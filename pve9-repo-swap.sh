#!/usr/bin/env bash
# ============================================================
# pve9-repo-swap.sh — switch a checked PVE 8 / Bookworm node
#                      to PVE 9 / Trixie (no-subscription).
# Run as root only after pve9-preflight.sh reports GO.
#
# This script is intentionally conservative:
#   * unknown third-party repositories are a hard stop;
#   * Docker is disabled and recreated after the PVE upgrade;
#   * only Debian and Proxmox repository entries are rewritten;
#   * apt update must succeed before the script reports READY.
# ============================================================
set -euo pipefail

red(){ printf '\033[31m%s\033[0m\n' "$*"; }
grn(){ printf '\033[32m%s\033[0m\n' "$*"; }
ylw(){ printf '\033[33m%s\033[0m\n' "$*"; }

[ "$(id -u)" -eq 0 ] || { red "Run as root."; exit 1; }

TS="$(date +%Y%m%d-%H%M%S)"
BK="$(mktemp -d "/root/apt-sources-backup-$TS-XXXXXX")"
NAG_HOOK="/etc/apt/apt.conf.d/no-nag-script"

active_sources() {
  find /etc/apt \( -name '*.list' -o -name '*.sources' \) -print0 2>/dev/null \
    | xargs -0 --no-run-if-empty grep -HE '^[[:space:]]*(deb(-src)?[[:space:]]|URIs:)' 2>/dev/null \
    || true
}

echo "Current enabled repository entries:"
ACTIVE_SOURCES="$(active_sources)"
printf '%s\n' "${ACTIVE_SOURCES:-  (none)}"
echo

UNKNOWN_THIRD="$(printf '%s\n' "$ACTIVE_SOURCES" \
  | grep -vE 'debian\.org|proxmox\.com|download\.docker\.com' || true)"
if [ -n "$UNKNOWN_THIRD" ]; then
  red "Unknown third-party repositories are enabled:"
  printf '%s\n' "$UNKNOWN_THIRD" | sed 's/^/   /'
  red "Disable them and confirm Trixie compatibility before running this script again."
  exit 2
fi

DOCKER_ENABLED="$(printf '%s\n' "$ACTIVE_SOURCES" | grep 'download\.docker\.com' || true)"
if [ -n "$DOCKER_ENABLED" ]; then
  ylw "Docker's repository will be disabled for the OS upgrade and recreated afterward."
fi

DEB822_BACKPORTS="$(find /etc/apt -name '*.sources' -print0 2>/dev/null \
  | xargs -0 --no-run-if-empty grep -lE '^Suites:.*backports' 2>/dev/null || true)"
if [ -n "$DEB822_BACKPORTS" ]; then
  red "Deb822 backports entries require manual stanza-level review:"
  printf '%s\n' "$DEB822_BACKPORTS" | sed 's/^/   /'
  red "Disable those stanzas before running this script again."
  exit 2
fi

echo "This script will:"
echo "  1. Back up all APT source configuration"
echo "  2. Park the unsupported no-nag APT hook, if present"
echo "  3. Disable Docker and old Proxmox/Ceph repository entries"
echo "  4. Change only official Debian repositories from bookworm to trixie"
echo "  5. Add one PVE 9 no-subscription repository in deb822 format"
echo "  6. Stop unless apt update completes successfully"
echo
read -r -p "Proceed with the repository migration? Type YES to continue: " ans
[ "$ans" = "YES" ] || { rmdir "$BK"; echo "Aborted; no changes made."; exit 0; }

cp -a /etc/apt/sources.list "$BK/" 2>/dev/null || true
cp -a /etc/apt/sources.list.d "$BK/" 2>/dev/null || true
echo "APT sources backed up to: $BK"

if [ -f "$NAG_HOOK" ]; then
  mv "$NAG_HOOK" "$BK/no-nag-script.disabled"
  ylw "Parked unsupported APT hook; review it manually after the upgrade."
fi

# Disable Docker entries in legacy .list files.
find /etc/apt -name '*.list' -print0 2>/dev/null \
  | xargs -0 --no-run-if-empty sed -i -E \
      '\@download\.docker\.com@ s@^([[:space:]]*)(deb-src|deb)@\1# disabled-for-pve9 \2@'

# Disable dedicated Docker deb822 source files. A mixed vendor file is unsafe
# to rewrite automatically and is rejected.
while IFS= read -r -d '' file; do
  grep -q 'download\.docker\.com' "$file" || continue
  if grep -E '^URIs:' "$file" | grep -qv 'download\.docker\.com'; then
    red "Mixed Docker/non-Docker deb822 file requires manual review: $file"
    exit 2
  fi
  mv "$file" "$file.disabled-for-pve9-$TS"
done < <(find /etc/apt -name '*.sources' -print0 2>/dev/null)

# Rewrite only official Debian entries. Unknown vendors were rejected above.
find /etc/apt -name '*.list' -print0 2>/dev/null \
  | xargs -0 --no-run-if-empty sed -i -E \
      '/(deb\.debian\.org|security\.debian\.org)/ s/bookworm/trixie/g'
while IFS= read -r -d '' file; do
  grep -Eq '^URIs:.*(deb\.debian\.org|security\.debian\.org)' "$file" || continue
  sed -i 's/bookworm/trixie/g' "$file"
done < <(find /etc/apt -name '*.sources' -print0 2>/dev/null)

# Retire old-format PVE/Ceph lines and dedicated deb822 PVE/Ceph files.
find /etc/apt -name '*.list' -print0 2>/dev/null \
  | xargs -0 --no-run-if-empty sed -i -E \
      '\@(download|enterprise)\.proxmox\.com/debian/(pve|ceph)@ s@^([[:space:]]*)deb@\1# disabled-for-pve9 deb@'
while IFS= read -r -d '' file; do
  [ "$file" = "/etc/apt/sources.list.d/proxmox.sources" ] && continue
  grep -Eq '^URIs:.*proxmox\.com/debian/(pve|ceph)' "$file" || continue
  mv "$file" "$file.disabled-for-pve9-$TS"
done < <(find /etc/apt -name '*.sources' -print0 2>/dev/null)

# Backports were not tested for the PVE major-version upgrade.
find /etc/apt -name '*.list' -print0 2>/dev/null \
  | xargs -0 --no-run-if-empty sed -i -E \
      '/backports/ s/^([[:space:]]*)deb/\1# disabled-for-pve9 deb/'
cat > /etc/apt/sources.list.d/proxmox.sources <<'EOF'
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
echo "Wrote /etc/apt/sources.list.d/proxmox.sources"

REMAINING_BOOKWORM="$(active_sources | grep -i bookworm || true)"
if [ -n "$REMAINING_BOOKWORM" ]; then
  red "Enabled Bookworm entries remain; refusing to continue:"
  printf '%s\n' "$REMAINING_BOOKWORM" | sed 's/^/   /'
  exit 3
fi

echo
echo "=== apt update (hard gate) ==="
if ! apt update; then
  red "apt update failed. Restore or correct the source configuration before dist-upgrade."
  exit 4
fi

echo
echo "=== apt policy ==="
apt policy

echo
grn "READY: apt update succeeded and no enabled Bookworm source remains."
echo "Review apt policy above. Then run 'apt dist-upgrade' interactively inside tmux."
if [ -n "$DOCKER_ENABLED" ]; then
  echo "After PVE 9 is verified, recreate Docker's repository using runbook Step G."
fi

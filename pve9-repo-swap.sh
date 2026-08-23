#!/usr/bin/env bash
# ============================================================
# pve9-repo-swap.sh  (v3)  —  switch APT repos from PVE 8 / Bookworm
#                             to PVE 9 / Trixie (no-subscription).
# Run as root on the node you are ABOUT to upgrade, AFTER
# pve9-preflight.sh reported GO.
#
# Tailored to this cluster's real layout:
#   * pve-no-subscription is defined twice (sources.list +
#     pve-community.list) -> both commented, one clean deb822 added.
#   * Old-format Proxmox pve/ceph lines are signed by the bookworm
#     key; commenting them and using deb822 (explicit Signed-By)
#     avoids a signature error against the trixie repo.
#   * Node 2 has an ENABLED Docker repo (deb + deb-src, bookworm) in
#     sources.list -> disabled for the upgrade so a docker-ce upgrade
#     is not dragged into the OS jump. Docker keeps running.
#     Re-enable on trixie AFTER PVE9 is verified (snippet printed).
#   * .save / .dpkg-old files are ignored (apt only reads *.list /
#     *.sources), so this script leaves them alone too.
# Backs up all sources, shows the plan, asks before committing.
# ============================================================
set -uo pipefail
[ "$(id -u)" -eq 0 ] || { echo "Run as root."; exit 1; }

TS="$(date +%Y%m%d-%H%M%S)"
BK="/root/apt-sources-backup-$TS"
mkdir -p "$BK"
cp -a /etc/apt/sources.list    "$BK/" 2>/dev/null || true
cp -a /etc/apt/sources.list.d  "$BK/" 2>/dev/null || true
echo "APT sources backed up to: $BK"
echo

echo "Current ENABLED repo lines (what apt uses now):"
find /etc/apt \( -name '*.list' -o -name '*.sources' \) -print0 \
  | xargs -0 --no-run-if-empty grep -hE '^[[:space:]]*(deb|deb-src) ' 2>/dev/null \
  | sed 's/^/   /' || echo "   (none)"
echo

DOCKER_ENABLED="$(find /etc/apt -name '*.list' -print0 | xargs -0 --no-run-if-empty \
  grep -hE '^[[:space:]]*(deb|deb-src) .*docker\.com' 2>/dev/null || true)"
if [ -n "$DOCKER_ENABLED" ]; then
  printf '\033[33m%s\033[0m\n' "An ENABLED Docker repo was found and WILL BE DISABLED for the upgrade:"
  echo "$DOCKER_ENABLED" | sed 's/^/   /'
  printf '\033[33m%s\033[0m\n' "   Docker keeps running. Re-enable it on trixie AFTER PVE9 is verified (see end)."
  echo
fi

NAG_HOOK="/etc/apt/apt.conf.d/no-nag-script"
NAG_PRESENT=0
[ -f "$NAG_HOOK" ] && NAG_PRESENT=1

echo "This script will:"
echo "  0. Move the subscription-nag APT hook (no-nag-script) aside, if present"
echo "  1. Disable any third-party Docker repo lines (deb + deb-src) for the upgrade"
echo "  2. Rewrite Debian base repos:  bookworm -> trixie  (never touches docker lines)"
echo "  3. Comment out ALL old-format Proxmox pve/ceph lines (duplicates, pvetest, enterprise)"
echo "  4. Add ONE PVE 9 no-subscription repo (trixie, deb822, correct signing key)"
echo "  5. Comment out any backports lines"
echo
read -r -p "Proceed with the repo swap? type YES to continue: " ans
[ "$ans" = "YES" ] || { echo "Aborted — only the backup was written, no repo changes made."; exit 0; }

# 0) move the subscription-nag APT hook out of apt.conf.d so it can't fire during dist-upgrade
if [ "$NAG_PRESENT" -eq 1 ]; then
  mv "$NAG_HOOK" "$BK/no-nag-script.disabled"
  echo "Moved $NAG_HOOK -> $BK/no-nag-script.disabled (re-apply the nag fix fresh on 9 — see end)"
fi

# 1) disable Docker (deb + deb-src) wherever it lives
find /etc/apt -name '*.list' -print0 | xargs -0 --no-run-if-empty \
  sed -i -E '\@download\.docker\.com@ s@^([[:space:]]*)(deb-src|deb)@\1#\2@'

# 2) Debian base bookworm -> trixie, but NEVER on docker lines
find /etc/apt -name '*.list' -print0 | xargs -0 --no-run-if-empty \
  sed -i '/docker\.com/! s/bookworm/trixie/g'

# 3) comment ALL old-format Proxmox pve/ceph lines (@ delimiter keeps / and | literal/alternation)
find /etc/apt -name '*.list' -print0 | xargs -0 --no-run-if-empty \
  sed -i -E '\@(download|enterprise)\.proxmox\.com/debian/(pve|ceph)@ s@^([[:space:]]*)deb@\1#deb@'

# 4) one clean deb822 PVE 9 no-subscription repo (matches official wiki)
cat > /etc/apt/sources.list.d/proxmox.sources <<'EOF'
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
echo "Wrote /etc/apt/sources.list.d/proxmox.sources"

# 5) backports off
find /etc/apt -name '*.list' -print0 | xargs -0 --no-run-if-empty \
  sed -i '/backports/ s/^[[:space:]]*deb/#deb/'

echo
echo "=== apt update ==="
apt update
echo
echo "=== apt policy  (should show ONLY Debian trixie + pve-no-subscription trixie) ==="
apt policy
echo
echo "------------------------------------------------------------"
echo "If 'apt update' was error-free and 'apt policy' is clean, upgrade INSIDE tmux:"
echo "    apt dist-upgrade"
echo
if [ "$NAG_PRESENT" -eq 1 ]; then
  echo "AFTER PVE9 is confirmed good on THIS node, re-apply the subscription-nag fix (PVE9-correct):"
  echo "    cp /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js{,.bak}"
  echo "    sed -i \"s/data.status.toLowerCase() !== 'active'/data.status.toLowerCase() === 'active'/\" \\"
  echo "        /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js"
  echo "    systemctl restart pveproxy      # then hard-reload the web UI: Ctrl+Shift+R"
  echo "    # (mobile UI has a separate nag on 9; the desktop patch above does not cover it)"
  echo
fi
if [ -n "$DOCKER_ENABLED" ]; then
  echo "AFTER PVE9 is confirmed good on THIS node, bring Docker back on trixie WITH a fresh"
  echo "(non-SHA-1) key — Trixie's sqv rejects the old key:"
  echo "    install -m0755 -d /usr/share/keyrings"
  echo "    curl -fsSL https://download.docker.com/linux/debian/gpg \\"
  echo "      | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg"
  echo "    sed -i '/download.docker.com/ s/^deb/#deb/' /etc/apt/sources.list"
  echo "    echo 'deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/debian trixie stable' >> /etc/apt/sources.list"
  echo "    apt update && apt install --only-upgrade docker-ce docker-ce-cli containerd.io"
  echo "    docker ps    # confirm container(s) back"
fi
echo "------------------------------------------------------------"

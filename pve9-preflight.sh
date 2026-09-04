#!/usr/bin/env bash
# ============================================================
# pve9-preflight.sh  —  PVE 8 -> 9 pre-flight and backup gate
# Run as root on EACH node BEFORE you upgrade that node.
# Non-destructive: it only reads system state and writes backups.
# It changes NO system configuration. Safe to run over SSH.
# ============================================================
set -uo pipefail

CONFIG_BACKUP_DIR="${CONFIG_BACKUP_DIR:-/root/pve9-config-backup-$(hostname)-$(date +%Y%m%d-%H%M%S)}"
GUEST_BACKUP_DIR="${GUEST_BACKUP_DIR:-}"
BACKUP_RESTORE_TESTED="${BACKUP_RESTORE_TESTED:-NO}"
BACKUP_MODE="${BACKUP_MODE:-snapshot}"
HA_MAINTENANCE_CONFIRMED="${HA_MAINTENANCE_CONFIRMED:-NO}"
MIN_FREE_GB=5
REC_FREE_GB=10

red(){ printf '\033[31m%s\033[0m\n' "$*"; }
grn(){ printf '\033[32m%s\033[0m\n' "$*"; }
ylw(){ printf '\033[33m%s\033[0m\n' "$*"; }
hdr(){ printf '\n=== %s ===\n' "$*"; }

[ "$(id -u)" -eq 0 ] || { red "Run as root."; exit 1; }

case "$BACKUP_MODE" in
  snapshot|stop|suspend) ;;
  *) red "BACKUP_MODE must be snapshot, stop, or suspend."; exit 1 ;;
esac

PVE_STATUS_FILE="$(mktemp /tmp/pve9-preflight-status.XXXXXX)"
trap 'rm -f "$PVE_STATUS_FILE"' EXIT

GO=1
fail(){ red "FAIL: $*"; GO=0; }
warn(){ ylw "WARN: $*"; }
ok(){   grn "OK:   $*"; }

hdr "Node / version"
hostname
PVEVER="$(pveversion | grep -oP '(?<=pve-manager/)[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
echo "pve-manager: ${PVEVER:-unknown}"
ver_ge(){ [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" = "$2" ]; }
if [ -n "$PVEVER" ] && ver_ge "$PVEVER" "8.4.1"; then
  ok "on 8.4.1+ ($PVEVER)"
else
  fail "must be on 8.4.1+ first  ->  apt update && apt dist-upgrade  (still on bookworm repos), then reboot"
fi

hdr "Free space on /"
AVAIL_GB=$(( $(df --output=avail -k / | tail -1) / 1024 / 1024 ))
echo "${AVAIL_GB} GB free on /"
if   [ "$AVAIL_GB" -ge "$REC_FREE_GB" ]; then ok ">=${REC_FREE_GB}GB"
elif [ "$AVAIL_GB" -ge "$MIN_FREE_GB" ]; then warn "between ${MIN_FREE_GB} and ${REC_FREE_GB}GB (works, more is safer)"
else fail "<${MIN_FREE_GB}GB free on / — free space before upgrading"
fi

hdr "Ceph (client libs OK; a DEPLOYED cluster is not)"
# Distinguish a real Ceph deployment (daemons / storage / data) from leftover
# client libraries. Dormant libs are harmless and ride along in the upgrade.
CEPH_DAEMONS="$(systemctl list-units --type=service --all 2>/dev/null | grep -cE 'ceph-(mon|osd|mgr|mds)@')"
CEPH_STORAGE="$(grep -cEi '^\s*(rbd|cephfs)\b|type\s+(rbd|cephfs)' /etc/pve/storage.cfg 2>/dev/null)"; CEPH_STORAGE="${CEPH_STORAGE:-0}"
CEPH_DATA=0
[ -d /var/lib/ceph ] && [ "$(find /var/lib/ceph -mindepth 2 2>/dev/null | head -1 | wc -l)" -gt 0 ] && CEPH_DATA=1
if [ "${CEPH_DAEMONS:-0}" -gt 0 ] || [ "${CEPH_STORAGE:-0}" -gt 0 ] || [ "$CEPH_DATA" -gt 0 ]; then
  fail "DEPLOYED Ceph detected (daemons=$CEPH_DAEMONS storage=$CEPH_STORAGE data=$CEPH_DATA). Upgrade Ceph to Squid 19.2 FIRST. STOP and tell me."
  ceph --version 2>/dev/null || true
elif command -v ceph >/dev/null 2>&1; then
  ok "Ceph client libraries only — no daemons, no storage, no cluster data. Harmless; rides along in the upgrade."
else
  ok "no Ceph at all — local storage path applies"
fi

hdr "Co-installed Proxmox Backup Server"
if dpkg-query -W -f='${db:Status-Status}\n' proxmox-backup-server 2>/dev/null \
  | grep -qx installed; then
  fail "Proxmox Backup Server is co-installed; complete the supported PBS 3-to-4 path first"
else
  ok "Proxmox Backup Server is not co-installed"
fi

hdr "Cluster status"
if pvecm status >"$PVE_STATUS_FILE" 2>&1; then
  cat "$PVE_STATUS_FILE"
  if grep -qiE 'Quorate:[[:space:]]*Yes' "$PVE_STATUS_FILE"; then
    ok "cluster is quorate"
  else
    fail "cluster is not quorate — restore cluster health before upgrading"
  fi
else
  fail "pvecm status failed — this cluster procedure requires a healthy, quorate cluster"
  cat "$PVE_STATUS_FILE"
fi

hdr "HA resources (only matters if guests are HA-managed)"
if command -v ha-manager >/dev/null 2>&1; then
  HA_OUT="$(ha-manager status 2>/dev/null || true)"
  echo "${HA_OUT:-<none>}"
  if echo "$HA_OUT" | grep -qE 'service (vm|ct):'; then
    if [ "$HA_MAINTENANCE_CONFIRMED" = "YES" ]; then
      ok "operator confirmed node maintenance mode for HA-managed guests"
    else
      fail "HA-managed guests exist; enable node maintenance, then re-run with HA_MAINTENANCE_CONFIRMED=YES"
    fi
  else
    ok "no HA-managed guests — the maintenance-mode step does NOT apply, skip it"
  fi
else
  ok "ha-manager not present"
fi

hdr "Local APT hooks"
if [ -f /etc/apt/apt.conf.d/no-nag-script ]; then
  warn "unsupported no-nag-script hook present — repo-swap will park it; review it manually after the upgrade"
else
  ok "no known third-party APT hook present"
fi

hdr "Guests on this node"
mapfile -t VMIDS < <(qm list 2>/dev/null | awk 'NR>1{print $1}')
mapfile -t CTIDS < <(pct list 2>/dev/null | awk 'NR>1{print $1}')
qm list 2>/dev/null || true
pct list 2>/dev/null || true

hdr "Backup: configuration -> $CONFIG_BACKUP_DIR"
if mkdir -p "$CONFIG_BACKUP_DIR" && tar czf "$CONFIG_BACKUP_DIR/etc-$(hostname).tar.gz" \
  /etc/pve /etc/network/interfaces /etc/hosts /etc/hostname \
  /etc/passwd /etc/resolv.conf /etc/apt 2>/dev/null && \
  [ -s "$CONFIG_BACKUP_DIR/etc-$(hostname).tar.gz" ]; then
  ok "configuration archived: $CONFIG_BACKUP_DIR/etc-$(hostname).tar.gz"
else
  fail "configuration backup failed or is empty"
fi
cp -a /etc/pve/qemu-server "$CONFIG_BACKUP_DIR/qemu-server" 2>/dev/null || true
cp -a /etc/pve/lxc "$CONFIG_BACKUP_DIR/lxc" 2>/dev/null || true

hdr "Backup: guest disks (vzdump)"
if [ "${#VMIDS[@]}" -eq 0 ] && [ "${#CTIDS[@]}" -eq 0 ]; then
  ok "no guests on this node — nothing to vzdump"
else
  if [ -z "$GUEST_BACKUP_DIR" ]; then
    fail "guests exist: set GUEST_BACKUP_DIR to mounted external storage, then re-run"
  elif ! mkdir -p "$GUEST_BACKUP_DIR" || [ ! -w "$GUEST_BACKUP_DIR" ]; then
    fail "guest backup destination is unavailable or not writable: $GUEST_BACKUP_DIR"
  else
    ROOT_SOURCE="$(findmnt -n -o SOURCE --target / 2>/dev/null || true)"
    BACKUP_SOURCE="$(findmnt -n -o SOURCE --target "$GUEST_BACKUP_DIR" 2>/dev/null || true)"
    if [ -z "$BACKUP_SOURCE" ] || [ "$BACKUP_SOURCE" = "$ROOT_SOURCE" ]; then
      fail "GUEST_BACKUP_DIR must be mounted external storage, not the node root filesystem"
    else
      ok "external guest backup target: $GUEST_BACKUP_DIR ($BACKUP_SOURCE)"
      BACKUPS_OK=1
      for id in "${VMIDS[@]}" "${CTIDS[@]}"; do
        [ -n "$id" ] || continue
        echo ">> vzdump $id"
        if ! vzdump "$id" --dumpdir "$GUEST_BACKUP_DIR" --mode "$BACKUP_MODE" --compress zstd; then
          fail "vzdump $id failed; do not upgrade until a valid backup succeeds"
          BACKUPS_OK=0
        fi
      done
      [ "$BACKUPS_OK" -eq 1 ] && ok "all guest backups completed on external storage"
    fi
  fi

  if [ "$BACKUP_RESTORE_TESTED" = "YES" ]; then
    ok "operator confirmed a backup restore test"
  else
    fail "a tested restore is required; set BACKUP_RESTORE_TESTED=YES only after verifying one"
  fi
fi

hdr "pve8to9 --full  (the authoritative checker)"
if command -v pve8to9 >/dev/null 2>&1; then
  if ! pve8to9 --full | tee "$CONFIG_BACKUP_DIR/pve8to9.txt"; then
    fail "pve8to9 did not complete successfully"
  fi
  FAILS=$(grep -c 'FAIL:' "$CONFIG_BACKUP_DIR/pve8to9.txt" || true)
  WARNS=$(grep -c 'WARN:' "$CONFIG_BACKUP_DIR/pve8to9.txt" || true)
  echo
  echo "pve8to9 summary: ${FAILS} FAIL, ${WARNS} WARN  (log: $CONFIG_BACKUP_DIR/pve8to9.txt)"
  [ -s "$CONFIG_BACKUP_DIR/pve8to9.txt" ] || fail "pve8to9 produced no report"
  [ "${FAILS:-0}" -eq 0 ] || fail "pve8to9 reported FAILs — resolve each, then re-run this script"
else
  fail "pve8to9 not found — this node is not on latest 8.4 packages yet"
fi

hdr "REV-4 sweep: NIC-pinning readiness"
PVEMANAGER="$(pveversion | grep -oP '(?<=pve-manager/)[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
if ver_ge "${PVEMANAGER:-0}" "8.4.9"; then
  ok "pve-manager $PVEMANAGER >= 8.4.9 -> pve-network-interface-pinning IS available (pin BEFORE upgrade, see runbook Step B)"
else
  warn "pve-manager $PVEMANAGER < 8.4.9 -> pin names manually (naming-scheme doc) or get to latest 8.4 first"
fi
echo "Current interfaces:"; ip -br link 2>/dev/null | awk '{print "   "$1" "$2}'

hdr "REV-4 sweep: third-party repositories"
ACTIVE_SOURCES="$(find /etc/apt \( -name '*.list' -o -name '*.sources' \) -print0 2>/dev/null \
  | xargs -0 --no-run-if-empty grep -hE '^[[:space:]]*(deb(-src)?[[:space:]]|URIs:)' 2>/dev/null || true)"
THIRD="$(printf '%s\n' "$ACTIVE_SOURCES" | grep -vE 'debian\.org|proxmox\.com|download\.docker\.com' || true)"
DOCKER_SOURCE="$(printf '%s\n' "$ACTIVE_SOURCES" | grep 'download\.docker\.com' || true)"
if [ -n "$THIRD" ]; then
  fail "unsupported third-party repositories are enabled; disable and verify compatibility before the upgrade:"
  printf '%s\n' "$THIRD" | sed 's/^/   /'
else
  ok "no unknown third-party repositories enabled"
fi
if [ -n "$DOCKER_SOURCE" ]; then
  warn "Docker repository is enabled; repo-swap will disable it and Step G recreates it from Docker's current instructions"
fi

hdr "REV-4 sweep: boot method (do NOT blind-purge systemd-boot)"
if command -v efibootmgr >/dev/null 2>&1 && efibootmgr >/dev/null 2>&1; then
  efibootmgr -v 2>/dev/null | grep -iE 'BootCurrent|Boot0|shim|grub' | head -6 | sed 's/^/   /'
  warn "UEFI system — if pve8to9 FAILs on systemd-boot, confirm GRUB/shim boots FIRST above before touching it"
else
  ok "legacy BIOS boot (no efibootmgr/EFI vars) — systemd-boot item does not apply"
fi

hdr "REV-4 sweep: sysctl + custom ACL roles"
if [ -s /etc/sysctl.conf ] && grep -qvE '^[[:space:]]*(#|$)' /etc/sysctl.conf; then
  warn "/etc/sysctl.conf has custom tunables — migrate to /etc/sysctl.d/99-custom.conf after upgrade (precautionary):"
  grep -vE '^[[:space:]]*(#|$)' /etc/sysctl.conf | sed 's/^/   /'
else
  ok "/etc/sysctl.conf has no custom tunables"
fi
if grep -q 'VM.Monitor' /etc/pve/user.cfg 2>/dev/null; then
  warn "custom role uses VM.Monitor -> migrate to Sys.Audit / VM.GuestAgent.* on 9"
else
  ok "no VM.Monitor ACL roles"
fi

hdr "VERDICT for $(hostname)"
if [ "$GO" -eq 1 ]; then
  grn "GO — pre-flight passed. Review any WARN lines above, then run pve9-repo-swap.sh on THIS node."
else
  red "NO-GO — fix the FAIL lines above and re-run until this says GO. Do not proceed."
  exit 2
fi

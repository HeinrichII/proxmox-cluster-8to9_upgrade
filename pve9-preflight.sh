#!/usr/bin/env bash
# ============================================================
# pve9-preflight.sh  —  PVE 8 -> 9 pre-flight & backup
# Run as root on EACH node BEFORE you upgrade that node.
# Non-destructive: it only READS system state and WRITES backups.
# It changes NO system configuration. Safe to run over SSH.
# ============================================================
set -uo pipefail

BACKUP_DIR="${BACKUP_DIR:-/root/pve9-backup-$(hostname)-$(date +%Y%m%d-%H%M%S)}"
MIN_FREE_GB=5
REC_FREE_GB=10

red(){ printf '\033[31m%s\033[0m\n' "$*"; }
grn(){ printf '\033[32m%s\033[0m\n' "$*"; }
ylw(){ printf '\033[33m%s\033[0m\n' "$*"; }
hdr(){ printf '\n=== %s ===\n' "$*"; }

[ "$(id -u)" -eq 0 ] || { red "Run as root."; exit 1; }

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

hdr "Cluster status"
if pvecm status >"/tmp/pvecm.$$" 2>&1; then
  cat "/tmp/pvecm.$$"
  if grep -qiE 'Quorate:[[:space:]]*Yes' "/tmp/pvecm.$$"; then
    ok "cluster is quorate"
  else
    warn "cluster not showing quorate — do NOT upgrade a node unless the other two stay quorate"
  fi
else
  warn "pvecm status failed (single node, or cluster service down):"
  cat "/tmp/pvecm.$$"
fi
rm -f "/tmp/pvecm.$$"

hdr "HA resources (only matters if guests are HA-managed)"
if command -v ha-manager >/dev/null 2>&1; then
  HA_OUT="$(ha-manager status 2>/dev/null || true)"
  echo "${HA_OUT:-<none>}"
  if echo "$HA_OUT" | grep -qE 'service (vm|ct):'; then
    warn "HA-managed guests exist -> enable node-maintenance on THIS node before upgrade, disable after (see runbook)"
  else
    ok "no HA-managed guests — the maintenance-mode step does NOT apply, skip it"
  fi
else
  ok "ha-manager not present"
fi

hdr "Subscription-nag APT hook"
if [ -f /etc/apt/apt.conf.d/no-nag-script ]; then
  warn "no-nag-script hook present — pve9-repo-swap.sh will move it aside before the upgrade (expected)"
else
  ok "no nag hook present"
fi

hdr "Guests on this node"
qm list  2>/dev/null || true
pct list 2>/dev/null || true

hdr "Backup: config -> $BACKUP_DIR"
mkdir -p "$BACKUP_DIR"
tar czf "$BACKUP_DIR/etc-$(hostname).tar.gz" \
  /etc/pve /etc/network/interfaces /etc/hosts /etc/hostname \
  /etc/passwd /etc/resolv.conf /etc/apt 2>/dev/null && \
  ok "config archived: $BACKUP_DIR/etc-$(hostname).tar.gz" || warn "config tar had non-fatal warnings"
cp -a /etc/pve/qemu-server "$BACKUP_DIR/qemu-server" 2>/dev/null || true
cp -a /etc/pve/lxc         "$BACKUP_DIR/lxc"         2>/dev/null || true

hdr "Backup: guest disks (vzdump)"
echo "Target: $BACKUP_DIR  (LOCAL disk — copy this OFF the node when done!)"
mapfile -t VMIDS < <(qm list  2>/dev/null | awk 'NR>1{print $1}')
mapfile -t CTIDS < <(pct list 2>/dev/null | awk 'NR>1{print $1}')
if [ "${#VMIDS[@]}" -eq 0 ] && [ "${#CTIDS[@]}" -eq 0 ]; then
  ok "no guests on this node — nothing to vzdump"
else
  for id in "${VMIDS[@]}" "${CTIDS[@]}"; do
    [ -n "$id" ] || continue
    echo ">> vzdump $id"
    vzdump "$id" --dumpdir "$BACKUP_DIR" --mode snapshot --compress zstd \
      || warn "vzdump $id had issues — for a guaranteed-consistent copy use: vzdump $id --dumpdir $BACKUP_DIR --mode stop"
  done
  ok "guest backups written to $BACKUP_DIR"
fi

hdr "pve8to9 --full  (the authoritative checker)"
if command -v pve8to9 >/dev/null 2>&1; then
  pve8to9 --full | tee "$BACKUP_DIR/pve8to9.txt"
  FAILS=$(grep -c 'FAIL:' "$BACKUP_DIR/pve8to9.txt" || true)
  WARNS=$(grep -c 'WARN:' "$BACKUP_DIR/pve8to9.txt" || true)
  echo
  echo "pve8to9 summary: ${FAILS} FAIL, ${WARNS} WARN  (log: $BACKUP_DIR/pve8to9.txt)"
  [ "${FAILS:-0}" -eq 0 ] || fail "pve8to9 reported FAILs — resolve each, then re-run this script"
else
  fail "pve8to9 not found — this node is not on latest 8.4 packages yet"
fi

hdr "REV-3 sweep: NIC-pinning readiness"
PVEMANAGER="$(pveversion | grep -oP '(?<=pve-manager/)[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
if ver_ge "${PVEMANAGER:-0}" "8.4.9"; then
  ok "pve-manager $PVEMANAGER >= 8.4.9 -> pve-network-interface-pinning IS available (pin BEFORE upgrade, see runbook Step B)"
else
  warn "pve-manager $PVEMANAGER < 8.4.9 -> pin names manually (naming-scheme doc) or get to latest 8.4 first"
fi
echo "Current interfaces:"; ip -br link 2>/dev/null | awk '{print "   "$1" "$2}'

hdr "REV-3 sweep: third-party repos + keyrings (SHA-1/sqv exposure)"
THIRD="$(find /etc/apt -name '*.list' -print0 2>/dev/null | xargs -0 --no-run-if-empty grep -hE '^[[:space:]]*deb' 2>/dev/null | grep -vE 'debian\.org|proxmox\.com' || true)"
if [ -n "$THIRD" ]; then
  warn "third-party repo(s) present — their keys may be SHA-1 (rejected by Trixie sqv). Refresh key at re-enable, not mid-upgrade:"
  echo "$THIRD" | sed 's/^/   /'
else
  ok "no third-party repos beyond Debian/Proxmox"
fi
echo "keyrings on disk:"; ls -1 /usr/share/keyrings/ 2>/dev/null | sed 's/^/   /'
if ls /usr/share/keyrings/docker* >/dev/null 2>&1; then
  ok "docker keyring present in /usr/share/keyrings"
elif echo "$THIRD" | grep -q docker; then
  warn "docker repo enabled but NO docker keyring in /usr/share/keyrings -> legacy key = likely SHA-1. Refresh at Step G (Node 2)."
fi

hdr "REV-3 sweep: boot method (do NOT blind-purge systemd-boot)"
if command -v efibootmgr >/dev/null 2>&1 && efibootmgr >/dev/null 2>&1; then
  efibootmgr -v 2>/dev/null | grep -iE 'BootCurrent|Boot0|shim|grub' | head -6 | sed 's/^/   /'
  warn "UEFI system — if pve8to9 FAILs on systemd-boot, confirm GRUB/shim boots FIRST above before touching it"
else
  ok "legacy BIOS boot (no efibootmgr/EFI vars) — systemd-boot item does not apply"
fi

hdr "REV-3 sweep: sysctl + custom ACL roles"
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

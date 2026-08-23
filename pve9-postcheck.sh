#!/usr/bin/env bash
# ============================================================
# pve9-postcheck.sh  —  verify a node after dist-upgrade + reboot.
# Run as root on the freshly-upgraded node.
# ============================================================
set -uo pipefail
grn(){ printf '\033[32m%s\033[0m\n' "$*"; }
ylw(){ printf '\033[33m%s\033[0m\n' "$*"; }
hdr(){ printf '\n=== %s ===\n' "$*"; }

hdr "Version (expect 9.x) + kernel"
pveversion
uname -r

hdr "Cluster status (expect Quorate: Yes)"
pvecm status || ylw "pvecm status failed — investigate before touching the next node"

hdr "Guests (should be running as before)"
qm list  2>/dev/null || true
pct list 2>/dev/null || true

hdr "Failed systemd units (should be empty)"
systemctl --failed --no-legend || true

hdr "pve8to9 --full (post-upgrade pass — expect clean / info only)"
pve8to9 --full 2>/dev/null || ylw "pve8to9 not present post-upgrade (expected on 9.x) — skip"

hdr "Active repos"
apt policy 2>/dev/null | grep -iE 'trixie|pve' || true

hdr "Explicit apt update (catches SHA-1/sqv rejection on THIS node)"
if apt update 2>&1 | tee /tmp/aptupd.$$ | grep -qiE 'sqv .*error|SHA1 is not considered secure|is not signed'; then
  ylw "SHA-1 / signature rejection detected — refresh the offending vendor key into /usr/share/keyrings and add signed-by= (see runbook Step G / Gotchas):"
  grep -iE 'sqv|SHA1|not signed|Err:' /tmp/aptupd.$$ | sed 's/^/   /'
else
  grn "apt update clean — no signature rejections"
fi
rm -f /tmp/aptupd.$$

hdr "Network / NIC names intact"
ip -br link 2>/dev/null | awk '{print "   "$1" "$2}'
ip -br addr show up 2>/dev/null | grep -qE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' \
  && grn "node has an IP / network is up" || ylw "no IPv4 up — check /etc/network/interfaces vs current NIC names"

echo
grn "If: pveversion = 9.x, cluster Quorate: Yes, no failed units, guests running —"
grn "this node is DONE. Move to the NEXT node. Never upgrade two nodes at once."

#!/usr/bin/env bash
# ============================================================
# pve9-postcheck.sh — hard-gate a node after upgrade and reboot.
# Run as root on the freshly upgraded node. A nonzero exit means
# the next cluster node must not be upgraded yet.
# ============================================================
set -uo pipefail

red(){ printf '\033[31m%s\033[0m\n' "$*"; }
grn(){ printf '\033[32m%s\033[0m\n' "$*"; }
ylw(){ printf '\033[33m%s\033[0m\n' "$*"; }
hdr(){ printf '\n=== %s ===\n' "$*"; }

[ "$(id -u)" -eq 0 ] || { red "Run as root."; exit 1; }

PASS=1
fail(){ red "FAIL: $*"; PASS=0; }
warn(){ ylw "WARN: $*"; }
ok(){ grn "OK:   $*"; }

STATUS_FILE="$(mktemp /tmp/pve9-postcheck-status.XXXXXX)"
APT_LOG="$(mktemp /tmp/pve9-postcheck-apt.XXXXXX)"
UNITS_FILE="$(mktemp /tmp/pve9-postcheck-units.XXXXXX)"
trap 'rm -f "$STATUS_FILE" "$APT_LOG" "$UNITS_FILE"' EXIT

hdr "Version and kernel"
PVE_OUTPUT="$(pveversion 2>&1 || true)"
printf '%s\n' "$PVE_OUTPUT"
uname -r
if printf '%s\n' "$PVE_OUTPUT" | grep -qE 'pve-manager/9\.'; then
  ok "pve-manager major version is 9"
else
  fail "pve-manager 9.x was not detected"
fi

hdr "Cluster status"
if pvecm status >"$STATUS_FILE" 2>&1; then
  cat "$STATUS_FILE"
  if grep -qiE 'Quorate:[[:space:]]*Yes' "$STATUS_FILE"; then
    ok "cluster is quorate"
  else
    fail "cluster is not quorate"
  fi
else
  cat "$STATUS_FILE"
  fail "pvecm status failed"
fi

hdr "Core Proxmox services"
for service in pve-cluster pvedaemon pveproxy pvestatd corosync; do
  if systemctl is-active --quiet "$service"; then
    ok "$service is active"
  else
    fail "$service is not active"
  fi
done

hdr "Guests (compare expected state before continuing)"
qm list 2>/dev/null || fail "qm list failed"
pct list 2>/dev/null || fail "pct list failed"

hdr "Failed systemd units"
systemctl --failed --no-legend >"$UNITS_FILE" 2>&1 || true
if [ -s "$UNITS_FILE" ]; then
  cat "$UNITS_FILE"
  fail "one or more systemd units failed"
else
  ok "no failed systemd units"
fi

hdr "pve8to9 checker"
if command -v pve8to9 >/dev/null 2>&1; then
  CHECK_STATUS=0
  CHECK_OUTPUT="$(pve8to9 --full 2>&1)" || CHECK_STATUS=$?
  printf '%s\n' "$CHECK_OUTPUT"
  if [ "$CHECK_STATUS" -ne 0 ]; then
    fail "pve8to9 returned status $CHECK_STATUS"
  elif [ -z "$CHECK_OUTPUT" ]; then
    fail "pve8to9 produced no report"
  elif printf '%s\n' "$CHECK_OUTPUT" | grep -q 'FAIL:'; then
    fail "pve8to9 still reports failures"
  else
    ok "pve8to9 reports no failures"
  fi
else
  warn "pve8to9 is not present after the upgrade; skipped"
fi

hdr "Active repositories"
apt policy 2>/dev/null | grep -iE 'trixie|pve' || true
ACTIVE_BOOKWORM="$(find /etc/apt \( -name '*.list' -o -name '*.sources' \) -print0 2>/dev/null \
  | xargs -0 --no-run-if-empty grep -HE '^[[:space:]]*(deb(-src)?[[:space:]]|Suites:).*bookworm' 2>/dev/null || true)"
if [ -n "$ACTIVE_BOOKWORM" ]; then
  printf '%s\n' "$ACTIVE_BOOKWORM"
  fail "enabled Bookworm repository entries remain"
else
  ok "no enabled Bookworm repository entry detected"
fi

hdr "apt update"
if apt update 2>&1 | tee "$APT_LOG"; then
  if grep -qiE 'sqv .*error|SHA1 is not considered secure|is not signed|^Err:' "$APT_LOG"; then
    fail "apt reported a signature or repository error"
  else
    ok "apt update completed without detected repository errors"
  fi
else
  fail "apt update returned a nonzero status"
fi

hdr "Network"
ip -br link 2>/dev/null | awk '{print "   "$1" "$2}'
if ip -br addr show up 2>/dev/null | grep -qE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'; then
  ok "node has an active IPv4 address"
else
  fail "no active IPv4 address detected"
fi

hdr "VERDICT for $(hostname)"
if [ "$PASS" -eq 1 ]; then
  grn "PASS — this node passed automated checks. Confirm guest application health before proceeding."
  exit 0
fi

red "NO-GO — resolve every FAIL before upgrading the next node."
exit 2

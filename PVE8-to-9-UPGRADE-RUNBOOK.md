# Proxmox VE 8 → 9 Cluster Upgrade Runbook — REV 3

**Deadline:** Aug 31, 2026 (PVE 8 EOL — confirmed against Proxmox's lifecycle table).
**Your cluster:** 3× Dell Wyse 5060, currently **PVE 8.4.20**, 16 GB RAM / 1 TB each, no shared storage.
**Target:** current Trixie repo = **PVE 9.2** — Debian 13.5, **kernel 7.0**, QEMU 11, LXC 7, ZFS 2.4.
`apt` installs whatever 9.x is current; you don't get to pin 9.0. **Reboot into the new kernel is mandatory** regardless of your prior kernel.
**Goal:** seamless — quorum never drops, each guest only blinks offline (or zero downtime if you migrate).

> **REV-3 note:** merges the Aug 22 sweep. New vs rev-2: NIC pinning *before* upgrade, the Trixie **SHA-1/sqv** third-party-key landmine (scoped to Node 2 Docker only, at re-enable), systemd-boot / sysctl / custom-ACL checks, and an explicit third-party `apt update` gate per node. Verified against the official 8→9 wiki + the 9.2 release notes.

---

## Assumptions (scripts self-check these; correct me if any are wrong)

1. **No Ceph** — local storage only. Pre-flight hard-fails if it finds Ceph.
2. **No Proxmox Backup Server** co-installed.
3. **No-subscription repos** (homelab). Confirmed from your repo dump.
4. **Legacy-BIOS + ext4/LVM boot** (typical for Wyse thin clients). If pve8to9 raises a systemd-boot or ZFS-boot item, see Gotchas — likely N/A but handle it, don't assume.

**Confirmed free passes for this cluster:** Ceph→Squid N/A (no Ceph) · PBS→4 N/A (not co-installed) · LVM autoactivation mostly N/A (no shared pool; local vols keep old behavior).

---

## Why this isn't one blind script

- `apt dist-upgrade` is **interactive** — it asks how to handle changed config files. Auto-answering blind can brick a hypervisor.
- A **cluster upgrades one node at a time** so the other two hold quorum. All-at-once = one bad boot takes the cluster down with no fallback.
- The **Wyse 5060's older AMD SoC** rides the edge of Proxmox's "test old hardware first" caution for kernel 7.0. Node 1 (empty) is the **canary** — clean boot there means the two identical nodes will follow.

---

## Node order (fully, one at a time — never two at once)

| Order | Node | Workload | Why this slot |
|------:|------|----------|---------------|
| 1st | **Node 1 (pve1)** | *(empty)* | Canary. Zero risk, proves the 5060 boots kernel 7.0. |
| 2nd | **Node 2 (pve2)** | Docker | After canary passes. Only node with the SHA-1/Docker step. |
| 3rd | **Node 3 (pve3)** | Nextcloud | Last. Cleanest repo set. |

**Post-install tweaks (all nodes):** a Proxmox post-install/nag script customized these boxes.
- **`no-nag-script` APT hook** → `pve9-repo-swap.sh` moves it aside pre-upgrade so it can't fire during `dist-upgrade`. Re-apply the nag fix after (Step G).
- **HA services enabled** = cluster default. Pre-flight runs `ha-manager status`; **no** `service vm:`/`ct:` lines = no HA-managed guests, skip maintenance mode. If any are listed: `ha-manager crm-command node-maintenance enable <node>` before, `... disable <node>` after. (9.2 also has cluster-wide HA arm/disarm if you ever need it.)
- **`.save` / `.dpkg-old` repo leftovers** → ignored by apt (reads only `*.list` / `*.sources`). Leave them or `rm /etc/apt/sources.list.d/*.save /etc/apt/sources.list.d/*.dpkg-old`.

**SHA-1 / sqv (Node 2 only):** Trixie's apt uses `sqv` and rejects SHA-1-signed keys since 2026-02-01. Your Debian + Proxmox keyrings are modern (confirmed present), so **the core upgrade is unaffected**. The only exposure is **Node 2's Docker key** (it's in the legacy trusted store, no `docker-archive-keyring.gpg`). Since repo-swap disables Docker for the upgrade, this can't bite mid-upgrade — it's handled at Docker re-enable (Step G, Node 2).

---

## Phase 0 — One-time prep (from your laptop)

```
scp pve9-preflight.sh pve9-repo-swap.sh pve9-postcheck.sh root@<node-ip>:/root/
ssh root@<node-ip> 'chmod +x /root/pve9-*.sh'
```
On each node, get to **latest 8.4** (still bookworm), install tmux, reboot if a kernel came down:
```
apt update && apt dist-upgrade
apt install -y tmux
# reboot if the kernel updated
```
**Console access on standby** — real IPMI/physical/tmux console, **not** the web noVNC console (it dies with services mid-upgrade). NIC pinning below removes most of this risk, but keep it handy.

---

## The per-node loop (Node 1 → 2 → 3)

> Do it **inside tmux**: `tmux new -s pve9`  (re-attach: `tmux attach -t pve9`)

### Step A — Pre-flight + backup *(read-only + backups; changes no config)*
```
/root/pve9-preflight.sh
```
Wait for **`GO`**. It also runs the REV-3 sweep checks (third-party repos + keyrings, boot method via `efibootmgr`, `/etc/sysctl.conf` tunables, custom `VM.Monitor` ACL roles, NIC-pin readiness). Resolve FAILs, review WARNs. Copy the backup dir it names **off the node**.

### Step B — Pin NIC names *(do this BEFORE the upgrade, on PVE 8)*
Kernel 7.0 can rename interfaces; a stale `vmbr0` = no network on boot. Lock names now (tool is present on 8.4.20):
```
pve-network-interface-pinning generate      # run --help first if unsure of subcommand
```
Then **reboot on PVE 8** and confirm the node comes back with the pinned `nicX` names and full network (`ip -br link`, `ping` the gateway). This *decouples* the NIC risk from the upgrade — do it on **Node 1 first** so any surprise is on the empty box.

### Step C — Guests off this node *(skip on empty Node 1)*
No shared storage, so either **migrate** for zero downtime or **stop** (simpler; fine given light use):
```
qm migrate  <vmid> <other-node> --online 0     # or: qm stop  <vmid>
pct migrate <ctid> <other-node>                # or: pct stop <ctid>
```
*(If Docker/Nextcloud are installed on the host rather than in guests, they simply go down with the reboot — nothing to migrate; the vzdump in Step A already captured any guests.)*

### Step D — Repo swap *(bookworm → trixie; also parks the nag hook)*
```
/root/pve9-repo-swap.sh
```
Type `YES`. Confirm `apt update` was **error-free** and `apt policy` shows **only** Debian trixie + pve-no-subscription trixie.

### Step E — The upgrade *(interactive — you drive)*
```
apt dist-upgrade
```
Answers for a stock setup:

| Prompt | Answer |
|---|---|
| `/etc/issue` | **No** (keep) |
| `/etc/lvm/lvm.conf` | **Yes** (maintainer's) if never hand-edited |
| `/etc/ssh/sshd_config` | **Yes** (maintainer's) |
| `/etc/default/grub` | **No** (keep) unless you edited it |
| `/etc/chrony/chrony.conf` | **Yes** (maintainer's) if never hand-edited |
| "Restart services without asking?" | default is fine |
| apt-listchanges pager | press **`q`** |

Don't interrupt it — on the 5060's storage the dist-upgrade can run toward an hour.

### Step F — Reboot + post-check
```
reboot
/root/pve9-postcheck.sh
```
Green = `pveversion` 9.x, kernel 7.0, **Quorate: Yes**, no failed units, guests back, NIC names intact, and an explicit third-party `apt update` that's clean (so a SHA-1 rejection surfaces here, not on the next node). Hard-refresh the UI (**Ctrl+Shift+R**).

### Step G — Restore tweaks *(after the node is verified 9.x)*
Re-apply the nag fix (swap script prints this too):
```
cp /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js{,.bak}
sed -i "s/data.status.toLowerCase() !== 'active'/data.status.toLowerCase() === 'active'/" \
    /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js
systemctl restart pveproxy      # then Ctrl+Shift+R
```
**Node 2 only — bring Docker back on trixie WITH a fresh (non-SHA-1) key:**
```
install -m0755 -d /usr/share/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg \
  | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
# comment every old docker line, then add ONE clean trixie line pinned to the fresh key:
sed -i '/download.docker.com/ s/^deb/#deb/' /etc/apt/sources.list
echo 'deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/debian trixie stable' >> /etc/apt/sources.list
apt update && apt install --only-upgrade docker-ce docker-ce-cli containerd.io
docker ps      # confirm your container(s) came back
```
The fresh key is SHA-256-bound, so sqv accepts it. If Docker on Node 2 turns out to be Debian's `docker.io` (not `docker-ce`), tell me — different re-enable.

**Only when Node N is fully green do you start Step A on the next node.**

---

## After all three are on 9.x

- `pvecm status` on any node → all three, quorate.
- *(Optional)* `apt modernize-sources` (preview with `n`, apply with `Y`; keeps `.list.bak`).
- HA *groups* auto-migrated to HA *rules* once all nodes are 9. If HA misbehaves: `journalctl -eu pve-ha-crm`.
- `/etc/sysctl.conf`: if Step A flagged custom tunables, move them to `/etc/sysctl.d/99-custom.conf` (precautionary — Trixie may not read the legacy file) and `sysctl --system`.

---

## Rollback / if a node goes bad

**No in-place downgrade 9→8** — the canary + backups are the safety net.

- **Before dist-upgrade:** nothing irreversible. Restore `/root/apt-sources-backup-*` and you're still on 8.4.
- **dist-upgrade fails partway:** `apt -f install`, then re-run `apt dist-upgrade`. If it wants to *remove* `proxmox-ve`, a repo line is still bookworm — fix it.
- **Won't boot / no NIC:** fix at the console (Gotchas). Worst case: reinstall 9.2 on that one node and rejoin — the other two stayed up.

---

## Gotchas specific to your setup

- **NIC rename** — mitigated by Step B (pin on 8, reboot-verify). If a name still drifts: `ip -br link`, edit `/etc/network/interfaces`, `systemctl restart networking`.
- **systemd-boot meta-package** *(highest severity — wrong move = won't boot)* — pve8to9 may FAIL on it. **Do NOT blind-purge.** Confirm how you actually boot first: `efibootmgr -v` (GRUB-via-shim first = you boot GRUB, the systemd-boot pkg is vestigial). On legacy-BIOS Wyse boxes this is likely a non-issue. If unsure, stop and send me `efibootmgr -v` output.
- **SHA-1 / sqv** — only Node 2 Docker (handled in Step G). If any *other* enabled repo throws `sqv ... SHA1 is not considered secure`, refresh that vendor's key into `/usr/share/keyrings/` and add `signed-by=` — don't disable signature checking.
- **Custom ACL roles** — if Step A found `VM.Monitor` in `/etc/pve/user.cfg`, migrate those roles to `Sys.Audit` / `VM.GuestAgent.*` (renamed in 9). Empty = skip.
- **`/tmp` is tmpfs on Trixie** (≤50% RAM ≈ 8 GB here), auto-cleaned — don't park large files there.
- **Old-AMD canary** — if Node 1 throws kernel/illegal-instruction errors on boot, **stop**, leave Nodes 2/3, and send me the console output.

---

*Sources: Proxmox official "Upgrade from 8 to 9" wiki; PVE 9.2 release notes (Debian 13.5 / kernel 7.0, May 21 2026); Debian Trixie sqv SHA-1 policy (effective 2026-02-01); pve-network-interface-pinning backport to pve-manager ≥ 8.4.9. Verified Aug 22, 2026.*

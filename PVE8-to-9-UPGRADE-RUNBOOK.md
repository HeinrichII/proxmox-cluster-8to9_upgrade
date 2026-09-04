# Proxmox VE 8 → 9 Cluster Upgrade — Validated Procedures (REV 4)

**Deadline:** Aug 31, 2026 (PVE 8 EOL — confirmed against Proxmox's lifecycle table).
**Your cluster:** 3× Dell Wyse 5060, currently **PVE 8.4.20**, 16 GB RAM / 1 TB each, no shared storage.
**Target:** current Trixie repo = **PVE 9.2** — Debian 13.5, **kernel 7.0**, QEMU 11, LXC 7, ZFS 2.4.
`apt` installs whatever 9.x is current; you don't get to pin 9.0. **Reboot into the new kernel is mandatory** regardless of your prior kernel.
**Goal:** preserve cluster quorum and control-plane availability while measuring and
managing workload downtime separately. With local storage, an offline guest migration
or shutdown may take materially longer than a brief interruption.

> **Validation status:** The operational sequence was completed successfully in August
> 2026. REV 4 hardens the scripts after a retrospective review: quorum, backups,
> repositories, `apt update`, services, and networking now enforce nonzero stop
> conditions. These changes pass static and syntax checks but require canary testing
> before reuse on another cluster.

---

## Assumptions (scripts self-check these; correct me if any are wrong)

1. **No Ceph** — local storage only. Pre-flight hard-fails if it finds Ceph.
2. **No Proxmox Backup Server** co-installed.
3. **No-subscription repos** (homelab). Confirmed from your repo dump.
4. **UEFI/GRUB + ext4/LVM boot**, as observed on these nodes. If `pve8to9`
   raises a systemd-boot or ZFS-boot item, investigate the actual boot path rather
   than applying a generic package-removal fix.

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

**Local customizations:** a community customization installed `no-nag-script` as an
APT hook. `pve9-repo-swap.sh` parks it before `dist-upgrade`; restoring unsupported
UI modifications is outside this validated procedure.

- **`no-nag-script` APT hook** → parked so non-vendor code cannot run while packages
  are being configured.
- **HA services enabled** = cluster default. Pre-flight runs `ha-manager status`; **no** `service vm:`/`ct:` lines = no HA-managed guests, skip maintenance mode. If any are listed: `ha-manager crm-command node-maintenance enable <node>` before, `... disable <node>` after. (9.2 also has cluster-wide HA arm/disarm if you ever need it.)
- **`.save` / `.dpkg-old` repo leftovers** → ignored by apt (reads only `*.list` / `*.sources`). Leave them or `rm /etc/apt/sources.list.d/*.save /etc/apt/sources.list.d/*.dpkg-old`.

**Third-party repositories:** Debian and Proxmox sources are allowlisted. Docker is
disabled during the distribution upgrade and recreated afterward from Docker's current
Debian instructions. Any other enabled vendor repository is a hard stop.

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
The official guidance prefers a host-independent console such as IPMI or physical
access. This lab had SSH only, so it consciously accepted that additional risk and used
an identical empty node as the hardware canary. `tmux` protects the package process
from an SSH disconnect, but it is **not** a console and cannot recover a boot or network
failure. Do not copy this exception without a realistic recovery plan.

---

## The per-node loop (Node 1 → 2 → 3)

> Do it **inside tmux**: `tmux new -s pve9`  (re-attach: `tmux attach -t pve9`)

### Step A — Preflight + backup gate *(reads state and writes backups; changes no config)*

When guests exist, mount external backup storage and verify a restore before setting
the confirmation variable:

```
GUEST_BACKUP_DIR=/mnt/external-pve-backups \
BACKUP_RESTORE_TESTED=YES \
  /root/pve9-preflight.sh
```

On an empty node, `GUEST_BACKUP_DIR` and `BACKUP_RESTORE_TESTED` are not required.
Configuration archives remain local for convenience; guest backups must resolve to a
different mounted filesystem. Wait for **`GO`**, resolve every failure, and review all
warnings before continuing.

### Step B — Pin NIC names *(do this BEFORE the upgrade, on PVE 8)*
Kernel 7.0 can rename interfaces; a stale `vmbr0` = no network on boot. Lock names now (tool is present on 8.4.20):
```
pve-network-interface-pinning generate      # run --help first if unsure of subcommand
```
Inspect every generated `.new` configuration against its active file, including the
bridge port expected by `vmbr0`. Apply only the reviewed changes. Then **reboot on PVE
8** and confirm that the node returns with the pinned `nicX` names and full network
(`ip -br link`, `ping` the gateway). This decouples NIC risk from upgrade risk.

### Step C — Guests off this node *(skip on empty Node 1)*
There is no shared storage. The examples below use offline migration or shutdown and
therefore incur workload downtime; record the actual duration rather than calling it
zero downtime:
```
qm migrate  <vmid> <other-node> --online 0     # or: qm stop  <vmid>
pct migrate <ctid> <other-node>                # or: pct stop <ctid>
```
*(If Docker/Nextcloud are installed on the host rather than in guests, they simply go down with the reboot — nothing to migrate; the vzdump in Step A already captured any guests.)*

### Step D — Repo swap *(bookworm → trixie; also parks the nag hook)*
```
/root/pve9-repo-swap.sh
```
Type `YES`. The script refuses unknown third-party sources, refuses enabled Bookworm
entries, and exits nonzero unless `apt update` succeeds. Review `apt policy` before
continuing.

### Step E — The upgrade *(interactive — you drive)*
```
apt dist-upgrade
```
Answers for a stock setup:

| Prompt | Answer |
|---|---|
| `/etc/issue` | **No** (keep) |
| `/etc/lvm/lvm.conf` | **Yes** (maintainer's) if never hand-edited |
| `/etc/ssh/sshd_config` | **Inspect the diff.** Use the maintainer version only when the differences are the expected deprecated-option/comment changes and remote access remains valid. |
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
Exit status 0 and `PASS` require PVE 9, **Quorate: Yes**, active core services,
no failed units, working networking, and a successful `apt update`. Application-level
guest health still requires human verification. Hard-refresh the UI (**Ctrl+Shift+R**).

### Step G — Restore required services *(after the node is verified 9.x)*

Do not restore the parked third-party APT hook as part of the upgrade procedure.

**Node 2 only — recreate Docker's repository using the current vendor format:**

```
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg \
  -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

cat > /etc/apt/sources.list.d/docker.sources <<'EOF'
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: trixie
Components: stable
Architectures: amd64
Signed-By: /etc/apt/keyrings/docker.asc
EOF

apt update && apt install --only-upgrade docker-ce docker-ce-cli containerd.io
systemctl start docker
docker ps
```

This follows Docker's current Debian repository layout. If the node uses Debian's
`docker.io` instead of Docker CE, do not add Docker's vendor repository.

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

- **Before dist-upgrade:** restore the timestamped `/root/apt-sources-backup-*`
  configuration and re-run `apt update`; the node is still on 8.4 packages.
- **dist-upgrade fails partway:** `apt -f install`, then re-run `apt dist-upgrade`. If it wants to *remove* `proxmox-ve`, a repo line is still bookworm — fix it.
- **Won't boot / no NIC:** SSH cannot recover this. Attach a physical console or boot
  rescue media; if recovery requires travel or new hardware, that is real recovery
  time. Worst case, reinstall that node, rejoin it, and restore guests from external
  backups while the other two nodes retain quorum.

---

## Gotchas specific to your setup

- **NIC rename** — mitigated by Step B (pin on 8, reboot-verify). If a name still drifts: `ip -br link`, edit `/etc/network/interfaces`, `systemctl restart networking`.
- **systemd-boot meta-package** *(highest severity — wrong move = won't boot)* —
  `pve8to9` may flag it. **Do not blind-purge.** Confirm the actual UEFI boot path with
  `efibootmgr -v` and follow the checker/official upgrade guidance.
- **Repository signature rejection** — Docker on Node 2 was the historical case and is
  handled in Step G. If another vendor repository fails verification, disable it and
  follow that vendor's current keyring instructions; never disable signature checking.
- **Custom ACL roles** — if Step A found `VM.Monitor` in `/etc/pve/user.cfg`, migrate those roles to `Sys.Audit` / `VM.GuestAgent.*` (renamed in 9). Empty = skip.
- **`/tmp` is tmpfs on Trixie** (≤50% RAM ≈ 8 GB here), auto-cleaned — don't park large files there.
- **Old-AMD canary** — if Node 1 throws kernel/illegal-instruction errors on boot, **stop**, leave Nodes 2/3, and send me the console output.

---

## Sources

- [Proxmox VE: Upgrade from 8 to 9](https://pve.proxmox.com/wiki/Upgrade_from_8_to_9)
- [Proxmox VE 9.2 release announcement](https://forum.proxmox.com/threads/proxmox-virtual-environment-9-2-available.183741/)
- [Proxmox network-interface pinning](https://pve.proxmox.com/wiki/Network_Configuration#network_override_device_names)
- [Docker Engine on Debian](https://docs.docker.com/engine/install/debian/)
- [Debian 13 release notes](https://www.debian.org/releases/trixie/release-notes/)

Source guidance last reviewed August 22, 2026; safety-gate revision completed
September 4, 2026.

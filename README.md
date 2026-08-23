# Rolling Proxmox VE 8 → 9 Cluster Upgrade (Zero Cluster Downtime, Headless)

Upgrading a live 3-node Proxmox VE cluster from **8.4 → 9.2** — across a major
Debian release (12 *Bookworm* → 13 *Trixie*) and a new kernel (**7.0**) — one node
at a time, with the cluster staying quorate throughout and each node accessed
**only over SSH** (no physical console, no IPMI).

**Outcome:** all three nodes upgraded, verified, and cleaned up. Cluster never lost
quorum. No data loss. No node required a physical rescue despite being headless.

---

## Why this was non-trivial

This wasn't a single-host reinstall. The constraints are what made it interesting:

- **It's a cluster.** Nodes must be upgraded individually while the remaining nodes
  hold quorum. Take two down at once and the cluster filesystem (`/etc/pve`) goes
  read-only. The whole procedure is built around never dropping below 2-of-3 votes.
- **It's a major-version jump.** 8→9 rides on top of Debian 12→13, so it's a full OS
  distribution upgrade *and* a hypervisor upgrade at the same time — new kernel, new
  apt signature tooling, changed config-file defaults.
- **The hardware is old and headless.** Three Dell Wyse 5060 thin clients (AMD
  GX-424CC SoC, ~2016-era). No monitor attached, no out-of-band management. If a
  network interface got renamed on the new kernel, the node would boot with no
  network and no way back in — so every network change had to be de-risked *before*
  the point of no return.
- **There is no in-place downgrade.** Once a node is on 9, it stays on 9. Every step
  had to be reversible *up to* a clearly-marked one-way gate, with backups taken
  first.

## Environment

| | |
|---|---|
| Cluster | 3 nodes (`pve1`/`pve2`/`pve3`), quorum-based |
| Hardware | Dell Wyse 5060 · AMD GX-424CC · 16 GB RAM · 1 TB · legacy-BIOS→**UEFI/GRUB** boot |
| Storage | Local only (LVM-thin) — **no shared storage, no Ceph cluster** |
| From | PVE 8.4.x / Debian 12 / kernel 6.8 |
| To | **PVE 9.2 / Debian 13.5 / kernel 7.0** (QEMU 11, LXC 7, ZFS 2.4) |
| Access | SSH only, headless |
| Workloads | A NextcloudPi VM; a handful of dormant Docker containers |

## Method

A few principles drove the design, encoded into the scripts and runbook:

1. **Canary first.** The emptiest node was upgraded first. Because all three boxes are
   identical hardware, a clean boot on the new kernel there de-risked the other two —
   it answered the biggest unknown (does an 11-year-old AMD SoC boot kernel 7.0?) at
   zero cost.
2. **One node at a time, quorum preserved.** Never two nodes down simultaneously.
3. **Verify before committing, especially on the network.** NIC name pinning was
   generated, then the config was diffed against what the bridge expected, then applied
   *live* (`ifreload -a`) to prove it worked while still reachable — and only then
   carried through a reboot. The riskiest headless step was made observable before the
   irreversible one.
4. **Gate the one-way step.** Backups + the official `pve8to9 --full` checker had to
   pass clean before the repository swap; the swap's `apt update` had to be error-free
   before `apt dist-upgrade`.
5. **Automate the mechanical, keep judgment human.** Scripts handle checks, backups,
   and repo rewrites. The interactive `dist-upgrade` (with its config-file prompts) is
   driven by hand, inside `tmux` so a dropped SSH session can't kill it mid-flight.

## Per-node sequence

```
pre-flight (checks + backup)  →  GO
  → GRUB-EFI fix              (bootloader gap, see below)
  → pin NIC name             (generate → verify → ifreload → reboot-verify on 8)
  → guests off               (stop/insulate workloads)
  → repo swap                (bookworm → trixie, deb822, keys, nag hook parked)
  → apt dist-upgrade         (interactive, inside tmux)
  → reboot into kernel 7.0
  → post-check               (version / quorum / services / NIC / apt clean)
  → restore tweaks           (nag fix; Docker re-enable where applicable)
```

Run order: **canary → Docker node → app (Nextcloud) node.**

## Gotchas encountered and how they were handled

The parts that don't show up in a tidy tutorial — the actual friction, and the fix:

- **NIC rename on the new kernel (headless-fatal risk).** Kernel 7.0 can rename
  interfaces; a stale `vmbr0` bridge port = a node with no network and no console to
  fix it. Solved with `pve-network-interface-pinning` (backported to `pve-manager
  ≥ 8.4.9`) to lock the name to the MAC *before* upgrading, then a verify-reboot on the
  old OS to confirm the node returns on the pinned name — decoupling the NIC risk from
  the upgrade risk entirely. Held on all three.

- **UEFI/GRUB bootloader gap.** `pve8to9` flagged that the system boots UEFI via GRUB
  but `grub-efi-amd64` wasn't installed, so future GRUB updates wouldn't reach the EFI
  partition — a latent "won't boot someday" trap. Fixed proactively on every node
  before upgrading.

- **Debian 13 `sqv` / SHA-1 key rejection.** Trixie's apt verifies signatures with
  `sqv` and rejects SHA-1-bound keys (effective 2026-02-01). Scoped it precisely: the
  Debian and Proxmox keyrings were already modern, so the core upgrade was unaffected —
  the only exposure was a third-party Docker repo whose legacy key would be rejected.
  Handled by disabling that repo during the upgrade and re-adding it on the far side
  with a fresh, SHA-256 key pinned via `signed-by=`.

- **Dormant Ceph client libraries triggering a false alarm.** A blunt "is Ceph present?"
  check failed because leftover Ceph *client* libraries were installed — but there was
  no Ceph *cluster*: no daemons, no OSD/MON data, no Ceph storage. Verified the
  distinction and corrected the check to fail only on a real deployment, so the harmless
  libraries just ride along in the upgrade.

- **`apt install` dragging in the OS upgrade.** Installing a tool *after* switching to
  the trixie repos pulled part of the distribution upgrade early (including glibc).
  Fixed the ordering: install prerequisites like `tmux` **before** the repo swap, while
  still on the old release.

- **Enterprise repo re-appearing as deb822.** PVE 9 ships an enterprise repo entry in
  the newer `.sources` (deb822) format, which the older `.list`-oriented cleanup didn't
  catch — causing a `401 Unauthorized` on `apt update` post-upgrade. Disabled it with
  `Enabled: false` on each node.

- **Subscription-nag re-patch across the upgrade.** A community post-install nag-removal
  patch (and its APT hook) was present. The hook was parked before the upgrade so it
  couldn't fire mid-`dist-upgrade`, and the patch re-applied cleanly on 9 afterward.

## Verification

Each node was confirmed via the bundled post-check and the official checker:

- `pveversion` → **9.2.x**, `uname -r` → **7.0.x**
- `pvecm status` → **Quorate: Yes**, all three members present
- No failed systemd units; core PVE services active
- Pinned NIC (`nic0`) up, bridge and IP intact
- `apt update` clean — **no signature/SHA-1 rejections**
- `pve8to9 --full` → **0 failures** (only the optional `amd64-microcode` advisory,
  since resolved by installing it from `non-free-firmware`)

## Post-upgrade cleanup

Finished means finished — the cluster was left tidy, not just working:

- Installed `amd64-microcode` on all nodes (clears the last checker advisory).
- Disabled the unauthenticated enterprise repo on all nodes.
- Removed ~2 GB of years-old unused Docker containers/images cluster-wide; left Docker
  Engine installed but stopped and disabled at boot.
- Re-applied the UI nag fix on each node.
- Deliberately **left** the old fallback kernels in place (prune after a stability
  window) and ignored cosmetic advisories (LVM autoactivation notice on local storage,
  legacy-format RRD files) that the checker itself rates as harmless.

## Repository contents

| File | Purpose |
|---|---|
| `PVE8-to-9-UPGRADE-RUNBOOK.md` | The full step-by-step runbook, with per-node sequence, config-prompt answers, rollback guidance, and hardware-specific gotchas. |
| `pve9-preflight.sh` | Non-destructive pre-flight: version/space/quorum checks, config + guest backup, runs `pve8to9 --full`, plus audits (keyrings, boot method, NIC-pin readiness). GO/NO-GO verdict. |
| `pve9-repo-swap.sh` | Rewrites repos bookworm→trixie (deb822, correct signing key), disables third-party/enterprise repos for the upgrade, parks the nag hook. Interactive confirmation + `apt update` verification. |
| `pve9-postcheck.sh` | Post-reboot verification: version, kernel, quorum, failed units, NIC names, explicit `apt update` (catches signature rejections). |

## Skills demonstrated

Cluster administration under availability constraints · major-version OS/hypervisor
migration · risk sequencing and reversibility design · working on headless/remote
infrastructure · Debian/apt internals (deb822, signing keys, `sqv`) · shell scripting
with real validation · methodical troubleshooting and honest scoping of alarms vs. real
problems.

---

*Homelab project. All addresses shown are RFC-1918 private. No credentials or secrets
are included in this repository.*

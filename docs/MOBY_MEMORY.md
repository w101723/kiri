# Kiri Moby adaptive memory, Apple Silicon

This branch implements a *safe, online* guest-memory governor in the existing
Virtualization.framework backend. It is **not** yet OrbStack-equivalent on
macOS. Apple's VZ balloon can reduce the Guest memory target, but host resident
memory may remain high after Guest pages are freed.

## Implemented

- Linux Guest serves read-only MemTotal/MemAvailable/Cached samples over a
  private AF_VSOCK:2378; the standard Docker API stays byte-transparent.
- The Host polls every ~2 seconds **off the Docker API accept thread**. It
  cautiously lowers the balloon target by up to 256 MiB per sample after
  three stable samples. The live-VM floor remains 1 GiB, the estimated reserve
  is 768 MiB, and shrink never leaves less than 512 MiB Guest MemAvailable.
  This fixes a measured post-container idle dead zone at target 1536 MiB:
  the older 1 GiB headroom + full-step requirement could refuse any further
  reduction despite ~279 MiB estimated live use.
- Docker stop/die/destroy/oom events ask for an immediate memory sample when
  the normal event/port watcher is active; a full low-frequency scan remains
  the fallback. The actual reduction still requires safe Guest headroom.
- Guest low-memory pressure (<512 MiB MemAvailable) expands the target promptly;
  Docker Engine and its running containers are never deliberately restarted.
  New regression tests exercise captured Apple Silicon post-container memory
  statistics (1536 -> 1280 -> 1047 MiB) and rapid pressure reinflation.
- Under low Guest MemAvailable, the Host expands the target promptly. Max
  remains KIRI_MOBY_MEMORY_MIB (default 4096), floor 1024 MiB.
- Telemetry loss never drives the balloon blindly; VM stays online and Docker
  container restart policies are untouched.
- Local user can query the current balloon target and Guest memory on
  ~/.kiri-moby/run/host-control.sock using STAT + newline (macOS nc -U).
  host_reclaimed_bytes is null until actual macOS physical reclamation can be
  measured; do not confuse balloon target with Mac Task Manager memory.
- Reduce Guest dentry/inode cache retention via vfs_cache_pressure while
  keeping Docker build/file caches otherwise intact.
- Unit tests for parser, malformed samples, floor, conservative shrink and
  rapid recovery. A Mac smoke script samples RSS across a 256 MiB tmpfs
  allocation and release; it does **not** assume VZ returns RAM to macOS.

Opt out without reverting the code: KIRI_MOBY_MEMORY_POLICY=off on the Host.
Turn off on production workloads if large instantaneous allocations OOM before
the next sample. A governor cannot prevent every guest OOM.

## 2026-11-20: captured Mac post-container regression

An empty Docker `ps` after creating/removing several containers showed the
Apple VZ virtualization service at 684.6 MB (previous idle screenshot 440.5
MB). The local control endpoint returned:

```json
{"balloon_target_mib":1536,"guest_total_kib":4030296,"guest_available_kib":1123264,"host_reclaimed_bytes":null}
```

At the default 4096 MiB ceiling, balloon inflation accounts for 2560 MiB.
The estimated working set is `4030296/1024 - 1123264/1024 - 2560`,
roughly 279 MiB. The old governor's contraction predicates required both
`desired + 256 < target` and `available > 1280`: both were false, so the
guest could remain stuck at 1536 MiB indefinitely. The new policy uses a
768 MiB reserve, 128 MiB hysteresis, partial-step contraction and a
post-shrink 512 MiB safety floor. Simulation of **this** telemetry predicts
a target of about 1047 MiB, but only a real Mac retest can establish a
decrease in Activity Monitor's physical-memory figure.

The user must compare `STAT` before/after an idle interval and macOS
virtualization service resident memory. This is **not a measured memory win**
and is **not a change of VMM backend**.

## What is still needed for OrbStack-like memory return

Apple documents that VZ's balloon support is partial and released Guest RAM
may not return to the macOS host. Real host reclamation should be measured
by Activity Monitor / macOS memory pressure before claiming success.

libkrun has a different Hypervisor.framework backend and a Mac free-page
reporting "Replace" mode. Integrating it is **not** a drop-in memory tweak:
the current Kiri guest relies on VZ's NAT NIC, block disk, Rosetta,
virtiofs, vsock and lifecycle. Switching to libkrun without exercising
these would break the existing verified Docker/Compose/Buildx GUI.

The libkrun research and cross-backend acceptance matrix are in
docs/MOBY_LIBKRUN_MEMORY.md. This change intentionally does not introduce
an untested VMM switch into the user-visible App.

## Verify (on an actual Apple Silicon Mac)

1. Build a matching Host+Guest artifact from the same commit; older Guest
   versions don't expose AF_VSOCK:2378.
2. Run Kiri Moby. Check the Host log for "balloon target".
3. Run scripts/moby/measure-memory-macos.sh --stress (after pulling alpine:3.22). Compare Guest target,
   macOS Resident Set Size and macOS memory pressure; only RSS/pressure
   show whether physical memory really returned.
4. Stress test Compose, multi-architecture Buildx and allocation bursts
   before calling the change production-ready.

## Low-memory boot redesign (memory-reclaim branch)

The old full Alpine + Docker userspace initramfs caused boot-time inflation and
then copied the userspace into an ext4 disk **every single boot**. This is a
plausible source of elevated Mac RSS, but remains unverified until Mac sampling.

The new pipeline moves Alpine, dockerd, containerd and the guest bridge onto a
prepopulated persistent ext4 disk. The initial RAM filesystem contains only
BusyBox, musl and the first-stage init. The VM also attaches a second,
read-only ext4 seed disk for one-time userspace updates on existing installs.

- `/dev/vda` is the **same existing persistent data.img**. Docker images,
  volumes and container metadata under /var/lib are preserved; never erase it.
- `/dev/vdb` is the sealed read-only system.img seed. The stage1 init
  compares .kiri-moby-rootfs-revision and copies only on first migration or an
  explicit upgrade. The revision stamp is committed after a successful sync.
- Newly provisioned data.img comes **prepopulated** with the same rootfs stamp,
  so every normal start can switch_root directly without a userspace copy.
- The host caches system.img by revision. Upgrades to an existing system image
  do not touch the data.img outside the Linux guest and do not touch OrbStack.
- The new required Guest assets are `system.img.tgz` and
  `rootfs.revision`, plus existing `Image`, `initramfs.cpio`,
  `data.img.tgz`, `SHA256SUMS`. Use a matching same-commit Host and Guest.
- **First boot on an old installed disk still needs a one-time OS copy**;
  subsequent boots should log `Userspace already current; no rootfs copying`.
- Compare the CI initramfs size, macOS process RSS, Guest `MemAvailable`,
  slab, and VM pressure to test the 800 MiB idle hypothesis. We have not yet
  established 100-200 MiB as measured Kiri host RSS.

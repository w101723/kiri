# Kiri Moby adaptive memory, Apple Silicon

This branch implements a *safe, online* guest-memory governor in the existing
Virtualization.framework backend. It is **not** yet OrbStack-equivalent on
macOS. Apple's VZ balloon can reduce the Guest memory target, but host resident
memory may remain high after Guest pages are freed.

## Implemented

- Linux Guest serves read-only MemTotal/MemAvailable/Cached samples over a
  private AF_VSOCK:2378; the standard Docker API stays byte-transparent.
- The Host polls every ~2 seconds **off the Docker API accept thread**. It
  cautiously lowers the balloon target in 256 MiB increments, after three
  stable samples, preserving at least 1 GiB of estimated headroom.
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
3. Run scripts/moby/measure-memory-macos.sh. Compare Guest target,
   macOS Resident Set Size and macOS memory pressure; only RSS/pressure
   show whether physical memory really returned.
4. Stress test Compose, multi-architecture Buildx and allocation bursts
   before calling the change production-ready.

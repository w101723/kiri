# libkrun macOS host memory reclamation integration gate

## Why this is a separate backend

The existing VZ implementation uses Apple Virtualization.framework.
Linux Guest CONFIG_VIRTIO_BALLOON and CONFIG_PAGE_REPORTING are already on,
but VZ provides only partial memory reclamation: reducing Guest
MemAvailable/balloon target does not prove macOS process RSS declined.

As of November 2026, libkrun has a macOS-specific free-page reporting
Replace mode that replaces reported Guest RAM mappings to release physical
pages. This capability is absent in Apple's VZ traditional balloon device.

Sources:
- https://github.com/apple/container/blob/main/docs/technical-overview.md
- https://github.com/libkrun/libkrun/blob/main/include/libkrun.h
- https://github.com/libkrun/libkrun/blob/main/docs/vm-lifecycle.md

libkrun's main branch has introduced a non-backward-compatible 2.0 API.
A reliable integration must pin the version and verify the exact API, signing,
entitlements, and platform support in macOS CI.

## Required acceptance before switching the default backend

1. Boot the existing persistent data.img **without conversion or deletion**.
   Only one process may own writable ext4 disk at once.
2. Start stock dockerd/containerd/runc; support private Docker Unix socket,
   streaming exec/attach, container events and Docker auth.
3. Guest NAT and Mac localhost published TCP port behavior must match VZ.
   Verify UDP separately instead of silently claiming support.
4. Match per-directory Mac VirtioFS allowlist; never share all /Users.
5. Native arm64 containers AND Rosetta linux/amd64 containers.
6. Compose/Buildx ARM64 and AMD64 and volume persistence after VM restart.
7. Guest >=2 GiB allocation then release with VM still running; measure
   macOS host physical resident pages and memory pressure. Require clear
   decrease, with sustained idle and under pressure, without OOM.
8. Repeated sleep/wake, stop/start, fault injection, and VM disk integrity.
9. Package licenses, pinned libkrun version and runtime dependencies in App.

Until these gates pass, retain the working VZ backend. The adaptive governor
is a safe partial improvement, not the same as OrbStack's host reclamation.

## Experimental v2 capability probe (no VM boot)

An independent, non-production C probe is included at
`scripts/moby/libkrun2-memory-probe.c`. It compiles without new dependencies
and requires an explicit absolute path to a locally trusted/pinned libkrun 2.x
library at runtime. It only checks the exported API for free-page reporting
and an external-kernel boot; it does not write a disk, boot a guest, or prove
RAM reclamation. Use `clang -std=c11 -Wall -Wextra -Werror -arch arm64 -o
/tmp/kiri-libkrun-probe scripts/moby/libkrun2-memory-probe.c` and run with an
absolute dylib path. Never load unverified third-party dylibs in the GUI.

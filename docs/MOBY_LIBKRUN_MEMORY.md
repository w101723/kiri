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

# Isolated libkrun2 RAM lab (never the production Kiri VM)

The optional \`scripts/moby/libkrun2-ram-lab.c\` is a **real experimental
libkrun 2.x VMM runner**, not just a symbol probe. It creates a 2-GiB MMIO
guest without any persistent block disk, Docker socket, networking, host
share, or production context. The Balloon uses
\`KRUN_FREE_PAGE_REPORTING_MODE_REPLACE\` (value 1), as defined in pinned
libkrun source SHA \`3d0e61d1293f39562f757cf45ae6673cf2663100\`
(2026-11-19). It requires a locally trusted matching ARM64 library.

Build on Apple Silicon (or cross-compile using Xcode SDK):

\`\`\`sh
clang -std=c11 -Wall -Wextra -Werror -arch arm64 \
  -o /tmp/kiri-libkrun-ram-lab scripts/moby/libkrun2-ram-lab.c
\`\`\`

Run with **separately constructed throwaway kernel/initramfs** and an
independently pinned, trusted \`libkrun.dylib\`:

\`\`\`sh
/tmp/kiri-libkrun-ram-lab \
  /absolute/path/to/libkrun.dylib \
  /absolute/path/to/mmio-enabled/Image \
  /absolute/path/to/memory-lab-initramfs.cpio
\`\`\`

Important:
- Kiri's production kernel does **not** currently enable
  \`CONFIG_VIRTIO_MMIO\`; its \`CONFIG_VIRTIO_PCI=y\` alone is insufficient.
  Build a separate kernel enabling \`CONFIG_VIRTIO_MMIO=y\` without modifying
  the tested Moby kernel or existing ext4 data disk.
- **Do not pass the Kiri Moby Guest initramfs** to this lab: its PID1 requires
  /dev/vda and would fail. Use a dedicated RAM-only init that mounts /proc,
  devtmpfs, sysfs, then allocates/touches/frees 256 MiB and sleeps so host RSS
  can be measured.
- This runner is off by default and not integrated into the GUI. Loading a
  dylib may execute library constructors; never load arbitrary files.
- macOS code-signing/HV entitlement requirements and physical return of
  pages have not been verified on actual Apple Silicon.
- Check host RSS and memory pressure, not merely the guest's MemAvailable
  nor a VMM-configured memory target.
- After independently validating real host reclamation, full backend parity
  with VZ (VirtioFS, Rosetta x86_64, NAT/port publishing, vsock transport,
  graceful shutdown, same-commit packaging) is still needed before the GUI
  engine can switch over.


## RAM-only memory A/B lab (memory-reporting-lab branch)

This branch adds a **separate experimental Guest build** and a macOS Physical
footprint sampler. Production Kiri Moby VZ, Docker Engine, rootfs and user
Docker data are unchanged.

GitHub Actions workflow: .github/workflows/moby-libkrun-lab.yml.

Download these two artifacts:
- experimental-libkrun2-guest-mmio-arm64: Image, initramfs.cpio,
  kernel.config and SHA256SUMS. Its throwaway ARM64 kernel includes
  CONFIG_VIRTIO_MMIO, CONFIG_VIRTIO_BALLOON and CONFIG_PAGE_REPORTING.
  Its initramfs is just BusyBox/musl and a RAM-only /init; no persistent disk.
- experimental-libkrun2-ram-lab-arm64: signed ARM64 lab runner, capability
  probe and measure-libkrun-lab-macos.sh.

**Important prerequisite:** neither artifact bundles libkrun.dylib.
Supply a separately trusted libkrun v2.x Apple Silicon library. Homebrew
libkrun 1.x is not ABI-compatible with this v2 experiment.

### Obtain the library from a pinned source revision

The C ABI in the experimental code was authored against libkrun commit
3d0e61d1293f39562f757cf45ae6673cf2663100. Verify that upstream revision
and its prerequisites before compiling; do not use a moving main branch.
The upstream macOS build guide describes Rust, the Linux musl target, lld and
xz. An isolated checkout can start as follows:

    git clone https://github.com/libkrun/libkrun.git /tmp/kiri-libkrun-v2
    cd /tmp/kiri-libkrun-v2
    git checkout 3d0e61d1293f39562f757cf45ae6673cf2663100
    rustup target add aarch64-unknown-linux-musl
    make

Additional build dependencies may be required. No tool in this branch
automatically installs these dependencies on the user's Mac. Never load an
untrusted library just to test memory recovery.

### Run Default vs Replace under identical conditions

Extract both workflow artifacts to local absolute paths. Verify the Guest's
SHA256SUMS, then execute the capability probe:

    /absolute/runner/kiri-libkrun2-symbol-probe /absolute/trusted/libkrun.dylib

Run the exact same Guest and library twice, with each mode:

    KIRI_LIBKRUN_REPORTING_MODE=default bash scripts/moby/measure-libkrun-lab-macos.sh \
      /absolute/runner/kiri-libkrun2-ram-lab /absolute/trusted/libkrun.dylib \
      /absolute/guest/Image /absolute/guest/initramfs.cpio

    KIRI_LIBKRUN_REPORTING_MODE=replace bash scripts/moby/measure-libkrun-lab-macos.sh \
      /absolute/runner/kiri-libkrun2-ram-lab /absolute/trusted/libkrun.dylib \
      /absolute/guest/Image /absolute/guest/initramfs.cpio

Each call produces a timestamped guest.log plus footprint.csv, sampling
the actual libkrun PID via vmmap -summary every four seconds for 112 seconds.
The RAM-only Guest emits READY, ALLOCATING, ALLOCATED and FREED milestones.

For a useful result: compare the Physical footprint before allocation,
after allocating/touching 256 MiB, and after Guest frees it, for both modes.
The Replace mode should show a repeatable drop not seen in Default. Check
macOS compression/swap effects too. Startup failure, missing milestones or
empty vmmap values are not evidence. This lab proves neither 200 MB idle
Docker VM nor Docker/Compose/Buildx parity by itself.

## 2026-11-20 Apple Silicon A/B result: isolated RAM recovery verified

The owner ran the separately built, RAM-only MMIO Guest (2 GiB configured)
against the same locally compiled libkrun 2.x dylib, switching only
`KIRI_LIBKRUN_REPORTING_MODE`:

| vmmap Physical footprint | Default | Replace |
| --- | ---: | ---: |
| Guest READY, before allocation | ~97.4 MB | ~97.5 MB |
| After 256 MiB tmpfs allocation | ~351.9 MB | ~355.1 MB |
| Immediately around Guest FREED marker | ~352.0 MB | ~355.4 MB |
| Stable after free | ~352.2 MB | ~113.3 MB |

Both runs emitted all mandatory Guest milestones:
`KIRI-LIBKRUN-MEMLAB READY`, `ALLOCATING`, `ALLOCATED`, and `FREED`.
The Replace footprint decreased from 355.4 MB to 113.3 MB, a ~242 MB
physical-footprint decrease, and stayed close to 113.3 MB. Default remained
around 352 MB after free. This is strong, phase-aligned evidence of Guest-to-Host
page reclamation without shutting down the VM. It does **not** prove an
idle Docker VM can reach 113 MB or the 200 MB product target.

Earlier runs captured only runner stderr, not Guest milestones: libkrun's
non-TTY hvc0 output is routed through the libkrun logger. The runner now calls
`krun_init_log` before creating the virtual console, and the sampler rejects
runs without all four milestones. Some Guest log lines contain CR, so the
sampler also normalizes phase names before writing `footprint.csv`.
The first successful measurements were saved locally as
`~/kiri-lab/default-v2` and `~/kiri-lab/replace-v2`;
`default` and `replace` are the older *invalid* phase-less runs.

**Next experimental gate:** bring up the *stock Docker Engine* on a separate
throwaway libkrun Guest with block-device persistence, NAT/port forwarding,
vsock, per-folder VirtioFS and amd64 emulation parity. Do **not** replace
production Apple VZ or attach the original writable `~/.kiri-moby` data disk
until the complete gates above have been verified on a disposable copy.


## Adaptive-memory stage: cold anonymous pages in the RAM-only lab

The independent adaptive-memory-lab branch extends the verified 256 MiB
*free-after-use* experiment. New question: can a still-running process
retain anonymous pages, compress them to Guest zram, release their Host
physical mappings, and fault them back without data loss?

The isolated MMIO kernel adds CONFIG_ZRAM=y, CONFIG_ZRAM_BACKEND_LZ4=y,
and CONFIG_ZRAM_DEF_COMP_LZ4=y. The production Kiri VZ kernel, Docker,
GUI and data.img remain unchanged.

KIRI_LIBKRUN_WORKLOAD=anon-zram adds the kernel arguments
zswap.enabled=0 and kiri.lab.workload=anon-zram. The throwaway Guest
disables zswap to avoid it intercepting swap writes before the 768 MiB
zram device can measure them.

The Guest starts a static C test process that:
1. Writes 384 MiB anonymous RAM while retaining its mapping.
2. Invokes MADV_PAGEOUT explicitly.
3. Checks that at least 64 MiB of zram swap is occupied, and logs mm_stat.
4. Holds the process/mapping alive through ANON_IDLE.
5. Faults and validates three locations on each page, then logs ANON_RESTORED.
6. Frees the mapping, logs ANON_FREED, and stays alive.

**Scope:** MADV_PAGEOUT is a deliberate request by the synthetic process;
it is NOT a production idle page-scanner for ordinary Docker containers.
zram uses some RAM to retain compressed pages. The macOS compressor counter
is global, not attributable specifically to Kiri. This stage does not
implement Docker engine integration or background policies.

### Run with freshly built artifacts

Get both experimental-libkrun2-guest-mmio-arm64 and
experimental-libkrun2-ram-lab-arm64 from a successful
adaptive-memory-lab workflow. Both artifacts have changed; do not reuse
the earlier 256 MiB-only Guest and runner. Reuse the locally trusted
libkrun v2 dylib from the successful memory-reporting experiment.

    LAB="$HOME/kiri-lab"
    LIB="$LAB/libkrun/target/release/libkrun.dylib"
    for mode in default replace; do
      KIRI_LIBKRUN_REPORTING_MODE="$mode" \
      KIRI_LIBKRUN_LAB_RESULTS="$LAB/cold-anon-$mode" \
      bash "$LAB/runner/measure-libkrun-cold-anon-macos.sh" \
        "$LAB/runner/kiri-libkrun2-ram-lab" "$LIB" \
        "$LAB/guest/Image" "$LAB/guest/initramfs.cpio"
    done

The host sampler collects 45 four-second samples per mode (~3 minutes),
then stops the VM automatically. Logs are guest.log and host-memory.csv
with the exact VM process footprint, RSS and global macOS compressor
page count. Missing Guest phases, insufficient swap, early exit and
unavailable Host samples are **invalid runs**, not accepted evidence.

Success requires meaningful swap usage while the mapping remains alive,
a sustained Host footprint/RSS drop in Replace relative to Default,
correct restoration of all bytes, and stable operation. Even success
does NOT establish automatic cold-process reclaim. The next experiment
must separately validate an activity-gated, rate-limited cgroup reclaim
controller and its effect on real Docker workloads before product use.

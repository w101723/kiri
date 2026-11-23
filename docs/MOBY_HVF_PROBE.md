# Kiri Moby HVF — local macOS 27 build

The local Apple Silicon build runs the VM inside `Kiri Moby Helper.app`. The
Helper loads libkrun into its own process and executes the vCPUs using Apple's
public [Hypervisor.framework](https://developer.apple.com/documentation/hypervisor).
There is no `Virtualization.framework` backend, Apple Virtualization worker or
separate VMM/network proxy in this build. libslirp provides IPv4 DHCP/DNS/NAT in
that process; dockerd and containerd still run inside Linux. The engine comes only from the app bundle injection; the seed ships no engine and the guest fails closed without the tag.

The GUI starts its bundled Helper on demand. The Helper holds `moby-vm.lock`,
checks and installs bundled Guest assets, reads CPU/RAM and approved directory
settings, opens the VM disks, and exposes Docker and control Unix sockets. Its
lifetime is one VM session: closing the GUI leaves the VM running; clean Guest
poweroff ends the Helper. A stop timeout exits the Helper but is recorded as a
forced stop, not a confirmed disk sync. Files and Docker context from the older
VZ app are not used. The local build defaults to `~/.kiri-moby-hvf`; use an
explicit, dedicated `KIRI_MOBY_DATA_DIR` for tests. Newly created
`vm/data.img` disks are Btrfs (with `docker`, `machines`, and `k8s`
subvolumes); `vm/system.img` remains a read-only ext4 seed. An existing
ext4 data disk continues to boot without being reformatted. Linux Machines
are unavailable on that legacy layout until an explicit migration is
implemented; do not delete the old disk to enable them.

## Build the local app

Use Apple Silicon running **macOS 27**, Xcode, Rust/Cargo, `uv`, `pkg-config`,
Python 3 and GLib discoverable by `pkg-config`. The local bundle is ad-hoc
signed, uses this Mac's GLib from Homebrew, and is not a notarized redistributable
artifact. It does not require a macOS 14 build or test machine.

1. Build the Guest assets with `scripts/moby/build-guest.sh` on Linux ARM64.
   The seed must include `scripts/moby/guest/init` with per-directory virtiofs.
   Build `Image` from `guest/kernel/build.sh` with `CONFIG_VIRTIO_MMIO=y` and add
   its hash to the Guest `SHA256SUMS`. When building the kernel in a container
   on macOS, create `/build` inside the container's case-sensitive filesystem;
   mount only the kernel configuration and the output directory.
2. Assemble and sign the local app. The existing signed app is read only for
   the Docker CLI, its plugins and the icon; it is not copied over or updated:

   ```sh
   bash scripts/moby/build-hvf-app-macos.sh /path/to/verified/guest-assets \
     '/Applications/Kiri Moby.app'
   ```

3. Open the `Kiri Moby HVF.app` printed by the build script, or run the isolated
   Helper acceptance test first:

   ```sh
   bash scripts/moby/smoke-hvf-app-macos.sh '/path/to/Kiri Moby HVF.app'
   ```

The acceptance test uses new disks under `/tmp`, the bundled CLI pointed at the
private socket, and temporary published ports. It covers the disk lock, resource
settings, online ARM64 image pull, stdin EOF and attached stdout, bidirectional
PTY, bundled Compose and Buildx, localhost TCP publish/release, graceful stop,
restart, and a persistent named volume. Run `scripts/moby/smoke-hvf-gui-macos.sh`
with the app path to verify that the GUI starts the Helper and can exit and
reconnect to the same Helper PID. Optionally set `KIRI_HVF_QA_SHARE` to an authorized test directory
under `/Users` or `/Volumes` containing a `kiri-hvf-share-token` file to verify
per-directory virtiofs. No entire home directory is exported by default.

On macOS 27.0.1, these tests passed with the signed local app: GUI relaunch
reused the same Helper PID, attached output and PTY input round-tripped,
Compose and Buildx used the bundled plugins, an authorized virtiofs bind
mount read the host fixture, and a named volume persisted across restart.
No new Apple Virtualization worker was observed.

## Standalone probe and dependency patch

`bash scripts/moby/build-hvf-probe-macos.sh` builds a standalone vCPU and Guest
probe. Run `--check-hvf`, or use `scripts/moby/smoke-hvf-probe-macos.sh` with the
probe executable, Guest assets and kernel to check Docker readiness, telemetry,
process ownership, shutdown and an unchanged read-only seed. Set
`KIRI_HVF_PROBE_TEST_IMAGE=alpine:3.22` for an online image test; also set
`KIRI_HVF_PROBE_IMAGE_ARCHIVE` to use a local `docker save` archive instead.

The builder checks source archive SHA-256 hashes and builds pinned libkrun with
its lockfile. Local libkrun patches preserve virtio-vsock half-close semantics:
Docker's stdin EOF no longer resets the socket and discards pending output.
They include regression tests for half-close and full-close behavior. The
published VZ app and its CI packaging are separate from this macOS 27 local
build. The VMM reports Guest memory telemetry, but does not report a balloon
target or claim host memory has been reclaimed.

## Apple Intel translation experiment

macOS 27 includes [Intel binary translation for ARM Linux guests](https://developer.apple.com/documentation/virtualization/running-intel-binaries-in-linux-vms)
without a separate Rosetta installation. Apple's public integration still uses
`VZLinuxRosettaDirectoryShare`. The standalone HVF probe has an opt-in experiment
that exposes only the built-in Apple Linux runtime via host-enforced read-only
VirtioFS. It does not copy or bundle Apple binaries and does not add VZ or QEMU.

On Apple Silicon macOS **27.0.1** (build `26A434`), the Guest mounted the share and
verified the enabled `binfmt_misc` rule pointed to `/run/rosetta/rosetta`. Both
`linux/amd64` images (`alpine:3.22`, `debian:bookworm-slim`) reached Apple's
interpreter and exited with status 133 and the same message:

> Rosetta is only intended to run on Apple Silicon with a macOS host using
> Virtualization.framework with Rosetta mode enabled

With the share disabled, both amd64 images failed with `exec format error`.
A native `linux/arm64` container ran in both tests; both VMs shut down cleanly,
the read-only seed kept the same hash, and no new Apple VZ worker was observed.
The experiment stops at the probe: **the local HVF App does not enable amd64
execution**, and the installed VZ App and its data are unchanged.

To reproduce, build the current probe and Guest assets and run the two isolated
checks below. The second command returns nonzero if translation cannot execute
the images. The script prints the disposable VM and log directory for each run.

```sh
bash scripts/moby/smoke-hvf-probe-macos.sh "$probe" "$assets" "$assets/Image" --no-translation-control
bash scripts/moby/smoke-hvf-probe-macos.sh "$probe" "$assets" "$assets/Image" --apple-translation
```

## Helper parity result (in-process libkrun, macOS 27)

The probe result carries over to the Helper with the same evidence chain, so the
Helper now wires the identical opt-in path:

- `kiri_hvf_run_helper` accepts a `rosetta_directory` and exports it under the
  read-only `rosetta` VirtioFS tag exactly like the probe; the guest kernel
  reports `virtiofs virtioN: discovered new tag: rosetta`.
- `HVFHelper.systemRosettaDirectory()` validates the system runtime the same way
  the probe does (root-owned directory and interpreter, no group/other write
  bits, `R_OK|X_OK`) and honors `KIRI_MOBY_DISABLE_ROSETTA=1`. A missing or
  rejected runtime logs a trace line and leaves the VM fully ARM64-capable; it
  never fails the VM. When present, the helper emits
  `kiri.moby_hvf_rosetta=1` on the kernel command line and the guest init runs
  `kiri-rosetta --diagnose`.
- Live verification on this Mac: the guest mounted the share read-only, the
  interpreter was executable, and binfmt_misc registered
  `interpreter /run/rosetta/rosetta` (`[kiri-rosetta]` diagnose lines in
  `logs/console.log`).

## amd64 translation result (guest-kernel attestation shim)

With the guest-kernel patch below, amd64 containers run on the local HVF build.
Live checks on this Mac: `alpine:3.22` and `debian:bookworm-slim` with
`--platform linux/amd64` both report `x86_64` (`dpkg --print-architecture` =
`amd64`), a static amd64 workload executes, and native `linux/arm64` containers
are unaffected. Graceful stop remains clean.

### The three ioctls

Apple's `rosetta` interpreter (`/Library/Apple/usr/libexec/oah/RosettaLinux/rosetta`,
an ARM64 static ELF ptrace tracer) probes its environment on
`/proc/self/exe` before translating anything. Captured from a real macOS 27
VZ virtual machine with `VZLinuxRosettaDirectoryShare` (probe binary issuing
all three ioctls and dumping the buffers):

| cmd | direction | size | VZ behavior |
|---|---|---|---|
| `0x80456125` (`_IOC(READ,0x61,0x25,0x45)`) | read | 69 | copies the 69-byte watermark, returns 1 |
| `0x80806123` (`_IOC(READ,0x61,0x23,0x80)`) | read | 128 | copies 128 zero bytes, returns 1 |
| `0x00006124` (`_IOC(NONE,0x61,0x24,0)`) | none | 0 | returns 1 |

The watermark is `"Our hard work\nby these words guarded\nplease don't
steal\n\xc2\xa9 Apple Inc\0"` (69 bytes with the trailing NUL). The rosetta
binary `memcmp()`s the 69-byte reply against a copy at its own VA
`0x80000000f089` (call site `0x8000000315fc`) and executes `brk` (SIGTRAP, the
"Rosetta is only intended to run on Apple Silicon…" error) on mismatch. The
VZ share's plain-text copies inside the rosetta binary are spelled `guarded`;
an earlier probe iteration reported `guarfeded` — that spelling came from the
decoy buffer, not from the comparison target, and does not pass the check.
After the watermark passes, rosetta issues the other two commands; a failing
one surfaces as "Unexpected ioctl error when communicating with hypervisor".
The zero capability block and bare rc=1 are what VZ answers, and both the
static (`alpine`) and dynamic (`debian`, via `/lib/ld-musl-x86_64.so.1`
extracted per-image) paths complete under them.

### Implementation

`guest/kernel/patches/0007-fuse-rosetta-attestation-ioctl.patch` intercepts the
three commands in `fuse_file_ioctl()` on any FUSE mount (the interpreter opens
the interpreter file through the read-only virtiofs FUSE device) and answers
them in-kernel, copying the same bytes VZ does (69 / 128 / 0) and returning 1.
This replaces the earlier libkrun-side approach
(`04-rosetta-attestation-ioctl.patch` in the helper's libkrun patches): a FUSE
server reply cannot carry more than `_IOC_SIZE` bytes, and keeping the answer
in the guest kernel matches OrbStack's approach (its kernel answers rosetta
from a file-operations shim). The libkrun patch is kept as a harmless fallback
with the corrected `guarded` payload. Every other command takes the normal FUSE
path untouched.

Build notes: the kernel tree must live on a case-sensitive filesystem —
building under a macOS-host bind mount merges `xt_DSCP.c`/`xt_dscp.c` and
fails with "No rule to make target 'net/netfilter/xt_DSCP.o'"; use a container
named volume. `kiri.config` disables `CONFIG_IP_NF_TARGET_ECN` (6.18.58 uapi
dropped `IPT_ECN_OP_SET_*`). The stale data-dir guest assets are refreshed by
`installGuestAssets`; when iterating on kernels, replace
`KIRI_MOBY_DATA_DIR/guest/Image` directly (the bundle copy alone is not
re-installed when `rootfs.revision` is unchanged).

Executing amd64 images used to fail at Apple's interpreter attestation with
status 133 and the message quoted above; the guest-kernel patch in the previous
section resolves it. Two host-side facts remain true and worth keeping:

1. **The interpreter is not the whole runtime.** `/Library/Apple/usr/libexec/oah`
   also contains `oahd`, `runtime` and `translate_tool`; the Linux `rosetta`
   binary is a ptrace-based tracer whose "hypervisor communication" turned out
   to be the three plain ioctls on the interpreter file (documented above) —
   answered in this project by the guest-kernel FUSE patch, not by the VMM.
2. **OrbStack also solves it in the guest kernel.** Its bundled kernel carries
   `proc_rosetta_exe_file` and `orb_rvk_set_key` ("RvK") symbols and maps the
   interpreter into every amd64 process at fixed VA `0x800000000000` as a
   synthetic `/mnt/rv/[rosetta]` mapping, without a separate tracer process.
   kiri reaches the same result differently: the interpreter stays a binfmt_misc
   tracer, and the guest kernel answers its three attestation ioctls.

Therefore the local HVF App enables amd64 execution only when the system
Rosetta runtime is present and exported (the behavior is opt-out via
`KIRI_MOBY_DISABLE_ROSETTA=1`, which removes the share entirely); without the
runtime, amd64 images fail with `exec format error` and there is no silent
fallback to another translator.

## Linux Machines and Kubernetes safeguards

Linux Machines share this Guest's kernel, resources, and networking.
They are isolated Linux namespace root filesystems, **not additional VMs
or security boundaries**. Do not treat a Machine as a sandbox for
untrusted privileged workloads. Management uses the private Machines
vsock channel (2379), bridged to `run/machines.sock` on both the VZ
and HVF Helpers; no TCP management port is opened.

The controller validates Machine names, decodes JSON escapes strictly,
caps request size and concurrent clients, enters the Machine's root when
executing a command, and refuses destructive deletion while the init or
other processes still hold its rootfs. Machine launch confirms the init
process actually started; failed deletions preserve the Btrfs data.

A distro rootfs must contain a working `/sbin/init` or
`/usr/sbin/init`. Minimal official container images may lack a real
init and are rejected with an error rather than shown as booted. Only
the Alpine preset has been exercised in an end-to-end Machine test; the
other presets need separate validation before production enablement.

k3s is **experimental** and not a required component of the Docker
Engine. The Kubernetes UI is hidden unless
`KIRI_MOBY_EXPERIMENTAL_K8S=1` is set (or an existing cluster is
running). The Guest-side kubeconfig does not yet provide a Mac-facing
Kubernetes API endpoint. Do not advertise the cluster as fully
Mac-accessible until that path is implemented and tested.

The idle Docker cache eviction worker now checks for running Machines
and k3s before dropping the Guest's global clean file cache. No
implicit ext4-to-Btrfs migration or destructive reset is performed.

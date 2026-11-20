# Moby Engine migration — macOS Apple Silicon only

## Decision (2026-11-19)

This fork **replaces** Kiri's custom Docker-compatible Engine with upstream
Moby/Docker Engine. It will not ship a runtime selector or maintain both
implementations.

Target: **macOS 14+ on arm64 (Apple Silicon)**. The Linux/aarch64 guest is an
implementation detail, not a supported Linux host platform. Windows,
Intel macOS, native Linux, Kubernetes and USB integration are out of scope.

The existing self-built runtime remains in the upstream source tree **only
until its consumers are replaced**. Do not mistake the initial proxy code
for a completed migration: the original GUI and `kiri daemon` still use
Kiri's custom Engine at the moment.

## Target architecture

macOS:
- Kiri GUI, VM lifecycle controller, memory balloon, sleep/wake, resources
- Native Apple Virtualization.framework (`crates/kiri-vmm`)
- One owner-restricted local Unix socket; do not touch OrbStack or Colima
- Byte-transparent Docker Engine API transport over vsock (no HTTP rewriting)
- Host port forwarding driven by upstream Docker `/events`

Linux/aarch64 guest:
- Proper Linux kernel config for cgroup v2, overlayfs, seccomp, namespaces,
  netfilter/iptables/nftables, virtiofs, vsock, virtio-blk and Rosetta binfmt
- Minimal persistent root filesystem, a real init/daemon supervisor
- **Upstream dockerd + containerd + runc**, pinned and updated together
- Docker controls containers, image metadata, volumes, networks, BuildKit
- Guest-side AF_VSOCK listener at port 2375 relays to /run/docker.sock
- No Docker TCP listener; no Kiri Engine API or duplicate container DB

```text
docker / compose / buildx
         |
~/.kiri-moby/run/docker.sock  (0600)
         |
kiri-moby-host / VM controller (Apple VZ)
         |    AF_VSOCK:2375 (not TCP)
kiri-moby-guest (opaque byte bridge)
         |
/run/docker.sock
         |
    upstream dockerd
      /        \
 containerd    BuildKit
      |
     runc
```

### Implemented on branch moby-engine — transport foundation

- `crates/kiri-moby-bridge`: lossless duplex transport, binary data, EOF
  propagation, HTTP Upgrade / attach; unit tests.
- `kiri-moby-host`: standalone Apple Silicon VZ boot and private Unix
  Docker socket; it refuses to replace another engine's socket and requests
  Guest shutdown on Ctrl-C/SIGTERM before releasing the disk.
- `kiri-moby-guest`: Linux/aarch64 AF_VSOCK listener which bridges
  each client to the **real** Docker Engine socket; no Docker API parsing.
- GitHub Actions compile checks for macOS arm64 and Linux arm64.

**Apple Silicon real-device validation (2026-11-19):** a user has
successfully booted the Guest, called the real Docker Engine API, pulled
images, run native ARM64 and cross-architecture AMD64 containers, built
both architectures with Buildx, executed Docker Compose, and read/write
tested a named Docker Volume. Mac localhost TCP publishing reached Nginx
after the original polling delay. The new Docker /events forwarding
implementation has unit/CI tests, but its real-Mac latency and listener
cleanup **must still be validated**.

The existing Kiri GUI still uses the original Engine; replacing its consumers,
sleep/balloon integration, UDP, and production hardening remain pending.

## Low-memory ext4 root and OCI pivot_root (2026-11-20)

The real Moby container runtime must run from ext4, not Linux's initial
ramfs, to support OCI runc pivot_root. An earlier implementation bundled
the full Alpine + Moby userspace in the uncompressed initramfs and copied it
to ext4 **at every VM boot**. This could cause large transient Guest memory
allocation whose physical pages are retained by Apple VZ, but host RSS
has not yet been measured to establish the cause of an 800 MiB idle VM.

**The current `memory-reclaim` branch eliminates that repeated in-RAM copy:**

1. Build-time Linux ARM64 packaging prepopulates the existing sparse ext4
   `data.img` template with Alpine, stock Moby Engine, and the Guest bridge.
   The initial kernel initramfs has **only ~2 MiB of BusyBox + musl + tiny
   first-stage init**, verified in Linux ARM64 GitHub Actions CI.
2. The VM attaches writable persistent `vm/data.img` and a **separate
   read-only** `vm/system.img` containing the same userspace as an upgrade
   seed. The tiny init discovers disks by ext4 labels (`kiri-moby`,
   `kiri-system`) before mounting the data image writable, independent of
   virtio device enumeration.
3. Existing installations continue to reuse their original persistent
   `vm/data.img`. Only when `.kiri-moby-rootfs-revision` differs does
   first-stage init copy OS directories from the read-only seed, **never
   overwriting `/var/lib/docker` or `/var/lib/containerd`**. It commits
   the revision stamp after sync, so an interrupted copy is retried on next
   boot. Previously migrated top-level `/docker` and `/containerd`
   directories are moved safely with conflict checks.
4. All **normal boots** avoid copying the root filesystem entirely: the
   tiny early init simply switches into ext4, and stage 2 starts Moby
   `dockerd`, `containerd` and the private vsock bridge.
5. Installing an updated Kiri Moby.app updates a checksum-verified set
   of boot assets under a VM disk lock, keeping an offline boot-asset backup.
   Existing persistent Docker images, named volumes, networks and
   container metadata remain on the same `vm/data.img`.

This boot redesign is separate from runtime dynamic Balloon control and the
isolated libkrun2 free-page-replacement experiment. It does **not** yet prove
macOS process RSS is under 800 MiB, much less 100–200 MiB. Mac real-device
measurements and safe migration acceptance remain required before merging PR #2.

## Experimental Guest image build and test

GitHub Actions now contains two distinct build pipelines:

- [Moby bridge verification](../../actions/workflows/moby-bridge.yml):
  Rust unit tests, ARM64 Linux guest transport check, ARM64 macOS launcher
  build with ad-hoc virtualization entitlement and a downloadable binary.
- [Build standard Moby ARM64 Guest](../../actions/workflows/moby-guest.yml):
  Alpine 3.22 standard Docker Engine (dockerd, containerd, runc), minimal
  initramfs/BusyBox PID 1, ext4 sparse disk template, and the Kiri ARM64
  kernel with required filesystem/network capabilities.

The build produces an artifact `kiri-moby-guest-arm64.tgz` (when CI passes)
with:

- `Image`: ARM64 kernel from Kiri's existing source/config
- `initramfs.cpio`: ~2 MiB BusyBox + musl + tiny first-stage init,
  **no Docker Engine or Alpine rootfs**.
- `data.img.tgz`: 48 GiB **virtual** sparse prepopulated ext4 root + user
  Docker state; initial template is unpacked only on fresh installs.
- `system.img.tgz`: separate sealed read-only ext4 userspace upgrade seed
  (about 704 MiB virtual on initial CI build).
- `rootfs.revision`: fingerprint of the matching Alpine + Moby userspace.
- `SHA256SUMS`: checksums for the entire boot package.

The VM uses `$KIRI_MOBY_DATA_DIR/guest` for boot assets and
`$KIRI_MOBY_DATA_DIR/vm/data.img` for the **separate writable data disk**;
the latter is unpacked on first launch.

GitHub ARM64 Actions validate the Guest build but **not** macOS VZ
runtime behavior. A separate real Apple Silicon smoke test has now passed
Docker Engine, native/cross-architecture containers, Buildx, Compose, and
the original TCP publish path. The **new event-driven** forwarding changes
still require real-Mac acceptance. Alpine dependencies are not digest pinned;
release/supply-chain hardening remains a separate gate.

### Test on an Apple Silicon Mac

Get the two *artifact archives* from the successful runs of the workflows
above. This does not install or modify OrbStack and never overwrites
`/var/run/docker.sock`.

```sh
mkdir -p "$HOME/.kiri-moby/guest"
tar -xzf kiri-moby-guest-arm64.tgz -C "$HOME/.kiri-moby/guest"
(cd "$HOME/.kiri-moby/guest" && shasum -a 256 -c SHA256SUMS)

mkdir -p "$HOME/.local/bin"
tar -xzf kiri-moby-host-arm64.tgz -C "$HOME/.local/bin"
# For a local source build, sign using the upstream virtualization entitlement:
# codesign -f -s - --entitlements crates/kiri/kiri.entitlements \
#   target/aarch64-apple-darwin/release/kiri-moby-host
"$HOME/.local/bin/kiri-moby-host"

# In a second terminal:
docker context create kiri-moby --docker "host=unix://$HOME/.kiri-moby/run/docker.sock"
docker --context kiri-moby version
docker --context kiri-moby run --rm alpine:3.22 echo hello
```

To store all VM data on an APFS external SSD, launch with
`KIRI_MOBY_DATA_DIR=/Volumes/ExternalSSD/kiri-moby` and extract boot assets
under that directory's `guest/`. Do not place the data disk on exFAT.
The VM memory defaults to 4 GiB and CPU to 4; override with
`KIRI_MOBY_MEMORY_MIB` and `KIRI_MOBY_CPUS`.

### TCP publish forwarding

The host subscribes to standard Docker `GET /events` and reconciles
published TCP ports against `GET /containers/json`. The events stream triggers
on container start, stop, die and related lifecycle transitions; the container
list remains the **source of truth**. On successful event subscription the host
performs a fresh snapshot to close the startup/reconnect gap. It performs a
full scan every 30 seconds as recovery for missed events, and retries if the
Docker API is not yet available. Mac listeners bind only `127.0.0.1`.

Because Docker API events are delivered asynchronously, there remains a small
race between `docker run -d` returning and the Mac listener being ready:
this is **lower latency than the old 2-second polling**, not a synchronous
port-publish guarantee. UDP and LAN-exposed bind-address semantics are not
implemented. Export `KIRI_MOBY_DEBUG=1` for detailed relay errors.

To install a new event-driven **Host** without replacing Guest or ext4 data,
stop the Kiri VM and run:

```sh
export KIRI_MOBY_DATA_DIR="/tmp/kiri-test/.kiri-moby"
bash scripts/moby/upgrade-host-macos.sh "$HOME/Downloads/kiri-moby-host-arm64.zip"
```

Run `bash scripts/moby/test-port-events-macos.sh` for an Apple Silicon
smoke test of automatic TCP publishing, Nginx readiness and listener
cleanup. The VM must be running with auto-forwarding enabled. The test
uses localhost:18081 by default (override with
`KIRI_MOBY_EVENT_TEST_PORT`) and never contacts OrbStack.

For manual override, set `KIRI_MOBY_TCP_PORTS`:

```sh
KIRI_MOBY_TCP_PORTS="8080:8080,5432:5432" \
  "$HOME/.local/bin/kiri-moby-host"

# In a second terminal:
docker --context kiri-moby run -d --name web -p 8080:80 nginx:alpine
curl -v http://127.0.0.1:8080/
```

The mapping format is `MAC_PORT:GUEST_PUBLISHED_PORT`. It deliberately binds
only 127.0.0.1 on the Mac, and currently supports TCP only. Inside the
guest **dockerd** controls the container port publish and network/NAT rules;
the host relay never bypasses Docker to reach a container IP directly.
**UDP remains pending**; TCP auto-discovery is event-driven with reconciliation fallback.
A port must be free on the Mac, or host startup fails.
Press Ctrl-C to request a graceful guest shutdown and disk sync.

**Not yet implemented:** UDP publishing, synchronous Mac port readiness, standard
Docker API integration into Kiri's existing GUI, automatic VM sleep/balloon policy,
full regression tests and signed/notarized single-app distribution.

It intentionally does not replace the current Docker context or
`/var/run/docker.sock`.

## Work packages and hard gates

1. **Guest**: construct a reproducible Linux/aarch64 guest from pinned
   Linux and Docker Engine releases with checksums/SBOM. Include the stock
   Docker daemons and enable kernel features without disabling seccomp.
   Acceptance: Docker Engine API `/_ping` and `docker version` work.
2. **Linux operations**: init process, graceful shutdown, fsync/data-disk
   behavior, guest DNS/VPN/proxy, /Users and /Volumes virtiofs mounts
   at their expected paths, Rosetta/binfmt. Acceptance: restart without
   corrupting layers/volumes and run amd64 on Apple Silicon.
3. **Mac integrations**: parse Docker `/events` and reconcile published
   TCP/UDP ports with Mac host, DNS, localhost, VM wake, balloon pressure.
   Acceptance: Compose networking, host port conflicts, sleep/wake and VPN.
4. **GUI**: remove the custom container `Engine` data model. The GUI must
   use Docker APIs for images/containers/volumes/networks/builds. Docker
   Engine must be the sole source of truth.
5. **Remove custom Engine**: delete unused custom Docker API, `kiri-image`
   store, container state DB, `kiri-init` runtime implementations and
   obsolete WSL/Windows/Linux paths only after replacements compile.
6. **Regression and packaging**: one signed arm64 macOS app and automated
   release tests. No x86_64/Windows/Linux products.

Acceptance matrix (not yet passed): Docker CLI, Compose, Buildx `docker`
driver, multi-stage builds, caches, image push/pull, bind mounts, >=120
image layers, restarts, volumes, TCP/UDP, `--network host` semantics,
Testcontainers, Rosetta amd64 builds, sleep/wake, and VM crashes.

## Security and data principles

- The Docker Unix socket gives root-equivalent control over the **guest**.
  It must be accessible only to the local user; never publish dockerd on
  0.0.0.0:2375 TCP or expose an unauthenticated remote API.
- Docker controls the guest; do not claim that privileged containers are
  sandboxed from guest compromise. Keep host mounts explicitly scoped and
  limit guest access to macOS through vsock.
- Standard Docker Engine must be updated for security releases.
- **Do not reuse or overwrite upstream Kiri's image/data disk**. New
  Moby storage uses a separate `~/.kiri-moby` directory.
- Do not auto-import or delete OrbStack, Colima, or original Kiri data.
- Do not auto-switch the default Docker Context.

## Relationship to upstream

The VMM and UI code originate from libracoder/kiri (Apache-2.0).
Migration code in this fork is additive until its cutover is proven. The
target is **one** runtime: Moby. There is no intent to support the original
custom Engine after cutover.

## Single-source-revision milestone package

The `Kiri Moby unified macOS ARM64 milestone bundle` workflow builds the
Linux Guest and signed Apple Silicon Host from the **same Git revision** in
one GitHub Actions run. It produces a single downloadable artifact named
`kiri-moby-macos-arm64-bundle` with checksums and source revision metadata.

Stop the VM before installing. The single-artifact offline installer
`bash scripts/moby/install-milestone-macos.sh <bundle.zip>` verifies
both Guest and Host and **preserves the existing vm/data.img**.
The milestone bundle is not the finished native GUI application.

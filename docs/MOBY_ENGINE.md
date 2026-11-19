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

**Implemented as build recipes, not yet validated on a Mac:** ARM64
guest initramfs, kernel build and ext4 data-disk template. The existing
Kiri GUI is still connected to the original Engine, and automatic port
publishing, auto-sleep/balloon integration and Buildx/Compose end-to-end
testing are still pending. The launcher refuses to run without guest
assets; an incomplete build must not be described as a working runtime.

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
- `initramfs.cpio`: minimal Alpine Linux ARM64 userspace with real Docker
- `data.img.tgz`: 48 GiB **virtual** sparse ext4 disk (not 48 GiB physically)
- `SHA256SUMS`: checksums of these three files

The VM uses `$KIRI_MOBY_DATA_DIR/guest` for boot assets and
`$KIRI_MOBY_DATA_DIR/vm/data.img` for the **separate writable data disk**;
the latter is unpacked on first launch.

This is an experimental build recipe, **not yet a VM smoke-test result**.
GitHub ARM64 Actions build the Linux guest but do not prove that
Virtualization.framework can boot it or that a Docker workload works on a
real Apple Silicon machine. Alpine dependencies are not yet digest pinned;
release/supply-chain hardening is another gate.

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
Press Ctrl-C to request a graceful guest shutdown and disk sync.

**Not yet implemented:** automatic host port publishing, standard Docker API
integration into Kiri's existing GUI, automatic VM sleep/balloon policy,
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

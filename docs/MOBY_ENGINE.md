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
  Docker socket; it refuses to replace another engine's socket.
- `kiri-moby-guest`: Linux/aarch64 AF_VSOCK listener which bridges
  each client to the **real** Docker Engine socket; no Docker API parsing.
- GitHub Actions compile checks for macOS arm64 and Linux arm64.

**Not yet implemented:** provisioning a bootable Moby guest (kernel,
initramfs, persistent disk, dockerd, containerd, runc); existing Kiri GUI
integration; port publishing; auto sleep/balloon based on Docker state;
Buildx and Compose runtime acceptance tests. Until then the standalone
host will report that its guest assets are missing, and is not a working
Docker runtime.

## Experimental transport paths

The experimental VM expects three matching files placed under
`~/.kiri-moby/guest/` (or `$KIRI_MOBY_DATA_DIR/guest/`):

- `Image`: bootable ARM64 Linux kernel supporting upstream Docker
- `initramfs.cpio`: PID 1 that starts the Guest, `dockerd`, and
  `kiri-moby-guest` with the correct filesystems/network/cgroups
- `data.img`: persistent ext4 guest disk

These images **are not produced by the transport milestone**. No external
images should be trusted as drop-in replacements without checksum, provenance,
and a compatible kernel config. Boot the existing Kiri guest with this
module only after a guest image is explicitly built and verified.

After a correctly provisioned guest is available:

```sh
cargo build -p kiri-moby-bridge --release --bin kiri-moby-host
./target/release/kiri-moby-host

# A separate terminal:
docker context create kiri-moby \
  --docker "host=unix://$HOME/.kiri-moby/run/docker.sock"
docker --context kiri-moby version
```

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

# Moby-only macOS GUI migration: implementation checklist

## Decision

The shipped macOS application will have **one engine**: upstream Moby.
The custom container execution engine is temporary source-code debt, not
a user-selectable runtime. Do **not** add a long-term runtime toggle or
forward Moby requests to the old Kiri daemon.

**Scope**: macOS Apple Silicon only. Keep OrbStack / other Docker engines and
the user's Docker context completely untouched unless the user explicitly
chooses otherwise. The experimental Kiri Moby data disk is isolated.

## Already verified on a real Apple Silicon Mac (2026-11-19)

- Linux VZ VM boots with persistent ext4 root, standard dockerd/containerd/runc.
- Docker Engine API, ARM64 and AMD64 containers, Docker Hub TLS/pull.
- ARM64 and AMD64 Buildx via Docker CLI, Compose up/down, named volumes.
- Mac localhost TCP -> Guest published port -> Nginx web page (original polling implementation).
- Event-driven TCP publishing compiled, signed, and exercised by CI; changed
  implementation still needs an integrated Mac acceptance gate.
- Authorized per-directory Mac VirtioFS mounts implemented with shared
  Host/Guest parser tests; Mac runtime acceptance is not yet complete.

## Existing UI API mapping

Source: crates/kiri/src/ui/mod.rs, crates/kiri/src/client.rs, and setup.rs.

| Existing GUI action | Standard Moby equivalent | Required changes |
| --- | --- | --- |
| Containers list, images, volumes, networks | GET /containers/json?all=1, /images/json, /volumes, /networks | Keep list view and icons; point to private Moby socket |
| Start, stop, restart, remove, pause, unpause | Standard Docker container endpoints | Preserve error mapping and event refresh |
| Run image and port bindings | POST /containers/create, /containers/{id}/start | Honor Moby's immutable create-time bindings |
| Pull with progress | POST /images/create (streaming response) | Preserve cancellation and JSON progress |
| Buildx and Compose | Bundled Docker CLI using DOCKER_HOST | Reuse the already verified standard engine |
| Docker events | GET /events streaming | Reconnect, debounce, refresh |
| GUI wake / stop | Kiri-only POST /kiri/wake, /kiri/stop | Replace with Host VM lifecycle controller |
| VM panel | /info KiriVmAwake, KiriMemoryTarget, KiriCpuPercent ... | Host VZ metrics + normal Docker /info |
| Edit ports after create | POST /kiri/containers/{id}/ports (Kiri-only) | Docker-compatible recreate flow with explicit user confirmation |
| Edit container env | POST /kiri/containers/{id}/env (Kiri-only) | Docker-compatible recreate flow; never mutate running container |
| Domains, proxy, resources | POST /kiri/domains, /kiri/proxy, /kiri/resources | Separate host integration features, not fabricated Docker APIs |
| Setup / Docker context | Existing Kiri setup links sockets / changes context | Point to Moby socket; do not hijack OrbStack |
| Engine restart/update | update::start_engine, update::restart_engine | Launch/stop Moby VM and atomic guest asset updates |

## Implementation milestones (no per-feature manual testing)

### A. Central Moby-only backend and lifecycle

- Replace callers of the Kiri-only socket in the macOS UI / CLI.
- Start/stop exactly one Kiri Moby Host process; propagate SIGTERM,
  wait for disk flush, and refuse overlapping VM launches.
- VM state is obtained from VZ lifecycle; Docker state is from dockerd.
- Keep socket private and never overwrite /var/run/docker.sock.
- Automated API smoke tests and a typed backend contract.

### B. GUI Docker parity

- Make container/image/volume/network list and action views use standard Docker.
- Remove assumptions about Kiri-only /info fields from the VM sidebar.
- Replace post-create environment/port mutations with Docker-compatible
  explicit recreation (stop/remove/rename only after user confirmation).
- Compose/Buildx use the same private Moby socket. No second image store.
- CI: static API-contract checks + existing UI test suite.

### C. Mac integration and security

- Scoped VirtioFS project shares, instead of enabling the whole home directory.
- Event-driven TCP publishing, UDP support later; maintain localhost-safe default.
- Stable CPU/memory metrics, memory balloon, sleep/wake handling.
- Keep third-party Docker data and contexts isolated.

### D. Packaging / one-click install

- Bundle the signed macOS Host, matching Guest kernel/initramfs and template.
- Embed Docker CLI / Compose / Buildx.
- LaunchAgent and GUI control the same Moby host lifecycle, not the legacy daemon.
- Upgrade assets transactionally with separate persistent ext4 Docker disk.

### E. Remove old custom runtime

Only after A-D pass automated validation:
- Eliminate custom container Engine, custom image store and custom
  Docker API emulation from macOS build.
- Keep unrelated tooling only if it has a remaining consumer.
- Remove stale UI operations rather than continuing to call /kiri/*.
- Do not delete the user's legacy engine data during migration.

## Acceptance and reporting

Engineering changes should ship in coherent milestone batches with GitHub CI.
**No repetitive user smoke tests.** The next real Apple Silicon user-run
acceptance should be a single packaged-application regression covering GUI,
Compose/Buildx, startup/shutdown, persisted volumes and file mounts.

Current status: core Docker Engine path passed real-device testing;
the macOS GUI migration is **not complete**.

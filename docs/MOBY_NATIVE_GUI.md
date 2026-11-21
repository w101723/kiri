# Kiri Moby — SwiftUI / Swift Host / Rust Guest

## Supported system

Kiri Moby is an **Apple Silicon-only macOS 14+** Docker desktop built with
SwiftUI, AppKit and [SwiftTerm 1.20.0](https://github.com/migueldeicaza/SwiftTerm).
It does not ship the previous custom Kiri daemon, WebKit UI, custom image engine
or Windows/Linux host application.

## Production processes

| Component | Language | Process | Responsibility |
| --- | --- | --- | --- |
| `kiri-moby-ui` | Swift | Finder macOS GUI | Containers, images, volumes, networks, Compose inventory, Buildx, logs, terminal, VM controls |
| `Kiri Moby Helper.app` (`Kiri Moby Helper` process) | Swift | Independently signed headless agent bundled inside the GUI app | Apple Virtualization.framework VM lifecycle, Docker API / Unix-vsock relay, published localhost TCP ports, VirtioFS and memory balloon |
| `com.apple.Virtualization.VirtualMachine.xpc` | Apple system service | Separate macOS-managed VM worker | Executes the virtual machine; macOS controls its process identity and display name |
| `kiri-moby-guest` | Rust | Linux ARM64 Guest | Standard Docker socket vsock proxy, shutdown port, published TCP forwarding, memory telemetry, authorized shares and clock synchronization |
| `dockerd` | Upstream | Linux ARM64 Guest | Container state, image layers, volumes, networks and BuildKit |

The app **does not launch a Rust CLI**. `MobyApp.swift` calls
`MobyRuntime.swift` directly for standard Docker HTTP/1.1 requests through
`~/.kiri-moby/run/docker.sock`. The socket belongs only to Kiri Moby;
`/var/run/docker.sock`, system Docker contexts and OrbStack are not changed.
The Swift runtime supports bounded requests, HTTP content length and chunked
framing, and normalizes Docker CPU, working-set memory, network and block I/O.
It fetches statistics for at most 64 running containers (six concurrent requests).
UI refreshing remains periodic, with followable bounded log snapshots.

The interactive terminal uses SwiftTerm's `LocalProcessTerminalView` and
executes the **bundled Docker CLI** with
`DOCKER_HOST=unix://~/.kiri-moby/run/docker.sock` and
`DOCKER_CONTEXT` removed. Compose and Buildx also invoke this pinned CLI
against Kiri Moby's private socket, not the user's default engine.

## Independent Host and disk safety

The Swift Host is bundled at `Kiri Moby.app/Contents/Library/Helpers/Kiri Moby Helper.app`,
with `LSUIElement=true`, its own bundle identifier, and an independent
virtualization-entitled code signature. The GUI launches the helper directly
using `Process`, without launchd registration or elevated privileges; no
second Dock icon is created. The underlying Apple Virtualization XPC worker
remains a separate system process and is not renamed by packaging the Helper.

The Swift Host runs in a separate process. Quitting or crashing the GUI does
not intentionally stop the VM; reopening the GUI reconnects via the private socket.
It holds an exclusive `moby-vm.lock` during VM ownership to prevent simultaneous
writable mounts. VM shutdown uses the Guest's graceful SHUTDOWN vsock protocol,
waits for disk release, and then cleans up sockets.

The Linux disk ABI remains fixed:
- `~/.kiri-moby/vm/data.img`: writable persistent ext4 Docker image, volumes and metadata (`/dev/vda`)
- `~/.kiri-moby/vm/system.img`: read-only Guest rootfs seed (`/dev/vdb`)
- `~/.kiri-moby/guest/`: signed kernel, initramfs, seed archives and revision checksums

Guest updates verify bundled `SHA256SUMS`, stage replacement boot assets under
the same disk lock and leave the writable Docker disk intact. macOS shares are
explicit opt-in normalized project directories beneath `/Users` or `/Volumes`,
validated by both Host and Rust Guest. Rosetta integration is optional. The
traditional VZ memory balloon must not be confused with verified host RSS reclamation.

## Release and CI

The source is under `crates/kiri/native/`:
- `MobyApp.swift` — application and views
- `MobyRuntime.swift` — in-process native Docker client and VM controller
- `KiriMobyHost.swift` — standalone Swift Virtualization.framework Host
- `Package.swift` — pinned SwiftTerm dependency for the UI

The Linux Guest Rust source is solely under `crates/kiri-moby-bridge/`, with
`Cargo.lock` containing only Guest build dependencies. Guest kernel scripts,
rootfs generation, signing and packaging are in `guest/kernel/` and
`scripts/moby/`.

- `.github/workflows/moby-native-ui-check.yml`: cross-compiles arm64 Swift UI,
  SwiftTerm and Swift Host; exercises a synthetic Docker HTTP-over-Unix-socket
  integration test
- `.github/workflows/moby-bridge.yml`: builds and tests the Linux Rust Guest
  and compiles/signs the independent Swift Host
- `.github/workflows/moby-native-visual-preview.yml`: real AppKit window
  screenshot using **test-only synthetic data**, never AI-generated visuals
- `.github/workflows/moby-personal-signing-test.yml`: verifies the existing
  private-P12 signer on a clean macOS runner
- `.github/workflows/moby-milestone.yml`: full same-commit Guest+Host+SwiftUI
  application and DMG packaging, triggered manually on this feature branch

## Physical Apple Silicon acceptance required

CI cross-compilation on Intel macOS runners cannot substitute for hardware
acceptance. On a real Apple Silicon Mac verify: Guest boot; Docker pull,
container lifecycle, networks, volumes, Compose, Buildx and amd64 Rosetta;
SwiftTerm interactive PTY; large streaming Docker build and logs; published
localhost port forwarding; authorized directory shares; disk persistence across
Host restart; GUI close/reopen without stopping VM; and VM balloon behavior
using `vmmap -summary`/real physical footprint. Verify signing certificates,
DMG install and Gatekeeper behavior separately. A personal self-signed
certificate is **not** Apple Developer ID notarization.

# Kiri Moby · macOS Apple Silicon

Kiri Moby is a private **macOS 14+ / Apple Silicon (arm64)** Docker
application using the standard upstream Moby Docker Engine. It does not
include Windows, WSL or Linux-host application support. Linux ARM64 remains
the **Guest operating system inside the Mac virtual machine**, as Docker
Engine needs Linux kernel namespaces and cgroups.

## Native UI

The Finder-launched application is fully native **SwiftUI + AppKit**.
The previous HTML/WebKit Moby screen is retained as a compatibility
reference in the source tree only. The native GUI has the same structure,
colors, navigation order and control surfaces:

- 44-point top strip: sidebar rail toggle, search (⌘K), Settings.
- 212-point sidebar (60-point compact rail): Docker / Kiri navigation,
  counts, theme toggle and persistent bottom VM status card.
- Containers: original All / Running / Stopped / Failed tabs,
  Compose-project collapse/expand, seven columns, inline start/stop/
  restart/pause/unpause, Exec, Logs, Inspect and Remove, published port links.
- Images / Volumes / Networks: original rows, columns, action buttons.
- Compose: choose YAML, Up -d, PS, Logs, Down.
- Builds: build context, image tag and linux/arm64 or linux/amd64.
- Settings: VM start/stop, explicit authorized macOS project folders,
  apply changes with controlled VM restart.
- Original Docker status footer and independent AppKit menu-bar item.

The SwiftUI Finder executable is **Contents/MacOS/kiri-moby-ui**.
It calls the signed, short-lived Rust CLI inside the same App bundle for
Docker/VM operations. No WKWebView runs in the Finder app.
The separate kiri-moby-host process controls Apple's Virtualization
framework, private vsock transport and ~/.kiri-moby Docker socket.
No extra Docker Engine or new user data store is created.

The old legacy Kiri WebKit GUI source is temporarily preserved for
visual/functional parity audit; it is not the normal Finder app entrypoint.
See [Native UI engineering contract](docs/MOBY_NATIVE_GUI.md).

## macOS install

Builds and development releases: [Kiri Moby GitHub Actions](https://github.com/w101723/kiri/actions/workflows/moby-milestone.yml).
Only ARM64 binaries are produced. The app ZIP includes the verified local
installer. For a personally signed, **non-notarized** build, authorize its
pinned-certificate installer only once, then use it for later upgrades:
[Local installation and signing](docs/MOBY_PERSONAL_SIGNING.md).

An existing Kiri Moby Docker data disk at ~/.kiri-moby/vm/data.img is not
overwritten by UI changes. Stop the VM before an App upgrade.
Personal P12 credentials belong exclusively in GitHub Actions Secrets,
never in the repository. Apple notarization requires Developer ID.

## Architecture

    macOS arm64
    ├── Kiri Moby.app / SwiftUI + AppKit
    │   └── Contents/MacOS/kiri — short-lived Rust JSON control/CLI
    ├── kiri-moby-host — VZ VM lifecycle / Docker Unix socket forwarding
    └── Apple Virtualization.framework
        └── Linux ARM64 Guest
            ├── Linux kernel, virtiofs and virtio balloon
            ├── upstream Moby dockerd / containerd / runc
            └── persistent ext4 Docker data disk

The VM service's physical footprint is independent of WebKit process
removal. Balloon target, Guest MemAvailable and Host Physical footprint
must be measured separately.

## Build and verification

Use macOS/Xcode with an Apple SDK and Rust targeting Apple Silicon:

    rustup target add aarch64-apple-darwin
    cargo check -p kiri --target aarch64-apple-darwin
    python3 scripts/moby/check-native-ui-parity.py

The separate macOS CI pipeline cross-compiles the SwiftUI native app,
verifies no direct WebKit or JavaScriptCore dependency, checks the Rust
control bridge and verifies original UI feature parity. The complete
ARM64 bundle workflow packages and signs the GUI, CLI, Host and Docker
tools plus matching Linux ARM64 Guest. CI compilation alone does not
replace a real Apple Silicon screenshot/interaction acceptance test.

## Project lineage and licenses

Kiri Moby is based on the open-source Kiri project. The original Kiri
engine's Linux/Windows installers and benchmark claims do **not** apply
to this Apple Silicon/Moby fork. Kiri's name and marks are subject to
their original trademark terms; source code remains Apache-2.0.
Third-party attribution is in [NOTICE](NOTICE); Linux Guest source and
GPL-2.0 source-offer information remain in [guest/kernel](guest/kernel).

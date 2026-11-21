# Kiri Moby

Native Apple Silicon-only Docker desktop: **SwiftUI/AppKit + SwiftTerm, pure Swift macOS Virtualization Host, and upstream Linux dockerd**. Only the minimal Linux ARM64 Guest transport remains in Rust.

## Architecture

```text
Kiri Moby.app (macOS arm64)
  Contents/MacOS/kiri-moby-ui    SwiftUI + Docker Unix Socket client
  Contents/Resources/bin/kiri-moby-host   standalone Swift VZ daemon
  Contents/Resources/bin/docker           upstream Docker CLI
  Contents/Resources/bin/cli-plugins/      Compose and Buildx
  Contents/Resources/guest/                kernel / initramfs / ext4 seed

  GUI ---> ~/.kiri-moby/run/docker.sock ---> Swift Host ---> vsock ---> Guest dockerd
                                      |                         |
                            VM lifecycle / virtiofs      Rust kiri-moby-guest
                            TCP ports / memory balloon
```

The Swift GUI **never launches a Rust controller** or starts a second Docker Engine. Its standard Docker API traffic is direct over a private Unix socket; interactive container terminals launch the bundled Docker CLI with an explicit `DOCKER_HOST`. No WebKit, K8s, proprietary daemon, Windows/Linux host app, or custom container engine remains.

The Swift Host remains an independent long-lived process, so quitting the GUI does not stop the VM. Docker images/volumes/state stay in `~/.kiri-moby/vm/data.img`. The OS seed is a separate read-only ext4 disk; normal guest reboots do not overwrite user data.

## Build and verification

```bash
# macOS 14+ / Apple Silicon with Xcode and Swift 6
swift build --package-path crates/kiri/native -c release --product kiri-moby-ui
swiftc -parse-as-library -O crates/kiri/native/KiriMobyHost.swift -o kiri-moby-host

# Guest (Linux arm64, musl):
cargo build --release --target aarch64-unknown-linux-musl -p kiri-moby-bridge --bin kiri-moby-guest
```

CI builds signed arm64 Host+UI, the Linux Guest, verifies real AppKit screenshots with synthetic fixture data, and packages a single `.app`/DMG. See [native GUI](docs/MOBY_NATIVE_GUI.md), [engine](docs/MOBY_ENGINE.md), and [install](docs/MOBY_LOCAL_INSTALL_MACOS.md).

Licensed under Apache-2.0. Third-party copyright notices: [NOTICE](NOTICE).

## Native-only resource guarantee

The menu-bar item draws an 18pt monochrome hexagonal-cube outline with
AppKit `NSBezierPath` and sets `NSImage.isTemplate = true` for automatic
light/dark appearance. It has no color, rounded-square background or external
icon file. Finder/Dock retain the separate full-color `Kiri.icns` brand icon. CI checks native source, compiled framework links and
the assembled app for browser runtimes and web frontend assets using
`scripts/moby/audit-native-runtime.py`. Browser-opening actions use the
system browser outside the app; the app itself renders only SwiftUI/AppKit.
The current `NOTICE` contains the active native components and the Linux
kernel GPL-2.0-only license / source offer; obsolete web dependency notices
remain available in Git history, not in the installed app.

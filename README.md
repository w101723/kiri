# Kiri Moby

**Native Docker desktop for macOS Apple Silicon (ARM64) only.**

Kiri Moby consists of a SwiftUI/AppKit application with SwiftTerm terminals, Apple's Virtualization.framework for an ARM64 Linux VM, and the **standard upstream Docker Engine (dockerd)** inside the guest. No custom Kiri daemon, WebKit UI, Kubernetes subsystem, or Linux/Windows host app is included.

## Runtime

```text
Kiri Moby.app
  ├── Contents/MacOS/kiri-moby-ui       SwiftUI / AppKit / SwiftTerm
  ├── Contents/MacOS/kiri               short-lived JSON / PTY CLI bridge
  └── Contents/Resources/
      ├── bin/kiri-moby-host            Apple VZ VM, vsock Docker relay
      ├── bin/docker                    Docker CLI, Compose and Buildx plugins
      ├── guest/                        Linux ARM64 kernel / initramfs / ext4
      ├── Kiri.icns
      └── kiri-menubar-template@2x.png
             │
             ▼
~/.kiri-moby/run/docker.sock ↔ kiri-moby-host ↔ Linux guest dockerd
```

All Docker data lives in `~/.kiri-moby/vm/data.img`. The application uses its **own private Unix socket** and never changes your existing Docker contexts or contacts the discontinued Kiri daemon.

## Supported features

Containers, images, volumes, networks, Compose project inventory, Buildx, live container resource stats, logs, actual PTY terminal, VM CPU/RAM controls, and permissioned Mac folder sharing.

## Development

Requires macOS 14+ on Apple Silicon, Xcode and the Rust ARM64 target.

```bash
cargo xtask check
cargo xtask ui
cargo xtask host
```

The complete Guest + Host + SwiftUI signed app and DMG are built by [Moby milestone CI](.github/workflows/moby-milestone.yml). [Native UI CI](.github/workflows/moby-native-ui-check.yml) cross-compiles the arm64 application and backend. [Visual Preview CI](.github/workflows/moby-native-visual-preview.yml) captures a real AppKit window using synthetic test data.

Documentation: [Architecture](docs/MOBY_ENGINE.md) · [Native UI](docs/MOBY_NATIVE_GUI.md) · [macOS installation](docs/MOBY_LOCAL_INSTALL_MACOS.md) · [Signing](docs/MOBY_MACOS_SIGNING.md)

Apache-2.0 licensed. See [NOTICE](NOTICE) for third-party attributions.

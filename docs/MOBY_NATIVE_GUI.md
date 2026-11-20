# Kiri Moby Native SwiftUI/AppKit Frontend

## Architectural choice

The macOS Finder application now launches the arm64 executable
Contents/MacOS/kiri-moby-ui, written in SwiftUI/AppKit. The previous
WKWebView-based Rust GUI is not the default application entrypoint.

Persistent processes should be:
- SwiftUI GUI application (no WebKit WebContent/GPU/Networking helpers)
- kiri-moby-host (Docker API, VM lifecycle, file sharing)
- Apple Virtualization.framework XPC VM service (Linux VM memory)

The app also bundles Contents/MacOS/kiri as a **short-lived, local-only**
Rust command bridge, invoking the exact same Moby controller logic and
private Unix sockets. There is no new long-running backend server, new
Docker context, or duplicated container metadata database.

## Native GUI features

- Overview: real Docker Engine version, containers/images/volumes counts,
  configured maximum Guest RAM and live balloon target.
- Containers: search, list, start/stop/restart/pause/unpause, logs, exec,
  inspect, published localhost ports and remove.
- Images: search, pull, run, inspect, remove.
- Volumes and networks: list, create, inspect, remove.
- Compose: choose .yaml/.yml file with NSOpenPanel, up/down/ps/logs.
- Buildx: choose context folder, set tag and linux/arm64 or linux/amd64.
- Settings: VM start/stop/restart, explicit authorized Mac project directories.
- Native macOS menus, alerts, sidebar, searchable lists and menu bar icon.

The Docker engine remains upstream Moby, and user state remains in
~/.kiri-moby/vm/data.img. The Host process and Apple VZ backend remain
unchanged. The native UI sends no network requests to an external service.

## Package, signing, verification

Full ARM64 build compiles the native SwiftUI frontend and Rust CLI, then
bundles both into the same signed App. Info.plist CFBundleExecutable is
kiri-moby-ui. The original fixed personal P12, certificate fingerprint
and private root CA flow sign both executables and the independent Host,
then sign the outer Kiri Moby.app. The local installer validates both
executables' arm64 architecture and signature, not just the original CLI.

CI builds the SwiftUI binary and rejects direct WebKit/JavaScriptCore
linkage. The real P12 signing test uses its own clean macOS Runner, separate
from the synthetic private CA signing test. Full CI builds the entire DMG.

The old WebView implementation remains in the source tree during parity
validation as a rollback, but it is not launched by Finder in the new app.
Do not remove it before all existing Docker actions are verified.

## Required manual Apple Silicon acceptance

1. Launch the native app. It must not spawn Kiri-owned WebContent,
   WebKit GPU or WebKit Networking processes.
2. Confirm background kiri-moby-host and Apple VZ VM service continue
   working and the existing Docker data disk remains intact.
3. Test start/stop/restart VM, list, pull/run/stop/remove containers,
   inspect/logs/exec, and open published localhost port.
4. Test volumes, networks, Compose, arm64/amd64 Buildx and directory shares.
5. Quit/reopen GUI while background VM stays online.
6. Install using the existing one-time authorized personal installer and
   verify certificate fingerprint remains identical between releases.

A reduction in WebKit helper process count does not necessarily reduce
the 700+ MB VM XPC service footprint. That is separate VM memory management.

The private personal certificate alone still does not replace Apple
Developer ID notarization for fresh downloaded DMG drag-and-drop installs.

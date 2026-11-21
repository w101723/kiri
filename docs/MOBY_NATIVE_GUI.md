# Kiri Moby Native SwiftUI/AppKit Frontend

## Apple Silicon-only architecture

The macOS Finder application now launches the arm64 executable
Contents/MacOS/kiri-moby-ui, written in SwiftUI/AppKit. The retired WKWebView-based Rust GUI and its daemon are absent from this product.

Persistent processes should be:
- SwiftUI GUI application (no WebKit WebContent/GPU/Networking helpers)
- kiri-moby-host (Docker API, VM lifecycle, file sharing)
- Apple Virtualization.framework XPC VM service (Linux VM memory)

The app also bundles an in-process Swift Docker client which connects to the private Unix
socket directly. The Swift VM Host remains a separate process that outlives
the GUI. Linux Guest's minimal Rust vsock proxy remains unchanged.

## Native GUI features

- Overview: real Docker Engine version, containers/images/volumes counts,
  configured maximum Guest RAM and live balloon target.
- Containers: search, list, start/stop/restart/pause/unpause, logs, exec,
  inspect, published localhost ports and remove. The table also displays live
  Docker CPU utilization (multi-core percentages can exceed 100%), active
  working-set RAM and per-container memory limits with progress indication,
  cumulative network receive/transmit and disk read/write totals; hover for PIDs.
  Stopped containers show no live utilization rather than misleading zeroes.
  Telemetry is fetched via `/containers/{id}/stats?stream=false` every five
  seconds only on Containers and Compose, separately from the Docker list refresh.
  At most 64 containers and six stats requests at a time are sampled, each with
  a 5-second socket timeout. Stats errors do not block container actions.
- Images: search, pull, run, inspect, remove.
- Volumes and networks: list, create, inspect, remove.
- Compose: automatically discover projects from `com.docker.compose.project` labels,
  expand nested service/container rows and access the same container actions.
  No Compose YAML path or `up/down` command form is shown.
- Buildx: choose context folder, set tag and linux/arm64 or linux/amd64.
- Settings: persist host-aware CPU and maximum VM memory ceilings (1 CPU minimum,
  memory in 256 MiB increments), optionally restart VM to apply changes, plus
  explicit authorized Mac project directories.
- Logs: floating native window with refresh/follow toggle, bounded 200/1,000/5,000
  line tail, copy, clear. Logs are polled every two seconds, not streamed.
- Exec: floating PTY-backed `docker exec -it` shell with repeatable input,
  copy, clear and Ctrl-C. Line-oriented display is **not** a full VT100 emulator.
- Native macOS NavigationSplitView / system sidebar material, standard titlebar
  toolbar, searchable navigation, VM-resource popover and menu bar icon.
  Containers are shown in a native sortable multi-select SwiftUI Table
  (NSTableView on macOS), with context-menu batch actions and compact buttons.
- Mac HIG UI refinements: explicit non-localized `localhost:8080` links (no
  locale thousands separators), a system-titlebar application brand and VM
  status pill, primary-color sidebar labels including Chinese “存储卷”, and
  right-aligned Table actions after creation time. Rows keep only CPU% and
  active RAM plus a thin usage indicator; network/block I/O, PIDs and RAM
  limit are available from the per-row info popover.
- The charcoal console uses a single 34pt compact tab/action strip
  (`#1F1F23`) and a consistent `#141414` canvas in the AppKit log view and
  SwiftTerm terminal. Log follow and tail-length actions stay in that shared
  strip; detached windows use the actual macOS toolbar instead.
- A draggable vertical split embeds Exec and Logs into a dark console drawer.
  Sessions can be detached into real macOS WindowGroup windows which opt into
  native AppKit window tabbing. Detaching creates a new terminal process; it is
  **not** a seamless PTY migration.
- Logs use an AppKit NSTextView via NSViewRepresentable, with native find bar,
  disabled smart substitutions and incremental text updates. The bounded log
  fetching is still poll-based; no true stream has been implemented.
- Exec is configured to use **SwiftTerm 1.20.0** in the production SwiftPM
  executable, wrapping `LocalProcessTerminalView` in `NSViewRepresentable`.
  SwiftTerm owns the PTY, ANSI/xterm rendering, keyboard handling and PTY
  resize; it launches the already-signed bundled Kiri CLI, connecting through
  Kiri's existing private Docker socket. The bare-swiftc CI visual fixture
  intentionally falls back to the old line-oriented SwiftUI Text terminal.
  The SwiftTerm-linked arm64 binary has its **own required CI build gate**;
  only that gate proves the production native terminal compiles correctly.

The Docker engine remains upstream Moby, and user state remains in
~/.kiri-moby/vm/data.img. The Host process and Apple VZ backend remain
unchanged. The native UI sends no network requests to an external service.

## Package, signing, verification

Full ARM64 build compiles the native SwiftUI frontend and the Swift VZ Host, then
bundles both into the same signed App. Info.plist CFBundleExecutable is
kiri-moby-ui. The original fixed personal P12, certificate fingerprint
and private root CA flow sign both executables and the independent Host,
then sign the outer Kiri Moby.app. The local installer validates both
executables' arm64 architecture and signature, not just the original CLI.

CI builds the SwiftUI binary and rejects direct WebKit/JavaScriptCore
linkage. The real P12 signing test uses its own clean macOS Runner, separate
from the synthetic private CA signing test. Full CI builds the entire DMG.

The `moby-native-visual-preview.yml` workflow separately compiles the same
AppKit/SwiftUI UI source in a **test-only** macOS preview build and takes a real
window screenshot in a hosted macOS session. Its container status, logs and
terminal output are explicitly synthetic fixtures compiled only with
`KIRI_UI_PREVIEW`; production Apple Silicon binaries do not include them.
This permits layout and window overlap debugging without installing the app
or starting the Docker VM. It is not a substitute for live Docker acceptance.

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

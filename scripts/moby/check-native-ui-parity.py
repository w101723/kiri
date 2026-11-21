#!/usr/bin/env python3
"""Static UI contract: original Moby controls plus approved native Compose/VM updates.

The native SwiftUI app must also compile and undergo real-device acceptance.
"""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
NEW = (ROOT / "crates/kiri/native/MobyApp.swift").read_text(encoding="utf-8")
WORKFLOW = (ROOT / ".github/workflows/moby-milestone.yml").read_text()
SIGNER = (ROOT / "scripts/moby/sign-personal-macos.sh").read_text()
INSTALL = (ROOT / "scripts/moby/install-local-macos.sh").read_text()
errors = []

def has(haystack, needle, label):
    if needle not in haystack:
        errors.append(f"{label}: missing {needle!r}")

# HIG-native navigation intentionally replaces all legacy hand-painted bars.
if not all(token in NEW for token in (
    "NavigationSplitView {", "List(selection:", ".listStyle(.sidebar)",
    ".navigationSplitViewColumnWidth(", "nativeSidebarItem(.settings)",
    ".toolbar {", ".searchable(text:", "HSplitView {",
)):
    errors.append("Native macOS split/toolbar/sidebar contract is incomplete")

checks = [
    ('NavigationSplitView {', "System managed split navigation"),
    ('.windowToolbarStyle(.unified)', "Unified native macOS toolbar"),
    ('sidebarEngineStatus', "Engine status inset in native sidebar"),
    ('ContainerWorkspaceDetail(', "Native container workspace is scoped to Containers"),
    ('ModernInspectorView(', "Selected container inspector content"),
    ('ModernInspectorCard {', "Four grouped inspector cards"),
    ('InspectorMetricTile(', "Compact inspector dashboard metrics"),
    ('LinearGradient(', "Gradient area charts"),
    ('CopyableInspectorTag(', "Copyable native port and mount tags"),
    ('InspectorEnvironmentRow(entry:', "Per-key secret masking controls"),
    ('CompactContainerRow(item:', "Compact Mail-style container row"),
    ('List(selection: $selectedContainerIDs)', "Native compact container list"),
    ('.onHover { hovered = $0 }', "Hover-only container actions"),
    ('.defaultSize(width: 940, height: 600)', "Compact default window"),

    ('InspectorAreaChart(', "Real stats time-series visualizations"),
    ('statsHistory', "Bounded history from live Docker stats"),
    ('ContainerInspectDetails: Decodable', "Read-only Docker inspect details"),
    ('Text("Kiri 私有 Docker · 默认 Context 不变")', "Private Docker context in sidebar"),
    ('iconAction("停止", icon: "stop.circle")', "Borderless SF Symbol container actions"),
    ('private var sidebarEngineStatus: some View', "Sidebar status view"),

    ('.listStyle(.sidebar)', "macOS vibrancy sidebar material"),
    ('.badge(count)', "Native sidebar counter badges"),
    ('.searchable(text: $model.search, placement: .toolbar', "System toolbar search"),
    ('ToolbarItem(placement: .primaryAction)', "Native primary action"),
    ('.popover(isPresented: $showVMPopover)', "Compact VM popover"),
    ('vmResourcePopover', "VM resource and restart popover"),
    ('HSplitView {', "Resizable full-height container workspace"),
    ('ContainerDetailTab: String, CaseIterable', "Overview / Logs / Terminal segmented tabs"),
    ('.pickerStyle(.segmented)', "Native segmented detail navigation"),
    ('ForEach(loadedTerminalIDs.sorted()', "SwiftTerm views remain mounted when switching tabs"),
    ('EmbeddedContainerLogsView(', "Searchable inline log pane"),
    ('WindowGroup("容器控制台", id: "container-console"', "Real macOS console windows"),
    ('openWindow(id: "container-console", value: ConsoleSession(', "Pop-out from detail pane"),
    ('tabbingMode = .preferred', "AppKit native window tabbing"),
    ('ConsoleSession: Codable, Hashable, Identifiable', "Stable typed sessions"),
    ('NativeLogTextView: NSViewRepresentable', "Incremental NSTextView log renderer"),
    ('ConsoleAppearance.canvas', "Consistent charcoal console canvas"),
    ('ConsoleAppearance.toolbar', "Card-scoped dark console controls"),
    ('LabeledContent("网络接收（累计）"', "Network and disk moved into detail popover"),
    ('String(published)', "Port number grouping disabled"),

    ('view.usesFindBar = true', "AppKit native find bar"),
    ('storage.append(NSAttributedString(', "Incremental log text insertion"),
    ('model.refreshContainerStats()', "Periodic Docker stats refresh"),
    ('ContainerWorkspaceDetail(', "Ports, mounts and metadata live in detail pane"),
    ('containerOp("start"', "Start container"),
    ('containerOp("stop"', "Stop container"),
    ('containerOp("restart"', "Restart container"),
    ('containerOp("pause"', "Pause container"),
    ('containerOp("unpause"', "Resume container"),
    ('containerOp("remove"', "Remove container"),
    ('openConsole(.exec', "Exec opens console drawer"),
    ('openConsole(.logs', "Logs opens console drawer"),
    ('session.following.toggle()', "Live log follow control"),
    ('Button("最近 1,000 行")', "Log tail options"),
    ('session.clear()', "Clear logs"),
    ('postTerminal(.interrupt', "Exec interrupt"),
    ('Button("拉取镜像")', "Docker image pull"),
    ('Button("创建 Volume")', "Docker volume creation"),
    ('Button("创建网络")', "Docker network creation"),
    ('if !["bridge","host","none"].contains(item.Name)', "Protected default networks"),
    ('Text("Compose 项目")', "Expandable Compose project list"),
    ('private var composeProjects: [String]', "Compose group discovery"),
    ('ForEach(composeProjects, id:', "Compose grouped projects"),
    ('"com.docker.compose.service"', "Compose service label"),
    ('ForEach(members)', "Compose container rows"),
    ('Button("构建镜像")', "Buildx"),
    ('"linux/arm64"', "ARM64 target"),
    ('"linux/amd64"', "AMD64 target"),
    ('Text("虚拟机资源上限")', "VM CPU RAM settings"),
    ('Stepper(value: $model.resourceCPUs', "VM CPU control"),
    ('Slider(', "VM memory slider"),
    ('Button("仅保存")', "Persistent VM settings"),
    ('"保存并重启 VM"', "Apply VM config by restart"),
    ('Text("Mac 目录共享")', "Explicit shared Mac directories"),
    ('Button("选择共享目录…")', "Shares panel"),
    ('Button("应用更改并重启 VM")', "Apply shares"),
    ('Kiri 私有 Docker · 默认 Context 不变', "Private Docker context status in sidebar"),
]
for key, label in checks:
    has(NEW, key, label)

if any(s in NEW for s in ("VSplitView {", "UnifiedConsoleDrawer(", ".inspector(isPresented:")):
    errors.append("Legacy console drawer or overlay inspector returned")
if ".safeAreaInset(edge: .bottom, spacing: 0) { footer }" in NEW:
    errors.append("White full-width status footer reintroduced below console")
if ".tableStyle(.inset(alternatesRowBackgrounds: true))" in NEW:
    errors.append("Old blank zebra table stripes reintroduced")

# Containers deliberately use a narrow headerless List rather than Table.
if "Table(sorted, selection: $selectedContainerIDs" in NEW:
    errors.append("Wide container Table returned")
if ".environment(\\.colorScheme, .dark)" in NEW:
    errors.append("Console must follow system appearance")
if "overviewCard(item)\n                        resourceCard(item)" in NEW:
    errors.append("Duplicate container identity card returned")

# SwiftUI LocalizedStringKey interpolates Int with grouping separators.
if 'Button("localhost:\\(published)' in NEW:
    errors.append("localhost labels must interpolate String(port), not Int")

for label in ("Containers", "Images", "Volumes", "Networks", "Compose", "Builds", "Settings"):
    has(NEW, label, "Native navigation")

has(WORKFLOW, "CFBundleExecutable</key><string>kiri-moby-ui", "Native Finder binary")
has(NEW, 'NSImage(size: size, flipped: false)', "Menu-bar renders a vector NSImage")
has(NEW, 'NSSize(width: 18, height: 18)', "18pt native status-bar mark")
has(NEW, 'let outline = NSBezierPath()', "Open-backed six-sided brand silhouette")
has(NEW, 'let folds = NSBezierPath()', "Inverted-Y cube folds")
has(NEW, 'for corner in [top, lowerLeft, lowerRight]', "Three-way cube face alignment")
has(NEW, 'image.isTemplate = true', "System-tinted monochrome menu-bar icon")
has(NEW, '.renderingMode(.template)', "SwiftUI honors template rendering")
if 'Bundle.main.url(forResource: "Kiri", withExtension: "icns")' in NEW:
    errors.append("Colorful Dock app icon must not be reused for the status bar")
if '.renderingMode(.original)' in NEW or 'image.isTemplate = false' in NEW:
    errors.append("Status bar icon must adapt to light/dark system appearance")
if "kiri-menubar-template@2x.png" in NEW or "kiri-menubar-template@2x.png" in WORKFLOW:
    errors.append("Retired standalone menu-bar icon must not be bundled")
for text, label in [(SIGNER, "Personal signer"), (INSTALL, "Local installer")]:
    has(text, "Contents/MacOS/kiri-moby-ui", label)

# The Linux ARM64 Guest IS required for Apple Silicon Docker VM.
for required in ("guest/kernel/build.sh", "scripts/moby/build-guest.sh"):
    if not (ROOT / required).is_file():
        errors.append(f"Required Docker Guest build source missing: {required}")
for forbidden in (
    "crates/kiri/src", "crates/kiri-vmm", "xtask",
    "crates/kiri/src/daemon", "crates/kiri/src/ui",
    "crates/kiri-image", "crates/kiri-proto", "crates/kiri-share-proto",
    "crates/kiri-win", "crates/kiri-init", "crates/kiri/src/ui/gtk.rs",
    "crates/kiri/src/ui/linux.rs", "packaging/linux", "installer/windows",
):
    if (ROOT / forbidden).exists():
        errors.append(f"Unsupported host source remains: {forbidden}")

runtime = (ROOT / "crates/kiri/native/MobyRuntime.swift").read_text(encoding="utf-8")
host = (ROOT / "crates/kiri/native/KiriMobyHost.swift").read_text(encoding="utf-8")
for term in ("Contents/MacOS/kiri", "moby-native", 'systemImage:"shippingbox"'):
    if term in NEW:
        errors.append(f"Native GUI still references retired Rust bridge: {term}")
for token in ("AF_UNIX", "run/docker.sock", "func snapshot()", "func stats()", "terminalEnvironment()"):
    has(runtime, token, "Native Swift Docker Client")
for token in ("import Virtualization", "VZVirtualMachineConfiguration", "vsockDocker",
              "host-control.sock", "VZVirtioTraditionalMemoryBalloonDevice"):
    has(host, token, "Native independent VM Helper")
if errors:
    print("FAIL: Native Moby parity contract:\n  - " + "\n  - ".join(errors), file=sys.stderr)
    sys.exit(1)
print(f"PASS: {len(checks)} native Swift Moby UI / Host assertions and macOS-only scope.")

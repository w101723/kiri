#!/usr/bin/env python3
"""Static UI contract: original Moby controls plus approved native Compose/VM updates.

The native SwiftUI app must also compile and undergo real-device acceptance.
"""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[2]
OLD = (ROOT / "crates/kiri/src/ui/moby.html").read_text(encoding="utf-8")
NEW = (ROOT / "crates/kiri/native/MobyApp.swift").read_text(encoding="utf-8")
WORKFLOW = (ROOT / ".github/workflows/moby-milestone.yml").read_text()
SIGNER = (ROOT / "scripts/moby/sign-personal-macos.sh").read_text()
INSTALL = (ROOT / "scripts/moby/install-local-macos.sh").read_text()
errors = []

def has(haystack, needle, label):
    if needle not in haystack:
        errors.append(f"{label}: missing {needle!r}")

legacy_nav = re.findall(
    r'<button data-page="([^"]+)"',
    OLD.split("<aside>", 1)[1].split("</aside>", 1)[0])
if legacy_nav != [
    "containers", "compose", "images", "volumes", "networks", "build", "settings"
]:
    errors.append("Original Moby navigation unexpectedly changed")
if not re.search(
    r"ForEach\(\[Page\.containers, \.compose, \.images, \.volumes, \.networks, \.builds\]",
    NEW,
) or "navButton(.settings)" not in NEW:
    errors.append("Native sidebar navigation order does not match original")

checks = [
    ("frame(height: 44)", "Original title strip"),
    ("? 60 : 212", "Original 212pt sidebar / 60pt rail"),
    ('Text("DOCKER")', "Docker sidebar section"),
    ('Text("KIRI")', "Settings sidebar section"),
    ('Text("Linux VM")', "VM status card"),
    ('Text("CPUs")', "VM CPU meter"),
    ('Text("Balloon")', "VM Balloon target"),
    ('Text("⌘K")', "Search shortcut"),
    ('model.isLight.toggle()', "Original theme control"),
    ('model.sidebarCollapsed.toggle()', "Rail toggle"),
    ('case all = "All", running = "Running", stopped = "Stopped", failed = "Failed"',
     "Four container filter chips"),
    ('model.collapsedProjects.insert(project)', "Compose collapse"),
    ('model.collapsedProjects.remove(project)', "Compose expand"),
    ('"com.docker.compose.project"', "Compose project grouping"),
    ('tableTitle("NAME"', "Container name"),
    ('tableTitle("STATE"', "Container state"),
    ('tableTitle("PORTS"', "Container ports"),
    ('tableTitle("SHARE"', "Container share"),
    ('tableTitle("SIZE"', "Container size"),
    ('tableTitle("CREATED"', "Container created"),
    ('tableTitle("ACTIONS"', "Container inline actions"),
    ('"http://127.0.0.1:', "Published port link"),
    ('containerOp("start"', "Start container"),
    ('containerOp("stop"', "Stop container"),
    ('containerOp("restart"', "Restart container"),
    ('containerOp("pause"', "Pause container"),
    ('containerOp("unpause"', "Resume container"),
    ('containerOp("remove"', "Remove container"),
    ('smallAction("执行")', "Container exec"),
    ('smallAction("日志")', "Container logs"),
    ('smallAction("详情")', "Container inspect"),
    ('smallAction("删除"', "Container delete"),
    ('Button("拉取镜像")', "Pull image"),
    ('Button("创建 Volume")', "Create volume"),
    ('Button("创建网络")', "Create network"),
    ('if !["bridge","host","none"].contains(item.Name)', "Default networks are protected"),
    ('Text("Compose 项目")', "Compose inventory header"),
    ('private var composeProjects: [String]', "Compose project discovery"),
    ('ForEach(composeProjects, id:', "Compose grouped project list"),
    ('"com.docker.compose.service"', "Compose service labels"),
    ('ForEach(members)', "Compose nested container rows"),
    ('tableValue(containerButtons(container)', "Compose inline container controls"),
    ('Text("虚拟机资源上限")', "CPU and memory resource settings"),
    ('Stepper(value: $model.resourceCPUs', "Host-limited CPU selector"),
    ('Slider(', "RAM ceiling slider"),
    ('Button("仅保存")', "Save VM resource settings"),
    ('"保存并重启 VM"', "Apply VM resources by restart"),
    ('Button("构建镜像")', "Buildx"),
    ('"linux/arm64"', "Buildx ARM64"),
    ('"linux/amd64"', "Buildx AMD64"),
    ('Text("Mac 目录共享")', "Mac shares settings"),
    ('Button("选择共享目录…")', "Mac share picker"),
    ('Button("应用更改并重启 VM")', "Apply share and restart"),
    ('OrbStack/default Docker context unchanged', "Original footer"),
]
for key, label in checks:
    has(NEW, key, label)

for label in ("Containers", "Images", "Volumes", "Networks", "Compose", "Builds", "Settings"):
    has(OLD, label, "Original navigation")
    has(NEW, label, "Native navigation")

has(WORKFLOW, "CFBundleExecutable</key><string>kiri-moby-ui", "Native Finder binary")
for text, label in [(SIGNER, "Personal signer"), (INSTALL, "Local installer")]:
    has(text, "Contents/MacOS/kiri-moby-ui", label)

# The Linux ARM64 Guest IS required for Apple Silicon Docker VM.
for required in ("guest/kernel/build.sh", "scripts/moby/build-guest.sh"):
    if not (ROOT / required).is_file():
        errors.append(f"Required Docker Guest build source missing: {required}")
for forbidden in (
    "crates/kiri-win", "crates/kiri-init", "crates/kiri/src/ui/gtk.rs",
    "crates/kiri/src/ui/linux.rs", "packaging/linux", "installer/windows",
):
    if (ROOT / forbidden).exists():
        errors.append(f"Unsupported host source remains: {forbidden}")

if errors:
    print("FAIL: Native Moby parity contract:\n  - " + "\n  - ".join(errors), file=sys.stderr)
    sys.exit(1)
print(f"PASS: {len(checks)} native Moby UI parity assertions and macOS-only scope.")

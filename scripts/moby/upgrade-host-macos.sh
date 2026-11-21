#!/usr/bin/env bash
# Safely upgrade only the Kiri Moby Apple Silicon Host launcher.
# Does not touch Guest assets, vm/data.img, Docker contexts or OrbStack.
set -euo pipefail
umask 077
if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <kiri-moby-host-arm64.zip>" >&2
    exit 2
fi
[ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = arm64 ] ||
    { echo "Requires Apple Silicon macOS" >&2; exit 2; }
data="${KIRI_MOBY_DATA_DIR:-$HOME/.kiri-moby}"
[ ! -L "$data" ] || { echo "Refusing symlink data dir" >&2; exit 2; }
[ -d "$data/bin" ] || { echo "Missing Host install: $data/bin" >&2; exit 2; }
[ -f "$1" ] || { echo "Artifact zip missing: $1" >&2; exit 2; }
if pgrep -x "Kiri Moby Helper" >/dev/null 2>&1 || pgrep -x kiri-moby-host >/dev/null 2>&1; then
    echo "Stop kiri-moby-host with Ctrl+C before upgrading." >&2
    exit 2
fi
for tool in unzip tar codesign lipo mktemp; do
    command -v "$tool" >/dev/null ||
        { echo "Missing $tool" >&2; exit 2; }
done
work="$(mktemp -d "$data/.host-upgrade.XXXXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/zip" "$work/bin"
unzip -q "$1" -d "$work/zip"
archive="$(find "$work/zip" -type f -name kiri-moby-host-arm64.tgz -print -quit)"
[ -n "$archive" ] || { echo "Artifact is missing the expected .tgz" >&2; exit 2; }
tar -xzf "$archive" -C "$work/bin" kiri-moby-host
binary="$work/bin/kiri-moby-host"
[ "$(lipo "$binary" -archs)" = arm64 ] ||
    { echo "Expected an ARM64-only Mach-O binary" >&2; exit 2; }
codesign --verify --strict --verbose=2 "$binary"
chmod 700 "$binary"
if [ -e "$data/bin/kiri-moby-host" ]; then
    backup="$data/bin/kiri-moby-host.before-events-$(date +%Y%m%d-%H%M%S)"
    [ ! -e "$backup" ] || { echo "Backup already exists: $backup" >&2; exit 2; }
    mv "$data/bin/kiri-moby-host" "$backup"
    echo "Previous Host saved: $backup"
fi
mv "$binary" "$data/bin/kiri-moby-host"
echo "Updated Host only. Guest VM disk and images unchanged."
"$data/bin/kiri-moby-host" --version

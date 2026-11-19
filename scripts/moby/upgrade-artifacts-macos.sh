#!/bin/bash
# Offline-only upgrade of the experimental Kiri/Moby ARM64 artifacts.
# Preserve vm/data.img (Docker containers, images and volumes), and do not touch OrbStack.
set -euo pipefail
if [ "$#" -ne 2 ]; then
  echo "Usage: $0 <kiri-moby-guest-arm64.zip> <kiri-moby-host-arm64.zip>" >&2
  exit 2
fi
[ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = arm64 ] || { echo "Requires Apple Silicon Mac" >&2; exit 2; }
dest="${KIRI_MOBY_DATA_DIR:-$HOME/.kiri-moby}"
[ -d "$dest/guest" ] && [ -d "$dest/bin" ] || { echo "Not installed: $dest" >&2; exit 2; }
[ -f "$1" ] && [ -f "$2" ] || { echo "Missing GitHub Actions artifact ZIP" >&2; exit 2; }
if pgrep -fl "[k]iri-moby-host" | grep -q kiri-moby-host; then
  echo "A kiri-moby-host process is still running. Stop it with Ctrl+C first." >&2
  exit 2
fi
# Keep the previous boot and host bytes for offline rollback. Never touch vm/data.img.
work="$(mktemp -d "$dest/.upgrade.XXXXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/gzip" "$work/hzip" "$work/guest" "$work/host"
unzip -q "$1" -d "$work/gzip"
unzip -q "$2" -d "$work/hzip"
g="$(find "$work/gzip" -type f -name kiri-moby-guest-arm64.tgz -print -quit)"
h="$(find "$work/hzip" -type f -name kiri-moby-host-arm64.tgz -print -quit)"
[ -n "$g" ] && [ -n "$h" ] || { echo "ZIP files lack their expected .tgz bundles" >&2; exit 2; }
tar -xzf "$g" -C "$work/guest" Image initramfs.cpio data.img.tgz SHA256SUMS
(cd "$work/guest" && shasum -a 256 -c SHA256SUMS)
tar -xzf "$h" -C "$work/host" kiri-moby-host
file "$work/host/kiri-moby-host" | grep -q arm64 || { echo "Host not arm64" >&2; exit 2; }
codesign --verify --strict --verbose=2 "$work/host/kiri-moby-host"
# Do not modify a mounted ext4 filesystem. Keep a versioned, private backup.
backup="$dest/backup-$(date +%Y%m%d-%H%M%S)"
if [ -e "$backup" ]; then echo "Backup already exists: $backup" >&2; exit 2; fi
mkdir -m 700 "$backup"
mkdir -m 700 "$backup/guest" "$backup/bin"
for name in Image initramfs.cpio data.img.tgz SHA256SUMS; do
  if [ -f "$dest/guest/$name" ]; then
    mv "$dest/guest/$name" "$backup/guest/$name"
  fi
  mv "$work/guest/$name" "$dest/guest/$name"
done
if [ -f "$dest/bin/kiri-moby-host" ]; then
  mv "$dest/bin/kiri-moby-host" "$backup/bin/kiri-moby-host"
fi
mv "$work/host/kiri-moby-host" "$dest/bin/kiri-moby-host"
chmod 700 "$dest/bin/kiri-moby-host"
echo "Updated Kiri Moby boot images and Host launcher."
echo "Backup: $backup"
echo "PRESERVED: $dest/vm/data.img"
echo "Restart with:"
printf '  KIRI_MOBY_DATA_DIR="%s" KIRI_MOBY_DISABLE_PORT_FORWARD=1 "%s/bin/kiri-moby-host"\n' "$dest" "$dest"
echo "For logs: tail -n 120 \"$dest/logs/console.log\""

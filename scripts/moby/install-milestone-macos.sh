#!/bin/bash
# Install or upgrade a single pinned Host+Guest Moby milestone artifact.
# Does not touch OrbStack, Docker contexts, or existing vm/data.img.
set -euo pipefail
umask 077
if [ "$#" -ne 1 ]; then
  echo "Usage: $0 <kiri-moby-macos-arm64-bundle.zip>" >&2
  exit 2
fi
[ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = arm64 ] || {
  echo "Requires macOS Apple Silicon" >&2; exit 2;
}
for bin in unzip tar shasum codesign lipo mktemp; do
  command -v "$bin" >/dev/null || { echo "Missing: $bin" >&2; exit 2; }
done
[ -f "$1" ] || { echo "Artifact not found: $1" >&2; exit 2; }
if pgrep -x kiri-moby-host >/dev/null 2>&1; then
  echo "Stop the existing Kiri Moby Host before upgrading its Guest." >&2
  exit 2
fi
dest="${KIRI_MOBY_DATA_DIR:-$HOME/.kiri-moby}"
[ ! -L "$dest" ] || { echo "Refusing symbolic-link data directory" >&2; exit 2; }
mkdir -p "$dest" "$dest/guest" "$dest/bin" "$dest/run"
chmod 700 "$dest" "$dest/guest" "$dest/bin" "$dest/run"
stage="$(mktemp -d "$dest/.milestone.XXXXXXXX")"
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/archive" "$stage/out"
unzip -q "$1" -d "$stage/archive"
tgz="$(find "$stage/archive" -type f -name kiri-moby-macos-arm64-bundle.tgz -print -quit)"
[ -n "$tgz" ] || { echo "Expected milestone .tgz not found" >&2; exit 2; }
tar -xzf "$tgz" -C "$stage/out" \
  guest/Image guest/initramfs.cpio guest/data.img.tgz \
  guest/system.img.tgz guest/rootfs.revision guest/SHA256SUMS \
  bin/kiri-moby-host SOURCE_REVISION BUNDLE_SHA256SUMS
(cd "$stage/out" && shasum -a 256 -c BUNDLE_SHA256SUMS)
(cd "$stage/out/guest" && shasum -a 256 -c SHA256SUMS)
[ "$(lipo "$stage/out/bin/kiri-moby-host" -archs)" = arm64 ] || {
  echo "The macOS Host artifact is not ARM64-only" >&2; exit 2;
}
codesign --verify --strict --verbose=2 "$stage/out/bin/kiri-moby-host"
chmod 700 "$stage/out/bin/kiri-moby-host"
backup="$dest/backup-milestone-$(date +%Y%m%d-%H%M%S)"
if [ -e "$backup" ]; then
  echo "Backup path exists: $backup" >&2; exit 2
fi
mkdir -m 700 "$backup"
mkdir -m 700 "$backup/guest" "$backup/bin"
for filename in Image initramfs.cpio data.img.tgz system.img.tgz rootfs.revision SHA256SUMS; do
  if [ -e "$dest/guest/$filename" ]; then
    mv "$dest/guest/$filename" "$backup/guest/$filename"
  fi
  mv "$stage/out/guest/$filename" "$dest/guest/$filename"
done
if [ -e "$dest/bin/kiri-moby-host" ]; then
  mv "$dest/bin/kiri-moby-host" "$backup/bin/kiri-moby-host"
fi
mv "$stage/out/bin/kiri-moby-host" "$dest/bin/kiri-moby-host"
cp "$stage/out/SOURCE_REVISION" "$dest/guest/SOURCE_REVISION"
echo "Installed Host + Guest from the same revision: $(cat "$dest/guest/SOURCE_REVISION")"
echo "Previous boot assets backed up: $backup"
echo "Preserved persistent Docker disk: $dest/vm/data.img"
echo "No Docker context or other installed Docker engine changed."

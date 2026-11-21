#!/bin/bash
# Install both GitHub Actions artifacts on Apple Silicon without affecting OrbStack.
set -euo pipefail
if [ "$#" -ne 2 ]; then
  echo "Usage: $0 <kiri-moby-guest-arm64.zip> <kiri-moby-host-arm64.zip>" >&2
  exit 2
fi
[ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = arm64 ] || {
  echo "Only macOS Apple Silicon is supported" >&2; exit 2;
}
for tool in unzip tar shasum codesign file mktemp; do
  command -v "$tool" >/dev/null || { echo "Missing $tool" >&2; exit 2; }
done
guest_zip="$1"
host_zip="$2"
[ -f "$guest_zip" ] && [ -f "$host_zip" ] || { echo "Both artifact ZIPs must exist" >&2; exit 2; }
dest="${KIRI_MOBY_DATA_DIR:-$HOME/.kiri-moby}"
[ ! -L "$dest" ] || { echo "Refusing symlink for guest data dir" >&2; exit 2; }
mkdir -p "$dest" "$dest/guest" "$dest/bin" "$dest/run"
chmod 700 "$dest" "$dest/guest" "$dest/bin" "$dest/run"
for name in Image initramfs.cpio data.img.tgz system.img.tgz rootfs.revision SHA256SUMS; do
  [ ! -e "$dest/guest/$name" ] || { echo "Refusing to overwrite $dest/guest/$name" >&2; exit 2; }
done
[ ! -e "$dest/bin/kiri-moby-host" ] || {
  echo "Refusing to overwrite $dest/bin/kiri-moby-host" >&2; exit 2;
}
tmp="$(mktemp -d "$dest/.stage.XXXXXXXX")"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/guestzip" "$tmp/hostzip" "$tmp/root" "$tmp/bin"
unzip -q "$guest_zip" -d "$tmp/guestzip"
unzip -q "$host_zip" -d "$tmp/hostzip"
g="$(find "$tmp/guestzip" -type f -name kiri-moby-guest-arm64.tgz -print -quit)"
h="$(find "$tmp/hostzip" -type f -name kiri-moby-host-arm64.tgz -print -quit)"
[ -n "$g" ] && [ -n "$h" ] || {
  echo "Expected .tgz not found inside the GitHub artifact ZIPs" >&2; exit 2;
}
tar -xzf "$g" -C "$tmp/root" Image initramfs.cpio data.img.tgz system.img.tgz rootfs.revision SHA256SUMS
(cd "$tmp/root" && shasum -a 256 -c SHA256SUMS)
tar -xzf "$h" -C "$tmp/bin" kiri-moby-host
file "$tmp/bin/kiri-moby-host"
file "$tmp/bin/kiri-moby-host" | grep -q arm64 || {
  echo "Launcher is not an Apple Silicon binary" >&2; exit 2;
}
codesign --verify --strict --verbose=2 "$tmp/bin/kiri-moby-host"
chmod 700 "$tmp/bin/kiri-moby-host"
for name in Image initramfs.cpio data.img.tgz system.img.tgz rootfs.revision SHA256SUMS; do
  mv "$tmp/root/$name" "$dest/guest/$name"
done
mv "$tmp/bin/kiri-moby-host" "$dest/bin/kiri-moby-host"
echo "Installed in $dest"
echo "Terminal 1:"
printf '  KIRI_MOBY_DATA_DIR="%s" "%s/bin/kiri-moby-host"\n' "$dest" "$dest"
echo "Terminal 2:"
printf '  docker context create kiri-moby --docker "host=unix://%s/run/docker.sock"\n' "$dest"
echo '  docker --context kiri-moby version'
echo '  docker --context kiri-moby run --rm alpine:3.22 echo hello'
echo "VM boot log: $dest/logs/console.log"

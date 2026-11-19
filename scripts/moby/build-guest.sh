#!/usr/bin/env bash
# ARM64 Linux host only. Requires Docker, sudo, e2fsprogs, cpio and Cargo.
# Build kernel separately via cargo xtask kernel, then copy guest/out/Image.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
out="$root/target/moby-guest"
[ "$#" -eq 0 ] || out="$1"
size="$(printenv KIRI_MOBY_DISK_GB || echo 48)"
case "$size" in ''|*[!0-9]*) echo "KIRI_MOBY_DISK_GB must be an integer" >&2; exit 2 ;; esac
[ "$size" -ge 8 ] && [ "$size" -le 256 ] || { echo "disk size must be 8-256 GiB" >&2; exit 2; }
[ "$(uname -s)" = Linux ] && [ "$(uname -m)" = aarch64 ] || { echo "Requires Linux ARM64 native host" >&2; exit 2; }
for p in docker cpio mkfs.ext4 tar gzip cargo; do command -v "$p" >/dev/null || { echo "missing $p" >&2; exit 2; }; done
mkdir -p "$out"
work="$(mktemp -d)"
tag="kiri-moby-guest:temp-$$"
cid=""
cleanup() {
  [ -z "$cid" ] || docker rm -f "$cid" >/dev/null 2>&1 || true
  docker image rm "$tag" >/dev/null 2>&1 || true
  sudo rm -rf "$work"
}
trap cleanup EXIT
mkdir -p "$work/context" "$work/root"
cp "$root/scripts/moby/guest/"* "$work/context/"
binary="$root/target/aarch64-unknown-linux-musl/release/kiri-moby-guest"
if [ ! -x "$binary" ]; then
  cargo build --release --target aarch64-unknown-linux-musl -p kiri-moby-bridge --bin kiri-moby-guest
fi
cp "$binary" "$work/context/kiri-moby-guest"
docker build --platform linux/arm64 -t "$tag" "$work/context"
cid="$(docker create --platform linux/arm64 "$tag" /bin/true)"
docker export "$cid" | sudo tar -xpf - -C "$work/root"
docker rm "$cid" >/dev/null
cid=""
sudo mkdir -p "$work/root/dev"
[ -e "$work/root/dev/console" ] || sudo mknod -m 600 "$work/root/dev/console" c 5 1
[ -e "$work/root/dev/null" ] || sudo mknod -m 666 "$work/root/dev/null" c 1 3
( cd "$work/root" && sudo find . -print0 | LC_ALL=C sort -z | sudo cpio --null --quiet -o -H newc ) > "$out/initramfs.cpio"
disk="$out/data.img"
rm -f "$disk"
truncate -s "$size"G "$disk"
mkfs.ext4 -q -F -m 0 -L kiri-moby -E lazy_itable_init=1,lazy_journal_init=1 "$disk"
( cd "$out" && tar --sparse -cf - data.img | gzip -1 > data.img.tgz )
rm -f "$disk"
( cd "$out" && sha256sum initramfs.cpio data.img.tgz > SHA256SUMS )
echo "Guest rootfs: $out/initramfs.cpio"
echo "Sparse ext4 disk: $out/data.img.tgz ($size GiB virtual)"

#!/usr/bin/env bash
# Isolated libkrun2 Guest artifact builder. Never opens Kiri VM disk.
# Usage: scripts/moby/build-libkrun-lab-guest.sh /absolute/output-directory
# Requires: Linux ARM64, Docker, sudo, cpio, tar, sha256sum.
set -euo pipefail
[[ "$(uname -s)" == Linux && "$(uname -m)" == aarch64 ]] || {
  echo "Requires native Linux ARM64 for kernel and Alpine rootfs" >&2; exit 2;
}
[[ $# == 1 && "$1" == /* ]] || {
  echo "Usage: $0 /absolute/output-directory" >&2; exit 2;
}
for cmd in docker sudo cpio tar sha256sum; do
  command -v "$cmd" >/dev/null || { echo "Missing $cmd" >&2; exit 2; }
done
root="$(cd "$(dirname "$0")/../.." && pwd)"
out="$1"
mkdir -p "$out"
work="$(mktemp -d)"
cid=""
cleanup() {
  [[ -z "$cid" ]] || docker rm -f "$cid" >/dev/null 2>&1 || true
  sudo rm -rf -- "$work"
}
trap cleanup EXIT
mkdir -p "$work/kernel/patches" "$work/kernel-build" "$work/alpine" "$work/boot/bin" "$work/boot/lib" \
  "$work/boot/dev" "$work/boot/proc" "$work/boot/sys" "$work/boot/tmp"
cp "$root/guest/kernel/build.sh" "$work/kernel/"
cp "$root/guest/kernel/kiri.config" "$work/kernel/"
cp "$root/guest/kernel/patches/"*.patch "$work/kernel/patches/"
# Only the throwaway kernel gets MMIO + zram; production kernel is untouched.
cat >> "$work/kernel/kiri.config" <<'LAB_KCONFIG'
CONFIG_VIRTIO_MMIO=y
CONFIG_ZRAM=y
CONFIG_ZRAM_BACKEND_LZ4=y
CONFIG_ZRAM_DEF_COMP_LZ4=y
LAB_KCONFIG
docker run --rm --platform linux/arm64 \
  -e DEBIAN_FRONTEND=noninteractive -e KARCH=arm64 \
  -v "$work/kernel:/src:ro" -v "$work/kernel-build:/build" -v "$out:/out" \
  debian:trixie sh /src/build.sh
grep -Fxq 'CONFIG_VIRTIO_MMIO=y' "$out/.config" || {
  echo "Missing virtio-mmio from built kernel" >&2; exit 1;
}
grep -Fxq 'CONFIG_PAGE_REPORTING=y' "$out/.config" || {
  echo "Missing free page reporting from built kernel" >&2; exit 1;
}
grep -Fxq 'CONFIG_VIRTIO_BALLOON=y' "$out/.config" || {
  echo "Missing virtio balloon from built kernel" >&2; exit 1;
}
for feature in CONFIG_ZRAM CONFIG_ZRAM_BACKEND_LZ4 CONFIG_ZRAM_DEF_COMP_LZ4; do
  grep -Fxq "$feature=y" "$out/.config" || {
    echo "Missing $feature from isolated kernel" >&2; exit 1;
  }
done
# Only the Alpine BusyBox + musl dynamic loader enter the RAM-only initrd.
# No rootfs, no Docker binaries, and no persistent disk are attached.
docker pull --platform linux/arm64 alpine:3.22
cid="$(docker create --platform linux/arm64 alpine:3.22 /bin/true)"
docker export "$cid" | sudo tar -xpf - -C "$work/alpine"
docker rm "$cid" >/dev/null
cid=""
cp -a "$work/alpine/bin/busybox" "$work/boot/bin/busybox"
for lib in ld-musl-aarch64.so.1 libc.musl-aarch64.so.1; do
  [[ -e "$work/alpine/lib/$lib" || -L "$work/alpine/lib/$lib" ]] || {
    echo "Alpine musl library missing: $lib" >&2; exit 1;
  }
  cp -a "$work/alpine/lib/$lib" "$work/boot/lib/$lib"
done
# Force the static build to be independent of host libraries and libkrun.
docker run --rm --platform linux/arm64 \
  -v "$root/scripts/moby:/src:ro" -v "$work/boot/bin:/out" \
  alpine:3.22 sh -ec \
  'apk add --no-cache build-base >/dev/null && cc -static -Os -s -Wall -Wextra -Werror -o /out/kiri-lab-anon /src/libkrun-lab-anon.c'
test -s "$work/boot/bin/kiri-lab-anon"
# Alpine BusyBox includes mkswap, but not swapon. The tiny static
# kiri-lab-anon process invokes the Linux swapon(2) syscall directly.
if ! docker run --rm --platform linux/arm64 --entrypoint /bin/busybox \
  alpine:3.22 --list | grep -Fx 'mkswap' >/dev/null; then
  echo "Alpine BusyBox lacks mkswap" >&2; exit 1;
fi
for cmd in sh mount mkdir grep sleep dd rm cat head mkswap; do
  ln -s busybox "$work/boot/bin/$cmd"
done
cp "$root/scripts/moby/libkrun-lab-init" "$work/boot/init"
chmod 0755 "$work/boot/init"
sudo mknod -m 600 "$work/boot/dev/console" c 5 1
sudo mknod -m 666 "$work/boot/dev/null" c 1 3
(
  cd "$work/boot"
  sudo find . -print0 | LC_ALL=C sort -z | sudo cpio --null --quiet -o -H newc
) > "$out/initramfs.cpio"
test -s "$out/Image"
test -s "$out/initramfs.cpio"
test "$(stat -c '%s' "$out/initramfs.cpio")" -lt 16777216
! ( cpio -it --quiet < "$out/initramfs.cpio" | grep -Eq '(^|/)(dockerd|containerd|runc)$' )
cp "$out/.config" "$out/kernel.config"
rm -f "$out/.config"
printf '%s\n' "RAM-only MMIO + Free Page Reporting + optional zram compression Guest; no persistent disk" > "$out/README.txt"
(cd "$out" && sha256sum Image initramfs.cpio kernel.config README.txt > SHA256SUMS)
echo "Built isolated lab Guest: $out (MMIO, balloon and page reporting enabled)"

#!/usr/bin/env bash
# Extract a throwaway *guest image initramfs* into an isolated RAM-only lab.
# Requires a Linux host with sudo, cpio and BusyBox in the source Alpine root.
# This does not read or modify ~/.kiri-moby/vm/data.img.
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 /absolute/source/initramfs.cpio /absolute/output/lab-initramfs.cpio" >&2
  exit 2
fi
src="$(realpath "$1")"
dst="$(realpath -m "$2")"
[[ -f "$src" && "$src" != "$dst" ]] || {
  echo "Source must exist and must differ from destination" >&2; exit 2;
}
[[ "$(uname -s)" == Linux ]] || { echo "Linux host required" >&2; exit 2; }
for cmd in cpio sudo find sort; do
  command -v "$cmd" >/dev/null || { echo "Missing $cmd" >&2; exit 2; }
done

work="$(mktemp -d)"
cleanup() {
  [[ -d "$work" ]] && sudo rm -rf -- "$work"
}
trap cleanup EXIT
mkdir -p "$work/root"
(
  cd "$work/root"
  sudo cpio -idm --no-absolute-filenames --quiet < "$src"
)
sudo tee "$work/root/init" >/dev/null <<'LAB_INIT'
#!/bin/sh
set -eu
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
mount -t devtmpfs devtmpfs /dev
exec >/dev/console 2>&1
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mkdir -p /tmp
mount -t tmpfs -o size=512m tmpfs /tmp
echo 'KIRI-LIBKRUN-MEMLAB READY (no disk, no network)'
cat /proc/meminfo | head -5
sleep 10
echo 'KIRI-LIBKRUN-MEMLAB ALLOCATING 256MiB'
dd if=/dev/zero of=/tmp/blob bs=1M count=256 2>/dev/null
echo 'KIRI-LIBKRUN-MEMLAB ALLOCATED, holding 20 seconds'
sleep 20
rm -f /tmp/blob
echo 'KIRI-LIBKRUN-MEMLAB FREED, holding VM alive for host RSS measurements'
while :; do sleep 30; done
LAB_INIT
sudo chmod 0755 "$work/root/init"
mkdir -p "$(dirname "$dst")"
(
  cd "$work/root"
  sudo find . -print0 | LC_ALL=C sort -z |
    sudo cpio --null --quiet -o -H newc
) > "$dst"
echo "Isolated lab initramfs: $dst"
echo "Requires separate MMIO-enabled ARM64 kernel. NEVER use with the production Kiri VM."

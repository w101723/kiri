#!/usr/bin/env bash
# Build ARM64 stock Moby rootfs ON DISK, not in the Linux kernel initramfs.
# Requires Linux ARM64, Docker, sudo, e2fsprogs, cpio and Cargo.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
out="$root/target/moby-guest"
[ "$#" -eq 0 ] || out="$1"
size="$(printenv KIRI_MOBY_DISK_GB || echo 48)"
case "$size" in ''|*[!0-9]*) echo "KIRI_MOBY_DISK_GB must be an integer" >&2; exit 2 ;; esac
[ "$size" -ge 8 ] && [ "$size" -le 256 ] || { echo "disk size must be 8-256 GiB" >&2; exit 2; }
[ "$(uname -s)" = Linux ] && [ "$(uname -m)" = aarch64 ] || { echo "Requires Linux ARM64 native host" >&2; exit 2; }
for p in docker cpio mkfs.ext4 debugfs tar gzip cargo sudo; do
  command -v "$p" >/dev/null || { echo "missing $p" >&2; exit 2; }
done

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
mkdir -p "$work/context" "$work/root" "$work/boot"

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
# The persistent ext4 root is populated at build time. There is no need to
# inflate the full dockerd/Debian userspace into the Guest's memory on boot.
sudo mkdir -p "$work/root/var/lib/docker" "$work/root/var/lib/containerd"
sudo mkdir -p "$work/root/dev" "$work/root/proc" "$work/root/sys/fs/cgroup" "$work/root/run"
sudo mkdir -p "$work/root/tmp" "$work/root/dev/pts" "$work/root/dev/shm"
if [ ! -e "$work/root/var/run" ] && [ ! -L "$work/root/var/run" ]; then
  sudo ln -s /run "$work/root/var/run"
fi

# Fingerprint actual shipped userspace, not a CI timestamp. The final stamp
# is outside copied directories; PID1 writes it only AFTER a successful sync.
revision="$(cd "$work/root" &&
  sudo find . -type f -print0 | LC_ALL=C sort -z | sudo xargs -0 sha256sum |
    sha256sum | cut -d' ' -f1)"
printf '%s\n' "$revision" | sudo tee "$work/root/.kiri-moby-rootfs-revision" >/dev/null
printf '%s\n' "$revision" > "$out/rootfs.revision"
echo "Rootfs revision: $revision"

# Initramfs contains only BusyBox, musl and a first-stage init. In particular,
# there is NO dockerd/containerd/rootfs tarball in RAM at VM creation.
sudo mkdir -p "$work/boot/bin" "$work/boot/lib" "$work/boot/dev" \
  "$work/boot/proc" "$work/boot/sys" "$work/boot/newroot" "$work/boot/seed"
sudo cp -a "$work/root/bin/busybox" "$work/boot/bin/busybox"
sudo ln -s busybox "$work/boot/bin/sh"
# Alpine BusyBox depends on musl; preserve both the interpreter symlink and
# its real target (usually libc.musl-aarch64.so.1).
for name in ld-musl-aarch64.so.1 libc.musl-aarch64.so.1; do
  if [ -e "$work/root/lib/$name" ] || [ -L "$work/root/lib/$name" ]; then
    sudo cp -a "$work/root/lib/$name" "$work/boot/lib/$name"
  fi
done
sudo chroot "$work/boot" /bin/busybox true
sudo cp "$root/scripts/moby/guest/stage1-init" "$work/boot/init"
sudo chmod 0755 "$work/boot/init"
sudo mknod -m 600 "$work/boot/dev/console" c 5 1
sudo mknod -m 666 "$work/boot/dev/null" c 1 3
# Enumerating two virtio disks by letter is unsafe: the tiny root must be
# able to match partitionless ext4 labels before mounting writable storage.
(cd "$work/boot" && sudo find . -print0 | LC_ALL=C sort -z |
  sudo cpio --null --quiet -o -H newc) > "$out/initramfs.cpio"

# Keep a sealed, read-only rootfs seed available as a SECOND virtio block
# device (/dev/vdb) for upgrading an already-installed writable data disk.
# Only copy the OS on a version change; old Docker layers never move.
used_mib="$(sudo du -sm "$work/root" | awk '{print $1}')"
system_mib="$(( (used_mib * 2 + 128 + 63) / 64 * 64 ))"
[ "$system_mib" -ge 512 ] || system_mib=512
[ "$system_mib" -le 2048 ] || { echo "Guest rootfs unexpectedly exceeds 2 GiB" >&2; exit 1; }
seed="$out/system.img"
disk="$out/data.img"
rm -f "$seed" "$disk"
truncate -s "$system_mib"M "$seed"
sudo mkfs.ext4 -q -F -m 0 -L kiri-system -E lazy_itable_init=1,lazy_journal_init=1 \
  -d "$work/root" "$seed"
truncate -s "$size"G "$disk"
sudo mkfs.ext4 -q -F -m 0 -L kiri-moby -E lazy_itable_init=1,lazy_journal_init=1 \
  -d "$work/root" "$disk"

# Check both filesystem stamps while the filesystem images are offline.
for img in "$seed" "$disk"; do
  stamp="$(debugfs -R 'cat .kiri-moby-rootfs-revision' "$img" 2>/dev/null)"
  [ "$stamp" = "$revision" ] || { echo "Rootfs stamp mismatch in $img" >&2; exit 1; }
done
# Bounded sanity check: initial ramdisk must stay tiny and exclude Docker.
initrd_mib="$(du -m "$out/initramfs.cpio" | awk '{print $1}')"
[ "$initrd_mib" -lt 16 ] || { echo "Boot initramfs unexpectedly large: $initrd_mib MiB" >&2; exit 1; }
! ( cpio -it --quiet < "$out/initramfs.cpio" | grep -Eq '(^|/)(dockerd|containerd|runc)$' ) ||
  { echo "Full Docker runtime leaked into boot initramfs" >&2; exit 1; }

(cd "$out" && tar --sparse -cf - data.img | gzip -1 > data.img.tgz)
(cd "$out" && tar --sparse -cf - system.img | gzip -1 > system.img.tgz)
rm -f "$disk" "$seed"
(cd "$out" && sha256sum initramfs.cpio data.img.tgz system.img.tgz rootfs.revision > SHA256SUMS)
echo "Tiny initramfs: $out/initramfs.cpio ($initrd_mib MiB)"
echo "Read-only system upgrade image: $out/system.img.tgz ($system_mib MiB virtual)"
echo "Prepopulated ext4 Docker data template: $out/data.img.tgz ($size GiB virtual)"

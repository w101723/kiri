#!/bin/sh
# Builds the Linux ARM64 Guest kernel for Apple Silicon hosts.
# Runs inside a Debian/Ubuntu container and writes /out/Image.
set -eu
KVER="${KVER:-7.3.5}"
case "$(uname -m)" in
  aarch64) cross="" pkgs="" ;;
  *) cross=aarch64-linux-gnu- pkgs=gcc-aarch64-linux-gnu ;;
esac
apt-get update -qq && apt-get install -y -qq build-essential flex bison bc libssl-dev libelf-dev dwarves curl xz-utils python3 $pkgs >/dev/null
cd /build
[ -f "linux-$KVER/Makefile" ] && [ -f "linux-$KVER/scripts/Kbuild.include" ] || { rm -rf "linux-$KVER"; curl -fsSL "https://cdn.kernel.org/pub/linux/kernel/v${KVER%%.*}.x/linux-$KVER.tar.xz" | tar xJ; }
cd "linux-$KVER"
# Kiri's kernel patches. Reverse-apply first so re-runs on a cached tree stay clean.
for p in /src/patches/*.patch; do
  patch -p1 -R -s -f --dry-run < "$p" >/dev/null 2>&1 && patch -p1 -R -s < "$p"
  patch -p1 -s < "$p"
done
config=/src/kiri.config
make -s ARCH=arm64 CROSS_COMPILE="$cross" allnoconfig KCONFIG_ALLCONFIG="$config"
missing=0
for line in $(grep -E '^CONFIG_[A-Z0-9_]+=y' "$config"); do
  grep -qx "$line" .config || { echo "MISSING: $line"; missing=1; }
done
[ "$missing" = 0 ] || { echo "some options were not applied (dependency not met)" >&2; exit 1; }
make -s -j"$(nproc)" ARCH=arm64 CROSS_COMPILE="$cross" Image
cp arch/arm64/boot/Image .config /out/
ls -la /out/Image

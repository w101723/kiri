#!/usr/bin/env bash
# Build the macOS 27 HVF probe or the local in-process Helper.
set -euo pipefail
umask 077
root="$(cd "$(dirname "$0")/../.." && pwd)"
mode=probe
if [[ ${1:-} == --helper ]]; then mode=helper; shift; fi
[[ $# -le 1 ]] || { printf 'Usage: %s [--helper] [work-directory]\n' "$0" >&2; exit 2; }
[[ $(uname -sm) == 'Darwin arm64' && $(sw_vers -productVersion) == 27.* ]] || {
  printf 'Requires Apple Silicon running macOS 27\n' >&2; exit 2;
}
for tool in cargo uv pkg-config xcrun codesign install_name_tool otool lipo patch; do
  command -v "$tool" >/dev/null || { printf 'Missing build tool: %s\n' "$tool" >&2; exit 2; }
done
pkg-config --exists glib-2.0 || { printf 'Missing glib-2.0 (pkg-config)\n' >&2; exit 2; }
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)" MACOSX_DEPLOYMENT_TARGET=27.0
work="${1:-$root/target/hvf-probe-work}"
mkdir -p "$work"
work="$(cd "$work" && pwd -P)"
sources="$root/crates/kiri/native/hvf"

extract() {
  local name="$1" url="$2" sha="$3" archive="$work/$1.tar.gz" stage
  if [[ ! -f "$archive" ]]; then
    curl --fail --silent --show-error --location --retry 3 "$url" -o "$archive.part"
    mv "$archive.part" "$archive"
  fi
  local actual
  actual="$(shasum -a 256 "$archive")"
  [[ ${actual%% *} == "$sha" ]] || { printf 'Checksum mismatch: %s\n' "$archive" >&2; return 1; }
  if [[ ! -d "$work/$name" ]]; then
    stage="$(mktemp -d "$work/$name.XXXXXXXX")"
    tar -xzf "$archive" -C "$stage" --strip-components=1
    mv "$stage" "$work/$name"
  fi
}

extract libkrun https://codeload.github.com/containers/libkrun/tar.gz/c4d283c233bc0ae1993c289ec2a1b4da2242f1f8 \
  59ca276f5dd7cf24116bce9b069e3f3468cea6af8525eaa41dd8b7e9518d9b53
extract libslirp https://gitlab.freedesktop.org/slirp/libslirp/-/archive/v4.9.7/libslirp-v4.9.7.tar.gz \
  d2567fa06a6357c7755d61c67293b2c0bf069b3f2173bde6b76cf768529a1938

# Apply local patches to a separate tree keyed by their contents; never mutate
# the extracted upstream source or let old builds silently pick up new patches.
patches=("$sources/patches/"*.patch)
patch_id="$(shasum -a 256 "${patches[@]}" | cut -d ' ' -f 1 | shasum -a 256 | cut -c1-16)"
krun="$work/libkrun-1.19.8-$patch_id"
if [[ ! -d "$krun" ]]; then
  stage="$(mktemp -d "$work/krun-patched.XXXXXXXX")"
  tar -xzf "$work/libkrun.tar.gz" -C "$stage" --strip-components=1
  for file in "${patches[@]}"; do patch -d "$stage" -p1 -s -i "$file"; done
  mv "$stage" "$krun"
fi
# Use Kiri's external kernel/initramfs; no bundled init blob, firmware or GPU.
cargo build --manifest-path "$krun/Cargo.toml" --target-dir "$work/build" \
  --package libkrun --release --locked --no-default-features --features blk,net
venv="$work/probe-meson/venv"
if [[ ! -x "$venv/bin/meson" || ! -x "$venv/bin/ninja" ]]; then
  uv venv "$venv"
  uv pip install --python "$venv/bin/python" meson==1.11.1 ninja==1.13.0
fi
export PATH="$venv/bin:$PATH"
slirp="$work/slirp-build-sdk"
if [[ ! -f "$slirp/build.ninja" ]]; then
  meson setup "$slirp" "$work/libslirp" --default-library=static --buildtype=release
fi
meson compile -C "$slirp" slirp

# This probe alone links the build machine's GLib; no Homebrew library is
# included in, or expected by, the shipping Kiri app.
bin="$(mktemp -d "$work/probe.XXXXXXXX")"
lib="$bin/libkrun.1.dylib"
cp "$work/build/release/libkrun.dylib" "$lib"
install_name_tool -id @rpath/libkrun.1.dylib "$lib"
codesign --force --sign - "$lib"
read -r -a glib_cflags <<< "$(pkg-config --cflags glib-2.0)"
read -r -a glib_libs <<< "$(pkg-config --libs glib-2.0)"
arch=arm64-apple-macos27.0
xcrun clang -target "$arch" -O2 -Wall -Wextra -Werror -I "$work/libkrun/include" \
  -c "$sources/krun_probe.c" -o "$bin/krun_probe.o"
xcrun clang -target "$arch" -O2 -Wall -Wextra -Werror -I "$work/libslirp/src" -I "$slirp" \
  "${glib_cflags[@]}" -c "$sources/slirp_network.c" -o "$bin/slirp_network.o"
probe="$bin/kiri-hvf-probe"
swift_sources=("$sources/Probe.swift")
if [[ $mode == helper ]]; then
  probe="$bin/kiri-moby-host"
  swift_sources=(-DKIRI_HVF_LOCAL "$sources/Helper.swift" "$sources/../KiriMobyHost.swift" "$sources/../MobyRuntime.swift")
fi
xcrun swiftc -parse-as-library -O -target "$arch" -sdk "$SDKROOT" \
  -import-objc-header "$sources/krun_probe.h" "${swift_sources[@]}" \
  "$bin/krun_probe.o" "$bin/slirp_network.o" "$slirp/libslirp.a" "$lib" "${glib_libs[@]}" \
  -framework Hypervisor -lresolv -Xlinker -rpath -Xlinker @loader_path \
  -Xlinker -rpath -Xlinker @loader_path/../Frameworks -o "$probe"
# The local ad-hoc probe uses the build machine's GLib, not a notarized library set.
codesign --force --sign - --entitlements "$sources/hypervisor.entitlements" "$probe"
codesign --verify --strict "$lib" "$probe"
[[ $(lipo -archs "$probe") == arm64 && $(lipo -archs "$lib") == arm64 ]]
links="$(otool -L "$probe" "$lib")"
if [[ $links == *'/Virtualization.framework/'* || $links != *'/Hypervisor.framework/'* ||
      $links != *'@rpath/libkrun.1.dylib'* ]]; then
  printf 'Unexpected VMM linkage:\n%s\n' "$links" >&2
  exit 1
fi
printf 'Probe: %s\n' "$probe"

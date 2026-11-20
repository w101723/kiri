#!/usr/bin/env bash
# Observe macOS Physical footprint during an isolated libkrun Guest alloc/free.
# Run separately with KIRI_LIBKRUN_REPORTING_MODE=default and =replace.
# Usage: script /abs/runner /abs/trusted/libkrun.dylib /abs/Image /abs/initramfs.cpio
set -euo pipefail
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || {
  echo "Requires Apple Silicon macOS" >&2; exit 2;
}
[[ $# == 4 ]] || {
  echo "Usage: $0 /absolute/runner /absolute/libkrun.dylib /absolute/Image /absolute/initramfs.cpio" >&2; exit 2;
}
for arg in "$@"; do
  [[ "$arg" == /* && -f "$arg" ]] || { echo "Expected an existing absolute file path: $arg" >&2; exit 2; }
done
mode="$(printenv KIRI_LIBKRUN_REPORTING_MODE || true)"
[[ -n "$mode" ]] || mode="replace"
[[ "$mode" == default || "$mode" == replace ]] || {
  echo "KIRI_LIBKRUN_REPORTING_MODE must be default or replace" >&2; exit 2;
}
out="$(printenv KIRI_LIBKRUN_LAB_RESULTS || true)"
[[ -n "$out" ]] || out="$PWD/kiri-libkrun-$mode-$(date '+%Y%m%d-%H%M%S')"
mkdir -p "$out"
log="$out/guest.log"
csv="$out/footprint.csv"
printf 'timestamp,stage,physical_footprint\n' > "$csv"
echo "Running isolated lab in $mode mode. Recording: $out"
KIRI_LIBKRUN_REPORTING_MODE="$mode" "$1" "$2" "$3" "$4" > "$log" 2>&1 &
pid="$!"
cleanup() {
  kill "$pid" >/dev/null 2>&1 || true
  wait "$pid" >/dev/null 2>&1 || true
}
trap cleanup EXIT
for ((i=1; i<=28; i++)); do
  sleep 4
  if ! kill -0 "$pid" >/dev/null 2>&1; then
    echo "Lab VM exited unexpectedly; check $log" >&2
    cat "$log" >&2
    exit 1
  fi
  stage="$(grep 'KIRI-LIBKRUN-MEMLAB' "$log" | tail -n 1 | sed 's/^.*KIRI-LIBKRUN-MEMLAB /LAB-/' || true)"
  [[ -n "$stage" ]] || stage="BOOTING"
  physical="$(vmmap -summary "$pid" 2>/dev/null | awk '/^Physical footprint:/ {print $3; exit}' || true)"
  [[ -n "$physical" ]] || physical="unavailable"
  printf '%s,"%s",%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$stage" "$physical" | tee -a "$csv"
done
# A host footprint change with no Guest progress is not an accepted test.
for phase in READY ALLOCATING ALLOCATED FREED; do
  if ! grep -Fq "KIRI-LIBKRUN-MEMLAB $phase" "$log"; then
    echo "INVALID LAB RUN: missing Guest $phase marker in $log" >&2
    echo "Guest console output was not observed. Do not claim a successful A/B measurement." >&2
    tail -n 40 "$log" >&2
    exit 1
  fi
done
if grep -Fq ',unavailable' "$csv"; then
  echo "INVALID LAB RUN: vmmap Physical footprint unavailable in $csv" >&2
  exit 1
fi
echo "PASS: Guest READY / ALLOCATING / ALLOCATED / FREED phases all observed."
echo "Completed samples. Guest log: $log ; host measurement: $csv"
echo "Compare post-ALLOCATED and post-FREED physical_footprint, across default and replace modes."

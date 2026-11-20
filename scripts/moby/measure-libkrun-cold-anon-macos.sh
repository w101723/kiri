#!/usr/bin/env bash
# Host-side A/B for ZRAM-evicted but still-mapped cold anonymous pages.
# Requires a RAM-only Guest with CONFIG_ZRAM and /bin/kiri-lab-anon.
# Both modes keep the Guest and test process running throughout.
# Usage: script /abs/runner /abs/trusted/libkrun2.dylib /abs/Image /abs/initramfs.cpio
set -euo pipefail
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || {
  echo "Requires Apple Silicon macOS" >&2; exit 2;
}
[[ $# == 4 ]] || {
  echo "Usage: $0 /abs/runner /abs/libkrun.dylib /abs/Image /abs/initramfs.cpio" >&2; exit 2;
}
for arg in "$@"; do
  [[ "$arg" == /* && -f "$arg" ]] || { echo "Expected existing absolute file: $arg" >&2; exit 2; }
done
mode="$(printenv KIRI_LIBKRUN_REPORTING_MODE || true)"
[[ -n "$mode" ]] || mode="replace"
[[ "$mode" == default || "$mode" == replace ]] || {
  echo "KIRI_LIBKRUN_REPORTING_MODE must be default or replace" >&2; exit 2;
}
out="$(printenv KIRI_LIBKRUN_LAB_RESULTS || true)"
[[ -n "$out" ]] || out="$PWD/kiri-cold-anon-$mode-$(date '+%Y%m%d-%H%M%S')"
mkdir -p "$out"
log="$out/guest.log"
csv="$out/host-memory.csv"
printf 'timestamp,phase,physical_footprint,rss_kib,mac_compressor_pages_global\n' > "$csv"
echo "Cold-anon zram lab: $mode; results in $out"
KIRI_LIBKRUN_REPORTING_MODE="$mode" KIRI_LIBKRUN_WORKLOAD=anon-zram \
  "$1" "$2" "$3" "$4" > "$log" 2>&1 &
pid="$!"
cleanup() {
  kill "$pid" >/dev/null 2>&1 || true
  wait "$pid" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# ~3 minutes. All samples are of the SAME live libkrun PID.
# Compressor pages are global macOS counters, not per-process numbers.
for ((i=1; i<=45; i++)); do
  sleep 4
  if ! kill -0 "$pid" >/dev/null 2>&1; then
    echo "INVALID RUN: VMM exited early; read $log" >&2
    tail -n 80 "$log" >&2
    exit 1
  fi
  phase="$(grep -E 'KIRI-LIBKRUN-MEMLAB ANON_(READY|ALLOCATED|PAGEOUT|SWAP_CONFIRMED|IDLE|RESTORED|FREED)' "$log" |
    tail -n 1 |
    sed -E 's/^.*KIRI-LIBKRUN-MEMLAB (ANON_(READY|ALLOCATED|PAGEOUT|SWAP_CONFIRMED|IDLE|RESTORED|FREED)).*$/\1/' |
    tr -d '\r' || true)"
  case "$phase" in
    ANON_READY|ANON_ALLOCATED|ANON_PAGEOUT|ANON_SWAP_CONFIRMED|ANON_IDLE|ANON_RESTORED|ANON_FREED) ;;
    *) phase="BOOTING" ;;
  esac
  footprint="$(vmmap -summary "$pid" 2>/dev/null | awk '/^Physical footprint:/ {print $3; exit}' || true)"
  [[ -n "$footprint" ]] || footprint="unavailable"
  rss="$(ps -p "$pid" -o rss= 2>/dev/null | tr -d '[:space:]' || true)"
  [[ -n "$rss" ]] || rss="unavailable"
  # macOS compressor is system-wide. This is supportive context, not proof
  # that this VM's particular pages were compressed by the Mac.
  compressed="$(vm_stat 2>/dev/null | awk -F: '/Pages occupied by compressor/ {gsub(/[^0-9]/, "", $2); print $2; exit}' || true)"
  [[ -n "$compressed" ]] || compressed="unavailable"
  printf '%s,%s,%s,%s,%s\n' \
    "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$phase" "$footprint" "$rss" "$compressed" |
    tee -a "$csv"
done

for phase in ANON_READY ANON_ALLOCATED ANON_PAGEOUT ANON_SWAP_CONFIRMED ANON_IDLE ANON_RESTORED ANON_FREED; do
  if ! grep -Eq "KIRI-LIBKRUN-MEMLAB $phase([[:space:]]|$)" "$log"; then
    echo "INVALID RUN: Guest $phase absent; no compression/recovery claim" >&2
    tail -n 80 "$log" >&2
    exit 1
  fi
done
if grep -Fq ',unavailable' "$csv"; then
  echo "INVALID RUN: host vmmap, RSS or global compressor metrics unavailable" >&2
  exit 1
fi
echo "PASS: confirmed swap-out while anonymous mapping remained alive; data restored correctly."
echo "Host samples: $csv ; Guest evidence: $log"
echo "Compare ANON_ALLOCATED -> ANON_IDLE -> ANON_RESTORED -> ANON_FREED in default and replace."

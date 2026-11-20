#!/usr/bin/env bash
# Observe Guest balloon target AND host process RSS. Does not change Docker
# context and does not restart the VM. Optional --stress uses a temporary
# Alpine container with a 256MiB tmpfs allocation.
set -euo pipefail

case "${1:-}" in ""|--stress) ;; *) echo "Usage: $0 [--stress]" >&2; exit 2 ;; esac
data="${KIRI_MOBY_DATA_DIR:-$HOME/.kiri-moby}"
control="$data/run/host-control.sock"
docker_socket="$data/run/docker.sock"
[[ -S "$control" && -S "$docker_socket" ]] || { echo "Moby VM sockets not running" >&2; exit 1; }

stats() {
  printf 'STAT\n' | nc -U "$control"
}
rss() {
  # VZ may charge memory to com.apple.Virtualization.VirtualMachine XPC, not
  # kiri-moby-host. This is indicative, not an authoritative VM footprint.
  echo "Host processes (RSS KiB):"
  ps -axo pid=,rss=,comm= | grep -E 'kiri-moby-host|com.apple.Virtualization.VirtualMachine' | grep -v grep || true
}
snapshot() {
  printf '%s\n' "--- $(date '+%Y-%m-%dT%H:%M:%S%z') ---"
  echo "Guest / balloon:"
  stats || true
  rss
}
snapshot
[[ "${1:-}" == --stress ]] || exit 0
command -v docker >/dev/null || { echo "docker CLI required for --stress" >&2; exit 2; }
image="${KIRI_MOBY_MEMORY_TEST_IMAGE:-alpine:3.22}"
docker --host "unix://$docker_socket" image inspect "$image" >/dev/null || {
  echo "Pull $image into Kiri Moby first; test does not download images" >&2; exit 2;
}
name="kiri-memory-test-$$"
cleanup() { docker --host "unix://$docker_socket" rm -f "$name" >/dev/null 2>&1 || true; }
trap cleanup EXIT
echo "Allocating 256MiB tmpfs for 20s in temporary container"
docker --host "unix://$docker_socket" run --rm --name "$name" -d --tmpfs /work:rw,size=384m "$image" sh -c   'dd if=/dev/zero of=/work/blob bs=1M count=256 2>/dev/null && sleep 20' >/dev/null
sleep 4
snapshot
docker --host "unix://$docker_socket" rm -f "$name" >/dev/null 2>&1 || true
echo "Container stopped; recording reclamation at 5, 15 and 30 seconds"
for interval in 5 10 15; do sleep "$interval"; snapshot; done
echo "Compare RSS/pressure before and after. Balloon target alone does not prove reclaim."

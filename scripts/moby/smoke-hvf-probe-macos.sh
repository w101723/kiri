#!/usr/bin/env bash
# Exercise the in-process VMM using fresh copies of the shipped Guest disks.
set -euo pipefail
umask 077
[[ $# -eq 3 || ( $# -eq 4 && ( $4 == --apple-translation || $4 == --no-translation-control ) ) ]] || {
  printf 'Usage: %s /path/to/kiri-hvf-probe /path/to/guest-assets /path/to/rebuilt/Image [--apple-translation|--no-translation-control]\n' "$0" >&2
  exit 2
}
probe="$1"
assets="$(cd "$2" && pwd -P)"
kernel="$3"
translation="${4:-}"
probe_args=()
if [[ $translation == --apple-translation ]]; then probe_args+=("$translation"); fi
[[ $(uname -sm) == 'Darwin arm64' && -x "$probe" && -s "$kernel" ]] || exit 2
if [[ -n $translation ]]; then
  [[ $(sw_vers -productVersion) == 27.* ]] || exit 2
  links="$(otool -L "$probe" "$(dirname "$probe")/libkrun.1.dylib")"
  [[ $links == *'/Hypervisor.framework/'* && $links != *'/Virtualization.framework/'* ]] || {
    printf 'Unexpected VMM linkage:\n%s\n' "$links" >&2; exit 1;
  }
fi
(cd "$assets" && shasum -a 256 -c SHA256SUMS)
"$probe" --check-hvf

# Keep Unix socket paths well below Darwin's sockaddr_un limit.
vm="$(mktemp -d /tmp/kiri-hvf-vm.XXXXXXXX)"
printf 'Isolated VM and logs: %s\n' "$vm"
: > "$vm/.kiri-hvf-probe"
cp "$kernel" "$vm/Image"
cp "$assets/initramfs.cpio" "$vm/"
tar -xzf "$assets/data.img.tgz" -C "$vm" data.img
tar -xzf "$assets/system.img.tgz" -C "$vm" system.img
seed_before="$(shasum -a 256 "$vm/system.img")"

workers() {
  ps -axo pid=,comm= | awk '/com\.apple\.Virtualization\.VirtualMachine/{print $1}' | sort
}
workers > "$vm/workers-before"
"$probe" --run "$vm" ${probe_args[@]+"${probe_args[@]}"} > "$vm/helper.log" 2>&1 &
pid=$!
(
  while kill -0 "$pid" 2>/dev/null; do
    workers
    sleep 0.2
  done
) > "$vm/workers-observed" &
monitor=$!
cleanup() {
  if [[ -n "$pid" ]]; then
    # Only signal the child created by this script. Keep logs and test disks.
    kill -TERM "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

docker_probe() {
  curl --noproxy '*' --silent --show-error --fail --max-time 2 \
    --unix-socket "$vm/docker.sock" "http://localhost/$1"
}
ready=0
for ((i = 0; i < 160; i++)); do
  kill -0 "$pid" 2>/dev/null || break
  if [[ $(docker_probe _ping 2>/dev/null) == OK ]]; then
    ready=1
    break
  fi
  sleep 0.25
done
if [[ $ready != 1 ]]; then
  printf 'Docker did not become ready; see %s/{helper,console}.log\n' "$vm" >&2
  exit 1
fi
docker_probe version
printf '\n'
image="${KIRI_HVF_PROBE_TEST_IMAGE:-}"
if [[ -n $translation && -z $image ]]; then image=alpine:3.22; fi
runtime_status=0
if [[ -n $image ]]; then
  # The private CLI config never reads or changes the user's Docker context.
  # An optional archive of the native image can avoid a registry pull.
  python3 -I - "$vm" "$image" "${KIRI_HVF_PROBE_IMAGE_ARCHIVE:-}" "$translation" <<'PY' || runtime_status=$?
import os
from pathlib import Path
import subprocess
import sys

root, image, archive, translation = sys.argv[1:]
root = Path(root)
env = dict(os.environ)
env.pop("DOCKER_CONTEXT", None)
env["DOCKER_CONFIG"] = str(root / "docker-config")
docker = [env.get("KIRI_HVF_PROBE_DOCKER_CLI", "docker"), "--host", f"unix://{root / 'docker.sock'}"]


def query(*args):
    return subprocess.check_output(docker + list(args), env=env, timeout=90).strip()


def run(platform, image, *args):
    return subprocess.run(docker + ["run", "--rm", "--pull=never", "--platform", platform, image, *args],
                          env=env, capture_output=True, timeout=90)


if archive:
    query("load", "--input", archive)
else:
    query("pull", "--platform", "linux/arm64", image)
native = run("linux/arm64", image, "uname", "-m")
if native.returncode != 0 or native.stdout.strip() != b"aarch64":
    raise SystemExit(f"Unexpected ARM64 result: {native.returncode=} {native.stdout=!r} {native.stderr=!r}")
print("PASS: native ARM64 container: aarch64", flush=True)

if translation:
    console = (root / "console.log").read_bytes()
    registered = b"[kiri-rosetta] binfmt_misc registered interpreter /run/rosetta/rosetta" in console
    expected = translation == "--apple-translation"
    passed = registered == expected
    print(f"Apple binfmt registration verified: {registered}", flush=True)
    for amd_image in ("alpine:3.22", "debian:bookworm-slim"):
        query("pull", "--platform", "linux/amd64", amd_image)
        architecture = query("image", "inspect", "--format", "{{.Os}}/{{.Architecture}}", amd_image)
        if architecture != b"linux/amd64":
            raise SystemExit(f"Unexpected image platform for {amd_image}: {architecture!r}")
        result = run("linux/amd64", amd_image, "/bin/sh", "-c", "uname -m; printf 'kiri-amd64\\n'; exit 42")
        print(f"{amd_image} [{architecture.decode()}]: exit={result.returncode}, "
              f"stdout={result.stdout.strip()!r}, stderr={result.stderr.strip()!r}", flush=True)
        if expected:
            passed &= result.returncode == 42 and result.stdout.strip() == b"x86_64\nkiri-amd64"
        else:
            passed &= result.returncode != 0 and b"exec format error" in result.stdout + result.stderr
    if not passed:
        raise SystemExit("Apple translation probe did not meet its execution or control assertions")
PY
fi
python3 -I - "$vm/memory.sock" <<'PY'
import socket
import sys

with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
    client.settimeout(4)
    client.connect(sys.argv[1])
    with client.makefile("rb") as stream:
        report = stream.readline(128).decode("ascii").strip()
parts = report.split()
if len(parts) != 4 or parts[0] != "KIRI_MEM_V1" or not all(x.isdigit() for x in parts[1:]):
    raise SystemExit(f"Invalid guest memory report: {report!r}")
print(report)
PY
if [[ -n $(ps -axo ppid=,pid= | awk -v pid="$pid" '$1 == pid {print $2}') ]]; then
  printf 'Probe has unexpected child processes\n' >&2
  exit 1
fi

python3 -I - "$vm/shutdown.sock" <<'PY'
import socket
import sys

with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
    client.settimeout(4)
    client.connect(sys.argv[1])
    client.sendall(b"SHUTDOWN\n")
PY
for ((i = 0; i < 120; i++)); do
  if ! kill -0 "$pid" 2>/dev/null; then
    result=0
    wait "$pid" || result=$?
    pid=''
    [[ $result == 0 ]] || { printf 'Guest shutdown exited with %s\n' "$result" >&2; exit 1; }
    grep -Fq 'Stopping dockerd/containerd and flushing ext4 data' "$vm/console.log"
    [[ "$(shasum -a 256 "$vm/system.img")" == "$seed_before" ]]
    wait "$monitor"
    sort -u "$vm/workers-observed" > "$vm/workers-running"
    if [[ -n $(comm -13 "$vm/workers-before" "$vm/workers-running") ]]; then
      printf 'New Apple Virtualization worker observed; isolate other VZ apps and retry\n' >&2
      exit 1
    fi
    printf 'PASS: Docker ready, vsock telemetry, no new VZ worker observed, Guest poweroff, unchanged seed\n'
    exit "$runtime_status"
  fi
  sleep 0.25
done
printf 'Guest shutdown did not exit within 30s; see %s/{helper,console}.log\n' "$vm" >&2
exit 1

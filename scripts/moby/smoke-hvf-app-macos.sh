#!/usr/bin/env bash
# Local end-to-end Helper acceptance. Does not use or update any Docker context.
set -euo pipefail
umask 077
[[ $# -eq 1 && $(sw_vers -productVersion) == 27.* ]] || {
  printf 'Usage on macOS 27: %s /path/to/Kiri\ Moby\ HVF.app\n' "$0" >&2; exit 2;
}
app="$1"
helper="$app/Contents/Library/Helpers/Kiri Moby Helper.app/Contents/MacOS/Kiri Moby Helper"
[[ -x "$helper" ]]
codesign --verify --deep --strict "$app"
export KIRI_MOBY_DATA_DIR="$(mktemp -d /tmp/kiri-hvf-qa.XXXXXXXX)"
printf 'Isolated data and logs: %s\n' "$KIRI_MOBY_DATA_DIR"
cli="$app/Contents/Resources/bin/docker"
workers() { ps -axo pid=,comm= | awk '/com\.apple\.Virtualization\.VirtualMachine/ {print $1}' | sort; }
workers > "$KIRI_MOBY_DATA_DIR/workers-before"
python3 -I - "$helper" "$cli" <<'PY'
import json
import errno
import os
from pathlib import Path
import pty
import select
import socket
import subprocess
import sys
import time

helper, cli = sys.argv[1:]
data = Path(os.environ["KIRI_MOBY_DATA_DIR"])
env = dict(os.environ)
env.pop("DOCKER_CONTEXT", None)
config = data / "docker-config"
env["DOCKER_CONFIG"] = str(config)
env.pop("BUILDX_CONFIG", None)
cli_command = [cli, "--host", f"unix://{data / 'run/docker.sock'}"]
image = "alpine:3.22"


def docker(*args, input=None):
    return subprocess.check_output(cli_command + list(args), env=env, input=input, timeout=90).strip()


def check_pty():
    master, slave = pty.openpty()
    proc = subprocess.Popen(cli_command + ["run", "--rm", "-it", image, "sh", "-c",
                            'printf "pty-ready\\n"; read -r line; printf "pty-output:%s\\n" "$line"'],
                            env=env, stdin=slave, stdout=slave, stderr=slave)
    os.close(slave)
    output = bytearray()
    sent = False
    deadline = time.monotonic() + 15
    try:
        while time.monotonic() < deadline:
            if not select.select([master], [], [], 0.25)[0]:
                continue
            try:
                chunk = os.read(master, 4096)
            except OSError as e:
                if e.errno == errno.EIO:
                    break
                raise
            if not chunk:
                break
            output.extend(chunk)
            if not sent and b"pty-ready" in output:
                os.write(master, b"interactive-input\n")
                sent = True
            if b"pty-output:interactive-input" in output:
                break
        if b"pty-output:interactive-input" not in output or proc.wait(timeout=5) != 0:
            raise RuntimeError(f"Interactive PTY did not round-trip: {bytes(output)!r}")
    finally:
        os.close(master)
        if proc.poll() is None:
            proc.kill()
            proc.wait(timeout=5)


def control(command):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
        sock.settimeout(2)
        sock.connect(str(data / "run/host-control.sock"))
        sock.sendall(command.encode() + b"\n")
        with sock.makefile("rb") as response:
            return response.readline(2048)


def start(log):
    proc = subprocess.Popen([helper], env=env, stdin=subprocess.DEVNULL, stdout=log, stderr=log)
    try:
        for _ in range(200):
            if proc.poll() is not None:
                raise RuntimeError(f"Helper exited with {proc.returncode}; see {data / 'helper.log'}")
            try:
                stat = json.loads(control("STAT"))
                if stat["phase"] == "ready" and stat["backend"] == "hvf-libkrun":
                    assert stat["pid"] == proc.pid
                    return proc
            except (OSError, ValueError):
                pass
            time.sleep(0.25)
        raise RuntimeError("Helper did not become ready")
    except BaseException:
        terminate(proc)
        raise


def terminate(proc):
    if proc.poll() is None:
        proc.terminate()
        try:
            proc.wait(timeout=35)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=5)


def stop(proc):
    assert control("STOP") == b"OK\n"
    assert proc.wait(timeout=36) == 0
    assert not (data / "run/forced-stop").exists()


(data / "vm-resources.json").write_text('{"cpus":2,"memory_mib":2048}')
share = os.getenv("KIRI_HVF_QA_SHARE")
if share:
    share = str(Path(share).resolve(strict=True))
    if not (Path(share) / "kiri-hvf-share-token").is_file():
        raise RuntimeError("Share fixture must already contain kiri-hvf-share-token")
    (data / "authorized-shares.json").write_text(json.dumps([share]))
with (data / "helper.log").open("ab") as log:
    first = start(log)
    try:
        assert docker("info", "--format", "{{.NCPU}}") == b"2"
        status = json.loads(control("STAT"))
        assert status["vm_memory_ceiling_mib"] == 2048
        assert subprocess.run([helper], env=env, stdout=log, stderr=log, timeout=5).returncode != 0
        subprocess.run(["ps", "-axo", "pid=,ppid=,comm="], stdout=(data / "processes-running").open("wb"), check=True)
        docker("pull", "--platform", "linux/arm64", image)
        if share:
            name = docker("create", "--mount", f"type=bind,source={share},target=/approved,readonly",
                          image, "cat", "/approved/kiri-hvf-share-token").decode()
            docker("start", name)
            assert docker("wait", name) == b"0"
            assert docker("logs", name) == (Path(share) / "kiri-hvf-share-token").read_bytes().strip()
            docker("rm", name)
            print("PASS: authorized directory mounted through per-share virtiofs", flush=True)
        docker("volume", "create", "kiri-hvf-qa")
        docker("run", "--rm", "-v", "kiri-hvf-qa:/data", image, "sh", "-c", "echo persistent > /data/token")
        assert docker("run", "--rm", image, "uname", "-m") == b"aarch64"
        assert docker("run", "--rm", "-i", image, "cat", input=b"duplex-stdin\n") == b"duplex-stdin"
        check_pty()
        print("PASS: attached stdout, stdin EOF and interactive Docker PTY", flush=True)
        compose = data / "compose.yaml"
        compose.write_text('services:\n  probe:\n    image: alpine:3.22\n    command: ["echo", "compose-ok"]\n')
        assert docker("compose", "-f", str(compose), "run", "--rm", "probe") == b"compose-ok"
        docker("compose", "-f", str(compose), "down")
        build = data / "build"
        build.mkdir()
        (build / "Dockerfile").write_text('FROM alpine:3.22\nRUN echo buildx-ok > /probe\nCMD ["cat", "/probe"]\n')
        docker("buildx", "build", "--platform", "linux/arm64", "--load", "-t", "hvf-qa:buildx", str(build))
        assert docker("run", "--rm", "hvf-qa:buildx") == b"buildx-ok"
        print("PASS: Compose and Buildx using the bundled plugins", flush=True)
        name = "kiri-hvf-qa-http"
        web_image = "nginx:alpine"
        docker("pull", "--platform", "linux/arm64", web_image)
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as port_probe:
            port_probe.bind(("127.0.0.1", 0))
            port = port_probe.getsockname()[1]
        docker("run", "-d", "--name", name, "-p", f"{port}:80", web_image)
        for _ in range(40):
            response = subprocess.run(["curl", "--silent", "--noproxy", "*", "--max-time", "1",
                                       f"http://127.0.0.1:{port}"], capture_output=True)
            if response.returncode == 0 and b"Welcome to nginx" in response.stdout:
                break
            time.sleep(0.25)
        else:
            raise RuntimeError("Published port did not respond")
        docker("rm", "-f", name)
        for _ in range(40):
            with socket.socket() as listener:
                listener.settimeout(0.25)
                if listener.connect_ex(("127.0.0.1", port)) != 0:
                    break
            time.sleep(0.25)
        else:
            raise RuntimeError("Published port listener remained open")
        stop(first)
    finally:
        terminate(first)
    second = start(log)
    try:
        name = docker("create", "--mount", "source=kiri-hvf-qa,target=/data", image, "cat", "/data/token").decode()
        docker("start", name)
        assert docker("wait", name) == b"0"
        assert docker("logs", name) == b"persistent"
        docker("rm", name)
        stop(second)
    finally:
        terminate(second)
print("PASS: private control, disk lock, resources, Docker pull, localhost publish/release, restart and volume persistence")
PY
python3 -I - "$KIRI_MOBY_DATA_DIR" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
before = set((root / "workers-before").read_text().split())
running = (root / "processes-running").read_text().splitlines()
new = [row for row in running if "com.apple.Virtualization.VirtualMachine" in row and row.split()[0] not in before]
if new:
    raise SystemExit(f"Observed new Virtualization worker while running: {new}")
print("PASS: no new Apple Virtualization worker during Helper run")
PY

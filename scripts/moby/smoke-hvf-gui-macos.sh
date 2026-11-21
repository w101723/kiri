#!/usr/bin/env bash
# Exercise GUI-triggered Helper startup and reconnect on a logged-in Mac.
set -euo pipefail
umask 077
[[ $# -eq 1 ]] || { printf 'Usage: %s "/path/to/Kiri Moby HVF.app"\n' "$0" >&2; exit 2; }
app="$1"
codesign --verify --deep --strict "$app"
app_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")
[[ $app_id == dev.kiri.app.moby.hvf.local ]]
export KIRI_MOBY_DATA_DIR="$(mktemp -d /tmp/kiri-hvf-gui.XXXXXXXX)"
printf 'Isolated GUI data and logs: %s\n' "$KIRI_MOBY_DATA_DIR"
python3 -I - "$app/Contents/MacOS/kiri-moby-ui" <<'PY'
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import time

ui = sys.argv[1]
data = Path(os.environ["KIRI_MOBY_DATA_DIR"])


def control(command):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
        sock.settimeout(2)
        sock.connect(str(data / "run/host-control.sock"))
        sock.sendall(command.encode() + b"\n")
        with sock.makefile("rb") as response:
            return response.readline(2048)


def ready(proc):
    for _ in range(200):
        if proc.poll() is not None:
            raise RuntimeError(f"GUI exited {proc.returncode}; see {data / 'gui.log'}")
        try:
            stats = json.loads(control("STAT"))
            if stats["backend"] == "hvf-libkrun" and stats["phase"] == "ready":
                return stats["pid"]
        except (OSError, ValueError):
            pass
        time.sleep(0.25)
    raise RuntimeError("GUI did not start its Helper")


def quit_gui(proc):
    if proc and proc.poll() is None:
        proc.send_signal(signal.SIGTERM)
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=5)


with (data / "gui.log").open("ab") as log:
    env = dict(os.environ)
    env.pop("KIRI_MOBY_UI_PREVIEW", None)
    first = second = None
    try:
        first = subprocess.Popen([ui], env=env, stdin=subprocess.DEVNULL, stdout=log, stderr=log)
        pid = ready(first)
        quit_gui(first)
        assert json.loads(control("STAT"))["pid"] == pid
        second = subprocess.Popen([ui], env=env, stdin=subprocess.DEVNULL, stdout=log, stderr=log)
        assert ready(second) == pid
        time.sleep(2)
        assert second.poll() is None
        assert json.loads(control("STAT"))["pid"] == pid
        quit_gui(second)
        assert control("STOP") == b"OK\n"
        for _ in range(144):
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                assert not (data / "run/forced-stop").exists()
                break
            time.sleep(0.25)
        else:
            raise RuntimeError("GUI-launched Helper did not exit")
    finally:
        quit_gui(first)
        quit_gui(second)
        try:
            control("STOP")
        except OSError:
            pass
print("PASS: GUI starts the in-process Helper, exit leaves it running, relaunch reuses its PID")
PY

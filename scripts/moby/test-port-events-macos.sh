#!/usr/bin/env bash
# Real-Mac end-to-end Docker /events TCP port publishing smoke test.
# Uses ONLY the explicit Kiri Docker socket; never touches OrbStack.
set -euo pipefail
if [ "$(uname -s)" != Darwin ] || [ "$(uname -m)" != arm64 ]; then
    echo "Requires macOS Apple Silicon" >&2
    exit 2
fi
data="${KIRI_MOBY_DATA_DIR:-$HOME/.kiri-moby}"
sock="unix://$data/run/docker.sock"
port="${KIRI_MOBY_EVENT_TEST_PORT:-18081}"
case "$port" in ''|*[!0-9]*) echo "Invalid port: $port" >&2; exit 2 ;; esac
if [ "$port" -lt 1024 ] || [ "$port" -gt 65535 ]; then
    echo "Select an unprivileged TCP port between 1024 and 65535" >&2
    exit 2
fi
[ -S "$data/run/docker.sock" ] || { echo "Missing Kiri Docker socket: $data" >&2; exit 2; }
for cmd in docker curl lsof; do
    command -v "$cmd" >/dev/null || { echo "Missing $cmd" >&2; exit 2; }
done
if lsof -nP -iTCP:"$port" -sTCP:LISTEN | grep -q LISTEN; then
    echo "Mac TCP port $port is already in use. Change KIRI_MOBY_EVENT_TEST_PORT." >&2
    exit 2
fi
name="kiri-event-smoke-$port-$$"
created=0
cleanup() {
    if [ "$created" -eq 1 ]; then
        docker --host "$sock" rm -f "$name" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

docker --host "$sock" version --format '{{.Server.Version}}' >/dev/null
echo "Creating Nginx container with -p $port:80..."
docker --host "$sock" run -d --rm --platform linux/arm64 \
    --name "$name" -p "$port:80" nginx:alpine >/dev/null
created=1

ready=0
i=0
while [ "$i" -lt 100 ]; do
    if curl --fail --silent --noproxy '*' --max-time 1 \
       -o /dev/null "http://127.0.0.1:$port/"; then
        ready=1
        break
    fi
    i=$((i + 1))
    sleep 0.1
done
if [ "$ready" -ne 1 ]; then
    echo "FAIL: localhost:$port did not become reachable" >&2
    docker --host "$sock" ps --filter "name=$name" >&2 || true
    exit 1
fi
echo "PASS: Nginx reachable through Mac localhost:$port"
docker --host "$sock" stop "$name" >/dev/null
created=0

released=0
i=0
while [ "$i" -lt 100 ]; do
    if ! lsof -nP -iTCP:"$port" -sTCP:LISTEN | grep -q LISTEN; then
        released=1
        break
    fi
    i=$((i + 1))
    sleep 0.1
done
if [ "$released" -ne 1 ]; then
    echo "FAIL: localhost:$port listener remained after Docker stop" >&2
    exit 1
fi
echo "PASS: Docker stop event released localhost:$port"

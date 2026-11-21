#!/usr/bin/env bash
# Run on a real Apple Silicon Mac after both experimental artifacts are installed.
# Does not delete or modify other Docker contexts, containers or volumes.
set -euo pipefail
context="kiri-moby"
command -v docker >/dev/null || { echo "Docker CLI is required" >&2; exit 2; }
[ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = arm64 ] || { echo "Only macOS Apple Silicon is supported" >&2; exit 2; }
docker context inspect "$context" >/dev/null || { echo "Docker context kiri-moby is missing" >&2; exit 2; }
scratch="$(mktemp -d "$HOME/.kiri-moby-smoke.XXXXXX")"
vol="kiri-moby-smoke-$"
image_arm="kiri-moby-smoke-$:arm64"
image_amd="kiri-moby-smoke-$:amd64"
cleanup() {
  docker --context "$context" volume rm -f "$vol" >/dev/null 2>&1 || true
  docker --context "$context" image rm -f "$image_arm" "$image_amd" >/dev/null 2>&1 || true
  rm -rf "$scratch"
}
trap cleanup EXIT

echo "1/7: API and server info"
docker --context "$context" version
docker --context "$context" info --format 'Root={{.DockerRootDir}} Driver={{.Driver}} Kernel={{.KernelVersion}}'

echo "2/7: Native Linux/ARM64"
docker --context "$context" run --rm --platform linux/arm64 alpine:3.22 sh -c 'test "$(uname -m)" = aarch64 && echo arm64-ok'

echo "3/7: Rosetta Linux/AMD64"
docker --context "$context" run --rm --platform linux/amd64 alpine:3.22 sh -c 'test "$(uname -m)" = x86_64 && echo amd64-ok'

echo "4/7: macOS host bind mounts"
echo "bind-mount-ok" > "$scratch/bind.txt"
docker --context "$context" run --rm -v "$scratch:/src:ro" alpine:3.22 \
  sh -c 'test "$(cat /src/bind.txt)" = bind-mount-ok && echo bind-mount-ok'

echo "5/7: Persistent named Docker volume"
docker --context "$context" volume create "$vol" >/dev/null
docker --context "$context" run --rm -v "$vol:/data" alpine:3.22 \
  sh -c 'echo volume-ok >/data/probe'
docker --context "$context" run --rm -v "$vol:/data" alpine:3.22 \
  sh -c 'test "$(cat /data/probe)" = volume-ok && echo volume-ok'

echo "6/7: Buildx local ARM64/AMD64 image builds"
cat > "$scratch/Dockerfile" <<'EOF'
FROM alpine:3.22
RUN echo built-by-standard-dockerd >/probe
CMD ["cat", "/probe"]
EOF
docker --context "$context" buildx build --platform linux/arm64 --load \
  -t "$image_arm" "$scratch"
docker --context "$context" run --rm "$image_arm" | grep -qx built-by-standard-dockerd
docker --context "$context" buildx build --platform linux/amd64 --load \
  -t "$image_amd" "$scratch"
docker --context "$context" run --rm --platform linux/amd64 "$image_amd" | grep -qx built-by-standard-dockerd

echo "7/7: Docker Compose"
cat > "$scratch/compose.yaml" <<'EOF'
services:
  test:
    image: alpine:3.22
    command: ["sh", "-c", "echo compose-ok"]
EOF
docker --context "$context" compose -p "kiri-moby-smoke-$$" \
  -f "$scratch/compose.yaml" up --abort-on-container-exit --exit-code-from test
docker --context "$context" compose -p "kiri-moby-smoke-$$" \
  -f "$scratch/compose.yaml" down --volumes

echo "PASS: native arm64, Rosetta amd64, bind mount, volumes, Buildx and Compose"

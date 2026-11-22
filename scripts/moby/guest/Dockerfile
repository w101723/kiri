# Minimal Alpine base with only the support packages dockerd needs at runtime.
# The Docker Engine is NOT part of the seed: the launcher exports the pinned
# engine binaries (docker-ce 29.x, built for aarch64 by upstream) read-only
# over VirtioFS under the "docker" tag and PID1 prefers them, mirroring
# OrbStack's app-injected engine. A missing tag fails closed: an incomplete
# injection is a packaging mistake, not a reason to boot an old engine.
FROM --platform=linux/arm64 alpine:3.22
RUN apk add --no-cache iptables ip6tables iproute2 e2fsprogs util-linux ca-certificates tzdata \
 && command -v iptables && command -v ip \
 && /bin/busybox --list | grep -qx switch_root \
 && /bin/busybox --list | grep -qx blkid \
 && /bin/busybox --list | grep -qx udhcpc
COPY init /init
COPY udhcpc-script /usr/local/sbin/kiri-udhcpc
COPY rosetta.sh /usr/local/sbin/kiri-rosetta
COPY kiri-moby-guest /usr/local/sbin/kiri-moby-guest
RUN chmod 0755 /init /usr/local/sbin/kiri-udhcpc /usr/local/sbin/kiri-rosetta /usr/local/sbin/kiri-moby-guest \
 && mkdir -p /run /var/log /sys/fs/cgroup /mnt/mac /Users /Volumes /dev/pts /run/docker-host

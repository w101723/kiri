# Stock Alpine base with only the support packages dockerd needs at runtime.
# The Docker Engine itself is NOT installed from Alpine (28.x there): the
# launcher exports the pinned engine binaries (docker-ce 29.x, built for
# aarch64 by upstream) read-only over VirtioFS under the "docker" tag and PID1
# prefers them, mirroring OrbStack's app-injected engine. The seed's own
# /usr/bin/dockerd (Alpine package) remains as a fallback for backends that do
# not export the tag.
FROM --platform=linux/arm64 alpine:3.22
# The Alpine docker package (28.x) stays as the fallback engine for backends
# that do not export the injected tag; the launcher's pinned 29.x engine wins
# when present.
RUN apk add --no-cache docker docker-engine iptables ip6tables iproute2 e2fsprogs util-linux ca-certificates tzdata \
 && command -v dockerd && command -v containerd && command -v runc \
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

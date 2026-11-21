# Standard Moby/Docker Engine packages on Linux ARM64; not Kiri's custom engine.
FROM --platform=linux/arm64 alpine:3.22
RUN apk add --no-cache docker containerd runc iptables ip6tables iproute2 ca-certificates tzdata e2fsprogs util-linux \
 && command -v dockerd && command -v containerd && command -v runc \
 && command -v iptables && command -v udhcpc \
 && /bin/busybox --list | grep -qx switch_root \
 && /bin/busybox --list | grep -qx blkid \
 && dockerd --version && containerd --version && runc --version
COPY init /init
COPY udhcpc-script /usr/local/sbin/kiri-udhcpc
COPY rosetta.sh /usr/local/sbin/kiri-rosetta
COPY kiri-moby-guest /usr/local/sbin/kiri-moby-guest
RUN chmod 0755 /init /usr/local/sbin/kiri-udhcpc /usr/local/sbin/kiri-rosetta /usr/local/sbin/kiri-moby-guest \
 && mkdir -p /run /var/log /sys/fs/cgroup /mnt/mac /Users /Volumes /dev/pts

# Standard Moby/Docker Engine on Linux ARM64, on a Debian base; not Kiri's
# custom engine. The engine comes from Docker's official apt repository so the
# Guest tracks upstream releases (docker-ce 29.x) instead of Debian's packaged
# 26.x. BusyBox stays static so the boot initramfs needs no shared libraries.
FROM --platform=linux/arm64 debian:trixie
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl gnupg iptables iproute2 e2fsprogs util-linux \
      busybox-static kmod procps \
 && install -m 0755 -d /etc/apt/keyrings \
 && curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc \
 && chmod a+r /etc/apt/keyrings/docker.asc \
 && printf 'Types: deb\nArchitectures: arm64\nURIs: https://download.docker.com/linux/debian\nSuites: trixie\nComponents: stable\nSigned-By: /etc/apt/keyrings/docker.asc\n' \
      > /etc/apt/sources.list.d/docker.sources \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin \
 && apt-get purge -y curl gnupg && apt-get autoremove -y \
 && rm -rf /var/lib/apt/lists/* \
 && command -v dockerd && command -v containerd && command -v runc \
 && command -v iptables && command -v docker \
 && /bin/busybox --list | grep -qx switch_root \
 && command -v blkid \
 && dockerd --version && containerd --version && runc --version && docker --version
COPY init /init
COPY udhcpc-script /usr/local/sbin/kiri-udhcpc
COPY rosetta.sh /usr/local/sbin/kiri-rosetta
COPY kiri-moby-guest /usr/local/sbin/kiri-moby-guest
RUN chmod 0755 /init /usr/local/sbin/kiri-udhcpc /usr/local/sbin/kiri-rosetta /usr/local/sbin/kiri-moby-guest \
 && mkdir -p /run /var/log /sys/fs/cgroup /mnt/mac /Users /Volumes /dev/pts

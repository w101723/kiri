#!/bin/sh
# binfmt registration matches the pattern already used by upstream kiri-init.
set -e
mkdir -p /run/rosetta /proc/sys/fs/binfmt_misc
mount -t virtiofs -o ro rosetta /run/rosetta || exit 0
mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc || exit 1
test -x /run/rosetta/rosetta || exit 1
printf '%s\n' ':rosetta:M::\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x3e\x00:\xff\xff\xff\xff\xff\xfe\xfe\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:/run/rosetta/rosetta:CF' > /proc/sys/fs/binfmt_misc/register

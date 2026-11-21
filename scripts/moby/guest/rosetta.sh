#!/bin/sh
# binfmt registration matches the pattern already used by upstream kiri-init.
set -e
mode="${1:-}"
diagnose() {
    if [ "$mode" = --diagnose ]; then printf '[kiri-rosetta] %s\n' "$1" >&2; fi
}
mkdir -p /run/rosetta /proc/sys/fs/binfmt_misc
if ! mount -t virtiofs -o ro rosetta /run/rosetta; then
    diagnose 'VirtioFS mount failed'
    if [ "$mode" = --diagnose ]; then exit 1; fi
    exit 0
fi
diagnose 'VirtioFS mounted read-only'
if ! mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc; then
    diagnose 'binfmt_misc mount failed'
    exit 1
fi
if ! test -x /run/rosetta/rosetta; then
    diagnose 'Apple interpreter is missing or not executable'
    exit 1
fi
diagnose 'Apple interpreter is executable'
registration=':rosetta:M::\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x3e\x00:\xff\xff\xff\xff\xff\xfe\xfe\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:/run/rosetta/rosetta:CF'
if [ "$mode" != --diagnose ]; then
    printf '%s\n' "$registration" > /proc/sys/fs/binfmt_misc/register
    exit
fi
# One registration per write: a separate trailing newline can be rejected
# even though binfmt_misc already accepted the rule.
if ! printf '%s' "$registration" > /proc/sys/fs/binfmt_misc/register; then
    diagnose 'binfmt_misc registration write failed; checking kernel state'
fi
entry=/proc/sys/fs/binfmt_misc/rosetta
if ! grep -Fxq enabled "$entry" || ! grep -Fxq 'interpreter /run/rosetta/rosetta' "$entry"; then
    diagnose 'binfmt_misc registration could not be verified'
    exit 1
fi
diagnose 'binfmt_misc registered interpreter /run/rosetta/rosetta'

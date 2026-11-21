#!/bin/sh
# Mocked-fixture test for the kiri-share-layout block in this directory's
# init. Runs unprivileged on any POSIX shell (macOS host CI included): the
# block is extracted between its markers and replayed with stubbed mount
# and kiri-moby-guest binaries. Real virtiofs mounts and Rust validation
# stay on the Guest; this only pins the mount planning and fail-closed
# behavior of the two share layouts.
set -eu

dir="$(dirname "$0")"
init="$dir/init"
[ -f "$init" ] || { echo "missing $init" >&2; exit 1; }
sh -n "$init"
sh -n "$0"

block="$(sed -n '/# --- kiri-share-layout begin/,/# --- kiri-share-layout end/p' "$init")"
[ -n "$block" ] || { echo "FATAL: share-layout markers not found in $init" >&2; exit 1; }

work="$(mktemp -d "${TMPDIR:-/tmp}/kiri-share-test.XXXXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"

# Stub kiri-moby-guest: records the authorized spec; the real Rust decoder
# re-validates it inside the Guest.
cat >"$work/bin/kiri-moby-guest" <<EOF
#!/bin/sh
echo "guest \$*" >> "$work/calls.log"
EOF
chmod +x "$work/bin/kiri-moby-guest"

# run_case <name> <expect-die:0|1> <mount-fail-tag-or-none> <layout> <spec>
run_case() {
    name="$1" expect_die="$2" fail_tag="$3" share_layout="$4" share_spec="$5"
    : >"$work/calls.log"
    : >"$work/out.log"
    rm -rf "$work/mntmac"
    cat >"$work/harness.sh" <<EOF
set -eu
log() { echo "LOG \$*" >> "$work/out.log"; }
die() { echo "DIE \$*" >> "$work/out.log"; exit 42; }
mount() {
    echo "mount \$*" >> "$work/calls.log"
    for a in "\$@"; do [ "\$a" = "$fail_tag" ] && return 1; done
    return 0
}
share_layout="$4"
share_spec="$5"
$block
EOF
    KIRI_MOBY_MAC_MOUNT="$work/mntmac" \
    KIRI_MOBY_GUEST_BIN="$work/bin/kiri-moby-guest" \
        sh "$work/harness.sh" && rc=0 || rc=$?
    case "$expect_die:$rc" in
        0:0|1:42) ;;
        *) echo "FAIL [$name]: exit $rc, expected die=$expect_die" >&2
            cat "$work/out.log" >&2; exit 1 ;;
    esac
}

expect_calls() { # name then fixed-string lines that must appear in calls.log
    name="$1"; shift
    for line in "$@"; do
        grep -Fqx -- "$line" "$work/calls.log" || {
            echo "FAIL [$name]: missing call '$line'" >&2
            cat "$work/calls.log" >&2; exit 1; }
    done
}

expect_no_call() {
    name="$1"; line="$2"
    grep -Fqx -- "$line" "$work/calls.log" && {
        echo "FAIL [$name]: unexpected call '$line'" >&2; exit 1; } || true
}

# 1) Original VZ layout: single kiri-mac mount, Rust --mount-shares runs,
#    no per-directory tags are touched.
VZ_SPEC="s0@2f55736572732f612f646576,s1@2f566f6c756d65732f5353442f5265706f"
run_case "vz-spec" 0 none "" "$VZ_SPEC"
expect_calls "vz-spec" \
    "mount -t virtiofs kiri-mac $work/mntmac" \
    "guest --mount-shares $VZ_SPEC"
expect_no_call "vz-spec" "mount -t virtiofs kiri-s0 $work/mntmac/s0"

# 2) VZ layout without a spec: legacy broad bind stays possible (the
#    trusted Host only emits kiri-mac with /Users when opted in).
run_case "vz-legacy" 0 none "" ""
expect_calls "vz-legacy" "mount -t virtiofs kiri-mac $work/mntmac"
expect_no_call "vz-legacy" "guest --mount-shares "

# 3) HVF per-directory: each kiri-sN tag mounted at <mac_root>/sN first,
#    then the unchanged Rust validation/binds.
run_case "hvf-2shares" 0 none per-directory "$VZ_SPEC"
expect_calls "hvf-2shares" \
    "mount -t virtiofs kiri-s0 $work/mntmac/s0" \
    "mount -t virtiofs kiri-s1 $work/mntmac/s1" \
    "guest --mount-shares $VZ_SPEC"
expect_no_call "hvf-2shares" "mount -t virtiofs kiri-mac"

# 4) HVF per-directory with no shares: nothing is mounted; no implicit
#    broad kiri-mac or /Users fallback.
run_case "hvf-none" 0 none per-directory ""
expect_no_call "hvf-none" "mount -t virtiofs kiri-mac"
expect_no_call "hvf-none" "guest --mount-shares "

# 5) A missing per-share tag fails closed; no fallback to broad sharing.
run_case "hvf-tag-missing" 1 kiri-s1 per-directory "$VZ_SPEC"
expect_no_call "hvf-tag-missing" "mount -t virtiofs kiri-mac"
grep -q "VirtioFS per-share mount kiri-s1 failed" "$work/out.log" || {
    echo "FAIL [hvf-tag-missing]: wrong fatal message" >&2; exit 1; }

# 6) More than the 16 approved slots is refused before any mount attempt.
spec17=""
i=0
while [ "$i" -lt 17 ]; do
    [ "$i" -eq 0 ] || spec17="$spec17,"
    spec17="$spec17 s$i@2f55736572732f612f646576"
    spec17="${spec17# }"
    i=$((i + 1))
done
run_case "hvf-too-many" 1 none per-directory "$spec17"
expect_no_call "hvf-too-many" "guest --mount-shares $spec17"
grep -q "too many share entries" "$work/out.log" || {
    echo "FAIL [hvf-too-many]: no rejection message" >&2; exit 1; }

# 7) A malformed spec still reaches Rust: planning does not pre-filter it.
run_case "hvf-malformed" 0 none per-directory "s0@zz,s1@2f"
expect_calls "hvf-malformed" "guest --mount-shares s0@zz,s1@2f"

echo "kiri-share-layout mocked tests: all cases passed"

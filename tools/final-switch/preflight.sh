#!/usr/bin/env bash
# FINAL SWITCH -- shared preflight and helpers.
#
# Sourced by every other script in this directory. Executed directly it runs
# the host checks and prints the provenance block, which is the cheapest way
# to confirm the machine is in the state the numbers will claim it was.
#
# Everything here is fail-closed on purpose. Each check exists because its
# absence produced a wrong or vacuous result at least once during Gate A:
#
#   * FS_CPU pinning -- run_zoo_compare.py ATTESTS effective affinity, it does
#     not SET it. Callers must supply `taskset -c $FS_CPU`. The first Gate A
#     attempt omitted it and the runner refused all three invocations (rc=2).
#     fs_pinned() below is the only sanctioned way to invoke those runners.
#   * FS_LOCK -- the exclusive host lock, held across every build, test and
#     measurement so nothing perturbs anything else.
#   * the qjs yardstick -- comparisons are only ever against pinned QuickJS.

# Guard against double-sourcing (build_artifacts.sh -> preflight.sh, and a
# caller that sources both).
if [ "${FS_PREFLIGHT_SOURCED:-0}" = 1 ]; then
    return 0 2>/dev/null || true
fi
FS_PREFLIGHT_SOURCED=1

FS_ZIG="${FS_ZIG:-/home/aneryu/.local/share/mise/installs/zig/0.16.0/bin/zig}"
FS_QJS="${FS_QJS:-/home/aneryu/quickjs/qjs}"
FS_ZOO="${FS_ZOO:-/home/aneryu/javascript-zoo}"
FS_CPU="${FS_CPU:-19}"
FS_LOCK="${FS_LOCK:-/tmp/zjs-host-heavy.lock}"

# Gate A manifest (see README.md). Recorded so a future run that no longer
# matches says so out loud instead of quietly comparing against a different
# world.
FS_GATE_A_COMMIT="04922a471eaf940b1a3964e2572efffdc7727a06"
FS_GATE_A_ZIG="0.16.0"
FS_GATE_A_QJS_SHA="b76d154265e829e64d14dafba9e8f3eb8f2215ac947ffb62cc31379d1171364d"

fs_say() { printf '########## %s  %s\n' "$*" "$(date -Is)"; }
fs_die() { printf 'error: %s\n' "$*" >&2; exit 2; }

# Every build/test/measurement goes through the exclusive host lock.
fs_heavy() { flock -x "$FS_LOCK" "$@"; }

# The ONLY sanctioned way to invoke a runner that attests affinity. Supplying
# taskset here rather than at each call site is the fix for the Gate A defect
# where an unpinned invocation was possible at all.
fs_pinned() { flock -x "$FS_LOCK" taskset -c "$FS_CPU" "$@"; }

fs_repo_root() { (cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd); }

fs_provenance() {
    local repo; repo="$(fs_repo_root)"
    printf 'PROVENANCE commit=%s dirty=%s\n' \
        "$(git -C "$repo" rev-parse HEAD 2>/dev/null || echo '?')" \
        "$(git -C "$repo" status --porcelain 2>/dev/null | wc -l)"
    printf 'PROVENANCE zig=%s\n' "$("$FS_ZIG" version 2>/dev/null || echo '?')"
    printf 'PROVENANCE qjs=%s sha256=%s\n' "$FS_QJS" \
        "$(sha256sum "$FS_QJS" 2>/dev/null | cut -d' ' -f1)"
    printf 'PROVENANCE cpu=%s kernel=%s\n' "$FS_CPU" "$(uname -r)"
}

# Checks required before anything is BUILT.
fs_preflight_build() {
    [ -x "$FS_ZIG" ] || fs_die "zig not executable at $FS_ZIG (set FS_ZIG)"
    local zver; zver="$("$FS_ZIG" version)"
    [ "$zver" = "$FS_GATE_A_ZIG" ] || \
        printf 'warning: zig %s != Gate A manifest %s\n' "$zver" "$FS_GATE_A_ZIG" >&2
    local repo; repo="$(fs_repo_root)"
    [ -f "$repo/build.zig" ] || fs_die "no build.zig under $repo"
    if [ -n "$(git -C "$repo" status --porcelain 2>/dev/null)" ]; then
        printf 'warning: working tree is DIRTY; artifacts will not match any commit\n' >&2
    fi
    return 0
}

# Checks required before anything is MEASURED. Strictly more than the build
# side: a wrong host here silently produces plausible numbers.
fs_preflight_measure() {
    fs_preflight_build
    [ -x "$FS_QJS" ] || fs_die "pinned qjs not executable at $FS_QJS (set FS_QJS)"
    local qsha; qsha="$(sha256sum "$FS_QJS" | cut -d' ' -f1)"
    [ "$qsha" = "$FS_GATE_A_QJS_SHA" ] || \
        printf 'warning: qjs sha256 %s != Gate A manifest %s (the yardstick moved)\n' \
            "$qsha" "$FS_GATE_A_QJS_SHA" >&2
    [ -d "$FS_ZOO" ] || fs_die "javascript-zoo checkout not found at $FS_ZOO (set FS_ZOO)"
    command -v taskset >/dev/null || fs_die "taskset not available; measurement cannot be pinned"
    command -v flock   >/dev/null || fs_die "flock not available; the host lock cannot be held"
    command -v perf    >/dev/null || fs_die "perf not available; instructions/cycles cannot be collected"
    # Prove the pin we are about to rely on actually takes effect, rather than
    # discovering at the end of a 40-minute run that it did not.
    local eff
    eff="$(taskset -c "$FS_CPU" python3 -c 'import os;print(sorted(os.sched_getaffinity(0)))' 2>/dev/null)"
    [ "$eff" = "[$FS_CPU]" ] || \
        fs_die "taskset -c $FS_CPU yields effective affinity $eff, not [$FS_CPU]"
    return 0
}

# Run directly (not sourced): report the host state.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    set -uo pipefail
    fs_say "PREFLIGHT"
    fs_preflight_measure
    fs_provenance
    fs_say "PREFLIGHT OK"
fi

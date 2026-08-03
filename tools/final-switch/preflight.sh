#!/usr/bin/env bash
# FINAL SWITCH -- shared preflight, helpers, and the STANDING RULES.
#
# Sourced by every other script in this directory. Executed directly it runs
# the host checks and prints the provenance block, which is the cheapest way
# to confirm the machine is in the state the numbers will claim it was.
#
# The five standing rules are implemented here as callable predicates, and
# `selftest.sh` fault-injects every one of them on every run so that none can
# rot into a comment. Each rule is a REGRESSION TEST for a defect that actually
# happened during Gate A, not a style preference:
#
#   RULE A  AFFINITY     the orchestrator SETS the pin (`taskset -c $FS_CPU`)
#                        and INDEPENDENTLY verifies it took effect. It never
#                        trusts a runner's own affinity self-report.
#   RULE B  TS PROBES    a TypeScript probe routes through
#                        parseAndCompileV2TestProgram(), never `zjs -e '<ts>'`.
#   RULE C  L3 COLLECT   `v2_construct_emitted > 0` is asserted BEFORE
#                        `legacy_in_v2_unallowed == 0` is believed.
#   RULE D  CORPUS SKIPS the actual skipped set is compared against an EXPLICIT
#                        allowlist, per case, by identity. (src/compiler_v2.)
#   RULE E  STRICT SHELL every script is strict-mode, is shellcheck-clean, and
#                        ABORTS LOUDLY rather than silently emitting nothing.
#
# Everything else here is fail-closed for the same reason:
#
#   * FS_LOCK -- the exclusive host lock, held across every build, test and
#     measurement so nothing perturbs anything else.
#   * the qjs yardstick -- comparisons are only ever against pinned QuickJS.

# Guard against double-sourcing (build_artifacts.sh -> preflight.sh, and a
# caller that sources both).
if [ "${FS_PREFLIGHT_SOURCED:-0}" = 1 ]; then
    # shellcheck disable=SC2317  # reachable only on a second `source`
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
FS_GATE_A_ZIG="0.16.0"
FS_GATE_A_QJS_SHA="b76d154265e829e64d14dafba9e8f3eb8f2215ac947ffb62cc31379d1171364d"

fs_say() { printf '########## %s  %s\n' "$*" "$(date -Is)"; }

# --------------------------------------------------------------------------
# RULE E -- strict shell, and a loud abort.
#
# A `set -u` unbound-variable bug killed two separate Gate A measurement
# scripts. Both times the script stopped mid-way, printed a one-line bash
# diagnostic among hundreds of lines of build output, and produced NO verdict
# -- which reads like a run that is still going, not like a run that died.
#
# fs_strict() installs an EXIT trap that fires unless fs_finish() was reached,
# so any premature death (set -u, a missing binary, a `kill`) ends in an
# unmissable banner and a non-zero status. Every executable script in this
# directory calls fs_strict at the top and fs_finish at the bottom; selftest.sh
# enforces both statically AND proves the trap fires by injecting a genuine
# unbound-variable fault.
# --------------------------------------------------------------------------
fs_strict() {
    set -uo pipefail
    FS_SCRIPT_NAME="${1:-${BASH_SOURCE[1]:-<unknown>}}"
    FS_COMPLETED=0
    trap 'fs_abort_banner' EXIT
}

fs_abort_banner() {
    local rc=$?
    [ "${FS_COMPLETED:-0}" = 1 ] && return 0
    printf '\n########## ABORTED %s rc=%s\n' "${FS_SCRIPT_NAME:-<unknown>}" "$rc" >&2
    printf 'error: this script exited BEFORE reaching its verdict.\n' >&2
    printf '       Nothing below the abort point ran, so any output above is PARTIAL\n' >&2
    printf '       and no gate result may be read from it. (A set -u unbound variable\n' >&2
    printf '       killed two Gate A measurement scripts exactly this way.)\n' >&2
    [ "$rc" -eq 0 ] && exit 3
    return 0
}

# The only sanctioned exit. Marks the run complete so the abort banner stays
# silent, then exits with the verdict.
fs_finish() {
    FS_COMPLETED=1
    exit "${1:-0}"
}

# A deliberate, already-reported failure: loud on its own, so suppress the
# abort banner and exit 2.
fs_die() {
    printf 'error: %s\n' "$*" >&2
    FS_COMPLETED=1
    exit 2
}

# Every build/test/measurement goes through the exclusive host lock.
#
# flock is NOT reentrant across processes: a nested acquisition from inside a
# context that already holds the lock -- `flock -x $FS_LOCK zig build
# final-switch-selftest`, say -- blocks forever, with no output, which is
# indistinguishable from a long build. FS_LOCK_ALREADY_HELD=1 declares "my
# caller holds it"; it is recorded in the provenance block so a run that
# skipped the lock says so on the record rather than quietly.
fs_lock_prefix() {
    if [ "${FS_LOCK_ALREADY_HELD:-0}" = 1 ]; then
        FS_LOCK_ARGV=()
    else
        FS_LOCK_ARGV=(flock -x "$FS_LOCK")
    fi
}

fs_heavy() {
    fs_lock_prefix
    "${FS_LOCK_ARGV[@]+"${FS_LOCK_ARGV[@]}"}" "$@"
}

# --------------------------------------------------------------------------
# RULE A -- affinity is SET by the orchestrator and VERIFIED independently.
#
# tools/perf/**/run_*.py ATTEST effective affinity; they do not SET it. The
# first Gate A performance attempt omitted `taskset -c 19` and the runner
# refused all three invocations (rc=2). That was fail-closed behaviour working,
# but only because the runner happened to check -- the orchestrator should
# never have been able to request an unpinned measurement at all.
#
# Two halves, and the second is the one that was missing:
#
#   1. fs_pinned() is the ONLY sanctioned way to invoke an affinity-attesting
#      runner and always supplies `taskset -c $FS_CPU`. selftest.sh refuses any
#      script in this directory that names such a runner without it, and
#      refuses any script other than this one that spells `taskset` at all, so
#      there is exactly one audited chokepoint.
#
#   2. fs_pinned() verifies the pin from INSIDE the pinned process tree, via
#      /proc/self/status, immediately before exec'ing the runner -- a different
#      mechanism, a different process, and no dependence on anything the runner
#      reports about itself. The observation is appended to $FS_AFFINITY_ATTEST
#      so join_results.py can require the orchestrator's independent reading and
#      the runner's self-report to AGREE. One source attesting itself is not
#      verification.
# --------------------------------------------------------------------------

# fs_effective_affinity [pid-less] -- this process's affinity as a CPU list.
# Reads /proc, deliberately NOT python's os.sched_getaffinity, so that the
# orchestrator's reading shares no code with the runner's.
fs_effective_affinity() {
    grep -m1 '^Cpus_allowed_list:' /proc/self/status | cut -f2
}

# fs_verify_affinity <cpu> -- prove `taskset -c <cpu>` actually pins, standalone.
# Used by fs_preflight_measure so a 40-minute run does not discover this at the
# end. Returns 2 and explains itself on failure.
fs_verify_affinity() {
    local cpu="$1" eff
    command -v taskset >/dev/null || { printf 'error: taskset not available\n' >&2; return 2; }
    eff="$(taskset -c "$cpu" bash -c 'grep -m1 "^Cpus_allowed_list:" /proc/self/status | cut -f2' 2>/dev/null)"
    if [ "$eff" != "$cpu" ]; then
        printf 'error: taskset -c %s yields effective affinity [%s], not [%s]\n' \
            "$cpu" "${eff:-<unreadable>}" "$cpu" >&2
        return 2
    fi
    printf 'AFFINITY verified independently: taskset -c %s => Cpus_allowed_list=%s\n' "$cpu" "$eff"
    return 0
}

# fs_pinned <cmd...> -- run under the host lock, pinned, with the pin verified
# from inside the pinned process before the command is exec'd.
fs_pinned() {
    local attest="${FS_AFFINITY_ATTEST:-/dev/null}"
    fs_lock_prefix
    # The inner script is single-quoted deliberately: it must be evaluated by
    # the pinned child, not by this shell, so that the /proc read observes the
    # child's affinity. Values cross the boundary as positional arguments.
    # shellcheck disable=SC2016
    "${FS_LOCK_ARGV[@]+"${FS_LOCK_ARGV[@]}"}" taskset -c "$FS_CPU" bash -c '
        set -uo pipefail
        want="$1"; attest="$2"; shift 2
        eff="$(grep -m1 "^Cpus_allowed_list:" /proc/self/status | cut -f2)"
        printf "%s\t%s\t%s\n" "$want" "${eff:-<unreadable>}" "$*" >> "$attest"
        if [ "$eff" != "$want" ]; then
            printf "error: pinned invocation observed affinity [%s], expected [%s]\n" \
                "${eff:-<unreadable>}" "$want" >&2
            printf "       refusing to measure: this is the Gate A unpinned-measurement defect\n" >&2
            exit 2
        fi
        exec "$@"
    ' fs_pinned "$FS_CPU" "$attest" "$@"
}

fs_repo_root() { (cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd); }

fs_provenance() {
    local repo; repo="$(fs_repo_root)"
    printf 'PROVENANCE commit=%s dirty=%s\n' \
        "$(git -C "$repo" rev-parse HEAD 2>/dev/null || echo '?')" \
        "$(git -C "$repo" status --porcelain 2>/dev/null | wc -l)"
    printf 'PROVENANCE zig=%s\n' "$("$FS_ZIG" version 2>/dev/null || echo '?')"
    printf 'PROVENANCE qjs=%s sha256=%s\n' "$FS_QJS" \
        "$(sha256sum "$FS_QJS" 2>/dev/null | cut -d' ' -f1)"
    printf 'PROVENANCE cpu=%s kernel=%s orchestrator_affinity=%s\n' \
        "$FS_CPU" "$(uname -r)" "$(fs_effective_affinity)"
    printf 'PROVENANCE host_lock=%s\n' \
        "$([ "${FS_LOCK_ALREADY_HELD:-0}" = 1 ] && echo "assumed-held-by-caller (FS_LOCK_ALREADY_HELD=1)" || echo "$FS_LOCK")"
}

# --------------------------------------------------------------------------
# RULE C -- an emission report is only evidence once something was emitted.
#
# The first Gate A L3 collect invoked the binary with --print-config-signature,
# which compiles NOTHING, and reported
#     v2_construct_emitted=0 ... legacy_in_v2_unallowed=0
# a vacuous zero that reads exactly like a pass. `legacy_in_v2_unallowed == 0`
# is a claim about constructs that were emitted; over zero emitted constructs
# it is not a weak pass, it is not a measurement.
#
# fs_l3_verdict <report-line> prints one of
#     PASS emitted=N unallowed=0
#     VACUOUS emitted=0 unallowed=N   (rc 1) -- the defect, caught
#     FAIL   emitted=N unallowed=M    (rc 1)
#     NOREPORT                        (rc 1)
# and is the single implementation both migration_gates.sh and selftest.sh use,
# so the assertion cannot be right in the test and wrong in the gate.
# --------------------------------------------------------------------------
fs_l3_verdict() {
    local report="${1:-}" emitted unallowed
    if [ -z "$report" ]; then
        printf 'NOREPORT no coverage line was emitted at all\n'
        return 1
    fi
    emitted="$(printf '%s' "$report"   | grep -oE 'v2_construct_emitted=[0-9]+'   | cut -d= -f2)"
    unallowed="$(printf '%s' "$report" | grep -oE 'legacy_in_v2_unallowed=[0-9]+' | cut -d= -f2)"
    if [ -z "$emitted" ] || [ -z "$unallowed" ]; then
        printf 'NOREPORT coverage line is missing v2_construct_emitted or legacy_in_v2_unallowed: %s\n' "$report"
        return 1
    fi
    # THE ORDER IS THE RULE: emitted>0 is checked FIRST. A zero unallowed count
    # over a workload that emitted nothing proves nothing about fallback.
    if [ "$emitted" -le 0 ]; then
        printf 'VACUOUS emitted=0 unallowed=%s -- this workload compiled NOTHING, so legacy_in_v2_unallowed=%s is not evidence\n' \
            "$unallowed" "$unallowed"
        return 1
    fi
    if [ "$unallowed" -ne 0 ]; then
        printf 'FAIL emitted=%s unallowed=%s -- legacy emission inside v2 scope\n' "$emitted" "$unallowed"
        return 1
    fi
    printf 'PASS emitted=%s unallowed=0\n' "$emitted"
    return 0
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
    command -v flock >/dev/null || fs_die "flock not available; the host lock cannot be held"
    command -v perf  >/dev/null || fs_die "perf not available; instructions/cycles cannot be collected"
    # RULE A, first half: prove the pin takes effect BEFORE a long run starts.
    fs_verify_affinity "$FS_CPU" || fs_die "affinity pin does not take effect; refusing to measure"
    return 0
}

# Run directly (not sourced): report the host state.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    fs_strict "preflight.sh"
    fs_say "PREFLIGHT"
    fs_preflight_measure
    fs_provenance
    fs_say "PREFLIGHT OK"
    fs_finish 0
fi

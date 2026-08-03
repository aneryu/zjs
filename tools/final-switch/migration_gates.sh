#!/usr/bin/env bash
# FINAL SWITCH -- migration-only gates. These require BOTH compilers to exist.
#
# Everything in this file stops being runnable the moment the legacy production
# path is deleted, which is exactly why it is a separate file: after deletion
# it should be removed wholesale, not quietly reduced to a set of no-ops that
# still print PASS.
#
#   * the dual comparator over the Zig corpus and over test262 -- the only
#     oracle that can say "the two backends produce the same thing", as opposed
#     to "both backends pass the same tests";
#   * the L3 emission gate -- proves the v2 pipeline is not silently falling
#     back into legacy emission for production constructs.
#
# DEFECT FIXED HERE (found the hard way during Gate A): the L3 collect must run
# over a REAL WORKLOAD. The first attempt invoked the binary with
# `--print-config-signature`, which compiles nothing, and so reported
#     v2_construct_emitted=0 legacy_in_v2_unallowed=0
# a vacuous zero that reads exactly like a pass. `legacy_in_v2_unallowed == 0`
# is only evidence when `v2_construct_emitted > 0`; the assertion below refuses
# the report otherwise.
#
# Usage: tools/final-switch/migration_gates.sh [--out DIR] [--workload FILE]...
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
# shellcheck source=./preflight.sh
source "$HERE/preflight.sh"

OUT="$REPO/reports/perf/final-switch/migration"
WORKLOADS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --out) OUT="$2"; shift 2 ;;
        --workload) WORKLOADS+=("$2"); shift 2 ;;
        *) fs_die "unknown argument: $1" ;;
    esac
done
mkdir -p "$OUT"
cd "$REPO" || fs_die "cannot enter $REPO"
fs_preflight_build

FAILED=0
SUMMARY="$OUT/summary.tsv"
: > "$SUMMARY"

record() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$SUMMARY"; }

fs_provenance

# The legacy path must still exist for any of this to mean anything.
if ! "$FS_ZIG" build --help 2>&1 | grep -q 'zjs_compiler'; then
    fs_die "-Dzjs_compiler is gone: the migration gates are no longer runnable, delete this script"
fi

# --------------------------------------------------------------------------
# 1. Dual comparator over the Zig corpus.
# --------------------------------------------------------------------------
fs_say "GATE dual-zig-corpus"
rc=0
fs_heavy "$FS_ZIG" build test -Dzjs_compiler=dual --summary all > "$OUT/dual-zig.log" 2>&1 || rc=$?
MISMATCHES="$(grep -c 'ZJS-DUAL-MISMATCH' "$OUT/dual-zig.log" 2>/dev/null || true)"
printf '  rc=%s  ZJS-DUAL-MISMATCH lines=%s\n' "$rc" "$MISMATCHES"
[ "$rc" = 0 ] || { FAILED=1; tail -25 "$OUT/dual-zig.log" | sed 's/^/  | /'; }
record dual-zig-corpus "$rc" "mismatch_lines=$MISMATCHES"

# --------------------------------------------------------------------------
# 2. Dual comparator over the FULL test262 corpus.
#
# This is the last moment it can be run at all. It is the widest corpus either
# backend ever sees, and it covers constructs no hand-written corpus reaches:
# the divergence it found at 04922a47 (switch `default:` clause ending in an
# if/else whose taken branch is empty) appears in NO other dual corpus.
# --------------------------------------------------------------------------
fs_say "GATE dual-test262"
rc=0
fs_heavy "$FS_ZIG" build test262-gate -Dzjs_compiler=dual > "$OUT/dual-test262.log" 2>&1 || rc=$?
RESULT_LINE="$(grep -oE 'Result: [0-9]+/[0-9]+ errors, passed [0-9]+, known [0-9]+' "$OUT/dual-test262.log" | tail -1)"
printf '  rc=%s\n  %s\n' "$rc" "${RESULT_LINE:-<no Result line>}"
if [ -z "$RESULT_LINE" ]; then
    printf '  FAIL dual-test262 produced no Result line (the corpus did not run)\n'; FAILED=1
fi
[ "$rc" = 0 ] || FAILED=1
grep -oE 'ZJS-DUAL-MISMATCH .*' "$OUT/dual-test262.log" | sort -u | head -40 | sed 's/^/  MISMATCH /'
if [ -f reports/test262-latest/test262-failures.log ]; then
    cp reports/test262-latest/test262-failures.log "$OUT/dual-test262-failures.log"
    printf '  DualCompileMismatch cases:\n'
    grep 'DualCompileMismatch' "$OUT/dual-test262-failures.log" | sed 's/^/    /'
fi
record dual-test262 "$rc" "${RESULT_LINE:-<none>}"

# --------------------------------------------------------------------------
# 3. L3 emission gate over the Zig corpus.
# --------------------------------------------------------------------------
fs_say "GATE l3-emission-suite"
rc=0
ZJS_V2_EMISSION_COLLECT=1 fs_heavy "$FS_ZIG" build test-compiler-v2 --summary all \
    > "$OUT/l3-suite.log" 2>&1 || rc=$?
grep -E 'QCP-1 L3 emission coverage|violation_site' "$OUT/l3-suite.log" | tail -6 | sed 's/^/  /'
[ "$rc" = 0 ] || { printf '  FAIL l3-emission-suite\n'; FAILED=1; tail -25 "$OUT/l3-suite.log" | sed 's/^/  | /'; }
record l3-emission-suite "$rc" "-"

# --------------------------------------------------------------------------
# 4. L3 emission collect over a REAL WORKLOAD. See the defect note at the top.
# --------------------------------------------------------------------------
fs_say "BUILD zjs-dev (coverage instrumentation is Debug/ReleaseSafe only)"
rc=0
fs_heavy "$FS_ZIG" build zjs-dev > "$OUT/l3-build.log" 2>&1 || rc=$?
[ "$rc" = 0 ] || { printf '  FAIL zjs-dev build\n'; FAILED=1; tail -20 "$OUT/l3-build.log" | sed 's/^/  | /'; }
DEV="$REPO/zig-out/bin/zjs-dev"

# Default workloads: real source that actually reaches the compiler. A caller
# may add more with --workload, but may not reduce the set to nothing.
if [ "${#WORKLOADS[@]}" = 0 ]; then
    WORKLOADS=(
        "$HERE/l3_workload.js"
        "$HERE/l3_workload.ts"
    )
fi

l3_collect() {
    local workload="$1" tag; tag="$(basename "$workload")"
    if [ ! -f "$workload" ]; then
        printf '  FAIL l3-workload %s: file does not exist\n' "$workload"; FAILED=1; return 0
    fi
    local report
    report="$(ZJS_V2_EMISSION_COLLECT=1 "$DEV" "$workload" 2>&1 >/dev/null \
        | grep -E 'QCP-1 L3 emission coverage' | tail -1)"
    if [ -z "$report" ]; then
        printf '  FAIL l3-workload %s: no coverage report emitted\n' "$tag"; FAILED=1
        record "l3-workload-$tag" 1 "<no report>"; return 0
    fi
    printf '  %s: %s\n' "$tag" "$report"
    local emitted unallowed
    emitted="$(printf '%s' "$report"   | grep -oE 'v2_construct_emitted=[0-9]+'    | cut -d= -f2)"
    unallowed="$(printf '%s' "$report" | grep -oE 'legacy_in_v2_unallowed=[0-9]+'  | cut -d= -f2)"
    emitted="${emitted:-0}"; unallowed="${unallowed:-0}"
    # THE ASSERTION THAT WAS MISSING. A zero unallowed count over a workload
    # that emitted nothing is not a pass, it is an empty measurement.
    if [ "$emitted" -le 0 ]; then
        printf '  FAIL l3-workload %s: v2_construct_emitted=0 -- this workload compiled NOTHING,\n' "$tag"
        printf '       so legacy_in_v2_unallowed=%s is vacuous and proves nothing.\n' "$unallowed"
        FAILED=1
        record "l3-workload-$tag" 1 "VACUOUS emitted=0 unallowed=$unallowed"; return 0
    fi
    if [ "$unallowed" -ne 0 ]; then
        printf '  FAIL l3-workload %s: legacy_in_v2_unallowed=%s over %s emitted constructs\n' \
            "$tag" "$unallowed" "$emitted"
        FAILED=1
        record "l3-workload-$tag" 1 "emitted=$emitted unallowed=$unallowed"; return 0
    fi
    printf '  PASS l3-workload %s (emitted=%s > 0, unallowed=0)\n' "$tag" "$emitted"
    record "l3-workload-$tag" 0 "emitted=$emitted unallowed=0"
    return 0
}

fs_say "GATE l3-emission-workloads"
for w in "${WORKLOADS[@]}"; do l3_collect "$w"; done

fs_say "migration_gates FAILED=$FAILED"
exit "$FAILED"

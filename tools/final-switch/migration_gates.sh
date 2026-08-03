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
# RULE C (L3 COLLECT) is enforced here: the collect must run over a REAL
# WORKLOAD, and `v2_construct_emitted > 0` must be asserted BEFORE
# `legacy_in_v2_unallowed == 0` is believed. The first Gate A attempt invoked
# the binary with `--print-config-signature`, which compiles nothing, and so
# reported
#     v2_construct_emitted=0 legacy_in_v2_unallowed=0
# a vacuous zero that reads exactly like a pass. The assertion itself lives in
# fs_l3_verdict() in preflight.sh -- one implementation, shared with
# selftest.sh, which fault-injects a vacuous report on every run and requires
# the verdict VACUOUS.
#
# RULE B (TS PROBES) also applies to the TypeScript workload below. It is
# compiled from a `.ts` FILE, which the engine strips by path; a TypeScript
# probe must never be expressed as `zjs -e '<ts source>'`, which has no
# TypeScript handling and reports SyntaxError for every construct --
# indistinguishable from an engine failure. selftest.sh refuses that form
# statically and proves the SyntaxError dynamically.
#
# Usage: tools/final-switch/migration_gates.sh [--out DIR] [--workload FILE]...

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
# shellcheck source=./preflight.sh
source "$HERE/preflight.sh"
fs_strict "migration_gates.sh"

OUT="$REPO/reports/perf/final-switch/migration"
# Declared empty on purpose. Under `set -u` in bash < 4.4 a bare
# `"${empty[@]}"` is an unbound-variable error, so this array is only ever
# expanded with `${#...[@]}` (safe everywhere) or after the fs_die below has
# proved it non-empty. RULE E: a `set -u` fault killed two Gate A scripts.
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
# may ADD more with --workload, but may not reduce the set to nothing: the
# `[@]+` guard yields the empty string, the count check below then restores the
# defaults, and an empty final set is a hard failure rather than a silent
# zero-workload run that would print no FAIL lines at all.
if [ "${#WORKLOADS[@]}" -eq 0 ]; then
    WORKLOADS=(
        "$HERE/l3_workload.js"
        "$HERE/l3_workload.ts"
    )
fi
[ "${#WORKLOADS[@]}" -gt 0 ] || fs_die "no L3 workloads: a collect over nothing is the vacuous-zero defect"

l3_collect() {
    local workload="$1" tag; tag="$(basename "$workload")"
    if [ ! -f "$workload" ]; then
        printf '  FAIL l3-workload %s: file does not exist\n' "$workload"; FAILED=1; return 0
    fi
    # Capture the exit status too: a workload that throws (a SyntaxError from a
    # TypeScript probe expressed the wrong way, say) must not be read as a
    # clean collect just because a report line happened to be printed.
    local out run_rc=0
    out="$(ZJS_V2_EMISSION_COLLECT=1 "$DEV" "$workload" 2>&1 >/dev/null)" || run_rc=$?
    local report verdict verdict_rc=0
    report="$(printf '%s\n' "$out" | grep -E 'QCP-1 L3 emission coverage' | tail -1)"
    # RULE C lives in fs_l3_verdict(): emitted>0 is asserted BEFORE unallowed==0
    # is believed. selftest.sh fault-injects that exact function every run.
    verdict="$(fs_l3_verdict "$report")" || verdict_rc=$?
    printf '  %s: %s\n' "$tag" "${report:-<no coverage line>}"
    if [ "$run_rc" != 0 ]; then
        printf '  FAIL l3-workload %s: the workload itself exited rc=%s\n' "$tag" "$run_rc"
        printf '%s\n' "$out" | grep -vE 'QCP-1 L3 emission coverage' | tail -5 | sed 's/^/       | /'
        FAILED=1
        record "l3-workload-$tag" 1 "workload rc=$run_rc"
        return 0
    fi
    if [ "$verdict_rc" != 0 ]; then
        printf '  FAIL l3-workload %s: %s\n' "$tag" "$verdict"
        FAILED=1
        record "l3-workload-$tag" 1 "$verdict"
        return 0
    fi
    printf '  PASS l3-workload %s: %s\n' "$tag" "$verdict"
    record "l3-workload-$tag" 0 "$verdict"
    return 0
}

fs_say "GATE l3-emission-workloads"
for w in "${WORKLOADS[@]}"; do l3_collect "$w"; done

fs_say "migration_gates FAILED=$FAILED"
fs_finish "$FAILED"

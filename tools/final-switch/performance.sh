#!/usr/bin/env bash
# FINAL SWITCH -- the performance lane. FINAL SWITCH tier, not INTERMEDIATE.
#
# Runs ALONE on a quiet host: no correctness job may overlap, not even pinned
# to other cores. Sequence it after the correctness lanes, never beside them.
#
# DEFECT FIXED HERE (found the hard way during Gate A): run_zoo_compare.py
# ATTESTS effective affinity, it does not SET it. The first Gate A invocation
# omitted `taskset -c 19` and the runner refused all three runs (rc=2) --
# fail-closed, exactly as designed, but only because the runner happened to
# check. Every runner invocation below goes through fs_pinned(), which always
# supplies taskset, and a refusal (rc=2) is reported as a hard failure rather
# than being allowed to leave a missing artifact that a later join step would
# quietly skip.
#
# Four zoo runs, because the two noise floors answer different questions:
#   cand-b1 vs cand-b2     -- often byte-identical binaries => RUNTIME variance
#   legacy-a1 vs legacy-a2 -- genuinely different builds    => BUILD-LAYOUT lottery
# The four cross pairings (b*/a*) are then the gate, and all four are reported;
# dropping the unfavourable one is the failure mode this file exists to stop.
#
# code-load is ONE OF the 15 zoo benchmarks, so the zoo runs produce the switch
# gate directly. The codeload micro is a separate instrument that adds
# instructions/score and cycles/score attribution -- it does not replace the
# suite, and on its own it is INTERMEDIATE.
#
# Usage: tools/final-switch/performance.sh [--artifacts DIR] [--out DIR]
#                                          [--zoo-samples N] [--micro-samples N]
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
# shellcheck source=./preflight.sh
source "$HERE/preflight.sh"

ART="$REPO/reports/perf/final-switch/artifacts"
OUT="$REPO/reports/perf/final-switch/perf"
ZOO_SAMPLES=4
MICRO_SAMPLES=12
while [ $# -gt 0 ]; do
    case "$1" in
        --artifacts) ART="$2"; shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        --zoo-samples) ZOO_SAMPLES="$2"; shift 2 ;;
        --micro-samples) MICRO_SAMPLES="$2"; shift 2 ;;
        *) fs_die "unknown argument: $1" ;;
    esac
done
mkdir -p "$OUT"
cd "$REPO" || fs_die "cannot enter $REPO"
fs_preflight_measure

# Contract #3: odd sample counts unbalance ABBA and have twice voided a
# headline number. Refuse rather than round.
[ $((ZOO_SAMPLES % 2)) -eq 0 ]   || fs_die "--zoo-samples must be even (got $ZOO_SAMPLES)"
[ $((MICRO_SAMPLES % 2)) -eq 0 ] || fs_die "--micro-samples must be even (got $MICRO_SAMPLES)"

for side in cand-b1 cand-b2 legacy-a1 legacy-a2; do
    [ -x "$ART/zjs-$side" ] || fs_die "missing artifact $ART/zjs-$side (run build_artifacts.sh first)"
done
fs_say "ARTIFACTS"
sed 's/^/  /' "$ART/manifest.tsv" 2>/dev/null || true

FAILED=0

zoo() {
    local tag="$1" bin="$2"
    fs_say "ZOO $tag (samples=$ZOO_SAMPLES)"
    local rc=0
    fs_pinned python3 tools/perf/zoo/run_zoo_compare.py \
        --zjs "$ART/$bin" --qjs "$FS_QJS" --zoo "$FS_ZOO" \
        --samples "$ZOO_SAMPLES" --cpu "$FS_CPU" \
        --output "$OUT/zoo-$tag.json" > "$OUT/zoo-$tag.log" 2>&1 || rc=$?
    tail -20 "$OUT/zoo-$tag.log" | sed 's/^/  /'
    if [ "$rc" != 0 ]; then
        printf '  FAIL zoo %s rc=%s\n' "$tag" "$rc"
        [ "$rc" = 2 ] && printf '  (rc=2 is the runner REFUSING: it attests affinity, it does not set it)\n'
        FAILED=1
    fi
    # A refusal must not leave a hole a later join step reads as "not measured".
    if [ ! -s "$OUT/zoo-$tag.json" ]; then
        printf '  FAIL zoo %s produced no artifact\n' "$tag"; FAILED=1
    fi
    return 0
}

micro() {
    local tag="$1" a="$2" b="$3"
    fs_say "CODELOAD-MICRO $tag (a=$a b=$b samples=$MICRO_SAMPLES) [attribution instrument]"
    local rc=0
    fs_pinned python3 tools/perf/codeload/run_codeload_micro.py \
        --a "$ART/$a" --b "$ART/$b" --mode compile \
        --samples "$MICRO_SAMPLES" --cpu "$FS_CPU" \
        --output "$OUT/micro-$tag.json" > "$OUT/micro-$tag.log" 2>&1 || rc=$?
    tail -14 "$OUT/micro-$tag.log" | sed 's/^/  /'
    if [ "$rc" != 0 ]; then printf '  FAIL micro %s rc=%s\n' "$tag" "$rc"; FAILED=1; fi
    if [ ! -s "$OUT/micro-$tag.json" ]; then
        printf '  FAIL micro %s produced no artifact\n' "$tag"; FAILED=1
    fi
    return 0
}

# --- Stage 1: the gate itself, one balanced round over the full 15 ----------
zoo cand-b1   zjs-cand-b1
zoo legacy-a1 zjs-legacy-a1
# --- Stage 2: the two noise floors ------------------------------------------
zoo cand-b2   zjs-cand-b2
zoo legacy-a2 zjs-legacy-a2
# --- Stage 3: attribution instrument, all four pairings ---------------------
micro a1b1 zjs-legacy-a1 zjs-cand-b1
micro a1b2 zjs-legacy-a1 zjs-cand-b2
micro a2b1 zjs-legacy-a2 zjs-cand-b1
micro a2b2 zjs-legacy-a2 zjs-cand-b2

fs_say "JOIN"
python3 "$HERE/join_results.py" --perf "$OUT" --artifacts "$ART" \
    --output "$OUT/final-switch-summary.json" || FAILED=1

fs_say "performance FAILED=$FAILED"
exit "$FAILED"

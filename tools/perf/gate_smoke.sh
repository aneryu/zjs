#!/usr/bin/env bash
# Gate smoke: run the FIXED-WORK benchmark corpus, not only the ordinary form.
#
# The macro sweep runs each benchmark as shipped. The perf harness runs the
# fixed-work variants (doWarmup=false, doDeterministic=true), which reach heap
# states the ordinary form does not: on 2026-08-27 a morgue-bucketing change
# passed the macro sweep 9/9 and crashed the fixed-work regexp 6 runs out of 6.
# A gate that cannot see the states the measurements run in is not a gate.
#
# Usage: gate_smoke.sh [binary] [corpus] [cpu] [ordinary-runs] [expectations.json]
# ZJS_MEASURE_FIELD=a|b|host selects the default CPU when [cpu] is omitted;
# field B / CPU19 remains the default. Explicit [cpu] is retained for batch
# correctness sweeps and historical callers.
# The JSON schema and supported exact/range fields live in gate_smoke_check.py.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
FIELD="${ZJS_MEASURE_FIELD:-b}"
if ! FIELD_CPU=$(python3 "$SCRIPT_DIR/measure_fields.py" cpus --field "$FIELD" --layer single); then
    echo "fixed-work smoke: invalid ZJS_MEASURE_FIELD: $FIELD" >&2
    exit 2
fi
BIN="${1:-zig-out/bin/zjs}"
CORPUS="${2:-/tmp/gcgap-fixed}"
CPU="${3:-$FIELD_CPU}"
RUNS="${4:-3}"
EXPECTATIONS="${5:-}"
MAX_COMMITTED_LIVE_MILLI="${ZJS_GATE_MAX_COMMITTED_LIVE_MILLI:-32000}"

# The default binary is whatever happens to sit in zig-out, and this script does
# not build. On 2026-08-28 that produced a red gate against a binary three
# merges old: the failure it reported had already been fixed on the branch it
# was supposedly gating. A stale pass is the worse half of that -- it reads as
# "the merge is clean" when nothing of the merge was run. Refuse either way.
# Explicit artifacts are owned by the caller: the build graph checks its input
# dependencies, and frozen baselines may intentionally predate current sources.
# A tests-only edit can leave a valid cached production artifact's mtime intact.
if [[ -z "${1:-}" && -f "$BIN" ]]; then
    newest_src=$(find "$SCRIPT_DIR/../../src" "$SCRIPT_DIR/../../build.zig" \
        -newer "$BIN" -print -quit 2>/dev/null || true)
    if [[ -n "$newest_src" ]]; then
        echo "fixed-work smoke: $BIN is older than $newest_src" >&2
        echo "  rebuild first, or pass an explicit binary path as \$1" >&2
        exit 1
    fi
fi
CHECKER="$SCRIPT_DIR/gate_smoke_check.py"

if [[ ! -x "$BIN" ]]; then
    echo "fixed-work smoke: binary is not executable: $BIN" >&2
    exit 2
fi
# The corpus lives in /tmp by convention; a durable copy sits next to the
# frozen baselines (~/zjs-frozen/gcgap-fixed, 2026-09-06) so a reboot does
# not turn the merge gate red. Restore from it when the default is missing.
if [[ ! -d "$CORPUS" && "$CORPUS" == /tmp/gcgap-fixed && -d "$HOME/zjs-frozen/gcgap-fixed" ]]; then
    mkdir -p "$CORPUS" && cp "$HOME/zjs-frozen/gcgap-fixed"/*.js "$CORPUS"/
    echo "fixed-work smoke: restored $CORPUS from ~/zjs-frozen/gcgap-fixed" >&2
fi
if [[ ! -d "$CORPUS" ]]; then
    echo "fixed-work smoke: corpus directory does not exist: $CORPUS" >&2
    exit 2
fi
if [[ ! "$CPU" =~ ^[0-9]+([,-][0-9]+)*$ ]]; then
    echo "fixed-work smoke: invalid taskset CPU list: $CPU" >&2
    exit 2
fi
if [[ ! "$RUNS" =~ ^[1-9][0-9]*$ ]]; then
    echo "fixed-work smoke: RUNS must be a positive integer: $RUNS" >&2
    exit 2
fi
if [[ ! "$MAX_COMMITTED_LIVE_MILLI" =~ ^[1-9][0-9]*$ ]]; then
    echo "fixed-work smoke: ZJS_GATE_MAX_COMMITTED_LIVE_MILLI must be positive" >&2
    exit 2
fi
if [[ -n "$EXPECTATIONS" && ! -f "$EXPECTATIONS" ]]; then
    echo "fixed-work smoke: expectation file does not exist: $EXPECTATIONS" >&2
    exit 2
fi

# The checker's stats contract (exactly one retirement line plus endpoint and
# explicitly settled doomed state) belongs to the tracing collector. It
# survived an era when a second collector could occupy zig-out: on 2026-08-29 an rc rebuild produced a
# red gate whose message ("expected exactly one retirement line, found 0") read
# like a stats regression when the real problem was the wrong variant under
# test. The rc collector is gone, but the probe stays -- it is one `--gc-stats`
# run, and it also catches "you passed a stale or non-zjs binary as $1".
variant_probe=$(mktemp --suffix=.js)
echo "0;" > "$variant_probe"
variant_out=$(taskset -c "$CPU" "$BIN" --gc-gate-settle --gc-stats "$variant_probe" 2>/dev/null || true)
rm -f "$variant_probe"
if ! grep -q "^gc: endpoint doomed_pending" <<< "$variant_out" ||
   ! grep -q "^gc: settled doomed_pending" <<< "$variant_out"; then
    echo "fixed-work smoke: $BIN does not emit the collector stats lines this gate reads" >&2
    echo "  (expected a current zjs build; pass it explicitly as \$1)" >&2
    exit 2
fi

shopt -s nullglob
scripts=("$CORPUS"/*.js)
if (( ${#scripts[@]} == 0 )); then
    echo "fixed-work smoke: no .js files in corpus: $CORPUS" >&2
    exit 2
fi

outputs=$(mktemp -d)
trap 'rm -rf -- "$outputs"' EXIT

# One benchmark's full treatment: the ordinary runs, plus one deliberately
# expensive pass with the whole-heap arena/invariant audit and --gc-stats so
# the gate proves completion state, not merely exit status. The two halves
# are independent processes; parallel mode runs them concurrently (the
# earley-boyer chain, 22 s ordinary then 30 s audit, was the merge gate's
# tail until 2026-09-06), serial mode keeps the ordinary-then-audit order.
ordinary_runs() {
    local name="$1" js="$2" cpu="$3" run
    for ((run = 1; run <= RUNS; run += 1)); do
        if ! taskset -c "$cpu" "$BIN" "$js" >/dev/null 2>&1; then
            echo "FAIL $name ordinary run $run"
            return 1
        fi
    done
    return 0
}

audit_run() {
    local name="$1" js="$2" cpu="$3"
    if ! env ZJS_GC_ARENA_AUDIT=1 taskset -c "$cpu" \
        "$BIN" --gc-gate-settle --gc-stats "$js" >"$outputs/$name.stdout" 2>"$outputs/$name.stderr"; then
        echo "FAIL $name arena-audit stats run"
        tail -n 20 "$outputs/$name.stderr" >&2 || true
        return 1
    fi
    return 0
}

run_bench() {
    local name="$1" js="$2" cpu="$3"
    ordinary_runs "$name" "$js" "$cpu" || return 1
    audit_run "$name" "$js" "$cpu"
}

fail=0
if [[ -n "${ZJS_GATE_PARALLEL_CPUS:-}" ]]; then
    # Parallel mode: every run pinned to the whole CPU list (a taskset list,
    # ranges allowed), all benchmarks and both halves at once, the kernel
    # balances. This is a crash/invariant smoke, not a measurement --
    # shared-cache contention cannot fake a pass, and every per-benchmark
    # artifact is still written and checked. Serial remains the default; the
    # 2026-08-30 batch-gate accounting found the serial sweep dominating the
    # whole gate (~8 of ~12 minutes).
    if [[ ! "$ZJS_GATE_PARALLEL_CPUS" =~ ^[0-9]+([,-][0-9]+)*$ ]]; then
        echo "fixed-work smoke: ZJS_GATE_PARALLEL_CPUS must be a taskset CPU list" >&2
        exit 2
    fi
    pids=()
    for js in "${scripts[@]}"; do
        name=$(basename "$js" .js)
        ordinary_runs "$name" "$js" "$ZJS_GATE_PARALLEL_CPUS" &
        pids+=($!)
        audit_run "$name" "$js" "$ZJS_GATE_PARALLEL_CPUS" &
        pids+=($!)
    done
    for pid in "${pids[@]}"; do
        if ! wait "$pid"; then fail=$((fail + 1)); fi
    done
else
    for js in "${scripts[@]}"; do
        name=$(basename "$js" .js)
        if ! run_bench "$name" "$js" "$CPU"; then fail=$((fail + 1)); fi
    done
fi

if (( fail != 0 )); then
    echo "fixed-work smoke: $fail benchmark run(s) failed"
    exit 1
fi

checker_args=(
    --corpus "$CORPUS"
    --outputs "$outputs"
    --max-committed-live-milli "$MAX_COMMITTED_LIVE_MILLI"
)
if [[ -n "$EXPECTATIONS" ]]; then
    checker_args+=(--expectations "$EXPECTATIONS")
fi
python3 "$CHECKER" "${checker_args[@]}"

echo "fixed-work smoke: all clean ($RUNS ordinary + 1 arena-audit/stats run each)"

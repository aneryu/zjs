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
# The JSON schema and supported exact/range fields live in gate_smoke_check.py.
set -euo pipefail

BIN="${1:-zig-out/bin/zjs}"
CORPUS="${2:-/tmp/gcgap-fixed}"
CPU="${3:-0}"
RUNS="${4:-3}"
EXPECTATIONS="${5:-}"
MAX_COMMITTED_LIVE_MILLI="${ZJS_GATE_MAX_COMMITTED_LIVE_MILLI:-32000}"
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

# The default binary is whatever happens to sit in zig-out, and this script does
# not build. On 2026-08-28 that produced a red gate against a binary three
# merges old: the failure it reported had already been fixed on the branch it
# was supposedly gating. A stale pass is the worse half of that -- it reads as
# "the merge is clean" when nothing of the merge was run. Refuse either way.
if [[ -f "$BIN" ]]; then
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

# The checker's stats contract (exactly one retirement line, doomed_pending
# terminal state) only exists in trace_stw builds. The default binary is
# whatever sits in zig-out, which after an rc rebuild is an rc binary; on
# 2026-08-29 that produced a red gate whose message ("expected exactly one
# retirement line, found 0") reads like a stats regression when the actual
# problem is the wrong variant under test. Probe the variant before the
# corpus loop and refuse rc binaries by name.
variant_probe=$(mktemp --suffix=.js)
echo "0;" > "$variant_probe"
variant_out=$("$BIN" --gc-stats "$variant_probe" 2>/dev/null || true)
rm -f "$variant_probe"
if ! grep -q "^gc: terminal doomed_pending" <<< "$variant_out"; then
    echo "fixed-work smoke: $BIN is not a trace_stw build (no trace-only stats lines)" >&2
    echo "  this gate's stats contract only exists in trace builds;" >&2
    echo "  pass the trace binary explicitly as \$1" >&2
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
fail=0
for js in "${scripts[@]}"; do
    name=$(basename "$js" .js)
    for ((run = 1; run <= RUNS; run += 1)); do
        if ! taskset -c "$CPU" "$BIN" "$js" >/dev/null 2>&1; then
            echo "FAIL $name ordinary run $run"
            fail=$((fail + 1))
            break
        fi
    done

    # One additional full-corpus pass is deliberately expensive: it enables
    # the whole-heap arena/invariant audit and captures --gc-stats so the gate
    # proves completion state, not merely exit status.
    if ! env ZJS_GC_ARENA_AUDIT=1 taskset -c "$CPU" \
        "$BIN" --gc-stats "$js" >"$outputs/$name.stdout" 2>"$outputs/$name.stderr"; then
        echo "FAIL $name arena-audit stats run"
        tail -n 20 "$outputs/$name.stderr" >&2 || true
        fail=$((fail + 1))
    fi
done

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

#!/bin/bash
# P7-10 sampling harness.
#
# Emits one CSV row per run: binary,case,sample,instructions,cycles,task_clock_ns
#
# Discipline this encodes:
#   - Even sample count. An odd count under ABBA leaves the order unbalanced,
#     which has voided headline numbers twice in this campaign.
#   - Config order is reversed on even samples, so every config sees both a
#     warm-predecessor and a cold-predecessor position equally often.
#   - Pinned to CPU 19. This host is big.LITTLE with two PMUs; perf prints
#     "<not counted>" for the PMU the pinned core is not on, and those rows are
#     filtered rather than parsed.
#   - Caller is responsible for holding the exclusive host lock.
#
# Usage: sample.sh <samples> <binary-label>=<path> [<label>=<path> ...]
set -u
SAMPLES=$1; shift
CASE_DIR="$(cd "$(dirname "$0")/cases" && pwd)"
CASES=(read_toplevel read_local write_toplevel write_local binding_toplevel binding_local)

if [ $((SAMPLES % 2)) -ne 0 ]; then
    echo "sample count must be even (got $SAMPLES)" >&2
    exit 2
fi

BINS=("$@")

run_one() {
    local bin=$1 file=$2
    taskset -c 19 perf stat -x, -e instructions,cycles,task-clock "$bin" "$file" 2>&1 >/dev/null \
      | awk -F, '$1 != "<not counted>" && $1 != "" {
            if ($3 ~ /instructions/) ins=$1;
            else if ($3 ~ /cycles/) cyc=$1;
            else if ($3 == "task-clock") tc=$1
          } END { print ins "," cyc "," tc }'
}

for ((i = 1; i <= SAMPLES; i++)); do
    if [ $((i % 2)) -eq 1 ]; then
        order_bins=("${BINS[@]}"); order_cases=("${CASES[@]}")
    else
        order_bins=(); for ((j = ${#BINS[@]} - 1; j >= 0; j--)); do order_bins+=("${BINS[$j]}"); done
        order_cases=(); for ((j = ${#CASES[@]} - 1; j >= 0; j--)); do order_cases+=("${CASES[$j]}"); done
    fi
    for entry in "${order_bins[@]}"; do
        label=${entry%%=*}; path=${entry#*=}
        for c in "${order_cases[@]}"; do
            echo "$label,$c,$i,$(run_one "$path" "$CASE_DIR/$c.js")"
        done
    done
done

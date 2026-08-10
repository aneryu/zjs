#!/usr/bin/env bash
# Interleaved A/B pairs on a fixed-work source (default /tmp/rt-fixed-d64.js).
# Usage: rt_ab_pairs.sh <cand> <base> [pairs] [source]
# Emits CSV: bin,pair,instructions,cycles,task_clock
set -euo pipefail
CAND="${1:?cand}"; BASE="${2:?base}"; PAIRS="${3:-4}"; SRC="${4:-/tmp/rt-fixed-d64.js}"

run_one() {
    taskset -c 19 perf stat -x, -e instructions,cycles,task-clock "$1" "$SRC" 2>&1 >/dev/null \
      | awk -F, '$1 != "<not counted>" && $1 != "" {
            if ($3 ~ /instructions/) ins=$1;
            else if ($3 ~ /cycles/) cyc=$1;
            else if ($3 == "task-clock") tc=$1
          } END { print ins "," cyc "," tc }'
}

echo "bin,pair,instructions,cycles,task_clock"
for ((i = 1; i <= PAIRS; i++)); do
    if [ $((i % 2)) -eq 1 ]; then order="cand base"; else order="base cand"; fi
    for label in $order; do
        if [ "$label" = cand ]; then bin="$CAND"; else bin="$BASE"; fi
        echo "$label,$i,$(run_one "$bin")"
    done
done

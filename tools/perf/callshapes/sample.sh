#!/bin/bash
# Call-shape microbenchmark sampler (shapes A-J from the campaign brief).
#
# Emits one CSV row per run: binary,case,sample,instructions,cycles,task_clock_ns
#
# Same discipline as tools/perf/property/sample.sh:
#   - Even sample count. An odd count under ABBA leaves the order unbalanced.
#   - Binary and case order are reversed on even samples, so every config sees a
#     warm-predecessor and a cold-predecessor position equally often.
#   - Pinned to CPU 19 (Cortex-X925, 3900MHz). This host is big.LITTLE with two
#     PMUs; perf prints "<not counted>" for the PMU the pinned core is not on,
#     and those rows are filtered rather than parsed.
#
# Usage: sample.sh <samples> <label>=<path> [<label>=<path> ...]
set -u
SAMPLES=$1; shift
CASE_DIR="$(cd "$(dirname "$0")/cases" && pwd)"
CASES=(empty ctrl A_direct_call A2_direct_call_ret B_method_call \
       C_apply_array_literal C2_apply_array_hoisted D_apply_arguments \
       E0_arguments_zeroarg E1_arguments_length E2_arguments_index \
       E4_arguments_fourarg F_simple_ctor G_raytrace_ctor \
       H1_prop_read H2_prop_write I_proto_method J_instanceof \
       K1_length_array K2_length_plain \
       L0_ctor_noprops L3_ctor_threeprops M1_proto_data_read \
       L3p_ctor_shadowing M2_chain_read M3_poly_read \
       L4_generic_ctor L4p_generic_ctor_shadowing \
       W0_fresh_object W1_newprop_writes)

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

echo "binary,case,sample,instructions,cycles,task_clock_ns"
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

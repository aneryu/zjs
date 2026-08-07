#!/usr/bin/env bash
# ABBA paired benchmark for zjs call_method optimization.
#
# Usage: scripts/abba-bench.sh <binary_a> <binary_b> [test.js ...] [options]
#
# Runs N paired iterations in ABBA order (A,B,B,A) to cancel warm-up/cache
# asymmetry. Reports per-test median ratio B/A and a noise-floor note.
#
# Defaults: 8 pairs on pdfjs.js. Override test list by passing *.js paths.
# Override pair count with -n <N>.

set -euo pipefail

ZOO="${ZOO:-/Users/aneryu/javascript-zoo/bench}"
N=8
TESTS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -n) N="$2"; shift 2;;
        -*) echo "unknown option: $1" >&2; exit 2;;
        *)  break;;
    esac
done
BIN_A="$1"; shift
BIN_B="$1"; shift
# Remaining args are test files; default to pdfjs
if [[ $# -gt 0 ]]; then
    TESTS=("$@")
else
    TESTS=("$ZOO/pdfjs.js")
fi

[[ -x "$BIN_A" ]] || { echo "binary A not executable: $BIN_A" >&2; exit 2; }
[[ -x "$BIN_B" ]] || { echo "binary B not executable: $BIN_B" >&2; exit 2; }

extract_score() {
    # $1 = label (e.g. "PdfJS"), $2 = output file
    grep -oE "^${1}: [0-9]+(\.[0-9]+)?" "$2" | tail -1 | grep -oE "[0-9]+(\.[0-9]+)?"
}

get_score_keys() {
    # $1 = test script path. Pull the score label(s) the script prints.
    # Octane scripts print "<Name>: <score>" then "Score (version ...)".
    # We only want the per-benchmark score, not the aggregate.
    local script="$1"
    # Look for the benchmark name in the script's score-printing code.
    # Common pattern: print("PdfJS: " + score) or score_pretty("PdfJS")
    grep -oE '(print|console\.log)\("[A-Za-z0-9_]+: ?" ?\+' "$script" 2>/dev/null \
        | grep -oE '[A-Za-z0-9_]+' | grep -vE 'print|console|log' \
        | sort -u
    # Fallback: derive from filename
    if [[ -z "$(get_score_keys 2>/dev/null)" ]]; then
        basename "$script" .js | sed 's/^./\U&/'
    fi
}

run_once() {
    # $1 = binary, $2 = test.js, $3 = out file
    local bin="$1" test="$2" out="$3"
    "$bin" "$test" >"$out" 2>&1 || true
}

# Collect score keys per test
declare -A TEST_KEYS
for t in "${TESTS[@]}"; do
    base=$(basename "$t" .js)
    # Hardcode known Octane score labels for reliability
    case "$base" in
        pdfjs)        TEST_KEYS["$t"]="PdfJS";;
        richards)     TEST_KEYS["$t"]="Richards";;
        deltablue)    TEST_KEYS["$t"]="DeltaBlue";;
        crypto)       TEST_KEYS["$t"]="Crypto";;
        raytrace)     TEST_KEYS["$t"]="RayTrace";;
        earley-boyer) TEST_KEYS["$t"]="EarleyBoyer";;
        regexp)       TEST_KEYS["$t"]="RegExp";;
        splay)        TEST_KEYS["$t"]="Splay";;
        navier-stokes) TEST_KEYS["$t"]="NavierStokes";;
        mandreel)     TEST_KEYS["$t"]="Mandreel";;
        gbemu)        TEST_KEYS["$t"]="Gameboy";;
        code-load)    TEST_KEYS["$t"]="CodeLoad";;
        box2d)        TEST_KEYS["$t"]="Box2D";;
        *)            TEST_KEYS["$t"]=$(get_score_keys "$t" | head -1);;
    esac
done

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "ABBA paired benchmark: N=$N pairs"
echo "  A = $BIN_A"
echo "  B = $BIN_B"
echo "  tests = ${TESTS[*]}"
echo ""

# Collect samples: per test, per binary, list of scores
declare -A SCORES_A SCORES_B

for t in "${TESTS[@]}"; do
    key="${TEST_KEYS[$t]}"
    a_vals=()
    b_vals=()
    for ((i=0; i<N; i++)); do
        # ABBA order: pair i uses (A,B) then (B,A) interleaved across pairs
        # to cancel systematic position bias.
        if (( i % 2 == 0 )); then
            run_once "$BIN_A" "$t" "$TMP/a.out"
            run_once "$BIN_B" "$t" "$TMP/b.out"
        else
            run_once "$BIN_B" "$t" "$TMP/b.out"
            run_once "$BIN_A" "$t" "$TMP/a.out"
        fi
        sa=$(extract_score "$key" "$TMP/a.out")
        sb=$(extract_score "$key" "$TMP/b.out")
        if [[ -z "$sa" || -z "$sb" ]]; then
            echo "  [warn] $t pair $i: missing score (a=$sa b=$sb)" >&2
            continue
        fi
        a_vals+=("$sa")
        b_vals+=("$sb")
    done
    SCORES_A["$t"]="${a_vals[*]}"
    SCORES_B["$t"]="${b_vals[*]}"
done

# Report: per-test median ratio B/A, plus raw values
python3 - "$N" "${TESTS[@]}" <<'PYEOF'
import sys, statistics
N = int(sys.argv[1])
tests = sys.argv[2:]
# Read back from env-like parsing of the bash arrays via stdin not available;
# instead re-read the scores passed as trailing args is messy. We'll parse
# from a simpler mechanism: the bash side writes them to temp files.
PYEOF

# Simpler: compute median in bash via sort
median() {
    local arr=($1)
    local n=${#arr[@]}
    if (( n == 0 )); then echo "NaN"; return; fi
    local sorted=($(printf '%s\n' "${arr[@]}" | sort -n))
    local mid=$((n / 2))
    if (( n % 2 == 0 )); then
        echo "scale=3; (${sorted[$((mid-1))]} + ${sorted[$mid]}) / 2" | bc -l
    else
        echo "${sorted[$mid]}"
    fi
}

printf "%-20s %8s %8s %8s %8s %8s\n" "test" "A_med" "B_med" "B/A" "A_min" "A_max"
printf "%-20s %8s %8s %8s %8s %8s\n" "----" "-----" "-----" "---" "-----" "-----"
for t in "${TESTS[@]}"; do
    a_arr=(${SCORES_A[$t]})
    b_arr=(${SCORES_B[$t]})
    a_med=$(median "${a_arr[*]}")
    b_med=$(median "${b_arr[*]}")
    a_min=$(printf '%s\n' "${a_arr[@]}" | sort -n | head -1)
    a_max=$(printf '%s\n' "${a_arr[@]}" | sort -n | tail -1)
    if [[ "$a_med" == "NaN" || "$a_med" == "0" ]]; then
        ratio="NaN"
    else
        ratio=$(echo "scale=4; $b_med / $a_med" | bc -l)
    fi
    printf "%-20s %8s %8s %8s %8s %8s\n" "$(basename "$t" .js)" "$a_med" "$b_med" "$ratio" "$a_min" "$a_max"
done

echo ""
echo "Raw A samples:"
for t in "${TESTS[@]}"; do
    echo "  $(basename "$t" .js): ${SCORES_A[$t]}"
done
echo "Raw B samples:"
for t in "${TESTS[@]}"; do
    echo "  $(basename "$t" .js): ${SCORES_B[$t]}"
done

#!/usr/bin/env bash
# Paired A/B for one candidate build against a frozen baseline and qjs.
#
# Usage: ab.sh <candidate-bin> <baseline-bin> [qjs-bin] [samples]
#
# Runs all three binaries interleaved in ONE sampling session, then prints two
# tables: candidate-vs-baseline (did the change do anything?) and
# candidate-vs-qjs (how far is left?). Sampling all three together is the point
# — comparing across two separate sessions has produced 0.3-0.6% phantom drift
# on frozen binaries before.
#
# The baseline must be a COPY of the pre-change binary, not a path that a later
# `zig build` will overwrite.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CAND="${1:?candidate binary}"
BASE="${2:?baseline binary (must be a frozen copy)}"
QJS="${3:-/home/aneryu/quickjs/qjs}"
N="${4:-8}"

for b in "$CAND" "$BASE" "$QJS"; do
    [[ -x "$b" ]] || { echo "not executable: $b" >&2; exit 2; }
done
if [[ "$(realpath "$BASE")" == "$(realpath "$HERE/../../../zig-out/bin/zjs")" ]]; then
    echo "baseline points at zig-out/bin/zjs — copy it somewhere first" >&2
    exit 2
fi

CSV="$(mktemp /tmp/callshapes-ab-XXXXXX.csv)"
"$HERE/sample.sh" "$N" "cand=$CAND" "base=$BASE" "qjs=$QJS" > "$CSV"
echo "raw: $CSV"
echo

for pair in "cand base" "cand qjs"; do
    set -- $pair
    sub="$(mktemp /tmp/callshapes-pair-XXXXXX.csv)"
    head -1 "$CSV" > "$sub"
    grep -E "^($1|$2)," "$CSV" >> "$sub"
    echo "########## $1 vs $2   (ratio < 1.00 means $1 is cheaper)"
    python3 "$HERE/report.py" "$sub"
    echo
done

cat <<'EOF'
Reading the result:
  - ctrl / H1 / H2 / K1 are the control group. They should read 1.00 against the
    baseline. If one of them moved, you are looking at code layout, not at your
    change, and the headline number is not yours to claim.
  - Compare every delta against that case's own spread%. A delta smaller than
    the spread is noise, however good it looks.
  - An instruction win with no cycle win is the normal outcome for a constant
    tax; only allocation removal has reliably converted to time here.
EOF

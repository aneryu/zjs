#!/usr/bin/env bash
set -euo pipefail

if [ $# -ne 4 ]; then
    echo "Usage: $0 <sample-list> <dump-zjs-bytecode> <dump-quickjs-bytecode.sh> <diff-bc>" >&2
    exit 2
fi

sample_list="$1"
dump_zjs="$2"
dump_qjs="$3"
diff_bc="$4"

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/zjs-f10-parity.XXXXXX")"
cleanup() {
    rm -rf "$tmp_dir"
}
trap cleanup EXIT

total=0
passed=0
total_zjs_code_len=0
total_quickjs_code_len=0
total_instructions=0

while IFS= read -r script || [ -n "$script" ]; do
    case "$script" in
        ""|\#*) continue ;;
    esac

    total=$((total + 1))
    zjs_dump="$tmp_dir/$total.zjs.dump"
    qjs_dump="$tmp_dir/$total.qjs.dump"

    if ! "$dump_zjs" "$script" >"$zjs_dump"; then
        echo "FAIL $script (zjs dump failed)" >&2
        exit 1
    fi
    if ! "$dump_qjs" "$script" >"$qjs_dump"; then
        echo "FAIL $script (quickjs dump failed)" >&2
        exit 1
    fi
    diff_output="$("$diff_bc" --metrics "$zjs_dump" "$qjs_dump")" || {
        printf '%s\n' "$diff_output" >&2
        echo "FAIL $script (opcode sequence mismatch)" >&2
        exit 1
    }

    metrics="$(printf '%s\n' "$diff_output" | awk '
        /^METRIC / {
            for (i = 2; i <= NF; i++) {
                split($i, kv, "=")
                values[kv[1]] = kv[2]
            }
            print values["instructions"], values["zjs_code_len"], values["quickjs_code_len"]
        }
    ')"
    if [ -z "$metrics" ]; then
        echo "FAIL $script (missing bytecode metrics)" >&2
        exit 1
    fi
    read -r instructions zjs_code_len quickjs_code_len <<EOF_METRICS
$metrics
EOF_METRICS

    total_instructions=$((total_instructions + instructions))
    total_zjs_code_len=$((total_zjs_code_len + zjs_code_len))
    total_quickjs_code_len=$((total_quickjs_code_len + quickjs_code_len))

    passed=$((passed + 1))
    echo "ok   $script (instructions=$instructions, zjs_bytes=$zjs_code_len, quickjs_bytes=$quickjs_code_len)"
done < "$sample_list"

echo "F10 parity: $passed/$total opcode sequences matched"
echo "F10 bytecode size: zjs=$total_zjs_code_len bytes, quickjs=$total_quickjs_code_len bytes, instructions=$total_instructions"
if [ "$total_quickjs_code_len" -gt 0 ]; then
    awk -v z="$total_zjs_code_len" -v q="$total_quickjs_code_len" 'BEGIN {
        delta = z - q
        pct = (delta * 100.0) / q
        printf("F10 bytecode delta: %+d bytes (%+.2f%% vs QuickJS)\n", delta, pct)
    }'
fi

if [ "$total" -ne 50 ]; then
    echo "FAIL sample list must contain exactly 50 executable entries, found $total" >&2
    exit 1
fi

#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
quickjs="${QUICKJS_DIR:-/Users/aneryu/quickjs}"
javascript_zoo="${JAVASCRIPT_ZOO_DIR:-$repo/../javascript-zoo}"
out_dir="${TMPDIR:-/tmp}/zjs-regexp-direct-demo"
cases="$out_dir/regexp-direct-cases.tsv"
zig_csv="$out_dir/zig-regexp-direct-bench.csv"
quickjs_csv="$out_dir/quickjs-libregexp-direct-bench.csv"
compile_iterations="${REGEXP_DIRECT_COMPILE_ITERATIONS:-100}"
exec_iterations="${REGEXP_DIRECT_EXEC_ITERATIONS:-1000}"
warmup="${REGEXP_DIRECT_WARMUP:-20}"
zig_extra_phases="${REGEXP_DIRECT_ZIG_EXTRA_PHASES:-0}"

mkdir -p "$out_dir"

python3 "$repo/tools/regexp-direct-demo/extract_javascript_zoo_cases.py" \
  --source "$javascript_zoo/bench/regexp.js" \
  --output "$cases"

zig build-exe \
  -O ReleaseFast \
  -lc \
  "$repo/src/regexp_direct_bench.zig" \
  -femit-bin="$out_dir/zig-regexp-direct-bench"

cc -O3 -DNDEBUG \
  -I"$quickjs" \
  "$repo/tools/regexp-direct-demo/quickjs_libregexp_direct_bench.c" \
  "$quickjs/libregexp.c" \
  "$quickjs/libunicode.c" \
  "$quickjs/cutils.c" \
  -o "$out_dir/quickjs-libregexp-direct-bench"

"$out_dir/zig-regexp-direct-bench" "$cases" "$compile_iterations" "$exec_iterations" "$warmup" "$zig_extra_phases" > "$zig_csv"
"$out_dir/quickjs-libregexp-direct-bench" "$cases" "$compile_iterations" "$exec_iterations" "$warmup" > "$quickjs_csv"

cat "$zig_csv"
sed '1{/^engine,/d;}' "$quickjs_csv"

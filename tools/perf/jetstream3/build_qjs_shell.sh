#!/usr/bin/env bash
set -euo pipefail
script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
repo_root="$(CDPATH= cd -- "${script_dir}/../../.." && pwd)"
quickjs_dir="${QUICKJS_DIR:-${repo_root}/../quickjs}"
output="${QJS_SHELL_OUT:-${repo_root}/.zig-cache/perf/jetstream3/qjs-jetstream}"
mkdir -p "$(dirname -- "$output")"
"${CC:-cc}" -O2 -DNDEBUG -std=c11 -Wall -Wextra -Werror \
  -isystem "$quickjs_dir" "$script_dir/qjs_shell.c" \
  "$quickjs_dir/libquickjs.a" -Wl,--wrap=JS_ExecutePendingJob \
  -lm -lpthread -ldl -o "$output"
printf '%s\n' "$output"

#!/usr/bin/env bash
set -euo pipefail

script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
repo_root="$(CDPATH= cd -- "${script_dir}/../../.." && pwd)"
quickjs_dir="${QUICKJS_DIR:-${repo_root}/../quickjs}"
output="${QJS_HARNESS_OUT:-${repo_root}/.zig-cache/perf/qjs-align/same-runtime/qjs-same-runtime}"
cc="${CC:-cc}"

if [[ ! -f "${quickjs_dir}/quickjs.h" ]]; then
    echo "error: missing ${quickjs_dir}/quickjs.h" >&2
    exit 1
fi
if [[ ! -f "${quickjs_dir}/libquickjs.a" ]]; then
    echo "error: missing ${quickjs_dir}/libquickjs.a" >&2
    exit 1
fi

mkdir -p "$(dirname -- "${output}")"
qjs_harness_cflags=(
    -O2
    -DNDEBUG
    -std=c11
    -Wall
    -Wextra
    -Wno-unused-parameter
    -Werror
)
qjs_harness_ldflags=(-lm -lpthread)
case "$(uname -s)" in
    Darwin)
        # Defining _POSIX_C_SOURCE on Darwin hides the non-POSIX ru_maxrss
        # extension from <sys/resource.h>. The C harness uses that field for its
        # optional peak-RSS diagnostic, so compile against Darwin's default
        # feature set.
        ;;
    *)
        qjs_harness_cflags+=(-D_POSIX_C_SOURCE=200809L)
        qjs_harness_ldflags+=(-ldl)
        ;;
esac
qjs_harness_build_flags="${qjs_harness_cflags[*]} -I${quickjs_dir} ${quickjs_dir}/libquickjs.a ${qjs_harness_ldflags[*]}"
"${cc}" \
    "${qjs_harness_cflags[@]}" \
    "-DQJS_HARNESS_BUILD_FLAGS=\"${qjs_harness_build_flags}\"" \
    -I"${quickjs_dir}" \
    "${script_dir}/qjs_same_runtime.c" \
    "${quickjs_dir}/libquickjs.a" \
    "${qjs_harness_ldflags[@]}" \
    -o "${output}"

printf '%s\n' "${output}"

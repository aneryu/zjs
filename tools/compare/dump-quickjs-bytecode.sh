#!/bin/bash
# Wrapper script for dumping QuickJS bytecode
# Usage: ./dump-quickjs-bytecode.sh <script.js>

if [ $# -lt 1 ]; then
    echo "Usage: $0 <script.js>"
    exit 1
fi

SCRIPT="$1"

# Find qjs binary
QJS="${QJS:-quickjs/build/qjs}"
if [ ! -f "$QJS" ]; then
    QJS="build/qjs"
fi

if [ ! -f "$QJS" ]; then
    echo "Error: qjs not found. Set QJS environment variable or build quickjs."
    exit 1
fi

# Dump final bytecode using the QuickJS-ng dump flag interface. This local
# QuickJS does not expose the older --bytecode-dump flag; JS_DUMP_BYTECODE_FINAL
# is 0x01 in quickjs/quickjs.h.
#
# Some smoke programs intentionally exercise runtime TypeError paths after the
# bytecode has already been dumped. For the parity gate, the dump is the
# artifact under comparison, so keep a non-empty dump even if script execution
# exits non-zero.
set +e
ERR_FILE="$(mktemp "${TMPDIR:-/tmp}/qjs-dump-stderr.XXXXXX")"
OUTPUT="$(QJS_DUMP_FLAGS="${QJS_DUMP_FLAGS:-1}" "$QJS" "$SCRIPT" 2>"$ERR_FILE")"
STATUS=$?
ERR_OUTPUT="$(cat "$ERR_FILE")"
rm -f "$ERR_FILE"
set -e
printf '%s\n' "$OUTPUT"
if [ "$STATUS" -ne 0 ] && ! printf '%s\n' "$OUTPUT" | grep -q 'function:'; then
    printf '%s\n' "$ERR_OUTPUT" >&2
    exit "$STATUS"
fi

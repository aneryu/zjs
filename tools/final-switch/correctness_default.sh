#!/usr/bin/env bash
# FINAL SWITCH -- correctness on TRUE PRODUCTION DEFAULTS.
#
# No -Dzjs_v2_layout appears anywhere in this file. That
# is the whole point of it: Gate A's predecessor was green about a
# configuration it had never actually run, because every gate line carried an
# explicit flag and the *default* build was therefore never the thing tested.
# Variants live in correctness_variants.sh. Keeping them in separate files is
# what makes "the default path is green" a claim you can check by reading, not
# by auditing flags line by line.
#
# Usage: tools/final-switch/correctness_default.sh [--out DIR]

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
# shellcheck source=./preflight.sh
source "$HERE/preflight.sh"
fs_strict "correctness_default.sh"

OUT="$REPO/reports/perf/final-switch/correctness-default"
while [ $# -gt 0 ]; do
    case "$1" in
        --out) OUT="$2"; shift 2 ;;
        *) fs_die "unknown argument: $1" ;;
    esac
done
mkdir -p "$OUT"
cd "$REPO" || fs_die "cannot enter $REPO"
fs_preflight_build

FAILED=0
SUMMARY="$OUT/summary.tsv"
: > "$SUMMARY"

# Any -Dzjs_v2_layout reaching this file is a bug in this
# file, so refuse rather than run a mislabelled gate.
gate() {
    local label="$1"; shift
    for arg in "$@"; do
        case "$arg" in
            -Dzjs_v2_layout=*)
                fs_die "correctness_default.sh must not carry $arg (label=$label)" ;;
        esac
    done
    fs_say "GATE $label  cmd=[$*]"
    local rc=0
    fs_heavy "$@" > "$OUT/$label.log" 2>&1 || rc=$?
    local sigs
    sigs="$(grep -ohE 'zjs-config-[A-Za-z0-9]*:[A-Za-z0-9=,_]*' "$OUT/$label.log" 2>/dev/null | sort -u | tr '\n' ' ')"
    if [ "$rc" = 0 ]; then printf '  PASS %s\n' "$label"
    else printf '  FAIL %s (rc=%s)\n' "$label" "$rc"; FAILED=1
         tail -25 "$OUT/$label.log" | sed 's/^/  | /'
    fi
    printf '  SIG-SEEN: %s\n' "${sigs:-<none>}"
    printf '%s\t%s\t%s\n' "$label" "$rc" "${sigs:-<none>}" >> "$SUMMARY"
    grep -E '^Summary:|[0-9]+ passed' "$OUT/$label.log" 2>/dev/null | tail -3 | sed 's/^/  /'
    return 0
}

fs_provenance

fs_say "GATE fmt"
if fs_heavy "$FS_ZIG" fmt --check src build.zig tools docs > "$OUT/fmt.log" 2>&1; then
    printf '  PASS fmt\n'; printf 'fmt\t0\t-\n' >> "$SUMMARY"
else
    printf '  FAIL fmt (unformatted files below)\n'; FAILED=1
    sed 's/^/  | /' "$OUT/fmt.log"; printf 'fmt\t1\t-\n' >> "$SUMMARY"
fi

# --- the default artifact, and the evidence of what it actually is ----------
gate build-default "$FS_ZIG" build zjs
if [ -x zig-out/bin/zjs ]; then
    printf '  DEFAULT zjs signature: %s\n' "$(./zig-out/bin/zjs --print-config-signature 2>&1)"
    printf '  DEFAULT zjs sha256   : %s\n' "$(sha256sum zig-out/bin/zjs | cut -d' ' -f1)"
    printf '  DEFAULT zjs size     : %s\n' "$(stat -c %s zig-out/bin/zjs)"
fi
gate config-signature "$FS_ZIG" build config-signature-check
# Proves the attestation can still FAIL. An attestation that has never been
# observed failing is a comment.
gate config-drift     "$FS_ZIG" build config-drift-gate
gate architecture     "$FS_ZIG" build architecture-check
gate smoke            "$FS_ZIG" build smoke

# --- unit tests, defaults ---------------------------------------------------
gate test             "$FS_ZIG" build test --summary all
gate test-compiler-v2 "$FS_ZIG" build test-compiler-v2 --summary all
gate test-core        "$FS_ZIG" build test-core --summary all
gate test-parser      "$FS_ZIG" build test-parser --summary all
gate test-bytecode    "$FS_ZIG" build test-bytecode --summary all
gate test-exec        "$FS_ZIG" build test-exec --summary all
gate test-builtins    "$FS_ZIG" build test-builtins --summary all
gate test-runtime     "$FS_ZIG" build test-runtime --summary all
gate test-runner      "$FS_ZIG" build test-runner --summary all

# --- test262, defaults: the largest correctness surface --------------------
fs_say "GATE test262"
t262_rc=0
fs_heavy "$FS_ZIG" build test262-gate > "$OUT/test262.log" 2>&1 || t262_rc=$?
RESULT_LINE="$(grep -oE 'Result: [0-9]+/[0-9]+ errors, passed [0-9]+, known [0-9]+' "$OUT/test262.log" | tail -1)"
printf '  rc=%s\n  %s\n' "$t262_rc" "${RESULT_LINE:-<no Result line>}"
[ -n "$RESULT_LINE" ] || { printf '  FAIL test262 produced no Result line\n'; FAILED=1; }
[ "$t262_rc" = 0 ] || { printf '  FAIL test262\n'; FAILED=1; tail -25 "$OUT/test262.log" | sed 's/^/  | /'; }
printf 'test262\t%s\t%s\n' "$t262_rc" "${RESULT_LINE:-<none>}" >> "$SUMMARY"
# `run-test262` attests its effective configuration at COMPILE time
# (src/cli/run_test262.zig -> config_signature.attest), so the evidence that
# this sweep ran the intended backend is that the runner BUILT at all --
# there is no runtime signature to print, and printing its usage banner here
# and calling that evidence would be worse than saying so.
printf '  run-test262 configuration: attested at compile time; the build succeeding IS the attestation\n'
printf '  (expectation carried by this build: %s)\n' \
    "$(./zig-out/bin/zjs --print-config-signature 2>&1 | tr -d '\n')"

fs_say "correctness_default FAILED=$FAILED"
fs_finish "$FAILED"

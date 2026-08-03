#!/usr/bin/env bash
# FINAL SWITCH -- variant correctness gates.
#
# Every gate here carries a flag ON PURPOSE, and each one must PROVE it ran
# the variant it names. A variant gate that silently ran the default
# configuration is worse than not running it: it reports coverage it does not
# have.
#
# The proof is `-Dzjs_expect_config`, not a grep of stdout. Grepping was tried
# first and is not sound: the scoped test steps (`test-core`, `test-parser`,
# ...) print no runtime configuration signature at all, so "no signature seen"
# is indistinguishable from "wrong signature" and the check fires on gates that
# are in fact correct. `-Dzjs_expect_config` instead makes every engine-bearing
# artifact in the build graph assert its own effective configuration AT COMPILE
# TIME, and a mismatch is a build error naming the differing field:
#
#   error: zjs configuration drift: ... artifact: test-compiler-v2
#          expected: ...,force_gc=off,...   actual: ...,force_gc=on,...
#          differing fields: force_gc: expected off, actual on
#
# `assert_mechanism_can_fail` below runs one deliberately-wrong expectation and
# REQUIRES it to fail, so this run proves the assertion has teeth rather than
# assuming it.
#
# Usage: tools/final-switch/correctness_variants.sh [--out DIR]

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
# shellcheck source=./preflight.sh
source "$HERE/preflight.sh"
fs_strict "correctness_variants.sh"

OUT="$REPO/reports/perf/final-switch/correctness-variants"
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

# Signature shape, for readers building new expectations:
#   zjs-config-v2:compiler=,layout=,repr=,optimize=,force_gc=,ownership_audit=
# `optimize` is substituted per artifact (a Debug test binary is not evidence
# of drift for having been built Debug), so it is the one field an expectation
# cannot pin; every other field is asserted verbatim. The production defaults
# are `sig v2 short tagged <optimize> off off`; each gate below states its own
# single deviation from that.
sig() { printf 'zjs-config-v2:compiler=%s,layout=%s,repr=%s,optimize=%s,force_gc=%s,ownership_audit=%s' "$@"; }

# gate <label> <expect-signature|-> <cmd...>
gate() {
    local label="$1" expect="$2"; shift 2
    fs_say "GATE $label  expect=[$expect]  cmd=[$*]"
    local rc=0
    fs_heavy "$@" > "$OUT/$label.log" 2>&1 || rc=$?
    if [ "$rc" = 0 ]; then printf '  PASS %s\n' "$label"
    else printf '  FAIL %s (rc=%s)\n' "$label" "$rc"; FAILED=1
         tail -25 "$OUT/$label.log" | sed 's/^/  | /'
    fi
    local sigs
    sigs="$(grep -ohE 'zjs-config-[A-Za-z0-9]*:[A-Za-z0-9=,_]*' "$OUT/$label.log" 2>/dev/null | sort -u | tr '\n' ' ')"
    printf '  SIG-SEEN (informational): %s\n' "${sigs:-<none: this step prints no runtime signature>}"
    if [ "$expect" = "-" ]; then
        printf '  NOTE: no -Dzjs_expect_config for this gate (see comment at its call site)\n'
    fi
    printf '%s\t%s\t%s\t%s\n' "$label" "$rc" "$expect" "${sigs:-<none>}" >> "$SUMMARY"
    grep -E '^Summary:|[0-9]+ passed' "$OUT/$label.log" 2>/dev/null | tail -3 | sed 's/^/  /'
    return 0
}

# Prove, in this run, that a wrong expectation is rejected. Without this the
# gates below are only as good as the assumption that -Dzjs_expect_config does
# anything at all.
assert_mechanism_can_fail() {
    fs_say "SELF-CHECK: a wrong expectation must FAIL the build"
    local wrong; wrong="$(sig v2 short tagged Debug off off)"
    if fs_heavy "$FS_ZIG" build config-attest-build -Dzjs_force_gc=true \
        -Dzjs_expect_config="$wrong" > "$OUT/self-check.log" 2>&1
    then
        printf '  FAIL self-check: a deliberately wrong expectation BUILT.\n'
        printf '        -Dzjs_expect_config is not asserting anything; every gate below is hollow.\n'
        FAILED=1
        printf 'self-check\t1\tmechanism-did-not-fail\t-\n' >> "$SUMMARY"
    else
        printf '  PASS self-check (rejected, as required): %s\n' \
            "$(grep -oE 'differing fields:.*|[a-z_]+: expected [a-z_]+, actual [a-z_]+' "$OUT/self-check.log" | tail -1)"
        printf 'self-check\t0\tmechanism-fails-closed\t-\n' >> "$SUMMARY"
    fi
}

fs_provenance
assert_mechanism_can_fail

# --- variants whose configuration can be pinned end to end ------------------
# Force-GC makes every allocation a collection point: the sharpest lifetime
# oracle available, and the one that has caught real use-after-free.
gate force-gc-core    "$(sig v2 short tagged Debug on off)" \
    "$FS_ZIG" build test-core -Dzjs_force_gc=true \
    -Dzjs_expect_config="$(sig v2 short tagged Debug on off)" --summary all
gate force-gc-unified "$(sig v2 short tagged Debug on off)" \
    "$FS_ZIG" build test -Dzjs_force_gc=true \
    -Dzjs_expect_config="$(sig v2 short tagged Debug on off)" --summary all
gate ownership-audit  "$(sig v2 short tagged Debug off on)" \
    "$FS_ZIG" build test -Dzjs_ownership_audit=true \
    -Dzjs_expect_config="$(sig v2 short tagged Debug off on)" --summary all
# ReleaseSafe: the safety checks ReleaseFast compiles out. The unified suite
# FOLLOWS -Doptimize, so this is the one gate where the optimize field is
# actually asserted rather than substituted.
gate releasesafe      "$(sig v2 short tagged ReleaseSafe off off)" \
    "$FS_ZIG" build test -Doptimize=ReleaseSafe \
    -Dzjs_expect_config="$(sig v2 short tagged ReleaseSafe off off)" --summary all
# .plain is the A/B diagnostic instrument, REJECTED for production but kept
# reachable; this proves it still builds and still attests as .plain.
gate plain-smoke      "$(sig v2 plain tagged Debug off off)" \
    "$FS_ZIG" build test-compiler-v2 -Dzjs_v2_layout=plain \
    -Dzjs_expect_config="$(sig v2 plain tagged Debug off off)" --summary all

# --- variants that reconfigure themselves internally ------------------------
# `test-altrepr` builds the unified suite with the representation OPPOSITE the
# target default, and `test-oom` carries its own corpus engine module. Their
# effective configuration is therefore NOT the one this invocation requests, so
# a top-level -Dzjs_expect_config would assert the wrong thing and fail a
# correct gate. They are covered instead by the compile-time attestation the
# nested builds carry themselves.
gate altrepr - "$FS_ZIG" build test-altrepr
gate oom     - "$FS_ZIG" build test-oom --summary all

fs_say "correctness_variants FAILED=$FAILED"
fs_finish "$FAILED"

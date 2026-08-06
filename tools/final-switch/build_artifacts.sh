#!/usr/bin/env bash
# FINAL SWITCH -- build every measurement artifact ONCE, up front.
#
# Two cold builds per side, local cache wiped between them, so the formal
# protocol has independent layouts to pair across (measurement-contracts.md #4:
# a single build per side has twice produced a confident wrong conclusion).
# Correctness artifacts are deliberately NOT double-built: only the two
# performance sides need the pairing.
#
# Every artifact is recorded with its SHA-256 *and* its runtime configuration
# signature, because "which binary" and "what was that binary actually built
# as" are different questions and the second one is the one that went wrong.
#
# Usage:
#   tools/final-switch/build_artifacts.sh [--out DIR]
#
# POST-DELETION: the legacy production path is gone, so there is no baseline
# side to build. The manifest records that explicitly rather than leaving a
# reader to infer it from an absent row.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
# shellcheck source=./preflight.sh
source "$HERE/preflight.sh"
fs_strict "build_artifacts.sh"

OUT="$REPO/reports/perf/final-switch/artifacts"
while [ $# -gt 0 ]; do
    case "$1" in
        --out) OUT="$2"; shift 2 ;;
        *) fs_die "unknown argument: $1" ;;
    esac
done

mkdir -p "$OUT"
cd "$REPO" || fs_die "cannot enter $REPO"

fs_preflight_build

MANIFEST="$OUT/manifest.tsv"
: > "$MANIFEST"
printf 'name\tsha256\tsignature\tbuild_flags\n' >> "$MANIFEST"

build_one() {
    local name="$1"; shift
    fs_say "BUILD $name  flags=[$*]"
    # A genuine cold build: the cache is what makes two builds of the same
    # source land on the same layout, and the whole point of b1/b2 is that
    # they must not.
    rm -rf "$REPO/.zig-cache"
    if ! fs_heavy "$FS_ZIG" build zjs -Doptimize=ReleaseFast "$@" > "$OUT/build-$name.log" 2>&1; then
        fs_say "BUILD_FAIL $name"
        tail -25 "$OUT/build-$name.log" | sed 's/^/  | /'
        return 1
    fi
    cp "$REPO/zig-out/bin/zjs" "$OUT/zjs-$name" || return 1
    local sha sig
    sha="$(sha256sum "$OUT/zjs-$name" | cut -d' ' -f1)"
    sig="$("$OUT/zjs-$name" --print-config-signature 2>&1 | tr -d '\n')"
    [ -n "$sig" ] || fs_die "artifact $name printed no configuration signature"
    case "$sig" in
        zjs-config-*) : ;;
        *) fs_die "artifact $name signature is not a configuration signature: $sig" ;;
    esac
    fs_say "  sha256    = $sha"
    fs_say "  signature = $sig"
    printf '%s\t%s\t%s\t%s\n' "$name" "$sha" "$sig" "${*:-<defaults>}" >> "$MANIFEST"
}

rc=0
# Candidate = TRUE PRODUCTION DEFAULTS. No -Dzjs_v2_layout.
# A candidate built with an explicit flag is a scratch probe and is
# INTERMEDIATE by construction, however carefully it is then measured.
build_one cand-b1 || rc=1
build_one cand-b2 || rc=1
fs_say "NOTE: the legacy production path is deleted; there is no baseline side."
printf '%s\t%s\t%s\t%s\n' 'legacy-side' '-' '-' '<deleted: no legacy compiler>' >> "$MANIFEST"

fs_say "MANIFEST"
cat "$MANIFEST" | sed 's/^/  /'
fs_provenance | sed 's/^/  /'
fs_say "build_artifacts rc=$rc"
fs_finish "$rc"

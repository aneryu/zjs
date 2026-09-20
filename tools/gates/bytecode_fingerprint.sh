#!/usr/bin/env bash
# Parser identity gate: compile a corpus with two zjs binaries and compare the
# bytecode fingerprint (`zjs --bytecode-fingerprint`) line by line.
#
#   tools/gates/bytecode_fingerprint.sh <baseline-zjs> <candidate-zjs> [corpus-list]
#
# The corpus list is one source path per line; without one, every .js file
# under test262/test plus tests/fixtures is used. A differing line means the
# candidate emits different bytecode (or a different SyntaxError) for that
# file. Diagnostic-only differences must be justified in the change log.
set -euo pipefail
baseline=${1:?baseline zjs binary}
candidate=${2:?candidate zjs binary}
corpus=${3:-}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
if [[ -z "$corpus" ]]; then
  corpus="$work/corpus.txt"
  { find test262/test -name '*.js'; find tests/fixtures -name '*.js'; } | sort > "$corpus"
fi
run() {
  xargs -a "$corpus" -P "$(nproc)" -n 1 sh -c 'timeout 20 '"$1"' --bytecode-fingerprint "$0" 2>&1 | head -1 || echo "fail $0"' | sort -k2 > "$2"
}
run "$baseline" "$work/baseline.txt"
run "$candidate" "$work/candidate.txt"
if diff "$work/baseline.txt" "$work/candidate.txt" > "$work/diff.txt"; then
  echo "bytecode fingerprint: identical over $(wc -l < "$corpus") files"
else
  echo "bytecode fingerprint: $(grep -c '^>' "$work/diff.txt") files differ"
  cat "$work/diff.txt"
  exit 1
fi

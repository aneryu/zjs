#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: lint_anti_goals.sh [--cached] [--base REF]

Checks the current diff for performance-roadmap anti-goals:
  - no new tryFuse* fast paths in engine code without explicit review
  - no new anyerror in engine code
  - no new Runtime struct field additions
  - no unreviewed Object top-level field shape changes

By default this compares the working tree against HEAD. Use --cached for the
staged diff, or --base REF to compare against another commit/ref.
USAGE
}

diff_args=()
while (($#)); do
  case "$1" in
    --cached)
      diff_args+=(--cached)
      shift
      ;;
    --base)
      if [[ $# -lt 2 ]]; then
        echo "error: --base requires a ref" >&2
        exit 2
      fi
      diff_args+=("$2")
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

tmp_diff="$(mktemp)"
trap 'rm -f "$tmp_diff"' EXIT

git diff --unified=0 -- src/engine tools/perf "${diff_args[@]}" > "$tmp_diff"

status=0

try_fuse_matches="$(
  awk '
    /^\+\+\+ b\/src\/engine\// { in_engine = 1; next }
    /^\+\+\+ b\// { in_engine = 0 }
    in_engine && /^\+[^+]/ && $0 ~ /(^|[^A-Za-z0-9_])tryFuse[A-Za-z0-9_]*/ {
      print FNR ":" $0
    }
  ' "$tmp_diff"
)"

if [[ -n "$try_fuse_matches" ]]; then
  echo "anti-goal violation: new tryFuse fast path in engine code" >&2
  echo "$try_fuse_matches" >&2
  status=1
fi

anyerror_matches="$(
  awk '
    /^\+\+\+ b\/src\/engine\// { in_engine = 1; next }
    /^\+\+\+ b\// { in_engine = 0 }
    in_engine && /^\+[^+]/ && $0 ~ /(^|[^A-Za-z0-9_])anyerror([^A-Za-z0-9_]|$)/ {
      print FNR ":" $0
    }
  ' "$tmp_diff"
)"

if [[ -n "$anyerror_matches" ]]; then
  echo "anti-goal violation: new anyerror in engine code" >&2
  echo "$anyerror_matches" >&2
  status=1
fi

runtime_field_matches="$(
  awk '
    /^\+\+\+ b\/src\/engine\/core\/runtime\.zig$/ { in_runtime = 1; next }
    /^\+\+\+ b\// { in_runtime = 0 }
    in_runtime && /^\+[^+]/ && $0 ~ /^\+[[:space:]]+[A-Za-z_][A-Za-z0-9_]*:[[:space:]]/ {
      print FNR ":" $0
    }
  ' "$tmp_diff"
)"

if [[ -n "$runtime_field_matches" ]]; then
  echo "anti-goal violation: new Runtime struct field candidate" >&2
  echo "$runtime_field_matches" >&2
  status=1
fi

object_shape_errors="$(
  python3 - <<'PY'
from pathlib import Path
import re
import sys

expected = [
    "header",
    "class_id",
    "class_payload",
    "class_payload_kind",
    "shape_ref",
    "prototype",
    "null_prototype",
    "extensible",
    "is_array",
    "is_proxy",
    "is_global",
    "shared_lazy_native_functions",
    "global_lexical_env",
    "is_html_dda",
    "length",
    "length_writable",
    "is_with_environment",
    "properties",
    "property_capacity",
    "exotic",
]

path = Path("src/engine/core/object.zig")
try:
    lines = path.read_text().splitlines()
except OSError as err:
    print(f"unable to read {path}: {err}")
    sys.exit(0)

fields = []
in_object = False
for line in lines:
    stripped = line.strip()
    if not in_object:
        if stripped == "pub const Object = struct {":
            in_object = True
        continue
    if stripped.startswith("pub fn ") or stripped.startswith("fn "):
        break
    match = re.match(r"^([A-Za-z_][A-Za-z0-9_]*):\s", stripped)
    if match:
        fields.append(match.group(1))

if fields != expected:
    print("Object top-level field allowlist mismatch")
    missing = [name for name in expected if name not in fields]
    added = [name for name in fields if name not in expected]
    if missing:
        print("missing from current Object: " + ", ".join(missing))
    if added:
        print("new/unreviewed Object fields: " + ", ".join(added))
    if not missing and not added:
        print("field order changed")
PY
)"

if [[ -n "$object_shape_errors" ]]; then
  echo "anti-goal violation: Object top-level field allowlist changed" >&2
  echo "$object_shape_errors" >&2
  status=1
fi

exit "$status"

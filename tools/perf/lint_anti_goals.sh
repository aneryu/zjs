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

git diff --unified=0 -- src tools/perf "${diff_args[@]}" > "$tmp_diff"

status=0

try_fuse_matches="$(
  awk '
    /^\+\+\+ b\/src\/(builtins|bytecode|core|exec|libs|parser\.zig|root\.zig)/ { in_engine = 1; next }
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
    /^\+\+\+ b\/src\/(builtins|bytecode|core|exec|libs|parser\.zig|root\.zig)/ { in_engine = 1; next }
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

qjs_absent_matches="$(
  awk '
    /^\+\+\+ b\/src\/(builtins|bytecode|core|exec|libs|parser\.zig|root\.zig)/ { in_engine = 1; next }
    /^\+\+\+ b\// { in_engine = 0 }
    in_engine && /^\+[^+]/ && tolower($0) ~ /(zjs-only|zjs only).*(fast path|bypass|fastpath)|(fast path|bypass|fastpath).*(zjs-only|zjs only)|quickjs has no counterpart|qjs has no counterpart/ {
      print FNR ":" $0
    }
  ' "$tmp_diff"
)"

if [[ -n "$qjs_absent_matches" ]]; then
  echo "anti-goal violation: new QuickJS-absent fast path in engine code" >&2
  echo "  zjs is a faithful reimplementation: a specialization QuickJS does not" >&2
  echo "  have distorts the benchmarks that are supposed to price the generic" >&2
  echo "  route (see the constructSimpleFieldConstructor / L0-L3 precedent)." >&2
  echo "$qjs_absent_matches" >&2
  status=1
fi

runtime_field_matches="$(
  awk '
    /^\+\+\+ b\/src\/core\/runtime\.zig$/ { in_runtime = 1; next }
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
    # Mirrors qjs JSObject (quickjs.c:1017): an intrusive header, the weak
    # ref count, class_id, the packed flag word, the shape pointer, the
    # property value array and the class payload union. Update this list
    # only alongside a reviewed Object shape change -- it is the tripwire
    # for one landing unnoticed.
    "header",
    "weakref_count",
    "class_id",
    "flags",
    "shape_ref",
    "prop_values",
    "u",
]

path = Path("src/core/object.zig")
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
        if stripped in ("pub const Object = struct {", "pub const Object = extern struct {"):
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

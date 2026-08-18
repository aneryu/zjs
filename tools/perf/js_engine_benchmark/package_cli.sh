#!/usr/bin/env bash
# Pack a ReleaseFast zjs CLI for easy-install / js-engine-setup.
# Usage: package_cli.sh <zjs-binary> <rust-target-triple> <output-dir>
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: $0 <zjs-binary> <target-triple> <output-dir>" >&2
  exit 2
fi

src=$1
target=$2
out_dir=$3
mkdir -p "$out_dir"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

cp "$src" "$work/zjs"
if command -v strip >/dev/null 2>&1; then
  strip "$work/zjs" || true
fi
chmod 755 "$work/zjs"

archive="zjs-${target}.tar.gz"
if [[ "$target" == *windows* ]]; then
  mv "$work/zjs" "$work/zjs.exe"
  archive="zjs-${target}.zip"
  if command -v zip >/dev/null 2>&1; then
    (cd "$work" && zip -q "$archive" zjs.exe)
  else
    python3 - "$work" "$archive" <<'PY'
import sys, zipfile
from pathlib import Path
work = Path(sys.argv[1])
archive = sys.argv[2]
with zipfile.ZipFile(work / archive, "w", compression=zipfile.ZIP_DEFLATED) as zf:
    zf.write(work / "zjs.exe", "zjs.exe")
PY
  fi
else
  tar -C "$work" -czf "$work/$archive" zjs
fi

mv "$work/$archive" "$out_dir/$archive"
echo "$out_dir/$archive"

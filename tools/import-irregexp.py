#!/usr/bin/env python3
"""Import V8 Irregexp sources into vendor/irregexp/imported.

Rewrites V8 regexp includes to the vendored layout and strips headers that
the standalone shim replaces. Run from the repository root:

    python3 tools/import-irregexp.py --path /path/to/v8/src/regexp
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from pathlib import Path


NEED_SHIM = {
    "property-sequences.h",
    "regexp-ast.h",
    "regexp-bytecode-analysis.h",
    "regexp-bytecode-peephole.h",
    "regexp-bytecodes.h",
    "regexp-compiler.h",
    "regexp-dotprinter.h",
    "regexp-error.h",
    "regexp-flags.h",
    "regexp.h",
    "regexp-macro-assembler.h",
    "regexp-parser.h",
    "regexp-printer.h",
    "regexp-stack.h",
    "special-case.h",
    "regexp-nodes.h",
    "regexp-bytecode-generator.h",
    "regexp-interpreter.h",
    "regexp-code-generator.h",
}

COPY_EXCLUDED = {
    "DIR_METADATA",
    "OWNERS",
    "regexp.cc",
    "regexp-result-vector.cc",
    "regexp-result-vector.h",
    "regexp-utils.cc",
    "regexp-utils.h",
    "regexp-macro-assembler-arch.h",
    "gen-regexp-special-case.cc",
    "special-case.h",
}

# regexp headers we do not vendor; drop those includes instead of rewriting.
SKIP_REGEXP_INCLUDES = re.compile(
    r'#include "src/regexp/(?:regexp-(?:utils|result-vector)|regexp-macro-assembler-arch|special-case)\.h"'
)
REGEXP_INCLUDE = re.compile(r'#include "src/regexp/')
OTHER_INCLUDE = re.compile(r'#include "(src|include)/')


def copy_and_update_includes(src_path: Path, dst_path: Path) -> None:
    need_to_add_shim = src_path.name in NEED_SHIM
    adding_shim_now = False
    lines = src_path.read_text(encoding="utf-8", errors="replace").splitlines(True)
    out: list[str] = []
    for line in lines:
        if adding_shim_now:
            if line == "\n":
                out.append('#include "irregexp/RegExpShim.h"\n')
                need_to_add_shim = False
                adding_shim_now = False
        if SKIP_REGEXP_INCLUDES.search(line):
            if need_to_add_shim:
                adding_shim_now = True
            continue
        if REGEXP_INCLUDE.search(line):
            rewritten = line.replace(
                '#include "src/regexp/', '#include "irregexp/imported/'
            )
            out.append(rewritten)
            continue
        if OTHER_INCLUDE.search(line):
            if need_to_add_shim:
                adding_shim_now = True
            continue
        out.append(line)
    if need_to_add_shim:
        # Header had no foreign include gap; insert after the last include.
        inserted = False
        for i, line in enumerate(out):
            if line.startswith("#include"):
                last = i
        else:
            last = -1
        if last >= 0:
            out.insert(last + 1, '#include "irregexp/RegExpShim.h"\n')
            inserted = True
        if not inserted:
            out.insert(0, '#include "irregexp/RegExpShim.h"\n')
    if src_path.suffix == ".cc" and src_path.with_suffix(".h").exists():
        sibling = f'#include "irregexp/imported/{src_path.stem}.h"\n'
        if sibling not in out:
            # Some V8 .cc files only included their header via a stripped
            # non-regexp "src/..." line; keep the rewritten form so the TU
            # compiles standalone.
            insert_at = 0
            for i, line in enumerate(out):
                if line.startswith("#include"):
                    insert_at = i
                    break
            out.insert(insert_at, sibling)
    dst_path.write_text("".join(out), encoding="utf-8")


def import_from(srcdir: Path, dstdir: Path) -> None:
    imported = dstdir / "imported"
    imported.mkdir(parents=True, exist_ok=True)
    for stale in imported.iterdir():
        if stale.is_file():
            stale.unlink()
    for file in sorted(srcdir.iterdir()):
        if file.is_dir() or file.name in COPY_EXCLUDED:
            continue
        copy_and_update_includes(file, imported / file.name)


def main() -> int:
    parser = argparse.ArgumentParser(description="Import Irregexp from V8")
    parser.add_argument("-p", "--path", help="path to v8/src/regexp")
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[1]
    dst = repo / "vendor" / "irregexp"
    if args.path:
        src = Path(args.path)
    else:
        print("error: --path is required", file=sys.stderr)
        return 1
    if not (src / "regexp.h").exists():
        print(f"error: regexp.h not found in {src}", file=sys.stderr)
        return 1
    import_from(src, dst)
    head = subprocess.check_output(
        ["git", "-C", str(src.parent.parent if src.name == "regexp" else src), "rev-parse", "HEAD"],
        text=True,
    ).strip()
    (dst / "IRREGEXP_VERSION").write_text(head + "\n", encoding="utf-8")
    print(f"imported Irregexp from {src} @ {head} -> {dst / 'imported'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

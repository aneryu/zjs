#!/usr/bin/env python3
"""Audit zjs emitter opcode ids against the canonical QuickJS index map.

Reads `quickjs/quickjs-opcode.h` and `src/engine/bytecode/emitter.zig`
(specifically the legacy `pub const known = struct { ... };` block) and
classifies every emitter constant into one of three buckets:

- aligned: emitter name maps to the same index QuickJS assigns it
- mis_indexed: emitter name exists in QuickJS but with a different index
- bespoke: emitter name does not exist in QuickJS at all

The script writes a JSON report to `reports/opcode-alignment.json` and
prints a summary. Exits non-zero if invoked with `--check` and the
counts diverge from the baseline numbers recorded in
`docs/quickjs-redesign/PARSER_REWRITE_PLAN.md` (§2.5):

    aligned = 7, mis_indexed = 27, bespoke = 61
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from typing import Dict, List, Tuple

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
OPCODE_HEADER = os.path.join(REPO_ROOT, "quickjs", "quickjs-opcode.h")
EMITTER_ZIG = os.path.join(REPO_ROOT, "src", "engine", "bytecode", "emitter.zig")
REPORT_PATH = os.path.join(REPO_ROOT, "reports", "opcode-alignment.json")

# Baseline numbers from PARSER_REWRITE_PLAN.md §2.5 (revision 2, 2026-04-27).
BASELINE = {"aligned": 7, "mis_indexed": 27, "bespoke": 61}

DEF_RE = re.compile(r"^\s*(?:DEF|def)\(\s*([A-Za-z_][A-Za-z0-9_]*)\s*,")
KNOWN_BLOCK_RE = re.compile(
    r"pub const known\s*=\s*struct\s*\{(?P<body>.*?)\n\};",
    re.DOTALL,
)
KNOWN_ENTRY_RE = re.compile(
    r"pub const\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*u8\s*=\s*(\d+)\s*;"
)

# Emitter constants use slightly different names than QuickJS in a few cases
# (the constant is a Zig-friendly alias for the same opcode). These aliases
# are still considered "aligned" if their id matches the QuickJS index for
# the underlying opcode.
EMITTER_ALIASES: Dict[str, str] = {
    "undefined_value": "undefined",
    "null_value": "null",
    "bit_not": "not",
    "bit_and": "and",
    "bit_xor": "xor",
    "bit_or": "or",
    "typeof_value": "typeof",
}


def load_quickjs_index() -> Dict[str, int]:
    """Return {opcode_name: zero-based index} for every DEF/def in the header."""
    index: Dict[str, int] = {}
    next_idx = 0
    with open(OPCODE_HEADER, "r", encoding="utf-8") as fh:
        for line in fh:
            m = DEF_RE.match(line)
            if not m:
                continue
            index[m.group(1)] = next_idx
            next_idx += 1
    if "invalid" not in index:
        raise SystemExit(
            "opcode_align_check: failed to parse {}: 'invalid' opcode not found".format(
                OPCODE_HEADER
            )
        )
    return index


def load_emitter_constants() -> List[Tuple[str, int]]:
    with open(EMITTER_ZIG, "r", encoding="utf-8") as fh:
        text = fh.read()
    block = KNOWN_BLOCK_RE.search(text)
    if not block:
        # The known struct may already have been deleted (post F2). Treat as
        # an empty constants list so the audit reports zero of each class.
        return []
    return [
        (m.group(1), int(m.group(2)))
        for m in KNOWN_ENTRY_RE.finditer(block.group("body"))
    ]


def classify(
    emitter: List[Tuple[str, int]], qjs: Dict[str, int]
) -> Dict[str, List[Dict[str, object]]]:
    aligned: List[Dict[str, object]] = []
    mis_indexed: List[Dict[str, object]] = []
    bespoke: List[Dict[str, object]] = []
    for name, value in emitter:
        canonical = EMITTER_ALIASES.get(name, name)
        if canonical not in qjs:
            collision = next(
                (qjs_name for qjs_name, idx in qjs.items() if idx == value),
                None,
            )
            bespoke.append(
                {"name": name, "id": value, "collides_with": collision}
            )
            continue
        expected = qjs[canonical]
        if expected == value:
            aligned.append({"name": name, "id": value, "qjs_name": canonical})
        else:
            collision = next(
                (qjs_name for qjs_name, idx in qjs.items() if idx == value),
                None,
            )
            mis_indexed.append(
                {
                    "name": name,
                    "qjs_name": canonical,
                    "emitter_id": value,
                    "expected_id": expected,
                    "collides_with": collision,
                }
            )
    return {"aligned": aligned, "mis_indexed": mis_indexed, "bespoke": bespoke}


def write_report(buckets: Dict[str, List[Dict[str, object]]]) -> None:
    os.makedirs(os.path.dirname(REPORT_PATH), exist_ok=True)
    payload = {
        "summary": {
            "aligned": len(buckets["aligned"]),
            "mis_indexed": len(buckets["mis_indexed"]),
            "bespoke": len(buckets["bespoke"]),
            "total": sum(len(v) for v in buckets.values()),
        },
        "baseline": BASELINE,
        "aligned": sorted(buckets["aligned"], key=lambda e: e["id"]),
        "mis_indexed": sorted(buckets["mis_indexed"], key=lambda e: e["emitter_id"]),
        "bespoke": sorted(buckets["bespoke"], key=lambda e: e["id"]),
    }
    with open(REPORT_PATH, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, indent=2)
        fh.write("\n")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--check",
        action="store_true",
        help=(
            "Fail with non-zero exit if mis_indexed or bespoke counts exceed "
            "the recorded baseline (gate for CI)."
        ),
    )
    parser.add_argument(
        "--quiet",
        action="store_true",
        help="Only print summary line.",
    )
    args = parser.parse_args()

    qjs = load_quickjs_index()
    emitter = load_emitter_constants()
    buckets = classify(emitter, qjs)
    write_report(buckets)

    summary = {k: len(v) for k, v in buckets.items()}
    summary["total"] = sum(summary.values())
    print(
        "opcode-alignment: aligned={aligned} mis_indexed={mis_indexed} "
        "bespoke={bespoke} total={total} (baseline aligned={ba} "
        "mis_indexed={bm} bespoke={bb})".format(
            ba=BASELINE["aligned"],
            bm=BASELINE["mis_indexed"],
            bb=BASELINE["bespoke"],
            **summary,
        )
    )
    if not args.quiet:
        print("report: {}".format(os.path.relpath(REPORT_PATH, REPO_ROOT)))

    if args.check:
        if (
            summary["mis_indexed"] > BASELINE["mis_indexed"]
            or summary["bespoke"] > BASELINE["bespoke"]
        ):
            print(
                "opcode-alignment: regression — counts exceed baseline",
                file=sys.stderr,
            )
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

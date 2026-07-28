#!/usr/bin/env python3
"""Normalized per-symbol disassembly identity for two binaries.

Why this exists
---------------
Comparing binaries by file hash is too strict (build-id and other non-code
metadata differ freely) and comparing them by per-symbol instruction *count* is
too weak: two builds of this repository have been observed with 209 symbols at
differing counts and a further 1366 symbols at identical counts but different
bodies. Neither is an equivalence test.

The identity used here is, per symbol: presence, size, and a hash of the
normalized instruction body. Normalization removes only how an address is
*printed*; it never removes an opcode, a condition code, an immediate, a memory
displacement, or the identity of a branch/call target.

Usage
-----
    compare_symbol_disassembly.py identity <binary> [-o out.json]
    compare_symbol_disassembly.py compare <a.json|binary> <b.json|binary>

`compare` exits 0 when the two are code-identical, 1 when they differ, and 2 on
a usage or parse failure. Parsing is fail-closed: a disassembly line that does
not match the expected form aborts rather than being silently skipped.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Any

SYMBOL_HEADER = re.compile(r"^([0-9a-f]+) <(.+)>:$")
INSTRUCTION = re.compile(r"^\s+([0-9a-f]+):\s+((?:[0-9a-f]{2} ?)+)\t(.*)$")
BLANK_OR_NOISE = re.compile(
    r"^$|^Disassembly of section |^\S+:\s+file format |^\s*\.\.\.$"
)

# `bl 4a1234 <foo>` / `b.ne 4a1240 <bar+0x10>` -> keep the target identity,
# drop the absolute address that carries no semantic content.
TARGET_WITH_SYMBOL = re.compile(r"\b[0-9a-f]{2,}\s+<([^>]+)>")
# A bare code address with no symbol (intra-function branch). Rewritten
# relative to the referring instruction so branch distance is preserved.
BARE_ADDRESS = re.compile(r"(?<![\w.$])([0-9a-f]{4,})(?![\w.$])")


class ParseError(RuntimeError):
    """Raised when disassembly output does not match the expected form."""


def normalize_operands(text: str, instruction_address: int) -> str:
    """Strip address *representation* while preserving every semantic field."""
    text = text.split("//")[0].rstrip()
    text = TARGET_WITH_SYMBOL.sub(lambda m: f"<{m.group(1)}>", text)

    def rewrite_bare(match: re.Match[str]) -> str:
        target = int(match.group(1), 16)
        delta = target - instruction_address
        return f".{'+' if delta >= 0 else '-'}{abs(delta)}"

    return BARE_ADDRESS.sub(rewrite_bare, text)


def parse_disassembly(lines: list[str]) -> dict[str, list[str]]:
    """Parse `objdump -d` output into symbol -> normalized instruction bodies."""
    symbols: dict[str, list[str]] = {}
    current: str | None = None
    for line in lines:
        header = SYMBOL_HEADER.match(line)
        if header:
            current = header.group(2)
            symbols[current] = []
            continue
        instruction = INSTRUCTION.match(line)
        if instruction:
            if current is None:
                raise ParseError(f"instruction outside any symbol: {line!r}")
            address = int(instruction.group(1), 16)
            symbols[current].append(
                normalize_operands(instruction.group(3), address)
            )
            continue
        if BLANK_OR_NOISE.match(line):
            continue
        raise ParseError(f"unrecognized disassembly line: {line!r}")
    return symbols


def symbol_sizes(binary: Path) -> dict[str, int]:
    completed = subprocess.run(
        ["nm", "--print-size", "--radix=d", str(binary)],
        capture_output=True,
        text=True,
        check=False,
    )
    sizes: dict[str, int] = {}
    for line in completed.stdout.split("\n"):
        parts = line.split()
        if len(parts) >= 4 and parts[0].isdigit() and parts[1].isdigit():
            sizes[parts[3]] = int(parts[1])
    return sizes


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def text_sha256(binary: Path) -> str:
    completed = subprocess.run(
        ["objcopy", "-O", "binary", "--only-section=.text", str(binary), "/dev/stdout"],
        capture_output=True,
        check=False,
    )
    if completed.returncode != 0:
        return "unavailable"
    return hashlib.sha256(completed.stdout).hexdigest()


def identity(binary: Path) -> dict[str, Any]:
    completed = subprocess.run(
        ["objdump", "-d", "--section=.text", str(binary)],
        capture_output=True,
        text=True,
        check=True,
    )
    bodies = parse_disassembly(completed.stdout.split("\n"))
    sizes = symbol_sizes(binary)

    symbols: dict[str, dict[str, Any]] = {}
    for name, body in bodies.items():
        symbols[name] = {
            "present": True,
            "size": sizes.get(name),
            "instruction_count": len(body),
            "normalized_body_sha256": hashlib.sha256(
                "\n".join(body).encode()
            ).hexdigest(),
        }

    return {
        "binary": str(binary),
        "binary_sha256": sha256_file(binary),
        "text_sha256": text_sha256(binary),
        "global_normalized_signature": global_signature(symbols),
        "symbols": symbols,
    }


def global_signature(symbols: dict[str, dict[str, Any]]) -> str:
    """SHA256 over sorted (name, size, normalized body hash) triples."""
    digest = hashlib.sha256()
    for name in sorted(symbols):
        entry = symbols[name]
        digest.update(
            f"{name}\0{entry['size']}\0{entry['normalized_body_sha256']}\n".encode()
        )
    return digest.hexdigest()


def load_identity(argument: str) -> dict[str, Any]:
    path = Path(argument)
    if path.suffix == ".json":
        return json.loads(path.read_text(encoding="utf-8"))
    return identity(path)


def compare(left: dict[str, Any], right: dict[str, Any]) -> dict[str, Any]:
    a, b = left["symbols"], right["symbols"]
    shared = set(a) & set(b)
    body_changed = sorted(
        n for n in shared
        if a[n]["normalized_body_sha256"] != b[n]["normalized_body_sha256"]
    )
    size_changed = sorted(n for n in shared if a[n]["size"] != b[n]["size"])
    # Reported separately only as a triage aid. Equal counts prove nothing;
    # the body hash is the verdict.
    count_changed = sorted(
        n for n in shared
        if a[n]["instruction_count"] != b[n]["instruction_count"]
    )
    added = sorted(set(b) - set(a))
    removed = sorted(set(a) - set(b))
    return {
        "left_binary_sha256": left.get("binary_sha256"),
        "right_binary_sha256": right.get("binary_sha256"),
        "left_global_normalized_signature": left["global_normalized_signature"],
        "right_global_normalized_signature": right["global_normalized_signature"],
        "identical": not (added or removed or body_changed or size_changed),
        "symbol_count_left": len(a),
        "symbol_count_right": len(b),
        "added_symbols": added,
        "removed_symbols": removed,
        "body_changed_symbols": body_changed,
        "size_changed_symbols": size_changed,
        "instruction_count_changed_symbols": count_changed,
    }


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)

    ident = sub.add_parser("identity", help="emit the identity of one binary")
    ident.add_argument("binary")
    ident.add_argument("-o", "--output")

    comp = sub.add_parser("compare", help="compare two binaries or identities")
    comp.add_argument("left")
    comp.add_argument("right")
    comp.add_argument("-o", "--output")
    comp.add_argument(
        "--list-limit",
        type=int,
        default=20,
        help="how many changed symbol names to print (0 = all)",
    )

    args = parser.parse_args(argv)

    if args.command == "identity":
        result = identity(Path(args.binary))
        text = json.dumps(result, indent=1)
        if args.output:
            Path(args.output).write_text(text + "\n", encoding="utf-8")
            print(
                f"{args.binary}: {len(result['symbols'])} symbols, "
                f"signature {result['global_normalized_signature'][:16]}"
            )
        else:
            print(text)
        return 0

    result = compare(load_identity(args.left), load_identity(args.right))
    if args.output:
        Path(args.output).write_text(json.dumps(result, indent=1) + "\n", encoding="utf-8")

    print(f"identical: {result['identical']}")
    print(
        f"symbols: {result['symbol_count_left']} vs {result['symbol_count_right']}"
    )
    for key in (
        "added_symbols",
        "removed_symbols",
        "size_changed_symbols",
        "body_changed_symbols",
    ):
        names = result[key]
        if not names:
            continue
        print(f"{key}: {len(names)}")
        shown = names if args.list_limit == 0 else names[: args.list_limit]
        for name in shown:
            print(f"  {name}")
        if len(shown) < len(names):
            print(f"  ... and {len(names) - len(shown)} more")
    return 0 if result["identical"] else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except ParseError as error:
        print(f"compare_symbol_disassembly: {error}", file=sys.stderr)
        raise SystemExit(2)
    except (OSError, subprocess.CalledProcessError) as error:
        print(f"compare_symbol_disassembly: {error}", file=sys.stderr)
        raise SystemExit(2)

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
import struct
import subprocess
import sys
from pathlib import Path
from typing import Any

SYMBOL_HEADER = re.compile(r"^([0-9a-f]+) <(.+)>:$")
INSTRUCTION = re.compile(
    r"^\s*([0-9a-f]+):\s+((?:[0-9a-f]{2}[ ]?)+)[ ]*\t(.*)$"
)
BLANK_OR_NOISE = re.compile(
    r"^$|^Disassembly of section |^\S+:\s+file format |^\s*\.\.\.$"
)

# `bl 4a1234 <foo>` / `b.ne 4a1240 <bar+0x10>` -> keep the target identity,
# drop the absolute address that carries no semantic content.
TARGET_WITH_SYMBOL = re.compile(r"\b[0-9a-f]{2,}\s+<([^>]+)>")
# A bare code address with no symbol (intra-function branch). Rewritten
# relative to the referring instruction so branch distance is preserved.
BARE_ADDRESS = re.compile(r"(?<![\w.$])([0-9a-f]{4,})(?![\w.$])")

ELF_MAGIC = b"\x7fELF"
MACHO_LAYOUTS = {
    b"\xcf\xfa\xed\xfe": ("<", True),
    b"\xfe\xed\xfa\xcf": (">", True),
    b"\xce\xfa\xed\xfe": ("<", False),
    b"\xfe\xed\xfa\xce": (">", False),
}
FAT_MACHO_MAGICS = {
    b"\xca\xfe\xba\xbe",
    b"\xbe\xba\xfe\xca",
    b"\xca\xfe\xba\xbf",
    b"\xbf\xba\xfe\xca",
}
LC_SEGMENT = 0x1
LC_SEGMENT_64 = 0x19


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


def parse_disassembly(
    lines: list[str],
    encoded_sizes: dict[str, int] | None = None,
) -> dict[str, list[str]]:
    """Parse `objdump -d` output into symbol -> normalized instruction bodies."""
    symbols: dict[str, list[str]] = {}
    current: str | None = None
    for line in lines:
        header = SYMBOL_HEADER.match(line)
        if header:
            current = header.group(2)
            symbols[current] = []
            if encoded_sizes is not None:
                encoded_sizes[current] = 0
            continue
        instruction = INSTRUCTION.match(line)
        if instruction:
            if current is None:
                raise ParseError(f"instruction outside any symbol: {line!r}")
            address = int(instruction.group(1), 16)
            if encoded_sizes is not None:
                encoded_sizes[current] += len(
                    instruction.group(2).replace(" ", "")
                ) // 2
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


def binary_format(binary: Path) -> str:
    with binary.open("rb") as handle:
        magic = handle.read(4)
    if magic == ELF_MAGIC:
        return "elf"
    if magic in MACHO_LAYOUTS:
        return "mach-o"
    if magic in FAT_MACHO_MAGICS:
        raise ParseError(
            f"universal Mach-O binaries are unsupported: {binary}"
        )
    raise ParseError(f"unsupported binary format for {binary}")


def fixed_name(raw: bytes) -> str:
    return raw.split(b"\0", 1)[0].decode("ascii")


def macho_text_bytes(binary: Path) -> bytes:
    """Read the raw __TEXT,__text bytes from one thin Mach-O binary."""
    data = binary.read_bytes()
    layout = MACHO_LAYOUTS.get(data[:4])
    if layout is None:
        raise ParseError(f"not a supported thin Mach-O binary: {binary}")
    endian, is_64 = layout
    if is_64:
        header_format = endian + "IiiIIIII"
        segment_command = LC_SEGMENT_64
        segment_format = endian + "II16sQQQQiiII"
        section_format = endian + "16s16sQQIIIIIIII"
    else:
        header_format = endian + "IiiIIII"
        segment_command = LC_SEGMENT
        segment_format = endian + "II16sIIIIiiII"
        section_format = endian + "16s16sIIIIIIIII"

    header_size = struct.calcsize(header_format)
    if len(data) < header_size:
        raise ParseError(f"truncated Mach-O header: {binary}")
    header = struct.unpack_from(header_format, data)
    command_count = header[4]
    command_offset = header_size
    segment_size = struct.calcsize(segment_format)
    section_size = struct.calcsize(section_format)

    for _ in range(command_count):
        if command_offset + 8 > len(data):
            raise ParseError(f"truncated Mach-O load command: {binary}")
        command, command_size = struct.unpack_from(
            endian + "II", data, command_offset
        )
        command_end = command_offset + command_size
        if command_size < 8 or command_end > len(data):
            raise ParseError(f"invalid Mach-O load command size: {binary}")
        if command == segment_command:
            if command_size < segment_size:
                raise ParseError(f"truncated Mach-O segment command: {binary}")
            segment = struct.unpack_from(segment_format, data, command_offset)
            section_count = segment[9]
            section_offset = command_offset + segment_size
            if section_offset + section_count * section_size > command_end:
                raise ParseError(f"truncated Mach-O section table: {binary}")
            for index in range(section_count):
                section = struct.unpack_from(
                    section_format,
                    data,
                    section_offset + index * section_size,
                )
                if fixed_name(section[0]) != "__text":
                    continue
                if fixed_name(section[1]) != "__TEXT":
                    continue
                file_offset = section[4]
                byte_count = section[3]
                file_end = file_offset + byte_count
                if file_end > len(data):
                    raise ParseError(f"truncated Mach-O __text section: {binary}")
                return data[file_offset:file_end]
        command_offset = command_end
    raise ParseError(f"Mach-O __TEXT,__text section not found: {binary}")


def text_sha256(binary: Path, format_name: str | None = None) -> str:
    if format_name is None:
        format_name = binary_format(binary)
    if format_name == "mach-o":
        return hashlib.sha256(macho_text_bytes(binary)).hexdigest()

    completed = subprocess.run(
        ["objcopy", "-O", "binary", "--only-section=.text", str(binary), "/dev/stdout"],
        capture_output=True,
        check=False,
    )
    if completed.returncode != 0:
        return "unavailable"
    return hashlib.sha256(completed.stdout).hexdigest()


def identity(binary: Path) -> dict[str, Any]:
    format_name = binary_format(binary)
    section_name = "__text" if format_name == "mach-o" else ".text"
    completed = subprocess.run(
        ["objdump", "-d", f"--section={section_name}", str(binary)],
        capture_output=True,
        text=True,
        check=True,
    )
    encoded_sizes: dict[str, int] | None = (
        {} if format_name == "mach-o" else None
    )
    bodies = parse_disassembly(
        completed.stdout.split("\n"),
        encoded_sizes=encoded_sizes,
    )
    if not bodies:
        raise ParseError(
            f"disassembly produced no symbols from {section_name}: {binary}"
        )
    # Mach-O symbol tables do not carry ELF-style st_size values. LLVM nm
    # reports every size as zero, so use the exact encoded instruction bytes
    # already parsed above. ELF retains the existing strict nm path.
    sizes = encoded_sizes if encoded_sizes is not None else symbol_sizes(binary)

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
        "text_sha256": text_sha256(binary, format_name),
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

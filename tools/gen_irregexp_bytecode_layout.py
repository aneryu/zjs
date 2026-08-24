#!/usr/bin/env python3
"""Generate Zig operand-offset tables from V8 regexp-bytecodes.h packing rules."""

from __future__ import annotations

import re
from pathlib import Path

HEADER = Path("/workspace/vendor/irregexp/imported/regexp-bytecodes.h")
OUT = Path("/workspace/src/libs/irregexp_bytecode.zig")

K_BYTECODE_SIZE = 1  # sizeof(enum class Bytecode : uint8_t)
K_BYTECODE_ALIGNMENT = 4
K_TABLE_SIZE = 16

# (size, alignment) matching OperandTypeTraits in regexp-bytecodes-inl.h
TYPE_SIZE_ALIGN = {
    "Int16": (2, 2),
    "Int32": (4, 4),
    "Uint32": (4, 4),
    "Char": (2, 2),  # base::uc16
    "JumpTarget": (4, 4),
    "Offset": (2, 2),  # int16_t
    "BoundsCheckOffset": (4, 4),  # int32_t
    "Register": (2, 2),  # uint16_t
    "StackCheckFlag": (1, 1),  # enum class : uint8_t
    "StandardCharacterSet": (1, 1),  # enum class : char
    "BitTable": (16, 1),
}

READ_FN = {
    "Int16": "i16",
    "Int32": "i32",
    "Uint32": "u32",
    "Char": "u16",
    "JumpTarget": "u32",
    "Offset": "i16",
    "BoundsCheckOffset": "i32",
    "Register": "u16",
    "StackCheckFlag": "u8",
    "StandardCharacterSet": "u8",
    "BitTable": "table",
}


def round_up(x: int, align: int) -> int:
    return (x + align - 1) & ~(align - 1)


def packed_offsets(types: list[str]) -> tuple[list[int], int]:
    if not types:
        return [], round_up(K_BYTECODE_SIZE, K_BYTECODE_ALIGNMENT)
    offsets: list[int] = []
    offset = K_BYTECODE_SIZE
    for t in types:
        size, align = TYPE_SIZE_ALIGN[t]
        offset = round_up(offset, align)
        if (offset % K_BYTECODE_ALIGNMENT) + size > K_BYTECODE_ALIGNMENT:
            offset = round_up(offset, K_BYTECODE_ALIGNMENT)
        offsets.append(offset)
        offset += size
    packed = round_up(offsets[-1] + TYPE_SIZE_ALIGN[types[-1]][0], K_BYTECODE_ALIGNMENT)
    return offsets, packed


def to_snake(name: str) -> str:
    if name == "Break":
        return "break_"
    name = name.replace("LT", "Lt").replace("GT", "Gt").replace("GE", "Ge")
    return re.sub(r"(?<!^)(?=[A-Z])", "_", name).lower()


def parse_list(text: str) -> list[tuple[str, list[tuple[str, str]]]]:
    # Join continued macro lines, then find V(Name, (names), (types), (flags))
    # Strip // comments first so they don't hide commas.
    stripped = []
    for line in text.splitlines():
        if "//" in line:
            # keep preprocessor and macro content; comments are only after code
            code, _, comment = line.partition("//")
            if "/*" not in code:
                line = code.rstrip()
        stripped.append(line)
    blob = "\n".join(stripped)
    blob = re.sub(r"/\*.*?\*/", " ", blob, flags=re.S)
    # Extract V(...) invocations with balanced parens after V
    bytecodes: list[tuple[str, list[tuple[str, str]]]] = []
    i = 0
    while True:
        m = re.search(r"\bV\(", blob[i:])
        if not m:
            break
        start = i + m.end()
        depth = 1
        j = start
        while j < len(blob) and depth:
            if blob[j] == "(":
                depth += 1
            elif blob[j] == ")":
                depth -= 1
            j += 1
        inner = blob[start : j - 1]
        i = j
        # inner: CamelName, (names...), (types...), (flags...)
        name_m = re.match(r"\s*([A-Za-z][A-Za-z0-9]*)\s*,", inner)
        if not name_m:
            continue
        name = name_m.group(1)
        rest = inner[name_m.end() :]
        groups = split_top_tuples(rest)
        if len(groups) < 2:
            bytecodes.append((name, []))
            continue
        names_s, types_s = groups[0], groups[1]
        names_s = names_s.replace("\\", " ")
        types_s = types_s.replace("\\", " ")
        names = [re.sub(r"\s+", "", p) for p in names_s.split(",") if p.strip()]
        types = []
        for part in types_s.split(","):
            part = re.sub(r"\s+", "", part)
            if not part:
                continue
            tm = re.search(r"k([A-Za-z0-9]+)$", part)
            if not tm:
                raise SystemExit(f"bad type {part!r} in {name}")
            types.append(tm.group(1))
        if names_s.strip() == "" and types_s.strip() == "":
            bytecodes.append((name, []))
            continue
        if len(names) != len(types):
            raise SystemExit(f"name/type count mismatch in {name}: {names} vs {types}")
        bytecodes.append((name, list(zip(names, types))))
    return bytecodes


def split_top_tuples(s: str) -> list[str]:
    """Split ' (a, b), (T, U), (flags) ' into inner contents of each (...)."""
    out: list[str] = []
    depth = 0
    start = None
    for idx, ch in enumerate(s):
        if ch == "(":
            if depth == 0:
                start = idx + 1
            depth += 1
        elif ch == ")":
            depth -= 1
            if depth == 0 and start is not None:
                out.append(s[start:idx])
                start = None
    return out


def main() -> None:
    text = HEADER.read_text()
    start = text.index("#define INVALID_BYTECODE_LIST")
    end = text.index("#define REGEXP_BYTECODE_LIST")
    chunk = text[start:end]
    bcs = parse_list(chunk)
    assert bcs[0][0] == "Break", bcs[0]
    names = [n for n, _ in bcs]
    assert "SkipUntilOneOfMasked3" in names, names

    lines = [
        "// Generated by tools/gen_irregexp_bytecode_layout.py. Do not edit by hand.",
        "// Packing matches vendor/irregexp/imported/regexp-bytecodes-inl.h.",
        "const std = @import(\"std\");",
        "",
        "pub const table_size: usize = 16;",
        "pub const table_mask: u32 = 0x7f;",
        "pub const bytecode_alignment: usize = 4;",
        "",
        "pub const Opcode = enum(u8) {",
    ]
    for i, (name, _) in enumerate(bcs):
        field = "break_" if name == "Break" else to_snake(name)
        lines.append(f"    {field} = {i},")
    lines.append("};")
    lines.append("")
    lines.append(f"pub const opcode_count: usize = {len(bcs)};")
    lines.append("")
    lines.append("pub const opcode_size: [opcode_count]u8 = .{")
    for name, ops in bcs:
        types = [t for _, t in ops]
        _, size = packed_offsets(types)
        field = "break_" if name == "Break" else to_snake(name)
        lines.append(f"    {size}, // {name} / {field}")
    lines.append("};")
    lines.append("")
    lines.append("pub fn sizeOf(op: Opcode) u32 {")
    lines.append("    return opcode_size[@intFromEnum(op)];")
    lines.append("}")
    lines.append("")
    lines.append("pub const Off = struct {")
    for name, ops in bcs:
        if not ops:
            continue
        types = [t for _, t in ops]
        offsets, _ = packed_offsets(types)
        field = to_snake(name)
        lines.append(f"    pub const {field} = struct {{")
        for (oname, otype), off in zip(ops, offsets):
            zig_ty = READ_FN[otype]
            lines.append(f"        pub const {oname}: usize = {off}; // {otype} as {zig_ty}")
        lines.append("    };")
    lines.append("};")
    lines.append("")
    lines.append("test \"Irregexp bytecode sizes are 4-byte aligned\" {")
    lines.append("    for (opcode_size) |sz| {")
    lines.append("        try std.testing.expect(sz % 4 == 0);")
    lines.append("        try std.testing.expect(sz >= 4);")
    lines.append("    }")
    lines.append("}")
    lines.append("")

    OUT.write_text("\n".join(lines) + "\n")
    print(f"wrote {OUT} ({len(bcs)} opcodes)")
    for name, ops in bcs:
        types = [t for _, t in ops]
        _, size = packed_offsets(types)
        print(f"  {name:40s} size={size:3d} ops={len(ops)}")


if __name__ == "__main__":
    main()

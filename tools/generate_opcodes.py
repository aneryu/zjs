#!/usr/bin/env python3
"""
Generate Zig opcode constants from quickjs/quickjs-opcode.h.
Run this script when quickjs-opcode.h changes to regenerate the opcode table.
"""

import re
import sys

# Zig keywords that need to be escaped with @"keyword"
ZIG_KEYWORDS = {
    'return', 'const', 'var', 'fn', 'struct', 'enum', 'union', 'opaque',
    'if', 'else', 'switch', 'while', 'for', 'break', 'continue', 'defer',
    'errdefer', 'resume', 'try', 'catch', 'async', 'await', 'suspend',
    'nosuspend', 'usingnamespace', 'test', 'pub', 'export', 'extern',
    'inline', 'comptime', 'noinline', 'threadlocal', 'allowzero', 'anytype',
    'anyerror', 'error', 'fn', 'bool', 'f16', 'f32', 'f64', 'f128', 'i8',
    'i16', 'i32', 'i64', 'i128', 'isize', 'u8', 'u16', 'u32', 'u64', 'u128',
    'usize', 'c_short', 'c_ushort', 'c_int', 'c_uint', 'c_long', 'c_ulong',
    'c_longlong', 'c_ulonglong', 'c_longdouble', 'c_void', 'true', 'false',
    'null', 'undefined', 'type', 'anyframe', 'orelse', 'and', 'or', 'packed',
    'volatile', 'linksection', 'align', 'callconv', 'noalias', 'fn'
}

def escape_zig_identifier(name):
    """Escape Zig keywords and invalid identifiers."""
    if name in ZIG_KEYWORDS:
        return f'@"{name}"'
    return name

def main():
    # Read quickjs-opcode.h. QuickJS layout (see quickjs.c:1155):
    #   - All `DEF` entries get sequential ids 0..N-1 (OP_COUNT = N).
    #   - All `def` (temp) entries START at OP_nop + 1 and OVERLAP with the
    #     short opcodes that share the same id range. Temp ops are stripped
    #     before resolve_labels; short ops appear after. They never coexist
    #     in actual bytecode, so sharing the id space is sound.
    with open('quickjs/quickjs-opcode.h', 'r') as f:
        lines = f.readlines()

    # Each entry is (name, size, n_pop, n_push, format).
    defs = []   # regular DEF entries, sequential
    temps = []  # def (temp) entries, overlap with short DEFs starting at OP_nop+1
    nop_index = None
    row_re = re.compile(
        r'(DEF|def)\s*\(\s*(\w+)\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*(\w+)\s*\)'
    )
    for line in lines:
        # Use `match` (not `search`) so commented-out `//DEF(...)`
        # lines are ignored; the previous regex caught them and shifted
        # every subsequent opcode id by one.
        m = row_re.match(line.strip())
        if not m:
            continue
        macro, name, size, n_pop, n_push, fmt = m.groups()
        entry = (name, int(size), int(n_pop), int(n_push), fmt)
        if macro == 'DEF':
            if name == 'nop':
                nop_index = len(defs)
            defs.append(entry)
        else:
            temps.append(entry)

    if nop_index is None:
        raise SystemExit("ERROR: 'nop' opcode not found; cannot anchor OP_TEMP_START")

    temp_start = nop_index + 1

    # Generate Zig code
    zig_code = """// Auto-generated from quickjs/quickjs-opcode.h by tools/generate_opcodes.py.
// DO NOT EDIT — regenerate when quickjs-opcode.h changes.
//
// Layout mirrors QuickJS (`quickjs.c:1155`):
//   - DEF entries get sequential ids 0..OP_COUNT-1.
//   - def (temp) entries start at OP_nop+1 and OVERLAP with the short opcodes
//     that share the same id range. Temp ops are stripped before
//     resolve_labels; short ops appear afterwards. They never coexist in
//     emitted bytecode, so sharing the id space is sound.

pub const op = struct {
"""

    for idx, (name, *_rest) in enumerate(defs):
        escaped_name = escape_zig_identifier(name)
        zig_code += f"    pub const {escaped_name}: u8 = {idx};\n"

    zig_code += "\n    // Temporary opcodes (Phase 1 emit, Phase 2 erase). Ids overlap with\n"
    zig_code += "    // the short opcodes above; the parser/emitter must not mix them.\n"
    for idx, (name, *_rest) in enumerate(temps):
        escaped_name = escape_zig_identifier(name)
        zig_code += f"    pub const {escaped_name}: u8 = {temp_start + idx};\n"

    zig_code += f"\n    pub const op_count: u16 = {len(defs)};\n"
    zig_code += f"    pub const op_temp_start: u8 = {temp_start};\n"
    zig_code += f"    pub const op_temp_end: u8 = {temp_start + len(temps)};\n"

    zig_code += "};\n"

    # --- Baked opcode-size table ------------------------------------
    # `opcode_size[id]` is the total byte length (opcode + operands) of
    # the instruction at `id`. The 179..196 range is shared between the
    # temp opcodes and the short DEF opcodes (`quickjs.c:1155`). The
    # parser/pipeline mixes both within a single buffer (only 3 temp
    # opcodes — scope_get_var/scope_put_var/scope_get_var_undef — are
    # actually in flight pre-lowering, while the rest of the overlap
    # range is used as final-form short opcodes like push_empty_string).
    # We therefore populate the table with the *DEF* (final-form)
    # sizes; the pipeline special-cases the handful of temps it
    # actually consumes with hardcoded byte widths, so a temp opcode
    # never reaches `sizeOf`.
    size_table = [0] * 256
    format_table = ['none'] * 256
    for idx, (name, size, _np, _nh, fmt) in enumerate(defs):
        if idx < 256:
            size_table[idx] = size
            format_table[idx] = fmt

    zig_code += "\n// Total byte length (opcode + operands) indexed by opcode id.\n"
    zig_code += "// Driven from `quickjs-opcode.h` so the pipeline stays in sync\n"
    zig_code += "// without hand-maintained switches. Zero means no entry claims\n"
    zig_code += "// that id (callers should treat such bytes as pass-through).\n"
    zig_code += "pub const opcode_size: [256]u8 = .{\n"
    for row_start in range(0, 256, 16):
        row = ", ".join(str(v) for v in size_table[row_start:row_start + 16])
        zig_code += f"    {row},\n"
    zig_code += "};\n"

    # Deduplicated format enum (matches Format in opcode.zig).
    zig_code += "\n// Operand format tag indexed by opcode id. Values are the\n"
    zig_code += "// `bytecode.opcode.Format` enum names as written in\n"
    zig_code += "// quickjs-opcode.h. Callers convert via `std.meta.stringToEnum`.\n"
    zig_code += "pub const opcode_format_name: [256][]const u8 = .{\n"
    for row_start in range(0, 256, 8):
        row = ", ".join(f'"{v}"' for v in format_table[row_start:row_start + 8])
        zig_code += f"    {row},\n"
    zig_code += "};\n"

    # Opcode-name lookup table for tooling (bytecode dumper, debug
    # printers, error messages). Indexed by opcode id; ids that do not
    # correspond to any DEF entry get the literal string "?<id>" so a
    # caller can still print something meaningful.
    name_table = [None] * 256
    for idx, (name, _sz, _np, _nh, _fmt) in enumerate(defs):
        if idx < 256:
            name_table[idx] = name
    zig_code += "\n// Opcode name lookup indexed by opcode id. Slots without a\n"
    zig_code += "// DEF entry contain an empty string; callers should treat\n"
    zig_code += "// `opcode_name[id].len == 0` as 'unknown opcode'.\n"
    zig_code += "pub const opcode_name: [256][]const u8 = .{\n"
    for row_start in range(0, 256, 4):
        row_items = []
        for v in name_table[row_start:row_start + 4]:
            row_items.append(f'"{v}"' if v is not None else '""')
        zig_code += "    " + ", ".join(row_items) + ",\n"
    zig_code += "};\n"

    # Write to stdout
    print(zig_code)

if __name__ == '__main__':
    main()
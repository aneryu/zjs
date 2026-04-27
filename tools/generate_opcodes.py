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

    defs = []  # regular DEF entries, sequential
    temps = []  # def (temp) entries, overlap with short DEFs starting at OP_nop+1
    nop_index = None
    for line in lines:
        line = line.strip()
        m_def = re.match(r'DEF\s*\(\s*(\w+)', line)
        if m_def:
            name = m_def.group(1)
            if name == 'nop':
                nop_index = len(defs)
            defs.append(name)
            continue
        m_temp = re.match(r'def\s*\(\s*(\w+)', line)
        if m_temp:
            temps.append(m_temp.group(1))

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

    for idx, name in enumerate(defs):
        escaped_name = escape_zig_identifier(name)
        zig_code += f"    pub const {escaped_name}: u8 = {idx};\n"

    zig_code += "\n    // Temporary opcodes (Phase 1 emit, Phase 2 erase). Ids overlap with\n"
    zig_code += "    // the short opcodes above; the parser/emitter must not mix them.\n"
    for idx, name in enumerate(temps):
        escaped_name = escape_zig_identifier(name)
        zig_code += f"    pub const {escaped_name}: u8 = {temp_start + idx};\n"

    zig_code += f"\n    pub const op_count: u16 = {len(defs)};\n"
    zig_code += f"    pub const op_temp_start: u8 = {temp_start};\n"
    zig_code += f"    pub const op_temp_end: u8 = {temp_start + len(temps)};\n"

    zig_code += "};\n"

    # Write to stdout
    print(zig_code)

if __name__ == '__main__':
    main()
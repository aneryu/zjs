//! Phase 3a: resolve_labels
//!
//! Mirrors `resolve_labels` at `quickjs.c:34197`.
//!
//! This phase injects function prologue, rewrites absolute jumps to
//! relative forms, and selects short-form opcodes.

const std = @import("std");
const atom = @import("../../core/atom.zig");
const memory = @import("../../core/memory.zig");
const bytecode_function = @import("../function.zig");
const opcode = @import("../opcode.zig");

pub const Error = error{
    InvalidBytecode,
};

/// Context for label resolution.
pub const Context = struct {
    function: *bytecode_function.Bytecode,
    memory: *memory.MemoryAccount,
    atoms: *atom.AtomTable,

    pub fn init(function: *bytecode_function.Bytecode) Context {
        return .{
            .function = function,
            .memory = function.memory,
            .atoms = function.atoms,
        };
    }
};

/// Run Phase 3a label resolution on a function.
///
/// Input: a Bytecode with Phase 2 output (no temp opcodes except label).
/// Output: the same Bytecode with label opcodes dropped.
///
/// This simplified implementation:
/// - Drops OP_label opcodes (5 bytes: opcode + label:u32)
/// - Preserves all other opcodes
///
/// Full QuickJS alignment (prologue, jump rewriting, short-form selection,
/// coalescing) will be added when FunctionDef is integrated into the parser.
/// Total byte length (opcode + operands) for `op_id`. Driven by the
/// comptime-baked `opcode.opcode_size` table so every opcode in
/// `quickjs-opcode.h` is recognised. Unknown ids fall back to 1 to
/// keep the walker progressing.
fn instrSize(op_id: u8) usize {
    const total = opcode.sizeOf(op_id);
    return if (total == 0) 1 else total;
}

pub fn run(ctx: *Context) !void {
    const func = ctx.function;

    // First pass: compute output size. OP_label (5 bytes: opcode +
    // label:u32) is dropped; every other opcode copies through at
    // its table-reported size.
    var output_size: usize = 0;
    var i: usize = 0;
    while (i < func.code.len) {
        const op = func.code[i];
        if (op == opcode.op.label) {
            i += 5;
        } else {
            const size = instrSize(op);
            output_size += size;
            i += size;
        }
    }

    // Allocate output buffer. Skip zero-sized allocations (see
    // `resolve_variables.run` for the leak-avoidance rationale).
    const output: []u8 = if (output_size == 0)
        &.{}
    else
        try ctx.memory.alloc(u8, output_size);
    errdefer if (output.len != 0) ctx.memory.free(u8, output);

    // Second pass: copy (dropping labels).
    var out_idx: usize = 0;
    i = 0;
    while (i < func.code.len) {
        const op = func.code[i];
        if (op == opcode.op.label) {
            i += 5;
        } else {
            const size = instrSize(op);
            if (i + size > func.code.len) return error.InvalidBytecode;
            @memcpy(output[out_idx .. out_idx + size], func.code[i .. i + size]);
            out_idx += size;
            i += size;
        }
    }

    // Replace the old code.
    if (func.code.len != 0) ctx.memory.free(u8, func.code);
    func.code = output[0..out_idx];
}
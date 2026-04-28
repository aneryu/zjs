//! Phase 2: resolve_variables
//!
//! Mirrors `resolve_variables` at `quickjs.c:33622`.
//!
//! This phase walks the lexical chain, resolves variable references,
//! and replaces Phase 1 temporary opcodes with their final forms.

const std = @import("std");
const atom = @import("../../core/atom.zig");
const memory = @import("../../core/memory.zig");
const bytecode_function = @import("../function.zig");
const opcode = @import("../opcode.zig");
const scope = @import("../scope.zig");

pub const Error = error{
    InvalidBytecode,
};

/// Context for variable resolution.
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

/// Run Phase 2 variable resolution on a function.
///
/// Input: a Bytecode whose code contains Phase-1 temporary opcodes only.
/// Output: the same Bytecode with temporary opcodes replaced by final forms.
///
/// This implementation:
/// - Linear scan over byte_code
/// - Replaces scope_get_var → get_var
/// - Replaces scope_put_var → put_var
/// - Replaces scope_get_var_undef → get_var_undef
/// - Drops enter_scope/leave_scope
///
/// Full QuickJS alignment (closure variables, TDZ, eval) will be added
/// when FunctionDef is integrated into the parser.
/// Total byte length (opcode + operands) for `op_id`, driven by the
/// comptime-baked `opcode.opcode_size` table. Returns 1 for ids with
/// no table entry so callers can safely fall through unknown opcodes
/// one byte at a time (matching QuickJS's unknown-op pass-through).
fn instrSize(op_id: u8) usize {
    const total = opcode.sizeOf(op_id);
    return if (total == 0) 1 else total;
}

/// Returns true if the opcode at `op_id` is a Phase 1 temporary
/// variable-scope opcode that `resolve_variables` needs to lower.
fn isScopeVarOp(op_id: u8) bool {
    return op_id == opcode.op.scope_get_var or
        op_id == opcode.op.scope_put_var or
        op_id == opcode.op.scope_get_var_undef;
}

/// Maps a scope_* var opcode to its final-form counterpart. Callers
/// must have verified the input is a known scope-var opcode.
fn lowerScopeVarOp(op_id: u8) u8 {
    return switch (op_id) {
        opcode.op.scope_get_var => opcode.op.get_var,
        opcode.op.scope_put_var => opcode.op.put_var,
        opcode.op.scope_get_var_undef => opcode.op.get_var_undef,
        else => unreachable,
    };
}

/// Returns true if `op_id`'s table format carries a leading atom
/// operand at `bytes[1..5]`. Used to track the atom-operand list in
/// lockstep with bytecode rewriting.
fn hasAtomOperand(op_id: u8) bool {
    const fmt = opcode.formatOf(op_id);
    return fmt == .atom or fmt == .atom_u8 or fmt == .atom_u16 or
        fmt == .atom_label_u8 or fmt == .atom_label_u16;
}

/// Describes the location and kind of an absolute label operand
/// embedded in the output bytecode. The parser emits jump targets as
/// absolute u32 byte offsets (`emitForwardJump` / `emitBackwardJump`);
/// when `resolve_variables` shrinks opcodes that precede those
/// targets, the stored absolute values go stale. We collect each
/// jump's operand position here during the main walk, then rewrite
/// the targets at the end using the old→new pc map.
const JumpSite = struct {
    /// Byte offset within the *output* buffer where the u32 target
    /// operand begins. Always points to a 4-byte little-endian field.
    operand_pos: usize,
};

/// Returns the byte offset within this opcode of the absolute u32
/// label operand, or `null` if the format has no such operand. Only
/// the `.label` format (u32 absolute target) is relevant for the
/// interim pipeline — the parser does not yet emit label8 / label16
/// short forms.
fn labelOperandOffset(op_id: u8) ?usize {
    const fmt = opcode.formatOf(op_id);
    return switch (fmt) {
        .label => 1, // u32 target at bytes[1..5]
        else => null,
    };
}

pub fn run(ctx: *Context) !void {
    const func = ctx.function;

    // First pass: compute output size (in bytes) and atom count.
    // Phase 1 scope-var opcodes shrink from 7 bytes to 5 bytes. The
    // enter_scope / leave_scope pair (3 bytes each) is dropped. All
    // other opcodes copy through at their table-reported size.
    //
    // We also count the number of jump opcodes (format `.label`) so
    // we can size the pc-map and the jump-site list ahead of the
    // second pass.
    var output_size: usize = 0;
    var output_atom_count: usize = 0;
    var jump_count: usize = 0;
    var i: usize = 0;
    while (i < func.code.len) {
        const op = func.code[i];
        if (isScopeVarOp(op)) {
            output_size += 5;
            output_atom_count += 1;
            i += 7;
        } else if (op == opcode.op.enter_scope or op == opcode.op.leave_scope) {
            i += 3;
        } else {
            const size = instrSize(op);
            output_size += size;
            if (hasAtomOperand(op)) output_atom_count += 1;
            if (labelOperandOffset(op) != null) jump_count += 1;
            i += size;
        }
    }

    // Allocate output buffers. Skip zero-sized allocations because
    // `MemoryAccount.alloc(_, 0)` still bumps the allocation counter,
    // while `Bytecode.deinit` skips `free` for empty slices — together
    // that would manifest as a false-positive leak.
    const output: []u8 = if (output_size == 0)
        &.{}
    else
        try ctx.memory.alloc(u8, output_size);
    errdefer if (output.len != 0) ctx.memory.free(u8, output);
    const output_atoms: []atom.Atom = if (output_atom_count == 0)
        &.{}
    else
        try ctx.memory.alloc(atom.Atom, output_atom_count);
    errdefer if (output_atoms.len != 0) ctx.memory.free(atom.Atom, output_atoms);

    // Scratch arrays for pc-map and jump sites (use raw allocator so
    // we don't pollute the MemoryAccount counters; these are freed
    // before `run` returns).
    const allocator = ctx.memory.allocator;
    // `pc_map[old_pc + 1]` holds the new pc that the instruction
    // previously at `old_pc` now starts at. Entry `pc_map[0]` is
    // unused (0 maps to 0 trivially). Dropped instructions (the
    // enter/leave scope pair) map their old pc to the new pc of the
    // *next* kept instruction, so a jump that targets them still
    // lands on a valid instruction boundary.
    const pc_map = try allocator.alloc(usize, func.code.len + 1);
    defer allocator.free(pc_map);
    @memset(pc_map, 0);
    const jump_sites = try allocator.alloc(JumpSite, jump_count);
    defer allocator.free(jump_sites);

    // Second pass: walk input + atom_operands in lockstep. Every
    // opcode with an atom format consumes one entry from the input
    // `func.atom_operands` list; we re-retain it for `output_atoms`
    // so refcounts stay balanced. Jump operand sites are recorded
    // into `jump_sites` for post-pass patching.
    var out_idx: usize = 0;
    var out_atom_idx: usize = 0;
    var in_atom_idx: usize = 0;
    var out_jump_idx: usize = 0;
    i = 0;

    while (i < func.code.len) {
        pc_map[i] = out_idx;
        const op = func.code[i];
        if (isScopeVarOp(op)) {
            if (i + 7 > func.code.len) return error.InvalidBytecode;
            const atom_id = std.mem.readInt(u32, func.code[i + 1 ..][0..4], .little);
            // scope_level at func.code[i+5..i+7] is unused in the
            // interim pipeline; the full FunctionDef version will
            // drive resolve_scope_var from it.
            output[out_idx] = lowerScopeVarOp(op);
            std.mem.writeInt(u32, output[out_idx + 1 ..][0..4], atom_id, .little);
            output_atoms[out_atom_idx] = func.atoms.dup(atom_id);
            out_idx += 5;
            out_atom_idx += 1;
            in_atom_idx += 1;
            i += 7;
        } else if (op == opcode.op.enter_scope or op == opcode.op.leave_scope) {
            if (i + 3 > func.code.len) return error.InvalidBytecode;
            i += 3;
        } else {
            const size = instrSize(op);
            if (i + size > func.code.len) return error.InvalidBytecode;
            @memcpy(output[out_idx .. out_idx + size], func.code[i .. i + size]);
            if (hasAtomOperand(op)) {
                if (in_atom_idx >= func.atom_operands.len) return error.InvalidBytecode;
                output_atoms[out_atom_idx] = func.atoms.dup(func.atom_operands[in_atom_idx]);
                out_atom_idx += 1;
                in_atom_idx += 1;
            }
            if (labelOperandOffset(op)) |offset| {
                jump_sites[out_jump_idx] = .{ .operand_pos = out_idx + offset };
                out_jump_idx += 1;
            }
            out_idx += size;
            i += size;
        }
    }
    // Terminal entry: pc_map[old_len] == out_idx handles jumps that
    // target exactly one-past-the-end (e.g. loop exit to the next
    // instruction after the final byte).
    pc_map[func.code.len] = out_idx;

    // Patch jump targets using the pc map. Each site stored an
    // absolute u32 target that was valid against the *input* code
    // layout; rewrite it to the new post-lowering position.
    for (jump_sites[0..out_jump_idx]) |site| {
        const old_target = std.mem.readInt(u32, output[site.operand_pos..][0..4], .little);
        // Targets outside `[0, func.code.len]` indicate a parser bug,
        // but we treat them as identity rather than panicking so the
        // pipeline stays robust to unfamiliar inputs.
        const new_target: u32 = if (old_target <= func.code.len)
            @intCast(pc_map[old_target])
        else
            old_target;
        std.mem.writeInt(u32, output[site.operand_pos..][0..4], new_target, .little);
    }

    // Replace the old code buffer.
    if (func.code.len != 0) ctx.memory.free(u8, func.code);
    func.code = output[0..out_idx];

    // Replace atom_operands: release old entries, install new ones.
    for (func.atom_operands) |old_atom| func.atoms.free(old_atom);
    if (func.atom_operands.len != 0) ctx.memory.free(atom.Atom, func.atom_operands);
    func.atom_operands = output_atoms[0..out_atom_idx];
}
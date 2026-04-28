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
const function_def_mod = @import("../function_def.zig");
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
    /// Optional FunctionDef driving local-slot lookup. When non-null,
    /// `resolve_variables` lowers `scope_get_var` / `scope_put_var` to
    /// `get_loc` / `put_loc` (3-byte loc form) for any atom that
    /// resolves to a `VarDef` in `function_def.vars`. References that
    /// don't resolve fall back to global `get_var` / `put_var` (5-byte
    /// atom form), matching QuickJS `resolve_scope_var`
    /// (`quickjs.c:32377`) when `JSClosureType.GLOBAL` is selected.
    function_def: ?*const function_def_mod.FunctionDef = null,

    pub fn init(function: *bytecode_function.Bytecode) Context {
        return .{
            .function = function,
            .memory = function.memory,
            .atoms = function.atoms,
        };
    }

    pub fn initWithFunctionDef(
        function: *bytecode_function.Bytecode,
        fd: *const function_def_mod.FunctionDef,
    ) Context {
        return .{
            .function = function,
            .memory = function.memory,
            .atoms = function.atoms,
            .function_def = fd,
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
/// All four are 7-byte `atom_u16` forms.
fn isScopeVarOp(op_id: u8) bool {
    return op_id == opcode.op.scope_get_var or
        op_id == opcode.op.scope_put_var or
        op_id == opcode.op.scope_get_var_undef or
        op_id == opcode.op.scope_put_var_init;
}

/// Maps a scope_* var opcode to its global-form counterpart (5-byte
/// atom form). Used when the variable doesn't resolve to a local
/// slot in `function_def.vars`. `scope_put_var_init` lowers to
/// `put_var_init` (initialise-once binding for top-level
/// `let`/`const`); the others use their plain counterparts.
fn lowerScopeVarOpGlobal(op_id: u8) u8 {
    return switch (op_id) {
        opcode.op.scope_get_var => opcode.op.get_var,
        opcode.op.scope_put_var => opcode.op.put_var,
        opcode.op.scope_get_var_undef => opcode.op.get_var_undef,
        opcode.op.scope_put_var_init => opcode.op.put_var_init,
        else => unreachable,
    };
}

/// Maps a scope_* var opcode to its local-form counterpart (3-byte
/// loc form). `scope_get_var_undef` collapses to `get_loc` since
/// locals are always defined (frame allocates them up front, default
/// value is `undefined`). `scope_put_var_init` collapses to
/// `put_loc` for the local case — the TDZ-aware `put_loc_check_init`
/// variant is §F10.1 Outstanding work.
fn lowerScopeVarOpLocal(op_id: u8) u8 {
    return switch (op_id) {
        opcode.op.scope_get_var => opcode.op.get_loc,
        opcode.op.scope_put_var => opcode.op.put_loc,
        opcode.op.scope_get_var_undef => opcode.op.get_loc,
        opcode.op.scope_put_var_init => opcode.op.put_loc,
        else => unreachable,
    };
}

/// Shortest-form local-slot opcode triple. Mirrors `put_short_code`
/// (`quickjs.c:34140`):
/// - `idx ∈ [0, 4)` → 1-byte short forms `get_loc0..3` / `put_loc0..3`
///   / `set_loc0..3` (idx encoded in opcode id).
/// - `idx ∈ [4, 256)` → 2-byte `get_loc8` / `put_loc8` / `set_loc8`
///   (1-byte op + u8 idx).
/// - `idx ∈ [256, 65536)` → 3-byte `get_loc` / `put_loc` / `set_loc`
///   (1-byte op + u16 idx).
const ShortLocForm = struct {
    /// Selected opcode id.
    op_id: u8,
    /// Total byte length (1, 2, or 3) the encoder will produce.
    size: u8,
    /// Operand byte width (0 for short, 1 for u8, 2 for u16).
    operand_size: u8,
};

fn selectShortLoc(base_op: u8, idx: u16) ShortLocForm {
    if (idx < 4) {
        const short_base: u8 = switch (base_op) {
            opcode.op.get_loc => opcode.op.get_loc0,
            opcode.op.put_loc => opcode.op.put_loc0,
            opcode.op.set_loc => opcode.op.set_loc0,
            else => unreachable,
        };
        return .{
            .op_id = short_base + @as(u8, @intCast(idx)),
            .size = 1,
            .operand_size = 0,
        };
    }
    if (idx < 256) {
        const op_id: u8 = switch (base_op) {
            opcode.op.get_loc => opcode.op.get_loc8,
            opcode.op.put_loc => opcode.op.put_loc8,
            opcode.op.set_loc => opcode.op.set_loc8,
            else => unreachable,
        };
        return .{ .op_id = op_id, .size = 2, .operand_size = 1 };
    }
    return .{ .op_id = base_op, .size = 3, .operand_size = 2 };
}

/// If the FunctionDef has a `VarDef` for `atom_id`, return its var
/// index. Mirrors a simplified `find_var` (`quickjs.c:23378`) — this
/// scan ignores arg vs var split since the parser does not yet
/// register arguments. Full scope-chain walking with closure
/// classification is part of §F10.1 Outstanding.
fn lookupLocal(ctx: *const Context, atom_id: u32) ?u16 {
    const fd = ctx.function_def orelse return null;
    const idx = fd.findVar(atom_id);
    if (idx < 0) return null;
    return @intCast(idx);
}

/// True iff the local at `loc_idx` is a lexical (`let`/`const`) var
/// — these need TDZ check variants. `var` slots return false (var
/// is hoisted and starts as `undefined`, no TDZ).
fn isLexicalLocal(ctx: *const Context, loc_idx: u16) bool {
    const fd = ctx.function_def orelse return false;
    if (loc_idx >= fd.vars.len) return false;
    return fd.vars[loc_idx].is_lexical;
}

/// Promote a Phase-1 var op to its TDZ-checked counterpart for
/// lexical locals. Mirrors the `_check` family in QuickJS:
/// - `scope_get_var` / `scope_get_var_undef` → `get_loc_check`
///   (throws ReferenceError if slot is uninitialised).
/// - `scope_put_var` → `put_loc_check` (throws ReferenceError if
///   uninitialised, then stores).
/// - `scope_put_var_init` → `put_loc_check_init` (stores and
///   clears the uninitialised flag).
///
/// All check variants are 3-byte u16 forms (no short variants in
/// QuickJS), so callers must NOT run `selectShortLoc` on the result.
fn lowerScopeVarOpLexical(op_id: u8) u8 {
    return switch (op_id) {
        opcode.op.scope_get_var => opcode.op.get_loc_check,
        opcode.op.scope_get_var_undef => opcode.op.get_loc_check,
        opcode.op.scope_put_var => opcode.op.put_loc_check,
        opcode.op.scope_put_var_init => opcode.op.put_loc_check_init,
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
    // Count lexical locals so we can size the TDZ prologue. Each
    // lexical slot needs an `OP_set_loc_uninitialized <u16 idx>`
    // (3 bytes) emitted before the body so `get_loc_check` knows
    // the slot is in TDZ. `var` slots don't need this — they're
    // already undefined.
    var prologue_lexical_count: usize = 0;
    if (ctx.function_def) |fd| {
        for (fd.vars) |v| {
            if (v.is_lexical) prologue_lexical_count += 1;
        }
    }
    const prologue_size: usize = prologue_lexical_count * 3;

    var output_size: usize = prologue_size;
    var output_atom_count: usize = 0;
    var jump_count: usize = 0;
    var i: usize = 0;
    while (i < func.code.len) {
        const op = func.code[i];
        if (isScopeVarOp(op)) {
            if (i + 7 > func.code.len) return error.InvalidBytecode;
            const atom_id = std.mem.readInt(u32, func.code[i + 1 ..][0..4], .little);
            if (lookupLocal(ctx, atom_id)) |loc_idx| {
                if (isLexicalLocal(ctx, loc_idx)) {
                    // Lexical: 3-byte check variant, no short form.
                    output_size += 3;
                } else {
                    // var: pick shortest form (1, 2, or 3 bytes).
                    const local_op = lowerScopeVarOpLocal(op);
                    const form = selectShortLoc(local_op, loc_idx);
                    output_size += form.size;
                }
            } else {
                // Global: 5-byte atom form, one atom operand.
                output_size += 5;
                output_atom_count += 1;
            }
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

    // Emit the TDZ prologue: one `set_loc_uninitialized <idx>` per
    // lexical local. This marks the slots so `get_loc_check` /
    // `put_loc_check` throw `ReferenceError` until
    // `put_loc_check_init` runs.
    if (ctx.function_def) |fd| {
        for (fd.vars, 0..) |v, var_idx| {
            if (!v.is_lexical) continue;
            output[out_idx] = opcode.op.set_loc_uninitialized;
            std.mem.writeInt(u16, output[out_idx + 1 ..][0..2], @intCast(var_idx), .little);
            out_idx += 3;
        }
    }

    i = 0;
    while (i < func.code.len) {
        // pc_map for input pc i maps to output pc out_idx (after the
        // prologue), so jumps that reference the post-prologue body
        // resolve correctly.
        pc_map[i] = out_idx;
        const op = func.code[i];
        if (isScopeVarOp(op)) {
            if (i + 7 > func.code.len) return error.InvalidBytecode;
            const atom_id = std.mem.readInt(u32, func.code[i + 1 ..][0..4], .little);
            // scope_level at func.code[i+5..i+7] is unused in this
            // simplified path; the full §F10.1 Outstanding pipeline
            // will check it via `is_child_scope` for shadowing.
            if (lookupLocal(ctx, atom_id)) |loc_idx| {
                if (isLexicalLocal(ctx, loc_idx)) {
                    // Lexical: emit 3-byte TDZ-check variant.
                    output[out_idx] = lowerScopeVarOpLexical(op);
                    std.mem.writeInt(u16, output[out_idx + 1 ..][0..2], loc_idx, .little);
                    out_idx += 3;
                    in_atom_idx += 1;
                } else {
                    // var: emit shortest form. The input atom slot is
                    // consumed but we do NOT re-emit it.
                    const local_op = lowerScopeVarOpLocal(op);
                    const form = selectShortLoc(local_op, loc_idx);
                    output[out_idx] = form.op_id;
                    switch (form.operand_size) {
                        0 => {}, // idx encoded in opcode id
                        1 => output[out_idx + 1] = @intCast(loc_idx),
                        2 => std.mem.writeInt(u16, output[out_idx + 1 ..][0..2], loc_idx, .little),
                        else => unreachable,
                    }
                    out_idx += form.size;
                    in_atom_idx += 1;
                }
            } else {
                // Global lowering: emit get_var / put_var with atom.
                output[out_idx] = lowerScopeVarOpGlobal(op);
                std.mem.writeInt(u32, output[out_idx + 1 ..][0..4], atom_id, .little);
                output_atoms[out_atom_idx] = func.atoms.dup(atom_id);
                out_idx += 5;
                out_atom_idx += 1;
                in_atom_idx += 1;
            }
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
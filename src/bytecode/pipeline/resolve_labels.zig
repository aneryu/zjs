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
const function_def_mod = @import("../function_def.zig");
const opcode = @import("../opcode.zig");

// Special object subtypes (mirrors quickjs.c:17410-17416)
const SPECIAL_OBJECT_ARGUMENTS: u8 = 0;
const SPECIAL_OBJECT_MAPPED_ARGUMENTS: u8 = 1;
const SPECIAL_OBJECT_THIS_FUNC: u8 = 2;
const SPECIAL_OBJECT_NEW_TARGET: u8 = 3;
const SPECIAL_OBJECT_HOME_OBJECT: u8 = 4;
const SPECIAL_OBJECT_VAR_OBJECT: u8 = 5;
const SPECIAL_OBJECT_IMPORT_META: u8 = 6;
const SPECIAL_OBJECT_NULL_PROTO: u8 = 7;

pub const Error = error{
    InvalidBytecode,
};

/// JSContext for label resolution.
pub const JSContext = struct {
    function: *bytecode_function.Bytecode,
    memory: *memory.MemoryAccount,
    atoms: *atom.AtomTable,
    /// Optional FunctionDef for function prologue emission. When non-null,
    /// `resolve_labels` emits OP_special_object sequences for special
    /// variables (home_object, this_active_func, new_target, arguments, etc.).
    function_def: ?*const function_def_mod.FunctionDef = null,

    pub fn init(function: *bytecode_function.Bytecode) JSContext {
        return .{
            .function = function,
            .memory = function.memory,
            .atoms = function.atoms,
        };
    }

    pub fn initWithFunctionDef(
        function: *bytecode_function.Bytecode,
        fd: *const function_def_mod.FunctionDef,
    ) JSContext {
        return .{
            .function = function,
            .memory = function.memory,
            .atoms = function.atoms,
            .function_def = fd,
        };
    }
};

/// Total byte length (opcode + operands) for `op_id` in final-form
/// (non-temp) encoding, from the generated metadata table. This pass's
/// input contains no temp opcode except `label` (resolve_variables
/// erased the rest), and `label` is special-cased at each walk site,
/// so the final view is the correct one here — phase-2 streams may
/// already carry final-form ids like `fclosure8` whose temp-view size
/// would differ. Unknown ids fall back to 1 to keep the walker
/// progressing.
fn instrSize(op_id: u8) usize {
    const total = opcode.sizeOf(op_id);
    return if (total == 0) 1 else total;
}

fn isJumpOp(op_id: u8) bool {
    return op_id == opcode.op.if_false or
        op_id == opcode.op.if_true or
        op_id == opcode.op.goto or
        op_id == opcode.op.@"catch";
}

fn isAtomLabelU8Op(op_id: u8) bool {
    return op_id == opcode.op.with_get_var or
        op_id == opcode.op.with_put_var or
        op_id == opcode.op.with_delete_var or
        op_id == opcode.op.with_make_ref or
        op_id == opcode.op.with_get_ref;
}

const ShortSlotForm = struct {
    op_id: u8,
    size: u8,
    operand_size: u8,
};

fn selectShortSlot(op_id: u8, idx: u16) ?ShortSlotForm {
    const short_base: ?u8 = switch (op_id) {
        opcode.op.get_loc => opcode.op.get_loc0,
        opcode.op.put_loc => opcode.op.put_loc0,
        opcode.op.set_loc => opcode.op.set_loc0,
        opcode.op.get_arg => opcode.op.get_arg0,
        opcode.op.put_arg => opcode.op.put_arg0,
        opcode.op.set_arg => opcode.op.set_arg0,
        opcode.op.get_var_ref => opcode.op.get_var_ref0,
        opcode.op.put_var_ref => opcode.op.put_var_ref0,
        opcode.op.set_var_ref => opcode.op.set_var_ref0,
        else => null,
    };
    const base = short_base orelse return null;
    if (idx < 4) {
        return .{
            .op_id = base + @as(u8, @intCast(idx)),
            .size = 1,
            .operand_size = 0,
        };
    }

    const loc8_op: ?u8 = switch (op_id) {
        opcode.op.get_loc => opcode.op.get_loc8,
        opcode.op.put_loc => opcode.op.put_loc8,
        opcode.op.set_loc => opcode.op.set_loc8,
        else => null,
    };
    if (loc8_op) |loc_op| {
        if (idx < 256) {
            return .{ .op_id = loc_op, .size = 2, .operand_size = 1 };
        }
    }
    return .{ .op_id = op_id, .size = 3, .operand_size = 2 };
}

fn jumpTarget(code: []const u8, pc: usize) !usize {
    if (pc + 5 > code.len) return error.InvalidBytecode;
    const target = std.mem.readInt(u32, code[pc + 1 ..][0..4], .little);
    if (target > code.len) return error.InvalidBytecode;
    return @intCast(target);
}

fn atomLabelTarget(code: []const u8, pc: usize) !usize {
    if (pc + 10 > code.len) return error.InvalidBytecode;
    const target = std.mem.readInt(u32, code[pc + 5 ..][0..4], .little);
    if (target > code.len) return error.InvalidBytecode;
    return @intCast(target);
}

fn skipLabels(code: []const u8, pc: usize) !usize {
    var cursor = pc;
    while (cursor < code.len and code[cursor] == opcode.op.label) {
        if (cursor + 5 > code.len) return error.InvalidBytecode;
        cursor += 5;
    }
    return cursor;
}

fn threadedJumpTarget(code: []const u8, pc: usize) !usize {
    const original = try jumpTarget(code, pc);
    var target = original;
    var depth: usize = 0;
    while (depth < 10) : (depth += 1) {
        const target_pc = try skipLabels(code, target);
        if (target_pc >= code.len or code[target_pc] != opcode.op.goto) return target;
        const next = try jumpTarget(code, target_pc);
        if (next == target) return original;
        target = next;
    }
    return original;
}

fn resolvedJumpTarget(code: []const u8, pc: usize) !usize {
    return switch (code[pc]) {
        opcode.op.goto, opcode.op.if_false, opcode.op.if_true => threadedJumpTarget(code, pc),
        else => jumpTarget(code, pc),
    };
}

fn relOffset(from_pc: usize, target_pc: usize) i64 {
    return @as(i64, @intCast(target_pc)) - @as(i64, @intCast(from_pc + 1));
}

fn jumpSizeForOffset(op_id: u8, diff: i64, use_short_opcodes: bool) usize {
    if (op_id == opcode.op.@"catch") return 5;
    if (use_short_opcodes) {
        if (diff >= std.math.minInt(i8) and diff <= std.math.maxInt(i8)) return 2;
        if (op_id == opcode.op.goto and diff >= std.math.minInt(i16) and diff <= std.math.maxInt(i16)) return 3;
    }
    return 5;
}

fn jumpOpForSize(op_id: u8, size: usize) u8 {
    return switch (size) {
        2 => switch (op_id) {
            opcode.op.if_false => opcode.op.if_false8,
            opcode.op.if_true => opcode.op.if_true8,
            opcode.op.goto => opcode.op.goto8,
            else => unreachable,
        },
        3 => switch (op_id) {
            opcode.op.goto => opcode.op.goto16,
            else => op_id,
        },
        5 => op_id,
        else => unreachable,
    };
}

fn loweredPushI32Size(value: i32, use_short_opcodes: bool) usize {
    if (!use_short_opcodes) return 5;
    if (value >= -1 and value <= 7) return 1;
    if (value >= std.math.minInt(i8) and value <= std.math.maxInt(i8)) return 2;
    if (value >= std.math.minInt(i16) and value <= std.math.maxInt(i16)) return 3;
    return 5;
}

fn loweredInstrSize(code: []const u8, pc: usize, use_short_opcodes: bool) usize {
    const op = code[pc];
    if (!use_short_opcodes) return instrSize(op);
    if (op == opcode.op.push_i32 and pc + 5 <= code.len) {
        const value = std.mem.readInt(i32, code[pc + 1 ..][0..4], .little);
        return loweredPushI32Size(value, use_short_opcodes);
    }
    if (op == opcode.op.call and pc + 3 <= code.len) {
        const argc = std.mem.readInt(u16, code[pc + 1 ..][0..2], .little);
        if (argc <= 3) return 1;
    }
    if ((op == opcode.op.push_const or op == opcode.op.fclosure) and pc + 5 <= code.len) {
        const idx = std.mem.readInt(u32, code[pc + 1 ..][0..4], .little);
        if (idx < 256) return 2;
    }
    if (pc + 3 <= code.len) {
        const idx = std.mem.readInt(u16, code[pc + 1 ..][0..2], .little);
        if (selectShortSlot(op, idx)) |form| return form.size;
    }
    return instrSize(op);
}

fn hasAtomOperand(op_id: u8) bool {
    const fmt = opcode.formatOf(op_id);
    return fmt == .atom or fmt == .atom_u8 or fmt == .atom_u16 or
        fmt == .atom_label_u8 or fmt == .atom_label_u16;
}

fn hasJumpTargetInRange(code: []const u8, start_pc: usize, end_pc: usize) bool {
    var scan_pc: usize = 0;
    while (scan_pc < code.len) {
        const op_id = code[scan_pc];
        const size = if (op_id == opcode.op.label) 5 else instrSize(op_id);
        if (size == 0 or scan_pc + size > code.len) return false;
        const target = if (isJumpOp(op_id))
            (jumpTarget(code, scan_pc) catch return false)
        else if (isAtomLabelU8Op(op_id))
            (atomLabelTarget(code, scan_pc) catch return false)
        else
            null;
        if (target) |target_pc| {
            if (target_pc >= start_pc and target_pc < end_pc) return true;
        }
        scan_pc += size;
    }
    return false;
}

const ConstantTestPeephole = struct {
    taken: bool,
    jump_pc: usize,
    total_size: usize,
};

fn matchConstantTestPeephole(code: []const u8, pc: usize) ?ConstantTestPeephole {
    if (pc + 10 > code.len or code[pc] != opcode.op.push_i32) return null;
    const jump_pc = pc + 5;
    const jump_op = code[jump_pc];
    if (jump_op != opcode.op.if_false and jump_op != opcode.op.if_true) return null;
    if (hasJumpTargetInRange(code, pc + 1, pc + 10)) return null;
    const value = std.mem.readInt(i32, code[pc + 1 ..][0..4], .little);
    const truthy = value != 0;
    return .{
        .taken = if (jump_op == opcode.op.if_true) truthy else !truthy,
        .jump_pc = jump_pc,
        .total_size = 10,
    };
}

const PushI32NegPeephole = struct {
    value: i32,
    total_size: usize,
};

fn matchPushI32NegPeephole(code: []const u8, pc: usize) ?PushI32NegPeephole {
    if (pc + 6 > code.len or code[pc] != opcode.op.push_i32 or code[pc + 5] != opcode.op.neg) return null;
    if (hasJumpTargetInRange(code, pc + 1, pc + 6)) return null;
    const value = std.mem.readInt(i32, code[pc + 1 ..][0..4], .little);
    if (value == std.math.minInt(i32) or value == 0) return null;
    return .{ .value = -value, .total_size = 6 };
}

fn deadCodePastGotoSize(code: []const u8, pc: usize) ?usize {
    if (pc >= code.len or code[pc] != opcode.op.goto) return null;
    const goto_size = instrSize(opcode.op.goto);
    var scan_pc = pc + goto_size;
    var skipped: usize = 0;
    while (scan_pc < code.len) {
        if (hasJumpTargetTo(code, scan_pc)) break;
        const op_id = code[scan_pc];
        const size = if (op_id == opcode.op.label) 5 else instrSize(op_id);
        if (size == 0 or scan_pc + size > code.len) return null;
        if (hasAtomOperand(op_id)) return null;
        scan_pc += size;
        skipped += size;
    }
    return if (skipped == 0) null else skipped;
}

fn undefinedDropPairSize(code: []const u8, pc: usize) ?usize {
    if (pc + 2 > code.len) return null;
    if (code[pc] == opcode.op.undefined and code[pc + 1] == opcode.op.drop) return 2;
    return null;
}

const AddLocPeephole = struct {
    idx: u16,
    rhs_op: u8,
    rhs_size: usize,
    total_size: usize,
};

fn matchAddLocPeephole(code: []const u8, pc: usize) ?AddLocPeephole {
    if (pc + 3 > code.len) return null;
    const first_op = code[pc];
    if (first_op != opcode.op.get_loc) return null;
    const idx = std.mem.readInt(u16, code[pc + 1 ..][0..2], .little);
    if (idx >= 256) return null;

    const rhs_pc = pc + 3;
    if (rhs_pc >= code.len) return null;
    const rhs_op = code[rhs_pc];

    const rhs_size = switch (rhs_op) {
        opcode.op.push_i32, opcode.op.push_const, opcode.op.push_atom_value => @as(usize, 5),
        opcode.op.get_loc, opcode.op.get_arg, opcode.op.get_var_ref => @as(usize, 3),
        else => return null,
    };

    const suffix_pc = rhs_pc + rhs_size;
    if (suffix_pc + 6 > code.len) return null;

    if (code[suffix_pc] != opcode.op.add) return null;
    if (code[suffix_pc + 1] != opcode.op.dup) return null;
    if (code[suffix_pc + 2] != opcode.op.put_loc) return null;

    const put_idx = std.mem.readInt(u16, code[suffix_pc + 3 ..][0..2], .little);
    if (put_idx != idx) return null;

    if (code[suffix_pc + 5] != opcode.op.drop) return null;

    var offset: usize = 1;
    const total_len = rhs_size + 9;
    while (offset < total_len) : (offset += 1) {
        if (hasJumpTargetTo(code, pc + offset)) return null;
    }

    return .{
        .idx = idx,
        .rhs_op = rhs_op,
        .rhs_size = rhs_size,
        .total_size = total_len,
    };
}

fn isTerminalOp(op_id: u8) bool {
    return switch (op_id) {
        opcode.op.goto,
        opcode.op.@"return",
        opcode.op.return_undef,
        opcode.op.return_async,
        opcode.op.tail_call,
        opcode.op.tail_call_method,
        opcode.op.throw,
        => true,
        else => false,
    };
}

fn isCleanupOp(op_id: u8) bool {
    return op_id == opcode.op.label or op_id == opcode.op.leave_scope or op_id == opcode.op.close_loc;
}

fn hasJumpTargetTo(code: []const u8, target_pc: usize) bool {
    var scan_pc: usize = 0;
    while (scan_pc < code.len) {
        const op_id = code[scan_pc];
        const size = if (op_id == opcode.op.label) 5 else instrSize(op_id);
        if (size == 0 or scan_pc + size > code.len) return false;
        if (isJumpOp(op_id)) {
            if ((jumpTarget(code, scan_pc) catch return false) == target_pc) return true;
        } else if (isAtomLabelU8Op(op_id)) {
            if ((atomLabelTarget(code, scan_pc) catch return false) == target_pc) return true;
        }
        scan_pc += size;
    }
    return false;
}

fn redundantReturnUndefSize(code: []const u8, pc: usize) ?usize {
    if (pc >= code.len or code[pc] != opcode.op.return_undef) return null;
    if (hasJumpTargetTo(code, pc)) return null;
    var scan_pc: usize = 0;
    var last_non_cleanup: ?u8 = null;
    while (scan_pc < pc) {
        const op_id = code[scan_pc];
        const size = if (op_id == opcode.op.label) 5 else instrSize(op_id);
        if (size == 0 or scan_pc + size > code.len) return null;
        if (!isCleanupOp(op_id)) last_non_cleanup = op_id;
        scan_pc += size;
    }
    if (last_non_cleanup) |op_id| {
        if (isTerminalOp(op_id)) return 1;
    }
    return null;
}

fn emitPushI32Value(output: []u8, out_idx: *usize, value: i32, use_short_opcodes: bool) void {
    if (use_short_opcodes) {
        if (value >= -1 and value <= 7) {
            output[out_idx.*] = switch (value) {
                -1 => opcode.op.push_minus1,
                0 => opcode.op.push_0,
                1 => opcode.op.push_1,
                2 => opcode.op.push_2,
                3 => opcode.op.push_3,
                4 => opcode.op.push_4,
                5 => opcode.op.push_5,
                6 => opcode.op.push_6,
                7 => opcode.op.push_7,
                else => unreachable,
            };
            out_idx.* += 1;
            return;
        }
        if (value >= std.math.minInt(i8) and value <= std.math.maxInt(i8)) {
            output[out_idx.*] = opcode.op.push_i8;
            output[out_idx.* + 1] = @bitCast(@as(i8, @intCast(value)));
            out_idx.* += 2;
            return;
        }
        if (value >= std.math.minInt(i16) and value <= std.math.maxInt(i16)) {
            output[out_idx.*] = opcode.op.push_i16;
            std.mem.writeInt(i16, output[out_idx.* + 1 ..][0..2], @intCast(value), .little);
            out_idx.* += 3;
            return;
        }
    }
    output[out_idx.*] = opcode.op.push_i32;
    std.mem.writeInt(i32, output[out_idx.* + 1 ..][0..4], value, .little);
    out_idx.* += 5;
}

fn emitLoweredInstruction(code: []const u8, pc: usize, output: []u8, out_idx: *usize, use_short_opcodes: bool) !void {
    const op = code[pc];
    if (op == opcode.op.push_i32 and pc + 5 <= code.len) {
        const value = std.mem.readInt(i32, code[pc + 1 ..][0..4], .little);
        emitPushI32Value(output, out_idx, value, use_short_opcodes);
        return;
    }
    if (use_short_opcodes and op == opcode.op.call and pc + 3 <= code.len) {
        const argc = std.mem.readInt(u16, code[pc + 1 ..][0..2], .little);
        if (argc <= 3) {
            output[out_idx.*] = switch (argc) {
                0 => opcode.op.call0,
                1 => opcode.op.call1,
                2 => opcode.op.call2,
                3 => opcode.op.call3,
                else => unreachable,
            };
            out_idx.* += 1;
            return;
        }
    }
    if (use_short_opcodes and (op == opcode.op.push_const or op == opcode.op.fclosure) and pc + 5 <= code.len) {
        const idx = std.mem.readInt(u32, code[pc + 1 ..][0..4], .little);
        if (idx < 256) {
            output[out_idx.*] = if (op == opcode.op.push_const) opcode.op.push_const8 else opcode.op.fclosure8;
            output[out_idx.* + 1] = @intCast(idx);
            out_idx.* += 2;
            return;
        }
    }
    if (use_short_opcodes and pc + 3 <= code.len) {
        const idx = std.mem.readInt(u16, code[pc + 1 ..][0..2], .little);
        if (selectShortSlot(op, idx)) |form| {
            output[out_idx.*] = form.op_id;
            switch (form.operand_size) {
                0 => {},
                1 => output[out_idx.* + 1] = @intCast(idx),
                2 => std.mem.writeInt(u16, output[out_idx.* + 1 ..][0..2], idx, .little),
                else => return error.InvalidBytecode,
            }
            out_idx.* += form.size;
            return;
        }
    }
    const size = instrSize(op);
    if (pc + size > code.len) return error.InvalidBytecode;
    @memcpy(output[out_idx.* .. out_idx.* + size], code[pc .. pc + size]);
    out_idx.* += size;
}

fn computeLayout(ctx: *const JSContext, positions: []usize, sizes: []usize, use_short_opcodes: bool, initial_pc: usize) !usize {
    const code = ctx.function.code;
    @memset(positions, 0);
    @memset(sizes, 0);

    var changed = true;
    var final_size: usize = 0;
    var pass: usize = 0;
    // Short-form jumps and instruction shrinkage can cascade through large
    // generated files; keep iterating past the old small fixed cap, while
    // still retaining a hard guard against accidental oscillation.
    const max_passes = 64;
    while (changed and pass < max_passes) : (pass += 1) {
        changed = false;
        var out_pc: usize = initial_pc;
        var pc: usize = 0;
        while (pc < code.len) {
            positions[pc] = out_pc;
            const op = code[pc];
            const old_size = sizes[pc];
            const in_size = if (op == opcode.op.label) 5 else instrSize(op);
            if (pc + in_size > code.len) return error.InvalidBytecode;

            const new_size: usize = if (op == opcode.op.label)
                0
            else if (undefinedDropPairSize(code, pc) != null)
                0
            else if (redundantReturnUndefSize(code, pc) != null)
                0
            else if (matchAddLocPeephole(code, pc)) |_|
                loweredInstrSize(code, pc + 3, use_short_opcodes) + 2
            else if (matchConstantTestPeephole(code, pc)) |p| blk: {
                if (!p.taken) break :blk 0;
                const target = try resolvedJumpTarget(code, p.jump_pc);
                const target_pc = positions[target];
                const diff = relOffset(out_pc, target_pc);
                break :blk jumpSizeForOffset(opcode.op.goto, diff, use_short_opcodes);
            } else if (matchPushI32NegPeephole(code, pc)) |p|
                loweredPushI32Size(p.value, use_short_opcodes)
            else if (isAtomLabelU8Op(op))
                instrSize(op)
            else if (isJumpOp(op)) blk: {
                const target = try resolvedJumpTarget(code, pc);
                const target_pc = positions[target];
                const diff = relOffset(out_pc, target_pc);
                break :blk jumpSizeForOffset(op, diff, use_short_opcodes);
            } else loweredInstrSize(code, pc, use_short_opcodes);

            sizes[pc] = new_size;
            if (old_size != new_size) changed = true;
            const next_pc = pc + (undefinedDropPairSize(code, pc) orelse (redundantReturnUndefSize(code, pc) orelse (if (matchAddLocPeephole(code, pc)) |p| p.total_size else if (matchConstantTestPeephole(code, pc)) |p| p.total_size else if (matchPushI32NegPeephole(code, pc)) |p| p.total_size else in_size + (deadCodePastGotoSize(code, pc) orelse 0))));
            var boundary_pc = pc + 1;
            while (boundary_pc <= next_pc and boundary_pc < positions.len) : (boundary_pc += 1) {
                positions[boundary_pc] = out_pc + new_size;
            }
            out_pc += new_size;
            pc = next_pc;
        }
        positions[code.len] = out_pc;
        final_size = out_pc;
    }
    if (changed) return error.InvalidBytecode;
    return final_size;
}

fn emitJumpToTarget(op: u8, target: usize, output: []u8, out_idx: *usize, positions: []const usize, size: usize) !void {
    const target_pc = positions[target];
    const current_pc = out_idx.*;
    const diff = relOffset(current_pc, target_pc);
    output[out_idx.*] = jumpOpForSize(op, size);
    switch (size) {
        2 => {
            output[out_idx.* + 1] = @bitCast(@as(i8, @intCast(diff)));
        },
        3 => {
            std.mem.writeInt(i16, output[out_idx.* + 1 ..][0..2], @intCast(diff), .little);
        },
        5 => {
            std.mem.writeInt(i32, output[out_idx.* + 1 ..][0..4], @intCast(diff), .little);
        },
        else => return error.InvalidBytecode,
    }
    out_idx.* += size;
}

fn emitJump(code: []const u8, pc: usize, output: []u8, out_idx: *usize, positions: []const usize, size: usize) !void {
    const op = code[pc];
    const target = try resolvedJumpTarget(code, pc);
    try emitJumpToTarget(op, target, output, out_idx, positions, size);
}

fn emitAtomLabelU8(code: []const u8, pc: usize, output: []u8, out_idx: *usize, positions: []const usize) !void {
    if (pc + 10 > code.len) return error.InvalidBytecode;
    const target = try atomLabelTarget(code, pc);
    const target_pc = positions[target];
    const current_pc = out_idx.*;
    const diff = @as(i64, @intCast(target_pc)) - @as(i64, @intCast(current_pc + 5));
    if (diff < std.math.minInt(i32) or diff > std.math.maxInt(i32)) return error.InvalidBytecode;
    output[out_idx.*] = code[pc];
    @memcpy(output[out_idx.* + 1 .. out_idx.* + 5], code[pc + 1 .. pc + 5]);
    std.mem.writeInt(i32, output[out_idx.* + 5 ..][0..4], @intCast(diff), .little);
    output[out_idx.* + 9] = code[pc + 9];
    out_idx.* += 10;
}

/// Emit the function prologue with OP_special_object sequences.
/// Mirrors `quickjs.c:34232-34294`.
fn emitFunctionPrologue(ctx: *const JSContext, output: []u8, out_idx: *usize) !void {
    const fd = ctx.function_def orelse return;

    // home_object
    if (fd.home_object_var_idx >= 0) {
        output[out_idx.*] = opcode.op.special_object;
        output[out_idx.* + 1] = SPECIAL_OBJECT_HOME_OBJECT;
        output[out_idx.* + 2] = opcode.op.put_loc;
        std.mem.writeInt(u16, output[out_idx.* + 3 ..][0..2], @intCast(fd.home_object_var_idx), .little);
        out_idx.* += 5;
    }

    // this_active_func
    if (fd.this_active_func_var_idx >= 0) {
        output[out_idx.*] = opcode.op.special_object;
        output[out_idx.* + 1] = SPECIAL_OBJECT_THIS_FUNC;
        output[out_idx.* + 2] = opcode.op.put_loc;
        std.mem.writeInt(u16, output[out_idx.* + 3 ..][0..2], @intCast(fd.this_active_func_var_idx), .little);
        out_idx.* += 5;
    }

    // new_target
    if (fd.new_target_var_idx >= 0) {
        output[out_idx.*] = opcode.op.special_object;
        output[out_idx.* + 1] = SPECIAL_OBJECT_NEW_TARGET;
        output[out_idx.* + 2] = opcode.op.put_loc;
        std.mem.writeInt(u16, output[out_idx.* + 3 ..][0..2], @intCast(fd.new_target_var_idx), .little);
        out_idx.* += 5;
    }

    // this (special handling for derived class constructors)
    if (fd.this_var_idx >= 0) {
        if (fd.is_derived_class_constructor) {
            output[out_idx.*] = opcode.op.set_loc_uninitialized;
            std.mem.writeInt(u16, output[out_idx.* + 1 ..][0..2], @intCast(fd.this_var_idx), .little);
            out_idx.* += 3;
        } else {
            output[out_idx.*] = opcode.op.push_this;
            out_idx.* += 1;
            output[out_idx.*] = opcode.op.put_loc;
            std.mem.writeInt(u16, output[out_idx.* + 1 ..][0..2], @intCast(fd.this_var_idx), .little);
            out_idx.* += 3;
        }
    }

    // arguments
    if (fd.arguments_var_idx >= 0) {
        if (fd.is_strict_mode or !fd.has_simple_parameter_list) {
            output[out_idx.*] = opcode.op.special_object;
            output[out_idx.* + 1] = SPECIAL_OBJECT_ARGUMENTS;
            out_idx.* += 2;
        } else {
            // Mapped arguments - capture all args (simplified)
            output[out_idx.*] = opcode.op.special_object;
            output[out_idx.* + 1] = SPECIAL_OBJECT_MAPPED_ARGUMENTS;
            out_idx.* += 2;
        }
        if (fd.arguments_arg_idx >= 0) {
            output[out_idx.*] = opcode.op.set_loc;
            std.mem.writeInt(u16, output[out_idx.* + 1 ..][0..2], @intCast(fd.arguments_arg_idx), .little);
            out_idx.* += 3;
        }
        output[out_idx.*] = opcode.op.put_loc;
        std.mem.writeInt(u16, output[out_idx.* + 1 ..][0..2], @intCast(fd.arguments_var_idx), .little);
        out_idx.* += 3;
    }

    // func_var (reference to current function)
    if (fd.func_var_idx >= 0) {
        output[out_idx.*] = opcode.op.special_object;
        output[out_idx.* + 1] = SPECIAL_OBJECT_THIS_FUNC;
        output[out_idx.* + 2] = opcode.op.put_loc;
        std.mem.writeInt(u16, output[out_idx.* + 3 ..][0..2], @intCast(fd.func_var_idx), .little);
        out_idx.* += 5;
    }

    // var_object
    if (fd.var_object_idx >= 0) {
        output[out_idx.*] = opcode.op.special_object;
        output[out_idx.* + 1] = SPECIAL_OBJECT_VAR_OBJECT;
        output[out_idx.* + 2] = opcode.op.put_loc;
        std.mem.writeInt(u16, output[out_idx.* + 3 ..][0..2], @intCast(fd.var_object_idx), .little);
        out_idx.* += 5;
    }

    // arg_var_object
    if (fd.arg_var_object_idx >= 0) {
        output[out_idx.*] = opcode.op.special_object;
        output[out_idx.* + 1] = SPECIAL_OBJECT_VAR_OBJECT;
        output[out_idx.* + 2] = opcode.op.put_loc;
        std.mem.writeInt(u16, output[out_idx.* + 3 ..][0..2], @intCast(fd.arg_var_object_idx), .little);
        out_idx.* += 5;
    }
}

pub fn run(ctx: *JSContext) !void {
    const func = ctx.function;
    const use_short_opcodes = if (ctx.function_def) |fd| fd.use_short_opcodes else false;

    // Calculate function prologue size
    var prologue_size: usize = 0;
    if (ctx.function_def) |fd| {
        if (fd.home_object_var_idx >= 0) prologue_size += 5;
        if (fd.this_active_func_var_idx >= 0) prologue_size += 5;
        if (fd.new_target_var_idx >= 0) prologue_size += 5;
        if (fd.this_var_idx >= 0) {
            if (fd.is_derived_class_constructor) {
                prologue_size += 3;
            } else {
                prologue_size += 4; // push_this (1) + put_loc (3)
            }
        }
        if (fd.arguments_var_idx >= 0) {
            prologue_size += 2; // special_object
            if (fd.arguments_arg_idx >= 0) prologue_size += 3;
            prologue_size += 3; // put_loc
        }
        if (fd.func_var_idx >= 0) prologue_size += 5;
        if (fd.var_object_idx >= 0) prologue_size += 5;
        if (fd.arg_var_object_idx >= 0) prologue_size += 5;
    }

    const positions = try ctx.memory.alloc(usize, func.code.len + 1);
    defer ctx.memory.free(usize, positions);
    const sizes = try ctx.memory.alloc(usize, func.code.len + 1);
    defer ctx.memory.free(usize, sizes);

    // First pass: compute the old-pc -> new-pc layout. OP_label is
    // dropped; jumps are rewritten from parser absolute targets to the
    // pc-relative form expected after resolve_labels.
    const output_size = try computeLayout(ctx, positions, sizes, use_short_opcodes, prologue_size);

    // Keep empty output as an inert slice so bytecode ownership stays explicit
    // without touching allocator accounting.
    const output: []u8 = if (output_size == 0)
        &.{}
    else
        try ctx.memory.alloc(u8, output_size);
    errdefer if (output.len != 0) ctx.memory.free(u8, output);

    // Second pass: emit prologue and copy (dropping labels).
    var out_idx: usize = 0;
    try emitFunctionPrologue(ctx, output, &out_idx);
    var i: usize = 0;
    while (i < func.code.len) {
        const op = func.code[i];
        if (op == opcode.op.label) {
            i += 5;
        } else if (undefinedDropPairSize(func.code, i)) |pair_size| {
            i += pair_size;
        } else if (redundantReturnUndefSize(func.code, i)) |return_size| {
            i += return_size;
        } else if (matchAddLocPeephole(func.code, i)) |p| {
            try emitLoweredInstruction(func.code, i + 3, output, &out_idx, use_short_opcodes);
            output[out_idx] = opcode.op.add_loc;
            output[out_idx + 1] = @intCast(p.idx);
            out_idx += 2;
            i += p.total_size;
        } else if (matchConstantTestPeephole(func.code, i)) |p| {
            if (p.taken) {
                const size = sizes[i];
                const target = try resolvedJumpTarget(func.code, p.jump_pc);
                try emitJumpToTarget(opcode.op.goto, target, output, &out_idx, positions, size);
            }
            i += p.total_size;
        } else if (matchPushI32NegPeephole(func.code, i)) |p| {
            emitPushI32Value(output, &out_idx, p.value, use_short_opcodes);
            i += p.total_size;
        } else if (isJumpOp(op)) {
            const size = sizes[i];
            try emitJump(func.code, i, output, &out_idx, positions, size);
            i += instrSize(op) + (deadCodePastGotoSize(func.code, i) orelse 0);
        } else if (isAtomLabelU8Op(op)) {
            try emitAtomLabelU8(func.code, i, output, &out_idx, positions);
            i += instrSize(op);
        } else {
            const size = instrSize(op);
            if (i + size > func.code.len) return error.InvalidBytecode;
            try emitLoweredInstruction(func.code, i, output, &out_idx, use_short_opcodes);
            i += size;
        }
    }

    // Replace the old code. `output` is sized to `output_size`, the
    // worst-case post-lowering layout; trim it to `out_idx` before
    // installing so capacity tracking stays accurate.
    func.remapSourceLocs(positions);
    func.remapDirectCallSites(positions);
    if (out_idx < output.len) {
        const trimmed = try ctx.memory.alloc(u8, out_idx);
        @memcpy(trimmed, output[0..out_idx]);
        ctx.memory.free(u8, output);
        func.installCode(trimmed);
    } else {
        func.installCode(output);
    }
}

const std = @import("std");

const bytecode = @import("../bytecode/root.zig");
const core = @import("../core/root.zig");
const frame_mod = @import("frame.zig");
const stack_mod = @import("stack.zig");
const value_ops = @import("value_ops.zig");
const call_runtime = @import("call_runtime.zig");
const coercion_ops = @import("coercion_ops.zig");
const slot_ops = @import("slot_ops.zig");

const op = bytecode.opcode.op;

pub const Step = enum { done, continue_loop };

pub fn binary(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    binop: u8,
    output: ?*std.Io.Writer,
    global: *core.Object,
) !void {
    const rhs = try stack.pop();
    defer rhs.free(ctx.runtime);
    const lhs = try stack.pop();
    defer lhs.free(ctx.runtime);
    if (lhs.asInt32()) |lhs_int| {
        if (rhs.asInt32()) |rhs_int| {
            if (fastBinaryInt32(binop, lhs_int, rhs_int)) |fast| {
                try stack.pushOwned(fast);
                return;
            }
        }
    }
    if (lhs.asShortBigInt()) |lhs_bigint| {
        if (rhs.asShortBigInt()) |rhs_bigint| {
            if (value_ops.shortBigIntBinary(binop, lhs_bigint, rhs_bigint)) |fast| {
                try stack.pushOwned(fast);
                return;
            }
        }
    }
    if (binop == op.add and ((lhs.isString() and !rhs.isObject()) or (rhs.isString() and !lhs.isObject()))) {
        const result = try value_ops.binary(ctx.runtime, binop, lhs, rhs);
        errdefer result.free(ctx.runtime);
        try stack.pushOwned(result);
        return;
    }
    const result = if (binop == op.add) blk: {
        const lhs_primitive = try coercion_ops.toPrimitiveForAddition(ctx, output, global, lhs);
        defer lhs_primitive.free(ctx.runtime);
        const rhs_primitive = try coercion_ops.toPrimitiveForAddition(ctx, output, global, rhs);
        defer rhs_primitive.free(ctx.runtime);
        break :blk try value_ops.binary(ctx.runtime, binop, lhs_primitive, rhs_primitive);
    } else if (isBitwiseBinaryOp(binop) or isNumericBinaryOp(binop)) blk: {
        const lhs_primitive = try coercion_ops.toPrimitiveForNumber(ctx, output, global, lhs);
        defer lhs_primitive.free(ctx.runtime);
        if (lhs_primitive.isSymbol()) return error.TypeError;
        const rhs_primitive = try coercion_ops.toPrimitiveForNumber(ctx, output, global, rhs);
        defer rhs_primitive.free(ctx.runtime);
        if (rhs_primitive.isSymbol()) return error.TypeError;
        break :blk try value_ops.binary(ctx.runtime, binop, lhs_primitive, rhs_primitive);
    } else try value_ops.binary(ctx.runtime, binop, lhs, rhs);
    errdefer result.free(ctx.runtime);
    try stack.pushOwned(result);
}

pub noinline fn binaryVm(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    binop: u8,
    output: ?*std.Io.Writer,
    global: *core.Object,
) !Step {
    binary(ctx, stack, binop, output, global) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    return .done;
}

pub fn compare(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    cmp: u8,
    output: ?*std.Io.Writer,
    global: *core.Object,
) !void {
    const rhs = try stack.pop();
    defer rhs.free(ctx.runtime);
    const lhs = try stack.pop();
    defer lhs.free(ctx.runtime);
    if (lhs.asInt32()) |lhs_int| {
        if (rhs.asInt32()) |rhs_int| {
            const result = switch (cmp) {
                op.lt => lhs_int < rhs_int,
                op.lte => lhs_int <= rhs_int,
                op.gt => lhs_int > rhs_int,
                op.gte => lhs_int >= rhs_int,
                op.eq, op.strict_eq => lhs_int == rhs_int,
                op.neq, op.strict_neq => lhs_int != rhs_int,
                else => null,
            };
            if (result) |out| {
                try stack.pushOwned(core.JSValue.boolean(out));
                return;
            }
        }
    }
    if (lhs.asShortBigInt()) |lhs_bigint| {
        if (rhs.asShortBigInt()) |rhs_bigint| {
            if (fastCompareShortBigInt(cmp, lhs_bigint, rhs_bigint)) |out| {
                try stack.pushOwned(core.JSValue.boolean(out));
                return;
            }
        }
    }

    const result: core.JSValue = switch (cmp) {
        op.eq => core.JSValue.boolean(try looseEqualOp(ctx, output, global, lhs, rhs, 0)),
        op.neq => core.JSValue.boolean(!try looseEqualOp(ctx, output, global, lhs, rhs, 0)),
        op.strict_eq => value_ops.strictEqual(lhs, rhs),
        op.strict_neq => value_ops.strictNotEqual(lhs, rhs),
        else => blk: {
            const lhs_primitive = try coercion_ops.toPrimitiveForNumber(ctx, output, global, lhs);
            defer lhs_primitive.free(ctx.runtime);
            if (lhs_primitive.isSymbol()) return error.TypeError;
            const rhs_primitive = try coercion_ops.toPrimitiveForNumber(ctx, output, global, rhs);
            defer rhs_primitive.free(ctx.runtime);
            if (rhs_primitive.isSymbol()) return error.TypeError;
            break :blk try value_ops.compare(ctx.runtime, cmp, lhs_primitive, rhs_primitive);
        },
    };
    errdefer result.free(ctx.runtime);
    try stack.pushOwned(result);
}

pub noinline fn compareVm(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    cmp: u8,
    output: ?*std.Io.Writer,
    global: *core.Object,
) !Step {
    compare(ctx, stack, cmp, output, global) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    return .done;
}

/// Inline operand-stack fast path for two int32 operands of an arithmetic /
/// bitwise binary op. Identical semantics to `binary()`'s int32 branch (same
/// `fastBinaryInt32` helper, same overflow->float promotion), but operates in
/// place on the operand stack: no `binaryVm`/`binary` call frames, no
/// pop/defer-free traffic (int32 values are never refcounted). Returns false
/// (leaving the stack untouched) whenever either operand is not an int32, so
/// the caller falls through to the generic path. The `*2` (keep-receiver) and
/// string/object/bigint/coercion cases are entirely the generic path's job.
pub inline fn tryInt32Binary(stack: *stack_mod.Stack, binop: u8) bool {
    const n = stack.values.len;
    if (n < 2) return false;
    const lhs_int = stack.values[n - 2].asInt32() orelse return false;
    const rhs_int = stack.values[n - 1].asInt32() orelse return false;
    const result = fastBinaryInt32(binop, lhs_int, rhs_int) orelse return false;
    stack.values[n - 2] = result;
    stack.values = stack.values.ptr[0 .. n - 1];
    return true;
}

pub inline fn tryInt32BinaryWindow(base: [*]core.JSValue, sp_len: *usize, binop: u8) bool {
    const n = sp_len.*;
    if (n < 2) return false;
    const lhs_int = base[n - 2].asInt32() orelse return false;
    const rhs_int = base[n - 1].asInt32() orelse return false;
    const result = fastBinaryInt32(binop, lhs_int, rhs_int) orelse return false;
    base[n - 2] = result;
    sp_len.* = n - 1;
    return true;
}

/// Inline operand-stack fast path for two int32 operands of a comparison op.
/// Mirrors `compare()`'s int32 branch exactly (same per-op boolean switch).
/// Returns false untouched when either operand is not int32.
pub inline fn tryInt32Compare(stack: *stack_mod.Stack, cmp: u8) bool {
    const n = stack.values.len;
    if (n < 2) return false;
    const lhs_int = stack.values[n - 2].asInt32() orelse return false;
    const rhs_int = stack.values[n - 1].asInt32() orelse return false;
    const result = switch (cmp) {
        op.lt => lhs_int < rhs_int,
        op.lte => lhs_int <= rhs_int,
        op.gt => lhs_int > rhs_int,
        op.gte => lhs_int >= rhs_int,
        op.eq, op.strict_eq => lhs_int == rhs_int,
        op.neq, op.strict_neq => lhs_int != rhs_int,
        else => return false,
    };
    stack.values[n - 2] = core.JSValue.boolean(result);
    stack.values = stack.values.ptr[0 .. n - 1];
    return true;
}

pub inline fn tryInt32CompareWindow(base: [*]core.JSValue, sp_len: *usize, cmp: u8) bool {
    const n = sp_len.*;
    if (n < 2) return false;
    const lhs_int = base[n - 2].asInt32() orelse return false;
    const rhs_int = base[n - 1].asInt32() orelse return false;
    const result = switch (cmp) {
        op.lt => lhs_int < rhs_int,
        op.lte => lhs_int <= rhs_int,
        op.gt => lhs_int > rhs_int,
        op.gte => lhs_int >= rhs_int,
        op.eq, op.strict_eq => lhs_int == rhs_int,
        op.neq, op.strict_neq => lhs_int != rhs_int,
        else => return false,
    };
    base[n - 2] = core.JSValue.boolean(result);
    sp_len.* = n - 1;
    return true;
}

pub fn unary(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    opcode_id: u8,
    output: ?*std.Io.Writer,
    global: *core.Object,
) !void {
    const value = try stack.pop();
    defer value.free(ctx.runtime);

    const result: core.JSValue = blk: {
        if (value.asInt32()) |int_value| {
            switch (opcode_id) {
                op.plus => break :blk value,
                op.neg => break :blk value_ops.numberToValue(-@as(f64, @floatFromInt(int_value))),
                op.inc => break :blk value_ops.numberToValue(@as(f64, @floatFromInt(int_value)) + 1),
                op.dec => break :blk value_ops.numberToValue(@as(f64, @floatFromInt(int_value)) - 1),
                else => {},
            }
        }
        if (value.asShortBigInt()) |bigint_value| {
            if (value_ops.shortBigIntUnary(opcode_id, bigint_value)) |fast| break :blk fast;
        }
        if (opcode_id == op.neg or opcode_id == op.plus or opcode_id == op.inc or opcode_id == op.dec) {
            const primitive = try coercion_ops.toPrimitiveForNumber(ctx, output, global, value);
            defer primitive.free(ctx.runtime);
            if (primitive.isSymbol()) return error.TypeError;
            break :blk try value_ops.unary(ctx.runtime, opcode_id, primitive);
        }
        break :blk try value_ops.unary(ctx.runtime, opcode_id, value);
    };
    errdefer result.free(ctx.runtime);
    try stack.pushOwned(result);
}

pub noinline fn unaryVm(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    opcode_id: u8,
    output: ?*std.Io.Writer,
    global: *core.Object,
) !Step {
    unary(ctx, stack, opcode_id, output, global) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    return .done;
}

pub fn bitNot(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    output: ?*std.Io.Writer,
    global: *core.Object,
) !void {
    const value = try stack.pop();
    defer value.free(ctx.runtime);
    const primitive = try coercion_ops.toPrimitiveForNumber(ctx, output, global, value);
    defer primitive.free(ctx.runtime);
    const result = try value_ops.unary(ctx.runtime, op.not, primitive);
    errdefer result.free(ctx.runtime);
    try stack.pushOwned(result);
}

pub noinline fn bitNotVm(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    output: ?*std.Io.Writer,
    global: *core.Object,
) !Step {
    bitNot(ctx, stack, output, global) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    return .done;
}

pub fn postUpdate(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    opcode_id: u8,
    output: ?*std.Io.Writer,
    global: *core.Object,
) !void {
    const old = try stack.pop();
    defer old.free(ctx.runtime);
    if (old.asInt32()) |old_int| {
        const updated = switch (opcode_id) {
            op.post_inc => fastInt32Add(old_int, 1),
            op.post_dec => fastInt32Sub(old_int, 1),
            else => unreachable,
        };
        try stack.push(old);
        try stack.push(updated);
        return;
    }
    if (old.asShortBigInt()) |old_bigint| {
        if (value_ops.shortBigIntUnary(opcode_id, old_bigint)) |updated| {
            try stack.push(old);
            try stack.push(updated);
            return;
        }
    }
    const primitive = try coercion_ops.toPrimitiveForNumber(ctx, output, global, old);
    defer primitive.free(ctx.runtime);
    if (primitive.isSymbol()) return error.TypeError;
    const numeric_old = if (primitive.isBigInt()) primitive.dup() else try value_ops.toNumberValue(ctx.runtime, primitive);
    defer numeric_old.free(ctx.runtime);
    const updated = try value_ops.unary(ctx.runtime, opcode_id, numeric_old);
    defer updated.free(ctx.runtime);
    try stack.push(numeric_old);
    try stack.push(updated);
}

pub noinline fn postUpdateVm(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    opcode_id: u8,
    output: ?*std.Io.Writer,
    global: *core.Object,
) !Step {
    postUpdate(ctx, stack, opcode_id, output, global) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    return .done;
}

pub fn updateLocal(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    opcode_id: u8,
    output: ?*std.Io.Writer,
    sync_global_lexical_locals: bool,
) !void {
    if (frame.pc >= function.code.len) return error.InvalidBytecode;
    const idx: u16 = function.code[frame.pc];
    frame.pc += 1;
    if (idx >= frame.locals.len) return error.InvalidBytecode;

    const value = slot_ops.slotValueDup(frame.locals[idx]);
    defer value.free(ctx.runtime);
    if (value.asInt32()) |int_value| {
        const updated = switch (opcode_id) {
            op.inc_loc => fastInt32Add(int_value, 1),
            op.dec_loc => fastInt32Sub(int_value, 1),
            else => unreachable,
        };
        try slot_ops.setSlotValue(ctx, &frame.locals[idx], updated);
        try slot_ops.syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, idx, sync_global_lexical_locals);
        return;
    }
    if (value.asShortBigInt()) |bigint_value| {
        const op_id = switch (opcode_id) {
            op.inc_loc => op.inc,
            op.dec_loc => op.dec,
            else => unreachable,
        };
        if (value_ops.shortBigIntUnary(op_id, bigint_value)) |updated| {
            try slot_ops.setSlotValue(ctx, &frame.locals[idx], updated);
            try slot_ops.syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, idx, sync_global_lexical_locals);
            return;
        }
    }
    const primitive = try coercion_ops.toPrimitiveForNumber(ctx, output, global, value);
    defer primitive.free(ctx.runtime);
    if (primitive.isSymbol()) return error.TypeError;
    const op_id = switch (opcode_id) {
        op.inc_loc => op.inc,
        op.dec_loc => op.dec,
        else => unreachable,
    };
    const updated = try value_ops.unary(ctx.runtime, op_id, primitive);
    try slot_ops.setSlotValue(ctx, &frame.locals[idx], updated);
    try slot_ops.syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, idx, sync_global_lexical_locals);
}

pub noinline fn updateLocalVm(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    opcode_id: u8,
    output: ?*std.Io.Writer,
    sync_global_lexical_locals: bool,
) !Step {
    updateLocal(ctx, function, global, frame, opcode_id, output, sync_global_lexical_locals) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    return .done;
}

pub fn addLocal(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    output: ?*std.Io.Writer,
    sync_global_lexical_locals: bool,
) !void {
    if (frame.pc >= function.code.len) return error.InvalidBytecode;
    const idx: u16 = function.code[frame.pc];
    frame.pc += 1;
    if (idx >= frame.locals.len) return error.InvalidBytecode;

    const rhs = try stack.pop();
    defer rhs.free(ctx.runtime);

    const cell_opt = slot_ops.varRefCellFromValue(frame.locals[idx]);
    const lhs_borrowed = if (cell_opt) |cell| cell.varRefValue() else frame.locals[idx];
    if (lhs_borrowed.isString()) {
        const lhs = slot_ops.slotValueDup(frame.locals[idx]);
        defer lhs.free(ctx.runtime);

        const rhs_primitive = try coercion_ops.toPrimitiveForAddition(ctx, output, global, rhs);
        defer rhs_primitive.free(ctx.runtime);

        // QuickJS OP_add_loc appends into the local's string storage when the
        // accumulator is unshared. Reference accounting: the local slot plus
        // our dup hold two references, and a
        // synced top-level global-lexical mirror may hold a third reference to
        // the same accumulator. This keeps `s += part` loops on a flat
        // growable buffer instead of chaining rope nodes per iteration.
        if (cell_opt == null and rhs_primitive.isString()) {
            const has_global_sync_mirror =
                sync_global_lexical_locals and
                frame.global_lexical_sync_checked and
                idx < frame.global_lexical_sync_slots.len and
                frame.global_lexical_sync_slots[idx];
            const max_ref_count: usize = if (has_global_sync_mirror) 3 else 2;
            if (try value_ops.tryAppendStringInPlace(ctx.runtime, lhs, rhs_primitive, max_ref_count)) {
                try slot_ops.syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, idx, sync_global_lexical_locals);
                return;
            }
        }

        const updated = try value_ops.binary(ctx.runtime, op.add, lhs, rhs_primitive);

        try slot_ops.setSlotValue(ctx, &frame.locals[idx], updated);
        try slot_ops.syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, idx, sync_global_lexical_locals);
        return;
    }

    const lhs = slot_ops.slotValueDup(frame.locals[idx]);
    defer lhs.free(ctx.runtime);
    if (lhs.asInt32()) |lhs_int| {
        if (rhs.asInt32()) |rhs_int| {
            const updated = fastInt32Add(lhs_int, rhs_int);
            try slot_ops.setSlotValue(ctx, &frame.locals[idx], updated);
            try slot_ops.syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, idx, sync_global_lexical_locals);
            return;
        }
    }
    if (lhs.asShortBigInt()) |lhs_bigint| {
        if (rhs.asShortBigInt()) |rhs_bigint| {
            if (value_ops.shortBigIntBinary(op.add, lhs_bigint, rhs_bigint)) |updated| {
                try slot_ops.setSlotValue(ctx, &frame.locals[idx], updated);
                try slot_ops.syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, idx, sync_global_lexical_locals);
                return;
            }
        }
    }

    const lhs_primitive = try coercion_ops.toPrimitiveForAddition(ctx, output, global, lhs);
    defer lhs_primitive.free(ctx.runtime);
    const rhs_primitive = try coercion_ops.toPrimitiveForAddition(ctx, output, global, rhs);
    defer rhs_primitive.free(ctx.runtime);
    const updated = try value_ops.binary(ctx.runtime, op.add, lhs_primitive, rhs_primitive);
    try slot_ops.setSlotValue(ctx, &frame.locals[idx], updated);
    try slot_ops.syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, idx, sync_global_lexical_locals);
}

pub noinline fn addLocalVm(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    output: ?*std.Io.Writer,
    sync_global_lexical_locals: bool,
) !Step {
    addLocal(ctx, stack, function, global, frame, output, sync_global_lexical_locals) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    return .done;
}

/// Fuses `add; dup? put_var s; (put_locN | drop)?` when the add is a string
/// append whose stack lhs *is* the global data slot's current value: the
/// known references are that slot, the stack copy this fusion pops, and
/// (when the previous statement's completion local still holds the
/// accumulator) the completion slot — all aliases of the accumulator the
/// pattern overwrites. The append then extends lhs storage in place (flat
/// capacity append or rope tail append) instead of copying or chaining a
/// rope node per iteration, keeping top-level `s += part` loops O(1) per
/// step in nodes and bytes.
fn canFuseGlobalDataWrite(
    function: *const bytecode.Bytecode,
    frame: *const frame_mod.Frame,
    atom_id: core.Atom,
    eval_local_names: []const core.Atom,
    eval_var_ref_names: []const core.Atom,
    eval_with_object: core.JSValue,
) bool {
    if (!eval_with_object.isUndefined()) return false;
    if (!frame.current_function.isUndefined()) return false;
    if (frameHasVarRefBinding(function, frame, atom_id)) return false;
    if (eval_local_names.len != 0 or eval_var_ref_names.len != 0) return false;
    if (frame.eval_local_names.len != 0 or frame.eval_var_ref_names.len != 0) return false;
    return true;
}

fn frameHasVarRefBinding(function: *const bytecode.Bytecode, frame: *const frame_mod.Frame, atom_id: core.Atom) bool {
    const count = @min(frame.var_refs.len, function.var_ref_names.len);
    for (function.var_ref_names[0..count]) |name| {
        if (name == atom_id) return true;
    }
    return false;
}

const ImmediateInt32 = struct {
    value: i32,
    next_pc: usize,
};

const LoopCondition = struct {
    limit: i32,
    body_pc: usize,
    exit_pc: usize,
};

const LocalLengthLoopCondition = struct {
    array_idx: u16,
    body_pc: usize,
    exit_pc: usize,
};

const ShortBigIntLoopCondition = struct {
    limit: i64,
    body_pc: usize,
    exit_pc: usize,
};

const LocalPut = struct {
    idx: u16,
    operand_pc: usize,
    consume: u8,
    checked: bool,
};

fn decodeLocalPut(code: []const u8, pc: usize) ?LocalPut {
    if (pc >= code.len) return null;
    return switch (code[pc]) {
        op.put_loc0 => .{ .idx = 0, .operand_pc = pc + 1, .consume = 0, .checked = false },
        op.put_loc1 => .{ .idx = 1, .operand_pc = pc + 1, .consume = 0, .checked = false },
        op.put_loc2 => .{ .idx = 2, .operand_pc = pc + 1, .consume = 0, .checked = false },
        op.put_loc3 => .{ .idx = 3, .operand_pc = pc + 1, .consume = 0, .checked = false },
        op.put_loc8 => blk: {
            if (pc + 2 > code.len) return null;
            break :blk .{ .idx = code[pc + 1], .operand_pc = pc + 1, .consume = 1, .checked = false };
        },
        op.put_loc => blk: {
            if (pc + 3 > code.len) return null;
            break :blk .{ .idx = std.mem.readInt(u16, code[pc + 1 ..][0..2], .little), .operand_pc = pc + 1, .consume = 2, .checked = false };
        },
        op.put_loc_check => blk: {
            if (pc + 3 > code.len) return null;
            break :blk .{ .idx = std.mem.readInt(u16, code[pc + 1 ..][0..2], .little), .operand_pc = pc + 1, .consume = 2, .checked = true };
        },
        else => null,
    };
}

fn parseCheckedLocalInt32LessThanImmediateCondition(code: []const u8, target_pc: usize, loop_idx: u16) ?LoopCondition {
    if (target_pc + 4 > code.len) return null;
    if (code[target_pc] != op.get_loc_check) return null;
    const cond_idx = std.mem.readInt(u16, code[target_pc + 1 ..][0..2], .little);
    if (cond_idx != loop_idx) return null;
    const rhs = immediateInt32Operand(code, target_pc + 3) orelse return null;
    if (rhs.next_pc + 3 > code.len) return null;
    if (code[rhs.next_pc] != op.lt or code[rhs.next_pc + 1] != op.if_false8) return null;
    const branch_operand_pc = rhs.next_pc + 2;
    const branch_diff: i8 = @bitCast(code[branch_operand_pc]);
    const exit_pc_i64 = @as(i64, @intCast(branch_operand_pc)) + @as(i64, branch_diff);
    if (exit_pc_i64 < 0) return null;
    return .{
        .limit = rhs.value,
        .body_pc = rhs.next_pc + 3,
        .exit_pc = @intCast(exit_pc_i64),
    };
}

fn parseCheckedLocalInt32LessThanLocalLengthCondition(code: []const u8, target_pc: usize, loop_idx: u16) ?LocalLengthLoopCondition {
    if (target_pc + 10 > code.len) return null;
    if (code[target_pc] != op.get_loc_check) return null;
    const cond_idx = std.mem.readInt(u16, code[target_pc + 1 ..][0..2], .little);
    if (cond_idx != loop_idx) return null;
    if (code[target_pc + 3] != op.get_loc_check) return null;
    const array_idx = std.mem.readInt(u16, code[target_pc + 4 ..][0..2], .little);
    if (code[target_pc + 6] != op.get_length or code[target_pc + 7] != op.lt or code[target_pc + 8] != op.if_false8) return null;
    const branch_operand_pc = target_pc + 9;
    const branch_diff: i8 = @bitCast(code[branch_operand_pc]);
    const exit_pc_i64 = @as(i64, @intCast(branch_operand_pc)) + @as(i64, branch_diff);
    if (exit_pc_i64 < 0) return null;
    return .{
        .array_idx = array_idx,
        .body_pc = target_pc + 10,
        .exit_pc = @intCast(exit_pc_i64),
    };
}

fn localArrayLengthI32(frame: *const frame_mod.Frame, array_idx: u16) ?i32 {
    if (array_idx >= frame.locals.len or array_idx >= frame.locals_uninit.len) return null;
    if (frame.localIsUninitialized(array_idx)) return null;
    const object = objectFromValue(frame.locals[array_idx]) orelse return null;
    if (object.proxyTarget() != null or object.hasExoticMethods() or !object.flags.is_array) return null;
    if (object.arrayLength() > @as(u32, @intCast(std.math.maxInt(i32)))) return null;
    return @intCast(object.arrayLength());
}

fn parseCheckedLocalShortBigIntLessThanImmediateCondition(code: []const u8, target_pc: usize, loop_idx: u16) ?ShortBigIntLoopCondition {
    if (target_pc + 11 > code.len) return null;
    if (code[target_pc] != op.get_loc_check) return null;
    const cond_idx = std.mem.readInt(u16, code[target_pc + 1 ..][0..2], .little);
    if (cond_idx != loop_idx) return null;
    if (code[target_pc + 3] != op.push_bigint_i32) return null;
    const limit: i64 = std.mem.readInt(i32, code[target_pc + 4 ..][0..4], .little);
    if (code[target_pc + 8] != op.lt or code[target_pc + 9] != op.if_false8) return null;
    const branch_operand_pc = target_pc + 10;
    const branch_diff: i8 = @bitCast(code[branch_operand_pc]);
    const exit_pc_i64 = @as(i64, @intCast(branch_operand_pc)) + @as(i64, branch_diff);
    if (exit_pc_i64 < 0) return null;
    return .{
        .limit = limit,
        .body_pc = target_pc + 11,
        .exit_pc = @intCast(exit_pc_i64),
    };
}

fn objectFromValue(value: core.JSValue) ?*core.Object {
    if (!value.isObject()) return null;
    const header = value.refHeader() orelse return null;
    return @fieldParentPtr("header", header);
}

fn immediateInt32Operand(code: []const u8, pc: usize) ?ImmediateInt32 {
    if (pc >= code.len) return null;
    return switch (code[pc]) {
        op.push_minus1 => .{ .value = -1, .next_pc = pc + 1 },
        op.push_0 => .{ .value = 0, .next_pc = pc + 1 },
        op.push_1 => .{ .value = 1, .next_pc = pc + 1 },
        op.push_2 => .{ .value = 2, .next_pc = pc + 1 },
        op.push_3 => .{ .value = 3, .next_pc = pc + 1 },
        op.push_4 => .{ .value = 4, .next_pc = pc + 1 },
        op.push_5 => .{ .value = 5, .next_pc = pc + 1 },
        op.push_6 => .{ .value = 6, .next_pc = pc + 1 },
        op.push_7 => .{ .value = 7, .next_pc = pc + 1 },
        op.push_i8 => blk: {
            if (pc + 2 > code.len) return null;
            const value: i8 = @bitCast(code[pc + 1]);
            break :blk .{ .value = value, .next_pc = pc + 2 };
        },
        op.push_i16 => blk: {
            if (pc + 3 > code.len) return null;
            break :blk .{ .value = std.mem.readInt(i16, code[pc + 1 ..][0..2], .little), .next_pc = pc + 3 };
        },
        op.push_i32 => blk: {
            if (pc + 5 > code.len) return null;
            break :blk .{ .value = std.mem.readInt(i32, code[pc + 1 ..][0..4], .little), .next_pc = pc + 5 };
        },
        else => null,
    };
}

pub fn fastBinaryInt32(binop: u8, lhs: i32, rhs: i32) ?core.JSValue {
    return switch (binop) {
        op.add => fastInt32Add(lhs, rhs),
        op.sub => fastInt32Sub(lhs, rhs),
        op.mul => fastInt32Mul(lhs, rhs),
        op.div => value_ops.numberToValue(@as(f64, @floatFromInt(lhs)) / @as(f64, @floatFromInt(rhs))),
        op.mod => fastInt32Mod(lhs, rhs),
        op.shl => core.JSValue.int32(lhs << @intCast(rhs & 31)),
        op.sar => core.JSValue.int32(lhs >> @intCast(rhs & 31)),
        op.shr => value_ops.numberToValue(@floatFromInt(@as(u32, @bitCast(lhs)) >> @intCast(rhs & 31))),
        op.@"and" => core.JSValue.int32(lhs & rhs),
        op.@"or" => core.JSValue.int32(lhs | rhs),
        op.xor => core.JSValue.int32(lhs ^ rhs),
        else => null,
    };
}

pub fn fastInt32Add(lhs: i32, rhs: i32) core.JSValue {
    const result = @addWithOverflow(lhs, rhs);
    if (result[1] == 0) return core.JSValue.int32(result[0]);
    return value_ops.numberToValue(@as(f64, @floatFromInt(lhs)) + @as(f64, @floatFromInt(rhs)));
}

pub fn fastInt32Sub(lhs: i32, rhs: i32) core.JSValue {
    const result = @subWithOverflow(lhs, rhs);
    if (result[1] == 0) return core.JSValue.int32(result[0]);
    return value_ops.numberToValue(@as(f64, @floatFromInt(lhs)) - @as(f64, @floatFromInt(rhs)));
}

fn fastInt32Mul(lhs: i32, rhs: i32) core.JSValue {
    if ((lhs == 0 and rhs < 0) or (rhs == 0 and lhs < 0)) return core.JSValue.float64(-0.0);
    const result = @mulWithOverflow(lhs, rhs);
    if (result[1] == 0) return core.JSValue.int32(result[0]);
    return value_ops.numberToValue(@as(f64, @floatFromInt(lhs)) * @as(f64, @floatFromInt(rhs)));
}

fn fastInt32Mod(lhs: i32, rhs: i32) core.JSValue {
    if (rhs == 0) return core.JSValue.float64(std.math.nan(f64));
    if (rhs == -1) return if (lhs < 0) core.JSValue.float64(-0.0) else core.JSValue.int32(0);
    const result = @rem(lhs, rhs);
    if (result == 0 and lhs < 0) return core.JSValue.float64(-0.0);
    return core.JSValue.int32(result);
}

fn fastCompareShortBigInt(cmp: u8, lhs: i64, rhs: i64) ?bool {
    return switch (cmp) {
        op.lt => lhs < rhs,
        op.lte => lhs <= rhs,
        op.gt => lhs > rhs,
        op.gte => lhs >= rhs,
        op.eq, op.strict_eq => lhs == rhs,
        op.neq, op.strict_neq => lhs != rhs,
        else => null,
    };
}

fn isBitwiseBinaryOp(binop: u8) bool {
    return binop == op.shl or binop == op.sar or binop == op.shr or
        binop == op.@"and" or binop == op.@"or" or binop == op.xor;
}

fn isNumericBinaryOp(binop: u8) bool {
    return binop == op.sub or binop == op.mul or binop == op.div or
        binop == op.mod or binop == op.pow;
}

fn looseEqualOp(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    lhs: core.JSValue,
    rhs: core.JSValue,
    depth: u8,
) !bool {
    if (depth > 8) return error.TypeError;
    if (sameLooseEqualityType(lhs, rhs)) return value_ops.strictEqual(lhs, rhs).asBool().?;
    if ((lhs.isNull() and rhs.isUndefined()) or (lhs.isUndefined() and rhs.isNull())) return true;
    if ((value_ops.isHTMLDDA(lhs) and (rhs.isNull() or rhs.isUndefined())) or
        ((lhs.isNull() or lhs.isUndefined()) and value_ops.isHTMLDDA(rhs))) return true;
    if (lhs.isNull() or lhs.isUndefined() or rhs.isNull() or rhs.isUndefined()) return false;

    if (lhs.isNumber() and rhs.isString()) {
        const number_rhs = try value_ops.toNumberValue(ctx.runtime, rhs);
        defer number_rhs.free(ctx.runtime);
        return looseEqualSameNumberTypes(lhs, number_rhs);
    }
    if (lhs.isString() and rhs.isNumber()) {
        const number_lhs = try value_ops.toNumberValue(ctx.runtime, lhs);
        defer number_lhs.free(ctx.runtime);
        return looseEqualSameNumberTypes(number_lhs, rhs);
    }
    if (lhs.isBigInt() and rhs.isString()) {
        var rhs_bigint = value_ops.parseStringToBigInt(ctx.runtime, rhs) catch return false;
        defer rhs_bigint.deinit();
        const rhs_value = try value_ops.createBigIntValue(ctx.runtime, rhs_bigint);
        defer rhs_value.free(ctx.runtime);
        return value_ops.strictEqual(lhs, rhs_value).asBool().?;
    }
    if (lhs.isString() and rhs.isBigInt()) {
        var lhs_bigint = value_ops.parseStringToBigInt(ctx.runtime, lhs) catch return false;
        defer lhs_bigint.deinit();
        const lhs_value = try value_ops.createBigIntValue(ctx.runtime, lhs_bigint);
        defer lhs_value.free(ctx.runtime);
        return value_ops.strictEqual(lhs_value, rhs).asBool().?;
    }
    if (lhs.isBool()) {
        const number_lhs = core.JSValue.int32(if (lhs.asBool().?) 1 else 0);
        return looseEqualOp(ctx, output, global, number_lhs, rhs, depth + 1);
    }
    if (rhs.isBool()) {
        const number_rhs = core.JSValue.int32(if (rhs.asBool().?) 1 else 0);
        return looseEqualOp(ctx, output, global, lhs, number_rhs, depth + 1);
    }
    if (lhs.isBigInt() and rhs.isNumber()) {
        const number_rhs = value_ops.numberValue(rhs) orelse return false;
        return value_ops.bigIntEqualsNumber(ctx.runtime, lhs, number_rhs);
    }
    if (lhs.isNumber() and rhs.isBigInt()) {
        const number_lhs = value_ops.numberValue(lhs) orelse return false;
        return value_ops.bigIntEqualsNumber(ctx.runtime, rhs, number_lhs);
    }
    if (isLoosePrimitiveForObject(lhs) and rhs.isObject()) {
        const primitive_rhs = try coercion_ops.toPrimitiveForAddition(ctx, output, global, rhs);
        defer primitive_rhs.free(ctx.runtime);
        return looseEqualOp(ctx, output, global, lhs, primitive_rhs, depth + 1);
    }
    if (lhs.isObject() and isLoosePrimitiveForObject(rhs)) {
        const primitive_lhs = try coercion_ops.toPrimitiveForAddition(ctx, output, global, lhs);
        defer primitive_lhs.free(ctx.runtime);
        return looseEqualOp(ctx, output, global, primitive_lhs, rhs, depth + 1);
    }
    return false;
}

fn sameLooseEqualityType(lhs: core.JSValue, rhs: core.JSValue) bool {
    if (lhs.isNumber() and rhs.isNumber()) return true;
    if (lhs.isString() and rhs.isString()) return true;
    if (lhs.isBool() and rhs.isBool()) return true;
    if (lhs.isBigInt() and rhs.isBigInt()) return true;
    if (lhs.isSymbol() and rhs.isSymbol()) return true;
    if (lhs.isObject() and rhs.isObject()) return true;
    if (lhs.isFunctionBytecode() and rhs.isFunctionBytecode()) return true;
    return lhs.tagOf() == rhs.tagOf();
}

fn isLoosePrimitiveForObject(value: core.JSValue) bool {
    return value.isNumber() or value.isString() or value.isBigInt() or value.isSymbol();
}

fn looseEqualSameNumberTypes(lhs: core.JSValue, rhs: core.JSValue) bool {
    const lhs_number = value_ops.numberValue(lhs) orelse return false;
    const rhs_number = value_ops.numberValue(rhs) orelse return false;
    if (std.math.isNan(lhs_number) or std.math.isNan(rhs_number)) return false;
    return lhs_number == rhs_number;
}

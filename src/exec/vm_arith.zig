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

pub fn binaryVm(
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

pub fn compareVm(
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

pub fn unaryVm(
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

pub fn bitNotVm(
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

pub fn postUpdateVm(
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

pub fn tryFuseDroppedCheckedLocalPostUpdateRead(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    idx: u16,
    opcode_id: u8,
    sync_global_lexical_locals: bool,
) !bool {
    const pc = frame.pc;
    if (pc + 5 > function.code.len) return false;
    if (function.code[pc + 1] != op.put_loc_check) return false;
    const store_idx = std.mem.readInt(u16, function.code[pc + 2 ..][0..2], .little);
    if (store_idx != idx) return false;
    if (function.code[pc + 4] != op.drop) return false;
    if (idx >= frame.locals.len or idx >= frame.locals_uninit.len) return false;
    if (frame.localIsUninitialized(idx)) return false;
    if (idx < function.var_is_const.len and function.var_is_const[idx]) return false;

    const old = frame.locals[idx];
    const updated = blk: {
        if (old.asInt32()) |old_int| {
            break :blk switch (opcode_id) {
                op.post_inc => fastInt32Add(old_int, 1),
                op.post_dec => fastInt32Sub(old_int, 1),
                else => return false,
            };
        }
        if (old.asShortBigInt()) |old_bigint| {
            if (value_ops.shortBigIntUnary(opcode_id, old_bigint)) |fast| break :blk fast;
        }
        return false;
    };
    try slot_ops.setSlotValue(ctx, &frame.locals[idx], updated);
    try slot_ops.syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, idx, sync_global_lexical_locals);
    frame.pc = pc + 5;
    return true;
}

pub fn tryFuseDroppedCheckedLocalPostUpdateReadAndGoto8Condition(
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    idx: u16,
    opcode_id: u8,
    sync_global_lexical_locals: bool,
) !bool {
    const pc = frame.pc;
    const code = function.code;
    if (pc + 7 > code.len) return false;
    if (code[pc + 1] != op.put_loc_check) return false;
    const store_idx = std.mem.readInt(u16, code[pc + 2 ..][0..2], .little);
    if (store_idx != idx) return false;
    if (code[pc + 4] != op.drop or code[pc + 5] != op.goto8) return false;
    if (idx >= frame.locals.len or idx >= frame.locals_uninit.len) return false;
    if (frame.localIsUninitialized(idx)) return false;
    if (idx < function.var_is_const.len and function.var_is_const[idx]) return false;

    const goto_operand_pc = pc + 6;
    const goto_diff: i8 = @bitCast(code[goto_operand_pc]);
    if (goto_diff >= 0) return false;
    const target_pc_i64 = @as(i64, @intCast(goto_operand_pc)) + @as(i64, goto_diff);
    if (target_pc_i64 < 0) return false;
    const target_pc: usize = @intCast(target_pc_i64);
    if (parseCheckedLocalInt32LessThanImmediateCondition(code, target_pc, idx)) |condition| {
        const old_int = frame.locals[idx].asInt32() orelse return false;
        if (opcode_id == op.post_inc and
            pc >= 3 and
            condition.body_pc == pc - 3 and
            ctx.runtime.opcode_profile == null and
            !ctx.runtime.hasInterruptHandler() and
            old_int < condition.limit)
        {
            try slot_ops.setSlotValue(ctx, &frame.locals[idx], core.JSValue.int32(condition.limit));
            try slot_ops.syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, idx, sync_global_lexical_locals);
            frame.pc = condition.exit_pc;
            return true;
        }

        const updated_int = switch (opcode_id) {
            op.post_inc => blk: {
                const updated = @addWithOverflow(old_int, 1);
                if (updated[1] != 0) return false;
                break :blk updated[0];
            },
            op.post_dec => blk: {
                const updated = @subWithOverflow(old_int, 1);
                if (updated[1] != 0) return false;
                break :blk updated[0];
            },
            else => return false,
        };

        try slot_ops.setSlotValue(ctx, &frame.locals[idx], core.JSValue.int32(updated_int));
        try slot_ops.syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, idx, sync_global_lexical_locals);
        frame.pc = if (updated_int < condition.limit) condition.body_pc else condition.exit_pc;
        return true;
    }

    if (parseCheckedLocalInt32LessThanLocalLengthCondition(code, target_pc, idx)) |condition| {
        const old_int = frame.locals[idx].asInt32() orelse return false;
        const limit = localArrayLengthI32(frame, condition.array_idx) orelse return false;
        const updated_int = switch (opcode_id) {
            op.post_inc => blk: {
                const updated = @addWithOverflow(old_int, 1);
                if (updated[1] != 0) return false;
                break :blk updated[0];
            },
            op.post_dec => blk: {
                const updated = @subWithOverflow(old_int, 1);
                if (updated[1] != 0) return false;
                break :blk updated[0];
            },
            else => return false,
        };

        try slot_ops.setSlotValue(ctx, &frame.locals[idx], core.JSValue.int32(updated_int));
        try slot_ops.syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, idx, sync_global_lexical_locals);
        frame.pc = if (updated_int < limit) condition.body_pc else condition.exit_pc;
        return true;
    }

    const condition = parseCheckedLocalShortBigIntLessThanImmediateCondition(code, target_pc, idx) orelse return false;
    const old_bigint = frame.locals[idx].asShortBigInt() orelse return false;
    const updated = value_ops.shortBigIntUnary(opcode_id, old_bigint) orelse return false;
    const updated_bigint = updated.asShortBigInt() orelse return false;
    try slot_ops.setSlotValue(ctx, &frame.locals[idx], updated);
    try slot_ops.syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, idx, sync_global_lexical_locals);
    frame.pc = if (updated_bigint < condition.limit) condition.body_pc else condition.exit_pc;
    return true;
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

pub fn updateLocalVm(
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
    const lhs_borrowed = if (cell_opt) |cell| (cell.varRefValueSlot().* orelse core.JSValue.undefinedValue()) else frame.locals[idx];
    if (lhs_borrowed.isString()) {
        const lhs = slot_ops.slotValueDup(frame.locals[idx]);
        defer lhs.free(ctx.runtime);

        const rhs_primitive = try coercion_ops.toPrimitiveForAddition(ctx, output, global, rhs);
        defer rhs_primitive.free(ctx.runtime);

        // QuickJS OP_add_loc appends into the local's string storage when the
        // accumulator is unshared. Mirror tryFuseLocalStringAppend's reference
        // accounting: the local slot plus our dup hold two references, and a
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

pub fn addLocalVm(
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

pub fn tryFuseLocalStringAppend(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    sync_global_lexical_locals: bool,
) !bool {
    const code = function.code;
    var store_pc = frame.pc;
    var drop_pc: ?usize = null;
    var completion_store: ?LocalPut = null;
    if (store_pc < code.len and code[store_pc] == op.dup) {
        store_pc += 1;
        const decoded_store = decodeLocalPut(code, store_pc) orelse return false;
        const candidate_next_pc = decoded_store.operand_pc + decoded_store.consume;
        if (candidate_next_pc < code.len and code[candidate_next_pc] == op.drop) {
            drop_pc = candidate_next_pc;
        } else {
            const candidate_completion = decodeLocalPut(code, candidate_next_pc) orelse return false;
            if (candidate_completion.idx >= frame.locals.len or candidate_completion.idx >= frame.locals_uninit.len) return false;
            if (candidate_completion.checked) return false;
            if (candidate_completion.idx < function.var_is_lexical.len and function.var_is_lexical[candidate_completion.idx]) return false;
            if (slot_ops.varRefCellFromValue(frame.locals[candidate_completion.idx]) != null) return false;
            if (candidate_completion.idx < function.var_is_const.len and function.var_is_const[candidate_completion.idx]) return false;
            completion_store = candidate_completion;
        }
    }
    const store = decodeLocalPut(code, store_pc) orelse return false;
    const idx = store.idx;
    if (idx >= frame.locals.len or idx >= frame.locals_uninit.len) return false;
    if (frame.localIsUninitialized(idx)) return false;
    if (idx < function.var_is_const.len and function.var_is_const[idx]) return false;
    if (stack.values.len < 2) return false;

    const lhs = stack.values[stack.values.len - 2];
    const rhs = stack.values[stack.values.len - 1];
    if (!frame.locals[idx].same(lhs)) return false;
    const has_global_sync_mirror =
        sync_global_lexical_locals and
        frame.global_lexical_sync_checked and
        idx < frame.global_lexical_sync_slots.len and
        frame.global_lexical_sync_slots[idx];
    const has_completion_ref =
        completion_store != null and
        completion_store.?.idx != idx and
        completion_store.?.idx < frame.locals.len and
        frame.locals[completion_store.?.idx].same(lhs);
    const base_ref_count: usize = if (has_global_sync_mirror) 3 else 2;
    const max_ref_count = base_ref_count + @as(usize, @intFromBool(has_completion_ref));
    if (!try value_ops.tryAppendStringInPlace(ctx.runtime, lhs, rhs, max_ref_count)) return false;

    const rhs_owned = try stack.pop();
    const lhs_owned = try stack.pop();
    if (completion_store) |completion| {
        try slot_ops.setSlotValue(ctx, &frame.locals[completion.idx], lhs_owned.dup());
        try slot_ops.syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, completion.idx, sync_global_lexical_locals);
    }
    frame.pc = if (drop_pc) |drop|
        drop + 1
    else if (completion_store) |completion|
        completion.operand_pc + completion.consume
    else
        store.operand_pc + store.consume;
    rhs_owned.free(ctx.runtime);
    lhs_owned.free(ctx.runtime);
    try slot_ops.syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, idx, sync_global_lexical_locals);
    return true;
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
pub fn tryFuseGlobalStringAppend(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    sync_global_lexical_locals: bool,
    eval_local_names: []const core.Atom,
    eval_var_ref_names: []const core.Atom,
    eval_with_object: core.JSValue,
) !bool {
    const code = function.code;
    var store_pc = frame.pc;
    const has_dup = store_pc < code.len and code[store_pc] == op.dup;
    if (has_dup) store_pc += 1;
    if (store_pc + 5 > code.len or code[store_pc] != op.put_var) return false;
    const atom_id = std.mem.readInt(u32, code[store_pc + 1 ..][0..4], .little);
    var next_pc = store_pc + 5;
    var completion_store: ?LocalPut = null;
    if (has_dup) {
        // The duplicated result must be consumed right after the global
        // store: either dropped or kept as the statement completion local.
        if (next_pc < code.len and code[next_pc] == op.drop) {
            next_pc += 1;
        } else {
            const candidate = decodeLocalPut(code, next_pc) orelse return false;
            if (candidate.checked) return false;
            if (candidate.idx >= frame.locals.len or candidate.idx >= frame.locals_uninit.len) return false;
            if (candidate.idx < function.var_is_lexical.len and function.var_is_lexical[candidate.idx]) return false;
            if (slot_ops.varRefCellFromValue(frame.locals[candidate.idx]) != null) return false;
            if (candidate.idx < function.var_is_const.len and function.var_is_const[candidate.idx]) return false;
            completion_store = candidate;
            next_pc = candidate.operand_pc + candidate.consume;
        }
    }
    if (!canFuseGlobalDataWrite(function, frame, atom_id, eval_local_names, eval_var_ref_names, eval_with_object)) return false;
    if (atom_id == core.atom.ids.undefined_ or atom_id == core.atom.ids.arguments) return false;
    if (ctx.lexicals) |env| {
        if (env.hasOwnProperty(atom_id)) return false;
    }
    if (stack.values.len < 2) return false;
    const lhs = stack.values[stack.values.len - 2];
    const rhs = stack.values[stack.values.len - 1];
    if (!lhs.isString() or !rhs.isString()) return false;

    // The in-place append is only sound when the stack lhs aliases the
    // global accumulator: probe the slot for identity, then prove it is a
    // plain writable data property via a no-op re-store *before* mutating
    // lhs (a failed store afterwards would corrupt the generic re-add
    // fallback, which would see an lhs that already contains rhs).
    const slot_is_lhs = alias: {
        const slot_value = global.getOwnDataPropertyValue(atom_id) orelse break :alias false;
        defer slot_value.free(ctx.runtime);
        break :alias slot_value.same(lhs);
    };
    if (!slot_is_lhs) return false;
    if (!try global.setOwnWritableDataProperty(ctx.runtime, atom_id, lhs)) return false;

    const has_completion_ref =
        completion_store != null and
        frame.locals[completion_store.?.idx].same(lhs);
    const max_ref_count: usize = 2 + @as(usize, @intFromBool(has_completion_ref));
    if (!try value_ops.tryAppendStringInPlace(ctx.runtime, lhs, rhs, max_ref_count)) return false;

    const rhs_owned = try stack.pop();
    const lhs_owned = try stack.pop();
    if (completion_store) |completion| {
        try slot_ops.setSlotValue(ctx, &frame.locals[completion.idx], lhs_owned.dup());
        try slot_ops.syncTopLevelGlobalLexicalLocal(ctx, function, global, frame, completion.idx, sync_global_lexical_locals);
    }
    frame.pc = next_pc;
    rhs_owned.free(ctx.runtime);
    lhs_owned.free(ctx.runtime);
    return true;
}

pub fn tryFuseGlobalDataAdd(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    eval_local_names: []const core.Atom,
    eval_var_ref_names: []const core.Atom,
    eval_with_object: core.JSValue,
) !bool {
    if (frame.pc + 5 > function.code.len) return false;
    if (function.code[frame.pc] != op.put_var) return false;
    const atom_id = std.mem.readInt(u32, function.code[frame.pc + 1 ..][0..4], .little);
    if (!canFuseGlobalDataWrite(function, frame, atom_id, eval_local_names, eval_var_ref_names, eval_with_object)) return false;
    if (atom_id == core.atom.ids.undefined_ or atom_id == core.atom.ids.arguments) return false;
    if (ctx.lexicals) |env| {
        if (env.hasOwnProperty(atom_id)) return false;
    }
    if (stack.values.len < 2) return false;

    const lhs = stack.values[stack.values.len - 2];
    const rhs = stack.values[stack.values.len - 1];
    const updated = blk: {
        if (lhs.asInt32()) |lhs_int| {
            if (rhs.asInt32()) |rhs_int| break :blk fastInt32Add(lhs_int, rhs_int);
        }
        if (lhs.asShortBigInt()) |lhs_bigint| {
            if (rhs.asShortBigInt()) |rhs_bigint| {
                if (value_ops.shortBigIntBinary(op.add, lhs_bigint, rhs_bigint)) |fast| break :blk fast;
            }
        }
        if (lhs.isString() and rhs.isString()) {
            break :blk try value_ops.binary(ctx.runtime, op.add, lhs, rhs);
        }
        if (!lhs.isNumber() or !rhs.isNumber()) return false;
        break :blk try value_ops.binary(ctx.runtime, op.add, lhs, rhs);
    };
    errdefer updated.free(ctx.runtime);

    if (!try global.setOwnWritableDataProperty(ctx.runtime, atom_id, updated)) {
        updated.free(ctx.runtime);
        return false;
    }
    const rhs_owned = try stack.pop();
    const lhs_owned = try stack.pop();
    frame.pc += 5;
    updated.free(ctx.runtime);
    rhs_owned.free(ctx.runtime);
    lhs_owned.free(ctx.runtime);
    return true;
}

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
    if (object.proxyTarget() != null or object.exotic != null or !object.flags.is_array) return null;
    if (object.length > @as(u32, @intCast(std.math.maxInt(i32)))) return null;
    return @intCast(object.length);
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

fn fastBinaryInt32(binop: u8, lhs: i32, rhs: i32) ?core.JSValue {
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

fn fastInt32Add(lhs: i32, rhs: i32) core.JSValue {
    const result = @addWithOverflow(lhs, rhs);
    if (result[1] == 0) return core.JSValue.int32(result[0]);
    return value_ops.numberToValue(@as(f64, @floatFromInt(lhs)) + @as(f64, @floatFromInt(rhs)));
}

fn fastInt32Sub(lhs: i32, rhs: i32) core.JSValue {
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

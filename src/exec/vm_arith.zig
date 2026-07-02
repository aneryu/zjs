const std = @import("std");

const bytecode = @import("../bytecode.zig");
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

/// Register-resident slow compare (qjs OP_lt/OP_le/… → js_relational_slow /
/// js_eq_slow): takes the two operands BY VALUE and RETURNS the result, never
/// reading frame.pc or popping the stack — the dispatch handler keeps pc/sp in
/// registers and stores the result into sp[-2] itself, syncing only on the error
/// path. Reached only after op_compare's both-int32 fast path missed, so the body
/// is `compare`'s minus that arm (the float-vs-int / float-vs-float / object /
/// loose-eq cases). `lhs`/`rhs` are OWNED here (consumed via the defers / the
/// borrowing coercions, exactly as `compare`'s popped operands were).
pub fn compareAt(
    ctx: *core.JSContext,
    global: *core.Object,
    output: ?*std.Io.Writer,
    cmp: u8,
    lhs: core.JSValue,
    rhs: core.JSValue,
) !core.JSValue {
    defer rhs.free(ctx.runtime);
    defer lhs.free(ctx.runtime);
    // Number fast path — qjs js_relational_slow's `float64_compare` (both operands
    // already numeric ⇒ ToPrimitive is a no-op, so compare the doubles directly).
    // Covers the float-vs-int `x < n` that misses op_compare's both-int32 arm every
    // float-counter iteration, skipping toPrimitiveForNumber + value_ops.compare.
    switch (cmp) {
        op.lt, op.lte, op.gt, op.gte => {
            if (value_ops.numberValue(lhs)) |d1| {
                if (value_ops.numberValue(rhs)) |d2| {
                    const out = switch (cmp) {
                        op.lt => d1 < d2,
                        op.lte => d1 <= d2,
                        op.gt => d1 > d2,
                        op.gte => d1 >= d2,
                        else => unreachable,
                    };
                    return core.JSValue.boolean(out);
                }
            }
        },
        else => {},
    }
    if (lhs.asShortBigInt()) |lhs_bigint| {
        if (rhs.asShortBigInt()) |rhs_bigint| {
            if (fastCompareShortBigInt(cmp, lhs_bigint, rhs_bigint)) |out| {
                return core.JSValue.boolean(out);
            }
        }
    }
    return switch (cmp) {
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
    const ints = core.JSValue.asInt32Pair(stack.values[n - 2], stack.values[n - 1]) orelse return false;
    const result = fastBinaryInt32(binop, ints.lhs, ints.rhs) orelse return false;
    stack.values[n - 2] = result;
    stack.values = stack.values.ptr[0 .. n - 1];
    return true;
}

pub inline fn tryInt32BinaryWindow(base: [*]core.JSValue, sp_len: *usize, binop: u8) bool {
    const n = sp_len.*;
    if (n < 2) return false;
    const ints = core.JSValue.asInt32Pair(base[n - 2], base[n - 1]) orelse return false;
    const result = fastBinaryInt32(binop, ints.lhs, ints.rhs) orelse return false;
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
    const ints = core.JSValue.asInt32Pair(stack.values[n - 2], stack.values[n - 1]) orelse return false;
    const result = switch (cmp) {
        op.lt => ints.lhs < ints.rhs,
        op.lte => ints.lhs <= ints.rhs,
        op.gt => ints.lhs > ints.rhs,
        op.gte => ints.lhs >= ints.rhs,
        op.eq, op.strict_eq => ints.lhs == ints.rhs,
        op.neq, op.strict_neq => ints.lhs != ints.rhs,
        else => return false,
    };
    stack.values[n - 2] = core.JSValue.boolean(result);
    stack.values = stack.values.ptr[0 .. n - 1];
    return true;
}

pub inline fn tryInt32CompareWindow(base: [*]core.JSValue, sp_len: *usize, cmp: u8) bool {
    const n = sp_len.*;
    if (n < 2) return false;
    const ints = core.JSValue.asInt32Pair(base[n - 2], base[n - 1]) orelse return false;
    const result = switch (cmp) {
        op.lt => ints.lhs < ints.rhs,
        op.lte => ints.lhs <= ints.rhs,
        op.gt => ints.lhs > ints.rhs,
        op.gte => ints.lhs >= ints.rhs,
        op.eq, op.strict_eq => ints.lhs == ints.rhs,
        op.neq, op.strict_neq => ints.lhs != ints.rhs,
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
) !Step {
    updateLocal(ctx, function, global, frame, opcode_id, output) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    return .done;
}

/// Register-resident slow inc_loc/dec_loc (qjs OP_inc_loc/OP_dec_loc's non-int
/// branch), the unary analog of `addLocalAt`: it takes the local SLOT POINTER and
/// the opcode directly, never reading `frame.pc` or touching the stack, so the
/// dispatch handler keeps pc/sp in registers and skips the per-iteration frame.pc
/// memory round-trip. inc_loc/dec_loc are stack-neutral (they rewrite the local in
/// place), so there is nothing to pop. Body is `updateLocal`'s, re-parameterized on
/// (slot, opcode_id).
pub fn updateLocalAt(
    ctx: *core.JSContext,
    global: *core.Object,
    output: ?*std.Io.Writer,
    slot: *core.JSValue,
    opcode_id: u8,
) !void {
    // The int32/float64/short-bigint fast paths are non-refcounted and store through
    // setSlotValue (which frees any old refcounted value), so they read `slot.*`
    // WITHOUT a dup — qjs js_unary_arith_slow reads sp[-1] directly and JS_DupValue on
    // a number is a no-op. A var-ref cell (an eval `var x` boxed by a nested closure —
    // inc_loc is NOT non-captured in eval code) is an object, so it misses all three
    // and falls to the slow path below, which walks it via slotValueDup.
    const cur = slot.*;
    if (cur.asInt32()) |int_value| {
        const updated = switch (opcode_id) {
            op.inc_loc => fastInt32Add(int_value, 1),
            op.dec_loc => fastInt32Sub(int_value, 1),
            else => unreachable,
        };
        try slot_ops.setSlotValue(ctx, slot, updated);
        return;
    }
    // Float64 fast path — qjs js_unary_arith_slow's `if (FLOAT64) goto handle_float64`
    // (d ± 1 → bare __JS_NewFloat64, no int32 renormalization). Skips the generic
    // toPrimitiveForNumber + value_ops.unary dispatch on every float-counter `x++`.
    if (cur.asFloat64()) |d| {
        const updated = switch (opcode_id) {
            op.inc_loc => d + 1,
            op.dec_loc => d - 1,
            else => unreachable,
        };
        try slot_ops.setSlotValue(ctx, slot, core.JSValue.float64(updated));
        return;
    }
    if (cur.asShortBigInt()) |bigint_value| {
        const op_id = switch (opcode_id) {
            op.inc_loc => op.inc,
            op.dec_loc => op.dec,
            else => unreachable,
        };
        if (value_ops.shortBigIntUnary(op_id, bigint_value)) |updated| {
            try slot_ops.setSlotValue(ctx, slot, updated);
            return;
        }
    }
    // Object / heap-bigint / var-ref-cell slow path: slotValueDup walks a cell (eval
    // boxed var) to its value and dups, so user coercion (valueOf) cannot free the
    // accumulator underneath us (qjs OP_inc_loc's `op1 = JS_DupValue(op1)`).
    const value = slot_ops.slotValueDup(slot.*);
    defer value.free(ctx.runtime);
    const primitive = try coercion_ops.toPrimitiveForNumber(ctx, output, global, value);
    defer primitive.free(ctx.runtime);
    if (primitive.isSymbol()) return error.TypeError;
    const op_id = switch (opcode_id) {
        op.inc_loc => op.inc,
        op.dec_loc => op.dec,
        else => unreachable,
    };
    const updated = try value_ops.unary(ctx.runtime, op_id, primitive);
    try slot_ops.setSlotValue(ctx, slot, updated);
}

pub fn addLocal(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    output: ?*std.Io.Writer,
) !void {
    if (frame.pc >= function.code.len) return error.InvalidBytecode;
    const idx: u16 = function.code[frame.pc];
    frame.pc += 1;
    if (idx >= frame.locals.len) return error.InvalidBytecode;

    const rhs = try stack.pop();
    // rhs ownership transfers onward: the string and number slow paths consume it
    // via toPrimitiveForAdditionFree (qjs JS_ToPrimitiveFree). The int32/bigint
    // fast paths only ever see non-refcounted operands, so their early returns
    // leave nothing to free.

    const cell_opt = slot_ops.varRefCellFromValue(frame.locals[idx]);
    const lhs_borrowed = if (cell_opt) |cell| cell.varRefValue() else frame.locals[idx];
    if (lhs_borrowed.isString()) {
        // Outlined: the string-append path carries its own JSValue temporaries
        // (dup'd accumulator + coerced rhs). Keeping them in a separate frame
        // stops them from inflating the hot number path's spill set — LLVM does
        // not coalesce the two branches' spill slots, so an inline string block
        // makes every float `s = s + i` iteration pay its stack frame.
        return addLocalString(ctx, output, global, frame, idx, rhs, cell_opt == null);
    }

    // Dup the local so user coercion (Symbol.toPrimitive/valueOf) cannot free it
    // underneath us. lhs is owned and is CONSUMED by the slow path below.
    const lhs = slot_ops.slotValueDup(frame.locals[idx]);
    if (lhs.asInt32()) |lhs_int| {
        if (rhs.asInt32()) |rhs_int| {
            const updated = fastInt32Add(lhs_int, rhs_int);
            try slot_ops.setSlotValue(ctx, &frame.locals[idx], updated);
            return; // both int32 — non-refcounted, nothing to free
        }
    }
    if (lhs.asShortBigInt()) |lhs_bigint| {
        if (rhs.asShortBigInt()) |rhs_bigint| {
            if (value_ops.shortBigIntBinary(op.add, lhs_bigint, rhs_bigint)) |updated| {
                try slot_ops.setSlotValue(ctx, &frame.locals[idx], updated);
                return; // both short big ints — non-refcounted, nothing to free
            }
        }
    }

    // Slow path: consume lhs and rhs into primitives with no second dup, mirroring
    // qjs js_add_slow's JS_ToPrimitiveFree(op1)/JS_ToPrimitiveFree(op2). For the
    // hot float case both are non-objects, so each call passes the value straight
    // through — one fewer live JSValue temporary per operand than a borrowing dup.
    const lhs_primitive = coercion_ops.toPrimitiveForAdditionFree(ctx, output, global, lhs) catch |err| {
        rhs.free(ctx.runtime);
        return err;
    };
    defer lhs_primitive.free(ctx.runtime);
    const rhs_primitive = try coercion_ops.toPrimitiveForAdditionFree(ctx, output, global, rhs);
    defer rhs_primitive.free(ctx.runtime);

    // js_add_slow general path: two JS_TAG_INT operands take the int32 path
    // (overflow→float); any float operand falls to ToFloat64 + bare __JS_NewFloat64
    // with NO int32 renormalization. The hot loop is float+int, so `isInt`
    // short-circuits to the bare box. value_ops.binary is reached only for the cold
    // (string-via-coercion / BigInt / bool / null) operand combinations.
    if (value_ops.numberValue(lhs_primitive)) |d1| {
        if (value_ops.numberValue(rhs_primitive)) |d2| {
            const sum = d1 + d2;
            // Store directly in each arm rather than merging into one `updated`
            // value: LLVM materializes the 16-byte select/phi in a stack temp and
            // then copies temp→slot, a SIMD round-trip every iteration. Two direct
            // stores keep the result in registers to the slot.
            if (lhs_primitive.isInt() and rhs_primitive.isInt()) {
                try slot_ops.setSlotValue(ctx, &frame.locals[idx], value_ops.numberToValue(sum));
            } else {
                try slot_ops.setSlotValue(ctx, &frame.locals[idx], core.JSValue.float64(sum));
            }
            return;
        }
    }
    const updated = try value_ops.binary(ctx.runtime, op.add, lhs_primitive, rhs_primitive);
    try slot_ops.setSlotValue(ctx, &frame.locals[idx], updated);
}

/// String-accumulator branch of `addLocal`, outlined so its JSValue temporaries
/// live in their own frame and never inflate the hot number path's spill set.
/// `rhs` is CONSUMED here (toPrimitiveForAdditionFree); the caller transfers
/// ownership and does not free it.
noinline fn addLocalString(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    frame: *frame_mod.Frame,
    idx: u16,
    rhs: core.JSValue,
    cell_is_null: bool,
) !void {
    const lhs = slot_ops.slotValueDup(frame.locals[idx]);
    defer lhs.free(ctx.runtime);

    const rhs_primitive = try coercion_ops.toPrimitiveForAdditionFree(ctx, output, global, rhs);
    defer rhs_primitive.free(ctx.runtime);

    // QuickJS OP_add_loc appends into the local's string storage when the
    // accumulator is unshared. Reference accounting: the local slot plus our dup
    // hold exactly two references to the accumulator. This keeps `s += part`
    // loops on a flat growable buffer instead of chaining rope nodes per
    // iteration.
    if (cell_is_null and rhs_primitive.isString()) {
        if (try value_ops.tryAppendStringInPlace(ctx.runtime, lhs, rhs_primitive, 2)) {
            return;
        }
        if (try value_ops.startAccumulatorRope(ctx.runtime, lhs, rhs_primitive)) |rope_val| {
            try slot_ops.setSlotValue(ctx, &frame.locals[idx], rope_val);
            return;
        }
    }

    const updated = try value_ops.binary(ctx.runtime, op.add, lhs, rhs_primitive);
    try slot_ops.setSlotValue(ctx, &frame.locals[idx], updated);
}

pub noinline fn addLocalVm(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    output: ?*std.Io.Writer,
) !Step {
    addLocal(ctx, stack, function, global, frame, output) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    return .done;
}

/// Register-resident slow add for OP_add_loc, the faithful analog of qjs's
/// `js_add_loc_slow(ctx, pv, sp)`: it takes the local SLOT POINTER and the rhs
/// VALUE directly. Unlike `addLocal` it does NOT read `frame.pc` (the dispatch
/// handler already holds the operand in a register) and does NOT call
/// `stack.pop()` (the handler keeps sp register-resident, syncing only on the
/// error path). This removes the per-iteration `frame.pc` store→reload→store→reload
/// round-trip — `publish` (write frame.pc/stack.values) → `addLocal` (re-read
/// frame.pc for the operand) → `coldNext` (re-read frame.pc to re-dispatch) — that
/// serialized the dispatch critical path through memory; qjs keeps pc in a register
/// across the js_add_loc_slow call.
///
/// `rhs` is OWNED here: the string/number slow paths consume it (qjs
/// JS_ToPrimitiveFree); the int32/bigint fast paths only ever see non-refcounted
/// operands, so their early returns leave nothing to free. On every error path rhs
/// (or the primitive derived from it) is freed, so the caller publishes the popped
/// sp and the catch unwinder never double-frees the now-dead stack slot. The body
/// is byte-for-byte `addLocal`'s, only re-parameterized on (slot, rhs).
pub fn addLocalAt(
    ctx: *core.JSContext,
    global: *core.Object,
    output: ?*std.Io.Writer,
    slot: *core.JSValue,
    rhs: core.JSValue,
) !void {
    const cell_opt = slot_ops.varRefCellFromValue(slot.*);
    const lhs_borrowed = if (cell_opt) |cell| cell.varRefValue() else slot.*;
    if (lhs_borrowed.isString()) {
        return addLocalStringAt(ctx, output, global, slot, rhs, cell_opt == null);
    }

    const lhs = slot_ops.slotValueDup(slot.*);
    if (lhs.asInt32()) |lhs_int| {
        if (rhs.asInt32()) |rhs_int| {
            try slot_ops.setSlotValue(ctx, slot, fastInt32Add(lhs_int, rhs_int));
            return; // both int32 — non-refcounted, nothing to free
        }
    }
    if (lhs.asShortBigInt()) |lhs_bigint| {
        if (rhs.asShortBigInt()) |rhs_bigint| {
            if (value_ops.shortBigIntBinary(op.add, lhs_bigint, rhs_bigint)) |updated| {
                try slot_ops.setSlotValue(ctx, slot, updated);
                return; // both short big ints — non-refcounted, nothing to free
            }
        }
    }

    const lhs_primitive = coercion_ops.toPrimitiveForAdditionFree(ctx, output, global, lhs) catch |err| {
        rhs.free(ctx.runtime);
        return err;
    };
    defer lhs_primitive.free(ctx.runtime);
    const rhs_primitive = try coercion_ops.toPrimitiveForAdditionFree(ctx, output, global, rhs);
    defer rhs_primitive.free(ctx.runtime);

    if (value_ops.numberValue(lhs_primitive)) |d1| {
        if (value_ops.numberValue(rhs_primitive)) |d2| {
            const sum = d1 + d2;
            if (lhs_primitive.isInt() and rhs_primitive.isInt()) {
                try slot_ops.setSlotValue(ctx, slot, value_ops.numberToValue(sum));
            } else {
                try slot_ops.setSlotValue(ctx, slot, core.JSValue.float64(sum));
            }
            return;
        }
    }
    const updated = try value_ops.binary(ctx.runtime, op.add, lhs_primitive, rhs_primitive);
    try slot_ops.setSlotValue(ctx, slot, updated);
}

/// `addLocalString`'s slot-pointer analog (see `addLocalAt`).
noinline fn addLocalStringAt(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    slot: *core.JSValue,
    rhs: core.JSValue,
    cell_is_null: bool,
) !void {
    const lhs = slot_ops.slotValueDup(slot.*);
    defer lhs.free(ctx.runtime);

    const rhs_primitive = try coercion_ops.toPrimitiveForAdditionFree(ctx, output, global, rhs);
    defer rhs_primitive.free(ctx.runtime);

    if (cell_is_null and rhs_primitive.isString()) {
        if (try value_ops.tryAppendStringInPlace(ctx.runtime, lhs, rhs_primitive, 2)) {
            return;
        }
        if (try value_ops.startAccumulatorRope(ctx.runtime, lhs, rhs_primitive)) |rope_val| {
            try slot_ops.setSlotValue(ctx, slot, rope_val);
            return;
        }
    }

    const updated = try value_ops.binary(ctx.runtime, op.add, lhs, rhs_primitive);
    try slot_ops.setSlotValue(ctx, slot, updated);
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
    if (frame.evalLocalNames().len != 0 or frame.evalVarRefNames().len != 0) return false;
    return true;
}

fn frameHasVarRefBinding(function: *const bytecode.Bytecode, frame: *const frame_mod.Frame, atom_id: core.Atom) bool {
    const count = @min(frame.var_refs.len, function.varRefNamesLen());
    var idx: usize = 0;
    while (idx < count) : (idx += 1) {
        const name = function.varRefName(idx);
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
    if (array_idx >= frame.locals.len) return null;
    if (slot_ops.varRefSlotIsUninitialized(frame.locals[array_idx])) return null;
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
    // qjs-style int64-widen + range check (quickjs.c OP_add int path): avoids
    // @addWithOverflow's overflow-flag materialize + stack spill in the hot int32
    // path (the cset/strb [sp] LLVM emits). r is exact in f64 on the float fall-back.
    const r: i64 = @as(i64, lhs) + rhs;
    const r32: i32 = @truncate(r);
    if (r32 == r) return core.JSValue.int32(r32);
    return value_ops.numberToValue(@as(f64, @floatFromInt(r)));
}

pub fn fastInt32Sub(lhs: i32, rhs: i32) core.JSValue {
    const r: i64 = @as(i64, lhs) - rhs;
    const r32: i32 = @truncate(r);
    if (r32 == r) return core.JSValue.int32(r32);
    return value_ops.numberToValue(@as(f64, @floatFromInt(r)));
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

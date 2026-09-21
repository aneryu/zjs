//! Stack-VM opcode handlers and their helpers.
//!
//! Operand-stack / frame operations for arithmetic, control, calls,
//! literals, generators/async, eval/module, regexp literals, and `using`.
//! Property opcodes live in `vm_property.zig`.


const std = @import("std");

const bytecode = @import("../bytecode.zig");
const core = @import("../core/root.zig");
const frame_mod = @import("frame.zig");
const stack_mod = @import("stack.zig");
const value_ops = @import("value_ops.zig");
const call_runtime = @import("call_runtime.zig");
const coercion_ops = @import("value_ops.zig");

const dispatch = @import("tailcall_dispatch.zig");
const Vm = dispatch.Vm;
const HostError = @import("exception_ops.zig").HostError;
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
    const lhs = try stack.pop();
    // The two pops above guarantee capacity for one push, and none of the
    // fast legs below run user code that could touch the operand stack in
    // between — mirror qjs js_add_slow/js_binary_arith_slow writing the
    // result straight to sp[-2] with no capacity check (quickjs.c,
    // The coercing tail below keeps the checked push: toPrimitive
    // re-enters user code.
    if (lhs.as(.int)) |lhs_int| {
        if (rhs.as(.int)) |rhs_int| {
            if (fastBinaryInt32(binop, lhs_int, rhs_int)) |fast| {
                stack.pushOwnedAssumeCapacity(fast);
                return;
            }
        }
    }
    if (lhs.as(.short_big_int)) |lhs_bigint| {
        if (rhs.as(.short_big_int)) |rhs_bigint| {
            if (value_ops.shortBigIntBinary(binop, lhs_bigint, rhs_bigint)) |fast| {
                stack.pushOwnedAssumeCapacity(fast);
                return;
            }
        }
    }
    if (binop == op.add and ((lhs.isString() and !rhs.is(.object)) or (rhs.isString() and !lhs.is(.object)))) {
        const result = try value_ops.binary(ctx.runtime, binop, lhs, rhs);
        stack.pushOwnedAssumeCapacity(result);
        return;
    }
    const result = if (binop == op.add) blk: {
        const lhs_primitive = try coercion_ops.toPrimitiveForAddition(ctx, output, global, lhs);
        const rhs_primitive = try coercion_ops.toPrimitiveForAddition(ctx, output, global, rhs);
        break :blk try value_ops.binary(ctx.runtime, binop, lhs_primitive, rhs_primitive);
    } else if (isBitwiseBinaryOp(binop) or isNumericBinaryOp(binop)) blk: {
        const lhs_primitive = try coercion_ops.toPrimitiveForNumber(ctx, output, global, lhs);
        if (lhs_primitive.is(.symbol)) return error.TypeError;
        const rhs_primitive = try coercion_ops.toPrimitiveForNumber(ctx, output, global, rhs);
        if (rhs_primitive.is(.symbol)) return error.TypeError;
        break :blk try value_ops.binary(ctx.runtime, binop, lhs_primitive, rhs_primitive);
    } else try value_ops.binary(ctx.runtime, binop, lhs, rhs);
    try stack.pushOwned(result);
}

pub noinline fn binaryVm(vm: *Vm, opc: u8) HostError!void {
    binary(vm.ctx, vm.stack, opc, vm.output, vm.global) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(vm.ctx, vm.output, vm.stack, vm.frame, vm.catch_target, vm.global, err)) return;
        return err;
    };
}

pub fn compare(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    cmp: u8,
    output: ?*std.Io.Writer,
    global: *core.Object,
) !void {
    const rhs = try stack.pop();
    const lhs = try stack.pop();
    if (lhs.as(.int)) |lhs_int| {
        if (rhs.as(.int)) |rhs_int| {
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
    if (lhs.as(.short_big_int)) |lhs_bigint| {
        if (rhs.as(.short_big_int)) |rhs_bigint| {
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
            if (lhs_primitive.is(.symbol)) return error.TypeError;
            const rhs_primitive = try coercion_ops.toPrimitiveForNumber(ctx, output, global, rhs);
            if (rhs_primitive.is(.symbol)) return error.TypeError;
            break :blk try value_ops.compare(ctx.runtime, cmp, lhs_primitive, rhs_primitive);
        },
    };
    try stack.pushOwned(result);
}

pub noinline fn compareVm(vm: *Vm, opc: u8) HostError!void {
    compare(vm.ctx, vm.stack, opc, vm.output, vm.global) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(vm.ctx, vm.output, vm.stack, vm.frame, vm.catch_target, vm.global, err)) return;
        return err;
    };
}

/// Register-resident slow compare (qjs OP_lt/OP_le/… → js_relational_slow /
/// js_eq_slow): takes the two operands BY VALUE and RETURNS the result, never
/// reading frame.pc or popping the stack — the dispatch handler keeps pc/sp in
/// registers and stores the result into sp[-2] itself, syncing only on the error
/// path. Reached only after opCompare's both-int32 fast path missed, so the body
/// is `compare`'s minus that arm (the float-vs-int / float-vs-float / object /
/// loose-eq cases). `lhs`/`rhs` are OWNED here (consumed via the defers / the
/// borrowing coercions, exactly as `compare`'s popped operands were).
///
/// `cmp` is COMPTIME — qjs reaches its slow calls from independent CASE labels
/// (`js_relational_slow(ctx, sp, opcode)` at quickjs.c vs
/// `js_eq_slow(ctx, sp, inv)` at 20330), so no qjs slow path ever selects its
/// predicate at run time. With a runtime `u8` here every eq-family call still
/// evaluated the relational float leg's switch and every relational call still
/// evaluated the eq dispatch; both legs measured ZERO hits from the other family's
/// traffic. Specializing folds each caller down to only its own arms.
pub fn compareAt(
    comptime cmp: u8,
    ctx: *core.JSContext,
    global: *core.Object,
    output: ?*std.Io.Writer,
    lhs: core.JSValue,
    rhs: core.JSValue,
) !core.JSValue {
    // Number fast path — qjs js_relational_slow's `float64_compare` (both operands
    // already numeric ⇒ ToPrimitive is a no-op, so compare the doubles directly).
    // Covers the float-vs-int `x < n` that misses opCompare's both-int32 arm every
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
    if (lhs.as(.short_big_int)) |lhs_bigint| {
        if (rhs.as(.short_big_int)) |rhs_bigint| {
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
            // qjs JS_ToPrimitiveFree on a non-object returns it as-is with no
            // refcount change (move semantics). zjs's toPrimitiveForNumber is
            // borrow-in/owned-out, so it dups — costing 2 retain + 2 release
            // per string comparison that qjs doesn't pay. For non-object
            // operands (the common case: string/string, string/number),
            // ToPrimitive is identity, so skip it and pass the already-owned
            // operands directly to compare. Objects still need the full
            // ToPrimitive path (valueOf/toString can run user code).
            if (lhs.is(.object) or rhs.is(.object)) {
                const lhs_primitive = try coercion_ops.toPrimitiveForNumber(ctx, output, global, lhs);
                if (lhs_primitive.is(.symbol)) return error.TypeError;
                const rhs_primitive = try coercion_ops.toPrimitiveForNumber(ctx, output, global, rhs);
                if (rhs_primitive.is(.symbol)) return error.TypeError;
                break :blk try value_ops.compare(ctx.runtime, cmp, lhs_primitive, rhs_primitive);
            }
            if (lhs.is(.symbol) or rhs.is(.symbol)) return error.TypeError;
            break :blk try value_ops.compare(ctx.runtime, cmp, lhs, rhs);
        },
    };
}

pub fn unary(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    opcode_id: u8,
    output: ?*std.Io.Writer,
    global: *core.Object,
) !void {
    const value = try stack.pop();

    const result: core.JSValue = blk: {
        if (value.as(.int)) |int_value| {
            switch (opcode_id) {
                op.to_number => break :blk value,
                op.neg => break :blk value_ops.numberToValue(-@as(f64, @floatFromInt(int_value))),
                op.inc => break :blk value_ops.numberToValue(@as(f64, @floatFromInt(int_value)) + 1),
                op.dec => break :blk value_ops.numberToValue(@as(f64, @floatFromInt(int_value)) - 1),
                else => {},
            }
        }
        if (value.as(.short_big_int)) |bigint_value| {
            if (value_ops.shortBigIntUnary(opcode_id, bigint_value)) |fast| break :blk fast;
        }
        if (opcode_id == op.neg or opcode_id == op.to_number or opcode_id == op.inc or opcode_id == op.dec) {
            const primitive = try coercion_ops.toPrimitiveForNumber(ctx, output, global, value);
            if (primitive.is(.symbol)) return error.TypeError;
            break :blk try value_ops.unary(ctx.runtime, opcode_id, primitive);
        }
        break :blk try value_ops.unary(ctx.runtime, opcode_id, value);
    };
    try stack.pushOwned(result);
}

pub noinline fn unaryVm(vm: *Vm, opc: u8) HostError!void {
    unary(vm.ctx, vm.stack, opc, vm.output, vm.global) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(vm.ctx, vm.output, vm.stack, vm.frame, vm.catch_target, vm.global, err)) return;
        return err;
    };
}

pub fn bitNot(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    output: ?*std.Io.Writer,
    global: *core.Object,
) !void {
    const value = try stack.pop();
    const primitive = try coercion_ops.toPrimitiveForNumber(ctx, output, global, value);
    const result = try value_ops.unary(ctx.runtime, op.not, primitive);
    try stack.pushOwned(result);
}

pub noinline fn bitNotVm(vm: *Vm) HostError!void {
    bitNot(vm.ctx, vm.stack, vm.output, vm.global) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(vm.ctx, vm.output, vm.stack, vm.frame, vm.catch_target, vm.global, err)) return;
        return err;
    };
}

pub fn postUpdate(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    opcode_id: u8,
    output: ?*std.Io.Writer,
    global: *core.Object,
) !void {
    const old = try stack.pop();
    if (old.as(.int)) |old_int| {
        const updated = switch (opcode_id) {
            op.post_inc => fastInt32Add(old_int, 1),
            op.post_dec => fastInt32Sub(old_int, 1),
            else => unreachable,
        };
        try stack.push(old);
        try stack.push(updated);
        return;
    }
    if (old.as(.short_big_int)) |old_bigint| {
        if (value_ops.shortBigIntUnary(opcode_id, old_bigint)) |updated| {
            try stack.push(old);
            try stack.push(updated);
            return;
        }
    }
    const primitive = try coercion_ops.toPrimitiveForNumber(ctx, output, global, old);
    if (primitive.is(.symbol)) return error.TypeError;
    const numeric_old = if (primitive.isBigInt()) primitive else try value_ops.toNumberValue(ctx.runtime, primitive);
    const updated = try value_ops.unary(ctx.runtime, opcode_id, numeric_old);
    try stack.push(numeric_old);
    try stack.push(updated);
}

pub noinline fn postUpdateVm(vm: *Vm, opc: u8) HostError!void {
    postUpdate(vm.ctx, vm.stack, opc, vm.output, vm.global) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(vm.ctx, vm.output, vm.stack, vm.frame, vm.catch_target, vm.global, err)) return;
        return err;
    };
}

pub fn updateLocal(
    ctx: *core.JSContext,
    function: *const bytecode.FunctionBytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    opcode_id: u8,
    output: ?*std.Io.Writer,
) !void {
    if (frame.pc >= function.byteCode().len) return error.InvalidBytecode;
    const idx: u16 = function.byteCode()[frame.pc];
    frame.pc += 1;
    if (idx >= frame.locals.len) return error.InvalidBytecode;

    const value = frame.locals[idx];
    if (value.as(.int)) |int_value| {
        const updated = switch (opcode_id) {
            op.inc_loc => fastInt32Add(int_value, 1),
            op.dec_loc => fastInt32Sub(int_value, 1),
            else => unreachable,
        };
        frame.locals[idx] = updated;
        return;
    }
    if (value.as(.short_big_int)) |bigint_value| {
        const op_id = switch (opcode_id) {
            op.inc_loc => op.inc,
            op.dec_loc => op.dec,
            else => unreachable,
        };
        if (value_ops.shortBigIntUnary(op_id, bigint_value)) |updated| {
            frame.locals[idx] = updated;
            return;
        }
    }
    const primitive = try coercion_ops.toPrimitiveForNumber(ctx, output, global, value);
    if (primitive.is(.symbol)) return error.TypeError;
    const op_id = switch (opcode_id) {
        op.inc_loc => op.inc,
        op.dec_loc => op.dec,
        else => unreachable,
    };
    const updated = try value_ops.unary(ctx.runtime, op_id, primitive);
    frame.locals[idx] = updated;
}

pub noinline fn updateLocalVm(vm: *Vm, opc: u8) HostError!void {
    updateLocal(vm.ctx, vm.function, vm.global, vm.frame, opc, vm.output) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(vm.ctx, vm.output, vm.stack, vm.frame, vm.catch_target, vm.global, err)) return;
        return err;
    };
}

/// Register-resident slow inc_loc/dec_loc (qjs OP_inc_loc/OP_dec_loc's non-int
/// branch), the unary analog of `addLocalAt`: it takes the local SLOT POINTER and
/// the opcode directly, never reading `frame.pc` or touching the stack, so the
/// dispatch handler keeps pc/sp in registers and skips the per-iteration frame.pc
/// memory round-trip. inc_loc/dec_loc are stack-neutral (they rewrite the local in
/// place), so there is nothing to pop. Body is `updateLocal`'s, re-parameterized on
/// (slot, opcode_id).
pub fn updateLocalAt(vm: *Vm, opcode_id: u8, slot: *core.JSValue) HostError!void {
    const ctx = vm.ctx;
    // Frame locals are plain ValueSlots. The numeric fast paths read `slot.*`
    // without a dup and replace it with store-before-free ownership ordering;
    // qjs likewise reads sp[-1] directly and JS_DupValue on a number is a no-op.
    const cur = slot.*;
    if (cur.as(.int)) |int_value| {
        const updated = switch (opcode_id) {
            op.inc_loc => fastInt32Add(int_value, 1),
            op.dec_loc => fastInt32Sub(int_value, 1),
            else => unreachable,
        };
        slot.* = updated;
        return;
    }
    // Float64 fast path — qjs js_unary_arith_slow's `if (FLOAT64) goto handle_float64`
    // (d ± 1 → bare __JS_NewFloat64, no int32 renormalization). Skips the generic
    // toPrimitiveForNumber + value_ops.unary dispatch on every float-counter `x++`.
    if (cur.as(.float64)) |d| {
        const updated = switch (opcode_id) {
            op.inc_loc => d + 1,
            op.dec_loc => d - 1,
            else => unreachable,
        };
        slot.* = core.JSValue.float64(updated);
        return;
    }
    if (cur.as(.short_big_int)) |bigint_value| {
        const op_id = switch (opcode_id) {
            op.inc_loc => op.inc,
            op.dec_loc => op.dec,
            else => unreachable,
        };
        if (value_ops.shortBigIntUnary(op_id, bigint_value)) |updated| {
            slot.* = updated;
            return;
        }
    }
    // Object / heap-bigint slow path: take an owned copy so user coercion
    // (valueOf) cannot free the accumulator underneath us (qjs OP_inc_loc's
    // `op1 = JS_DupValue(op1)`).
    const value = slot.*;
    const primitive = try coercion_ops.toPrimitiveForNumber(ctx, vm.output, vm.global, value);
    if (primitive.is(.symbol)) return error.TypeError;
    const op_id = switch (opcode_id) {
        op.inc_loc => op.inc,
        op.dec_loc => op.dec,
        else => unreachable,
    };
    const updated = try value_ops.unary(ctx.runtime, op_id, primitive);
    slot.* = updated;
}

pub fn addLocal(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    function: *const bytecode.FunctionBytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    output: ?*std.Io.Writer,
) !void {
    if (frame.pc >= function.byteCode().len) return error.InvalidBytecode;
    const idx: u16 = function.byteCode()[frame.pc];
    frame.pc += 1;
    if (idx >= frame.locals.len) return error.InvalidBytecode;

    const rhs = try stack.pop();
    // rhs ownership transfers onward: the string and number slow paths consume it
    // via toPrimitiveForAdditionFree (qjs JS_ToPrimitiveFree). The int32/bigint
    // fast paths only ever see non-refcounted operands, so their early returns
    // leave nothing to free.

    const lhs_borrowed = frame.locals[idx];
    if (lhs_borrowed.isString()) {
        // Outlined: the string-append path carries its own JSValue temporaries
        // (dup'd accumulator + coerced rhs). Keeping them in a separate frame
        // stops them from inflating the hot number path's spill set — LLVM does
        // not coalesce the two branches' spill slots, so an inline string block
        // makes every float `s = s + i` iteration pay its stack frame.
        return addLocalString(ctx, output, global, frame, idx, rhs);
    }

    // Dup the local so user coercion (Symbol.toPrimitive/valueOf) cannot free it
    // underneath us. lhs is owned and is CONSUMED by the slow path below.
    const lhs = frame.locals[idx];
    if (lhs.as(.int)) |lhs_int| {
        if (rhs.as(.int)) |rhs_int| {
            const updated = fastInt32Add(lhs_int, rhs_int);
            frame.locals[idx] = updated;
            return; // both int32 — non-refcounted, nothing to free
        }
    }
    if (lhs.as(.short_big_int)) |lhs_bigint| {
        if (rhs.as(.short_big_int)) |rhs_bigint| {
            if (value_ops.shortBigIntBinary(op.add, lhs_bigint, rhs_bigint)) |updated| {
                frame.locals[idx] = updated;
                return; // both short big ints — non-refcounted, nothing to free
            }
        }
    }

    // Slow path: consume lhs and rhs into primitives with no second dup, mirroring
    // qjs js_add_slow's JS_ToPrimitiveFree(op1)/JS_ToPrimitiveFree(op2). For the
    // hot float case both are non-objects, so each call passes the value straight
    // through — one fewer live JSValue temporary per operand than a borrowing dup.
    const lhs_primitive = coercion_ops.toPrimitiveForAdditionFree(ctx, output, global, lhs) catch |err| {
        return err;
    };
    const rhs_primitive = try coercion_ops.toPrimitiveForAdditionFree(ctx, output, global, rhs);

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
            if (lhs_primitive.is(.int) and rhs_primitive.is(.int)) {
                frame.locals[idx] = value_ops.numberToValue(sum);
            } else {
                frame.locals[idx] = core.JSValue.float64(sum);
            }
            return;
        }
    }
    const updated = try value_ops.binary(ctx.runtime, op.add, lhs_primitive, rhs_primitive);
    frame.locals[idx] = updated;
}

/// String-accumulator branch of `addLocal`, outlined so its JSValue temporaries
/// live in their own frame and never inflate the hot number path's spill set.
/// `rhs` is CONSUMED here; the caller transfers ownership and does not free it.
noinline fn addLocalString(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    frame: *frame_mod.Frame,
    idx: u16,
    rhs: core.JSValue,
) !void {
    const lhs = frame.locals[idx];

    // qjs:19766-19767 OP_add_loc string arm requires BOTH `*pv` and `op2`
    // already JS_TAG_STRING; object operands go to js_add_slow (qjs:19778).
    // Structurally impossible to in-place-append after user toString.
    if (rhs.isString()) {
        const updated = try value_ops.binary(ctx.runtime, op.add, lhs, rhs);
        frame.locals[idx] = updated;
        return;
    }

    const rhs_primitive = try coercion_ops.toPrimitiveForAdditionFree(ctx, output, global, rhs);
    const updated = try value_ops.binary(ctx.runtime, op.add, lhs, rhs_primitive);
    frame.locals[idx] = updated;
}

pub noinline fn addLocalVm(vm: *Vm) HostError!void {
    addLocal(vm.ctx, vm.stack, vm.function, vm.global, vm.frame, vm.output) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(vm.ctx, vm.output, vm.stack, vm.frame, vm.catch_target, vm.global, err)) return;
        return err;
    };
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
pub fn addLocalAt(vm: *Vm, slot: *core.JSValue, rhs: core.JSValue) HostError!void {
    const ctx = vm.ctx;
    const global = vm.global;
    const output = vm.output;
    const lhs_borrowed = slot.*;
    if (lhs_borrowed.isString()) {
        return addLocalStringAt(ctx, output, global, slot, rhs);
    }

    const lhs = slot.*;
    if (lhs.as(.int)) |lhs_int| {
        if (rhs.as(.int)) |rhs_int| {
            slot.* = fastInt32Add(lhs_int, rhs_int);
            return; // both int32 — non-refcounted, nothing to free
        }
    }
    if (lhs.as(.short_big_int)) |lhs_bigint| {
        if (rhs.as(.short_big_int)) |rhs_bigint| {
            if (value_ops.shortBigIntBinary(op.add, lhs_bigint, rhs_bigint)) |updated| {
                slot.* = updated;
                return; // both short big ints — non-refcounted, nothing to free
            }
        }
    }

    const lhs_primitive = coercion_ops.toPrimitiveForAdditionFree(ctx, output, global, lhs) catch |err| {
        return err;
    };
    const rhs_primitive = try coercion_ops.toPrimitiveForAdditionFree(ctx, output, global, rhs);

    if (value_ops.numberValue(lhs_primitive)) |d1| {
        if (value_ops.numberValue(rhs_primitive)) |d2| {
            const sum = d1 + d2;
            if (lhs_primitive.is(.int) and rhs_primitive.is(.int)) {
                slot.* = value_ops.numberToValue(sum);
            } else {
                slot.* = core.JSValue.float64(sum);
            }
            return;
        }
    }
    const updated = try value_ops.binary(ctx.runtime, op.add, lhs_primitive, rhs_primitive);
    slot.* = updated;
}

/// `addLocalString`'s slot-pointer analog (see `addLocalAt`).
noinline fn addLocalStringAt(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    slot: *core.JSValue,
    rhs: core.JSValue,
) !void {
    const lhs = slot.*;

    // qjs:19766-19767 OP_add_loc string arm requires BOTH `*pv` and `op2`
    // already JS_TAG_STRING; object operands go to js_add_slow (qjs:19778).
    if (rhs.isString()) {
        const updated = try value_ops.binary(ctx.runtime, op.add, lhs, rhs);
        slot.* = updated;
        return;
    }

    const rhs_primitive = try coercion_ops.toPrimitiveForAdditionFree(ctx, output, global, rhs);
    const updated = try value_ops.binary(ctx.runtime, op.add, lhs, rhs_primitive);
    slot.* = updated;
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
    if (sameLooseEqualityType(lhs, rhs)) return value_ops.strictEqual(lhs, rhs).as(.boolean).?;
    if ((lhs.is(.null_value) and rhs.is(.undefined_value)) or (lhs.is(.undefined_value) and rhs.is(.null_value))) return true;
    if ((value_ops.isHTMLDDA(lhs) and (rhs.is(.null_value) or rhs.is(.undefined_value))) or
        ((lhs.is(.null_value) or lhs.is(.undefined_value)) and value_ops.isHTMLDDA(rhs))) return true;
    if (lhs.is(.null_value) or lhs.is(.undefined_value) or rhs.is(.null_value) or rhs.is(.undefined_value)) return false;

    if (lhs.isNumber() and rhs.isString()) {
        const number_rhs = try value_ops.toNumberValue(ctx.runtime, rhs);
        return looseEqualSameNumberTypes(lhs, number_rhs);
    }
    if (lhs.isString() and rhs.isNumber()) {
        const number_lhs = try value_ops.toNumberValue(ctx.runtime, lhs);
        return looseEqualSameNumberTypes(number_lhs, rhs);
    }
    if (lhs.isBigInt() and rhs.isString()) {
        var rhs_bigint = value_ops.parseStringToBigInt(ctx.runtime, rhs) catch return false;
        defer rhs_bigint.deinit();
        const rhs_value = try value_ops.createBigIntValue(ctx.runtime, rhs_bigint);
        return value_ops.strictEqual(lhs, rhs_value).as(.boolean).?;
    }
    if (lhs.isString() and rhs.isBigInt()) {
        var lhs_bigint = value_ops.parseStringToBigInt(ctx.runtime, lhs) catch return false;
        defer lhs_bigint.deinit();
        const lhs_value = try value_ops.createBigIntValue(ctx.runtime, lhs_bigint);
        return value_ops.strictEqual(lhs_value, rhs).as(.boolean).?;
    }
    if (lhs.is(.boolean)) {
        const number_lhs = core.JSValue.int32(if (lhs.as(.boolean).?) 1 else 0);
        return looseEqualOp(ctx, output, global, number_lhs, rhs, depth + 1);
    }
    if (rhs.is(.boolean)) {
        const number_rhs = core.JSValue.int32(if (rhs.as(.boolean).?) 1 else 0);
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
    if (isLoosePrimitiveForObject(lhs) and rhs.is(.object)) {
        const primitive_rhs = try coercion_ops.toPrimitiveForAddition(ctx, output, global, rhs);
        return looseEqualOp(ctx, output, global, lhs, primitive_rhs, depth + 1);
    }
    if (lhs.is(.object) and isLoosePrimitiveForObject(rhs)) {
        const primitive_lhs = try coercion_ops.toPrimitiveForAddition(ctx, output, global, lhs);
        return looseEqualOp(ctx, output, global, primitive_lhs, rhs, depth + 1);
    }
    return false;
}

fn sameLooseEqualityType(lhs: core.JSValue, rhs: core.JSValue) bool {
    if (lhs.isNumber() and rhs.isNumber()) return true;
    if (lhs.isString() and rhs.isString()) return true;
    if (lhs.is(.boolean) and rhs.is(.boolean)) return true;
    if (lhs.isBigInt() and rhs.isBigInt()) return true;
    if (lhs.is(.symbol) and rhs.is(.symbol)) return true;
    if (lhs.is(.object) and rhs.is(.object)) return true;
    if (lhs.is(.function_bytecode) and rhs.is(.function_bytecode)) return true;
    return lhs.tagOf() == rhs.tagOf();
}

fn isLoosePrimitiveForObject(value: core.JSValue) bool {
    return value.isNumber() or value.isString() or value.isBigInt() or value.is(.symbol);
}

fn looseEqualSameNumberTypes(lhs: core.JSValue, rhs: core.JSValue) bool {
    const lhs_number = value_ops.numberValue(lhs) orelse return false;
    const rhs_number = value_ops.numberValue(rhs) orelse return false;
    if (std.math.isNan(lhs_number) or std.math.isNan(rhs_number)) return false;
    return lhs_number == rhs_number;
}


// ----- merged from vm_call.zig -----
// Bytecode call, construct, and tail-call adapters plus call-depth accounting.
// 
// Operand-stack values enter as owned slots; frame setup borrows, duplicates,
// or transfers arguments and VarRef cells according to `Frame`'s explicit
// dispositions. `CallDepthGuard` balances logical, native, and byte budgets.
// Inline requests use caller-owned request storage to avoid an sret; hot native
// dispatch remains separate from generic fallback. This follows
// `JS_CallInternal` frame entry at quickjs.c and class-call
// dispatch at quickjs.c.
const array_ops = @import("array_ops.zig");
const property_ops = @import("property_ops.zig");
const exception_ops = @import("exception_ops.zig");
const builtin_dispatch = @import("builtin_dispatch.zig");
const inline_calls = @import("inline_calls.zig");
pub const CallStep = enum {
    done,
    continue_loop,
    /// The InlineCallRequest is written through the caller's shared `req_out`
    /// slot, not carried in the result (payload-free → no per-call sret alloca).
    inline_call,
    /// OP_apply(1) materialized `[callable, new_target, args...]` in the
    /// caller's operand region. The constructor opcode adapter consumes the
    /// shared request metadata and enters with a constructor continuation.
    inline_constructor,
};
pub const CallDepthGuard = struct {
    ctx: *core.JSContext,
    planned_stack_bytes: usize,

    pub fn deinit(self: CallDepthGuard) void {
        const rt = self.ctx.runtime;
        std.debug.assert(rt.hot.active_bytecode_stack_bytes >= self.planned_stack_bytes);
        rt.hot.active_bytecode_stack_bytes -= self.planned_stack_bytes;
        rt.hot.call_depth -= 1;
        rt.hot.native_call_depth -= 1;
    }
};
pub fn enterCallDepth(
    ctx: *core.JSContext,
    global: *core.Object,
    planned_stack_bytes: usize,
) !CallDepthGuard {
    const rt = ctx.runtime;
    if (rt.hot.native_call_depth >= maxNativeJsCallDepth(ctx) or
        rt.hot.call_depth >= maxLogicalJsCallDepth(ctx) or
        bytecodeStackBudgetWouldOverflow(rt, planned_stack_bytes))
    {
        // QuickJS JS_CallInternal stack guard -> JS_ThrowStackOverflow =
        // InternalError "stack overflow".
        _ = exception_ops.throwInternalErrorMessage(ctx, global, "stack overflow") catch |err| return err;
        return error.StackOverflow;
    }
    rt.hot.active_bytecode_stack_bytes += planned_stack_bytes;
    rt.hot.call_depth += 1;
    rt.hot.native_call_depth += 1;
    return .{ .ctx = ctx, .planned_stack_bytes = planned_stack_bytes };
}

/// QuickJS JS_CallInternal's planned `alloca_size` for a normal bytecode
/// target called without COPY_ARGV. Tail opcodes use
/// flags=0, so only missing arguments allocate the padded argv prefix.
pub fn bytecodeFrameAllocaSize(
    function: *const bytecode.FunctionBytecode,
    argc: usize,
    copy_argv: bool,
) usize {
    const allocated_arg_count: usize = if (copy_argv or argc < @as(usize, function.arg_count))
        function.arg_count
    else
        0;
    const value_slots = allocated_arg_count +
        @as(usize, function.var_count) +
        @as(usize, function.stack_size);
    return value_slots * @sizeOf(core.JSValue) +
        @as(usize, function.var_ref_count) * @sizeOf(*core.VarRef);
}

/// Leaf-family pricing of `bytecodeFrameAllocaSize`. Every published leaf
/// commits with copy_argv=false and argc >= arg_count (empty/forwarded leaves
/// are zero-arg bodies; the exact-args family asserts argc == arg_count), so
/// the qjs padded-argv prefix is always empty and the figure collapses to
/// function-header scalars — no argc load and no pricing select on the
/// per-return release path.
pub inline fn bytecodeLeafFrameAllocaSize(
    function: *const bytecode.FunctionBytecode,
) usize {
    const value_slots = @as(usize, function.var_count) + @as(usize, function.stack_size);
    return value_slots * @sizeOf(core.JSValue) +
        @as(usize, function.var_ref_count) * @sizeOf(*core.VarRef);
}

inline fn bytecodeStackBudgetWouldOverflow(
    rt: *const core.JSRuntime,
    planned_stack_bytes: usize,
) bool {
    return admissionCeilingsReject(&rt.hot, rt.hot.active_bytecode_stack_bytes +% planned_stack_bytes, planned_stack_bytes);
}

/// The two byte-priced ceilings of a bytecode push, as one predicate over the
/// already-formed sum: the wrap test (`accumulated` went backwards) and the
/// qjs `js_check_stack_overflow` native recursion guard. `std.math.add`'s
/// error union made LLVM materialize the overflow flag into a byte and spill
/// it (`cset` + `sturb` in front of every crossing); `+%` plus the backwards
/// compare is the same predicate with the flag consumed where it is produced.
inline fn admissionCeilingsReject(
    hot: *const core.JSRuntime.HotExecState,
    accumulated: usize,
    planned_stack_bytes: usize,
) bool {
    // No wrap test: every accepted `accumulated` is below a native frame
    // address (the guard below), and one planned figure is bounded by the
    // function header's u16 slot counts, so the sum stays under 2^49. The
    // `std.math.add` error union this replaces cost a `cset` + a `tbnz` per
    // crossing to carry a flag that is provably never set.
    std.debug.assert(accumulated >= planned_stack_bytes);
    return (@frameAddress() -| accumulated) < hot.native_stack_limit;
}

/// Byte-priced variants: constructors that already hold the planned frame
/// bytes (to persist them into the Entry for the O(1) teardown release) check
/// and commit that exact figure instead of re-deriving it from the function
/// header.
pub inline fn canEnterInlineCallDepthBytes(
    ctx: *const core.JSContext,
    planned_stack_bytes: usize,
) bool {
    const rt = ctx.runtime;
    return rt.hot.call_depth < maxLogicalJsCallDepth(ctx) and
        !bytecodeStackBudgetWouldOverflow(rt, planned_stack_bytes);
}

pub inline fn commitInlineCallDepthBytes(
    ctx: *core.JSContext,
    planned_stack_bytes: usize,
) void {
    const rt = ctx.runtime;
    std.debug.assert(std.math.maxInt(usize) - rt.hot.active_bytecode_stack_bytes >= planned_stack_bytes);
    rt.hot.active_bytecode_stack_bytes += planned_stack_bytes;
    rt.hot.call_depth += 1;
}

/// K2 fused admission+commit for the warm leaf constructors: the check and
/// the commit RMW run back-to-back on one caller-supplied `rt` (no chunk or
/// carve stores in between), so the whole budget transaction is a single
/// hot-line load cluster instead of the admission/commit split that reloaded
/// ctx→runtime after the arena carve's aliasing store (M1 dossier K2: rt
/// reloads #3/#4). Mirrors qjs check-then-alloca where the check IS the
/// commitment; a later chunk/carve miss must retreat
/// the charge via `retreatInlineCallDepthBytesMiss` before the pure-miss
/// null return. `bytecodeStackBudgetWouldOverflow` already rejects a wrapping
/// add, so the commit needs no second overflow assert.
pub inline fn tryCommitInlineCallDepthBytesRt(
    rt: *core.JSRuntime,
    planned_stack_bytes: usize,
) bool {
    // One load cluster, one sum, one commit: the accumulated byte figure the
    // ceilings test IS the figure that is stored back, so the crossing pays
    // a single `adds` instead of the check's add plus the commit's add.
    const hot = &rt.hot;
    const depth = hot.call_depth;
    const bytes = hot.active_bytecode_stack_bytes;
    const accumulated = bytes +% planned_stack_bytes;
    if (depth >= hot.stack_size or
        admissionCeilingsReject(hot, accumulated, planned_stack_bytes)) return false;
    hot.active_bytecode_stack_bytes = accumulated;
    hot.call_depth = depth + 1;
    return true;
}

/// K2 cold unwind: commit-before-carve means a warm constructor's rare
/// chunk/carve miss holds an already-committed budget charge; retreat it so
/// the authoritative slow constructor re-enters from balanced accounting.
/// noinline keeps the unwind bl-only on the warm body's miss exits.
pub noinline fn retreatInlineCallDepthBytesMiss(
    rt: *core.JSRuntime,
    planned_stack_bytes: usize,
) void {
    leaveInlineCallDepthBytesRt(rt, planned_stack_bytes);
}

/// Admit and charge callers that keep the planned stack byte count across
/// the push (Entry persistence + errdefer).
pub inline fn enterInlineCallDepthBytes(
    ctx: *core.JSContext,
    global: *core.Object,
    planned_stack_bytes: usize,
) !void {
    if (!canEnterInlineCallDepthBytes(ctx, planned_stack_bytes)) {
        return inlineCallDepthOverflow(ctx, global);
    }
    commitInlineCallDepthBytes(ctx, planned_stack_bytes);
}

pub inline fn leaveInlineCallDepthBytes(
    ctx: *core.JSContext,
    planned_stack_bytes: usize,
) void {
    leaveInlineCallDepthBytesRt(ctx.runtime, planned_stack_bytes);
}

/// rt-threaded sibling: the leaf pops load `rt` once BEFORE their inline
/// teardown's arena store, whose aliasing otherwise blocks CSE of the
/// ctx->runtime reload on the release path (M1 dossier K3).
pub inline fn leaveInlineCallDepthBytesRt(
    rt: *core.JSRuntime,
    planned_stack_bytes: usize,
) void {
    std.debug.assert(rt.hot.active_bytecode_stack_bytes >= planned_stack_bytes);
    rt.hot.active_bytecode_stack_bytes -= planned_stack_bytes;
    rt.hot.call_depth -= 1;
}

/// Preflight for a tail-call frame replacement. QuickJS's OP_tail_call enters
/// a nested JS_CallInternal, checks native SP minus the callee's planned
/// alloca, and leaves every caller blocked until the final callee returns.
/// zjs reuses physical Entry storage, so it carries those planned bytes in a
/// separate Runtime budget while also preserving logical call-depth balance.
/// Neither budget aliases the per-Realm interrupt counter.
pub fn checkTailCallChainStackBudget(
    ctx: *core.JSContext,
    global: *core.Object,
    planned_stack_bytes: usize,
) !void {
    const rt = ctx.runtime;
    if (rt.hot.call_depth >= maxLogicalJsCallDepth(ctx) or
        bytecodeStackBudgetWouldOverflow(rt, planned_stack_bytes))
    {
        return inlineCallDepthOverflow(ctx, global);
    }
}

/// Stack exhaustion is exceptional and constructs a JS error.  Keep it out of
/// the same-native-stack inline-call prologue: otherwise LLVM couples the
/// thrower's large error-union frame and callee-saved register set to every
/// ordinary JS call.  QJS likewise keeps this behind the unlikely
/// `js_check_stack_overflow` arm of `JS_CallInternal`.
noinline fn inlineCallDepthOverflow(ctx: *core.JSContext, global: *core.Object) !void {
    _ = exception_ops.throwInternalErrorMessage(ctx, global, "stack overflow") catch |err| return err;
    return error.StackOverflow;
}

pub inline fn initFrameLocals(
    ctx: *core.JSContext,
    function: *const bytecode.FunctionBytecode,
    frame: *frame_mod.Frame,
    use_inline_storage: bool,
    windows: frame_mod.FrameStorageWindows,
) !void {
    if (function.var_count == 0) return;
    var storage_transferred = false;
    errdefer if (!storage_transferred) frame.releaseOwnedStorage(&ctx.runtime.memory, ctx.runtime);

    const locals = blk: {
        if (windows.locals) |values| {
            std.debug.assert(values.len == function.var_count);
            break :blk values;
        }
        if (use_inline_storage) {
            if (ctx.runtime.vm_stack.carve(&ctx.runtime.memory, function.var_count)) |window| break :blk window;
        }
        break :blk try frame.allocOwnedStorage(&ctx.runtime.memory, function.var_count);
    };
    @memset(locals, core.JSValue.undefinedValue());
    frame.locals = locals;

    storage_transferred = true;
}

pub inline fn initFrameVarRefs(
    ctx: *core.JSContext,
    function: *const bytecode.FunctionBytecode,
    frame: *frame_mod.Frame,
    var_refs: []const *core.VarRef,
    use_inline_storage: bool,
    windows: frame_mod.FrameStorageWindows,
) !void {
    if (var_refs.len > 0) {
        const owned_refs = if (windows.var_refs) |cells| blk: {
            std.debug.assert(cells.len == var_refs.len);
            break :blk cells;
        } else blk: {
            if (use_inline_storage) {
                if (ctx.runtime.vm_stack.carveTyped(&ctx.runtime.memory, *core.VarRef, var_refs.len)) |window| break :blk window;
            }
            break :blk try allocFrameVarRefWindow(ctx, frame, var_refs.len);
        };
        // Inherit: pointer copy + rc++ per slot (qjs JS_CLOSURE_REF form,
        // quickjs.c).
        for (var_refs, 0..) |cell, idx| owned_refs[idx] = cell;
        frame.var_refs = owned_refs;
        return;
    }

    // Canonical functions receive their complete capture array from their
    // function object. Reconstructing cells at frame entry would create a
    // second identity and revive the retired placeholder/copy/replace path.
    if (function.closureVar().len > 0) return error.InvalidBytecode;
}

/// Heap fallback for an owned frame var_refs array: a []JSValue storage
/// allocation windowed as pointer slots, so the uniform storage_values
/// teardown owns the memory (same layout the FrameSlab carve produces).
fn allocFrameVarRefWindow(ctx: *core.JSContext, frame: *frame_mod.Frame, count: usize) ![]*core.VarRef {
    const ptr_bytes = try std.math.mul(usize, @sizeOf(*core.VarRef), count);
    const value_slots = try std.math.divCeil(usize, ptr_bytes, @sizeOf(core.JSValue));
    const values = try frame.allocOwnedStorage(&ctx.runtime.memory, value_slots);
    return std.mem.bytesAsSlice(*core.VarRef, std.mem.sliceAsBytes(values)[0..ptr_bytes]);
}

pub noinline fn closure(vm: *Vm, opc: u8) HostError!void {
    const function = vm.function;
    const frame = vm.frame;
    const index: u32 = if (opc == op.fclosure) blk: {
        const value = readInt(u32, function.byteCode()[frame.pc..][0..4]);
        frame.pc += 4;
        break :blk value;
    } else blk: {
        const value: u32 = function.byteCode()[frame.pc];
        frame.pc += 1;
        break :blk value;
    };
    try array_ops.pushFunctionClosure(vm.ctx, frame, vm.stack, function, vm.global, index);
}

pub fn call(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.FunctionBytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    opc: u8,
    req_out: *call_runtime.InlineCallRequest,
) !CallStep {
    const argc = switch (opc) {
        op.call => blk: {
            const value = readInt(u16, function.byteCode()[frame.pc..][0..2]);
            frame.pc += 2; // argc
            break :blk value;
        },
        op.call0 => 0,
        op.call1 => 1,
        op.call2 => 2,
        op.call3 => 3,
        else => unreachable,
    };
    return switch (try call_runtime.execCall(ctx, stack, function, frame, catch_target, argc, output, global, true, req_out)) {
        .done => .done,
        .continue_loop => .continue_loop,
        .inline_call => .inline_call,
    };
}

/// Record + callable realm from one walk of the function payload
/// (`nativeCallTarget`); a builtin whose record is not memoized yet takes the
/// lazy resolve once and retries.
pub inline fn resolvedNativeCallTargetAssumeCFunction(
    ctx: *core.JSContext,
    func_obj: *core.Object,
) ?core.Object.NativeCallTarget {
    return func_obj.nativeCallTarget() orelse blk: {
        _ = resolvedNativeMethodRecordAssumeCFunction(ctx, func_obj) orelse return null;
        break :blk func_obj.nativeCallTarget();
    };
}

/// Resolve the C-function record carried by a concrete native method object.
/// QuickJS reaches the same terminal through the class call hook, which reads
/// `p->u.cfunc.c_function` directly. Keep the record
/// memoization shared by every opcode that already holds the method object.
pub inline fn resolvedNativeMethodRecord(
    ctx: *core.JSContext,
    method_obj: *core.Object,
) ?*const core.NativeEntry {
    if (method_obj.class_id != core.class.ids.c_function) return null;
    return resolvedNativeMethodRecordAssumeCFunction(ctx, method_obj);
}

/// K1: caller already proved `class_id == c_function`.
pub inline fn resolvedNativeMethodRecordAssumeCFunction(
    ctx: *core.JSContext,
    method_obj: *core.Object,
) ?*const core.NativeEntry {
    return method_obj.nativeEntryAssumeCFunction() orelse blk: {
        const native_id = method_obj.nativeFunctionId();
        const nref = core.function.decodeNativeBuiltinId(native_id) orelse return null;
        const record = ctx.runtime.internalBuiltinRecord(@intCast(@intFromEnum(nref.domain)), nref.id) orelse return null;
        method_obj.nativeEntrySlot().* = record;
        break :blk record;
    };
}

/// Call a record returned by `resolvedNativeMethodRecord`. The caller owns the
/// single call-entry interrupt poll and must keep receiver, method, and args
/// rooted across this observable call.
pub inline fn callResolvedNativeMethod(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    method_obj: *core.Object,
    record: *const core.NativeEntry,
    receiver: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    return builtin_dispatch.callInternalRecordDirect(
        ctx,
        output,
        global,
        &.{},
        method_obj,
        receiver,
        record,
        args,
        caller_function,
        caller_frame,
    );
}

pub noinline fn callMethod(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.FunctionBytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    allow_inline: bool,
    req_out: *call_runtime.InlineCallRequest,
) !CallStep {
    const argc = readInt(u16, function.byteCode()[frame.pc..][0..2]);
    frame.pc += 2; // argc
    // Inline frame fast path: a method call whose callable is a plain bytecode
    // function runs as an inline frame (like op.call), so method-position
    // recursion gets the logical call-depth limit instead of the shallow
    // native-recursion limit, and its tail-positioned method calls become
    // frame-reusing proper tail calls. Receiver, callable, and args stay on the
    // operand stack (zero-copy) at `[receiver, callable, args...]` until the
    // dispatch loop pushes the frame; the receiver becomes the callee's `this`
    // (arrow targets use their lexical `this`). Native builtin methods — the
    // common case — are not inline-eligible and fall through to the fast native
    // dispatch below. Class constructors (super() targets) are rejected by
    // `resolveInlineTarget`, so this never shadows the super-constructor path.
    if (allow_inline) {
        const total = @as(usize, argc) + 2;
        if (stack.len() >= total) {
            const region_base = stack.len() - total;
            const receiver = stack.values[region_base];
            const method = stack.values[region_base + 1];
            if (inline_calls.resolveInlineTarget(global, receiver, method)) |target| {
                req_out.* = .{ .target = target, .region_base = region_base, .argc = argc, .layout = .method };
                return .inline_call;
            }
        }
    }
    // Zero-copy method-call sequence (mirrors execCall + qjs OP_call_method):
    // borrow `obj | func | args...` directly from the caller-owned operand stack
    // instead of popping them into a duplicated staging buffer. The region stays
    // on the stack (rooting obj/func/args for the whole call), and is popped and
    // released only after the call completes.
    const total: usize = @as(usize, argc) + 2;
    if (stack.len() < total) return error.StackUnderflow;
    const region_base = stack.len() - total;
    const obj = stack.values[region_base];
    const func = stack.values[region_base + 1];
    const args: []const core.JSValue = stack.values[region_base + 2 ..][0..argc];
    exception_ops.pollInterrupt(ctx, global) catch |err| {
        call_runtime.popOwnedStackRegion(stack, region_base);
        if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    const fast_result = fastNativeMethodCall(ctx, output, global, obj, func, args, function, frame) catch |err| {
        call_runtime.popOwnedStackRegion(stack, region_base);
        if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    if (fast_result) |value| {
        call_runtime.popOwnedStackRegion(stack, region_base);
        if (dropUnusedCallResult(ctx, function, frame, value)) return .done;
        stack.pushOwnedAssumeCapacity(value);
        return .done;
    }
    const maybe_array_result = array_ops.arrayMethodFastCall(ctx, output, global, obj, func, args, function, frame) catch |err| {
        call_runtime.popOwnedStackRegion(stack, region_base);
        if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    const result = if (maybe_array_result) |array_result|
        array_result
    else
        call_runtime.callValueOrBytecodeRootPreRootedAfterInterruptPoll(ctx, output, global, obj, func, args, function, frame) catch |err| {
            call_runtime.popOwnedStackRegion(stack, region_base);
            if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
            return err;
        };
    call_runtime.popOwnedStackRegion(stack, region_base);
    if (dropUnusedCallResult(ctx, function, frame, result)) return .done;
    stack.pushOwnedAssumeCapacity(result);
    return .done;
}

pub fn dropUnusedCallResult(
    _: *core.JSContext,
    function: *const bytecode.FunctionBytecode,
    frame: *frame_mod.Frame,
    _: core.JSValue,
) bool {
    if (frame.pc >= function.byteCode().len or function.byteCode()[frame.pc] != op.drop) return false;
    frame.pc += 1;
    return true;
}

inline fn fastNativeMethodCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    func: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    // QuickJS uniform dispatch: the `call_method` opcode hot
    // path routes through the same exec-owned internal record table the general
    // record dispatch (`call.zig:callNativeFunctionRecord`) and the plain-call
    // VM fast path (`call_runtime.callNativeBuiltinRecordForVm`) use, so exec
    // carries zero compile-time knowledge of individual native domains. The retired
    // per-domain hot subset (math min/max primitives, the URI string fast path,
    // Number.parse{Int,Float}, String.fromCharCode / substring primitive, the
    // Array prototype hub, the collection / regexp / JSON record glue) is gone:
    // every one of those domains is table-backed, and the table handler is the
    // complete implementation, so a table HIT returns the final value here.
    //
    // This call site holds the materialized function object (pass non-null
    // `func_obj = function_object`). Realm selection belongs to the final
    // record terminal: it loads the C_FUNCTION's owned RealmContext and global
    // as one view. Keep the caller global here so no fast-path-only fallback
    // can switch authority before record selection and stack preflight.
    //
    // A table MISS returns null so the caller falls through to the array
    // fast-array storage fallback (`arrayMethodFastCall`, which keeps the
    // name-based TypedArray slice/subarray path that has no native-builtin id)
    // and then the generic value/bytecode dispatch. Among encoded native
    // domains, only the separate host mechanism intentionally has no standard
    // record table.
    const function_object = core.value_semantics.objectFromValue(func) orelse return null;
    // This is specifically the native c_function fast path. Bytecode functions
    // use the same FunctionPayload kind, but qjs discriminates their overlaid
    // union by class before reading `u.cfunc`; do the same before interpreting
    // the shared call-cache slot as an NativeEntry. Bound/proxy/closure
    // callables likewise fall through to the generic dispatcher.
    if (function_object.class_id != core.class.ids.c_function) return null;
    // Divergence B: cache the resolved `*const NativeEntry` on the func-object
    // payload so the hot call skips the per-call native-id DECODE + record-table
    // LOOKUP, mirroring qjs `func = p->u.cfunc.c_function` (the dispatchable
    // handle lives on the object). SAFE memoization: `native_function_id` is
    // write-once at registration, and the resolved record is a comptime
    // `pub const` in `rt.internal_builtins` (rodata) — program-lifetime stable,
    // identical across runtimes, never dangles, so the memo can never go stale.
    // A MISS falls through to null exactly as the pre-memo decode/probe did.
    const rec = resolvedNativeMethodRecord(ctx, function_object) orelse return null;
    return try callResolvedNativeMethod(ctx, output, global, function_object, rec, this_value, args, caller_function, caller_frame);
}

pub noinline fn apply(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.FunctionBytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    req_out: *call_runtime.InlineCallRequest,
) !CallStep {
    const is_new = readInt(u16, function.byteCode()[frame.pc..][0..2]);
    frame.pc += 2;
    if (is_new != 0) {
        // Parser-emitted constructor spread owns one operand transaction:
        // `[callable, new_target, materialized-array]`. Preserve it through
        // observable list creation. An eligible target rewrites only the array
        // suffix into final args; every fallback retains the authoritative
        // recursive [[Construct]] path.
        if (stack.len() < 3) return error.StackUnderflow;
        const region_base = stack.len() - 3;
        const func = stack.values[region_base];
        const new_target = stack.values[region_base + 1];
        const array_value = stack.values[region_base + 2];
        var apply_args = array_ops.argsFromArray(ctx.runtime, array_value) catch |err| {
            call_runtime.popOwnedStackRegion(stack, region_base);
            if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
            return err;
        };
        defer call_runtime.freeArgs(ctx.runtime, apply_args);
        var apply_args_root = array_ops.ValueSliceRoot{};
        apply_args_root.init(ctx.runtime, &apply_args);
        defer apply_args_root.deinit();

        if (call_runtime.resolveSameMachineSpreadConstructor(global, func, new_target)) |candidate| {
            const final_len = try std.math.add(usize, region_base + 2, apply_args.len);
            const current_len = stack.len();
            if (final_len > current_len) {
                stack.reserveAdditional(final_len - current_len) catch |err| {
                    call_runtime.popOwnedStackRegion(stack, region_base);
                    if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
                    return err;
                };
            }

            // reserveAdditional may relocate the backing. Keep the callable
            // and new.target in their original owned slots; replace only the
            // materialized-array suffix with the final moved argument list.
            const rooted_func = stack.values[region_base];
            stack.values[region_base + 2] = core.JSValue.undefinedValue();
            stack.setLen(region_base + 2);
            for (apply_args, 0..) |*arg, index| {
                stack.values[region_base + 2 + index] = arg.*;
                arg.* = core.JSValue.undefinedValue();
            }
            stack.setLen(final_len);
            req_out.* = .{
                // The constructor adapter uses the receiver-independent
                // witness after reloading the committed operand region.
                .target = candidate.resolved.bind(core.JSValue.undefinedValue(), rooted_func),
                .region_base = region_base,
                .argc = @intCast(apply_args.len),
                .layout = .method,
            };
            return .inline_constructor;
        }

        const result = call_runtime.constructValueOrBytecodeWithNewTarget(ctx, output, global, func, apply_args, function, frame, new_target) catch |err| {
            call_runtime.popOwnedStackRegion(stack, region_base);
            if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
            return err;
        };
        call_runtime.popOwnedStackRegion(stack, region_base);
        stack.pushOwnedAssumeCapacity(result);
        return .done;
    }

    // Parser-emitted ordinary spread has one rooted operand region:
    // `[callable, receiver, materialized-array]`. Build the argument snapshot
    // first. On an eligible target, recast that same region to
    // `[receiver, callable, args...]` and let the current Machine's ordinary
    // `.next` call driver consume it. This is an opcode call, not a native
    // Function.apply bridge, so no native fence or synthetic apply frame is
    // involved.
    if (stack.len() < 3) return error.StackUnderflow;
    const region_base = stack.len() - 3;
    const func = stack.values[region_base];
    const this_value = stack.values[region_base + 1];
    const array_value = stack.values[region_base + 2];
    var apply_args = array_ops.argsFromArray(ctx.runtime, array_value) catch |err| {
        call_runtime.popOwnedStackRegion(stack, region_base);
        if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    defer call_runtime.freeArgs(ctx.runtime, apply_args);
    var apply_args_root = array_ops.ValueSliceRoot{};
    apply_args_root.init(ctx.runtime, &apply_args);
    defer apply_args_root.deinit();

    if (inline_calls.resolveInlineTarget(global, this_value, func)) |target| {
        const final_len = try std.math.add(usize, region_base + 2, apply_args.len);
        const current_len = stack.len();
        if (final_len > current_len) {
            stack.reserveAdditional(final_len - current_len) catch |err| {
                call_runtime.popOwnedStackRegion(stack, region_base);
                if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
                return err;
            };
        }

        // reserveAdditional may relocate the backing, so reload every slot.
        const rooted_func = stack.values[region_base];
        const rooted_this = stack.values[region_base + 1];
        stack.values[region_base] = rooted_this;
        stack.values[region_base + 1] = rooted_func;
        stack.values[region_base + 2] = core.JSValue.undefinedValue();
        stack.setLen(region_base + 2);

        for (apply_args, 0..) |*arg, index| {
            stack.values[region_base + 2 + index] = arg.*;
            arg.* = core.JSValue.undefinedValue();
        }
        stack.setLen(final_len);
        req_out.* = .{
            .target = target,
            .region_base = region_base,
            .argc = @intCast(apply_args.len),
            .layout = .method,
        };
        return .inline_call;
    }

    const result = call_runtime.callValueOrBytecodeRootPreRooted(ctx, output, global, this_value, func, apply_args, function, frame) catch |err| {
        call_runtime.popOwnedStackRegion(stack, region_base);
        if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    call_runtime.popOwnedStackRegion(stack, region_base);
    stack.pushOwnedAssumeCapacity(result);
    return .done;
}

pub noinline fn constructor(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.FunctionBytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
) !Step {
    const argc = readInt(u16, function.byteCode()[frame.pc..][0..2]);
    frame.pc += 2;
    var inline_args: [4]core.JSValue = undefined;
    const args_buf: []core.JSValue = if (argc <= inline_args.len)
        inline_args[0..argc]
    else
        try ctx.runtime.memory.alloc(core.JSValue, argc);
    defer if (argc > inline_args.len) ctx.runtime.memory.free(core.JSValue, args_buf);
    var remaining: usize = argc;
    while (remaining > 0) {
        remaining -= 1;
        args_buf[remaining] = try stack.pop();
    }
    const top = try stack.pop();
    const has_explicit_new_target = stack.len() != 0;
    const new_target = top;
    const func = if (has_explicit_new_target)
        stack.pop() catch |err| {
            return err;
        }
    else
        top;
    const result = call_runtime.constructValueOrBytecodeWithNewTargetInternal(ctx, output, global, func, args_buf, function, frame, new_target) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    try stack.pushOwned(result);
    return .done;
}

fn throwCtorTypeError(ctx: *core.JSContext, global: *core.Object, message: []const u8) !void {
    _ = exception_ops.throwTypeErrorMessage(ctx, global, message) catch |err| return err;
    return error.TypeError;
}

pub fn checkCtor(ctx: *core.JSContext, global: *core.Object, frame: *frame_mod.Frame) !void {
    if (frame.newTargetValue().is(.undefined_value)) {
        return throwCtorTypeError(ctx, global, "class constructors must be invoked with 'new'");
    }
}

pub noinline fn checkCtorVm(vm: *Vm) HostError!void {
    checkCtor(vm.ctx, vm.global, vm.frame) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(vm.ctx, vm.output, vm.stack, vm.frame, vm.catch_target, vm.global, err)) return;
        return err;
    };
}

pub fn checkCtorReturn(ctx: *core.JSContext, stack: *stack_mod.Stack) !void {
    _ = ctx;
    const value = stack.peekBorrowed() orelse return error.StackUnderflow;
    if (value.is(.object)) {
        try stack.pushOwned(core.JSValue.boolean(false));
    } else if (value.is(.undefined_value)) {
        try stack.pushOwned(core.JSValue.boolean(true));
    } else {
        // qjs constructs this error in JS_CallInternal's caller_ctx, not the
        // derived constructor's own realm. A distinct sentinel preserves that
        // delayed materialization while carrying the exact qjs message.
        return error.DerivedConstructorReturn;
    }
}

pub noinline fn checkCtorReturnVm(vm: *Vm) HostError!void {
    checkCtorReturn(vm.ctx, vm.stack) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(vm.ctx, vm.output, vm.stack, vm.frame, vm.catch_target, vm.global, err)) return;
        return err;
    };
}

pub fn initCtor(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.FunctionBytecode,
    frame: *frame_mod.Frame,
) !void {
    if (frame.newTargetValue().is(.undefined_value)) {
        return throwCtorTypeError(ctx, global, "class constructors must be invoked with 'new'");
    }
    const function_object = try property_ops.expectObject(frame.current_function);
    // qjs OP_init_ctor performs JS_GetPrototype(ctx, func_obj) on every entry.
    // The class-definition-time super carrier is intentionally not
    // authoritative: Object.setPrototypeOf may have replaced the constructor's
    // live [[Prototype]]. Retain the live value across the observable
    // constructor call exactly as JS_GetPrototype's owned result does.
    const super_object = function_object.getPrototype() orelse
        return throwCtorTypeError(ctx, global, "not a function");
    const super = super_object.value();
    const original_args = frame.originalArgs();
    const args = if (original_args.len != 0)
        original_args[0..@min(frame.actual_arg_count, original_args.len)]
    else
        frame.args[0..@min(frame.actual_arg_count, frame.args.len)];
    const result = try call_runtime.constructValueOrBytecodeWithNewTarget(ctx, output, global, super, args, function, frame, frame.newTargetValue());
    try stack.pushOwned(result);
}

pub noinline fn initCtorVm(vm: *Vm) HostError!void {
    initCtor(vm.ctx, vm.output, vm.global, vm.stack, vm.function, vm.frame) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(vm.ctx, vm.output, vm.stack, vm.frame, vm.catch_target, vm.global, err)) return;
        return err;
    };
}

fn maxNativeJsCallDepth(ctx: *const core.JSContext) usize {
    return @max(@as(usize, 16), ctx.stackLimit() / 16384);
}

fn maxLogicalJsCallDepth(ctx: *const core.JSContext) usize {
    return ctx.stackLimit();
}

fn readInt(comptime T: type, bytes: []const u8) T {
    return std.mem.readInt(T, bytes[0..@sizeOf(T)], .little);
}


// ----- merged from vm_control.zig -----
// VM control-transfer helpers: return, jump, throw, catch, and iterator close.
// 
// Stack pops are ownership moves, matching QuickJS opcode semantics; handled
// throws install or route the pending exception before execution resumes.
// Hot dispatch remains outside this file and calls these focused helpers.
const builtin = @import("builtin");
const forof_ops = @import("iterator_ops.zig");
pub const ThrowResult = enum {
    handled,
};
pub inline fn returnTop(vm: *Vm) !core.JSValue {
    const ctx = vm.ctx;
    const stack = vm.stack;
    if (vm.machine.l0.generator_state) |generator_object| generator_object.completeGeneratorExecution(ctx.runtime);
    // qjs OP_return is an ownership MOVE off the operand stack, never a dup:
    // `ret_val = *--sp;`. The done: epilogue then frees
    // only local_buf..sp, which no longer includes the
    // popped ret_val — zero refcount traffic on the returned value. Mirror
    // that: take the top slot by value and shrink, so frame teardown
    // (Entry.deinitSimple / stack.deinit) never touches it.
    const values = stack.liveValues();
    const value = if (values.len != 0) blk: {
        stack.setLen(values.len - 1);
        break :blk values[values.len - 1];
    } else core.JSValue.undefinedValue();
    return finishFunctionReturn(ctx, vm.frame, value);
}

pub inline fn returnUndefined(ctx: *core.JSContext, frame: *frame_mod.Frame, generator: ?*core.Object) !core.JSValue {
    if (generator) |generator_object| generator_object.completeGeneratorExecution(ctx.runtime);
    return finishFunctionReturn(ctx, frame, core.JSValue.undefinedValue());
}

// Hot return-path passthrough: a non-derived-ctor frame returns the value verbatim.
// Inlined so the per-return arm pays no call (it was ~1% of fib as a separate fn).
pub inline fn finishFunctionReturn(_: *core.JSContext, frame: *frame_mod.Frame, value: core.JSValue) !core.JSValue {
    if (!frame.function.isDerivedClassConstructor()) return value;
    if (value.is(.object)) return value;
    if (!value.is(.undefined_value)) return error.DerivedConstructorReturn;
    if (adapterValueBorrow(frame.this_value).is(.uninitialized)) return error.DerivedThisUninitialized;
    return adapterValueBorrow(frame.this_value);
}

pub fn jump32(function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame) void {
    const operand_pc = frame.pc;
    const diff = readInt(i32, function.byteCode()[frame.pc..][0..4]);
    frame.pc = relativePc(operand_pc, diff);
}

pub fn jump16(function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame) void {
    const operand_pc = frame.pc;
    const diff = readInt(i16, function.byteCode()[frame.pc..][0..2]);
    frame.pc = relativePc(operand_pc, diff);
}

pub fn jump8(function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame) void {
    const operand_pc = frame.pc;
    const diff: i8 = @bitCast(function.byteCode()[frame.pc]);
    frame.pc = relativePc(operand_pc, diff);
}

/// `goto*` cold bodies: take the jump, then poll (qjs polls interrupts on
/// every goto; the back edge is a pure loop's only poll point).
pub fn gotoPoll32(vm: *Vm) HostError!void {
    jump32(vm.function, vm.frame);
    try exception_ops.pollInterrupt(vm.ctx, vm.global);
}

pub fn gotoPoll16(vm: *Vm) HostError!void {
    jump16(vm.function, vm.frame);
    try exception_ops.pollInterrupt(vm.ctx, vm.global);
}

pub fn gotoPoll8(vm: *Vm) HostError!void {
    jump8(vm.function, vm.frame);
    try exception_ops.pollInterrupt(vm.ctx, vm.global);
}

/// `if_false` / `if_true` cold bodies: branch, then poll.
pub fn branchPoll32(vm: *Vm, opc: u8) HostError!void {
    try branch32(vm.ctx, vm.stack, vm.function, vm.frame, opc == op.if_true);
    try exception_ops.pollInterrupt(vm.ctx, vm.global);
}

/// `if_false8` / `if_true8` cold bodies: branch, then poll.
pub fn branchPoll8(vm: *Vm, opc: u8) HostError!void {
    try branch8(vm.ctx, vm.stack, vm.function, vm.frame, opc == op.if_true8);
    try exception_ops.pollInterrupt(vm.ctx, vm.global);
}

pub fn branch32(_: *core.JSContext, stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, branch_if_true: bool) !void {
    const operand_pc = frame.pc;
    const diff = readInt(i32, function.byteCode()[frame.pc..][0..4]);
    frame.pc += 4;
    const value = try stack.pop();
    const truthy = value.as(.boolean) orelse value_ops.isTruthy(value);
    if (truthy == branch_if_true) {
        frame.pc = relativePc(operand_pc, diff);
    }
}

pub fn branch8(_: *core.JSContext, stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, branch_if_true: bool) !void {
    const operand_pc = frame.pc;
    const diff: i8 = @bitCast(function.byteCode()[frame.pc]);
    frame.pc += 1;
    const value = try stack.pop();
    const truthy = value.as(.boolean) orelse value_ops.isTruthy(value);
    if (truthy == branch_if_true) {
        frame.pc = relativePc(operand_pc, diff);
    }
}

pub noinline fn throwTop(vm: *Vm) !ThrowResult {
    const ctx = vm.ctx;
    const stack = vm.stack;
    const catch_target = vm.catch_target;
    const value = try stack.pop();
    try forof_ops.closeStackTopForOfIteratorForPendingError(ctx, vm.output, vm.global, stack);
    try stack.reserveAdditional(1);
    if (catch_target.* == null) {
        if (try array_ops.popCatchMarker(ctx.runtime, stack)) |restored| {
            catch_target.* = restored;
        }
    }
    if (catch_target.*) |target| {
        const restored = (try array_ops.popCatchMarker(ctx.runtime, stack)) orelse null;
        stack.pushOwnedAssumeCapacity(value);
        vm.frame.pc = target;
        catch_target.* = restored;
        return .handled;
    }
    _ = ctx.throwValue(value);
    return error.JSException;
}

fn createAtomError(
    ctx: *core.JSContext,
    global: *core.Object,
    error_name: []const u8,
    atom_id: core.Atom,
    prefix: []const u8,
    suffix: []const u8,
) !core.JSValue {
    const atom_name = ctx.runtime.atoms.name(atom_id) orelse "lexical variable";
    const prefix_name_len = std.math.add(usize, prefix.len, atom_name.len) catch return error.OutOfMemory;
    const message_len = std.math.add(usize, prefix_name_len, suffix.len) catch return error.OutOfMemory;
    const message = try ctx.runtime.allocRuntime(u8, message_len);
    defer ctx.runtime.memory.free(u8, message);
    @memcpy(message[0..prefix.len], prefix);
    @memcpy(message[prefix.len..prefix_name_len], atom_name);
    @memcpy(message[prefix_name_len..], suffix);
    return exception_ops.createNamedError(ctx, global, error_name, message);
}

fn createThrowErrorValue(ctx: *core.JSContext, global: *core.Object, atom_id: core.Atom, error_type: u8) !core.JSValue {
    return switch (error_type) {
        0 => createAtomError(ctx, global, "TypeError", atom_id, "'", "' is read-only"),
        1 => createAtomError(ctx, global, "SyntaxError", atom_id, "redeclaration of '", "'"),
        2 => createAtomError(ctx, global, "ReferenceError", atom_id, "", " is not initialized"),
        3 => exception_ops.createNamedError(ctx, global, "ReferenceError", "unsupported reference to 'super'"),
        4 => exception_ops.createNamedError(ctx, global, "TypeError", "iterator does not have a throw method"),
        5 => exception_ops.createNamedError(ctx, global, "ReferenceError", "invalid assignment target"),
        else => blk: {
            var message_buffer: [64]u8 = undefined;
            const message = std.fmt.bufPrint(&message_buffer, "invalid throw var type {d}", .{error_type}) catch unreachable;
            break :blk exception_ops.createNamedError(ctx, global, "InternalError", message);
        },
    };
}

fn deliverPendingThrow(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    stack: *stack_mod.Stack,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    global: *core.Object,
    comptime err: anytype,
) !ThrowResult {
    if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .handled;
    return err;
}

pub noinline fn throwErrorVm(vm: *Vm) !ThrowResult {
    const ctx = vm.ctx;
    const output = vm.output;
    const stack = vm.stack;
    const frame = vm.frame;
    const catch_target = vm.catch_target;
    const global = vm.global;
    const atom_id = core.Atom.fromRaw(std.mem.readInt(u32, vm.function.byteCode()[frame.pc..][0..4], .little));
    const error_type = vm.function.byteCode()[frame.pc + 4];
    frame.pc += 5;
    const error_value = try createThrowErrorValue(ctx, global, atom_id, error_type);
    _ = ctx.throwValue(error_value);
    // Preserve the typed sentinel while carrying the richer pending exception.
    // Inline-call unwinding uses the sentinel to find a catch in an outer frame;
    // pendingExceptionMatchesError then transfers this exact Error object.
    return switch (error_type) {
        0, 4 => deliverPendingThrow(ctx, output, stack, frame, catch_target, global, error.TypeError),
        1 => deliverPendingThrow(ctx, output, stack, frame, catch_target, global, error.SyntaxError),
        2, 3, 5 => deliverPendingThrow(ctx, output, stack, frame, catch_target, global, error.ReferenceError),
        else => deliverPendingThrow(ctx, output, stack, frame, catch_target, global, error.JSException),
    };
}

pub noinline fn catchTarget(function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, stack: *stack_mod.Stack, catch_target: *?usize) !void {
    const operand_pc = frame.pc;
    const diff = readInt(i32, function.byteCode()[frame.pc..][0..4]);
    frame.pc += 4;
    const previous_target: i32 = if (catch_target.*) |target| @intCast(target) else -1;
    catch_target.* = relativePc(operand_pc, diff);
    try stack.pushOwned(core.JSValue.catchOffset(previous_target));
}

pub fn gosub(vm: *Vm) HostError!void {
    const frame = vm.frame;
    const operand_pc = frame.pc;
    const diff = readInt(i32, vm.function.byteCode()[frame.pc..][0..4]);
    const return_pc = frame.pc + 4;
    if (return_pc > @as(usize, @intCast(std.math.maxInt(i32)))) return error.InvalidBytecode;
    try vm.stack.pushOwned(core.JSValue.int32(@intCast(return_pc)));
    frame.pc = relativePc(operand_pc, diff);
}

pub fn ret(vm: *Vm) HostError!void {
    const target = try vm.stack.pop();
    const pc_i32 = target.as(.int) orelse return error.InvalidBytecode;
    if (pc_i32 < 0) return error.InvalidBytecode;
    const pc: usize = @intCast(pc_i32);
    if (pc >= vm.function.byteCode().len) return error.InvalidBytecode;
    vm.frame.pc = pc;
}

fn relativePc(operand_pc: usize, diff: anytype) usize {
    return @intCast(@as(i64, @intCast(operand_pc)) + @as(i64, diff));
}

fn adapterValueBorrow(slot: core.JSValue) core.JSValue {
    const cell = varRefCellFromValue(slot) orelse return slot;
    const value = cell.varRefValue();
    if (comptime builtin.mode == .Debug) {
        std.debug.assert(varRefCellFromValue(value) == null);
    }
    return value;
}

fn varRefCellFromValue(value: core.JSValue) ?*core.VarRef {
    return core.VarRef.fromValue(value);
}



// ----- merged from vm_eval_module.zig -----
// VM opcode helpers for direct eval, apply-eval, and dynamic import.
// 
// The active frame supplies lexical/caller authority, while module jobs and
// promise settlement stay in their owning modules. Stack operands are moved
// or released here before control returns to the dispatch loop.
const eval_ops = @import("eval_entry.zig");
const module_graph = @import("module.zig");
const promise_ops = @import("promise_ops.zig");
const string_ops = @import("string_ops.zig");
pub const EvalStep = union(enum) {
    done,
    continue_loop,
    /// Non-%eval% callee in tail position; eligible for frame reuse.
    tail_inline: call_runtime.InlineCallRequest,
};
pub noinline fn directEval(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    function: *const bytecode.FunctionBytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    output: ?*std.Io.Writer,
    global: *core.Object,
    caller_eval_global_var_bindings: bool,
    allow_tail_inline: bool,
) !EvalStep {
    const eval_operands = readInt(u32, function.byteCode()[frame.pc..][0..4]);
    frame.pc += 4;
    const argc: u16 = @intCast(eval_operands & 0xffff);
    const eval_scope: u16 = @intCast((eval_operands >> 16) & 0xffff);
    const eval_scope_head = @as(i32, eval_scope) + bytecode.function_bytecode.arg_scope_end;
    return switch (try eval_ops.execDirectEval(
        ctx,
        stack,
        function,
        frame,
        catch_target,
        argc,
        output,
        global,
        eval_scope_head,
        caller_eval_global_var_bindings,
        allow_tail_inline,
    )) {
        .done => .done,
        .continue_loop => .continue_loop,
        .tail_inline => |request| .{ .tail_inline = request },
    };
}

pub noinline fn applyEval(vm: *Vm) HostError!void {
    const eval_scope = readInt(u16, vm.function.byteCode()[vm.frame.pc..][0..2]);
    vm.frame.pc += 2;
    const eval_scope_head = @as(i32, eval_scope) + bytecode.function_bytecode.arg_scope_end;
    switch (try eval_ops.execApplyEval(
        vm.ctx,
        vm.stack,
        vm.function,
        vm.frame,
        vm.catch_target,
        vm.output,
        vm.global,
        eval_scope_head,
        dispatch.directEvalVarsReachGlobal(vm),
    )) {
        .done, .continue_loop => {},
        // eval_ops.execApplyEval never requests tail-call inlining.
        .tail_inline => unreachable,
    }
}

pub noinline fn dynamicImport(vm: *Vm) HostError!void {
    const ctx = vm.ctx;
    const global = vm.global;
    const stack = vm.stack;
    const options = try stack.pop();
    const specifier = try stack.pop();

    const prototype = promise_ops.promisePrototypeFromGlobal(ctx.runtime, global);
    const specifier_string = string_ops.toStringForAnnexB(ctx, vm.output, global, specifier, vm.function, vm.frame) catch |err| {
        const rejected = try exception_ops.rejectedPromiseForRuntimeError(ctx, global, err, prototype);
        try stack.pushOwned(rejected);
        return;
    };

    // Mirror qjs js_dynamic_import: the specifier ToString
    // (above) plus options/with-attribute validation run synchronously; the
    // load/link/evaluate work is deferred to an enqueued job (JS_EnqueueJob
    // quickjs.c) that settles the returned pending promise, so the
    // statement after import() runs before any module side effect. All
    // options validation, attribute-string enforcement, and attribute
    // threading live in module_graph.evaluateImportCall.
    // Referrer = the stable active ScriptOrModule identity (spec
    // GetActiveScriptOrModule, qjs JS_GetScriptOrModuleName quickjs.c).
    // Direct eval retains this separately from its "<eval>" display filename,
    // so escaped eval-created functions do not depend on live caller frames.
    const referrer_path = ctx.runtime.atoms.name(vm.function.scriptOrModule()) orelse "";
    const promise = module_graph.evaluateImportCall(ctx, vm.output, global, prototype, referrer_path, specifier_string, options, vm.function, vm.frame) catch |err| {
        const rejected = try exception_ops.rejectedPromiseForRuntimeError(ctx, global, err, prototype);
        try stack.pushOwned(rejected);
        return;
    };
    try stack.pushOwned(promise);
}



// ----- merged from vm_gen_async.zig -----
// Generator, async-function, `yield`, and `await` opcode state transitions.
// 
// Parking transfers frame and operand-stack backing into
// `GeneratorExecutionState`; open VarRefs attach to that owner and live VM
// views are cleared so resume or teardown releases each value exactly once.
// Await paths distinguish raw suspension from settled completion, including
// top-level module evaluation. The transition shape follows QuickJS's async
// opcode handling around quickjs.c.
const iterator_ops = @import("iterator_ops.zig");
pub const Result = union(enum) {
    none,
    continue_loop,
    return_value: core.JSValue,
};
pub const ResumeState = struct {
    throw_on_entry: bool = false,
    catch_target: ?usize = null,
};
const AwaitSuspendMode = enum {
    none,
    /// Legacy synchronous-drain mode. Kept for the non-suspending helper legs;
    /// module TLA now uses `.raw` and is resumed as an ordered Promise reaction.
    settled,
    /// Async functions and async generators yield the raw awaited value; the
    /// caller wires it through Promise.resolve(...).then(resume, reject),
    /// matching QuickJS OP_await (quickjs.c: save frame, return
    /// FUNC_RET_AWAIT with the operand at cur_sp[-1]).
    raw,
};
inline fn reserveGeneratorExecutionStackAdditional(rt: *core.JSRuntime, stack: *stack_mod.Stack, execution: *core.object.GeneratorExecutionState, additional: usize) !void {
    const parked = &execution.suspended.storage.stack;
    if (parked.values.len <= stack.stackLimit() and
        additional <= stack.stackLimit() - parked.values.len and
        parked.values.len <= parked.capacity and
        additional <= parked.capacity - parked.values.len)
    {
        return;
    }
    const resident_backing = execution.stackUsesCombinedStorage();
    try parked.ensureAdditionalWithResidentBacking(rt, stack.stackLimit(), additional, resident_backing);
}

fn sameSlice(comptime T: type, left: []T, right: []T) bool {
    return left.len == right.len and (left.len == 0 or left.ptr == right.ptr);
}

fn residentFrameViewsMatch(state: *const core.object.SuspendedExecutionState, frame: *const frame_mod.Frame) bool {
    const parked = state.storage.frame;
    return sameSlice(core.JSValue, parked.storage, frame.storage_values) and
        sameSlice(core.JSValue, parked.locals, frame.locals) and
        sameSlice(core.JSValue, parked.args, frame.args) and
        sameSlice(*core.VarRef, parked.var_refs, frame.var_refs) and
        sameSlice(?*core.VarRef, parked.open_var_refs, frame.open_var_refs);
}

fn clearLiveExecutionViews(stack: *stack_mod.Stack, frame: *frame_mod.Frame) void {
    stack.clearBacking();
    stack.setArenaWindow(false);
    stack.setResidentWindow(false);
    frame.storage_values = &.{};
    frame.ownership.storage = .borrowed;
    frame.locals = &.{};
    frame.args = &.{};
    frame.var_refs = &.{};
    frame.ownership.var_refs = .owned;
    frame.open_var_refs = &.{};
}

/// Park live execution slices without moving the resident frame on the common
/// path. QuickJS keeps one JSAsyncFunctionState backing allocation and changes
/// only cur_sp/cur_pc at a suspension; this is the corresponding zjs seam.
///
/// A defensive frame-growth path can replace one of the combined windows. In
/// that case publish the live descriptors once and return to the legacy
/// transfer model. Normal compiled generator frames are sized exactly and stay
/// on the descriptor-free resident path after their first suspension.
fn parkGeneratorExecutionState(
    rt: *core.JSRuntime,
    stack: *stack_mod.Stack,
    frame: *frame_mod.Frame,
    generator: *core.Object,
    execution: *core.object.GeneratorExecutionState,
    pc: usize,
    catch_target_pc: u32,
    has_frame: bool,
) void {
    // Parking copies a whole live frame -- operands, locals, args, cells, the
    // current function -- into storage the generator owns. Naming every value
    // individually would be a barrier per slot on a hot path and would have to
    // be kept in step with the frame layout; remembering the owner once is the
    // same guarantee, and is what the dense-array append choke point does for
    // the same reason.
    rt.gc.rememberOwnerForBulkWrite(generator.gcHeader());
    // An open cell borrows pvalue from this frame. Once a published generator
    // is parked, retain that storage owner exactly once in the cell, matching
    // QuickJS's attached JSVarRef -> JSAsyncFunctionState edge. Initial
    // parameter setup uses a detached shell; finishGeneratorShell installs
    // these edges immediately after publishing its fresh rc==1 header.
    if (generator.gcHeader().metaConst().alloc_info.heap_accounted) {
        const generator_value = generator.value();
        for (frame.open_var_refs) |maybe_cell| {
            const cell = maybe_cell orelse continue;
            cell.attachOpenOwner(rt, generator_value);
        }
    }

    const state = &execution.suspended;
    const was_resident_owner = state.running_aliases and state.resident_storage_owner;
    const frame_views_match = was_resident_owner and residentFrameViewsMatch(state, frame);

    if (frame_views_match) {
        const old_stack = state.storage.stack;
        const old_stack_uses_combined_storage = execution.stackUsesCombinedStorage();
        state.storage.stack = .{
            .values = stack.liveValues(),
            .capacity = stack.capacity,
        };
        state.pc = pc;
        state.catch_target_pc = catch_target_pc;
        state.has_frame = has_frame;
        state.running_aliases = false;
        clearLiveExecutionViews(stack, frame);

        // Stack growth copies raw owned slots to its new buffer. Once the new
        // view is authoritative, release only the old backing bytes; its stale
        // slot copies must never decrement references.
        if (old_stack.capacity != 0 and
            old_stack.values.ptr != state.storage.stack.values.ptr and
            !old_stack_uses_combined_storage)
        {
            rt.memory.free(core.JSValue, old_stack.values.ptr[0..old_stack.capacity]);
        }
        return;
    }

    if (was_resident_owner) {
        // Resident frame growth is expected only on defensive malformed or
        // synthetic bytecode paths. The first such change still starts from
        // the combined FAM backing, which remains owned by the execution-state
        // allocation after the live replacement is published.
        std.debug.assert(execution.frameUsesCombinedStorage() or state.storage.frame.storage.len == 0);
    }

    const old_stack = state.storage.stack;
    const old_stack_uses_combined_storage = execution.stackUsesCombinedStorage();
    var replacement = core.object.SuspendedExecutionStorage{
        .stack = .{
            .values = stack.liveValues(),
            .capacity = stack.capacity,
        },
        .frame = .{
            .storage = frame.storage_values,
            .locals = frame.locals,
            .args = frame.args,
            .var_refs = frame.var_refs,
            .open_var_refs = frame.open_var_refs,
        },
    };
    clearLiveExecutionViews(stack, frame);
    state.replaceStorageOwned(pc, catch_target_pc, &replacement, rt);
    state.has_frame = has_frame;

    if (was_resident_owner and old_stack.capacity != 0 and
        old_stack.values.ptr != state.storage.stack.values.ptr and
        !old_stack_uses_combined_storage)
    {
        rt.memory.free(core.JSValue, old_stack.values.ptr[0..old_stack.capacity]);
    }

    if (has_frame and !was_resident_owner and execution.canRetainResidentStorageOwnership()) {
        state.resident_storage_owner = true;
    }
}

/// Keep the ownership handoff as one cold-ish seam. Every yield/await opcode
/// reaches this helper, and duplicating its reset/swap/deinit sequence into
/// each handler measurably bloats the ReleaseFast instruction working set.
pub noinline fn saveGeneratorExecutionState(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    frame: *frame_mod.Frame,
    generator: *core.Object,
    pc: usize,
    catch_target: ?usize,
) !void {
    const execution = generator.generatorPayloadPtr().execution orelse return error.TypeError;
    // Generator frames must run on heap-backed stacks: suspension transfers
    // buffer ownership into the generator object, which is incompatible with
    // borrowed VM stack-arena windows.
    std.debug.assert(!stack.isArenaWindow());
    std.debug.assert(frame.ownership.storage == .owned or frame.storage_values.len == 0 or execution.frameUsesCombinedStorage());
    std.debug.assert(frame.ownership.var_refs == .owned or frame.var_refs.len == 0);
    std.debug.assert(frame.open_var_refs.len == 0 or frame.storage_values.len != 0);
    if (frame.open_var_refs.len != @as(usize, frame.function.openVarRefCount())) return error.InvalidBytecode;
    // Encode every fallible scalar before changing any ownership. An invalid
    // oversized target must leave the live VM state intact for normal unwind.
    const catch_target_pc = if (catch_target) |target|
        std.math.cast(u32, target) orelse return error.InvalidBytecode
    else
        std.math.maxInt(u32);
    parkGeneratorExecutionState(ctx.runtime, stack, frame, generator, execution, pc, catch_target_pc, true);
}

pub fn resumeExecutionState(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    function: *const bytecode.FunctionBytecode,
    frame: *frame_mod.Frame,
    generator: ?*core.Object,
    resume_value: ?core.JSValue,
) !ResumeState {
    const generator_object = generator orelse return .{};
    return resumeExecutionStateRaw(ctx, stack, function, frame, generator_object, resume_value);
}

/// Install parked buffers after every fallible resume preparation has
/// completed. The typed state keeps these addresses as non-owning aliases while
/// running, mirroring qjs's resident async frame with `cur_sp == NULL`. GC and
/// teardown consult `running_aliases`, so only the live Frame/Stack owns them.
inline fn installSuspendedExecutionStorage(
    stack: *stack_mod.Stack,
    frame: *frame_mod.Frame,
    state: *core.object.SuspendedExecutionState,
    resident_stack: bool,
    resident_frame: bool,
) void {
    const suspended = &state.storage;
    const resident_owner = state.resident_storage_owner;
    frame.storage_values = suspended.frame.storage;
    frame.ownership.storage = if (frame.storage_values.len != 0 and !resident_frame and !resident_owner) .owned else .borrowed;
    frame.locals = suspended.frame.locals;
    frame.args = suspended.frame.args;
    frame.var_refs = suspended.frame.var_refs;
    frame.ownership.var_refs = .owned;
    frame.open_var_refs = suspended.frame.open_var_refs;
    stack.installBacking(suspended.stack.values, suspended.stack.capacity);
    stack.setArenaWindow(false);
    stack.setResidentWindow(resident_stack or resident_owner);
    state.beginRunningAliases();
}

/// Clear aliases after completion/error. A suspension already republished the
/// live owners and cleared `running_aliases`, making this a cheap no-op there.
pub fn finishExecutionStateRun(rt: *core.JSRuntime, stack: *stack_mod.Stack, frame: *frame_mod.Frame, generator: ?*core.Object) void {
    const object = generator orelse return;
    // The payload outlives its nullable execution record. Internal module
    // continuations can complete and release that record before this defer.
    const execution = object.generatorPayloadPtr().execution orelse return;
    const state = &execution.suspended;
    if (!state.running_aliases) return;
    if (state.resident_storage_owner) {
        parkGeneratorExecutionState(rt, stack, frame, object, execution, frame.pc, std.math.maxInt(u32), false);
        return;
    }
    state.finishRunningAliases();
}

/// Keep generator-only ownership installation out of the universal
/// runWithArgsState frame. The nullable wrapper still folds to a cheap null
/// return for ordinary calls, while an actual resume crosses this boundary
/// once, like qjs's async_func_resume re-entry seam.
noinline fn resumeExecutionStateRaw(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    function: *const bytecode.FunctionBytecode,
    frame: *frame_mod.Frame,
    generator: *core.Object,
    resume_value: ?core.JSValue,
) align(64) !ResumeState {
    const payload = generator.generatorPayloadPtr();
    const execution = payload.execution orelse return error.TypeError;
    const state = &execution.suspended;
    if (!state.has_frame) {
        if (execution.stackUsesCombinedStorage()) {
            std.debug.assert(stack.capacity == 0 and stack.len() == 0);
            stack.installBacking(state.storage.stack.values, state.storage.stack.capacity);
            stack.setArenaWindow(false);
            stack.setResidentWindow(true);
            state.beginRunningAliases();
        }
        payload.just_yielded = false;
        return .{};
    }
    // Resume installs generator-owned heap buffers into the stack; the stack
    // must not be an arena window (its deinit would skip freeing them).
    std.debug.assert(!stack.isArenaWindow());
    // ESCAPE CONTRACT (v2 escape audit §5.4, git history): `state.pc` is a bare
    // compiler-assigned offset — not a tagged pointer and not a
    // (function, offset) pair — so it has no provenance of its own. `function`
    // arrives as a parameter independent of `generator`. Resume must pin the
    // callee to the continuation's own function: indexing one function's parked
    // pc into another's bytecode is forbidden. Every production resume derives
    // the callee from the continuation itself. Null-tolerant by design: module
    // continuations carry no current_function, and an internal self-referential
    // fixture resolves to none.
    if (generator.generatorFunctionBytecode()) |retained| {
        std.debug.assert(call_runtime.functionBytecodeFromValue(retained) == function);
    }

    const resume_pc = state.pc;
    const generator_started = payload.started;
    const was_yield_star_suspended = generator_started and payload.yield_star_suspended;
    const completion: core.generator_state.ResumeCompletion = if (generator_started) payload.resume_completion else .next;
    const resume_needs_branch_false = generator_started and
        resume_pc > 0 and
        resume_pc <= function.byteCode().len and
        function.byteCode()[resume_pc - 1] == bytecode.opcode.op.yield and
        resume_pc < function.byteCode().len and
        (function.byteCode()[resume_pc] == bytecode.opcode.op.if_false or function.byteCode()[resume_pc] == bytecode.opcode.op.if_false8);

    var resume_push_count: usize = if (!generator_started)
        0
    else if (was_yield_star_suspended)
        2
    else if (completion == .throw)
        0
    else
        1;
    if (resume_needs_branch_false) resume_push_count += 1;
    try reserveGeneratorExecutionStackAdditional(ctx.runtime, stack, execution, resume_push_count);

    payload.just_yielded = false;
    // Started resumes no longer build a throwaway frame slab in zjs_vm. The
    // fresh Frame contains only borrowed call bindings until the resident
    // windows below are installed, so there is no pre-existing storage to
    // close or release here.
    std.debug.assert(frame.storage_values.len == 0);
    std.debug.assert(frame.locals.len == 0 and frame.args.len == 0);
    std.debug.assert(frame.var_refs.len == 0 and frame.open_var_refs.len == 0);
    frame.pc = resume_pc;
    const resident_stack = execution.stackUsesCombinedStorage();
    const resident_frame = execution.frameUsesCombinedStorage();
    if (state.storage.frame.open_var_refs.len != @as(usize, function.openVarRefCount())) return error.InvalidBytecode;
    installSuspendedExecutionStorage(stack, frame, state, resident_stack, resident_frame);
    // The parked target is the authoritative dynamic control state. A shared
    // finalizer PC can be entered from several differently nested catch legs,
    // so its bytecode address alone cannot reconstruct the active target.
    const catch_target = state.catchTarget();

    if (!generator_started) return .{ .catch_target = catch_target };
    if (was_yield_star_suspended) {
        payload.yield_star_suspended = false;
        payload.resume_completion = .next;
        stack.pushAssumeCapacity(resume_value orelse core.JSValue.undefinedValue());
        stack.pushOwnedAssumeCapacity(core.JSValue.int32(@intFromEnum(completion)));
    } else {
        if (completion == .throw) {
            payload.resume_completion = .next;
            if (resume_needs_branch_false) {
                stack.pushOwnedAssumeCapacity(core.JSValue.boolean(false));
            }
            return .{ .throw_on_entry = true, .catch_target = catch_target };
        }
        stack.pushAssumeCapacity(resume_value orelse core.JSValue.undefinedValue());
        if (completion != .next) payload.resume_completion = .next;
    }
    if (resume_needs_branch_false) {
        // A plain `yield` resumes with the QuickJS two-slot protocol:
        // `[resume_value, completion_magic]`.  The parser lowers the magic
        // test to `if_false normal_resume`; NEXT is false while RETURN must
        // fall through to the compiled return/iterator/finally cleanup path.
        stack.pushOwnedAssumeCapacity(core.JSValue.boolean(completion == .return_));
    }
    return .{ .catch_target = catch_target };
}

pub fn completeResumeState(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.FunctionBytecode,
    frame: *frame_mod.Frame,
    state: ResumeState,
    resume_value: ?core.JSValue,
) !?usize {
    var catch_target = state.catch_target;
    if (!state.throw_on_entry) return catch_target;
    const thrown = resume_value orelse core.JSValue.undefinedValue();
    _ = ctx.throwValue(thrown);
    try closeIteratorForPendingError(ctx, output, global, stack, function, frame);
    if (!(try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, &catch_target, global, error.JSException))) {
        return error.JSException;
    }
    return catch_target;
}

fn handleAwaitError(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.FunctionBytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    err: HostError,
) HostError!bool {
    try closeIteratorForPendingError(ctx, output, global, stack, function, frame);
    return try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err);
}

pub fn stopBeforePc(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    frame: *frame_mod.Frame,
    generator: ?*core.Object,
    catch_target: ?usize,
    stop_before_pc: ?usize,
) !?core.JSValue {
    const stop_pc = stop_before_pc orelse return null;
    if (frame.pc != stop_pc) return null;
    if (generator) |generator_object| {
        try parkGeneratorStartBoundary(ctx, stack, frame, generator_object, stop_pc, catch_target);
    }
    return core.JSValue.undefinedValue();
}

fn parkGeneratorStartBoundary(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    frame: *frame_mod.Frame,
    generator: *core.Object,
    pc: usize,
    catch_target: ?usize,
) !void {
    // QuickJS closes parameter-environment refs at OP_initial_yield while
    // keeping arg_buf resident. zjs shares one open-ref table for args and
    // locals, so close only the parameter-environment entries before parking.
    // The started/just-yielded bits intentionally remain false: this is the
    // suspended-start control boundary, not a user-visible yield.
    if (!generator.generatorStarted()) try frame.closeParameterEnvironmentVarRefs(ctx.runtime);
    try saveGeneratorExecutionState(ctx, stack, frame, generator, pc, catch_target);
    generator.generatorSuspendKindSlot().* = @intFromEnum(core.object.GeneratorSuspendKind.none);
}

pub fn initialYield(vm: *Vm) !Result {
    const stack = vm.stack;
    if (dispatch.stopOnYield(vm)) {
        if (dispatch.generatorState(vm)) |generator_object| {
            const frame = vm.frame;
            try parkGeneratorStartBoundary(vm.ctx, stack, frame, generator_object, frame.pc, vm.catch_target.*);
        }
        return .{ .return_value = core.JSValue.undefinedValue() };
    }
    try stack.pushOwned(core.JSValue.undefinedValue());
    return .none;
}

pub noinline fn yieldValue(vm: *Vm) !Result {
    const stack = vm.stack;
    const value = try stack.pop();
    if (dispatch.stopOnYield(vm)) {
        if (dispatch.generatorState(vm)) |generator_object| {
            const frame = vm.frame;
            try saveGeneratorExecutionState(vm.ctx, stack, frame, generator_object, frame.pc, vm.catch_target.*);
            const payload = generator_object.generatorPayloadPtr();
            payload.suspend_kind = @intFromEnum(core.object.GeneratorSuspendKind.yield);
            payload.started = true;
            payload.just_yielded = true;
        }
        return .{ .return_value = value };
    }
    try stack.reserveAdditional(1);
    stack.pushOwnedAssumeCapacity(core.JSValue.undefinedValue());
    return .none;
}

pub noinline fn yieldStar(vm: *Vm) !Result {
    const ctx = vm.ctx;
    const output = vm.output;
    const global = vm.global;
    const stack = vm.stack;
    const frame = vm.frame;
    const catch_target = vm.catch_target;
    return yieldStarRaw(ctx, output, global, stack, vm.function, frame, dispatch.generatorState(vm), dispatch.stopOnYield(vm), catch_target.*) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) {
            return .continue_loop;
        }
        return err;
    };
}

fn yieldStarRaw(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.FunctionBytecode,
    frame: *frame_mod.Frame,
    generator: ?*core.Object,
    stop_on_yield: bool,
    catch_target: ?usize,
) !Result {
    const opcode_pc = frame.pc - 1;
    const expanded_lowering = frame.pc < function.byteCode().len and function.byteCode()[frame.pc] == bytecode.opcode.op.dup;
    if (expanded_lowering) {
        const result_object = try stack.pop();
        if (stop_on_yield) {
            if (generator) |generator_object| {
                try saveGeneratorExecutionState(ctx, stack, frame, generator_object, frame.pc, catch_target);
                generator_object.generatorSuspendKindSlot().* = @intFromEnum(core.object.GeneratorSuspendKind.yield_star);
                try call_runtime.setGeneratorYieldStarSuspended(ctx.runtime, generator_object, true);
                generator_object.generatorStartedSlot().* = true;
                generator_object.generatorJustYieldedSlot().* = true;
            } else {
                try stack.reserveAdditional(2);
                stack.pushOwnedAssumeCapacity(core.JSValue.undefinedValue());
                stack.pushOwnedAssumeCapacity(core.JSValue.int32(0));
                return .none;
            }
            return .{ .return_value = result_object };
        }
        try stack.reserveAdditional(2);
        stack.pushOwnedAssumeCapacity(core.JSValue.undefinedValue());
        stack.pushOwnedAssumeCapacity(core.JSValue.int32(0));
        return .none;
    }

    var iterator_value: core.JSValue = undefined;
    var using_stored_iterator = false;
    var next_arg = core.JSValue.undefinedValue();
    if (generator) |generator_object| {
        if (generator_object.generatorYieldStarIterator()) |stored| {
            iterator_value = stored;
            using_stored_iterator = true;
            if (generator_object.generatorStarted() and stack.len() > 0) {
                next_arg = try stack.pop();
            }
        } else {
            const iterable = try stack.pop();
            iterator_value = try iterator_ops.iteratorForValue(ctx, output, global, iterable, function, frame);
        }
    } else {
        const iterable = try stack.pop();
        iterator_value = try iterator_ops.iteratorForValue(ctx, output, global, iterable, function, frame);
    }
    const step = try iterator_ops.iteratorStepResult(ctx, output, global, iterator_value, next_arg);
    if (step.done) {
        try stack.reserveAdditional(1);
        if (generator) |generator_object| {
            generator_object.clearGeneratorYieldStarIterator();
        }
        stack.pushAssumeCapacity(step.value);
        return .continue_loop;
    }
    if (stop_on_yield) {
        if (generator) |generator_object| {
            if (!using_stored_iterator) generator_object.setGeneratorYieldStarIterator(iterator_value);
            try saveGeneratorExecutionState(ctx, stack, frame, generator_object, opcode_pc, catch_target);
            generator_object.generatorSuspendKindSlot().* = @intFromEnum(core.object.GeneratorSuspendKind.yield_star);
            generator_object.generatorStartedSlot().* = true;
            generator_object.generatorJustYieldedSlot().* = true;
        }
        return .{ .return_value = step.result };
    }
    try stack.reserveAdditional(1);
    stack.pushOwnedAssumeCapacity(core.JSValue.undefinedValue());
    return .none;
}

pub noinline fn awaitValue(vm: *Vm) HostError!Result {
    const ctx = vm.ctx;
    const output = vm.output;
    const global = vm.global;
    const stack = vm.stack;
    const function = vm.function;
    const frame = vm.frame;
    const catch_target = vm.catch_target;
    return awaitValueRaw(ctx, output, global, stack, function, frame, dispatch.generatorState(vm), dispatch.suspendOnModuleAwait(vm), dispatch.stopOnYield(vm), catch_target.*) catch |err| {
        if (try handleAwaitError(ctx, output, global, stack, function, frame, catch_target, err)) {
            return .continue_loop;
        }
        return err;
    };
}

fn awaitValueRaw(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.FunctionBytecode,
    frame: *frame_mod.Frame,
    generator: ?*core.Object,
    suspend_on_module_await: bool,
    stop_on_yield: bool,
    catch_target: ?usize,
) HostError!Result {
    const suspend_mode = awaitSuspendMode(function, suspend_on_module_await, stop_on_yield);
    const awaited = try stack.pop();
    if (suspend_mode == .raw) {
        if (try suspendAwaitValue(ctx, stack, frame, generator, true, awaited, catch_target)) |result| return result;
        try stack.push(awaited);
        return .continue_loop;
    }
    const promise = objectFromValue(awaited) orelse {
        if (try promise_ops.awaitThenableValue(ctx, output, global, awaited, function, frame)) |value| {
            if (try suspendAwaitValue(ctx, stack, frame, generator, suspend_mode == .settled, value, catch_target)) |result| return result;
            try stack.push(value);
            return .none;
        }
        if (try suspendAwaitValue(ctx, stack, frame, generator, suspend_mode == .settled, awaited, catch_target)) |result| return result;
        try stack.push(awaited);
        return .continue_loop;
    };
    if (promise.class_id != core.class.ids.promise) {
        if (try promise_ops.awaitThenableValue(ctx, output, global, awaited, function, frame)) |value| {
            if (try suspendAwaitValue(ctx, stack, frame, generator, suspend_mode == .settled, value, catch_target)) |result| return result;
            try stack.push(value);
            return .none;
        }
        if (try suspendAwaitValue(ctx, stack, frame, generator, suspend_mode == .settled, awaited, catch_target)) |result| return result;
        try stack.push(awaited);
        return .continue_loop;
    }
    try promise_ops.settlePendingPromiseReaction(ctx, output, global, promise);
    if (suspend_mode == .settled and promise.promiseResult() == null) try promise_ops.drainPendingPromiseJobs(ctx, output, global);
    if (promise.promiseResult() == null) try promise_ops.awaitPendingPromise(ctx, output, global, promise);
    const result = if (promise.promiseResult()) |stored| stored else core.JSValue.undefinedValue();
    if (promise.promiseIsRejected()) {
        _ = ctx.throwValue(result);
        return error.JSException;
    }
    if (try suspendAwaitValue(ctx, stack, frame, generator, suspend_mode == .settled, result, catch_target)) |suspended| return suspended;
    try stack.push(result);
    return .none;
}

fn suspendAwaitValue(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    frame: *frame_mod.Frame,
    generator: ?*core.Object,
    suspend_on_await: bool,
    value: core.JSValue,
    catch_target: ?usize,
) !?Result {
    if (!suspend_on_await) return null;
    const generator_object = generator orelse return null;
    try saveGeneratorExecutionState(ctx, stack, frame, generator_object, frame.pc, catch_target);
    generator_object.generatorSuspendKindSlot().* = @intFromEnum(core.object.GeneratorSuspendKind.await_op);
    generator_object.generatorStartedSlot().* = true;
    generator_object.generatorJustYieldedSlot().* = true;
    return .{ .return_value = value };
}

fn awaitSuspendMode(function: *const bytecode.FunctionBytecode, suspend_on_module_await: bool, stop_on_yield: bool) AwaitSuspendMode {
    if (suspend_on_module_await and function.isModule()) return .raw;
    if (suspend_on_module_await and function.isAsync()) return .raw;
    // Async-generator bodies genuinely suspend at every await; the queue
    // machine (exec/promise_ops.zig) resumes them via promise-reaction
    // jobs (mirrors js_async_generator_await + resume trampolines,
    // quickjs.c).
    if (stop_on_yield and function.isAsync()) return .raw;
    return .none;
}

fn closeIteratorForPendingError(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.FunctionBytecode,
    frame: *frame_mod.Frame,
) !void {
    if (frame.pc < function.byteCode().len and function.byteCode()[frame.pc] == bytecode.opcode.op.iterator_get_value_done) {
        // for-await-of: qjs js_for_await_of_next DISABLES the catch offset for
        // the await between OP_for_await_of_next and
        // OP_iterator_get_value_done — a rejection
        // while awaiting the step result must NOT close the iterator from the
        // unwind path; the AsyncFromSyncIterator close-wrap reaction
        // is the only closer.
        return;
    }
    try forof_ops.closeStackTopForOfIteratorForPendingError(ctx, output, global, stack);
}

const objectFromValue = core.value_semantics.objectFromValueTrustedExpression;


// ----- merged from vm_literal.zig -----
// Object, array, spread, rest, and special-object literal opcode adapters.
// 
// Popped stack values are owned locally; successful property insertion or
// stack push transfers them, while guarded fast probes remain borrow-until-
// commit. Observable iterator and property work stays on the explicit call
// environment. The opcode bodies follow QuickJS object/field creation at
// quickjs.c and quickjs.c, spread copying at quickjs.c,
// and rest-array construction at quickjs.c.
const object_ops = @import("object_ops.zig");
const special_object_subtype = bytecode.opcode.special_object_subtype;
pub noinline fn objectLiteral(vm: *Vm) HostError!void {
    const created = try core.Object.create(vm.ctx.runtime, core.class.ids.object, object_ops.objectPrototypeFromGlobal(vm.ctx.runtime, vm.global));
    const value = created.value();
    try vm.stack.pushOwned(value);
}

pub noinline fn objectReserved2(vm: *Vm) HostError!void {
    const created = try core.Object.createPlainObjectReserved2(
        vm.ctx.runtime,
        object_ops.objectPrototypeFromGlobal(vm.ctx.runtime, vm.global),
    );
    const value = created.value();
    try vm.stack.pushOwned(value);
}

/// Frameless OP_object fast path (qjs CASE(OP_object): `*sp++ = JS_NewObject(ctx)`,
/// quickjs.c). Creates a bare `{}` and returns it OWNED for the handler to push
/// onto the register-resident sp, so no `publish`/stack round-trip is needed — object
/// creation runs no user code and captures no backtrace (qjs sets no `sf->cur_pc`
/// here), only OOM can fail (→ handler routes to the cold shell). Mirrors the object()
/// body minus the stack.pushOwned so the value stays in a register.
pub inline fn newPlainObjectValue(ctx: *core.JSContext, global: *core.Object) !core.JSValue {
    const created = try core.Object.create(ctx.runtime, core.class.ids.object, object_ops.objectPrototypeFromGlobal(ctx.runtime, global));
    return created.value();
}

pub inline fn newPlainObjectReserved2Value(ctx: *core.JSContext, global: *core.Object) !core.JSValue {
    const created = try core.Object.createPlainObjectReserved2(
        ctx.runtime,
        object_ops.objectPrototypeFromGlobal(ctx.runtime, global),
    );
    return created.value();
}

/// Frameless OP_define_field fast leg (qjs CASE(OP_define_field): a single
/// JS_DefinePropertyValue on sp[-2] with sp[-1], quickjs.c). Handles the
/// plain-data-add/replace on a plain, extensible, non-array, non-exotic, non-proxy
/// `obj` for ANY value shape — qjs's define path carries no value-form gate either:
/// a refcounted value ({left:obj,right:obj} literals) takes the same
/// JS_DefinePropertyValue fast route as an int. No explicit value rooting is needed
/// across the shape-transition alloc/GC: the value keeps its live refcount in the
/// (unpublished) sp slot, and cycle removal is qjs-faithful trial deletion
/// (gc_decref/gc_scan) — a refcount unaccounted for by traced children IS an
/// external root, so the stack-held ref keeps the value alive. Returns true on a
/// completed define (handler pops the value + keeps obj as the literal receiver);
/// false routes to the cold shell (arrays, proxies, non-extensible, setters — every
/// backtrace/user-code-capable case stays on the publishing path). `value` is
/// CONSUMED into the property slot on success (like the cold leg's Descriptor.data)
/// and NOT consumed on `false` — definePlainDataPropertyKnownFast is
/// borrow-until-commit on its failure paths, so the cold shell re-executes the
/// opcode with the stack's ownership intact (no double-free on OOM mid-append).
///
/// No private-atom probe: OP_define_field's u32 operand is a parser-minted
/// property-name atom — every private name is discriminated at parse time into
/// the define/get/put_private_field family (qjs OP_define_field likewise
/// carries no JS_ATOM_TYPE_PRIVATE test, quickjs.c), so the
/// mightBePrivate 3-load chain was a zjs-only tax on the trusted bytecode-atom
/// path (op_get/put_field precedent). Debug keeps the precise kind claim.
/// The receiver is likewise an evaluated expression value (OP_object /
/// push_this / any literal-start), never a make_ref cell pair, so the
/// trusted-expression classification skips the header-kind re-load.
pub inline fn defineFieldFast(rt: *core.JSRuntime, obj: core.JSValue, atom_id: core.Atom, value: core.JSValue) bool {
    if (comptime builtin.mode == .Debug) {
        std.debug.assert(rt.atoms.kind(atom_id) != .private);
    }
    const target = object_ops.objectFromValueTrustedExpression(obj) orelse return false;
    // qjs OP_define_field → JS_DefinePropertyValue with JS_PROP_THROW: only a plain
    // ordinary object with room to add a data property takes the in-CASE fast add;
    // everything exotic/proxy/array/non-extensible defers to the general define.
    if (target.class_id != core.class.ids.object) return false;
    if (target.hasExoticMethods()) return false;
    if (target.proxyTarget() != null) return false;
    if (target.isArray()) return false;
    if (!target.flags.extensible) return false;
    target.definePlainDataPropertyKnownFast(rt, atom_id, value) catch return false;
    return true;
}

pub noinline fn arrayFrom(vm: *Vm) HostError!void {
    const ctx = vm.ctx;
    const argc = readInt(u16, vm.function.byteCode()[vm.frame.pc..][0..2]);
    vm.frame.pc += 2;
    var stack_values: [8]core.JSValue = undefined;
    const values = if (argc <= stack_values.len)
        stack_values[0..argc]
    else
        try ctx.runtime.memory.alloc(core.JSValue, argc);
    defer if (argc > stack_values.len) ctx.runtime.memory.free(core.JSValue, values);
    var remaining: usize = argc;
    while (remaining > 0) {
        remaining -= 1;
        values[remaining] = try vm.stack.pop();
    }
    const array = try core.array.constructLiteralWithPrototype(ctx.runtime, values, array_ops.arrayPrototypeFromGlobal(ctx.runtime, vm.global));
    try vm.stack.pushOwned(array);
}

pub noinline fn defineField(vm: *Vm) HostError!void {
    const ctx = vm.ctx;
    const frame = vm.frame;
    const atom_id = core.Atom.fromRaw(readInt(u32, vm.function.byteCode()[frame.pc..][0..4]));
    frame.pc += 4;
    if (ctx.runtime.atoms.kind(atom_id) == .private) return error.InvalidBytecode;
    const value = try vm.stack.pop();
    const obj = vm.stack.peekBorrowed() orelse return error.StackUnderflow;
    if (!value.isTracerOwned()) {
        if (property_ops.expectObject(obj)) |target| {
            // flags.extensible gate: qjs OP_define_field goes
            // through JS_DefinePropertyValue with JS_PROP_THROW, which enforces
            // extensibility in JS_CreateProperty — a non-extensible
            // object must fall through to createDataPropertyOrThrow's TypeError.
            if (target.class_id == core.class.ids.object and
                !target.hasExoticMethods() and
                target.proxyTarget() == null and
                !target.isArray() and
                target.flags.extensible)
            {
                try target.definePlainDataPropertyKnownFast(ctx.runtime, atom_id, value);
                return;
            }
        } else |_| {}
    }
    var rooted_value = value;
    var rooted_obj = obj;
    var root_frame = core.runtime.rootValues(.{ &rooted_value, &rooted_obj });
    root_frame.activate(ctx.runtime);
    defer root_frame.deactivate(ctx.runtime);

    const target = try property_ops.expectObject(obj);
    if (target.isArray() and atom_id == core.atom.ids.length and
        target.flags.length_writable and target.shape_ref.prop_count == 0)
    {
        if (value.as(.int)) |length| {
            const new_len: u32 = @intCast(@max(length, 0));
            // No index properties to delete, so the length set reduces to the
            // dense case: growth keeps the fast array (tail holes), shrink frees
            // the dense tail via truncateArrayElements. No sparse conversion
            // either way — faithful to set_array_length.
            // Arrays carrying index properties fall through to defineArrayLength.
            target.truncateArrayElements(ctx.runtime, new_len);
            target.setArrayLength(new_len);
            return;
        }
    }
    if (target.isArray()) {
        if (core.array.arrayIndexFromAtom(&ctx.runtime.atoms, atom_id)) |index| {
            if (try target.defineDenseArrayDataProperty(ctx.runtime, index, rooted_value)) return;
        }
    }
    if (target.class_id == core.class.ids.object and
        !target.hasExoticMethods() and
        target.proxyTarget() == null and
        !target.isArray() and
        target.flags.extensible and
        target.shape_ref.prop_count == 0)
    {
        try target.defineOwnPropertyAssumingNew(ctx.runtime, atom_id, core.Descriptor.data(rooted_value, .all));
        return;
    }
    object_ops.createDataPropertyOrThrow(ctx, vm.output, vm.global, rooted_obj, target, atom_id, rooted_value, vm.function, frame) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(ctx, vm.output, vm.stack, frame, vm.catch_target, vm.global, err)) return;
        return err;
    };
}

pub noinline fn setProto(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
) !void {
    const proto_value = try stack.pop();
    const obj = stack.peek() orelse return error.StackUnderflow;
    const object_value = try property_ops.expectObject(obj);
    if (proto_value.is(.null_value)) {
        try object_value.setPrototype(ctx.runtime, null);
    } else if (proto_value.is(.object)) {
        try object_value.setPrototype(ctx.runtime, try property_ops.expectObject(proto_value));
    }
}

pub noinline fn defineArrayEl(vm: *Vm) HostError!void {
    const ctx = vm.ctx;
    const output = vm.output;
    const global = vm.global;
    const stack = vm.stack;
    const frame = vm.frame;
    const value = try stack.pop();
    var rooted_value = value;
    const index = try stack.pop();
    var rooted_index = index;
    const array_value = stack.peek() orelse return error.StackUnderflow;
    var rooted_array = array_value;

    var root_frame = core.runtime.rootValues(.{ &rooted_value, &rooted_index, &rooted_array });
    root_frame.activate(ctx.runtime);
    defer root_frame.deactivate(ctx.runtime);

    const object_value = property_ops.expectObject(rooted_array) catch |err|
        return try handleLiteralRuntimeError(ctx, output, stack, frame, vm.catch_target, global, err);
    const atom_id = object_ops.toPropertyKeyAtom(ctx, output, global, rooted_index, vm.function, frame) catch |err|
        return try handleLiteralRuntimeError(ctx, output, stack, frame, vm.catch_target, global, err);
    object_ops.createDataPropertyOrThrow(ctx, output, global, rooted_array, object_value, atom_id, rooted_value, vm.function, frame) catch |err|
        return try handleLiteralRuntimeError(ctx, output, stack, frame, vm.catch_target, global, err);
    try stack.push(rooted_index);
}

pub fn appendSpreadValues(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    opc: u8,
) !void {
    const iterable = try stack.pop();
    const index = try stack.pop();
    _ = opc;
    const array_value = stack.peek() orelse return error.StackUnderflow;
    const array = try property_ops.expectObject(array_value);
    const start_index = index.as(.int) orelse 0;
    // Faithful to qjs js_append_enumerate: resolve @@iterator
    // and create the iterator, taking the dense bulk copy ONLY when the Array
    // iterator protocol is un-tampered. The former `is_array`-only fast path
    // silently ignored a user-patched src[Symbol.iterator] / %ArrayIteratorPrototype%.next.
    const out_index = try call_runtime.appendSpreadValuesEnumerate(ctx, output, global, array, iterable, start_index);
    try stack.pushOwned(core.JSValue.int32(out_index));
}

pub noinline fn appendSpreadValuesVm(vm: *Vm, opc: u8) HostError!void {
    appendSpreadValues(vm.ctx, vm.output, vm.global, vm.stack, opc) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(vm.ctx, vm.output, vm.stack, vm.frame, vm.catch_target, vm.global, err)) return;
        return err;
    };
}

pub noinline fn copyDataProperties(vm: *Vm) HostError!void {
    const ctx = vm.ctx;
    const output = vm.output;
    const global = vm.global;
    const stack = vm.stack;
    const caller_frame = vm.frame;
    const catch_target = vm.catch_target;
    const mask = vm.function.byteCode()[vm.frame.pc];
    vm.frame.pc += 1;
    const rt = ctx.runtime;
    const target_value = try stackValueFromTop(stack, mask & 3);
    var rooted_target_value = target_value;
    const source_value = try stackValueFromTop(stack, (mask >> 2) & 7);
    var rooted_source_value = source_value;
    const exclusion_value = try stackValueFromTop(stack, (mask >> 5) & 7);
    var rooted_exclusion_value = exclusion_value;

    var root_frame = core.runtime.rootValues(.{
        &rooted_target_value,
        &rooted_source_value,
        &rooted_exclusion_value,
    });
    root_frame.activate(rt);
    defer root_frame.deactivate(rt);

    // qjs JS_CopyDataProperties skips EVERY non-object
    // source — `{...5}`, `{...true}`, `{..."ab"}`, `{...Symbol()}` all yield no
    // properties, not just null/undefined. (Object-rest destructuring still
    // copies from a wrapped string because its source is objectified upstream
    // before OP_copy_data_properties, both engines.) The former
    // null/undefined-only skip let a primitive source fall into expectObject's
    // TypeError — a divergence from qjs, not a spec-ordering guard.
    if (!rooted_source_value.is(.object)) return;

    const target = property_ops.expectObject(rooted_target_value) catch |err|
        return try handleLiteralRuntimeError(ctx, output, stack, caller_frame, catch_target, global, err);
    const source = property_ops.expectObject(rooted_source_value) catch |err|
        return try handleLiteralRuntimeError(ctx, output, stack, caller_frame, catch_target, global, err);
    const exclusion: ?*core.Object = if (rooted_exclusion_value.is(.null_value) or rooted_exclusion_value.is(.undefined_value))
        null
    else
        property_ops.expectObject(rooted_exclusion_value) catch |err|
            return try handleLiteralRuntimeError(ctx, output, stack, caller_frame, catch_target, global, err);
    const keys = object_ops.objectRestOwnKeys(ctx, output, global, source) catch |err|
        return try handleLiteralRuntimeError(ctx, output, stack, caller_frame, catch_target, global, err);
    defer core.Object.freeKeys(rt, keys);

    // qjs JS_CopyDataProperties requests JS_GPN_ENUM_ONLY
    // for an ordinary (non-exotic) source, so the per-key enumerable
    // descriptor probe is folded into the key enumeration up-front: the key
    // set is already enumerable-filtered before the copy loop runs any
    // user getter, and each surviving key takes a single JS_GetProperty.
    // Only an exotic source with a get_own_property_names hook (a Proxy, or
    // a typed array / module namespace here) keeps JS_GPN_ENUM_ONLY cleared,
    // so its descriptor test stays interleaved with the per-key get (trap
    // ordering for a proxy: gopd:k, get:k, ...).
    const source_is_ordinary = source.proxyTarget() == null and
        !core.object.isTypedArrayObject(source) and
        source.class_id != core.class.ids.module_ns;
    if (source_is_ordinary) {
        // Up-front enumerable snapshot. getOwnProperty for an ordinary source
        // never invokes a user getter (it surfaces the getter function, not
        // its result), so resolving every key's enumerability here is free of
        // observable side effects -- and it freezes which keys copy before any
        // value getter can mutate a later key's enumerability/existence
        // (qjs ENUM_ONLY snapshots tab_atom once up front).
        const copy_flags = try rt.memory.alloc(bool, keys.len);
        defer rt.memory.free(bool, copy_flags);
        for (keys, copy_flags) |key, *copy| {
            if (exclusion) |excluded| {
                if (excluded.hasOwnProperty(key)) {
                    copy.* = false;
                    continue;
                }
            }
            copy.* = switch (source.ownPropertyEnumerableKind(rt, key)) {
                .enumerable => true,
                .not_enumerable => false,
                // Ordinary sources never yield `.descriptor` here (typed
                // arrays / module namespaces are routed to the interleaved
                // path above); fall back defensively if that ever changes.
                .descriptor => blk: {
                    const maybe_desc = object_ops.objectRestOwnPropertyDescriptor(ctx, output, global, source, key) catch |err|
                        return try handleLiteralRuntimeError(ctx, output, stack, caller_frame, catch_target, global, err);
                    const desc = maybe_desc orelse break :blk false;
                    break :blk (desc.enumerable orelse false);
                },
            };
        }
        for (keys, copy_flags) |key, copy| {
            if (!copy) continue;
            const value = object_ops.getValueProperty(ctx, output, global, rooted_source_value, key, vm.function, caller_frame) catch |err|
                return try handleLiteralRuntimeError(ctx, output, stack, caller_frame, catch_target, global, err);
            var rooted_value = value;
            var value_root_values = [_]core.runtime.ValueRootValue{
                .{ .value = &rooted_value },
            };
            var value_root_frame = core.runtime.ValueRootFrame{
                .values = &value_root_values,
            };
            value_root_frame.activate(rt);
            defer value_root_frame.deactivate(rt);
            property_ops.defineDataProperty(rt, target, key, rooted_value) catch |err|
                return try handleLiteralRuntimeError(ctx, output, stack, caller_frame, catch_target, global, err);
        }
        return;
    }

    for (keys) |key| {
        if (exclusion) |excluded| {
            if (excluded.hasOwnProperty(key)) continue;
        }
        const maybe_desc = object_ops.objectRestOwnPropertyDescriptor(ctx, output, global, source, key) catch |err|
            return try handleLiteralRuntimeError(ctx, output, stack, caller_frame, catch_target, global, err);
        const desc = maybe_desc orelse continue;
        if (!(desc.enumerable orelse false)) continue;
        const value = object_ops.getValueProperty(ctx, output, global, rooted_source_value, key, vm.function, caller_frame) catch |err|
            return try handleLiteralRuntimeError(ctx, output, stack, caller_frame, catch_target, global, err);
        var rooted_value = value;
        var value_root_frame = core.runtime.rootValues(.{&rooted_value});
        value_root_frame.activate(rt);
        defer value_root_frame.deactivate(rt);
        property_ops.defineDataProperty(rt, target, key, rooted_value) catch |err|
            return try handleLiteralRuntimeError(ctx, output, stack, caller_frame, catch_target, global, err);
    }
}

fn handleLiteralRuntimeError(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    stack: *stack_mod.Stack,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    global: *core.Object,
    err: anytype,
) HostError!void {
    if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return;
    return err;
}

pub noinline fn specialObject(vm: *Vm) HostError!void {
    const stack = vm.stack;
    const frame = vm.frame;
    const subtype = vm.function.byteCode()[frame.pc];
    frame.pc += 1;
    if (subtype == 0 or subtype == 1) {
        const arguments = try object_ops.frameArgumentsObjectForSpecialObject(vm.ctx, vm.global, frame, subtype);
        try stack.pushOwned(arguments);
    } else if (subtype == 2) {
        try stack.push(frame.current_function);
    } else if (subtype == 3) {
        try stack.push(frame.newTargetValue());
    } else if (subtype == special_object_subtype.home_object) {
        if (property_ops.expectObject(frame.current_function)) |function_object| {
            if (function_object.functionHomeObject()) |home_object| {
                try stack.push(home_object.value());
                return;
            }
        } else |_| {}
        try stack.pushOwned(core.JSValue.undefinedValue());
    } else if (subtype == special_object_subtype.import_meta) {
        const import_meta = try object_ops.importMetaObject(vm.ctx, vm.function);
        try stack.pushOwned(import_meta);
    } else if (subtype == special_object_subtype.var_object) {
        const var_object = try core.Object.create(vm.ctx.runtime, core.class.ids.object, null);
        const value = var_object.value();
        try stack.pushOwned(value);
    } else {
        try stack.pushOwned(core.JSValue.undefinedValue());
    }
}

pub noinline fn getLength(vm: *Vm) HostError!void {
    const value = try vm.stack.pop();
    const length = object_ops.getValueProperty(vm.ctx, vm.output, vm.global, value, core.atom.ids.length, vm.function, vm.frame) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(vm.ctx, vm.output, vm.stack, vm.frame, vm.catch_target, vm.global, err)) return;
        return err;
    };
    try vm.stack.pushOwned(length);
}

pub noinline fn rest(vm: *Vm) HostError!void {
    const frame = vm.frame;
    const first_arg_idx = readInt(u16, vm.function.byteCode()[frame.pc..][0..2]);
    frame.pc += 2;
    // qjs OP_rest uses js_create_array → JS_NewArray (quickjs.c,
    // 5841-5844), whose shape proto is the realm Array.prototype. Rest arrays
    // must walk that real chain; the deleted class-name Get fallback is gone.
    const prototype = if (vm.ctx.global) |global| array_ops.arrayPrototypeFromGlobal(vm.ctx.runtime, global) else null;
    // Copy the borrowed actual-argument slice into one fresh dense array, as
    // qjs js_create_array does. Per-index descriptor definitions would turn
    // it sparse and disable the dense iterator path at the next spread.
    const end = @min(frame.actual_arg_count, frame.args.len);
    const start = @min(@as(usize, first_arg_idx), end);
    // Reserve before construction: no allocation may separate the helper's
    // rooted result from publication on the operand stack.
    try vm.stack.reserveAdditional(1);
    const array_value = try core.array.constructLiteralWithPrototype(vm.ctx.runtime, frame.args[start..end], prototype);
    vm.stack.pushOwnedAssumeCapacity(array_value);
}

fn stackValueFromTop(stack: *const stack_mod.Stack, offset: u8) !core.JSValue {
    const index_from_top: usize = offset;
    if (index_from_top >= stack.len()) return error.StackUnderflow;
    return stack.values[stack.len() - 1 - index_from_top];
}



// ----- merged from vm_native.zig -----
// NB2 §5.2: the one VM-side native call dispatcher for both call shapes
// (`op_call*`: window = [callee, args...]; `op_call_method`: window =
// [receiver, callee, args...]). Replaces the plain / method twin
// dispatchers of vm_call.zig. The terminal is
// `builtin_dispatch.callRecordFromVmInRealm` (preflight, backtrace marker,
// leaf arm without environment, managed arm with environment only when the
// entry declares `needs_env`).
// 
// Per D7 there is no interrupt tick here: qjs `js_call_c_function` does not
// poll either; JS loops poll at their back-edges and function entries.
pub const Shape = enum { plain, method };
pub const Outcome = enum { hit, caught, miss };
pub noinline fn dispatchNativeCall(
    vm: *Vm,
    func_obj: *core.Object,
    argc: u16,
    shape: Shape,
) align(32) core.errors.HostError!Outcome {
    const ctx = vm.ctx;
    const stack = vm.stack;
    const frame = vm.frame;
    const window_head: usize = if (shape == .method) 2 else 1;
    const total: usize = @as(usize, argc) + window_head;
    if (shape == .method and stack.len() < total) return error.StackUnderflow;
    const region_base = stack.len() - total;
    const target = resolvedNativeCallTargetAssumeCFunction(ctx, func_obj) orelse return .miss;
    const entry = target.entry;
    const args: []const core.JSValue = stack.values[region_base + window_head ..][0..argc];
    var result: core.JSValue = undefined;
    var handled = false;
    if (entry.kind == .leaf) {
        if (shape == .method) frame.pc += 2; // argc
        if (builtin_dispatch.invokeLeafFastEntry(entry, args)) |value| {
            result = value;
            handled = true;
        }
    } else {
        if (entry.flags.forwards_call) return .miss;
        if (shape == .method) frame.pc += 2; // argc
    }
    if (!handled) {
        const this_value = if (shape == .method) stack.values[region_base] else core.JSValue.undefinedValue();
        result = builtin_dispatch.nativeFromBits(builtin_dispatch.callRecordFromVmInRealm(
            ctx,
            vm.output,
            vm.global,
            func_obj,
            entry,
            target.realm,
            this_value,
            args,
            vm.function,
            frame,
        ));
        if (builtin_dispatch.nativeIsExc(ctx, result)) {
            return failure(ctx, vm.output, stack, frame, vm.catch_target, vm.global, region_base, builtin_dispatch.nativeHostError(ctx));
        }
    }
    stack.setLen(region_base);
    if (dropUnusedCallResult(ctx, vm.function, frame, result)) return .hit;
    stack.pushOwnedAssumeCapacity(result);
    return .hit;
}

/// K0 inline-arm eligibility (design §5.2): a managed entry without an
/// environment, with room on the native stack for the qjs `arg_buf`
/// reservation. Everything else takes `dispatch`.
pub inline fn managedInlineEligible(rt: *const core.JSRuntime, entry: *const core.NativeEntry) bool {
    if (entry.kind != .managed or entry.flags.needs_env or entry.flags.forwards_call) return false;
    return !rt.checkNativeStackOverflow(@as(usize, entry.arity) * @sizeOf(core.JSValue));
}

/// Same preflight for the W1 `.native_getter` arm: an untyped managed
/// getter without an environment is one `bl` from the field tail.
pub inline fn getterInlineEligible(rt: *const core.JSRuntime, entry: *const core.NativeEntry) bool {
    if (entry.kind != .getter or entry.sig != .none or entry.flags.needs_env) return false;
    return !rt.checkNativeStackOverflow(@as(usize, entry.arity) * @sizeOf(core.JSValue));
}

/// Same preflight for the K2 `method_managed` arm of the method handler.
pub inline fn methodManagedInlineEligible(rt: *const core.JSRuntime, entry: *const core.NativeEntry) bool {
    if (entry.kind != .method_managed) return false;
    return !rt.checkNativeStackOverflow(@as(usize, entry.arity) * @sizeOf(core.JSValue));
}

/// Cold leg: drop the call region and route the pending error to the
/// frame's handler (`.caught`) or the caller.
pub noinline fn failure(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    stack: *stack_mod.Stack,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    global: *core.Object,
    region_base: usize,
    err: core.errors.HostError,
) core.errors.HostError!Outcome {
    call_runtime.popOwnedStackRegion(stack, region_base);
    const caught = call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err) catch |handler_err|
        return @errorCast(handler_err);
    if (caught) return .caught;
    return err;
}


// ----- merged from vm_regexp.zig -----
// VM adapter for compiled RegExp literal creation.
// 
// The operand stack transfers owned pattern/bytecode constants into this
// helper; locals release them after construction, and `pushOwned` transfers
// the fresh RegExp result back to the stack. The active global selects the
// realm's fixed RegExp shape without consulting the mutable constructor
// binding, matching QuickJS `OP_regexp` at quickjs.c.
fn constructCompiledLiteralInRealm(
    rt: *core.JSRuntime,
    global: *core.Object,
    source: core.JSValue,
    compiled_value: core.JSValue,
) !core.JSValue {
    if (!compiled_value.isString()) return error.TypeError;
    const compiled_string = compiled_value.asStringBodyRaw() orelse return error.TypeError;
    if (compiled_string.isWide() or compiled_string.len() == 0) return error.TypeError;
    const realm = rt.contextForGlobal(global) orelse return error.TypeError;
    const initial_shape = realm.regexp_shape orelse return error.TypeError;

    var source_val = source;
    var compiled_root = compiled_value;
    var root_frame = core.runtime.rootValues(.{ &source_val, &compiled_root });
    root_frame.activate(rt);
    defer root_frame.deactivate(rt);

    const object = try core.Object.createRegExpFromShape(rt, initial_shape);
    errdefer core.Object.destroyFromHeader(rt, object.gcHeader());
    try object.setRegexpSource(rt, source_val);
    try object.setRegexpCompiledBytecodeString(rt, compiled_string);
    return object.value();
}

pub noinline fn pushLiteral(vm: *Vm) HostError!void {
    const compiled = try vm.stack.pop();
    const pattern = try vm.stack.pop();

    const value = try constructCompiledLiteralInRealm(vm.rt, vm.global, pattern, compiled);
    try vm.stack.pushOwned(value);
}


// ----- merged from vm_value.zig -----
// Value, constant, stack-shuffle, `typeof`, and return opcode adapters.
// 
// Operand-stack slots are owned; borrowed frame bindings and constant-pool
// values are duplicated before they are pushed, while explicit pop/drop paths
// release their slots. Private symbols and completion values transfer only at
// their named handoff points. These cold adapters mirror the standalone
// QuickJS opcode cases beginning at quickjs.c; fused hot dispatch
// remains outside this module.
pub const DropResult = union(enum) {
    value,
    catch_target: ?usize,
};
pub fn pushInt32Operand(vm: *Vm) HostError!void {
    const value = readInt(i32, vm.function.byteCode()[vm.frame.pc..][0..4]);
    vm.frame.pc += 4;
    vm.stack.pushOwnedAssumeCapacity(core.JSValue.int32(value));
}

pub fn pushBigIntI32Operand(vm: *Vm) HostError!void {
    const value = readInt(i32, vm.function.byteCode()[vm.frame.pc..][0..4]);
    vm.frame.pc += 4;
    vm.stack.pushOwnedAssumeCapacity(core.JSValue.shortBigInt(value));
}

pub fn pushI16Operand(vm: *Vm) HostError!void {
    const value = readInt(i16, vm.function.byteCode()[vm.frame.pc..][0..2]);
    vm.frame.pc += 2;
    vm.stack.pushOwnedAssumeCapacity(core.JSValue.int32(value));
}

pub fn pushI8Operand(vm: *Vm) HostError!void {
    const value: i8 = @bitCast(vm.function.byteCode()[vm.frame.pc]);
    vm.frame.pc += 1;
    vm.stack.pushOwnedAssumeCapacity(core.JSValue.int32(value));
}

/// Plain immediate-integer push, no fusion of any kind.
///
/// qjs has no runtime push+binop fusion: every push opcode is a standalone
/// `*sp++ = ...` and a following binop is a separate dispatch (quickjs.c
/// The threaded fast path (zjs_vm.zig push_i32/i16/i8) already
/// pushes the immediate inline; this is the non-threaded fallback, kept
/// byte-identical to it — a plain push, no stack-lhs fold.
/// `push_minus1` .. `push_7`: the opcode number encodes the value.
pub fn pushSmallInt(vm: *Vm, opc: u8) HostError!void {
    const value: i32 = @as(i32, opc) - @as(i32, op.push_0);
    vm.stack.pushOwnedAssumeCapacity(core.JSValue.int32(value));
}

pub fn pushUndefined(vm: *Vm) HostError!void {
    vm.stack.pushOwnedAssumeCapacity(core.JSValue.undefinedValue());
}

pub fn pushNull(vm: *Vm) HostError!void {
    vm.stack.pushOwnedAssumeCapacity(core.JSValue.nullValue());
}

/// `push_false` / `push_true`.
pub fn pushBoolean(vm: *Vm, opc: u8) HostError!void {
    vm.stack.pushOwnedAssumeCapacity(core.JSValue.boolean(opc == op.push_true));
}

pub noinline fn pushConst(vm: *Vm) HostError!void {
    const index = readInt(u32, vm.function.byteCode()[vm.frame.pc..][0..4]);
    vm.frame.pc += 4;
    const value = vm.function.constantAt(index) orelse return error.TypeError;
    vm.stack.pushAssumeCapacity(value);
}

pub noinline fn pushConst8(vm: *Vm) HostError!void {
    const index = vm.function.byteCode()[vm.frame.pc];
    vm.frame.pc += 1;
    const value = vm.function.constantAt(index) orelse return error.TypeError;
    vm.stack.pushAssumeCapacity(value);
}

pub fn pushAtomValue(vm: *Vm) HostError!void {
    const atom_id = core.Atom.fromRaw(readInt(u32, vm.function.byteCode()[vm.frame.pc..][0..4]));
    vm.frame.pc += 4;
    const value = try vm.rt.atoms.toStringValue(vm.rt, atom_id);
    vm.stack.pushOwnedAssumeCapacity(value);
}

pub noinline fn pushPrivateSymbol(ctx: *core.JSContext, stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame) !void {
    const template_atom = core.Atom.fromRaw(readInt(u32, function.byteCode()[frame.pc..][0..4]));
    frame.pc += 4;
    const name = ctx.runtime.atoms.name(template_atom) orelse return error.InvalidAtom;
    const empty_before = stack.capacity == 0;
    try stack.reserveAdditional(1);
    errdefer if (empty_before) stack.discardEmptyHeapBacking();
    const value = value: {
        const fresh_atom = try ctx.runtime.atoms.newSymbol(name, .private);
        errdefer ctx.runtime.atoms.abandonUnpublishedSymbol(fresh_atom);
        break :value try ctx.runtime.takeSymbolValue(fresh_atom);
    };
    stack.pushOwnedAssumeCapacity(value);
}

pub noinline fn pushEmptyString(vm: *Vm) HostError!void {
    const value = (try vm.rt.emptyString()).value();
    vm.stack.pushOwnedAssumeCapacity(value);
}

pub fn pushThis(stack: *stack_mod.Stack, this_value: core.JSValue) !void {
    const value = adapterValueBorrow(this_value);
    if (value.is(.uninitialized)) return error.ReferenceError;
    stack.pushAssumeCapacity(value);
}

pub noinline fn pushThisVm(vm: *Vm) HostError!void {
    const this_value = object_ops.materializeFrameThisBinding(vm.ctx, vm.global, vm.frame) catch |err| switch (err) {
        error.TypeError => {
            if (try call_runtime.handleCatchableRuntimeError(vm.ctx, vm.output, vm.stack, vm.frame, vm.catch_target, vm.global, error.TypeError)) return;
            return error.TypeError;
        },
        else => return err,
    };
    pushThis(vm.stack, this_value) catch |err| switch (err) {
        error.ReferenceError => {
            if (try call_runtime.handleCatchableRuntimeError(vm.ctx, vm.output, vm.stack, vm.frame, vm.catch_target, vm.global, error.ReferenceError)) return;
            return error.ReferenceError;
        },
    };
}

pub fn toObject(ctx: *core.JSContext, global: *core.Object, stack: *stack_mod.Stack) !void {
    const value = try stack.pop();
    const object_value = if (value.is(.object))
        value
    else
        try object_ops.primitiveObjectForAccess(ctx.runtime, global, value);
    stack.pushOwnedAssumeCapacity(object_value);
}

pub noinline fn toObjectVm(vm: *Vm) HostError!void {
    toObject(vm.ctx, vm.global, vm.stack) catch |err| switch (err) {
        error.TypeError => {
            if (try call_runtime.handleCatchableRuntimeError(vm.ctx, vm.output, vm.stack, vm.frame, vm.catch_target, vm.global, error.TypeError)) return;
            return error.TypeError;
        },
        else => return err,
    };
}

pub noinline fn typeOf(vm: *Vm) HostError!void {
    const value = try vm.stack.pop();
    // qjs `js_operator_typeof` returns a predefined atom and OP_typeof pushes
    // `JS_AtomToString` of it — a refcount dup of the interned atom string, not
    // a fresh allocation. The `typeof` result strings are all predefined string
    // atoms here too, so resolve to the atom and dup its cached interned string.
    const atom_id: core.Atom = if (value.is(.undefined_value) or value_ops.isHTMLDDA(value))
        core.atom.ids.undefined_
    else if (value.is(.null_value))
        core.atom.ids.type_object
    else if (value.is(.boolean))
        core.atom.ids.type_boolean
    else if (value.isBigInt())
        core.atom.ids.type_bigint
    else if (value.isNumber())
        core.atom.ids.type_number
    else if (value.isString())
        core.atom.ids.type_string
    else if (value.is(.symbol))
        core.atom.ids.type_symbol
    else if (value.is(.function_bytecode) or functionObjectFromValue(value) != null or callableObjectFromValue(value) != null or proxyTargetIsCallable(value))
        core.atom.ids.type_function
    else
        core.atom.ids.type_object;
    const out = try vm.rt.atoms.toStringValue(vm.rt, atom_id);
    vm.stack.pushOwnedAssumeCapacity(out);
}

pub noinline fn typeOfIsUndefined(_: *core.JSRuntime, stack: *stack_mod.Stack) !void {
    const value = try stack.pop();
    stack.pushOwnedAssumeCapacity(core.JSValue.boolean(value.is(.undefined_value) or value_ops.isHTMLDDA(value)));
}

pub noinline fn typeOfIsFunction(_: *core.JSRuntime, stack: *stack_mod.Stack) !void {
    const value = try stack.pop();
    // Keep the short comparison opcode exactly aligned with `typeOf`: native
    // c_functions, external host functions, and callable proxies all report
    // "function", not only bytecode function objects.
    const is_func = !value_ops.isHTMLDDA(value) and
        (value.is(.function_bytecode) or
            functionObjectFromValue(value) != null or
            callableObjectFromValue(value) != null or
            proxyTargetIsCallable(value));
    stack.pushOwnedAssumeCapacity(core.JSValue.boolean(is_func));
}

pub noinline fn logicalNot(vm: *Vm) HostError!void {
    const value = try vm.stack.pop();
    vm.stack.pushOwnedAssumeCapacity(core.JSValue.boolean(!value_ops.isTruthy(value)));
}

pub noinline fn drop(_: *core.JSRuntime, stack: *stack_mod.Stack) !DropResult {
    const value = try stack.pop();
    if (forof_ops.isIteratorCatchMarker(value)) {
        return .value;
    }
    if (value.is(.catch_offset)) {
        if ((value.as(.catch_offset) orelse -1) == 0) {
            return .value;
        }
        const target = value.catchTarget();
        return .{ .catch_target = target };
    }
    return .value;
}

/// Pop the return value, unwind to the nearest catch offset, push the value
/// back, and re-arm `vm.catch_target` when the offset was a real handler
/// (not an iterator marker or a zero offset).
pub noinline fn nipCatch(vm: *Vm) HostError!void {
    const stack = vm.stack;
    const ret_value = try stack.pop();

    while (stack.len() != 0) {
        const value = try stack.pop();
        if (value.is(.catch_offset)) {
            const is_marker = forof_ops.isIteratorCatchMarker(value) or
                (value.as(.catch_offset) orelse -1) == 0;
            try stack.pushOwned(ret_value);
            if (!is_marker) vm.catch_target.* = value.catchTarget();
            return;
        }
    }

    return error.InvalidBytecode;
}

pub fn dup(vm: *Vm) HostError!void {
    const value = vm.stack.peekBorrowed() orelse return error.StackUnderflow;
    vm.stack.pushAssumeCapacity(value);
}

pub fn swap(vm: *Vm) HostError!void {
    const stack = vm.stack;
    try requireStackLen(stack, 2);
    const a = try stack.pop();
    const b = try stack.pop();
    stack.pushOwnedAssumeCapacity(a);
    stack.pushOwnedAssumeCapacity(b);
}

pub fn nip(vm: *Vm) HostError!void {
    const stack = vm.stack;
    try requireStackLen(stack, 2);
    const top = try stack.pop();
    _ = try stack.pop();
    stack.pushOwnedAssumeCapacity(top);
}

pub fn dup2(ctx: *core.JSContext, stack: *stack_mod.Stack) !void {
    _ = ctx;
    try requireStackLen(stack, 2);
    const b = try stack.pop();
    const a = try stack.pop();
    stack.pushAssumeCapacity(a);
    stack.pushAssumeCapacity(b);
    stack.pushOwnedAssumeCapacity(a);
    stack.pushOwnedAssumeCapacity(b);
}

pub fn dup1(ctx: *core.JSContext, stack: *stack_mod.Stack) !void {
    _ = ctx;
    try requireStackLen(stack, 2);
    const b = try stack.pop();
    const a = try stack.pop();
    stack.pushAssumeCapacity(a);
    stack.pushOwnedAssumeCapacity(a);
    stack.pushOwnedAssumeCapacity(b);
}

pub fn dup3(ctx: *core.JSContext, stack: *stack_mod.Stack) !void {
    _ = ctx;
    try requireStackLen(stack, 3);
    const c = try stack.pop();
    const b = try stack.pop();
    const a = try stack.pop();
    stack.pushAssumeCapacity(a);
    stack.pushAssumeCapacity(b);
    stack.pushAssumeCapacity(c);
    stack.pushOwnedAssumeCapacity(a);
    stack.pushOwnedAssumeCapacity(b);
    stack.pushOwnedAssumeCapacity(c);
}

pub fn insert2(vm: *Vm) HostError!void {
    const stack = vm.stack;
    try requireStackLen(stack, 2);
    const b = try stack.pop();
    const a = try stack.pop();
    stack.pushAssumeCapacity(b);
    stack.pushOwnedAssumeCapacity(a);
    stack.pushOwnedAssumeCapacity(b);
}

pub fn insert3(vm: *Vm) HostError!void {
    const stack = vm.stack;
    try requireStackLen(stack, 3);
    const c = try stack.pop();
    const b = try stack.pop();
    const a = try stack.pop();
    stack.pushAssumeCapacity(c);
    stack.pushOwnedAssumeCapacity(a);
    stack.pushOwnedAssumeCapacity(b);
    stack.pushOwnedAssumeCapacity(c);
}

pub fn insert4(ctx: *core.JSContext, stack: *stack_mod.Stack) !void {
    _ = ctx;
    try requireStackLen(stack, 4);
    const d = try stack.pop();
    const c = try stack.pop();
    const b = try stack.pop();
    const a = try stack.pop();
    stack.pushAssumeCapacity(d);
    stack.pushOwnedAssumeCapacity(a);
    stack.pushOwnedAssumeCapacity(b);
    stack.pushOwnedAssumeCapacity(c);
    stack.pushOwnedAssumeCapacity(d);
}

pub fn rot3l(vm: *Vm) HostError!void {
    const stack = vm.stack;
    try requireStackLen(stack, 3);
    const c = try stack.pop();
    const b = try stack.pop();
    const a = try stack.pop();
    stack.pushOwnedAssumeCapacity(b);
    stack.pushOwnedAssumeCapacity(c);
    stack.pushOwnedAssumeCapacity(a);
}

pub fn rot3r(ctx: *core.JSContext, stack: *stack_mod.Stack) !void {
    _ = ctx;
    try requireStackLen(stack, 3);
    const c = try stack.pop();
    const b = try stack.pop();
    const a = try stack.pop();
    stack.pushOwnedAssumeCapacity(c);
    stack.pushOwnedAssumeCapacity(a);
    stack.pushOwnedAssumeCapacity(b);
}

pub fn rot4l(ctx: *core.JSContext, stack: *stack_mod.Stack) !void {
    _ = ctx;
    try requireStackLen(stack, 4);
    const d = try stack.pop();
    const c = try stack.pop();
    const b = try stack.pop();
    const a = try stack.pop();
    stack.pushOwnedAssumeCapacity(b);
    stack.pushOwnedAssumeCapacity(c);
    stack.pushOwnedAssumeCapacity(d);
    stack.pushOwnedAssumeCapacity(a);
}

pub fn rot5l(ctx: *core.JSContext, stack: *stack_mod.Stack) !void {
    _ = ctx;
    try requireStackLen(stack, 5);
    const e = try stack.pop();
    const d = try stack.pop();
    const c = try stack.pop();
    const b = try stack.pop();
    const a = try stack.pop();
    stack.pushOwnedAssumeCapacity(b);
    stack.pushOwnedAssumeCapacity(c);
    stack.pushOwnedAssumeCapacity(d);
    stack.pushOwnedAssumeCapacity(e);
    stack.pushOwnedAssumeCapacity(a);
}

pub fn perm3(vm: *Vm) HostError!void {
    const stack = vm.stack;
    try requireStackLen(stack, 3);
    const c = try stack.pop();
    const b = try stack.pop();
    const a = try stack.pop();
    stack.pushOwnedAssumeCapacity(b);
    stack.pushOwnedAssumeCapacity(a);
    stack.pushOwnedAssumeCapacity(c);
}

pub fn perm4(vm: *Vm) HostError!void {
    const stack = vm.stack;
    try requireStackLen(stack, 4);
    const d = try stack.pop();
    const c = try stack.pop();
    const b = try stack.pop();
    const a = try stack.pop();
    stack.pushOwnedAssumeCapacity(c);
    stack.pushOwnedAssumeCapacity(a);
    stack.pushOwnedAssumeCapacity(b);
    stack.pushOwnedAssumeCapacity(d);
}

pub fn perm5(ctx: *core.JSContext, stack: *stack_mod.Stack) !void {
    _ = ctx;
    try requireStackLen(stack, 5);
    const e = try stack.pop();
    const d = try stack.pop();
    const c = try stack.pop();
    const b = try stack.pop();
    const a = try stack.pop();
    stack.pushOwnedAssumeCapacity(d);
    stack.pushOwnedAssumeCapacity(a);
    stack.pushOwnedAssumeCapacity(b);
    stack.pushOwnedAssumeCapacity(c);
    stack.pushOwnedAssumeCapacity(e);
}

pub fn swap2(ctx: *core.JSContext, stack: *stack_mod.Stack) !void {
    _ = ctx;
    try requireStackLen(stack, 4);
    const d = try stack.pop();
    const c = try stack.pop();
    const b = try stack.pop();
    const a = try stack.pop();
    stack.pushOwnedAssumeCapacity(c);
    stack.pushOwnedAssumeCapacity(d);
    stack.pushOwnedAssumeCapacity(a);
    stack.pushOwnedAssumeCapacity(b);
}

pub noinline fn isUndefinedOrNull(vm: *Vm) HostError!void {
    const value = try vm.stack.pop();
    vm.stack.pushOwnedAssumeCapacity(core.JSValue.boolean(value.is(.undefined_value) or value.is(.null_value)));
}

pub noinline fn isUndefined(_: *core.JSRuntime, stack: *stack_mod.Stack) !void {
    const value = try stack.pop();
    stack.pushOwnedAssumeCapacity(core.JSValue.boolean(value.is(.undefined_value)));
}

pub noinline fn isNull(vm: *Vm) HostError!void {
    const value = try vm.stack.pop();
    vm.stack.pushOwnedAssumeCapacity(core.JSValue.boolean(value.is(.null_value)));
}

fn requireStackLen(stack: *const stack_mod.Stack, required: usize) !void {
    if (stack.len() < required) return error.StackUnderflow;
}

fn expectStackInt32s(stack: *const stack_mod.Stack, expected: []const i32) !void {
    try std.testing.expectEqual(expected.len, stack.len());
    for (expected, 0..) |value, index| {
        try std.testing.expectEqual(@as(?i32, value), stack.values[index].as(.int));
    }
}

fn functionObjectFromValue(value: core.JSValue) ?*core.Object {
    if (!value.is(.object)) return null;
    const header = value.refHeader() orelse return null;
    const object = core.Object.fromHeader(header);
    if (!core.class.isBytecodeFunctionClass(object.class_id)) return null;
    return object;
}

fn callableObjectFromValue(value: core.JSValue) ?*core.Object {
    if (!value.is(.object)) return null;
    const header = value.refHeader() orelse return null;
    const object = core.Object.fromHeader(header);
    if (object.class_id != core.class.ids.c_function and
        object.class_id != core.class.ids.c_function_data and
        !core.class.isAsyncFunctionResumeClass(object.class_id) and
        object.class_id != core.class.ids.bound_function) return null;
    return object;
}

fn proxyTargetIsCallable(value: core.JSValue) bool {
    const object = objectFromValue(value) orelse return false;
    const target = object.proxyTarget() orelse return false;
    return target.is(.function_bytecode) or functionObjectFromValue(target) != null or callableObjectFromValue(target) != null or proxyTargetIsCallable(target);
}

fn countLivePrivateAtomsNamed(rt: *core.JSRuntime, expected_name: []const u8) usize {
    var count: usize = 0;
    for (0..rt.atoms.entries.len) |index| {
        const atom_id: core.Atom = core.Atom.fromRaw(@intCast(core.atom.first_dynamic_atom + index));
        if (rt.atoms.kind(atom_id) != .private) continue;
        const name = rt.atoms.name(atom_id) orelse continue;
        if (std.mem.eql(u8, name, expected_name)) count += 1;
    }
    return count;
}

test "function object lookup recognizes every bytecode function class" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const class_ids = [_]core.ClassId{
        core.class.ids.bytecode_function,
        core.class.ids.generator_function,
        core.class.ids.async_function,
        core.class.ids.async_generator_function,
    };
    for (class_ids) |class_id| {
        const function_object = try core.Object.create(rt, class_id, null);
        try std.testing.expectEqual(function_object, functionObjectFromValue(function_object.value()).?);
    }

    const plain_object = try core.Object.create(rt, core.class.ids.object, null);
    try std.testing.expect(functionObjectFromValue(plain_object.value()) == null);
}

test "push private symbol creates a fresh runtime atom per execution" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();

    const function_name = try rt.internAtom("pushPrivateSymbolNoRetain");
    const template_name = "pushPrivateSymbolNoRetainName";
    var template_atom = try rt.atoms.newSymbol(template_name, .private);
    var template_atom_released = false;
    // TGC S3-c: the template id lives on a non-GC `Bytecode` operand array, so
    // it needs a declared root to survive a major.
    var template_roots = core.runtime.rootAtoms(.{&template_atom});
    template_roots.activate(rt);
    defer if (!template_atom_released) template_roots.deactivate(rt);

    var code: [4]u8 = undefined;
    std.mem.writeInt(u32, &code, template_atom.raw(), .little);
    const execution_function = try bytecode.FunctionBytecode.createFixture(rt, .{ .name = function_name, .byte_code = &code });
    defer execution_function.destroyUnpublishedFixture(rt);
    var frame = frame_mod.Frame.init(execution_function);
    var stack = stack_mod.Stack.init(&rt.memory, 8);
    defer stack.deinit(rt);

    try pushPrivateSymbol(ctx, &stack, execution_function, &frame);
    frame.pc = 0;
    try pushPrivateSymbol(ctx, &stack, execution_function, &frame);

    var first_atom: core.Atom = undefined;
    var second_atom: core.Atom = undefined;
    {
        const second_value = try stack.pop();
        const first_value = try stack.pop();
        first_atom = first_value.asSymbolAtom().?;
        second_atom = second_value.asSymbolAtom().?;

        try std.testing.expect(first_atom != template_atom);
        try std.testing.expect(second_atom != template_atom);
        try std.testing.expect(first_atom != second_atom);
        try std.testing.expectEqualStrings(template_name, rt.atoms.name(first_atom).?);
        try std.testing.expectEqualStrings(template_name, rt.atoms.name(second_atom).?);
        try std.testing.expectEqual(@as(usize, 3), countLivePrivateAtomsNamed(rt, template_name));
    }

    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(first_atom) == null);
    try std.testing.expect(rt.atoms.name(second_atom) == null);
    try std.testing.expectEqual(@as(usize, 1), countLivePrivateAtomsNamed(rt, template_name));
    template_roots.deactivate(rt);
    template_atom_released = true;
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(template_atom) == null);
}

test "stack rearrange opcodes validate depth before mutating stack" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();
    var stack = stack_mod.Stack.init(&rt.memory, 8);
    defer stack.deinit(rt);

    try stack.pushOwned(core.JSValue.int32(1));
    try stack.pushOwned(core.JSValue.int32(2));
    try std.testing.expectError(error.StackUnderflow, dup3(ctx, &stack));
    try expectStackInt32s(&stack, &.{ 1, 2 });

    try stack.pushOwned(core.JSValue.int32(3));
    try std.testing.expectError(error.StackUnderflow, insert4(ctx, &stack));
    try expectStackInt32s(&stack, &.{ 1, 2, 3 });

    try std.testing.expectError(error.StackUnderflow, swap2(ctx, &stack));
    try expectStackInt32s(&stack, &.{ 1, 2, 3 });
}

test "push private symbol stack failure does not retain transient private atom" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();

    const function_name = try rt.internAtom("pushPrivateSymbolStackFailure");
    const template_name = "pushPrivateSymbolStackFailureName";
    var template_atom = try rt.atoms.newSymbol(template_name, .private);
    var template_atom_released = false;
    // TGC S3-c: the template id lives on a non-GC `Bytecode` operand array, so
    // it needs a declared root to survive a major.
    var template_roots = core.runtime.rootAtoms(.{&template_atom});
    template_roots.activate(rt);
    defer if (!template_atom_released) template_roots.deactivate(rt);

    var code: [4]u8 = undefined;
    std.mem.writeInt(u32, &code, template_atom.raw(), .little);
    const execution_function = try bytecode.FunctionBytecode.createFixture(rt, .{ .name = function_name, .byte_code = &code });
    defer execution_function.destroyUnpublishedFixture(rt);
    var frame = frame_mod.Frame.init(execution_function);
    var stack = stack_mod.Stack.init(&rt.memory, 0);
    defer stack.deinit(rt);

    // TGC S3-c: `free` no longer retires an entry -- a major does. The
    // calibration atom exists to warm one recyclable slot, so it has to be
    // collected before the measurement.
    _ = try rt.atoms.newSymbol(template_name, .private);
    _ = rt.runObjectCycleRemoval();
    const allocated_before = rt.memory.allocated_bytes;
    try std.testing.expectError(error.StackOverflow, pushPrivateSymbol(ctx, &stack, execution_function, &frame));
    try std.testing.expectEqual(allocated_before, rt.memory.allocated_bytes);
    try std.testing.expectEqual(@as(usize, 1), countLivePrivateAtomsNamed(rt, template_name));

    template_roots.deactivate(rt);
    template_atom_released = true;
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(template_atom) == null);
}

test "push private symbol releases fresh atom on allocation failure" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();

    const function_name = try rt.internAtom("pushPrivateSymbolAllocationFailure");
    const template_name = "pushPrivateSymbolAllocationFailureName";
    var template_atom = try rt.atoms.newSymbol(template_name, .private);
    // TGC S3-c: the template id lives on a non-GC `Bytecode` operand array.
    var template_roots = core.runtime.rootAtoms(.{&template_atom});
    template_roots.activate(rt);
    defer template_roots.deactivate(rt);

    var code: [4]u8 = undefined;
    std.mem.writeInt(u32, &code, template_atom.raw(), .little);
    const execution_function = try bytecode.FunctionBytecode.createFixture(rt, .{ .name = function_name, .byte_code = &code });
    defer execution_function.destroyUnpublishedFixture(rt);
    var frame = frame_mod.Frame.init(execution_function);
    var stack = stack_mod.Stack.init(&rt.memory, 1);
    defer stack.deinit(rt);
    defer rt.setMemoryLimit(null);

    // Warm one recyclable atom-table slot and measure the exact transient
    // description allocation. The following limit then admits newSymbol but
    // rejects the first symbol-body allocation in takeSymbolValue.
    _ = try rt.atoms.newSymbol(template_name, .private);
    const allocated_with_atom = rt.memory.allocated_bytes;
    // TGC S3-c: `free` no longer retires an entry -- a major does.
    _ = rt.runObjectCycleRemoval();
    const allocated_before = rt.memory.allocated_bytes;
    try std.testing.expect(allocated_with_atom > allocated_before);
    const atom_allocation_bytes = allocated_with_atom - allocated_before;
    try std.testing.expectEqual(@as(usize, 1), countLivePrivateAtomsNamed(rt, template_name));

    rt.setMemoryLimit(allocated_before);
    try std.testing.expectError(error.OutOfMemory, pushPrivateSymbol(ctx, &stack, execution_function, &frame));
    rt.setMemoryLimit(null);
    try std.testing.expectEqual(allocated_before, rt.memory.allocated_bytes);
    try std.testing.expectEqual(@as(usize, 1), countLivePrivateAtomsNamed(rt, template_name));

    frame.pc = 0;
    rt.setMemoryLimit(allocated_before + atom_allocation_bytes);
    try std.testing.expectError(error.OutOfMemory, pushPrivateSymbol(ctx, &stack, execution_function, &frame));
    rt.setMemoryLimit(null);
    try std.testing.expectEqual(allocated_before, rt.memory.allocated_bytes);
    try std.testing.expectEqual(@as(usize, 1), countLivePrivateAtomsNamed(rt, template_name));

    frame.pc = 0;
    try pushPrivateSymbol(ctx, &stack, execution_function, &frame);
    const recovered = try stack.pop();
    const recovered_atom = recovered.asSymbolAtom().?;
    try std.testing.expect(recovered_atom != template_atom);
    try std.testing.expectEqualStrings(template_name, rt.atoms.name(recovered_atom).?);
}


// ----- merged from using_ops.zig -----
// Bytecode handlers for explicit-resource-management (`using`) operations.
//
// These handlers own and pop VM operands, delegate resource lifetime to
// `disposable_ops`, and route synchronous/async disposal failures through the
// active catch target. Promise scheduling remains in `promise_ops`.
const disposable_ops = @import("disposable_ops.zig");
const vm_property_field = @import("vm_property.zig");
pub const DisposalDisposition = enum {
    normal,
    throw,
};

fn popOwnedOperands(_: *core.JSRuntime, stack: *stack_mod.Stack, count: usize) !void {
    var remaining = count;
    while (remaining != 0) : (remaining -= 1) {
        _ = try stack.pop();
    }
}

fn routeRuntimeError(vm: *Vm, err: anytype) HostError!void {
    if (try call_runtime.handleCatchableRuntimeError(vm.ctx, vm.output, vm.stack, vm.frame, vm.catch_target, vm.global, err)) {
        return;
    }
    return err;
}

pub noinline fn createStackVm(vm: *Vm) HostError!void {
    const stack = vm.stack;
    try stack.reserveAdditional(1);
    const value = promise_ops.usingCreateAsyncDisposableStack(vm.ctx, vm.global) catch |err| {
        return routeRuntimeError(vm, err);
    };
    stack.pushOwnedAssumeCapacity(value);
}

pub noinline fn execVm(vm: *Vm) HostError!void {
    const ctx = vm.ctx;
    const output = vm.output;
    const global = vm.global;
    const stack = vm.stack;
    const function = vm.function;
    const frame = vm.frame;
    const catch_target = vm.catch_target;
    const code = function.byteCode();
    if (frame.pc >= code.len) return error.InvalidBytecode;
    const sub = code[frame.pc];
    frame.pc += 1;
    if (bytecode.opcode.ext0_sub.isAdd(sub)) {
        try addResourceWithHint(vm, bytecode.opcode.ext0_sub.addHint(sub));
        return;
    }
    switch (sub) {
        bytecode.opcode.ext0_sub.create => try createStackVm(vm),
        bytecode.opcode.ext0_sub.dispose => try disposeStackVm(vm, .normal),
        bytecode.opcode.ext0_sub.dispose_throw => try disposeStackVm(vm, .throw),
        // Cold-plane reclamation (opcode-space survey §7): zero executions
        // in the benchmark suite, so the second-level branch is free.
        bytecode.opcode.ext0_sub.put_super_value => {
            try object_ops.putSuperValue(vm);
        },
        bytecode.opcode.ext0_sub.to_object => {
            try toObjectVm(vm);
        },
        // C0 late-encoding resident: the canonical final encoding of
        // to_propkey. Identical semantics to the direct id 112, which
        // stays executable for the D11 alias window only.
        bytecode.opcode.ext0_sub.to_propkey => {
            _ = try vm_property_field.toPropKeyVm(ctx, output, global, stack, function, frame, catch_target);
        },
        // C1-1 resident: identical semantics to the direct id 75, which
        // stays executable for its D11 window only. The opcode constant is
        // passed literally -- the shared setName helper selects its
        // computed arm from it, never from the stream byte.
        bytecode.opcode.ext0_sub.set_name_computed => {
            try vm_property_field.setName(ctx, output, global, stack, function, frame, bytecode.opcode.op.set_name_computed);
        },
        bytecode.opcode.ext0_sub.set_proto => {
            try setProto(ctx, stack);
        },
        bytecode.opcode.ext0_sub.check_ctor_return => {
            try checkCtorReturnVm(vm);
        },
        bytecode.opcode.ext0_sub.is_undefined => {
            try isUndefined(ctx.runtime, stack);
        },
        bytecode.opcode.ext0_sub.typeof_is_undefined => {
            try typeOfIsUndefined(ctx.runtime, stack);
        },
        bytecode.opcode.ext0_sub.typeof_is_function => {
            try typeOfIsFunction(ctx.runtime, stack);
        },
        bytecode.opcode.ext0_sub.insert4 => {
            try insert4(ctx, stack);
        },
        bytecode.opcode.ext0_sub.rot5l => {
            try rot5l(ctx, stack);
        },
        bytecode.opcode.ext0_sub.perm5 => {
            try perm5(ctx, stack);
        },
        bytecode.opcode.ext0_sub.dup2 => {
            try dup2(ctx, stack);
        },
        bytecode.opcode.ext0_sub.swap2 => {
            try swap2(ctx, stack);
        },
        bytecode.opcode.ext0_sub.rot3r => {
            try rot3r(ctx, stack);
        },
        bytecode.opcode.ext0_sub.rot4l => {
            try rot4l(ctx, stack);
        },
        bytecode.opcode.ext0_sub.dup3 => {
            try dup3(ctx, stack);
        },
        bytecode.opcode.ext0_sub.dup1 => {
            try dup1(ctx, stack);
        },
        else => return error.InvalidBytecode,
    }
}

fn addResourceWithHint(vm: *Vm, hint_byte: u8) HostError!void {
    const ctx = vm.ctx;
    const stack = vm.stack;
    const hint: core.object.DisposalHint = switch (hint_byte) {
        @intFromEnum(core.object.DisposalHint.sync) => .sync,
        @intFromEnum(core.object.DisposalHint.async) => .async,
        else => return error.InvalidBytecode,
    };
    const stack_len = stack.len();
    if (stack_len < 2) return error.StackUnderflow;
    const args = stack.values[stack_len - 2 .. stack_len];

    _ = switch (hint) {
        .sync => disposable_ops.usingAddSyncResource(ctx, vm.output, vm.global, args),
        .async => promise_ops.usingAddAsyncResource(ctx, vm.output, vm.global, args),
    } catch |err| {
        try popOwnedOperands(vm.rt, stack, 2);
        return routeRuntimeError(vm, err);
    };
    try popOwnedOperands(vm.rt, stack, 2);
}

fn disposeStack(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack_value: core.JSValue,
    completion: ?core.JSValue,
) !core.JSValue {
    const disposable_stack = try disposable_ops.parserDisposableStackReceiver(stack_value);
    if (!disposable_stack.disposableStackHasAsyncHint()) {
        if (completion) |thrown| {
            const args = [_]core.JSValue{ stack_value, thrown };
            return disposable_ops.usingDisposeSyncStackForThrow(ctx, output, global, &args);
        }
        const args = [_]core.JSValue{stack_value};
        return disposable_ops.usingDisposeSyncStack(ctx, output, global, &args);
    }

    if (completion) |thrown| {
        const args = [_]core.JSValue{ stack_value, thrown };
        return promise_ops.usingDisposeAsyncStackForThrow(ctx, output, global, &args);
    }
    const args = [_]core.JSValue{stack_value};
    return promise_ops.usingDisposeAsyncStack(ctx, output, global, &args);
}

pub noinline fn disposeStackVm(vm: *Vm, disposition: DisposalDisposition) HostError!void {
    const stack = vm.stack;
    const operand_count: usize = switch (disposition) {
        .normal => 1,
        .throw => 2,
    };
    const stack_len = stack.len();
    if (stack_len < operand_count) return error.StackUnderflow;
    const operand_base = stack_len - operand_count;
    const stack_value = stack.values[operand_base];
    const completion = if (disposition == .throw) stack.values[operand_base + 1] else null;

    const result = disposeStack(vm.ctx, vm.output, vm.global, stack_value, completion) catch |err| {
        try popOwnedOperands(vm.rt, stack, operand_count);
        return routeRuntimeError(vm, err);
    };
    try popOwnedOperands(vm.rt, stack, operand_count);
    stack.pushOwnedAssumeCapacity(result);
}


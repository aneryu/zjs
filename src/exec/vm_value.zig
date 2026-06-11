const std = @import("std");

const bytecode = @import("../bytecode/root.zig");
const builtins = @import("../builtins/root.zig");
const core = @import("../core/root.zig");
const dtoa = @import("../libs/dtoa.zig");
const frame_mod = @import("frame.zig");
const property_ops = @import("property_ops.zig");
const stack_mod = @import("stack.zig");
const value_ops = @import("value_ops.zig");

const op = bytecode.opcode.op;

pub const DropResult = union(enum) {
    value,
    catch_target: ?usize,
};

pub const Step = enum { done, continue_loop };

pub const GlobalFastPathEnv = struct {
    global: *core.Object,
    eval_local_names: []const core.Atom,
    eval_var_ref_names: []const core.Atom,
    eval_with_object: core.JSValue,
};

pub const PushAtomValueFastPaths = struct {
    global_env: GlobalFastPathEnv,
    regexp_prototype: ?*core.Object,
};

pub fn pushInt32Operand(stack: *stack_mod.Stack, function: *const bytecode.Bytecode, frame: *frame_mod.Frame) !void {
    const value = readInt(i32, function.code[frame.pc..][0..4]);
    frame.pc += 4;
    try pushImmediateInt32MaybeFuse(stack, function, frame, value);
}

pub fn pushBigIntI32Operand(stack: *stack_mod.Stack, function: *const bytecode.Bytecode, frame: *frame_mod.Frame) !void {
    const value = readInt(i32, function.code[frame.pc..][0..4]);
    frame.pc += 4;
    try stack.pushOwned(core.JSValue.shortBigInt(value));
}

pub fn pushI16Operand(stack: *stack_mod.Stack, function: *const bytecode.Bytecode, frame: *frame_mod.Frame) !void {
    const value = readInt(i16, function.code[frame.pc..][0..2]);
    frame.pc += 2;
    try pushImmediateInt32MaybeFuse(stack, function, frame, value);
}

pub fn pushI16OperandVm(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    fast_paths: GlobalFastPathEnv,
    comptime tryFuseGlobalInt32PrefixTermsStore: anytype,
    comptime globalLexicalValue: anytype,
) !void {
    if (tryFuseGlobalInt32PrefixTermsStore(ctx, fast_paths.global, function, frame, frame.pc - 1, fast_paths.eval_local_names, fast_paths.eval_var_ref_names, fast_paths.eval_with_object, globalLexicalValue)) return;
    try pushI16Operand(stack, function, frame);
}

pub fn pushI8Operand(stack: *stack_mod.Stack, function: *const bytecode.Bytecode, frame: *frame_mod.Frame) !void {
    const value: i8 = @bitCast(function.code[frame.pc]);
    frame.pc += 1;
    try pushImmediateInt32MaybeFuse(stack, function, frame, value);
}

pub fn pushSmallInt(stack: *stack_mod.Stack, value: i32) !void {
    try stack.pushOwned(core.JSValue.int32(value));
}

pub fn pushSmallIntMaybeFuse(stack: *stack_mod.Stack, function: *const bytecode.Bytecode, frame: *frame_mod.Frame, value: i32) !void {
    try pushImmediateInt32MaybeFuse(stack, function, frame, value);
}

fn pushImmediateInt32MaybeFuse(
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    value: i32,
) !void {
    var current = value;
    var pc = frame.pc;
    var consumed = false;
    while (tryFoldImmediateInt32At(function.code, &pc, &current)) |result| {
        consumed = true;
        current = result.asInt32() orelse {
            frame.pc = pc;
            try pushImmediateBinaryResultMaybeFuseStackBinary(stack, function, frame, result);
            return;
        };
    }
    while (tryFoldFollowingImmediateInt32Term(function.code, &pc, &current)) |result| {
        consumed = true;
        current = result.asInt32() orelse {
            frame.pc = pc;
            try pushImmediateBinaryResultMaybeFuseStackBinary(stack, function, frame, result);
            return;
        };
    }
    if (consumed) frame.pc = pc;
    try pushImmediateBinaryResultMaybeFuseStackBinary(stack, function, frame, core.JSValue.int32(current));
}

fn tryFoldImmediateInt32At(code: []const u8, pc: *usize, current: *const i32) ?core.JSValue {
    const immediate = immediateInt32Operand(code, pc.*) orelse return null;
    if (immediate.next_pc >= code.len) return null;
    const result = fastInt32ImmediateBinary(code[immediate.next_pc], current.*, immediate.value) orelse return null;
    pc.* = immediate.next_pc + 1;
    return result;
}

fn tryFoldFollowingImmediateInt32Term(code: []const u8, pc: *usize, current: *const i32) ?core.JSValue {
    const rhs = immediateInt32Operand(code, pc.*) orelse return null;
    var rhs_value = rhs.value;
    var rhs_pc = rhs.next_pc;
    while (tryFoldImmediateInt32At(code, &rhs_pc, &rhs_value)) |rhs_result| {
        rhs_value = rhs_result.asInt32() orelse return null;
    }
    if (rhs_pc >= code.len) return null;
    const result = fastInt32ImmediateBinary(code[rhs_pc], current.*, rhs_value) orelse return null;
    pc.* = rhs_pc + 1;
    return result;
}

const ImmediateInt32 = struct {
    value: i32,
    next_pc: usize,
};

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
            const rhs: i8 = @bitCast(code[pc + 1]);
            break :blk .{ .value = rhs, .next_pc = pc + 2 };
        },
        op.push_i16 => blk: {
            if (pc + 3 > code.len) return null;
            break :blk .{ .value = readInt(i16, code[pc + 1 ..][0..2]), .next_pc = pc + 3 };
        },
        op.push_i32 => blk: {
            if (pc + 5 > code.len) return null;
            break :blk .{ .value = readInt(i32, code[pc + 1 ..][0..4]), .next_pc = pc + 5 };
        },
        else => null,
    };
}

fn pushImmediateBinaryResultMaybeFuseStackBinary(
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    rhs_value: core.JSValue,
) !void {
    const rhs = rhs_value.asInt32() orelse {
        try stack.pushOwned(rhs_value);
        return;
    };
    if (frame.pc < function.code.len) {
        if (stack.peekBorrowed()) |lhs_value| {
            if (lhs_value.asInt32()) |lhs| {
                if (fastInt32ImmediateBinary(function.code[frame.pc], lhs, rhs)) |result| {
                    _ = try stack.pop();
                    try stack.pushOwned(result);
                    frame.pc += 1;
                    return;
                }
            }
        }
    }
    try stack.pushOwned(rhs_value);
}

fn fastInt32ImmediateBinary(opcode_id: u8, lhs: i32, rhs: i32) ?core.JSValue {
    return switch (opcode_id) {
        op.add => fastInt32Add(lhs, rhs),
        op.sub => fastInt32Sub(lhs, rhs),
        op.mul => fastInt32Mul(lhs, rhs),
        op.sar => core.JSValue.int32(lhs >> @intCast(rhs & 31)),
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

pub fn pushUndefined(stack: *stack_mod.Stack) !void {
    try stack.pushOwned(core.JSValue.undefinedValue());
}

pub fn pushNull(stack: *stack_mod.Stack) !void {
    try stack.pushOwned(core.JSValue.nullValue());
}

pub fn pushBoolean(stack: *stack_mod.Stack, value: bool) !void {
    try stack.pushOwned(core.JSValue.boolean(value));
}

pub fn pushConst(ctx: *core.JSContext, stack: *stack_mod.Stack, function: *const bytecode.Bytecode, frame: *frame_mod.Frame, opc: u8) !void {
    _ = opc;
    const index = readInt(u32, function.code[frame.pc..][0..4]);
    frame.pc += 4;
    const value = function.constants.get(index) orelse return error.TypeError;
    defer value.free(ctx.runtime);
    try stack.push(value);
}

pub fn pushConst8(ctx: *core.JSContext, stack: *stack_mod.Stack, function: *const bytecode.Bytecode, frame: *frame_mod.Frame, opc: u8) !void {
    _ = opc;
    const index = function.code[frame.pc];
    frame.pc += 1;
    const value = function.constants.get(index) orelse return error.TypeError;
    defer value.free(ctx.runtime);
    try stack.push(value);
}

pub fn pushAtomValue(ctx: *core.JSContext, stack: *stack_mod.Stack, function: *const bytecode.Bytecode, frame: *frame_mod.Frame) !void {
    const atom_id = readInt(u32, function.code[frame.pc..][0..4]);
    if (ctx.runtime.opcode_profile == null) {
        if (try pushFusedAsciiAtomStringConcat(ctx, stack, function, frame, atom_id)) return;
    }
    frame.pc += 4;
    const value = try ctx.runtime.atoms.toStringValue(ctx.runtime, atom_id);
    errdefer value.free(ctx.runtime);
    try stack.pushOwned(value);
}

pub fn pushAtomValueVm(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    fast_paths: PushAtomValueFastPaths,
    comptime tryFuseAtomPercentHexGlobalStringStore: anytype,
    comptime tryPushRegexpLiteralFromAtomPair: anytype,
    comptime globalLexicalValue: anytype,
) !void {
    const global_env = fast_paths.global_env;
    if (try tryFuseAtomPercentHexGlobalStringStore(ctx, global_env.global, function, frame, global_env.eval_local_names, global_env.eval_var_ref_names, global_env.eval_with_object, globalLexicalValue)) return;
    if (ctx.runtime.opcode_profile == null and try tryPushRegexpLiteralFromAtomPair(ctx, global_env.global, stack, function, frame, fast_paths.regexp_prototype)) return;
    try pushAtomValue(ctx, stack, function, frame);
}

fn pushFusedAsciiAtomStringConcat(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    first_atom: core.Atom,
) !bool {
    const code = function.code;
    const second_op_pc = frame.pc + 4;
    var first_buf: [10]u8 = undefined;
    const first = atomAsciiText(ctx.runtime, first_atom, &first_buf) orelse return false;
    if (second_op_pc < code.len and code[second_op_pc] == op.push_atom_value) {
        if (second_op_pc + 6 > code.len) return false;
        const second_atom = readInt(u32, code[second_op_pc + 1 ..][0..4]);
        if (code[second_op_pc + 5] != op.add) return false;

        var second_buf: [10]u8 = undefined;
        const second = atomAsciiText(ctx.runtime, second_atom, &second_buf) orelse return false;
        const out = try core.string.String.createLatin1Concat(ctx.runtime, first, second);
        const value = out.value();
        errdefer value.free(ctx.runtime);
        try stack.pushOwned(value);
        frame.pc = second_op_pc + 6;
        return true;
    }
    const second_int = immediateInt32Operand(code, second_op_pc) orelse return false;
    if (second_int.next_pc >= code.len or code[second_int.next_pc] != op.add) return false;

    var int_buf: [16]u8 = undefined;
    const digits = dtoa.formatInt32(&int_buf, second_int.value);
    const out = try core.string.String.createLatin1Concat(ctx.runtime, first, digits);
    const value = out.value();
    errdefer value.free(ctx.runtime);
    try stack.pushOwned(value);
    frame.pc = second_int.next_pc + 1;
    return true;
}

fn atomAsciiText(rt: *core.JSRuntime, atom_id: core.Atom, buffer: *[10]u8) ?[]const u8 {
    if (rt.atoms.kind(atom_id) != .string) return null;
    if (core.atom.isTaggedInt(atom_id)) {
        return std.fmt.bufPrint(buffer, "{d}", .{core.atom.atomToUInt32(atom_id)}) catch return null;
    }
    const text = rt.atoms.name(atom_id) orelse return null;
    if (!core.string.isAsciiBytes(text)) return null;
    return text;
}

pub fn pushPrivateSymbol(ctx: *core.JSContext, stack: *stack_mod.Stack, function: *const bytecode.Bytecode, frame: *frame_mod.Frame) !void {
    const atom_id = readInt(u32, function.code[frame.pc..][0..4]);
    frame.pc += 4;
    const effective_atom = remapPrivateAtomFromFrame(ctx.runtime, frame, atom_id);
    try stack.pushOwned(core.JSValue.symbol(effective_atom));
}

pub fn pushEmptyString(ctx: *core.JSContext, stack: *stack_mod.Stack) !void {
    const value = (try ctx.runtime.emptyString()).value().dup();
    errdefer value.free(ctx.runtime);
    try stack.pushOwned(value);
}

pub fn pushThis(stack: *stack_mod.Stack, this_value: core.JSValue) !void {
    if (varRefSlotIsUninitialized(this_value)) return error.ReferenceError;
    try pushSlotValue(stack, this_value);
}

pub fn pushThisVm(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    global: *core.Object,
    comptime handleCatchableRuntimeError: anytype,
) !Step {
    pushThis(stack, frame.this_value) catch |err| switch (err) {
        error.ReferenceError => {
            if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, error.ReferenceError)) return .continue_loop;
            return error.ReferenceError;
        },
        else => return err,
    };
    return .done;
}

pub fn toObject(ctx: *core.JSContext, stack: *stack_mod.Stack) !void {
    const value = try stack.pop();
    defer value.free(ctx.runtime);
    var object_value = try toObjectForWith(ctx.runtime, value);
    errdefer object_value.free(ctx.runtime);
    const object = try property_ops.expectObject(object_value);
    object.flags.is_with_environment = true;
    try stack.pushOwned(object_value);
}

pub fn toObjectVm(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    global: *core.Object,
    comptime handleCatchableRuntimeError: anytype,
) !Step {
    toObject(ctx, stack) catch |err| switch (err) {
        error.TypeError => {
            if (try handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, error.TypeError)) return .continue_loop;
            return error.TypeError;
        },
        else => return err,
    };
    return .done;
}

pub fn typeOf(ctx: *core.JSContext, stack: *stack_mod.Stack) !void {
    const value = try stack.pop();
    defer value.free(ctx.runtime);
    const text: []const u8 = if (value.isUndefined() or value_ops.isHTMLDDA(value))
        "undefined"
    else if (value.isNull())
        "object"
    else if (value.isBool())
        "boolean"
    else if (value.isBigInt())
        "bigint"
    else if (value.isNumber())
        "number"
    else if (value.isString())
        "string"
    else if (value.isSymbol())
        "symbol"
    else if (value.isFunctionBytecode() or functionObjectFromValue(value) != null or callableObjectFromValue(value) != null or proxyTargetIsCallable(value))
        "function"
    else
        "object";
    const out = try value_ops.createStringValue(ctx.runtime, text);
    errdefer out.free(ctx.runtime);
    try stack.pushOwned(out);
}

pub fn typeOfIsUndefined(rt: *core.JSRuntime, stack: *stack_mod.Stack) !void {
    const value = try stack.pop();
    defer value.free(rt);
    try stack.pushOwned(core.JSValue.boolean(value.isUndefined() or value_ops.isHTMLDDA(value)));
}

pub fn typeOfIsFunction(rt: *core.JSRuntime, stack: *stack_mod.Stack) !void {
    const value = try stack.pop();
    defer value.free(rt);
    const is_func = value.isFunctionBytecode() or functionObjectFromValue(value) != null;
    try stack.pushOwned(core.JSValue.boolean(is_func));
}

pub fn logicalNot(rt: *core.JSRuntime, stack: *stack_mod.Stack) !void {
    const value = try stack.pop();
    defer value.free(rt);
    try stack.pushOwned(core.JSValue.boolean(!value_ops.isTruthy(value)));
}

pub fn drop(rt: *core.JSRuntime, stack: *stack_mod.Stack) !DropResult {
    const value = try stack.pop();
    if (value.isCatchOffset()) {
        if ((value.asCatchOffset() orelse -1) == 0) {
            value.free(rt);
            return .value;
        }
        const target = catchTargetFromMarker(value);
        return .{ .catch_target = target };
    }
    value.free(rt);
    return .value;
}

pub fn nipCatch(rt: *core.JSRuntime, stack: *stack_mod.Stack) !void {
    const ret_value = try stack.pop();

    while (stack.values.len != 0) {
        const value = try stack.pop();
        if (value.isCatchOffset()) {
            value.free(rt);
            stack.pushOwned(ret_value) catch |err| {
                ret_value.free(rt);
                return err;
            };
            return;
        }
        value.free(rt);
    }

    ret_value.free(rt);
    return error.InvalidBytecode;
}

pub fn dup(ctx: *core.JSContext, stack: *stack_mod.Stack, opc: u8) !void {
    _ = ctx;
    _ = opc;
    const value = stack.peekBorrowed() orelse return error.StackUnderflow;
    try stack.push(value);
}

pub fn swap(ctx: *core.JSContext, stack: *stack_mod.Stack) !void {
    _ = ctx;
    try requireStackLen(stack, 2);
    const a = try stack.pop();
    const b = try stack.pop();
    stack.pushOwnedAssumeCapacity(a);
    stack.pushOwnedAssumeCapacity(b);
}

pub fn nip(ctx: *core.JSContext, stack: *stack_mod.Stack) !void {
    try requireStackLen(stack, 2);
    const top = try stack.pop();
    const second = try stack.pop();
    second.free(ctx.runtime);
    stack.pushOwnedAssumeCapacity(top);
}

pub fn nip1(ctx: *core.JSContext, stack: *stack_mod.Stack) !void {
    try requireStackLen(stack, 3);
    const c = try stack.pop();
    const b = try stack.pop();
    const a = try stack.pop();
    a.free(ctx.runtime);
    stack.pushOwnedAssumeCapacity(b);
    stack.pushOwnedAssumeCapacity(c);
}

pub fn dup2(ctx: *core.JSContext, stack: *stack_mod.Stack) !void {
    _ = ctx;
    try requireStackLen(stack, 2);
    try stack.reserveAdditional(2);
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
    try stack.reserveAdditional(1);
    const b = try stack.pop();
    const a = try stack.pop();
    stack.pushAssumeCapacity(a);
    stack.pushOwnedAssumeCapacity(a);
    stack.pushOwnedAssumeCapacity(b);
}

pub fn dup3(ctx: *core.JSContext, stack: *stack_mod.Stack) !void {
    _ = ctx;
    try requireStackLen(stack, 3);
    try stack.reserveAdditional(3);
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

pub fn insert2(ctx: *core.JSContext, stack: *stack_mod.Stack) !void {
    _ = ctx;
    try requireStackLen(stack, 2);
    try stack.reserveAdditional(1);
    const b = try stack.pop();
    const a = try stack.pop();
    stack.pushAssumeCapacity(b);
    stack.pushOwnedAssumeCapacity(a);
    stack.pushOwnedAssumeCapacity(b);
}

pub fn insert3(ctx: *core.JSContext, stack: *stack_mod.Stack) !void {
    _ = ctx;
    try requireStackLen(stack, 3);
    try stack.reserveAdditional(1);
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
    try stack.reserveAdditional(1);
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

pub fn rot3l(ctx: *core.JSContext, stack: *stack_mod.Stack) !void {
    _ = ctx;
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

pub fn perm3(ctx: *core.JSContext, stack: *stack_mod.Stack) !void {
    _ = ctx;
    try requireStackLen(stack, 3);
    const c = try stack.pop();
    const b = try stack.pop();
    const a = try stack.pop();
    stack.pushOwnedAssumeCapacity(b);
    stack.pushOwnedAssumeCapacity(a);
    stack.pushOwnedAssumeCapacity(c);
}

pub fn perm4(ctx: *core.JSContext, stack: *stack_mod.Stack) !void {
    _ = ctx;
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

pub fn isUndefinedOrNull(rt: *core.JSRuntime, stack: *stack_mod.Stack) !void {
    const value = try stack.pop();
    defer value.free(rt);
    try stack.pushOwned(core.JSValue.boolean(value.isUndefined() or value.isNull()));
}

pub fn isUndefined(rt: *core.JSRuntime, stack: *stack_mod.Stack) !void {
    const value = try stack.pop();
    defer value.free(rt);
    try stack.pushOwned(core.JSValue.boolean(value.isUndefined()));
}

pub fn isNull(rt: *core.JSRuntime, stack: *stack_mod.Stack) !void {
    const value = try stack.pop();
    defer value.free(rt);
    try stack.pushOwned(core.JSValue.boolean(value.isNull()));
}

pub fn toObjectForWith(rt: *core.JSRuntime, value: core.JSValue) !core.JSValue {
    if (value.isObject()) return value.dup();
    if (value.isNull() or value.isUndefined()) return error.TypeError;
    if (value.isString()) return builtins.string.constructWithPrototype(rt, &.{value}, null);
    if (value.isNumber()) return primitiveObject(rt, core.class.ids.number, value);
    if (value.asBool() != null) return primitiveObject(rt, core.class.ids.boolean, value);
    if (value.isBigInt()) return primitiveObject(rt, core.class.ids.big_int, value);
    if (value.isSymbol()) return primitiveObject(rt, core.class.ids.symbol, value);
    return error.TypeError;
}

fn primitiveObject(rt: *core.JSRuntime, class_id: core.class.ClassId, primitive: core.JSValue) !core.JSValue {
    var rooted_primitive = primitive;
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &rooted_primitive },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    const object = try core.Object.create(rt, class_id, null);
    errdefer core.Object.destroyFromHeader(rt, &object.header);
    try object.setOptionalValueSlot(rt, object.objectDataSlot(), rooted_primitive.dup());
    return object.value();
}

test "primitiveObject roots direct symbol while creating ToObject wrapper" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const symbol_atom = try rt.atoms.newValueSymbol("gc-vm-value-wrapper-symbol");
    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const wrapper_value = try primitiveObject(rt, core.class.ids.symbol, core.JSValue.symbol(symbol_atom));
    var wrapper_alive = true;
    defer if (wrapper_alive) wrapper_value.free(rt);
    const wrapper = property_ops.expectObject(wrapper_value) catch return error.TypeError;

    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    const stored = wrapper.objectData() orelse return error.TypeError;
    try std.testing.expect(stored.same(core.JSValue.symbol(symbol_atom)));

    wrapper_value.free(rt);
    wrapper_alive = false;
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

fn pushSlotValue(stack: *stack_mod.Stack, slot: core.JSValue) !void {
    try stack.push(slotValueBorrow(slot));
}

fn slotValueBorrow(slot: core.JSValue) core.JSValue {
    var current = slot;
    var depth: usize = 0;
    while (depth < 16) : (depth += 1) {
        const cell = varRefCellFromValue(current) orelse return current;
        current = cell.varRefValueSlot().* orelse return core.JSValue.undefinedValue();
    }
    return current;
}

fn requireStackLen(stack: *const stack_mod.Stack, required: usize) !void {
    if (stack.values.len < required) return error.StackUnderflow;
}

fn expectStackInt32s(stack: *const stack_mod.Stack, expected: []const i32) !void {
    try std.testing.expectEqual(expected.len, stack.values.len);
    for (expected, 0..) |value, index| {
        try std.testing.expectEqual(@as(?i32, value), stack.values[index].asInt32());
    }
}

fn varRefSlotIsUninitialized(slot: core.JSValue) bool {
    return slotValueBorrow(slot).isUninitialized();
}

fn varRefCellFromValue(value: core.JSValue) ?*core.Object {
    if (!value.isObject()) return null;
    const header = value.refHeader() orelse return null;
    const object: *core.Object = @fieldParentPtr("header", header);
    if (object.class_payload_kind != .var_ref) return null;
    return object;
}

fn functionObjectFromValue(value: core.JSValue) ?*core.Object {
    if (!value.isObject()) return null;
    const header = value.refHeader() orelse return null;
    const object: *core.Object = @fieldParentPtr("header", header);
    if (object.class_id != core.class.ids.bytecode_function) return null;
    return object;
}

fn objectFromValue(value: core.JSValue) ?*core.Object {
    if (!value.isObject()) return null;
    const header = value.refHeader() orelse return null;
    return @fieldParentPtr("header", header);
}

fn remapPrivateAtomFromObject(rt: *core.JSRuntime, object: *const core.Object, atom_id: core.Atom) core.Atom {
    if (rt.atoms.kind(atom_id) != .private) return atom_id;
    for (object.privateRemapFrom(), 0..) |old_atom, idx| {
        if (old_atom == atom_id) return object.privateRemapTo()[idx];
    }
    return atom_id;
}

fn remapPrivateAtomFromFrame(rt: *core.JSRuntime, frame: ?*frame_mod.Frame, atom_id: core.Atom) core.Atom {
    if (rt.atoms.kind(atom_id) != .private) return atom_id;
    const current_frame = frame orelse return atom_id;
    const function_object = objectFromValue(current_frame.current_function) orelse return atom_id;
    const function_atom = remapPrivateAtomFromObject(rt, function_object, atom_id);
    if (function_atom != atom_id) return function_atom;
    const home_object = function_object.functionHomeObjectSlot().* orelse return atom_id;
    return remapPrivateAtomFromObject(rt, home_object, atom_id);
}

fn callableObjectFromValue(value: core.JSValue) ?*core.Object {
    if (!value.isObject()) return null;
    const header = value.refHeader() orelse return null;
    const object: *core.Object = @fieldParentPtr("header", header);
    if (object.class_id != core.class.ids.c_function and
        object.class_id != core.class.ids.c_closure and
        object.class_id != core.class.ids.bound_function) return null;
    return object;
}

fn proxyTargetIsCallable(value: core.JSValue) bool {
    const object = objectFromValue(value) orelse return false;
    const target = object.proxyTarget() orelse return false;
    return target.isFunctionBytecode() or functionObjectFromValue(target) != null or callableObjectFromValue(target) != null or proxyTargetIsCallable(target);
}

fn catchTargetFromMarker(marker: core.JSValue) ?usize {
    const previous = marker.asCatchOffset() orelse -1;
    if (previous < 0) return null;
    return @intCast(previous);
}

fn readInt(comptime T: type, bytes: []const u8) T {
    return std.mem.readInt(T, bytes[0..@sizeOf(T)], .little);
}

test "push private symbol does not retain transient private atom" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const function_name = try rt.internAtom("pushPrivateSymbolNoRetain");
    defer rt.atoms.free(function_name);
    const private_name = try rt.atoms.newSymbol("pushPrivateSymbolNoRetainName", .private);
    var private_name_released = false;
    defer if (!private_name_released) rt.atoms.free(private_name);

    var function = bytecode.Bytecode.init(&rt.memory, &rt.atoms, function_name);
    defer function.deinit(rt);
    var code: [4]u8 = undefined;
    std.mem.writeInt(u32, &code, private_name, .little);
    try function.setCode(&code);

    var frame = frame_mod.Frame.init(&function);
    var stack = stack_mod.Stack.init(&rt.memory, 8);
    defer stack.deinit(rt);

    try pushPrivateSymbol(ctx, &stack, &function, &frame);
    const value = try stack.pop();
    try std.testing.expectEqual(private_name, value.asSymbolAtom().?);
    value.free(rt);

    rt.atoms.free(private_name);
    private_name_released = true;
    try std.testing.expect(rt.atoms.name(private_name) == null);
}

test "stack rearrange opcodes validate depth before mutating stack" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
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
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const function_name = try rt.internAtom("pushPrivateSymbolStackFailure");
    defer rt.atoms.free(function_name);
    const private_name = try rt.atoms.newSymbol("pushPrivateSymbolStackFailureName", .private);
    var private_name_released = false;
    defer if (!private_name_released) rt.atoms.free(private_name);

    var function = bytecode.Bytecode.init(&rt.memory, &rt.atoms, function_name);
    defer function.deinit(rt);
    var code: [4]u8 = undefined;
    std.mem.writeInt(u32, &code, private_name, .little);
    try function.setCode(&code);

    var frame = frame_mod.Frame.init(&function);
    var stack = stack_mod.Stack.init(&rt.memory, 0);
    defer stack.deinit(rt);

    try std.testing.expectError(error.StackOverflow, pushPrivateSymbol(ctx, &stack, &function, &frame));

    rt.atoms.free(private_name);
    private_name_released = true;
    try std.testing.expect(rt.atoms.name(private_name) == null);
}

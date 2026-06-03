const std = @import("std");

const bytecode = @import("../../bytecode/root.zig");
const core = @import("../../core/root.zig");
const frame_mod = @import("../frame.zig");
const stack_mod = @import("../stack.zig");
const value_ops = @import("../value_ops.zig");

pub const ThrowResult = enum {
    handled,
};

pub const ThrowError = error{
    SyntaxError,
    ReferenceError,
    TypeError,
};

pub fn returnTop(ctx: *core.JSContext, stack: *stack_mod.Stack, frame: *frame_mod.Frame, generator: ?*core.Object) !core.JSValue {
    if (generator) |generator_object| generator_object.generatorDoneSlot().* = true;
    const value = stack.peek() orelse core.JSValue.undefinedValue();
    return finishFunctionReturn(ctx, frame, value);
}

pub fn returnUndefined(ctx: *core.JSContext, frame: *frame_mod.Frame, generator: ?*core.Object) !core.JSValue {
    if (generator) |generator_object| generator_object.generatorDoneSlot().* = true;
    return finishFunctionReturn(ctx, frame, core.JSValue.undefinedValue());
}

pub fn finishFunctionReturn(ctx: *core.JSContext, frame: *frame_mod.Frame, value: core.JSValue) !core.JSValue {
    if (!frame.function.flags.is_derived_class_constructor) return value;
    if (value.isObject()) return value;
    defer value.free(ctx.runtime);
    if (!value.isUndefined()) return error.TypeError;
    if (varRefSlotIsUninitialized(frame.this_value)) return error.ReferenceError;
    return slotValueDup(frame.this_value);
}

pub fn jump32(function: *const bytecode.Bytecode, frame: *frame_mod.Frame) void {
    const operand_pc = frame.pc;
    const diff = readInt(i32, function.code[frame.pc..][0..4]);
    frame.pc = relativePc(operand_pc, diff);
}

pub fn jump16(function: *const bytecode.Bytecode, frame: *frame_mod.Frame) void {
    const operand_pc = frame.pc;
    const diff = readInt(i16, function.code[frame.pc..][0..2]);
    frame.pc = relativePc(operand_pc, diff);
}

pub fn jump8(function: *const bytecode.Bytecode, frame: *frame_mod.Frame) void {
    const operand_pc = frame.pc;
    const diff: i8 = @bitCast(function.code[frame.pc]);
    frame.pc = relativePc(operand_pc, diff);
}

pub fn branch32(ctx: *core.JSContext, stack: *stack_mod.Stack, function: *const bytecode.Bytecode, frame: *frame_mod.Frame, branch_if_true: bool) !void {
    const operand_pc = frame.pc;
    const diff = readInt(i32, function.code[frame.pc..][0..4]);
    frame.pc += 4;
    const value = try stack.pop();
    defer value.free(ctx.runtime);
    const truthy = value.asBool() orelse value_ops.isTruthy(value);
    if (truthy == branch_if_true) {
        frame.pc = relativePc(operand_pc, diff);
    }
}

pub fn branch8(ctx: *core.JSContext, stack: *stack_mod.Stack, function: *const bytecode.Bytecode, frame: *frame_mod.Frame, branch_if_true: bool) !void {
    const operand_pc = frame.pc;
    const diff: i8 = @bitCast(function.code[frame.pc]);
    frame.pc += 1;
    const value = try stack.pop();
    defer value.free(ctx.runtime);
    const truthy = value.asBool() orelse value_ops.isTruthy(value);
    if (truthy == branch_if_true) {
        frame.pc = relativePc(operand_pc, diff);
    }
}

pub fn throwTop(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    comptime closeStackTopForOfIteratorForPendingError: anytype,
) !ThrowResult {
    const value = try stack.pop();
    var value_owned = true;
    errdefer if (value_owned) value.free(ctx.runtime);
    try closeStackTopForOfIteratorForPendingError(ctx, output, global, stack);
    try stack.reserveAdditional(1);
    if (catch_target.* == null) {
        if (try popCatchMarker(ctx.runtime, stack)) |restored| {
            catch_target.* = restored;
        }
    }
    if (catch_target.*) |target| {
        const restored = (try popCatchMarker(ctx.runtime, stack)) orelse null;
        stack.pushOwnedAssumeCapacity(value);
        value_owned = false;
        frame.pc = target;
        catch_target.* = restored;
        return .handled;
    }
    _ = ctx.throwValue(value);
    value_owned = false;
    return error.Test262Error;
}

pub fn throwError(function: *const bytecode.Bytecode, frame: *frame_mod.Frame) ThrowError {
    const error_type = function.code[frame.pc + 4];
    frame.pc += 5;
    return switch (error_type) {
        1 => error.SyntaxError,
        2, 3 => error.ReferenceError,
        else => error.TypeError,
    };
}

pub fn catchTarget(function: *const bytecode.Bytecode, frame: *frame_mod.Frame, stack: *stack_mod.Stack, catch_target: *?usize) !void {
    const operand_pc = frame.pc;
    const diff = readInt(i32, function.code[frame.pc..][0..4]);
    frame.pc += 4;
    const previous_target: i32 = if (catch_target.*) |target| @intCast(target) else -1;
    catch_target.* = relativePc(operand_pc, diff);
    try stack.pushOwned(core.JSValue.catchOffset(previous_target));
}

pub fn gosub(function: *const bytecode.Bytecode, frame: *frame_mod.Frame, stack: *stack_mod.Stack) !void {
    const operand_pc = frame.pc;
    const diff = readInt(i32, function.code[frame.pc..][0..4]);
    const return_pc = frame.pc + 4;
    if (return_pc > @as(usize, @intCast(std.math.maxInt(i32)))) return error.InvalidBytecode;
    try stack.pushOwned(core.JSValue.int32(@intCast(return_pc)));
    frame.pc = relativePc(operand_pc, diff);
}

pub fn ret(ctx: *core.JSContext, function: *const bytecode.Bytecode, frame: *frame_mod.Frame, stack: *stack_mod.Stack) !void {
    const target = try stack.pop();
    defer target.free(ctx.runtime);
    const pc_i32 = target.asInt32() orelse return error.InvalidBytecode;
    if (pc_i32 < 0) return error.InvalidBytecode;
    const pc: usize = @intCast(pc_i32);
    if (pc >= function.code.len) return error.InvalidBytecode;
    frame.pc = pc;
}

pub fn nop() void {}

fn relativePc(operand_pc: usize, diff: anytype) usize {
    return @intCast(@as(i64, @intCast(operand_pc)) + @as(i64, diff));
}

fn popCatchMarker(rt: *core.JSRuntime, stack: *stack_mod.Stack) !??usize {
    while (stack.peekBorrowed()) |marker| {
        const popped = try stack.pop();
        if (marker.isCatchOffset()) return catchTargetFromMarker(popped);
        popped.free(rt);
    }
    return null;
}

fn catchTargetFromMarker(marker: core.JSValue) ?usize {
    const previous = marker.asCatchOffset() orelse -1;
    if (previous < 0) return null;
    return @intCast(previous);
}

fn slotValueDup(slot: core.JSValue) core.JSValue {
    return slotValueBorrow(slot).dup();
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

fn varRefSlotIsUninitialized(slot: core.JSValue) bool {
    return slotValueBorrow(slot).tag == core.Tag.uninitialized;
}

fn varRefCellFromValue(value: core.JSValue) ?*core.Object {
    if (!value.isObject()) return null;
    const header = value.refHeader() orelse return null;
    const object: *core.Object = @fieldParentPtr("header", header);
    if (object.class_payload_kind != .var_ref) return null;
    return object;
}

fn readInt(comptime T: type, bytes: []const u8) T {
    return std.mem.readInt(T, bytes[0..@sizeOf(T)], .little);
}

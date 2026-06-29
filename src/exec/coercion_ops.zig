//! Primitive coercion: ToPrimitive/ToNumber/ToLength/ToUint32 helpers and wrapper extraction.

const bytecode = @import("../bytecode.zig");
const core = @import("../core/root.zig");
const frame_mod = @import("frame.zig");
const property_ops = @import("property_ops.zig");
const std = @import("std");
const value_ops = @import("value_ops.zig");

const call_runtime = @import("call_runtime.zig");
const object_ops = @import("object_ops.zig");

// Helpers that remain in call_runtime.zig (generic utilities outside the coercion
// cluster).
const callObjectToPrimitiveMethod = object_ops.callObjectToPrimitiveMethod;
const callValueOrBytecode = call_runtime.callValueOrBytecode;
const getValueProperty = object_ops.getValueProperty;
const isCallableValue = call_runtime.isCallableValue;

/// qjs JS_ToPrimitiveFree: CONSUMES `value` (ownership transfers in). A non-object
/// operand — the hot int/float add case — passes straight through with no dup and
/// no free; only objects fall to the outlined Symbol.toPrimitive path, which frees
/// the input object. The caller hands in an owned value and owns the result out.
/// This is the faithful primitive; `toPrimitiveForAddition` borrows on top of it.
pub inline fn toPrimitiveForAdditionFree(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.JSValue,
) !core.JSValue {
    if (!value.isObject()) return value;
    return toPrimitiveForAdditionObject(ctx, output, global, value);
}

/// Borrowing wrapper for callers that hold a borrowed value: dups first so the
/// consume contract of `toPrimitiveForAdditionFree` leaves their reference intact.
pub inline fn toPrimitiveForAddition(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.JSValue,
) !core.JSValue {
    return toPrimitiveForAdditionFree(ctx, output, global, value.dup());
}

fn toPrimitiveForAdditionObject(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.JSValue,
) !core.JSValue {
    defer value.free(ctx.runtime); // consume: JS_ToPrimitiveFree frees the input object
    const symbol_to_primitive = core.atom.predefinedId("Symbol.toPrimitive", .symbol) orelse return toOrdinaryPrimitive(ctx, output, global, value);
    const method = try getValueProperty(ctx, output, global, value, symbol_to_primitive, null, null);
    defer method.free(ctx.runtime);
    if (!method.isUndefined() and !method.isNull()) {
        if (!isCallableValue(method)) return error.TypeError;
        const hint = try value_ops.createStringValue(ctx.runtime, "default");
        defer hint.free(ctx.runtime);
        const primitive = try callValueOrBytecode(ctx, output, global, value, method, &.{hint}, null, null);
        if (primitive.isObject()) {
            primitive.free(ctx.runtime);
            return error.TypeError;
        }
        return primitive;
    }

    return toOrdinaryPrimitive(ctx, output, global, value);
}

pub fn toPrimitiveForNumber(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.JSValue,
) !core.JSValue {
    if (!value.isObject()) return value.dup();
    const symbol_to_primitive = core.atom.predefinedId("Symbol.toPrimitive", .symbol) orelse return toOrdinaryPrimitiveNumber(ctx, output, global, value);
    const method = try getValueProperty(ctx, output, global, value, symbol_to_primitive, null, null);
    defer method.free(ctx.runtime);
    if (!method.isUndefined() and !method.isNull()) {
        if (!isCallableValue(method)) return error.TypeError;
        const hint = try value_ops.createStringValue(ctx.runtime, "number");
        defer hint.free(ctx.runtime);
        const primitive = try callValueOrBytecode(ctx, output, global, value, method, &.{hint}, null, null);
        if (primitive.isObject()) {
            primitive.free(ctx.runtime);
            return error.TypeError;
        }
        return primitive;
    }

    return toOrdinaryPrimitiveNumber(ctx, output, global, value);
}

pub fn toOrdinaryPrimitive(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.JSValue,
) !core.JSValue {
    if (try callObjectToPrimitiveMethod(ctx, output, global, value, "valueOf", null, null)) |primitive| return primitive;
    if (try callObjectToPrimitiveMethod(ctx, output, global, value, "toString", null, null)) |primitive| return primitive;
    return error.TypeError;
}

pub fn toOrdinaryPrimitiveNumber(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.JSValue,
) !core.JSValue {
    if (try callObjectToPrimitiveMethod(ctx, output, global, value, "valueOf", null, null)) |primitive| return primitive;
    if (try callObjectToPrimitiveMethod(ctx, output, global, value, "toString", null, null)) |primitive| return primitive;
    return error.TypeError;
}

pub fn valueTruthy(value: core.JSValue) bool {
    return value_ops.isTruthy(value);
}

pub fn toUint16CodeUnit(number: f64) u16 {
    if (std.math.isNan(number) or !std.math.isFinite(number) or number == 0) return 0;
    const int = if (number < 0) -@floor(@abs(number)) else @floor(number);
    const modulo = @mod(int, 65536.0);
    return @intFromFloat(modulo);
}

pub fn toLengthIndex(ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, value: core.JSValue) !usize {
    const length = try toLengthNumber(ctx, output, global, value);
    if (length >= @as(f64, @floatFromInt(std.math.maxInt(usize)))) return std.math.maxInt(usize);
    return @intFromFloat(length);
}

pub fn toLengthNumber(ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, value: core.JSValue) !f64 {
    const primitive = try toPrimitiveForNumber(ctx, output, global, value);
    defer primitive.free(ctx.runtime);
    if (primitive.isBigInt()) return error.TypeError;
    const number_value = try value_ops.toNumberValue(ctx.runtime, primitive);
    defer number_value.free(ctx.runtime);
    const number = value_ops.numberValue(number_value) orelse std.math.nan(f64);
    if (std.math.isNan(number) or number <= 0) return 0;
    const max_length = 9007199254740991.0;
    if (number >= max_length) return max_length;
    return @floor(number);
}

pub fn fastToLengthIndex(value: core.JSValue) ?usize {
    if (value.asInt32()) |int_value| {
        if (int_value <= 0) return 0;
        return @intCast(int_value);
    }
    if (value.asFloat64()) |number| {
        if (std.math.isNan(number) or number <= 0) return 0;
        const max_length = 9007199254740991.0;
        const clamped = if (number >= max_length) max_length else @floor(number);
        if (clamped >= @as(f64, @floatFromInt(std.math.maxInt(usize)))) return std.math.maxInt(usize);
        return @intFromFloat(clamped);
    }
    return null;
}

pub fn toUint32Number(number: f64) u32 {
    if (std.math.isNan(number) or !std.math.isFinite(number) or number == 0) return 0;
    const integer = if (number < 0) -@floor(@abs(number)) else @floor(number);
    const modulo = @mod(integer, 4294967296.0);
    return @intFromFloat(modulo);
}

pub fn uint32NumberValue(value: u32) core.JSValue {
    if (value <= @as(u32, @intCast(std.math.maxInt(i32)))) return core.JSValue.int32(@intCast(value));
    return core.JSValue.float64(@floatFromInt(value));
}

pub fn coerceOptionalNumberMethodArgument(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    preserve_undefined: bool,
) !?core.JSValue {
    if (args.len == 0) return null;
    if (preserve_undefined and args[0].isUndefined()) return null;
    const primitive = try toPrimitiveForNumber(ctx, output, global, args[0]);
    defer primitive.free(ctx.runtime);
    if (primitive.isBigInt()) return error.TypeError;
    return try value_ops.toNumberValue(ctx.runtime, primitive);
}

pub fn primitiveWrapperStoredValue(rt: *core.JSRuntime, value: core.JSValue) ?core.JSValue {
    _ = rt;
    if (!value.isObject()) return null;
    const object = property_ops.expectObject(value) catch return null;
    switch (object.class_id) {
        core.class.ids.number,
        core.class.ids.boolean,
        core.class.ids.big_int,
        core.class.ids.symbol,
        => if (object.objectData()) |stored| return stored.dup() else return null,
        else => return null,
    }
}

pub fn toNumberForDateMethod(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    if (value.isObject()) {
        const primitive = try toPrimitiveForNumber(ctx, output, global, value);
        defer primitive.free(ctx.runtime);
        return value_ops.toNumberValue(ctx.runtime, primitive);
    }
    _ = caller_function;
    _ = caller_frame;
    return value_ops.toNumberValue(ctx.runtime, value);
}

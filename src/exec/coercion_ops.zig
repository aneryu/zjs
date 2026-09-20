//! Primitive coercion: ToPrimitive/ToNumber/ToLength/ToUint32 helpers and wrapper extraction.

const bytecode = @import("../bytecode.zig");
const core = @import("../core/root.zig");
const frame_mod = @import("frame.zig");
const property_ops = @import("property_ops.zig");
const std = @import("std");
const value_ops = @import("value_ops.zig");

const call_runtime = @import("call_runtime.zig");
const object_ops = @import("object_ops.zig");
const exception_ops = @import("exception_ops.zig");

// Helpers that remain in call_runtime.zig (generic utilities outside the coercion
// cluster).
const callObjectToPrimitiveMethod = object_ops.callObjectToPrimitiveMethod;
const callValueOrBytecodeSyncInternal = call_runtime.callValueOrBytecodeSyncInternalOutlined;
const getValueProperty = object_ops.getValueProperty;
const isCallableValue = call_runtime.isCallableValue;
const throwTypeErrorMessage = exception_ops.throwTypeErrorMessage;

/// qjs `JS_ToPrimitiveFree` (the name keeps qjs's; under the tracing GC there
/// is no ownership transfer and nothing is freed). A non-object operand -- the
/// hot int/float add case -- passes straight through; only objects fall to the
/// outlined Symbol.toPrimitive path.
pub inline fn toPrimitiveForAdditionFree(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.JSValue,
) !core.JSValue {
    if (!value.is(.object)) return value;
    return toPrimitiveForAdditionObject(ctx, output, global, value);
}

/// The `Free` suffix is a refcount-era spelling of qjs `JS_ToPrimitiveFree`
/// (it consumed its argument). Under the tracing GC nothing is consumed, so
/// the "borrowing wrapper" is literally the same call; both names stay because
/// each reads correctly at its own VM call sites.
pub const toPrimitiveForAddition = toPrimitiveForAdditionFree;

fn toPrimitiveForAdditionObject(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.JSValue,
) !core.JSValue {
    const symbol_to_primitive = core.atom.predefinedId("Symbol.toPrimitive", .symbol) orelse return toOrdinaryPrimitive(ctx, output, global, value);
    const method = try getValueProperty(ctx, output, global, value, symbol_to_primitive, null, null);
    if (!method.is(.undefined_value) and !method.is(.null_value)) {
        // JS_ToPrimitiveInternal (quickjs.c JS_CallFree): a non-callable
        // Symbol.toPrimitive is still called and reports "not a function"; an
        // object return value throws "toPrimitive".
        if (!isCallableValue(method)) return throwTypeErrorMessage(ctx, global, "not a function");
        const hint = try value_ops.createStringValue(ctx.runtime, "default");
        const primitive = try callValueOrBytecodeSyncInternal(ctx, output, global, value, method, &.{hint}, null, null);
        if (primitive.is(.object)) {
            return throwTypeErrorMessage(ctx, global, "toPrimitive");
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
    if (!value.is(.object)) return value;
    const symbol_to_primitive = core.atom.predefinedId("Symbol.toPrimitive", .symbol) orelse return toOrdinaryPrimitiveNumber(ctx, output, global, value);
    const method = try getValueProperty(ctx, output, global, value, symbol_to_primitive, null, null);
    if (!method.is(.undefined_value) and !method.is(.null_value)) {
        // JS_ToPrimitiveInternal (quickjs.c JS_CallFree): a non-callable
        // Symbol.toPrimitive is still called and reports "not a function"; an
        // object return value throws "toPrimitive".
        if (!isCallableValue(method)) return throwTypeErrorMessage(ctx, global, "not a function");
        const hint = try value_ops.createStringValue(ctx.runtime, "number");
        const primitive = try callValueOrBytecodeSyncInternal(ctx, output, global, value, method, &.{hint}, null, null);
        if (primitive.is(.object)) {
            return throwTypeErrorMessage(ctx, global, "toPrimitive");
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
    if (try callObjectToPrimitiveMethod(ctx, output, global, value, core.atom.ids.valueOf, null, null)) |primitive| return primitive;
    if (try callObjectToPrimitiveMethod(ctx, output, global, value, core.atom.ids.toString, null, null)) |primitive| return primitive;
    // JS_ToPrimitiveInternal: no primitive from valueOf/toString.
    return throwTypeErrorMessage(ctx, global, "toPrimitive");
}

pub fn toOrdinaryPrimitiveNumber(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.JSValue,
) !core.JSValue {
    if (try callObjectToPrimitiveMethod(ctx, output, global, value, core.atom.ids.valueOf, null, null)) |primitive| return primitive;
    if (try callObjectToPrimitiveMethod(ctx, output, global, value, core.atom.ids.toString, null, null)) |primitive| return primitive;
    // JS_ToPrimitiveInternal: no primitive from valueOf/toString.
    return throwTypeErrorMessage(ctx, global, "toPrimitive");
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
    var index: usize = undefined;
    try toLengthIndexInto(ctx, output, global, value, &index);
    return index;
}

/// QJS's `JS_ToLengthFree` returns an integer status and writes the converted
/// length through an out pointer. Keep the same ABI shape here so callers do
/// not need a 16-byte `!usize` result slot around the tag switch.
noinline fn toLengthIndexInto(ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, value: core.JSValue, index: *usize) !void {
    // QJS `JS_ToLengthFree` enters `JS_ToInt64SatFree`, whose first switch
    // handles integer/float tags directly and invokes ToNumber only for other
    // values. Keep object/Symbol/BigInt coercion on the observable slow path.
    if (fastToLengthIndex(value)) |converted| {
        index.* = converted;
        return;
    }
    index.* = try toLengthIndexSlow(ctx, output, global, value);
}

/// Observable ToPrimitive/ToNumber half of ToLength. Callers that have
/// already rejected the numeric tags can enter here without repeating the
/// primitive discriminator.
pub fn toLengthIndexSlow(ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, value: core.JSValue) !usize {
    const length = try toLengthNumber(ctx, output, global, value);
    if (length >= @as(f64, @floatFromInt(std.math.maxInt(usize)))) return std.math.maxInt(usize);
    return @intFromFloat(length);
}

pub fn toLengthNumber(ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, value: core.JSValue) !f64 {
    const primitive = try toPrimitiveForNumber(ctx, output, global, value);
    // JS_ToNumber on a bigint throws "cannot convert bigint to number".
    if (primitive.isBigInt()) {
        _ = throwTypeErrorMessage(ctx, global, "cannot convert bigint to number") catch |err| return err;
        return error.TypeError;
    }
    const number_value = try value_ops.toNumberValue(ctx.runtime, primitive);
    const number = value_ops.numberValue(number_value) orelse std.math.nan(f64);
    if (std.math.isNan(number) or number <= 0) return 0;
    const max_length = 9007199254740991.0;
    if (number >= max_length) return max_length;
    return @floor(number);
}

pub fn fastToLengthIndex(value: core.JSValue) ?usize {
    if (value.as(.int)) |int_value| {
        if (int_value <= 0) return 0;
        return @intCast(int_value);
    }
    if (value.as(.float64)) |number| {
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
    if (preserve_undefined and args[0].is(.undefined_value)) return null;
    const primitive = try toPrimitiveForNumber(ctx, output, global, args[0]);
    // JS_ToNumber on a bigint throws "cannot convert bigint to number".
    if (primitive.isBigInt()) {
        _ = throwTypeErrorMessage(ctx, global, "cannot convert bigint to number") catch |err| return err;
        return error.TypeError;
    }
    return try value_ops.toNumberValue(ctx.runtime, primitive);
}

/// The `[[PrimitiveValue]]` slot of a Number/Boolean/BigInt/Symbol wrapper, or
/// null for anything else. `rt` is unused (borrowed reads only) and is kept
/// only so the cross-file call sites keep their uniform `(rt, value)` shape.
pub fn primitiveWrapperStoredValue(rt: *core.JSRuntime, value: core.JSValue) ?core.JSValue {
    _ = rt;
    if (!value.is(.object)) return null;
    const object = core.value_semantics.objectFromValue(value) orelse return null;
    switch (object.class_id) {
        core.class.ids.number,
        core.class.ids.boolean,
        core.class.ids.big_int,
        core.class.ids.symbol,
        => if (object.objectData()) |stored| return stored else return null,
        else => return null,
    }
}

pub fn toNumberForDateMethod(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    if (value.is(.object)) {
        const primitive = try toPrimitiveForNumber(ctx, output, global, value);
        // JS_ToFloat64 on a bigint primitive throws "cannot convert bigint to
        // number"; qjs date argument coercion never accepts bigints.
        if (primitive.isBigInt()) {
            _ = throwTypeErrorMessage(ctx, global, "cannot convert bigint to number") catch |err| return err;
            return error.TypeError;
        }
        return value_ops.toNumberValue(ctx.runtime, primitive);
    }
    // Neither leg needs the caller frame today: `toPrimitiveForNumber` opens
    // its own native environment. The pair stays so the ~10 date_ops call
    // sites keep passing the frame they already hold.
    _ = caller_function;
    _ = caller_frame;
    if (value.isBigInt()) {
        _ = throwTypeErrorMessage(ctx, global, "cannot convert bigint to number") catch |err| return err;
        return error.TypeError;
    }
    return value_ops.toNumberValue(ctx.runtime, value);
}

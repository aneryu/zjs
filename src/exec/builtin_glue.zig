//! Native-record glue for Math, Number/BigInt, parseInt/parseFloat, URI, JSON and Date builtins,
//! plus collections (Map/Set), weak refs/FinalizationRegistry, Symbol registry and DataView.

const builtins = @import("../builtins/root.zig");
const call_mod = @import("call.zig");
const bytecode = @import("../bytecode/root.zig");
const collection_vm = @import("array_ops.zig");
const core = @import("../core/root.zig");
const date_vm = @import("date_ops.zig");
const frame_mod = @import("frame.zig");
const json_vm = @import("json_ops.zig");
const property_ops = @import("property_ops.zig");
const std = @import("std");
const value_ops = @import("value_ops.zig");

const call_runtime = @import("call_runtime.zig");
const coercion_ops = @import("coercion_ops.zig");
const object_ops = @import("object_ops.zig");
const string_ops = @import("string_ops.zig");

// Helpers that remain in call_runtime.zig (generic utilities outside the builtin
// glue cluster).
const callValueOrBytecode = call_runtime.callValueOrBytecode;
const constructCollectionWithPrototypeFromVm = object_ops.constructCollectionWithPrototypeFromVm;
const constructorNameEqlLocal = call_runtime.constructorNameEqlLocal;
const constructorPrototypeObject = object_ops.constructorPrototypeObject;
const functionPrototypeFromGlobal = object_ops.functionPrototypeFromGlobal;
const getIteratorMethod = call_runtime.getIteratorMethod;
const getValueProperty = object_ops.getValueProperty;
const isCallableValue = call_runtime.isCallableValue;
const iteratorCloseWithCompletionAndPropagate = call_runtime.iteratorCloseWithCompletionAndPropagate;
const iteratorStepValue = call_runtime.iteratorStepValue;
const lengthIndexValue = collection_vm.lengthIndexValue;
const objectFromValue = object_ops.objectFromValue;
const qjsArrayBufferAccessor = collection_vm.qjsArrayBufferAccessor;
const qjsArrayBufferIsView = collection_vm.qjsArrayBufferIsView;
const qjsArrayBufferPrototypeNativeRecord = collection_vm.qjsArrayBufferPrototypeNativeRecord;
const qjsSharedArrayBufferAccessor = collection_vm.qjsSharedArrayBufferAccessor;
const qjsTypedArrayAccessor = collection_vm.qjsTypedArrayAccessor;
const qjsTypedArrayConstructToIndex = collection_vm.qjsTypedArrayConstructToIndex;
const toPrimitiveForNumber = coercion_ops.toPrimitiveForNumber;
const toStringBytesForSymbol = string_ops.toStringBytesForSymbol;
const toStringForAnnexB = string_ops.toStringForAnnexB;
const toUint32Number = coercion_ops.toUint32Number;

pub fn qjsNumberFunctionCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
) !core.JSValue {
    const input = if (args.len >= 1) args[0] else return core.JSValue.int32(0);
    if (input.isBigInt()) return value_ops.numberToValue(try value_ops.bigIntToNumber(ctx.runtime, input));
    const primitive = try toPrimitiveForNumber(ctx, output, global, input);
    defer primitive.free(ctx.runtime);
    if (primitive.isBigInt()) return value_ops.numberToValue(try value_ops.bigIntToNumber(ctx.runtime, primitive));
    return value_ops.toNumberValue(ctx.runtime, primitive);
}

pub fn qjsBigIntFunctionCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
) !core.JSValue {
    const input = if (args.len >= 1) args[0] else core.JSValue.int32(0);
    const primitive = try toPrimitiveForNumber(ctx, output, global, input);
    defer primitive.free(ctx.runtime);
    if (primitive.asInt32()) |int_value| return value_ops.createBigIntI128(ctx.runtime, int_value);
    if (primitive.asFloat64()) |float_value| {
        return value_ops.integerNumberToBigIntValue(ctx.runtime, float_value);
    }
    var bigint = try value_ops.toBigIntValue(ctx.runtime, primitive);
    defer bigint.deinit();
    return value_ops.createBigIntValue(ctx.runtime, bigint);
}

pub fn qjsBigIntAsN(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    unsigned: bool,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    _ = caller_function;
    _ = caller_frame;
    const bits_input = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const bits_primitive = try toPrimitiveForNumber(ctx, output, global, bits_input);
    defer bits_primitive.free(ctx.runtime);
    if (bits_primitive.isBigInt() or bits_primitive.isSymbol()) return error.TypeError;
    const bits_number_value = try value_ops.toNumberValue(ctx.runtime, bits_primitive);
    defer bits_number_value.free(ctx.runtime);
    const bits_number = value_ops.numberValue(bits_number_value) orelse 0;
    const bits: usize = if (std.math.isNan(bits_number))
        0
    else blk: {
        if (!std.math.isFinite(bits_number)) return error.RangeError;
        const truncated = @trunc(bits_number);
        if (truncated < 0) return error.RangeError;
        if (truncated > 9007199254740991.0) return error.RangeError;
        break :blk @intFromFloat(truncated);
    };

    const bigint_input = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
    const bigint_primitive = try toPrimitiveForNumber(ctx, output, global, bigint_input);
    defer bigint_primitive.free(ctx.runtime);
    const bigint_value = try toBigIntFromPrimitive(ctx.runtime, bigint_primitive);
    defer bigint_value.free(ctx.runtime);
    return value_ops.asN(ctx.runtime, core.JSValue.float64(@floatFromInt(bits)), bigint_value, unsigned);
}

pub fn toBigIntFromPrimitive(rt: *core.JSRuntime, value: core.JSValue) !core.JSValue {
    if (value.isBigInt()) return value.dup();
    if (value.asBool()) |bool_value| return value_ops.createBigIntI128(rt, if (bool_value) 1 else 0);
    if (value.isString()) {
        var bigint = try value_ops.toBigIntValue(rt, value);
        defer bigint.deinit();
        return value_ops.createBigIntValue(rt, bigint);
    }
    return error.TypeError;
}

pub fn qjsGlobalIsNaNOrFinite(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    args: []const core.JSValue,
    is_nan: bool,
) !core.JSValue {
    if (objectFromValue(this_value)) |receiver| {
        if (try constructorNameEqlLocal(ctx.runtime, receiver, "Number")) {
            const value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
            const number = value_ops.numberValue(value);
            if (is_nan) return core.JSValue.boolean(value.isNumber() and std.math.isNan(number orelse std.math.nan(f64)));
            return core.JSValue.boolean(value.isNumber() and std.math.isFinite(number orelse std.math.nan(f64)));
        }
    }
    const input = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const primitive = try toPrimitiveForNumber(ctx, output, global, input);
    defer primitive.free(ctx.runtime);
    if (primitive.isSymbol() or primitive.isBigInt()) return error.TypeError;
    const number_value = try value_ops.toNumberValue(ctx.runtime, primitive);
    defer number_value.free(ctx.runtime);
    const number = value_ops.numberValue(number_value) orelse std.math.nan(f64);
    return core.JSValue.boolean(if (is_nan) std.math.isNan(number) else std.math.isFinite(number));
}

pub fn qjsUriCallForNativeRecord(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    mode: u32,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const input = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    if (input.isString()) {
        return builtins.uri.call(ctx.runtime, mode, input) catch |err| switch (err) {
            error.TypeError, error.URIError => err,
            else => err,
        };
    }
    const string_value = try toStringForAnnexB(ctx, output, global, input, caller_function, caller_frame);
    defer string_value.free(ctx.runtime);
    return builtins.uri.call(ctx.runtime, mode, string_value) catch |err| switch (err) {
        error.TypeError, error.URIError => err,
        else => err,
    };
}

pub fn qjsJsonCallForNativeRecord(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    id: u32,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const json_mod = builtins.json;
    return switch (id) {
        @intFromEnum(json_mod.StaticMethod.is_raw_json) => core.JSValue.boolean(args.len >= 1 and json_mod.isRawJSON(args[0])),
        @intFromEnum(json_mod.StaticMethod.raw_json) => {
            const value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
            return json_mod.rawJSON(ctx.runtime, value) catch |err| switch (err) {
                error.SyntaxError, error.TypeError => err,
                else => err,
            };
        },
        @intFromEnum(json_mod.StaticMethod.parse) => {
            if (try json_vm.qjsJsonParseCall(ctx, output, global, args, caller_function, caller_frame)) |value| return value;
            return error.TypeError;
        },
        @intFromEnum(json_mod.StaticMethod.stringify) => {
            if (try json_vm.qjsJsonStringifyCall(ctx, output, global, args, caller_function, caller_frame)) |value| return value;
            return error.TypeError;
        },
        else => error.TypeError,
    };
}

pub fn qjsDateToPrimitiveNativeRecord(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    return date_vm.qjsDateToPrimitiveCall(ctx, output, global, this_value, args, caller_function, caller_frame);
}

pub fn toNumberLikeArgument(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.JSValue,
) !core.JSValue {
    const primitive = try toPrimitiveForNumber(ctx, output, global, value);
    defer primitive.free(ctx.runtime);
    if (primitive.isBigInt()) return error.TypeError;
    const number_value = try value_ops.toNumberValue(ctx.runtime, primitive);
    defer number_value.free(ctx.runtime);
    return value_ops.numberToValue(value_ops.numberValue(number_value) orelse std.math.nan(f64));
}

pub fn qjsGlobalParseInt(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const input = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const string_value = if (input.isString())
        input
    else
        try toStringForAnnexB(ctx, output, global, input, caller_function, caller_frame);
    defer if (!input.isString()) string_value.free(ctx.runtime);

    const radix_value: ?core.JSValue = if (args.len >= 2) blk: {
        const radix_input = args[1];
        if (!radix_input.isObject() and !radix_input.isSymbol() and !radix_input.isBigInt()) break :blk radix_input;
        const primitive = try toPrimitiveForNumber(ctx, output, global, radix_input);
        defer primitive.free(ctx.runtime);
        const number_value = try value_ops.toNumberValue(ctx.runtime, primitive);
        defer number_value.free(ctx.runtime);
        break :blk value_ops.numberToValue(value_ops.numberValue(number_value) orelse std.math.nan(f64));
    } else null;
    return value_ops.numberToValue(try builtins.number.parseIntValue(ctx.runtime, string_value, radix_value));
}

pub fn qjsGlobalParseFloat(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const input = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const string_value = if (input.isString())
        input
    else
        try toStringForAnnexB(ctx, output, global, input, caller_function, caller_frame);
    defer if (!input.isString()) string_value.free(ctx.runtime);
    return value_ops.numberToValue(try builtins.number.parseFloatValue(ctx.runtime, string_value));
}

pub fn qjsMathCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    id: u32,
    args: []const core.JSValue,
) !core.JSValue {
    const number = switch (id) {
        1 => @abs(try mathArg(ctx, output, global, args, 0)),
        2 => @floor(try mathArg(ctx, output, global, args, 0)),
        3 => @ceil(try mathArg(ctx, output, global, args, 0)),
        4 => qjsMathRound(try mathArg(ctx, output, global, args, 0)),
        5 => @sqrt(try mathArg(ctx, output, global, args, 0)),
        6 => qjsMathPow(try mathArg(ctx, output, global, args, 0), try mathArg(ctx, output, global, args, 1)),
        7 => try qjsMathMinMax(ctx, output, global, args, false),
        8 => try qjsMathMinMax(ctx, output, global, args, true),
        9 => 0.5,
        10 => builtins.math.exp(try mathArg(ctx, output, global, args, 0)),
        11 => @sin(try mathArg(ctx, output, global, args, 0)),
        12 => @cos(try mathArg(ctx, output, global, args, 0)),
        13 => @tan(try mathArg(ctx, output, global, args, 0)),
        14 => std.math.acos(try mathArg(ctx, output, global, args, 0)),
        15 => std.math.asin(try mathArg(ctx, output, global, args, 0)),
        16 => std.math.atan(try mathArg(ctx, output, global, args, 0)),
        17 => std.math.atan2(try mathArg(ctx, output, global, args, 0), try mathArg(ctx, output, global, args, 1)),
        18 => std.math.acosh(try mathArg(ctx, output, global, args, 0)),
        19 => std.math.asinh(try mathArg(ctx, output, global, args, 0)),
        20 => std.math.atanh(try mathArg(ctx, output, global, args, 0)),
        21 => @log(try mathArg(ctx, output, global, args, 0)),
        22 => blk: {
            const a = try mathArg(ctx, output, global, args, 0);
            break :blk if (std.math.isNan(a) or a == 0 or !std.math.isFinite(a)) a else if (a < 0) -@floor(@abs(a)) else @floor(a);
        },
        23 => std.math.cbrt(try mathArg(ctx, output, global, args, 0)),
        24 => @as(f64, @floatFromInt(@clz(toUint32Number(try mathArg(ctx, output, global, args, 0))))),
        25 => std.math.cosh(try mathArg(ctx, output, global, args, 0)),
        26 => std.math.expm1(try mathArg(ctx, output, global, args, 0)),
        27 => @as(f64, @floatCast(@as(f16, @floatCast(try mathArg(ctx, output, global, args, 0))))),
        28 => @as(f64, @floatCast(@as(f32, @floatCast(try mathArg(ctx, output, global, args, 0))))),
        29 => try qjsMathHypot(ctx, output, global, args),
        30 => @as(f64, @floatFromInt(qjsMathImul(try mathArg(ctx, output, global, args, 0), try mathArg(ctx, output, global, args, 1)))),
        31 => std.math.log1p(try mathArg(ctx, output, global, args, 0)),
        32 => builtins.math.log2(try mathArg(ctx, output, global, args, 0)),
        33 => @log10(try mathArg(ctx, output, global, args, 0)),
        34 => qjsMathSign(try mathArg(ctx, output, global, args, 0)),
        35 => std.math.sinh(try mathArg(ctx, output, global, args, 0)),
        36 => std.math.tanh(try mathArg(ctx, output, global, args, 0)),
        else => return error.TypeError,
    };
    return value_ops.numberToValue(number);
}

pub fn mathArg(ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, args: []const core.JSValue, index: usize) !f64 {
    if (index >= args.len) return std.math.nan(f64);
    return toMathNumber(ctx, output, global, args[index]);
}

pub fn toMathNumber(ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, value: core.JSValue) !f64 {
    const primitive = try toPrimitiveForNumber(ctx, output, global, value);
    defer primitive.free(ctx.runtime);
    if (primitive.isBigInt()) return error.TypeError;
    const number_value = try value_ops.toNumberValue(ctx.runtime, primitive);
    defer number_value.free(ctx.runtime);
    return value_ops.numberValue(number_value) orelse std.math.nan(f64);
}

pub fn qjsMathMinMax(ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, args: []const core.JSValue, is_max: bool) !f64 {
    if (args.len == 2) {
        const a_val = args[0];
        const b_val = args[1];
        if (a_val.isInt() and b_val.isInt()) {
            const a_i32 = a_val.asInt32().?;
            const b_i32 = b_val.asInt32().?;
            if (a_i32 == 0 and b_i32 == 0) return 0.0;
            return @floatFromInt(if (is_max) (if (a_i32 > b_i32) a_i32 else b_i32) else (if (a_i32 < b_i32) a_i32 else b_i32));
        }
        if (a_val.isNumber() and b_val.isNumber()) {
            const a = qjsPrimitiveMathNumber(a_val).?;
            const b = qjsPrimitiveMathNumber(b_val).?;
            if (std.math.isNan(a)) return a;
            if (std.math.isNan(b)) return b;
            return if (is_max) qjsFmax(a, b) else qjsFmin(a, b);
        }
    }
    if (args.len == 0) return if (is_max) -std.math.inf(f64) else std.math.inf(f64);
    if (qjsMathMinMaxPrimitiveFast(args, is_max)) |fast| return fast;
    var result = try toMathNumber(ctx, output, global, args[0]);
    for (args[1..]) |arg| {
        const number = try toMathNumber(ctx, output, global, arg);
        if (!std.math.isNan(result)) {
            result = if (std.math.isNan(number))
                number
            else if (is_max)
                qjsFmax(result, number)
            else
                qjsFmin(result, number);
        }
    }
    return result;
}

pub fn qjsMathMinMaxPrimitiveFast(args: []const core.JSValue, is_max: bool) ?f64 {
    var result = if (is_max) -std.math.inf(f64) else std.math.inf(f64);
    for (args) |arg| {
        const number = qjsPrimitiveMathNumber(arg) orelse return null;
        if (!std.math.isNan(result)) {
            result = if (std.math.isNan(number))
                number
            else if (is_max)
                qjsFmax(result, number)
            else
                qjsFmin(result, number);
        }
    }
    return result;
}

pub fn qjsPrimitiveMathNumber(value: core.JSValue) ?f64 {
    if (value.isInt()) return @floatFromInt(value.asInt32().?);
    if (value.isFloat64()) return value.asFloat64().?;
    if (value.asBool()) |bool_value| return if (bool_value) 1 else 0;
    if (value.isNull()) return 0;
    if (value.isUndefined()) return std.math.nan(f64);
    return null;
}

pub fn qjsFmin(a: f64, b: f64) f64 {
    if (a == 0 and b == 0) return @bitCast(@as(u64, @bitCast(a)) | @as(u64, @bitCast(b)));
    return if (a < b) a else b;
}

pub fn qjsFmax(a: f64, b: f64) f64 {
    if (a == 0 and b == 0) return @bitCast(@as(u64, @bitCast(a)) & @as(u64, @bitCast(b)));
    return if (a < b) b else a;
}

pub fn qjsMathPow(a: f64, b: f64) f64 {
    if (!std.math.isFinite(b) and @abs(a) == 1) return std.math.nan(f64);
    return std.math.pow(f64, a, b);
}

pub fn qjsMathRound(a: f64) f64 {
    var bits: u64 = @bitCast(a);
    const exponent = (bits >> 52) & 0x7ff;
    if (exponent < 1023) {
        if (exponent == 1022 and bits != 0xbfe0000000000000) {
            bits = (bits & (@as(u64, 1) << 63)) | (@as(u64, 1023) << 52);
        } else {
            bits &= @as(u64, 1) << 63;
        }
    } else if (exponent < 1075) {
        const sign = bits >> 63;
        const one = @as(u64, 1) << @intCast(52 - (exponent - 1023));
        const frac_mask = one - 1;
        bits +%= (one >> 1) -% sign;
        bits &= ~frac_mask;
    }
    return @bitCast(bits);
}

pub fn qjsMathHypot(ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, args: []const core.JSValue) !f64 {
    if (args.len == 0) return 0;
    var result = try toMathNumber(ctx, output, global, args[0]);
    if (args.len == 1) return @abs(result);
    for (args[1..]) |arg| {
        const number = try toMathNumber(ctx, output, global, arg);
        result = std.math.hypot(result, number);
    }
    return result;
}

pub fn qjsMathImul(lhs: f64, rhs: f64) i32 {
    const product = toUint32Number(lhs) *% toUint32Number(rhs);
    return @bitCast(product);
}

pub fn qjsMathSign(value: f64) f64 {
    if (std.math.isNan(value) or value == 0) return value;
    return if (value < 0) -1 else 1;
}

pub fn qjsCollectionNativeRecord(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    function_object: *core.Object,
    id: u32,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    return collection_vm.qjsCollectionNativeRecord(ctx, output, global, this_value, function_object, id, args, caller_function, caller_frame);
}

pub fn qjsMapGroupByRecord(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    prototype: ?*core.Object,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    return collection_vm.qjsMapGroupByRecord(ctx, output, global, args, prototype, caller_function, caller_frame);
}

pub fn qjsBufferNativeRecord(
    ctx: *core.JSContext,
    receiver: core.JSValue,
    id: u32,
    args: []const core.JSValue,
) !?core.JSValue {
    if (id == @intFromEnum(builtins.buffer.StaticMethod.is_view)) return qjsArrayBufferIsView(args);
    if (builtins.buffer.arrayBufferAccessorNameFromRecordId(id)) |accessor_name| {
        return @as(?core.JSValue, try qjsArrayBufferAccessor(ctx, receiver, accessor_name));
    }
    if (builtins.buffer.sharedArrayBufferAccessorNameFromRecordId(id)) |accessor_name| {
        return @as(?core.JSValue, try qjsSharedArrayBufferAccessor(ctx, receiver, accessor_name));
    }
    if (builtins.buffer.dataViewAccessorNameFromRecordId(id)) |accessor_name| {
        return @as(?core.JSValue, try qjsDataViewAccessor(ctx, receiver, accessor_name));
    }
    if (builtins.buffer.typedArrayAccessorNameFromRecordId(id)) |accessor_name| {
        return @as(?core.JSValue, try qjsTypedArrayAccessor(ctx, receiver, accessor_name));
    }
    if (try qjsArrayBufferPrototypeNativeRecord(ctx, receiver, id, args)) |value| return value;
    if (builtins.buffer.dataViewGetKindFromRecordId(id)) |method_id| {
        const global = ctx.global orelse {
            const value = try (builtins.buffer.dataViewGet(ctx.runtime, receiver, method_id, args) catch |err| switch (err) {
                error.TypeError => error.TypeError,
                error.RangeError => error.RangeError,
                else => err,
            });
            return @as(?core.JSValue, value);
        };
        const value = try (qjsDataViewGet(ctx, null, global, receiver, method_id, args) catch |err| switch (err) {
            error.TypeError => error.TypeError,
            error.RangeError => error.RangeError,
            else => err,
        });
        return @as(?core.JSValue, value);
    }
    if (builtins.buffer.dataViewSetKindFromRecordId(id)) |method_id| {
        const global = ctx.global orelse {
            const value = try (builtins.buffer.dataViewSet(ctx.runtime, receiver, method_id, args) catch |err| switch (err) {
                error.TypeError => error.TypeError,
                error.RangeError => error.RangeError,
                else => err,
            });
            return @as(?core.JSValue, value);
        };
        const value = try (qjsDataViewSet(ctx, null, global, receiver, method_id, args) catch |err| switch (err) {
            error.TypeError => error.TypeError,
            error.RangeError => error.RangeError,
            else => err,
        });
        return @as(?core.JSValue, value);
    }
    return null;
}

pub const DataViewConstructorArgs = struct {
    byte_offset: usize,
    view_length: ?usize,
    has_offset: bool,
};

pub fn qjsDataViewConstructorArgs(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
) !DataViewConstructorArgs {
    if (args.len < 1) return error.TypeError;
    try builtins.buffer.dataViewRequireArrayBuffer(args[0]);
    const byte_offset = if (args.len >= 2)
        try qjsTypedArrayConstructToIndex(ctx, output, global, args[1])
    else
        @as(usize, 0);
    const view_length = if (args.len >= 3 and !args[2].isUndefined())
        try qjsTypedArrayConstructToIndex(ctx, output, global, args[2])
    else
        null;
    try builtins.buffer.dataViewValidateConstructorRange(ctx.runtime, args[0], byte_offset, view_length);
    return .{
        .byte_offset = byte_offset,
        .view_length = view_length,
        .has_offset = args.len >= 2,
    };
}

pub fn qjsDataViewAccessor(ctx: *core.JSContext, receiver: core.JSValue, accessor: []const u8) !core.JSValue {
    const object = objectFromValue(receiver) orelse return error.TypeError;
    if (object.class_id != core.class.ids.dataview) return error.TypeError;
    if (std.mem.eql(u8, accessor, "buffer")) {
        return (object.typedArrayBuffer() orelse return error.TypeError).dup();
    }
    if (std.mem.eql(u8, accessor, "byteLength")) {
        return core.JSValue.int32(@intCast(try builtins.buffer.dataViewByteLength(ctx.runtime, object)));
    }
    if (std.mem.eql(u8, accessor, "byteOffset")) {
        return core.JSValue.int32(@intCast(try builtins.buffer.dataViewByteOffset(ctx.runtime, object)));
    }
    return error.TypeError;
}

pub fn qjsDataViewGet(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    method_id: u32,
    args: []const core.JSValue,
) !core.JSValue {
    try builtins.buffer.dataViewRequire(receiver);
    const index_arg = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const index = try qjsTypedArrayConstructToIndex(ctx, output, global, index_arg);
    const little_endian = args.len >= 2 and value_ops.isTruthy(args[1]);
    const call_args = [_]core.JSValue{ lengthIndexValue(index), core.JSValue.boolean(little_endian) };
    return builtins.buffer.dataViewGet(ctx.runtime, receiver, method_id, call_args[0..]);
}

pub fn qjsDataViewSet(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    method_id: u32,
    args: []const core.JSValue,
) !core.JSValue {
    try builtins.buffer.dataViewRejectImmutable(ctx.runtime, receiver);
    const index_arg = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const index = try qjsTypedArrayConstructToIndex(ctx, output, global, index_arg);
    const value_arg = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
    const coerced_value = try qjsDataViewSetCoerceValue(ctx, output, global, method_id, value_arg);
    defer coerced_value.free(ctx.runtime);
    const little_endian = args.len >= 3 and value_ops.isTruthy(args[2]);
    const call_args = [_]core.JSValue{ lengthIndexValue(index), coerced_value, core.JSValue.boolean(little_endian) };
    return builtins.buffer.dataViewSet(ctx.runtime, receiver, method_id, call_args[0..]);
}

pub fn qjsDataViewSetCoerceValue(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    method_id: u32,
    value: core.JSValue,
) !core.JSValue {
    const primitive = try toPrimitiveForNumber(ctx, output, global, value);
    errdefer primitive.free(ctx.runtime);
    if (method_id == 9 or method_id == 10) return primitive;
    if (primitive.isBigInt()) return error.TypeError;
    const number_value = try value_ops.toNumberValue(ctx.runtime, primitive);
    primitive.free(ctx.runtime);
    return number_value;
}

pub fn qjsErrorIsError(args: []const core.JSValue) core.JSValue {
    if (args.len < 1) return core.JSValue.boolean(false);
    const object = objectFromValue(args[0]) orelse return core.JSValue.boolean(false);
    return core.JSValue.boolean(object.class_id == core.class.ids.error_);
}

pub fn qjsWeakRefDeref(rt: *core.JSRuntime, receiver: core.JSValue) !core.JSValue {
    const object = objectFromValue(receiver) orelse return error.TypeError;
    if (object.class_id != core.class.ids.weak_ref) return error.TypeError;
    return object.weakRefDeref(rt);
}

pub fn qjsFinalizationRegistryRegister(ctx: *core.JSContext, receiver: core.JSValue, args: []const core.JSValue) !core.JSValue {
    const object = objectFromValue(receiver) orelse return error.TypeError;
    if (object.class_id != core.class.ids.finalization_registry) return error.TypeError;
    const target = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const held_value = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
    const unregister_token = if (args.len >= 3) args[2] else core.JSValue.undefinedValue();
    if (!qjsCanBeHeldWeakly(ctx.runtime, target)) return error.TypeError;
    if (builtins.object.sameValue(target, held_value)) return error.TypeError;
    if (!unregister_token.isUndefined() and !qjsCanBeHeldWeakly(ctx.runtime, unregister_token)) return error.TypeError;
    if (builtins.object.sameValue(target, receiver)) return core.JSValue.undefinedValue();
    try qjsFinalizationRegistryAppendCell(ctx.runtime, object, target, held_value, unregister_token);
    return core.JSValue.undefinedValue();
}

pub fn qjsFinalizationRegistryUnregister(ctx: *core.JSContext, receiver: core.JSValue, args: []const core.JSValue) !core.JSValue {
    const object = objectFromValue(receiver) orelse return error.TypeError;
    if (object.class_id != core.class.ids.finalization_registry) return error.TypeError;
    const token = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    if (!qjsCanBeHeldWeakly(ctx.runtime, token)) return error.TypeError;
    return core.JSValue.boolean(object.unregisterFinalizationRegistryCells(ctx.runtime, token));
}

pub fn qjsFinalizationRegistryAppendCell(
    rt: *core.JSRuntime,
    object: *core.Object,
    target: core.JSValue,
    held_value: core.JSValue,
    unregister_token: core.JSValue,
) !void {
    try object.appendFinalizationRegistryCell(rt, target, held_value, unregister_token);
}

pub fn qjsCanBeHeldWeakly(rt: *core.JSRuntime, value: core.JSValue) bool {
    if (value.isObject()) return true;
    if (value.asSymbolAtom()) |atom_id| {
        return rt.atoms.kind(atom_id) == .symbol and builtins.symbol.registryKey(&rt.atoms, atom_id) == null;
    }
    return false;
}

pub fn qjsSymbolFor(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const key = if (args.len >= 1)
        try toStringBytesForSymbol(ctx, output, global, args[0], caller_function, caller_frame)
    else
        try ctx.runtime.memory.allocator.dupe(u8, "undefined");
    defer ctx.runtime.memory.allocator.free(key);

    const registered = try std.fmt.allocPrint(ctx.runtime.memory.allocator, "{s}{s}", .{ builtins.symbol.registry_prefix, key });
    defer ctx.runtime.memory.allocator.free(registered);
    const atom_id = try ctx.runtime.atoms.internRegisteredValueSymbol(registered);
    return core.JSValue.symbol(atom_id);
}

pub fn qjsSymbolKeyFor(rt: *core.JSRuntime, args: []const core.JSValue) !core.JSValue {
    const value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const atom_id = value.asSymbolAtom() orelse return error.TypeError;
    const key = builtins.symbol.registryKey(&rt.atoms, atom_id) orelse return core.JSValue.undefinedValue();
    return value_ops.createStringValue(rt, key);
}

pub fn qjsCreateBuiltinFunction(rt: *core.JSRuntime, global: *core.Object, name: []const u8, length: i32) !core.JSValue {
    const function = try builtins.function.nativeFunction(rt, name, length);
    errdefer function.free(rt);
    const object = objectFromValue(function) orelse return error.TypeError;
    try object.setFunctionRealmGlobalPtr(rt, global);
    if (functionPrototypeFromGlobal(rt, global)) |function_proto| {
        try object.setPrototype(rt, function_proto);
    }
    return function;
}

pub fn constructCollectionFromVm(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    constructor: core.JSValue,
    kind: u32,
    args: []const core.JSValue,
) !core.JSValue {
    const prototype = try constructorPrototypeObject(ctx.runtime, constructor);
    return constructCollectionWithPrototypeFromVm(ctx, output, global, kind, args, prototype);
}

pub fn addCollectionEntriesFromIterator(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    collection_value: core.JSValue,
    kind: u32,
    iterable_value: core.JSValue,
    adder: core.JSValue,
) !void {
    const iterator_method = try getIteratorMethod(ctx, output, global, iterable_value);
    defer iterator_method.free(ctx.runtime);
    if (!isCallableValue(iterator_method)) return error.TypeError;
    const iterator_value = try callValueOrBytecode(ctx, output, global, iterable_value, iterator_method, &.{}, null, null);
    defer iterator_value.free(ctx.runtime);
    _ = try property_ops.expectObject(iterator_value);

    while (true) {
        const step = iteratorStepValue(ctx, output, global, iterator_value) catch |err| {
            return iteratorCloseWithCompletionAndPropagate(ctx, output, global, iterator_value, err, null, null);
        };
        defer step.value.free(ctx.runtime);
        if (step.done) return;

        if (kind == 1 or kind == 3) {
            const entry = property_ops.expectObject(step.value) catch {
                return iteratorCloseWithCompletionAndPropagate(ctx, output, global, iterator_value, error.TypeError, null, null);
            };
            const key = getValueProperty(ctx, output, global, entry.value(), core.atom.atomFromUInt32(0), null, null) catch |err| {
                return iteratorCloseWithCompletionAndPropagate(ctx, output, global, iterator_value, err, null, null);
            };
            defer key.free(ctx.runtime);
            const value = getValueProperty(ctx, output, global, entry.value(), core.atom.atomFromUInt32(1), null, null) catch |err| {
                return iteratorCloseWithCompletionAndPropagate(ctx, output, global, iterator_value, err, null, null);
            };
            defer value.free(ctx.runtime);
            callCollectionAdderFromVm(ctx, output, global, collection_value, adder, &.{ key, value }) catch |err| {
                return iteratorCloseWithCompletionAndPropagate(ctx, output, global, iterator_value, err, null, null);
            };
        } else {
            callCollectionAdderFromVm(ctx, output, global, collection_value, adder, &.{step.value}) catch |err| {
                return iteratorCloseWithCompletionAndPropagate(ctx, output, global, iterator_value, err, null, null);
            };
        }
    }
}

pub fn callCollectionAdderFromVm(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    collection_value: core.JSValue,
    adder: core.JSValue,
    args: []const core.JSValue,
) !void {
    const out = try callValueOrBytecode(ctx, output, global, collection_value, adder, args, null, null);
    out.free(ctx.runtime);
}

// Host output fast-path probes (moved from the VM call runtime).

pub fn fastHostOutputCall(rt: *core.JSRuntime, output: ?*std.Io.Writer, func: core.JSValue, args: []const core.JSValue) !bool {
    const object = object_ops.objectFromValue(func) orelse return false;
    if (object.hostFunctionKind() != core.host_function.ids.output) return false;
    try printHostOutputArgs(rt, output, args);
    return true;
}

pub fn printHostOutputArgs(rt: *core.JSRuntime, output: ?*std.Io.Writer, args: []const core.JSValue) !void {
    if (output) |writer| {
        for (args, 0..) |arg, idx| {
            if (idx != 0) try writer.writeByte(' ');
            try call_mod.printValue(rt, writer, arg);
        }
        try writer.writeByte('\n');
    }
}

pub fn globalHostOutputAutoInit(rt: *core.JSRuntime, global: *core.Object, atom_id: core.Atom) bool {
    if (global.exotic != null) return false;
    for (global.shapeProps(), 0..) |prop, property_index| {
        const prop_flags = core.property.Flags.fromBits(prop.flags);
        if (prop_flags.deleted or prop.atom_id != atom_id) continue;
        if (prop_flags.accessor) return false;
        return switch (global.properties[property_index].slot) {
            .auto_init => |info| info.host_function_kind == core.host_function.ids.output or
                (info.host_function_kind == core.host_function.ids.external_host and
                    call_mod.isOutputExternalHostFunctionId(rt, info.external_host_function_id)),
            .data, .accessor, .deleted => false,
        };
    }
    return false;
}

// Realm slot and native-method helpers (moved from the VM call runtime).

pub fn functionConstructorFromGlobal(rt: *core.JSRuntime, global: *core.Object) ?*core.Object {
    if (global.getOwnDataObjectBorrowed(core.atom.ids.Function)) |constructor| return constructor;
    const function_value = global.getProperty(core.atom.ids.Function);
    defer function_value.free(rt);
    return property_ops.expectObject(function_value) catch null;
}

pub fn storeRealmValue(rt: *core.JSRuntime, global: *core.Object, slot: core.object.RealmValueSlot, value: core.JSValue) !void {
    const cached = try global.cachedRealmValueSlot(rt, slot);
    try global.setOptionalValueSlot(rt, cached, value.dup());
}

pub fn defineNativeDataMethod(rt: *core.JSRuntime, object: *core.Object, name: []const u8, length: i32) !void {
    const atom_id = try rt.internAtom(name);
    defer rt.atoms.free(atom_id);
    const method = try builtins.function.nativeFunction(rt, name, length);
    defer method.free(rt);
    try object.defineOwnProperty(rt, atom_id, core.Descriptor.data(method, true, false, true));
}

// --- Primitive coercion moved to coercion_ops.zig ---

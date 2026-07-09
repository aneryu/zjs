const core = @import("../core/root.zig");
const dtoa = @import("../libs/number_format.zig");
const std = @import("std");
const builtin_dispatch = @import("builtin_dispatch.zig");
const builtin_glue = @import("builtin_glue.zig");
const coercion_ops = @import("coercion_ops.zig");
const exceptions = @import("exceptions.zig");
const exception_ops = @import("vm_exception_ops.zig");
const object_ops = @import("object_ops.zig");
const value_ops = @import("value_ops.zig");

const HostError = exceptions.HostError;
const InternalCall = core.host_function.InternalCall;

/// Pure ASCII -> f64 parse primitives now live in `core/number.zig`; re-export
/// them here so the existing install/dispatch path keeps a single import
/// surface. The realm-coercing record handler (`numberCall`) and the
/// `Number.prototype.*` formatters below still own the VM-touching logic.
pub const parseIntValue = core.number.parseIntValue;
pub const parseFloatValue = core.number.parseFloatValue;
pub const parseIntLatin1Bytes = core.number.parseIntLatin1Bytes;
pub const parseFloatLatin1Bytes = core.number.parseFloatLatin1Bytes;

pub const StaticMethod = core.host_function.builtin_method_ids.number.StaticMethod;
pub const PrototypeMethod = core.host_function.builtin_method_ids.number.PrototypeMethod;

pub fn staticMethodId(name: []const u8) ?u32 {
    if (std.mem.eql(u8, name, "parseInt")) return @intFromEnum(StaticMethod.parse_int);
    if (std.mem.eql(u8, name, "parseFloat")) return @intFromEnum(StaticMethod.parse_float);
    if (std.mem.eql(u8, name, "isNaN")) return @intFromEnum(StaticMethod.is_nan);
    if (std.mem.eql(u8, name, "isFinite")) return @intFromEnum(StaticMethod.is_finite);
    if (std.mem.eql(u8, name, "isInteger")) return @intFromEnum(StaticMethod.is_integer);
    if (std.mem.eql(u8, name, "isSafeInteger")) return @intFromEnum(StaticMethod.is_safe_integer);
    return null;
}

pub fn prototypeMethodId(name: []const u8) ?u32 {
    if (std.mem.eql(u8, name, "toString")) return @intFromEnum(PrototypeMethod.to_string);
    if (std.mem.eql(u8, name, "toLocaleString")) return @intFromEnum(PrototypeMethod.to_locale_string);
    if (std.mem.eql(u8, name, "toFixed")) return @intFromEnum(PrototypeMethod.to_fixed);
    if (std.mem.eql(u8, name, "toExponential")) return @intFromEnum(PrototypeMethod.to_exponential);
    if (std.mem.eql(u8, name, "toPrecision")) return @intFromEnum(PrototypeMethod.to_precision);
    return null;
}

/// Declaration table: one entry per `Number.*` static, the four global
/// number functions, and the `Number.prototype.*` methods. `id` is the
/// `StaticMethod`/`PrototypeMethod` enum value, reused as the dispatch
/// `magic`. All share `numberCall`, which mirrors the legacy
/// `callNumberNativeFunctionRecord` dispatch. Static parse helpers and the
/// realm-coercing prototype/parse paths reach exec VM ops through
/// `builtin_glue`/`object_ops` (shared with the fast-call entry points);
/// bare-runtime parse callers use the primitive-only `parse*Value` fallback.
pub const internal_entries = [_]core.host_function.InternalEntry{
    .{ .name = "parseInt", .length = 2, .id = @intFromEnum(StaticMethod.parse_int), .magic = @intFromEnum(StaticMethod.parse_int), .prepared_call_ok = true, .call = &numberCall },
    .{ .name = "parseFloat", .length = 1, .id = @intFromEnum(StaticMethod.parse_float), .magic = @intFromEnum(StaticMethod.parse_float), .prepared_call_ok = true, .call = &numberCall },
    .{ .name = "isNaN", .length = 1, .id = @intFromEnum(StaticMethod.is_nan), .magic = @intFromEnum(StaticMethod.is_nan), .call = &numberCall },
    .{ .name = "isFinite", .length = 1, .id = @intFromEnum(StaticMethod.is_finite), .magic = @intFromEnum(StaticMethod.is_finite), .call = &numberCall },
    .{ .name = "isInteger", .length = 1, .id = @intFromEnum(StaticMethod.is_integer), .magic = @intFromEnum(StaticMethod.is_integer), .call = &numberCall },
    .{ .name = "isSafeInteger", .length = 1, .id = @intFromEnum(StaticMethod.is_safe_integer), .magic = @intFromEnum(StaticMethod.is_safe_integer), .call = &numberCall },
    .{ .name = "toString", .length = 1, .id = @intFromEnum(PrototypeMethod.to_string), .magic = @intFromEnum(PrototypeMethod.to_string), .call = &numberCall },
    .{ .name = "toLocaleString", .length = 0, .id = @intFromEnum(PrototypeMethod.to_locale_string), .magic = @intFromEnum(PrototypeMethod.to_locale_string), .call = &numberCall },
    .{ .name = "toFixed", .length = 1, .id = @intFromEnum(PrototypeMethod.to_fixed), .magic = @intFromEnum(PrototypeMethod.to_fixed), .call = &numberCall },
    .{ .name = "toExponential", .length = 1, .id = @intFromEnum(PrototypeMethod.to_exponential), .magic = @intFromEnum(PrototypeMethod.to_exponential), .call = &numberCall },
    .{ .name = "toPrecision", .length = 1, .id = @intFromEnum(PrototypeMethod.to_precision), .magic = @intFromEnum(PrototypeMethod.to_precision), .call = &numberCall },
};

/// Shared record handler for the `.number` domain. Replicates the legacy
/// `callNumberNativeFunctionRecord` dispatch verbatim: realm parse/predicate
/// and prototype methods take the VM-coercing exec ops, the bare-runtime
/// `parse*` fall back to the primitive-only path, and the integer predicates
/// stay self-contained.
fn numberCall(host_call: InternalCall) HostError!core.JSValue {
    const ctx = host_call.ctx;
    const id: u32 = host_call.magic;
    const args = host_call.args;
    const caller_function = builtin_dispatch.callerBytecode(host_call);
    const caller_frame = builtin_dispatch.callerFrame(host_call);
    return switch (id) {
        @intFromEnum(StaticMethod.parse_int) => {
            if (host_call.global) |global| return builtin_glue.qjsGlobalParseInt(ctx, host_call.output, global, args, caller_function, caller_frame);
            const input = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
            const radix = if (args.len >= 2) args[1] else null;
            return value_ops.numberToValue(try parseIntValue(ctx.runtime, input, radix));
        },
        @intFromEnum(StaticMethod.parse_float) => {
            if (host_call.global) |global| return builtin_glue.qjsGlobalParseFloat(ctx, host_call.output, global, args, caller_function, caller_frame);
            const input = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
            return value_ops.numberToValue(try parseFloatValue(ctx.runtime, input));
        },
        @intFromEnum(StaticMethod.is_nan) => {
            const global = host_call.global orelse return error.TypeError;
            return builtin_glue.qjsGlobalIsNaNOrFinite(ctx, host_call.output, global, host_call.this_value, args, true);
        },
        @intFromEnum(StaticMethod.is_finite) => {
            const global = host_call.global orelse return error.TypeError;
            return builtin_glue.qjsGlobalIsNaNOrFinite(ctx, host_call.output, global, host_call.this_value, args, false);
        },
        @intFromEnum(StaticMethod.is_integer) => {
            const value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
            return core.JSValue.boolean(numberIsInteger(value));
        },
        @intFromEnum(StaticMethod.is_safe_integer) => {
            const value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
            if (!numberIsInteger(value)) return core.JSValue.boolean(false);
            const number = value_ops.numberValue(value) orelse return core.JSValue.boolean(false);
            return core.JSValue.boolean(@abs(number) <= 9007199254740991.0);
        },
        @intFromEnum(PrototypeMethod.to_string),
        @intFromEnum(PrototypeMethod.to_locale_string),
        @intFromEnum(PrototypeMethod.to_fixed),
        @intFromEnum(PrototypeMethod.to_exponential),
        @intFromEnum(PrototypeMethod.to_precision),
        => {
            const global = host_call.global orelse return error.TypeError;
            return numberPrototypeMethod(ctx, host_call.output, global, host_call.this_value, id, args);
        },
        else => error.TypeError,
    };
}

/// `Number.prototype.{toString,toLocaleString,toFixed,toExponential,toPrecision}`
/// method body. Coerces the receiver to a number primitive and the optional
/// digits argument through the VM ToNumber path, then dispatches to the pure
/// formatters below; receiver/range failures map to the spec error messages.
/// `id` is a `PrototypeMethod` enum value. This is a builtin method body (it
/// reaches the VM coercion/exception ops), so exec routes here through the
/// record table (`object_ops.qjsNumberPrototypeMethod` ->
/// `builtin_dispatch.callInternalRecord`) instead of naming it directly.
fn numberPrototypeMethod(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    id: u32,
    args: []const core.JSValue,
) HostError!core.JSValue {
    const rt = ctx.runtime;
    const primitive = object_ops.primitivePrototypeThisValue(rt, this_value, 1) catch |err| switch (err) {
        error.TypeError => return exception_ops.throwTypeErrorMessage(ctx, global, "not a number"),
    };
    defer primitive.free(rt);
    const coerced_arg: ?core.JSValue = if (id == @intFromEnum(PrototypeMethod.to_locale_string))
        null
    else
        try coercion_ops.coerceOptionalNumberMethodArgument(ctx, output, global, args, true);
    defer if (coerced_arg) |value| value.free(rt);
    var coerced_storage: [1]core.JSValue = undefined;
    const method_args = if (coerced_arg) |value| blk: {
        coerced_storage[0] = value;
        break :blk coerced_storage[0..];
    } else args;
    return (switch (id) {
        @intFromEnum(PrototypeMethod.to_string) => toStringMethod(rt, primitive, method_args),
        @intFromEnum(PrototypeMethod.to_locale_string) => toStringMethod(rt, primitive, &.{}),
        @intFromEnum(PrototypeMethod.to_fixed) => toFixed(rt, primitive, method_args),
        @intFromEnum(PrototypeMethod.to_exponential) => toExponential(rt, primitive, method_args),
        @intFromEnum(PrototypeMethod.to_precision) => toPrecision(rt, primitive, method_args),
        else => error.TypeError,
    }) catch |err| switch (err) {
        error.TypeError => return exception_ops.throwTypeErrorMessage(ctx, global, "not a number"),
        error.InvalidRadix => return exception_ops.throwRangeErrorMessage(ctx, global, "radix must be between 2 and 36"),
        error.RangeError => return exception_ops.throwRangeErrorMessage(ctx, global, "invalid number of digits"),
        else => err,
    };
}

fn numberIsInteger(value: core.JSValue) bool {
    const number = value_ops.numberValue(value) orelse return false;
    return std.math.isFinite(number) and @floor(number) == number;
}

pub fn parseFloat(bytes: []const u8) !f64 {
    return dtoa.parseNumber(bytes);
}

pub fn toString(buf: []u8, value: f64) ![]const u8 {
    return dtoa.formatNumber(buf, value);
}

pub fn toFixed(rt: *core.JSRuntime, receiver: core.JSValue, args: []const core.JSValue) !core.JSValue {
    const number = core.number.numberValue(receiver) orelse return error.TypeError;
    const fraction_digits = try integerDigitsArgument(rt, args, 0);
    if (fraction_digits < 0 or fraction_digits > 100) return error.RangeError;

    const flags = if (@abs(number) >= 1e21) dtoa.JS_DTOA_FORMAT_FREE else dtoa.JS_DTOA_FORMAT_FRAC;
    return dtoaStringValue(rt, number, fraction_digits, flags);
}

pub fn toExponential(rt: *core.JSRuntime, receiver: core.JSValue, args: []const core.JSValue) !core.JSValue {
    const number = core.number.numberValue(receiver) orelse return error.TypeError;
    const fraction_arg_undefined = args.len == 0 or args[0].isUndefined();
    var fraction_digits = try integerDigitsArgument(rt, args, 0);
    if (std.math.isNan(number) or !std.math.isFinite(number)) return numberStringValue(rt, number);
    const flags = if (fraction_arg_undefined) flags: {
        fraction_digits = 0;
        break :flags dtoa.JS_DTOA_FORMAT_FREE;
    } else flags: {
        if (fraction_digits < 0 or fraction_digits > 100) return error.RangeError;
        fraction_digits += 1;
        break :flags dtoa.JS_DTOA_FORMAT_FIXED;
    };
    return dtoaStringValue(rt, number, fraction_digits, flags | dtoa.JS_DTOA_EXP_ENABLED);
}

pub fn toPrecision(rt: *core.JSRuntime, receiver: core.JSValue, args: []const core.JSValue) !core.JSValue {
    const number = core.number.numberValue(receiver) orelse return error.TypeError;
    if (args.len == 0 or args[0].isUndefined()) return numberStringValue(rt, number);
    const precision = try integerDigitsArgument(rt, args, 0);
    if (std.math.isNan(number) or !std.math.isFinite(number)) return numberStringValue(rt, number);
    if (precision < 1 or precision > 100) return error.RangeError;
    return dtoaStringValue(rt, number, precision, dtoa.JS_DTOA_FORMAT_FIXED);
}

pub fn toStringMethod(rt: *core.JSRuntime, receiver: core.JSValue, args: []const core.JSValue) !core.JSValue {
    const number = core.number.numberValue(receiver) orelse return error.TypeError;
    const radix = if (args.len >= 1 and !args[0].isUndefined())
        @as(i32, @intFromFloat(try core.number.toNumber(rt, args[0])))
    else
        10;
    if (radix < 2 or radix > 36) return error.InvalidRadix;

    if (radix == 10 or !std.math.isFinite(number) or std.math.isNan(number)) {
        var buffer: [64]u8 = undefined;
        const text = try toString(&buffer, number);
        const string = try core.string.String.createAscii(rt, text);
        return string.value();
    }

    var out = std.ArrayList(u8).empty;
    defer out.deinit(rt.memory.allocator);
    try appendRadixInteger(rt, &out, number, @intCast(radix));
    const string = try core.string.String.createAscii(rt, out.items);
    return string.value();
}

fn numberStringValue(rt: *core.JSRuntime, number: f64) !core.JSValue {
    var buffer: [64]u8 = undefined;
    const text = try toString(&buffer, number);
    const string = try core.string.String.createAscii(rt, text);
    return string.value();
}

fn dtoaStringValue(rt: *core.JSRuntime, number: f64, n_digits: i32, flags: i32) !core.JSValue {
    var buffer: [768]u8 = undefined;
    const text = try dtoa.formatDtoaChecked(&buffer, number, n_digits, flags);
    const string = try core.string.String.createAscii(rt, text);
    return string.value();
}

fn integerDigitsArgument(rt: *core.JSRuntime, args: []const core.JSValue, default: i32) !i32 {
    if (args.len == 0 or args[0].isUndefined()) return default;
    if (args[0].isSymbol() or args[0].isBigInt()) return error.TypeError;
    const number = try core.number.toNumber(rt, args[0]);
    if (std.math.isNan(number) or number == 0) return 0;
    if (!std.math.isFinite(number)) return if (number < 0) std.math.minInt(i32) else std.math.maxInt(i32);
    const truncated = @trunc(number);
    if (truncated <= @as(f64, @floatFromInt(std.math.minInt(i32)))) return std.math.minInt(i32);
    if (truncated >= @as(f64, @floatFromInt(std.math.maxInt(i32)))) return std.math.maxInt(i32);
    return @intFromFloat(truncated);
}

const radix_digit_chars = "0123456789abcdefghijklmnopqrstuvwxyz";

/// Unbiased exponent minus mantissa width: > 0 means the double's unit in the
/// last place exceeds 1, i.e. successive integers are no longer representable.
fn radixDoubleExponent(value: f64) i32 {
    const bits: u64 = @bitCast(value);
    const biased: i32 = @intCast((bits >> 52) & 0x7ff);
    return biased - 1075;
}

/// Free-format radix conversion for Number.prototype.toString(radix != 10)
/// (qjs js_number_toString -> js_dtoa2(d, base, 0, JS_DTOA_FORMAT_FREE |
/// JS_DTOA_EXP_DISABLED), quickjs.c:44989). Delta-terminated shortest digit
/// generation: fractional digits emit until the remaining fraction is within
/// half an ulp of the source value (with round-half-even and carry
/// propagation into the integer part), and integer digits are produced
/// exactly for the whole double range (no more >= 2^128 @intFromFloat).
/// Output parity with qjs is enforced by the dual-engine fuzz suite.
fn appendRadixInteger(rt: *core.JSRuntime, out: *std.ArrayList(u8), number: f64, radix: u8) !void {
    if (std.math.isNan(number)) {
        try out.appendSlice(rt.memory.allocator, "NaN");
        return;
    }
    if (!std.math.isFinite(number)) {
        try out.appendSlice(rt.memory.allocator, if (number < 0) "-Infinity" else "Infinity");
        return;
    }
    if (number == 0) {
        try out.append(rt.memory.allocator, '0');
        return;
    }
    var value = number;
    if (value < 0) {
        try out.append(rt.memory.allocator, '-');
        value = -value;
    }
    const radix_f: f64 = @floatFromInt(radix);

    var integer_part = @floor(value);
    var fraction = value - integer_part;
    // Half the distance to the next representable double; floor at the
    // smallest subnormal so the loop always terminates.
    const value_bits: u64 = @bitCast(value);
    const next_up: f64 = @bitCast(value_bits + 1);
    var delta: f64 = 0.5 * (next_up - value);
    const min_subnormal: f64 = @bitCast(@as(u64, 1));
    if (delta < min_subnormal) delta = min_subnormal;

    var fraction_buf: [1200]u8 = undefined;
    var fraction_len: usize = 0;
    if (fraction >= delta) {
        while (true) {
            fraction *= radix_f;
            delta *= radix_f;
            var digit: usize = @intFromFloat(fraction);
            fraction -= @as(f64, @floatFromInt(digit));
            fraction_buf[fraction_len] = radix_digit_chars[digit];
            fraction_len += 1;
            var rounded_up = false;
            if (fraction > 0.5 or (fraction == 0.5 and (digit & 1) == 1)) {
                if (fraction + delta > 1.0) {
                    // Round up the tail, carrying into the integer part when
                    // every fractional digit overflows.
                    while (true) {
                        if (fraction_len == 0) {
                            integer_part += 1;
                            break;
                        }
                        fraction_len -= 1;
                        const c = fraction_buf[fraction_len];
                        digit = if (c > '9') c - 'a' + 10 else c - '0';
                        if (digit + 1 < radix) {
                            fraction_buf[fraction_len] = radix_digit_chars[digit + 1];
                            fraction_len += 1;
                            break;
                        }
                    }
                    rounded_up = true;
                }
            }
            if (rounded_up or fraction < delta) break;
        }
    }

    var integer_buf: [1200]u8 = undefined;
    var integer_cursor: usize = integer_buf.len;
    // Digits below the double's precision are exact zeros.
    while (radixDoubleExponent(integer_part / radix_f) > 0) {
        integer_part /= radix_f;
        integer_cursor -= 1;
        integer_buf[integer_cursor] = '0';
    }
    while (true) {
        const remainder = @rem(integer_part, radix_f);
        integer_cursor -= 1;
        integer_buf[integer_cursor] = radix_digit_chars[@intFromFloat(remainder)];
        integer_part = (integer_part - remainder) / radix_f;
        if (integer_part <= 0) break;
    }
    try out.appendSlice(rt.memory.allocator, integer_buf[integer_cursor..]);
    if (fraction_len != 0) {
        try out.append(rt.memory.allocator, '.');
        try out.appendSlice(rt.memory.allocator, fraction_buf[0..fraction_len]);
    }
}

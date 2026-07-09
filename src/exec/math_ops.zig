//! QuickJS source map: js_math_obj / js_math_funcs in quickjs.c. Implementation
//! and declaration table live side by side, matching QuickJS's
//! JSCFunctionListEntry pattern. The transitional builtins installer consumes
//! `internal_entries` until standard-global installation moves fully into exec.

const core = @import("../core/root.zig");
const std = @import("std");
const bignum = @import("../libs/bigint.zig");
const builtin_dispatch = @import("builtin_dispatch.zig");
const call_runtime = @import("call_runtime.zig");
const coercion_ops = @import("coercion_ops.zig");
const exception_ops = @import("vm_exception_ops.zig");
const exceptions = @import("exceptions.zig");
const value_ops = @import("value_ops.zig");

const HostError = exceptions.HostError;
const InternalCall = core.host_function.InternalCall;
const toPrimitiveForNumber = coercion_ops.toPrimitiveForNumber;
const toUint32Number = coercion_ops.toUint32Number;

pub const PI = std.math.pi;
pub const E = std.math.e;
pub const LN10 = std.math.ln10;
pub const LN2 = std.math.ln2;
pub const LOG2E = std.math.log2e;
pub const LOG10E = std.math.log10e;
pub const SQRT1_2 = std.math.sqrt1_2;
pub const SQRT2 = std.math.sqrt2;

pub const sum_precise_method_id: u32 = 37;

/// Declaration table: one entry per `Math.*` method. `id` doubles as the
/// dispatch `magic` for the shared numeric handler (QuickJS uses the same
/// magic pattern for its js_math_op entries). Entry order is the namespace
/// property definition order (kept from the legacy registry table).
pub const internal_entries = [_]core.host_function.InternalEntry{
    mathOpEntry("min", 2, 7),
    mathOpEntry("max", 2, 8),
    mathOpEntry("abs", 1, 1),
    mathOpEntry("floor", 1, 2),
    mathOpEntry("ceil", 1, 3),
    mathOpEntry("round", 1, 4),
    mathOpEntry("sqrt", 1, 5),
    mathOpEntry("acos", 1, 14),
    mathOpEntry("asin", 1, 15),
    mathOpEntry("atan", 1, 16),
    mathOpEntry("atan2", 2, 17),
    mathOpEntry("cos", 1, 12),
    mathOpEntry("exp", 1, 10),
    mathOpEntry("log", 1, 21),
    mathOpEntry("pow", 2, 6),
    mathOpEntry("sin", 1, 11),
    mathOpEntry("tan", 1, 13),
    mathOpEntry("trunc", 1, 22),
    mathOpEntry("sign", 1, 34),
    mathOpEntry("cosh", 1, 25),
    mathOpEntry("sinh", 1, 35),
    mathOpEntry("tanh", 1, 36),
    mathOpEntry("acosh", 1, 18),
    mathOpEntry("asinh", 1, 19),
    mathOpEntry("atanh", 1, 20),
    mathOpEntry("expm1", 1, 26),
    mathOpEntry("log1p", 1, 31),
    mathOpEntry("log2", 1, 32),
    mathOpEntry("log10", 1, 33),
    mathOpEntry("cbrt", 1, 23),
    mathOpEntry("hypot", 2, 29),
    mathOpEntry("random", 0, 9),
    mathOpEntry("f16round", 1, 27),
    mathOpEntry("fround", 1, 28),
    mathOpEntry("imul", 2, 30),
    mathOpEntry("clz32", 1, 24),
    .{ .name = "sumPrecise", .length = 1, .id = sum_precise_method_id, .prepared_call_ok = true, .call = &mathSumPreciseCall },
};

fn mathOpEntry(comptime name: []const u8, comptime length: u8, comptime id: u32) core.host_function.InternalEntry {
    return .{ .name = name, .length = length, .id = id, .magic = id, .prepared_call_ok = true, .call = &mathOpCall };
}

/// Shared record handler for the numeric `Math.*` methods (ids 1..36).
/// With a realm global the arguments take the full spec ToNumber coercion
/// path; without one (bare-runtime callers) the primitive-only `call`
/// fallback below preserves the legacy host-path behavior.
/// qjs `xorshift64star` (quickjs.c:47362).
fn xorshift64star(state: *u64) u64 {
    var x = state.*;
    x ^= x >> 12;
    x ^= x << 25;
    x ^= x >> 27;
    state.* = x;
    return x *% 0x2545F4914F6CDD1D;
}

/// qjs `js_math_random` (quickjs.c:47383): advance the per-runtime xorshift
/// state and pack the top 52 bits into a [1.0, 2.0) double, returning d - 1.
fn mathRandom(rt: *core.JSRuntime) f64 {
    const v = xorshift64star(&rt.random_state);
    const bits: u64 = (@as(u64, 0x3ff) << 52) | (v >> 12);
    return @as(f64, @bitCast(bits)) - 1.0;
}

fn mathOpCall(host_call: InternalCall) HostError!core.JSValue {
    if (host_call.global == null) {
        if (host_call.magic == 9) return value_ops.numberToValue(mathRandom(host_call.ctx.runtime));
        const number = call(host_call.magic, host_call.args) catch return error.TypeError;
        return value_ops.numberToValue(number);
    }
    return preparedOpCall(host_call.ctx, host_call.output, host_call.global.?, host_call.magic, host_call.args);
}

/// Realm-path scalar `Math.*` computation (ids 1..36), shared by the record
/// handler (`mathOpCall`) and the VM prepared-call fast path
/// (`vm_call.callPreparedNativeTarget`). The prepared path calls this directly
/// rather than through the record table's function pointer: the indirect call
/// and table lookup measurably regress the hottest tight-loop scalar math
/// (Math.abs/sqrt/floor) by ~5%, so this is the documented hybrid: Math keeps
/// a specialized prepared branch while every other migrated domain unifies on
/// the table. Always invoked with a realm `global`; the bare-runtime fallback
/// stays in `mathOpCall`.
pub fn preparedOpCall(ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, id: u32, args: []const core.JSValue) HostError!core.JSValue {
    const number = switch (id) {
        1 => @abs(try mathArg(ctx, output, global, args, 0)),
        2 => @floor(try mathArg(ctx, output, global, args, 0)),
        3 => @ceil(try mathArg(ctx, output, global, args, 0)),
        4 => qjsMathRound(try mathArg(ctx, output, global, args, 0)),
        5 => @sqrt(try mathArg(ctx, output, global, args, 0)),
        6 => qjsMathPow(try mathArg(ctx, output, global, args, 0), try mathArg(ctx, output, global, args, 1)),
        7 => try qjsMathMinMax(ctx, output, global, args, false),
        8 => try qjsMathMinMax(ctx, output, global, args, true),
        9 => mathRandom(ctx.runtime),
        10 => exp(try mathArg(ctx, output, global, args, 0)),
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
        32 => log2(try mathArg(ctx, output, global, args, 0)),
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
    if (primitive.isBigInt()) {
        _ = exception_ops.throwTypeErrorMessage(ctx, global, "cannot convert bigint to number") catch |err| return err;
        return error.TypeError;
    }
    if (primitive.isSymbol()) {
        _ = exception_ops.throwTypeErrorMessage(ctx, global, "cannot convert symbol to number") catch |err| return err;
        return error.TypeError;
    }
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
        const sign_bit = bits >> 63;
        const one = @as(u64, 1) << @intCast(52 - (exponent - 1023));
        const frac_mask = one - 1;
        bits +%= (one >> 1) -% sign_bit;
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

// --- Math.sumPrecise ---------------------------------------------------------

fn mathSumPreciseCall(host_call: InternalCall) HostError!core.JSValue {
    const global = host_call.global orelse return error.TypeError;
    return qjsMathSumPrecise(
        host_call.ctx,
        host_call.output,
        global,
        host_call.args,
        builtin_dispatch.callerBytecode(host_call),
        builtin_dispatch.callerFrame(host_call),
    );
}

pub fn qjsMathSumPrecise(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const builtin_dispatch.Bytecode,
    caller_frame: ?*builtin_dispatch.Frame,
) HostError!core.JSValue {
    if (args.len < 1) return exception_ops.throwTypeErrorMessage(ctx, global, "cannot read property 'Symbol.iterator' of undefined");
    const iterator_value = try call_runtime.iteratorForValue(ctx, output, global, args[0], caller_function, caller_frame);
    defer iterator_value.free(ctx.runtime);

    var finite_values = std.ArrayList(f64).empty;
    defer finite_values.deinit(ctx.runtime.memory.allocator);
    var saw_nan = false;
    var saw_positive_inf = false;
    var saw_negative_inf = false;
    var saw_positive_zero = false;
    var saw_negative_zero = false;

    while (true) {
        const step = try call_runtime.iteratorStepValue(ctx, output, global, iterator_value);
        defer step.value.free(ctx.runtime);
        if (step.done) break;
        const number = value_ops.numberValue(step.value) orelse {
            try call_runtime.qjsIteratorClose(ctx, output, global, iterator_value, caller_function, caller_frame);
            return exception_ops.throwTypeErrorMessage(ctx, global, "not a number");
        };
        if (std.math.isNan(number)) {
            saw_nan = true;
        } else if (std.math.isPositiveInf(number)) {
            saw_positive_inf = true;
        } else if (std.math.isNegativeInf(number)) {
            saw_negative_inf = true;
        } else if (number == 0) {
            if (std.math.isNegativeZero(number)) {
                saw_negative_zero = true;
            } else {
                saw_positive_zero = true;
            }
        } else {
            try finite_values.append(ctx.runtime.memory.allocator, number);
        }
    }

    if (saw_nan or (saw_positive_inf and saw_negative_inf)) return core.JSValue.float64(std.math.nan(f64));
    if (saw_positive_inf) return core.JSValue.float64(std.math.inf(f64));
    if (saw_negative_inf) return core.JSValue.float64(-std.math.inf(f64));
    if (finite_values.items.len == 0) {
        return if (saw_positive_zero) core.JSValue.int32(0) else core.JSValue.float64(-0.0);
    }

    const rounded = try exactF64Sum(ctx.runtime.memory.allocator, finite_values.items);
    if (rounded == 0 and !saw_positive_zero and saw_negative_zero) return core.JSValue.float64(-0.0);
    return value_ops.numberToValue(rounded);
}

pub fn exactF64Sum(allocator: std.mem.Allocator, values: []const f64) !f64 {
    var total = bignum.BigInt{ .allocator = allocator };
    defer total.deinit();

    for (values) |number| {
        var term = try exactF64ScaledInteger(allocator, number);
        defer term.deinit();
        const next = try total.add(term);
        total.deinit();
        total = next;
    }

    return try scaledIntegerToF64(allocator, total);
}

pub fn exactF64ScaledInteger(allocator: std.mem.Allocator, number: f64) !bignum.BigInt {
    const bits: u64 = @bitCast(number);
    const sign_bit = (bits >> 63) != 0;
    const exponent_bits: u16 = @intCast((bits >> 52) & 0x7ff);
    const fraction = bits & ((@as(u64, 1) << 52) - 1);
    const mantissa: u64 = if (exponent_bits == 0) fraction else ((@as(u64, 1) << 52) | fraction);
    const exponent: i32 = if (exponent_bits == 0) -1074 else @as(i32, exponent_bits) - 1023 - 52;
    var base = try bignum.BigInt.fromIntAlloc(allocator, if (sign_bit) -@as(i128, @intCast(mantissa)) else @as(i128, @intCast(mantissa)));
    if (mantissa == 0) return base;
    const shift: usize = @intCast(exponent + 1074);
    const shifted = try base.shl(allocator, shift);
    base.deinit();
    return shifted;
}

pub fn scaledIntegerToF64(allocator: std.mem.Allocator, value: bignum.BigInt) !f64 {
    if (value.isZero()) return 0;
    var magnitude = try value.cloneWithAllocator(allocator);
    defer magnitude.deinit();
    const negative = magnitude.negative;
    magnitude.negative = false;

    const bit_len = magnitude.bitLengthAbs();
    if (bit_len <= 52) {
        const fraction: u64 = @intCast(magnitude.toUsize() orelse return error.TypeError);
        const bits = (@as(u64, @intFromBool(negative)) << 63) | fraction;
        return @bitCast(bits);
    }

    var exponent = @as(i32, @intCast(bit_len - 1)) - 1074;
    if (exponent > 1023) return if (negative) -std.math.inf(f64) else std.math.inf(f64);

    const shift = bit_len - 53;
    var top_int = if (shift == 0)
        try magnitude.cloneWithAllocator(allocator)
    else
        try magnitude.shr(allocator, shift);
    defer top_int.deinit();
    var significand: u64 = @intCast(top_int.toUsize() orelse return error.TypeError);

    if (shift > 0 and shouldRoundScaledIntegerUp(magnitude, shift, significand)) {
        significand += 1;
        if (significand == (@as(u64, 1) << 53)) {
            significand >>= 1;
            exponent += 1;
            if (exponent > 1023) return if (negative) -std.math.inf(f64) else std.math.inf(f64);
        }
    }

    const exponent_bits: u64 = @intCast(exponent + 1023);
    const fraction = significand & ((@as(u64, 1) << 52) - 1);
    const bits = (@as(u64, @intFromBool(negative)) << 63) | (exponent_bits << 52) | fraction;
    return @bitCast(bits);
}

pub fn shouldRoundScaledIntegerUp(magnitude: bignum.BigInt, shift: usize, significand: u64) bool {
    if (!magnitude.testBit(shift - 1)) return false;
    if ((significand & 1) != 0) return true;
    var bit: usize = 0;
    while (bit + 1 < shift) : (bit += 1) {
        if (magnitude.testBit(bit)) return true;
    }
    return false;
}

// --- Primitive-only fallback (no-realm callers) ------------------------------

/// QuickJS source map: Math builtin functions in quickjs.c. Primitive-only
/// argument handling used when no realm global is available (host callers on
/// bare runtimes); the record handler above owns the full coercion path.
pub fn call(id: u32, args: []const core.JSValue) !f64 {
    const missing = std.math.nan(f64);
    const a = if (args.len >= 1) try numberValue(args[0]) else missing;
    const b = if (args.len >= 2) try numberValue(args[1]) else missing;
    return switch (id) {
        1 => @abs(a),
        2 => @floor(a),
        3 => @ceil(a),
        4 => @floor(a + 0.5),
        5 => @sqrt(a),
        6 => std.math.pow(f64, a, b),
        7 => min(args),
        8 => maxSlice(args),
        9 => 0.5,
        10 => exp(a),
        11 => @sin(a),
        12 => @cos(a),
        13 => @tan(a),
        14 => std.math.acos(a),
        15 => std.math.asin(a),
        16 => std.math.atan(a),
        17 => std.math.atan2(a, b),
        18 => std.math.acosh(a),
        19 => std.math.asinh(a),
        20 => std.math.atanh(a),
        21 => @log(a),
        22 => if (std.math.isNan(a) or a == 0 or !std.math.isFinite(a)) a else if (a < 0) -@floor(@abs(a)) else @floor(a),
        23 => std.math.cbrt(a),
        24 => @floatFromInt(@clz(toUint32(a))),
        25 => std.math.cosh(a),
        26 => std.math.expm1(a),
        27 => @floatCast(@as(f16, @floatCast(a))),
        28 => @floatCast(@as(f32, @floatCast(a))),
        29 => hypot(args),
        30 => @floatFromInt(imul(a, b)),
        31 => std.math.log1p(a),
        32 => log2(a),
        33 => @log10(a),
        34 => sign(a),
        35 => std.math.sinh(a),
        36 => std.math.tanh(a),
        else => error.TypeError,
    };
}

pub fn abs(value: f64) f64 {
    return @abs(value);
}

pub fn exp(value: f64) f64 {
    if (value == 1) return E;
    if (value == -1) return 1.0 / E;
    return @exp(value);
}

pub fn log2(value: f64) f64 {
    if (exactPowerOfTwoExponent(value)) |exponent| return @floatFromInt(exponent);
    return @log2(value);
}

pub fn max(a: f64, b: f64) f64 {
    return if (a > b) a else b;
}

fn min(args: []const core.JSValue) !f64 {
    var out = std.math.inf(f64);
    for (args) |arg| out = @min(out, try numberValue(arg));
    return out;
}

fn maxSlice(args: []const core.JSValue) !f64 {
    var out = -std.math.inf(f64);
    for (args) |arg| out = @max(out, try numberValue(arg));
    return out;
}

fn hypot(args: []const core.JSValue) !f64 {
    var sum: f64 = 0;
    for (args) |arg| {
        const number = try numberValue(arg);
        if (std.math.isInf(number)) return std.math.inf(f64);
        if (std.math.isNan(number)) return std.math.nan(f64);
        sum += number * number;
    }
    return @sqrt(sum);
}

fn imul(lhs: f64, rhs: f64) i32 {
    const a = toUint32(lhs);
    const b = toUint32(rhs);
    const product = a *% b;
    return @bitCast(product);
}

fn sign(value: f64) f64 {
    if (std.math.isNan(value) or value == 0) return value;
    return if (value < 0) -1 else 1;
}

fn exactPowerOfTwoExponent(value: f64) ?i32 {
    if (value <= 0 or !std.math.isFinite(value)) return null;
    const bits: u64 = @bitCast(value);
    const exponent_bits = (bits >> 52) & 0x7ff;
    const fraction = bits & ((@as(u64, 1) << 52) - 1);
    if (exponent_bits == 0) {
        if (fraction == 0 or (fraction & (fraction - 1)) != 0) return null;
        const bit_index: i32 = @intCast(@ctz(fraction));
        return bit_index - 1074;
    }
    if (fraction != 0) return null;
    return @as(i32, @intCast(exponent_bits)) - 1023;
}

fn toUint32(value: f64) u32 {
    if (std.math.isNan(value) or value == 0 or !std.math.isFinite(value)) return 0;
    const integer = if (value < 0) -@floor(@abs(value)) else @floor(value);
    const two32 = 4294967296.0;
    var modulo = @mod(integer, two32);
    if (modulo < 0) modulo += two32;
    return @intFromFloat(modulo);
}

fn numberValue(value: core.JSValue) !f64 {
    if (value.isInt()) return @floatFromInt(value.asInt32().?);
    if (value.isFloat64()) return value.asFloat64().?;
    if (value.asBool()) |v| return if (v) 1 else 0;
    if (value.isNull()) return 0;
    if (value.isUndefined()) return std.math.nan(f64);
    return error.TypeError;
}

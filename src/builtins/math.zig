const core = @import("../core/root.zig");
const std = @import("std");

pub const PI = std.math.pi;
pub const E = std.math.e;
pub const LN10 = std.math.ln10;
pub const LN2 = std.math.ln2;
pub const LOG2E = std.math.log2e;
pub const LOG10E = std.math.log10e;
pub const SQRT1_2 = std.math.sqrt1_2;
pub const SQRT2 = std.math.sqrt2;

pub const sum_precise_method_id: u32 = 37;

/// QuickJS source map: Math builtin functions in quickjs.c. This is the
/// current narrow Math subset used by transitional `math_call` bytecode.
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

pub fn methodId(name: []const u8) ?u32 {
    if (std.mem.eql(u8, name, "abs")) return 1;
    if (std.mem.eql(u8, name, "floor")) return 2;
    if (std.mem.eql(u8, name, "ceil")) return 3;
    if (std.mem.eql(u8, name, "round")) return 4;
    if (std.mem.eql(u8, name, "sqrt")) return 5;
    if (std.mem.eql(u8, name, "pow")) return 6;
    if (std.mem.eql(u8, name, "min")) return 7;
    if (std.mem.eql(u8, name, "max")) return 8;
    if (std.mem.eql(u8, name, "random")) return 9;
    if (std.mem.eql(u8, name, "exp")) return 10;
    if (std.mem.eql(u8, name, "sin")) return 11;
    if (std.mem.eql(u8, name, "cos")) return 12;
    if (std.mem.eql(u8, name, "tan")) return 13;
    if (std.mem.eql(u8, name, "acos")) return 14;
    if (std.mem.eql(u8, name, "asin")) return 15;
    if (std.mem.eql(u8, name, "atan")) return 16;
    if (std.mem.eql(u8, name, "atan2")) return 17;
    if (std.mem.eql(u8, name, "acosh")) return 18;
    if (std.mem.eql(u8, name, "asinh")) return 19;
    if (std.mem.eql(u8, name, "atanh")) return 20;
    if (std.mem.eql(u8, name, "log")) return 21;
    if (std.mem.eql(u8, name, "trunc")) return 22;
    if (std.mem.eql(u8, name, "cbrt")) return 23;
    if (std.mem.eql(u8, name, "clz32")) return 24;
    if (std.mem.eql(u8, name, "cosh")) return 25;
    if (std.mem.eql(u8, name, "expm1")) return 26;
    if (std.mem.eql(u8, name, "f16round")) return 27;
    if (std.mem.eql(u8, name, "fround")) return 28;
    if (std.mem.eql(u8, name, "hypot")) return 29;
    if (std.mem.eql(u8, name, "imul")) return 30;
    if (std.mem.eql(u8, name, "log1p")) return 31;
    if (std.mem.eql(u8, name, "log2")) return 32;
    if (std.mem.eql(u8, name, "log10")) return 33;
    if (std.mem.eql(u8, name, "sign")) return 34;
    if (std.mem.eql(u8, name, "sinh")) return 35;
    if (std.mem.eql(u8, name, "tanh")) return 36;
    if (std.mem.eql(u8, name, "sumPrecise")) return sum_precise_method_id;
    return null;
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
    if (value.tag == core.Tag.int) return @floatFromInt(value.asInt32().?);
    if (value.tag == core.Tag.float64) return value.asFloat64().?;
    if (value.asBool()) |v| return if (v) 1 else 0;
    if (value.isNull()) return 0;
    if (value.isUndefined()) return std.math.nan(f64);
    return error.TypeError;
}

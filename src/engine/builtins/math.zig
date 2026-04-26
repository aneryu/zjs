const core = @import("../core/root.zig");
const std = @import("std");

pub const PI = std.math.pi;
pub const E = std.math.e;

/// QuickJS source map: Math builtin functions in quickjs.c. This is the
/// current narrow Math subset used by transitional `math_call` bytecode.
pub fn call(id: u32, args: []const core.Value) !f64 {
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
        10 => @sin(a),
        11 => @cos(a),
        12 => @tan(a),
        13 => std.math.acosh(a),
        14 => std.math.asinh(a),
        15 => std.math.atanh(a),
        16 => @log(a),
        else => error.UnsupportedMathCall,
    };
}

pub fn abs(value: f64) f64 {
    return @abs(value);
}

pub fn max(a: f64, b: f64) f64 {
    return if (a > b) a else b;
}

fn min(args: []const core.Value) !f64 {
    var out = std.math.inf(f64);
    for (args) |arg| out = @min(out, try numberValue(arg));
    return out;
}

fn maxSlice(args: []const core.Value) !f64 {
    var out = -std.math.inf(f64);
    for (args) |arg| out = @max(out, try numberValue(arg));
    return out;
}

fn numberValue(value: core.Value) !f64 {
    if (value.asInt32()) |v| return @floatFromInt(v);
    if (value.asFloat64()) |v| return v;
    if (value.asBool()) |v| return if (v) 1 else 0;
    if (value.isNull()) return 0;
    if (value.isUndefined()) return std.math.nan(f64);
    return error.TypeError;
}

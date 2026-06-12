const std = @import("std");
const core = @import("../core/root.zig");
const bytecode = @import("../bytecode/root.zig");
const frame_mod = @import("frame.zig");
const bignum = @import("../libs/bignum.zig");
const value_ops = @import("value_ops.zig");
const call_runtime = @import("call_runtime.zig");

pub fn qjsMathSumPrecise(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    if (args.len < 1) return error.TypeError;
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
            return error.TypeError;
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
    const sign = (bits >> 63) != 0;
    const exponent_bits: u16 = @intCast((bits >> 52) & 0x7ff);
    const fraction = bits & ((@as(u64, 1) << 52) - 1);
    const mantissa: u64 = if (exponent_bits == 0) fraction else ((@as(u64, 1) << 52) | fraction);
    const exponent: i32 = if (exponent_bits == 0) -1074 else @as(i32, exponent_bits) - 1023 - 52;
    var base = try bignum.BigInt.fromIntAlloc(allocator, if (sign) -@as(i128, @intCast(mantissa)) else @as(i128, @intCast(mantissa)));
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

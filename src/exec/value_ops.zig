const bytecode = @import("../bytecode.zig");
const core = @import("../core/root.zig");
const dtoa = @import("../libs/number_format.zig");
const bignum = @import("../libs/bigint.zig");
const unicode_lib = @import("../libs/unicode.zig");
const std = @import("std");

pub const AppendStringError = error{
    OutOfMemory,
    TypeError,
    InvalidRadix,
    NoSpaceLeft,
};

pub fn binary(rt: *core.JSRuntime, op: u8, a: core.JSValue, b: core.JSValue) !core.JSValue {
    if (op == bytecode.opcode.op.add and (a.isString() or b.isString())) return stringAdd(rt, a, b);
    if (a.isSymbol() or b.isSymbol()) return error.TypeError;
    if (a.isBigInt() or b.isBigInt()) {
        if (!a.isBigInt() or !b.isBigInt()) return error.TypeError;
        return binaryBigInt(rt, op, a, b);
    }
    if (op == bytecode.opcode.op.shl or op == bytecode.opcode.op.sar or op == bytecode.opcode.op.shr or
        op == bytecode.opcode.op.@"and" or op == bytecode.opcode.op.xor or op == bytecode.opcode.op.@"or")
    {
        const lhs = try toInt32(rt, a);
        const rhs = try toInt32(rt, b);
        if (op == bytecode.opcode.op.shr) {
            const out = @as(u32, @bitCast(lhs)) >> @intCast(rhs & 31);
            return numberToValue(@floatFromInt(out));
        }
        const out = switch (op) {
            bytecode.opcode.op.shl => lhs << @intCast(rhs & 31),
            bytecode.opcode.op.sar => lhs >> @intCast(rhs & 31),
            bytecode.opcode.op.@"and" => lhs & rhs,
            bytecode.opcode.op.xor => lhs ^ rhs,
            bytecode.opcode.op.@"or" => lhs | rhs,
            else => unreachable,
        };
        return core.JSValue.int32(out);
    }
    if (a.isNumber() and b.isNumber()) return binaryNumber(rt, op, a, b);
    if (op == bytecode.opcode.op.add or op == bytecode.opcode.op.sub or op == bytecode.opcode.op.mul or
        op == bytecode.opcode.op.div or op == bytecode.opcode.op.mod or op == bytecode.opcode.op.pow)
    {
        return binaryNumber(rt, op, a, b);
    }
    const lhs = try toInt32(rt, a);
    const rhs = try toInt32(rt, b);
    const out = switch (op) {
        bytecode.opcode.op.mul => lhs * rhs,
        bytecode.opcode.op.div => @divTrunc(lhs, rhs),
        bytecode.opcode.op.mod => @rem(lhs, rhs),
        bytecode.opcode.op.add => lhs + rhs,
        bytecode.opcode.op.sub => lhs - rhs,
        bytecode.opcode.op.shl => lhs << @intCast(rhs & 31),
        bytecode.opcode.op.sar => lhs >> @intCast(rhs & 31),
        bytecode.opcode.op.shr => @as(i32, @bitCast(@as(u32, @bitCast(lhs)) >> @intCast(rhs & 31))),
        bytecode.opcode.op.@"and" => lhs & rhs,
        bytecode.opcode.op.xor => lhs ^ rhs,
        bytecode.opcode.op.@"or" => lhs | rhs,
        bytecode.opcode.op.pow => powI32(lhs, rhs),
        else => unreachable,
    };
    return core.JSValue.int32(out);
}

pub fn compare(rt: *core.JSRuntime, op: u8, a: core.JSValue, b: core.JSValue) !core.JSValue {
    if (a.isString() and b.isString()) {
        const cmp: i32 = if (a.same(b)) 0 else compareStringValues(a, b) orelse return error.TypeError;
        const out = switch (op) {
            bytecode.opcode.op.lt => cmp < 0,
            bytecode.opcode.op.lte => cmp <= 0,
            bytecode.opcode.op.gt => cmp > 0,
            bytecode.opcode.op.gte => cmp >= 0,
            else => false,
        };
        return core.JSValue.boolean(out);
    }
    if (a.isBigInt() or b.isBigInt()) {
        const cmp = try compareBigIntRelational(rt, a, b) orelse return core.JSValue.boolean(false);
        const out = switch (op) {
            bytecode.opcode.op.lt => cmp == .lt,
            bytecode.opcode.op.lte => cmp == .lt or cmp == .eq,
            bytecode.opcode.op.gt => cmp == .gt,
            bytecode.opcode.op.gte => cmp == .gt or cmp == .eq,
            else => unreachable,
        };
        return core.JSValue.boolean(out);
    }
    const lhs = if (numberValue(a)) |number| number else try toIntegerOrInfinity(rt, a);
    const rhs = if (numberValue(b)) |number| number else try toIntegerOrInfinity(rt, b);
    const out = switch (op) {
        bytecode.opcode.op.lt => lhs < rhs,
        bytecode.opcode.op.lte => lhs <= rhs,
        bytecode.opcode.op.gt => lhs > rhs,
        bytecode.opcode.op.gte => lhs >= rhs,
        else => false,
    };
    return core.JSValue.boolean(out);
}

fn compareBigIntRelational(rt: *core.JSRuntime, a: core.JSValue, b: core.JSValue) !?std.math.Order {
    if (a.isBigInt() and b.isBigInt()) {
        return compareBigIntValues(a, b) orelse error.TypeError;
    }
    if (a.isBigInt()) return compareBigIntToNonBigInt(rt, a, b);
    const order = try compareBigIntToNonBigInt(rt, b, a) orelse return null;
    return reverseOrder(order);
}

fn compareBigIntToNonBigInt(rt: *core.JSRuntime, bigint_value: core.JSValue, other: core.JSValue) !?std.math.Order {
    if (other.isString()) {
        var parsed = parseStringToBigInt(rt, other) catch return null;
        defer parsed.deinit();
        var lhs = try cloneBigIntValue(rt, bigint_value);
        defer lhs.deinit();
        return lhs.compare(parsed);
    }
    if (numberValue(other)) |number| return try compareBigIntToNumber(rt, bigint_value, number);
    if (other.asBool()) |bool_value| {
        var rhs = try bignum.BigInt.fromIntAlloc(rt.memory.allocator, if (bool_value) 1 else 0);
        defer rhs.deinit();
        var lhs = try cloneBigIntValue(rt, bigint_value);
        defer lhs.deinit();
        return lhs.compare(rhs);
    }
    if (other.isNull()) {
        const zero = bignum.BigInt{ .allocator = rt.memory.allocator };
        var lhs = try cloneBigIntValue(rt, bigint_value);
        defer lhs.deinit();
        return lhs.compare(zero);
    }
    if (other.isUndefined()) return null;
    return error.TypeError;
}

pub fn parseStringToBigInt(rt: *core.JSRuntime, value: core.JSValue) !bignum.BigInt {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(rt.memory.allocator);
    try appendRawString(rt, &buffer, value);
    const trimmed = std.mem.trim(u8, buffer.items, " \t\r\n");
    if (trimmed.len == 0) return bignum.BigInt{ .allocator = rt.memory.allocator };
    return bignum.parseAutoAlloc(rt.memory.allocator, trimmed);
}

fn compareBigIntToNumber(rt: *core.JSRuntime, bigint_value: core.JSValue, number: f64) !?std.math.Order {
    if (std.math.isNan(number)) return null;
    if (std.math.isPositiveInf(number)) return .lt;
    if (std.math.isNegativeInf(number)) return .gt;

    var rhs = try truncatedFiniteNumberToBigInt(rt.memory.allocator, number);
    defer rhs.deinit();
    var lhs = try cloneBigIntValue(rt, bigint_value);
    defer lhs.deinit();
    const order = lhs.compare(rhs);
    if (order != .eq) return order;
    if (@trunc(number) == number) return .eq;
    return if (number > 0) .lt else .gt;
}

pub fn bigIntEqualsNumber(rt: *core.JSRuntime, bigint_value: core.JSValue, number: f64) !bool {
    const order = try compareBigIntToNumber(rt, bigint_value, number) orelse return false;
    return order == .eq;
}

fn truncatedFiniteNumberToBigInt(allocator: std.mem.Allocator, number: f64) !bignum.BigInt {
    const bits: u64 = @bitCast(number);
    const exp_bits: u11 = @intCast((bits >> 52) & 0x7ff);
    const frac = bits & ((@as(u64, 1) << 52) - 1);
    const negative = (bits >> 63) != 0;
    if (exp_bits == 0 and frac == 0) return .{ .allocator = allocator };

    const exponent: i32 = if (exp_bits == 0) -1022 else @as(i32, exp_bits) - 1023;
    const significand: u64 = if (exp_bits == 0) frac else ((@as(u64, 1) << 52) | frac);
    const shift = exponent - 52;

    var out = if (shift >= 0) blk: {
        var base = try bignum.BigInt.fromIntAlloc(allocator, significand);
        defer base.deinit();
        break :blk try base.shl(allocator, @intCast(shift));
    } else blk: {
        const rshift: u32 = @intCast(-shift);
        const int_part: u64 = if (rshift >= 64) 0 else significand >> @intCast(rshift);
        break :blk try bignum.BigInt.fromIntAlloc(allocator, int_part);
    };
    out.negative = negative and !out.isZero();
    return out;
}

pub fn integerNumberToBigIntValue(rt: *core.JSRuntime, number: f64) !core.JSValue {
    if (!std.math.isFinite(number) or @trunc(number) != number) return error.RangeError;
    var bigint = try truncatedFiniteNumberToBigInt(rt.memory.allocator, number);
    defer bigint.deinit();
    return createBigIntValue(rt, bigint);
}

fn reverseOrder(order: std.math.Order) std.math.Order {
    return switch (order) {
        .lt => .gt,
        .eq => .eq,
        .gt => .lt,
    };
}

pub fn strictEqual(a: core.JSValue, b: core.JSValue) core.JSValue {
    return core.JSValue.boolean(valuesEqual(a, b));
}

pub fn strictNotEqual(a: core.JSValue, b: core.JSValue) core.JSValue {
    return core.JSValue.boolean(!valuesEqual(a, b));
}

pub fn length(rt: *core.JSRuntime, value: core.JSValue) !core.JSValue {
    if (value.isString()) {
        const string_value = value.asStringBody() orelse return error.TypeError;
        return core.JSValue.int32(@intCast(string_value.len()));
    }
    if (value.isObject()) {
        const header = value.refHeader() orelse return error.TypeError;
        const object_value: *core.Object = @fieldParentPtr("header", header);
        if (object_value.flags.is_array) {
            if (object_value.arrayLength() <= @as(u32, @intCast(std.math.maxInt(i32)))) {
                return core.JSValue.int32(@intCast(object_value.arrayLength()));
            }
            return core.JSValue.float64(@floatFromInt(object_value.arrayLength()));
        }
        const length_value = object_value.getProperty(core.atom.ids.length);
        if (!length_value.isUndefined()) return length_value;
        length_value.free(rt);
        return core.JSValue.undefinedValue();
    }
    if (value.isNull() or value.isUndefined()) return error.TypeError;
    return core.JSValue.undefinedValue();
}

pub fn unary(rt: *core.JSRuntime, op: u8, value: core.JSValue) !core.JSValue {
    if (op == bytecode.opcode.op.not and !value.isBigInt()) {
        return core.JSValue.int32(~try toInt32(rt, value));
    }
    if (value.asFloat64()) |float_value| {
        const out = switch (op) {
            bytecode.opcode.op.neg => -float_value,
            bytecode.opcode.op.plus => float_value,
            bytecode.opcode.op.dec, bytecode.opcode.op.post_dec => float_value - 1,
            bytecode.opcode.op.inc, bytecode.opcode.op.post_inc => float_value + 1,
            else => unreachable,
        };
        return numberToValue(out);
    }
    if (value.isBigInt()) {
        if (op == bytecode.opcode.op.plus) return error.TypeError;
        if (value.asShortBigInt()) |short| {
            if (shortBigIntUnary(op, short)) |out| return out;
        }
        var out = try cloneBigIntValue(rt, value);
        defer out.deinit();
        switch (op) {
            bytecode.opcode.op.neg => out.negative = !out.negative and !out.isZero(),
            bytecode.opcode.op.dec, bytecode.opcode.op.post_dec => {
                var one = try bignum.BigInt.fromIntAlloc(rt.memory.allocator, 1);
                defer one.deinit();
                var next = try bignum.subAlloc(rt.memory.allocator, out, one);
                defer next.deinit();
                return createBigIntValue(rt, next);
            },
            bytecode.opcode.op.inc, bytecode.opcode.op.post_inc => {
                var one = try bignum.BigInt.fromIntAlloc(rt.memory.allocator, 1);
                defer one.deinit();
                var next = try bignum.addAlloc(rt.memory.allocator, out, one);
                defer next.deinit();
                return createBigIntValue(rt, next);
            },
            bytecode.opcode.op.not => {
                var next = try out.bitNot(rt.memory.allocator);
                defer next.deinit();
                return createBigIntValue(rt, next);
            },
            else => unreachable,
        }
        return createBigIntValue(rt, out);
    }
    if (op == bytecode.opcode.op.neg or op == bytecode.opcode.op.plus or
        op == bytecode.opcode.op.dec or op == bytecode.opcode.op.post_dec or
        op == bytecode.opcode.op.inc or op == bytecode.opcode.op.post_inc)
    {
        const number_value = try toNumberValue(rt, value);
        defer number_value.free(rt);
        const number = numberValue(number_value) orelse return error.TypeError;
        const out = switch (op) {
            bytecode.opcode.op.neg => -number,
            bytecode.opcode.op.plus => number,
            bytecode.opcode.op.dec, bytecode.opcode.op.post_dec => number - 1,
            bytecode.opcode.op.inc, bytecode.opcode.op.post_inc => number + 1,
            else => unreachable,
        };
        return numberToValue(out);
    }
    const n = try toInt32(rt, value);
    const out = switch (op) {
        bytecode.opcode.op.neg => return numberToValue(-@as(f64, @floatFromInt(n))),
        bytecode.opcode.op.plus => n,
        bytecode.opcode.op.not => ~n,
        bytecode.opcode.op.dec, bytecode.opcode.op.post_dec => n - 1,
        bytecode.opcode.op.inc, bytecode.opcode.op.post_inc => n + 1,
        else => unreachable,
    };
    return core.JSValue.int32(out);
}

pub fn factorial(value: core.JSValue) !core.JSValue {
    const n = value.asInt32() orelse return error.TypeError;
    if (n < 0) return error.RangeError;
    var out: i32 = 1;
    var i: i32 = 2;
    while (i <= n) : (i += 1) out *= i;
    return core.JSValue.int32(out);
}

pub fn typeOf(rt: *core.JSRuntime, value: core.JSValue) !core.JSValue {
    const name: []const u8 = if (value.isBigInt())
        "bigint"
    else if (value.isNumber())
        "number"
    else if (value.isBool())
        "boolean"
    else if (value.isString())
        "string"
    else if (value.isUndefined())
        "undefined"
    else if (isHTMLDDA(value))
        "undefined"
    else if (value.isSymbol())
        "symbol"
    else if (value.isNull())
        "object"
    else if (value.isFunctionBytecode())
        "function"
    else if (isFunctionObject(value) or proxyTargetIsFunction(value))
        "function"
    else
        "object";
    return createStringValue(rt, name);
}

pub fn logical(op: u8, a: core.JSValue, b: core.JSValue) core.JSValue {
    const out = switch (op) {
        bytecode.opcode.op.@"and" => if (isTruthy(a)) b else a,
        bytecode.opcode.op.@"or" => if (isTruthy(a)) a else b,
        bytecode.opcode.op.is_undefined_or_null => if (a.isNull() or a.isUndefined()) b else a,
        else => unreachable,
    };
    return out.dup();
}

pub fn toStringValue(rt: *core.JSRuntime, value: core.JSValue) !core.JSValue {
    if (try primitiveToStringValueFast(rt, value)) |fast| return fast;
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(rt.memory.allocator);
    try appendValueString(rt, &buffer, value);
    return createStringValue(rt, buffer.items);
}

fn primitiveToStringValueFast(rt: *core.JSRuntime, value: core.JSValue) !?core.JSValue {
    if (value.isString()) return value.dup();
    if (value.asInt32()) |int_value| {
        if (int_value >= 0 and int_value < 256) {
            const cached = try rt.smallIntString(@intCast(int_value));
            return cached.value().dup();
        }
        var int_buf: [32]u8 = undefined;
        return try createAsciiStringValue(rt, dtoa.formatInt32(&int_buf, int_value));
    }
    if (value.asFloat64()) |float_value| {
        if (std.math.isNan(float_value)) return try createAsciiStringValue(rt, "NaN");
        if (std.math.isPositiveInf(float_value)) return try createAsciiStringValue(rt, "Infinity");
        if (std.math.isNegativeInf(float_value)) return try createAsciiStringValue(rt, "-Infinity");
        if (std.math.isNegativeZero(float_value)) return try createAsciiStringValue(rt, "0");
        var float_buf: [64]u8 = undefined;
        return try createAsciiStringValue(rt, try formatFiniteNumber(&float_buf, float_value));
    }
    if (value.asShortBigInt()) |bigint_value| {
        var bigint_buf: [32]u8 = undefined;
        return try createAsciiStringValue(rt, dtoa.formatInt64(&bigint_buf, bigint_value));
    }
    if (value.asBool()) |bool_value| {
        return try createAsciiStringValue(rt, if (bool_value) "true" else "false");
    }
    if (value.isUndefined()) return try createAsciiStringValue(rt, "undefined");
    if (value.isNull()) return try createAsciiStringValue(rt, "null");
    return null;
}

fn fastStringToInt32(bytes: []const u8) ?i32 {
    if (bytes.len == 0 or bytes.len > 10) return null;
    var res: i64 = 0;
    for (bytes) |ch| {
        if (ch < '0' or ch > '9') return null;
        res = res * 10 + @as(i64, ch - '0');
    }
    if (res > std.math.maxInt(i32)) return null;
    return @intCast(res);
}

pub fn toNumberValue(rt: *core.JSRuntime, value: core.JSValue) !core.JSValue {
    if (value.isSymbol()) return error.TypeError;
    if (numberValue(value)) |number| return numberToValue(number);
    if (value.asBool()) |bool_value| return core.JSValue.int32(if (bool_value) 1 else 0);
    if (value.isNull()) return core.JSValue.int32(0);
    if (value.isString()) {
        const str = stringObject(value).?;
        try str.ensureFlat(rt);
        switch (str.resolveData()) {
            .latin1 => |bytes| {
                if (fastStringToInt32(bytes)) |val| return core.JSValue.int32(val);
                return numberToValue(parseJsNumber(bytes));
            },
            .utf16 => {},
        }
        var bytes = std.ArrayList(u8).empty;
        defer bytes.deinit(rt.memory.allocator);
        try appendRawString(rt, &bytes, value);
        return numberToValue(parseJsNumber(bytes.items));
    }
    return core.JSValue.float64(std.math.nan(f64));
}

pub fn toBooleanValue(value: core.JSValue) core.JSValue {
    return core.JSValue.boolean(isTruthy(value));
}

pub fn asN(rt: *core.JSRuntime, bits_value: core.JSValue, bigint_value: core.JSValue, unsigned: bool) !core.JSValue {
    if (bits_value.isBigInt() or bits_value.isSymbol()) return error.TypeError;
    const bits_number = try toIntegerOrInfinity(rt, bits_value);
    if (!std.math.isFinite(bits_number)) return error.RangeError;
    const truncated = @trunc(bits_number);
    if (truncated < 0) return error.RangeError;
    if (truncated > 9007199254740991.0) return error.RangeError;
    const bits: usize = @intFromFloat(truncated);
    var input = try toBigIntValue(rt, bigint_value);
    defer input.deinit();
    if (bits == 0) return createBigIntI128(rt, 0);

    const input_bit_length = input.bitLengthAbs();
    if (unsigned) {
        if (!input.negative and input_bit_length <= bits) return createBigIntValue(rt, input);
    } else if (input_bit_length < bits) {
        return createBigIntValue(rt, input);
    }

    var reduced = try input.modPowerOfTwo(rt.memory.allocator, bits);
    defer reduced.deinit();
    if (!unsigned and reduced.testBit(bits - 1)) {
        var modulus = try bignum.pow2(rt.memory.allocator, bits);
        defer modulus.deinit();
        var signed = try bignum.subAlloc(rt.memory.allocator, reduced, modulus);
        defer signed.deinit();
        return createBigIntValue(rt, signed);
    }
    return createBigIntValue(rt, reduced);
}

pub fn numberToValue(value: f64) core.JSValue {
    if (value >= -2147483648 and value <= 2147483647) {
        const int_val: i32 = @intFromFloat(value);
        if (@as(f64, @floatFromInt(int_val)) == value and !std.math.isNegativeZero(value)) {
            return core.JSValue.int32(int_val);
        }
    }
    return core.JSValue.float64(value);
}

pub fn createStringValue(rt: *core.JSRuntime, bytes: []const u8) !core.JSValue {
    if (bytes.len == 0) {
        const cached = try rt.emptyString();
        return cached.value().dup();
    }
    const str = if (core.string.isAsciiBytes(bytes))
        try core.string.String.createAscii(rt, bytes)
    else
        try core.string.String.createUtf8(rt, bytes);
    return str.value();
}

fn createAsciiStringValue(rt: *core.JSRuntime, bytes: []const u8) !core.JSValue {
    if (bytes.len == 0) {
        const cached = try rt.emptyString();
        return cached.value().dup();
    }
    return (try core.string.String.createAscii(rt, bytes)).value();
}

pub fn createBigIntI128(rt: *core.JSRuntime, value: i128) !core.JSValue {
    if (core.JSValue.shortBigIntFits(value)) {
        return core.JSValue.shortBigInt(@intCast(value));
    }
    const big = try core.bigint.BigInt.create(rt, value);
    return big.valueRef();
}

pub fn createBigIntOwned(rt: *core.JSRuntime, value: bignum.BigInt) !core.JSValue {
    var owned = value;
    errdefer owned.deinit();
    if (owned.toI64()) |val| {
        if (core.JSValue.shortBigIntFits(val)) {
            owned.deinit();
            return core.JSValue.shortBigInt(val);
        }
    }
    const big = try core.bigint.BigInt.createFromOwned(rt, owned);
    return big.valueRef();
}

pub fn createBigIntValue(rt: *core.JSRuntime, value: bignum.BigInt) !core.JSValue {
    if (value.toI64()) |val| {
        if (core.JSValue.shortBigIntFits(val)) {
            return core.JSValue.shortBigInt(val);
        }
    }
    const big = try core.bigint.BigInt.createFromBigInt(rt, value);
    return big.valueRef();
}

pub fn numberValue(value: core.JSValue) ?f64 {
    if (value.isInt()) return @floatFromInt(value.asInt32().?);
    if (value.isFloat64()) return value.asFloat64().?;
    return null;
}

pub fn bigIntToNumber(rt: *core.JSRuntime, value: core.JSValue) !f64 {
    var bigint = try cloneBigIntValue(rt, value);
    defer bigint.deinit();
    const text = try bigint.formatBase10Alloc(rt.memory.allocator);
    defer rt.memory.allocator.free(text);
    return std.fmt.parseFloat(f64, text);
}

pub fn toIntegerOrInfinity(rt: *core.JSRuntime, value: core.JSValue) !f64 {
    if (numberValue(value)) |number| return number;
    if (value.asBool()) |bool_value| return if (bool_value) 1 else 0;
    if (value.isNull()) return 0;
    if (value.isUndefined()) return std.math.nan(f64);

    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(rt.memory.allocator);
    try appendValueString(rt, &buffer, value);
    return parseJsNumber(buffer.items);
}

pub fn toIndexUsize(rt: *core.JSRuntime, value: core.JSValue) !usize {
    const number = try toIntegerOrInfinity(rt, value);
    if (std.math.isNan(number)) return 0;
    if (!std.math.isFinite(number)) return error.RangeError;
    const truncated = @trunc(number);
    if (truncated < 0) return error.RangeError;
    if (truncated == 0) return 0;
    return @intFromFloat(truncated);
}

pub fn toBigIntValue(rt: *core.JSRuntime, value: core.JSValue) !bignum.BigInt {
    if (value.isBigInt()) return cloneBigIntValue(rt, value);
    if (value.isNumber()) return error.TypeError;
    if (value.asBool()) |bool_value| return bignum.BigInt.fromIntAlloc(rt.memory.allocator, if (bool_value) 1 else 0);

    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(rt.memory.allocator);
    if (value.isString() or value.isObject()) {
        try appendValueString(rt, &buffer, value);
        const trimmed = std.mem.trim(u8, buffer.items, " \t\r\n");
        if (trimmed.len == 0) return bignum.BigInt.fromIntAlloc(rt.memory.allocator, 0);
        return bignum.parseAutoAlloc(rt.memory.allocator, trimmed) catch error.SyntaxError;
    }
    return error.TypeError;
}

pub fn bigIntFromValueBorrowed(rt: *core.JSRuntime, value: core.JSValue) !bignum.BigInt {
    if (value.asShortBigInt()) |big_int| return bignum.BigInt.fromIntAlloc(rt.memory.allocator, big_int);
    if (value.isBigInt() and value.refHeader() != null) {
        const header = value.refHeader().?;
        const big: *core.bigint.BigInt = @alignCast(@fieldParentPtr("header", header));
        var val = big.value;
        val.allocator = rt.memory.allocator;
        return val;
    }
    return error.TypeError;
}

pub fn cloneBigIntValue(rt: *core.JSRuntime, value: core.JSValue) !bignum.BigInt {
    if (value.asShortBigInt()) |big_int| return bignum.BigInt.fromIntAlloc(rt.memory.allocator, big_int);
    if (value.isBigInt() and value.refHeader() != null) {
        const header = value.refHeader().?;
        const big: *core.bigint.BigInt = @alignCast(@fieldParentPtr("header", header));
        return big.value.cloneWithAllocator(rt.memory.allocator);
    }
    return error.TypeError;
}

pub fn isTruthy(value: core.JSValue) bool {
    return core.value_semantics.toBoolean(value);
}

pub fn isFunctionObject(value: core.JSValue) bool {
    const header = value.refHeader() orelse return false;
    if (!value.isObject()) return false;
    const object: *core.Object = @fieldParentPtr("header", header);
    if (object.proxyTarget() != null) return proxyTargetIsFunction(value);
    return object.class_id == core.class.ids.c_function or
        object.class_id == core.class.ids.bytecode_function or
        object.class_id == core.class.ids.bound_function or
        object.class_id == core.class.ids.c_function_data or
        object.class_id == core.class.ids.c_closure;
}

fn proxyTargetIsFunction(value: core.JSValue) bool {
    const header = value.refHeader() orelse return false;
    if (!value.isObject()) return false;
    const object: *core.Object = @fieldParentPtr("header", header);
    const target = object.proxyTarget() orelse return false;
    return target.isFunctionBytecode() or isFunctionObject(target);
}

pub fn atomNameEql(rt: *core.JSRuntime, atom_id: core.Atom, name: []const u8) bool {
    return if (rt.atoms.name(atom_id)) |atom_name| std.mem.eql(u8, atom_name, name) else false;
}

pub fn appendRawString(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), value: core.JSValue) !void {
    const string_value = value.asStringBody() orelse return;
    try string_value.ensureFlat(rt);
    switch (string_value.resolveData()) {
        .latin1 => |bytes| try buffer.appendSlice(rt.memory.allocator, bytes),
        .utf16 => |units| try appendUtf16AsUtf8(rt, buffer, units),
    }
}

pub fn appendValueString(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), value: core.JSValue) AppendStringError!void {
    if (value.asSymbolAtom()) |atom_id| {
        const description = core.symbol.description(&rt.atoms, atom_id) orelse "";
        try buffer.appendSlice(rt.memory.allocator, "Symbol(");
        try buffer.appendSlice(rt.memory.allocator, description);
        try buffer.append(rt.memory.allocator, ')');
    } else if (value.asInt32()) |int_value| {
        var int_buf: [32]u8 = undefined;
        const printed = dtoa.formatInt32(&int_buf, int_value);
        try buffer.appendSlice(rt.memory.allocator, printed);
    } else if (value.asFloat64()) |float_value| {
        if (std.math.isNan(float_value)) {
            try buffer.appendSlice(rt.memory.allocator, "NaN");
        } else if (std.math.isPositiveInf(float_value)) {
            try buffer.appendSlice(rt.memory.allocator, "Infinity");
        } else if (std.math.isNegativeInf(float_value)) {
            try buffer.appendSlice(rt.memory.allocator, "-Infinity");
        } else if (std.math.isNegativeZero(float_value)) {
            try buffer.append(rt.memory.allocator, '0');
        } else {
            var float_buf: [64]u8 = undefined;
            const printed = try formatFiniteNumber(&float_buf, float_value);
            try buffer.appendSlice(rt.memory.allocator, printed);
        }
    } else if (value.isBigInt()) {
        try core.value_format.appendBigIntBase10(rt.memory.allocator, buffer, value);
    } else if (value.asBool()) |bool_value| {
        try buffer.appendSlice(rt.memory.allocator, if (bool_value) "true" else "false");
    } else if (value.isUndefined()) {
        try buffer.appendSlice(rt.memory.allocator, "undefined");
    } else if (value.isNull()) {
        try buffer.appendSlice(rt.memory.allocator, "null");
    } else if (value.isString()) {
        const string_value = value.asStringBody() orelse return;
        try string_value.ensureFlat(rt);
        switch (string_value.resolveData()) {
            .latin1 => |bytes| {
                for (bytes) |byte| try appendUtf8CodePoint(rt, buffer, byte);
            },
            .utf16 => |units| try appendUtf16AsUtf8(rt, buffer, units),
        }
    } else if (value.isObject()) {
        const header = value.refHeader() orelse return;
        const object_value: *core.Object = @fieldParentPtr("header", header);
        if (object_value.class_id == core.class.ids.string) {
            const data = object_value.objectData() orelse return error.TypeError;
            try appendValueString(rt, buffer, data);
        } else if (object_value.class_id == core.class.ids.array_buffer) {
            try buffer.appendSlice(rt.memory.allocator, "[object ArrayBuffer]");
        } else if (object_value.class_id == core.class.ids.promise) {
            try buffer.appendSlice(rt.memory.allocator, "[object Promise]");
        } else if (object_value.flags.is_array) {
            try appendArrayString(rt, buffer, object_value);
        } else {
            try buffer.appendSlice(rt.memory.allocator, "[object Object]");
        }
    } else {
        try buffer.appendSlice(rt.memory.allocator, "[object Object]");
    }
}

pub fn formatFiniteNumber(buffer: []u8, value: f64) ![]const u8 {
    return core.value_format.formatFiniteNumber(buffer, value);
}

fn normalizeExponentSign(buffer: []u8, len: usize) []const u8 {
    const text = buffer[0..len];
    const exp_index = std.mem.indexOfScalar(u8, text, 'e') orelse return text;
    if (exp_index + 1 >= text.len or text[exp_index + 1] == '-' or text[exp_index + 1] == '+') return text;
    var tail_index = len;
    while (tail_index > exp_index + 1) : (tail_index -= 1) {
        buffer[tail_index] = buffer[tail_index - 1];
    }
    buffer[exp_index + 1] = '+';
    return buffer[0 .. len + 1];
}

fn appendUtf8CodePoint(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), cp: u32) !void {
    return unicode_lib.appendUtf8CodePoint(rt.memory.allocator, buffer, cp);
}

fn appendUtf16AsUtf8(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), units: []const u16) !void {
    return unicode_lib.appendUtf16UnitsAsUtf8(rt.memory.allocator, buffer, units);
}

fn binaryBigInt(rt: *core.JSRuntime, op: u8, a: core.JSValue, b: core.JSValue) !core.JSValue {
    if (a.asShortBigInt()) |lhs| {
        if (b.asShortBigInt()) |rhs| {
            if (shortBigIntBinary(op, lhs, rhs)) |out| return out;
        }
    }

    if (op == bytecode.opcode.op.add) {
        if (b.asShortBigInt()) |rhs| {
            if (rhs > 0) {
                if (try addPositiveShortToBigInt(rt, a, @intCast(rhs))) |out| return out;
            }
        }
        if (a.asShortBigInt()) |lhs| {
            if (lhs > 0) {
                if (try addPositiveShortToBigInt(rt, b, @intCast(lhs))) |out| return out;
            }
        }
    }

    if (op == bytecode.opcode.op.add and a.isBigInt() and a.refHeader() != null and a.refHeader().?.meta().rc == 1) {
        const header = a.refHeader().?;
        const big: *core.bigint.BigInt = @alignCast(@fieldParentPtr("header", header));
        const rhs = try bigIntFromValueBorrowed(rt, b);
        const rhs_is_owned = b.asShortBigInt() != null;
        defer if (rhs_is_owned) {
            var owned = rhs;
            owned.deinit();
        };
        try big.value.addInPlace(rhs);
        return a.dup();
    }

    const lhs = try bigIntFromValueBorrowed(rt, a);
    const lhs_is_owned = a.asShortBigInt() != null;
    defer if (lhs_is_owned) {
        var owned = lhs;
        owned.deinit();
    };

    const rhs = try bigIntFromValueBorrowed(rt, b);
    const rhs_is_owned = b.asShortBigInt() != null;
    defer if (rhs_is_owned) {
        var owned = rhs;
        owned.deinit();
    };

    const allocator = rt.memory.allocator;
    const out = switch (op) {
        bytecode.opcode.op.mul => try bignum.mulAlloc(allocator, lhs, rhs),
        bytecode.opcode.op.div => lhs.div(rhs) catch |err| switch (err) {
            error.DivisionByZero => return error.RangeError,
            else => return err,
        },
        bytecode.opcode.op.mod => lhs.rem(rhs) catch |err| switch (err) {
            error.DivisionByZero => return error.RangeError,
            else => return err,
        },
        bytecode.opcode.op.add => try bignum.addAlloc(allocator, lhs, rhs),
        bytecode.opcode.op.sub => try bignum.subAlloc(allocator, lhs, rhs),
        bytecode.opcode.op.pow => lhs.pow(rhs, allocator) catch |err| switch (err) {
            error.NegativeExponent, error.BigIntTooLarge => return error.RangeError,
            else => return err,
        },
        bytecode.opcode.op.@"and" => try lhs.bitwise(rhs, allocator, .@"and"),
        bytecode.opcode.op.xor => try lhs.bitwise(rhs, allocator, .xor),
        bytecode.opcode.op.@"or" => try lhs.bitwise(rhs, allocator, .@"or"),
        bytecode.opcode.op.shl => try shiftBigInt(allocator, lhs, rhs, .left),
        bytecode.opcode.op.sar => try shiftBigInt(allocator, lhs, rhs, .right),
        bytecode.opcode.op.shr => return error.TypeError,
        else => unreachable,
    };
    return createBigIntOwned(rt, out);
}

fn addPositiveShortToBigInt(rt: *core.JSRuntime, value: core.JSValue, addend: bignum.Limb) !?core.JSValue {
    if (!value.isBigInt()) return null;
    const header = value.refHeader() orelse return null;
    const big: *core.bigint.BigInt = @alignCast(@fieldParentPtr("header", header));
    if (big.value.negative) return null;

    var out = try big.value.cloneWithAllocator(rt.memory.allocator);
    errdefer out.deinit();
    try out.addPositiveSmallInPlace(addend);
    return try createBigIntOwned(rt, out);
}

pub fn shortBigIntBinary(op: u8, lhs: i64, rhs: i64) ?core.JSValue {
    return switch (op) {
        bytecode.opcode.op.add => shortBigIntAdd(lhs, rhs),
        bytecode.opcode.op.sub => shortBigIntSub(lhs, rhs),
        bytecode.opcode.op.mul => shortBigIntMul(lhs, rhs),
        bytecode.opcode.op.@"and" => core.JSValue.shortBigInt(lhs & rhs),
        bytecode.opcode.op.xor => core.JSValue.shortBigInt(lhs ^ rhs),
        bytecode.opcode.op.@"or" => core.JSValue.shortBigInt(lhs | rhs),
        else => null,
    };
}

pub fn shortBigIntUnary(op: u8, value: i64) ?core.JSValue {
    return switch (op) {
        bytecode.opcode.op.neg => shortBigIntSub(0, value),
        bytecode.opcode.op.dec, bytecode.opcode.op.post_dec => shortBigIntSub(value, 1),
        bytecode.opcode.op.inc, bytecode.opcode.op.post_inc => shortBigIntAdd(value, 1),
        bytecode.opcode.op.not => core.JSValue.shortBigInt(~value),
        else => null,
    };
}

fn shortBigIntAdd(lhs: i64, rhs: i64) ?core.JSValue {
    const result = @addWithOverflow(lhs, rhs);
    if (result[1] != 0) return null;
    if (!core.JSValue.shortBigIntFits(result[0])) return null;
    return core.JSValue.shortBigInt(result[0]);
}

fn shortBigIntSub(lhs: i64, rhs: i64) ?core.JSValue {
    const result = @subWithOverflow(lhs, rhs);
    if (result[1] != 0) return null;
    if (!core.JSValue.shortBigIntFits(result[0])) return null;
    return core.JSValue.shortBigInt(result[0]);
}

fn shortBigIntMul(lhs: i64, rhs: i64) ?core.JSValue {
    const result = @mulWithOverflow(lhs, rhs);
    if (result[1] != 0) return null;
    if (!core.JSValue.shortBigIntFits(result[0])) return null;
    return core.JSValue.shortBigInt(result[0]);
}

fn binaryNumber(rt: *core.JSRuntime, op: u8, a: core.JSValue, b: core.JSValue) !core.JSValue {
    const lhs = if (numberValue(a)) |number| number else try toIntegerOrInfinity(rt, a);
    const rhs = if (numberValue(b)) |number| number else try toIntegerOrInfinity(rt, b);
    const out = switch (op) {
        bytecode.opcode.op.mul => lhs * rhs,
        bytecode.opcode.op.div => lhs / rhs,
        bytecode.opcode.op.mod => @rem(lhs, rhs),
        bytecode.opcode.op.add => lhs + rhs,
        bytecode.opcode.op.sub => lhs - rhs,
        bytecode.opcode.op.pow => jsMathPow(lhs, rhs),
        else => unreachable,
    };
    // qjs js_add_slow / js_binary_arith_slow: two JS_TAG_INT operands take the
    // int32 path (normalized result, overflow→float); any float operand goes
    // ToFloat64 + bare __JS_NewFloat64 with NO int32 renormalization. Mirror that
    // so a float-involving result is not silently re-tagged int32.
    if (a.isInt() and b.isInt()) return numberToValue(out);
    return core.JSValue.float64(out);
}

fn toInt32(rt: *core.JSRuntime, value: core.JSValue) !i32 {
    const number = try toIntegerOrInfinity(rt, value);
    if (!std.math.isFinite(number) or std.math.isNan(number)) return 0;
    const integer = if (number < 0) -@floor(@abs(number)) else @floor(number);
    const wrapped: u32 = @intFromFloat(@mod(integer, 4294967296));
    return @bitCast(wrapped);
}

fn stringAdd(rt: *core.JSRuntime, a: core.JSValue, b: core.JSValue) !core.JSValue {
    if (a.isSymbol() or b.isSymbol()) return error.TypeError;
    if (a.isString() and b.isInt()) {
        if (try stringAddStringInt(rt, a, b.asInt32().?, .suffix)) |out| return out;
    }
    if (a.isInt() and b.isString()) {
        if (try stringAddStringInt(rt, b, a.asInt32().?, .prefix)) |out| return out;
    }
    if (a.isString() and b.isString()) return stringAddStrings(rt, a, b);
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(rt.memory.allocator);
    try appendValueString(rt, &buffer, a);
    try appendValueString(rt, &buffer, b);
    return createStringValue(rt, buffer.items);
}

const StringIntPosition = enum {
    prefix,
    suffix,
};

fn stringAddStringInt(rt: *core.JSRuntime, string_value: core.JSValue, int_value: i32, position: StringIntPosition) !?core.JSValue {
    // Rope-backed values must NOT be flattened here: extend the rope's tail
    // when it is exclusively held, otherwise chain through another rope node.
    // Detect the rope at the VALUE/tag level before `stringObject` would
    // flatten it.
    if (string_value.ropeBody()) |node| {
        if (node.len == 0) return try toStringValue(rt, core.JSValue.int32(int_value));
        if (position == .suffix) {
            if (node.header().rc == 1 and node.flat == null) {
                var digits_buf: [16]u8 = undefined;
                const digits = dtoa.formatInt32(&digits_buf, int_value);
                if (try core.string.appendRopeTail(node, rt, .{ .latin1 = digits })) {
                    return string_value.dup();
                }
            }
        }
        const digits_value = try toStringValue(rt, core.JSValue.int32(int_value));
        const left = if (position == .prefix) digits_value else string_value;
        const right = if (position == .prefix) string_value else digits_value;
        const out = core.string.String.createRope(rt, left, right) catch |err| {
            digits_value.free(rt);
            return err;
        };
        digits_value.free(rt);
        return out.value();
    }

    const string = stringObject(string_value) orelse return null;
    if (string.len() == 0) {
        return try toStringValue(rt, core.JSValue.int32(int_value));
    }

    const string_bytes = string.borrowLatin1() orelse return null;
    if (int_value >= 0 and int_value < 256) {
        const cached = try rt.smallIntString(@intCast(int_value));
        const digits = cached.borrowLatin1() orelse return null;

        const out = switch (position) {
            .prefix => try core.string.String.createLatin1Concat(rt, digits, string_bytes),
            .suffix => try core.string.String.createLatin1Concat(rt, string_bytes, digits),
        };
        return out.value();
    }

    var int_buf: [16]u8 = undefined;
    const digits = dtoa.formatInt32(&int_buf, int_value);

    const out = switch (position) {
        .prefix => try core.string.String.createLatin1Concat(rt, digits, string_bytes),
        .suffix => try core.string.String.createLatin1Concat(rt, string_bytes, digits),
    };
    return out.value();
}

fn stringAddStrings(rt: *core.JSRuntime, a: core.JSValue, b: core.JSValue) !core.JSValue {
    const a_len = core.string.stringValueLen(a);
    const b_len = core.string.stringValueLen(b);
    if (a_len == 0) return b.dup();
    if (b_len == 0) return a.dup();

    const a_is_rope = a.ropeBody() != null;
    const b_is_rope = b.ropeBody() != null;

    // rc==1: the caller holds the only reference, so the lhs is consumed by
    // this add and may be extended in place (rope tail append when the lhs is
    // an unmaterialized rope). A rope rhs keeps the deferred rope-of-rope
    // linking below instead of being copied.
    if (!b_is_rope) {
        if (a.ropeBody()) |node| {
            if (node.header().rc == 1 and try appendRopeTailValue(rt, node, b)) {
                return a.dup();
            }
        }
    }
    // If either operand already is a rope, concatenating eagerly would flatten
    // it; chain another rope node instead (ropes are always >= rope_min_len).
    if (a_is_rope or b_is_rope) {
        const out = try core.string.String.createRope(rt, a, b);
        return out.value();
    }
    // Long concatenations defer the copy through a rope node (QuickJS
    // JSStringRope analogue); content materializes lazily on first read.
    if (a_len + b_len >= core.string.String.rope_min_len) {
        const out = try core.string.String.createRope(rt, a, b);
        return out.value();
    }

    // Both operands are flat from here.
    const a_string = stringObject(a) orelse return error.TypeError;
    const b_string = stringObject(b) orelse return error.TypeError;
    // Fast path: both operands are latin1. We allocate the result string
    // directly and memcpy in place, skipping the ArrayList intermediate
    // and the latin1→utf16 fallback when both sides fit in 8 bits.
    if (a_string.borrowLatin1()) |a_bytes| {
        if (b_string.borrowLatin1()) |b_bytes| {
            if (try percentHexConcat(rt, a_bytes, b_bytes)) |result| return result;

            const out = try core.string.String.createLatin1Concat(rt, a_bytes, b_bytes);
            return out.value();
        }
    }
    // Fast path: both operands are utf16, concat directly into a fresh
    // utf16 buffer.
    switch (a_string.resolveData()) {
        .utf16 => |a_units| switch (b_string.resolveData()) {
            .utf16 => |b_units| {
                const out = try core.string.String.createUtf16Concat(rt, a_units, b_units);
                return out.value();
            },
            .latin1 => {},
        },
        .latin1 => {},
    }
    // Mixed widths fall back to the slower ArrayList path.
    var units = try std.ArrayList(u16).initCapacity(rt.memory.allocator, a_len + b_len);
    defer units.deinit(rt.memory.allocator);
    try appendStringUtf16Units(rt, &units, a_string);
    try appendStringUtf16Units(rt, &units, b_string);
    return (try core.string.String.createUtf16(rt, units.items)).value();
}

/// Extends an exclusively-held unmaterialized rope's tail with `rhs`'s flat
/// content. `rhs` must NOT be a rope (the caller guards that so the rhs's own
/// deferred content stays lazy through rope-of-rope linking instead).
fn appendRopeTailValue(rt: *core.JSRuntime, node: *core.string.StringRope, rhs: core.JSValue) !bool {
    if (rhs.ropeBody() != null) return false;
    if (node.flat != null) return false;
    const rhs_string = stringObject(rhs) orelse return false;
    return core.string.appendRopeTail(node, rt, rhs_string.resolveData());
}

pub fn tryAppendStringInPlace(rt: *core.JSRuntime, lhs: core.JSValue, rhs: core.JSValue, max_ref_count: usize) !bool {
    // Only an exclusively-held unmaterialized rope lhs can be extended in
    // place (via its private tail buffer). Flat strings store their characters
    // inline in a fixed-size allocation (qjs `JSString` FAM), so there is no
    // spare capacity — the caller copies into a fresh string instead.
    const node = lhs.ropeBody() orelse return false;
    if (@as(usize, @intCast(node.header().rc)) > max_ref_count) return false;
    return appendRopeTailValue(rt, node, rhs);
}

pub fn tryAppendLatin1StringInPlace(rt: *core.JSRuntime, lhs: core.JSValue, rhs: core.JSValue, max_ref_count: usize) !bool {
    return tryAppendStringInPlace(rt, lhs, rhs, max_ref_count);
}

pub fn tryAppendLatin1AtomRepeatedInPlace(rt: *core.JSRuntime, lhs: core.JSValue, atom_id: core.Atom, repeat_count: usize, max_ref_count: usize) !bool {
    // Flat strings store their characters inline in a fixed-size allocation
    // (QuickJS `JSString` FAM), so there is no spare capacity to extend into
    // in place. Callers fall back to `latin1AtomRepeatedConcatValue`, which
    // copies into a fresh string.
    _ = rt;
    _ = lhs;
    _ = atom_id;
    _ = repeat_count;
    _ = max_ref_count;
    return false;
}

pub fn latin1AtomRepeatedConcatValue(rt: *core.JSRuntime, lhs: core.JSValue, atom_id: core.Atom, repeat_count: usize) !?core.JSValue {
    const lhs_string = stringObject(lhs) orelse return null;
    try lhs_string.ensureFlat(rt);
    const lhs_bytes = switch (lhs_string.resolveData()) {
        .latin1 => |bytes| bytes,
        .utf16 => return null,
    };
    if (rt.atoms.kind(atom_id) != .string) return null;
    const suffix = rt.atoms.name(atom_id) orelse return null;
    for (suffix) |byte| {
        if (byte > 0x7f) return null;
    }
    if (suffix.len == 0 or repeat_count == 0) return lhs.dup();
    const out = try core.string.String.createLatin1RepeatedConcatWithSeed(rt, lhs_bytes, suffix, repeat_count, 0);
    return out.value();
}

fn percentHexConcat(rt: *core.JSRuntime, a: []const u8, b: []const u8) !?core.JSValue {
    if (a.len == 1 and b.len == 1 and a[0] == '%' and upperHexValue(b[0]) != null) {
        const cached = try rt.recentTwoUnitString('%', b[0]);
        return cached.value().dup();
    }
    if (a.len == 2 and b.len == 1 and a[0] == '%') {
        const high = upperHexValue(a[1]) orelse return null;
        const low = upperHexValue(b[0]) orelse return null;
        const cached = try rt.percentHexString((high << 4) | low);
        return cached.value().dup();
    }
    return null;
}

fn upperHexValue(byte: u8) ?u8 {
    return unicode_lib.asciiUpperHexDigitValueByte(byte);
}

fn stringObject(value: core.JSValue) ?*core.string.String {
    return value.asStringBody();
}

fn appendStringLatin1Units(rt: *core.JSRuntime, out: *std.ArrayList(u8), string: *const core.string.String) !void {
    switch (string.resolveData()) {
        .latin1 => |bytes| try out.appendSlice(rt.memory.allocator, bytes),
        .utf16 => |units| try appendUtf16AsUtf8(rt, out, units),
    }
}

fn stringLatin1IsAscii(string: *const core.string.String) bool {
    switch (string.resolveData()) {
        .latin1 => |bytes| {
            for (bytes) |byte| {
                if (byte > 0x7f) return false;
            }
            return true;
        },
        .utf16 => return false,
    }
}

fn appendStringUtf16Units(rt: *core.JSRuntime, out: *std.ArrayList(u16), string: *const core.string.String) !void {
    switch (string.resolveData()) {
        .latin1 => |bytes| {
            for (bytes) |byte| try out.append(rt.memory.allocator, byte);
        },
        .utf16 => |units| try out.appendSlice(rt.memory.allocator, units),
    }
}

fn shiftBigInt(allocator: std.mem.Allocator, lhs: bignum.BigInt, rhs: bignum.BigInt, direction: enum { left, right }) !bignum.BigInt {
    var shift_value = try rhs.cloneWithAllocator(allocator);
    defer shift_value.deinit();
    const negative_shift = shift_value.negative;
    shift_value.negative = false;
    const amount = shift_value.toUsize() orelse return error.RangeError;
    return switch (direction) {
        .left => if (negative_shift) lhs.shr(allocator, amount) else lhs.shl(allocator, amount),
        .right => if (negative_shift) lhs.shl(allocator, amount) else lhs.shr(allocator, amount),
    };
}

fn parseJsNumber(bytes: []const u8) f64 {
    return core.value_format.parseJsNumber(bytes);
}

fn appendArrayString(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), object: *core.Object) AppendStringError!void {
    var index: u32 = 0;
    while (index < object.arrayLength()) : (index += 1) {
        if (index != 0) try buffer.append(rt.memory.allocator, ',');
        const value = object.getProperty(core.atom.atomFromUInt32(index));
        defer value.free(rt);
        if (!value.isUndefined() and !value.isNull()) try appendValueString(rt, buffer, value);
    }
}

fn valuesEqual(a: core.JSValue, b: core.JSValue) bool {
    if (a.isBigInt() and b.isBigInt()) {
        return (compareBigIntValues(a, b) orelse return false) == .eq;
    }
    if (a.isNumber() and b.isNumber()) {
        const av = numberValue(a) orelse return false;
        const bv = numberValue(b) orelse return false;
        if (std.math.isNan(av) or std.math.isNan(bv)) return false;
        return av == bv;
    }
    if (a.asInt32()) |ai| {
        if (b.asInt32()) |bi| return ai == bi;
    }
    if (a.asBool()) |ab| {
        if (b.asBool()) |bb| return ab == bb;
    }
    if (a.isNull() or a.isUndefined()) return a.same(b);
    if (a.isString() and b.isString()) {
        if (a.same(b)) return true;
        return (compareStringValues(a, b) orelse 1) == 0;
    }
    return a.same(b);
}

fn compareBigIntValues(a: core.JSValue, b: core.JSValue) ?std.math.Order {
    var lhs_scratch: [2]bignum.Limb = undefined;
    var rhs_scratch: [2]bignum.Limb = undefined;
    const lhs = bigIntParts(a, &lhs_scratch) orelse return null;
    const rhs = bigIntParts(b, &rhs_scratch) orelse return null;
    return bignum.compareParts(lhs.negative, lhs.limbs, rhs.negative, rhs.limbs);
}

const BigIntParts = struct {
    negative: bool,
    limbs: []const bignum.Limb,
};

fn bigIntParts(value: core.JSValue, scratch: *[2]bignum.Limb) ?BigIntParts {
    if (value.asShortBigInt()) |short| {
        const signed: i128 = short;
        var magnitude: u128 = if (signed < 0) @intCast(-signed) else @intCast(signed);
        var len: usize = 0;
        while (magnitude != 0) {
            scratch[len] = @truncate(magnitude);
            magnitude >>= @bitSizeOf(bignum.Limb);
            len += 1;
        }
        return .{
            .negative = short < 0,
            .limbs = scratch[0..len],
        };
    }
    if (value.isBigInt() and value.refHeader() != null) {
        const header = value.refHeader().?;
        const big: *core.bigint.BigInt = @alignCast(@fieldParentPtr("header", header));
        return .{ .negative = big.value.negative, .limbs = big.value.limbs };
    }
    return null;
}

pub fn isHTMLDDA(value: core.JSValue) bool {
    return core.value_semantics.isHTMLDDA(value);
}

fn sameAbstractEqualityType(a: core.JSValue, b: core.JSValue) bool {
    if (a.isNumber() and b.isNumber()) return true;
    if (a.isBigInt() and b.isBigInt()) return true;
    if (a.isString() and b.isString()) return true;
    if (a.isBool() and b.isBool()) return true;
    if (a.isSymbol() and b.isSymbol()) return true;
    if (a.isObject() and b.isObject()) return true;
    if (a.isFunctionBytecode() and b.isFunctionBytecode()) return true;
    return a.tagOf() == b.tagOf();
}

fn numberLikeInt(value: core.JSValue) ?i32 {
    if (value.asInt32()) |int_value| return int_value;
    if (value.asBool()) |bool_value| return if (bool_value) 1 else 0;
    if (value.isNull()) return 0;
    if (value.isString()) {
        const string_value = value.asStringBody() orelse return null;
        return switch (string_value.resolveData()) {
            .latin1 => |bytes| parseIntString(bytes),
            .utf16 => null,
        };
    }
    return null;
}

fn parseIntString(bytes: []const u8) ?i32 {
    const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
    if (trimmed.len == 0) return 0;
    return std.fmt.parseInt(i32, trimmed, 10) catch null;
}

fn compareStringValues(a: core.JSValue, b: core.JSValue) ?i32 {
    const a_string = a.asStringBody() orelse return null;
    const b_string = b.asStringBody() orelse return null;
    return a_string.compare(b_string);
}

fn jsMathPow(lhs: f64, rhs: f64) f64 {
    if (!std.math.isFinite(rhs) and @abs(lhs) == 1) return std.math.nan(f64);
    return std.math.pow(f64, lhs, rhs);
}

fn powI32(lhs: i32, rhs: i32) i32 {
    if (rhs < 0) return 0;
    var out: i32 = 1;
    var i: i32 = 0;
    while (i < rhs) : (i += 1) out *= lhs;
    return out;
}

// Strict equality over runtime values (moved from the VM call runtime).

pub fn valuesStrictEqual(rt: *core.JSRuntime, a: core.JSValue, b: core.JSValue) !bool {
    if (a.isNumber() and b.isNumber()) {
        const av = numberValue(a) orelse return false;
        const bv = numberValue(b) orelse return false;
        if (std.math.isNan(av) or std.math.isNan(bv)) return false;
        return av == bv;
    }
    if (a.asBool()) |ab| {
        if (b.asBool()) |bb| return ab == bb;
    }
    if (a.isNull() or a.isUndefined()) return a.same(b);
    if (a.isBigInt() and b.isBigInt()) return a.sameValue(b);
    if (a.isString() and b.isString()) {
        if (a.same(b)) return true;
        var a_bytes = std.ArrayList(u8).empty;
        defer a_bytes.deinit(rt.memory.allocator);
        var b_bytes = std.ArrayList(u8).empty;
        defer b_bytes.deinit(rt.memory.allocator);
        try appendRawString(rt, &a_bytes, a);
        try appendRawString(rt, &b_bytes, b);
        return std.mem.eql(u8, a_bytes.items, b_bytes.items);
    }
    return a.same(b);
}

const bytecode = @import("../bytecode/root.zig");
const core = @import("../core/root.zig");
const dtoa = @import("../libs/dtoa.zig");
const bignum = @import("../libs/bignum.zig");
const symbol_builtin = @import("../builtins/symbol.zig");
const std = @import("std");

pub const AppendStringError = error{
    OutOfMemory,
    TypeError,
    InvalidRadix,
    NoSpaceLeft,
};

pub fn binary(rt: *core.Runtime, op: u8, a: core.Value, b: core.Value) !core.Value {
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
        return core.Value.int32(out);
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
    return core.Value.int32(out);
}

pub fn compare(rt: *core.Runtime, op: u8, a: core.Value, b: core.Value) !core.Value {
    if (a.isString() and b.isString()) {
        const cmp: i32 = if (a.same(b)) 0 else compareStringValues(a, b) orelse return error.TypeError;
        const out = switch (op) {
            bytecode.opcode.op.lt => cmp < 0,
            bytecode.opcode.op.lte => cmp <= 0,
            bytecode.opcode.op.gt => cmp > 0,
            bytecode.opcode.op.gte => cmp >= 0,
            else => false,
        };
        return core.Value.boolean(out);
    }
    if (a.isBigInt() or b.isBigInt()) {
        const cmp = try compareBigIntRelational(rt, a, b) orelse return core.Value.boolean(false);
        const out = switch (op) {
            bytecode.opcode.op.lt => cmp == .lt,
            bytecode.opcode.op.lte => cmp == .lt or cmp == .eq,
            bytecode.opcode.op.gt => cmp == .gt,
            bytecode.opcode.op.gte => cmp == .gt or cmp == .eq,
            else => unreachable,
        };
        return core.Value.boolean(out);
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
    return core.Value.boolean(out);
}

fn compareBigIntRelational(rt: *core.Runtime, a: core.Value, b: core.Value) !?std.math.Order {
    if (a.isBigInt() and b.isBigInt()) {
        return compareBigIntValues(a, b) orelse error.TypeError;
    }
    if (a.isBigInt()) return compareBigIntToNonBigInt(rt, a, b);
    const order = try compareBigIntToNonBigInt(rt, b, a) orelse return null;
    return reverseOrder(order);
}

fn compareBigIntToNonBigInt(rt: *core.Runtime, bigint_value: core.Value, other: core.Value) !?std.math.Order {
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

pub fn parseStringToBigInt(rt: *core.Runtime, value: core.Value) !bignum.BigInt {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(rt.memory.allocator);
    try appendRawString(rt, &buffer, value);
    const trimmed = std.mem.trim(u8, buffer.items, " \t\r\n");
    if (trimmed.len == 0) return bignum.BigInt{ .allocator = rt.memory.allocator };
    return bignum.parseAutoAlloc(rt.memory.allocator, trimmed);
}

fn compareBigIntToNumber(rt: *core.Runtime, bigint_value: core.Value, number: f64) !?std.math.Order {
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

pub fn bigIntEqualsNumber(rt: *core.Runtime, bigint_value: core.Value, number: f64) !bool {
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

pub fn integerNumberToBigIntValue(rt: *core.Runtime, number: f64) !core.Value {
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

pub fn strictEqual(a: core.Value, b: core.Value) core.Value {
    return core.Value.boolean(valuesEqual(a, b));
}

pub fn strictNotEqual(a: core.Value, b: core.Value) core.Value {
    return core.Value.boolean(!valuesEqual(a, b));
}

pub fn length(rt: *core.Runtime, value: core.Value) !core.Value {
    if (value.isString()) {
        const header = value.refHeader() orelse return error.TypeError;
        const string_value: *core.string.String = @fieldParentPtr("header", header);
        return core.Value.int32(@intCast(string_value.len()));
    }
    if (value.isObject()) {
        const header = value.refHeader() orelse return error.TypeError;
        const object_value: *core.Object = @fieldParentPtr("header", header);
        if (object_value.is_array) {
            if (object_value.length <= @as(u32, @intCast(std.math.maxInt(i32)))) {
                return core.Value.int32(@intCast(object_value.length));
            }
            return core.Value.float64(@floatFromInt(object_value.length));
        }
        const length_value = object_value.getProperty(core.atom.ids.length);
        if (!length_value.isUndefined()) return length_value;
        length_value.free(rt);
        return core.Value.undefinedValue();
    }
    if (value.isNull() or value.isUndefined()) return error.TypeError;
    return core.Value.undefinedValue();
}

pub fn unary(rt: *core.Runtime, op: u8, value: core.Value) !core.Value {
    if (op == bytecode.opcode.op.not and !value.isBigInt()) {
        return core.Value.int32(~try toInt32(rt, value));
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
    return core.Value.int32(out);
}

pub fn factorial(value: core.Value) !core.Value {
    const n = value.asInt32() orelse return error.TypeError;
    if (n < 0) return error.RangeError;
    var out: i32 = 1;
    var i: i32 = 2;
    while (i <= n) : (i += 1) out *= i;
    return core.Value.int32(out);
}

pub fn typeOf(rt: *core.Runtime, value: core.Value) !core.Value {
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

pub fn logical(op: u8, a: core.Value, b: core.Value) core.Value {
    const out = switch (op) {
        bytecode.opcode.op.@"and" => if (isTruthy(a)) b else a,
        bytecode.opcode.op.@"or" => if (isTruthy(a)) a else b,
        bytecode.opcode.op.is_undefined_or_null => if (a.isNull() or a.isUndefined()) b else a,
        else => unreachable,
    };
    return out.dup();
}

pub fn toStringValue(rt: *core.Runtime, value: core.Value) !core.Value {
    if (try primitiveToStringValueFast(rt, value)) |fast| return fast;
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(rt.memory.allocator);
    try appendValueString(rt, &buffer, value);
    return createStringValue(rt, buffer.items);
}

fn primitiveToStringValueFast(rt: *core.Runtime, value: core.Value) !?core.Value {
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
        if (isNegativeZero(float_value)) return try createAsciiStringValue(rt, "0");
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

pub fn toNumberValue(rt: *core.Runtime, value: core.Value) !core.Value {
    if (value.isSymbol()) return error.TypeError;
    if (numberValue(value)) |number| return numberToValue(number);
    if (value.asBool()) |bool_value| return core.Value.int32(if (bool_value) 1 else 0);
    if (value.isNull()) return core.Value.int32(0);
    if (value.isString()) {
        const str = stringObject(value).?;
        switch (str.resolveData()) {
            .latin1 => |bytes| {
                if (fastStringToInt32(bytes)) |val| return core.Value.int32(val);
                return numberToValue(parseJsNumber(bytes));
            },
            .utf16 => {},
        }
        var bytes = std.ArrayList(u8).empty;
        defer bytes.deinit(rt.memory.allocator);
        try appendRawString(rt, &bytes, value);
        return numberToValue(parseJsNumber(bytes.items));
    }
    return core.Value.float64(std.math.nan(f64));
}

pub fn toBooleanValue(value: core.Value) core.Value {
    return core.Value.boolean(isTruthy(value));
}

pub fn asN(rt: *core.Runtime, bits_value: core.Value, bigint_value: core.Value, unsigned: bool) !core.Value {
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

pub fn numberToValue(value: f64) core.Value {
    if (value >= -2147483648 and value <= 2147483647) {
        const int_val: i32 = @intFromFloat(value);
        if (@as(f64, @floatFromInt(int_val)) == value and !isNegativeZero(value)) {
            return core.Value.int32(int_val);
        }
    }
    return core.Value.float64(value);
}

pub fn createStringValue(rt: *core.Runtime, bytes: []const u8) !core.Value {
    if (bytes.len == 0) {
        const cached = try rt.emptyString();
        return cached.value().dup();
    }
    const str = if (isAsciiBytes(bytes))
        try core.string.String.createAscii(rt, bytes)
    else
        try core.string.String.createUtf8(rt, bytes);
    return str.value();
}

fn createAsciiStringValue(rt: *core.Runtime, bytes: []const u8) !core.Value {
    if (bytes.len == 0) {
        const cached = try rt.emptyString();
        return cached.value().dup();
    }
    return (try core.string.String.createAscii(rt, bytes)).value();
}

fn isAsciiBytes(bytes: []const u8) bool {
    for (bytes) |byte| {
        if (byte >= 0x80) return false;
    }
    return true;
}

pub fn createBigIntI128(rt: *core.Runtime, value: i128) !core.Value {
    if (value >= std.math.minInt(i64) and value <= std.math.maxInt(i64)) {
        return core.Value.shortBigInt(@intCast(value));
    }
    const big = try core.bigint.BigInt.create(rt, value);
    return big.valueRef();
}

pub fn createBigIntOwned(rt: *core.Runtime, value: bignum.BigInt) !core.Value {
    var owned = value;
    errdefer owned.deinit();
    if (owned.toI64()) |val| {
        owned.deinit();
        return core.Value.shortBigInt(val);
    }
    const big = try core.bigint.BigInt.createFromOwned(rt, owned);
    return big.valueRef();
}

pub fn createBigIntValue(rt: *core.Runtime, value: bignum.BigInt) !core.Value {
    if (value.toI64()) |val| {
        return core.Value.shortBigInt(val);
    }
    const big = try core.bigint.BigInt.createFromBigInt(rt, value);
    return big.valueRef();
}

pub fn numberValue(value: core.Value) ?f64 {
    if (value.tag == core.Tag.int) return @floatFromInt(value.asInt32().?);
    if (value.tag == core.Tag.float64) return value.asFloat64().?;
    return null;
}

pub fn bigIntToNumber(rt: *core.Runtime, value: core.Value) !f64 {
    var bigint = try cloneBigIntValue(rt, value);
    defer bigint.deinit();
    const text = try bigint.formatBase10Alloc(rt.memory.allocator);
    defer rt.memory.allocator.free(text);
    return std.fmt.parseFloat(f64, text);
}

pub fn toIntegerOrInfinity(rt: *core.Runtime, value: core.Value) !f64 {
    if (numberValue(value)) |number| return number;
    if (value.asBool()) |bool_value| return if (bool_value) 1 else 0;
    if (value.isNull()) return 0;
    if (value.isUndefined()) return std.math.nan(f64);

    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(rt.memory.allocator);
    try appendValueString(rt, &buffer, value);
    return parseJsNumber(buffer.items);
}

pub fn toIndexUsize(rt: *core.Runtime, value: core.Value) !usize {
    const number = try toIntegerOrInfinity(rt, value);
    if (std.math.isNan(number)) return 0;
    if (!std.math.isFinite(number)) return error.RangeError;
    const truncated = @trunc(number);
    if (truncated < 0) return error.RangeError;
    if (truncated == 0) return 0;
    return @intFromFloat(truncated);
}

pub fn toBigIntValue(rt: *core.Runtime, value: core.Value) !bignum.BigInt {
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

pub fn bigIntFromValueBorrowed(rt: *core.Runtime, value: core.Value) !bignum.BigInt {
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

pub fn cloneBigIntValue(rt: *core.Runtime, value: core.Value) !bignum.BigInt {
    if (value.asShortBigInt()) |big_int| return bignum.BigInt.fromIntAlloc(rt.memory.allocator, big_int);
    if (value.isBigInt() and value.refHeader() != null) {
        const header = value.refHeader().?;
        const big: *core.bigint.BigInt = @alignCast(@fieldParentPtr("header", header));
        return big.value.cloneWithAllocator(rt.memory.allocator);
    }
    return error.TypeError;
}

pub fn isTruthy(value: core.Value) bool {
    if (isHTMLDDA(value)) return false;
    if (value.isUndefined() or value.isNull()) return false;
    if (value.asBool()) |bool_value| return bool_value;
    if (value.asInt32()) |int_value| return int_value != 0;
    if (value.asFloat64()) |float_value| return float_value != 0 and !std.math.isNan(float_value);
    if (value.asShortBigInt()) |bigint_value| return bigint_value != 0;
    if (value.isBigInt()) {
        var zero_scratch: [2]bignum.Limb = undefined;
        const parts = bigIntParts(value, &zero_scratch) orelse return true;
        return !(parts.limbs.len == 0 or (parts.limbs.len == 1 and parts.limbs[0] == 0));
    }
    if (value.isString()) {
        const header = value.refHeader() orelse return false;
        const string_value: *core.string.String = @fieldParentPtr("header", header);
        return string_value.len() != 0;
    }
    return true;
}

pub fn isFunctionObject(value: core.Value) bool {
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

fn proxyTargetIsFunction(value: core.Value) bool {
    const header = value.refHeader() orelse return false;
    if (!value.isObject()) return false;
    const object: *core.Object = @fieldParentPtr("header", header);
    const target = object.proxyTarget() orelse return false;
    return target.isFunctionBytecode() or isFunctionObject(target);
}

pub fn atomNameEql(rt: *core.Runtime, atom_id: core.Atom, name: []const u8) bool {
    return if (rt.atoms.name(atom_id)) |atom_name| std.mem.eql(u8, atom_name, name) else false;
}

pub fn appendRawString(rt: *core.Runtime, buffer: *std.ArrayList(u8), value: core.Value) !void {
    const header = value.refHeader() orelse return;
    const string_value: *core.string.String = @fieldParentPtr("header", header);
    switch (string_value.resolveData()) {
        .latin1 => |bytes| try buffer.appendSlice(rt.memory.allocator, bytes),
        .utf16 => |units| try appendUtf16AsUtf8(rt, buffer, units),
    }
}

pub fn appendValueString(rt: *core.Runtime, buffer: *std.ArrayList(u8), value: core.Value) AppendStringError!void {
    if (value.asSymbolAtom()) |atom_id| {
        const description = symbol_builtin.description(&rt.atoms, atom_id) orelse "";
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
        } else if (isNegativeZero(float_value)) {
            try buffer.append(rt.memory.allocator, '0');
        } else {
            var float_buf: [64]u8 = undefined;
            const printed = try formatFiniteNumber(&float_buf, float_value);
            try buffer.appendSlice(rt.memory.allocator, printed);
        }
    } else if (value.asShortBigInt()) |bigint_value| {
        var bigint_buf: [32]u8 = undefined;
        const printed = dtoa.formatInt64(&bigint_buf, bigint_value);
        try buffer.appendSlice(rt.memory.allocator, printed);
    } else if (value.isBigInt()) {
        var big = try cloneBigIntValue(rt, value);
        defer big.deinit();
        const printed = try big.formatBase10Alloc(rt.memory.allocator);
        defer rt.memory.allocator.free(printed);
        try buffer.appendSlice(rt.memory.allocator, printed);
    } else if (value.asBool()) |bool_value| {
        try buffer.appendSlice(rt.memory.allocator, if (bool_value) "true" else "false");
    } else if (value.isUndefined()) {
        try buffer.appendSlice(rt.memory.allocator, "undefined");
    } else if (value.isNull()) {
        try buffer.appendSlice(rt.memory.allocator, "null");
    } else if (value.isString()) {
        const header = value.refHeader() orelse return;
        const string_value: *core.string.String = @fieldParentPtr("header", header);
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
        } else if (object_value.is_array) {
            try appendArrayString(rt, buffer, object_value);
        } else {
            try buffer.appendSlice(rt.memory.allocator, "[object Object]");
        }
    } else {
        try buffer.appendSlice(rt.memory.allocator, "[object Object]");
    }
}

pub fn formatFiniteNumber(buffer: []u8, value: f64) ![]const u8 {
    if (formatSimpleFiniteDecimal(buffer, value)) |text| return text;
    return dtoa.formatNumber(buffer, value);
}

fn formatSimpleFiniteDecimal(buffer: []u8, value: f64) ?[]const u8 {
    if (!std.math.isFinite(value)) return null;
    if (value == 0) return null;
    const abs_value = @abs(value);
    if (abs_value < 1e-6 or abs_value >= 1e21) return null;

    const scaled = value * 10.0;
    if (!std.math.isFinite(scaled)) return null;
    if (@abs(scaled) > 9007199254740991.0) return null;
    if (@trunc(scaled) != scaled) return null;

    const scaled_int: i64 = @intFromFloat(scaled);
    const sign_len: usize = if (scaled_int < 0) 1 else 0;
    const magnitude: u64 = @intCast(if (scaled_int < 0) -scaled_int else scaled_int);
    const integer = magnitude / 10;
    const fraction: u8 = @intCast(magnitude % 10);

    if (fraction == 0) {
        const needed = sign_len + 20;
        if (buffer.len < needed) return null;
        var temp: [32]u8 = undefined;
        const digits = dtoa.formatInt64(&temp, @intCast(integer));
        if (sign_len + digits.len > buffer.len) return null;
        var index: usize = 0;
        if (scaled_int < 0) {
            buffer[index] = '-';
            index += 1;
        }
        @memcpy(buffer[index .. index + digits.len], digits);
        return buffer[0 .. index + digits.len];
    }

    var temp: [32]u8 = undefined;
    const digits = dtoa.formatInt64(&temp, @intCast(integer));
    const total_len = sign_len + digits.len + 2;
    if (total_len > buffer.len) return null;
    var index: usize = 0;
    if (scaled_int < 0) {
        buffer[index] = '-';
        index += 1;
    }
    @memcpy(buffer[index .. index + digits.len], digits);
    index += digits.len;
    buffer[index] = '.';
    buffer[index + 1] = '0' + fraction;
    return buffer[0..total_len];
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

fn appendUtf8CodePoint(rt: *core.Runtime, buffer: *std.ArrayList(u8), cp: u32) !void {
    if (cp <= 0x7f) {
        try buffer.append(rt.memory.allocator, @intCast(cp));
    } else if (cp <= 0x7ff) {
        try buffer.append(rt.memory.allocator, @intCast(0xc0 | (cp >> 6)));
        try buffer.append(rt.memory.allocator, @intCast(0x80 | (cp & 0x3f)));
    } else if (cp <= 0xffff) {
        try buffer.append(rt.memory.allocator, @intCast(0xe0 | (cp >> 12)));
        try buffer.append(rt.memory.allocator, @intCast(0x80 | ((cp >> 6) & 0x3f)));
        try buffer.append(rt.memory.allocator, @intCast(0x80 | (cp & 0x3f)));
    } else {
        try buffer.append(rt.memory.allocator, @intCast(0xf0 | (cp >> 18)));
        try buffer.append(rt.memory.allocator, @intCast(0x80 | ((cp >> 12) & 0x3f)));
        try buffer.append(rt.memory.allocator, @intCast(0x80 | ((cp >> 6) & 0x3f)));
        try buffer.append(rt.memory.allocator, @intCast(0x80 | (cp & 0x3f)));
    }
}

fn appendUtf16AsUtf8(rt: *core.Runtime, buffer: *std.ArrayList(u8), units: []const u16) !void {
    var index: usize = 0;
    while (index < units.len) : (index += 1) {
        const unit = units[index];
        if (unit >= 0xd800 and unit <= 0xdbff and index + 1 < units.len) {
            const next = units[index + 1];
            if (next >= 0xdc00 and next <= 0xdfff) {
                const high: u32 = @intCast(unit - 0xd800);
                const low: u32 = @intCast(next - 0xdc00);
                try appendUtf8CodePoint(rt, buffer, 0x10000 + (high << 10) + low);
                index += 1;
                continue;
            }
        }
        try appendUtf8CodePoint(rt, buffer, unit);
    }
}

fn binaryBigInt(rt: *core.Runtime, op: u8, a: core.Value, b: core.Value) !core.Value {
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

    if (op == bytecode.opcode.op.add and a.isBigInt() and a.refHeader() != null and a.refHeader().?.rc == 1) {
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

fn addPositiveShortToBigInt(rt: *core.Runtime, value: core.Value, addend: bignum.Limb) !?core.Value {
    if (!value.isBigInt()) return null;
    const header = value.refHeader() orelse return null;
    const big: *core.bigint.BigInt = @alignCast(@fieldParentPtr("header", header));
    if (big.value.negative) return null;

    var out = try big.value.cloneWithAllocator(rt.memory.allocator);
    errdefer out.deinit();
    try out.addPositiveSmallInPlace(addend);
    return try createBigIntOwned(rt, out);
}

pub fn shortBigIntBinary(op: u8, lhs: i64, rhs: i64) ?core.Value {
    return switch (op) {
        bytecode.opcode.op.add => shortBigIntAdd(lhs, rhs),
        bytecode.opcode.op.sub => shortBigIntSub(lhs, rhs),
        bytecode.opcode.op.mul => shortBigIntMul(lhs, rhs),
        bytecode.opcode.op.@"and" => core.Value.shortBigInt(lhs & rhs),
        bytecode.opcode.op.xor => core.Value.shortBigInt(lhs ^ rhs),
        bytecode.opcode.op.@"or" => core.Value.shortBigInt(lhs | rhs),
        else => null,
    };
}

pub fn shortBigIntUnary(op: u8, value: i64) ?core.Value {
    return switch (op) {
        bytecode.opcode.op.neg => if (value == std.math.minInt(i64)) null else core.Value.shortBigInt(-value),
        bytecode.opcode.op.dec, bytecode.opcode.op.post_dec => shortBigIntSub(value, 1),
        bytecode.opcode.op.inc, bytecode.opcode.op.post_inc => shortBigIntAdd(value, 1),
        bytecode.opcode.op.not => core.Value.shortBigInt(~value),
        else => null,
    };
}

fn shortBigIntAdd(lhs: i64, rhs: i64) ?core.Value {
    const result = @addWithOverflow(lhs, rhs);
    if (result[1] != 0) return null;
    return core.Value.shortBigInt(result[0]);
}

fn shortBigIntSub(lhs: i64, rhs: i64) ?core.Value {
    const result = @subWithOverflow(lhs, rhs);
    if (result[1] != 0) return null;
    return core.Value.shortBigInt(result[0]);
}

fn shortBigIntMul(lhs: i64, rhs: i64) ?core.Value {
    const result = @mulWithOverflow(lhs, rhs);
    if (result[1] != 0) return null;
    return core.Value.shortBigInt(result[0]);
}

fn binaryNumber(rt: *core.Runtime, op: u8, a: core.Value, b: core.Value) !core.Value {
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
    return numberToValue(out);
}

fn toInt32(rt: *core.Runtime, value: core.Value) !i32 {
    const number = try toIntegerOrInfinity(rt, value);
    if (!std.math.isFinite(number) or std.math.isNan(number)) return 0;
    const integer = if (number < 0) -@floor(@abs(number)) else @floor(number);
    const wrapped: u32 = @intFromFloat(@mod(integer, 4294967296));
    return @bitCast(wrapped);
}

fn stringAdd(rt: *core.Runtime, a: core.Value, b: core.Value) !core.Value {
    if (a.isSymbol() or b.isSymbol()) return error.TypeError;
    if (a.isString() and b.tag == core.Tag.int) {
        if (try stringAddStringInt(rt, a, b.asInt32().?, .suffix)) |out| return out;
    }
    if (a.tag == core.Tag.int and b.isString()) {
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

fn stringAddStringInt(rt: *core.Runtime, string_value: core.Value, int_value: i32, position: StringIntPosition) !?core.Value {
    const string = stringObject(string_value) orelse return null;
    if (string.len() == 0) {
        return try toStringValue(rt, core.Value.int32(int_value));
    }

    const string_bytes = string.borrowLatin1() orelse return null;
    if (int_value >= 0 and int_value < 256) {
        const cached = try rt.smallIntString(@intCast(int_value));
        const digits = cached.borrowLatin1() orelse return null;

        if (position == .suffix) {
            if (string_value.refHeader()) |header| {
                if (header.rc == 1 and string.atom_id == null) {
                    if (try string.appendLatin1InPlace(rt, digits)) {
                        return string_value.dup();
                    }
                }
            }
        }

        const out = switch (position) {
            .prefix => try core.string.String.createLatin1Concat(rt, digits, string_bytes),
            .suffix => try core.string.String.createLatin1Concat(rt, string_bytes, digits),
        };
        return out.value();
    }

    var int_buf: [16]u8 = undefined;
    const digits = formatI32Decimal(&int_buf, int_value);

    const out = switch (position) {
        .prefix => try core.string.String.createLatin1Concat(rt, digits, string_bytes),
        .suffix => try core.string.String.createLatin1Concat(rt, string_bytes, digits),
    };
    return out.value();
}

fn formatI32Decimal(buffer: *[16]u8, value: i32) []const u8 {
    if (value == 0) {
        buffer[buffer.len - 1] = '0';
        return buffer[buffer.len - 1 ..];
    }

    var index = buffer.len;
    var magnitude: u32 = if (value < 0)
        @as(u32, @intCast(-(value + 1))) + 1
    else
        @intCast(value);
    while (magnitude != 0) {
        index -= 1;
        buffer[index] = '0' + @as(u8, @intCast(magnitude % 10));
        magnitude /= 10;
    }
    if (value < 0) {
        index -= 1;
        buffer[index] = '-';
    }
    return buffer[index..];
}

fn stringAddStrings(rt: *core.Runtime, a: core.Value, b: core.Value) !core.Value {
    const a_string = stringObject(a) orelse return error.TypeError;
    const b_string = stringObject(b) orelse return error.TypeError;
    const a_len = a_string.len();
    const b_len = b_string.len();
    if (a_len == 0) return b.dup();
    if (b_len == 0) return a.dup();
    if (a.refHeader()) |header| {
        if (header.rc == 1 and try appendStringInPlace(rt, a_string, b_string)) {
            return a.dup();
        }
    }
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
    try appendStringUtf16Units(rt, &units, a_string.*);
    try appendStringUtf16Units(rt, &units, b_string.*);
    return (try core.string.String.createUtf16(rt, units.items)).value();
}

fn appendStringInPlace(rt: *core.Runtime, lhs_string: *core.string.String, rhs_string: *core.string.String) !bool {
    return switch (rhs_string.resolveData()) {
        .latin1 => |rhs_bytes| switch (lhs_string.resolveData()) {
            .latin1 => try lhs_string.appendLatin1InPlace(rt, rhs_bytes),
            .utf16 => try lhs_string.appendLatin1ToUtf16InPlace(rt, rhs_bytes),
        },
        .utf16 => |rhs_units| switch (lhs_string.resolveData()) {
            .latin1 => try lhs_string.appendUtf16WidenInPlace(rt, rhs_units),
            .utf16 => try lhs_string.appendUtf16InPlace(rt, rhs_units),
        },
    };
}

pub fn tryAppendStringInPlace(rt: *core.Runtime, lhs: core.Value, rhs: core.Value, max_ref_count: usize) !bool {
    const lhs_header = lhs.refHeader() orelse return false;
    if (lhs_header.rc > max_ref_count) return false;
    const lhs_string = stringObject(lhs) orelse return false;
    const rhs_string = stringObject(rhs) orelse return false;
    return try appendStringInPlace(rt, lhs_string, rhs_string);
}

pub fn tryAppendLatin1StringInPlace(rt: *core.Runtime, lhs: core.Value, rhs: core.Value, max_ref_count: usize) !bool {
    return tryAppendStringInPlace(rt, lhs, rhs, max_ref_count);
}

pub fn tryAppendLatin1AtomRepeatedInPlace(rt: *core.Runtime, lhs: core.Value, atom_id: core.Atom, repeat_count: usize, max_ref_count: usize) !bool {
    const lhs_header = lhs.refHeader() orelse return false;
    if (@as(usize, @intCast(lhs_header.rc)) > max_ref_count) return false;
    const lhs_string = stringObject(lhs) orelse return false;
    if (rt.atoms.kind(atom_id) != .string) return false;
    const suffix = rt.atoms.name(atom_id) orelse return false;
    for (suffix) |byte| {
        if (byte > 0x7f) return false;
    }
    return try lhs_string.appendLatin1RepeatedInPlace(rt, suffix, repeat_count);
}

pub fn latin1AtomRepeatedConcatValue(rt: *core.Runtime, lhs: core.Value, atom_id: core.Atom, repeat_count: usize) !?core.Value {
    const lhs_string = stringObject(lhs) orelse return null;
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
    const out = try core.string.String.createLatin1RepeatedConcatWithSeed(rt, lhs_bytes, suffix, repeat_count, lhs_string.hash);
    return out.value();
}

fn percentHexConcat(rt: *core.Runtime, a: []const u8, b: []const u8) !?core.Value {
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
    if (byte >= '0' and byte <= '9') return byte - '0';
    if (byte >= 'A' and byte <= 'F') return byte - 'A' + 10;
    return null;
}

fn stringObject(value: core.Value) ?*core.string.String {
    const header = value.refHeader() orelse return null;
    if (!value.isString()) return null;
    return @fieldParentPtr("header", header);
}

fn appendStringLatin1Units(rt: *core.Runtime, out: *std.ArrayList(u8), string: core.string.String) !void {
    switch (string.resolveData()) {
        .latin1 => |bytes| try out.appendSlice(rt.memory.allocator, bytes),
        .utf16 => |units| try appendUtf16AsUtf8(rt, out, units),
    }
}

fn stringLatin1IsAscii(string: core.string.String) bool {
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

fn appendStringUtf16Units(rt: *core.Runtime, out: *std.ArrayList(u16), string: core.string.String) !void {
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

fn isNegativeZero(value: f64) bool {
    return value == 0 and std.math.isNegativeInf(1.0 / value);
}

fn parseJsNumber(bytes: []const u8) f64 {
    const trimmed = trimJsWhitespace(bytes);
    if (trimmed.len == 0) return 0;
    if (std.mem.indexOfScalar(u8, trimmed, '_') != null) return std.math.nan(f64);
    if (hasSignedRadixPrefix(trimmed)) return std.math.nan(f64);
    if (std.mem.eql(u8, trimmed, "Infinity") or std.mem.eql(u8, trimmed, "+Infinity")) return std.math.inf(f64);
    if (std.mem.eql(u8, trimmed, "-Infinity")) return -std.math.inf(f64);
    if (trimmed.len >= 2 and trimmed[0] == '0' and (trimmed[1] == 'x' or trimmed[1] == 'X')) {
        const parsed = std.fmt.parseUnsigned(u64, trimmed[2..], 16) catch return std.math.nan(f64);
        return @floatFromInt(parsed);
    }
    if (trimmed.len >= 2 and trimmed[0] == '0' and (trimmed[1] == 'o' or trimmed[1] == 'O')) {
        const parsed = std.fmt.parseUnsigned(u64, trimmed[2..], 8) catch return std.math.nan(f64);
        return @floatFromInt(parsed);
    }
    if (trimmed.len >= 2 and trimmed[0] == '0' and (trimmed[1] == 'b' or trimmed[1] == 'B')) {
        const parsed = std.fmt.parseUnsigned(u64, trimmed[2..], 2) catch return std.math.nan(f64);
        return @floatFromInt(parsed);
    }
    const parsed = std.fmt.parseFloat(f64, trimmed) catch return std.math.nan(f64);
    if (std.math.isInf(parsed) and beginsWithAsciiAlphaAfterSign(trimmed)) return std.math.nan(f64);
    return parsed;
}

fn trimJsWhitespace(bytes: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = bytes.len;
    while (start < end) {
        const width = jsWhitespacePrefixLen(bytes[start..end]) orelse break;
        start += width;
    }
    while (end > start) {
        const width = jsWhitespaceSuffixLen(bytes[start..end]) orelse break;
        end -= width;
    }
    return bytes[start..end];
}

fn jsWhitespacePrefixLen(bytes: []const u8) ?usize {
    if (bytes.len == 0) return null;
    switch (bytes[0]) {
        0x09...0x0d, 0x20 => return 1,
        0xa0 => return 1,
        0xc2 => if (startsWith(bytes, &.{ 0xc2, 0xa0 })) return 2,
        0xe1 => if (startsWith(bytes, &.{ 0xe1, 0x9a, 0x80 })) return 3,
        0xe2 => {
            if (bytes.len >= 3 and bytes[1] == 0x80 and ((bytes[2] >= 0x80 and bytes[2] <= 0x8a) or bytes[2] == 0xa8 or bytes[2] == 0xa9 or bytes[2] == 0xaf)) return 3;
            if (startsWith(bytes, &.{ 0xe2, 0x81, 0x9f })) return 3;
        },
        0xe3 => if (startsWith(bytes, &.{ 0xe3, 0x80, 0x80 })) return 3,
        0xef => if (startsWith(bytes, &.{ 0xef, 0xbb, 0xbf })) return 3,
        else => {},
    }
    return null;
}

fn jsWhitespaceSuffixLen(bytes: []const u8) ?usize {
    if (bytes.len == 0) return null;
    const last = bytes[bytes.len - 1];
    if ((last >= 0x09 and last <= 0x0d) or last == 0x20) return 1;
    if (endsWith(bytes, &.{ 0xc2, 0xa0 })) return 2;
    if (last == 0xa0) return 1;
    if (endsWith(bytes, &.{ 0xe1, 0x9a, 0x80 })) return 3;
    if (endsWith(bytes, &.{ 0xe2, 0x81, 0x9f })) return 3;
    if (endsWith(bytes, &.{ 0xe3, 0x80, 0x80 })) return 3;
    if (endsWith(bytes, &.{ 0xef, 0xbb, 0xbf })) return 3;
    if (bytes.len >= 3 and bytes[bytes.len - 3] == 0xe2 and bytes[bytes.len - 2] == 0x80) {
        const tail = bytes[bytes.len - 1];
        if ((tail >= 0x80 and tail <= 0x8a) or tail == 0xa8 or tail == 0xa9 or tail == 0xaf) return 3;
    }
    return null;
}

fn startsWith(bytes: []const u8, prefix: []const u8) bool {
    return bytes.len >= prefix.len and std.mem.eql(u8, bytes[0..prefix.len], prefix);
}

fn endsWith(bytes: []const u8, suffix: []const u8) bool {
    return bytes.len >= suffix.len and std.mem.eql(u8, bytes[bytes.len - suffix.len ..], suffix);
}

fn hasSignedRadixPrefix(bytes: []const u8) bool {
    return bytes.len >= 3 and (bytes[0] == '+' or bytes[0] == '-') and bytes[1] == '0' and
        (bytes[2] == 'x' or bytes[2] == 'X' or bytes[2] == 'o' or bytes[2] == 'O' or bytes[2] == 'b' or bytes[2] == 'B');
}

fn beginsWithAsciiAlphaAfterSign(bytes: []const u8) bool {
    const index: usize = if (bytes.len > 0 and (bytes[0] == '+' or bytes[0] == '-')) 1 else 0;
    return index < bytes.len and ((bytes[index] >= 'a' and bytes[index] <= 'z') or (bytes[index] >= 'A' and bytes[index] <= 'Z'));
}

fn appendArrayString(rt: *core.Runtime, buffer: *std.ArrayList(u8), object: *core.Object) AppendStringError!void {
    var index: u32 = 0;
    while (index < object.length) : (index += 1) {
        if (index != 0) try buffer.append(rt.memory.allocator, ',');
        const value = object.getProperty(core.atom.atomFromUInt32(index));
        defer value.free(rt);
        if (!value.isUndefined() and !value.isNull()) try appendValueString(rt, buffer, value);
    }
}

fn valuesEqual(a: core.Value, b: core.Value) bool {
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

fn compareBigIntValues(a: core.Value, b: core.Value) ?std.math.Order {
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

fn bigIntParts(value: core.Value, scratch: *[2]bignum.Limb) ?BigIntParts {
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

pub fn isHTMLDDA(value: core.Value) bool {
    if (!value.isObject()) return false;
    const header = value.refHeader() orelse return false;
    const object: *core.Object = @fieldParentPtr("header", header);
    return object.is_html_dda;
}

fn sameAbstractEqualityType(a: core.Value, b: core.Value) bool {
    if (a.isNumber() and b.isNumber()) return true;
    if (a.isBigInt() and b.isBigInt()) return true;
    if (a.isString() and b.isString()) return true;
    if (a.isBool() and b.isBool()) return true;
    if (a.isSymbol() and b.isSymbol()) return true;
    if (a.isObject() and b.isObject()) return true;
    if (a.isFunctionBytecode() and b.isFunctionBytecode()) return true;
    return a.tag == b.tag;
}

fn numberLikeInt(value: core.Value) ?i32 {
    if (value.asInt32()) |int_value| return int_value;
    if (value.asBool()) |bool_value| return if (bool_value) 1 else 0;
    if (value.isNull()) return 0;
    if (value.isString()) {
        const header = value.refHeader() orelse return null;
        const string_value: *core.string.String = @fieldParentPtr("header", header);
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

fn compareStringValues(a: core.Value, b: core.Value) ?i32 {
    const a_header = a.refHeader() orelse return null;
    const b_header = b.refHeader() orelse return null;
    const a_string: *core.string.String = @fieldParentPtr("header", a_header);
    const b_string: *core.string.String = @fieldParentPtr("header", b_header);
    return a_string.compare(b_string.*);
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

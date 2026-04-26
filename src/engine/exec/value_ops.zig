const bytecode = @import("../bytecode/root.zig");
const core = @import("../core/root.zig");
const bignum = @import("../libs/bignum.zig");
const std = @import("std");

pub fn binary(rt: *core.Runtime, op: u8, a: core.Value, b: core.Value) !core.Value {
    if (op == bytecode.emitter.known.add and (a.isString() or b.isString())) return stringAdd(rt, a, b);
    if (a.isBigInt() or b.isBigInt()) {
        if (!a.isBigInt() or !b.isBigInt()) return error.TypeError;
        return binaryBigInt(rt, op, a, b);
    }
    if (a.isNumber() and b.isNumber()) return binaryNumber(op, a, b);
    const lhs = a.asInt32() orelse return error.UnsupportedValueOp;
    const rhs = b.asInt32() orelse return error.UnsupportedValueOp;
    const out = switch (op) {
        bytecode.emitter.known.mul => lhs * rhs,
        bytecode.emitter.known.div => @divTrunc(lhs, rhs),
        bytecode.emitter.known.mod => @rem(lhs, rhs),
        bytecode.emitter.known.add => lhs + rhs,
        bytecode.emitter.known.sub => lhs - rhs,
        bytecode.emitter.known.shl => lhs << @intCast(rhs & 31),
        bytecode.emitter.known.sar => lhs >> @intCast(rhs & 31),
        bytecode.emitter.known.shr => @as(i32, @bitCast(@as(u32, @bitCast(lhs)) >> @intCast(rhs & 31))),
        bytecode.emitter.known.bit_and => lhs & rhs,
        bytecode.emitter.known.bit_xor => lhs ^ rhs,
        bytecode.emitter.known.bit_or => lhs | rhs,
        bytecode.emitter.known.pow => powI32(lhs, rhs),
        else => unreachable,
    };
    return core.Value.int32(out);
}

pub fn compare(rt: *core.Runtime, op: u8, a: core.Value, b: core.Value) !core.Value {
    if (a.isString() and b.isString()) {
        const cmp = compareStringValues(a, b) orelse return error.UnsupportedValueOp;
        const out = switch (op) {
            253 => cmp < 0,
            254 => cmp <= 0,
            255 => cmp > 0,
            bytecode.emitter.known.gte => cmp >= 0,
            else => false,
        };
        return core.Value.boolean(out);
    }
    if (a.isBigInt() or b.isBigInt()) {
        if (!a.isBigInt() or !b.isBigInt()) return error.TypeError;
        var lhs = try cloneBigIntValue(rt, a);
        defer lhs.deinit();
        var rhs = try cloneBigIntValue(rt, b);
        defer rhs.deinit();
        const cmp = lhs.compare(rhs);
        const out = switch (op) {
            253 => cmp == .lt,
            254 => cmp == .lt or cmp == .eq,
            255 => cmp == .gt,
            bytecode.emitter.known.gte => cmp == .gt or cmp == .eq,
            else => return error.UnsupportedValueOp,
        };
        return core.Value.boolean(out);
    }
    const lhs = numberValue(a) orelse return error.UnsupportedValueOp;
    const rhs = numberValue(b) orelse return error.UnsupportedValueOp;
    const out = switch (op) {
        253 => lhs < rhs,
        254 => lhs <= rhs,
        255 => lhs > rhs,
        bytecode.emitter.known.gte => lhs >= rhs,
        else => false,
    };
    return core.Value.boolean(out);
}

pub fn strictEqual(a: core.Value, b: core.Value) core.Value {
    return core.Value.boolean(valuesEqual(a, b));
}

pub fn looseEqual(a: core.Value, b: core.Value) core.Value {
    return core.Value.boolean(valuesLooseEqual(a, b));
}

pub fn strictNotEqual(a: core.Value, b: core.Value) core.Value {
    return core.Value.boolean(!valuesEqual(a, b));
}

pub fn length(rt: *core.Runtime, value: core.Value) !core.Value {
    const header = value.refHeader() orelse return error.UnsupportedValueOp;
    if (value.isString()) {
        const string_value: *core.string.String = @fieldParentPtr("header", header);
        return core.Value.int32(@intCast(string_value.len()));
    }
    if (value.isObject()) {
        const object_value: *core.Object = @fieldParentPtr("header", header);
        if (object_value.is_array) return core.Value.int32(@intCast(object_value.length));
        const length_value = object_value.getProperty(core.atom.ids.length);
        if (!length_value.isUndefined()) return length_value;
        length_value.free(rt);
    }
    return error.UnsupportedValueOp;
}

pub fn unary(rt: *core.Runtime, op: u8, value: core.Value) !core.Value {
    if (value.asFloat64()) |float_value| {
        const out = switch (op) {
            224 => -float_value,
            225 => float_value,
            226, 228 => float_value - 1,
            227, 229 => float_value + 1,
            else => unreachable,
        };
        return numberToValue(out);
    }
    if (value.isBigInt()) {
        var out = try cloneBigIntValue(rt, value);
        defer out.deinit();
        switch (op) {
            224 => out.negative = !out.negative and !out.isZero(),
            225 => {},
            bytecode.emitter.known.bit_not => {
                var next = try out.bitNot(rt.memory.allocator);
                defer next.deinit();
                return createBigIntValue(rt, next);
            },
            else => return error.UnsupportedValueOp,
        }
        return createBigIntValue(rt, out);
    }
    const n = value.asInt32() orelse return error.UnsupportedValueOp;
    const out = switch (op) {
        224 => -n,
        225 => n,
        bytecode.emitter.known.bit_not => ~n,
        226, 228 => n - 1,
        227, 229 => n + 1,
        else => unreachable,
    };
    return core.Value.int32(out);
}

pub fn factorial(value: core.Value) !core.Value {
    const n = value.asInt32() orelse return error.UnsupportedValueOp;
    if (n < 0) return error.UnsupportedValueOp;
    var out: i32 = 1;
    var i: i32 = 2;
    while (i <= n) : (i += 1) out *= i;
    return core.Value.int32(out);
}

pub fn typeOf(rt: *core.Runtime, value: core.Value) !core.Value {
    const name: []const u8 = if (value.isNumber())
        "number"
    else if (value.isBool())
        "boolean"
    else if (value.isString())
        "string"
    else if (value.isUndefined())
        "undefined"
    else if (isFunctionObject(value))
        "function"
    else
        "object";
    return createStringValue(rt, name);
}

pub fn logical(op: u8, a: core.Value, b: core.Value) core.Value {
    const out = switch (op) {
        bytecode.emitter.known.logical_and => if (isTruthy(a)) b else a,
        bytecode.emitter.known.logical_or => if (isTruthy(a)) a else b,
        bytecode.emitter.known.nullish_coalesce => if (a.isNull() or a.isUndefined()) b else a,
        else => unreachable,
    };
    return out.dup();
}

pub fn toStringValue(rt: *core.Runtime, value: core.Value) !core.Value {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(rt.memory.allocator);
    try appendValueString(rt, &buffer, value);
    return createStringValue(rt, buffer.items);
}

pub fn toNumberValue(rt: *core.Runtime, value: core.Value) !core.Value {
    if (numberValue(value)) |number| return numberToValue(number);
    if (value.asBool()) |bool_value| return core.Value.int32(if (bool_value) 1 else 0);
    if (value.isNull()) return core.Value.int32(0);
    if (value.isString()) {
        var bytes = std.ArrayList(u8).empty;
        defer bytes.deinit(rt.memory.allocator);
        try appendRawString(rt, &bytes, value);
        const trimmed = std.mem.trim(u8, bytes.items, " \t\r\n");
        if (trimmed.len == 0) return core.Value.int32(0);
        if (std.fmt.parseFloat(f64, trimmed)) |parsed| return numberToValue(parsed) else |_| return core.Value.float64(std.math.nan(f64));
    }
    return core.Value.float64(std.math.nan(f64));
}

pub fn toBooleanValue(value: core.Value) core.Value {
    return core.Value.boolean(isTruthy(value));
}

pub fn asN(rt: *core.Runtime, bits_value: core.Value, bigint_value: core.Value, unsigned: bool) !core.Value {
    const bits_number = try toIntegerOrInfinity(rt, bits_value);
    if (std.math.isNan(bits_number) or bits_number == 0) return createBigIntI128(rt, 0);
    if (!std.math.isFinite(bits_number)) return error.RangeError;
    const truncated = @trunc(bits_number);
    if (truncated < 0) return error.RangeError;
    const bits: usize = @intFromFloat(truncated);
    if (bits == 0) return createBigIntI128(rt, 0);
    var input = try toBigIntValue(rt, bigint_value);
    defer input.deinit();
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
    if (std.math.isFinite(value) and @floor(value) == value and value >= @as(f64, @floatFromInt(std.math.minInt(i32))) and value <= @as(f64, @floatFromInt(std.math.maxInt(i32))) and !isNegativeZero(value)) {
        return core.Value.int32(@intFromFloat(value));
    }
    return core.Value.float64(value);
}

pub fn createStringValue(rt: *core.Runtime, bytes: []const u8) !core.Value {
    const str = try core.string.String.createUtf8(rt, bytes);
    return str.value();
}

pub fn createBigIntI128(rt: *core.Runtime, value: i128) !core.Value {
    const big = try core.bigint.BigInt.create(rt, value);
    return big.valueRef();
}

pub fn createBigIntValue(rt: *core.Runtime, value: bignum.BigInt) !core.Value {
    const big = try core.bigint.BigInt.createFromBigInt(rt, value);
    return big.valueRef();
}

pub fn numberValue(value: core.Value) ?f64 {
    if (value.asInt32()) |v| return @floatFromInt(v);
    if (value.asFloat64()) |v| return v;
    return null;
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
    if (value.asInt32()) |int_value| return bignum.BigInt.fromIntAlloc(rt.memory.allocator, int_value);
    if (value.asFloat64()) |float_value| {
        if (!std.math.isFinite(float_value) or @trunc(float_value) != float_value) return error.TypeError;
        return bignum.BigInt.fromIntAlloc(rt.memory.allocator, @intFromFloat(float_value));
    }
    if (value.asBool()) |bool_value| return bignum.BigInt.fromIntAlloc(rt.memory.allocator, if (bool_value) 1 else 0);

    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(rt.memory.allocator);
    if (value.isString() or value.isObject()) {
        try appendValueString(rt, &buffer, value);
        const trimmed = std.mem.trim(u8, buffer.items, " \t\r\n");
        if (trimmed.len == 0) return error.TypeError;
        return bignum.parseAutoAlloc(rt.memory.allocator, trimmed) catch error.TypeError;
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
    if (value.isUndefined() or value.isNull()) return false;
    if (value.asBool()) |bool_value| return bool_value;
    if (value.asInt32()) |int_value| return int_value != 0;
    if (value.asFloat64()) |float_value| return float_value != 0 and !std.math.isNan(float_value);
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
    return object.class_id == core.class.ids.c_function or
        object.class_id == core.class.ids.bytecode_function or
        object.class_id == core.class.ids.bound_function or
        object.class_id == core.class.ids.c_function_data or
        object.class_id == core.class.ids.c_closure;
}

pub fn atomNameEql(rt: *core.Runtime, atom_id: core.Atom, name: []const u8) bool {
    return if (rt.atoms.name(atom_id)) |atom_name| std.mem.eql(u8, atom_name, name) else false;
}

pub fn appendRawString(rt: *core.Runtime, buffer: *std.ArrayList(u8), value: core.Value) !void {
    const header = value.refHeader() orelse return;
    const string_value: *core.string.String = @fieldParentPtr("header", header);
    switch (string_value.data) {
        .latin1 => |bytes| try buffer.appendSlice(rt.memory.allocator, bytes),
        .utf16 => |units| {
            for (units) |unit| {
                if (unit <= 0x7f) try buffer.append(rt.memory.allocator, @intCast(unit));
            }
        },
    }
}

pub fn appendValueString(rt: *core.Runtime, buffer: *std.ArrayList(u8), value: core.Value) anyerror!void {
    if (value.asInt32()) |int_value| {
        var int_buf: [32]u8 = undefined;
        const printed = try std.fmt.bufPrint(&int_buf, "{d}", .{int_value});
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
            const printed = try std.fmt.bufPrint(&float_buf, "{d}", .{float_value});
            try buffer.appendSlice(rt.memory.allocator, printed);
        }
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
        switch (string_value.data) {
            .latin1 => |bytes| try buffer.appendSlice(rt.memory.allocator, bytes),
            .utf16 => |units| {
                for (units) |unit| {
                    if (unit <= 0x7f) {
                        try buffer.append(rt.memory.allocator, @intCast(unit));
                    } else {
                        var unit_buf: [16]u8 = undefined;
                        const printed = try std.fmt.bufPrint(&unit_buf, "\\u{x}", .{unit});
                        try buffer.appendSlice(rt.memory.allocator, printed);
                    }
                }
            },
        }
    } else if (value.isObject()) {
        const header = value.refHeader() orelse return;
        const object_value: *core.Object = @fieldParentPtr("header", header);
        if (object_value.class_id == core.class.ids.string) {
            const data = object_value.string_data orelse return error.UnsupportedValueOp;
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

fn binaryBigInt(rt: *core.Runtime, op: u8, a: core.Value, b: core.Value) !core.Value {
    var lhs = try cloneBigIntValue(rt, a);
    defer lhs.deinit();
    var rhs = try cloneBigIntValue(rt, b);
    defer rhs.deinit();
    const allocator = rt.memory.allocator;
    var out = switch (op) {
        bytecode.emitter.known.mul => try bignum.mulAlloc(allocator, lhs, rhs),
        bytecode.emitter.known.div => lhs.div(rhs) catch |err| switch (err) {
            error.DivisionByZero => return error.RangeError,
            else => return err,
        },
        bytecode.emitter.known.mod => lhs.rem(rhs) catch |err| switch (err) {
            error.DivisionByZero => return error.RangeError,
            else => return err,
        },
        bytecode.emitter.known.add => try bignum.addAlloc(allocator, lhs, rhs),
        bytecode.emitter.known.sub => try bignum.subAlloc(allocator, lhs, rhs),
        bytecode.emitter.known.pow => lhs.pow(rhs, allocator) catch |err| switch (err) {
            error.NegativeExponent, error.BigIntTooLarge => return error.RangeError,
            else => return err,
        },
        bytecode.emitter.known.bit_and => try lhs.bitwise(rhs, allocator, .@"and"),
        bytecode.emitter.known.bit_xor => try lhs.bitwise(rhs, allocator, .xor),
        bytecode.emitter.known.bit_or => try lhs.bitwise(rhs, allocator, .@"or"),
        bytecode.emitter.known.shl => try shiftBigInt(allocator, lhs, rhs, .left),
        bytecode.emitter.known.sar => try shiftBigInt(allocator, lhs, rhs, .right),
        bytecode.emitter.known.shr => return error.TypeError,
        else => return error.UnsupportedValueOp,
    };
    defer out.deinit();
    return createBigIntValue(rt, out);
}

fn binaryNumber(op: u8, a: core.Value, b: core.Value) !core.Value {
    const lhs = numberValue(a) orelse return error.UnsupportedValueOp;
    const rhs = numberValue(b) orelse return error.UnsupportedValueOp;
    const out = switch (op) {
        240 => lhs * rhs,
        241 => lhs / rhs,
        242 => @mod(lhs, rhs),
        243 => lhs + rhs,
        244 => lhs - rhs,
        251 => std.math.pow(f64, lhs, rhs),
        else => return error.UnsupportedValueOp,
    };
    return numberToValue(out);
}

fn stringAdd(rt: *core.Runtime, a: core.Value, b: core.Value) !core.Value {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(rt.memory.allocator);
    try appendValueString(rt, &buffer, a);
    try appendValueString(rt, &buffer, b);
    return createStringValue(rt, buffer.items);
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
    const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
    if (trimmed.len == 0) return std.math.nan(f64);
    if (std.mem.eql(u8, trimmed, "Infinity") or std.mem.eql(u8, trimmed, "+Infinity")) return std.math.inf(f64);
    if (std.mem.eql(u8, trimmed, "-Infinity")) return -std.math.inf(f64);
    return std.fmt.parseFloat(f64, trimmed) catch std.math.nan(f64);
}

fn appendArrayString(rt: *core.Runtime, buffer: *std.ArrayList(u8), object: *core.Object) anyerror!void {
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
    if (a.asInt32()) |ai| {
        if (b.asInt32()) |bi| return ai == bi;
    }
    if (a.asBool()) |ab| {
        if (b.asBool()) |bb| return ab == bb;
    }
    if (a.isNull() or a.isUndefined()) return a.same(b);
    if (a.isString() and b.isString()) {
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
            magnitude >>= 32;
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

fn valuesLooseEqual(a: core.Value, b: core.Value) bool {
    if (valuesEqual(a, b)) return true;
    if ((a.isNull() and b.isUndefined()) or (a.isUndefined() and b.isNull())) return true;
    if (numberLikeInt(a)) |ai| {
        if (numberLikeInt(b)) |bi| return ai == bi;
    }
    return false;
}

fn numberLikeInt(value: core.Value) ?i32 {
    if (value.asInt32()) |int_value| return int_value;
    if (value.asBool()) |bool_value| return if (bool_value) 1 else 0;
    if (value.isNull()) return 0;
    if (value.isString()) {
        const header = value.refHeader() orelse return null;
        const string_value: *core.string.String = @fieldParentPtr("header", header);
        return switch (string_value.data) {
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

fn powI32(lhs: i32, rhs: i32) i32 {
    if (rhs < 0) return 0;
    var out: i32 = 1;
    var i: i32 = 0;
    while (i < rhs) : (i += 1) out *= lhs;
    return out;
}

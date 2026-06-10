const std = @import("std");

const bignum = @import("../libs/bignum.zig");
const gc = @import("gc.zig");

pub const Tag = struct {
    pub const first: i32 = -9;
    pub const big_int: i32 = -9;
    pub const symbol: i32 = -8;
    pub const string: i32 = -7;
    pub const string_rope: i32 = -6;
    pub const module: i32 = -3;
    pub const function_bytecode: i32 = -2;
    pub const object: i32 = -1;
    pub const int: i32 = 0;
    pub const boolean: i32 = 1;
    pub const null_value: i32 = 2;
    pub const undefined_value: i32 = 3;
    pub const uninitialized: i32 = 4;
    pub const catch_offset: i32 = 5;
    pub const exception: i32 = 6;
    pub const short_big_int: i32 = 7;
    pub const float64: i32 = 8;
};

pub const JSValue = extern struct {
    pub const Scope = @import("runtime.zig").HandleScope;
    pub const Local = @import("runtime.zig").LocalHandle;
    pub const Persistent = @import("runtime.zig").JSValueHandle;
    pub const Weak = @import("runtime.zig").WeakPersistentValue;
    pub const String = @import("string_view.zig").JSString(JSValue);
    pub const Bytes = @import("bytes_view.zig").JSBytes(JSValue);

    payload: u64,
    tag: i32,
    padding: i32 = 0,

    pub fn int32(v: i32) JSValue {
        return .{ .payload = payloadFromI32(v), .tag = Tag.int };
    }

    pub fn float64(v: f64) JSValue {
        return .{ .payload = @bitCast(v), .tag = Tag.float64 };
    }

    pub fn number(v: f64) JSValue {
        if (v >= std.math.minInt(i32) and v <= std.math.maxInt(i32)) {
            const int_val: i32 = @intFromFloat(v);
            if (@as(f64, @floatFromInt(int_val)) == v and !isNegativeZero(v)) {
                return int32(int_val);
            }
        }
        return float64(v);
    }

    pub fn boolean(v: bool) JSValue {
        return .{ .payload = if (v) 1 else 0, .tag = Tag.boolean };
    }

    pub fn shortBigInt(v: i64) JSValue {
        return .{ .payload = @bitCast(v), .tag = Tag.short_big_int };
    }

    pub fn bigInt(header: *gc.Header) JSValue {
        return .{ .payload = @intFromPtr(header), .tag = Tag.big_int };
    }

    pub fn string(header: *gc.Header) JSValue {
        return .{ .payload = @intFromPtr(header), .tag = Tag.string };
    }

    pub fn stringRope(header: *gc.Header) JSValue {
        return .{ .payload = @intFromPtr(header), .tag = Tag.string_rope };
    }

    pub fn symbol(atom_id: u32) JSValue {
        return .{ .payload = atom_id, .tag = Tag.symbol };
    }

    pub fn object(header: *gc.Header) JSValue {
        return .{ .payload = @intFromPtr(header), .tag = Tag.object };
    }

    pub fn module(header: *gc.Header) JSValue {
        return .{ .payload = @intFromPtr(header), .tag = Tag.module };
    }

    pub fn functionBytecode(header: *gc.GCObjectHeader) JSValue {
        return .{ .payload = @intFromPtr(header), .tag = Tag.function_bytecode };
    }

    pub fn nullValue() JSValue {
        return .{ .payload = 0, .tag = Tag.null_value };
    }

    pub fn undefinedValue() JSValue {
        return .{ .payload = 0, .tag = Tag.undefined_value };
    }

    pub fn uninitialized() JSValue {
        return .{ .payload = 0, .tag = Tag.uninitialized };
    }

    pub fn catchOffset(offset: i32) JSValue {
        return .{ .payload = payloadFromI32(offset), .tag = Tag.catch_offset };
    }

    pub fn exception() JSValue {
        return .{ .payload = 0, .tag = Tag.exception };
    }

    pub fn isNumber(self: JSValue) bool {
        return self.tag == Tag.int or self.tag == Tag.float64;
    }

    pub fn isBigInt(self: JSValue) bool {
        return self.tag == Tag.big_int or self.tag == Tag.short_big_int;
    }

    pub fn isBool(self: JSValue) bool {
        return self.tag == Tag.boolean;
    }

    pub fn isString(self: JSValue) bool {
        return self.tag == Tag.string or self.tag == Tag.string_rope;
    }

    pub fn isSymbol(self: JSValue) bool {
        return self.tag == Tag.symbol;
    }

    pub fn isObject(self: JSValue) bool {
        return self.tag == Tag.object;
    }

    pub fn isNull(self: JSValue) bool {
        return self.tag == Tag.null_value;
    }

    pub fn isUndefined(self: JSValue) bool {
        return self.tag == Tag.undefined_value;
    }

    pub fn isUninitialized(self: JSValue) bool {
        return self.tag == Tag.uninitialized;
    }

    pub fn isCatchOffset(self: JSValue) bool {
        return self.tag == Tag.catch_offset;
    }

    pub fn isException(self: JSValue) bool {
        return self.tag == Tag.exception;
    }

    pub fn isModule(self: JSValue) bool {
        return self.tag == Tag.module;
    }

    pub fn isFunctionBytecode(self: JSValue) bool {
        return self.tag == Tag.function_bytecode;
    }

    pub inline fn requiresRefCount(self: JSValue) bool {
        switch (self.tag) {
            Tag.big_int, Tag.string, Tag.string_rope, Tag.object, Tag.module, Tag.function_bytecode => return true,
            else => return false,
        }
    }

    pub fn asInt32(self: JSValue) ?i32 {
        if (self.tag == Tag.int) return payloadAsI32(self.payload);
        return null;
    }

    pub fn asFloat64(self: JSValue) ?f64 {
        if (self.tag == Tag.float64) return @bitCast(self.payload);
        return null;
    }

    pub fn asNumber(self: JSValue) ?f64 {
        return numberValue(self);
    }

    pub fn asBool(self: JSValue) ?bool {
        if (self.tag == Tag.boolean) return self.payload != 0;
        return null;
    }

    pub fn asSymbolAtom(self: JSValue) ?u32 {
        if (self.tag == Tag.symbol) return @truncate(self.payload);
        return null;
    }

    pub fn asShortBigInt(self: JSValue) ?i64 {
        if (self.tag == Tag.short_big_int) return @bitCast(self.payload);
        return null;
    }

    pub fn asCatchOffset(self: JSValue) ?i32 {
        if (self.tag == Tag.catch_offset) return payloadAsI32(self.payload);
        return null;
    }

    pub fn asString(self: JSValue) ?String {
        return String.fromValue(self);
    }

    pub fn asBytes(self: JSValue, ctx: anytype) Bytes.Error!Bytes {
        _ = ctx;
        return Bytes.fromValue(self);
    }

    pub fn refHeader(self: JSValue) ?*gc.Header {
        return switch (self.tag) {
            Tag.big_int, Tag.string, Tag.string_rope, Tag.object, Tag.module => ptrFromPayload(gc.Header, self.payload),
            else => null,
        };
    }

    pub fn objectHeader(self: JSValue) ?*gc.GCObjectHeader {
        return switch (self.tag) {
            Tag.function_bytecode => ptrFromPayload(gc.GCObjectHeader, self.payload),
            else => null,
        };
    }

    pub fn dup(self: JSValue) JSValue {
        if (!self.requiresRefCount()) return self;
        if (self.refHeader()) |header| gc.retain(header);
        if (self.objectHeader()) |header| header.retain();
        return self;
    }

    pub fn free(self: JSValue, rt: anytype) void {
        if (!self.requiresRefCount()) return;
        if (rt.gc.phase == .deinit) {
            switch (self.tag) {
                Tag.object, Tag.module, Tag.function_bytecode => return,
                else => {},
            }
        }
        if (rt.opcode_profile) |prof| prof.recordValueFree();
        if (self.refHeader()) |header| gc.release(rt, header);
        if (self.objectHeader()) |header| gc.release(rt, header);
    }

    pub fn same(self: JSValue, other: JSValue) bool {
        if (self.tag != other.tag) return false;
        return switch (self.tag) {
            Tag.null_value, Tag.undefined_value, Tag.uninitialized, Tag.exception => true,
            Tag.int, Tag.symbol, Tag.catch_offset, Tag.boolean, Tag.float64, Tag.short_big_int, Tag.big_int, Tag.string, Tag.string_rope, Tag.module, Tag.object, Tag.function_bytecode => self.payload == other.payload,
            else => unreachable,
        };
    }

    pub fn sameValue(self: JSValue, other: JSValue) bool {
        if (numberValue(self)) |lhs| {
            if (numberValue(other)) |rhs| {
                if (std.math.isNan(lhs) and std.math.isNan(rhs)) return true;
                if (lhs == 0 and rhs == 0) return isNegativeZero(lhs) == isNegativeZero(rhs);
                return lhs == rhs;
            }
        }
        if (self.isBigInt() and other.isBigInt()) {
            return (compareBigIntValues(self, other) orelse return false) == .eq;
        }
        if (self.asInt32()) |lhs| {
            if (other.asInt32()) |rhs| return lhs == rhs;
        }
        if (self.asBool()) |lhs| {
            if (other.asBool()) |rhs| return lhs == rhs;
        }
        if (self.isNull() or self.isUndefined()) return self.same(other);
        if (self.isString() and other.isString()) {
            if (self.same(other)) return true;
            return (compareStringValues(self, other) orelse 1) == 0;
        }
        return self.same(other);
    }
};

fn numberValue(value: JSValue) ?f64 {
    if (value.asInt32()) |int_value| return @floatFromInt(int_value);
    if (value.asFloat64()) |float_value| return float_value;
    return null;
}

pub fn isZeroBigInt(value: JSValue) ?bool {
    var scratch: [2]bignum.Limb = undefined;
    const parts = bigIntParts(value, &scratch) orelse return null;
    return parts.limbs.len == 0 or (parts.limbs.len == 1 and parts.limbs[0] == 0);
}

fn isNegativeZero(value: f64) bool {
    return value == 0 and std.math.isNegativeInf(1.0 / value);
}

fn compareStringValues(a: JSValue, b: JSValue) ?i32 {
    if (!a.isString() or !b.isString()) return null;
    const a_header = a.refHeader() orelse return null;
    const b_header = b.refHeader() orelse return null;
    const a_string: *const @import("string.zig").String = @fieldParentPtr("header", a_header);
    const b_string: *const @import("string.zig").String = @fieldParentPtr("header", b_header);
    return a_string.compare(b_string.*);
}

fn compareBigIntValues(a: JSValue, b: JSValue) ?std.math.Order {
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

fn bigIntParts(value: JSValue, scratch: *[2]bignum.Limb) ?BigIntParts {
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
        const big: *@import("bigint.zig").BigInt = @alignCast(@fieldParentPtr("header", header));
        return .{ .negative = big.value.negative, .limbs = big.value.limbs };
    }
    return null;
}

fn payloadFromI32(value: i32) u64 {
    const bits: u32 = @bitCast(value);
    return bits;
}

fn payloadAsI32(payload: u64) i32 {
    const bits: u32 = @truncate(payload);
    return @bitCast(bits);
}

fn ptrFromPayload(comptime T: type, payload: u64) ?*T {
    if (payload == 0) return null;
    return @ptrFromInt(payload);
}

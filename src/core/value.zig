const std = @import("std");
const build_options = @import("build_options");

const bignum = @import("../libs/bignum.zig");
const gc = @import("gc.zig");

/// When true, JSValue uses the 8-byte NaN-boxed representation (build -Dzjs_nan_boxing=true).
pub const nan_boxing: bool = build_options.zjs_nan_boxing;

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

/// NaN-boxed encoding (see quickjs.h JS_NAN_BOXING): float64 values are stored
/// directly as their IEEE-754 bit pattern with NaN canonicalized, so every
/// float bit pattern is <= 0xFFF0_0000_0000_0000 (-Infinity). All other tags
/// are boxed strictly above that range: a 4-bit dense tag index in bits 51..48
/// and a 48-bit payload in bits 47..0 (covers aarch64/x86-64 user-space
/// pointers and sign-extended 48-bit short big ints).
const NanBox = struct {
    const payload_bits = 48;
    const payload_mask: u64 = (@as(u64, 1) << payload_bits) - 1;
    /// Largest canonical float64 bit pattern (-Infinity).
    const float_max: u64 = 0xFFF0_0000_0000_0000;
    const canonical_nan: u64 = 0x7FF8_0000_0000_0000;

    const boxed_tags = [_]i32{
        Tag.big_int,
        Tag.symbol,
        Tag.string,
        Tag.string_rope,
        Tag.module,
        Tag.function_bytecode,
        Tag.object,
        Tag.int,
        Tag.boolean,
        Tag.null_value,
        Tag.undefined_value,
        Tag.uninitialized,
        Tag.catch_offset,
        Tag.exception,
        Tag.short_big_int,
    };

    /// Dense 1-based tag index; index 0 is reserved so that no boxed encoding
    /// can collide with the canonical float range.
    fn indexOf(comptime tag: i32) u64 {
        for (boxed_tags, 1..) |candidate, index| {
            if (candidate == tag) return index;
        }
        @compileError("tag is not representable in the NaN-boxed encoding");
    }

    /// High 16 bits of a boxed encoding for `tag`.
    fn prefixOf(comptime tag: i32) u64 {
        return (float_max >> payload_bits) | indexOf(tag);
    }

    const tag_by_index: [boxed_tags.len + 1]i32 = blk: {
        var table: [boxed_tags.len + 1]i32 = undefined;
        table[0] = Tag.float64;
        for (boxed_tags, 1..) |tag, index| table[index] = tag;
        break :blk table;
    };
};

pub const JSValue = extern struct {
    pub const Scope = @import("runtime.zig").HandleScope;
    pub const Local = @import("runtime.zig").LocalHandle;
    pub const Persistent = @import("runtime.zig").JSValueHandle;
    pub const Weak = @import("runtime.zig").WeakPersistentValue;
    pub const String = @import("string_view.zig").JSString(JSValue);
    pub const Bytes = @import("bytes_view.zig").JSBytes(JSValue);

    pub const Repr = if (nan_boxing) extern struct {
        bits: u64,
    } else extern struct {
        payload: u64,
        tag: i32,
        padding: i32 = 0,
    };

    repr: Repr,

    comptime {
        std.debug.assert(@sizeOf(JSValue) == if (nan_boxing) 8 else 16);
        std.debug.assert(@alignOf(JSValue) == 8);
    }

    /// Number of bits available for the immediate short big int payload.
    pub const short_big_int_bits: u16 = if (nan_boxing) NanBox.payload_bits else 64;
    pub const short_big_int_min: i64 = if (nan_boxing) -(@as(i64, 1) << (NanBox.payload_bits - 1)) else std.math.minInt(i64);
    pub const short_big_int_max: i64 = if (nan_boxing) (@as(i64, 1) << (NanBox.payload_bits - 1)) - 1 else std.math.maxInt(i64);

    pub inline fn shortBigIntFits(value: i128) bool {
        return value >= short_big_int_min and value <= short_big_int_max;
    }

    inline fn make(comptime tag: i32, payload: u64) JSValue {
        if (comptime nan_boxing) {
            std.debug.assert(payload <= NanBox.payload_mask);
            const prefix_bits = comptime (NanBox.prefixOf(tag) << NanBox.payload_bits);
            return .{ .repr = .{ .bits = prefix_bits | payload } };
        }
        return .{ .repr = .{ .payload = payload, .tag = tag } };
    }

    inline fn hasTag(self: JSValue, comptime tag: i32) bool {
        if (comptime nan_boxing) {
            if (comptime tag == Tag.float64) return self.repr.bits <= NanBox.float_max;
            return (self.repr.bits >> NanBox.payload_bits) == comptime NanBox.prefixOf(tag);
        }
        return self.repr.tag == tag;
    }

    inline fn payloadOf(self: JSValue) u64 {
        if (comptime nan_boxing) return self.repr.bits & NanBox.payload_mask;
        return self.repr.payload;
    }

    pub fn int32(v: i32) JSValue {
        return make(Tag.int, payloadFromI32(v));
    }

    pub fn float64(v: f64) JSValue {
        if (comptime nan_boxing) {
            const bits: u64 = @bitCast(v);
            // Canonicalize every NaN so no float collides with boxed encodings.
            if ((bits & 0x7FFF_FFFF_FFFF_FFFF) > 0x7FF0_0000_0000_0000) {
                return .{ .repr = .{ .bits = NanBox.canonical_nan } };
            }
            return .{ .repr = .{ .bits = bits } };
        }
        return make(Tag.float64, @bitCast(v));
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
        return make(Tag.boolean, if (v) 1 else 0);
    }

    pub fn shortBigInt(v: i64) JSValue {
        if (comptime nan_boxing) {
            std.debug.assert(shortBigIntFits(v));
            return make(Tag.short_big_int, @as(u64, @bitCast(v)) & NanBox.payload_mask);
        }
        return make(Tag.short_big_int, @bitCast(v));
    }

    pub fn bigInt(header: *gc.Header) JSValue {
        return make(Tag.big_int, @intFromPtr(header));
    }

    pub fn string(header: *gc.Header) JSValue {
        return make(Tag.string, @intFromPtr(header));
    }

    pub fn stringRope(header: *gc.Header) JSValue {
        return make(Tag.string_rope, @intFromPtr(header));
    }

    pub fn symbol(atom_id: u32) JSValue {
        return make(Tag.symbol, atom_id);
    }

    pub fn object(header: *gc.Header) JSValue {
        return make(Tag.object, @intFromPtr(header));
    }

    pub fn module(header: *gc.Header) JSValue {
        return make(Tag.module, @intFromPtr(header));
    }

    pub fn functionBytecode(header: *gc.GCObjectHeader) JSValue {
        return make(Tag.function_bytecode, @intFromPtr(header));
    }

    pub fn nullValue() JSValue {
        return make(Tag.null_value, 0);
    }

    pub fn undefinedValue() JSValue {
        return make(Tag.undefined_value, 0);
    }

    pub fn uninitialized() JSValue {
        return make(Tag.uninitialized, 0);
    }

    pub fn catchOffset(offset: i32) JSValue {
        return make(Tag.catch_offset, payloadFromI32(offset));
    }

    pub fn exception() JSValue {
        return make(Tag.exception, 0);
    }

    pub inline fn tagOf(self: JSValue) i32 {
        if (comptime nan_boxing) {
            if (self.repr.bits <= NanBox.float_max) return Tag.float64;
            return NanBox.tag_by_index[@as(usize, @intCast((self.repr.bits >> NanBox.payload_bits) & 0xF))];
        }
        return self.repr.tag;
    }

    pub fn isNumber(self: JSValue) bool {
        return self.hasTag(Tag.int) or self.hasTag(Tag.float64);
    }

    pub inline fn isInt(self: JSValue) bool {
        return self.hasTag(Tag.int);
    }

    pub inline fn isFloat64(self: JSValue) bool {
        return self.hasTag(Tag.float64);
    }

    pub fn isBigInt(self: JSValue) bool {
        return self.hasTag(Tag.big_int) or self.hasTag(Tag.short_big_int);
    }

    pub fn isBool(self: JSValue) bool {
        return self.hasTag(Tag.boolean);
    }

    pub fn isString(self: JSValue) bool {
        return self.hasTag(Tag.string) or self.hasTag(Tag.string_rope);
    }

    pub fn isSymbol(self: JSValue) bool {
        return self.hasTag(Tag.symbol);
    }

    pub fn isObject(self: JSValue) bool {
        return self.hasTag(Tag.object);
    }

    pub fn isNull(self: JSValue) bool {
        return self.hasTag(Tag.null_value);
    }

    pub fn isUndefined(self: JSValue) bool {
        return self.hasTag(Tag.undefined_value);
    }

    pub fn isUninitialized(self: JSValue) bool {
        return self.hasTag(Tag.uninitialized);
    }

    pub fn isCatchOffset(self: JSValue) bool {
        return self.hasTag(Tag.catch_offset);
    }

    pub fn isException(self: JSValue) bool {
        return self.hasTag(Tag.exception);
    }

    pub fn isModule(self: JSValue) bool {
        return self.hasTag(Tag.module);
    }

    pub fn isFunctionBytecode(self: JSValue) bool {
        return self.hasTag(Tag.function_bytecode);
    }

    pub inline fn requiresRefCount(self: JSValue) bool {
        switch (self.tagOf()) {
            Tag.big_int, Tag.string, Tag.string_rope, Tag.object, Tag.module, Tag.function_bytecode => return true,
            else => return false,
        }
    }

    pub fn asInt32(self: JSValue) ?i32 {
        if (self.hasTag(Tag.int)) return payloadAsI32(self.payloadOf());
        return null;
    }

    pub fn asFloat64(self: JSValue) ?f64 {
        if (comptime nan_boxing) {
            if (self.repr.bits <= NanBox.float_max) return @bitCast(self.repr.bits);
            return null;
        }
        if (self.repr.tag == Tag.float64) return @bitCast(self.repr.payload);
        return null;
    }

    pub fn asNumber(self: JSValue) ?f64 {
        return numberValue(self);
    }

    pub fn asBool(self: JSValue) ?bool {
        if (self.hasTag(Tag.boolean)) return self.payloadOf() != 0;
        return null;
    }

    pub fn asSymbolAtom(self: JSValue) ?u32 {
        if (self.hasTag(Tag.symbol)) return @truncate(self.payloadOf());
        return null;
    }

    pub fn asShortBigInt(self: JSValue) ?i64 {
        if (!self.hasTag(Tag.short_big_int)) return null;
        if (comptime nan_boxing) {
            // Sign-extend the 48-bit payload.
            const shifted: i64 = @bitCast(self.repr.bits << (64 - NanBox.payload_bits));
            return shifted >> (64 - NanBox.payload_bits);
        }
        return @bitCast(self.repr.payload);
    }

    /// Extract a BigInt value as a signed i64. Handles BOTH the inline
    /// (short_big_int) and heap (big_int) representations. Returns null for
    /// non-BigInt values and for BigInts whose magnitude exceeds the i64 range
    /// (the i64::MIN edge, magnitude == 1<<63, is handled correctly). Stays in
    /// core: reuses the file-local `bigIntParts`, so it carries no builtins
    /// dependency. The public, representation-complete analog of `asShortBigInt`.
    pub fn asInt64(self: JSValue) ?i64 {
        if (!self.isBigInt()) return null;
        // Fast path: an inline short BigInt always fits i64 by construction (its
        // payload is at most the 48-bit short window under NaN-boxing).
        if (self.asShortBigInt()) |short| return short;
        var scratch: [2]bignum.Limb = undefined;
        const parts = bigIntParts(self, &scratch) orelse return null;
        // Build a non-owning view over the limbs (allocator is never touched by
        // toI64); scratch outlives this call since it is stack-local here.
        const view = bignum.BigInt{
            .negative = parts.negative,
            .limbs = @constCast(parts.limbs),
            .allocator = undefined,
        };
        return view.toI64();
    }

    /// Extract a BigInt value as an unsigned u64. Handles BOTH the inline
    /// (short_big_int) and heap (big_int) representations. Returns null for
    /// non-BigInt values, for negative non-zero BigInts, and for BigInts whose
    /// magnitude exceeds the u64 range. Crucially this accepts the 2^63..2^64-1
    /// band that does NOT fit i64, so it must NOT be implemented as a shim over
    /// `asInt64`.
    pub fn asUint64(self: JSValue) ?u64 {
        if (!self.isBigInt()) return null;
        var scratch: [2]bignum.Limb = undefined;
        const parts = bigIntParts(self, &scratch) orelse return null;
        const view = bignum.BigInt{
            .negative = parts.negative,
            .limbs = @constCast(parts.limbs),
            .allocator = undefined,
        };
        return view.toU64();
    }

    pub fn asCatchOffset(self: JSValue) ?i32 {
        if (self.hasTag(Tag.catch_offset)) return payloadAsI32(self.payloadOf());
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
        return switch (self.tagOf()) {
            Tag.big_int, Tag.string, Tag.string_rope, Tag.object, Tag.module => ptrFromPayload(gc.Header, self.payloadOf()),
            else => null,
        };
    }

    pub fn objectHeader(self: JSValue) ?*gc.GCObjectHeader {
        return switch (self.tagOf()) {
            Tag.function_bytecode => ptrFromPayload(gc.GCObjectHeader, self.payloadOf()),
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
            switch (self.tagOf()) {
                Tag.object, Tag.module, Tag.function_bytecode => return,
                else => {},
            }
        }
        if (rt.opcode_profile) |prof| prof.recordValueFree();
        if (self.refHeader()) |header| gc.release(rt, header);
        if (self.objectHeader()) |header| gc.release(rt, header);
    }

    pub fn same(self: JSValue, other: JSValue) bool {
        if (comptime nan_boxing) {
            // Encodings are canonical (NaN included), so bit equality matches
            // the tag+payload comparison of the boxed representation.
            return self.repr.bits == other.repr.bits;
        }
        if (self.repr.tag != other.repr.tag) return false;
        return switch (self.repr.tag) {
            Tag.null_value, Tag.undefined_value, Tag.uninitialized, Tag.exception => true,
            Tag.int, Tag.symbol, Tag.catch_offset, Tag.boolean, Tag.float64, Tag.short_big_int, Tag.big_int, Tag.string, Tag.string_rope, Tag.module, Tag.object, Tag.function_bytecode => self.repr.payload == other.repr.payload,
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

    /// SameValueZero (ECMA-262): like SameValue but treats `+0` and `-0` as
    /// equal. Used by `Array.prototype.includes`, the Map/Set key comparison,
    /// and `Object.is`-adjacent collection lookups. Pure: no allocation, no VM
    /// state.
    pub fn sameValueZero(self: JSValue, other: JSValue) bool {
        if (numberValue(self)) |lhs| {
            if (numberValue(other)) |rhs| {
                if (std.math.isNan(lhs) and std.math.isNan(rhs)) return true;
                return lhs == rhs;
            }
        }
        if (self.asBool()) |lhs| {
            if (other.asBool()) |rhs| return lhs == rhs;
        }
        if (self.isNull() or self.isUndefined()) return self.same(other);
        if (self.isBigInt() and other.isBigInt()) return self.sameValue(other);
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

test "asInt64 / asUint64 on inline short BigInt and non-BigInt" {
    const t = std.testing;

    // Non-BigInt values must extract as null on both.
    try t.expectEqual(@as(?i64, null), JSValue.int32(7).asInt64());
    try t.expectEqual(@as(?u64, null), JSValue.int32(7).asUint64());
    try t.expectEqual(@as(?i64, null), JSValue.float64(1.5).asInt64());
    try t.expectEqual(@as(?u64, null), JSValue.boolean(true).asUint64());

    // Inline short BigInt across its full representable range. That range is the
    // NaN-boxed 48-bit window (±2^47) when nan_boxing is on, or the full i64
    // otherwise — so the test pins to the representation's own bounds. A raw
    // i64::MAX literal would overflow the 48-bit short payload and trip the
    // `shortBigInt` construction assert under the default (NaN-boxed) build.
    try t.expectEqual(@as(?i64, 0), JSValue.shortBigInt(0).asInt64());
    try t.expectEqual(@as(?i64, 42), JSValue.shortBigInt(42).asInt64());
    try t.expectEqual(@as(?i64, -42), JSValue.shortBigInt(-42).asInt64());
    try t.expectEqual(@as(?i64, JSValue.short_big_int_max), JSValue.shortBigInt(JSValue.short_big_int_max).asInt64());
    try t.expectEqual(@as(?i64, JSValue.short_big_int_min), JSValue.shortBigInt(JSValue.short_big_int_min).asInt64());

    // asUint64 on inline: non-negative ok, negative non-zero -> null. (The
    // 2^63..2^64-1 band that distinguishes asUint64 from asInt64 lives in the
    // heap representation and is covered by the bignum toU64/toI64 edge test.)
    try t.expectEqual(@as(?u64, 0), JSValue.shortBigInt(0).asUint64());
    try t.expectEqual(@as(?u64, 42), JSValue.shortBigInt(42).asUint64());
    try t.expectEqual(@as(?u64, @as(u64, @intCast(JSValue.short_big_int_max))), JSValue.shortBigInt(JSValue.short_big_int_max).asUint64());
    try t.expectEqual(@as(?u64, null), JSValue.shortBigInt(-1).asUint64());
    try t.expectEqual(@as(?u64, null), JSValue.shortBigInt(JSValue.short_big_int_min).asUint64());
}

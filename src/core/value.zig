//! The engine's 8-byte NaN-boxed JSValue representation.
//!
//! Values are copied freely; traced heap values are kept alive by heap edges,
//! root frames, or native pins. Float64 values are IEEE bits (NaNs
//! canonicalized). Every other kind is a 16-bit prefix `0xFFF0 + index`
//! plus a 48-bit payload, where `index` packs Kind densely into 1..15 by
//! skipping the unused −5 hole. `tagOf` recovers Kind by arithmetic; tracer
//! ownership is one unsigned range on the raw word. Kind numbers stay the
//! tagged-era i32 space for switches. This core leaf cannot depend on exec
//! or binding.

const std = @import("std");

const bignum = @import("../libs/bigint.zig");
const gc = @import("gc.zig");
const string_mod = @import("string.zig");

pub const JSValue = extern struct {
    /// Semantic tag numbers for `is` / `as` / `from` and `tagOf()`. The stored
    /// word is NaN-boxed; call sites write `v.is(.int)` / `v.as(.int)`, not
    /// `isInt` / `asInt32` / `Tag.int`.
    pub const Kind = enum(i32) {
        // Heap / tracer-owned. Decoded tags in [-8, -1] pack into prefixes
        // 0xFFF1..0xFFF7; Kind −5 is not encoded. `isTracerOwned` is one
        // unsigned range on the raw word.
        symbol = -8,
        string = -7,
        string_rope = -6,
        // -5 reserved: keeps the tracer band contiguous.
        /// Deviation from qjs (`JS_TAG_BIG_INT = -9`): heap BigInt is tracer-owned
        /// since TGC S1-c, so it sits in this former hole.
        big_int = -4,
        module = -3,
        function_bytecode = -2,
        object = -1,

        // Immediates and VM sentinels (non-negative).
        int = 0,
        boolean = 1,
        null_value = 2,
        undefined_value = 3,
        uninitialized = 4,
        catch_offset = 5,
        exception = 6,
        short_big_int = 7,
        float64 = 8,
    };

    pub const Int32Pair = struct {
        lhs: i32,
        rhs: i32,
    };

    pub const String = @import("string_view.zig").JSString(JSValue);
    pub const Bytes = @import("bytes_view.zig").JSBytes(JSValue);

    /// Packed-value encoding revision. Zero would mean the field layout fully
    /// describes the representation. Bump this if the meaning of the
    /// payload/tag pair ever changes without a visible change in field types.
    pub const abi_encoding_revision: u64 = 2;

    /// Immediate short BigInt fits in the 48-bit NaN-box payload.
    pub const short_big_int_bits: u16 = 48;
    pub const short_big_int_min: i64 = -(@as(i64, 1) << (short_big_int_bits - 1));
    pub const short_big_int_max: i64 = (@as(i64, 1) << (short_big_int_bits - 1)) - 1;

    const payload_bits: u16 = short_big_int_bits;
    const payload_mask: u64 = (@as(u64, 1) << payload_bits) - 1;
    /// Inclusive max of a float word. Equal to −Inf; the `0xFFF0_xxxx`
    /// hole above it is not a boxed encoding.
    const float_max: u64 = 0xFFF0_0000_0000_0000;
    const canonical_nan: u64 = 0x7FF8_0000_0000_0000;
    /// Boxed prefix = `prefix_base + boxedIndex(kind)`. Index 0 is the
    /// float/hole band, not a boxed kind.
    const prefix_base: u64 = 0xFFF0;
    const first_boxed: u64 = 0xFFF1_0000_0000_0000;
    /// First non-tracer boxed kind (int). Tracer-owned is
    /// `[first_boxed, tracer_owned_end)` = prefixes 0xFFF1..0xFFF7.
    const tracer_owned_end: u64 = 0xFFF8_0000_0000_0000;
    const inf_bits: u64 = 0x7FF0_0000_0000_0000;

    bits: u64,

    comptime {
        std.debug.assert(@sizeOf(JSValue) == 8);
        std.debug.assert(@alignOf(JSValue) == 8);
        std.debug.assert(@intFromEnum(Kind.int) == 0);
        std.debug.assert(boxedPrefix(.symbol) == 0xFFF1);
        std.debug.assert(boxedPrefix(.string_rope) == 0xFFF3);
        std.debug.assert(boxedPrefix(.big_int) == 0xFFF4);
        std.debug.assert(boxedPrefix(.object) == 0xFFF7);
        std.debug.assert(boxedPrefix(.int) == 0xFFF8);
        std.debug.assert(boxedPrefix(.undefined_value) == 0xFFFB);
        std.debug.assert(boxedPrefix(.short_big_int) == 0xFFFF);
        std.debug.assert(first_boxed == boxedPrefix(.symbol) << payload_bits);
        std.debug.assert(tracer_owned_end == boxedPrefix(.int) << payload_bits);
        std.debug.assert(abi_encoding_revision == 2);
    }

    fn boxedIndex(comptime kind: Kind) u64 {
        const n = @intFromEnum(kind);
        if (n == @intFromEnum(Kind.float64)) {
            @compileError("float64 is stored as IEEE bits, not a boxed prefix");
        }
        // Kind skips −5 so the 15 live boxed kinds pack densely into
        // 0xFFF1..0xFFFF. Kinds before the hole (−8..−6) take one extra slot.
        return @intCast(8 + n + @as(i32, @intFromBool(n < @intFromEnum(Kind.big_int))));
    }

    fn boxedPrefix(comptime kind: Kind) u64 {
        return prefix_base + boxedIndex(kind);
    }

    fn box(comptime kind: Kind, raw: u64) u64 {
        std.debug.assert(raw <= payload_mask);
        return (boxedPrefix(kind) << payload_bits) | raw;
    }

    fn Payload(comptime kind: Kind) type {
        return switch (kind) {
            .int, .catch_offset => i32,
            .boolean => bool,
            .float64 => f64,
            .short_big_int => i64,
            .object, .module, .big_int, .string, .symbol, .string_rope, .function_bytecode => *gc.Header,
            .null_value, .undefined_value, .uninitialized, .exception => void,
        };
    }

    fn encode(comptime kind: Kind, value: Payload(kind)) u64 {
        return switch (kind) {
            .int, .catch_offset => payloadFromI32(value),
            .boolean => @intFromBool(value),
            .float64 => @bitCast(value),
            .short_big_int => blk: {
                std.debug.assert(shortBigIntFits(value));
                break :blk @as(u64, @bitCast(value)) & payload_mask;
            },
            .object, .module, .big_int, .string, .symbol, .string_rope, .function_bytecode => @intFromPtr(value) & payload_mask,
            .null_value, .undefined_value, .uninitialized, .exception => 0,
        };
    }

    fn decode(comptime kind: Kind, payload: u64) Payload(kind) {
        return switch (kind) {
            .int, .catch_offset => payloadAsI32(payload),
            .boolean => payload != 0,
            .float64 => @bitCast(payload),
            .short_big_int => @as(i64, @bitCast(payload << 16)) >> 16,
            .object, .module, .big_int, .string, .symbol, .string_rope, .function_bytecode => ptrFromPayload(gc.Header, payload).?,
            .null_value, .undefined_value, .uninitialized, .exception => {},
        };
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

    pub inline fn shortBigIntFits(value: i128) bool {
        return value >= short_big_int_min and value <= short_big_int_max;
    }

    pub inline fn is(self: JSValue, comptime kind: Kind) bool {
        if (comptime kind == .float64) return self.bits <= float_max;
        return (self.bits >> payload_bits) == comptime boxedPrefix(kind);
    }

    pub fn as(self: JSValue, comptime kind: Kind) ?Payload(kind) {
        if (!self.is(kind)) return null;
        if (comptime kind == .float64) return @bitCast(self.bits);
        return decode(kind, self.payloadBits());
    }

    pub fn from(comptime kind: Kind, value: Payload(kind)) JSValue {
        if (comptime kind == .float64) {
            const bits: u64 = @bitCast(value);
            if ((bits & 0x7FFF_FFFF_FFFF_FFFF) > inf_bits) return .{ .bits = canonical_nan };
            return .{ .bits = bits };
        }
        return .{ .bits = box(kind, encode(kind, value)) };
    }

    inline fn payloadBits(self: JSValue) u64 {
        return self.bits & payload_mask;
    }

    pub fn int32(v: i32) JSValue {
        return from(.int, v);
    }

    pub fn float64(v: f64) JSValue {
        return from(.float64, v);
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
        return from(.boolean, v);
    }

    pub fn shortBigInt(v: i64) JSValue {
        return from(.short_big_int, v);
    }

    pub fn bigInt(header: *gc.Header) JSValue {
        return from(.big_int, header);
    }

    pub fn string(header: *gc.Header) JSValue {
        return from(.string, header);
    }

    pub fn stringRope(header: *gc.Header) JSValue {
        return from(.string_rope, header);
    }

    pub fn symbol(header: *gc.Header) JSValue {
        return from(.symbol, header);
    }

    pub fn object(header: *gc.Header) JSValue {
        return from(.object, header);
    }

    pub fn module(header: *gc.Header) JSValue {
        return from(.module, header);
    }

    pub fn functionBytecode(header: *gc.Header) JSValue {
        return from(.function_bytecode, header);
    }

    pub fn nullValue() JSValue {
        return from(.null_value, {});
    }

    pub fn undefinedValue() JSValue {
        return from(.undefined_value, {});
    }

    pub fn uninitialized() JSValue {
        return from(.uninitialized, {});
    }

    pub fn catchOffset(offset: i32) JSValue {
        return from(.catch_offset, offset);
    }

    pub fn exception() JSValue {
        return from(.exception, {});
    }

    pub inline fn tagOf(self: JSValue) i32 {
        if (self.bits <= float_max) return Tag.float64;
        const index: i32 = @intCast((self.bits >> payload_bits) - prefix_base);
        // index 1..3 = kinds −8..−6; index 4..15 = kinds −4..7.
        return index - 8 - @as(i32, @intFromBool(index < 4));
    }

    pub fn isNumber(self: JSValue) bool {
        return self.is(.int) or self.is(.float64);
    }

    pub fn isBigInt(self: JSValue) bool {
        return self.is(.big_int) or self.is(.short_big_int);
    }

    pub fn isString(self: JSValue) bool {
        return self.is(.string) or self.is(.string_rope);
    }

    /// Replace a slot already classified as `Tag.int`.
    pub inline fn setInt32AssumeInt(self: *JSValue, value: i32) void {
        std.debug.assert(self.is(.int));
        self.bits = box(.int, payloadFromI32(value));
    }

    /// Fast form of moving an int32 from one live slot into another: when both
    /// slots already hold `Tag.int`, copy the boxed word. On false, neither
    /// slot is modified and the caller must use the normal replacement path.
    pub inline fn trySetInt32FromSlot(self: *JSValue, source: *const JSValue) bool {
        if (!self.is(.int) or !source.is(.int)) return false;
        self.bits = source.bits;
        return true;
    }

    pub inline fn asInt32Pair(lhs: JSValue, rhs: JSValue) ?Int32Pair {
        if (!lhs.is(.int) or !rhs.is(.int)) return null;
        return .{
            .lhs = payloadAsI32(lhs.payloadBits()),
            .rhs = payloadAsI32(rhs.payloadBits()),
        };
    }

    pub fn asNumber(self: JSValue) ?f64 {
        if (self.as(.int)) |int_value| return @floatFromInt(int_value);
        return self.as(.float64);
    }

    /// QuickJS OP_if_{true,false} classifies the contiguous immediate tag
    /// range [int, undefined] with one unsigned comparison, then reads the
    /// payload as its truth value. In the NaN-box those kinds are prefixes
    /// 0xFFF8..0xFFFB. Null and undefined have a zero payload; references
    /// and floats return null so the caller can use full ToBoolean.
    pub inline fn asBranchImmediateBool(self: JSValue) ?bool {
        const prefix = self.bits >> payload_bits;
        if (prefix < boxedPrefix(.int) or prefix > boxedPrefix(.undefined_value)) return null;
        return self.payloadBits() != 0;
    }

    pub fn asSymbolAtom(self: JSValue) ?u32 {
        const body = self.asSymbolBody() orelse return null;
        if (body.atom_id == string_mod.String.no_atom_id) return null;
        return body.atom_id;
    }

    pub fn asSymbolBody(self: JSValue) ?*string_mod.String {
        if (!self.is(.symbol)) return null;
        return ptrFromPayload(string_mod.String, self.payloadBits());
    }

    /// Extract a BigInt value as a signed i64. Handles BOTH the inline
    /// (short_big_int) and heap (big_int) representations. Returns null for
    /// non-BigInt values and for BigInts whose magnitude exceeds the i64 range
    /// (the i64::MIN edge, magnitude == 1<<63, is handled correctly). Stays in
    /// core: reuses the file-local `bigIntParts`, so it carries no builtins
    /// dependency.
    pub fn asInt64(self: JSValue) ?i64 {
        if (!self.isBigInt()) return null;
        // Fast path: an inline short BigInt always fits i64 by construction.
        if (self.as(.short_big_int)) |short| return short;
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

    /// The catch-handler bytecode offset a catch marker carries, or null when
    /// the marker is the "no handler" sentinel. Three dispatch files spelled
    /// this decode out; it belongs next to the encoding it decodes.
    pub fn catchTarget(self: JSValue) ?usize {
        const offset = self.as(.catch_offset) orelse -1;
        if (offset < 0) return null;
        return @intCast(offset);
    }

    pub fn asString(self: JSValue) ?String {
        return String.fromValue(self);
    }

    /// Value→String boundary (qjs `js_linearize_string_rope` call site): a
    /// `.string_rope` value is MATERIALIZED into a flat string and the borrowed
    /// flat `*String` is returned, so every downstream reader sees a flat
    /// string. `.string`/`.symbol` values return their body directly.
    pub fn asStringBody(self: JSValue) ?*string_mod.String {
        switch (self.tagOf()) {
            Tag.string, Tag.symbol => return ptrFromPayload(string_mod.String, self.payloadBits()),
            Tag.string_rope => {
                const node = self.ropeBody() orelse return null;
                return node.flattenInfallible();
            },
            else => return null,
        }
    }

    /// Raw string body WITHOUT flattening: returns the `*String` for
    /// `.string`/`.symbol` and null for a rope (which is not a `*String`).
    /// Used by the rope-internal walkers that already discriminate on tag.
    pub fn asStringBodyRaw(self: JSValue) ?*string_mod.String {
        switch (self.tagOf()) {
            Tag.string, Tag.symbol => return ptrFromPayload(string_mod.String, self.payloadBits()),
            else => return null,
        }
    }

    /// The `StringRope` behind a `.string_rope` value (null otherwise).
    pub fn ropeBody(self: JSValue) ?*string_mod.StringRope {
        if (!self.is(.string_rope)) return null;
        return ptrFromPayload(string_mod.StringRope, self.payloadBits());
    }

    pub fn asBytes(self: JSValue) Bytes.Error!Bytes {
        return Bytes.fromValue(self);
    }

    pub fn refHeader(self: JSValue) ?*gc.Header {
        return switch (self.tagOf()) {
            Tag.big_int, Tag.object, Tag.module => ptrFromPayload(gc.Header, self.payloadBits()),
            else => null,
        };
    }

    /// qjs `JS_VALUE_GET_OBJ`: tag already proven, payload is the object.
    /// Release does not re-test a null pointer (F1); Debug still asserts.
    pub inline fn refHeaderAssumeObject(self: JSValue) *gc.Header {
        std.debug.assert(self.is(.object));
        const payload = self.payloadBits();
        std.debug.assert(payload != 0);
        return @ptrFromInt(payload);
    }

    pub fn stringHeader(self: JSValue) ?*gc.Header {
        return switch (self.tagOf()) {
            Tag.symbol, Tag.string, Tag.string_rope => ptrFromPayload(gc.Header, self.payloadBits()),
            else => null,
        };
    }

    /// Direct payload access for call sites that have already classified the
    /// tag as string/symbol/string_rope. Mirrors QJS's JS_VALUE_GET_STRING*
    /// macros and avoids repeating the tag switch while collecting multiple
    /// rope operand fields.
    pub inline fn stringHeaderAssumeStringLike(self: JSValue) *gc.Header {
        const tag = self.tagOf();
        std.debug.assert(tag == Tag.string or tag == Tag.symbol or tag == Tag.string_rope);
        return ptrFromPayload(gc.Header, self.payloadBits()).?;
    }

    /// Header of a `.function_bytecode` value. Not a generic JS object.
    pub fn functionBytecodeHeader(self: JSValue) ?*gc.Header {
        if (!self.is(.function_bytecode)) return null;
        return ptrFromPayload(gc.Header, self.payloadBits());
    }

    /// `JS_MarkValue` filter (quickjs.c:6553-6566) widened by one tag: OBJECT /
    /// FUNCTION_BYTECODE / MODULE plus heap BIG_INT, which is a leaf on
    /// `lists.objects` since S1-c (qjs keeps BigInt refcounted; zjs traces it).
    /// Boxed prefixes 0xFFF1..0xFFF7 are that tag set; one unsigned range on
    /// the raw word.
    pub inline fn cycleMarkHeader(self: JSValue) ?*gc.Header {
        if (!self.isTracerOwned()) return null;
        return ptrFromPayload(gc.Header, self.payloadBits());
    }

    /// Whether the tracing collector owns this value's lifetime: exactly the
    /// tag set `cycleMarkHeader` accepts. Store/barrier fast paths use the
    /// negation (both sides immediate → skip rooting and the generational barrier).
    pub inline fn isTracerOwned(self: JSValue) bool {
        return self.bits >= first_boxed and self.bits < tracer_owned_end;
    }

    pub fn same(self: JSValue, other: JSValue) bool {
        if (self.bits == other.bits) return true;
        const tag = self.tagOf();
        if (tag != other.tagOf()) return false;
        return switch (tag) {
            Tag.null_value, Tag.undefined_value, Tag.uninitialized, Tag.exception => true,
            Tag.float64 => false,
            Tag.symbol, Tag.string, Tag.string_rope, Tag.big_int, Tag.module, Tag.function_bytecode, Tag.object, Tag.int, Tag.boolean, Tag.catch_offset, Tag.short_big_int => self.payloadBits() == other.payloadBits(),
            else => unreachable,
        };
    }

    pub fn sameValue(self: JSValue, other: JSValue) bool {
        if (self.asNumber()) |lhs| {
            if (other.asNumber()) |rhs| {
                if (std.math.isNan(lhs) and std.math.isNan(rhs)) return true;
                if (lhs == 0 and rhs == 0) return isNegativeZero(lhs) == isNegativeZero(rhs);
                return lhs == rhs;
            }
        }
        if (self.isBigInt() and other.isBigInt()) {
            return (compareBigIntValues(self, other) orelse return false) == .eq;
        }
        if (self.as(.boolean)) |lhs| {
            if (other.as(.boolean)) |rhs| return lhs == rhs;
        }
        if (self.is(.null_value) or self.is(.undefined_value)) return self.same(other);
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
        if (self.asNumber()) |lhs| {
            if (other.asNumber()) |rhs| {
                if (std.math.isNan(lhs) and std.math.isNan(rhs)) return true;
                return lhs == rhs;
            }
        }
        if (self.as(.boolean)) |lhs| {
            if (other.as(.boolean)) |rhs| return lhs == rhs;
        }
        if (self.is(.null_value) or self.is(.undefined_value)) return self.same(other);
        if (self.isBigInt() and other.isBigInt()) return self.sameValue(other);
        if (self.isString() and other.isString()) {
            if (self.same(other)) return true;
            return (compareStringValues(self, other) orelse 1) == 0;
        }
        return self.same(other);
    }
};

/// i32 tag numbers for switches on `tagOf()`. Prefer `JSValue.Kind` / `is(.int)`.
pub const Tag = struct {
    pub const symbol: i32 = @intFromEnum(JSValue.Kind.symbol);
    pub const string: i32 = @intFromEnum(JSValue.Kind.string);
    pub const string_rope: i32 = @intFromEnum(JSValue.Kind.string_rope);
    pub const big_int: i32 = @intFromEnum(JSValue.Kind.big_int);
    pub const module: i32 = @intFromEnum(JSValue.Kind.module);
    pub const function_bytecode: i32 = @intFromEnum(JSValue.Kind.function_bytecode);
    pub const object: i32 = @intFromEnum(JSValue.Kind.object);
    pub const int: i32 = @intFromEnum(JSValue.Kind.int);
    pub const boolean: i32 = @intFromEnum(JSValue.Kind.boolean);
    pub const null_value: i32 = @intFromEnum(JSValue.Kind.null_value);
    pub const undefined_value: i32 = @intFromEnum(JSValue.Kind.undefined_value);
    pub const uninitialized: i32 = @intFromEnum(JSValue.Kind.uninitialized);
    pub const catch_offset: i32 = @intFromEnum(JSValue.Kind.catch_offset);
    pub const exception: i32 = @intFromEnum(JSValue.Kind.exception);
    pub const short_big_int: i32 = @intFromEnum(JSValue.Kind.short_big_int);
    pub const float64: i32 = @intFromEnum(JSValue.Kind.float64);
};

pub fn isZeroBigInt(value: JSValue) ?bool {
    var scratch: [2]bignum.Limb = undefined;
    const parts = bigIntParts(value, &scratch) orelse return null;
    return parts.limbs.len == 0 or (parts.limbs.len == 1 and parts.limbs[0] == 0);
}

fn isNegativeZero(value: f64) bool {
    return value == 0 and std.math.isNegativeInf(1.0 / value);
}

fn compareStringValues(a: JSValue, b: JSValue) ?i32 {
    return string_mod.compareStringValues(a, b, true);
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
    if (value.as(.short_big_int)) |short| {
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
        return .{ .negative = big.negative(), .limbs = big.limbs() };
    }
    return null;
}

test "QuickJS value tag constants are locked" {
    const t = std.testing;
    try t.expectEqual(@as(i32, -8), Tag.symbol);
    try t.expectEqual(@as(i32, -7), Tag.string);
    try t.expectEqual(@as(i32, -6), Tag.string_rope);
    try t.expectEqual(@as(i32, -4), Tag.big_int);
    try t.expectEqual(@as(i32, -3), Tag.module);
    try t.expectEqual(@as(i32, -2), Tag.function_bytecode);
    try t.expectEqual(@as(i32, -1), Tag.object);
    try t.expectEqual(@as(i32, 0), Tag.int);
    try t.expectEqual(@as(i32, 1), Tag.boolean);
    try t.expectEqual(@as(i32, 2), Tag.null_value);
    try t.expectEqual(@as(i32, 3), Tag.undefined_value);
    try t.expectEqual(@as(i32, 4), Tag.uninitialized);
    try t.expectEqual(@as(i32, 5), Tag.catch_offset);
    try t.expectEqual(@as(i32, 6), Tag.exception);
    try t.expectEqual(@as(i32, 7), Tag.short_big_int);
    try t.expectEqual(@as(i32, 8), Tag.float64);
}

test "NaN-box prefix is dense Kind index, not a lookup table" {
    const t = std.testing;
    try t.expectEqual(@as(u64, 0xFFF8_0000_0000_002A), JSValue.int32(42).bits);
    try t.expectEqual(@as(u64, 0xFFF8_0000_FFFF_FFFF), JSValue.int32(-1).bits);
    try t.expectEqual(@as(u64, 0xFFF9_0000_0000_0001), JSValue.boolean(true).bits);
    try t.expectEqual(@as(u64, 0xFFFA_0000_0000_0000), JSValue.nullValue().bits);
    try t.expectEqual(@as(u64, 0xFFFB_0000_0000_0000), JSValue.undefinedValue().bits);
    try t.expectEqual(@as(u64, 0xFFFF_0000_0000_0005), JSValue.shortBigInt(5).bits);
    try t.expectEqual(@as(i64, -1), JSValue.shortBigInt(-1).as(.short_big_int).?);
    try t.expectEqual(JSValue.short_big_int_min, JSValue.shortBigInt(JSValue.short_big_int_min).as(.short_big_int).?);

    try t.expect(!JSValue.int32(0).isTracerOwned());
    try t.expect(!JSValue.undefinedValue().isTracerOwned());
    try t.expect(!JSValue.float64(1).isTracerOwned());

    var header: gc.Header = undefined;
    const obj = JSValue.object(&header);
    try t.expectEqual(@as(u64, 0xFFF7), obj.bits >> 48);
    try t.expect(obj.isTracerOwned());
    try t.expectEqual(@as(?*gc.Header, &header), obj.cycleMarkHeader());

    const signed_nan = JSValue.float64(@bitCast(@as(u64, 0xFFF8_0000_0000_0001)));
    try t.expect(signed_nan.is(.float64));
    try t.expect(!signed_nan.is(.int));
    try t.expect(!signed_nan.is(.object));
    try t.expectEqual(@as(u64, 0x7FF8_0000_0000_0000), signed_nan.bits);
}

test "every JSValue constructor recovers its QuickJS semantic tag" {
    const t = std.testing;
    var header: gc.Header = undefined;
    var string_header: gc.Header = undefined;
    var object_header: gc.Header = undefined;

    const cases = [_]struct { value: JSValue, tag: i32 }{
        .{ .value = JSValue.symbol(&string_header), .tag = Tag.symbol },
        .{ .value = JSValue.string(&string_header), .tag = Tag.string },
        .{ .value = JSValue.stringRope(&string_header), .tag = Tag.string_rope },
        .{ .value = JSValue.bigInt(&header), .tag = Tag.big_int },
        .{ .value = JSValue.module(&header), .tag = Tag.module },
        .{ .value = JSValue.functionBytecode(&object_header), .tag = Tag.function_bytecode },
        .{ .value = JSValue.object(&header), .tag = Tag.object },
        .{ .value = JSValue.int32(-42), .tag = Tag.int },
        .{ .value = JSValue.boolean(true), .tag = Tag.boolean },
        .{ .value = JSValue.nullValue(), .tag = Tag.null_value },
        .{ .value = JSValue.undefinedValue(), .tag = Tag.undefined_value },
        .{ .value = JSValue.uninitialized(), .tag = Tag.uninitialized },
        .{ .value = JSValue.catchOffset(-7), .tag = Tag.catch_offset },
        .{ .value = JSValue.exception(), .tag = Tag.exception },
        .{ .value = JSValue.shortBigInt(-123), .tag = Tag.short_big_int },
        .{ .value = JSValue.float64(-1.5), .tag = Tag.float64 },
    };

    for (cases) |case| {
        try t.expectEqual(case.tag, case.value.tagOf());
        try t.expect(case.value.same(case.value));
    }
    try t.expect(JSValue.from(.int, @as(i32, -42)).is(.int));
    try t.expectEqual(@as(?i32, -42), JSValue.from(.int, @as(i32, -42)).as(.int));
    try t.expect(JSValue.from(.boolean, true).as(.boolean).?);
}

test "QuickJS branch immediate range admits int bool null and undefined only" {
    const t = std.testing;
    var object_header: gc.Header = undefined;
    const cases = [_]struct {
        value: JSValue,
        expected: ?bool,
    }{
        .{ .value = JSValue.int32(-1), .expected = true },
        .{ .value = JSValue.int32(0), .expected = false },
        .{ .value = JSValue.int32(1), .expected = true },
        .{ .value = JSValue.boolean(false), .expected = false },
        .{ .value = JSValue.boolean(true), .expected = true },
        .{ .value = JSValue.nullValue(), .expected = false },
        .{ .value = JSValue.undefinedValue(), .expected = false },
        .{ .value = JSValue.object(&object_header), .expected = null },
        .{ .value = JSValue.float64(1), .expected = null },
        .{ .value = JSValue.uninitialized(), .expected = null },
        .{ .value = JSValue.shortBigInt(1), .expected = null },
    };

    for (cases) |case| {
        try t.expectEqual(case.expected, case.value.asBranchImmediateBool());
    }
}

test "heap JSValue payloads name collector handles directly" {
    const t = std.testing;
    const pointerPayload = struct {
        fn get(value: JSValue) usize {
            return @intCast(value.payloadBits());
        }
    }.get;

    var gc_storage: [@sizeOf(gc.Metadata) + @sizeOf(gc.Header)]u8 align(@alignOf(gc.Header)) = undefined;
    const gc_meta: *gc.Metadata = @ptrCast(@alignCast(&gc_storage));
    const gc_header: *gc.Header = @ptrCast(@alignCast(&gc_storage[@sizeOf(gc.Metadata)]));
    gc_meta.* = .{};
    gc_header.* = .{};

    var flat_storage: [gc.string_prefix_size + @sizeOf(string_mod.String)]u8 align(@alignOf(gc.Metadata)) = undefined;
    const flat_body: *string_mod.String = @ptrCast(@alignCast(&flat_storage[gc.string_prefix_size]));
    flat_body.metadata().* = .{ .flags = .{ .kind = .string } };
    const flat_header = flat_body.header();

    var rope_storage: [string_mod.StringRope.metadata_prefix_size + @sizeOf(string_mod.StringRope)]u8 align(@alignOf(string_mod.StringRope)) = undefined;
    const rope_body: *string_mod.StringRope = @ptrCast(@alignCast(&rope_storage[string_mod.StringRope.metadata_prefix_size]));
    rope_body.metadata().* = .{ .flags = .{ .kind = .string } };
    const rope_header = rope_body.header();

    const cases = [_]struct {
        value: JSValue,
        body_address: usize,
    }{
        .{ .value = JSValue.bigInt(gc_header), .body_address = @intFromPtr(gc_header) },
        .{ .value = JSValue.symbol(flat_header), .body_address = @intFromPtr(flat_body) },
        .{ .value = JSValue.string(flat_header), .body_address = @intFromPtr(flat_body) },
        .{ .value = JSValue.stringRope(rope_header), .body_address = @intFromPtr(rope_body) },
        .{ .value = JSValue.module(gc_header), .body_address = @intFromPtr(gc_header) },
        .{ .value = JSValue.functionBytecode(gc_header), .body_address = @intFromPtr(gc_header) },
        .{ .value = JSValue.object(gc_header), .body_address = @intFromPtr(gc_header) },
    };

    for (cases) |case| {
        try t.expectEqual(case.body_address, pointerPayload(case.value));
    }
}

test "primitive value predicates match QuickJS helpers" {
    const t = std.testing;
    try t.expect(JSValue.int32(1).isNumber());
    try t.expect(JSValue.float64(1.5).isNumber());
    try t.expect(JSValue.boolean(false).is(.boolean));
    try t.expect(JSValue.nullValue().is(.null_value));
    try t.expect(JSValue.undefinedValue().is(.undefined_value));
    try t.expect(JSValue.uninitialized().is(.uninitialized));
    try t.expect(JSValue.exception().is(.exception));
    try t.expect(JSValue.shortBigInt(42).isBigInt());
    try t.expectEqual(@as(?i32, 7), JSValue.int32(7).as(.int));
    try t.expectEqual(@as(?i32, null), JSValue.float64(7).as(.int));
}

test "int32 same-tag update preserves the value representation invariant" {
    const t = std.testing;
    var value = JSValue.int32(-1);
    value.setInt32AssumeInt(1234567);

    try t.expectEqual(Tag.int, value.tagOf());
    try t.expectEqual(@as(?i32, 1234567), value.as(.int));
}

test "int32 slot move copies the payload when both slots already hold ints" {
    const t = std.testing;
    var destination = JSValue.int32(11);
    const source = JSValue.int32(22);

    try t.expect(destination.trySetInt32FromSlot(&source));
    try t.expectEqual(@as(?i32, 22), destination.as(.int));

    var non_int = JSValue.boolean(false);
    try t.expect(!non_int.trySetInt32FromSlot(&source));
    try t.expectEqual(@as(?bool, false), non_int.as(.boolean));
}

test "float construction is valid" {
    const t = std.testing;
    const finite = JSValue.float64(1.5);
    try t.expectEqual(@as(?f64, 1.5), finite.as(.float64));

    const negative_zero = JSValue.float64(-0.0);
    const negative_zero_value = negative_zero.as(.float64).?;
    try t.expect(negative_zero_value == 0.0);
    try t.expectEqual(@as(u64, 0x8000_0000_0000_0000), @as(u64, @bitCast(negative_zero_value)));

    const nan_value = JSValue.float64(@bitCast(@as(u64, 0x7FF8_0000_0000_0042)));
    try t.expect(std.math.isNan(nan_value.as(.float64).?));
}

test "cycleMarkHeader matches JS_MarkValue tag set" {
    const t = std.testing;
    var dummy: gc.Header = undefined;

    try t.expect(JSValue.int32(1).cycleMarkHeader() == null);
    try t.expect(JSValue.undefinedValue().cycleMarkHeader() == null);
    try t.expect(JSValue.nullValue().cycleMarkHeader() == null);
    try t.expect(JSValue.boolean(true).cycleMarkHeader() == null);

    try t.expectEqual(@as(?*gc.Header, &dummy), JSValue.object(&dummy).cycleMarkHeader());
    try t.expectEqual(@as(?*gc.Header, &dummy), JSValue.module(&dummy).cycleMarkHeader());
    try t.expectEqual(@as(?*gc.Header, &dummy), JSValue.functionBytecode(&dummy).cycleMarkHeader());

    // Heap BigInt is tracer-owned since S1-c: marked like an object, no
    // common refcount word (qjs 6557-6564 skips it because qjs refcounts it).
    try t.expectEqual(@as(?*gc.Header, &dummy), JSValue.bigInt(&dummy).cycleMarkHeader());
    try t.expect(JSValue.bigInt(&dummy).isTracerOwned());
}

test "asInt64 / asUint64 on inline short BigInt and non-BigInt" {
    const t = std.testing;

    // Non-BigInt values must extract as null on both.
    try t.expectEqual(@as(?i64, null), JSValue.int32(7).asInt64());
    try t.expectEqual(@as(?u64, null), JSValue.int32(7).asUint64());
    try t.expectEqual(@as(?i64, null), JSValue.float64(1.5).asInt64());
    try t.expectEqual(@as(?u64, null), JSValue.boolean(true).asUint64());

    // Inline short BigInt across its representable range: the 48-bit payload
    // is sign-extended, so the bounds are short_big_int_min/max.
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

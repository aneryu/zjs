const std = @import("std");
const build_options = @import("build_options");

const bignum = @import("../libs/bigint.zig");
const gc = @import("gc.zig");
const string_mod = @import("string.zig");

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

    // Preserve QuickJS's semantic tag order inside the dense boxed prefix
    // space. The two numeric tag runs [-9..-6] and [-3..7] map to prefix
    // indexes [1..4] and [5..15], respectively, so `tagOf` can invert the
    // encoding arithmetically instead of loading a tag from a lookup table.
    // Reference-counted and deinit-skip tags remain contiguous, retaining the
    // single range checks used by `requiresRefCount`/`dup`/`free`.
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

    /// Inclusive prefix range of all reference-counted tags.
    const refcount_min: u64 = prefixOf(Tag.big_int);
    const refcount_max: u64 = prefixOf(Tag.object);
    /// Lowest prefix of the deinit-phase skip set {module, object, function_bytecode}.
    const deinit_skip_min: u64 = prefixOf(Tag.module);

    inline fn prefixBits(bits: u64) u64 {
        return bits >> payload_bits;
    }

    const tag_assertions = blk: {
        // Dense indexes must decode to the semantic QuickJS tags without a
        // table. This also pins the otherwise-unused -5/-4 holes in the tag
        // number line between the two runs.
        for (boxed_tags, 1..) |tag, index| {
            if (tagFromIndex(index) != tag) @compileError("boxed tag order is not arithmetically decodable");
        }
        // Refcounted tags must form the contiguous range [refcount_min, refcount_max].
        for ([_]i32{ Tag.big_int, Tag.symbol, Tag.string, Tag.string_rope, Tag.module, Tag.object, Tag.function_bytecode }) |tag| {
            const p = prefixOf(tag);
            if (p < refcount_min or p > refcount_max) @compileError("refcounted tag escaped the contiguous prefix range");
        }
        // Non-refcounted boxed tags must sit OUTSIDE that range.
        for ([_]i32{ Tag.int, Tag.boolean, Tag.null_value, Tag.undefined_value, Tag.uninitialized, Tag.catch_offset, Tag.exception, Tag.short_big_int }) |tag| {
            const p = prefixOf(tag);
            if (p >= refcount_min and p <= refcount_max) @compileError("non-refcounted tag landed inside the refcount prefix range");
        }
        // The deinit-skip set must be the contiguous tail [deinit_skip_min, refcount_max].
        for ([_]i32{ Tag.module, Tag.object, Tag.function_bytecode }) |tag| {
            const p = prefixOf(tag);
            if (p < deinit_skip_min or p > refcount_max) @compileError("deinit-skip tag escaped its contiguous range");
        }
        // Float canonical range must be strictly below the boxed prefixes.
        if (refcount_min <= (float_max >> payload_bits)) @compileError("refcount prefixes overlap the float range");
        break :blk true;
    };

    /// Dense 1-based tag index; index 0 is reserved so that no boxed encoding
    /// can collide with the canonical float range.
    fn indexOf(comptime tag: i32) u64 {
        return switch (tag) {
            Tag.big_int...Tag.string_rope => @intCast(tag + 10),
            Tag.module...Tag.short_big_int => @intCast(tag + 8),
            else => @compileError("tag is not representable in the NaN-boxed encoding"),
        };
    }

    inline fn tagFromIndex(index: u64) i32 {
        const dense: i32 = @intCast(index);
        // Indexes 1..4 make `dense - 5` negative; its sign bit restores the
        // two unused semantic tags before the second run without a branch.
        const before_second_run: u32 = @bitCast(dense - 5);
        return dense - 8 - @as(i32, @intCast((before_second_run >> 31) * 2));
    }

    /// High 16 bits of a boxed encoding for `tag`.
    fn prefixOf(comptime tag: i32) u64 {
        return (float_max >> payload_bits) | indexOf(tag);
    }
};

pub const JSValue = extern struct {
    pub const Int32Pair = struct {
        lhs: i32,
        rhs: i32,
    };

    pub const Scope = @import("runtime.zig").HandleScope;
    pub const Local = @import("runtime.zig").LocalHandle;
    pub const Persistent = @import("runtime.zig").JSValueHandle;
    pub const Weak = @import("runtime.zig").WeakPersistentValue;
    pub const String = @import("string_view.zig").JSString(JSValue);
    pub const Bytes = @import("bytes_view.zig").JSBytes(JSValue);

    /// Packed-value encoding revision included in the plugin ABI fingerprint.
    /// Zero means the field layout fully describes the representation.
    pub const abi_encoding_revision: u64 = if (nan_boxing) 3 else 1;

    pub const Repr = if (nan_boxing) extern struct {
        bits: u64,
    } else extern struct {
        payload: u64,
        // 8-byte tag (matches QuickJS's `int64_t tag` on 64-bit, not a narrow
        // i32+pad). Critical for codegen: LLVM keeps the 16-byte JSValue in a SIMD
        // (q) register, so reading the tag means a store-to-load round-trip. A 4-byte
        // i32 load at offset 8 from the 16-byte store only PARTIALLY overlaps and
        // stalls (no clean store-forwarding); a full 8-byte load forwards cleanly.
        // Widening i32+pad → i64 cut the int+float `s=s+i` loop's backend-stall
        // cycles ~63% (713ms→566ms) with zero conformance-suite change.
        tag: i64,
    };

    repr: Repr,

    comptime {
        std.debug.assert(@sizeOf(JSValue) == if (nan_boxing) 8 else 16);
        std.debug.assert(@alignOf(JSValue) == 8);
        if (nan_boxing) _ = NanBox.tag_assertions;
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
            if (comptime tag == Tag.float64) {
                // Floats are the one semantic tag that is not boxed. Keep the
                // unified constructor total over every Tag while preserving
                // the canonical-NaN invariant that separates raw IEEE values
                // from the boxed prefix range.
                if ((payload & 0x7FFF_FFFF_FFFF_FFFF) > 0x7FF0_0000_0000_0000) {
                    return .{ .repr = .{ .bits = NanBox.canonical_nan } };
                }
                return .{ .repr = .{ .bits = payload } };
            }
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

    pub fn string(header: *gc.StringHeader) JSValue {
        return make(Tag.string, @intFromPtr(header) + gc.ref_count_offset_from_payload);
    }

    pub fn stringRope(header: *gc.StringHeader) JSValue {
        return make(Tag.string_rope, @intFromPtr(header) + gc.ref_count_offset_from_payload);
    }

    pub fn symbol(header: *gc.StringHeader) JSValue {
        return make(Tag.symbol, @intFromPtr(header) + gc.ref_count_offset_from_payload);
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
            return NanBox.tagFromIndex((self.repr.bits >> NanBox.payload_bits) & 0xF);
        }
        return @intCast(self.repr.tag);
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
        if (comptime nan_boxing) {
            // Single prefix range test, no `tag_by_index` table load. Floats
            // (prefix <= float range) and non-refcounted boxed tags (prefix >
            // refcount_max) both fall outside [refcount_min, refcount_max].
            const p = NanBox.prefixBits(self.repr.bits);
            return p >= NanBox.refcount_min and p <= NanBox.refcount_max;
        }
        // QuickJS deliberately uses one unsigned range comparison here:
        // negative refcounted tags [-9..-1] (including the unreachable -5/-4
        // holes) compare above every non-negative immediate tag.
        const tag: u64 = @bitCast(self.repr.tag);
        const first: u64 = @bitCast(@as(i64, Tag.first));
        return tag >= first;
    }

    pub fn asInt32(self: JSValue) ?i32 {
        if (self.hasTag(Tag.int)) return payloadAsI32(self.payloadOf());
        return null;
    }

    pub inline fn asInt32Pair(lhs: JSValue, rhs: JSValue) ?Int32Pair {
        if (comptime nan_boxing) {
            const int_prefix_bits = comptime NanBox.prefixOf(Tag.int) << NanBox.payload_bits;
            const tag_mask = comptime ~NanBox.payload_mask;
            if ((((lhs.repr.bits ^ int_prefix_bits) | (rhs.repr.bits ^ int_prefix_bits)) & tag_mask) != 0) return null;
            return .{
                .lhs = payloadAsI32(lhs.repr.bits),
                .rhs = payloadAsI32(rhs.repr.bits),
            };
        }
        if (comptime Tag.int == 0) {
            if ((lhs.repr.tag | rhs.repr.tag) != 0) return null;
        } else {
            if (((lhs.repr.tag ^ Tag.int) | (rhs.repr.tag ^ Tag.int)) != 0) return null;
        }
        return .{
            .lhs = payloadAsI32(lhs.repr.payload),
            .rhs = payloadAsI32(rhs.repr.payload),
        };
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
        const body = self.asSymbolBody() orelse return null;
        if (body.atom_id == string_mod.String.no_atom_id) return null;
        return body.atom_id;
    }

    pub fn asSymbolBody(self: JSValue) ?*string_mod.String {
        if (!self.hasTag(Tag.symbol)) return null;
        return ptrFromPayload(string_mod.String, self.payloadOf());
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

    /// Value→String boundary (qjs `js_linearize_string_rope` call site): a
    /// `.string_rope` value is MATERIALIZED into a flat string and the borrowed
    /// flat `*String` is returned, so every downstream reader sees a flat
    /// string. `.string`/`.symbol` values return their body directly.
    pub fn asStringBody(self: JSValue) ?*string_mod.String {
        switch (self.tagOf()) {
            Tag.string, Tag.symbol => return ptrFromPayload(string_mod.String, self.payloadOf()),
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
            Tag.string, Tag.symbol => return ptrFromPayload(string_mod.String, self.payloadOf()),
            else => return null,
        }
    }

    /// The `StringRope` behind a `.string_rope` value (null otherwise).
    pub fn ropeBody(self: JSValue) ?*string_mod.StringRope {
        if (!self.hasTag(Tag.string_rope)) return null;
        return ptrFromPayload(string_mod.StringRope, self.payloadOf());
    }

    pub fn asBytes(self: JSValue, ctx: anytype) Bytes.Error!Bytes {
        _ = ctx;
        return Bytes.fromValue(self);
    }

    pub fn refHeader(self: JSValue) ?*gc.Header {
        return switch (self.tagOf()) {
            Tag.big_int, Tag.object, Tag.module => ptrFromPayload(gc.Header, self.payloadOf()),
            else => null,
        };
    }

    pub fn stringHeader(self: JSValue) ?*gc.StringHeader {
        return switch (self.tagOf()) {
            Tag.symbol, Tag.string, Tag.string_rope => self.refCountWordAssumeRefCounted(),
            else => null,
        };
    }

    /// Direct payload access for call sites that have already classified the
    /// tag as string/symbol/string_rope. Mirrors QJS's JS_VALUE_GET_STRING*
    /// macros and avoids repeating the tag switch while collecting multiple
    /// rope operand fields.
    pub inline fn stringHeaderAssumeStringLike(self: JSValue) *gc.StringHeader {
        const tag = self.tagOf();
        std.debug.assert(tag == Tag.string or tag == Tag.symbol or tag == Tag.string_rope);
        return self.refCountWordAssumeRefCounted();
    }

    pub fn objectHeader(self: JSValue) ?*gc.GCObjectHeader {
        return switch (self.tagOf()) {
            Tag.function_bytecode => ptrFromPayload(gc.GCObjectHeader, self.payloadOf()),
            else => null,
        };
    }

    /// Full GC headers only. Strings and symbols use `stringHeader()` because
    /// their bodies are refcount-only and do not carry cycle-list links.
    pub fn refCountHeader(self: JSValue) ?*gc.Header {
        return switch (self.tagOf()) {
            Tag.big_int, Tag.object, Tag.module, Tag.function_bytecode => ptrFromPayload(gc.Header, self.payloadOf()),
            else => null,
        };
    }

    pub inline fn dup(self: JSValue) JSValue {
        if (comptime nan_boxing) {
            const p = NanBox.prefixBits(self.repr.bits);
            if (p >= NanBox.refcount_min and p <= NanBox.refcount_max) {
                gc.retain(self.refCountWordAssumeRefCounted());
            }
            return self;
        }
        if (!self.requiresRefCount()) return self;
        gc.retain(self.refCountWordAssumeRefCounted());
        return self;
    }

    pub inline fn free(self: JSValue, rt: anytype) void {
        comptime {
            @setEvalBranchQuota(10_000);
        }
        if (comptime nan_boxing) {
            const p = NanBox.prefixBits(self.repr.bits);
            if (p < NanBox.refcount_min or p > NanBox.refcount_max) return;
            // deinit-phase skip for {module, object, function_bytecode} — the
            // contiguous tail [deinit_skip_min, refcount_max].
            if (rt.gc.phase == .deinit and p >= NanBox.deinit_skip_min) return;
            if (comptime build_options.zjs_enable_opcode_profile) {
                if (rt.opcode_profile) |prof| prof.recordValueFree();
            }
            self.releaseCommonRefCount(rt);
            return;
        }
        if (!self.requiresRefCount()) return;
        const tag = self.tagOf();
        if (rt.gc.phase == .deinit and tag >= Tag.module and tag <= Tag.object) return;
        if (comptime build_options.zjs_enable_opcode_profile) {
            if (rt.opcode_profile) |prof| prof.recordValueFree();
        }
        self.releaseCommonRefCount(rt);
    }

    inline fn refCountWordAssumeRefCounted(self: JSValue) *gc.RefCountHeader {
        const payload = ptrFromPayload(anyopaque, self.payloadOf()).?;
        return gc.refCountHeaderFromPayload(payload);
    }

    inline fn releaseCommonRefCount(self: JSValue, rt: anytype) void {
        const hdr = self.refCountWordAssumeRefCounted();
        std.debug.assert(hdr.rc > 0);
        hdr.rc -= 1;
        if (hdr.rc == 0) self.destroyZeroRef(rt);
    }

    /// QuickJS `__JS_FreeValue` analogue: tag dispatch is paid only when the
    /// common payload-4 refcount reaches zero.
    noinline fn destroyZeroRef(self: JSValue, rt: anytype) void {
        switch (self.tagOf()) {
            Tag.string, Tag.symbol => string_mod.String.destroyFromHeader(rt, self.refCountWordAssumeRefCounted()),
            Tag.string_rope => string_mod.destroyRope(rt, self.ropeBody().?),
            Tag.big_int, Tag.module, Tag.function_bytecode, Tag.object => gc.destroyZeroRef(rt, ptrFromPayload(gc.Header, self.payloadOf()).?),
            else => unreachable,
        }
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

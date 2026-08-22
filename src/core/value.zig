//! The engine's 16-byte tagged JSValue representation and refcount operations.
//!
//! Immediate values are copied freely; object/string/symbol/bytecode/module
//! values own one reference per JSValue and `dup`/`free` must balance against
//! the originating Runtime. Borrowed views never extend that lifetime. The
//! extern `Repr` field order, 8-byte tag, tag numbers, and alignment are
//! compiler/plugin ABI and dispatch-codegen pins. QuickJS source map: JSValue
//! tag/payload accessors in quickjs.h and the pointer decoders at
//! quickjs.c:224-231. This core leaf is consumed throughout the engine and
//! cannot depend on exec or binding.

const std = @import("std");

const bignum = @import("../libs/bigint.zig");
const gc = @import("gc.zig");
const string_mod = @import("string.zig");

/// Value-free profile hooks stay off even in `zjs-profile`. Compiling them
/// into JSValue.free / call-profile guards slid WPO (zlib SIGSEGV, `sp==0`
/// into `op_return`). Dispatch counts live in `cont`/`next` only.
const value_free_profile = false;

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
    /// Zero would mean the field layout fully describes the representation.
    /// Bump this if the meaning of the payload/tag pair ever changes without a
    /// visible change in field types; plugins compiled against a different
    /// revision are rejected by the fingerprint.
    pub const abi_encoding_revision: u64 = 1;

    pub const Repr = extern struct {
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
        std.debug.assert(@sizeOf(JSValue) == 16);
        std.debug.assert(@alignOf(JSValue) == 8);
    }

    /// Number of bits available for the immediate short big int payload. The
    /// payload word holds the value outright, so this is the full i64 range.
    pub const short_big_int_bits: u16 = 64;
    pub const short_big_int_min: i64 = std.math.minInt(i64);
    pub const short_big_int_max: i64 = std.math.maxInt(i64);

    pub inline fn shortBigIntFits(value: i128) bool {
        return value >= short_big_int_min and value <= short_big_int_max;
    }

    inline fn make(comptime tag: i32, payload: u64) JSValue {
        return .{ .repr = .{ .payload = payload, .tag = tag } };
    }

    inline fn hasTag(self: JSValue, comptime tag: i32) bool {
        return self.repr.tag == tag;
    }

    inline fn payloadOf(self: JSValue) u64 {
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

    /// Replace an already-proven int32 value without changing its semantic tag.
    /// The caller must have classified this exact slot as `Tag.int`. Keeping the
    /// operation in the JSValue module lets it update only the payload word
    /// instead of rebuilding the whole value.
    pub inline fn setInt32AssumeInt(self: *JSValue, value: i32) void {
        std.debug.assert(self.hasTag(Tag.int));
        self.repr.payload = payloadFromI32(value);
    }

    /// Fast form of moving an int32 from one live slot into another: when both
    /// slots already hold `Tag.int`, preserve the proven tag and copy only the
    /// payload, avoiding an aggregate copy and refcount classification. On
    /// false, neither slot is modified and the caller must use the normal
    /// ownership-aware replacement path.
    pub inline fn trySetInt32FromSlot(self: *JSValue, source: *const JSValue) bool {
        if (comptime Tag.int == 0) {
            if ((self.repr.tag | source.repr.tag) != 0) return false;
        } else {
            if (((self.repr.tag ^ Tag.int) | (source.repr.tag ^ Tag.int)) != 0) return false;
        }
        self.repr.payload = source.repr.payload;
        return true;
    }

    pub inline fn asInt32Pair(lhs: JSValue, rhs: JSValue) ?Int32Pair {
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
        if (self.repr.tag == Tag.float64) return @bitCast(self.repr.payload);
        return null;
    }

    pub fn asNumber(self: JSValue) ?f64 {
        return numberValue(self);
    }

    /// QuickJS OP_if_{true,false} classifies the contiguous immediate tag
    /// range [int, undefined] with one unsigned comparison, then reads the
    /// payload as its truth value. Null and undefined have a zero payload;
    /// references and floats return null so the caller can use full ToBoolean.
    pub inline fn asBranchImmediateBool(self: JSValue) ?bool {
        const tag: u32 = @bitCast(self.tagOf());
        const last_immediate: u32 = @intCast(Tag.undefined_value);
        if (tag > last_immediate) return null;
        return self.payloadOf() != 0;
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
        // Fast path: an inline short BigInt always fits i64 by construction --
        // the payload word holds the value outright.
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

    /// The catch-handler bytecode offset a catch marker carries, or null when
    /// the marker is the "no handler" sentinel. Three dispatch files spelled
    /// this decode out; it belongs next to the encoding it decodes.
    pub fn catchTarget(self: JSValue) ?usize {
        const offset = self.asCatchOffset() orelse -1;
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

    /// qjs `JS_VALUE_GET_OBJ`: tag already proven, payload is the object.
    /// Release does not re-test a null pointer (F1); Debug still asserts.
    pub inline fn refHeaderAssumeObject(self: JSValue) *gc.Header {
        std.debug.assert(self.isObject());
        const payload = self.payloadOf();
        std.debug.assert(payload != 0);
        return @ptrFromInt(payload);
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

    /// `JS_MarkValue` filter (quickjs.c:6553-6566): OBJECT / FUNCTION_BYTECODE /
    /// MODULE only. Heap BigInt is refcounted but is not a cycle-list member;
    /// qjs drops it here with `cmn tag, #3` (tagged tags {-3,-2,-1}).
    pub inline fn cycleMarkHeader(self: JSValue) ?*gc.Header {
        const tag = self.repr.tag;
        if (tag > Tag.object or tag < Tag.module) return null;
        return ptrFromPayload(gc.Header, self.repr.payload);
    }

    pub inline fn dup(self: JSValue) JSValue {
        if (!self.requiresRefCount()) return self;
        gc.retain(self.refCountWordAssumeRefCounted());
        return self;
    }

    pub inline fn free(self: JSValue, rt: anytype) void {
        comptime {
            @setEvalBranchQuota(10_000);
        }
        if (!self.requiresRefCount()) return;
        const tag = self.tagOf();
        if (rt.gc.phase == .deinit and tag >= Tag.module and tag <= Tag.object) return;
        if (comptime value_free_profile) {
            if (rt.opcode_profile) |prof| prof.recordValueFree();
        }
        self.releaseCommonRefCount(rt);
    }

    /// QuickJS-shaped release for an owner held by an active bytecode frame.
    ///
    /// Runtime teardown hard-fails before entering `gc.deinit` while any
    /// bytecode call-depth owner is live (`JSRuntime.assertIdleForTeardown`).
    /// A VM handler may therefore prove the deinit exclusion once at bytecode
    /// entry instead of re-reading `gc.phase` for every `JS_FreeValue`-shaped
    /// release. Keep the proof explicit here: Debug/ReleaseSafe catch a caller
    /// outside that window, while ReleaseFast retains only QuickJS's tag-range
    /// check, refcount decrement, profile hook, and zero-ref tail. That tail
    /// keeps the phase gate in `gc.destroyZeroRef`, after the refcount reaches
    /// zero, matching QuickJS `__JS_FreeValueRT` (quickjs.c:6431,6476).
    ///
    /// Generic/runtime teardown code must continue to use `free`.
    pub inline fn freeDuringActiveBytecode(self: JSValue, rt: anytype) void {
        comptime {
            @setEvalBranchQuota(10_000);
        }
        std.debug.assert(rt.hot.call_depth != 0);
        std.debug.assert(rt.gc.phase != .deinit);
        if (!self.requiresRefCount()) return;
        if (comptime value_free_profile) {
            if (rt.opcode_profile) |prof| prof.recordValueFree();
        }
        self.releaseCommonRefCount(rt);
    }

    /// Release a value whose caller has already proved the semantic tag is
    /// `object`. This is the typed counterpart of QuickJS's direct Object
    /// owner release: it preserves deinit/profile/zero-ref behavior while
    /// avoiding the generic JSValue refcount-range and tag dispatch on the
    /// common non-zero arm.
    pub inline fn freeObjectAssumeObject(self: JSValue, rt: anytype) void {
        std.debug.assert(self.tagOf() == Tag.object);
        if (rt.gc.phase == .deinit) return;
        if (comptime value_free_profile) {
            if (rt.opcode_profile) |prof| prof.recordValueFree();
        }
        const hdr = self.refCountWordAssumeRefCounted();
        std.debug.assert(hdr.rc > 0);
        hdr.rc -= 1;
        if (hdr.rc == 0) {
            gc.destroyZeroRef(rt, ptrFromPayload(gc.Header, self.payloadOf()).?);
        }
    }

    /// Active-bytecode twin of `freeObjectAssumeObject`. Runtime teardown is
    /// excluded while a bytecode owner is live, so the common decrement pays
    /// no pre-release phase probe; a zero ref still reaches
    /// `gc.destroyZeroRef` and its QuickJS-shaped phase gate (quickjs.c:6476).
    pub inline fn freeObjectAssumeObjectDuringActiveBytecode(self: JSValue, rt: anytype) void {
        std.debug.assert(self.tagOf() == Tag.object);
        std.debug.assert(rt.hot.call_depth != 0);
        std.debug.assert(rt.gc.phase != .deinit);
        if (comptime value_free_profile) {
            if (rt.opcode_profile) |prof| prof.recordValueFree();
        }
        const hdr = self.refCountWordAssumeRefCounted();
        std.debug.assert(hdr.rc > 0);
        hdr.rc -= 1;
        if (hdr.rc == 0) {
            gc.destroyZeroRef(rt, ptrFromPayload(gc.Header, self.payloadOf()).?);
        }
    }

    /// Property-slot release from `Object.destroyPlainObjectFast`.
    ///
    /// The caller has already proved `gc.phase` is neither `.deinit` nor
    /// `.remove_cycles` (the fast-arm gate in `destroyFromHeader`). That
    /// matches `free_property` → `JS_FreeValueRT` (quickjs.c:6111 / 697-704):
    /// the decrement does not reload phase. An object last-ref goes straight
    /// to the zero-ref queue (`__JS_FreeValueRT` 6471-6483) instead of hopping
    /// through `JSValue.destroyZeroRef` + `gc.destroyZeroRef`.
    pub inline fn freeFromPlainObjectDestroy(self: JSValue, rt: anytype) void {
        if (!self.requiresRefCount()) return;
        const hdr = self.refCountWordAssumeRefCounted();
        std.debug.assert(hdr.rc > 0);
        hdr.rc -= 1;
        if (hdr.rc != 0) return;
        if (self.tagOf() == Tag.object) {
            @call(.never_inline, gc.Registry.enqueueZeroRef, .{
                &rt.gc, rt, self.refHeaderAssumeObject(),
            });
            return;
        }
        self.destroyZeroRef(rt);
    }

    /// Read a 16-byte JSValue slot as two 64-bit integer loads. Hot
    /// property/operand slots are written and read across handlers as 64-bit
    /// integer halves; letting LLVM lower either side as one 128-bit SIMD
    /// access breaks store-to-load forwarding against the integer half on the
    /// other side (double-digit cycles per hit). qjs's JSValue moves are
    /// integer ldp/stp pairs throughout (e.g. set_value, quickjs.c:5091;
    /// GET_FIELD_INLINE's val handling, quickjs.c:19131-19158).
    pub inline fn loadSlotAsIntPair(slot: *const JSValue) JSValue {
        const words: *const [2]u64 = @ptrCast(@alignCast(slot));
        const lo = words[0];
        const hi = words[1];
        return @bitCast([2]u64{ lo, hi });
    }

    /// Store twin of `loadSlotAsIntPair`: write a JSValue slot as two 64-bit
    /// integer stores so downstream 64-bit readers stay forwarding-eligible.
    pub inline fn storeSlotAsIntPair(slot: *JSValue, value: JSValue) void {
        const words: *[2]u64 = @ptrCast(@alignCast(slot));
        const src: [2]u64 = @bitCast(value);
        words[0] = src[0];
        words[1] = src[1];
    }

    /// Frameless-handler variant of `freeObjectAssumeObject`: performs the
    /// deinit-phase gate and the common non-zero refcount decrement inline, but
    /// REPORTS a would-be zero refcount (leaving rc at 1) instead of invoking
    /// the destroy machinery, so a leaf dispatch handler can route the rare
    /// destroy through a tail-call and stay prologue-free (the destroy `bl` was
    /// the only call in the hot get_field body, and it alone forced the
    /// callee-saved spill frame). When this returns true the caller must
    /// complete the release exactly once (e.g. `value.free(rt)`).
    pub inline fn releaseObjectAssumeObjectNeedsDestroy(self: JSValue, rt: anytype) bool {
        std.debug.assert(self.tagOf() == Tag.object);
        if (rt.gc.phase == .deinit) return false;
        const hdr = self.refCountWordAssumeRefCounted();
        std.debug.assert(hdr.rc > 0);
        if (hdr.rc == 1) return true;
        if (comptime value_free_profile) {
            if (rt.opcode_profile) |prof| prof.recordValueFree();
        }
        hdr.rc -= 1;
        return false;
    }

    /// Any-tag twin of `releaseObjectAssumeObjectNeedsDestroy` for the
    /// resident put_field handler's old-slot value (which can be any
    /// refcounted tag, not just object): performs the refcount-range gate,
    /// the deinit-phase skip, and the common non-zero decrement inline, but
    /// REPORTS a would-be zero refcount (leaving rc at 1) instead of invoking
    /// the destroy machinery, so the leaf handler can park the value and
    /// route the rare destroy through a cold tail without carrying a
    /// callee-saved spill frame. When this returns true the caller must
    /// complete the release exactly once (e.g. `value.free(rt)`).
    pub inline fn releaseRefCountedNeedsDestroy(self: JSValue, rt: anytype) bool {
        if (!self.requiresRefCount()) return false;
        const tag = self.tagOf();
        if (rt.gc.phase == .deinit and tag >= Tag.module and tag <= Tag.object) return false;
        const hdr = self.refCountWordAssumeRefCounted();
        std.debug.assert(hdr.rc > 0);
        if (hdr.rc == 1) return true;
        if (comptime value_free_profile) {
            if (rt.opcode_profile) |prof| prof.recordValueFree();
        }
        hdr.rc -= 1;
        return false;
    }

    /// Active-bytecode twin of `releaseObjectAssumeObjectNeedsDestroy`.
    /// The hot non-zero arm mirrors QuickJS `JS_FreeValue`: no GC-phase read;
    /// the caller routes the zero-ref leg to the phase-aware destroy tail
    /// (quickjs.c:6431,6476).
    pub inline fn releaseObjectAssumeObjectNeedsDestroyDuringActiveBytecode(self: JSValue, rt: anytype) bool {
        std.debug.assert(self.tagOf() == Tag.object);
        std.debug.assert(rt.hot.call_depth != 0);
        std.debug.assert(rt.gc.phase != .deinit);
        const hdr = self.refCountWordAssumeRefCounted();
        std.debug.assert(hdr.rc > 0);
        if (hdr.rc == 1) return true;
        if (comptime value_free_profile) {
            if (rt.opcode_profile) |prof| prof.recordValueFree();
        }
        hdr.rc -= 1;
        return false;
    }

    /// Any-tag active-bytecode twin of
    /// `releaseObjectAssumeObjectNeedsDestroyDuringActiveBytecode`.
    pub inline fn releaseRefCountedNeedsDestroyDuringActiveBytecode(self: JSValue, rt: anytype) bool {
        std.debug.assert(rt.hot.call_depth != 0);
        std.debug.assert(rt.gc.phase != .deinit);
        if (!self.requiresRefCount()) return false;
        const hdr = self.refCountWordAssumeRefCounted();
        std.debug.assert(hdr.rc > 0);
        if (hdr.rc == 1) return true;
        if (comptime value_free_profile) {
            if (rt.opcode_profile) |prof| prof.recordValueFree();
        }
        hdr.rc -= 1;
        return false;
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
        return .{ .negative = big.negative(), .limbs = big.limbs() };
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

    // Heap BigInt is refcounted but JS_MarkValue skips it (quickjs.c:6557-6564).
    try t.expect(JSValue.bigInt(&dummy).cycleMarkHeader() == null);
    try t.expect(JSValue.bigInt(&dummy).refCountHeader() != null);
}

test "asInt64 / asUint64 on inline short BigInt and non-BigInt" {
    const t = std.testing;

    // Non-BigInt values must extract as null on both.
    try t.expectEqual(@as(?i64, null), JSValue.int32(7).asInt64());
    try t.expectEqual(@as(?u64, null), JSValue.int32(7).asUint64());
    try t.expectEqual(@as(?i64, null), JSValue.float64(1.5).asInt64());
    try t.expectEqual(@as(?u64, null), JSValue.boolean(true).asUint64());

    // Inline short BigInt across its full representable range: the payload word
    // holds the value outright, so the bounds are the full i64 range.
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

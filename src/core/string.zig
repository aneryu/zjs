const atom_mod = @import("atom.zig");
const gc = @import("gc.zig");
const unicode = @import("../libs/unicode.zig");
const JSRuntime = @import("runtime.zig").JSRuntime;
const JSValue = @import("value.zig").JSValue;
const ValueTag = @import("value.zig").Tag;

pub const StringError = error{
    InvalidUtf8,
};

/// Maximum string length in code units, mirroring QuickJS `JS_STRING_LEN_MAX`
/// ((1 << 30) - 1, quickjs.c:212). Every creation/concat path enforces it
/// (`error.StringTooLong` -> InternalError "string too long", the qjs
/// JS_ThrowInternalError sites at quickjs.c:4078/4368/4655/4898); without it the
/// packed u31 `len_meta.len` field wraps at 2^31 and `.length` goes negative.
pub const max_length: usize = (1 << 30) - 1;

/// Deferred concatenation node (QuickJS `JSStringRope` analogue). A rope is a
/// STANDALONE refcounted heap object reached through a `JSValue` tagged
/// `Tag.string_rope` (never a `*String`). It owns its `left`/`right` children
/// as `JSValue`s (each may itself be a flat `Tag.string` or another
/// `Tag.string_rope`, so rope-of-rope chains are handled). Generic ropes keep
/// only the QJS-like tree state plus the runtime needed by the infallible
/// borrowed-string API. The zjs-only growable accumulator tail lives in an
/// optional sidecar, so ordinary QJS-style rope nodes do not pay for its
/// buffer union and bookkeeping.
///
/// The first content read MATERIALIZES the rope into a flat `*String`
/// (`flatten`, mirroring qjs `js_linearize_string_rope`) and caches it in
/// `left` with `depth == 0`, releasing the former children and the tail. This
/// mirrors qjs's linearized `left=flat, right=empty` representation without a
/// separate flat/hash payload. All borrowed slices returned to readers point
/// into that owned flat string, so they stay valid for as long as the rope
/// object is alive. The refcount lives in a 4-byte `gc.StringHeader`
/// prefix at `ropePtr - 4` (see `String` below), reached through `header()`, so
/// a `Tag.string_rope` value's payload is that prefix pointer, exactly like a
/// flat string.
pub const StringRope = struct {
    left: JSValue,
    right: JSValue,
    /// `asStringBody()` has no context/runtime argument, so zjs retains this
    /// one pointer for on-demand linearization. QJS receives `JSContext *` at
    /// its linearization call site and therefore does not need it in the node.
    rt: *JSRuntime,
    /// Total length in code units, including the tail sidecar's used units.
    /// QJS uses uint32_t and caps strings below 2^30; keep the same width.
    len: u32,
    /// Maximum child depth plus one, matching QuickJS `JSStringRope.depth`.
    /// Generic concatenation rebalances once this exceeds
    /// `String.rope_max_depth`, keeping reads and recursive destruction
    /// bounded. Zero is reserved for an already-linearized rope.
    depth: u8,
    wide: bool,
    /// The trailing tail-state slot exists only on the larger accumulator-node
    /// allocation. Ordinary QJS-style nodes keep this flag clear and end at
    /// `@sizeOf(StringRope)`.
    flags: u8 = 0,

    const accumulator_tail_slot_flag: u8 = 1 << 0;

    /// Size of the refcount prefix reserved ahead of a `StringRope` node. The
    /// node holds pointers (`@alignOf(StringRope) == 8`), so the 4-byte rc word
    /// is padded up to the node's alignment to keep the struct that follows it
    /// aligned. The rc word lives in the LAST 4 bytes of the prefix, i.e. at
    /// `nodePtr - 4`, so `header()` returns the same `nodePtr - 4` a flat string
    /// would (the JSValue payload is that rc pointer for both tags).
    pub const rc_prefix_size: usize = std.mem.alignForward(usize, gc.string_rc_prefix_size, @alignOf(StringRope));

    /// Pointer to the 4-byte refcount word sitting immediately before this rope
    /// node (`ropePtr - 4`), mirroring `String.header()`. The rc word is the
    /// shared identity a `Tag.string_rope` JSValue carries in its payload.
    pub inline fn header(self: *const StringRope) *gc.StringHeader {
        const base: [*]u8 = @ptrCast(@constCast(self));
        return @ptrCast(@alignCast(base - gc.string_rc_prefix_size));
    }

    /// Recover a rope node from its refcount-word pointer (inverse of
    /// `header()`). The rc word sits `string_rc_prefix_size` (4) bytes before
    /// the node, exactly like a flat string.
    pub inline fn fromHeader(hdr: *gc.StringHeader) *StringRope {
        const base: [*]u8 = @ptrCast(hdr);
        return @ptrCast(@alignCast(base + gc.string_rc_prefix_size));
    }

    /// A `Tag.string_rope` JSValue pointing at this node.
    pub fn value(self: *StringRope) JSValue {
        return JSValue.stringRope(self.header());
    }

    pub inline fn retain(self: *StringRope) void {
        self.header().retain();
    }

    pub fn isWide(self: *const StringRope) bool {
        return self.wide;
    }

    pub fn len_(self: *const StringRope) usize {
        return @intCast(self.len);
    }

    /// QJS recognizes a linearized rope by an empty-string right child. zjs
    /// reserves depth zero for the same state, avoiding another field and an
    /// empty-string retain in every materialized rope.
    pub fn isLinearized(self: *const StringRope) bool {
        return self.depth == 0;
    }

    pub fn supportsTail(self: *const StringRope) bool {
        return self.flags & accumulator_tail_slot_flag != 0;
    }

    fn tailStateSlot(self: *const StringRope) ?*?*RopeTailState {
        if (!self.supportsTail()) return null;
        const tail_address = @intFromPtr(self) + @sizeOf(StringRope);
        return @ptrFromInt(tail_address);
    }

    pub fn hasTail(self: *const StringRope) bool {
        const slot = self.tailStateSlot() orelse return false;
        return slot.* != null;
    }

    pub fn tailLen(self: *const StringRope) usize {
        const slot = self.tailStateSlot() orelse return 0;
        return if (slot.*) |tail| tail.len else 0;
    }

    fn flatString(self: *const StringRope) ?*String {
        if (!self.isLinearized()) return null;
        return self.left.asStringBodyRaw();
    }

    fn tailResolved(self: *const StringRope) ?String.ResolvedData {
        const slot = self.tailStateSlot() orelse return null;
        const tail = slot.* orelse return null;
        return switch (tail.data) {
            .latin1 => |buf| .{ .latin1 = buf[0..tail.len] },
            .utf16 => |buf| .{ .utf16 = buf[0..tail.len] },
        };
    }

    /// Materializes this rope into a flat `*String`, caching its owned value in
    /// `left` and releasing the former children and tail. Returns a BORROWED
    /// pointer to the cached flat string (the rope keeps ownership; callers
    /// that need to own it must retain). Idempotent. On allocation failure the
    /// rope is left untouched.
    pub fn flatten(self: *StringRope) !*String {
        if (self.flatString()) |flat| return flat;
        const rt = self.rt;
        const total_len: usize = @intCast(self.len);
        const flat = if (self.wide) blk: {
            const s = try String.createUninitialized(rt, .utf16, total_len);
            errdefer String.destroyFlat(rt, s);
            copyRopeContent(u16, self, s.utf16Mut());
            break :blk s;
        } else blk: {
            const s = try String.createUninitialized(rt, .latin1, total_len);
            errdefer String.destroyFlat(rt, s);
            copyRopeContent(u8, self, s.latin1Mut());
            writeLatin1Terminator(s.latin1Mut());
            break :blk s;
        };
        const old_left = self.left;
        const old_right = self.right;
        self.left = flat.value();
        self.right = JSValue.undefinedValue();
        freeRopeTail(rt, self);
        self.depth = 0;
        // Release the former tree only after publishing the new owned flat
        // child. String destruction has no user callback, but this ordering
        // also keeps the rope internally valid under force-GC diagnostics.
        old_left.free(rt);
        old_right.free(rt);
        return flat;
    }

    /// Infallible flatten used by borrowed-slice readers that cannot propagate
    /// errors (`resolveData`). On OOM it runs object-cycle removal to reclaim
    /// memory and retries once; a second failure is fatal.
    pub fn flattenInfallible(self: *StringRope) *String {
        return self.flatten() catch {
            _ = self.rt.runObjectCycleRemoval();
            return self.flatten() catch @panic("zjs: out of memory while flattening string rope");
        };
    }

    /// Content hash without materialization. Flat children keep their normal
    /// cache; the rope itself has no duplicate hash field, matching QJS.
    pub fn contentHash(self: *StringRope) u32 {
        return stringValueContentHash(self.value()).?;
    }
};

/// Sidecar used only by zjs's fused `add_loc` accumulator extension. Keeping
/// it out of `StringRope` makes the ordinary concat/rebalance node compact like
/// QJS while retaining the measured O(1) tail-append win for exclusive locals.
const RopeTailState = struct {
    data: Data,
    len: usize,

    const Data = union(enum) {
        latin1: []u8,
        utf16: []u16,
    };
};

pub fn isAsciiBytes(bytes: []const u8) bool {
    for (bytes) |byte| {
        if (byte >= 0x80) return false;
    }
    return true;
}

/// Faithful storage model aligned with QuickJS `JSString`. A flat string keeps
/// its characters INLINE, laid out immediately after the struct (a flexible
/// array member reached via the `latin1()`/`utf16()`/`bytes()` accessors, like
/// qjs `u.str8[]`/`u.str16[]`). There is no `Data` union and no separate heap
/// buffer for the characters. A rope-backed value keeps `is_rope = true` and
/// points at a `StringRope` through `rope`; its inline payload is empty and its
/// content materializes lazily on first read.
pub const String = struct {
    pub const no_atom_id: u32 = std.math.maxInt(u32);

    /// Length + width word, mirroring QuickJS `JSString`'s first u32 bitfield
    /// `{ len:31, is_wide_char:1 }`. `len` is the inline payload length in code
    /// units. Ropes are a separate `StringRope` object, so this struct is always
    /// a flat string now (no rope discriminant lives here).
    pub const LenMeta = packed struct(u32) {
        len: u31 = 0,
        is_wide: bool = false,
    };

    /// Content-hash word, mirroring QuickJS `JSString`'s second u32 bitfield
    /// `{ hash:30, atom_type:2 }`. Following qjs, `hash == 0` is the "not yet
    /// computed" sentinel: a real hash that lands on 0 is stored as 1. The
    /// `atom_type` bits are unused for now (atom membership is tracked through
    /// `atom_id`); they are reserved to fold that in later.
    pub const HashMeta = packed struct(u32) {
        hash: u30 = 0,
        atom_type: u2 = 0,
    };

    /// Combined `{ len, is_wide }` word (qjs first bitfield).
    len_meta: LenMeta = .{},
    /// Combined `{ hash, atom_type }` word (qjs second bitfield). `hash == 0`
    /// means "not computed yet".
    hash_meta: HashMeta = .{},
    atom_id: u32 = no_atom_id,

    /// Pointer to the 4-byte refcount prefix sitting immediately before this
    /// struct (`stringPtr - 4`, qjs `JSRefCountHeader` analogue). The rc word is
    /// allocated as a leading prefix so the flat `String` struct is exactly 12B
    /// (mirroring qjs `JSString`: two u32 bitfields + `atom_type`), with the rc
    /// kept out of band. Both `String` and `StringRope` share this prefix model,
    /// so a `Tag.string`/`Tag.string_rope`/`Tag.symbol` JSValue's payload is the
    /// prefix pointer and reaches the rc uniformly through `header()`.
    pub inline fn header(self: *const String) *gc.StringHeader {
        const base: [*]u8 = @ptrCast(@constCast(self));
        return @ptrCast(@alignCast(base - gc.string_rc_prefix_size));
    }

    /// Recover a `*String` from its refcount prefix pointer (inverse of
    /// `header()`; replaces the old `@fieldParentPtr("header", …)`).
    pub inline fn fromHeader(hdr: *gc.StringHeader) *String {
        const base: [*]u8 = @ptrCast(hdr);
        return @ptrCast(@alignCast(base + gc.string_rc_prefix_size));
    }

    /// Returns an owned runtime string. The runtime releases it through
    /// reference counting when all `JSValue` handles are freed.
    pub fn createAscii(rt: *JSRuntime, bytes: []const u8) !*String {
        return createLatin1(rt, bytes);
    }

    /// Returns an owned runtime string decoded from UTF-8 into QuickJS-style
    /// 8-bit or 16-bit code-unit storage.
    pub fn createUtf8(rt: *JSRuntime, bytes: []const u8) !*String {
        const plan = try scanUtf8(bytes);
        if (!plan.wide) {
            const self = try createUninitialized(rt, .latin1, plan.units);
            errdefer destroyFlat(rt, self);
            _ = try decodeUtf8(bytes, self.latin1Mut(), null);
            writeLatin1Terminator(self.latin1Mut());
            return self;
        }

        const self = try createUninitialized(rt, .utf16, plan.units);
        errdefer destroyFlat(rt, self);
        _ = try decodeUtf8(bytes, null, self.utf16Mut());
        return self;
    }

    /// Returns an owned runtime string. Caller transfers the returned value to
    /// `JSValue.free` or another owner.
    pub fn createUtf16(rt: *JSRuntime, units: []const u16) !*String {
        var needs_wide = false;
        for (units) |unit| {
            if (unit > 0xff) {
                needs_wide = true;
                break;
            }
        }

        if (!needs_wide) {
            const self = try createUninitialized(rt, .latin1, units.len);
            errdefer destroyFlat(rt, self);
            const out = self.latin1Mut();
            for (units, 0..) |unit, i| out[i] = @intCast(unit);
            writeLatin1Terminator(out);
            return self;
        }

        const self = try createUninitialized(rt, .utf16, units.len);
        errdefer destroyFlat(rt, self);
        @memcpy(self.utf16Mut(), units);
        return self;
    }

    /// Copies `units` into a fresh inline string; the caller retains ownership
    /// of `units` (it is NOT adopted). QuickJS `JSString` characters are always
    /// inline, so there is no owned-buffer fast path anymore.
    pub fn createUtf16Owned(rt: *JSRuntime, units: []const u16, capacity: usize) !*String {
        _ = capacity;
        return createUtf16(rt, units);
    }

    pub fn createUtf16Pair(rt: *JSRuntime, first: u16, second: u16) !*String {
        if (first <= 0xff and second <= 0xff) {
            const self = try createUninitialized(rt, .latin1, 2);
            errdefer destroyFlat(rt, self);
            const out = self.latin1Mut();
            out[0] = @intCast(first);
            out[1] = @intCast(second);
            writeLatin1Terminator(out);
            return self;
        }

        const self = try createUninitialized(rt, .utf16, 2);
        errdefer destroyFlat(rt, self);
        const out = self.utf16Mut();
        out[0] = first;
        out[1] = second;
        return self;
    }

    pub fn createSymbolNoDescription(rt: *JSRuntime) !*String {
        return createUninitialized(rt, .utf16, 0);
    }

    pub fn isSymbolNoDescription(self: *const String) bool {
        return self.len() == 0 and self.isWide();
    }

    pub fn createAtomBacked(rt: *JSRuntime, atom_id: u32) !*String {
        // Atom-table cache hit: hand out one more reference to the string
        // already materialized for this atom, skipping the UTF-8 decode.
        if (rt.atoms.cachedString(atom_id)) |cached| {
            gc.retain(cached.header());
            return cached;
        }
        const name = rt.atoms.name(atom_id) orelse return error.InvalidAtom;
        const self = try createUtf8(rt, name);
        // `cacheString` only binds string-kind atoms: a symbol's
        // description string must not convert back into the symbol atom
        // when later used as a property key.
        rt.atoms.cacheString(atom_id, self);
        return self;
    }

    /// Interns this string's content as a property-key atom and returns an
    /// owned atom reference (caller releases it via `rt.atoms.free`).
    ///
    /// The atom name uses the same UTF-8/WTF-8 encoding the lexer and the
    /// JSON parser produce, so keys built from runtime strings unify with
    /// keys interned from source text. The string is then bound into the
    /// atom table's per-atom string cache (`AtomTable.cacheString`): the
    /// table holds a string reference and `atom_id` becomes a weak
    /// back-pointer, making repeated conversions of the same string a
    /// ref-count bump; the reverse direction (`AtomTable.toStringValue`)
    /// reuses the same cached string with zero conversion.
    /// Rope-backed strings are flattened by the content read.
    pub fn internAtom(self: *String, rt: *JSRuntime) !u32 {
        if (self.atom_id != no_atom_id) return rt.atoms.dup(self.atom_id);
        _ = self.contentHash();
        var utf8 = std.ArrayList(u8).empty;
        defer utf8.deinit(rt.memory.allocator);
        const atom_id = switch (self.resolveData()) {
            .latin1 => |bytes| blk: {
                if (isAsciiBytes(bytes)) break :blk try rt.atoms.internString(bytes);
                for (bytes) |byte| try unicode.appendUtf8CodePoint(rt.memory.allocator, &utf8, byte);
                break :blk try rt.atoms.internString(utf8.items);
            },
            .utf16 => |units| blk: {
                try unicode.appendUtf16UnitsAsUtf8(rt.memory.allocator, &utf8, units);
                break :blk try rt.atoms.internString(utf8.items);
            },
        };
        rt.atoms.cacheString(atom_id, self);
        return atom_id;
    }

    /// Concatenate two latin1 string buffers into a single freshly allocated
    /// latin1 string. The runtime owns the result.
    ///
    /// Used by the `+` operator string fast path so we skip the per-call
    /// `ArrayList(u8)` intermediate (and its `deinit`).
    pub fn createLatin1Concat(rt: *JSRuntime, a: []const u8, b: []const u8) !*String {
        const total = a.len + b.len;
        const self = try createUninitialized(rt, .latin1, total);
        errdefer destroyFlat(rt, self);
        const out = self.latin1Mut();
        @memcpy(out[0..a.len], a);
        @memcpy(out[a.len..], b);
        writeLatin1Terminator(out);
        return self;
    }

    /// Concatenate already-measured latin1 pieces into one freshly allocated
    /// latin1 string. Mirrors qjs `JS_ConcatString1` (quickjs.c:4646): one
    /// `js_alloc_string`, then each source memcpy lands in the result payload.
    pub fn createLatin1Parts(rt: *JSRuntime, parts: []const []const u8, total: usize) !*String {
        const self = try createUninitialized(rt, .latin1, total);
        errdefer destroyFlat(rt, self);
        const out = self.latin1Mut();
        var offset: usize = 0;
        for (parts) |part| {
            std.debug.assert(offset + part.len <= total);
            @memcpy(out[offset..][0..part.len], part);
            offset += part.len;
        }
        std.debug.assert(offset == total);
        writeLatin1Terminator(out);
        return self;
    }

    pub fn createLatin1ConcatWithSeed(rt: *JSRuntime, a: []const u8, b: []const u8, seed: u32) !*String {
        _ = seed;
        return createLatin1Concat(rt, a, b);
    }

    pub fn createLatin1RepeatedConcatWithSeed(rt: *JSRuntime, a: []const u8, suffix: []const u8, repeat_count: usize, seed: u32) !*String {
        _ = seed;
        const append_len = try std.math.mul(usize, suffix.len, repeat_count);
        const total = try std.math.add(usize, a.len, append_len);
        const self = try createUninitialized(rt, .latin1, total);
        errdefer destroyFlat(rt, self);
        const out = self.latin1Mut();
        @memcpy(out[0..a.len], a);
        if (suffix.len == 1) {
            @memset(out[a.len..total], suffix[0]);
        } else {
            var offset = a.len;
            var remaining = repeat_count;
            while (remaining != 0) : (remaining -= 1) {
                @memcpy(out[offset..][0..suffix.len], suffix);
                offset += suffix.len;
            }
        }
        writeLatin1Terminator(out);
        return self;
    }

    /// Concatenate two utf16 unit buffers into a single freshly allocated
    /// utf16 string. The runtime owns the result.
    pub fn createUtf16Concat(rt: *JSRuntime, a: []const u16, b: []const u16) !*String {
        const total = a.len + b.len;
        const self = try createUninitialized(rt, .utf16, total);
        errdefer destroyFlat(rt, self);
        const out = self.utf16Mut();
        @memcpy(out[0..a.len], a);
        @memcpy(out[a.len..], b);
        return self;
    }

    pub fn createUtf16ConcatWithSeed(rt: *JSRuntime, a: []const u16, b: []const u16, seed: u32) !*String {
        _ = seed;
        return createUtf16Concat(rt, a, b);
    }

    pub fn createLatin1(rt: *JSRuntime, bytes: []const u8) !*String {
        const self = try createUninitialized(rt, .latin1, bytes.len);
        errdefer destroyFlat(rt, self);
        @memcpy(self.latin1Mut(), bytes);
        writeLatin1Terminator(self.latin1Mut());
        return self;
    }

    /// If `bytes` is ASCII, allocate the final narrow string and case-map the
    /// source directly into its inline payload. A non-ASCII source returns null
    /// without allocating so the caller can use the full Unicode converter.
    pub fn createAsciiCaseMapped(rt: *JSRuntime, bytes: []const u8, to_lower: bool) !?*String {
        for (bytes) |byte| {
            if (byte >= 0x80) return null;
        }
        const self = try createUninitialized(rt, .latin1, bytes.len);
        errdefer destroyFlat(rt, self);
        const out = self.latin1Mut();
        for (bytes, 0..) |byte, index| {
            out[index] = if (to_lower) unicode.toLowerAscii(byte) else unicode.toUpperAscii(byte);
        }
        writeLatin1Terminator(out);
        return self;
    }

    /// QuickJS `JS_STRING_ROPE_SHORT_LEN`: a short RHS is merged into a rope's
    /// short right leaf before another wrapper node is introduced.
    pub const rope_short_len: usize = 512;
    /// QuickJS `JS_STRING_ROPE_SHORT2_LEN`: two flat strings stay flat while
    /// the LHS is at most this long and the RHS is short.
    pub const rope_short2_len: usize = 8192;
    /// QuickJS `JS_STRING_ROPE_MAX_DEPTH`: deeper trees are rebuilt with the
    /// Fibonacci-bucket rope balancing algorithm.
    pub const rope_max_depth: u8 = 60;

    /// Creates a rope deferring the concatenation of `left ++ right`. Returns a
    /// STANDALONE `*StringRope` (the caller emits its `Tag.string_rope` value via
    /// `node.value()`). Retains both children; content materializes lazily on
    /// first read. `left`/`right` are borrowed `*String`/`*StringRope` handles
    /// supplied as-is by the concat machinery; the rope stores them as owned
    /// `JSValue`s.
    pub fn createRope(rt: *JSRuntime, left: JSValue, right: JSValue) !*StringRope {
        // QJS classifies each operand once, collecting len/width/depth from
        // the same branch before allocating. Do not repeat ropeBody/raw-body
        // tag decoding independently for all three fields.
        const left_info = stringValueInfo(left);
        const right_info = stringValueInfo(right);
        const node = try createRopeNode(rt, left, right, left_info, right_info, false);
        left_info.header.retain();
        right_info.header.retain();
        return node;
    }

    /// Creates the zjs-only fused-local accumulator rope. Its base node keeps
    /// the same compact QJS layout; only this allocation receives one trailing
    /// nullable tail-state slot.
    pub fn createAccumulatorRope(rt: *JSRuntime, left: JSValue, right: JSValue) !*StringRope {
        const left_info = stringValueInfo(left);
        const right_info = stringValueInfo(right);
        const node = try createRopeNode(rt, left, right, left_info, right_info, true);
        left_info.header.retain();
        right_info.header.retain();
        return node;
    }

    /// Consuming counterpart of `createRope`, matching QJS
    /// `js_new_string_rope(ctx, op1, op2)`: both input owners transfer directly
    /// into the new node, with no retain-then-free round trip. On failure both
    /// inputs are released.
    pub fn createRopeOwned(rt: *JSRuntime, left: JSValue, right: JSValue) !*StringRope {
        const left_info = stringValueInfo(left);
        const right_info = stringValueInfo(right);
        return createRopeNode(rt, left, right, left_info, right_info, false) catch |err| {
            left.free(rt);
            right.free(rt);
            return err;
        };
    }

    /// Creates a rope and applies the same depth cap and Fibonacci-bucket
    /// rebalance as QuickJS `js_new_string_rope`. The inputs are borrowed; the
    /// returned value owns its complete tree.
    pub fn createBalancedRope(rt: *JSRuntime, left: JSValue, right: JSValue) !JSValue {
        const node = try createRope(rt, left, right);
        const rope_value = node.value();
        if (node.depth <= rope_max_depth) return rope_value;

        const balanced = rebalanceRope(rt, rope_value) catch |err| {
            rope_value.free(rt);
            return err;
        };
        rope_value.free(rt);
        return balanced;
    }

    /// Consumes two owned operands and applies the same depth cap/rebalance as
    /// `createBalancedRope`. This is the ownership contract of QJS's concat
    /// helper and is the hot path used by direct `OP_add`.
    pub fn createBalancedRopeOwned(rt: *JSRuntime, left: JSValue, right: JSValue) !JSValue {
        const node = try createRopeOwned(rt, left, right);
        const rope_value = node.value();
        if (node.depth <= rope_max_depth) return rope_value;

        const balanced = rebalanceRope(rt, rope_value) catch |err| {
            rope_value.free(rt);
            return err;
        };
        rope_value.free(rt);
        return balanced;
    }

    /// Content hash accessor (qjs `JSString.hash`). Computes on first demand;
    /// the raw stored value uses `0` as the "not computed" sentinel.
    pub fn contentHash(self: *const String) u32 {
        // Follow qjs `js_string_compute_hash`: a stored hash of 0 means "not
        // computed yet"; a freshly computed 0 is bumped to 1 so it never
        // collides with the sentinel.
        if (self.hash_meta.hash == 0) {
            const mutable = @constCast(self);
            mutable.hash_meta.hash = foldHash30(switch (self.resolveData()) {
                .latin1 => |bytes| hashLatin1(bytes, 0),
                .utf16 => |units| hashUtf16(units, 0),
            });
        }
        return self.hash_meta.hash;
    }

    pub fn value(self: *String) JSValue {
        return JSValue.string(self.header());
    }

    pub inline fn retain(self: *String) void {
        self.header().retain();
    }

    pub fn releaseFromHeader(rt: *JSRuntime, hdr: *gc.StringHeader) void {
        std.debug.assert(hdr.rc > 0);
        hdr.rc -= 1;
        if (hdr.rc == 0) destroyFromHeader(rt, hdr);
    }

    pub fn len(self: *const String) usize {
        return self.len_meta.len;
    }

    pub fn isWide(self: *const String) bool {
        return self.len_meta.is_wide;
    }

    /// Cached content hash accessor (qjs `JSString.hash`). Computes on first
    /// demand through `contentHash`; the raw stored value uses `0` as the
    /// "not computed" sentinel.
    pub fn hash(self: *const String) u32 {
        return self.contentHash();
    }

    /// Inline character pointer, computed from the byte immediately after the
    /// struct (QuickJS `u.str8`/`u.str16`). Only valid for a flat string.
    inline fn inlineBytesPtr(self: *const String) [*]const u8 {
        const base: [*]const u8 = @ptrCast(self);
        return base + payload_offset;
    }
    inline fn inlineBytesPtrMut(self: *String) [*]u8 {
        const base: [*]u8 = @ptrCast(self);
        return base + payload_offset;
    }

    pub fn latin1(self: *const String) []const u8 {
        std.debug.assert(!self.len_meta.is_wide);
        return self.inlineBytesPtr()[0..self.len_meta.len];
    }
    pub fn utf16(self: *const String) []const u16 {
        std.debug.assert(self.len_meta.is_wide);
        const units: [*]const u16 = @ptrCast(@alignCast(self.inlineBytesPtr()));
        return units[0..self.len_meta.len];
    }
    fn latin1Mut(self: *String) []u8 {
        return self.inlineBytesPtrMut()[0..self.len_meta.len];
    }
    fn utf16Mut(self: *String) []u16 {
        const units: [*]u16 = @ptrCast(@alignCast(self.inlineBytesPtrMut()));
        return units[0..self.len_meta.len];
    }

    pub fn eqlBytes(self: *const String, bytes: []const u8) bool {
        return switch (self.resolveData()) {
            .latin1 => |lat| std.mem.eql(u8, lat, bytes),
            .utf16 => |u16s| eqlUtf16Latin1(u16s, bytes),
        };
    }

    pub fn eqlString(self: *const String, other: *const String) bool {
        return compare(self, other) == 0;
    }

    pub fn compare(self: *const String, other: *const String) i32 {
        if (self.atom_id != no_atom_id and other.atom_id != no_atom_id) {
            if (self.atom_id == other.atom_id) return 0;
        }
        return compareResolved(self.resolveData(), other.resolveData());
    }

    pub const ResolvedData = union(enum) {
        latin1: []const u8,
        utf16: []const u16,

        pub fn len(self: ResolvedData) usize {
            return switch (self) {
                .latin1 => |bytes| bytes.len,
                .utf16 => |units| units.len,
            };
        }
    };

    /// No-op on a flat string: ropes are a separate object flattened at the
    /// value boundary (`asStringBody`), so a `*String` reaching here is always
    /// flat. Kept for source compatibility with the fallible read paths.
    pub fn ensureFlat(self: *String, rt: *JSRuntime) !void {
        _ = self;
        _ = rt;
    }

    pub fn resolveData(self: *const String) ResolvedData {
        if (self.len_meta.is_wide) return .{ .utf16 = self.utf16() };
        return .{ .latin1 = self.latin1() };
    }

    pub fn borrowLatin1(self: *const String) ?[]const u8 {
        if (self.len_meta.is_wide) return null;
        return self.latin1();
    }

    pub fn codeUnitAt(self: *const String, index: usize) u16 {
        const resolved = self.resolveData();
        return switch (resolved) {
            .latin1 => |bytes| bytes[index],
            .utf16 => |units| units[index],
        };
    }

    /// Eager substring copy (QuickJS `js_sub_string`): produces a fresh
    /// exact-size flat string holding `parent[start..start+slice_len]`. There
    /// is no zero-copy view anymore, so the parent is never retained by the
    /// result.
    pub fn createSlice(rt: *JSRuntime, parent: *String, start: usize, slice_len: usize) !*String {
        if (slice_len == 0) return try createAscii(rt, "");
        return switch (parent.resolveData()) {
            .latin1 => |bytes| createLatin1(rt, bytes[start .. start + slice_len]),
            .utf16 => |units| createUtf16(rt, units[start .. start + slice_len]),
        };
    }

    pub fn destroyFromHeader(rt: *JSRuntime, hdr: *gc.StringHeader) void {
        const self: *String = String.fromHeader(hdr);
        // `atom_id` is a weak back-pointer: it holds no atom reference.
        // A string bound to a live dynamic atom cannot be destroyed (the
        // atom table holds a reference), so reaching here with a dynamic
        // id would mean the table failed to clear the back-pointer.
        if (self.atom_id != no_atom_id) {
            const atom_id = self.atom_id;
            if (!atom_mod.isConst(atom_id) and !atom_mod.isTaggedInt(atom_id)) {
                if (rt.atoms.onSymbolBodyZeroRef(rt, atom_id, self)) return;
            } else {
                std.debug.assert(atom_mod.isConst(atom_id) or atom_mod.isTaggedInt(atom_id));
            }
        }
        destroyFlat(rt, self);
    }

    pub fn destroyWeakSymbolBody(rt: *JSRuntime, self: *String) void {
        std.debug.assert(self.header().rc == 0);
        self.atom_id = no_atom_id;
        destroyFlat(rt, self);
    }

    const StorageTag = enum { latin1, utf16 };

    fn createUninitialized(rt: *JSRuntime, comptime tag: StorageTag, unit_count: usize) !*String {
        // Central allocation cap (qjs js_alloc_string / string_buffer_realloc,
        // quickjs.c:4078): every flat creator funnels through here, so this one
        // compare bounds all string construction.
        if (unit_count > max_length) return error.StringTooLong;
        const inline_layout = inlineAllocationLayout(tag, unit_count) orelse return error.OutOfMemory;
        // Reserve a 4-byte refcount prefix ahead of the struct so `String`
        // itself stays exactly 12B (qjs `JSString`). The block base is
        // 4-aligned; the rc prefix is 4 bytes, so the struct at `base + 4` keeps
        // `String`'s 4-byte alignment and the inline char FAM stays u16-aligned.
        const bytes = try rt.allocStringAlignedBytes(inline_layout.total_size, inline_layout.allocation_alignment);
        const rc_ptr: *gc.StringHeader = @ptrCast(@alignCast(bytes.ptr));
        rc_ptr.* = .{};
        const self: *String = @ptrCast(@alignCast(bytes.ptr + gc.string_rc_prefix_size));
        self.* = .{
            .len_meta = .{ .len = @intCast(unit_count), .is_wide = (tag == .utf16) },
            .hash_meta = .{},
            .atom_id = no_atom_id,
        };
        return self;
    }

    fn destroyFlat(rt: *JSRuntime, self: *String) void {
        const tag: StorageTag = if (self.len_meta.is_wide) .utf16 else .latin1;
        const inline_layout = switch (tag) {
            .latin1 => inlineAllocationLayout(.latin1, self.len_meta.len) orelse unreachable,
            .utf16 => inlineAllocationLayout(.utf16, self.len_meta.len) orelse unreachable,
        };
        // Free from the refcount prefix base (`stringPtr - 4`), the true
        // allocation start whose size includes the prefix.
        const base: [*]u8 = @ptrCast(self.header());
        rt.memory.freeAlignedBytes(base[0..inline_layout.total_size], inline_layout.allocation_alignment);
    }
};

/// Byte offset from a flat `String` header to its inline character payload.
/// latin1 (u8) and utf16 (u16) share the same offset because `String`'s
/// alignment already covers u16.
const payload_offset: usize = std.mem.alignForward(usize, @sizeOf(String), @alignOf(u16));

comptime {
    // The u16 payload must be reachable at a u16-aligned address so `utf16()`
    // can `@alignCast` safely.
    std.debug.assert(payload_offset % @alignOf(u16) == 0);
    // The flat `String` refcount prefix is exactly `@alignOf(String)` bytes, so
    // the struct at `base + prefix` keeps `String`'s alignment (and thus the
    // u16 FAM stays aligned). Guard the invariant the layout math relies on.
    std.debug.assert(gc.string_rc_prefix_size % @alignOf(String) == 0);
    std.debug.assert(@sizeOf(String) == 12);
}

fn compareResolved(a: String.ResolvedData, b: String.ResolvedData) i32 {
    return switch (a) {
        .latin1 => |a_bytes| switch (b) {
            .latin1 => |b_bytes| compareSameWidth(u8, a_bytes, b_bytes),
            .utf16 => |b_units| compareLatin1Utf16(a_bytes, b_units),
        },
        .utf16 => |a_units| switch (b) {
            .latin1 => |b_bytes| compareUtf16Latin1(a_units, b_bytes),
            .utf16 => |b_units| compareSameWidth(u16, a_units, b_units),
        },
    };
}

fn compareSameWidth(comptime T: type, a: []const T, b: []const T) i32 {
    if (a.len == b.len and std.mem.eql(u8, std.mem.sliceAsBytes(a), std.mem.sliceAsBytes(b))) return 0;
    return orderToI32(std.mem.order(T, a, b));
}

fn compareLatin1Utf16(a: []const u8, b: []const u16) i32 {
    const shared_len = @min(a.len, b.len);
    var i: usize = 0;
    while (i < shared_len) : (i += 1) {
        const a_unit: u16 = a[i];
        const b_unit = b[i];
        if (a_unit < b_unit) return -1;
        if (a_unit > b_unit) return 1;
    }
    return compareLength(a.len, b.len);
}

fn compareUtf16Latin1(a: []const u16, b: []const u8) i32 {
    const shared_len = @min(a.len, b.len);
    var i: usize = 0;
    while (i < shared_len) : (i += 1) {
        const a_unit = a[i];
        const b_unit: u16 = b[i];
        if (a_unit < b_unit) return -1;
        if (a_unit > b_unit) return 1;
    }
    return compareLength(a.len, b.len);
}

fn compareLength(a_len: usize, b_len: usize) i32 {
    if (a_len < b_len) return -1;
    if (a_len > b_len) return 1;
    return 0;
}

fn orderToI32(order: std.math.Order) i32 {
    return switch (order) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    };
}

/// True length in code units of a string-or-rope value.
pub fn stringValueLen(value: JSValue) usize {
    if (!value.isString()) return 0;
    return stringValueLenUnchecked(value);
}

/// QJS `string_rope_get_len` precondition: `value` is a string or rope.
pub inline fn stringValueLenUnchecked(value: JSValue) usize {
    const tag = value.tagOf();
    const header = value.stringHeaderAssumeStringLike();
    if (tag == ValueTag.string_rope) return StringRope.fromHeader(header).len_();
    std.debug.assert(tag == ValueTag.string);
    return String.fromHeader(header).len();
}

/// Fixed-stack, allocation-free traversal of a string-or-rope value. This is
/// the zjs analogue of QJS `JSStringRopeIter`: flat leaf slices are returned in
/// code-unit order without materializing the rope. The extra `tail` phase
/// accounts for zjs's optional accumulator sidecar (`left ++ right ++ tail`).
pub const StringValueIterator = struct {
    current: ?JSValue,
    nodes: [rope_iterator_stack_capacity]*const StringRope = undefined,
    phases: [rope_iterator_stack_capacity]Phase = undefined,
    stack_len: usize = 0,

    const Phase = enum(u1) { right, tail };

    pub fn init(value: JSValue) StringValueIterator {
        std.debug.assert(value.isString());
        return .{ .current = value };
    }

    pub fn next(self: *StringValueIterator) ?String.ResolvedData {
        while (true) {
            if (self.current) |value| {
                self.current = null;
                if (value.asStringBodyRaw()) |flat| {
                    const resolved = flat.resolveData();
                    if (resolved.len() != 0) return resolved;
                    continue;
                }

                const node = value.ropeBody() orelse return null;
                if (node.flatString()) |flat| {
                    const resolved = flat.resolveData();
                    if (resolved.len() != 0) return resolved;
                    continue;
                }

                std.debug.assert(self.stack_len < self.nodes.len);
                self.nodes[self.stack_len] = node;
                self.phases[self.stack_len] = .right;
                self.stack_len += 1;
                self.current = node.left;
                continue;
            }

            if (self.stack_len == 0) return null;
            const top = self.stack_len - 1;
            const node = self.nodes[top];
            switch (self.phases[top]) {
                .right => {
                    self.phases[top] = .tail;
                    self.current = node.right;
                },
                .tail => {
                    self.stack_len = top;
                    if (node.tailResolved()) |resolved| {
                        if (resolved.len() != 0) return resolved;
                    }
                },
            }
        }
    }
};

const rope_iterator_stack_capacity: usize = String.rope_max_depth;

/// QJS `string_rope_get`: return one UTF-16 code unit without flattening.
pub fn stringValueCodeUnitAt(value: JSValue, index: usize) ?u16 {
    if (!value.isString() or index >= stringValueLen(value)) return null;
    return stringValueCodeUnitAtUnchecked(value, index);
}

/// QJS `string_rope_get` precondition: `value` is a string/rope and `index` is
/// in range. Callers that already checked length avoid repeating optional/tag
/// validation on every character access.
pub fn stringValueCodeUnitAtUnchecked(value: JSValue, index: usize) u16 {
    var current = value;
    var relative = index;
    while (true) {
        const tag = current.tagOf();
        const header = current.stringHeaderAssumeStringLike();
        if (tag == ValueTag.string) return String.fromHeader(header).codeUnitAt(relative);
        std.debug.assert(tag == ValueTag.string_rope);

        const node = StringRope.fromHeader(header);
        if (node.flatString()) |flat| return flat.codeUnitAt(relative);

        const left_len = stringValueLenUnchecked(node.left);
        if (relative < left_len) {
            current = node.left;
            continue;
        }
        relative -= left_len;

        const right_len = stringValueLenUnchecked(node.right);
        if (relative < right_len) {
            current = node.right;
            continue;
        }
        relative -= right_len;

        const tail = node.tailResolved() orelse unreachable;
        return switch (tail) {
            .latin1 => |bytes| bytes[relative],
            .utf16 => |units| units[relative],
        };
    }
}

/// QJS `js_string_rope_compare`: compare flat and rope strings a leaf chunk at
/// a time. `eq_only` permits the same early length mismatch used by equality.
pub fn compareStringValues(a: JSValue, b: JSValue, eq_only: bool) ?i32 {
    if (!a.isString() or !b.isString()) return null;
    if (a.same(b)) return 0;

    const a_len = stringValueLen(a);
    const b_len = stringValueLen(b);
    if (eq_only and a_len != b_len) return 1;

    var remaining = @min(a_len, b_len);
    var a_iter = StringValueIterator.init(a);
    var b_iter = StringValueIterator.init(b);
    var a_part = a_iter.next();
    var b_part = b_iter.next();
    var a_pos: usize = 0;
    var b_pos: usize = 0;

    while (remaining != 0) {
        const a_resolved = a_part orelse return null;
        const b_resolved = b_part orelse return null;
        const chunk_len = @min(remaining, @min(a_resolved.len() - a_pos, b_resolved.len() - b_pos));
        const cmp = compareResolved(
            resolvedSlice(a_resolved, a_pos, chunk_len),
            resolvedSlice(b_resolved, b_pos, chunk_len),
        );
        if (cmp != 0) return cmp;

        remaining -= chunk_len;
        a_pos += chunk_len;
        b_pos += chunk_len;
        if (a_pos == a_resolved.len()) {
            a_part = a_iter.next();
            a_pos = 0;
        }
        if (b_pos == b_resolved.len()) {
            b_part = b_iter.next();
            b_pos = 0;
        }
    }

    return if (a_len < b_len) -1 else if (a_len > b_len) 1 else 0;
}

/// QJS `hash_string_rope`: hash leaf chunks in order without flattening. Flat
/// strings retain their existing cached hash; ropes intentionally do not add a
/// duplicate cache field, matching QJS's rope layout.
pub fn stringValueContentHash(value: JSValue) ?u32 {
    if (!value.isString()) return null;
    if (value.asStringBodyRaw()) |flat| return flat.contentHash();
    if (value.ropeBody()) |node| {
        if (node.flatString()) |flat| return flat.contentHash();
    }

    var iterator = StringValueIterator.init(value);
    var hash: u32 = 0;
    while (iterator.next()) |resolved| {
        hash = switch (resolved) {
            .latin1 => |bytes| hashLatin1(bytes, hash),
            .utf16 => |units| hashUtf16(units, hash),
        };
    }
    return foldHash30(hash);
}

fn resolvedSlice(resolved: String.ResolvedData, start: usize, len: usize) String.ResolvedData {
    return switch (resolved) {
        .latin1 => |bytes| .{ .latin1 = bytes[start..][0..len] },
        .utf16 => |units| .{ .utf16 = units[start..][0..len] },
    };
}

const StringValueInfo = struct {
    len: usize,
    depth: u8,
    wide: bool,
    header: *gc.StringHeader,
};

/// QJS `js_new_string_rope`'s one-tag-test operand classification.
fn stringValueInfo(value: JSValue) StringValueInfo {
    const tag = value.tagOf();
    const header = value.stringHeaderAssumeStringLike();
    if (tag == ValueTag.string_rope) {
        const node = StringRope.fromHeader(header);
        return .{ .len = node.len_(), .depth = node.depth, .wide = node.wide, .header = header };
    }
    std.debug.assert(tag == ValueTag.string or tag == ValueTag.symbol);
    const flat = String.fromHeader(header);
    return .{ .len = flat.len(), .depth = 0, .wide = flat.isWide(), .header = header };
}

fn createRopeNode(
    rt: *JSRuntime,
    left: JSValue,
    right: JSValue,
    left_info: StringValueInfo,
    right_info: StringValueInfo,
    with_accumulator_tail_slot: bool,
) !*StringRope {
    const total = try std.math.add(usize, left_info.len, right_info.len);
    // Rope-concat length cap (qjs JS_ConcatString rope path, quickjs.c:4898).
    if (total > max_length) return error.StringTooLong;
    const node = try allocRopeNode(rt, with_accumulator_tail_slot);
    node.* = .{
        .left = left,
        .right = right,
        .len = @intCast(total),
        .depth = @max(left_info.depth, right_info.depth) +| 1,
        .wide = left_info.wide or right_info.wide,
        .flags = if (with_accumulator_tail_slot) StringRope.accumulator_tail_slot_flag else 0,
        .rt = rt,
    };
    if (node.tailStateSlot()) |slot| slot.* = null;
    return node;
}

// Fibonacci buckets from QuickJS `rope_bucket_len` (quickjs.c:4934). The last
// entry is greater than `max_length`, so every valid string has a bucket.
const rope_bucket_len = [_]usize{
    1,         2,         3,         5,
    8,         13,        21,        34,
    55,        89,        144,       233,
    377,       610,       987,       1597,
    2584,      4181,      6765,      10946,
    17711,     28657,     46368,     75025,
    121393,    196418,    317811,    514229,
    832040,    1346269,   2178309,   3524578,
    5702887,   9227465,   14930352,  24157817,
    39088169,  63245986,  102334155, 165580141,
    267914296, 433494437, 701408733, 1134903170,
};

const RopeBuckets = [rope_bucket_len.len]?JSValue;

/// Consumes two owned values and returns one owned raw rope value. `createRope`
/// itself borrows and retains the inputs, so releasing the two incoming owners
/// after construction implements the ownership transfer used by QJS's
/// `js_new_string_rope`.
fn createOwnedRope(rt: *JSRuntime, left: JSValue, right: JSValue) !JSValue {
    return (try String.createRopeOwned(rt, left, right)).value();
}

/// Inserts one owned flat leaf into the Fibonacci buckets. On either success
/// or failure ownership of `owned_leaf` is consumed.
fn addRopeRebalanceLeaf(rt: *JSRuntime, buckets: *RopeBuckets, owned_leaf: JSValue) !void {
    const leaf_len = stringValueLen(owned_leaf);
    if (leaf_len == 0) {
        owned_leaf.free(rt);
        return;
    }

    var leaf: ?JSValue = owned_leaf;
    var accumulated: ?JSValue = null;
    errdefer {
        if (leaf) |value| value.free(rt);
        if (accumulated) |value| value.free(rt);
    }

    var bucket_index: usize = 0;
    while (leaf_len >= rope_bucket_len[bucket_index + 1]) : (bucket_index += 1) {
        if (buckets[bucket_index]) |bucket| {
            buckets[bucket_index] = null;
            if (accumulated) |current| {
                accumulated = null;
                accumulated = try createOwnedRope(rt, bucket, current);
            } else {
                accumulated = bucket;
            }
        }
    }

    if (accumulated) |prefix| {
        accumulated = null;
        const suffix = leaf.?;
        leaf = null;
        accumulated = try createOwnedRope(rt, prefix, suffix);
    } else {
        accumulated = leaf;
        leaf = null;
    }

    while (buckets[bucket_index]) |bucket| : (bucket_index += 1) {
        buckets[bucket_index] = null;
        const current = accumulated.?;
        accumulated = null;
        accumulated = try createOwnedRope(rt, bucket, current);
    }
    std.debug.assert(bucket_index < buckets.len);
    buckets[bucket_index] = accumulated;
    accumulated = null;
}

fn collectRopeRebalanceLeaves(rt: *JSRuntime, buckets: *RopeBuckets, value: JSValue) !void {
    const node = value.ropeBody() orelse {
        return addRopeRebalanceLeaf(rt, buckets, value.dup());
    };
    if (node.flatString()) |flat| {
        return addRopeRebalanceLeaf(rt, buckets, flat.value().dup());
    }

    try collectRopeRebalanceLeaves(rt, buckets, node.left);
    try collectRopeRebalanceLeaves(rt, buckets, node.right);
    if (node.tailResolved()) |tail| {
        const flat = switch (tail) {
            .latin1 => |bytes| try String.createLatin1(rt, bytes),
            .utf16 => |units| try String.createUtf16(rt, units),
        };
        try addRopeRebalanceLeaf(rt, buckets, flat.value());
    }
}

/// Returns a new balanced value without consuming `rope`. This is the Boehm,
/// Atkinson and Plass Fibonacci-bucket algorithm used by QuickJS
/// `js_rebalancee_string_rope`.
fn rebalanceRope(rt: *JSRuntime, rope: JSValue) !JSValue {
    var buckets: RopeBuckets = @splat(null);
    errdefer for (&buckets) |*entry| {
        if (entry.*) |value| value.free(rt);
    };

    try collectRopeRebalanceLeaves(rt, &buckets, rope);

    var result: ?JSValue = null;
    errdefer if (result) |value| value.free(rt);
    for (&buckets) |*entry| {
        const bucket = entry.* orelse continue;
        entry.* = null;
        if (result) |current| {
            result = null;
            result = try createOwnedRope(rt, bucket, current);
        } else {
            result = bucket;
        }
    }
    if (result) |balanced| return balanced;
    return (try String.createLatin1(rt, "")).value();
}

/// Appends flat content to a not-yet-materialized rope by extending the rope's
/// private tail buffer (amortized doubling) instead of chaining a new rope node
/// per concatenation. Returns false when the caller must keep the regular
/// new-node linking (materialized rope). Aliasing is the caller's contract,
/// exactly like the flat `append*InPlace` family (reference-count accounting at
/// the call site). On allocation failure the rope is left untouched.
pub fn appendRopeTail(node: *StringRope, rt: *JSRuntime, suffix: String.ResolvedData, max_ref_count: usize) !bool {
    std.debug.assert(node.rt == rt);
    if (node.isLinearized()) return false;
    if (!node.supportsTail()) return false;
    // A shared rope (a rope child, or otherwise held by an INDEPENDENT owner)
    // must not mutate in place: another owner's view would change under it.
    // The caller passes `max_ref_count` = the number of references it knows to
    // be aliases of the accumulator it is overwriting (e.g. the fused
    // `add_loc` path holds the local slot plus its own transient dup = 2). Any
    // reference beyond that is an independent observer, so appending in place
    // would corrupt it — bail. This is the refcount analogue of the old
    // `rope_child` snapshot bit, generalized to the caller's known-alias count.
    if (node.header().rc > max_ref_count) return false;
    const add_len = suffix.len();
    if (add_len == 0) return true;
    const new_total = checkedAddLength(node.len_(), add_len) orelse return false;
    // Length cap on the in-place tail-append fast path: past JS_STRING_LEN_MAX
    // the append bails to createRope, which throws error.StringTooLong (qjs
    // JS_ConcatString cap, quickjs.c:4898). One compare on the hot churn loop.
    if (new_total > max_length) return false;
    const used = node.tailLen();
    const need = checkedAddLength(used, add_len) orelse return false;

    const tail_slot = node.tailStateSlot().?;
    const widen_tail = if (tail_slot.*) |tail| switch (tail.data) {
        .latin1 => suffix == .utf16,
        .utf16 => true,
    } else suffix == .utf16;
    if (widen_tail) {
        const buf = try ropeTailEnsureWide(rt, node, need);
        switch (suffix) {
            .latin1 => |bytes| for (bytes, used..) |byte, index| {
                buf[index] = byte;
            },
            .utf16 => |units| @memcpy(buf[used..][0..add_len], units),
        }
    } else {
        const buf = try ropeTailEnsureNarrow(rt, node, need);
        @memcpy(buf[used..][0..add_len], suffix.latin1);
    }
    if (suffix == .utf16) node.wide = true;
    tail_slot.*.?.len = need;
    node.len = @intCast(new_total);
    return true;
}

/// Allocates the optional accumulator-tail sidecar and its first buffer. The
/// node is not mutated until both allocations succeed.
fn createRopeTailState(rt: *JSRuntime, node: *StringRope, comptime T: type, need: usize) ![]T {
    const state = try rt.createRuntime(RopeTailState);
    errdefer rt.destroyRuntime(RopeTailState, state);
    const buf = try rt.allocRuntime(T, nextStringCapacity(0, need));
    state.* = .{
        .data = if (T == u8) .{ .latin1 = buf } else .{ .utf16 = buf },
        .len = 0,
    };
    node.tailStateSlot().?.* = state;
    return buf;
}

/// Total allocation size for a `StringRope` node: the (padded) refcount prefix
/// plus the node struct. The prefix is padded to the node's alignment so the
/// node lands aligned at `base + StringRope.rc_prefix_size`.
const rope_node_alloc_size: usize = StringRope.rc_prefix_size + @sizeOf(StringRope);
const accumulator_rope_node_alloc_size: usize = rope_node_alloc_size + @sizeOf(?*RopeTailState);
const rope_node_alignment: std.mem.Alignment = std.mem.Alignment.of(StringRope);

comptime {
    // The padded prefix must be a whole multiple of the node's alignment so the
    // struct that follows it stays aligned, and it must be large enough to hold
    // the 4-byte rc word that sits at `nodePtr - 4`.
    std.debug.assert(StringRope.rc_prefix_size % @alignOf(StringRope) == 0);
    std.debug.assert(StringRope.rc_prefix_size >= gc.string_rc_prefix_size);
    std.debug.assert(@sizeOf(StringRope) % @alignOf(?*RopeTailState) == 0);
}

/// Allocates a `StringRope` node with a leading padded rc prefix (rc set to 1),
/// mirroring the flat `String` prefix model. Returns the node pointer; the rc
/// word lives at `nodePtr - 4` and is reached through `node.header()`.
fn allocRopeNode(rt: *JSRuntime, with_accumulator_tail_slot: bool) !*StringRope {
    const alloc_size = if (with_accumulator_tail_slot) accumulator_rope_node_alloc_size else rope_node_alloc_size;
    const bytes = try rt.allocStringAlignedBytes(alloc_size, rope_node_alignment);
    const node: *StringRope = @ptrCast(@alignCast(bytes.ptr + StringRope.rc_prefix_size));
    node.header().* = .{};
    return node;
}

/// Frees a `StringRope` node from its allocation base (`nodePtr - rc_prefix_size`).
fn freeRopeNode(rt: *JSRuntime, node: *StringRope) void {
    const base: [*]u8 = @as([*]u8, @ptrCast(node)) - StringRope.rc_prefix_size;
    const alloc_size = if (node.supportsTail()) accumulator_rope_node_alloc_size else rope_node_alloc_size;
    rt.memory.freeAlignedBytes(base[0..alloc_size], rope_node_alignment);
}

/// Releases a rope's private tail buffer (no-op for tail-less ropes).
fn freeRopeTail(rt: *JSRuntime, node: *StringRope) void {
    const slot = node.tailStateSlot() orelse return;
    const state = slot.* orelse return;
    switch (state.data) {
        .latin1 => |buf| rt.memory.free(u8, buf),
        .utf16 => |buf| rt.memory.free(u16, buf),
    }
    slot.* = null;
    rt.destroyRuntime(RopeTailState, state);
}

/// Grows (or creates) a narrow tail buffer to hold `need` used bytes and
/// returns it. Callers must route wide tails through `ropeTailEnsureWide`.
fn ropeTailEnsureNarrow(rt: *JSRuntime, node: *StringRope, need: usize) ![]u8 {
    const state = node.tailStateSlot().?.* orelse return createRopeTailState(rt, node, u8, need);
    switch (state.data) {
        .latin1 => |buf| {
            if (need <= buf.len) return buf;
            const grown = try rt.allocRuntime(u8, nextStringCapacity(buf.len, need));
            @memcpy(grown[0..state.len], buf[0..state.len]);
            rt.memory.free(u8, buf);
            state.data = .{ .latin1 = grown };
            return grown;
        },
        .utf16 => unreachable,
    }
}

/// Grows (or creates) a wide tail buffer to hold `need` used units and
/// returns it. A narrow tail is widened in place so a wide suffix can land
/// in the same buffer.
fn ropeTailEnsureWide(rt: *JSRuntime, node: *StringRope, need: usize) ![]u16 {
    const state = node.tailStateSlot().?.* orelse return createRopeTailState(rt, node, u16, need);
    switch (state.data) {
        .utf16 => |buf| {
            if (need <= buf.len) return buf;
            const grown = try rt.allocRuntime(u16, nextStringCapacity(buf.len, need));
            @memcpy(grown[0..state.len], buf[0..state.len]);
            rt.memory.free(u16, buf);
            state.data = .{ .utf16 = grown };
            return grown;
        },
        .latin1 => |buf| {
            const widened = try rt.allocRuntime(u16, nextStringCapacity(buf.len, need));
            for (buf[0..state.len], 0..) |byte, index| widened[index] = byte;
            rt.memory.free(u8, buf);
            state.data = .{ .utf16 = widened };
            return widened;
        },
    }
}

/// QJS caps rope depth at 60 and walks its tree without allocating. Do the
/// same here: the only possible failure during flattening is allocation of the
/// destination flat string itself. Each unlinearized zjs rope contributes
/// `left ++ right ++ optional-tail`.
fn copyRopeContent(comptime T: type, root: *const StringRope, out: []T) void {
    std.debug.assert(root.isLinearized() or root.depth <= String.rope_max_depth);
    var offset: usize = 0;
    copyRopeNodeContent(T, root, out, &offset);
    std.debug.assert(offset == out.len);
}

fn copyRopeNodeContent(comptime T: type, node: *const StringRope, out: []T, offset: *usize) void {
    if (node.flatString()) |flat| {
        offset.* += copyResolvedUnits(T, out[offset.*..], flat.resolveData());
        return;
    }
    copyRopeValueContent(T, node.left, out, offset);
    copyRopeValueContent(T, node.right, out, offset);
    if (node.tailResolved()) |resolved| {
        offset.* += copyResolvedUnits(T, out[offset.*..], resolved);
    }
}

fn copyRopeValueContent(comptime T: type, value: JSValue, out: []T, offset: *usize) void {
    if (value.ropeBody()) |node| {
        copyRopeNodeContent(T, node, out, offset);
        return;
    }
    if (value.asStringBodyRaw()) |flat| {
        offset.* += copyResolvedUnits(T, out[offset.*..], flat.resolveData());
    }
}

fn copyResolvedUnits(comptime T: type, out: []T, resolved: String.ResolvedData) usize {
    switch (resolved) {
        .latin1 => |bytes| {
            if (T == u8) {
                @memcpy(out[0..bytes.len], bytes);
            } else {
                for (bytes, 0..) |byte, i| out[i] = byte;
            }
            return bytes.len;
        },
        .utf16 => |units| {
            if (T == u16) {
                @memcpy(out[0..units.len], units);
                return units.len;
            }
            // A narrow rope (`wide == false`) can never contain wide leaves.
            unreachable;
        },
    }
}

/// Destroys a rope object when its refcount reaches 0. QJS's depth-60 invariant
/// bounds the recursive release chain, so the generic node needs no intrusive
/// destroy link.
pub fn destroyRope(rt: *JSRuntime, node: *StringRope) void {
    if (node.isLinearized()) {
        std.debug.assert(!node.hasTail());
        node.left.free(rt);
    } else {
        std.debug.assert(node.depth <= String.rope_max_depth);
        freeRopeTail(rt, node);
        node.left.free(rt);
        node.right.free(rt);
    }
    freeRopeNode(rt, node);
}

const InlineAllocationLayout = struct {
    total_size: usize,
    allocation_alignment: std.mem.Alignment,
};

fn inlineAllocationLayout(comptime tag: String.StorageTag, unit_count: usize) ?InlineAllocationLayout {
    const unit_size = switch (tag) {
        .latin1 => @sizeOf(u8),
        .utf16 => @sizeOf(u16),
    };
    const string_alignment = std.mem.Alignment.of(String);
    const payload_units = switch (tag) {
        // latin1 keeps a trailing NUL terminator (qjs `str8` is NUL-terminated).
        .latin1 => finalLatin1AllocationLen(unit_count) orelse return null,
        .utf16 => unit_count,
    };
    const payload_size = std.math.mul(usize, unit_size, payload_units) catch return null;
    // Layout: [rc prefix (4B)] [String struct] [char FAM]. `payload_offset` is
    // measured from the struct base to the FAM; the allocation additionally
    // carries the leading rc prefix, so the total starts with it.
    const struct_and_payload = std.math.add(usize, payload_offset, payload_size) catch return null;
    const total_size = std.math.add(usize, gc.string_rc_prefix_size, struct_and_payload) catch return null;
    return .{
        .total_size = total_size,
        .allocation_alignment = string_alignment,
    };
}

fn finalLatin1AllocationLen(unit_count: usize) ?usize {
    return std.math.add(usize, unit_count, 1) catch null;
}

fn writeLatin1Terminator(bytes: []u8) void {
    bytes.ptr[bytes.len] = 0;
}

fn checkedAddLength(a: usize, b: usize) ?usize {
    const result = @addWithOverflow(a, b);
    return if (result[1] == 0) result[0] else null;
}

fn nextStringCapacity(current: usize, needed: usize) usize {
    var capacity = if (current == 0) @as(usize, 16) else current;
    while (capacity < needed) {
        const doubled = @mulWithOverflow(capacity, 2);
        capacity = if (doubled[1] == 0 and doubled[0] > capacity) doubled[0] else needed;
    }
    return capacity;
}

/// Folds a full 32-bit content hash into the 30-bit field qjs `JSString.hash`
/// stores, reserving 0 as the "not yet computed" sentinel (a computed 0 becomes
/// 1). Flat strings and ropes both route through this so equal content hashes
/// identically regardless of rope state.
/// Folds a full 32-bit content hash into the 30-bit `HashMeta.hash` field,
/// bumping a computed 0 to 1 (qjs `js_string_compute_hash`). Callers that hash
/// string content WITHOUT a `String` object (e.g. the Map latin1-concat fast
/// path) must fold too, so their bucket matches `contentHash()`.
pub fn foldHash30(full: u32) u30 {
    const raw: u30 = @truncate(full);
    return if (raw == 0) 1 else raw;
}

pub fn hashBytes(bytes: []const u8) u32 {
    return hashLatin1(bytes, 0);
}

pub fn hashLatin1(bytes: []const u8, seed: u32) u32 {
    var h = seed;
    for (bytes) |byte| h = h *% 263 +% byte;
    return h;
}

pub fn hashUtf16(units: []const u16, seed: u32) u32 {
    var h = seed;
    for (units) |unit| h = h *% 263 +% unit;
    return h;
}

fn eqlUtf16Latin1(units: []const u16, bytes: []const u8) bool {
    if (units.len != bytes.len) return false;
    for (units, bytes) |unit, byte| {
        if (unit != byte) return false;
    }
    return true;
}

const Utf8Plan = struct {
    units: usize,
    wide: bool,
};

fn scanUtf8(bytes: []const u8) StringError!Utf8Plan {
    var i: usize = 0;
    var units: usize = 0;
    var wide = false;
    while (i < bytes.len) {
        const decoded = try decodeOne(bytes, i);
        i = decoded.next;
        if (decoded.codepoint <= 0xff) {
            units += 1;
        } else if (decoded.codepoint <= 0xffff) {
            wide = true;
            units += 1;
        } else {
            wide = true;
            units += 2;
        }
    }
    return .{ .units = units, .wide = wide };
}

fn decodeUtf8(bytes: []const u8, latin1: ?[]u8, utf16: ?[]u16) StringError!usize {
    var in_i: usize = 0;
    var out_i: usize = 0;
    while (in_i < bytes.len) {
        const decoded = try decodeOne(bytes, in_i);
        in_i = decoded.next;

        if (latin1) |out| {
            if (decoded.codepoint > 0xff) return error.InvalidUtf8;
            out[out_i] = @intCast(decoded.codepoint);
            out_i += 1;
        } else if (utf16) |out| {
            if (decoded.codepoint <= 0xffff) {
                out[out_i] = @intCast(decoded.codepoint);
                out_i += 1;
            } else {
                const pair = unicode.surrogatePairFromCodePoint(decoded.codepoint);
                out[out_i] = pair.high;
                out[out_i + 1] = pair.low;
                out_i += 2;
            }
        }
    }
    return out_i;
}

const Decoded = struct {
    codepoint: u21,
    next: usize,
};

fn decodeOne(bytes: []const u8, index: usize) StringError!Decoded {
    const b0 = bytes[index];
    if (b0 < 0x80) return .{ .codepoint = b0, .next = index + 1 };

    if (b0 & 0xe0 == 0xc0) {
        if (index + 1 >= bytes.len) return error.InvalidUtf8;
        const b1 = bytes[index + 1];
        if (b1 & 0xc0 != 0x80) return error.InvalidUtf8;
        const cp: u21 = (@as(u21, b0 & 0x1f) << 6) | (b1 & 0x3f);
        if (cp < 0x80) return error.InvalidUtf8;
        return .{ .codepoint = cp, .next = index + 2 };
    }

    if (b0 & 0xf0 == 0xe0) {
        if (index + 2 >= bytes.len) return error.InvalidUtf8;
        const b1 = bytes[index + 1];
        const b2 = bytes[index + 2];
        if (b1 & 0xc0 != 0x80 or b2 & 0xc0 != 0x80) return error.InvalidUtf8;
        const cp: u21 = (@as(u21, b0 & 0x0f) << 12) | (@as(u21, b1 & 0x3f) << 6) | (b2 & 0x3f);
        // The lexer uses WTF-8/CESU-8-style three-byte sequences as an
        // internal transport for lone surrogate escapes (`"\uD800"`).
        // JavaScript strings are UTF-16 code-unit sequences, so preserve
        // that code unit here instead of rejecting it as external UTF-8.
        if (cp < 0x800) return error.InvalidUtf8;
        return .{ .codepoint = cp, .next = index + 3 };
    }

    if (b0 & 0xf8 == 0xf0) {
        if (index + 3 >= bytes.len) return error.InvalidUtf8;
        const b1 = bytes[index + 1];
        const b2 = bytes[index + 2];
        const b3 = bytes[index + 3];
        if (b1 & 0xc0 != 0x80 or b2 & 0xc0 != 0x80 or b3 & 0xc0 != 0x80) return error.InvalidUtf8;
        const cp: u21 = (@as(u21, b0 & 0x07) << 18) | (@as(u21, b1 & 0x3f) << 12) | (@as(u21, b2 & 0x3f) << 6) | (b3 & 0x3f);
        if (cp < 0x10000 or cp > 0x10ffff) return error.InvalidUtf8;
        return .{ .codepoint = cp, .next = index + 4 };
    }

    return error.InvalidUtf8;
}

test "string ascii byte helper covers byte boundary" {
    try std.testing.expect(isAsciiBytes(""));
    try std.testing.expect(isAsciiBytes("plain/ascii-127\x7f"));
    try std.testing.expect(!isAsciiBytes("latin1-\xc3\xa9"));
    try std.testing.expect(!isAsciiBytes(&.{0x80}));
}

test "string compare uses code-unit ordering for same and mixed width strings" {
    const rt = try JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const latin_a = try String.createUtf8(rt, "abc");
    const latin_a_value = latin_a.value();
    defer latin_a_value.free(rt);
    const latin_b = try String.createUtf8(rt, "abd");
    const latin_b_value = latin_b.value();
    defer latin_b_value.free(rt);
    try std.testing.expectEqual(@as(i32, 0), latin_a.compare(latin_a));
    try std.testing.expect(latin_a.compare(latin_b) < 0);

    const wide_a = try String.createUtf16(rt, &.{0x0100});
    const wide_a_value = wide_a.value();
    defer wide_a_value.free(rt);
    const wide_b = try String.createUtf16(rt, &.{ 0x00ff, 0x0100 });
    const wide_b_value = wide_b.value();
    defer wide_b_value.free(rt);
    try std.testing.expect(wide_a.compare(wide_b) > 0);

    const wide_parent = try String.createUtf16(rt, &.{ 0x0100, 'a' });
    const wide_parent_value = wide_parent.value();
    defer wide_parent_value.free(rt);
    const wide_slice = try String.createSlice(rt, wide_parent, 1, 1);
    const wide_slice_value = wide_slice.value();
    defer wide_slice_value.free(rt);
    const latin_single = try String.createUtf8(rt, "a");
    const latin_single_value = latin_single.value();
    defer latin_single_value.free(rt);
    try std.testing.expectEqual(@as(i32, 0), latin_single.compare(wide_slice));
}

test "string compare short-circuits equal interned atom ids" {
    const rt = try JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const first = try String.createUtf8(rt, "length");
    const first_value = first.value();
    defer first_value.free(rt);
    const first_atom = try first.internAtom(rt);
    defer rt.atoms.free(first_atom);

    const second = try String.createUtf8(rt, "length");
    const second_value = second.value();
    defer second_value.free(rt);
    const second_atom = try second.internAtom(rt);
    defer rt.atoms.free(second_atom);

    try std.testing.expectEqual(first_atom, second_atom);
    try std.testing.expect(first != second);
    try std.testing.expectEqual(@as(i32, 0), first.compare(second));
}

const std = @import("std");

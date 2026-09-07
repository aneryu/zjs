//! Traced flat strings, deferred ropes, and code-unit operations.
//!
//! A string JSValue names either a flat `String` or a `StringRope`; rope nodes
//! trace both children and materialize a stable flat
//! body on first borrowed-content read. Allocation and release always go
//! through the originating Runtime. QuickJS source map:
//! `JSString`/`JSStringRope` at quickjs.c:583-609. Core and higher layers may
//! import this module; it has no exec/binding dependency.

const atom_mod = @import("atom.zig");
const gc = @import("gc.zig");
const gc_block_heap = @import("gc_block_heap.zig");
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
/// traced heap object reached through a `JSValue` tagged
/// `Tag.string_rope` (never a `*String`). It owns its `left`/`right` children
/// as `JSValue`s (each may itself be a flat `Tag.string` or another
/// `Tag.string_rope`, so rope-of-rope chains are handled). Generic ropes keep
/// only the QJS-like tree state plus the runtime needed by the infallible
/// borrowed-string API.
///
/// The first content read MATERIALIZES the rope into a flat `*String`
/// (`flatten`, mirroring qjs `js_linearize_string_rope`) and caches it in
/// `left` with `depth == 0`, releasing the former children. This
/// mirrors qjs's linearized `left=flat, right=empty` representation without a
/// separate flat/hash payload. All borrowed slices returned to readers point
/// into that owned flat string, so they stay valid for as long as the rope
/// object is alive. Like QuickJS, a `Tag.string_rope` value stores the rope
/// body pointer.
pub const StringRope = struct {
    left: JSValue,
    right: JSValue,
    /// `asStringBody()` has no context/runtime argument, so zjs retains this
    /// one pointer for on-demand linearization. QJS receives `JSContext *` at
    /// its linearization call site and therefore does not need it in the node.
    rt: *JSRuntime,
    /// TGC S2-i: the shared tail buffer this node is a DEPENDENT VIEW of.
    /// Non-null makes the node a leaf whose content is `buffer[0..len]`;
    /// `left`/`right` are then undefined-valued and `depth` is one.
    /// Null is the ordinary QJS-shaped `left ++ right` node.
    buffer: ?*StringBuffer = null,
    /// Total length in code units.
    /// QJS uses uint32_t and caps strings below 2^30; keep the same width.
    len: u32,
    /// Maximum child depth plus one, matching QuickJS `JSStringRope.depth`.
    /// Generic concatenation rebalances once this exceeds
    /// `String.rope_max_depth`, keeping reads and recursive destruction
    /// bounded. Zero is reserved for an already-linearized rope.
    depth: u8,
    wide: bool,
    /// TGC S2-i: append rights on `buffer`. At most ONE live node per buffer
    /// carries it, which is what replaces the retired `rc == 1` uniqueness
    /// test: `r = s + x` moves the right from `s` to `r`, so a second
    /// `s + y` finds `s` inextensible and copies instead of overwriting the
    /// bytes `s` still names. Always false when `buffer == null`.
    extensible: bool = false,
    reserved: u8 = 0,

    comptime {
        std.debug.assert(@sizeOf(StringRope) == 56);
        std.debug.assert(@alignOf(StringRope) == 8);
        std.debug.assert(@offsetOf(StringRope, "left") == 0);
        std.debug.assert(@offsetOf(StringRope, "right") == 16);
        std.debug.assert(@offsetOf(StringRope, "rt") == 32);
        std.debug.assert(@offsetOf(StringRope, "buffer") == 40);
        std.debug.assert(@offsetOf(StringRope, "len") == 48);
        std.debug.assert(@offsetOf(StringRope, "depth") == 52);
        std.debug.assert(@offsetOf(StringRope, "wide") == 53);
        std.debug.assert(@offsetOf(StringRope, "extensible") == 54);
    }

    /// Size of the collector metadata prefix ahead of a rope node.
    pub const metadata_prefix_size: usize = std.mem.alignForward(usize, gc.string_prefix_size, @alignOf(StringRope));

    /// Unified collector handle. String-family handles are their body pointer;
    /// the metadata is immediately before the body.
    pub inline fn header(self: *const StringRope) *gc.GCObjectHeader {
        return @ptrCast(@alignCast(@constCast(self)));
    }

    pub inline fn fromHeader(hdr: *gc.GCObjectHeader) *StringRope {
        return @ptrCast(@alignCast(hdr));
    }

    /// The `Metadata` word at the allocation base (`nodePtr - 8`).
    pub inline fn metadata(self: *const StringRope) *gc.Metadata {
        const base: [*]u8 = @ptrCast(@constCast(self));
        return @ptrCast(@alignCast(base - metadata_prefix_size));
    }

    /// A `Tag.string_rope` JSValue pointing at this node.
    pub fn value(self: *StringRope) JSValue {
        return JSValue.stringRope(self.header());
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

    pub fn flatString(self: *const StringRope) ?*String {
        if (!self.isLinearized()) return null;
        return self.left.asStringBodyRaw();
    }

    /// TGC S2-i: the code units a dependent view names, or null for an
    /// ordinary `left ++ right` node. Every rope reader tests this in the
    /// same place it tests `flatString`: a view is a LEAF, so the tree walk
    /// below it must not run (its `left`/`right` are undefined values).
    pub inline fn bufferView(self: *const StringRope) ?String.ResolvedData {
        const buf = self.buffer orelse return null;
        return buf.prefix(self.len);
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
        // TGC S2-i: a dependent view materializes by copying its prefix out
        // of the shared buffer. It cannot hand the buffer itself out as the
        // flat body: a `String` keeps its units in its own FAM immediately
        // after a twelve-byte header, and the buffer has neither that header
        // nor exclusive ownership of the bytes (older views still name the
        // same prefix).
        const flat = if (self.buffer) |buf| blk: {
            std.debug.assert(buf.is_wide == self.wide);
            if (buf.is_wide) {
                const s = try String.createUninitialized(rt, .utf16, total_len);
                @memcpy(s.utf16Mut(), buf.utf16Const()[0..total_len]);
                break :blk s;
            }
            const s = try String.createUninitialized(rt, .latin1, total_len);
            @memcpy(s.latin1Mut(), buf.latin1Const()[0..total_len]);
            writeLatin1Terminator(s.latin1Mut());
            break :blk s;
        } else if (self.wide) blk: {
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
        // The rope is a heap owner adopting a fresh (young / possibly
        // unmarked) child.
        rt.gc.generationalBarrierValue(@ptrCast(@alignCast(self)), flat.value());
        self.left = flat.value();
        self.right = JSValue.undefinedValue();
        // Dropping the buffer edge is the same class of write `right` above
        // takes: the linearized node owns its flat child and nothing else.
        // The append right goes with it -- a linearized node is never a
        // concat accumulator again.
        self.buffer = null;
        self.extensible = false;
        self.depth = 0;
        // Release the former tree only after publishing the new owned flat
        // child. String destruction has no user callback, but this ordering
        // also keeps the rope internally valid under force-GC diagnostics.
        return flat;
    }

    /// Infallible flatten used by borrowed-slice readers that cannot propagate
    /// errors (`resolveData`). On OOM it runs object-cycle removal to reclaim
    /// memory and retries once; a second failure is fatal.
    pub fn flattenInfallible(self: *StringRope) *String {
        return self.flatten() catch {
            _ = self.rt.tryRunObjectCycleRemovalWithValueRoots(null, .engine_active) catch {}; // engine-frames-active trigger
            return self.flatten() catch @panic("zjs: out of memory while flattening string rope");
        };
    }

    /// Content hash without materialization. Flat children keep their normal
    /// cache; the rope itself has no duplicate hash field, matching QJS.
    pub fn contentHash(self: *StringRope) u32 {
        return stringValueContentHash(self.value()).?;
    }
};

/// TGC S2-i: the extensible tail buffer a chain of dependent rope views
/// shares (SpiderMonkey's extensible/dependent string pair, minus the
/// refcount its exclusivity test used to need -- see `StringRope.extensible`).
///
/// A bare storage carrier of GC kind `.string_buffer`: no out-edges, no
/// destructor, no JSValue names it. It is kept alive by the `storageCell`
/// edge every viewing rope node reports, and returned by the bitmap sweep
/// (block cell) or the extent sweep, exactly like a flat body without the
/// atom handshake.
///
/// Layout mirrors `String`: an eight-byte collector `Metadata` prefix, then
/// this header, then the code-unit FAM. `capacity` counts CODE UNITS, so a
/// wide buffer holds `capacity` u16s.
pub const StringBuffer = struct {
    capacity: u32,
    is_wide: bool,
    reserved: [3]u8 = .{ 0, 0, 0 },

    /// Byte offset from the header to the code-unit FAM. Same reasoning as
    /// `payload_offset` for `String`: the 8-aligned allocation base plus an
    /// 8-byte header keeps the u16 payload u16-aligned.
    pub const units_offset: usize = 8;

    comptime {
        std.debug.assert(@sizeOf(StringBuffer) == 8);
        std.debug.assert(@alignOf(StringBuffer) == 4);
        std.debug.assert(@offsetOf(StringBuffer, "capacity") == 0);
        std.debug.assert(@offsetOf(StringBuffer, "is_wide") == 4);
        std.debug.assert(units_offset % @alignOf(u16) == 0);
    }

    pub inline fn header(self: *const StringBuffer) *gc.GCObjectHeader {
        return @ptrCast(@alignCast(@constCast(self)));
    }

    pub inline fn fromHeader(hdr: *gc.GCObjectHeader) *StringBuffer {
        return @ptrCast(@alignCast(hdr));
    }

    inline fn unitsPtr(self: *const StringBuffer) [*]u8 {
        const base: [*]u8 = @ptrCast(@constCast(self));
        return base + units_offset;
    }

    pub inline fn latin1(self: *StringBuffer) []u8 {
        std.debug.assert(!self.is_wide);
        return self.unitsPtr()[0..self.capacity];
    }

    pub inline fn utf16(self: *StringBuffer) []u16 {
        std.debug.assert(self.is_wide);
        const units: [*]u16 = @ptrCast(@alignCast(self.unitsPtr()));
        return units[0..self.capacity];
    }

    pub inline fn latin1Const(self: *const StringBuffer) []const u8 {
        std.debug.assert(!self.is_wide);
        return self.unitsPtr()[0..self.capacity];
    }

    pub inline fn utf16Const(self: *const StringBuffer) []const u16 {
        std.debug.assert(self.is_wide);
        const units: [*]const u16 = @ptrCast(@alignCast(self.unitsPtr()));
        return units[0..self.capacity];
    }

    /// The first `used` code units as a reader-shaped slice.
    pub inline fn prefix(self: *const StringBuffer, used: u32) String.ResolvedData {
        std.debug.assert(used <= self.capacity);
        if (self.is_wide) return .{ .utf16 = self.utf16Const()[0..used] };
        return .{ .latin1 = self.latin1Const()[0..used] };
    }
};

/// Total allocation bytes (prefix included) for a buffer of `capacity` code
/// units. Null on overflow.
fn stringBufferAllocSize(is_wide: bool, capacity: usize) ?usize {
    const unit_size: usize = if (is_wide) @sizeOf(u16) else @sizeOf(u8);
    const payload = std.math.mul(usize, unit_size, capacity) catch return null;
    const body = std.math.add(usize, StringBuffer.units_offset, payload) catch return null;
    return std.math.add(usize, gc.string_prefix_size, body) catch return null;
}

/// Allocate and publish an uninitialized tail buffer. TGC S4 spec 2.2: one
/// funnel, block cell under the small-class ceiling and a heap extent above
/// it. The units are left undefined; the caller fills `[0, used)` before any
/// view can name them.
pub fn createStringBuffer(rt: *JSRuntime, is_wide: bool, capacity: usize) !*StringBuffer {
    if (capacity > max_length) return error.StringTooLong;
    const total = stringBufferAllocSize(is_wide, capacity) orelse return error.OutOfMemory;
    // Same allocation-threshold boundary flat bodies and rope nodes take
    // (TGC S2-f (3)); before the raw carrier pointer is taken.
    rt.collectBeforeObjectAllocation(total);
    const cell = try rt.memory.createStorageCell(gc.representation.string_buffer_kind_tag, total);
    const buf: *StringBuffer = @ptrCast(@alignCast(cell.base + gc.string_prefix_size));
    buf.* = .{ .capacity = @intCast(capacity), .is_wide = is_wide };
    rt.gc.addInitializedWithSizeNoFail(@ptrCast(@alignCast(buf)), cell.accounted_bytes);
    return buf;
}

/// Sweep-time return of a condemned `.string_buffer` BLOCK CELL. Pure memory:
/// a buffer owns no edges, no atom entry and no external resource.
pub fn destroyStringBufferCell(rt: *JSRuntime, header: *gc.GCObjectHeader) void {
    std.debug.assert(gc.Registry.isBlockCellHeader(header));
    const buf: *StringBuffer = @ptrCast(@alignCast(header));
    const total = stringBufferAllocSize(buf.is_wide, buf.capacity).?;
    rt.gc.unpublishStringCell(header, gc_block_heap.accountedBodyBytesForRequest(total, gc.string_prefix_size).?);
    rt.memory.destroyStringCell(buf, total);
}

/// Registry-side size query for a `.string_buffer` carrier, the twin of
/// `accountedAllocationSizeFromHeader`.
pub fn accountedStorageSizeFromHeader(header: *const gc.GCObjectHeader) usize {
    const buf: *const StringBuffer = @ptrCast(@alignCast(header));
    const total = stringBufferAllocSize(buf.is_wide, buf.capacity).?;
    if (gc.Registry.isBlockCellHeader(header)) {
        return gc_block_heap.accountedBodyBytesForRequest(total, gc.string_prefix_size).?;
    }
    return total - gc.string_prefix_size;
}

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

    /// Unified collector handle. String-family handles are their body pointer.
    pub inline fn header(self: *const String) *gc.GCObjectHeader {
        return @ptrCast(@alignCast(@constCast(self)));
    }

    pub inline fn fromHeader(hdr: *gc.GCObjectHeader) *String {
        return @ptrCast(@alignCast(hdr));
    }

    /// TGC S4-d spec 2.4: bind a materialized-string back-pointer.
    ///
    /// A DYNAMIC atom id makes this body's death owe the atom-table handshake
    /// (`destroyCellFromHeader` -> `onSymbolBodyDead`), so the sweep has to
    /// visit the cell: stamp `needs_finalizer`. Predefined and tagged-int ids
    /// are never recycled, the handshake skips them, and such a body stays in
    /// the bitmap-only population. The bit only ever goes on (D-S4-4).
    pub fn bindAtomId(self: *String, rt: *JSRuntime, atom_id: u32) void {
        self.atom_id = atom_id;
        if (atom_id == no_atom_id or atom_mod.isConst(atom_id) or atom_mod.isTaggedInt(atom_id)) return;
        rt.gc.setNeedsFinalizer(self.header());
    }

    /// The `Metadata` word at the allocation base (`stringPtr - 8`).
    pub inline fn metadata(self: *const String) *gc.Metadata {
        const base: [*]u8 = @ptrCast(@constCast(self));
        return @ptrCast(@alignCast(base - gc.string_prefix_size));
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

    /// Interns this string's content as a property-key atom and returns an
    /// owned atom reference (caller releases it via `rt.atoms.free`).
    ///
    /// The atom name uses the same UTF-8/WTF-8 encoding the lexer and the
    /// JSON parser produce, so keys built from runtime strings unify with
    /// keys interned from source text. The string is then bound into the
    /// atom table's per-atom string cache (`AtomTable.cacheString`): the
    /// table traces the cached string and `atom_id` becomes a weak
    /// back-pointer; the reverse direction (`AtomTable.toStringValue`) reuses
    /// the same string with zero conversion.
    /// Rope-backed strings are flattened by the content read.
    pub fn internAtom(self: *String, rt: *JSRuntime) !u32 {
        if (self.atom_id != no_atom_id) return self.atom_id;
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
        rt.atoms.cacheString(rt, atom_id, self);
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

    /// Concatenate already-flattened mixed-width pieces into one freshly
    /// allocated string. Mirrors qjs `JS_ConcatString1` (quickjs.c:4646): the
    /// result is wide iff any part is wide (`p1->is_wide_char ||
    /// p2->is_wide_char`), one `js_alloc_string`, then each part copies into
    /// the result payload — same-width parts memcpy, latin1 parts widen per
    /// code unit into a wide result. `wide` must be the OR of the part widths
    /// and `total` the sum of their unit lengths (both from the caller's
    /// measure pass).
    pub fn createResolvedParts(rt: *JSRuntime, parts: []const ResolvedData, total: usize, wide: bool) !*String {
        if (!wide) {
            const self = try createUninitialized(rt, .latin1, total);
            errdefer destroyFlat(rt, self);
            const out = self.latin1Mut();
            var offset: usize = 0;
            for (parts) |part| {
                switch (part) {
                    .latin1 => |bytes| {
                        @memcpy(out[offset..][0..bytes.len], bytes);
                        offset += bytes.len;
                    },
                    // A wide part forces `wide` at the caller's measure pass.
                    .utf16 => unreachable,
                }
            }
            std.debug.assert(offset == total);
            writeLatin1Terminator(out);
            return self;
        }
        const self = try createUninitialized(rt, .utf16, total);
        errdefer destroyFlat(rt, self);
        const out = self.utf16Mut();
        var offset: usize = 0;
        for (parts) |part| {
            switch (part) {
                .latin1 => |bytes| {
                    for (bytes, 0..) |byte, i| out[offset + i] = byte;
                    offset += bytes.len;
                },
                .utf16 => |units| {
                    @memcpy(out[offset..][0..units.len], units);
                    offset += units.len;
                },
            }
        }
        std.debug.assert(offset == total);
        return self;
    }

    pub fn createLatin1ConcatWithSeed(rt: *JSRuntime, a: []const u8, b: []const u8, seed: u32) !*String {
        _ = seed;
        return createLatin1Concat(rt, a, b);
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

    /// Append an ASCII literal to an already-resolved string with one final
    /// allocation. This is the storage operation behind qjs
    /// `JS_ConcatString3(ctx, "", value, suffix)`: a narrow input stays
    /// narrow, while a wide input remains wide and receives widened ASCII code
    /// units directly in its inline payload.
    pub fn createAsciiSuffix(rt: *JSRuntime, source: ResolvedData, suffix: []const u8) !*String {
        std.debug.assert(isAsciiBytes(suffix));
        return switch (source) {
            .latin1 => |bytes| createLatin1Concat(rt, bytes, suffix),
            .utf16 => |units| blk: {
                const total = try std.math.add(usize, units.len, suffix.len);
                const self = try createUninitialized(rt, .utf16, total);
                errdefer destroyFlat(rt, self);
                const out = self.utf16Mut();
                @memcpy(out[0..units.len], units);
                for (suffix, units.len..) |byte, index| out[index] = byte;
                break :blk self;
            },
        };
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

    /// TGC S2-i: the LHS length at which `a + b` stops producing a fresh flat
    /// body and starts an extensible tail buffer instead.
    ///
    /// Below it the flat copy is the cheaper answer -- a short result usually
    /// becomes a property key or a comparand next, and a dependent view has
    /// to flatten (one copy plus one allocation) before it can be either. At
    /// and above it the quadratic term of `s = s + x` dominates: the flat arm
    /// re-copies the whole accumulator on every append, which is 97.9% of
    /// pdfjs's memcpy time (spec 7.11).
    ///
    /// 512 was measured, not assumed (ReleaseFast, fixed-work, CPU 15):
    /// 128 gave pdfjs 2.53 s but regexp maxrss 139 MB against a 106 MB
    /// baseline; 2048 gave regexp 95 MB but pdfjs 2.62 s. 512 with the 1.5x
    /// seed capacity below holds pdfjs at 2.55 s and regexp at ~103 MB.
    pub const tail_buffer_seed_len: usize = 512;

    /// Smallest tail buffer worth allocating, in code units.
    pub const tail_buffer_min_capacity: usize = 64;

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
        return createRopeNode(rt, left, right, left_info, right_info);
    }

    /// Consuming counterpart of `createRope`, matching QJS
    /// `js_new_string_rope(ctx, op1, op2)`: both input owners transfer directly
    /// into the new node, with no retain-then-free round trip. On failure both
    /// inputs are released.
    pub fn createRopeOwned(rt: *JSRuntime, left: JSValue, right: JSValue) !*StringRope {
        const left_info = stringValueInfo(left);
        const right_info = stringValueInfo(right);
        return createRopeNode(rt, left, right, left_info, right_info) catch |err| {
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
            return err;
        };
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
            return err;
        };
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
    pub inline fn inlineBytesPtr(self: *const String) [*]const u8 {
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

    const StorageTag = enum { latin1, utf16 };

    fn createUninitialized(rt: *JSRuntime, comptime tag: StorageTag, unit_count: usize) !*String {
        // Central allocation cap (qjs js_alloc_string / string_buffer_realloc,
        // quickjs.c:4078): every flat creator funnels through here, so this one
        // compare bounds all string construction.
        if (unit_count > max_length) return error.StringTooLong;
        const inline_layout = inlineAllocationLayout(tag, unit_count) orelse return error.OutOfMemory;
        // TGC S2-f (3): flat string bodies are collector carriers now, so
        // string churn has to cross the same allocation-threshold boundary
        // object construction does. qjs could skip it (`js_alloc_string` is
        // plain malloc + refcount, and `js_trigger_gc` fires only from
        // `JS_NewObjectFromShape`), but under the tracer a pure string loop
        // would otherwise allocate without bound: 380k x 320B leaves
        // `young_count` at 380k and `collections` at zero. Level-triggered,
        // one compare on the fast path, cold tail otherwise. It must precede
        // every raw carrier pointer this function takes.
        rt.collectBeforeObjectAllocation(inline_layout.total_size);
        // Reserve the eight-byte Metadata prefix ahead of the struct so
        // `String` itself stays exactly 12B (qjs `JSString`). The block base
        // is 8-aligned (Metadata), so the struct at `base + 8` keeps `String`'s
        // 4-byte alignment and the inline char FAM stays u16-aligned. The
        // prefix carries collector metadata.
        if (try rt.memory.createStringCell(gc.representation.string_kind_tag, inline_layout.total_size)) |base| {
            const self: *String = @ptrCast(@alignCast(base + gc.string_prefix_size));
            self.* = .{
                .len_meta = .{ .len = @intCast(unit_count), .is_wide = (tag == .utf16) },
                .hash_meta = .{},
                .atom_id = no_atom_id,
            };
            rt.gc.addInitializedWithSizeNoFail(@ptrCast(@alignCast(self)), gc_block_heap.accountedBodyBytesForRequest(inline_layout.total_size, gc.string_prefix_size).?);
            return self;
        }
        // Extent route (spec §5.7): over the cell ceiling the body lives in a
        // medium page run / large mapping of the same heap.
        const bytes = try rt.memory.createStringExtent(inline_layout.total_size);
        const self: *String = @ptrCast(@alignCast(bytes.ptr + gc.string_prefix_size));
        self.* = .{
            .len_meta = .{ .len = @intCast(unit_count), .is_wide = (tag == .utf16) },
            .hash_meta = .{},
            .atom_id = no_atom_id,
        };
        rt.gc.addInitializedWithSizeNoFail(@ptrCast(@alignCast(self)), inline_layout.total_size - gc.string_prefix_size);
        return self;
    }

    fn destroyFlat(rt: *JSRuntime, self: *String) void {
        const tag: StorageTag = if (self.len_meta.is_wide) .utf16 else .latin1;
        const inline_layout = switch (tag) {
            .latin1 => inlineAllocationLayout(.latin1, self.len_meta.len) orelse unreachable,
            .utf16 => inlineAllocationLayout(.utf16, self.len_meta.len) orelse unreachable,
        };
        if (gc.Registry.isBlockCellHeader(@ptrCast(@alignCast(self)))) {
            rt.memory.destroyStringCell(self, inline_layout.total_size);
            return;
        }
        std.debug.assert(self.metadata().alloc_info.standalone);
        rt.memory.destroyStringExtent(self, inline_layout.total_size);
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
    // The flat `String` prefix is a multiple of `@alignOf(String)`, so the
    // struct at `base + prefix` keeps `String`'s alignment (and thus the u16
    // FAM stays aligned). Guard the invariant the layout math relies on.
    std.debug.assert(gc.string_prefix_size % @alignOf(String) == 0);
    std.debug.assert(gc.string_prefix_size == @sizeOf(gc.Metadata));
    std.debug.assert(@sizeOf(String) == 12);
    std.debug.assert(@alignOf(String) == 4);
    std.debug.assert(@offsetOf(String, "len_meta") == 0);
    std.debug.assert(@offsetOf(String, "hash_meta") == 4);
    std.debug.assert(@offsetOf(String, "atom_id") == 8);
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
/// code-unit order without materializing the rope.
pub const StringValueIterator = struct {
    current: ?JSValue,
    nodes: [rope_iterator_stack_capacity]*const StringRope = undefined,
    stack_len: usize = 0,

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
                // TGC S2-i: a dependent view is a leaf over the shared tail
                // buffer; descending into `left`/`right` would read undefined
                // values.
                if (node.bufferView()) |view| {
                    if (view.len() != 0) return view;
                    continue;
                }

                std.debug.assert(self.stack_len < self.nodes.len);
                self.nodes[self.stack_len] = node;
                self.stack_len += 1;
                self.current = node.left;
                continue;
            }

            if (self.stack_len == 0) return null;
            const top = self.stack_len - 1;
            const node = self.nodes[top];
            self.stack_len = top;
            self.current = node.right;
        }
    }
};

const rope_iterator_stack_capacity: usize = String.rope_max_depth;

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
        if (node.bufferView()) |view| return switch (view) {
            .latin1 => |bytes| bytes[relative],
            .utf16 => |units| units[relative],
        };

        const left_len = stringValueLenUnchecked(node.left);
        if (relative < left_len) {
            current = node.left;
            continue;
        }
        relative -= left_len;
        current = node.right;
    }
}

/// QJS `js_string_rope_compare`: compare flat and rope strings a leaf chunk at
/// a time. `eq_only` permits the same early length mismatch used by equality.
/// QJS `js_string_eq` (quickjs.c:4605-4613): length test, pointer identity, then
/// one body comparison through `js_string_memcmp` (quickjs.c:4586-4603).
///
/// Flat strings only. qjs's inline OP_CMP_EQ / OP_CMP_STRICT_EQ arms fire on
/// `JS_TAG_STRING` (quickjs.c:20321, 20382), and a rope carries the distinct
/// `JS_TAG_STRING_ROPE`, so ropes never reach `js_string_eq` from the dispatch
/// loop. Keeping the same restriction here is what lets this stay allocation-,
/// iterator- and frame-free: `compareStringValues` below must open a 60-slot
/// `StringValueIterator` pair for the rope case before it can even test the
/// lengths, which is the cost this bypasses for the flat-flat majority.
pub fn flatStringsEq(a: *const String, b: *const String) bool {
    return flatStringsEqNear(a, b) orelse flatStringsEqMixedWidth(a, b);
}

/// qjs `js_string_eq` (quickjs.c:4605-4613) for a same-width flat pair:
/// length, pointer identity, then one body scan. Returns `null` when the
/// encodings differ so the caller can keep the framed mixed-width helper
/// (qjs `js_string_memcmp` 4586-4599) off the leftover leaf.
pub inline fn flatStringsEqNear(a: *const String, b: *const String) ?bool {
    if (a.len_meta.len != b.len_meta.len) return false; // qjs:4607
    if (a == b) return true; // qjs:4609
    if (a.len_meta.is_wide != b.len_meta.is_wide) return null;
    // Same-width scan in place of `memcmp` / `memcmp16` (quickjs.c:4593, 4600).
    // A libcall here would open a frame on the leftover mixed leaf (硬门 #9).
    const n: u32 = a.len_meta.len;
    const pa = a.inlineBytesPtr();
    const pb = b.inlineBytesPtr();
    var i: u32 = 0;
    if (a.len_meta.is_wide) {
        const ua: [*]const u16 = @ptrCast(@alignCast(pa));
        const ub: [*]const u16 = @ptrCast(@alignCast(pb));
        while (i < n) : (i += 1) {
            if (ua[i] != ub[i]) return false;
        }
        return true;
    }
    while (i < n) : (i += 1) {
        if (pa[i] != pb[i]) return false;
    }
    return true;
}

fn flatStringsEqMixedWidth(a: *const String, b: *const String) bool {
    const narrow = if (a.len_meta.is_wide) b else a;
    const wide = if (a.len_meta.is_wide) a else b;
    for (narrow.latin1(), wide.utf16()) |unit_n, unit_w| {
        if (unit_n != unit_w) return false;
    }
    return true;
}

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

/// Append `value`'s text to `buffer` as UTF-8. Non-string values append
/// nothing — callers coerce first when they need ToString.
///
/// This is the single owner of the operation qjs spells `JS_ToCStringLen2`
/// (quickjs.c:4458). Eight hand-written copies of it existed, and their
/// comments record the same defect being repaired independently six times:
/// latin1 0x80-0xFF must WIDEN to UTF-8 rather than land as raw bytes, and
/// UTF-16 surrogate pairs must combine into one 4-byte sequence rather than
/// encode per unit (the CESU-8 form, which cannot byte-match an astral needle
/// encoded the canonical way). It lives in core because two of the copies are
/// core files, which cannot import exec.
pub fn appendValueUtf8(rt: *JSRuntime, buffer: *std.ArrayList(u8), value: JSValue) !void {
    const string_value = value.asStringBody() orelse return;
    try string_value.ensureFlat(rt);
    switch (string_value.resolveData()) {
        .latin1 => |bytes| {
            if (isAsciiBytes(bytes)) return buffer.appendSlice(rt.memory.allocator, bytes);
            for (bytes) |byte| try unicode.appendUtf8CodePoint(rt.memory.allocator, buffer, byte);
        },
        .utf16 => |units| try unicode.appendUtf16UnitsAsUtf8(rt.memory.allocator, buffer, units),
    }
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
};

/// QJS `js_new_string_rope`'s one-tag-test operand classification.
fn stringValueInfo(value: JSValue) StringValueInfo {
    const tag = value.tagOf();
    const header = value.stringHeaderAssumeStringLike();
    if (tag == ValueTag.string_rope) {
        const node = StringRope.fromHeader(header);
        return .{ .len = node.len_(), .depth = node.depth, .wide = node.wide };
    }
    std.debug.assert(tag == ValueTag.string or tag == ValueTag.symbol);
    const flat = String.fromHeader(header);
    return .{ .len = flat.len(), .depth = 0, .wide = flat.isWide() };
}

fn createRopeNode(
    rt: *JSRuntime,
    left: JSValue,
    right: JSValue,
    left_info: StringValueInfo,
    right_info: StringValueInfo,
) !*StringRope {
    const total = try std.math.add(usize, left_info.len, right_info.len);
    // Rope-concat length cap (qjs JS_ConcatString rope path, quickjs.c:4898).
    if (total > max_length) return error.StringTooLong;
    const node = try allocRopeNode(rt);
    node.* = .{
        .left = left,
        .right = right,
        .len = @intCast(total),
        .depth = @max(left_info.depth, right_info.depth) +| 1,
        .wide = left_info.wide or right_info.wide,
        .rt = rt,
    };
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
        return;
    }

    var leaf: ?JSValue = owned_leaf;
    var accumulated: ?JSValue = null;

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
        return addRopeRebalanceLeaf(rt, buckets, value);
    };
    if (node.flatString()) |flat| {
        return addRopeRebalanceLeaf(rt, buckets, flat.value());
    }
    // A dependent view is an indivisible leaf: the buffer bytes past `len`
    // belong to a longer sibling view, so the rebalance must keep the node.
    if (node.buffer != null) {
        return addRopeRebalanceLeaf(rt, buckets, value);
    }

    try collectRopeRebalanceLeaves(rt, buckets, node.left);
    try collectRopeRebalanceLeaves(rt, buckets, node.right);
}

/// Returns a new balanced value without consuming `rope`. This is the Boehm,
/// Atkinson and Plass Fibonacci-bucket algorithm used by QuickJS
/// `js_rebalancee_string_rope`.
fn rebalanceRope(rt: *JSRuntime, rope: JSValue) !JSValue {
    var buckets: RopeBuckets = @splat(null);

    try collectRopeRebalanceLeaves(rt, &buckets, rope);

    var result: ?JSValue = null;
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

/// Total allocation size for a `StringRope` node: the padded metadata prefix
/// plus the node struct. The prefix is padded to the node's alignment so the
/// node lands aligned at `base + StringRope.metadata_prefix_size`.
const rope_node_alloc_size: usize = StringRope.metadata_prefix_size + @sizeOf(StringRope);

comptime {
    // The padded prefix must be a whole multiple of the node's alignment so the
    // struct that follows it stays aligned.
    std.debug.assert(StringRope.metadata_prefix_size % @alignOf(StringRope) == 0);
    std.debug.assert(StringRope.metadata_prefix_size == gc.string_prefix_size);
}

/// TGC S2-i: write `data` into `buf` starting at code-unit `offset`.
/// The destination width is the buffer's; a narrow source widens per unit,
/// and a wide source into a narrow buffer is impossible by construction (the
/// callers pick the buffer width from the OR of both operands).
fn writeTailUnits(buf: *StringBuffer, offset: u32, data: String.ResolvedData) void {
    if (std.debug.runtime_safety) {
        const meta = buf.header().metaConst();
        std.debug.assert(meta.flags.kind == .string_buffer);
        std.debug.assert(meta.alloc_info.heap_accounted);
        std.debug.assert(@as(usize, offset) + data.len() <= buf.capacity);
    }
    if (buf.is_wide) {
        const out = buf.utf16();
        switch (data) {
            .latin1 => |bytes| for (bytes, 0..) |byte, i| {
                out[offset + i] = byte;
            },
            .utf16 => |units| @memcpy(out[offset..][0..units.len], units),
        }
        return;
    }
    const out = buf.latin1();
    switch (data) {
        .latin1 => |bytes| @memcpy(out[offset..][0..bytes.len], bytes),
        .utf16 => unreachable,
    }
}

/// Seed capacity: 1.5x, not the growth path's 2x. The seed is the one
/// allocation an accumulator that never gets appended to again still pays,
/// and there are many of those (regexp's maxrss moved 139 MB -> 103 MB on
/// this constant alone). Amortization does not depend on it -- it is the
/// GROWTH factor that has to be geometric.
fn tailBufferSeedCapacityFor(total: usize) usize {
    const wanted = @max(total +| total / 2, String.tail_buffer_min_capacity);
    return @min(wanted, max_length);
}

/// Growth capacity: 2x, which is what makes a run of appends amortized O(1).
fn tailBufferCapacityFor(total: usize) usize {
    const doubled = total *| 2;
    const wanted = @max(doubled, String.tail_buffer_min_capacity);
    return @min(wanted, max_length);
}

/// TGC S2-i seed: `a ++ b` into a FRESH extensible tail buffer, returned as a
/// dependent view node. This still copies `a` once -- the amortization starts
/// with the next append, which writes only `b`'s units.
pub fn createTailBufferRope(rt: *JSRuntime, a: *String, b: *String) !*StringRope {
    const a_len = a.len();
    const total = try std.math.add(usize, a_len, b.len());
    if (total > max_length) return error.StringTooLong;
    const wide = a.isWide() or b.isWide();
    // Allocation may collect. `a`/`b` are native locals resolved by the
    // conservative scan, and nothing published names the buffer yet.
    const buf = try createStringBuffer(rt, wide, tailBufferSeedCapacityFor(total));
    writeTailUnits(buf, 0, a.resolveData());
    writeTailUnits(buf, @intCast(a_len), b.resolveData());
    const node = try allocRopeNode(rt);
    node.* = .{
        .left = JSValue.undefinedValue(),
        .right = JSValue.undefinedValue(),
        .rt = rt,
        .buffer = buf,
        .len = @intCast(total),
        .depth = 1,
        .wide = wide,
        .extensible = true,
    };
    return node;
}

/// TGC S2-i append: `view ++ b` where `view` is a dependent view node.
///
/// The in-place arm is the amortized-O(1) one: `b`'s units go into the shared
/// buffer past `view.len`, which no live view names, and the append right
/// moves to the new node. Every other case (right already taken, buffer full,
/// buffer too narrow) allocates a doubled buffer and copies the prefix -- and
/// leaves `view` untouched, which is what makes `r1 = s + x; r2 = s + y`
/// correct without a refcount.
pub fn appendTailBufferRope(rt: *JSRuntime, view: *StringRope, b: *String) !*StringRope {
    const buf = view.buffer.?;
    const used = view.len;
    const total = try std.math.add(usize, @as(usize, used), b.len());
    if (total > max_length) return error.StringTooLong;
    const wide = buf.is_wide or b.isWide();

    if (view.extensible and wide == buf.is_wide and total <= buf.capacity) {
        // Allocate first: a collection here still sees `view` extensible over
        // an unmodified buffer, so the operation is all-or-nothing.
        const node = try allocRopeNode(rt);
        // The allocation may have collected. Nothing the collector does may
        // move a view off its buffer, shorten it, or spend its append right:
        // those are mutator-only writes, and this is the one place that makes
        // them.
        std.debug.assert(view.buffer == buf and view.len == used and view.extensible);
        writeTailUnits(buf, used, b.resolveData());
        node.* = .{
            .left = JSValue.undefinedValue(),
            .right = JSValue.undefinedValue(),
            .rt = rt,
            .buffer = buf,
            .len = @intCast(total),
            .depth = 1,
            .wide = buf.is_wide,
            .extensible = true,
        };
        view.extensible = false;
        return node;
    }

    const next = try createStringBuffer(rt, wide, tailBufferCapacityFor(total));
    writeTailUnits(next, 0, buf.prefix(used));
    writeTailUnits(next, used, b.resolveData());
    const node = try allocRopeNode(rt);
    node.* = .{
        .left = JSValue.undefinedValue(),
        .right = JSValue.undefinedValue(),
        .rt = rt,
        .buffer = next,
        .len = @intCast(total),
        .depth = 1,
        .wide = wide,
        .extensible = true,
    };
    return node;
}

/// Allocates a `StringRope` node with its leading collector metadata.
fn allocRopeNode(rt: *JSRuntime) !*StringRope {
    // Ropes never take the extent route: the node fits a block cell.
    comptime std.debug.assert(gc_block_heap.canAllocCellSize(rope_node_alloc_size));
    // TGC S2-f (3): same allocation-threshold boundary as flat bodies (see
    // `String.createUninitialized`). Before the cell pointer is taken.
    rt.collectBeforeObjectAllocation(rope_node_alloc_size);
    const base = (try rt.memory.createStringCell(gc.representation.rope_kind_tag, rope_node_alloc_size)) orelse unreachable;
    const node: *StringRope = @ptrCast(@alignCast(base + StringRope.metadata_prefix_size));
    rt.gc.addInitializedWithSizeNoFail(@ptrCast(node), gc_block_heap.accountedBodyBytesForRequest(rope_node_alloc_size, StringRope.metadata_prefix_size).?);
    return node;
}

/// QJS caps rope depth at 60 and walks its tree without allocating. Do the
/// same here: the only possible failure during flattening is allocation of the
/// destination flat string itself. Each unlinearized zjs rope contributes
/// `left ++ right`.
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
    if (node.bufferView()) |view| {
        offset.* += copyResolvedUnits(T, out[offset.*..], view);
        return;
    }
    copyRopeValueContent(T, node.left, out, offset);
    copyRopeValueContent(T, node.right, out, offset);
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

const InlineAllocationLayout = struct {
    total_size: usize,
    allocation_alignment: std.mem.Alignment,
};

/// TGC S4-a (D-S4-1): the rope discriminator is a GC kind, not a borrowed
/// `mark` bit. `allocRopeNode` stamps it in the prefix the allocator writes.
pub inline fn metaIsRope(meta: *const gc.Metadata) bool {
    return meta.flags.kind == .rope;
}

/// Registry-side size query for a string-family carrier (TGC S2). `header`
/// is the body pointer the JSValue payload names (String or StringRope);
/// the prefix sits eight bytes before it.
pub fn accountedAllocationSizeFromHeader(header: *const gc.GCObjectHeader) usize {
    const meta: *const gc.Metadata = @ptrFromInt(@intFromPtr(header) - gc.string_prefix_size);
    const total = if (metaIsRope(meta)) blk: {
        break :blk rope_node_alloc_size;
    } else blk: {
        const body: *const String = @ptrCast(@alignCast(header));
        const layout = if (body.len_meta.is_wide)
            inlineAllocationLayout(.utf16, body.len_meta.len) orelse unreachable
        else
            inlineAllocationLayout(.latin1, body.len_meta.len) orelse unreachable;
        break :blk layout.total_size;
    };
    if (gc.Registry.isBlockCellHeader(header)) {
        return gc_block_heap.accountedBodyBytesForRequest(total, gc.string_prefix_size).?;
    }
    return total - gc.string_prefix_size;
}

/// Sweep-time death of a condemned string-family BLOCK CELL (TGC S2 §5.7
/// "sweep dispatch"). `header` is the body pointer (cell base + 8, the same
/// convention `traceStringEdges` uses); the prefix at `header - 8` tells a
/// rope from a flat body. Nothing here touches a refcount and nothing calls
/// `JSValue.free`: a rope's `left`/`right` are traced values the sweep
/// reclaims on their own, and only an atom-table entry needs an explicit
/// hand-off before a flat symbol body's cell goes back.
pub fn destroyCellFromHeader(rt: *JSRuntime, header: *gc.GCObjectHeader) void {
    std.debug.assert(gc.Registry.isBlockCellHeader(header));
    const meta: *const gc.Metadata = @ptrFromInt(@intFromPtr(header) - gc.string_prefix_size);
    if (meta.flags.kind == .string_buffer) {
        destroyStringBufferCell(rt, header);
        return;
    }
    // TGC S4-b/S4-c: teardown walks this funnel over every PREFIX CARRIER,
    // which now includes the property/array storage cells and the a-class
    // payload cells. They are pure memory. A missing arm here does not merely
    // leak -- the flat-body arm below would read a payload's bytes as a
    // `String` -- so the set must stay exactly `kindIsPrefixCarrier` minus the
    // string family.
    if (meta.flags.kind == .property_storage or
        meta.flags.kind == .array_storage or
        meta.flags.kind == .payload)
    {
        rt.gc.destroyStorageCell(header);
        return;
    }
    if (metaIsRope(meta)) {
        const node: *StringRope = @ptrCast(@alignCast(header));
        rt.gc.unpublishStringCell(header, gc_block_heap.accountedBodyBytesForRequest(rope_node_alloc_size, StringRope.metadata_prefix_size).?);
        rt.memory.destroyStringCell(node, rope_node_alloc_size);
        return;
    }
    const body: *String = @ptrCast(@alignCast(header));
    // Bodies carry a dynamic atom id: the table must stop naming the body
    // before its memory is recycled. TGC S3-c made the two kinds differ --
    // a string atom's `str` is a droppable cache (the handshake just unbinds
    // it), a value symbol's body IS the entry's identity (the handshake
    // retires or weakens the entry).
    const atom_id = body.atom_id;
    if (atom_id != String.no_atom_id and !atom_mod.isConst(atom_id) and !atom_mod.isTaggedInt(atom_id)) {
        rt.atoms.onSymbolBodyDead(atom_id, body);
    }
    const layout = if (body.len_meta.is_wide)
        inlineAllocationLayout(.utf16, body.len_meta.len) orelse unreachable
    else
        inlineAllocationLayout(.latin1, body.len_meta.len) orelse unreachable;
    rt.gc.unpublishStringCell(header, gc_block_heap.accountedBodyBytesForRequest(layout.total_size, gc.string_prefix_size).?);
    rt.memory.destroyStringCell(body, layout.total_size);
}

/// TGC S2 extent sweep (spec §5.7): destroy every string extent the major
/// did not mark. The collector calls this after the bitmap sweep (the block
/// cells' twin is `destroyCellFromHeader`); returns the count destroyed.
/// Runtime teardown twin of the sweep: every remaining string cell and
/// extent is dead by definition. Cells are collected first so freeing does
/// not disturb the bitmap walk.
pub fn destroyAllStringCarriersForDeinit(rt: *JSRuntime) void {
    var cells = std.ArrayList(*gc.GCObjectHeader).empty;
    defer cells.deinit(std.heap.page_allocator);
    // One reservation for the whole live string population is the common
    // path; the walk below then appends into reserved memory and never
    // allocates. Teardown must not abort on a failed reservation, so the
    // fallback is a slower shape of the same work rather than a `@panic`:
    // destroy what was recorded plus the one cell that did not fit, then
    // restart the walk over a strictly smaller population. Progress is at
    // least one cell per pass, so this terminates with zero spare memory.
    cells.ensureTotalCapacity(std.heap.page_allocator, rt.gc.liveCountKind(.string) +
        rt.gc.liveCountKind(.rope) + rt.gc.liveCountKind(.string_buffer) +
        rt.gc.liveCountKind(.property_storage) + rt.gc.liveCountKind(.array_storage) +
        rt.gc.liveCountKind(.payload)) catch {};
    while (true) {
        cells.clearRetainingCapacity();
        var overflow: ?*gc.GCObjectHeader = null;
        var it = rt.gc.objectIterator(.all);
        while (it.next()) |header| {
            if (!gc.kindIsPrefixCarrier(header.metaConst().flags.kind)) continue;
            if (!gc.Registry.isBlockCellHeader(header)) continue;
            cells.append(std.heap.page_allocator, header) catch {
                // The iterator is abandoned here, so destroying out of the
                // walk cannot disturb it.
                overflow = header;
                break;
            };
        }
        for (cells.items) |header| destroyCellFromHeader(rt, header);
        const pending = overflow orelse break;
        destroyCellFromHeader(rt, pending);
    }
    const heap = &rt.gc.block_heap;
    // Major epochs are even; the next one matches no recorded extent mark.
    _ = heap.sweepExtents(heap.mark_epoch +% 2, @ptrCast(rt), destroyDeadStringExtent);
}

pub fn sweepExtents(rt: *JSRuntime) usize {
    const heap = &rt.gc.block_heap;
    return heap.sweepExtents(heap.mark_epoch, @ptrCast(rt), destroyDeadStringExtent);
}

/// Minor twin of `sweepExtents` (spec 7.2 (2)): destroy every extent in
/// the heap's young list the minor did not mark. Sound for the same reason
/// the young cell sweep is: an old object's write to a young extent is in the
/// remembered set (`generationalBarrierValue`; `cycleMarkHeader` accepts the
/// string tags), the minor force-traces every remembered owner, and an extent
/// has no out-edges of its own -- ropes always fit a cell.
pub fn sweepYoungExtents(rt: *JSRuntime) usize {
    const heap = &rt.gc.block_heap;
    return heap.sweepYoungExtents(heap.mark_epoch, @ptrCast(rt), destroyDeadStringExtent);
}

/// `Heap.sweepExtents` callback: the same handshake a condemned flat
/// cell performs, then the registry unpublish and the memory return.
/// `base` is the allocation start (prefix), `user_bytes` the request.
fn destroyDeadStringExtent(ctx: *anyopaque, base: usize, user_bytes: usize, needs_finalizer: bool) void {
    const rt: *JSRuntime = @ptrCast(@alignCast(ctx));
    const meta: *const gc.Metadata = @ptrFromInt(base);
    // TGC S4-d spec 2.4: the table row already answered "does this death owe
    // anything?". Only a string body bound to a DYNAMIC atom ever sets it, so
    // an unstamped extent skips the kind dispatch and the atom probe outright.
    if (!needs_finalizer) {
        const plain: *gc.GCObjectHeader = @ptrFromInt(base + gc.string_prefix_size);
        rt.gc.unpublishStringExtent(plain, user_bytes - gc.string_prefix_size);
        rt.memory.destroyStringExtent(plain, user_bytes);
        return;
    }
    // TGC S4 spec 2.2 "destroy_by_kind": the extent tables hold every prefix
    // carrier over the cell ceiling, so the callback dispatches. Ropes always
    // fit a cell (`allocRopeNode` asserts it at comptime), so the two live
    // answers are a flat body (atom handshake) and a tail buffer (pure
    // memory).
    std.debug.assert(meta.alloc_info.standalone);
    if (meta.flags.kind == .string_buffer or
        meta.flags.kind == .property_storage or
        meta.flags.kind == .array_storage or
        meta.flags.kind == .payload)
    {
        // TGC S2-i tail buffer, the TGC S4-b storage cells and the TGC S4-c
        // payload cells share one answer: unpublish, then hand the mapping
        // back. None owns an atom entry, an edge or an external resource, and
        // `user_bytes` from the extent table is the only size record a bare
        // carrier has. (An a-class payload STRUCT always fits a block cell;
        // the extent route is reachable through the subordinate slices --
        // a bound-argument array or reaction list past the 3760B ceiling.)
        const body: *gc.GCObjectHeader = @ptrFromInt(base + gc.string_prefix_size);
        rt.gc.unpublishStringExtent(body, user_bytes - gc.string_prefix_size);
        rt.memory.destroyStringExtent(body, user_bytes);
        return;
    }
    std.debug.assert(meta.flags.kind == .string);
    const header: *gc.GCObjectHeader = @ptrFromInt(base + gc.string_prefix_size);
    const body: *String = @ptrCast(@alignCast(header));
    std.debug.assert(accountedAllocationSizeFromHeader(header) == user_bytes - gc.string_prefix_size);
    // Symbol-body handshake: a dynamic atom whose body just died must drop
    // or weaken its entry (spec §5.7 atom ownership rule). Const and
    // tagged-int ids have no entry to tell.
    const atom_id = body.atom_id;
    if (atom_id != String.no_atom_id and !atom_mod.isConst(atom_id) and !atom_mod.isTaggedInt(atom_id)) {
        rt.atoms.onSymbolBodyDead(atom_id, body);
    }
    rt.gc.unpublishStringExtent(header, user_bytes - gc.string_prefix_size);
    rt.memory.destroyStringExtent(body, user_bytes);
}

/// Child edges of a rope node: `left`/`right`. Flat bodies are leaves and
/// never reach here -- `traceHeaderEdges` dispatches on the `.rope` kind
/// (TGC S4-a) instead of re-reading the prefix discriminator.
pub fn traceRopeEdges(rt: *JSRuntime, visitor: anytype, header: *gc.GCObjectHeader) !void {
    _ = rt;
    std.debug.assert(metaIsRope(@ptrFromInt(@intFromPtr(header) - gc.string_prefix_size)));
    const node: *StringRope = @ptrCast(@alignCast(header));
    // TGC S2-i: the tail buffer is a storage cell with no edges of its own;
    // every view that can still read it reports it here. A view's
    // `left`/`right` are undefined VALUES (not garbage pointers), so the two
    // visits below stay unconditional and branch-free.
    if (node.buffer) |buf| {
        std.debug.assert(buf.header().metaConst().flags.kind == .string_buffer);
        try callVisitStorageCell(visitor, buf.header());
    }
    try callVisitValue(visitor, &node.left);
    try callVisitValue(visitor, &node.right);
}

/// Visitor shim for the storage-cell edge (TGC S4 spec 2.2). Visitors that
/// do not declare `storageCell` -- the root adaptors, which never enumerate
/// heap edges -- compile this away entirely.
inline fn callVisitStorageCell(vis: anytype, header: *gc.GCObjectHeader) !void {
    const VisType = @TypeOf(vis);
    const CleanType = comptime if (@typeInfo(VisType) == .pointer) @typeInfo(VisType).pointer.child else VisType;
    if (comptime !@hasDecl(CleanType, "storageCell")) return;
    const ReturnType = @typeInfo(@TypeOf(CleanType.storageCell)).@"fn".return_type.?;
    if (comptime @typeInfo(ReturnType) == .error_union) {
        try vis.storageCell(header);
    } else {
        vis.storageCell(header);
    }
}

/// Visitors come in two shapes (`visitValue` returning void or an error
/// union); mirror shape.zig's helper so one trace body serves both.
inline fn callVisitValue(vis: anytype, slot: *JSValue) !void {
    const VisType = @TypeOf(vis);
    const CleanType = comptime if (@typeInfo(VisType) == .pointer) @typeInfo(VisType).pointer.child else VisType;
    const ReturnType = @typeInfo(@TypeOf(CleanType.visitValue)).@"fn".return_type.?;
    if (comptime @typeInfo(ReturnType) == .error_union) {
        try vis.visitValue(slot);
    } else {
        vis.visitValue(slot);
    }
}

fn inlineAllocationLayout(comptime tag: String.StorageTag, unit_count: usize) ?InlineAllocationLayout {
    const unit_size = switch (tag) {
        .latin1 => @sizeOf(u8),
        .utf16 => @sizeOf(u16),
    };
    // The allocation base carries the Metadata prefix, so it is 8-aligned;
    // that covers `String` (4) and the u16 FAM.
    const string_alignment = std.mem.Alignment.of(gc.Metadata);
    const payload_units = switch (tag) {
        // latin1 keeps a trailing NUL terminator (qjs `str8` is NUL-terminated).
        .latin1 => finalLatin1AllocationLen(unit_count) orelse return null,
        .utf16 => unit_count,
    };
    const payload_size = std.math.mul(usize, unit_size, payload_units) catch return null;
    // Layout: [Metadata prefix (8B)] [String struct] [char FAM]. `payload_offset`
    // is measured from the struct base to the FAM; the allocation additionally
    // carries the leading prefix, so the total starts with it.
    const struct_and_payload = std.math.add(usize, payload_offset, payload_size) catch return null;
    const total_size = std.math.add(usize, gc.string_prefix_size, struct_and_payload) catch return null;
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
    const latin_b = try String.createUtf8(rt, "abd");
    try std.testing.expectEqual(@as(i32, 0), latin_a.compare(latin_a));
    try std.testing.expect(latin_a.compare(latin_b) < 0);

    const wide_a = try String.createUtf16(rt, &.{0x0100});
    const wide_b = try String.createUtf16(rt, &.{ 0x00ff, 0x0100 });
    try std.testing.expect(wide_a.compare(wide_b) > 0);

    const wide_parent = try String.createUtf16(rt, &.{ 0x0100, 'a' });
    const wide_slice = try String.createSlice(rt, wide_parent, 1, 1);
    const latin_single = try String.createUtf8(rt, "a");
    try std.testing.expectEqual(@as(i32, 0), latin_single.compare(wide_slice));
}

test "flatStringsEqNear matches js_string_eq on same-width flats" {
    const rt = try JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const a = try String.createUtf8(rt, "k0");
    const b = try String.createUtf8(rt, "k0");
    const c = try String.createUtf8(rt, "k32");
    const empty_a = try String.createUtf8(rt, "");
    const empty_b = try String.createUtf8(rt, "");
    const wide_a = try String.createUtf16(rt, &[_]u16{ 0x3b1, 0x3b2 });
    const wide_b = try String.createUtf16(rt, &[_]u16{ 0x3b1, 0x3b2 });
    const wide_c = try String.createUtf16(rt, &[_]u16{ 0x3b1, 0x3b3 });

    try std.testing.expectEqual(true, flatStringsEqNear(a, a).?);
    try std.testing.expectEqual(true, flatStringsEqNear(a, b).?);
    try std.testing.expectEqual(false, flatStringsEqNear(a, c).?);
    try std.testing.expectEqual(true, flatStringsEqNear(empty_a, empty_b).?);
    try std.testing.expectEqual(true, flatStringsEqNear(wide_a, wide_b).?);
    try std.testing.expectEqual(false, flatStringsEqNear(wide_a, wide_c).?);
    try std.testing.expect(flatStringsEq(a, b));
    try std.testing.expect(!flatStringsEq(a, c));
}

test "string compare short-circuits equal interned atom ids" {
    const rt = try JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const first = try String.createUtf8(rt, "length");
    const first_atom = try first.internAtom(rt);

    const second = try String.createUtf8(rt, "length");
    const second_atom = try second.internAtom(rt);

    try std.testing.expectEqual(first_atom, second_atom);
    try std.testing.expect(first != second);
    try std.testing.expectEqual(@as(i32, 0), first.compare(second));
}

const std = @import("std");

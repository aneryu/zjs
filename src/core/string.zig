const atom_mod = @import("atom.zig");
const gc = @import("gc.zig");
const unicode = @import("../libs/unicode.zig");
const JSRuntime = @import("runtime.zig").JSRuntime;
const JSValue = @import("value.zig").JSValue;

pub const StringError = error{
    InvalidUtf8,
};

pub const Data = union(enum) {
    latin1: []u8,
    utf16: []u16,
    slice: struct {
        parent: *String,
        start: u32,
        len: u32,
    },
    rope: *Rope,

    pub fn len(self: Data) usize {
        return switch (self) {
            .latin1 => |bytes| bytes.len,
            .utf16 => |units| units.len,
            .slice => |s| s.len,
            .rope => |node| node.len,
        };
    }
    pub fn isWide(self: Data) bool {
        return switch (self) {
            .latin1 => false,
            .utf16 => true,
            .slice => |s| s.parent.data.isWide(),
            .rope => |node| node.wide,
        };
    }
};

/// Deferred concatenation node (QuickJS `JSStringRope` analogue). A rope-backed
/// `String` keeps `data = .rope` for its whole lifetime; the first content read
/// materializes the flat buffer into `flat` (and releases the children), so all
/// borrowed slices stay valid for as long as the owning `String` is alive.
pub const Rope = struct {
    left: *String,
    right: *String,
    /// Total length in code units, including the tail buffer's used units.
    len: usize,
    wide: bool,
    rt: *JSRuntime,
    hash: u32 = 0,
    hash_ready: bool = false,
    flat: FlatCache = .none,
    /// Growable private append buffer so `s += x` loops extend the rope in
    /// place instead of chaining one ~150-byte node per concatenation.
    /// Logically the tail's content sits after `right`. The slices keep the
    /// full allocated capacity; `tail_len` is the used unit count. Flattening
    /// merges the tail into `flat` and releases it, so a materialized rope
    /// never carries a tail.
    tail: Tail = .none,
    tail_len: usize = 0,
    /// Intrusive link used only by the iterative destroy path so arbitrarily
    /// deep rope chains never recurse.
    chain_next: ?*String = null,

    pub const FlatCache = union(enum) {
        none,
        latin1: []u8,
        utf16: []u16,
    };

    pub const Tail = union(enum) {
        none,
        latin1: []u8,
        utf16: []u16,
    };

    fn tailResolved(self: *const Rope) ?String.ResolvedData {
        return switch (self.tail) {
            .none => null,
            .latin1 => |buf| .{ .latin1 = buf[0..self.tail_len] },
            .utf16 => |buf| .{ .utf16 = buf[0..self.tail_len] },
        };
    }
};

pub const Layout = enum(u8) {
    compact,
    separate,
    slice,
};

pub fn isAsciiBytes(bytes: []const u8) bool {
    for (bytes) |byte| {
        if (byte >= 0x80) return false;
    }
    return true;
}

pub const String = struct {
    pub const no_atom_id: u32 = std.math.maxInt(u32);

    header: gc.StringHeader,
    data: Data,
    layout: Layout,
    capacity: u32,
    hash: u32,
    hash_ready: bool = false,
    atom_id: u32 = no_atom_id,
    /// Set once a string becomes a rope child. Rope nodes snapshot their
    /// children's content, so in-place appends must be refused from then on.
    rope_child: bool = false,

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
            errdefer destroyUninitialized(rt, self);
            _ = try decodeUtf8(bytes, self.data.latin1, null);
            writeLatin1Terminator(self.data.latin1);
            return self;
        }

        const self = try createUninitialized(rt, .utf16, plan.units);
        errdefer destroyUninitialized(rt, self);
        _ = try decodeUtf8(bytes, null, self.data.utf16);
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
            errdefer destroyUninitialized(rt, self);
            for (units, 0..) |unit, i| self.data.latin1[i] = @intCast(unit);
            writeLatin1Terminator(self.data.latin1);
            return self;
        }

        const self = try createUninitialized(rt, .utf16, units.len);
        errdefer destroyUninitialized(rt, self);
        @memcpy(self.data.utf16, units);
        return self;
    }

    pub fn createUtf16Owned(rt: *JSRuntime, units: []u16, capacity: usize) !*String {
        std.debug.assert(capacity >= units.len);
        var needs_wide = false;
        for (units) |unit| {
            if (unit > 0xff) {
                needs_wide = true;
                break;
            }
        }

        if (!needs_wide) {
            const self = try createUninitialized(rt, .latin1, units.len);
            errdefer destroyUninitialized(rt, self);
            for (units, 0..) |unit, i| self.data.latin1[i] = @intCast(unit);
            writeLatin1Terminator(self.data.latin1);
            rt.memory.free(u16, units.ptr[0..capacity]);
            return self;
        }

        const self = try rt.createRuntime(String);
        self.* = .{
            .header = .{},
            .data = .{ .utf16 = units },
            .layout = .separate,
            .capacity = @intCast(capacity),
            .hash = 0,
        };
        return self;
    }

    pub fn createUtf16Pair(rt: *JSRuntime, first: u16, second: u16) !*String {
        if (first <= 0xff and second <= 0xff) {
            const self = try createUninitialized(rt, .latin1, 2);
            errdefer destroyUninitialized(rt, self);
            self.data.latin1[0] = @intCast(first);
            self.data.latin1[1] = @intCast(second);
            writeLatin1Terminator(self.data.latin1);
            return self;
        }

        const self = try createUninitialized(rt, .utf16, 2);
        errdefer destroyUninitialized(rt, self);
        self.data.utf16[0] = first;
        self.data.utf16[1] = second;
        return self;
    }

    pub fn createSymbolNoDescription(rt: *JSRuntime) !*String {
        return createUninitialized(rt, .utf16, 0);
    }

    pub fn isSymbolNoDescription(self: String) bool {
        return self.data.len() == 0 and self.data.isWide();
    }

    pub fn createAtomBacked(rt: *JSRuntime, atom_id: u32) !*String {
        // Atom-table cache hit: hand out one more reference to the string
        // already materialized for this atom, skipping the UTF-8 decode.
        if (rt.atoms.cachedString(atom_id)) |cached| {
            gc.retain(&cached.header);
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
        _ = self.contentHash();
        if (self.atom_id != no_atom_id) return rt.atoms.dup(self.atom_id);
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
        return createLatin1ConcatGrowable(rt, a, b);
    }

    pub fn createLatin1ConcatWithSeed(rt: *JSRuntime, a: []const u8, b: []const u8, seed: u32) !*String {
        _ = seed;
        const total = a.len + b.len;
        const self = try createUninitialized(rt, .latin1, total);
        errdefer destroyUninitialized(rt, self);
        @memcpy(self.data.latin1[0..a.len], a);
        @memcpy(self.data.latin1[a.len..], b);
        writeLatin1Terminator(self.data.latin1);
        return self;
    }

    fn createLatin1ConcatGrowable(rt: *JSRuntime, a: []const u8, b: []const u8) !*String {
        const total = a.len + b.len;
        const capacity = nextStringCapacity(0, total);
        const self = try createInlineUninitialized(rt, .latin1, total, capacity);
        errdefer destroyUninitialized(rt, self);
        @memcpy(self.data.latin1[0..a.len], a);
        @memcpy(self.data.latin1[a.len..], b);
        writeLatin1Terminator(self.data.latin1);
        return self;
    }

    pub fn createLatin1RepeatedConcatWithSeed(rt: *JSRuntime, a: []const u8, suffix: []const u8, repeat_count: usize, seed: u32) !*String {
        _ = seed;
        const append_len = try std.math.mul(usize, suffix.len, repeat_count);
        const total = try std.math.add(usize, a.len, append_len);
        const self = try createUninitialized(rt, .latin1, total);
        errdefer destroyUninitialized(rt, self);
        @memcpy(self.data.latin1[0..a.len], a);
        if (suffix.len == 1) {
            @memset(self.data.latin1[a.len..total], suffix[0]);
        } else {
            var offset = a.len;
            var remaining = repeat_count;
            while (remaining != 0) : (remaining -= 1) {
                @memcpy(self.data.latin1[offset..][0..suffix.len], suffix);
                offset += suffix.len;
            }
        }
        writeLatin1Terminator(self.data.latin1);
        return self;
    }

    /// Concatenate two utf16 unit buffers into a single freshly allocated
    /// utf16 string. The runtime owns the result.
    pub fn createUtf16Concat(rt: *JSRuntime, a: []const u16, b: []const u16) !*String {
        return createUtf16ConcatGrowable(rt, a, b);
    }

    pub fn createUtf16ConcatWithSeed(rt: *JSRuntime, a: []const u16, b: []const u16, seed: u32) !*String {
        _ = seed;
        const total = a.len + b.len;
        const self = try createUninitialized(rt, .utf16, total);
        errdefer destroyUninitialized(rt, self);
        @memcpy(self.data.utf16[0..a.len], a);
        @memcpy(self.data.utf16[a.len..], b);
        return self;
    }

    fn createUtf16ConcatGrowable(rt: *JSRuntime, a: []const u16, b: []const u16) !*String {
        const total = a.len + b.len;
        const capacity = nextStringCapacity(0, total);
        const self = try createInlineUninitialized(rt, .utf16, total, capacity);
        errdefer destroyUninitialized(rt, self);
        @memcpy(self.data.utf16[0..a.len], a);
        @memcpy(self.data.utf16[a.len..], b);
        return self;
    }

    pub fn createLatin1(rt: *JSRuntime, bytes: []const u8) !*String {
        const self = try createUninitialized(rt, .latin1, bytes.len);
        errdefer destroyUninitialized(rt, self);
        @memcpy(self.data.latin1, bytes);
        writeLatin1Terminator(self.data.latin1);
        return self;
    }

    /// Minimum combined length (in code units) for the `+` operator to defer
    /// concatenation through a rope instead of copying eagerly.
    pub const rope_min_len: usize = 256;

    /// Creates a rope string deferring the concatenation of `left ++ right`.
    /// Retains both children; content is materialized lazily on first read.
    pub fn createRope(rt: *JSRuntime, left: *String, right: *String) !*String {
        const total = try std.math.add(usize, left.len(), right.len());
        const node = try rt.createRuntime(Rope);
        errdefer rt.memory.destroy(Rope, node);
        const self = try rt.createRuntime(String);
        node.* = .{
            .left = left,
            .right = right,
            .len = total,
            .wide = left.isWide() or right.isWide(),
            .rt = rt,
        };
        self.* = .{
            .header = .{},
            .data = .{ .rope = node },
            .layout = .separate,
            .capacity = 0,
            .hash = 0,
        };
        left.retain();
        right.retain();
        left.rope_child = true;
        right.rope_child = true;
        return self;
    }

    pub fn isRope(self: *const String) bool {
        return self.data == .rope;
    }

    /// Appends flat content to a not-yet-materialized rope by extending the
    /// rope's private tail buffer (amortized doubling) instead of chaining a
    /// new rope node per concatenation. Returns false when the caller must
    /// keep the regular new-node linking: non-rope backing, materialized
    /// `flat` cache, or an append-protected wrapper (rope child /
    /// atom-bound). Aliasing is the caller's contract, exactly like the flat
    /// `append*InPlace` family (reference-count accounting at the call site).
    /// On allocation failure the rope is left untouched.
    pub fn appendRopeTail(self: *String, rt: *JSRuntime, suffix: ResolvedData) !bool {
        if (self.atom_id != no_atom_id or self.rope_child) return false;
        if (self.data != .rope) return false;
        const node = self.data.rope;
        std.debug.assert(node.rt == rt);
        if (node.flat != .none) return false;
        // Tail appends happen strictly before flattening. A demanded rope hash
        // flattens first, so this in-place mutation cannot leave a live hash
        // cache stale.
        std.debug.assert(!node.hash_ready);
        std.debug.assert(!self.hash_ready);
        const add_len = suffix.len();
        if (add_len == 0) return true;
        const new_total = checkedAddLength(node.len, add_len) orelse return false;
        const used = node.tail_len;
        const need = checkedAddLength(used, add_len) orelse return false;

        const widen_tail = switch (node.tail) {
            .none, .latin1 => suffix == .utf16,
            .utf16 => true,
        };
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
        node.tail_len = need;
        node.len = new_total;
        return true;
    }

    /// Content hash usable for hashing string values regardless of rope state.
    /// Computed lazily and cached on first demand. Rope-backed strings flatten
    /// first so equal contents hash equally without hashing at rope creation or
    /// flatten time.
    pub fn contentHash(self: *const String) u32 {
        if (self.data == .rope) {
            _ = self.resolveData();
            const node = self.data.rope;
            if (!node.hash_ready) {
                node.hash = switch (node.flat) {
                    .latin1 => |buf| hashLatin1(buf, 0),
                    .utf16 => |buf| hashUtf16(buf, 0),
                    .none => unreachable,
                };
                node.hash_ready = true;
            }
            return node.hash;
        }
        if (!self.hash_ready) {
            const mutable = @constCast(self);
            mutable.hash = switch (self.resolveData()) {
                .latin1 => |bytes| hashLatin1(bytes, 0),
                .utf16 => |units| hashUtf16(units, 0),
            };
            mutable.hash_ready = true;
        }
        return self.hash;
    }

    pub fn value(self: *String) JSValue {
        return JSValue.string(&self.header);
    }

    pub inline fn retain(self: *String) void {
        self.header.retain();
    }

    pub fn releaseFromHeader(rt: *JSRuntime, header: *gc.StringHeader) void {
        std.debug.assert(header.rc > 0);
        header.rc -= 1;
        rt.gc.stats.rc_dec += 1;
        if (header.rc == 0) destroyFromHeader(rt, header);
    }

    pub fn len(self: String) usize {
        return self.data.len();
    }

    pub fn isWide(self: String) bool {
        return self.data.isWide();
    }

    pub fn eqlBytes(self: String, bytes: []const u8) bool {
        return switch (self.resolveData()) {
            .latin1 => |latin1| std.mem.eql(u8, latin1, bytes),
            .utf16 => |utf16| eqlUtf16Latin1(utf16, bytes),
        };
    }

    pub fn eqlString(self: String, other: String) bool {
        return compare(self, other) == 0;
    }

    pub fn compare(self: String, other: String) i32 {
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

    /// Materializes rope-backed content (including ropes reached through a
    /// slice parent chain) so subsequent `resolveData` reads are
    /// allocation-free. Already-flat strings return at zero cost. Unlike the
    /// infallible `resolveData` path, allocation failure propagates to the
    /// caller instead of panicking, so fallible read paths can surface OOM
    /// as a regular error.
    pub fn ensureFlat(self: *String, rt: *JSRuntime) !void {
        var cursor: *const String = self;
        while (cursor.data == .slice) cursor = cursor.data.slice.parent;
        switch (cursor.data) {
            .rope => |node| {
                std.debug.assert(node.rt == rt);
                try flattenRopeNodeFallible(node);
            },
            else => {},
        }
    }

    pub fn resolveData(self: *const String) ResolvedData {
        switch (self.data) {
            .latin1 => |latin1| return .{ .latin1 = latin1 },
            .utf16 => |utf16| return .{ .utf16 = utf16 },
            .rope => |node| return flattenedRopeData(self, node),
            .slice => {},
        }
        var cursor = self;
        var offset: usize = 0;
        const total_len = self.data.len();
        while (cursor.data == .slice) {
            const s = cursor.data.slice;
            offset += s.start;
            cursor = s.parent;
        }
        return switch (cursor.data) {
            .latin1 => |bytes| .{ .latin1 = bytes[offset .. offset + total_len] },
            .utf16 => |units| .{ .utf16 = units[offset .. offset + total_len] },
            .rope => |node| switch (flattenedRopeData(cursor, node)) {
                .latin1 => |bytes| .{ .latin1 = bytes[offset .. offset + total_len] },
                .utf16 => |units| .{ .utf16 = units[offset .. offset + total_len] },
            },
            .slice => unreachable,
        };
    }

    pub fn borrowLatin1(self: *const String) ?[]const u8 {
        const resolved = self.resolveData();
        return if (resolved == .latin1) resolved.latin1 else null;
    }

    pub fn codeUnitAt(self: String, index: usize) u16 {
        const resolved = self.resolveData();
        return switch (resolved) {
            .latin1 => |bytes| bytes[index],
            .utf16 => |units| units[index],
        };
    }

    pub fn createSlice(rt: *JSRuntime, parent: *String, start: usize, slice_len: usize) !*String {
        if (slice_len == 0) return try createAscii(rt, "");
        const self = try rt.createRuntime(String);
        errdefer rt.memory.destroy(String, self);
        self.header = .{};
        self.hash = 0;
        self.hash_ready = false;
        self.atom_id = no_atom_id;
        self.rope_child = false;
        self.layout = .slice;
        self.capacity = 0;
        self.data = .{ .slice = .{ .parent = parent, .start = @intCast(start), .len = @intCast(slice_len) } };
        parent.retain();
        return self;
    }

    pub fn appendLatin1InPlace(self: *String, rt: *JSRuntime, suffix: []const u8) !bool {
        if (self.atom_id != no_atom_id or self.rope_child) return false;
        if (suffix.len == 0) return true;
        const bytes = switch (self.data) {
            .latin1 => |bytes| bytes,
            .utf16, .slice, .rope => return false,
        };
        const old_len = bytes.len;
        const new_len = old_len + suffix.len;
        if (new_len <= self.capacity) {
            const expanded = bytes.ptr[0..new_len];
            @memcpy(expanded[old_len..new_len], suffix);
            writeLatin1Terminator(expanded);
            self.data = .{ .latin1 = expanded };
            if (self.hash_ready) self.hash = hashLatin1(suffix, self.hash);
            return true;
        }
        if (self.layout != .separate) return false;

        var next_capacity = if (self.capacity == 0) @as(usize, 16) else self.capacity;
        while (next_capacity < new_len) {
            next_capacity = next_capacity * 2;
        }
        const expanded_allocation = try allocFinalLatin1Buffer(rt, next_capacity);
        errdefer rt.memory.free(u8, expanded_allocation);
        const expanded = expanded_allocation[0..new_len];
        @memcpy(expanded[0..old_len], bytes);
        @memcpy(expanded[old_len..new_len], suffix);
        writeLatin1Terminator(expanded);
        const old_bytes = finalLatin1Allocation(bytes, self.capacity);
        self.data = .{ .latin1 = expanded };
        self.capacity = @intCast(next_capacity);
        if (self.hash_ready) self.hash = hashLatin1(suffix, self.hash);
        rt.memory.free(u8, old_bytes);
        return true;
    }

    pub fn appendUtf16InPlace(self: *String, rt: *JSRuntime, suffix: []const u16) !bool {
        if (self.atom_id != no_atom_id or self.rope_child) return false;
        if (suffix.len == 0) return true;
        const units = switch (self.data) {
            .latin1, .slice, .rope => return false,
            .utf16 => |units| units,
        };
        const old_len = units.len;
        const new_len = checkedAddLength(old_len, suffix.len) orelse return false;
        if (new_len <= self.capacity) {
            const expanded = units.ptr[0..new_len];
            @memcpy(expanded[old_len..new_len], suffix);
            self.data = .{ .utf16 = expanded };
            if (self.hash_ready) self.hash = hashUtf16(suffix, self.hash);
            return true;
        }
        if (self.layout != .separate) return false;

        const next_capacity = nextStringCapacity(self.capacity, new_len);
        const expanded = try rt.allocRuntime(u16, next_capacity);
        errdefer rt.memory.free(u16, expanded);
        @memcpy(expanded[0..old_len], units);
        @memcpy(expanded[old_len..new_len], suffix);
        const old_units = units.ptr[0..self.capacity];
        self.data = .{ .utf16 = expanded[0..new_len] };
        self.capacity = @intCast(next_capacity);
        if (self.hash_ready) self.hash = hashUtf16(suffix, self.hash);
        rt.memory.free(u16, old_units);
        return true;
    }

    pub fn appendLatin1ToUtf16InPlace(self: *String, rt: *JSRuntime, suffix: []const u8) !bool {
        if (self.atom_id != no_atom_id or self.rope_child) return false;
        if (suffix.len == 0) return true;
        const units = switch (self.data) {
            .latin1, .slice, .rope => return false,
            .utf16 => |units| units,
        };
        const old_len = units.len;
        const new_len = checkedAddLength(old_len, suffix.len) orelse return false;
        if (new_len <= self.capacity) {
            const expanded = units.ptr[0..new_len];
            for (suffix, old_len..) |byte, index| expanded[index] = byte;
            self.data = .{ .utf16 = expanded };
            if (self.hash_ready) self.hash = hashLatin1(suffix, self.hash);
            return true;
        }
        if (self.layout != .separate) return false;

        const next_capacity = nextStringCapacity(self.capacity, new_len);
        const expanded = try rt.allocRuntime(u16, next_capacity);
        errdefer rt.memory.free(u16, expanded);
        @memcpy(expanded[0..old_len], units);
        for (suffix, old_len..) |byte, index| expanded[index] = byte;
        const old_units = units.ptr[0..self.capacity];
        self.data = .{ .utf16 = expanded[0..new_len] };
        self.capacity = @intCast(next_capacity);
        if (self.hash_ready) self.hash = hashLatin1(suffix, self.hash);
        rt.memory.free(u16, old_units);
        return true;
    }

    pub fn appendUtf16WidenInPlace(self: *String, rt: *JSRuntime, suffix: []const u16) !bool {
        if (self.atom_id != no_atom_id or self.rope_child) return false;
        if (suffix.len == 0) return true;
        const bytes = switch (self.data) {
            .latin1 => |bytes| bytes,
            .utf16, .slice, .rope => return false,
        };
        const old_len = bytes.len;
        const new_len = checkedAddLength(old_len, suffix.len) orelse return false;
        if (self.layout != .separate) return false;
        const next_capacity = nextStringCapacity(self.capacity, new_len);
        const expanded = try rt.allocRuntime(u16, next_capacity);
        errdefer rt.memory.free(u16, expanded);
        for (bytes, 0..) |byte, index| expanded[index] = byte;
        @memcpy(expanded[old_len..new_len], suffix);
        const old_bytes = finalLatin1Allocation(bytes, self.capacity);
        self.data = .{ .utf16 = expanded[0..new_len] };
        self.capacity = @intCast(next_capacity);
        if (self.hash_ready) self.hash = hashUtf16(suffix, self.hash);
        rt.memory.free(u8, old_bytes);
        return true;
    }

    pub fn appendLatin1RepeatedInPlace(self: *String, rt: *JSRuntime, suffix: []const u8, repeat_count: usize) !bool {
        if (self.atom_id != no_atom_id or self.rope_child) return false;
        if (repeat_count == 0 or suffix.len == 0) return true;
        const bytes = switch (self.data) {
            .latin1 => |bytes| bytes,
            .utf16, .slice, .rope => return false,
        };

        const append_len_result = @mulWithOverflow(suffix.len, repeat_count);
        if (append_len_result[1] != 0) return false;
        const append_len = append_len_result[0];
        const old_len = bytes.len;
        const new_len_result = @addWithOverflow(old_len, append_len);
        if (new_len_result[1] != 0) return false;
        const new_len = new_len_result[0];

        var expanded: []u8 = undefined;
        var old_bytes: []u8 = &.{};
        var next_capacity: usize = self.capacity;
        if (new_len <= self.capacity) {
            expanded = bytes.ptr[0..new_len];
        } else {
            if (self.layout != .separate) return false;
            next_capacity = if (self.capacity == 0) @as(usize, 16) else self.capacity;
            while (next_capacity < new_len) {
                const doubled = @mulWithOverflow(next_capacity, 2);
                next_capacity = if (doubled[1] == 0 and doubled[0] > next_capacity) doubled[0] else new_len;
            }
            const expanded_allocation = try allocFinalLatin1Buffer(rt, next_capacity);
            errdefer rt.memory.free(u8, expanded_allocation);
            expanded = expanded_allocation[0..new_len];
            @memcpy(expanded[0..old_len], bytes);
            old_bytes = finalLatin1Allocation(bytes, self.capacity);
        }

        if (suffix.len == 1) {
            @memset(expanded[old_len..new_len], suffix[0]);
        } else {
            var offset = old_len;
            var remaining = repeat_count;
            while (remaining != 0) : (remaining -= 1) {
                @memcpy(expanded[offset..][0..suffix.len], suffix);
                offset += suffix.len;
            }
        }
        writeLatin1Terminator(expanded);
        self.data = .{ .latin1 = expanded[0..new_len] };
        self.capacity = @intCast(next_capacity);
        if (self.hash_ready) {
            var remaining = repeat_count;
            while (remaining != 0) : (remaining -= 1) {
                self.hash = hashLatin1(suffix, self.hash);
            }
        }
        if (old_bytes.len != 0) rt.memory.free(u8, old_bytes);
        return true;
    }

    pub fn destroyFromHeader(rt: *JSRuntime, header: *gc.StringHeader) void {
        const self: *String = @alignCast(@fieldParentPtr("header", header));
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
        destroyUninitialized(rt, self);
    }

    pub fn destroyWeakSymbolBody(rt: *JSRuntime, self: *String) void {
        std.debug.assert(self.header.rc == 0);
        self.atom_id = no_atom_id;
        destroyUninitialized(rt, self);
    }

    fn createUninitialized(rt: *JSRuntime, comptime tag: std.meta.Tag(Data), unit_count: usize) !*String {
        return createInlineUninitialized(rt, tag, unit_count, unit_count);
    }

    fn createInlineUninitialized(rt: *JSRuntime, comptime tag: std.meta.Tag(Data), unit_count: usize, capacity: usize) !*String {
        std.debug.assert(capacity >= unit_count);
        const inline_layout = inlineAllocationLayout(tag, capacity) orelse return error.OutOfMemory;
        const bytes = try rt.allocRuntimeAlignedBytes(inline_layout.total_size, inline_layout.allocation_alignment);
        const self: *String = @ptrCast(@alignCast(bytes.ptr));
        self.header = .{};
        self.hash = 0;
        self.hash_ready = false;
        self.atom_id = no_atom_id;
        self.rope_child = false;
        self.layout = .compact;
        self.capacity = @intCast(capacity);
        switch (tag) {
            .latin1 => {
                const payload = bytes[inline_layout.payload_offset..];
                self.data = .{ .latin1 = payload.ptr[0..unit_count] };
            },
            .utf16 => {
                const payload = bytes[inline_layout.payload_offset..];
                const units: [*]u16 = @ptrCast(@alignCast(payload.ptr));
                self.data = .{ .utf16 = units[0..unit_count] };
            },
            .slice, .rope => unreachable,
        }
        return self;
    }

    fn destroyUninitialized(rt: *JSRuntime, self: *String) void {
        switch (self.data) {
            .latin1 => |bytes| switch (self.layout) {
                .compact => return destroyInline(rt, self, .latin1),
                .separate => rt.memory.free(u8, finalLatin1Allocation(bytes, self.capacity)),
                .slice => unreachable,
            },
            .utf16 => |units| switch (self.layout) {
                .compact => return destroyInline(rt, self, .utf16),
                .separate => rt.memory.free(u16, units.ptr[0..self.capacity]),
                .slice => unreachable,
            },
            .slice => |s| JSValue.string(&s.parent.header).free(rt),
            .rope => return destroyRopeWrapper(rt, self),
        }
        rt.memory.destroy(String, self);
    }

    fn destroyInline(rt: *JSRuntime, self: *String, comptime tag: std.meta.Tag(Data)) void {
        const inline_layout = inlineAllocationLayout(tag, self.capacity) orelse unreachable;
        const bytes: [*]u8 = @ptrCast(self);
        rt.memory.freeAlignedBytes(bytes[0..inline_layout.total_size], inline_layout.allocation_alignment);
    }
};

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

fn flattenedRopeData(self: *const String, node: *Rope) String.ResolvedData {
    flattenRopeNode(node);
    _ = self;
    return switch (node.flat) {
        .latin1 => |buf| .{ .latin1 = buf },
        .utf16 => |buf| .{ .utf16 = buf },
        .none => unreachable,
    };
}

/// Infallible flatten used by borrowed-slice readers (`resolveData`), which
/// cannot propagate errors. On allocation failure it runs object-cycle
/// removal to reclaim memory and retries once; only a second failure is
/// fatal, mirroring unrecoverable internal OOM behaviour. Fallible read
/// paths should call `String.ensureFlat` first so OOM surfaces as an error
/// instead of reaching this backstop.
fn flattenRopeNode(node: *Rope) void {
    flattenRopeNodeFallible(node) catch {
        _ = node.rt.runObjectCycleRemoval();
        flattenRopeNodeFallible(node) catch @panic("zjs: out of memory while flattening string rope");
    };
}

/// Materializes the rope's content into `node.flat` and releases the
/// children and the tail buffer. Idempotent. On error the rope is left
/// untouched (children and tail retained, `flat == .none`), so the caller
/// can retry or surface the failure.
fn flattenRopeNodeFallible(node: *Rope) !void {
    if (node.flat != .none) return;
    const rt = node.rt;
    if (node.wide) {
        const buf = try rt.allocRuntime(u16, node.len);
        errdefer rt.memory.free(u16, buf);
        try copyRopeContent(u16, rt, node, buf);
        node.flat = .{ .utf16 = buf };
    } else {
        const allocation = try allocFinalLatin1Buffer(rt, node.len);
        errdefer rt.memory.free(u8, allocation);
        const buf = allocation[0..node.len];
        try copyRopeContent(u8, rt, node, buf);
        writeLatin1Terminator(buf);
        node.flat = .{ .latin1 = buf };
    }
    releaseRopeChildRef(rt, node.left);
    releaseRopeChildRef(rt, node.right);
    node.left = undefined;
    node.right = undefined;
    freeRopeTail(rt, node);
}

/// Releases a rope's private tail buffer (no-op for tail-less ropes).
fn freeRopeTail(rt: *JSRuntime, node: *Rope) void {
    switch (node.tail) {
        .none => return,
        .latin1 => |buf| rt.memory.free(u8, buf),
        .utf16 => |buf| rt.memory.free(u16, buf),
    }
    node.tail = .none;
    node.tail_len = 0;
}

/// Grows (or creates) a narrow tail buffer to hold `need` used bytes and
/// returns it. Callers must route wide tails through `ropeTailEnsureWide`.
fn ropeTailEnsureNarrow(rt: *JSRuntime, node: *Rope, need: usize) ![]u8 {
    switch (node.tail) {
        .latin1 => |buf| {
            if (need <= buf.len) return buf;
            const grown = try rt.allocRuntime(u8, nextStringCapacity(buf.len, need));
            @memcpy(grown[0..node.tail_len], buf[0..node.tail_len]);
            rt.memory.free(u8, buf);
            node.tail = .{ .latin1 = grown };
            return grown;
        },
        .none => {
            const buf = try rt.allocRuntime(u8, nextStringCapacity(0, need));
            node.tail = .{ .latin1 = buf };
            return buf;
        },
        .utf16 => unreachable,
    }
}

/// Grows (or creates) a wide tail buffer to hold `need` used units and
/// returns it. A narrow tail is widened in place so a wide suffix can land
/// in the same buffer.
fn ropeTailEnsureWide(rt: *JSRuntime, node: *Rope, need: usize) ![]u16 {
    switch (node.tail) {
        .utf16 => |buf| {
            if (need <= buf.len) return buf;
            const grown = try rt.allocRuntime(u16, nextStringCapacity(buf.len, need));
            @memcpy(grown[0..node.tail_len], buf[0..node.tail_len]);
            rt.memory.free(u16, buf);
            node.tail = .{ .utf16 = grown };
            return grown;
        },
        .latin1 => |buf| {
            const widened = try rt.allocRuntime(u16, nextStringCapacity(buf.len, need));
            for (buf[0..node.tail_len], 0..) |byte, index| widened[index] = byte;
            rt.memory.free(u8, buf);
            node.tail = .{ .utf16 = widened };
            return widened;
        },
        .none => {
            const buf = try rt.allocRuntime(u16, nextStringCapacity(0, need));
            node.tail = .{ .utf16 = buf };
            return buf;
        },
    }
}

/// Iterative left-to-right leaf copy; never recurses, so arbitrarily deep
/// rope chains (`s = s + x` loops) cannot overflow the native stack. Only the
/// traversal stack can fail; the output buffer is owned by the caller, so an
/// error leaves the rope itself unmodified. Each unflattened rope contributes
/// `left ++ right ++ tail`; a flattened child already merged its tail into
/// `flat`.
fn copyRopeContent(comptime T: type, rt: *JSRuntime, root: *Rope, out: []T) !void {
    const allocator = rt.memory.allocator;
    const Item = union(enum) {
        str: *const String,
        tail: *const Rope,
    };
    var stack = std.ArrayList(Item).empty;
    defer stack.deinit(allocator);
    try stack.append(allocator, .{ .tail = root });
    try stack.append(allocator, .{ .str = root.right });
    try stack.append(allocator, .{ .str = root.left });
    var offset: usize = 0;
    while (stack.pop()) |item| {
        const leaf = switch (item) {
            .tail => |node| {
                if (node.tailResolved()) |resolved| {
                    offset += copyResolvedUnits(T, out[offset..], resolved);
                }
                continue;
            },
            .str => |s| s,
        };
        if (leaf.data == .rope) {
            const child = leaf.data.rope;
            if (child.flat == .none) {
                try stack.append(allocator, .{ .tail = child });
                try stack.append(allocator, .{ .str = child.right });
                try stack.append(allocator, .{ .str = child.left });
                continue;
            }
            offset += copyResolvedUnits(T, out[offset..], switch (child.flat) {
                .latin1 => |buf| .{ .latin1 = buf },
                .utf16 => |buf| .{ .utf16 = buf },
                .none => unreachable,
            });
            continue;
        }
        offset += copyResolvedUnits(T, out[offset..], leaf.resolveData());
    }
    std.debug.assert(offset == out.len);
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
            // A narrow rope (`wide == false`) can never contain wide leaves:
            // children are append-protected via `rope_child`.
            unreachable;
        },
    }
}

fn releaseRopeChildRef(rt: *JSRuntime, child: *String) void {
    var pending: ?*String = null;
    releaseStringRefIntoChain(rt, child, &pending);
    drainRopeDestroyChain(rt, &pending);
}

fn releaseStringRefIntoChain(rt: *JSRuntime, s: *String, pending: *?*String) void {
    if (s.data == .rope) {
        // Manual release for rope wrappers so deep chains destroy iteratively
        // instead of recursing through gc.release -> destroyFromHeader.
        std.debug.assert(s.header.rc > 0);
        s.header.rc -= 1;
        rt.gc.stats.rc_dec += 1;
        if (s.header.rc == 0) {
            s.data.rope.chain_next = pending.*;
            pending.* = s;
        }
        return;
    }
    String.releaseFromHeader(rt, &s.header);
}

fn drainRopeDestroyChain(rt: *JSRuntime, pending: *?*String) void {
    while (pending.*) |wrapper| {
        const node = wrapper.data.rope;
        pending.* = node.chain_next;
        // `atom_id` is a weak back-pointer; nothing to release here. A
        // wrapper bound to a live dynamic atom cannot reach rc 0.
        if (wrapper.atom_id != String.no_atom_id) {
            std.debug.assert(atom_mod.isConst(wrapper.atom_id) or atom_mod.isTaggedInt(wrapper.atom_id));
        }
        switch (node.flat) {
            .none => {
                freeRopeTail(rt, node);
                releaseStringRefIntoChain(rt, node.left, pending);
                releaseStringRefIntoChain(rt, node.right, pending);
            },
            // Flattening merged and released the tail, so a materialized
            // rope never carries one.
            .latin1 => |buf| {
                std.debug.assert(node.tail == .none);
                rt.memory.free(u8, finalLatin1Allocation(buf, buf.len));
            },
            .utf16 => |buf| {
                std.debug.assert(node.tail == .none);
                rt.memory.free(u16, buf);
            },
        }
        rt.memory.destroy(Rope, node);
        rt.memory.destroy(String, wrapper);
    }
}

fn destroyRopeWrapper(rt: *JSRuntime, self: *String) void {
    self.atom_id = String.no_atom_id; // weak back-pointer, already validated by destroyFromHeader
    self.data.rope.chain_next = null;
    var pending: ?*String = self;
    drainRopeDestroyChain(rt, &pending);
}

const InlineAllocationLayout = struct {
    payload_offset: usize,
    total_size: usize,
    allocation_alignment: std.mem.Alignment,
};

fn inlineAllocationLayout(comptime tag: std.meta.Tag(Data), capacity: usize) ?InlineAllocationLayout {
    const unit_align = switch (tag) {
        .latin1 => @alignOf(u8),
        .utf16 => @alignOf(u16),
        .slice, .rope => unreachable,
    };
    const unit_size = switch (tag) {
        .latin1 => @sizeOf(u8),
        .utf16 => @sizeOf(u16),
        .slice, .rope => unreachable,
    };
    const payload_alignment = std.mem.Alignment.fromByteUnits(unit_align);
    const string_alignment = std.mem.Alignment.of(String);
    const allocation_alignment = if (payload_alignment.compare(.gt, string_alignment)) payload_alignment else string_alignment;
    const payload_offset = std.mem.alignForward(usize, @sizeOf(String), payload_alignment.toByteUnits());
    const payload_units = switch (tag) {
        .latin1 => finalLatin1AllocationLen(capacity) orelse return null,
        .utf16 => capacity,
        .slice, .rope => unreachable,
    };
    const payload_size = std.math.mul(usize, unit_size, payload_units) catch return null;
    const total_size = std.math.add(usize, payload_offset, payload_size) catch return null;
    return .{
        .payload_offset = payload_offset,
        .total_size = total_size,
        .allocation_alignment = allocation_alignment,
    };
}

fn finalLatin1AllocationLen(capacity: usize) ?usize {
    return std.math.add(usize, capacity, 1) catch null;
}

fn allocFinalLatin1Buffer(rt: *JSRuntime, capacity: usize) ![]u8 {
    const allocation_len = finalLatin1AllocationLen(capacity) orelse return error.OutOfMemory;
    return rt.allocRuntime(u8, allocation_len);
}

fn finalLatin1Allocation(bytes: []u8, capacity: usize) []u8 {
    const allocation_len = finalLatin1AllocationLen(capacity) orelse unreachable;
    return bytes.ptr[0..allocation_len];
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
    try std.testing.expectEqual(@as(i32, 0), latin_a.compare(latin_a.*));
    try std.testing.expect(latin_a.compare(latin_b.*) < 0);

    const wide_a = try String.createUtf16(rt, &.{0x0100});
    const wide_a_value = wide_a.value();
    defer wide_a_value.free(rt);
    const wide_b = try String.createUtf16(rt, &.{ 0x00ff, 0x0100 });
    const wide_b_value = wide_b.value();
    defer wide_b_value.free(rt);
    try std.testing.expect(wide_a.compare(wide_b.*) > 0);

    const wide_parent = try String.createUtf16(rt, &.{ 0x0100, 'a' });
    const wide_parent_value = wide_parent.value();
    defer wide_parent_value.free(rt);
    const wide_slice = try String.createSlice(rt, wide_parent, 1, 1);
    const wide_slice_value = wide_slice.value();
    defer wide_slice_value.free(rt);
    const latin_single = try String.createUtf8(rt, "a");
    const latin_single_value = latin_single.value();
    defer latin_single_value.free(rt);
    try std.testing.expectEqual(@as(i32, 0), latin_single.compare(wide_slice.*));
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
    try std.testing.expectEqual(@as(i32, 0), first.compare(second.*));
}

const std = @import("std");

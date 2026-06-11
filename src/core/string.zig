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
        start: usize,
        len: usize,
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
    len: usize,
    wide: bool,
    rt: *JSRuntime,
    hash: u32 = 0,
    flat: FlatCache = .none,
    /// Intrusive link used only by the iterative destroy path so arbitrarily
    /// deep rope chains never recurse.
    chain_next: ?*String = null,

    pub const FlatCache = union(enum) {
        none,
        latin1: []u8,
        utf16: []u16,
    };
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
    header: gc.Header,
    data: Data,
    layout: Layout,
    capacity: usize,
    hash: u32,
    atom_id: ?u32 = null,
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
            self.hash = hashLatin1(self.data.latin1, 0);
            return self;
        }

        const self = try createUninitialized(rt, .utf16, plan.units);
        errdefer destroyUninitialized(rt, self);
        _ = try decodeUtf8(bytes, null, self.data.utf16);
        self.hash = hashUtf16(self.data.utf16, 0);
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
            self.hash = hashLatin1(self.data.latin1, 0);
            return self;
        }

        const self = try createUninitialized(rt, .utf16, units.len);
        errdefer destroyUninitialized(rt, self);
        @memcpy(self.data.utf16, units);
        self.hash = hashUtf16(self.data.utf16, 0);
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
            self.hash = hashLatin1(self.data.latin1, 0);
            rt.memory.free(u16, units.ptr[0..capacity]);
            return self;
        }

        const self = try rt.memory.create(String);
        self.* = .{
            .header = .{ .kind = .string },
            .data = .{ .utf16 = units },
            .layout = .separate,
            .capacity = capacity,
            .hash = hashUtf16(units, 0),
        };
        return self;
    }

    pub fn createUtf16Pair(rt: *JSRuntime, first: u16, second: u16) !*String {
        if (first <= 0xff and second <= 0xff) {
            const self = try createUninitialized(rt, .latin1, 2);
            errdefer destroyUninitialized(rt, self);
            self.data.latin1[0] = @intCast(first);
            self.data.latin1[1] = @intCast(second);
            self.hash = (@as(u32, @intCast(first)) *% 263) +% @as(u32, @intCast(second));
            return self;
        }

        const self = try createUninitialized(rt, .utf16, 2);
        errdefer destroyUninitialized(rt, self);
        self.data.utf16[0] = first;
        self.data.utf16[1] = second;
        self.hash = (@as(u32, @intCast(first)) *% 263) +% @as(u32, @intCast(second));
        return self;
    }

    pub fn createAtomBacked(rt: *JSRuntime, atom_id: u32) !*String {
        const name = rt.atoms.name(atom_id) orelse return error.InvalidAtom;
        const self = try createUtf8(rt, name);
        // Only string-kind atoms may seed the bidirectional cache: a
        // symbol's description string must not convert back into the
        // symbol atom when later used as a property key.
        if (rt.atoms.kind(atom_id) == .string) {
            self.atom_id = rt.atoms.dup(atom_id);
        }
        return self;
    }

    /// Interns this string's content as a property-key atom and returns an
    /// owned atom reference (caller releases it via `rt.atoms.free`).
    ///
    /// The atom name uses the same UTF-8/WTF-8 encoding the lexer and the
    /// JSON parser produce, so keys built from runtime strings unify with
    /// keys interned from source text. The id is cached on `atom_id` (the
    /// cache holds its own atom reference, released on destroy), making
    /// repeated conversions of the same string a ref-count bump; the
    /// reverse direction (`AtomTable.toStringValue`) seeds the same cache.
    /// Rope-backed strings are flattened by the content read.
    pub fn internAtom(self: *String, rt: *JSRuntime) !u32 {
        if (self.atom_id) |cached| return rt.atoms.dup(cached);
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
        self.atom_id = rt.atoms.dup(atom_id);
        return atom_id;
    }

    /// Concatenate two latin1 string buffers into a single freshly allocated
    /// latin1 string. The runtime owns the result.
    ///
    /// Used by the `+` operator string fast path so we skip the per-call
    /// `ArrayList(u8)` intermediate (and its `deinit`).
    pub fn createLatin1Concat(rt: *JSRuntime, a: []const u8, b: []const u8) !*String {
        return createLatin1ConcatGrowableWithSeed(rt, a, b, hashLatin1(a, 0));
    }

    pub fn createLatin1ConcatWithSeed(rt: *JSRuntime, a: []const u8, b: []const u8, seed: u32) !*String {
        const total = a.len + b.len;
        const self = try createUninitialized(rt, .latin1, total);
        errdefer destroyUninitialized(rt, self);
        @memcpy(self.data.latin1[0..a.len], a);
        @memcpy(self.data.latin1[a.len..], b);
        self.hash = hashLatin1(b, seed);
        return self;
    }

    fn createLatin1ConcatGrowableWithSeed(rt: *JSRuntime, a: []const u8, b: []const u8, seed: u32) !*String {
        const total = a.len + b.len;
        const capacity = nextStringCapacity(0, total);
        const self = try createInlineUninitialized(rt, .latin1, total, capacity);
        errdefer destroyUninitialized(rt, self);
        @memcpy(self.data.latin1[0..a.len], a);
        @memcpy(self.data.latin1[a.len..], b);
        self.hash = hashLatin1(b, seed);
        return self;
    }

    pub fn createLatin1RepeatedConcatWithSeed(rt: *JSRuntime, a: []const u8, suffix: []const u8, repeat_count: usize, seed: u32) !*String {
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
        self.hash = seed;
        var remaining = repeat_count;
        while (remaining != 0) : (remaining -= 1) {
            self.hash = hashLatin1(suffix, self.hash);
        }
        return self;
    }

    /// Concatenate two utf16 unit buffers into a single freshly allocated
    /// utf16 string. The runtime owns the result.
    pub fn createUtf16Concat(rt: *JSRuntime, a: []const u16, b: []const u16) !*String {
        return createUtf16ConcatGrowableWithSeed(rt, a, b, hashUtf16(a, 0));
    }

    pub fn createUtf16ConcatWithSeed(rt: *JSRuntime, a: []const u16, b: []const u16, seed: u32) !*String {
        const total = a.len + b.len;
        const self = try createUninitialized(rt, .utf16, total);
        errdefer destroyUninitialized(rt, self);
        @memcpy(self.data.utf16[0..a.len], a);
        @memcpy(self.data.utf16[a.len..], b);
        self.hash = hashUtf16(b, seed);
        return self;
    }

    fn createUtf16ConcatGrowableWithSeed(rt: *JSRuntime, a: []const u16, b: []const u16, seed: u32) !*String {
        const total = a.len + b.len;
        const capacity = nextStringCapacity(0, total);
        const self = try createInlineUninitialized(rt, .utf16, total, capacity);
        errdefer destroyUninitialized(rt, self);
        @memcpy(self.data.utf16[0..a.len], a);
        @memcpy(self.data.utf16[a.len..], b);
        self.hash = hashUtf16(b, seed);
        return self;
    }

    pub fn createLatin1(rt: *JSRuntime, bytes: []const u8) !*String {
        const self = try createUninitialized(rt, .latin1, bytes.len);
        errdefer destroyUninitialized(rt, self);
        @memcpy(self.data.latin1, bytes);
        self.hash = hashLatin1(bytes, 0);
        return self;
    }

    /// Minimum combined length (in code units) for the `+` operator to defer
    /// concatenation through a rope instead of copying eagerly.
    pub const rope_min_len: usize = 256;

    /// Creates a rope string deferring the concatenation of `left ++ right`.
    /// Retains both children; content is materialized lazily on first read.
    pub fn createRope(rt: *JSRuntime, left: *String, right: *String) !*String {
        const total = try std.math.add(usize, left.len(), right.len());
        const node = try rt.memory.create(Rope);
        errdefer rt.memory.destroy(Rope, node);
        const self = try rt.memory.create(String);
        node.* = .{
            .left = left,
            .right = right,
            .len = total,
            .wide = left.isWide() or right.isWide(),
            .rt = rt,
        };
        self.* = .{
            .header = .{ .kind = .string },
            .data = .{ .rope = node },
            .layout = .separate,
            .capacity = 0,
            .hash = 0,
        };
        gc.retain(&left.header);
        gc.retain(&right.header);
        left.rope_child = true;
        right.rope_child = true;
        return self;
    }

    pub fn isRope(self: *const String) bool {
        return self.data == .rope;
    }

    /// Content hash usable for hashing string values regardless of rope state.
    /// Flattens rope-backed strings first so equal contents hash equally.
    pub fn contentHash(self: *const String) u32 {
        if (self.data == .rope) {
            _ = self.resolveData();
            return self.data.rope.hash;
        }
        return self.hash;
    }

    pub fn value(self: *String) JSValue {
        return JSValue.string(&self.header);
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
        const shared_len = @min(self.len(), other.len());
        var i: usize = 0;
        while (i < shared_len) : (i += 1) {
            const a = self.codeUnitAt(i);
            const b = other.codeUnitAt(i);
            if (a < b) return -1;
            if (a > b) return 1;
        }
        if (self.len() < other.len()) return -1;
        if (self.len() > other.len()) return 1;
        return 0;
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
        const self = try rt.memory.create(String);
        errdefer rt.memory.destroy(String, self);
        self.header = .{ .kind = .string };
        self.hash = 0;
        self.atom_id = null;
        self.rope_child = false;
        self.layout = .slice;
        self.capacity = 0;
        self.data = .{ .slice = .{ .parent = parent, .start = start, .len = slice_len } };
        gc.retain(&parent.header);
        self.hash = switch (self.resolveData()) {
            .latin1 => |bytes| hashLatin1(bytes, 0),
            .utf16 => |units| hashUtf16(units, 0),
        };
        return self;
    }

    pub fn appendLatin1InPlace(self: *String, rt: *JSRuntime, suffix: []const u8) !bool {
        if (self.atom_id != null or self.rope_child) return false;
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
            self.data = .{ .latin1 = expanded };
            self.hash = hashLatin1(suffix, self.hash);
            return true;
        }
        if (self.layout != .separate) return false;

        var next_capacity = if (self.capacity == 0) @as(usize, 16) else self.capacity;
        while (next_capacity < new_len) {
            next_capacity = next_capacity * 2;
        }
        const expanded = try rt.memory.alloc(u8, next_capacity);
        errdefer rt.memory.free(u8, expanded);
        @memcpy(expanded[0..old_len], bytes);
        @memcpy(expanded[old_len..new_len], suffix);
        const old_bytes = bytes.ptr[0..self.capacity];
        self.data = .{ .latin1 = expanded[0..new_len] };
        self.capacity = next_capacity;
        self.hash = hashLatin1(suffix, self.hash);
        rt.memory.free(u8, old_bytes);
        return true;
    }

    pub fn appendUtf16InPlace(self: *String, rt: *JSRuntime, suffix: []const u16) !bool {
        if (self.atom_id != null or self.rope_child) return false;
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
            self.hash = hashUtf16(suffix, self.hash);
            return true;
        }
        if (self.layout != .separate) return false;

        const next_capacity = nextStringCapacity(self.capacity, new_len);
        const expanded = try rt.memory.alloc(u16, next_capacity);
        errdefer rt.memory.free(u16, expanded);
        @memcpy(expanded[0..old_len], units);
        @memcpy(expanded[old_len..new_len], suffix);
        const old_units = units.ptr[0..self.capacity];
        self.data = .{ .utf16 = expanded[0..new_len] };
        self.capacity = next_capacity;
        self.hash = hashUtf16(suffix, self.hash);
        rt.memory.free(u16, old_units);
        return true;
    }

    pub fn appendLatin1ToUtf16InPlace(self: *String, rt: *JSRuntime, suffix: []const u8) !bool {
        if (self.atom_id != null or self.rope_child) return false;
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
            self.hash = hashLatin1(suffix, self.hash);
            return true;
        }
        if (self.layout != .separate) return false;

        const next_capacity = nextStringCapacity(self.capacity, new_len);
        const expanded = try rt.memory.alloc(u16, next_capacity);
        errdefer rt.memory.free(u16, expanded);
        @memcpy(expanded[0..old_len], units);
        for (suffix, old_len..) |byte, index| expanded[index] = byte;
        const old_units = units.ptr[0..self.capacity];
        self.data = .{ .utf16 = expanded[0..new_len] };
        self.capacity = next_capacity;
        self.hash = hashLatin1(suffix, self.hash);
        rt.memory.free(u16, old_units);
        return true;
    }

    pub fn appendUtf16WidenInPlace(self: *String, rt: *JSRuntime, suffix: []const u16) !bool {
        if (self.atom_id != null or self.rope_child) return false;
        if (suffix.len == 0) return true;
        const bytes = switch (self.data) {
            .latin1 => |bytes| bytes,
            .utf16, .slice, .rope => return false,
        };
        const old_len = bytes.len;
        const new_len = checkedAddLength(old_len, suffix.len) orelse return false;
        if (self.layout != .separate) return false;
        const next_capacity = nextStringCapacity(self.capacity, new_len);
        const expanded = try rt.memory.alloc(u16, next_capacity);
        errdefer rt.memory.free(u16, expanded);
        for (bytes, 0..) |byte, index| expanded[index] = byte;
        @memcpy(expanded[old_len..new_len], suffix);
        const old_bytes = bytes.ptr[0..self.capacity];
        self.data = .{ .utf16 = expanded[0..new_len] };
        self.capacity = next_capacity;
        self.hash = hashUtf16(suffix, self.hash);
        rt.memory.free(u8, old_bytes);
        return true;
    }

    pub fn appendLatin1RepeatedInPlace(self: *String, rt: *JSRuntime, suffix: []const u8, repeat_count: usize) !bool {
        if (self.atom_id != null or self.rope_child) return false;
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
        var next_capacity = self.capacity;
        if (new_len <= self.capacity) {
            expanded = bytes.ptr[0..new_len];
        } else {
            if (self.layout != .separate) return false;
            next_capacity = if (self.capacity == 0) @as(usize, 16) else self.capacity;
            while (next_capacity < new_len) {
                const doubled = @mulWithOverflow(next_capacity, 2);
                next_capacity = if (doubled[1] == 0 and doubled[0] > next_capacity) doubled[0] else new_len;
            }
            expanded = try rt.memory.alloc(u8, next_capacity);
            errdefer rt.memory.free(u8, expanded);
            @memcpy(expanded[0..old_len], bytes);
            old_bytes = bytes.ptr[0..self.capacity];
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
        self.data = .{ .latin1 = expanded[0..new_len] };
        self.capacity = next_capacity;
        var remaining = repeat_count;
        while (remaining != 0) : (remaining -= 1) {
            self.hash = hashLatin1(suffix, self.hash);
        }
        if (old_bytes.len != 0) rt.memory.free(u8, old_bytes);
        return true;
    }

    pub fn destroyFromHeader(rt: *JSRuntime, header: *gc.Header) void {
        const self: *String = @alignCast(@fieldParentPtr("header", header));
        if (self.atom_id) |atom_id| rt.atoms.free(atom_id);
        destroyUninitialized(rt, self);
    }

    fn createUninitialized(rt: *JSRuntime, comptime tag: std.meta.Tag(Data), unit_count: usize) !*String {
        return createInlineUninitialized(rt, tag, unit_count, unit_count);
    }

    fn createInlineUninitialized(rt: *JSRuntime, comptime tag: std.meta.Tag(Data), unit_count: usize, capacity: usize) !*String {
        std.debug.assert(capacity >= unit_count);
        const inline_layout = inlineAllocationLayout(tag, capacity) orelse return error.OutOfMemory;
        const bytes = try rt.memory.allocAlignedBytes(inline_layout.total_size, inline_layout.allocation_alignment);
        const self: *String = @ptrCast(@alignCast(bytes.ptr));
        self.header = .{ .kind = .string };
        self.hash = 0;
        self.atom_id = null;
        self.rope_child = false;
        self.layout = .compact;
        self.capacity = capacity;
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
                .separate => rt.memory.free(u8, bytes.ptr[0..self.capacity]),
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

fn flattenedRopeData(self: *const String, node: *Rope) String.ResolvedData {
    flattenRopeNode(node);
    // Keep the canonical wrapper's hash cache coherent for direct readers.
    // (When `self` is a transient by-value copy the write is simply lost.)
    @constCast(self).hash = node.hash;
    return switch (node.flat) {
        .latin1 => |buf| .{ .latin1 = buf },
        .utf16 => |buf| .{ .utf16 = buf },
        .none => unreachable,
    };
}

/// Materializes the rope's content into `node.flat` and releases the children.
/// Idempotent. Borrowed-slice readers (`resolveData`) cannot propagate errors,
/// so an allocation failure here is fatal, mirroring unrecoverable internal
/// OOM behaviour.
fn flattenRopeNode(node: *Rope) void {
    if (node.flat != .none) return;
    const rt = node.rt;
    if (node.wide) {
        const buf = rt.memory.alloc(u16, node.len) catch @panic("zjs: out of memory while flattening string rope");
        copyRopeContent(u16, rt, node, buf);
        node.flat = .{ .utf16 = buf };
        node.hash = hashUtf16(buf, 0);
    } else {
        const buf = rt.memory.alloc(u8, node.len) catch @panic("zjs: out of memory while flattening string rope");
        copyRopeContent(u8, rt, node, buf);
        node.flat = .{ .latin1 = buf };
        node.hash = hashLatin1(buf, 0);
    }
    releaseRopeChildRef(rt, node.left);
    releaseRopeChildRef(rt, node.right);
    node.left = undefined;
    node.right = undefined;
}

/// Iterative left-to-right leaf copy; never recurses, so arbitrarily deep
/// rope chains (`s = s + x` loops) cannot overflow the native stack.
fn copyRopeContent(comptime T: type, rt: *JSRuntime, root: *Rope, out: []T) void {
    const allocator = rt.memory.allocator;
    var stack = std.ArrayList(*const String).empty;
    defer stack.deinit(allocator);
    stack.append(allocator, root.right) catch @panic("zjs: out of memory while flattening string rope");
    stack.append(allocator, root.left) catch @panic("zjs: out of memory while flattening string rope");
    var offset: usize = 0;
    while (stack.pop()) |item| {
        if (item.data == .rope) {
            const child = item.data.rope;
            if (child.flat == .none) {
                stack.append(allocator, child.right) catch @panic("zjs: out of memory while flattening string rope");
                stack.append(allocator, child.left) catch @panic("zjs: out of memory while flattening string rope");
                continue;
            }
            offset += copyResolvedUnits(T, out[offset..], switch (child.flat) {
                .latin1 => |buf| .{ .latin1 = buf },
                .utf16 => |buf| .{ .utf16 = buf },
                .none => unreachable,
            });
            continue;
        }
        offset += copyResolvedUnits(T, out[offset..], item.resolveData());
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
    gc.release(rt, &s.header);
}

fn drainRopeDestroyChain(rt: *JSRuntime, pending: *?*String) void {
    while (pending.*) |wrapper| {
        const node = wrapper.data.rope;
        pending.* = node.chain_next;
        if (wrapper.atom_id) |atom_id| rt.atoms.free(atom_id);
        switch (node.flat) {
            .none => {
                releaseStringRefIntoChain(rt, node.left, pending);
                releaseStringRefIntoChain(rt, node.right, pending);
            },
            .latin1 => |buf| rt.memory.free(u8, buf),
            .utf16 => |buf| rt.memory.free(u16, buf),
        }
        rt.memory.destroy(Rope, node);
        rt.memory.destroy(String, wrapper);
    }
}

fn destroyRopeWrapper(rt: *JSRuntime, self: *String) void {
    self.atom_id = null; // already released by destroyFromHeader
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
    const payload_size = std.math.mul(usize, unit_size, capacity) catch return null;
    const total_size = std.math.add(usize, payload_offset, payload_size) catch return null;
    return .{
        .payload_offset = payload_offset,
        .total_size = total_size,
        .allocation_alignment = allocation_alignment,
    };
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

const std = @import("std");

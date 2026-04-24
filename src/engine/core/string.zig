const gc = @import("gc.zig");
const Runtime = @import("runtime.zig").Runtime;
const Value = @import("value.zig").Value;

pub const StringError = error{
    InvalidUtf8,
};

pub const Data = union(enum) {
    latin1: []u8,
    utf16: []u16,

    pub fn len(self: Data) usize {
        return switch (self) {
            .latin1 => |bytes| bytes.len,
            .utf16 => |units| units.len,
        };
    }

    pub fn isWide(self: Data) bool {
        return self == .utf16;
    }
};

pub const String = struct {
    header: gc.Header,
    data: Data,
    hash: u32,
    atom_id: ?u32 = null,

    /// Returns an owned runtime string. The runtime releases it through
    /// reference counting when all `Value` handles are freed.
    pub fn createAscii(rt: *Runtime, bytes: []const u8) !*String {
        return createLatin1(rt, bytes);
    }

    /// Returns an owned runtime string decoded from UTF-8 into QuickJS-style
    /// 8-bit or 16-bit code-unit storage.
    pub fn createUtf8(rt: *Runtime, bytes: []const u8) !*String {
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
    /// `Value.free` or another owner.
    pub fn createUtf16(rt: *Runtime, units: []const u16) !*String {
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

    pub fn createAtomBacked(rt: *Runtime, atom_id: u32) !*String {
        const name = rt.atoms.name(atom_id) orelse return error.InvalidAtom;
        const self = try createUtf8(rt, name);
        self.atom_id = rt.atoms.dup(atom_id);
        return self;
    }

    fn createLatin1(rt: *Runtime, bytes: []const u8) !*String {
        const self = try rt.memory.create(String);
        errdefer rt.memory.destroy(String, self);

        const owned = try rt.memory.alloc(u8, bytes.len);
        errdefer rt.memory.free(u8, owned);
        @memcpy(owned, bytes);

        self.* = .{
            .header = .{ .kind = .string },
            .data = .{ .latin1 = owned },
            .hash = hashLatin1(bytes, 0),
        };
        return self;
    }

    pub fn value(self: *String) Value {
        return Value.string(&self.header);
    }

    pub fn len(self: String) usize {
        return self.data.len();
    }

    pub fn isWide(self: String) bool {
        return self.data.isWide();
    }

    pub fn eqlBytes(self: String, bytes: []const u8) bool {
        return switch (self.data) {
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

    pub fn codeUnitAt(self: String, index: usize) u16 {
        return switch (self.data) {
            .latin1 => |bytes| bytes[index],
            .utf16 => |units| units[index],
        };
    }

    pub fn destroyFromHeader(rt: *Runtime, header: *gc.Header) void {
        const self: *String = @fieldParentPtr("header", header);
        if (self.atom_id) |atom_id| rt.atoms.free(atom_id);
        destroyUninitialized(rt, self);
    }

    fn createUninitialized(rt: *Runtime, comptime tag: std.meta.Tag(Data), unit_count: usize) !*String {
        const self = try rt.memory.create(String);
        errdefer rt.memory.destroy(String, self);
        self.header = .{ .kind = .string };
        self.hash = 0;
        self.atom_id = null;
        switch (tag) {
            .latin1 => self.data = .{ .latin1 = try rt.memory.alloc(u8, unit_count) },
            .utf16 => self.data = .{ .utf16 = try rt.memory.alloc(u16, unit_count) },
        }
        return self;
    }

    fn destroyUninitialized(rt: *Runtime, self: *String) void {
        switch (self.data) {
            .latin1 => |bytes| rt.memory.free(u8, bytes),
            .utf16 => |units| rt.memory.free(u16, units),
        }
        rt.memory.destroy(String, self);
    }
};

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
                const cp = decoded.codepoint - 0x10000;
                out[out_i] = @intCast(0xd800 + (cp >> 10));
                out[out_i + 1] = @intCast(0xdc00 + (cp & 0x3ff));
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
        if (cp < 0x800 or (cp >= 0xd800 and cp <= 0xdfff)) return error.InvalidUtf8;
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

const std = @import("std");

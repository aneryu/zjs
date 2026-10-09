//! Array-index parsing and owned atom-id lists.
//!
//! `atom.zig` re-exports the public names. `parseArrayIndex` stays file-visible
//! for the predefined hash and `AtomTable`; it is not a new `atom.zig` export.

const atom = @import("atom.zig");
const JSRuntime = @import("../runtime.zig").JSRuntime;

const Atom = atom.Atom;
const max_int_atom = atom.max_int_atom;

pub fn parseArrayIndex(bytes: []const u8) ?u32 {
    // Leading-digit gate before any scan work, mirroring qjs JS_NewAtomLen
    // (quickjs.c `is_digit(*str)`): identifier spellings bail here.
    if (bytes.len == 0 or bytes[0] < '0' or bytes[0] > '9') return null;
    if (bytes.len > 1 and bytes[0] == '0') return null;
    var n: u64 = 0;
    for (bytes) |c| {
        if (c < '0' or c > '9') return null;
        n = n * 10 + (c - '0');
        if (n > max_int_atom) return null;
    }
    return @intCast(n);
}

/// Upper bound of a JS array index (2^32-2). Mirrors `array.max_array_index`;
/// duplicated here to keep the atom layer free of an `array.zig` import cycle.
pub const max_array_index: u32 = 0xffff_fffe;

/// Like `parseArrayIndex` but bounded by the full array-index range
/// (`max_array_index`) instead of the tighter tagged-int range (`max_int_atom`).
/// Matches `array.arrayIndexFromName`, used by `atomIsArrayIndex` for the high
/// string-atom index window `(max_int_atom, max_array_index]` that stays a
/// dynamic string atom (never tagged at intern time).
/// The canonical array index (`0`..`max_array_index`, no leading zeros) a
/// decimal property name spells, if any.
pub fn parseHighArrayIndex(bytes: []const u8) ?u32 {
    if (bytes.len == 0) return null;
    if (bytes.len > 1 and bytes[0] == '0') return null;
    var n: u64 = 0;
    for (bytes) |c| {
        if (c < '0' or c > '9') return null;
        n = n * 10 + (c - '0');
        if (n > max_array_index) return null;
    }
    return @intCast(n);
}

/// Builds an owned `[]Atom` in amortized O(1) appends. `items` is the
/// filled prefix of `buffer`; root it with `rootAtomList(&builder.items)`
/// while user code can run. `toOwnedSlice` returns an exact-length list,
/// the shape `freeAtomList` / `Object.freeKeys` expect.
pub const AtomListBuilder = struct {
    buffer: []Atom = &.{},
    items: []Atom = &.{},

    pub fn initCapacity(rt: *JSRuntime, capacity: usize) !AtomListBuilder {
        var builder: AtomListBuilder = .{};
        try builder.ensureTotalCapacity(rt, capacity);
        return builder;
    }

    pub fn deinit(self: *AtomListBuilder, rt: *JSRuntime) void {
        freeAtomList(rt, self.buffer);
        self.* = .{};
    }

    pub fn ensureTotalCapacity(self: *AtomListBuilder, rt: *JSRuntime, capacity: usize) !void {
        if (capacity <= self.buffer.len) return;
        const next = try rt.allocNative(Atom, capacity);
        @memcpy(next[0..self.items.len], self.items);
        const old = self.buffer;
        self.buffer = next;
        self.items = next[0..self.items.len];
        freeAtomList(rt, old);
    }

    pub fn append(self: *AtomListBuilder, rt: *JSRuntime, atom_id: Atom) !void {
        if (self.items.len == self.buffer.len) {
            try self.ensureTotalCapacity(rt, @max(8, self.buffer.len * 2));
        }
        self.buffer[self.items.len] = atom_id;
        self.items = self.buffer[0 .. self.items.len + 1];
    }

    /// Transfers ownership of the filled atoms; the builder is empty after.
    pub fn toOwnedSlice(self: *AtomListBuilder, rt: *JSRuntime) ![]Atom {
        if (self.items.len != self.buffer.len) {
            const exact: []Atom = if (self.items.len == 0) &.{} else try rt.allocNative(Atom, self.items.len);
            @memcpy(exact, self.items);
            freeAtomList(rt, self.buffer);
            self.* = .{};
            return exact;
        }
        const owned = self.buffer;
        self.* = .{};
        return owned;
    }
};

pub fn freeAtomList(rt: *JSRuntime, list: []Atom) void {
    if (list.len != 0) rt.freeNative(Atom, list);
}

const atom = @import("atom.zig");

pub const max_array_index: u32 = 0xffff_fffe;
pub const max_array_length: u32 = 0xffff_ffff;

pub fn isArrayIndexName(bytes: []const u8) bool {
    return arrayIndexFromName(bytes) != null;
}

pub fn arrayIndexFromAtom(atoms: anytype, atom_id: atom.Atom) ?u32 {
    if (atom.isTaggedInt(atom_id)) {
        const index = atom.atomToUInt32(atom_id);
        if (index <= max_array_index) return index;
        return null;
    }
    const name = atoms.name(atom_id) orelse return null;
    return arrayIndexFromName(name);
}

pub fn arrayIndexFromName(bytes: []const u8) ?u32 {
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

pub fn canonicalNumericIndex(bytes: []const u8) ?f64 {
    if (std.mem.eql(u8, bytes, "-0")) return -0.0;
    if (std.fmt.parseFloat(f64, bytes)) |value| {
        var buf: [64]u8 = undefined;
        const printed = std.fmt.bufPrint(&buf, "{d}", .{value}) catch return null;
        if (std.mem.eql(u8, printed, bytes)) return value;
    } else |_| {}
    return null;
}

const std = @import("std");

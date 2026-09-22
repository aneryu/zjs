//! Runtime string cache: single-byte, empty, two-unit, atom, percent, and
//! small-integer strings.
//!
//! The slots stay on `JSRuntime` so auto-layout does not move `vm_stack`.
//! Each filled slot is a strong root for the runtime's lifetime. Lookups
//! return a borrowed string; there is no per-caller retain. The four-way
//! atom cursor lives in `recent_atom_string_next` (a `u8` in the old
//! `compact_state` slot).

const std = @import("std");
const atom = @import("atom.zig");
const string = @import("string.zig");
const unicode = @import("../libs/unicode.zig");
const runtime_mod = @import("runtime.zig");
const JSRuntime = runtime_mod.JSRuntime;
const RootVisitor = runtime_mod.RootVisitor;
const RootTraceError = runtime_mod.RootTraceError;

pub const RecentTwoUnit = struct {
    first: u16,
    second: u16,
    string: *string.String,
};

pub const RecentAtom = struct {
    atom_id: atom.Atom,
    string: *string.String,
};

pub fn bind(rt: *JSRuntime) void {
    rt.single_byte_strings = @splat(null);
    rt.empty_string = null;
    rt.recent_two_unit_string = null;
    rt.recent_atom_strings = @splat(null);
    rt.percent_hex_strings = @splat(null);
    rt.small_int_strings = @splat(null);
    rt.recent_atom_string_next = 0;
}

pub fn clear(rt: *JSRuntime) void {
    rt.recent_two_unit_string = null;
    for (&rt.recent_atom_strings) |*slot| slot.* = null;
    rt.recent_atom_string_next = 0;
    rt.empty_string = null;
    for (&rt.single_byte_strings) |*slot| slot.* = null;
    for (&rt.percent_hex_strings) |*slot| slot.* = null;
    for (&rt.small_int_strings) |*slot| slot.* = null;
}

pub fn trace(rt: *JSRuntime, visitor: *RootVisitor) RootTraceError!void {
    for (&rt.single_byte_strings) |*slot| try visitor.stringSlot(slot);
    for (&rt.percent_hex_strings) |*slot| try visitor.stringSlot(slot);
    for (&rt.small_int_strings) |*slot| try visitor.stringSlot(slot);
    try visitor.stringSlot(&rt.empty_string);
    if (rt.recent_two_unit_string) |*cached| try visitor.stringField(&cached.string);
    for (&rt.recent_atom_strings) |*cached| {
        if (cached.*) |*stored| try visitor.stringField(&stored.string);
    }
}

pub inline fn singleByte(rt: *JSRuntime, byte: u8) !*string.String {
    if (rt.single_byte_strings[byte]) |cached| return cached;
    return createSingleByte(rt, byte);
}

pub noinline fn createSingleByte(rt: *JSRuntime, byte: u8) !*string.String {
    const created = try string.String.createLatin1(rt, &.{byte});
    rt.single_byte_strings[byte] = created;
    return created;
}

pub inline fn cachedSingleByte(rt: *JSRuntime, byte: u8) ?*string.String {
    return rt.single_byte_strings[byte];
}

pub fn empty(rt: *JSRuntime) !*string.String {
    if (rt.empty_string) |cached| return cached;
    const created = try string.String.createAscii(rt, "");
    rt.empty_string = created;
    return created;
}

pub fn recentTwoUnit(rt: *JSRuntime, first: u16, second: u16) !*string.String {
    if (rt.recent_two_unit_string) |cached| {
        if (cached.first == first and cached.second == second) return cached.string;
    }
    const created = try string.String.createUtf16Pair(rt, first, second);
    rt.recent_two_unit_string = .{
        .first = first,
        .second = second,
        .string = created,
    };
    return created;
}

pub fn recentAtom(rt: *JSRuntime, atom_id: atom.Atom, bytes: []const u8) !*string.String {
    for (rt.recent_atom_strings) |slot| {
        if (slot) |cached| {
            if (cached.atom_id == atom_id) return cached.string;
        }
    }
    const created = try string.String.createUtf8(rt, bytes);
    rt.atoms.cacheString(rt, atom_id, created);
    const slot_index: usize = rt.recent_atom_string_next;
    rt.recent_atom_strings[slot_index] = .{
        .atom_id = atom_id,
        .string = created,
    };
    rt.recent_atom_string_next = @intCast((slot_index + 1) % rt.recent_atom_strings.len);
    return created;
}

pub fn smallInt(rt: *JSRuntime, value: u8) !*string.String {
    if (rt.small_int_strings[value]) |cached| return cached;
    var buf: [4]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d}", .{value}) catch unreachable;
    const cached = try string.String.createLatin1(rt, text);
    rt.small_int_strings[value] = cached;
    return cached;
}

pub fn percentHex(rt: *JSRuntime, value: u8) !*string.String {
    if (rt.percent_hex_strings[value]) |cached| return cached;
    const bytes: [3]u8 = .{
        '%',
        unicode.asciiUpperHexDigitChar(value >> 4),
        unicode.asciiUpperHexDigitChar(value & 0x0f),
    };
    const created = try string.String.createAscii(rt, &bytes);
    rt.percent_hex_strings[value] = created;
    return created;
}

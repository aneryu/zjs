//! Runtime string cache: single-byte, empty, two-unit, atom, percent, and
//! small-integer strings.
//!
//! Each filled slot is a strong root for the runtime's lifetime. Lookups
//! return a borrowed string; there is no per-caller retain.

const std = @import("std");
const atom = @import("atom.zig");
const string = @import("string.zig");
const unicode = @import("../libs/unicode.zig");
const runtime_mod = @import("../runtime.zig");
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

/// `JSRuntime.strings`. Every slot is filled lazily and then kept until
/// runtime teardown.
pub const Cache = struct {
    /// One shared latin1 body per code unit `0..255`. Every one-code-unit
    /// producer reads it (`charAt`, `at`, one-argument `String.fromCharCode`,
    /// the string iterator, `s[i]`, a length-1 `slice`); code units `>= 0x100`
    /// still allocate. Sharing is unobservable because strings are immutable
    /// and compared by value.
    single_byte: [256]?*string.String = @splat(null),
    /// Uppercase percent-escaped bytes (`%00`..`%FF`) for the URI helpers.
    percent_hex: [256]?*string.String = @splat(null),
    /// Decimal strings "0".."255".
    small_int: [256]?*string.String = @splat(null),
    empty: ?*string.String = null,
    /// Most recent two-code-unit string, e.g. a surrogate pair built by both
    /// `decodeURI` and `String.fromCharCode` in the same sweep.
    recent_two_unit: ?RecentTwoUnit = null,
    /// Four-way atom-to-string cache for hot bytecode constants; regexp
    /// literals alternate between source and flags atoms.
    recent_atoms: [4]?RecentAtom = @splat(null),
    recent_atom_next: u8 = 0,
};

pub fn trace(rt: *JSRuntime, visitor: *RootVisitor) RootTraceError!void {
    const cache = &rt.strings;
    for (&cache.single_byte) |*slot| try visitor.stringSlot(slot);
    for (&cache.percent_hex) |*slot| try visitor.stringSlot(slot);
    for (&cache.small_int) |*slot| try visitor.stringSlot(slot);
    try visitor.stringSlot(&cache.empty);
    if (cache.recent_two_unit) |*cached| try visitor.stringField(&cached.string);
    for (&cache.recent_atoms) |*cached| {
        if (cached.*) |*stored| try visitor.stringField(&stored.string);
    }
}

pub inline fn singleByte(rt: *JSRuntime, byte: u8) !*string.String {
    if (rt.strings.single_byte[byte]) |cached| return cached;
    return createSingleByte(rt, byte);
}

noinline fn createSingleByte(rt: *JSRuntime, byte: u8) !*string.String {
    const created = try string.String.createLatin1(rt, &.{byte});
    rt.strings.single_byte[byte] = created;
    return created;
}

pub inline fn cachedSingleByte(rt: *JSRuntime, byte: u8) ?*string.String {
    return rt.strings.single_byte[byte];
}

pub fn empty(rt: *JSRuntime) !*string.String {
    if (rt.strings.empty) |cached| return cached;
    const created = try string.String.createAscii(rt, "");
    rt.strings.empty = created;
    return created;
}

pub fn recentTwoUnit(rt: *JSRuntime, first: u16, second: u16) !*string.String {
    if (rt.strings.recent_two_unit) |cached| {
        if (cached.first == first and cached.second == second) return cached.string;
    }
    const created = try string.String.createUtf16Pair(rt, first, second);
    rt.strings.recent_two_unit = .{
        .first = first,
        .second = second,
        .string = created,
    };
    return created;
}

pub fn recentAtom(rt: *JSRuntime, atom_id: atom.Atom, bytes: []const u8) !*string.String {
    for (rt.strings.recent_atoms) |slot| {
        if (slot) |cached| {
            if (cached.atom_id == atom_id) return cached.string;
        }
    }
    const created = try string.String.createUtf8(rt, bytes);
    rt.atoms.cacheString(rt, atom_id, created);
    const slot_index: usize = rt.strings.recent_atom_next;
    rt.strings.recent_atoms[slot_index] = .{
        .atom_id = atom_id,
        .string = created,
    };
    rt.strings.recent_atom_next = @intCast((slot_index + 1) % rt.strings.recent_atoms.len);
    return created;
}

pub fn smallInt(rt: *JSRuntime, value: u8) !*string.String {
    if (rt.strings.small_int[value]) |cached| return cached;
    var buf: [4]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d}", .{value}) catch unreachable;
    const cached = try string.String.createLatin1(rt, text);
    rt.strings.small_int[value] = cached;
    return cached;
}

pub fn percentHex(rt: *JSRuntime, value: u8) !*string.String {
    if (rt.strings.percent_hex[value]) |cached| return cached;
    const bytes: [3]u8 = .{
        '%',
        unicode.asciiUpperHexDigitChar(value >> 4),
        unicode.asciiUpperHexDigitChar(value & 0x0f),
    };
    const created = try string.String.createAscii(rt, &bytes);
    rt.strings.percent_hex[value] = created;
    return created;
}

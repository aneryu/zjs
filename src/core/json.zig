//! JSON serialization formatting primitives.
//!
//! These are the pure string-factory + JSON-escaping helpers used when
//! building the result of `JSON.stringify`. They depend only on
//! `core.string.String` (the flat string factory), `core.atom` (tagged-int /
//! name lookups), `core.runtime` rooting, and the `libs/unicode` codec. They
//! carry zero exec/builtins/opcode dependency, so they live in core and are
//! consumed by the JSON serializer and install path in builtins/json.zig
//! (which re-exports them).

const std = @import("std");

const core = @import("root.zig");
const unicode = @import("../libs/unicode.zig");

/// Wrap finished serializer bytes in a JSValue string, choosing the ASCII
/// fast path when the buffer holds no high bytes.
pub fn createJsonStringValue(rt: *core.JSRuntime, bytes: []const u8) !core.JSValue {
    const str = if (jsonBytesAreAscii(bytes))
        try core.string.String.createAscii(rt, bytes)
    else
        try core.string.String.createUtf8(rt, bytes);
    return str.value();
}

fn jsonBytesAreAscii(bytes: []const u8) bool {
    for (bytes) |byte| {
        if (byte >= 0x80) return false;
    }
    return true;
}

/// Append the JSON quoted-string form of a string JSValue to `buffer`.
pub fn appendJsonStringValue(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), value: core.JSValue) !void {
    var rooted_value = value;
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &rooted_value },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    const string_value = rooted_value.asStringBody() orelse {
        try appendEscapedJsonString(rt, buffer, "");
        return;
    };
    try string_value.ensureFlat(rt);
    switch (string_value.resolveData()) {
        .latin1 => |bytes| try appendEscapedJsonLatin1String(rt, buffer, bytes),
        .utf16 => |units| try appendEscapedJsonUtf16String(rt, buffer, units),
    }
}

/// Append the JSON quoted-string form of a property key atom to `buffer`,
/// rendering tagged-int atoms as their decimal index.
pub fn appendJsonAtomName(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), atom_id: core.Atom) !void {
    if (core.atom.isTaggedInt(atom_id)) {
        var int_buf: [10]u8 = undefined;
        const printed = try std.fmt.bufPrint(&int_buf, "{d}", .{core.atom.atomToUInt32(atom_id)});
        return appendEscapedJsonString(rt, buffer, printed);
    }
    const name = rt.atoms.name(atom_id) orelse "";
    return appendEscapedJsonString(rt, buffer, name);
}

/// Append `bytes` (treated as ASCII/UTF-8 source) as a JSON quoted string.
pub fn appendEscapedJsonString(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), bytes: []const u8) !void {
    try buffer.append(rt.memory.allocator, '"');
    for (bytes) |byte| {
        try appendEscapedJsonByte(rt, buffer, byte);
    }
    try buffer.append(rt.memory.allocator, '"');
}

fn appendEscapedJsonLatin1String(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), bytes: []const u8) !void {
    try buffer.append(rt.memory.allocator, '"');
    for (bytes) |byte| {
        if (byte <= 0x7f) {
            try appendEscapedJsonByte(rt, buffer, byte);
        } else {
            try appendUtf8CodePoint(rt, buffer, byte);
        }
    }
    try buffer.append(rt.memory.allocator, '"');
}

fn appendEscapedJsonUtf16String(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), units: []const u16) !void {
    try buffer.append(rt.memory.allocator, '"');
    var index: usize = 0;
    while (index < units.len) : (index += 1) {
        const unit = units[index];
        if (unicode.isHighSurrogateUnit(unit)) {
            if (index + 1 < units.len) {
                const next = units[index + 1];
                if (unicode.isLowSurrogateUnit(next)) {
                    try appendUtf8CodePoint(rt, buffer, @intCast(unicode.codePointFromSurrogatePair(unit, next)));
                    index += 1;
                    continue;
                }
            }
            try appendEscapedJsonUnit(rt, buffer, unit);
        } else if (unicode.isLowSurrogateUnit(unit)) {
            try appendEscapedJsonUnit(rt, buffer, unit);
        } else if (unit <= 0x7f) {
            try appendEscapedJsonByte(rt, buffer, @intCast(unit));
        } else {
            try appendUtf8CodePoint(rt, buffer, unit);
        }
    }
    try buffer.append(rt.memory.allocator, '"');
}

fn appendEscapedJsonByte(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), byte: u8) !void {
    switch (byte) {
        '"' => try buffer.appendSlice(rt.memory.allocator, "\\\""),
        '\\' => try buffer.appendSlice(rt.memory.allocator, "\\\\"),
        0x08 => try buffer.appendSlice(rt.memory.allocator, "\\b"),
        0x09 => try buffer.appendSlice(rt.memory.allocator, "\\t"),
        0x0a => try buffer.appendSlice(rt.memory.allocator, "\\n"),
        0x0c => try buffer.appendSlice(rt.memory.allocator, "\\f"),
        0x0d => try buffer.appendSlice(rt.memory.allocator, "\\r"),
        0x00...0x07, 0x0b, 0x0e...0x1f => try appendEscapedJsonUnit(rt, buffer, byte),
        else => try buffer.append(rt.memory.allocator, byte),
    }
}

fn appendEscapedJsonUnit(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), unit: anytype) !void {
    var escaped: [6]u8 = undefined;
    const text = try std.fmt.bufPrint(&escaped, "\\u{x:0>4}", .{unit});
    try buffer.appendSlice(rt.memory.allocator, text);
}

fn appendUtf8CodePoint(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), cp: u32) !void {
    return unicode.appendUtf8CodePoint(rt.memory.allocator, buffer, cp);
}

//! Engine-core typed-array element specification: the concrete `*Array` names
//! mapped to their element byte size and the internal element-kind tag.
//!
//! QuickJS source map: the typed-array element-type table (`typed_array_size_log2`
//! / class taxonomy in the C core) is engine metadata, consulted by the
//! constructor and element read/write fabric (`core/typed_array.zig`). These are
//! pure name<->kind/size lookups over the fixed standard set; they import only
//! `std` and run no VM machinery, so they live in core and exec/builtins are
//! clients.

const std = @import("std");

pub const Element = struct {
    size: u32,
    kind: u8,
};

const Entry = struct {
    name: []const u8,
    element: Element,
};

pub const concrete = [_]Entry{
    .{ .name = "Int8Array", .element = .{ .size = 1, .kind = 1 } },
    .{ .name = "Uint8Array", .element = .{ .size = 1, .kind = 2 } },
    .{ .name = "Uint8ClampedArray", .element = .{ .size = 1, .kind = 3 } },
    .{ .name = "Int16Array", .element = .{ .size = 2, .kind = 4 } },
    .{ .name = "Uint16Array", .element = .{ .size = 2, .kind = 5 } },
    .{ .name = "Int32Array", .element = .{ .size = 4, .kind = 6 } },
    .{ .name = "Uint32Array", .element = .{ .size = 4, .kind = 7 } },
    .{ .name = "Float16Array", .element = .{ .size = 2, .kind = 8 } },
    .{ .name = "Float32Array", .element = .{ .size = 4, .kind = 9 } },
    .{ .name = "Float64Array", .element = .{ .size = 8, .kind = 10 } },
    .{ .name = "BigInt64Array", .element = .{ .size = 8, .kind = 11 } },
    .{ .name = "BigUint64Array", .element = .{ .size = 8, .kind = 12 } },
};

pub fn element(name: []const u8) ?Element {
    for (concrete) |entry| {
        if (std.mem.eql(u8, name, entry.name)) return entry.element;
    }
    return null;
}

pub fn elementFromKind(kind: u8) ?Element {
    for (concrete) |entry| {
        if (entry.element.kind == kind) return entry.element;
    }
    return null;
}

pub fn nameFromKind(kind: u8) ?[]const u8 {
    for (concrete) |entry| {
        if (entry.element.kind == kind) return entry.name;
    }
    return null;
}

pub fn isConcrete(name: []const u8) bool {
    return element(name) != null;
}

test "typed array concrete names map to stable element sizes and kinds" {
    const testing = std.testing;

    try testing.expectEqual(@as(usize, 12), concrete.len);
    try testing.expectEqual(@as(u32, 1), element("Int8Array").?.size);
    try testing.expectEqual(@as(u8, 2), element("Uint8Array").?.kind);
    try testing.expectEqual(@as(u32, 2), element("Float16Array").?.size);
    try testing.expectEqual(@as(u8, 12), element("BigUint64Array").?.kind);
    try testing.expectEqualStrings("BigInt64Array", nameFromKind(11).?);
    try testing.expect(isConcrete("Float64Array"));
    try testing.expect(!isConcrete("TypedArray"));
    try testing.expect(element("ArrayBuffer") == null);
    try testing.expect(elementFromKind(0) == null);
}

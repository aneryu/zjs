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

/// The typed-array element kinds, plus the DataView-only marker that reuses
/// the same payload slot. `none` is the value of a slot that names no view.
pub const Kind = enum(u8) {
    none = 0,
    int8 = 1,
    uint8 = 2,
    uint8_clamped = 3,
    int16 = 4,
    uint16 = 5,
    int32 = 6,
    uint32 = 7,
    float16 = 8,
    float32 = 9,
    float64 = 10,
    bigint64 = 11,
    biguint64 = 12,
    /// A DataView (element_size 0) whose byte length tracks its resizable
    /// buffer instead of being fixed at construction.
    data_view_length_tracking = 13,

    /// A concrete typed-array element kind (not `none` / the DataView marker).
    pub fn isElement(self: Kind) bool {
        return switch (self) {
            .none, .data_view_length_tracking => false,
            else => true,
        };
    }

    /// The non-BigInt element kinds: decoded and encoded without allocating.
    pub fn isNumeric(self: Kind) bool {
        return switch (self) {
            .int8, .uint8, .uint8_clamped, .int16, .uint16, .int32, .uint32, .float16, .float32, .float64 => true,
            else => false,
        };
    }

    pub fn isInteger(self: Kind) bool {
        return switch (self) {
            .int8, .uint8, .uint8_clamped, .int16, .uint16, .int32, .uint32 => true,
            else => false,
        };
    }

    pub fn isBigInt(self: Kind) bool {
        return self == .bigint64 or self == .biguint64;
    }
};

pub const Element = struct {
    size: u32,
    kind: Kind,
};

const Entry = struct {
    name: []const u8,
    element: Element,
};

pub const concrete = [_]Entry{
    .{ .name = "Int8Array", .element = .{ .size = 1, .kind = .int8 } },
    .{ .name = "Uint8Array", .element = .{ .size = 1, .kind = .uint8 } },
    .{ .name = "Uint8ClampedArray", .element = .{ .size = 1, .kind = .uint8_clamped } },
    .{ .name = "Int16Array", .element = .{ .size = 2, .kind = .int16 } },
    .{ .name = "Uint16Array", .element = .{ .size = 2, .kind = .uint16 } },
    .{ .name = "Int32Array", .element = .{ .size = 4, .kind = .int32 } },
    .{ .name = "Uint32Array", .element = .{ .size = 4, .kind = .uint32 } },
    .{ .name = "Float16Array", .element = .{ .size = 2, .kind = .float16 } },
    .{ .name = "Float32Array", .element = .{ .size = 4, .kind = .float32 } },
    .{ .name = "Float64Array", .element = .{ .size = 8, .kind = .float64 } },
    .{ .name = "BigInt64Array", .element = .{ .size = 8, .kind = .bigint64 } },
    .{ .name = "BigUint64Array", .element = .{ .size = 8, .kind = .biguint64 } },
};

pub fn element(name: []const u8) ?Element {
    for (concrete) |entry| {
        if (std.mem.eql(u8, name, entry.name)) return entry.element;
    }
    return null;
}

pub fn nameFromKind(kind: Kind) ?[]const u8 {
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
    try testing.expectEqual(Kind.uint8, element("Uint8Array").?.kind);
    try testing.expectEqual(@as(u32, 2), element("Float16Array").?.size);
    try testing.expectEqual(Kind.biguint64, element("BigUint64Array").?.kind);
    try testing.expectEqualStrings("BigInt64Array", nameFromKind(.bigint64).?);
    try testing.expect(isConcrete("Float64Array"));
    try testing.expect(!isConcrete("TypedArray"));
    try testing.expect(element("ArrayBuffer") == null);
}

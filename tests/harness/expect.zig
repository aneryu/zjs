//! Value-shape assertions used by integration tests.

const std = @import("std");
const zjs = @import("zjs");
const core = zjs.core;

pub fn expectActiveSetStrings(object: *core.Object, comptime expected: []const []const u8) !void {
    var active_index: usize = 0;
    for (object.collectionEntriesSlot().items) |entry| {
        if (!entry.active) continue;
        try std.testing.expect(active_index < expected.len);
        try expectStringValueBytes(entry.key, expected[active_index]);
        active_index += 1;
    }
    try std.testing.expectEqual(expected.len, active_index);
}

pub fn expectStringValueBytes(value: core.JSValue, expected: []const u8) !void {
    try std.testing.expect(value.isString());
    const string = value.asStringBody().?;
    switch (string.resolveData()) {
        .latin1 => |bytes| try std.testing.expectEqualStrings(expected, bytes),
        .utf16 => |units| {
            try std.testing.expectEqual(expected.len, units.len);
            for (expected, units) |byte, unit| {
                try std.testing.expectEqual(@as(u16, byte), unit);
            }
        },
    }
}

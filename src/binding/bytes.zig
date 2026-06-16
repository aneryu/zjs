const core = @import("../core/root.zig");

pub const JSBytes = core.JSValue.Bytes;
pub const BytesError = JSBytes.Error;

test "kernel JSBytes is the core JSValue byte view" {
    const std = @import("std");
    try std.testing.expect(JSBytes == core.JSValue.Bytes);
}

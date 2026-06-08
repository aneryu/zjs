const core = @import("../core/root.zig");

pub const JSString = core.JSValue.String;

test "kernel JSString is the core JSValue string view" {
    const std = @import("std");
    try std.testing.expect(JSString == core.JSValue.String);
}

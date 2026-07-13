const std = @import("std");
const runtime = @import("runtime/root.zig");

test {
    std.testing.refAllDecls(runtime);
}

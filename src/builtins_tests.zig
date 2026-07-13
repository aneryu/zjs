const std = @import("std");
const builtins_tests = @import("tests/builtins.zig");

test {
    std.testing.refAllDecls(builtins_tests);
}

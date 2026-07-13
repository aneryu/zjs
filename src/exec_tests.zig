const std = @import("std");
const exec_tests = @import("tests/exec.zig");

test {
    std.testing.refAllDecls(exec_tests);
}

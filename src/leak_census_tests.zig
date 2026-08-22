const std = @import("std");
const exec_tests = @import("tests/exec.zig");
const builtins_tests = @import("tests/builtins.zig");

comptime {
    @import("zjs").config_signature.attest("test-leak-census");
}

test {
    std.testing.refAllDecls(exec_tests);
    std.testing.refAllDecls(builtins_tests);
}

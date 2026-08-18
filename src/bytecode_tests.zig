const std = @import("std");
const bytecode_tests = @import("tests/bytecode.zig");

// QCP-1: this artifact proves its OWN effective configuration at compile time
// (src/config_signature.zig). Every test artifact attests separately; none
// borrows the `src/all_tests.zig` root's attestation, and this one is Debug so
// it reports `optimize=Debug`.
comptime {
    @import("zjs").config_signature.attest("test-bytecode");
}

test {
    std.testing.refAllDecls(bytecode_tests);
}

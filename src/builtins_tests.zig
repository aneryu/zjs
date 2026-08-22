//! Focused test root for JavaScript builtin implementations.
const std = @import("std");
const builtins_tests = @import("tests/builtins.zig");
// QCP-1: this artifact proves its OWN effective configuration at compile time
// (src/config_signature.zig). Every test artifact attests separately; none
// borrows the `src/all_tests.zig` root's attestation, and this one is Debug so
// it reports `optimize=Debug`.
comptime {
    @import("zjs").config_signature.attest("test-builtins");
}

test {
    std.testing.refAllDecls(builtins_tests);
}

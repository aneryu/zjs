//! Focused test root for execution and VM behavior.
const std = @import("std");
const exec_tests = @import("tests/exec.zig");
// QCP-1: this artifact proves its OWN effective configuration at compile time
// (src/config_signature.zig). Every test artifact attests separately; none
// borrows the `src/all_tests.zig` root's attestation, and this one is Debug so
// it reports `optimize=Debug`.
comptime {
    @import("zjs").config_signature.attest("test-exec");
}

test {
    std.testing.refAllDecls(exec_tests);
}

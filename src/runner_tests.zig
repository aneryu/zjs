const std = @import("std");
const runner_tests = @import("cli/run_test262.zig");

// QCP-1: this artifact proves its OWN effective configuration at compile time
// (src/config_signature.zig). Every test artifact attests separately; none
// borrows the `src/all_tests.zig` root's attestation, and this one is Debug so
// it reports `optimize=Debug`.
//
// `cli/run_test262.zig` also attests the same string ("run-test262 / test-runner")
// because that file is the executable root for `run-test262` / `run-test262-dev`.
// Two attestations of the same value are harmless.
comptime {
    @import("zjs").config_signature.attest("run-test262 / test-runner");
}

test {
    std.testing.refAllDecls(runner_tests);
}

const std = @import("std");
const runtime = @import("runtime/root.zig");

// QCP-1: this artifact proves its OWN effective configuration at compile time
// (src/config_signature.zig). Every test artifact attests separately; none
// borrows the `src/all_tests.zig` root's attestation, and this one is Debug so
// it reports `optimize=Debug`.
// Imported relatively, not through the `zjs` module: this root already spans
// the engine subtree by relative path (`runtime/root.zig`), and pulling in the
// same files a second time under a module name is a "file exists in two
// modules" error.
comptime {
    @import("config_signature.zig").attest("test-runtime");
}

test {
    std.testing.refAllDecls(runtime);
}

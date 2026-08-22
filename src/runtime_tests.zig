//! Focused test root for runtime integration and plugins.
const std = @import("std");
const runtime = @import("runtime/root.zig");
// Class-A root: see docs/testing-graph.md. Attest via relative import;
// do not `@import("zjs")`.
comptime {
    @import("config_signature.zig").attest("test-runtime");
}

test {
    std.testing.refAllDecls(runtime);
}

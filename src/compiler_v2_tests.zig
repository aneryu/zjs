//! Focused test root for compiler_v2 (QCP). Class-A; see docs/testing-graph.md.
comptime {
    @import("config_signature.zig").attest("test-compiler-v2");
}

test {
    _ = @import("compiler_v2/root.zig");
}

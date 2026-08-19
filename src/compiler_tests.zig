//! Focused test root for the compiler (QCP). Class-A; see docs/testing-graph.md.
comptime {
    @import("config_signature.zig").attest("test-compiler");
}

test {
    _ = @import("compiler/root.zig");
}

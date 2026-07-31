//! Focused test root for compiler_v2 (QCP). Rooted at src/ (mirroring
//! exec_tests.zig / builtins_tests.zig) so the module subtree spans both
//! compiler_v2/ and core/ — the builder's sibling `../core/root.zig` import
//! resolves inside the module path. Used by the `test-compiler-v2` scoped
//! target (filter "compiler_v2."); checkpoint and production gates continue
//! to reach compiler_v2 through the unified all_tests root.

test {
    _ = @import("compiler_v2/root.zig");
}

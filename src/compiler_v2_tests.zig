//! Focused test root for compiler_v2 (QCP). Rooted at src/ (mirroring
//! exec_tests.zig / builtins_tests.zig) so the module subtree spans both
//! compiler_v2/ and core/ — the builder's sibling `../core/root.zig` import
//! resolves inside the module path. Used by the `test-compiler-v2` scoped
//! target (filter "compiler_v2."); checkpoint and production gates continue
//! to reach compiler_v2 through the unified all_tests root.

// QCP-1: this artifact proves its OWN effective configuration at compile time
// (src/config_signature.zig). It is also the artifact `zig build
// config-drift-gate` compiles, because its attestation covers both components
// that gate is required to drift-test: the compiler backend and the final
// bytecode layout.
// Imported relatively, not through the `zjs` module: this root already spans
// the engine subtree by relative path, and pulling in the same files a second
// time under a module name is a "file exists in two modules" error.
comptime {
    @import("config_signature.zig").attest("test-compiler-v2");
}

test {
    _ = @import("compiler_v2/root.zig");
}

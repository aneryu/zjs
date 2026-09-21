//! CLI test root. Zig collects `test` declarations from the root module
//! only, so this file pulls the colocated tests in the two CLI executable
//! files. `@import("zjs")` is the engine module (`src/root.zig`), the same
//! import the production CLI uses. Engine files never import this tree.

test {
    _ = @import("zjs.zig");
    _ = @import("run_test262.zig");
    _ = @import("run_test262_host.zig");
}

//! Tooling layer root (cli, resolver, bundler, package_manager, test_runner, transpiler, etc.).
//!
//! See docs/fun_zjs_subtree_architecture.md §3.

pub const cli = @import("cli/root.zig");
pub const resolver = @import("resolver/root.zig");
pub const transpiler = @import("transpiler/root.zig");
pub const bundler = @import("bundler/root.zig");
pub const package_manager = @import("package_manager/root.zig");
pub const test_runner = @import("test_runner/root.zig");
pub const watcher = @import("watcher/root.zig");
pub const http_server = @import("http_server/root.zig");
pub const js_validation = @import("js_validation/root.zig");

// Legacy repl placeholder (expected by the pipeline test via `pub const repl = tooling;`).
pub const ReplError = error{ReplNotImplemented};

pub fn start() ReplError!void {
    return error.ReplNotImplemented;
}

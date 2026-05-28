//! Runtime layer: owns VM, scheduler, module loader, public APIs, and N-API.
//!
//! Only src/runtime/vm/ may have deep knowledge of the zjs engine.
//!
//! See docs/fun_zjs_subtree_architecture.md §3, §4, §9–12.

pub const vm = @import("vm/root.zig");
pub const scheduler = @import("scheduler/root.zig");
pub const modules = @import("modules/root.zig");
pub const api = @import("api/root.zig");
pub const napi = @import("napi/root.zig");

pub const Runtime = @import("Runtime.zig");

// Legacy explicit placeholder surface (kept so the "pipeline placeholders are explicit"
// test in src/root.zig continues to pass unchanged).
pub const RuntimeError = error{ExecutionNotImplemented};

pub const EntryPoint = union(enum) {
    source: []const u8,
    file: []const u8,
};

pub fn execute(_: EntryPoint) RuntimeError!void {
    return error.ExecutionNotImplemented;
}

test "runtime execution is explicitly pending" {
    const std = @import("std");
    try std.testing.expectError(error.ExecutionNotImplemented, execute(.{ .source = "1 + 1" }));
}

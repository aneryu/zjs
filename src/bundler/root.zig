//! Bundler pipeline (explicitly deferred placeholder).
//!
//! Not started until after M4–M5. See docs/roadmap.md (M7).

pub const BundleError = error{
    BundlerNotImplemented,
};

pub const EntryPoint = struct {
    path: []const u8,
};

pub fn bundle(_: EntryPoint) BundleError!void {
    return error.BundlerNotImplemented;
}

test "bundler entrypoint is explicit placeholder" {
    const std = @import("std");
    try std.testing.expectError(error.BundlerNotImplemented, bundle(.{ .path = "app.ts" }));
}

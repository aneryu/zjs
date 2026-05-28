//! REPL loop (part of runtime MVP).
//!
//! Explicit placeholder. Must eventually reuse one persistent `zjs` context.
//! See docs/runtime-mvp.md.

pub const ReplError = error{
    ReplNotImplemented,
};

pub fn start() ReplError!void {
    return error.ReplNotImplemented;
}

test "repl is explicit placeholder" {
    const std = @import("std");
    try std.testing.expectError(error.ReplNotImplemented, start());
}

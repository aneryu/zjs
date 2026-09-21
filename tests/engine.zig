//! Engine integration tests pulled into the unified suite.
//!
//! Unit tests stay next to the implementation. This file only pulls
//! multi-module system tests: public API, runtime/GC, and VM/eval.
//! Zig 0.16 names these `tests.public_api.`, `tests.core.`, `tests.exec.`.
pub const public_api = @import("public_api.zig");
pub const core = @import("core.zig");
pub const exec = @import("exec.zig");

test {
    _ = public_api;
    _ = core;
    _ = exec;
}

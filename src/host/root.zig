//! Bundled host capabilities for zjs CLI, run-test262, and their tests.
//! Depends on the consumer's engine module; never imported by the engine.
pub const globals = @import("globals.zig");
pub const output = @import("output.zig");
pub const EventLoop = @import("event_loop.zig").EventLoop;
pub const file_modules = @import("file_module_loader.zig");

test {
    _ = @import("event_loop.zig");
    _ = file_modules;
}

// Zig test collection is rooted in the consuming module. The unified root
// invokes these private-source checks through tests/host.zig explicitly.
pub const testing = if (@import("builtin").is_test) struct {
    pub const event_loop = @import("event_loop.zig").tests;
    pub const output = @import("output.zig").tests;
    pub const file_modules = @import("file_module_loader.zig").tests;
} else struct {};

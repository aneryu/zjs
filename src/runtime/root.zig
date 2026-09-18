//! Host event-loop surface for embedders, CLI, and test262.
pub const EventLoop = @import("event_loop.zig").EventLoop;
pub const EventLoopOptions = @import("event_loop.zig").Options;
pub const EventLoopRunResult = @import("event_loop.zig").RunResult;
pub const runUntilIdle = @import("event_loop.zig").runUntilIdle;

test {
    _ = @import("event_loop.zig");
}

test "runtime namespace does not expose internals or kernel primitives" {
    const std = @import("std");

    try std.testing.expect(!@hasDecl(@This(), "event_loop"));
    try std.testing.expect(!@hasDecl(@This(), "cleanup"));
    try std.testing.expect(!@hasDecl(@This(), "modules"));
    try std.testing.expect(!@hasDecl(@This(), "plugin"));
    try std.testing.expect(!@hasDecl(@This(), "buffer"));

    try std.testing.expect(!@hasDecl(@This(), "Engine"));
    try std.testing.expect(!@hasDecl(@This(), "JSRuntime"));
    try std.testing.expect(!@hasDecl(@This(), "JSContext"));
    try std.testing.expect(!@hasDecl(@This(), "JSValue"));
    try std.testing.expect(!@hasDecl(@This(), "Object"));
    try std.testing.expect(!@hasDecl(@This(), "binding"));
    try std.testing.expect(!@hasDecl(@This(), "ffi"));
}

const runtime = @import("root.zig");

pub const EventLoop = runtime.EventLoop;
pub const EventLoopOptions = runtime.EventLoopOptions;
pub const EventLoopRunResult = runtime.EventLoopRunResult;
pub const runUntilIdle = runtime.runUntilIdle;
pub const cleanupAtomicsWaitersForContext = runtime.cleanupAtomicsWaitersForContext;
pub const wakeAtomicsWaitersForRuntimes = runtime.wakeAtomicsWaitersForRuntimes;
pub const detachArrayBuffer = runtime.detachArrayBuffer;
pub const evalFileModuleGraphWithOutput = runtime.evalFileModuleGraphWithOutput;
pub const resolveModuleSpecifier = runtime.resolveModuleSpecifier;
pub const Plugin = runtime.Plugin;
pub const PluginInstallOptions = runtime.PluginInstallOptions;

test {
    _ = EventLoop;
    _ = EventLoopOptions;
    _ = EventLoopRunResult;
    _ = runUntilIdle;
    _ = cleanupAtomicsWaitersForContext;
    _ = wakeAtomicsWaitersForRuntimes;
    _ = detachArrayBuffer;
    _ = evalFileModuleGraphWithOutput;
    _ = resolveModuleSpecifier;
    _ = Plugin;
    _ = PluginInstallOptions;
}

test "public runtime namespace does not expose internals or kernel primitives" {
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

pub const event_loop = @import("event_loop.zig");

pub const EventLoop = event_loop.EventLoop;
pub const EventLoopOptions = event_loop.Options;
pub const EventLoopRunResult = event_loop.RunResult;
pub const runUntilIdle = event_loop.runUntilIdle;

test {
    _ = event_loop;
}

//! Host time for event-loop deadlines and opt-in engine diagnostics.
const std = @import("std");
const zjs = @import("zjs");

pub fn monotonicNanos() u64 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const nanos = std.Io.Clock.Timestamp.now(io, .awake).raw.toNanoseconds();
    return if (nanos <= 0) 0 else @intCast(nanos);
}

fn diagnosticNanos(_: ?*anyopaque) u64 {
    return monotonicNanos();
}

pub const diagnostic_clock: zjs.Runtime.DiagnosticClock = .{ .nowNanos = diagnosticNanos };

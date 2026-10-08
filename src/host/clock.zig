//! Host time for event-loop deadlines and opt-in engine diagnostics.
const std = @import("std");
const zjs = @import("zjs");

/// The host's single-threaded Io, used for clocks and timer sleeps.
pub fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

pub fn monotonicNanos() u64 {
    const nanos = std.Io.Clock.Timestamp.now(io(), .awake).raw.toNanoseconds();
    return if (nanos <= 0) 0 else @intCast(nanos);
}

/// Wall-clock time since the Unix epoch.
pub fn realNanos() i96 {
    return std.Io.Clock.Timestamp.now(io(), .real).raw.toNanoseconds();
}

fn diagnosticNanos(_: ?*anyopaque) u64 {
    return monotonicNanos();
}

pub const diagnostic_clock: zjs.Runtime.DiagnosticClock = .{ .nowNanos = diagnosticNanos };

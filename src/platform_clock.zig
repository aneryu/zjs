//! Cross-platform monotonic-clock helpers for diagnostics and timing.
const std = @import("std");
fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

/// Cross-platform CLOCK_MONOTONIC equivalent used for diagnostics and elapsed
/// time accounting. `awake` maps to CLOCK_MONOTONIC on Linux and the native
/// monotonic clock on Windows and macOS.
pub fn monotonicNanos() u64 {
    const nanos = std.Io.Clock.Timestamp.now(io(), .awake).raw.toNanoseconds();
    return if (nanos <= 0) 0 else @intCast(nanos);
}

/// Nanoseconds elapsed since `start`, saturating at zero. A monotonic clock
/// can still read backwards across a suspend/resume boundary; every caller
/// wanted the clamp, and three of them wrote it out.
pub fn elapsedNanosSince(start: u64) u64 {
    const end = monotonicNanos();
    return if (end > start) end - start else 0;
}

/// Cross-platform wall clock in microseconds since the Unix epoch.
pub fn realtimeMicros() i64 {
    return std.Io.Clock.Timestamp.now(io(), .real).raw.toMicroseconds();
}

test "platform clocks expose usable monotonic and realtime values" {
    const first = monotonicNanos();
    const second = monotonicNanos();
    try std.testing.expect(second >= first);
    try std.testing.expect(realtimeMicros() > 0);
}

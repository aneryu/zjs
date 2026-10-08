//! Interrupt polling, termination requests, and host blocking for one
//! Runtime (`JSRuntime.interrupt`, `JSRuntime.host_wait`).
//!
//! The host handler, the cross-thread termination flag, and the poll
//! countdowns live together so every poll site runs one rule: termination
//! first, then the handler. The public `setInterruptHandler`,
//! `terminateExecution`, and `cancelTerminateExecution` stay on JSRuntime.

const std = @import("std");
const runtime_mod = @import("../runtime.zig");
const JSRuntime = runtime_mod.JSRuntime;

pub const Handler = *const fn (*JSRuntime, ?*anyopaque) bool;

/// Host interrupt callback and its borrowed context.
pub const Hook = struct {
    handler: Handler,
    context: ?*anyopaque,
};

/// Iterations a long native loop runs between interrupt polls.
pub const native_poll_interval: u32 = 4096;

/// Bytes a bulk step (copy, fill, scan, compare) does per unit of
/// `pollNativeWork`'s countdown: one interval is about 256 KiB.
pub const native_bulk_bytes_per_unit = 64;

pub const State = struct {
    hook: ?Hook = null,
    /// Set from any thread; the owner observes it at its next poll.
    termination_requested: std.atomic.Value(bool) = .init(false),
    /// Native-loop iterations left until the next poll, shared by every
    /// native loop (`pollNativeWork`).
    native_countdown: u32 = native_poll_interval,
    /// The regexp executor's poll countdown, shared by every match.
    regexp_countdown: i32 = 10_000,

    fn runtime(self: *State) *JSRuntime {
        return @alignCast(@fieldParentPtr("interrupt", self));
    }

    pub fn isTerminating(self: *const State) bool {
        return self.termination_requested.load(.acquire);
    }

    /// Whether a poll can stop execution: a handler is installed or
    /// termination was requested.
    pub fn mayInterrupt(self: *const State) bool {
        return self.hook != null or self.isTerminating();
    }

    /// One interrupt poll: true when execution must stop.
    pub fn poll(self: *State) bool {
        if (self.isTerminating()) return true;
        const hook = self.hook orelse return false;
        return hook.handler(self.runtime(), hook.context);
    }

    /// The interrupt poll of a long native loop or of code that sees only
    /// the runtime (a parser, a numeric library). Every
    /// `native_poll_interval` calls it polls; a stop request returns a bare
    /// `error.Interrupted`, which the builtin seam
    /// (`materializeRuntimeError`) or `exception_ops.raiseBareInterrupt`
    /// turns into the uncatchable InternalError.
    pub inline fn pollNativeWork(self: *State) error{Interrupted}!void {
        self.native_countdown -= 1;
        if (self.native_countdown != 0) return;
        self.native_countdown = native_poll_interval;
        if (self.poll()) return error.Interrupted;
    }

    /// `pollNativeWork` for a bulk step over `bytes` bytes: it uses up its
    /// share of the countdown, so a loop of large copies or scans polls as
    /// often as a loop of small iterations.
    pub fn pollNativeBulkWork(self: *State, bytes: usize) error{Interrupted}!void {
        const units = bytes / native_bulk_bytes_per_unit;
        if (units < self.native_countdown) {
            self.native_countdown -= @intCast(units);
            return;
        }
        self.native_countdown = native_poll_interval;
        if (self.poll()) return error.Interrupted;
    }
};

/// Whether this Runtime's thread may block (`Atomics.wait`), and the
/// cross-thread, allocation-free wake signal for host completions consumed
/// on the owner thread. Atomics.waitAsync is the first producer; the signal
/// carries no JS state and is reset only while the producer registry mutex
/// excludes a lost-wakeup race.
pub const HostWait = struct {
    can_block: bool = false,
    completion: std.Io.Event = .unset,

    pub fn signal(self: *HostWait, io: std.Io) void {
        self.completion.set(io);
    }

    pub fn reset(self: *HostWait) void {
        self.completion.reset();
    }

    pub fn wait(self: *HostWait, io: std.Io) void {
        self.completion.waitUncancelable(io);
    }

    /// False when the deadline passed (or the wait was canceled) first.
    pub fn waitUntil(self: *HostWait, io: std.Io, deadline: std.Io.Timestamp) bool {
        self.completion.waitTimeout(io, .{ .deadline = deadline.withClock(.awake) }) catch |err| switch (err) {
            error.Timeout, error.Canceled => return false,
        };
        return true;
    }
};

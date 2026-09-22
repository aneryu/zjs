//! JS heap budget. Block cells and published extent/standalone cells charge
//! it; nursery cells, ordinary native bytes, external tokens, and RSS do not.
//! The byte count is the one publication already passes
//! (`accountedBodyBytesForRequest` or `heapByteSizeFromHeader`). This is not
//! a second scan and not a count times a fixed size.
//!
//! `limit` rejects a prospective charge. `gc_threshold` is the separate
//! growth bar the collector compares against `bytes`. Neither field is
//! stored again on the account.

const std = @import("std");

pub const Budget = struct {
    bytes: usize = 0,
    cycle_peak_output: ?*usize = null,
    limit: ?usize = null,
    gc_threshold: usize = 0,
    /// One production callee: `JSRuntime.retryHeapLimitOnce`. A second
    /// admission while it runs fails instead of collecting again.
    retry: ?*const fn (*anyopaque) void = null,
    retry_ctx: ?*anyopaque = null,
    retrying: bool = false,
    suppress_retry: bool = false,
    /// Skips the test/force per-allocation notify. Not a heap-limit retry.
    suspend_alloc_notify: bool = false,
    owner_notify: ?*const fn (?*anyopaque, usize) void = null,
    owner_ctx: ?*anyopaque = null,
    probe: ?*const fn (?*anyopaque, usize) void = null,
    probe_ctx: ?*anyopaque = null,
    limit_retries: usize = 0,

    pub fn charge(self: *Budget, n: usize) void {
        self.bytes +|= n;
        if (self.cycle_peak_output) |peak| peak.* = @max(peak.*, self.bytes);
    }

    pub fn beginCyclePeakTracking(self: *Budget, output: *usize) void {
        std.debug.assert(self.cycle_peak_output == null);
        output.* = self.bytes;
        self.cycle_peak_output = output;
    }

    pub fn endCyclePeakTracking(self: *Budget) void {
        self.cycle_peak_output = null;
    }

    pub fn discharge(self: *Budget, n: usize) void {
        if (comptime std.debug.runtime_safety) {
            std.debug.assert(self.bytes >= n);
        }
        self.bytes -|= n;
    }

    /// Check only. Native caps and `NoTrigger` heap allocations use this so
    /// they cannot collect.
    pub fn checkOnly(self: *const Budget, extra: usize) !void {
        const limit = self.limit orelse return;
        if (!fits(self.bytes, extra, limit)) return error.OutOfMemory;
    }

    /// One protected retry, then `error.OutOfMemory` if the charge still
    /// does not fit. `retrying` is the reentrancy guard and the exit.
    pub fn admit(self: *Budget, extra: usize) !void {
        const limit = self.limit orelse return;
        if (fits(self.bytes, extra, limit)) return;
        if (self.suppress_retry or self.retrying) return error.OutOfMemory;
        const retry = self.retry orelse return error.OutOfMemory;
        const ctx = self.retry_ctx orelse return error.OutOfMemory;
        self.retrying = true;
        self.limit_retries +|= 1;
        defer self.retrying = false;
        retry(ctx);
        // Reentrant host cleanup may have changed or removed the limit.
        try self.checkOnly(extra);
    }
};

fn fits(used: usize, extra: usize, limit: usize) bool {
    const next = std.math.add(usize, used, extra) catch return false;
    return next <= limit;
}

test "heap budget admits exact fit, rejects one byte over, and retries once" {
    var budget = Budget{};
    try budget.admit(50);
    budget.charge(50);
    budget.limit = 50;
    try budget.admit(0);
    try budget.checkOnly(0);
    try std.testing.expectError(error.OutOfMemory, budget.checkOnly(1));
    try std.testing.expectError(error.OutOfMemory, budget.admit(1));

    const Collect = struct {
        fn freeAll(ctx: *anyopaque) void {
            const self: *Budget = @ptrCast(@alignCast(ctx));
            self.discharge(self.bytes);
        }
    };
    budget.retry = Collect.freeAll;
    budget.retry_ctx = &budget;
    try budget.admit(50);
    try std.testing.expectEqual(@as(usize, 0), budget.bytes);
    try std.testing.expectEqual(@as(usize, 1), budget.limit_retries);

    const Nest = struct {
        budget: *Budget,
        hits: usize = 0,
        fn run(ctx: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.hits +|= 1;
            // 40 bytes are live under a limit of 50, and `retrying` is set.
            // A charge that fits returns; one that does not must fail here
            // instead of calling this function again.
            self.budget.admit(20) catch {
                self.hits +|= 10;
            };
        }
    };
    var nest = Nest{ .budget = &budget };
    budget.charge(40);
    budget.retry = Nest.run;
    budget.retry_ctx = &nest;
    const before = budget.limit_retries;
    try std.testing.expectError(error.OutOfMemory, budget.admit(20));
    try std.testing.expectEqual(before + 1, budget.limit_retries);
    try std.testing.expectEqual(@as(usize, 11), nest.hits);
    try std.testing.expectEqual(@as(usize, 40), budget.bytes);
}

test "runtime review heap retry uses the current limit after callback" {
    const Change = struct {
        budget: *Budget,
        next_limit: ?usize,
        fn retry(raw: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.budget.discharge(10);
            self.budget.limit = self.next_limit;
        }
    };
    var budget = Budget{ .bytes = 40, .limit = 50, .retry = Change.retry };
    var change = Change{ .budget = &budget, .next_limit = 30 };
    budget.retry_ctx = &change;
    try std.testing.expectError(error.OutOfMemory, budget.admit(20));
    budget.bytes = 40;
    budget.limit = 50;
    change.next_limit = 100;
    try budget.admit(30);
    budget.bytes = 40;
    budget.limit = 50;
    change.next_limit = null;
    try budget.admit(30);
}

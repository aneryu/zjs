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
    /// Set while `admit`'s one collection runs: a nested admission that does
    /// not fit fails instead of collecting again.
    retrying: bool = false,
    suppress_retry: bool = false,
    /// Skips the test/force per-allocation notify. Not a heap-limit retry.
    /// Change it through `suspendAllocNotify` / `restoreAllocNotify`.
    suspend_alloc_notify: bool = false,
    /// Test builds: replaces the per-allocation notify. Change it through
    /// `installProbe` / `restoreProbe`.
    probe: ?Probe = null,
    limit_retries: usize = 0,
    /// Fault-injection seam: replaces the heap-limit collection so a fixture
    /// can act at the exact retry point. Read only on the cold retry path;
    /// the exact-roots contract executable (a non-test build) uses it.
    retry_override: ?RetryOverride = null,

    pub const Probe = struct {
        run: *const fn (?*anyopaque, usize) void,
        context: ?*anyopaque,
    };

    /// Install `probe` (or none); returns the probe to restore.
    pub fn installProbe(self: *Budget, probe: ?Probe) ?Probe {
        const previous = self.probe;
        self.probe = probe;
        return previous;
    }

    pub fn restoreProbe(self: *Budget, previous: ?Probe) void {
        self.probe = previous;
    }

    /// Stop allocation notifies (and probes) for a native step that must not
    /// collect, such as growing a root table; returns the state to restore.
    pub fn suspendAllocNotify(self: *Budget) bool {
        const previous = self.suspend_alloc_notify;
        self.suspend_alloc_notify = true;
        return previous;
    }

    pub fn restoreAllocNotify(self: *Budget, previous: bool) void {
        self.suspend_alloc_notify = previous;
    }

    pub const RetryOverride = struct {
        context: *anyopaque,
        collect: *const fn (*anyopaque) void,
    };

    /// Test builds: deliver an allocation event to the installed probe with
    /// nested notifies suspended, so a probe that allocates or collects is
    /// never re-entered. Returns false when no probe is installed.
    pub fn runProbe(self: *Budget, bytes: usize) bool {
        const probe = self.probe orelse return false;
        if (self.suspend_alloc_notify) return true;
        self.suspend_alloc_notify = true;
        defer self.suspend_alloc_notify = false;
        probe.run(probe.context, bytes);
        return true;
    }

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

    /// Check a prospective heap charge without collecting or reserving bytes.
    /// Used by `NoTrigger` GC allocations; native diagnostic caps are separate.
    pub fn checkOnly(self: *const Budget, extra: usize) !void {
        const limit = self.limit orelse return;
        if (!fits(self.bytes, extra, limit)) return error.OutOfMemory;
    }

    /// Check admission with at most one protected retry, then error.OutOfMemory
    /// if the charge still does not fit. Does not reserve or charge bytes.
    /// `collector.collect()` runs the one retry (production:
    /// `gc_driver.HeapLimitRetry`); `retrying` prevents another collection
    /// during a nested admission.
    pub fn admit(self: *Budget, extra: usize, collector: anytype) error{OutOfMemory}!void {
        const limit = self.limit orelse return;
        if (fits(self.bytes, extra, limit)) return;
        if (self.suppress_retry or self.retrying) return error.OutOfMemory;
        self.retrying = true;
        self.limit_retries +|= 1;
        defer self.retrying = false;
        collector.collect();
        // Reentrant host cleanup may have changed or removed the limit.
        try self.checkOnly(extra);
    }
};

fn fits(used: usize, extra: usize, limit: usize) bool {
    const next = std.math.add(usize, used, extra) catch return false;
    return next <= limit;
}

test "heap budget admits exact fit, rejects one byte over, and retries once" {
    const NoCollect = struct {
        fn collect(_: @This()) void {}
    };
    var budget = Budget{};
    try budget.admit(50, NoCollect{});
    budget.charge(50);
    budget.limit = 50;
    try budget.admit(0, NoCollect{});
    try budget.checkOnly(0);
    try std.testing.expectError(error.OutOfMemory, budget.checkOnly(1));

    const FreeAll = struct {
        budget: *Budget,
        fn collect(self: @This()) void {
            self.budget.discharge(self.budget.bytes);
        }
    };
    try budget.admit(50, FreeAll{ .budget = &budget });
    try std.testing.expectEqual(@as(usize, 0), budget.bytes);
    try std.testing.expectEqual(@as(usize, 1), budget.limit_retries);

    const Nest = struct {
        budget: *Budget,
        hits: usize = 0,
        fn collect(self: *@This()) void {
            self.hits +|= 1;
            // 40 bytes are live under a limit of 50, and `retrying` is set.
            // A charge that fits returns; one that does not must fail here
            // instead of calling this function again.
            self.budget.admit(20, self) catch {
                self.hits +|= 10;
            };
        }
    };
    var nest = Nest{ .budget = &budget };
    budget.charge(40);
    const before = budget.limit_retries;
    try std.testing.expectError(error.OutOfMemory, budget.admit(20, &nest));
    try std.testing.expectEqual(before + 1, budget.limit_retries);
    try std.testing.expectEqual(@as(usize, 11), nest.hits);
    try std.testing.expectEqual(@as(usize, 40), budget.bytes);
}

test "runtime review heap retry uses the current limit after callback" {
    const Change = struct {
        budget: *Budget,
        next_limit: ?usize,
        fn collect(self: *@This()) void {
            self.budget.discharge(10);
            self.budget.limit = self.next_limit;
        }
    };
    var budget = Budget{ .bytes = 40, .limit = 50 };
    var change = Change{ .budget = &budget, .next_limit = 30 };
    try std.testing.expectError(error.OutOfMemory, budget.admit(20, &change));
    budget.bytes = 40;
    budget.limit = 50;
    change.next_limit = 100;
    try budget.admit(30, &change);
    budget.bytes = 40;
    budget.limit = 50;
    change.next_limit = null;
    try budget.admit(30, &change);
}

//! When a major collection runs, and under what policy.
//!
//! Two scalars and a request slot. The request slot is a *latch*, not a
//! queue: at most one major can be pending, and a second request either
//! upgrades its urgency or refines its reason. The major phase is the
//! collector's own state machine (idle -> mark_roots -> sweep -> idle), kept
//! apart from `Registry.hot.phase`, which is the much coarser thing every
//! JSValue release reads.
//!
//! Nothing here touches the heap, so the whole group is decidable from
//! policy plus the request latch. The two predicates that also need live
//! byte counts (`externalMemoryRequestReason`, `shouldTryMinor`) stay on the
//! Registry, where the statistics block is.

const std = @import("std");
const gc = @import("gc.zig");

const Policy = gc.Policy;
const MajorPhase = gc.MajorPhase;
const Request = gc.Request;
const RequestReason = gc.RequestReason;
const RequestUrgency = gc.RequestUrgency;
const SchedulerPoint = gc.SchedulerPoint;
const PressureRequest = gc.PressureRequest;

pub const Scheduler = struct {
    policy: Policy = .{},
    major_phase: MajorPhase = .idle,
    major_reason: ?RequestReason = null,
    major_request: Request = .{},

    /// Set only around `JSRuntime.deinit`'s teardown collections. The host has
    /// by contract released every handle and no mutator frame is live, so those
    /// collections are entitled to the precise root scan that
    /// `runObjectCycleRemovalWithValueRoots` already asks for -- production
    /// otherwise forces the conservative pass, and a stale native-stack slot
    /// pointing at a host-released Realm keeps it marked, which breaks the
    /// `context_head == null` teardown invariant once the tracer rather than
    /// refcounting owns object lifetime.
    host_quiescent: bool = false,

    pub fn processMemoryRequest(self: Scheduler, rss_bytes: usize, cgroup_limit_bytes: usize) ?PressureRequest {
        if (self.policy.rss_hard_limit) |limit| {
            if (rss_bytes >= limit) return .{ .reason = .rss_pressure, .urgency = .urgent };
        }
        if (self.policy.cgroup_hard_ratio_per_mille != 0 and cgroup_limit_bytes != 0 and gc.ratioPerMille(rss_bytes, cgroup_limit_bytes) >= self.policy.cgroup_hard_ratio_per_mille) {
            return .{ .reason = .rss_pressure, .urgency = .urgent };
        }
        if (self.policy.rss_soft_limit) |limit| {
            if (rss_bytes >= limit) return .{ .reason = .rss_pressure, .urgency = .soon };
        }
        if (self.policy.cgroup_soft_ratio_per_mille != 0 and cgroup_limit_bytes != 0 and gc.ratioPerMille(rss_bytes, cgroup_limit_bytes) >= self.policy.cgroup_soft_ratio_per_mille) {
            return .{ .reason = .rss_pressure, .urgency = .soon };
        }
        return null;
    }

    /// Latch a major request, or strengthen the one already latched.
    pub fn request(self: *Scheduler, reason: RequestReason, urgency: RequestUrgency) void {
        const slot = &self.major_request;
        if (!slot.pending) {
            slot.* = .{
                .pending = true,
                .reason = reason,
                .urgency = urgency,
            };
            return;
        }
        if (urgency == .urgent and slot.urgency != .urgent) {
            slot.urgency = .urgent;
            slot.reason = reason;
            return;
        }
        // An allocation-threshold request is level-triggered: the live-byte
        // condition may disappear before the next scheduler boundary. Do not
        // let that weak request hide an independently requested same-urgency
        // collection, because the allocation boundary may later discard only
        // the stale threshold request.
        if (slot.reason == .allocation_threshold and reason != .allocation_threshold) {
            slot.reason = reason;
            return;
        }
        if (slot.reason == null) slot.reason = reason;
    }

    pub fn hasPendingMajorRequest(self: Scheduler) bool {
        return self.major_request.pending;
    }

    pub fn pendingMajorRequest(self: Scheduler) ?Request {
        return if (self.major_request.pending) self.major_request else null;
    }

    pub fn clearMajorRequest(self: *Scheduler) ?Request {
        if (!self.major_request.pending) return null;
        const pending = self.major_request;
        self.major_request = .{};
        return pending;
    }

    /// Is the pending major request the collector pacing itself off the
    /// allocation threshold -- exactly the request
    /// `clearStaleAllocationThresholdRequest` is willing to discard?
    ///
    /// A threshold crossing is usually REPORTED rather than observed: the
    /// allocation boundary tests `allocated_bytes + size` and records the
    /// request before the allocation lands, so the poll it then makes can read
    /// its own account as still under the bar. A scheduler that wants to act
    /// on crossings has to accept both forms.
    pub fn pendingAllocationThresholdRequest(self: Scheduler) bool {
        const pending = self.pendingMajorRequest() orelse return false;
        return pending.reason == .allocation_threshold and pending.urgency == .soon;
    }

    pub fn clearStaleAllocationThresholdRequest(self: *Scheduler) bool {
        const pending = self.pendingMajorRequest() orelse return false;
        if (pending.reason != .allocation_threshold or pending.urgency != .soon) return false;
        self.major_request = .{};
        return true;
    }

    pub fn shouldRunMajorAt(self: Scheduler, point: SchedulerPoint, over_threshold: bool) bool {
        if (point == .urgent or over_threshold) return true;
        const pending = self.pendingMajorRequest() orelse return false;
        return switch (point) {
            .allocation_slow_path, .idle => true,
            .callback_boundary, .safepoint => pending.urgency == .urgent,
            .urgent => true,
        };
    }

    pub fn beginMajorCycle(self: *Scheduler, reason: RequestReason) void {
        if (self.major_phase != .idle) {
            if (self.major_reason == null) self.major_reason = reason;
            return;
        }
        self.major_phase = .mark_roots;
        self.major_reason = reason;
    }

    pub fn setMajorPhase(self: *Scheduler, phase: MajorPhase) void {
        if (self.major_phase == .idle and phase != .idle) return;
        self.major_phase = phase;
    }

    pub fn activeMajorReason(self: Scheduler) ?RequestReason {
        return self.major_reason;
    }

    pub fn abortMajorCycle(self: *Scheduler) void {
        self.major_phase = .idle;
        self.major_reason = null;
    }

    pub fn finishMajorCycle(self: *Scheduler) void {
        self.major_phase = .idle;
        self.major_reason = null;
    }
};

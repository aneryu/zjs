//! Concurrent-major state: the target-shading barrier and the handshake that
//! makes it sound (§8.4, §7.4).
//!
//! The barrier is incremental-update and shades the *exact new target* of a
//! strong write. It deliberately reads no owner colour and keeps no
//! owner-rescan bit: a write through an unreachable owner may preserve
//! floating garbage for the cycle, which is the price of not paying for owner
//! state on every store.
//!
//! What makes it correct is not the shading alone but its pairing with the
//! safepoint protocol. The heap store and the shading happen inside one
//! `BarrierCriticalScope`, and a mutator may not acknowledge a safepoint
//! while inside one. Final remark therefore cannot stop the mutator *between*
//! a store and its shading, which is the only interleaving that could hide a
//! reference from the marker.

const std = @import("std");
const gc = @import("gc.zig");

pub const Stats = struct {
    shaded: usize = 0,
    barrier_calls: usize = 0,
    /// Times a mutator observed a safepoint request while inside a critical
    /// scope and had to finish the scope first. A high count means scopes are
    /// too coarse and time-to-safepoint suffers (§1.3's latency row).
    deferred_acks: usize = 0,
    critical_depth_max: usize = 0,
};

pub const State = struct {
    /// Only changes while the runtime is stopped (§8.4), so a plain acquire
    /// load is enough on the mutator side.
    major_marking_active: std.atomic.Value(bool) = .init(false),
    /// Set by the controller, observed at polls. A mutator that sees it must
    /// still finish any open critical scope before parking.
    safepoint_requested: std.atomic.Value(bool) = .init(false),
    critical_depth: usize = 0,
    stats: Stats = .{},

    pub fn markingActive(self: *const State) bool {
        return self.major_marking_active.load(.acquire);
    }

    /// Enter the region in which a store and its shading are indivisible with
    /// respect to safepoints.
    pub fn enterCritical(self: *State) void {
        self.critical_depth += 1;
        if (self.critical_depth > self.stats.critical_depth_max) {
            self.stats.critical_depth_max = self.critical_depth;
        }
    }

    pub fn leaveCritical(self: *State) void {
        std.debug.assert(self.critical_depth > 0);
        self.critical_depth -= 1;
    }

    /// Whether this mutator may acknowledge a safepoint right now. Inside a
    /// critical scope the answer is no, and the caller must poll again after
    /// the scope closes -- that deferral is exactly what keeps final remark
    /// from bisecting a store/shade pair.
    pub fn mayAcknowledgeSafepoint(self: *State) bool {
        if (self.critical_depth != 0) {
            self.stats.deferred_acks += 1;
            return false;
        }
        return true;
    }
};

/// The `BarrierCriticalScope` of §8.4, as an RAII pair.
pub const CriticalScope = struct {
    state: *State,

    pub fn begin(state: *State) CriticalScope {
        state.enterCritical();
        return .{ .state = state };
    }

    pub fn end(self: CriticalScope) void {
        self.state.leaveCritical();
    }
};

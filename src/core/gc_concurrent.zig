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

    /// Stage 6 reporting rows (§13). Each is measured rather than estimated
    /// because the design asks for them by name.
    ///
    /// Work the mutator did on the marker's behalf when allocation outran
    /// marking. High assist time means the marker is losing the race and the
    /// mutator is paying for it — the number a throughput claim has to
    /// disclose.
    assist_batches: usize = 0,
    assist_marked: usize = 0,
    assist_ns_total: u64 = 0,
    /// Objects that stayed marked at the end of a cycle without being
    /// reachable — the cost of an incremental-update barrier that shades
    /// through owners which may themselves be dead (§8.4).
    floating_garbage: usize = 0,
    /// Objects handed to the owner thread because the marker could not take
    /// them (mutator-only types, exhausted snapshots).
    bailouts: usize = 0,
    /// Incremental cycles completed, and the marking increments they took.
    cycles_completed: usize = 0,
    cycles_aborted: usize = 0,
    increments: usize = 0,
    /// STW slices of the LAST completed cycle: begin + increments + remark,
    /// summed. §1.3's "cumulative major STW per cycle" row.
    last_cycle_stw_ns: u64 = 0,
    max_cycle_stw_ns: u64 = 0,
    /// The cycle finished early because allocation outran marking past the
    /// safety valve, forcing a full-drain finish in one pause.
    forced_finishes: usize = 0,
    /// Request-to-acknowledge latency at safepoints (§1.3's row).
    safepoint_wait_ns_total: u64 = 0,
    safepoint_wait_ns_max: u64 = 0,
    safepoint_acks: usize = 0,
};

pub const State = struct {
    /// Only changes while the runtime is stopped (§8.4), so a plain acquire
    /// load is enough on the mutator side.
    major_marking_active: std.atomic.Value(bool) = .init(false),
    /// Set by the controller, observed at polls. A mutator that sees it must
    /// still finish any open critical scope before parking.
    safepoint_requested: std.atomic.Value(bool) = .init(false),
    critical_depth: usize = 0,
    /// Running STW accumulator for the open cycle; drained into
    /// `stats.last_cycle_stw_ns` at completion.
    cycle_stw_ns: u64 = 0,
    stats: Stats = .{},

    pub fn markingActive(self: *const State) bool {
        // `.monotonic`, deliberately, and this is the write barrier's hot
        // path: `.acquire` compiles to an `ldar` on aarch64, and the barrier
        // runs tens of millions of times per benchmark (55.8M on
        // earley-boyer). Today there is exactly one thread -- marking is
        // driven to completion on the owner -- so there is no ordering to
        // acquire. When a real marker thread lands, this becomes JSC's
        // threshold protocol: a plain byte the collector rewrites at phase
        // boundaries with the world stopped, fences only in the slow path
        // (HeapInlines.h:106, Heap.cpp:2871).
        return self.major_marking_active.load(.monotonic);
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

    /// Record how long a safepoint request waited to be acknowledged. The
    /// design's latency row is about the tail, so the maximum is kept
    /// alongside the total -- a good mean with a bad maximum is exactly the
    /// shape a pause target is meant to catch.
    pub fn noteSafepointAck(self: *State, waited_ns: u64) void {
        self.stats.safepoint_acks += 1;
        self.stats.safepoint_wait_ns_total += waited_ns;
        if (waited_ns > self.stats.safepoint_wait_ns_max) {
            self.stats.safepoint_wait_ns_max = waited_ns;
        }
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

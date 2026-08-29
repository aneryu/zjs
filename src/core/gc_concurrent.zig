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
    /// Barrier exits are mutually exclusive and, together with `shaded`,
    /// add back to `barrier_calls`. Keep the split: a marked-target hit is a
    /// cheap deduplication success, while unpublished exits and owner requeue
    /// point at different correctness mechanisms.
    barrier_marked_target: usize = 0,
    barrier_unpublished_owner: usize = 0,
    barrier_unpublished_target: usize = 0,
    barrier_requeued_owner: usize = 0,
    /// Times a mutator observed a safepoint request while inside a critical
    /// scope and had to finish the scope first. A high count means scopes are
    /// too coarse and time-to-safepoint suffers (§1.3's latency row).
    deferred_acks: usize = 0,
    /// Incremental cycles completed, and the marking increments they took.
    cycles_completed: usize = 0,
    cycles_aborted: usize = 0,
    increments: usize = 0,
    /// Total STW of the last completed cycle across all of its pauses.
    last_cycle_stw_ns: u64 = 0,
    /// Cumulative stop-the-world nanoseconds by attributed phase, over the whole
    /// run. The per-cycle total answers §1.3's row; this answers "which
    /// phase owns the stopped time", which is the question a decision about
    /// concurrent marking turns on.
    total_stw_by_kind: [4]u64 = @splat(0),
    total_segments_by_kind: [4]u64 = @splat(0),
    max_cycle_stw_ns: u64 = 0,
    /// The cycle finished early because allocation outran marking past the
    /// safety valve, forcing a full-drain finish in one pause.
    forced_finishes: usize = 0,
    /// Same-domain §1.3 envelope. The raw tuple is the one completed cycle
    /// with the largest P/T; retaining one coherent tuple avoids the invalid
    /// alternative of independently maximizing S, T and P across cycles.
    envelope_measured_cycles: usize = 0,
    envelope_skipped_cycles: usize = 0,
    envelope_max_start_bytes: usize = 0,
    envelope_max_threshold_bytes: usize = 0,
    envelope_max_begin_bytes: usize = 0,
    envelope_max_peak_bytes: usize = 0,
    /// Cumulative morgue accounting. `doomed_destroyed_objects` follows the
    /// public freed-object convention and therefore excludes bytecode nodes;
    /// `doomed_condemned_headers` counts every condemned GC node. Parked
    /// entries are the second, physical-free pass after destructors.
    doomed_condemned_headers: usize = 0,
    doomed_destroyed_objects: usize = 0,
    doomed_parked_entries_drained: usize = 0,
    doomed_parked_drain_slices: usize = 0,
    /// Worst attributed phase segment: begin, increment, destroy, finish.
    /// A final poll has both increment and finish segments but is one pause.
    segment_max_ns: [4]u64 = @splat(0),

    /// Cumulative phase attribution, owned by this Registry. These used to
    /// live in a process-global `last_finish_phases`, so two runtimes silently
    /// contaminated one another's panel.
    phase_begin_clear_ns: u64 = 0,
    phase_begin_precise_seed_ns: u64 = 0,
    phase_begin_conservative_seed_ns: u64 = 0,
    phase_begin_retire_ns: u64 = 0,
    phase_finish_remark_ns: u64 = 0,
    /// Subset of `phase_finish_remark_ns`, printed as such.
    phase_finish_conservative_seed_ns: u64 = 0,
    phase_finish_weak_ns: u64 = 0,
    phase_finish_condemn_ns: u64 = 0,
    phase_retired_nonblock_headers: usize = 0,
    phase_retired_young_blocks: usize = 0,
    phase_retired_remembered_sets: usize = 0,
    phase_cleared_nonblock_headers: usize = 0,
};

comptime {
    // This state lives in every tracing Registry. Keep diagnostic growth
    // deliberate instead of silently widening every runtime.
    if (@sizeOf(usize) == 8 and @sizeOf(Stats) != 376) {
        @compileError("gc concurrent Stats size changed; update the footprint pin deliberately");
    }
}

fn ratioMillionthsCeil(numerator: usize, denominator: usize) usize {
    if (denominator == 0) return 0;
    const wide_numerator = @as(u128, numerator) * 1_000_000;
    const rounded = (wide_numerator + @as(u128, denominator) - 1) / denominator;
    return @intCast(@min(rounded, std.math.maxInt(usize)));
}

pub fn envelopePeakOverThresholdMillionths(stats: Stats) usize {
    return ratioMillionthsCeil(stats.envelope_max_peak_bytes, stats.envelope_max_threshold_bytes);
}

pub fn envelopeBeginOverThresholdMillionths(stats: Stats) usize {
    return ratioMillionthsCeil(stats.envelope_max_begin_bytes, stats.envelope_max_threshold_bytes);
}

pub fn envelopePeakOverStartMillionths(stats: Stats) usize {
    return ratioMillionthsCeil(stats.envelope_max_peak_bytes, stats.envelope_max_start_bytes);
}

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
    /// The next cycle consumes the S/T pair established by the preceding
    /// successful major's threshold reset. A manual threshold invalidates it.
    envelope_baseline_valid: bool = false,
    envelope_active: bool = false,
    envelope_next_start_bytes: usize = 0,
    envelope_next_threshold_bytes: usize = 0,
    envelope_cycle_start_bytes: usize = 0,
    envelope_cycle_threshold_bytes: usize = 0,
    envelope_cycle_begin_bytes: usize = 0,
    envelope_cycle_peak_bytes: usize = 0,
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

//! Incremental-major state and target-shading barrier (§8.4, §7.4).
//!
//! The barrier is incremental-update and shades the *exact new target* of a
//! strong write. That common target-shading arm deliberately reads no owner
//! colour and keeps no owner-rescan bit: a write through an unreachable owner
//! may preserve floating garbage for the cycle, which is the price of not
//! paying for owner state on every store. The two rare owner-requeue arms are
//! different: retracing is necessary only after the owner has already been
//! claimed black, so they verify that prior mark and skip a still-white owner.

const std = @import("std");

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
    /// Shape/Realm target writes that reached the owner-requeue arm. A white
    /// owner is counted here but skipped: only an already-black owner is
    /// actually appended to the frontier.
    barrier_requeued_owner: usize = 0,
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
    /// Finish-pause time before the remark starts (collector setup).
    phase_finish_init_ns: u64 = 0,
    /// Finish-pause time after condemnation (young-state retirement, sweep
    /// model close, safety-build invariants). With `init`, `remark`, `weak`
    /// and `condemn` this makes the subphase row sum to the STW `finish` row
    /// up to the two `nowNanos` reads on either side of the pause.
    phase_finish_tail_ns: u64 = 0,
    phase_retired_nonblock_headers: usize = 0,
    phase_retired_young_blocks: usize = 0,
    phase_retired_remembered_sets: usize = 0,
    phase_cleared_nonblock_headers: usize = 0,
};

pub fn ratioMillionthsCeil(numerator: usize, denominator: usize) usize {
    if (denominator == 0) return 0;
    const wide_numerator = @as(u128, numerator) * 1_000_000;
    const rounded = (wide_numerator + @as(u128, denominator) - 1) / denominator;
    return @intCast(@min(rounded, std.math.maxInt(usize)));
}

pub const State = struct {
    /// Only changes while the runtime is stopped (§8.4), so a plain acquire
    /// load is enough on the mutator side.
    major_marking_active: std.atomic.Value(bool) = .init(false),
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
};

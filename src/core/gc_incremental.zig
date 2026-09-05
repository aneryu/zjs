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
const gc = @import("gc.zig");
const mark_queue = @import("gc_mark_queue.zig");
const registry_lists = @import("gc_registry_lists.zig");

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
    /// future parallel marking turns on.
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
    /// Single-threaded, deliberately: a plain `bool`, not an atomic.
    ///
    /// The incremental major is driven to completion on the runtime's owner
    /// thread (`JSRuntime.owner_thread_id`), and no GC source file spawns a
    /// thread -- there is no marker worker, and parallel marking (S4-b) was
    /// withdrawn. Every reader and the single writer
    /// (`Registry.setMajorMarkingActive`) therefore run on that one thread,
    /// so there is nothing to synchronise with and no ordering to name.
    ///
    /// It is also the write barrier's hot path: `markingActive` runs tens of
    /// millions of times per benchmark (55.8M on earley-boyer). When a real
    /// marker thread lands, this becomes JSC's threshold protocol -- a plain
    /// byte the collector rewrites at phase boundaries with the world
    /// stopped, fences only in the slow path (HeapInlines.h:106,
    /// Heap.cpp:2871) -- which is a plain byte then too.
    major_marking_active: bool = false,
    /// Running STW accumulator for the open cycle; drained into
    /// `stats.last_cycle_stw_ns` at completion.
    cycle_stw_ns: u64 = 0,
    /// Settled live estimate after the last major, in account bytes; the
    /// threshold for the next cycle is priced off it. Pacing input, hence its
    /// place here rather than beside the marked-set census.
    last_settled_live_bytes: usize = 0,
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

    pub inline fn markingActive(self: *const State) bool {
        return self.major_marking_active;
    }
};

/// The mark frontier and the epoch its marks are read under.
///
/// The barrier's shared queue lives here rather than inside `gc_mark_queue`
/// because the barrier reaches it through the Registry and must not import
/// the queue module to do so.
pub const Marking = struct {
    /// Objects the marking barrier shaded GREY: marked, children still to be
    /// traced. Whole 4 KiB segments move between this shared chain and the
    /// private tracer stacks.
    queue: mark_queue.Queue = .{},
    /// The owner's segmented private LIFO. It persists across slices; old
    /// whole segments are donated for parallel work while the hot top stays
    /// local. Allocation failure aborts the cycle before sweep.
    stack: mark_queue.MarkStack = .{},
    /// Current mark epoch for non-block trace carriers. Epoch 0 is reserved
    /// for newborn/unmarked; a major advances this scalar, while minors keep
    /// it fixed so sticky survivor marks remain valid. Unlike a global parity
    /// flip, a stale nonzero epoch cannot make a newborn (0) read marked.
    header_epoch: u16 = 1,

    /// Idempotent: both the private stack and the shared queue reset to their
    /// empty state, so a Registry torn down twice -- the OOM rollback case --
    /// does not double-free a segment.
    pub fn deinit(self: *Marking, allocator: std.mem.Allocator) void {
        self.stack.deinitStack();
        self.queue.deinit(allocator);
    }
};

/// The morgue: condemned by a cycle's finish, awaiting sliced destruction at
/// later polls.
///
/// Everything here is unreachable (the remark's full trace proved it) and
/// weak-cleared (processWeak ran first), so the mutator cannot reach it,
/// cannot re-derive a pointer to it, and cannot observe its destruction
/// order. What CAN still find it is a conservative scan: a parked corpse
/// keeps `heap_accounted` until its destructor runs, so a stale stack word
/// would resolve it and the tracer would walk freed payloads. That is why
/// minors and new cycles are gated while this list is non-empty -- no
/// collection, no scan, no resurrection-by-residue.
pub const Morgue = struct {
    /// Split by kind at condemnation.
    ///
    /// Destruction has to run objects before realms before modules before
    /// bytecode before var_refs before shapes, and it used to get that order
    /// by walking ONE list once per kind: a corpse of the last kind was
    /// stepped over five times before its own pass reached it, and each of
    /// those steps was a list-node dereference and a budget counter tick.
    /// Bucketing at condemnation costs nothing extra -- that pass already
    /// visits every corpse -- and makes destruction visit each exactly once.
    /// Indexed by `@intFromEnum(kind)`.
    by_kind: [gc.gc_kind_count]registry_lists.IntrusiveHeaderList = @splat(.{}),
    /// Sliced-destruction cursor: which kind pass destruction is on. The
    /// lists are stable between slices -- the mutator cannot touch them -- so
    /// a plain cursor resumes exactly where the budget ran out.
    kind_pass: u8 = 0,
    /// Resume point within the current kind pass. Sound to hold across slices
    /// because nothing touches the list between them: collections are gated
    /// and the mutator has no path to a condemned object.
    cursor: ?*gc.GCObjectHeader = null,
    pending: bool = false,
    /// Objects destroyed by the slices of the current morgue, for the
    /// completion poll's CollectionResult.
    destroyed: usize = 0,
    /// Heap bytes the morgue holds: already condemned, not yet returned.
    /// The growth threshold subtracts this at finish -- pricing the next
    /// cycle off a heap full of corpses was a compounding feedback loop
    /// (measured: an 841 MB peak on a ~50 MB live set).
    bytes: usize = 0,

    /// Bind the per-kind cyclic sentinels. Must run before any condemnation,
    /// and is idempotent.
    pub fn init(self: *Morgue) void {
        for (&self.by_kind) |*head| registry_lists.listInit(head);
    }
};

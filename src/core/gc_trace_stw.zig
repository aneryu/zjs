//! Stop-the-world reclaiming tracer (tracing-gc-design.md §13 Stage 3).
//!
//! Mark/sweep over the compatibility heap: current registry and layouts, no
//! new header, no block heap, no generations, no concurrent marker. Strong
//! edges walk `traceChildEdges*` (the same authority as the shadow observer).
//! WeakMap/WeakSet values are NOT marked during the strong walk;
//! `visitWeakCollectionEntry` stays a no-op. A separate ephemeron fixed
//! point then marks a value only when both its table and key are live.
//!
//! Compiled only when `-Dzjs_gc=trace_stw`. Default `rc` never imports this
//! module. Failure returns to the caller; it does not fall back to RC.

const std = @import("std");
const builtin = @import("builtin");

const conservative = @import("gc_conservative.zig");
const context_mod = @import("context.zig");
const gc = @import("gc.zig");
const module_mod = @import("module.zig");
const object_gc = @import("object_gc.zig");
const object_mod = @import("object.zig");
const object_payloads = @import("object_payloads.zig");
const profile = @import("profile.zig");
const memory_mod = @import("memory.zig");
const BlockHeapMod = @import("gc_block_heap.zig");
const runtime_mod = @import("runtime.zig");
const property = @import("property.zig");
const shape = @import("shape.zig");
const var_ref_mod = @import("var_ref.zig");
const function_bytecode_mod = @import("../bytecode.zig").function_bytecode;
const FunctionBytecode = function_bytecode_mod.FunctionBytecode;
const JSRuntime = runtime_mod.JSRuntime;
const JSValue = @import("value.zig").JSValue;
const Object = object_mod.Object;

pub const enabled = true;

const CollectError = std.mem.Allocator.Error || error{PayloadMarkFailed};

pub const SurvivorClass = enum {
    matching,
    floating_garbage,
    rc_side_leak,
    semantic_diff,
};

pub const Report = struct {
    allocated_before: usize = 0,
    marked_exact: usize = 0,
    marked_conservative_extra: usize = 0,
    swept: usize = 0,
    /// Minor-collection outcome; zero on a major.
    minor_reclaimed: usize = 0,
    minor_young_before: usize = 0,
    remaining: usize = 0,
    ephemeron_rounds: usize = 0,
    ephemeron_values_shaded: usize = 0,
    weak_entries_dropped: usize = 0,
    weakrefs_cleared: usize = 0,
    finalization_enqueued: usize = 0,
    conservative: conservative.Metrics = .{},
    mark_debt: usize = 0,
    sweep_debt: usize = 0,
    /// Bytes the sweep actually returned, from the space account's delta.
    reclaimed_bytes: usize = 0,
    /// Of this collection's wall time, how much went on census walks.
    census_ns: u64 = 0,
    /// The round marked but did not sweep: an arena was unregistered, so a
    /// conservative candidate into it could not have been resolved.
    skipped_sweep_incomplete_arenas: bool = false,
    soft_headroom: usize = 0,
    hard_headroom: usize = 0,
    windows_active: usize = 0,
    trans_fresh_to_active: usize = 0,
    trans_active_to_needs_sweep: usize = 0,
    trans_needs_sweep_to_sweeping: usize = 0,
    trans_sweeping_to_swept: usize = 0,
    trans_swept_to_active: usize = 0,
    mark_epoch: u64 = 0,
    committed_bytes: usize = 0,
    block_live_bytes: usize = 0,
    committed_live_milli: usize = 0,
    string_live: usize = 0,
    drained_sweep_debt: usize = 0,

    pub fn format(self: Report, writer: anytype) !void {
        try writer.print(
            \\trace-stw
            \\  allocated_before: {d}  marked_exact: {d}  conservative_extra: {d}  swept: {d}  remaining: {d}
            \\  ephemeron_rounds: {d}  ephemeron_values_shaded: {d}
            \\  weak_entries_dropped: {d}  weakrefs_cleared: {d}  finalization_enqueued: {d}
            \\  debt mark: {d} sweep: {d} soft: {d} hard: {d} windows_active: {d}
            \\
        , .{
            self.allocated_before,
            self.marked_exact,
            self.marked_conservative_extra,
            self.swept,
            self.remaining,
            self.ephemeron_rounds,
            self.ephemeron_values_shaded,
            self.weak_entries_dropped,
            self.weakrefs_cleared,
            self.finalization_enqueued,
            self.mark_debt,
            self.sweep_debt,
            self.soft_headroom,
            self.hard_headroom,
            self.windows_active,
        });
    }
};

pub var last_report: Report = .{};

/// `ZJS_GC_VERIFY_MINOR=1`: what a FULL trace would keep, recomputed before
/// each minor so the minor's condemned set can be checked against it.
///
/// This is the systematic form of `ZJS_MINOR_AUDIT`. The audit asks "does some
/// live object still name this?", which finds a missing barrier only when the
/// owner is itself reachable AND the edge is one `traceChildEdges` enumerates
/// -- it is blind to exactly the cases where the tracer does not know about the
/// reference at all. This asks the question the collector is really answering,
/// "is this garbage?", against the collector's own roots with the generational
/// shortcuts turned off. Anything it reports is a young-generation soundness
/// violation whatever the cause: a missing write barrier, a remembered-set
/// entry lost, a promotion that aged something the trace never reached.
///
/// Cost is a whole extra whole-heap trace plus a mark save/restore per minor,
/// which is why it is a diagnostic mode and not an assertion.
var verify_reachable: std.AutoHashMapUnmanaged(usize, void) = .empty;
var verify_armed: bool = false;

/// Mark exactly what the roots reach, with no sticky-old shortcut and no
/// remembered set, and hand back the set. Leaves every mark bit as it found it:
/// the minor that runs next depends on the sticky marks this has to disturb.
fn computeFullReachable(rt: *JSRuntime, scan: runtime_mod.GCRootScan) !void {
    verify_reachable.clearRetainingCapacity();

    var saved: std.ArrayList(*gc.Header) = .empty;
    defer saved.deinit(rt.memory.persistent_allocator);
    {
        var it = rt.gc.objectIterator();
        while (it.next()) |header| {
            if (rt.gc.headerMarked(header)) try saved.append(rt.memory.persistent_allocator, header);
        }
    }

    var probe = try Collector.init(rt, null, scan);
    defer probe.deinit();
    probe.clearMarks();
    try probe.seedRoots();
    try probe.drain();
    if (probe.conservative_on) {
        try probe.seedConservativeRoots();
        try probe.drain();
    }
    // `processWeak` is deliberately NOT run: it clears weak references, and a
    // diagnostic pass must not have side effects the real collection then sees.
    try probe.ephemeronFixedPoint();

    {
        var it = rt.gc.objectIterator();
        while (it.next()) |header| {
            if (rt.gc.headerMarked(header)) {
                try verify_reachable.put(rt.memory.persistent_allocator, @intFromPtr(header), {});
            }
        }
    }

    probe.clearMarks();
    for (saved.items) |header| rt.gc.setHeaderMarked(header);
}

/// Compute the census fields that each cost a whole-heap walk.
///
/// A major over the compatibility heap needs `clearMarks` before the trace and
/// `sweepUnmarked` after it, plus `clearYoungState` to retire the young set.
/// `collectCycles` was doing eight passes; five of the extra ones exist only to
/// produce numbers -- `allocated_before`, `marked_exact`,
/// `marked_conservative_extra`, and two `liveCount()` calls feeding
/// `report.remaining` and the `promoted` counter.
///
/// "Only to produce numbers" is not the same as "no effect", and the first
/// version of this comment claimed it was. `countMarked` runs immediately
/// before `seedConservativeRoots`, so the `*gc.Header` it leaves in a
/// callee-saved register is shaded by the conservative stack scan and pins an
/// object that would otherwise be swept: turning the census off makes a major
/// reclaim slightly MORE, not less. That is the retaining direction going away
/// rather than a lost object, so it is safe -- but it makes the census a
/// behavioural switch, and it has to be treated as one.
///
/// Which is why the default is `false`, the shipped value, rather than
/// `builtin.is_test`. Keying it off the test build made `zig build test`
/// exercise only the configuration nobody runs, and the configuration everybody
/// runs did not pass: `engine_production`'s allocation-failure test depended on
/// the emergency collection reclaiming exactly nothing. Tests that want the
/// census ask for it around the body that needs it.
pub var detailed_reports: bool = false;

/// Nanoseconds the last collection spent on census walks rather than on
/// collecting, so the pause it reports is the pause it would have had.
///
/// Without this the only instrument for the pause distribution inflates it:
/// the census runs inside the region `tryRunObjectCycleRemovalWithValueRoots`
/// times, and it is enabled by the same `--gc-stats` that prints the result.
/// Measured at +38-41% on raytrace's p50. An instrument that changes its
/// subject by that much cannot be used to judge a change to the subject, and
/// this repository has already been burned twice by rulers that moved.
pub var last_census_ns: u64 = 0;

inline fn censusStart() u64 {
    return if (detailed_reports) profile.nowNanos() else 0;
}

inline fn censusEnd(started: u64) void {
    if (!detailed_reports) return;
    const now = profile.nowNanos();
    if (now > started) last_census_ns +|= now - started;
}

pub fn collectCycles(rt: *JSRuntime, extra_roots: ?*const runtime_mod.ValueRootFrame, scan: runtime_mod.GCRootScan) CollectError!usize {
    last_census_ns = 0;
    var drained_sweep_debt: usize = 0;
    if (comptime gc.sweep_model_enabled) {
        if (rt.gc.sweep_model.debt.sweep_debt != 0) {
            drained_sweep_debt = rt.gc.sweep_model.debt.sweep_debt;
            rt.gc.sweep_model.beginSweep();
            rt.gc.sweep_model.endSweep();
        }
        std.debug.assert(rt.gc.sweep_model.debt.sweep_debt == 0);
    }
    rt.gc.stats.collections += 1;
    if (comptime gc.block_heap_enabled) rt.gc.block_heap.beginMajor();
    var collector = try Collector.init(rt, extra_roots, scan);
    defer collector.deinit();
    const swept = try collector.run();
    clearYoungState(rt);
    // A major resets the experiment: it changes what is old, and with it the
    // survival rate the next minor would measure.
    rt.gc.generation.decayLowYieldStreak();
    last_report = collector.report;
    last_report.swept = swept;
    if (detailed_reports) {
        const t = censusStart();
        last_report.remaining = rt.gc.liveCount();
        censusEnd(t);
    } else last_report.remaining = 0;
    last_report.drained_sweep_debt = drained_sweep_debt;
    last_report.census_ns = last_census_ns;
    if (gc.arena_audit) {
        const stale = rt.gc.address_registry.auditArenas();
        const missing = auditLiveObjectsResolve(rt);
        if (stale != 0 or missing != 0) {
            std.debug.print(
                "gc: ARENA AUDIT after major: {d} free blocks read live, {d} live objects unresolvable\n",
                .{ stale, missing },
            );
            @panic("arena invariant violated");
        }
    }
    if (comptime gc.block_heap_enabled) {
        last_report.mark_epoch = rt.gc.block_heap.mark_epoch;
        last_report.committed_bytes = rt.gc.block_heap.stats.committed_bytes;
        last_report.block_live_bytes = rt.gc.block_heap.stats.live_bytes;
        last_report.committed_live_milli = rt.gc.block_heap.committedLiveMilli();
    }
    if (comptime gc.string_registry_enabled) {
        last_report.string_live = rt.gc.address_registry.stats.string_live;
    }
    return swept;
}

/// Stop-the-world minor collection over the young set (§8.5).
///
/// The minor traces roots and remembered owners, following only young
/// children, then reclaims young objects that stayed unmarked. Survivors
/// become old by the sticky rule, which here means clearing the young set:
/// nothing is copied and no age is counted.
///
/// Returns the number of young objects reclaimed, or null when there is no
/// generational state to work with.
pub fn collectMinor(rt: *JSRuntime, extra_roots: ?*const runtime_mod.ValueRootFrame, scan: runtime_mod.GCRootScan) CollectError!?usize {
    if (comptime !gc.generation_enabled) return null;
    const young_before = rt.gc.generation.stats.young_count;
    if (young_before == 0) return 0;

    // The minor is the consumer of the young-suffix anchor, so verify it here
    // rather than only at the major boundary: a stale `young_head` is
    // otherwise unobservable until `clearYoungMarks` dereferences freed
    // memory, one collection after the detach that stranded it.
    if (builtin.mode == .Debug) rt.gc.verifyIntrusiveList() catch unreachable;

    var collector = try Collector.init(rt, extra_roots, scan);
    defer collector.deinit();

    if (gc.verify_minor) {
        computeFullReachable(rt, scan) catch |err| {
            std.debug.print("VERIFY-MINOR setup failed: {s}\n", .{@errorName(err)});
        };
        verify_armed = true;
    }

    collector.clearYoungMarks();
    try collector.seedRoots();
    if (collector.conservative_on) try collector.seedConservativeRoots();

    // §8.3: force-trace each remembered owner instead of `tryMark`ing it. An
    // old owner already carries a sticky mark, so marking it would make the
    // walk skip exactly the children the minor exists to find.
    var remembered = rt.gc.generation.rememberedIterator();
    while (remembered.next()) |addr| {
        const header: *gc.Header = @ptrFromInt(addr.*);
        const before = collector.work.items.len;
        try collector.traceHeader(header);
        if (collector.work.items.len == before) {
            rt.gc.generation.stats.remembered_without_young += 1;
        }
    }
    try collector.drain();
    try collector.ephemeronFixedPoint();

    rt.gc.generation.stats.young_at_start_total += young_before;
    if (young_before > rt.gc.generation.stats.young_at_start_max) {
        rt.gc.generation.stats.young_at_start_max = young_before;
    }
    // Same requirement as the major: a sweep is only sound when every arena is
    // registered, because an unregistered one hides its objects from the
    // conservative scan that decides what is live.
    if (!rt.gc.arenaSetWhole()) return 0;
    const reclaimed = collector.sweepUnmarkedYoung();
    rt.gc.generation.noteMinorYield(young_before, reclaimed);

    // Promotion is the sticky rule made concrete: everything still young
    // after the sweep survived this collection, so it is old now. Clearing
    // the bit here is what makes a later write to it hit the remembered-set
    // path instead of being skipped as "the minor will see it anyway".
    var survivors = rt.gc.youngIterator();
    while (survivors.next()) |header| {
        header.meta().flags.young = false;
    }
    if (comptime gc.block_heap_enabled) rt.gc.block_heap.clearYoungBlocks();
    rt.gc.young_head = null;
    rt.gc.generation.promoteSurvivors(young_before -| reclaimed);
    last_report.minor_reclaimed = reclaimed;
    last_report.minor_young_before = young_before;
    return reclaimed;
}

/// Three-phase concurrent major (§8.6), driven to completion on the owner
/// thread.
///
/// The phases are real and so is the protocol: initial mark stops the mutator
/// and seeds roots, the concurrent phase drains with the barrier live so
/// mutator writes shade their targets, and final remark stops again to rescan
/// roots and drain what the barrier produced. What is not here yet is a
/// separate marker thread -- the drain runs on the owner. That keeps the
/// phase transitions, the barrier handshake and the remark obligations
/// testable before a second thread is introduced, which is the order the
/// litmus argued for: validate the protocol, then parallelise it.
pub fn collectConcurrentMajor(rt: *JSRuntime, extra_roots: ?*const runtime_mod.ValueRootFrame, scan: runtime_mod.GCRootScan) CollectError!usize {
    if (comptime !gc.concurrent_enabled) return error.PayloadMarkFailed;

    var collector = try Collector.init(rt, extra_roots, scan);
    defer collector.deinit();

    // Initial mark, mutator stopped. The barrier queue gets its ring before
    // marking is published: a queue with no buffer reports every push as
    // overflow, which is sound but downgrades every cycle to the rescan.
    rt.gc.concurrent_mark_queue.ensureCapacity(gc.Registry.markQueueAllocator());
    collector.clearMarks();
    var live = rt.gc.objectIterator();
    while (live.next()) |_| collector.report.allocated_before += 1;
    try collector.seedRoots();
    if (collector.conservative_on) try collector.seedConservativeRoots();

    // Publish that marking is live before resuming: from here every strong
    // write shades its target GREY -- marked and queued -- instead of taking
    // the generational path.
    rt.gc.concurrent.major_marking_active.store(true, .release);

    // Concurrent phase. The mutator is logically running here; the barrier is
    // what keeps its writes visible to this drain, and what it queued is part
    // of this drain's work.
    try collector.drain();
    _ = try collector.drainBarrierQueue();
    collector.report.marked_exact = collector.countMarked();

    // Final remark, mutator stopped again. Roots are rescanned because they
    // moved while the mutator ran, and the drain repeats because rescanning
    // and the barrier both produce work. The barrier queue is drained to
    // empty HERE, under the stopped mutator: entries are grey -- their
    // children have never been traced -- and leaving one behind is exactly
    // the black-without-tracing hole this queue exists to close.
    try collector.seedRoots();
    if (collector.conservative_on) try collector.seedConservativeRoots();
    try collector.drain();
    _ = try collector.drainBarrierQueue();
    try collector.ephemeronFixedPoint();

    // Marking is over before anything is freed: a mutator that resumes mid
    // sweep must not still be shading into a set being torn down.
    rt.gc.concurrent.major_marking_active.store(false, .release);

    collector.processWeak();
    const swept = collector.sweepUnmarked();
    last_report = collector.report;
    last_report.swept = swept;
    if (detailed_reports) {
        const t = censusStart();
        last_report.remaining = rt.gc.liveCount();
        censusEnd(t);
    } else last_report.remaining = 0;
    if (comptime gc.generation_enabled) {
        // Everything that survived a major is old, and the remembered set it
        // was built from is stale (§8.2). Clearing the bits and the suffix
        // cursor is what makes that true rather than merely intended: a
        // survivor that kept its young bit would be swept by the next minor
        // on the strength of a trace that never looked at its incoming edges.
        clearYoungState(rt);
        // The argument feeds the `promoted` counter and nothing else, and
        // `liveCount` is a whole-heap walk. After a major every survivor is
        // old, so with the counter unread there is nothing to count.
        const t = censusStart();
        rt.gc.generation.promoteSurvivors(if (detailed_reports) rt.gc.liveCount() else 0);
        censusEnd(t);
    }
    return swept;
}

/// Retire the young set after a whole-heap collection.
///
/// The bulk of the young bits are retired by the sweep itself -- survivors on
/// both arms of its walk get `young = false` -- so the whole-heap pass this
/// used to be is gone. What the sweep cannot see is an object allocated
/// DURING it: finalizer enqueue and deferred-free bookkeeping allocate, and
/// publication marks young and appends at the list tail, behind the walk's
/// cursor. Those are therefore a contiguous tail run, and retiring them is a
/// backward walk that stops at the first non-young object --
/// O(sweep-time allocations), not O(heap). The suffix invariant
/// (`verifyHeapAccounting`) is what caught this: with `young_head` null, any
/// surviving young bit is a corruption report.
fn clearYoungState(rt: *JSRuntime) void {
    if (comptime !gc.generation_enabled) return;
    var cursor = rt.gc.gc_obj_list.prev;
    while (cursor) |h| {
        if (h == &rt.gc.gc_obj_list) break;
        if (!h.metaConst().flags.young) break;
        h.meta().flags.young = false;
        cursor = h.prev;
    }
    // Block-population young bits: walk the young-block list, not the heap.
    // This also retires sweep-time allocations -- a block that received one
    // is on the list like any other.
    if (comptime gc.block_heap_enabled) {
        var young = rt.gc.youngIterator();
        young.cursor = null;
        while (young.next()) |h| h.meta().flags.young = false;
        rt.gc.block_heap.clearYoungBlocks();
    }
    rt.gc.young_head = null;
    rt.gc.generation.retireYoungSet();
}

/// Open an incremental major cycle (§8.6 initial mark, mutator stopped for
/// this call only).
///
/// Clears marks, seeds every precise and conservative root GREY into the
/// persistent queue, retires the young/remembered state ("remembered owners
/// are not major roots"), and publishes `major_marking_active`. Returns with
/// the mutator free to run; the frontier drains at subsequent polls.
pub fn beginIncrementalCycle(rt: *JSRuntime, extra_roots: ?*const runtime_mod.ValueRootFrame, scan: runtime_mod.GCRootScan) CollectError!void {
    std.debug.assert(!rt.gc.concurrent.markingActive());
    rt.gc.concurrent_mark_queue.ensureCapacity(gc.Registry.markQueueAllocator());
    rt.gc.concurrent_mark_queue.reset();

    var collector = try Collector.init(rt, extra_roots, scan);
    defer collector.deinit();
    collector.shade_to_queue = true;

    collector.clearMarks();
    try collector.seedRoots();
    if (collector.conservative_on) try collector.seedConservativeRoots();

    // §8.6 initial mark step 3. O(young) via the suffix and the young-block
    // list.
    var young = rt.gc.youngIterator();
    while (young.next()) |header| header.meta().flags.young = false;
    if (comptime gc.block_heap_enabled) rt.gc.block_heap.clearYoungBlocks();
    rt.gc.young_head = null;
    rt.gc.generation.retireYoungSet();

    rt.gc.concurrent.major_marking_active.store(true, .monotonic);
}

/// Drain up to `budget_ns` of the grey frontier. Returns true when the
/// frontier is empty and the cycle is ready for its final remark.
///
/// The clock is sampled every 64 objects rather than per pop; a traceHeader
/// is tens of nanoseconds and `nowNanos` is not free.
pub fn incrementalMarkStep(rt: *JSRuntime, budget_ns: u64) CollectError!bool {
    std.debug.assert(rt.gc.concurrent.markingActive());
    var collector = try Collector.init(rt, null, .declared_only);
    defer collector.deinit();
    collector.shade_to_queue = true;

    const queue = &rt.gc.concurrent_mark_queue;
    const started = profile.nowNanos();
    var since_clock: usize = 0;
    while (queue.pop()) |header| {
        // No validation needed: rc-managed kinds never enter the queue (see
        // `shade`), and everything that can is freeable only by the collector
        // itself, which does not run inside its own mutator windows. The pop
        // used to revalidate through the address registry -- 4.3% of splay's
        // runtime, paid per object against a hazard only shapes had.
        try collector.traceHeader(header);
        if (collector.err) |err| return err;
        since_clock += 1;
        if (since_clock == 64) {
            since_clock = 0;
            if (profile.nowNanos() -| started >= budget_ns) break;
        }
    }
    rt.gc.concurrent.stats.increments += 1;
    return queue.len() == 0;
}

/// Final remark and sweep (§8.6, mutator stopped). Re-seeds every root --
/// stack slots are not barriered, so the conservative rescan is what catches
/// white objects referenced only from native frames -- drains what that and
/// the barrier produced, then runs the ordinary weak/sweep tail.
/// Wall-time split of the last finish slice, for deciding which phase the
/// next pause tranche attacks. Nanoseconds; written every finish.
pub var last_finish_phases: struct {
    remark_ns: u64 = 0,
    weak_ns: u64 = 0,
    sweep_ns: u64 = 0,
} = .{};

pub fn finishIncrementalCycle(rt: *JSRuntime, extra_roots: ?*const runtime_mod.ValueRootFrame, scan: runtime_mod.GCRootScan) CollectError!usize {
    std.debug.assert(rt.gc.concurrent.markingActive());
    rt.gc.stats.collections += 1;

    var collector = try Collector.init(rt, extra_roots, scan);
    defer collector.deinit();

    const t_remark = profile.nowNanos();
    try collector.seedRoots();
    if (collector.conservative_on) try collector.seedConservativeRoots();
    try collector.drain();
    _ = try collector.drainBarrierQueue();
    try collector.ephemeronFixedPoint();

    // Marking is over before anything is freed (§8.6 step 12 before 13).
    rt.gc.concurrent.major_marking_active.store(false, .monotonic);

    const t_weak = profile.nowNanos();
    collector.processWeak();
    const t_sweep = profile.nowNanos();
    collector.beginSweepModelSweep();
    if (!rt.gc.arenaSetWhole()) {
        collector.report.skipped_sweep_incomplete_arenas = true;
        last_report = collector.report;
        return 0;
    }

    // Condemn, do not destroy. The walk detaches every unmarked, unpinned
    // object onto the morgue and retires the survivors' young bits; the
    // destruction -- which the phase probe measured at 99.5% of this slice
    // (63.9 of 64.2 ms on splay) -- happens in bounded slices at later polls.
    // Weak state is already clear and the trace already proved these
    // unreachable, so the mutator cannot tell the difference; what it buys is
    // the whole reason Phase 2 exists.
    // Dead-scan condemnation: the block phase computes alloc & ~mark a word
    // at a time and never touches a survivor -- the survivors' young bits are
    // retired by the young-block list in `clearYoungState`, not here. The
    // list phase still carries the per-header test for the non-block kinds.
    var condemned: usize = 0;
    var doomed_bytes: usize = 0;
    var iterator = rt.gc.deadCandidateIterator();
    while (iterator.next()) |header| {
        if (!gc.Registry.isBlockCellHeader(header)) {
            // List phase: mark test as always, and fold the survivors' young
            // retirement into the same touch.
            if (rt.gc.headerMarked(header)) {
                header.meta().flags.young = false;
                continue;
            }
        }
        if (header.metaConst().flags.is_pinned) continue;
        // The byte total only feeds the threshold's condemn-time reset; for a
        // block corpse the cell class is close enough, and precise
        // `heapByteSizeFromHeader` reads the corpse's shape -- one cache miss
        // per dead object, on the slice that is the pause tail.
        doomed_bytes +|= if (gc.Registry.isBlockCellHeader(header))
            BlockHeapMod.Block.fromCellTrusted(@intFromPtr(header) - gc.metadata_prefix_size).cell_size - gc.metadata_prefix_size
        else
            gc.Registry.heapByteSizeFromHeader(rt, header);
        rt.gc.detachCycleCandidate(header);
        gc.listAddTail(&rt.gc.doomed_list, header);
        // A condemned shape must leave the transition table NOW, not at its
        // destructor: the mutator runs before the destruction slices, and a
        // table that still serves the corpse lets a live object adopt a shape
        // that is already scheduled to be freed. Realms and modules sit on
        // membership lists that only collections walk, and those are gated
        // while the morgue is open; the shape table is the one engine-global
        // structure the MUTATOR consults.
        if (header.metaConst().flags.kind == .shape) {
            rt.shapes.delistCondemnedShape(header);
        }
        condemned += 1;
    }
    rt.gc.doomed_phase = 0;
    rt.gc.doomed_cursor = null;
    rt.gc.doomed_destroyed = 0;
    rt.gc.doomed_bytes = doomed_bytes;
    rt.gc.doomed_pending = condemned != 0;
    if (condemned == 0) rt.gc.concurrent.stats.cycles_completed += 1;

    const t_end = profile.nowNanos();
    last_finish_phases = .{
        .remark_ns = t_weak -| t_remark,
        .weak_ns = t_sweep -| t_weak,
        .sweep_ns = t_end -| t_sweep,
    };
    collector.endSweepModelSweep();

    clearYoungState(rt);
    rt.gc.generation.decayLowYieldStreak();
    last_report = collector.report;
    last_report.swept = condemned;
    if (gc.arena_audit) {
        const stale = rt.gc.address_registry.auditArenas();
        const missing = auditLiveObjectsResolve(rt);
        if (stale != 0 or missing != 0) {
            std.debug.print(
                "gc: ARENA AUDIT after incremental cycle: {d} free blocks read live, {d} live objects unresolvable\n",
                .{ stale, missing },
            );
            @panic("arena invariant violated");
        }
    }
    return condemned;
}

/// Destruction order for the morgue: identical to `destroyCondemned`'s five
/// passes (qjs `gc_free_cycles`), spelled as a phase index so a bounded slice
/// can resume where its budget ran out. Objects first; realms, modules and
/// function bytecode after; cells and shapes last, because earlier
/// destructors still read them.
const doomed_phase_kinds = [_]gc.GcKind{ .object, .realm_context, .module, .function_bytecode, .var_ref };

/// Destroy up to `budget_ns` of the morgue. Returns true when it is empty.
///
/// Runs under `.remove_cycles` so every struct free parks on
/// `cycle_deferred_frees`; the drain happens ONCE, after the last slice, which
/// is what keeps a destructor in a later slice reading a sibling from an
/// earlier one as stripped-but-allocated memory instead of freed memory --
/// the same mid-pass guarantee the monolithic sweep had, stretched across
/// polls. The list is stable between slices: everything on it is unreachable,
/// weak-cleared, and invisible to collections (which are gated while the
/// morgue is open).
pub fn destroyDoomedSlice(rt: *JSRuntime, budget_ns: u64) usize {
    std.debug.assert(rt.gc.doomed_pending);
    const started = profile.nowNanos();
    var destroyed: usize = 0;
    var since_clock: usize = 0;

    const old_phase = rt.gc.phase;
    rt.gc.phase = .remove_cycles;
    defer rt.gc.phase = old_phase;

    while (rt.gc.doomed_phase < doomed_phase_kinds.len + 1) {
        const final_pass = rt.gc.doomed_phase == doomed_phase_kinds.len;
        var cursor = rt.gc.doomed_cursor orelse rt.gc.doomed_list.next;
        while (cursor) |h| {
            if (h == &rt.gc.doomed_list) break;
            const next = h.next;
            const kind = h.meta().flags.kind;
            const wanted = if (final_pass)
                kind == .shape
            else
                kind == doomed_phase_kinds[rt.gc.doomed_phase];
            if (wanted) {
                gc.listDel(h);
                rt.gc.sweep_current = h;
                switch (kind) {
                    .object => Object.destroyFromHeader(rt, h),
                    .realm_context => {
                        rt.gc.unlinkObjectWithBytes(h, gc.Registry.heapByteSizeFromHeader(rt, h));
                        context_mod.JSContext.destroyFromHeader(rt, h);
                    },
                    .module => {
                        rt.gc.unlinkObjectWithBytes(h, gc.Registry.heapByteSizeFromHeader(rt, h));
                        module_mod.ModuleRecord.destroyFromHeader(rt, h);
                    },
                    .function_bytecode => {
                        rt.gc.unlinkObjectWithBytes(h, gc.Registry.heapByteSizeFromHeader(rt, h));
                        function_bytecode_mod.destroyFromHeader(rt, h);
                    },
                    .var_ref => {
                        rt.gc.unlinkObjectWithBytes(h, gc.Registry.heapByteSizeFromHeader(rt, h));
                        var_ref_mod.VarRef.destroyFromHeader(rt, h);
                    },
                    .shape => {
                        if (!h.meta().flags.finalizing) rt.shapes.destroyFromHeader(h);
                    },
                    else => unreachable,
                }
                rt.gc.sweep_current = null;
                if (kind != .function_bytecode) destroyed += 1;
                since_clock += 1;
                if (since_clock == 32) {
                    since_clock = 0;
                    if (profile.nowNanos() -| started >= budget_ns) {
                        rt.gc.doomed_cursor = next;
                        rt.gc.doomed_destroyed += destroyed;
                        return destroyed;
                    }
                }
            }
            cursor = next;
        }
        rt.gc.doomed_phase += 1;
        rt.gc.doomed_cursor = null;
    }

    // Morgue empty: return the parked memory in one drain, same condition the
    // monolithic sweep used.
    rt.gc.doomed_pending = false;
    rt.gc.doomed_cursor = null;
    rt.gc.doomed_destroyed += destroyed;
    if (!rt.hasPendingDeferredClassPayloadFinalizers()) object_gc.drainCycleDeferredFrees(rt);
    rt.gc.concurrent.stats.cycles_completed += 1;
    return destroyed;
}

/// Complete any pending sliced destruction synchronously. Explicit
/// collections and teardown call this: destruction is irreversible, so unlike
/// an open marking cycle it cannot be aborted, only finished.
pub fn finishPendingDestruction(rt: *JSRuntime) void {
    if (comptime !gc.trace_stw_enabled) return;
    if (!rt.gc.doomed_pending) return;
    _ = destroyDoomedSlice(rt, std.math.maxInt(u64));
}

/// Drain the concurrent barrier queue the way the final remark does, for
/// tests that construct the mutator interleaving `collectConcurrentMajor`
/// cannot express (it drains to completion in one call, so nothing mutates
/// between its phases). Returns the number of grey entries traced.
pub fn remarkBarrierQueueForTest(rt: *JSRuntime) CollectError!usize {
    var collector = try Collector.init(rt, null, .declared_only);
    defer collector.deinit();
    return collector.drainBarrierQueue();
}

/// The other direction of the arena invariant: every live object must be
/// findable from a conservative candidate.
///
/// `auditArenas` catches garbage that reads as live. This catches live objects
/// that read as garbage, which is the direction that frees something still in
/// use -- and it is checked here rather than at each suspected site because the
/// ways to lose an object (an unregistered arena, a bounds window that excludes
/// it, a block index rejected as out of range) have nothing in common except
/// the answer they produce.
pub fn auditLiveObjectsResolve(rt: *JSRuntime) usize {
    var missing: usize = 0;
    var reported: usize = 0;
    var it = rt.gc.objectIterator();
    while (it.next()) |header| {
        if (rt.gc.address_registry.containsHeader(header)) continue;
        missing += 1;
        if (reported < 8) {
            reported += 1;
            std.debug.print(
                "gc: ARENA AUDIT live object at 0x{x} (kind {any}) does not resolve\n",
                .{ @intFromPtr(header), header.metaConst().flags.kind },
            );
        }
    }
    return missing;
}

const Collector = struct {
    rt: *JSRuntime,
    extra_roots: ?*const runtime_mod.ValueRootFrame,
    arena: std.heap.ArenaAllocator,
    work: std.ArrayList(*gc.Header),
    err: ?CollectError = null,
    report: Report = .{},
    exact_mark_count: usize = 0,
    conservative_on: bool,
    /// Incremental-cycle mode: `shade` pushes grey objects onto the
    /// persistent barrier queue instead of the per-collection work list, so
    /// the frontier survives between increments. The work list is untouched
    /// in this mode, which also means the collector's arena never allocates.
    shade_to_queue: bool = false,

    fn init(rt: *JSRuntime, extra_roots: ?*const runtime_mod.ValueRootFrame, scan: runtime_mod.GCRootScan) std.mem.Allocator.Error!Collector {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        errdefer arena.deinit();
        return .{
            .rt = rt,
            .extra_roots = extra_roots,
            .arena = arena,
            .work = .empty,
            // CLI STW always adds the conservative pass over containers-only
            // frames (same split as shadow). Tests honour the trigger's scan
            // policy: engine-internal triggers (allocation threshold,
            // safepoint, callback boundary) run with mutator native frames
            // live — frames entitled to hold rc refs without a
            // ValueRootFrame, conservative is their covering mechanism — so
            // precision there is unsound (first caught by Error().stack
            // assembly being swept mid-construction). Host-quiescent
            // triggers stay precise so liveness tests are deterministic and
            // a missing test-side root still fails loudly.
            .conservative_on = if (!builtin.is_test)
                !rt.gc.host_quiescent
            else
                (rt.test_root_scan_override orelse scan) == .engine_active,
        };
    }

    fn deinit(self: *Collector) void {
        self.arena.deinit();
    }

    fn allocator(self: *Collector) std.mem.Allocator {
        return self.arena.allocator();
    }

    fn run(self: *Collector) CollectError!usize {
        self.clearMarks();
        if (detailed_reports) {
            const t = censusStart();
            var live = self.rt.gc.objectIterator();
            while (live.next()) |_| self.report.allocated_before += 1;
            censusEnd(t);
        }

        self.beginSweepModelMark();

        try self.seedRoots();
        try self.drain();
        if (detailed_reports) {
            const t = censusStart();
            self.exact_mark_count = self.countMarked();
            self.report.marked_exact = self.exact_mark_count;
            censusEnd(t);
        }

        if (self.conservative_on) {
            try self.seedConservativeRoots();
            try self.drain();
            if (detailed_reports) {
                const t = censusStart();
                const after = self.countMarked();
                self.report.marked_conservative_extra = after - self.exact_mark_count;
                censusEnd(t);
            }
        }

        try self.ephemeronFixedPoint();
        self.processWeak();
        self.endSweepModelMark();
        self.beginSweepModelSweep();
        // Sweeping requires that every live object be reachable from a
        // conservative candidate, which requires every arena to be registered.
        // If one is not, mark and stop: the marks are still correct, nothing is
        // reclaimed this round, and the objects stay alive until the arena set
        // can be repaired. Leaking a round is recoverable; freeing a live
        // object is not.
        if (!self.rt.gc.arenaSetWhole()) {
            self.report.skipped_sweep_incomplete_arenas = true;
            return 0;
        }
        const live_before_sweep = self.liveHeapBytes();
        const swept = self.sweepUnmarked();
        self.report.reclaimed_bytes = live_before_sweep -| self.liveHeapBytes();
        if (comptime gc.sweep_model_enabled) {
            self.rt.gc.sweep_model.last_sweep_debt = self.report.reclaimed_bytes;
        }
        self.endSweepModelSweep();
        return swept;
    }

    fn liveHeapBytes(self: *Collector) usize {
        return self.rt.gc.old_space.live_bytes +| self.rt.gc.large_space.live_bytes;
    }

    fn beginSweepModelMark(self: *Collector) void {
        if (comptime !gc.sweep_model_enabled) return;
        self.rt.gc.sweep_model.beginMark(self.liveHeapBytes());
    }

    fn endSweepModelMark(self: *Collector) void {
        if (comptime !gc.sweep_model_enabled) return;
        // Zero, deliberately: the whole-heap walk that used to produce a figure
        // here is gone.
        //
        // It visited every object and asked `heapByteSizeFromHeader` for each,
        // to compute the bytes the sweep was about to reclaim, and nothing
        // could read the answer -- `endSweep` zeroes `debt.sweep_debt` before
        // `refreshHeadroom` consumes it (gc_sweep_model.zig:94,99), and the
        // panel prints that same zeroed field. The number is worth having, so
        // it now comes from the space account instead: live bytes before the
        // sweep minus live bytes after. That is exact and free, because every
        // free already debits it.
        //
        // The window transitions `endMark` drives do not depend on the value.
        self.rt.gc.sweep_model.endMark(0);
    }

    fn beginSweepModelSweep(self: *Collector) void {
        if (comptime !gc.sweep_model_enabled) return;
        self.rt.gc.sweep_model.beginSweep();
    }

    fn endSweepModelSweep(self: *Collector) void {
        if (comptime !gc.sweep_model_enabled) return;
        self.rt.gc.sweep_model.endSweep();
        self.rt.gc.sweep_model.refreshHeadroom(
            self.liveHeapBytes(),
            self.rt.gc.policy.major_debt_threshold,
            self.rt.gc.stats.external_bytes,
        );
        const model = self.rt.gc.sweep_model;
        self.report.mark_debt = model.debt.mark_debt;
        self.report.sweep_debt = model.debt.sweep_debt;
        self.report.soft_headroom = model.debt.soft_headroom;
        self.report.hard_headroom = model.debt.hard_headroom;
        self.report.windows_active = model.active;
        self.report.trans_fresh_to_active = model.trans_fresh_to_active;
        self.report.trans_active_to_needs_sweep = model.trans_active_to_needs_sweep;
        self.report.trans_needs_sweep_to_sweeping = model.trans_needs_sweep_to_sweeping;
        self.report.trans_sweeping_to_swept = model.trans_sweeping_to_swept;
        self.report.trans_swept_to_active = model.trans_swept_to_active;
    }

    /// Whole-heap unmark.
    ///
    /// Block cells: one epoch bump. Every block's bitmap goes stale at once
    /// and reads unmarked until its first `setMark` re-stamps it -- the
    /// per-block-version scheme the unsound global parity flip pointed at
    /// (see `Registry.mark_parity`), now real. The walk below only still
    /// exists for the non-block populations (slab and standalone kinds), and
    /// skips block cells outright rather than paying a block-header read to
    /// clear a bit the bump already invalidated. Restore semantics for the
    /// VERIFY_MINOR probe hold: re-marking a saved set under the new epoch
    /// means exactly "marked" again.
    fn clearMarks(self: *Collector) void {
        if (comptime gc.block_heap_enabled) self.rt.gc.block_heap.mark_epoch += 1;
        // LIST ONLY. The epoch bump above is the whole-population unmark for
        // block cells; walking the composite iterator here re-enumerated
        // every live cell just to skip it, and that enumeration alone was the
        // 12 ms p99 begin slice on splay.
        var cursor = self.rt.gc.gc_obj_list.next;
        while (cursor) |header| {
            if (header == &self.rt.gc.gc_obj_list) break;
            self.rt.gc.setHeaderUnmarked(header);
            cursor = header.next;
        }
    }

    /// Clear marks over the young suffix only.
    ///
    /// A minor must not touch old marks for two separate reasons, and both
    /// matter: under the sticky rule an old object's mark is what tells the
    /// remembered-owner walk that it has already been accounted for (§8.5),
    /// and clearing the whole heap would make a nursery collection cost
    /// O(heap) -- which is how a large live set turns frequent minors
    /// quadratic.
    fn clearYoungMarks(self: *Collector) void {
        var iterator = self.rt.gc.youngIterator();
        while (iterator.next()) |header| {
            self.rt.gc.setHeaderUnmarked(header);
        }
    }

    fn countMarked(self: *Collector) usize {
        var n: usize = 0;
        var iterator = self.rt.gc.objectIterator();
        while (iterator.next()) |header| {
            if (self.rt.gc.headerMarked(header)) n += 1;
        }
        return n;
    }

    fn shade(self: *Collector, header: *gc.Header) void {
        if (self.err != null) return;
        const addr = @intFromPtr(header);
        if (addr < 4096 or !std.mem.isAligned(addr, @alignOf(gc.Header))) return;
        if (self.rt.gc.headerMarked(header)) return;
        // UNPUBLISHED: a published container can briefly hold a pointer to an
        // object still under construction (the store happens, the barrier
        // correctly skips it), and tracing through the container reaches it
        // here with its fields undefined. Skipping is the only sound answer,
        // and it is complete: an unpublished object is not on `gc_obj_list`,
        // so no sweep can condemn it, and its edges are covered by the
        // published-grey push the moment registration completes -- or it
        // dies unconstructed, in which case there was nothing to keep.
        if (!header.meta().alloc_info.heap_accounted) return;
        // A condemned corpse awaiting its destruction slice. No precise root
        // can name it -- the remark proved it unreachable and processWeak
        // cleared its identities -- so the only way here is conservative
        // stack residue resolving a parked slab block that still reads
        // `heap_accounted`. Shading it would trace freed payloads.
        // `detachCycleCandidate` already stamps the bit; this is the read.
        if (header.meta().flags.cycle_visited) return;
        self.rt.gc.setHeaderMarked(header);
        if (self.shade_to_queue) {
            // rc-managed kinds (shapes and realms still refcount under the
            // tracer) never enter the queue: the mutator can free them during
            // a window and the entry would dangle -- the pop used to pay a
            // hash-validation per object to survive that, 4.3% of splay's
            // whole runtime. Instead they are traced HERE, synchronously: a
            // shape's trace is one proto edge, a realm is shaded once per
            // cycle at the seeds. Every kind that CAN sit in the queue can
            // only be freed by the collector itself, which does not run
            // inside its own windows, so the queue needs no validation at
            // all.
            const kind = header.meta().flags.kind;
            if (kind == .shape or kind == .realm_context) {
                // Mark BEFORE tracing: the mark is both this object's
                // survival (an unmarked shape here was condemned alive -- the
                // first build of this branch forgot the store and test262
                // found what macro-check missed) and the recursion's
                // deduplication, since a re-shade of the same shape now takes
                // the marked early-return above.
                self.rt.gc.setHeaderMarked(header);
                self.traceHeader(header) catch |err| {
                    self.err = err;
                };
                return;
            }
            // A failed push is the queue's overflow contract: the object is
            // marked, the flag is set, and the remark's rescan will find it.
            _ = self.rt.gc.concurrent_mark_queue.push(header);
            return;
        }
        self.work.append(self.allocator(), header) catch |err| {
            self.err = err;
        };
    }

    fn shadeOptionalObject(self: *Collector, obj: ?*Object) void {
        const object = obj orelse return;
        if (@intFromPtr(object) == 0) return;
        self.shade(&object.header);
    }

    pub fn visitValue(self: *Collector, val: *JSValue) void {
        if (val.cycleMarkHeader()) |header| self.shade(header);
    }

    pub fn visitObject(self: *Collector, obj_ptr: *?*Object) void {
        self.shadeOptionalObject(obj_ptr.*);
    }

    pub fn visitShape(self: *Collector, shape_ref: *shape.Shape) void {
        self.shade(&shape_ref.header);
    }

    pub fn visitRealm(self: *Collector, ctx_ptr: *?*context_mod.RealmContext) void {
        if (ctx_ptr.*) |ctx| self.shade(&ctx.header);
    }

    pub fn visitModule(self: *Collector, record: *module_mod.ModuleRecord) void {
        self.shade(&record.header);
    }

    /// Strong mark must not promote a weak edge. Ephemeron values are
    /// shaded only by `ephemeronFixedPoint` when both table and key are live.
    pub fn visitWeakCollectionEntry(self: *Collector, entry: *object_payloads.WeakCollectionEntry) void {
        _ = self;
        _ = entry;
    }

    pub fn visitFinalizationCell(self: *Collector, entry: *object_payloads.FinalizationRegistryCell) void {
        if (entry.keepsHeldValuesAlive()) self.visitValue(&entry.held_value);
    }

    fn seedRoots(self: *Collector) CollectError!void {
        // `context_head` / `constructing_context_head` are membership lists,
        // not strong roots (gc-invariants.md). A host-released Realm still
        // sitting on the list because a heap cycle holds its last RC must be
        // collectable — the same graph trial deletion frees. Live contexts
        // are reached through host-create-ref `root_providers` (registered
        // by ownership, unregistered when that ref is consumed) and
        // `traceActiveRoots`.
        for (self.rt.gc.pin_entries) |entry| {
            self.shade(entry.header);
        }
        if (self.err) |err| return err;

        const Adaptor = struct {
            collector: *Collector,

            fn visitValue(context: *anyopaque, slot: *JSValue) runtime_mod.RootTraceError!void {
                const adaptor: *@This() = @ptrCast(@alignCast(context));
                adaptor.collector.visitValue(slot);
                if (adaptor.collector.err) |err| return err;
            }

            fn visitObject(context: *anyopaque, slot: *?*Object) runtime_mod.RootTraceError!void {
                const adaptor: *@This() = @ptrCast(@alignCast(context));
                adaptor.collector.visitObject(slot);
                if (adaptor.collector.err) |err| return err;
            }

            fn visitHeader(context: *anyopaque, header: *const gc.Header) runtime_mod.RootTraceError!void {
                const adaptor: *@This() = @ptrCast(@alignCast(context));
                adaptor.collector.shade(@constCast(header));
                if (adaptor.collector.err) |err| return err;
            }
        };
        var adaptor = Adaptor{ .collector = self };
        var visitor = runtime_mod.RootVisitor{
            .context = @ptrCast(&adaptor),
            .visit_value = Adaptor.visitValue,
            .visit_object = Adaptor.visitObject,
            .visit_header = Adaptor.visitHeader,
        };
        try self.rt.traceActiveRoots(&visitor);
        // `runObjectCycleRemovalWithValueRoots` passes a frame that is not
        // necessarily linked on `active_value_roots`. Trial deletion ignored
        // it because RC>0 already kept those values; STW must visit it.
        if (self.extra_roots) |roots| {
            try self.rt.traceValueRootFrameChain(roots, &visitor);
        }
    }

    fn shadeConservative(context: *anyopaque, header: *gc.Header) void {
        const self: *Collector = @ptrCast(@alignCast(context));
        self.shade(header);
    }

    fn seedConservativeRoots(self: *Collector) CollectError!void {
        conservative.spillRegistersAndScan(
            self.rt,
            &self.report.conservative,
            shadeConservative,
            @ptrCast(self),
        );
        if (self.err) |err| return err;
    }

    /// Trace everything the marking barrier shaded grey, then handle
    /// overflow by the coarse route.
    ///
    /// A queue entry is marked with untraced children; tracing it and
    /// draining makes it genuinely black. Overflow does not lose work -- the
    /// object stays marked and the flag stays set -- but it does lose the
    /// ADDRESS, so the downgrade is one pass over every marked object,
    /// tracing each. That is strictly more scanning and strictly no less
    /// discovery (`gc_mark_queue.zig`'s contract). One pass suffices: any
    /// object the pass shades goes onto the ordinary work list and is traced
    /// transitively by the drain before the pass moves on.
    fn drainBarrierQueue(self: *Collector) CollectError!usize {
        if (comptime !gc.concurrent_enabled) return 0;
        const queue = &self.rt.gc.concurrent_mark_queue;
        var drained: usize = 0;
        while (queue.pop()) |header| {
            drained += 1;
            try self.traceHeader(header);
            if (self.err) |err| return err;
            try self.drain();
        }
        if (queue.hasOverflowed()) {
            var it = self.rt.gc.objectIterator();
            while (it.next()) |header| {
                if (!self.rt.gc.headerMarked(header)) continue;
                try self.traceHeader(header);
                if (self.err) |err| return err;
                try self.drain();
            }
            queue.clearOverflow();
        }
        return drained;
    }

    fn drain(self: *Collector) CollectError!void {
        while (self.work.pop()) |header| {
            try self.traceHeader(header);
            if (self.err) |err| return err;
        }
    }

    fn traceHeader(self: *Collector, header: *gc.Header) CollectError!void {
        switch (header.meta().flags.kind) {
            .object => {
                const obj: *Object = @alignCast(@fieldParentPtr("header", header));
                try obj.traceChildEdgesFallible(self.rt, self);
                if (self.err) |err| return err;
            },
            .function_bytecode => {
                const fb: *FunctionBytecode = @alignCast(@fieldParentPtr("header", header));
                self.visitRealm(&fb.realm.ptr);
                for (fb.cpoolSlice()) |*stored| self.visitValue(stored);
            },
            .var_ref => {
                const ref: *var_ref_mod.VarRef = @alignCast(@fieldParentPtr("header", header));
                self.visitValue(&ref.value);
            },
            .shape => {
                const shape_ref: *shape.Shape = @alignCast(@fieldParentPtr("header", header));
                try shape_ref.traceChildEdgesFallible(self.rt, self);
                if (self.err) |err| return err;
            },
            .realm_context => {
                const ctx: *context_mod.JSContext = @alignCast(@fieldParentPtr("header", header));
                ctx.traceChildEdgesNoFail(self);
                if (self.err) |err| return err;
            },
            .module => {
                const record: *module_mod.ModuleRecord = @alignCast(@fieldParentPtr("header", header));
                try record.traceChildEdgesFallible(self.rt, self);
                if (self.err) |err| return err;
            },
            .string, .big_int => {},
        }
    }

    fn ephemeronFixedPoint(self: *Collector) CollectError!void {
        while (true) {
            const before = self.report.ephemeron_values_shaded;
            var holder = self.rt.weak_reference_holder_head;
            while (holder) |object| {
                const next = object.weakReferenceHolderNext();
                if (self.rt.gc.headerMarked(&object.header)) {
                    if (object.collectionPayloadForCycleGc()) |payload| {
                        for (payload.weak_entries) |*entry| {
                            if (!keyIsMarked(self.rt, entry.key_identity)) continue;
                            const child = entry.value.cycleMarkHeader() orelse continue;
                            if (self.rt.gc.headerMarked(child)) continue;
                            self.shade(child);
                            self.report.ephemeron_values_shaded += 1;
                        }
                    }
                }
                holder = next;
            }
            if (self.err) |err| return err;
            try self.drain();
            self.report.ephemeron_rounds += 1;
            if (self.report.ephemeron_values_shaded == before) break;
        }
    }

    fn processWeak(self: *Collector) void {
        self.rt.gc.beginDecrefPhase();
        defer self.rt.gc.endDecrefPhase(self.rt);

        for (self.rt.weak_root_slots) |slot| {
            const identity = slot.identity orelse continue;
            if (!keyIsMarked(self.rt, identity)) {
                self.rt.clearWeakRootSlot(slot, true);
            }
        }

        var finalization_enqueue_blocked = false;
        var current = self.rt.weak_reference_holder_head;
        while (current) |holder| {
            const next = holder.weakReferenceHolderNext();
            if (self.rt.gc.headerMarked(&holder.header)) {
                self.sweepHolder(holder, &finalization_enqueue_blocked);
            }
            current = next;
        }
    }

    fn sweepHolder(self: *Collector, holder: *Object, finalization_enqueue_blocked: *bool) void {
        if (holder.weakRefPayloadForCycleGc()) |payload| {
            if (payload.weak_target_identity) |identity| {
                if (!keyIsMarked(self.rt, identity)) {
                    self.rt.clearWeakIdentitySlot(&payload.weak_target_identity);
                    self.report.weakrefs_cleared += 1;
                }
            }
        }

        if (holder.collectionPayloadForCycleGc()) |payload| {
            var read_index: usize = 0;
            var write_index: usize = 0;
            var removed = false;
            while (read_index < payload.weak_entries.len) : (read_index += 1) {
                const entry = payload.weak_entries[read_index];
                if (keyIsMarked(self.rt, entry.key_identity)) {
                    if (write_index != read_index) payload.weak_entries[write_index] = entry;
                    write_index += 1;
                    continue;
                }
                self.rt.releaseWeakIdentity(entry.key_identity);
                entry.value.free(self.rt);
                removed = true;
                self.report.weak_entries_dropped += 1;
            }
            if (removed) {
                payload.weak_entries = payload.weak_entries.ptr[0..write_index];
                holder.clearCollectionIndex(self.rt);
            }
        }

        const finalization_payload = holder.finalizationRegistryPayloadForCycleGc() orelse {
            holder.pruneBorrowedReferenceHolderIfEmpty(self.rt);
            return;
        };
        var read_index: usize = 0;
        var write_index: usize = 0;
        while (read_index < finalization_payload.cells.len) : (read_index += 1) {
            var cell = finalization_payload.cells[read_index];
            if (cell.unregister_token_identity) |identity| {
                if (!keyIsMarked(self.rt, identity)) {
                    self.rt.clearWeakIdentitySlot(&cell.unregister_token_identity);
                }
            }
            const target_identity = cell.target_identity orelse {
                finalization_payload.cells[write_index] = cell;
                write_index += 1;
                continue;
            };
            if (keyIsMarked(self.rt, target_identity)) {
                finalization_payload.cells[write_index] = cell;
                write_index += 1;
                continue;
            }

            if (cell.state == .queued) continue;
            if (cell.isActive()) cell.state = .pending_enqueue;
            if (finalization_enqueue_blocked.*) {
                finalization_payload.cells[write_index] = cell;
                write_index += 1;
                continue;
            }
            // Tombstone before enqueue/destroy so a reentrant collection cannot
            // consume another cell's reserved job slot (§9.3).
            finalization_payload.cells[read_index].state = .queued;
            object_gc.enqueueFinalizationCleanup(self.rt, finalization_payload, cell.held_value);
            cell.state = .queued;
            cell.destroy(self.rt);
            self.report.finalization_enqueued += 1;
        }
        finalization_payload.cells = finalization_payload.cells.ptr[0..write_index];
        holder.pruneBorrowedReferenceHolderIfEmpty(self.rt);
    }

    /// Young-only sweep for a minor. An old object cannot be proven dead by a
    /// minor -- its incoming edges were never traced -- so only unmarked young
    /// objects are condemned, and old marks are left alone rather than reset.
    fn sweepUnmarkedYoung(self: *Collector) usize {
        gc.listInit(&self.rt.gc.tmp_obj_list);

        var doomed: std.ArrayList(*gc.Header) = .empty;
        defer doomed.deinit(self.allocator());
        var young_it = self.rt.gc.youngIterator();
        while (young_it.next()) |header| {
            if (self.rt.gc.headerMarked(header)) continue;
            if (header.metaConst().flags.is_pinned) continue;
            // Every condemned kind is freed, not just `.object` -- see
            // `destroyCondemned`. A young var_ref or shape the trace did not
            // reach is exactly as dead as a young object it did not reach, and
            // leaving it linked leaves it pointing at freed children.
            // The trace is the liveness authority. This used to skip anything
            // with `rc > 0`, which made the minor unable to reclaim the only
            // garbage it could add value on -- a young cycle holds both halves
            // above zero -- so a minor reclaimed nothing that refcounting had
            // not already taken (measured: 500 fresh cyclic pairs, reclaimed 0,
            // survived_by_refcount 1000). The full major has never consulted
            // the count (`sweepUnmarked` condemns on mark and pin alone) and
            // clears test262 at 0/49778, so the trace is already the authority
            // everywhere else; the minor now agrees with it. A young object the
            // trace did not reach is a missing root or a missing barrier, and
            // must fail loudly rather than be masked by a count.
            doomed.append(self.allocator(), header) catch return 0;
        }
        if (verify_armed) {
            verify_armed = false;
            var violations: usize = 0;
            for (doomed.items) |header| {
                if (!verify_reachable.contains(@intFromPtr(header))) continue;
                violations += 1;
                const kind = header.metaConst().flags.kind;
                if (kind == .object) {
                    const o: *Object = @alignCast(@fieldParentPtr("header", header));
                    std.debug.print("VERIFY-MINOR condemned-but-reachable kind=object class={d} payload={s}\n", .{ o.class_id, @tagName(o.flags.class_payload_kind) });
                } else {
                    std.debug.print("VERIFY-MINOR condemned-but-reachable kind={s}\n", .{@tagName(kind)});
                }
            }
            if (violations != 0) {
                std.debug.print("VERIFY-MINOR {d} of {d} condemned objects are reachable by a full trace\n", .{ violations, doomed.items.len });
            }
        }
        if (gc.minor_audit) self.auditCondemnedYoung(doomed.items);
        for (doomed.items) |header| {
            self.rt.gc.detachCycleCandidate(header);
            gc.listAddTail(&self.rt.gc.tmp_obj_list, header);
        }

        const old_phase = self.rt.gc.phase;
        self.rt.gc.phase = .remove_cycles;
        defer self.rt.gc.phase = old_phase;

        const reclaimed = self.destroyCondemned();
        gc.listInit(&self.rt.gc.tmp_obj_list);

        // Destroying under `.remove_cycles` parks every struct free on
        // `cycle_deferred_frees` so a finalizer cannot observe a sibling's
        // memory being reused mid-pass. The major sweep drains that queue
        // before it returns; the minor did not, so a minor reported N
        // reclaimed objects while returning zero bytes to the allocator --
        // and `pollGC` then recomputed the major threshold from an
        // `allocated_bytes` that had not moved, ratcheting it up by half on
        // every minor. Drain inside the `.remove_cycles` scope, on the same
        // pending-finalizer condition the major uses.
        if (!self.rt.hasPendingDeferredClassPayloadFinalizers()) object_gc.drainCycleDeferredFrees(self.rt);

        // Survivors keep their marks: that is what makes them old.
        return reclaimed;
    }

    fn sweepUnmarked(self: *Collector) usize {
        gc.listInit(&self.rt.gc.tmp_obj_list);

        var iterator = self.rt.gc.deadCandidateIterator();
        while (iterator.next()) |header| {
            if (self.rt.gc.headerMarked(header)) {
                // The mark STAYS. §8.2's sticky rule is `allocated && marked`
                // is old, and the survivor's mark is what tells the next
                // minor's `shade()` to stop at it -- clearing here made the
                // first minor after every major find the whole heap unmarked
                // and re-trace the entire live set from the roots (~29 ms per
                // probe minor on splay, against a 1 ms target). The next
                // major's `clearMarks` is the clearer; this used to clear a
                // second time. Retiring the young bit rides the same walk,
                // which is what deleted `clearYoungState`'s third whole-heap
                // pass.
                header.meta().flags.young = false;
                continue;
            }
            if (header.metaConst().flags.is_pinned) {
                // An unmarked-but-pinned survivor must retire its young bit
                // too: it leaves the suffix when `young_head` resets below,
                // and a stale young bit would make the barrier remember its
                // owner on every store, forever.
                header.meta().flags.young = false;
                continue;
            }
            self.rt.gc.detachCycleCandidate(header);
            gc.listAddTail(&self.rt.gc.tmp_obj_list, header);
        }

        const old_phase = self.rt.gc.phase;
        self.rt.gc.phase = .remove_cycles;
        defer self.rt.gc.phase = old_phase;

        const garbage_count = self.destroyCondemned();
        if (!self.rt.hasPendingDeferredClassPayloadFinalizers()) object_gc.drainCycleDeferredFrees(self.rt);
        return garbage_count;
    }

    /// Diagnostic (`ZJS_MINOR_AUDIT=1`): report any live object still holding a
    /// strong edge to something this minor is about to condemn.
    ///
    /// That combination is exactly a missing write barrier -- the trace could
    /// not reach the child, so the owner must be old and unremembered -- and
    /// this names the owner instead of leaving it to be guessed from the
    /// eventual JS-visible symptom.
    ///
    /// Known blind spot, worth stating because it cost a day: this walks the
    /// SAME `traceChildEdges` enumeration the collector does, so an edge the
    /// tracer does not know about is equally invisible here. A clean run means
    /// "no owner forgot to remember a child it does declare", not "no live
    /// reference to the condemned set exists" -- native windows and undeclared
    /// slots are outside it entirely, and that is where the bug it was built
    /// to find actually was (`Stack.pending_call_region`).
    fn auditCondemnedYoung(self: *Collector, doomed_items: []const *gc.Header) void {
        const Audit = struct {
            doomed: []const *gc.Header,
            rt: *JSRuntime,
            owner_kind: gc.GcKind = .object,
            owner_class: u32 = 0,
            owner_ptr: *gc.Header = undefined,
            owner_young: bool = false,
            owner_remembered: bool = false,
            fn hit(a: *@This(), h: ?*gc.Header) void {
                const child = h orelse return;
                for (a.doomed) |d| {
                    if (d != child) continue;
                    const c: *Object = @alignCast(@fieldParentPtr("header", child));
                    if (a.owner_kind == .object) {
                        const o: *Object = @alignCast(@fieldParentPtr("header", a.owner_ptr));
                        var where: []const u8 = "unknown";
                        var hit_atom: u32 = 0;
                        if (o.promisePayload()) |pp| {
                            if (pp.result) |v| if (v.cycleMarkHeader() == child) {
                                where = "promise.result";
                            };
                            if (pp.reaction_callback) |v| if (v.cycleMarkHeader() == child) {
                                where = "promise.reaction_callback";
                            };
                            if (pp.reaction_arg) |v| if (v.cycleMarkHeader() == child) {
                                where = "promise.reaction_arg";
                            };
                            for (pp.reactions) |v| {
                                if (v.cycleMarkHeader() == child) where = "promise.reactions";
                            }
                        }
                        if (o.isFastArray()) {
                            for (o.fastArrayValues()) |v| {
                                if (v.cycleMarkHeader() == child) where = "dense";
                            }
                        }
                        for (o.propertyEntries(), 0..) |*e, pi| {
                            const pf = property.Flags.fromBits(o.shape_ref.props()[pi].flags);
                            if (pf.deleted) continue;
                            switch (pf.kind) {
                                .data => if (e.slot.data.cycleMarkHeader() == child) {
                                    where = "prop_data";
                                    hit_atom = o.shape_ref.props()[pi].atom_id;
                                },
                                .accessor => {
                                    if (e.slot.accessor.getter) |g| if (g == child) {
                                        where = "prop_getter";
                                    };
                                    if (e.slot.accessor.setter) |st| if (st == child) {
                                        where = "prop_setter";
                                    };
                                },
                                else => {},
                            }
                        }
                        std.debug.print("MINOR-AUDIT-WHERE owner_class={d} payload={s} where={s} atom={s} nprops={d} owner_marked={}\n", .{ o.class_id, @tagName(o.flags.class_payload_kind), where, a.rt.atoms.name(@intCast(hit_atom)) orelse "?", o.shape_ref.prop_count, a.rt.gc.headerMarked(&o.header) });
                    }
                    std.debug.print("MINOR-AUDIT owner={s}/ptr{x} owner_young={} owner_remembered={} -> child class={d}/{s} child_young={} child_marked={}\n", .{
                        @tagName(a.owner_kind), @intFromPtr(a.owner_ptr), a.owner_young, a.owner_remembered,
                        c.class_id,             @tagName(c.flags.class_payload_kind),
                        child.metaConst().flags.young, a.rt.gc.headerMarked(child),
                    });
                    return;
                }
            }
            pub fn visitValue(a: *@This(), val: *JSValue) void {
                a.hit(val.cycleMarkHeader());
            }
            pub fn visitObject(a: *@This(), obj_ptr: *?*Object) void {
                if (obj_ptr.*) |o| a.hit(&o.header);
            }
            pub fn visitShape(a: *@This(), sh: *shape.Shape) void {
                a.hit(&sh.header);
            }
            pub fn visitRealm(a: *@This(), ctx_ptr: *?*context_mod.RealmContext) void {
                if (ctx_ptr.*) |c| a.hit(&c.header);
            }
            pub fn visitModule(a: *@This(), record: *module_mod.ModuleRecord) void {
                a.hit(&record.header);
            }
            pub fn visitRealm2(a: *@This(), ctx_ptr: *?*context_mod.RealmContext) void {
                if (ctx_ptr.*) |c| a.hit(&c.header);
            }
            pub fn visitWeakCollectionEntry(_: *@This(), _: *object_payloads.WeakCollectionEntry) void {}
            pub fn visitFinalizationCell(_: *@This(), _: *object_payloads.FinalizationRegistryCell) void {}
        };
        var audit = Audit{ .doomed = doomed_items, .rt = self.rt };
        var it = self.rt.gc.objectIterator();
        while (it.next()) |h| {
            var condemned = false;
            for (doomed_items) |d| {
                if (d == h) {
                    condemned = true;
                    break;
                }
            }
            if (condemned) continue;
            audit.owner_kind = h.metaConst().flags.kind;
            audit.owner_ptr = h;
            audit.owner_young = h.metaConst().flags.young;
            audit.owner_remembered = blk: {
                var rit = self.rt.gc.generation.rememberedIterator();
                while (rit.next()) |addr| {
                    if (addr.* == @intFromPtr(h)) break :blk true;
                }
                break :blk false;
            };
            switch (h.metaConst().flags.kind) {
                .object => {
                    const owner: *Object = @alignCast(@fieldParentPtr("header", h));
                    audit.owner_class = owner.class_id;
                    owner.traceChildEdgesFallible(self.rt, &audit) catch {};
                },
                .shape => {
                    const sh: *shape.Shape = @alignCast(@fieldParentPtr("header", h));
                    audit.owner_class = 0;
                    sh.traceChildEdgesFallible(self.rt, &audit) catch {};
                },
                .var_ref => {
                    const cell: *var_ref_mod.VarRef = @alignCast(@fieldParentPtr("header", h));
                    audit.owner_class = if (cell.is_open) 1 else 2;
                    audit.visitValue(&cell.value);
                },
                .function_bytecode => {
                    const fb: *FunctionBytecode = @alignCast(@fieldParentPtr("header", h));
                    audit.owner_class = 0;
                    audit.visitRealm(&fb.realm.ptr);
                    for (fb.cpoolSlice()) |*stored| audit.visitValue(stored);
                },
                .realm_context => {
                    const ctx: *context_mod.JSContext = @alignCast(@fieldParentPtr("header", h));
                    audit.owner_class = 0;
                    ctx.traceChildEdgesNoFail(&audit);
                },
                .module => {
                    const record: *module_mod.ModuleRecord = @alignCast(@fieldParentPtr("header", h));
                    audit.owner_class = 0;
                    record.traceChildEdgesFallible(self.rt, &audit) catch {};
                },
                else => {},
            }
        }
    }

    /// Ordered teardown of everything condemned onto `tmp_obj_list`.
    ///
    /// The order is load-bearing (qjs `gc_free_cycles`): objects first, then
    /// realms, modules and function bytecode, and only then the cells and
    /// shapes whose contents those releases were still reading. Destroying
    /// under `.remove_cycles` parks every struct free, so a destructor
    /// dereferencing a sibling already torn down in an earlier pass reads
    /// stripped-but-allocated memory rather than freed memory.
    ///
    /// Both sweeps share this. They did not: the minor condemned and destroyed
    /// only `.object`, so a young var_ref that was equally unreachable survived
    /// the minor while the object it held was freed, and the next major's
    /// var_ref teardown released a refcount through a dangling pointer. The
    /// condemned set has to be closed under "reachable only from other
    /// condemned nodes", and the only way to keep it closed is to free every
    /// kind the trace condemned, not a subset.
    fn destroyCondemned(self: *Collector) usize {
        var garbage_count: usize = 0;
        var cursor = self.rt.gc.tmp_obj_list.next;
        while (cursor) |h| {
            if (h == &self.rt.gc.tmp_obj_list) break;
            const next = h.next;
            if (h.meta().flags.kind == .object) {
                gc.listDel(h);
                garbage_count += 1;
                self.rt.gc.sweep_current = h;
                Object.destroyFromHeader(self.rt, h);
                self.rt.gc.sweep_current = null;
            }
            cursor = next;
        }
        cursor = self.rt.gc.tmp_obj_list.next;
        while (cursor) |h| {
            if (h == &self.rt.gc.tmp_obj_list) break;
            const next = h.next;
            if (h.meta().flags.kind == .realm_context) {
                gc.listDel(h);
                garbage_count += 1;
                self.rt.gc.unlinkObjectWithBytes(h, gc.Registry.heapByteSizeFromHeader(self.rt, h));
                self.rt.gc.sweep_current = h;
                context_mod.JSContext.destroyFromHeader(self.rt, h);
                self.rt.gc.sweep_current = null;
            }
            cursor = next;
        }
        cursor = self.rt.gc.tmp_obj_list.next;
        while (cursor) |h| {
            if (h == &self.rt.gc.tmp_obj_list) break;
            const next = h.next;
            if (h.meta().flags.kind == .module) {
                gc.listDel(h);
                garbage_count += 1;
                self.rt.gc.unlinkObjectWithBytes(h, gc.Registry.heapByteSizeFromHeader(self.rt, h));
                self.rt.gc.sweep_current = h;
                module_mod.ModuleRecord.destroyFromHeader(self.rt, h);
                self.rt.gc.sweep_current = null;
            }
            cursor = next;
        }
        cursor = self.rt.gc.tmp_obj_list.next;
        while (cursor) |h| {
            if (h == &self.rt.gc.tmp_obj_list) break;
            const next = h.next;
            if (h.meta().flags.kind == .function_bytecode) {
                gc.listDel(h);
                self.rt.gc.unlinkObjectWithBytes(h, gc.Registry.heapByteSizeFromHeader(self.rt, h));
                self.rt.gc.sweep_current = h;
                function_bytecode_mod.destroyFromHeader(self.rt, h);
                self.rt.gc.sweep_current = null;
            }
            cursor = next;
        }
        while (gc.listFirst(&self.rt.gc.tmp_obj_list)) |h| {
            gc.listDel(h);
            switch (h.meta().flags.kind) {
                .var_ref => {
                    garbage_count += 1;
                    self.rt.gc.unlinkObjectWithBytes(h, gc.Registry.heapByteSizeFromHeader(self.rt, h));
                    self.rt.gc.sweep_current = h;
                    var_ref_mod.VarRef.destroyFromHeader(self.rt, h);
                    self.rt.gc.sweep_current = null;
                },
                .shape => {
                    garbage_count += 1;
                    if (!h.meta().flags.finalizing) self.rt.shapes.destroyFromHeader(h);
                },
                else => unreachable,
            }
        }

        return garbage_count;
    }
};

fn keyIsMarked(rt: *const JSRuntime, identity: usize) bool {
    if ((identity & 1) != 0) {
        const atom_id = identity >> 1;
        if (atom_id > std.math.maxInt(@import("atom.zig").Atom)) return false;
        return rt.atoms.kind(@intCast(atom_id)) == .symbol;
    }
    const object = rt.liveObjectFromWeakIdentity(identity) orelse return false;
    return rt.gc.headerMarked(&object.header);
}

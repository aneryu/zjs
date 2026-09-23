//! Poll routing, growth-threshold reset, and doomed-destruction completion.
//!
//! `JSRuntime.pollGC` still checks the owner thread, skips a poll while a
//! payload finalizer is active, and drains deferred cleanup first. This
//! module owns the minor/major decision, the threshold write, and finishing
//! an interrupted destruction. `gc_running` stays separate from `phase`.

const mem_ops = @import("memory.zig");
const std = @import("std");
const gc = @import("gc.zig");
const profile = @import("profile.zig");
const runtime_mod = @import("../runtime.zig");
const JSRuntime = runtime_mod.JSRuntime;
const GCPollMode = runtime_mod.GCPollMode;
const ValueRootFrame = runtime_mod.ValueRootFrame;

pub fn continuePoll(
    self: *JSRuntime,
    roots: ?*const ValueRootFrame,
    mode: GCPollMode,
) gc.CollectionError!gc.CollectionResult {
    // A morgue can only be non-empty if a collection was interrupted
    // mid-destruction by an allocation failure; finish it before starting
    // anything new. Destruction is irreversible.
    if (self.gc.morgue.pending and !self.gc_running and self.gc.hot.phase == .none) {
        self.gc_running = true;
        @import("gc_trace_stw.zig").finishPendingDestruction(self);
        self.gc_running = false;
        _ = finishDoomed(self, 0);
    }
    // Is the whole-heap threshold already crossed? The crossing decides
    // the ORDER of the two collections below, and it is asked TWICE: once
    // here, and again on the account a minor leaves behind.
    //
    // A minor may not ANSWER a crossing. It does not reach the old
    // generation, which is where a heap over its threshold has put its
    // garbage. Letting it free a handful of young objects, report success
    // and return meant the major check below was never reached, and
    // nothing ever collected the old generation: earley-boyer performed
    // 13,642 minors and zero majors, promoted 6.8M objects, and finished
    // holding 435MB where refcounting held 3MB, with every one of those
    // minors paying 1.12ms to trace a heap that large. See
    // the minor/major threshold crossing.
    //
    // The first repair skipped the minor entirely on a crossing, which
    // reads the crossing as PROOF that the garbage is old. Since S2 that
    // inference is false: string bodies are collector carriers, so a dead
    // young string stays in `allocated_bytes` until a collection frees it,
    // and pure allocation churn drives the account past the threshold with
    // nothing old behind it at all. pdfjs paid 908 whole-heap majors where
    // the refcounting baseline paid 6.
    //
    // So the order is generational -- minor first -- and the verdict is
    // the SECOND reading. Old-generation garbage survives the minor, the
    // account is still over, and the major runs exactly as it did before:
    // earley-boyer's repair is a consequence of the re-read, not of
    // withholding the minor. Young churn is answered by the young
    // collection, and the crossing is simply gone.
    var over_threshold = self.gc.heap_budget.bytes > self.gc.heap_budget.gc_threshold;
    // The crossing is usually REPORTED, not observed here.
    // `collectBeforeObjectAllocation` tests `allocated_bytes + size` and
    // records `.allocation_threshold`/`.soon` BEFORE the allocation lands,
    // then polls; the poll's own account is still one allocation short of
    // the bar. Instrumented on pdfjs: this line saw 33 crossings against
    // 874 majors -- the other 841 arrived as that pending request, so a
    // minor-first rule written against `allocated_bytes` alone never fired.
    const crossing = over_threshold or self.gc.scheduler.pendingAllocationThresholdRequest();
    // §8.5: an automatic poll prefers a minor. A minor only reaches the
    // young set, so allocation churn is reclaimed without a whole-heap
    // trace -- but only here. An explicit `runObjectCycleRemoval` means
    // "collect everything", and answering it with a minor would silently
    // change what that call promises.
    //
    // A crossing widens the offer to `normal` as well. `acceptsMinor` asks
    // whether a minor may BE the answer; a crossing asks the cheap
    // collection first and then re-reads the account, so the minor is a
    // precondition of the major rather than a substitute for it, and the
    // caller of a threshold collection still receives everything it did.
    // This matters because the crossing is almost always DISCOVERED at a
    // `normal` poll: `collectBeforeObjectAllocation` is the boundary
    // `String.createUninitialized` reaches on the very allocation that
    // goes over (TGC S2-f), so an offer restricted to the scheduler modes
    // never gets asked. Measured on pdfjs: unchanged at 909 majors when
    // this read `acceptsMinor()` alone.
    //
    // `urgent` and `idle` keep out of the crossing arm, and one test
    // covers both: they are the precise-scanning modes. `urgent`'s caller
    // is out of headroom and wants the whole heap examined rather than one
    // more pause before it; `idle`'s precise scan is host-quiescent by
    // design, and a synchronous minor needs the conservative one -- see
    // `pollScansConservatively`.
    //
    // The crossing also asks a different SIZE question of the young set --
    // see `Registry.shouldTryMinorBeforeMajor`.
    const offer_minor = if (crossing)
        self.pollScansConservatively(mode) and self.gc.shouldTryMinorBeforeMajor()
    else
        mode.acceptsMinor() and self.gc.shouldTryMinor();
    if (offer_minor and !self.gc_running) {
        self.gc_running = true;
        defer self.gc_running = false;
        mem_ops.samplePeakAtCollection(self);
        const started = profile.nowNanos();
        if (@import("gc_trace_stw.zig").collectMinor(self, roots, mode.rootScan()) catch null) |freed| {
            self.gc.stats.collections += 1;
            const ended = profile.nowNanos();
            const elapsed = if (ended > started) ended - started else 0;
            // Tracked separately from the major distribution: a minor
            // is judged on being short, and averaging it with
            // whole-heap pauses hides exactly that.
            //
            // Counted whether or not it reclaimed anything. A minor
            // that frees nothing is the EXPENSIVE case, not a
            // non-event: it walked its roots and every remembered
            // owner and came back empty. Pricing those at zero made
            // the panel report `minor pause mean 0 ns, max 0 ns` for a
            // run that performed 320 of them, which is precisely the
            // shape anyone optimising the minor needs to see.
            self.gc.generation.recordMinorPause(
                gc.Registry.markQueueAllocator(),
                elapsed,
                @import("gc_trace_stw.zig").detailed_reports,
            );
            // TGC S2-h1 (2). The aged-decommit policy used to be
            // driven from major boundaries alone. S2-g took pdfjs
            // from 908 majors to 24, so the block decommit and the
            // empty-medium-superblock release stopped being offered
            // ~884 times per run and maxrss rose 31% (raytrace 33%)
            // on a live set that had FALLEN -- a superblock high
            // water mark, not retained garbage.
            //
            // A minor is now the same boundary: cells and medium
            // extents are exactly what it frees. Nothing about the
            // policy changes -- `releaseFreeBlockPages` keeps its own
            // 100 ms period gate and both idle gates
            // (`decommit_min_idle_ns`, `medium_release_min_idle_ns`)
            // -- so this only stops the offers from being withheld.
            // Placed after `elapsed` is taken, like the major call
            // sites: the release is not part of the pause it reports.
            // It also advances `Heap.clock_ns`, which is what makes
            // the idle gates measure real idleness again instead of
            // ageing against a clock that only ticked 24 times.
            _ = self.gc.block_heap.releaseFreeBlockPages(ended);
            const result: gc.CollectionResult = .{
                .freed_objects = freed,
                .duration_ns = elapsed,
            };
            // NOT `recordSuccess`: that would push a minor's duration
            // into the major pause ring and count it as a whole-heap
            // cycle. The minor's own pause accounting is the
            // `generation.stats` update just above. This holds on the
            // fall-through below too -- a minor that precedes a major
            // in the same poll contributes its reclaim to the freed
            // account but never its time to the major's pause ring.
            if (freed > 0) self.gc.recordMinorSuccess(result);
            // Deliberately NOT `resetGCThreshold()`. That sets the
            // major threshold to 1.5x the CURRENT footprint and
            // clears the allocation debt, and a minor has no claim
            // to either: it did not look at the old generation, so
            // the footprint it is measuring is mostly old garbage
            // it cannot see. Resetting here raised the bar by half
            // on every minor, so the more garbage accumulated the
            // further the major receded -- the threshold outran the
            // heap it was meant to bound. Both belong to the major.
            if (crossing) {
                // The second verdict, on the account this minor left
                // behind. Still over means the garbage the threshold
                // is complaining about was not young, so fall through
                // to the major with the crossing intact.
                over_threshold = self.gc.heap_budget.bytes > self.gc.heap_budget.gc_threshold;
                if (!over_threshold) {
                    // The crossing WAS young churn and is now paid.
                    // The threshold condition is level-triggered, so
                    // the `.allocation_threshold`/`.soon` request an
                    // allocation boundary recorded on the way up is
                    // stale: discard exactly that request, the way
                    // `collectBeforeObjectAllocation` does when a
                    // prospective total falls back under the bar.
                    _ = self.gc.scheduler.clearStaleAllocationThresholdRequest();
                    // Only the threshold's own request is retired by a
                    // minor. A host manual GC, memory pressure or a
                    // failure retry that happened to be queued behind
                    // it is a promise to someone: leave the poll on its
                    // major path so this call still keeps it.
                    if (!self.gc.hasPendingMajorRequest()) return result;
                }
            } else if (freed > 0) {
                return result;
            }
        }
    }
    if (self.gc_running or self.gc.hot.phase != .none) return .{};
    const scheduler_point: gc.SchedulerPoint = switch (mode) {
        .normal => .allocation_slow_path,
        .callback_boundary => .callback_boundary,
        .idle => .idle,
        .safepoint => .safepoint,
        .urgent => .urgent,
    };
    const over_collection_threshold = over_threshold;
    const run_major = self.gc.scheduler.shouldRunMajorAt(scheduler_point, over_collection_threshold);
    if (!run_major) return .{};

    const major_request = self.gc.scheduler.pendingMajorRequest();
    if (major_request != null) _ = self.gc.scheduler.clearMajorRequest();
    const reason = if (major_request) |request|
        request.reason
    else if (over_collection_threshold)
        gc.RequestReason.allocation_threshold
    else
        gc.RequestReason.manual;
    self.gc.scheduler.beginMajorCycle(reason);
    return try self.tryRunObjectCycleRemovalWithValueRoots(null, mode.rootScan());
}

pub fn resetThresholdExcludingDoomed(self: *JSRuntime) void {
    const settled = self.gc.heap_budget.bytes -| self.gc.morgue.bytes;
    const saved = self.gc.heap_budget.bytes;
    // Reuse the one rule rather than duplicating it: present the heap
    // budget net of corpses, compute, restore. Single-threaded.
    self.gc.heap_budget.bytes = settled;
    resetThreshold(self);
    self.gc.heap_budget.bytes = saved;
}

pub fn finishDoomed(self: *JSRuntime, last_slice_ns: u64) gc.CollectionResult {
    std.debug.assert(!self.gc.morgue.pending);
    @import("gc_trace_stw.zig").auditDoomedExitInvariant(self);
    const result: gc.CollectionResult = .{
        .freed_objects = self.gc.morgue.destroyed,
        .duration_ns = last_slice_ns,
    };
    self.gc.morgue.destroyed = 0;
    self.gc.recordCycleSuccess(result);
    resetThreshold(self);
    _ = self.gc.block_heap.releaseFreeBlockPages(profile.nowNanos());
    return result;
}

pub fn resetThreshold(self: *JSRuntime) void {
    // Refcounting keeps qjs's rule verbatim (js_trigger_gc after JS_RunGC,
    // quickjs.c): threshold = malloc_size + (malloc_size >> 1).
    //
    // The tracer gets 2x, and the divergence is deliberate: qjs's 1.5x
    // governs a CYCLE collector running over a heap where refcounting has
    // already freed every acyclic object, so each round handles residue.
    // A tracer must trace the whole live set to free anything at all --
    // the cost of a collection is proportional to what survives, not to
    // what dies -- so the same constant buys far less allocation per
    // whole-heap trace. Copying it across that semantic change was
    // faithfulness to the wrong collector: splay completed in 16 rounds
    // under rc and paid ~41 whole-heap majors under the tracer at 1.5x.
    // JSC's precedent for a full-tracing heap is a growth factor of 2 on
    // small heaps (smallHeapGrowthFactor, OptionsList.h:219; "small" is
    // heap < 25% of RAM). The factor here was 1.75 while §1.3 capped
    // cycle peak/live at 1.8; the owner renegotiated that cap to 2.0 on
    // 2026-08-29 (ABBA n=16 pricing: splay cycles -7.25%, six-benchmark
    // geomean 0.9867, peak RSS +10-13%).
    // Steady-state cycle peak/live equals this factor by construction,
    // so the constant and the §1.3 cap must move together.
    const live_now = self.gc.heap_budget.bytes;
    const grown = std.math.add(usize, live_now, live_now) catch std.math.maxInt(usize);
    // ...plus room for one nursery. Half of a small live set is less than
    // a nursery, and since the threshold is tested before a minor is
    // offered, such a threshold would be crossed first every time and
    // every collection would be a major. raytrace lives in 288KB, so the
    // qjs rule alone gives it 144KB of headroom to fill a nursery that
    // wants an order of magnitude more.
    const headroom = gc.small_heap_major_headroom_bytes;
    const floored = std.math.add(usize, self.gc.heap_budget.bytes, headroom) catch std.math.maxInt(usize);
    self.gc.heap_budget.gc_threshold = @max(grown, floored);
    // Both rules add to the live set, so the threshold can never sit below
    // it: a threshold under the heap budget would make the very next
    // heap allocation trigger a collection.
    std.debug.assert(self.gc.heap_budget.gc_threshold >= self.gc.heap_budget.bytes);
    // Which rule set the cadence. Without this the claim "raytrace's
    // majors are paced by the floor, not by growth" stays an inference
    // from arithmetic; with it, it is a reading.
    if (floored > grown) {
        self.gc.stats.threshold_floor_hits +|= 1;
    } else {
        self.gc.stats.threshold_growth_hits +|= 1;
    }
    // A pending morgue uses a provisional threshold net of doomed bytes;
    // no new cycle may begin before destruction completes, and the final
    // reset below will publish the actual settled pair.
    if (!self.gc.morgue.pending) {
        self.gc.noteCycleEnvelopeBaseline(self.gc.heap_budget.bytes, self.gc.heap_budget.gc_threshold);
    }
    self.gc.resetAllocationDebt();
}

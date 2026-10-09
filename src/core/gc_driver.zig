//! Collection orchestration: full collections, poll routing, allocation
//! triggers, the heap-limit retry, growth-threshold reset, and doomed-
//! destruction completion.
//!
//! Every entry checks the owner thread and tracing reentry itself; the
//! `JSRuntime` methods of the same names are aliases. Full collection, an
//! ordinary poll, and the heap-limit retry keep their own scan and error
//! contracts. `gc.hot.collecting` stays separate from `phase`.

const std = @import("std");
const builtin = @import("builtin");
const gc = @import("gc.zig");
const gc_scope = @import("gc_scope.zig");
const runtime_mod = @import("../runtime.zig");
const native_allocation = runtime_mod.native_allocation;
const JSRuntime = runtime_mod.JSRuntime;
const PollMode = gc.PollMode;
const ValueRootFrame = runtime_mod.ValueRootFrame;

/// Service pending collection requests at a poll of `mode`: a minor when
/// the young set warrants one, then a major when the scheduler says so.
pub fn pollGC(self: *JSRuntime, mode: PollMode) gc.CollectionError!gc.CollectionResult {
    self.assertOwnerThread();
    self.assertGCAllowed();
    if (self.roots.isTracing()) @panic("collection reentry during tracing");
    // A minor clears dead weak slots too (`processWeak`). Registered first so
    // it runs last, after the minor's `collecting` window has closed; the
    // major path's own drain makes this a no-op there.
    defer self.roots.runWeakCallbacks(self);
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
    // trace -- but only here. An explicit `collectFull` means
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
        pollScansConservatively(self, mode) and self.gc.shouldTryMinorBeforeMajor()
    else
        mode.acceptsMinor() and self.gc.shouldTryMinor();
    if (offer_minor and !self.gc.hot.collecting) {
        self.gc.hot.collecting = true;
        defer self.gc.hot.collecting = false;
        native_allocation.samplePeakAtCollection(self);
        const started = self.diagnosticNanos();
        if (@import("gc_trace_stw.zig").collectMinor(self, mode.rootScan()) catch null) |freed| {
            const ended = self.diagnosticNanos();
            const result: gc.CollectionResult = .{
                .freed_objects = freed,
                .duration_ns = if (ended > started) ended - started else 0,
            };
            self.gc.recordMinor(result);
            // Deliberately NOT `resetGrowthThreshold()`. That sets the
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
    if (self.gc.isBusy()) return .{};
    if (!self.gc.scheduler.shouldRunMajorAt(mode, over_threshold)) return .{};
    const reason = if (self.gc.scheduler.clearMajorRequest()) |request|
        request.reason
    else if (over_threshold)
        gc.RequestReason.allocation_threshold
    else
        gc.RequestReason.manual;
    return collectMajor(self, reason, mode.rootScan());
}

/// Stop-the-world full collection for an engine-internal trigger: the
/// caller's native frames are live, so the scan is `.engine_active`.
pub fn collectFull(self: *JSRuntime) gc.CollectionError!gc.CollectionResult {
    return collectMajor(self, .manual, .engine_active);
}

/// Precise full collection at Runtime teardown. Errors leave the remaining
/// graph to `gc.deinit`.
pub fn collectForTeardown(self: *JSRuntime) usize {
    const result = collectMajor(self, .manual, .declared_only) catch return 0;
    return result.freed_objects;
}

/// Host-requested full collection. `roots` names one more frame of host
/// values for this collection; it is linked like any `ValueRootFrame`.
pub fn forceGC(self: *JSRuntime, roots: ?*const ValueRootFrame) gc.CollectionError!gc.CollectionResult {
    self.assertOwnerThread();
    var extra: ValueRootFrame = if (roots) |frame| .{
        .slices = frame.slices,
        .values = frame.values,
        .objects = frame.objects,
        .headers = frame.headers,
        .atoms = frame.atoms,
    } else .{};
    if (roots != null) extra.activate(self);
    defer if (roots != null) extra.deactivate(self);
    self.gc.requestGC(.manual, .urgent);
    return pollGC(self, .urgent);
}

/// Test builds: a full collection under an explicit root-scan class.
pub fn collectWithScanForTest(self: *JSRuntime, scan: gc.RootScan) gc.CollectionError!gc.CollectionResult {
    if (!builtin.is_test) @compileError("test-only collection helper");
    return collectMajor(self, .manual, scan);
}

fn collectMajor(self: *JSRuntime, reason: gc.RequestReason, scan: gc.RootScan) gc.CollectionError!gc.CollectionResult {
    self.assertOwnerThread();
    self.assertGCAllowed();
    if (self.roots.isTracing()) @panic("collection reentry during tracing");
    // Registered first so it runs last, after `collecting` is cleared.
    defer self.roots.runWeakCallbacks(self);
    // A collection or collector phase already on the stack (a destructor
    // that allocates, for one) leaves the request pending rather than
    // nesting a second collection or touching its morgue and cycle.
    if (self.gc.isBusy()) return .{};
    if (builtin.mode == .Debug) self.gc.verifyIntrusiveList() catch unreachable;
    if (builtin.mode == .Debug) self.gc.verifyHeapAccounting(self) catch unreachable;
    defer if (builtin.mode == .Debug) {
        self.gc.verifyIntrusiveList() catch unreachable;
        self.gc.verifyHeapAccounting(self) catch unreachable;
    };
    self.gc.hot.collecting = true;
    defer self.gc.hot.collecting = false;

    // The cycle's high-water is the account right now, at trigger time.
    native_allocation.samplePeakAtCollection(self);
    const start_ns = self.diagnosticNanos();

    self.gc.scheduler.beginMajorCycle(reason);
    const freed = @import("gc_trace_stw.zig").collectCycles(self, scan) catch |err| {
        const mapped: gc.CollectionError = switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.PayloadMarkFailed => error.PayloadMarkFailed,
        };
        self.gc.failMajor(mapped);
        return mapped;
    };
    self.gc.scheduler.setMajorPhase(.sweep);

    const elapsed = self.diagnosticElapsedSince(start_ns);
    // Charge the census to whoever asked for it, not to the pause. The
    // walks run inside this region and are enabled by the same
    // `--gc-stats` that prints the distribution, so leaving them in makes
    // the only pause instrument inflate its own subject by ~40%.
    const census = self.gc.last_census_ns;
    const result = gc.CollectionResult{
        .freed_objects = freed,
        .duration_ns = elapsed -| census,
    };
    self.gc.completeMajor(result);
    return result;
}

/// Does a collection started at this poll decide liveness with the
/// conservative pass over the mutator's native frames?
///
/// A collection destroys synchronously, so running one from an arbitrary
/// allocation boundary is only sound while the scan covers the Zig locals the interrupted caller is holding -- the
/// shape `Object.create` acquires before its own boundary, for one. That
/// is exactly the promise `gc.PollMode.rootScan` makes for the engine
/// triggers, and exactly what `test_root_scan_override` withdraws: pacing
/// tests declare their frame quiescent so reclamation is deterministic,
/// which an allocation boundary in the middle of a constructor is not.
/// Those polls run a major without a preceding minor.
fn pollScansConservatively(self: *const JSRuntime, mode: gc.PollMode) bool {
    const scan = if (comptime builtin.is_test)
        self.test_root_scan_override orelse mode.rootScan()
    else
        mode.rootScan();
    return scan == .engine_active;
}

inline fn prospectiveAllocationTotal(self: *const JSRuntime, size: usize) usize {
    return self.gc.heap_budget.bytes +| size;
}

/// Queue an allocation-threshold request and return the exact prospective
/// total used for that decision. Object allocation immediately consumes
/// the same total to retire a stale threshold request; returning it keeps
/// `gc.requestGC`'s writes from forcing a second allocated-bytes load and
/// overflow-checked add on every object construction.
inline fn requestGCForAllocationTotal(self: *JSRuntime, size: usize) usize {
    if (comptime builtin.is_test) {
        if (self.gc.heap_budget.runProbe(size)) return prospectiveAllocationTotal(self, size);
    }
    // Destructors may allocate, but starting a nested collection from
    // inside a running one is not allowed.
    if (self.gc.isBusy()) return prospectiveAllocationTotal(self, size);
    if (comptime native_allocation.force_gc_on_allocation_enabled) {
        if (self.gc.heap_budget.suspend_alloc_notify) return prospectiveAllocationTotal(self, size);
        // A no-GC scope's native allocations (atom interning, for one)
        // never collect in a normal build; the synthetic collection
        // must not start inside one either.
        if (comptime gc_scope.checks_enabled) {
            if (self.active_no_gc_scope != null) return prospectiveAllocationTotal(self, size);
        }
        // The force-GC build option is diagnostic instrumentation, not a
        // scheduling-policy change. Preserve an explicitly configured
        // threshold across the synthetic pre-allocation collection.
        const saved_threshold = self.gc.heap_budget.gc_threshold;
        defer self.gc.heap_budget.gc_threshold = saved_threshold;
        _ = forceGC(self, null) catch {};
        return prospectiveAllocationTotal(self, size);
    }
    // The growth bar is the heap budget, not the mixed native account.
    const total = prospectiveAllocationTotal(self, size);
    if (total > self.gc.heap_budget.gc_threshold) {
        self.gc.requestGC(.allocation_threshold, .soon);
    }
    return total;
}

pub inline fn requestGCForAllocation(self: *JSRuntime, size: usize) void {
    _ = requestGCForAllocationTotal(self, size);
}

/// QuickJS `JS_NewObjectFromShape` runs its threshold GC before entering
/// the allocator. Object construction uses this stronger boundary instead
/// of merely leaving a pending request for post-registration service: a
/// memory-limit check must be allowed to reuse space from reclaimable
/// cycles before rejecting the replacement object.
pub fn collectBeforeObjectAllocation(self: *JSRuntime, size: usize) align(64) void {
    const prospective = requestGCForAllocationTotal(self, size);
    // Scratch allocation can cross the threshold and queue a request, then
    // fall back below it before the next qjs-style object boundary. The
    // threshold condition is level-triggered: discard only that ordinary
    // stale request. Registry request coalescing preserves manual/external/
    // pressure reasons so they cannot be cancelled here.
    if (prospective <= self.gc.heap_budget.gc_threshold) {
        _ = self.gc.scheduler.clearStaleAllocationThresholdRequest();
    }
    // A pending major is collected here, in full, before the allocation
    // lands. A registry that is already collecting, or that has nothing
    // pending, returns and leaves the request latched. Safepoint and
    // callback polls call `pollGC` themselves.
    if (self.gc.isBusy()) return;
    if (!self.gc.hasPendingMajorRequest()) return;
    return pollGCBeforeObjectAllocation(self);
}

/// Cold tail that owns `pollGC`'s error-union return area. The common
/// below-threshold allocation path can then remain a leaf with no saved
/// registers or stack frame.
noinline fn pollGCBeforeObjectAllocation(self: *JSRuntime) void {
    _ = pollGC(self, .normal) catch {};
}

pub const HeapLimitRetry = struct {
    rt: *JSRuntime,

    /// The mutator's native frames are live here, so the scan stays
    /// `.engine_active`. A collection already running is the same exit as
    /// `Budget.retrying`.
    pub fn collect(self: HeapLimitRetry) void {
        if (self.rt.gc.heap_budget.retry_override) |override| return override.collect(override.context);
        if (self.rt.gc.isBusy()) return;
        _ = collectFull(self.rt) catch return;
    }
};

/// Admit `bytes` against the JS heap limit, collecting at most once.
pub fn admitHeapCharge(self: *JSRuntime, bytes: usize) error{OutOfMemory}!void {
    return self.gc.heap_budget.admit(bytes, HeapLimitRetry{ .rt = self });
}

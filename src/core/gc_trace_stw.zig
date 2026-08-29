//! Stop-the-world reclaiming tracer (tracing-gc-design.md §13 Stage 3).
//!
//! Mark/sweep over the compatibility heap: current registry and layouts, no
//! new header, no block heap, no generations, no concurrent marker. Strong
//! edges walk `traceChildEdges*` (the same authority as the shadow observer).
//! WeakMap/WeakSet values are NOT marked during the strong walk;
//! `visitWeakCollectionEntry` stays a no-op. A separate ephemeron fixed
//! point then marks a value only when both its table and key are live.
//!
//! Compiled only when `-Dzjs_experimental_gc=trace_stw`. Default `rc` never imports this
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

/// Edge enumeration for one object, generic over the visitor so the
/// single-threaded `Collector` and the parallel tracer share one authority.
/// The visitor must provide visitValue/visitObject/visitShape/visitRealm/
/// visitModule/visitWeakCollectionEntry/visitFinalizationCell.
pub fn traceHeaderEdges(rt: *JSRuntime, visitor: anytype, header: *gc.Header) CollectError!void {
    // The block-cell allocator hook serves `Object` and no other GC kind.
    // Its 0x1F route marker is already in the metadata line this trace must
    // read, so the dominant path can avoid loading and dispatching `kind`.
    // `Registry.verifyRepresentationInvariants` checks the physical carrier
    // and object-kind construction invariant; the debug assertion names it
    // sooner.
    if (gc.Registry.isBlockCellHeader(header)) {
        std.debug.assert(header.metaConst().flags.kind == .object);
    } else switch (header.meta().flags.kind) {
        // Fall through to the one shared object body below. Keeping a single
        // hot entry matters: spelling the fast path as an early object return
        // made LLVM emit separate block/non-block object-entry sequences.
        .object => {},
        .function_bytecode => {
            const fb: *FunctionBytecode = @alignCast(@fieldParentPtr("header", header));
            visitor.visitRealm(&fb.realm.ptr);
            for (fb.cpoolSlice()) |*stored| visitor.visitValue(stored);
            return;
        },
        .var_ref => {
            const ref: *var_ref_mod.VarRef = @alignCast(@fieldParentPtr("header", header));
            visitor.visitValue(&ref.value);
            return;
        },
        .shape => {
            const shape_ref: *shape.Shape = @alignCast(@fieldParentPtr("header", header));
            try shape_ref.traceChildEdgesFallible(rt, visitor);
            return;
        },
        .realm_context => {
            const ctx: *context_mod.JSContext = @alignCast(@fieldParentPtr("header", header));
            ctx.traceChildEdgesNoFail(visitor);
            return;
        },
        .module => {
            const record: *module_mod.ModuleRecord = @alignCast(@fieldParentPtr("header", header));
            try record.traceChildEdgesFallible(rt, visitor);
            return;
        },
        .string, .big_int => return,
    }

    const obj: *Object = @alignCast(@fieldParentPtr("header", header));
    try obj.traceChildEdgesFallible(rt, visitor);
}

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

/// Static storage footprint of the final marked set.  This is intentionally a
/// `--gc-stats` census rather than a counter in the marking hot path: the
/// latter would perturb every edge visit and would still confuse successful
/// mark claims with the final live population.
///
/// A component touch means one distinct allocation reached while expanding a
/// marked header. Shared shapes therefore contribute once per object that
/// reaches them. `allocated_bytes` records the allocation's full capacity;
/// `touched_cache_lines` records the contiguous live span the trace walks
/// (the base carrier conservatively uses its full span). These are structural
/// cache-line opportunities, not hardware refill counts.
pub const MarkStorageComponent = enum(u8) {
    base,
    shape,
    property_slots,
    dense_elements,
    trace_payload,
    payload_backing,
};

pub const mark_storage_component_count: usize = @typeInfo(MarkStorageComponent).@"enum".fields.len;

pub const MarkTraceClass = enum(u8) {
    ordinary_object,
    fast_array,
    bytecode_function,
    exotic_object,
    non_object,
};

pub const mark_trace_class_count: usize = @typeInfo(MarkTraceClass).@"enum".fields.len;

pub const MarkStorageAggregate = struct {
    allocation_touches: usize = 0,
    allocated_bytes: usize = 0,
    touched_cache_lines: usize = 0,
};

pub const MarkFootprint = struct {
    pub const cache_line_bytes: usize = 64;
    pub const inline_limits = [_]usize{ 1, 2, 4 };

    major_censuses: usize = 0,
    marked_headers: usize = 0,
    block_headers: usize = 0,
    refcount_removed_headers: usize = 0,
    by_kind: [gc.gc_kind_count]usize = @splat(0),
    by_trace_class: [mark_trace_class_count]usize = @splat(0),
    storage: [mark_storage_component_count]MarkStorageAggregate = @splat(.{}),
    storage_by_trace_class: [mark_trace_class_count]MarkStorageAggregate = @splat(.{}),
    // Eligibility is a terminal-Shape upper bound. The byte/line fields below
    // are deliberately TRUE external storage only; direct tail objects remain
    // eligible but are split into `inline_direct_objects`, while a tail owner
    // that later grew a separate buffer is called out independently. Keeping
    // these populations separate prevents a successful direct allocation from
    // being mislabeled as an unrealized external opportunity.
    inline_eligible_objects: [inline_limits.len]usize = @splat(0),
    inline_property_bytes: [inline_limits.len]usize = @splat(0),
    inline_property_cache_lines: [inline_limits.len]usize = @splat(0),
    inline_direct_objects: [inline_limits.len]usize = @splat(0),
    inline_tail_grown_external_objects: [inline_limits.len]usize = @splat(0),
    inline_ordinary_eligible_objects: [inline_limits.len]usize = @splat(0),
    inline_ordinary_property_bytes: [inline_limits.len]usize = @splat(0),
    inline_ordinary_property_cache_lines: [inline_limits.len]usize = @splat(0),
    inline_ordinary_direct_objects: [inline_limits.len]usize = @splat(0),
    inline_ordinary_tail_grown_external_objects: [inline_limits.len]usize = @splat(0),
    active_trace_class: MarkTraceClass = .non_object,

    fn cacheLines(address: usize, bytes: usize) usize {
        if (bytes == 0) return 0;
        const last = address +| (bytes - 1);
        return last / cache_line_bytes - address / cache_line_bytes + 1;
    }

    pub fn noteMarkedHeader(self: *MarkFootprint, header: *gc.Header) void {
        const kind = header.metaConst().flags.kind;
        self.marked_headers +|= 1;
        self.by_kind[@intFromEnum(kind)] +|= 1;
        if (gc.Registry.isBlockCellHeader(header)) self.block_headers +|= 1;
        if (gc.refCountRemoved(kind)) self.refcount_removed_headers +|= 1;
    }

    pub fn beginTraceClass(self: *MarkFootprint, class: MarkTraceClass) void {
        self.by_trace_class[@intFromEnum(class)] +|= 1;
        self.active_trace_class = class;
    }

    pub fn noteAllocation(
        self: *MarkFootprint,
        component: MarkStorageComponent,
        allocation_bytes: usize,
        touched_address: usize,
        touched_bytes: usize,
    ) void {
        if (allocation_bytes == 0 or touched_bytes == 0) return;
        const aggregate = &self.storage[@intFromEnum(component)];
        aggregate.allocation_touches +|= 1;
        aggregate.allocated_bytes +|= allocation_bytes;
        aggregate.touched_cache_lines +|= cacheLines(touched_address, touched_bytes);
        const class_aggregate = &self.storage_by_trace_class[@intFromEnum(self.active_trace_class)];
        class_aggregate.allocation_touches +|= 1;
        class_aggregate.allocated_bytes +|= allocation_bytes;
        class_aggregate.touched_cache_lines +|= cacheLines(touched_address, touched_bytes);
    }

    pub fn noteInlinePropertyCandidate(
        self: *MarkFootprint,
        live_properties: usize,
        allocation_bytes: usize,
        allocation_address: usize,
        touched_bytes: usize,
        has_trailing_allocation: bool,
        storage_is_inline: bool,
    ) void {
        if (live_properties == 0 or allocation_bytes == 0 or touched_bytes == 0) return;
        std.debug.assert(!storage_is_inline or has_trailing_allocation);
        for (inline_limits, 0..) |limit, index| {
            if (live_properties > limit) continue;
            self.inline_eligible_objects[index] +|= 1;
            if (storage_is_inline) {
                self.inline_direct_objects[index] +|= 1;
            } else {
                self.inline_property_bytes[index] +|= allocation_bytes;
                self.inline_property_cache_lines[index] +|= cacheLines(allocation_address, touched_bytes);
                if (has_trailing_allocation) self.inline_tail_grown_external_objects[index] +|= 1;
            }
            if (self.active_trace_class == .ordinary_object) {
                self.inline_ordinary_eligible_objects[index] +|= 1;
                if (storage_is_inline) {
                    self.inline_ordinary_direct_objects[index] +|= 1;
                } else {
                    self.inline_ordinary_property_bytes[index] +|= allocation_bytes;
                    self.inline_ordinary_property_cache_lines[index] +|= cacheLines(allocation_address, touched_bytes);
                    if (has_trailing_allocation) self.inline_ordinary_tail_grown_external_objects[index] +|= 1;
                }
            }
        }
    }
};

test "mark footprint separates direct candidates from true external storage" {
    var footprint: MarkFootprint = .{};
    footprint.beginTraceClass(.ordinary_object);
    footprint.noteInlinePropertyCandidate(2, 32, 0x1000, 32, true, true);

    const two_slot_index = 1;
    try std.testing.expectEqual(@as(usize, 1), footprint.inline_ordinary_eligible_objects[two_slot_index]);
    try std.testing.expectEqual(@as(usize, 1), footprint.inline_ordinary_direct_objects[two_slot_index]);
    try std.testing.expectEqual(@as(usize, 0), footprint.inline_ordinary_property_bytes[two_slot_index]);
    try std.testing.expectEqual(@as(usize, 0), footprint.inline_ordinary_property_cache_lines[two_slot_index]);

    footprint.noteInlinePropertyCandidate(2, 64, 0x2000, 32, true, false);
    footprint.noteInlinePropertyCandidate(2, 32, 0x3000, 32, false, false);

    try std.testing.expectEqual(@as(usize, 3), footprint.inline_ordinary_eligible_objects[two_slot_index]);
    try std.testing.expectEqual(@as(usize, 1), footprint.inline_ordinary_direct_objects[two_slot_index]);
    try std.testing.expectEqual(@as(usize, 1), footprint.inline_ordinary_tail_grown_external_objects[two_slot_index]);
    try std.testing.expectEqual(
        @as(usize, 1),
        footprint.inline_ordinary_eligible_objects[two_slot_index] -
            footprint.inline_ordinary_direct_objects[two_slot_index] -
            footprint.inline_ordinary_tail_grown_external_objects[two_slot_index],
    );
    try std.testing.expectEqual(@as(usize, 96), footprint.inline_ordinary_property_bytes[two_slot_index]);
    try std.testing.expectEqual(@as(usize, 2), footprint.inline_ordinary_property_cache_lines[two_slot_index]);
}

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
/// shortcuts turned off. A condemned object reached from the PRECISE roots is
/// a young-generation soundness violation: a missing write barrier, a lost
/// remembered-set entry, or a bad promotion. A conservative-only disagreement
/// is reported separately: the verifier and real minor have different native
/// frames, so stale pointer residue may exist in only one of the two scans.
///
/// Cost is a whole extra whole-heap trace plus a mark save/restore per minor,
/// which is why it is a diagnostic mode and not an assertion.
const VerifyReachability = enum(u8) {
    precise,
    conservative_only,
};

const FullReachable = struct {
    entries: std.AutoHashMapUnmanaged(usize, VerifyReachability) = .empty,
    allocator: std.mem.Allocator,

    fn deinit(self: *FullReachable) void {
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }
};

/// Mark exactly what the roots reach, with no sticky-old shortcut and no
/// remembered set, and hand back the set. Leaves every mark bit as it found it:
/// the minor that runs next depends on the sticky marks this has to disturb.
fn computeFullReachable(rt: *JSRuntime, scan: runtime_mod.GCRootScan) !FullReachable {
    const allocator = rt.memory.persistent_allocator;
    var reachable: FullReachable = .{ .allocator = allocator };
    errdefer reachable.deinit();

    // A sticky oracle runs inside final remark while the marking flag is
    // still published. Its fresh root walk must not black-publish into the
    // production queue it is auditing. The mutator is stopped here; suppress
    // the barrier mode for the diagnostic and restore it before returning.
    const marking_was_active = rt.gc.concurrent.markingActive();
    if (marking_was_active) rt.gc.concurrent.major_marking_active.store(false, .monotonic);
    defer if (marking_was_active) rt.gc.concurrent.major_marking_active.store(true, .monotonic);

    var saved: std.ArrayList(*gc.Header) = .empty;
    defer saved.deinit(allocator);
    {
        var it = rt.gc.objectIterator();
        while (it.next()) |header| {
            if (rt.gc.headerMarked(header)) try saved.append(allocator, header);
        }
    }

    var probe = try Collector.init(rt, null, scan);
    defer probe.deinit();
    probe.clearMarks();
    try probe.seedRoots();
    try probe.drain();
    try probe.ephemeronFixedPoint();
    const precise_young = probe.countMarkedYoung();
    {
        var it = rt.gc.objectIterator();
        while (it.next()) |header| {
            if (rt.gc.headerMarked(header)) {
                try reachable.entries.put(allocator, @intFromPtr(header), .precise);
            }
        }
    }
    if (probe.conservative_on) {
        try probe.seedConservativeRoots();
        try probe.drain();
    }
    // `processWeak` is deliberately NOT run: it clears weak references, and a
    // diagnostic pass must not have side effects the real collection then sees.
    try probe.ephemeronFixedPoint();
    const all_young = probe.countMarkedYoung();
    rt.gc.generation.stats.conservative_only_young +|= all_young -| precise_young;

    {
        var it = rt.gc.objectIterator();
        while (it.next()) |header| {
            if (rt.gc.headerMarked(header)) {
                const result = try reachable.entries.getOrPut(allocator, @intFromPtr(header));
                if (!result.found_existing) result.value_ptr.* = .conservative_only;
            }
        }
    }

    probe.clearMarks();
    for (saved.items) |header| rt.gc.setHeaderMarked(header);
    return reachable;
}

/// Reject the exact set an incremental finish is about to condemn against a
/// trace that started from freshly cleared marks.
///
/// Fail-closed on PRECISE disagreements only, and that asymmetry is the whole
/// design. The direction being defended is "sticky may keep too much, never too
/// little": a condemned object the fresh precise roots reach is a kill, full
/// stop, so the caller aborts before weak state or object storage is mutated.
/// A conservative-only disagreement is a different animal. This oracle runs on
/// a deeper native frame than the cycle it audits, so pointer residue can exist
/// in one scan and not the other -- `computeFullReachable`'s own contract has
/// said so since the minor verifier. Counting it as a kill would abort healthy
/// cycles; ignoring it silently would hide a real signal. So it is counted,
/// separately, and read against the full-scope control (`ZJS_GC_VERIFY_MAJOR_ALL`)
/// where the same number must appear even though a full scope cannot under-mark.
fn verifyStickyCondemnation(
    rt: *JSRuntime,
    scope: gc.IncrementalMajorScope,
    reachable: *const FullReachable,
) CollectError!void {
    var precise_violations: usize = 0;
    var conservative_violations: usize = 0;
    var reported: usize = 0;
    var objects = rt.gc.objectIterator();
    while (objects.next()) |header| {
        if (rt.gc.headerMarked(header) or header.metaConst().flags.is_pinned) continue;
        const source = reachable.entries.get(@intFromPtr(header)) orelse continue;
        switch (source) {
            .precise => precise_violations += 1,
            .conservative_only => conservative_violations += 1,
        }
        if (reported < 8) {
            reported += 1;
            std.debug.print("VERIFY-STICKY condemned-but-reachable scope={s} source={s} kind={s}\n", .{
                @tagName(scope),
                @tagName(source),
                @tagName(header.metaConst().flags.kind),
            });
        }
    }
    rt.gc.noteStickyMajorOracle(scope, precise_violations, conservative_violations);
    if (precise_violations + conservative_violations == 0) return;
    std.debug.print("VERIFY-STICKY scope={s}: {d} precise, {d} conservative-only condemned-but-reachable\n", .{
        @tagName(scope),
        precise_violations,
        conservative_violations,
    });
    if (precise_violations == 0) return;
    return error.PayloadMarkFailed;
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

/// Run `recordFinalMarkFootprint` -- the marked-set/storage census, a whole
/// heap walk with per-object property-storage accounting.
///
/// This is deliberately NOT `detailed_reports`. Deducting a census from the
/// number a panel prints (`last_census_ns` below) makes the printed number
/// honest; it does not give the mutator its time back. The marked-set census
/// is by far the most expensive of the walks -- on splay it is 525k headers
/// per major, and it lands inside the final-remark stop -- so bundling it into
/// `--gc-stats` moved the thing the panel exists to measure: with the flag on,
/// splay scored -9.8% and SplayLatency -23.7% against the SAME binary with it
/// off. A latency benchmark measures the mutator's wall clock, not our
/// bookkeeping, and no amount of subtraction reaches it.
///
/// So the census is its own opt-in (`--gc-mark-footprint`). `--gc-stats` keeps
/// the cheap counters and the pause distribution, and is once again usable as
/// a ruler for the pause work. The subtraction below is kept as well, for the
/// runs that do ask for the census: the two mechanisms answer different
/// questions and neither replaces the other.
pub var mark_footprint_census: bool = false;

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

/// The final-remark span BEFORE `last_census_ns` is deducted from it.
///
/// Written only under `detailed_reports`, and read only by the test that pins
/// the deduction: without a raw witness "the phase total is census-net" is
/// asserted about a quantity nothing else records, and the deduction can be
/// dropped without a single test changing colour.
pub var last_finish_remark_raw_ns: u64 = 0;

/// Either census family is on, so the walks have to be timed to be deducted.
/// `mark_footprint_census` is separately switchable, and timing it only when
/// `detailed_reports` also happened to be set would leave the deduction silently
/// zero for exactly the walk that dominates the cost.
inline fn censusTimed() bool {
    return detailed_reports or mark_footprint_census;
}

inline fn censusStart() u64 {
    return if (censusTimed()) profile.nowNanos() else 0;
}

inline fn censusEnd(started: u64) void {
    if (!censusTimed()) return;
    const now = profile.nowNanos();
    if (now > started) last_census_ns +|= now - started;
}

fn verifyCollectorInvariants(
    rt: *JSRuntime,
    verify_scan_cache: bool,
    require_retirement_commit: bool,
) void {
    const stale = rt.gc.address_registry.auditArenas();
    const missing = auditLiveObjectsResolve(rt);
    if (stale != 0 or missing != 0) {
        std.debug.print(
            "gc: ARENA AUDIT: {d} free blocks read live, {d} live objects unresolvable\n",
            .{ stale, missing },
        );
        @panic("arena invariant violated");
    }
    rt.gc.address_registry.verifyIndex(verify_scan_cache) catch |err| {
        std.debug.print("gc: ADDRESS INDEX AUDIT: {s}\n", .{@errorName(err)});
        @panic("address index invariant violated");
    };
    // Validate construction pins before BlockHeap consults them as the
    // sole exception to the publication rule. A corrupt exception authority
    // must never turn arbitrary unpublished cells into accepted state.
    rt.gc.verifyConstructionRoots() catch |err| {
        std.debug.print("gc: CONSTRUCTION ROOT AUDIT: {s}\n", .{@errorName(err)});
        @panic("construction root invariant violated");
    };
    rt.gc.verifyRepresentationInvariants() catch |err| {
        std.debug.print("gc: REPRESENTATION AUDIT: {s}\n", .{@errorName(err)});
        @panic("GC representation invariant violated");
    };
    auditDeferredPayloadRootsBeforeBlockPublication(rt);
    rt.gc.verifyObjectPropertyStorageLayouts(rt) catch |err| {
        std.debug.print("gc: PROPERTY STORAGE AUDIT: {s}\n", .{@errorName(err)});
        @panic("object property storage invariant violated");
    };
    rt.gc.verifyIntrusiveList() catch |err| {
        std.debug.print("gc: INTRUSIVE LIST AUDIT: {s}\n", .{@errorName(err)});
        @panic("intrusive list invariant violated");
    };
    if (comptime gc.sweep_model_enabled) {
        rt.gc.sweep_model.verify() catch |err| {
            std.debug.print("gc: SWEEP MODEL AUDIT: {s}\n", .{@errorName(err)});
            @panic("sweep model invariant violated");
        };
    }
    if (comptime gc.block_heap_enabled) {
        rt.gc.block_heap.verify() catch |err| {
            std.debug.print("gc: BLOCK HEAP AUDIT: {s}\n", .{@errorName(err)});
            @panic("block heap invariant violated");
        };
        rt.gc.block_heap.verifyPublishedCellsAllowing(
            gc.representation.block_cell_size_class,
            @as(u3, @intCast(@intFromEnum(gc.GcKind.object))),
            .{
                .context = @ptrCast(&rt.gc),
                .classify = gc.Registry.blockCellPublicationAllowance,
            },
        ) catch |err| {
            std.debug.print("gc: BLOCK CELL PUBLICATION AUDIT: {s}\n", .{@errorName(err)});
            @panic("block cell publication invariant violated");
        };
    }
    rt.gc.verifyGenerationInvariants() catch |err| {
        std.debug.print("gc: GENERATION AUDIT: {s}\n", .{@errorName(err)});
        @panic("generation invariant violated");
    };
    if (require_retirement_commit) {
        rt.gc.verifyMajorRetirementCommit() catch |err| {
            std.debug.print("gc: RETIREMENT AUDIT: {s}\n", .{@errorName(err)});
            @panic("young retirement incomplete");
        };
    }
    // Non-block corpses leave the object iterator while sliced destruction is
    // pending but remain in the byte account until their destructor runs.
    if (!rt.gc.doomed_pending) {
        rt.gc.verifyHeapAccounting(rt) catch |err| {
            std.debug.print("gc: HEAP ACCOUNTING AUDIT: {s}\n", .{@errorName(err)});
            @panic("heap accounting invariant violated");
        };
    }
}

/// Record one major's final marked set after root/edge/ephemeron closure and
/// before weak processing or condemnation mutates the heap. This is the only
/// denominator suitable for cross-workload "per marked object" pricing:
/// `gc_parallel_mark.Stats.owner_marked/worker_marked` count successful claims
/// only on slices that actually entered the parallel pool, so a CPU-0 run can
/// legitimately report both as zero while marking a large graph.
/// Gated on `mark_footprint_census`, not on `detailed_reports`: this walk runs
/// inside the final-remark stop and is the one census big enough to move the
/// benchmark scores the panel is used to read (see `mark_footprint_census`).
fn recordFinalMarkFootprint(rt: *JSRuntime) void {
    if (!mark_footprint_census) return;
    const started = censusStart();
    defer censusEnd(started);

    const footprint = &rt.gc_mark_pool.footprint;
    footprint.major_censuses +|= 1;
    var marked = rt.gc.objectIterator();
    while (marked.next()) |header| {
        if (!rt.gc.headerMarked(header)) continue;
        footprint.noteMarkedHeader(header);

        if (header.metaConst().flags.kind == .object) {
            const object: *const Object = @alignCast(@fieldParentPtr("header", header));
            object.recordTraceStorageFootprint(rt, footprint);
        } else {
            footprint.beginTraceClass(.non_object);
            const allocation_address = @intFromPtr(header) - gc.metadata_prefix_size;
            const allocation_bytes = gc.metadata_prefix_size + gc.Registry.heapByteSizeFromHeader(rt, header);
            footprint.noteAllocation(
                .base,
                allocation_bytes,
                allocation_address,
                allocation_bytes,
            );
        }
    }
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
    // The synchronous major uses the same trace-coupled retirement contract as
    // the incremental major. This is especially load-bearing after aborting an
    // incremental cycle: its begin step has already cleared the young-block
    // chain, so only tracing can retire the marked survivors. Without opening
    // the transaction here `retireTracedYoung` is a no-op and `clearYoungState`
    // has no chain left from which to find them.
    rt.gc.generation.beginMajorRetirement();
    errdefer rt.gc.generation.abandonMajorRetirement();
    const swept = try collector.run();
    clearYoungState(rt);
    // `Collector.run` returns 0 without sweeping when the arena set is not
    // whole. That is an exit from the transaction, not a completion of it:
    // committing there would reopen minors over a population the trace had
    // already half-promoted.
    if (collector.report.skipped_sweep_incomplete_arenas) {
        rt.gc.generation.abandonMajorRetirement();
        rt.gc.requestGC(.collection_failed, .soon);
    } else {
        rt.gc.generation.commitMajorRetirement();
    }
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
    if (gc.invariantChecksEnabled()) {
        verifyCollectorInvariants(
            rt,
            collector.conservative_on,
            !collector.report.skipped_sweep_incomplete_arenas,
        );
    }
    if (comptime gc.block_heap_enabled) {
        last_report.mark_epoch = rt.gc.block_heap.mark_epoch;
        last_report.committed_bytes = rt.gc.block_heap.stats.committed_bytes;
        last_report.block_live_bytes = rt.gc.block_heap.liveBytes();
        last_report.committed_live_milli = rt.gc.block_heap.committedLiveMilli();
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
    // Hard guard, not only the scheduler's. `shouldTryMinor` is the policy
    // gate, but a minor can also be reached directly, and running one with a
    // retirement transaction open means reading a young population the trace
    // has already half-promoted.
    if (!rt.gc.generation.minorsAllowed()) return null;
    const young_before = rt.gc.generation.stats.young_count;
    if (young_before == 0) return 0;

    // The minor is the consumer of the young-suffix anchor, so verify it here
    // rather than only at the major boundary: a stale `young_head` is
    // otherwise unobservable until `clearYoungMarks` dereferences freed
    // memory, one collection after the detach that stranded it.
    if (builtin.mode == .Debug) rt.gc.verifyIntrusiveList() catch unreachable;

    var collector = try Collector.init(rt, extra_roots, scan);
    defer collector.deinit();

    var full_reachable: ?FullReachable = null;
    defer if (full_reachable) |*reachable| reachable.deinit();
    if (gc.verify_minor) {
        full_reachable = computeFullReachable(rt, scan) catch |err| blk: {
            std.debug.print("VERIFY-MINOR setup failed: {s}\n", .{@errorName(err)});
            break :blk null;
        };
    }

    const phase_stats = detailed_reports;
    var phase_started = if (phase_stats) profile.nowNanos() else 0;
    collector.clearYoungMarks();
    if (phase_stats) {
        const ended = profile.nowNanos();
        rt.gc.generation.stats.minor_clear_ns_total +|= ended -| phase_started;
        phase_started = ended;
    }
    try collector.seedRoots();
    if (phase_stats) {
        const ended = profile.nowNanos();
        rt.gc.generation.stats.minor_roots_ns_total +|= ended -| phase_started;
        phase_started = ended;
    }
    if (collector.conservative_on) try collector.seedConservativeRoots();
    if (phase_stats) {
        const ended = profile.nowNanos();
        rt.gc.generation.stats.minor_conservative_ns_total +|= ended -| phase_started;
        phase_started = ended;
    }

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
    if (phase_stats) {
        const ended = profile.nowNanos();
        rt.gc.generation.stats.minor_remembered_ns_total +|= ended -| phase_started;
        phase_started = ended;
    }
    try collector.drain();
    try collector.ephemeronFixedPoint();
    if (phase_stats) {
        const ended = profile.nowNanos();
        rt.gc.generation.stats.minor_trace_ns_total +|= ended -| phase_started;
        phase_started = ended;
    }

    rt.gc.generation.stats.young_at_start_total += young_before;
    if (young_before > rt.gc.generation.stats.young_at_start_max) {
        rt.gc.generation.stats.young_at_start_max = young_before;
    }
    // Same requirement as the major: a sweep is only sound when every arena is
    // registered, because an unregistered one hides its objects from the
    // conservative scan that decides what is live.
    if (!rt.gc.arenaSetWhole()) {
        if (phase_stats) {
            rt.gc.generation.stats.minor_sweep_ns_total +|= profile.nowNanos() -| phase_started;
        }
        return 0;
    }
    const reclaimed = collector.sweepUnmarkedYoung(if (full_reachable) |*reachable| reachable else null);
    rt.gc.generation.noteMinorYield(young_before, reclaimed);
    if (phase_stats) {
        const ended = profile.nowNanos();
        rt.gc.generation.stats.minor_sweep_ns_total +|= ended -| phase_started;
        phase_started = ended;
    }

    // Promotion is the sticky rule made concrete: everything still young
    // after the sweep survived this collection, so it is old now. Clearing
    // the bit here is what makes a later write to it hit the remembered-set
    // path instead of being skipped as "the minor will see it anyway".
    var survivors = rt.gc.youngIterator();
    while (survivors.next()) |header| {
        header.meta().flags.young = false;
    }
    if (comptime gc.block_heap_enabled) _ = rt.gc.block_heap.clearYoungBlocks();
    rt.gc.resetYoungListSuffix();
    rt.gc.retireGenerationalYoungSet();
    rt.gc.generation.noteMinorPromotion(young_before -| reclaimed);
    if (phase_stats) {
        rt.gc.generation.stats.minor_promote_ns_total +|= profile.nowNanos() -| phase_started;
    }
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
    recordFinalMarkFootprint(rt);

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
        // was built from is stale (§8.2). This retires the authoritative map,
        // its object-local cache bits, and the suffix cursor. A survivor that
        // kept its young bit would be swept by the next minor on the strength
        // of a trace that never looked at its incoming edges.
        clearYoungState(rt);
        // The argument feeds the `promoted` counter and nothing else, and
        // `liveCount` is a whole-heap walk. After a major every survivor is
        // old, so with the counter unread there is nothing to count.
        const t = censusStart();
        rt.gc.generation.noteMinorPromotion(if (detailed_reports) rt.gc.liveCount() else 0);
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
    var cursor = rt.gc.young_head;
    while (cursor) |h| {
        if (h == &rt.gc.gc_obj_list.sentinel) break;
        const next = h.next;
        std.debug.assert(h.metaConst().flags.young);
        h.meta().flags.young = false;
        cursor = next;
    }
    // Block-population young bits: walk the young-block list, not the heap.
    // This also retires sweep-time allocations -- a block that received one
    // is on the list like any other.
    if (comptime gc.block_heap_enabled) {
        var young = rt.gc.youngIterator();
        young.cursor = null;
        while (young.next()) |h| h.meta().flags.young = false;
        _ = rt.gc.block_heap.clearYoungBlocks();
    }
    rt.gc.resetYoungListSuffix();
    rt.gc.retireGenerationalYoungSet();
}

/// Open an incremental major cycle (§8.6 initial mark, mutator stopped for
/// this call only).
///
/// A full scope clears marks. The experimental sticky scope preserves old
/// marks and force-traces the remembered owners before retiring that set.
/// Both scopes seed every precise and conservative root GREY and publish
/// `major_marking_active`; the frontier drains at subsequent polls.
pub fn beginIncrementalCycle(rt: *JSRuntime, extra_roots: ?*const runtime_mod.ValueRootFrame, scan: runtime_mod.GCRootScan) CollectError!void {
    std.debug.assert(!rt.gc.concurrent.markingActive());
    rt.gc.concurrent_mark_queue.ensureCapacity(gc.Registry.markQueueAllocator());
    rt.gc.concurrent_mark_queue.reset();
    rt.gc.mark_stack.ensure();
    rt.gc.mark_stack.len = 0;
    rt.gc_mark_pool.slice_in_cycle = 0;
    rt.gc_mark_pool.cycle_hot = false;

    var collector = try Collector.init(rt, extra_roots, scan);
    defer collector.deinit();
    collector.shade_to_queue = true;
    const scope = rt.gc.prepareIncrementalMajorScope();

    // Open the retirement transaction BEFORE anything can shade: the first
    // root seeded is already eligible to be retired by the trace.
    rt.gc.generation.beginMajorRetirement();
    // Seeding can fail (an allocation inside a root walk). Any exit from
    // here that does not reach `major_marking_active` leaves a transaction
    // open with part of the population possibly promoted, so it abandons.
    errdefer rt.gc.generation.abandonMajorRetirement();
    const t0 = profile.nowNanos();
    const remembered_clears_before = rt.gc.generation.stats.remembered_clears;
    switch (scope) {
        .full => collector.clearMarks(),
        .sticky => {
            // Copy before clearing: the set is the only owner of these
            // addresses, but tracing one owner may itself allocate. The world
            // is stopped, so the snapshot remains valid until it is consumed.
            var remembered = rt.gc.generation.rememberedIterator();
            while (remembered.next()) |addr| {
                const header: *gc.Header = @ptrFromInt(addr.*);
                try collector.work.append(collector.allocator(), header);
            }

            // Old owners already carry a sticky mark, so ordinary root
            // shading would skip their children. Expand them explicitly; the
            // young targets they expose enter the persistent frontier.
            //
            // `sticky_inject_skip` drops the first N owners on purpose. That
            // is exactly the shape of a lost write barrier, and it is what the
            // fresh-trace oracle downstream must refuse. It is zero unless the
            // operator sets `ZJS_GC_STICKY_INJECT_SKIP`.
            const expand_from = @min(gc.sticky_inject_skip, collector.work.items.len);
            for (collector.work.items[expand_from..]) |header| try collector.traceHeader(header);
            collector.work.clearRetainingCapacity();
        },
    }
    const t1 = profile.nowNanos();
    try collector.seedRoots();
    const t1b = profile.nowNanos();
    if (collector.conservative_on) try collector.seedConservativeRoots();
    const t2 = profile.nowNanos();
    rt.gc.concurrent.stats.phase_begin_clear_ns +|= t1 -| t0;
    rt.gc.concurrent.stats.phase_begin_precise_seed_ns +|= t1b -| t1;
    rt.gc.concurrent.stats.phase_begin_conservative_seed_ns +|= t2 -| t1b;

    // Non-block young objects keep their exact list suffix throughout the
    // open major. The mandatory finish condemnation pass retires every list
    // survivor while detaching every dead node, so begin need not walk them at
    // all. Block survivors still retire as their trace loads them. No minor
    // can run inside this window (`minorsAllowed`), so the remembered index and
    // scalar count can be reset once seeding completes.
    const t_retire = profile.nowNanos();
    const young_blocks = if (comptime gc.block_heap_enabled)
        rt.gc.block_heap.clearYoungBlocks()
    else
        0;
    rt.gc.retireGenerationalYoungSet();
    const retire_ns = profile.nowNanos() -| t_retire;
    rt.gc.concurrent.stats.phase_begin_retire_ns +|= retire_ns;
    rt.gc.concurrent.stats.phase_retired_young_blocks +|= young_blocks;
    rt.gc.concurrent.stats.phase_retired_remembered_sets +|=
        rt.gc.generation.stats.remembered_clears -| remembered_clears_before;

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
    const stack = &rt.gc.mark_stack;
    // A frontier worth sharing goes to the parallel pool (owner + helpers,
    // each a claim-dedup tracer lane); anything smaller stays on this exact
    // single-threaded path, as does every configuration whose affinity mask
    // yields zero workers.
    {
        const parallel = @import("gc_parallel_mark.zig");
        const pool = &rt.gc_mark_pool;
        defer pool.slice_in_cycle += 1;
        // First-slice admission uses the frontier; every later slice in the
        // same cycle qualifies unconditionally.
        //
        // Requiring the threshold on EVERY slice looks obviously right --
        // waking three threads costs tens of microseconds and a narrow
        // frontier is worth a few hundred nanoseconds of marking -- and it
        // cost splay 10% on four cores. The frontier is an instantaneous
        // reading of a depth-first traversal: it dips below any threshold
        // repeatedly in the middle of a cycle that still has millions of
        // objects to go, and each dip parks the helpers for the rest of that
        // slice. What a slice is worth is a property of the cycle, not of
        // the frontier at the instant the slice opens. (Measured 2026-08-27;
        // the suggestion was sound in principle and the threshold is simply
        // the wrong instrument for it.)
        if (pool.slice_in_cycle >= 1 or stack.len + queue.len() >= 512) {
            pool.ensureSpawned(rt);
            if (pool.available()) {
                const done = parallel.parallelMarkStep(rt, pool, budget_ns);
                rt.gc.concurrent.stats.increments += 1;
                return done;
            }
        }
    }
    const started = profile.nowNanos();
    var since_clock: usize = 0;
    while (stack.popPrefetch() orelse queue.popSingle()) |header| {
        // No validation needed: rc-managed kinds never enter the queue
        // (see `shade`), and everything that can is freeable only by the
        // collector itself, which does not run inside its own mutator
        // windows. The pop used to revalidate through the address
        // registry -- 4.3% of splay's runtime, paid per object against a
        // hazard only shapes had.
        try collector.traceHeader(header);
        if (collector.err) |err| return err;
        since_clock += 1;
        if (since_clock == 64) {
            since_clock = 0;
            if (profile.nowNanos() -| started >= budget_ns) break;
        }
    }
    rt.gc.concurrent.stats.increments += 1;
    return stack.len == 0 and queue.len() == 0;
}

/// Final remark and sweep (§8.6, mutator stopped). Re-seeds every root --
/// stack slots are not barriered, so the conservative rescan is what catches
/// white objects referenced only from native frames -- drains what that and
/// the barrier produced, then runs the ordinary weak/sweep tail.
pub fn finishIncrementalCycle(rt: *JSRuntime, extra_roots: ?*const runtime_mod.ValueRootFrame, scan: runtime_mod.GCRootScan) CollectError!usize {
    std.debug.assert(rt.gc.concurrent.markingActive());
    rt.gc.stats.collections += 1;

    var collector = try Collector.init(rt, extra_roots, scan);
    defer collector.deinit();

    // Own the accumulator for this finish, the way `collectCycles` owns it for
    // a synchronous major. Without the reset the deduction below would charge
    // this pause with whatever the previous collection's walks cost.
    last_census_ns = 0;
    const t_remark = profile.nowNanos();
    try collector.seedRoots();
    const t_remark_cons = profile.nowNanos();
    if (collector.conservative_on) try collector.seedConservativeRoots();
    rt.gc.concurrent.stats.phase_finish_conservative_seed_ns +|= profile.nowNanos() -| t_remark_cons;
    try collector.drain();
    _ = try collector.drainBarrierQueue();
    try collector.ephemeronFixedPoint();
    recordFinalMarkFootprint(rt);

    // The sticky marks are not their own correctness proof. Before they can
    // authorize condemnation, an opt-in oracle re-derives reachability from
    // a fresh mark epoch and compares the exact would-be-doomed set. Keep the
    // set collection-local: Runtime allocator lifetimes may not be mixed.
    var full_reachable: ?FullReachable = null;
    defer if (full_reachable) |*reachable| reachable.deinit();
    if (comptime gc.sticky_major_enabled) {
        const scope = rt.gc.incrementalMajorScope();
        // `verify_major_all` extends the audit to full-scope cycles. A full
        // scope re-derives everything from cleared marks and so cannot be the
        // thing under suspicion -- which is precisely why it is worth auditing:
        // it turns the sticky arm's violation count into a rate against a
        // control that is known-good.
        const audit = gc.verify_major_all or (scope == .sticky and gc.verify_sticky_major);
        if (audit) {
            full_reachable = try computeFullReachable(rt, scan);
            if (full_reachable) |*reachable| try verifyStickyCondemnation(rt, scope, reachable);
        }
    }

    // Marking is over before anything is freed (§8.6 step 12 before 13).
    rt.gc.concurrent.major_marking_active.store(false, .monotonic);

    const t_weak = profile.nowNanos();
    collector.processWeak();
    const t_sweep = profile.nowNanos();
    collector.beginSweepModelSweep();
    if (!rt.gc.arenaSetWhole()) {
        // Declining to sweep is safe for memory -- one round leaks -- but it
        // is an exit from the retirement transaction, and block cells the
        // trace already promoted make the young structures inconsistent.
        // Minors stay closed until a major commits.
        rt.gc.generation.abandonMajorRetirement();
        // Ask for the repair explicitly. Without it the state waits for
        // whatever schedules the next major, and minors stay closed for the
        // whole interval.
        rt.gc.requestGC(.collection_failed, .soon);
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
    // Condemnation in two strokes. Block cells: a bitmap snapshot --
    // alloc & ~mark captured into each block's doomed bitmap, word arithmetic
    // only, microseconds for the whole heap, and no corpse is touched until
    // its destruction slice. Pinned cells cannot appear in it: pinning is
    // rare and pinned objects are roots, so the trace marked them. The list:
    // the non-block kinds plus standalone objects, walked as before -- it is
    // small now.
    assertMorgueEmptyBeforeCondemnation(rt);
    var condemned: usize = 0;
    var doomed_bytes: usize = 0;
    if (comptime gc.block_heap_enabled) {
        const snap = rt.gc.block_heap.snapshotAllDoomed(rt.gc.block_heap.mark_epoch);
        condemned += snap.count;
        // Ledger parity: the account carries object sizes, not cell sizes.
        doomed_bytes +|= snap.bytes -| (snap.count * gc.metadata_prefix_size);
    }
    var previous_node: *gc.Header = &rt.gc.gc_obj_list.sentinel;
    var cursor_node = previous_node.next;
    while (cursor_node) |header| {
        if (header == &rt.gc.gc_obj_list.sentinel) break;
        const next_node = header.next;
        if (rt.gc.headerMarked(header)) {
            header.meta().flags.young = false;
            previous_node = header;
            cursor_node = next_node;
            continue;
        }
        if (header.metaConst().flags.is_pinned) {
            header.meta().flags.young = false;
            previous_node = header;
            cursor_node = next_node;
            continue;
        }
        doomed_bytes +|= gc.Registry.heapByteSizeFromHeader(rt, header);
        rt.gc.detachCycleCandidateAfter(previous_node, header);
        gc.listAddTailTraversalOwned(&rt.gc.doomed_by_kind[@intFromEnum(header.meta().flags.kind)], header);
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
        cursor_node = next_node;
    }
    // Every pre-existing list survivor was retired by tracing/condemnation.
    // From here on a non-null anchor belongs to a post-mark publication, so a
    // forward walk is the exact replacement for the old header.prev tail walk.
    rt.gc.resetYoungListSuffix();
    rt.gc.doomed_phase = 0;
    rt.gc.doomed_cursor = null;
    rt.gc.doomed_destroyed = 0;
    rt.gc.doomed_bytes = doomed_bytes;
    rt.gc.concurrent.stats.doomed_condemned_headers +|= condemned;
    rt.gc.doomed_pending = condemned != 0;
    if (comptime gc.block_heap_enabled) {
        if (rt.gc.block_heap.doomed_blocks != null) rt.gc.doomed_pending = true;
    }
    if (rt.gc.doomed_pending) rt.gc.beginDeferredFreeProducerSequence();
    if (!rt.gc.doomed_pending) rt.gc.concurrent.stats.cycles_completed += 1;
    auditDoomedExitInvariant(rt);

    const t_end = profile.nowNanos();
    // Every census walk this finish performed happened between `t_remark` and
    // `t_weak` -- that is where the marked set still exists to be counted --
    // so the remark segment is the only one that can carry census time, and
    // it must not: the panel that prints this row is the same flag that
    // switches the walks on. The containment assertion is what keeps that
    // "only" true; a census added after `t_weak` would inflate a segment the
    // deduction below never touches, silently.
    const raw_remark_ns = t_weak -| t_remark;
    const census_ns = last_census_ns;
    std.debug.assert(census_ns <= raw_remark_ns);
    if (detailed_reports) last_finish_remark_raw_ns = raw_remark_ns;
    rt.gc.concurrent.stats.phase_finish_remark_ns +|= raw_remark_ns -| census_ns;
    rt.gc.concurrent.stats.phase_finish_weak_ns +|= t_sweep -| t_weak;
    rt.gc.concurrent.stats.phase_finish_condemn_ns +|= t_end -| t_sweep;
    collector.endSweepModelSweep();

    // Commit the retirement transaction. Condemnation retired surviving
    // list carriers; `clearYoungState` catches allocations published during
    // sweep and any block cell published after its block left the young list,
    // so the whole young population is old once this returns.
    clearYoungState(rt);
    rt.gc.generation.commitMajorRetirement();
    rt.gc.generation.decayLowYieldStreak();
    last_report = collector.report;
    last_report.swept = condemned;
    last_report.census_ns = census_ns;
    if (gc.invariantChecksEnabled()) {
        verifyCollectorInvariants(rt, collector.conservative_on, true);
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
/// Runs under `.tracer_destroy` so every struct free parks on
/// `cycle_deferred_frees`; the drain happens ONCE, after the last slice, which
/// is what keeps a destructor in a later slice reading a sibling from an
/// earlier one as stripped-but-allocated memory instead of freed memory --
/// the same mid-pass guarantee the monolithic sweep had, stretched across
/// polls. The list is stable between slices: everything on it is unreachable,
/// weak-cleared, and invisible to collections (which are gated while the
/// morgue is open).
/// Corpses processed between budget checks.
///
/// The clock is not free: `platform_clock.monotonicNanos` goes through the
/// `std.Io.Clock` interface, so each read is at least a virtual call and a
/// timestamp read (vDSO on Linux, not necessarily a syscall), and at the old
/// cadence of 8 a single earley-boyer run took roughly 21 million of them.
///
/// This buys throughput; it does NOT buy a static pause bound, and the
/// budget check never did. A single destruction is unbounded from this
/// module's point of view: a class payload finalizer and an ArrayBuffer's
/// external deinit are host callbacks, and the property loop is O(own
/// properties). What the cadence changes is the number of ordinary small
/// objects that can pass between two checks -- 256 of those at ~50 ns is
/// about 13 us against a 1 ms budget. The pause distribution is the plan's
/// gate and is measured, not asserted.
const destroy_clock_cadence: usize = 256;

/// Destruction-slice decomposition. The slice costs far more than the
/// destructors it runs -- on raytrace the profile puts `destroyFromHeader`
/// at 1.75% while the slice's stopped time is 5.4% of the run -- so the
/// difference is the machinery around them, and naming it needs a probe
/// rather than a guess. Off unless `ZJS_GC_DESTROY_PROBE` is set: the
/// timestamp per corpse would otherwise BE the cost.
pub var destroy_probe: bool = false;
pub var destroy_probe_dtor_ns: u64 = 0;
pub var destroy_probe_drain_ns: u64 = 0;
pub var destroy_probe_corpses: u64 = 0;

fn morgueIsEmpty(rt: *const JSRuntime) bool {
    if (rt.gc.doomed_cursor != null) return false;
    if (rt.gc.cycle_deferred_frees.count != 0) return false;
    if (comptime gc.block_heap_enabled) {
        if (rt.gc.block_heap.doomed_blocks != null) return false;
    }
    for (&rt.gc.doomed_by_kind) |*bucket| {
        if (!gc.listEmpty(bucket)) return false;
    }
    return true;
}

/// Cross-lane publication contract for deferred plugin payload roots. Block
/// draining may publish a partial block before the global doomed transaction
/// closes, but no cell reachable from a live-wrapper, queued-job, or active-job
/// payload root may be among that block's released intervals. Call this
/// immediately before every such publication point; d/f's clustered drain and
/// hot-block publication paths share this seam.
pub fn auditDeferredPayloadRootsBeforeBlockPublication(rt: *JSRuntime) void {
    if (!gc.invariantChecksEnabled()) return;
    rt.verifyDeferredClassPayloadRootLiveness() catch |err| {
        std.debug.print("gc: DEFERRED PAYLOAD ROOT AUDIT: {s}\n", .{@errorName(err)});
        @panic("deferred payload root entered doomed or released storage");
    };
}

/// The sliced-destruction exit contract. The morgue gate is the only thing
/// preventing a fresh trace from observing resource-stripped or parked
/// objects, so a false gate must mean every representation of that state is
/// empty. Payload-root liveness is checked even while the transaction stays
/// open, because partial blocks may already have been published by then.
pub fn auditDoomedExitInvariant(rt: *const JSRuntime) void {
    if (!gc.invariantChecksEnabled()) return;
    auditDeferredPayloadRootsBeforeBlockPublication(@constCast(rt));
    if (rt.gc.doomed_pending) return;
    if (!morgueIsEmpty(rt)) @panic("gc: closed doomed state retains morgue entries");
}

/// A new condemnation may reuse every morgue field. Catch a caller that
/// starts one before the previous destruction transaction has really closed.
fn assertMorgueEmptyBeforeCondemnation(rt: *const JSRuntime) void {
    std.debug.assert(!rt.gc.doomed_pending);
    std.debug.assert(morgueIsEmpty(rt));
}

pub fn destroyDoomedSlice(rt: *JSRuntime, budget_ns: u64) usize {
    std.debug.assert(rt.gc.doomed_pending);
    const started = profile.nowNanos();
    // Read once per slice. The environment switch is fixed at Runtime init;
    // reloading it around every destructor made the disabled probe part of
    // the path it was meant to observe.
    const probe_enabled = destroy_probe;
    var destroyed: usize = 0;
    var since_clock: usize = 0;

    const old_phase = rt.gc.phase;
    rt.gc.phase = .tracer_destroy;
    defer rt.gc.phase = old_phase;

    // Block corpses first: they are all plain objects, which is exactly the
    // kind order's first pass, so draining them before the list phases keeps
    // "objects before realms before shapes" intact -- standalone objects on
    // the list still get their turn in pass 0 below.
    if (comptime gc.block_heap_enabled) {
        while (rt.gc.block_heap.doomed_blocks) |block| {
            // Geometry is immutable until `resetBlock`. Pass A only strips
            // resources and parks each struct; its alloc bit is cleared in
            // Pass B, so this block cannot become empty/reset underneath a
            // finalizer callback. Keep the base/stride across callbacks
            // instead of reloading both fields for every corpse.
            const cells_base = @intFromPtr(block) + block.cells_offset + gc.metadata_prefix_size;
            const cell_size: usize = block.cell_size;
            while (block.takeDoomedCell(0)) |index| {
                const header: *gc.Header = @ptrFromInt(cells_base + @as(usize, index) * cell_size);
                std.debug.assert(header.meta().flags.kind == .object);
                // The alloc bit and heap-accounted stamp remain live through
                // every payload callback, so containsHeader's block iterator
                // already publishes this object. Standalone/list objects need
                // sweep_current below because condemnation delisted them.
                const d0 = if (probe_enabled) profile.nowNanos() else 0;
                Object.destroyFromHeader(rt, header);
                if (probe_enabled) {
                    destroy_probe_dtor_ns +|= profile.nowNanos() -| d0;
                    destroy_probe_corpses +|= 1;
                }
                destroyed += 1;
                since_clock += 1;
                if (since_clock == destroy_clock_cadence) {
                    since_clock = 0;
                    if (profile.nowNanos() -| started >= budget_ns) {
                        rt.gc.doomed_destroyed += destroyed;
                        rt.gc.concurrent.stats.doomed_destroyed_objects +|= destroyed;
                        return destroyed;
                    }
                }
            }
            // Pass A has consumed this block's whole doomed bitmap, so its
            // alloc bitmap and `allocated_count` are canonical again -- which
            // under stage 3 is a claim about work this loop just did, not a
            // tautology. Name the offending block here rather than waiting for
            // the next whole-heap `AllocCountMismatch`.
            if (gc.invariantChecksEnabled()) {
                BlockHeapMod.Heap.verifyBlockAllocCount(block) catch |err| {
                    std.debug.print(
                        "gc: PASS-A SETTLEMENT AUDIT: {s} block=0x{x} allocated_count={d}\n",
                        .{ @errorName(err), @intFromPtr(block), block.allocated_count },
                    );
                    @panic("Pass-A settlement left a block's alloc bitmap and count disagreeing");
                };
            }
            const link = block.doomed_link;
            block.doomed_link = 0;
            rt.gc.block_heap.doomed_blocks = if (link <= 1) null else @ptrFromInt(link);
        }
    }

    while (rt.gc.doomed_phase < doomed_phase_kinds.len + 1) {
        const final_pass = rt.gc.doomed_phase == doomed_phase_kinds.len;
        const phase_kind: gc.GcKind = if (final_pass) .shape else doomed_phase_kinds[rt.gc.doomed_phase];
        const bucket = &rt.gc.doomed_by_kind[@intFromEnum(phase_kind)];
        var cursor = rt.gc.doomed_cursor orelse bucket.sentinel.next;
        while (cursor) |h| {
            if (h == &bucket.sentinel) break;
            const next = h.next;
            const kind = h.meta().flags.kind;
            // The bucket only holds this phase's kind, so the test is an
            // assertion rather than a filter now.
            const wanted = kind == phase_kind;
            if (wanted) {
                // Each kind owns one bucket and destruction consumes it from
                // the head, including after a budgeted resume.
                gc.listDelAfterTraversalOwned(bucket, &bucket.sentinel, h);
                rt.gc.sweep_current = h;
                const d0 = if (destroy_probe) profile.nowNanos() else 0;
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
                if (destroy_probe) {
                    destroy_probe_dtor_ns +|= profile.nowNanos() -| d0;
                    destroy_probe_corpses +|= 1;
                }
                rt.gc.sweep_current = null;
                if (kind != .function_bytecode) destroyed += 1;
            }
            // Count VISITED nodes, not destroyed ones. The morgue is walked
            // once per kind, so a pass looking for shapes steps over every
            // object, realm, module and var_ref on the list -- and with the
            // counter inside the `wanted` arm those steps never reached a
            // budget check. A long list of the wrong kind was an unbounded
            // scan with no clock read in it (adversarial review, codex,
            // 2026-08-27).
            since_clock += 1;
            if (since_clock == destroy_clock_cadence) {
                since_clock = 0;
                if (profile.nowNanos() -| started >= budget_ns) {
                    rt.gc.doomed_cursor = next;
                    rt.gc.doomed_destroyed += destroyed;
                    rt.gc.concurrent.stats.doomed_destroyed_objects +|= destroyed;
                    return destroyed;
                }
            }
            cursor = next;
        }
        rt.gc.doomed_phase += 1;
        rt.gc.doomed_cursor = null;
    }

    // Morgue empty: the parked memory trickles back under the same budget.
    // The park's obligation ends with the last destructor; a one-shot drain
    // here was a 6.8 ms pause hiding at the tail of the last slice (found by
    // the per-kind slice maxima -- the budget checks guarded every destroy
    // but not this).
    rt.gc.doomed_destroyed += destroyed;
    rt.gc.concurrent.stats.doomed_destroyed_objects +|= destroyed;
    const drain0 = if (probe_enabled) profile.nowNanos() else 0;
    defer if (probe_enabled) {
        destroy_probe_drain_ns +|= profile.nowNanos() -| drain0;
    };
    const pending_finalizers = rt.hasPendingDeferredClassPayloadFinalizers();
    const parked_before = rt.gc.cycle_deferred_frees.count;
    const drain_complete = !pending_finalizers and
        object_gc.drainCycleDeferredFreesBudgeted(rt, 4096);
    if (!pending_finalizers and parked_before != 0) {
        rt.gc.concurrent.stats.doomed_parked_drain_slices +|= 1;
        rt.gc.concurrent.stats.doomed_parked_entries_drained +|=
            parked_before -| rt.gc.cycle_deferred_frees.count;
    }
    if (drain_complete) {
        // Pass A has stripped every resource and Pass B has now freed every
        // parked Object struct, so block alloc bitmaps are finally canonical.
        // This transaction boundary, not per-block doomed-list removal, is
        // the first sound point to publish partial blocks for interval reuse.
        if (comptime gc.block_heap_enabled) {
            auditDeferredPayloadRootsBeforeBlockPublication(rt);
            rt.gc.block_heap.publishCompletedHotBlocks(rt.gc.cycle_deferred_frees.count);
        }
        rt.gc.doomed_pending = false;
        rt.gc.doomed_cursor = null;
        rt.gc.concurrent.stats.cycles_completed += 1;
    }
    auditDoomedExitInvariant(rt);
    return destroyed;
}

/// Complete any pending sliced destruction synchronously. Explicit
/// collections and teardown call this: destruction is irreversible, so unlike
/// an open marking cycle it cannot be aborted, only finished.
pub fn finishPendingDestruction(rt: *JSRuntime) void {
    while (rt.gc.doomed_pending) {
        _ = destroyDoomedSlice(rt, std.math.maxInt(u64));
        // Payload jobs may retain JSValues into this condemnation. Their
        // callbacks therefore run after every resource destructor but before
        // the parked structs are allowed to disappear. The synchronous entry
        // promises completion, so it also owns completing this prerequisite.
        if (rt.hasPendingDeferredClassPayloadFinalizers()) {
            std.debug.assert(rt.gc.phase == .none);
            // Destruction has returned to Phase.none. Publish that idle state
            // to the reentrant callback so its allocations can request the
            // next collection; the active-job guard still prevents that new
            // request from entering a collector while this morgue is open.
            const collector_was_running = rt.gc_running;
            rt.gc_running = false;
            rt.drainDeferredClassPayloadFinalizers();
            rt.gc_running = collector_was_running;
        }
    }
    auditDoomedExitInvariant(rt);
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
        recordFinalMarkFootprint(self.rt);
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

    /// Whole-heap unmark: one epoch bump for block bitmaps and one for the
    /// fixed-offset epoch shared by every non-block trace carrier. Restore
    /// semantics for the VERIFY_MINOR probe hold: re-marking a saved set under
    /// the new epochs means exactly "marked" again.
    fn clearMarks(self: *Collector) void {
        if (comptime gc.block_heap_enabled) self.rt.gc.block_heap.beginMajor();
        self.rt.gc.advanceHeaderMarkEpoch();
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

    fn countMarkedYoung(self: *Collector) usize {
        var n: usize = 0;
        var iterator = self.rt.gc.youngIterator();
        while (iterator.next()) |header| {
            if (self.rt.gc.headerMarked(header)) n += 1;
        }
        return n;
    }

    /// Shade an edge whose producer owns a typed GC reference. `*Header`
    /// supplies alignment, and the edge contract supplies address validity;
    /// conservative words use `shadeConservativeCandidate` below instead.
    fn shadeExact(self: *Collector, header: *gc.Header) void {
        if (self.err != null) return;
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
            // Owner-private stack first: the hot loop pops it with plain
            // array ops. Full or missing -> the shared ring; a failed ring
            // push is the overflow contract (object marked, flag set, the
            // remark's rescan finds it).
            if (!self.rt.gc.mark_stack.push(header)) {
                _ = self.rt.gc.concurrent_mark_queue.pushSingle(header);
            }
            return;
        }
        self.work.append(self.allocator(), header) catch |err| {
            self.err = err;
        };
    }

    fn shadeOptionalObject(self: *Collector, obj: ?*Object) void {
        const object = obj orelse return;
        self.shadeExact(&object.header);
    }

    pub fn visitValue(self: *Collector, val: *JSValue) void {
        if (val.cycleMarkHeader()) |header| self.shadeExact(header);
    }

    pub fn visitObject(self: *Collector, obj_ptr: *?*Object) void {
        self.shadeOptionalObject(obj_ptr.*);
    }

    pub fn visitShape(self: *Collector, shape_ref: *shape.Shape) void {
        self.shadeExact(&shape_ref.header);
    }

    pub fn visitRealm(self: *Collector, ctx_ptr: *?*context_mod.RealmContext) void {
        if (ctx_ptr.*) |ctx| self.shadeExact(&ctx.header);
    }

    pub fn visitModule(self: *Collector, record: *module_mod.ModuleRecord) void {
        self.shadeExact(&record.header);
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
            // Detached generator shells have a complete payload but no Shape
            // until parameter initialization resolves the final prototype.
            // shade() correctly rejects unpublished objects; mark the block
            // cell directly and trace only its initialized payload.
            if (self.rt.gc.pinEntryIsConstructionRoot(entry)) {
                self.rt.gc.setHeaderMarked(entry.header);
                const object: *Object = @alignCast(@fieldParentPtr("header", entry.header));
                try object.traceDetachedGeneratorShellEdges(self);
                continue;
            }
            self.shadeExact(entry.header);
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
                adaptor.collector.shadeExact(@constCast(header));
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

    fn shadeConservativeCandidate(context: *anyopaque, header: *gc.Header) void {
        const self: *Collector = @ptrCast(@alignCast(context));
        if (self.err != null) return;
        const addr = @intFromPtr(header);
        if (addr < 4096 or !std.mem.isAligned(addr, @alignOf(gc.Header))) return;
        self.shadeExact(header);
    }

    fn seedConservativeRoots(self: *Collector) CollectError!void {
        conservative.spillRegistersAndScan(
            self.rt,
            &self.report.conservative,
            shadeConservativeCandidate,
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
        while (self.rt.gc.mark_stack.pop() orelse queue.popSingle()) |header| {
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
        try traceHeaderEdges(self.rt, self, header);
        if (self.err) |err| return err;
        // Trace-coupled retirement: promotion is bound to "strong edges
        // handled", not to the mark claim, so a header retired here has
        // genuinely been through this cycle's trace.
        self.rt.gc.retireTracedYoung(header);
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
                            self.shadeExact(child);
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
    fn sweepUnmarkedYoung(self: *Collector, full_reachable: ?*const FullReachable) usize {
        gc.listInit(&self.rt.gc.tmp_obj_list);

        // The production sweep consumes each dead header exactly once. Keep
        // a pointer snapshot only for the two diagnostics that need to inspect
        // the whole condemned set before mutation; allocating/growing this
        // array and replaying it was pure per-minor work otherwise.
        const snapshot_doomed = full_reachable != null or gc.minor_audit;
        var doomed: std.ArrayList(*gc.Header) = .empty;
        defer doomed.deinit(self.allocator());
        // Every condemned kind is freed, not just `.object` -- see
        // `destroyCondemned`. A young var_ref or shape the trace did not reach
        // is exactly as dead as a young object it did not reach. The trace is
        // the liveness authority; rc cannot mask a missing root or barrier.
        if (snapshot_doomed) {
            // Preserve the production producer order even under diagnostics:
            // block Objects first, then the standalone/list population. Pass A
            // pushes in this order, so LIFO Pass B gets its required generic
            // prefix followed by one block-only suffix.
            var young_blocks = self.rt.gc.youngBlockIterator();
            while (young_blocks.next()) |header| {
                if (self.rt.gc.headerMarked(header)) continue;
                if (header.metaConst().flags.is_pinned) continue;
                doomed.append(self.allocator(), header) catch return 0;
            }
            var young_cursor = self.rt.gc.young_head;
            while (young_cursor) |header| {
                if (header == &self.rt.gc.gc_obj_list.sentinel) break;
                young_cursor = header.next;
                if (self.rt.gc.headerMarked(header)) continue;
                if (header.metaConst().flags.is_pinned) continue;
                doomed.append(self.allocator(), header) catch return 0;
            }
        } else {
            // Block cells must be parked before the generic list population.
            // LIFO reversal then gives Pass B its generic-prefix/block-suffix
            // topology without a per-entry descriptor.
            var young_blocks = self.rt.gc.youngBlockIterator();
            while (young_blocks.next()) |header| {
                if (self.rt.gc.headerMarked(header)) continue;
                if (header.metaConst().flags.is_pinned) continue;
                self.rt.gc.detachCycleCandidate(header);
                gc.listAddTailTraversalOwned(&self.rt.gc.tmp_obj_list, header);
            }
            // The list population is a young suffix. Its predecessor was
            // captured at the first publication, so deletion is O(young).
            if (self.rt.gc.young_head) |young_head| {
                var previous = self.rt.gc.young_predecessor orelse unreachable;
                var cursor: ?*gc.Header = young_head;
                while (cursor) |header| {
                    if (header == &self.rt.gc.gc_obj_list.sentinel) break;
                    const next = header.next;
                    if (self.rt.gc.headerMarked(header) or header.metaConst().flags.is_pinned) {
                        previous = header;
                        cursor = next;
                        continue;
                    }
                    self.rt.gc.detachCycleCandidateAfter(previous, header);
                    gc.listAddTailTraversalOwned(&self.rt.gc.tmp_obj_list, header);
                    cursor = next;
                }
            }
        }
        if (full_reachable) |reachable| {
            var violations: usize = 0;
            var precise_violations: usize = 0;
            for (doomed.items) |header| {
                const reachability = reachable.entries.get(@intFromPtr(header)) orelse continue;
                violations += 1;
                if (reachability == .precise) precise_violations += 1;
                const kind = header.metaConst().flags.kind;
                if (kind == .object) {
                    const o: *Object = @alignCast(@fieldParentPtr("header", header));
                    std.debug.print("VERIFY-MINOR condemned-but-reachable source={s} kind=object class={d} payload={s}\n", .{ @tagName(reachability), o.class_id, @tagName(o.flags.class_payload_kind) });
                } else {
                    std.debug.print("VERIFY-MINOR condemned-but-reachable source={s} kind={s}\n", .{ @tagName(reachability), @tagName(kind) });
                }
            }
            if (violations != 0) {
                std.debug.print("VERIFY-MINOR {d} of {d} condemned objects are reachable by a full trace ({d} precise, {d} conservative-only)\n", .{
                    violations,
                    doomed.items.len,
                    precise_violations,
                    violations - precise_violations,
                });
            }
        }
        if (gc.minor_audit) self.auditCondemnedYoung(doomed.items);
        if (snapshot_doomed) {
            for (doomed.items) |header| {
                self.rt.gc.detachCycleCandidate(header);
                gc.listAddTailTraversalOwned(&self.rt.gc.tmp_obj_list, header);
            }
        }

        const old_phase = self.rt.gc.phase;
        self.rt.gc.phase = .tracer_destroy;
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

        // Block cells are appended first so the object Pass-A walk parks them
        // before standalone/list objects. LIFO reversal is then the same as the
        // incremental major: optional generic prefix, contiguous block suffix.
        // Both populations are `.object` in this pass, so this changes no
        // destructor-kind ordering.
        var block_iterator = self.rt.gc.deadBlockCandidateIterator();
        while (block_iterator.next()) |header| {
            if (header.metaConst().flags.is_pinned) {
                header.meta().flags.young = false;
                continue;
            }
            self.rt.gc.detachCycleCandidate(header);
            gc.listAddTailTraversalOwned(&self.rt.gc.tmp_obj_list, header);
        }

        // List carriers are singly linked in trace. Walk them with an explicit
        // predecessor so every condemnation is an O(1) splice.
        var previous: *gc.Header = &self.rt.gc.gc_obj_list.sentinel;
        var cursor = previous.next;
        while (cursor) |header| {
            if (header == &self.rt.gc.gc_obj_list.sentinel) break;
            const next = header.next;
            if (self.rt.gc.headerMarked(header)) {
                // The mark STAYS. §8.2's sticky rule is `allocated && marked`
                // is old, and the survivor's mark is what tells the next
                // minor's `shadeExact()` to stop at it -- clearing here made the
                // first minor after every major find the whole heap unmarked
                // and re-trace the entire live set from the roots (~29 ms per
                // probe minor on splay, against a 1 ms target). The next
                // major's `clearMarks` is the clearer; this used to clear a
                // second time. Retiring the young bit rides the same walk,
                // which is what deleted `clearYoungState`'s third whole-heap
                // pass.
                header.meta().flags.young = false;
                previous = header;
                cursor = next;
                continue;
            }
            if (header.metaConst().flags.is_pinned) {
                // An unmarked-but-pinned survivor must retire its young bit
                // too: it leaves the suffix when `young_head` resets below,
                // and a stale young bit would make the barrier remember its
                // owner on every store, forever.
                header.meta().flags.young = false;
                previous = header;
                cursor = next;
                continue;
            }
            self.rt.gc.detachCycleCandidateAfter(previous, header);
            gc.listAddTailTraversalOwned(&self.rt.gc.tmp_obj_list, header);
            cursor = next;
        }

        // The compact trace header has no predecessor.  Close the retired
        // pre-sweep suffix here; any allocation performed by destruction opens
        // a fresh young tail that clearYoungState can walk forward exactly.
        self.rt.gc.resetYoungListSuffix();

        const old_phase = self.rt.gc.phase;
        self.rt.gc.phase = .tracer_destroy;
        defer self.rt.gc.phase = old_phase;

        const garbage_count = self.destroyCondemned();
        if (!self.rt.hasPendingDeferredClassPayloadFinalizers()) {
            object_gc.drainCycleDeferredFrees(self.rt);
            if (comptime gc.block_heap_enabled) {
                self.rt.gc.block_heap.publishCompletedHotBlocks(self.rt.gc.cycle_deferred_frees.count);
            }
        }
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
                        @tagName(a.owner_kind), @intFromPtr(a.owner_ptr),             a.owner_young,                 a.owner_remembered,
                        c.class_id,             @tagName(c.flags.class_payload_kind), child.metaConst().flags.young, a.rt.gc.headerMarked(child),
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
        self.rt.gc.beginDeferredFreeProducerSequence();
        var garbage_count: usize = 0;
        var previous: *gc.Header = &self.rt.gc.tmp_obj_list.sentinel;
        var cursor = self.rt.gc.tmp_obj_list.sentinel.next;
        while (cursor) |h| {
            if (h == &self.rt.gc.tmp_obj_list.sentinel) break;
            const next = h.next;
            if (h.meta().flags.kind == .object) {
                gc.listDelAfterTraversalOwned(&self.rt.gc.tmp_obj_list, previous, h);
                garbage_count += 1;
                self.rt.gc.sweep_current = h;
                Object.destroyFromHeader(self.rt, h);
                self.rt.gc.sweep_current = null;
            } else {
                previous = h;
            }
            cursor = next;
        }
        previous = &self.rt.gc.tmp_obj_list.sentinel;
        cursor = self.rt.gc.tmp_obj_list.sentinel.next;
        while (cursor) |h| {
            if (h == &self.rt.gc.tmp_obj_list.sentinel) break;
            const next = h.next;
            if (h.meta().flags.kind == .realm_context) {
                gc.listDelAfterTraversalOwned(&self.rt.gc.tmp_obj_list, previous, h);
                garbage_count += 1;
                self.rt.gc.unlinkObjectWithBytes(h, gc.Registry.heapByteSizeFromHeader(self.rt, h));
                self.rt.gc.sweep_current = h;
                context_mod.JSContext.destroyFromHeader(self.rt, h);
                self.rt.gc.sweep_current = null;
            } else {
                previous = h;
            }
            cursor = next;
        }
        previous = &self.rt.gc.tmp_obj_list.sentinel;
        cursor = self.rt.gc.tmp_obj_list.sentinel.next;
        while (cursor) |h| {
            if (h == &self.rt.gc.tmp_obj_list.sentinel) break;
            const next = h.next;
            if (h.meta().flags.kind == .module) {
                gc.listDelAfterTraversalOwned(&self.rt.gc.tmp_obj_list, previous, h);
                garbage_count += 1;
                self.rt.gc.unlinkObjectWithBytes(h, gc.Registry.heapByteSizeFromHeader(self.rt, h));
                self.rt.gc.sweep_current = h;
                module_mod.ModuleRecord.destroyFromHeader(self.rt, h);
                self.rt.gc.sweep_current = null;
            } else {
                previous = h;
            }
            cursor = next;
        }
        previous = &self.rt.gc.tmp_obj_list.sentinel;
        cursor = self.rt.gc.tmp_obj_list.sentinel.next;
        while (cursor) |h| {
            if (h == &self.rt.gc.tmp_obj_list.sentinel) break;
            const next = h.next;
            if (h.meta().flags.kind == .function_bytecode) {
                gc.listDelAfterTraversalOwned(&self.rt.gc.tmp_obj_list, previous, h);
                self.rt.gc.unlinkObjectWithBytes(h, gc.Registry.heapByteSizeFromHeader(self.rt, h));
                self.rt.gc.sweep_current = h;
                function_bytecode_mod.destroyFromHeader(self.rt, h);
                self.rt.gc.sweep_current = null;
            } else {
                previous = h;
            }
            cursor = next;
        }
        while (gc.listFirst(&self.rt.gc.tmp_obj_list)) |h| {
            gc.listDelAfterTraversalOwned(&self.rt.gc.tmp_obj_list, &self.rt.gc.tmp_obj_list.sentinel, h);
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

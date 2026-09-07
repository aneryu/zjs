//! The collector: non-moving, generational (sticky mark bit), incrementally
//! marking, stop-the-world at every step (tracing-gc-design.md, current
//! state in gc-invariants.md). Majors mark from precise + conservative roots
//! into block bitmaps / header epochs and condemn from the bitmaps; minors
//! trace the young set from roots plus the remembered owners. Strong edges
//! walk `traceChildEdges*`; WeakMap/WeakSet values are NOT marked during the
//! strong walk (`visitWeakCollectionEntry` is a no-op) -- a separate
//! ephemeron fixed point marks a value only when both its table and key are
//! live. A collection failure returns to the caller; the runtime aborts the
//! cycle and retries from fresh marks.

const std = @import("std");
const builtin = @import("builtin");

const atom_mod = @import("atom.zig");
const conservative = @import("gc_conservative.zig");
const context_mod = @import("context.zig");
const gc = @import("gc.zig");
const module_mod = @import("module.zig");
const object_gc = @import("object_gc.zig");
const object_mod = @import("object.zig");
const object_payloads = @import("object_payloads.zig");
const profile = @import("profile.zig");
const BlockHeapMod = @import("gc_block_heap.zig");
const gc_audit_print = @import("gc_audit_print.zig");
const runtime_mod = @import("runtime.zig");
const property = @import("property.zig");
const shape = @import("shape.zig");
const string_mod = @import("string.zig");
const var_ref_mod = @import("var_ref.zig");
const bigint_mod = @import("bigint.zig");
const function_bytecode_mod = @import("../bytecode.zig").function_bytecode;
const FunctionBytecode = function_bytecode_mod.FunctionBytecode;
const JSRuntime = runtime_mod.JSRuntime;
const JSValue = @import("value.zig").JSValue;
const Object = object_mod.Object;

const CollectError = std.mem.Allocator.Error || error{PayloadMarkFailed};

fn checkFrontierFailure(queue: *const gc.mark_queue.Queue) CollectError!void {
    switch (queue.failure()) {
        .none => {},
        .out_of_memory => return error.OutOfMemory,
        .unqueueable_barrier => return error.PayloadMarkFailed,
    }
}

fn popSegmentedFrontier(
    stack: *gc.MarkStack,
    queue: *gc.mark_queue.Queue,
    comptime prefetch: bool,
) ?*gc.Header {
    while (true) {
        if (if (prefetch) stack.popPrefetch() else stack.pop()) |entry| return entry;
        if (!queue.steal(stack)) return null;
    }
}

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
        const cell_kind = header.metaConst().flags.kind;
        if (cell_kind != .object) {
            // TGC S4-a: the string family is two kinds now, so the prefix
            // re-read `traceStringEdges` used to do is this dispatch instead.
            std.debug.assert(gc.kindIsPrefixCarrier(cell_kind));
            if (cell_kind == .rope) return string_mod.traceRopeEdges(rt, visitor, header);
            // A flat body and a `.string_buffer` tail buffer are leaves.
            return;
        }
    } else switch (header.meta().flags.kind) {
        // Fall through to the one shared object body below. Keeping a single
        // hot entry matters: spelling the fast path as an early object return
        // made LLVM emit separate block/non-block object-entry sequences.
        .object => {},
        .function_bytecode => {
            const fb: *FunctionBytecode = @alignCast(@fieldParentPtr("header", header));
            visitor.visitRealm(&fb.realm.ptr);
            for (fb.cpoolSlice()) |*stored| visitor.visitValue(stored);
            try traceFunctionBytecodeAtoms(rt, fb, visitor);
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
        // A flat body is a leaf; an extent is always flat (`allocRopeNode`
        // asserts a rope node fits a cell), so this arm has no edges to walk.
        .string => return,
        .rope => return string_mod.traceRopeEdges(rt, visitor, header),
        .big_int => return,
        // Storage cells are marked by their owner's edge and have no
        // out-edges of their own: TGC S2-i's tail buffer is reported by
        // `traceRopeEdges`, the S4-b property/array buffers by
        // `Object.traceChildEdgesFallible`, and S4-c's payload kind is not
        // minted yet.
        .string_buffer, .property_storage, .array_storage, .payload => return,
    }

    const obj = Object.fromHeader(header);
    try obj.traceChildEdgesFallible(rt, visitor);
}

/// TGC S3 §2.4: run the atom table's sweep for the major that just finished.
///
/// MUST run with the mutator stopped, in the same pause that took the verdict.
/// The verdict is "no `visitAtom` edge, no marked body, no host pin, not born
/// this epoch", and it is only true of the heap AS OF THE END OF MARKING. The
/// entry is still indexed until this sweep unindexes it, so if the mutator gets
/// to run in between it can re-obtain the id from `internString` (a hash hit on
/// an entry the trace found unreachable), store it into a surviving holder
/// through `noteHolderStore` -- whose insertion barrier is disarmed, marking is
/// over -- and then watch this sweep retire the entry and recycle the slot under
/// a live shape key. That is exactly what deferring the call to
/// `destroyDoomedSlice`'s drain-complete did: the incremental path condemns at
/// finish and destroys in later slices, so the window was every interrupt poll
/// of a whole destruction run (pdfjs: a live `objs` shape kept the key
/// `font_p0_1` while its id was rebound to another spelling).
///
/// Both major paths therefore call this inside their own pause, after
/// condemnation. Unmarked string cells are condemned but NOT yet destroyed on
/// the incremental path, so `sweepDead` also has to unbind the cached bodies
/// that did not survive (see its "doomed cache" arm) -- that is the part the
/// destroy handshake used to do before the mutator could look.
fn sweepAtomTable(rt: *JSRuntime) void {
    const epoch = rt.gc.block_heap.mark_epoch;
    rt.atoms.sweepDead(rt, epoch);
}

/// TGC S3 §2.2 edges B/C/D and H: every atom id a FunctionBytecode owns.
///
/// B  `func_name`, `filename`, `script_or_module`
/// C  the 4-byte atom operand inlined in each atom-format opcode
/// D  `vardefs[].var_name` and `closureVar()[].var_name`
/// H  the small-inline `CallerState` (reported through the exec hook)
///
/// Visitors without a `visitAtom` decl compile this away entirely.
fn traceFunctionBytecodeAtoms(rt: *JSRuntime, fb: *FunctionBytecode, visitor: anytype) CollectError!void {
    const VisType = @TypeOf(visitor);
    const CleanType = comptime if (@typeInfo(VisType) == .pointer) @typeInfo(VisType).pointer.child else VisType;
    if (comptime !@hasDecl(CleanType, "visitAtom")) return;

    try atom_mod.callVisitAtom(visitor, fb.funcName());
    try atom_mod.callVisitAtom(visitor, fb.filenameAtom());
    try atom_mod.callVisitAtom(visitor, fb.scriptOrModule());
    for (fb.allVarDefs()) |vardef| try atom_mod.callVisitAtom(visitor, vardef.var_name);
    for (fb.closureVar()) |closure_var| try atom_mod.callVisitAtom(visitor, closure_var.var_name);
    var operands = fb.atomOperandIterator();
    while (operands.next()) |operand| try atom_mod.callVisitAtom(visitor, operand);

    const hook = rt.small_inline_trace_atoms orelse return;
    const Bridge = struct {
        vis: VisType,
        failed: bool = false,
        fn visit(ctx: *anyopaque, id: atom_mod.Atom) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            atom_mod.callVisitAtom(self.vis, id) catch {
                self.failed = true;
            };
        }
    };
    var bridge = Bridge{ .vis = visitor };
    hook(rt, @ptrCast(fb), @ptrCast(&bridge), Bridge.visit);
    if (bridge.failed) return error.OutOfMemory;
}

/// What a collection leaves behind for tests and the census deduction; the
/// collector's own control flow reads only `skipped_sweep_incomplete_arenas`
/// and the ephemeron counters.
pub const Report = struct {
    /// Objects the conservative arm marked beyond the precise trace
    /// (detailed reports only).
    marked_conservative_extra: usize = 0,
    swept: usize = 0,
    ephemeron_rounds: usize = 0,
    ephemeron_values_shaded: usize = 0,
    conservative: conservative.Metrics = .{},
    /// Of this collection's wall time, how much went on census walks.
    census_ns: u64 = 0,
    /// The round marked but did not sweep: an arena was unregistered, so a
    /// conservative candidate into it could not have been resolved.
    skipped_sweep_incomplete_arenas: bool = false,
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
        // TGC S4-a: rope nodes became their own kind. The census keeps
        // reporting one `string` population -- the two shapes are one family
        // to every consumer of this panel, and folding here keeps
        // `gc_stats_snapshot.py`'s existing line intact.
        self.by_kind[
            @intFromEnum(switch (kind) {
                // TGC S2-i folds the tail buffer in as well: it is string bytes
                // that used to sit inside the flat bodies this row already counted.
                .rope, .string_buffer => gc.GcKind.string,
                else => kind,
            })
        ] +|= 1;
        if (gc.Registry.isBlockCellHeader(header)) self.block_headers +|= 1;
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
///
/// "Every mark bit" is two populations, not one. `objectIterator(.all)` covers
/// the first -- non-block headers, block cells, side objects, and (since TGC
/// S2) the string/`string_buffer`/`property_storage`/`array_storage`/`payload`
/// extents, whose mark lives in the extent table row rather than in a header
/// or a block bitmap; `setHeaderMarked` routes each of those back to the same
/// place `headerMarked` reads it from, so the save/restore below is exact for
/// all of them. `.rope` is a block cell by comptime assertion and needs no
/// extent arm.
///
/// The second population is the atom table, which is NOT a heap object and so
/// is in no iterator: its liveness is a stamp compared against
/// `Heap.mark_epoch`, the very counter `clearMarks` advances to give the probe
/// a private mark space. `AtomTable.restampTraceEpoch` is the restore for that
/// half -- without it the epoch this function returns under is four ahead of
/// every stamp the cycle made, `sweepAtomTable` finds the whole table dead,
/// and the run this is supposed to be auditing dies of missing property keys.
fn computeFullReachable(rt: *JSRuntime, scan: runtime_mod.GCRootScan) !FullReachable {
    const allocator = rt.memory.persistent_allocator;
    const entry_epoch: u64 = rt.gc.block_heap.mark_epoch;
    var reachable: FullReachable = .{ .allocator = allocator };
    errdefer reachable.deinit();

    // A sticky oracle runs inside final remark while the marking flag is
    // still published. Its fresh root walk must not black-publish into the
    // production queue it is auditing. The mutator is stopped here; suppress
    // the barrier mode for the diagnostic and restore it before returning.
    const marking_was_active = rt.gc.incremental.markingActive();
    if (marking_was_active) rt.gc.setMajorMarkingActive(false);
    defer if (marking_was_active) rt.gc.setMajorMarkingActive(true);

    var saved: std.ArrayList(*gc.Header) = .empty;
    defer saved.deinit(allocator);
    {
        var it = rt.gc.objectIterator(.all);
        while (it.next()) |header| {
            if (rt.gc.headerMarked(header)) try saved.append(allocator, header);
        }
    }

    var probe = try Collector.init(rt, null, scan);
    defer probe.deinit();
    probe.atom_stamps_frozen = true;
    probe.clearMarks();
    try probe.seedRoots();
    try probe.drain();
    try probe.ephemeronFixedPoint();
    const precise_young = probe.countMarkedYoung();
    {
        var it = rt.gc.objectIterator(.all);
        while (it.next()) |header| {
            if (rt.gc.headerMarked(header)) {
                try reachable.entries.put(allocator, @intFromPtr(header), .precise);
            }
        }
    }
    const diag_direct_before: usize = conservative.diagThreadDirect();
    if (probe.conservative_on) {
        if (comptime gc.roots_diag_enabled) {
            // Same scan, but the callback records every header this arm
            // marks that the precise arm did not (R3 census).
            conservative.spillRegistersAndScan(
                rt,
                &probe.report.conservative,
                Collector.recordConservativeCandidate,
                @ptrCast(&probe),
            );
            if (probe.err) |err| return err;
        } else {
            try probe.seedConservativeRoots();
        }
        try probe.drain();
    }
    // `processWeak` is deliberately NOT run: it clears weak references, and a
    // diagnostic pass must not have side effects the real collection then sees.
    try probe.ephemeronFixedPoint();
    const all_young = probe.countMarkedYoung();
    rt.gc.generation.stats.conservative_only_young +|= all_young -| precise_young;

    var conservative_only_count: usize = 0;
    {
        var it = rt.gc.objectIterator(.all);
        while (it.next()) |header| {
            if (rt.gc.headerMarked(header)) {
                const result = try reachable.entries.getOrPut(allocator, @intFromPtr(header));
                if (!result.found_existing) {
                    result.value_ptr.* = .conservative_only;
                    conservative_only_count += 1;
                }
            }
        }
    }
    if (comptime gc.roots_diag_enabled) {
        if (probe.conservative_on) conservative.noteProbe(conservative_only_count, conservative.diagThreadDirect() - diag_direct_before);
    }

    probe.clearMarks();
    for (saved.items) |header| rt.gc.setHeaderMarked(header);
    rt.atoms.restampTraceEpoch(entry_epoch, rt.gc.block_heap.mark_epoch);
    return reachable;
}

/// Reject the exact set an incremental finish is about to condemn against a
/// trace that started from freshly cleared marks.
///
/// Fail-closed on PRECISE disagreements only, and that asymmetry is the whole
/// design: a condemned object the fresh precise roots reach is a kill, full
/// stop, so the caller aborts before weak state or object storage is mutated.
/// A conservative-only disagreement is a different animal. This oracle runs on
/// a deeper native frame than the cycle it audits, so pointer residue can exist
/// in one scan and not the other -- `computeFullReachable`'s own contract has
/// said so since the minor verifier. Counting it as a kill would abort healthy
/// cycles; ignoring it silently would hide a real signal. So it is counted,
/// separately (`ZJS_GC_VERIFY_MAJOR_ALL`, roots-diag builds).
fn verifyFullCondemnation(rt: *JSRuntime, reachable: *const FullReachable) CollectError!void {
    var precise_violations: usize = 0;
    var conservative_violations: usize = 0;
    var reported: usize = 0;
    var objects = rt.gc.objectIterator(.all);
    while (objects.next()) |header| {
        if (rt.gc.headerMarked(header) or rt.gc.headerIsPinned(header)) continue;
        const source = reachable.entries.get(@intFromPtr(header)) orelse continue;
        switch (source) {
            .precise => precise_violations += 1,
            .conservative_only => conservative_violations += 1,
        }
        if (reported < 8) {
            reported += 1;
            gc_audit_print.print(&.{
                .{ .text = "VERIFY-MAJOR condemned-but-reachable source=" },
                .{ .text = @tagName(source) },
                .{ .text = " kind=" },
                .{ .text = @tagName(header.metaConst().flags.kind) },
                .{ .text = "\n" },
            });
        }
    }
    if (precise_violations + conservative_violations == 0) return;
    gc_audit_print.print(&.{
        .{ .text = "VERIFY-MAJOR " },
        .{ .dec = precise_violations },
        .{ .text = " precise, " },
        .{ .dec = conservative_violations },
        .{ .text = " conservative-only condemned-but-reachable\n" },
    });
    if (precise_violations == 0) return;
    return error.PayloadMarkFailed;
}

/// Compute the census fields that each cost a whole-heap walk.
///
/// A major over the compatibility heap needs `clearMarks` before the trace and
/// `sweepUnmarked` after it, plus `clearYoungState` to retire the young set.
/// `collectCycles` used to do eight passes; the census-only ones (object
/// counts before/after marking, two `liveCount()` walks) are gone with the
/// fields they fed. Only `marked_conservative_extra` survives, and only under
/// detailed reports.
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

fn requireInvariant(result: anyerror!void, audit: []const u8, panic_message: []const u8) void {
    result catch |err| {
        gc_audit_print.print(&.{
            .{ .text = "gc: " },
            .{ .text = audit },
            .{ .text = " AUDIT: " },
            .{ .text = @errorName(err) },
            .{ .text = "\n" },
        });
        @panic(panic_message);
    };
}

fn verifyCollectorInvariants(
    rt: *JSRuntime,
    verify_scan_cache: bool,
    require_retirement_commit: bool,
) void {
    const stale = rt.gc.address_registry.auditArenas();
    const missing = auditLiveObjectsResolve(rt);
    if (stale != 0 or missing != 0) {
        gc_audit_print.print(&.{
            .{ .text = "gc: ARENA AUDIT: " },
            .{ .dec = stale },
            .{ .text = " free blocks read live, " },
            .{ .dec = missing },
            .{ .text = " live objects unresolvable\n" },
        });
        @panic("arena invariant violated");
    }
    requireInvariant(rt.gc.address_registry.verifyIndex(verify_scan_cache), "ADDRESS INDEX", "address index invariant violated");
    // The shape table is the one engine-global structure the MUTATOR consults
    // while a morgue is open, and condemnation's delist is what keeps corpses
    // out of it. That delist reads `is_hashed` as "linked in a bucket", so the
    // biconditional it reads is an invariant with no owner -- check it.
    requireInvariant(rt.shapes.verifyHashIndex(), "SHAPE HASH INDEX", "shape hash index invariant violated");
    // Validate construction pins before BlockHeap consults them as the
    // sole exception to the publication rule. A corrupt exception authority
    // must never turn arbitrary unpublished cells into accepted state.
    requireInvariant(rt.gc.verifyConstructionRoots(), "CONSTRUCTION ROOT", "construction root invariant violated");
    requireInvariant(rt.gc.verifyRepresentationInvariants(), "REPRESENTATION", "GC representation invariant violated");
    auditDeferredPayloadRootsBeforeBlockPublication(rt);
    requireInvariant(rt.gc.verifyObjectPropertyStorageLayouts(rt), "PROPERTY STORAGE", "object property storage invariant violated");
    requireInvariant(rt.gc.verifyIntrusiveList(), "INTRUSIVE LIST", "intrusive list invariant violated");
    requireInvariant(rt.gc.block_heap.verify(), "BLOCK HEAP", "block heap invariant violated");
    requireInvariant(
        rt.gc.block_heap.verifyPublishedCellsAllowing(
            gc.representation.block_cell_size_class,
            @as(u3, @intCast(@intFromEnum(gc.GcKind.object))),
            .{
                .context = @ptrCast(&rt.gc),
                .classify = gc.Registry.blockCellPublicationAllowance,
            },
        ),
        "BLOCK CELL PUBLICATION",
        "block cell publication invariant violated",
    );
    requireInvariant(rt.gc.verifyGenerationInvariants(), "GENERATION", "generation invariant violated");
    if (require_retirement_commit) {
        requireInvariant(rt.gc.verifyMajorRetirementCommit(), "RETIREMENT", "young retirement incomplete");
    }
    // The accounting population includes both block doom bitmaps and the
    // non-block morgue, so an open destruction transaction is now auditable
    // instead of becoming a blind interval for lost owner links.
    requireInvariant(rt.gc.verifyHeapAccounting(rt), "HEAP ACCOUNTING", "heap accounting invariant violated");
}

/// Record one major's final marked set after root/edge/ephemeron closure and
/// before weak processing or condemnation mutates the heap. This is the only
/// denominator suitable for cross-workload "per marked object" pricing.
/// Gated on `mark_footprint_census`, not on `detailed_reports`: this walk runs
/// inside the final-remark stop and is the one census big enough to move the
/// benchmark scores the panel is used to read (see `mark_footprint_census`).
fn recordFinalMarkFootprint(rt: *JSRuntime) void {
    if (!mark_footprint_census) return;
    const started = censusStart();
    defer censusEnd(started);

    const footprint = &rt.gc_mark_footprint;
    footprint.major_censuses +|= 1;
    var marked = rt.gc.objectIterator(.all);
    while (marked.next()) |header| {
        if (!rt.gc.headerMarked(header)) continue;
        footprint.noteMarkedHeader(header);

        if (header.metaConst().flags.kind == .object) {
            const object = Object.fromHeaderConst(header);
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
    rt.gc.stats.collections += 1;
    // The epoch bump and the hot-block withdrawal belong to `clearMarks`,
    // which `Collector.run` reaches below; this entry used to do them a second
    // time before it.
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
    // `Collector.run` returns 0 without sweeping when the conservative address
    // set is not whole. That is an exit from the transaction, not a completion:
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
    last_report.census_ns = last_census_ns;
    if (gc.invariantChecksEnabled()) {
        verifyCollectorInvariants(
            rt,
            collector.conservative_on,
            !collector.report.skipped_sweep_incomplete_arenas,
        );
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
    collector.minor_mode = true;
    defer collector.deinit();

    // TGC S4-h (2): trace-coupled retirement, the major's mechanism applied to
    // the minor. Abandoned on any error, because a half-retired young set is
    // exactly the split `abandonMajorRetirement` guards against.
    errdefer rt.gc.generation.abandonMinorRetirement();

    var full_reachable: ?FullReachable = null;
    defer if (full_reachable) |*reachable| reachable.deinit();
    if (gc.verify_minor) {
        full_reachable = computeFullReachable(rt, scan) catch |err| blk: {
            gc_audit_print.print(&.{
                .{ .text = "VERIFY-MINOR setup failed: " },
                .{ .text = @errorName(err) },
                .{ .text = "\n" },
            });
            break :blk null;
        };
    }

    // Open the retirement transaction BEFORE anything can shade, exactly as
    // both majors do. The binding rule is "a MARK CLAIM owes a retirement",
    // not "a frontier pop owes one": a minor's marking phase has three entries
    // that claim a mark WITHOUT a frontier round trip -- `storageCell`'s leaf
    // claim (S4-g (2)), `shadeExact`'s synchronous shape/realm arm, and
    // `seedRoots`'s construction-root arm -- and every one of them is reached
    // during root seeding or the remembered walk. With the window opened after
    // the remembered walk those claims marked a young block cell and retired
    // nothing, and `drain` could not repair it because both shade entries
    // early-return on `headerMarked`. The cell then survived the sweep with
    // its young bit still set while `closeYoungGeneration` took every young
    // structure away from under it -- a live cell that is young, on no young
    // list and in no census. The next minor that re-admits its block to the
    // young chain clears its mark with `clearYoungBlockMarksStw` (that pass is
    // block-wide, not young-bit-filtered) and `alloc & ~mark` then condemns it
    // alive. That is the ReleaseFast failure: `property_storage` cells of live
    // OLD objects reached through the remembered walk, freed underneath them.
    //
    // `traceRememberedOwner` is the one entry that must NOT retire, and it is
    // handled where it belongs -- at the call, not by keeping the window shut
    // for the whole phase (see there).
    rt.gc.generation.beginMinorRetirement();

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
        try collector.traceRememberedOwner(header);
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
    // Same requirement as the major: a sweep is only sound when every arena
    // and standalone occupant is registered, because a missing range hides
    // its objects from the conservative scan that decides what is live.
    if (!rt.gc.addressSetWhole(rt)) {
        // No sweep runs, but the trace has already retired every block cell it
        // reached, so the header bits and the young structures disagree. Close
        // the generation with the bulk promotion pass rather than leave that
        // split for the next minor to trip over.
        promoteYoungSurvivorsInBulk(rt);
        closeYoungGeneration(rt);
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
    // after the sweep survived this collection, so it is old now. TGC S4-h
    // (2): the trace did that, cell by cell, on header lines it had already
    // loaded (`retireTracedYoung`), and `sweepUnmarkedYoung` closed the young
    // generation between the condemnation and the destruction slice -- so
    // anything published by a destructor is a NEW young object on a fresh
    // young list, which is what it should be. The pass that used to stand here
    // walked the `alloc_info` byte of every allocated cell of every young
    // block to re-derive the same verdict.
    //
    // TGC S4-f (2): return this minor's holes to the allocator. Deliberately
    // AFTER `clearYoungBlocks` above -- `publishHotBlock` refuses a block that
    // still carries `flag_young`, and every block a minor touched carries it
    // until that call. The doomed buckets are drained by the destruction slice inside
    // the sweep; since TGC S4-e there is no parked-free stack any more, so
    // that half of the major call site's precondition is vacuous (0).
    rt.gc.block_heap.publishCompletedHotBlocksSlice(
        0,
        gc.minor_hot_publish_superblock_budget,
    );
    rt.gc.generation.noteMinorPromotion(young_before -| reclaimed);
    if (phase_stats) {
        rt.gc.generation.stats.minor_promote_ns_total +|= profile.nowNanos() -| phase_started;
    }
    return reclaimed;
}

/// Bulk promotion: clear the young bit of every member of the young set.
///
/// TGC S4-h (2) removed this from the minor's production path -- the trace
/// retires block cells and the condemnation walks retire the list and
/// side-authority halves -- but two arms still need it: the diagnostic
/// producer (`verify_minor` / `minor_audit`), which only collects pointers,
/// and the `addressSetWhole` bail-out, which never reaches a sweep at all.
fn promoteYoungSurvivorsInBulk(rt: *JSRuntime) void {
    var survivors = rt.gc.objectIterator(.young);
    while (survivors.next()) |header| {
        header.meta().flags.young = false;
    }
}

/// Close a minor's young generation: retire the extent half, break the
/// young-block list and the young suffix, and zero the census and the
/// remembered set built from it.
///
/// TGC S4-h (2): this runs between the condemnation and the destruction slice,
/// so a destructor's own publication starts the NEXT young generation instead
/// of being stranded in a census that has already been zeroed.
fn closeYoungGeneration(rt: *JSRuntime) void {
    rt.gc.block_heap.retireYoungExtents();
    _ = rt.gc.block_heap.clearYoungBlocks();
    // TGC S3-c: a value symbol's body is only reachable from an old holder
    // over an atom id, which no minor traces, so the table roots it until it
    // is promoted -- which is exactly here.
    rt.atoms.retireYoungSymbolBodies();
    rt.gc.lists.resetYoungSuffix();
    rt.gc.retireGenerationalYoungSet();
    rt.gc.generation.commitMinorRetirement();
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
    // Intrusive carriers use the young suffix; non-block Objects use their
    // side authority and are filtered by the same young bit.
    var young_nonblock = rt.gc.objectIterator(.young_list);
    while (young_nonblock.next()) |h| {
        std.debug.assert(h.metaConst().flags.young);
        h.meta().flags.young = false;
    }
    // Block-population young bits: walk the young-block list, not the heap.
    // This also retires sweep-time allocations -- a block that received one
    // is on the list like any other.
    var young = rt.gc.objectIterator(.young_block);
    while (young.next()) |h| h.meta().flags.young = false;
    _ = rt.gc.block_heap.clearYoungBlocks();
    // Extents have no carrier to walk; their young enumeration is the
    // heap's own list. Survivors of the major's whole-table extent sweep
    // are promoted here, and the list is closed.
    rt.gc.block_heap.retireYoungExtents();
    // Same promotion point for the atom table's young symbol bodies (§S3-c).
    rt.atoms.retireYoungSymbolBodies();
    rt.gc.lists.resetYoungSuffix();
    rt.gc.retireGenerationalYoungSet();
}

/// Open an incremental major cycle (§8.6 initial mark, mutator stopped for
/// this call only).
///
/// Clears marks, seeds every precise and conservative root GREY and publishes
/// `major_marking_active`; the frontier drains at subsequent polls.
pub fn beginIncrementalCycle(rt: *JSRuntime, extra_roots: ?*const runtime_mod.ValueRootFrame, scan: runtime_mod.GCRootScan) CollectError!void {
    std.debug.assert(!rt.gc.incremental.markingActive());
    rt.gc.marking.queue.ensureCapacity(gc.Registry.markQueueAllocator());
    rt.gc.marking.stack.ensure(rt.gc.marking.queue.segmentPool());
    rt.gc.marking.stack.reset();
    rt.gc.marking.queue.reset();
    errdefer {
        rt.gc.marking.stack.reset();
        rt.gc.marking.queue.reset();
    }
    // Freeze the decision at major start. The settled account is the live
    // estimate that set this cycle's threshold; current allocation bytes also
    // include the garbage whose threshold crossing requested this major.

    var collector = try Collector.init(rt, extra_roots, scan);
    defer collector.deinit();
    collector.shade_to_queue = true;

    // Open the retirement transaction BEFORE anything can shade: the first
    // root seeded is already eligible to be retired by the trace.
    rt.gc.generation.beginMajorRetirement();
    // Seeding can fail (an allocation inside a root walk). Any exit from
    // here that does not reach `major_marking_active` leaves a transaction
    // open with part of the population possibly promoted, so it abandons.
    errdefer rt.gc.generation.abandonMajorRetirement();
    const t0 = profile.nowNanos();
    const remembered_clears_before = rt.gc.generation.stats.remembered_clears;
    collector.clearMarks();
    const t1 = profile.nowNanos();
    try collector.seedRoots();
    const t1b = profile.nowNanos();
    if (collector.conservative_on) try collector.seedConservativeRoots();
    try checkFrontierFailure(&rt.gc.marking.queue);
    const t2 = profile.nowNanos();
    rt.gc.incremental.stats.phase_begin_clear_ns +|= t1 -| t0;
    rt.gc.incremental.stats.phase_begin_precise_seed_ns +|= t1b -| t1;
    rt.gc.incremental.stats.phase_begin_conservative_seed_ns +|= t2 -| t1b;

    // Non-block young objects keep their exact list suffix throughout the
    // open major. The mandatory finish condemnation pass retires every list
    // survivor while detaching every dead node, so begin need not walk them at
    // all. Block survivors still retire as their trace loads them. No minor
    // can run inside this window (`minorsAllowed`), so the remembered index and
    // scalar count can be reset once seeding completes.
    const t_retire = profile.nowNanos();
    const young_blocks = rt.gc.block_heap.clearYoungBlocks();
    rt.gc.retireGenerationalYoungSet();
    const retire_ns = profile.nowNanos() -| t_retire;
    rt.gc.incremental.stats.phase_begin_retire_ns +|= retire_ns;
    rt.gc.incremental.stats.phase_retired_young_blocks +|= young_blocks;
    rt.gc.incremental.stats.phase_retired_remembered_sets +|=
        rt.gc.generation.stats.remembered_clears -| remembered_clears_before;

    rt.gc.setMajorMarkingActive(true);
}

/// Drain up to `budget_ns` of the grey frontier. Returns true when the
/// frontier is empty and the cycle is ready for its final remark.
pub fn incrementalMarkStep(rt: *JSRuntime, budget_ns: u64) CollectError!bool {
    std.debug.assert(rt.gc.incremental.markingActive());
    var collector = try Collector.init(rt, null, .declared_only);
    defer collector.deinit();
    collector.shade_to_queue = true;

    _ = try collector.drainSegmentedFrontier(budget_ns, true, false);
    rt.gc.incremental.stats.increments += 1;
    return rt.gc.marking.stack.len == 0 and rt.gc.marking.queue.isEmpty();
}

/// Final remark and sweep (§8.6, mutator stopped). Re-seeds every root --
/// stack slots are not barriered, so the conservative rescan is what catches
/// white objects referenced only from native frames -- drains what that and
/// the barrier produced, then runs the ordinary weak/sweep tail.
pub fn finishIncrementalCycle(rt: *JSRuntime, extra_roots: ?*const runtime_mod.ValueRootFrame, scan: runtime_mod.GCRootScan) CollectError!usize {
    std.debug.assert(rt.gc.incremental.markingActive());
    rt.gc.stats.collections += 1;
    const t_enter = profile.nowNanos();

    var collector = try Collector.init(rt, extra_roots, scan);
    defer collector.deinit();

    // Own the accumulator for this finish, the way `collectCycles` owns it for
    // a synchronous major. Without the reset the deduction below would charge
    // this pause with whatever the previous collection's walks cost.
    last_census_ns = 0;
    const t_remark = profile.nowNanos();
    rt.gc.incremental.stats.phase_finish_init_ns +|= t_remark -| t_enter;
    try collector.seedRoots();
    const t_remark_cons = profile.nowNanos();
    if (collector.conservative_on) try collector.seedConservativeRoots();
    rt.gc.incremental.stats.phase_finish_conservative_seed_ns +|= profile.nowNanos() -| t_remark_cons;
    try collector.drain();
    _ = try collector.drainBarrierQueue();
    try collector.ephemeronFixedPoint();
    recordFinalMarkFootprint(rt);

    // Roots-diag oracle: re-derive reachability from a fresh mark epoch and
    // compare the exact would-be-doomed set. Keep the set collection-local:
    // Runtime allocator lifetimes may not be mixed.
    var full_reachable: ?FullReachable = null;
    defer if (full_reachable) |*reachable| reachable.deinit();
    if (comptime gc.roots_diag_enabled) {
        if (gc.verify_major_all) {
            full_reachable = try computeFullReachable(rt, scan);
            if (full_reachable) |*reachable| try verifyFullCondemnation(rt, reachable);
        }
    }

    // Marking is over before anything is freed (§8.6 step 12 before 13).
    rt.gc.setMajorMarkingActive(false);
    rt.gc.assertFrontierDrainedBeforeReclaim();

    const t_weak = profile.nowNanos();
    collector.processWeak();
    const t_sweep = profile.nowNanos();
    if (!rt.gc.addressSetWhole(rt)) {
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
    rt.gc.assertFrontierAllowsReclaimKind(.object);
    const snap = rt.gc.block_heap.snapshotAllDoomed(rt.gc.block_heap.mark_epoch);
    // TGC S4-d spec 2.4: one debit for every corpse the sweep will take
    // from the bitmap. Those cells never reach a per-cell free path.
    rt.memory.debitBlockBytes(snap.bitmap_bytes);
    condemned += snap.count;
    // Ledger parity: the account carries object sizes, not cell sizes.
    doomed_bytes +|= snap.bytes -| (snap.count * gc.metadata_prefix_size);
    // Unmarked string extents are dead at finish and referenced by
    // nothing; free them now (rare, so the pause cost is negligible)
    // rather than teaching the sliced morgue a table-backed kind.
    condemned += string_mod.sweepExtents(rt);
    var sink = FinishCondemnSink{};
    condemned += condemnListSweep(rt, &sink, false);
    doomed_bytes +|= sink.doomed_bytes;
    // Reuse the pacing contract's settled-live estimate. `doomed_bytes` has
    // already converted block cell bytes to MemoryAccount units above, so this
    // subtraction does not mix physical cells with logical payload sizes.
    rt.gc.incremental.last_settled_live_bytes = rt.memory.allocated_bytes -| doomed_bytes;
    // Every pre-existing list survivor was retired by tracing/condemnation.
    // From here on a non-null anchor belongs to a post-mark publication, so a
    // forward walk is the exact replacement for the old header.prev tail walk.
    rt.gc.lists.resetYoungSuffix();
    rt.gc.morgue.kind_pass = 0;
    rt.gc.morgue.cursor = null;
    rt.gc.morgue.destroyed = 0;
    rt.gc.morgue.bytes = doomed_bytes;
    rt.gc.incremental.stats.doomed_condemned_headers +|= condemned;
    rt.gc.morgue.pending = condemned != 0;
    if (rt.gc.block_heap.doomed_blocks != null) rt.gc.morgue.pending = true;
    if (!rt.gc.morgue.pending) rt.gc.incremental.stats.cycles_completed += 1;
    // TGC S3 §2.4. The verdict and its application must share one pause: see
    // `sweepAtomTable`. This used to be deferred to the point the morgue
    // empties, on the pre-flip reasoning that a condemned holder still holds
    // its property-key REFS until its destructor runs. Refs are gone -- the
    // sweep reads mark stamps, which a corpse cannot set -- and the delay cost
    // a mutator window in which a retired-but-still-indexed atom could be
    // re-interned into a live holder.
    sweepAtomTable(rt);
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
    rt.gc.incremental.stats.phase_finish_remark_ns +|= raw_remark_ns -| census_ns;
    rt.gc.incremental.stats.phase_finish_weak_ns +|= t_sweep -| t_weak;
    rt.gc.incremental.stats.phase_finish_condemn_ns +|= t_end -| t_sweep;

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
    // Everything after condemnation: the sweep-model close, the young-state
    // retirement walk and (safety builds only) the invariant sweep. Timed so
    // the subphase row reconciles with the STW `finish` row instead of
    // leaving a residual nobody can name.
    rt.gc.incremental.stats.phase_finish_tail_ns +|= profile.nowNanos() -| t_end;
    return condemned;
}

/// Destruction order for the morgue (qjs `gc_free_cycles`'s five passes),
/// spelled as a phase index so a bounded slice
/// can resume where its budget ran out. Objects first; realms, modules and
/// function bytecode after; cells and shapes last, because earlier
/// destructors still read them.
const doomed_phase_kinds = [_]gc.GcKind{ .object, .realm_context, .module, .function_bytecode, .var_ref, .big_int };

/// Destroy up to `budget_ns` of the morgue. Returns true when it is empty.
///
/// Runs under `.tracer_destroy`. TGC S4-e: a destructor releases its own
/// storage, so there is no second pass to stretch across polls; the morgue is
/// stable between slices because everything in it is unreachable,
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

fn morgueIsEmpty(rt: *const JSRuntime) bool {
    if (rt.gc.morgue.cursor != null) return false;
    if (rt.gc.block_heap.doomed_blocks != null) return false;
    if (rt.gc.nonblock_objects) |authority| {
        if (authority.doomed.items.len != 0) return false;
    }
    for (&rt.gc.morgue.by_kind) |*bucket| {
        if (!gc.listEmpty(bucket)) return false;
    }
    return true;
}

/// Read-only endpoint/settled census for the fixed-work gate. These counts
/// deliberately come from the representations that keep the morgue open,
/// rather than from lifetime collection counters: the gate needs to
/// distinguish one unserved destruction slice from a closed transaction that
/// accidentally retained state.
pub const DoomedStateSnapshot = struct {
    pending: bool,
    nonempty_buckets: usize,
    bucket_headers: usize,
    cursor_present: bool,
    doomed_blocks: usize,
    deferred_finalizers: usize,
    active_finalizer: bool,
};

pub fn doomedStateSnapshot(rt: *const JSRuntime) DoomedStateSnapshot {
    const doomed_nonblock_objects = if (rt.gc.nonblock_objects) |authority| authority.doomed.items.len else 0;
    var nonempty_buckets: usize = if (doomed_nonblock_objects != 0) 1 else 0;
    var bucket_headers: usize = doomed_nonblock_objects;
    for (&rt.gc.morgue.by_kind) |*bucket| {
        if (!gc.listEmpty(bucket)) nonempty_buckets += 1;
        var header = bucket.sentinel.next_non_object;
        while (header) |current| {
            if (current == &bucket.sentinel) break;
            bucket_headers += 1;
            header = current.nextNonObject();
        }
    }

    var doomed_blocks: usize = 0;
    var block = rt.gc.block_heap.doomed_blocks;
    while (block) |current| {
        doomed_blocks += 1;
        const link = current.doomed_link;
        block = if (link <= 1) null else @ptrFromInt(link);
    }

    return .{
        .pending = rt.gc.morgue.pending,
        .nonempty_buckets = nonempty_buckets,
        .bucket_headers = bucket_headers,
        .cursor_present = rt.gc.morgue.cursor != null,
        .doomed_blocks = doomed_blocks,
        .deferred_finalizers = rt.deferred_class_payload_finalizers.len,
        .active_finalizer = rt.active_deferred_class_payload_finalizer != null,
    };
}

/// Cross-lane publication contract for deferred plugin payload roots. Block
/// draining may publish a partial block before the global doomed transaction
/// closes, but no cell reachable from a live-wrapper, queued-job, or active-job
/// payload root may be among that block's released intervals. Call this
/// immediately before every such publication point; d/f's clustered drain and
/// hot-block publication paths share this seam.
fn auditDeferredPayloadRootsBeforeBlockPublication(rt: *JSRuntime) void {
    if (!gc.invariantChecksEnabled()) return;
    requireInvariant(rt.verifyDeferredClassPayloadRootLiveness(), "DEFERRED PAYLOAD ROOT", "deferred payload root entered doomed or released storage");
}

/// The sliced-destruction exit contract. The morgue gate is the only thing
/// preventing a fresh trace from observing resource-stripped or parked
/// objects, so a false gate must mean every representation of that state is
/// empty. Payload-root liveness is checked even while the transaction stays
/// open, because partial blocks may already have been published by then.
pub fn auditDoomedExitInvariant(rt: *const JSRuntime) void {
    if (!gc.invariantChecksEnabled()) return;
    auditDeferredPayloadRootsBeforeBlockPublication(@constCast(rt));
    if (rt.gc.morgue.pending) return;
    if (!morgueIsEmpty(rt)) @panic("gc: closed doomed state retains morgue entries");
}

/// A new condemnation may reuse every morgue field. Catch a caller that
/// starts one before the previous destruction transaction has really closed.
fn assertMorgueEmptyBeforeCondemnation(rt: *const JSRuntime) void {
    std.debug.assert(!rt.gc.morgue.pending);
    std.debug.assert(morgueIsEmpty(rt));
}

/// Move a condemned non-object carrier onto its kind's morgue bucket.
///
/// TGC S5-b: every condemnation path -- both STW sweeps and the incremental
/// finish -- publishes here, so the destruction slice has exactly one input
/// representation. Objects never arrive: block cells are owned by the doomed
/// bitmap and non-block Objects by the side authority's doomed lane.
inline fn condemnIntoBucket(rt: *JSRuntime, header: *gc.Header) void {
    const kind = header.metaConst().flags.kind;
    std.debug.assert(kind != .object);
    gc.listAddTailTraversalOwned(&rt.gc.morgue.by_kind[@intFromEnum(kind)], header);
}

/// The condemnation half of every sweep: detach the unmarked, unpinned
/// carriers onto the morgue and retire the survivors' young bits.
///
/// TGC S5-b: this was written three times -- the synchronous major's whole
/// list, the minor's young suffix, and the incremental finish's pause -- with
/// the same four-case body (marked / pinned / dead list carrier / dead
/// side-authority Object) and three different spellings of it. What actually
/// differed is two axes, and they are the two parameters here:
///
///   `young_only` picks the range. The minor walks the young suffix from
///   `young_head`, whose predecessor was captured at the first publication, so
///   the detach stays O(young) instead of searching from the head per corpse;
///   the majors walk the whole list from the sentinel. The side authority is
///   unordered rather than a suffix in both cases, so its young half is a
///   filter on the young bit rather than a range.
///
///   `sink` is the per-corpse extra work. The finish pause owes the pacing
///   contract a byte total and owes the shape table an immediate delisting
///   (the mutator runs before the destruction slices); the synchronous sweeps
///   destroy in the same pause and owe neither.
///
/// The survivor arms retire the young bit rather than leaving it to a bulk
/// pass: TGC S4-h (2) made the trace retire block cells as it loads them, but
/// a LIST carrier cannot be retired by the trace without breaking
/// `young_head`'s exact-suffix invariant while the suffix is still being
/// walked -- so it is cleared here, where the walk is already O(young) and the
/// header line is already loaded. A pinned-but-unmarked survivor needs it just
/// as much: it leaves the suffix when `young_head` resets, and a stale young
/// bit would make the barrier remember its owner on every store, forever.
///
/// Returns the number of headers condemned.
fn condemnListSweep(rt: *JSRuntime, sink: anytype, young_only: bool) usize {
    var condemned: usize = 0;

    // List carriers are singly linked in trace. Walk them with an explicit
    // predecessor so every condemnation is an O(1) splice.
    const list_head: ?*gc.Header = if (young_only)
        rt.gc.lists.young_head
    else
        rt.gc.lists.objects.sentinel.next_non_object;
    if (list_head) |head| {
        var previous: *gc.Header = if (young_only)
            rt.gc.lists.young_predecessor orelse unreachable
        else
            &rt.gc.lists.objects.sentinel;
        var cursor: ?*gc.Header = head;
        while (cursor) |header| {
            if (header == &rt.gc.lists.objects.sentinel) break;
            const next = header.nextNonObject();
            // The mark STAYS on a survivor. §8.2's sticky rule is
            // `allocated && marked` is old, and that mark is what tells the
            // next minor's `shadeExact` to stop at it -- clearing here made
            // the first minor after every major find the whole heap unmarked
            // and re-trace the entire live set from the roots (~29 ms per
            // probe minor on splay, against a 1 ms target). The next major's
            // `clearMarks` is the clearer.
            if (rt.gc.headerMarked(header) or rt.gc.headerIsPinned(header)) {
                header.meta().flags.young = false;
                previous = header;
                cursor = next;
                continue;
            }
            sink.note(rt, header);
            rt.gc.detachCycleCandidateAfter(previous, header);
            condemnIntoBucket(rt, header);
            condemned += 1;
            cursor = next;
        }
    }

    // Non-block Objects have no live-list node. Their unordered side authority
    // is consumed in place: condemnation swap-removes, so the replacement at
    // this index must be examined before advancing.
    if (rt.gc.nonblock_objects) |authority| {
        var object_index: usize = 0;
        while (object_index < authority.items.items.len) {
            const header = authority.items.items[object_index];
            if (young_only and !header.metaConst().flags.young) {
                object_index += 1;
                continue;
            }
            if (rt.gc.headerMarked(header) or rt.gc.headerIsPinned(header)) {
                header.meta().flags.young = false;
                object_index += 1;
                continue;
            }
            sink.note(rt, header);
            rt.gc.condemnNonBlockObject(header);
            condemned += 1;
        }
    }
    return condemned;
}

/// The sink of a sweep that destroys in the same pause: nothing is owed
/// between the condemnation and the teardown, so there is no extra per-corpse
/// work at all.
const SamePauseSink = struct {
    fn note(_: *const @This(), _: *JSRuntime, _: *gc.Header) void {}
};

/// The sink of the incremental finish: the mutator runs between this
/// condemnation and the destruction slices, so the byte total the pacing
/// contract reads and the shape table the mutator consults must both be
/// settled here.
const FinishCondemnSink = struct {
    doomed_bytes: usize = 0,

    fn note(self: *@This(), rt: *JSRuntime, header: *gc.Header) void {
        self.doomed_bytes +|= gc.Registry.heapByteSizeFromHeader(rt, header);
        // A condemned shape must leave the transition table NOW, not at its
        // destructor: a table that still serves the corpse lets a live object
        // adopt a shape that is already scheduled to be freed. Realms and
        // modules sit on membership lists that only collections walk, and
        // those are gated while the morgue is open; the shape table is the one
        // engine-global structure the MUTATOR consults.
        if (header.metaConst().flags.kind == .shape) {
            rt.shapes.delistCondemnedShape(header);
        }
    }
};

/// Outcome of one destruction slice. `morgue_empty` is the only thing the
/// slice can report that its caller cannot re-derive cheaply: the budget may
/// have run out mid-phase, and the resume state lives in the registry.
const CondemnedSliceResult = struct {
    destroyed: usize,
    morgue_empty: bool,
};

/// Ordered teardown of the morgue, in one bounded slice.
///
/// TGC S5-b: the single destruction authority. The STW sweeps and the
/// incremental morgue drain used to be two transcriptions of the same five
/// kind passes -- one walking `tmp_obj_list` with a `residual_kinds` bitmap
/// prescan, one walking the `doomed_by_kind` buckets with a budget -- and
/// they had already drifted (`sweep_current` was published for a different
/// subset of kinds on each side). Condemnation now feeds the buckets on
/// every path, and a `budget_ns` of `maxInt` is exactly the old STW
/// semantics: no clock check can trip, so the slice runs the morgue to
/// empty.
///
/// The order is load-bearing (qjs `gc_free_cycles`): objects first, then
/// realms, modules and function bytecode, and only then the cells and shapes
/// whose contents those releases were still reading. Destroying under
/// `.tracer_destroy` parks every struct free, so a destructor dereferencing a
/// sibling already torn down in an earlier pass reads stripped-but-allocated
/// memory rather than freed memory.
///
/// Every condemned kind is freed, not just `.object`: the minor used to
/// condemn and destroy only objects, so a young var_ref that was equally
/// unreachable survived while the object it held was freed. The condemned set
/// has to be closed under "reachable only from other condemned nodes", and the
/// only way to keep it closed is to free every kind the trace condemned.
///
/// `sweep_string_extents` runs the whole-table extent sweep after the block
/// corpses: only a full major trace can prove an OLD extent dead, so the
/// synchronous major asks for it and the minor (which sweeps young extents
/// from `Heap.young_extents`) and the incremental drain (which swept them in
/// the finish pause) do not.
fn destroyCondemnedSlice(rt: *JSRuntime, budget_ns: u64, sweep_string_extents: bool) CondemnedSliceResult {
    const started = profile.nowNanos();
    var destroyed: usize = 0;
    var since_clock: usize = 0;

    const old_phase = rt.gc.hot.phase;
    rt.gc.hot.phase = .tracer_destroy;
    defer rt.gc.hot.phase = old_phase;

    // Block corpses first: they are all plain objects, which is exactly the
    // kind order's first pass, so draining them before the list phases keeps
    // "objects before realms before shapes" intact -- standalone objects on
    // the side authority still get their turn in pass 0 below.
    while (rt.gc.block_heap.doomed_blocks) |block| {
        // Geometry is immutable until `resetBlock`. Keep the base/stride
        // across callbacks instead of reloading both fields for every
        // corpse.
        const cells_base = @intFromPtr(block) + block.cells_offset + gc.metadata_prefix_size;
        const cell_size: usize = block.cell_size;
        // TGC S4-d spec 2.4: only `doomed & needs_finalizer` reaches a
        // destructor. Everything else -- plain objects, storage cells,
        // unbound string bodies -- is left in the doomed bitmap for the
        // word-arithmetic reclaim below, which never reads its header.
        while (block.takeDoomedFinalizerCell()) |index| {
            const header: *gc.Header = @ptrFromInt(cells_base + @as(usize, index) * cell_size);
            // The alloc bit and heap-accounted stamp remain live through
            // every payload callback, so containsHeader's block iterator
            // already publishes this object. Standalone/list objects need
            // sweep_current below because condemnation delisted them.
            switch (header.meta().flags.kind) {
                .object => Object.destroyFromHeader(rt, header),
                // String-family cells (TGC S2) share the block heap; the
                // stamped ones are the bodies bound to a dynamic atom, and
                // the string side performs that handshake.
                .string, .rope, .string_buffer => string_mod.destroyCellFromHeader(rt, header),
                // A bare storage cell never owes destructor work, so it
                // can never carry the bit.
                else => unreachable,
            }
            destroyed += 1;
            since_clock += 1;
            if (since_clock == destroy_clock_cadence) {
                since_clock = 0;
                if (profile.nowNanos() -| started >= budget_ns) {
                    return .{ .destroyed = destroyed, .morgue_empty = false };
                }
            }
        }
        // The destructor set is drained, so the rest of this block is
        // bitmap work that cannot be interrupted. Close the block out of
        // the doomed list FIRST: `reclaimDoomedCells` may hand an emptied
        // block to the free-block list, and a free-listed block must not
        // carry a live `doomed_link`.
        const link = block.doomed_link;
        block.doomed_link = 0;
        rt.gc.block_heap.doomed_blocks = if (link <= 1) null else @ptrFromInt(link);
        destroyed += rt.gc.reclaimDoomedBlock(block);
        // This block's doomed bitmap is fully consumed, so its alloc
        // bitmap and `allocated_count` are canonical again -- a claim
        // about work this loop just did, not a tautology. Name the
        // offending block here rather than waiting for the next
        // whole-heap `AllocCountMismatch`.
        if (gc.invariantChecksEnabled()) {
            BlockHeapMod.Heap.verifyBlockAllocCount(block) catch |err| {
                gc_audit_print.print(&.{
                    .{ .text = "gc: DOOMED RECLAIM AUDIT: " },
                    .{ .text = @errorName(err) },
                    .{ .text = " block=0x" },
                    .{ .hex = @intFromPtr(block) },
                    .{ .text = " allocated_count=" },
                    .{ .dec = block.allocated_count },
                    .{ .text = "\n" },
                });
                @panic("the doomed reclaim left a block's alloc bitmap and count disagreeing");
            };
        }
    }

    // Whole-table extent sweep: only a full major trace can prove an OLD
    // extent dead. Unbudgeted by construction -- the only caller that asks
    // for it is the synchronous major, whose budget cannot trip.
    if (sweep_string_extents) destroyed += string_mod.sweepExtents(rt);

    while (rt.gc.morgue.kind_pass < doomed_phase_kinds.len + 1) {
        const final_pass = rt.gc.morgue.kind_pass == doomed_phase_kinds.len;
        const phase_kind: gc.GcKind = if (final_pass) .shape else doomed_phase_kinds[rt.gc.morgue.kind_pass];
        if (phase_kind == .object) {
            if (rt.gc.nonblock_objects) |authority| {
                while (authority.doomed.pop()) |h| {
                    rt.gc.lists.sweep_current = h;
                    Object.destroyFromHeader(rt, h);
                    rt.gc.lists.sweep_current = null;
                    destroyed += 1;
                    since_clock += 1;
                    if (since_clock == destroy_clock_cadence) {
                        since_clock = 0;
                        if (profile.nowNanos() -| started >= budget_ns) {
                            return .{ .destroyed = destroyed, .morgue_empty = false };
                        }
                    }
                }
            }
            rt.gc.morgue.kind_pass += 1;
            rt.gc.morgue.cursor = null;
            continue;
        }
        const bucket = &rt.gc.morgue.by_kind[@intFromEnum(phase_kind)];
        var cursor = rt.gc.morgue.cursor orelse bucket.sentinel.next_non_object;
        while (cursor) |h| {
            if (h == &bucket.sentinel) break;
            const next = h.nextNonObject();
            const kind = h.meta().flags.kind;
            // The bucket only holds this phase's kind, so the test is an
            // assertion rather than a filter now.
            const wanted = kind == phase_kind;
            if (wanted) {
                // Each kind owns one bucket and destruction consumes it from
                // the head, including after a budgeted resume.
                gc.listDelAfterTraversalOwned(bucket, &bucket.sentinel, h);
                rt.gc.lists.sweep_current = h;
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
                    .big_int => {
                        rt.gc.unlinkObjectWithBytes(h, gc.Registry.heapByteSizeFromHeader(rt, h));
                        bigint_mod.BigInt.destroyFromHeader(rt, h);
                    },
                    .shape => {
                        if (!h.meta().flags.finalizing) rt.shapes.destroyFromHeader(h);
                    },
                    else => unreachable,
                }
                rt.gc.lists.sweep_current = null;
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
                    rt.gc.morgue.cursor = next;
                    return .{ .destroyed = destroyed, .morgue_empty = false };
                }
            }
            cursor = next;
        }
        rt.gc.morgue.kind_pass += 1;
        rt.gc.morgue.cursor = null;
    }

    return .{ .destroyed = destroyed, .morgue_empty = true };
}

/// Run the STW twin of a destruction slice: the whole morgue, no budget, from
/// a fresh phase cursor. Both synchronous sweeps condemn into the same buckets
/// as the incremental finish, so the only difference left is the absence of a
/// resume state and of the sliced transaction's bookkeeping.
fn destroyCondemnedWhole(rt: *JSRuntime, sweep_string_extents: bool) usize {
    rt.gc.morgue.kind_pass = 0;
    rt.gc.morgue.cursor = null;
    const result = destroyCondemnedSlice(rt, std.math.maxInt(u64), sweep_string_extents);
    std.debug.assert(result.morgue_empty);
    return result.destroyed;
}

/// Destroy up to `budget_ns` of the morgue. Returns the number destroyed.
///
/// Runs under `.tracer_destroy`. TGC S4-e: a destructor releases its own
/// storage, so there is no second pass to stretch across polls; the morgue is
/// stable between slices because everything in it is unreachable,
/// weak-cleared, and invisible to collections (which are gated while the
/// morgue is open).
pub fn destroyDoomedSlice(rt: *JSRuntime, budget_ns: u64) usize {
    std.debug.assert(rt.gc.morgue.pending);
    const result = destroyCondemnedSlice(rt, budget_ns, false);
    rt.gc.morgue.destroyed += result.destroyed;
    rt.gc.incremental.stats.doomed_destroyed_objects +|= result.destroyed;
    if (!result.morgue_empty) return result.destroyed;

    // TGC S4-e: a deferred class payload finalizer still retains JSValues into
    // this condemnation, so the transaction stays open until those callbacks
    // have run. Everything else that used to hold it open (the parked-free
    // drain) is gone.
    if (!rt.hasPendingDeferredClassPayloadFinalizers()) {
        // Every destructor has run and released its own storage, so block
        // alloc bitmaps are canonical. This transaction boundary, not
        // per-block doomed-list removal, is the first sound point to publish
        // partial blocks for interval reuse.
        auditDeferredPayloadRootsBeforeBlockPublication(rt);
        rt.gc.block_heap.publishCompletedHotBlocks();
        rt.gc.morgue.pending = false;
        rt.gc.morgue.cursor = null;
        rt.gc.incremental.stats.cycles_completed += 1;
        // TGC S3 §2.4: the atom sweep is NOT here. It belongs to the pause that
        // took the verdict (`finishIncrementalCycle`); running it after the
        // mutator has had a whole destruction run's worth of polls lets a
        // re-interned id be retired under a live holder. See `sweepAtomTable`.
    }
    auditDoomedExitInvariant(rt);
    return result.destroyed;
}

/// Complete any pending sliced destruction synchronously. Explicit
/// collections and teardown call this: destruction is irreversible, so unlike
/// an open marking cycle it cannot be aborted, only finished.
pub fn finishPendingDestruction(rt: *JSRuntime) void {
    while (rt.gc.morgue.pending) {
        _ = destroyDoomedSlice(rt, std.math.maxInt(u64));
        // Payload jobs may retain JSValues into this condemnation. Their
        // callbacks therefore run after every resource destructor but before
        // the parked structs are allowed to disappear. The synchronous entry
        // promises completion, so it also owns completing this prerequisite.
        if (rt.hasPendingDeferredClassPayloadFinalizers()) {
            std.debug.assert(rt.gc.hot.phase == .none);
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

/// Drain the incremental barrier queue the way the final remark does, for
/// tests that construct a mutator interleaving between marking phases.
/// Returns the number of grey entries traced.
pub fn remarkBarrierQueueForTest(rt: *JSRuntime) CollectError!usize {
    if (!builtin.is_test) @compileError("test-only helper");
    rt.gc.marking.stack.ensure(rt.gc.marking.queue.segmentPool());
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
fn auditLiveObjectsResolve(rt: *JSRuntime) usize {
    var missing: usize = 0;
    var reported: usize = 0;
    var it = rt.gc.objectIterator(.all);
    while (it.next()) |header| {
        if (rt.gc.address_registry.containsHeader(header)) continue;
        missing += 1;
        if (reported < 8) {
            reported += 1;
            gc_audit_print.print(&.{
                .{ .text = "gc: ARENA AUDIT live object at 0x" },
                .{ .hex = @intFromPtr(header) },
                .{ .text = " (kind ." },
                .{ .text = @tagName(header.metaConst().flags.kind) },
                .{ .text = ") does not resolve\n" },
            });
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
    /// Minor mode: `seedRoots` adds the atom table's not-yet-promoted symbol
    /// bodies (`AtomTable.young_symbol_atoms`). A major must NOT take those
    /// as roots -- it is the collection that is entitled to retire a symbol
    /// whose last holder died in the cycle that created it.
    minor_mode: bool = false,
    /// `computeFullReachable`'s probe: walk the atom edges for their shading
    /// effect but write nothing into the table. Its epoch is not the cycle's,
    /// so a stamp here would destroy the verdict the probe exists to check
    /// (`AtomTable.atomEdgeBodyWithoutStamp`).
    atom_stamps_frozen: bool = false,

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
                !rt.gc.scheduler.host_quiescent
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
        try self.seedRoots();
        try self.drain();
        if (detailed_reports) {
            const t = censusStart();
            self.exact_mark_count = self.countMarked();
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
        // Sweeping requires that every live object be reachable from a
        // conservative candidate, which requires every owned range to be registered.
        // If one is not, mark and stop: the marks are still correct, nothing is
        // reclaimed this round, and the objects stay alive until the address
        // set can be repaired. Leaking a round is recoverable; freeing a live
        // object is not.
        if (!self.rt.gc.addressSetWhole(self.rt)) {
            self.report.skipped_sweep_incomplete_arenas = true;
            return 0;
        }
        return self.sweepUnmarked();
    }

    /// Whole-heap unmark: one epoch bump for block bitmaps and one for the
    /// fixed-offset epoch shared by every non-block trace carrier. Restore
    /// semantics for the VERIFY_MINOR probe hold: re-marking a saved set under
    /// the new epochs means exactly "marked" again.
    fn clearMarks(self: *Collector) void {
        self.rt.gc.block_heap.beginMajor();
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
    inline fn clearYoungMarks(self: *Collector) void {
        var iterator = self.rt.gc.objectIterator(.young_list);
        while (iterator.next()) |header| {
            self.rt.gc.setHeaderUnmarked(header);
        }
        self.rt.gc.block_heap.clearYoungBlockMarksStw();
        self.rt.gc.block_heap.clearYoungExtentMarksStw();
    }

    fn countMarked(self: *Collector) usize {
        var n: usize = 0;
        var iterator = self.rt.gc.objectIterator(.all);
        while (iterator.next()) |header| {
            if (self.rt.gc.headerMarked(header)) n += 1;
        }
        return n;
    }

    fn countMarkedYoung(self: *Collector) usize {
        var n: usize = 0;
        var iterator = self.rt.gc.objectIterator(.young);
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
        // and it is complete: an unpublished object is not on `lists.objects`,
        // so no sweep can condemn it, and its edges are covered by the
        // published-grey push the moment registration completes -- or it
        // dies unconstructed, in which case there was nothing to keep.
        if (!header.meta().alloc_info.heap_accounted) return;
        // A condemned corpse awaiting its destruction slice. No precise root
        // can name it -- the remark proved it unreachable and processWeak
        // cleared its identities -- so the only way here is conservative
        // stack residue resolving a parked slab block that still reads
        // `heap_accounted`. Shading it would trace freed payloads.
        // `detachCycleCandidate` already writes the stamp; this is the read.
        if (gc.headerCondemned(header)) return;
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
            if (!gc.frontierEpochSafe(kind)) {
                if (kind != .shape and kind != .realm_context)
                    @panic("gc: FRONTIER SAFETY: non-tracing kind reached shade");
                {
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
            }
            // Owner-private segments first. If local growth hits OOM, route
            // this address to the shared segmented chain; if that allocation
            // also fails, fail the cycle closed before sweep.
            const frontier_header = self.rt.gc.frontierSafeHeaderAfterMarkClaim(header);
            if (!self.rt.gc.marking.stack.push(frontier_header)) {
                if (!self.rt.gc.marking.queue.push(frontier_header)) {
                    self.err = error.OutOfMemory;
                }
            }
            return;
        }
        self.work.append(self.allocator(), header) catch |err| {
            self.err = err;
        };
    }

    pub fn visitValue(self: *Collector, val: *JSValue) void {
        if (val.cycleMarkHeader()) |header| self.shadeExact(header);
    }

    pub fn visitObject(self: *Collector, obj_ptr: *?*Object) void {
        if (obj_ptr.*) |obj| self.shadeExact(obj.gcHeader());
    }

    pub fn visitShape(self: *Collector, shape_ref: *shape.Shape) void {
        if (self.rt.gc.headerMarkedKnownNonBlock(&shape_ref.header)) return;
        self.shadeExact(&shape_ref.header);
    }

    pub fn visitRealm(self: *Collector, ctx_ptr: *?*context_mod.RealmContext) void {
        if (ctx_ptr.*) |ctx| self.shadeExact(&ctx.header);
    }

    pub fn visitModule(self: *Collector, record: *module_mod.ModuleRecord) void {
        self.shadeExact(&record.header);
    }

    /// TGC S4 spec 2.2 / S4-g (2): an owner's edge to a bare storage cell.
    ///
    /// LEAF SHADE. The cell has no out-edges -- `traceHeaderEdges` returns
    /// immediately for every kind `kindIsOwnedStorageCell` admits -- so the
    /// frontier round trip `shadeExact` used to buy (push, pop, re-load the
    /// metadata line, dispatch on kind, return, retire) bought nothing. What
    /// the pop actually did is inlined here: claim the mark and retire the
    /// young bit. Nothing else about the cell is ever observed by the trace.
    ///
    /// S4-b/S4-c put one or two of these cells behind EVERY object with
    /// out-of-line properties or a payload, which made this edge 30% of
    /// `shadeExact` on splay (5.1% of the whole run, split 17.3/13.1 between
    /// incremental major marking and minors -- the baseline S2-i tree, whose
    /// only storage cell was the rope tail buffer, spends 0.0% here).
    ///
    /// The guards are `shadeExact`'s, in its order and for its reasons:
    /// already-marked, UNPUBLISHED (a container can name a cell whose owner
    /// is still under construction) and the condemned-corpse bit.
    pub fn storageCell(self: *Collector, header: *gc.Header) void {
        if (self.err != null) return;
        if (self.rt.gc.headerMarked(header)) return;
        if (!header.meta().alloc_info.heap_accounted) return;
        if (gc.headerCondemned(header)) return;
        // The leaf claim is only sound for a kind `traceHeaderEdges` returns
        // from. An extent-carried storage cell is admitted too: its mark goes
        // to the extent table and `retireTracedYoung` skips it, which is what
        // the frontier route did as well.
        if (comptime std.debug.runtime_safety) {
            std.debug.assert(gc.kindIsOwnedStorageCell(header.metaConst().flags.kind));
            std.debug.assert(gc.frontierEpochSafe(header.metaConst().flags.kind));
        }
        self.rt.gc.setHeaderMarked(header);
        // The whole of `traceHeader` for a leaf: no edges, then the
        // trace-coupled retirement. A no-op outside a major's retirement
        // transaction, exactly as on the frontier route.
        self.rt.gc.retireTracedYoung(header);
    }

    /// TGC S3 §2.2. An atom id is not a heap pointer: the edge stamps the
    /// table entry with this major's epoch, and only a VALUE SYMBOL's body
    /// rides along (the id holder must be able to hand the JSValue back out).
    /// A string atom's `str` is a droppable cache and is left to the mark.
    pub fn visitAtom(self: *Collector, id: atom_mod.Atom) void {
        if (self.atom_stamps_frozen) {
            // Diagnostic probe: shade the body the edge keeps alive, leave the
            // entry alone (`AtomTable.atomEdgeBodyWithoutStamp`).
            if (self.rt.atoms.atomEdgeBodyWithoutStamp(id)) |body| self.shadeExact(body.header());
            return;
        }
        const epoch = self.rt.gc.block_heap.mark_epoch;
        if (self.rt.atoms.markAtomAtEpoch(id, epoch)) |body| self.shadeExact(body.header());
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
        for (self.rt.gc.pins.entries) |entry| {
            // Detached generator shells have a complete payload but no Shape
            // until parameter initialization resolves the final prototype.
            // shade() correctly rejects unpublished objects; mark the block
            // cell directly and trace only its initialized payload.
            if (self.rt.gc.pins.entryIsConstructionRoot(entry)) {
                self.rt.gc.setHeaderMarked(entry.header);
                const object = Object.fromHeader(entry.header);
                try object.traceDetachedGeneratorShellEdges(self);
                // A mark claim outside the frontier owes the same retirement a
                // frontier pop does. Guarded on publication because that is
                // what this arm exists for: an UNPUBLISHED shell is not young
                // yet and is not in any young structure, so it has nothing to
                // retire, and `retireTracedYoung` asserts on `heap_accounted`.
                if (entry.header.metaConst().alloc_info.heap_accounted) {
                    self.rt.gc.retireTracedYoung(entry.header);
                }
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

            fn visitAtom(context: *anyopaque, id: atom_mod.Atom) runtime_mod.RootTraceError!void {
                const adaptor: *@This() = @ptrCast(@alignCast(context));
                adaptor.collector.visitAtom(id);
                if (adaptor.collector.err) |err| return err;
            }
        };
        var adaptor = Adaptor{ .collector = self };
        var visitor = runtime_mod.RootVisitor{
            .context = @ptrCast(&adaptor),
            .visit_value = Adaptor.visitValue,
            .visit_object = Adaptor.visitObject,
            .visit_header = Adaptor.visitHeader,
            .visit_atom = Adaptor.visitAtom,
        };
        try self.rt.traceActiveRoots(&visitor);
        // TGC S3-c: the minor's extra root set. A young symbol body's only
        // holder can be an OLD shape naming it by atom id -- an edge no minor
        // traces and no barrier records.
        if (self.minor_mode) try self.rt.atoms.traceYoungSymbolBodies(&visitor);
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

    /// R3 census variant of `shadeConservativeCandidate`: same filters and
    /// the same `shadeExact`, plus a record when the shade is what marked the
    /// header. Used only by `computeFullReachable`'s conservative arm, where
    /// the precise trace has already run to a fixed point.
    fn recordConservativeCandidate(context: *anyopaque, header: *gc.Header) void {
        const self: *Collector = @ptrCast(@alignCast(context));
        if (self.err != null) return;
        const addr = @intFromPtr(header);
        if (addr < 4096 or !std.mem.isAligned(addr, @alignOf(gc.Header))) return;
        const was_marked = self.rt.gc.headerMarked(header);
        self.shadeExact(header);
        if (comptime gc.roots_diag_enabled) {
            if (!was_marked and self.rt.gc.headerMarked(header)) {
                conservative.noteDirect(self.rt, header, conservative.diagCurrentWord());
            }
        }
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

    /// Trace everything the marking barrier shaded grey. Shared segments are
    /// stolen whole; exhaustion is an explicit collection failure, never an
    /// address-losing overflow followed by a whole-heap rescan.
    fn drainBarrierQueue(self: *Collector) CollectError!usize {
        return self.drainSegmentedFrontier(std.math.maxInt(u64), false, true);
    }

    /// Trace the segmented frontier until it is empty or `budget_ns` runs
    /// out; returns how many headers were traced. TGC S5-b: the incremental
    /// increment and the final remark's barrier drain are this one loop.
    ///
    /// A pop needs no validation: rc-managed kinds never enter the queue (see
    /// `shade`), and everything that can is freeable only by the collector
    /// itself, which does not run inside its own mutator windows -- the pop
    /// used to revalidate through the address registry, 4.3% of splay's
    /// runtime, against a hazard only shapes had. `drain_work` is the remark's
    /// extra obligation: its collector shades into the per-collection work
    /// list rather than the queue, so each traced header's children are
    /// flushed before the next pop. The clock is sampled every 64 objects
    /// rather than per pop (a traceHeader is tens of nanoseconds and
    /// `nowNanos` is not free); an unbudgeted caller skips the read.
    fn drainSegmentedFrontier(
        self: *Collector,
        budget_ns: u64,
        comptime prefetch: bool,
        comptime drain_work: bool,
    ) CollectError!usize {
        const queue = &self.rt.gc.marking.queue;
        const stack = &self.rt.gc.marking.stack;
        try checkFrontierFailure(queue);
        const budgeted = budget_ns != std.math.maxInt(u64);
        const started = if (budgeted) profile.nowNanos() else 0;
        var traced: usize = 0;
        var since_clock: usize = 0;
        while (popSegmentedFrontier(stack, queue, prefetch)) |header| {
            traced += 1;
            try self.traceHeader(header);
            if (self.err) |err| return err;
            if (drain_work) try self.drain();
            try checkFrontierFailure(queue);
            since_clock += 1;
            if (since_clock == 64) {
                since_clock = 0;
                if (budgeted and profile.nowNanos() -| started >= budget_ns) break;
            }
        }
        return traced;
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

    /// Force-trace one remembered owner (the minor's remembered walk, §8.3).
    ///
    /// Every other entry into `traceHeader` arrives through `shade`, which
    /// refuses a header whose cell is not published yet
    /// (`alloc_info.heap_accounted == false`). This walk is the one that
    /// bypasses that filter: its input is whatever address the write barrier
    /// stamped, and the barrier fires on a STORE -- which is exactly what a
    /// constructor does to a half-built object.
    ///
    /// The half-built object that reaches here is the detached generator
    /// shell. `createDetachedGeneratorShell` leaves `shape_ref` absent until
    /// `finishGeneratorShell` resolves the prototype, while
    /// `runGeneratorParameterInit` already stores into its payload -- so the
    /// shell is a legitimate remembered owner with no readable Shape, and the
    /// ordinary object edge walk starts at `callVisitShape(self.shape_ref)`.
    /// `seedRoots` routes construction-root pins to the shell protocol; this
    /// is the same exemption for the walk that does not go through the pin
    /// ledger.
    ///
    /// Skipping the shell instead would be wrong: its generator payload is
    /// the only initialized part and is precisely what the barrier
    /// remembered, so dropping it would leave the shell's young children
    /// unmarked.
    fn traceRememberedOwner(self: *Collector, header: *gc.Header) CollectError!void {
        if (header.metaConst().flags.kind == .object) {
            const shell = Object.fromHeader(header);
            if (shell.isDetachedGeneratorShellForGc()) {
                shell.traceDetachedGeneratorShellEdges(self) catch |err| {
                    self.err = err;
                };
                if (self.err) |err| return err;
                return;
            }
        }
        // `traceHeaderEdges`, NOT `traceHeader`: this is the only entry into
        // the trace that does not claim a mark, so it is the only one that
        // must not retire. Promoting a header the trace has not proven live
        // takes it out of the census and off the young list while leaving it
        // unmarked, and `ZJS_MINOR_AUDIT=fatal` catches the result as a live
        // old owner holding an unremembered edge into the condemned young set.
        // A remembered owner CAN be young: the barrier classifies an
        // unpublished header as old (it reads `flags.young == false`) and
        // remembers it, and publication then makes it young with the map entry
        // still standing. The ones that are genuinely live are retired by the
        // frontier route anyway -- by whatever marked them.
        try traceHeaderEdges(self.rt, self, header);
        if (self.err) |err| return err;
    }

    fn ephemeronFixedPoint(self: *Collector) CollectError!void {
        while (true) {
            const before = self.report.ephemeron_values_shaded;
            var holder = self.rt.weak_reference_holder_head;
            while (holder) |object| {
                const next = object.weakReferenceHolderNext();
                if (self.rt.gc.headerMarked(object.gcHeader())) {
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
            if (self.rt.gc.headerMarked(holder.gcHeader())) {
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
                removed = true;
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
        }
        finalization_payload.cells = finalization_payload.cells.ptr[0..write_index];
        holder.pruneBorrowedReferenceHolderIfEmpty(self.rt);
    }

    /// Young-only sweep for a minor. An old object cannot be proven dead by a
    /// minor -- its incoming edges were never traced -- so only unmarked young
    /// objects are condemned, and old marks are left alone rather than reset.
    /// TGC S4-g (3): stamp the condemnation bit on the young corpses the
    /// doomed bitmap already names, word at a time, without reading a single
    /// survivor's header.
    ///
    /// The two header tests kept per corpse are the ones `nextInBlock`'s young
    /// filter used to supply: an UNPUBLISHED cell (allocated, `heap_accounted`
    /// still clear) is not an object yet, and a corpse left over from an
    /// earlier condemnation still carries the stamp -- re-detaching it
    /// would trip `detachBlockObjectCandidate`'s own assertion.
    fn stampYoungBlockCorpses(self: *Collector) void {
        var cursor = self.rt.gc.block_heap.young_blocks;
        while (cursor) |block| {
            const next_link = block.young_link;
            for (block.doomedWords(), 0..) |word_bits, word_index| {
                var bits = word_bits;
                while (bits != 0) {
                    const bit: u6 = @intCast(@ctz(bits));
                    bits &= bits - 1;
                    const index: u32 = @intCast(word_index * 64 + bit);
                    if (index >= block.cell_count) break;
                    const header: *gc.Header = @ptrFromInt(block.cellBase(index) + gc.metadata_prefix_size);
                    const meta = header.metaConst();
                    if (!meta.alloc_info.heap_accounted) continue;
                    if (gc.headerCondemned(header)) continue;
                    if (self.rt.gc.headerIsPinned(header)) continue;
                    self.rt.gc.detachBlockObjectCandidate(header);
                }
            }
            cursor = if (next_link <= 1) null else @ptrFromInt(next_link);
        }
    }

    fn sweepUnmarkedYoung(self: *Collector, full_reachable: ?*const FullReachable) usize {
        // The production sweep consumes each dead header exactly once. Keep
        // a pointer snapshot only for the two diagnostics that need to inspect
        // the whole condemned set before mutation; allocating/growing this
        // array and replaying it was pure per-minor work otherwise.
        const snapshot_doomed = full_reachable != null or gc.minor_audit;
        var doomed: std.ArrayList(*gc.Header) = .empty;
        defer doomed.deinit(self.allocator());
        // Every condemned kind is freed, not just `.object` -- see
        // `destroyCondemnedSlice`. A young var_ref or shape the trace did not reach
        // is exactly as dead as a young object it did not reach. The trace is
        // the liveness authority; rc cannot mask a missing root or barrier.
        if (snapshot_doomed) {
            // Preserve the production producer order even under diagnostics:
            // block Objects first, then the standalone/list population. Pass A
            // pushes in this order, so LIFO Pass B gets its required generic
            // prefix followed by one block-only suffix.
            var young_blocks = self.rt.gc.objectIterator(.young_block);
            while (young_blocks.next()) |header| {
                if (self.rt.gc.headerMarked(header)) continue;
                if (self.rt.gc.headerIsPinned(header)) continue;
                doomed.append(self.allocator(), header) catch return 0;
            }
            var young_nonblock = self.rt.gc.objectIterator(.young_list);
            while (young_nonblock.next()) |header| {
                if (self.rt.gc.headerMarked(header)) continue;
                if (self.rt.gc.headerIsPinned(header)) continue;
                doomed.append(self.allocator(), header) catch return 0;
            }
        } else {
            // Stamp every block corpse. Object owns no intrusive successor;
            // block doomed bits are the complete condemnation authority until
            // Pass A destroys it.
            //
            // TGC S4-g (3): the snapshot goes FIRST and the stamp reads its
            // bitmap. `snapshotDoomed` is `alloc & ~mark` word arithmetic and
            // is the condemnation authority either way, so the walk it used to
            // follow was re-deriving the same verdict one HEADER at a time --
            // 55.78% of `nextInBlock`'s cycles are the single `alloc_info`
            // load, streamed over every allocated cell of every young block
            // (2.88% of the splay.fixed run). Corpses are ~20% of that
            // population (793 minors reclaim 4.69 M of 23.1 M young), so the
            // stamp now touches a fifth of the lines and the survivors are
            // never read at all.
            //
            // Two facts license dropping the young filter the header walk
            // applied. An OLD cell in a young block is always MARKED --
            // `clearYoungMarksStw` clears the mark of young cells only, and a
            // survivor is promoted with its mark still set -- so `alloc &
            // ~mark` cannot name one. And a PINNED cell is always marked too,
            // because `seedRoots` shades the whole pin ledger before anything
            // else; the pin test below is kept anyway, now that it costs a
            // probe per corpse rather than per cell.
            self.rt.memory.debitBlockBytes(
                self.rt.gc.block_heap.snapshotYoungDoomed(self.rt.gc.block_heap.mark_epoch).bitmap_bytes,
            );
            self.stampYoungBlockCorpses();
            // The list half is the young suffix and the side-authority half
            // is filtered by the young bit; both are the shared walk.
            var sink = SamePauseSink{};
            _ = condemnListSweep(self.rt, &sink, true);
        }
        if (full_reachable) |reachable| {
            var violations: usize = 0;
            var precise_violations: usize = 0;
            for (doomed.items) |header| {
                const reachability = reachable.entries.get(@intFromPtr(header)) orelse continue;
                violations += 1;
                if (reachability == .precise) precise_violations += 1;
                // A conservative-only hit is expected by construction (see
                // `gc.verify_minor_verbose`); printing it is opt-in so the
                // precise ones, which are the actual finding, are visible.
                if (reachability != .precise and !gc.verify_minor_verbose) continue;
                const kind = header.metaConst().flags.kind;
                if (kind == .object) {
                    const o = Object.fromHeader(header);
                    gc_audit_print.print(&.{
                        .{ .text = "VERIFY-MINOR condemned-but-reachable source=" },
                        .{ .text = @tagName(reachability) },
                        .{ .text = " kind=object class=" },
                        .{ .dec = o.class_id },
                        .{ .text = " payload=" },
                        .{ .text = @tagName(o.flags.class_payload_kind) },
                        .{ .text = "\n" },
                    });
                } else {
                    gc_audit_print.print(&.{
                        .{ .text = "VERIFY-MINOR condemned-but-reachable source=" },
                        .{ .text = @tagName(reachability) },
                        .{ .text = " kind=" },
                        .{ .text = @tagName(kind) },
                        .{ .text = "\n" },
                    });
                }
            }
            if (violations != 0) {
                defer if (gc.verify_minor_fatal and precise_violations != 0)
                    @panic("VERIFY-MINOR: precisely reachable object condemned by a minor");
                if (precise_violations != 0 or gc.verify_minor_verbose) {
                    gc_audit_print.print(&.{
                        .{ .text = "VERIFY-MINOR " },
                        .{ .dec = violations },
                        .{ .text = " of " },
                        .{ .dec = doomed.items.len },
                        .{ .text = " condemned objects are reachable by a full trace (" },
                        .{ .dec = precise_violations },
                        .{ .text = " precise, " },
                        .{ .dec = violations - precise_violations },
                        .{ .text = " conservative-only)\n" },
                    });
                }
            }
        }
        if (gc.minor_audit) self.auditCondemnedYoung(doomed.items);
        if (snapshot_doomed) {
            for (doomed.items) |header| {
                const doomed_kind = header.metaConst().flags.kind;
                if (gc.kindIsBlockCellKind(doomed_kind)) {
                    // String cells share the block route; a string is never a
                    // list carrier (extents are not young-listed).
                    if (gc.Registry.isBlockCellHeader(header))
                        self.rt.gc.detachBlockObjectCandidate(header)
                    else
                        self.rt.gc.condemnNonBlockObject(header);
                } else {
                    self.rt.gc.detachCycleCandidate(header);
                    condemnIntoBucket(self.rt, header);
                }
            }
            self.rt.memory.debitBlockBytes(
                self.rt.gc.block_heap.snapshotYoungDoomed(self.rt.gc.block_heap.mark_epoch).bitmap_bytes,
            );
        }

        const old_phase = self.rt.gc.hot.phase;
        self.rt.gc.hot.phase = .tracer_destroy;
        defer self.rt.gc.hot.phase = old_phase;

        // The extent half of the young set, FIRST. The destruction slice
        // covers only the block/bucket carriers, and an extent is in neither;
        // without this a short-lived >128 B string had to survive to the next
        // major. It runs before the close because it reads both structures the
        // close retires (`young_extents` and the young bit).
        var reclaimed: usize = 0;
        const published_before = self.rt.gc.generation.stats.young_publications;
        reclaimed += string_mod.sweepYoungExtents(self.rt);
        // What licenses running this before the close: an extent's death
        // is an atom handshake plus a mapping return, and neither
        // PUBLISHES. A GC publication here would be a young object the
        // close is about to strand -- counted into a census that is about
        // to be zeroed, on a young list that is about to be broken.
        // (`young_count` cannot answer this on its own: a death here
        // legitimately DECREMENTS it, via `forgetUnremembered`.)
        std.debug.assert(self.rt.gc.generation.stats.young_publications == published_before);

        // TGC S4-h (2): close the young generation BETWEEN the condemnation and
        // the destruction slice, not after it.
        //
        // Trace-coupled retirement leaves nothing for a bulk promotion pass to
        // do -- but it also leaves nothing to promote an object a DESTRUCTOR
        // publishes (finalizer enqueue, FinalizationRegistry job bookkeeping).
        // Closing first turns that from a hazard into the right answer: the
        // young list, the young-block list and the census are all empty when
        // the destructors run, so a sweep-time publication re-links its block
        // and re-counts itself as what it is, a member of the NEXT young
        // generation. (After the close it would otherwise be a cell with the
        // young bit set, no block on the young list, and no census entry --
        // invisible to the next minor and to `verifyGenerationInvariants`.)
        // The diagnostic producer above does not clear survivor young bits as
        // it walks (it only collects pointers), so that arm still needs the
        // bulk pass. Production does not.
        if (snapshot_doomed) promoteYoungSurvivorsInBulk(self.rt);
        closeYoungGeneration(self.rt);

        reclaimed += destroyCondemnedWhole(self.rt, false);

        // Survivors keep their marks: that is what makes them old.
        return reclaimed;
    }

    fn sweepUnmarked(self: *Collector) usize {
        // Block Object corpses are stamped first, then published only through
        // the block doomed bitmap. No Object body word is list authority.
        var block_iterator = self.rt.gc.objectIterator(.dead_block);
        while (block_iterator.next()) |header| {
            if (self.rt.gc.headerIsPinned(header)) {
                header.meta().flags.young = false;
                continue;
            }
            self.rt.gc.detachBlockObjectCandidate(header);
        }
        self.rt.memory.debitBlockBytes(
            self.rt.gc.block_heap.snapshotAllDoomed(self.rt.gc.block_heap.mark_epoch).bitmap_bytes,
        );

        // The whole live list plus the rare side-authoritative Objects.
        var sink = SamePauseSink{};
        _ = condemnListSweep(self.rt, &sink, false);

        // The compact trace header has no predecessor.  Close the retired
        // pre-sweep suffix here; any allocation performed by destruction opens
        // a fresh young tail that clearYoungState can walk forward exactly.
        self.rt.gc.lists.resetYoungSuffix();

        const old_phase = self.rt.gc.hot.phase;
        self.rt.gc.hot.phase = .tracer_destroy;
        defer self.rt.gc.hot.phase = old_phase;

        const garbage_count = destroyCondemnedWhole(self.rt, true);
        sweepAtomTable(self.rt);
        if (!self.rt.hasPendingDeferredClassPayloadFinalizers()) {
            self.rt.gc.block_heap.publishCompletedHotBlocks();
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
                    // The condemned cell is not necessarily an object: since
                    // TGC S2 a string body is an ordinary tracer cell and can
                    // be the child of a live owner's edge, so read the class
                    // only when the kind really is `.object`.
                    const c: ?*Object = if (child.metaConst().flags.kind == .object) Object.fromHeader(child) else null;
                    if (a.owner_kind == .object) {
                        const o = Object.fromHeader(a.owner_ptr);
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
                        if (o.ordinaryPayloadForAudit()) |op| {
                            const fields = .{
                                .{ "ordinary.callsite_file", op.callsite_file },
                                .{ "ordinary.callsite_function", op.callsite_function },
                                .{ "ordinary.promise_reaction_on_fulfilled", op.promise_reaction_on_fulfilled },
                                .{ "ordinary.promise_reaction_on_rejected", op.promise_reaction_on_rejected },
                                .{ "ordinary.promise_reaction_resolve", o.promiseReactionResolve() },
                                .{ "ordinary.promise_reaction_reject", o.promiseReactionReject() },
                                .{ "ordinary.promise_capability_resolve", op.promise_capability_resolve },
                                .{ "ordinary.promise_capability_reject", op.promise_capability_reject },
                                .{ "ordinary.promise_combinator_resolve", op.promise_combinator_resolve },
                                .{ "ordinary.promise_combinator_reject", op.promise_combinator_reject },
                                .{ "ordinary.promise_combinator_values", op.promise_combinator_values },
                                .{ "ordinary.promise_combinator_keys", op.promise_combinator_keys },
                                .{ "ordinary.error_stack", op.error_stack },
                                .{ "ordinary.error_stack_sites", op.error_stack_sites },
                            };
                            inline for (fields) |field| {
                                if (field[1]) |v| if (v.cycleMarkHeader() == child) {
                                    where = field[0];
                                };
                            }
                        }
                        if (o.promiseReactionIntrinsicCapability()) |capability| {
                            if (capability.target.cycleMarkHeader() == child) where = "reaction.intrinsic_target";
                            if (capability.self_error_global.cycleMarkHeader() == child) where = "reaction.self_error_global";
                        }
                        if (o.cachedIteratorNextSlotForCycleGc(a.rt)) |slot| {
                            if (slot.*) |v| if (v.cycleMarkHeader() == child) {
                                where = "iterator_next_cache";
                            };
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
                        std.debug.print("MINOR-AUDIT-WHERE owner_class={d} payload={s} where={s} atom={s} nprops={d} owner_marked={}\n", .{ o.class_id, @tagName(o.flags.class_payload_kind), where, a.rt.atoms.name(@intCast(hit_atom)) orelse "?", o.shape_ref.prop_count, a.rt.gc.headerMarked(o.gcHeader()) });
                    }
                    std.debug.print("MINOR-AUDIT owner={s}/ptr{x} owner_young={} owner_remembered={} -> child kind={s} class={d}/{s} child_young={} child_marked={}\n", .{
                        @tagName(a.owner_kind),
                        @intFromPtr(a.owner_ptr),
                        a.owner_young,
                        a.owner_remembered,
                        @tagName(child.metaConst().flags.kind),
                        if (c) |o| o.class_id else 0,
                        if (c) |o| @tagName(o.flags.class_payload_kind) else "-",
                        child.metaConst().flags.young,
                        a.rt.gc.headerMarked(child),
                    });
                    if (gc.minor_audit_fatal) @panic("MINOR-AUDIT: live owner holds an unremembered edge into the condemned young set");
                    return;
                }
            }
            pub fn visitValue(a: *@This(), val: *JSValue) void {
                a.hit(val.cycleMarkHeader());
            }
            pub fn visitObject(a: *@This(), obj_ptr: *?*Object) void {
                if (obj_ptr.*) |o| a.hit(o.gcHeader());
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
            pub fn storageCell(a: *@This(), header: *gc.Header) void {
                a.hit(header);
            }
            pub fn visitWeakCollectionEntry(_: *@This(), _: *object_payloads.WeakCollectionEntry) void {}
            pub fn visitFinalizationCell(_: *@This(), _: *object_payloads.FinalizationRegistryCell) void {}
        };
        var audit = Audit{ .doomed = doomed_items, .rt = self.rt };
        var it = self.rt.gc.objectIterator(.all);
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
                    const owner = Object.fromHeader(h);
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
};

fn keyIsMarked(rt: *const JSRuntime, identity: usize) bool {
    if ((identity & 1) != 0) {
        const atom_id = identity >> 1;
        if (atom_id > std.math.maxInt(@import("atom.zig").Atom)) return false;
        const symbol_atom: @import("atom.zig").Atom = @intCast(atom_id);
        if (rt.atoms.kind(symbol_atom) != .symbol) return false;
        const header = rt.atoms.symbolBodyHeaderIfLive(rt, symbol_atom) orelse return false;
        return rt.gc.headerMarked(header);
    }
    const object = rt.liveObjectFromWeakIdentity(identity) orelse return false;
    return rt.gc.headerMarked(object.gcHeader());
}

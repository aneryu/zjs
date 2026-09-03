//! Three-phase trial-deletion cycle collector for object-model GC nodes.
//!
//! Edge enumeration remains on Object: the authority trace belongs beside the
//! data it describes. This module owns the phase driver and its hot mark arms.

const atom = @import("atom.zig");
const class = @import("class.zig");
const context_mod = @import("context.zig");
const gc = @import("gc.zig");
const module_mod = @import("module.zig");
const object_mod = @import("object.zig");
const block_heap = @import("gc_block_heap.zig");
const corpse_census = @import("gc_corpse_census.zig");
const property = @import("property.zig");
const runtime_mod = @import("runtime.zig");
const shape = @import("shape.zig");
const var_ref_mod = @import("var_ref.zig");
const function_bytecode_mod = @import("../bytecode.zig").function_bytecode;
const FunctionBytecode = function_bytecode_mod.FunctionBytecode;
const Object = object_mod.Object;
const FinalizationRegistryCell = object_mod.FinalizationRegistryCell;
const FinalizationRegistryPayload = object_mod.FinalizationRegistryPayload;
const WeakCollectionEntry = object_mod.WeakCollectionEntry;
const JSRuntime = runtime_mod.JSRuntime;
const JSValue = @import("value.zig").JSValue;
const std = @import("std");
const builtin = @import("builtin");

const ObjectVisitSet = std.AutoHashMap(usize, void);
const ObjectGraphError = std.mem.Allocator.Error || error{PayloadMarkFailed};

/// qjs `JS_MarkFunc` (quickjs.h). Cold-tail walk uses one shared body.
const MarkFunc = *const fn (rt: *JSRuntime, header: *gc.Header) void;

/// Phase selector for the specialized ordinary-object data-slot arm. It used
/// to carry the trial-deletion collector's three passes (decref / scan_incref /
/// scan_restore), each getting its own small hot copy with the child update
/// inlined. Those passes went with the collector; what is left is the
/// edge-recording mode the parity test drives (see
/// `collectCycleMarkChildHeadersForTest`).
const MarkMode = enum(u8) { collect_test };

threadlocal var cycle_mark_test_headers: ?*ObjectVisitSet = null;
threadlocal var cycle_mark_test_oom: bool = false;

fn collectCycleMarkChildForTest(_: *JSRuntime, header: *gc.Header) void {
    if (!builtin.is_test) @compileError("cycle-mark child collection is test-only");
    const headers = cycle_mark_test_headers orelse unreachable;
    headers.put(@intFromPtr(header), {}) catch {
        cycle_mark_test_oom = true;
    };
}

inline fn markFuncFor(comptime mode: MarkMode) MarkFunc {
    return switch (mode) {
        .collect_test => collectCycleMarkChildForTest,
    };
}

inline fn isOrdinaryCycleHotObject(self: *const Object) bool {
    // qjs mark_children OBJECT arm stops after properties when
    // class_id == JS_CLASS_OBJECT (quickjs.c:6605).
    return self.class_id == class.ids.object and self.flags.class_payload_kind == .none;
}

inline fn markHeader(rt: *JSRuntime, header: anytype, comptime mode: MarkMode) void {
    const h: *gc.Header = gc.headerPtr(header);
    switch (mode) {
        .collect_test => collectCycleMarkChildForTest(rt, h),
    }
}

const MarkVisitor = struct {
    rt: *JSRuntime,
    mark_func: MarkFunc,

    pub fn visitValue(self: MarkVisitor, val: *JSValue) void {
        // JS_MarkValue (quickjs.c:6553-6566).
        if (val.cycleMarkHeader()) |h| self.mark_func(self.rt, h);
    }

    pub fn visitObject(self: MarkVisitor, obj_ptr: *?*Object) void {
        if (obj_ptr.*) |obj| {
            if (@intFromPtr(obj) == 0) return;
            self.mark_func(self.rt, obj.header.asHeader());
        }
    }

    pub fn visitShape(self: MarkVisitor, shape_ref: *shape.Shape) void {
        self.mark_func(self.rt, &shape_ref.header);
    }

    pub fn visitRealm(self: MarkVisitor, ctx_ptr: *?*context_mod.RealmContext) void {
        if (ctx_ptr.*) |ctx| self.mark_func(self.rt, &ctx.header);
    }

    pub fn visitModule(self: MarkVisitor, record: *module_mod.ModuleRecord) void {
        self.mark_func(self.rt, &record.header);
    }

    pub fn visitWeakCollectionEntry(self: MarkVisitor, entry: *WeakCollectionEntry) void {
        _ = self;
        _ = entry;
    }

    pub fn visitFinalizationCell(self: MarkVisitor, entry: *FinalizationRegistryCell) void {
        if (entry.keepsHeldValuesAlive()) self.visitValue(&entry.held_value);
    }
};

fn markUnusualPropertyCold(
    rt: *JSRuntime,
    entry: *property.Entry,
    slot_flags: property.Flags,
    mark_func: MarkFunc,
) void {
    const visitor = MarkVisitor{ .rt = rt, .mark_func = mark_func };
    switch (slot_flags.kind) {
        .data => unreachable,
        .accessor => {
            var getter_value = entry.slot.accessor.getterValue();
            visitor.visitValue(&getter_value);
            entry.slot.accessor.syncGetterFromVisitedValue(getter_value);
            var setter_value = entry.slot.accessor.setterValue();
            visitor.visitValue(&setter_value);
            entry.slot.accessor.syncSetterFromVisitedValue(setter_value);
        },
        .var_ref => {
            var cell_value = entry.slot.var_ref.valueRef();
            visitor.visitValue(&cell_value);
        },
        .auto_init => {
            const realm_header = entry.slot.auto_init.realm_and_id.realmHeader() orelse unreachable;
            var realm: ?*context_mod.RealmContext = @alignCast(@fieldParentPtr("header", realm_header));
            visitor.visitRealm(&realm);
            entry.slot.auto_init.realm_and_id.syncRealmHeader(&(realm orelse unreachable).header);
        },
    }
}

fn markIteratorNextCacheCold(rt: *JSRuntime, self: *Object, mark_func: MarkFunc) void {
    const visitor = MarkVisitor{ .rt = rt, .mark_func = mark_func };
    if (self.cachedIteratorNextSlotForCycleGc(rt)) |slot| {
        if (slot.*) |*stored| visitor.visitValue(stored);
    }
}

inline fn markPropertyDataSlots(rt: *JSRuntime, self: *Object, comptime mode: MarkMode) void {
    const traced_prop_count = self.shape_ref.prop_count;
    for (self.propertyStorageEntries(traced_prop_count), 0..) |*entry, index| {
        const slot_flags = self.propFlagsAt(index);
        if (slot_flags.deleted) continue;
        if (slot_flags.kind == .data) {
            if (entry.slot.data.cycleMarkHeader()) |h| markHeader(rt, h, mode);
            continue;
        }
        @call(.never_inline, markUnusualPropertyCold, .{ rt, entry, slot_flags, markFuncFor(mode) });
    }
}

/// Specialized ordinary-object arm (qjs:6572-6603, class_id == OBJECT).
/// One small copy per MarkMode so the data-slot `JS_MarkValue` + child
/// update inline. Accessor / var_ref / autoinit stay outlined.
fn markOrdinaryObjectHot(rt: *JSRuntime, self: *Object, comptime mode: MarkMode) align(16) void {
    markHeader(rt, &self.shape_ref.header, mode);
    markPropertyDataSlots(rt, self, mode);
    if (rt.cached_iterator_next_entries.len != 0) {
        @call(.never_inline, markIteratorNextCacheCold, .{ rt, self, markFuncFor(mode) });
    }
}

/// Specialized fast-array arm (qjs js_array_mark, quickjs.c:6204).
fn markFastArrayHot(rt: *JSRuntime, self: *Object, comptime mode: MarkMode) align(16) void {
    markHeader(rt, &self.shape_ref.header, mode);
    markPropertyDataSlots(rt, self, mode);
    for (self.arrayElements()) |*stored| {
        if (stored.cycleMarkHeader()) |h| markHeader(rt, h, mode);
    }
    if (rt.cached_iterator_next_entries.len != 0) {
        @call(.never_inline, markIteratorNextCacheCold, .{ rt, self, markFuncFor(mode) });
    }
}

/// Specialized shape arm (qjs:6662-6668).
fn markShapeHot(rt: *JSRuntime, header: *gc.Header, comptime mode: MarkMode) align(16) void {
    const shape_ref: *shape.Shape = @alignCast(@fieldParentPtr("header", header));
    if (shape_ref.proto) |proto| {
        if (@intFromPtr(proto) != 0) markHeader(rt, &proto.header, mode);
    }
}

/// Shared cold walk: non-ordinary objects and non-object GC kinds.
/// Single instantiation; visitor is a function pointer.
fn markChildrenCold(rt: *JSRuntime, header: *gc.Header, mark_func: MarkFunc) align(16) void {
    const visitor = MarkVisitor{ .rt = rt, .mark_func = mark_func };
    switch (header.meta().flags.kind) {
        .object => {
            const obj: *Object = Object.fromHeader(header);
            obj.traceChildEdgesNoFail(rt, visitor);
        },
        .function_bytecode => {
            const fb: *FunctionBytecode = @alignCast(@fieldParentPtr("header", header));
            visitor.visitRealm(&fb.realm.ptr);
            for (fb.cpoolSlice()) |*stored| visitor.visitValue(stored);
        },
        .var_ref => {
            const ref: *var_ref_mod.VarRef = @alignCast(@fieldParentPtr("header", header));
            // Closed: value is the owned binding value. Open: pvalue is a
            // borrowed frame slot, while value owns the parked generator
            // that keeps that slot alive. This is QuickJS's detached-value
            // vs attached-async_func union; tracing pvalue for an open cell
            // double-counts the frame-owned slot and corrupts trial RC.
            visitor.visitValue(&ref.value);
        },
        .shape => {
            const shape_ref: *shape.Shape = @alignCast(@fieldParentPtr("header", header));
            shape_ref.traceChildEdgesNoFail(rt, visitor);
        },
        .realm_context => {
            const ctx: *context_mod.JSContext = @alignCast(@fieldParentPtr("header", header));
            ctx.traceChildEdgesNoFail(visitor);
        },
        .module => {
            const record: *module_mod.ModuleRecord = @alignCast(@fieldParentPtr("header", header));
            record.traceChildEdgesNoFail(rt, visitor);
        },
        // Strings are acyclic refcounted leaves with no child edges.
        .string => {},
        // BigInts are acyclic refcounted leaves with no child edges.
        .big_int => {},
    }
}

inline fn markOne(rt: *JSRuntime, header: *gc.Header, comptime mode: MarkMode) void {
    switch (header.meta().flags.kind) {
        .object => {
            const obj: *Object = Object.fromHeader(header);
            if (isOrdinaryCycleHotObject(obj)) {
                @call(.never_inline, markOrdinaryObjectHot, .{ rt, obj, mode });
                return;
            }
            if (obj.isArray() and obj.flags.fast_array) {
                @call(.never_inline, markFastArrayHot, .{ rt, obj, mode });
                return;
            }
        },
        .shape => {
            @call(.never_inline, markShapeHot, .{ rt, header, mode });
            return;
        },
        else => {},
    }
    @call(.never_inline, markChildrenCold, .{ rt, header, markFuncFor(mode) });
}

/// Pass B: qjs `gc_free_cycles` second walk (quickjs.c:6797-6810).
/// One `list_for_each_safe`, in-place free, no pop/continue revisit.
/// Keep only a JS object with remaining weakrefs (qjs:6803-6806). Leftover
/// rc after the resource pass is intra-cycle and is freed here so the next
/// GC does not walk the husk again. Still only the four qjs kinds (OBJECT /
/// FUNCTION_BYTECODE / MODULE; zjs has no ASYNC) plus var_ref / realm_context
/// leftovers whose owners skipped them via cycle_visited. Does not delete
/// `cycle_visited`, does not touch RC teardown or ScanIncref.
pub fn drainCycleDeferredFrees(rt: *JSRuntime) void {
    _ = drainCycleDeferredFreesBudgeted(rt, std.math.maxInt(usize));
}

inline fn freeCycleDeferredObject(rt: *JSRuntime, h: *gc.Header) void {
    const obj: *Object = @ptrCast(@alignCast(h));
    // qjs:6803-6806. deinit must still free weak husks (phase != remove_cycles).
    if (gc.phaseIsTwoPassTeardown(rt.gc.phase) and obj.weakReferenceCount() != 0) {
        // Neither pop path clears the dead allocation's links. This is the one
        // branch that keeps the allocation, so finish the detach here. The
        // Pass-B overlay lives in `prop_values`; restore the empty sentinel
        // rather than writing `Header.next`.
        obj.restoreEmptyPropertyStorage();
        h.meta().flags.mark = false;
        h.meta().flags.cycle_visited = false;
        h.meta().flags.finalizing = false;
        // The shared word is mark/husk state, not an object count, so stamp the
        // state for `releaseWeakIdentity` to recognise it.
        gc.setHeaderWeakHusk(h);
    } else {
        Object.freeCycleDeferredStruct(rt, obj);
    }
}

/// Stage 3 (`docs/corpse-census-2026-08-29.md` §5.2/§5.3): settle a trivially
/// releasable block corpse HERE, in Pass A, instead of parking it for Pass B.
///
/// The census priced Pass B at 27.8 cycles and **1.13 L2D refills per entry**
/// and showed those cycles are essentially all cache refill: Pass A has just
/// touched this corpse's line (`destroyFromHeader` wrote its flags), the LIFO
/// push evicts it, and the drain's pointer chase pulls it back a second time.
/// So the classification has to happen while the line is still hot -- doing it
/// in Pass B would pay exactly the miss it is trying to remove (§5.3).
///
/// What the settlement omits relative to the deferred free, and why each is
/// safe:
///
/// * the LIFO push/pop -- the corpse never enters the parked queue;
/// * `pushCell`'s per-cell free link -- 95.6% of those writes on splay are
///   provably dead stores (`openBlock` rebuilds intervals from the alloc
///   bitmap and resets `next_free`), and the remaining ones are rebuilt the
///   same way. This is stage 2 arriving as a by-product, exactly as §5.1
///   predicted;
/// * the empty-block transition and the allocator-current block -- both
///   vetoed by `Heap.canSettleDoomedCellInPassA`.
///
/// Nothing about destructor ordering moves: the cell is released but unlinked,
/// its bytes are untouched, and it can only be handed out again after the
/// publication gate, which still runs in Pass B / at transaction close.
pub inline fn trySettleTracerBlockCorpse(
    rt: *JSRuntime,
    self: *Object,
    class_is_settleable: bool,
    payload_bytes: usize,
) bool {
    // Only the tracer's own destruction window. `.deinit` keeps the
    // established park path -- it tears the block heap down anyway.
    if (rt.gc.phase != .tracer_destroy) return false;
    if (!class_is_settleable) return false;
    if (!gc.Registry.isBlockCellHeader(&self.header)) return false;
    // `freeCycleDeferredObject` would keep this allocation as a weak husk, and
    // the fast arm would still have to drop a weak-id side-table entry. Both
    // are 0 on all three census workloads, so the exclusion is free.
    if (self.weakReferenceCount() != 0 or self.flags.has_weak_id) return false;

    const cell_addr = @intFromPtr(&self.header) - gc.metadata_prefix_size;
    const cell: [*]u8 = @ptrFromInt(cell_addr);
    const block = block_heap.Block.fromCellTrusted(cell_addr);
    if (!rt.gc.block_heap.canSettleDoomedCellInPassA(block)) return false;

    if (comptime std.debug.runtime_safety) {
        // The settlement predicate must be a SUBSET of the Pass-B fast arm:
        // everything skipped here is something `freeCycleDeferredStruct` would
        // also have skipped. A dynamic class id would leak its definition pin
        // (`Table.deinit`'s `assert(!state.isPinned())`), and an inline-payload
        // class would have had its allocation base before the Object.
        std.debug.assert(Object.passBFastArmEligible(rt, self.class_id));
        std.debug.assert(payload_bytes == self.allocationSize(rt));
    }

    const index: u32 = std.mem.readInt(u16, cell[0..2], .little);
    rt.memory.debitBlockCellPayload(self, payload_bytes);
    rt.gc.block_heap.settleDoomedCellInPassA(block, index);
    // ③ made "ordinary size" a per-class quantity. Comparing against the head
    // size alone would report every wide-armed corpse (every fast array) as
    // non-ordinary and silently rewrite the stage-3 settlement census.
    corpse_census.noteSettled(payload_bytes != Object.objectBodyBytes(class.ids.object));
    return true;
}

/// Census-only classification of one parked corpse, taken BEFORE the physical
/// release. Every field describes work the release must do beyond clearing the
/// alloc bit, decrementing `allocated_count` and debiting `MemoryAccount`.
fn censusNoteParked(rt: *JSRuntime, h: *gc.Header) void {
    if (comptime !corpse_census.enabled) return;
    const kind = h.meta().flags.kind;
    if (!gc.Registry.isBlockCellHeader(h)) {
        corpse_census.note(.{
            .block_cell = false,
            .kind = @intFromEnum(kind),
            .weak_husk = false,
            .weak_id = false,
            .fast_class = false,
            .standard_class = false,
            .inline_payload = false,
            .trailing_fam = false,
            .interval_allocator = false,
            .allocator_current = false,
            .becomes_empty = false,
            .cell_index = 0,
            .class_id = 0,
        });
        return;
    }
    const obj: *Object = Object.fromHeader(h);
    const cell_addr = @intFromPtr(h) - gc.metadata_prefix_size;
    const cell: [*]u8 = @ptrFromInt(cell_addr);
    const block = block_heap.Block.fromCellTrusted(cell_addr);
    const index: u32 = std.mem.readInt(u16, cell[0..2], .little);
    const facts = rt.gc.block_heap.censusCellFacts(block, index);
    const plan = rt.classes.destructionPlan(obj.class_id);
    corpse_census.note(.{
        .block_cell = true,
        .kind = @intFromEnum(kind),
        .weak_husk = gc.phaseIsTwoPassTeardown(rt.gc.phase) and obj.weakReferenceCount() != 0,
        .weak_id = obj.flags.has_weak_id,
        .fast_class = Object.passBFastArmEligible(rt, obj.class_id),
        .standard_class = obj.class_id < class.ids.init_count,
        .inline_payload = if (plan) |p| p.inline_payload_size != 0 else false,
        .trailing_fam = obj.hasTrailingPropertyAllocation(),
        .interval_allocator = facts.interval_allocator,
        .allocator_current = facts.allocator_current,
        .becomes_empty = facts.becomes_empty,
        .cell_index = index,
        .class_id = obj.class_id,
    });
}

/// Return up to `budget` parked struct frees to the allocator. Returns true
/// when the queue is empty. The park's only obligation is to outlive every
/// destructor of the same condemned set; once destruction is complete the
/// frees can trickle out across polls -- a single-shot drain of a large
/// morgue was a 6.8 ms pause hiding at the tail of the last slice.
pub fn drainCycleDeferredFreesBudgeted(rt: *JSRuntime, budget: usize) bool {
    const parked = &rt.gc.cycle_deferred_frees;
    corpse_census.noteDrainCall();
    if (gc.arena_audit) {
        rt.gc.verifyDeferredFreeRunTopology() catch |err| {
            std.debug.print("gc: DEFERRED RUN AUDIT: {s}\n", .{@errorName(err)});
            @panic("deferred free run invariant violated");
        };
    }

    var remaining = @min(budget, parked.count);
    var unsettled_at = remaining;
    var cursor = parked.head;

    // Pass A parks block cells before list carriers. LIFO reversal therefore
    // leaves a generic prefix followed by one proven block-only suffix. Pay the
    // exact route-marker test only while finding that suffix.
    while (remaining != 0) {
        const h = cursor orelse unreachable;
        if (gc.Registry.isBlockCellHeader(h)) break;
        cursor = gc.deferredFreeSuccessor(h);
        remaining -= 1;
        censusNoteParked(rt, h);
        switch (h.meta().flags.kind) {
            .object => freeCycleDeferredObject(rt, h),
            .function_bytecode => function_bytecode_mod.freeCycleDeferredStruct(rt, h),
            .module => module_mod.ModuleRecord.freeCycleDeferredStruct(rt, h),
            .var_ref => var_ref_mod.VarRef.freeCycleDeferredStruct(rt, h),
            .realm_context => context_mod.JSContext.freeCycleDeferredStruct(rt, h),
            else => {},
        }
    }

    // Inside the block suffix, the topology checker proves every entry is an
    // Object and each block occurs in one contiguous run. The only per-entry
    // route work is the 64 KiB mask/compare on the already-captured successor.
    if (remaining != 0) {
        var block = block_heap.Block.fromCellTrusted(@intFromPtr(cursor.?) - gc.metadata_prefix_size);
        while (remaining != 0) {
            const h = cursor orelse unreachable;
            cursor = gc.deferredFreeSuccessor(h);
            remaining -= 1;
            censusNoteParked(rt, h);
            freeCycleDeferredObject(rt, h);

            const next_base = if (cursor) |next|
                @intFromPtr(next) & ~@as(usize, block_heap.block_bytes - 1)
            else
                0;
            if (next_base == @intFromPtr(block)) continue;

            // Settle only on an actual run boundary. No released cell from the
            // completed run remains reachable when the callback publishes it.
            parked.head = cursor;
            parked.count -= unsettled_at - remaining;
            unsettled_at = remaining;
            corpse_census.noteRunBoundary(@intFromPtr(block));
            rt.gc.block_heap.onBlockPassBComplete(block);
            if (next_base != 0) block = @ptrFromInt(next_base);
        }
    }

    // A budget may stop in the generic prefix or halfway through a block run.
    // No Pass-B arm invokes a payload callback, so one final settlement is
    // sufficient for that partial batch.
    parked.head = cursor;
    parked.count -= unsettled_at - remaining;
    std.debug.assert((parked.head == null) == (parked.count == 0));
    if (parked.head != null) corpse_census.noteBudgetStop();
    corpse_census.noteSliceEnd();
    return parked.head == null;
}

pub fn enqueueFinalizationCleanup(
    rt: *JSRuntime,
    payload: *const FinalizationRegistryPayload,
    held_value: JSValue,
) void {
    // §9.3: the job slot was reserved when the cell was registered. Sweep
    // must not allocate.
    const callback = payload.cleanup_callback orelse {
        if (rt.job_queue.capacity != 0) rt.job_queue.releaseReservedEntries(1);
        return;
    };
    const realm = payload.realm.borrow() orelse unreachable;
    // Normal collections consume the slot reserved at register. Runtime
    // teardown deinits the queue first, then cycle-removes leftover
    // objects; fall back to an allocating enqueue so that path can
    // rehydrate the queue the way trial deletion always did.
    if (rt.job_queue.reserved_entries != 0) {
        rt.enqueueFinalizationJobReserved(realm, callback, held_value);
    } else {
        rt.enqueueFinalizationJobForRealm(realm, callback, held_value) catch {};
    }
}

/// Dual of `Object.ordinary_object_cycle_hot_edges`: the specialized
/// `markOrdinaryObjectHot` arm covers these kinds. Runtime presence of any
/// kind still depends on the live object (empty props, absent iterator cache).
pub const ordinary_object_cycle_hot_edges = [_]Object.CycleHotEdgeKind{
    .shape,
    .property_slots,
    .iterator_next_cache,
};

/// Dual of `Object.fast_array_cycle_hot_edges` for `markFastArrayHot`.
pub const fast_array_cycle_hot_edges = [_]Object.CycleHotEdgeKind{
    .shape,
    .property_slots,
    .array_elements,
    .iterator_next_cache,
};

/// Dual of `Object.shape_cycle_hot_edges` for `markShapeHot`.
pub const shape_cycle_hot_edges = [_]Object.CycleHotEdgeKind{.proto};

comptime {
    std.debug.assert(std.mem.eql(
        u8,
        std.mem.asBytes(&ordinary_object_cycle_hot_edges),
        std.mem.asBytes(&Object.ordinary_object_cycle_hot_edges),
    ));
    std.debug.assert(std.mem.eql(
        u8,
        std.mem.asBytes(&fast_array_cycle_hot_edges),
        std.mem.asBytes(&Object.fast_array_cycle_hot_edges),
    ));
    std.debug.assert(std.mem.eql(
        u8,
        std.mem.asBytes(&shape_cycle_hot_edges),
        std.mem.asBytes(&Object.shape_cycle_hot_edges),
    ));
}

pub const CycleMarkPathForTest = enum { mark_one, children_cold };

/// Test-only: run a production mark walk (`markOne` or `markChildrenCold`) with
/// a child-recording update and return the visited GC headers. `collect_test`
/// is a separate comptime instantiation of the same specialized hot arms, so
/// production Decref/Scan copies are unchanged and no carrier lifetime word is
/// perturbed in either collector configuration.
pub fn collectCycleMarkChildHeadersForTest(
    rt: *JSRuntime,
    header: *gc.Header,
    path: CycleMarkPathForTest,
    allocator: std.mem.Allocator,
) ![]usize {
    if (!builtin.is_test) @compileError("cycle-mark child collection is test-only");
    std.debug.assert(cycle_mark_test_headers == null);
    std.debug.assert(!cycle_mark_test_oom);

    var set = ObjectVisitSet.init(allocator);
    defer set.deinit();
    cycle_mark_test_headers = &set;
    defer cycle_mark_test_headers = null;
    defer cycle_mark_test_oom = false;

    switch (path) {
        .mark_one => markOne(rt, header, .collect_test),
        .children_cold => markChildrenCold(rt, header, collectCycleMarkChildForTest),
    }
    if (cycle_mark_test_oom) return error.OutOfMemory;

    const keys = try allocator.alloc(usize, set.count());
    var index: usize = 0;
    var key_iterator = set.keyIterator();
    while (key_iterator.next()) |key| {
        keys[index] = key.*;
        index += 1;
    }
    std.mem.sort(usize, keys, {}, std.sort.asc(usize));
    return keys;
}

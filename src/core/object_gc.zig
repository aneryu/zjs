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

const ObjectVisitSet = std.AutoHashMap(usize, void);
const ObjectGraphError = std.mem.Allocator.Error || error{PayloadMarkFailed};

pub fn destroyRuntimeCycles(rt: *JSRuntime) usize {
    return rt.runObjectCycleRemoval();
}

/// qjs `JS_MarkFunc` (quickjs.h). Cold-tail walk uses one shared body.
const MarkFunc = *const fn (rt: *JSRuntime, header: *gc.Header) void;

/// Phase selector for the specialized ordinary-object data-slot arm.
/// Comptime so Decref / ScanIncref each get a small hot copy with the
/// child update inlined (no per-edge `blr`). Rare class-payload tails
/// stay in `markChildrenCold`.
const MarkMode = enum(u8) { decref, scan_incref, scan_restore };

inline fn markFuncFor(comptime mode: MarkMode) MarkFunc {
    return switch (mode) {
        .decref => gcDecrefChild,
        .scan_incref => gcScanIncrefChild,
        .scan_restore => gcScanIncrefChild2,
    };
}

inline fn isOrdinaryCycleHotObject(self: *const Object) bool {
    // qjs mark_children OBJECT arm stops after properties when
    // class_id == JS_CLASS_OBJECT (quickjs.c:6605).
    return self.class_id == class.ids.object and self.flags.class_payload_kind == .none;
}

/// qjs `gc_decref_child` (quickjs.c:6687-6695).
inline fn gcDecrefChildInline(rt: *JSRuntime, p: *gc.Header) void {
    std.debug.assert(p.meta().rc > 0);
    p.meta().rc -= 1;
    if (p.meta().rc == 0 and p.meta().flags.mark) {
        rt.gc.detachCycleCandidate(p);
        gc.listAddTail(&rt.gc.tmp_obj_list, p);
    }
}

fn gcDecrefChild(rt: *JSRuntime, p: *gc.Header) void {
    gcDecrefChildInline(rt, p);
}

/// qjs `gc_scan_incref_child` (quickjs.c:6719-6728).
inline fn gcScanIncrefChildInline(rt: *JSRuntime, p: *gc.Header) void {
    p.meta().rc += 1;
    if (p.meta().rc != 1) return;
    // Unlinked headers are not cycle-list members (heap BigInt used to
    // reach here via refCountHeader; cycleMarkHeader now matches
    // JS_MarkValue, but force-GC and mid-construction edges can still
    // present a non-listed GC header). list_del on prev==null is SEGV.
    if (p.prev == null) return;
    gc.listDel(p);
    rt.gc.restoreCycleCandidate(p);
    p.meta().flags.mark = false;
}

fn gcScanIncrefChild(rt: *JSRuntime, p: *gc.Header) void {
    gcScanIncrefChildInline(rt, p);
}

/// qjs `gc_scan_incref_child2` (quickjs.c:6731-6734).
inline fn gcScanIncrefChild2Inline(rt: *JSRuntime, p: *gc.Header) void {
    _ = rt;
    p.meta().rc += 1;
}

fn gcScanIncrefChild2(rt: *JSRuntime, p: *gc.Header) void {
    gcScanIncrefChild2Inline(rt, p);
}

inline fn markHeader(rt: *JSRuntime, h: *gc.Header, comptime mode: MarkMode) void {
    switch (mode) {
        .decref => gcDecrefChildInline(rt, h),
        .scan_incref => gcScanIncrefChildInline(rt, h),
        .scan_restore => gcScanIncrefChild2Inline(rt, h),
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
            self.mark_func(self.rt, &obj.header);
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
    for (self.prop_values[0..traced_prop_count], 0..) |*entry, index| {
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
            const obj: *Object = @alignCast(@fieldParentPtr("header", header));
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
            const obj: *Object = @alignCast(@fieldParentPtr("header", header));
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

fn gcRemoveWeakObjects(rt: *JSRuntime) ObjectGraphError!void {
    sweepDeadWeakRootSlots(rt);

    // Match qjs gc_remove_weak_objects: the payload-resident holder list is
    // traversed exactly once while zero-ref destruction is deferred. Empty
    // weak holders stay linked for their full lifetime, so this traversal
    // has no allocation and no registry rescans or mark-bit side effects.
    rt.gc.beginDecrefPhase();
    defer rt.gc.endDecrefPhase(rt);
    var finalization_enqueue_blocked = false;
    var current = rt.weak_reference_holder_head;
    while (current) |holder| {
        const next = holder.weakReferenceHolderNext();
        try sweepDeadWeakPayloadReferences(holder, rt, &finalization_enqueue_blocked);
        current = next;
    }
}

fn sweepDeadWeakRootSlots(rt: *JSRuntime) void {
    for (rt.weak_root_slots) |slot| {
        const identity = slot.identity orelse continue;
        if (!weakIdentityIsLive(rt, identity)) {
            rt.clearWeakRootSlot(slot, true);
        }
    }
}

fn sweepDeadWeakPayloadReferences(
    self: *Object,
    rt: *JSRuntime,
    finalization_enqueue_blocked: *bool,
) ObjectGraphError!void {
    if (self.weakRefPayloadForCycleGc()) |payload| {
        if (payload.weak_target_identity) |identity| {
            if (!weakIdentityIsLive(rt, identity)) {
                rt.clearWeakIdentitySlot(&payload.weak_target_identity);
            }
        }
    }

    if (self.collectionPayloadForCycleGc()) |payload| {
        var read_index: usize = 0;
        var write_index: usize = 0;
        var removed_weak_entry = false;
        while (read_index < payload.weak_entries.len) : (read_index += 1) {
            const entry = payload.weak_entries[read_index];
            if (weakIdentityIsLive(rt, entry.key_identity)) {
                if (write_index != read_index) payload.weak_entries[write_index] = entry;
                write_index += 1;
                continue;
            }

            rt.releaseWeakIdentity(entry.key_identity);
            entry.value.free(rt);
            removed_weak_entry = true;
        }
        if (removed_weak_entry) {
            payload.weak_entries = payload.weak_entries.ptr[0..write_index];
            self.clearCollectionIndex(rt);
        }
    }

    const finalization_payload = self.finalizationRegistryPayloadForCycleGc() orelse {
        self.pruneBorrowedReferenceHolderIfEmpty(rt);
        return;
    };
    var read_index: usize = 0;
    var write_index: usize = 0;
    while (read_index < finalization_payload.cells.len) : (read_index += 1) {
        var cell = finalization_payload.cells[read_index];
        if (cell.unregister_token_identity) |identity| {
            if (!weakIdentityIsLive(rt, identity)) {
                rt.clearWeakIdentitySlot(&cell.unregister_token_identity);
            }
        }
        const target_identity = cell.target_identity orelse {
            finalization_payload.cells[write_index] = cell;
            write_index += 1;
            continue;
        };
        if (weakIdentityIsLive(rt, target_identity)) {
            finalization_payload.cells[write_index] = cell;
            write_index += 1;
            continue;
        }

        if (cell.isActive()) cell.state = .pending_enqueue;
        if (finalization_enqueue_blocked.*) {
            finalization_payload.cells[write_index] = cell;
            write_index += 1;
            continue;
        }
        enqueueFinalizationCleanup(rt, finalization_payload, cell.held_value) catch |err| switch (err) {
            error.OutOfMemory => {
                // No later cleanup in this GC traversal may overtake this
                // retained cell. A later collection retries the stable
                // registry/entry order after allocator recovery.
                finalization_enqueue_blocked.* = true;
                finalization_payload.cells[write_index] = cell;
                write_index += 1;
                continue;
            },
            error.PayloadMarkFailed => return error.PayloadMarkFailed,
        };
        cell.state = .queued;
        cell.destroy(rt);
    }
    finalization_payload.cells = finalization_payload.cells.ptr[0..write_index];
    self.pruneBorrowedReferenceHolderIfEmpty(rt);
}

fn weakIdentityIsLive(rt: *const JSRuntime, identity: usize) bool {
    if ((identity & 1) != 0) {
        const atom_id = identity >> 1;
        if (atom_id > std.math.maxInt(atom.Atom)) return false;
        return rt.atoms.kind(@intCast(atom_id)) == .symbol;
    }
    return rt.liveObjectFromWeakIdentity(identity) != null;
}

pub fn destroyRuntimeCyclesWithValueRoots(rt: *JSRuntime, roots: ?*const runtime_mod.ValueRootFrame) ObjectGraphError!usize {
    _ = roots;
    rt.gc.stats.collections += 1;
    // This is the only fallible operation in the collection round, and it
    // completes before trial refcounts, list membership, or round flags are
    // changed. Everything below is therefore a committed, no-error path.
    try gcRemoveWeakObjects(rt);

    gc.listInit(&rt.gc.tmp_obj_list);

    // Phase 1: gc_decref (quickjs.c:6697-6717)
    {
        var gc_iter = rt.gc.objectIterator();
        while (gc_iter.next()) |h| {
            markOne(rt, h, .decref);
            // Match qjs gc_decref: mark the current node after visiting
            // its children, then move it immediately if its trial count
            // is zero. GcObjectIterator captured `next` before tracing.
            h.meta().flags.mark = true;
            if (h.meta().rc == 0) {
                rt.gc.detachCycleCandidate(h);
                gc.listAddTail(&rt.gc.tmp_obj_list, h);
            }
        }
    }

    // Phase 2: gc_scan (quickjs.c:6736-6747)
    {
        // Walk the live list dynamically: reviving a trial-zero child moves
        // it from tmp_obj_list to the registry tail, so it is visited without
        // recursion or an auxiliary worklist.
        var cursor = rt.gc.gc_obj_list.next;
        while (cursor) |h| {
            if (h == &rt.gc.gc_obj_list) break;
            std.debug.assert(h.meta().rc > 0);
            h.meta().flags.mark = false;
            markOne(rt, h, .scan_incref);
            cursor = h.next;
        }
    }

    // Phase 3: restore refcounts of the detached dead-cycle partition
    // (quickjs.c:6749-6753, gc_scan_incref_child2).
    {
        var cursor = rt.gc.tmp_obj_list.next;
        while (cursor) |h| {
            if (h == &rt.gc.tmp_obj_list) break;
            markOne(rt, h, .scan_restore);
            cursor = h.next;
        }
    }

    Object.sweepCycleGarbageWeakCollectionEntriesForCycleGc(rt);

    // Consume tmp_obj_list like qjs gc_free_cycles (quickjs.c:6756-6793):
    // no 6-way staging lists. Explicit free_gc_object set is OBJECT /
    // FUNCTION_BYTECODE / MODULE (zjs has no JS_GC_OBJ_TYPE_ASYNC_FUNCTION).
    // Objects still run first so FB capture-count metadata outlives
    // closures (qjs free_object reads b->var_ref_count). Default kinds
    // (var_ref / shape / realm_context) stay on tmp until the four-kind
    // pass finishes, then get resource teardown — owners skip them via
    // cycle_visited, so they cannot rely on ownership the way qjs does.
    const old_phase = rt.gc.phase;
    rt.gc.phase = .remove_cycles;
    defer {
        rt.gc.phase = old_phase;
    }

    var garbage_count: usize = 0;
    // One walk per kind (O(n)), not one walk per node (O(n²)).
    var cursor = rt.gc.tmp_obj_list.next;
    while (cursor) |h| {
        if (h == &rt.gc.tmp_obj_list) break;
        const next = h.next;
        if (h.meta().flags.kind == .object) {
            gc.listDel(h);
            garbage_count += 1;
            Object.destroyFromHeader(rt, h);
        }
        cursor = next;
    }
    cursor = rt.gc.tmp_obj_list.next;
    while (cursor) |h| {
        if (h == &rt.gc.tmp_obj_list) break;
        const next = h.next;
        if (h.meta().flags.kind == .realm_context) {
            gc.listDel(h);
            garbage_count += 1;
            rt.gc.unlinkObjectWithBytes(h, gc.Registry.heapByteSizeFromHeader(rt, h));
            context_mod.JSContext.destroyFromHeader(rt, h);
        }
        cursor = next;
    }
    cursor = rt.gc.tmp_obj_list.next;
    while (cursor) |h| {
        if (h == &rt.gc.tmp_obj_list) break;
        const next = h.next;
        if (h.meta().flags.kind == .module) {
            gc.listDel(h);
            garbage_count += 1;
            rt.gc.unlinkObjectWithBytes(h, gc.Registry.heapByteSizeFromHeader(rt, h));
            module_mod.ModuleRecord.destroyFromHeader(rt, h);
        }
        cursor = next;
    }
    cursor = rt.gc.tmp_obj_list.next;
    while (cursor) |h| {
        if (h == &rt.gc.tmp_obj_list) break;
        const next = h.next;
        if (h.meta().flags.kind == .function_bytecode) {
            gc.listDel(h);
            rt.gc.unlinkObjectWithBytes(h, gc.Registry.heapByteSizeFromHeader(rt, h));
            function_bytecode_mod.destroyFromHeader(rt, h);
        }
        cursor = next;
    }
    while (gc.listFirst(&rt.gc.tmp_obj_list)) |h| {
        gc.listDel(h);
        switch (h.meta().flags.kind) {
            .var_ref => {
                garbage_count += 1;
                rt.gc.unlinkObjectWithBytes(h, gc.Registry.heapByteSizeFromHeader(rt, h));
                var_ref_mod.VarRef.destroyFromHeader(rt, h);
            },
            .shape => {
                garbage_count += 1;
                if (!h.meta().flags.finalizing) rt.shapes.destroyFromHeader(h);
            },
            else => unreachable,
        }
    }

    // Pass B: now every garbage object's resources are gone AND every shape
    // (whose teardown re-releases protos) has run. If class-payload
    // finalizers were deferred, keep the resource-stripped object husks until
    // those finalizers drain: payloads may still hold JSValues into the
    // condemned cycle and must be able to release them without dereferencing
    // freed object memory.
    if (!rt.hasPendingDeferredClassPayloadFinalizers()) drainCycleDeferredFrees(rt);

    return garbage_count;
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
    const parked = &rt.gc.cycle_deferred_frees;
    var cursor = gc.listFirst(&parked.sentinel);
    while (cursor) |h| {
        const next = parked.nextAfter(h);
        parked.remove(h);
        switch (h.meta().flags.kind) {
            .object => {
                const obj: *Object = @alignCast(@fieldParentPtr("header", h));
                // qjs:6803-6806. deinit must still free weak husks (phase != remove_cycles).
                if (rt.gc.phase == .remove_cycles and obj.weakref_count != 0) {
                    h.meta().flags.mark = false;
                    h.meta().flags.cycle_visited = false;
                    h.meta().flags.finalizing = false;
                } else {
                    Object.freeCycleDeferredStruct(rt, obj);
                }
            },
            .function_bytecode => function_bytecode_mod.freeCycleDeferredStruct(rt, h),
            .module => module_mod.ModuleRecord.freeCycleDeferredStruct(rt, h),
            .var_ref => var_ref_mod.VarRef.freeCycleDeferredStruct(rt, h),
            .realm_context => context_mod.JSContext.freeCycleDeferredStruct(rt, h),
            else => {},
        }
        cursor = next;
    }
}

pub fn releaseCallbackOwnedFunctionBytecodeCycles(rt: *JSRuntime) void {
    var candidates = ObjectVisitSet.init(rt.memory.allocator);
    defer candidates.deinit();

    var gc_iter = rt.gc.objectIterator();
    while (gc_iter.next()) |h| {
        const function_bytecode = functionBytecodeFromGcHeader(h) orelse continue;
        candidates.put(@intFromPtr(function_bytecode), {}) catch return;
    }
    if (candidates.count() == 0) return;

    pruneCallbackOwnedFunctionBytecodeCycles(&candidates) catch return;
    if (candidates.count() == 0) return;

    retainFunctionBytecodeGuards(&candidates);
    defer releaseFunctionBytecodeGuards(rt, &candidates);

    var iterator = candidates.keyIterator();
    while (iterator.next()) |address| {
        const function_bytecode: *FunctionBytecode = @ptrFromInt(address.*);
        clearCallbackOwnedFunctionBytecodeCycleRefs(rt, function_bytecode, &candidates);
    }
}

fn pruneCallbackOwnedFunctionBytecodeCycles(candidates: *ObjectVisitSet) ObjectGraphError!void {
    while (true) {
        var removed = false;
        var iterator = candidates.keyIterator();
        while (iterator.next()) |address| {
            const function_bytecode: *const FunctionBytecode = @ptrFromInt(address.*);
            const internal_refs = countFunctionBytecodeRefsFromFunctionBytecodes(function_bytecode, candidates);
            const ref_count = function_bytecode.header.metaConst().rc;
            if (ref_count == internal_refs or (ref_count != 0 and ref_count - 1 == internal_refs)) continue;

            _ = candidates.remove(address.*);
            removed = true;
            break;
        }
        if (!removed) return;
    }
}

fn retainFunctionBytecodeGuards(candidates: *const ObjectVisitSet) void {
    var iterator = candidates.keyIterator();
    while (iterator.next()) |address| {
        const function_bytecode: *FunctionBytecode = @ptrFromInt(address.*);
        function_bytecode.header.retain();
    }
}

fn releaseFunctionBytecodeGuards(rt: *JSRuntime, candidates: *const ObjectVisitSet) void {
    var iterator = candidates.keyIterator();
    while (iterator.next()) |address| {
        const function_bytecode: *FunctionBytecode = @ptrFromInt(address.*);
        if (rt.gc.containsHeader(&function_bytecode.header)) {
            gc.release(rt, &function_bytecode.header);
        }
    }
}

fn clearCallbackOwnedFunctionBytecodeCycleRefs(
    rt: *JSRuntime,
    function_bytecode: *FunctionBytecode,
    candidates: *const ObjectVisitSet,
) void {
    for (function_bytecode.cpoolSlice()) |*stored| {
        if (!valueReferencesFunctionBytecodeCandidate(stored.*, candidates)) continue;
        const old_value = stored.*;
        stored.* = JSValue.undefinedValue();
        old_value.free(rt);
    }
}

fn valueReferencesFunctionBytecodeCandidate(stored: JSValue, candidates: *const ObjectVisitSet) bool {
    const function_bytecode = functionBytecodeFromValue(stored) orelse return false;
    return candidates.contains(@intFromPtr(function_bytecode));
}

fn functionBytecodeFromValue(stored: JSValue) ?*FunctionBytecode {
    const header = stored.objectHeader() orelse return null;
    if (header.meta().flags.kind != .function_bytecode) return null;
    return @fieldParentPtr("header", header);
}

fn countFunctionBytecodeRefsFromFunctionBytecodes(
    function_bytecode: *const FunctionBytecode,
    owners: *const ObjectVisitSet,
) usize {
    var count: usize = 0;
    var iterator = owners.keyIterator();
    while (iterator.next()) |address| {
        const owner: *const FunctionBytecode = @ptrFromInt(address.*);
        for (owner.cpoolSlice()) |stored| {
            const header = stored.objectHeader() orelse continue;
            if (header == &function_bytecode.header) count += 1;
        }
    }
    return count;
}

// mirror of value_semantics.objectFromValue (kind check included), keep
// in sync — kept local: object.zig <-> value_semantics import cycle.
fn objectFromValue(stored: JSValue) ?*Object {
    const stored_header = stored.refHeader() orelse return null;
    if (stored_header.meta().flags.kind != .object) return null;
    return @fieldParentPtr("header", stored_header);
}

pub fn enqueueFinalizationCleanup(
    rt: *JSRuntime,
    payload: *const FinalizationRegistryPayload,
    held_value: JSValue,
) ObjectGraphError!void {
    const callback = payload.cleanup_callback orelse return;
    const realm = payload.realm.borrow() orelse unreachable;
    try rt.enqueueFinalizationJobForRealm(realm, callback, held_value);
}

fn functionBytecodeFromGcHeader(header: *gc.GCObjectHeader) ?*const FunctionBytecode {
    if (header.meta().flags.kind != .function_bytecode) return null;
    return @alignCast(@fieldParentPtr("header", header));
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

/// Test-only: run a production mark walk (`markOne` or `markChildrenCold`) in
/// the decref phase and return the child GC headers whose RC dropped. Callers
/// must hang unique children (a header visited twice can hit RC 0). Restores
/// every listed header's RC before returning. Does not change the specialized
/// hot-arm production copies.
pub fn collectCycleMarkChildHeadersForTest(
    rt: *JSRuntime,
    header: *gc.Header,
    path: CycleMarkPathForTest,
    allocator: std.mem.Allocator,
) ![]usize {
    const rc_pad: i32 = 16;
    var snap = std.AutoHashMap(usize, i32).init(allocator);
    defer snap.deinit();
    var iterator = rt.gc.objectIterator();
    while (iterator.next()) |h| {
        try snap.put(@intFromPtr(h), h.meta().rc);
        h.meta().rc += rc_pad;
    }

    switch (path) {
        .mark_one => markOne(rt, header, .decref),
        .children_cold => markChildrenCold(rt, header, gcDecrefChild),
    }

    var set = ObjectVisitSet.init(allocator);
    defer set.deinit();
    var restore = rt.gc.objectIterator();
    while (restore.next()) |h| {
        const ptr = @intFromPtr(h);
        const orig = snap.get(ptr) orelse {
            h.meta().rc += rc_pad;
            continue;
        };
        if (h.meta().rc < orig + rc_pad) {
            try set.put(ptr, {});
        }
        h.meta().rc = orig;
    }

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

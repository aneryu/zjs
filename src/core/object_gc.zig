//! Death-side helpers left over from the trial-deletion collector: the Pass-B
//! parked-free drain (`drainCycleDeferredFreesBudgeted`), block-corpse
//! settlement, and FinalizationRegistry cleanup enqueueing. Edge enumeration
//! lives on `Object.traceChildEdgesFallible` and is driven by
//! `gc_trace_stw.traceHeaderEdges`; this module no longer marks anything.

const class = @import("class.zig");
const context_mod = @import("context.zig");
const gc = @import("gc.zig");
const module_mod = @import("module.zig");
const object_mod = @import("object.zig");
const block_heap = @import("gc_block_heap.zig");
const runtime_mod = @import("runtime.zig");
const var_ref_mod = @import("var_ref.zig");
const function_bytecode_mod = @import("../bytecode.zig").function_bytecode;
const FunctionBytecode = function_bytecode_mod.FunctionBytecode;
const Object = object_mod.Object;
const FinalizationRegistryPayload = object_mod.FinalizationRegistryPayload;
const JSRuntime = runtime_mod.JSRuntime;
const JSValue = @import("value.zig").JSValue;
const std = @import("std");

pub fn drainCycleDeferredFrees(rt: *JSRuntime) void {
    _ = drainCycleDeferredFreesBudgeted(rt, std.math.maxInt(usize));
}

inline fn freeCycleDeferredObject(rt: *JSRuntime, h: *gc.Header) void {
    const obj = Object.fromHeader(h);
    // qjs:6803-6806. deinit must still free weak husks (phase != remove_cycles).
    if (gc.phaseIsTwoPassTeardown(rt.gc.phase) and obj.weakReferenceCount() != 0) {
        // Neither pop path clears the dead allocation's links. This is the one
        // branch that keeps the allocation, so finish the detach here.
        gc.setDeferredNext(h, null);
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
    if (!gc.Registry.isBlockCellHeader(self.gcHeader())) return false;
    // `freeCycleDeferredObject` would keep this allocation as a weak husk, and
    // the fast arm would still have to drop a weak-id side-table entry. Both
    // are 0 on all three census workloads, so the exclusion is free.
    if (self.weakReferenceCount() != 0 or self.flags.has_weak_id) return false;

    const cell_addr = @intFromPtr(self.gcHeader()) - gc.metadata_prefix_size;
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
    if (comptime gc.block_tracking_enabled) rt.memory.finishBlockGcRawFree(@intFromPtr(self));
    return true;
}

/// Return up to `budget` parked struct frees to the allocator. Returns true
/// when the queue is empty. The park's only obligation is to outlive every
/// destructor of the same condemned set; once destruction is complete the
/// frees can trickle out across polls -- a single-shot drain of a large
/// morgue was a 6.8 ms pause hiding at the tail of the last slice.
pub fn drainCycleDeferredFreesBudgeted(rt: *JSRuntime, budget: usize) bool {
    const parked = &rt.gc.cycle_deferred_frees;
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
        const kind = h.meta().flags.kind;
        cursor = gc.deferredNextForKind(h, kind);
        remaining -= 1;
        switch (kind) {
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
            // Block suffix: topology proves every entry is an Object.
            cursor = gc.deferredNextForKind(h, .object);
            remaining -= 1;
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

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
const runtime_mod = @import("runtime.zig");
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

pub fn collectCycles(rt: *JSRuntime, extra_roots: ?*const runtime_mod.ValueRootFrame) CollectError!usize {
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
    var collector = try Collector.init(rt, extra_roots);
    defer collector.deinit();
    const swept = try collector.run();
    last_report = collector.report;
    last_report.swept = swept;
    last_report.remaining = rt.gc.liveCount();
    last_report.drained_sweep_debt = drained_sweep_debt;
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
pub fn collectMinor(rt: *JSRuntime, extra_roots: ?*const runtime_mod.ValueRootFrame) CollectError!?usize {
    if (comptime !gc.generation_enabled) return null;
    if (rt.gc.generation.young.count() == 0) return 0;
    const young_before = rt.gc.generation.young.count();

    var collector = try Collector.init(rt, extra_roots);
    defer collector.deinit();

    collector.clearMarks();
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

    const reclaimed = collector.sweepUnmarkedYoung();
    rt.gc.generation.promoteSurvivors(young_before - reclaimed);
    last_report.minor_reclaimed = reclaimed;
    last_report.minor_young_before = young_before;
    return reclaimed;
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

    fn init(rt: *JSRuntime, extra_roots: ?*const runtime_mod.ValueRootFrame) std.mem.Allocator.Error!Collector {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        errdefer arena.deinit();
        return .{
            .rt = rt,
            .extra_roots = extra_roots,
            .arena = arena,
            .work = .empty,
            // Tests link every ValueRootFrame; conservative scan would add
            // non-deterministic stack hits. CLI STW uses containers-only
            // frames plus the conservative scanner (same split as shadow).
            .conservative_on = !builtin.is_test,
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
        var live = self.rt.gc.objectIterator();
        while (live.next()) |_| self.report.allocated_before += 1;

        self.beginSweepModelMark();

        try self.seedRoots();
        try self.drain();
        self.exact_mark_count = self.countMarked();
        self.report.marked_exact = self.exact_mark_count;

        if (self.conservative_on) {
            try self.seedConservativeRoots();
            try self.drain();
            const after = self.countMarked();
            self.report.marked_conservative_extra = after - self.exact_mark_count;
        }

        try self.ephemeronFixedPoint();
        self.processWeak();
        self.endSweepModelMark();
        self.beginSweepModelSweep();
        const swept = self.sweepUnmarked();
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
        var unmarked_bytes: usize = 0;
        var iterator = self.rt.gc.objectIterator();
        while (iterator.next()) |header| {
            if (header.metaConst().flags.mark) continue;
            if (header.metaConst().flags.is_pinned) continue;
            unmarked_bytes +|= gc.Registry.heapByteSizeFromHeader(self.rt, header);
        }
        self.rt.gc.sweep_model.endMark(unmarked_bytes);
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

    fn clearMarks(self: *Collector) void {
        var iterator = self.rt.gc.objectIterator();
        while (iterator.next()) |header| {
            header.meta().flags.mark = false;
        }
    }

    fn countMarked(self: *Collector) usize {
        var n: usize = 0;
        var iterator = self.rt.gc.objectIterator();
        while (iterator.next()) |header| {
            if (header.metaConst().flags.mark) n += 1;
        }
        return n;
    }

    fn shade(self: *Collector, header: *gc.Header) void {
        if (self.err != null) return;
        const addr = @intFromPtr(header);
        if (addr < 4096 or !std.mem.isAligned(addr, @alignOf(gc.Header))) return;
        if (header.meta().flags.mark) return;
        header.meta().flags.mark = true;
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
                if (object.header.metaConst().flags.mark) {
                    if (object.collectionPayloadForCycleGc()) |payload| {
                        for (payload.weak_entries) |*entry| {
                            if (!keyIsMarked(self.rt, entry.key_identity)) continue;
                            const child = entry.value.cycleMarkHeader() orelse continue;
                            if (child.metaConst().flags.mark) continue;
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
            if (holder.header.metaConst().flags.mark) {
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
        var young_it = self.rt.gc.generation.youngIterator();
        while (young_it.next()) |addr| {
            const header: *gc.Header = @ptrFromInt(addr.*);
            if (header.metaConst().flags.mark) continue;
            if (header.metaConst().flags.is_pinned) continue;
            if (header.metaConst().flags.kind != .object) continue;
            // A minor runs while native frames are live, and this collector
            // still shares the heap with refcounting: a young object the trace
            // did not reach may nonetheless be held by native code that has
            // not published a root. Refusing to condemn anything with a live
            // count keeps a minor conservative in the safe direction -- it
            // leaks a young object until the next major rather than freeing
            // one a builtin is still using.
            if (header.metaConst().rc > 0) continue;
            doomed.append(self.allocator(), header) catch return 0;
        }
        for (doomed.items) |header| {
            self.rt.gc.detachCycleCandidate(header);
            gc.listAddTail(&self.rt.gc.tmp_obj_list, header);
        }

        const old_phase = self.rt.gc.phase;
        self.rt.gc.phase = .remove_cycles;
        defer self.rt.gc.phase = old_phase;

        var reclaimed: usize = 0;
        var cursor = self.rt.gc.tmp_obj_list.next;
        while (cursor) |h| {
            if (h == &self.rt.gc.tmp_obj_list) break;
            const next = h.next;
            gc.listDel(h);
            reclaimed += 1;
            Object.destroyFromHeader(self.rt, h);
            cursor = next;
        }
        gc.listInit(&self.rt.gc.tmp_obj_list);

        // Survivors keep their marks: that is what makes them old.
        return reclaimed;
    }

    fn sweepUnmarked(self: *Collector) usize {
        gc.listInit(&self.rt.gc.tmp_obj_list);

        var iterator = self.rt.gc.objectIterator();
        while (iterator.next()) |header| {
            if (header.metaConst().flags.mark) {
                header.meta().flags.mark = false;
                continue;
            }
            if (header.metaConst().flags.is_pinned) continue;
            self.rt.gc.detachCycleCandidate(header);
            gc.listAddTail(&self.rt.gc.tmp_obj_list, header);
        }

        const old_phase = self.rt.gc.phase;
        self.rt.gc.phase = .remove_cycles;
        defer self.rt.gc.phase = old_phase;

        var garbage_count: usize = 0;
        var cursor = self.rt.gc.tmp_obj_list.next;
        while (cursor) |h| {
            if (h == &self.rt.gc.tmp_obj_list) break;
            const next = h.next;
            if (h.meta().flags.kind == .object) {
                gc.listDel(h);
                garbage_count += 1;
                Object.destroyFromHeader(self.rt, h);
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
                context_mod.JSContext.destroyFromHeader(self.rt, h);
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
                module_mod.ModuleRecord.destroyFromHeader(self.rt, h);
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
                function_bytecode_mod.destroyFromHeader(self.rt, h);
            }
            cursor = next;
        }
        while (gc.listFirst(&self.rt.gc.tmp_obj_list)) |h| {
            gc.listDel(h);
            switch (h.meta().flags.kind) {
                .var_ref => {
                    garbage_count += 1;
                    self.rt.gc.unlinkObjectWithBytes(h, gc.Registry.heapByteSizeFromHeader(self.rt, h));
                    var_ref_mod.VarRef.destroyFromHeader(self.rt, h);
                },
                .shape => {
                    garbage_count += 1;
                    if (!h.meta().flags.finalizing) self.rt.shapes.destroyFromHeader(h);
                },
                else => unreachable,
            }
        }

        if (!self.rt.hasPendingDeferredClassPayloadFinalizers()) object_gc.drainCycleDeferredFrees(self.rt);
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
    return object.header.metaConst().flags.mark;
}

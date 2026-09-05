//! The Registry's verification and statistics surface.
//!
//! Everything here READS the collector's state and writes nothing but the
//! statistics block. That is the whole reason it is one file: these are the
//! sixteen functions that legitimately reach across every group -- the pin
//! ledger, the intrusive lists, the morgue, the address registry, the block
//! heap -- and having them in `gc.zig` made cross-group access look like the
//! norm rather than the exception it is.
//!
//! The functions take `*Registry` as their first parameter and are aliased
//! back into `Registry`'s declaration namespace, so every existing
//! `rt.gc.verifyX()` call site is unchanged.

const std = @import("std");

const gc = @import("gc.zig");
const carrier = @import("gc_carrier.zig");
const gc_space = @import("gc_space.zig");
const memory = @import("memory.zig");
const object = @import("object.zig");
const shape = @import("shape.zig");
const string = @import("string.zig");
const class = @import("class.zig");
const var_ref = @import("var_ref.zig");
const registry_lists = @import("gc_registry_lists.zig");
const property = @import("property.zig");
const representation = @import("gc_representation_constants.zig");

const Registry = gc.Registry;
const GCObjectHeader = gc.GCObjectHeader;
const GcKind = gc.GcKind;
const InvariantError = gc.InvariantError;
const CollectionError = gc.CollectionError;
const CollectionResult = gc.CollectionResult;
const PauseDistribution = gc.PauseDistribution;
const Stats = gc.Stats;
const pause_sample_capacity = gc.pause_sample_capacity;
const heapByteSizeFromHeader = Registry.heapByteSizeFromHeader;
const verifyCircularHeaderList = registry_lists.verifyCircularHeaderList;
const verifyMetadataSemantics = gc.verifyMetadataSemantics;
const listEmpty = registry_lists.listEmpty;
const isCycleCandidate = Registry.isCycleCandidate;
const construction_pin_count = gc.construction_pin_count;
const trace_remembered_mask = gc.trace_remembered_mask;
const kindIsOwnedStorageCell = gc.kindIsOwnedStorageCell;
const isBlockCellHeader = Registry.isBlockCellHeader;
const trace_object_shape_summary_mask = gc.trace_object_shape_summary_mask;
const metadata_prefix_size = gc.metadata_prefix_size;
const heap_accounting_oracle_enabled = gc.heap_accounting_oracle_enabled;
const headerCondemned = gc.headerCondemned;
const kindIsBlockCellKind = gc.kindIsBlockCellKind;
const CarrierStateMask = gc.CarrierStateMask;
const BlockHeapMod = @import("gc_block_heap.zig");
const HeapAccountingOracle = gc.HeapAccountingOracle;
const AllocationHandle = gc.AllocationHandle;
const CarrierLifecycleState = gc.CarrierLifecycleState;

/// Percentiles over the retained round durations, or null if no round has
/// completed. Sorts a stack copy: this is a diagnostic call, not a hot
/// path, and sorting in place would reorder the live ring.
pub fn pauseDistribution(self: *const Registry) ?PauseDistribution {
    const retained = @min(self.stats.pause_sample_count, pause_sample_capacity);
    if (retained == 0) return null;
    var scratch: [pause_sample_capacity]u64 = undefined;
    @memcpy(scratch[0..retained], self.stats.pause_samples[0..retained]);
    const window = scratch[0..retained];
    // Percentiles depend only on value order; equal samples have no
    // identity, so the large stable block-sort implementation buys no
    // observable behavior on this cold diagnostic path.
    std.sort.heap(u64, window, {}, std.sort.asc(u64));
    return .{
        .samples = self.stats.pause_sample_count,
        .p50_ns = window[percentileIndex(retained, 50)],
        .p95_ns = window[percentileIndex(retained, 95)],
        .p99_ns = window[percentileIndex(retained, 99)],
        .max_ns = window[retained - 1],
    };
}

/// Nearest-rank index: the smallest sample at or above the percentile.
fn percentileIndex(len: usize, percentile: usize) usize {
    const rank = (len * percentile + 99) / 100;
    return @min(if (rank == 0) 0 else rank - 1, len - 1);
}

pub const HeapSpaceSnapshot = struct {
    heap_live_bytes: usize = 0,
    old_live_bytes: usize = 0,
    large_object_bytes: usize = 0,
    old_count: usize = 0,
    large_count: usize = 0,
};

/// Cold logical-space census. Production publication/free keep no byte
/// ledger: live containers, condemned buckets, and explicit in-finalizer
/// lifecycle slots are the accounting authority, and each header's real
/// allocation size is classified against the current immutable policy.
fn deriveHeapSpaceSnapshot(self: *const Registry, rt: anytype) HeapSpaceSnapshot {
    var derived: HeapSpaceSnapshot = .{};
    var iterator = self.heapAccountingIterator();
    while (iterator.next()) |header| {
        const bytes = heapByteSizeFromHeader(rt, header);
        derived.heap_live_bytes +|= bytes;
        if (self.isLargeAllocation(bytes)) {
            derived.large_object_bytes +|= bytes;
            derived.large_count +|= 1;
        } else {
            derived.old_live_bytes +|= bytes;
            derived.old_count +|= 1;
        }
    }
    return derived;
}

pub fn statsSnapshot(self: *const Registry, rt: anytype) Stats {
    const snapshot = self.*;
    // Walk the Registry's accounting containers, not the by-value
    // snapshot: nodes' links point at live sentinels, not copied headers.
    const heap = deriveHeapSpaceSnapshot(self, rt);
    return .{
        .total_allocated_bytes = heap.heap_live_bytes,
        // The account's real high-water, not live again. This field
        // printed `live` for its whole history, which is why the §1.3
        // peak/live rows had no instrument: peak == live == allocated on
        // every panel ever captured. Whole-account rather than heap-only,
        // which errs on the reporting-more side.
        .peak_allocated_bytes = rt.memory.peak_allocated_bytes,
        .heap_live_bytes = heap.heap_live_bytes,
        .old_live_bytes = heap.old_live_bytes,
        .large_object_bytes = heap.large_object_bytes,
        .old_allocated_bytes = heap.old_live_bytes,
        .old_alloc_count = heap.old_count,
        .large_allocated_bytes = heap.large_object_bytes,
        .large_alloc_count = heap.large_count,
        .external_bytes = snapshot.stats.external_bytes,
        .external_untracked_bytes = snapshot.stats.external_untracked_bytes,
        .peak_external_bytes = snapshot.stats.peak_external_bytes,
        .external_alloc_count = snapshot.stats.external_alloc_count,
        .external_free_count = snapshot.stats.external_free_count,
        .external_token_count = snapshot.external.count(),
        .external_token_bytes = snapshot.external.totalBytes(),
        .external_invalid_release_count = snapshot.stats.external_invalid_release_count,
        .allocation_debt = snapshot.stats.allocation_debt,
        .collections = snapshot.stats.collections,
        .major_gc_count = snapshot.stats.cycle_gc_count,
        .major_gc_time_ns = snapshot.stats.cycle_gc_time_ns,
        .last_collection_time_ns = snapshot.stats.last_collection_time_ns,
        .major_phase = snapshot.scheduler.major_phase,
        .failed_collections = snapshot.stats.failed_collections,
        .last_failure = snapshot.stats.last_failure,
        .freed_objects = snapshot.stats.freed_objects,
        .pinned_cell_count = snapshot.pins.entries.len,
        .gc_request_count = snapshot.stats.gc_request_count,
        .pending_major = snapshot.scheduler.major_request.pending,
        .pending_request_reason = if (snapshot.scheduler.major_request.pending) snapshot.scheduler.major_request.reason else null,
        .pending_request_urgency = if (snapshot.scheduler.major_request.pending) snapshot.scheduler.major_request.urgency else null,
        .last_request_reason = snapshot.stats.last_request_reason,
    };
}

/// Register a freshly allocated header whose prefix and intrusive links are
/// already initialized. Typed MemoryAccount allocations plus their owning
/// constructors provide this invariant, avoiding duplicate hot-path stores.
/// Cross-module representation audit for Object's direct property pointer
/// and allocation-layout marker. This is deliberately a whole-heap audit,
/// never a property-access branch: construction/free, Shape capacity, and
/// block-cell sizing meet here without taxing the paths they protect.
/// Condemned-by-this-cycle test that is valid for every population: the
/// doomed bit for a block cell, the mark-epoch stamp for everything else.
fn ownerCondemned(header: *const GCObjectHeader) bool {
    if (isBlockCellHeader(header)) {
        const block = BlockHeapMod.Block.fromCellTrusted(@intFromPtr(header) - metadata_prefix_size);
        const index = block.cellIndexInterior(@intFromPtr(header)) orelse return false;
        return block.isDoomed(index);
    }
    return headerCondemned(header);
}

pub fn verifyObjectPropertyStorageLayouts(self: *const Registry, rt: anytype) InvariantError!void {
    var iterator = self.objectIterator(.all);
    while (iterator.next()) |header| {
        if (header.metaConst().flags.kind != .object) continue;
        // A corpse condemned by the cycle this audit closes is still
        // published (the destruction slices run later), but its storage may
        // already be gone: a dead array's element EXTENT is returned by the
        // synchronous `sweepExtents` at finish, ahead of the owner's own
        // bitmap reclaim. Only a live owner owes the invariant. Block cells
        // are condemned in the doomed bitmap without a header stamp (S4-d),
        // so the test is the bitmap for them and the stamp for the rest.
        // (pdfjs under ZJS_GC_ARENA_AUDIT tripped this on a 6035-element
        // array, deterministically in one code layout, 2026-09-05.)
        if (ownerCondemned(header)) continue;
        const owner = object.Object.fromHeaderConst(header);
        const slots2 = owner.hasSlots2Layout();
        const storage = owner.prop_values;
        if (@intFromPtr(storage) & (@alignOf(property.Entry) - 1) != 0)
            return error.MisalignedPropertyStorage;

        const has_trailing_allocation = slots2;
        if (has_trailing_allocation) {
            if (owner.class_id != class.ids.object) return error.InvalidTrailingPropertyClass;
            const definition = rt.classes.recordPtr(owner.class_id) orelse
                return error.InvalidTrailingPropertyClass;
            if (definition.inline_payload_size != 0)
                return error.InvalidTrailingPropertyLayout;
            if (owner.propertyStorageIsInline() and
                (owner.shape_ref.prop_size == 0 or
                    owner.shape_ref.prop_size > object.Object.trailing_property_capacity))
            {
                return error.InvalidTrailingPropertyCapacity;
            }
        } else if (owner.propertyStorageIsInline()) {
            return error.InvalidTrailingPropertyLayout;
        }
        // TGC S4-c: a slots2 body's arm word IS its payload slot, so a
        // payload-bearing slots2 object must have spilled its property
        // storage out of line first (`spillInlinePropertyStorageForPayload`).
        // Inline storage plus a payload means the payload pointer and the
        // first property entry are the same eight bytes.
        if (slots2 and owner.flags.class_payload_kind != .none and
            owner.propertyStorageIsInline())
        {
            return error.InvalidSlots2PayloadOwner;
        }
        if (owner.shape_ref.prop_count != 0 and !owner.hasPropertyStorage())
            return error.MissingObjectPropertyStorage;
        // TGC S4-b: an EXTERNAL property buffer is a `.property_storage`
        // GC cell, so the pointer must land on a published cell of that
        // kind. This is the audit that catches an install that skipped
        // `createPropertyStorageCell` (a raw `allocRuntime` buffer has no
        // prefix, so the sweep would read a neighbouring allocation's
        // bytes as a header).
        if (owner.propertyStoragePointerIsExternal(storage)) {
            const cell_header: *const GCObjectHeader = @ptrCast(@alignCast(storage));
            if (!self.containsHeader(cell_header)) return error.DanglingPropertyStorageCell;
            if (cell_header.metaConst().flags.kind != .property_storage)
                return error.InvalidPropertyStorageKind;
        }
        // The dense element buffer answers the same two questions.
        if (owner.flags.fast_array or owner.class_id == class.ids.mapped_arguments) {
            if (owner.arrayArm().*.capacity != 0) {
                const cell_header: *const GCObjectHeader =
                    @ptrCast(@alignCast(owner.arrayArm().*.values));
                if (!self.containsHeader(cell_header)) {
                    // Name the owner: the audit fires long after the write
                    // that caused it, and the class is the first clue to
                    // which adoption path forgot its barrier.
                    // The cell may be unmapped memory by now: name it, do not
                    // read it.
                    std.debug.print(
                        "gc: PROPERTY STORAGE AUDIT: array owner class={d} fast_array={} capacity={d} young={} cell=0x{x}\n",
                        .{ owner.class_id, owner.flags.fast_array, owner.arrayArm().*.capacity, header.metaConst().flags.young, @intFromPtr(cell_header) },
                    );
                    return error.DanglingArrayStorageCell;
                }
                if (cell_header.metaConst().flags.kind != .array_storage)
                    return error.InvalidArrayStorageKind;
            }
        }
        if (owner.shape_ref.prop_count > owner.shape_ref.prop_size)
            return error.InvalidTrailingPropertyCapacity;

        if (isBlockCellHeader(header)) {
            const cell = @intFromPtr(header) - metadata_prefix_size;
            const block = BlockHeapMod.Block.fromCellTrusted(cell);
            const wanted = metadata_prefix_size + owner.allocationSize(rt);
            if (block.cell_size < wanted)
                return error.UndersizedTrailingObjectCell;
            // obj64 ③: the cell width is now a function of `class_id`,
            // and alloc and free each compute it independently. A cell
            // that is merely BIG ENOUGH is not enough: it means the two
            // sides disagreed, and the free will hand the allocator a
            // size class the alloc never took. Demand the exact class.
            const wanted_class = gc_space.classIndexForPayload(wanted) orelse
                return error.ObjectCellSizeClassMismatch;
            const actual_class = gc_space.classIndexForPayload(block.cell_size) orelse
                return error.ObjectCellSizeClassMismatch;
            if (wanted_class != actual_class)
                return error.ObjectCellSizeClassMismatch;
        }
    }
}

pub fn recordFailure(self: *Registry, err: CollectionError) void {
    self.stats.failed_collections += 1;
    self.stats.last_failure = switch (err) {
        error.OutOfMemory => .out_of_memory,
        error.PayloadMarkFailed => .payload_mark_failed,
    };
}

pub fn recordSuccess(self: *Registry, result: CollectionResult) void {
    self.stats.last_failure = .none;
    self.stats.last_collection_time_ns = result.duration_ns;
    self.stats.cycle_gc_count +|= 1;
    self.stats.cycle_gc_time_ns +|= result.duration_ns;
    self.stats.freed_objects +|= result.freed_objects;
    recordPauseSample(self, result.duration_ns);
}

/// One STW slice of an incremental major cycle: begin, an increment, or
/// the final remark. Each is its own sample in the major ring -- the ring
/// answers "how long does this collector stop the world at once", and an
/// incremental cycle stops it many times briefly. The per-cycle total is
/// accumulated separately for §1.3's cumulative-STW row.
pub const SliceKind = enum(u2) { begin, increment, destroy, finish };

pub fn recordMajorSlicePause(self: *Registry, ns: u64, kind: SliceKind) void {
    recordPauseSample(self, ns);
    self.incremental.cycle_stw_ns += ns;
    const slot = &self.incremental.stats.segment_max_ns[@intFromEnum(kind)];
    if (ns > slot.*) slot.* = ns;
    self.incremental.stats.total_stw_by_kind[@intFromEnum(kind)] +|= ns;
    self.incremental.stats.total_segments_by_kind[@intFromEnum(kind)] +|= 1;
}

/// Cycle-completion accounting for an incremental major. Mirrors
/// `recordSuccess` minus the ring push: the slices already recorded
/// themselves, and pushing the cycle total as one more sample would count
/// the same nanoseconds twice.
pub fn recordIncrementalCycleSuccess(self: *Registry, result: CollectionResult) void {
    self.finishCycleEnvelope();
    self.stats.last_failure = .none;
    self.stats.cycle_gc_count +|= 1;
    self.stats.freed_objects +|= result.freed_objects;
    const total = self.incremental.cycle_stw_ns;
    // `result.duration_ns` is intentionally the completion poll's
    // pause for the host-facing call. The stats fields promise major
    // collection time, so they own the whole cycle's accumulated STW.
    self.stats.last_collection_time_ns = total;
    self.stats.cycle_gc_time_ns +|= total;
    self.incremental.stats.last_cycle_stw_ns = total;
    if (total > self.incremental.stats.max_cycle_stw_ns) {
        self.incremental.stats.max_cycle_stw_ns = total;
    }
    self.incremental.cycle_stw_ns = 0;
}

/// Credit a MINOR collection without putting its pause in the major ring.
///
/// The two populations differ by more than an order of magnitude -- a minor
/// is judged on being short, a major on bounding the whole heap -- so
/// mixing them makes the percentile panel report the wrong thing entirely.
/// A run doing 90% minors printed a p50 of 758us against a true major
/// median of 16.45ms, and the target it is checked against
/// (`docs/tracing-gc-design.md` §1.3) is a major target. The minor's own
/// distribution lives in `generation.stats`.
pub fn recordMinorSuccess(self: *Registry, result: CollectionResult) void {
    self.stats.last_failure = .none;
    self.stats.freed_objects +|= result.freed_objects;
}

fn recordPauseSample(self: *Registry, duration_ns: u64) void {
    self.stats.pause_samples[self.stats.pause_sample_cursor] = duration_ns;
    self.stats.pause_sample_cursor = (self.stats.pause_sample_cursor + 1) % pause_sample_capacity;
    self.stats.pause_sample_count +|= 1;
}

pub fn verifyIntrusiveList(self: *Registry) InvariantError!void {
    try verifyAuxiliaryIntrusiveLists(self);
    _ = try verifyCircularHeaderList(&self.lists.objects, null, true);

    var saw_young_head = false;
    const sentinel = &self.lists.objects.sentinel;
    var current = sentinel.next_non_object;
    var previous: *GCObjectHeader = sentinel;
    while (current) |h| {
        if (h == sentinel) break;
        // The young set is exactly the suffix starting at
        // `young_head`. Checking membership alone is not enough: a
        // stranded anchor whose slab has been recycled points at a
        // live list member again, so "found it" proves nothing. The
        // suffix shape does prove it -- a recycled anchor lands in
        // the wrong place and one of the two halves fails.
        if (self.lists.young_head == h) {
            if (self.lists.young_predecessor != previous) return error.DanglingYoungHead;
            saw_young_head = true;
        }
        const is_young = h.metaConst().flags.young;
        if (self.lists.young_head != null) {
            if (!saw_young_head and is_young) return error.DanglingYoungHead;
            if (saw_young_head and !is_young) return error.DanglingYoungHead;
        } else if (is_young) return error.DanglingYoungHead;
        if (!isCycleCandidate(h) or h.metaConst().flags.kind == .object)
            return error.CorruptGcList;
        {
            const state = h.metaConst().lifetime;
            if (state.flags.reserved != 0 or state.mark_epoch > self.marking.header_epoch)
                return error.InvalidHeaderState;
            // Every list member is an eligible carrier (the range gate is
            // the cycle-candidate set), so bit7 is legitimately theirs;
            // only the Object-owned low seven bits must be clear here.
            if (h.metaConst().flags.kind != .object and
                state.object_shape_summary & trace_object_shape_summary_mask != 0)
                return error.InvalidHeaderState;
        }
        // No "mark bit left set" check here: sticky generations keep a
        // survivor's mark bit between collections as the record of "this
        // is old now" (§8.2), so a set mark outside a collection is normal.
        const next = h.nextNonObject() orelse return error.CorruptGcList;
        previous = h;
        current = next;
    }
    // Free-standing check rather than an assert at each detach: the walk
    // above is already paying for the traversal, and a stale anchor is
    // only observable as a crash one collection later.
    if (self.lists.young_head != null and !saw_young_head) return error.DanglingYoungHead;
    if (self.lists.young_head == null and self.lists.young_predecessor != null) return error.DanglingYoungHead;

    const nonblock_items = if (self.nonblock_objects) |authority|
        authority.items.items
    else
        &.{};
    for (nonblock_items, 0..) |header, index| {
        const meta = header.metaConst();
        if (meta.flags.kind != .object or isBlockCellHeader(header) or
            !meta.alloc_info.heap_accounted or headerCondemned(header))
        {
            return error.CorruptNonBlockObjectAuthority;
        }
        for (nonblock_items[0..index]) |previous_object| {
            if (previous_object == header) return error.CorruptNonBlockObjectAuthority;
        }
    }
}

fn verifyAuxiliaryIntrusiveLists(self: *Registry) InvariantError!void {
    var doomed_nodes: usize = 0;
    var cursor_found = self.morgue.cursor == null;
    for (&self.morgue.by_kind, 0..) |*head, kind_index| {
        const kind: GcKind = @enumFromInt(kind_index);
        if (kind == .object and !listEmpty(head))
            return error.CorruptNonBlockObjectAuthority;
        doomed_nodes += try verifyCircularHeaderList(head, kind, false);
        if (!cursor_found) {
            var node = head.sentinel.next_non_object;
            while (node) |candidate| {
                if (candidate == &head.sentinel) break;
                if (candidate == self.morgue.cursor.?) cursor_found = true;
                node = candidate.nextNonObject();
            }
        }
    }
    if (!cursor_found) return error.DoomedCursorMismatch;

    if (self.nonblock_objects) |authority| {
        const live = authority.items.items;
        const doomed = authority.doomed.items;
        for (doomed, 0..) |header, index| {
            const meta = header.metaConst();
            if (meta.flags.kind != .object or isBlockCellHeader(header) or
                !meta.alloc_info.heap_accounted or !headerCondemned(header))
            {
                return error.CorruptNonBlockObjectAuthority;
            }
            for (live) |candidate| if (candidate == header)
                return error.CorruptNonBlockObjectAuthority;
            for (doomed[0..index]) |candidate| if (candidate == header)
                return error.CorruptNonBlockObjectAuthority;
        }
    }

    const block_doomed = self.block_heap.doomed_blocks != null;
    const doomed_objects = if (self.nonblock_objects) |authority|
        authority.doomed.items.len != 0
    else
        false;
    if ((doomed_nodes != 0 or block_doomed or self.morgue.cursor != null or doomed_objects) and
        !self.morgue.pending and self.hot.phase != .tracer_destroy)
    {
        return error.DoomedPendingMismatch;
    }
}

/// Check the reserved pin-ledger entries that protect detached generator
/// shells. The sentinel must never bless a published, non-block, partially
/// initialized, or wrong-class header as the BlockHeap publication
/// exception.
pub fn verifyConstructionRoots(self: *const Registry) InvariantError!void {
    for (self.pins.entries) |entry| {
        if (entry.count != construction_pin_count) continue;
        if (!self.pins.isConstructionRoot(entry.header)) {
            return error.ConstructionRootStateMismatch;
        }
        try verifyMetadataSemantics(entry.header.metaConst(), .object, .construction_block_object);
    }
}

fn verifyPublishedHeaderRepresentation(
    self: *const Registry,
    header: *const GCObjectHeader,
    expected_kind: ?GcKind,
) InvariantError!void {
    const meta = header.metaConst();
    const kind = expected_kind orelse meta.flags.kind;
    verifyMetadataSemantics(meta, kind, .registry_published) catch |err| {
        std.debug.print(
            "gc: REPRESENTATION HEADER population={s} header=0x{x} kind={s} size_class={d} alloc_info=0x{x:0>2} flags=0x{x:0>2} lifetime=0x{x:0>8} error={s}\n",
            .{
                if (expected_kind == null) "live" else "doomed",
                @intFromPtr(header),
                @tagName(kind),
                meta.size_class,
                @as(u8, @bitCast(meta.alloc_info)),
                @as(u8, @bitCast(meta.flags)),
                @as(u32, @bitCast(meta.lifetime)),
                @errorName(err),
            },
        );
        return err;
    };

    if (kind == .object) {
        const owner = object.Object.fromHeaderConst(header);
        if (!owner.traceShapeSummaryMatches())
            return error.ObjectShapeSummaryMismatch;
    }
    // bit=1 => map=1, for EVERY carrier that leases the bit (audit §10).
    // Keeping this outside the `.object` arm is the point of the widening:
    // a cache bit no auditor can see is a cache bit with no soundness
    // evidence behind it, and `.shape`/`.var_ref` are where the traffic is.
    const cached = meta.lifetime.object_shape_summary & trace_remembered_mask != 0;
    if (cached and !self.generation.remembered.contains(@intFromPtr(header)))
        return error.RememberedCacheWithoutOwner;

    const cell_addr = @intFromPtr(header) - metadata_prefix_size;
    const physical_block = self.block_heap.blockOf(@ptrFromInt(cell_addr));
    const stamped_block = meta.alloc_info.block_size_idx == representation.block_cell_size_class;
    if ((physical_block != null) != stamped_block)
        return error.RepresentationAllocationCarrierMismatch;
    if (physical_block) |block| {
        if (!kindIsBlockCellKind(kind))
            return error.RepresentationAllocationCarrierMismatch;
        const actual_index = block.cellIndex(cell_addr) orelse
            return error.RepresentationCellIndexMismatch;
        if (meta.size_class != actual_index or !block.cellAllocated(actual_index))
            return error.RepresentationCellIndexMismatch;
    }
}

/// Whole-runtime representation audit.  It covers both publication
/// populations: the ordinary list plus bitmap-enumerated block cells, and
/// the non-block doomed buckets that have been detached from that list but
/// whose prefixes remain live until sliced destruction finishes. Call only
/// at stable boundaries: remembered-map retirement clears each carrier's
/// cache bit before clearing the map, so the two representations must agree
/// in both directions whenever this checker runs.
pub fn verifyRepresentationInvariants(self: *const Registry) InvariantError!void {
    var live = self.objectIterator(.all);
    while (live.next()) |header| {
        try verifyPublishedHeaderRepresentation(self, header, null);
    }
    for (&self.morgue.by_kind, 0..) |*head, kind_index| {
        const expected: GcKind = @enumFromInt(kind_index);
        var cursor = head.sentinel.next_non_object;
        while (cursor) |header| {
            if (header == &head.sentinel) break;
            try verifyPublishedHeaderRepresentation(self, header, expected);
            cursor = header.nextNonObject();
        }
    }
    if (self.nonblock_objects) |authority| {
        for (authority.doomed.items) |header| {
            try verifyPublishedHeaderRepresentation(self, header, .object);
        }
    }
    var remembered = self.generation.rememberedIterator();
    while (remembered.next()) |addr| {
        const header: *GCObjectHeader = @ptrFromInt(addr.*);
        if (!self.address_registry.containsHeader(header))
            return error.RememberedOwnerNotLive;
        // map=1 => bit=1, the other direction. Widened with the cache
        // itself: an eligible resident whose bit is clear is precisely
        // the state that makes `forgetUnremembered` strand a dangling
        // address, so the checker must cover every leasing kind.
        if (header.metaConst().lifetime.object_shape_summary & trace_remembered_mask == 0) {
            return error.RememberedOwnerMissingCache;
        }
    }
}

/// Check the sticky-generation census and remembered-owner roots at a
/// stable collection boundary. A stale remembered address is dereferenced
/// by the next minor; an under-count silently postpones that minor.
pub fn verifyGenerationInvariants(self: *Registry) InvariantError!void {
    var actual_young: usize = 0;
    var actual_trigger: usize = 0;
    var young = self.objectIterator(.young);
    while (young.next()) |header| {
        actual_young += 1;
        if (!kindIsOwnedStorageCell(header.metaConst().flags.kind)) actual_trigger += 1;
    }
    // The extent half of the young set is in no young carrier, so the
    // iterator above cannot see it (`markPublishedYoungClassified`).
    // Count it from the extent tables rather than from
    // `Heap.young_extents`, which tolerates stale/duplicate bases.
    var extents = self.block_heap.extentKeys();
    while (extents.next()) |base| {
        const header: *const GCObjectHeader = @ptrFromInt(base + metadata_prefix_size);
        if (header.metaConst().flags.young) {
            actual_young += 1;
            if (!kindIsOwnedStorageCell(header.metaConst().flags.kind)) actual_trigger += 1;
        }
    }
    if (actual_young != self.generation.stats.young_count) return error.YoungCountMismatch;
    // The trigger census is what schedules minors, so a drift in it is a
    // scheduling bug that no other checker would see (S4-f (1)).
    if (actual_trigger != self.generation.stats.young_trigger_count) return error.YoungCountMismatch;
    var remembered = self.generation.remembered.keyIterator();
    while (remembered.next()) |addr| {
        const header: *GCObjectHeader = @ptrFromInt(addr.*);
        if (!self.address_registry.containsHeader(header)) return error.RememberedOwnerNotLive;
        if (header.metaConst().flags.young) return error.RememberedOwnerYoung;
    }
}

/// A successful major commit must close the trace-coupled retirement
/// transaction and leave no survivor in the young population.
pub fn verifyMajorRetirementCommit(self: *Registry) InvariantError!void {
    if (self.generation.major_retirement != .clean or
        self.lists.young_head != null or
        self.lists.young_predecessor != null or
        self.generation.stats.young_count != 0 or
        self.generation.remembered.count() != 0)
    {
        return error.RetirementStateMismatch;
    }
    if (self.block_heap.young_blocks != null) return error.RetirementStateMismatch;
    // `clearYoungState` promotes and empties the extent half of the
    // young set; a leftover entry is a young extent nothing will ever
    // retire (the state the lane-C audit found).
    if (self.block_heap.young_extents.items.len != 0) return error.RetirementStateMismatch;
    var survivors = self.objectIterator(.all);
    while (survivors.next()) |header| {
        if (!header.metaConst().flags.young) continue;
        if (self.headerMarked(header) or self.headerIsPinned(header)) {
            return error.RetirementYoungSurvivor;
        }
    }
}

pub fn verifyHeapAccounting(self: *const Registry, rt: anytype) InvariantError!void {
    if (comptime carrier.extent_identity_enabled) {
        self.memory.gc_extent_identity.verify() catch return error.CarrierOldNewMismatch;
    }
    if (comptime carrier.lifecycle_state_enabled) {
        self.memory.gc_extent_lifecycle.verify() catch return error.CarrierOldNewMismatch;
    }
    if (comptime carrier.block_generation_enabled) {
        self.block_heap.verifyGenerationAuthority() catch return error.CarrierOldNewMismatch;
    }
    // The extent page index is what makes a conservative candidate
    // resolve to a >128-byte string; a hole in it drops a live root.
    self.block_heap.verifyExtentPageIndex() catch return error.CarrierOldNewMismatch;
    // The medium free-run buckets are the allocator's only view of
    // free page runs. A run cached above the bitmap's truth hands the
    // same pages to two extents.
    self.block_heap.verifyMediumBuckets() catch return error.CarrierOldNewMismatch;
    if (comptime carrier.lifecycle_state_enabled) {
        self.block_heap.verifyLifecycleAuthority() catch return error.CarrierOldNewMismatch;
        self.block_heap.verifyAccountingCellsAllowing(
            representation.block_cell_size_class,
            @as(u3, @intCast(@intFromEnum(GcKind.object))),
            .{
                .context = @ptrCast(self),
                .classify = Registry.blockCellAccountingAllowance,
            },
        ) catch return error.MissingHeapAllocation;
    }

    var heap_live_bytes: usize = 0;
    var old_live_bytes: usize = 0;
    var large_object_bytes: usize = 0;

    var iterator = self.heapAccountingIterator();
    while (iterator.next()) |header| {
        if (!header.metaConst().alloc_info.heap_accounted) return error.MissingHeapAllocation;
        if (self.headerIsPinned(header) and self.pins.indexOf(header) == null) {
            return error.PinnedHeaderMissingEntry;
        }
        const bytes = heapByteSizeFromHeader(rt, header);
        if (bytes == 0) return error.MissingHeapAllocation;
        const is_large = self.isLargeAllocation(bytes);
        heap_live_bytes = std.math.add(usize, heap_live_bytes, bytes) catch std.math.maxInt(usize);
        if (is_large) {
            large_object_bytes = std.math.add(usize, large_object_bytes, bytes) catch std.math.maxInt(usize);
        } else {
            old_live_bytes = std.math.add(usize, old_live_bytes, bytes) catch std.math.maxInt(usize);
        }
        if (comptime heap_accounting_oracle_enabled) {
            const raw = self.heap_accounting_oracle.raw.get(@intFromPtr(header)) orelse
                return error.CarrierRawOwnedMismatch;
            if (!raw.published) return error.CarrierOldNewMismatch;
            if (raw.accounted_bytes != bytes) return error.CarrierByteMismatch;
            if (comptime carrier.authority_audit_enabled) {
                const handle = self.allocationHandle(header) orelse return error.CarrierOldNewMismatch;
                const resolved = self.resolveExact(
                    handle,
                    header.metaConst().flags.kind,
                    CarrierStateMask.publishedOnly(),
                ) catch return error.CarrierOldNewMismatch;
                if (resolved.tracing != header) return error.CarrierOldNewMismatch;
                if (raw.generation != handle.generation) return error.CarrierGenerationMismatch;
            }
        }
    }

    for (self.pins.entries, 0..) |entry, index| {
        if (entry.count == 0) return error.EmptyPinEntry;
        if (entry.count == construction_pin_count) {
            if (!self.pins.isConstructionRoot(entry.header)) {
                return error.ConstructionRootStateMismatch;
            }
        } else if (!self.containsHeader(entry.header)) return error.PinEntryNotLive;
        if (!self.headerIsPinned(entry.header)) return error.PinnedHeaderFlagMismatch;
        for (self.pins.entries[0..index]) |previous| {
            if (previous.header == entry.header) return error.DuplicatePinEntry;
        }
    }

    var external_token_bytes: usize = 0;
    for (self.external.entries, 0..) |entry, index| {
        if (entry.id == 0 or entry.bytes == 0) return error.EmptyExternalMemoryToken;
        for (self.external.entries[0..index]) |previous| {
            if (previous.id == entry.id) return error.DuplicateExternalMemoryToken;
        }
        external_token_bytes = std.math.add(usize, external_token_bytes, entry.bytes) catch std.math.maxInt(usize);
    }

    // The expected value is lifecycle-maintained, not another instance of
    // the ownership iterator above. An accounted header that loses every
    // owner container must therefore leave the walk short and fail here.
    if (comptime heap_accounting_oracle_enabled) {
        const oracle = &self.heap_accounting_oracle;
        if (heap_live_bytes != oracle.heap_live_bytes) return error.HeapLiveBytesMismatch;
        if (old_live_bytes != oracle.old_live_bytes) return error.OldLiveBytesMismatch;
        if (large_object_bytes != oracle.large_object_bytes) return error.LargeObjectBytesMismatch;

        if (comptime carrier.authority_audit_enabled) {
            // independent raw -> new owned authority
            var raw_it = oracle.raw.valueIterator();
            while (raw_it.next()) |raw| {
                const handle = self.allocationHandle(@ptrFromInt(raw.base)) orelse
                    return error.CarrierRawOwnedMismatch;
                if (handle.generation != raw.generation) return error.CarrierGenerationMismatch;
                if (raw.published) {
                    _ = self.resolveExact(
                        handle,
                        null,
                        CarrierStateMask.publishedOnly(),
                    ) catch return error.CarrierOldNewMismatch;
                }
            }
        }

        // new extent authority -> independent raw
        if (comptime carrier.extent_identity_enabled) {
            var extent_it = self.memory.gc_extent_identity.records.valueIterator();
            while (extent_it.next()) |record| {
                const raw = oracle.raw.get(record.base) orelse return error.CarrierRawOwnedMismatch;
                if (raw.generation != record.generation) return error.CarrierGenerationMismatch;
                if (raw.raw_base != record.raw_base or raw.raw_bytes != record.raw_bytes) {
                    return error.CarrierByteMismatch;
                }
            }
        }
        if (comptime carrier.lifecycle_state_enabled) {
            var lifecycle_it = self.memory.gc_extent_lifecycle.records.iterator();
            while (lifecycle_it.next()) |entry| {
                const raw = oracle.raw.get(entry.key_ptr.*) orelse return error.CarrierRawOwnedMismatch;
                if (raw.published and raw.accounted_bytes != entry.value_ptr.accounted_bytes) {
                    return error.CarrierByteMismatch;
                }
            }
        }

        const BlockAudit = struct {
            oracle: *const HeapAccountingOracle,
            mismatch: ?InvariantError = null,
            fn visit(raw_context: *anyopaque, handle: AllocationHandle, _: CarrierLifecycleState) void {
                const audit: *@This() = @ptrCast(@alignCast(raw_context));
                const raw = audit.oracle.raw.get(handle.base) orelse {
                    audit.mismatch = error.CarrierRawOwnedMismatch;
                    return;
                };
                if (raw.generation != handle.generation) audit.mismatch = error.CarrierGenerationMismatch;
            }
        };
        if (comptime carrier.block_generation_enabled and carrier.lifecycle_state_enabled) {
            var block_audit: BlockAudit = .{ .oracle = oracle };
            self.block_heap.forEachOwnedIdentity(metadata_prefix_size, &block_audit, BlockAudit.visit);
            if (block_audit.mismatch) |err| return err;
        }
    }
    const accounted_external_bytes = std.math.add(usize, external_token_bytes, self.stats.external_untracked_bytes) catch std.math.maxInt(usize);
    if (accounted_external_bytes != self.stats.external_bytes) return error.ExternalTokenBytesMismatch;
}

/// Diagnostic/test-only: derived by walking, exactly like `liveCountKind`.
/// The hot alloc/free paths keep no live-object counter (qjs
/// add_gc_object/remove_gc_object are pure list splices).
pub fn liveCount(self: *const Registry) usize {
    var count: usize = 0;
    var iterator = self.objectIterator(.all);
    while (iterator.next()) |_| count += 1;
    return count;
}

pub fn liveCountKind(self: *const Registry, kind: GcKind) usize {
    var count: usize = 0;
    var iterator = self.objectIterator(.all);
    while (iterator.next()) |header| {
        if (header.metaConst().flags.kind == kind) count += 1;
    }
    return count;
}

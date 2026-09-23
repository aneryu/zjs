//! Registry-owned GC cell allocation, layout, storage routing, and carrier audit.
//! Constructors initialize semantic fields; Registry publication owns heap charges.
//! Native allocations are handled by Runtime and cannot enter these typed routes.
const gc_alloc = @This();
const runtime_owner = @import("../runtime.zig");
const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const Registry = @import("gc.zig").Registry;
const native_alloc = @import("../runtime_alloc.zig");
const diagnostic_accounting_enabled = native_alloc.diagnostic_accounting_enabled;
const oom_coverage_enabled = native_alloc.oom_coverage_enabled;
const oom_coverage = native_alloc.oom_coverage;
const allocation_gc_trigger_enabled = native_alloc.allocation_gc_trigger_enabled;

const gc_representation = @import("gc_representation_constants.zig");

const gc_block_heap = @import("gc_block_heap.zig");

const gc_nursery_mod = @import("gc_nursery.zig");

const gc_storage = @import("gc_storage.zig");

const gc_carrier = @import("gc_carrier.zig");

const carrier_audit_enabled = gc_carrier.audit_enabled;

/// OOM-injection topology, gated by the `oom_injection` build option
/// (`build/config.zig`), which only the `test-oom` step sets.
///
/// When on, the pools the tracing collector allocates out of -- the block
/// heap's superblocks and extents, and the small-object slab arenas -- take
/// their memory from `backing_allocator` instead of from an
/// independent allocator, which is what makes their allocations reachable by
/// `std.testing.checkAllAllocationFailures` and the fail-at-N allocators.
///
/// It used to be `builtin.is_test`, which handed the WHOLE unit suite an
/// allocator topology the shipped build never has. The injection surface is
/// the only thing that changes here, so it belongs to the one tier that uses
/// it.
pub const oom_injection_enabled: bool = build_options.zjs_oom_injection;

/// Issue the next slab pop's block-header fetch one allocation early.
///
/// The free chain qjs threads through the free blocks themselves
/// (`JSMallocBlockHeader.u.next_block`, quickjs.c) costs one load per pop,
/// and that load's result is what names the *following* pop's block -- so
/// without this it cannot start until the caller has finished initializing the
/// previous object.
///
/// Under refcounting that load is free and this would be pure cost: the alloc
/// side cycles a handful of arenas that never leave L1/L2 (measured on splay:
/// 4.8 free arenas per class, 16.6% of arena switches return to one of the
/// last 8 that class used). Under tracing the identical code walks a set two
/// orders of magnitude larger -- 2,733 free arenas per class, 0.04% revisits
/// -- because a sweep leaves thousands of arenas partially free at once and
/// the alloc side then drains each exactly once. Every arena visit lands on a
/// cold page and the chain becomes a serial run of cold dependent loads:
/// 80.4% of `allocAlignedBytesNoTrigger`'s self cycles and sixty times rc's
/// L2D refill count.
///
/// Measurements, and the two heavier designs this was chosen over, live
/// in git history (2026-08-29 slab-reuse account).
const slab_alloc_prefetch: bool = true;

/// qjs `MALLOC_OVERHEAD`: 0 on Apple, 8 elsewhere.
/// Added to every `js_malloc` usable size in `js_def_malloc`.
pub const malloc_overhead: usize = if (builtin.os.tag.isDarwin()) 0 else 8;

pub const SmallObjectSlab = @import("gc_slab.zig").Slab;

/// qjs `js_def_malloc` / `js_def_free`:
/// `malloc_size ±= js_def_malloc_usable_size(ptr) + MALLOC_OVERHEAD`.
///
/// Slab: `__js_malloc_usable_size` is `block_size - header`
///. Plus `MALLOC_OVERHEAD` that equals the class
/// size on Linux (96/112/…), which is what we charge. Standalone / large
/// have no class; charge the backing request. Adding another
/// `MALLOC_OVERHEAD` there would double-count the 8-byte GC prefix that
/// standalone already folds into `request_bytes`.
pub fn accountedMallocSize(request_bytes: usize, slab_class: ?usize) usize {
    if (slab_class) |index| {
        const usable = SmallObjectSlab.blockSize(index) - SmallObjectSlab.block_header_bytes;
        return usable + malloc_overhead;
    }
    return request_bytes;
}

/// Charge for a request that may land in the slab (`classIndex` is private).
pub fn accountedSizeForRequest(request_bytes: usize, alignment: std.mem.Alignment) usize {
    return accountedMallocSize(request_bytes, SmallObjectSlab.classIndex(request_bytes, alignment));
}

/// Pop a block from an already-available free arena of `index`'s class, or
/// null when the class has no free arena (caller falls back to the slow
/// twin, which builds a new arena / routes to the backing allocator).
/// Inline: this is the entire qjs `__js_malloc` small-block hot arm.
inline fn slabPopHot(self: *Registry, index: usize, comptime stamp_class: bool) ?[*]u8 {
    const arena = self.cell_storage.slab.free_arenas[index] orelse return null;
    return self.cell_storage.slab.popFreeBlock(arena, index, stamp_class);
}

/// Type-erased layout shared by fixed-size and variable-FAM GC cold paths.
const SlowLayout = struct {
    /// Whole GC payload: `@sizeOf(T) + fam_bytes`.
    payload_bytes: usize,
    alignment: std.mem.Alignment,
    /// `gcPrefixSize(T)` for a GC kind served standalone, else 0.
    standalone_prefix: usize,
    kind_tag: u8,
    trigger_gc: bool,
};

/// Shared GC cold path: admission, storage, prefix, and raw carrier audit.
/// The constructor still owns initialization and Registry publication.
noinline fn allocSlowErased(self: *Registry, l: SlowLayout) ![*]u8 {
    const slab_index = if (self.cell_storage.slab_enabled)
        SmallObjectSlab.classIndex(l.payload_bytes, l.alignment)
    else
        null;
    const prefix = if (slab_index != null) 0 else l.standalone_prefix;
    const bytes = prefix + l.payload_bytes;
    try admitHeapCharge(self, l.payload_bytes, l.trigger_gc);
    try native_alloc.checkAllocation(self.runtime.?, bytes);
    if (l.trigger_gc) {
        noteAllocProbe(self, l.payload_bytes);
    }
    const track_extent = carrier_audit_enabled;
    const carrier_reservation = if (comptime track_extent) try reserveGcExtent(self) else {};
    const raw = try rawAllocForGc(self, bytes, l.alignment, slab_index);
    const obj_addr = @intFromPtr(raw) + prefix;
    initGcPrefixTagged(l.kind_tag, @ptrFromInt(obj_addr - gc_prefix_size), slab_index);
    creditAlloc(self, if (slab_index != null) l.payload_bytes else bytes, slab_index);
    if (comptime track_extent) {
        commitGcExtent(
            self,
            carrier_reservation,
            obj_addr,
            @intFromPtr(raw),
            l.payload_bytes,
            bytes,
            l.payload_bytes,
            l.kind_tag,
        );
    }
    native_alloc.noteAllocDiagnostics(self.runtime.?, true);
    return @ptrFromInt(obj_addr);
}

/// Returns owned memory. Caller must destroy it with `destroy`.
pub inline fn create(self: *Registry, comptime T: type) !*T {
    return createInternal(self, T, 0, true, false);
}

/// Skips allocation probes and GC retry, but still checks the heap limit.
/// The caller owns any GC preparation and subsequent publication.
pub inline fn createNoTrigger(self: *Registry, comptime T: type) !*T {
    return createInternal(self, T, 0, false, false);
}

/// Object-only path: Registry reserves non-block membership before taking
/// compatibility storage. The successful block path needs no such reservation.
pub inline fn createObjectConstFamNoTrigger(
    self: *Registry,
    comptime T: type,
    comptime fam_bytes: usize,
) !*T {
    comptime std.debug.assert(T.gc_kind_tag == gc_representation.object_kind_tag);
    return createInternal(self, T, fam_bytes, false, true);
}

/// Size of GC metadata immediately before every GC object. Small slab
/// allocations overlay it on the slab block header; other allocations
/// reserve a standalone prefix. MUST equal `@sizeOf(gc.Metadata)`.
const gc_prefix_size: usize = gc_representation.metadata_size;

/// Total leading bytes reserved before a GC object so that (a) the 8-byte
/// `Metadata` lands at `objectPtr - 8` (where `BlockHeader.meta()` looks) and
/// (b) the object stays `@alignOf(T)`-aligned. For align<=8 types this is 8;
/// for genuinely over-aligned GC payloads it rounds up to their alignment.
inline fn gcPrefixSize(comptime T: type) usize {
    return comptime std.mem.alignForward(usize, gc_prefix_size, @alignOf(T));
}

inline fn gcAlignment(comptime T: type) std.mem.Alignment {
    return comptime if (@alignOf(T) > gc_prefix_size) std.mem.Alignment.of(T) else std.mem.Alignment.fromByteUnits(gc_prefix_size);
}

inline fn gcSlabClassIndex(self: *const Registry, payload_bytes: usize, alignment: std.mem.Alignment) ?usize {
    if (!self.cell_storage.slab_enabled) return null;
    return SmallObjectSlab.classIndex(payload_bytes, alignment);
}

inline fn rawAllocForGc(self: *Registry, bytes: usize, alignment: std.mem.Alignment, slab_index: ?usize) ![*]u8 {
    if (slab_index) |index| return self.cell_storage.slab.allocAtIndex(self.allocator, index, false);
    return self.allocator.rawAlloc(bytes, alignment, @returnAddress()) orelse error.OutOfMemory;
}

/// Allocate an old-generation cell for a young survivor.
///
/// Promotion is an allocation and owes what every allocation owes: the
/// limit check, the byte credit, the carrier raw-ledger entry the
/// publication will look for, and the diagnostics. Null means the old
/// generation declined, which the caller answers by retaining the page
/// instead of by failing.
pub fn allocPromotedObjectCell(self: *Registry, request: usize) ?[*]u8 {
    const heap = objectCellHeap(self) orelse return null;
    const accounted = gc_block_heap.accountedBodyBytesForRequest(request, gc_prefix_size) orelse return null;
    admitHeapCharge(self, accounted, false) catch return null;
    native_alloc.checkAllocation(self.runtime.?, accounted) catch return null;
    if (comptime carrier_audit_enabled) prepareGcRawAudit(self) catch return null;
    const cell = (heap.allocCell(request) catch return null) orelse return null;
    creditAlloc(self, accounted, null);
    if (comptime carrier_audit_enabled) {
        recordBlockGcAllocation(self, @intFromPtr(cell) + gc_prefix_size, accounted);
    }
    native_alloc.noteAllocDiagnostics(self.runtime.?, true);
    return cell;
}

fn prepareGcRawAudit(self: *Registry) !void {
    if (comptime carrier_audit_enabled) {
        if (gcCarrier(self).heap_oracle) |oracle| try oracle.prepareRawAlloc(std.heap.page_allocator);
    }
}

pub fn reserveGcExtent(self: *Registry) !gc_carrier.ExtentReservation {
    comptime std.debug.assert(carrier_audit_enabled);
    try prepareGcRawAudit(self);
    if (comptime carrier_audit_enabled) {
        try gcCarrier(self).extent_lifecycle.prepare(std.heap.page_allocator);
    }
    if (comptime carrier_audit_enabled) {
        return gcCarrier(self).extent_identity.reserve(std.heap.page_allocator);
    }
    return .{ .generation = 0 };
}

pub fn commitGcExtent(
    self: *Registry,
    reservation: gc_carrier.ExtentReservation,
    base: usize,
    raw_base: usize,
    payload_bytes: usize,
    raw_bytes: usize,
    accounted_bytes: usize,
    kind: u8,
) void {
    comptime std.debug.assert(carrier_audit_enabled);
    if (comptime carrier_audit_enabled) {
        gcCarrier(self).extent_identity.commit(reservation, .{
            .base = base,
            .raw_base = raw_base,
            .payload_bytes = payload_bytes,
            .raw_bytes = raw_bytes,
            .generation = reservation.generation,
            .kind = kind,
        });
    }
    if (comptime carrier_audit_enabled) gcCarrier(self).extent_lifecycle.commit(base);
    if (comptime carrier_audit_enabled) {
        if (gcCarrier(self).heap_oracle) |oracle| oracle.recordRawAlloc(.{
            .audit_id = 0,
            .base = base,
            .raw_base = raw_base,
            .raw_bytes = raw_bytes,
            .accounted_bytes = accounted_bytes,
            .kind = kind,
            .generation = reservation.generation,
        });
    }
}

fn recordBlockGcAllocation(self: *Registry, base: usize, payload_bytes: usize) void {
    if (comptime !carrier_audit_enabled) return;
    const heap = objectCellHeap(self).?;
    const generation = if (comptime carrier_audit_enabled)
        (heap.generationHandle(base, gc_prefix_size).?).generation
    else
        0;
    const raw_bytes = heap.rawBytesForCell(base, gc_prefix_size).?;
    if (gcCarrier(self).heap_oracle) |oracle| oracle.recordRawAlloc(.{
        .audit_id = 0,
        .base = base,
        .raw_base = base - gc_prefix_size,
        .raw_bytes = raw_bytes,
        .accounted_bytes = payload_bytes,
        .kind = gc_representation.object_kind_tag,
        .generation = generation,
    });
}

pub fn carrierGenerationHandle(self: *const Registry, base: usize) ?gc_carrier.AllocationHandle {
    comptime std.debug.assert(carrier_audit_enabled and carrier_audit_enabled);
    if (objectCellHeap(self)) |heap| {
        if (heap.generationHandle(base, gc_prefix_size)) |handle| return handle;
    }
    return (&self.cell_storage).extent_identity.handle(base);
}

pub fn carrierTransition(self: *Registry, base: usize, state: gc_carrier.LifecycleState) gc_carrier.ResolveError!void {
    comptime std.debug.assert(carrier_audit_enabled);
    if (objectCellHeap(self)) |heap| {
        if (heap.containsAllocatedCell(base, gc_prefix_size)) {
            return heap.transitionCell(base, gc_prefix_size, state);
        }
    }
    return gcCarrier(self).extent_lifecycle.transition(base, state);
}

pub fn carrierPublish(self: *Registry, base: usize, accounted_bytes: usize) gc_carrier.ResolveError!void {
    comptime std.debug.assert(carrier_audit_enabled);
    if (objectCellHeap(self)) |heap| {
        if (heap.containsAllocatedCell(base, gc_prefix_size)) {
            return heap.publishCell(base, gc_prefix_size, accounted_bytes);
        }
    }
    return gcCarrier(self).extent_lifecycle.publish(base, accounted_bytes);
}

pub fn beginGcRawFree(self: *Registry, base: usize) void {
    comptime std.debug.assert(carrier_audit_enabled or carrier_audit_enabled);
    if (comptime carrier_audit_enabled) {
        carrierTransition(self, base, .raw_free_in_progress) catch
            @panic("gc: CARRIER IDENTITY: raw free missing lifecycle record");
    }
}

pub fn finishExtentGcRawFree(self: *Registry, base: usize) void {
    comptime std.debug.assert(carrier_audit_enabled);
    if (comptime carrier_audit_enabled) {
        gcCarrier(self).extent_lifecycle.finishRawFree(base) catch
            @panic("gc: CARRIER IDENTITY: extent lifecycle removed before raw free commit");
    }
    if (comptime carrier_audit_enabled) {
        gcCarrier(self).extent_identity.finishRawFree(base) catch
            @panic("gc: CARRIER IDENTITY: extent identity removed before raw free commit");
    }
    if (comptime carrier_audit_enabled) {
        if (gcCarrier(self).heap_oracle) |oracle| oracle.recordRawFree(base);
    }
}

pub fn finishBlockGcRawFree(self: *Registry, base: usize) void {
    comptime std.debug.assert(carrier_audit_enabled);
    if (comptime carrier_audit_enabled) {
        if (gcCarrier(self).heap_oracle) |oracle| oracle.recordRawFree(base);
    }
}

pub fn deinitGcCarrier(self: *Registry) void {
    const storage = &self.cell_storage;
    storage.detach();
}

inline fn objectCellHeap(self: *const Registry) ?*gc_block_heap.Heap {
    const storage = &self.cell_storage;
    return storage.block_heap;
}

inline fn youngNursery(self: *const Registry) ?*gc_nursery_mod.Nursery {
    const storage = &self.cell_storage;
    return storage.nursery;
}

inline fn gcCarrier(self: *Registry) *gc_storage.Owner {
    return (&self.cell_storage);
}

/// `alloc_info` value marking a GC object served from the collector's
/// block heap rather than the slab: class field saturated (31, one past
/// the slab's 30 real classes), large/accounted/standalone bits all zero
/// -- which is exactly what the account's existing branches need to do
/// nothing special with it. The cell is `[8B metadata prefix][object]`,
/// 16-aligned, and `destroy` routes on this byte back to the block heap.
pub const alloc_info_block_cell: u8 = gc_representation.block_cell_alloc_info;

pub const alloc_info_nursery_cell: u8 = gc_representation.nursery_cell_alloc_info;

/// Byte 2 of the GC prefix (`gc.Metadata.alloc_info`): bits 0..4 slab
/// class index, bit 6 heap-accounted (registry-owned), bit 7 standalone
/// prefix. Bit positions are asserted against gc.AllocInfo in gc.zig.
const alloc_info_standalone: u8 = gc_representation.alloc_info_standalone_mask;

const alloc_info_class_mask: u8 = gc_representation.alloc_info_class_mask;

const alloc_info_nursery: u8 = gc_representation.nursery_alloc_info_mask;

/// A bump-allocated young cell owns none of its memory: the PAGE is the
/// allocation, and the minor returns it whole. Every free path has to ask
/// this first, because a nursery cell's class field reads 0 and its
/// standalone bit is clear -- which is exactly the encoding of a slab
/// class-0 object, and freeing one as such corrupts the slab.
inline fn isNurseryCell(ptr: *const anyopaque) bool {
    return gcAllocInfoByte(ptr) & alloc_info_nursery != 0;
}

/// Reads back byte 2 of a live GC object's prefix. For slab-backed objects
/// it carries the allocator's class index (qjs `__js_free` reads
/// `b->block_size_idx`, quickjs.c, instead of re-deriving the
/// class); for standalone prefixes bit 7 is set.
inline fn gcAllocInfoByte(ptr: *const anyopaque) u8 {
    return @as(*const u8, @ptrFromInt(@intFromPtr(ptr) - gc_prefix_size + 2)).*;
}

/// Prefix writer for a block-heap cell: same field layout as
/// `initGcPrefix`, info byte fixed to the block-cell marker.
/// Prefix writer for a bump-allocated young cell. Unlike a block cell
/// there is no cell index to preserve -- the nursery has no bitmap -- so
/// the whole prefix is written here.
inline fn initGcPrefixNursery(comptime T: type, meta: [*]u8) void {
    comptime std.debug.assert(T.gc_kind_tag <= gc_representation.kind_mask);
    @as(*align(8) u32, @ptrCast(@alignCast(meta))).* = 0;
    std.mem.writeInt(u16, meta[2..4], @as(u16, alloc_info_nursery_cell) | (@as(u16, T.gc_kind_tag) << 8), .little);
    @as(*align(4) u32, @ptrCast(@alignCast(meta + 4))).* = 0;
}

inline fn initGcPrefixBlockCell(comptime T: type, meta: [*]u8) void {
    comptime std.debug.assert(T.gc_kind_tag <= gc_representation.kind_mask);
    // Bytes 0..2 carry the CELL INDEX, stamped by the block allocator so
    // the mark accessors never pay the non-power-of-two division on the
    // trace's hottest path. Preserved here, not zeroed.
    std.mem.writeInt(u16, meta[2..4], @as(u16, alloc_info_block_cell) | (@as(u16, T.gc_kind_tag) << 8), .little);
    // trace header state: newborn epoch 0, Object Shape summary zero,
    // husk/reserved clear.
    @as(*align(4) u32, @ptrCast(@alignCast(meta + 4))).* = 0;
}

/// Initialize GC metadata at `meta` (= objectPtr - 8). Bytes 0..2 are the
/// slab allocator's live block index when the metadata is overlaid, so that
/// case must preserve them. `slab_class` = the slab size-class backing this
/// allocation (null = standalone prefix); it lands in the alloc_info byte,
/// mirroring qjs `JSMallocBlockHeader`'s adjacent block_size_idx +
/// gc_obj_type:7|mark:1 bytes with one u16 store.
inline fn initGcPrefix(comptime T: type, meta: [*]u8, slab_class: ?usize) void {
    // The kind must stay inside the low nibble of the shared kind/flags
    // byte (gc.BlockFlags.kind).
    comptime std.debug.assert(T.gc_kind_tag <= gc_representation.kind_mask);
    initGcPrefixTagged(T.gc_kind_tag, meta, slab_class);
}

/// `initGcPrefix` with the kind already reduced to its byte: the erased
/// slow paths carry the tag at runtime.
inline fn initGcPrefixTagged(kind_tag: u8, meta: [*]u8, slab_class: ?usize) void {
    std.debug.assert(kind_tag <= gc_representation.kind_mask);
    // Exact-value stores (no memset-then-overwrite): size_class (bytes
    // 0..2, preserved when the slab header is overlaid), alloc_info + kind
    // as one u16 (byte order fixed by the gc.zig offset asserts), and the
    // lifetime word at offset 4. Every GC kind is tracer-owned: the word
    // starts all-zero (epoch/state) so publication can prove
    // newborn/unmarked.
    if (slab_class == null) std.mem.writeInt(u16, meta[0..2], 0, .little);
    if (slab_class) |index| std.debug.assert(index <= alloc_info_class_mask);
    const info: u8 = if (slab_class) |index| @intCast(index) else alloc_info_standalone;
    std.mem.writeInt(u16, meta[2..4], @as(u16, info) | (@as(u16, kind_tag) << 8), .little);
    const initial_lifetime_word: u32 = 0;
    @as(*align(4) u32, @ptrCast(@alignCast(meta + 4))).* = initial_lifetime_word;
}

fn createInternal(
    self: *Registry,
    comptime T: type,
    comptime fam_bytes: usize,
    comptime trigger_gc: bool,
    comptime prepare_nonblock: bool,
) !*T {
    if (comptime oom_coverage_enabled) oom_coverage.record(@returnAddress());
    comptime requireGc(T);
    const payload_size = comptime @sizeOf(T) + fam_bytes;
    // Inline hot arm = qjs `__js_malloc` small-block path;
    // everything else (arena refill, slab-disabled, standalone prefix,
    // non-slab classes) lives in the noinline slow twin.
    const slab_class = comptime SmallObjectSlab.classIndex(
        payload_size,
        gcAlignment(T),
    );
    // Fixed-size Objects use the block heap with a compile-time size class.
    if (comptime T.gc_kind_tag == gc_representation.object_kind_tag) {
        if (comptime gc_block_heap.canAllocCellSize(gc_prefix_size + payload_size)) {
            if (objectCellHeap(self)) |heap| {
                const bytes: usize = payload_size;
                const prospective_accounted = comptime gc_block_heap.accountedBodyBytesForRequest(
                    gc_prefix_size + bytes,
                    gc_prefix_size,
                ).?;
                try admitHeapCharge(self, prospective_accounted, trigger_gc);
                try native_alloc.checkAllocation(self.runtime.?, prospective_accounted);
                if (comptime trigger_gc) noteAllocProbe(self, prospective_accounted);
                if (comptime carrier_audit_enabled) try prepareGcRawAudit(self);
                // A nursery cell is deliberately OUTSIDE the byte
                // account and the carrier ledger. It has no raw
                // allocation to pair a publication with (the page was
                // charged once), and charging it here would bill the
                // same object twice: once now and again when
                // promotion allocates its old-generation cell.
                // `Nursery.allocated_bytes` is what paces the minor.
                if (youngNursery(self)) |nursery| {
                    if (nursery.serving()) {
                        if (nursery.alloc(nursery.page_allocator, gc_prefix_size + bytes)) |cell| {
                            initGcPrefixNursery(T, cell);
                            return @ptrFromInt(@intFromPtr(cell) + gc_prefix_size);
                        }
                    }
                }
                const cell_class = comptime gc_block_heap.cellClassForPayload(gc_prefix_size + bytes);
                if (heap.allocCellFixedPtr(cell_class.idx, cell_class.size)) |cell| {
                    initGcPrefixBlockCell(T, cell);
                    creditAlloc(self, prospective_accounted, null);
                    if (comptime carrier_audit_enabled) {
                        recordBlockGcAllocation(self, @intFromPtr(cell) + gc_prefix_size, prospective_accounted);
                    }
                    native_alloc.noteAllocDiagnostics(self.runtime.?, true);
                    return @ptrFromInt(@intFromPtr(cell) + gc_prefix_size);
                }
                // Block heap declined (OOM in its backing): the slab
                // still serves, which is the graceful direction.
            }
        }
        if (comptime prepare_nonblock) try self.prepareNonBlockObjectAuthority();
    }
    // GC kinds that missed the block heap use the compatibility slab.
    if (comptime slab_class != null) {
        if (self.cell_storage.slab_enabled) {
            const bytes: usize = payload_size;
            try admitHeapCharge(self, bytes, trigger_gc);
            try native_alloc.checkAllocation(self.runtime.?, bytes);
            if (comptime trigger_gc) noteAllocProbe(self, bytes);
            const carrier_reservation = if (comptime carrier_audit_enabled)
                try reserveGcExtent(self)
            else {};
            const raw = slabPopHot(self, comptime slab_class.?, false) orelse
                return createInternalSlow(self, T, fam_bytes, trigger_gc);
            initGcPrefix(T, @ptrFromInt(@intFromPtr(raw) - gc_prefix_size), comptime slab_class.?);
            creditAlloc(self, bytes, comptime slab_class);
            if (comptime carrier_audit_enabled) commitGcExtent(
                self,
                carrier_reservation,
                @intFromPtr(raw),
                @intFromPtr(raw),
                payload_size,
                payload_size,
                payload_size,
                T.gc_kind_tag,
            );
            native_alloc.noteAllocDiagnostics(self.runtime.?, true);
            return @ptrCast(@alignCast(raw));
        }
    }
    return createInternalSlow(self, T, fam_bytes, trigger_gc);
}

/// Cold continuation of `createInternal`; see `allocSlowErased`.
inline fn createInternalSlow(self: *Registry, comptime T: type, comptime fam_bytes: usize, comptime trigger_gc: bool) !*T {
    comptime requireGc(T);
    const payload_size = comptime @sizeOf(T) + fam_bytes;
    const raw = try allocSlowErased(self, .{
        .payload_bytes = payload_size,
        .alignment = gcAlignment(T),
        .standalone_prefix = gcPrefixSize(T),
        .kind_tag = T.gc_kind_tag,
        .trigger_gc = trigger_gc,
    });
    return @ptrCast(@alignCast(raw));
}

pub inline fn destroy(self: *Registry, comptime T: type, ptr: *T) void {
    return destroyConstFam(self, T, 0, ptr);
}

/// `destroyWithFam` for a flexible-array size the caller knows at compile
/// time. Keeps the slab
/// class index and the block-cell debit constant on the destroy hot path.
/// The walk itself is one `destroyErased` body so leftover typed destroy
/// copies share the already-specialized debit/free arms.
pub inline fn destroyConstFam(self: *Registry, comptime T: type, comptime fam_bytes: usize, ptr: *T) void {
    comptime requireGc(T);
    const payload_size = comptime @sizeOf(T) + fam_bytes;
    const alignment = gcAlignment(T);
    const can_block_cell = comptime T.gc_kind_tag == gc_representation.object_kind_tag and
        gc_block_heap.canAllocCellSize(gc_prefix_size + payload_size);
    destroyErased(self, @ptrCast(ptr), .{
        .payload_size = payload_size,
        .alignment = alignment,
        .standalone_prefix = gcPrefixSize(T),
        .slab_class = comptime SmallObjectSlab.classIndex(payload_size, alignment),
        .can_block_cell = can_block_cell,
        .accounted_block = if (comptime can_block_cell)
            gc_block_heap.accountedBodyBytesForRequest(gc_prefix_size + payload_size, gc_prefix_size).?
        else
            0,
    });
}

const DestroyLayout = struct {
    payload_size: usize,
    alignment: std.mem.Alignment,
    standalone_prefix: usize,
    slab_class: ?usize,
    can_block_cell: bool,
    accounted_block: usize,
};

/// One destroy walk behind `destroy` / `destroyConstFam`. Does not change
/// the block-cell / slab / standalone routing, only the leftover typed
/// copies. `destroyWithFam` stays specialized (runtime FAM size).
noinline fn destroyErased(self: *Registry, ptr: [*]u8, l: DestroyLayout) void {
    if (isNurseryCell(ptr)) return;
    // Collector-served cell goes home first: the marker byte is in the
    // prefix this free is already about to touch.
    if (l.can_block_cell) {
        if (gcAllocInfoByte(ptr) == alloc_info_block_cell) {
            if (objectCellHeap(self)) |heap| {
                if (comptime carrier_audit_enabled) beginGcRawFree(self, @intFromPtr(ptr));
                debitAlloc(self, l.accounted_block, null);
                native_alloc.noteFreeDiagnostics(self.runtime.?, true);
                heap.freeSmallCell(@ptrFromInt(@intFromPtr(ptr) - gc_prefix_size));
                if (comptime carrier_audit_enabled) finishBlockGcRawFree(self, @intFromPtr(ptr));
                return;
            }
        }
    }
    // Compatibility slab; standalone GC allocations use the backing below.
    if (l.slab_class) |slab_class| {
        if (self.cell_storage.slab_enabled) {
            std.debug.assert(gcAllocInfoByte(ptr) & (alloc_info_standalone | alloc_info_class_mask) == slab_class);
            if (comptime carrier_audit_enabled) beginGcRawFree(self, @intFromPtr(ptr));
            debitAlloc(self, l.payload_size, slab_class);
            native_alloc.noteFreeDiagnostics(self.runtime.?, true);
            self.cell_storage.slab.freeAtIndex(&self.allocator, ptr, slab_class);
            if (comptime carrier_audit_enabled) finishExtentGcRawFree(self, @intFromPtr(ptr));
            return;
        }
    }
    const bytes = l.standalone_prefix + l.payload_size;
    debitAlloc(self, bytes, null);
    native_alloc.noteFreeDiagnostics(self.runtime.?, true);
    const base: [*]u8 = @ptrFromInt(@intFromPtr(ptr) - l.standalone_prefix);
    if (comptime carrier_audit_enabled) beginGcRawFree(self, @intFromPtr(ptr));
    self.allocator.rawFree(base[0..bytes], l.alignment, @returnAddress());
    if (comptime carrier_audit_enabled) finishExtentGcRawFree(self, @intFromPtr(ptr));
}

/// Variable-size GC allocation: the `T` struct immediately followed by
/// `fam_bytes` of inline flexible-array-member storage, in ONE allocation,
/// with 8-byte `Metadata` at `objectPtr - 8` (overlaid on the slab header
/// when eligible, otherwise standalone). Mirrors qjs's single allocation for
/// JSShape (struct fields + inline hash table + prop[]). The caller is
/// responsible for the FAM's internal alignment (must be <= `gcAlignment(T)`,
/// which is >= 8); since the struct size is a multiple of `@alignOf(T)`, the
/// FAM region starts `@alignOf(T)`-aligned right after the struct.
pub inline fn createWithFam(self: *Registry, comptime T: type, fam_bytes: usize) !*T {
    return createWithFamInternal(self, T, fam_bytes, true, false);
}

/// Initial-shape path: `fam_bytes` is a comptime constant so the slab
/// class is folded (qjs `js_new_shape2.constprop` folds `get_shape_size`).
pub inline fn createWithFamComptime(self: *Registry, comptime T: type, comptime fam_bytes: usize) !*T {
    comptime std.debug.assert(@hasDecl(T, "gc_kind_tag"));
    const payload_bytes: usize = @sizeOf(T) + fam_bytes;
    const alignment = comptime gcAlignment(T);
    if (comptime oom_coverage_enabled) oom_coverage.record(@returnAddress());
    if (comptime SmallObjectSlab.classIndex(payload_bytes, alignment)) |slab_class| {
        if (self.cell_storage.slab_enabled) {
            try admitHeapCharge(self, payload_bytes, true);
            try native_alloc.checkAllocation(self.runtime.?, payload_bytes);
            if (comptime allocation_gc_trigger_enabled) noteAllocProbe(self, payload_bytes);
            const carrier_reservation = if (comptime carrier_audit_enabled)
                try reserveGcExtent(self)
            else {};
            const raw = slabPopHot(self, slab_class, false) orelse
                return createWithFamInternalSlow(self, T, fam_bytes, true);
            initGcPrefix(T, @ptrFromInt(@intFromPtr(raw) - gc_prefix_size), slab_class);
            creditAlloc(self, payload_bytes, slab_class);
            if (comptime carrier_audit_enabled) commitGcExtent(
                self,
                carrier_reservation,
                @intFromPtr(raw),
                @intFromPtr(raw),
                payload_bytes,
                payload_bytes,
                payload_bytes,
                T.gc_kind_tag,
            );
            native_alloc.noteAllocDiagnostics(self.runtime.?, true);
            return @ptrCast(@alignCast(raw));
        }
    }
    return createWithFamInternalSlow(self, T, fam_bytes, true);
}

pub inline fn createObjectWithFamNoTrigger(
    self: *Registry,
    comptime T: type,
    fam_bytes: usize,
) !*T {
    comptime std.debug.assert(T.gc_kind_tag == gc_representation.object_kind_tag);
    return createWithFamInternal(self, T, fam_bytes, false, true);
}

fn createWithFamInternal(
    self: *Registry,
    comptime T: type,
    fam_bytes: usize,
    comptime trigger_gc: bool,
    comptime prepare_nonblock: bool,
) !*T {
    comptime std.debug.assert(@hasDecl(T, "gc_kind_tag"));
    if (comptime oom_coverage_enabled) oom_coverage.record(@returnAddress());
    const payload_bytes = std.math.add(usize, @sizeOf(T), fam_bytes) catch return error.OutOfMemory;
    // Shape-sized trailing Object storage must stay on the collector's
    // ordinary classed-block bump path. This is the variable-size twin of
    // createInternal's direct block route: only the authorized GC kind can enter,
    // and medium/large requests are declined by allocCell and fall through
    // to the compatibility slab without acquiring a partial block.
    if (comptime T.gc_kind_tag == gc_representation.object_kind_tag) {
        if (objectCellHeap(self)) |heap| {
            const prospective_accounted = gc_block_heap.accountedBodyBytesForRequest(
                gc_prefix_size + payload_bytes,
                gc_prefix_size,
            ).?;
            try admitHeapCharge(self, prospective_accounted, trigger_gc);
            try native_alloc.checkAllocation(self.runtime.?, prospective_accounted);
            if (comptime trigger_gc) noteAllocProbe(self, prospective_accounted);
            if (comptime carrier_audit_enabled) try prepareGcRawAudit(self);
            if ((heap.allocCell(gc_prefix_size + payload_bytes) catch null)) |cell| {
                initGcPrefixBlockCell(T, cell);
                creditAlloc(self, prospective_accounted, null);
                if (comptime carrier_audit_enabled) {
                    recordBlockGcAllocation(self, @intFromPtr(cell) + gc_prefix_size, prospective_accounted);
                }
                native_alloc.noteAllocDiagnostics(self.runtime.?, true);
                return @ptrFromInt(@intFromPtr(cell) + gc_prefix_size);
            }
        }
        if (comptime prepare_nonblock) try self.prepareNonBlockObjectAuthority();
    }
    // Inline hot arm = qjs `__js_malloc` small-block path
    // with the runtime `get_block_size_index` classification qjs also pays
    // for a runtime size. Arena refill and the standalone-prefix route live
    // in the noinline slow twin.
    if (self.cell_storage.slab_enabled) {
        if (SmallObjectSlab.classIndex(payload_bytes, comptime gcAlignment(T))) |slab_class| {
            try admitHeapCharge(self, payload_bytes, trigger_gc);
            try native_alloc.checkAllocation(self.runtime.?, payload_bytes);
            if (comptime trigger_gc) noteAllocProbe(self, payload_bytes);
            const carrier_reservation = if (comptime carrier_audit_enabled)
                try reserveGcExtent(self)
            else {};
            const raw = slabPopHot(self, slab_class, false) orelse
                return createWithFamInternalSlow(self, T, fam_bytes, trigger_gc);
            initGcPrefix(T, @ptrFromInt(@intFromPtr(raw) - gc_prefix_size), slab_class);
            creditAlloc(self, payload_bytes, slab_class);
            if (comptime carrier_audit_enabled) {
                commitGcExtent(
                    self,
                    carrier_reservation,
                    @intFromPtr(raw),
                    @intFromPtr(raw),
                    payload_bytes,
                    payload_bytes,
                    payload_bytes,
                    T.gc_kind_tag,
                );
            }
            native_alloc.noteAllocDiagnostics(self.runtime.?, true);
            return @ptrCast(@alignCast(raw));
        }
    }
    return createWithFamInternalSlow(self, T, fam_bytes, trigger_gc);
}

/// Cold continuation of `createWithFamInternal`. Same walk as
/// `createInternalSlow`: one `allocSlowErased` body, runtime FAM size.
/// Does not instantiate `allocAlignedBytesSlow(true)`.
inline fn createWithFamInternalSlow(self: *Registry, comptime T: type, fam_bytes: usize, comptime trigger_gc: bool) !*T {
    comptime std.debug.assert(@hasDecl(T, "gc_kind_tag"));
    const payload_bytes = std.math.add(usize, @sizeOf(T), fam_bytes) catch return error.OutOfMemory;
    const raw = try allocSlowErased(self, .{
        .payload_bytes = payload_bytes,
        .alignment = comptime gcAlignment(T),
        .standalone_prefix = comptime gcPrefixSize(T),
        .kind_tag = T.gc_kind_tag,
        .trigger_gc = trigger_gc,
    });
    return @ptrCast(@alignCast(raw));
}

/// Accounted payload of a slab-backed GC FAM, or null when the object
/// uses a standalone prefix (caller falls back to live capacity fields).
/// qjs `__js_free` never re-derives size from JSShape.prop_size.
pub fn gcSlabAccountedPayload(ptr: *const anyopaque) ?usize {
    const info = gcAllocInfoByte(ptr);
    if (info & alloc_info_nursery != 0) return null;
    if (info & alloc_info_class_mask == alloc_info_block_cell) return null;
    if (info & alloc_info_standalone != 0) return null;
    return SmallObjectSlab.usablePayloadFromClass(info & alloc_info_class_mask);
}

/// Frees a `createWithFam` allocation. `fam_bytes` MUST equal the value
/// passed to `createWithFam` (the caller derives it from the live object's
/// capacity fields before clearing them) on the standalone-prefix path.
/// The slab arm trusts the header class (qjs `__js_free`, quickjs.c)
/// and does not re-run `classIndex` on the requested length.
pub fn destroyWithFam(self: *Registry, comptime T: type, ptr: *T, fam_bytes: usize) void {
    comptime std.debug.assert(@hasDecl(T, "gc_kind_tag"));
    if (isNurseryCell(ptr)) return;
    const payload_bytes = @sizeOf(T) + fam_bytes;
    const alignment = comptime gcAlignment(T);
    const info = gcAllocInfoByte(ptr);
    // Variable-sized block cells carry the same route marker as fixed
    // Objects. Debit the logical Object+tail payload and return the exact
    // cell to the classed block; no class reclassification or partial-block
    // reuse is introduced here.
    if (comptime T.gc_kind_tag == gc_representation.object_kind_tag) {
        if (info & alloc_info_class_mask == alloc_info_block_cell) {
            if (objectCellHeap(self)) |heap| {
                const accounted = gc_block_heap.accountedBodyBytesForRequest(
                    gc_prefix_size + payload_bytes,
                    gc_prefix_size,
                ).?;
                if (comptime carrier_audit_enabled) beginGcRawFree(self, @intFromPtr(ptr));
                debitAlloc(self, accounted, null);
                native_alloc.noteFreeDiagnostics(self.runtime.?, true);
                heap.freeSmallCell(@ptrFromInt(@intFromPtr(ptr) - gc_prefix_size));
                if (comptime carrier_audit_enabled) finishBlockGcRawFree(self, @intFromPtr(ptr));
                return;
            }
        }
    }
    // Straight-line slab arm mirroring qjs `__js_free`'s small-block path
    //: the block header byte carries the class index,
    // so the free never re-derives the class from the byte size.
    if (info & alloc_info_standalone == 0) {
        const slab_class: usize = info & alloc_info_class_mask;
        std.debug.assert(self.cell_storage.slab_enabled);
        if (comptime carrier_audit_enabled) beginGcRawFree(self, @intFromPtr(ptr));
        debitAlloc(self, payload_bytes, slab_class);
        native_alloc.noteFreeDiagnostics(self.runtime.?, true);
        self.cell_storage.slab.freeAtIndex(&self.allocator, @ptrCast(ptr), slab_class);
        if (comptime carrier_audit_enabled) finishExtentGcRawFree(self, @intFromPtr(ptr));
        return;
    }
    const prefix = comptime gcPrefixSize(T);
    const bytes = prefix + payload_bytes;
    debitAlloc(self, bytes, null);
    native_alloc.noteFreeDiagnostics(self.runtime.?, true);
    const base: [*]u8 = @ptrFromInt(@intFromPtr(ptr) - prefix);
    if (comptime carrier_audit_enabled) beginGcRawFree(self, @intFromPtr(ptr));
    self.allocator.rawFree(base[0..bytes], alignment, @returnAddress());
    if (comptime carrier_audit_enabled) finishExtentGcRawFree(self, @intFromPtr(ptr));
}

/// TGC S2: a string-family carrier from the collector's block heap.
/// `total_bytes` counts the eight-byte Metadata prefix; the returned
/// pointer is the cell base (prefix start). Null when the request is not
/// a small-class cell or the heap declined: the caller takes the extent
/// route. The prefix is initialized like an Object cell (cell index in
/// bytes 0..2 preserved, `kind_tag`, zero lifetime word); the caller
/// still publishes through `addInitializedWithSizeNoFail`.
///
/// `kind_tag` is a runtime byte (string-family or storage). The prefix
/// write is still one store: `string_kind_tag` / `rope_kind_tag` or a
/// storage tag from `createStorageCell`.
pub fn createStringCell(self: *Registry, kind_tag: u8, total_bytes: usize) !?[*]u8 {
    return createCarrierCell(self, kind_tag, total_bytes, true);
}

fn createCarrierCell(self: *Registry, kind_tag: u8, total_bytes: usize, allow_retry: bool) !?[*]u8 {
    std.debug.assert(kind_tag <= gc_representation.kind_mask);
    if (comptime oom_coverage_enabled) oom_coverage.record(@returnAddress());
    if (!gc_block_heap.canAllocCellSize(total_bytes)) return null;
    const heap = objectCellHeap(self) orelse return null;
    const accounted = gc_block_heap.accountedBodyBytesForRequest(total_bytes, gc_prefix_size).?;
    try admitHeapCharge(self, accounted, allow_retry);
    try native_alloc.checkAllocation(self.runtime.?, accounted);
    if (comptime carrier_audit_enabled) try prepareGcRawAudit(self);
    const cell = (try heap.allocCell(total_bytes)) orelse return null;
    std.mem.writeInt(u16, cell[2..4], @as(u16, alloc_info_block_cell) | (@as(u16, kind_tag) << 8), .little);
    @as(*align(4) u32, @ptrCast(@alignCast(cell + 4))).* = 0;
    creditAlloc(self, accounted, null);
    if (comptime carrier_audit_enabled) {
        recordBlockGcAllocation(self, @intFromPtr(cell) + gc_prefix_size, accounted);
    }
    native_alloc.noteAllocDiagnostics(self.runtime.?, false);
    return cell;
}

/// Return a string-family block cell (see `createStringCell`). `payload`
/// is the body pointer (cell base + 8); the accounted byte count mirrors
/// the one `createStringCell` charged, so the ledger balances.
pub fn destroyStringCell(self: *Registry, payload: *const anyopaque, total_bytes: usize) void {
    const heap = objectCellHeap(self).?;
    const accounted = gc_block_heap.accountedBodyBytesForRequest(total_bytes, gc_prefix_size).?;
    if (comptime carrier_audit_enabled) beginGcRawFree(self, @intFromPtr(payload));
    debitAlloc(self, accounted, null);
    native_alloc.noteFreeDiagnostics(self.runtime.?, true);
    heap.freeSmallCell(@ptrFromInt(@intFromPtr(payload) - gc_prefix_size));
    if (comptime carrier_audit_enabled) finishBlockGcRawFree(self, @intFromPtr(payload));
}

/// TGC S2: a string-family carrier that does not fit a block cell -- a
/// medium page run or a large mapping from the collector's block heap
/// (spec §5.7 "extent"; first `Heap.alloc` caller). `total_bytes` counts
/// the eight-byte Metadata prefix; the returned slice starts at it.
///
/// Prefix bytes, written exactly as `initGcPrefix`'s standalone form:
/// bytes 0..2 zero (`size_class`; publication stamps `encodeHeapBytes`),
/// byte 2 = `alloc_info_standalone`, byte 3 = string kind tag, bytes 4..8
/// zero (newborn lifetime word). The caller publishes the body
/// (`base + 8`) through `addInitializedWithSizeNoFail(body, total - 8)`.
/// Accounting charges the request like every standalone GC prefix
/// (`accountedMallocSize(total, null)`); audit builds also keep the extent
/// identity/lifecycle records `carrierPublish` will look up.
pub fn createStringExtent(self: *Registry, total_bytes: usize) ![]u8 {
    return createExtentInner(self, gc_representation.string_kind_tag, total_bytes, true);
}

/// TGC S2-i / S4-b (D-S4-3): the kind-parameterized extent route. Every
/// prefix carrier over the block-cell ceiling lands here. `kind_tag` is
/// a runtime byte: the prefix write is still one store.
pub fn createExtent(self: *Registry, kind_tag: u8, total_bytes: usize) ![]u8 {
    return createExtentInner(self, kind_tag, total_bytes, true);
}

fn createExtentInner(self: *Registry, kind_tag: u8, total_bytes: usize, allow_retry: bool) ![]u8 {
    if (comptime oom_coverage_enabled) oom_coverage.record(@returnAddress());
    std.debug.assert(!gc_block_heap.canAllocCellSize(total_bytes));
    const heap = objectCellHeap(self) orelse return error.OutOfMemory;
    try admitHeapCharge(self, total_bytes - gc_prefix_size, allow_retry);
    try native_alloc.checkAllocation(self.runtime.?, total_bytes);
    const carrier_reservation = if (comptime carrier_audit_enabled)
        try reserveGcExtent(self)
    else {};
    const slice = try heap.alloc(total_bytes);
    const base = slice.ptr;
    std.mem.writeInt(u16, base[0..2], 0, .little);
    std.debug.assert(kind_tag <= gc_representation.kind_mask);
    std.mem.writeInt(u16, base[2..4], @as(u16, alloc_info_standalone) | (@as(u16, kind_tag) << 8), .little);
    @as(*align(4) u32, @ptrCast(@alignCast(base + 4))).* = 0;
    creditAlloc(self, total_bytes, null);
    const body = @intFromPtr(base) + gc_prefix_size;
    const payload_bytes = total_bytes - gc_prefix_size;
    if (comptime carrier_audit_enabled) {
        commitGcExtent(
            self,
            carrier_reservation,
            body,
            @intFromPtr(base),
            payload_bytes,
            total_bytes,
            payload_bytes,
            kind_tag,
        );
    }
    native_alloc.noteAllocDiagnostics(self.runtime.?, false);
    return slice;
}

/// Return a string extent (see `createStringExtent`). `payload` is the
/// body pointer (base + 8); the registry side (`unpublishStringExtent`)
/// has already run. Mirrors `destroyWithFam`'s standalone arm.
pub fn destroyStringExtent(self: *Registry, payload: *const anyopaque, total_bytes: usize) void {
    const heap = objectCellHeap(self).?;
    const body = @intFromPtr(payload);
    if (comptime carrier_audit_enabled) beginGcRawFree(self, body);
    debitAlloc(self, total_bytes, null);
    native_alloc.noteFreeDiagnostics(self.runtime.?, true);
    heap.free(@ptrFromInt(body - gc_prefix_size));
    if (comptime carrier_audit_enabled) finishExtentGcRawFree(self, body);
}

/// A storage cell as the collector sees it: the allocation base (prefix
/// start), the byte count publication must charge, and which of the two
/// carriers answered. TGC S4 spec 2.2.
pub const StorageCell = struct {
    base: [*]u8,
    accounted_bytes: usize,
    is_block_cell: bool,
};

/// TGC S4 spec 2.2 -- the ONE allocation funnel for a bare storage
/// carrier (S2-i's string tail buffer today; property/array/payload
/// storage in S4-b). `total_bytes` counts the eight-byte Metadata prefix.
/// Small requests take a block cell, everything else an extent of the
/// same heap. The caller publishes the body (`base + 8`) through
/// `addInitializedWithSizeNoFail(body, accounted_bytes)`.
pub fn createStorageCell(self: *Registry, kind_tag: u8, total_bytes: usize) !StorageCell {
    // Storage callers prepare the charge while they can still name every
    // live cell. The mint itself must not collect: the returned body is
    // unpublished until the caller installs it.
    if (try createCarrierCell(self, kind_tag, total_bytes, false)) |base| {
        return .{
            .base = base,
            .accounted_bytes = gc_block_heap.accountedBodyBytesForRequest(total_bytes, gc_prefix_size).?,
            .is_block_cell = true,
        };
    }
    const slice = try createExtentInner(self, kind_tag, total_bytes, false);
    return .{
        .base = slice.ptr,
        .accounted_bytes = total_bytes - gc_prefix_size,
        .is_block_cell = false,
    };
}

/// TGC S4-d spec 2.4: the audit half of a bitmap-reclaimed block cell.
///
/// Production reclaims the cell with word arithmetic and writes nothing
/// per corpse. The audit builds still own an independent raw oracle and a
/// carrier lifecycle state machine, and both must see the same free record
/// `destroyStringCell` writes -- everything except the byte debit, which
/// happened once at condemnation (`debitBlockBytes`).
pub fn noteBlockCellBitmapReclaim(self: *Registry, payload: *const anyopaque) void {
    if (comptime carrier_audit_enabled) beginGcRawFree(self, @intFromPtr(payload));
    native_alloc.noteFreeDiagnostics(self.runtime.?, true);
    if (comptime carrier_audit_enabled) finishBlockGcRawFree(self, @intFromPtr(payload));
}

/// TGC S4-d spec 2.4: one debit for a whole condemnation's worth of block
/// cells.
///
/// `bytes` is the prefix-excluded accounted size summed over the corpses
/// the sweep reclaims from the BITMAP -- the ones no per-cell free path
/// will ever run for. The corpses that owe a destructor are excluded at
/// the snapshot and keep their per-cell debit, so the two routes partition
/// the condemned set and neither double-counts.
pub inline fn debitBlockBytes(self: *Registry, bytes: usize) void {
    if (comptime !diagnostic_accounting_enabled) return;
    if (bytes == 0) return;
    debitAlloc(self, bytes, null);
}

pub fn enableSmallObjectSlab(self: *Registry) void {
    self.cell_storage.slab_enabled = true;
}

/// Conservative resolution requires page-aligned slab arenas. The trace
/// runtime serves those physical pages from Zig's independent allocator;
/// logical allocations remain charged to this account.
///
/// The OOM-injection tier keeps the arenas on `backing_allocator`
/// instead (`oom_injection_enabled`; `zig build test` does not). The
/// independent allocator is a throughput choice ("keeps arena refills off
/// glibc's high-alignment malloc path"), not a correctness one -- the
/// page alignment is requested explicitly by `addArena`, so any allocator
/// that honours it works. Routing the refills away from the account's own
/// backing allocator, however, hides every slab-class allocation from OOM
/// injection, and slab classes are most of the engine's small allocations
/// (in the export-name-lookahead canary: all three interned identifier
/// bodies). That blindspot arrived with the tracing collector (7fc2c9e9)
/// and is what shrank the canary's injectable window from 9 to 6.
pub fn useIndependentSmallObjectSlabArenaBacking(self: *Registry) void {
    if (comptime oom_injection_enabled) return;
    self.cell_storage.slab.setArenaBacking(std.heap.smp_allocator);
}

pub fn deinitSmallObjectSlab(self: *Registry) void {
    self.cell_storage.slab.deinit(self.allocator);
    self.cell_storage.slab_enabled = false;
}

/// Bytes a carrier of `total_bytes` (metadata prefix included) will add to
/// the heap budget. Block cells use the size-class body; extents use the
/// payload. Matches `createCarrierCell` / `createExtentInner`.
pub fn heapChargeForCarrier(total_bytes: usize) usize {
    if (gc_block_heap.canAllocCellSize(total_bytes)) {
        return gc_block_heap.accountedBodyBytesForRequest(total_bytes, gc_prefix_size) orelse (total_bytes -| gc_prefix_size);
    }
    return total_bytes -| gc_prefix_size;
}

/// Prospective JS-heap charge. `bytes` is the amount publication will add
/// to the heap budget, not the diagnostic allocation size. Checks admission
/// without reserving or charging bytes; Registry charges on publication.
/// `allow_retry` permits the budget's GC callback. Otherwise this only checks.
fn admitHeapCharge(self: *Registry, bytes: usize, allow_retry: bool) !void {
    const budget = &self.heap_budget;
    if (allow_retry) try budget.admit(bytes) else try budget.checkOnly(bytes);
}

/// Test and force-GC observation for an allocation that opted in. `NoTrigger`
/// paths do not call this. A custom probe replaces the default notify and
/// does not, by itself, schedule a collection.
pub inline fn noteAllocProbe(self: *Registry, byte_count: usize) void {
    if (comptime !allocation_gc_trigger_enabled) return;
    const budget = &self.heap_budget;
    if (budget.suspend_alloc_notify) return;
    if (comptime builtin.is_test) {
        if (budget.probe) |probe| {
            const saved = budget.suspend_alloc_notify;
            budget.suspend_alloc_notify = true;
            defer budget.suspend_alloc_notify = saved;
            probe(budget.probe_ctx, byte_count);
            return;
        }
    }
    if (budget.owner_notify) |notify| notify(budget.owner_ctx, byte_count);
}

fn requireGc(comptime T: type) void {
    if (@typeInfo(T) != .@"struct" or !@hasDecl(T, "gc_kind_tag"))
        @compileError("native allocations belong to Runtime");
}

inline fn creditAlloc(self: *Registry, request_bytes: usize, slab_class: ?usize) void {
    native_alloc.creditAlloc(self.runtime.?, accountedMallocSize(request_bytes, slab_class));
}

inline fn debitAlloc(self: *Registry, request_bytes: usize, slab_class: ?usize) void {
    native_alloc.debitAlloc(self.runtime.?, accountedMallocSize(request_bytes, slab_class));
}

/// Preserves the existing Runtime construction boundary for Realm/VarRef cells.
pub inline fn createRuntimeCell(self: *Registry, comptime T: type) !*T {
    comptime requireGc(T);
    if (comptime allocation_gc_trigger_enabled) self.runtime.?.requestGCForAllocation(@sizeOf(T));
    return createNoTrigger(self, T);
}

/// Standalone Object with a custom aligned inline payload. The constructor
/// supplies the checked layout and initializes metadata/body before publication.
/// Like other NoTrigger routes, this cannot collect while sibling cells exist.
pub noinline fn allocStandaloneObject(
    self: *Registry,
    allocation_size: usize,
    alignment: std.mem.Alignment,
    object_offset: usize,
    object_size: usize,
) ![*]u8 {
    try self.heap_budget.checkOnly(object_size);
    try self.prepareNonBlockObjectAuthority();
    const reservation = if (comptime carrier_audit_enabled) try reserveGcExtent(self) else {};
    if (comptime oom_coverage_enabled) oom_coverage.record(@returnAddress());
    try native_alloc.checkAllocation(self.runtime.?, allocation_size);
    const raw = self.allocator.rawAlloc(allocation_size, alignment, @returnAddress()) orelse return error.OutOfMemory;
    creditAlloc(self, allocation_size, null);
    native_alloc.noteAllocDiagnostics(self.runtime.?, false);
    const body = raw + object_offset;
    if (comptime carrier_audit_enabled) {
        commitGcExtent(self, reservation, @intFromPtr(body), @intFromPtr(raw), object_size, allocation_size, object_size, gc_representation.object_kind_tag);
    }
    return body;
}

/// Paired raw release for allocStandaloneObject, after any required unpublish.
pub noinline fn freeStandaloneObject(
    self: *Registry,
    body: *anyopaque,
    allocation_size: usize,
    alignment: std.mem.Alignment,
    object_offset: usize,
) void {
    const raw: [*]u8 = @ptrFromInt(@intFromPtr(body) - object_offset);
    if (comptime carrier_audit_enabled) beginGcRawFree(self, @intFromPtr(body));
    debitAlloc(self, allocation_size, null);
    native_alloc.noteFreeDiagnostics(self.runtime.?, false);
    self.allocator.rawFree(raw[0..allocation_size], alignment, @returnAddress());
    if (comptime carrier_audit_enabled) finishExtentGcRawFree(self, @intFromPtr(body));
}

test "allocation ownership keeps native bytes outside each Registry budget" {
    const Cell = extern struct {
        pub const gc_kind_tag: u8 = 3;
        payload: [32]u8 = @splat(0),
    };
    const first = try runtime_owner.createAllocationTestRuntime(std.testing.allocator);
    defer first.destroy();
    const second = try runtime_owner.createAllocationTestRuntime(std.testing.allocator);
    defer second.destroy();
    first.gc.heap_budget.limit = 0;
    const bytes = try first.allocNative(u8, 32);
    defer first.freeNative(u8, bytes);
    try std.testing.expectError(error.OutOfMemory, first.gc.createCellNoTrigger(Cell));
    try std.testing.expectEqual(@as(usize, 0), first.gc.heap_budget.bytes);
    try std.testing.expectEqual(@as(usize, 32), first.diagnostics.allocations.allocated_bytes);
    const other = try second.gc.createCellNoTrigger(Cell);
    try std.testing.expectEqual(@as(usize, 0), second.gc.heap_budget.bytes);
    try std.testing.expect(second.hasOutstandingAllocations());
    second.gc.destroyCell(Cell, other);
    try std.testing.expect(!second.hasOutstandingAllocations());
    try std.testing.expectEqual(@as(usize, 32), first.diagnostics.allocations.allocated_bytes);
}

test "createWithFamInternalSlow shares allocSlowErased ledger for FAM payloads" {
    const TestHeader = extern struct {
        prev: ?*@This() = null,
        next_non_object: ?*@This() = null,
    };
    const TestGc = extern struct {
        pub const gc_kind_tag: u8 = 3;

        header: TestHeader = .{},
        payload: [48]u8 = @splat(0),
    };

    comptime std.debug.assert(@sizeOf(TestGc) == 64);

    // Slab disabled forces createWithFamInternalSlow (no hot slab pop).
    const account = try runtime_owner.createAllocationTestRuntime(std.testing.allocator);
    defer account.destroy();
    defer account.gc.cell_storage.slab.deinit(std.testing.allocator);
    defer account.gc.deinitGcCarrier();
    account.gc.cell_storage.slab_enabled = false;

    const extras = [_]usize{ 0, 8, 64, 256 };
    for (extras) |extra| {
        const before = account.diagnostics.allocations.allocated_bytes;
        const ptr = try account.gc.createWithFam(TestGc, extra);
        ptr.* = .{};
        const meta: [*]const u8 = @ptrFromInt(@intFromPtr(ptr) - gc_alloc.gc_prefix_size);
        try std.testing.expectEqual(TestGc.gc_kind_tag, meta[3] & 0x7);
        const prefix = gc_alloc.gcPrefixSize(TestGc);
        try std.testing.expectEqual(before + prefix + @sizeOf(TestGc) + extra, account.diagnostics.allocations.allocated_bytes);
        account.gc.destroyWithFam(TestGc, ptr, extra);
        try std.testing.expectEqual(before, account.diagnostics.allocations.allocated_bytes);
    }
}

test "reallocElements matches alloc(T, n+1) ledger for exact-fit append" {
    for ([_]bool{ false, true }) |slab_enabled| {
        const typed = try runtime_owner.createAllocationTestRuntime(std.testing.allocator);
        defer typed.destroy();
        defer typed.gc.cell_storage.slab.deinit(std.testing.allocator);
        typed.gc.cell_storage.slab_enabled = slab_enabled;
        const erased = try runtime_owner.createAllocationTestRuntime(std.testing.allocator);
        defer erased.destroy();
        defer erased.gc.cell_storage.slab.deinit(std.testing.allocator);
        erased.gc.cell_storage.slab_enabled = slab_enabled;

        var typed_items: []u32 = &.{};
        var erased_items: []u32 = &.{};
        defer if (typed_items.len != 0) typed.freeNative(u32, typed_items);
        defer if (erased_items.len != 0) erased.freeNativeAlignedBytes(
            @as([*]u8, @ptrCast(erased_items.ptr))[0 .. erased_items.len * @sizeOf(u32)],
            std.mem.Alignment.of(u32),
        );

        for (0..8) |n| {
            const before_typed = typed.diagnostics.allocations.allocated_bytes;
            const before_erased = erased.diagnostics.allocations.allocated_bytes;
            const next_typed = try typed.allocNative(u32, n + 1);
            @memcpy(next_typed[0..n], typed_items);
            next_typed[n] = @intCast(n);
            if (typed_items.len != 0) typed.freeNative(u32, typed_items);
            typed_items = next_typed;

            const old_ptr: [*]u8 = if (erased_items.len == 0) undefined else @ptrCast(erased_items.ptr);
            const next_erased = try erased.reallocNativeElements(
                old_ptr,
                erased_items.len,
                erased_items.len + 1,
                @sizeOf(u32),
                std.mem.Alignment.of(u32),
            );
            erased_items = @as([*]u32, @ptrCast(@alignCast(next_erased.ptr)))[0 .. n + 1];
            erased_items[n] = @intCast(n);

            try std.testing.expectEqual(typed.diagnostics.allocations.allocated_bytes - before_typed, erased.diagnostics.allocations.allocated_bytes - before_erased);
            try std.testing.expectEqual(typed_items.len, erased_items.len);
            try std.testing.expectEqualSlices(u32, typed_items, erased_items);
        }
    }
}

test "destroyConstFam shares destroyErased ledger for GC objects" {
    const TestGc = extern struct {
        pub const gc_kind_tag: u8 = 3;
        header: u64 = 0,
        payload: [24]u8 = @splat(0),
    };
    const TinyGc = extern struct {
        pub const gc_kind_tag: u8 = 3;
        header: u64 = 0,
    };

    for ([_]bool{ false, true }) |slab_enabled| {
        inline for (.{ TestGc, TinyGc }) |T| {
            const account = try runtime_owner.createAllocationTestRuntime(std.testing.allocator);
            defer account.destroy();
            defer account.gc.cell_storage.slab.deinit(std.testing.allocator);
            defer account.gc.deinitGcCarrier();
            account.gc.cell_storage.slab_enabled = slab_enabled;
            const before = account.diagnostics.allocations.allocated_bytes;
            const ptr = try account.gc.createCell(T);
            ptr.* = .{};
            try std.testing.expect(account.diagnostics.allocations.allocated_bytes > before);
            account.gc.destroyCell(T, ptr);
            try std.testing.expectEqual(before, account.diagnostics.allocations.allocated_bytes);
        }
    }
}

test "free shares freeAlignedBytes ledger for non-GC elements" {
    const Sample = extern struct { a: u64, b: u64, c: u64, d: u64, e: u64, f: u64, g: u64 };
    comptime std.debug.assert(@sizeOf(Sample) == 56);

    const counts = [_]usize{ 1, 4, 8, 16 };
    for ([_]bool{ false, true }) |slab_enabled| {
        inline for (.{ u8, u32, Sample }) |T| {
            for (counts) |count| {
                const typed = try runtime_owner.createAllocationTestRuntime(std.testing.allocator);
                defer typed.destroy();
                defer typed.gc.cell_storage.slab.deinit(std.testing.allocator);
                typed.gc.cell_storage.slab_enabled = slab_enabled;
                const erased = try runtime_owner.createAllocationTestRuntime(std.testing.allocator);
                defer erased.destroy();
                defer erased.gc.cell_storage.slab.deinit(std.testing.allocator);
                erased.gc.cell_storage.slab_enabled = slab_enabled;

                const typed_items = try typed.allocNative(T, count);
                const erased_items = try erased.allocNative(T, count);
                const before_typed = typed.diagnostics.allocations.allocated_bytes;
                const before_erased = erased.diagnostics.allocations.allocated_bytes;
                typed.freeNative(T, typed_items);
                const erased_bytes = @as([*]u8, @ptrCast(erased_items.ptr))[0 .. erased_items.len * @sizeOf(T)];
                erased.freeNativeAlignedBytes(erased_bytes, std.mem.Alignment.of(T));
                try std.testing.expectEqual(@as(usize, 0), typed.diagnostics.allocations.allocated_bytes);
                try std.testing.expectEqual(@as(usize, 0), erased.diagnostics.allocations.allocated_bytes);
                try std.testing.expectEqual(before_typed, before_erased);
            }
        }
    }
}

test "allocElements matches alloc(T) ledger for non-GC elements" {
    for ([_]bool{ false, true }) |slab_enabled| {
        const typed = try runtime_owner.createAllocationTestRuntime(std.testing.allocator);
        defer typed.destroy();
        defer typed.gc.cell_storage.slab.deinit(std.testing.allocator);
        typed.gc.cell_storage.slab_enabled = slab_enabled;
        const erased = try runtime_owner.createAllocationTestRuntime(std.testing.allocator);
        defer erased.destroy();
        defer erased.gc.cell_storage.slab.deinit(std.testing.allocator);
        erased.gc.cell_storage.slab_enabled = slab_enabled;

        const counts = [_]usize{ 1, 4, 8, 16 };
        for (counts) |count| {
            const before_typed = typed.diagnostics.allocations.allocated_bytes;
            const before_erased = erased.diagnostics.allocations.allocated_bytes;
            const typed_items = try typed.allocNative(u32, count);
            const erased_bytes = try erased.allocNativeElements(count, @sizeOf(u32), std.mem.Alignment.of(u32));
            try std.testing.expectEqual(typed.diagnostics.allocations.allocated_bytes - before_typed, erased.diagnostics.allocations.allocated_bytes - before_erased);
            try std.testing.expectEqual(typed_items.len * @sizeOf(u32), erased_bytes.len);
            typed.freeNative(u32, typed_items);
            erased.freeNativeAlignedBytes(erased_bytes, std.mem.Alignment.of(u32));
            try std.testing.expectEqual(before_typed, typed.diagnostics.allocations.allocated_bytes);
            try std.testing.expectEqual(before_erased, erased.diagnostics.allocations.allocated_bytes);
        }
    }
}

test "aligned byte allocations charge the request with the slab enabled" {
    // Ordinary native bytes use the backing allocator. Enabling the GC slab
    // must not round them up to a size class.
    for ([_]bool{ false, true }) |slab_enabled| {
        const account = try runtime_owner.createAllocationTestRuntime(std.testing.allocator);
        defer account.destroy();
        defer account.gc.cell_storage.slab.deinit(std.testing.allocator);
        account.gc.cell_storage.slab_enabled = slab_enabled;

        var byte_count: usize = 1;
        while (byte_count <= SmallObjectSlab.max_size + 64) : (byte_count += 1) {
            for ([_]std.mem.Alignment{ .@"1", .@"8", .@"16", .@"64" }) |alignment| {
                const before = account.diagnostics.allocations.allocated_bytes;
                const bytes = try account.allocNativeAlignedBytesNoTrigger(byte_count, alignment);
                try std.testing.expectEqual(byte_count, account.diagnostics.allocations.allocated_bytes - before);
                account.freeNativeAlignedBytes(bytes, alignment);
                try std.testing.expectEqual(before, account.diagnostics.allocations.allocated_bytes);
            }
        }
    }
}

test "ordinary native allocation bypasses the small object slab" {
    const account = try runtime_owner.createAllocationTestRuntime(std.testing.allocator);
    defer account.destroy();
    account.gc.enableSmallObjectSlab();
    defer account.gc.deinitSmallObjectSlab();

    const Native = struct { value: u64 = 0 };
    const created = try account.createNative(Native);
    created.* = .{ .value = 9 };
    try std.testing.expectEqual(@sizeOf(Native), account.diagnostics.allocations.allocated_bytes);
    for (account.gc.cell_storage.slab.arenas) |arena| try std.testing.expect(arena == null);

    const bytes = try account.allocNative(u8, 24);
    try std.testing.expectEqual(@sizeOf(Native) + 24, account.diagnostics.allocations.allocated_bytes);
    for (account.gc.cell_storage.slab.arenas) |arena| try std.testing.expect(arena == null);

    account.setAllocationDiagnosticLimit(account.diagnostics.allocations.allocated_bytes);
    try std.testing.expectError(error.OutOfMemory, account.allocNative(u8, 8));
    try std.testing.expectEqual(@sizeOf(Native) + 24, account.diagnostics.allocations.allocated_bytes);
    account.setAllocationDiagnosticLimit(null);

    var items = try account.allocNative(u32, 2);
    items[0] = 7;
    if (try account.remapNative(u32, items, 8)) |grown| {
        try std.testing.expectEqual(@as(u32, 7), grown[0]);
        try std.testing.expectEqual(@as(usize, 8), grown.len);
        account.freeNative(u32, grown);
    } else {
        const copy = try account.allocNative(u32, 8);
        copy[0] = items[0];
        account.freeNative(u32, items);
        try std.testing.expectEqual(@as(u32, 7), copy[0]);
        account.freeNative(u32, copy);
    }
    account.freeNative(u8, bytes);
    account.destroyNative(Native, created);
    try std.testing.expectEqual(@as(usize, 0), account.diagnostics.allocations.allocated_bytes);
    for (account.gc.cell_storage.slab.arenas) |arena| try std.testing.expect(arena == null);
}

test "small object slab retains one empty arena per class" {
    var slab: SmallObjectSlab = .{};
    defer slab.deinit(std.testing.allocator);

    const backing = std.testing.allocator;
    const index = SmallObjectSlab.classIndex(64, .@"8").?;
    const allocation = try slab.allocAtIndex(backing, index, true);
    try std.testing.expect(slab.arenas[index] != null);

    const first_arena = slab.arenas[index].?;
    slab.freeAtIndex(&backing, allocation, index);
    // Retained: still listed, at the free-list head, empty.
    try std.testing.expect(slab.arenas[index] == first_arena);
    try std.testing.expect(slab.free_arenas[index] == first_arena);
    try std.testing.expect(first_arena.used_blocks == 0);

    // The spare comes back without a fresh backing allocation.
    const next = try slab.allocAtIndex(backing, index, true);
    try std.testing.expect(slab.arenas[index] == first_arena);
    try std.testing.expect(first_arena.used_blocks == 1);
    slab.freeAtIndex(&backing, next, index);
    try std.testing.expect(slab.arenas[index] == first_arena);
    try std.testing.expect(first_arena.next == null);
}

test "small object slab releases excess empty arenas" {
    var slab: SmallObjectSlab = .{};
    defer slab.deinit(std.testing.allocator);

    const backing = std.testing.allocator;
    const index = SmallObjectSlab.classIndex(64, .@"8").?;
    var allocations: [SmallObjectSlab.arena_size / 16][*]u8 = undefined;
    allocations[0] = try slab.allocAtIndex(backing, index, true);
    const first_arena_capacity: usize = slab.arenas[index].?.block_count;
    for (allocations[1 .. first_arena_capacity + 1]) |*slot| {
        slot.* = try slab.allocAtIndex(backing, index, true);
    }
    try std.testing.expect(slab.arenas[index].?.next != null);

    for (allocations[0..first_arena_capacity]) |allocation| {
        slab.freeAtIndex(&backing, allocation, index);
    }
    // The first arena emptied and is retained; the second still holds one.
    try std.testing.expect(slab.arenas[index] != null);
    try std.testing.expect(slab.arenas[index].?.next != null);
    try std.testing.expect(slab.free_arenas[index].?.used_blocks == 0);

    // The second empties: one empty arena is kept, the other released.
    slab.freeAtIndex(&backing, allocations[first_arena_capacity], index);
    try std.testing.expect(slab.arenas[index] != null);
    try std.testing.expect(slab.arenas[index].?.next == null);
    try std.testing.expect(slab.arenas[index].?.used_blocks == 0);
}

test "small slab GC allocation reuses allocator header for metadata" {
    const TestHeader = extern struct {
        prev: ?*@This() = null,
        next_non_object: ?*@This() = null,
    };
    const TestGc = extern struct {
        pub const gc_kind_tag: u8 = 3;

        header: TestHeader = .{},
        payload: [48]u8 = @splat(0),
    };

    comptime std.debug.assert(@sizeOf(TestGc) == 64);

    const account = try runtime_owner.createAllocationTestRuntime(std.testing.allocator);
    defer account.destroy();
    defer account.gc.deinitGcCarrier();
    account.gc.enableSmallObjectSlab();
    defer account.gc.deinitSmallObjectSlab();

    const first = try account.gc.createCell(TestGc);
    first.* = .{};
    const second = try account.gc.createCell(TestGc);
    second.* = .{};

    // qjs js_def_malloc: usable + MALLOC_OVERHEAD per block.
    // 64-byte TestGc lands in class 72; Linux charge is the class size.
    const test_class = SmallObjectSlab.classIndex(@sizeOf(TestGc), gc_alloc.gcAlignment(TestGc)).?;
    try std.testing.expectEqual(2 * gc_alloc.accountedMallocSize(@sizeOf(TestGc), test_class), account.diagnostics.allocations.allocated_bytes);

    const second_meta: [*]const u8 = @ptrFromInt(@intFromPtr(second) - gc_alloc.gc_prefix_size);
    // Byte 2 = allocator class stamp (qjs block_size_idx), byte 3 = kind in
    // the low 3 bits of the shared kind/flags byte (qjs gc_obj_type:7|mark:1).
    const expected_class = SmallObjectSlab.classIndex(@sizeOf(TestGc), gc_alloc.gcAlignment(TestGc)).?;
    try std.testing.expectEqual(expected_class, second_meta[2]);
    try std.testing.expectEqual(TestGc.gc_kind_tag, second_meta[3] & 0x7);
    // Offset 4: trace carriers must be born with epoch/state zero so
    // publication cannot read them marked.
    const expected_lifetime: u32 = 0;
    try std.testing.expectEqual(expected_lifetime, @as(*align(4) const u32, @ptrFromInt(@intFromPtr(second) - 4)).*);

    // Free a non-zero-index block, then prove its allocator index survived GC
    // prefix initialization by reusing the same slot.
    account.gc.destroyCell(TestGc, second);
    const reused = try account.gc.createCell(TestGc);
    try std.testing.expectEqual(@intFromPtr(second), @intFromPtr(reused));

    account.gc.destroyCell(TestGc, reused);
    account.gc.destroyCell(TestGc, first);
    try std.testing.expectEqual(@as(usize, 0), account.diagnostics.allocations.allocated_bytes);
}

test "GC ledger charges slab class usable plus malloc overhead (qjs:2168)" {
    const account = try runtime_owner.createAllocationTestRuntime(std.testing.allocator);
    defer account.destroy();
    account.gc.enableSmallObjectSlab();
    defer account.gc.deinitSmallObjectSlab();

    // 32-byte raw payload → total 40 → class 40. Linux charge is the class size.
    const request: usize = 32;
    const class = SmallObjectSlab.classIndex(request, .@"8").?;
    try std.testing.expectEqual(@as(usize, 40), SmallObjectSlab.blockSize(class));
    const charged = gc_alloc.accountedMallocSize(request, class);
    if (malloc_overhead == 8) {
        try std.testing.expectEqual(@as(usize, 40), charged);
    } else {
        try std.testing.expectEqual(request, charged);
    }

    const ptr = try account.allocNative(u8, request);
    // The class-size formula above is what a GC slab block charges. An
    // ordinary byte slice charges the request even while the slab is enabled.
    try std.testing.expectEqual(request, account.diagnostics.allocations.allocated_bytes);
    account.freeNative(u8, ptr);
    try std.testing.expectEqual(@as(usize, 0), account.diagnostics.allocations.allocated_bytes);

    const standalone_request: usize = 600;
    const standalone = try account.allocNative(u8, standalone_request);
    try std.testing.expectEqual(standalone_request, account.diagnostics.allocations.allocated_bytes);
    account.freeNative(u8, standalone);
    try std.testing.expectEqual(@as(usize, 0), account.diagnostics.allocations.allocated_bytes);
}
test "memory account tracks same-allocator allocation and free" {
    const account = try runtime_owner.createAllocationTestRuntime(std.testing.allocator);
    defer account.destroy();
    const buf = try account.allocNative(u8, 16);
    try std.testing.expect(account.hasOutstandingAllocations());
    account.freeNative(u8, buf);
    try std.testing.expect(!account.hasOutstandingAllocations());
}

test "memory account treats zero-length allocations as inert" {
    const account = try runtime_owner.createAllocationTestRuntime(std.testing.allocator);
    defer account.destroy();
    const empty = try account.allocNative(u8, 0);

    try std.testing.expectEqual(@as(usize, 0), account.diagnostics.allocations.allocated_bytes);
    try std.testing.expectEqual(@as(usize, 0), account.diagnostics.allocations.allocation_count);
    try std.testing.expect(!account.hasOutstandingAllocations());

    account.freeNative(u8, empty);
    try std.testing.expectEqual(@as(usize, 0), account.diagnostics.allocations.allocated_bytes);
    try std.testing.expectEqual(@as(usize, 0), account.diagnostics.allocations.allocation_count);
    try std.testing.expect(!account.hasOutstandingAllocations());
}

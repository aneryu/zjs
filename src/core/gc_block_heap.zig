//! 64 KiB block heap (tracing-gc-design.md §4.2 / §4.3 / §8.1).
//!
//! Superblocks are 2 MiB mappings split into 64 KiB-aligned blocks. A block
//! holds one size class. Empty blocks return to the runtime free list; the
//! mapping is released only as a whole superblock. One over-sized mapping
//! plus per-block `munmap` is forbidden.
//!
//! Every published Object lives in a block cell (terminal layout M); the
//! non-block kinds (shape, realm, module, function bytecode, var_ref) keep
//! the slab / standalone allocator and their intrusive lists.

const std = @import("std");
const builtin = @import("builtin");

const gc_representation = @import("gc_representation_constants.zig");
const gc = @import("gc.zig");
const carrier = @import("gc_carrier.zig");
const space = @import("gc_space.zig");

const block_generation_enabled = carrier.block_generation_enabled;
const lifecycle_state_enabled = carrier.lifecycle_state_enabled;
const block_tracking_enabled = carrier.block_tracking_enabled;

/// Test-only proof that a young-only morgue close does not accidentally run
/// the major-only whole-heap publication scan.
pub var publish_completed_hot_blocks_calls_for_test: if (builtin.is_test) usize else void =
    if (builtin.is_test) 0 else {};

/// Test-only injection point for `Heap.indexExtentPages`: when set, the page
/// fan-out fails after this many pages, so the rollback and the linear
/// fallback can be exercised without depending on where a hash map happens
/// to grow.
pub var extent_page_index_fail_after_for_test: if (builtin.is_test) ?usize else void =
    if (builtin.is_test) null else {};

/// Test-only proof that `allocMedium` is O(1) in the superblock count: every
/// superblock this counter charges is one the allocator actually looked at.
/// The bucket index makes that exactly one per allocation (plus the reserve
/// that creates a superblock), where `findMediumRun` charged one per LIVE
/// superblock per allocation.
pub var medium_superblock_visits_for_test: if (builtin.is_test) usize else void =
    if (builtin.is_test) 0 else {};

/// Test-only OOM injection point for block-cell allocation.
///
/// The block heap is a pool: once a superblock is mapped, cell allocation
/// never touches the backing allocator again, so `checkAllAllocationFailures`
/// and the hand-rolled fail-at-N allocators are structurally blind to it --
/// the OOM tier could not reach a single "cell exhaustion" error path. A probe
/// allocation inside `allocSmallCell` would fix the visibility at the cost of
/// breaking everything the tier is built on: it would add allocations to the
/// `oom_cap` "OOM delivery allocates nothing" invariant, multiply the corpus
/// index space, and make every sticky sweep fail at the first cell.
///
/// So the cell dimension gets its own channel instead. The hook is consulted
/// on the slow arm of `allocSmallCell` only (the arm that would take a new
/// block), returns `error.OutOfMemory` without touching or charging the
/// backing allocator, and leaves the heap unmutated so a later retry behaves
/// exactly as if the failure had never been offered. The driver in
/// `src/tests/oom.zig` points it at the same counter its allocator injection
/// uses, which is what folds cell failures into one `fail_index` space.
pub const CellFailureInjector = struct {
    context: *anyopaque,
    /// Called once per candidate cell allocation. `true` means "fail this
    /// one". Implementations must be non-sticky if the sweep expects the
    /// engine to keep running after the injected failure.
    shouldFail: *const fn (context: *anyopaque) bool,
};

pub var cell_failure_injector: if (builtin.is_test) ?CellFailureInjector else void =
    if (builtin.is_test) null else {};

/// How many times the slow arm has offered an injection point, armed or not.
/// The hook is only worth anything if it sits on a path the engine actually
/// takes, and "the block heap stopped reaching this arm" is exactly the kind
/// of silent regression that made the cell dimension invisible in the first
/// place, so a test asserts this counter moves.
pub var cell_injection_questions_for_test: if (builtin.is_test) usize else void =
    if (builtin.is_test) 0 else {};

inline fn injectedCellFailure() bool {
    if (comptime !builtin.is_test) return false;
    cell_injection_questions_for_test += 1;
    const injector = cell_failure_injector orelse return false;
    return injector.shouldFail(injector.context);
}

pub const superblock_bytes: usize = 2 * 1024 * 1024;
pub const block_bytes: usize = 64 * 1024;
pub const blocks_per_superblock: usize = superblock_bytes / block_bytes;
/// Page radix shared with the conservative address registry
/// (`gc_address_registry.page_shift` aliases these): medium page runs, large
/// mappings and the standalone occupant fan-out all key on the same 4 KiB
/// grid, so there must be exactly one definition of it.
pub const page_shift: u6 = 12;
pub const page_bytes: usize = 1 << page_shift;
pub const pages_per_superblock: usize = superblock_bytes / page_bytes;
/// A medium extent is everything the small classes will not take and the
/// large threshold will not claim, so its page run is bounded by
/// `space.large_min_bytes`. Free runs longer than that are indistinguishable
/// for allocation purposes and are clamped to this value, which is what makes
/// the free-run bucket array a fixed 17 slots instead of one per page.
pub const max_medium_pages: u32 = @intCast(space.large_min_bytes / page_bytes);
const medium_bucket_count: usize = max_medium_pages + 1;
/// Absent superblock index in the medium free-run buckets.
const bucket_nil: u32 = std.math.maxInt(u32);
pub const block_align: std.mem.Alignment = .fromByteUnits(block_bytes);
/// Bytes handed back to the OS when a free block is decommitted. The header
/// stays mapped; on platforms whose OS page is larger than `page_bytes`
/// (aarch64 macOS, 16 KiB) the retained prefix is one OS page so `madvise`
/// sees a `page_size_min`-aligned pointer.
pub const decommit_bytes: usize = blk: {
    const start = std.mem.alignForward(usize, page_bytes, std.heap.page_size_min);
    break :blk if (start < block_bytes) block_bytes - start else 0;
};
/// Free-list representation.
///
/// A free cell stores its successor in its first four bytes, which are also
/// the object metadata prefix: byte 2 is `alloc_info` (whose low five bits
/// are the "this is a block cell" marker) and byte 3 is the GC flags. Any
/// code that mistakes a free cell for a live header and writes a flag bit
/// therefore writes into the link. That is not hypothetical: with a
/// terminator of 0xFFFFFFFF, byte 2 read 0x1F, the cell impersonated a live
/// block cell, and clearing `young` turned the link into 0xEFFFFFFF, which
/// the allocator then followed outside the block.
///
/// So the link lives in the LOW 16 bits and the high half is a poison
/// pattern. A cell index cannot exceed `block_bytes / min_class_bytes`, so
/// 16 bits is ample, and the two bytes a header write can reach are now
/// outside the link entirely -- for SET bits as well as cleared ones, which
/// a cleverly-chosen 32-bit terminator could not manage. The poison is
/// chosen so a free cell read as a header is rejected by every path that
/// matters: `block_size_idx` reads 0 (not a block cell), `heap_accounted`
/// reads 0 (the iterators and `shade` refuse it), and `cycle_visited` reads 1
/// (`shade` refuses it again). The kind nibble reads `.string`; that is
/// incidental, `heap_accounted`/`cycle_visited` are what reject the word.
pub const free_nil: u32 = 0xFFFF;
pub const free_link_mask: u32 = gc_representation.free_cell_link_mask;
pub const free_poison: u32 = gc_representation.free_cell_poison;
/// Match JSC's default 0.9 `minMarkedBlockUtilization`: a completed block is
/// worth reopening when at least one tenth of its cells can form intervals.
pub const hot_reuse_min_free_percent: u32 = 10;
pub const hot_reuse_k64: u32 = 64;
pub const hot_reuse_min_interval_cells: u32 = hot_reuse_k64;

comptime {
    if (block_bytes / space.min_class_bytes > free_link_mask) @compileError("cell index does not fit the free link");
}

comptime {
    // The terminator must not read as a block-cell header. Checked rather
    // than trusted, because the value looks arbitrary and its constraint is
    // three fields away in another file.
    const marker_byte: u8 = @truncate(free_nil >> 16);
    if (marker_byte & gc_representation.alloc_info_class_mask == gc_representation.block_cell_size_class)
        @compileError("free_nil impersonates a block-cell header");
}

/// Why this heap does not yet serve `createRuntime`.
///
/// A GC object is not just its struct: `memory.zig` writes an 8-byte prefix in
/// front of every allocation, and `alloc_info` in that prefix records which
/// slab class the object came from. `GCObjectHeader.meta()` reads back through
/// it. Handing out raw cells from here therefore produces headers whose
/// `meta()` dereferences uninitialised memory — wiring it into the allocation
/// funnel segfaults immediately, in `addInitializedWithSizeNoFail`'s first
/// assertion, which is exactly where it should.
///
/// Serving GC nodes means the cell layout has to carry that prefix, which is
/// the object-header representation change §4.5 defers to its own tranche with
/// its own binary and performance gates. Until then this heap is exercised
/// through its own tests and reports its geometry, and the compatibility
/// allocator keeps serving the collector.
pub const block_magic: u64 = 0x5a4a53_424c4b_0001;

/// Per-block sweep lifecycle (§8.7), the collector's only remaining consumer
/// of the former logical-window sweep model.
pub const SweepState = enum(u8) {
    fresh,
    active,
    needs_sweep,
    sweeping,
    swept,
};

const max_bitmap_words: usize = (block_bytes / space.min_class_bytes + 63) / 64;

pub const Stats = struct {
    committed_bytes: usize = 0,
    live_bytes: usize = 0,
    superblocks: usize = 0,
    large_maps: usize = 0,
    live_count: usize = 0,
    medium_allocs: usize = 0,
    large_allocs: usize = 0,
    large_reserves: usize = 0,
    /// Bytes handed back to the OS from fully-free blocks (cumulative), and
    /// bytes re-faulted when such a block was reopened. The difference is the
    /// currently-decommitted figure already subtracted from `committed_bytes`.
    decommitted_bytes: usize = 0,
    recommitted_bytes: usize = 0,
    /// Free-list scans that passed the 100ms throttle. This distinguishes
    /// "nothing was old enough" from "the scavenger was never serviced" in
    /// heap-shrink reports.
    decommit_checks: usize = 0,
    decommit_max_batch_bytes: usize = 0,
    malloc_trim_attempts: usize = 0,
    malloc_trim_successes: usize = 0,
    /// Completed partial blocks published to the per-class hot pool, and
    /// blocks subsequently selected instead of initializing fresh storage.
    deferred_block_runs_completed: usize = 0,
    hot_blocks_published: usize = 0,
    hot_blocks_reopened: usize = 0,
    /// TGC S4-f (2): why a candidate partial block was NOT admitted to the
    /// per-class hot pool. The pool is the only route by which a
    /// partially-emptied block re-enters allocation, so a rejection here is a
    /// 64 KiB block that stays committed with its handful of survivors until
    /// some later cycle changes the answer.
    hot_publish_rejected_empty: usize = 0,
    hot_publish_rejected_capacity: usize = 0,
    hot_publish_rejected_active: usize = 0,
    hot_publish_rejected_doomed: usize = 0,
    hot_publish_rejected_young: usize = 0,
    hot_publish_rejected_listed: usize = 0,
    hot_publish_rejected_decommitted: usize = 0,
    /// Candidates refused from the cached verdict of an earlier reopen
    /// (`Block.flag_hot_rejected`), i.e. bitmap walks the cache saved.
    hot_publish_rejected_cached_k: usize = 0,
    /// Hot blocks `openBlock` rejected for having no interval long enough to
    /// be worth the reopen (`hot_reuse_min_interval_cells`). They are dropped
    /// from the pool, so the next chance to reuse them is the next major.
    hot_blocks_k_rejected: usize = 0,
    /// Corpses reclaimed straight into the alloc bitmap -- no free link, no
    /// parked entry, no header read (`Block.reclaimDoomedIntoBitmap`).
    ///
    /// TGC S4-e retired the Pass-A settlement this counter was born for
    /// (`passa_settled_cells`), so the name now says what the number is. The
    /// `--gc-stats` line text is unchanged on purpose: `gc_stats_snapshot.py`
    /// compares leaf sets, and dropping a leaf invalidates every frozen
    /// Stage-0 baseline.
    bitmap_reclaimed_cells: usize = 0,
    /// Wholly-empty medium superblocks whose mapping was returned to the
    /// backing allocator (TGC S2-f (2)). Deliberately NOT folded into
    /// `decommitted_bytes`: that counter is paired with `recommitted_bytes`
    /// and is divided by `decommit_bytes` to report a BLOCK count, which a
    /// 2 MiB superblock release would corrupt.
    medium_superblocks_released: usize = 0,
    medium_superblock_bytes_released: usize = 0,

    pub fn currentDecommittedBytes(self: Stats) usize {
        return self.decommitted_bytes -| self.recommitted_bytes;
    }
};

/// TGC S4-d spec 2.4: one block's condemnation split by whether the corpse
/// owes a destructor. `dead - finalizing` is the bitmap-reclaimed population.
pub const DoomedCounts = struct { dead: u32 = 0, finalizing: u32 = 0 };

/// TGC S4-f (2): one size class's share of the committed block heap, as a
/// walk of every block ever handed out by `takeClassedBlock`.
///
/// The question this exists to answer is why `committed/live` reached 21-34x
/// after S4-b/c moved the storage kinds into the heap. `committed_bytes` is a
/// superblock count times 2 MiB and a superblock's `used_blocks` never falls,
/// so the figure is the PEAK number of distinct blocks the allocator ever
/// opened -- and the occupancy histogram below says whether those blocks are
/// empty (a decommit question), thinly populated (a reuse question) or full
/// (an honest live-set question).
pub const BlockCensusRow = struct {
    cell_bytes: u32 = 0,
    blocks: u32 = 0,
    cells: u64 = 0,
    allocated: u64 = 0,
    /// Occupancy buckets, by `allocated_count / cell_count`.
    empty: u32 = 0,
    lt10: u32 = 0,
    lt50: u32 = 0,
    ge50: u32 = 0,
    /// Blocks carrying `flag_young` (they hold at least one cell published
    /// since the last retirement) and blocks whose cell pages are returned.
    young: u32 = 0,
    decommitted: u32 = 0,
    /// List membership at census time: the per-class allocation target, the
    /// hot (partially-free, republished by a major) pool, and the wholly-empty
    /// pool the decommit scavenger reads.
    active: u32 = 0,
    hot_listed: u32 = 0,
    free_listed: u32 = 0,
};

pub const BlockCensus = struct {
    rows: [space.class_count]BlockCensusRow = @splat(.{}),
    classed_superblocks: usize = 0,
    other_superblocks: usize = 0,
    /// Slots inside a classed superblock's `used_blocks` prefix whose header
    /// does not read back as an initialized block (a `resetBlock` that failed
    /// after the slot was claimed). Expected zero.
    uninitialized_blocks: usize = 0,
};



pub fn canAllocCellSize(n: usize) bool {
    if (n == 0 or n >= space.large_min_bytes) return false;
    return space.classIndexForPayload(n) != null;
}

/// Accounting twin of `allocCell`: map a requested physical cell payload to
/// the block class that serves it, then exclude the metadata prefix. This pure
/// calculation is the shared credit/debit authority; tests pin it against the
/// actual block header without putting that cold read on production paths.
pub inline fn accountedBodyBytesForRequest(n: usize, metadata_prefix_bytes: usize) ?usize {
    if (n == 0 or n >= space.large_min_bytes) return null;
    const class_idx = space.classIndexForPayload(n) orelse return null;
    const cell_size = space.classes[class_idx];
    std.debug.assert(cell_size >= metadata_prefix_bytes);
    return cell_size - metadata_prefix_bytes;
}

/// `tombstone` is a slot whose 2 MiB mapping has been returned to the backing
/// allocator. The slot itself must stay: `Block.super_index`,
/// `MediumExtent.super_index` and the medium bucket links are all array
/// INDICES, so compacting `Heap.superblocks` would silently repoint them.
/// Every `sb.kind != .classed` / `!= .medium` walk skips a tombstone already;
/// the two places that must know about it are `Heap.deinit` (nothing to free)
/// and `Heap.census`.
const SuperblockKind = enum { classed, medium, tombstone };

const CellLifecycle = struct {
    state: carrier.LifecycleState = .free,
    accounted_bytes: usize = 0,
};

const Superblock = struct {
    bytes: []align(block_bytes) u8,
    kind: SuperblockKind,
    used_blocks: u32 = 0,
    /// Medium superblocks use this as their allocation-page bitmap. Classed
    /// superblocks have no medium extents, so their low 32 bits index the
    /// blocks whose `allocated_count` is non-zero. The storage already exists
    /// in both variants; sharing it by kind keeps the sparse condemnation
    /// index footprint-neutral.
    page_bits: [pages_per_superblock / 64]u64 = @splat(0),
    /// Medium superblocks only: the longest run of free pages in `page_bits`,
    /// clamped to `max_medium_pages`. It doubles as this superblock's index
    /// in `Heap.medium_buckets`, so "which bucket am I in" needs no separate
    /// field and cannot disagree with the bitmap. 0 means "serves no medium
    /// request" and is deliberately not linked anywhere.
    max_free_run: u8 = 0,
    /// Doubly-linked bucket membership (superblock indices, `bucket_nil` for
    /// absent). Doubly linked because a free re-buckets an arbitrary
    /// superblock, not the head of a list.
    bucket_prev: u32 = bucket_nil,
    bucket_next: u32 = bucket_nil,
    /// Medium superblocks only: `Heap.clock_ns` when the page bitmap last
    /// became wholly empty. Same coarse stamp and the same idle rule as
    /// `Block.free_time_ns`, and for the same reason: releasing on "empty at a
    /// collection boundary" makes the policy a function of collection
    /// FREQUENCY, and pdfjs collects every ~10 ms. Without this gate the
    /// release traded 5.8 s of wall for 3.6 GB of mmap/munmap churn (1711
    /// superblocks returned in one run) -- exactly the failure the block
    /// decommit policy already documents.
    empty_since_ns: u64 = 0,
    /// Tombstoned slots only: intrusive free-slot chain consumed by
    /// `reserveSuperblock`. Intrusive and not an `ArrayList` because
    /// `releaseEmptyMediumSuperblocks` runs at a collection boundary and must
    /// not be able to fail.
    free_slot_next: u32 = bucket_nil,
    /// Generation and lifecycle are separate components.  A generation-only
    /// production switch cannot silently allocate/write lifecycle storage.
    block_incarnations: if (block_generation_enabled) [blocks_per_superblock]u32 else void =
        if (block_generation_enabled) @splat(0) else {},
    cell_generations: if (block_generation_enabled) [blocks_per_superblock][]u32 else void =
        if (block_generation_enabled) @splat(&.{}) else {},
    cell_lifecycles: if (lifecycle_state_enabled) [blocks_per_superblock][]CellLifecycle else void =
        if (lifecycle_state_enabled) @splat(&.{}) else {},
};

/// Extent mark storage (TGC S2). Neither extent kind has a block bitmap, so
/// the mark lives in the table entry: an extent is marked in the current
/// major iff `mark_epoch == Heap.mark_epoch`. Epoch 0 is newborn/unmarked
/// (the heap's epoch is even and only ever advanced by `beginMajor`).
/// Only string extents exist -- Object never allocates an extent, ropes
/// always fit a cell -- so no kind field is needed yet; the sweep below
/// treats every entry as a string extent.
const LargeMap = struct {
    bytes: []u8,
    /// Requested size; `bytes.len` is the page-rounded mapping. The sweep
    /// hands this to the destroy callback so accounting debits what was
    /// credited.
    user_bytes: usize,
    mark_epoch: u64 = extent_unmarked_epoch,
    /// TGC S4-a: the extent twin of `Block.finalizerBits`. Set at
    /// construction for carriers whose death owes an external release; the
    /// S4-d extent sweep runs a destroy callback only for those.
    needs_finalizer: bool = false,
};

const MediumExtent = struct {
    super_index: u32,
    page: u32,
    pages: u32,
    user_bytes: usize,
    mark_epoch: u64 = extent_unmarked_epoch,
    needs_finalizer: bool = false,
};

/// Newborn / cleared extent mark. Heap epochs are always even (`beginMajor`
/// strides by two), so an odd sentinel can never be mistaken for one -- which
/// is what lets a MINOR mark extents at `mark_epoch == 0`, before the first
/// major has ever run. The previous "0 means unmarked" rule made every
/// minor-marked extent read dead in that window.
const extent_unmarked_epoch: u64 = 1;

/// One entry per 4 KiB page an extent's MAPPING covers, so conservative
/// candidate resolution is a shift and a hash probe instead of a walk of
/// both extent tables (`Heap.extentContaining`).
///
/// `end` is `base + user_bytes`, the inclusive one-past-end bound the
/// occupant table uses. It is cached here rather than re-read from
/// `medium`/`large` so a hit costs one probe, not two.
///
/// The page -> extent mapping is a FUNCTION, not a relation: medium runs come
/// out of the superblock page bitmap and large mappings are page-aligned with
/// a page-rounded length, so two extents can never share a page. The only
/// address an extent claims outside its own pages is a one-past-end that
/// falls exactly on the next page boundary; `extentContaining` recovers that
/// with a second probe on `addr - 1` instead of turning the map into a list.
const ExtentPage = struct {
    base: usize,
    end: usize,
};

pub const Block = extern struct {
    magic: u64 = block_magic,
    mark_epoch: u64 = 0,
    cell_size: u32 = 0,
    cell_count: u32 = 0,
    allocated_count: u32 = 0,
    bump: u32 = 0,
    free_list: u32 = free_nil,
    size_class: u16 = 0,
    /// Physical block lifecycle marker. Observable blocks are active or
    /// empty/swept; condemnation and sliced destruction intentionally use the
    /// doomed bitmap/list rather than the historical five-state model.
    sweep_state: SweepState = .fresh,
    flags: u8 = 0,
    /// Intrusive doomed-block link (address; 0 = not linked; 1 = tail). A
    /// block joins at condemnation when its snapshot finds dead cells, and
    /// leaves when the destruction slices empty its doomed bitmap.
    doomed_link: usize = 0,
    /// Intrusive young-block link (address; 0 = not linked). A block joins
    /// the list the first time a cycle publishes a young object into it --
    /// including an OLD block that hands out a recycled cell, which is what
    /// makes cell reuse compatible with the young scan: the per-cell `young`
    /// header bit filters the old neighbours.
    young_link: usize = 0,
    cells_offset: u32 = 0,
    alloc_bits_off: u32 = 0,
    mark_bits_off: u32 = 0,
    remember_bits_off: u32 = 0,
    bitmap_words: u32 = 0,
    /// Index into `Heap.superblocks`. This occupies the four-byte alignment
    /// hole that preceded `next_free`; pin the offset and total size below so
    /// the sparse nonempty index cannot silently enlarge every block header.
    super_index: u32 = 0,
    next_free: usize = 0,
    /// Lowest cell index that may still carry a doomed bit, so a block's
    /// drain is linear rather than quadratic in its bitmap words. Reset by
    /// `snapshotDoomed`, which is the only writer of those bits.
    /// Word index the doomed scan is serving, and the bits of that word not
    /// yet handed out. Reset by `snapshotDoomed`, the only writer of those
    /// bits.
    doomed_cursor: u32 = 0,
    /// Exclusive end of the current free interval. This occupies the former
    /// four-byte alignment hole before `doomed_word`, keeping Block at 112 B.
    /// It is meaningful only with `flag_interval_allocator`.
    interval_end: u32 = 0,
    doomed_word: u64 = 0,
    /// Coarse wall clock (`Heap.clock_ns`, stamped at cycle boundaries) when
    /// the block went on the free list. Idle DURATION, not collection count,
    /// gates the decommit -- see `Heap.releaseFreeBlockPages`.
    free_time_ns: u64 = 0,

    comptime {
        std.debug.assert(@offsetOf(@This(), "super_index") == 76);
        std.debug.assert(@offsetOf(@This(), "next_free") == 80);
        std.debug.assert(@offsetOf(@This(), "interval_end") == 92);
        std.debug.assert(@sizeOf(@This()) == 112);
    }

    pub const flag_young: u8 = 1 << 0;
    /// TGC S4-f (2): `openBlock` reopened this block, rebuilt its free
    /// intervals and found none long enough to be worth allocating from
    /// (`hot_reuse_min_interval_cells`). The answer cannot change until the
    /// block gains free space, so it is cached here and cleared by the two
    /// sites that grow a block's free space -- `freeSmall` and
    /// `reclaimDoomedCells` -- plus `resetBlock`, which rewrites `flags`.
    ///
    /// Without the cache the minor-time publication slice re-offered the same
    /// rejects on every sweep and `openBlock` paid a full bitmap walk to
    /// re-derive the same no: earley-boyer took 592,540 rejected reopens
    /// against 112,076 accepted ones (-6.5% on its score), splay 58,569.
    pub const flag_hot_rejected: u8 = 1 << 1;
    /// Stage-3 Pass-A settlement left holes that only the alloc bitmap
    /// records: `settleDoomedCellInPassA` clears a cell's alloc bit without
    /// writing a free link, so `free_list`/`bump` no longer enumerate every
    /// hole in this block. The bitmap is the sole canonical free-space
    /// representation until `rebuildFreeIntervals` reconstructs the allocator
    /// view from it -- the same promise `flag_hot_list` makes, which is why
    /// the audit treats the two identically.
    ///
    /// (Bit 4 previously held `flag_epoch_transition`, which the atomic
    /// `ensureMarkEpoch` rewrite left declared but never read or written.)
    const flag_bitmap_canonical: u8 = 1 << 4;
    /// The block's cell pages (everything past the header page) have been
    /// returned to the OS with MADV_DONTNEED. The header page stays mapped
    /// and populated, so the free-list link, magic, and bitmaps remain valid;
    /// `resetBlock` clears this flag on reuse because it rewrites the whole
    /// header anyway and the cells are rebuilt from `bump = 0`.
    const flag_decommitted: u8 = 1 << 5;
    /// `bump..interval_end` plus `free_list` describe address-ordered free
    /// intervals. While such a block is active, `next_free` is a low-16-bit
    /// LIFO for exceptional cells returned after interval publication.
    const flag_interval_allocator: u8 = 1 << 6;
    /// The populated block is linked through `next_free` on `Heap.hot_blocks`.
    const flag_hot_list: u8 = 1 << 7;

    fn fromAddr(addr: usize) ?*Block {
        if (addr < block_bytes) return null;
        const base = addr & ~@as(usize, block_bytes - 1);
        const block: *Block = @ptrFromInt(base);
        if (block.magic != block_magic) return null;
        return block;
    }

    fn bitmaps(self: *Block) struct { alloc: []u64, mark: []u64, remember: []u64 } {
        const base: [*]u8 = @ptrCast(self);
        const words = self.bitmap_words;
        return .{
            .alloc = @as([*]u64, @ptrCast(@alignCast(base + self.alloc_bits_off)))[0..words],
            .mark = @as([*]u64, @ptrCast(@alignCast(base + self.mark_bits_off)))[0..words],
            .remember = @as([*]u64, @ptrCast(@alignCast(base + self.remember_bits_off)))[0..words],
        };
    }

    /// The `needs_finalizer` bitmap (TGC S4-a). Derived rather than stored:
    /// see `blockGeometry`. Only cells whose bit is set are handed to a
    /// destructor by the S4-d sweep; the rest are reclaimed by clearing
    /// their alloc bit, without touching the header.
    pub fn finalizerBits(self: *Block) []u64 {
        const base: [*]u8 = @ptrCast(self);
        const words = self.bitmap_words;
        const offset = self.remember_bits_off + words * 8;
        return @as([*]u64, @ptrCast(@alignCast(base + offset)))[0..words];
    }

    pub fn setFinalizerBit(self: *Block, index: u32) void {
        setBitPlain(self.finalizerBits(), index);
    }

    pub fn clearFinalizerBit(self: *Block, index: u32) void {
        clearBitPlain(self.finalizerBits(), index);
    }

    pub fn cellNeedsFinalizer(self: *Block, index: u32) bool {
        return testBitPlain(self.finalizerBits(), index);
    }

    fn cellPtr(self: *Block, index: u32) [*]u8 {
        const base: [*]u8 = @ptrCast(self);
        return base + self.cells_offset + index * self.cell_size;
    }

    pub fn cellIndex(self: *const Block, ptr: usize) ?u32 {
        const base = @intFromPtr(self) + self.cells_offset;
        if (ptr < base) return null;
        const off = ptr - base;
        if (off % self.cell_size != 0) return null;
        const index: u32 = @intCast(off / self.cell_size);
        if (index >= self.cell_count) return null;
        return index;
    }

    /// Interior-pointer resolution: the cell containing `ptr`, or null when
    /// `ptr` lands in the header/bitmap region or past the last cell. Unlike
    /// `cellIndex` this does not require the exact cell base -- a conservative
    /// stack word may point anywhere inside an object.
    pub fn cellIndexInterior(self: *const Block, ptr: usize) ?u32 {
        const base = @intFromPtr(self) + self.cells_offset;
        if (ptr < base) return null;
        const index: u32 = @intCast((ptr - base) / self.cell_size);
        if (index >= self.cell_count) return null;
        return index;
    }

    /// The alloc bitmap words, for word-skipping enumeration.
    pub fn allocWords(self: *Block) []u64 {
        return self.bitmaps().alloc;
    }

    /// The condemnation bitmap words (TGC S4-g (3)), for enumerating a
    /// block's corpses without reading one header per CELL. Only meaningful
    /// between `snapshotDoomed` and the reclaim that clears them -- outside
    /// that window this bitmap is the generational remembered column, which
    /// is exactly what `isDoomed` already assumes of its callers.
    pub fn doomedWords(self: *Block) []u64 {
        return self.bitmaps().remember;
    }

    /// One word of dead candidates: allocated cells the current epoch never
    /// marked. A stale epoch means no cell was marked, so every allocated
    /// cell is a candidate.
    pub fn deadWord(self: *Block, word_index: usize, epoch: u64) u64 {
        const alloc = self.bitmaps().alloc[word_index];
        if (@atomicLoad(u64, &self.mark_epoch, .acquire) != epoch) return alloc;
        const mark = @atomicLoad(u64, &self.bitmaps().mark[word_index], .monotonic);
        return alloc & ~mark;
    }

    pub fn cellAllocated(self: *Block, index: u32) bool {
        return testBitPlain(self.bitmaps().alloc, index);
    }

    pub fn cellBase(self: *const Block, index: u32) usize {
        return @intFromPtr(self) + self.cells_offset + index * self.cell_size;
    }

    /// The block containing a cell KNOWN to be a block cell (its prefix
    /// carries the route marker). No membership check: the marker is the
    /// proof, and the mask is pure arithmetic on a mapped page.
    pub inline fn fromCellTrusted(cell_addr: usize) *Block {
        return @ptrFromInt(cell_addr & ~@as(usize, block_bytes - 1));
    }

    /// Unmark under the epoch scheme: a stale bitmap already reads unmarked
    /// for every cell, so only a current-epoch bit needs clearing.
    pub fn clearMark(self: *Block, index: u32, epoch: u64) void {
        if (@atomicLoad(u64, &self.mark_epoch, .acquire) != epoch) return;
        clearBit(self.bitmaps().mark, index);
    }

    /// Clear marks for this block's published young cells during a minor's
    /// owner-thread stop-the-world window.
    ///
    /// The generic header path re-derives this block and cell index, reloads
    /// the block epoch, then performs one atomic RMW for every young object.
    /// Here the block is already known and marker lanes are excluded. Walk the
    /// allocation bitmap a word at a time, retain old-cell marks, and issue at
    /// most one plain mark-word update for 64 cells. The header walk is still
    /// intentional: recycled cells can put old and young objects in the same
    /// block, so clearing a whole mark word would destroy sticky old marks.
    pub fn clearYoungMarksStw(self: *Block, epoch: u64) void {
        if (self.mark_epoch != epoch) return;
        const maps = self.bitmaps();
        words: for (maps.alloc, 0..) |alloc_word, word_index| {
            var candidates = alloc_word & maps.mark[word_index];
            var young_marks: u64 = 0;
            while (candidates != 0) {
                const bit: u6 = @intCast(@ctz(candidates));
                const index: u32 = @intCast(word_index * 64 + bit);
                if (index >= self.cell_count) break :words;
                const cell = self.cellBase(index);
                const alloc_info = @as(*const u8, @ptrFromInt(cell + gc_representation.metadata_alloc_info_offset)).*;
                const flags = @as(*const u8, @ptrFromInt(cell + gc_representation.metadata_flags_offset)).*;
                if (alloc_info & gc_representation.alloc_info_heap_accounted_mask != 0 and
                    flags & gc_representation.metadata_young_mask != 0 and
                    !self.isDoomed(index))
                {
                    young_marks |= @as(u64, 1) << bit;
                }
                candidates &= candidates - 1;
            }
            if (young_marks != 0) maps.mark[word_index] &= ~young_marks;
        }
    }

    pub inline fn isYoungListed(self: *const Block) bool {
        return (self.flags & flag_young) != 0;
    }

    fn hasPendingDoomed(self: *Block) bool {
        if (self.doomed_word != 0) return true;
        for (self.bitmaps().remember) |word| {
            if (word != 0) return true;
        }
        return false;
    }

    fn cellPendingDoomed(self: *Block, index: u32) bool {
        if (self.isDoomed(index)) return true;
        return self.doomed_word & bitMask(index) != 0 and self.doomed_cursor == index / 64;
    }

    /// Snapshot this block's dead cells (allocated, unmarked in `epoch`)
    /// into the doomed bitmap -- the block's third bitmap, which the
    /// remembered-set design reserved and nothing else uses yet. Word
    /// arithmetic only: the whole heap's condemnation becomes microseconds
    /// of STW instead of a walk that touches every corpse.
    ///
    /// Returns the dead count and, of those, how many owe a destructor
    /// (TGC S4-d): the complement is the population the sweep reclaims with
    /// word arithmetic and accounts for in ONE block-level debit, so the split
    /// has to be counted here, where the words are already in registers.
    pub fn snapshotDoomed(self: *Block, epoch: u64) DoomedCounts {
        const maps = self.bitmaps();
        const fin = self.finalizerBits();
        self.doomed_cursor = 0;
        self.doomed_word = 0;
        var counts = DoomedCounts{};
        const stale = @atomicLoad(u64, &self.mark_epoch, .acquire) != epoch;
        for (maps.alloc, 0..) |alloc_word, i| {
            const mark_word = if (stale) 0 else @atomicLoad(u64, &maps.mark[i], .monotonic);
            const doomed = alloc_word & ~mark_word;
            // Store only when it changes. Condemnation rewrites every word
            // of every live block's doomed bitmap once per collection --
            // ~334 blocks x 13 words x 7,748 cycles on earley-boyer -- and
            // the common word is zero over zero. A load and a compare do not
            // dirty the line; the store does.
            if (doomed != 0 or maps.remember[i] != 0) maps.remember[i] = doomed;
            if (doomed == 0) continue;
            counts.dead += @popCount(doomed);
            counts.finalizing += @popCount(doomed & fin[i]);
        }
        return counts;
    }

    /// Pop the next doomed cell index, clearing its bit.
    ///
    /// The cursor is the point: callers drain a block corpse by corpse, and
    /// restarting the bitmap scan at word 0 each time made draining a block
    /// quadratic in its word count. An 80-byte class packs ~800 cells into
    /// 13 words, so a full block cost ~13x more word reads than it needed;
    /// across earley-boyer's 171 M destructions that is on the order of a
    /// billion redundant loads. The cursor only ever moves forward within a
    /// drain because `snapshotDoomed` is the only thing that sets bits, and
    /// it runs at condemnation, not during destruction.
    /// A cell that leaves the doomed set by a route other than the drain:
    /// the last WeakRef to a resource-stripped husk frees it while the drain
    /// is still walking the same block. Without this the allocator can hand
    /// the cell out again and the drain then destroys the fresh object
    /// (found by test262 FinalizationRegistry cases under `ZJS_GC_STRESS=1`).
    /// Only meaningful while the block is on the doomed list; outside that
    /// window `remember` holds remembered-set bits, which must stay.
    pub fn forgetDoomedCell(self: *Block, index: u32) void {
        if (self.doomed_link == 0) return;
        const word_index = index / 64;
        const mask = @as(u64, 1) << @as(u6, @intCast(index % 64));
        self.bitmaps().remember[word_index] &= ~mask;
        if (self.doomed_cursor == word_index) self.doomed_word &= ~mask;
    }

    /// TGC S4-d spec 2.4: pop the next condemned cell that OWES A DESTRUCTOR
    /// (`doomed & needs_finalizer`), clearing its doomed bit.
    ///
    /// What is left in the doomed bitmap when this returns null is exactly the
    /// complement -- the cells whose whole release is `alloc &= ~doomed`, which
    /// `Heap.reclaimDoomedCells` then does with word arithmetic and without
    /// reading a single header. That is the point of the batch: on splay the
    /// destructor set is a few percent of the corpses, and the other 97% used
    /// to cost a cold header line each.
    ///
    /// The `doomed_word` register cache `takeDoomedCell` keeps is deliberately
    /// NOT used here: the finalizer subset is sparse, so a whole-word cache
    /// buys nothing, and leaving it zero keeps `forgetDoomedCell` (a weak
    /// release racing the drain) a pure bitmap operation.
    pub fn takeDoomedFinalizerCell(self: *Block) ?u32 {
        const maps = self.bitmaps();
        const fin = self.finalizerBits();
        var word_index: u32 = self.doomed_cursor;
        while (word_index * 64 < self.cell_count) : (word_index += 1) {
            const word = maps.remember[word_index] & fin[word_index];
            if (word == 0) continue;
            const bit = @ctz(word);
            maps.remember[word_index] &= ~(@as(u64, 1) << @intCast(bit));
            self.doomed_cursor = word_index;
            return word_index * 64 + bit;
        }
        self.doomed_cursor = 0;
        return null;
    }

    /// TGC S4-d spec 2.4: clear every cell still in the doomed bitmap out of
    /// the alloc bitmap, in whole words. Returns the count.
    ///
    /// The three bitmaps are updated together (`mark` for hygiene -- a doomed
    /// cell is unmarked by construction, `needs_finalizer` because a recycled
    /// cell must not inherit its predecessor's duty). No header is read and no
    /// free link is written, so the block's free representation becomes the
    /// alloc bitmap alone: `flag_bitmap_canonical`, exactly the state
    /// `settleDoomedCellInPassA` used to leave one cell at a time.
    ///
    /// Callers go through `Heap.reclaimDoomedCells`, which owns the two cases
    /// this cannot express (the allocator-current block and a release that
    /// empties the block).
    fn reclaimDoomedIntoBitmap(self: *Block) u32 {
        const maps = self.bitmaps();
        const fin = self.finalizerBits();
        var freed: u32 = 0;
        for (maps.remember, 0..) |doomed, i| {
            if (doomed == 0) continue;
            maps.remember[i] = 0;
            maps.alloc[i] &= ~doomed;
            maps.mark[i] &= ~doomed;
            fin[i] &= ~doomed;
            freed += @popCount(doomed);
        }
        self.doomed_cursor = 0;
        self.doomed_word = 0;
        if (freed != 0) {
            self.allocated_count -= freed;
            self.flags |= flag_bitmap_canonical;
        }
        return freed;
    }

    pub fn takeDoomedCell(self: *Block, start: u32) ?u32 {
        // Word-at-a-time. The cursor holds the current word and the bits of
        // it still to serve, so draining a full word costs one load and one
        // store instead of one of each per corpse -- and a block of 64-byte
        // cells holds ~800 of them, so that is 64 corpses served from a
        // register. The load/store pair per corpse was 50-120 ms of stopped
        // time on raytrace by static estimate.
        if (start > self.doomed_cursor) {
            self.doomed_word = 0;
            self.doomed_cursor = start;
        }
        if (self.doomed_word != 0) {
            const bit = @ctz(self.doomed_word);
            self.doomed_word &= self.doomed_word - 1;
            return self.doomed_cursor * 64 + bit;
        }
        const maps = self.bitmaps();
        var word_index: u32 = self.doomed_cursor;
        while (word_index * 64 < self.cell_count) : (word_index += 1) {
            const word = maps.remember[word_index];
            if (word != 0) {
                maps.remember[word_index] = 0;
                self.doomed_cursor = word_index;
                self.doomed_word = word & (word - 1);
                return word_index * 64 + @ctz(word);
            }
        }
        self.doomed_cursor = 0;
        self.doomed_word = 0;
        return null;
    }

    /// Lazily clear a stale mark bitmap for the new epoch, safely against
    /// concurrent markers. Heap epochs advance by 2 (always even); the odd
    /// value `epoch | 1` is the transition lock. Exactly one thread wins the
    /// CAS from the stale value, zeroes the bitmap with plain stores (losers
    /// spin and never touch the bitmap until the release store below), and
    /// publishes the even epoch. Readers (`isMarked`, `deadWord`) treat any
    /// non-current value -- stale or odd -- as "nothing marked", which is
    /// correct in both cases. The single-threaded fast path is one acquire
    /// load, same as before.
    ///
    /// The old non-atomic form set `flag_epoch_transition` but nothing ever
    /// read it: two threads first-marking the same stale block could each
    /// memset, wiping the other's fresh mark bits -- a live object condemned.
    /// Single-threaded marking never exposed it; parallel marking would have
    /// made it routine.
    pub fn ensureMarkEpoch(self: *Block, epoch: u64) void {
        if (@atomicLoad(u64, &self.mark_epoch, .acquire) == epoch) return;
        while (true) {
            const cur = @atomicLoad(u64, &self.mark_epoch, .acquire);
            if (cur == epoch) return;
            if (cur == (epoch | 1)) {
                std.atomic.spinLoopHint();
                continue;
            }
            if (@cmpxchgWeak(u64, &self.mark_epoch, cur, epoch | 1, .acquire, .monotonic) == null) {
                const bits = self.bitmaps();
                @memset(bits.mark, 0);
                @atomicStore(u64, &self.mark_epoch, epoch, .release);
                return;
            }
        }
    }

    /// Is this cell condemned and still awaiting its destruction slice?
    pub inline fn isDoomed(self: *Block, index: u32) bool {
        return (self.bitmaps().remember[index / 64] & (@as(u64, 1) << @intCast(index % 64))) != 0;
    }

    pub fn isMarked(self: *Block, index: u32, epoch: u64) bool {
        if (@atomicLoad(u64, &self.mark_epoch, .acquire) != epoch) return false;
        return testBit(self.bitmaps().mark, index);
    }

    pub fn setMark(self: *Block, index: u32, epoch: u64) void {
        self.ensureMarkEpoch(epoch);
        setBit(self.bitmaps().mark, index);
    }
};

// Block is embedded at the start of every 64 KiB block. Its size determines
// every bitmap and cell offset, so an accidental field addition is a heap
// layout change, not ordinary struct growth.
comptime {
    std.debug.assert(@sizeOf(Block) == 112);
}

const BlockGeometry = struct {
    cell_count: u32,
    bitmap_words: u32,
    alloc_off: u32,
    mark_off: u32,
    remember_off: u32,
    finalizer_off: u32,
    cells_off: u32,
};

fn blockGeometry(cell_size: u32) BlockGeometry {
    const header_size = std.mem.alignForward(usize, @sizeOf(Block), 16);
    const max_cells = (block_bytes - header_size) / cell_size;
    var cell_count: u32 = @intCast(max_cells);
    var bitmap_words: u32 = @intCast((cell_count + 63) / 64);
    const alloc_off: u32 = @intCast(header_size);
    var mark_off: u32 = alloc_off + bitmap_words * 8;
    var remember_off: u32 = mark_off + bitmap_words * 8;
    // TGC S4-a: the fourth bitmap (`needs_finalizer`). Its offset is not
    // cached in `Block` -- deriving it as `remember_bits_off + words * 8`
    // keeps the header at its pinned 112 bytes, and every reader of this
    // bitmap is cold (construction-time set, sweep-time scan).
    var finalizer_off: u32 = remember_off + bitmap_words * 8;
    var cells_off = std.mem.alignForward(u32, finalizer_off + bitmap_words * 8, 64);
    while (cells_off + cell_count * cell_size > block_bytes) {
        cell_count -= 1;
        bitmap_words = @intCast((cell_count + 63) / 64);
        mark_off = alloc_off + bitmap_words * 8;
        remember_off = mark_off + bitmap_words * 8;
        finalizer_off = remember_off + bitmap_words * 8;
        cells_off = std.mem.alignForward(u32, finalizer_off + bitmap_words * 8, 64);
    }
    return .{
        .cell_count = cell_count,
        .bitmap_words = bitmap_words,
        .alloc_off = alloc_off,
        .mark_off = mark_off,
        .remember_off = remember_off,
        .finalizer_off = finalizer_off,
        .cells_off = cells_off,
    };
}

pub const Heap = struct {
    backing: std.mem.Allocator,
    superblocks: std.ArrayListUnmanaged(Superblock) = .empty,
    /// Exact membership for initialized 64 KiB classed blocks.
    ///
    /// Conservative candidates are arbitrary machine words, so masking to a
    /// block base is only arithmetic, not permission to dereference it. JSC's
    /// conservative scanner answers that question with a TinyBloomFilter plus
    /// its MarkedBlockSet; keep the same two-stage shape here. The set is
    /// monotonic because classed blocks stay mapped until `Heap.deinit`, and
    /// capacity is reserved one superblock (32 blocks) at a time.
    classed_blocks: std.AutoHashMapUnmanaged(usize, void) = .empty,
    /// TinyBloomFilter bits: the OR of every key in `classed_blocks`.
    classed_block_filter: usize = 0,
    large: std.AutoHashMapUnmanaged(usize, LargeMap) = .empty,
    medium: std.AutoHashMapUnmanaged(usize, MediumExtent) = .empty,
    /// `addr >> page_shift` -> the extent covering that page. Maintained by
    /// `allocMedium` / `allocLarge` / `free`; read only by
    /// `extentContaining`, which the conservative scanner calls for EVERY
    /// stack word the block geometry disowns.
    extent_pages: std.AutoHashMapUnmanaged(usize, ExtentPage) = .empty,
    /// Extents whose page fan-out could not be recorded because the index
    /// insert failed (OOM). Unlike the address registry's occupant table, a
    /// dropped entry here is not allowed to cost soundness and does not need
    /// a sticky mark-only latch: while this is non-zero `extentContaining`
    /// falls back to the linear table walk, which is the exact same answer at
    /// the old price. It returns to zero when the unindexed extents die.
    extent_pages_unindexed: usize = 0,
    /// Monotone union of every string-extent mapping ever handed out, in the
    /// same `[lo, hi)` convention as `gc_address_registry.Table.bounds_lo/hi`
    /// (`hi` carries the `+ 1` that makes an inclusive one-past-end address
    /// fall inside the window).
    ///
    /// TGC S2-h1: extents no longer take an occupant-table entry, and that
    /// entry was what used to widen the registry's global range gate to cover
    /// them. `Table.rebuildScanFilter` merges this instead. Without it the
    /// two-compare gate at the top of `forEachTraceCandidateAt` would dismiss
    /// every word pointing at a >3760-byte string body before the page index
    /// was ever consulted -- a dropped root, not a missed optimisation.
    ///
    /// Monotone, like the registry's own bounds: a window that stayed wide
    /// after the last extent in a region died only costs a probe that would
    /// have happened anyway.
    extent_bounds_lo: usize = std.math.maxInt(usize),
    extent_bounds_hi: usize = 0,
    /// Removals since `extent_pages` was last compacted. Same disease and
    /// same cure as `gc_address_registry.Table.removes_since_rehash`: std's
    /// open-addressed map tombstones removed slots, and a map under balanced
    /// churn never rehashes on its own, so every probe would degenerate to a
    /// full-capacity scan -- exactly the cost this index exists to remove.
    extent_page_removes: usize = 0,
    /// Medium superblocks bucketed by `Superblock.max_free_run`: index B holds
    /// every medium superblock whose longest free run is exactly B pages.
    /// `allocMedium(pages)` therefore only has to find the first non-empty
    /// bucket at or above `pages` (at most 16 array probes) to be holding a
    /// superblock that is GUARANTEED to serve the request, instead of the
    /// first-fit walk of every superblock that `findMediumRun` performed --
    /// which was quadratic in heap size and cost pdfjs 275x cycles once the
    /// S2 string flip made medium the string body allocator.
    ///
    /// Slot 0 is never populated (a superblock with no usable run is not
    /// linked); it exists so the index arithmetic is the run length itself.
    medium_buckets: [medium_bucket_count]u32 = @splat(bucket_nil),
    /// Head of the tombstoned-slot chain (`Superblock.free_slot_next`).
    free_superblock_slots: u32 = bucket_nil,
    /// Allocation bases of the string extents published since the last
    /// collection retired the young set.
    ///
    /// An extent has no cell, no bitmap and no list link, so this list is the
    /// ONLY enumeration a minor can use for them. Without it a short-lived
    /// >128 B string had to survive to the next major -- which is what drove
    /// pdfjs's live heap from 8 MB to 343 MB after the S2 string flip.
    ///
    /// Entries are appended by `allocMedium`/`allocLarge`, i.e. before
    /// publication, so the walkers tolerate a base that is no longer an
    /// extent (construction failed and freed it) and a base that a later
    /// extent reused. Both are handled by re-probing the tables.
    young_extents: std.ArrayListUnmanaged(usize) = .empty,
    free_blocks: [space.class_count]?*Block = @splat(null),
    /// Completed, populated blocks with enough address-ordered free intervals
    /// to become the next exclusive allocation target for their size class.
    hot_blocks: [space.class_count]?*Block = @splat(null),
    active: [space.class_count]?*Block = @splat(null),
    /// Head of the young-block list (see `noteYoungCell`).
    young_blocks: ?*Block = null,
    /// Head of the doomed-block list: blocks whose snapshot found dead cells,
    /// consumed by the destruction slices.
    doomed_blocks: ?*Block = null,
    stats: Stats = .{},
    mark_epoch: u64 = 0,
    /// Coarse monotonic clock, stamped by the collector at cycle boundaries.
    /// The heap has no business reading a clock on the allocation path, and
    /// the decommit policy needs only second-scale resolution.
    clock_ns: u64 = 0,
    last_decommit_ns: u64 = 0,
    /// Round-robin cursor into `superblocks` for the minor-time hot-block
    /// publication slice (`publishCompletedHotBlocksSlice`, S4-f (2)).
    hot_publish_cursor: usize = 0,
    next_block_incarnation: if (block_generation_enabled) u32 else void =
        if (block_generation_enabled) 1 else {},
    block_generation_exhausted: if (block_generation_enabled) bool else void =
        if (block_generation_enabled) false else {},

    pub fn init(backing: std.mem.Allocator) Heap {
        return .{ .backing = backing };
    }

    pub fn deinit(self: *Heap) void {
        var large_it = self.large.iterator();
        while (large_it.next()) |entry| {
            self.backing.free(entry.value_ptr.bytes);
        }
        self.large.deinit(self.backing);
        self.medium.deinit(self.backing);
        self.extent_pages.deinit(self.backing);
        self.young_extents.deinit(self.backing);
        self.classed_blocks.deinit(self.backing);
        for (self.superblocks.items) |sb| {
            // A tombstone's mapping is already back with the backing allocator
            // and its per-block side tables were never allocated (medium only).
            if (sb.kind == .tombstone) continue;
            if (comptime block_generation_enabled) {
                for (sb.cell_generations) |generations| self.backing.free(generations);
            }
            if (comptime lifecycle_state_enabled) {
                for (sb.cell_lifecycles) |lifecycles| self.backing.free(lifecycles);
            }
            self.backing.free(sb.bytes);
        }
        self.superblocks.deinit(self.backing);
        self.* = .{ .backing = self.backing };
    }

    pub fn beginMajor(self: *Heap) void {
        // A new mark epoch may condemn an object in an otherwise idle hot
        // block. JSC likewise derives can-allocate blocks at endMarking, not
        // across a mark cycle. Keep every partial block private until this
        // cycle's liveness and Pass-B frees are canonical again.
        self.withdrawHotBlocks();
        // Stride 2: heap epochs are always even. The odd value in between is
        // each block's transition lock (`ensureMarkEpoch`).
        self.mark_epoch += 2;
    }

    pub fn alloc(self: *Heap, n: usize) std.mem.Allocator.Error![]u8 {
        if (n == 0) return &.{};
        if (n >= space.large_min_bytes) return self.allocLarge(n);
        if (space.classIndexForPayload(n)) |class_idx| return self.allocSmall(class_idx, n);
        return self.allocMedium(n);
    }

    /// A small-class cell. The allocator stamps its index into the cell prefix so every
    /// `allocCell` result satisfies the contract required by `freeSmallCell`
    /// and the mark accessors need no division; recovering it with
    /// `cellIndexTrusted` afterwards would put an integer division back on
    /// the hottest allocation path in the engine (255 M calls on
    /// earley-boyer, against 60 M marks -- the wrong side of the trade).
    ///
    /// Null means the request is not a small-class cell (medium or large);
    /// the caller must fall back to `alloc`, and must NOT treat the result
    /// as a block cell.
    pub fn allocCell(self: *Heap, n: usize) std.mem.Allocator.Error!?[*]u8 {
        if (n == 0 or n >= space.large_min_bytes) return null;
        const class_idx = space.classIndexForPayload(n) orelse return null;
        const cell_size: u32 = @intCast(space.classes[class_idx]);
        return try self.allocSmallCell(class_idx, cell_size);
    }

    /// Fixed-size twin used by typed Object allocation. The caller's type
    /// proves the payload at comptime, so runtime size classification would be
    /// duplicate work on every cell. Keep its entry on an instruction-cache
    /// line: the active-block pop is the allocation front end for every Object.
    pub noinline fn allocCellFixedPtr(self: *Heap, comptime n: usize) align(64) ?[*]u8 {
        comptime std.debug.assert(canAllocCellSize(n));
        const class_idx = comptime space.classIndexForPayload(n).?;
        const cell_size: u32 = comptime @intCast(space.classes[class_idx]);
        return self.allocSmallCell(class_idx, cell_size) catch return null;
    }

    inline fn allocSmallCell(self: *Heap, class_idx: usize, cell_size: u32) std.mem.Allocator.Error![*]u8 {
        // Both `orelse` arms are the slow path -- the active block is missing
        // or exhausted and a block has to be opened. The injection question is
        // asked before any heap state moves, so a refusal is indistinguishable
        // from the block open having failed, and the fast arm (pop a cell from
        // the active block) stays untouched in test builds too.
        var block = self.active[class_idx] orelse blk: {
            if (injectedCellFailure()) return error.OutOfMemory;
            const opened = try self.openBlock(class_idx, cell_size);
            self.active[class_idx] = opened;
            break :blk opened;
        };
        const index = self.popTrackedCell(block) orelse blk: {
            if (injectedCellFailure()) return error.OutOfMemory;
            self.active[class_idx] = null;
            block = try self.openBlock(class_idx, cell_size);
            self.active[class_idx] = block;
            break :blk self.popTrackedCell(block).?;
        };
        setBitPlain(block.bitmaps().alloc, index);
        if (block.allocated_count == 0) self.noteNonemptyBlock(block);
        block.allocated_count += 1;
        const ptr = block.cellPtr(index);
        std.mem.writeInt(u16, ptr[0..2], @intCast(index), .little);
        return ptr;
    }

    pub fn free(self: *Heap, ptr: [*]u8) void {
        const addr = @intFromPtr(ptr);
        if (self.large.fetchRemove(addr)) |kv| {
            self.unindexExtentPages(addr, kv.value.bytes.len);
            self.stats.live_bytes -= kv.value.bytes.len;
            self.stats.live_count -= 1;
            self.stats.committed_bytes -= kv.value.bytes.len;
            self.stats.large_maps -= 1;
            self.backing.free(kv.value.bytes);
            return;
        }
        if (self.medium.fetchRemove(addr)) |kv| {
            self.unindexExtentPages(addr, @as(usize, kv.value.pages) * page_bytes);
            self.freeMedium(kv.value);
            return;
        }
        const block = Block.fromAddr(addr) orelse return;
        const index = block.cellIndex(addr) orelse return;
        self.freeSmall(block, index, ptr);
    }

    /// TGC S2 extent marking (spec §5.7 "extent"). `base` is the allocation
    /// start (`Heap.alloc` result = body pointer - 8). The block-cell twins
    /// are `Block.setMark` / `Block.isMarked`; extents keep their mark in the
    /// table entry instead, reached by one hash probe on medium then large.
    /// Cold path: only strings over the 128-byte cell ceiling live here.
    ///
    /// The receiver is const like `setHeaderMarked`'s Registry: the entry is
    /// reached through the table's own storage pointer (as `Block.setMark`
    /// reaches the bitmap through the block address), not through `self`.
    /// Plain stores: extents are marked by the STW collector. Parallel
    /// marking (default off) would need these to become atomics AND the
    /// tables to be insert-free while marking runs.
    /// Keys (allocation bases) of every live string extent, medium then
    /// large. Audits use it to enumerate what no list or bitmap holds.
    pub const ExtentKeyIterator = struct {
        medium: std.AutoHashMapUnmanaged(usize, MediumExtent).KeyIterator,
        large: std.AutoHashMapUnmanaged(usize, LargeMap).KeyIterator,

        pub fn next(self: *ExtentKeyIterator) ?usize {
            if (self.medium.next()) |key| return key.*;
            if (self.large.next()) |key| return key.*;
            return null;
        }
    };

    pub fn extentKeys(self: *const Heap) ExtentKeyIterator {
        return .{ .medium = self.medium.keyIterator(), .large = self.large.keyIterator() };
    }

    pub fn extentSetMark(self: *const Heap, base: usize, epoch: u64) void {
        if (self.medium.getPtr(base)) |extent| {
            extent.mark_epoch = epoch;
            return;
        }
        if (self.large.getPtr(base)) |extent| {
            extent.mark_epoch = epoch;
            return;
        }
        unreachable; // not an extent base: the caller misclassified the header
    }

    /// TGC S4-a: record that this extent's death owes a destructor call.
    /// The bit only ever goes on (D-S4-4): a carrier that stops owing is
    /// rare and paying one no-op destructor is cheaper than exact pairing.
    pub fn extentSetNeedsFinalizer(self: *Heap, base: usize) void {
        if (self.medium.getPtr(base)) |extent| {
            extent.needs_finalizer = true;
        } else if (self.large.getPtr(base)) |extent| {
            extent.needs_finalizer = true;
        } else unreachable;
    }

    pub fn extentNeedsFinalizer(self: *const Heap, base: usize) bool {
        if (self.medium.getPtr(base)) |extent| return extent.needs_finalizer;
        if (self.large.getPtr(base)) |extent| return extent.needs_finalizer;
        unreachable;
    }

    pub fn extentIsMarked(self: *const Heap, base: usize, epoch: u64) bool {
        const stamped = if (self.medium.getPtr(base)) |extent|
            extent.mark_epoch
        else if (self.large.getPtr(base)) |extent|
            extent.mark_epoch
        else
            unreachable;
        // No epoch guard: a newborn or minor-cleared extent carries the odd
        // `extent_unmarked_epoch`, which no heap epoch equals, so epoch 0 (the
        // window before the first major, where minors already run) answers
        // like every other epoch.
        return stamped == epoch;
    }

    /// Conservative resolution: the extent base whose allocation contains
    /// `addr` (one-past-end included, like `Occupant.hi`), or null.
    ///
    /// O(1). The conservative scanner calls this for every stack/register
    /// word the block geometry disowns, so the linear walk of both extent
    /// tables it replaces priced each such word at O(live extents) -- and a
    /// string-heavy workload (regexp, pdfjs) holds thousands of extents.
    ///
    /// Two probes at most. The first resolves any address inside the
    /// mapping. The second exists only for the one-past-end of an extent
    /// whose `user_bytes` fills its last page exactly: that address is the
    /// FIRST byte of the following page, which the extent does not own, so
    /// it is found through `addr - 1`. That probe is reachable only for
    /// page-aligned candidates and only after the first one missed.
    pub fn extentContaining(self: *const Heap, addr: usize) ?usize {
        const pair = self.extentsContaining(addr);
        return pair.inside orelse pair.one_past_end;
    }

    /// Both extents a conservative candidate can name.
    ///
    /// `inside` owns `addr` outright. `one_past_end` is the extent whose
    /// inclusive one-past-end bound IS `addr`, which is a DIFFERENT extent
    /// exactly when `addr` is a page boundary that ends one mapping and
    /// starts the next -- interior pointers are legal candidates, so a
    /// single-winner answer would drop the predecessor's only root. The
    /// block and arena arms already visit both sides of such a boundary;
    /// this is the extent arm's twin of that (spec 7.2 (3)).
    pub const ExtentPair = struct {
        inside: ?usize = null,
        one_past_end: ?usize = null,
    };

    pub fn extentsContaining(self: *const Heap, addr: usize) ExtentPair {
        if (self.extent_pages_unindexed != 0) {
            @branchHint(.cold);
            return self.extentsContainingLinear(addr);
        }
        var out: ExtentPair = .{};
        if (self.extent_pages.count() == 0) return out;
        if (self.extent_pages.get(addr >> page_shift)) |entry| {
            if (addr >= entry.base and addr <= entry.end) out.inside = entry.base;
        }
        if (addr & (page_bytes - 1) == 0 and addr != 0) {
            if (self.extent_pages.get((addr - 1) >> page_shift)) |entry| {
                if (addr == entry.end and entry.base != out.inside) out.one_past_end = entry.base;
            }
        }
        return out;
    }

    /// Index-free twin of `extentsContaining`, used while a page fan-out is
    /// missing (`extent_pages_unindexed`) and by the index's own checker.
    fn extentsContainingLinear(self: *const Heap, addr: usize) ExtentPair {
        var out: ExtentPair = .{};
        if (self.medium.count() == 0 and self.large.count() == 0) return out;
        var medium_it = self.medium.iterator();
        while (medium_it.next()) |entry| {
            const base = entry.key_ptr.*;
            if (addr < base or addr > base + entry.value_ptr.user_bytes) continue;
            if (addr == base + entry.value_ptr.user_bytes and addr != base) {
                out.one_past_end = base;
            } else out.inside = base;
        }
        var large_it = self.large.iterator();
        while (large_it.next()) |entry| {
            const base = entry.key_ptr.*;
            if (addr < base or addr > base + entry.value_ptr.user_bytes) continue;
            if (addr == base + entry.value_ptr.user_bytes and addr != base) {
                out.one_past_end = base;
            } else out.inside = base;
        }
        return out;
    }

    /// Fan `[base, base + span_bytes)` out to one `extent_pages` entry per
    /// page. `span_bytes` is the MAPPING (page-rounded); `user_bytes` is the
    /// request, and bounds containment.
    ///
    /// Cannot fail: a partial fan-out would be a page-shaped hole in the
    /// conservative scan, so a failed insert rolls back this extent's pages
    /// and raises `extent_pages_unindexed`, which routes every probe back to
    /// the exact linear walk until the extent dies.
    fn indexExtentPages(self: *Heap, base: usize, span_bytes: usize, user_bytes: usize) void {
        std.debug.assert(base & (page_bytes - 1) == 0);
        std.debug.assert(span_bytes != 0 and span_bytes & (page_bytes - 1) == 0);
        std.debug.assert(user_bytes <= span_bytes);
        // Widened BEFORE the fan-out can fail: the linear fallback
        // (`extentsContainingLinear`) still answers for an unindexed extent,
        // but only if the range gate lets the candidate reach it.
        if (base < self.extent_bounds_lo) self.extent_bounds_lo = base;
        if (base + span_bytes + 1 > self.extent_bounds_hi) self.extent_bounds_hi = base + span_bytes + 1;
        const first = base >> page_shift;
        const last = (base + span_bytes - 1) >> page_shift;
        const value: ExtentPage = .{ .base = base, .end = base + user_bytes };
        var page = first;
        while (page <= last) : (page += 1) {
            if (comptime builtin.is_test) {
                if (extent_page_index_fail_after_for_test) |limit| {
                    if (page - first >= limit) {
                        self.rollbackExtentPages(first, page);
                        self.extent_pages_unindexed += 1;
                        return;
                    }
                }
            }
            const gop = self.extent_pages.getOrPut(self.backing, page) catch {
                self.rollbackExtentPages(first, page);
                self.extent_pages_unindexed += 1;
                return;
            };
            // Page -> extent is a function; a live occupant here means the
            // page bitmap or a large mapping handed the same page out twice.
            std.debug.assert(!gop.found_existing);
            gop.value_ptr.* = value;
        }
    }

    fn rollbackExtentPages(self: *Heap, first: usize, end_exclusive: usize) void {
        var page = first;
        while (page < end_exclusive) : (page += 1) _ = self.extent_pages.remove(page);
    }

    /// Drop an extent's page fan-out. Tolerates an extent that never got one
    /// (its insert failed), which is what returns `extent_pages_unindexed` to
    /// zero and the probe to O(1).
    fn unindexExtentPages(self: *Heap, base: usize, span_bytes: usize) void {
        const first = base >> page_shift;
        const indexed = if (self.extent_pages.get(first)) |entry| entry.base == base else false;
        if (!indexed) {
            std.debug.assert(self.extent_pages_unindexed != 0);
            self.extent_pages_unindexed -= 1;
            return;
        }
        const last = (base + span_bytes - 1) >> page_shift;
        var page = first;
        while (page <= last) : (page += 1) {
            std.debug.assert(self.extent_pages.contains(page));
            _ = self.extent_pages.remove(page);
            self.extent_page_removes += 1;
        }
        self.compactExtentPagesIfTombstoned();
    }

    /// Clear accumulated tombstones once a quarter of capacity has been
    /// removed, so one O(capacity) rehash amortises to a constant per free.
    fn compactExtentPagesIfTombstoned(self: *Heap) void {
        const budget = self.extent_pages.capacity() / 4;
        if (budget == 0 or self.extent_page_removes < budget) return;
        self.extent_page_removes = 0;
        self.extent_pages.rehash(std.hash_map.AutoContext(usize){});
    }

    pub const ExtentIndexError = error{
        ExtentIndexMissingPage,
        ExtentIndexOrphanPage,
        ExtentIndexRangeMismatch,
    };

    /// Prove the page index against the extent tables in both directions: a
    /// missing page drops a live root from the conservative scan, an orphan
    /// page resolves freed memory. Both are use-after-free directions, so
    /// counts alone are not enough. O(live extent pages); audit builds only.
    pub fn verifyExtentPageIndex(self: *const Heap) ExtentIndexError!void {
        var indexed: usize = 0;
        var unindexed: usize = 0;
        var medium_it = self.medium.iterator();
        while (medium_it.next()) |entry| {
            const span = @as(usize, entry.value_ptr.pages) * page_bytes;
            if (try self.verifyOneExtentIndexed(entry.key_ptr.*, span, entry.value_ptr.user_bytes)) {
                indexed += span >> page_shift;
            } else unindexed += 1;
        }
        var large_it = self.large.iterator();
        while (large_it.next()) |entry| {
            const span = entry.value_ptr.bytes.len;
            if (try self.verifyOneExtentIndexed(entry.key_ptr.*, span, entry.value_ptr.user_bytes)) {
                indexed += span >> page_shift;
            } else unindexed += 1;
        }
        if (indexed != self.extent_pages.count()) return error.ExtentIndexOrphanPage;
        if (unindexed != self.extent_pages_unindexed) return error.ExtentIndexOrphanPage;
    }

    fn verifyOneExtentIndexed(
        self: *const Heap,
        base: usize,
        span_bytes: usize,
        user_bytes: usize,
    ) ExtentIndexError!bool {
        const first = base >> page_shift;
        const last = (base + span_bytes - 1) >> page_shift;
        const head = self.extent_pages.get(first) orelse return false;
        if (head.base != base) return error.ExtentIndexRangeMismatch;
        var page = first;
        while (page <= last) : (page += 1) {
            const entry = self.extent_pages.get(page) orelse return error.ExtentIndexMissingPage;
            if (entry.base != base or entry.end != base + user_bytes) {
                return error.ExtentIndexRangeMismatch;
            }
        }
        return true;
    }

    /// Bitmap sweep's twin for extents: every extent whose mark is not
    /// `epoch` is dead. `destroy(ctx, base, user_bytes)` owns the body
    /// teardown and returns the memory through `Heap.free`, so the entry is
    /// removed from under the iterator. That is legal with std's hash map:
    /// `removeByIndex` only tombstones the slot in place (entries never move
    /// on removal; only inserts rehash), and the callback must not allocate
    /// an extent -- it frees one. Returns the number destroyed.
    /// TGC S4-d spec 2.4: the extent twin of the block sweep. `needs_finalizer`
    /// comes off the table row, so a carrier that owes nothing (every storage
    /// and payload extent, and a string body never bound to a dynamic atom)
    /// reaches the callback already knowing its release is pure memory --
    /// no kind dispatch, no atom-table probe.
    pub fn sweepExtents(
        self: *Heap,
        epoch: u64,
        ctx: *anyopaque,
        destroy: *const fn (*anyopaque, usize, usize, bool) void,
    ) usize {
        std.debug.assert(epoch != 0 and epoch & 1 == 0);
        var destroyed: usize = 0;
        var medium_it = self.medium.iterator();
        while (medium_it.next()) |entry| {
            if (entry.value_ptr.mark_epoch == epoch) continue;
            const base = entry.key_ptr.*;
            const user_bytes = entry.value_ptr.user_bytes;
            destroy(ctx, base, user_bytes, entry.value_ptr.needs_finalizer);
            std.debug.assert(!self.medium.contains(base));
            destroyed += 1;
        }
        var large_it = self.large.iterator();
        while (large_it.next()) |entry| {
            if (entry.value_ptr.mark_epoch == epoch) continue;
            const base = entry.key_ptr.*;
            const user_bytes = entry.value_ptr.user_bytes;
            destroy(ctx, base, user_bytes, entry.value_ptr.needs_finalizer);
            std.debug.assert(!self.large.contains(base));
            destroyed += 1;
        }
        return destroyed;
    }

    /// Is `base` still a live extent allocation base? Cheap enough for the
    /// young-extent walkers, which must tolerate stale list entries.
    pub fn containsExtent(self: *const Heap, base: usize) bool {
        return self.medium.contains(base) or self.large.contains(base);
    }

    pub fn extentUserBytes(self: *const Heap, base: usize) ?usize {
        if (self.medium.getPtr(base)) |extent| return extent.user_bytes;
        if (self.large.getPtr(base)) |extent| return extent.user_bytes;
        return null;
    }

    /// Minor twin of `sweepExtents`.
    ///
    /// Only an extent published since the last retirement can be proven dead
    /// by a young trace, and `young_extents` is exactly that population, so
    /// this walks the list instead of both whole tables. Survivors stay in the
    /// list for `retireYoungExtents`, which promotes them.
    ///
    /// Stale entries are expected (see `young_extents`): a base that is no
    /// longer an extent, or one whose header is not published (`young` is the
    /// publication's own stamp), is skipped rather than destroyed.
    pub fn sweepYoungExtents(
        self: *Heap,
        epoch: u64,
        ctx: *anyopaque,
        destroy: *const fn (*anyopaque, usize, usize, bool) void,
    ) usize {
        std.debug.assert(epoch & 1 == 0);
        var destroyed: usize = 0;
        // Indexed, re-reading the list each step: the destroy callback runs
        // arbitrary teardown, and a captured slice would be a dangling read if
        // anything it touched grew the list.
        var index: usize = 0;
        while (index < self.young_extents.items.len) : (index += 1) {
            const base = self.young_extents.items[index];
            const user_bytes = self.extentUserBytes(base) orelse continue;
            const header: *const gc.GCObjectHeader = @ptrFromInt(base + gc.metadata_prefix_size);
            if (!header.metaConst().flags.young) continue;
            if (self.extentIsMarked(base, epoch)) continue;
            destroy(ctx, base, user_bytes, self.extentNeedsFinalizer(base));
            std.debug.assert(!self.containsExtent(base));
            destroyed += 1;
        }
        return destroyed;
    }

    /// Promotion for the extent half of the young set: everything still in the
    /// list after the sweep lived through a collection, so it is old now and
    /// a later write to it must take the remembered-set path.
    pub fn retireYoungExtents(self: *Heap) void {
        for (self.young_extents.items) |base| {
            if (!self.containsExtent(base)) continue;
            const header: *gc.GCObjectHeader = @ptrFromInt(base + gc.metadata_prefix_size);
            header.meta().flags.young = false;
        }
        self.young_extents.clearRetainingCapacity();
    }

    /// Minor-entry mark clearing for extents, the twin of
    /// `clearYoungBlockMarksStw`: the young set enters each minor unmarked, so
    /// a mark left by the PREVIOUS collection cannot keep a dead extent alive.
    pub fn clearYoungExtentMarksStw(self: *Heap) void {
        for (self.young_extents.items) |base| {
            if (self.medium.getPtr(base)) |extent| {
                extent.mark_epoch = extent_unmarked_epoch;
                continue;
            }
            if (self.large.getPtr(base)) |extent| extent.mark_epoch = extent_unmarked_epoch;
        }
    }

    /// Free a cell the caller KNOWS came from `allocCell`, skipping the
    /// large/medium hash probes `free` needs for an arbitrary pointer. The
    /// allocator stamped the already-known cell index into the first two
    /// prefix bytes; read it back instead of re-deriving it with a
    /// non-power-of-two division on every free.
    pub fn freeSmallCell(self: *Heap, ptr: [*]u8) void {
        const addr = @intFromPtr(ptr);
        const block = Block.fromCellTrusted(addr);
        const index: u32 = std.mem.readInt(u16, ptr[0..2], .little);
        std.debug.assert(block.magic == block_magic);
        std.debug.assert(index < block.cell_count);
        std.debug.assert(block.cellBase(index) == addr);
        self.freeSmall(block, index, ptr);
    }

    fn generationFor(self: *Heap, block: *const Block, index: u32) *u32 {
        comptime std.debug.assert(block_generation_enabled);
        const sb = &self.superblocks.items[block.super_index];
        const block_index = (@intFromPtr(block) - @intFromPtr(sb.bytes.ptr)) / block_bytes;
        std.debug.assert(block_index < blocks_per_superblock);
        std.debug.assert(index < sb.cell_generations[block_index].len);
        return &sb.cell_generations[block_index][index];
    }

    fn generationForConst(self: *const Heap, block: *const Block, index: u32) *const u32 {
        comptime std.debug.assert(block_generation_enabled);
        const sb = &self.superblocks.items[block.super_index];
        const block_index = (@intFromPtr(block) - @intFromPtr(sb.bytes.ptr)) / block_bytes;
        std.debug.assert(block_index < blocks_per_superblock);
        std.debug.assert(index < sb.cell_generations[block_index].len);
        return &sb.cell_generations[block_index][index];
    }

    fn lifecycleFor(self: *Heap, block: *const Block, index: u32) *CellLifecycle {
        comptime std.debug.assert(lifecycle_state_enabled);
        const sb = &self.superblocks.items[block.super_index];
        const block_index = (@intFromPtr(block) - @intFromPtr(sb.bytes.ptr)) / block_bytes;
        std.debug.assert(block_index < blocks_per_superblock);
        std.debug.assert(index < sb.cell_lifecycles[block_index].len);
        return &sb.cell_lifecycles[block_index][index];
    }

    fn lifecycleForConst(self: *const Heap, block: *const Block, index: u32) *const CellLifecycle {
        comptime std.debug.assert(lifecycle_state_enabled);
        const sb = &self.superblocks.items[block.super_index];
        const block_index = (@intFromPtr(block) - @intFromPtr(sb.bytes.ptr)) / block_bytes;
        std.debug.assert(block_index < blocks_per_superblock);
        std.debug.assert(index < sb.cell_lifecycles[block_index].len);
        return &sb.cell_lifecycles[block_index][index];
    }

    fn blockIncarnation(self: *const Heap, block: *const Block) u32 {
        comptime std.debug.assert(block_generation_enabled);
        const sb = &self.superblocks.items[block.super_index];
        const block_index = (@intFromPtr(block) - @intFromPtr(sb.bytes.ptr)) / block_bytes;
        return sb.block_incarnations[block_index];
    }

    fn reserveCellGeneration(self: *Heap, block: *Block, index: u32) std.mem.Allocator.Error!u64 {
        comptime std.debug.assert(block_generation_enabled);
        const sequence = self.generationFor(block, index);
        if (sequence.* == std.math.maxInt(u32)) return error.OutOfMemory;
        sequence.* += 1;
        return (@as(u64, self.blockIncarnation(block)) << 32) | sequence.*;
    }

    inline fn popTrackedCell(self: *Heap, block: *Block) ?u32 {
        if (comptime !block_tracking_enabled) return popCell(block);
        while (popCell(block)) |index| {
            if (comptime block_generation_enabled) {
                _ = self.reserveCellGeneration(block, index) catch continue;
            }
            if (comptime lifecycle_state_enabled) {
                const lifecycle = self.lifecycleFor(block, index);
                lifecycle.state = .constructing;
                lifecycle.accounted_bytes = 0;
            }
            return index;
        }
        return null;
    }

    pub fn generationHandle(self: *const Heap, object_base: usize, prefix_bytes: usize) ?carrier.AllocationHandle {
        comptime std.debug.assert(block_generation_enabled);
        if (object_base < prefix_bytes) return null;
        const cell_base = object_base - prefix_bytes;
        const block = self.blockOf(@ptrFromInt(cell_base)) orelse return null;
        const index = block.cellIndex(cell_base) orelse return null;
        if (!block.cellAllocated(index)) return null;
        return .{
            .base = object_base,
            .generation = (@as(u64, self.blockIncarnation(block)) << 32) |
                self.generationForConst(block, index).*,
        };
    }

    pub fn containsAllocatedCell(self: *const Heap, object_base: usize, prefix_bytes: usize) bool {
        if (object_base < prefix_bytes) return false;
        const cell_base = object_base - prefix_bytes;
        const block = self.blockOf(@ptrFromInt(cell_base)) orelse return false;
        const index = block.cellIndex(cell_base) orelse return false;
        return block.cellAllocated(index);
    }

    pub const ResolvedCell = struct {
        block: *Block,
        index: u32,
        state: carrier.LifecycleState,
        generation: u64,
    };

    pub fn resolveExactHandle(
        self: *const Heap,
        handle: carrier.AllocationHandle,
        prefix_bytes: usize,
        allowed_states: carrier.StateMask,
        skip_generation_check: bool,
    ) carrier.ResolveError!ResolvedCell {
        comptime std.debug.assert(block_generation_enabled and lifecycle_state_enabled);
        if (handle.base < prefix_bytes) return error.NotFound;
        const cell_base = handle.base - prefix_bytes;
        const block = self.blockOf(@ptrFromInt(cell_base)) orelse return error.NotFound;
        const index = block.cellIndex(cell_base) orelse return error.NotExactStart;
        if (!block.cellAllocated(index)) return error.NotFound;
        const generation = (@as(u64, self.blockIncarnation(block)) << 32) |
            self.generationForConst(block, index).*;
        if (!skip_generation_check and generation != handle.generation) return error.GenerationMismatch;
        const lifecycle = self.lifecycleForConst(block, index);
        if (!allowed_states.contains(lifecycle.state)) return error.StateMismatch;
        return .{ .block = block, .index = index, .state = lifecycle.state, .generation = generation };
    }

    pub fn transitionCell(self: *Heap, object_base: usize, prefix_bytes: usize, state: carrier.LifecycleState) carrier.ResolveError!void {
        comptime std.debug.assert(lifecycle_state_enabled);
        if (object_base < prefix_bytes) return error.NotFound;
        const cell_base = object_base - prefix_bytes;
        const block = self.blockOf(@ptrFromInt(cell_base)) orelse return error.NotFound;
        const index = block.cellIndex(cell_base) orelse return error.NotExactStart;
        if (!block.cellAllocated(index)) return error.NotFound;
        self.lifecycleFor(block, index).state = state;
    }

    pub fn publishCell(self: *Heap, object_base: usize, prefix_bytes: usize, accounted_bytes: usize) carrier.ResolveError!void {
        comptime std.debug.assert(lifecycle_state_enabled);
        try self.transitionCell(object_base, prefix_bytes, .published);
        const cell_base = object_base - prefix_bytes;
        const block = self.blockOf(@ptrFromInt(cell_base)) orelse return error.NotFound;
        const index = block.cellIndex(cell_base) orelse return error.NotExactStart;
        self.lifecycleFor(block, index).accounted_bytes = accounted_bytes;
    }

    pub fn rawBytesForCell(self: *const Heap, object_base: usize, prefix_bytes: usize) ?usize {
        if (object_base < prefix_bytes) return null;
        const block = self.blockOf(@ptrFromInt(object_base - prefix_bytes)) orelse return null;
        if (block.cellIndex(object_base - prefix_bytes) == null) return null;
        return block.cell_size;
    }

    pub fn setReuseSequenceForTest(self: *Heap, cell: [*]u8, sequence: u32) void {
        comptime std.debug.assert(block_generation_enabled);
        const block = Block.fromCellTrusted(@intFromPtr(cell));
        const index = block.cellIndex(@intFromPtr(cell)).?;
        self.generationFor(block, index).* = sequence;
    }

    pub fn forEachOwnedIdentity(
        self: *const Heap,
        prefix_bytes: usize,
        context: *anyopaque,
        visit: *const fn (*anyopaque, carrier.AllocationHandle, carrier.LifecycleState) void,
    ) void {
        comptime std.debug.assert(block_generation_enabled and lifecycle_state_enabled);
        for (self.superblocks.items) |sb| {
            if (sb.kind != .classed) continue;
            var block_index: usize = 0;
            while (block_index < sb.used_blocks) : (block_index += 1) {
                const block: *const Block = @ptrFromInt(@intFromPtr(sb.bytes.ptr) + block_index * block_bytes);
                var index: u32 = 0;
                while (index < block.cell_count) : (index += 1) {
                    const lifecycle = &sb.cell_lifecycles[block_index][index];
                    if (lifecycle.state == .free) continue;
                    visit(context, .{
                        .base = block.cellBase(index) + prefix_bytes,
                        .generation = (@as(u64, sb.block_incarnations[block_index]) << 32) |
                            sb.cell_generations[block_index][index],
                    }, lifecycle.state);
                }
            }
        }
    }

    pub fn verifyGenerationAuthority(self: *const Heap) VerifyError!void {
        comptime std.debug.assert(block_generation_enabled);
        for (self.superblocks.items) |sb| {
            if (sb.kind != .classed) continue;
            var block_index: usize = 0;
            while (block_index < sb.used_blocks) : (block_index += 1) {
                const block: *const Block = @ptrFromInt(@intFromPtr(sb.bytes.ptr) + block_index * block_bytes);
                if (sb.block_incarnations[block_index] == 0 or
                    sb.cell_generations[block_index].len != block.cell_count)
                {
                    return error.CarrierIdentityMismatch;
                }
                for (sb.cell_generations[block_index], 0..) |generation, index| {
                    const allocated = @constCast(block).cellAllocated(@intCast(index));
                    if (allocated and generation == 0) return error.CarrierIdentityMismatch;
                }
            }
        }
    }

    pub fn verifyLifecycleAuthority(self: *const Heap) VerifyError!void {
        comptime std.debug.assert(lifecycle_state_enabled);
        for (self.superblocks.items) |sb| {
            if (sb.kind != .classed) continue;
            var block_index: usize = 0;
            while (block_index < sb.used_blocks) : (block_index += 1) {
                const block: *const Block = @ptrFromInt(@intFromPtr(sb.bytes.ptr) + block_index * block_bytes);
                if (sb.cell_lifecycles[block_index].len != block.cell_count) return error.CarrierIdentityMismatch;
                for (sb.cell_lifecycles[block_index], 0..) |lifecycle, index| {
                    const allocated = @constCast(block).cellAllocated(@intCast(index));
                    if (allocated != (lifecycle.state != .free)) return error.CarrierIdentityMismatch;
                    if (!allocated and lifecycle.accounted_bytes != 0) return error.CarrierIdentityMismatch;
                }
            }
        }
    }

    /// TGC S4-d spec 2.4: reclaim every condemned cell in `block` that owes no
    /// destructor. The caller must have drained the finalizer subset
    /// (`Block.takeDoomedFinalizerCell`) and must have UNLINKED the block from
    /// the doomed list first -- a block that goes empty here joins the
    /// free-block list, and a free-listed block with a live `doomed_link` is
    /// both an audit failure and a severed chain the moment `resetBlock` runs.
    ///
    /// Two cases keep the ordinary per-cell `freeSmall` path, for the reasons
    /// `canSettleDoomedCellInPassA` names: the allocator-current block must
    /// keep a maintained free-list/bump representation because the mutator
    /// allocates out of it between destruction slices, and a release that
    /// empties a block has to run the empty-block transition (list membership,
    /// aged decommit). Both are bounded -- one block per size class, one block
    /// per emptying -- so the bulk path still covers essentially every corpse.
    pub fn reclaimDoomedCells(self: *Heap, block: *Block) u32 {
        std.debug.assert(block.doomed_link == 0);
        var doomed_total: u32 = 0;
        for (block.bitmaps().remember) |word| doomed_total += @popCount(word);
        if (doomed_total == 0) return 0;
        if (self.active[block.size_class] == block or block.allocated_count == doomed_total) {
            var freed: u32 = 0;
            while (block.takeDoomedCell(0)) |index| {
                self.freeSmall(block, index, block.cellPtr(index));
                freed += 1;
            }
            std.debug.assert(freed == doomed_total);
            return freed;
        }
        if (comptime lifecycle_state_enabled) {
            var index: u32 = 0;
            while (index < block.cell_count) : (index += 1) {
                if (!block.isDoomed(index)) continue;
                const lifecycle = self.lifecycleFor(block, index);
                lifecycle.state = .free;
                lifecycle.accounted_bytes = 0;
            }
        }
        const freed = block.reclaimDoomedIntoBitmap();
        block.flags &= ~Block.flag_hot_rejected;
        std.debug.assert(freed == doomed_total);
        self.stats.bitmap_reclaimed_cells +|= freed;
        return freed;
    }

    /// Walk every classed block and bucket it by size class and occupancy.
    /// Diagnostic only: `--gc-block-census` calls it once, at exit, so it is
    /// off every collector path and costs the run nothing.
    pub fn censusBlocks(self: *const Heap) BlockCensus {
        var out: BlockCensus = .{};
        for (space.classes, 0..) |cell_bytes, i| out.rows[i].cell_bytes = @intCast(cell_bytes);
        for (self.superblocks.items) |*sb| {
            if (sb.kind != .classed) {
                out.other_superblocks += 1;
                continue;
            }
            out.classed_superblocks += 1;
            var i: usize = 0;
            while (i < sb.used_blocks) : (i += 1) {
                const block: *const Block = @ptrFromInt(@intFromPtr(sb.bytes.ptr) + i * block_bytes);
                if (block.magic != block_magic or block.size_class >= space.class_count) {
                    out.uninitialized_blocks += 1;
                    continue;
                }
                const row = &out.rows[block.size_class];
                row.blocks += 1;
                row.cells += block.cell_count;
                row.allocated += block.allocated_count;
                if (block.flags & Block.flag_young != 0) row.young += 1;
                if (block.flags & Block.flag_decommitted != 0) row.decommitted += 1;
                if (block.allocated_count == 0) {
                    row.empty += 1;
                } else {
                    const pct = @as(u64, block.allocated_count) * 100 / @max(@as(u64, block.cell_count), 1);
                    if (pct < 10) row.lt10 += 1 else if (pct < 50) row.lt50 += 1 else row.ge50 += 1;
                }
            }
        }
        for (self.active, 0..) |maybe_block, i| {
            if (maybe_block != null) out.rows[i].active += 1;
        }
        for (self.hot_blocks, 0..) |head, i| {
            var cursor = head;
            while (cursor) |block| {
                out.rows[i].hot_listed += 1;
                cursor = if (block.next_free == 0) null else @as(*Block, @ptrFromInt(block.next_free));
            }
        }
        for (self.free_blocks, 0..) |head, i| {
            var cursor = head;
            while (cursor) |block| {
                out.rows[i].free_listed += 1;
                cursor = if (block.next_free == 0) null else @as(*Block, @ptrFromInt(block.next_free));
            }
        }
        return out;
    }

    /// Per-block form of `verify`'s `AllocCountMismatch`, run when Pass A
    /// finishes a doomed block so a settlement bug names the block that caused
    /// it instead of surfacing at the next whole-heap audit.
    pub fn verifyBlockAllocCount(block: *Block) VerifyError!void {
        var set: u32 = 0;
        for (block.bitmaps().alloc) |word| set += @popCount(word);
        if (set != block.allocated_count) return error.AllocCountMismatch;
    }

    pub fn owns(self: *const Heap, ptr: [*]u8) bool {
        const addr = @intFromPtr(ptr);
        if (self.large.contains(addr)) return true;
        if (self.medium.contains(addr)) return true;
        return self.blockOf(ptr) != null;
    }

    /// First time this cycle that a young object lands in `block`: put the
    /// block on the young list. One flag test on the publication path.
    pub inline fn noteYoungCell(self: *Heap, block: *Block) void {
        if (block.isYoungListed()) return;
        block.flags |= Block.flag_young;
        block.young_link = if (self.young_blocks) |head| @intFromPtr(head) else 1;
        self.young_blocks = block;
    }

    /// Retire the young-block list: clear flags, break links.
    pub fn clearYoungBlocks(self: *Heap) usize {
        var cursor = self.young_blocks;
        var cleared: usize = 0;
        while (cursor) |block| {
            const link = block.young_link;
            block.flags &= ~Block.flag_young;
            block.young_link = 0;
            cleared += 1;
            cursor = if (link <= 1) null else @ptrFromInt(link);
        }
        self.young_blocks = null;
        return cleared;
    }

    /// Batch the block-cell half of minor-entry mark clearing. The young-block
    /// list is the exact structural index for blocks that may contain young
    /// cells; non-block carriers remain on Registry's young suffix.
    pub fn clearYoungBlockMarksStw(self: *Heap) void {
        var cursor = self.young_blocks;
        while (cursor) |block| {
            block.clearYoungMarksStw(self.mark_epoch);
            const link = block.young_link;
            cursor = if (link <= 1) null else @ptrFromInt(link);
        }
    }

    /// Maintain the classed-superblock nonempty index only on population
    /// transitions. Allocation and freeing within a populated block pay no
    /// shared counter or list-link traffic.
    fn noteNonemptyBlock(self: *Heap, block: *Block) void {
        const sb = &self.superblocks.items[block.super_index];
        std.debug.assert(sb.kind == .classed);
        const index: u32 = @intCast((@intFromPtr(block) - @intFromPtr(sb.bytes.ptr)) / block_bytes);
        std.debug.assert(index < sb.used_blocks);
        setPage(&sb.page_bits, index);
    }

    fn noteEmptyBlock(self: *Heap, block: *Block) void {
        const sb = &self.superblocks.items[block.super_index];
        std.debug.assert(sb.kind == .classed);
        const index: u32 = @intCast((@intFromPtr(block) - @intFromPtr(sb.bytes.ptr)) / block_bytes);
        std.debug.assert(index < sb.used_blocks);
        clearPage(&sb.page_bits, index);
    }

    fn hasHotReuseCapacity(block: *const Block) bool {
        const free_cells = block.cell_count - block.allocated_count;
        return free_cells * 100 >= block.cell_count * hot_reuse_min_free_percent;
    }

    /// Withdraw the previous cycle's can-allocate set before a new mark epoch.
    /// Blocks with no condemned cells are republished by final remark, while
    /// the rest wait for the global parked-free Pass B to finish.
    fn withdrawHotBlocks(self: *Heap) void {
        for (&self.hot_blocks) |*head| {
            var cursor = head.*;
            head.* = null;
            while (cursor) |block| {
                std.debug.assert(block.flags & Block.flag_hot_list != 0);
                const link = block.next_free;
                block.flags &= ~Block.flag_hot_list;
                // Outside list membership this field is the returned-cell
                // head for interval allocation, whose empty value is free_nil.
                block.next_free = free_nil;
                // A hot-unprepared block deliberately had no trustworthy
                // allocator representation: its `next_free` was a block-list
                // link and publication may have invalidated an older interval
                // table. Withdrawing it at the next major must leave a valid
                // census-owned cold representation, not an unowned bitmap.
                _ = rebuildFreeIntervals(block);
                cursor = if (link == 0) null else @ptrFromInt(link);
            }
        }
    }

    fn findCellState(block: *Block, start: u32, want_allocated: bool) u32 {
        if (start >= block.cell_count) return block.cell_count;
        const alloc_words = block.bitmaps().alloc;
        var word_index: usize = start / 64;
        var first_bit: u6 = @intCast(start % 64);
        while (word_index < alloc_words.len) : (word_index += 1) {
            var word = if (want_allocated) alloc_words[word_index] else ~alloc_words[word_index];
            const all_bits: u64 = std.math.maxInt(u64);
            word &= all_bits << first_bit;
            if (word_index + 1 == alloc_words.len and block.cell_count % 64 != 0) {
                const tail_bits: u6 = @intCast(block.cell_count % 64);
                word &= (@as(u64, 1) << tail_bits) - 1;
            }
            if (word != 0) {
                const index = word_index * 64 + @ctz(word);
                return @intCast(@min(index, block.cell_count));
            }
            first_bit = 0;
        }
        return block.cell_count;
    }

    fn writeIntervalNode(block: *Block, start: u32, end: u32, next: u32) void {
        std.debug.assert(start < end and end <= block.cell_count);
        std.debug.assert(next == free_nil or next < block.cell_count);
        const cell = block.cellPtr(start);
        @as(*u32, @ptrCast(@alignCast(cell))).* = free_poison | (next & free_link_mask);
        @as(*u32, @ptrCast(@alignCast(cell + 4))).* = end;
    }

    /// Rebuild all bitmap holes as maximal, address-ordered intervals. The
    /// block is private while this runs: it is neither active nor on a pool,
    /// and its doomed transaction has completed. Only interval heads receive
    /// links; allocation bumps through the cells between them.
    fn rebuildFreeIntervals(block: *Block) u32 {
        std.debug.assert(block.allocated_count != 0);
        std.debug.assert(!block.hasPendingDoomed());
        std.debug.assert(hasHotReuseCapacity(block));

        block.flags |= Block.flag_interval_allocator;
        // The reconstruction below reads exactly the alloc bitmap, so it is
        // also what discharges any stage-3 settlement debt: from here on
        // `bump`/`interval_end`/`free_list` enumerate every hole again.
        block.flags &= ~(Block.flag_hot_list | Block.flag_bitmap_canonical);
        block.bump = 0;
        block.interval_end = 0;
        block.free_list = free_nil;
        block.next_free = free_nil;

        var cursor: u32 = 0;
        var linked_start: ?u32 = null;
        var linked_end: u32 = 0;
        var found_first = false;
        var max_interval: u32 = 0;
        while (cursor < block.cell_count) {
            const start = findCellState(block, cursor, false);
            if (start == block.cell_count) break;
            const end = findCellState(block, start, true);
            if (!found_first) {
                block.bump = start;
                block.interval_end = end;
                found_first = true;
            } else {
                if (linked_start) |previous| {
                    writeIntervalNode(block, previous, linked_end, start);
                } else {
                    block.free_list = start;
                }
                linked_start = start;
                linked_end = end;
            }
            max_interval = @max(max_interval, end - start);
            cursor = end;
        }
        std.debug.assert(found_first);
        if (linked_start) |last| writeIntervalNode(block, last, linked_end, free_nil);
        return max_interval;
    }

    fn publishHotBlock(self: *Heap, block: *Block) void {
        if (block.allocated_count == 0) {
            self.stats.hot_publish_rejected_empty +|= 1;
            return;
        }
        if (!hasHotReuseCapacity(block)) {
            self.stats.hot_publish_rejected_capacity +|= 1;
            return;
        }
        if (self.active[block.size_class] == block) {
            self.stats.hot_publish_rejected_active +|= 1;
            return;
        }
        if (block.hasPendingDoomed()) {
            self.stats.hot_publish_rejected_doomed +|= 1;
            return;
        }
        if (block.flags & Block.flag_young != 0) {
            self.stats.hot_publish_rejected_young +|= 1;
            return;
        }
        if (block.flags & Block.flag_hot_list != 0) {
            self.stats.hot_publish_rejected_listed +|= 1;
            return;
        }
        if (block.flags & Block.flag_decommitted != 0) {
            self.stats.hot_publish_rejected_decommitted +|= 1;
            return;
        }
        if (block.flags & Block.flag_hot_rejected != 0) {
            self.stats.hot_publish_rejected_cached_k +|= 1;
            return;
        }
        // Rebuild even when this was an interval block before condemnation:
        // parked Pass-B frees accumulated in its returned-cell chain while it
        // was private. The alloc bitmap is now the single canonical source.
        // Hot publication is intentionally unprepared. Rebuild is deferred
        // until this block is actually selected by openBlock.
        block.flags &= ~Block.flag_interval_allocator;
        block.next_free = if (self.hot_blocks[block.size_class]) |head| @intFromPtr(head) else 0;
        const class_idx = block.size_class;
        block.flags |= Block.flag_hot_list;
        self.hot_blocks[class_idx] = block;
        self.stats.hot_blocks_published += 1;
    }

    /// Publish partial blocks once the whole doomed transaction has closed.
    ///
    /// TGC S4-e: this used to also wait on the global parked-free Pass B,
    /// because a corpse's alloc bit stayed set until its struct was handed
    /// back. Destruction is one pass now -- a destructor releases its own cell
    /// -- so an empty doomed list is the whole condition.
    pub fn publishCompletedHotBlocks(self: *Heap) void {
        if (comptime builtin.is_test) publish_completed_hot_blocks_calls_for_test += 1;
        std.debug.assert(self.doomed_blocks == null);
        for (self.superblocks.items) |*sb| self.publishSuperblockHotBlocks(sb);
    }

    /// TGC S4-f (2): the same publication, run at the end of a MINOR over a
    /// bounded round-robin slice of the superblock array.
    ///
    /// A partially-emptied block re-enters allocation only through the hot
    /// pool, and until now the pool was only refilled at the end of a major's
    /// two-pass teardown. regexp.fixed takes 3 majors and 640 minors: the
    /// holes 640 minors punched in its blocks were invisible to the allocator
    /// for the whole run, so every block that filled up was retired forever
    /// and `committed` became "peak count of blocks ever opened". Its census
    /// read 2,681 blocks of which 2,539 were under 10% occupied -- 166 MB of
    /// the 182 MB committed, holding 42k live cells (1.2% of capacity).
    ///
    /// Bounded rather than whole-heap because the walk is O(populated blocks)
    /// and a minor is meant to be short: earley-boyer takes 9k-13k minors over
    /// a heap of ~3.5k blocks, and the unbounded form would have made this a
    /// 50M-block-visit tax. The cursor makes coverage a function of minor
    /// COUNT instead, which is exactly the workload property that made the
    /// holes accumulate.
    pub fn publishCompletedHotBlocksSlice(
        self: *Heap,
        parked_frees: usize,
        superblock_budget: usize,
    ) void {
        if (parked_frees != 0) return;
        std.debug.assert(self.doomed_blocks == null);
        const total = self.superblocks.items.len;
        if (total == 0) return;
        var cursor = if (self.hot_publish_cursor >= total) 0 else self.hot_publish_cursor;
        var scanned: usize = 0;
        while (scanned < superblock_budget and scanned < total) : (scanned += 1) {
            self.publishSuperblockHotBlocks(&self.superblocks.items[cursor]);
            cursor += 1;
            if (cursor == total) cursor = 0;
        }
        self.hot_publish_cursor = cursor;
    }

    fn publishSuperblockHotBlocks(self: *Heap, sb: *Superblock) void {
        if (sb.kind != .classed) return;
        var nonempty = sb.page_bits[0];
        while (nonempty != 0) {
            const i: usize = @ctz(nonempty);
            nonempty &= nonempty - 1;
            const block: *Block = @ptrFromInt(@intFromPtr(sb.bytes.ptr) + i * block_bytes);
            if (block.flags & Block.flag_hot_list != 0) continue;
            self.publishHotBlock(block);
        }
    }

    const DoomedSnapshot = struct {
        count: usize = 0,
        bytes: usize = 0,
        /// TGC S4-d spec 2.4: the accounted bytes of the corpses the sweep
        /// reclaims from the BITMAP (`doomed & ~needs_finalizer`), i.e. the
        /// ones no per-cell debit will ever run for. Already prefix-excluded,
        /// so it is the exact number to hand `debitBlockBytes`.
        bitmap_bytes: usize = 0,
    };
    const DoomedOrigin = enum { minor, major };

    /// Finish the heap-owned half of condemning one block. Object corpses
    /// never borrow a body word for list linkage: the doomed bitmap and this
    /// block-level list are the complete side authority until destruction.
    fn recordDoomedBlock(
        self: *Heap,
        block: *Block,
        counts: DoomedCounts,
        result: *DoomedSnapshot,
        comptime origin: DoomedOrigin,
    ) void {
        const dead = counts.dead;
        if (dead == 0) {
            // Hot reuse is a major-lifecycle decision. A minor snapshot is
            // only the side authority for Object condemnation; it must not
            // change where the allocator obtains its next block.
            if (origin == .major) self.publishHotBlock(block);
            return;
        }
        // A block selected for interval reuse is unavailable until its final
        // doomed destructor returns. Small-death active blocks keep the
        // existing allocation policy; non-active blocks are private already.
        if (origin == .major and
            self.active[block.size_class] == block and
            dead * 100 >= block.cell_count * hot_reuse_min_free_percent)
        {
            self.active[block.size_class] = null;
        }
        result.count += dead;
        result.bytes += @as(usize, dead) * block.cell_size;
        // TGC S4-d spec 2.4: the block-level debit covers exactly the corpses
        // the bitmap reclaim takes. A cell that owes a destructor keeps the
        // per-cell release it always had (TGC S4-e: that release now happens
        // inside the destructor itself), so its bytes must NOT be debited
        // here.
        result.bitmap_bytes += @as(usize, dead - counts.finalizing) *
            (block.cell_size - gc.metadata_prefix_size);
        if (block.doomed_link == 0) {
            block.doomed_link = if (self.doomed_blocks) |head| @intFromPtr(head) else 1;
            self.doomed_blocks = block;
        }
    }

    /// Condemn every dead cell in the heap by bitmap snapshot. Blocks that
    /// hold any go on the doomed list. Returns total dead cells and bytes.
    pub fn snapshotAllDoomed(self: *Heap, epoch: u64) DoomedSnapshot {
        var result = DoomedSnapshot{};
        for (self.superblocks.items) |*sb| {
            if (sb.kind != .classed) continue;
            // Classed `page_bits` is the footprint-neutral nonempty index.
            // Empty committed blocks never reach `snapshotDoomed`; enumerate
            // one bit per populated block instead of linearly probing every
            // block ever opened in the superblock.
            var nonempty = sb.page_bits[0];
            while (nonempty != 0) {
                const i: usize = @ctz(nonempty);
                nonempty &= nonempty - 1;
                const block: *Block = @ptrFromInt(@intFromPtr(sb.bytes.ptr) + i * block_bytes);
                std.debug.assert(block.magic == block_magic);
                std.debug.assert(block.allocated_count != 0);
                self.recordDoomedBlock(block, block.snapshotDoomed(epoch), &result, .major);
            }
        }
        return result;
    }

    /// Minor twin of `snapshotAllDoomed`. Sticky old marks remain set, while
    /// minor entry cleared only published young marks, so `alloc & ~mark` over
    /// the young-block index names exactly the dead nursery cells. The link is
    /// captured before snapshot because condemnation may reuse `doomed_link`
    /// but never mutates the independent young chain.
    pub fn snapshotYoungDoomed(self: *Heap, epoch: u64) DoomedSnapshot {
        var result = DoomedSnapshot{};
        var cursor = self.young_blocks;
        while (cursor) |block| {
            const young_link = block.young_link;
            self.recordDoomedBlock(block, block.snapshotDoomed(epoch), &result, .minor);
            cursor = if (young_link <= 1) null else @ptrFromInt(young_link);
        }
        return result;
    }

    /// How long a block must sit unused before its pages go back, and how
    /// often the free lists are walked looking for such blocks. Both are
    /// wall-clock, deliberately: an idle-DURATION rule is what libpas uses
    /// (pas_scavenger_max_epoch_delta, 300-600s off Apple platforms, on a
    /// 100-125ms period) and the reason is exactly what a collection-count
    /// rule got wrong here. "Free across one collection" sounds conservative
    /// until the workload's collections are 0.4ms apart: earley-boyer's 7745
    /// cycles turned it into 4.95 GB of madvise and 4.94 GB of re-faulting
    /// in a 30-second run. Duration is invariant to collection frequency,
    /// which is the property the policy actually needs.
    pub const decommit_min_idle_ns: u64 = 1_000_000_000;
    pub const decommit_period_ns: u64 = 100_000_000;
    /// `malloc_trim` is process-wide, so require a contraction much larger
    /// than any of the pdfjs/regexp/deltablue block heaps before touching the
    /// libc arena. This is a shrink signal, not a steady-state density knob.
    pub const process_trim_min_decommitted_bytes: usize = 128 * 1024 * 1024;

    fn decommitCellPages(block: *Block) bool {
        if (comptime builtin.os.tag == .windows or decommit_bytes == 0) return false;
        const start = @intFromPtr(block) + (block_bytes - decommit_bytes);
        const cells: [*]align(std.heap.page_size_min) u8 = @ptrFromInt(start);
        if (comptime builtin.os.tag != .windows) {
            std.posix.madvise(cells, decommit_bytes, std.posix.MADV.DONTNEED) catch return false;
            return true;
        }
        return false;
    }

    /// Hand the cell pages of long-idle fully-free blocks back to the OS.
    /// The header page (magic, links, bitmaps -- all under 2KB) stays
    /// mapped, so the free list keeps working, conservative candidates still
    /// resolve through an intact magic + all-zero alloc bitmap, and
    /// `openBlock` rebuilds the cells from `bump = 0` exactly as for a fresh
    /// block. Called off every pause path, at destroy completion.
    pub fn releaseFreeBlockPages(self: *Heap, now_ns: u64) usize {
        self.clock_ns = now_ns;
        if (now_ns -| self.last_decommit_ns < decommit_period_ns) return 0;
        self.last_decommit_ns = now_ns;
        self.stats.decommit_checks += 1;
        var released: usize = 0;
        for (self.free_blocks) |head| {
            var cursor = head;
            while (cursor) |block| {
                cursor = if (block.next_free == 0) null else @ptrFromInt(block.next_free);
                if (block.flags & Block.flag_decommitted != 0) continue;
                if (now_ns -| block.free_time_ns < decommit_min_idle_ns) continue;
                if (decommit_bytes == 0) continue;
                if (!decommitCellPages(block)) continue;
                // The free-chain LINKS live in the discarded cell pages, not
                // in the retained header page. They now read as zero and must
                // no longer be described by the old head/bump pair. Reuse
                // already calls resetBlock and rebuilds from bump zero; make
                // the retained header tell that same truth immediately so an
                // audit never follows page-discarded links.
                block.bump = 0;
                block.free_list = free_nil;
                block.flags |= Block.flag_decommitted;
                released += decommit_bytes;
            }
        }
        self.stats.decommitted_bytes += released;
        self.stats.committed_bytes -= released;
        self.stats.decommit_max_batch_bytes = @max(self.stats.decommit_max_batch_bytes, released);
        // TGC S2-f (2): same boundary and the same throttle, but a whole
        // different space. `releaseEmptyMediumSuperblocks` accounts for its
        // own `committed_bytes`; it is added to `released` only so the caller
        // and the process-trim signal see the full contraction.
        const medium_released = self.releaseEmptyMediumSuperblocks(now_ns);
        self.trimProcessHeapAfterLargeShrink(released + medium_released);
        return released + medium_released;
    }

    /// Return free glibc arena pages only after the block heap independently
    /// proves a large, durable contraction. `malloc_trim` leaves allocation
    /// addresses and the block free lists intact; it only makes free libc
    /// pages non-resident. Small heaps cannot cross the threshold, avoiding a
    /// syscall/refault loop on pdfjs, regexp, and deltablue.
    fn trimProcessHeapAfterLargeShrink(self: *Heap, released: usize) void {
        if (comptime !builtin.target.isGnuLibC()) return;
        const current = self.stats.currentDecommittedBytes();
        // One trim per contraction episode: later batches while the heap stays
        // beyond the threshold add no new evidence that libc should be poked
        // again. A recommit below the threshold re-arms a future contraction.
        if (!processHeapTrimNeeded(current, released)) return;
        self.stats.malloc_trim_attempts += 1;
        if (malloc_trim(0) != 0) self.stats.malloc_trim_successes += 1;
    }

    pub const VerifyError = error{
        BlockGeometryCorrupt,
        BlockIndexMismatch,
        BlockScanFilterMismatch,
        BitmapTailSet,
        AllocCountMismatch,
        NonemptyBitmapMismatch,
        FreeListNotEmpty,
        FreeListMembershipMismatch,
        DecommittedBlockOccupied,
        FreeChainCorrupt,
        FreeCellPoisonMismatch,
        ListLinkOutOfHeap,
        YoungListCycle,
        YoungListFlagMismatch,
        DoomedListCycle,
        DoomedListMembershipMismatch,
        DoomedBitForFreeCell,
        UnlistedYoungFlag,
        AllocatedCellUnpublished,
        CellIndexStampMismatch,
        YoungCellUnlisted,
        SweepStateInvariant,
        CarrierIdentityMismatch,
    };

    /// Cross-check the block heap's counters against its bitmaps.
    ///
    /// This is the invariant nobody was checking, and it guards the three
    /// operations that trust `allocated_count` absolutely: `resetBlock`
    /// zeroes the alloc bitmap, the decommit walk hands whole cell ranges
    /// back to the OS, and `openBlock` re-serves a block as empty. A drift
    /// of one in that count silently turns any of them into "free a live
    /// object". Per the 2026-08-25 ruling that invariants get a checker
    /// rather than N targeted tests. Runs only under the arena audit.
    pub fn verify(self: *Heap) VerifyError!void {
        var initialized_blocks: usize = 0;
        var expected_block_filter: usize = 0;
        var eligible_free_blocks: usize = 0;
        var pending_doomed_blocks: usize = 0;
        for (self.superblocks.items) |sb| {
            if (sb.kind != .classed) continue;
            if (sb.used_blocks > blocks_per_superblock) return error.BlockGeometryCorrupt;
            var i: usize = 0;
            while (i < blocks_per_superblock) : (i += 1) {
                const block: *Block = @ptrFromInt(@intFromPtr(sb.bytes.ptr) + i * block_bytes);
                const indexed = testPage(sb.page_bits, @intCast(i));
                if (i >= sb.used_blocks) {
                    if (indexed) return error.NonemptyBitmapMismatch;
                    if (self.classed_blocks.contains(@intFromPtr(block))) {
                        return error.BlockIndexMismatch;
                    }
                    continue;
                }
                if (block.magic != block_magic) return error.BlockGeometryCorrupt;
                const block_base = @intFromPtr(block);
                if (!self.classed_blocks.contains(block_base)) return error.BlockIndexMismatch;
                expected_block_filter |= block_base;
                if (indexed != (block.allocated_count != 0)) return error.NonemptyBitmapMismatch;
                initialized_blocks += 1;
                if (block.size_class >= space.class_count) {
                    return error.BlockGeometryCorrupt;
                }
                // §8.7's physical authority has two stable states: populated
                // or allocator-current blocks are active, and only fully empty
                // free-list blocks are swept. The other enum values belong to
                // the retired historical design (fresh remains a private
                // openBlock transient); reject them at every audit boundary.
                switch (block.sweep_state) {
                    .active => {
                        if (block.allocated_count == 0 and self.active[block.size_class] != block) {
                            return error.SweepStateInvariant;
                        }
                    },
                    .swept => {
                        if (block.allocated_count != 0 or self.active[block.size_class] == block) {
                            return error.SweepStateInvariant;
                        }
                    },
                    .fresh, .needs_sweep, .sweeping => return error.SweepStateInvariant,
                }
                const expected = blockGeometry(@intCast(space.classes[block.size_class]));
                if (block.cell_size != @as(u32, @intCast(space.classes[block.size_class])) or
                    block.cell_count != expected.cell_count or
                    block.bitmap_words != expected.bitmap_words or
                    block.alloc_bits_off != expected.alloc_off or
                    block.mark_bits_off != expected.mark_off or
                    block.remember_bits_off != expected.remember_off or
                    block.remember_bits_off + block.bitmap_words * 8 != expected.finalizer_off or
                    block.cells_offset != expected.cells_off or
                    block.bump > block.cell_count)
                {
                    return error.BlockGeometryCorrupt;
                }
                const interval_mode = block.flags & Block.flag_interval_allocator != 0;
                const hot_unprepared = block.flags & Block.flag_hot_list != 0;
                // Stage-3 settlement removes cells from the alloc bitmap
                // without writing a free link, so for such a block the chain
                // walk below would (correctly) report an incomplete chain. The
                // bitmap remains the canonical authority and is still checked
                // by `AllocCountMismatch` and the doomed/tail-bit rules above.
                const bitmap_canonical = block.flags & Block.flag_bitmap_canonical != 0;
                if (hot_unprepared) {
                    if (interval_mode) return error.SweepStateInvariant;
                } else if (interval_mode) {
                    if (block.bump > block.interval_end or block.interval_end > block.cell_count) {
                        return error.BlockGeometryCorrupt;
                    }
                } else if (block.interval_end != 0 or block.allocated_count > block.bump) {
                    return error.BlockGeometryCorrupt;
                }
                if (block.allocated_count == 0 and self.active[block.size_class] != block) {
                    eligible_free_blocks += 1;
                }
                var set: u32 = 0;
                for (block.bitmaps().alloc) |word| set += @popCount(word);
                if (set != block.allocated_count) return error.AllocCountMismatch;
                const tail_bits: u6 = @intCast(block.cell_count % 64);
                if (tail_bits != 0) {
                    const valid = (@as(u64, 1) << tail_bits) - 1;
                    const maps = block.bitmaps();
                    const last = maps.alloc.len - 1;
                    if ((maps.alloc[last] | maps.mark[last] | maps.remember[last] |
                        block.finalizerBits()[last]) & ~valid != 0)
                    {
                        return error.BitmapTailSet;
                    }
                }
                const maps = block.bitmaps();
                for (maps.remember, maps.alloc) |doomed, allocated| {
                    if (doomed & ~allocated != 0) return error.DoomedBitForFreeCell;
                }
                if (block.doomed_word != 0) {
                    if (block.doomed_cursor >= block.bitmap_words) return error.BlockGeometryCorrupt;
                    if (block.doomed_word & ~maps.alloc[block.doomed_cursor] != 0) {
                        return error.DoomedBitForFreeCell;
                    }
                }
                if (block.hasPendingDoomed()) pending_doomed_blocks += 1;
                // Walk the cell free chain or the maximal-interval encoding.
                // Links live in each free
                // cell's first four bytes, which are also the GC metadata
                // prefix -- so anything that mistakes a free cell for a live
                // header and writes a flag corrupts the chain, and the
                // failure surfaces later as `popCell` following a wild
                // index. Checking it here names the moment instead.
                if (!hot_unprepared and !bitmap_canonical and
                    block.free_list >= block.cell_count and block.free_list != free_nil)
                {
                    std.debug.print(
                        "gc: BLOCK HEAP AUDIT free head out of range block=0x{x} head={d} cells={d}\n",
                        .{ @intFromPtr(block), block.free_list, block.cell_count },
                    );
                    return error.FreeChainCorrupt;
                }
                if (hot_unprepared or bitmap_canonical) {
                    // The alloc bitmap is the sole canonical free-space
                    // representation until openBlock rebuilds intervals.
                } else if (interval_mode) {
                    var free_cells: u32 = block.interval_end - block.bump;
                    var current = block.bump;
                    while (current < block.interval_end) : (current += 1) {
                        if (testBitPlain(maps.alloc, current)) return error.FreeChainCorrupt;
                    }

                    var interval = block.free_list;
                    var previous_end = block.interval_end;
                    var intervals: u32 = 0;
                    while (interval != free_nil) {
                        if (interval >= block.cell_count or interval <= previous_end) {
                            return error.FreeChainCorrupt;
                        }
                        const cell = block.cellPtr(interval);
                        const raw = @as(*const u32, @ptrCast(@alignCast(cell))).*;
                        if (raw & ~free_link_mask != free_poison) {
                            return error.FreeCellPoisonMismatch;
                        }
                        const end = @as(*const u32, @ptrCast(@alignCast(cell + 4))).*;
                        if (interval >= end or end > block.cell_count) return error.FreeChainCorrupt;
                        current = interval;
                        while (current < end) : (current += 1) {
                            if (testBitPlain(maps.alloc, current)) return error.FreeChainCorrupt;
                        }
                        free_cells += end - interval;
                        intervals += 1;
                        if (intervals > block.cell_count) return error.FreeChainCorrupt;
                        previous_end = end;
                        interval = raw & free_link_mask;
                    }

                    // On a hot-list block `next_free` links blocks. Otherwise
                    // it is the exceptional returned-cell chain accumulated
                    // after interval publication.
                    if (block.flags & Block.flag_hot_list == 0) {
                        var returned: u32 = @intCast(block.next_free);
                        var returned_count: u32 = 0;
                        while (returned != free_nil) {
                            if (returned >= block.cell_count or testBitPlain(maps.alloc, returned)) {
                                return error.FreeChainCorrupt;
                            }
                            const raw = @as(*const u32, @ptrCast(@alignCast(block.cellPtr(returned)))).*;
                            if (raw & ~free_link_mask != free_poison) {
                                return error.FreeCellPoisonMismatch;
                            }
                            free_cells += 1;
                            returned_count += 1;
                            if (returned_count > block.cell_count) return error.FreeChainCorrupt;
                            returned = raw & free_link_mask;
                        }
                    }
                    if (free_cells != block.cell_count - block.allocated_count) {
                        return error.FreeChainCorrupt;
                    }
                } else {
                    var link = block.free_list;
                    var walked: u32 = 0;
                    while (link != free_nil) {
                        if (link >= block.cell_count) return error.FreeChainCorrupt;
                        if (testBitPlain(block.bitmaps().alloc, link)) {
                            std.debug.print(
                                "gc: BLOCK HEAP AUDIT free link names allocated cell block=0x{x} link={d} walked={d}\n",
                                .{ @intFromPtr(block), link, walked },
                            );
                            return error.FreeChainCorrupt;
                        }
                        walked += 1;
                        if (walked > block.cell_count) return error.FreeChainCorrupt; // cycle
                        const raw = @as(*const u32, @ptrCast(@alignCast(block.cellPtr(link)))).*;
                        if (raw & ~free_link_mask != free_poison) {
                            std.debug.print(
                                "gc: BLOCK HEAP AUDIT free poison mismatch block=0x{x} link={d} raw=0x{x} walked={d} head={d} bump={d} allocated={d}\n",
                                .{ @intFromPtr(block), link, raw, walked, block.free_list, block.bump, block.allocated_count },
                            );
                            return error.FreeCellPoisonMismatch;
                        }
                        link = raw & free_link_mask;
                    }
                    // Completeness, not just validity: every cell handed out
                    // by the bump pointer and since freed is reachable.
                    if (walked != block.bump - block.allocated_count) {
                        std.debug.print(
                            "gc: BLOCK HEAP AUDIT incomplete free chain block=0x{x} walked={d} expected={d} head={d} bump={d} allocated={d}\n",
                            .{ @intFromPtr(block), walked, block.bump - block.allocated_count, block.free_list, block.bump, block.allocated_count },
                        );
                        return error.FreeChainCorrupt;
                    }
                }
                if (block.flags & Block.flag_decommitted != 0 and block.allocated_count != 0) {
                    return error.DecommittedBlockOccupied;
                }
            }
        }
        if (self.classed_blocks.count() != initialized_blocks) return error.BlockIndexMismatch;
        if (self.classed_block_filter != expected_block_filter) return error.BlockScanFilterMismatch;

        // The two intrusive lists. `resetBlock` writes the whole struct, so a
        // block reset while listed severs the chain there and every block
        // behind it silently leaves -- for the doomed list that means corpses
        // never destroyed, for the young list young cells a minor will never
        // see. Membership is checked both ways: reachable-from-head implies
        // the flag, and the flag implies reachable. Trace-coupled retirement
        // makes the young list the sole structural record of what is young,
        // so this is the invariant it rests on.
        const max_blocks = blocks_per_superblock * self.superblocks.items.len + 1;
        var young_seen: usize = 0;
        {
            var cursor = self.young_blocks;
            while (cursor) |block| {
                if (!self.containsInitializedBlock(block) or block.magic != block_magic) {
                    return error.ListLinkOutOfHeap;
                }
                if (block.flags & Block.flag_young == 0) return error.YoungListFlagMismatch;
                young_seen += 1;
                if (young_seen > max_blocks) return error.YoungListCycle;
                const link = block.young_link;
                cursor = try self.blockFromListLink(link);
            }
        }
        var doomed_seen: usize = 0;
        {
            var cursor = self.doomed_blocks;
            while (cursor) |block| {
                if (!self.containsInitializedBlock(block) or block.magic != block_magic) {
                    return error.ListLinkOutOfHeap;
                }
                if (!block.hasPendingDoomed()) return error.DoomedListMembershipMismatch;
                if (block.sweep_state != .active) return error.SweepStateInvariant;
                doomed_seen += 1;
                if (doomed_seen > max_blocks) return error.DoomedListCycle;
                const link = block.doomed_link;
                cursor = try self.blockFromListLink(link);
            }
        }
        if (doomed_seen != pending_doomed_blocks) return error.DoomedListMembershipMismatch;
        var flagged: usize = 0;
        var hot_flagged: usize = 0;
        for (self.superblocks.items) |sb2| {
            if (sb2.kind != .classed) continue;
            var j: usize = 0;
            while (j < blocks_per_superblock) : (j += 1) {
                const b2: *Block = @ptrFromInt(@intFromPtr(sb2.bytes.ptr) + j * block_bytes);
                if (b2.magic != block_magic) continue;
                if (b2.flags & Block.flag_young != 0) flagged += 1;
                if (b2.flags & Block.flag_hot_list != 0) hot_flagged += 1;
            }
        }
        if (flagged != young_seen) return error.UnlistedYoungFlag;
        var free_seen_total: usize = 0;
        for (self.free_blocks, 0..) |head, class_idx| {
            var cursor = head;
            var seen: usize = 0;
            while (cursor) |block| {
                if (!self.containsInitializedBlock(block) or block.magic != block_magic) {
                    return error.ListLinkOutOfHeap;
                }
                if (block.allocated_count != 0) return error.FreeListNotEmpty;
                if (block.size_class != class_idx) return error.FreeListNotEmpty;
                if (block.flags & Block.flag_young != 0 or block.doomed_link != 0) {
                    return error.FreeListMembershipMismatch;
                }
                if (block.sweep_state != .swept) return error.SweepStateInvariant;
                seen += 1;
                free_seen_total += 1;
                if (seen > initialized_blocks + 1) {
                    return error.FreeListNotEmpty;
                }
                cursor = try self.blockFromFreeLink(block.next_free);
            }
        }
        if (free_seen_total != eligible_free_blocks) return error.FreeListMembershipMismatch;

        var hot_seen_total: usize = 0;
        for (self.hot_blocks, 0..) |head, class_idx| {
            var cursor = head;
            var seen: usize = 0;
            while (cursor) |block| {
                if (!self.containsInitializedBlock(block) or block.magic != block_magic) {
                    return error.ListLinkOutOfHeap;
                }
                if (block.size_class != class_idx or block.allocated_count == 0 or
                    self.active[class_idx] == block or block.hasPendingDoomed() or
                    !hasHotReuseCapacity(block) or block.sweep_state != .active or
                    block.flags & Block.flag_hot_list == 0 or
                    block.flags & Block.flag_interval_allocator != 0 or
                    block.flags & (Block.flag_young | Block.flag_decommitted) != 0)
                {
                    return error.FreeListMembershipMismatch;
                }
                seen += 1;
                hot_seen_total += 1;
                if (seen > initialized_blocks + 1) return error.FreeListNotEmpty;
                cursor = try self.blockFromFreeLink(block.next_free);
            }
        }
        if (hot_seen_total != hot_flagged) return error.FreeListMembershipMismatch;

        for (self.active, 0..) |active, class_idx| {
            const block = active orelse continue;
            if (!self.containsInitializedBlock(block) or block.size_class != class_idx) {
                return error.FreeListMembershipMismatch;
            }
            if (block.sweep_state != .active) return error.SweepStateInvariant;
        }
    }

    /// Cross-check the allocation bitmap against the metadata publication
    /// prefix. Kept separate from `verify`: raw block-heap tests use `alloc`,
    /// while the runtime uses `allocCell` and promises every allocated cell is
    /// a published object at collection boundaries.
    pub const UnpublishedCellAllowance = struct {
        pub const Kind = enum {
            none,
            /// A detached construction root is intentionally unpublished.
            /// Heap-accounting audits may accept it before a collection marks
            /// it; collector publication audits use the stricter next arm.
            unmarked_construction,
            /// A detached construction root must have been marked by this
            /// collection before an unpublished cell can be accepted.
            marked_construction,
            /// A resource-stripped corpse remains allocated until deferred
            /// finalizers finish; exact deferred-stack membership is the
            /// authority, not a liveness mark.
            parked_finalizer,
        };

        context: *const anyopaque,
        classify: *const fn (context: *const anyopaque, cell_addr: usize) Kind,
    };

    /// Runtime audit variant. Detached generator shells require exact
    /// construction-root membership plus the current mark. Resource-stripped
    /// objects waiting behind a deferred finalizer require exact parked-stack
    /// membership instead: they are dead, so demanding a liveness mark would
    /// turn the audit itself into a false invariant.
    pub fn verifyPublishedCellsAllowing(
        self: *const Heap,
        block_cell_marker: u5,
        object_kind: u4,
        allowance: ?UnpublishedCellAllowance,
    ) VerifyError!void {
        return self.verifyCellsAllowing(block_cell_marker, object_kind, allowance, true);
    }

    /// Heap-accounting needs the same alloc-bit/publication cross-check but is
    /// also called at boundaries where young-list retirement is not complete.
    /// Keep the publication proof while leaving generation membership to the
    /// collector-boundary variant above.
    pub fn verifyAccountingCellsAllowing(
        self: *const Heap,
        block_cell_marker: u5,
        object_kind: u4,
        allowance: ?UnpublishedCellAllowance,
    ) VerifyError!void {
        return self.verifyCellsAllowing(block_cell_marker, object_kind, allowance, false);
    }

    fn verifyCellsAllowing(
        self: *const Heap,
        block_cell_marker: u5,
        object_kind: u4,
        allowance: ?UnpublishedCellAllowance,
        require_young_membership: bool,
    ) VerifyError!void {
        for (self.superblocks.items) |sb| {
            if (sb.kind != .classed) continue;
            var i: usize = 0;
            while (i < sb.used_blocks) : (i += 1) {
                const block: *Block = @ptrFromInt(@intFromPtr(sb.bytes.ptr) + i * block_bytes);
                var index: u32 = 0;
                while (index < block.cell_count) : (index += 1) {
                    if (!block.cellAllocated(index)) continue;
                    const cell = block.cellBase(index);
                    const stored_index = @as(*const u16, @ptrFromInt(cell)).*;
                    if (stored_index != index) return error.CellIndexStampMismatch;
                    const alloc_info = @as(*const u8, @ptrFromInt(cell + 2)).*;
                    const flags = @as(*const u8, @ptrFromInt(cell + 3)).*;
                    const accounted = alloc_info & gc_representation.alloc_info_heap_accounted_mask != 0;
                    const standalone = alloc_info & gc_representation.alloc_info_standalone_mask != 0;
                    // String-family cells share the block heap with Objects
                    // and carry kinds 6 (flat body) / 11 (rope node) / 12
                    // (TGC S2-i tail buffer) in the same prefix byte -- the
                    // kind is the low nibble since TGC S4-a. TGC S4-b adds the
                    // bare storage cells 8 (property entries) / 9 (array
                    // elements), TGC S4-c the a-class payload cells (10).
                    const cell_kind = flags & gc_representation.kind_mask;
                    const prefix_valid = !standalone and
                        alloc_info & gc_representation.alloc_info_class_mask == block_cell_marker and
                        (cell_kind == object_kind or
                            cell_kind == gc_representation.string_kind_tag or
                            cell_kind == gc_representation.rope_kind_tag or
                            cell_kind == gc_representation.string_buffer_kind_tag or
                            cell_kind == gc_representation.property_storage_kind_tag or
                            cell_kind == gc_representation.array_storage_kind_tag or
                            cell_kind == gc_representation.payload_kind_tag);
                    if (!accounted and prefix_valid) {
                        const allowed = if (allowance) |candidate|
                            candidate.classify(candidate.context, cell)
                        else
                            UnpublishedCellAllowance.Kind.none;
                        switch (allowed) {
                            .none => {},
                            .unmarked_construction => continue,
                            .marked_construction => if (block.isMarked(index, self.mark_epoch)) continue,
                            .parked_finalizer => continue,
                        }
                    }
                    if (!accounted or !prefix_valid) {
                        return error.AllocatedCellUnpublished;
                    }
                    const young = flags & (1 << 4) != 0;
                    if (require_young_membership and young and
                        !block.cellPendingDoomed(index) and !block.isYoungListed())
                    {
                        std.debug.print(
                            "gc: BLOCK CELL AUDIT young cell 0x{x} index {d} in unlisted block 0x{x} (flags=0x{x}, block_flags=0x{x}, marked={any}, doomed=0x{x}, doomed_cursor={d}, doomed_word=0x{x})\n",
                            .{
                                cell,
                                index,
                                @intFromPtr(block),
                                flags,
                                block.flags,
                                block.isMarked(index, self.mark_epoch),
                                block.bitmaps().remember[index / 64],
                                block.doomed_cursor,
                                block.doomed_word,
                            },
                        );
                        return error.YoungCellUnlisted;
                    }
                }
            }
        }
    }

    pub fn blockOf(self: *const Heap, ptr: [*]u8) ?*Block {
        // Arithmetic first, membership second, DEREFERENCE LAST. This is fed
        // arbitrary conservative candidates now, and the old order -- mask,
        // read the magic, then check membership -- read one word out of
        // whatever page the mask landed in, which for a stray stack integer
        // is as likely unmapped as not.
        return self.blockOfWithFilter(ptr, self.classed_block_filter);
    }

    /// Register-local snapshot for a conservative span, mirroring JSC's
    /// local copy of `MarkedBlockSet::filter()`. Classed block membership is
    /// monotonic and a conservative scan runs stop-the-world, so this cannot
    /// become stale during the span.
    pub inline fn scanFilter(self: *const Heap) usize {
        return self.classed_block_filter;
    }

    pub inline fn blockOfWithFilter(self: *const Heap, ptr: [*]u8, filter: usize) ?*Block {
        const addr = @intFromPtr(ptr);
        if (addr < block_bytes) return null;
        const base = addr & ~@as(usize, block_bytes - 1);
        if ((base & filter) != base) return null;
        if (!self.classed_blocks.contains(base)) return null;
        const block: *Block = @ptrFromInt(base);
        if (block.magic != block_magic) return null;
        return block;
    }

    /// Live bytes and live cells, derived from the bitmaps rather than
    /// counted on the allocation path.
    ///
    /// Maintaining them cost three read-modify-writes per allocation and two
    /// per free on a shared struct -- 18 M allocations on splay, 90 M on
    /// raytrace, 255 M on earley-boyer -- and every consumer is a diagnostic:
    /// the `--gc-stats` panel, the collection report, and the audit. Small,
    /// medium and large allocations keep their own counts because those are
    /// rare and their sizes are not derivable from a bitmap.
    pub fn liveSmall(self: *const Heap) struct { bytes: usize, count: usize } {
        var bytes: usize = 0;
        var count: usize = 0;
        for (self.superblocks.items) |sb| {
            if (sb.kind != .classed) continue;
            var i: usize = 0;
            while (i < sb.used_blocks) : (i += 1) {
                const block: *Block = @ptrFromInt(@intFromPtr(sb.bytes.ptr) + i * block_bytes);
                if (block.magic != block_magic) continue;
                count += block.allocated_count;
                bytes += @as(usize, block.allocated_count) * block.cell_size;
            }
        }
        return .{ .bytes = bytes, .count = count };
    }

    pub const ClassCensus = struct {
        initialized_blocks: usize = 0,
        nonempty_blocks: usize = 0,
        empty_free_blocks: usize = 0,
        empty_active_blocks: usize = 0,
        live_cells: usize = 0,
        cell_capacity: usize = 0,
    };

    /// Endpoint topology for `--gc-stats`. This is deliberately derived by a
    /// cold walk instead of maintained on allocation/free: splay performs
    /// 18 M publications, while the only consumer is a requested diagnostic
    /// panel. In particular, the per-class rows expose blocks that are wholly
    /// empty but cannot serve another class under the current free-list rule;
    /// do not conflate that with partially-free block reuse.
    pub const Census = struct {
        classed_superblocks: usize = 0,
        medium_superblocks: usize = 0,
        initialized_blocks: usize = 0,
        reserved_uninitialized_blocks: usize = 0,
        nonempty_blocks: usize = 0,
        partially_full_blocks: usize = 0,
        empty_free_blocks: usize = 0,
        empty_active_blocks: usize = 0,
        decommitted_empty_blocks: usize = 0,
        wholly_empty_superblocks: usize = 0,
        hot_reuse_blocks: usize = 0,
        interval_active_blocks: usize = 0,
        live_cell_bytes: usize = 0,
        nonempty_cell_capacity_bytes: usize = 0,
        empty_cell_capacity_bytes: usize = 0,
        classes: [space.class_count]ClassCensus = @splat(.{}),
    };

    pub fn census(self: *const Heap) Census {
        var out: Census = .{};
        for (self.superblocks.items) |sb| {
            switch (sb.kind) {
                .medium => {
                    out.medium_superblocks += 1;
                    continue;
                },
                .tombstone => continue,
                .classed => out.classed_superblocks += 1,
            }
            if (sb.page_bits[0] == 0) out.wholly_empty_superblocks += 1;
            out.initialized_blocks += sb.used_blocks;
            out.reserved_uninitialized_blocks += blocks_per_superblock - sb.used_blocks;

            var i: usize = 0;
            while (i < sb.used_blocks) : (i += 1) {
                const block: *const Block = @ptrFromInt(@intFromPtr(sb.bytes.ptr) + i * block_bytes);
                if (block.magic != block_magic) continue;
                const class_idx = block.size_class;
                if (block.flags & Block.flag_hot_list != 0) out.hot_reuse_blocks += 1;
                if (block.flags & Block.flag_interval_allocator != 0 and
                    self.active[class_idx] == block)
                {
                    out.interval_active_blocks += 1;
                }
                const class = &out.classes[class_idx];
                class.initialized_blocks += 1;
                class.live_cells += block.allocated_count;
                class.cell_capacity += block.cell_count;

                const capacity_bytes = @as(usize, block.cell_count) * block.cell_size;
                if (block.allocated_count == 0) {
                    out.empty_cell_capacity_bytes += capacity_bytes;
                    if (block.flags & Block.flag_decommitted != 0) {
                        out.decommitted_empty_blocks += 1;
                    }
                    if (self.active[class_idx] == block) {
                        out.empty_active_blocks += 1;
                        class.empty_active_blocks += 1;
                    } else {
                        out.empty_free_blocks += 1;
                        class.empty_free_blocks += 1;
                    }
                    continue;
                }

                out.nonempty_blocks += 1;
                class.nonempty_blocks += 1;
                out.live_cell_bytes += @as(usize, block.allocated_count) * block.cell_size;
                out.nonempty_cell_capacity_bytes += capacity_bytes;
                if (block.allocated_count != block.cell_count) out.partially_full_blocks += 1;
            }
        }
        return out;
    }

    /// Total live bytes including the non-cell spaces, for the panel.
    pub fn liveBytes(self: *const Heap) usize {
        var total = self.liveSmall().bytes;
        var large_it = self.large.valueIterator();
        while (large_it.next()) |v| total += v.bytes.len;
        var med_it = self.medium.valueIterator();
        while (med_it.next()) |v| total += v.user_bytes;
        return total;
    }

    pub fn committedLiveMilli(self: *const Heap) usize {
        const live = self.liveBytes();
        if (live == 0) return 0;
        return (self.stats.committed_bytes * 1000 + live - 1) / live;
    }

    fn containsBlock(self: *const Heap, block: *const Block) bool {
        return self.classed_blocks.contains(@intFromPtr(block));
    }

    fn containsInitializedBlock(self: *const Heap, block: *const Block) bool {
        return self.containsBlock(block);
    }

    fn blockFromListLink(self: *const Heap, link: usize) VerifyError!?*Block {
        if (link == 1) return null;
        if (link == 0) return error.ListLinkOutOfHeap;
        if (link & (block_bytes - 1) != 0) return error.ListLinkOutOfHeap;
        const block: *Block = @ptrFromInt(link);
        if (!self.containsInitializedBlock(block)) return error.ListLinkOutOfHeap;
        if (block.magic != block_magic) return error.ListLinkOutOfHeap;
        return block;
    }

    fn blockFromFreeLink(self: *const Heap, link: usize) VerifyError!?*Block {
        if (link == 0) return null;
        if (link == 1) return error.ListLinkOutOfHeap;
        return self.blockFromListLink(link);
    }

    fn allocSmall(self: *Heap, class_idx: usize, user_bytes: usize) std.mem.Allocator.Error![]u8 {
        const cell_size: u32 = @intCast(space.classes[class_idx]);
        const cell = try self.allocSmallCell(class_idx, cell_size);
        return cell[0..user_bytes];
    }

    fn freeSmall(self: *Heap, block: *Block, index: u32, cell: [*]u8) void {
        if (!testBitPlain(block.bitmaps().alloc, index)) return;
        block.forgetDoomedCell(index);
        if (comptime lifecycle_state_enabled) {
            self.lifecycleFor(block, index).state = .raw_free_in_progress;
        }
        clearBitPlain(block.bitmaps().alloc, index);
        // A recycled cell must not inherit its predecessor's finalizer duty.
        block.clearFinalizerBit(index);
        pushCell(block, index, cell);
        block.allocated_count -= 1;
        // This block just gained free space, so a cached "no long enough
        // interval" verdict is out of date (S4-f (2)). The header line is
        // already dirty from `allocated_count`.
        block.flags &= ~Block.flag_hot_rejected;
        if (comptime lifecycle_state_enabled) {
            const lifecycle = self.lifecycleFor(block, index);
            lifecycle.state = .free;
            lifecycle.accounted_bytes = 0;
        }
        if (block.allocated_count == 0) {
            self.noteEmptyBlock(block);
            const class_idx = block.size_class;
            if (self.active[class_idx] == block) return;
            // Empty blocks keep the existing aged-decommit lifecycle. Their
            // interval state no longer has a consumer, and `next_free` is
            // about to become a block-list link.
            block.flags &= ~(Block.flag_interval_allocator | Block.flag_hot_list |
                Block.flag_bitmap_canonical);
            block.bump = 0;
            block.interval_end = 0;
            block.free_list = free_nil;
            block.sweep_state = .swept;
            block.free_time_ns = self.clock_ns;
            block.next_free = if (self.free_blocks[class_idx]) |head| @intFromPtr(head) else 0;
            self.free_blocks[class_idx] = block;
        }
    }

    fn openBlock(self: *Heap, class_idx: usize, cell_size: u32) std.mem.Allocator.Error!*Block {
        while (self.hot_blocks[class_idx]) |block| {
            const link = block.next_free;
            self.hot_blocks[class_idx] = if (link == 0) null else @ptrFromInt(link);
            std.debug.assert(block.flags & Block.flag_hot_list != 0);
            std.debug.assert(block.allocated_count != 0);
            std.debug.assert(!block.hasPendingDoomed());
            block.flags &= ~Block.flag_hot_list;
            block.next_free = free_nil;
            block.sweep_state = .active;
            const max_interval = rebuildFreeIntervals(block);
            if (max_interval < hot_reuse_min_interval_cells) {
                self.stats.hot_blocks_k_rejected +|= 1;
                block.flags |= Block.flag_hot_rejected;
                // K-rejected non-empty partial: retain the valid interval
                // representation just built, but give it no allocation/list
                // owner. It remains census-owned and non-decommittable until
                // a later major can reconsider it after more deaths.
                continue;
            }
            self.stats.hot_blocks_reopened += 1;
            return block;
        }
        if (self.free_blocks[class_idx]) |block| {
            self.free_blocks[class_idx] = if (block.next_free == 0)
                null
            else
                @ptrFromInt(block.next_free);
            if (block.flags & Block.flag_decommitted != 0) {
                // The pages re-fault as zero on first touch; only the account
                // moves here. `resetBlock` clears the flag with the rest.
                self.stats.recommitted_bytes += decommit_bytes;
                self.stats.committed_bytes += decommit_bytes;
            }
            const super_index = block.super_index;
            try self.resetBlock(block, class_idx, cell_size, super_index, true);
            block.sweep_state = .active;
            return block;
        }
        const slot = try self.takeClassedBlock(cell_size);
        const block: *Block = @ptrCast(@alignCast(slot.ptr));
        try self.resetBlock(block, class_idx, cell_size, slot.super_index, false);
        block.sweep_state = .fresh;
        block.sweep_state = .active;
        return block;
    }

    fn takeClassedBlock(self: *Heap, cell_size: u32) std.mem.Allocator.Error!struct { ptr: [*]u8, super_index: u32 } {
        const geometry = blockGeometry(cell_size);
        for (self.superblocks.items, 0..) |*sb, super_index| {
            if (sb.kind != .classed) continue;
            if (sb.used_blocks >= blocks_per_superblock) continue;
            const off = sb.used_blocks * block_bytes;
            const base = @intFromPtr(sb.bytes.ptr + off);
            const block_index: usize = sb.used_blocks;
            // The rollbacks below MUST be declared in the loop-body scope, not
            // inside the `if (comptime ...)` blocks that own the allocation:
            // an `errdefer` fires when *its own* scope unwinds with an error,
            // and a comptime-if block that falls through has already exited
            // normally by the time a later `try` fails. Written the other way
            // (as it was until the block heap's backing became injectable), a
            // failing `cell_lifecycles` alloc or `classed_blocks.put` left
            // `cell_generations[block_index]` allocated while `used_blocks`
            // stayed put, and the next `takeClassedBlock` for that superblock
            // tripped the `len == 0` assertion on the very same slot.
            if (comptime block_generation_enabled) {
                std.debug.assert(sb.cell_generations[block_index].len == 0);
                sb.cell_generations[block_index] = try self.backing.alloc(u32, geometry.cell_count);
                @memset(sb.cell_generations[block_index], 0);
            }
            errdefer if (comptime block_generation_enabled) {
                self.backing.free(sb.cell_generations[block_index]);
                sb.cell_generations[block_index] = &.{};
            };
            if (comptime lifecycle_state_enabled) {
                std.debug.assert(sb.cell_lifecycles[block_index].len == 0);
                sb.cell_lifecycles[block_index] = try self.backing.alloc(CellLifecycle, geometry.cell_count);
                @memset(sb.cell_lifecycles[block_index], .{});
            }
            errdefer if (comptime lifecycle_state_enabled) {
                self.backing.free(sb.cell_lifecycles[block_index]);
                sb.cell_lifecycles[block_index] = &.{};
            };
            try self.classed_blocks.put(self.backing, base, {});
            self.classed_block_filter |= base;
            sb.used_blocks += 1;
            return .{ .ptr = sb.bytes.ptr + off, .super_index = @intCast(super_index) };
        }
        const slot = try self.reserveSuperblock(.classed);
        // Make publication of any of this superblock's 32 block bases
        // infallible after the mapping exists. Roll the mapping back if the
        // membership index cannot reserve: an allocation error must not leave
        // a committed-but-unusable superblock behind.
        self.classed_blocks.ensureUnusedCapacity(self.backing, blocks_per_superblock) catch |err| {
            self.unreserveSuperblock(slot);
            return err;
        };
        if (comptime block_generation_enabled) {
            self.superblocks.items[slot].cell_generations[0] =
                self.backing.alloc(u32, geometry.cell_count) catch |err| {
                    self.unreserveSuperblock(slot);
                    return err;
                };
            @memset(self.superblocks.items[slot].cell_generations[0], 0);
        }
        if (comptime lifecycle_state_enabled) {
            self.superblocks.items[slot].cell_lifecycles[0] =
                self.backing.alloc(CellLifecycle, geometry.cell_count) catch |err| {
                    if (comptime block_generation_enabled) {
                        self.backing.free(self.superblocks.items[slot].cell_generations[0]);
                        self.superblocks.items[slot].cell_generations[0] = &.{};
                    }
                    self.unreserveSuperblock(slot);
                    return err;
                };
            @memset(self.superblocks.items[slot].cell_lifecycles[0], .{});
        }
        const sb = &self.superblocks.items[slot];
        const base = @intFromPtr(sb.bytes.ptr);
        self.classed_blocks.putAssumeCapacity(base, {});
        self.classed_block_filter |= base;
        sb.used_blocks = 1;
        return .{ .ptr = sb.bytes.ptr, .super_index = slot };
    }

    /// Returns the SLOT INDEX, not a pointer: `superblocks` can grow, and a
    /// reused tombstone is not at the tail, so neither the address nor
    /// `items.len - 1` is a valid way for a caller to name what it just got.
    fn reserveSuperblock(self: *Heap, kind: SuperblockKind) std.mem.Allocator.Error!u32 {
        std.debug.assert(kind != .tombstone);
        var incarnations: if (block_generation_enabled) [blocks_per_superblock]u32 else void =
            if (block_generation_enabled) @splat(0) else {};
        if (comptime block_generation_enabled) {
            if (kind == .classed) {
                var i: usize = 0;
                while (i < blocks_per_superblock) : (i += 1) {
                    if (self.block_generation_exhausted or self.next_block_incarnation == std.math.maxInt(u32)) {
                        self.block_generation_exhausted = true;
                        return error.OutOfMemory;
                    }
                    incarnations[i] = self.next_block_incarnation;
                    self.next_block_incarnation += 1;
                }
            }
        }
        const bytes = try self.backing.alignedAlloc(u8, block_align, superblock_bytes);
        errdefer self.backing.free(bytes);
        const fresh: Superblock = .{
            .bytes = bytes,
            .kind = kind,
            .block_incarnations = if (block_generation_enabled) incarnations else {},
        };
        const slot: u32 = blk: {
            const head = self.free_superblock_slots;
            if (head != bucket_nil) {
                std.debug.assert(self.superblocks.items[head].kind == .tombstone);
                self.free_superblock_slots = self.superblocks.items[head].free_slot_next;
                break :blk head;
            }
            try self.superblocks.append(self.backing, fresh);
            break :blk @intCast(self.superblocks.items.len - 1);
        };
        self.superblocks.items[slot] = fresh;
        self.stats.superblocks += 1;
        self.stats.committed_bytes += superblock_bytes;
        return slot;
    }

    /// Undo a `reserveSuperblock`: return the mapping and make the slot
    /// reusable. Cannot fail and cannot move any other slot, because
    /// `Block.super_index` / `MediumExtent.super_index` / the bucket links all
    /// name slots by index. The tail case still pops so a rollback of the very
    /// last reservation leaves no residue at all.
    fn unreserveSuperblock(self: *Heap, slot: u32) void {
        const sb = &self.superblocks.items[slot];
        std.debug.assert(sb.kind != .tombstone);
        std.debug.assert(sb.bucket_prev == bucket_nil and sb.bucket_next == bucket_nil);
        std.debug.assert(sb.max_free_run == 0);
        const bytes = sb.bytes;
        self.stats.superblocks -= 1;
        self.stats.committed_bytes -= superblock_bytes;
        if (slot + 1 == self.superblocks.items.len) {
            self.superblocks.items.len -= 1;
        } else {
            sb.* = .{ .bytes = bytes[0..0], .kind = .tombstone };
            sb.free_slot_next = self.free_superblock_slots;
            self.free_superblock_slots = slot;
        }
        self.backing.free(bytes);
    }

    /// TGC S2-f (2). A medium superblock whose 512 page bits are all clear is
    /// 2 MiB of committed address space serving nothing: before this, the only
    /// release path in the heap was `releaseFreeBlockPages`, which walks the
    /// CLASSED free-block lists, so an empty medium superblock simply sat in
    /// bucket `max_medium_pages` forever and `committed_bytes` never fell.
    /// pdfjs's short-lived >128-byte string bodies made that a monotonic
    /// hundreds-of-megabytes ratchet.
    ///
    /// One empty superblock is kept as a spare so a workload oscillating
    /// around a single superblock's worth of medium extents does not
    /// mmap/munmap once per collection.
    pub const medium_spare_superblocks: usize = 1;

    /// Idle age a wholly-empty medium superblock must reach before its 2 MiB
    /// mapping is returned. Separate from `decommit_min_idle_ns` because the
    /// two releases are not the same operation: a classed block decommit is
    /// `madvise(DONTNEED)` on a mapping that stays, while this is a real
    /// `munmap` whose undo is a fresh `mmap` plus first-touch faults on every
    /// page. Measured on pdfjs.fixed (ReleaseFast, CPU19): ungated the release
    /// returned 1711 superblocks / 3.59 GB, took `block committed` from 75.7 MB
    /// to 49.1 MB and wall from 5.84 s to 30.82 s.
    /// Held at the classed constant: `munmap` is strictly more expensive to
    /// undo than `madvise`, so its idle bar must not be LOWER than the block
    /// one. A 100 ms probe (== `decommit_period_ns`, i.e. "empty across two
    /// consecutive scans") returned 3 superblocks / 6 MB of pdfjs's 75.7 MB at
    /// no measurable wall cost -- noise, not slack. pdfjs's medium superblocks
    /// are a steady-state working set, which is precisely what the ungated
    /// 30.82 s run proves: it was re-mapping what it had just released.
    pub const medium_release_min_idle_ns: u64 = decommit_min_idle_ns;

    fn whollyEmpty(sb: *const Superblock) bool {
        for (sb.page_bits) |word| {
            if (word != 0) return false;
        }
        return true;
    }

    pub fn releaseEmptyMediumSuperblocks(self: *Heap, now_ns: u64) usize {
        var released: usize = 0;
        var spared: usize = 0;
        var slot: u32 = 0;
        while (slot < self.superblocks.items.len) : (slot += 1) {
            {
                const sb = &self.superblocks.items[slot];
                if (sb.kind != .medium) continue;
                // `max_free_run` is only a cheap pre-filter: it is clamped to
                // `max_medium_pages` (16 of 512 pages), so a superblock with
                // one live extent at page 400 also reports 16. The bitmap is
                // the authority for "wholly empty".
                if (sb.max_free_run != max_medium_pages) continue;
                if (!whollyEmpty(sb)) continue;
                if (now_ns -| sb.empty_since_ns < medium_release_min_idle_ns) continue;
                if (spared < medium_spare_superblocks) {
                    spared += 1;
                    continue;
                }
            }
            self.bucketUnlink(slot);
            self.superblocks.items[slot].max_free_run = 0;
            self.unreserveSuperblock(slot);
            released += superblock_bytes;
            self.stats.medium_superblocks_released += 1;
            self.stats.medium_superblock_bytes_released += superblock_bytes;
        }
        return released;
    }

    fn resetBlock(
        self: *Heap,
        block: *Block,
        class_idx: usize,
        cell_size: u32,
        super_index: u32,
        reused: bool,
    ) std.mem.Allocator.Error!void {
        // Reinitialising a linked block overwrites the intrusive successor and
        // strands the rest of the young/doomed chain. This is the exact
        // resetBlock leak incident; fail at the destructive write, not at the
        // next collection that notices the missing tail. Comptime-erased from
        // ReleaseFast.
        if (comptime std.debug.runtime_safety) {
            if (reused) {
                std.debug.assert(!block.isYoungListed());
                std.debug.assert(block.doomed_link == 0);
            }
        }
        const geometry = blockGeometry(cell_size);
        std.debug.assert(geometry.cell_count >= space.min_cells_per_block);
        std.debug.assert(geometry.bitmap_words <= max_bitmap_words);
        const sb = &self.superblocks.items[super_index];
        const block_index = (@intFromPtr(block) - @intFromPtr(sb.bytes.ptr)) / block_bytes;
        if (comptime block_generation_enabled) {
            std.debug.assert(sb.cell_generations[block_index].len == geometry.cell_count);
        }
        if (comptime lifecycle_state_enabled) {
            std.debug.assert(sb.cell_lifecycles[block_index].len == geometry.cell_count);
            for (sb.cell_lifecycles[block_index]) |lifecycle| std.debug.assert(lifecycle.state == .free);
        }
        block.* = .{
            .magic = block_magic,
            .mark_epoch = self.mark_epoch,
            .cell_size = cell_size,
            .cell_count = geometry.cell_count,
            .allocated_count = 0,
            .bump = 0,
            .free_list = free_nil,
            .size_class = @intCast(class_idx),
            .sweep_state = .fresh,
            .flags = 0,
            .cells_offset = geometry.cells_off,
            .alloc_bits_off = geometry.alloc_off,
            .mark_bits_off = geometry.mark_off,
            .remember_bits_off = geometry.remember_off,
            .bitmap_words = geometry.bitmap_words,
            .super_index = super_index,
            .next_free = 0,
        };
        const bits = block.bitmaps();
        @memset(bits.alloc, 0);
        @memset(bits.mark, 0);
        @memset(bits.remember, 0);
        @memset(block.finalizerBits(), 0);
        std.debug.assert(block.remember_bits_off + block.bitmap_words * 8 == geometry.finalizer_off);
    }

    fn allocMedium(self: *Heap, n: usize) std.mem.Allocator.Error![]u8 {
        const pages: u32 = @intCast((n + page_bytes - 1) / page_bytes);
        std.debug.assert(pages >= 1 and pages <= max_medium_pages);
        // Every failure below must leave the page bitmap, the bucket index and
        // the extent table agreeing, so reserve both side tables BEFORE the
        // first bit is set. A half-applied medium allocation would otherwise
        // burn a page run that nothing can ever free.
        try self.medium.ensureUnusedCapacity(self.backing, 1);
        try self.young_extents.ensureUnusedCapacity(self.backing, 1);
        const super_index = self.takeMediumSuperblock(pages) orelse blk: {
            const fresh = try self.reserveSuperblock(.medium);
            self.bucketLink(fresh, max_medium_pages);
            break :blk fresh;
        };
        const page = blk: {
            const sb = &self.superblocks.items[super_index];
            // The bucket promised a run of at least `pages`; the scan only has
            // to say WHERE, and it is bounded by the eight bitmap words.
            break :blk scanFreeRuns(&sb.page_bits, pages).first.?;
        };
        const ptr = blk: {
            const sb = &self.superblocks.items[super_index];
            var p: u32 = 0;
            while (p < pages) : (p += 1) setPage(&sb.page_bits, page + p);
            break :blk sb.bytes.ptr + page * page_bytes;
        };
        self.rebucket(super_index);
        self.medium.putAssumeCapacity(@intFromPtr(ptr), .{
            .super_index = super_index,
            .page = page,
            .pages = pages,
            .user_bytes = n,
        });
        self.indexExtentPages(@intFromPtr(ptr), @as(usize, pages) * page_bytes, n);
        self.young_extents.appendAssumeCapacity(@intFromPtr(ptr));
        self.stats.live_bytes += n;
        self.stats.live_count += 1;
        self.stats.medium_allocs += 1;
        return ptr[0..n];
    }

    /// First medium superblock whose longest free run can serve `pages`, or
    /// null when one has to be reserved. At most `max_medium_pages` array
    /// probes and exactly one superblock touched -- the whole point of the
    /// bucket index.
    fn takeMediumSuperblock(self: *Heap, pages: u32) ?u32 {
        var bucket: usize = pages;
        while (bucket < medium_bucket_count) : (bucket += 1) {
            const head = self.medium_buckets[bucket];
            if (head == bucket_nil) continue;
            if (comptime builtin.is_test) medium_superblock_visits_for_test += 1;
            return head;
        }
        return null;
    }

    fn freeMedium(self: *Heap, extent: MediumExtent) void {
        {
            const sb = &self.superblocks.items[extent.super_index];
            var p: u32 = 0;
            while (p < extent.pages) : (p += 1) clearPage(&sb.page_bits, extent.page + p);
        }
        // A wholly empty medium superblock lands in bucket `max_medium_pages`
        // and is reused from there. Returning its mapping is the decommit
        // policy's business (`releaseEmptyMediumSuperblocks`, driven from
        // `releaseFreeBlockPages`); the allocator only stamps when the
        // superblock became idle, exactly as the classed free path does.
        self.rebucket(extent.super_index);
        {
            const sb = &self.superblocks.items[extent.super_index];
            if (sb.max_free_run == max_medium_pages and whollyEmpty(sb)) {
                sb.empty_since_ns = self.clock_ns;
            }
        }
        self.stats.live_bytes -= extent.user_bytes;
        self.stats.live_count -= 1;
    }

    /// Re-derive `max_free_run` from the bitmap and move the superblock to the
    /// matching bucket. The bitmap is the single source of truth; the field is
    /// a cache of it, and `verifyMediumBuckets` proves the two agree.
    fn rebucket(self: *Heap, super_index: u32) void {
        const run = scanFreeRuns(&self.superblocks.items[super_index].page_bits, 0).max_run;
        if (self.superblocks.items[super_index].max_free_run == run) return;
        self.bucketUnlink(super_index);
        self.bucketLink(super_index, run);
    }

    fn bucketUnlink(self: *Heap, super_index: u32) void {
        const sb = &self.superblocks.items[super_index];
        const bucket: usize = sb.max_free_run;
        if (bucket == 0) {
            std.debug.assert(sb.bucket_prev == bucket_nil and sb.bucket_next == bucket_nil);
            return;
        }
        const prev = sb.bucket_prev;
        const next = sb.bucket_next;
        sb.bucket_prev = bucket_nil;
        sb.bucket_next = bucket_nil;
        if (prev == bucket_nil) {
            std.debug.assert(self.medium_buckets[bucket] == super_index);
            self.medium_buckets[bucket] = next;
        } else {
            self.superblocks.items[prev].bucket_next = next;
        }
        if (next != bucket_nil) self.superblocks.items[next].bucket_prev = prev;
    }

    fn bucketLink(self: *Heap, super_index: u32, run: u32) void {
        std.debug.assert(run <= max_medium_pages);
        {
            const sb = &self.superblocks.items[super_index];
            std.debug.assert(sb.kind == .medium);
            std.debug.assert(sb.bucket_prev == bucket_nil and sb.bucket_next == bucket_nil);
            sb.max_free_run = @intCast(run);
            if (run == 0) return;
            sb.bucket_next = self.medium_buckets[run];
        }
        const head = self.medium_buckets[run];
        if (head != bucket_nil) self.superblocks.items[head].bucket_prev = super_index;
        self.medium_buckets[run] = super_index;
    }

    pub const MediumBucketError = error{
        MediumBucketStale,
        MediumBucketMislinked,
        MediumBucketUnlinked,
    };

    /// Prove `Superblock.max_free_run` against the page bitmap it caches and
    /// the bucket list it names. A stale run either hides free space forever
    /// (allocation reserves superblocks it does not need) or hands out a run
    /// that is not free -- the second is a double-allocation of live string
    /// bytes, so counts alone are not enough and both directions are checked.
    pub fn verifyMediumBuckets(self: *const Heap) MediumBucketError!void {
        if (self.medium_buckets[0] != bucket_nil) return error.MediumBucketMislinked;
        var expected_linked: usize = 0;
        for (self.superblocks.items) |*sb| {
            if (sb.kind != .medium) {
                // Classed AND tombstoned slots: both must be out of every
                // bucket. `releaseEmptyMediumSuperblocks` unlinks before it
                // tombstones, so a tombstone still in a bucket is a bug here,
                // not an exemption.
                if (sb.max_free_run != 0 or sb.bucket_prev != bucket_nil or sb.bucket_next != bucket_nil) {
                    return error.MediumBucketMislinked;
                }
                continue;
            }
            if (scanFreeRuns(&sb.page_bits, 0).max_run != sb.max_free_run) return error.MediumBucketStale;
            if (sb.max_free_run != 0) expected_linked += 1;
        }
        var linked: usize = 0;
        for (self.medium_buckets, 0..) |head, bucket| {
            var prev = bucket_nil;
            var cursor = head;
            while (cursor != bucket_nil) {
                if (cursor >= self.superblocks.items.len) return error.MediumBucketMislinked;
                const sb = &self.superblocks.items[cursor];
                if (sb.kind != .medium) return error.MediumBucketMislinked;
                if (@as(usize, sb.max_free_run) != bucket) return error.MediumBucketMislinked;
                if (sb.bucket_prev != prev) return error.MediumBucketMislinked;
                linked += 1;
                if (linked > self.superblocks.items.len) return error.MediumBucketMislinked;
                prev = cursor;
                cursor = sb.bucket_next;
            }
        }
        if (linked != expected_linked) return error.MediumBucketUnlinked;
    }

    fn allocLarge(self: *Heap, n: usize) std.mem.Allocator.Error![]u8 {
        const aligned = std.mem.alignForward(usize, n, page_bytes);
        self.stats.large_reserves += 1;
        try self.young_extents.ensureUnusedCapacity(self.backing, 1);
        const bytes = try self.backing.alignedAlloc(u8, .fromByteUnits(page_bytes), aligned);
        errdefer self.backing.free(bytes);
        try self.large.put(self.backing, @intFromPtr(bytes.ptr), .{ .bytes = bytes, .user_bytes = n });
        self.indexExtentPages(@intFromPtr(bytes.ptr), bytes.len, n);
        self.young_extents.appendAssumeCapacity(@intFromPtr(bytes.ptr));
        self.stats.live_bytes += bytes.len;
        self.stats.live_count += 1;
        self.stats.committed_bytes += bytes.len;
        self.stats.large_maps += 1;
        self.stats.large_allocs += 1;
        return bytes.ptr[0..n];
    }
};

extern "c" fn malloc_trim(pad: usize) c_int;

test "string extents: a shared page boundary resolves to both neighbours" {
    var heap = Heap.init(std.testing.allocator);
    defer heap.deinit();

    // `first` fills its last page exactly, so its inclusive one-past-end IS
    // `second`'s base -- the one address two extents both answer for.
    const first = try heap.alloc(page_bytes * 2);
    const second = try heap.alloc(page_bytes - 8);
    const first_base = @intFromPtr(first.ptr);
    const second_base = @intFromPtr(second.ptr);
    try std.testing.expectEqual(first_base + page_bytes * 2, second_base);

    const shared = heap.extentsContaining(second_base);
    try std.testing.expectEqual(@as(?usize, second_base), shared.inside);
    try std.testing.expectEqual(@as(?usize, first_base), shared.one_past_end);
    // The linear fallback must give the same two answers, not one of them.
    const shared_linear = heap.extentsContainingLinear(second_base);
    try std.testing.expectEqual(@as(?usize, second_base), shared_linear.inside);
    try std.testing.expectEqual(@as(?usize, first_base), shared_linear.one_past_end);

    // An interior address still has exactly one owner ...
    const interior = heap.extentsContaining(first_base + 8);
    try std.testing.expectEqual(@as(?usize, first_base), interior.inside);
    try std.testing.expectEqual(@as(?usize, null), interior.one_past_end);
    // ... and a one-past-end with no neighbour still resolves, alone.
    const tail = heap.extentsContaining(second_base + page_bytes - 8);
    try std.testing.expectEqual(@as(?usize, second_base), tail.inside);
    try std.testing.expectEqual(@as(?usize, null), tail.one_past_end);

    heap.free(first.ptr);
    heap.free(second.ptr);
}

test "medium free-run scan reports the longest run and the first fit" {
    var bits: [pages_per_superblock / 64]u64 = @splat(0);
    // Pages 0-2 free, 3-9 used, 10-20 free, 21 used, then free to the end.
    var page: u32 = 3;
    while (page < 10) : (page += 1) setPage(&bits, page);
    setPage(&bits, 21);

    // want = 0 answers only the bucket question, and clamps.
    try std.testing.expectEqual(@as(u32, max_medium_pages), scanFreeRuns(&bits, 0).max_run);
    try std.testing.expectEqual(@as(?u32, null), scanFreeRuns(&bits, 0).first);

    // A request the first hole serves lands in the first hole.
    try std.testing.expectEqual(@as(?u32, 0), scanFreeRuns(&bits, 3).first);
    // One page more and the three-page hole is skipped.
    try std.testing.expectEqual(@as(?u32, 10), scanFreeRuns(&bits, 4).first);
    // Longer than the eleven-page hole: the open tail.
    try std.testing.expectEqual(@as(?u32, 22), scanFreeRuns(&bits, 12).first);

    // Runs that cross a word boundary are one run.
    var packed_bits: [pages_per_superblock / 64]u64 = @splat(~@as(u64, 0));
    page = 60;
    while (page < 70) : (page += 1) clearPage(&packed_bits, page);
    try std.testing.expectEqual(@as(u32, 10), scanFreeRuns(&packed_bits, 0).max_run);
    try std.testing.expectEqual(@as(?u32, 60), scanFreeRuns(&packed_bits, 10).first);
    try std.testing.expectEqual(@as(?u32, null), scanFreeRuns(&packed_bits, 11).first);

    // A wholly used superblock is bucket 0 and serves nothing.
    const full: [pages_per_superblock / 64]u64 = @splat(~@as(u64, 0));
    try std.testing.expectEqual(@as(u32, 0), scanFreeRuns(&full, 0).max_run);
    try std.testing.expectEqual(@as(?u32, null), scanFreeRuns(&full, 1).first);
}

test "medium extents: free-run buckets track the page bitmap" {
    var heap = Heap.init(std.testing.allocator);
    defer heap.deinit();

    const run_bytes = page_bytes * max_medium_pages - 8;
    const runs_per_superblock = pages_per_superblock / max_medium_pages;

    // FULL: 32 sixteen-page runs fill one 2 MiB superblock exactly. Its
    // longest free run is 0, so it leaves the index entirely.
    var filled: [runs_per_superblock]usize = undefined;
    for (&filled) |*slot| slot.* = @intFromPtr((try heap.alloc(run_bytes)).ptr);
    try std.testing.expectEqual(@as(usize, 1), heap.stats.superblocks);
    try std.testing.expectEqual(@as(u8, 0), heap.superblocks.items[0].max_free_run);
    for (heap.medium_buckets) |head| try std.testing.expectEqual(bucket_nil, head);
    try heap.verifyMediumBuckets();

    // A full heap reserves instead of scanning, and the newcomer enters the
    // top bucket.
    const fresh = try heap.alloc(page_bytes - 8);
    try std.testing.expectEqual(@as(usize, 2), heap.stats.superblocks);
    try std.testing.expectEqual(@intFromPtr(heap.superblocks.items[1].bytes.ptr), @intFromPtr(fresh.ptr));
    try std.testing.expectEqual(@as(u8, max_medium_pages), heap.superblocks.items[1].max_free_run);
    try heap.verifyMediumBuckets();

    // HALF FULL: free every other run in superblock 0. Its longest run is a
    // whole hole again, so it re-enters the top bucket -- at the head, which
    // is what makes the reuse below deterministic.
    var i: usize = 0;
    while (i < filled.len) : (i += 2) heap.free(@ptrFromInt(filled[i]));
    try std.testing.expectEqual(@as(u8, max_medium_pages), heap.superblocks.items[0].max_free_run);
    try std.testing.expectEqual(@as(u32, 0), heap.medium_buckets[max_medium_pages]);
    try heap.verifyMediumBuckets();

    // The first hole serves the next full-size request; no superblock is
    // reserved for it.
    const reused = try heap.alloc(run_bytes);
    try std.testing.expectEqual(filled[0], @intFromPtr(reused.ptr));
    try std.testing.expectEqual(@as(usize, 2), heap.stats.superblocks);

    // FRAGMENTED: take five pages out of the next hole, leaving eleven.
    const five = try heap.alloc(page_bytes * 5 - 8);
    try std.testing.expectEqual(filled[2], @intFromPtr(five.ptr));
    // A twelve-page request cannot use that eleven-page remainder, so it
    // skips to the next whole hole instead of failing or reserving.
    const twelve = try heap.alloc(page_bytes * 12 - 8);
    try std.testing.expectEqual(filled[4], @intFromPtr(twelve.ptr));
    try std.testing.expectEqual(@as(usize, 2), heap.stats.superblocks);
    try heap.verifyMediumBuckets();

    // The bucket is a cache of the bitmap, and the verifier says so.
    heap.superblocks.items[0].max_free_run = 3;
    try std.testing.expectError(error.MediumBucketStale, heap.verifyMediumBuckets());
    heap.superblocks.items[0].max_free_run = max_medium_pages;
    try heap.verifyMediumBuckets();
}

test "medium allocation does not scan the superblock list" {
    var heap = Heap.init(std.testing.allocator);
    defer heap.deinit();

    const count: usize = 10_000;
    medium_superblock_visits_for_test = 0;
    var i: usize = 0;
    while (i < count) : (i += 1) _ = try heap.alloc(page_bytes - 8);

    // Enough superblocks that a first-fit walk would be quadratic ...
    try std.testing.expect(heap.stats.superblocks >= 15);
    // ... and at most one superblock examined per allocation regardless.
    try std.testing.expect(medium_superblock_visits_for_test <= count);
    try heap.verifyMediumBuckets();
}

test "string extents: table-held marks, containment probe, epoch sweep" {
    var heap = Heap.init(std.testing.allocator);
    defer heap.deinit();
    heap.beginMajor(); // epoch 2: extents born at 0 read unmarked

    const medium = try heap.alloc(4096);
    const large = try heap.alloc(space.large_min_bytes + 1);
    const medium_base = @intFromPtr(medium.ptr);
    const large_base = @intFromPtr(large.ptr);
    try std.testing.expect(!heap.extentIsMarked(medium_base, heap.mark_epoch));
    try std.testing.expect(!heap.extentIsMarked(large_base, heap.mark_epoch));

    // Containment: base, interior, one-past-end; nothing past that.
    try std.testing.expectEqual(medium_base, heap.extentContaining(medium_base).?);
    try std.testing.expectEqual(medium_base, heap.extentContaining(medium_base + 100).?);
    try std.testing.expectEqual(medium_base, heap.extentContaining(medium_base + 4096).?);
    try std.testing.expectEqual(@as(?usize, null), heap.extentContaining(medium_base + 4097));
    try std.testing.expectEqual(large_base, heap.extentContaining(large_base + space.large_min_bytes).?);

    heap.extentSetMark(medium_base, heap.mark_epoch);
    try std.testing.expect(heap.extentIsMarked(medium_base, heap.mark_epoch));
    try std.testing.expect(!heap.extentIsMarked(medium_base, heap.mark_epoch + 2));

    const Ctx = struct {
        heap: *Heap,
        freed: usize = 0,
        last_base: usize = 0,
        last_bytes: usize = 0,
        last_needs_finalizer: bool = false,
        fn destroy(ctx: *anyopaque, base: usize, user_bytes: usize, needs_finalizer: bool) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.freed += 1;
            self.last_base = base;
            self.last_bytes = user_bytes;
            self.last_needs_finalizer = needs_finalizer;
            self.heap.free(@ptrFromInt(base));
        }
    };
    var ctx = Ctx{ .heap = &heap };
    try std.testing.expectEqual(@as(usize, 1), heap.sweepExtents(heap.mark_epoch, @ptrCast(&ctx), Ctx.destroy));
    try std.testing.expectEqual(large_base, ctx.last_base);
    try std.testing.expectEqual(space.large_min_bytes + 1, ctx.last_bytes);
    try std.testing.expectEqual(@as(usize, 0), heap.large.count());
    try std.testing.expectEqual(@as(usize, 1), heap.medium.count());

    // Next major: last cycle's mark is stale, and several removals from
    // under one iteration must all land (in-place tombstones).
    heap.beginMajor();
    try std.testing.expect(!heap.extentIsMarked(medium_base, heap.mark_epoch));
    var extra: [3]usize = undefined;
    for (&extra) |*slot| slot.* = @intFromPtr((try heap.alloc(page_bytes * 2)).ptr);
    heap.extentSetMark(extra[1], heap.mark_epoch);
    try std.testing.expectEqual(@as(usize, 3), heap.sweepExtents(heap.mark_epoch, @ptrCast(&ctx), Ctx.destroy));
    try std.testing.expectEqual(@as(usize, 1), heap.medium.count());
    try std.testing.expect(heap.medium.contains(extra[1]));
    try std.testing.expectEqual(@as(usize, 0), heap.sweepExtents(heap.mark_epoch, @ptrCast(&ctx), Ctx.destroy));
    try std.testing.expectEqual(@as(usize, 4), ctx.freed);
}

test "string extents: page index resolves containment in O(1)" {
    var heap = Heap.init(std.testing.allocator);
    defer heap.deinit();

    // Two adjacent medium runs plus a large mapping, so every boundary the
    // conservative scanner can present is covered.
    const first = try heap.alloc(page_bytes);
    const second = try heap.alloc(page_bytes * 2 - 8);
    const large = try heap.alloc(space.large_min_bytes + 1);
    const first_base = @intFromPtr(first.ptr);
    const second_base = @intFromPtr(second.ptr);
    const large_base = @intFromPtr(large.ptr);
    try heap.verifyExtentPageIndex();
    try std.testing.expectEqual(@as(usize, 0), heap.extent_pages_unindexed);
    // 1 + 2 medium pages + the large mapping's pages.
    try std.testing.expectEqual(
        @as(usize, 3) + (std.mem.alignForward(usize, space.large_min_bytes + 1, page_bytes) >> page_shift),
        heap.extent_pages.count(),
    );

    // Base / interior / one-past-end / one byte past that.
    try std.testing.expectEqual(first_base, heap.extentContaining(first_base).?);
    try std.testing.expectEqual(first_base, heap.extentContaining(first_base + 1).?);
    try std.testing.expectEqual(first_base, heap.extentContaining(first_base + page_bytes - 1).?);
    try std.testing.expectEqual(second_base, heap.extentContaining(second_base).?);
    try std.testing.expectEqual(second_base, heap.extentContaining(second_base + page_bytes * 2 - 8).?);
    try std.testing.expectEqual(@as(?usize, null), heap.extentContaining(second_base + page_bytes * 2 - 7));
    try std.testing.expectEqual(large_base, heap.extentContaining(large_base).?);
    try std.testing.expectEqual(large_base, heap.extentContaining(large_base + space.large_min_bytes).?);
    try std.testing.expectEqual(large_base, heap.extentContaining(large_base + space.large_min_bytes + 1).?);
    try std.testing.expectEqual(@as(?usize, null), heap.extentContaining(large_base + space.large_min_bytes + 2));

    // Adjacent extents: the run allocator hands out consecutive pages, so
    // `first`'s one-past-end is `second`'s base. Single-winner resolution
    // gives the address to the extent that CONTAINS it (the neighbour's
    // one-past-end loses); the answer is deterministic either way, which the
    // hash-order-dependent linear walk this replaces was not.
    if (second_base == first_base + page_bytes) {
        try std.testing.expectEqual(second_base, heap.extentContaining(second_base).?);
    }
    // A page-aligned address one past a run that does NOT abut another
    // extent still resolves through the `addr - 1` probe.
    const tail_gap = try heap.alloc(page_bytes * 3);
    const tail_base = @intFromPtr(tail_gap.ptr);
    try std.testing.expectEqual(tail_base, heap.extentContaining(tail_base + page_bytes * 3).?);
    try std.testing.expectEqual(@as(?usize, null), heap.extentContaining(tail_base + page_bytes * 3 + 1));

    // Addresses outside every extent (a fresh classed cell) miss.
    const cell = (try heap.allocCell(64)).?;
    try std.testing.expectEqual(@as(?usize, null), heap.extentContaining(@intFromPtr(cell)));
    heap.freeSmallCell(cell);

    // Freed extents stop resolving and give their pages back.
    heap.free(large.ptr);
    try std.testing.expectEqual(@as(?usize, null), heap.extentContaining(large_base));
    try std.testing.expectEqual(@as(?usize, null), heap.extentContaining(large_base + 16));
    try heap.verifyExtentPageIndex();
    heap.free(first.ptr);
    try std.testing.expectEqual(@as(?usize, null), heap.extentContaining(first_base));
    // ... without disturbing its neighbour.
    try std.testing.expectEqual(second_base, heap.extentContaining(second_base + 8).?);
    try heap.verifyExtentPageIndex();

    heap.free(second.ptr);
    heap.free(tail_gap.ptr);
    try heap.verifyExtentPageIndex();
    try std.testing.expectEqual(@as(usize, 0), heap.extent_pages.count());
    try std.testing.expectEqual(@as(?usize, null), heap.extentContaining(second_base));
}

test "string extents: a failed page fan-out falls back to the exact linear probe" {
    var heap = Heap.init(std.testing.allocator);
    defer heap.deinit();

    // Deliberately NOT page-filling: the linear fallback is single-winner and
    // an extent whose one-past-end is the next extent's base makes its answer
    // depend on hash order (see `extentContaining`'s adjacency note).
    const indexed = try heap.alloc(page_bytes - 8);
    const indexed_base = @intFromPtr(indexed.ptr);

    // One page enters, the second insert "fails": the partial fan-out is
    // rolled back (a page-shaped hole in the index would be a dropped root)
    // and the probe reverts to the exact linear walk.
    extent_page_index_fail_after_for_test = 1;
    const unindexed = try heap.alloc(page_bytes * 2);
    extent_page_index_fail_after_for_test = null;
    const unindexed_base = @intFromPtr(unindexed.ptr);
    try std.testing.expectEqual(@as(usize, 1), heap.extent_pages_unindexed);
    try std.testing.expectEqual(@as(usize, 1), heap.extent_pages.count());
    try heap.verifyExtentPageIndex();

    try std.testing.expectEqual(unindexed_base, heap.extentContaining(unindexed_base).?);
    try std.testing.expectEqual(unindexed_base, heap.extentContaining(unindexed_base + 7).?);
    try std.testing.expectEqual(unindexed_base, heap.extentContaining(unindexed_base + page_bytes * 2).?);
    try std.testing.expectEqual(@as(?usize, null), heap.extentContaining(unindexed_base + page_bytes * 2 + 1));
    try std.testing.expectEqual(indexed_base, heap.extentContaining(indexed_base + 7).?);

    // Its death returns the heap to the O(1) path.
    heap.free(unindexed.ptr);
    try std.testing.expectEqual(@as(usize, 0), heap.extent_pages_unindexed);
    try heap.verifyExtentPageIndex();
    try std.testing.expectEqual(@as(?usize, null), heap.extentContaining(unindexed_base + 7));
    try std.testing.expectEqual(indexed_base, heap.extentContaining(indexed_base).?);
    heap.free(indexed.ptr);
    try heap.verifyExtentPageIndex();
}

test "block-cell generation packs incarnation and non-wrapping reuse sequence" {
    var heap = Heap.init(std.testing.allocator);
    defer heap.deinit();

    const first = (try heap.allocCell(80)).?;
    const first_base = @intFromPtr(first) + gc_representation.metadata_size;
    const first_handle = heap.generationHandle(first_base, gc_representation.metadata_size).?;
    try std.testing.expect(first_handle.generation >> 32 != 0);
    try std.testing.expect(@as(u32, @truncate(first_handle.generation)) != 0);
    heap.freeSmallCell(first);

    const block = Block.fromCellTrusted(@intFromPtr(first));
    const first_index = block.cellIndex(@intFromPtr(first)).?;
    heap.generationFor(block, first_index).* = std.math.maxInt(u32);
    // The exhausted cell is sealed and skipped, not wrapped or surfaced as a
    // false heap-wide OOM while another cell in the block remains usable.
    const next = (try heap.allocCell(80)).?;
    defer heap.freeSmallCell(next);
    try std.testing.expect(next != first);
    try std.testing.expectEqual(carrier.LifecycleState.free, heap.lifecycleFor(block, first_index).state);
    const next_handle = heap.generationHandle(
        @intFromPtr(next) + gc_representation.metadata_size,
        gc_representation.metadata_size,
    ).?;
    try std.testing.expectEqual(first_handle.generation >> 32, next_handle.generation >> 32);
}

pub fn processHeapTrimNeeded(current_decommitted: usize, released: usize) bool {
    return released != 0 and
        current_decommitted >= Heap.process_trim_min_decommitted_bytes and
        current_decommitted -| released < Heap.process_trim_min_decommitted_bytes;
}

fn popCell(block: *Block) ?u32 {
    if (block.flags & Block.flag_interval_allocator != 0) {
        if (block.bump < block.interval_end) {
            const index = block.bump;
            block.bump += 1;
            return index;
        }
        const interval = block.free_list;
        if (interval != free_nil) {
            std.debug.assert(interval < block.cell_count);
            if (interval < block.cell_count) {
                const cell = block.cellPtr(interval);
                const raw = @as(*const u32, @ptrCast(@alignCast(cell))).*;
                const end = @as(*const u32, @ptrCast(@alignCast(cell + 4))).*;
                std.debug.assert(raw & ~free_link_mask == free_poison);
                std.debug.assert(interval < end and end <= block.cell_count);
                block.free_list = raw & free_link_mask;
                block.bump = interval + 1;
                block.interval_end = end;
                return interval;
            }
        }
        // Constructor failure can return an already-consumed interval cell.
        // Keep that exceptional LIFO separate in `next_free`, so it cannot
        // splice an unordered singleton into the remaining interval stream.
        const returned: u32 = @intCast(block.next_free);
        if (returned != free_nil) {
            std.debug.assert(returned < block.cell_count);
            if (returned < block.cell_count) {
                const raw = @as(*const u32, @ptrCast(@alignCast(block.cellPtr(returned)))).*;
                std.debug.assert(raw & ~free_link_mask == free_poison);
                block.next_free = raw & free_link_mask;
                return returned;
            }
        }
        return null;
    }
    const head = block.free_list;
    if (head != free_nil) {
        // Strict, not permissive: an out-of-range head is corruption, and
        // reading it as "the list is empty" would silently strand every cell
        // behind it. The safety build stops; the release build falls through
        // to the bump pointer, which leaks rather than crashes.
        std.debug.assert(head < block.cell_count);
        if (head < block.cell_count) {
            const raw = @as(*const u32, @ptrCast(@alignCast(block.cellPtr(head)))).*;
            std.debug.assert(raw & ~free_link_mask == free_poison);
            block.free_list = raw & free_link_mask;
            return head;
        }
    }
    if (block.bump >= block.cell_count) return null;
    const index = block.bump;
    block.bump += 1;
    return index;
}

fn pushCell(block: *Block, index: u32, cell: [*]u8) void {
    // Poison the whole word, not just the tail. Every free cell then reads
    // as unaccounted, cycle-visited and untraced no matter where it sits in
    // the chain, so the "free cell impersonates a live header" class of bug
    // is closed for links as well as for the terminator.
    if (block.flags & Block.flag_interval_allocator != 0) {
        std.debug.assert(block.flags & Block.flag_hot_list == 0);
        const returned: u32 = @intCast(block.next_free);
        @as(*u32, @ptrCast(@alignCast(cell))).* = free_poison | (returned & free_link_mask);
        block.next_free = index;
    } else {
        @as(*u32, @ptrCast(@alignCast(cell))).* = free_poison | (block.free_list & free_link_mask);
        block.free_list = index;
    }
}

fn bitMask(index: u32) u64 {
    return @as(u64, 1) << @intCast(index % 64);
}

/// Atomic bit ops: 64 cells share a word, and a marker worker and the
/// mutator's barrier can shade neighbours concurrently -- plain RMW lost
/// marks the moment the worker existed (caught by its own unit test). The
/// header-bit era was immune only because every object owned its byte.
/// Plain (non-atomic) bitmap helpers, for the ALLOC bitmap only.
///
/// Marking needs atomics because several lanes claim mark bits in the same
/// 64-cell word. The alloc bitmap has no such reader: it is written only by
/// allocation and freeing, both of which are owner-thread work, and read only
/// by condemnation, the object iterator, conservative resolution and the
/// audit -- all owner-thread and all inside a stop-the-world window, where
/// the mutator is not running at all. Marker threads never touch it. Paying
/// a read-modify-write atomic per allocation AND per free bought nothing:
/// on splay that is ~36 M of them, and on aarch64 each is an LSE
/// read-modify-write against the plain load/or/store it replaces.
fn setBitPlain(bits: []u64, index: u32) void {
    bits[index / 64] |= @as(u64, 1) << @intCast(index % 64);
}

fn clearBitPlain(bits: []u64, index: u32) void {
    bits[index / 64] &= ~(@as(u64, 1) << @intCast(index % 64));
}

fn testBitPlain(bits: []const u64, index: u32) bool {
    return (bits[index / 64] & (@as(u64, 1) << @intCast(index % 64))) != 0;
}

fn testBit(bits: []const u64, index: u32) bool {
    const word = @atomicLoad(u64, &bits[index / 64], .monotonic);
    return (word & (@as(u64, 1) << @intCast(index % 64))) != 0;
}

fn setBit(bits: []u64, index: u32) void {
    _ = @atomicRmw(u64, &bits[index / 64], .Or, @as(u64, 1) << @intCast(index % 64), .monotonic);
}

fn clearBit(bits: []u64, index: u32) void {
    _ = @atomicRmw(u64, &bits[index / 64], .And, ~(@as(u64, 1) << @intCast(index % 64)), .monotonic);
}

/// Free-run scan over a medium superblock's page bitmap.
///
/// `max_run` is the longest run of free (zero) pages, clamped to
/// `max_medium_pages` because no medium request can use more. `first` is the
/// lowest page starting a run of at least `want` pages (null when `want` is 0
/// or no such run exists).
///
/// Word-at-a-time: each iteration jumps to the next USED page with `@ctz`, so
/// the cost is bounded by the eight bitmap words plus the number of allocated
/// runs it steps over, never by the 512 pages. This is the whole per-operation
/// cost of the medium allocator -- it does not depend on how many superblocks
/// the heap holds.
const FreeRunScan = struct { max_run: u32, first: ?u32 };

fn scanFreeRuns(bits: *const [pages_per_superblock / 64]u64, want: u32) FreeRunScan {
    var out: FreeRunScan = .{ .max_run = 0, .first = null };
    var run: u32 = 0;
    var word_index: usize = 0;
    while (word_index < bits.len) : (word_index += 1) {
        const word = bits[word_index];
        const word_base: u32 = @intCast(word_index * 64);
        var pos: u32 = 0;
        while (pos < 64) {
            // Free pages ahead of the next used one.
            const free_rest = word >> @as(u6, @intCast(pos));
            if (free_rest == 0) {
                run += 64 - pos;
                break;
            }
            const zeros: u32 = @ctz(free_rest);
            run += zeros;
            pos += zeros;
            // `word_base + pos` is one past the run that just ended.
            if (run > out.max_run) out.max_run = run;
            if (out.first == null and want != 0 and run >= want) out.first = word_base + pos - run;
            run = 0;
            // Skip the used run in one step too, so an iteration costs one
            // RUN, not one page.
            const used_rest = ~(word >> @as(u6, @intCast(pos)));
            pos += if (used_rest == 0) 64 - pos else @ctz(used_rest);
        }
        if (run > out.max_run) out.max_run = run;
        if (out.first == null and want != 0 and run >= want) out.first = word_base + 64 - run;
        if (out.max_run >= max_medium_pages and (want == 0 or out.first != null)) break;
    }
    if (out.max_run > max_medium_pages) out.max_run = max_medium_pages;
    return out;
}

fn testPage(bits: [pages_per_superblock / 64]u64, page: u32) bool {
    return bits[page / 64] & (@as(u64, 1) << @intCast(page % 64)) != 0;
}

fn setPage(bits: *[pages_per_superblock / 64]u64, page: u32) void {
    bits[page / 64] |= @as(u64, 1) << @intCast(page % 64);
}

fn clearPage(bits: *[pages_per_superblock / 64]u64, page: u32) void {
    bits[page / 64] &= ~(@as(u64, 1) << @intCast(page % 64));
}

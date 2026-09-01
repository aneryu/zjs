//! 64 KiB block heap (tracing-gc-design.md §4.2 / §4.3 / §8.1).
//!
//! Superblocks are 2 MiB mappings split into 64 KiB-aligned blocks. A block
//! holds one size class. Empty blocks return to the runtime free list; the
//! mapping is released only as a whole superblock. One over-sized mapping
//! plus per-block `munmap` is forbidden.
//!
//! Compiled only when `-Dzjs_experimental_gc=trace_stw`. Default `rc` keeps the existing
//! allocator. This module does not replace object headers.

const std = @import("std");
const builtin = @import("builtin");

const gc_representation = @import("gc_representation_constants.zig");
const space = @import("gc_space.zig");
const sweep = @import("gc_sweep_model.zig");

pub const enabled = true;

pub const superblock_bytes: usize = 2 * 1024 * 1024;
pub const block_bytes: usize = 64 * 1024;
pub const blocks_per_superblock: usize = superblock_bytes / block_bytes;
pub const page_bytes: usize = 4096;
pub const pages_per_superblock: usize = superblock_bytes / page_bytes;
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
/// reads 0 (the iterators and `shade` refuse it), `cycle_visited` reads 1
/// (`shade` refuses it again), and the kind reads `.big_int`, which is not
/// traced at all.
pub const free_nil: u32 = 0xFFFF;
pub const free_link_mask: u32 = gc_representation.free_cell_link_mask;
pub const free_poison: u32 = gc_representation.free_cell_poison;
/// Match JSC's default 0.9 `minMarkedBlockUtilization`: a completed block is
/// worth reopening when at least one tenth of its cells can form intervals.
pub const hot_reuse_min_free_percent: u32 = 10;
// Policy candidates retained for the pricing sweep; only the selected value
// participates in production until the combined candidate is measured.
pub const hot_reuse_k32: u32 = 32;
pub const hot_reuse_k64: u32 = 64;
pub const hot_reuse_k128: u32 = 128;
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

/// Alignment every cell is guaranteed to satisfy. Blocks and `cells_offset`
/// are 64-byte aligned, while every size class is a multiple of 16, so the
/// cross-class guarantee remains 16 bytes. A 64-byte class is consequently
/// cache-line aligned for every cell, which is the compact Object contract.
pub const cell_alignment: usize = 16;

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
pub const serves_gc_nodes = false;
pub const block_magic: u64 = 0x5a4a53_424c4b_0001;

const max_bitmap_words: usize = (block_bytes / space.min_class_bytes + 63) / 64;

pub const Stats = struct {
    committed_bytes: usize = 0,
    live_bytes: usize = 0,
    superblocks: usize = 0,
    large_maps: usize = 0,
    live_count: usize = 0,
    small_allocs: usize = 0,
    medium_allocs: usize = 0,
    large_allocs: usize = 0,
    superblock_reserves: usize = 0,
    large_reserves: usize = 0,
    failed_reserves: usize = 0,
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
    /// Stage-3: corpses released by `settleDoomedCellInPassA`, i.e. that never
    /// became a parked entry. Together with the Registry's
    /// `doomed_parked_entries_drained` this is the whole population the
    /// two-pass teardown physically released. It lives here rather than in
    /// `gc_concurrent.Stats` on purpose: that struct is instantiated by the
    /// `rc` build too, and stage 3 must not move a single `rc` byte.
    passa_settled_cells: usize = 0,

    pub fn committedLiveMilli(self: Stats) usize {
        if (self.live_bytes == 0) return 0;
        return (self.committed_bytes * 1000 + self.live_bytes - 1) / self.live_bytes;
    }

    pub fn currentDecommittedBytes(self: Stats) usize {
        return self.decommitted_bytes -| self.recommitted_bytes;
    }
};

pub const Cell = struct {
    ptr: [*]u8,
    index: u32,
};

pub fn canAllocCellSize(n: usize) bool {
    if (n == 0 or n >= space.large_min_bytes) return false;
    if (space.classifyPayload(n) != .small) return false;
    return space.classIndexForPayload(n) != null;
}

comptime {
    // These counters live in every tracing Registry. Keep additions explicit:
    // a silent size drift here multiplies across tests and embedded runtimes.
    // 160 -> 168: `passa_settled_cells` (stage-3 Pass-A settlement).
    if (@sizeOf(usize) == 8 and @sizeOf(Stats) != 168) {
        @compileError("gc block-heap Stats size changed; update the footprint pin deliberately");
    }
}

const SuperblockKind = enum { classed, medium };

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
};

const LargeMap = struct {
    bytes: []u8,
};

const MediumExtent = struct {
    super_index: u32,
    page: u32,
    pages: u32,
    user_bytes: usize,
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
    sweep_state: sweep.SweepState = .fresh,
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
    const flag_remembered: u8 = 1 << 1;
    const flag_overflow: u8 = 1 << 2;
    const flag_bailout: u8 = 1 << 3;
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

    pub fn fromAddrChecked(addr: usize) ?*Block {
        return fromAddr(addr);
    }

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

    /// Cell index for a KNOWN cell base (exact, not interior).
    pub inline fn cellIndexTrusted(self: *const Block, cell_addr: usize) u32 {
        return @intCast((cell_addr - (@intFromPtr(self) + self.cells_offset)) / self.cell_size);
    }

    /// Unmark under the epoch scheme: a stale bitmap already reads unmarked
    /// for every cell, so only a current-epoch bit needs clearing.
    pub fn clearMark(self: *Block, index: u32, epoch: u64) void {
        if (@atomicLoad(u64, &self.mark_epoch, .acquire) != epoch) return;
        clearBit(self.bitmaps().mark, index);
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
    /// Returns dead count; bytes are count * cell_size by construction.
    pub fn snapshotDoomed(self: *Block, epoch: u64) u32 {
        const maps = self.bitmaps();
        self.doomed_cursor = 0;
        self.doomed_word = 0;
        var dead: u32 = 0;
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
            dead += @popCount(doomed);
        }
        return dead;
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

    /// Atomically claim the mark bit: returns true iff this caller flipped it
    /// from clear to set. Parallel tracing uses the claim as its dedup -- the
    /// winner alone walks the object's edges, so trace-time write-backs
    /// (accessor sync stores) stay single-writer.
    pub fn tryAcquireMark(self: *Block, index: u32, epoch: u64) bool {
        self.ensureMarkEpoch(epoch);
        const mask = @as(u64, 1) << @intCast(index % 64);
        const old = @atomicRmw(u64, &self.bitmaps().mark[index / 64], .Or, mask, .monotonic);
        return (old & mask) == 0;
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
    var cells_off = std.mem.alignForward(u32, remember_off + bitmap_words * 8, 64);
    while (cells_off + cell_count * cell_size > block_bytes) {
        cell_count -= 1;
        bitmap_words = @intCast((cell_count + 63) / 64);
        mark_off = alloc_off + bitmap_words * 8;
        remember_off = mark_off + bitmap_words * 8;
        cells_off = std.mem.alignForward(u32, remember_off + bitmap_words * 8, 64);
    }
    return .{
        .cell_count = cell_count,
        .bitmap_words = bitmap_words,
        .alloc_off = alloc_off,
        .mark_off = mark_off,
        .remember_off = remember_off,
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
        self.classed_blocks.deinit(self.backing);
        for (self.superblocks.items) |sb| {
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
        if (space.classifyPayload(n) == .medium) return self.allocMedium(n);
        const class_idx = space.classIndexForPayload(n) orelse return self.allocMedium(n);
        return self.allocSmall(class_idx, n);
    }

    /// A small-class cell together with the cell index the allocator already
    /// computed. This allocator stamps that index into the cell prefix so every
    /// `allocCell` result satisfies the contract required by `freeSmallCell`
    /// and the mark accessors need no division; recovering it with
    /// `cellIndexTrusted` afterwards would put an integer division back on
    /// the hottest allocation path in the engine (255 M calls on
    /// earley-boyer, against 60 M marks -- the wrong side of the trade).
    ///
    /// Null means the request is not a small-class cell (medium or large);
    /// the caller must fall back to `alloc`, and must NOT treat the result
    /// as a block cell.
    pub fn allocCell(self: *Heap, n: usize) std.mem.Allocator.Error!?Cell {
        if (n == 0 or n >= space.large_min_bytes) return null;
        if (space.classifyPayload(n) == .medium) return null;
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
        const cell = self.allocSmallCell(class_idx, cell_size) catch return null;
        return cell.ptr;
    }

    inline fn allocSmallCell(self: *Heap, class_idx: usize, cell_size: u32) std.mem.Allocator.Error!Cell {
        var block = self.active[class_idx] orelse blk: {
            const opened = try self.openBlock(class_idx, cell_size);
            self.active[class_idx] = opened;
            break :blk opened;
        };
        const index = popCell(block) orelse blk: {
            self.active[class_idx] = null;
            block = try self.openBlock(class_idx, cell_size);
            self.active[class_idx] = block;
            break :blk popCell(block).?;
        };
        setBitPlain(block.bitmaps().alloc, index);
        if (block.allocated_count == 0) self.noteNonemptyBlock(block);
        block.allocated_count += 1;
        const ptr = block.cellPtr(index);
        std.mem.writeInt(u16, ptr[0..2], @intCast(index), .little);
        return .{ .ptr = ptr, .index = index };
    }

    pub fn free(self: *Heap, ptr: [*]u8) void {
        const addr = @intFromPtr(ptr);
        if (self.large.fetchRemove(addr)) |kv| {
            self.stats.live_bytes -= kv.value.bytes.len;
            self.stats.live_count -= 1;
            self.stats.committed_bytes -= kv.value.bytes.len;
            self.stats.large_maps -= 1;
            self.backing.free(kv.value.bytes);
            return;
        }
        if (self.medium.fetchRemove(addr)) |kv| {
            self.freeMedium(kv.value);
            return;
        }
        const block = Block.fromAddr(addr) orelse return;
        const index = block.cellIndex(addr) orelse return;
        self.freeSmall(block, index, ptr);
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

    /// Stage-3 (`docs/corpse-census-2026-08-29.md` §5.2): may a corpse in this
    /// block be settled during Pass A instead of parked for Pass B?
    ///
    /// Two block-side vetoes, and only two, because the census showed every
    /// other candidate veto (weak husk, weak id, inline payload, non-standard
    /// class) is either zero or handled by the caller's class predicate:
    ///
    /// 1. **allocator-current.** The mutator allocates from this block between
    ///    destruction slices, so its live free representation must keep being
    ///    maintained by the ordinary `freeSmall` path. Settlement deliberately
    ///    writes no free link, which is legal only for a private block.
    /// 2. **the release would empty the block.** The empty-block lifecycle
    ///    (`noteEmptyBlock`, `free_blocks`, aged decommit) must not run while
    ///    the global doomed transaction is open: `openBlock` could hand the
    ///    reset block straight back out while another block's destructor may
    ///    still dereference a resource-stripped sibling. Leaving the last cell
    ///    to Pass B keeps that transition on its proven path, and costs one
    ///    parked entry per emptied block (splay 22, raytrace 28 K).
    pub inline fn canSettleDoomedCellInPassA(self: *const Heap, block: *const Block) bool {
        if (self.active[block.size_class] == block) return false;
        return block.allocated_count > 1;
    }

    /// Physically release a block cell down to the canonical bitmap facts,
    /// with no free-list link and no empty-block transition.
    ///
    /// The cell becomes allocatable only when `rebuildFreeIntervals`
    /// reconstructs this block's intervals from the alloc bitmap, and that
    /// happens exclusively inside `openBlock` for a block the publication gate
    /// already admitted -- i.e. after Pass A completed globally. So the global
    /// two-pass rule is preserved: what stage 3 removes is the second cold
    /// touch of every corpse, not the ordering of destruction against reuse.
    ///
    /// The corpse's bytes are left intact (unlike `pushCell`, which overwrites
    /// the first four), so a not-yet-processed sibling destructor sees exactly
    /// the resource-stripped husk it sees today.
    pub inline fn settleDoomedCellInPassA(self: *Heap, block: *Block, index: u32) void {
        std.debug.assert(block.magic == block_magic);
        std.debug.assert(index < block.cell_count);
        std.debug.assert(self.canSettleDoomedCellInPassA(block));
        // Catches a corpse settled twice, and a corpse settled after Pass B
        // already freed it, at the site rather than at the next whole-heap
        // `AllocCountMismatch`.
        std.debug.assert(testBitPlain(block.bitmaps().alloc, index));
        clearBitPlain(block.bitmaps().alloc, index);
        block.allocated_count -= 1;
        block.flags |= Block.flag_bitmap_canonical;
        self.stats.passa_settled_cells +|= 1;
    }

    /// Per-block form of `verify`'s `AllocCountMismatch`, run when Pass A
    /// finishes a doomed block so a settlement bug names the block that caused
    /// it instead of surfacing at the next whole-heap audit.
    pub fn verifyBlockAllocCount(block: *Block) VerifyError!void {
        var set: u32 = 0;
        for (block.bitmaps().alloc) |word| set += @popCount(word);
        if (set != block.allocated_count) return error.AllocCountMismatch;
    }

    /// Census-only: the block-side facts that decide whether a corpse's
    /// physical release is exactly {clear alloc bit, allocated_count,
    /// MemoryAccount debit}. Never called from a measured build.
    pub fn censusCellFacts(self: *const Heap, block: *Block, index: u32) struct {
        interval_allocator: bool,
        allocator_current: bool,
        becomes_empty: bool,
        cell_size: u32,
    } {
        return .{
            .interval_allocator = block.flags & Block.flag_interval_allocator != 0,
            .allocator_current = self.active[block.size_class] == block,
            .becomes_empty = block.allocated_count == 1 and
                testBitPlain(block.bitmaps().alloc, index),
            .cell_size = block.cell_size,
        };
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
        if (block.allocated_count == 0 or !hasHotReuseCapacity(block)) return;
        if (self.active[block.size_class] == block or block.hasPendingDoomed()) return;
        if (block.flags & (Block.flag_young | Block.flag_hot_list | Block.flag_decommitted) != 0) return;
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

    /// Pass-B consumed one complete, contiguous run of parked Object cells
    /// from `block`. The caller captured the next run's block identity before
    /// freeing the final cell, so no per-entry block side table is needed.
    ///
    /// This minimal handoff preserves the current eager interval preparation;
    /// the joint drain/reuse follow-up moves that work to `openBlock` so the
    /// bitmap walk immediately precedes allocation.
    pub noinline fn onBlockPassBComplete(self: *Heap, block: *Block) void {
        std.debug.assert(!block.hasPendingDoomed());
        self.stats.deferred_block_runs_completed +|= 1;
        self.publishHotBlock(block);
    }

    /// Publish partial blocks only after the collector's global parked-free
    /// Pass B has drained. A block's doomed bitmap becoming empty ends Pass A,
    /// but Object structs (and therefore their alloc bits) deliberately stay
    /// live until every doomed object's resource destructor has run.
    pub fn publishCompletedHotBlocks(self: *Heap, parked_frees: usize) void {
        // This is a production guard, not merely an assertion: the block heap
        // cannot inspect Registry's parked queue itself, and publishing on a
        // caller's premature notification would make later Pass-B frees race
        // allocator ownership of the same block.
        if (parked_frees != 0) return;
        std.debug.assert(self.doomed_blocks == null);
        for (self.superblocks.items) |*sb| {
            if (sb.kind != .classed) continue;
            var nonempty = sb.page_bits[0];
            while (nonempty != 0) {
                const i: usize = @ctz(nonempty);
                nonempty &= nonempty - 1;
                const block: *Block = @ptrFromInt(@intFromPtr(sb.bytes.ptr) + i * block_bytes);
                if (block.flags & Block.flag_hot_list != 0) continue;
                self.publishHotBlock(block);
            }
        }
    }

    /// Condemn every dead cell in the heap by bitmap snapshot. Blocks that
    /// hold any go on the doomed list. Returns total dead cells and bytes.
    pub fn snapshotAllDoomed(self: *Heap, epoch: u64) struct { count: usize, bytes: usize } {
        var count: usize = 0;
        var bytes: usize = 0;
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
                const dead = block.snapshotDoomed(epoch);
                if (dead == 0) {
                    self.publishHotBlock(block);
                    continue;
                }
                // A block selected for interval reuse is unavailable until
                // its final doomed destructor returns. Small-death active
                // blocks keep the existing allocation policy; non-active
                // blocks are private already.
                if (self.active[block.size_class] == block and
                    dead * 100 >= block.cell_count * hot_reuse_min_free_percent)
                {
                    self.active[block.size_class] = null;
                }
                count += dead;
                bytes += @as(usize, dead) * block.cell_size;
                if (block.doomed_link == 0) {
                    block.doomed_link = if (self.doomed_blocks) |head| @intFromPtr(head) else 1;
                    self.doomed_blocks = block;
                }
            }
        }
        return .{ .count = count, .bytes = bytes };
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
        self.trimProcessHeapAfterLargeShrink(released);
        return released;
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
                    if ((maps.alloc[last] | maps.mark[last] | maps.remember[last]) & ~valid != 0) {
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
            /// A detached construction root must have been marked by this
            /// collection before an unpublished cell can be accepted.
            marked_construction,
            /// A resource-stripped corpse remains allocated until deferred
            /// finalizers finish; exact deferred-stack membership is the
            /// authority, not a liveness mark.
            parked_finalizer,
        };

        context: *anyopaque,
        classify: *const fn (context: *anyopaque, cell_addr: usize) Kind,
    };

    pub fn verifyPublishedCells(
        self: *Heap,
        block_cell_marker: u5,
        object_kind: u3,
    ) VerifyError!void {
        return self.verifyPublishedCellsAllowing(block_cell_marker, object_kind, null);
    }

    /// Runtime audit variant. Detached generator shells require exact
    /// construction-root membership plus the current mark. Resource-stripped
    /// objects waiting behind a deferred finalizer require exact parked-stack
    /// membership instead: they are dead, so demanding a liveness mark would
    /// turn the audit itself into a false invariant.
    pub fn verifyPublishedCellsAllowing(
        self: *Heap,
        block_cell_marker: u5,
        object_kind: u3,
        allowance: ?UnpublishedCellAllowance,
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
                    const prefix_valid = !standalone and
                        alloc_info & gc_representation.alloc_info_class_mask == block_cell_marker and
                        flags & 0x7 == object_kind;
                    if (!accounted and prefix_valid) {
                        const allowed = if (allowance) |candidate|
                            candidate.classify(candidate.context, cell)
                        else
                            UnpublishedCellAllowance.Kind.none;
                        switch (allowed) {
                            .none => {},
                            .marked_construction => if (block.isMarked(index, self.mark_epoch)) continue,
                            .parked_finalizer => continue,
                        }
                    }
                    if (!accounted or !prefix_valid) {
                        return error.AllocatedCellUnpublished;
                    }
                    const young = flags & (1 << 4) != 0;
                    if (young and !block.cellPendingDoomed(index) and !block.isYoungListed()) {
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
        var block = self.active[class_idx] orelse try self.openBlock(class_idx, cell_size);
        const index = popCell(block) orelse blk: {
            self.active[class_idx] = null;
            block = try self.openBlock(class_idx, cell_size);
            break :blk popCell(block).?;
        };
        self.active[class_idx] = block;
        setBitPlain(block.bitmaps().alloc, index);
        if (block.allocated_count == 0) self.noteNonemptyBlock(block);
        block.allocated_count += 1;
        return block.cellPtr(index)[0..user_bytes];
    }

    fn freeSmall(self: *Heap, block: *Block, index: u32, cell: [*]u8) void {
        if (!testBitPlain(block.bitmaps().alloc, index)) return;
        clearBitPlain(block.bitmaps().alloc, index);
        pushCell(block, index, cell);
        block.allocated_count -= 1;
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
            self.resetBlock(block, class_idx, cell_size, super_index, true);
            block.sweep_state = .active;
            return block;
        }
        const slot = try self.takeClassedBlock();
        const block: *Block = @ptrCast(@alignCast(slot.ptr));
        self.resetBlock(block, class_idx, cell_size, slot.super_index, false);
        block.sweep_state = .fresh;
        block.sweep_state = .active;
        return block;
    }

    fn takeClassedBlock(self: *Heap) std.mem.Allocator.Error!struct { ptr: [*]u8, super_index: u32 } {
        for (self.superblocks.items, 0..) |*sb, super_index| {
            if (sb.kind != .classed) continue;
            if (sb.used_blocks >= blocks_per_superblock) continue;
            const off = sb.used_blocks * block_bytes;
            const base = @intFromPtr(sb.bytes.ptr + off);
            try self.classed_blocks.put(self.backing, base, {});
            self.classed_block_filter |= base;
            sb.used_blocks += 1;
            return .{ .ptr = sb.bytes.ptr + off, .super_index = @intCast(super_index) };
        }
        const sb = try self.reserveSuperblock(.classed);
        // Make publication of any of this superblock's 32 block bases
        // infallible after the mapping exists. Roll the mapping back if the
        // membership index cannot reserve: an allocation error must not leave
        // a committed-but-unusable superblock behind.
        self.classed_blocks.ensureUnusedCapacity(self.backing, blocks_per_superblock) catch |err| {
            const bytes = sb.bytes;
            std.debug.assert(self.superblocks.items.len != 0);
            std.debug.assert(&self.superblocks.items[self.superblocks.items.len - 1] == sb);
            self.superblocks.items.len -= 1;
            self.backing.free(bytes);
            self.stats.superblocks -= 1;
            self.stats.committed_bytes -= superblock_bytes;
            self.stats.failed_reserves += 1;
            return err;
        };
        const base = @intFromPtr(sb.bytes.ptr);
        self.classed_blocks.putAssumeCapacity(base, {});
        self.classed_block_filter |= base;
        sb.used_blocks = 1;
        return .{ .ptr = sb.bytes.ptr, .super_index = @intCast(self.superblocks.items.len - 1) };
    }

    fn reserveSuperblock(self: *Heap, kind: SuperblockKind) std.mem.Allocator.Error!*Superblock {
        self.stats.superblock_reserves += 1;
        const bytes = self.backing.alignedAlloc(u8, block_align, superblock_bytes) catch |err| {
            self.stats.failed_reserves += 1;
            return err;
        };
        errdefer self.backing.free(bytes);
        try self.superblocks.append(self.backing, .{
            .bytes = bytes,
            .kind = kind,
        });
        self.stats.superblocks += 1;
        self.stats.committed_bytes += superblock_bytes;
        return &self.superblocks.items[self.superblocks.items.len - 1];
    }

    fn resetBlock(
        self: *Heap,
        block: *Block,
        class_idx: usize,
        cell_size: u32,
        super_index: u32,
        reused: bool,
    ) void {
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
    }

    fn allocMedium(self: *Heap, n: usize) std.mem.Allocator.Error![]u8 {
        const pages: u32 = @intCast((n + page_bytes - 1) / page_bytes);
        const found = self.findMediumRun(pages) orelse blk: {
            _ = try self.reserveSuperblock(.medium);
            break :blk self.findMediumRun(pages).?;
        };
        const sb = &self.superblocks.items[found.super_index];
        var p: u32 = 0;
        while (p < pages) : (p += 1) setPage(&sb.page_bits, found.page + p);
        const ptr = sb.bytes.ptr + found.page * page_bytes;
        try self.medium.put(self.backing, @intFromPtr(ptr), .{
            .super_index = found.super_index,
            .page = found.page,
            .pages = pages,
            .user_bytes = n,
        });
        self.stats.live_bytes += n;
        self.stats.live_count += 1;
        self.stats.medium_allocs += 1;
        return ptr[0..n];
    }

    fn findMediumRun(self: *Heap, pages: u32) ?struct { super_index: u32, page: u32 } {
        var si: u32 = 0;
        while (si < self.superblocks.items.len) : (si += 1) {
            const sb = &self.superblocks.items[si];
            if (sb.kind != .medium) continue;
            var start: u32 = 0;
            while (start + pages <= pages_per_superblock) {
                var ok = true;
                var p: u32 = 0;
                while (p < pages) : (p += 1) {
                    if (testPage(sb.page_bits, start + p)) {
                        ok = false;
                        start = start + p + 1;
                        break;
                    }
                }
                if (ok) return .{ .super_index = si, .page = start };
            }
        }
        return null;
    }

    fn freeMedium(self: *Heap, extent: MediumExtent) void {
        const sb = &self.superblocks.items[extent.super_index];
        var p: u32 = 0;
        while (p < extent.pages) : (p += 1) clearPage(&sb.page_bits, extent.page + p);
        self.stats.live_bytes -= extent.user_bytes;
        self.stats.live_count -= 1;
    }

    fn allocLarge(self: *Heap, n: usize) std.mem.Allocator.Error![]u8 {
        const aligned = std.mem.alignForward(usize, n, page_bytes);
        self.stats.large_reserves += 1;
        const bytes = self.backing.alignedAlloc(u8, .fromByteUnits(page_bytes), aligned) catch |err| {
            self.stats.failed_reserves += 1;
            return err;
        };
        errdefer self.backing.free(bytes);
        try self.large.put(self.backing, @intFromPtr(bytes.ptr), .{ .bytes = bytes });
        self.stats.live_bytes += bytes.len;
        self.stats.live_count += 1;
        self.stats.committed_bytes += bytes.len;
        self.stats.large_maps += 1;
        self.stats.large_allocs += 1;
        return bytes.ptr[0..n];
    }
};

extern "c" fn malloc_trim(pad: usize) c_int;

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

fn bitWord(index: u32) usize {
    return index / 64;
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

fn testPage(bits: [pages_per_superblock / 64]u64, page: u32) bool {
    return bits[page / 64] & (@as(u64, 1) << @intCast(page % 64)) != 0;
}

fn setPage(bits: *[pages_per_superblock / 64]u64, page: u32) void {
    bits[page / 64] |= @as(u64, 1) << @intCast(page % 64);
}

fn clearPage(bits: *[pages_per_superblock / 64]u64, page: u32) void {
    bits[page / 64] &= ~(@as(u64, 1) << @intCast(page % 64));
}

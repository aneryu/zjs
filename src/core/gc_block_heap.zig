//! 64 KiB block heap (tracing-gc-design.md §4.2 / §4.3 / §8.1).
//!
//! Superblocks are 2 MiB mappings split into 64 KiB-aligned blocks. A block
//! holds one size class. Empty blocks return to the runtime free list; the
//! mapping is released only as a whole superblock. One over-sized mapping
//! plus per-block `munmap` is forbidden.
//!
//! Compiled only when `-Dzjs_gc=trace_stw`. Default `rc` keeps the existing
//! allocator. This module does not replace object headers.

const std = @import("std");

const space = @import("gc_space.zig");
const sweep = @import("gc_sweep_model.zig");

pub const enabled = true;

pub const superblock_bytes: usize = 2 * 1024 * 1024;
pub const block_bytes: usize = 64 * 1024;
pub const blocks_per_superblock: usize = superblock_bytes / block_bytes;
pub const page_bytes: usize = 4096;
pub const pages_per_superblock: usize = superblock_bytes / page_bytes;
pub const block_align: std.mem.Alignment = .fromByteUnits(block_bytes);
pub const free_nil: u32 = std.math.maxInt(u32);

/// Alignment every cell is guaranteed to satisfy. Blocks are 64 KiB aligned,
/// `cells_offset` is aligned to 16, and every size class is a multiple of 16,
/// so cell addresses inherit 16-byte alignment. Callers needing more must not
/// use this heap.
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
    mark_epoch: u64 = 0,

    pub fn committedLiveMilli(self: Stats) usize {
        if (self.live_bytes == 0) return 0;
        return (self.committed_bytes * 1000 + self.live_bytes - 1) / self.live_bytes;
    }
};

const SuperblockKind = enum { classed, medium };

const Superblock = struct {
    bytes: []align(block_bytes) u8,
    kind: SuperblockKind,
    used_blocks: u32 = 0,
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
    sweep_state: sweep.SweepState = .fresh,
    flags: u8 = 0,
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
    next_free: usize = 0,

    pub const flag_young: u8 = 1 << 0;
    const flag_remembered: u8 = 1 << 1;
    const flag_overflow: u8 = 1 << 2;
    const flag_bailout: u8 = 1 << 3;
    const flag_epoch_transition: u8 = 1 << 4;

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
        const alloc = @atomicLoad(u64, &self.bitmaps().alloc[word_index], .monotonic);
        if (self.mark_epoch != epoch) return alloc;
        const mark = @atomicLoad(u64, &self.bitmaps().mark[word_index], .monotonic);
        return alloc & ~mark;
    }

    pub fn cellAllocated(self: *Block, index: u32) bool {
        return testBit(self.bitmaps().alloc, index);
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
        if (self.mark_epoch != epoch) return;
        clearBit(self.bitmaps().mark, index);
    }

    pub inline fn isYoungListed(self: *const Block) bool {
        return (self.flags & flag_young) != 0;
    }

    pub fn ensureMarkEpoch(self: *Block, epoch: u64) void {
        if (self.mark_epoch == epoch) return;
        self.flags |= flag_epoch_transition;
        const bits = self.bitmaps();
        @memset(bits.mark, 0);
        self.mark_epoch = epoch;
        self.flags &= ~flag_epoch_transition;
    }

    pub fn isMarked(self: *Block, index: u32, epoch: u64) bool {
        if (self.mark_epoch != epoch) return false;
        return testBit(self.bitmaps().mark, index);
    }

    pub fn setMark(self: *Block, index: u32, epoch: u64) void {
        self.ensureMarkEpoch(epoch);
        setBit(self.bitmaps().mark, index);
    }
};

pub const Heap = struct {
    backing: std.mem.Allocator,
    superblocks: std.ArrayListUnmanaged(Superblock) = .empty,
    large: std.AutoHashMapUnmanaged(usize, LargeMap) = .empty,
    medium: std.AutoHashMapUnmanaged(usize, MediumExtent) = .empty,
    free_blocks: [space.class_count]?*Block = @splat(null),
    active: [space.class_count]?*Block = @splat(null),
    /// Head of the young-block list (see `noteYoungCell`).
    young_blocks: ?*Block = null,
    stats: Stats = .{},
    mark_epoch: u64 = 0,

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
        for (self.superblocks.items) |sb| {
            self.backing.free(sb.bytes);
        }
        self.superblocks.deinit(self.backing);
        self.* = .{ .backing = self.backing };
    }

    pub fn beginMajor(self: *Heap) void {
        self.mark_epoch += 1;
        self.stats.mark_epoch = self.mark_epoch;
    }

    pub fn alloc(self: *Heap, n: usize) std.mem.Allocator.Error![]u8 {
        if (n == 0) return &.{};
        if (n >= space.large_min_bytes) return self.allocLarge(n);
        if (space.classifyPayload(n) == .medium) return self.allocMedium(n);
        const class_idx = space.classIndexForPayload(n) orelse return self.allocMedium(n);
        return self.allocSmall(class_idx, n);
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
        self.freeSmall(block, index);
    }

    pub fn owns(self: *const Heap, ptr: [*]u8) bool {
        const addr = @intFromPtr(ptr);
        if (self.large.contains(addr)) return true;
        if (self.medium.contains(addr)) return true;
        const block = Block.fromAddr(addr) orelse return false;
        return self.containsBlock(block);
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
    pub fn clearYoungBlocks(self: *Heap) void {
        var cursor = self.young_blocks;
        while (cursor) |block| {
            const link = block.young_link;
            block.flags &= ~Block.flag_young;
            block.young_link = 0;
            cursor = if (link <= 1) null else @ptrFromInt(link);
        }
        self.young_blocks = null;
    }

    pub fn blockOf(self: *const Heap, ptr: [*]u8) ?*Block {
        // Arithmetic first, membership second, DEREFERENCE LAST. This is fed
        // arbitrary conservative candidates now, and the old order -- mask,
        // read the magic, then check membership -- read one word out of
        // whatever page the mask landed in, which for a stray stack integer
        // is as likely unmapped as not.
        const addr = @intFromPtr(ptr);
        if (addr < block_bytes) return null;
        const base = addr & ~@as(usize, block_bytes - 1);
        const block: *Block = @ptrFromInt(base);
        if (!self.containsBlock(block)) return null;
        if (block.magic != block_magic) return null;
        return block;
    }

    pub fn committedLiveMilli(self: Heap) usize {
        return self.stats.committedLiveMilli();
    }

    fn containsBlock(self: *const Heap, block: *const Block) bool {
        const addr = @intFromPtr(block);
        for (self.superblocks.items) |sb| {
            if (sb.kind != .classed) continue;
            const lo = @intFromPtr(sb.bytes.ptr);
            if (addr >= lo and addr < lo + sb.bytes.len) return true;
        }
        return false;
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
        setBit(block.bitmaps().alloc, index);
        block.allocated_count += 1;
        self.stats.live_bytes += cell_size;
        self.stats.live_count += 1;
        self.stats.small_allocs += 1;
        return block.cellPtr(index)[0..user_bytes];
    }

    fn freeSmall(self: *Heap, block: *Block, index: u32) void {
        if (!testBit(block.bitmaps().alloc, index)) return;
        clearBit(block.bitmaps().alloc, index);
        pushCell(block, index);
        block.allocated_count -= 1;
        self.stats.live_bytes -= block.cell_size;
        self.stats.live_count -= 1;
        if (block.allocated_count == 0) {
            const class_idx = block.size_class;
            if (self.active[class_idx] == block) return;
            block.sweep_state = .swept;
            block.next_free = if (self.free_blocks[class_idx]) |head| @intFromPtr(head) else 0;
            self.free_blocks[class_idx] = block;
        }
    }

    fn openBlock(self: *Heap, class_idx: usize, cell_size: u32) std.mem.Allocator.Error!*Block {
        if (self.free_blocks[class_idx]) |block| {
            self.free_blocks[class_idx] = if (block.next_free == 0)
                null
            else
                @ptrFromInt(block.next_free);
            self.resetBlock(block, class_idx, cell_size);
            block.sweep_state = .active;
            return block;
        }
        const raw = try self.takeClassedBlock();
        const block: *Block = @ptrCast(@alignCast(raw));
        self.resetBlock(block, class_idx, cell_size);
        block.sweep_state = .fresh;
        block.sweep_state = .active;
        return block;
    }

    fn takeClassedBlock(self: *Heap) std.mem.Allocator.Error![*]u8 {
        for (self.superblocks.items) |*sb| {
            if (sb.kind != .classed) continue;
            if (sb.used_blocks >= blocks_per_superblock) continue;
            const off = sb.used_blocks * block_bytes;
            sb.used_blocks += 1;
            return sb.bytes.ptr + off;
        }
        const sb = try self.reserveSuperblock(.classed);
        sb.used_blocks = 1;
        return sb.bytes.ptr;
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

    fn resetBlock(self: *Heap, block: *Block, class_idx: usize, cell_size: u32) void {
        const header_size = std.mem.alignForward(usize, @sizeOf(Block), 16);
        const max_cells = (block_bytes - header_size) / cell_size;
        var cell_count: u32 = @intCast(max_cells);
        var bitmap_words: u32 = @intCast((cell_count + 63) / 64);
        const alloc_off: u32 = @intCast(header_size);
        var mark_off: u32 = alloc_off + bitmap_words * 8;
        var remember_off: u32 = mark_off + bitmap_words * 8;
        var cells_off = std.mem.alignForward(u32, remember_off + bitmap_words * 8, 16);
        while (cells_off + cell_count * cell_size > block_bytes) {
            cell_count -= 1;
            bitmap_words = @intCast((cell_count + 63) / 64);
            mark_off = alloc_off + bitmap_words * 8;
            remember_off = mark_off + bitmap_words * 8;
            cells_off = std.mem.alignForward(u32, remember_off + bitmap_words * 8, 16);
        }
        std.debug.assert(cell_count >= space.min_cells_per_block);
        std.debug.assert(bitmap_words <= max_bitmap_words);
        block.* = .{
            .magic = block_magic,
            .mark_epoch = self.mark_epoch,
            .cell_size = cell_size,
            .cell_count = cell_count,
            .allocated_count = 0,
            .bump = 0,
            .free_list = free_nil,
            .size_class = @intCast(class_idx),
            .sweep_state = .fresh,
            .flags = 0,
            .cells_offset = cells_off,
            .alloc_bits_off = alloc_off,
            .mark_bits_off = mark_off,
            .remember_bits_off = remember_off,
            .bitmap_words = bitmap_words,
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

fn popCell(block: *Block) ?u32 {
    if (block.free_list != free_nil) {
        const index = block.free_list;
        const cell = block.cellPtr(index);
        block.free_list = @as(*u32, @ptrCast(@alignCast(cell))).*;
        return index;
    }
    if (block.bump >= block.cell_count) return null;
    const index = block.bump;
    block.bump += 1;
    return index;
}

fn pushCell(block: *Block, index: u32) void {
    const cell = block.cellPtr(index);
    @as(*u32, @ptrCast(@alignCast(cell))).* = block.free_list;
    block.free_list = index;
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

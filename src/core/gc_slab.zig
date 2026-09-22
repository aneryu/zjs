//! GC-only size-class arenas. Native allocations never enter this storage.
const std = @import("std");
const slab_alloc_prefetch = true;

pub const Slab = struct {
    pub const arena_size: usize = 4 * 1024;
    pub const max_size: usize = 512;
    const slab_alignment: std.mem.Alignment = .@"8";
    /// Arenas are aligned to their own size, so `ptr & ~(arena_size - 1)` is
    /// the arena that owns any interior pointer.
    ///
    /// This is what lets the collector resolve a conservative stack candidate
    /// with arithmetic instead of a hash lookup. An arena holds one size class
    /// with its header at the base, so once the base is known the owning block
    /// is `(ptr - base - header) / block_size`, and the block's first byte is
    /// the GC metadata prefix that says whether it is a live GC object at all.
    /// Without this alignment none of that is reachable from an interior
    /// pointer and every published object has to be inserted into a side table
    /// instead -- which is what the address registry was, at 76% of raytrace's
    /// runtime. The arena is a whole page either way, so alignment costs the
    /// backing allocator nothing it was not already paying.
    pub const arena_alignment: std.mem.Alignment =
        .fromByteUnits(arena_size);
    const free_nil: u16 = std.math.maxInt(u16);
    const block_sizes = [_]usize{
        16,  24,  32,  40,  48,  56,  64,  72,
        80,  88,  96,  104, 112, 120, 128, 144,
        160, 176, 192, 208, 224, 240, 256, 288,
        320, 352, 384, 416, 448, 480, 512,
    };
    pub const class_count: usize = block_sizes.len;

    /// Every arena alive right now, for an observer installed after the fact.
    ///
    /// The runtime allocates before its GC registry exists, so by the time the
    /// observer can be installed some arenas are already serving objects.
    /// Without this they would never enter the arena set and every object in
    /// them would be invisible to the conservative scanner -- a use-after-free
    /// rather than a leak, and one that only shows up when a stack candidate
    /// happens to name an early object.
    pub fn forEachArena(self: *Slab, context: *anyopaque, visit: *const fn (*anyopaque, usize) void) void {
        for (&self.arenas) |head| {
            var node = head;
            while (node) |arena| {
                node = arena.next;
                visit(context, @intFromPtr(arena));
            }
        }
    }

    pub const ArenaObserver = struct {
        ctx: *anyopaque,
        on_create: *const fn (ctx: *anyopaque, base: usize) void,
        on_release: *const fn (ctx: *anyopaque, base: usize) void,
    };

    const BlockHeader = extern struct {
        /// Allocated: block index. Free: next free block index.
        index_or_next: u16,
        /// Size-class index of the owning arena, mirroring qjs
        /// `JSMallocBlockHeader.block_size_idx` so a free never
        /// has to recompute the class from the byte size. GC allocations stamp
        /// it too (low 5 bits of `gc.Metadata.alloc_info`, written by
        /// initGcPrefix together with the kind/flags byte); GC tenants may also
        /// set the accounting bits in its high bits, so rather than qjs's
        /// write-once-per-arena, each allocation re-stamps the
        /// byte at block-pop/prefix-init time and it stays valid for that
        /// block's lifetime.
        block_size_idx: u8,
    };

    /// Set on every live arena, checked before an address masked out of a
    /// conservative candidate is believed.
    ///
    /// The observer set below is the real authority -- a stray word can point
    /// at an unmapped page, and reading a magic out of it would fault rather
    /// than return false. This is the second check, against a word that points
    /// into some other mapped allocation that happens to share a page base
    /// with nothing at all.
    pub const arena_magic: u32 = 0x5a4a5341;

    const Arena = struct {
        magic: u32 = arena_magic,
        next: ?*Arena = null,
        prev: ?*Arena = null,
        free_next: ?*Arena = null,
        free_prev: ?*Arena = null,
        block_size_idx: u8 = 0,
        used_blocks: u16 = 0,
        block_count: u16 = 0,
        first_free_block: u16 = free_nil,
    };

    const block_header_size = std.mem.alignForward(usize, @sizeOf(BlockHeader), slab_alignment.toByteUnits());
    /// Public name for the 8-byte slab header folded into each class block.
    pub const block_header_bytes: usize = block_header_size;
    const arena_header_size = std.mem.alignForward(usize, @sizeOf(Arena), slab_alignment.toByteUnits());

    pub inline fn blockSize(index: usize) usize {
        return block_sizes[index];
    }

    arenas: [block_sizes.len]?*Arena = @splat(null),
    free_arenas: [block_sizes.len]?*Arena = @splat(null),
    /// Trace-only physical backing for the 4 KiB arenas. Logical payload
    /// accounting and limits still belong to Runtime allocation helpers; this only keeps
    /// arena refills off glibc's high-alignment malloc path.
    arena_backing: ?std.mem.Allocator = null,
    /// Told when an arena is created or released, so the collector can keep a
    /// set of valid arena bases. Arena lifetime, not object lifetime: at 4 KiB
    /// per arena against ~64-byte objects this is roughly two orders of
    /// magnitude less traffic than registering each published object.
    arena_observer: ?ArenaObserver = null,

    pub inline fn canUse(byte_count: usize, alignment: std.mem.Alignment) bool {
        return classIndex(byte_count, alignment) != null;
    }

    pub fn setArenaBacking(self: *Slab, allocator: std.mem.Allocator) void {
        for (self.arenas) |head| std.debug.assert(head == null);
        self.arena_backing = allocator;
    }

    /// Eligibility-only variant of `classIndex`: true iff that would return an
    /// index, without materializing the class arithmetic. Free paths pair this
    /// with `headerClassIndex` (qjs `__js_free` reads `b->block_size_idx`,
    /// quickjs.c, instead of re-deriving the class from the size).
    pub inline fn eligibleSize(byte_count: usize, alignment: std.mem.Alignment) bool {
        if (alignment.compare(.gt, slab_alignment)) return false;
        return totalBlockSize(byte_count) != null;
    }

    /// Class index carried by the block header of a slab-backed allocation.
    /// Only valid for blocks that are free or occupied by non-GC payloads
    /// (live GC blocks carry the class in the low 5 bits plus GC accounting
    /// bits above; their frees read it through `gcAllocInfoByte` instead).
    pub inline fn headerClassIndex(ptr: [*]u8) usize {
        return blockHeaderFromUser(ptr).block_size_idx;
    }

    /// qjs `__js_malloc_usable_size` small-block formula.
    pub inline fn usablePayloadFromClass(class: usize) usize {
        return block_sizes[class] - block_header_size;
    }

    /// `stamp_class` = the block will hold a raw (non-GC) payload, so record
    /// its class index in the header for `headerClassIndex` on the free side.
    /// GC objects skip the pop-time stamp only because initGcPrefix immediately
    /// rewrites the same byte with the identical class index (plus clear GC
    /// accounting bits) as part of its combined class+kind u16 store.
    pub inline fn allocAtIndex(self: *Slab, backing: std.mem.Allocator, index: usize, comptime stamp_class: bool) ![*]u8 {
        const arena = self.free_arenas[index] orelse try self.addArena(backing, index);
        return self.popFreeBlock(arena, index, stamp_class);
    }

    /// Hot small-block pop, mirroring the qjs `__js_malloc` small arm
    ///: unlink the first free block, stamp its live
    /// block index, and retire the arena from the free list when it fills.
    pub inline fn popFreeBlock(self: *Slab, arena: *Arena, index: usize, comptime stamp_class: bool) [*]u8 {
        const block_size = block_sizes[index];
        const block_idx = arena.first_free_block;
        std.debug.assert(block_idx != free_nil);
        const header = blockHeaderAt(arena, block_idx, block_size);
        const next_free = header.index_or_next;
        arena.first_free_block = next_free;
        if (comptime slab_alloc_prefetch) {
            const prefetch_idx: u16 = if (next_free == free_nil) 0 else next_free;
            // The property that makes this cheap instead of ruinous: the
            // address always lands inside this arena's own 4 KiB page, which
            // is mapped and in the TLB. An address outside it costs a page
            // walk the prefetch then throws away -- measured at 12.6% of
            // earley-boyer's total cycles when `free_nil` was left unfolded.
            std.debug.assert(prefetch_idx < arena.block_count);
            const prefetch_addr = @intFromPtr(arenaBlocks(arena)) + @as(usize, prefetch_idx) * block_size;
            std.debug.assert(prefetch_addr - @intFromPtr(arena) < arena_size);
            @prefetch(@as(*const u8, @ptrFromInt(prefetch_addr)), .{
                .rw = .write,
                .locality = 3,
                .cache = .data,
            });
        }
        header.index_or_next = block_idx;
        if (comptime stamp_class) header.block_size_idx = @intCast(index);
        arena.used_blocks += 1;
        if (arena.used_blocks == arena.block_count) {
            self.removeFreeArena(index, arena);
        }
        return userData(header);
    }

    /// `backing` is taken by pointer so the hot free path materializes only an
    /// address; the 16-byte allocator value is loaded solely inside the cold
    /// empty-arena arm that actually calls it.
    pub inline fn freeAtIndex(self: *Slab, backing: *const std.mem.Allocator, ptr: [*]u8, index: usize) void {
        const header = blockHeaderFromUser(ptr);
        const block_idx = header.index_or_next;
        const block_size = block_sizes[index];
        const arena = arenaFromBlock(header, block_idx, block_size);

        std.debug.assert(index < block_sizes.len);
        // Same reason as the arena-init stamp: a freed block must not read as
        // a live GC object. `recordHeapFreeWithBytes` clears `heap_accounted`
        // on the way here, but it returns early when the recorded size is
        // zero, and relying on every GC free path to have done it makes the
        // collector's answer depend on a chain of invariants rather than on
        // the state of the block. One byte store closes it here instead.
        header.block_size_idx = @intCast(index);
        std.debug.assert(block_idx < arena.block_count);
        std.debug.assert(arena.block_size_idx == index);
        std.debug.assert(arena.used_blocks != 0);

        const was_full = arena.used_blocks == arena.block_count;
        header.index_or_next = arena.first_free_block;
        arena.first_free_block = block_idx;
        if (was_full) {
            self.addFreeArena(index, arena);
        }
        arena.used_blocks -= 1;
        if (arena.used_blocks == 0) {
            return self.releaseEmptyArena(backing, index, arena);
        }
    }

    /// QuickJS `js_free` returns an empty 4 KiB arena immediately
    ///, but its re-acquisition is a tcache pop; ours
    /// is a page-aligned backing allocation, a stamp of every block header
    /// and an address-registry insert, plus the matching removal here. A
    /// builtin that allocates a handful of small blocks per call and frees
    /// them before the next call (regexp `replace`'s match arrays) paid that
    /// whole cycle on every call (~13% of its profile). So one empty arena
    /// per class is retained: it stays on both lists (at the head of the
    /// free list, `addFreeArena`) and registered; a second empty arena of
    /// the class is released at once, bounding the retained backing to one
    /// arena per class. No new slab field: the runtime's struct layout is
    /// load-bearing for GC address geometry (typescript +3.3% insn from a
    /// pad field alone). Out of line so the per-free hot path stays
    /// call-free (the mirror of qjs keeping `js_malloc_new_arena` no_inline
    /// on the alloc side).
    pub noinline fn releaseEmptyArena(self: *Slab, backing: *const std.mem.Allocator, index: usize, arena: *Arena) void {
        const head = self.free_arenas[index].?;
        if (head == arena) return; // already the retained spare, at the head
        if (head.used_blocks != 0) {
            // No spare yet: this arena becomes it, moved to the head.
            self.removeFreeArena(index, arena);
            arena.free_prev = null;
            arena.free_next = self.free_arenas[index];
            if (arena.free_next) |next| next.free_prev = arena;
            self.free_arenas[index] = arena;
            return;
        }
        self.removeArena(index, arena);
        self.removeFreeArena(index, arena);
        if (self.arena_observer) |observer| observer.on_release(observer.ctx, @intFromPtr(arena));
        arena.magic = 0;
        self.arenaBacking(backing.*).rawFree(arenaAllocation(arena), arena_alignment, @returnAddress());
    }

    pub fn deinit(self: *Slab, backing: std.mem.Allocator) void {
        for (&self.arenas) |*head| {
            var arena = head.*;
            while (arena) |node| {
                arena = node.next;
                if (self.arena_observer) |observer| observer.on_release(observer.ctx, @intFromPtr(node));
                node.magic = 0;
                self.arenaBacking(backing).rawFree(arenaAllocation(node), arena_alignment, @returnAddress());
            }
        }
        self.* = .{};
    }

    /// qjs `js_malloc_new_arena` is no_inline; keeping the
    /// arena-construction loop out of the per-alloc hot functions saves their
    /// prologues from carrying its register pressure.
    pub noinline fn addArena(self: *Slab, backing: std.mem.Allocator, index: usize) !*Arena {
        const block_size = block_sizes[index];
        const block_count = (arena_size - arena_header_size) / block_size;
        std.debug.assert(block_count > 0 and block_count <= free_nil);
        const alloc_size = arena_header_size + block_count * block_size;
        const storage_ptr = self.arenaBacking(backing).rawAlloc(alloc_size, arena_alignment, @returnAddress()) orelse return error.OutOfMemory;
        std.debug.assert(@intFromPtr(storage_ptr) % arena_size == 0);
        const arena: *Arena = @ptrCast(@alignCast(storage_ptr));
        arena.* = .{
            .block_size_idx = @intCast(index),
            .block_count = @intCast(block_count),
            .first_free_block = 0,
        };
        var block_idx: u16 = 0;
        while (block_idx < arena.block_count) : (block_idx += 1) {
            const header = blockHeaderAt(arena, block_idx, block_size);
            header.index_or_next = if (block_idx + 1 == arena.block_count) free_nil else block_idx + 1;
            // Stamp the class now, which also clears the GC accounting bits
            // that share this byte with it. Arenas come from recycled backing
            // memory, so a block that has never been allocated would otherwise
            // carry whatever its previous life left here -- and the collector
            // reads exactly this byte to decide whether an address masked out
            // of a conservative candidate is a live GC object. A stale
            // `heap_accounted` bit in a never-allocated block makes the tracer
            // walk garbage as if it were an object.
            header.block_size_idx = @intCast(index);
        }
        self.addArenaList(index, arena);
        self.addFreeArena(index, arena);
        if (self.arena_observer) |observer| observer.on_create(observer.ctx, @intFromPtr(arena));
        return arena;
    }

    pub inline fn classIndex(byte_count: usize, alignment: std.mem.Alignment) ?usize {
        if (alignment.compare(.gt, slab_alignment)) return null;
        const total_size = totalBlockSize(byte_count) orelse return null;
        return blockSizeIndex(total_size);
    }

    /// Map a required block size (<= `max_size`) to its `block_sizes` index by
    /// piecewise arithmetic instead of walking a fully-unrolled 31-rung linear
    /// `cmp` ladder. Faithful port of qjs `get_block_size_index`
    ///: the `block_sizes` table is byte-identical to qjs
    /// `js_malloc_block_sizes`, so the three arithmetic segments (step-8 up to
    /// 128, step-16 up to 256, step-32 up to 512) reproduce the exact same
    /// index the linear scan returned (verified by the comptime cross-check
    /// below). This collapses ~7-14 walked rungs (each `cmp`+`b.cs`+`adrp`+
    /// `add`+`b`) into a handful of `add`/`lsr`/`cmp` on every slab alloc/free.
    pub inline fn blockSizeIndex(total_size: usize) usize {
        std.debug.assert(total_size <= max_size);
        if (total_size <= 16) return 0;
        if (total_size <= 128) return (total_size + 7) / 8 - 2;
        if (total_size <= 256) return (total_size + 15) / 16 + 6;
        return (total_size + 31) / 32 + 14;
    }

    comptime {
        // Guard the arithmetic against any future edit to `block_sizes`: for
        // every reachable block size the arithmetic index must equal the
        // smallest `block_sizes[i] >= size` that the old linear scan picked.
        @setEvalBranchQuota(20000);
        var size: usize = 1;
        while (size <= max_size) : (size += 1) {
            var linear_index: usize = block_sizes.len;
            for (block_sizes, 0..) |block_size, index| {
                if (size <= block_size) {
                    linear_index = index;
                    break;
                }
            }
            if (linear_index != block_sizes.len) {
                std.debug.assert(blockSizeIndex(size) == linear_index);
            }
        }
    }

    pub inline fn totalBlockSize(byte_count: usize) ?usize {
        if (byte_count == 0) return null;
        const aligned_size = std.mem.alignForward(usize, byte_count, slab_alignment.toByteUnits());
        const total_size = std.math.add(usize, aligned_size, block_header_size) catch return null;
        if (total_size > max_size) return null;
        return total_size;
    }

    pub inline fn arenaBlocks(arena: *Arena) [*]u8 {
        return @as([*]u8, @ptrCast(arena)) + arena_header_size;
    }

    /// Resolve an interior pointer to the user address of the block holding it,
    /// given the arena base it was masked out of.
    ///
    /// This is the whole reason arenas are self-aligned. `base` must have come
    /// from `addr & ~(arena_size - 1)` AND been confirmed as a live arena by
    /// the caller's own set -- the magic check here is a second filter against
    /// a mapped-but-unrelated page, not a substitute for the first, because a
    /// stray candidate can name an unmapped address where reading the magic
    /// would fault.
    ///
    /// Returns the USER pointer (past the 8-byte block header), which for a GC
    /// tenant is its `gc.Header`; the header itself is the metadata prefix, so
    /// a candidate pointing at the prefix and one pointing at the object both
    /// land on the same block and resolve identically.
    pub fn userPtrWithinArena(base: usize, addr: usize) ?[*]u8 {
        const arena: *Arena = @ptrFromInt(base);
        if (arena.magic != arena_magic) return null;
        const blocks = @intFromPtr(arenaBlocks(arena));
        if (addr < blocks) return null;
        const block_size = block_sizes[arena.block_size_idx];
        const index = (addr - blocks) / block_size;
        if (index >= arena.block_count) return null;
        return @as([*]u8, @ptrFromInt(blocks + index * block_size)) + block_header_size;
    }

    /// Every block of an arena, with the slab's own opinion of whether it is
    /// free, so the collector can audit the invariant its candidate validation
    /// rests on: a block reads as a live GC object exactly when it holds one.
    ///
    /// Both halves of that are checkable only from here. "Free" means on this
    /// arena's free chain, which covers blocks never handed out (a fresh arena
    /// threads all of them onto it) and blocks returned by `freeAtIndex`. Those
    /// are precisely the two states whose stale `alloc_info` byte made the
    /// tracer walk garbage as an object.
    pub fn forEachArenaBlock(
        base: usize,
        context: *anyopaque,
        visit: *const fn (ctx: *anyopaque, user: [*]u8, is_free: bool) void,
    ) void {
        const arena: *Arena = @ptrFromInt(base);
        if (arena.magic != arena_magic) return;
        const block_size = block_sizes[arena.block_size_idx];
        // 253 blocks is the most any size class fits in a 4 KiB arena.
        var free_bits: [4]u64 = @splat(0);
        var cursor = arena.first_free_block;
        var guard: usize = 0;
        while (cursor != free_nil and guard <= arena.block_count) : (guard += 1) {
            if (cursor >= arena.block_count) break;
            free_bits[cursor / 64] |= @as(u64, 1) << @intCast(cursor % 64);
            cursor = blockHeaderAt(arena, cursor, block_size).index_or_next;
        }
        var index: u16 = 0;
        while (index < arena.block_count) : (index += 1) {
            const is_free = (free_bits[index / 64] & (@as(u64, 1) << @intCast(index % 64))) != 0;
            visit(context, userData(blockHeaderAt(arena, index, block_size)), is_free);
        }
    }

    pub inline fn blockHeaderAt(arena: *Arena, block_idx: u16, block_size: usize) *BlockHeader {
        return @ptrCast(@alignCast(arenaBlocks(arena) + @as(usize, block_idx) * block_size));
    }

    pub inline fn blockHeaderFromUser(ptr: [*]u8) *BlockHeader {
        return @ptrFromInt(@intFromPtr(ptr) - block_header_size);
    }

    pub inline fn userData(header: *BlockHeader) [*]u8 {
        return @as([*]u8, @ptrCast(header)) + block_header_size;
    }

    pub inline fn arenaFromBlock(header: *BlockHeader, block_idx: u16, block_size: usize) *Arena {
        const arena_addr = @intFromPtr(header) - @as(usize, block_idx) * block_size - arena_header_size;
        return @ptrFromInt(arena_addr);
    }

    pub inline fn arenaAllocation(arena: *Arena) []u8 {
        const index = arena.block_size_idx;
        const alloc_size = arena_header_size + @as(usize, arena.block_count) * block_sizes[index];
        return @as([*]u8, @ptrCast(arena))[0..alloc_size];
    }

    pub inline fn arenaBacking(self: *const Slab, fallback: std.mem.Allocator) std.mem.Allocator {
        return self.arena_backing orelse fallback;
    }

    pub fn addArenaList(self: *Slab, index: usize, arena: *Arena) void {
        arena.prev = null;
        arena.next = self.arenas[index];
        if (arena.next) |next| next.prev = arena;
        self.arenas[index] = arena;
    }

    pub fn removeArena(self: *Slab, index: usize, arena: *Arena) void {
        if (arena.prev) |prev| {
            prev.next = arena.next;
        } else {
            std.debug.assert(self.arenas[index] == arena);
            self.arenas[index] = arena.next;
        }
        if (arena.next) |next| next.prev = arena.prev;
        arena.next = null;
        arena.prev = null;
    }

    pub fn addFreeArena(self: *Slab, index: usize, arena: *Arena) void {
        // The class's retained empty arena (see `releaseEmptyArena`) keeps
        // the head of the free list, so a partially free arena joining the
        // list slots in behind it. Allocation then drains the empty arena
        // first, which is also what keeps "at most one empty arena" O(1).
        if (self.free_arenas[index]) |head| {
            if (head.used_blocks == 0 and head != arena) {
                arena.free_prev = head;
                arena.free_next = head.free_next;
                if (arena.free_next) |next| next.free_prev = arena;
                head.free_next = arena;
                return;
            }
        }
        arena.free_prev = null;
        arena.free_next = self.free_arenas[index];
        if (arena.free_next) |next| next.free_prev = arena;
        self.free_arenas[index] = arena;
    }

    pub fn removeFreeArena(self: *Slab, index: usize, arena: *Arena) void {
        if (arena.free_prev) |prev| {
            prev.free_next = arena.free_next;
        } else {
            std.debug.assert(self.free_arenas[index] == arena);
            self.free_arenas[index] = arena.free_next;
        }
        if (arena.free_next) |next| next.free_prev = arena.free_prev;
        arena.free_next = null;
        arena.free_prev = null;
    }
};

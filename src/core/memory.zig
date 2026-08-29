//! Runtime memory accounting, small-object slabs, and allocation entry points.
//!
//! `MemoryAccount` owns every allocation made through it and couples byte/
//! allocation counters to the GC registry; callers must free through the same
//! account and with the matching type/alignment/FAM size. Production GC
//! threshold checks intentionally occur at the object boundary, while OOM and
//! accounting probes are comptime diagnostic tiers. QuickJS source map:
//! `JSMallocState` at quickjs.c:314 and the allocator family around
//! quickjs.c:1566-1826. This leaf core allocator must not depend on exec or
//! binding.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const gc_representation = @import("gc_representation_constants.zig");
const gc_block_heap = @import("gc_block_heap.zig");

const diagnostic_accounting_enabled = builtin.is_test or builtin.mode == .Debug;
/// Exact per-allocation cycle peaks are available only to the experimental
/// tracing collector. The default RC account keeps neither the pointer nor
/// the branch in its allocation paths.
const cycle_envelope_tracking_available = std.mem.eql(u8, build_options.zjs_gc, "trace_stw");
const block_heap_enabled = std.mem.eql(u8, build_options.zjs_gc, "trace_stw");

/// OOM-injection coverage (v1), gated by `-Dzjs_oom_coverage` (default
/// false; the recording branches below are `comptime`-eliminated so the
/// default build's allocation hot path is unchanged).
///
/// When enabled, every `MemoryAccount` allocation entry point records its
/// caller via `@returnAddress()` into a process-global deduplicated set.
/// `zig build test-oom -Dzjs_oom_coverage=true` reports the number of
/// distinct allocation call sites the OOM corpus reached, giving a
/// comparable coverage figure across corpus changes.
///
/// v1 scope: a raw count of distinct return addresses (no symbolization).
/// Possible evolution: symbolize sites via std.debug.SelfInfo for a
/// human-readable report, track per-site hit counts, capture the direct
/// `MemoryAccount.allocator` container call sites at the backing-allocator
/// vtable instead, and schedule fail-injection toward not-yet-failed sites.
pub const oom_coverage_enabled: bool = build_options.zjs_oom_coverage;

/// Does a collector in this build need to find an arena from an interior
/// pointer?
///
/// Only the tracing and shadow collectors scan conservatively, and only they
/// resolve a stack word against the heap. Refcounting never asks, so it should
/// not pay: self-aligned arenas, the `magic` word in the arena header, the
/// lifetime observer, and the class-byte stamps all exist for that one query.
/// Mirrors `gc.address_registry_enabled`, which cannot be imported here --
/// `gc.zig` depends on this module, not the other way round.
pub const arena_addressable: bool = std.mem.eql(u8, build_options.zjs_gc, "trace_stw") or
    std.mem.eql(u8, build_options.zjs_gc, "shadow") or
    builtin.is_test;
const trace_stw_enabled: bool = std.mem.eql(u8, build_options.zjs_gc, "trace_stw");
pub const force_gc_on_allocation_enabled: bool = build_options.zjs_force_gc;

/// Issue the next slab pop's block-header fetch one allocation early.
///
/// The free chain qjs threads through the free blocks themselves
/// (`JSMallocBlockHeader.u.next_block`, quickjs.c:275) costs one load per pop,
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
/// Measurements, and the two heavier designs this was chosen over, are in
/// `docs/slab-reuse-2026-08-29.md`.
const slab_alloc_prefetch: bool = trace_stw_enabled;

/// Compile in the slab free-list locality audit (`slab_locality_audit.zig`).
///
/// Measurement instrument, never `true` in the tree. The import is on the
/// taken side of a `comptime` branch so the file is not even parsed when this
/// is off -- parking the counters in this file instead moved the refcounting
/// build by 171 instructions with no semantic change, and this module is on
/// that build's hottest path.
pub const slab_locality_audit: bool = false;
const slab_audit = if (slab_locality_audit) @import("slab_locality_audit.zig") else struct {};

/// Whether an ordinary allocation consults the GC threshold at all.
///
/// QuickJS reaches its allocation-threshold GC from exactly one site:
/// `js_trigger_gc(ctx->rt, sizeof(JSObject))` at the top of
/// `JS_NewObjectFromShape` (quickjs.c:5619). The allocators underneath it —
/// `js_malloc_rt` / `js_realloc_rt` / `js_mallocz_rt` (quickjs.c:1799-1826)
/// and the `__js_malloc` family they call (quickjs.c:1566) — only ever check
/// `malloc_limit`; none of them reads `malloc_gc_threshold`, which is touched
/// exclusively by `js_trigger_gc` itself (quickjs.c:1780-1797). Property
/// arrays (quickjs.c:5636), bytecode buffers, atom tables and parser scratch
/// therefore carry no per-allocation GC bookkeeping in QuickJS at all.
///
/// zjs mirrors that shape: `JSRuntime.collectBeforeObjectAllocation` is the
/// single production threshold boundary. The condition is level-triggered on
/// `allocated_bytes`, and it is recomputed from scratch at that boundary and
/// again at every `pollGC` (`over_threshold` feeds `Registry.shouldRunMajorAt`),
/// so a crossing produced by a non-object allocation is still serviced at the
/// next boundary — exactly as a prop-array `js_malloc` crossing in qjs waits
/// for the next `js_trigger_gc`. Recording a request per allocation adds no
/// scheduling information those boundaries cannot recompute.
///
/// Test builds inject probes through `trigger_gc_fn` to observe allocation
/// events, and force-GC builds must still collect before every allocation, so
/// those comptime modes retain the full per-allocation trigger. This is the
/// same rule that already governs `JSRuntime.allocStringAlignedBytes`.
pub const allocation_gc_trigger_enabled: bool = builtin.is_test or force_gc_on_allocation_enabled;

/// qjs `MALLOC_OVERHEAD` (quickjs.c:59-62): 0 on Apple, 8 elsewhere.
/// Added to every `js_malloc` usable size in `js_def_malloc` (quickjs.c:2168).
pub const malloc_overhead: usize = if (builtin.os.tag.isDarwin()) 0 else 8;

const oom_coverage = struct {
    // Plain atomic spinlock: diagnostic instrumentation must not depend on
    // an Io handle (std.Io.Mutex) and contention is negligible (worker
    // threads only).
    var lock_state: std.atomic.Value(bool) = .init(false);
    var sites: std.AutoHashMapUnmanaged(usize, void) = .empty;

    fn lock() void {
        while (lock_state.swap(true, .acquire)) std.atomic.spinLoopHint();
    }

    fn unlock() void {
        lock_state.store(false, .release);
    }

    fn record(site: usize) void {
        lock();
        defer unlock();
        // Diagnostic-only bookkeeping: the set grows via page_allocator so
        // it never perturbs engine allocation counts; a failed insert just
        // drops one sample.
        sites.put(std.heap.page_allocator, site, {}) catch {};
    }
};

/// Print the slab locality report. Compiled out unless `slab_locality_audit`.
pub fn slabLocalityReport() void {
    if (comptime slab_locality_audit) slab_audit.dump();
}

/// Number of distinct allocation call sites observed since process start
/// (or the last `oomCoverageReset`). Always 0 when coverage is disabled.
pub fn oomCoverageDistinctSiteCount() usize {
    if (comptime !oom_coverage_enabled) return 0;
    oom_coverage.lock();
    defer oom_coverage.unlock();
    return oom_coverage.sites.count();
}

pub fn oomCoverageReset() void {
    if (comptime !oom_coverage_enabled) return;
    oom_coverage.lock();
    defer oom_coverage.unlock();
    oom_coverage.sites.clearRetainingCapacity();
}

pub const SmallObjectSlab = struct {
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
        if (arena_addressable) .fromByteUnits(arena_size) else slab_alignment;
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
    pub fn forEachArena(self: *SmallObjectSlab, context: *anyopaque, visit: *const fn (*anyopaque, usize) void) void {
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
        /// `JSMallocBlockHeader.block_size_idx` (quickjs.c:275) so a free never
        /// has to recompute the class from the byte size. GC allocations stamp
        /// it too (low 5 bits of `gc.Metadata.alloc_info`, written by
        /// initGcPrefix together with the kind/flags byte); GC tenants may also
        /// set the accounting bits in its high bits, so rather than qjs's
        /// write-once-per-arena (quickjs.c:1527), each allocation re-stamps the
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
        magic: if (arena_addressable) u32 else void = if (arena_addressable) arena_magic else {},
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
    /// accounting and limits still belong to MemoryAccount; this only keeps
    /// arena refills off glibc's high-alignment malloc path.
    arena_backing: if (arena_addressable) ?std.mem.Allocator else void =
        if (arena_addressable) null else {},
    /// Told when an arena is created or released, so the collector can keep a
    /// set of valid arena bases. Arena lifetime, not object lifetime: at 4 KiB
    /// per arena against ~64-byte objects this is roughly two orders of
    /// magnitude less traffic than registering each published object.
    arena_observer: if (arena_addressable) ?ArenaObserver else void =
        if (arena_addressable) null else {},

    pub inline fn canUse(byte_count: usize, alignment: std.mem.Alignment) bool {
        return classIndex(byte_count, alignment) != null;
    }

    pub fn setArenaBacking(self: *SmallObjectSlab, allocator: std.mem.Allocator) void {
        if (comptime !arena_addressable) return;
        for (self.arenas) |head| std.debug.assert(head == null);
        self.arena_backing = allocator;
    }

    /// Eligibility-only variant of `classIndex`: true iff that would return an
    /// index, without materializing the class arithmetic. Free paths pair this
    /// with `headerClassIndex` (qjs `__js_free` reads `b->block_size_idx`,
    /// quickjs.c:1614-1617, instead of re-deriving the class from the size).
    inline fn eligibleSize(byte_count: usize, alignment: std.mem.Alignment) bool {
        if (alignment.compare(.gt, slab_alignment)) return false;
        return totalBlockSize(byte_count) != null;
    }

    /// Class index carried by the block header of a slab-backed allocation.
    /// Only valid for blocks that are free or occupied by non-GC payloads
    /// (live GC blocks carry the class in the low 5 bits plus GC accounting
    /// bits above; their frees read it through `gcAllocInfoByte` instead).
    inline fn headerClassIndex(ptr: [*]u8) usize {
        return blockHeaderFromUser(ptr).block_size_idx;
    }

    /// qjs `__js_malloc_usable_size` small-block formula (quickjs.c:1722).
    pub inline fn usablePayloadFromClass(class: usize) usize {
        return block_sizes[class] - block_header_size;
    }

    pub inline fn alloc(self: *SmallObjectSlab, backing: std.mem.Allocator, byte_count: usize, alignment: std.mem.Alignment) ![*]u8 {
        const index = classIndex(byte_count, alignment).?;
        return self.allocAtIndex(backing, index, true);
    }

    /// `stamp_class` = the block will hold a raw (non-GC) payload, so record
    /// its class index in the header for `headerClassIndex` on the free side.
    /// GC objects skip the pop-time stamp only because initGcPrefix immediately
    /// rewrites the same byte with the identical class index (plus clear GC
    /// accounting bits) as part of its combined class+kind u16 store.
    inline fn allocAtIndex(self: *SmallObjectSlab, backing: std.mem.Allocator, index: usize, comptime stamp_class: bool) ![*]u8 {
        const arena = self.free_arenas[index] orelse try self.addArena(backing, index);
        return self.popFreeBlock(arena, index, stamp_class);
    }

    /// Hot small-block pop, mirroring the qjs `__js_malloc` small arm
    /// (quickjs.c:1566-1587): unlink the first free block, stamp its live
    /// block index, and retire the arena from the free list when it fills.
    inline fn popFreeBlock(self: *SmallObjectSlab, arena: *Arena, index: usize, comptime stamp_class: bool) [*]u8 {
        const block_size = block_sizes[index];
        const block_idx = arena.first_free_block;
        std.debug.assert(block_idx != free_nil);
        const header = blockHeaderAt(arena, block_idx, block_size);
        if (comptime slab_locality_audit) slab_audit.notePop(
            @intFromPtr(arena),
            @intFromPtr(header),
            @as(u64, arena.block_count) - @as(u64, arena.used_blocks),
            index,
        );
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

    pub inline fn free(self: *SmallObjectSlab, backing: std.mem.Allocator, bytes: []u8, alignment: std.mem.Alignment) void {
        const index = classIndex(bytes.len, alignment).?;
        self.freeAtIndex(&backing, bytes.ptr, index);
    }

    /// `backing` is taken by pointer so the hot free path materializes only an
    /// address; the 16-byte allocator value is loaded solely inside the cold
    /// empty-arena arm that actually calls it.
    inline fn freeAtIndex(self: *SmallObjectSlab, backing: *const std.mem.Allocator, ptr: [*]u8, index: usize) void {
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
        if (comptime slab_locality_audit) slab_audit.noteFree(@intFromPtr(arena), @intFromPtr(header), was_full, index, @as(u64, arena.block_count) - @as(u64, arena.used_blocks) + 1);
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
    /// (quickjs.c:1626-1630). Keeping a per-class reserve would leave physical
    /// backing alive after the runtime's logical/accounted bytes reached zero.
    /// Out of line so the per-free hot path stays call-free (the mirror of qjs
    /// keeping `js_malloc_new_arena` no_inline on the alloc side).
    noinline fn releaseEmptyArena(self: *SmallObjectSlab, backing: *const std.mem.Allocator, index: usize, arena: *Arena) void {
        if (comptime slab_locality_audit) slab_audit.noteArena(false, @intFromPtr(arena), index);
        self.removeArena(index, arena);
        self.removeFreeArena(index, arena);
        if (comptime arena_addressable) {
            if (self.arena_observer) |observer| observer.on_release(observer.ctx, @intFromPtr(arena));
            arena.magic = 0;
        }
        self.arenaBacking(backing.*).rawFree(arenaAllocation(arena), arena_alignment, @returnAddress());
    }

    pub fn deinit(self: *SmallObjectSlab, backing: std.mem.Allocator) void {
        if (comptime slab_locality_audit) slab_audit.dump();
        for (&self.arenas) |*head| {
            var arena = head.*;
            while (arena) |node| {
                arena = node.next;
                if (comptime arena_addressable) {
                    if (self.arena_observer) |observer| observer.on_release(observer.ctx, @intFromPtr(node));
                    node.magic = 0;
                }
                self.arenaBacking(backing).rawFree(arenaAllocation(node), arena_alignment, @returnAddress());
            }
        }
        self.* = .{};
    }

    /// qjs `js_malloc_new_arena` is no_inline (quickjs.c:1496); keeping the
    /// arena-construction loop out of the per-alloc hot functions saves their
    /// prologues from carrying its register pressure.
    noinline fn addArena(self: *SmallObjectSlab, backing: std.mem.Allocator, index: usize) !*Arena {
        const block_size = block_sizes[index];
        const block_count = (arena_size - arena_header_size) / block_size;
        std.debug.assert(block_count > 0 and block_count <= free_nil);
        const alloc_size = arena_header_size + block_count * block_size;
        const storage_ptr = self.arenaBacking(backing).rawAlloc(alloc_size, arena_alignment, @returnAddress()) orelse return error.OutOfMemory;
        if (comptime arena_addressable) std.debug.assert(@intFromPtr(storage_ptr) % arena_size == 0);
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
            if (comptime arena_addressable) header.block_size_idx = @intCast(index);
        }
        if (comptime slab_locality_audit) slab_audit.noteArena(true, @intFromPtr(arena), index);
        self.addArenaList(index, arena);
        self.addFreeArena(index, arena);
        if (comptime arena_addressable) {
            if (self.arena_observer) |observer| observer.on_create(observer.ctx, @intFromPtr(arena));
        }
        return arena;
    }

    inline fn classIndex(byte_count: usize, alignment: std.mem.Alignment) ?usize {
        if (alignment.compare(.gt, slab_alignment)) return null;
        const total_size = totalBlockSize(byte_count) orelse return null;
        return blockSizeIndex(total_size);
    }

    /// Map a required block size (<= `max_size`) to its `block_sizes` index by
    /// piecewise arithmetic instead of walking a fully-unrolled 31-rung linear
    /// `cmp` ladder. Faithful port of qjs `get_block_size_index`
    /// (quickjs.c:1453): the `block_sizes` table is byte-identical to qjs
    /// `js_malloc_block_sizes`, so the three arithmetic segments (step-8 up to
    /// 128, step-16 up to 256, step-32 up to 512) reproduce the exact same
    /// index the linear scan returned (verified by the comptime cross-check
    /// below). This collapses ~7-14 walked rungs (each `cmp`+`b.cs`+`adrp`+
    /// `add`+`b`) into a handful of `add`/`lsr`/`cmp` on every slab alloc/free.
    inline fn blockSizeIndex(total_size: usize) usize {
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

    inline fn totalBlockSize(byte_count: usize) ?usize {
        if (byte_count == 0) return null;
        const aligned_size = std.mem.alignForward(usize, byte_count, slab_alignment.toByteUnits());
        const total_size = std.math.add(usize, aligned_size, block_header_size) catch return null;
        if (total_size > max_size) return null;
        return total_size;
    }

    inline fn arenaBlocks(arena: *Arena) [*]u8 {
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
        if (comptime !arena_addressable) return null;
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
        if (comptime !arena_addressable) return;
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

    inline fn blockHeaderAt(arena: *Arena, block_idx: u16, block_size: usize) *BlockHeader {
        return @ptrCast(@alignCast(arenaBlocks(arena) + @as(usize, block_idx) * block_size));
    }

    inline fn blockHeaderFromUser(ptr: [*]u8) *BlockHeader {
        return @ptrFromInt(@intFromPtr(ptr) - block_header_size);
    }

    inline fn userData(header: *BlockHeader) [*]u8 {
        return @as([*]u8, @ptrCast(header)) + block_header_size;
    }

    inline fn arenaFromBlock(header: *BlockHeader, block_idx: u16, block_size: usize) *Arena {
        const arena_addr = @intFromPtr(header) - @as(usize, block_idx) * block_size - arena_header_size;
        return @ptrFromInt(arena_addr);
    }

    inline fn arenaAllocation(arena: *Arena) []u8 {
        const index = arena.block_size_idx;
        const alloc_size = arena_header_size + @as(usize, arena.block_count) * block_sizes[index];
        return @as([*]u8, @ptrCast(arena))[0..alloc_size];
    }

    inline fn arenaBacking(self: *const SmallObjectSlab, fallback: std.mem.Allocator) std.mem.Allocator {
        if (comptime arena_addressable) return self.arena_backing orelse fallback;
        return fallback;
    }

    fn addArenaList(self: *SmallObjectSlab, index: usize, arena: *Arena) void {
        arena.prev = null;
        arena.next = self.arenas[index];
        if (arena.next) |next| next.prev = arena;
        self.arenas[index] = arena;
    }

    fn removeArena(self: *SmallObjectSlab, index: usize, arena: *Arena) void {
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

    fn addFreeArena(self: *SmallObjectSlab, index: usize, arena: *Arena) void {
        if (comptime slab_locality_audit) slab_audit.noteFreeList(index, 1, @intFromPtr(arena));
        arena.free_prev = null;
        arena.free_next = self.free_arenas[index];
        if (arena.free_next) |next| next.free_prev = arena;
        self.free_arenas[index] = arena;
    }

    fn removeFreeArena(self: *SmallObjectSlab, index: usize, arena: *Arena) void {
        if (comptime slab_locality_audit) slab_audit.noteFreeList(index, -1, @intFromPtr(arena));
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

    fn debugArenaCount(self: SmallObjectSlab, index: usize) usize {
        var count: usize = 0;
        var arena = self.arenas[index];
        while (arena) |node| : (arena = node.next) count += 1;
        return count;
    }
};

pub const MemoryAccount = struct {
    /// Current operation allocator. Parser compilation temporarily redirects
    /// this to its result-owned arena; allocations kept beyond that operation
    /// must not use it.
    allocator: std.mem.Allocator,
    /// Stable allocator that owns runtime-resident state for the lifetime of
    /// this account. A live JSRuntime rebinds this to `accountedAllocator()` so
    /// long-lived unmanaged containers cannot bypass the runtime limit.
    persistent_allocator: std.mem.Allocator,
    /// Actual allocator supplied by the embedder. MemoryAccount internals must
    /// use this field, never the public accounting facades above, or they would
    /// recurse back through their own vtable.
    backing_allocator: std.mem.Allocator,
    small_slab: SmallObjectSlab = .{},
    small_slab_enabled: bool = false,
    /// qjs `malloc_state.malloc_size`. Slab blocks charge class size
    /// (`usable + MALLOC_OVERHEAD`, quickjs.c:2168/1740); standalone charges
    /// the backing request.
    allocated_bytes: usize = 0,
    allocation_count: usize = 0,
    peak_allocated_bytes: usize = 0,
    peak_allocation_count: usize = 0,
    /// Optional destination for §1.3's same-domain cycle peak. Installed from
    /// the settled S/T reset through the next incremental cycle's completion;
    /// null keeps an ordinary tracing run to one predictable branch per
    /// account credit.
    cycle_peak_output: if (cycle_envelope_tracking_available) ?*usize else void =
        if (cycle_envelope_tracking_available) null else {},
    alloc_calls: usize = 0,
    free_calls: usize = 0,
    create_calls: usize = 0,
    destroy_calls: usize = 0,
    limit: ?usize = null,
    trace_writer: ?*std.Io.Writer = null,
    trace_failed: bool = false,
    profile_alloc_count: ?*u64 = null,
    /// Concrete block heap used for tracing collector Object cells. The
    /// collector choice is compile-time-known, so the trace build calls the
    /// allocator directly and the default RC build carries neither this
    /// pointer nor a dead nullable-function-pointer branch. The Object kind's
    /// byte encoding is part of the shared allocator representation above.
    gc_object_cell_heap: if (block_heap_enabled) ?*gc_block_heap.Heap else void =
        if (block_heap_enabled) null else {},

    trigger_gc_fn: ?*const fn (ctx: ?*anyopaque, size: usize) void = null,
    trigger_gc_ctx: ?*anyopaque = null,
    /// Collect-and-retry hook for an allocation that would cross `limit`.
    ///
    /// Under refcounting, crossing the limit really does mean out of memory:
    /// everything unreachable has already been freed. Under the tracer,
    /// garbage accumulates by design until a collection runs, so rejecting the
    /// allocation without collecting first reports OOM for a heap that is
    /// mostly garbage. Installed only by the tracing build; null elsewhere, so
    /// the refcounting limit behaviour is bit-for-bit what it was.
    limit_gc_fn: ?*const fn (ctx: *anyopaque) void = null,
    /// Deliberately separate from `trigger_gc_ctx`: tests repoint that one at
    /// their own allocation probes, and this hook must keep reaching the
    /// runtime.
    limit_gc_ctx: ?*anyopaque = null,

    pub fn init(allocator: std.mem.Allocator) MemoryAccount {
        return .{ .allocator = allocator, .persistent_allocator = allocator, .backing_allocator = allocator };
    }

    /// qjs `js_def_malloc` / `js_def_free` (quickjs.c:2168/2178):
    /// `malloc_size ±= js_def_malloc_usable_size(ptr) + MALLOC_OVERHEAD`.
    ///
    /// Slab: `__js_malloc_usable_size` is `block_size - header`
    /// (quickjs.c:1740-1741). Plus `MALLOC_OVERHEAD` that equals the class
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

    inline fn creditAlloc(self: *MemoryAccount, request_bytes: usize, slab_class: ?usize) void {
        self.allocated_bytes +%= accountedMallocSize(request_bytes, slab_class);
        self.noteCyclePeak();
    }

    inline fn debitAlloc(self: *MemoryAccount, request_bytes: usize, slab_class: ?usize) void {
        self.allocated_bytes -%= accountedMallocSize(request_bytes, slab_class);
    }

    pub fn initWithTrace(allocator: std.mem.Allocator, writer: *std.Io.Writer) MemoryAccount {
        return .{ .allocator = allocator, .persistent_allocator = allocator, .backing_allocator = allocator, .trace_writer = writer };
    }

    /// Rebind the public current/persistent allocators after MemoryAccount has
    /// reached its stable address inside JSRuntime. The facade stores `self` in
    /// its allocator context, so doing this to the temporary value returned by
    /// `init` would leave a dangling context after that value is copied.
    pub fn activateRuntimeAccounting(self: *MemoryAccount) void {
        const facade = self.accountedAllocator();
        self.allocator = facade;
        self.persistent_allocator = facade;
    }

    /// Standard allocator facade whose allocations participate in this
    /// account's limit, live-byte count, tracing, and slab policy. Use this for
    /// library value types (notably BigInt limbs) that need to retain a
    /// `std.mem.Allocator` for later realloc/free. `backing_allocator` remains
    /// the unwrapped allocator used internally by this facade.
    pub fn accountedAllocator(self: *MemoryAccount) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &accounted_allocator_vtable,
        };
    }

    const accounted_allocator_vtable: std.mem.Allocator.VTable = .{
        .alloc = accountedAllocatorAlloc,
        .resize = accountedAllocatorResize,
        .remap = accountedAllocatorRemap,
        .free = accountedAllocatorFree,
    };

    fn accountedAllocatorAlloc(
        context: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) ?[*]u8 {
        _ = return_address;
        const self: *MemoryAccount = @ptrCast(@alignCast(context));
        // Raw library/container allocation is accounted but is not a new GC
        // safepoint. Object creation owns the QuickJS-aligned threshold trigger.
        const allocation = self.allocAlignedBytesNoTrigger(len, alignment) catch return null;
        return allocation.ptr;
    }

    fn accountedAllocatorResize(
        context: *anyopaque,
        bytes: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) bool {
        const self: *MemoryAccount = @ptrCast(@alignCast(context));
        if (new_len == bytes.len) return true;
        if (self.small_slab_enabled and
            (SmallObjectSlab.canUse(bytes.len, alignment) or SmallObjectSlab.canUse(new_len, alignment)))
        {
            return false;
        }
        if (new_len > bytes.len) {
            const growth = new_len - bytes.len;
            self.checkAllocation(growth) catch return false;
        }
        if (!self.backing_allocator.rawResize(bytes, alignment, new_len, return_address)) return false;
        self.recordAccountedResize(bytes.len, new_len);
        return true;
    }

    fn accountedAllocatorRemap(
        context: *anyopaque,
        bytes: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) ?[*]u8 {
        const self: *MemoryAccount = @ptrCast(@alignCast(context));
        if (new_len == bytes.len) return bytes.ptr;
        if (self.small_slab_enabled and
            (SmallObjectSlab.canUse(bytes.len, alignment) or SmallObjectSlab.canUse(new_len, alignment)))
        {
            return null;
        }
        if (new_len > bytes.len) {
            const growth = new_len - bytes.len;
            self.checkAllocation(growth) catch return null;
        }
        const remapped = self.backing_allocator.rawRemap(bytes, alignment, new_len, return_address) orelse return null;
        if (comptime diagnostic_accounting_enabled) {
            if (remapped != bytes.ptr) {
                self.traceFree(@intFromPtr(bytes.ptr));
                self.traceAlloc(1, new_len, @intFromPtr(remapped));
            }
        }
        self.recordAccountedResize(bytes.len, new_len);
        return remapped;
    }

    fn accountedAllocatorFree(
        context: *anyopaque,
        bytes: []u8,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) void {
        _ = return_address;
        const self: *MemoryAccount = @ptrCast(@alignCast(context));
        self.freeAlignedBytes(bytes, alignment);
    }

    fn recordAccountedResize(self: *MemoryAccount, old_len: usize, new_len: usize) void {
        if (new_len > old_len) {
            self.allocated_bytes += new_len - old_len;
        } else {
            self.allocated_bytes -= old_len - new_len;
        }
        self.noteCyclePeak();
        if (comptime diagnostic_accounting_enabled) self.updatePeak();
    }

    /// Returns owned memory. Caller must free it with `free`.
    pub inline fn alloc(self: *MemoryAccount, comptime T: type, count: usize) ![]T {
        return self.allocInternal(T, count, true);
    }

    /// Runtime hot path variant. The owning runtime performs a direct GC
    /// threshold check before entering, avoiding the nullable trigger callback.
    pub inline fn allocNoTrigger(self: *MemoryAccount, comptime T: type, count: usize) ![]T {
        return self.allocInternal(T, count, false);
    }

    /// Pop a block from an already-available free arena of `index`'s class, or
    /// null when the class has no free arena (caller falls back to the slow
    /// twin, which builds a new arena / routes to the backing allocator).
    /// Inline: this is the entire qjs `__js_malloc` small-block hot arm.
    inline fn slabPopHot(self: *MemoryAccount, index: usize, comptime stamp_class: bool) ?[*]u8 {
        const arena = self.small_slab.free_arenas[index] orelse return null;
        return self.small_slab.popFreeBlock(arena, index, stamp_class);
    }

    inline fn noteAllocDiagnostics(
        self: *MemoryAccount,
        comptime is_create: bool,
        comptime element_size: usize,
        count: usize,
        address: usize,
    ) void {
        if (comptime diagnostic_accounting_enabled) {
            self.allocation_count += 1;
            if (comptime is_create) {
                self.create_calls += 1;
            } else {
                self.alloc_calls += 1;
            }
            self.updatePeak();
            if (self.profile_alloc_count) |counter| counter.* +|= 1;
            self.traceAlloc(element_size, count, address);
        }
    }

    inline fn noteFreeDiagnostics(self: *MemoryAccount, comptime is_destroy: bool) void {
        if (comptime diagnostic_accounting_enabled) {
            self.allocation_count -= 1;
            if (comptime is_destroy) {
                self.destroy_calls += 1;
            } else {
                self.free_calls += 1;
            }
        }
    }

    fn allocInternal(self: *MemoryAccount, comptime T: type, count: usize, comptime trigger_gc: bool) ![]T {
        if (comptime oom_coverage_enabled) oom_coverage.record(@returnAddress());
        if (count == 0) return &.{};
        // GC objects are allocated singly. Slab-backed objects reuse the slab's
        // existing 8-byte block header for their metadata; persistent/over-
        // aligned allocations keep the standalone prefix.
        const is_gc = comptime isGcObject(T);
        if (comptime is_gc) std.debug.assert(count == 1);
        // Inline hot arm = qjs `__js_malloc` small-block path (quickjs.c:1566):
        // limit check + block pop + single-scalar ledger bump. Arena refill and
        // the backing/standalone-prefix routes live in the noinline slow twin
        // (qjs keeps `js_malloc_new_arena` / `js_malloc_large` no_inline too).
        if (comptime is_gc) {
            const slab_class = comptime SmallObjectSlab.classIndex(@sizeOf(T), gcAlignment(T));
            if (comptime slab_class != null) {
                if (self.small_slab_enabled) {
                    const bytes: usize = @sizeOf(T);
                    try self.checkAllocation(bytes);
                    if (comptime trigger_gc) self.triggerGCBeforeAllocation(bytes);
                    const raw = self.slabPopHot(comptime slab_class.?, false) orelse
                        return self.allocInternalSlow(T, count, trigger_gc);
                    initGcPrefix(T, @ptrFromInt(@intFromPtr(raw) - gc_prefix_size), comptime slab_class.?);
                    self.creditAlloc(bytes, comptime slab_class);
                    self.noteAllocDiagnostics(false, @sizeOf(T), count, @intFromPtr(raw));
                    const ptr: [*]T = @ptrCast(@alignCast(raw));
                    return ptr[0..count];
                }
            }
        } else {
            const payload_bytes = std.math.mul(usize, @sizeOf(T), count) catch return error.OutOfMemory;
            if (self.small_slab_enabled) {
                if (SmallObjectSlab.classIndex(payload_bytes, std.mem.Alignment.of(T))) |slab_class| {
                    try self.checkAllocation(payload_bytes);
                    if (comptime trigger_gc) self.triggerGCBeforeAllocation(payload_bytes);
                    const raw = self.slabPopHot(slab_class, true) orelse
                        return self.allocInternalSlow(T, count, trigger_gc);
                    self.creditAlloc(payload_bytes, slab_class);
                    self.noteAllocDiagnostics(false, @sizeOf(T), count, @intFromPtr(raw));
                    const ptr: [*]T = @ptrCast(@alignCast(raw));
                    return ptr[0..count];
                }
            }
        }
        return self.allocInternalSlow(T, count, trigger_gc);
    }

    /// Cold continuation of `allocInternal`: arena refill, non-slab classes,
    /// and the slab-disabled/standalone-prefix routes. Re-running the limit
    /// check (and, on refill, the GC trigger request) here is idempotent.
    noinline fn allocInternalSlow(self: *MemoryAccount, comptime T: type, count: usize, comptime trigger_gc: bool) ![]T {
        const is_gc = comptime isGcObject(T);
        if (comptime is_gc) std.debug.assert(count == 1);
        const payload_bytes = std.math.mul(usize, @sizeOf(T), count) catch return error.OutOfMemory;
        const alignment = if (comptime is_gc) gcAlignment(T) else std.mem.Alignment.of(T);
        const slab_index = if (self.small_slab_enabled) SmallObjectSlab.classIndex(payload_bytes, alignment) else null;
        const prefix = if (comptime is_gc) (if (slab_index != null) 0 else gcPrefixSize(T)) else 0;
        const bytes = prefix + payload_bytes;
        try self.checkAllocation(bytes);
        if (comptime trigger_gc) {
            self.triggerGCBeforeAllocation(bytes);
        }
        const raw = if (comptime is_gc)
            try self.rawAllocForGc(bytes, alignment, slab_index)
        else
            try self.rawAlloc(bytes, alignment);
        const obj_addr = @intFromPtr(raw) + prefix;
        if (comptime is_gc) initGcPrefix(T, @ptrFromInt(obj_addr - gc_prefix_size), slab_index);
        const ptr: [*]T = if (comptime is_gc)
            @ptrFromInt(obj_addr)
        else
            @ptrCast(@alignCast(raw));
        const slice = ptr[0..count];
        self.creditAlloc(if (slab_index != null) payload_bytes else bytes, slab_index);
        self.noteAllocDiagnostics(false, @sizeOf(T), count, @intFromPtr(slice.ptr));
        return slice;
    }

    pub fn free(self: *MemoryAccount, comptime T: type, slice: []T) void {
        if (slice.len == 0) return;
        if (comptime diagnostic_accounting_enabled) self.traceFree(@intFromPtr(slice.ptr));
        const is_gc = comptime isGcObject(T);
        // GC objects are allocated singly (`allocInternal` asserts count == 1),
        // so their payload size is comptime-known here.
        if (comptime is_gc) std.debug.assert(slice.len == 1);
        // The alloc side validated this product with a checked multiply; qjs
        // `__js_free` (quickjs.c:1595) recomputes nothing on free.
        const payload_bytes = if (comptime is_gc) @sizeOf(T) else @sizeOf(T) *% slice.len;
        const alignment = if (comptime is_gc) gcAlignment(T) else std.mem.Alignment.of(T);
        const bytes_ptr: [*]u8 = @ptrCast(slice.ptr);
        if (comptime is_gc) {
            const slab_class = comptime SmallObjectSlab.classIndex(@sizeOf(T), gcAlignment(T));
            if (comptime slab_class != null) {
                if (self.small_slab_enabled) {
                    std.debug.assert(gcAllocInfoByte(bytes_ptr) & (alloc_info_standalone | alloc_info_class_mask) == comptime slab_class.?);
                    self.debitAlloc(payload_bytes, comptime slab_class);
                    self.noteFreeDiagnostics(false);
                    return self.small_slab.freeAtIndex(&self.backing_allocator, bytes_ptr, comptime slab_class.?);
                }
            }
            const prefix = comptime gcPrefixSize(T);
            const bytes = prefix + payload_bytes;
            self.debitAlloc(bytes, null);
            self.noteFreeDiagnostics(false);
            const base: [*]u8 = @ptrFromInt(@intFromPtr(slice.ptr) - prefix);
            return self.backing_allocator.rawFree(base[0..bytes], alignment, @returnAddress());
        }
        self.noteFreeDiagnostics(false);
        if (self.small_slab_enabled and SmallObjectSlab.eligibleSize(payload_bytes, alignment)) {
            // The runtime enables the slab before managed allocations begin;
            // while enabled, every eligible allocation comes from it. Non-GC
            // blocks keep the allocator's class byte, so read it back instead
            // of re-deriving the class (qjs __js_free, quickjs.c:1614).
            const slab_class = SmallObjectSlab.headerClassIndex(bytes_ptr);
            std.debug.assert(slab_class == SmallObjectSlab.classIndex(payload_bytes, alignment).?);
            self.debitAlloc(payload_bytes, slab_class);
            return self.small_slab.freeAtIndex(&self.backing_allocator, bytes_ptr, slab_class);
        }
        self.debitAlloc(payload_bytes, null);
        self.backing_allocator.rawFree(bytes_ptr[0..payload_bytes], alignment, @returnAddress());
    }

    /// Attempts to resize an existing allocation through the backing allocator's
    /// remap/realloc primitive. Returns null when the allocation is slab-backed
    /// or when the allocator cannot grow it without a caller-managed copy.
    pub fn remap(self: *MemoryAccount, comptime T: type, slice: []T, new_count: usize) !?[]T {
        if (slice.len == 0) return null;
        if (new_count == 0) {
            self.free(T, slice);
            return &.{};
        }
        const old_bytes = std.math.mul(usize, @sizeOf(T), slice.len) catch return error.OutOfMemory;
        const new_bytes = std.math.mul(usize, @sizeOf(T), new_count) catch return error.OutOfMemory;
        if (new_bytes == old_bytes) return slice.ptr[0..new_count];
        if (new_bytes > old_bytes) try self.checkAllocation(new_bytes - old_bytes);
        const alignment = std.mem.Alignment.of(T);
        if (self.small_slab_enabled and
            (SmallObjectSlab.canUse(old_bytes, alignment) or SmallObjectSlab.canUse(new_bytes, alignment)))
        {
            return null;
        }
        const old_raw: []u8 = @as([*]u8, @ptrCast(slice.ptr))[0..old_bytes];
        const remapped_ptr = self.backing_allocator.rawRemap(old_raw, alignment, new_bytes, @returnAddress()) orelse return null;
        if (new_bytes > old_bytes) {
            self.allocated_bytes += new_bytes - old_bytes;
        } else {
            self.allocated_bytes -= old_bytes - new_bytes;
        }
        self.noteCyclePeak();
        if (comptime diagnostic_accounting_enabled) {
            if (remapped_ptr != old_raw.ptr) {
                self.traceFree(@intFromPtr(old_raw.ptr));
                self.traceAlloc(@sizeOf(T), new_count, @intFromPtr(remapped_ptr));
            }
            self.updatePeak();
        }
        const new_ptr: [*]T = @ptrCast(@alignCast(remapped_ptr));
        return new_ptr[0..new_count];
    }

    pub fn allocAlignedBytes(self: *MemoryAccount, byte_count: usize, alignment: std.mem.Alignment) ![]u8 {
        return self.allocAlignedBytesInternal(byte_count, alignment, true);
    }

    /// Runtime hot path variant. The owning runtime performs a direct GC
    /// threshold check before entering, avoiding the nullable trigger callback.
    pub fn allocAlignedBytesNoTrigger(self: *MemoryAccount, byte_count: usize, alignment: std.mem.Alignment) ![]u8 {
        return self.allocAlignedBytesInternal(byte_count, alignment, false);
    }

    fn allocAlignedBytesInternal(self: *MemoryAccount, byte_count: usize, alignment: std.mem.Alignment, comptime trigger_gc: bool) ![]u8 {
        if (comptime oom_coverage_enabled) oom_coverage.record(@returnAddress());
        if (byte_count == 0) return &.{};
        try self.checkAllocation(byte_count);
        if (comptime trigger_gc) {
            self.triggerGCBeforeAllocation(byte_count);
        }
        var next_allocated_bytes: usize = undefined;
        // The accounting classification and `rawAlloc`'s classification are the
        // same `classIndex` call on the same two arguments, run twice. The
        // index is on the address-dependency chain of the arena free-list load
        // that carries ~78% of this function's cycles, so the duplicate is
        // both wasted work and delay in front of the miss.
        //
        // The answer is carried as an index-or-`class_count` sentinel rather
        // than an `?usize`: with the optional live across the account update,
        // LLVM sank it to memory and the function got *longer* than the version
        // that recomputed. The sentinel keeps it in one register.
        //
        // Kept behind the tracing build so the default RC `.text` stays
        // byte-identical to the branch point; this is a tracing-gap knife, not
        // a shared-allocator change.
        const ptr = if (comptime trace_stw_enabled) blk: {
            // The sentinel must be outside the class index domain, otherwise a
            // real class would be mistaken for "not slab-backed".
            comptime std.debug.assert(
                SmallObjectSlab.blockSizeIndex(SmallObjectSlab.max_size) < SmallObjectSlab.class_count,
            );
            const slab_class = self.rawSlabClass(byte_count, alignment) orelse SmallObjectSlab.class_count;
            const accounted = if (slab_class < SmallObjectSlab.class_count)
                accountedMallocSize(byte_count, slab_class)
            else
                byte_count;
            next_allocated_bytes = std.math.add(usize, self.allocated_bytes, accounted) catch
                return error.OutOfMemory;
            if (slab_class < SmallObjectSlab.class_count) {
                break :blk try self.small_slab.allocAtIndex(self.backing_allocator, slab_class, true);
            }
            break :blk self.backing_allocator.rawAlloc(byte_count, alignment, @returnAddress()) orelse
                return error.OutOfMemory;
        } else blk: {
            const slab_class = if (self.small_slab_enabled) SmallObjectSlab.classIndex(byte_count, alignment) else null;
            const accounted = accountedMallocSize(byte_count, slab_class);
            next_allocated_bytes = std.math.add(usize, self.allocated_bytes, accounted) catch
                return error.OutOfMemory;
            break :blk try self.rawAlloc(byte_count, alignment);
        };
        self.allocated_bytes = next_allocated_bytes;
        self.noteCyclePeak();
        if (comptime diagnostic_accounting_enabled) {
            self.allocation_count += 1;
            self.alloc_calls += 1;
            self.updatePeak();
            if (self.profile_alloc_count) |counter| counter.* +|= 1;
            self.traceAlloc(1, byte_count, @intFromPtr(ptr));
        }
        return ptr[0..byte_count];
    }

    pub fn freeAlignedBytes(self: *MemoryAccount, bytes: []u8, alignment: std.mem.Alignment) void {
        if (bytes.len == 0) return;
        if (comptime diagnostic_accounting_enabled) self.traceFree(@intFromPtr(bytes.ptr));
        if (comptime diagnostic_accounting_enabled) {
            self.allocation_count -= 1;
            self.free_calls += 1;
        }
        if (self.small_slab_enabled and SmallObjectSlab.eligibleSize(bytes.len, alignment)) {
            const index = SmallObjectSlab.headerClassIndex(bytes.ptr);
            std.debug.assert(index == SmallObjectSlab.classIndex(bytes.len, alignment).?);
            self.debitAlloc(bytes.len, index);
            self.small_slab.freeAtIndex(&self.backing_allocator, bytes.ptr, index);
            return;
        }
        self.debitAlloc(bytes.len, null);
        self.backing_allocator.rawFree(bytes, alignment, @returnAddress());
    }

    /// Returns owned memory. Caller must destroy it with `destroy`.
    pub inline fn create(self: *MemoryAccount, comptime T: type) !*T {
        return self.createInternal(T, true);
    }

    /// Runtime hot path variant. The owning runtime performs a direct GC
    /// threshold check before entering, avoiding the nullable trigger callback.
    pub inline fn createNoTrigger(self: *MemoryAccount, comptime T: type) !*T {
        return self.createInternal(T, false);
    }

    /// Size of GC metadata immediately before every GC object. Small slab
    /// allocations overlay it on the slab block header; other allocations
    /// reserve a standalone prefix. MUST equal `@sizeOf(gc.Metadata)`.
    const gc_prefix_size: usize = gc_representation.metadata_size;

    /// A GC object is any tagged struct whose first field is either the RC
    /// 16-byte intrusive header or the trace-only compact 8-byte successor.
    /// This module stays below gc.zig, so it recognizes the structural ABI
    /// instead of importing the selected Header alias.
    inline fn isGcObject(comptime T: type) bool {
        if (@typeInfo(T) != .@"struct") return false;
        if (!@hasDecl(T, "gc_kind_tag")) return false;
        if (!@hasField(T, "header")) return false;
        if (@offsetOf(T, "header") != 0) return false;
        const H = @FieldType(T, "header");
        if (@typeInfo(H) != .@"struct" or !@hasField(H, "next")) return false;
        return (@hasField(H, "prev") and @sizeOf(H) == 16) or
            (!@hasField(H, "prev") and @sizeOf(H) == 8);
    }

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

    inline fn gcSlabClassIndex(self: *const MemoryAccount, payload_bytes: usize, alignment: std.mem.Alignment) ?usize {
        if (!self.small_slab_enabled) return null;
        return SmallObjectSlab.classIndex(payload_bytes, alignment);
    }

    inline fn rawAllocForGc(self: *MemoryAccount, bytes: usize, alignment: std.mem.Alignment, slab_index: ?usize) ![*]u8 {
        if (slab_index) |index| return self.small_slab.allocAtIndex(self.backing_allocator, index, false);
        return self.backing_allocator.rawAlloc(bytes, alignment, @returnAddress()) orelse error.OutOfMemory;
    }

    /// `alloc_info` value marking a GC object served from the collector's
    /// block heap rather than the slab: class field saturated (31, one past
    /// the slab's 30 real classes), large/accounted/standalone bits all zero
    /// -- which is exactly what the account's existing branches need to do
    /// nothing special with it. The cell is `[8B metadata prefix][object]`,
    /// 16-aligned, and `destroy` routes on this byte back to the block heap.
    pub const alloc_info_block_cell: u8 = gc_representation.block_cell_alloc_info;

    /// Byte 2 of the GC prefix (`gc.Metadata.alloc_info`): bits 0..4 slab
    /// class index, bit 6 heap-accounted (registry-owned), bit 7 standalone
    /// prefix. Bit positions are asserted against gc.AllocInfo in gc.zig.
    const alloc_info_standalone: u8 = gc_representation.alloc_info_standalone_mask;
    const alloc_info_class_mask: u8 = gc_representation.alloc_info_class_mask;

    /// Reads back byte 2 of a live GC object's prefix. For slab-backed objects
    /// it carries the allocator's class index (qjs `__js_free` reads
    /// `b->block_size_idx`, quickjs.c:1614-1617, instead of re-deriving the
    /// class); for standalone prefixes bit 7 is set.
    inline fn gcAllocInfoByte(ptr: *const anyopaque) u8 {
        return @as(*const u8, @ptrFromInt(@intFromPtr(ptr) - gc_prefix_size + 2)).*;
    }

    /// Initialize GC metadata at `meta` (= objectPtr - 8). Bytes 0..2 are the
    /// slab allocator's live block index when the metadata is overlaid, so that
    /// case must preserve them. `slab_class` = the slab size-class backing this
    /// allocation (null = standalone prefix); it lands in the alloc_info byte,
    /// mirroring qjs `JSMallocBlockHeader`'s adjacent block_size_idx +
    /// gc_obj_type:7|mark:1 bytes (quickjs.c:275-277) with one u16 store.
    /// Prefix writer for a block-heap cell: same field layout as
    /// `initGcPrefix`, info byte fixed to the block-cell marker.
    inline fn initGcPrefixBlockCell(comptime T: type, meta: [*]u8) void {
        comptime std.debug.assert(T.gc_kind_tag < 8);
        // Bytes 0..2 carry the CELL INDEX, stamped by the block allocator so
        // the mark accessors never pay the non-power-of-two division on the
        // trace's hottest path. Preserved here, not zeroed.
        std.mem.writeInt(u16, meta[2..4], @as(u16, alloc_info_block_cell) | (@as(u16, T.gc_kind_tag) << 8), .little);
        // trace header state: newborn epoch 0, Object Shape summary zero,
        // husk/reserved clear.
        @as(*align(4) u32, @ptrCast(@alignCast(meta + 4))).* = 0;
    }

    inline fn initGcPrefix(comptime T: type, meta: [*]u8, slab_class: ?usize) void {
        // The kind must stay inside the low 3 bits of the shared kind/flags
        // byte (gc.BlockFlags.kind).
        comptime std.debug.assert(T.gc_kind_tag < 8);
        // Exact-value stores (no memset-then-overwrite): size_class (bytes
        // 0..2, preserved when the slab header is overlaid), alloc_info + kind
        // as one u16 (byte order fixed by the gc.zig offset asserts), and the
        // lifetime word at offset 4. Default RC/shadow and trace BigInt need a
        // native i32 count of 1; trace-owned carriers must start with an all-
        // zero epoch/state word so publication can prove newborn/unmarked.
        if (slab_class == null) std.mem.writeInt(u16, meta[0..2], 0, .little);
        if (slab_class) |index| std.debug.assert(index <= alloc_info_class_mask);
        const info: u8 = if (slab_class) |index| @intCast(index) else alloc_info_standalone;
        std.mem.writeInt(u16, meta[2..4], @as(u16, info) | (@as(u16, T.gc_kind_tag) << 8), .little);
        const initial_lifetime_word: u32 = if (trace_stw_enabled and T.gc_kind_tag != 7) 0 else 1;
        @as(*align(4) u32, @ptrCast(@alignCast(meta + 4))).* = initial_lifetime_word;
    }

    fn createInternal(self: *MemoryAccount, comptime T: type, comptime trigger_gc: bool) !*T {
        if (comptime oom_coverage_enabled) oom_coverage.record(@returnAddress());
        const is_gc = comptime isGcObject(T);
        // Inline hot arm = qjs `__js_malloc` small-block path (quickjs.c:1566);
        // everything else (arena refill, slab-disabled, standalone prefix,
        // non-slab classes) lives in the noinline slow twin.
        const slab_class = comptime SmallObjectSlab.classIndex(
            @sizeOf(T),
            if (is_gc) gcAlignment(T) else std.mem.Alignment.of(T),
        );
        // Collector-served cell: the tracing build routes fixed-size objects
        // of the selected kind directly to its block heap. The build-mode arm
        // is comptime-eliminated in RC; the direct call also lets the compiler
        // specialize the block size class for fixed-size Object allocations.
        if (comptime block_heap_enabled and is_gc) {
            if (comptime T.gc_kind_tag == gc_representation.object_kind_tag) {
                if (comptime gc_block_heap.canAllocCellSize(gc_prefix_size + @sizeOf(T))) {
                    if (self.gc_object_cell_heap) |heap| {
                        const bytes: usize = @sizeOf(T);
                        try self.checkAllocation(bytes);
                        if (comptime trigger_gc) self.triggerGCBeforeAllocation(bytes);
                        if (heap.allocCellFixedPtr(gc_prefix_size + bytes)) |cell| {
                            initGcPrefixBlockCell(T, cell);
                            // Slab accounting parity: the ledger records the
                            // object's size, never the prefix -- the heap-account
                            // verifier derives its expectation from
                            // `allocationSize`, and an 8-byte skew per object is
                            // a HeapLiveBytesMismatch on the first audit.
                            self.creditAlloc(bytes, null);
                            self.noteAllocDiagnostics(true, @sizeOf(T), 1, @intFromPtr(cell) + gc_prefix_size);
                            return @ptrFromInt(@intFromPtr(cell) + gc_prefix_size);
                        }
                        // Block heap declined (OOM in its backing): the slab
                        // still serves, which is the graceful direction.
                    }
                }
            }
        }
        if (comptime slab_class != null) {
            if (self.small_slab_enabled) {
                const bytes: usize = @sizeOf(T);
                try self.checkAllocation(bytes);
                if (comptime trigger_gc) self.triggerGCBeforeAllocation(bytes);
                const raw = self.slabPopHot(comptime slab_class.?, !is_gc) orelse
                    return self.createInternalSlow(T, trigger_gc);
                if (comptime is_gc) initGcPrefix(T, @ptrFromInt(@intFromPtr(raw) - gc_prefix_size), comptime slab_class.?);
                self.creditAlloc(bytes, comptime slab_class);
                self.noteAllocDiagnostics(true, @sizeOf(T), 1, @intFromPtr(raw));
                return @ptrCast(@alignCast(raw));
            }
        }
        return self.createInternalSlow(T, trigger_gc);
    }

    /// Cold continuation of `createInternal`: arena refill, non-slab classes,
    /// and the slab-disabled/standalone-prefix routes. Re-running the limit
    /// check (and, on refill, the GC trigger request) here is idempotent.
    noinline fn createInternalSlow(self: *MemoryAccount, comptime T: type, comptime trigger_gc: bool) !*T {
        const is_gc = comptime isGcObject(T);
        const alignment = if (comptime is_gc) gcAlignment(T) else std.mem.Alignment.of(T);
        const slab_index = if (self.small_slab_enabled) SmallObjectSlab.classIndex(@sizeOf(T), alignment) else null;
        const prefix = if (comptime is_gc) (if (slab_index != null) 0 else gcPrefixSize(T)) else 0;
        const bytes = prefix + @sizeOf(T);
        try self.checkAllocation(bytes);
        if (comptime trigger_gc) {
            self.triggerGCBeforeAllocation(bytes);
        }
        const raw = if (comptime is_gc)
            try self.rawAllocForGc(bytes, alignment, slab_index)
        else
            try self.rawAlloc(bytes, alignment);
        const obj_addr = @intFromPtr(raw) + prefix;
        if (comptime is_gc) initGcPrefix(T, @ptrFromInt(obj_addr - gc_prefix_size), slab_index);
        const ptr: *T = if (comptime is_gc)
            @ptrFromInt(obj_addr)
        else
            @ptrCast(@alignCast(raw));
        self.creditAlloc(if (slab_index != null) @sizeOf(T) else bytes, slab_index);
        self.noteAllocDiagnostics(true, @sizeOf(T), 1, @intFromPtr(ptr));
        return ptr;
    }

    pub fn destroy(self: *MemoryAccount, comptime T: type, ptr: *T) void {
        if (comptime diagnostic_accounting_enabled) self.traceFree(@intFromPtr(ptr));
        const is_gc = comptime isGcObject(T);
        const alignment = if (comptime is_gc) gcAlignment(T) else std.mem.Alignment.of(T);
        const bytes_ptr: [*]u8 = @ptrCast(ptr);
        // Collector-served cell goes home first: the marker byte is in the
        // prefix this free is already about to touch.
        if (comptime block_heap_enabled and is_gc) {
            if (gcAllocInfoByte(ptr) == alloc_info_block_cell) {
                if (self.gc_object_cell_heap) |heap| {
                    const bytes: usize = @sizeOf(T);
                    self.debitAlloc(bytes, null);
                    self.noteFreeDiagnostics(true);
                    heap.freeSmallCell(@ptrFromInt(@intFromPtr(ptr) - gc_prefix_size));
                    return;
                }
            }
        }
        // Straight-line slab arm mirroring qjs `__js_free`'s small-block path
        // (quickjs.c:1613); the class index is comptime for a sized type.
        const slab_class = comptime SmallObjectSlab.classIndex(@sizeOf(T), if (is_gc) gcAlignment(T) else std.mem.Alignment.of(T));
        if (comptime slab_class != null) {
            if (self.small_slab_enabled) {
                if (comptime is_gc) std.debug.assert(gcAllocInfoByte(ptr) & (alloc_info_standalone | alloc_info_class_mask) == comptime slab_class.?);
                self.debitAlloc(@sizeOf(T), comptime slab_class);
                self.noteFreeDiagnostics(true);
                return self.small_slab.freeAtIndex(&self.backing_allocator, bytes_ptr, comptime slab_class.?);
            }
        }
        const prefix = if (comptime is_gc) gcPrefixSize(T) else 0;
        const bytes = prefix + @sizeOf(T);
        self.debitAlloc(bytes, null);
        self.noteFreeDiagnostics(true);
        const base: [*]u8 = @ptrFromInt(@intFromPtr(ptr) - prefix);
        self.backing_allocator.rawFree(base[0..bytes], alignment, @returnAddress());
    }

    /// Variable-size GC allocation: the `T` struct immediately followed by
    /// `fam_bytes` of inline flexible-array-member storage, in ONE allocation,
    /// with 8-byte `Metadata` at `objectPtr - 8` (overlaid on the slab header
    /// when eligible, otherwise standalone). Mirrors qjs's single allocation for
    /// JSShape (struct fields + inline hash table + prop[]). The caller is
    /// responsible for the FAM's internal alignment (must be <= `gcAlignment(T)`,
    /// which is >= 8); since the struct size is a multiple of `@alignOf(T)`, the
    /// FAM region starts `@alignOf(T)`-aligned right after the struct.
    pub inline fn createWithFam(self: *MemoryAccount, comptime T: type, fam_bytes: usize) !*T {
        return self.createWithFamInternal(T, fam_bytes, true);
    }

    /// Initial-shape path: `fam_bytes` is a comptime constant so the slab
    /// class is folded (qjs `js_new_shape2.constprop` folds `get_shape_size`).
    pub inline fn createWithFamComptime(self: *MemoryAccount, comptime T: type, comptime fam_bytes: usize) !*T {
        comptime std.debug.assert(isGcObject(T));
        const payload_bytes: usize = @sizeOf(T) + fam_bytes;
        const alignment = comptime gcAlignment(T);
        if (comptime oom_coverage_enabled) oom_coverage.record(@returnAddress());
        if (comptime SmallObjectSlab.classIndex(payload_bytes, alignment)) |slab_class| {
            if (self.small_slab_enabled) {
                try self.checkAllocation(payload_bytes);
                if (comptime allocation_gc_trigger_enabled) self.triggerGCBeforeAllocation(payload_bytes);
                const raw = self.slabPopHot(slab_class, false) orelse
                    return self.createWithFamInternalSlow(T, fam_bytes, true);
                initGcPrefix(T, @ptrFromInt(@intFromPtr(raw) - gc_prefix_size), slab_class);
                self.creditAlloc(payload_bytes, slab_class);
                self.noteAllocDiagnostics(true, 1, payload_bytes, @intFromPtr(raw));
                return @ptrCast(@alignCast(raw));
            }
        }
        return self.createWithFamInternalSlow(T, fam_bytes, true);
    }

    pub inline fn createWithFamNoTrigger(self: *MemoryAccount, comptime T: type, fam_bytes: usize) !*T {
        return self.createWithFamInternal(T, fam_bytes, false);
    }

    fn createWithFamInternal(self: *MemoryAccount, comptime T: type, fam_bytes: usize, comptime trigger_gc: bool) !*T {
        comptime std.debug.assert(isGcObject(T));
        if (comptime oom_coverage_enabled) oom_coverage.record(@returnAddress());
        const payload_bytes = std.math.add(usize, @sizeOf(T), fam_bytes) catch return error.OutOfMemory;
        // Shape-sized trailing Object storage must stay on the collector's
        // ordinary classed-block bump path. This is the variable-size twin of
        // createInternal's direct block route: only the authorized GC kind can enter,
        // and medium/large requests are declined by allocCell and fall through
        // to the compatibility slab without acquiring a partial block.
        if (comptime block_heap_enabled) {
            if (comptime T.gc_kind_tag == gc_representation.object_kind_tag) {
                if (self.gc_object_cell_heap) |heap| {
                    try self.checkAllocation(payload_bytes);
                    if (comptime trigger_gc) self.triggerGCBeforeAllocation(payload_bytes);
                    if ((heap.allocCell(gc_prefix_size + payload_bytes) catch null)) |cell| {
                        initGcPrefixBlockCell(T, cell.ptr);
                        self.creditAlloc(payload_bytes, null);
                        self.noteAllocDiagnostics(true, 1, payload_bytes, @intFromPtr(cell.ptr) + gc_prefix_size);
                        return @ptrFromInt(@intFromPtr(cell.ptr) + gc_prefix_size);
                    }
                }
            }
        }
        // Inline hot arm = qjs `__js_malloc` small-block path (quickjs.c:1566)
        // with the runtime `get_block_size_index` classification qjs also pays
        // for a runtime size. Arena refill and the standalone-prefix route live
        // in the noinline slow twin.
        if (self.small_slab_enabled) {
            if (SmallObjectSlab.classIndex(payload_bytes, comptime gcAlignment(T))) |slab_class| {
                try self.checkAllocation(payload_bytes);
                if (comptime trigger_gc) self.triggerGCBeforeAllocation(payload_bytes);
                const raw = self.slabPopHot(slab_class, false) orelse
                    return self.createWithFamInternalSlow(T, fam_bytes, trigger_gc);
                initGcPrefix(T, @ptrFromInt(@intFromPtr(raw) - gc_prefix_size), slab_class);
                self.creditAlloc(payload_bytes, slab_class);
                self.noteAllocDiagnostics(true, 1, payload_bytes, @intFromPtr(raw));
                return @ptrCast(@alignCast(raw));
            }
        }
        return self.createWithFamInternalSlow(T, fam_bytes, trigger_gc);
    }

    /// Cold continuation of `createWithFamInternal`: arena refill and the
    /// slab-disabled/standalone-prefix routes. Re-running the limit check
    /// (and, on refill, the GC trigger request) here is idempotent.
    noinline fn createWithFamInternalSlow(self: *MemoryAccount, comptime T: type, fam_bytes: usize, comptime trigger_gc: bool) !*T {
        const payload_bytes = std.math.add(usize, @sizeOf(T), fam_bytes) catch return error.OutOfMemory;
        const alignment = comptime gcAlignment(T);
        const slab_index = self.gcSlabClassIndex(payload_bytes, alignment);
        const prefix = if (slab_index != null) 0 else comptime gcPrefixSize(T);
        const bytes = std.math.add(usize, prefix, payload_bytes) catch return error.OutOfMemory;
        try self.checkAllocation(bytes);
        if (comptime trigger_gc) {
            self.triggerGCBeforeAllocation(bytes);
        }
        const raw = try self.rawAllocForGc(bytes, alignment, slab_index);
        const obj_addr = @intFromPtr(raw) + prefix;
        initGcPrefix(T, @ptrFromInt(obj_addr - gc_prefix_size), slab_index);
        const ptr: *T = @ptrFromInt(obj_addr);
        self.creditAlloc(if (slab_index != null) payload_bytes else bytes, slab_index);
        self.noteAllocDiagnostics(true, 1, bytes, @intFromPtr(ptr));
        return ptr;
    }

    /// Accounted payload of a slab-backed GC FAM, or null when the object
    /// uses a standalone prefix (caller falls back to live capacity fields).
    /// qjs `__js_free` never re-derives size from JSShape.prop_size.
    pub fn gcSlabAccountedPayload(ptr: *const anyopaque) ?usize {
        const info = gcAllocInfoByte(ptr);
        if (info & alloc_info_class_mask == alloc_info_block_cell) return null;
        if (info & alloc_info_standalone != 0) return null;
        return SmallObjectSlab.usablePayloadFromClass(info & alloc_info_class_mask);
    }

    /// Frees a `createWithFam` allocation. `fam_bytes` MUST equal the value
    /// passed to `createWithFam` (the caller derives it from the live object's
    /// capacity fields before clearing them) on the standalone-prefix path.
    /// The slab arm trusts the header class (qjs `__js_free`, quickjs.c:1614)
    /// and does not re-run `classIndex` on the requested length.
    pub fn destroyWithFam(self: *MemoryAccount, comptime T: type, ptr: *T, fam_bytes: usize) void {
        comptime std.debug.assert(isGcObject(T));
        if (comptime diagnostic_accounting_enabled) self.traceFree(@intFromPtr(ptr));
        const payload_bytes = @sizeOf(T) + fam_bytes;
        const alignment = comptime gcAlignment(T);
        const info = gcAllocInfoByte(ptr);
        // Variable-sized block cells carry the same route marker as fixed
        // Objects. Debit the logical Object+tail payload and return the exact
        // cell to the classed block; no class reclassification or partial-block
        // reuse is introduced here.
        if (comptime block_heap_enabled) {
            if (info & alloc_info_class_mask == alloc_info_block_cell) {
                if (self.gc_object_cell_heap) |heap| {
                    self.debitAlloc(payload_bytes, null);
                    self.noteFreeDiagnostics(true);
                    heap.freeSmallCell(@ptrFromInt(@intFromPtr(ptr) - gc_prefix_size));
                    return;
                }
            }
        }
        // Straight-line slab arm mirroring qjs `__js_free`'s small-block path
        // (quickjs.c:1613-1617): the block header byte carries the class index,
        // so the free never re-derives the class from the byte size.
        if (info & alloc_info_standalone == 0) {
            const slab_class: usize = info & alloc_info_class_mask;
            std.debug.assert(self.small_slab_enabled);
            self.debitAlloc(payload_bytes, slab_class);
            self.noteFreeDiagnostics(true);
            return self.small_slab.freeAtIndex(&self.backing_allocator, @ptrCast(ptr), slab_class);
        }
        const prefix = comptime gcPrefixSize(T);
        const bytes = prefix + payload_bytes;
        self.debitAlloc(bytes, null);
        self.noteFreeDiagnostics(true);
        const base: [*]u8 = @ptrFromInt(@intFromPtr(ptr) - prefix);
        self.backing_allocator.rawFree(base[0..bytes], alignment, @returnAddress());
    }

    /// Stage-3 Pass-A settlement: the accounting half of the block-cell arm of
    /// `destroy` / `destroyWithFam`, without returning the cell to the heap.
    /// The caller (`object_gc.trySettleTracerBlockCorpse`) clears the alloc bit
    /// and the block's `allocated_count` itself, so the cell is released but
    /// unlinked; see `Heap.settleDoomedCellInPassA`.
    ///
    /// `payload_bytes` MUST be the same logical size the deferred free would
    /// have debited: `@sizeOf(Object)` normally and `@sizeOf(Object) +
    /// trailing_property_bytes` for the FAM variant. 62.3% of splay's block
    /// corpses are the FAM variant, so a block-uniform size would silently
    /// rewrite the RC comparison denominator.
    pub inline fn debitBlockCellPayload(self: *MemoryAccount, ptr: *const anyopaque, payload_bytes: usize) void {
        comptime std.debug.assert(block_heap_enabled);
        if (comptime diagnostic_accounting_enabled) self.traceFree(@intFromPtr(ptr));
        self.debitAlloc(payload_bytes, null);
        self.noteFreeDiagnostics(true);
    }

    pub fn hasOutstandingAllocations(self: MemoryAccount) bool {
        if (comptime diagnostic_accounting_enabled) {
            return self.allocated_bytes != 0 or self.allocation_count != 0;
        }
        return self.allocated_bytes != 0;
    }

    pub fn enableSmallObjectSlab(self: *MemoryAccount) void {
        self.small_slab_enabled = true;
        if (comptime slab_locality_audit) slab_audit.audit_slab = &self.small_slab;
    }

    /// Conservative resolution requires page-aligned slab arenas. The trace
    /// runtime serves those physical pages from Zig's independent allocator;
    /// logical allocations remain charged to this account.
    pub fn useIndependentSmallObjectSlabArenaBacking(self: *MemoryAccount) void {
        if (comptime !arena_addressable) return;
        self.small_slab.setArenaBacking(std.heap.smp_allocator);
    }

    pub fn deinitSmallObjectSlab(self: *MemoryAccount) void {
        self.small_slab.deinit(self.backing_allocator);
        self.small_slab_enabled = false;
    }

    pub fn setLimit(self: *MemoryAccount, limit: ?usize) void {
        self.limit = limit;
    }

    pub fn getLimit(self: MemoryAccount) ?usize {
        return self.limit;
    }

    fn checkAllocation(self: *MemoryAccount, bytes: usize) !void {
        const limit = self.limit orelse {
            @branchHint(.likely);
            return;
        };
        const next = std.math.add(usize, self.allocated_bytes, bytes) catch return error.OutOfMemory;
        if (next <= limit) return;
        const collect = self.limit_gc_fn orelse return error.OutOfMemory;
        const ctx = self.limit_gc_ctx orelse return error.OutOfMemory;
        collect(ctx);
        const retried = std.math.add(usize, self.allocated_bytes, bytes) catch return error.OutOfMemory;
        if (retried > limit) return error.OutOfMemory;
    }

    inline fn triggerGCBeforeAllocation(self: *MemoryAccount, byte_count: usize) void {
        // qjs `__js_malloc` (quickjs.c:1566) checks `malloc_limit` and nothing
        // else; `malloc_gc_threshold` belongs to `js_trigger_gc`
        // (quickjs.c:1780-1797), whose only caller is `JS_NewObjectFromShape`
        // (quickjs.c:5619). A production allocation therefore has no GC trigger
        // — see `allocation_gc_trigger_enabled`.
        //
        // Runtime-owned accounts install this after GC initialization. In the
        // forced-GC build, the same trigger performs a full collection here,
        // before the backing allocation; test builds keep it so injected probes
        // still observe every allocation.
        if (comptime !allocation_gc_trigger_enabled) return;
        if (self.trigger_gc_fn) |trigger| trigger(self.trigger_gc_ctx, byte_count);
    }

    /// Sample the lifetime account high-water at a collection boundary.
    ///
    /// Per-allocation peak tracking is Debug/test-only (`updatePeak` under
    /// `diagnostic_accounting_enabled`) because a RMW per allocation is the
    /// kind of tax this allocator exists to avoid. This historical field is a
    /// cheap lifetime diagnostic, not §1.3's cycle peak: allocations continue
    /// while an incremental major is open. `beginCyclePeakTracking` installs
    /// the exact, explicitly requested per-allocation instrument for that row.
    pub fn samplePeakAtCollection(self: *MemoryAccount) void {
        self.updatePeak();
    }

    fn updatePeak(self: *MemoryAccount) void {
        self.peak_allocated_bytes = @max(self.peak_allocated_bytes, self.allocated_bytes);
        self.peak_allocation_count = @max(self.peak_allocation_count, self.allocation_count);
    }

    /// Route account credits to one pacing window's peak. The caller owns the
    /// destination and must keep it stable until `endCyclePeakTracking`.
    pub fn beginCyclePeakTracking(self: *MemoryAccount, output: *usize) void {
        if (comptime !cycle_envelope_tracking_available) return;
        std.debug.assert(self.cycle_peak_output == null);
        output.* = self.allocated_bytes;
        self.cycle_peak_output = output;
    }

    pub fn endCyclePeakTracking(self: *MemoryAccount) void {
        if (comptime !cycle_envelope_tracking_available) return;
        self.cycle_peak_output = null;
    }

    inline fn noteCyclePeak(self: *MemoryAccount) void {
        if (comptime !cycle_envelope_tracking_available) return;
        if (self.cycle_peak_output) |peak| peak.* = @max(peak.*, self.allocated_bytes);
    }

    /// The slab-routing predicate `allocAlignedBytesInternal`'s tracing arm
    /// hoists so it is not derived twice per allocation. It must stay
    /// identical to the one inline in `rawAlloc` below; the test
    /// "aligned byte allocations charge their slab class" pins the agreement
    /// by observing the account delta, which is the only externally visible
    /// consequence of choosing a different class.
    ///
    /// Deliberately NOT shared with `rawAlloc` by having `rawAlloc` call it:
    /// routing that call through a function boundary left the RC build
    /// semantically identical but re-encoded 26 `tbz wN,#0` as `cbz wN`, which
    /// costs the byte-identical RC `.text` gate for zero benefit.
    inline fn rawSlabClass(self: *const MemoryAccount, byte_count: usize, alignment: std.mem.Alignment) ?usize {
        if (self.small_slab_enabled) {
            return SmallObjectSlab.classIndex(byte_count, alignment);
        }
        return null;
    }

    inline fn rawAlloc(self: *MemoryAccount, byte_count: usize, alignment: std.mem.Alignment) ![*]u8 {
        if (self.small_slab_enabled) {
            if (SmallObjectSlab.classIndex(byte_count, alignment)) |index| {
                return self.small_slab.allocAtIndex(self.backing_allocator, index, true);
            }
        }
        return self.backing_allocator.rawAlloc(byte_count, alignment, @returnAddress()) orelse error.OutOfMemory;
    }

    inline fn rawFree(self: *MemoryAccount, bytes: []u8, alignment: std.mem.Alignment) void {
        if (self.small_slab_enabled and SmallObjectSlab.eligibleSize(bytes.len, alignment)) {
            // The runtime enables the slab before managed allocations begin;
            // while enabled, every eligible allocation comes from it. This path
            // frees raw (non-GC-object) payloads, whose blocks keep the
            // allocator's class byte (qjs __js_free, quickjs.c:1614).
            const index = SmallObjectSlab.headerClassIndex(bytes.ptr);
            std.debug.assert(index == SmallObjectSlab.classIndex(bytes.len, alignment).?);
            self.small_slab.freeAtIndex(&self.backing_allocator, bytes.ptr, index);
            return;
        }
        self.backing_allocator.rawFree(bytes, alignment, @returnAddress());
    }

    fn traceAlloc(self: *MemoryAccount, comptime element_size: usize, count: usize, address: usize) void {
        const writer = self.trace_writer orelse return;
        if (self.trace_failed) return;
        const bytes = element_size * count;
        writer.print("A {d} -> 0x{x}.{d}\n", .{ bytes, address, bytes }) catch {
            self.trace_failed = true;
        };
    }

    fn traceFree(self: *MemoryAccount, address: usize) void {
        const writer = self.trace_writer orelse return;
        if (self.trace_failed) return;
        writer.print("F 0x{x}\n", .{address}) catch {
            self.trace_failed = true;
        };
    }
};

test "aligned byte allocations charge their slab class" {
    // Pins `allocAlignedBytesInternal`'s slab routing to the account contract.
    // The tracing arm hoists the classification out of `rawAlloc` and carries
    // it as an index-or-sentinel; if that arm ever picked a different class
    // than `rawAlloc` would, the ledger delta below is what would drift --
    // it is the only externally visible consequence of the choice.
    for ([_]bool{ false, true }) |slab_enabled| {
        var account = MemoryAccount.init(std.testing.allocator);
        defer account.small_slab.deinit(std.testing.allocator);
        account.small_slab_enabled = slab_enabled;

        var byte_count: usize = 1;
        while (byte_count <= SmallObjectSlab.max_size + 64) : (byte_count += 1) {
            for ([_]std.mem.Alignment{ .@"1", .@"8", .@"16", .@"64" }) |alignment| {
                const before = account.allocated_bytes;
                const bytes = try account.allocAlignedBytesNoTrigger(byte_count, alignment);
                const charged = account.allocated_bytes - before;
                const expected = if (slab_enabled)
                    MemoryAccount.accountedMallocSize(byte_count, SmallObjectSlab.classIndex(byte_count, alignment))
                else
                    byte_count;
                try std.testing.expectEqual(expected, charged);
                account.freeAlignedBytes(bytes, alignment);
                try std.testing.expectEqual(before, account.allocated_bytes);
            }
        }
    }
}

test "small object slab releases an empty arena immediately" {
    var slab: SmallObjectSlab = .{};
    defer slab.deinit(std.testing.allocator);

    const alloc = try slab.alloc(std.testing.allocator, 64, .@"8");
    const index = SmallObjectSlab.classIndex(64, .@"8").?;
    try std.testing.expectEqual(@as(usize, 1), slab.debugArenaCount(index));

    slab.free(std.testing.allocator, alloc[0..64], .@"8");
    try std.testing.expectEqual(@as(usize, 0), slab.debugArenaCount(index));

    const next = try slab.alloc(std.testing.allocator, 64, .@"8");
    try std.testing.expectEqual(@as(usize, 1), slab.debugArenaCount(index));
    slab.free(std.testing.allocator, next[0..64], .@"8");
    try std.testing.expectEqual(@as(usize, 0), slab.debugArenaCount(index));
}

test "small object slab releases excess empty arenas" {
    var slab: SmallObjectSlab = .{};
    defer slab.deinit(std.testing.allocator);

    const index = SmallObjectSlab.classIndex(64, .@"8").?;
    var allocations: [SmallObjectSlab.arena_size / 16][*]u8 = undefined;
    allocations[0] = try slab.alloc(std.testing.allocator, 64, .@"8");
    const first_arena_capacity: usize = slab.arenas[index].?.block_count;
    for (allocations[1 .. first_arena_capacity + 1]) |*slot| {
        slot.* = try slab.alloc(std.testing.allocator, 64, .@"8");
    }
    try std.testing.expectEqual(@as(usize, 2), slab.debugArenaCount(index));

    for (allocations[0..first_arena_capacity]) |allocation| {
        slab.free(std.testing.allocator, allocation[0..64], .@"8");
    }
    try std.testing.expectEqual(@as(usize, 1), slab.debugArenaCount(index));

    slab.free(std.testing.allocator, allocations[first_arena_capacity][0..64], .@"8");
    try std.testing.expectEqual(@as(usize, 0), slab.debugArenaCount(index));
}

test "small slab GC allocation reuses allocator header for metadata" {
    const TestHeader = extern struct {
        prev: ?*@This() = null,
        next: ?*@This() = null,
    };
    const TestGc = extern struct {
        pub const gc_kind_tag: u8 = 3;

        header: TestHeader = .{},
        payload: [48]u8 = @splat(0),
    };

    comptime std.debug.assert(@sizeOf(TestGc) == 64);

    var account = MemoryAccount.init(std.testing.allocator);
    account.enableSmallObjectSlab();
    defer account.deinitSmallObjectSlab();

    const first = try account.create(TestGc);
    first.* = .{};
    const second = try account.create(TestGc);
    second.* = .{};

    // qjs js_def_malloc (quickjs.c:2168): usable + MALLOC_OVERHEAD per block.
    // 64-byte TestGc lands in class 72; Linux charge is the class size.
    const test_class = SmallObjectSlab.classIndex(@sizeOf(TestGc), MemoryAccount.gcAlignment(TestGc)).?;
    try std.testing.expectEqual(2 * MemoryAccount.accountedMallocSize(@sizeOf(TestGc), test_class), account.allocated_bytes);

    const second_meta: [*]const u8 = @ptrFromInt(@intFromPtr(second) - MemoryAccount.gc_prefix_size);
    // Byte 2 = allocator class stamp (qjs block_size_idx), byte 3 = kind in
    // the low 3 bits of the shared kind/flags byte (qjs gc_obj_type:7|mark:1).
    const expected_class = SmallObjectSlab.classIndex(@sizeOf(TestGc), MemoryAccount.gcAlignment(TestGc)).?;
    try std.testing.expectEqual(expected_class, second_meta[2]);
    try std.testing.expectEqual(TestGc.gc_kind_tag, second_meta[3] & 0x7);
    // Offset 4 is configuration-owned: RC starts at one; trace carriers must
    // be born with epoch/state zero so publication cannot read them marked.
    const expected_lifetime: u32 = if (trace_stw_enabled) 0 else 1;
    try std.testing.expectEqual(expected_lifetime, @as(*align(4) const u32, @ptrFromInt(@intFromPtr(second) - 4)).*);

    // Free a non-zero-index block, then prove its allocator index survived GC
    // prefix initialization by reusing the same slot.
    account.destroy(TestGc, second);
    const reused = try account.create(TestGc);
    try std.testing.expectEqual(@intFromPtr(second), @intFromPtr(reused));

    account.destroy(TestGc, reused);
    account.destroy(TestGc, first);
    try std.testing.expectEqual(@as(usize, 0), account.allocated_bytes);
}

test "GC ledger charges slab class usable plus malloc overhead (qjs:2168)" {
    var account = MemoryAccount.init(std.testing.allocator);
    account.enableSmallObjectSlab();
    defer account.deinitSmallObjectSlab();

    // 32-byte raw payload → total 40 → class 40. Linux charge is the class size.
    const request: usize = 32;
    const class = SmallObjectSlab.classIndex(request, .@"8").?;
    try std.testing.expectEqual(@as(usize, 40), SmallObjectSlab.blockSize(class));
    const charged = MemoryAccount.accountedMallocSize(request, class);
    if (malloc_overhead == 8) {
        try std.testing.expectEqual(@as(usize, 40), charged);
    } else {
        try std.testing.expectEqual(request, charged);
    }

    const ptr = try account.alloc(u8, request);
    try std.testing.expectEqual(charged, account.allocated_bytes);
    account.free(u8, ptr);
    try std.testing.expectEqual(@as(usize, 0), account.allocated_bytes);

    const standalone_request: usize = 600;
    const standalone = try account.alloc(u8, standalone_request);
    try std.testing.expectEqual(standalone_request, account.allocated_bytes);
    account.free(u8, standalone);
    try std.testing.expectEqual(@as(usize, 0), account.allocated_bytes);
}

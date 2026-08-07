const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

const diagnostic_accounting_enabled = builtin.is_test or builtin.mode == .Debug;

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
pub const force_gc_on_allocation_enabled: bool = build_options.zjs_force_gc;

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
    const free_nil: u16 = std.math.maxInt(u16);
    const block_sizes = [_]usize{
        16,  24,  32,  40,  48,  56,  64,  72,
        80,  88,  96,  104, 112, 120, 128, 144,
        160, 176, 192, 208, 224, 240, 256, 288,
        320, 352, 384, 416, 448, 480, 512,
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

    const Arena = struct {
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
    const arena_header_size = std.mem.alignForward(usize, @sizeOf(Arena), slab_alignment.toByteUnits());

    arenas: [block_sizes.len]?*Arena = @splat(null),
    free_arenas: [block_sizes.len]?*Arena = @splat(null),

    pub inline fn canUse(byte_count: usize, alignment: std.mem.Alignment) bool {
        return classIndex(byte_count, alignment) != null;
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
        arena.first_free_block = header.index_or_next;
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
    /// (quickjs.c:1626-1630). Keeping a per-class reserve would leave physical
    /// backing alive after the runtime's logical/accounted bytes reached zero.
    /// Out of line so the per-free hot path stays call-free (the mirror of qjs
    /// keeping `js_malloc_new_arena` no_inline on the alloc side).
    noinline fn releaseEmptyArena(self: *SmallObjectSlab, backing: *const std.mem.Allocator, index: usize, arena: *Arena) void {
        self.removeArena(index, arena);
        self.removeFreeArena(index, arena);
        backing.rawFree(arenaAllocation(arena), slab_alignment, @returnAddress());
    }

    pub fn deinit(self: *SmallObjectSlab, backing: std.mem.Allocator) void {
        for (&self.arenas) |*head| {
            var arena = head.*;
            while (arena) |node| {
                arena = node.next;
                backing.rawFree(arenaAllocation(node), slab_alignment, @returnAddress());
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
        const storage_ptr = backing.rawAlloc(alloc_size, slab_alignment, @returnAddress()) orelse return error.OutOfMemory;
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
        }
        self.addArenaList(index, arena);
        self.addFreeArena(index, arena);
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
        arena.free_prev = null;
        arena.free_next = self.free_arenas[index];
        if (arena.free_next) |next| next.free_prev = arena;
        self.free_arenas[index] = arena;
    }

    fn removeFreeArena(self: *SmallObjectSlab, index: usize, arena: *Arena) void {
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
    allocated_bytes: usize = 0,
    allocation_count: usize = 0,
    peak_allocated_bytes: usize = 0,
    peak_allocation_count: usize = 0,
    alloc_calls: usize = 0,
    free_calls: usize = 0,
    create_calls: usize = 0,
    destroy_calls: usize = 0,
    limit: ?usize = null,
    trace_writer: ?*std.Io.Writer = null,
    trace_failed: bool = false,
    profile_alloc_count: ?*u64 = null,
    trigger_gc_fn: ?*const fn (ctx: ?*anyopaque, size: usize) void = null,
    trigger_gc_ctx: ?*anyopaque = null,

    pub fn init(allocator: std.mem.Allocator) MemoryAccount {
        return .{ .allocator = allocator, .persistent_allocator = allocator, .backing_allocator = allocator };
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
                    self.allocated_bytes +%= bytes;
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
                    self.allocated_bytes +%= payload_bytes;
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
        const slab_index = if (comptime is_gc) self.gcSlabClassIndex(payload_bytes, alignment) else null;
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
        self.allocated_bytes +%= bytes;
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
                    self.allocated_bytes -%= payload_bytes;
                    self.noteFreeDiagnostics(false);
                    return self.small_slab.freeAtIndex(&self.backing_allocator, bytes_ptr, comptime slab_class.?);
                }
            }
            const prefix = comptime gcPrefixSize(T);
            const bytes = prefix + payload_bytes;
            self.allocated_bytes -%= bytes;
            self.noteFreeDiagnostics(false);
            const base: [*]u8 = @ptrFromInt(@intFromPtr(slice.ptr) - prefix);
            return self.backing_allocator.rawFree(base[0..bytes], alignment, @returnAddress());
        }
        self.allocated_bytes -%= payload_bytes;
        self.noteFreeDiagnostics(false);
        if (self.small_slab_enabled and SmallObjectSlab.eligibleSize(payload_bytes, alignment)) {
            // The runtime enables the slab before managed allocations begin;
            // while enabled, every eligible allocation comes from it. Non-GC
            // blocks keep the allocator's class byte, so read it back instead
            // of re-deriving the class (qjs __js_free, quickjs.c:1614).
            const slab_class = SmallObjectSlab.headerClassIndex(bytes_ptr);
            std.debug.assert(slab_class == SmallObjectSlab.classIndex(payload_bytes, alignment).?);
            return self.small_slab.freeAtIndex(&self.backing_allocator, bytes_ptr, slab_class);
        }
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
        const next_allocated_bytes = std.math.add(usize, self.allocated_bytes, byte_count) catch return error.OutOfMemory;
        const ptr = try self.rawAlloc(byte_count, alignment);
        self.allocated_bytes = next_allocated_bytes;
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
        self.allocated_bytes -= bytes.len;
        if (comptime diagnostic_accounting_enabled) {
            self.allocation_count -= 1;
            self.free_calls += 1;
        }
        self.rawFree(bytes, alignment);
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
    const gc_prefix_size: usize = 8;

    /// A GC object is any struct whose first field (`header`, offset 0) is the
    /// 16-byte intrusive-list `BlockHeader` (`prev`/`next`). Such objects carry
    /// refcount/kind/flags at `objectPtr - 8`; plain allocations (and the 4-byte
    /// `StringHeader`, which has no prev/next) do not.
    inline fn isGcObject(comptime T: type) bool {
        if (@typeInfo(T) != .@"struct") return false;
        if (!@hasDecl(T, "gc_kind_tag")) return false;
        if (!@hasField(T, "header")) return false;
        if (@offsetOf(T, "header") != 0) return false;
        const H = @FieldType(T, "header");
        return @typeInfo(H) == .@"struct" and @hasField(H, "prev") and @hasField(H, "next") and @sizeOf(H) == 16;
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

    /// Byte 2 of the GC prefix (`gc.Metadata.alloc_info`): bits 0..4 slab
    /// class index, bit 6 heap-accounted (registry-owned), bit 7 standalone
    /// prefix. Bit positions are asserted against gc.AllocInfo in gc.zig.
    const alloc_info_standalone: u8 = 1 << 7;
    const alloc_info_class_mask: u8 = 0x1f;

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
    inline fn initGcPrefix(comptime T: type, meta: [*]u8, slab_class: ?usize) void {
        // The kind must stay inside the low 3 bits of the shared kind/flags
        // byte (gc.BlockFlags.kind).
        comptime std.debug.assert(T.gc_kind_tag < 8);
        // Exact-value stores (no memset-then-overwrite): size_class (bytes
        // 0..2, preserved when the slab header is overlaid), alloc_info + kind
        // as one u16 (byte order fixed by the gc.zig offset asserts), and the
        // refcount as a native i32 (gc reads Metadata.rc as a struct field).
        if (slab_class == null) std.mem.writeInt(u16, meta[0..2], 0, .little);
        if (slab_class) |index| std.debug.assert(index <= alloc_info_class_mask);
        const info: u8 = if (slab_class) |index| @intCast(index) else alloc_info_standalone;
        std.mem.writeInt(u16, meta[2..4], @as(u16, info) | (@as(u16, T.gc_kind_tag) << 8), .little);
        @as(*align(4) i32, @ptrCast(@alignCast(meta + 4))).* = 1;
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
        if (comptime slab_class != null) {
            if (self.small_slab_enabled) {
                const bytes: usize = @sizeOf(T);
                try self.checkAllocation(bytes);
                if (comptime trigger_gc) self.triggerGCBeforeAllocation(bytes);
                const raw = self.slabPopHot(comptime slab_class.?, !is_gc) orelse
                    return self.createInternalSlow(T, trigger_gc);
                if (comptime is_gc) initGcPrefix(T, @ptrFromInt(@intFromPtr(raw) - gc_prefix_size), comptime slab_class.?);
                self.allocated_bytes +%= bytes;
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
        const slab_index = if (comptime is_gc) self.gcSlabClassIndex(@sizeOf(T), alignment) else null;
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
        self.allocated_bytes +%= bytes;
        self.noteAllocDiagnostics(true, @sizeOf(T), 1, @intFromPtr(ptr));
        return ptr;
    }

    pub fn destroy(self: *MemoryAccount, comptime T: type, ptr: *T) void {
        if (comptime diagnostic_accounting_enabled) self.traceFree(@intFromPtr(ptr));
        const is_gc = comptime isGcObject(T);
        const alignment = if (comptime is_gc) gcAlignment(T) else std.mem.Alignment.of(T);
        const bytes_ptr: [*]u8 = @ptrCast(ptr);
        // Straight-line slab arm mirroring qjs `__js_free`'s small-block path
        // (quickjs.c:1613); the class index is comptime for a sized type.
        const slab_class = comptime SmallObjectSlab.classIndex(@sizeOf(T), if (is_gc) gcAlignment(T) else std.mem.Alignment.of(T));
        if (comptime slab_class != null) {
            if (self.small_slab_enabled) {
                if (comptime is_gc) std.debug.assert(gcAllocInfoByte(ptr) & (alloc_info_standalone | alloc_info_class_mask) == comptime slab_class.?);
                self.allocated_bytes -%= @sizeOf(T);
                self.noteFreeDiagnostics(true);
                return self.small_slab.freeAtIndex(&self.backing_allocator, bytes_ptr, comptime slab_class.?);
            }
        }
        const prefix = if (comptime is_gc) gcPrefixSize(T) else 0;
        const bytes = prefix + @sizeOf(T);
        self.allocated_bytes -%= bytes;
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

    pub inline fn createWithFamNoTrigger(self: *MemoryAccount, comptime T: type, fam_bytes: usize) !*T {
        return self.createWithFamInternal(T, fam_bytes, false);
    }

    fn createWithFamInternal(self: *MemoryAccount, comptime T: type, fam_bytes: usize, comptime trigger_gc: bool) !*T {
        comptime std.debug.assert(isGcObject(T));
        if (comptime oom_coverage_enabled) oom_coverage.record(@returnAddress());
        const payload_bytes = std.math.add(usize, @sizeOf(T), fam_bytes) catch return error.OutOfMemory;
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
                self.allocated_bytes +%= payload_bytes;
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
        self.allocated_bytes +%= bytes;
        self.noteAllocDiagnostics(true, 1, bytes, @intFromPtr(ptr));
        return ptr;
    }

    /// Frees a `createWithFam` allocation. `fam_bytes` MUST equal the value
    /// passed to `createWithFam` (the caller derives it from the live object's
    /// capacity fields before clearing them).
    pub fn destroyWithFam(self: *MemoryAccount, comptime T: type, ptr: *T, fam_bytes: usize) void {
        comptime std.debug.assert(isGcObject(T));
        if (comptime diagnostic_accounting_enabled) self.traceFree(@intFromPtr(ptr));
        const payload_bytes = @sizeOf(T) + fam_bytes;
        const alignment = comptime gcAlignment(T);
        // Straight-line slab arm mirroring qjs `__js_free`'s small-block path
        // (quickjs.c:1613-1617): the block header byte carries the class index,
        // so the free never re-derives the class from the byte size.
        const info = gcAllocInfoByte(ptr);
        if (info & alloc_info_standalone == 0) {
            const slab_class: usize = info & alloc_info_class_mask;
            std.debug.assert(self.small_slab_enabled);
            std.debug.assert(slab_class == SmallObjectSlab.classIndex(payload_bytes, alignment).?);
            self.allocated_bytes -%= payload_bytes;
            self.noteFreeDiagnostics(true);
            return self.small_slab.freeAtIndex(&self.backing_allocator, @ptrCast(ptr), slab_class);
        }
        const prefix = comptime gcPrefixSize(T);
        const bytes = prefix + payload_bytes;
        self.allocated_bytes -%= bytes;
        self.noteFreeDiagnostics(true);
        const base: [*]u8 = @ptrFromInt(@intFromPtr(ptr) - prefix);
        self.backing_allocator.rawFree(base[0..bytes], alignment, @returnAddress());
    }

    pub fn hasOutstandingAllocations(self: MemoryAccount) bool {
        if (comptime diagnostic_accounting_enabled) {
            return self.allocated_bytes != 0 or self.allocation_count != 0;
        }
        return self.allocated_bytes != 0;
    }

    pub fn enableSmallObjectSlab(self: *MemoryAccount) void {
        self.small_slab_enabled = true;
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

    fn checkAllocation(self: MemoryAccount, bytes: usize) !void {
        const limit = self.limit orelse return;
        const next = std.math.add(usize, self.allocated_bytes, bytes) catch return error.OutOfMemory;
        if (next > limit) return error.OutOfMemory;
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

    fn updatePeak(self: *MemoryAccount) void {
        self.peak_allocated_bytes = @max(self.peak_allocated_bytes, self.allocated_bytes);
        self.peak_allocation_count = @max(self.peak_allocation_count, self.allocation_count);
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

    // The slab's existing 8-byte block header carries the GC metadata. Only
    // the 64-byte payload is charged/requested, so the physical slab class is
    // 72 bytes (8-byte allocator header + payload), not the old 80 bytes.
    try std.testing.expectEqual(2 * @sizeOf(TestGc), account.allocated_bytes);

    const second_meta: [*]const u8 = @ptrFromInt(@intFromPtr(second) - MemoryAccount.gc_prefix_size);
    // Byte 2 = allocator class stamp (qjs block_size_idx), byte 3 = kind in
    // the low 3 bits of the shared kind/flags byte (qjs gc_obj_type:7|mark:1).
    const expected_class = SmallObjectSlab.classIndex(@sizeOf(TestGc), MemoryAccount.gcAlignment(TestGc)).?;
    try std.testing.expectEqual(expected_class, second_meta[2]);
    try std.testing.expectEqual(TestGc.gc_kind_tag, second_meta[3] & 0x7);
    try std.testing.expectEqual(@as(i32, 1), @as(*align(4) const i32, @ptrFromInt(@intFromPtr(second) - 4)).*);

    // Free a non-zero-index block, then prove its allocator index survived GC
    // prefix initialization by reusing the same slot.
    account.destroy(TestGc, second);
    const reused = try account.create(TestGc);
    try std.testing.expectEqual(@intFromPtr(second), @intFromPtr(reused));

    account.destroy(TestGc, reused);
    account.destroy(TestGc, first);
    try std.testing.expectEqual(@as(usize, 0), account.allocated_bytes);
}

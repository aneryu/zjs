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
    empty_reserves: [block_sizes.len]?*Arena = @splat(null),

    pub inline fn canUse(byte_count: usize, alignment: std.mem.Alignment) bool {
        return classIndex(byte_count, alignment) != null;
    }

    pub inline fn alloc(self: *SmallObjectSlab, backing: std.mem.Allocator, byte_count: usize, alignment: std.mem.Alignment) ![*]u8 {
        const index = classIndex(byte_count, alignment).?;
        return self.allocAtIndex(backing, index);
    }

    inline fn allocAtIndex(self: *SmallObjectSlab, backing: std.mem.Allocator, index: usize) ![*]u8 {
        var arena = self.free_arenas[index] orelse try self.addArena(backing, index);
        const block_size = block_sizes[index];
        const block_idx = arena.first_free_block;
        std.debug.assert(block_idx != free_nil);
        const header = blockHeaderAt(arena, block_idx, block_size);
        if (arena.used_blocks == 0 and self.empty_reserves[index] == arena) {
            self.empty_reserves[index] = null;
        }
        arena.first_free_block = header.index_or_next;
        header.index_or_next = block_idx;
        arena.used_blocks += 1;
        if (arena.used_blocks == arena.block_count) {
            self.removeFreeArena(index, arena);
        }
        return userData(header);
    }

    pub inline fn free(self: *SmallObjectSlab, backing: std.mem.Allocator, bytes: []u8, alignment: std.mem.Alignment) void {
        const index = classIndex(bytes.len, alignment).?;
        self.freeAtIndex(backing, bytes.ptr, index);
    }

    inline fn freeAtIndex(self: *SmallObjectSlab, backing: std.mem.Allocator, ptr: [*]u8, index: usize) void {
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
            // Keep one empty arena per size class as a bounded hot reserve. A
            // class with no unrelated resident allocation must not alternate
            // rawAlloc/rawFree for every short-lived object; that made object
            // literal throughput depend on incidental startup allocation sizes.
            // Excess empty arenas are still returned immediately, and deinit
            // releases the final reserve. The upper bound is 31 * 4 KiB.
            if (self.empty_reserves[index] == null) {
                self.empty_reserves[index] = arena;
            } else {
                std.debug.assert(self.empty_reserves[index] != arena);
                self.removeArena(index, arena);
                self.removeFreeArena(index, arena);
                backing.rawFree(arenaAllocation(arena), slab_alignment, @returnAddress());
            }
        }
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

    fn addArena(self: *SmallObjectSlab, backing: std.mem.Allocator, index: usize) !*Arena {
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
            header.* = .{
                .index_or_next = if (block_idx + 1 == arena.block_count) free_nil else block_idx + 1,
            };
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
    /// this account. Long-lived unmanaged containers must allocate and deinit
    /// with this allocator.
    persistent_allocator: std.mem.Allocator,
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
        return .{ .allocator = allocator, .persistent_allocator = allocator };
    }

    pub fn initWithTrace(allocator: std.mem.Allocator, writer: *std.Io.Writer) MemoryAccount {
        return .{ .allocator = allocator, .persistent_allocator = allocator, .trace_writer = writer };
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

    fn allocInternal(self: *MemoryAccount, comptime T: type, count: usize, comptime trigger_gc: bool) ![]T {
        if (comptime oom_coverage_enabled) oom_coverage.record(@returnAddress());
        if (count == 0) return &.{};
        // GC objects are allocated singly. Slab-backed objects reuse the slab's
        // existing 8-byte block header for their metadata; persistent/over-
        // aligned allocations keep the standalone prefix.
        const is_gc = comptime isGcObject(T);
        if (comptime is_gc) std.debug.assert(count == 1);
        const payload_bytes = std.math.mul(usize, @sizeOf(T), count) catch return error.OutOfMemory;
        const alignment = if (comptime is_gc) gcAlignment(T) else std.mem.Alignment.of(T);
        const slab_index = if (comptime is_gc) self.gcSlabClassIndex(payload_bytes, alignment) else null;
        const metadata_in_slab = slab_index != null;
        const prefix = if (comptime is_gc) (if (metadata_in_slab) 0 else gcPrefixSize(T)) else 0;
        const bytes = prefix + payload_bytes;
        try self.checkAllocation(bytes);
        if (comptime trigger_gc) {
            self.triggerGCBeforeAllocation(bytes);
        }
        const next_allocated_bytes = std.math.add(usize, self.allocated_bytes, bytes) catch return error.OutOfMemory;
        const raw = if (comptime is_gc)
            try self.rawAllocForGc(bytes, alignment, slab_index)
        else
            try self.rawAlloc(bytes, alignment);
        const obj_addr = @intFromPtr(raw) + prefix;
        if (comptime is_gc) initGcPrefix(T, @ptrFromInt(obj_addr - gc_prefix_size), metadata_in_slab);
        const ptr: [*]T = if (comptime is_gc)
            @ptrFromInt(obj_addr)
        else
            @ptrCast(@alignCast(raw));
        const slice = ptr[0..count];
        self.allocated_bytes = next_allocated_bytes;
        if (comptime diagnostic_accounting_enabled) {
            self.allocation_count += 1;
            self.alloc_calls += 1;
            self.updatePeak();
            if (self.profile_alloc_count) |counter| counter.* +|= 1;
            self.traceAlloc(@sizeOf(T), count, @intFromPtr(slice.ptr));
        }
        return slice;
    }

    pub fn free(self: *MemoryAccount, comptime T: type, slice: []T) void {
        if (slice.len == 0) return;
        if (comptime diagnostic_accounting_enabled) self.traceFree(@intFromPtr(slice.ptr));
        const is_gc = comptime isGcObject(T);
        const payload_bytes = std.math.mul(usize, @sizeOf(T), slice.len) catch return;
        const alignment = if (comptime is_gc) gcAlignment(T) else std.mem.Alignment.of(T);
        const slab_index = if (comptime is_gc) self.gcSlabClassIndex(payload_bytes, alignment) else null;
        const metadata_in_slab = slab_index != null;
        const prefix = if (comptime is_gc) (if (metadata_in_slab) 0 else gcPrefixSize(T)) else 0;
        const bytes = prefix + payload_bytes;
        self.allocated_bytes -= bytes;
        if (comptime diagnostic_accounting_enabled) {
            self.allocation_count -= 1;
            self.free_calls += 1;
        }
        const base: usize = @intFromPtr(slice.ptr) - prefix;
        const bytes_ptr: [*]u8 = @ptrFromInt(base);
        if (comptime is_gc) {
            self.rawFreeForGc(bytes_ptr[0..bytes], alignment, slab_index);
        } else {
            self.rawFree(bytes_ptr[0..bytes], alignment);
        }
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
        const remapped_ptr = self.persistent_allocator.rawRemap(old_raw, alignment, new_bytes, @returnAddress()) orelse return null;
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
    /// for over-aligned types (e.g. FunctionBytecode forces align 16 to keep its
    /// `header` field at offset 0) it rounds up to the alignment.
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
        if (slab_index) |index| return self.small_slab.allocAtIndex(self.persistent_allocator, index);
        return self.persistent_allocator.rawAlloc(bytes, alignment, @returnAddress()) orelse error.OutOfMemory;
    }

    inline fn rawFreeForGc(self: *MemoryAccount, bytes: []u8, alignment: std.mem.Alignment, slab_index: ?usize) void {
        if (slab_index) |index| {
            self.small_slab.freeAtIndex(self.persistent_allocator, bytes.ptr, index);
            return;
        }
        self.persistent_allocator.rawFree(bytes, alignment, @returnAddress());
    }

    /// Initialize GC metadata at `meta` (= objectPtr - 8). Bytes 0..2 are the
    /// slab allocator's live block index when the metadata is overlaid, so that
    /// case must preserve them. `metadata_in_slab` occupies flags bit 5; the
    /// raw offsets/mask are asserted against gc.Metadata in gc.zig.
    inline fn initGcPrefix(comptime T: type, meta: [*]u8, metadata_in_slab: bool) void {
        if (!metadata_in_slab) @memset(meta[0..2], 0);
        @memset(meta[2..gc_prefix_size], 0);
        meta[2] = T.gc_kind_tag;
        if (metadata_in_slab) meta[3] = 1 << 5;
        meta[4] = 1;
    }

    fn createInternal(self: *MemoryAccount, comptime T: type, comptime trigger_gc: bool) !*T {
        if (comptime oom_coverage_enabled) oom_coverage.record(@returnAddress());
        const is_gc = comptime isGcObject(T);
        const alignment = if (comptime is_gc) gcAlignment(T) else std.mem.Alignment.of(T);
        const slab_index = if (comptime is_gc) self.gcSlabClassIndex(@sizeOf(T), alignment) else null;
        const metadata_in_slab = slab_index != null;
        const prefix = if (comptime is_gc) (if (metadata_in_slab) 0 else gcPrefixSize(T)) else 0;
        const bytes = prefix + @sizeOf(T);
        try self.checkAllocation(bytes);
        if (comptime trigger_gc) {
            self.triggerGCBeforeAllocation(bytes);
        }
        const next_allocated_bytes = std.math.add(usize, self.allocated_bytes, bytes) catch return error.OutOfMemory;
        const raw = if (comptime is_gc)
            try self.rawAllocForGc(bytes, alignment, slab_index)
        else
            try self.rawAlloc(bytes, alignment);
        const obj_addr = @intFromPtr(raw) + prefix;
        if (comptime is_gc) initGcPrefix(T, @ptrFromInt(obj_addr - gc_prefix_size), metadata_in_slab);
        const ptr: *T = if (comptime is_gc)
            @ptrFromInt(obj_addr)
        else
            @ptrCast(@alignCast(raw));
        self.allocated_bytes = next_allocated_bytes;
        if (comptime diagnostic_accounting_enabled) {
            self.allocation_count += 1;
            self.create_calls += 1;
            self.updatePeak();
            if (self.profile_alloc_count) |counter| counter.* +|= 1;
            self.traceAlloc(@sizeOf(T), 1, @intFromPtr(ptr));
        }
        return ptr;
    }

    pub fn destroy(self: *MemoryAccount, comptime T: type, ptr: *T) void {
        if (comptime diagnostic_accounting_enabled) self.traceFree(@intFromPtr(ptr));
        const is_gc = comptime isGcObject(T);
        const alignment = if (comptime is_gc) gcAlignment(T) else std.mem.Alignment.of(T);
        const slab_index = if (comptime is_gc) self.gcSlabClassIndex(@sizeOf(T), alignment) else null;
        const metadata_in_slab = slab_index != null;
        const prefix = if (comptime is_gc) (if (metadata_in_slab) 0 else gcPrefixSize(T)) else 0;
        const bytes = prefix + @sizeOf(T);
        self.allocated_bytes -= bytes;
        if (comptime diagnostic_accounting_enabled) {
            self.allocation_count -= 1;
            self.destroy_calls += 1;
        }
        const base: usize = @intFromPtr(ptr) - prefix;
        const bytes_ptr: [*]u8 = @ptrFromInt(base);
        if (comptime is_gc) {
            self.rawFreeForGc(bytes_ptr[0..bytes], alignment, slab_index);
        } else {
            self.rawFree(bytes_ptr[0..bytes], alignment);
        }
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
        const alignment = comptime gcAlignment(T);
        const slab_index = self.gcSlabClassIndex(payload_bytes, alignment);
        const metadata_in_slab = slab_index != null;
        const prefix = if (metadata_in_slab) 0 else comptime gcPrefixSize(T);
        const bytes = std.math.add(usize, prefix, payload_bytes) catch return error.OutOfMemory;
        try self.checkAllocation(bytes);
        if (comptime trigger_gc) {
            self.triggerGCBeforeAllocation(bytes);
        }
        const next_allocated_bytes = std.math.add(usize, self.allocated_bytes, bytes) catch return error.OutOfMemory;
        const raw = try self.rawAllocForGc(bytes, alignment, slab_index);
        const obj_addr = @intFromPtr(raw) + prefix;
        initGcPrefix(T, @ptrFromInt(obj_addr - gc_prefix_size), metadata_in_slab);
        const ptr: *T = @ptrFromInt(obj_addr);
        self.allocated_bytes = next_allocated_bytes;
        if (comptime diagnostic_accounting_enabled) {
            self.allocation_count += 1;
            self.create_calls += 1;
            self.updatePeak();
            if (self.profile_alloc_count) |counter| counter.* +|= 1;
            self.traceAlloc(1, bytes, @intFromPtr(ptr));
        }
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
        const slab_index = self.gcSlabClassIndex(payload_bytes, alignment);
        const metadata_in_slab = slab_index != null;
        const prefix = if (metadata_in_slab) 0 else comptime gcPrefixSize(T);
        const bytes = prefix + payload_bytes;
        self.allocated_bytes -= bytes;
        if (comptime diagnostic_accounting_enabled) {
            self.allocation_count -= 1;
            self.destroy_calls += 1;
        }
        const base: usize = @intFromPtr(ptr) - prefix;
        const bytes_ptr: [*]u8 = @ptrFromInt(base);
        self.rawFreeForGc(bytes_ptr[0..bytes], alignment, slab_index);
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
        self.small_slab.deinit(self.persistent_allocator);
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
        // Runtime-owned accounts install this after GC initialization. In the
        // forced-GC build, the same trigger performs a full collection here,
        // before the backing allocation.
        if (self.trigger_gc_fn) |trigger| trigger(self.trigger_gc_ctx, byte_count);
    }

    fn updatePeak(self: *MemoryAccount) void {
        self.peak_allocated_bytes = @max(self.peak_allocated_bytes, self.allocated_bytes);
        self.peak_allocation_count = @max(self.peak_allocation_count, self.allocation_count);
    }

    inline fn rawAlloc(self: *MemoryAccount, byte_count: usize, alignment: std.mem.Alignment) ![*]u8 {
        if (self.small_slab_enabled) {
            if (SmallObjectSlab.classIndex(byte_count, alignment)) |index| {
                return self.small_slab.allocAtIndex(self.persistent_allocator, index);
            }
        }
        return self.persistent_allocator.rawAlloc(byte_count, alignment, @returnAddress()) orelse error.OutOfMemory;
    }

    inline fn rawFree(self: *MemoryAccount, bytes: []u8, alignment: std.mem.Alignment) void {
        if (self.small_slab_enabled) {
            if (SmallObjectSlab.classIndex(bytes.len, alignment)) |index| {
                // The runtime enables the slab before managed allocations begin;
                // while enabled, every eligible allocation comes from it.
                self.small_slab.freeAtIndex(self.persistent_allocator, bytes.ptr, index);
                return;
            }
        }
        self.persistent_allocator.rawFree(bytes, alignment, @returnAddress());
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

test "small object slab retains one empty arena as a reusable reserve" {
    var slab: SmallObjectSlab = .{};
    defer slab.deinit(std.testing.allocator);

    const alloc = try slab.alloc(std.testing.allocator, 64, .@"8");
    const index = SmallObjectSlab.classIndex(64, .@"8").?;
    try std.testing.expectEqual(@as(usize, 1), slab.debugArenaCount(index));

    slab.free(std.testing.allocator, alloc[0..64], .@"8");
    try std.testing.expectEqual(@as(usize, 1), slab.debugArenaCount(index));

    const reused = try slab.alloc(std.testing.allocator, 64, .@"8");
    try std.testing.expectEqual(@intFromPtr(alloc), @intFromPtr(reused));
    slab.free(std.testing.allocator, reused[0..64], .@"8");
    try std.testing.expectEqual(@as(usize, 1), slab.debugArenaCount(index));
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
    try std.testing.expectEqual(@as(usize, 2), slab.debugArenaCount(index));

    slab.free(std.testing.allocator, allocations[first_arena_capacity][0..64], .@"8");
    try std.testing.expectEqual(@as(usize, 1), slab.debugArenaCount(index));
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
    try std.testing.expectEqual(TestGc.gc_kind_tag, second_meta[2]);
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

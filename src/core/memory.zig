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
        block_size_idx: u8,
        reserved: u8 = 0,
        padding: u32 = 0,
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

    pub inline fn alloc(self: *SmallObjectSlab, backing: std.mem.Allocator, byte_count: usize, alignment: std.mem.Alignment) ![*]u8 {
        const index = classIndex(byte_count, alignment).?;
        var arena = self.free_arenas[index] orelse try self.addArena(backing, index);
        const block_size = block_sizes[index];
        const block_idx = arena.first_free_block;
        std.debug.assert(block_idx != free_nil);
        const header = blockHeaderAt(arena, block_idx, block_size);
        arena.first_free_block = header.index_or_next;
        header.index_or_next = block_idx;
        arena.used_blocks += 1;
        if (arena.used_blocks == arena.block_count) {
            self.removeFreeArena(index, arena);
        }
        return userData(header);
    }

    pub inline fn free(self: *SmallObjectSlab, backing: std.mem.Allocator, bytes: []u8, alignment: std.mem.Alignment) void {
        _ = classIndex(bytes.len, alignment).?;
        const header = blockHeaderFromUser(bytes.ptr);
        const block_idx = header.index_or_next;
        const index = header.block_size_idx;
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
            self.removeArena(index, arena);
            self.removeFreeArena(index, arena);
            backing.rawFree(arenaAllocation(arena), slab_alignment, @returnAddress());
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
                .block_size_idx = @intCast(index),
            };
        }
        self.addArenaList(index, arena);
        self.addFreeArena(index, arena);
        return arena;
    }

    inline fn classIndex(byte_count: usize, alignment: std.mem.Alignment) ?usize {
        if (alignment.compare(.gt, slab_alignment)) return null;
        const total_size = totalBlockSize(byte_count) orelse return null;
        inline for (block_sizes, 0..) |block_size, index| {
            if (total_size <= block_size) return index;
        }
        return null;
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
    allocator: std.mem.Allocator,
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
        // GC objects (header at offset 0) carry an 8-byte metadata prefix before
        // the object. They are only ever allocated singly (`alloc(T, 1)`), e.g.
        // FunctionBytecode; arrays of pointers/values are NOT GC objects.
        const is_gc = comptime isGcObject(T);
        if (comptime is_gc) std.debug.assert(count == 1);
        const prefix = comptime if (is_gc) gcPrefixSize(T) else 0;
        const payload_bytes = std.math.mul(usize, @sizeOf(T), count) catch return error.OutOfMemory;
        const bytes = prefix + payload_bytes;
        try self.checkAllocation(bytes);
        if (comptime trigger_gc) {
            self.triggerGCBeforeAllocation(bytes);
        }
        const next_allocated_bytes = std.math.add(usize, self.allocated_bytes, bytes) catch return error.OutOfMemory;
        const alignment = if (comptime is_gc) gcAlignment(T) else std.mem.Alignment.of(T);
        const raw = try self.rawAlloc(bytes, alignment);
        const obj_addr = @intFromPtr(raw) + prefix;
        if (comptime is_gc) initGcPrefix(T, @ptrFromInt(obj_addr - gc_prefix_size));
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
        const prefix = comptime if (is_gc) gcPrefixSize(T) else 0;
        const payload_bytes = std.math.mul(usize, @sizeOf(T), slice.len) catch return;
        const bytes = prefix + payload_bytes;
        self.allocated_bytes -= bytes;
        if (comptime diagnostic_accounting_enabled) {
            self.allocation_count -= 1;
            self.free_calls += 1;
        }
        const base: usize = @intFromPtr(slice.ptr) - prefix;
        const bytes_ptr: [*]u8 = @ptrFromInt(base);
        const alignment = if (comptime is_gc) gcAlignment(T) else std.mem.Alignment.of(T);
        self.rawFree(bytes_ptr[0..bytes], alignment);
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

    /// Size of the metadata prefix the allocator places before every GC object.
    /// MUST equal `@sizeOf(gc.Metadata)` (asserted there). Hardcoded to avoid a
    /// circular import (gc.zig imports memory.zig).
    const gc_prefix_size: usize = 8;

    /// A GC object is any struct whose first field (`header`, offset 0) is the
    /// 16-byte intrusive-list `BlockHeader` (`prev`/`next`). Such objects carry
    /// their refcount/kind/flags in an 8-byte prefix at `objectPtr - 8`; plain
    /// allocations (and the 4-byte `StringHeader`, which has no prev/next) do not.
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

    /// Initialize the 8-byte GC metadata at `meta` (= objectPtr - 8) to
    /// {size_class:0, kind:T.gc_kind_tag, flags:0, rc:1}. Written as raw bytes
    /// (memory.zig has no gc import); the kind@2 / rc@4 offsets are asserted in gc.zig.
    inline fn initGcPrefix(comptime T: type, meta: [*]u8) void {
        @memset(meta[0..gc_prefix_size], 0);
        meta[2] = T.gc_kind_tag;
        meta[4] = 1;
    }

    fn createInternal(self: *MemoryAccount, comptime T: type, comptime trigger_gc: bool) !*T {
        if (comptime oom_coverage_enabled) oom_coverage.record(@returnAddress());
        const is_gc = comptime isGcObject(T);
        const prefix = comptime if (is_gc) gcPrefixSize(T) else 0;
        const bytes = prefix + @sizeOf(T);
        try self.checkAllocation(bytes);
        if (comptime trigger_gc) {
            self.triggerGCBeforeAllocation(bytes);
        }
        const next_allocated_bytes = std.math.add(usize, self.allocated_bytes, bytes) catch return error.OutOfMemory;
        const alignment = if (comptime is_gc) gcAlignment(T) else std.mem.Alignment.of(T);
        const raw = try self.rawAlloc(bytes, alignment);
        const obj_addr = @intFromPtr(raw) + prefix;
        if (comptime is_gc) initGcPrefix(T, @ptrFromInt(obj_addr - gc_prefix_size));
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
            self.traceAlloc(bytes, 1, @intFromPtr(ptr));
        }
        return ptr;
    }

    pub fn destroy(self: *MemoryAccount, comptime T: type, ptr: *T) void {
        if (comptime diagnostic_accounting_enabled) self.traceFree(@intFromPtr(ptr));
        const is_gc = comptime isGcObject(T);
        const prefix = comptime if (is_gc) gcPrefixSize(T) else 0;
        const bytes = prefix + @sizeOf(T);
        self.allocated_bytes -= bytes;
        if (comptime diagnostic_accounting_enabled) {
            self.allocation_count -= 1;
            self.destroy_calls += 1;
        }
        const base: usize = @intFromPtr(ptr) - prefix;
        const bytes_ptr: [*]u8 = @ptrFromInt(base);
        const alignment = if (comptime is_gc) gcAlignment(T) else std.mem.Alignment.of(T);
        self.rawFree(bytes_ptr[0..bytes], alignment);
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
        if (self.small_slab_enabled and SmallObjectSlab.canUse(byte_count, alignment)) {
            return self.small_slab.alloc(self.persistent_allocator, byte_count, alignment);
        }
        return self.persistent_allocator.rawAlloc(byte_count, alignment, @returnAddress()) orelse error.OutOfMemory;
    }

    inline fn rawFree(self: *MemoryAccount, bytes: []u8, alignment: std.mem.Alignment) void {
        if (self.small_slab_enabled and SmallObjectSlab.canUse(bytes.len, alignment)) {
            // The runtime enables the slab before managed allocations begin; while
            // enabled, every slab-eligible MemoryAccount allocation comes from it.
            self.small_slab.free(self.persistent_allocator, bytes, alignment);
            return;
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

test "small object slab releases empty arenas" {
    var slab: SmallObjectSlab = .{};
    defer slab.deinit(std.testing.allocator);

    const alloc = try slab.alloc(std.testing.allocator, 64, .@"8");
    const index = SmallObjectSlab.classIndex(64, .@"8").?;
    try std.testing.expectEqual(@as(usize, 1), slab.debugArenaCount(index));

    slab.free(std.testing.allocator, alloc[0..64], .@"8");
    try std.testing.expectEqual(@as(usize, 0), slab.debugArenaCount(index));
}

test "small object slab keeps non-empty arenas reusable" {
    var slab: SmallObjectSlab = .{};
    defer slab.deinit(std.testing.allocator);

    const first = try slab.alloc(std.testing.allocator, 64, .@"8");
    const second = try slab.alloc(std.testing.allocator, 64, .@"8");
    const index = SmallObjectSlab.classIndex(64, .@"8").?;
    try std.testing.expectEqual(@as(usize, 1), slab.debugArenaCount(index));

    slab.free(std.testing.allocator, first[0..64], .@"8");
    try std.testing.expectEqual(@as(usize, 1), slab.debugArenaCount(index));

    const reused = try slab.alloc(std.testing.allocator, 64, .@"8");
    try std.testing.expectEqual(@intFromPtr(first), @intFromPtr(reused));

    slab.free(std.testing.allocator, second[0..64], .@"8");
    try std.testing.expectEqual(@as(usize, 1), slab.debugArenaCount(index));

    slab.free(std.testing.allocator, reused[0..64], .@"8");
    try std.testing.expectEqual(@as(usize, 0), slab.debugArenaCount(index));
}

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
    const slab_alignment: std.mem.Alignment = .@"16";
    const block_sizes = [_]usize{ 16, 24, 32, 48, 64, 80, 96, 128, 160, 192, 256, 320, 384, 448, 512 };

    const FreeNode = extern struct {
        next: ?*FreeNode,
    };

    const Arena = struct {
        next: ?*Arena = null,
        storage: []u8 = &.{},
        used: usize = 0,
    };

    arenas: ?*Arena = null,
    current: [block_sizes.len]?*Arena = @splat(null),
    free_lists: [block_sizes.len]?*FreeNode = @splat(null),

    pub inline fn canUse(byte_count: usize, alignment: std.mem.Alignment) bool {
        return classIndex(byte_count, alignment) != null;
    }

    pub inline fn alloc(self: *SmallObjectSlab, backing: std.mem.Allocator, byte_count: usize, alignment: std.mem.Alignment) ![*]u8 {
        const index = classIndex(byte_count, alignment).?;
        if (self.free_lists[index]) |node| {
            self.free_lists[index] = node.next;
            const ptr: [*]u8 = @ptrCast(node);
            return ptr;
        }
        return self.allocSlow(backing, index);
    }

    pub inline fn free(self: *SmallObjectSlab, bytes: []u8, alignment: std.mem.Alignment) void {
        const index = classIndex(bytes.len, alignment).?;
        const node: *FreeNode = @ptrCast(@alignCast(bytes.ptr));
        node.next = self.free_lists[index];
        self.free_lists[index] = node;
    }

    pub fn owns(self: SmallObjectSlab, ptr: [*]const u8) bool {
        const address = @intFromPtr(ptr);
        var arena = self.arenas;
        while (arena) |node| : (arena = node.next) {
            const start = @intFromPtr(node.storage.ptr);
            const end = start + node.storage.len;
            if (address >= start and address < end) return true;
        }
        return false;
    }

    pub fn deinit(self: *SmallObjectSlab, backing: std.mem.Allocator) void {
        var arena = self.arenas;
        while (arena) |node| {
            arena = node.next;
            backing.rawFree(node.storage, slab_alignment, @returnAddress());
            backing.destroy(node);
        }
        self.* = .{};
    }

    noinline fn allocSlow(self: *SmallObjectSlab, backing: std.mem.Allocator, index: usize) ![*]u8 {
        const block_size = block_sizes[index];
        var arena = self.current[index];
        if (arena == null or arena.?.used + block_size > arena.?.storage.len) {
            arena = try self.addArena(backing, index);
        }
        const node = arena.?;
        const ptr = node.storage.ptr + node.used;
        node.used += block_size;
        return ptr;
    }

    fn addArena(self: *SmallObjectSlab, backing: std.mem.Allocator, index: usize) !*Arena {
        const storage_ptr = backing.rawAlloc(arena_size, slab_alignment, @returnAddress()) orelse return error.OutOfMemory;
        errdefer backing.rawFree(storage_ptr[0..arena_size], slab_alignment, @returnAddress());
        const arena = try backing.create(Arena);
        arena.* = .{
            .next = self.arenas,
            .storage = storage_ptr[0..arena_size],
            .used = 0,
        };
        self.arenas = arena;
        self.current[index] = arena;
        return arena;
    }

    inline fn classIndex(byte_count: usize, alignment: std.mem.Alignment) ?usize {
        if (byte_count == 0 or byte_count > max_size) return null;
        if (alignment.compare(.gt, slab_alignment)) return null;
        const align_bytes = alignment.toByteUnits();
        inline for (block_sizes, 0..) |block_size, index| {
            if (byte_count <= block_size and block_size % align_bytes == 0) return index;
        }
        return null;
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
        const bytes = std.math.mul(usize, @sizeOf(T), count) catch return error.OutOfMemory;
        try self.checkAllocation(bytes);
        const next_allocated_bytes = std.math.add(usize, self.allocated_bytes, bytes) catch return error.OutOfMemory;
        if (comptime trigger_gc) {
            if (self.trigger_gc_fn) |trigger| trigger(self.trigger_gc_ctx, bytes);
        }
        const raw = try self.rawAlloc(bytes, std.mem.Alignment.of(T));
        const ptr: [*]T = @ptrCast(@alignCast(raw));
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
        const bytes = std.math.mul(usize, @sizeOf(T), slice.len) catch return;
        self.allocated_bytes -= bytes;
        if (comptime diagnostic_accounting_enabled) {
            self.allocation_count -= 1;
            self.free_calls += 1;
        }
        const bytes_ptr: [*]u8 = @ptrCast(slice.ptr);
        self.rawFree(bytes_ptr[0..bytes], std.mem.Alignment.of(T));
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
        const next_allocated_bytes = std.math.add(usize, self.allocated_bytes, byte_count) catch return error.OutOfMemory;
        if (comptime trigger_gc) {
            if (self.trigger_gc_fn) |trigger| trigger(self.trigger_gc_ctx, byte_count);
        }
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

    fn createInternal(self: *MemoryAccount, comptime T: type, comptime trigger_gc: bool) !*T {
        if (comptime oom_coverage_enabled) oom_coverage.record(@returnAddress());
        const bytes = @sizeOf(T);
        try self.checkAllocation(bytes);
        const next_allocated_bytes = std.math.add(usize, self.allocated_bytes, bytes) catch return error.OutOfMemory;
        if (comptime trigger_gc) {
            if (self.trigger_gc_fn) |trigger| trigger(self.trigger_gc_ctx, bytes);
        }
        const raw = try self.rawAlloc(bytes, std.mem.Alignment.of(T));
        const ptr: *T = @ptrCast(@alignCast(raw));
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
        self.allocated_bytes -= @sizeOf(T);
        if (comptime diagnostic_accounting_enabled) {
            self.allocation_count -= 1;
            self.destroy_calls += 1;
        }
        const bytes_ptr: [*]u8 = @ptrCast(ptr);
        self.rawFree(bytes_ptr[0..@sizeOf(T)], std.mem.Alignment.of(T));
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
        if (self.small_slab_enabled and SmallObjectSlab.canUse(bytes.len, alignment) and self.small_slab.owns(bytes.ptr)) {
            self.small_slab.free(bytes, alignment);
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

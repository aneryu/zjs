const std = @import("std");
const build_options = @import("build_options");

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

pub const MemoryAccount = struct {
    allocator: std.mem.Allocator,
    persistent_allocator: std.mem.Allocator,
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
    pub fn alloc(self: *MemoryAccount, comptime T: type, count: usize) ![]T {
        if (comptime oom_coverage_enabled) oom_coverage.record(@returnAddress());
        if (count == 0) return &.{};
        const bytes = std.math.mul(usize, @sizeOf(T), count) catch return error.OutOfMemory;
        try self.checkAllocation(bytes);
        const next_allocated_bytes = std.math.add(usize, self.allocated_bytes, bytes) catch return error.OutOfMemory;
        if (self.trigger_gc_fn) |trigger| trigger(self.trigger_gc_ctx, bytes);
        const slice = try self.persistent_allocator.alloc(T, count);
        self.allocated_bytes = next_allocated_bytes;
        self.allocation_count += 1;
        self.alloc_calls += 1;
        self.updatePeak();
        if (self.profile_alloc_count) |counter| counter.* +|= 1;
        self.traceAlloc(@sizeOf(T), count, @intFromPtr(slice.ptr));
        return slice;
    }

    pub fn free(self: *MemoryAccount, comptime T: type, slice: []T) void {
        if (slice.len == 0) return;
        self.traceFree(@intFromPtr(slice.ptr));
        const bytes = std.math.mul(usize, @sizeOf(T), slice.len) catch return;
        self.allocated_bytes -= bytes;
        self.allocation_count -= 1;
        self.free_calls += 1;
        self.persistent_allocator.free(slice);
    }

    pub fn allocAlignedBytes(self: *MemoryAccount, byte_count: usize, alignment: std.mem.Alignment) ![]u8 {
        if (comptime oom_coverage_enabled) oom_coverage.record(@returnAddress());
        if (byte_count == 0) return &.{};
        try self.checkAllocation(byte_count);
        const next_allocated_bytes = std.math.add(usize, self.allocated_bytes, byte_count) catch return error.OutOfMemory;
        if (self.trigger_gc_fn) |trigger| trigger(self.trigger_gc_ctx, byte_count);
        const ptr = self.persistent_allocator.rawAlloc(byte_count, alignment, @returnAddress()) orelse return error.OutOfMemory;
        self.allocated_bytes = next_allocated_bytes;
        self.allocation_count += 1;
        self.alloc_calls += 1;
        self.updatePeak();
        if (self.profile_alloc_count) |counter| counter.* +|= 1;
        self.traceAlloc(1, byte_count, @intFromPtr(ptr));
        return ptr[0..byte_count];
    }

    pub fn freeAlignedBytes(self: *MemoryAccount, bytes: []u8, alignment: std.mem.Alignment) void {
        if (bytes.len == 0) return;
        self.traceFree(@intFromPtr(bytes.ptr));
        self.allocated_bytes -= bytes.len;
        self.allocation_count -= 1;
        self.free_calls += 1;
        self.persistent_allocator.rawFree(bytes, alignment, @returnAddress());
    }

    /// Returns owned memory. Caller must destroy it with `destroy`.
    pub fn create(self: *MemoryAccount, comptime T: type) !*T {
        if (comptime oom_coverage_enabled) oom_coverage.record(@returnAddress());
        const bytes = @sizeOf(T);
        try self.checkAllocation(bytes);
        const next_allocated_bytes = std.math.add(usize, self.allocated_bytes, bytes) catch return error.OutOfMemory;
        if (self.trigger_gc_fn) |trigger| trigger(self.trigger_gc_ctx, bytes);
        const ptr = try self.persistent_allocator.create(T);
        self.allocated_bytes = next_allocated_bytes;
        self.allocation_count += 1;
        self.create_calls += 1;
        self.updatePeak();
        if (self.profile_alloc_count) |counter| counter.* +|= 1;
        self.traceAlloc(@sizeOf(T), 1, @intFromPtr(ptr));
        return ptr;
    }

    pub fn destroy(self: *MemoryAccount, comptime T: type, ptr: *T) void {
        self.traceFree(@intFromPtr(ptr));
        self.allocated_bytes -= @sizeOf(T);
        self.allocation_count -= 1;
        self.destroy_calls += 1;
        self.persistent_allocator.destroy(ptr);
    }

    pub fn hasOutstandingAllocations(self: MemoryAccount) bool {
        return self.allocated_bytes != 0 or self.allocation_count != 0;
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

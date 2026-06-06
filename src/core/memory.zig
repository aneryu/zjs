const std = @import("std");

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

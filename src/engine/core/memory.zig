const std = @import("std");

pub const MemoryAccount = struct {
    allocator: std.mem.Allocator,
    allocated_bytes: usize = 0,
    allocation_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator) MemoryAccount {
        return .{ .allocator = allocator };
    }

    /// Returns owned memory. Caller must free it with `free`.
    pub fn alloc(self: *MemoryAccount, comptime T: type, count: usize) ![]T {
        const slice = try self.allocator.alloc(T, count);
        self.allocated_bytes += @sizeOf(T) * count;
        self.allocation_count += 1;
        return slice;
    }

    pub fn free(self: *MemoryAccount, comptime T: type, slice: []T) void {
        self.allocated_bytes -= @sizeOf(T) * slice.len;
        self.allocation_count -= 1;
        self.allocator.free(slice);
    }

    /// Returns owned memory. Caller must destroy it with `destroy`.
    pub fn create(self: *MemoryAccount, comptime T: type) !*T {
        const ptr = try self.allocator.create(T);
        self.allocated_bytes += @sizeOf(T);
        self.allocation_count += 1;
        return ptr;
    }

    pub fn destroy(self: *MemoryAccount, comptime T: type, ptr: *T) void {
        self.allocated_bytes -= @sizeOf(T);
        self.allocation_count -= 1;
        self.allocator.destroy(ptr);
    }

    pub fn hasOutstandingAllocations(self: MemoryAccount) bool {
        return self.allocated_bytes != 0 or self.allocation_count != 0;
    }
};

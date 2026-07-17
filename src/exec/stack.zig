const std = @import("std");

const memory = @import("../core/memory.zig");
const runtime = @import("../core/runtime.zig");
const JSValue = @import("../core/value.zig").JSValue;

pub const Stack = struct {
    const Policy = runtime.VmStackWindowPolicy;

    memory: *memory.MemoryAccount,
    /// Base of the operand-stack backing allocation. `top_ptr` is the
    /// authoritative end of the live prefix; keeping both as raw pointers
    /// avoids rebuilding a slice at every VM/cold-helper seam.
    values: [*]JSValue,
    top_ptr: [*]JSValue,
    capacity: usize = 0,
    /// Stack limit and the two mutually independent backing-ownership flags in
    /// one word. A 62-bit slot limit is far beyond any addressable JSValue
    /// buffer while avoiding the six bytes of tail padding the booleans created.
    policy: Policy,

    pub fn init(account: *memory.MemoryAccount, limit: usize) Stack {
        const empty = emptyPtr();
        return .{
            .memory = account,
            .values = empty,
            .top_ptr = empty,
            .policy = Policy.forLimit(limit),
        };
    }

    pub fn initArenaWindow(account: *memory.MemoryAccount, policy: Policy, window: []JSValue) Stack {
        std.debug.assert(policy.arena_window and !policy.resident_window);
        return .{
            .memory = account,
            .values = window.ptr,
            .top_ptr = window.ptr,
            .capacity = window.len,
            .policy = policy,
        };
    }

    inline fn emptyPtr() [*]JSValue {
        // Zig slices cannot carry a null pointer, so an empty Stack uses a
        // non-dereferenceable aligned address for both endpoints.
        return @ptrFromInt(@alignOf(JSValue));
    }

    pub inline fn stackLimit(self: *const Stack) usize {
        return @intCast(self.policy.limit);
    }

    pub inline fn isArenaWindow(self: *const Stack) bool {
        return self.policy.arena_window;
    }

    pub inline fn setArenaWindow(self: *Stack, value: bool) void {
        self.policy.arena_window = value;
    }

    pub inline fn isResidentWindow(self: *const Stack) bool {
        return self.policy.resident_window;
    }

    pub inline fn setResidentWindow(self: *Stack, value: bool) void {
        self.policy.resident_window = value;
    }

    pub inline fn basePtr(self: *const Stack) [*]JSValue {
        return self.values;
    }

    pub inline fn topPtr(self: *const Stack) [*]JSValue {
        return self.top_ptr;
    }

    pub inline fn len(self: *const Stack) usize {
        return (@intFromPtr(self.top_ptr) - @intFromPtr(self.values)) / @sizeOf(JSValue);
    }

    pub inline fn liveValues(self: *const Stack) []JSValue {
        return self.values[0..self.len()];
    }

    pub inline fn backingValues(self: *const Stack) []JSValue {
        return self.values[0..self.capacity];
    }

    pub inline fn setLen(self: *Stack, new_len: usize) void {
        std.debug.assert(new_len <= self.capacity);
        self.top_ptr = self.values + new_len;
    }

    pub inline fn setTopPtr(self: *Stack, new_top: [*]JSValue) void {
        const base_addr = @intFromPtr(self.values);
        const top_addr = @intFromPtr(new_top);
        std.debug.assert(top_addr >= base_addr);
        std.debug.assert(top_addr - base_addr <= self.capacity * @sizeOf(JSValue));
        std.debug.assert((top_addr - base_addr) % @sizeOf(JSValue) == 0);
        self.top_ptr = new_top;
    }

    /// Install a backing allocation whose live prefix is described by
    /// `live_values`. Used only at the generator ownership-transfer seam.
    pub inline fn installBacking(self: *Stack, live_values: []JSValue, backing_capacity: usize) void {
        std.debug.assert(live_values.len <= backing_capacity);
        self.values = live_values.ptr;
        self.top_ptr = live_values.ptr + live_values.len;
        self.capacity = backing_capacity;
    }

    /// Drop this Stack's borrowed view after ownership moved elsewhere.
    pub inline fn clearBacking(self: *Stack) void {
        const empty = emptyPtr();
        self.values = empty;
        self.top_ptr = empty;
        self.capacity = 0;
    }

    pub inline fn deinit(self: *Stack, rt: anytype) void {
        const values = self.liveValues();
        const backing = self.backingValues();
        const stack_capacity = self.capacity;
        const arena_window = self.policy.arena_window;
        const resident_window = self.policy.resident_window;
        self.clearBacking();
        self.policy.arena_window = false;
        self.policy.resident_window = false;
        for (values) |*slot| {
            const value = slot.*;
            slot.* = JSValue.undefinedValue();
            value.free(rt);
        }
        if (stack_capacity != 0 and !arena_window and !resident_window) self.memory.free(JSValue, backing);
    }

    pub fn push(self: *Stack, value: JSValue) !void {
        try self.reserveAdditional(1);
        self.top_ptr[0] = if (value.requiresRefCount()) value.dup() else value;
        self.top_ptr += 1;
    }

    pub fn pushOwned(self: *Stack, value: JSValue) !void {
        try self.reserveAdditional(1);
        self.top_ptr[0] = value;
        self.top_ptr += 1;
    }

    pub fn pushAssumeCapacity(self: *Stack, value: JSValue) void {
        std.debug.assert(self.len() < self.capacity);
        self.top_ptr[0] = if (value.requiresRefCount()) value.dup() else value;
        self.top_ptr += 1;
    }

    pub fn pushOwnedAssumeCapacity(self: *Stack, value: JSValue) void {
        std.debug.assert(self.len() < self.capacity);
        self.top_ptr[0] = value;
        self.top_ptr += 1;
    }

    pub fn pop(self: *Stack) !JSValue {
        if (self.top_ptr == self.values) return error.StackUnderflow;
        self.top_ptr -= 1;
        return self.top_ptr[0];
    }

    pub fn peek(self: Stack) ?JSValue {
        if (self.top_ptr == self.values) return null;
        return (self.top_ptr - 1)[0].dup();
    }

    pub fn peekBorrowed(self: Stack) ?JSValue {
        if (self.top_ptr == self.values) return null;
        return (self.top_ptr - 1)[0];
    }

    pub fn reserveAdditional(self: *Stack, additional: usize) !void {
        const live_len = self.len();
        const stack_limit = self.stackLimit();
        if (live_len > stack_limit or additional > stack_limit - live_len) return error.StackOverflow;
        const needed = live_len + additional;
        try self.reserveCapacityUpTo(needed, stack_limit);
    }

    pub fn reserveFrameCapacity(self: *Stack, frame_stack_size: usize) !void {
        if (frame_stack_size > self.stackLimit()) return error.StackOverflow;
        try self.reserveCapacityUpTo(frame_stack_size + 1, frame_stack_size + 1);
    }

    fn reserveCapacityUpTo(self: *Stack, needed: usize, max_capacity: usize) !void {
        const current_capacity = self.capacity;
        if (needed <= current_capacity) return;

        var next_capacity = if (current_capacity == 0) @as(usize, 8) else current_capacity;
        while (next_capacity < needed) {
            next_capacity *= 2;
            if (next_capacity > max_capacity) {
                next_capacity = max_capacity;
                break;
            }
        }
        if (next_capacity < needed) return error.StackOverflow;

        const next = try self.memory.alloc(JSValue, next_capacity);
        errdefer self.memory.free(JSValue, next);
        const old_values = self.liveValues();
        const old_backing = self.backingValues();
        const old_capacity = current_capacity;
        const old_arena_window = self.policy.arena_window;
        const old_resident_window = self.policy.resident_window;
        @memcpy(next[0..old_values.len], old_values);
        self.values = next.ptr;
        self.top_ptr = next.ptr + old_values.len;
        self.capacity = next_capacity;
        self.policy.arena_window = false;
        self.policy.resident_window = false;
        if (old_capacity != 0 and !old_arena_window and !old_resident_window) self.memory.free(JSValue, old_backing);
    }
};

/// Read the value `offset` slots below the top of the stack without popping
/// (moved from the dissolved exec/vm_utils.zig).
pub fn stackValueFromTop(stack: *const Stack, offset: u8) !JSValue {
    const index_from_top: usize = offset;
    const stack_len = stack.len();
    if (index_from_top >= stack_len) return error.StackUnderflow;
    return stack.values[stack_len - 1 - index_from_top].dup();
}

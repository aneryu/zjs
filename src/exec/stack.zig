const std = @import("std");

const memory = @import("../core/memory.zig");
const JSValue = @import("../core/value.zig").JSValue;

pub const Stack = struct {
    memory: *memory.MemoryAccount,
    values: []JSValue = &.{},
    capacity: usize = 0,
    limit: usize,
    /// True while the capacity region is a borrowed VM stack-arena window.
    /// Windows are never freed or reallocated in place; growth beyond the
    /// window migrates to an owned heap buffer and clears this flag.
    arena_window: bool = false,

    pub fn init(account: *memory.MemoryAccount, limit: usize) Stack {
        return .{ .memory = account, .limit = limit };
    }

    pub fn initArenaWindow(account: *memory.MemoryAccount, limit: usize, window: []JSValue) Stack {
        return .{
            .memory = account,
            .limit = limit,
            .values = window[0..0],
            .capacity = window.len,
            .arena_window = true,
        };
    }

    pub fn deinit(self: *Stack, rt: anytype) void {
        const values = self.values;
        const capacity = self.capacity;
        const arena_window = self.arena_window;
        self.values = &.{};
        self.capacity = 0;
        self.arena_window = false;
        for (values) |*slot| {
            const value = slot.*;
            slot.* = JSValue.undefinedValue();
            value.free(rt);
        }
        if (capacity != 0 and !arena_window) self.memory.free(JSValue, values.ptr[0..capacity]);
    }

    pub fn push(self: *Stack, value: JSValue) !void {
        try self.reserveAdditional(1);
        const old_len = self.values.len;
        self.values = self.values.ptr[0 .. old_len + 1];
        self.values[old_len] = if (value.requiresRefCount()) value.dup() else value;
    }

    pub fn pushOwned(self: *Stack, value: JSValue) !void {
        try self.reserveAdditional(1);
        const old_len = self.values.len;
        self.values = self.values.ptr[0 .. old_len + 1];
        self.values[old_len] = value;
    }

    pub fn pushAssumeCapacity(self: *Stack, value: JSValue) void {
        std.debug.assert(self.values.len < self.capacity);
        const old_len = self.values.len;
        self.values = self.values.ptr[0 .. old_len + 1];
        self.values[old_len] = if (value.requiresRefCount()) value.dup() else value;
    }

    pub fn pushOwnedAssumeCapacity(self: *Stack, value: JSValue) void {
        std.debug.assert(self.values.len < self.capacity);
        const old_len = self.values.len;
        self.values = self.values.ptr[0 .. old_len + 1];
        self.values[old_len] = value;
    }

    pub fn pop(self: *Stack) !JSValue {
        if (self.values.len == 0) return error.StackUnderflow;
        const value = self.values[self.values.len - 1];
        self.values = self.values.ptr[0 .. self.values.len - 1];
        return value;
    }

    pub fn peek(self: Stack) ?JSValue {
        if (self.values.len == 0) return null;
        return self.values[self.values.len - 1].dup();
    }

    pub fn peekBorrowed(self: Stack) ?JSValue {
        if (self.values.len == 0) return null;
        return self.values[self.values.len - 1];
    }

    pub fn len(self: Stack) usize {
        return self.values.len;
    }

    pub fn reserveAdditional(self: *Stack, additional: usize) !void {
        if (additional > self.limit - self.values.len) return error.StackOverflow;
        const needed = self.values.len + additional;
        if (needed <= self.capacity) return;

        var next_capacity = if (self.capacity == 0) @as(usize, 8) else self.capacity;
        while (next_capacity < needed) {
            next_capacity *= 2;
            if (next_capacity > self.limit) {
                next_capacity = self.limit;
                break;
            }
        }

        const next = try self.memory.alloc(JSValue, next_capacity);
        errdefer self.memory.free(JSValue, next);
        const old_values = self.values;
        const old_capacity = self.capacity;
        const old_arena_window = self.arena_window;
        @memcpy(next[0..old_values.len], old_values);
        self.values = next[0..old_values.len];
        self.capacity = next_capacity;
        self.arena_window = false;
        if (old_capacity != 0 and !old_arena_window) self.memory.free(JSValue, old_values.ptr[0..old_capacity]);
    }
};

const std = @import("std");

const memory = @import("../core/memory.zig");
const Value = @import("../core/value.zig").Value;

pub const Stack = struct {
    memory: *memory.MemoryAccount,
    values: []Value = &.{},
    capacity: usize = 0,
    limit: usize,

    pub fn init(account: *memory.MemoryAccount, limit: usize) Stack {
        return .{ .memory = account, .limit = limit };
    }

    pub fn deinit(self: *Stack, rt: anytype) void {
        const values = self.values;
        const capacity = self.capacity;
        self.values = &.{};
        self.capacity = 0;
        for (values) |*slot| {
            const value = slot.*;
            slot.* = Value.undefinedValue();
            value.free(rt);
        }
        if (capacity != 0) self.memory.free(Value, values.ptr[0..capacity]);
    }

    pub fn push(self: *Stack, value: Value) !void {
        try self.reserveAdditional(1);
        const old_len = self.values.len;
        self.values = self.values.ptr[0 .. old_len + 1];
        self.values[old_len] = if (value.requiresRefCount()) value.dup() else value;
    }

    pub fn pushOwned(self: *Stack, value: Value) !void {
        try self.reserveAdditional(1);
        const old_len = self.values.len;
        self.values = self.values.ptr[0 .. old_len + 1];
        self.values[old_len] = value;
    }

    pub fn pushAssumeCapacity(self: *Stack, value: Value) void {
        std.debug.assert(self.values.len < self.capacity);
        const old_len = self.values.len;
        self.values = self.values.ptr[0 .. old_len + 1];
        self.values[old_len] = if (value.requiresRefCount()) value.dup() else value;
    }

    pub fn pushOwnedAssumeCapacity(self: *Stack, value: Value) void {
        std.debug.assert(self.values.len < self.capacity);
        const old_len = self.values.len;
        self.values = self.values.ptr[0 .. old_len + 1];
        self.values[old_len] = value;
    }

    pub fn pop(self: *Stack) !Value {
        if (self.values.len == 0) return error.StackUnderflow;
        const value = self.values[self.values.len - 1];
        self.values = self.values.ptr[0 .. self.values.len - 1];
        return value;
    }

    pub fn peek(self: Stack) ?Value {
        if (self.values.len == 0) return null;
        return self.values[self.values.len - 1].dup();
    }

    pub fn peekBorrowed(self: Stack) ?Value {
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

        const next = try self.memory.alloc(Value, next_capacity);
        errdefer self.memory.free(Value, next);
        const old_values = self.values;
        const old_capacity = self.capacity;
        @memcpy(next[0..old_values.len], old_values);
        self.values = next[0..old_values.len];
        self.capacity = next_capacity;
        if (old_capacity != 0) self.memory.free(Value, old_values.ptr[0..old_capacity]);
    }
};

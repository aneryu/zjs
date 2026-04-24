const memory = @import("../core/memory.zig");
const Value = @import("../core/value.zig").Value;

pub const Stack = struct {
    memory: *memory.MemoryAccount,
    values: []Value = &.{},
    limit: usize,

    pub fn init(account: *memory.MemoryAccount, limit: usize) Stack {
        return .{ .memory = account, .limit = limit };
    }

    pub fn deinit(self: *Stack, rt: anytype) void {
        for (self.values) |value| value.free(rt);
        if (self.values.len != 0) self.memory.free(Value, self.values);
        self.values = &.{};
    }

    pub fn push(self: *Stack, value: Value) !void {
        if (self.values.len >= self.limit) return error.StackOverflow;
        const next = try self.memory.alloc(Value, self.values.len + 1);
        errdefer self.memory.free(Value, next);
        @memcpy(next[0..self.values.len], self.values);
        next[self.values.len] = value.dup();
        if (self.values.len != 0) self.memory.free(Value, self.values);
        self.values = next;
    }

    pub fn pop(self: *Stack) !Value {
        if (self.values.len == 0) return error.StackUnderflow;
        const value = self.values[self.values.len - 1];
        if (self.values.len == 1) {
            self.memory.free(Value, self.values);
            self.values = &.{};
            return value;
        }
        const next = try self.memory.alloc(Value, self.values.len - 1);
        errdefer self.memory.free(Value, next);
        @memcpy(next, self.values[0 .. self.values.len - 1]);
        self.memory.free(Value, self.values);
        self.values = next;
        return value;
    }

    pub fn peek(self: Stack) ?Value {
        if (self.values.len == 0) return null;
        return self.values[self.values.len - 1].dup();
    }

    pub fn len(self: Stack) usize {
        return self.values.len;
    }
};

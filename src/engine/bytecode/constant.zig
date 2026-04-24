const memory = @import("../core/memory.zig");
const Value = @import("../core/value.zig").Value;

pub const Pool = struct {
    memory: *memory.MemoryAccount,
    values: []Value = &.{},

    pub fn init(account: *memory.MemoryAccount) Pool {
        return .{ .memory = account };
    }

    pub fn deinit(self: *Pool, rt: anytype) void {
        for (self.values) |value| value.free(rt);
        if (self.values.len != 0) self.memory.free(Value, self.values);
        self.values = &.{};
    }

    pub fn append(self: *Pool, value: Value) !u32 {
        const next = try self.memory.alloc(Value, self.values.len + 1);
        errdefer self.memory.free(Value, next);
        @memcpy(next[0..self.values.len], self.values);
        next[self.values.len] = value.dup();
        if (self.values.len != 0) self.memory.free(Value, self.values);
        self.values = next;
        return @intCast(self.values.len - 1);
    }

    pub fn get(self: Pool, index: usize) ?Value {
        if (index >= self.values.len) return null;
        return self.values[index].dup();
    }
};

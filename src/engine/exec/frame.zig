const bytecode = @import("../bytecode/root.zig");
const memory = @import("../core/memory.zig");
const Value = @import("../core/value.zig").Value;

pub const Frame = struct {
    function: *const bytecode.Bytecode,
    pc: usize = 0,
    this_value: Value = Value.undefinedValue(),
    locals: []Value = &.{},
    args: []Value = &.{},

    pub fn init(function: *const bytecode.Bytecode) Frame {
        return .{ .function = function };
    }

    pub fn deinit(self: *Frame, account: *memory.MemoryAccount, rt: anytype) void {
        self.this_value.free(rt);
        for (self.locals) |value| value.free(rt);
        for (self.args) |value| value.free(rt);
        if (self.locals.len != 0) account.free(Value, self.locals);
        if (self.args.len != 0) account.free(Value, self.args);
        self.locals = &.{};
        self.args = &.{};
    }

    pub fn setLocal(self: *Frame, account: *memory.MemoryAccount, rt: anytype, index: usize, value: Value) !void {
        if (index >= self.locals.len) {
            const next = try account.alloc(Value, index + 1);
            errdefer account.free(Value, next);
            @memset(next, Value.undefinedValue());
            if (self.locals.len != 0) {
                @memcpy(next[0..self.locals.len], self.locals);
                account.free(Value, self.locals);
            }
            self.locals = next;
        } else {
            self.locals[index].free(rt);
        }
        self.locals[index] = value.dup();
    }
};

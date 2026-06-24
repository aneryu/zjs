const memory = @import("../core/memory.zig");
const atom = @import("../core/atom.zig");
const JSValue = @import("../core/value.zig").JSValue;

fn dupOwnedValue(atoms: *atom.AtomTable, value: JSValue) JSValue {
    _ = atoms;
    return value.dup();
}

fn takeOwnedValue(atoms: *atom.AtomTable, value: JSValue) JSValue {
    _ = atoms;
    return value;
}

fn freeOwnedValue(atoms: *atom.AtomTable, value: JSValue, rt: anytype) void {
    _ = atoms;
    value.free(rt);
}

pub const Pool = struct {
    memory: *memory.MemoryAccount,
    atoms: *atom.AtomTable,
    values: []JSValue = &.{},

    pub fn init(account: *memory.MemoryAccount, atoms: *atom.AtomTable) Pool {
        return .{ .memory = account, .atoms = atoms };
    }

    pub fn deinit(self: *Pool, rt: anytype) void {
        const values = self.values;
        self.values = &.{};
        for (values) |*slot| {
            const value = slot.*;
            slot.* = JSValue.undefinedValue();
            freeOwnedValue(self.atoms, value, rt);
        }
        if (values.len != 0) self.memory.free(JSValue, values);
    }

    pub fn append(self: *Pool, value: JSValue) !u32 {
        const old_values = self.values;
        const next = try self.memory.alloc(JSValue, self.values.len + 1);
        errdefer self.memory.free(JSValue, next);
        @memcpy(next[0..old_values.len], old_values);
        next[old_values.len] = dupOwnedValue(self.atoms, value);
        self.values = next;
        if (old_values.len != 0) self.memory.free(JSValue, old_values);
        return @intCast(self.values.len - 1);
    }

    pub fn appendOwned(self: *Pool, value: JSValue) !u32 {
        const old_values = self.values;
        const next = try self.memory.alloc(JSValue, self.values.len + 1);
        errdefer self.memory.free(JSValue, next);
        @memcpy(next[0..old_values.len], old_values);
        next[old_values.len] = takeOwnedValue(self.atoms, value);
        self.values = next;
        if (old_values.len != 0) self.memory.free(JSValue, old_values);
        return @intCast(self.values.len - 1);
    }

    pub fn get(self: Pool, index: usize) ?JSValue {
        if (index >= self.values.len) return null;
        return self.values[index].dup();
    }
};

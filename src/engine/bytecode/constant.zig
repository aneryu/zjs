const memory = @import("../core/memory.zig");
const atom = @import("../core/atom.zig");
const Value = @import("../core/value.zig").Value;

fn dupOwnedValue(atoms: *atom.AtomTable, value: Value) Value {
    if (value.asSymbolAtom()) |atom_id| return Value.symbol(atoms.dup(atom_id));
    return value.dup();
}

fn takeOwnedValue(atoms: *atom.AtomTable, value: Value) Value {
    if (value.asSymbolAtom()) |atom_id| return Value.symbol(atoms.dup(atom_id));
    return value;
}

fn freeOwnedValue(atoms: *atom.AtomTable, value: Value, rt: anytype) void {
    if (value.asSymbolAtom()) |atom_id| {
        atoms.free(atom_id);
        return;
    }
    value.free(rt);
}

pub const Pool = struct {
    memory: *memory.MemoryAccount,
    atoms: *atom.AtomTable,
    values: []Value = &.{},

    pub fn init(account: *memory.MemoryAccount, atoms: *atom.AtomTable) Pool {
        return .{ .memory = account, .atoms = atoms };
    }

    pub fn deinit(self: *Pool, rt: anytype) void {
        const values = self.values;
        self.values = &.{};
        for (values) |*slot| {
            const value = slot.*;
            slot.* = Value.undefinedValue();
            freeOwnedValue(self.atoms, value, rt);
        }
        if (values.len != 0) self.memory.free(Value, values);
    }

    pub fn append(self: *Pool, value: Value) !u32 {
        const old_values = self.values;
        const next = try self.memory.alloc(Value, self.values.len + 1);
        errdefer self.memory.free(Value, next);
        @memcpy(next[0..old_values.len], old_values);
        next[old_values.len] = dupOwnedValue(self.atoms, value);
        self.values = next;
        if (old_values.len != 0) self.memory.free(Value, old_values);
        return @intCast(self.values.len - 1);
    }

    pub fn appendOwned(self: *Pool, value: Value) !u32 {
        const old_values = self.values;
        const next = try self.memory.alloc(Value, self.values.len + 1);
        errdefer self.memory.free(Value, next);
        @memcpy(next[0..old_values.len], old_values);
        next[old_values.len] = takeOwnedValue(self.atoms, value);
        self.values = next;
        if (old_values.len != 0) self.memory.free(Value, old_values);
        return @intCast(self.values.len - 1);
    }

    pub fn get(self: Pool, index: usize) ?Value {
        if (index >= self.values.len) return null;
        return self.values[index].dup();
    }
};

const atom = @import("../core/atom.zig");
const memory = @import("../core/memory.zig");

pub const BindingKind = enum {
    var_,
    let_,
    const_,
    arg,
    function,
    catch_,
};

pub const Binding = struct {
    name: atom.Atom,
    kind: BindingKind,
    is_captured: bool = false,
    is_lexical: bool = false,
};

pub const ClosureVar = struct {
    name: atom.Atom,
    scope_index: u32,
    slot_index: u32,
    is_arg: bool = false,
};

pub const ScopeRecord = struct {
    memory: *memory.MemoryAccount,
    atoms: *atom.AtomTable,
    parent: ?u32 = null,
    bindings: []Binding = &.{},
    closure_vars: []ClosureVar = &.{},

    pub fn init(account: *memory.MemoryAccount, atoms: *atom.AtomTable, parent: ?u32) ScopeRecord {
        return .{ .memory = account, .atoms = atoms, .parent = parent };
    }

    pub fn deinit(self: *ScopeRecord) void {
        for (self.bindings) |binding| self.atoms.free(binding.name);
        for (self.closure_vars) |closure| self.atoms.free(closure.name);
        if (self.bindings.len != 0) self.memory.free(Binding, self.bindings);
        if (self.closure_vars.len != 0) self.memory.free(ClosureVar, self.closure_vars);
        self.bindings = &.{};
        self.closure_vars = &.{};
    }

    pub fn addBinding(self: *ScopeRecord, name: atom.Atom, kind: BindingKind, is_captured: bool) !u32 {
        const next = try self.memory.alloc(Binding, self.bindings.len + 1);
        errdefer self.memory.free(Binding, next);
        @memcpy(next[0..self.bindings.len], self.bindings);
        next[self.bindings.len] = .{
            .name = self.atoms.dup(name),
            .kind = kind,
            .is_captured = is_captured,
            .is_lexical = kind == .let_ or kind == .const_ or kind == .catch_,
        };
        if (self.bindings.len != 0) self.memory.free(Binding, self.bindings);
        self.bindings = next;
        return @intCast(self.bindings.len - 1);
    }

    pub fn addClosureVar(self: *ScopeRecord, name: atom.Atom, scope_index: u32, slot_index: u32, is_arg: bool) !u32 {
        const next = try self.memory.alloc(ClosureVar, self.closure_vars.len + 1);
        errdefer self.memory.free(ClosureVar, next);
        @memcpy(next[0..self.closure_vars.len], self.closure_vars);
        next[self.closure_vars.len] = .{
            .name = self.atoms.dup(name),
            .scope_index = scope_index,
            .slot_index = slot_index,
            .is_arg = is_arg,
        };
        if (self.closure_vars.len != 0) self.memory.free(ClosureVar, self.closure_vars);
        self.closure_vars = next;
        return @intCast(self.closure_vars.len - 1);
    }
};

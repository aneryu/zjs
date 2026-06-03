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
        const bindings = self.bindings;
        const closure_vars = self.closure_vars;
        self.bindings = &.{};
        self.closure_vars = &.{};
        for (bindings) |binding| self.atoms.free(binding.name);
        for (closure_vars) |closure| self.atoms.free(closure.name);
        if (bindings.len != 0) self.memory.free(Binding, bindings);
        if (closure_vars.len != 0) self.memory.free(ClosureVar, closure_vars);
    }

    pub fn addBinding(self: *ScopeRecord, name: atom.Atom, kind: BindingKind, is_captured: bool) !u32 {
        const old_bindings = self.bindings;
        const next = try self.memory.alloc(Binding, self.bindings.len + 1);
        errdefer self.memory.free(Binding, next);
        @memcpy(next[0..old_bindings.len], old_bindings);
        next[old_bindings.len] = .{
            .name = self.atoms.dup(name),
            .kind = kind,
            .is_captured = is_captured,
            .is_lexical = kind == .let_ or kind == .const_ or kind == .catch_,
        };
        self.bindings = next;
        if (old_bindings.len != 0) self.memory.free(Binding, old_bindings);
        return @intCast(self.bindings.len - 1);
    }

    pub fn addClosureVar(self: *ScopeRecord, name: atom.Atom, scope_index: u32, slot_index: u32, is_arg: bool) !u32 {
        const old_closure_vars = self.closure_vars;
        const next = try self.memory.alloc(ClosureVar, self.closure_vars.len + 1);
        errdefer self.memory.free(ClosureVar, next);
        @memcpy(next[0..old_closure_vars.len], old_closure_vars);
        next[old_closure_vars.len] = .{
            .name = self.atoms.dup(name),
            .scope_index = scope_index,
            .slot_index = slot_index,
            .is_arg = is_arg,
        };
        self.closure_vars = next;
        if (old_closure_vars.len != 0) self.memory.free(ClosureVar, old_closure_vars);
        return @intCast(self.closure_vars.len - 1);
    }
};

const atom = @import("../core/atom.zig");
const memory = @import("../core/memory.zig");
const Value = @import("../core/value.zig").Value;
const constant = @import("constant.zig");
const debug = @import("debug.zig");
const module = @import("module.zig");
const scope = @import("scope.zig");

pub const Flags = packed struct(u16) {
    has_prototype: bool = false,
    has_simple_parameter_list: bool = true,
    is_derived_class_constructor: bool = false,
    need_home_object: bool = false,
    is_async: bool = false,
    is_generator: bool = false,
    is_strict: bool = false,
    is_global_var: bool = false,
    reserved: u8 = 0,
};

/// Opcode format tag for dual-dispatch VM during parser-rewrite transition.
/// Mirrors PARSER_REWRITE_PLAN.md §F2+F3 — legacy QuickParser emits bespoke
/// `bytecode.emitter.known.*` IDs; new `qjs_parser` emits real QuickJS
/// `bytecode.opcode.op.*` IDs. The VM dispatches to the matching handler
/// table based on this flag. F2+F3 atomic swap will collapse this back
/// to a single format once all bespoke IDs are expanded.
pub const OpcodeFormat = enum(u8) {
    /// Legacy format with bespoke opcode IDs (emitter.known.*).
    legacy,
    /// QuickJS-aligned format with real opcode IDs (opcode.op.*).
    qjs,
};

pub const Bytecode = struct {
    memory: *memory.MemoryAccount,
    atoms: *atom.AtomTable,
    name: atom.Atom,
    flags: Flags = .{},
    /// Opcode format — determines which VM dispatcher handles this bytecode.
    opcode_format: OpcodeFormat = .legacy,
    arg_count: u16 = 0,
    var_count: u16 = 0,
    stack_size: u16 = 0,
    code: []u8 = &.{},
    atom_operands: []atom.Atom = &.{},
    constants: constant.Pool,
    scopes: []scope.ScopeRecord = &.{},
    module_record: ?module.Record = null,
    debug_table: ?debug.Table = null,

    pub fn init(account: *memory.MemoryAccount, atoms: *atom.AtomTable, name: atom.Atom) Bytecode {
        return .{
            .memory = account,
            .atoms = atoms,
            .name = atoms.dup(name),
            .constants = constant.Pool.init(account),
        };
    }

    pub fn deinit(self: *Bytecode, rt: anytype) void {
        self.atoms.free(self.name);
        for (self.atom_operands) |atom_id| self.atoms.free(atom_id);
        if (self.atom_operands.len != 0) self.memory.free(atom.Atom, self.atom_operands);
        if (self.code.len != 0) self.memory.free(u8, self.code);
        self.constants.deinit(rt);
        for (self.scopes) |*scope_record| scope_record.deinit();
        if (self.scopes.len != 0) self.memory.free(scope.ScopeRecord, self.scopes);
        if (self.module_record) |*record| record.deinit();
        if (self.debug_table) |*table| table.deinit();
        self.code = &.{};
        self.atom_operands = &.{};
        self.scopes = &.{};
        self.module_record = null;
        self.debug_table = null;
    }

    pub fn setCode(self: *Bytecode, bytes: []const u8) !void {
        if (self.code.len != 0) self.memory.free(u8, self.code);
        const owned = try self.memory.alloc(u8, bytes.len);
        errdefer self.memory.free(u8, owned);
        @memcpy(owned, bytes);
        self.code = owned;
    }

    pub fn addConstant(self: *Bytecode, value: Value) !u32 {
        return self.constants.append(value);
    }

    pub fn retainAtomOperand(self: *Bytecode, atom_id: atom.Atom) !void {
        const next = try self.memory.alloc(atom.Atom, self.atom_operands.len + 1);
        errdefer self.memory.free(atom.Atom, next);
        @memcpy(next[0..self.atom_operands.len], self.atom_operands);
        next[self.atom_operands.len] = self.atoms.dup(atom_id);
        if (self.atom_operands.len != 0) self.memory.free(atom.Atom, self.atom_operands);
        self.atom_operands = next;
    }

    pub fn addScope(self: *Bytecode, parent: ?u32) !*scope.ScopeRecord {
        const next = try self.memory.alloc(scope.ScopeRecord, self.scopes.len + 1);
        errdefer self.memory.free(scope.ScopeRecord, next);
        @memcpy(next[0..self.scopes.len], self.scopes);
        next[self.scopes.len] = scope.ScopeRecord.init(self.memory, self.atoms, parent);
        if (self.scopes.len != 0) self.memory.free(scope.ScopeRecord, self.scopes);
        self.scopes = next;
        return &self.scopes[self.scopes.len - 1];
    }

    pub fn ensureModule(self: *Bytecode) *module.Record {
        if (self.module_record == null) self.module_record = module.Record.init(self.memory, self.atoms);
        return &self.module_record.?;
    }

    pub fn ensureDebug(self: *Bytecode, filename: atom.Atom) *debug.Table {
        if (self.debug_table == null) self.debug_table = debug.Table.init(self.memory, self.atoms, filename);
        return &self.debug_table.?;
    }
};

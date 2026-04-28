const atom = @import("../core/atom.zig");
const memory = @import("../core/memory.zig");
const Value = @import("../core/value.zig").Value;
const constant = @import("constant.zig");
const debug = @import("debug.zig");
const module = @import("module.zig");
const scope = @import("scope.zig");
const function_def = @import("function_def.zig");

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

/// Mirrors `JSFunctionBytecode` (`quickjs.c:768`).
///
/// This is the final compiled bytecode structure produced by the
/// js_create_function equivalent. It contains the fully processed
/// bytecode after all pipeline phases (resolve_variables, resolve_labels,
/// compute_stack_size, etc.).
///
/// Unlike QuickJS's single contiguous allocation, this Zig version uses
/// separate allocations for each field, which is simpler and more idiomatic.
pub const FunctionBytecode = struct {
    memory: *memory.MemoryAccount,
    atoms: *atom.AtomTable,

    // Flags (mirrors JSFunctionBytecode packed fields)
    is_strict_mode: bool = false,
    has_prototype: bool = false,
    has_simple_parameter_list: bool = true,
    is_derived_class_constructor: bool = false,
    need_home_object: bool = false,
    func_kind: function_def.FunctionKind = .normal,
    new_target_allowed: bool = false,
    super_call_allowed: bool = false,
    super_allowed: bool = false,
    arguments_allowed: bool = false,
    backtrace_barrier: bool = false,

    // Bytecode
    byte_code: []u8 = &.{},

    // Metadata
    func_name: atom.Atom,
    arg_count: u16 = 0,
    var_count: u16 = 0,
    defined_arg_count: u16 = 0,
    stack_size: u16 = 0,
    var_ref_count: u16 = 0,

    // Variable definitions (args + vars)
    vardefs: []function_def.VarDef = &.{},

    // Closure variables
    closure_var: []function_def.ClosureVar = &.{},
    closure_var_count: u16 = 0,

    // Constant pool (contains child Function objects)
    cpool: []Value = &.{},
    cpool_count: i32 = 0,

    // Source location
    filename: atom.Atom,
    line_num: i32 = 0,
    col_num: i32 = 0,

    // pc2line data
    pc2line_buf: []u8 = &.{},
    pc2line_len: i32 = 0,

    // Source (optional)
    source: ?[]const u8 = null,
    source_len: i32 = 0,

    pub fn init(account: *memory.MemoryAccount, atoms: *atom.AtomTable, name: atom.Atom) FunctionBytecode {
        return .{
            .memory = account,
            .atoms = atoms,
            .func_name = atoms.dup(name),
            .filename = atoms.dup(name),
        };
    }

    pub fn deinit(self: *FunctionBytecode, rt: anytype) void {
        self.atoms.free(self.func_name);
        self.atoms.free(self.filename);

        if (self.byte_code.len != 0) self.memory.free(u8, self.byte_code);

        for (self.vardefs) |*v| self.atoms.free(v.var_name);
        if (self.vardefs.len != 0) self.memory.free(function_def.VarDef, self.vardefs);

        for (self.closure_var) |*cv| self.atoms.free(cv.var_name);
        if (self.closure_var.len != 0) self.memory.free(function_def.ClosureVar, self.closure_var);

        for (self.cpool) |v| v.free(rt);
        if (self.cpool.len != 0) self.memory.free(Value, self.cpool);

        if (self.pc2line_buf.len != 0) self.memory.free(u8, self.pc2line_buf);

        if (self.source) |src| {
            // Cast away const for freeing - the memory was allocated as mutable
            self.memory.free(u8, @constCast(src));
        }

        self.byte_code = &.{};
        self.vardefs = &.{};
        self.closure_var = &.{};
        self.cpool = &.{};
        self.pc2line_buf = &.{};
        self.source = null;
    }
};
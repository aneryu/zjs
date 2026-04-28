//! `FunctionDef` — mirrors `JSFunctionDef` (`quickjs.c:21420`).
//!
//! This is the Phase 1 compilation state used by the parser to
//! collect variable bindings, scopes, labels, and temporary bytecode.
//! After Phase 2/Phase 3 pipeline, it's lowered to `FunctionBytecode`
//! (`JSFunctionBytecode` at `quickjs.c:768`).

const std = @import("std");
const atom = @import("../core/atom.zig");
const memory = @import("../core/memory.zig");
const Value = @import("../core/value.zig").Value;
const pc2line = @import("./pipeline/pc2line.zig");

/// Mirrors `JSFunctionKindEnum` (`quickjs.c:761`).
pub const FunctionKind = enum(u2) {
    normal = 0,
    generator = 1 << 0,
    async = 1 << 1,
    async_generator = 3, // generator | async
};

/// Mirrors `JSParseFunctionEnum` (`quickjs.c:21401`).
pub const ParseFunctionKind = enum(u7) {
    statement,
    var_, // renamed from 'var' (reserved keyword in Zig)
    expr,
    arrow,
    getter,
    setter,
    method,
    class_static_init,
    class_constructor,
    derived_class_constructor,
};

/// Mirrors `JSClosureTypeEnum` (`quickjs.c:675`).
pub const ClosureType = enum(u3) {
    local, // 'var_idx' is the index of a local variable in the parent function
    arg, // 'var_idx' is the index of an argument variable in the parent function
    ref, // 'var_idx' is the index of a closure variable in the parent function
    global_ref, // 'var_idx' is the index of a closure variable referencing a global variable
    global_decl, // global variable declaration (eval code only)
    global, // global variable (eval code only)
    module_decl, // definition of a module variable (eval code only)
    module_import, // definition of a module import (eval code only)
};

/// Mirrors `JSVarKindEnum` (`quickjs.c:707`).
pub const VarKind = enum(u4) {
    normal,
    function_decl, // lexical var with function declaration
    new_function_decl, // lexical var with async/generator function declaration
    catch_,
    function_name, // function expression name
    private_field,
    private_method,
    private_getter,
    private_setter,
    private_getter_setter,
};

/// Mirrors `JSVarDef` (`quickjs.c:724`).
pub const VarDef = struct {
    var_name: atom.Atom,
    scope_level: i32, // index into scopes of this variable lexical scope
    is_lexical: bool = false,
    is_const: bool = false,
    is_captured: bool = false,
    var_kind: VarKind = .normal,
};

/// Mirrors `JSVarScope` (`quickjs.c:702`).
pub const VarScope = struct {
    parent: i32, // index into scopes of the enclosing scope
    first: i32, // index into vars of the last variable in this scope
};

/// Mirrors `JSClosureVar` (`quickjs.c:687`).
pub const ClosureVar = struct {
    closure_type: ClosureType,
    is_lexical: bool = false,
    is_const: bool = false,
    var_kind: VarKind = .normal,
    var_idx: u16, // index to a normal variable of the parent function, or index to a closure variable
    var_name: atom.Atom,
};

/// Mirrors `JSGlobalVar` (`quickjs.c:21364`).
pub const GlobalVar = struct {
    cpool_idx: i32, // index in the constant pool for hoisted function definition
    force_init: bool = false,
    is_lexical: bool = false, // global let/const definition
    is_const: bool = false, // const definition
    scope_level: i32, // scope of definition
    var_name: atom.Atom,
};

/// Mirrors `RelocEntry` (`quickjs.c:21374`).
pub const RelocEntry = struct {
    next: ?*RelocEntry = null,
    addr: i32,
    size: i32,
    label: i32,
};

/// Mirrors `LabelSlot` (`quickjs.c:21387`).
pub const LabelSlot = struct {
    ref_count: i32 = 0,
    pos: i32 = -1, // phase 1 address, -1 means not resolved yet
    pos2: i32 = -1, // phase 2 address, -1 means not resolved yet
    addr: i32 = -1, // phase 3 address, -1 means not resolved yet
    first_reloc: ?*RelocEntry = null,
};

/// Mirrors `JumpSlot` (`quickjs.c:21380`).
pub const JumpSlot = struct {
    op: i32,
    size: i32,
    pos: i32,
    label: i32,
};

/// Mirrors `JSFunctionDef` (`quickjs.c:21420`).
pub const FunctionDef = struct {
    memory: *memory.MemoryAccount,
    atoms: *atom.AtomTable,
    parent: ?*FunctionDef = null,
    parent_cpool_idx: i32 = -1,
    parent_scope_level: i32 = 0,

    // Flags — packed as in QuickJS
    is_eval: bool = false,
    is_global_var: bool = false,
    is_func_expr: bool = false,
    has_home_object: bool = false,
    has_prototype: bool = false,
    has_simple_parameter_list: bool = true,
    has_parameter_expressions: bool = false,
    has_use_strict: bool = false,
    has_eval_call: bool = false,
    has_arguments_binding: bool = false,
    has_this_binding: bool = false,
    new_target_allowed: bool = false,
    super_call_allowed: bool = false,
    super_allowed: bool = false,
    arguments_allowed: bool = false,
    is_derived_class_constructor: bool = false,
    in_function_body: bool = false,
    backtrace_barrier: bool = false,
    need_home_object: bool = false,
    use_short_opcodes: bool = false,
    has_await: bool = false,

    func_kind: FunctionKind = .normal,
    func_type: ParseFunctionKind = .statement,
    is_strict_mode: bool = false,
    func_name: atom.Atom,

    // Variables
    vars: []VarDef = &.{},
    vars_htab: []u32 = &.{},
    var_count: i32 = 0,
    args: []VarDef = &.{},
    arg_count: i32 = 0,
    defined_arg_count: i32 = 0,
    var_ref_count: i32 = 0,
    var_object_idx: i32 = -1,
    arg_var_object_idx: i32 = -1,
    arguments_var_idx: i32 = -1,
    arguments_arg_idx: i32 = -1,
    func_var_idx: i32 = -1,
    eval_ret_idx: i32 = -1,
    this_var_idx: i32 = -1,
    new_target_var_idx: i32 = -1,
    this_active_func_var_idx: i32 = -1,
    home_object_var_idx: i32 = -1,

    // Scopes
    scope_level: i32 = 0,
    scope_first: i32 = 0,
    scope_count: i32 = 0,
    scopes: []VarScope = &.{},

    // Global variables
    global_vars: []GlobalVar = &.{},
    global_var_count: i32 = 0,

    // Bytecode (Phase 1)
    byte_code: []u8 = &.{},
    last_opcode_pos: i32 = -1,

    // Labels
    label_slots: []LabelSlot = &.{},
    label_count: i32 = 0,

    // Constant pool
    cpool: []Value = &.{},
    cpool_count: i32 = 0,

    // Closure variables
    closure_var: []ClosureVar = &.{},
    closure_var_count: i32 = 0,

    // Jumps
    jump_slots: []JumpSlot = &.{},
    jump_count: i32 = 0,

    // Source location
    source_loc_slots: []pc2line.SourceLocSlot = &.{},
    source_loc_count: i32 = 0,
    line_number_last: i32 = 0,
    line_number_last_pc: i32 = 0,
    col_number_last: i32 = 0,

    // pc2line table
    filename: atom.Atom,
    line_num: i32 = 0,
    col_num: i32 = 0,

    // Child functions (nested functions)
    child_list: []FunctionDef = &.{},

    pub fn init(account: *memory.MemoryAccount, atoms: *atom.AtomTable, name: atom.Atom) FunctionDef {
        return .{
            .memory = account,
            .atoms = atoms,
            .func_name = atoms.dup(name),
            .filename = atoms.dup(name),
        };
    }

    pub fn deinit(self: *FunctionDef, rt: anytype) void {
        self.atoms.free(self.func_name);
        self.atoms.free(self.filename);

        for (self.vars) |*v| self.atoms.free(v.var_name);
        if (self.vars.len != 0) self.memory.free(VarDef, self.vars);
        if (self.vars_htab.len != 0) self.memory.free(u32, self.vars_htab);

        for (self.args) |*a| self.atoms.free(a.var_name);
        if (self.args.len != 0) self.memory.free(VarDef, self.args);

        if (self.scopes.len != 0) self.memory.free(VarScope, self.scopes);

        for (self.global_vars) |*g| self.atoms.free(g.var_name);
        if (self.global_vars.len != 0) self.memory.free(GlobalVar, self.global_vars);

        if (self.byte_code.len != 0) self.memory.free(u8, self.byte_code);

        // Free label reloc entries
        for (self.label_slots) |*ls| {
            var reloc = ls.first_reloc;
            while (reloc) |r| {
                const next = r.next;
                self.memory.free(RelocEntry, r[0..1]);
                reloc = next;
            }
        }
        if (self.label_slots.len != 0) self.memory.free(LabelSlot, self.label_slots);

        for (self.cpool) |v| v.free(rt);
        if (self.cpool.len != 0) self.memory.free(Value, self.cpool);

        for (self.closure_var) |*cv| self.atoms.free(cv.var_name);
        if (self.closure_var.len != 0) self.memory.free(ClosureVar, self.closure_var);

        if (self.jump_slots.len != 0) self.memory.free(JumpSlot, self.jump_slots);

        if (self.source_loc_slots.len != 0) self.memory.free(pc2line.SourceLocSlot, self.source_loc_slots);

        for (self.child_list) |*child| child.deinit(rt);
        if (self.child_list.len != 0) self.memory.free(FunctionDef, self.child_list);

        self.vars = &.{};
        self.vars_htab = &.{};
        self.args = &.{};
        self.scopes = &.{};
        self.global_vars = &.{};
        self.byte_code = &.{};
        self.label_slots = &.{};
        self.cpool = &.{};
        self.closure_var = &.{};
        self.jump_slots = &.{};
        self.source_loc_slots = &.{};
        self.child_list = &.{};
    }
};
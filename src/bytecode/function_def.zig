//! `FunctionDef` — mirrors `JSFunctionDef` (`quickjs.c:21420`).
//!
//! This is the Phase 1 compilation state used by the parser to
//! collect variable bindings, scopes, labels, and temporary bytecode.
//! After Phase 2/Phase 3 pipeline, it's lowered to `FunctionBytecode`
//! (`JSFunctionBytecode` at `quickjs.c:768`).

const std = @import("std");
const atom = @import("../core/atom.zig");
const function_bytecode = @import("../core/function_bytecode.zig");
const memory = @import("../core/memory.zig");
const JSValue = @import("../core/value.zig").JSValue;
const pc2line = @import("./pipeline/pc2line.zig");

fn dupOwnedValue(atoms: *atom.AtomTable, value: JSValue) JSValue {
    if (value.asSymbolAtom()) |atom_id| return JSValue.symbol(atoms.dup(atom_id));
    return value.dup();
}

fn takeOwnedValue(atoms: *atom.AtomTable, value: JSValue) JSValue {
    if (value.asSymbolAtom()) |atom_id| return JSValue.symbol(atoms.dup(atom_id));
    return value;
}

fn freeOwnedValue(atoms: *atom.AtomTable, value: JSValue, rt: anytype) void {
    if (value.asSymbolAtom()) |atom_id| {
        atoms.free(atom_id);
        return;
    }
    value.free(rt);
}

pub const FunctionKind = function_bytecode.FunctionKind;

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

pub const ClosureType = function_bytecode.ClosureType;
pub const VarKind = function_bytecode.VarKind;
pub const VarDef = function_bytecode.VarDef;

pub const DirectCallKind = enum(u8) {
    prop_atom,
};

pub const DirectCallSite = struct {
    kind: DirectCallKind = .prop_atom,
    prepare_pc: u32,
    call_pc: u32,
    atom_id: atom.Atom,
    argc: u16,
};

/// Mirrors `JSVarScope` (`quickjs.c:702`).
pub const VarScope = struct {
    parent: i32, // index into scopes of the enclosing scope
    first: i32, // index into vars of the last variable in this scope
};

pub const ClosureVar = function_bytecode.ClosureVar;

/// Mirrors `JSGlobalVar` (`quickjs.c:21364`).
pub const GlobalVar = struct {
    cpool_idx: i32, // index in the constant pool for hoisted function definition
    force_init: bool = false,
    is_configurable: bool = false,
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

/// Generic geometric growth helper for FunctionDef hot buffers.
///
/// Maintains the contract that `slice.*.len` is the *used* count while the
/// allocator-owned backing buffer is `slice.*.ptr[0..capacity.*]`. Returns a
/// writable view of the freshly grown tail (length `n`).
///
/// Each append used to do `alloc(old + n) + memcpy + free(old)`, making
/// repeated appends O(n²). Geometric growth (capacity doubling, with an
/// 8-element floor) reduces total cost to amortised O(1) per item.
fn growSliceBy(
    comptime T: type,
    mem: *memory.MemoryAccount,
    slice: *[]T,
    capacity: *usize,
    n: usize,
) ![]T {
    const used = slice.len;
    const new_used = used + n;
    if (new_used <= capacity.*) {
        slice.* = slice.ptr[0..new_used];
        return slice.ptr[used..new_used];
    }
    var new_cap: usize = if (capacity.* == 0) 8 else capacity.* * 2;
    if (new_cap < new_used) new_cap = new_used;
    const new_buf = try mem.alloc(T, new_cap);
    @memcpy(new_buf[0..used], slice.*);
    var old_buf: []T = &.{};
    if (capacity.* != 0) old_buf = slice.ptr[0..capacity.*];
    slice.* = new_buf[0..new_used];
    capacity.* = new_cap;
    if (old_buf.len != 0) mem.free(T, old_buf);
    return slice.ptr[used..new_used];
}

/// Free the full backing buffer of a growable slice and reset both the
/// visible slice and its capacity.
fn freeGrowableSlice(
    comptime T: type,
    mem: *memory.MemoryAccount,
    slice: *[]T,
    capacity: *usize,
) void {
    var old_buf: []T = &.{};
    if (capacity.* != 0) old_buf = slice.ptr[0..capacity.*];
    slice.* = &.{};
    capacity.* = 0;
    if (old_buf.len != 0) mem.free(T, old_buf);
}

fn freeGrowableAtomSlice(
    atoms: *atom.AtomTable,
    mem: *memory.MemoryAccount,
    slice: *[]atom.Atom,
    capacity: *usize,
) void {
    const items = slice.*;
    const old_capacity = capacity.*;
    slice.* = &.{};
    capacity.* = 0;
    for (items) |atom_id| atoms.free(atom_id);
    if (old_capacity != 0) {
        mem.free(atom.Atom, items.ptr[0..old_capacity]);
    } else if (items.len != 0) {
        mem.free(atom.Atom, items);
    }
}

fn freeGrowableDirectCallSites(
    atoms: *atom.AtomTable,
    mem: *memory.MemoryAccount,
    slice: *[]DirectCallSite,
    capacity: *usize,
) void {
    const items = slice.*;
    const old_capacity = capacity.*;
    slice.* = &.{};
    capacity.* = 0;
    for (items) |site| atoms.free(site.atom_id);
    if (old_capacity != 0) {
        mem.free(DirectCallSite, items.ptr[0..old_capacity]);
    } else if (items.len != 0) {
        mem.free(DirectCallSite, items);
    }
}

fn freeGrowableNamedSlice(
    comptime T: type,
    atoms: *atom.AtomTable,
    mem: *memory.MemoryAccount,
    slice: *[]T,
    capacity: *usize,
) void {
    const items = slice.*;
    const old_capacity = capacity.*;
    slice.* = &.{};
    capacity.* = 0;
    for (items) |*item| atoms.free(item.var_name);
    if (old_capacity != 0) {
        mem.free(T, items.ptr[0..old_capacity]);
    } else if (items.len != 0) {
        mem.free(T, items);
    }
}

/// Mirrors `JSFunctionDef` (`quickjs.c:21420`).
pub const FunctionDef = struct {
    memory: *memory.MemoryAccount,
    atoms: *atom.AtomTable,
    parent: ?*FunctionDef = null,
    discard_next: ?*FunctionDef = null,
    parent_cpool_idx: i32 = -1,
    parent_scope_level: i32 = 0,

    // Flags — packed as in QuickJS
    is_eval: bool = false,
    is_global_var: bool = false,
    persist_global_lexical: bool = false,
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
    is_indirect_eval: bool = false,

    func_kind: FunctionKind = .normal,
    func_type: ParseFunctionKind = .statement,
    is_strict_mode: bool = false,
    func_name: atom.Atom,

    // Variables
    vars: []VarDef = &.{},
    vars_capacity: usize = 0,
    vars_htab: []u32 = &.{},
    var_count: i32 = 0,
    args: []VarDef = &.{},
    args_capacity: usize = 0,
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
    scopes_capacity: usize = 0,

    // Global variables
    global_vars: []GlobalVar = &.{},
    global_vars_capacity: usize = 0,
    global_var_count: i32 = 0,

    // Bytecode (Phase 1)
    byte_code: []u8 = &.{},
    byte_code_capacity: usize = 0,
    atom_operands: []atom.Atom = &.{},
    atom_operands_capacity: usize = 0,
    direct_call_sites: []DirectCallSite = &.{},
    direct_call_sites_capacity: usize = 0,
    last_opcode_pos: i32 = -1,

    // Labels
    label_slots: []LabelSlot = &.{},
    label_count: i32 = 0,

    // Constant pool
    cpool: []JSValue = &.{},
    cpool_capacity: usize = 0,
    cpool_count: i32 = 0,

    // Closure variables
    closure_var: []ClosureVar = &.{},
    closure_var_capacity: usize = 0,
    closure_var_count: i32 = 0,

    // Public instance fields without initializers. Kept for older parser paths;
    // the QuickJS-style class field initializer function is tracked separately.
    class_instance_fields: []atom.Atom = &.{},
    class_instance_fields_capacity: usize = 0,
    private_bound_names: []atom.Atom = &.{},
    private_bound_names_capacity: usize = 0,
    class_private_names: []atom.Atom = &.{},
    class_private_names_capacity: usize = 0,
    class_fields_init_cpool_idx: i32 = -1,

    // Jumps
    jump_slots: []JumpSlot = &.{},
    jump_count: i32 = 0,

    // Source location
    source_loc_slots: []pc2line.SourceLocSlot = &.{},
    source_loc_capacity: usize = 0,
    source_loc_count: i32 = 0,
    line_number_last: i32 = 0,
    line_number_last_pc: i32 = 0,
    col_number_last: i32 = 0,

    // pc2line table
    filename: atom.Atom,
    line_num: i32 = 0,
    col_num: i32 = 0,
    source_text: ?[]const u8 = null,

    // Child functions (nested functions)
    child_list: []FunctionDef = &.{},
    child_list_capacity: usize = 0,
    emit_top_level_closure_init: bool = false,
    top_level_closure_var_idx: i32 = -1,
    child_decl_init_keep_value: bool = false,
    child_decl_var_idx: i32 = -1,
    child_decl_annex_b_var_idx: i32 = -1,
    child_decl_emit_inline: bool = false,
    child_decl_emit_var_inline: bool = false,
    child_decl_skip_init: bool = false,
    child_decl_force_local_init: bool = false,
    child_decl_emit_global_inline: bool = false,

    pub fn init(account: *memory.MemoryAccount, atoms: *atom.AtomTable, name: atom.Atom) FunctionDef {
        return .{
            .memory = account,
            .atoms = atoms,
            .func_name = atoms.dup(name),
            .filename = atoms.dup(name),
        };
    }

    pub fn deinitInitFailure(self: *FunctionDef) void {
        const func_name = self.func_name;
        const filename = self.filename;
        self.func_name = atom.null_atom;
        self.filename = atom.null_atom;
        self.atoms.free(func_name);
        self.atoms.free(filename);
        freeGrowableSlice(VarScope, self.memory, &self.scopes, &self.scopes_capacity);
        self.scope_count = 0;
    }

    /// Append a `VarScope` to `scopes`. Mirrors `push_scope`
    /// (`quickjs.c:23486`): the new scope records its parent index
    /// and inherits an empty `first` (no vars yet). Returns the index
    /// of the newly added scope (== new `scope_level`).
    pub fn appendScope(self: *FunctionDef, parent: i32) !i32 {
        const tail = try growSliceBy(VarScope, self.memory, &self.scopes, &self.scopes_capacity, 1);
        tail[0] = .{ .parent = parent, .first = -1 };
        self.scope_count += 1;
        const idx: i32 = @intCast(self.scopes.len - 1);
        return idx;
    }

    /// Append a `VarDef` to `vars`. Mirrors `add_var`
    /// (`quickjs.c:23554`). The caller is responsible for setting
    /// `scope_level`, `var_kind`, `is_lexical`, `is_const`. The atom
    /// is duplicated; the caller keeps ownership of its copy.
    /// Returns the index of the new var.
    pub fn appendVar(self: *FunctionDef, var_def: VarDef) !i32 {
        const tail = try growSliceBy(VarDef, self.memory, &self.vars, &self.vars_capacity, 1);
        tail[0] = var_def;
        tail[0].var_name = self.atoms.dup(var_def.var_name);
        self.var_count += 1;
        const idx: i32 = @intCast(self.vars.len - 1);
        return idx;
    }

    pub fn appendGlobalVar(self: *FunctionDef, global_var: GlobalVar) !void {
        const tail = try growSliceBy(GlobalVar, self.memory, &self.global_vars, &self.global_vars_capacity, 1);
        tail[0] = global_var;
        tail[0].var_name = self.atoms.dup(global_var.var_name);
        self.global_var_count = @intCast(self.global_vars.len);
    }

    /// Append a formal argument definition. Mirrors the `args` side of
    /// QuickJS function metadata; parser lowering resolves matching
    /// identifier references to `get_arg*` opcodes.
    pub fn appendArg(self: *FunctionDef, var_def: VarDef) !i32 {
        const tail = try growSliceBy(VarDef, self.memory, &self.args, &self.args_capacity, 1);
        tail[0] = var_def;
        tail[0].var_name = self.atoms.dup(var_def.var_name);
        self.arg_count = @intCast(self.args.len);
        self.defined_arg_count = @intCast(self.args.len);
        return @intCast(self.args.len - 1);
    }

    /// Append a child FunctionDef to `child_list`. Mirrors
    /// `list_add_tail(&fd->link, &parent->child_list)` in
    /// `js_new_function_def` (`quickjs.c:31487`). The child is
    /// moved into the parent's child_list; the caller should not
    /// access the child directly after this call.
    pub fn addChild(self: *FunctionDef, child: FunctionDef) !void {
        const tail = try growSliceBy(FunctionDef, self.memory, &self.child_list, &self.child_list_capacity, 1);
        tail[0] = child;
        tail[0].discard_next = null;
        self.refreshChildParentPointers();
    }

    fn refreshChildParentPointers(self: *FunctionDef) void {
        for (self.child_list) |*child| {
            child.parent = self;
            child.refreshChildParentPointers();
        }
    }

    /// Mirror `add_scope_var` (`quickjs.c:23577`): add a var and
    /// attach it to `scope_level`'s scope (updates `scope_first`).
    pub fn addScopeVar(
        self: *FunctionDef,
        name: atom.Atom,
        var_kind: VarKind,
        scope_level: i32,
        is_lexical: bool,
        is_const: bool,
    ) !i32 {
        const prev_first: i32 = if (scope_level >= 0 and @as(usize, @intCast(scope_level)) < self.scopes.len)
            self.scopes[@intCast(scope_level)].first
        else
            -1;
        const idx = try self.appendVar(.{
            .var_name = name,
            .scope_level = scope_level,
            .scope_next = prev_first,
            .is_lexical = is_lexical,
            .is_const = is_const,
            .var_kind = var_kind,
        });
        if (scope_level >= 0 and @as(usize, @intCast(scope_level)) < self.scopes.len) {
            self.scopes[@intCast(scope_level)].first = idx;
            self.scope_first = idx;
        }
        return idx;
    }

    /// Append a closure variable entry. Used for top-level module/eval
    /// bindings and, later, captured parent-scope variables.
    pub fn addClosureVar(self: *FunctionDef, closure_var: ClosureVar) !i32 {
        const tail = try growSliceBy(ClosureVar, self.memory, &self.closure_var, &self.closure_var_capacity, 1);
        tail[0] = closure_var;
        tail[0].var_name = self.atoms.dup(closure_var.var_name);
        self.closure_var_count = @intCast(self.closure_var.len);
        return @intCast(self.closure_var.len - 1);
    }

    pub fn appendClassInstanceField(self: *FunctionDef, atom_id: atom.Atom) !void {
        const tail = try growSliceBy(atom.Atom, self.memory, &self.class_instance_fields, &self.class_instance_fields_capacity, 1);
        tail[0] = self.atoms.dup(atom_id);
    }

    pub fn appendPrivateBoundName(self: *FunctionDef, atom_id: atom.Atom) !void {
        for (self.private_bound_names) |existing| {
            if (existing == atom_id) return;
        }
        const tail = try growSliceBy(atom.Atom, self.memory, &self.private_bound_names, &self.private_bound_names_capacity, 1);
        tail[0] = self.atoms.dup(atom_id);
    }

    pub fn appendClassPrivateName(self: *FunctionDef, atom_id: atom.Atom) !void {
        for (self.class_private_names) |existing| {
            if (existing == atom_id) return;
        }
        const tail = try growSliceBy(atom.Atom, self.memory, &self.class_private_names, &self.class_private_names_capacity, 1);
        tail[0] = self.atoms.dup(atom_id);
    }

    /// Find a var by name, searching newest-first. Returns the var
    /// index or `-1` if not found. Mirrors the htab-free path of
    /// `find_var` (`quickjs.c:23378`).
    pub fn findVar(self: *const FunctionDef, name: atom.Atom) i32 {
        var i: usize = self.vars.len;
        while (i > 0) {
            i -= 1;
            if (self.vars[i].var_name == name) return @intCast(i);
        }
        return -1;
    }

    pub fn findArg(self: *const FunctionDef, name: atom.Atom) i32 {
        var i: usize = self.args.len;
        while (i > 0) {
            i -= 1;
            if (self.args[i].var_name == name) return @intCast(i);
        }
        return -1;
    }

    /// Append bytes to the byte_code buffer. Used for nested function
    /// bytecode emission during parsing.
    pub fn appendByteCode(self: *FunctionDef, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        const tail = try growSliceBy(u8, self.memory, &self.byte_code, &self.byte_code_capacity, bytes.len);
        @memcpy(tail, bytes);
    }

    pub fn appendSourceLoc(self: *FunctionDef, pc: u32, line_num: i32, col_num: i32) !void {
        if (line_num <= 0 or col_num <= 0) return;
        const tail = try growSliceBy(pc2line.SourceLocSlot, self.memory, &self.source_loc_slots, &self.source_loc_capacity, 1);
        tail[0] = .{ .pc = pc, .line_num = line_num, .col_num = col_num };
        self.source_loc_count = @intCast(self.source_loc_slots.len);
    }

    pub fn appendAtomOperand(self: *FunctionDef, atom_id: atom.Atom) !void {
        const tail = try growSliceBy(atom.Atom, self.memory, &self.atom_operands, &self.atom_operands_capacity, 1);
        tail[0] = self.atoms.dup(atom_id);
    }

    pub fn appendDirectCallSite(self: *FunctionDef, site: DirectCallSite) !void {
        const tail = try growSliceBy(DirectCallSite, self.memory, &self.direct_call_sites, &self.direct_call_sites_capacity, 1);
        tail[0] = site;
        tail[0].atom_id = self.atoms.dup(site.atom_id);
    }

    pub fn appendCpool(self: *FunctionDef, value: JSValue) !u32 {
        const tail = try growSliceBy(JSValue, self.memory, &self.cpool, &self.cpool_capacity, 1);
        tail[0] = dupOwnedValue(self.atoms, value);
        self.cpool_count = @intCast(self.cpool.len);
        return @intCast(self.cpool.len - 1);
    }

    pub fn appendCpoolOwned(self: *FunctionDef, value: JSValue) !u32 {
        const tail = try growSliceBy(JSValue, self.memory, &self.cpool, &self.cpool_capacity, 1);
        tail[0] = takeOwnedValue(self.atoms, value);
        self.cpool_count = @intCast(self.cpool.len);
        return @intCast(self.cpool.len - 1);
    }

    /// Truncate `byte_code` to `target_len` bytes, leaving capacity intact so
    /// re-emission after speculative rollback does not require reallocation.
    pub fn truncateByteCode(self: *FunctionDef, target_len: usize) void {
        std.debug.assert(target_len <= self.byte_code.len);
        self.byte_code = self.byte_code.ptr[0..target_len];
    }

    /// Truncate `atom_operands` to `target_len` entries, releasing the
    /// per-element atom refcounts but keeping the backing buffer.
    pub fn truncateAtomOperands(self: *FunctionDef, target_len: usize) void {
        std.debug.assert(target_len <= self.atom_operands.len);
        var i: usize = target_len;
        while (i < self.atom_operands.len) : (i += 1) {
            self.atoms.free(self.atom_operands[i]);
        }
        self.atom_operands = self.atom_operands.ptr[0..target_len];
    }

    pub fn deinit(self: *FunctionDef, rt: anytype) void {
        const func_name = self.func_name;
        const filename = self.filename;
        self.func_name = atom.null_atom;
        self.filename = atom.null_atom;
        self.atoms.free(func_name);
        self.atoms.free(filename);

        freeGrowableNamedSlice(VarDef, self.atoms, self.memory, &self.vars, &self.vars_capacity);
        if (self.vars_htab.len != 0) self.memory.free(u32, self.vars_htab);

        freeGrowableNamedSlice(VarDef, self.atoms, self.memory, &self.args, &self.args_capacity);

        freeGrowableSlice(VarScope, self.memory, &self.scopes, &self.scopes_capacity);

        freeGrowableNamedSlice(GlobalVar, self.atoms, self.memory, &self.global_vars, &self.global_vars_capacity);

        freeGrowableSlice(u8, self.memory, &self.byte_code, &self.byte_code_capacity);
        freeGrowableAtomSlice(self.atoms, self.memory, &self.atom_operands, &self.atom_operands_capacity);
        freeGrowableDirectCallSites(self.atoms, self.memory, &self.direct_call_sites, &self.direct_call_sites_capacity);

        const old_label_slots = self.label_slots;
        self.label_slots = &.{};
        // Free label reloc entries
        for (old_label_slots) |*ls| {
            var reloc = ls.first_reloc;
            ls.first_reloc = null;
            while (reloc) |r| {
                const next = r.next;
                self.memory.free(RelocEntry, r[0..1]);
                reloc = next;
            }
        }
        if (old_label_slots.len != 0) self.memory.free(LabelSlot, old_label_slots);

        const old_cpool = self.cpool;
        const old_cpool_capacity = self.cpool_capacity;
        self.cpool = &.{};
        self.cpool_capacity = 0;
        self.cpool_count = 0;
        for (old_cpool) |*slot| {
            const value = slot.*;
            slot.* = JSValue.undefinedValue();
            freeOwnedValue(self.atoms, value, rt);
        }
        if (old_cpool_capacity != 0) self.memory.free(JSValue, old_cpool.ptr[0..old_cpool_capacity]);

        freeGrowableNamedSlice(ClosureVar, self.atoms, self.memory, &self.closure_var, &self.closure_var_capacity);

        freeGrowableAtomSlice(self.atoms, self.memory, &self.class_instance_fields, &self.class_instance_fields_capacity);
        freeGrowableAtomSlice(self.atoms, self.memory, &self.private_bound_names, &self.private_bound_names_capacity);
        freeGrowableAtomSlice(self.atoms, self.memory, &self.class_private_names, &self.class_private_names_capacity);

        if (self.jump_slots.len != 0) self.memory.free(JumpSlot, self.jump_slots);

        freeGrowableSlice(pc2line.SourceLocSlot, self.memory, &self.source_loc_slots, &self.source_loc_capacity);
        if (self.source_text) |source| self.memory.free(u8, @constCast(source));

        const old_child_list = self.child_list;
        const old_child_list_capacity = self.child_list_capacity;
        self.child_list = &.{};
        self.child_list_capacity = 0;
        for (old_child_list) |*child| child.deinit(rt);

        self.vars_htab = &.{};
        self.discard_next = null;
        self.class_fields_init_cpool_idx = -1;
        self.jump_slots = &.{};
        self.source_text = null;
        self.emit_top_level_closure_init = false;
        self.top_level_closure_var_idx = -1;
        self.child_decl_init_keep_value = false;
        self.child_decl_var_idx = -1;
        self.child_decl_annex_b_var_idx = -1;
        self.child_decl_emit_inline = false;
        self.child_decl_emit_var_inline = false;
        self.child_decl_skip_init = false;
        self.child_decl_force_local_init = false;
        self.child_decl_emit_global_inline = false;
        if (old_child_list_capacity != 0) self.memory.free(FunctionDef, old_child_list.ptr[0..old_child_list_capacity]);
    }
};

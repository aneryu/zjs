const std = @import("std");

const atom = @import("atom.zig");
const gc = @import("gc.zig");
const ic = @import("ic.zig");
const memory = @import("memory.zig");
const runtime = @import("runtime.zig");
const shape = @import("shape.zig");
const JSValue = @import("value.zig").JSValue;

/// Mirrors `JSFunctionKindEnum` (`quickjs.c:761`).
pub const FunctionKind = enum(u2) {
    normal = 0,
    generator = 1 << 0,
    async = 1 << 1,
    async_generator = 3, // generator | async
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
    scope_next: i32 = -1, // index into vars of the next variable in the same or enclosing lexical scope
    is_lexical: bool = false,
    is_const: bool = false,
    is_captured: bool = false,
    tdz_emitted_at_decl: bool = false,
    var_kind: VarKind = .normal,
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

/// Mirrors `JSGlobalVar` (`quickjs.c:713`).
pub const GlobalVar = struct {
    cpool_idx: i32,
    force_init: bool = false,
    is_configurable: bool = false,
    is_lexical: bool = false,
    is_const: bool = false,
    scope_level: i32,
    var_name: atom.Atom,
};

pub const CallSiteKind = enum(u8) {
    prop_atom,
};

pub const CallSite = struct {
    kind: CallSiteKind = .prop_atom,
    atom_id: atom.Atom,
    prepare_pc: u32,
    call_pc: u32,
    ic_slot_index: usize = std.math.maxInt(usize),
};

/// Mirrors `JSFunctionBytecode` (`quickjs.c:768-804`).
///
/// This is the final compiled bytecode structure produced by the
/// js_create_function equivalent. It contains the fully processed bytecode
/// after all bytecode pipeline phases. Core owns this GC object so runtime,
/// object graph cleanup, and tracing can operate without depending on the
/// bytecode compile-time module.
///
/// Field order matches QuickJS exactly for strong alignment (§1.5.3).
///
/// Storage layout: the finalize pipeline packs every read-only artifact
/// slice (byte_code, cpool, atom tables, vardefs, pc2line, source, ...)
/// into a single `block` allocation; the slice fields then point inside
/// that block (see `BlockBuilder`). Fixtures that populate the fields with
/// individual allocations leave `block` empty, and `deinit` falls back to
/// the legacy per-slice frees. The IC tables (`ic_slots` / `ic_site_ids` /
/// `ic_sites`) always stay independent allocations because they are
/// runtime-mutable and independently released via `deinitIcSlots`.
pub const FunctionBytecode = struct {
    header: gc.GCObjectHeader,
    memory: *memory.MemoryAccount,
    atoms: *atom.AtomTable,

    /// Consolidated storage for the read-only slices below. Empty when the
    /// fields were populated with individual allocations (fixture path).
    block: []u8 = &.{},

    // Flags (mirrors JSFunctionBytecode packed fields, same order as quickjs.c:770-782)
    is_strict_mode: bool = false,
    runtime_strict_mode: bool = false,
    has_prototype: bool = false,
    has_simple_parameter_list: bool = true,
    is_class_constructor: bool = false,
    is_derived_class_constructor: bool = false,
    need_home_object: bool = false,
    func_kind: FunctionKind = .normal,
    is_arrow_function: bool = false,
    new_target_allowed: bool = false,
    super_call_allowed: bool = false,
    super_allowed: bool = false,
    arguments_allowed: bool = false,
    backtrace_barrier: bool = false,
    is_indirect_eval: bool = false,
    has_eval_call: bool = false,

    // Bytecode (quickjs.c:783-784)
    byte_code: []u8 = &.{},
    byte_code_len: i32 = 0,
    generator_body_pc: usize = 0,
    atom_operands: []atom.Atom = &.{},
    arg_names: []atom.Atom = &.{},
    var_names: []atom.Atom = &.{},
    var_is_lexical: []bool = &.{},
    var_is_const: []bool = &.{},
    // Lexical scope level per local slot (parallels var_is_lexical). Distinguishes
    // a top-level (scope_level == 0) lexical from a block-level shadower.
    var_scope_level: []i32 = &.{},
    var_ref_names: []atom.Atom = &.{},
    var_ref_is_lexical: []bool = &.{},
    var_ref_is_const: []bool = &.{},
    var_ref_is_global_decl: []bool = &.{},
    global_var_names: []atom.Atom = &.{},
    global_vars: []GlobalVar = &.{},

    // Metadata (quickjs.c:785-792)
    func_name: atom.Atom,
    vardefs: []VarDef = &.{},
    closure_var: []ClosureVar = &.{},
    class_instance_fields: []atom.Atom = &.{},
    private_bound_names: []atom.Atom = &.{},
    class_private_names: []atom.Atom = &.{},
    class_fields_init: ?JSValue = null,
    arg_count: u16 = 0,
    var_count: u16 = 0,
    defined_arg_count: u16 = 0,
    stack_size: u16 = 0,
    var_ref_count: u16 = 0,
    closure_var_count: u16 = 0,
    cpool_count: i32 = 0,
    ic_slots: []ic.Slot = &.{},
    ic_site_ids: []usize = &.{},
    ic_sites: []ic.Site = &.{},
    call_sites: []CallSite = &.{},

    /// Cached execution view used by the VM call machinery. QuickJS keeps a
    /// direct `JSFunctionBytecode *` on function objects and dispatches from
    /// that pointer; zjs still exposes the older `bytecode.Bytecode` execution
    /// API, so finalized bytecode stores one borrowed view and the VM passes a
    /// pointer to it instead of rebuilding the view per call.
    execution_view: ?*anyopaque = null,
    execution_view_owned: bool = false,
    execution_view_heap_size: usize = 0,
    execution_view_destroy: ?*const fn (*memory.MemoryAccount, *anyopaque) void = null,

    // Note: QuickJS has 'realm' field (JSContext *) here; Zig version
    // tracks this differently via the runtime context.

    // Constant pool (contains child Function objects) (quickjs.c:796)
    cpool: []JSValue = &.{},

    // Source location (quickjs.c:797-803)
    filename: atom.Atom,
    line_num: i32 = 0,
    col_num: i32 = 0,
    source_len: i32 = 0,
    pc2line_len: i32 = 0,
    pc2line_buf: []u8 = &.{},
    source: ?[]const u8 = null,

    pub fn init(account: *memory.MemoryAccount, atoms: *atom.AtomTable, name: atom.Atom) FunctionBytecode {
        return .{
            .header = .{
                .kind = .function_bytecode,
            },
            .memory = account,
            .atoms = atoms,
            .func_name = atoms.dup(name),
            .filename = atoms.dup(name),
        };
    }

    pub fn deinit(self: *FunctionBytecode, rt: anytype) void {
        // When `block` owns the storage the per-slice frees are skipped;
        // only the per-element atom/value references are released and the
        // block is freed once at the end.
        const owned = self.block.len == 0;

        const execution_view = self.execution_view;
        const execution_view_owned = self.execution_view_owned;
        const execution_view_destroy = self.execution_view_destroy;
        self.execution_view = null;
        self.execution_view_owned = false;
        self.execution_view_heap_size = 0;
        self.execution_view_destroy = null;
        if (execution_view_owned) {
            if (execution_view_destroy) |destroy| {
                if (execution_view) |ptr| destroy(self.memory, ptr);
            }
        }

        const func_name = self.func_name;
        const filename = self.filename;
        self.func_name = atom.null_atom;
        self.filename = atom.null_atom;
        self.atoms.free(func_name);
        self.atoms.free(filename);

        const byte_code = self.byte_code;
        self.byte_code = &.{};
        self.byte_code_len = 0;
        if (owned and byte_code.len != 0) self.memory.free(u8, byte_code);
        releaseAtomSlice(self.atoms, self.memory, &self.atom_operands, owned);
        releaseAtomSlice(self.atoms, self.memory, &self.arg_names, owned);
        releaseAtomSlice(self.atoms, self.memory, &self.var_names, owned);
        releaseSlice(bool, self.memory, &self.var_is_lexical, owned);
        releaseSlice(bool, self.memory, &self.var_is_const, owned);
        releaseSlice(i32, self.memory, &self.var_scope_level, owned);
        releaseAtomSlice(self.atoms, self.memory, &self.var_ref_names, owned);
        releaseSlice(bool, self.memory, &self.var_ref_is_lexical, owned);
        releaseSlice(bool, self.memory, &self.var_ref_is_const, owned);
        releaseSlice(bool, self.memory, &self.var_ref_is_global_decl, owned);
        releaseAtomSlice(self.atoms, self.memory, &self.global_var_names, owned);

        const global_vars = self.global_vars;
        self.global_vars = &.{};
        for (global_vars) |*gv| self.atoms.free(gv.var_name);
        if (owned and global_vars.len != 0) self.memory.free(GlobalVar, global_vars);

        const vardefs = self.vardefs;
        self.vardefs = &.{};
        for (vardefs) |*v| self.atoms.free(v.var_name);
        if (owned and vardefs.len != 0) self.memory.free(VarDef, vardefs);

        const closure_var = self.closure_var;
        self.closure_var = &.{};
        for (closure_var) |*cv| self.atoms.free(cv.var_name);
        if (owned and closure_var.len != 0) self.memory.free(ClosureVar, closure_var);

        releaseAtomSlice(self.atoms, self.memory, &self.class_instance_fields, owned);
        releaseAtomSlice(self.atoms, self.memory, &self.private_bound_names, owned);
        releaseAtomSlice(self.atoms, self.memory, &self.class_private_names, owned);
        const class_fields_init = self.class_fields_init;
        self.class_fields_init = null;
        if (class_fields_init) |stored| stored.free(rt);

        const cpool = self.cpool;
        self.cpool = &.{};
        for (cpool) |*slot| {
            const value = slot.*;
            slot.* = JSValue.undefinedValue();
            value.free(rt);
        }
        if (owned and cpool.len != 0) self.memory.free(JSValue, cpool);

        const pc2line_buf = self.pc2line_buf;
        self.pc2line_buf = &.{};
        self.pc2line_len = 0;
        if (owned and pc2line_buf.len != 0) self.memory.free(u8, pc2line_buf);

        releaseCallSites(self.atoms, self.memory, &self.call_sites, owned);
        if (self.source) |src| {
            self.source = null;
            if (owned) self.memory.free(u8, @constCast(src));
        }
        self.source_len = 0;
        self.deinitIcSlots(&rt.shapes);

        self.class_fields_init = null;
        self.cpool = &.{};

        const block = self.block;
        self.block = &.{};
        if (block.len != 0) self.memory.freeAlignedBytes(block, block_alignment);
    }

    pub fn heapByteSize(self: *const FunctionBytecode) usize {
        var bytes: usize = @sizeOf(FunctionBytecode);
        bytes = addSliceBytes(bytes, ic.Slot, self.ic_slots.len);
        bytes = addSliceBytes(bytes, usize, self.ic_site_ids.len);
        bytes = addSliceBytes(bytes, ic.Site, self.ic_sites.len);
        bytes = addSaturating(bytes, self.execution_view_heap_size);
        if (self.block.len != 0) return addSaturating(bytes, self.block.len);
        bytes = addSliceBytes(bytes, u8, self.byte_code.len);
        bytes = addSliceBytes(bytes, atom.Atom, self.atom_operands.len);
        bytes = addSliceBytes(bytes, atom.Atom, self.arg_names.len);
        bytes = addSliceBytes(bytes, atom.Atom, self.var_names.len);
        bytes = addSliceBytes(bytes, bool, self.var_is_lexical.len);
        bytes = addSliceBytes(bytes, bool, self.var_is_const.len);
        bytes = addSliceBytes(bytes, i32, self.var_scope_level.len);
        bytes = addSliceBytes(bytes, atom.Atom, self.var_ref_names.len);
        bytes = addSliceBytes(bytes, bool, self.var_ref_is_lexical.len);
        bytes = addSliceBytes(bytes, bool, self.var_ref_is_const.len);
        bytes = addSliceBytes(bytes, bool, self.var_ref_is_global_decl.len);
        bytes = addSliceBytes(bytes, atom.Atom, self.global_var_names.len);
        bytes = addSliceBytes(bytes, GlobalVar, self.global_vars.len);
        bytes = addSliceBytes(bytes, VarDef, self.vardefs.len);
        bytes = addSliceBytes(bytes, ClosureVar, self.closure_var.len);
        bytes = addSliceBytes(bytes, atom.Atom, self.class_instance_fields.len);
        bytes = addSliceBytes(bytes, atom.Atom, self.private_bound_names.len);
        bytes = addSliceBytes(bytes, atom.Atom, self.class_private_names.len);
        bytes = addSliceBytes(bytes, JSValue, self.cpool.len);
        bytes = addSliceBytes(bytes, u8, self.pc2line_buf.len);
        bytes = addSliceBytes(bytes, CallSite, self.call_sites.len);
        if (self.source) |source| bytes = addSaturating(bytes, source.len);
        return bytes;
    }

    pub fn deinitIcSlots(self: *FunctionBytecode, registry: ?*shape.Registry) void {
        const ic_slots = self.ic_slots;
        self.ic_slots = &.{};
        if (ic_slots.len != 0 and @intFromPtr(ic_slots.ptr) != 0) {
            if (registry) |shape_registry| {
                for (ic_slots) |*slot| slot.deinit(shape_registry);
            }
            self.memory.free(ic.Slot, ic_slots);
        }
        const ic_site_ids = self.ic_site_ids;
        self.ic_site_ids = &.{};
        if (ic_site_ids.len != 0 and @intFromPtr(ic_site_ids.ptr) != 0) {
            self.memory.free(usize, ic_site_ids);
        }
        const ic_sites = self.ic_sites;
        self.ic_sites = &.{};
        if (ic_sites.len != 0 and @intFromPtr(ic_sites.ptr) != 0) {
            self.memory.free(ic.Site, ic_sites);
        }
    }
};

/// Alignment of the consolidated `FunctionBytecode.block` allocation. Must
/// cover the widest element type packed into the block.
pub const block_alignment: std.mem.Alignment = .fromByteUnits(@max(
    @alignOf(JSValue),
    @alignOf(CallSite),
    @alignOf(VarDef),
    @alignOf(ClosureVar),
    @alignOf(atom.Atom),
));

/// Computes the offsets/total size of the consolidated storage block.
/// Callers reserve segments (largest alignment first keeps padding minimal)
/// and then materialize them with `blockSlice` after a single allocation.
pub const BlockBuilder = struct {
    size: usize = 0,

    pub fn reserve(self: *BlockBuilder, comptime T: type, len: usize) usize {
        const offset = std.mem.alignForward(usize, self.size, @alignOf(T));
        self.size = offset + len * @sizeOf(T);
        return offset;
    }
};

/// Reinterpret a segment of a `block_alignment`-aligned block as a typed
/// slice. `offset` must come from `BlockBuilder.reserve` with the same `T`.
pub fn blockSlice(block: []u8, comptime T: type, offset: usize, len: usize) []T {
    if (len == 0) return &.{};
    std.debug.assert(offset + len * @sizeOf(T) <= block.len);
    const ptr: [*]T = @ptrCast(@alignCast(block.ptr + offset));
    return ptr[0..len];
}

fn releaseAtomSlice(atoms: *atom.AtomTable, mem: *memory.MemoryAccount, slot: *[]atom.Atom, owned: bool) void {
    const items = slot.*;
    slot.* = &.{};
    for (items) |atom_id| atoms.free(atom_id);
    if (owned and items.len != 0) mem.free(atom.Atom, items);
}

fn releaseCallSites(atoms: *atom.AtomTable, mem: *memory.MemoryAccount, slot: *[]CallSite, owned: bool) void {
    const items = slot.*;
    slot.* = &.{};
    for (items) |site| atoms.free(site.atom_id);
    if (owned and items.len != 0) mem.free(CallSite, items);
}

fn releaseSlice(comptime T: type, mem: *memory.MemoryAccount, slot: *[]T, owned: bool) void {
    const items = slot.*;
    slot.* = &.{};
    if (owned and items.len != 0) mem.free(T, items);
}

fn addSliceBytes(total: usize, comptime T: type, len: usize) usize {
    const slice_bytes = std.math.mul(usize, @sizeOf(T), len) catch std.math.maxInt(usize);
    return addSaturating(total, slice_bytes);
}

fn addSaturating(a: usize, b: usize) usize {
    return std.math.add(usize, a, b) catch std.math.maxInt(usize);
}

pub fn destroyFunctionBytecode(header: *gc.ObjectHeader, destroy_ctx: ?*anyopaque) void {
    const rt: *runtime.JSRuntime = @ptrCast(@alignCast(destroy_ctx orelse return));
    destroyFromHeader(rt, header);
}

pub fn destroyFromHeader(rt: anytype, header: *gc.Header) void {
    const self: *FunctionBytecode = @alignCast(@fieldParentPtr("header", header));
    self.deinit(rt);
    rt.memory.free(FunctionBytecode, self[0..1]);
}

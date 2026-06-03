const std = @import("std");
const build_options = @import("build_options");
const atom = @import("../core/atom.zig");
const gc = @import("../core/gc.zig");
const memory = @import("../core/memory.zig");
const JSValue = @import("../core/value.zig").JSValue;
const constant = @import("constant.zig");
const debug = @import("debug.zig");
const ic = @import("ic.zig");
const module = @import("module.zig");
const opcode = @import("opcode.zig");
const pc2line = @import("pipeline/pc2line.zig");
const scope = @import("scope.zig");
const function_def = @import("function_def.zig");
const runtime = @import("../core/runtime.zig");

/// Generic geometric growth helper, identical in shape to the FunctionDef
/// helper of the same name. Keeps `slice.*.len` as the *used* count and
/// `slice.*.ptr[0..capacity.*]` as the allocator-owned buffer. Returns the
/// freshly grown tail (length `n`).
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

fn freeOwnedAtomSlice(atoms: *atom.AtomTable, mem: *memory.MemoryAccount, slot: *[]atom.Atom) void {
    const items = slot.*;
    slot.* = &.{};
    for (items) |atom_id| atoms.free(atom_id);
    if (items.len != 0) mem.free(atom.Atom, items);
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

fn freeOwnedSlice(comptime T: type, mem: *memory.MemoryAccount, slot: *[]T) void {
    const items = slot.*;
    slot.* = &.{};
    if (items.len != 0) mem.free(T, items);
}

pub const Flags = packed struct(u16) {
    has_prototype: bool = false,
    has_simple_parameter_list: bool = true,
    is_derived_class_constructor: bool = false,
    need_home_object: bool = false,
    is_async: bool = false,
    is_generator: bool = false,
    is_strict: bool = false,
    runtime_strict: bool = false,
    is_global_var: bool = false,
    is_module: bool = false,
    is_indirect_eval: bool = false,
    reserved: u5 = 0,
};

pub const SimpleNumericKind = enum(u8) {
    none,
    arg0_const,
    arg0_arg1,
    capture0_arg0,
};

pub const SimpleStringKind = enum(u8) {
    none,
    percent_hex_byte,
};

const IcSite = struct {
    pc: usize,
    slot_index: usize,
};

pub const Bytecode = struct {
    memory: *memory.MemoryAccount,
    atoms: *atom.AtomTable,
    name: atom.Atom,
    filename: atom.Atom,
    line_num: i32 = 1,
    col_num: i32 = 1,
    pc2line_buf: []u8 = &.{},
    owns_pc2line_buf: bool = false,
    pc2line_start_line: i32 = 1,
    pc2line_start_col: i32 = 1,
    source_loc_slots: []pc2line.SourceLocSlot = &.{},
    source_loc_capacity: usize = 0,
    flags: Flags = .{},
    arg_count: u16 = 0,
    var_count: u16 = 0,
    stack_size: u16 = 0,
    /// `code` and `atom_operands` are mutated by the parser via geometric
    /// growth (see `appendCode` / `retainAtomOperand`). The visible slice
    /// length is the *used* count; the backing buffer is sized by
    /// `code_capacity` / `atom_operands_capacity`. After
    /// `resolve_variables` rewrites the buffers in place these stay 0
    /// because that pass installs slices that exactly fit the resolved
    /// length.
    code: []u8 = &.{},
    code_capacity: usize = 0,
    atom_operands: []atom.Atom = &.{},
    atom_operands_capacity: usize = 0,
    arg_names: []atom.Atom = &.{},
    var_names: []atom.Atom = &.{},
    var_is_lexical: []bool = &.{},
    var_is_const: []bool = &.{},
    var_ref_names: []atom.Atom = &.{},
    var_ref_is_lexical: []bool = &.{},
    var_ref_is_const: []bool = &.{},
    global_var_names: []atom.Atom = &.{},
    private_bound_names: []atom.Atom = &.{},
    constants: constant.Pool,
    scopes: []scope.ScopeRecord = &.{},
    scopes_capacity: usize = 0,
    module_record: ?module.Record = null,
    debug_table: ?debug.Table = null,
    ic_slots: []ic.Slot = &.{},
    ic_site_ids: []usize = &.{},
    ic_sites: []IcSite = &.{},

    pub fn init(account: *memory.MemoryAccount, atoms: *atom.AtomTable, name: atom.Atom) Bytecode {
        return .{
            .memory = account,
            .atoms = atoms,
            .name = atoms.dup(name),
            .filename = atoms.dup(name),
            .constants = constant.Pool.init(account, atoms),
        };
    }

    pub fn deinit(self: *Bytecode, rt: anytype) void {
        const name = self.name;
        const filename = self.filename;
        self.name = atom.null_atom;
        self.filename = atom.null_atom;
        self.atoms.free(name);
        self.atoms.free(filename);
        freeGrowableAtomSlice(self.atoms, self.memory, &self.atom_operands, &self.atom_operands_capacity);
        freeOwnedAtomSlice(self.atoms, self.memory, &self.arg_names);
        freeOwnedAtomSlice(self.atoms, self.memory, &self.var_names);
        freeOwnedSlice(bool, self.memory, &self.var_is_lexical);
        freeOwnedSlice(bool, self.memory, &self.var_is_const);
        freeOwnedAtomSlice(self.atoms, self.memory, &self.var_ref_names);
        freeOwnedSlice(bool, self.memory, &self.var_ref_is_lexical);
        freeOwnedSlice(bool, self.memory, &self.var_ref_is_const);
        freeOwnedAtomSlice(self.atoms, self.memory, &self.global_var_names);
        freeOwnedAtomSlice(self.atoms, self.memory, &self.private_bound_names);
        freeGrowableSlice(u8, self.memory, &self.code, &self.code_capacity);
        freeGrowableSlice(pc2line.SourceLocSlot, self.memory, &self.source_loc_slots, &self.source_loc_capacity);
        const pc2line_buf = self.pc2line_buf;
        const owns_pc2line_buf = self.owns_pc2line_buf;
        self.pc2line_buf = &.{};
        self.owns_pc2line_buf = false;
        self.constants.deinit(rt);
        for (self.scopes) |*scope_record| scope_record.deinit();
        freeGrowableSlice(scope.ScopeRecord, self.memory, &self.scopes, &self.scopes_capacity);
        var module_record = self.module_record;
        var debug_table = self.debug_table;
        self.module_record = null;
        self.debug_table = null;
        if (module_record) |*record| record.deinit();
        if (debug_table) |*table| table.deinit();
        self.deinitIcSlots(rt);
        if (owns_pc2line_buf and pc2line_buf.len != 0) self.memory.free(u8, pc2line_buf);
    }

    pub fn allocateIcSlots(self: *Bytecode) !void {
        self.deinitIcSlots(null);
        if (!build_options.zjs_enable_ic) return;
        if (self.code.len == 0) return;
        if (bytecodeSkipsPropertyIc(self.code)) return;
        const site_count = countIcSitesInCode(self.code);
        if (site_count == 0) return;
        const use_dense_sites = shouldUseDenseIcSiteIds(self.code.len, site_count);
        var site_ids: []usize = &.{};
        if (use_dense_sites) site_ids = try self.allocateIcSiteIds(self.code);
        errdefer if (site_ids.len != 0) self.memory.free(usize, site_ids);
        var sites: []IcSite = &.{};
        if (!use_dense_sites) sites = try self.allocateIcSites(self.code, site_count);
        errdefer if (sites.len != 0) self.memory.free(IcSite, sites);
        const slots = try self.memory.alloc(ic.Slot, site_count);
        errdefer self.memory.free(ic.Slot, slots);
        @memset(slots, .{});
        self.ic_site_ids = site_ids;
        self.ic_sites = sites;
        self.ic_slots = slots;
    }

    fn deinitIcSlots(self: *Bytecode, rt: ?*runtime.JSRuntime) void {
        const ic_slots = self.ic_slots;
        self.ic_slots = &.{};
        if (ic_slots.len != 0 and @intFromPtr(ic_slots.ptr) != 0) {
            if (rt) |runtime_ptr| {
                for (ic_slots) |*slot| slot.deinit(&runtime_ptr.shapes);
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
            self.memory.free(IcSite, ic_sites);
        }
    }

    pub fn icSlotForPc(self: *const Bytecode, site_pc: usize) ?*ic.Slot {
        if (self.ic_site_ids.len != 0) {
            if (site_pc >= self.ic_site_ids.len) return null;
            const site_id = self.ic_site_ids[site_pc];
            if (site_id == std.math.maxInt(usize) or site_id >= self.ic_slots.len) return null;
            return @constCast(&self.ic_slots[site_id]);
        }
        const site = findIcSite(self.ic_sites, site_pc) orelse return null;
        if (site.slot_index >= self.ic_slots.len) return null;
        return @constCast(&self.ic_slots[site.slot_index]);
    }

    fn allocateIcSiteIds(self: *Bytecode, code: []const u8) ![]usize {
        const site_ids = try self.memory.alloc(usize, code.len);
        errdefer self.memory.free(usize, site_ids);
        @memset(site_ids, std.math.maxInt(usize));
        var next_site_id: usize = 0;
        var pc: usize = 0;
        while (pc < code.len) {
            const op_id = code[pc];
            const size = opcode.sizeOf(op_id);
            if (size == 0 or pc + size > code.len) return error.InvalidBytecode;
            if (opcodeHasOwnDataIc(op_id)) {
                site_ids[pc] = next_site_id;
                next_site_id += 1;
            }
            pc += size;
        }
        return site_ids;
    }

    fn allocateIcSites(self: *Bytecode, code: []const u8, site_count: usize) ![]IcSite {
        const sites = try self.memory.alloc(IcSite, site_count);
        errdefer self.memory.free(IcSite, sites);
        var next_site_id: usize = 0;
        var pc: usize = 0;
        while (pc < code.len) {
            const op_id = code[pc];
            const size = opcode.sizeOf(op_id);
            if (size == 0 or pc + size > code.len) return error.InvalidBytecode;
            if (opcodeHasOwnDataIc(op_id)) {
                sites[next_site_id] = .{ .pc = pc, .slot_index = next_site_id };
                next_site_id += 1;
            }
            pc += size;
        }
        std.debug.assert(next_site_id == site_count);
        return sites;
    }

    pub fn setCode(self: *Bytecode, bytes: []const u8) !void {
        freeGrowableSlice(u8, self.memory, &self.code, &self.code_capacity);
        if (bytes.len == 0) {
            self.code = &.{};
            self.code_capacity = 0;
            return;
        }
        const owned = try self.memory.alloc(u8, bytes.len);
        errdefer self.memory.free(u8, owned);
        @memcpy(owned, bytes);
        self.code = owned;
        self.code_capacity = bytes.len;
    }

    /// Append bytes to `code` with geometric growth. The visible slice
    /// length tracks the used count so callers can read `code.len` for
    /// the current size, while reallocations are amortised O(1).
    pub fn appendCode(self: *Bytecode, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        const tail = try growSliceBy(u8, self.memory, &self.code, &self.code_capacity, bytes.len);
        @memcpy(tail, bytes);
    }

    pub fn appendSourceLoc(self: *Bytecode, pc: u32, line_num: i32, col_num: i32) !void {
        if (line_num <= 0 or col_num <= 0) return;
        const tail = try growSliceBy(pc2line.SourceLocSlot, self.memory, &self.source_loc_slots, &self.source_loc_capacity, 1);
        tail[0] = .{ .pc = pc, .line_num = line_num, .col_num = col_num };
    }

    pub fn remapSourceLocs(self: *Bytecode, old_to_new_pc: []const usize) void {
        if (self.source_loc_slots.len == 0) return;
        for (self.source_loc_slots) |*slot| {
            if (slot.pc >= old_to_new_pc.len) continue;
            slot.pc = @intCast(old_to_new_pc[slot.pc]);
        }
    }

    /// Truncate `code` back to `target_len` bytes, preserving capacity so
    /// re-emission after speculative rollback does not reallocate.
    pub fn truncateCode(self: *Bytecode, target_len: usize) void {
        std.debug.assert(target_len <= self.code.len);
        self.code = self.code.ptr[0..target_len];
    }

    /// Replace the `code` buffer with an exact-fit slice. Used by pipeline
    /// passes that fully rewrite the buffer (e.g. `resolve_variables`).
    /// The provided slice is taken over; any prior buffer is freed.
    pub fn installCode(self: *Bytecode, owned: []u8) void {
        freeGrowableSlice(u8, self.memory, &self.code, &self.code_capacity);
        self.code = owned;
        self.code_capacity = owned.len;
    }

    pub fn installPc2Line(self: *Bytecode, owned: []u8, start_line_num: i32, start_col_num: i32) void {
        const old = self.pc2line_buf;
        const old_owned = self.owns_pc2line_buf;
        self.pc2line_buf = owned;
        self.owns_pc2line_buf = owned.len != 0;
        self.pc2line_start_line = start_line_num;
        self.pc2line_start_col = start_col_num;
        if (old_owned and old.len != 0) self.memory.free(u8, old);
    }

    /// Replace the `atom_operands` buffer with an exact-fit slice. The
    /// provided slice is taken over; any prior buffer is freed and atom
    /// refcounts already held by `atom_operands` are NOT released by this
    /// helper (callers must release them explicitly when needed).
    pub fn installAtomOperands(self: *Bytecode, owned: []atom.Atom) void {
        freeGrowableSlice(atom.Atom, self.memory, &self.atom_operands, &self.atom_operands_capacity);
        self.atom_operands = owned;
        self.atom_operands_capacity = owned.len;
    }

    pub fn addConstant(self: *Bytecode, value: JSValue) !u32 {
        return self.constants.append(value);
    }

    pub fn retainAtomOperand(self: *Bytecode, atom_id: atom.Atom) !void {
        const tail = try growSliceBy(atom.Atom, self.memory, &self.atom_operands, &self.atom_operands_capacity, 1);
        tail[0] = self.atoms.dup(atom_id);
    }

    /// Truncate `atom_operands` to `target_len` entries, releasing the
    /// per-element atom refcounts but keeping the backing buffer.
    pub fn truncateAtomOperands(self: *Bytecode, target_len: usize) void {
        std.debug.assert(target_len <= self.atom_operands.len);
        var i: usize = target_len;
        while (i < self.atom_operands.len) : (i += 1) {
            self.atoms.free(self.atom_operands[i]);
        }
        self.atom_operands = self.atom_operands.ptr[0..target_len];
    }

    pub fn addScope(self: *Bytecode, parent: ?u32) !*scope.ScopeRecord {
        const tail = try growSliceBy(scope.ScopeRecord, self.memory, &self.scopes, &self.scopes_capacity, 1);
        tail[0] = scope.ScopeRecord.init(self.memory, self.atoms, parent);
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

/// Mirrors `JSFunctionBytecode` (`quickjs.c:768-804`).
///
/// This is the final compiled bytecode structure produced by the
/// js_create_function equivalent. It contains the fully processed
/// bytecode after all pipeline phases (resolve_variables, resolve_labels,
/// compute_stack_size, etc.).
///
/// The VM still executes the existing `Bytecode` instruction view. Finalized
/// functions therefore expose `asBytecodeView`, a borrowed execution view over
/// this GC-owned artifact. That keeps compile-time scratch state out of
/// `FunctionBytecode` while making the storage/execution boundary explicit.
///
/// Field order matches QuickJS exactly for strong alignment (§1.5.3).
/// Uses flat per-field allocation instead of QuickJS's single contiguous
/// allocation - registered as deviation D2 in parser-deviation-matrix.md.
pub const FunctionBytecode = struct {
    header: gc.GCObjectHeader,
    gc: gc.GcNode = .{},
    memory: *memory.MemoryAccount,
    atoms: *atom.AtomTable,

    // Flags (mirrors JSFunctionBytecode packed fields, same order as quickjs.c:770-782)
    is_strict_mode: bool = false,
    runtime_strict_mode: bool = false,
    has_prototype: bool = false,
    has_simple_parameter_list: bool = true,
    is_class_constructor: bool = false,
    is_derived_class_constructor: bool = false,
    need_home_object: bool = false,
    func_kind: function_def.FunctionKind = .normal,
    is_arrow_function: bool = false,
    new_target_allowed: bool = false,
    super_call_allowed: bool = false,
    super_allowed: bool = false,
    arguments_allowed: bool = false,
    backtrace_barrier: bool = false,
    is_indirect_eval: bool = false,

    // Bytecode (quickjs.c:783-784)
    byte_code: []u8 = &.{},
    byte_code_len: i32 = 0,
    generator_body_pc: usize = 0,
    atom_operands: []atom.Atom = &.{},
    arg_names: []atom.Atom = &.{},
    var_names: []atom.Atom = &.{},
    var_is_lexical: []bool = &.{},
    var_is_const: []bool = &.{},
    var_ref_names: []atom.Atom = &.{},
    var_ref_is_lexical: []bool = &.{},
    var_ref_is_const: []bool = &.{},
    global_var_names: []atom.Atom = &.{},

    // Metadata (quickjs.c:785-792)
    func_name: atom.Atom,
    vardefs: []function_def.VarDef = &.{},
    closure_var: []function_def.ClosureVar = &.{},
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
    simple_numeric_kind: SimpleNumericKind = .none,
    simple_numeric_op: u8 = 0,
    simple_numeric_rhs: i32 = 0,
    simple_string_kind: SimpleStringKind = .none,
    ic_slots: []ic.Slot = &.{},
    ic_site_ids: []usize = &.{},
    ic_sites: []IcSite = &.{},

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

    /// Return a borrowed `Bytecode` execution view for the current VM.
    ///
    /// The returned value does not own any slices and must not be deinitialized.
    /// It intentionally omits compile-only fields such as scopes, modules, and
    /// debug tables; those remain on the compile-time `Bytecode` representation.
    pub fn asBytecodeView(self: *const FunctionBytecode, rt: *runtime.JSRuntime) Bytecode {
        return .{
            .memory = &rt.memory,
            .atoms = &rt.atoms,
            .name = self.func_name,
            .filename = self.filename,
            .line_num = self.line_num,
            .col_num = self.col_num,
            .pc2line_buf = self.pc2line_buf,
            .owns_pc2line_buf = false,
            .pc2line_start_line = self.line_num,
            .pc2line_start_col = self.col_num,
            .flags = .{
                .has_prototype = self.has_prototype,
                .has_simple_parameter_list = self.has_simple_parameter_list,
                .is_derived_class_constructor = self.is_derived_class_constructor,
                .is_async = self.func_kind == .async or self.func_kind == .async_generator,
                .is_generator = self.func_kind == .generator or self.func_kind == .async_generator,
                .is_strict = self.is_strict_mode,
                .runtime_strict = self.runtime_strict_mode,
                .is_indirect_eval = self.is_indirect_eval,
            },
            .arg_count = self.arg_count,
            .var_count = self.var_count,
            .stack_size = self.stack_size,
            .code = self.byte_code,
            .atom_operands = self.atom_operands,
            .arg_names = self.arg_names,
            .var_names = self.var_names,
            .var_is_lexical = self.var_is_lexical,
            .var_is_const = self.var_is_const,
            .var_ref_names = self.var_ref_names,
            .var_ref_is_lexical = self.var_ref_is_lexical,
            .var_ref_is_const = self.var_ref_is_const,
            .global_var_names = self.global_var_names,
            .private_bound_names = self.private_bound_names,
            .ic_slots = self.ic_slots,
            .ic_site_ids = self.ic_site_ids,
            .ic_sites = self.ic_sites,
            .constants = .{ .memory = &rt.memory, .atoms = &rt.atoms, .values = self.cpool },
        };
    }

    pub fn deinit(self: *FunctionBytecode, rt: anytype) void {
        const func_name = self.func_name;
        const filename = self.filename;
        self.func_name = atom.null_atom;
        self.filename = atom.null_atom;
        self.atoms.free(func_name);
        self.atoms.free(filename);

        const byte_code = self.byte_code;
        self.byte_code = &.{};
        self.byte_code_len = 0;
        if (byte_code.len != 0) self.memory.free(u8, byte_code);
        freeOwnedAtomSlice(self.atoms, self.memory, &self.atom_operands);
        freeOwnedAtomSlice(self.atoms, self.memory, &self.arg_names);
        freeOwnedAtomSlice(self.atoms, self.memory, &self.var_names);
        freeOwnedSlice(bool, self.memory, &self.var_is_lexical);
        freeOwnedSlice(bool, self.memory, &self.var_is_const);
        freeOwnedAtomSlice(self.atoms, self.memory, &self.var_ref_names);
        freeOwnedSlice(bool, self.memory, &self.var_ref_is_lexical);
        freeOwnedSlice(bool, self.memory, &self.var_ref_is_const);
        freeOwnedAtomSlice(self.atoms, self.memory, &self.global_var_names);

        const vardefs = self.vardefs;
        self.vardefs = &.{};
        for (vardefs) |*v| self.atoms.free(v.var_name);
        if (vardefs.len != 0) self.memory.free(function_def.VarDef, vardefs);

        const closure_var = self.closure_var;
        self.closure_var = &.{};
        for (closure_var) |*cv| self.atoms.free(cv.var_name);
        if (closure_var.len != 0) self.memory.free(function_def.ClosureVar, closure_var);

        freeOwnedAtomSlice(self.atoms, self.memory, &self.class_instance_fields);
        freeOwnedAtomSlice(self.atoms, self.memory, &self.private_bound_names);
        freeOwnedAtomSlice(self.atoms, self.memory, &self.class_private_names);
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
        if (cpool.len != 0) self.memory.free(JSValue, cpool);

        const pc2line_buf = self.pc2line_buf;
        self.pc2line_buf = &.{};
        self.pc2line_len = 0;
        if (pc2line_buf.len != 0) self.memory.free(u8, pc2line_buf);

        if (self.source) |src| {
            // Cast away const for freeing - the memory was allocated as mutable
            self.source = null;
            self.memory.free(u8, @constCast(src));
        }
        self.source_len = 0;
        self.deinitIcSlots(rt);

        self.class_fields_init = null;
        self.cpool = &.{};
    }

    pub fn allocateIcSlots(self: *FunctionBytecode) !void {
        self.deinitIcSlots(null);
        if (!build_options.zjs_enable_ic) return;
        if (self.byte_code.len == 0) return;
        if (bytecodeSkipsPropertyIc(self.byte_code)) return;
        const site_count = countIcSitesInCode(self.byte_code);
        if (site_count == 0) return;
        const use_dense_sites = shouldUseDenseIcSiteIds(self.byte_code.len, site_count);
        var site_ids: []usize = &.{};
        if (use_dense_sites) site_ids = try self.allocateIcSiteIds(self.byte_code);
        errdefer if (site_ids.len != 0) self.memory.free(usize, site_ids);
        var sites: []IcSite = &.{};
        if (!use_dense_sites) sites = try self.allocateIcSites(self.byte_code, site_count);
        errdefer if (sites.len != 0) self.memory.free(IcSite, sites);
        const slots = try self.memory.alloc(ic.Slot, site_count);
        errdefer self.memory.free(ic.Slot, slots);
        @memset(slots, .{});
        self.ic_site_ids = site_ids;
        self.ic_sites = sites;
        self.ic_slots = slots;
    }

    fn deinitIcSlots(self: *FunctionBytecode, rt: ?*runtime.JSRuntime) void {
        const ic_slots = self.ic_slots;
        self.ic_slots = &.{};
        if (ic_slots.len != 0 and @intFromPtr(ic_slots.ptr) != 0) {
            if (rt) |runtime_ptr| {
                for (ic_slots) |*slot| slot.deinit(&runtime_ptr.shapes);
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
            self.memory.free(IcSite, ic_sites);
        }
    }

    fn allocateIcSiteIds(self: *FunctionBytecode, code: []const u8) ![]usize {
        const site_ids = try self.memory.alloc(usize, code.len);
        errdefer self.memory.free(usize, site_ids);
        @memset(site_ids, std.math.maxInt(usize));
        var next_site_id: usize = 0;
        var pc: usize = 0;
        while (pc < code.len) {
            const op_id = code[pc];
            const size = opcode.sizeOf(op_id);
            if (size == 0 or pc + size > code.len) return error.InvalidBytecode;
            if (opcodeHasOwnDataIc(op_id)) {
                site_ids[pc] = next_site_id;
                next_site_id += 1;
            }
            pc += size;
        }
        return site_ids;
    }

    fn allocateIcSites(self: *FunctionBytecode, code: []const u8, site_count: usize) ![]IcSite {
        const sites = try self.memory.alloc(IcSite, site_count);
        errdefer self.memory.free(IcSite, sites);
        var next_site_id: usize = 0;
        var pc: usize = 0;
        while (pc < code.len) {
            const op_id = code[pc];
            const size = opcode.sizeOf(op_id);
            if (size == 0 or pc + size > code.len) return error.InvalidBytecode;
            if (opcodeHasOwnDataIc(op_id)) {
                sites[next_site_id] = .{ .pc = pc, .slot_index = next_site_id };
                next_site_id += 1;
            }
            pc += size;
        }
        std.debug.assert(next_site_id == site_count);
        return sites;
    }
};

fn opcodeHasOwnDataIc(op_id: u8) bool {
    return op_id == opcode.op.get_var or
        op_id == opcode.op.get_var_undef or
        op_id == opcode.op.put_var or
        op_id == opcode.op.get_field or
        op_id == opcode.op.get_field2 or
        op_id == opcode.op.put_field;
}

fn bytecodeSkipsPropertyIc(code: []const u8) bool {
    var pc: usize = 0;
    while (pc < code.len) {
        const op_id = code[pc];
        const size = opcode.sizeOf(op_id);
        if (size == 0 or pc + size > code.len) return true;
        switch (op_id) {
            opcode.op.eval,
            opcode.op.apply_eval,
            opcode.op.with_get_var,
            opcode.op.with_put_var,
            opcode.op.with_delete_var,
            opcode.op.with_make_ref,
            opcode.op.with_get_ref,
            opcode.op.with_get_ref_undef,
            => return true,
            else => {},
        }
        pc += size;
    }
    return false;
}

fn countIcSitesInCode(code: []const u8) usize {
    var count: usize = 0;
    var pc: usize = 0;
    while (pc < code.len) {
        const op_id = code[pc];
        const size = opcode.sizeOf(op_id);
        if (size == 0 or pc + size > code.len) return 0;
        if (opcodeHasOwnDataIc(op_id)) count += 1;
        pc += size;
    }
    return count;
}

fn shouldUseDenseIcSiteIds(code_len: usize, site_count: usize) bool {
    return code_len > 128 or site_count > 8;
}

fn findIcSite(sites: []const IcSite, site_pc: usize) ?IcSite {
    var low: usize = 0;
    var high: usize = sites.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        const site = sites[mid];
        if (site.pc == site_pc) return site;
        if (site.pc < site_pc) {
            low = mid + 1;
        } else {
            high = mid;
        }
    }
    return null;
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

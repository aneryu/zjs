const std = @import("std");
const build_options = @import("build_options");
const atom = @import("../core/atom.zig");
const function_bytecode = @import("../core/function_bytecode.zig");
const memory = @import("../core/memory.zig");
const JSValue = @import("../core/value.zig").JSValue;
const constant = @import("constant.zig");
const debug = @import("debug.zig");
const ic = @import("../core/ic.zig");
const module = @import("module.zig");
const opcode = @import("opcode.zig");
const pc2line = @import("pipeline/pc2line.zig");
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

fn freeOwnedClosureVarSlice(atoms: *atom.AtomTable, mem: *memory.MemoryAccount, slot: *[]function_bytecode.ClosureVar) void {
    const items = slot.*;
    slot.* = &.{};
    for (items) |*cv| atoms.free(cv.var_name);
    if (items.len != 0) mem.free(function_bytecode.ClosureVar, items);
}

fn freeOwnedGlobalVarSlice(atoms: *atom.AtomTable, mem: *memory.MemoryAccount, slot: *[]function_bytecode.GlobalVar) void {
    const items = slot.*;
    slot.* = &.{};
    for (items) |*gv| atoms.free(gv.var_name);
    if (items.len != 0) mem.free(function_bytecode.GlobalVar, items);
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
    has_eval_call: bool = false,
    backtrace_barrier: bool = false,
    reserved: u3 = 0,
};

/// Compatibility aliases for finalized runtime function bytecode.
/// The GC object lives in core; bytecode keeps opcode-aware helpers below.
pub const FunctionBytecode = function_bytecode.FunctionBytecode;
pub const FunctionKind = function_bytecode.FunctionKind;
pub const ClosureType = function_bytecode.ClosureType;
pub const VarKind = function_bytecode.VarKind;
pub const VarDef = function_bytecode.VarDef;
pub const ClosureVar = function_bytecode.ClosureVar;
pub const CallSiteKind = function_bytecode.CallSiteKind;
pub const CallSite = function_bytecode.CallSite;

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

const IcSite = ic.Site;

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
    // Lexical scope level (`JSVarDef.scope_level`) per local slot. Top-level
    // (scope_level == 0) lexicals participate in the global-lexical sync; a
    // block-level shadower (scope_level > 0) that happens to share a name with
    // a top-level `let`/`const` must NOT. Mirrors qjs, where a block `let` is a
    // pure frame local (`add_scope_var`) with no tie to the global_decl cell.
    var_scope_level: []i32 = &.{},
    var_ref_names: []atom.Atom = &.{},
    var_ref_is_lexical: []bool = &.{},
    var_ref_is_const: []bool = &.{},
    // True for each var-ref that is a top-level script lexical (closure_type
    // == .global_decl, qjs JS_CLOSURE_GLOBAL_DECL). Distinguishes top-level
    // let/const from hoisted function-decl closure vars at instantiation.
    var_ref_is_global_decl: []bool = &.{},
    closure_var: []function_bytecode.ClosureVar = &.{},
    global_var_names: []atom.Atom = &.{},
    global_vars: []function_bytecode.GlobalVar = &.{},
    private_bound_names: []atom.Atom = &.{},
    constants: constant.Pool,
    module_record: ?module.Record = null,
    debug_table: ?debug.Table = null,
    ic_slots: []ic.Slot = &.{},
    ic_site_ids: []usize = &.{},
    ic_sites: []IcSite = &.{},
    direct_call_sites: []DirectCallSite = &.{},
    direct_call_sites_capacity: usize = 0,
    call_sites: []CallSite = &.{},
    call_sites_capacity: usize = 0,

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
        freeOwnedSlice(i32, self.memory, &self.var_scope_level);
        freeOwnedAtomSlice(self.atoms, self.memory, &self.var_ref_names);
        freeOwnedSlice(bool, self.memory, &self.var_ref_is_lexical);
        freeOwnedSlice(bool, self.memory, &self.var_ref_is_const);
        freeOwnedSlice(bool, self.memory, &self.var_ref_is_global_decl);
        freeOwnedClosureVarSlice(self.atoms, self.memory, &self.closure_var);
        freeOwnedAtomSlice(self.atoms, self.memory, &self.global_var_names);
        freeOwnedGlobalVarSlice(self.atoms, self.memory, &self.global_vars);
        freeOwnedAtomSlice(self.atoms, self.memory, &self.private_bound_names);
        freeGrowableSlice(u8, self.memory, &self.code, &self.code_capacity);
        freeGrowableSlice(pc2line.SourceLocSlot, self.memory, &self.source_loc_slots, &self.source_loc_capacity);
        const pc2line_buf = self.pc2line_buf;
        const owns_pc2line_buf = self.owns_pc2line_buf;
        self.pc2line_buf = &.{};
        self.owns_pc2line_buf = false;
        self.constants.deinit(rt);
        var module_record = self.module_record;
        var debug_table = self.debug_table;
        self.module_record = null;
        self.debug_table = null;
        if (module_record) |*record| record.deinit();
        if (debug_table) |*table| table.deinit();
        self.deinitIcSlots(rt);
        self.deinitDirectCallSites();
        self.deinitCallSites();
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
        if (use_dense_sites) site_ids = try allocateIcSiteIds(self.memory, self.code);
        errdefer if (site_ids.len != 0) self.memory.free(usize, site_ids);
        var sites: []IcSite = &.{};
        if (!use_dense_sites) sites = try allocateIcSites(self.memory, self.code, site_count);
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
        return lookupIcSlotForPc(self.ic_slots, self.ic_site_ids, self.ic_sites, site_pc);
    }

    pub fn setCode(self: *Bytecode, bytes: []const u8) !void {
        freeGrowableSlice(u8, self.memory, &self.code, &self.code_capacity);
        if (bytes.len == 0) {
            self.code = &.{};
            self.code_capacity = 0;
            return;
        }
        // Allocate one extra trailing byte holding an `op.return` sentinel.
        // qjs-aligned: every real function is terminated by a return, so the
        // register-resident dispatch carries no per-op fall-off-end bounds
        // check. Hand-authored test bytecode that omits a terminator reads this
        // sentinel on fall-off and returns the stack top — exactly the
        // completion value the old bounds-checked fall-off produced. The
        // sentinel sits just past the visible `code` slice; terminated
        // bytecode hits its own return first and never observes it.
        const owned = try self.memory.alloc(u8, bytes.len + 1);
        errdefer self.memory.free(u8, owned);
        @memcpy(owned[0..bytes.len], bytes);
        owned[bytes.len] = opcode.op.@"return";
        self.code = owned[0..bytes.len];
        self.code_capacity = bytes.len + 1;
    }

    /// Append bytes to `code` with geometric growth. The visible slice
    /// length tracks the used count so callers can read `code.len` for
    /// the current size, while reallocations are amortised O(1).
    pub fn appendCode(self: *Bytecode, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        if (bytesMayContainEvalCall(bytes)) self.flags.has_eval_call = true;
        const tail = try growSliceBy(u8, self.memory, &self.code, &self.code_capacity, bytes.len);
        @memcpy(tail, bytes);
    }

    /// Ensure a trailing `op.return` sentinel one byte past the visible `code`
    /// slice without changing `code.len` (mirrors setCode). Defensive backstop
    /// for the register-resident dispatch's removed fall-off-end bounds check:
    /// parser-produced code always ends in a cold terminator and never reads it,
    /// but a hand-built top-level `Bytecode` ending in a hot opcode would
    /// otherwise read `code[code.len]` (heap garbage) on fall-off.
    pub fn ensureTrailingReturnSentinel(self: *Bytecode) !void {
        if (self.code.len == 0) return;
        const len = self.code.len;
        _ = try growSliceBy(u8, self.memory, &self.code, &self.code_capacity, 1);
        self.code = self.code[0..len];
        self.code.ptr[len] = opcode.op.@"return";
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

    pub fn remapDirectCallSites(self: *Bytecode, old_to_new_pc: []const usize) void {
        if (self.direct_call_sites.len == 0) return;
        for (self.direct_call_sites) |*site| {
            if (site.prepare_pc < old_to_new_pc.len) {
                site.prepare_pc = @intCast(old_to_new_pc[site.prepare_pc]);
            } else {
                site.prepare_pc = std.math.maxInt(u32);
            }
            if (site.call_pc < old_to_new_pc.len) {
                site.call_pc = @intCast(old_to_new_pc[site.call_pc]);
            } else {
                site.call_pc = std.math.maxInt(u32);
            }
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

    pub fn appendDirectCallSite(self: *Bytecode, site: DirectCallSite) !void {
        const tail = try growSliceBy(DirectCallSite, self.memory, &self.direct_call_sites, &self.direct_call_sites_capacity, 1);
        tail[0] = site;
        tail[0].atom_id = self.atoms.dup(site.atom_id);
    }

    pub fn appendCallSite(self: *Bytecode, site: CallSite) !u16 {
        if (self.call_sites.len >= std.math.maxInt(u16)) return error.BytecodeOverflow;
        const tail = try growSliceBy(CallSite, self.memory, &self.call_sites, &self.call_sites_capacity, 1);
        tail[0] = site;
        tail[0].atom_id = self.atoms.dup(site.atom_id);
        return @intCast(self.call_sites.len - 1);
    }

    pub fn deinitDirectCallSites(self: *Bytecode) void {
        const items = self.direct_call_sites;
        const capacity = self.direct_call_sites_capacity;
        self.direct_call_sites = &.{};
        self.direct_call_sites_capacity = 0;
        for (items) |site| self.atoms.free(site.atom_id);
        if (capacity != 0) self.memory.free(DirectCallSite, items.ptr[0..capacity]);
    }

    pub fn deinitCallSites(self: *Bytecode) void {
        const items = self.call_sites;
        const capacity = self.call_sites_capacity;
        self.call_sites = &.{};
        self.call_sites_capacity = 0;
        for (items) |site| self.atoms.free(site.atom_id);
        if (capacity != 0) self.memory.free(CallSite, items.ptr[0..capacity]);
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

/// Return a borrowed `Bytecode` execution view for the current VM.
///
/// The returned value does not own any slices and must not be deinitialized.
/// It intentionally omits compile-only fields such as scopes, modules, and
/// debug tables; those remain on the compile-time `Bytecode` representation.
pub fn asBytecodeView(fb: *const FunctionBytecode, rt: *runtime.JSRuntime) Bytecode {
    return makeBytecodeView(fb, &rt.memory, &rt.atoms);
}

fn makeBytecodeView(fb: *const FunctionBytecode, mem: *memory.MemoryAccount, atoms: *atom.AtomTable) Bytecode {
    return .{
        .memory = mem,
        .atoms = atoms,
        .name = fb.func_name,
        .filename = fb.filename,
        .line_num = fb.line_num,
        .col_num = fb.col_num,
        .pc2line_buf = fb.pc2line_buf,
        .owns_pc2line_buf = false,
        .pc2line_start_line = fb.line_num,
        .pc2line_start_col = fb.col_num,
        .flags = .{
            .has_prototype = fb.has_prototype,
            .has_simple_parameter_list = fb.has_simple_parameter_list,
            .is_derived_class_constructor = fb.is_derived_class_constructor,
            .is_async = fb.func_kind == .async or fb.func_kind == .async_generator,
            .is_generator = fb.func_kind == .generator or fb.func_kind == .async_generator,
            .is_strict = fb.is_strict_mode,
            .runtime_strict = fb.runtime_strict_mode,
            .is_indirect_eval = fb.is_indirect_eval,
            .has_eval_call = fb.has_eval_call,
            .backtrace_barrier = fb.backtrace_barrier,
        },
        .arg_count = fb.arg_count,
        .var_count = fb.var_count,
        .stack_size = fb.stack_size,
        .code = fb.byte_code,
        .atom_operands = fb.atom_operands,
        .arg_names = fb.arg_names,
        .var_names = fb.var_names,
        .var_is_lexical = fb.var_is_lexical,
        .var_is_const = fb.var_is_const,
        .var_scope_level = fb.var_scope_level,
        .var_ref_names = fb.var_ref_names,
        .var_ref_is_lexical = fb.var_ref_is_lexical,
        .var_ref_is_const = fb.var_ref_is_const,
        .var_ref_is_global_decl = fb.var_ref_is_global_decl,
        .closure_var = fb.closure_var,
        .global_var_names = fb.global_var_names,
        .global_vars = fb.global_vars,
        .private_bound_names = fb.private_bound_names,
        .ic_slots = fb.ic_slots,
        .ic_site_ids = fb.ic_site_ids,
        .ic_sites = fb.ic_sites,
        .call_sites = fb.call_sites,
        .constants = .{ .memory = mem, .atoms = atoms, .values = fb.cpool },
    };
}

pub fn cachedBytecodeView(fb: *const FunctionBytecode) ?*const Bytecode {
    const ptr = fb.execution_view orelse return null;
    return @ptrCast(@alignCast(ptr));
}

pub fn installCachedBytecodeView(fb: *FunctionBytecode, view: *Bytecode) void {
    view.* = makeBytecodeView(fb, fb.memory, fb.atoms);
    fb.execution_view = view;
    fb.execution_view_owned = false;
    fb.execution_view_heap_size = 0;
    fb.execution_view_destroy = null;
}

pub fn ensureCachedBytecodeView(fb: *const FunctionBytecode, rt: *runtime.JSRuntime) !*const Bytecode {
    if (cachedBytecodeView(fb)) |view| return view;
    const mutable_fb: *FunctionBytecode = @constCast(fb);
    const view = try rt.memory.create(Bytecode);
    view.* = makeBytecodeView(fb, &rt.memory, &rt.atoms);
    mutable_fb.execution_view = view;
    mutable_fb.execution_view_owned = true;
    mutable_fb.execution_view_heap_size = @sizeOf(Bytecode);
    mutable_fb.execution_view_destroy = destroyCachedBytecodeView;
    return view;
}

pub fn refreshCachedBytecodeView(fb: *FunctionBytecode) void {
    const view = cachedBytecodeView(fb) orelse return;
    @constCast(view).* = makeBytecodeView(fb, fb.memory, fb.atoms);
}

fn destroyCachedBytecodeView(mem: *memory.MemoryAccount, ptr: *anyopaque) void {
    const view: *Bytecode = @ptrCast(@alignCast(ptr));
    mem.destroy(Bytecode, view);
}

pub fn allocateFunctionBytecodeIcSlots(fb: *FunctionBytecode) !void {
    fb.deinitIcSlots(null);
    if (!build_options.zjs_enable_ic) return;
    if (fb.byte_code.len == 0) return;
    if (bytecodeSkipsPropertyIc(fb.byte_code)) return;
    const site_count = countIcSitesInCode(fb.byte_code);
    if (site_count == 0) return;
    const use_dense_sites = shouldUseDenseIcSiteIds(fb.byte_code.len, site_count);
    var site_ids: []usize = &.{};
    if (use_dense_sites) site_ids = try allocateIcSiteIds(fb.memory, fb.byte_code);
    errdefer if (site_ids.len != 0) fb.memory.free(usize, site_ids);
    var sites: []IcSite = &.{};
    if (!use_dense_sites) sites = try allocateIcSites(fb.memory, fb.byte_code, site_count);
    errdefer if (sites.len != 0) fb.memory.free(IcSite, sites);
    const slots = try fb.memory.alloc(ic.Slot, site_count);
    errdefer fb.memory.free(ic.Slot, slots);
    @memset(slots, .{});
    fb.ic_site_ids = site_ids;
    fb.ic_sites = sites;
    fb.ic_slots = slots;
}

pub fn functionBytecodeIcSlotForPc(fb: *const FunctionBytecode, site_pc: usize) ?*ic.Slot {
    return lookupIcSlotForPc(fb.ic_slots, fb.ic_site_ids, fb.ic_sites, site_pc);
}

fn lookupIcSlotForPc(ic_slots: []const ic.Slot, ic_site_ids: []const usize, ic_sites: []const IcSite, site_pc: usize) ?*ic.Slot {
    if (ic_site_ids.len != 0) {
        if (site_pc >= ic_site_ids.len) return null;
        const site_id = ic_site_ids[site_pc];
        if (site_id == std.math.maxInt(usize) or site_id >= ic_slots.len) return null;
        return @constCast(&ic_slots[site_id]);
    }
    const site = findIcSite(ic_sites, site_pc) orelse return null;
    if (site.slot_index >= ic_slots.len) return null;
    return @constCast(&ic_slots[site.slot_index]);
}

fn opcodeHasOwnDataIc(op_id: u8) bool {
    return op_id == opcode.op.get_var or
        op_id == opcode.op.get_var_undef or
        op_id == opcode.op.put_var or
        op_id == opcode.op.get_field or
        op_id == opcode.op.get_field2 or
        op_id == opcode.op.put_field;
}

fn bytesMayContainEvalCall(bytes: []const u8) bool {
    return std.mem.indexOfScalar(u8, bytes, opcode.op.eval) != null or
        std.mem.indexOfScalar(u8, bytes, opcode.op.apply_eval) != null;
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

fn allocateIcSiteIds(mem: *memory.MemoryAccount, code: []const u8) ![]usize {
    const site_ids = try mem.alloc(usize, code.len);
    errdefer mem.free(usize, site_ids);
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

fn allocateIcSites(mem: *memory.MemoryAccount, code: []const u8, site_count: usize) ![]IcSite {
    const sites = try mem.alloc(IcSite, site_count);
    errdefer mem.free(IcSite, sites);
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

pub const destroyFunctionBytecode = function_bytecode.destroyFunctionBytecode;
pub const destroyFromHeader = function_bytecode.destroyFromHeader;

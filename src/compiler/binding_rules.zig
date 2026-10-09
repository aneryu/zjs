//! Binding resolution rules.
//!
//! Mirrors the binding decisions and lowering writers of
//! `resolve_variables` at `quickjs.c`: lexical-chain walk order,
//! closure-source threading, dynamic-environment probe planning, private
//! brand resolution, and the exact byte forms each decision writes.
//!
//! This is a rule library, not a pass. `compiler/resolve_variables.zig`
//! owns the pass structure (block CFG, LabelId operands, transactional
//! output) and calls in here for every binding decision, so there is one
//! definition of QuickJS binding semantics in the tree.

const std = @import("std");
const bytecode = @import("../bytecode.zig");
const atom = @import("../core/atom.zig");
const runtime = @import("../runtime.zig");
const FunctionBytecode = bytecode.FunctionBytecode;
const FunctionDef = bytecode.FunctionDef;
const opcode = bytecode.opcode;
const module = bytecode.module;
const function_bytecode = bytecode.function_bytecode;
const function_def = bytecode.function_def;
const function_mod = bytecode.carrier;
const binding_rules = @This();

const bytecode_function = function_mod;
const function_def_mod = function_def;

const EVAL_SCOPE_HEAD_BIAS: i32 = -function_bytecode.arg_scope_end;
const atom_var_object: atom.Atom = atom.ids.var_object; // "<var>"
const ScopeOperand = struct {
    level: i16,
    /// `opcode.scope_no_dynamic_env_flag`: a store into the variable
    /// environment itself (Annex B's eval copy): no `with` objects, no
    /// same-named eval catch parameter.
    no_dynamic_env: bool,
};

fn decodeScopeOperand(bytes: *const [2]u8) ScopeOperand {
    const raw = std.mem.readInt(u16, bytes, .little);
    if (raw == std.math.maxInt(u16)) {
        return .{ .level = -1, .no_dynamic_env = false };
    }
    return .{
        .level = @intCast(raw & ~opcode.scope_no_dynamic_env_flag),
        .no_dynamic_env = (raw & opcode.scope_no_dynamic_env_flag) != 0,
    };
}

pub const Error = error{
    OutOfMemory,
    InvalidBytecode,
    BytecodeOverflow,
    NoFunctionDef,
    ClosureVarNotFound,
    /// The interrupt handler asked to stop (`resolve_variables` polls).
    Interrupted,
};

fn markEvalCapturedVariables(fd: *function_def_mod.FunctionDef, scope_level: u16) Error!void {
    if (scope_level >= fd.scopes.len) return error.InvalidBytecode;
    var index = fd.scopes[scope_level].first;
    var visited: usize = 0;
    while (index >= 0) {
        if (@as(usize, @intCast(index)) >= fd.vars.len or visited >= fd.vars.len) {
            return error.InvalidBytecode;
        }
        visited += 1;
        const local_index: usize = @intCast(index);
        try fd.captureLocal(local_index);
        index = fd.vars[local_index].scope_next;
    }
    if (index != -1 and index != function_bytecode.arg_scope_end) return error.InvalidBytecode;
}

fn encodeEvalScopeHead(fd: *const function_def_mod.FunctionDef, scope_level: u16) Error!u16 {
    if (scope_level >= fd.scopes.len) return error.InvalidBytecode;
    const head = fd.scopes[scope_level].first;
    const encoded = head + EVAL_SCOPE_HEAD_BIAS;
    if (encoded < 0 or encoded > std.math.maxInt(u16)) return error.BytecodeOverflow;
    return @intCast(encoded);
}

/// The FunctionDef parent relation is borrowed and intentionally has no
/// arbitrary nesting cap.  Floyd's walk makes both the production proof
/// and standalone fallback fail closed on a synthetic parent cycle without
/// allocating a visited set.
fn validateFunctionDefParentChain(start: *function_def_mod.FunctionDef) error{InvalidBytecode}!void {
    var slow: ?*function_def_mod.FunctionDef = start;
    var fast: ?*function_def_mod.FunctionDef = start;
    while (true) {
        slow = if (slow) |node| node.parent else return;
        fast = if (fast) |node| node.parent else return;
        fast = if (fast) |node| node.parent else return;
        if (slow == fast) return error.InvalidBytecode;
    }
}

const ScopeLinkProof = enum(u2) {
    none,
    current,
    tree,
};

/// JSContext for variable resolution.
pub const JSContext = struct {
    function: *bytecode_function.Bytecode,
    atoms: *atom.AtomTable,
    /// Optional FunctionDef driving local-slot lookup. When non-null,
    /// `resolve_variables` lowers `scope_get_var` / `scope_put_var` to
    /// local, closure, or QuickJS-style global closure-var references.
    function_def: ?*function_def_mod.FunctionDef = null,
    /// Advanced only by structural validation, never by mutable FunctionDef
    /// lifecycle state.  Current-scope lookup needs `.current`; the first
    /// actual parent miss upgrades it to `.tree` before ancestor links are
    /// consumed.
    scope_link_proof: ScopeLinkProof = .none,
    pub fn initWithFunctionDef(
        function: *bytecode_function.Bytecode,
        fd: *function_def_mod.FunctionDef,
    ) JSContext {
        return .{
            .function = function,
            .atoms = function.atoms,
            .function_def = fd,
        };
    }

    /// Establish the no-allocation topology proof consumed by the V2-only
    /// resolver specialization.  The current FunctionDef is always proven
    /// at `run` entry. Ancestors are proven lazily on the first real parent
    /// miss; the active finalizer walk shares these proofs across siblings
    /// until mutation. Standalone calls retain no proof between runs.
    pub fn proveScopeLinksForResolution(self: *JSContext) Error!void {
        self.scope_link_proof = .none;
        const fd = self.function_def orelse return error.NoFunctionDef;
        fd.validateFinalScopeLinks() catch return error.InvalidBytecode;
        self.scope_link_proof = .current;
    }

    fn proveParentScopeLinksForResolution(self: *JSContext) Error!void {
        if (self.scope_link_proof == .tree) return;
        if (self.scope_link_proof != .current) return error.InvalidBytecode;
        const fd = self.function_def orelse return error.NoFunctionDef;
        try validateFunctionDefParentChain(fd);
        var maybe_parent = fd.parent;
        while (maybe_parent) |parent| {
            parent.proveAncestorScopeLinks() catch return error.InvalidBytecode;
            maybe_parent = parent.parent;
        }
        self.scope_link_proof = .tree;
    }
};

fn fclosureEncodingSize(cpool_idx: u32) usize {
    return if (cpool_idx <= std.math.maxInt(u8)) 2 else 5;
}

fn emitFClosure(output: []u8, out_idx: *usize, idx: u32) error{InvalidBytecode}!void {
    if (idx <= std.math.maxInt(u8)) {
        if (out_idx.* + 2 > output.len) return error.InvalidBytecode;
        output[out_idx.*] = opcode.op.fclosure8;
        output[out_idx.* + 1] = @intCast(idx);
        out_idx.* += 2;
        return;
    }
    if (out_idx.* + 5 > output.len) return error.InvalidBytecode;
    output[out_idx.*] = opcode.op.fclosure;
    std.mem.writeInt(u32, output[out_idx.* + 1 ..][0..4], idx, .little);
    out_idx.* += 5;
}

/// Maps a scope_* var opcode to its global-form counterpart (3-byte
/// var_ref form). Used when the variable doesn't resolve to a local
/// slot in `function_def.vars`. `scope_put_var_init` lowers to
/// `put_var_init` (initialise-once binding for top-level
/// `let`/`const`); the others use their plain counterparts.
fn lowerScopeVarOpGlobal(op_id: u8) u8 {
    return switch (op_id) {
        opcode.op.scope_get_var, opcode.op.scope_get_var_checkthis => opcode.op.get_var,
        opcode.op.scope_put_var => opcode.op.put_var,
        opcode.op.scope_get_var_undef => opcode.op.get_var_undef,
        opcode.op.scope_put_var_init => opcode.op.put_var_init,
        else => unreachable,
    };
}

/// Maps a scope_* var opcode to its local-form counterpart (3-byte
/// loc form). `scope_get_var_undef` collapses to `get_loc` since
/// locals are always defined (frame allocates them up front, default
/// value is `undefined`). `scope_put_var_init` collapses to
/// `put_loc` for the local case. The TDZ-aware `put_loc_check_init`
/// variant remains open for broader lexical-initialization coverage.
fn lowerScopeVarOpLocal(op_id: u8) u8 {
    return switch (op_id) {
        opcode.op.scope_get_var, opcode.op.scope_get_var_checkthis => opcode.op.get_loc,
        opcode.op.scope_put_var => opcode.op.put_loc,
        opcode.op.scope_get_var_undef => opcode.op.get_loc,
        opcode.op.scope_put_var_init => opcode.op.put_loc,
        else => unreachable,
    };
}

/// Shortest-form local-slot opcode triple. Mirrors `put_short_code`:
/// - `idx ∈ [0, 4)` → 1-byte short forms `get_loc0..3` / `put_loc0..3`
///   / `set_loc0..3` (idx encoded in opcode id).
/// - `idx ∈ [4, 256)` → 2-byte `get_loc8` / `put_loc8` / `set_loc8`
///   (1-byte op + u8 idx).
/// - `idx ∈ [256, 65536)` → 3-byte `get_loc` / `put_loc` / `set_loc`
///   (1-byte op + u16 idx).
const ShortLocForm = struct {
    /// Selected opcode id.
    op_id: u8,
    /// Total byte length (1, 2, or 3) the encoder will produce.
    size: u8,
    /// Operand byte width (0 for short, 1 for u8, 2 for u16).
    operand_size: u8,
};

fn selectShortLoc(base_op: u8, idx: u16) ShortLocForm {
    if (idx < 4) {
        const short_base: u8 = switch (base_op) {
            opcode.op.get_loc => opcode.op.get_loc0,
            opcode.op.put_loc => opcode.op.put_loc0,
            opcode.op.set_loc => opcode.op.set_loc0,
            else => unreachable,
        };
        return .{
            .op_id = short_base + @as(u8, @intCast(idx)),
            .size = 1,
            .operand_size = 0,
        };
    }
    if (idx < 256) {
        const op_id: u8 = switch (base_op) {
            opcode.op.get_loc => opcode.op.get_loc8,
            opcode.op.put_loc => opcode.op.put_loc8,
            opcode.op.set_loc => opcode.op.set_loc8,
            else => unreachable,
        };
        return .{ .op_id = op_id, .size = 2, .operand_size = 1 };
    }
    return .{ .op_id = base_op, .size = 3, .operand_size = 2 };
}

fn shortOpcodesEnabled(ctx: *const JSContext) bool {
    const fd = ctx.function_def orelse return false;
    return fd.use_short_opcodes;
}

fn selectLocForm(ctx: *const JSContext, base_op: u8, idx: u16) ShortLocForm {
    if (shortOpcodesEnabled(ctx)) return selectShortLoc(base_op, idx);
    return .{ .op_id = base_op, .size = 3, .operand_size = 2 };
}

pub fn closureVarIsRuntimeVarRef(cv: function_def_mod.ClosureVar) bool {
    return switch (cv.closureType()) {
        // `.global` is the sole atom-only carrier. GLOBAL_REF and
        // GLOBAL_DECL both own/alias a real VarRef cell at construction;
        // whether ordinary access stays dynamic is a separate question
        // answered by closureVarSourceIsDynamicGlobal below.
        .global => false,
        .local, .arg, .ref, .global_ref, .global_decl, .module_decl, .module_import => true,
    };
}

fn closureVarSourceIsDynamicGlobal(fd: *const function_def_mod.FunctionDef, start_idx: usize) bool {
    var owner = fd;
    var idx = start_idx;
    var hops: usize = 0;
    while (idx < owner.closure_var.len and hops < 64) : (hops += 1) {
        const cv = owner.closure_var[idx];
        switch (cv.closureType()) {
            .global, .global_ref, .global_decl => return true,
            .ref => {
                const parent = owner.parent orelse return false;
                owner = parent;
                idx = cv.var_idx;
            },
            .module_decl => return false,
            .local, .arg, .module_import => return false,
        }
    }
    return false;
}

fn lookupClosureVar(ctx: *const JSContext, atom_id: atom.Atom) ?u16 {
    const fd = ctx.function_def orelse return null;
    for (fd.closure_var, 0..) |cv, idx| {
        if (!closureVarIsRuntimeVarRef(cv)) continue;
        if (closureVarSourceIsDynamicGlobal(fd, idx)) continue;
        if (cv.var_name == atom_id) return @intCast(idx);
    }
    // resolveBindingTopology/get_closure_var must have installed an entry
    // in the *current* function before lowering begins.  A parent closure,
    // local, or argument index is in a different index space and can never
    // be emitted as this function's var-ref operand (quickjs.c).
    // The former ancestor fallback merely hid a missing
    // topology event and could address an unrelated current row.
    return null;
}

fn lookupGlobalClosureVar(ctx: *const JSContext, atom_id: atom.Atom) Error!?u16 {
    const fd = ctx.function_def orelse return null;
    var rows = try fd.closureRowsNamed(atom_id);
    while (rows.next()) |idx| switch (fd.closure_var[idx].closureType()) {
        .global, .global_ref, .global_decl, .module_decl, .module_import => return idx,
        else => {},
    };
    return null;
}

fn addOrFindClosureSource(
    fd: *function_def_mod.FunctionDef,
    closure_type: function_def_mod.ClosureType,
    source_idx: u16,
    source: function_def_mod.ClosureVar,
) Error!u16 {
    // QuickJS get_closure_var identity is exactly (closure_type,var_idx);
    // the atom is lookup metadata only.
    if (try fd.findClosureSource(closure_type, source_idx)) |idx| return idx;
    const idx = try fd.addClosureVar(.{
        .closure_type = closure_type,
        .is_lexical = source.isLexical(),
        .is_const = source.isConst(),
        .var_kind = source.varKind(),
        .var_idx = source_idx,
        .var_name = source.var_name,
    });
    // Closure-variable indices are u16 operands: a limit, not corruption.
    if (idx < 0) return error.InvalidBytecode;
    if (idx > std.math.maxInt(u16)) return error.BytecodeOverflow;
    return @intCast(idx);
}

/// QuickJS get_closure_var recursion for a source already owned by an
/// ancestor. Each intermediate function receives one identity-deduped
/// row pointing at its direct parent; global sources retain GLOBAL_REF.
pub fn threadClosureSource(
    target: *function_def_mod.FunctionDef,
    source_owner: *function_def_mod.FunctionDef,
    source_idx: u16,
    source: function_def_mod.ClosureVar,
    source_type: function_def_mod.ClosureType,
) Error!u16 {
    const parent = target.parent orelse return error.InvalidBytecode;
    const direct_source = parent == source_owner;
    const parent_idx = if (direct_source)
        source_idx
    else
        try threadClosureSource(parent, source_owner, source_idx, source, source_type);
    const target_type: function_def_mod.ClosureType = if (direct_source)
        source_type
    else if (source_type == .global_ref)
        .global_ref
    else
        .ref;
    switch (target_type) {
        .local, .arg, .ref, .global_ref => {},
        .global, .global_decl, .module_decl, .module_import => return error.InvalidBytecode,
    }
    return addOrFindClosureSource(target, target_type, parent_idx, source);
}

fn ensureGlobalClosureVar(ctx: *JSContext, atom_id: atom.Atom) Error!u16 {
    if (try lookupGlobalClosureVar(ctx, atom_id)) |idx| return idx;
    const fd = ctx.function_def orelse return error.NoFunctionDef;

    // resolve_scope_var creates an unresolved ordinary-global carrier in
    // the eval root, even when the first demand comes from a descendant;
    // get_closure_var then threads GLOBAL_REF rows back down. This makes
    // every function share one root identity and, because children are
    // finalized first, preserves child-demand-before-parent-demand order.
    var root = fd;
    while (!root.is_eval) root = root.parent orelse break;

    var root_idx: ?u16 = null;
    var rows = try root.closureRowsNamed(atom_id);
    while (rows.next()) |idx| switch (root.closure_var[idx].closureType()) {
        .global, .global_ref, .global_decl => {
            root_idx = idx;
            break;
        },
        else => {},
    };
    if (root_idx == null) {
        const idx = try root.addClosureVar(.{
            .closure_type = .global,
            .is_lexical = false,
            .is_const = false,
            .var_kind = .normal,
            .var_idx = 0,
            .var_name = atom_id,
        });
        if (idx < 0 or idx > std.math.maxInt(u16)) return error.BytecodeOverflow;
        root_idx = @intCast(idx);
    }

    if (root == fd) return root_idx.?;
    const source = root.closure_var[root_idx.?];
    return threadClosureSource(fd, root, root_idx.?, source, .global_ref);
}

fn emitGlobalVarOp(ctx: *JSContext, output: []u8, out_idx: *usize, op_id: u8, atom_id: atom.Atom) Error!void {
    if (out_idx.* + 3 > output.len) return error.InvalidBytecode;
    const ref_idx = (try lookupGlobalClosureVar(ctx, atom_id)) orelse return error.ClosureVarNotFound;
    output[out_idx.*] = op_id;
    std.mem.writeInt(u16, output[out_idx.* + 1 ..][0..2], ref_idx, .little);
    out_idx.* += 3;
}

fn lookupTopLevelModuleLexicalClosureVar(ctx: *const JSContext, atom_id: atom.Atom, scope_level: i32) Error!?u16 {
    if (scope_level != 0) return null;
    const fd = ctx.function_def orelse return null;
    var rows = try fd.closureRowsNamed(atom_id);
    while (rows.next()) |idx| {
        const cv = fd.closure_var[idx];
        if ((cv.closureType() == .module_decl or cv.closureType() == .global_decl) and cv.isLexical()) return idx;
    }
    return null;
}

fn preferTopLevelModuleClassBinding(ctx: *const JSContext, atom_id: atom.Atom, loc_idx: u16) Error!?u16 {
    const fd = ctx.function_def orelse return null;
    if (loc_idx >= fd.vars.len) return null;
    const vd = fd.vars[loc_idx];
    if (vd.var_name != atom_id or vd.scope_level != 0 or !vd.is_lexical or !vd.is_const) return null;
    var rows = try fd.closureRowsNamed(atom_id);
    while (rows.next()) |idx| {
        const cv = fd.closure_var[idx];
        if (cv.closureType() == .module_decl and cv.isLexical() and !cv.isConst()) return idx;
    }
    return null;
}

fn closureVarKind(ctx: *const JSContext, idx: u16) function_def_mod.VarKind {
    const fd = ctx.function_def orelse return .normal;
    if (idx >= fd.closure_var.len) return .normal;
    return fd.closure_var[idx].varKind();
}

/// qjs resolve_scope_var `has_idx`: a write
/// (`OP_scope_put_var`) or reference capture (`OP_scope_make_ref`) that
/// resolves to a const closure variable compiles to
/// `OP_throw_error <name> JS_THROW_VAR_RO` instead of a store. The global
/// families are exempt — qjs routes them to `has_global_idx`
/// which has no such check; global const writes stay on
/// the runtime global-lexical-cell path (TDZ ReferenceError precedence,
/// OP_put_var quickjs.c).
///
/// This compile-time throw is what makes module import bindings read-only:
/// imports register `is_const` at parse time (add_import quickjs.c)
/// and their frame slot is a direct alias of the exporting module's cell
/// (js_inner_module_linking quickjs.c) — the shared cell
/// itself carries no const flag, so the write must never reach it.
/// A write to an immutable binding: SetMutableBinding (§9.1.1.1.5) throws a
/// ReferenceError while the binding is uninitialized and a TypeError after,
/// so a binding with a TDZ is read with the checked form first.
const ReadOnlyWrite = struct {
    /// `get_loc_check` / `get_var_ref_check` of `tdz_idx`, or null when the
    /// binding has no TDZ.
    tdz_op: ?u8 = null,
    tdz_idx: u16 = 0,

    fn size(self: ReadOnlyWrite) usize {
        return throw_error_instr_size + @as(usize, if (self.tdz_op != null) 4 else 0);
    }
};

fn closureVarReadOnlyWrite(ctx: *const JSContext, ref_idx: u16) ?ReadOnlyWrite {
    const fd = ctx.function_def orelse return null;
    if (ref_idx >= fd.closure_var.len) return null;
    const base = closureVarConstWriteBase(fd, ref_idx) orelse return null;
    // An import is immutable but never observed in its exporter's TDZ here.
    if (base == .module_import) return .{};
    return .{ .tdz_op = opcode.op.get_var_ref_check, .tdz_idx = ref_idx };
}

fn localReadOnlyWrite(ctx: *const JSContext, loc_idx: u16) ?ReadOnlyWrite {
    if (!localWriteThrowsReadOnly(ctx, loc_idx)) return null;
    return .{ .tdz_op = opcode.op.get_loc_check, .tdz_idx = loc_idx };
}

/// The closure type at the base of a const row's capture chain, or null when
/// a write through the row does not throw.
fn closureVarConstWriteBase(start_fd: *const function_def_mod.FunctionDef, start_idx: u16) ?function_def_mod.ClosureType {
    var fd = start_fd;
    var cv = fd.closure_var[start_idx];
    if (!cv.isConst()) return null;
    // Follow the capture chain to its base closure var. The finalized
    // resolver threads local/module sources through descendants as plain
    // `.ref` rows, while eval-root GLOBAL families are re-derived as
    // `.global_ref`, matching resolve_scope_var.
    // Const-write treatment is therefore decided by the base identity,
    // not by the immediate forwarding row alone.
    var hops: usize = 0;
    while ((cv.closureType() == .ref or cv.closureType() == .global_ref) and hops < 64) : (hops += 1) {
        const parent = fd.parent orelse break;
        if (cv.var_idx >= parent.closure_var.len) break;
        fd = parent;
        cv = parent.closure_var[cv.var_idx];
    }
    return switch (cv.closureType()) {
        .global, .global_decl, .global_ref => null,
        .local, .arg, .ref, .module_decl, .module_import => |base| base,
    };
}

/// `OP_throw_error <atom:u32> <type:u8>` — 6 bytes, one atom operand.
const throw_error_instr_size: usize = 6;
const JS_THROW_VAR_RO: u8 = 0;
const JS_THROW_VAR_REDECL: u8 = 1;

/// Cursor over one reserved code span and its atom operands.
const AtomWriter = struct {
    code: []u8 = &.{},
    atoms: []atom.Atom = &.{},
    idx: usize = 0,
    atom_idx: usize = 0,
    /// Null-output sizing: advance the cursors and skip the stores. The
    /// write path leaves this false and fills the reserved slices.
    counting: bool = false,

    pub fn op(self: *AtomWriter, op_id: u8) void {
        if (!self.counting) self.code[self.idx] = op_id;
        self.idx += 1;
    }

    pub fn @"u16"(self: *AtomWriter, value: u16) void {
        if (!self.counting) std.mem.writeInt(u16, self.code[self.idx..][0..2], value, .little);
        self.idx += 2;
    }

    pub fn atomOp(self: *AtomWriter, op_id: u8, atom_id: atom.Atom) void {
        if (!self.counting) {
            self.code[self.idx] = op_id;
            std.mem.writeInt(u32, self.code[self.idx + 1 ..][0..4], atom_id.raw(), .little);
            self.atoms[self.atom_idx] = atom_id;
        }
        self.idx += 5;
        self.atom_idx += 1;
    }

    pub fn throwVar(self: *AtomWriter, atom_id: atom.Atom, error_type: u8) void {
        if (!self.counting) {
            self.code[self.idx] = opcode.op.throw_error;
            std.mem.writeInt(u32, self.code[self.idx + 1 ..][0..4], atom_id.raw(), .little);
            self.code[self.idx + 5] = error_type;
            self.atoms[self.atom_idx] = atom_id;
        }
        self.idx += throw_error_instr_size;
        self.atom_idx += 1;
    }
};

fn writeThrowVarReadOnly(w: *AtomWriter, atom_id: atom.Atom) void {
    w.throwVar(atom_id, JS_THROW_VAR_RO);
}

fn writeReadOnlyWrite(w: *AtomWriter, atom_id: atom.Atom, write: ReadOnlyWrite) void {
    if (write.tdz_op) |op_id| {
        w.op(op_id);
        w.u16(write.tdz_idx);
        w.op(opcode.op.drop);
    }
    writeThrowVarReadOnly(w, atom_id);
}

fn lowerScopeVarOpForClosure(ctx: *const JSContext, atom_id: atom.Atom, ref_idx: u16, op_id: u8) u8 {
    var ref_op = lowerScopeVarOpClosure(op_id);
    const fd = ctx.function_def orelse return ref_op;
    if (ref_idx >= fd.closure_var.len) return ref_op;
    const resolved = fd.closure_var[ref_idx];
    // QuickJS resolve_scope_var keeps BindThisValue's initialize-once
    // guard after `this` has escaped into a closure.
    // The parser intentionally carries only name+scope here; choose the
    // checked final opcode now that this function's exact ref index exists.
    if (op_id == opcode.op.scope_put_var_init and atom_id == atom.ids.this_) {
        ref_op = opcode.op.put_var_ref_check_init;
    }
    // qjs has_idx reads s->closure_var[idx] directly after get_closure_var
    // selected that exact identity. Do not search
    // the same atom through the current and parent functions again: two
    // same-name closure rows may have different lexical metadata, and the
    // resolved ref_idx is the authoritative row.
    if ((op_id == opcode.op.scope_get_var or op_id == opcode.op.scope_get_var_undef) and
        (resolved.varKind() == .function_decl or !resolved.isLexical()))
    {
        ref_op = opcode.op.get_var_ref;
    }
    if (op_id == opcode.op.scope_put_var and !resolved.isLexical()) {
        ref_op = opcode.op.put_var_ref;
    }
    return ref_op;
}

test "resolved closure identity owns lexical opcode selection" {
    const rt = try runtime.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const name = try rt.internAtom("resolved-closure-opcode-selection");
    const binding = try rt.internAtom("same-name-closure");

    var fd = function_def_mod.FunctionDef.init(rt.nativeAllocator(), rt.nativeAllocator(), rt.atoms, name);
    defer fd.deinit(rt);
    _ = try fd.addClosureVar(.{
        .closure_type = .local,
        .is_lexical = false,
        .is_const = false,
        .var_kind = .normal,
        .var_idx = 0,
        .var_name = binding,
    });
    const lexical_idx = try fd.addClosureVar(.{
        .closure_type = .local,
        .is_lexical = true,
        .is_const = false,
        .var_kind = .normal,
        .var_idx = 1,
        .var_name = binding,
    });

    var bc = bytecode_function.Bytecode.init(rt.nativeAllocator(), rt.nativeAllocator(), rt.atoms, name);
    defer bc.deinit();
    const ctx = JSContext.initWithFunctionDef(&bc, &fd);
    try std.testing.expectEqual(
        opcode.op.get_var_ref_check,
        lowerScopeVarOpForClosure(&ctx, binding, @intCast(lexical_idx), opcode.op.scope_get_var),
    );
    try std.testing.expectEqual(
        opcode.op.get_var_ref_check,
        lowerScopeVarOpForClosure(&ctx, binding, @intCast(lexical_idx), opcode.op.scope_get_var_undef),
    );
    try std.testing.expectEqual(
        opcode.op.get_var_ref,
        lowerScopeVarOpForClosure(&ctx, binding, 0, opcode.op.scope_get_var_undef),
    );
    try std.testing.expectEqual(
        opcode.op.put_var_ref_check,
        lowerScopeVarOpForClosure(&ctx, binding, @intCast(lexical_idx), opcode.op.scope_put_var),
    );
}

const PrivateFieldResolution = struct {
    idx: u16,
    is_ref: bool,
    var_kind: function_def_mod.VarKind,
};

const PrivateLookup = enum {
    /// The private name itself: a field, method, or accessor pair.
    name,
    /// The `<set>` companion binding of a private accessor.
    setter,
};

/// Find a private binding visible at `scope_level`: the enclosing class
/// scopes of this function first, then its captured closure variables.
fn resolvePrivate(ctx: *const JSContext, atom_id: atom.Atom, scope_level: i32, comptime lookup: PrivateLookup) ?PrivateFieldResolution {
    const fd = ctx.function_def orelse return null;
    const Match = struct {
        fn test_(c: *const JSContext, private_atom: atom.Atom, name: atom.Atom, kind: function_def_mod.VarKind) bool {
            return switch (lookup) {
                .name => name == private_atom and isPrivateVarKind(kind),
                .setter => kind == .private_setter and isPrivateSetterCompanionName(c, private_atom, name),
            };
        }
    };

    if (scope_level >= 0 and @as(usize, @intCast(scope_level)) < fd.scopes.len) {
        var idx = fd.scopes[@intCast(scope_level)].first;
        var visited: usize = 0;
        while (idx >= 0) {
            if (@as(usize, @intCast(idx)) >= fd.vars.len or visited >= fd.vars.len) return null;
            visited += 1;
            const vd = fd.vars[@intCast(idx)];
            if (Match.test_(ctx, atom_id, vd.var_name, vd.var_kind)) {
                return .{ .idx = @intCast(idx), .is_ref = false, .var_kind = vd.var_kind };
            }
            idx = vd.scope_next;
        }
    }

    for (fd.closure_var, 0..) |cv, idx| {
        if (Match.test_(ctx, atom_id, cv.var_name, cv.varKind())) {
            return .{ .idx = @intCast(idx), .is_ref = true, .var_kind = cv.varKind() };
        }
    }
    return null;
}

fn isPrivateVarKind(kind: function_def_mod.VarKind) bool {
    return switch (kind) {
        .private_field,
        .private_method,
        .private_getter,
        .private_setter,
        .private_getter_setter,
        => true,
        else => false,
    };
}

fn isPrivateSetterCompanionName(ctx: *const JSContext, private_atom: atom.Atom, candidate_atom: atom.Atom) bool {
    const private_name = ctx.atoms.name(private_atom) orelse return false;
    const candidate_name = ctx.atoms.name(candidate_atom) orelse return false;
    const suffix = "<set>";
    return candidate_name.len == private_name.len + suffix.len and
        std.mem.eql(u8, candidate_name[0..private_name.len], private_name) and
        std.mem.eql(u8, candidate_name[private_name.len..], suffix);
}

fn writePrivateAccessor(ctx: *const JSContext, w: *AtomWriter, res: PrivateFieldResolution) void {
    if (res.is_ref) {
        const form = selectVarRefForm(ctx, opcode.op.get_var_ref, res.idx);
        w.op(form.op_id);
        switch (form.operand_size) {
            0 => {},
            2 => w.u16(res.idx),
            else => unreachable,
        }
        return;
    }

    const form = selectLocForm(ctx, opcode.op.get_loc, res.idx);
    w.op(form.op_id);
    switch (form.operand_size) {
        0 => {},
        1 => w.op(@intCast(res.idx)),
        2 => w.u16(res.idx),
        else => unreachable,
    }
}

fn writePrivateCallMethod(w: *AtomWriter, argc: u16) void {
    w.op(opcode.op.call_method);
    w.u16(argc);
}

fn writeLoweredPrivateField(
    ctx: *const JSContext,
    w: *AtomWriter,
    op_id: u8,
    atom_id: atom.Atom,
    scope_level: i32,
    res: PrivateFieldResolution,
) !void {
    switch (op_id) {
        opcode.op.scope_get_private_field, opcode.op.scope_get_private_field2 => switch (res.var_kind) {
            .private_field => {
                if (op_id == opcode.op.scope_get_private_field2) w.op(opcode.op.dup);
                writePrivateAccessor(ctx, w, res);
                w.op(opcode.op.get_private_field);
            },
            .private_method => {
                writePrivateAccessor(ctx, w, res);
                w.op(opcode.op.check_brand);
                if (op_id == opcode.op.scope_get_private_field) w.op(opcode.op.nip);
            },
            .private_getter, .private_getter_setter => {
                if (op_id == opcode.op.scope_get_private_field2) w.op(opcode.op.dup);
                writePrivateAccessor(ctx, w, res);
                w.op(opcode.op.check_brand);
                writePrivateCallMethod(w, 0);
            },
            .private_setter => w.throwVar(atom_id, opcode.throw_error_private_without_getter),
            else => return error.ClosureVarNotFound,
        },
        opcode.op.scope_put_private_field => switch (res.var_kind) {
            .private_field => {
                writePrivateAccessor(ctx, w, res);
                w.op(opcode.op.put_private_field);
            },
            .private_method, .private_getter => writeThrowVarReadOnly(w, atom_id),
            .private_setter, .private_getter_setter => {
                const setter = resolvePrivate(ctx, atom_id, scope_level, .setter) orelse return error.ClosureVarNotFound;
                writePrivateAccessor(ctx, w, setter);
                w.op(opcode.op.swap);
                w.op(opcode.op.ext0);
                w.op(opcode.ext0_sub.rot3r);
                w.op(opcode.op.check_brand);
                w.op(opcode.op.rot3l);
                writePrivateCallMethod(w, 1);
                w.op(opcode.op.drop);
            },
            else => return error.ClosureVarNotFound,
        },
        opcode.op.scope_in_private_field => {
            // A setter-only accessor's function lives in its `<set>` companion;
            // the plain binding is never initialized.
            const element = if (res.var_kind == .private_setter)
                resolvePrivate(ctx, atom_id, scope_level, .setter) orelse return error.ClosureVarNotFound
            else
                res;
            writePrivateAccessor(ctx, w, element);
            w.op(opcode.op.private_in);
        },
        else => unreachable,
    }
}

/// Ordinary lexical vars get their TDZ bit re-armed on scope entry.
/// Function declarations take the other QuickJS OP_enter_scope arm and
/// are initialized from their VarDef.func_pool_idx instead.
fn varNeedsTdzRearm(vd: function_def_mod.VarDef) bool {
    return vd.is_lexical and (vd.var_kind == .normal or isPrivateVarKind(vd.var_kind));
}

fn varNeedsScopeFunctionInit(vd: function_def_mod.VarDef) bool {
    return vd.is_lexical and vd.func_pool_idx != null and
        (vd.var_kind == .function_decl or vd.var_kind == .new_function_decl);
}

/// Lower `enter_scope <scope>`. Mirrors the QuickJS `OP_enter_scope` case:
/// initialize only the bindings declared by this exact scope. Captured cells
/// are detached exclusively by the corresponding leave marker. With a null
/// `output` only `out_idx` advances, so sizing and writing share one walk.
fn lowerEnterScope(ctx: *const JSContext, output: ?[]u8, out_idx: *usize, scope: i32) Error!void {
    const fd = ctx.function_def orelse return;
    if (scope < 0 or @as(usize, @intCast(scope)) >= fd.scopes.len) return;
    // A fresh binding per scope entry (§14.2.2): a closure that captured the
    // previous entry's binding keeps it even when that entry was left by an
    // exception, which skips the leave-scope close. Detach every captured
    // slot first: the block-function closures created below capture the
    // new bindings. The function body scope is entered once per call.
    var idx = if (scope > fd.body_scope) fd.scopes[@intCast(scope)].first else -1;
    while (idx >= 0 and @as(usize, @intCast(idx)) < fd.vars.len) {
        const vd = fd.vars[@intCast(idx)];
        if (vd.scope_level != scope) break;
        if (enterScopeRefreshesVar(fd, idx) and vd.is_captured) {
            writeLocOp3(output, out_idx, opcode.op.close_loc, @intCast(idx));
        }
        idx = vd.scope_next;
    }
    idx = fd.scopes[@intCast(scope)].first;
    while (idx >= 0 and @as(usize, @intCast(idx)) < fd.vars.len) {
        const vd = fd.vars[@intCast(idx)];
        if (vd.scope_level != scope) break;
        const loc_idx: u16 = @intCast(idx);
        if (fd.arguments_arg_idx == null or idx != fd.arguments_arg_idx.?) {
            if (varNeedsScopeFunctionInit(vd)) {
                const form = selectLocForm(ctx, opcode.op.put_loc, loc_idx);
                if (output) |out| {
                    try emitFClosure(out, out_idx, vd.func_pool_idx.?);
                    writeSelectedLocForm(out, out_idx, form, loc_idx);
                } else {
                    out_idx.* += fclosureEncodingSize(vd.func_pool_idx.?) + form.size;
                }
            } else if (varNeedsTdzRearm(vd)) {
                writeLocOp3(output, out_idx, opcode.op.set_loc_uninitialized, loc_idx);
            }
        }
        idx = vd.scope_next;
    }
}

fn enterScopeRefreshesVar(fd: *const function_def_mod.FunctionDef, idx: i32) bool {
    if (fd.arguments_arg_idx != null and idx == fd.arguments_arg_idx.?) return false;
    const vd = fd.vars[@intCast(idx)];
    return varNeedsScopeFunctionInit(vd) or varNeedsTdzRearm(vd);
}

/// Lower QuickJS `OP_leave_scope`: detach each captured local declared by
/// exactly this scope. The inherited tail belongs to enclosing scopes and
/// must not be closed here. A null `output` only advances `out_idx`.
fn lowerLeaveScope(ctx: *const JSContext, output: ?[]u8, out_idx: *usize, scope: i32) void {
    const fd = ctx.function_def orelse return;
    if (scope < 0 or @as(usize, @intCast(scope)) >= fd.scopes.len) return;
    var idx = fd.scopes[@intCast(scope)].first;
    while (idx >= 0 and @as(usize, @intCast(idx)) < fd.vars.len) {
        const vd = fd.vars[@intCast(idx)];
        if (vd.scope_level != scope) break;
        if (vd.is_captured) writeLocOp3(output, out_idx, opcode.op.close_loc, @intCast(idx));
        idx = vd.scope_next;
    }
}

/// A 3-byte `op u16` local-slot instruction; a null `output` only sizes it.
fn writeLocOp3(output: ?[]u8, out_idx: *usize, op: u8, loc_idx: u16) void {
    if (output) |out| {
        out[out_idx.*] = op;
        std.mem.writeInt(u16, out[out_idx.* + 1 ..][0..2], loc_idx, .little);
    }
    out_idx.* += 3;
}

fn lowerScopeVarOpClosure(op_id: u8) u8 {
    return switch (op_id) {
        // qjs 33352-33376: `scope_get_var` and `scope_get_var_undef`
        // share the lexical → `get_var_ref_check` rewrite. `typeof`
        // of an uninitialized import/let must still throw TDZ.
        opcode.op.scope_get_var, opcode.op.scope_get_var_checkthis, opcode.op.scope_get_var_undef => opcode.op.get_var_ref_check,
        opcode.op.scope_put_var => opcode.op.put_var_ref_check,
        opcode.op.scope_put_var_init => opcode.op.put_var_ref,
        else => unreachable,
    };
}

fn selectShortVarRef(base_op: u8, idx: u16) ShortLocForm {
    if (idx < 4) {
        const short_base: u8 = switch (base_op) {
            opcode.op.get_var_ref => opcode.op.get_var_ref0,
            opcode.op.put_var_ref => opcode.op.put_var_ref0,
            opcode.op.set_var_ref => opcode.op.set_var_ref0,
            else => return .{ .op_id = base_op, .size = 3, .operand_size = 2 },
        };
        return .{
            .op_id = short_base + @as(u8, @intCast(idx)),
            .size = 1,
            .operand_size = 0,
        };
    }
    return .{ .op_id = base_op, .size = 3, .operand_size = 2 };
}

fn selectVarRefForm(ctx: *const JSContext, base_op: u8, idx: u16) ShortLocForm {
    if (shortOpcodesEnabled(ctx)) return selectShortVarRef(base_op, idx);
    return .{ .op_id = base_op, .size = 3, .operand_size = 2 };
}

fn selectShortArg(base_op: u8, idx: u16) ShortLocForm {
    if (idx < 4) {
        const short_base: u8 = switch (base_op) {
            opcode.op.get_arg => opcode.op.get_arg0,
            opcode.op.put_arg => opcode.op.put_arg0,
            else => unreachable,
        };
        return .{
            .op_id = short_base + @as(u8, @intCast(idx)),
            .size = 1,
            .operand_size = 0,
        };
    }
    return .{ .op_id = base_op, .size = 3, .operand_size = 2 };
}

fn selectArgForm(ctx: *const JSContext, base_op: u8, idx: u16) ShortLocForm {
    if (shortOpcodesEnabled(ctx)) return selectShortArg(base_op, idx);
    return .{ .op_id = base_op, .size = 3, .operand_size = 2 };
}

fn lookupArg(ctx: *const JSContext, atom_id: atom.Atom) ?u16 {
    const fd = ctx.function_def orelse return null;
    const idx = fd.findArg(atom_id);
    if (idx < 0) return null;
    return @intCast(idx);
}

/// QuickJS checks the named function-expression binding after the current
/// scope/var/argument lookup, including while the argument scope is active
/// (resolve_scope_var quickjs.c). That scope deliberately does
/// not link to the body scope, so the ordinary scope walk cannot find the
/// lazily materialized function-name slot for a default initializer.
fn lookupCurrentFunctionName(ctx: *const JSContext, atom_id: atom.Atom) ?u16 {
    const fd = ctx.function_def orelse return null;
    const idx: usize = fd.func_var_idx orelse return null;
    if (idx >= fd.vars.len) return null;
    const vd = fd.vars[idx];
    if (vd.var_name != atom_id or vd.var_kind != .function_name) return null;
    return @intCast(idx);
}

fn lookupCurrentPseudoBinding(ctx: *const JSContext, atom_id: atom.Atom) ?u16 {
    const fd = ctx.function_def orelse return null;
    if (!fd.has_this_binding) return null;
    const maybe_idx: ?u16 = if (atom_id == atom.ids.home_object)
        fd.home_object_var_idx
    else if (atom_id == atom.ids.this_active_func)
        fd.this_active_func_var_idx
    else if (atom_id == atom.ids.new_target)
        fd.new_target_var_idx
    else if (atom_id == atom.ids.this_)
        fd.this_var_idx
    else
        return null;
    const idx = maybe_idx orelse return null;
    if (idx >= fd.vars.len) return null;
    if (fd.vars[idx].var_name != atom_id) return null;
    return idx;
}

fn lowerScopeVarOpArg(op_id: u8) ?u8 {
    return switch (op_id) {
        opcode.op.scope_get_var, opcode.op.scope_get_var_undef, opcode.op.scope_get_var_checkthis => opcode.op.get_arg,
        opcode.op.scope_put_var, opcode.op.scope_put_var_init => opcode.op.put_arg,
        else => null,
    };
}

/// Resolve the local half of QuickJS `resolve_scope_var`: walk the one
/// destructively rebuilt `first/scope_next` chain, then (unless it ends at
/// ARG_SCOPE_END) run newest-first `find_var` over scope-0 rows. Scope 1 is
/// deliberately not made to inherit scope 0 by `js_create_function`.
const ScopeVarLookup = struct {
    local: ?u16 = null,
    argument_environment_only: bool = false,
};

/// Preserve the terminal scope-chain sentinel together with the binding.
/// QuickJS keeps `idx` from the one linked walk and tests ARG_SCOPE_END
/// directly; losing it here used to make V2 walk the same chain again on
/// every miss merely to decide whether formal arguments are visible.
inline fn resolveScopeVarLookupImpl(
    comptime trust_final_scope_links: bool,
    ctx: *const JSContext,
    atom_id: atom.Atom,
    scope_level: i32,
) ScopeVarLookup {
    const fd = ctx.function_def orelse return .{};
    if (scope_level < 0 or @as(usize, @intCast(scope_level)) >= fd.scopes.len) return .{};
    if (comptime trust_final_scope_links) {
        std.debug.assert(ctx.scope_link_proof != .none);
        if (fd.vars.len >= scope_chain_index_threshold) {
            if (indexedScopeVarLookup(fd, atom_id, scope_level)) |found| {
                if (std.debug.runtime_safety) {
                    std.debug.assert(std.meta.eql(found, linkedScopeVarLookup(fd, atom_id, scope_level)));
                }
                return found;
            }
        }
    }
    return linkedScopeVarLookup(fd, atom_id, scope_level);
}

/// Below this many vars the linked walk is cheaper than the name index.
const scope_chain_index_threshold: usize = 64;

/// The linked walk's answer from the (scope, name) index, for final scope
/// links: the chain visits `scope_level`, then its parents while above
/// scope 1, each scope's vars newest first. So the answer is the newest
/// same-name var of the nearest scope on that path: one probe per scope.
/// Null on allocation failure (the caller walks).
fn indexedScopeVarLookup(fd: *function_def_mod.FunctionDef, atom_id: atom.Atom, scope_level: i32) ?ScopeVarLookup {
    var last = scope_level;
    while (true) {
        if (fd.newestVarInScope(last, atom_id) catch return null) |idx| return .{ .local = idx };
        if (last <= 1) break;
        last = fd.scopes[@intCast(last)].parent;
    }
    if (last == 1 and fd.has_parameter_expressions) return .{ .argument_environment_only = true };
    return .{ .local = fd.findFunctionVar(atom_id) };
}

fn linkedScopeVarLookup(fd: *function_def_mod.FunctionDef, atom_id: atom.Atom, scope_level: i32) ScopeVarLookup {
    var idx = fd.scopes[@intCast(scope_level)].first;
    var visited: usize = 0;
    while (idx >= 0) {
        if (@as(usize, @intCast(idx)) >= fd.vars.len or visited >= fd.vars.len) return .{};
        visited += 1;
        const vd = fd.vars[@intCast(idx)];
        if (vd.var_name == atom_id) return .{ .local = @intCast(idx) };
        idx = vd.scope_next;
    }
    if (idx == function_bytecode.arg_scope_end) {
        return .{ .argument_environment_only = true };
    }
    if (fd.findFunctionVar(atom_id)) |flat_idx| return .{ .local = flat_idx };
    return .{};
}

inline fn resolveScopeVarImpl(
    comptime trust_final_scope_links: bool,
    ctx: *const JSContext,
    atom_id: atom.Atom,
    scope_level: i32,
) ?u16 {
    return resolveScopeVarLookupImpl(
        trust_final_scope_links,
        ctx,
        atom_id,
        scope_level,
    ).local;
}

inline fn resolveScopeVar(ctx: *const JSContext, atom_id: atom.Atom, scope_level: i32) ?u16 {
    return resolveScopeVarImpl(false, ctx, atom_id, scope_level);
}

const LocalOrArg = union(enum) {
    local: u16,
    arg: u16,
};

/// Final identity selected by QuickJS's `resolve_scope_var` walk.  Keeping
/// this four-way result lets compiler-v2 carry the binding discovered by
/// topology directly into opcode selection instead of searching the same
/// local/closure chains again for every scope opcode.
const ScopeVarBinding = union(enum) {
    local: u16,
    arg: u16,
    closure: u16,
    global: u16,
};

inline fn resolveLocalOrArgImpl(
    comptime trust_final_scope_links: bool,
    ctx: *const JSContext,
    atom_id: atom.Atom,
    scope_level: i32,
) ?LocalOrArg {
    const fd = ctx.function_def orelse return null;
    const lookup = resolveScopeVarLookupImpl(
        trust_final_scope_links,
        ctx,
        atom_id,
        scope_level,
    );
    if (lookup.local) |idx| return .{ .local = idx };

    // ARG_SCOPE_END suppresses the ordinary find_var pass (which includes
    // formal arguments), but pseudo bindings remain visible. This ordering
    // is the local half of qjs resolve_scope_var.
    if (!lookup.argument_environment_only) {
        if (lookupArg(ctx, atom_id)) |arg_idx| return .{ .arg = arg_idx };
    }
    if (lookupCurrentPseudoBinding(ctx, atom_id)) |idx| return .{ .local = idx };
    if (atom_id == atom.ids.arguments) {
        if (fd.arguments_var_idx) |idx| return .{ .local = idx };
    }
    if (lookupCurrentFunctionName(ctx, atom_id)) |idx| return .{ .local = idx };
    return null;
}

inline fn resolveLocalOrArg(ctx: *const JSContext, atom_id: atom.Atom, scope_level: i32) ?LocalOrArg {
    return resolveLocalOrArgImpl(false, ctx, atom_id, scope_level);
}

const EvalVarObjectProbe = union(enum) {
    local: u16,
    ref: u16,
    with_local: u16,
    with_ref: u16,
};

fn isEvalVarObjectAtom(atom_id: atom.Atom) bool {
    return atom_id == atom.ids.arg_var_object or atom_id == atom_var_object;
}

pub fn isDynamicEnvObjectAtom(atom_id: atom.Atom) bool {
    return isEvalVarObjectAtom(atom_id) or atom_id == atom.ids.with_object;
}

fn closureVarRangeHasDynamicEnvObjects(
    fd: *const function_def_mod.FunctionDef,
    start: usize,
) bool {
    // A stale cursor must fail closed: callers use false only as proof that
    // the second, V2-specific probe walk can be skipped.
    if (start > fd.closure_var.len) return true;
    for (fd.closure_var[start..]) |cv| {
        if (closureVarIsRuntimeVarRef(cv) and isDynamicEnvObjectAtom(cv.var_name)) return true;
    }
    return false;
}

fn functionHasDynamicEnvObjects(ctx: *const JSContext) bool {
    const fd = ctx.function_def orelse return false;
    if (fd.var_object_idx != null or fd.arg_var_object_idx != null) return true;
    for (fd.vars) |vd| {
        if (vd.var_name == atom.ids.with_object) return true;
    }
    return closureVarRangeHasDynamicEnvObjects(fd, 0);
}

fn scopeUsesArgumentEnvironmentOnly(fd: *const function_def_mod.FunctionDef, scope_level: i32) bool {
    if (!fd.has_parameter_expressions or scope_level < 0 or
        @as(usize, @intCast(scope_level)) >= fd.scopes.len) return false;
    var idx = fd.scopes[@intCast(scope_level)].first;
    var visited: usize = 0;
    while (idx >= 0) {
        if (@as(usize, @intCast(idx)) >= fd.vars.len or visited >= fd.vars.len) return false;
        visited += 1;
        idx = fd.vars[@intCast(idx)].scope_next;
    }
    return idx == function_bytecode.arg_scope_end;
}

const ClosureDynamicEnvProbeIterator = struct {
    fd: ?*const function_def_mod.FunctionDef,
    stop_idx: usize,
    next_idx: usize = 0,
    /// Where the resolved binding lives, when known: only environments
    /// between the reference and it are probed.
    binding_position: ?EnvPosition = null,

    fn init(ctx: *const JSContext, atom_id: atom.Atom) ClosureDynamicEnvProbeIterator {
        const fd = ctx.function_def orelse return .{
            .fd = null,
            .stop_idx = 0,
        };
        var stop_idx = fd.closure_var.len;
        // A direct eval runs inside the catch block that its catch-parameter
        // row names, so that row is an ordinary active binding: environments
        // captured before it (a `with` in the block) are probed, those after
        // it (the caller's var object) are not.
        const catch_rows_stop = bytecodeFunctionIsEval(ctx);
        for (fd.closure_var, 0..) |cv, idx| {
            // A catch binding is only visible while its catch block is
            // active, and global-family rows are the fallback after the
            // dynamic environment objects. Neither row terminates the
            // var-object probe chain for a reference outside that static
            // binding. Lexical/local/argument rows still stop it.
            const stops_probe = !isDynamicEnvObjectAtom(cv.var_name) and
                cv.var_name == atom_id and
                (cv.varKind() != .catch_ or catch_rows_stop) and
                !closureVarIsGlobalFamily(cv);
            if (stops_probe) {
                if (cv.varKind() == .function_name) return functionNameProbes(fd, idx);
                stop_idx = idx;
                break;
            }
            if (cv.var_name == atom_id and cv.varKind() == .catch_) {
                if (catchParameterProbes(fd, idx)) |probes| return probes;
            }
        }
        return .{
            .fd = fd,
            .stop_idx = stop_idx,
        };
    }

    /// A catch parameter reached through closure row `idx` from a function
    /// created inside its catch block: probe only the environments inner to
    /// it. Null when the row has no ordered position.
    fn catchParameterProbes(fd: *const function_def_mod.FunctionDef, idx: usize) ?ClosureDynamicEnvProbeIterator {
        const position = closureRowEnvPosition(fd, idx) orelse return null;
        return .{ .fd = fd, .stop_idx = fd.closure_var.len, .binding_position = position };
    }

    /// A function expression's own name (closure row `idx`) sits outside its
    /// function's variable environment and inside every enclosing one: probe
    /// the environments inner to it by position, since rows are numbered by
    /// first use. Rows captured from a direct eval's caller have no ordered
    /// position; they were captured in chain order, own variable object
    /// first, so stop at the row as for any binding.
    fn functionNameProbes(fd: *const function_def_mod.FunctionDef, idx: usize) ClosureDynamicEnvProbeIterator {
        var position = closureRowEnvPosition(fd, idx) orelse return .{ .fd = fd, .stop_idx = idx };
        if (position.outside) return .{ .fd = fd, .stop_idx = idx };
        position.scope = std.math.minInt(i32);
        return .{ .fd = fd, .stop_idx = fd.closure_var.len, .binding_position = position };
    }

    fn next(self: *ClosureDynamicEnvProbeIterator) ?usize {
        const fd = self.fd orelse return null;
        while (self.next_idx < self.stop_idx) {
            const idx = self.next_idx;
            self.next_idx += 1;
            const cv = fd.closure_var[idx];
            if (!closureVarIsRuntimeVarRef(cv) or !isDynamicEnvObjectAtom(cv.var_name)) continue;
            if (self.binding_position) |binding| {
                // Rows are numbered by first use, not by chain order: an
                // environment threaded for another name may lie beyond it.
                if (closureRowEnvPosition(fd, idx)) |row| {
                    if (row.isInnerThan(binding) == false) continue;
                }
            }
            return idx;
        }
        return null;
    }
};

/// Where a closure row's source sits on the function's environment chain:
/// `depth` functions out, in block scope `scope` of that function. A var
/// object or an argument is `scope = -1`, after every block scope of its
/// function, as QuickJS's resolve_scope_var probes it. `outside` marks a
/// source beyond the outermost compile-time function (a direct eval's
/// caller), whose scope is unknown.
const EnvPosition = struct {
    depth: u32,
    scope: i32,
    outside: bool = false,
    /// For an `outside` source: its row in the outermost compile-time
    /// function (the direct eval), whose rows were captured from the caller
    /// innermost environment first.
    outside_row: usize = 0,

    /// Null when both are outside the same row and cannot be ordered.
    fn isInnerThan(self: EnvPosition, other: EnvPosition) ?bool {
        if (self.outside or other.outside) {
            if (self.outside and other.outside) {
                if (self.outside_row == other.outside_row) return null;
                return self.outside_row < other.outside_row;
            }
            return other.outside;
        }
        // Both lie on one scope chain, and a child scope's index is always
        // greater than its parent's.
        return self.depth < other.depth or (self.depth == other.depth and self.scope > other.scope);
    }
};

/// Null for rows that are not environment sources (global family).
fn closureRowEnvPosition(fd: *const function_def_mod.FunctionDef, idx: usize) ?EnvPosition {
    var owner = fd;
    var row_idx = idx;
    var depth: u32 = 1;
    while (true) {
        if (row_idx >= owner.closure_var.len) return null;
        const cv = owner.closure_var[row_idx];
        const parent = owner.parent orelse return switch (cv.closureType()) {
            .local, .arg, .ref => .{ .depth = depth, .scope = -1, .outside = true, .outside_row = row_idx },
            else => null,
        };
        switch (cv.closureType()) {
            .local => {
                if (cv.var_idx >= parent.vars.len) return null;
                if (isEvalVarObjectAtom(cv.var_name)) return .{ .depth = depth, .scope = -1 };
                return .{ .depth = depth, .scope = parent.vars[cv.var_idx].scope_level };
            },
            .arg => return .{ .depth = depth, .scope = -1 },
            .ref => {
                owner = parent;
                row_idx = cv.var_idx;
                depth += 1;
            },
            else => return null,
        }
    }
}

const LocalWithProbeIterator = struct {
    fd: ?*const function_def_mod.FunctionDef,
    atom_id: atom.Atom,
    next_var_idx: i32,

    fn init(ctx: *const JSContext, atom_id: atom.Atom, scope_level: i32) LocalWithProbeIterator {
        const fd = ctx.function_def;
        const first = if (fd) |def|
            if (scope_level >= 0 and @as(usize, @intCast(scope_level)) < def.scopes.len)
                def.scopes[@intCast(scope_level)].first
            else
                -1
        else
            -1;
        return .{ .fd = fd, .atom_id = atom_id, .next_var_idx = first };
    }

    fn next(self: *LocalWithProbeIterator) ?u16 {
        const fd = self.fd orelse return null;
        var visited: usize = 0;
        while (self.next_var_idx >= 0 and visited < fd.vars.len) {
            visited += 1;
            const idx = self.next_var_idx;
            if (@as(usize, @intCast(idx)) >= fd.vars.len) return null;
            const vd = fd.vars[@intCast(idx)];
            self.next_var_idx = vd.scope_next;
            if (vd.var_name == self.atom_id) {
                self.next_var_idx = -1;
                return null;
            }
            if (vd.var_name == atom.ids.with_object) return @intCast(idx);
        }
        return null;
    }
};

fn staticBindingStopsDynamicEnvProbes(ctx: *const JSContext, atom_id: atom.Atom, scope_level: i32) Error!bool {
    if (try lookupTopLevelModuleLexicalClosureVar(ctx, atom_id, scope_level) != null) return true;
    const binding = resolveLocalOrArg(ctx, atom_id, scope_level) orelse return false;
    return switch (binding) {
        .arg => true,
        .local => |loc_idx| blk: {
            const fd = ctx.function_def orelse break :blk false;
            if (loc_idx >= fd.vars.len) break :blk false;
            const vd = fd.vars[loc_idx];
            if (vd.var_kind == .catch_ and !scopeContainsBinding(fd, scope_level, vd.scope_level)) {
                break :blk false;
            }
            // A function expression's own name lives in an environment
            // outside its variables: a direct eval's `var nf` shadows it.
            if (vd.var_kind == .function_name) break :blk false;
            break :blk !isEvalNonLexicalLocal(ctx, loc_idx);
        },
    };
}

/// A function expression's own name bound as a local: its environment sits
/// between the function's variable environment and every enclosing one, so
/// the function's own eval var object may shadow it but an outer `with` or
/// eval var object may not.
fn isLocalFunctionName(ctx: *const JSContext, loc_idx: u16) bool {
    const fd = ctx.function_def orelse return false;
    return loc_idx < fd.vars.len and fd.vars[loc_idx].var_kind == .function_name;
}

fn resolvedBindingIsLocalFunctionName(ctx: *const JSContext, binding: ScopeVarBinding) bool {
    return switch (binding) {
        .local => |loc_idx| isLocalFunctionName(ctx, loc_idx),
        else => false,
    };
}

/// `this`, `new.target` and the `super` home object are never looked up by
/// name (ResolveThisBinding, GetNewTarget, [[HomeObject]]), so a `with`
/// object cannot shadow them.
fn scopeVarDynamicProbeEligible(atom_id: atom.Atom, scope_level: i32) bool {
    return scope_level >= 0 and
        atom_id != atom.ids.ret and
        !isPseudoBindingAtom(atom_id) and
        !isDynamicEnvObjectAtom(atom_id);
}

/// Binding-aware form of `staticBindingStopsDynamicEnvProbes`.  The old
/// helper has to rediscover the local/closure identity by name; compiler-v2
/// already owns that result from the topology walk.
fn resolvedBindingStopsDynamicEnvProbes(
    ctx: *const JSContext,
    atom_id: atom.Atom,
    scope_level: i32,
    binding: ScopeVarBinding,
) bool {
    return switch (binding) {
        .arg => true,
        .local => |loc_idx| blk: {
            const fd = ctx.function_def orelse break :blk false;
            if (loc_idx >= fd.vars.len) break :blk false;
            const vd = fd.vars[loc_idx];
            if (vd.var_kind == .catch_ and
                !scopeContainsBinding(fd, scope_level, vd.scope_level))
            {
                break :blk false;
            }
            // A direct eval's `var` shadows the function expression's name.
            if (vd.var_kind == .function_name) break :blk false;
            break :blk !isEvalNonLexicalLocal(ctx, loc_idx);
        },
        .closure => |ref_idx| blk: {
            const fd = ctx.function_def orelse break :blk false;
            if (ref_idx >= fd.closure_var.len) break :blk false;
            const cv = fd.closure_var[ref_idx];
            if (scope_level == 0 and cv.var_name == atom_id and
                (cv.closureType() == .module_decl or cv.closureType() == .global_decl) and
                cv.isLexical())
            {
                break :blk true;
            }
            break :blk false;
        },
        .global => false,
    };
}

fn closureDynamicEnvProbeIteratorInitResolved(
    ctx: *const JSContext,
    binding: ScopeVarBinding,
) ClosureDynamicEnvProbeIterator {
    const fd = ctx.function_def orelse return .{ .fd = null, .stop_idx = 0 };
    var stop_idx = fd.closure_var.len;
    var binding_position: ?EnvPosition = null;
    switch (binding) {
        .closure => |ref_idx| if (ref_idx < fd.closure_var.len) {
            const cv = fd.closure_var[ref_idx];
            if (cv.varKind() == .function_name) return ClosureDynamicEnvProbeIterator.functionNameProbes(fd, ref_idx);
            if (cv.varKind() == .catch_ and !bytecodeFunctionIsEval(ctx)) {
                if (ClosureDynamicEnvProbeIterator.catchParameterProbes(fd, ref_idx)) |probes| return probes;
            }
            if (!isDynamicEnvObjectAtom(cv.var_name) and
                (cv.varKind() != .catch_ or bytecodeFunctionIsEval(ctx)) and
                !closureVarIsGlobalFamily(cv))
            {
                // The binding's own resolution threaded every environment
                // before it, so they all have lower indices.
                stop_idx = ref_idx;
                binding_position = closureRowEnvPosition(fd, ref_idx);
            }
        },
        else => {},
    }
    return .{ .fd = fd, .stop_idx = stop_idx, .binding_position = binding_position };
}

fn scopeContainsBinding(
    fd: *const function_def_mod.FunctionDef,
    reference_scope: i32,
    binding_scope: i32,
) bool {
    if (reference_scope < 0 or binding_scope < 0) return false;
    var scope = reference_scope;
    var visited: usize = 0;
    while (scope >= 0 and @as(usize, @intCast(scope)) < fd.scopes.len and visited <= fd.scopes.len) : (visited += 1) {
        if (scope == binding_scope) return true;
        scope = fd.scopes[@intCast(scope)].parent;
    }
    return false;
}

const EvalVarObjectProbeKind = enum {
    read,
    delete,
    put,
    get_ref,
    make_ref,

    fn matches(self: EvalVarObjectProbeKind, op_id: u8) bool {
        return switch (self) {
            .read => op_id == opcode.op.scope_get_var or op_id == opcode.op.scope_get_var_undef,
            .delete => op_id == opcode.op.scope_delete_var,
            .put => op_id == opcode.op.scope_put_var,
            .get_ref => op_id == opcode.op.scope_get_ref,
            .make_ref => op_id == opcode.op.scope_make_ref,
        };
    }

    fn wireKind(self: EvalVarObjectProbeKind) opcode.dyn_env.ProbeKind {
        return switch (self) {
            .read => .read,
            .delete => .delete,
            .put => .put,
            .get_ref => .get_ref,
            .make_ref => .make_ref,
        };
    }
};

const EvalVarObjectProbePlan = struct {
    count: usize = 0,
    prefix_size: usize = 0,
};

fn evalVarObjectProbePlan(
    ctx: *const JSContext,
    atom_id: atom.Atom,
    scope_level: i32,
    op_id: u8,
    kind: EvalVarObjectProbeKind,
) Error!?EvalVarObjectProbePlan {
    if (!kind.matches(op_id) or scope_level < 0 or isDynamicEnvObjectAtom(atom_id)) return null;
    // Eval completion is an implementation-local frame slot. It must never
    // consult with/Proxy or a variable object, even when those environments
    // precede ordinary user bindings at the call site.
    if (atom_id == atom.ids.ret) return null;
    const fd = ctx.function_def orelse return null;
    // Every kind now lowers to the same opcode, so the size oracle no
    // longer varies with it.  It is still read from the table rather than
    // written as a literal, so a format change stays a one-line edit.
    const probe_size = opcode.sizeOf(opcode.op.dyn_env_probe);
    var plan = EvalVarObjectProbePlan{};
    var with_iter = LocalWithProbeIterator.init(ctx, atom_id, scope_level);
    while (with_iter.next()) |idx| {
        plan.count += 1;
        plan.prefix_size += evalVarObjectProbeAccessorSize(ctx, .{ .with_local = idx }) + probe_size;
    }
    if (try staticBindingStopsDynamicEnvProbes(ctx, atom_id, scope_level)) {
        return if (plan.count == 0) null else plan;
    }
    // A variable object may acquire any free name from a later direct eval;
    // probe eligibility therefore depends on environment order, not on the
    // current eval unit's hoisted-name list.
    if (!scopeUsesArgumentEnvironmentOnly(fd, scope_level)) {
        if (fd.var_object_idx) |idx| {
            plan.count += 1;
            plan.prefix_size += evalVarObjectProbeAccessorSize(ctx, .{ .local = idx }) + probe_size;
        }
    }
    if (fd.arg_var_object_idx) |idx| {
        plan.count += 1;
        plan.prefix_size += evalVarObjectProbeAccessorSize(ctx, .{ .local = idx }) + probe_size;
    }
    if (resolveLocalOrArg(ctx, atom_id, scope_level)) |binding| switch (binding) {
        .local => |loc_idx| if (isLocalFunctionName(ctx, loc_idx)) return if (plan.count == 0) null else plan,
        .arg => {},
    };
    var closure_iter = ClosureDynamicEnvProbeIterator.init(ctx, atom_id);
    while (closure_iter.next()) |idx| {
        plan.count += 1;
        plan.prefix_size += evalVarObjectProbeAccessorSize(ctx, evalVarObjectClosureProbe(fd.closure_var[idx], idx)) + probe_size;
    }
    return if (plan.count == 0) null else plan;
}

const ScopeVarAction = struct {
    selected: ShortLocForm,
    index: u16 = 0,
    /// Set for `throw_error`: the write to an immutable binding.
    read_only: ReadOnlyWrite = .{},

    fn size(self: ScopeVarAction) usize {
        return self.selected.size;
    }

    fn atomCount(self: ScopeVarAction) usize {
        return @intFromBool(self.selected.op_id == opcode.op.throw_error);
    }

    fn form(selected: ShortLocForm, index: u16) ScopeVarAction {
        return .{ .selected = selected, .index = index };
    }

    fn throwReadonly(write: ReadOnlyWrite) ScopeVarAction {
        return .{ .selected = .{
            .op_id = opcode.op.throw_error,
            .size = @intCast(write.size()),
            .operand_size = 0,
        }, .read_only = write };
    }

    fn dropAction() ScopeVarAction {
        return .{ .selected = .{
            .op_id = opcode.op.drop,
            .size = 1,
            .operand_size = 0,
        } };
    }
};

fn scopeVarProbeKind(op_id: u8) ?EvalVarObjectProbeKind {
    if (op_id == opcode.op.scope_put_var) return .put;
    if (op_id == opcode.op.scope_get_var or op_id == opcode.op.scope_get_var_undef) {
        return .read;
    }
    return null;
}

fn closureScopeVarAction(
    ctx: *const JSContext,
    atom_id: atom.Atom,
    ref_idx: u16,
    op_id: u8,
) ScopeVarAction {
    if (op_id == opcode.op.scope_put_var) {
        if (closureVarReadOnlyWrite(ctx, ref_idx)) |write| return ScopeVarAction.throwReadonly(write);
    }
    if (op_id == opcode.op.scope_put_var and closureVarKind(ctx, ref_idx) == .function_name) {
        // A function expression's own name is immutable; SetMutableBinding
        // throws when the ASSIGNING code is strict (§9.1.1.1.5), whatever
        // the named function's own strictness.
        const assigning_strict = if (ctx.function_def) |fd| fd.is_strict_mode else false;
        return if (assigning_strict) ScopeVarAction.throwReadonly(.{}) else ScopeVarAction.dropAction();
    }
    const ref_op = lowerScopeVarOpForClosure(ctx, atom_id, ref_idx, op_id);
    return ScopeVarAction.form(selectVarRefForm(ctx, ref_op, ref_idx), ref_idx);
}

/// Opcode half of QuickJS `resolve_scope_var` for an identity already
/// returned by the topology walk.  This is deliberately only a projection
/// of the resolved identity: it does not introduce a cache or a second
/// representation of the instruction stream.
fn planResolvedScopeVarAction(
    ctx: *const JSContext,
    atom_id: atom.Atom,
    op_id: u8,
    binding: ScopeVarBinding,
) Error!ScopeVarAction {
    return switch (binding) {
        .arg => |arg_idx| blk: {
            const arg_op = lowerScopeVarOpArg(op_id) orelse return error.InvalidBytecode;
            break :blk ScopeVarAction.form(selectArgForm(ctx, arg_op, arg_idx), arg_idx);
        },
        .local => |loc_idx| blk: {
            if (op_id == opcode.op.scope_put_var) {
                if (localReadOnlyWrite(ctx, loc_idx)) |write| break :blk ScopeVarAction.throwReadonly(write);
            }
            if (op_id == opcode.op.scope_put_var and localIsFunctionName(ctx, loc_idx)) {
                break :blk ScopeVarAction.dropAction();
            }
            if (localLexicalAccessNeedsCheck(ctx, atom_id, loc_idx, op_id)) {
                break :blk ScopeVarAction.form(
                    .{
                        .op_id = lowerScopeVarOpLexical(op_id),
                        .size = 3,
                        .operand_size = 2,
                    },
                    loc_idx,
                );
            }
            const local_op = lowerScopeVarOpLocal(op_id);
            break :blk ScopeVarAction.form(selectLocForm(ctx, local_op, loc_idx), loc_idx);
        },
        .closure => |ref_idx| closureScopeVarAction(ctx, atom_id, ref_idx, op_id),
        .global => |ref_idx| ScopeVarAction.form(
            .{
                .op_id = lowerScopeVarOpGlobal(op_id),
                .size = 3,
                .operand_size = 2,
            },
            ref_idx,
        ),
    };
}

fn writeScopeVarAction(
    w: *AtomWriter,
    atom_id: atom.Atom,
    action: ScopeVarAction,
) Error!void {
    if (w.idx + action.size() > w.code.len) return error.InvalidBytecode;
    if (action.selected.op_id == opcode.op.throw_error) {
        if (w.atom_idx >= w.atoms.len) return error.InvalidBytecode;
        writeReadOnlyWrite(w, atom_id, action.read_only);
    } else if (action.selected.op_id == opcode.op.drop) {
        w.op(opcode.op.drop);
    } else {
        writeSelectedLocForm(w.code, &w.idx, action.selected, action.index);
    }
}

fn evalVarObjectProbeAccessorSize(ctx: *const JSContext, probe: EvalVarObjectProbe) usize {
    return switch (probe) {
        .local, .with_local => |idx| selectLocForm(ctx, opcode.op.get_loc, idx).size,
        .ref, .with_ref => |idx| selectVarRefForm(ctx, opcode.op.get_var_ref, idx).size,
    };
}

fn evalVarObjectProbeIsWith(probe: EvalVarObjectProbe) bool {
    return switch (probe) {
        .with_local, .with_ref => true,
        .local, .ref => false,
    };
}

fn evalVarObjectClosureProbe(cv: function_def_mod.ClosureVar, idx: usize) EvalVarObjectProbe {
    return if (cv.var_name == atom.ids.with_object)
        .{ .with_ref = @intCast(idx) }
    else
        .{ .ref = @intCast(idx) };
}

/// True when a lowered `scope_delete_var` needs a runtime `delete_var`;
/// declared bindings compile to `push_false`.
fn loweredScopeDeleteVarIsDynamic(ctx: *const JSContext, atom_id: atom.Atom, scope_level: i32) bool {
    if (resolveScopeVar(ctx, atom_id, scope_level)) |loc_idx| return isEvalNonLexicalLocal(ctx, loc_idx);
    return lookupArg(ctx, atom_id) == null and
        lookupCurrentFunctionName(ctx, atom_id) == null and
        lookupClosureVar(ctx, atom_id) == null;
}

/// Encoding chosen for a lowered `scope_get_ref`: `undefined` followed by
/// the value read. Size and bytes both derive from this one decision.
const GetRefPlan = union(enum) {
    /// `get_arg` / `get_loc` / `get_var_ref` in the selected short form.
    slot: struct { form: ShortLocForm, idx: u16 },
    /// `get_loc_check` for a lexical local (TDZ).
    loc_check: u16,
    /// `get_var` through the global closure slot.
    global,

    pub fn size(plan: GetRefPlan) usize {
        return 1 + switch (plan) {
            .slot => |slot| slot.form.size,
            .loc_check, .global => 3,
        };
    }
};

fn loweredScopeGetRefPlan(ctx: *const JSContext, atom_id: atom.Atom, scope_level: i32) GetRefPlan {
    if (resolveLocalOrArg(ctx, atom_id, scope_level)) |binding| return switch (binding) {
        .arg => |arg_idx| .{ .slot = .{ .form = selectArgForm(ctx, opcode.op.get_arg, arg_idx), .idx = arg_idx } },
        .local => |loc_idx| if (isEvalNonLexicalLocal(ctx, loc_idx))
            .global
        else if (isLexicalLocal(ctx, loc_idx))
            .{ .loc_check = loc_idx }
        else
            .{ .slot = .{ .form = selectLocForm(ctx, opcode.op.get_loc, loc_idx), .idx = loc_idx } },
    };
    if (lookupClosureVar(ctx, atom_id)) |ref_idx| {
        return .{ .slot = .{ .form = selectVarRefForm(ctx, opcode.op.get_var_ref, ref_idx), .idx = ref_idx } };
    }
    return .global;
}

/// Encoding chosen for a lowered `scope_make_ref`. Size, atom count, and
/// bytes all derive from this one decision.
const MakeRefPlan = union(enum) {
    /// `make_arg_ref` / `make_loc_ref` / `make_var_ref_ref`: atom + u16 index.
    slot_ref: struct { op_id: u8, idx: u16 },
    /// `make_var_ref`: atom resolved at runtime (global or eval var object).
    dynamic,
    /// Write to an immutable binding: `throw_error` read-only.
    throw_read_only: ReadOnlyWrite,
    /// Sloppy function-expression name: a disposable `{ name: value }`
    /// reference read with the selected get form.
    function_name: struct { form: ShortLocForm, idx: u16 },

    pub fn size(plan: MakeRefPlan) usize {
        return switch (plan) {
            .slot_ref => 7,
            .dynamic => 5,
            .throw_read_only => |write| write.size(),
            .function_name => |name| 1 + name.form.size + 5 + 5,
        };
    }

    pub fn atomCount(plan: MakeRefPlan) usize {
        return switch (plan) {
            .function_name => 2,
            .slot_ref, .dynamic, .throw_read_only => 1,
        };
    }
};

fn loweredScopeMakeRefPlan(ctx: *const JSContext, atom_id: atom.Atom, scope_level: i32) MakeRefPlan {
    if (resolveLocalOrArg(ctx, atom_id, scope_level)) |binding| return switch (binding) {
        .arg => |arg_idx| .{ .slot_ref = .{ .op_id = opcode.op.make_arg_ref, .idx = arg_idx } },
        .local => |loc_idx| if (isEvalNonLexicalLocal(ctx, loc_idx))
            .dynamic
        else if (localReadOnlyWrite(ctx, loc_idx)) |write|
            .{ .throw_read_only = write }
        else if (localIsFunctionName(ctx, loc_idx))
            .{ .function_name = .{ .form = selectLocForm(ctx, opcode.op.get_loc, loc_idx), .idx = loc_idx } }
        else
            .{ .slot_ref = .{ .op_id = opcode.op.make_loc_ref, .idx = loc_idx } },
    };
    if (lookupClosureVar(ctx, atom_id)) |ref_idx| {
        if (closureVarReadOnlyWrite(ctx, ref_idx)) |write| return .{ .throw_read_only = write };
        if (closureVarKind(ctx, ref_idx) == .function_name) {
            return .{ .function_name = .{ .form = selectVarRefForm(ctx, opcode.op.get_var_ref, ref_idx), .idx = ref_idx } };
        }
        return .{ .slot_ref = .{ .op_id = opcode.op.make_var_ref_ref, .idx = ref_idx } };
    }
    return .dynamic;
}

fn writeEvalVarObjectProbeAccessor(ctx: *const JSContext, output: []u8, out_idx: *usize, probe: EvalVarObjectProbe) Error!void {
    switch (probe) {
        .local, .with_local => |idx| {
            const form = selectLocForm(ctx, opcode.op.get_loc, idx);
            if (out_idx.* + form.size > output.len) return error.InvalidBytecode;
            output[out_idx.*] = form.op_id;
            switch (form.operand_size) {
                0 => {},
                1 => output[out_idx.* + 1] = @intCast(idx),
                2 => std.mem.writeInt(u16, output[out_idx.* + 1 ..][0..2], idx, .little),
                else => unreachable,
            }
            out_idx.* += form.size;
        },
        .ref, .with_ref => |idx| {
            const form = selectVarRefForm(ctx, opcode.op.get_var_ref, idx);
            if (out_idx.* + form.size > output.len) return error.InvalidBytecode;
            output[out_idx.*] = form.op_id;
            switch (form.operand_size) {
                0 => {},
                2 => std.mem.writeInt(u16, output[out_idx.* + 1 ..][0..2], idx, .little),
                else => unreachable,
            }
            out_idx.* += form.size;
        },
    }
}

fn writeLoweredScopeDeleteVar(
    w: *AtomWriter,
    atom_id: atom.Atom,
    is_dynamic: bool,
) void {
    if (is_dynamic) {
        w.atomOp(opcode.op.delete_var, atom_id);
    } else {
        w.op(opcode.op.push_false);
    }
}

fn writeLoweredScopeGetRef(
    ctx: *JSContext,
    output: []u8,
    out_idx: *usize,
    atom_id: atom.Atom,
    plan: GetRefPlan,
) Error!void {
    output[out_idx.*] = opcode.op.undefined;
    out_idx.* += 1;
    switch (plan) {
        .slot => |slot| writeSelectedLocForm(output, out_idx, slot.form, slot.idx),
        .loc_check => |loc_idx| {
            output[out_idx.*] = opcode.op.get_loc_check;
            std.mem.writeInt(u16, output[out_idx.* + 1 ..][0..2], loc_idx, .little);
            out_idx.* += 3;
        },
        .global => try emitGlobalVarOp(ctx, output, out_idx, opcode.op.get_var, atom_id),
    }
}

/// QuickJS resolve_scope_var builds a disposable `{ name: binding }`
/// reference for sloppy function-expression names. Reference-form
/// assignments then update that object property, leaving the immutable
/// self-binding untouched.
fn writeFunctionNameDummyRef(
    w: *AtomWriter,
    atom_id: atom.Atom,
    get_form: ShortLocForm,
    binding_idx: u16,
) void {
    w.op(opcode.op.object);
    writeSelectedLocForm(w.code, &w.idx, get_form, binding_idx);
    w.atomOp(opcode.op.define_field, atom_id);
    w.atomOp(opcode.op.push_atom_value, atom_id);
}

fn writeLoweredScopeMakeRef(
    w: *AtomWriter,
    atom_id: atom.Atom,
    plan: MakeRefPlan,
) void {
    switch (plan) {
        .slot_ref => |slot| {
            w.atomOp(slot.op_id, atom_id);
            w.u16(slot.idx);
        },
        .dynamic => w.atomOp(opcode.op.make_var_ref, atom_id),
        .throw_read_only => |write| writeReadOnlyWrite(w, atom_id, write),
        .function_name => |name| writeFunctionNameDummyRef(w, atom_id, name.form, name.idx),
    }
}

/// True iff the local at `loc_idx` is a lexical (`let`/`const`) var
/// — these need TDZ check variants. `var` slots return false (var
/// is hoisted and starts as `undefined`, no TDZ).
fn isLexicalLocal(ctx: *const JSContext, loc_idx: u16) bool {
    const fd = ctx.function_def orelse return false;
    if (loc_idx >= fd.vars.len) return false;
    return fd.vars[loc_idx].is_lexical;
}

fn isEvalNonLexicalLocal(ctx: *const JSContext, loc_idx: u16) bool {
    const fd = ctx.function_def orelse return false;
    // QuickJS marks every root program FunctionDef `is_eval`; that flag
    // controls global-declaration construction, not whether compiler
    // temporaries should become dynamic eval bindings. Only actual direct
    // or indirect eval units take this lowering path.
    if (!fd.is_direct_eval and !fd.is_indirect_eval and !bytecodeFunctionIsEval(ctx)) return false;
    if (fd.is_strict_mode or ctx.function.flags.is_strict) return false;
    if (loc_idx >= fd.vars.len) return false;
    const vd = fd.vars[loc_idx];
    // `<ret>` is the eval engine's private completion slot, not a
    // user-declared `var`. It must remain frame-local even in sloppy eval;
    // publishing it as a global/eval binding makes direct eval depend on
    // whether its caller happened to request a script completion value.
    // Demand-created `this`/`new.target`/home-object locals are likewise
    // compiler-owned frame state. Canonical indirect-eval roots expose
    // their own `this` through this path; it is never a dynamic eval var.
    if (vd.var_name == atom.ids.ret or isPseudoBindingAtom(vd.var_name)) return false;
    if (vd.scope_level != 0 or vd.is_lexical) return false;
    return vd.var_kind == .normal or
        vd.var_kind == .function_decl or
        vd.var_kind == .new_function_decl;
}

fn bytecodeFunctionIsEval(ctx: *const JSContext) bool {
    // Variable resolution runs before the final FunctionBytecode flags are
    // published.  QuickJS makes these decisions from the live
    // JSFunctionDef::is_eval field, not from the finished bytecode flag
    // (whose QuickJS use is script/module-name lookup).  Keep the finished
    // flag only as the exact fallback for synthetic callers without an fd.
    if (ctx.function_def) |fd| return fd.is_direct_eval or fd.is_indirect_eval;
    return ctx.function.flags.is_direct_or_indirect_eval;
}

fn localIsFunctionName(ctx: *const JSContext, loc_idx: u16) bool {
    const fd = ctx.function_def orelse return false;
    return loc_idx < fd.vars.len and fd.vars[loc_idx].var_kind == .function_name;
}

/// QuickJS resolves writes/references to const locals directly to
/// OP_throw_error. Function-expression names are const exactly when their
/// defining function is strict; sloppy names are handled by the discard
/// and dummy-reference lowering paths above.
fn localWriteThrowsReadOnly(ctx: *const JSContext, loc_idx: u16) bool {
    const fd = ctx.function_def orelse return false;
    if (loc_idx >= fd.vars.len) return false;
    return fd.vars[loc_idx].is_const;
}

/// Promote a Phase-1 var op to its TDZ-checked counterpart for
/// lexical locals. Mirrors the `_check` family in QuickJS:
/// - `scope_get_var` / `scope_get_var_undef` → `get_loc_check`
///   (throws ReferenceError if slot is uninitialised).
/// - `scope_put_var` → `put_loc_check` (throws ReferenceError if
///   uninitialised, then stores).
/// - derived-constructor `this` initialization → `put_loc_check_init`
///   (the only lexical initialization QuickJS checks for re-entry).
///
/// All check variants are 3-byte u16 forms (no short variants in
/// QuickJS), so callers must NOT run `selectShortLoc` on the result.
fn lowerScopeVarOpLexical(op_id: u8) u8 {
    return switch (op_id) {
        opcode.op.scope_get_var => opcode.op.get_loc_check,
        opcode.op.scope_get_var_undef => opcode.op.get_loc_check,
        opcode.op.scope_get_var_checkthis => opcode.op.get_loc_checkthis,
        opcode.op.scope_put_var => opcode.op.put_loc_check,
        opcode.op.scope_put_var_init => opcode.op.put_loc_check_init,
        else => unreachable,
    };
}

/// QuickJS keeps ordinary lexical reads/writes TDZ-checked, but lowers an
/// ordinary `scope_put_var_init` to bare `put_loc`; only the derived
/// constructor's `this` binding uses `put_loc_check_init` so `super()`
/// cannot initialize it twice.
fn localLexicalAccessNeedsCheck(ctx: *const JSContext, atom_id: atom.Atom, loc_idx: u16, op_id: u8) bool {
    if (!isLexicalLocal(ctx, loc_idx)) return false;
    return op_id != opcode.op.scope_put_var_init or atom_id == atom.ids.this_;
}

fn writeSelectedLocForm(output: []u8, out_idx: *usize, form: ShortLocForm, loc_idx: u16) void {
    output[out_idx.*] = form.op_id;
    switch (form.operand_size) {
        0 => {},
        1 => output[out_idx.* + 1] = @intCast(loc_idx),
        2 => std.mem.writeInt(u16, output[out_idx.* + 1 ..][0..2], loc_idx, .little),
        else => unreachable,
    }
    out_idx.* += form.size;
}

fn markReferenceTakenBinding(ctx: *const JSContext, atom_id: atom.Atom, scope_level: i16) Error!void {
    const fd = ctx.function_def orelse return;
    const binding = resolveLocalOrArg(ctx, atom_id, scope_level) orelse return;
    switch (binding) {
        .local => |idx| if (idx < fd.vars.len) {
            // QuickJS's function-name dummy-reference arm never calls
            // capture_var: the temporary object owns the write target.
            if (fd.vars[idx].var_kind != .function_name) {
                try fd.captureLocal(idx);
            }
        },
        .arg => |idx| if (idx < fd.args.len) {
            try fd.captureArg(idx);
        },
    }
}

fn functionIsStrict(ctx: *const JSContext) bool {
    if (ctx.function_def) |fd| return fd.is_strict_mode;
    return ctx.function.flags.is_strict or ctx.function.flags.runtime_strict;
}

fn functionDeclaresGlobalVar(ctx: *const JSContext, atom_id: atom.Atom) bool {
    const fd = ctx.function_def orelse return false;
    for (fd.global_vars) |global_var| {
        if (global_var.var_name == atom_id) return true;
    }
    return false;
}

fn canOptimizeGlobalRefPutTail(ctx: *const JSContext, atom_id: atom.Atom) bool {
    return !functionIsStrict(ctx) or functionDeclaresGlobalVar(ctx, atom_id);
}

fn closureVarIsGlobalFamily(cv: function_def_mod.ClosureVar) bool {
    return switch (cv.closureType()) {
        .global, .global_ref, .global_decl, .module_decl, .module_import => true,
        .local, .arg, .ref => false,
    };
}

/// Resolve each eval hoist against the finalized closure order. Dynamic
/// environment objects and real bindings deliberately share one ordered
/// walk: the first applicable entry is the declaration environment.
fn resolveEvalGlobalVarTargets(fd: *function_def_mod.FunctionDef) Error!void {
    if (!fd.is_eval) {
        for (fd.global_vars) |*gv| gv.eval_target = .global;
        return;
    }
    // One pass over the rows instead of one per hoist: a top-level script's
    // closure rows include one per declaration.
    const none = std.math.maxInt(u32);
    // First same-name row that can be the variable environment: a catch
    // parameter never is (B.3.4 only relaxes the conflict check), nor is a
    // function expression's own name.
    var first_rows: std.AutoHashMapUnmanaged(atom.Atom, u32) = .empty;
    defer first_rows.deinit(fd.allocator);
    var first_var_object: u32 = none;
    for (fd.closure_var, 0..) |cv, idx| {
        if (idx > std.math.maxInt(u16)) return error.BytecodeOverflow;
        const row: u32 = @intCast(idx);
        if (isEvalVarObjectAtom(cv.var_name) and closureVarIsRuntimeVarRef(cv)) {
            if (first_var_object == none) first_var_object = row;
            continue;
        }
        if (cv.varKind() == .function_name or cv.varKind() == .catch_) continue;
        const entry = try first_rows.getOrPut(fd.allocator, cv.var_name);
        if (!entry.found_existing) entry.value_ptr.* = row;
    }
    for (fd.global_vars) |*gv| {
        // EvalDeclarationInstantiation creates and initializes vars and
        // functions in the variable environment; the initializer of a
        // hoisted `var` still assigns through a same-name catch reference.
        const binding_row = first_rows.get(gv.var_name) orelse none;
        gv.eval_target = if (binding_row < first_var_object)
            .{ .closure = @intCast(binding_row) }
        else if (first_var_object != none)
            .{ .var_object = @intCast(first_var_object) }
        else
            .global;
    }
}

fn hasDirectEvalLexicalRedeclaration(
    fd: *const function_def_mod.FunctionDef,
    gv: function_def_mod.GlobalVar,
) bool {
    if (!fd.is_direct_eval) return false;
    for (fd.closure_var) |cv| {
        // add_global_variables appends global-family entries at the end;
        // QuickJS's validation walk stops there.
        if (closureVarIsGlobalFamily(cv)) return false;
        if (cv.var_name == gv.var_name) {
            // Annex B.3.4 excludes the same-name simple catch environment
            // from EvalDeclarationInstantiation's conflict walk. Continue
            // so an outer lexical still rejects the declaration.
            if (gv.cpool_idx < 0 and cv.varKind() == .catch_) continue;
            return cv.isLexical();
        }
        if (isEvalVarObjectAtom(cv.var_name)) return false;
    }
    return false;
}

fn isPseudoBindingAtom(atom_id: atom.Atom) bool {
    return atom_id == atom.ids.home_object or
        atom_id == atom.ids.this_active_func or
        atom_id == atom.ids.new_target or
        atom_id == atom.ids.this_;
}

fn threadParentLocalSource(
    target: *function_def_mod.FunctionDef,
    parent: *function_def_mod.FunctionDef,
    local_idx: u16,
) Error!u16 {
    if (local_idx >= parent.vars.len) return error.InvalidBytecode;
    try parent.captureLocal(local_idx);
    const vd = parent.vars[local_idx];
    return threadClosureSource(target, parent, local_idx, function_def_mod.ClosureVar.init(.{
        .closure_type = .local,
        .is_lexical = vd.is_lexical,
        .is_const = vd.is_const,
        .var_kind = vd.var_kind,
        .var_idx = local_idx,
        .var_name = vd.var_name,
    }), .local);
}

/// `threadParentLocalSource`, except that a function expression's own name
/// first threads the parent's var objects: a direct eval `var` in the parent
/// shadows the name, so references must probe them before it.
fn threadParentBindingSource(
    target: *function_def_mod.FunctionDef,
    parent: *function_def_mod.FunctionDef,
    local_idx: u16,
    argument_environment_only: bool,
) Error!u16 {
    if (local_idx < parent.vars.len and parent.vars[local_idx].var_kind == .function_name) {
        if (!argument_environment_only) {
            if (parent.var_object_idx) |idx| _ = try threadParentLocalSource(target, parent, idx);
        }
        if (parent.arg_var_object_idx) |idx| _ = try threadParentLocalSource(target, parent, idx);
    }
    return threadParentLocalSource(target, parent, local_idx);
}

fn threadParentArgSource(
    target: *function_def_mod.FunctionDef,
    parent: *function_def_mod.FunctionDef,
    arg_idx: u16,
) Error!u16 {
    if (arg_idx >= parent.args.len) return error.InvalidBytecode;
    try parent.captureArg(arg_idx);
    const arg = parent.args[arg_idx];
    return threadClosureSource(target, parent, arg_idx, function_def_mod.ClosureVar.init(.{
        .closure_type = .arg,
        .is_lexical = arg.is_lexical,
        .is_const = arg.is_const,
        .var_kind = arg.var_kind,
        .var_idx = arg_idx,
        .var_name = arg.var_name,
    }), .arg);
}

/// Scope-chain half of qjs resolve_scope_var. While looking for the named
/// source, every preceding `with` environment is itself a capture event.
/// `first/scope_next` is already the complete finalized visible chain.
const ParentScopedSource = struct {
    local: ?u16 = null,
    argument_environment_only: bool = false,
};

fn discoverParentScopedSource(
    comptime trust_final_scope_links: bool,
    target: *function_def_mod.FunctionDef,
    parent: *function_def_mod.FunctionDef,
    atom_id: atom.Atom,
    start_scope: i32,
) Error!ParentScopedSource {
    if (start_scope < 0 or @as(usize, @intCast(start_scope)) >= parent.scopes.len) {
        return error.InvalidBytecode;
    }
    if (comptime trust_final_scope_links) {
        switch (try parent.scopeChainFirstVar(start_scope, atom_id)) {
            .walk => {},
            .found => |row| return .{ .local = row },
            .missing => |end| {
                if (end != -1 and end != function_bytecode.arg_scope_end) return error.InvalidBytecode;
                return .{ .argument_environment_only = end == function_bytecode.arg_scope_end };
            },
        }
    }
    var var_idx = parent.scopes[@intCast(start_scope)].first;
    var visited_vars: usize = 0;
    while (var_idx >= 0) {
        if (comptime !trust_final_scope_links) {
            if (@as(usize, @intCast(var_idx)) >= parent.vars.len or
                visited_vars >= parent.vars.len) return error.InvalidBytecode;
            visited_vars += 1;
        }
        const vd = parent.vars[@intCast(var_idx)];
        if (vd.var_name == atom_id) return .{ .local = @intCast(var_idx) };
        if (!isPseudoBindingAtom(atom_id) and vd.var_name == atom.ids.with_object) {
            _ = try threadParentLocalSource(target, parent, @intCast(var_idx));
        }
        var_idx = vd.scope_next;
    }
    if (var_idx != -1 and var_idx != function_bytecode.arg_scope_end) return error.InvalidBytecode;
    return .{ .argument_environment_only = var_idx == function_bytecode.arg_scope_end };
}

pub fn remapArgumentsArgumentBindingError(
    err: error{ OutOfMemory, BytecodeOverflow, InvalidScope },
) error{ OutOfMemory, BytecodeOverflow, InvalidBytecode } {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.BytecodeOverflow => error.BytecodeOverflow,
        error.InvalidScope => error.InvalidBytecode,
    };
}

fn ensureCurrentPseudoBinding(
    fd: *function_def_mod.FunctionDef,
    atom_id: atom.Atom,
) Error!?u16 {
    if (!fd.has_this_binding) return null;
    return if (atom_id == atom.ids.home_object)
        try fd.ensureHomeObjectBinding()
    else if (atom_id == atom.ids.this_active_func)
        try fd.ensureThisActiveFunctionBinding()
    else if (atom_id == atom.ids.new_target)
        try fd.ensureNewTargetBinding()
    else if (atom_id == atom.ids.this_)
        try fd.ensureThisBinding()
    else
        null;
}

/// Select the same current-function closure identity as the lowering half:
/// a real runtime ref wins, while dynamic-global carriers are the fallback.
/// Returns the chosen index, so the caller needs no second name scan.
fn findResolvedClosureBinding(
    fd: *function_def_mod.FunctionDef,
    atom_id: atom.Atom,
) Error!?ScopeVarBinding {
    var global_idx: ?u16 = null;
    var rows = try fd.closureRowsNamed(atom_id);
    while (rows.next()) |idx| {
        const cv = fd.closure_var[idx];
        if (closureVarIsRuntimeVarRef(cv) and
            !closureVarSourceIsDynamicGlobal(fd, idx))
        {
            return .{ .closure = idx };
        }
        if (global_idx == null and closureVarIsGlobalFamily(cv)) {
            global_idx = idx;
        }
    }
    return if (global_idx) |idx| .{ .global = idx } else null;
}

/// Continue QuickJS's resolve_scope_var walk after the current function's
/// scope/var/argument lookup missed.  Keep parent traversal, closure
/// threading, and demand-created bindings out of the overwhelmingly common
/// local/argument path: those operations need fallible calls and a large
/// spill frame, while QuickJS reaches them only after the same local miss.
noinline fn resolveBindingTopologyAfterCurrentMiss(
    trust_final_scope_links: bool,
    ctx: *JSContext,
    atom_id: atom.Atom,
) Error!ScopeVarBinding {
    const fd = ctx.function_def orelse return error.NoFunctionDef;
    if (trust_final_scope_links) {
        std.debug.assert(ctx.scope_link_proof != .none);
    }
    // Current-function fallbacks mirror resolve_scope_var exactly: normal
    // scope/var/argument lookup first, then pseudo variables, implicit
    // arguments, and finally a named function-expression self binding.
    // Parser bytecode therefore stays name+scope; this final topology pass
    // is the single point that can append a demand-created special local.
    if (try ensureCurrentPseudoBinding(fd, atom_id)) |idx| return .{ .local = idx };
    if (atom_id == atom.ids.arguments and fd.has_arguments_binding) {
        return .{ .local = try fd.ensureArgumentsBinding() };
    }
    if (fd.is_named_func_expr and atom_id == fd.func_name) {
        return .{ .local = try fd.ensureFuncExprSelfBinding() };
    }

    // Fixed prefixes/imports and already-threaded child demands are final
    // binding identities. The selected row is returned directly instead
    // of using a name-only guard and rediscovering it in the planner.
    if (try findResolvedClosureBinding(fd, atom_id)) |binding| return binding;

    if (fd.parent != null) {
        if (trust_final_scope_links) {
            try ctx.proveParentScopeLinksForResolution();
        } else {
            try validateFunctionDefParentChain(fd);
        }
    }

    var maybe_parent = fd.parent;
    var visible_scope_level = fd.parent_scope_level;
    while (maybe_parent) |parent| {
        // Keep `discoverParentScopedSource` specialized; this outlined
        // miss walk is shared for both proof modes.
        const scoped_source = if (trust_final_scope_links)
            try discoverParentScopedSource(true, fd, parent, atom_id, visible_scope_level)
        else
            try discoverParentScopedSource(false, fd, parent, atom_id, visible_scope_level);
        const argument_environment_only = scoped_source.argument_environment_only;
        if (scoped_source.local) |local_idx| {
            return .{ .closure = try threadParentBindingSource(fd, parent, local_idx, argument_environment_only) };
        }

        // An arrow created while a parameter initializer is evaluated is
        // linked to the parameter environment, not to the function-body
        // var environment.  The synthetic `arguments` cell is normally
        // created by add_eval_variables, but this capture is also valid
        // without a direct eval in the parent, so materialize the same
        // scope-1 cell on demand before the body-var/arguments fallback.
        if (atom_id == atom.ids.arguments and
            argument_environment_only and
            parent.has_arguments_binding and
            parent.has_parameter_expressions and
            parent.func_type != .arrow and
            parent.func_type != .class_static_init)
        {
            _ = try parent.ensureArgumentsBinding();
            parent.ensureArgumentsArgumentBinding() catch |err| return remapArgumentsArgumentBindingError(err);
            const parameter_arguments_idx = if (parent.hasExplicitArgumentsVar())
                parent.arguments_arg_idx
            else
                parent.arguments_var_idx;
            if (parameter_arguments_idx) |parameter_arguments_local| {
                return .{ .closure = try threadParentLocalSource(
                    fd,
                    parent,
                    parameter_arguments_local,
                ) };
            }
        }

        // A sloppy eval's own `var` lives in its caller's variable
        // environment, outside a catch block the eval runs in: the
        // same-named catch parameter row (threaded by the eval arm below)
        // is found first (B.3.4).
        const eval_catch_shadows_var = parent.is_eval and !parent.is_strict_mode and
            if (try parent.findClosureRow(atom_id)) |row| parent.closure_var[row].varKind() == .catch_ else false;
        if (!argument_environment_only and !eval_catch_shadows_var) {
            // QuickJS's finalized scope chain deliberately stops before
            // scope 0, then resolve_scope_var calls find_var: function
            // vars are scope-0 rows even when their parser-era
            // `scope_next` stores a block declaration origin.  They must
            // not be linked into scope.first merely to make descendants
            // discover them.
            if (parent.findFunctionVar(atom_id)) |function_var_idx| {
                return .{ .closure = try threadParentBindingSource(fd, parent, function_var_idx, argument_environment_only) };
            }
            const arg_idx_i32 = parent.findArg(atom_id);
            if (arg_idx_i32 >= 0) {
                const arg_idx: u16 = @intCast(arg_idx_i32);
                return .{ .closure = try threadParentArgSource(fd, parent, arg_idx) };
            }
        }

        if (try ensureCurrentPseudoBinding(parent, atom_id)) |local_idx| {
            return .{ .closure = try threadParentLocalSource(fd, parent, local_idx) };
        }

        if (atom_id == atom.ids.arguments and parent.has_arguments_binding) {
            const local_idx = try parent.ensureArgumentsBinding();
            return .{ .closure = try threadParentLocalSource(fd, parent, local_idx) };
        }

        if (parent.is_named_func_expr and atom_id == parent.func_name) {
            const local_idx = try parent.ensureFuncExprSelfBinding();
            return .{ .closure = try threadParentBindingSource(fd, parent, local_idx, argument_environment_only) };
        }

        if (!isPseudoBindingAtom(atom_id)) {
            if (!argument_environment_only) {
                if (parent.var_object_idx) |idx| _ = try threadParentLocalSource(fd, parent, idx);
            }
            if (parent.arg_var_object_idx) |idx| _ = try threadParentLocalSource(fd, parent, idx);
        }

        if (parent.is_eval) {
            // The eval root's rows in order up to the first named `atom_id`:
            // thread each dynamic environment passed, then the match.
            const match = try parent.findClosureRow(atom_id);
            if (!isPseudoBindingAtom(atom_id)) {
                for (try parent.closureDynamicEnvRows()) |source_idx| {
                    if (match) |match_idx| if (source_idx >= match_idx) break;
                    _ = try threadClosureSource(fd, parent, source_idx, parent.closure_var[source_idx], .ref);
                }
            }
            const source_idx = match orelse break;
            const source = parent.closure_var[source_idx];
            const source_type: function_def_mod.ClosureType = switch (source.closureType()) {
                .global, .global_ref, .global_decl => .global_ref,
                .local, .arg, .ref, .module_decl, .module_import => .ref,
            };
            const idx = try threadClosureSource(fd, parent, source_idx, source, source_type);
            return if (source_type == .global_ref)
                .{ .global = idx }
            else
                .{ .closure = idx };
        }

        visible_scope_level = parent.parent_scope_level;
        maybe_parent = parent.parent;
    }

    return .{ .global = try ensureGlobalClosureVar(ctx, atom_id) };
}

/// Discover one scope-bytecode binding after all declarations and child
/// FunctionDefs exist. This is the topology half of QuickJS
/// resolve_scope_var/get_closure_var: source identity is found from final
/// scope metadata, capture_var fires at the owner, and every intermediate
/// row is appended in child-finalization/bytecode encounter order.  The
/// returned identity is the row that the same QuickJS walk just selected.
inline fn resolveBindingTopologyResultImpl(
    comptime trust_final_scope_links: bool,
    ctx: *JSContext,
    atom_id: atom.Atom,
    scope_level: i32,
) Error!ScopeVarBinding {
    if (scope_level >= 0) {
        if (resolveLocalOrArgImpl(
            trust_final_scope_links,
            ctx,
            atom_id,
            scope_level,
        )) |binding| {
            return switch (binding) {
                .local => |idx| .{ .local = idx },
                .arg => |idx| .{ .arg = idx },
            };
        }
    }
    return resolveBindingTopologyAfterCurrentMiss(trust_final_scope_links, ctx, atom_id);
}

fn resolveBindingTopologyResult(
    ctx: *JSContext,
    atom_id: atom.Atom,
    scope_level: i32,
) Error!ScopeVarBinding {
    return resolveBindingTopologyResultImpl(false, ctx, atom_id, scope_level);
}

/// Complete the binding classification needed by ordinary scope-var
/// lowering. Module lexical precedence and sloppy-eval locals are action
/// semantics, so normalize them once here rather than in a later lookup.
fn resolveScopeVarBindingTopology(
    ctx: *JSContext,
    atom_id: atom.Atom,
    scope_level: i32,
) Error!ScopeVarBinding {
    const discovered = try resolveBindingTopologyResultImpl(
        true,
        ctx,
        atom_id,
        scope_level,
    );
    if (scope_level < 0) {
        return .{ .global = try ensureGlobalClosureVar(ctx, atom_id) };
    }
    if (try lookupTopLevelModuleLexicalClosureVar(ctx, atom_id, scope_level)) |ref_idx| {
        return .{ .closure = ref_idx };
    }
    return switch (discovered) {
        .local => |loc_idx| blk: {
            if (isEvalNonLexicalLocal(ctx, loc_idx)) break :blk try evalVarBinding(ctx, atom_id);
            if (try preferTopLevelModuleClassBinding(ctx, atom_id, loc_idx)) |ref_idx| {
                break :blk .{ .closure = ref_idx };
            }
            break :blk discovered;
        },
        else => discovered,
    };
}

/// A sloppy eval's own `var`: it lives in the caller's variable environment,
/// reached dynamically. A same-named catch parameter of a catch block the
/// eval runs in is nearer and found first (B.3.4).
fn evalVarBinding(ctx: *JSContext, atom_id: atom.Atom) Error!ScopeVarBinding {
    if (lookupClosureVar(ctx, atom_id)) |ref_idx| {
        if (closureVarKind(ctx, ref_idx) == .catch_) return .{ .closure = ref_idx };
    }
    return .{ .global = try ensureGlobalClosureVar(ctx, atom_id) };
}

const ScopeVarBindingKind = enum(u8) {
    local,
    arg,
    closure,
    global,
};

/// Register-sized result of the QuickJS-shaped binding walk.  The former
/// tagged-union pair was 10 bytes, which forced the outlined resolver to
/// return through caller-owned stack memory even though both identities
/// are u16 and the selected instruction is at most three bytes of
/// metadata.  Keep the semantic representation (`ScopeVarBinding` and
/// `ScopeVarAction`) at the API edges, but carry the hot result in one
/// integer exactly like QuickJS keeps `idx`, `var_idx`, and `op` in the
/// resolving routine.
const ResolvedScopeVarPlan = packed struct(u64) {
    binding_index: u16,
    action_index: u16,
    action_op_id: u8,
    action_size: u8,
    action_operand_size: u8,
    binding_kind: ScopeVarBindingKind,

    fn init(
        resolved_binding: ScopeVarBinding,
        resolved_action: ScopeVarAction,
    ) ResolvedScopeVarPlan {
        const base: ResolvedScopeVarPlan = .{
            .binding_index = 0,
            .action_index = resolved_action.index,
            .action_op_id = resolved_action.selected.op_id,
            .action_size = resolved_action.selected.size,
            .action_operand_size = resolved_action.selected.operand_size,
            .binding_kind = .local,
        };
        return switch (resolved_binding) {
            .local => |index| withBinding(base, .local, index),
            .arg => |index| withBinding(base, .arg, index),
            .closure => |index| withBinding(base, .closure, index),
            .global => |index| withBinding(base, .global, index),
        };
    }

    inline fn withBinding(
        base: ResolvedScopeVarPlan,
        kind: ScopeVarBindingKind,
        index: u16,
    ) ResolvedScopeVarPlan {
        var result = base;
        result.binding_kind = kind;
        result.binding_index = index;
        return result;
    }

    inline fn binding(self: ResolvedScopeVarPlan) ScopeVarBinding {
        return switch (self.binding_kind) {
            .local => .{ .local = self.binding_index },
            .arg => .{ .arg = self.binding_index },
            .closure => .{ .closure = self.binding_index },
            .global => .{ .global = self.binding_index },
        };
    }

    inline fn action(self: ResolvedScopeVarPlan) ScopeVarAction {
        var result: ScopeVarAction = .{
            .selected = .{
                .op_id = self.action_op_id,
                .size = self.action_size,
                .operand_size = self.action_operand_size,
            },
            .index = self.action_index,
        };
        // A TDZ-checked read-only write reads the binding it resolved to; the
        // size alone records that the check is present.
        if (self.action_op_id == opcode.op.throw_error and self.action_size != throw_error_instr_size) {
            result.read_only = .{
                .tdz_op = if (self.binding_kind == .local) opcode.op.get_loc_check else opcode.op.get_var_ref_check,
                .tdz_idx = self.binding_index,
            };
        }
        return result;
    }
};

/// QuickJS `resolve_scope_var` discovers the binding and selects the final
/// opcode in one routine. Keep the production V2 scope-op path equally
/// fused: its surface inlines this semantic walk into `lowerScopeVar`, so
/// discovery, action selection, and writing share one outlined compiler
/// entry. The exact-index compatibility wrapper below remains outlined,
/// while reference/private consumers retain the standalone topology API.
/// This is only a call-shape change; lookup order and data structures stay
/// identical to the linked-scope QuickJS path above.
/// `var_env_only` (the scope operand's no-dynamic-env bit) marks a store
/// that targets the variable environment itself rather than resolving
/// through the scope chain -- Annex B's copy of a block function in a
/// direct eval (B.3.2.3 `genv.SetMutableBinding`). Such a store skips a
/// nearer catch parameter of the same name, which an eval `var` would see.
inline fn resolveScopeVarPlan(
    ctx: *JSContext,
    atom_id: atom.Atom,
    scope_level: i32,
    op_id: u8,
    var_env_only: bool,
) Error!ResolvedScopeVarPlan {
    var binding = try @call(
        .always_inline,
        resolveScopeVarBindingTopology,
        .{ ctx, atom_id, scope_level },
    );
    if (var_env_only) switch (binding) {
        .closure => |ref_idx| if (closureVarKind(ctx, ref_idx) == .catch_ and (if (ctx.function_def) |fd| fd.is_eval else false)) {
            binding = .{ .global = try ensureGlobalClosureVar(ctx, atom_id) };
        },
        else => {},
    };
    const action = try @call(
        .always_inline,
        planResolvedScopeVarAction,
        .{ ctx, atom_id, op_id, binding },
    );
    return ResolvedScopeVarPlan.init(binding, action);
}

fn resolveBindingTopology(ctx: *JSContext, atom_id: atom.Atom, scope_level: i32) Error!void {
    _ = try resolveBindingTopologyResult(ctx, atom_id, scope_level);
}

const PrivateBindingOwner = struct {
    fd: *function_def_mod.FunctionDef,
    local_idx: u16,
};

fn privateBindingOwner(ctx: *const JSContext, res: PrivateFieldResolution) ?PrivateBindingOwner {
    var carrier = ctx.function_def orelse return null;
    if (!res.is_ref) {
        if (res.idx >= carrier.vars.len or !isPrivateVarKind(carrier.vars[res.idx].var_kind)) return null;
        return .{ .fd = carrier, .local_idx = res.idx };
    }

    var closure_idx = res.idx;
    var hops: usize = 0;
    while (hops < 64) : (hops += 1) {
        if (closure_idx >= carrier.closure_var.len) return null;
        const cv = carrier.closure_var[closure_idx];
        switch (cv.closureType()) {
            .local => {
                const owner = carrier.parent orelse return null;
                if (cv.var_idx >= owner.vars.len or !isPrivateVarKind(owner.vars[cv.var_idx].var_kind)) return null;
                return .{ .fd = owner, .local_idx = cv.var_idx };
            },
            .ref => {
                carrier = carrier.parent orelse return null;
                closure_idx = cv.var_idx;
            },
            .arg, .global, .global_ref, .global_decl, .module_decl, .module_import => return null,
        }
    }
    return null;
}

fn findPrivateSetterOwnerBinding(
    ctx: *const JSContext,
    private_atom: atom.Atom,
    owner: PrivateBindingOwner,
) ?u16 {
    if (owner.local_idx >= owner.fd.vars.len) return null;
    const private_vd = owner.fd.vars[owner.local_idx];
    for (owner.fd.vars, 0..) |vd, idx| {
        if (vd.scope_level != private_vd.scope_level or vd.var_kind != .private_setter) continue;
        if (isPrivateSetterCompanionName(ctx, private_atom, vd.var_name)) return @intCast(idx);
    }
    return null;
}

fn resolvePrivateBindingTopology(
    ctx: *JSContext,
    op_id: u8,
    atom_id: atom.Atom,
    scope_level: i32,
) Error!void {
    // Private operands use the ordinary lexical/capture machinery, but a
    // miss is never an ordinary global. Validate the VarKind immediately
    // after threading so the compatibility side-name tables cannot turn
    // an absent declaration into a binding.
    try resolveBindingTopology(ctx, atom_id, scope_level);
    const private = resolvePrivate(ctx, atom_id, scope_level, .name) orelse return error.ClosureVarNotFound;

    // Writes reach the setter through its `<set>` companion; so does a
    // brand check (`#x in o`) on a setter-only accessor.
    const needs_setter = switch (op_id) {
        opcode.op.scope_put_private_field => private.var_kind == .private_setter or private.var_kind == .private_getter_setter,
        opcode.op.scope_in_private_field => private.var_kind == .private_setter,
        else => false,
    };
    if (!needs_setter) return;
    if (resolvePrivate(ctx, atom_id, scope_level, .setter) != null) return;

    const owner = privateBindingOwner(ctx, private) orelse return error.ClosureVarNotFound;
    const setter_idx = findPrivateSetterOwnerBinding(ctx, atom_id, owner) orelse return error.ClosureVarNotFound;
    const current = ctx.function_def orelse return error.NoFunctionDef;
    if (owner.fd != current) _ = try threadParentLocalSource(current, owner.fd, setter_idx);
    if (resolvePrivate(ctx, atom_id, scope_level, .setter) == null) return error.ClosureVarNotFound;
}

/// The decision/writer surface `compiler/resolve_variables.zig`
/// consumes. Everything the compiler is allowed to reach is named once
/// here; nothing else in this namespace is exported.
pub const surface = struct {
    pub const ScopeOperandAlias = ScopeOperand;
    pub const ScopeVarActionAlias = ScopeVarAction;
    pub const ScopeVarBindingAlias = ScopeVarBinding;
    pub const ResolvedScopeVarPlanAlias = ResolvedScopeVarPlan;
    pub const EvalVarObjectProbeAlias = EvalVarObjectProbe;
    pub const EvalVarObjectProbeKindAlias = EvalVarObjectProbeKind;
    pub const PrivateFieldResolutionAlias = PrivateFieldResolution;

    pub const decodeScopeOperand = binding_rules.decodeScopeOperand;
    pub const markEvalCapturedVariables = binding_rules.markEvalCapturedVariables;
    pub const encodeEvalScopeHead = binding_rules.encodeEvalScopeHead;
    pub const resolveScopeVarBindingTopology = binding_rules.resolveScopeVarBindingTopology;
    pub const resolveScopeVarPlan = binding_rules.resolveScopeVarPlan;
    pub const resolvedScopeVarPlanBinding = ResolvedScopeVarPlan.binding;
    pub const resolvedScopeVarPlanAction = ResolvedScopeVarPlan.action;
    pub const planResolvedScopeVarAction = binding_rules.planResolvedScopeVarAction;
    pub const scopeVarActionSize = ScopeVarAction.size;
    pub const scopeVarActionAtomCount = ScopeVarAction.atomCount;
    pub const writeScopeVarAction = binding_rules.writeScopeVarAction;
    pub const functionHasDynamicEnvObjects = binding_rules.functionHasDynamicEnvObjects;
    pub const closureVarRangeHasDynamicEnvObjects = binding_rules.closureVarRangeHasDynamicEnvObjects;

    pub const scopeVarProbeKind = binding_rules.scopeVarProbeKind;
    pub const scopeVarProbeWireKind = EvalVarObjectProbeKind.wireKind;
    pub const evalVarObjectProbePlan = binding_rules.evalVarObjectProbePlan;
    pub const scopeVarDynamicProbeEligible = binding_rules.scopeVarDynamicProbeEligible;
    pub const evalVarObjectProbeAccessorSize = binding_rules.evalVarObjectProbeAccessorSize;
    pub const writeEvalVarObjectProbeAccessor = binding_rules.writeEvalVarObjectProbeAccessor;
    pub const localWithProbeIteratorInit = LocalWithProbeIterator.init;
    pub const localWithProbeIteratorNext = LocalWithProbeIterator.next;
    pub const closureDynamicEnvProbeIteratorInitResolved = binding_rules.closureDynamicEnvProbeIteratorInitResolved;
    pub const closureDynamicEnvProbeIteratorNext = ClosureDynamicEnvProbeIterator.next;
    pub const resolvedBindingStopsDynamicEnvProbes = binding_rules.resolvedBindingStopsDynamicEnvProbes;
    pub const resolvedBindingIsLocalFunctionName = binding_rules.resolvedBindingIsLocalFunctionName;
    pub const scopeUsesArgumentEnvironmentOnly = binding_rules.scopeUsesArgumentEnvironmentOnly;
    pub const evalVarObjectClosureProbe = binding_rules.evalVarObjectClosureProbe;
    pub const evalVarObjectProbeIsWith = binding_rules.evalVarObjectProbeIsWith;

    pub const loweredScopeDeleteVarIsDynamic = binding_rules.loweredScopeDeleteVarIsDynamic;
    pub const writeLoweredScopeDeleteVar = binding_rules.writeLoweredScopeDeleteVar;
    pub const loweredScopeGetRefPlan = binding_rules.loweredScopeGetRefPlan;
    pub const writeLoweredScopeGetRef = binding_rules.writeLoweredScopeGetRef;
    pub const loweredScopeMakeRefPlan = binding_rules.loweredScopeMakeRefPlan;
    pub const writeLoweredScopeMakeRef = binding_rules.writeLoweredScopeMakeRef;
    pub const markReferenceTakenBinding = binding_rules.markReferenceTakenBinding;
    pub const canOptimizeGlobalRefPutTail = binding_rules.canOptimizeGlobalRefPutTail;

    pub const resolvePrivateBindingTopology = binding_rules.resolvePrivateBindingTopology;
    pub const resolvePrivate = binding_rules.resolvePrivate;
    pub const writeLoweredPrivateField = binding_rules.writeLoweredPrivateField;
    pub const lowerEnterScope = binding_rules.lowerEnterScope;
    pub const lowerLeaveScope = binding_rules.lowerLeaveScope;

    pub const resolveEvalGlobalVarTargets = binding_rules.resolveEvalGlobalVarTargets;
    pub const hasDirectEvalLexicalRedeclaration = binding_rules.hasDirectEvalLexicalRedeclaration;
    pub const AtomWriter = binding_rules.AtomWriter;
    pub const throw_error_instr_size = binding_rules.throw_error_instr_size;
    pub const JS_THROW_VAR_REDECL = binding_rules.JS_THROW_VAR_REDECL;
};

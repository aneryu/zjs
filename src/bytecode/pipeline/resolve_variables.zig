//! resolve_variables
//!
//! Mirrors `resolve_variables` at `quickjs.c:33622`.
//!
//! Walks the lexical chain, resolves variable references, and replaces
//! temporary scope opcodes with their final forms.

const std = @import("std");
const atom = @import("../../core/atom.zig");
const memory = @import("../../core/memory.zig");
const bytecode_function = @import("../function.zig");
const function_def_mod = @import("../function_def.zig");
const opcode = @import("../opcode.zig");

// Global variable definition flags (mirrors quickjs.c)
const DEFINE_GLOBAL_LEX_VAR: u8 = 1 << 7;
const DEFINE_GLOBAL_FUNC_VAR: u8 = 1 << 6;
const DEFINE_GLOBAL_CONFIGURABLE: u8 = 1 << 5;
const DEFINE_GLOBAL_CONST: u8 = 1 << 4;
const EVAL_CLASS_FIELD_INITIALIZER_FLAG: u16 = 0x8000;
const EVAL_SCOPE_INDEX_MASK: u16 = 0x7fff;

pub const Error = error{
    InvalidBytecode,
    NoFunctionDef,
    NoParentScope,
    ClosureVarNotFound,
};

/// JSContext for variable resolution.
pub const JSContext = struct {
    function: *bytecode_function.Bytecode,
    memory: *memory.MemoryAccount,
    atoms: *atom.AtomTable,
    /// Optional FunctionDef driving local-slot lookup. When non-null,
    /// `resolve_variables` lowers `scope_get_var` / `scope_put_var` to
    /// `get_loc` / `put_loc` (3-byte loc form) for any atom that
    /// resolves to a `VarDef` in `function_def.vars`. References that
    /// don't resolve fall back to global `get_var` / `put_var` (5-byte
    /// atom form), matching QuickJS `resolve_scope_var`
    /// (`quickjs.c:32377`) when `JSClosureType.GLOBAL` is selected.
    function_def: ?*const function_def_mod.FunctionDef = null,

    pub fn init(function: *bytecode_function.Bytecode) JSContext {
        return .{
            .function = function,
            .memory = function.memory,
            .atoms = function.atoms,
        };
    }

    pub fn initWithFunctionDef(
        function: *bytecode_function.Bytecode,
        fd: *const function_def_mod.FunctionDef,
    ) JSContext {
        return .{
            .function = function,
            .memory = function.memory,
            .atoms = function.atoms,
            .function_def = fd,
        };
    }
};

/// Run variable resolution on a function.
///
/// Input: a Bytecode whose code contains temporary scope opcodes only.
/// Output: the same Bytecode with temporary opcodes replaced by final forms.
///
/// This implementation:
/// - Linear scan over byte_code
/// - Replaces scope_get_var → get_var
/// - Replaces scope_put_var → put_var
/// - Replaces scope_get_var_undef → get_var_undef
/// - Drops enter_scope/leave_scope
///
/// Full QuickJS alignment (closure variables, TDZ, eval) will be added
/// when FunctionDef is integrated into the parser.
/// Total byte length (opcode + operands) for `op_id` in final-form
/// (non-temp) encoding, from the generated metadata table. Returns 1
/// for ids with no table entry so callers can safely fall through
/// unknown opcodes one byte at a time (matching QuickJS's unknown-op
/// pass-through). Temp opcodes this pass consumes are special-cased
/// at each walk site (or use `inputInstrSizeForRefTailScan`).
fn instrSize(op_id: u8) usize {
    const total = opcode.sizeOf(op_id);
    return if (total == 0) 1 else total;
}

/// Returns true if the opcode at `op_id` is a temporary
/// variable-scope opcode that `resolve_variables` needs to lower.
/// All four are 7-byte `atom_u16` forms.
fn isScopeVarOp(op_id: u8) bool {
    return op_id == opcode.op.scope_get_var or
        op_id == opcode.op.scope_put_var or
        op_id == opcode.op.scope_get_var_undef or
        op_id == opcode.op.scope_put_var_init;
}

/// Returns true if the opcode is a scope_delete_var / scope_get_ref
/// temporary. Both are 7-byte `atom_u16` forms, same layout as the
/// basic scope_*_var family. `scope_make_ref` is an 11-byte
/// `atom_label_u16` form and is handled separately.
fn isScopeRefOp(op_id: u8) bool {
    return op_id == opcode.op.scope_get_ref or
        op_id == opcode.op.scope_delete_var;
}

/// Returns true if the opcode at `op_id` is a temporary
/// private field opcode that `resolve_variables` needs to lower.
fn isScopePrivateFieldOp(op_id: u8) bool {
    return op_id == opcode.op.scope_get_private_field or
        op_id == opcode.op.scope_get_private_field2 or
        op_id == opcode.op.scope_put_private_field or
        op_id == opcode.op.scope_in_private_field;
}

fn isScopePrivateFieldAt(func: *const bytecode_function.Bytecode, pc: usize, atom_operand_idx: usize) bool {
    if (pc + 7 > func.code.len) return false;
    if (!isScopePrivateFieldOp(func.code[pc])) return false;
    if (atom_operand_idx >= func.atom_operands.len) return false;
    const encoded_atom = std.mem.readInt(u32, func.code[pc + 1 ..][0..4], .little);
    return func.atom_operands[atom_operand_idx] == encoded_atom;
}

/// Maps a scope_* private field opcode to its final form.
fn lowerScopePrivateFieldOp(op_id: u8) u8 {
    return switch (op_id) {
        opcode.op.scope_get_private_field => opcode.op.get_private_field,
        opcode.op.scope_get_private_field2 => opcode.op.get_private_field,
        opcode.op.scope_put_private_field => opcode.op.put_private_field,
        opcode.op.scope_in_private_field => opcode.op.private_in,
        else => unreachable,
    };
}

/// Maps a scope_* var opcode to its global-form counterpart (5-byte
/// atom form). Used when the variable doesn't resolve to a local
/// slot in `function_def.vars`. `scope_put_var_init` lowers to
/// `put_var_init` (initialise-once binding for top-level
/// `let`/`const`); the others use their plain counterparts.
fn lowerScopeVarOpGlobal(op_id: u8) u8 {
    return switch (op_id) {
        opcode.op.scope_get_var => opcode.op.get_var,
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
        opcode.op.scope_get_var => opcode.op.get_loc,
        opcode.op.scope_put_var => opcode.op.put_loc,
        opcode.op.scope_get_var_undef => opcode.op.get_loc,
        opcode.op.scope_put_var_init => opcode.op.put_loc,
        else => unreachable,
    };
}

/// Shortest-form local-slot opcode triple. Mirrors `put_short_code`
/// (`quickjs.c:34140`):
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

fn scopeChainContains(fd: *const function_def_mod.FunctionDef, start_scope: i32, target_scope: i32) bool {
    var scope_idx = start_scope;
    while (scope_idx >= 0 and @as(usize, @intCast(scope_idx)) < fd.scopes.len) {
        if (scope_idx == target_scope) return true;
        scope_idx = fd.scopes[@intCast(scope_idx)].parent;
    }
    return false;
}

fn lookupClosureVar(ctx: *const JSContext, atom_id: u32) ?u16 {
    const fd = ctx.function_def orelse return null;
    for (fd.closure_var, 0..) |cv, idx| {
        if (cv.var_name == atom_id) return @intCast(idx);
    }
    var maybe_parent = fd.parent;
    var visible_scope_level = fd.parent_scope_level;
    while (maybe_parent) |parent| {
        for (parent.closure_var, 0..) |cv, idx| {
            if (cv.var_name == atom_id) return @intCast(idx);
        }
        if (findVisibleParentVar(parent, atom_id, visible_scope_level)) |parent_var| {
            return @intCast(parent_var);
        }
        const parent_arg = parent.findArg(atom_id);
        if (parent_arg >= 0) return @intCast(parent_arg);
        visible_scope_level = parent.parent_scope_level;
        maybe_parent = parent.parent;
    }
    return null;
}

fn lookupTopLevelModuleLexicalClosureVar(ctx: *const JSContext, atom_id: u32, scope_level: i32) ?u16 {
    if (scope_level != 0) return null;
    const fd = ctx.function_def orelse return null;
    for (fd.closure_var, 0..) |cv, idx| {
        if (cv.var_name == atom_id and cv.closure_type == .module_decl and cv.is_lexical) return @intCast(idx);
    }
    return null;
}

fn preferTopLevelModuleClassBinding(ctx: *const JSContext, atom_id: u32, loc_idx: u16) ?u16 {
    const fd = ctx.function_def orelse return null;
    if (loc_idx >= fd.vars.len) return null;
    const vd = fd.vars[loc_idx];
    if (vd.var_name != atom_id or vd.scope_level != 0 or !vd.is_lexical or !vd.is_const) return null;
    for (fd.closure_var, 0..) |cv, idx| {
        if (cv.var_name == atom_id and cv.closure_type == .module_decl and cv.is_lexical and !cv.is_const) return @intCast(idx);
    }
    return null;
}

fn closureVarKind(ctx: *const JSContext, idx: u16) function_def_mod.VarKind {
    const fd = ctx.function_def orelse return .normal;
    if (idx >= fd.closure_var.len) return .normal;
    return fd.closure_var[idx].var_kind;
}

fn closureVarKindForAtom(ctx: *const JSContext, atom_id: u32) function_def_mod.VarKind {
    const fd = ctx.function_def orelse return .normal;
    for (fd.closure_var) |cv| {
        if (cv.var_name == atom_id) return cv.var_kind;
    }
    var maybe_parent = fd.parent;
    var visible_scope_level = fd.parent_scope_level;
    while (maybe_parent) |parent| {
        for (parent.closure_var) |cv| {
            if (cv.var_name == atom_id) return cv.var_kind;
        }
        if (findVisibleParentVar(parent, atom_id, visible_scope_level)) |parent_var| {
            return parent.vars[@intCast(parent_var)].var_kind;
        }
        visible_scope_level = parent.parent_scope_level;
        maybe_parent = parent.parent;
    }
    return .normal;
}

fn closureVarIsLexicalForAtom(ctx: *const JSContext, atom_id: u32) bool {
    const fd = ctx.function_def orelse return true;
    for (fd.closure_var) |cv| {
        if (cv.var_name == atom_id) return cv.is_lexical;
    }
    var maybe_parent = fd.parent;
    while (maybe_parent) |parent| {
        for (parent.closure_var) |cv| {
            if (cv.var_name == atom_id) return cv.is_lexical;
        }
        maybe_parent = parent.parent;
    }
    return true;
}

fn lowerScopeVarOpForClosure(ctx: *const JSContext, atom_id: u32, ref_idx: u16, op_id: u8) u8 {
    var ref_op = lowerScopeVarOpClosure(op_id);
    if (op_id == opcode.op.scope_get_var and (closureVarKind(ctx, ref_idx) == .function_decl or closureVarKindForAtom(ctx, atom_id) == .function_decl or !closureVarIsLexicalForAtom(ctx, atom_id))) {
        ref_op = opcode.op.get_var_ref;
    }
    if (op_id == opcode.op.scope_put_var and !closureVarIsLexicalForAtom(ctx, atom_id)) {
        ref_op = opcode.op.put_var_ref;
    }
    return ref_op;
}

fn findVisibleParentVar(fd: *const function_def_mod.FunctionDef, atom_id: u32, visible_scope_level: i32) ?i32 {
    var i: usize = fd.vars.len;
    while (i > 0) {
        i -= 1;
        const vd = fd.vars[i];
        if (vd.var_name != atom_id) continue;
        if (vd.var_kind == .function_name or scopeChainContains(fd, visible_scope_level, vd.scope_level)) return @intCast(i);
    }
    return null;
}

const PrivateFieldResolution = struct {
    idx: u16,
    is_ref: bool,
    var_kind: function_def_mod.VarKind,
};

fn resolvePrivateField(ctx: *const JSContext, atom_id: u32, scope_level: i32) ?PrivateFieldResolution {
    const fd = ctx.function_def orelse return null;

    var scope_idx = scope_level;
    while (scope_idx >= 0 and @as(usize, @intCast(scope_idx)) < fd.scopes.len) {
        var idx: i32 = fd.scopes[@intCast(scope_idx)].first;
        while (idx >= 0 and @as(usize, @intCast(idx)) < fd.vars.len) {
            const vd = fd.vars[@intCast(idx)];
            if (vd.var_name == atom_id and isPrivateVarKind(vd.var_kind)) {
                return .{ .idx = @intCast(idx), .is_ref = false, .var_kind = vd.var_kind };
            }
            idx = vd.scope_next;
        }
        scope_idx = fd.scopes[@intCast(scope_idx)].parent;
    }

    for (fd.closure_var, 0..) |cv, idx| {
        if (cv.var_name == atom_id and isPrivateVarKind(cv.var_kind)) {
            return .{ .idx = @intCast(idx), .is_ref = true, .var_kind = cv.var_kind };
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

fn privateAccessorSize(ctx: *const JSContext, res: PrivateFieldResolution) usize {
    return if (res.is_ref) selectVarRefForm(ctx, opcode.op.get_var_ref, res.idx).size else selectLocForm(ctx, opcode.op.get_loc, res.idx).size;
}

fn writePrivateAccessor(ctx: *const JSContext, output: []u8, out_idx: *usize, res: PrivateFieldResolution) void {
    if (res.is_ref) {
        const form = selectVarRefForm(ctx, opcode.op.get_var_ref, res.idx);
        output[out_idx.*] = form.op_id;
        switch (form.operand_size) {
            0 => {},
            2 => std.mem.writeInt(u16, output[out_idx.* + 1 ..][0..2], res.idx, .little),
            else => unreachable,
        }
        out_idx.* += form.size;
        return;
    }

    const form = selectLocForm(ctx, opcode.op.get_loc, res.idx);
    output[out_idx.*] = form.op_id;
    switch (form.operand_size) {
        0 => {},
        1 => output[out_idx.* + 1] = @intCast(res.idx),
        2 => std.mem.writeInt(u16, output[out_idx.* + 1 ..][0..2], res.idx, .little),
        else => unreachable,
    }
    out_idx.* += form.size;
}

fn loweredPrivateFieldSize(ctx: *const JSContext, op_id: u8, res: PrivateFieldResolution) !usize {
    if (res.var_kind != .private_field and op_id != opcode.op.scope_in_private_field) return error.ClosureVarNotFound;
    const accessor_size = privateAccessorSize(ctx, res);
    return switch (op_id) {
        opcode.op.scope_get_private_field => accessor_size + 1,
        opcode.op.scope_get_private_field2 => 1 + accessor_size + 1,
        opcode.op.scope_put_private_field => accessor_size + 1,
        opcode.op.scope_in_private_field => accessor_size + 1,
        else => unreachable,
    };
}

fn writeLoweredPrivateField(ctx: *const JSContext, output: []u8, out_idx: *usize, op_id: u8, res: PrivateFieldResolution) !void {
    if (res.var_kind != .private_field and op_id != opcode.op.scope_in_private_field) return error.ClosureVarNotFound;
    if (op_id == opcode.op.scope_get_private_field2) {
        output[out_idx.*] = opcode.op.dup;
        out_idx.* += 1;
    }
    writePrivateAccessor(ctx, output, out_idx, res);
    output[out_idx.*] = lowerScopePrivateFieldOp(op_id);
    out_idx.* += 1;
}

/// True if the local slot `loc_idx` is captured by a closure — either the
/// parser marked it (`ensureClosureChain` sets `VarDef.is_captured`, the
/// `capture_var` equivalent of quickjs.c:33022) or a child FunctionDef
/// references the slot through its closure_var table (retrofit capture
/// paths that do not set the flag).
pub fn localIsCaptured(fd: *const function_def_mod.FunctionDef, loc_idx: u16) bool {
    if (loc_idx < fd.vars.len and fd.vars[loc_idx].is_captured) return true;
    for (fd.child_list) |child| {
        for (child.closure_var) |cv| {
            if ((cv.closure_type == .local or cv.closure_type == .ref) and cv.var_idx == loc_idx) return true;
        }
    }
    return false;
}

/// Lexical vars with `.normal` kind get their TDZ bit re-armed on scope
/// entry. Block function declarations are excluded: their inline
/// `fclosure` init does not always clear the TDZ bit, so re-arming them
/// would fault later reads (QuickJS re-instantiates them in
/// `enter_scope` instead, quickjs.c:34488).
fn varNeedsTdzRearm(vd: function_def_mod.VarDef) bool {
    return vd.is_lexical and vd.var_kind == .normal;
}

/// Byte size of the `enter_scope <scope>` lowering. Mirrors the QuickJS
/// `OP_enter_scope` case (quickjs.c:34476): one `set_loc_uninitialized`
/// per lexical var of the scope. In addition zjs emits one `close_loc`
/// per captured var: QuickJS detaches captured stack slots at
/// `OP_leave_scope` (quickjs.c:34510) and at break/continue jump sites
/// (`close_scopes`, quickjs.c:27948); zjs's boxed-cell model instead
/// detaches at scope *entry*, which dominates every re-entry path
/// (normal back-edge, `continue`, jumps out of inner blocks) with a
/// single emission site. This is observationally equivalent because
/// local slots are never reused and a detached cell is only reachable
/// through the closures that captured it.
fn enterScopeRefreshSize(ctx: *const JSContext, scope: i32) usize {
    const fd = ctx.function_def orelse return 0;
    if (scope < 0 or @as(usize, @intCast(scope)) >= fd.scopes.len) return 0;
    var total: usize = 0;
    var idx = fd.scopes[@intCast(scope)].first;
    while (idx >= 0 and @as(usize, @intCast(idx)) < fd.vars.len) {
        const vd = fd.vars[@intCast(idx)];
        if (vd.scope_level != scope) break;
        if (localIsCaptured(fd, @intCast(idx))) total += 3;
        if (varNeedsTdzRearm(vd)) total += 3;
        idx = vd.scope_next;
    }
    return total;
}

/// Emit the `enter_scope` lowering described in `enterScopeRefreshSize`.
fn writeEnterScopeRefresh(ctx: *const JSContext, output: []u8, out_idx: *usize, scope: i32) void {
    const fd = ctx.function_def orelse return;
    if (scope < 0 or @as(usize, @intCast(scope)) >= fd.scopes.len) return;
    var idx = fd.scopes[@intCast(scope)].first;
    while (idx >= 0 and @as(usize, @intCast(idx)) < fd.vars.len) {
        const vd = fd.vars[@intCast(idx)];
        if (vd.scope_level != scope) break;
        const loc_idx: u16 = @intCast(idx);
        if (localIsCaptured(fd, loc_idx)) {
            output[out_idx.*] = opcode.op.close_loc;
            std.mem.writeInt(u16, output[out_idx.* + 1 ..][0..2], loc_idx, .little);
            out_idx.* += 3;
        }
        if (varNeedsTdzRearm(vd)) {
            output[out_idx.*] = opcode.op.set_loc_uninitialized;
            std.mem.writeInt(u16, output[out_idx.* + 1 ..][0..2], loc_idx, .little);
            out_idx.* += 3;
        }
        idx = vd.scope_next;
    }
}

fn isAncestorLocalOrArg(ctx: *const JSContext, atom_id: u32) bool {
    const fd = ctx.function_def orelse return false;
    var maybe_parent = fd.parent;
    var depth: usize = 1;
    while (maybe_parent) |parent| {
        if (parent.findVar(atom_id) >= 0) return depth > 1;
        if (parent.findArg(atom_id) >= 0) return true;
        maybe_parent = parent.parent;
        depth += 1;
    }
    return false;
}

fn lowerScopeVarOpClosure(op_id: u8) u8 {
    return switch (op_id) {
        opcode.op.scope_get_var => opcode.op.get_var_ref_check,
        opcode.op.scope_get_var_undef => opcode.op.get_var_ref,
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

fn lookupArg(ctx: *const JSContext, atom_id: u32) ?u16 {
    const fd = ctx.function_def orelse return null;
    const idx = fd.findArg(atom_id);
    if (idx < 0) return null;
    return @intCast(idx);
}

fn scopedLocalShadowsArg(ctx: *const JSContext, loc_idx: u16) bool {
    const fd = ctx.function_def orelse return false;
    if (loc_idx >= fd.vars.len) return false;
    const vd = fd.vars[loc_idx];
    return vd.is_lexical and vd.scope_level > 0;
}

fn lowerScopeVarOpArg(op_id: u8) ?u8 {
    return switch (op_id) {
        opcode.op.scope_get_var, opcode.op.scope_get_var_undef => opcode.op.get_arg,
        opcode.op.scope_put_var, opcode.op.scope_put_var_init => opcode.op.put_arg,
        else => null,
    };
}

/// If the FunctionDef has a `VarDef` for `atom_id`, return its var
/// index. Mirrors a simplified `find_var` (`quickjs.c:23378`) — this
/// scan ignores arg vs var split. Full scope-chain walking with closure
/// classification remains tied to the eval / closure residual tests.
fn lookupLocal(ctx: *const JSContext, atom_id: u32) ?u16 {
    const fd = ctx.function_def orelse return null;
    const idx = fd.findVar(atom_id);
    if (idx < 0) return null;
    return @intCast(idx);
}

/// Resolve a variable by walking the current function's scope at
/// `scope_level`. Mirrors the local-only portion of
/// `resolve_scope_var` (`quickjs.c:32377-32420`). Returns the local
/// var index if found, or null otherwise.
///
/// NOTE: parent-scope traversal + `get_closure_var` synthesis is still
/// incomplete for the remaining eval / arguments interaction debts. We keep
/// this fallback local-only where the caller has not provided closure metadata.
fn resolveScopeVar(ctx: *const JSContext, atom_id: u32, scope_level: i32) ?u16 {
    const fd = ctx.function_def orelse return null;

    // Check the current scope level chain.
    var scope_idx = scope_level;
    while (scope_idx >= 0 and @as(usize, @intCast(scope_idx)) < fd.scopes.len) {
        var idx: i32 = fd.scopes[@intCast(scope_idx)].first;
        while (idx >= 0 and @as(usize, @intCast(idx)) < fd.vars.len) {
            const vd = &fd.vars[@intCast(idx)];
            if (vd.var_name == atom_id) return @intCast(idx);
            idx = vd.scope_next;
        }
        scope_idx = fd.scopes[@intCast(scope_idx)].parent;
    }

    // Fall back to a flat var scan for legacy callers that don't
    // record scope_level on every emission.
    if (fd.use_short_opcodes) {
        var flat_i: usize = fd.vars.len;
        while (flat_i > 0) {
            flat_i -= 1;
            const v = fd.vars[flat_i];
            if (v.var_name == atom_id and v.scope_level == scope_level) return @intCast(flat_i);
        }
        return null;
    }
    const flat = fd.findVar(atom_id);
    if (flat < 0) return null;
    const vd = fd.vars[@intCast(flat)];
    if (vd.scope_level != scope_level and (vd.is_lexical or vd.scope_level != 0)) return null;
    return @intCast(flat);
}

const LocalOrArg = union(enum) {
    local: u16,
    arg: u16,
};

fn resolveLocalOrArg(ctx: *const JSContext, atom_id: u32, scope_level: i32) ?LocalOrArg {
    const local_idx = resolveScopeVar(ctx, atom_id, scope_level);
    if (local_idx) |idx| {
        if (scopedLocalShadowsArg(ctx, idx)) return .{ .local = idx };
    }
    if (lookupArg(ctx, atom_id)) |arg_idx| return .{ .arg = arg_idx };
    if (local_idx) |idx| return .{ .local = idx };
    return null;
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
    if (!fd.is_eval and !bytecodeFunctionIsEval(ctx)) return false;
    if (loc_idx >= fd.vars.len) return false;
    return !fd.vars[loc_idx].is_lexical;
}

fn bytecodeFunctionIsEval(ctx: *const JSContext) bool {
    const name = ctx.atoms.name(ctx.function.name) orelse return false;
    return std.mem.eql(u8, name, "<eval>");
}

fn isConstLocal(ctx: *const JSContext, loc_idx: u16) bool {
    const fd = ctx.function_def orelse return false;
    if (loc_idx >= fd.vars.len) return false;
    return fd.vars[loc_idx].is_const;
}

fn localTdzEmittedAtDecl(ctx: *const JSContext, loc_idx: u16) bool {
    const fd = ctx.function_def orelse return false;
    if (loc_idx >= fd.vars.len) return false;
    return fd.vars[loc_idx].tdz_emitted_at_decl;
}

fn isTopLevelGlobalLexical(ctx: *const JSContext, atom_id: u32, loc_idx: u16) bool {
    const fd = ctx.function_def orelse return false;
    if (!fd.persist_global_lexical) return false;
    if (loc_idx >= fd.vars.len) return false;
    const vd = fd.vars[loc_idx];
    if (!vd.is_lexical or vd.scope_level != 0) return false;
    for (fd.global_vars) |gv| {
        if (gv.var_name == atom_id and gv.is_lexical and gv.scope_level == 0) return true;
    }
    return false;
}

fn useUncheckedLexicalLocals(ctx: *const JSContext) bool {
    const fd = ctx.function_def orelse return false;
    return fd.use_short_opcodes;
}

/// Promote a Phase-1 var op to its TDZ-checked counterpart for
/// lexical locals. Mirrors the `_check` family in QuickJS:
/// - `scope_get_var` / `scope_get_var_undef` → `get_loc_check`
///   (throws ReferenceError if slot is uninitialised).
/// - `scope_put_var` → `put_loc_check` (throws ReferenceError if
///   uninitialised, then stores).
/// - `scope_put_var_init` → `put_loc_check_init` (stores and
///   clears the uninitialised flag).
///
/// All check variants are 3-byte u16 forms (no short variants in
/// QuickJS), so callers must NOT run `selectShortLoc` on the result.
fn lowerScopeVarOpLexical(op_id: u8) u8 {
    return switch (op_id) {
        opcode.op.scope_get_var => opcode.op.get_loc_check,
        opcode.op.scope_get_var_undef => opcode.op.get_loc_check,
        opcode.op.scope_put_var => opcode.op.put_loc_check,
        opcode.op.scope_put_var_init => opcode.op.put_loc_check_init,
        else => unreachable,
    };
}

/// Returns true if `op_id`'s table format carries a leading atom
/// operand at `bytes[1..5]`. Used to track the atom-operand list in
/// lockstep with bytecode rewriting.
fn hasAtomOperand(op_id: u8) bool {
    const fmt = opcode.formatOf(op_id);
    return fmt == .atom or fmt == .atom_u8 or fmt == .atom_u16 or
        fmt == .atom_label_u8 or fmt == .atom_label_u16;
}

/// Describes the location and kind of an absolute label operand
/// embedded in the output bytecode. The parser emits jump targets as
/// absolute u32 byte offsets (`emitForwardJump` / `emitBackwardJump`);
/// when `resolve_variables` shrinks opcodes that precede those
/// targets, the stored absolute values go stale. We collect each
/// jump's operand position here during the main walk, then rewrite
/// the targets at the end using the old→new pc map.
const JumpSite = struct {
    /// Byte offset within the *output* buffer where the u32 target
    /// operand begins. Always points to a 4-byte little-endian field.
    operand_pos: usize,
};

const GLOBAL_REF_TAIL_NONE: u8 = 0;
const GLOBAL_REF_TAIL_PUT: u8 = 1;
const GLOBAL_REF_TAIL_DUP_PUT: u8 = 2;

const GlobalRefPutTail = struct {
    pc: usize,
    original_size: usize,
    kind: u8,
};

/// Returns the byte offset within this opcode of the absolute u32
/// label operand, or `null` if the format has no such operand. Only
/// the `.label` format (u32 absolute target) is relevant for the
/// interim pipeline — the parser does not yet emit label8 / label16
/// short forms.
fn labelOperandOffset(op_id: u8) ?usize {
    const fmt = opcode.formatOf(op_id);
    return switch (fmt) {
        .label => 1, // u32 target at bytes[1..5]
        .atom_label_u8, .atom_label_u16 => 5, // atom at bytes[1..5], target at bytes[5..9]
        else => null,
    };
}

fn globalRefPutTailReplacementSize(kind: u8) usize {
    return switch (kind) {
        GLOBAL_REF_TAIL_PUT => 5,
        GLOBAL_REF_TAIL_DUP_PUT => 6,
        else => 0,
    };
}

fn decodeGlobalRefPutTail(code: []const u8, pc: usize) ?GlobalRefPutTail {
    if (pc >= code.len) return null;
    if (code[pc] == opcode.op.put_ref_value) {
        return .{ .pc = pc, .original_size = 1, .kind = GLOBAL_REF_TAIL_PUT };
    }
    if (pc + 2 > code.len or code[pc + 1] != opcode.op.put_ref_value) return null;
    return switch (code[pc]) {
        opcode.op.insert3 => .{ .pc = pc, .original_size = 2, .kind = GLOBAL_REF_TAIL_DUP_PUT },
        opcode.op.nop, opcode.op.perm4, opcode.op.rot3l => .{ .pc = pc, .original_size = 2, .kind = GLOBAL_REF_TAIL_PUT },
        else => null,
    };
}

/// Instruction size for the Phase 1 input stream this pass consumes:
/// temp opcodes in the overlap range size as their temp forms
/// (`opcode.sizeOfPhase1`). Returns null when the stream cannot be
/// decoded, stopping the tail scan.
fn inputInstrSizeForRefTailScan(code: []const u8, pc: usize) ?usize {
    if (pc >= code.len) return null;
    const size: usize = opcode.sizeOfPhase1(code[pc]);
    if (size == 0 or pc + size > code.len) return null;
    return size;
}

fn stopsGlobalRefTailScan(op_id: u8) bool {
    if (op_id == opcode.op.scope_make_ref or
        op_id == opcode.op.scope_get_ref or
        op_id == opcode.op.scope_delete_var or
        op_id == opcode.op.eval or
        op_id == opcode.op.apply_eval or
        op_id == opcode.op.@"return" or
        op_id == opcode.op.return_undef or
        op_id == opcode.op.return_async or
        op_id == opcode.op.throw or
        op_id == opcode.op.goto or
        op_id == opcode.op.goto8 or
        op_id == opcode.op.goto16 or
        op_id == opcode.op.if_false or
        op_id == opcode.op.if_false8 or
        op_id == opcode.op.if_true or
        op_id == opcode.op.if_true8 or
        op_id == opcode.op.@"catch" or
        op_id == opcode.op.label or
        op_id == opcode.op.gosub or
        op_id == opcode.op.ret or
        op_id == opcode.op.call or
        op_id == opcode.op.call0 or
        op_id == opcode.op.call1 or
        op_id == opcode.op.call2 or
        op_id == opcode.op.call3 or
        op_id == opcode.op.call_method or
        op_id == opcode.op.tail_call or
        op_id == opcode.op.tail_call_method)
    {
        return true;
    }
    return false;
}

fn findGlobalRefPutTail(code: []const u8, make_ref_pc: usize) ?GlobalRefPutTail {
    if (make_ref_pc + 11 > code.len or code[make_ref_pc] != opcode.op.scope_make_ref) return null;
    const label_pc = std.mem.readInt(u32, code[make_ref_pc + 5 ..][0..4], .little);
    if (label_pc > make_ref_pc and label_pc < code.len) {
        if (decodeGlobalRefPutTail(code, @intCast(label_pc))) |tail| return tail;
    }

    var pc = make_ref_pc + 11;
    var steps: usize = 0;
    while (pc < code.len and steps < 16) : (steps += 1) {
        if (decodeGlobalRefPutTail(code, pc)) |tail| return tail;
        const op_id = code[pc];
        if (stopsGlobalRefTailScan(op_id)) return null;
        const size = inputInstrSizeForRefTailScan(code, pc) orelse return null;
        pc += size;
    }
    return null;
}

fn scopeMakeRefResolvesToGlobal(ctx: *const JSContext, atom_id: u32, scope_level: i16) bool {
    if (lookupTopLevelModuleLexicalClosureVar(ctx, atom_id, scope_level) != null) return false;
    if (resolveLocalOrArg(ctx, atom_id, scope_level) != null) return false;
    if (lookupClosureVar(ctx, atom_id) != null) return false;
    return true;
}

fn functionIsStrict(ctx: *const JSContext) bool {
    if (ctx.function_def) |fd| return fd.is_strict_mode;
    return ctx.function.flags.is_strict or ctx.function.flags.runtime_strict;
}

fn functionDeclaresGlobalVar(ctx: *const JSContext, atom_id: u32) bool {
    const fd = ctx.function_def orelse return false;
    for (fd.global_vars) |global_var| {
        if (global_var.var_name == atom_id) return true;
    }
    return false;
}

fn canOptimizeGlobalRefPutTail(ctx: *const JSContext, atom_id: u32) bool {
    return !functionIsStrict(ctx) or functionDeclaresGlobalVar(ctx, atom_id);
}

pub fn run(ctx: *JSContext) !void {
    const func = ctx.function;

    // First pass: compute output size (in bytes) and atom count.
    // Temporary scope-var opcodes shrink from 7 bytes to 5 bytes. The
    // enter_scope / leave_scope pair (3 bytes each) is dropped. All
    // other opcodes copy through at their table-reported size.
    //
    // We also count the number of jump opcodes (format `.label`) so
    // we can size the pc-map and the jump-site list ahead of the
    // second pass.
    //
    // Global vars pre-pass: each global var first emits
    // OP_check_define_var (all checks must run before any binding is
    // created), then OP_define_var. Both forms are 6 bytes:
    // 1 opcode + 4 atom + 1 flags.
    var global_vars_size: usize = 0;
    var global_vars_atom_count: usize = 0;
    if (ctx.function_def) |fd| {
        if (fd.global_var_count > 0) {
            global_vars_size = @as(usize, @intCast(fd.global_var_count)) * 12;
            global_vars_atom_count = @as(usize, @intCast(fd.global_var_count)) * 2;
        }
    }

    // Count lexical locals so we can size the TDZ prologue. Each
    // lexical slot needs an `OP_set_loc_uninitialized <u16 idx>`
    // (3 bytes) emitted before the body so `get_loc_check` knows
    // the slot is in TDZ. `var` slots don't need this — they're
    // already undefined.
    var prologue_lexical_count: usize = 0;
    if (ctx.function_def) |fd| {
        for (fd.vars) |v| {
            if (v.is_lexical and !v.tdz_emitted_at_decl) prologue_lexical_count += 1;
        }
    }
    const prologue_size: usize = prologue_lexical_count * 3;
    var top_level_closure_init_size: usize = 0;
    var child_decl_init_size: usize = 0;
    if (ctx.function_def) |fd| {
        for (fd.child_list) |child| {
            if (child.emit_top_level_closure_init) {
                if (child.parent_cpool_idx < 0 or child.top_level_closure_var_idx < 0) continue;
                top_level_closure_init_size += 2 + selectVarRefForm(ctx, opcode.op.put_var_ref, @intCast(child.top_level_closure_var_idx)).size;
                continue;
            }
            if (child.child_decl_emit_inline) continue;
            if (child.func_type != .statement) continue;
            const arg_idx_i = if (child.child_decl_force_local_init) -1 else fd.findArg(child.func_name);
            const form = if (arg_idx_i >= 0)
                selectArgForm(ctx, opcode.op.put_arg, @intCast(arg_idx_i))
            else blk: {
                const var_idx_i = if (child.child_decl_var_idx >= 0) child.child_decl_var_idx else fd.findVar(child.func_name);
                if (var_idx_i < 0) continue;
                break :blk selectLocForm(ctx, if (child.child_decl_init_keep_value) opcode.op.set_loc else opcode.op.put_loc, @intCast(var_idx_i));
            };
            child_decl_init_size += 2 + form.size;
        }
    }

    const init_bypassed = if (ctx.function_def) |fd| blk: {
        const bytes = try ctx.memory.alloc(bool, fd.vars.len);
        // The block below allocates and can fail with InvalidBytecode; the
        // owning `defer` only binds after `break :blk`, so error exits inside
        // the block must release `bytes` here (found by test-oom injection).
        errdefer if (bytes.len != 0) ctx.memory.free(bool, bytes);
        @memset(bytes, false);

        // Pre-pass: find init_pc for each var and check if any forward jump bypasses it
        const init_pc = try ctx.memory.alloc(?usize, fd.vars.len);
        @memset(init_pc, null);
        defer ctx.memory.free(?usize, init_pc);

        // First scan to find init_pc
        var pc: usize = 0;
        var scan_atom_idx: usize = 0;
        while (pc < func.code.len) {
            const op = func.code[pc];
            if (op == opcode.op.eval) {
                if (pc + 5 > func.code.len) return error.InvalidBytecode;
                pc += 5;
            } else if (op == opcode.op.apply_eval) {
                if (pc + 2 > func.code.len) return error.InvalidBytecode;
                pc += 2;
            } else if (isScopeVarOp(op)) {
                if (pc + 7 > func.code.len) return error.InvalidBytecode;
                const atom_id = std.mem.readInt(u32, func.code[pc + 1 ..][0..4], .little);
                const scope_level = std.mem.readInt(i16, func.code[pc + 5 ..][0..2], .little);
                if (op == opcode.op.scope_put_var_init) {
                    if (resolveLocalOrArg(ctx, atom_id, scope_level)) |binding| switch (binding) {
                        .local => |loc_idx| {
                            if (loc_idx < fd.vars.len) {
                                if (init_pc[loc_idx] == null) {
                                    init_pc[loc_idx] = pc;
                                }
                            }
                        },
                        else => {},
                    };
                }
                scan_atom_idx += 1;
                pc += 7;
            } else if (isScopePrivateFieldAt(func, pc, scan_atom_idx)) {
                if (pc + 7 > func.code.len) return error.InvalidBytecode;
                scan_atom_idx += 1;
                pc += 7;
            } else if (op == opcode.op.scope_make_ref) {
                if (pc + 11 > func.code.len) return error.InvalidBytecode;
                scan_atom_idx += 1;
                pc += 11;
            } else if (isScopeRefOp(op)) {
                if (pc + 7 > func.code.len) return error.InvalidBytecode;
                scan_atom_idx += 1;
                pc += 7;
            } else if (op == opcode.op.enter_scope or op == opcode.op.leave_scope) {
                if (pc + 3 > func.code.len) return error.InvalidBytecode;
                pc += 3;
            } else {
                const size = instrSize(op);
                if (pc + size > func.code.len) return error.InvalidBytecode;
                if (hasAtomOperand(op)) {
                    scan_atom_idx += 1;
                }
                pc += size;
            }
        }

        // Second scan to check for bypassing forward jumps
        pc = 0;
        scan_atom_idx = 0;
        while (pc < func.code.len) {
            const op = func.code[pc];
            var size: usize = undefined;
            var is_scope_var = false;

            if (op == opcode.op.eval) {
                size = 5;
            } else if (op == opcode.op.apply_eval) {
                size = 2;
            } else if (isScopeVarOp(op)) {
                size = 7;
                is_scope_var = true;
            } else if (isScopePrivateFieldAt(func, pc, scan_atom_idx)) {
                size = 7;
                scan_atom_idx += 1;
            } else if (op == opcode.op.scope_make_ref) {
                size = 11;
                scan_atom_idx += 1;
            } else if (isScopeRefOp(op)) {
                size = 7;
                scan_atom_idx += 1;
            } else if (op == opcode.op.enter_scope or op == opcode.op.leave_scope) {
                size = 3;
            } else {
                size = instrSize(op);
                if (hasAtomOperand(op)) {
                    scan_atom_idx += 1;
                }
            }

            if (pc + size > func.code.len) return error.InvalidBytecode;

            if (labelOperandOffset(op)) |offset| {
                if (pc + offset + 4 <= func.code.len) {
                    const old_target = std.mem.readInt(u32, func.code[pc + offset ..][0..4], .little);
                    if (old_target > pc) { // forward jump
                        for (fd.vars, 0..) |_, loc_idx| {
                            if (init_pc[loc_idx]) |ipc| {
                                if (pc < ipc and old_target > ipc) {
                                    bytes[loc_idx] = true;
                                }
                            }
                        }
                    }
                }
            }

            if (is_scope_var) {
                scan_atom_idx += 1;
            }
            pc += size;
        }

        break :blk bytes;
    } else @as([]bool, &.{});
    defer if (init_bypassed.len != 0) ctx.memory.free(bool, init_bypassed);

    var output_size: usize = global_vars_size + top_level_closure_init_size + child_decl_init_size + prologue_size;
    var output_atom_count: usize = global_vars_atom_count;
    var jump_count: usize = 0;
    var i: usize = 0;
    var scan_atom_idx: usize = 0;
    var global_ref_tail_atoms: []atom.Atom = if (func.code.len == 0) &.{} else try ctx.memory.alloc(atom.Atom, func.code.len);
    defer if (global_ref_tail_atoms.len != 0) ctx.memory.free(atom.Atom, global_ref_tail_atoms);
    var global_ref_tail_kinds: []u8 = if (func.code.len == 0) &.{} else try ctx.memory.alloc(u8, func.code.len);
    defer if (global_ref_tail_kinds.len != 0) ctx.memory.free(u8, global_ref_tail_kinds);
    if (global_ref_tail_atoms.len != 0) @memset(global_ref_tail_atoms, atom.null_atom);
    if (global_ref_tail_kinds.len != 0) @memset(global_ref_tail_kinds, GLOBAL_REF_TAIL_NONE);
    const var_initialized = if (ctx.function_def) |fd| blk: {
        const bytes = try ctx.memory.alloc(bool, fd.vars.len);
        @memset(bytes, false);
        break :blk bytes;
    } else @as([]bool, &.{});
    defer if (var_initialized.len != 0) ctx.memory.free(bool, var_initialized);
    while (i < func.code.len) {
        const op = func.code[i];
        if (global_ref_tail_kinds.len != 0 and global_ref_tail_kinds[i] != GLOBAL_REF_TAIL_NONE) {
            output_size += globalRefPutTailReplacementSize(global_ref_tail_kinds[i]);
            output_atom_count += 1;
            i += (decodeGlobalRefPutTail(func.code, i) orelse return error.InvalidBytecode).original_size;
            continue;
        }
        // Handle OP_eval and OP_apply_eval scope_idx rewrite (mirrors quickjs.c:33690-33702)
        if (op == opcode.op.eval) {
            if (i + 5 > func.code.len) return error.InvalidBytecode;
            // Format: call_argc (u16) + scope_idx (u16)
            _ = std.mem.readInt(u16, func.code[i + 1 ..][0..2], .little); // call_argc
            const raw_scope_idx = std.mem.readInt(u16, func.code[i + 3 ..][0..2], .little);
            const scope_idx = raw_scope_idx & EVAL_SCOPE_INDEX_MASK;

            // Rewrite scope_idx to s->scopes[scope].first + 1
            const fd = ctx.function_def orelse {
                // If no FunctionDef, copy through as-is
                output_size += 5;
                i += 5;
                continue;
            };
            if (@as(usize, @intCast(scope_idx)) < fd.scopes.len) {
                // Direct-eval-visible bindings are materialized by the parser
                // and VM eval overlay; this pass only remaps the scope index.
                _ = fd.scopes[@intCast(scope_idx)].first + 1; // new_scope_idx
                output_size += 5;
                i += 5;
                continue;
            } else {
                // Invalid scope_idx, copy through as-is
                output_size += 5;
                i += 5;
                continue;
            }
        } else if (op == opcode.op.apply_eval) {
            if (i + 2 > func.code.len) return error.InvalidBytecode;
            // Format: scope_idx (u16)
            const raw_scope_idx = std.mem.readInt(u16, func.code[i + 1 ..][0..2], .little);
            const scope_idx = raw_scope_idx & EVAL_SCOPE_INDEX_MASK;

            // Rewrite scope_idx to s->scopes[scope].first + 1
            const fd = ctx.function_def orelse {
                // If no FunctionDef, copy through as-is
                output_size += 2;
                i += 2;
                continue;
            };
            if (@as(usize, @intCast(scope_idx)) < fd.scopes.len) {
                // Direct-eval-visible bindings are materialized by the parser
                // and VM eval overlay; this pass only remaps the scope index.
                _ = fd.scopes[@intCast(scope_idx)].first + 1; // new_scope_idx
                output_size += 2;
                i += 2;
                continue;
            } else {
                // Invalid scope_idx, copy through as-is
                output_size += 2;
                i += 2;
                continue;
            }
        } else if (isScopeVarOp(op)) {
            if (i + 7 > func.code.len) return error.InvalidBytecode;
            const atom_id = std.mem.readInt(u32, func.code[i + 1 ..][0..4], .little);
            const scope_level = std.mem.readInt(i16, func.code[i + 5 ..][0..2], .little);
            if (lookupTopLevelModuleLexicalClosureVar(ctx, atom_id, scope_level)) |ref_idx| {
                const ref_op = lowerScopeVarOpForClosure(ctx, atom_id, ref_idx, op);
                const form = selectVarRefForm(ctx, ref_op, ref_idx);
                output_size += form.size;
            } else if (resolveLocalOrArg(ctx, atom_id, scope_level)) |binding| switch (binding) {
                .arg => |arg_idx| {
                    const arg_op = lowerScopeVarOpArg(op).?;
                    const form = selectArgForm(ctx, arg_op, arg_idx);
                    output_size += form.size;
                },
                .local => |loc_idx| {
                    if (preferTopLevelModuleClassBinding(ctx, atom_id, loc_idx)) |ref_idx| {
                        const ref_op = lowerScopeVarOpForClosure(ctx, atom_id, ref_idx, op);
                        const form = selectVarRefForm(ctx, ref_op, ref_idx);
                        output_size += form.size;
                    } else if (isTopLevelGlobalLexical(ctx, atom_id, loc_idx)) {
                        output_size += 5;
                        output_atom_count += 1;
                        i += 7;
                        continue;
                    } else if (blk: {
                        if (!isLexicalLocal(ctx, loc_idx)) break :blk false;
                        if (!useUncheckedLexicalLocals(ctx)) break :blk true;
                        if (op == opcode.op.scope_put_var_init) {
                            break :blk isConstLocal(ctx, loc_idx);
                        } else if (op == opcode.op.scope_put_var) {
                            if (isConstLocal(ctx, loc_idx)) break :blk true;
                            const init_safe = var_initialized[loc_idx] and !init_bypassed[loc_idx];
                            break :blk !init_safe and localTdzEmittedAtDecl(ctx, loc_idx);
                        } else {
                            const init_safe = var_initialized[loc_idx] and !init_bypassed[loc_idx];
                            break :blk !init_safe and (isConstLocal(ctx, loc_idx) or localTdzEmittedAtDecl(ctx, loc_idx));
                        }
                    }) {
                        // Lexical: 3-byte TDZ-check variant.
                        output_size += 3;
                    } else {
                        // var: shortest form (1, 2, or 3 bytes).
                        const local_op = lowerScopeVarOpLocal(op);
                        const form = selectLocForm(ctx, local_op, loc_idx);
                        output_size += form.size;
                    }
                    if (op == opcode.op.scope_put_var_init and loc_idx < var_initialized.len) {
                        var_initialized[loc_idx] = true;
                    }
                },
            } else if (lookupClosureVar(ctx, atom_id)) |ref_idx| {
                const ref_op = lowerScopeVarOpForClosure(ctx, atom_id, ref_idx, op);
                const form = selectVarRefForm(ctx, ref_op, ref_idx);
                output_size += form.size;
            } else {
                // Global: 5-byte atom form, one atom operand.
                output_size += 5;
                output_atom_count += 1;
            }
            scan_atom_idx += 1;
            i += 7;
        } else if (isScopePrivateFieldAt(func, i, scan_atom_idx)) {
            const atom_id = std.mem.readInt(u32, func.code[i + 1 ..][0..4], .little);
            const scope_level = std.mem.readInt(i16, func.code[i + 5 ..][0..2], .little);
            const res = resolvePrivateField(ctx, atom_id, scope_level) orelse return error.ClosureVarNotFound;
            output_size += try loweredPrivateFieldSize(ctx, op, res);
            scan_atom_idx += 1;
            i += 7;
        } else if (op == opcode.op.scope_make_ref) {
            if (i + 11 > func.code.len) return error.InvalidBytecode;
            const atom_id = std.mem.readInt(u32, func.code[i + 1 ..][0..4], .little);
            const scope_level = std.mem.readInt(i16, func.code[i + 9 ..][0..2], .little);
            if (canOptimizeGlobalRefPutTail(ctx, atom_id) and scopeMakeRefResolvesToGlobal(ctx, atom_id, scope_level)) {
                if (findGlobalRefPutTail(func.code, i)) |tail| {
                    if (tail.pc < global_ref_tail_kinds.len and global_ref_tail_kinds[tail.pc] == GLOBAL_REF_TAIL_NONE) {
                        global_ref_tail_atoms[tail.pc] = atom_id;
                        global_ref_tail_kinds[tail.pc] = tail.kind;
                        scan_atom_idx += 1;
                        i += 11;
                        continue;
                    }
                }
            }
            if (resolveLocalOrArg(ctx, atom_id, scope_level) != null) {
                output_size += 7;
                output_atom_count += 1;
            } else if (lookupClosureVar(ctx, atom_id) != null) {
                output_size += 7;
                output_atom_count += 1;
            } else {
                output_size += 5;
                output_atom_count += 1;
            }
            scan_atom_idx += 1;
            i += 11;
        } else if (isScopeRefOp(op)) {
            // scope_delete_var / scope_get_ref: 7-byte atom_u16.
            if (i + 7 > func.code.len) return error.InvalidBytecode;
            const atom_id = std.mem.readInt(u32, func.code[i + 1 ..][0..4], .little);
            const scope_level = std.mem.readInt(i16, func.code[i + 5 ..][0..2], .little);
            if (op == opcode.op.scope_delete_var) {
                if (resolveScopeVar(ctx, atom_id, scope_level)) |loc_idx| {
                    if (isEvalNonLexicalLocal(ctx, loc_idx)) {
                        // Eval-created `var` bindings are deletable environment
                        // bindings; keep a dynamic delete so the VM can remove
                        // the var-ref cell.
                        output_size += 5;
                        output_atom_count += 1;
                    } else {
                        // Local var: delete returns false (1 byte).
                        output_size += 1;
                    }
                } else if (lookupArg(ctx, atom_id) != null or lookupClosureVar(ctx, atom_id) != null) {
                    // Local / arg / closure var: delete returns false (1 byte).
                    output_size += 1;
                } else {
                    // Global: OP_delete_var <atom> (5 bytes + 1 atom).
                    output_size += 5;
                    output_atom_count += 1;
                }
            } else if (op == opcode.op.scope_get_ref) {
                if (resolveLocalOrArg(ctx, atom_id, scope_level)) |binding| switch (binding) {
                    .arg => |arg_idx| {
                        // OP_undefined (1) + OP_get_arg/short (1-3).
                        const form = selectArgForm(ctx, opcode.op.get_arg, arg_idx);
                        output_size += 1 + form.size;
                    },
                    .local => |loc_idx| {
                        // OP_undefined (1) + OP_get_loc/short (1-3).
                        if (isLexicalLocal(ctx, loc_idx)) {
                            output_size += 1 + 3; // undefined + get_loc_check
                        } else {
                            const form = selectLocForm(ctx, opcode.op.get_loc, loc_idx);
                            output_size += 1 + form.size;
                        }
                    },
                } else if (lookupClosureVar(ctx, atom_id)) |ref_idx| {
                    // OP_undefined (1) + OP_get_var_ref (1-3).
                    const form = selectVarRefForm(ctx, opcode.op.get_var_ref, ref_idx);
                    output_size += 1 + form.size;
                } else {
                    // Global: OP_undefined (1) + OP_get_var (5) + 1 atom.
                    output_size += 1 + 5;
                    output_atom_count += 1;
                }
            }
            scan_atom_idx += 1;
            i += 7;
        } else if (op == opcode.op.enter_scope or op == opcode.op.leave_scope) {
            if (i + 3 > func.code.len) return error.InvalidBytecode;
            if (op == opcode.op.enter_scope) {
                const scope = std.mem.readInt(u16, func.code[i + 1 ..][0..2], .little);
                output_size += enterScopeRefreshSize(ctx, scope);
            }
            i += 3;
        } else {
            const size = instrSize(op);
            output_size += size;
            if (hasAtomOperand(op)) {
                output_atom_count += 1;
                scan_atom_idx += 1;
            }
            if (labelOperandOffset(op) != null) jump_count += 1;
            i += size;
        }
    }

    // Keep empty outputs as inert slices so later bytecode ownership has a
    // stable representation without touching allocator accounting.
    const output: []u8 = if (output_size == 0)
        &.{}
    else
        try ctx.memory.alloc(u8, output_size);
    var output_owned = output.len != 0;
    errdefer if (output_owned) ctx.memory.free(u8, output);
    const output_atoms: []atom.Atom = if (output_atom_count == 0)
        &.{}
    else
        try ctx.memory.alloc(atom.Atom, output_atom_count);
    var output_atoms_owned = output_atoms.len != 0;
    var out_atom_idx: usize = 0;
    errdefer if (output_atoms_owned) {
        for (output_atoms[0..out_atom_idx]) |atom_id| ctx.atoms.free(atom_id);
        ctx.memory.free(atom.Atom, output_atoms);
    };

    // Scratch arrays for pc-map and jump sites (use raw allocator so
    // we don't pollute the MemoryAccount counters; these are freed
    // before `run` returns).
    const allocator = ctx.memory.allocator;
    // `pc_map[old_pc + 1]` holds the new pc that the instruction
    // previously at `old_pc` now starts at. Entry `pc_map[0]` is
    // unused (0 maps to 0 trivially). Dropped instructions (the
    // enter/leave scope pair) map their old pc to the new pc of the
    // *next* kept instruction, so a jump that targets them still
    // lands on a valid instruction boundary.
    const pc_map = try allocator.alloc(usize, func.code.len + 1);
    defer allocator.free(pc_map);
    @memset(pc_map, 0);
    const jump_sites = try allocator.alloc(JumpSite, jump_count);
    defer allocator.free(jump_sites);

    // Second pass: walk input + atom_operands in lockstep. Every
    // opcode with an atom format consumes one entry from the input
    // `func.atom_operands` list; we re-retain it for `output_atoms`
    // so refcounts stay balanced. Jump operand sites are recorded
    // into `jump_sites` for post-pass patching.
    var out_idx: usize = 0;
    var in_atom_idx: usize = 0;
    var out_jump_idx: usize = 0;

    // Emit global vars pre-pass (mirrors quickjs.c:33636-33672):
    // first validate every declaration, then create bindings. This
    // ordering matters because a later lexical redeclaration error must
    // prevent earlier `var` bindings from being created.
    if (ctx.function_def) |fd| {
        for (fd.global_vars) |gv| {
            // Check for conflicts with closure vars (simplified - full check
            // requires eval_type and is_lexical flag handling per QuickJS)
            var flags: u8 = 0;
            if (gv.is_lexical) flags |= DEFINE_GLOBAL_LEX_VAR;
            if (gv.cpool_idx >= 0 or gv.force_init) flags |= DEFINE_GLOBAL_FUNC_VAR;
            if (gv.is_configurable) flags |= DEFINE_GLOBAL_CONFIGURABLE;
            if (gv.is_const) flags |= DEFINE_GLOBAL_CONST;

            output[out_idx] = opcode.op.check_define_var;
            std.mem.writeInt(u32, output[out_idx + 1 ..][0..4], gv.var_name, .little);
            output[out_idx + 5] = flags;
            output_atoms[out_atom_idx] = ctx.atoms.dup(gv.var_name);
            out_idx += 6;
            out_atom_idx += 1;
        }
        for (fd.global_vars) |gv| {
            var flags: u8 = 0;
            if (gv.is_lexical) flags |= DEFINE_GLOBAL_LEX_VAR;
            if (gv.cpool_idx >= 0 or gv.force_init) flags |= DEFINE_GLOBAL_FUNC_VAR;
            if (gv.is_configurable) flags |= DEFINE_GLOBAL_CONFIGURABLE;
            if (gv.is_const) flags |= DEFINE_GLOBAL_CONST;

            output[out_idx] = opcode.op.define_var;
            std.mem.writeInt(u32, output[out_idx + 1 ..][0..4], gv.var_name, .little);
            output[out_idx + 5] = flags;
            output_atoms[out_atom_idx] = ctx.atoms.dup(gv.var_name);
            out_idx += 6;
            out_atom_idx += 1;
        }
    }

    // Emit the TDZ prologue: one `set_loc_uninitialized <idx>` per
    // lexical local. This marks the slots so `get_loc_check` /
    // `put_loc_check` throw `ReferenceError` until
    // `put_loc_check_init` runs.
    if (ctx.function_def) |fd| {
        var var_idx = fd.vars.len;
        while (var_idx > 0) {
            var_idx -= 1;
            const v = fd.vars[var_idx];
            if (!v.is_lexical or v.tdz_emitted_at_decl) continue;
            output[out_idx] = opcode.op.set_loc_uninitialized;
            std.mem.writeInt(u16, output[out_idx + 1 ..][0..2], @intCast(var_idx), .little);
            out_idx += 3;
        }
    }

    if (ctx.function_def) |fd| {
        for (fd.child_list) |child| {
            if (child.emit_top_level_closure_init) {
                if (child.parent_cpool_idx < 0 or child.top_level_closure_var_idx < 0) return error.InvalidBytecode;
                output[out_idx] = opcode.op.fclosure8;
                output[out_idx + 1] = @intCast(child.parent_cpool_idx);
                out_idx += 2;
                const ref_idx: u16 = @intCast(child.top_level_closure_var_idx);
                const form = selectVarRefForm(ctx, opcode.op.put_var_ref, ref_idx);
                output[out_idx] = form.op_id;
                switch (form.operand_size) {
                    0 => {},
                    2 => std.mem.writeInt(u16, output[out_idx + 1 ..][0..2], ref_idx, .little),
                    else => unreachable,
                }
                out_idx += form.size;
                continue;
            }
            if (child.child_decl_emit_inline) continue;
            if (child.func_type != .statement) continue;
            if (child.parent_cpool_idx < 0) return error.InvalidBytecode;
            output[out_idx] = opcode.op.fclosure8;
            output[out_idx + 1] = @intCast(child.parent_cpool_idx);
            out_idx += 2;
            const arg_idx_i = if (child.child_decl_force_local_init) -1 else fd.findArg(child.func_name);
            const form = if (arg_idx_i >= 0)
                selectArgForm(ctx, opcode.op.put_arg, @intCast(arg_idx_i))
            else blk: {
                const var_idx_i = if (child.child_decl_var_idx >= 0) child.child_decl_var_idx else fd.findVar(child.func_name);
                if (var_idx_i < 0) return error.InvalidBytecode;
                const var_idx: u16 = @intCast(var_idx_i);
                break :blk selectLocForm(ctx, if (child.child_decl_init_keep_value) opcode.op.set_loc else opcode.op.put_loc, var_idx);
            };
            const binding_idx: u16 = if (arg_idx_i >= 0) @intCast(arg_idx_i) else blk: {
                const var_idx_i = if (child.child_decl_var_idx >= 0) child.child_decl_var_idx else fd.findVar(child.func_name);
                if (var_idx_i < 0) return error.InvalidBytecode;
                break :blk @intCast(var_idx_i);
            };
            output[out_idx] = form.op_id;
            switch (form.operand_size) {
                0 => {},
                1 => output[out_idx + 1] = @intCast(binding_idx),
                2 => std.mem.writeInt(u16, output[out_idx + 1 ..][0..2], binding_idx, .little),
                else => unreachable,
            }
            out_idx += form.size;
        }
    }

    const var_initialized_pass2 = if (ctx.function_def) |fd| blk: {
        const bytes = try ctx.memory.alloc(bool, fd.vars.len);
        @memset(bytes, false);
        break :blk bytes;
    } else @as([]bool, &.{});
    defer if (var_initialized_pass2.len != 0) ctx.memory.free(bool, var_initialized_pass2);

    i = 0;
    while (i < func.code.len) {
        // pc_map for input pc i maps to output pc out_idx (after the
        // global_vars pre-pass and TDZ prologue), so jumps that reference
        // the post-prologue body resolve correctly.
        pc_map[i] = out_idx;
        const op = func.code[i];
        if (global_ref_tail_kinds.len != 0 and global_ref_tail_kinds[i] != GLOBAL_REF_TAIL_NONE) {
            const atom_id = global_ref_tail_atoms[i];
            if (global_ref_tail_kinds[i] == GLOBAL_REF_TAIL_DUP_PUT) {
                output[out_idx] = opcode.op.dup;
                out_idx += 1;
            }
            output[out_idx] = opcode.op.put_var;
            std.mem.writeInt(u32, output[out_idx + 1 ..][0..4], atom_id, .little);
            output_atoms[out_atom_idx] = func.atoms.dup(atom_id);
            out_idx += 5;
            out_atom_idx += 1;
            i += (decodeGlobalRefPutTail(func.code, i) orelse return error.InvalidBytecode).original_size;
            continue;
        }
        // Handle OP_eval and OP_apply_eval scope_idx rewrite (mirrors quickjs.c:33690-33702)
        if (op == opcode.op.eval) {
            if (i + 5 > func.code.len) return error.InvalidBytecode;
            const call_argc = std.mem.readInt(u16, func.code[i + 1 ..][0..2], .little);
            const raw_scope_idx = std.mem.readInt(u16, func.code[i + 3 ..][0..2], .little);
            const scope_idx = raw_scope_idx & EVAL_SCOPE_INDEX_MASK;
            const scope_flags = raw_scope_idx & ~EVAL_SCOPE_INDEX_MASK;

            const fd = ctx.function_def orelse {
                // If no FunctionDef, copy through as-is
                @memcpy(output[out_idx .. out_idx + 5], func.code[i .. i + 5]);
                out_idx += 5;
                i += 5;
                continue;
            };
            if (@as(usize, @intCast(scope_idx)) < fd.scopes.len) {
                // Direct-eval-visible bindings are materialized by the parser
                // and VM eval overlay; this pass only remaps the scope index.
                const new_scope_idx: u16 = @intCast(fd.scopes[@intCast(scope_idx)].first + 1);
                output[out_idx] = opcode.op.eval;
                std.mem.writeInt(u16, output[out_idx + 1 ..][0..2], call_argc, .little);
                std.mem.writeInt(u16, output[out_idx + 3 ..][0..2], new_scope_idx | scope_flags, .little);
                out_idx += 5;
                i += 5;
                continue;
            } else {
                // Invalid scope_idx, copy through as-is
                @memcpy(output[out_idx .. out_idx + 5], func.code[i .. i + 5]);
                out_idx += 5;
                i += 5;
                continue;
            }
        } else if (op == opcode.op.apply_eval) {
            if (i + 2 > func.code.len) return error.InvalidBytecode;
            const raw_scope_idx = std.mem.readInt(u16, func.code[i + 1 ..][0..2], .little);
            const scope_idx = raw_scope_idx & EVAL_SCOPE_INDEX_MASK;
            const scope_flags = raw_scope_idx & ~EVAL_SCOPE_INDEX_MASK;

            const fd = ctx.function_def orelse {
                // If no FunctionDef, copy through as-is
                @memcpy(output[out_idx .. out_idx + 2], func.code[i .. i + 2]);
                out_idx += 2;
                i += 2;
                continue;
            };
            if (@as(usize, @intCast(scope_idx)) < fd.scopes.len) {
                // Direct-eval-visible bindings are materialized by the parser
                // and VM eval overlay; this pass only remaps the scope index.
                const new_scope_idx: u16 = @intCast(fd.scopes[@intCast(scope_idx)].first + 1);
                output[out_idx] = opcode.op.apply_eval;
                std.mem.writeInt(u16, output[out_idx + 1 ..][0..2], new_scope_idx | scope_flags, .little);
                out_idx += 2;
                i += 2;
                continue;
            } else {
                // Invalid scope_idx, copy through as-is
                @memcpy(output[out_idx .. out_idx + 2], func.code[i .. i + 2]);
                out_idx += 2;
                i += 2;
                continue;
            }
        } else if (isScopeVarOp(op)) {
            if (i + 7 > func.code.len) return error.InvalidBytecode;
            const atom_id = std.mem.readInt(u32, func.code[i + 1 ..][0..4], .little);
            const scope_level = std.mem.readInt(i16, func.code[i + 5 ..][0..2], .little);
            if (lookupTopLevelModuleLexicalClosureVar(ctx, atom_id, scope_level)) |ref_idx| {
                const ref_op = lowerScopeVarOpForClosure(ctx, atom_id, ref_idx, op);
                const form = selectVarRefForm(ctx, ref_op, ref_idx);
                output[out_idx] = form.op_id;
                switch (form.operand_size) {
                    0 => {},
                    2 => std.mem.writeInt(u16, output[out_idx + 1 ..][0..2], ref_idx, .little),
                    else => unreachable,
                }
                out_idx += form.size;
                in_atom_idx += 1;
            } else if (resolveLocalOrArg(ctx, atom_id, scope_level)) |binding| switch (binding) {
                .arg => |arg_idx| {
                    const arg_op = lowerScopeVarOpArg(op).?;
                    const form = selectArgForm(ctx, arg_op, arg_idx);
                    output[out_idx] = form.op_id;
                    switch (form.operand_size) {
                        0 => {},
                        2 => std.mem.writeInt(u16, output[out_idx + 1 ..][0..2], arg_idx, .little),
                        else => unreachable,
                    }
                    out_idx += form.size;
                    in_atom_idx += 1;
                },
                .local => |loc_idx| {
                    if (preferTopLevelModuleClassBinding(ctx, atom_id, loc_idx)) |ref_idx| {
                        const ref_op = lowerScopeVarOpForClosure(ctx, atom_id, ref_idx, op);
                        const form = selectVarRefForm(ctx, ref_op, ref_idx);
                        output[out_idx] = form.op_id;
                        switch (form.operand_size) {
                            0 => {},
                            2 => std.mem.writeInt(u16, output[out_idx + 1 ..][0..2], ref_idx, .little),
                            else => unreachable,
                        }
                        out_idx += form.size;
                    } else if (isTopLevelGlobalLexical(ctx, atom_id, loc_idx)) {
                        output[out_idx] = lowerScopeVarOpGlobal(op);
                        std.mem.writeInt(u32, output[out_idx + 1 ..][0..4], atom_id, .little);
                        output_atoms[out_atom_idx] = func.atoms.dup(atom_id);
                        out_idx += 5;
                        out_atom_idx += 1;
                        in_atom_idx += 1;
                        i += 7;
                        continue;
                    } else if (blk: {
                        if (!isLexicalLocal(ctx, loc_idx)) break :blk false;
                        if (!useUncheckedLexicalLocals(ctx)) break :blk true;
                        if (op == opcode.op.scope_put_var_init) {
                            break :blk isConstLocal(ctx, loc_idx);
                        } else if (op == opcode.op.scope_put_var) {
                            if (isConstLocal(ctx, loc_idx)) break :blk true;
                            const init_safe = var_initialized_pass2[loc_idx] and !init_bypassed[loc_idx];
                            break :blk !init_safe and localTdzEmittedAtDecl(ctx, loc_idx);
                        } else {
                            const init_safe = var_initialized_pass2[loc_idx] and !init_bypassed[loc_idx];
                            break :blk !init_safe and (isConstLocal(ctx, loc_idx) or localTdzEmittedAtDecl(ctx, loc_idx));
                        }
                    }) {
                        output[out_idx] = lowerScopeVarOpLexical(op);
                        std.mem.writeInt(u16, output[out_idx + 1 ..][0..2], loc_idx, .little);
                        out_idx += 3;
                    } else {
                        const local_op = lowerScopeVarOpLocal(op);
                        const form = selectLocForm(ctx, local_op, loc_idx);
                        output[out_idx] = form.op_id;
                        switch (form.operand_size) {
                            0 => {},
                            1 => output[out_idx + 1] = @intCast(loc_idx),
                            2 => std.mem.writeInt(u16, output[out_idx + 1 ..][0..2], loc_idx, .little),
                            else => unreachable,
                        }
                        out_idx += form.size;
                    }
                    if (op == opcode.op.scope_put_var_init and loc_idx < var_initialized_pass2.len) {
                        var_initialized_pass2[loc_idx] = true;
                    }
                    in_atom_idx += 1;
                },
            } else if (lookupClosureVar(ctx, atom_id)) |ref_idx| {
                const ref_op = lowerScopeVarOpForClosure(ctx, atom_id, ref_idx, op);
                const form = selectVarRefForm(ctx, ref_op, ref_idx);
                output[out_idx] = form.op_id;
                switch (form.operand_size) {
                    0 => {},
                    2 => std.mem.writeInt(u16, output[out_idx + 1 ..][0..2], ref_idx, .little),
                    else => unreachable,
                }
                out_idx += form.size;
                in_atom_idx += 1;
            } else {
                output[out_idx] = lowerScopeVarOpGlobal(op);
                std.mem.writeInt(u32, output[out_idx + 1 ..][0..4], atom_id, .little);
                output_atoms[out_atom_idx] = func.atoms.dup(atom_id);
                out_idx += 5;
                out_atom_idx += 1;
                in_atom_idx += 1;
            }
            i += 7;
        } else if (isScopePrivateFieldAt(func, i, in_atom_idx)) {
            const atom_id = std.mem.readInt(u32, func.code[i + 1 ..][0..4], .little);
            const scope_level = std.mem.readInt(i16, func.code[i + 5 ..][0..2], .little);
            const res = resolvePrivateField(ctx, atom_id, scope_level) orelse return error.ClosureVarNotFound;
            try writeLoweredPrivateField(ctx, output, &out_idx, op, res);
            in_atom_idx += 1;
            i += 7;
        } else if (op == opcode.op.scope_make_ref) {
            if (i + 11 > func.code.len) return error.InvalidBytecode;
            const atom_id = std.mem.readInt(u32, func.code[i + 1 ..][0..4], .little);
            const scope_level = std.mem.readInt(i16, func.code[i + 9 ..][0..2], .little);
            if (canOptimizeGlobalRefPutTail(ctx, atom_id) and scopeMakeRefResolvesToGlobal(ctx, atom_id, scope_level)) {
                if (findGlobalRefPutTail(func.code, i)) |tail| {
                    if (tail.pc < global_ref_tail_kinds.len and
                        global_ref_tail_kinds[tail.pc] != GLOBAL_REF_TAIL_NONE and
                        global_ref_tail_atoms[tail.pc] == atom_id)
                    {
                        in_atom_idx += 1;
                        i += 11;
                        continue;
                    }
                }
            }
            if (resolveLocalOrArg(ctx, atom_id, scope_level)) |binding| switch (binding) {
                .arg => |arg_idx| {
                    output[out_idx] = opcode.op.make_arg_ref;
                    std.mem.writeInt(u32, output[out_idx + 1 ..][0..4], atom_id, .little);
                    std.mem.writeInt(u16, output[out_idx + 5 ..][0..2], arg_idx, .little);
                    output_atoms[out_atom_idx] = func.atoms.dup(atom_id);
                    out_idx += 7;
                    out_atom_idx += 1;
                },
                .local => |loc_idx| {
                    output[out_idx] = opcode.op.make_loc_ref;
                    std.mem.writeInt(u32, output[out_idx + 1 ..][0..4], atom_id, .little);
                    std.mem.writeInt(u16, output[out_idx + 5 ..][0..2], loc_idx, .little);
                    output_atoms[out_atom_idx] = func.atoms.dup(atom_id);
                    out_idx += 7;
                    out_atom_idx += 1;
                },
            } else if (lookupClosureVar(ctx, atom_id)) |ref_idx| {
                output[out_idx] = opcode.op.make_var_ref_ref;
                std.mem.writeInt(u32, output[out_idx + 1 ..][0..4], atom_id, .little);
                std.mem.writeInt(u16, output[out_idx + 5 ..][0..2], ref_idx, .little);
                output_atoms[out_atom_idx] = func.atoms.dup(atom_id);
                out_idx += 7;
                out_atom_idx += 1;
            } else {
                output[out_idx] = opcode.op.make_var_ref;
                std.mem.writeInt(u32, output[out_idx + 1 ..][0..4], atom_id, .little);
                output_atoms[out_atom_idx] = func.atoms.dup(atom_id);
                out_idx += 5;
                out_atom_idx += 1;
            }
            in_atom_idx += 1;
            i += 11;
        } else if (isScopeRefOp(op)) {
            if (i + 7 > func.code.len) return error.InvalidBytecode;
            const atom_id = std.mem.readInt(u32, func.code[i + 1 ..][0..4], .little);
            const scope_level = std.mem.readInt(i16, func.code[i + 5 ..][0..2], .little);
            if (op == opcode.op.scope_delete_var) {
                if (resolveScopeVar(ctx, atom_id, scope_level)) |loc_idx| {
                    if (isEvalNonLexicalLocal(ctx, loc_idx)) {
                        output[out_idx] = opcode.op.delete_var;
                        std.mem.writeInt(u32, output[out_idx + 1 ..][0..4], atom_id, .little);
                        output_atoms[out_atom_idx] = func.atoms.dup(atom_id);
                        out_idx += 5;
                        out_atom_idx += 1;
                    } else {
                        output[out_idx] = opcode.op.push_false;
                        out_idx += 1;
                    }
                } else if (lookupArg(ctx, atom_id) != null or lookupClosureVar(ctx, atom_id) != null) {
                    output[out_idx] = opcode.op.push_false;
                    out_idx += 1;
                } else {
                    output[out_idx] = opcode.op.delete_var;
                    std.mem.writeInt(u32, output[out_idx + 1 ..][0..4], atom_id, .little);
                    output_atoms[out_atom_idx] = func.atoms.dup(atom_id);
                    out_idx += 5;
                    out_atom_idx += 1;
                }
                in_atom_idx += 1;
            } else {
                // scope_get_ref: emit OP_undefined + get accessor.
                output[out_idx] = opcode.op.undefined;
                out_idx += 1;
                if (resolveLocalOrArg(ctx, atom_id, scope_level)) |binding| switch (binding) {
                    .arg => |arg_idx| {
                        const form = selectArgForm(ctx, opcode.op.get_arg, arg_idx);
                        output[out_idx] = form.op_id;
                        switch (form.operand_size) {
                            0 => {},
                            2 => std.mem.writeInt(u16, output[out_idx + 1 ..][0..2], arg_idx, .little),
                            else => unreachable,
                        }
                        out_idx += form.size;
                    },
                    .local => |loc_idx| {
                        if (isLexicalLocal(ctx, loc_idx)) {
                            output[out_idx] = opcode.op.get_loc_check;
                            std.mem.writeInt(u16, output[out_idx + 1 ..][0..2], loc_idx, .little);
                            out_idx += 3;
                        } else {
                            const form = selectLocForm(ctx, opcode.op.get_loc, loc_idx);
                            output[out_idx] = form.op_id;
                            switch (form.operand_size) {
                                0 => {},
                                1 => output[out_idx + 1] = @intCast(loc_idx),
                                2 => std.mem.writeInt(u16, output[out_idx + 1 ..][0..2], loc_idx, .little),
                                else => unreachable,
                            }
                            out_idx += form.size;
                        }
                    },
                } else if (lookupClosureVar(ctx, atom_id)) |ref_idx| {
                    const form = selectVarRefForm(ctx, opcode.op.get_var_ref, ref_idx);
                    output[out_idx] = form.op_id;
                    switch (form.operand_size) {
                        0 => {},
                        2 => std.mem.writeInt(u16, output[out_idx + 1 ..][0..2], ref_idx, .little),
                        else => unreachable,
                    }
                    out_idx += form.size;
                } else {
                    output[out_idx] = opcode.op.get_var;
                    std.mem.writeInt(u32, output[out_idx + 1 ..][0..4], atom_id, .little);
                    output_atoms[out_atom_idx] = func.atoms.dup(atom_id);
                    out_idx += 5;
                    out_atom_idx += 1;
                }
                in_atom_idx += 1;
            }
            i += 7;
        } else if (op == opcode.op.enter_scope or op == opcode.op.leave_scope) {
            if (i + 3 > func.code.len) return error.InvalidBytecode;
            if (op == opcode.op.enter_scope) {
                const scope = std.mem.readInt(u16, func.code[i + 1 ..][0..2], .little);
                writeEnterScopeRefresh(ctx, output, &out_idx, scope);
            }
            i += 3;
        } else {
            const size = instrSize(op);
            if (i + size > func.code.len) return error.InvalidBytecode;
            @memcpy(output[out_idx .. out_idx + size], func.code[i .. i + size]);
            if (hasAtomOperand(op)) {
                if (in_atom_idx >= func.atom_operands.len) return error.InvalidBytecode;
                const atom_id = if (size >= 5) blk: {
                    const encoded_atom = std.mem.readInt(u32, func.code[i + 1 ..][0..4], .little);
                    if (encoded_atom != atom.null_atom and func.atoms.kind(encoded_atom) == null) {
                        // The atom operand list owns the retain. If an older
                        // rewrite left a stale wide immediate, resynchronise it
                        // before the final FunctionBytecode takes ownership.
                        const retained_atom = func.atom_operands[in_atom_idx];
                        std.mem.writeInt(u32, output[out_idx + 1 ..][0..4], retained_atom, .little);
                        break :blk retained_atom;
                    }
                    break :blk encoded_atom;
                } else func.atom_operands[in_atom_idx];
                if (size >= 5) std.mem.writeInt(u32, output[out_idx + 1 ..][0..4], atom_id, .little);
                output_atoms[out_atom_idx] = func.atoms.dup(atom_id);
                out_atom_idx += 1;
                in_atom_idx += 1;
            }
            if (labelOperandOffset(op)) |offset| {
                jump_sites[out_jump_idx] = .{ .operand_pos = out_idx + offset };
                out_jump_idx += 1;
            }
            out_idx += size;
            i += size;
        }
    }
    // Terminal entry: pc_map[old_len] == out_idx handles jumps that
    // target exactly one-past-the-end (e.g. loop exit to the next
    // instruction after the final byte).
    pc_map[func.code.len] = out_idx;

    // Patch jump targets using the pc map. Each site stored an
    // absolute u32 target that was valid against the *input* code
    // layout; rewrite it to the new post-lowering position.
    for (jump_sites[0..out_jump_idx]) |site| {
        const old_target = std.mem.readInt(u32, output[site.operand_pos..][0..4], .little);
        // Targets outside `[0, func.code.len]` indicate a parser bug,
        // but we treat them as identity rather than panicking so the
        // pipeline stays robust to unfamiliar inputs.
        const new_target: u32 = if (old_target <= func.code.len)
            @intCast(pc_map[old_target])
        else
            old_target;
        std.mem.writeInt(u32, output[site.operand_pos..][0..4], new_target, .little);
    }

    // Build exact-fit buffers before mutating the function. Either trim
    // allocation may fail, and the original temporary buffers must remain
    // owned by the local errdefer path until every fallible step is complete.
    const code_to_install: []u8 = if (out_idx < output.len) blk: {
        if (out_idx == 0) break :blk &.{};
        const trimmed = try ctx.memory.alloc(u8, out_idx);
        @memcpy(trimmed, output[0..out_idx]);
        break :blk trimmed;
    } else output;
    var code_to_install_owned = code_to_install.len != 0 and code_to_install.ptr != output.ptr;
    errdefer if (code_to_install_owned) ctx.memory.free(u8, code_to_install);

    const atoms_to_install: []atom.Atom = if (out_atom_idx < output_atoms.len) blk: {
        if (out_atom_idx == 0) break :blk &.{};
        const trimmed = try ctx.memory.alloc(atom.Atom, out_atom_idx);
        @memcpy(trimmed, output_atoms[0..out_atom_idx]);
        break :blk trimmed;
    } else output_atoms;
    var atoms_to_install_owned = atoms_to_install.len != 0 and atoms_to_install.ptr != output_atoms.ptr;
    errdefer if (atoms_to_install_owned) ctx.memory.free(atom.Atom, atoms_to_install);

    // Replace the old code buffer. `installCode` frees any prior buffer,
    // including capacity allocated by the parser via geometric growth.
    func.remapSourceLocs(pc_map);
    func.remapDirectCallSites(pc_map);
    if (code_to_install.ptr != output.ptr and output_owned) {
        ctx.memory.free(u8, output);
        output_owned = false;
    }
    func.installCode(code_to_install);
    if (code_to_install_owned) code_to_install_owned = false;
    if (code_to_install.ptr == output.ptr) output_owned = false;

    // Replace atom_operands: release old entries, install new ones.
    for (func.atom_operands) |old_atom| func.atoms.free(old_atom);
    if (atoms_to_install.ptr != output_atoms.ptr and output_atoms_owned) {
        ctx.memory.free(atom.Atom, output_atoms);
        output_atoms_owned = false;
    }
    func.installAtomOperands(atoms_to_install);
    if (atoms_to_install_owned) atoms_to_install_owned = false;
    if (atoms_to_install.ptr == output_atoms.ptr) output_atoms_owned = false;
}

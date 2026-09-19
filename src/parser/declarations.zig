//! Declaration bookkeeping: `defineVar` and the QuickJS `define_var` /
//! `add_scope_var` / `add_var` rules behind it, the lexical and
//! function-scope lookups they need, and the declaration-conflict index
//! that keeps those lookups linear on large functions.

const std = @import("std");
const root = @import("../parser.zig");
const parse_state = @import("parse_state.zig");
const identifiers = @import("identifiers.zig");
const emitter = @import("emitter.zig");
const functions = @import("functions.zig");
const bytecode = @import("../bytecode.zig");
const atom_module = @import("../core/atom.zig");
const core = @import("../core/root.zig");
const compiler = @import("../compiler/root.zig");
const Emitter = emitter.Emitter;
const State = parse_state.State;
const Error = parse_state.Error;
const Atom = parse_state.Atom;
const function_def_mod = parse_state.function_def_mod;
const bytecode_function = parse_state.bytecode_function;
const opcode = parse_state.opcode;
const atom_this = parse_state.atom_this;
const atom_new_target = parse_state.atom_new_target;
const atom_this_active_func = parse_state.atom_this_active_func;
const atom_home_object = parse_state.atom_home_object;

/// Parser-only accelerator for the two declaration-conflict scans which
/// otherwise make a flat list of unique lexical declarations quadratic.
/// The finalized FunctionBytecode never observes this state.
pub const declaration_conflict_index_threshold: usize = 64;

pub const no_declaration_index: u32 = std.math.maxInt(u32);

pub const DeclarationConflictEntry = struct {
    /// Newest linked lexical declaration in this exact scope.
    newest_lexical: u32 = no_declaration_index,
    /// Newest linked lexical-or-catch declaration in this exact scope.
    newest_lexical_or_catch: u32 = no_declaration_index,
    /// Oldest scope-0 var whose parser-time origin is this scope or one of
    /// its descendants. This preserves find_var_in_child_scope's forward
    /// scan result while making the query exact-scope.
    oldest_child_function_var: u32 = no_declaration_index,
};

pub const DeclarationConflictIndex = struct {
    const ScopeNameMap = std.AutoHashMapUnmanaged(u64, DeclarationConflictEntry);
    const BuildError = error{ OutOfMemory, InvalidTopology };

    scope_names: ScopeNameMap = .empty,
    observed_vars_len: usize = 0,
    dirty: bool = false,

    pub fn deinit(self: *DeclarationConflictIndex, allocator: std.mem.Allocator) void {
        self.scope_names.deinit(allocator);
        self.* = .{};
    }

    fn scopeNameKey(scope_level: i32, name: Atom) ?u64 {
        if (scope_level < 0) return null;
        return (@as(u64, @intCast(scope_level)) << 32) | name.raw();
    }

    fn validateScopes(fd: *const function_def_mod.FunctionDef) BuildError!void {
        for (fd.scopes, 0..) |scope, scope_index| {
            if (scope.parent < -1) return error.InvalidTopology;
            if (scope.parent >= 0 and @as(usize, @intCast(scope.parent)) >= scope_index) {
                return error.InvalidTopology;
            }
        }
    }

    fn entry(
        self: *DeclarationConflictIndex,
        allocator: std.mem.Allocator,
        key: u64,
    ) BuildError!*DeclarationConflictEntry {
        const result = try self.scope_names.getOrPut(allocator, key);
        if (!result.found_existing) result.value_ptr.* = .{};
        return result.value_ptr;
    }

    fn recordLinkedNewestFirst(
        self: *DeclarationConflictIndex,
        allocator: std.mem.Allocator,
        vd: function_def_mod.VarDef,
        var_index: usize,
    ) BuildError!void {
        const eligible_for_lexical = vd.is_lexical;
        const eligible_for_lexical_or_catch = eligible_for_lexical or vd.var_kind == .catch_;
        if (!eligible_for_lexical_or_catch) return;
        const key = scopeNameKey(vd.scope_level, vd.var_name) orelse return error.InvalidTopology;
        const value = try self.entry(allocator, key);
        if (eligible_for_lexical and value.newest_lexical == no_declaration_index) {
            value.newest_lexical = @intCast(var_index);
        }
        if (value.newest_lexical_or_catch == no_declaration_index) {
            value.newest_lexical_or_catch = @intCast(var_index);
        }
    }

    fn recordFunctionVarOriginOldestFirst(
        self: *DeclarationConflictIndex,
        allocator: std.mem.Allocator,
        fd: *const function_def_mod.FunctionDef,
        vd: function_def_mod.VarDef,
        var_index: usize,
    ) BuildError!void {
        var scope = vd.scope_next;
        var visited: usize = 0;
        while (scope >= 0) : (visited += 1) {
            if (visited >= fd.scopes.len or @as(usize, @intCast(scope)) >= fd.scopes.len) {
                return error.InvalidTopology;
            }
            const key = scopeNameKey(scope, vd.var_name) orelse return error.InvalidTopology;
            const value = try self.entry(allocator, key);
            if (value.oldest_child_function_var == no_declaration_index) {
                value.oldest_child_function_var = @intCast(var_index);
            }
            scope = fd.scopes[@intCast(scope)].parent;
        }
    }

    pub fn build(
        self: *DeclarationConflictIndex,
        allocator: std.mem.Allocator,
        fd: *const function_def_mod.FunctionDef,
    ) BuildError!void {
        try validateScopes(fd);
        if (fd.vars.len != 0) {
            try self.scope_names.ensureTotalCapacity(allocator, @intCast(fd.vars.len));
        }

        // Each scope's local prefix is newest-first. Inherited heads stop
        // at the first row owned by an outer scope.
        for (fd.scopes, 0..) |scope, scope_index| {
            var var_index = scope.first;
            var visited: usize = 0;
            while (var_index >= 0) : (visited += 1) {
                if (visited >= fd.vars.len or @as(usize, @intCast(var_index)) >= fd.vars.len) {
                    return error.InvalidTopology;
                }
                const index: usize = @intCast(var_index);
                const vd = fd.vars[index];
                if (vd.scope_level != @as(i32, @intCast(scope_index))) break;
                try self.recordLinkedNewestFirst(allocator, vd, index);
                var_index = vd.scope_next;
            }
        }

        // Parser-time scope-0 rows retain their source declaration scope
        // in scope_next and are intentionally absent from scope.first.
        // Walk oldest-first to preserve the legacy scan's returned index.
        for (fd.vars, 0..) |vd, var_index| {
            if (vd.scope_level != 0) continue;
            try self.recordFunctionVarOriginOldestFirst(allocator, fd, vd, var_index);
        }

        self.observed_vars_len = fd.vars.len;
        self.dirty = false;
    }

    fn readyFor(self: *const DeclarationConflictIndex, fd: *const function_def_mod.FunctionDef) bool {
        return !self.dirty and self.observed_vars_len == fd.vars.len;
    }
};

pub const DeclarationConflictIndexRegistry =
    std.AutoHashMapUnmanaged(*function_def_mod.FunctionDef, DeclarationConflictIndex);

/// Register a variable declaration in `function_def.vars`.
/// Mirrors `add_scope_var` (`quickjs.c:23577`). `kind` selects
/// the `VarKind` (normal for `var`, normal + is_lexical for let,
/// normal + is_lexical + is_const for const). Returns the var
/// index. Currently informational only; the interim pipeline
/// ignores `function_def` and relies on global fallback for all
/// var references.
pub const ScopeVarOptions = struct { is_lexical: bool = false, is_const: bool = false };

/// Parser-time declaration classes accepted by QuickJS `define_var`.
/// Private names and pseudo locals deliberately bypass this API, just
/// as upstream uses add_private_class_field/add_var for those rows.
pub const DefineVarType = enum {
    with_,
    let_,
    const_,
    function_decl,
    new_function_decl,
    catch_,
    var_,
};

/// The physical binding selected by `defineVar`.  QuickJS encodes the
/// same three outcomes as a local index, ARGUMENT_VAR_OFFSET, or
/// GLOBAL_VAR_OFFSET; a tagged result avoids importing those C bit
/// sentinels into Zig consumers.
pub const DefinedVar = union(enum) {
    local: u16,
    argument: u16,
    global,
};

pub const LexicalDeclaration = union(enum) {
    local: u16,
    global,
};

/// Return a complete index or null for the legacy scan path. Dirty
/// indices are rebuilt into a temporary owner and replaced only after
/// the complete topology has been indexed successfully.
pub fn declarationConflictIndex(
    s: *State,
    fd: *function_def_mod.FunctionDef,
) Error!?*DeclarationConflictIndex {
    if (s.declaration_conflict_indices.getPtr(fd)) |existing| {
        if (existing.readyFor(fd)) return existing;
        existing.dirty = true;
    }
    if (fd.vars.len < declaration_conflict_index_threshold) return null;

    const allocator = s.function.memory.allocator;
    var candidate: DeclarationConflictIndex = .{};
    var candidate_owned = true;
    defer if (candidate_owned) candidate.deinit(allocator);
    candidate.build(allocator, fd) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidTopology => return null,
    };

    if (s.declaration_conflict_indices.getPtr(fd)) |existing| {
        const replaced = existing.*;
        existing.* = candidate;
        candidate = replaced;
        return existing;
    }

    try s.declaration_conflict_indices.put(allocator, fd, candidate);
    candidate_owned = false;
    return s.declaration_conflict_indices.getPtr(fd) orelse unreachable;
}

pub fn readyDeclarationConflictIndexForWrite(
    s: *State,
    fd: *function_def_mod.FunctionDef,
) ?*DeclarationConflictIndex {
    const index = s.declaration_conflict_indices.getPtr(fd) orelse return null;
    if (!index.readyFor(fd)) {
        index.dirty = true;
        return null;
    }
    return index;
}

pub fn discardDeclarationConflictIndex(
    s: *State,
    fd: *function_def_mod.FunctionDef,
) void {
    if (s.declaration_conflict_indices.getPtr(fd)) |index| {
        index.deinit(s.function.memory.allocator);
        _ = s.declaration_conflict_indices.remove(fd);
    }
}

pub fn deinitDeclarationConflictIndices(s: *State) void {
    const allocator = s.function.memory.allocator;
    var iterator = s.declaration_conflict_indices.iterator();
    while (iterator.next()) |entry| {
        entry.value_ptr.deinit(allocator);
    }
    s.declaration_conflict_indices.deinit(allocator);
    s.declaration_conflict_indices = .empty;
}

/// Reserve the sole possible exact-scope key before the authoritative
/// FunctionDef append. Once the append succeeds, publishing the cache
/// update is allocation-free.
pub fn prepareLinkedDeclarationIndexWrite(
    s: *State,
    fd: *function_def_mod.FunctionDef,
    name: Atom,
    kind: function_def_mod.VarKind,
    is_lexical: bool,
) Error!bool {
    const index = readyDeclarationConflictIndexForWrite(s, fd) orelse return false;
    if (!is_lexical and kind != .catch_) return true;
    const key = DeclarationConflictIndex.scopeNameKey(s.scope_level, name) orelse {
        index.dirty = true;
        return false;
    };
    if (!index.scope_names.contains(key)) {
        const needed = std.math.add(
            usize,
            @as(usize, @intCast(index.scope_names.count())),
            1,
        ) catch return error.OutOfMemory;
        try index.scope_names.ensureTotalCapacity(
            s.function.memory.allocator,
            @intCast(needed),
        );
    }
    return true;
}

pub fn commitLinkedDeclarationIndexWrite(
    s: *State,
    fd: *function_def_mod.FunctionDef,
    var_index: i32,
    prepared: bool,
) void {
    if (!prepared) return;
    const index = s.declaration_conflict_indices.getPtr(fd) orelse return;
    if (index.dirty or
        var_index < 0 or
        @as(usize, @intCast(var_index)) + 1 != fd.vars.len or
        index.observed_vars_len + 1 != fd.vars.len)
    {
        index.dirty = true;
        return;
    }
    const vd = fd.vars[@intCast(var_index)];
    if (vd.is_lexical or vd.var_kind == .catch_) {
        const key = DeclarationConflictIndex.scopeNameKey(vd.scope_level, vd.var_name) orelse {
            index.dirty = true;
            return;
        };
        if (!index.scope_names.contains(key)) {
            index.scope_names.putAssumeCapacity(key, .{});
        }
        const value = index.scope_names.getPtr(key) orelse unreachable;
        if (vd.is_lexical) value.newest_lexical = @intCast(var_index);
        value.newest_lexical_or_catch = @intCast(var_index);
    }
    index.observed_vars_len = fd.vars.len;
}

/// A parser-time function var conflicts with lexical declarations in
/// its origin scope and every ancestor. Reserve all missing keys before
/// appending the unlinked scope-0 row.
pub fn prepareFunctionVarOriginIndexWrite(
    s: *State,
    fd: *function_def_mod.FunctionDef,
    name: Atom,
    origin_scope: i32,
) Error!bool {
    const index = readyDeclarationConflictIndexForWrite(s, fd) orelse return false;
    var missing: usize = 0;
    var scope = origin_scope;
    var visited: usize = 0;
    while (scope >= 0) : (visited += 1) {
        if (visited >= fd.scopes.len or @as(usize, @intCast(scope)) >= fd.scopes.len) {
            index.dirty = true;
            return false;
        }
        const key = DeclarationConflictIndex.scopeNameKey(scope, name) orelse {
            index.dirty = true;
            return false;
        };
        if (!index.scope_names.contains(key)) missing += 1;
        scope = fd.scopes[@intCast(scope)].parent;
    }
    if (missing != 0) {
        const needed = std.math.add(
            usize,
            @as(usize, @intCast(index.scope_names.count())),
            missing,
        ) catch return error.OutOfMemory;
        try index.scope_names.ensureTotalCapacity(
            s.function.memory.allocator,
            @intCast(needed),
        );
    }
    return true;
}

pub fn commitFunctionVarOriginIndexWrite(
    s: *State,
    fd: *function_def_mod.FunctionDef,
    var_index: i32,
    origin_scope: i32,
    prepared: bool,
) void {
    if (!prepared) return;
    const index = s.declaration_conflict_indices.getPtr(fd) orelse return;
    if (index.dirty or
        var_index < 0 or
        @as(usize, @intCast(var_index)) + 1 != fd.vars.len or
        index.observed_vars_len + 1 != fd.vars.len)
    {
        index.dirty = true;
        return;
    }
    const vd = fd.vars[@intCast(var_index)];
    var scope = origin_scope;
    var visited: usize = 0;
    while (scope >= 0) : (visited += 1) {
        if (visited >= fd.scopes.len or @as(usize, @intCast(scope)) >= fd.scopes.len) {
            index.dirty = true;
            return;
        }
        const key = DeclarationConflictIndex.scopeNameKey(scope, vd.var_name) orelse {
            index.dirty = true;
            return;
        };
        if (!index.scope_names.contains(key)) {
            index.scope_names.putAssumeCapacity(key, .{});
        }
        const value = index.scope_names.getPtr(key) orelse unreachable;
        if (value.oldest_child_function_var == no_declaration_index) {
            value.oldest_child_function_var = @intCast(var_index);
        }
        scope = fd.scopes[@intCast(scope)].parent;
    }
    index.observed_vars_len = fd.vars.len;
}

pub fn findIndexedLexicalDeclaration(
    s: *State,
    index: *const DeclarationConflictIndex,
    fd: *const function_def_mod.FunctionDef,
    name: Atom,
    check_catch: bool,
) error{InvalidTopology}!?u16 {
    var scope = s.scope_level;
    var visited: usize = 0;
    while (scope >= 0) : (visited += 1) {
        if (visited >= fd.scopes.len or @as(usize, @intCast(scope)) >= fd.scopes.len) {
            return error.InvalidTopology;
        }
        const key = DeclarationConflictIndex.scopeNameKey(scope, name) orelse
            return error.InvalidTopology;
        if (index.scope_names.get(key)) |entry| {
            const raw_index = if (check_catch)
                entry.newest_lexical_or_catch
            else
                entry.newest_lexical;
            if (raw_index != no_declaration_index) {
                if (@as(usize, @intCast(raw_index)) >= fd.vars.len or
                    raw_index > std.math.maxInt(u16))
                {
                    return error.InvalidTopology;
                }
                return @intCast(raw_index);
            }
        }
        scope = fd.scopes[@intCast(scope)].parent;
    }
    return null;
}

pub fn findLexicalDeclaration(
    s: *State,
    name: Atom,
    check_catch: bool,
) Error!?LexicalDeclaration {
    const fd = s.curFunc();
    if (try declarationConflictIndex(s, fd)) |index| {
        const indexed = findIndexedLexicalDeclaration(s, index, fd, name, check_catch) catch {
            index.dirty = true;
            return findLexicalDeclarationLegacy(s, name, check_catch);
        };
        if (indexed) |var_index| return .{ .local = var_index };
        if (fd.is_eval and
            !fd.is_direct_eval and
            !fd.is_indirect_eval and
            !fd.is_module and
            findLexicalGlobalVar(s, name))
        {
            return .global;
        }
        return null;
    }
    return findLexicalDeclarationLegacy(s, name, check_catch);
}

/// Authoritative QuickJS `find_lexical_decl` scan
/// (`quickjs.c:24087`). The parser-only index below is derived from
/// this exact linked topology and falls back here when unavailable or
/// dirty. Only global-eval (not module/direct eval) adds the
/// GLOBAL_VAR_OFFSET lexical fallback.
pub fn findLexicalDeclarationLegacy(s: *State, name: Atom, check_catch: bool) ?LexicalDeclaration {
    const fd = s.curFunc();
    var var_idx = fd.scope_first;
    var visited: usize = 0;
    while (var_idx >= 0 and visited <= fd.vars.len) : (visited += 1) {
        if (@as(usize, @intCast(var_idx)) >= fd.vars.len) break;
        const vd = fd.vars[@intCast(var_idx)];
        if (vd.var_name == name and (vd.is_lexical or (check_catch and vd.var_kind == .catch_))) {
            return .{ .local = @intCast(var_idx) };
        }
        var_idx = vd.scope_next;
    }
    if (fd.is_eval and
        !fd.is_direct_eval and
        !fd.is_indirect_eval and
        !fd.is_module and
        findLexicalGlobalVar(s, name))
    {
        return .global;
    }
    return null;
}

pub fn findFunctionVarInChildScope(
    s: *State,
    name: Atom,
    scope_level: i32,
) Error!?u16 {
    const fd = s.curFunc();
    if (try declarationConflictIndex(s, fd)) |index| {
        const key = DeclarationConflictIndex.scopeNameKey(scope_level, name) orelse {
            index.dirty = true;
            return findFunctionVarInChildScopeLegacy(s, name, scope_level);
        };
        if (index.scope_names.get(key)) |entry| {
            const raw_index = entry.oldest_child_function_var;
            if (raw_index != no_declaration_index) {
                if (@as(usize, @intCast(raw_index)) >= fd.vars.len or
                    raw_index > std.math.maxInt(u16))
                {
                    index.dirty = true;
                    return findFunctionVarInChildScopeLegacy(s, name, scope_level);
                }
                return @intCast(raw_index);
            }
        }
        return null;
    }
    return findFunctionVarInChildScopeLegacy(s, name, scope_level);
}

/// QuickJS `find_var_in_child_scope` (quickjs.c:24048).  A function
/// `var` remains a scope-0 row, but until final scope-link rebuilding
/// its `scope_next` field is the lexical scope where the declaration
/// occurred.  Such rows are intentionally absent from scope.first.
pub fn findFunctionVarInChildScopeLegacy(s: *State, name: Atom, scope_level: i32) ?u16 {
    for (s.curFunc().vars, 0..) |vd, idx| {
        if (vd.var_name != name or vd.scope_level != 0) continue;
        if (s.isChildScope(vd.scope_next, scope_level)) return @intCast(idx);
    }
    return null;
}

/// qjs find_lexical_global_var (quickjs.c:24078): a global_vars entry with
/// is_lexical set (a top-level let/const declared as JS_CLOSURE_GLOBAL_DECL).
pub fn findLexicalGlobalVar(s: *State, name: Atom) bool {
    for (s.curFunc().global_vars) |gv| {
        if (gv.var_name == name and gv.is_lexical) return true;
    }
    return false;
}

pub fn findFunctionScopeVar(s: *State, name: Atom) ?u16 {
    const vars = s.curFunc().vars;
    var i = vars.len;
    while (i > 0) {
        i -= 1;
        if (vars[i].var_name == name and vars[i].scope_level == 0) return @intCast(i);
    }
    return null;
}

pub fn scopeHasVar(s: *State, scope_idx: i32, name: Atom) bool {
    if (scope_idx < 0 or @as(usize, @intCast(scope_idx)) >= s.curFunc().scopes.len) return false;
    var var_idx = s.curFunc().scopes[@intCast(scope_idx)].first;
    while (var_idx >= 0 and @as(usize, @intCast(var_idx)) < s.curFunc().vars.len) {
        const var_def = s.curFunc().vars[@intCast(var_idx)];
        if (var_def.scope_level != scope_idx) break;
        if (var_def.var_name == name) return true;
        var_idx = var_def.scope_next;
    }
    return false;
}

pub fn visibleLexicalScopeVar(s: *State, name: Atom) ?u16 {
    var scope_idx = s.scope_level;
    while (scope_idx >= 0 and @as(usize, @intCast(scope_idx)) < s.curFunc().scopes.len) {
        var var_idx = s.curFunc().scopes[@intCast(scope_idx)].first;
        while (var_idx >= 0 and @as(usize, @intCast(var_idx)) < s.curFunc().vars.len) {
            const var_def = s.curFunc().vars[@intCast(var_idx)];
            if (var_def.scope_level != scope_idx) break;
            if (var_def.var_name == name and var_def.is_lexical) return @intCast(var_idx);
            var_idx = var_def.scope_next;
        }
        scope_idx = s.curFunc().scopes[@intCast(scope_idx)].parent;
    }
    return null;
}

/// Single declaration-semantics owner mirroring QuickJS `define_var`
/// (quickjs.c:24303).  Syntax-token restrictions stay in the thin
/// producer wrappers; every scope collision and physical row choice
/// belongs here.
pub fn defineVar(s: *State, name: Atom, var_def_type: DefineVarType) Error!DefinedVar {
    const fd = s.curFunc();
    switch (var_def_type) {
        .with_ => {
            return .{ .local = @intCast(try addScopeVar(s, name, .normal, .{})) };
        },
        .let_, .const_, .function_decl, .new_function_decl => {
            if (try findLexicalDeclaration(s, name, true)) |decl| switch (decl) {
                .local => |idx| {
                    const existing = fd.vars[idx];
                    if (existing.scope_level == s.scope_level) {
                        const sloppy_function_redefinition = !fd.is_strict_mode and
                            var_def_type == .function_decl and
                            existing.var_kind == .function_decl;
                        if (!sloppy_function_redefinition)
                            return s.failExpectedDescription("non-conflicting declaration");
                    } else if (existing.var_kind == .catch_ and existing.scope_level + 2 == s.scope_level) {
                        return s.failExpectedDescription("non-conflicting declaration");
                    }
                },
                .global => if (s.atFunctionBodyScope())
                    return s.failExpectedDescription("non-conflicting declaration"),
            };

            if (var_def_type != .function_decl and
                var_def_type != .new_function_decl and
                s.atFunctionBodyScope() and
                fd.findArg(name) >= 0)
            {
                return s.failExpectedDescription("non-conflicting declaration");
            }
            if (try findFunctionVarInChildScope(s, name, s.scope_level) != null) {
                return s.failExpectedDescription("non-conflicting declaration");
            }
            if (fd.is_global_var) {
                if (s.firstGlobalVarIndex(name)) |global_idx| {
                    const gv = fd.global_vars[global_idx];
                    if (s.isChildScope(gv.scope_level, s.scope_level)) {
                        return s.failExpectedDescription("non-conflicting declaration");
                    }
                }
            }

            // eval_type GLOBAL/MODULE body lexicals are declaration
            // carriers, not frame locals.  Direct eval deliberately
            // takes the add_scope_var branch even when sloppy.
            if (fd.is_eval and
                !fd.is_direct_eval and
                !fd.is_indirect_eval and
                s.atFunctionBodyScope())
            {
                try addGlobalVar(s, name, .{ .is_lexical = true, .is_const = var_def_type == .const_ });
                return .global;
            }

            const kind: function_def_mod.VarKind = switch (var_def_type) {
                .function_decl => .function_decl,
                .new_function_decl => .new_function_decl,
                else => .normal,
            };
            return .{ .local = @intCast(try addScopeVar(s, name, kind, .{
                .is_lexical = true,
                .is_const = var_def_type == .const_,
            })) };
        },
        .catch_ => {
            return .{ .local = @intCast(try addScopeVar(s, name, .catch_, .{})) };
        },
        .var_ => {
            if (try findLexicalDeclaration(s, name, false) != null) {
                return s.failExpectedDescription("non-conflicting declaration");
            }
            if (fd.is_global_var) {
                if (s.firstGlobalVarIndex(name)) |global_idx| {
                    const gv = fd.global_vars[global_idx];
                    if (gv.is_lexical and
                        gv.scope_level == s.scope_level and
                        fd.is_module)
                    {
                        return s.failExpectedDescription("non-conflicting declaration");
                    }
                }
                try addGlobalVar(s, name, .{});
                return .global;
            }
            if (findFunctionScopeVar(s, name)) |idx| return .{ .local = idx };
            const arg_idx = fd.findArg(name);
            if (arg_idx >= 0) return .{ .argument = @intCast(arg_idx) };

            const idx = try appendFunctionVarAtOrigin(s, name, s.scope_level);
            if (identifiers.atomNameEquals(s, name, "arguments") and fd.has_arguments_binding) {
                fd.arguments_var_idx = idx;
            }
            return .{ .local = idx };
        },
    }
}

pub fn addScopeVar(s: *State, name: Atom, kind: function_def_mod.VarKind, options: ScopeVarOptions) Error!i32 {
    const is_lexical = options.is_lexical;
    const is_const = options.is_const;
    const fd = s.curFunc();
    const index_prepared = try prepareLinkedDeclarationIndexWrite(
        s,
        fd,
        name,
        kind,
        is_lexical,
    );
    const var_index = try fd.addScopeVar(
        name,
        kind,
        s.scope_level,
        is_lexical,
        is_const,
    );
    commitLinkedDeclarationIndexWrite(s, fd, var_index, index_prepared);
    return var_index;
}

pub fn addGlobalVar(s: *State, name: Atom, options: ScopeVarOptions) Error!void {
    const is_lexical = options.is_lexical;
    const is_const = options.is_const;
    return try s.curFunc().appendGlobalVar(.{
        .cpool_idx = -1,
        .force_init = false,
        .is_configurable = s.eval_global_var_bindings and !is_lexical,
        .is_lexical = is_lexical,
        .is_const = is_const,
        .scope_level = s.scope_level,
        .var_name = name,
    });
}

pub fn addGlobalAnnexBFunctionVar(s: *State, name: Atom, is_configurable: bool) Error!void {
    return try s.curFunc().appendGlobalVar(.{
        .cpool_idx = -1,
        // QuickJS only forces the Annex-B var copy in strict code;
        // Annex B itself is a sloppy-code rule, so this declaration
        // must not be classified as a global function initializer.
        .force_init = false,
        .is_configurable = is_configurable,
        .is_lexical = false,
        .is_const = false,
        .scope_level = 0,
        .var_name = name,
    });
}

pub fn addDirectEvalVarObjectVar(s: *State, name: Atom) Error!void {
    const fd = s.curFunc();
    try fd.appendGlobalVar(.{
        .cpool_idx = -1,
        .force_init = true,
        .is_configurable = true,
        .is_lexical = false,
        .is_const = false,
        .scope_level = 0,
        .var_name = name,
    });
}

/// Index of the function-scope var row for `name`, appending one when it
/// does not exist yet. Mirrors qjs `add_var` reuse in define_var.
pub fn ensureFunctionScopeVar(s: *State, name: Atom) Error!u16 {
    if (findFunctionScopeVar(s, name)) |idx| return idx;
    // Annex-B's create_func_var path calls add_var directly and thus
    // never links this row into scope 0's lexical chain.  Zero is the
    // parser-era origin value left by QuickJS's zero-initialized row.
    return try appendFunctionVarAtOrigin(s, name, 0);
}

/// qjs find_global_var (quickjs.c:24066): any global_vars entry with this
/// name — top-level var, hoisted function declaration, or lexical.
pub fn findGlobalVar(s: *State, name: Atom) bool {
    for (s.curFunc().global_vars) |gv| {
        if (gv.var_name == name) return true;
    }
    return false;
}

pub fn appendFunctionVarAtOrigin(s: *State, name: Atom, origin_scope: i32) Error!u16 {
    const fd = s.curFunc();
    const index_prepared = try prepareFunctionVarOriginIndexWrite(s, fd, name, origin_scope);
    const idx = try fd.appendVar(.{
        .var_name = name,
        .scope_level = 0,
        .scope_next = origin_scope,
        .is_lexical = false,
        .is_const = false,
        .var_kind = .normal,
    });
    commitFunctionVarOriginIndexWrite(s, fd, idx, origin_scope, index_prepared);
    return @intCast(idx);
}

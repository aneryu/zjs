//! `FunctionDefImpl` — mirrors `JSFunctionDef`.
//!
//! This is the Phase 1 compilation state used by the parser to
//! collect variable bindings, scopes, labels, and temporary bytecode.
//! After Phase 2/Phase 3 pipeline, it's lowered to `FunctionBytecode`
//! (`JSFunctionBytecode` at `quickjs.c`).

const std = @import("std");
const bytecode = @import("../bytecode.zig");
const builtin = @import("builtin");
const atom = @import("../core/atom.zig");
const bigint_mod = @import("../core/bigint.zig");
const runtime = @import("../runtime.zig");
const JSValue = @import("../core/value.zig").JSValue;
const compiler = @import("../compiler/root.zig");
const FunctionBytecode = bytecode.FunctionBytecode;
const pipeline = bytecode.pipeline;
const module = bytecode.module;
const function_bytecode = bytecode.function_bytecode;
const binding_rules = bytecode.binding_rules;

const function_bytecode_mod = function_bytecode;

fn freeOwnedValue(value: JSValue, rt: anytype) void {
    // A constant-pool BigInt that never reached a published
    // FunctionBytecode is still reserved: nothing else will free it.
    if (bigint_mod.BigInt.destroyIfReservedValue(rt, value)) return;
}

pub const FunctionKind = function_bytecode_mod.FunctionKind;

/// Mirrors `JSParseFunctionEnum`.
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

pub const ClosureType = function_bytecode_mod.ClosureType;
pub const VarKind = function_bytecode_mod.VarKind;
pub const VarDef = function_bytecode_mod.VarDef;

/// Mirrors `JSVarScope`.
pub const VarScope = struct {
    parent: i32, // index into scopes of the enclosing scope
    first: i32, // index into vars of the last variable in this scope
};

pub const ClosureVar = function_bytecode_mod.ClosureVar;

pub const EvalBindingTarget = function_bytecode_mod.EvalBindingTarget;

pub const GlobalVar = function_bytecode_mod.GlobalVar;

/// Compile-only state for the single QuickJS `js_create_function`
/// preparation pass.  A FunctionDef is prepared before any child and is
/// resolved only after every child has completed.
pub const FinalizationState = enum {
    unprepared,
    prepared,
    resolved,
};

pub const ScopeLinkCache = enum { disabled, unproven, proven };

// Shared with the parser route test; production has no counters or stores.
pub const ScopeProofTestCounters = if (builtin.is_test) struct {
    pub threadlocal var validations: usize = 0;
    pub threadlocal var cache_hits: usize = 0;
} else void;

/// Generic geometric growth helper for FunctionDefImpl hot buffers.
///
/// Maintains the contract that `slice.*.len` is the *used* count while the
/// allocator-owned backing buffer is `slice.*.ptr[0..capacity.*]`. Returns a
/// writable view of the freshly grown tail (length `n`).
///
/// Each append used to do `alloc(old + n) + memcpy + free(old)`, making
/// repeated appends O(n²). Geometric growth (capacity doubling, with an
/// 8-element floor) reduces total cost to amortised O(1) per item.
inline fn growSliceBy(
    comptime T: type,
    allocator: std.mem.Allocator,
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
    const new_buf = try allocator.alloc(T, new_cap);
    if (used != 0) @memcpy(new_buf[0..used], slice.ptr[0..used]);
    var old_buf: []T = &.{};
    if (capacity.* != 0) old_buf = slice.ptr[0..capacity.*];
    slice.* = new_buf[0..new_used];
    capacity.* = new_cap;
    if (old_buf.len != 0) allocator.free(old_buf);
    return slice.ptr[used..new_used];
}

/// Free the full backing buffer of a growable slice and reset both the
/// visible slice and its capacity.
fn freeGrowableSlice(
    comptime T: type,
    allocator: std.mem.Allocator,
    slice: *[]T,
    capacity: *usize,
) void {
    var old_buf: []T = &.{};
    if (capacity.* != 0) old_buf = slice.ptr[0..capacity.*];
    slice.* = &.{};
    capacity.* = 0;
    if (old_buf.len != 0) allocator.free(old_buf);
}

fn freeGrowableAtomSlice(
    allocator: std.mem.Allocator,
    slice: *[]atom.Atom,
    capacity: *usize,
) void {
    const items = slice.*;
    const old_capacity = capacity.*;
    slice.* = &.{};
    capacity.* = 0;
    if (old_capacity != 0) {
        allocator.free(items.ptr[0..old_capacity]);
    } else if (items.len != 0) {
        allocator.free(items);
    }
}

fn freeGrowableNamedSlice(
    comptime T: type,
    allocator: std.mem.Allocator,
    slice: *[]T,
    capacity: *usize,
) void {
    const items = slice.*;
    const old_capacity = capacity.*;
    slice.* = &.{};
    capacity.* = 0;
    if (old_capacity != 0) {
        allocator.free(items.ptr[0..old_capacity]);
    } else if (items.len != 0) {
        allocator.free(items);
    }
}

/// Mirrors `JSFunctionDef`.
pub const FunctionDefImpl = struct {
    /// Ordinary buffers. Same account as `artifacts`, probed on alloc.
    allocator: std.mem.Allocator,
    /// Facade that owns `function_var_index`. It outlives the parser arena
    /// and does not fire the per-allocation probe.
    artifacts: std.mem.Allocator,
    atoms: *atom.AtomTable,
    parent: ?*FunctionDefImpl = null,
    discard_next: ?*FunctionDefImpl = null,
    /// This child's slot in the parent's constant pool once appended.
    parent_cpool_idx: ?u16 = null,
    parent_scope_level: i32 = 0,
    parent_parameter_environment_only: bool = false,

    // Flags — packed as in QuickJS
    is_eval: bool = false,
    is_global_var: bool = false,
    is_module: bool = false,
    is_direct_eval: bool = false,
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
    need_home_object: bool = false,
    use_short_opcodes: bool = false,
    is_indirect_eval: bool = false,
    /// QuickJS reaches `var_object_test` (qjs:32973) only from binding-walk
    /// events: a `<with>` row on the current chain (qjs:33037-33042), the
    /// current function's var_object/arg_var_object (qjs:33180-33192), a
    /// parent-chain environment (qjs:33217-33267), or an eval closure row
    /// (qjs:33307).  It never asks "may this function need dynamic-env
    /// probes" once per operand.  This monotone flag records that a
    /// runtime-var-ref closure row naming a dynamic-env object atom was
    /// appended (see `addClosureVar`, the single closure-row growth path),
    /// so resolve_variables can gate its per-op probe qualification on one
    /// load.  Never cleared: rows are never removed, so a true value stays
    /// an exact "such a row exists" fact for the def's lifetime, and a
    /// false value proves no probe walk can ever be required.
    closure_var_may_have_dynamic_env: bool = false,

    func_kind: FunctionKind = .normal,
    func_type: ParseFunctionKind = .statement,
    is_strict_mode: bool = false,
    /// qjs `fd->is_func_expr && fd->func_name != JS_ATOM_NULL`: this def
    /// is a *named* function expression. Its self-binding var
    /// (`func_var_idx`, kind `.function_name`) and the matching
    /// `special_object THIS_FUNC ; put_loc` prologue materialize lazily on
    /// the first falling-through reference — mirroring qjs, where
    /// add_func_var is only called from resolve_scope_var
    /// and add_eval_variables
    ///, never unconditionally.
    is_named_func_expr: bool = false,
    func_name: atom.Atom,

    // Variables
    vars: []VarDef = &.{},
    vars_capacity: usize = 0,
    vars_htab: []u32 = &.{},
    /// Newest scope-0 (function-level) row per name: the flat `find_var`
    /// pass that follows a lexical-chain miss (qjs `var_htab`). Built on
    /// demand once the function has enough rows for the linear scan to
    /// matter, and brought up to date on demand: rows are append-only and
    /// a row never changes scope, so catching up is exact.
    function_var_index: std.AutoHashMapUnmanaged(u32, u16) = .empty,
    function_var_indexed_len: usize = 0,
    var_count: i32 = 0,
    args: []VarDef = &.{},
    args_capacity: usize = 0,
    arg_count: i32 = 0,
    defined_arg_count: i32 = 0,
    /// qjs `JSFunctionDef.var_ref_count`: number of local/argument
    /// bindings captured so far. It is advanced by the first capture
    /// event, independently from `closure_var_count` (which describes
    /// cells imported by this function from its parent).
    var_ref_count: i32 = 0,
    finalization_state: FinalizationState = .unprepared,
    /// Enabled only while this def is an active finalizer ancestor. A
    /// structural proof, not finalization_state, advances it to proven.
    /// Parsing and standalone resolver calls never retain a cached proof.
    scope_link_cache: ScopeLinkCache = .disabled,
    var_object_idx: ?u16 = null,
    arg_var_object_idx: ?u16 = null,
    arguments_var_idx: ?u16 = null,
    arguments_arg_idx: ?u16 = null,
    func_var_idx: ?u16 = null,
    this_var_idx: ?u16 = null,
    new_target_var_idx: ?u16 = null,
    this_active_func_var_idx: ?u16 = null,
    home_object_var_idx: ?u16 = null,

    // Scopes
    scope_level: i32 = 0,
    /// Scope whose OP_enter_scope is intentionally suppressed because
    /// instantiate_hoisted_definitions and its lexical initialization are
    /// injected at the function body boundary.  Like QuickJS, a freshly
    /// allocated FunctionDef has no body until its parser/default-ctor
    /// producer pushes one; the synthetic class-fields aggregator is the
    /// intentional no-body exception.
    body_scope: i32 = -1,
    scope_first: i32 = -1,
    scope_count: i32 = 0,
    scopes: []VarScope = &.{},
    scopes_capacity: usize = 0,

    // Global variables
    global_vars: []GlobalVar = &.{},
    global_vars_capacity: usize = 0,
    global_var_count: i32 = 0,

    /// Compact temporary-bytecode emission backend for this function.
    /// Heap-allocated when parse begins; released in `deinit` or at the
    /// resolve_variables consumption point. One optional pointer keeps
    /// `@sizeOf` impact minimal.
    builder: ?*compiler.Builder = null,

    // Constant pool
    cpool: []JSValue = &.{},
    cpool_capacity: usize = 0,
    cpool_count: i32 = 0,

    // Closure variables
    closure_var: []ClosureVar = &.{},
    closure_var_capacity: usize = 0,
    closure_var_count: i32 = 0,

    // pc2line table
    filename: atom.Atom,
    /// Stable ScriptOrModule identity, separately owned from `filename` so
    /// direct eval can retain its caller's referrer while displaying <eval>.
    script_or_module: atom.Atom,
    // Source coordinates are one-based at the compiler boundary. Even a
    // synthetic/no-source FunctionDef therefore has the canonical (1,1)
    // pc2line header rather than a separate zero-coordinate sentinel.
    line_num: i32 = 1,
    col_num: i32 = 1,
    /// Logical source bytes backed by a `len + 1` allocation with a NUL at
    /// `source_text[len]`. Finalization transfers this exact owner to the FB.
    source_text: ?[:0]const u8 = null,

    // Child functions (nested functions)
    child_list: []*FunctionDefImpl = &.{},
    child_list_capacity: usize = 0,

    pub fn init(allocator: std.mem.Allocator, artifacts: std.mem.Allocator, atoms: *atom.AtomTable, name: atom.Atom) FunctionDefImpl {
        return .{
            .allocator = allocator,
            .artifacts = artifacts,
            .atoms = atoms,
            .func_name = name,
            .filename = name,
            .script_or_module = name,
        };
    }

    pub fn replaceSourceText(self: *FunctionDefImpl, source: []const u8) !void {
        const allocation_len = std.math.add(usize, source.len, 1) catch return error.OutOfMemory;
        const allocation = try self.allocator.alloc(u8, allocation_len);
        @memcpy(allocation[0..source.len], source);
        allocation[source.len] = 0;
        const owned: [:0]const u8 = allocation[0..source.len :0];
        const old = self.source_text;
        self.source_text = owned;
        if (old) |existing| self.allocator.free(@constCast(existing.ptr[0 .. existing.len + 1]));
    }

    pub fn deinitInitFailure(self: *FunctionDefImpl) void {
        self.func_name = atom.null_atom;
        self.filename = atom.null_atom;
        self.script_or_module = atom.null_atom;
        // A root emitter attaches its Builder before the first token is
        // lexed (`ParseState.initRootEmitter`), so an initializer that
        // fails after that point owns one exactly like a fully built
        // FunctionDef does. Release it on the same terms as `deinit`.
        if (self.builder) |v2b| {
            self.builder = null;
            v2b.deinit();
            self.allocator.destroy(v2b);
        }
        freeGrowableSlice(VarScope, self.allocator, &self.scopes, &self.scopes_capacity);
        self.scope_count = 0;
    }

    /// Append a `VarScope` to `scopes`. Mirrors `push_scope`
    ///: the new scope records its parent index
    /// and inherits the current visible binding head. Returns the index
    /// of the newly added scope (== new `scope_level`).
    pub fn appendScope(self: *FunctionDefImpl, parent: i32) !i32 {
        self.invalidateScopeLinkCache();
        const tail = try growSliceBy(VarScope, self.allocator, &self.scopes, &self.scopes_capacity, 1);
        tail[0] = .{ .parent = parent, .first = self.scope_first };
        self.scope_count += 1;
        const idx: i32 = @intCast(self.scopes.len - 1);
        return idx;
    }

    /// Destructively rebuild the final scope linkage once, exactly where
    /// QuickJS does so at the start of `js_create_function`
    ///. From this point onward `scopes[].first`
    /// and `VarDef.scope_next` are the sole lexical-chain authority.
    pub fn rebuildFinalScopeLinks(self: *FunctionDefImpl) error{InvalidScope}!void {
        self.invalidateScopeLinkCache();
        if (self.scopes.len == 0 or self.scope_count != @as(i32, @intCast(self.scopes.len))) return error.InvalidScope;
        if (self.scopes[0].parent != -1) return error.InvalidScope;
        if (self.has_parameter_expressions) {
            if (self.scopes.len <= 1 or self.scopes[1].parent != -1) return error.InvalidScope;
        }
        if (self.body_scope >= 0 and @as(usize, @intCast(self.body_scope)) >= self.scopes.len) {
            return error.InvalidScope;
        }

        for (self.scopes, 0..) |*scope, scope_index| {
            if (scope_index != 0) {
                if (scope.parent < -1 or
                    (scope.parent >= 0 and @as(usize, @intCast(scope.parent)) >= scope_index))
                {
                    return error.InvalidScope;
                }
            }
            scope.first = -1;
        }
        if (self.has_parameter_expressions) {
            self.scopes[1].first = function_bytecode_mod.arg_scope_end;
        }

        for (self.vars, 0..) |*vd, index| {
            if (vd.scope_level < 0 or @as(usize, @intCast(vd.scope_level)) >= self.scopes.len) {
                return error.InvalidScope;
            }
            vd.scope_next = self.scopes[@intCast(vd.scope_level)].first;
            self.scopes[@intCast(vd.scope_level)].first = @intCast(index);
        }
        var scope_index: usize = 2;
        while (scope_index < self.scopes.len) : (scope_index += 1) {
            const parent = self.scopes[scope_index].parent;
            if (parent < 0) return error.InvalidScope;
            if (self.scopes[scope_index].first < 0) {
                self.scopes[scope_index].first = self.scopes[@intCast(parent)].first;
            }
        }
        for (self.vars) |*vd| {
            if (vd.scope_next < 0 and vd.scope_level > 1) {
                const parent = self.scopes[@intCast(vd.scope_level)].parent;
                if (parent < 0) return error.InvalidScope;
                vd.scope_next = self.scopes[@intCast(parent)].first;
            }
        }

        self.scope_first = if (self.scope_level >= 0 and
            @as(usize, @intCast(self.scope_level)) < self.scopes.len)
            self.scopes[@intCast(self.scope_level)].first
        else
            -1;
    }

    /// Prove the finalized lexical topology without allocating or changing
    /// it.  QuickJS rebuilds these links once in `js_create_function`, then
    /// its resolver consumes them without per-node bounds/cycle checks.  V2
    /// always proves the current function at resolution entry. Active
    /// ancestors may share a proof until the next topology mutation, while
    /// standalone walkers retain their defensive checks.
    ///
    /// Scope 0 and scope 1 have independent terminal sentinels.  Every
    /// deeper scope either owns an exact-scope prefix or inherits its
    /// already-proven parent head, matching `rebuildFinalScopeLinks` above.
    pub fn validateFinalScopeLinks(self: *const FunctionDefImpl) error{InvalidScope}!void {
        if (builtin.is_test) ScopeProofTestCounters.validations += 1;
        if (self.scopes.len == 0) {
            // Synthetic resolve_variables fixtures may contain no lexical
            // scopes at all.  The retained per-operand scope bound prevents
            // a trusted walker from indexing this vacuous topology.
            if (self.scope_count != 0 or self.body_scope >= 0 or self.scope_first != -1) {
                return error.InvalidScope;
            }
            return;
        }
        if (self.scopes.len > std.math.maxInt(i32) or
            self.vars.len > @as(usize, std.math.maxInt(u16)) + 1 or
            self.scope_count != @as(i32, @intCast(self.scopes.len)))
        {
            return error.InvalidScope;
        }
        if (self.scopes[0].parent != -1) return error.InvalidScope;
        if (self.has_parameter_expressions and
            (self.scopes.len <= 1 or self.scopes[1].parent != -1))
        {
            return error.InvalidScope;
        }
        if (self.body_scope >= 0 and @as(usize, @intCast(self.body_scope)) >= self.scopes.len) {
            return error.InvalidScope;
        }

        for (self.scopes, 0..) |scope, scope_index| {
            if (scope_index != 0 and
                (scope.parent < -1 or
                    (scope.parent >= 0 and @as(usize, @intCast(scope.parent)) >= scope_index)))
            {
                return error.InvalidScope;
            }
            if (scope_index >= 2 and scope.parent < 0) return error.InvalidScope;

            const expected_terminal: i32 = if (scope_index == 0)
                -1
            else if (scope_index == 1)
                if (self.has_parameter_expressions)
                    function_bytecode_mod.arg_scope_end
                else
                    -1
            else
                self.scopes[@intCast(scope.parent)].first;

            var index = scope.first;
            var visited: usize = 0;
            while (index != expected_terminal) {
                if (index < 0 or
                    @as(usize, @intCast(index)) >= self.vars.len or
                    visited >= self.vars.len)
                {
                    return error.InvalidScope;
                }
                visited += 1;
                const vd = self.vars[@intCast(index)];
                if (vd.scope_level != @as(i32, @intCast(scope_index))) {
                    return error.InvalidScope;
                }
                index = vd.scope_next;
            }
        }

        // Unlinked pseudo rows are valid, but every row still names a real
        // lexical level.  This also protects later flat scope-0 scans.
        for (self.vars) |vd| {
            if (vd.scope_level < 0 or @as(usize, @intCast(vd.scope_level)) >= self.scopes.len) {
                return error.InvalidScope;
            }
        }
    }

    fn invalidateScopeLinkCache(self: *FunctionDefImpl) void {
        if (self.scope_link_cache != .disabled) self.scope_link_cache = .unproven;
    }

    pub fn proveAncestorScopeLinks(self: *FunctionDefImpl) error{InvalidScope}!void {
        if (self.scope_link_cache == .proven) {
            if (builtin.is_test) ScopeProofTestCounters.cache_hits += 1;
            return;
        }
        try self.validateFinalScopeLinks();
        if (self.scope_link_cache == .unproven) self.scope_link_cache = .proven;
    }

    /// Release the parse-only GlobalVar ledger only after its hoist plan
    /// has been installed successfully into resolved bytecode.
    pub fn consumeGlobalVars(self: *FunctionDefImpl) void {
        const globals = self.global_vars;
        const capacity = self.global_vars_capacity;
        self.global_vars = &.{};
        self.global_vars_capacity = 0;
        self.global_var_count = 0;
        for (globals) |*gv| {
            gv.var_name = atom.null_atom;
        }
        if (capacity != 0) self.allocator.free(globals.ptr[0..capacity]);
    }

    /// Mirror qjs add_func_var: create the named
    /// function expression's self-binding var on demand, idempotent via
    /// `func_var_idx`. QuickJS marks the binding const only when the
    /// defining function is strict; sloppy writes are discarded during
    /// scope resolution instead of reaching the runtime cell.
    pub fn ensureFuncExprSelfBinding(self: *FunctionDefImpl) !u16 {
        if (self.func_var_idx) |idx| return idx;
        // add_func_var uses add_var, not add_scope_var: the binding is
        // a special fallback after ordinary scopes/vars/arguments and
        // must not participate in the lexical scope linked list.
        const idx: u16 = @intCast(try self.appendVar(.{
            .var_name = self.func_name,
            .scope_level = 0,
            // qjs add_var zero-initializes scope_next. These special
            // fallbacks are intentionally outside scopes[].first.
            .scope_next = 0,
            .is_const = self.is_strict_mode,
            .var_kind = .function_name,
        }));
        self.func_var_idx = idx;
        return idx;
    }

    /// QuickJS pseudo bindings are appended with `add_var`, after the
    /// ordinary scope graph has been built. They are deliberately absent
    /// from `scopes[].first`: `resolve_pseudo_var` reaches them only after
    /// ordinary current-scope lookup has failed.
    pub fn ensureThisBinding(self: *FunctionDefImpl) !u16 {
        if (self.this_var_idx) |idx| return idx;
        const idx: u16 = @intCast(try self.appendVar(.{
            .var_name = atom.ids.this_,
            .scope_level = 0,
            .scope_next = 0,
            .is_lexical = self.is_derived_class_constructor,
            .var_kind = .normal,
        }));
        if (self.is_derived_class_constructor) {
            // resolve_labels owns the single TDZ initialization in
            // the function prologue.
            self.vars[idx].tdz_emitted_at_decl = true;
        }
        self.this_var_idx = idx;
        return idx;
    }

    pub fn ensureNewTargetBinding(self: *FunctionDefImpl) !u16 {
        if (self.new_target_var_idx) |idx| return idx;
        const idx: u16 = @intCast(try self.appendVar(.{
            .var_name = atom.ids.new_target,
            .scope_level = 0,
            .scope_next = 0,
            .var_kind = .normal,
        }));
        self.new_target_var_idx = idx;
        return idx;
    }

    pub fn ensureThisActiveFunctionBinding(self: *FunctionDefImpl) !u16 {
        if (self.this_active_func_var_idx) |idx| return idx;
        const idx: u16 = @intCast(try self.appendVar(.{
            .var_name = atom.ids.this_active_func,
            .scope_level = 0,
            .scope_next = 0,
            .var_kind = .normal,
        }));
        self.this_active_func_var_idx = idx;
        return idx;
    }

    pub fn ensureHomeObjectBinding(self: *FunctionDefImpl) !u16 {
        // QuickJS publishes need_home_object when either the explicit
        // parser bit or the resolved home-object pseudo local is present.
        self.need_home_object = true;
        if (self.home_object_var_idx) |idx| return idx;
        const idx: u16 = @intCast(try self.appendVar(.{
            .var_name = atom.ids.home_object,
            .scope_level = 0,
            .scope_next = 0,
            .var_kind = .normal,
        }));
        self.home_object_var_idx = idx;
        return idx;
    }

    /// Mirror qjs add_arguments_var: the field, rather than a name scan,
    /// owns the identity. An explicit parameter named `arguments` does
    /// not suppress this pseudo binding when direct eval requires it.
    pub fn ensureArgumentsBinding(self: *FunctionDefImpl) !u16 {
        if (self.arguments_var_idx) |idx| return idx;
        const idx: u16 = @intCast(try self.appendVar(.{
            .var_name = atom.ids.arguments,
            .scope_level = 0,
            .scope_next = 0,
            .var_kind = .normal,
        }));
        self.arguments_var_idx = idx;
        return idx;
    }

    /// Mirror qjs add_arguments_arg. This is the sole pseudo binding that
    /// is manually linked into a scope after normal scope construction.
    /// If an explicit parameter binding already occupies argument scope,
    /// it wins and no synthetic alias is recorded for the prologue copy.
    pub fn ensureArgumentsArgumentBinding(self: *FunctionDefImpl) !void {
        // This is callable after the ordinary one-shot rebuild, including
        // while a descendant resolves a prepared parent.  Refuse malformed
        // input before following it, and leave a freshly proven topology
        // before any caller can resume a trusted production walk.
        try self.validateFinalScopeLinks();
        if (self.arguments_arg_idx != null) return;
        const argument_scope_level: i32 = 1;
        if (@as(usize, @intCast(argument_scope_level)) >= self.scopes.len) {
            return error.InvalidScope;
        }

        var scope_idx = self.scopes[@intCast(argument_scope_level)].first;
        while (scope_idx >= 0) {
            if (@as(usize, @intCast(scope_idx)) >= self.vars.len) return error.InvalidScope;
            const vd = self.vars[@intCast(scope_idx)];
            if (vd.scope_level != argument_scope_level) break;
            if (vd.var_name == atom.ids.arguments) return;
            scope_idx = vd.scope_next;
        }

        const idx = try self.appendVar(.{
            .var_name = atom.ids.arguments,
            .scope_level = argument_scope_level,
            .scope_next = self.scopes[@intCast(argument_scope_level)].first,
            .is_lexical = true,
            .var_kind = .normal,
        });
        self.scopes[@intCast(argument_scope_level)].first = idx;
        self.arguments_arg_idx = @intCast(idx);
        try self.validateFinalScopeLinks();
    }

    /// `arguments_var_idx` is also used for the lazy pseudo binding that
    /// represents the function's body arguments object. A source-level
    /// `var arguments` replaces that pseudo row with a real function var;
    /// its parser origin is retained in `scope_next` (the synthetic row
    /// has the zero origin used by `add_var`). Parameter-initializer
    /// closures need this distinction: without a body declaration they
    /// share the function arguments binding, while `var arguments`
    /// deliberately shadows it with a separate body binding.
    pub fn hasExplicitArgumentsVar(self: *const FunctionDefImpl) bool {
        const idx: usize = self.arguments_var_idx orelse return false;
        if (idx >= self.vars.len) return false;
        return self.vars[idx].scope_next != 0;
    }

    /// Append a `VarDef` to `vars`. Mirrors `add_var`
    ///. The caller is responsible for setting
    /// `scope_level`, `var_kind`, `is_lexical`, `is_const`. The atom id
    /// is copied by value; the atom table is not consulted.
    /// Returns the index of the new var.
    pub fn appendVar(self: *FunctionDefImpl, var_def: VarDef) !i32 {
        self.invalidateScopeLinkCache();
        const tail = try growSliceBy(VarDef, self.allocator, &self.vars, &self.vars_capacity, 1);
        tail[0] = var_def;
        tail[0].var_name = var_def.var_name;
        self.var_count += 1;
        const idx: i32 = @intCast(self.vars.len - 1);
        return idx;
    }

    pub fn appendGlobalVar(self: *FunctionDefImpl, global_var: GlobalVar) !void {
        const tail = try growSliceBy(GlobalVar, self.allocator, &self.global_vars, &self.global_vars_capacity, 1);
        tail[0] = global_var;
        tail[0].var_name = global_var.var_name;
        self.global_var_count = @intCast(self.global_vars.len);
    }

    /// Append a formal argument definition. Mirrors the `args` side of
    /// QuickJS function metadata; parser lowering resolves matching
    /// identifier references to `get_arg*` opcodes.
    pub fn appendArg(self: *FunctionDefImpl, var_def: VarDef) !i32 {
        const tail = try growSliceBy(VarDef, self.allocator, &self.args, &self.args_capacity, 1);
        tail[0] = var_def;
        tail[0].var_name = var_def.var_name;
        self.arg_count = @intCast(self.args.len);
        self.defined_arg_count = @intCast(self.args.len);
        return @intCast(self.args.len - 1);
    }

    /// Append a child FunctionDefImpl to `child_list`. Mirrors
    /// `list_add_tail(&fd->link, &parent->child_list)` in
    /// `js_new_function_def`. The parent takes
    /// ownership of the child pointer.
    pub fn addChild(self: *FunctionDefImpl, child: *FunctionDefImpl) !void {
        const tail = try growSliceBy(*FunctionDefImpl, self.allocator, &self.child_list, &self.child_list_capacity, 1);
        child.parent = self;
        child.discard_next = null;
        tail[0] = child;
    }

    /// Mirror `add_scope_var`: add a var and
    /// attach it to `scope_level`'s scope (updates `scope_first`).
    pub const ScopeVarOptions = struct { is_lexical: bool = false, is_const: bool = false };

    pub fn addScopeVar(
        self: *FunctionDefImpl,
        name: atom.Atom,
        var_kind: VarKind,
        scope_level: i32,
        options: ScopeVarOptions,
    ) !i32 {
        const is_lexical = options.is_lexical;
        const is_const = options.is_const;
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
    pub fn addClosureVar(self: *FunctionDefImpl, init_value: ClosureVar.Init) !i32 {
        const tail = try growSliceBy(ClosureVar, self.allocator, &self.closure_var, &self.closure_var_capacity, 1);
        tail[0] = ClosureVar.init(init_value);
        tail[0].var_name = init_value.var_name;
        self.closure_var_count = @intCast(self.closure_var.len);
        // Maintain the dynamic-env possibility flag at the single growth
        // point (qjs:32973 var_object_test precondition; see the field
        // doc).  The predicate mirrors the resolver's per-row test in
        // `closureVarRangeHasDynamicEnvObjects` exactly.
        if (binding_rules.closureVarIsRuntimeVarRef(tail[0]) and
            binding_rules.isDynamicEnvObjectAtom(tail[0].var_name))
        {
            self.closure_var_may_have_dynamic_env = true;
        }
        return @intCast(self.closure_var.len - 1);
    }

    const CaptureError = error{ InvalidBytecode, BytecodeOverflow };

    fn captureBinding(self: *FunctionDefImpl, vd: *VarDef) CaptureError!void {
        if (vd.open_binding_idx != function_bytecode_mod.no_open_binding) {
            vd.is_captured = true;
            return;
        }
        if (self.var_ref_count < 0) return error.InvalidBytecode;
        const next: u32 = @intCast(self.var_ref_count);
        if (next >= function_bytecode_mod.no_open_binding) return error.BytecodeOverflow;
        vd.is_captured = true;
        vd.open_binding_idx = @intCast(next);
        self.var_ref_count += 1;
    }

    /// qjs `capture_var(fd, &fd->vars[idx])`: the first real capture event
    /// assigns the stable owner-frame cell index immediately.
    pub fn captureLocal(self: *FunctionDefImpl, idx: usize) CaptureError!void {
        if (idx >= self.vars.len) return error.InvalidBytecode;
        try self.captureBinding(&self.vars[idx]);
    }

    /// qjs `capture_var(fd, &fd->args[idx])`.
    pub fn captureArg(self: *FunctionDefImpl, idx: usize) CaptureError!void {
        if (idx >= self.args.len) return error.InvalidBytecode;
        try self.captureBinding(&self.args[idx]);
    }

    const function_var_index_threshold: usize = 32;

    /// The newest function-level (`scope_level == 0`) var named `name`:
    /// QuickJS's `find_var` after the finalized lexical chain missed.
    /// Small functions scan; large ones consult `function_var_index`.
    pub fn findFunctionVar(self: *FunctionDefImpl, name: atom.Atom) ?u16 {
        if (self.vars.len < function_var_index_threshold) return self.scanFunctionVar(name);
        if (self.function_var_indexed_len < self.vars.len) {
            self.catchUpFunctionVarIndex() catch return self.scanFunctionVar(name);
        }
        return self.function_var_index.get(name.raw());
    }

    fn scanFunctionVar(self: *const FunctionDefImpl, name: atom.Atom) ?u16 {
        var i = self.vars.len;
        while (i > 0) {
            i -= 1;
            const vd = &self.vars[i];
            if (vd.var_name == name and vd.scope_level == 0) return @intCast(i);
        }
        return null;
    }

    fn catchUpFunctionVarIndex(self: *FunctionDefImpl) !void {
        // The artifact facade, not the native allocator: FunctionDefs
        // outlive the parser's arena redirect and must free where they
        // allocated.
        const allocator = self.artifacts;
        try self.function_var_index.ensureUnusedCapacity(allocator, @intCast(self.vars.len - self.function_var_indexed_len));
        for (self.vars[self.function_var_indexed_len..], self.function_var_indexed_len..) |vd, i| {
            // Later rows overwrite earlier ones: newest wins, as in the scan.
            if (vd.scope_level == 0) self.function_var_index.putAssumeCapacity(vd.var_name.raw(), @intCast(i));
        }
        self.function_var_indexed_len = self.vars.len;
    }

    /// Find a var by name, searching newest-first. Returns the var
    /// index or `-1` if not found. Mirrors the htab-free path of
    /// `find_var`.
    pub fn findVar(self: *const FunctionDefImpl, name: atom.Atom) i32 {
        var i: usize = self.vars.len;
        while (i > 0) {
            i -= 1;
            if (self.vars[i].var_name == name) return @intCast(i);
        }
        return -1;
    }

    pub fn findArg(self: *const FunctionDefImpl, name: atom.Atom) i32 {
        var i: usize = self.args.len;
        while (i > 0) {
            i -= 1;
            if (self.args[i].var_name == name) return @intCast(i);
        }
        return -1;
    }

    pub fn appendCpool(self: *FunctionDefImpl, value: JSValue) !u32 {
        const tail = try growSliceBy(JSValue, self.allocator, &self.cpool, &self.cpool_capacity, 1);
        tail[0] = value;
        self.cpool_count = @intCast(self.cpool.len);
        return @intCast(self.cpool.len - 1);
    }

    /// Historic rc-era spelling of `appendCpool`. Under the tracing GC
    /// the pool never took a reference, so the two were byte-identical.
    pub const appendCpoolOwned = appendCpool;

    /// TGC S3-b: precise root for the GC values this def holds while the
    /// compile is in flight.
    ///
    /// `cpool` is the only GC-typed storage a `FunctionDef` owns, and it is
    /// the one that matters. What lands there: a RegExp literal's pattern
    /// and compiled-bytecode strings, a tagged template's frozen array
    /// pair, the cpool-string form of a numeric-name literal, and one
    /// reserved slot per nested function that
    /// `installChildFunctionBytecodes` later fills with the child's
    /// `FunctionBytecode`. (Ordinary string literals do NOT: they become
    /// `push_atom_value` atoms, which is the S3-b atom half. A cpool
    /// BigInt is present but is deliberately unregistered until the
    /// artifact is published, so the tracer neither marks nor sweeps it.)
    ///
    /// Until `createFunctionBytecode` publishes the artifact that plain
    /// `[]JSValue` on the Zig heap is the ONLY holder -- it is not on the
    /// stack, so even the conservative scan cannot see it, and no tracer
    /// edge reaches it. `cpool_count` is maintained equal to `cpool.len`
    /// at every growth point, so the slice is the live set.
    ///
    /// The child walk recurses. Depth is the source's function-nesting
    /// depth, which the parser already bounded with its own native
    /// stack-overflow guard while using frames orders of magnitude larger
    /// than this one, so anything that parsed can be walked here.
    pub fn traceCompileRoots(
        self: *FunctionDefImpl,
        visitor: *runtime.RootVisitor,
    ) runtime.RootTraceError!void {
        try visitor.values(self.cpool);
        for (self.child_list) |child| try child.traceCompileRoots(visitor);
    }

    pub fn deinit(self: *FunctionDefImpl, rt: anytype) void {
        self.func_name = atom.null_atom;
        self.filename = atom.null_atom;
        self.script_or_module = atom.null_atom;

        // Parse-time/error-path backstop; successful v2 lowering
        // releases the builder at its consumption point.
        if (self.builder) |v2b| {
            self.builder = null;
            v2b.deinit();
            self.allocator.destroy(v2b);
        }

        freeGrowableNamedSlice(VarDef, self.allocator, &self.vars, &self.vars_capacity);
        if (self.vars_htab.len != 0) self.allocator.free(self.vars_htab);
        self.function_var_index.deinit(self.artifacts);
        self.function_var_indexed_len = 0;

        freeGrowableNamedSlice(VarDef, self.allocator, &self.args, &self.args_capacity);

        freeGrowableSlice(VarScope, self.allocator, &self.scopes, &self.scopes_capacity);

        freeGrowableNamedSlice(GlobalVar, self.allocator, &self.global_vars, &self.global_vars_capacity);

        const old_cpool = self.cpool;
        const old_cpool_capacity = self.cpool_capacity;
        self.cpool = &.{};
        self.cpool_capacity = 0;
        self.cpool_count = 0;
        for (old_cpool) |*slot| {
            const value = slot.*;
            slot.* = JSValue.undefinedValue();
            freeOwnedValue(value, rt);
        }
        if (old_cpool_capacity != 0) self.allocator.free(old_cpool.ptr[0..old_cpool_capacity]);

        freeGrowableNamedSlice(ClosureVar, self.allocator, &self.closure_var, &self.closure_var_capacity);

        if (self.source_text) |source| self.allocator.free(@constCast(source.ptr[0 .. source.len + 1]));

        const old_child_list = self.child_list;
        const old_child_list_capacity = self.child_list_capacity;
        self.child_list = &.{};
        self.child_list_capacity = 0;
        for (old_child_list) |child| {
            child.deinit(rt);
            self.allocator.destroy(child);
        }

        self.vars_htab = &.{};
        self.discard_next = null;
        self.source_text = null;
        if (old_child_list_capacity != 0) self.allocator.free(old_child_list.ptr[0..old_child_list_capacity]);
    }
};

pub const FunctionDef = FunctionDefImpl;

test "findFunctionVar returns the newest scope-0 row through the lazy index" {
    const rt = try runtime.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    var fd = FunctionDefImpl.init(rt.nativeAllocator(), rt.nativeAllocator(), rt.atoms, try rt.internAtom("var-index"));
    defer fd.deinit(rt);
    _ = try fd.appendScope(-1);
    const target = try rt.internAtom("target");
    const other = try rt.internAtom("other");
    // Below the index threshold: the linear scan answers.
    _ = try fd.appendVar(.{ .var_name = target, .scope_level = 0 });
    try std.testing.expectEqual(@as(?u16, 0), fd.findFunctionVar(target));
    try std.testing.expectEqual(@as(?u16, null), fd.findFunctionVar(other));
    // Grow past the threshold; a block-scoped row with the name must
    // not shadow the function-level one, a newer function-level row must.
    for (0..FunctionDefImpl.function_var_index_threshold) |_| {
        _ = try fd.appendVar(.{ .var_name = other, .scope_level = 1 });
    }
    try std.testing.expectEqual(@as(?u16, 0), fd.findFunctionVar(target));
    try std.testing.expectEqual(@as(?u16, null), fd.findFunctionVar(other));
    const newest = try fd.appendVar(.{ .var_name = target, .scope_level = 0 });
    try std.testing.expectEqual(@as(?u16, @intCast(newest)), fd.findFunctionVar(target));
    const other_fn = try fd.appendVar(.{ .var_name = other, .scope_level = 0 });
    try std.testing.expectEqual(@as(?u16, @intCast(other_fn)), fd.findFunctionVar(other));
}

test "scope proof cache invalidates variable scope and late arguments mutations" {
    const rt = try runtime.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const name = try rt.internAtom("scope-cache");
    var fd = FunctionDefImpl.init(rt.nativeAllocator(), rt.nativeAllocator(), rt.atoms, name);
    defer fd.deinit(rt);
    _ = try fd.appendScope(-1);
    _ = try fd.appendScope(-1);
    fd.has_parameter_expressions = true;
    try fd.rebuildFinalScopeLinks();

    // Standalone proof calls never enable persistence themselves.
    try fd.proveAncestorScopeLinks();
    try std.testing.expectEqual(ScopeLinkCache.disabled, fd.scope_link_cache);
    fd.scope_link_cache = .unproven;
    try fd.proveAncestorScopeLinks();
    const before = ScopeProofTestCounters.validations;
    const hits_before = ScopeProofTestCounters.cache_hits;
    try fd.proveAncestorScopeLinks();
    try std.testing.expectEqual(before, ScopeProofTestCounters.validations);
    try std.testing.expectEqual(hits_before + 1, ScopeProofTestCounters.cache_hits);

    const bad = try fd.appendVar(.{ .var_name = name, .scope_level = 99 });
    try std.testing.expectEqual(ScopeLinkCache.unproven, fd.scope_link_cache);
    try std.testing.expectError(error.InvalidScope, fd.proveAncestorScopeLinks());
    try std.testing.expectEqual(ScopeLinkCache.unproven, fd.scope_link_cache);
    fd.vars[@intCast(bad)].scope_level = 0;
    try fd.proveAncestorScopeLinks();

    _ = try fd.addScopeVar(name, .normal, 1, .{ .is_lexical = true });
    try std.testing.expectEqual(ScopeLinkCache.unproven, fd.scope_link_cache);
    try fd.proveAncestorScopeLinks();
    try fd.ensureArgumentsArgumentBinding();
    try std.testing.expectEqual(ScopeLinkCache.unproven, fd.scope_link_cache);
    try fd.proveAncestorScopeLinks();

    const scope = try fd.appendScope(-1);
    try std.testing.expectEqual(ScopeLinkCache.unproven, fd.scope_link_cache);
    try std.testing.expectError(error.InvalidScope, fd.proveAncestorScopeLinks());
    fd.scopes[@intCast(scope)] = .{ .parent = 1, .first = fd.scopes[1].first };
    try fd.proveAncestorScopeLinks();
    try fd.rebuildFinalScopeLinks();
    try std.testing.expectEqual(ScopeLinkCache.unproven, fd.scope_link_cache);
    try fd.proveAncestorScopeLinks();

    // Revoking the traversal lease restores defensive standalone calls,
    // including callers that directly mutate the public fixture fields.
    fd.scope_link_cache = .disabled;
    const alias: usize = fd.arguments_arg_idx.?;
    fd.vars[alias].scope_next = @intCast(alias);
    try std.testing.expectError(error.InvalidScope, fd.proveAncestorScopeLinks());
}

//! QuickJS-aligned parser.
//!
//! Mirrors `js_parse_expr` family in `quickjs.c:27049..27645` row-for-row:
//!
//!     parseExpr            -> parseExpr2(PF_IN_ACCEPTED)
//!     parseExpr2(flags)    -> parseAssignExpr2(flags); while ',' { drop ; ... }
//!     parseAssignExpr2     -> parseCondExpr(flags); if assign-op { ... }
//!     parseCondExpr        -> parseCoalesceExpr; if '?' { ... }
//!     parseCoalesceExpr    -> parseLogicalAndOr(OP_or); if '??' { ... }
//!     parseLogicalAndOr    -> parseExprBinary(level=8) ; while op_match { ... }
//!     parseExprBinary(L,f) -> if L==0 parseUnary ; switch(L) on token table
//!     parseUnary           -> handle delete/void/typeof/+/-/~/!/++/--/await ; ** if PF_POW_ALLOWED
//!     parsePostfixExpr     -> parseLhsExpr ; postfix ++/--
//!     parseLhsExpr         -> primary or new ... ; member chain
//!
//! This parser emits real QuickJS opcode ids (`bytecode.opcode.op.<name>`)
//! into the bytecode buffer and is validated against QuickJS semantics through
//! focused conformance and regression slices.
//!
//! This module coexists with the legacy `frontend/parser.zig`
//! (QuickParser) until the remaining legacy callers are retired.

const std = @import("std");

const atom_module = @import("../core/atom.zig");
const core_bigint = @import("../core/bigint.zig");
const core = @import("../core/root.zig");
const regexp_validate = @import("../libs/regexp_validate.zig");
const libs_bignum = @import("../libs/bignum.zig");
const unicode = @import("../libs/unicode.zig");
const memory = @import("../core/memory.zig");
const JSValue = @import("../core/value.zig").JSValue;

const bytecode_function = @import("../bytecode/function.zig");
const function_def_mod = @import("../bytecode/function_def.zig");
const bytecode_module = @import("../bytecode/module.zig");
const opcode = @import("../bytecode/opcode.zig");

const lexer_mod = @import("zjs_lexer.zig");
const tok = @import("zjs_token.zig");

const Atom = atom_module.Atom;

const eval_class_field_initializer_flag: u16 = 0x8000;
const eval_parameter_initializer_flag: u16 = 0x4000;
const atom_this: Atom = 8; // "this"
const atom_new_target: Atom = 115; // "new.target"
const atom_this_active_func: Atom = 116; // "this.active_func"
const atom_class_fields_init: Atom = 120; // "<class_fields_init>"
const shared_iterator_close_marker: u8 = 255;
const direct_iterator_close_marker: u8 = 254;

pub const Error = lexer_mod.Error || error{
    UnexpectedToken,
    InvalidLhs,
    InvalidNumberLiteral,
    InvalidIdentifier,
    InvalidAssignmentTarget,
    YieldOutsideGenerator,
    AwaitOutsideAsyncFunction,
    SyntaxError,
};

/// Parse flags mirror the QuickJS `PF_*` macros (`quickjs.c:21358..21370`).
pub const ParseFlags = packed struct(u32) {
    in_accepted: bool = false,
    pow_allowed: bool = false,
    arrow_func: bool = false,
    trailing_comma_ok: bool = false,
    result_needed: bool = true,
    yield_forbidden: bool = false,
    _padding: u26 = 0,

    pub const default = ParseFlags{ .in_accepted = true };
};

fn forceResultNeeded(flags: ParseFlags) ParseFlags {
    var value_flags = flags;
    value_flags.result_needed = true;
    return value_flags;
}

/// Mirror `quickjs.c:21352` — BlockEnv for break/continue/finally tracking.
pub const BlockEnv = struct {
    prev: ?*BlockEnv,
    label_name: Atom,
    label_break: i32,
    label_cont: i32,
    drop_count: i32,
    label_finally: i32,
    scope_level: i32,
    has_iterator: bool,
    is_regular_stmt: bool,
};

const LabelFrame = struct {
    atom: Atom,
    allow_continue: bool,
    catch_marker_depth: u32,
    control_frame_depth: usize,
    break_fixups: std.ArrayList(usize) = .empty,
    continue_fixups: std.ArrayList(usize) = .empty,

    fn deinit(self: *LabelFrame, allocator: std.mem.Allocator) void {
        self.break_fixups.deinit(allocator);
        self.continue_fixups.deinit(allocator);
    }
};

const ControlFrames = struct {
    break_fixups: std.ArrayList(usize),
    break_frame_lens: std.ArrayList(usize),
    break_frame_catch_marker_depths: std.ArrayList(u32),
    break_frame_cleanup_drops: std.ArrayList(u8),
    break_frame_cross_cleanup_drops: std.ArrayList(u8),
    continue_fixups: std.ArrayList(usize),
    continue_frame_lens: std.ArrayList(usize),
    continue_frame_catch_marker_depths: std.ArrayList(u32),
    continue_frame_cleanup_drops: std.ArrayList(u8),
    label_frames: std.ArrayList(LabelFrame),
    pending_label_atom: ?Atom,
    active_catch_marker_depth: u32,
    droppable_rethrow_marker_count: u32,
    using_block_frames: std.ArrayList(UsingBlockFrame),
};

const ReturnFinallyFrame = struct {
    value_loc: u16,
    catch_marker_depth: u32,
    break_depth: usize,
    continue_depth: usize,
    label_depth: usize,
    fixups: std.ArrayList(usize) = .empty,
    break_fixups: std.ArrayList(usize) = .empty,
    continue_fixups: std.ArrayList(usize) = .empty,
    labelled_break_fixups: std.ArrayList(LabelledFinallyControlFixup) = .empty,
    labelled_continue_fixups: std.ArrayList(LabelledFinallyControlFixup) = .empty,

    fn deinit(self: *ReturnFinallyFrame, allocator: std.mem.Allocator) void {
        self.fixups.deinit(allocator);
        self.break_fixups.deinit(allocator);
        self.continue_fixups.deinit(allocator);
        self.labelled_break_fixups.deinit(allocator);
        self.labelled_continue_fixups.deinit(allocator);
    }
};

const LabelledFinallyControlFixup = struct {
    off: usize,
    atom_id: Atom,
};

const BlockScopeDecls = struct {
    scope_level: i32,
    function_depth: usize,
    lexical_names: std.ArrayList(Atom) = .empty,
    var_names: std.ArrayList(Atom) = .empty,

    fn deinit(self: *BlockScopeDecls, allocator: std.mem.Allocator) void {
        self.lexical_names.deinit(allocator);
        self.var_names.deinit(allocator);
    }
};

const UsingStackKind = enum {
    sync,
    async,
};

const UsingBlockFrame = struct {
    stack_loc: ?u16 = null,
    catch_marker_depth: u32 = 0,
    kind: UsingStackKind = .sync,
};

const ClassPrivateElementKind = enum {
    field,
    method,
    getter,
    setter,
};

const ClassPrivateElement = struct {
    atom: Atom,
    kind: ClassPrivateElementKind,
    is_static: bool,
};

const ReturnFinallyBoundary = struct {
    frames: std.ArrayList(ReturnFinallyFrame),
    suppress_capture: u32,
    suppress_capture_depth: usize,
    suppress_capture_end: usize,
    pending_abrupt_frames: std.ArrayList(FinallyPendingAbruptFrame),
};

const ReturnFinallyCaptureSuppression = struct {
    count: u32,
    depth: usize,
    end: usize,
};

const FinallyPendingAbruptFrame = struct {
    break_depth: usize,
    continue_depth: usize,
    label_depth: usize,
};

const FinallyControlKind = enum {
    @"break",
    @"continue",
};

const FinallyControlTarget = struct {
    kind: FinallyControlKind,
    label_atom: ?Atom = null,
};

/// Declaration mask for `parseStatementOrDecl`. Mirrors QuickJS `DECL_MASK_*`.
pub const DeclMask = packed struct(u32) {
    func: bool = false,
    func_with_label: bool = false,
    other: bool = false,
    _padding: u29 = 0,
};

/// Function kind. Mirrors QuickJS `JSFunctionKindEnum`.
pub const FunctionKind = enum {
    normal,
    generator,
    async,
    async_generator,
};

/// Parse function kind. Mirrors QuickJS `JSParseFunctionEnum`.
pub const ParseFunctionKind = enum {
    normal,
    generator,
    async,
    async_generator,
    arrow,
    method,
    get,
    set,
    class_constructor,
    derived_class_constructor,
    class_static_block,
};

pub const Feature = enum {
    expression,
    statement,
    function_,
    arrow,
    async_function,
    generator,
    async_generator,
    class_,
    private_name,
    destructuring,
    spread_rest,
    dynamic_import,
};

/// Class element kind. Mirrors QuickJS class element types.
pub const ClassElementKind = enum {
    field,
    method,
    getter,
    setter,
    static_field,
    static_method,
    static_getter,
    static_setter,
    private_field,
    private_method,
    private_getter,
    private_setter,
    static_block,
};

/// `JSParseState` analogue for expression, statement, function, and class parsing.
pub const ParseState = struct {
    lex: *lexer_mod.Lexer,
    function: *bytecode_function.Bytecode,
    runtime: ?*core.JSRuntime = null,
    /// One-token lookahead. The lexer is the source of truth; we cache
    /// the most recently produced token here so the parser can `peek`.
    token: tok.Token,
    last_token_end_offset: usize = 0,
    last_token_line_num: u32 = 1,
    last_token_col_num: u32 = 1,
    /// Block environment stack for break/continue/finally tracking.
    top_break: ?*BlockEnv = null,
    /// Current scope level (for lexical declarations).
    scope_level: i32 = 0,
    /// Whether we're in strict mode.
    is_strict: bool = false,
    /// Whether we're in an eval context.
    is_eval: bool = false,
    /// Whether non-strict `delete name` may target bindings introduced by
    /// enclosing eval code. This intentionally crosses nested function
    /// boundaries, unlike `is_eval`, because functions created by eval can
    /// delete eval-created var bindings captured in their environment.
    eval_delete_bindings: bool = false,
    /// Whether we're inside a class body.
    in_class: bool = false,
    /// Whether the current class has an extends clause.
    class_has_extends: bool = false,
    /// Whether the current class body defines a static `name` member.
    class_static_name_seen: bool = false,
    /// Whether we're in a static class element context.
    is_static: bool = false,
    /// Whether statement parsing is inside a class static initialization block.
    in_class_static_block: bool = false,
    /// Whether declarations are currently being parsed inside the synthetic
    /// CaseBlock lexical environment for a switch statement.
    in_switch_case_block_scope: bool = false,
    /// Whether `return` is syntactically allowed in the current statement body.
    return_depth: u32 = 0,
    /// Whether we're in a constructor.
    in_constructor: bool = false,
    /// Whether we are currently parsing the outermost constructor block.
    is_outer_constructor_block: bool = false,
    /// Whether `super` is syntactically allowed in the current function body.
    allow_super: bool = false,
    /// Whether direct `super(...)` constructor calls are syntactically allowed.
    allow_super_call: bool = false,
    /// Whether the last primary expression was super.
    last_was_super: bool = false,
    /// Whether the current bare callee is syntactically direct eval.
    last_was_direct_eval_callee: bool = false,
    /// Whether the last primary expression was a `with` environment
    /// identifier lowered with a retained base object for a direct call.
    last_was_with_method_ref: bool = false,
    /// Whether the last parsed comma expression actually used the comma
    /// operator. Parenthesized member calls preserve references only for
    /// single expressions, not for `(0, obj.method)()`.
    last_expr_had_comma: bool = false,
    /// Whether the last expression value can arrive through a short-circuit
    /// or conditional merge. A trailing member load in that shape cannot be
    /// promoted to a two-slot method reference for a following parenthesized
    /// call because sibling predecessors still leave one stack slot.
    last_expr_was_short_circuit_or_cond: bool = false,
    /// Prefix update parses the lvalue after consuming `++` / `--`, so
    /// the identifier parser cannot see an assignment-like lookahead.
    force_with_lvalue: bool = false,
    /// Whether we're in a generator function.
    in_generator: bool = false,
    /// Whether we're in an async function.
    in_async: bool = false,
    /// Whether parameter default initializer parsing must reject `await`.
    reject_await_in_parameter_initializer: bool = false,
    /// Whether `new.target` is syntactically allowed in the current function
    /// context. Direct eval roots inherit this from the caller; indirect eval
    /// and top-level script roots keep it false.
    new_target_allowed: bool = false,
    /// Whether to emit temporary scope opcodes for the finalize pipeline.
    /// When true, emits scope_get_var/scope_put_var/scope_get_var_undef
    /// instead of the final get_var/put_var/get_var_undef opcodes.
    ///
    /// **Default is `true`** for parser output that still needs finalization.
    /// Callers run `bytecode.pipeline.finalize.run` after parsing to
    /// lower the temp opcodes to their final shapes. The pipeline:
    ///   * shrinks scope_get_var (7 bytes) → get_var (5 bytes), and
    ///     equivalents for scope_put_var / scope_get_var_undef;
    ///   * drops enter_scope / leave_scope / OP_label entirely;
    ///   * patches every absolute u32 jump operand using an
    ///     old→new pc map so `&&`/`||`/`??`/`?:` keep working
    ///     across the byte-offset shift.
    ///
    /// Setting this to `false` skips temp emission entirely (the
    /// parser writes final-form opcodes directly), which is useful
    /// for golden-byte tests that assert the lowered shape and want
    /// to bypass the pipeline.
    emit_phase1_temp: bool = true,
    /// One-shot: the next `parseBlock` is a function/arrow body and must
    /// not emit `enter_scope` (see `emitEnterScope`).
    suppress_block_enter_scope: bool = false,

    /// Parity/tooling mode for top-level program dumps. QuickJS-ng dumps
    /// top-level lexical bindings in the eval/module wrapper as var-ref
    /// closure variables (`module_decl`) instead of ordinary local TDZ slots.
    /// Keep this opt-in so existing expression/unit-test paths retain their
    /// current local-slot behavior until full module/eval semantics land.
    top_level_lexical_as_module_ref: bool = false,
    top_level_functions_as_children: bool = false,
    eval_global_var_bindings: bool = false,
    eval_annex_b_blocked_function_names: []const Atom = &.{},
    features: std.EnumSet(Feature) = .initEmpty(),
    in_namespace: bool = false,
    current_namespace_atom: ?Atom = null,
    last_declared_atom: ?Atom = null,
    current_parameter_properties: ?std.ArrayList(Atom) = null,
    namespace_export: bool = false,

    /// QuickJS `eval_ret_idx` mirror (`quickjs.c:21480`). When ≥ 0,
    /// the slot at this local index receives the result of every
    /// expression statement (instead of the placeholder `drop`), and
    /// the caller's `finalizeEvalReturn` retrieves it at script end.
    /// `enableEvalReturn` allocates the slot using the `<ret>` atom
    /// (id 82, `quickjs-atom.h:115`). `-1` means non-eval mode.
    eval_ret_idx: i32 = -1,

    /// QuickJS `JSFunctionDef` companion state. Populated
    /// during parsing with scope chain (`pushScope`/`popScope`),
    /// variable declarations (`addScopeVar`), and later closure/label
    /// data. The FunctionDef-based `resolve_variables` / `resolve_labels`
    /// passes read from it to drive scope-chain walking, closure synthesis,
    /// TDZ, and local-slot assignment.
    ///
    /// The parser still emits to `function.code` as before; this is a
    /// parallel structure that mirrors `JSParseState.cur_func`
    /// (`quickjs.c:21581`). Tests in `qjs_parser_test.zig` assert the
    /// `vars` / `scopes` layout is populated correctly.
    function_def: function_def_mod.FunctionDef,

    /// Stack of FunctionDef pointers for nested function parsing.
    /// Mirrors `JSParseState.cur_func` stack management. The top of
    /// the stack is the current function being parsed. When entering
    /// a nested function, we push a new FunctionDef; when exiting,
    /// we pop back to the parent.
    cur_func_stack: []*function_def_mod.FunctionDef = &.{},
    cur_func_stack_capacity: usize = 0,
    discarded_func_head: ?*function_def_mod.FunctionDef = null,

    /// When true, emit bytecode to the current FunctionDef's byte_code
    /// buffer instead of the Bytecode object's code buffer. Used for
    /// nested functions to maintain separate bytecode buffers.
    emit_to_function_def: bool = false,
    pending_function_name: ?Atom = null,
    pending_function_is_decl: bool = false,
    annex_b_if_function_decl_clause: bool = false,
    function_expr_name_binding: ?Atom = null,
    in_parameter_initializer: bool = false,
    last_function_child_index: ?u16 = null,
    class_constructor_cpool_idx: ?u16 = null,
    last_anonymous_function_expr: bool = false,
    last_primary_was_arrow_function: bool = false,
    return_expr_mode: bool = false,
    return_expr_emitted_return: bool = false,
    return_expr_cond_depth: u32 = 0,
    suppress_expr_statement_drop: bool = false,
    last_var_decl_atom: ?Atom = null,
    last_var_decl_can_skip_get: bool = false,
    last_var_decl_ref_idx: ?u16 = null,
    last_class_decl_atom: ?Atom = null,
    skip_next_ident_get: ?Atom = null,
    last_lhs_was_tagged_template: bool = false,
    last_lhs_had_optional_chain: bool = false,
    destructuring_binding_is_lexical: bool = false,
    destructuring_binding_is_const: bool = false,
    destructuring_predeclare_only: bool = false,
    destructuring_assignment_target_mode: bool = false,
    suppress_destructuring_capture_retrofit: bool = false,
    collect_module_export_bindings: bool = false,
    assign_expr_depth: u32 = 0,
    last_coalesce_expr_depth: ?u32 = null,
    active_with_atom: ?Atom = null,
    active_with_func_depth: usize = 0,
    with_scope_id: u32 = 0,
    active_catch_marker_depth: u32 = 0,
    /// How many of the active catch markers are pure rethrow markers of
    /// finally-less `catch` bodies. When ALL active markers are such
    /// markers, a `return <expr>` may drop them before evaluating the
    /// expression (catch-and-rethrow equals plain propagation), putting a
    /// trailing call into tail position per HasCallInTailPosition.
    droppable_rethrow_marker_count: u32 = 0,
    emit_lexical_tdz_at_decl: bool = false,
    break_fixups: std.ArrayList(usize) = .empty,
    break_frame_lens: std.ArrayList(usize) = .empty,
    continue_fixups: std.ArrayList(usize) = .empty,
    continue_frame_lens: std.ArrayList(usize) = .empty,
    break_frame_catch_marker_depths: std.ArrayList(u32) = .empty,
    break_frame_cleanup_drops: std.ArrayList(u8) = .empty,
    break_frame_cross_cleanup_drops: std.ArrayList(u8) = .empty,
    continue_frame_catch_marker_depths: std.ArrayList(u32) = .empty,
    continue_frame_cleanup_drops: std.ArrayList(u8) = .empty,
    label_frames: std.ArrayList(LabelFrame) = .empty,
    pending_label_atom: ?Atom = null,
    return_finally_frames: std.ArrayList(ReturnFinallyFrame) = .empty,
    suppress_return_finally_capture: u32 = 0,
    suppress_return_finally_capture_depth: usize = 0,
    suppress_return_finally_capture_end: usize = 0,
    finally_pending_abrupt_frames: std.ArrayList(FinallyPendingAbruptFrame) = .empty,
    block_scope_decls: std.ArrayList(BlockScopeDecls) = .empty,
    using_block_frames: std.ArrayList(UsingBlockFrame) = .empty,
    class_private_elements: std.ArrayList(ClassPrivateElement) = .empty,
    class_private_bound_names: std.ArrayList(Atom) = .empty,
    class_public_instance_fields: std.ArrayList(Atom) = .empty,
    class_static_deferred_code: std.ArrayList(u8) = .empty,
    class_static_deferred_atoms: std.ArrayList(Atom) = .empty,
    class_fields_init_child_index: ?u16 = null,
    class_field_initializer_depth: u32 = 0,
    class_static_field_this_atom: ?Atom = null,

    pub fn init(lex: *lexer_mod.Lexer, function: *bytecode_function.Bytecode) Error!ParseState {
        var state = ParseState{
            .lex = lex,
            .function = function,
            .token = undefined,
            .function_def = function_def_mod.FunctionDef.init(function.memory, function.atoms, function.name),
        };
        errdefer state.function_def.deinitInitFailure();
        state.function_def.line_num = 1;
        state.function_def.col_num = 1;
        // Mirror `js_new_function_def` (`quickjs.c:31511`): scope 0
        // is the function's var/arg scope, parent = -1.
        _ = state.function_def.appendScope(-1) catch return error.OutOfMemory;
        state.token = try lex.next();
        // Note: cur_func_stack starts empty; cur_func() returns &function_def when empty
        return state;
    }

    /// Release ParseState-owned resources. `rt` is forwarded to
    /// `FunctionDef.deinit` so constants in `function_def.cpool` can
    /// be released. `anytype` matches `Bytecode.deinit`'s signature
    /// so callers pass their existing runtime pointer.
    pub fn deinit(self: *ParseState, rt: anytype) void {
        self.lex.freeToken(&self.token);
        // Free any nested function definitions on the stack
        const cur_func_stack = self.cur_func_stack;
        const cur_func_stack_capacity = self.cur_func_stack_capacity;
        self.cur_func_stack = &.{};
        self.cur_func_stack_capacity = 0;
        for (cur_func_stack) |fd| {
            fd.deinit(rt);
            self.function.memory.destroy(function_def_mod.FunctionDef, fd);
        }
        if (cur_func_stack_capacity != 0) {
            self.function.memory.free(*function_def_mod.FunctionDef, cur_func_stack.ptr[0..cur_func_stack_capacity]);
        }
        var discarded_func = self.discarded_func_head;
        self.discarded_func_head = null;
        while (discarded_func) |fd| {
            const next = fd.discard_next;
            fd.discard_next = null;
            fd.deinit(rt);
            self.function.memory.destroy(function_def_mod.FunctionDef, fd);
            discarded_func = next;
        }
        self.break_fixups.deinit(self.function.memory.allocator);
        self.break_frame_lens.deinit(self.function.memory.allocator);
        self.continue_fixups.deinit(self.function.memory.allocator);
        self.continue_frame_lens.deinit(self.function.memory.allocator);
        self.break_frame_catch_marker_depths.deinit(self.function.memory.allocator);
        self.break_frame_cleanup_drops.deinit(self.function.memory.allocator);
        self.break_frame_cross_cleanup_drops.deinit(self.function.memory.allocator);
        self.continue_frame_catch_marker_depths.deinit(self.function.memory.allocator);
        self.continue_frame_cleanup_drops.deinit(self.function.memory.allocator);
        for (self.label_frames.items) |*frame| {
            frame.deinit(self.function.memory.allocator);
        }
        self.label_frames.deinit(self.function.memory.allocator);
        for (self.return_finally_frames.items) |*frame| {
            frame.deinit(self.function.memory.allocator);
        }
        self.return_finally_frames.deinit(self.function.memory.allocator);
        self.finally_pending_abrupt_frames.deinit(self.function.memory.allocator);
        for (self.block_scope_decls.items) |*decls| {
            decls.deinit(self.function.memory.allocator);
        }
        self.block_scope_decls.deinit(self.function.memory.allocator);
        self.using_block_frames.deinit(self.function.memory.allocator);
        self.truncateClassPrivateElements(0);
        self.class_private_elements.deinit(self.function.memory.allocator);
        self.truncateClassPrivateBoundNames(0);
        self.class_private_bound_names.deinit(self.function.memory.allocator);
        self.truncateClassPublicInstanceFields(0);
        self.class_public_instance_fields.deinit(self.function.memory.allocator);
        self.truncateClassStaticDeferred(0, 0);
        self.class_static_deferred_code.deinit(self.function.memory.allocator);
        self.class_static_deferred_atoms.deinit(self.function.memory.allocator);
        self.function_def.deinit(rt);
    }

    /// Get the current FunctionDef from the top of the stack.
    /// Mirrors `JSParseState.cur_func` access. Returns the root
    /// function_def when the stack is empty (top-level parsing).
    fn cur_func(self: *ParseState) *function_def_mod.FunctionDef {
        if (self.cur_func_stack.len == 0) {
            return &self.function_def;
        }
        return self.cur_func_stack[self.cur_func_stack.len - 1];
    }

    fn funcAtVirtualIndex(self: *ParseState, idx: usize) *function_def_mod.FunctionDef {
        if (idx == 0) return &self.function_def;
        return self.cur_func_stack[idx - 1];
    }

    /// Push a new FunctionDef onto the stack. Called when entering
    /// a nested function. Mirrors the parent link setup in
    /// `js_new_function_def` (`quickjs.c:31484-31490`).
    fn pushFunction(self: *ParseState, fd: *function_def_mod.FunctionDef) Error!void {
        const old_len = self.cur_func_stack.len;
        const new_len = self.cur_func_stack.len + 1;

        if (new_len > self.cur_func_stack_capacity) {
            const old_capacity = self.cur_func_stack_capacity;
            var new_capacity = if (old_capacity == 0)
                @as(usize, 4)
            else
                std.math.mul(usize, old_capacity, 2) catch return error.OutOfMemory;
            if (new_capacity < new_len) new_capacity = new_len;

            const next = try self.function.memory.alloc(*function_def_mod.FunctionDef, new_capacity);
            errdefer self.function.memory.free(*function_def_mod.FunctionDef, next);
            @memcpy(next[0..old_len], self.cur_func_stack);
            const old_stack: []*function_def_mod.FunctionDef = if (old_capacity != 0) self.cur_func_stack.ptr[0..old_capacity] else self.cur_func_stack[0..0];
            self.cur_func_stack = next[0..old_len];
            self.cur_func_stack_capacity = new_capacity;
            if (old_capacity != 0) {
                self.function.memory.free(*function_def_mod.FunctionDef, old_stack);
            }
        }

        self.cur_func_stack = self.cur_func_stack.ptr[0..new_len];
        self.cur_func_stack[old_len] = fd;
    }

    /// Pop the current FunctionDef from the stack. Called when exiting
    /// a nested function. Returns the popped FunctionDef pointer.
    fn popFunction(self: *ParseState) *function_def_mod.FunctionDef {
        const fd = self.cur_func_stack[self.cur_func_stack.len - 1];
        self.cur_func_stack = self.cur_func_stack.ptr[0 .. self.cur_func_stack.len - 1];
        return fd;
    }

    fn discardCurrentFunction(self: *ParseState) void {
        const fd = self.popFunction();
        self.discardFunctionDef(fd);
    }

    fn discardFunctionDef(self: *ParseState, fd: *function_def_mod.FunctionDef) void {
        if (self.runtime) |rt| {
            fd.deinit(rt);
            self.function.memory.destroy(function_def_mod.FunctionDef, fd);
            return;
        }
        fd.discard_next = self.discarded_func_head;
        self.discarded_func_head = fd;
    }

    /// Mirror `push_scope` (`quickjs.c:23486`): allocate a new
    /// `VarScope` whose parent is the current scope, then switch
    /// `scope_level` to it. Call on entry to a new lexical block.
    pub fn pushScope(self: *ParseState) Error!void {
        const parent = self.scope_level;
        const new_scope = self.cur_func().appendScope(parent) catch return error.OutOfMemory;
        self.scope_level = new_scope;
        self.cur_func().scope_level = new_scope;
        try self.block_scope_decls.append(self.function.memory.allocator, .{
            .scope_level = new_scope,
            .function_depth = self.cur_func_stack.len,
        });
    }

    /// Mirror `pop_scope` (`quickjs.c:23532`): restore the parent
    /// scope. Also updates `function_def.scope_first` to the outer
    /// scope's first lexical var so subsequent lookups see the
    /// correct chain.
    pub fn popScope(self: *ParseState) void {
        if (self.scope_level < 0) return;
        if (self.block_scope_decls.items.len > 0) {
            const last_idx = self.block_scope_decls.items.len - 1;
            const last = &self.block_scope_decls.items[last_idx];
            if (last.scope_level == self.scope_level and last.function_depth == self.cur_func_stack.len) {
                last.deinit(self.function.memory.allocator);
                _ = self.block_scope_decls.pop().?;
            }
        }
        const parent = self.cur_func().scopes[@intCast(self.scope_level)].parent;
        self.scope_level = parent;
        self.cur_func().scope_level = parent;
        // Recompute scope_first for the new current scope (mirrors
        // `get_first_lexical_var` at `quickjs.c:23521`).
        var scope = parent;
        self.cur_func().scope_first = -1;
        while (scope >= 0) {
            const s_idx = self.cur_func().scopes[@intCast(scope)].first;
            if (s_idx >= 0) {
                self.cur_func().scope_first = s_idx;
                break;
            }
            scope = self.cur_func().scopes[@intCast(scope)].parent;
        }
    }

    /// Register a variable declaration in `function_def.vars`.
    /// Mirrors `add_scope_var` (`quickjs.c:23577`). `kind` selects
    /// the `VarKind` (normal for `var`, normal + is_lexical for let,
    /// normal + is_lexical + is_const for const). Returns the var
    /// index. Currently informational only; the interim pipeline
    /// ignores `function_def` and relies on global fallback for all
    /// var references.
    pub fn addScopeVar(
        self: *ParseState,
        name: Atom,
        kind: function_def_mod.VarKind,
        is_lexical: bool,
        is_const: bool,
    ) Error!i32 {
        return self.cur_func().addScopeVar(name, kind, self.scope_level, is_lexical, is_const) catch return error.OutOfMemory;
    }

    fn scopeHasVar(self: *ParseState, scope_idx: i32, name: Atom) bool {
        if (scope_idx < 0 or @as(usize, @intCast(scope_idx)) >= self.cur_func().scopes.len) return false;
        var var_idx = self.cur_func().scopes[@intCast(scope_idx)].first;
        while (var_idx >= 0 and @as(usize, @intCast(var_idx)) < self.cur_func().vars.len) {
            const var_def = self.cur_func().vars[@intCast(var_idx)];
            if (var_def.var_name == name) return true;
            var_idx = var_def.scope_next;
        }
        return false;
    }

    fn visibleLexicalScopeVar(self: *ParseState, name: Atom) ?u16 {
        var scope_idx = self.scope_level;
        while (scope_idx >= 0 and @as(usize, @intCast(scope_idx)) < self.cur_func().scopes.len) {
            var var_idx = self.cur_func().scopes[@intCast(scope_idx)].first;
            while (var_idx >= 0 and @as(usize, @intCast(var_idx)) < self.cur_func().vars.len) {
                const var_def = self.cur_func().vars[@intCast(var_idx)];
                if (var_def.var_name == name and var_def.is_lexical) return @intCast(var_idx);
                var_idx = var_def.scope_next;
            }
            scope_idx = self.cur_func().scopes[@intCast(scope_idx)].parent;
        }
        return null;
    }

    fn ensureFunctionScopeVar(self: *ParseState, name: Atom) Error!u16 {
        if (self.scopeHasVar(0, name)) {
            if (self.findFunctionScopeVar(name)) |idx| return idx;
        }
        const saved_scope = self.scope_level;
        self.scope_level = 0;
        self.cur_func().scope_level = 0;
        defer {
            self.scope_level = saved_scope;
            self.cur_func().scope_level = saved_scope;
        }
        return @intCast(try self.addScopeVar(name, .normal, false, false));
    }

    fn findFunctionScopeVar(self: *ParseState, name: Atom) ?u16 {
        const vars = self.cur_func().vars;
        var i: usize = 0;
        while (i < vars.len) : (i += 1) {
            if (vars[i].var_name == name and vars[i].scope_level == 0) return @intCast(i);
        }
        return null;
    }

    fn addGlobalVar(self: *ParseState, name: Atom, is_lexical: bool, is_const: bool) Error!void {
        return self.cur_func().appendGlobalVar(.{
            .cpool_idx = -1,
            .force_init = false,
            .is_configurable = self.eval_global_var_bindings and !is_lexical,
            .is_lexical = is_lexical,
            .is_const = is_const,
            .scope_level = self.scope_level,
            .var_name = name,
        }) catch return error.OutOfMemory;
    }

    fn addGlobalAnnexBFunctionVar(self: *ParseState, name: Atom, is_configurable: bool) Error!void {
        return self.cur_func().appendGlobalVar(.{
            .cpool_idx = -1,
            .force_init = true,
            .is_configurable = is_configurable,
            .is_lexical = false,
            .is_const = false,
            .scope_level = 0,
            .var_name = name,
        }) catch return error.OutOfMemory;
    }

    fn currentBlockDecls(self: *ParseState) ?*BlockScopeDecls {
        if (self.block_scope_decls.items.len == 0) return null;
        const idx = self.block_scope_decls.items.len - 1;
        const decls = &self.block_scope_decls.items[idx];
        if (decls.scope_level != self.scope_level or decls.function_depth != self.cur_func_stack.len) return null;
        return decls;
    }

    fn appendUniqueAtom(self: *ParseState, list: *std.ArrayList(Atom), name: Atom) Error!void {
        for (list.items) |existing| {
            if (existing == name) return;
        }
        try list.append(self.function.memory.allocator, name);
    }

    fn registerBlockLexicalDeclaration(self: *ParseState, name: Atom) Error!void {
        const decls = self.currentBlockDecls() orelse return;
        for (decls.var_names.items) |var_name| {
            if (var_name == name) return Error.UnexpectedToken;
        }
        try self.appendUniqueAtom(&decls.lexical_names, name);
    }

    fn registerBlockVarDeclaration(self: *ParseState, name: Atom) Error!void {
        const function_depth = self.cur_func_stack.len;
        for (self.block_scope_decls.items) |*decls| {
            if (decls.function_depth != function_depth) continue;
            for (decls.lexical_names.items) |lexical_name| {
                if (lexical_name == name) return Error.UnexpectedToken;
            }
        }
        for (self.block_scope_decls.items) |*decls| {
            if (decls.function_depth != function_depth) continue;
            try self.appendUniqueAtom(&decls.var_names, name);
        }
    }

    /// Atom id reserved for the eval-return slot, mirroring
    /// `JS_ATOM__ret_` / `<ret>` (`quickjs-atom.h:115`). Used as the
    /// var name for the synthetic local that captures every
    /// expression-statement result in eval mode.
    pub const eval_ret_atom: Atom = 82;

    /// Switch the parser into eval mode and allocate the synthetic
    /// `<ret>` local that holds the result of the last evaluated
    /// expression. Mirrors `set_eval_ret_undefined` setup +
    /// `add_var(JS_ATOM__ret_)` (`quickjs.c:28219`/`28834`). The
    /// caller invokes this immediately after `ParseState.init` and
    /// before parsing any statements.
    ///
    /// Effect:
    /// 1. `is_eval` is set so `parseExprStatement` emits
    ///    `scope_put_var <ret>` (lowered to `put_loc <idx>`)
    ///    instead of `drop`.
    /// 2. The `<ret>` slot is registered in `function_def.vars`
    ///    (non-lexical so it bypasses TDZ).
    /// 3. The slot is initialised to `undefined` so an empty script
    ///    (no expressions) still returns a sensible value.
    pub fn enableEvalReturn(self: *ParseState) Error!void {
        self.is_eval = true;
        self.cur_func().is_eval = true;
        self.eval_delete_bindings = true;
        try self.enableReturnCompletion();
    }

    /// Enable expression-statement completion capture without changing script
    /// declaration semantics. This supports global script execution that returns
    /// the script completion without switching to eval code semantics.
    pub fn enableReturnCompletion(self: *ParseState) Error!void {
        const idx = try self.addScopeVar(eval_ret_atom, .normal, false, false);
        self.eval_ret_idx = idx;
        self.cur_func().eval_ret_idx = idx;
        // Emit the initialiser:  undefined ; scope_put_var <ret>.
        try self.emitOp(opcode.op.undefined);
        try self.emitScopePutVar(eval_ret_atom);
    }

    /// Mirror the tail of `js_parse_program` (`quickjs.c:31459`):
    /// after the last statement is parsed, emit
    /// `scope_get_var <ret>` so the eval result sits on the stack
    /// for `vm.run` to return. No-op when not in eval mode.
    pub fn finalizeEvalReturn(self: *ParseState) Error!void {
        if (self.eval_ret_idx < 0) return;
        try self.emitScopeGetVar(eval_ret_atom);
    }

    /// Mirror QuickJS `set_eval_ret_undefined` (`quickjs.c:28219-28226`):
    /// control-flow statements reset eval completion before parsing their
    /// children, and executed expression statements overwrite it.
    pub fn setEvalReturnUndefined(self: *ParseState) Error!void {
        if (self.eval_ret_idx < 0) return;
        try self.emitOp(opcode.op.undefined);
        try self.emitScopePutVar(eval_ret_atom);
    }

    pub fn emitReturnUndefined(self: *ParseState) Error!void {
        try self.emitOp(opcode.op.return_undef);
    }

    /// Advance one token. Frees the payload of the consumed token.
    fn advance(self: *ParseState) Error!void {
        self.last_token_end_offset = self.currentTokenEndOffset();
        self.last_token_line_num = self.token.line_num;
        self.last_token_col_num = self.token.col_num;
        self.lex.freeToken(&self.token);
        self.token = try self.lex.next();
    }

    pub fn peekKind(self: ParseState) tok.TokenKind {
        return self.token.val;
    }

    fn currentTokenStartOffset(self: *const ParseState) usize {
        const source_ptr = @intFromPtr(self.lex.source.ptr);
        const token_ptr = @intFromPtr(self.token.ptr);
        if (token_ptr <= source_ptr) return 0;
        return @min(token_ptr - source_ptr, self.lex.source.len);
    }

    fn currentTokenEndOffset(self: *const ParseState) usize {
        return @min(self.currentTokenStartOffset() + self.token.len, self.lex.source.len);
    }

    fn captureFunctionSource(self: *ParseState, fd: *function_def_mod.FunctionDef, source_start: usize) Error!void {
        try self.setFunctionSourceRange(fd, source_start, self.last_token_end_offset);
    }

    fn setFunctionSourceRange(
        self: *ParseState,
        fd: *function_def_mod.FunctionDef,
        source_start: usize,
        source_end: usize,
    ) Error!void {
        if (source_end <= source_start or source_start > self.lex.source.len or source_end > self.lex.source.len) return;
        const owned = try self.function.memory.alloc(u8, source_end - source_start);
        @memcpy(owned, self.lex.source[source_start..source_end]);
        const old = fd.source_text;
        fd.source_text = owned;
        if (old) |existing| self.function.memory.free(u8, @constCast(existing));
    }

    fn setChildFunctionSourceByCpoolIndex(
        self: *ParseState,
        cpool_idx: u16,
        source_start: usize,
        source_end: usize,
    ) Error!void {
        for (self.cur_func().child_list) |*child| {
            if (child.parent_cpool_idx != cpool_idx) continue;
            try self.setFunctionSourceRange(child, source_start, source_end);
            return;
        }
    }

    fn isPunct(self: ParseState, ch: u8) bool {
        return self.token.val == @as(tok.TokenKind, @intCast(ch));
    }

    /// Check if we got a line terminator before the current token (for ASI).
    fn gotLineTerminator(self: ParseState) bool {
        return self.lex.gotLineTerminator();
    }

    // ---- label management ----
    // This parser still lowers jumps directly, but labelled control flow
    // mirrors QuickJS `push_break_entry` / `emit_break` enough to route
    // labels without exposing regular labelled statements to unlabelled
    // `break`.

    fn hasActiveLabel(s: *ParseState, atom_id: Atom) bool {
        for (s.label_frames.items) |frame| {
            if (frame.atom == atom_id) return true;
        }
        return false;
    }

    fn pushLabelFrame(s: *ParseState, atom_id: Atom, allow_continue: bool) Error!usize {
        try s.label_frames.append(s.function.memory.allocator, LabelFrame{
            .atom = atom_id,
            .allow_continue = allow_continue,
            .catch_marker_depth = s.active_catch_marker_depth,
            .control_frame_depth = s.continue_frame_lens.items.len,
        });
        return s.label_frames.items.len - 1;
    }

    fn patchLabelBreaks(s: *ParseState, frame_index: usize) Error!void {
        for (s.label_frames.items[frame_index].break_fixups.items) |off| {
            try patchForwardJump(s, off);
        }
    }

    fn patchLabelContinues(s: *ParseState, frame_index: usize) Error!void {
        for (s.label_frames.items[frame_index].continue_fixups.items) |off| {
            try patchForwardJump(s, off);
        }
    }

    fn popLabelFrame(s: *ParseState, frame_index: usize) void {
        std.debug.assert(frame_index + 1 == s.label_frames.items.len);
        s.label_frames.items[frame_index].deinit(s.function.memory.allocator);
        _ = s.label_frames.pop().?;
    }

    fn findLabelFrame(s: *ParseState, atom_id: Atom) ?usize {
        var i = s.label_frames.items.len;
        while (i != 0) {
            i -= 1;
            if (s.label_frames.items[i].atom == atom_id) return i;
        }
        return null;
    }

    fn emitLabelledBreak(s: *ParseState, atom_id: Atom) Error!void {
        if (try emitCapturedControlThroughFinally(s, .{ .kind = .@"break", .label_atom = atom_id })) return;
        try s.emitLabelledBreakNoFinallyCapture(atom_id);
    }

    fn emitLabelledBreakNoFinallyCapture(s: *ParseState, atom_id: Atom) Error!void {
        const frame_index = findLabelFrame(s, atom_id) orelse return Error.UnexpectedToken;
        try emitPendingAbruptDropsForLabel(s, frame_index);
        try emitCatchMarkerDropsToDepth(s, s.label_frames.items[frame_index].catch_marker_depth);
        var frame_depth = s.break_frame_cleanup_drops.items.len;
        while (frame_depth > s.label_frames.items[frame_index].control_frame_depth) {
            frame_depth -= 1;
            try emitCrossFrameCleanup(s, s.break_frame_cross_cleanup_drops.items[frame_depth]);
        }
        if (s.label_frames.items[frame_index].allow_continue and s.label_frames.items[frame_index].control_frame_depth > 0) {
            try emitUnlabelledBreakCleanup(s, s.break_frame_cleanup_drops.items[s.label_frames.items[frame_index].control_frame_depth - 1]);
        }
        const off = try emitForwardJumpNoSource(s, opcode.op.goto);
        try s.label_frames.items[frame_index].break_fixups.append(s.function.memory.allocator, off);
    }

    fn emitLabelledContinue(s: *ParseState, atom_id: Atom) Error!void {
        if (try emitCapturedControlThroughFinally(s, .{ .kind = .@"continue", .label_atom = atom_id })) return;
        try s.emitLabelledContinueNoFinallyCapture(atom_id);
    }

    fn emitLabelledContinueNoFinallyCapture(s: *ParseState, atom_id: Atom) Error!void {
        const frame_index = findLabelFrame(s, atom_id) orelse return Error.UnexpectedToken;
        if (!s.label_frames.items[frame_index].allow_continue) return Error.UnexpectedToken;
        try emitPendingAbruptDropsForLabel(s, frame_index);
        try emitCatchMarkerDropsToDepth(s, s.label_frames.items[frame_index].catch_marker_depth);
        var frame_depth = s.continue_frame_lens.items.len;
        while (frame_depth > s.label_frames.items[frame_index].control_frame_depth) {
            frame_depth -= 1;
            try emitCrossFrameCleanup(s, s.break_frame_cross_cleanup_drops.items[frame_depth]);
        }
        if (s.label_frames.items[frame_index].control_frame_depth > 0) {
            try emitCrossFrameCleanup(s, s.continue_frame_cleanup_drops.items[s.label_frames.items[frame_index].control_frame_depth - 1]);
        }
        const off = try emitForwardJumpNoSource(s, opcode.op.goto);
        try s.label_frames.items[frame_index].continue_fixups.append(s.function.memory.allocator, off);
    }

    fn labelStartAtom(s: *ParseState) ?Atom {
        if (!isIdentifierLikeToken(s)) return null;
        if (s.peekNextKind() != @as(tok.TokenKind, @intCast(':'))) return null;
        const kind = s.peekKind();
        const atom_id = identifierLikeAtom(s);
        if (kind == tok.TOK_IDENT and escapedIdentifierIsReservedWordForCurrentContext(s, atom_id, s.token.payload.ident.has_escape)) return null;
        return atom_id;
    }

    fn isReservedLabelIdentifier(s: *ParseState, atom_id: Atom) bool {
        return (s.lex.is_module and atomNameEquals(s, atom_id, "await")) or
            (s.in_async and atomNameEquals(s, atom_id, "await")) or
            (s.in_class_static_block and atomNameEquals(s, atom_id, "await")) or
            (s.in_generator and atomNameEquals(s, atom_id, "yield")) or
            ((s.is_strict or s.cur_func().is_strict_mode) and atomNameEquals(s, atom_id, "yield"));
    }

    fn deinitCurrentControlFrames(s: *ParseState) void {
        const allocator = s.function.memory.allocator;
        s.break_fixups.deinit(allocator);
        s.break_frame_lens.deinit(allocator);
        s.break_frame_catch_marker_depths.deinit(allocator);
        s.break_frame_cleanup_drops.deinit(allocator);
        s.break_frame_cross_cleanup_drops.deinit(allocator);
        s.continue_fixups.deinit(allocator);
        s.continue_frame_lens.deinit(allocator);
        s.continue_frame_catch_marker_depths.deinit(allocator);
        s.continue_frame_cleanup_drops.deinit(allocator);
        for (s.label_frames.items) |*frame| {
            frame.deinit(allocator);
        }
        s.label_frames.deinit(allocator);
        s.using_block_frames.deinit(allocator);
    }

    fn enterControlBoundary(s: *ParseState) ControlFrames {
        const saved = ControlFrames{
            .break_fixups = s.break_fixups,
            .break_frame_lens = s.break_frame_lens,
            .break_frame_catch_marker_depths = s.break_frame_catch_marker_depths,
            .break_frame_cleanup_drops = s.break_frame_cleanup_drops,
            .break_frame_cross_cleanup_drops = s.break_frame_cross_cleanup_drops,
            .continue_fixups = s.continue_fixups,
            .continue_frame_lens = s.continue_frame_lens,
            .continue_frame_catch_marker_depths = s.continue_frame_catch_marker_depths,
            .continue_frame_cleanup_drops = s.continue_frame_cleanup_drops,
            .label_frames = s.label_frames,
            .pending_label_atom = s.pending_label_atom,
            .active_catch_marker_depth = s.active_catch_marker_depth,
            .droppable_rethrow_marker_count = s.droppable_rethrow_marker_count,
            .using_block_frames = s.using_block_frames,
        };
        s.break_fixups = .empty;
        s.break_frame_lens = .empty;
        s.break_frame_catch_marker_depths = .empty;
        s.break_frame_cleanup_drops = .empty;
        s.break_frame_cross_cleanup_drops = .empty;
        s.continue_fixups = .empty;
        s.continue_frame_lens = .empty;
        s.continue_frame_catch_marker_depths = .empty;
        s.continue_frame_cleanup_drops = .empty;
        s.label_frames = .empty;
        s.pending_label_atom = null;
        s.active_catch_marker_depth = 0;
        s.droppable_rethrow_marker_count = 0;
        s.using_block_frames = .empty;
        return saved;
    }

    fn leaveControlBoundary(s: *ParseState, saved: ControlFrames) void {
        s.deinitCurrentControlFrames();
        s.break_fixups = saved.break_fixups;
        s.break_frame_lens = saved.break_frame_lens;
        s.break_frame_catch_marker_depths = saved.break_frame_catch_marker_depths;
        s.break_frame_cleanup_drops = saved.break_frame_cleanup_drops;
        s.break_frame_cross_cleanup_drops = saved.break_frame_cross_cleanup_drops;
        s.continue_fixups = saved.continue_fixups;
        s.continue_frame_lens = saved.continue_frame_lens;
        s.continue_frame_catch_marker_depths = saved.continue_frame_catch_marker_depths;
        s.continue_frame_cleanup_drops = saved.continue_frame_cleanup_drops;
        s.label_frames = saved.label_frames;
        s.pending_label_atom = saved.pending_label_atom;
        s.active_catch_marker_depth = saved.active_catch_marker_depth;
        s.droppable_rethrow_marker_count = saved.droppable_rethrow_marker_count;
        s.using_block_frames = saved.using_block_frames;
    }

    fn truncateClassPrivateElements(self: *ParseState, len: usize) void {
        var i = len;
        while (i < self.class_private_elements.items.len) : (i += 1) {
            self.function.atoms.free(self.class_private_elements.items[i].atom);
        }
        self.class_private_elements.shrinkRetainingCapacity(len);
    }

    fn truncateClassPrivateBoundNames(self: *ParseState, len: usize) void {
        var i = len;
        while (i < self.class_private_bound_names.items.len) : (i += 1) {
            self.function.atoms.free(self.class_private_bound_names.items[i]);
        }
        self.class_private_bound_names.shrinkRetainingCapacity(len);
    }

    fn truncateClassPublicInstanceFields(self: *ParseState, len: usize) void {
        var i = len;
        while (i < self.class_public_instance_fields.items.len) : (i += 1) {
            self.function.atoms.free(self.class_public_instance_fields.items[i]);
        }
        self.class_public_instance_fields.shrinkRetainingCapacity(len);
    }

    fn truncateClassStaticDeferred(self: *ParseState, code_len: usize, atom_len: usize) void {
        var i = atom_len;
        while (i < self.class_static_deferred_atoms.items.len) : (i += 1) {
            self.function.atoms.free(self.class_static_deferred_atoms.items[i]);
        }
        self.class_static_deferred_atoms.shrinkRetainingCapacity(atom_len);
        self.class_static_deferred_code.shrinkRetainingCapacity(code_len);
    }

    /// Expect a semicolon, applying ASI rules. Returns true if a semicolon
    /// was present or inserted via ASI.
    fn expectSemicolon(s: *ParseState) Error!bool {
        if (s.isPunct(';')) {
            try s.advance();
            return true;
        }
        // ASI: if we have a line terminator or are at EOF or closing brace,
        // insert a semicolon automatically.
        if (s.gotLineTerminator() or s.peekKind() == tok.TOK_EOF or s.isPunct('}')) {
            return true;
        }
        return Error.UnexpectedToken;
    }

    /// Expect a specific token kind.
    fn expectToken(s: *ParseState, kind: tok.TokenKind) Error!void {
        if (s.peekKind() != kind) return Error.UnexpectedToken;
        try s.advance();
    }

    /// Peek at the next token kind without consuming the current token.
    /// Saves and restores lexer position so the cached token stays valid.
    fn peekNextKind(s: *ParseState) tok.TokenKind {
        const saved_pos = s.lex.pos;
        const saved_line = s.lex.line;
        const saved_col = s.lex.col;
        const saved_got_lf = s.lex.got_lf;
        const saved_mark_pos = s.lex.mark_pos;
        const saved_mark_line = s.lex.mark_line;
        const saved_mark_col = s.lex.mark_col;
        defer {
            s.lex.pos = saved_pos;
            s.lex.line = saved_line;
            s.lex.col = saved_col;
            s.lex.got_lf = saved_got_lf;
            s.lex.mark_pos = saved_mark_pos;
            s.lex.mark_line = saved_mark_line;
            s.lex.mark_col = saved_mark_col;
        }
        var peek_token = s.lex.next() catch return tok.TOK_EOF;
        defer s.lex.freeToken(&peek_token);
        return peek_token.val;
    }

    fn peekNextKindNoLineTerminator(s: *ParseState, expected: tok.TokenKind) bool {
        const saved_pos = s.lex.pos;
        const saved_line = s.lex.line;
        const saved_col = s.lex.col;
        const saved_got_lf = s.lex.got_lf;
        const saved_mark_pos = s.lex.mark_pos;
        const saved_mark_line = s.lex.mark_line;
        const saved_mark_col = s.lex.mark_col;
        defer {
            s.lex.pos = saved_pos;
            s.lex.line = saved_line;
            s.lex.col = saved_col;
            s.lex.got_lf = saved_got_lf;
            s.lex.mark_pos = saved_mark_pos;
            s.lex.mark_line = saved_mark_line;
            s.lex.mark_col = saved_mark_col;
        }
        var peek_token = s.lex.next() catch return false;
        defer s.lex.freeToken(&peek_token);
        const matched = peek_token.val == expected and !s.lex.gotLineTerminator();
        return matched;
    }

    fn peekNextKindWithLineTerminator(s: *ParseState, line_terminator: *bool) tok.TokenKind {
        const saved_pos = s.lex.pos;
        const saved_line = s.lex.line;
        const saved_col = s.lex.col;
        const saved_got_lf = s.lex.got_lf;
        const saved_mark_pos = s.lex.mark_pos;
        const saved_mark_line = s.lex.mark_line;
        const saved_mark_col = s.lex.mark_col;
        defer {
            s.lex.pos = saved_pos;
            s.lex.line = saved_line;
            s.lex.col = saved_col;
            s.lex.got_lf = saved_got_lf;
            s.lex.mark_pos = saved_mark_pos;
            s.lex.mark_line = saved_mark_line;
            s.lex.mark_col = saved_mark_col;
        }
        var peek_token = s.lex.next() catch return tok.TOK_EOF;
        defer s.lex.freeToken(&peek_token);
        line_terminator.* = s.lex.gotLineTerminator();
        return peek_token.val;
    }

    /// Check if the for loop head is for-in or for-of by looking ahead
    /// for `for (var x in expr)` or `for (var x of expr)`
    fn checkForInOfHead(s: *ParseState) bool {
        const saved_pos = s.lex.pos;
        const saved_line = s.lex.line;
        const saved_col = s.lex.col;
        const saved_mark_pos = s.lex.mark_pos;
        const saved_mark_line = s.lex.mark_line;
        const saved_mark_col = s.lex.mark_col;
        const saved_token = s.token;
        var advanced = false;
        defer {
            if (advanced) s.lex.freeToken(&s.token);
            s.lex.pos = saved_pos;
            s.lex.line = saved_line;
            s.lex.col = saved_col;
            s.lex.mark_pos = saved_mark_pos;
            s.lex.mark_line = saved_mark_line;
            s.lex.mark_col = saved_mark_col;
            s.token = saved_token;
        }

        const advanceLocal = struct {
            fn call(state: *ParseState, did_advance: *bool) bool {
                const next = state.lex.next() catch return false;
                state.lex.freeToken(&state.token);
                state.token = next;
                did_advance.* = true;
                return true;
            }
        }.call;

        var saw_decl = false;
        // Skip var/let/const/using if present.
        if (directUsingDeclarationKind(s)) |using_kind| {
            if (using_kind == .sync and usingDeclarationBindingIsOf(s, using_kind)) {
                if (usingDeclarationBindingFollowedByEquals(s, using_kind)) return false;
            } else {
                saw_decl = true;
                if (!advanceLocal(s, &advanced)) return false;
                if (using_kind == .async and !advanceLocal(s, &advanced)) return false;
            }
        } else if (s.peekKind() == tok.TOK_VAR or s.peekKind() == tok.TOK_LET or s.peekKind() == tok.TOK_CONST) {
            saw_decl = true;
            if (!advanceLocal(s, &advanced)) return false;
        }

        // Skip identifier
        if (isIdentifierLikeToken(s)) {
            if (!advanceLocal(s, &advanced)) return false;
            if (!saw_decl and s.peekKind() == @as(tok.TokenKind, @intCast('('))) {
                var depth: usize = 0;
                while (true) {
                    const kind = s.peekKind();
                    if (kind == tok.TOK_EOF) return false;
                    if (kind == @as(tok.TokenKind, @intCast('('))) depth += 1;
                    if (kind == @as(tok.TokenKind, @intCast(')'))) {
                        if (depth == 0) return false;
                        depth -= 1;
                        if (!advanceLocal(s, &advanced)) return false;
                        if (depth == 0) break;
                        continue;
                    }
                    if (!advanceLocal(s, &advanced)) return false;
                }
            }
            if (s.peekKind() == @as(tok.TokenKind, @intCast('.'))) {
                if (!advanceLocal(s, &advanced)) return false;
                if (s.peekKind() != tok.TOK_IDENT) return false;
                if (!advanceLocal(s, &advanced)) return false;
            }
        } else if (s.peekKind() == tok.TOK_THIS) {
            if (!advanceLocal(s, &advanced)) return false;
            if (s.peekKind() != @as(tok.TokenKind, @intCast('.'))) return false;
            if (!advanceLocal(s, &advanced)) return false;
            if (s.peekKind() != tok.TOK_PRIVATE_NAME) return false;
            if (!advanceLocal(s, &advanced)) return false;
        } else if (s.peekKind() == tok.TOK_ASYNC) {
            if (!advanceLocal(s, &advanced)) return false;
        } else if (s.peekKind() == @as(tok.TokenKind, @intCast('('))) {
            var depth: usize = 0;
            while (true) {
                const kind = s.peekKind();
                if (kind == tok.TOK_EOF) return false;
                if (kind == @as(tok.TokenKind, @intCast('('))) depth += 1;
                if (kind == @as(tok.TokenKind, @intCast(')'))) {
                    if (depth == 0) return false;
                    depth -= 1;
                    if (!advanceLocal(s, &advanced)) return false;
                    if (depth == 0) break;
                    continue;
                }
                if (!advanceLocal(s, &advanced)) return false;
            }
        } else if ((s.peekKind() == @as(tok.TokenKind, @intCast('[')) or s.peekKind() == @as(tok.TokenKind, @intCast('{'))) and saw_decl) {
            var depth: usize = 0;
            while (true) {
                const kind = s.peekKind();
                if (kind == tok.TOK_EOF) return false;
                if (kind == @as(tok.TokenKind, @intCast('[')) or kind == @as(tok.TokenKind, @intCast('{'))) depth += 1;
                if (kind == @as(tok.TokenKind, @intCast(']')) or kind == @as(tok.TokenKind, @intCast('}'))) {
                    if (depth == 0) return false;
                    depth -= 1;
                    if (!advanceLocal(s, &advanced)) return false;
                    if (depth == 0) break;
                    continue;
                }
                if (!advanceLocal(s, &advanced)) return false;
            }
        } else if (s.peekKind() == @as(tok.TokenKind, @intCast('[')) or s.peekKind() == @as(tok.TokenKind, @intCast('{'))) {
            var depth: usize = 0;
            const started_array = s.peekKind() == @as(tok.TokenKind, @intCast('['));
            while (true) {
                const kind = s.peekKind();
                if (kind == tok.TOK_EOF) return false;
                if (kind == @as(tok.TokenKind, @intCast('[')) or kind == @as(tok.TokenKind, @intCast('{'))) depth += 1;
                if (kind == @as(tok.TokenKind, @intCast(']')) or kind == @as(tok.TokenKind, @intCast('}'))) {
                    if (depth == 0) return false;
                    depth -= 1;
                    if (!advanceLocal(s, &advanced)) return false;
                    if (depth == 0) break;
                    continue;
                }
                if (!advanceLocal(s, &advanced)) return false;
            }
            if (started_array and s.peekKind() == @as(tok.TokenKind, @intCast('['))) {
                if (!advanceLocal(s, &advanced)) return false;
                if (s.peekKind() != tok.TOK_NUMBER) return false;
                if (!advanceLocal(s, &advanced)) return false;
                if (s.peekKind() != @as(tok.TokenKind, @intCast(']'))) return false;
                if (!advanceLocal(s, &advanced)) return false;
            }
        }
        if (saw_decl and s.peekKind() == '=') {
            if (!advanceLocal(s, &advanced)) return false;
            var depth: usize = 0;
            while (true) {
                const kind = s.peekKind();
                if (kind == tok.TOK_EOF) return false;
                if (depth == 0 and (kind == tok.TOK_IN or s.isOfToken())) break;
                if (depth == 0 and (kind == ';' or kind == @as(tok.TokenKind, @intCast(')')))) return false;
                if (kind == @as(tok.TokenKind, @intCast('(')) or kind == @as(tok.TokenKind, @intCast('[')) or kind == @as(tok.TokenKind, @intCast('{'))) {
                    depth += 1;
                } else if (kind == @as(tok.TokenKind, @intCast(')')) or kind == @as(tok.TokenKind, @intCast(']')) or kind == @as(tok.TokenKind, @intCast('}'))) {
                    if (depth == 0) return false;
                    depth -= 1;
                }
                if (!advanceLocal(s, &advanced)) return false;
            }
        }

        // Check if next token is 'in' or 'of'
        const next_kind = s.peekKind();
        if (next_kind == tok.TOK_IN) return true;
        if (s.isOfToken()) {
            if (s.peekNextKind() == tok.TOK_ARROW) return false;
            return true;
        }
        return false;
    }

    /// Check if the current token is an identifier with the given name
    fn isIdent(s: *ParseState, name: []const u8) bool {
        if (s.peekKind() != tok.TOK_IDENT) return false;
        if (s.token.payload.ident.has_escape) return false;
        const ident_str = s.lex.atoms.name(s.token.payload.ident.atom) orelse return false;
        return std.mem.eql(u8, ident_str, name);
    }

    fn isParameterModifier(s: *ParseState) bool {
        const k = s.peekKind();
        if (k == tok.TOK_PUBLIC or k == tok.TOK_PRIVATE or k == tok.TOK_PROTECTED) return true;
        if (k == tok.TOK_IDENT) {
            if (s.token.payload.ident.has_escape) return false;
            const ident_str = s.lex.atoms.name(s.token.payload.ident.atom) orelse return false;
            return std.mem.eql(u8, ident_str, "public") or
                std.mem.eql(u8, ident_str, "private") or
                std.mem.eql(u8, ident_str, "protected") or
                std.mem.eql(u8, ident_str, "readonly");
        }
        return false;
    }

    fn isOfToken(s: *ParseState) bool {
        return s.peekKind() == tok.TOK_OF or s.isIdent("of");
    }

    fn canTreatLetAsForInitializerExpression(s: *ParseState) bool {
        if (s.peekKind() != tok.TOK_LET) return false;
        if (s.is_strict or s.cur_func().is_strict_mode) return false;
        const next_kind = s.peekNextKind();
        if (next_kind == tok.TOK_YIELD) return false;
        if (next_kind == tok.TOK_AWAIT and canUseAwaitAsIdentifier(s)) return false;
        if (next_kind == tok.TOK_STATIC) return false;
        if (isSloppyFutureReservedToken(next_kind)) return false;
        return next_kind != tok.TOK_IDENT and
            next_kind != @as(tok.TokenKind, @intCast('[')) and
            next_kind != @as(tok.TokenKind, @intCast('{'));
    }

    // ---- emit primitives -------------------------------------------------
    //
    // Direct byte writes into `function.code`. Keep these local until the
    // remaining legacy emitter callers are retired.

    fn emitOp(self: *ParseState, op_id: u8) Error!void {
        try self.appendBytes(&[_]u8{op_id});
    }

    fn emitOpNoSource(self: *ParseState, op_id: u8) Error!void {
        try self.appendBytesNoSource(&[_]u8{op_id});
    }

    fn emitOpU8(self: *ParseState, op_id: u8, val: u8) Error!void {
        try self.appendBytes(&[_]u8{ op_id, val });
    }

    fn emitOpU16(self: *ParseState, op_id: u8, val: u16) Error!void {
        var bytes: [3]u8 = undefined;
        bytes[0] = op_id;
        std.mem.writeInt(u16, bytes[1..3], val, .little);
        try self.appendBytes(&bytes);
    }

    fn emitOpU16NoSource(self: *ParseState, op_id: u8, val: u16) Error!void {
        var bytes: [3]u8 = undefined;
        bytes[0] = op_id;
        std.mem.writeInt(u16, bytes[1..3], val, .little);
        try self.appendBytesNoSource(&bytes);
    }

    fn emitOpU16At(self: *ParseState, op_id: u8, val: u16, line_num: u32, col_num: u32) Error!void {
        var bytes: [3]u8 = undefined;
        bytes[0] = op_id;
        std.mem.writeInt(u16, bytes[1..3], val, .little);
        try self.appendBytesAt(&bytes, line_num, col_num);
    }

    fn emitOpI32(self: *ParseState, op_id: u8, val: i32) Error!void {
        var bytes: [5]u8 = undefined;
        bytes[0] = op_id;
        std.mem.writeInt(i32, bytes[1..5], val, .little);
        try self.appendBytes(&bytes);
    }

    fn emitOpU32(self: *ParseState, op_id: u8, val: u32) Error!void {
        var bytes: [5]u8 = undefined;
        bytes[0] = op_id;
        std.mem.writeInt(u32, bytes[1..5], val, .little);
        try self.appendBytes(&bytes);
    }

    fn emitOpU32At(self: *ParseState, op_id: u8, val: u32, line_num: u32, col_num: u32) Error!void {
        var bytes: [5]u8 = undefined;
        bytes[0] = op_id;
        std.mem.writeInt(u32, bytes[1..5], val, .little);
        try self.appendBytesAt(&bytes, line_num, col_num);
    }

    fn emitFClosure8(self: *ParseState, idx: u8) Error!void {
        // Phase-1 temporary opcodes overlap the short-opcode range that
        // contains fclosure8. Keep parser output in the wide form until
        // resolve_labels shortens it after temp opcodes have been erased.
        if (self.emit_phase1_temp) {
            try self.emitOpU32(opcode.op.fclosure, idx);
            return;
        }
        try self.emitOpU8(opcode.op.fclosure8, idx);
    }

    fn emitFClosure(self: *ParseState, idx: u16) Error!void {
        if (idx < 256) {
            try self.emitFClosure8(@intCast(idx));
        } else {
            try self.emitOpU32(opcode.op.fclosure, idx);
        }
    }

    fn emitSetVarRef(self: *ParseState, idx: u16) Error!void {
        if (idx < 4) {
            try self.emitOp(opcode.op.set_var_ref0 + @as(u8, @intCast(idx)));
        } else {
            try self.emitOpU16(opcode.op.set_var_ref, idx);
        }
    }

    fn emitPutVarRef(self: *ParseState, idx: u16) Error!void {
        if (idx < 4) {
            try self.emitOp(opcode.op.put_var_ref0 + @as(u8, @intCast(idx)));
        } else {
            try self.emitOpU16(opcode.op.put_var_ref, idx);
        }
    }

    fn emitCloseLoc(self: *ParseState, idx: u16) Error!void {
        try self.emitOpU16NoSource(opcode.op.close_loc, idx);
    }

    /// Mirror the `OP_enter_scope` emission of QuickJS `push_scope`
    /// (`quickjs.c:23486`). `resolve_variables` lowers this temp opcode
    /// to a per-scope binding refresh (TDZ re-arm + captured-slot
    /// detach, see `enterScopeRefreshSize`) so block-scoped bindings
    /// are fresh on every scope entry — the per-iteration semantics of
    /// lexicals declared inside loop bodies.
    ///
    /// Function/arrow body blocks set `suppress_block_enter_scope`:
    /// they are entered exactly once per frame (slots start fresh) and
    /// the hoisted statement-function inits injected ahead of the body
    /// may already have captured body-scope slots, which an entry-time
    /// detach would disconnect.
    fn emitEnterScope(self: *ParseState) Error!void {
        if (!self.emit_phase1_temp) return;
        if (self.scope_level < 0) return;
        try self.emitOpU16NoSource(opcode.op.enter_scope, @intCast(self.scope_level));
    }

    fn emitOpAtom(self: *ParseState, op_id: u8, atom_id: Atom) Error!void {
        if (self.emit_to_function_def) {
            try self.cur_func().appendAtomOperand(atom_id);
        } else {
            try self.function.retainAtomOperand(atom_id);
        }
        try self.emitOpU32(op_id, atom_id);
    }

    // ---- Temporary scope opcode helpers ----
    // These emit scope_* opcodes that will be lowered by resolve_variables.

    fn emitOpAtomU16(self: *ParseState, op_id: u8, atom_id: Atom, u16_val: u16) Error!void {
        if (self.emit_to_function_def) {
            try self.cur_func().appendAtomOperand(atom_id);
        } else {
            try self.function.retainAtomOperand(atom_id);
        }
        var bytes: [7]u8 = undefined;
        bytes[0] = op_id;
        std.mem.writeInt(u32, bytes[1..5], atom_id, .little);
        std.mem.writeInt(u16, bytes[5..7], u16_val, .little);
        try self.appendBytes(&bytes);
    }

    fn emitOpAtomU8(self: *ParseState, op_id: u8, atom_id: Atom, u8_val: u8) Error!void {
        if (self.emit_to_function_def) {
            try self.cur_func().appendAtomOperand(atom_id);
        } else {
            try self.function.retainAtomOperand(atom_id);
        }
        var bytes: [6]u8 = undefined;
        bytes[0] = op_id;
        std.mem.writeInt(u32, bytes[1..5], atom_id, .little);
        bytes[5] = u8_val;
        try self.appendBytes(&bytes);
    }

    fn emitOpAtomLabelU8(self: *ParseState, op_id: u8, atom_id: Atom, label: u32, u8_val: u8) Error!usize {
        if (self.emit_to_function_def) {
            try self.cur_func().appendAtomOperand(atom_id);
        } else {
            try self.function.retainAtomOperand(atom_id);
        }
        var bytes: [10]u8 = undefined;
        bytes[0] = op_id;
        std.mem.writeInt(u32, bytes[1..5], atom_id, .little);
        std.mem.writeInt(u32, bytes[5..9], label, .little);
        bytes[9] = u8_val;
        const label_offset = self.currentCodeLen() + 5;
        try self.appendBytes(&bytes);
        return label_offset;
    }

    fn emitScopeGetVar(self: *ParseState, atom_id: Atom) Error!void {
        try self.ensureClosureVar(atom_id);
        if (self.emit_phase1_temp) {
            try self.emitOpAtomU16(opcode.op.scope_get_var, atom_id, @intCast(self.scope_level));
        } else {
            try self.emitOpAtom(opcode.op.get_var, atom_id);
        }
    }

    fn emitScopePutVar(self: *ParseState, atom_id: Atom) Error!void {
        try self.ensureClosureVar(atom_id);
        if (self.emit_phase1_temp) {
            try self.emitOpAtomU16(opcode.op.scope_put_var, atom_id, @intCast(self.scope_level));
        } else {
            try self.emitOpAtom(opcode.op.put_var, atom_id);
        }
    }

    fn emitScopeMakeRef(self: *ParseState, atom_id: Atom) Error!void {
        try self.ensureClosureVar(atom_id);
        if (self.emit_phase1_temp) {
            if (self.emit_to_function_def) {
                try self.cur_func().appendAtomOperand(atom_id);
            } else {
                try self.function.retainAtomOperand(atom_id);
            }
            var bytes: [11]u8 = undefined;
            bytes[0] = opcode.op.scope_make_ref;
            std.mem.writeInt(u32, bytes[1..5], atom_id, .little);
            std.mem.writeInt(u32, bytes[5..9], 0, .little);
            std.mem.writeInt(u16, bytes[9..11], @intCast(self.scope_level), .little);
            try self.appendBytes(&bytes);
        } else {
            try self.emitOpAtom(opcode.op.make_var_ref, atom_id);
        }
    }

    fn emitScopeGetVarUndef(self: *ParseState, atom_id: Atom) Error!void {
        try self.ensureClosureVar(atom_id);
        if (self.emit_phase1_temp) {
            try self.emitOpAtomU16(opcode.op.scope_get_var_undef, atom_id, @intCast(self.scope_level));
        } else {
            try self.emitOpAtom(opcode.op.get_var_undef, atom_id);
        }
    }

    /// Emit `scope_put_var_init` for `let` / `const` initialisers.
    /// Mirrors `quickjs.c:282` (scope init form). The pipeline
    /// lowers this to `put_loc` when the var resolves locally, or
    /// to `put_var_init` when it's a top-level lexical global.
    fn emitScopePutVarInit(self: *ParseState, atom_id: Atom) Error!void {
        try self.ensureClosureVar(atom_id);
        if (self.emit_phase1_temp) {
            try self.emitOpAtomU16(opcode.op.scope_put_var_init, atom_id, @intCast(self.scope_level));
        } else {
            // Direct emission path (no pipeline): use the plain
            // `put_var_init` 5-byte form.
            try self.emitOpAtom(opcode.op.put_var_init, atom_id);
        }
    }

    fn emitScopePutVarRefCheckInit(self: *ParseState, atom_id: Atom) Error!void {
        try self.ensureClosureVar(atom_id);
        const ref_idx = findClosureVarIndex(self.cur_func(), atom_id) orelse return Error.UnexpectedToken;
        try self.emitOpU16(opcode.op.put_var_ref_check_init, ref_idx);
    }

    fn ensureThisLocal(self: *ParseState) Error!?u16 {
        if (!self.emit_to_function_def) return null;
        const fd = self.cur_func();
        if (!fd.has_this_binding) return null;
        if (fd.this_var_idx < 0) {
            fd.this_var_idx = @intCast(fd.addScopeVar(atom_this, .normal, 0, false, false) catch return error.OutOfMemory);
        }
        return @intCast(fd.this_var_idx);
    }

    fn emitThisValue(self: *ParseState) Error!void {
        if (try self.ensureThisLocal()) |_| {
            try self.emitScopeGetVar(atom_this);
        } else {
            try self.emitOp(opcode.op.push_this);
        }
    }

    fn ensureClosureVar(self: *ParseState, atom_id: Atom) Error!void {
        if (!self.emit_to_function_def) return;
        const current = self.cur_func();
        if (current.findVar(atom_id) >= 0 or current.findArg(atom_id) >= 0) return;
        for (current.closure_var) |cv| {
            if (cv.var_name == atom_id) return;
        }

        var parent_index = self.cur_func_stack.len;
        var visible_scope_level = current.parent_scope_level;
        while (parent_index > 0) {
            parent_index -= 1;
            const parent = self.funcAtVirtualIndex(parent_index);
            if (findVisibleParentVar(parent, atom_id, visible_scope_level)) |parent_var| {
                try self.ensureClosureChain(parent_index, .{
                    .closure_type = .local,
                    .is_lexical = parent.vars[@intCast(parent_var)].is_lexical,
                    .is_const = parent.vars[@intCast(parent_var)].is_const,
                    .var_kind = parent.vars[@intCast(parent_var)].var_kind,
                    .var_idx = @intCast(parent_var),
                    .var_name = atom_id,
                });
                return;
            }
            const parent_arg = parent.findArg(atom_id);
            if (parent_arg >= 0) {
                try self.ensureClosureChain(parent_index, .{
                    .closure_type = .arg,
                    .is_lexical = false,
                    .is_const = false,
                    .var_kind = .normal,
                    .var_idx = @intCast(parent_arg),
                    .var_name = atom_id,
                });
                return;
            }
            visible_scope_level = parent.parent_scope_level;
            for (parent.closure_var, 0..) |cv, idx| {
                if (cv.var_name == atom_id) {
                    try self.ensureClosureChain(parent_index, .{
                        .closure_type = .ref,
                        .is_lexical = cv.is_lexical,
                        .is_const = cv.is_const,
                        .var_kind = cv.var_kind,
                        .var_idx = @intCast(idx),
                        .var_name = atom_id,
                    });
                    return;
                }
            }
        }
    }

    fn emitCloseCurrentScopeLexicals(self: *ParseState) Error!void {
        if (self.scope_level < 0 or @as(usize, @intCast(self.scope_level)) >= self.cur_func().scopes.len) return;
        var idx = self.cur_func().scopes[@intCast(self.scope_level)].first;
        while (idx >= 0) {
            const var_idx: usize = @intCast(idx);
            const vd = self.cur_func().vars[var_idx];
            if (vd.is_lexical) try self.emitCloseLoc(@intCast(var_idx));
            idx = vd.scope_next;
        }
    }

    fn findVisibleParentVar(parent: *const function_def_mod.FunctionDef, atom_id: Atom, visible_scope_level: i32) ?i32 {
        var i: usize = parent.vars.len;
        while (i > 0) {
            i -= 1;
            const vd = parent.vars[i];
            if (vd.var_name != atom_id) continue;
            if (vd.var_kind == .function_name or scopeChainContains(parent, visible_scope_level, vd.scope_level)) return @intCast(i);
        }
        return null;
    }

    fn ensureClosureChain(self: *ParseState, source_index: usize, source: function_def_mod.ClosureVar) Error!void {
        if (source.closure_type == .local) {
            const source_fd = self.funcAtVirtualIndex(source_index);
            if (source.var_idx < source_fd.vars.len) {
                source_fd.vars[source.var_idx].is_captured = true;
            }
        }
        var parent_ref_idx: ?u16 = null;
        var child_index = source_index + 1;
        while (child_index <= self.cur_func_stack.len) : (child_index += 1) {
            const child = self.funcAtVirtualIndex(child_index);
            var existing: ?u16 = null;
            for (child.closure_var, 0..) |cv, idx| {
                if (cv.var_name == source.var_name) {
                    existing = @intCast(idx);
                    break;
                }
            }
            if (existing) |idx| {
                parent_ref_idx = idx;
                continue;
            }

            const cv = if (child_index == source_index + 1) source else function_def_mod.ClosureVar{
                .closure_type = .ref,
                .is_lexical = source.is_lexical,
                .is_const = source.is_const,
                .var_kind = source.var_kind,
                .var_idx = parent_ref_idx orelse return Error.UnexpectedToken,
                .var_name = source.var_name,
            };
            parent_ref_idx = @intCast(try child.addClosureVar(cv));
        }
    }

    fn findClosureVarIndex(fd: *const function_def_mod.FunctionDef, atom_id: Atom) ?u16 {
        for (fd.closure_var, 0..) |cv, idx| {
            if (cv.var_name == atom_id) return @intCast(idx);
        }
        return null;
    }

    fn functionDefUsesAtom(fd: *const function_def_mod.FunctionDef, atom_id: Atom) bool {
        for (fd.atom_operands) |operand| {
            if (operand == atom_id) return true;
        }
        return false;
    }

    /// Like `functionDefUsesAtom`, but also returns true when any (transitive)
    /// nested child function references `atom_id` without shadowing it. Used by
    /// the forward-capture retrofit so an intermediate function that merely
    /// *propagates* a binding to a deeper closure (and never names it directly)
    /// still receives a closure-var link. Mirrors QuickJS resolving the whole
    /// function tree after parsing, where such chains are built unconditionally.
    fn functionDefUsesAtomTransitive(fd: *const function_def_mod.FunctionDef, atom_id: Atom) bool {
        if (functionDefUsesAtom(fd, atom_id)) return true;
        for (fd.child_list) |*child| {
            if (child.findVar(atom_id) >= 0 or child.findArg(atom_id) >= 0) continue;
            if (functionDefUsesAtomTransitive(child, atom_id)) return true;
        }
        return false;
    }

    /// Recursively extend a forward-capture chain into the descendants of `fd`.
    /// `fd_ref_idx` is the index, within `fd.closure_var`, of the entry that
    /// already holds `atom_id`. Every descendant that transitively uses the atom
    /// (and does not shadow it) gets a `.ref` closure var pointing at its
    /// parent's entry, so the runtime can thread the cell down the whole chain.
    fn propagateForwardCaptureToDescendants(
        self: *ParseState,
        fd: *function_def_mod.FunctionDef,
        atom_id: Atom,
        fd_ref_idx: u16,
        is_lexical: bool,
        is_const: bool,
        var_kind: function_def_mod.VarKind,
    ) Error!void {
        for (fd.child_list) |*child| {
            if (child.findVar(atom_id) >= 0 or child.findArg(atom_id) >= 0) continue;
            if (!functionDefUsesAtomTransitive(child, atom_id)) continue;
            const child_ref_idx: u16 = if (findClosureVarIndex(child, atom_id)) |existing| blk: {
                child.closure_var[existing].closure_type = .ref;
                child.closure_var[existing].is_lexical = is_lexical;
                child.closure_var[existing].is_const = is_const;
                child.closure_var[existing].var_kind = var_kind;
                child.closure_var[existing].var_idx = fd_ref_idx;
                break :blk existing;
            } else @intCast(try child.addClosureVar(.{
                .closure_type = .ref,
                .is_lexical = is_lexical,
                .is_const = is_const,
                .var_kind = var_kind,
                .var_idx = fd_ref_idx,
                .var_name = atom_id,
            }));
            try self.propagateForwardCaptureToDescendants(child, atom_id, child_ref_idx, is_lexical, is_const, var_kind);
        }
    }

    fn scopeChainContains(fd: *const function_def_mod.FunctionDef, start_scope: i32, target_scope: i32) bool {
        var scope_idx = start_scope;
        while (scope_idx >= 0 and @as(usize, @intCast(scope_idx)) < fd.scopes.len) {
            if (scope_idx == target_scope) return true;
            scope_idx = fd.scopes[@intCast(scope_idx)].parent;
        }
        return false;
    }

    fn retrofitForwardTopLevelFunctionCapture(
        self: *ParseState,
        parent_fd: *function_def_mod.FunctionDef,
        atom_id: Atom,
        parent_ref_idx: u16,
    ) Error!void {
        try self.retrofitForwardTopLevelModuleCapture(parent_fd, atom_id, parent_ref_idx, true, false, .function_decl);
    }

    fn retrofitForwardTopLevelModuleCapture(
        self: *ParseState,
        parent_fd: *function_def_mod.FunctionDef,
        atom_id: Atom,
        parent_ref_idx: u16,
        is_lexical: bool,
        is_const: bool,
        var_kind: function_def_mod.VarKind,
    ) Error!void {
        for (parent_fd.child_list) |*child| {
            if (!functionDefUsesAtomTransitive(child, atom_id)) continue;
            if (child.findVar(atom_id) >= 0 or child.findArg(atom_id) >= 0) continue;
            const child_ref_idx: u16 = if (findClosureVarIndex(child, atom_id)) |existing|
                existing
            else
                @intCast(try child.addClosureVar(.{
                    .closure_type = .ref,
                    .is_lexical = is_lexical,
                    .is_const = is_const,
                    .var_kind = var_kind,
                    .var_idx = parent_ref_idx,
                    .var_name = atom_id,
                }));
            try self.propagateForwardCaptureToDescendants(child, atom_id, child_ref_idx, is_lexical, is_const, var_kind);
        }
    }

    fn retrofitForwardLocalFunctionCapture(
        self: *ParseState,
        parent_fd: *function_def_mod.FunctionDef,
        atom_id: Atom,
        local_idx: u16,
    ) Error!void {
        const local = parent_fd.vars[local_idx];
        for (parent_fd.child_list) |*child| {
            if (!functionDefUsesAtomTransitive(child, atom_id)) continue;
            if (child.findVar(atom_id) >= 0 or child.findArg(atom_id) >= 0) continue;
            if (!scopeChainContains(parent_fd, child.parent_scope_level, local.scope_level)) continue;
            const child_ref_idx: u16 = if (findClosureVarIndex(child, atom_id)) |existing| blk: {
                if (child.closure_var[existing].closure_type == .local and
                    child.closure_var[existing].var_idx < parent_fd.vars.len)
                {
                    const existing_scope = parent_fd.vars[child.closure_var[existing].var_idx].scope_level;
                    if (existing_scope != local.scope_level and scopeChainContains(parent_fd, existing_scope, local.scope_level)) {
                        continue;
                    }
                }
                child.closure_var[existing].closure_type = .local;
                child.closure_var[existing].is_lexical = local.is_lexical;
                child.closure_var[existing].is_const = local.is_const;
                child.closure_var[existing].var_kind = local.var_kind;
                child.closure_var[existing].var_idx = local_idx;
                break :blk existing;
            } else @intCast(try child.addClosureVar(.{
                .closure_type = .local,
                .is_lexical = local.is_lexical,
                .is_const = local.is_const,
                .var_kind = local.var_kind,
                .var_idx = local_idx,
                .var_name = atom_id,
            }));
            try self.propagateForwardCaptureToDescendants(child, atom_id, child_ref_idx, local.is_lexical, local.is_const, local.var_kind);
        }
    }

    fn emitPushConst(self: *ParseState, value: JSValue) Error!void {
        const idx = if (self.emit_to_function_def or self.top_level_functions_as_children)
            try self.cur_func().appendCpool(value)
        else
            try self.function.addConstant(value);
        try self.emitOpU32(opcode.op.push_const, idx);
    }

    fn emitPushConstOwned(self: *ParseState, value: JSValue) Error!void {
        var value_owned = true;
        errdefer if (value_owned) value.free(self.runtime.?);
        const idx = if (self.emit_to_function_def or self.top_level_functions_as_children)
            try self.cur_func().appendCpoolOwned(value)
        else
            try self.function.constants.appendOwned(value);
        value_owned = false;
        try self.emitOpU32(opcode.op.push_const, idx);
    }

    fn emitBigIntLiteral(self: *ParseState, text: []const u8, negate: bool) Error!void {
        if (parseBigIntI32(text, negate)) |small| {
            try self.emitOpI32(opcode.op.push_bigint_i32, small);
            return;
        }

        const parse_text = if (std.mem.indexOfScalar(u8, text, '_')) |_| blk: {
            var normalized = std.ArrayList(u8).empty;
            errdefer normalized.deinit(self.function.memory.allocator);
            for (text) |ch| {
                if (ch != '_') normalized.append(self.function.memory.allocator, ch) catch return Error.OutOfMemory;
            }
            break :blk normalized.toOwnedSlice(self.function.memory.allocator) catch return Error.OutOfMemory;
        } else text;
        defer if (parse_text.ptr != text.ptr) self.function.memory.allocator.free(parse_text);

        var parsed = libs_bignum.parseAutoAlloc(self.function.memory.persistent_allocator, parse_text) catch return Error.InvalidNumberLiteral;
        errdefer parsed.deinit();
        if (negate and !parsed.isZero()) parsed.negative = !parsed.negative;

        const big = self.function.memory.create(core_bigint.BigInt) catch return Error.OutOfMemory;
        big.* = .{
            .header = .{ .kind = .big_int },
            .value = parsed,
        };
        parsed = .{ .allocator = self.function.memory.persistent_allocator };
        try self.emitPushConstOwned(big.valueRef());
    }

    fn appendBytes(self: *ParseState, bytes: []const u8) Error!void {
        const loc_line = if (self.last_token_line_num >= self.token.line_num) self.last_token_line_num else self.token.line_num;
        const loc_col = if (loc_line == self.last_token_line_num) self.last_token_col_num else self.token.col_num;
        try self.appendBytesAt(bytes, loc_line, loc_col);
    }

    fn appendBytesNoSource(self: *ParseState, bytes: []const u8) Error!void {
        if (self.emit_to_function_def) {
            try self.cur_func().appendByteCode(bytes);
        } else {
            try self.function.appendCode(bytes);
        }
    }

    fn appendBytesAt(self: *ParseState, bytes: []const u8, line_num: u32, col_num: u32) Error!void {
        if (self.emit_to_function_def) {
            const pc: u32 = @intCast(self.cur_func().byte_code.len);
            try self.cur_func().appendSourceLoc(pc, @intCast(line_num), @intCast(col_num));
            try self.cur_func().appendByteCode(bytes);
        } else {
            const pc: u32 = @intCast(self.function.code.len);
            try self.function.appendSourceLoc(pc, @intCast(line_num), @intCast(col_num));
            // Emit to Bytecode object's code buffer (legacy behavior).
            try self.function.appendCode(bytes);
        }
    }

    fn currentCodeLen(self: *ParseState) usize {
        if (self.emit_to_function_def) return self.cur_func().byte_code.len;
        return self.function.code.len;
    }

    fn currentCode(self: *ParseState) []u8 {
        if (self.emit_to_function_def) return self.cur_func().byte_code;
        return self.function.code;
    }

    fn currentAtomOperands(self: *ParseState) []Atom {
        if (self.emit_to_function_def) return self.cur_func().atom_operands;
        return self.function.atom_operands;
    }

    fn appendAtomOperands(self: *ParseState, atoms: []const Atom) Error!void {
        for (atoms) |atom_id| {
            if (self.emit_to_function_def) {
                try self.cur_func().appendAtomOperand(atom_id);
            } else {
                try self.function.retainAtomOperand(atom_id);
            }
        }
    }

    fn appendMovedCodeWithAtoms(self: *ParseState, code: []u8, atoms: []const Atom, old_base: usize) Error!void {
        try rebaseMovedBytecodeLabels(code, atoms, old_base, self.currentCodeLen());
        try self.appendBytes(code);
        try self.appendAtomOperands(atoms);
    }

    /// Drop bytes appended after `target_len`. Used by parseAssignExpr2 /
    /// parsePostfixExpr to roll back a speculative LHS emission once an
    /// assignment / update operator is recognised. Atom operand counts are
    /// rolled back via `truncateAtomOperands`; callers must coordinate the
    /// two so retain/free ref-counts stay balanced.
    ///
    /// The growable-slice scheme keeps the backing buffer alive across
    /// truncation so a re-emission after rollback does not have to
    /// reallocate.
    fn truncateCode(self: *ParseState, target_len: usize) Error!void {
        if (self.emit_to_function_def) {
            self.cur_func().truncateByteCode(target_len);
        } else {
            self.function.truncateCode(target_len);
        }
    }

    /// Drop atom-operand entries beyond `target_len`, releasing the held
    /// atom refcounts. The retain happens in `emitOpAtom`/`retainAtomOperand`.
    fn truncateAtomOperands(self: *ParseState, target_len: usize) Error!void {
        if (self.emit_to_function_def) {
            self.cur_func().truncateAtomOperands(target_len);
            return;
        }
        self.function.truncateAtomOperands(target_len);
    }

    fn currentAtomOperandLen(self: *ParseState) usize {
        return if (self.emit_to_function_def)
            self.cur_func().atom_operands.len
        else
            self.function.atom_operands.len;
    }

    fn appendDirectCallSite(self: *ParseState, prepare_pc: usize, call_pc: usize, atom_id: Atom, argc: u16) Error!void {
        if (self.emit_to_function_def) {
            try self.cur_func().appendDirectCallSite(.{
                .kind = .prop_atom,
                .prepare_pc = @intCast(prepare_pc),
                .call_pc = @intCast(call_pc),
                .atom_id = atom_id,
                .argc = argc,
            });
            return;
        }
        try self.function.appendDirectCallSite(.{
            .kind = .prop_atom,
            .prepare_pc = @intCast(prepare_pc),
            .call_pc = @intCast(call_pc),
            .atom_id = atom_id,
            .argc = argc,
        });
    }
};

/// Check if `<ident> =>` is the arrow function head shape.
/// Saves and restores lexer position so the cached token stays valid.
fn checkIdentArrowHead(s: *ParseState) bool {
    const saved_pos = s.lex.pos;
    const saved_line = s.lex.line;
    const saved_col = s.lex.col;
    const saved_got_lf = s.lex.got_lf;
    const saved_mark_pos = s.lex.mark_pos;
    const saved_mark_line = s.lex.mark_line;
    const saved_mark_col = s.lex.mark_col;
    defer {
        s.lex.pos = saved_pos;
        s.lex.line = saved_line;
        s.lex.col = saved_col;
        s.lex.got_lf = saved_got_lf;
        s.lex.mark_pos = saved_mark_pos;
        s.lex.mark_line = saved_mark_line;
        s.lex.mark_col = saved_mark_col;
    }

    var peek_token = nextRegexpAwareLookaheadToken(s, s.peekKind()) catch return false;
    defer s.lex.freeToken(&peek_token);
    return peek_token.val == tok.TOK_ARROW;
}

fn checkAsyncSingleParamArrowHead(s: *ParseState) bool {
    if (!(s.peekKind() == tok.TOK_IDENT and s.isIdent("async"))) return false;
    if (s.token.payload.ident.has_escape) return false;

    const saved_pos = s.lex.pos;
    const saved_line = s.lex.line;
    const saved_col = s.lex.col;
    const saved_got_lf = s.lex.got_lf;
    const saved_mark_pos = s.lex.mark_pos;
    const saved_mark_line = s.lex.mark_line;
    const saved_mark_col = s.lex.mark_col;

    defer {
        s.lex.pos = saved_pos;
        s.lex.line = saved_line;
        s.lex.col = saved_col;
        s.lex.got_lf = saved_got_lf;
        s.lex.mark_pos = saved_mark_pos;
        s.lex.mark_line = saved_mark_line;
        s.lex.mark_col = saved_mark_col;
    }

    var param_token = nextRegexpAwareLookaheadToken(s, s.peekKind()) catch return false;
    defer s.lex.freeToken(&param_token);
    if (s.lex.gotLineTerminator()) return false;
    if (param_token.val != tok.TOK_IDENT) return false;

    var arrow_token = nextRegexpAwareLookaheadToken(s, param_token.val) catch return false;
    defer s.lex.freeToken(&arrow_token);
    if (s.lex.gotLineTerminator()) return false;
    return arrow_token.val == tok.TOK_ARROW;
}

/// Check if contextual `async` is followed by a parenthesized async arrow head:
/// `async (...) =>`.
fn checkAsyncParenArrowHead(s: *ParseState) bool {
    if (!(s.peekKind() == tok.TOK_IDENT and s.isIdent("async"))) return false;
    if (s.token.payload.ident.has_escape) return false;

    const saved_pos = s.lex.pos;
    const saved_line = s.lex.line;
    const saved_col = s.lex.col;
    const saved_got_lf = s.lex.got_lf;
    const saved_mark_pos = s.lex.mark_pos;
    const saved_mark_line = s.lex.mark_line;
    const saved_mark_col = s.lex.mark_col;

    defer {
        s.lex.pos = saved_pos;
        s.lex.line = saved_line;
        s.lex.col = saved_col;
        s.lex.got_lf = saved_got_lf;
        s.lex.mark_pos = saved_mark_pos;
        s.lex.mark_line = saved_mark_line;
        s.lex.mark_col = saved_mark_col;
    }

    var previous_token_kind: tok.TokenKind = s.peekKind();
    var open_token = nextRegexpAwareLookaheadToken(s, previous_token_kind) catch return false;
    defer s.lex.freeToken(&open_token);
    if (s.lex.gotLineTerminator()) return false;
    if (open_token.val != '(') return false;
    previous_token_kind = open_token.val;

    var depth: i32 = 1;
    while (depth > 0) {
        var scan_token = nextRegexpAwareLookaheadToken(s, previous_token_kind) catch return false;
        const k = scan_token.val;
        s.lex.freeToken(&scan_token);
        if (k == tok.TOK_EOF) return false;
        if (k == '(') depth += 1;
        if (k == ')') depth -= 1;
        previous_token_kind = k;
        if (depth == 0) break;
    }

    var arrow_token = nextRegexpAwareLookaheadToken(s, previous_token_kind) catch return false;
    defer s.lex.freeToken(&arrow_token);
    return arrow_token.val == tok.TOK_ARROW and !s.lex.gotLineTerminator();
}

/// Check if we're at an arrow function head
/// Mirrors `js_parse_skip_parens_token` in quickjs.c:24194.
///
/// Saves the lexer position, scans forward with scratch tokens, then
/// restores the lexer so the cached parser token remains valid.
fn checkArrowHead(s: *ParseState) bool {
    const saved_pos = s.lex.pos;
    const saved_line = s.lex.line;
    const saved_col = s.lex.col;
    const saved_got_lf = s.lex.got_lf;
    const saved_mark_pos = s.lex.mark_pos;
    const saved_mark_line = s.lex.mark_line;
    const saved_mark_col = s.lex.mark_col;
    defer {
        s.lex.pos = saved_pos;
        s.lex.line = saved_line;
        s.lex.col = saved_col;
        s.lex.got_lf = saved_got_lf;
        s.lex.mark_pos = saved_mark_pos;
        s.lex.mark_line = saved_mark_line;
        s.lex.mark_col = saved_mark_col;
    }

    var previous_token_kind: tok.TokenKind = s.peekKind();
    if (s.peekKind() == '(') {
        var depth: i32 = 1;
        while (depth > 0) {
            var scan_token = nextRegexpAwareLookaheadToken(s, previous_token_kind) catch return false;
            const k = scan_token.val;
            s.lex.freeToken(&scan_token);
            if (k == tok.TOK_EOF) return false;
            if (k == '(') depth += 1;
            if (k == ')') depth -= 1;
            previous_token_kind = k;
            if (depth == 0) break;
        }
    } else if (s.peekKind() == tok.TOK_IDENT) {
        var arrow_token = nextRegexpAwareLookaheadToken(s, previous_token_kind) catch return false;
        defer s.lex.freeToken(&arrow_token);
        return arrow_token.val == tok.TOK_ARROW;
    } else {
        return false;
    }

    var arrow_token = nextRegexpAwareLookaheadToken(s, previous_token_kind) catch return false;
    defer s.lex.freeToken(&arrow_token);
    return arrow_token.val == tok.TOK_ARROW;
}

fn nextRegexpAwareLookaheadToken(s: *ParseState, previous_token_kind: ?tok.TokenKind) Error!tok.Token {
    var token = s.lex.next() catch return Error.UnexpectedToken;
    errdefer s.lex.freeToken(&token);
    try rescanLookaheadTokenIfRegexp(s, &token, previous_token_kind);
    return token;
}

fn rescanLookaheadTokenIfRegexp(s: *ParseState, token: *tok.Token, previous_token_kind: ?tok.TokenKind) Error!void {
    if (!(token.val == @as(tok.TokenKind, @intCast('/')) or token.val == tok.TOK_DIV_ASSIGN)) return;
    if (!predeclareSlashStartsRegexp(s, previous_token_kind)) return;

    const slash_offset = s.lex.mark_pos;
    const regexp_token = s.lex.rescanRegexp(slash_offset) catch return Error.UnexpectedToken;
    s.lex.freeToken(token);
    token.* = regexp_token;
}

fn advanceRegexpAwareSpeculativeToken(s: *ParseState, previous_token_kind: *?tok.TokenKind) Error!void {
    try rescanLookaheadTokenIfRegexp(s, &s.token, previous_token_kind.*);
    previous_token_kind.* = s.peekKind();
    try s.advance();
}

// =====================================================================
// Expression parser entry points (mirror QuickJS function names).
// =====================================================================

/// `js_parse_expr` (`quickjs.c:27645`).
pub fn parseExpr(s: *ParseState) Error!void {
    return parseExpr2(s, ParseFlags.default);
}

/// `js_parse_expr2` (`quickjs.c:27621`). Comma operator.
pub fn parseExpr2(s: *ParseState, flags: ParseFlags) Error!void {
    s.features.insert(.expression);
    var operand_flags = flags;
    try parseAssignExpr2(s, operand_flags);
    var saw_comma = false;
    while (s.isPunct(',')) {
        saw_comma = true;
        try s.advance();
        // Discard left-hand side; `a, b` evaluates to b.
        if (s.suppress_expr_statement_drop) {
            s.suppress_expr_statement_drop = false;
        } else {
            try s.emitOp(opcode.op.drop);
        }
        operand_flags.result_needed = flags.result_needed;
        try parseAssignExpr2(s, operand_flags);
    }
    if (saw_comma) {
        s.last_anonymous_function_expr = false;
        s.last_was_direct_eval_callee = false;
    }
    s.last_expr_had_comma = saw_comma;
}

/// `js_parse_assign_expr` (`quickjs.c:27615`).
pub fn parseAssignExpr(s: *ParseState) Error!void {
    return parseAssignExpr2(s, ParseFlags.default);
}

/// `js_parse_assign_expr2` (`quickjs.c:27311`). Assignment-target check
/// and compound-assignment lowering for identifiers, member targets,
/// destructuring, and arrow cover forms.
pub fn parseAssignExpr2(s: *ParseState, flags: ParseFlags) Error!void {
    // std.debug.print("parseAssignExpr2: s.token.val={d} ('{c}')\n", .{ s.token.val, @as(u8, @intCast(if (s.token.val >= 0 and s.token.val <= 255) s.token.val else ' ' )) });
    s.assign_expr_depth += 1;
    const current_assign_depth = s.assign_expr_depth;
    s.last_expr_was_short_circuit_or_cond = false;
    if (s.last_coalesce_expr_depth == current_assign_depth) {
        s.last_coalesce_expr_depth = null;
    }
    defer s.assign_expr_depth -= 1;

    s.last_lhs_was_tagged_template = false;
    if (try parseDestructuringAssignment(s, flags)) return;
    // Capture an identifier target up front so we can re-emit if an
    // assignment operator follows. A full implementation would defer the
    // LHS emission until the assignment shape is known (QuickJS's
    // `JS_INIT_LV` deferred-emit path); for now we truncate the
    // speculative `get_var` and re-emit. Track the pre-LHS code/atom
    // lengths so the rollback is targeted (deeper recursion may have
    // already emitted unrelated bytes — wiping the whole buffer is
    // unsound, e.g. `1 + (a = b)`).
    const direct_lhs_atom: ?Atom = if (isIdentifierLikeToken(s)) identifierLikeAtom(s) else null;
    const saved_atom: ?Atom = direct_lhs_atom orelse peekParenthesizedBareIdent(s);
    const pre_lhs_code_len = s.currentCodeLen();
    const pre_lhs_atom_len = s.currentAtomOperandLen();

    try parseCondExpr(s, flags);

    const op_kind = s.peekKind();
    const assign_opcode = compoundAssignOpcode(op_kind);
    const logical_assign = logicalAssignKind(op_kind);
    const is_plain_assign = op_kind == @as(tok.TokenKind, @intCast('='));
    if (!is_plain_assign and assign_opcode == null and logical_assign == null) return;

    if (s.last_coalesce_expr_depth == current_assign_depth) {
        return Error.InvalidAssignmentTarget;
    }

    const shape = classifyLhs(s, pre_lhs_code_len, pre_lhs_atom_len, saved_atom);
    if (shape == .none) return Error.InvalidAssignmentTarget;
    if (shape == .invalid_call and (s.is_strict or s.cur_func().is_strict_mode)) return Error.InvalidAssignmentTarget;
    if ((s.is_strict or s.cur_func().is_strict_mode) and shape == .var_ref) {
        const atom_id = shape.var_ref.atom;
        if (atomNameEquals(s, atom_id, "eval") or atomNameEquals(s, atom_id, "arguments")) {
            return Error.InvalidAssignmentTarget;
        }
    }

    try s.advance(); // consume the assignment operator

    if (logical_assign) |kind| {
        if (shape == .invalid_call) return Error.InvalidAssignmentTarget;
        try emitLogicalAssign(s, flags, shape, kind, pre_lhs_atom_len);
    } else if (assign_opcode) |op_byte| {
        // Compound: `a.b += v` etc. Keep the receiver/key using the
        // QuickJS lvalue-read shape, then emit rhs, the binop, and store.
        var use_var_ref_snapshot = false;
        switch (shape) {
            .var_ref => |v| {
                if (try rhsMayContainDirectEvalCall(s)) {
                    try s.truncateCode(v.code_pos);
                    try s.truncateAtomOperands(pre_lhs_atom_len);
                    try s.emitScopeMakeRef(v.atom);
                    try s.emitOp(opcode.op.get_ref_value);
                    use_var_ref_snapshot = true;
                }
            },
            .dotted, .indexed => try rewriteToGetForm2(s, shape),
            .super_dotted => |d| {
                try s.truncateCode(d.code_pos);
                try s.emitOp(opcode.op.to_propkey);
                try s.emitOp(opcode.op.dup3);
                try s.emitOp(opcode.op.get_super_value);
            },
            .with_ref => {},
            .invalid_call => {
                try s.emitOpAtomU8(opcode.op.throw_error, atom_module.null_atom, 2);
                const rhs_flags = ParseFlags{ .in_accepted = flags.in_accepted };
                try parseAssignExpr2(s, rhs_flags);
                return;
            },
            .none => unreachable,
        }
        const rhs_flags = ParseFlags{ .in_accepted = flags.in_accepted };
        try parseAssignExpr2(s, rhs_flags);
        try s.emitOp(op_byte);
        if (use_var_ref_snapshot) {
            try emitPutRefValue(s, flags.result_needed);
        } else if (flags.result_needed) {
            try emitPutLValueKeepTop(s, shape);
        } else if (shape == .var_ref and !isNonLexicalBinding(s, shape.var_ref.atom)) {
            try emitPutLValueKeepTop(s, shape);
        } else {
            try emitPutLValueNoKeep(s, shape);
        }
    } else {
        // Plain `=`: drop the speculative load (we don't need the old value).
        const rhs_flags = ParseFlags{ .in_accepted = flags.in_accepted };
        switch (shape) {
            .var_ref => |v| {
                try s.truncateCode(v.code_pos);
                try s.truncateAtomOperands(pre_lhs_atom_len);
                const is_function_expr_name = isCurrentFunctionExpressionName(s, v.atom);
                const use_reference_snapshot = !is_function_expr_name and
                    ((try rhsMayContainDirectEvalCall(s)) or shouldSnapshotStrictUnresolvedAssignment(s, v.atom));
                if (use_reference_snapshot) {
                    try s.emitScopeMakeRef(v.atom);
                }
                try parseAssignExpr2(s, rhs_flags);
                if (direct_lhs_atom != null and s.last_anonymous_function_expr) {
                    try s.emitOpAtom(opcode.op.set_name, v.atom);
                    s.last_anonymous_function_expr = false;
                }
                if (is_function_expr_name) {
                    if (s.is_strict or s.cur_func().is_strict_mode) {
                        try s.emitOpAtomU8(opcode.op.throw_error, atom_module.null_atom, 4);
                    }
                    return;
                }
                if (use_reference_snapshot) {
                    try emitPutRefValue(s, flags.result_needed);
                } else if (flags.result_needed or !isNonLexicalBinding(s, v.atom)) {
                    try s.emitOp(opcode.op.dup);
                    try s.emitScopePutVar(v.atom);
                } else {
                    try emitPutLValueDropResult(s, shape);
                }
            },
            .dotted => |d| {
                // Drop the speculative `get_field <atom>` (5 bytes plus
                // its atom_operand entry); the receiver stays on the
                // stack from earlier emission.
                try s.truncateCode(d.code_pos);
                const atom_len = s.currentAtomOperandLen();
                if (atom_len == 0) return Error.UnexpectedToken;
                try s.truncateAtomOperands(atom_len - 1);
                try parseAssignExpr2(s, rhs_flags);
                if (s.last_anonymous_function_expr) {
                    s.last_anonymous_function_expr = false;
                }
                if (flags.result_needed) {
                    try s.emitOp(opcode.op.insert2);
                    try s.emitOpAtom(opcode.op.put_field, d.atom);
                } else {
                    try emitPutLValueDropResult(s, shape);
                }
            },
            .super_dotted => |d| {
                try s.truncateCode(d.code_pos);
                try parseAssignExpr2(s, rhs_flags);
                if (flags.result_needed) {
                    try s.emitOp(opcode.op.insert3);
                } else {
                    s.suppress_expr_statement_drop = true;
                }
                try s.emitOp(opcode.op.put_super_value);
            },
            .indexed => |i| {
                // Drop the speculative `get_array_el` (1 byte); the
                // receiver+key stay on the stack.
                try s.truncateCode(i.code_pos);
                try parseAssignExpr2(s, rhs_flags);
                if (s.last_anonymous_function_expr) {
                    s.last_anonymous_function_expr = false;
                }
                if (flags.result_needed) {
                    try s.emitOp(opcode.op.insert3);
                    try s.emitOp(opcode.op.put_array_el);
                } else {
                    try emitPutLValueDropResult(s, shape);
                }
            },
            .with_ref => {
                try s.truncateCode(pre_lhs_code_len);
                try s.truncateAtomOperands(pre_lhs_atom_len);
                try emitWithMakeRefFallback(s, s.active_with_atom orelse return Error.UnexpectedToken, shape.with_ref.atom);
                try parseAssignExpr2(s, rhs_flags);
                if (direct_lhs_atom != null and s.last_anonymous_function_expr) {
                    try s.emitOpAtom(opcode.op.set_name, shape.with_ref.atom);
                    s.last_anonymous_function_expr = false;
                }
                if (flags.result_needed) {
                    try emitPutLValueKeepTop(s, shape);
                } else {
                    try emitPutLValueDropResult(s, shape);
                }
            },
            .invalid_call => {
                try s.emitOpAtomU8(opcode.op.throw_error, atom_module.null_atom, 2);
                try parseAssignExpr2(s, rhs_flags);
            },
            .none => unreachable,
        }
    }
}

fn parseDestructuringAssignment(s: *ParseState, flags: ParseFlags) Error!bool {
    const kind: DestructuringKind = switch (s.peekKind()) {
        @as(tok.TokenKind, @intCast('[')) => .array,
        @as(tok.TokenKind, @intCast('{')) => .object,
        else => return false,
    };
    const initial = takeParserSnapshot(s);
    {
        const saved_assignment_target_mode = s.destructuring_assignment_target_mode;
        s.destructuring_assignment_target_mode = true;
        defer s.destructuring_assignment_target_mode = saved_assignment_target_mode;
        parseDestructuringPattern(s, kind, null) catch |err| switch (err) {
            error.UnexpectedToken, error.InvalidAssignmentTarget => {
                try truncateSpeculativeParse(s, initial.code_len, initial.atom_len);
                restoreParserLexerSnapshot(s, initial);
                return false;
            },
            else => return err,
        };
        try truncateSpeculativeParse(s, initial.code_len, initial.atom_len);
    }
    if (s.peekKind() != @as(tok.TokenKind, @intCast('='))) {
        restoreParserLexerSnapshot(s, initial);
        return false;
    }
    try s.advance();

    const temp_idx = try appendTempLocal(s);
    const rhs_flags = ParseFlags{ .in_accepted = flags.in_accepted };
    try parseAssignExpr2(s, rhs_flags);
    try s.emitOpU16(opcode.op.set_loc, temp_idx);
    const after_rhs = takeParserSnapshot(s);
    restoreParserLexerSnapshot(s, initial);
    {
        const saved_assignment_target_mode = s.destructuring_assignment_target_mode;
        s.destructuring_assignment_target_mode = true;
        defer s.destructuring_assignment_target_mode = saved_assignment_target_mode;
        try parseDestructuringPattern(s, kind, BindingSource{ .loc = temp_idx });
    }
    restoreParserLexerSnapshot(s, after_rhs);
    return true;
}

const LogicalAssignKind = enum {
    land,
    lor,
    nullish,
};

fn emitLogicalAssign(
    s: *ParseState,
    flags: ParseFlags,
    shape: LhsShape,
    kind: LogicalAssignKind,
    pre_lhs_atom_len: usize,
) Error!void {
    var use_var_ref_snapshot = false;
    switch (shape) {
        .var_ref => |v| {
            if (try rhsMayContainDirectEvalCall(s)) {
                try s.truncateCode(v.code_pos);
                try s.truncateAtomOperands(pre_lhs_atom_len);
                try s.emitScopeMakeRef(v.atom);
                try s.emitOp(opcode.op.get_ref_value);
                use_var_ref_snapshot = true;
            }
        },
        .dotted => try rewriteToGetForm2(s, shape),
        .super_dotted => {
            try s.emitOp(opcode.op.perm4);
            try s.emitOp(opcode.op.put_super_value);
        },
        .indexed => |i| {
            try s.truncateCode(i.code_pos);
            try s.emitOp(opcode.op.to_propkey2);
            try s.emitOp(opcode.op.dup2);
            try s.emitOp(opcode.op.get_array_el);
        },
        .with_ref => {},
        .invalid_call, .none => return Error.InvalidAssignmentTarget,
    }

    try s.emitOp(opcode.op.dup);
    const skip_assign = switch (kind) {
        .land => try emitForwardJump(s, opcode.op.if_false),
        .lor => try emitForwardJump(s, opcode.op.if_true),
        .nullish => blk: {
            try s.emitOp(opcode.op.is_undefined_or_null);
            break :blk try emitForwardJump(s, opcode.op.if_false);
        },
    };

    try s.emitOp(opcode.op.drop);
    const rhs_flags = ParseFlags{ .in_accepted = flags.in_accepted };
    s.last_anonymous_function_expr = false;
    try parseAssignExpr2(s, rhs_flags);
    if (shape == .var_ref and s.last_anonymous_function_expr) {
        try s.emitOpAtom(opcode.op.set_name, shape.var_ref.atom);
        s.last_anonymous_function_expr = false;
    }
    if (use_var_ref_snapshot) {
        try emitPutRefValue(s, flags.result_needed);
    } else if (flags.result_needed) {
        try emitPutLValueKeepTop(s, shape);
    } else {
        try emitPutLValueConsume(s, shape);
    }
    const end = try emitForwardJump(s, opcode.op.goto);

    try patchForwardJump(s, skip_assign);
    if (use_var_ref_snapshot) {
        try emitLogicalNoAssignRefCleanup(s, flags.result_needed);
    } else {
        try emitLogicalNoAssignCleanup(s, shape, flags.result_needed);
    }
    try patchForwardJump(s, end);
}

fn emitLogicalNoAssignRefCleanup(s: *ParseState, result_needed: bool) Error!void {
    if (result_needed) {
        try s.emitOp(opcode.op.nip);
        try s.emitOp(opcode.op.nip);
    } else {
        try s.emitOp(opcode.op.drop);
        try s.emitOp(opcode.op.drop);
        try s.emitOp(opcode.op.drop);
    }
}

fn emitLogicalNoAssignCleanup(s: *ParseState, shape: LhsShape, result_needed: bool) Error!void {
    switch (shape) {
        .var_ref => {
            if (!result_needed) try s.emitOp(opcode.op.drop);
        },
        .dotted => {
            if (result_needed) {
                try s.emitOp(opcode.op.nip);
            } else {
                try s.emitOp(opcode.op.drop);
                try s.emitOp(opcode.op.drop);
            }
        },
        .super_dotted => {
            if (result_needed) {
                try s.emitOp(opcode.op.nip);
            } else {
                try s.emitOp(opcode.op.drop);
                try s.emitOp(opcode.op.drop);
            }
        },
        .indexed => {
            if (result_needed) {
                try s.emitOp(opcode.op.nip);
                try s.emitOp(opcode.op.nip);
            } else {
                try s.emitOp(opcode.op.drop);
                try s.emitOp(opcode.op.drop);
                try s.emitOp(opcode.op.drop);
            }
        },
        .with_ref => {
            if (result_needed) {
                try s.emitOp(opcode.op.nip);
            } else {
                try s.emitOp(opcode.op.drop);
                try s.emitOp(opcode.op.drop);
            }
        },
        .invalid_call, .none => return Error.InvalidAssignmentTarget,
    }
}

/// Classification of the bytecode tail emitted by `parseLhsExpr` (or a
/// sub-parse). Mirrors QuickJS's `get_lvalue` opcode return value; the
/// caller turns it into the appropriate `put_lvalue` (KEEP_TOP for
/// assignment / prefix update; KEEP_SECOND for postfix update) sequence
/// per `quickjs.c:25466..25553`.
const LhsShape = union(enum) {
    none,
    invalid_call,
    /// `get_var <atom>` (5 bytes) — depth 0 reference.
    var_ref: struct { atom: Atom, code_pos: usize },
    /// `get_field <atom>` (5 bytes) — depth 1 reference. Compound assign
    /// rewrites this in place to `get_field2`.
    dotted: struct { atom: Atom, code_pos: usize },
    /// `get_super; <prop>; get_super_value` — depth 2 super reference.
    super_dotted: struct { code_pos: usize },
    /// `get_array_el` (1 byte) — depth 2 reference. Compound/update
    /// rewrites this to `to_propkey2; dup2; get_array_el`.
    indexed: struct { code_pos: usize },
    /// `with_get_ref <atom> ... fallback get_var <atom>` — depth 2
    /// reference where the base is either the with object or undefined.
    with_ref: struct { atom: Atom },
};

/// Inspect the trailing emission of a sub-parse and classify the LHS
/// shape. `pre_lhs_code_len` / `pre_lhs_atom_len` capture the buffer
/// state right before the sub-parse started; `saved_atom` is the atom
/// of a leading IDENT token if the caller observed one (used to
/// disambiguate a bare-identifier emission from a complex sub-parse
/// that happened to end at the same byte length).
fn classifyLhs(
    s: *ParseState,
    pre_lhs_code_len: usize,
    pre_lhs_atom_len: usize,
    saved_atom: ?Atom,
) LhsShape {
    const code = s.currentCode();
    if (saved_atom) |ident| {
        var pos = pre_lhs_code_len;
        while (pos + 9 <= code.len) : (pos += 1) {
            if (code[pos] != opcode.op.with_get_ref) continue;
            const atom_id: Atom = std.mem.readInt(u32, code[pos + 1 ..][0..4], .little);
            if (atom_id == ident) return .{ .with_ref = .{ .atom = ident } };
        }
    }
    // var_ref: exactly `get_var <atom>` (5 bytes) or `scope_get_var <atom> <u16>` (7 bytes) was added.
    if (saved_atom) |ident| {
        const final_pos = if (code.len >= pre_lhs_code_len + 5) code.len - 5 else pre_lhs_code_len;
        const temp_pos = if (code.len >= pre_lhs_code_len + 7) code.len - 7 else pre_lhs_code_len;
        const is_final = code.len >= pre_lhs_code_len + 5 and code[final_pos] == opcode.op.get_var;
        const is_temp = code.len >= pre_lhs_code_len + 7 and code[temp_pos] == opcode.op.scope_get_var;
        const code_pos = if (is_final) final_pos else temp_pos;
        const atom_operands = if (s.emit_to_function_def) s.cur_func().atom_operands else s.function.atom_operands;
        const atom_operand_matches =
            (atom_operands.len > pre_lhs_atom_len and
                atom_operands[atom_operands.len - 1] == ident);
        if ((is_final or is_temp) and atom_operand_matches) {
            const emitted = std.mem.readInt(u32, code[code_pos + 1 ..][0..4], .little);
            if (@as(Atom, emitted) == ident) {
                return .{ .var_ref = .{ .atom = ident, .code_pos = code_pos } };
            }
        }
    }
    // indexed: trailing `get_array_el` (1 byte). Check this before
    // fixed-width field forms so large numeric index literal payload bytes
    // cannot be mistaken for a trailing field opcode.
    if (code.len > pre_lhs_code_len and code[code.len - 1] == opcode.op.get_array_el) {
        if (s.last_lhs_had_optional_chain) return .none;
        return .{ .indexed = .{ .code_pos = code.len - 1 } };
    }
    // super reference: trailing `get_super_value` consumes the already
    // emitted receiver and property key.
    if (code.len > pre_lhs_code_len and code[code.len - 1] == opcode.op.get_super_value) {
        return .{ .super_dotted = .{ .code_pos = code.len - 1 } };
    }
    // dotted: trailing `get_field <atom>` (5 bytes).
    if (code.len >= pre_lhs_code_len + 5 and code[code.len - 5] == opcode.op.get_field) {
        if (s.last_lhs_had_optional_chain) return .none;
        const atom_id: Atom = std.mem.readInt(u32, code[code.len - 4 ..][0..4], .little);
        return .{ .dotted = .{ .atom = atom_id, .code_pos = code.len - 5 } };
    }
    if (s.last_lhs_was_tagged_template) return .none;
    if (code.len > pre_lhs_code_len) {
        const last = code[code.len - 1];
        if (last >= opcode.op.call0 and last <= opcode.op.call3) return .invalid_call;
        if (code.len >= pre_lhs_code_len + 3) {
            const op_id = code[code.len - 3];
            if (op_id == opcode.op.call or op_id == opcode.op.call_method) return .invalid_call;
        }
    }
    return .none;
}

fn emitPutRefValue(s: *ParseState, result_needed: bool) Error!void {
    if (result_needed) {
        try s.emitOp(opcode.op.insert3);
    } else {
        s.suppress_expr_statement_drop = true;
    }
    try s.emitOp(opcode.op.put_ref_value);
}

/// `put_lvalue` with PUT_LVALUE_KEEP_TOP semantics — used for plain
/// assignment, compound assignment, and prefix update. Mirrors
/// `quickjs.c:25470..25530`.
fn emitPutLValueKeepTop(s: *ParseState, shape: LhsShape) Error!void {
    switch (shape) {
        .var_ref => |v| {
            try s.emitOp(opcode.op.dup);
            try s.emitScopePutVar(v.atom);
        },
        .dotted => |d| {
            try s.emitOp(opcode.op.insert2);
            try s.emitOpAtom(opcode.op.put_field, d.atom);
        },
        .super_dotted => {
            try s.emitOp(opcode.op.insert4);
            try s.emitOp(opcode.op.put_super_value);
        },
        .indexed => {
            try s.emitOp(opcode.op.insert3);
            try s.emitOp(opcode.op.put_array_el);
        },
        .with_ref => |w| try emitPutWithRefKeep(s, w.atom, .top),
        .invalid_call, .none => return Error.InvalidAssignmentTarget,
    }
}

/// `put_lvalue` when the enclosing expression statement discards the
/// assignment result. QuickJS omits the KEEP_TOP shuffle in this context.
fn emitPutLValueDropResult(s: *ParseState, shape: LhsShape) Error!void {
    switch (shape) {
        .var_ref => |v| {
            s.suppress_expr_statement_drop = true;
            try s.emitScopePutVar(v.atom);
        },
        .dotted => |d| {
            s.suppress_expr_statement_drop = true;
            try s.emitOpAtom(opcode.op.put_field, d.atom);
        },
        .super_dotted => {
            s.suppress_expr_statement_drop = true;
            try s.emitOp(opcode.op.put_super_value);
        },
        .indexed => {
            s.suppress_expr_statement_drop = true;
            try s.emitOp(opcode.op.put_array_el);
        },
        .with_ref => |w| {
            s.suppress_expr_statement_drop = true;
            try emitPutWithRefKeep(s, w.atom, .none);
        },
        .invalid_call, .none => return Error.InvalidAssignmentTarget,
    }
}

/// Store an lvalue without preserving the assigned value. QuickJS uses
/// this for compound assignments in expression statements.
fn emitPutLValueNoKeep(s: *ParseState, shape: LhsShape) Error!void {
    switch (shape) {
        .var_ref => |v| {
            s.suppress_expr_statement_drop = true;
            try s.emitScopePutVar(v.atom);
        },
        .dotted => |d| {
            s.suppress_expr_statement_drop = true;
            try s.emitOpAtom(opcode.op.put_field, d.atom);
        },
        .super_dotted => {
            s.suppress_expr_statement_drop = true;
            try s.emitOp(opcode.op.put_super_value);
        },
        .indexed => {
            s.suppress_expr_statement_drop = true;
            try s.emitOp(opcode.op.put_array_el);
        },
        .with_ref => |w| {
            s.suppress_expr_statement_drop = true;
            try emitPutWithRefKeep(s, w.atom, .none);
        },
        .invalid_call, .none => return Error.InvalidAssignmentTarget,
    }
}

fn emitPutLValueConsume(s: *ParseState, shape: LhsShape) Error!void {
    switch (shape) {
        .var_ref => |v| {
            s.suppress_expr_statement_drop = true;
            try s.emitScopePutVar(v.atom);
        },
        .dotted => |d| {
            s.suppress_expr_statement_drop = true;
            try s.emitOpAtom(opcode.op.put_field, d.atom);
        },
        .super_dotted => {
            s.suppress_expr_statement_drop = true;
            try s.emitOp(opcode.op.put_super_value);
        },
        .indexed => {
            s.suppress_expr_statement_drop = true;
            try s.emitOp(opcode.op.put_array_el);
        },
        .with_ref => |w| {
            s.suppress_expr_statement_drop = true;
            try emitPutWithRefKeep(s, w.atom, .none);
        },
        .invalid_call, .none => return Error.InvalidAssignmentTarget,
    }
}

fn isNonLexicalBinding(s: *ParseState, atom_id: Atom) bool {
    for (s.cur_func().closure_var) |cv| {
        if (cv.var_name == atom_id) return !cv.is_lexical;
    }
    for (s.cur_func().vars) |v| {
        if (v.var_name == atom_id) return !v.is_lexical;
    }
    return s.emit_to_function_def;
}

fn hasKnownBinding(s: *ParseState, atom_id: Atom) bool {
    for (s.cur_func().closure_var) |cv| {
        if (cv.var_name == atom_id) return true;
    }
    var scope = s.scope_level;
    while (scope >= 0 and @as(usize, @intCast(scope)) < s.cur_func().scopes.len) {
        var idx = s.cur_func().scopes[@intCast(scope)].first;
        while (idx >= 0 and @as(usize, @intCast(idx)) < s.cur_func().vars.len) {
            const v = s.cur_func().vars[@intCast(idx)];
            if (v.var_name == atom_id) return true;
            idx = v.scope_next;
        }
        scope = s.cur_func().scopes[@intCast(scope)].parent;
    }
    for (s.cur_func().args) |a| {
        if (a.var_name == atom_id) return true;
    }
    return false;
}

fn evalDeleteBindingIsConfigurable(is_lexical: bool, var_kind: function_def_mod.VarKind) bool {
    return !is_lexical or var_kind == .function_decl;
}

fn evalClosureBindingIsConfigurable(s: *ParseState, owner_index: usize, cv: function_def_mod.ClosureVar) bool {
    const owner = s.funcAtVirtualIndex(owner_index);
    switch (cv.closure_type) {
        .local => {
            if (owner_index == 0) return false;
            const parent = s.funcAtVirtualIndex(owner_index - 1);
            if (cv.var_idx >= parent.vars.len) return false;
            const v = parent.vars[cv.var_idx];
            return parent.is_eval and evalDeleteBindingIsConfigurable(v.is_lexical, v.var_kind);
        },
        .ref => {
            if (owner_index == 0) return false;
            const parent = s.funcAtVirtualIndex(owner_index - 1);
            if (cv.var_idx >= parent.closure_var.len) return false;
            return evalClosureBindingIsConfigurable(s, owner_index - 1, parent.closure_var[cv.var_idx]);
        },
        .global_decl, .global, .module_decl => {
            return owner.is_eval and evalDeleteBindingIsConfigurable(cv.is_lexical, cv.var_kind);
        },
        .arg, .global_ref, .module_import => return false,
    }
}

fn hasEvalNonLexicalBinding(s: *ParseState, atom_id: Atom) bool {
    if (!s.eval_delete_bindings) return false;
    if (s.is_eval) {
        for (s.cur_func().vars) |v| {
            if (v.var_name == atom_id) return evalDeleteBindingIsConfigurable(v.is_lexical, v.var_kind);
        }
        for (s.cur_func().closure_var) |cv| {
            if (cv.var_name == atom_id) return evalClosureBindingIsConfigurable(s, s.cur_func_stack.len, cv);
        }
        return false;
    }
    if (hasCurrentFunctionBinding(s, atom_id)) return false;
    for (s.cur_func().closure_var) |cv| {
        if (cv.var_name == atom_id) return evalClosureBindingIsConfigurable(s, s.cur_func_stack.len, cv);
    }
    return false;
}

fn shouldSnapshotStrictUnresolvedAssignment(s: *ParseState, atom_id: Atom) bool {
    if (!(s.is_strict or s.cur_func().is_strict_mode)) return false;
    if (hasKnownBinding(s, atom_id)) return false;
    if (hasEvalNonLexicalBinding(s, atom_id)) return false;
    return true;
}

/// Direct eval in an assignment RHS can introduce a same-name `var`
/// binding before PutValue runs, so identifier lvalues must preserve
/// the original Reference. This scanner advances only the lexer cursor;
/// it leaves `s.token` owned by the parser.
fn rhsMayContainDirectEvalCall(s: *ParseState) Error!bool {
    const saved_pos = s.lex.pos;
    const saved_line = s.lex.line;
    const saved_col = s.lex.col;
    const saved_got_lf = s.lex.got_lf;
    const saved_mark_pos = s.lex.mark_pos;
    const saved_mark_line = s.lex.mark_line;
    const saved_mark_col = s.lex.mark_col;
    defer {
        s.lex.pos = saved_pos;
        s.lex.line = saved_line;
        s.lex.col = saved_col;
        s.lex.got_lf = saved_got_lf;
        s.lex.mark_pos = saved_mark_pos;
        s.lex.mark_line = saved_mark_line;
        s.lex.mark_col = saved_mark_col;
    }

    var paren_depth: usize = 0;
    var bracket_depth: usize = 0;
    var brace_depth: usize = 0;
    var expect_operand = true;

    switch (try scanAssignmentRhsTokenForDirectEval(s, &s.token, &paren_depth, &bracket_depth, &brace_depth, &expect_operand)) {
        .found => return true,
        .boundary => return false,
        .continue_scan => {},
    }

    while (true) {
        var lookahead = try s.lex.next();
        defer s.lex.freeToken(&lookahead);
        if (lookahead.val == tok.TOK_EOF) return false;
        switch (try scanAssignmentRhsTokenForDirectEval(s, &lookahead, &paren_depth, &bracket_depth, &brace_depth, &expect_operand)) {
            .found => return true,
            .boundary => return false,
            .continue_scan => {},
        }
    }
}

fn assignmentRhsScanBoundary(kind: tok.TokenKind) bool {
    return kind == @as(tok.TokenKind, @intCast(',')) or
        kind == @as(tok.TokenKind, @intCast(';')) or
        kind == @as(tok.TokenKind, @intCast(')')) or
        kind == @as(tok.TokenKind, @intCast(']')) or
        kind == @as(tok.TokenKind, @intCast('}'));
}

const RhsEvalScanResult = enum {
    continue_scan,
    found,
    boundary,
};

fn scanAssignmentRhsTokenForDirectEval(
    s: *ParseState,
    token: *const tok.Token,
    paren_depth: *usize,
    bracket_depth: *usize,
    brace_depth: *usize,
    expect_operand: *bool,
) Error!RhsEvalScanResult {
    const kind = token.val;
    if (paren_depth.* == 0 and bracket_depth.* == 0 and brace_depth.* == 0 and assignmentRhsScanBoundary(kind)) {
        return .boundary;
    }
    if (tokenCanStartSlashRegexp(kind) and expect_operand.*) {
        try skipRegExpLiteralInRhsScan(s, token);
        expect_operand.* = false;
        return .continue_scan;
    }
    if (kind == tok.TOK_TEMPLATE) {
        const part = token.payload.str.template orelse return Error.UnexpectedToken;
        expect_operand.* = part != .no_substitution and part != .tail;
        if (part != .no_substitution and part != .tail) return .found;
    }
    if (kind == tok.TOK_IDENT and
        atomNameEquals(s, token.payload.ident.atom, "eval") and
        s.peekNextKind() == @as(tok.TokenKind, @intCast('(')))
    {
        return .found;
    }

    switch (kind) {
        @as(tok.TokenKind, @intCast('(')) => {
            paren_depth.* += 1;
            expect_operand.* = true;
        },
        @as(tok.TokenKind, @intCast('[')) => {
            bracket_depth.* += 1;
            expect_operand.* = true;
        },
        @as(tok.TokenKind, @intCast('{')) => {
            brace_depth.* += 1;
            expect_operand.* = true;
        },
        @as(tok.TokenKind, @intCast(')')) => {
            if (paren_depth.* == 0) return .boundary;
            paren_depth.* -= 1;
            expect_operand.* = false;
        },
        @as(tok.TokenKind, @intCast(']')) => {
            if (bracket_depth.* == 0) return .boundary;
            bracket_depth.* -= 1;
            expect_operand.* = false;
        },
        @as(tok.TokenKind, @intCast('}')) => {
            if (brace_depth.* == 0) return .boundary;
            brace_depth.* -= 1;
            expect_operand.* = false;
        },
        else => expect_operand.* = tokenForcesRhsOperandAfter(kind),
    }
    return .continue_scan;
}

fn skipRegExpLiteralInRhsScan(s: *ParseState, token: *const tok.Token) Error!void {
    var regexp_token = try s.lex.rescanRegexp(tokenStartOffset(s, token));
    defer s.lex.freeToken(&regexp_token);
}

fn tokenStartOffset(s: *const ParseState, token: *const tok.Token) usize {
    const source_ptr = @intFromPtr(s.lex.source.ptr);
    const token_ptr = @intFromPtr(token.ptr);
    if (token_ptr <= source_ptr) return 0;
    return @min(token_ptr - source_ptr, s.lex.source.len);
}

fn tokenForcesRhsOperandAfter(kind: tok.TokenKind) bool {
    if (kind < 0) return switch (kind) {
        tok.TOK_INC,
        tok.TOK_DEC,
        tok.TOK_NUMBER,
        tok.TOK_STRING,
        tok.TOK_TEMPLATE,
        tok.TOK_IDENT,
        tok.TOK_NULL,
        tok.TOK_FALSE,
        tok.TOK_TRUE,
        tok.TOK_THIS,
        tok.TOK_SUPER,
        => false,
        else => true,
    };
    return switch (@as(u8, @intCast(kind))) {
        '+', '-', '*', '/', '%', '&', '|', '^', '!', '~', '?', ':', '=', ',' => true,
        '.' => true,
        else => false,
    };
}

fn hasCurrentFunctionBinding(s: *ParseState, atom_id: Atom) bool {
    return s.cur_func().findVar(atom_id) >= 0 or s.cur_func().findArg(atom_id) >= 0;
}

fn atomListContains(list: []const Atom, atom_id: Atom) bool {
    for (list) |item| {
        if (item == atom_id) return true;
    }
    return false;
}

fn appendRetainedAtom(list: *std.ArrayList(Atom), allocator: std.mem.Allocator, atoms: *atom_module.AtomTable, atom_id: Atom) Error!void {
    const retained = atoms.dup(atom_id);
    errdefer atoms.free(retained);
    try list.append(allocator, retained);
}

fn appendSwitchLexName(lex_names: *std.ArrayList(Atom), var_names: *const std.ArrayList(Atom), atom_id: Atom, allocator: std.mem.Allocator) Error!void {
    if (atomListContains(lex_names.items, atom_id) or atomListContains(var_names.items, atom_id)) return Error.UnexpectedToken;
    try lex_names.append(allocator, atom_id);
}

fn appendSwitchFunctionName(
    s: *ParseState,
    lex_names: *std.ArrayList(Atom),
    function_names: *std.ArrayList(Atom),
    var_names: *const std.ArrayList(Atom),
    atom_id: Atom,
) Error!void {
    if (s.is_strict or s.cur_func().is_strict_mode) {
        try appendSwitchLexName(lex_names, var_names, atom_id, s.lex.allocator);
        return;
    }
    if (atomListContains(var_names.items, atom_id)) return Error.UnexpectedToken;
    if (atomListContains(lex_names.items, atom_id) and !atomListContains(function_names.items, atom_id)) return Error.UnexpectedToken;
    if (!atomListContains(lex_names.items, atom_id)) try lex_names.append(s.lex.allocator, atom_id);
    if (!atomListContains(function_names.items, atom_id)) try function_names.append(s.lex.allocator, atom_id);
}

fn appendSwitchVarName(var_names: *std.ArrayList(Atom), lex_names: *const std.ArrayList(Atom), atom_id: Atom, allocator: std.mem.Allocator) Error!void {
    if (atomListContains(lex_names.items, atom_id)) return Error.UnexpectedToken;
    if (!atomListContains(var_names.items, atom_id)) try var_names.append(allocator, atom_id);
}

fn scanSwitchDeclarationName(
    s: *ParseState,
    lex_names: *std.ArrayList(Atom),
    function_names: *std.ArrayList(Atom),
    var_names: *std.ArrayList(Atom),
    kind: enum { lexical, function, var_decl },
) Error!void {
    var effective_kind = kind;
    if (s.peekKind() == '*') {
        try s.advance();
        if (kind == .function) effective_kind = .lexical;
    }
    if (s.peekKind() != tok.TOK_IDENT) return;
    const atom_id = s.token.payload.ident.atom;
    switch (effective_kind) {
        .lexical => try appendSwitchLexName(lex_names, var_names, atom_id, s.lex.allocator),
        .function => try appendSwitchFunctionName(s, lex_names, function_names, var_names, atom_id),
        .var_decl => try appendSwitchVarName(var_names, lex_names, atom_id, s.lex.allocator),
    }
}

fn validateSwitchCaseBlockDeclarations(s: *ParseState) Error!void {
    const snapshot = takeParserSnapshot(s);
    defer restoreParserLexerSnapshot(s, snapshot);

    var lex_names: std.ArrayList(Atom) = .empty;
    defer lex_names.deinit(s.lex.allocator);
    var function_names: std.ArrayList(Atom) = .empty;
    defer function_names.deinit(s.lex.allocator);
    var var_names: std.ArrayList(Atom) = .empty;
    defer var_names.deinit(s.lex.allocator);

    var brace_depth: usize = 0;
    var previous_token_kind: ?tok.TokenKind = null;
    while (s.peekKind() != tok.TOK_EOF) {
        const kind = s.peekKind();
        if (kind == @as(tok.TokenKind, @intCast('}'))) {
            if (brace_depth == 0) return;
            brace_depth -= 1;
            previous_token_kind = kind;
            try s.advance();
            continue;
        }
        if (kind == @as(tok.TokenKind, @intCast('{'))) {
            brace_depth += 1;
            previous_token_kind = kind;
            try s.advance();
            continue;
        }
        if (brace_depth != 0) {
            if (kind == tok.TOK_TEMPLATE) {
                try skipTemplateInPredeclareScan(s, s.token);
                previous_token_kind = tok.TOK_TEMPLATE;
                try s.advance();
                continue;
            }
            if (tokenCanStartSlashRegexp(kind)) {
                if (try skipRegexpInPredeclareScan(s, previous_token_kind)) {
                    previous_token_kind = tok.TOK_REGEXP;
                    try s.advance();
                    continue;
                }
                previous_token_kind = kind;
                try s.advance();
                continue;
            }
            previous_token_kind = kind;
            try s.advance();
            continue;
        }

        if (kind == tok.TOK_IF and try skipAnnexBIfFunctionDeclarationsInScan(s)) continue;

        switch (kind) {
            tok.TOK_LET, tok.TOK_CONST => {
                previous_token_kind = kind;
                try s.advance();
                try scanSwitchDeclarationName(s, &lex_names, &function_names, &var_names, .lexical);
            },
            tok.TOK_VAR => {
                previous_token_kind = kind;
                try s.advance();
                try scanSwitchDeclarationName(s, &lex_names, &function_names, &var_names, .var_decl);
            },
            tok.TOK_CLASS => {
                previous_token_kind = kind;
                try s.advance();
                try scanSwitchDeclarationName(s, &lex_names, &function_names, &var_names, .lexical);
            },
            tok.TOK_FUNCTION => {
                previous_token_kind = kind;
                try s.advance();
                try scanSwitchDeclarationName(s, &lex_names, &function_names, &var_names, .function);
            },
            tok.TOK_IDENT => {
                if (s.isIdent("async") and s.peekNextKindNoLineTerminator(tok.TOK_FUNCTION)) {
                    previous_token_kind = tok.TOK_FUNCTION;
                    try s.advance();
                    try s.advance();
                    try scanSwitchDeclarationName(s, &lex_names, &function_names, &var_names, .lexical);
                } else {
                    previous_token_kind = kind;
                    try s.advance();
                }
            },
            tok.TOK_TEMPLATE => {
                try skipTemplateInPredeclareScan(s, s.token);
                previous_token_kind = tok.TOK_TEMPLATE;
                try s.advance();
            },
            '/', tok.TOK_DIV_ASSIGN => {
                if (try skipRegexpInPredeclareScan(s, previous_token_kind)) {
                    previous_token_kind = tok.TOK_REGEXP;
                    try s.advance();
                    continue;
                }
                previous_token_kind = kind;
                try s.advance();
            },
            else => {
                previous_token_kind = kind;
                try s.advance();
            },
        }
    }
}

/// `put_lvalue` with PUT_LVALUE_KEEP_SECOND semantics — used for
/// postfix update where the OLD value is the expression result. Mirrors
/// `quickjs.c:25470..25530`.
fn emitPutLValueKeepSecond(s: *ParseState, shape: LhsShape) Error!void {
    switch (shape) {
        .var_ref => |v| {
            try s.emitScopePutVar(v.atom);
        },
        .dotted => |d| {
            try s.emitOp(opcode.op.perm3);
            try s.emitOpAtom(opcode.op.put_field, d.atom);
        },
        .indexed => {
            try s.emitOp(opcode.op.perm4);
            try s.emitOp(opcode.op.put_array_el);
        },
        .super_dotted => {
            try s.emitOp(opcode.op.perm5);
            try s.emitOp(opcode.op.put_super_value);
        },
        .with_ref => |w| try emitPutWithRefKeep(s, w.atom, .second),
        .invalid_call, .none => return Error.InvalidAssignmentTarget,
    }
}

const WithRefKeep = enum { top, second, none };

fn emitPutWithRefKeep(s: *ParseState, atom_id: Atom, keep: WithRefKeep) Error!void {
    switch (keep) {
        .top => {
            try s.emitOp(opcode.op.dup);
            try s.emitOp(opcode.op.rot3l);
        },
        .second => try s.emitOp(opcode.op.rot3l),
        .none => try s.emitOp(opcode.op.swap),
    }
    const fallback = try s.emitOpAtomLabelU8(opcode.op.with_put_var, atom_id, 0, 1);
    try s.emitScopePutVar(atom_id);
    try patchAbsoluteTarget(s, fallback);
}

/// Rewrite the trailing `get_field` / `get_array_el` to its `*2` form
/// so the receiver stays on the stack for compound or update lowering.
/// Var-refs need a fresh `get_var` re-emission and are handled by the
/// caller; this helper handles only the depth-1/2 cases.
fn rewriteToGetForm2(s: *ParseState, shape: LhsShape) Error!void {
    const code = s.currentCode();
    switch (shape) {
        .dotted => |d| code[d.code_pos] = opcode.op.get_field2,
        .indexed => |i| {
            try s.truncateCode(i.code_pos);
            try s.emitOp(opcode.op.to_propkey2);
            try s.emitOp(opcode.op.dup2);
            try s.emitOp(opcode.op.get_array_el);
        },
        .super_dotted => |d| {
            try s.truncateCode(d.code_pos);
            try s.emitOp(opcode.op.to_propkey);
            try s.emitOp(opcode.op.dup3);
            try s.emitOp(opcode.op.get_super_value);
        },
        else => {},
    }
}

fn isAssignmentLikeToken(k: tok.TokenKind) bool {
    return k == @as(tok.TokenKind, @intCast('=')) or
        k == tok.TOK_PLUS_ASSIGN or
        k == tok.TOK_MINUS_ASSIGN or
        k == tok.TOK_MUL_ASSIGN or
        k == tok.TOK_DIV_ASSIGN or
        k == tok.TOK_MOD_ASSIGN or
        k == tok.TOK_POW_ASSIGN or
        k == tok.TOK_SHL_ASSIGN or
        k == tok.TOK_SAR_ASSIGN or
        k == tok.TOK_SHR_ASSIGN or
        k == tok.TOK_AND_ASSIGN or
        k == tok.TOK_OR_ASSIGN or
        k == tok.TOK_XOR_ASSIGN or
        k == tok.TOK_LAND_ASSIGN or
        k == tok.TOK_LOR_ASSIGN or
        k == tok.TOK_DOUBLE_QUESTION_MARK_ASSIGN or
        k == tok.TOK_INC or
        k == tok.TOK_DEC;
}

fn tokenStartsPrimaryExpression(k: tok.TokenKind) bool {
    return k == tok.TOK_NUMBER or
        k == tok.TOK_STRING or
        k == tok.TOK_TEMPLATE or
        k == tok.TOK_TRUE or
        k == tok.TOK_FALSE or
        k == tok.TOK_NULL or
        k == tok.TOK_THIS or
        k == tok.TOK_SUPER or
        k == tok.TOK_CLASS or
        k == tok.TOK_FUNCTION or
        k == tok.TOK_IDENT or
        k == tok.TOK_LET or
        k == tok.TOK_YIELD or
        k == @as(tok.TokenKind, @intCast('(')) or
        k == @as(tok.TokenKind, @intCast('[')) or
        k == @as(tok.TokenKind, @intCast('{')) or
        k == @as(tok.TokenKind, @intCast('/')) or
        k == tok.TOK_DIV_ASSIGN;
}

fn tokenStartsYieldExpressionOperand(k: tok.TokenKind) bool {
    return tokenStartsPrimaryExpression(k) and !tokenCanStartSlashRegexp(k);
}

fn tokenCanStartSlashRegexp(k: tok.TokenKind) bool {
    return k == @as(tok.TokenKind, @intCast('/')) or k == tok.TOK_DIV_ASSIGN;
}

fn emitWithGetVarFallback(s: *ParseState, with_atom: Atom, ident: Atom) Error!void {
    try s.emitScopeGetVar(with_atom);
    const label_offset = try s.emitOpAtomLabelU8(opcode.op.with_get_var, ident, 0, 1);
    try s.emitScopeGetVar(ident);
    try patchAbsoluteTarget(s, label_offset);
}

fn emitWithGetRefFallback(s: *ParseState, with_atom: Atom, ident: Atom) Error!void {
    try s.emitScopeGetVar(with_atom);
    const label_offset = try s.emitOpAtomLabelU8(opcode.op.with_get_ref, ident, 0, 1);
    try s.emitOp(opcode.op.undefined);
    try s.emitScopeGetVar(ident);
    try patchAbsoluteTarget(s, label_offset);
}

fn emitWithMakeRefFallback(s: *ParseState, with_atom: Atom, ident: Atom) Error!void {
    try s.emitScopeGetVar(with_atom);
    const found_label = try s.emitOpAtomLabelU8(opcode.op.with_make_ref, ident, 0, 1);
    try s.emitOp(opcode.op.undefined);
    const end = try emitForwardJump(s, opcode.op.goto);
    try patchAbsoluteTarget(s, found_label);
    try s.emitOp(opcode.op.drop);
    try patchForwardJump(s, end);
}

fn emitDestructuringTargetBase(s: *ParseState, ident: Atom) Error!void {
    if (s.active_with_atom) |with_atom| {
        try emitWithGetVarFallback(s, with_atom, ident);
    } else {
        try s.emitScopeGetVar(ident);
    }
}

fn emitDestructuringVarBindingResolution(s: *ParseState, atom_id: Atom) Error!void {
    if (s.destructuring_binding_is_lexical) return;
    const with_atom = s.active_with_atom orelse return;
    try emitWithMakeRefFallback(s, with_atom, atom_id);
    try s.emitOp(opcode.op.drop);
}

fn emitWithDeleteVarFallback(s: *ParseState, with_atom: Atom, ident: Atom) Error!void {
    try s.emitScopeGetVar(with_atom);
    const label_offset = try s.emitOpAtomLabelU8(opcode.op.with_delete_var, ident, 0, 1);
    if (hasEvalNonLexicalBinding(s, ident)) {
        try s.emitOpAtom(opcode.op.delete_var, ident);
    } else if (hasKnownBinding(s, ident) or atomNameEquals(s, ident, "arguments")) {
        try s.emitOp(opcode.op.push_false);
    } else {
        try s.emitOpAtom(opcode.op.delete_var, ident);
    }
    try patchAbsoluteTarget(s, label_offset);
}

/// Emit the return for one pushed-down `return`-expression branch (see
/// `parseCondExpr`), folding a trailing call into a tail call when the
/// branch ends in one. Mirrors the `TOK_RETURN` rewrite conditions.
fn emitReturnExprBranch(s: *ParseState) Error!void {
    const tail_rewrite = if (!s.in_constructor and !s.in_async and !hasActiveIteratorCloses(s))
        rewriteTrailingCallAsTailCall(s)
    else
        TrailingCallRewrite.none;
    if (tail_rewrite != .rewrote) {
        try s.emitOp(if (s.in_async) opcode.op.return_async else opcode.op.@"return");
    }
}

/// `js_parse_cond_expr` (`quickjs.c:27282`). `a ? b : c`.
pub fn parseCondExpr(s: *ParseState, flags: ParseFlags) Error!void {
    const return_cond_depth = s.return_expr_cond_depth;
    const in_return_expr = s.return_expr_mode;
    if (in_return_expr) s.return_expr_cond_depth += 1;
    defer {
        if (in_return_expr) s.return_expr_cond_depth -= 1;
    }

    try parseCoalesceExpr(s, flags);
    if (s.isPunct('?')) {
        try s.advance();
        var then_flags = forceResultNeeded(flags);
        then_flags.in_accepted = true;
        const else_flags = forceResultNeeded(flags);
        // Short-circuit: if false, jump to else branch. The parser emits
        // absolute u32 offsets; `resolve_labels` lowers them to relative
        // goto8/goto16 forms.
        const else_jump_offset = try emitForwardJump(s, opcode.op.if_false);
        if (s.return_expr_mode and return_cond_depth == 0 and !hasActiveIteratorCloses(s)) {
            try parseAssignExprWithoutPendingFunctionName(s, then_flags);
            try emitReturnExprBranch(s);
            try patchForwardJump(s, else_jump_offset);
            try expectPunct(s, ':');
            try parseAssignExprWithoutPendingFunctionName(s, else_flags);
            try emitReturnExprBranch(s);
            s.return_expr_emitted_return = true;
            s.last_anonymous_function_expr = false;
            s.last_was_direct_eval_callee = false;
            s.last_expr_was_short_circuit_or_cond = true;
            return;
        }
        try parseAssignExprWithoutPendingFunctionName(s, then_flags);
        const end_jump_offset = try emitForwardJump(s, opcode.op.goto);
        try patchForwardJump(s, else_jump_offset);
        try expectPunct(s, ':');
        try parseAssignExprWithoutPendingFunctionName(s, else_flags);
        try patchForwardJump(s, end_jump_offset);
        s.last_anonymous_function_expr = false;
        s.last_was_direct_eval_callee = false;
        s.last_expr_was_short_circuit_or_cond = true;
    }
}

/// `js_parse_coalesce_expr` (`quickjs.c:27254`). `a ?? b`.
pub fn parseCoalesceExpr(s: *ParseState, flags: ParseFlags) Error!void {
    try parseLogicalAndOr(s, tok.TOK_LOR, flags);
    if (s.peekKind() == tok.TOK_DOUBLE_QUESTION_MARK) {
        s.last_coalesce_expr_depth = s.assign_expr_depth;
        var end_jumps: std.ArrayList(usize) = .empty;
        defer end_jumps.deinit(s.lex.allocator);
        const rhs_flags = forceResultNeeded(flags);

        while (s.peekKind() == tok.TOK_DOUBLE_QUESTION_MARK) {
            try s.advance();
            // Short-circuit on non-nullish: `a ?? b` keeps a if not
            // null/undefined, else evaluates b. All successful
            // non-nullish tests jump to the common end label, matching
            // QuickJS's single-label lowering for chained `??`.
            try s.emitOp(opcode.op.dup);
            try s.emitOp(opcode.op.is_undefined_or_null);
            const skip_jump = try emitForwardJump(s, opcode.op.if_false);
            try end_jumps.append(s.lex.allocator, skip_jump);
            try s.emitOp(opcode.op.drop);
            try parseExprBinaryWithoutPendingFunctionName(s, 8, rhs_flags);
        }
        for (end_jumps.items) |skip_jump| {
            try patchForwardJump(s, skip_jump);
        }
        s.last_anonymous_function_expr = false;
        s.last_was_direct_eval_callee = false;
        s.last_expr_was_short_circuit_or_cond = true;
    }
}

/// `js_parse_logical_and_or` (`quickjs.c:27213`). `a && b` / `a || b`.
pub fn parseLogicalAndOr(s: *ParseState, op_kind: tok.TokenKind, flags: ParseFlags) Error!void {
    if (op_kind == tok.TOK_LOR) {
        try parseLogicalAndOr(s, tok.TOK_LAND, flags);
        var saw_short_circuit = false;
        while (s.peekKind() == tok.TOK_LOR) {
            saw_short_circuit = true;
            try s.advance();
            // `a || b` → `dup ; if_true L_skip ; drop ; <b> ; L_skip:`
            try s.emitOp(opcode.op.dup);
            const skip_jump = try emitForwardJump(s, opcode.op.if_true);
            try s.emitOp(opcode.op.drop);
            try parseLogicalAndOrWithoutPendingFunctionName(s, tok.TOK_LAND, forceResultNeeded(flags));
            try patchForwardJump(s, skip_jump);
            s.last_anonymous_function_expr = false;
            s.last_was_direct_eval_callee = false;
            if (s.peekKind() != tok.TOK_LOR and s.peekKind() == tok.TOK_DOUBLE_QUESTION_MARK) {
                return Error.UnexpectedToken;
            }
        }
        if (saw_short_circuit) s.last_expr_was_short_circuit_or_cond = true;
    } else {
        try parseExprBinary(s, 8, flags);
        var saw_short_circuit = false;
        while (s.peekKind() == tok.TOK_LAND) {
            saw_short_circuit = true;
            try s.advance();
            // `a && b` → `dup ; if_false L_skip ; drop ; <b> ; L_skip:`
            try s.emitOp(opcode.op.dup);
            const skip_jump = try emitForwardJump(s, opcode.op.if_false);
            try s.emitOp(opcode.op.drop);
            try parseExprBinaryWithoutPendingFunctionName(s, 8, forceResultNeeded(flags));
            try patchForwardJump(s, skip_jump);
            s.last_anonymous_function_expr = false;
            s.last_was_direct_eval_callee = false;
            if (s.peekKind() != tok.TOK_LAND and s.peekKind() == tok.TOK_DOUBLE_QUESTION_MARK) {
                return Error.UnexpectedToken;
            }
        }
        if (saw_short_circuit) s.last_expr_was_short_circuit_or_cond = true;
    }
}

/// `js_parse_expr_binary` (`quickjs.c:27049`). Pratt-style with hand
/// rolled level table. Levels 1..8 covered (private-name `in` deferred).
pub fn parseExprBinary(s: *ParseState, level: u8, flags: ParseFlags) Error!void {
    if (level == 0) {
        return parseUnary(s, ParseFlags{
            .in_accepted = flags.in_accepted,
            .pow_allowed = true,
            .result_needed = flags.result_needed,
            .yield_forbidden = flags.yield_forbidden,
        });
    }
    if (level == 4 and flags.in_accepted and s.peekKind() == tok.TOK_PRIVATE_NAME and s.peekNextKind() == tok.TOK_IN) {
        s.features.insert(.private_name);
        const private_atom = findClassPrivateBoundName(s, s.token.payload.ident.atom, 0) orelse return Error.UnexpectedToken;
        const retained_private_atom = s.function.atoms.dup(private_atom);
        defer s.function.atoms.free(retained_private_atom);
        try s.advance();
        try s.expectToken(tok.TOK_IN);
        if (checkArrowHead(s) or
            checkIdentArrowHead(s) or
            checkAsyncSingleParamArrowHead(s) or
            checkAsyncParenArrowHead(s))
        {
            return Error.UnexpectedToken;
        }
        try parseExprBinary(s, level - 1, flags);
        try s.emitOpAtom(opcode.op.private_symbol, retained_private_atom);
        try s.emitOp(opcode.op.private_in);
        return;
    }
    try parseExprBinary(s, level - 1, flags);
    while (true) {
        const op_byte = matchBinaryOp(s.peekKind(), level, flags) orelse return;
        try s.advance();
        if (s.in_generator and s.peekKind() == tok.TOK_YIELD) return Error.UnexpectedToken;
        try parseExprBinaryWithoutPendingFunctionName(s, level - 1, flags);
        try s.emitOp(op_byte);
        s.last_anonymous_function_expr = false;
        s.last_was_direct_eval_callee = false;
    }
}

fn parseAssignExprWithoutPendingFunctionName(s: *ParseState, flags: ParseFlags) Error!void {
    const saved_name = s.pending_function_name;
    const saved_decl = s.pending_function_is_decl;
    s.pending_function_name = null;
    s.pending_function_is_decl = false;
    defer {
        s.pending_function_name = saved_name;
        s.pending_function_is_decl = saved_decl;
    }
    try parseAssignExpr2(s, flags);
}

fn parseLogicalAndOrWithoutPendingFunctionName(s: *ParseState, op_kind: tok.TokenKind, flags: ParseFlags) Error!void {
    const saved_name = s.pending_function_name;
    const saved_decl = s.pending_function_is_decl;
    s.pending_function_name = null;
    s.pending_function_is_decl = false;
    defer {
        s.pending_function_name = saved_name;
        s.pending_function_is_decl = saved_decl;
    }
    try parseLogicalAndOr(s, op_kind, flags);
}

fn parseExprBinaryWithoutPendingFunctionName(s: *ParseState, level: u8, flags: ParseFlags) Error!void {
    const saved_name = s.pending_function_name;
    const saved_decl = s.pending_function_is_decl;
    s.pending_function_name = null;
    s.pending_function_is_decl = false;
    defer {
        s.pending_function_name = saved_name;
        s.pending_function_is_decl = saved_decl;
    }
    try parseExprBinary(s, level, flags);
}

/// `js_parse_unary` (`quickjs.c:26922`). Covers prefix `+`, `-`, `~`,
/// `!`, `void`, `typeof`, `delete`, prefix `++`/`--`, right-associative
/// `**`, contextual `yield`, and contextual `await`.
pub fn parseUnary(s: *ParseState, flags: ParseFlags) Error!void {
    const k = s.peekKind();
    if (k == @as(tok.TokenKind, @intCast('+'))) {
        try s.advance();
        try parseUnary(s, .{ .pow_allowed = false, .in_accepted = flags.in_accepted, .yield_forbidden = true });
        try s.emitOp(opcode.op.plus);
        return;
    }
    if (k == @as(tok.TokenKind, @intCast('-'))) {
        try s.advance();
        if (s.cur_func().use_short_opcodes and s.peekKind() == tok.TOK_NUMBER) {
            if (s.token.payload.num.is_bigint) {
                if (parseBigIntI32(s.token.payload.num.bigint_text, true)) |small| {
                    try s.emitOpI32(opcode.op.push_bigint_i32, small);
                    try s.advance();
                    return;
                }
            }
            const value = s.token.payload.num.value;
            if (value != 0 and numberIsExactI32(value)) {
                try s.emitOpI32(opcode.op.push_i32, -@as(i32, @intFromFloat(value)));
                try s.advance();
                return;
            }
        }
        try parseUnary(s, .{ .pow_allowed = false, .in_accepted = flags.in_accepted, .yield_forbidden = true });
        try s.emitOp(opcode.op.neg);
        return;
    }
    if (k == @as(tok.TokenKind, @intCast('~'))) {
        try s.advance();
        try parseUnary(s, .{ .pow_allowed = false, .in_accepted = flags.in_accepted, .yield_forbidden = true });
        try s.emitOp(opcode.op.not);
        return;
    }
    if (k == @as(tok.TokenKind, @intCast('!'))) {
        try s.advance();
        try parseUnary(s, .{ .pow_allowed = false, .in_accepted = flags.in_accepted, .yield_forbidden = true });
        try s.emitOp(opcode.op.lnot);
        return;
    }
    if (k == tok.TOK_VOID) {
        try s.advance();
        try parseUnary(s, .{ .pow_allowed = false, .in_accepted = flags.in_accepted, .yield_forbidden = true });
        try s.emitOpNoSource(opcode.op.drop);
        try s.emitOpNoSource(opcode.op.undefined);
        return;
    }
    if (k == tok.TOK_TYPEOF) {
        try s.advance();
        // typeof on a missing global returns "undefined", not a
        // ReferenceError. QuickJS uses `get_var_undef` for that.
        if (peekParenthesizedBareIdent(s)) |ident| {
            if (s.class_field_initializer_depth > 0 and atomNameEquals(s, ident, "arguments")) {
                return Error.UnexpectedToken;
            }
            try s.advance(); // (
            try s.advance(); // ident
            try expectPunct(s, ')');
            if (hasKnownBinding(s, ident)) {
                try s.emitScopeGetVar(ident);
            } else {
                try s.emitScopeGetVarUndef(ident);
            }
        } else if (isIdentifierLikeToken(s) and
            s.peekNextKind() != @as(tok.TokenKind, @intCast('(')) and
            s.peekNextKind() != @as(tok.TokenKind, @intCast('.')) and
            s.peekNextKind() != @as(tok.TokenKind, @intCast('[')) and
            s.peekNextKind() != tok.TOK_QUESTION_MARK_DOT)
        {
            const ident = identifierLikeAtom(s);
            if (s.class_field_initializer_depth > 0 and atomNameEquals(s, ident, "arguments")) {
                return Error.UnexpectedToken;
            }
            try s.advance();
            if (hasKnownBinding(s, ident)) {
                try s.emitScopeGetVar(ident);
            } else {
                try s.emitScopeGetVarUndef(ident);
            }
        } else {
            try parseUnary(s, .{ .pow_allowed = false, .in_accepted = flags.in_accepted, .yield_forbidden = true });
        }
        try s.emitOp(opcode.op.typeof);
        return;
    }
    if (k == tok.TOK_DELETE) {
        try s.advance();
        if (peekParenthesizedBareIdent(s)) |ident| {
            try s.advance(); // (
            try s.advance(); // ident
            try expectPunct(s, ')');
            if (s.is_strict or s.cur_func().is_strict_mode) return Error.UnexpectedToken;
            if (s.active_with_atom) |with_atom| {
                try emitWithDeleteVarFallback(s, with_atom, ident);
            } else if (hasEvalNonLexicalBinding(s, ident)) {
                try s.emitOpAtom(opcode.op.delete_var, ident);
            } else if (hasKnownBinding(s, ident) or atomNameEquals(s, ident, "arguments")) {
                try s.emitOp(opcode.op.push_false);
            } else {
                try s.emitOpAtom(opcode.op.delete_var, ident);
            }
            return;
        }
        if (s.active_with_atom) |with_atom| {
            if (s.peekKind() == tok.TOK_IDENT and
                s.peekNextKind() != @as(tok.TokenKind, @intCast('.')) and
                s.peekNextKind() != @as(tok.TokenKind, @intCast('[')))
            {
                const ident = s.token.payload.ident.atom;
                try s.advance();
                try emitWithDeleteVarFallback(s, with_atom, ident);
                return;
            }
        }
        if (s.peekKind() == tok.TOK_SUPER and isDeleteSuperReference(s)) {
            try parseDeleteSuperReference(s, flags);
            return;
        }
        return parseDelete(s, flags);
    }
    if (k == tok.TOK_INC or k == tok.TOK_DEC) {
        const update_op: u8 = if (k == tok.TOK_INC) opcode.op.inc else opcode.op.dec;
        try s.advance();
        const saved_atom: ?Atom = if (peekParenthesizedBareIdent(s)) |ident| blk: {
            break :blk ident;
        } else if (isIdentifierLikeToken(s)) blk: {
            break :blk identifierLikeAtom(s);
        } else null;
        const pre_lhs_code_len = s.currentCodeLen();
        const pre_lhs_atom_len = s.currentAtomOperandLen();
        const saved_force_with_lvalue = s.force_with_lvalue;
        s.force_with_lvalue = true;
        defer s.force_with_lvalue = saved_force_with_lvalue;
        try parseLhsExpr(s, .{ .in_accepted = flags.in_accepted });
        const shape = classifyLhs(s, pre_lhs_code_len, pre_lhs_atom_len, saved_atom);
        if (shape == .none) return Error.InvalidAssignmentTarget;
        if (shape == .invalid_call) {
            if (s.is_strict or s.cur_func().is_strict_mode) return Error.InvalidAssignmentTarget;
            try s.emitOpAtomU8(opcode.op.throw_error, atom_module.null_atom, 2);
            return;
        }
        if ((s.is_strict or s.cur_func().is_strict_mode) and shape == .var_ref) {
            const atom_id = shape.var_ref.atom;
            if (atomNameEquals(s, atom_id, "eval") or atomNameEquals(s, atom_id, "arguments")) {
                return Error.InvalidAssignmentTarget;
            }
        }
        // For member targets, rewrite the speculative read to the
        // QuickJS keep-lvalue shape before applying the update.
        try rewriteToGetForm2(s, shape);
        try s.emitOp(update_op);
        try emitPutLValueKeepTop(s, shape);
        if (flags.pow_allowed and s.peekKind() == tok.TOK_POW) {
            try s.advance();
            try parseUnary(s, ParseFlags{ .in_accepted = flags.in_accepted, .pow_allowed = true });
            try s.emitOp(opcode.op.pow);
        }
        return;
    }
    // Handle yield expressions in generator functions.
    if (s.in_class_static_block and (k == tok.TOK_AWAIT or k == tok.TOK_YIELD)) {
        return Error.UnexpectedToken;
    }
    if (k == tok.TOK_YIELD) {
        if (flags.yield_forbidden) return Error.UnexpectedToken;
        if (s.in_parameter_initializer and s.in_generator) return Error.UnexpectedToken;
        if (!s.in_generator) {
            if (s.is_strict or s.cur_func().is_strict_mode) return Error.YieldOutsideGenerator;
            var next_has_line_terminator = false;
            const next_kind = s.peekNextKindWithLineTerminator(&next_has_line_terminator);
            if (!next_has_line_terminator and
                next_kind != @as(tok.TokenKind, @intCast('(')) and
                next_kind != @as(tok.TokenKind, @intCast('[')) and
                next_kind != tok.TOK_TEMPLATE and
                tokenStartsYieldExpressionOperand(next_kind))
            {
                return Error.YieldOutsideGenerator;
            }
            return parsePostfixExpr(s, flags);
        }
        try s.advance();
        // Check for yield*. A line terminator after `yield` ends the
        // YieldExpression before any following operand.
        const has_line_terminator = s.lex.got_lf;
        if (has_line_terminator and s.peekKind() == '*') return Error.UnexpectedToken;
        const is_yield_star = !has_line_terminator and s.peekKind() == '*';
        if (is_yield_star) {
            try s.advance();
            try parseAssignExpr2(s, ParseFlags{ .in_accepted = flags.in_accepted });
            try emitYieldStarDelegation(s, s.in_async);
        } else {
            // Check if there's an expression after yield
            // yield without an expression is equivalent to yield undefined
            if (has_line_terminator or
                s.peekKind() == @as(tok.TokenKind, @intCast(';')) or
                s.peekKind() == @as(tok.TokenKind, @intCast(',')) or
                s.peekKind() == @as(tok.TokenKind, @intCast(':')) or
                s.peekKind() == @as(tok.TokenKind, @intCast('}')) or
                s.peekKind() == @as(tok.TokenKind, @intCast(']')) or
                s.peekKind() == @as(tok.TokenKind, @intCast(')')) or
                s.peekKind() == tok.TOK_EOF)
            {
                // yield without expression
                try s.emitOp(opcode.op.undefined);
            } else {
                // yield with expression
                try parseAssignExpr2(s, ParseFlags{ .in_accepted = flags.in_accepted });
            }
            try s.emitOp(opcode.op.yield);
            const normal_resume = try emitForwardJump(s, opcode.op.if_false);
            try s.emitOp(opcode.op.return_async);
            try patchForwardJump(s, normal_resume);
        }
        return;
    }
    // Handle await expressions in async functions.
    if (k == tok.TOK_AWAIT) {
        const top_level_module_await = s.lex.is_module and s.cur_func_stack.len == 0;
        if (!s.in_async and !top_level_module_await) {
            const next_kind = s.peekNextKind();
            if (canUseAwaitAsIdentifier(s) and
                (!tokenCanStartExpression(next_kind) or
                    next_kind == @as(tok.TokenKind, @intCast('(')) or
                    next_kind == @as(tok.TokenKind, @intCast('.')) or
                    next_kind == @as(tok.TokenKind, @intCast('[')) or
                    next_kind == tok.TOK_INC or
                    next_kind == tok.TOK_DEC))
            {
                try parsePostfixExpr(s, flags);
                return;
            }
            return Error.AwaitOutsideAsyncFunction;
        }
        if (top_level_module_await) s.function.ensureModule().has_top_level_await = true;
        try s.advance();
        // Parse the awaited expression
        try parseAssignExpr(s);
        try s.emitOp(opcode.op.await);
        return;
    }
    try parsePostfixExpr(s, flags);
    // PF_POW_ALLOWED: `a ** b` is right-associative and only allowed
    // when no unary prefix was consumed.
    if (flags.pow_allowed and s.peekKind() == tok.TOK_POW) {
        try s.advance();
        try parseUnary(s, ParseFlags{ .in_accepted = flags.in_accepted, .pow_allowed = true });
        try s.emitOp(opcode.op.pow);
    }
}

fn emitYieldStarDelegation(s: *ParseState, is_async: bool) Error!void {
    const done_atom = atom_module.predefinedId("done", .string) orelse return Error.UnexpectedToken;
    const value_atom = atom_module.predefinedId("value", .string) orelse return Error.UnexpectedToken;

    try s.emitOp(if (is_async) opcode.op.for_await_of_start else opcode.op.for_of_start);
    try s.emitOp(opcode.op.drop);
    try s.emitOp(opcode.op.undefined);
    try s.emitOp(opcode.op.undefined);

    const loop_pc: u32 = @intCast(s.currentCodeLen());
    try s.emitOp(opcode.op.iterator_next);
    if (is_async) try s.emitOp(opcode.op.await);
    try s.emitOp(opcode.op.iterator_check_object);
    try s.emitOpAtom(opcode.op.get_field2, done_atom);
    const label_next = try emitForwardJump(s, opcode.op.if_true);

    const yield_pc: u32 = @intCast(s.currentCodeLen());
    if (is_async) {
        try s.emitOpAtom(opcode.op.get_field, value_atom);
        try s.emitOp(opcode.op.async_yield_star);
    } else {
        try s.emitOp(opcode.op.yield_star);
    }
    try s.emitOp(opcode.op.dup);
    const label_return = try emitForwardJump(s, opcode.op.if_true);
    try s.emitOp(opcode.op.drop);
    try emitBackwardJump(s, opcode.op.goto, loop_pc);

    try patchForwardJump(s, label_return);
    try s.emitOpI32(opcode.op.push_i32, 2);
    try s.emitOp(opcode.op.strict_eq);
    const label_throw = try emitForwardJump(s, opcode.op.if_true);

    if (is_async) try s.emitOp(opcode.op.await);
    try s.emitOpU8(opcode.op.iterator_call, 0);
    const label_return1 = try emitForwardJump(s, opcode.op.if_true);
    if (is_async) try s.emitOp(opcode.op.await);
    try s.emitOp(opcode.op.iterator_check_object);
    try s.emitOpAtom(opcode.op.get_field2, done_atom);
    try emitBackwardJump(s, opcode.op.if_false, yield_pc);

    try s.emitOpAtom(opcode.op.get_field, value_atom);

    try patchForwardJump(s, label_return1);
    try s.emitOp(opcode.op.nip);
    try s.emitOp(opcode.op.nip);
    try s.emitOp(opcode.op.nip);
    if (is_async) try s.emitOp(opcode.op.await);
    if (!try emitStackTopReturnThroughFinally(s)) {
        try s.emitOp(opcode.op.return_async);
    }

    try patchForwardJump(s, label_throw);
    try s.emitOpU8(opcode.op.iterator_call, 1);
    const label_throw1 = try emitForwardJump(s, opcode.op.if_true);
    if (is_async) try s.emitOp(opcode.op.await);
    try s.emitOp(opcode.op.iterator_check_object);
    try s.emitOpAtom(opcode.op.get_field2, done_atom);
    try emitBackwardJump(s, opcode.op.if_false, yield_pc);
    const goto_next = try emitForwardJump(s, opcode.op.goto);

    try patchForwardJump(s, label_throw1);
    try s.emitOpU8(opcode.op.iterator_call, 2);
    const label_throw2 = try emitForwardJump(s, opcode.op.if_true);
    if (is_async) try s.emitOp(opcode.op.await);
    try patchForwardJump(s, label_throw2);
    try s.emitOpAtomU8(opcode.op.throw_error, atom_module.null_atom, 4);

    try patchForwardJump(s, label_next);
    try patchForwardJump(s, goto_next);
    try s.emitOpAtom(opcode.op.get_field, value_atom);
    try s.emitOp(opcode.op.nip);
    try s.emitOp(opcode.op.nip);
    try s.emitOp(opcode.op.nip);
}

fn emitStackTopReturnThroughFinally(s: *ParseState) Error!bool {
    const frame_index = nearestReturnFinallyFrameForReturn(s, null) orelse return false;
    try emitStackTopReturnThroughFinallyFrame(s, frame_index, shouldDropPendingAbruptForCapture(s, frame_index));
    return true;
}

fn emitStackTopReturnThroughFinallyFrame(s: *ParseState, frame_index: usize, drop_pending_abrupt: bool) Error!void {
    const value_loc = s.return_finally_frames.items[frame_index].value_loc;
    const catch_marker_depth = s.return_finally_frames.items[frame_index].catch_marker_depth;
    try s.emitOpU16(opcode.op.put_loc, value_loc);
    try emitCatchMarkerDropsToDepth(s, catch_marker_depth);
    if (drop_pending_abrupt) try emitPendingAbruptDropsForReturn(s);
    const off = try emitForwardJump(s, opcode.op.goto);
    try s.return_finally_frames.items[frame_index].fixups.append(s.function.memory.allocator, off);
}

fn peekParenthesizedBareIdent(s: *ParseState) ?Atom {
    if (s.peekKind() != @as(tok.TokenKind, @intCast('('))) return null;

    const saved_pos = s.lex.pos;
    const saved_line = s.lex.line;
    const saved_col = s.lex.col;
    const saved_got_lf = s.lex.got_lf;
    const saved_mark_pos = s.lex.mark_pos;
    const saved_mark_line = s.lex.mark_line;
    const saved_mark_col = s.lex.mark_col;
    const saved_token = s.token;
    var advanced = false;
    defer {
        if (advanced) s.lex.freeToken(&s.token);
        s.lex.pos = saved_pos;
        s.lex.line = saved_line;
        s.lex.col = saved_col;
        s.lex.got_lf = saved_got_lf;
        s.lex.mark_pos = saved_mark_pos;
        s.lex.mark_line = saved_mark_line;
        s.lex.mark_col = saved_mark_col;
        s.token = saved_token;
    }

    var paren_count: usize = 0;
    while (s.peekKind() == @as(tok.TokenKind, @intCast('('))) {
        s.advance() catch return null;
        advanced = true;
        paren_count += 1;
    }
    if (s.peekKind() != tok.TOK_IDENT) return null;
    const ident = s.token.payload.ident.atom;
    s.advance() catch return null; // ident
    advanced = true;
    var close_count: usize = 0;
    while (close_count < paren_count) : (close_count += 1) {
        if (s.peekKind() != @as(tok.TokenKind, @intCast(')'))) return null;
        s.advance() catch return null;
        advanced = true;
    }
    if (isMemberStart(s.peekKind())) return null;
    return ident;
}

fn isDeleteSuperReference(s: *ParseState) bool {
    if (s.peekKind() != tok.TOK_SUPER) return false;
    const next = s.peekNextKind();
    return next == @as(tok.TokenKind, @intCast('.')) or next == @as(tok.TokenKind, @intCast('['));
}

fn parseDeleteSuperReference(s: *ParseState, flags: ParseFlags) Error!void {
    try s.advance(); // super
    if (s.peekKind() == @as(tok.TokenKind, @intCast('.'))) {
        try s.advance();
        const name = if (s.peekKind() == tok.TOK_IDENT)
            s.token.payload.ident.atom
        else if (tok.isKeyword(s.peekKind()))
            tok.keywordAtom(s.peekKind())
        else if (s.peekKind() == tok.TOK_DELETE)
            @as(Atom, 9)
        else if (s.peekKind() == tok.TOK_CATCH)
            @as(Atom, 25)
        else
            return Error.UnexpectedToken;
        try s.advance();
        if (s.peekKind() == @as(tok.TokenKind, @intCast('('))) {
            try s.emitOp(opcode.op.get_super);
            try s.emitOpAtom(opcode.op.push_atom_value, name);
            try s.emitOp(opcode.op.get_super_value);
            const shape = try parseCallArgs(s, flags);
            switch (shape) {
                .direct => |argc| try s.emitOpU16(opcode.op.call, argc),
                .applied => try s.emitOpU16(opcode.op.apply, 0),
            }
            try s.emitOp(opcode.op.drop);
            try s.emitOp(opcode.op.push_true);
            return;
        }
    } else if (s.peekKind() == @as(tok.TokenKind, @intCast('['))) {
        try s.advance();
        try s.emitOp(opcode.op.push_this);
        try s.emitOp(opcode.op.drop);
        try parseExpr(s);
        try expectPunct(s, ']');
    } else {
        return Error.UnexpectedToken;
    }
    try emitDeleteSuperError(s);
}

fn emitDeleteSuperError(s: *ParseState) Error!void {
    try s.emitOpAtomU8(opcode.op.throw_error, atom_module.null_atom, 3);
}

fn endsWithGetSuperValue(code: []const u8, min_pos: usize) bool {
    return code.len > min_pos and code[code.len - 1] == opcode.op.get_super_value;
}

/// `js_parse_delete` (`quickjs.c:26829`). Generic implementation: parse
/// a unary-style operand normally, then classify the trailing emission
/// and rewrite it into a delete shape:
///
///   * `var_ref a`     → truncate `get_var a` ; emit `delete_var a`
///   * `dotted obj.b`  → in-place rewrite trailing `get_field b` to
///                       `push_atom_value b` (same byte length); emit
///                       `delete`
///   * `indexed a[i]`  → truncate trailing `get_array_el` (1 byte);
///                       emit `delete`
///   * `none`          → operand is not a reference; per spec return
///                       `true` after evaluating the operand for side
///                       effects: emit `drop ; push_true`
///
/// This handles arbitrary chain depths (`delete a.b.c`,
/// `delete a.b[i]`, etc.) because the rewrite touches only the final
/// access. Optional-chain `delete a?.b` / `delete super.x` /
/// `delete #priv` are deferred.
fn parseDelete(s: *ParseState, flags: ParseFlags) Error!void {
    const saved_atom: ?Atom = if (peekParenthesizedBareIdent(s)) |ident| blk: {
        break :blk ident;
    } else if (s.peekKind() == tok.TOK_IDENT) blk: {
        break :blk s.token.payload.ident.atom;
    } else if (s.peekKind() == tok.TOK_YIELD and !s.in_generator and !(s.is_strict or s.cur_func().is_strict_mode)) blk: {
        break :blk tok.keywordAtom(tok.TOK_YIELD);
    } else null;
    const pre_lhs_code_len = s.currentCodeLen();
    const pre_lhs_atom_len = s.currentAtomOperandLen();
    try parseUnary(s, .{ .pow_allowed = false, .in_accepted = flags.in_accepted });
    const shape = classifyLhs(s, pre_lhs_code_len, pre_lhs_atom_len, saved_atom);
    if (lhsShapeIsPrivateReference(s, shape)) return Error.UnexpectedToken;
    const code_after_lhs = s.currentCode();
    if (shape == .none and code_after_lhs.len > pre_lhs_code_len and code_after_lhs[code_after_lhs.len - 1] == opcode.op.get_length) {
        try s.truncateCode(code_after_lhs.len - 1);
        try s.emitOpAtom(opcode.op.push_atom_value, atom_module.ids.length);
        try s.emitOp(opcode.op.delete);
        return;
    }
    if (shape == .none and saved_atom != null and atomNameEquals(s, saved_atom.?, "arguments") and !hasCurrentFunctionBinding(s, saved_atom.?)) {
        try s.truncateCode(pre_lhs_code_len);
        try s.truncateAtomOperands(pre_lhs_atom_len);
        try s.emitOp(opcode.op.push_false);
        return;
    }
    if (endsWithGetSuperValue(code_after_lhs, pre_lhs_code_len)) {
        try s.truncateCode(pre_lhs_code_len);
        try s.truncateAtomOperands(pre_lhs_atom_len);
        try emitDeleteSuperError(s);
        return;
    }
    if (shape == .indexed and code_after_lhs.len > pre_lhs_code_len and code_after_lhs[pre_lhs_code_len] == opcode.op.get_super) {
        try s.truncateCode(code_after_lhs.len - 1);
        try emitDeleteSuperError(s);
        return;
    }
    switch (shape) {
        .var_ref => |v| {
            if (s.is_strict or s.cur_func().is_strict_mode) return Error.UnexpectedToken;
            try s.truncateCode(v.code_pos);
            try s.truncateAtomOperands(pre_lhs_atom_len);
            if (hasEvalNonLexicalBinding(s, v.atom)) {
                try s.emitOpAtom(opcode.op.delete_var, v.atom);
            } else if (hasKnownBinding(s, v.atom) or atomNameEquals(s, v.atom, "arguments")) {
                try s.emitOp(opcode.op.push_false);
            } else {
                try s.emitOpAtom(opcode.op.delete_var, v.atom);
            }
        },
        .dotted => |d| {
            // Same byte width (atom format = opcode + atom4); just flip
            // the opcode byte. The atom is already retained from the
            // original `get_field` emission, and `push_atom_value` also
            // takes the atom as its operand, so refcount stays balanced.
            var code = s.currentCode();
            code[d.code_pos] = opcode.op.push_atom_value;
            try s.emitOp(opcode.op.delete);
        },
        .super_dotted => {
            try s.truncateCode(pre_lhs_code_len);
            try s.truncateAtomOperands(pre_lhs_atom_len);
            try emitDeleteSuperError(s);
        },
        .indexed => |i| {
            try s.truncateCode(i.code_pos);
            try s.emitOp(opcode.op.delete);
        },
        .with_ref => |w| {
            try s.truncateCode(pre_lhs_code_len);
            try s.truncateAtomOperands(pre_lhs_atom_len);
            try emitWithDeleteVarFallback(s, s.active_with_atom orelse return Error.UnexpectedToken, w.atom);
        },
        .invalid_call, .none => {
            try s.emitOp(opcode.op.drop);
            try s.emitOp(opcode.op.push_true);
        },
    }
}

fn lhsShapeIsPrivateReference(s: *ParseState, shape: LhsShape) bool {
    return switch (shape) {
        .dotted => |d| atomNameIsPrivate(s, d.atom),
        .super_dotted => false,
        else => false,
    };
}

fn isMemberStart(k: tok.TokenKind) bool {
    return k == @as(tok.TokenKind, @intCast('.')) or
        k == @as(tok.TokenKind, @intCast('[')) or
        k == @as(tok.TokenKind, @intCast('('));
}

fn optionalCallFollows(s: *ParseState) bool {
    return s.peekKind() == tok.TOK_QUESTION_MARK_DOT and
        s.peekNextKind() == @as(tok.TokenKind, @intCast('('));
}

fn clearShortCircuitOrConditionalTail(s: *ParseState) void {
    s.last_expr_was_short_circuit_or_cond = false;
}

fn rewriteTrailingMemberReferenceForCall(s: *ParseState) Error!bool {
    const should_promote_optional_exit = s.last_lhs_had_optional_chain;
    const code = s.currentCode();
    if (code.len >= 5 and code[code.len - 5] == opcode.op.get_field) {
        code[code.len - 5] = opcode.op.get_field2;
        if (should_promote_optional_exit) try promoteTrailingOptionalChainExitForMethodCall(s);
        return true;
    }
    if (code.len >= 1 and code[code.len - 1] == opcode.op.get_array_el) {
        code[code.len - 1] = opcode.op.get_array_el2;
        if (should_promote_optional_exit) try promoteTrailingOptionalChainExitForMethodCall(s);
        return true;
    }
    return false;
}

fn promoteTrailingOptionalChainExitForMethodCall(s: *ParseState) Error!void {
    var code = s.currentCode();
    const chain_end: u32 = @intCast(code.len);
    var pc: usize = 0;
    var candidate_drop: ?usize = null;
    while (pc + 14 <= code.len) : (pc += 1) {
        if (code[pc] == opcode.op.dup and
            code[pc + 1] == opcode.op.is_undefined_or_null and
            code[pc + 2] == opcode.op.if_false and
            code[pc + 7] == opcode.op.drop and
            code[pc + 8] == opcode.op.undefined and
            code[pc + 9] == opcode.op.goto)
        {
            const target = std.mem.readInt(u32, code[pc + 10 ..][0..4], .little);
            if (target == chain_end) candidate_drop = pc + 7;
        }
    }
    if (candidate_drop) |drop_pc| {
        try insertByteInCurrentCode(s, drop_pc + 2, opcode.op.undefined);
        try adjustJumpTargetsAfterInsert(s, drop_pc + 2, 1);
    }
}

fn insertByteInCurrentCode(s: *ParseState, index: usize, byte: u8) Error!void {
    const old_len = s.currentCodeLen();
    if (index > old_len) return Error.UnexpectedToken;
    try s.appendBytes(&.{byte});
    var code = s.currentCode();
    if (code.len != old_len + 1) return Error.UnexpectedToken;
    std.mem.copyBackwards(u8, code[index + 1 ..], code[index..old_len]);
    code[index] = byte;
}

fn adjustJumpTargetsAfterInsert(s: *ParseState, insert_at: usize, delta: u32) Error!void {
    var code = s.currentCode();
    var pc: usize = 0;
    while (pc < code.len) {
        const op_id = code[pc];
        const size = opcode.sizeOf(op_id);
        if (size == 0 or pc + size > code.len) return Error.UnexpectedToken;
        if (op_id == opcode.op.if_false or
            op_id == opcode.op.if_true or
            op_id == opcode.op.goto or
            op_id == opcode.op.@"catch")
        {
            const target = std.mem.readInt(u32, code[pc + 1 ..][0..4], .little);
            if (target >= insert_at) std.mem.writeInt(u32, code[pc + 1 ..][0..4], target + delta, .little);
        } else if (op_id == opcode.op.with_get_var or
            op_id == opcode.op.with_put_var or
            op_id == opcode.op.with_delete_var or
            op_id == opcode.op.with_make_ref or
            op_id == opcode.op.with_get_ref or
            op_id == opcode.op.with_get_ref_undef)
        {
            const target = std.mem.readInt(u32, code[pc + 5 ..][0..4], .little);
            if (target >= insert_at) std.mem.writeInt(u32, code[pc + 5 ..][0..4], target + delta, .little);
        }
        pc += size;
    }
}

fn emitPlainCallFromStack(s: *ParseState, shape: CallArgsShape) Error!void {
    switch (shape) {
        .direct => |argc| try s.emitOpU16(opcode.op.call, argc),
        .applied => {
            try s.emitOp(opcode.op.undefined);
            try s.emitOp(opcode.op.swap);
            try s.emitOpU16(opcode.op.apply, 0);
        },
    }
}

fn removeForcedSuperLvalueDup(s: *ParseState, pre_lhs_code_len: usize) Error!void {
    var code = s.currentCode();
    if (code.len <= pre_lhs_code_len + 1) return;
    if (code[code.len - 2] != opcode.op.dup2 or code[code.len - 1] != opcode.op.get_super_value) return;
    code[code.len - 2] = code[code.len - 1];
    try s.truncateCode(code.len - 1);
}

/// `js_parse_postfix_expr` (`quickjs.c:26176`). Wraps `parseLhsExpr`
/// with the postfix `++` / `--` update operators.
pub fn parsePostfixExpr(s: *ParseState, flags: ParseFlags) Error!void {
    const saved_atom: ?Atom = if (peekParenthesizedBareIdent(s)) |ident| blk: {
        break :blk ident;
    } else if (s.peekKind() == tok.TOK_IDENT) blk: {
        break :blk s.token.payload.ident.atom;
    } else null;
    const pre_lhs_code_len = s.currentCodeLen();
    const pre_lhs_atom_len = s.currentAtomOperandLen();

    const saved_force_with_lvalue = s.force_with_lvalue;
    const forced_super_lvalue = !s.force_with_lvalue and s.peekKind() == tok.TOK_SUPER;
    s.force_with_lvalue = s.force_with_lvalue or forced_super_lvalue;
    defer s.force_with_lvalue = saved_force_with_lvalue;
    try parseLhsExpr(s, flags);

    const k = s.peekKind();
    if (k != tok.TOK_INC and k != tok.TOK_DEC) {
        if (forced_super_lvalue) try removeForcedSuperLvalueDup(s, pre_lhs_code_len);
        return;
    }
    // ASI: per QuickJS (`quickjs.c:26206`), a postfix `++` / `--` after
    // a LineTerminator is forbidden. The lexer's `got_lf` flag tracks that.
    if (s.lex.got_lf) return;

    const shape = classifyLhs(s, pre_lhs_code_len, pre_lhs_atom_len, saved_atom);
    if (shape == .none) return Error.InvalidAssignmentTarget;
    if (shape == .invalid_call) {
        if (s.is_strict or s.cur_func().is_strict_mode) return Error.InvalidAssignmentTarget;
        try s.advance();
        try s.emitOpAtomU8(opcode.op.throw_error, atom_module.null_atom, 2);
        return;
    }
    if ((s.is_strict or s.cur_func().is_strict_mode) and shape == .var_ref) {
        const atom_id = shape.var_ref.atom;
        if (atomNameEquals(s, atom_id, "eval") or atomNameEquals(s, atom_id, "arguments")) {
            return Error.InvalidAssignmentTarget;
        }
    }
    const keep_postfix_result = flags.result_needed or shape == .var_ref;
    const update_op: u8 = if (keep_postfix_result)
        if (k == tok.TOK_INC) opcode.op.post_inc else opcode.op.post_dec
    else if (k == tok.TOK_INC) opcode.op.inc else opcode.op.dec;
    try s.advance(); // consume `++` or `--`

    // For member targets, rewrite the speculative read to the QuickJS
    // keep-lvalue shape before applying the update.
    try rewriteToGetForm2(s, shape);
    try s.emitOp(update_op);
    if (keep_postfix_result) {
        try emitPutLValueKeepSecond(s, shape);
    } else {
        try emitPutLValueNoKeep(s, shape);
    }
}

/// `js_parse_left_hand_side_expr` (`quickjs.c:24487`). Primary
/// expression followed by zero or more member accesses (`.x`, `[x]`),
/// function calls (`(...)`), and `new` constructions.
///
/// Tracks optional-chain state per call: each `?.` access emits an
/// inline `optional_chain_test` (mirror `quickjs.c:26158`) whose
/// chain-exit `OP_goto` operand is recorded in `chain_exits` and
/// patched to the post-chain byte offset after the member chain
/// finishes. Most chains have ≤4 `?.` accesses so a fixed-size
/// 16-slot buffer is sufficient.
pub fn parseLhsExpr(s: *ParseState, flags: ParseFlags) Error!void {
    s.last_lhs_had_optional_chain = false;
    if (s.peekKind() == tok.TOK_NEW) {
        try parseNewExpr(s, flags);
    } else {
        try parsePrimary(s, flags);
    }
    const primary_was_arrow_function = s.last_primary_was_arrow_function;
    s.last_primary_was_arrow_function = false;
    if (primary_was_arrow_function) {
        s.last_lhs_had_optional_chain = false;
        return;
    }
    const primary_had_optional_chain = s.last_lhs_had_optional_chain;
    const was_super = s.last_was_super;
    var chain_buf: [16]usize = undefined;
    var chain_count: usize = 0;
    try parseMemberChain(s, flags, &chain_buf, &chain_count);
    s.last_lhs_had_optional_chain = primary_had_optional_chain or chain_count > 0;
    if (chain_count > 0) {
        // Patch every chain-exit `OP_goto` operand to the current byte
        // offset so the chain returns `undefined` from the right place.
        const chain_end: u32 = @intCast(s.currentCodeLen());
        for (chain_buf[0..chain_count]) |offset| {
            const code = s.currentCode();
            std.mem.writeInt(u32, code[offset..][0..4], chain_end, .little);
        }
    }
    // Handle super() constructor calls after member chain.
    if (was_super and chain_count == 0 and s.peekKind() == @as(tok.TokenKind, @intCast('('))) {
        if (!s.allow_super_call) return Error.UnexpectedToken;
        const active_func_idx = s.cur_func().this_active_func_var_idx;
        const new_target_idx = s.cur_func().new_target_var_idx;
        const this_idx = s.cur_func().this_var_idx;
        if (active_func_idx < 0 or new_target_idx < 0 or this_idx < 0) {
            try emitCapturedSuperConstructorCall(s, flags, null);
            s.last_was_super = false;
            return;
        }
        const code = s.currentCode();
        if (code.len == 0 or code[code.len - 1] != opcode.op.get_super) return Error.UnexpectedToken;
        try s.truncateCode(code.len - 1);
        try s.emitOp(opcode.op.check_ctor);
        try s.emitOpU16(opcode.op.get_loc, @intCast(active_func_idx));
        try s.emitOp(opcode.op.get_super);
        try s.emitOpU16(opcode.op.get_loc, @intCast(new_target_idx));
        const shape = try parseCallArgs(s, flags);
        switch (shape) {
            .direct => |argc| try s.emitOpU16(opcode.op.call_constructor, argc),
            .applied => try s.emitOpU16(opcode.op.apply, 1),
        }
        try s.emitOp(opcode.op.dup);
        try s.emitOpU16(opcode.op.put_loc_check_init, @intCast(this_idx));
        try s.emitOpU16(opcode.op.get_var_ref_check, 0);
        try s.emitOp(opcode.op.dup);
        try s.emitOpU8(opcode.op.if_false8, 8);
        try s.emitOpU16(opcode.op.get_loc_check, @intCast(this_idx));
        try s.emitOp(opcode.op.swap);
        try s.emitOpU16(opcode.op.call_method, 0);
        try s.emitOp(opcode.op.drop);
        if (s.in_constructor and s.class_has_extends) {
            if (s.current_parameter_properties) |props| {
                for (props.items) |prop_atom| {
                    try s.emitThisValue();
                    try s.emitScopeGetVar(prop_atom);
                    try s.emitOpAtom(opcode.op.put_field, prop_atom);
                }
            }
        }
        s.last_was_super = false;
    }
}

const SourceLoc = struct {
    line: u32,
    col: u32,
};

fn emitCapturedSuperConstructorCall(s: *ParseState, flags: ParseFlags, loc: ?SourceLoc) Error!void {
    const code = s.currentCode();
    if (code.len == 0 or code[code.len - 1] != opcode.op.get_super) return Error.UnexpectedToken;
    try s.truncateCode(code.len - 1);

    try s.emitScopeGetVar(atom_this_active_func);
    try s.emitOp(opcode.op.get_super);
    try s.emitScopeGetVar(atom_new_target);
    const shape = try parseCallArgs(s, flags);
    switch (shape) {
        .direct => |argc| {
            if (loc) |source_loc| {
                try s.emitOpU16At(opcode.op.call_constructor, argc, source_loc.line, source_loc.col);
            } else {
                try s.emitOpU16(opcode.op.call_constructor, argc);
            }
        },
        .applied => {
            if (loc) |source_loc| {
                try s.emitOpU16At(opcode.op.apply, 1, source_loc.line, source_loc.col);
            } else {
                try s.emitOpU16(opcode.op.apply, 1);
            }
        },
    }
    try s.emitOp(opcode.op.dup);
    try s.emitScopePutVarRefCheckInit(atom_this);
    try s.emitScopeGetVar(atom_class_fields_init);
    try s.emitOp(opcode.op.dup);
    try s.emitOpU8(opcode.op.if_false8, 8);
    try s.emitScopeGetVar(atom_this);
    try s.emitOp(opcode.op.swap);
    try s.emitOpU16(opcode.op.call_method, 0);
    try s.emitOp(opcode.op.drop);
    if (s.in_constructor and s.class_has_extends) {
        if (s.current_parameter_properties) |props| {
            for (props.items) |prop_atom| {
                try s.emitScopeGetVar(atom_this);
                try s.emitScopeGetVar(prop_atom);
                try s.emitOpAtom(opcode.op.put_field, prop_atom);
            }
        }
    }
}

fn parseNewExpr(s: *ParseState, flags: ParseFlags) Error!void {
    try s.advance(); // consume 'new'
    if (s.peekKind() == @as(tok.TokenKind, @intCast('.'))) {
        try s.advance();
        if (s.peekKind() != tok.TOK_IDENT or
            s.token.payload.ident.has_escape or
            !atomNameEquals(s, s.token.payload.ident.atom, "target"))
        {
            return Error.UnexpectedToken;
        }
        if (!s.new_target_allowed) return Error.UnexpectedToken;
        try s.advance();
        try s.emitOpU8(opcode.op.special_object, 3);
        return;
    }
    if (s.peekKind() == tok.TOK_NEW) {
        try parseNewExpr(s, flags);
    } else if (s.peekKind() == tok.TOK_IMPORT) {
        if (s.peekNextKind() != @as(tok.TokenKind, @intCast('.'))) return Error.UnexpectedToken;
        try parsePrimary(s, flags);
        if (s.last_primary_was_arrow_function) return Error.UnexpectedToken;
        try parseNewCalleeMemberAccess(s, flags);
    } else {
        try parsePrimary(s, flags);
        if (s.last_primary_was_arrow_function) return Error.UnexpectedToken;
        try parseNewCalleeMemberAccess(s, flags);
    }
    if (s.last_was_with_method_ref) {
        try s.emitOp(opcode.op.nip);
        s.last_was_with_method_ref = false;
    }
    if (s.peekKind() == @as(tok.TokenKind, @intCast('('))) {
        try s.emitOp(opcode.op.dup);
        const callee_line = s.last_token_line_num;
        const callee_col = s.last_token_col_num;
        const shape = try parseCallArgs(s, flags);
        s.last_anonymous_function_expr = false;
        switch (shape) {
            .direct => |argc| try s.emitOpU16At(opcode.op.call_constructor, argc, callee_line, callee_col),
            .applied => {
                // `new X(...args)`. Stack on entry to apply: [func, array].
                // QuickJS rewrites with perm3 to feed apply a dummy `this`
                // (`quickjs.c:26693-26697`); for the plain `new` path we
                // synthesize that `this` slot here.
                try s.emitOp(opcode.op.undefined);
                try s.emitOp(opcode.op.swap);
                try s.emitOpU16At(opcode.op.apply, 1, callee_line, callee_col); // 1 = is_new
            },
        }
    } else {
        // `new X` (no args) is equivalent to `new X()`.
        try s.emitOp(opcode.op.dup);
        try s.emitOpU16At(opcode.op.call_constructor, 0, s.last_token_line_num, s.last_token_col_num);
    }
}

fn parseNewCalleeMemberAccess(s: *ParseState, flags: ParseFlags) Error!void {
    while (true) {
        const k = s.peekKind();
        if (k == @as(tok.TokenKind, @intCast('.'))) {
            try s.advance();
            const name = if (s.peekKind() == tok.TOK_IDENT)
                s.token.payload.ident.atom
            else if (tok.isKeyword(s.peekKind()))
                tok.keywordAtom(s.peekKind())
            else if (s.peekKind() == tok.TOK_DELETE)
                @as(Atom, 9)
            else if (s.peekKind() == tok.TOK_CATCH)
                @as(Atom, 25)
            else
                return Error.UnexpectedToken;
            const retained_name = s.function.atoms.dup(name);
            defer s.function.atoms.free(retained_name);
            try s.advance();
            try s.emitOpAtom(opcode.op.get_field, retained_name);
            clearShortCircuitOrConditionalTail(s);
        } else if (k == @as(tok.TokenKind, @intCast('['))) {
            try s.advance();
            try parseExpr(s);
            try expectPunct(s, ']');
            try s.emitOp(opcode.op.get_array_el);
            clearShortCircuitOrConditionalTail(s);
        } else if (k == tok.TOK_TEMPLATE) {
            try parseTaggedTemplateInvocation(s);
            clearShortCircuitOrConditionalTail(s);
        } else {
            _ = flags;
            return;
        }
    }
}

fn parseMemberChain(s: *ParseState, flags: ParseFlags, chain_buf: []usize, chain_count: *usize) Error!void {
    while (true) {
        const k = s.peekKind();
        if (k == @as(tok.TokenKind, @intCast('.'))) {
            s.last_anonymous_function_expr = false;
            try s.advance();
            const private_name = s.peekKind() == tok.TOK_PRIVATE_NAME;
            const raw_name = if (s.peekKind() == tok.TOK_IDENT or private_name)
                s.token.payload.ident.atom
            else if (tok.isKeyword(s.peekKind()))
                tok.keywordAtom(s.peekKind())
            else if (s.peekKind() == tok.TOK_DELETE)
                @as(Atom, 9)
            else if (s.peekKind() == tok.TOK_CATCH)
                @as(Atom, 25)
            else
                return Error.UnexpectedToken;
            if (private_name and !s.in_class) return Error.UnexpectedToken;
            const private_atom = if (private_name) try privateNameAtom(s, raw_name) else null;
            defer if (private_atom) |atom_id| s.function.atoms.free(atom_id);
            if (private_atom) |atom_id| {
                if (s.last_was_super or !classPrivateNameIsBound(s, atom_id)) return Error.UnexpectedToken;
            }
            const name = private_atom orelse raw_name;
            const retained_name = s.function.atoms.dup(name);
            defer s.function.atoms.free(retained_name);
            try s.advance();
            // If a call follows, use get_field2 to keep `obj` on the stack
            // so we can lower as `obj func args... call_method`. Otherwise
            // a plain get_field is sufficient.
            // If the base was `super`, use get_super_value and then synthesize
            // the receiver slot for call_method from the current `this`.
            const was_super = s.last_was_super;
            s.last_was_super = false;
            if (s.peekKind() == @as(tok.TokenKind, @intCast('('))) {
                const callee_line = s.last_token_line_num;
                const callee_col = s.last_token_col_num;
                const prepare_pc = s.currentCodeLen();
                if (was_super) {
                    const code = s.currentCode();
                    if (code.len == 0 or code[code.len - 1] != opcode.op.get_super) return Error.UnexpectedToken;
                    try s.truncateCode(code.len - 1);
                    try s.emitOp(opcode.op.push_this);
                    try s.emitOpU8(opcode.op.special_object, 4);
                    try s.emitOp(opcode.op.get_super);
                    try s.emitOpAtom(opcode.op.push_atom_value, retained_name);
                    try s.emitOp(opcode.op.get_array_el);
                } else {
                    try s.emitOpAtom(opcode.op.get_field2, retained_name);
                }
                const shape = try parseCallArgs(s, flags);
                s.last_anonymous_function_expr = false;
                switch (shape) {
                    .direct => |argc| {
                        const call_pc = s.currentCodeLen();
                        try s.emitOpU16At(opcode.op.call_method, argc, callee_line, callee_col);
                        if (!was_super and !private_name) try s.appendDirectCallSite(prepare_pc, call_pc, retained_name, argc);
                    },
                    .applied => {
                        // Method call with spread. Stack: [obj, func, array].
                        // QuickJS emits `perm3 ; apply 0` (`quickjs.c:26672-26676`).
                        try s.emitOp(opcode.op.perm3);
                        try s.emitOpU16At(opcode.op.apply, 0, callee_line, callee_col);
                    },
                }
            } else {
                if (was_super) {
                    const code = s.currentCode();
                    if (code.len == 0 or code[code.len - 1] != opcode.op.get_super) return Error.UnexpectedToken;
                    try s.truncateCode(code.len - 1);
                    try s.emitOp(opcode.op.push_this);
                    try s.emitOpU8(opcode.op.special_object, 4);
                    try s.emitOp(opcode.op.get_super);
                    try s.emitOpAtom(opcode.op.push_atom_value, retained_name);
                    try s.emitOp(opcode.op.get_super_value);
                    if (optionalCallFollows(s)) {
                        try s.emitOp(opcode.op.push_this);
                        try s.emitOp(opcode.op.swap);
                        s.last_was_with_method_ref = true;
                    }
                } else if (optionalCallFollows(s)) {
                    try s.emitOpAtom(opcode.op.get_field2, retained_name);
                    s.last_was_with_method_ref = true;
                } else if (!s.destructuring_assignment_target_mode and
                    name == atom_module.ids.length and
                    s.peekKind() != @as(tok.TokenKind, @intCast('=')) and
                    compoundAssignOpcode(s.peekKind()) == null and
                    s.peekKind() != tok.TOK_INC and
                    s.peekKind() != tok.TOK_DEC)
                {
                    try s.emitOp(opcode.op.get_length);
                } else {
                    try s.emitOpAtom(opcode.op.get_field, retained_name);
                }
            }
            clearShortCircuitOrConditionalTail(s);
        } else if (k == tok.TOK_QUESTION_MARK_DOT) {
            s.last_anonymous_function_expr = false;
            s.last_was_direct_eval_callee = false;
            // Optional-chain access: `obj?.x` / `obj?.[k]` / `obj?.()`.
            // QuickJS (`quickjs.c:26158` `optional_chain_test`) emits an
            // inline check at each `?.` site: dup the receiver, check
            // null/undefined, branch to either the normal access (NEXT)
            // or the chain exit (push undefined and goto). The chain
            // exit address is shared across all `?.` in the same
            // parseLhsExpr call and patched at chain end.
            try s.advance();
            const next = s.peekKind();
            const optional_method_call = next == @as(tok.TokenKind, @intCast('(')) and s.last_was_with_method_ref;
            try emitOptionalChainTest(s, chain_buf, chain_count, if (optional_method_call) 2 else 1);
            if (next == @as(tok.TokenKind, @intCast('['))) {
                try s.advance();
                try parseExpr(s);
                try expectPunct(s, ']');
                if (s.peekKind() == @as(tok.TokenKind, @intCast('('))) {
                    // `obj?.[k](args)` — keep obj on stack via get_array_el2.
                    try s.emitOp(opcode.op.get_array_el2);
                    const shape = try parseCallArgs(s, flags);
                    s.last_anonymous_function_expr = false;
                    switch (shape) {
                        .direct => |argc| try s.emitOpU16(opcode.op.call_method, argc),
                        .applied => {
                            try s.emitOp(opcode.op.perm3);
                            try s.emitOpU16(opcode.op.apply, 0);
                        },
                    }
                } else {
                    try s.emitOp(opcode.op.get_array_el);
                }
            } else if (next == @as(tok.TokenKind, @intCast('('))) {
                const use_method_call = s.last_was_with_method_ref;
                s.last_was_with_method_ref = false;
                const callee_line = s.last_token_line_num;
                const callee_col = s.last_token_col_num;
                // `a?.()` — optional function call. The chain test drop
                // already cleared `a`; on the success path `a` is the
                // function receiver, args follow on the stack, then a
                // plain `call` consumes them.
                const shape = try parseCallArgs(s, flags);
                s.last_anonymous_function_expr = false;
                switch (shape) {
                    .direct => |argc| try s.emitOpU16At(if (use_method_call) opcode.op.call_method else opcode.op.call, argc, callee_line, callee_col),
                    .applied => {
                        if (use_method_call) {
                            try s.emitOp(opcode.op.perm3);
                        } else {
                            try s.emitOp(opcode.op.undefined);
                            try s.emitOp(opcode.op.swap);
                        }
                        try s.emitOpU16At(opcode.op.apply, 0, callee_line, callee_col);
                    },
                }
            } else if (next == tok.TOK_IDENT or next == tok.TOK_PRIVATE_NAME or tok.isKeyword(next) or next == tok.TOK_DELETE or next == tok.TOK_CATCH) {
                const private_name = next == tok.TOK_PRIVATE_NAME;
                const raw_name = if (next == tok.TOK_IDENT or private_name)
                    s.token.payload.ident.atom
                else if (tok.isKeyword(next))
                    tok.keywordAtom(next)
                else if (next == tok.TOK_DELETE)
                    @as(Atom, 9)
                else if (next == tok.TOK_CATCH)
                    @as(Atom, 25)
                else
                    unreachable;
                if (private_name and !s.in_class) return Error.UnexpectedToken;
                const private_atom = if (private_name) try privateNameAtom(s, raw_name) else null;
                defer if (private_atom) |atom_id| s.function.atoms.free(atom_id);
                if (private_atom) |atom_id| {
                    if (!classPrivateNameIsBound(s, atom_id)) return Error.UnexpectedToken;
                }
                const name = private_atom orelse raw_name;
                const retained_name = s.function.atoms.dup(name);
                defer s.function.atoms.free(retained_name);
                try s.advance();
                if (s.peekKind() == @as(tok.TokenKind, @intCast('('))) {
                    // `obj?.b(args)` — method call. Use get_field2 to
                    // keep obj on the stack as the call's `this`.
                    try s.emitOpAtom(opcode.op.get_field2, retained_name);
                    const shape = try parseCallArgs(s, flags);
                    s.last_anonymous_function_expr = false;
                    switch (shape) {
                        .direct => |argc| try s.emitOpU16(opcode.op.call_method, argc),
                        .applied => {
                            try s.emitOp(opcode.op.perm3);
                            try s.emitOpU16(opcode.op.apply, 0);
                        },
                    }
                } else {
                    if (optionalCallFollows(s)) {
                        try s.emitOpAtom(opcode.op.get_field2, retained_name);
                        s.last_was_with_method_ref = true;
                    } else {
                        try s.emitOpAtom(opcode.op.get_field, retained_name);
                    }
                }
            } else {
                return Error.UnexpectedToken;
            }
            clearShortCircuitOrConditionalTail(s);
        } else if (k == @as(tok.TokenKind, @intCast('['))) {
            s.last_anonymous_function_expr = false;
            s.last_was_direct_eval_callee = false;
            const was_super = s.last_was_super;
            s.last_was_super = false;
            try s.advance();
            if (was_super) {
                const code = s.currentCode();
                if (code.len == 0 or code[code.len - 1] != opcode.op.get_super) return Error.UnexpectedToken;
                try s.truncateCode(code.len - 1);
                try s.emitOp(opcode.op.push_this);
                try s.emitOpU8(opcode.op.special_object, 4);
                try s.emitOp(opcode.op.get_super);
            }
            try parseExpr(s);
            try expectPunct(s, ']');
            // Same shape as dotted: if a call follows, keep obj on stack via
            // get_array_el2 + call_method.
            if (s.peekKind() == @as(tok.TokenKind, @intCast('('))) {
                const callee_line = s.last_token_line_num;
                const callee_col = s.last_token_col_num;
                if (was_super) {
                    try s.emitOp(opcode.op.get_array_el);
                } else {
                    try s.emitOp(opcode.op.get_array_el2);
                }
                const shape = try parseCallArgs(s, flags);
                s.last_anonymous_function_expr = false;
                switch (shape) {
                    .direct => |argc| try s.emitOpU16At(opcode.op.call_method, argc, callee_line, callee_col),
                    .applied => {
                        try s.emitOp(opcode.op.perm3);
                        try s.emitOpU16At(opcode.op.apply, 0, callee_line, callee_col);
                    },
                }
            } else {
                if (was_super) {
                    try s.emitOp(opcode.op.get_super_value);
                    if (optionalCallFollows(s)) {
                        try s.emitOp(opcode.op.push_this);
                        try s.emitOp(opcode.op.swap);
                        s.last_was_with_method_ref = true;
                    }
                } else {
                    if (optionalCallFollows(s)) {
                        try s.emitOp(opcode.op.get_array_el2);
                        s.last_was_with_method_ref = true;
                    } else {
                        try s.emitOp(opcode.op.get_array_el);
                    }
                }
            }
            clearShortCircuitOrConditionalTail(s);
        } else if (k == @as(tok.TokenKind, @intCast('('))) {
            s.last_anonymous_function_expr = false;
            const callee_line = s.last_token_line_num;
            const callee_col = s.last_token_col_num;
            const was_super = s.last_was_super;
            s.last_was_super = false;
            if (was_super and !s.allow_super_call) return Error.UnexpectedToken;
            if (was_super) {
                const active_func_idx = s.cur_func().this_active_func_var_idx;
                const new_target_idx = s.cur_func().new_target_var_idx;
                const this_idx = s.cur_func().this_var_idx;
                if (active_func_idx < 0 or new_target_idx < 0 or this_idx < 0) {
                    try emitCapturedSuperConstructorCall(s, flags, .{ .line = callee_line, .col = callee_col });
                    s.last_anonymous_function_expr = false;
                    continue;
                }
                const code = s.currentCode();
                if (code.len == 0 or code[code.len - 1] != opcode.op.get_super) return Error.UnexpectedToken;
                try s.truncateCode(code.len - 1);
                try s.emitOp(opcode.op.check_ctor);
                try s.emitOpU16(opcode.op.get_loc, @intCast(active_func_idx));
                try s.emitOp(opcode.op.get_super);
                try s.emitOpU16(opcode.op.get_loc, @intCast(new_target_idx));
                const shape = try parseCallArgs(s, flags);
                s.last_anonymous_function_expr = false;
                switch (shape) {
                    .direct => |argc| try s.emitOpU16At(opcode.op.call_constructor, argc, callee_line, callee_col),
                    .applied => try s.emitOpU16At(opcode.op.apply, 1, callee_line, callee_col),
                }
                try s.emitOp(opcode.op.dup);
                try s.emitOpU16(opcode.op.put_loc_check_init, @intCast(this_idx));
                try s.emitOpU16(opcode.op.get_var_ref_check, 0);
                try s.emitOp(opcode.op.dup);
                try s.emitOpU8(opcode.op.if_false8, 8);
                try s.emitOpU16(opcode.op.get_loc_check, @intCast(this_idx));
                try s.emitOp(opcode.op.swap);
                try s.emitOpU16(opcode.op.call_method, 0);
                try s.emitOp(opcode.op.drop);
                continue;
            }
            const was_with_method_ref = s.last_was_with_method_ref;
            s.last_was_with_method_ref = false;
            const was_direct_eval = s.last_was_direct_eval_callee;
            s.last_was_direct_eval_callee = false;
            if (was_direct_eval and was_with_method_ref) {
                try s.emitOp(opcode.op.nip);
            }
            const shape = try parseCallArgs(s, flags);
            s.last_anonymous_function_expr = false;
            switch (shape) {
                .direct => |argc| {
                    if (was_direct_eval) {
                        var eval_scope: u16 = @intCast(s.scope_level);
                        if (s.class_field_initializer_depth > 0) eval_scope |= eval_class_field_initializer_flag;
                        if (s.in_parameter_initializer) eval_scope |= eval_parameter_initializer_flag;
                        try s.emitOpU32At(opcode.op.eval, @as(u32, argc) | (@as(u32, eval_scope) << 16), callee_line, callee_col);
                    } else {
                        try s.emitOpU16At(if (was_with_method_ref) opcode.op.call_method else opcode.op.call, argc, callee_line, callee_col);
                    }
                },
                .applied => {
                    // Plain function call with spread. Stack: [func, array].
                    // QuickJS rearranges to [func, undef, array] for apply
                    // (`quickjs.c:26699-26703`).
                    if (was_direct_eval) {
                        var eval_scope: u16 = @intCast(s.scope_level);
                        if (s.class_field_initializer_depth > 0) eval_scope |= eval_class_field_initializer_flag;
                        if (s.in_parameter_initializer) eval_scope |= eval_parameter_initializer_flag;
                        try s.emitOpU16At(opcode.op.apply_eval, eval_scope, callee_line, callee_col);
                    } else {
                        if (was_super or was_with_method_ref) {
                            try s.emitOp(opcode.op.perm3);
                        } else {
                            try s.emitOp(opcode.op.undefined);
                            try s.emitOp(opcode.op.swap);
                        }
                        try s.emitOpU16At(opcode.op.apply, 0, callee_line, callee_col);
                    }
                },
            }
            clearShortCircuitOrConditionalTail(s);
        } else if (k == tok.TOK_TEMPLATE) {
            if (chain_count.* > 0) return Error.UnexpectedToken;
            try parseTaggedTemplateInvocation(s);
            clearShortCircuitOrConditionalTail(s);
        } else {
            break;
        }
    }
}

fn parseTaggedTemplateInvocation(s: *ParseState) Error!void {
    s.last_anonymous_function_expr = false;
    s.last_was_direct_eval_callee = false;
    s.last_lhs_was_tagged_template = true;
    // Tagged template `tag\`...\``. The previously emitted tag expression
    // sits on the stack. If the tag was a member access, rewrite the
    // trailing get_field/get_array_el to its `*2` form so the receiver stays
    // on the stack as `this`, matching QuickJS's `call=1` template branch
    // (`quickjs.c:23880`, `quickjs.c:26480..26486`).
    const code = s.currentCode();
    var use_method_call = false;
    if (code.len >= 5 and code[code.len - 5] == opcode.op.get_field) {
        code[code.len - 5] = opcode.op.get_field2;
        use_method_call = true;
    } else if (code.len >= 1 and code[code.len - 1] == opcode.op.get_array_el) {
        code[code.len - 1] = opcode.op.get_array_el2;
        use_method_call = true;
    }

    const first_part = s.token.payload.str.template orelse return Error.UnexpectedToken;
    if (first_part == .no_substitution) {
        if (s.runtime) |rt| {
            var builder = try TaggedTemplateObjectBuilder.init(rt);
            defer builder.deinit();
            try builder.addPart(s.token.payload.str.bytes, s.token.payload.str.raw_bytes, s.token.payload.str.cooked_invalid);
            try builder.finish();
            try s.emitPushConst(builder.template_value);
        } else {
            try emitTaggedTemplateSingletonObject(s, s.token.payload.str.bytes, s.token.payload.str.raw_bytes);
        }
        try s.advance();
        try s.emitOpU16(if (use_method_call) opcode.op.call_method else opcode.op.call, 1);
        s.last_anonymous_function_expr = false;
        return;
    }

    var template_builder = if (s.runtime) |rt| try TaggedTemplateObjectBuilder.init(rt) else null;
    defer if (template_builder) |*builder| builder.deinit();
    if (template_builder) |*builder| {
        try s.emitPushConst(builder.template_value);
    } else {
        try s.emitOp(opcode.op.undefined); // parser-only fallback placeholder
    }
    var argc: u16 = 1; // template object counts as the first arg
    while (true) {
        const part = s.token.payload.str.template orelse return Error.UnexpectedToken;
        if (template_builder) |*builder| {
            try builder.addPart(s.token.payload.str.bytes, s.token.payload.str.raw_bytes, s.token.payload.str.cooked_invalid);
        }
        if (part == .no_substitution or part == .tail) {
            try s.advance();
            break;
        }
        try s.advance();
        try parseExpr(s);
        argc += 1;
        if (s.peekKind() != @as(tok.TokenKind, @intCast('}'))) return Error.UnexpectedToken;
        s.lex.freeToken(&s.token);
        s.token = try s.lex.nextTemplatePartAfterBrace();
    }
    if (template_builder) |*builder| try builder.finish();
    try s.emitOpU16(if (use_method_call) opcode.op.call_method else opcode.op.call, argc);
    s.last_anonymous_function_expr = false;
}

/// Result of parsing a `(...)` argument list. When the list contains a
/// spread (`...x`), QuickJS switches to an `apply`-based lowering that
/// builds an args array on the stack; the caller-side dispatch differs
/// for normal call / method call / `new` / `super(...)`.
const CallArgsShape = union(enum) {
    /// No spread. Stack contract: argc args on top of stack; caller
    /// emits `call`/`call_method`/`call_constructor` with this argc.
    direct: u16,
    /// One or more spreads. The args array is now on top of the stack
    /// (above whatever was there: func / obj+func / etc.). Caller is
    /// responsible for the final `apply <is_new>` opcode and any
    /// stack-rearrange (`undefined ; swap` for plain calls;
    /// `perm3` for method calls / `new`). Mirrors `quickjs.c:26667-26706`.
    applied,
};

/// Emit the QuickJS `optional_chain_test` sequence (`quickjs.c:26158`):
///
///     dup
///     is_undefined_or_null
///     if_false NEXT          ; if NOT null/undef, skip to NEXT
///     drop * drop_count       ; remove the dup'd receiver (and any
///                              ;   companion stack entries)
///     undefined               ; chain result on null/undef
///     goto CHAIN_EXIT         ; jump to chain end (patched later)
///     NEXT:                   ; resume normal access here
///
/// The CHAIN_EXIT goto offset is recorded so `parseLhsExpr` can patch
/// it to the post-chain byte. `drop_count` is 1 for member access
/// (`?.b` / `?.[k]`) and 2 for method call after a member dup
/// (`obj?.b()` / `?.()`); slice 7 only handles the member-access cases.
fn emitOptionalChainTest(
    s: *ParseState,
    chain_buf: []usize,
    chain_count: *usize,
    drop_count: u8,
) Error!void {
    if (chain_count.* >= chain_buf.len) return Error.OutOfMemory;
    try s.emitOp(opcode.op.dup);
    try s.emitOp(opcode.op.is_undefined_or_null);
    const next_jump = try emitForwardJump(s, opcode.op.if_false);
    var i: u8 = 0;
    while (i < drop_count) : (i += 1) {
        try s.emitOp(opcode.op.drop);
    }
    try s.emitOp(opcode.op.undefined);
    const exit_jump = try emitForwardJump(s, opcode.op.goto);
    try patchForwardJump(s, next_jump);
    chain_buf[chain_count.*] = exit_jump;
    chain_count.* += 1;
}

/// Parse a `(arg0, arg1, ...)` argument list and return the call shape.
/// Caller consumed nothing yet — this consumes the leading `(` and the
/// matching `)`.
fn parseCallArgs(s: *ParseState, flags: ParseFlags) Error!CallArgsShape {
    try expectPunct(s, '(');
    var arg_flags = flags;
    arg_flags.result_needed = true;
    var argc: u16 = 0;
    var has_spread = false;
    while (s.peekKind() != @as(tok.TokenKind, @intCast(')'))) {
        if (s.peekKind() == tok.TOK_ELLIPSIS) {
            has_spread = true;
            break;
        }
        try parseAssignExpr2(s, arg_flags);
        argc += 1;
        if (s.peekKind() == @as(tok.TokenKind, @intCast(','))) {
            try s.advance();
            continue;
        }
        break;
    }
    if (!has_spread) {
        try expectPunct(s, ')');
        return .{ .direct = argc };
    }
    s.features.insert(.spread_rest);
    // Spread path mirrors `quickjs.c:26633..26664`. The leading args
    // become an array, then each remaining arg is appended (via the
    // iterator protocol for spread, via define_array_el+inc otherwise).
    try s.emitOpU16(opcode.op.array_from, argc);
    try s.emitOpI32(opcode.op.push_i32, @intCast(argc));
    while (s.peekKind() != @as(tok.TokenKind, @intCast(')'))) {
        if (s.peekKind() == tok.TOK_ELLIPSIS) {
            try s.advance();
            try parseAssignExpr2(s, arg_flags);
            try s.emitOp(opcode.op.append);
        } else {
            try parseAssignExpr2(s, arg_flags);
            try s.emitOp(opcode.op.define_array_el);
            try s.emitOp(opcode.op.inc);
        }
        if (s.peekKind() == @as(tok.TokenKind, @intCast(','))) {
            try s.advance();
            continue;
        }
        break;
    }
    try expectPunct(s, ')');
    try s.emitOp(opcode.op.drop); // drop the index, leave array on stack
    return .applied;
}

fn emitStringLiteralBytes(s: *ParseState, bytes: []const u8) Error!void {
    if (bytes.len == 0) {
        try s.emitOp(opcode.op.push_empty_string);
    } else {
        const atom_id = try s.function.atoms.internString(bytes);
        defer s.function.atoms.free(atom_id);
        try s.emitOpAtom(opcode.op.push_atom_value, atom_id);
    }
}

fn parseRegExpLiteral(s: *ParseState) Error!void {
    const slash_offset = s.lex.mark_pos;
    s.lex.freeToken(&s.token);
    s.token = try s.lex.rescanRegexp(slash_offset);
    const pattern = s.token.payload.regexp.pattern;
    const flags = s.token.payload.regexp.flags;
    if (!regexp_validate.validatePatternAndFlags(pattern, flags)) return Error.InvalidRegExp;
    try emitStringLiteralBytes(s, pattern);
    try emitStringLiteralBytes(s, flags);
    try s.emitOp(opcode.op.regexp);
    try s.advance();
}

/// Parse a primary expression. `js_parse_primary_expr` lives inside
/// `js_parse_postfix_expr` in QuickJS (`quickjs.c:25500..25800`).
fn parsePrimary(s: *ParseState, flags: ParseFlags) Error!void {
    const k = s.peekKind();
    s.last_primary_was_arrow_function = false;
    s.last_was_direct_eval_callee = false;
    switch (k) {
        tok.TOK_NUMBER => {
            const value = s.token.payload.num.value;
            // Encode small integers with push_i32 to match QuickJS.
            if (s.token.payload.num.is_bigint) {
                try s.emitBigIntLiteral(s.token.payload.num.bigint_text, false);
            } else if (numberIsExactI32(value)) {
                try s.emitOpI32(opcode.op.push_i32, @as(i32, @intFromFloat(value)));
            } else {
                try s.emitPushConst(JSValue.float64(value));
            }
            try s.advance();
        },
        tok.TOK_STRING => {
            // QuickJS emits `OP_push_atom_value <atom>` for short string
            // literals (`quickjs.c:25510`). We always intern; the empty
            // string is special-cased to `push_empty_string`.
            try emitStringLiteralValue(s, s.token.payload.str.bytes);
            try s.advance();
        },
        @as(tok.TokenKind, @intCast('/')), tok.TOK_DIV_ASSIGN => try parseRegExpLiteral(s),
        tok.TOK_TEMPLATE => return parseTemplate(s, flags),
        tok.TOK_TRUE => {
            try s.emitOp(opcode.op.push_true);
            try s.advance();
        },
        tok.TOK_FALSE => {
            try s.emitOp(opcode.op.push_false);
            try s.advance();
        },
        tok.TOK_NULL => {
            try s.emitOp(opcode.op.null);
            try s.advance();
        },
        tok.TOK_THIS => {
            if (s.class_static_field_this_atom) |this_atom| {
                try s.emitScopeGetVar(this_atom);
            } else {
                try s.emitThisValue();
            }
            try s.advance();
            s.last_was_super = false;
        },
        tok.TOK_SUPER => {
            if (!s.allow_super) return Error.UnexpectedToken;
            // Emit get_super; runtime semantics depend on constructor context.
            try s.emitOp(opcode.op.get_super);
            try s.advance();
            s.last_was_super = true;
        },
        tok.TOK_IMPORT => {
            if (s.peekNextKind() == @as(tok.TokenKind, @intCast('.'))) {
                if (!s.lex.is_module or s.is_eval) return Error.UnexpectedToken;
                try s.advance();
                try s.advance();
                if (s.peekKind() != tok.TOK_IDENT or
                    s.token.payload.ident.has_escape or
                    !atomNameEquals(s, s.token.payload.ident.atom, "meta"))
                {
                    return Error.UnexpectedToken;
                }
                try s.advance();
                if (s.destructuring_assignment_target_mode) return Error.InvalidAssignmentTarget;
                try s.emitOpU8(opcode.op.special_object, 4);
                s.last_was_super = false;
                return;
            }
            try parseDynamicImportCall(s, flags);
            s.last_was_super = false;
        },
        tok.TOK_CLASS => {
            // Class expression
            try parseClass(s, false);
        },
        tok.TOK_FUNCTION => {
            // Function expression: function or async function
            // Check for async function
            const is_async = s.isIdent("async");
            const source_start = s.currentTokenStartOffset();
            if (is_async) {
                try s.advance();
            }
            const func_kind: ParseFunctionKind = if (is_async) .async else .normal;
            try parseFunctionExpr(s, func_kind, source_start);
        },
        tok.TOK_IDENT,
        tok.TOK_AWAIT,
        tok.TOK_YIELD,
        tok.TOK_STATIC,
        tok.TOK_IMPLEMENTS,
        tok.TOK_INTERFACE,
        tok.TOK_PACKAGE,
        tok.TOK_PRIVATE,
        tok.TOK_PROTECTED,
        tok.TOK_PUBLIC,
        => {
            if (!isIdentifierLikeToken(s)) return Error.UnexpectedToken;
            if (s.peekKind() == tok.TOK_AWAIT and !canUseAwaitAsIdentifier(s)) return Error.AwaitOutsideAsyncFunction;
            if (s.peekKind() == tok.TOK_YIELD and (s.in_generator or s.is_strict or s.cur_func().is_strict_mode)) return Error.YieldOutsideGenerator;
            if (s.peekKind() == tok.TOK_IDENT and
                escapedIdentifierIsReservedWordForCurrentContext(s, s.token.payload.ident.atom, s.token.payload.ident.has_escape))
            {
                return Error.UnexpectedToken;
            }
            if (s.peekKind() == tok.TOK_IDENT and
                s.token.payload.ident.has_escape and
                atomNameEquals(s, s.token.payload.ident.atom, "import") and
                s.peekNextKind() == @as(tok.TokenKind, @intCast('(')))
            {
                return Error.UnexpectedToken;
            }
            if (s.peekKind() == tok.TOK_IDENT and
                s.token.payload.ident.has_escape and
                atomNameEquals(s, s.token.payload.ident.atom, "import") and
                s.peekNextKind() == @as(tok.TokenKind, @intCast('.')))
            {
                return Error.UnexpectedToken;
            }
            if (checkAsyncSingleParamArrowHead(s)) {
                const source_start = s.currentTokenStartOffset();
                try s.advance(); // consume async
                try parseArrowFunction(s, .async, source_start, flags);
                s.last_primary_was_arrow_function = true;
                return;
            }
            if (checkAsyncParenArrowHead(s)) {
                const source_start = s.currentTokenStartOffset();
                try s.advance(); // consume async
                try parseArrowFunction(s, .async, source_start, flags);
                s.last_primary_was_arrow_function = true;
                return;
            }
            // Check for async function (async is a contextual keyword)
            if (s.isIdent("async") and s.peekNextKindNoLineTerminator(tok.TOK_FUNCTION)) {
                const source_start = s.currentTokenStartOffset();
                try s.advance(); // consume async
                const func_kind: ParseFunctionKind = .async;
                try parseFunctionExpr(s, func_kind, source_start);
                s.last_was_super = false;
                return;
            }
            // Check if this is an arrow function: ident => or async ident =>
            // Use proper lexer state save/restore for the lookahead so we
            // don't desynchronize the lexer position from the cached token.
            if (checkIdentArrowHead(s)) {
                // Check for async arrow function
                const is_async = s.isIdent("async");
                const func_kind: ParseFunctionKind = if (is_async) .async else .normal;
                const source_start = s.currentTokenStartOffset();
                if (is_async) {
                    try s.advance();
                }
                try parseArrowFunction(s, func_kind, source_start, flags);
                s.last_primary_was_arrow_function = true;
                return;
            }
            const ident = identifierLikeAtom(s);
            if (s.class_field_initializer_depth > 0 and atomNameEquals(s, ident, "arguments")) {
                return Error.UnexpectedToken;
            }
            if (s.in_class_static_block and atomNameEquals(s, ident, "arguments") and !hasCurrentFunctionBinding(s, ident)) {
                return Error.UnexpectedToken;
            }
            const direct_eval_candidate = atomNameEquals(s, ident, "eval");
            if (atomNameEquals(s, ident, "arguments") and
                s.return_depth > 0 and
                !hasCurrentFunctionBinding(s, ident) and
                try remainingBlockHasDirectFunctionDeclarationName(s, ident))
            {
                const idx = @as(u16, @intCast(try s.addScopeVar(ident, .function_decl, true, false)));
                s.cur_func().vars[idx].tdz_emitted_at_decl = true;
                try s.retrofitForwardLocalFunctionCapture(s.cur_func(), ident, idx);
            }
            const ident_next_kind = s.peekNextKind();
            const arguments_as_lvalue =
                isAssignmentLikeToken(ident_next_kind) or
                ident_next_kind == tok.TOK_INC or
                ident_next_kind == tok.TOK_DEC;
            if (atomNameEquals(s, ident, "arguments") and
                s.return_depth > 0 and
                s.cur_func().func_type != .arrow and
                (s.in_parameter_initializer or !hasCurrentFunctionBinding(s, ident)) and
                !arguments_as_lvalue)
            {
                const subtype: u8 = if ((s.is_strict or s.cur_func().is_strict_mode) or !s.cur_func().has_simple_parameter_list) 0 else 1;
                try s.emitOpU8(opcode.op.special_object, subtype);
                try s.advance();
                s.last_was_with_method_ref = false;
                s.last_was_super = false;
                s.last_was_direct_eval_callee = false;
                return;
            }
            if (s.active_with_atom != null and s.active_with_func_depth != s.cur_func_stack.len and hasCurrentFunctionBinding(s, ident)) {
                try s.emitScopeGetVar(ident);
                s.last_was_with_method_ref = false;
            } else if (s.active_with_atom) |with_atom| {
                const next_kind = s.peekNextKind();
                if (next_kind == @as(tok.TokenKind, @intCast('('))) {
                    try emitWithGetRefFallback(s, with_atom, ident);
                    s.last_was_with_method_ref = true;
                } else if (s.force_with_lvalue or isAssignmentLikeToken(next_kind)) {
                    try emitWithGetRefFallback(s, with_atom, ident);
                    s.last_was_with_method_ref = false;
                } else if (next_kind == @as(tok.TokenKind, @intCast('.')) or next_kind == @as(tok.TokenKind, @intCast('['))) {
                    try emitWithGetVarFallback(s, with_atom, ident);
                    s.last_was_with_method_ref = false;
                } else {
                    try emitWithGetVarFallback(s, with_atom, ident);
                    s.last_was_with_method_ref = false;
                }
            } else if (s.skip_next_ident_get) |skip_atom| {
                if (skip_atom == ident) {
                    s.skip_next_ident_get = null;
                } else {
                    s.skip_next_ident_get = null;
                    try s.emitScopeGetVar(ident);
                }
                s.last_was_with_method_ref = false;
            } else {
                try s.emitScopeGetVar(ident);
                s.last_was_with_method_ref = false;
            }
            try s.advance();
            s.last_was_super = false;
            s.last_was_direct_eval_callee = direct_eval_candidate;
        },
        tok.TOK_LET => {
            if (s.is_strict or s.cur_func().is_strict_mode) return Error.UnexpectedToken;
            try s.emitScopeGetVar(tok.keywordAtom(tok.TOK_LET));
            try s.advance();
            s.last_was_super = false;
        },
        else => {
            if (k == @as(tok.TokenKind, @intCast('('))) {
                // Check if this is an arrow function
                if (checkArrowHead(s)) {
                    // Check for async arrow function
                    const is_async = s.isIdent("async");
                    const func_kind: ParseFunctionKind = if (is_async) .async else .normal;
                    const source_start = s.currentTokenStartOffset();
                    if (is_async) {
                        try s.advance();
                    }
                    try parseArrowFunction(s, func_kind, source_start, flags);
                    s.last_primary_was_arrow_function = true;
                    return;
                }
                try s.advance();
                try parseExpr2(s, forceResultNeeded(flags));
                const parenthesized_had_comma = s.last_expr_had_comma;
                const parenthesized_had_branchy_tail = s.last_expr_was_short_circuit_or_cond;
                try expectPunct(s, ')');
                if (!parenthesized_had_comma and
                    !parenthesized_had_branchy_tail and
                    (s.peekKind() == @as(tok.TokenKind, @intCast('(')) or optionalCallFollows(s)))
                {
                    if (try rewriteTrailingMemberReferenceForCall(s)) {
                        s.last_was_with_method_ref = true;
                    }
                }
                return;
            }
            if (k == @as(tok.TokenKind, @intCast('['))) {
                return parseArrayLiteral(s, flags);
            }
            if (k == @as(tok.TokenKind, @intCast('{'))) {
                return parseObjectLiteral(s, flags);
            }
            return Error.UnexpectedToken;
        },
    }
}

fn parseDynamicImportCall(s: *ParseState, flags: ParseFlags) Error!void {
    s.features.insert(.dynamic_import);
    try s.advance();
    try expectPunct(s, '(');
    var import_flags = flags;
    import_flags.in_accepted = true;
    try parseAssignExpr2(s, import_flags);
    if (s.peekKind() == @as(tok.TokenKind, @intCast(','))) {
        try s.advance();
        if (s.peekKind() == @as(tok.TokenKind, @intCast(')'))) {
            try s.emitOp(opcode.op.undefined);
        } else {
            try parseAssignExpr2(s, import_flags);
            if (s.peekKind() == @as(tok.TokenKind, @intCast(','))) try s.advance();
        }
    } else {
        try s.emitOp(opcode.op.undefined);
    }
    try expectPunct(s, ')');
    try s.emitOp(opcode.op.import);
}

/// `js_parse_template` (`quickjs.c:23880`). Non-tagged template literals
/// lower `\`a${b}c${d}e\`` to:
///
///     push_atom_value "a"
///     get_field2 concat
///     <expr b>
///     push_atom_value "c"
///     <expr d>
///     push_atom_value "e"
///     call_method <depth-1>
///
/// matching QuickJS's `String.prototype.concat`-based concatenation
/// strategy. Empty middle/tail strings are skipped (unless they are the
/// only content, where depth==0 forces an emit). Tagged templates
/// (`tag\`...\``) and lazy raw-string evaluation follow the `call=1`
/// branch in `js_parse_template`.
fn parseTemplate(s: *ParseState, flags: ParseFlags) Error!void {
    _ = flags;
    var depth: u16 = 0;
    while (s.peekKind() == tok.TOK_TEMPLATE) {
        const part_payload = s.token.payload.str;
        const bytes = part_payload.bytes;
        const part = part_payload.template orelse return Error.UnexpectedToken;
        if (part_payload.cooked_invalid) return Error.InvalidEscape;

        if (bytes.len != 0 or depth == 0) {
            if (bytes.len == 0) {
                try s.emitOp(opcode.op.push_empty_string);
            } else {
                const atom_id = try s.function.atoms.internString(bytes);
                defer s.function.atoms.free(atom_id);
                try s.emitOpAtom(opcode.op.push_atom_value, atom_id);
            }
            if (depth == 0) {
                if (part == .no_substitution) {
                    // Whole template is a single string constant; skip
                    // the concat-method setup and just consume the token.
                    try s.advance();
                    return;
                }
                const concat_atom = try s.function.atoms.internString("concat");
                defer s.function.atoms.free(concat_atom);
                try s.emitOpAtom(opcode.op.get_field2, concat_atom);
            }
            depth += 1;
        }

        if (part == .tail) {
            try s.emitOpU16(opcode.op.call_method, depth - 1);
            try s.advance(); // consume the tail TOK_TEMPLATE
            return;
        }
        // .head or .middle: parse the substitution expression and
        // resume template lexing after the closing `}`.
        try s.advance(); // consume head/middle TOK_TEMPLATE
        try parseExpr(s);
        depth += 1;
        if (s.peekKind() != @as(tok.TokenKind, @intCast('}'))) return Error.UnexpectedToken;
        // The lookahead `}` has already moved lex.pos one byte past it;
        // free the token and ask the lexer for the next template part
        // (middle or tail) without re-bumping.
        s.lex.freeToken(&s.token);
        s.token = try s.lex.nextTemplatePartAfterBrace();
    }
    return Error.UnexpectedToken;
}

fn emitTaggedTemplateSingletonObject(s: *ParseState, bytes: []const u8, raw_bytes: []const u8) Error!void {
    const cooked_atom = try s.function.atoms.internString(bytes);
    defer s.function.atoms.free(cooked_atom);
    try s.emitOpAtom(opcode.op.push_atom_value, cooked_atom);
    try s.emitOpU16(opcode.op.array_from, 1);

    const raw_atom = try s.function.atoms.internString(raw_bytes);
    defer s.function.atoms.free(raw_atom);
    try s.emitOpAtom(opcode.op.push_atom_value, raw_atom);
    try s.emitOpU16(opcode.op.array_from, 1);

    const raw_name = try s.function.atoms.internString("raw");
    defer s.function.atoms.free(raw_name);
    try s.emitOpAtom(opcode.op.define_field, raw_name);
}

const TaggedTemplateObjectBuilder = struct {
    rt: *core.JSRuntime,
    template_value: JSValue,
    raw_value: JSValue,
    template_object: *core.Object,
    raw_array: *core.Object,
    depth: u32 = 0,

    fn init(rt: *core.JSRuntime) Error!TaggedTemplateObjectBuilder {
        const template_object = core.Object.createArray(rt, null) catch return Error.OutOfMemory;
        errdefer core.Object.destroyFromHeader(rt, &template_object.header);
        const raw_array = core.Object.createArray(rt, null) catch return Error.OutOfMemory;
        errdefer core.Object.destroyFromHeader(rt, &raw_array.header);

        const raw_value = raw_array.value();
        const raw_atom = try rt.internAtom("raw");
        defer rt.atoms.free(raw_atom);
        template_object.defineOwnProperty(rt, raw_atom, core.Descriptor.data(raw_value, false, false, false)) catch return Error.UnexpectedToken;
        return .{
            .rt = rt,
            .template_value = template_object.value(),
            .raw_value = raw_value,
            .template_object = template_object,
            .raw_array = raw_array,
        };
    }

    fn deinit(self: *TaggedTemplateObjectBuilder) void {
        self.template_value.free(self.rt);
        self.raw_value.free(self.rt);
    }

    fn addPart(
        self: *TaggedTemplateObjectBuilder,
        cooked_bytes: []const u8,
        raw_bytes: []const u8,
        cooked_invalid: bool,
    ) Error!void {
        const cooked_value = if (cooked_invalid) core.JSValue.undefinedValue() else blk: {
            const cooked = core.string.String.createUtf8(self.rt, cooked_bytes) catch return Error.InvalidUtf8;
            break :blk cooked.value();
        };
        defer cooked_value.free(self.rt);
        self.template_object.defineOwnProperty(
            self.rt,
            core.atom.atomFromUInt32(self.depth),
            core.Descriptor.data(cooked_value, true, true, true),
        ) catch return Error.UnexpectedToken;

        const raw = core.string.String.createUtf8(self.rt, raw_bytes) catch return Error.InvalidUtf8;
        const raw_value = raw.value();
        defer raw_value.free(self.rt);
        self.raw_array.defineOwnProperty(
            self.rt,
            core.atom.atomFromUInt32(self.depth),
            core.Descriptor.data(raw_value, true, true, true),
        ) catch return Error.UnexpectedToken;
        self.depth += 1;
    }

    fn finish(self: *TaggedTemplateObjectBuilder) Error!void {
        self.raw_array.freeze(self.rt) catch return Error.OutOfMemory;
        self.template_object.freeze(self.rt) catch return Error.OutOfMemory;
    }
};

/// `js_parse_array_literal` (`quickjs.c:25194`). The QuickJS strategy
/// switches dynamically: leading
/// non-spread elements collect into an `array_from <count>`; on the
/// first spread, the parser pushes `<count>` as the running index,
/// then alternates between `define_array_el; inc` (for plain entries)
/// and `append` (for spread entries). The trailing `drop` removes
/// the index, leaving the constructed array on the stack.
fn parseArrayLiteral(s: *ParseState, flags: ParseFlags) Error!void {
    try s.advance(); // consume '['
    var count: u16 = 0;
    var sparse_active = false;
    var sparse_index: u32 = 0;
    var spread_active = false;
    while (s.peekKind() != @as(tok.TokenKind, @intCast(']'))) {
        if (s.peekKind() == @as(tok.TokenKind, @intCast(','))) {
            // Hole — leading or interior. QuickJS switches to an
            // object-style sparse array shape: `array_from <dense-prefix>`
            // followed by `define_field "<index>"` for present elements.
            if (spread_active) {
                try s.emitOp(opcode.op.undefined);
                try s.emitOp(opcode.op.define_array_el);
                try s.emitOp(opcode.op.inc);
            } else {
                if (!sparse_active) {
                    try s.emitOpU16(opcode.op.array_from, count);
                    sparse_active = true;
                    sparse_index = count;
                }
                sparse_index += 1;
            }
            try s.advance();
            continue;
        }
        if (s.peekKind() == tok.TOK_ELLIPSIS) {
            s.features.insert(.spread_rest);
            if (!spread_active) {
                // Switch from collect-then-array_from to running-array
                // mode. Emit array_from on the leading elements and push
                // <count> as the initial index.
                try s.emitOpU16(opcode.op.array_from, count);
                try s.emitOpI32(opcode.op.push_i32, @intCast(count));
                spread_active = true;
            }
            try s.advance();
            try parseAssignExprWithoutPendingFunctionName(s, flags);
            s.last_anonymous_function_expr = false;
            try s.emitOp(opcode.op.append);
        } else {
            try parseAssignExprWithoutPendingFunctionName(s, flags);
            s.last_anonymous_function_expr = false;
            if (spread_active) {
                try s.emitOp(opcode.op.define_array_el);
                try s.emitOp(opcode.op.inc);
            } else if (sparse_active) {
                var index_buf: [16]u8 = undefined;
                const index_name = std.fmt.bufPrint(&index_buf, "{d}", .{sparse_index}) catch return Error.UnexpectedToken;
                const index_atom = try s.function.atoms.internString(index_name);
                defer s.function.atoms.free(index_atom);
                try s.emitOpAtom(opcode.op.define_field, index_atom);
                sparse_index += 1;
            } else {
                count += 1;
            }
        }
        if (s.peekKind() == @as(tok.TokenKind, @intCast(','))) {
            try s.advance();
            continue;
        }
        break;
    }
    try expectPunct(s, ']');
    if (spread_active) {
        try s.emitOp(opcode.op.drop); // drop the running index
    } else if (!sparse_active) {
        try s.emitOpU16(opcode.op.array_from, count);
    } else {
        try s.emitOp(opcode.op.dup);
        try s.emitOpI32(opcode.op.push_i32, @intCast(sparse_index));
        try s.emitOpAtom(opcode.op.put_field, atom_module.ids.length);
    }
}

/// `js_parse_object_literal` (`quickjs.c:24361`). Supports ordinary,
/// shorthand, computed, method, accessor, spread, and `__proto__` forms.
fn parseObjectLiteral(s: *ParseState, flags: ParseFlags) Error!void {
    try s.advance(); // consume '{'
    try s.emitOp(opcode.op.object);
    var proto_field_seen = false;
    if (s.peekKind() != @as(tok.TokenKind, @intCast('}'))) {
        while (true) {
            try parseObjectProperty(s, flags, &proto_field_seen);
            if (s.peekKind() == @as(tok.TokenKind, @intCast(','))) {
                try s.advance();
                if (s.peekKind() == @as(tok.TokenKind, @intCast('}'))) break;
                continue;
            }
            break;
        }
    }
    try expectPunct(s, '}');
}

fn parseObjectProperty(s: *ParseState, flags: ParseFlags, proto_field_seen: *bool) Error!void {
    const k = s.peekKind();
    const property_source_start = s.currentTokenStartOffset();
    const computed_flags = ParseFlags{
        .in_accepted = true,
        .pow_allowed = flags.pow_allowed,
        .result_needed = flags.result_needed,
    };

    // Spread property: ...obj
    if (k == tok.TOK_ELLIPSIS) {
        s.features.insert(.spread_rest);
        try s.advance();
        try parseAssignExpr2(s, flags);
        try s.emitOp(opcode.op.null); // dummy excludeList, matching QuickJS object-spread lowering
        try s.emitOpU8(opcode.op.copy_data_properties, 2 | (1 << 2) | (0 << 5));
        try s.emitOp(opcode.op.drop); // excludeList
        try s.emitOp(opcode.op.drop); // source
        return;
    }

    if (k == @as(tok.TokenKind, @intCast('*'))) {
        try s.advance();
        if (s.peekKind() == @as(tok.TokenKind, @intCast('['))) {
            try s.advance();
            try parseAssignExpr2(s, computed_flags);
            try expectPunct(s, ']');
            if (s.peekKind() != @as(tok.TokenKind, @intCast('('))) return Error.UnexpectedToken;
            try emitObjectMethodFunction(s, null, .generator, property_source_start);
            try s.emitOpU8(opcode.op.define_method_computed, 4);
            return;
        }
        const name_info = (try parseObjectPropertyName(s)) orelse return Error.UnexpectedToken;
        const name = name_info.atom;
        defer if (name_info.retained) s.function.atoms.free(name);
        if (s.peekKind() != @as(tok.TokenKind, @intCast('('))) return Error.UnexpectedToken;
        try emitObjectMethodFunction(s, null, .generator, property_source_start);
        try s.emitOpAtomU8(opcode.op.define_method, name, 4);
        return;
    }

    if (k == tok.TOK_IDENT and s.isIdent("async") and
        s.peekNextKind() != @as(tok.TokenKind, @intCast(':')) and
        s.peekNextKind() != @as(tok.TokenKind, @intCast('(')) and
        s.peekNextKind() != @as(tok.TokenKind, @intCast(',')) and
        s.peekNextKind() != @as(tok.TokenKind, @intCast('}')))
    {
        try s.advance();
        if (s.gotLineTerminator()) return Error.UnexpectedToken;
        const func_kind: ParseFunctionKind = if (s.peekKind() == @as(tok.TokenKind, @intCast('*'))) blk: {
            try s.advance();
            break :blk .async_generator;
        } else .async;
        if (s.peekKind() == @as(tok.TokenKind, @intCast('['))) {
            try s.advance();
            try parseAssignExpr2(s, computed_flags);
            try expectPunct(s, ']');
            if (s.peekKind() != @as(tok.TokenKind, @intCast('('))) return Error.UnexpectedToken;
            try emitObjectMethodFunction(s, null, func_kind, property_source_start);
            try s.emitOpU8(opcode.op.define_method_computed, 4);
            return;
        }
        const name_info = (try parseObjectPropertyName(s)) orelse return Error.UnexpectedToken;
        const name = name_info.atom;
        defer if (name_info.retained) s.function.atoms.free(name);
        if (s.peekKind() != @as(tok.TokenKind, @intCast('('))) return Error.UnexpectedToken;
        try emitObjectMethodFunction(s, null, func_kind, property_source_start);
        try s.emitOpAtomU8(opcode.op.define_method, name, 4);
        return;
    }

    // Computed property name: [expr]: value
    if (k == @as(tok.TokenKind, @intCast('['))) {
        try s.advance();
        try parseAssignExpr2(s, computed_flags);
        try expectPunct(s, ']');
        if (s.peekKind() == @as(tok.TokenKind, @intCast('('))) {
            try emitObjectMethodFunction(s, null, .method, property_source_start);
            try s.emitOpU8(opcode.op.define_method_computed, 4);
        } else {
            try expectPunct(s, ':');
            try s.emitOp(opcode.op.to_propkey);
            try parseAssignExprWithPendingFunctionName(s, flags, null);
            if (s.last_anonymous_function_expr) {
                try s.emitOp(opcode.op.set_name_computed);
                s.last_anonymous_function_expr = false;
            }
            try s.emitOp(opcode.op.define_array_el);
            try s.emitOp(opcode.op.drop);
        }
        return;
    }

    if (try parseObjectPropertyName(s)) |name_info| {
        const name = name_info.atom;
        defer if (name_info.retained) s.function.atoms.free(name);
        const is_getter = !name_info.has_escape and atomNameEquals(s, name, "get");
        const is_setter = !name_info.has_escape and atomNameEquals(s, name, "set");
        if ((is_getter or is_setter) and
            s.peekKind() != @as(tok.TokenKind, @intCast(':')) and
            s.peekKind() != @as(tok.TokenKind, @intCast('(')))
        {
            try parseObjectAccessorProperty(s, computed_flags, if (is_getter) .get else .set, if (is_getter) 1 else 2, property_source_start);
        } else if (s.peekKind() == @as(tok.TokenKind, @intCast(':'))) {
            try s.advance();
            try parseAssignExprWithPendingFunctionName(s, flags, if (name_info.is_proto) null else name);
            if (name_info.is_proto) {
                if (proto_field_seen.*) return Error.UnexpectedToken;
                proto_field_seen.* = true;
                try s.emitOp(opcode.op.set_proto);
            } else {
                if (s.last_anonymous_function_expr) {
                    try s.emitOpAtom(opcode.op.set_name, name);
                    s.last_anonymous_function_expr = false;
                }
                try s.emitOpAtom(opcode.op.define_field, name);
            }
        } else if (s.peekKind() == @as(tok.TokenKind, @intCast('('))) {
            try emitObjectMethodFunction(s, null, .method, property_source_start);
            try s.emitOpAtomU8(opcode.op.define_method, name, 4);
        } else if (name_info.allow_shorthand) {
            // Shorthand `{ x }` — stack: obj, then push value of `x`.
            if (s.active_with_atom != null and s.active_with_func_depth != s.cur_func_stack.len and hasCurrentFunctionBinding(s, name)) {
                try s.emitScopeGetVar(name);
            } else if (s.active_with_atom) |with_atom| {
                try emitWithGetVarFallback(s, with_atom, name);
            } else {
                try s.emitScopeGetVar(name);
            }
            try s.emitOpAtom(opcode.op.define_field, name);
        } else {
            return Error.UnexpectedToken;
        }
        return;
    }
    return Error.UnexpectedToken;
}

fn parseObjectAccessorProperty(
    s: *ParseState,
    flags: ParseFlags,
    func_kind: ParseFunctionKind,
    define_flags: u8,
    source_start: usize,
) Error!void {
    if (s.peekKind() == @as(tok.TokenKind, @intCast('['))) {
        try s.advance();
        try parseAssignExpr2(s, flags);
        try expectPunct(s, ']');
        if (s.peekKind() != @as(tok.TokenKind, @intCast('('))) return Error.UnexpectedToken;
        try emitObjectMethodFunction(s, null, func_kind, source_start);
        try s.emitOpU8(opcode.op.define_method_computed, define_flags | 4);
        return;
    }

    const name_info = (try parseObjectPropertyName(s)) orelse return Error.UnexpectedToken;
    const name = name_info.atom;
    defer if (name_info.retained) s.function.atoms.free(name);
    if (s.peekKind() != @as(tok.TokenKind, @intCast('('))) return Error.UnexpectedToken;
    try emitObjectMethodFunction(s, null, func_kind, source_start);
    try s.emitOpAtomU8(opcode.op.define_method, name, define_flags | 4);
}

const ObjectPropertyName = struct {
    atom: Atom,
    is_proto: bool,
    allow_shorthand: bool,
    has_escape: bool,
    retained: bool,
};

fn parseObjectPropertyName(s: *ParseState) Error!?ObjectPropertyName {
    const k = s.peekKind();
    var atom_id: Atom = undefined;
    var retained = false;
    var allow_shorthand = false;
    var has_escape = false;

    if (k == tok.TOK_IDENT or (k == tok.TOK_AWAIT and canUseAwaitAsIdentifier(s))) {
        atom_id = if (k == tok.TOK_IDENT) s.token.payload.ident.atom else tok.keywordAtom(k);
        has_escape = k == tok.TOK_IDENT and s.token.payload.ident.has_escape;
        allow_shorthand = k == tok.TOK_AWAIT or !escapedIdentifierIsReservedWordForShorthandBinding(s, atom_id, has_escape);
        try s.advance();
    } else if (tok.isKeyword(k)) {
        atom_id = tok.keywordAtom(k);
        allow_shorthand = (k == tok.TOK_YIELD and !s.in_generator and !(s.is_strict or s.cur_func().is_strict_mode)) or
            (k == tok.TOK_LET and !(s.is_strict or s.cur_func().is_strict_mode));
        try s.advance();
    } else if (k == tok.TOK_STRING) {
        atom_id = try s.function.atoms.internString(s.token.payload.str.bytes);
        retained = true;
        try s.advance();
    } else if (k == tok.TOK_NUMBER) {
        const is_bigint = s.token.payload.num.is_bigint;
        const text = if (is_bigint)
            try formatBigIntPropertyName(s, s.token.payload.num.bigint_text)
        else blk: {
            var buf: [32]u8 = undefined;
            break :blk formatFiniteNumber(&buf, s.token.payload.num.value) catch
                return Error.InvalidNumberLiteral;
        };
        defer if (is_bigint) s.function.memory.allocator.free(text);
        atom_id = try s.function.atoms.internString(text);
        retained = true;
        try s.advance();
    } else {
        return null;
    }
    return .{
        .atom = atom_id,
        .is_proto = atomNameEquals(s, atom_id, "__proto__"),
        .allow_shorthand = allow_shorthand,
        .has_escape = has_escape,
        .retained = retained,
    };
}

fn escapedIdentifierIsReservedWordForBinding(s: *ParseState, atom_id: Atom, has_escape: bool) bool {
    if (!has_escape) return false;
    const name = s.function.atoms.name(atom_id) orelse return false;
    const strict = s.is_strict or s.cur_func().is_strict_mode;
    return std.mem.eql(u8, name, "null") or
        std.mem.eql(u8, name, "false") or
        std.mem.eql(u8, name, "true") or
        std.mem.eql(u8, name, "if") or
        std.mem.eql(u8, name, "else") or
        std.mem.eql(u8, name, "return") or
        std.mem.eql(u8, name, "var") or
        std.mem.eql(u8, name, "this") or
        std.mem.eql(u8, name, "delete") or
        std.mem.eql(u8, name, "void") or
        std.mem.eql(u8, name, "typeof") or
        std.mem.eql(u8, name, "new") or
        std.mem.eql(u8, name, "in") or
        std.mem.eql(u8, name, "instanceof") or
        std.mem.eql(u8, name, "do") or
        std.mem.eql(u8, name, "while") or
        std.mem.eql(u8, name, "for") or
        std.mem.eql(u8, name, "break") or
        std.mem.eql(u8, name, "continue") or
        std.mem.eql(u8, name, "switch") or
        std.mem.eql(u8, name, "case") or
        std.mem.eql(u8, name, "default") or
        std.mem.eql(u8, name, "throw") or
        std.mem.eql(u8, name, "try") or
        std.mem.eql(u8, name, "catch") or
        std.mem.eql(u8, name, "finally") or
        std.mem.eql(u8, name, "function") or
        std.mem.eql(u8, name, "debugger") or
        std.mem.eql(u8, name, "with") or
        std.mem.eql(u8, name, "class") or
        std.mem.eql(u8, name, "const") or
        std.mem.eql(u8, name, "enum") or
        std.mem.eql(u8, name, "export") or
        std.mem.eql(u8, name, "extends") or
        std.mem.eql(u8, name, "import") or
        std.mem.eql(u8, name, "super") or
        (strict and (std.mem.eql(u8, name, "implements") or
            std.mem.eql(u8, name, "interface") or
            std.mem.eql(u8, name, "let") or
            std.mem.eql(u8, name, "package") or
            std.mem.eql(u8, name, "private") or
            std.mem.eql(u8, name, "protected") or
            std.mem.eql(u8, name, "public") or
            std.mem.eql(u8, name, "static"))) or
        ((s.in_generator or strict) and std.mem.eql(u8, name, "yield")) or
        ((s.in_async or s.lex.is_module or s.in_class_static_block) and std.mem.eql(u8, name, "await"));
}

fn escapedIdentifierIsReservedWordForShorthandBinding(s: *ParseState, atom_id: Atom, has_escape: bool) bool {
    if (!has_escape) return false;
    const name = s.function.atoms.name(atom_id) orelse return false;
    return escapedIdentifierIsReservedWordForBinding(s, atom_id, has_escape) or
        std.mem.eql(u8, name, "implements") or
        std.mem.eql(u8, name, "interface") or
        std.mem.eql(u8, name, "let") or
        std.mem.eql(u8, name, "package") or
        std.mem.eql(u8, name, "private") or
        std.mem.eql(u8, name, "protected") or
        std.mem.eql(u8, name, "public") or
        std.mem.eql(u8, name, "static") or
        std.mem.eql(u8, name, "yield");
}

fn escapedIdentifierIsReservedWordForCurrentContext(s: *ParseState, atom_id: Atom, has_escape: bool) bool {
    return has_escape and
        (escapedIdentifierIsReservedWordForBinding(s, atom_id, has_escape) or
            atomNameEquals(s, atom_id, "null") or
            atomNameEquals(s, atom_id, "false") or
            atomNameEquals(s, atom_id, "true") or
            (s.in_async and atomNameEquals(s, atom_id, "await")) or
            (s.lex.is_module and atomNameEquals(s, atom_id, "await")) or
            (s.in_class_static_block and atomNameEquals(s, atom_id, "await")) or
            (s.in_generator and atomNameEquals(s, atom_id, "yield")) or
            ((s.is_strict or s.cur_func().is_strict_mode) and atomNameEquals(s, atom_id, "yield")));
}

fn isInvalidStrictFunctionBindingName(s: *ParseState, atom_id: Atom) bool {
    return atomNameEquals(s, atom_id, "eval") or atomNameEquals(s, atom_id, "arguments");
}

fn canUseAwaitAsIdentifier(s: *ParseState) bool {
    return !s.in_async and !s.lex.is_module and !s.in_class_static_block;
}

fn isIdentifierLikeToken(s: *ParseState) bool {
    return s.peekKind() == tok.TOK_IDENT or
        (s.peekKind() == tok.TOK_AWAIT and canUseAwaitAsIdentifier(s)) or
        (s.peekKind() == tok.TOK_YIELD and !s.in_generator and !(s.is_strict or s.cur_func().is_strict_mode)) or
        isSloppyFutureReservedBindingToken(s) or
        (!(s.is_strict or s.cur_func().is_strict_mode) and
            (s.peekKind() == tok.TOK_STATIC or s.peekKind() == tok.TOK_LET));
}

fn isSloppyFutureReservedBindingToken(s: *ParseState) bool {
    return !(s.is_strict or s.cur_func().is_strict_mode) and isSloppyFutureReservedToken(s.peekKind());
}

fn isSloppyFutureReservedToken(kind: tok.TokenKind) bool {
    return switch (kind) {
        tok.TOK_IMPLEMENTS,
        tok.TOK_INTERFACE,
        tok.TOK_PACKAGE,
        tok.TOK_PRIVATE,
        tok.TOK_PROTECTED,
        tok.TOK_PUBLIC,
        => true,
        else => false,
    };
}

fn tokenCanStartExpression(kind: tok.TokenKind) bool {
    return kind == tok.TOK_IDENT or
        kind == tok.TOK_AWAIT or
        kind == tok.TOK_YIELD or
        kind == tok.TOK_NUMBER or
        kind == tok.TOK_STRING or
        kind == tok.TOK_TRUE or
        kind == tok.TOK_FALSE or
        kind == tok.TOK_NULL or
        kind == tok.TOK_THIS or
        kind == tok.TOK_FUNCTION or
        kind == tok.TOK_CLASS or
        kind == @as(tok.TokenKind, @intCast('(')) or
        kind == @as(tok.TokenKind, @intCast('[')) or
        kind == @as(tok.TokenKind, @intCast('{'));
}

fn identifierLikeAtom(s: *ParseState) Atom {
    return if (s.peekKind() == tok.TOK_IDENT) s.token.payload.ident.atom else tok.keywordAtom(s.peekKind());
}

fn identifierLikeHasInvalidEscapeForBinding(s: *ParseState) bool {
    return s.peekKind() == tok.TOK_IDENT and
        escapedIdentifierIsReservedWordForBinding(s, s.token.payload.ident.atom, s.token.payload.ident.has_escape);
}

fn isCurrentFunctionExpressionName(s: *ParseState, atom_id: Atom) bool {
    return if (s.function_expr_name_binding) |name| name == atom_id else false;
}

fn emitObjectMethodFunction(s: *ParseState, name: ?Atom, func_kind: ParseFunctionKind, source_start: usize) Error!void {
    const saved_name = s.pending_function_name;
    const saved_decl = s.pending_function_is_decl;
    const saved_top_level_children = s.top_level_functions_as_children;
    const saved_in_generator = s.in_generator;
    const saved_in_async = s.in_async;
    const saved_allow_super = s.allow_super;
    s.pending_function_name = name;
    s.pending_function_is_decl = false;
    s.top_level_functions_as_children = true;
    s.in_generator = func_kind == .generator or func_kind == .async_generator;
    s.in_async = func_kind == .async or func_kind == .async_generator;
    s.allow_super = true;
    defer {
        s.pending_function_name = saved_name;
        s.pending_function_is_decl = saved_decl;
        s.top_level_functions_as_children = saved_top_level_children;
        s.in_generator = saved_in_generator;
        s.in_async = saved_in_async;
        s.allow_super = saved_allow_super;
    }
    try parseFunctionParamsAndBody(s, func_kind, source_start);
    // Object literal methods are named by OP_define_method. Do not let
    // function-expression name inference escape and name the object literal
    // itself in assignments such as `var obj = { method() {} }`.
    s.last_anonymous_function_expr = false;
}

fn parseAssignExprWithPendingFunctionName(s: *ParseState, flags: ParseFlags, name: ?Atom) Error!void {
    const saved_name = s.pending_function_name;
    const saved_decl = s.pending_function_is_decl;
    s.pending_function_name = name;
    s.pending_function_is_decl = false;
    defer {
        s.pending_function_name = saved_name;
        s.pending_function_is_decl = saved_decl;
    }
    try parseAssignExpr2(s, flags);
}

fn atomNameEquals(s: *ParseState, atom_id: Atom, name: []const u8) bool {
    return if (s.function.atoms.name(atom_id)) |atom_name| std.mem.eql(u8, atom_name, name) else false;
}

fn atomsNameEqual(s: *ParseState, left: Atom, right: Atom) bool {
    if (left == right) return true;
    const left_name = s.function.atoms.name(left) orelse return false;
    const right_name = s.function.atoms.name(right) orelse return false;
    return std.mem.eql(u8, left_name, right_name);
}

fn evalAnnexBBlockedFunctionName(s: *ParseState, atom_id: Atom) bool {
    for (s.eval_annex_b_blocked_function_names) |blocked| {
        if (atomsNameEqual(s, atom_id, blocked)) return true;
    }
    return false;
}

fn atomNameIsPrivate(s: *ParseState, atom_id: Atom) bool {
    return if (s.function.atoms.name(atom_id)) |atom_name| std.mem.startsWith(u8, atom_name, "#") else false;
}

fn formatFiniteNumber(buffer: []u8, value: f64) ![]const u8 {
    const abs_value = @abs(value);
    if (abs_value != 0 and (abs_value < 0.000001 or abs_value >= 1000000000000000000000.0)) {
        return std.fmt.bufPrint(buffer, "{e}", .{value});
    }
    return std.fmt.bufPrint(buffer, "{d}", .{value});
}

fn formatBigIntPropertyName(s: *ParseState, text: []const u8) Error![]const u8 {
    const parse_text = if (std.mem.indexOfScalar(u8, text, '_')) |_| blk: {
        var normalized = std.ArrayList(u8).empty;
        errdefer normalized.deinit(s.function.memory.allocator);
        for (text) |ch| {
            if (ch != '_') normalized.append(s.function.memory.allocator, ch) catch return Error.OutOfMemory;
        }
        break :blk normalized.toOwnedSlice(s.function.memory.allocator) catch return Error.OutOfMemory;
    } else text;
    defer if (parse_text.ptr != text.ptr) s.function.memory.allocator.free(parse_text);

    var parsed = libs_bignum.parseAutoAlloc(s.function.memory.allocator, parse_text) catch return Error.InvalidNumberLiteral;
    defer parsed.deinit();
    return parsed.formatBase10Alloc(s.function.memory.allocator) catch return Error.OutOfMemory;
}

// =====================================================================
// Helpers
// =====================================================================

/// Map an assignment-operator token to its compound-arithmetic opcode.
/// Returns `null` for plain `=` and non-assignment tokens.
fn compoundAssignOpcode(k: tok.TokenKind) ?u8 {
    return switch (k) {
        tok.TOK_MUL_ASSIGN => opcode.op.mul,
        tok.TOK_DIV_ASSIGN => opcode.op.div,
        tok.TOK_MOD_ASSIGN => opcode.op.mod,
        tok.TOK_PLUS_ASSIGN => opcode.op.add,
        tok.TOK_MINUS_ASSIGN => opcode.op.sub,
        tok.TOK_SHL_ASSIGN => opcode.op.shl,
        tok.TOK_SAR_ASSIGN => opcode.op.sar,
        tok.TOK_SHR_ASSIGN => opcode.op.shr,
        tok.TOK_AND_ASSIGN => opcode.op.@"and",
        tok.TOK_XOR_ASSIGN => opcode.op.xor,
        tok.TOK_OR_ASSIGN => opcode.op.@"or",
        tok.TOK_POW_ASSIGN => opcode.op.pow,
        else => null,
    };
}

fn logicalAssignKind(k: tok.TokenKind) ?LogicalAssignKind {
    return switch (k) {
        tok.TOK_LAND_ASSIGN => .land,
        tok.TOK_LOR_ASSIGN => .lor,
        tok.TOK_DOUBLE_QUESTION_MARK_ASSIGN => .nullish,
        else => null,
    };
}

/// Mirror `quickjs.c:27083..27201` — token-to-opcode level table.
fn matchBinaryOp(k: tok.TokenKind, level: u8, flags: ParseFlags) ?u8 {
    return switch (level) {
        1 => switch (k) {
            @as(tok.TokenKind, @intCast('*')) => opcode.op.mul,
            @as(tok.TokenKind, @intCast('/')) => opcode.op.div,
            @as(tok.TokenKind, @intCast('%')) => opcode.op.mod,
            else => null,
        },
        2 => switch (k) {
            @as(tok.TokenKind, @intCast('+')) => opcode.op.add,
            @as(tok.TokenKind, @intCast('-')) => opcode.op.sub,
            else => null,
        },
        3 => switch (k) {
            tok.TOK_SHL => opcode.op.shl,
            tok.TOK_SAR => opcode.op.sar,
            tok.TOK_SHR => opcode.op.shr,
            else => null,
        },
        4 => switch (k) {
            @as(tok.TokenKind, @intCast('<')) => opcode.op.lt,
            @as(tok.TokenKind, @intCast('>')) => opcode.op.gt,
            tok.TOK_LTE => opcode.op.lte,
            tok.TOK_GTE => opcode.op.gte,
            tok.TOK_INSTANCEOF => opcode.op.instanceof,
            tok.TOK_IN => if (flags.in_accepted) opcode.op.in else null,
            else => null,
        },
        5 => switch (k) {
            tok.TOK_EQ => opcode.op.eq,
            tok.TOK_NEQ => opcode.op.neq,
            tok.TOK_STRICT_EQ => opcode.op.strict_eq,
            tok.TOK_STRICT_NEQ => opcode.op.strict_neq,
            else => null,
        },
        6 => switch (k) {
            @as(tok.TokenKind, @intCast('&')) => opcode.op.@"and",
            else => null,
        },
        7 => switch (k) {
            @as(tok.TokenKind, @intCast('^')) => opcode.op.xor,
            else => null,
        },
        8 => switch (k) {
            @as(tok.TokenKind, @intCast('|')) => opcode.op.@"or",
            else => null,
        },
        else => null,
    };
}

fn expectPunct(s: *ParseState, ch: u8) Error!void {
    if (!s.isPunct(ch)) return Error.UnexpectedToken;
    try s.advance();
}

fn numberIsExactI32(value: f64) bool {
    if (std.math.isNan(value) or std.math.isInf(value)) return false;
    if (value < @as(f64, std.math.minInt(i32)) or value > @as(f64, std.math.maxInt(i32))) return false;
    const truncated: f64 = @floatFromInt(@as(i32, @intFromFloat(value)));
    return truncated == value;
}

fn parseBigIntI32(text: []const u8, negate: bool) ?i32 {
    const magnitude = std.fmt.parseInt(i64, text, 0) catch return null;
    const signed = if (negate) -magnitude else magnitude;
    if (signed < std.math.minInt(i32) or signed > std.math.maxInt(i32)) return null;
    return @intCast(signed);
}

/// Emit a forward-jump opcode with a placeholder absolute target. The
/// caller passes the offset back to `patchForwardJump` once the target
/// is known. The parser uses absolute u32 offsets; `resolve_labels`
/// lowers these to relative `goto8`/`goto16`/`label`s.
fn emitForwardJump(s: *ParseState, op_id: u8) Error!usize {
    var bytes: [5]u8 = undefined;
    bytes[0] = op_id;
    std.mem.writeInt(u32, bytes[1..5], 0, .little);
    const operand_offset = s.currentCodeLen() + 1;
    try s.appendBytes(&bytes);
    return operand_offset;
}

fn emitForwardJumpNoSource(s: *ParseState, op_id: u8) Error!usize {
    var bytes: [5]u8 = undefined;
    bytes[0] = op_id;
    std.mem.writeInt(u32, bytes[1..5], 0, .little);
    const operand_offset = s.currentCodeLen() + 1;
    try s.appendBytesNoSource(&bytes);
    return operand_offset;
}

/// Emit a jump opcode whose target is already known (for backward jumps,
/// e.g. while-loop continue or for-loop back edge). `resolve_labels`
/// lowers these to relative `goto8`/`goto16`.
fn emitBackwardJump(s: *ParseState, op_id: u8, target: u32) Error!void {
    var bytes: [5]u8 = undefined;
    bytes[0] = op_id;
    std.mem.writeInt(u32, bytes[1..5], target, .little);
    try s.appendBytes(&bytes);
}

fn emitBackwardJumpNoSource(s: *ParseState, op_id: u8, target: u32) Error!void {
    var bytes: [5]u8 = undefined;
    bytes[0] = op_id;
    std.mem.writeInt(u32, bytes[1..5], target, .little);
    try s.appendBytesNoSource(&bytes);
}

const ParserPhaseInstruction = struct {
    size: u8,
    is_temp: bool = false,
};

fn parserPhaseAtomTempInstruction(code: []const u8, atoms: []const Atom, pc: usize, atom_index: usize) ?ParserPhaseInstruction {
    const op_id = code[pc];
    const size: u8 = switch (op_id) {
        opcode.op.scope_get_var_undef,
        opcode.op.scope_get_var,
        opcode.op.scope_put_var,
        opcode.op.scope_delete_var,
        opcode.op.scope_get_ref,
        opcode.op.scope_put_var_init,
        opcode.op.scope_get_private_field,
        opcode.op.scope_get_private_field2,
        opcode.op.scope_put_private_field,
        opcode.op.scope_in_private_field,
        => 7,
        opcode.op.scope_make_ref => 11,
        opcode.op.get_field_opt_chain => 5,
        else => return null,
    };
    if (pc + size > code.len or atom_index >= atoms.len) return null;
    if (std.mem.readInt(u32, code[pc + 1 ..][0..4], .little) != atoms[atom_index]) return null;
    return .{ .size = size, .is_temp = true };
}

fn parserPhaseInstruction(code: []const u8, atoms: []const Atom, pc: usize, atom_index: usize) ParserPhaseInstruction {
    if (parserPhaseAtomTempInstruction(code, atoms, pc, atom_index)) |temp_instr| return temp_instr;
    return .{ .size = opcode.sizeOf(code[pc]) };
}

fn parserPhaseInstructionHasAtom(op_id: u8, is_temp: bool) bool {
    if (is_temp) return switch (op_id) {
        opcode.op.scope_get_var_undef,
        opcode.op.scope_get_var,
        opcode.op.scope_put_var,
        opcode.op.scope_delete_var,
        opcode.op.scope_make_ref,
        opcode.op.scope_get_ref,
        opcode.op.scope_put_var_init,
        opcode.op.scope_get_private_field,
        opcode.op.scope_get_private_field2,
        opcode.op.scope_put_private_field,
        opcode.op.scope_in_private_field,
        opcode.op.get_field_opt_chain,
        => true,
        else => false,
    };

    return switch (opcode.formatOf(op_id)) {
        .atom, .atom_u8, .atom_u16, .atom_label_u8, .atom_label_u16 => true,
        else => false,
    };
}

fn parserPhaseLabelOperandOffset(op_id: u8, pc: usize, is_temp: bool) ?usize {
    if (is_temp and op_id == opcode.op.scope_make_ref) return pc + 5;
    return switch (opcode.formatOf(op_id)) {
        .label => if (op_id == opcode.op.label) null else pc + 1,
        .atom_label_u8, .atom_label_u16 => pc + 5,
        .label_u16 => pc + 1,
        else => null,
    };
}

fn rebaseMovedBytecodeLabels(code: []u8, atoms: []const Atom, old_base: usize, new_base: usize) Error!void {
    if (old_base == new_base) return;
    const old_end = old_base + code.len;
    const delta = @as(i64, @intCast(new_base)) - @as(i64, @intCast(old_base));
    var pc: usize = 0;
    var atom_index: usize = 0;
    while (pc < code.len) {
        const op_id = code[pc];
        const instr = parserPhaseInstruction(code, atoms, pc, atom_index);
        const size = instr.size;
        if (size == 0 or pc + size > code.len) return Error.UnexpectedToken;

        const label_offset = parserPhaseLabelOperandOffset(op_id, pc, instr.is_temp);
        if (label_offset) |offset| {
            const target = std.mem.readInt(u32, code[offset..][0..4], .little);
            if (target >= old_base and target <= old_end) {
                const rebased = @as(i64, @intCast(target)) + delta;
                if (rebased < 0 or rebased > std.math.maxInt(u32)) return Error.UnexpectedToken;
                std.mem.writeInt(u32, code[offset..][0..4], @intCast(rebased), .little);
            }
        }

        if (parserPhaseInstructionHasAtom(op_id, instr.is_temp)) atom_index += 1;
        pc += size;
    }
}

fn pushBreakFrame(s: *ParseState) Error!void {
    try s.break_frame_lens.append(s.function.memory.allocator, s.break_fixups.items.len);
    try s.continue_frame_lens.append(s.function.memory.allocator, s.continue_fixups.items.len);
    try s.break_frame_catch_marker_depths.append(s.function.memory.allocator, s.active_catch_marker_depth);
    try s.break_frame_cleanup_drops.append(s.function.memory.allocator, 0);
    try s.break_frame_cross_cleanup_drops.append(s.function.memory.allocator, 0);
    try s.continue_frame_catch_marker_depths.append(s.function.memory.allocator, s.active_catch_marker_depth);
    try s.continue_frame_cleanup_drops.append(s.function.memory.allocator, 0);
}

fn pushBreakOnlyFrame(s: *ParseState) Error!void {
    try s.break_frame_lens.append(s.function.memory.allocator, s.break_fixups.items.len);
    try s.break_frame_catch_marker_depths.append(s.function.memory.allocator, s.active_catch_marker_depth);
    try s.break_frame_cleanup_drops.append(s.function.memory.allocator, 0);
    try s.break_frame_cross_cleanup_drops.append(s.function.memory.allocator, 0);
}

fn setCurrentBreakCleanupDrops(s: *ParseState, drops: u8) void {
    if (s.break_frame_cleanup_drops.items.len == 0) return;
    s.break_frame_cleanup_drops.items[s.break_frame_cleanup_drops.items.len - 1] = drops;
    s.break_frame_cross_cleanup_drops.items[s.break_frame_cross_cleanup_drops.items.len - 1] = drops;
}

fn setCurrentBreakCrossCleanupDrops(s: *ParseState, drops: u8) void {
    if (s.break_frame_cross_cleanup_drops.items.len == 0) return;
    s.break_frame_cross_cleanup_drops.items[s.break_frame_cross_cleanup_drops.items.len - 1] = drops;
}

fn emitUnlabelledBreakCleanup(s: *ParseState, cleanup_drops: u8) Error!void {
    if (cleanup_drops == shared_iterator_close_marker) return;
    try emitCrossFrameCleanup(s, cleanup_drops);
}

fn emitCrossFrameCleanup(s: *ParseState, cleanup_drops: u8) Error!void {
    if (cleanup_drops == shared_iterator_close_marker or cleanup_drops == direct_iterator_close_marker) {
        try s.emitOpNoSource(opcode.op.iterator_close);
        return;
    }
    var remaining = cleanup_drops;
    while (remaining > 0) : (remaining -= 1) {
        try s.emitOpNoSource(opcode.op.drop);
    }
}

fn emitCatchMarkerDropsToDepth(s: *ParseState, target_depth: u32) Error!void {
    var remaining = s.active_catch_marker_depth;
    while (remaining > target_depth) : (remaining -= 1) {
        try s.emitOpNoSource(opcode.op.drop);
        try emitUsingDisposesForCatchMarkerDepth(s, remaining);
    }
}

fn emitUsingDisposesForCatchMarkerDepth(s: *ParseState, depth: u32) Error!void {
    var i = s.using_block_frames.items.len;
    while (i != 0) {
        i -= 1;
        const frame = s.using_block_frames.items[i];
        if (frame.catch_marker_depth != depth) continue;
        const stack_loc = frame.stack_loc orelse continue;
        try emitUsingDisposeStack(s, frame.kind, stack_loc);
        try s.emitCloseLoc(stack_loc);
    }
}

fn emitUnlabelledBreak(s: *ParseState) Error!void {
    if (s.break_frame_lens.items.len == 0) return;
    if (try emitCapturedControlThroughFinally(s, .{ .kind = .@"break" })) return;
    try emitUnlabelledBreakNoFinallyCapture(s);
}

fn emitUnlabelledBreakNoFinallyCapture(s: *ParseState) Error!void {
    try emitPendingAbruptDropsForUnlabelledBreak(s);
    try emitCatchMarkerDropsToDepth(s, s.break_frame_catch_marker_depths.getLast());
    try emitUnlabelledBreakCleanup(s, s.break_frame_cleanup_drops.getLast());
    const off = try emitForwardJumpNoSource(s, opcode.op.goto);
    try s.break_fixups.append(s.function.memory.allocator, off);
}

fn emitUnlabelledContinue(s: *ParseState) Error!void {
    if (s.continue_frame_lens.items.len == 0) return;
    if (try emitCapturedControlThroughFinally(s, .{ .kind = .@"continue" })) return;
    try emitUnlabelledContinueNoFinallyCapture(s);
}

fn emitUnlabelledContinueNoFinallyCapture(s: *ParseState) Error!void {
    try emitPendingAbruptDropsForUnlabelledContinue(s);
    try emitCatchMarkerDropsToDepth(s, s.continue_frame_catch_marker_depths.getLast());
    try emitCrossFrameCleanup(s, s.continue_frame_cleanup_drops.getLast());
    const off = try emitForwardJumpNoSource(s, opcode.op.goto);
    try s.continue_fixups.append(s.function.memory.allocator, off);
}

fn emitPendingAbruptDropsForUnlabelledBreak(s: *ParseState) Error!void {
    const target_depth = s.break_frame_lens.items.len;
    for (s.finally_pending_abrupt_frames.items) |frame| {
        if (target_depth <= frame.break_depth) try s.emitOpNoSource(opcode.op.drop);
    }
}

fn emitPendingAbruptDropsForUnlabelledContinue(s: *ParseState) Error!void {
    const target_depth = s.continue_frame_lens.items.len;
    for (s.finally_pending_abrupt_frames.items) |frame| {
        if (target_depth <= frame.continue_depth) try s.emitOpNoSource(opcode.op.drop);
    }
}

fn emitPendingAbruptDropsForReturn(s: *ParseState) Error!void {
    for (s.finally_pending_abrupt_frames.items) |_| {
        try s.emitOpNoSource(opcode.op.drop);
    }
}

fn emitPendingAbruptDropsForLabel(s: *ParseState, label_frame_index: usize) Error!void {
    for (s.finally_pending_abrupt_frames.items) |frame| {
        if (label_frame_index < frame.label_depth) try s.emitOpNoSource(opcode.op.drop);
    }
}

fn enterSwitchContinueCleanup(s: *ParseState) void {
    for (s.continue_frame_cleanup_drops.items) |*drops| {
        if (drops.* != shared_iterator_close_marker and drops.* != direct_iterator_close_marker) drops.* += 1;
    }
}

fn leaveSwitchContinueCleanup(s: *ParseState) void {
    for (s.continue_frame_cleanup_drops.items) |*drops| {
        if (drops.* != shared_iterator_close_marker and drops.* != direct_iterator_close_marker and drops.* > 0) drops.* -= 1;
    }
}

fn emitActiveIteratorCloses(s: *ParseState) Error!void {
    var index = s.break_frame_cleanup_drops.items.len;
    while (index != 0) {
        index -= 1;
        try emitCrossFrameCleanup(s, s.break_frame_cleanup_drops.items[index]);
    }
}

fn hasActiveIteratorCloses(s: *ParseState) bool {
    for (s.break_frame_cleanup_drops.items) |drops| {
        if (drops != 0) return true;
    }
    return false;
}

fn expressionStatementKeepsCompletion(s: *const ParseState) bool {
    return s.eval_ret_idx >= 0 and !s.lex.is_module;
}

fn caseCanFallthrough(s: *ParseState) bool {
    const op_id = lastOpcode(s.currentCode()) orelse return true;
    return switch (op_id) {
        opcode.op.goto,
        opcode.op.@"return",
        opcode.op.return_undef,
        opcode.op.return_async,
        opcode.op.throw,
        => false,
        else => true,
    };
}

fn lastOpcode(code: []const u8) ?u8 {
    var pc: usize = 0;
    var last: ?u8 = null;
    while (pc < code.len) {
        const op_id = code[pc];
        const size = opcode.sizeOf(op_id);
        if (size == 0 or pc + size > code.len) return null;
        last = op_id;
        pc += size;
    }
    return last;
}

fn lastNonCleanupOpcode(code: []const u8) ?u8 {
    var pc: usize = 0;
    var last: ?u8 = null;
    while (pc < code.len) {
        const op_id = code[pc];
        const size = opcode.sizeOf(op_id);
        if (size == 0 or pc + size > code.len) return null;
        if (op_id != opcode.op.leave_scope and op_id != opcode.op.close_loc) last = op_id;
        pc += size;
    }
    return last;
}

fn hasJumpToCurrentEnd(code: []const u8, include_conditional: bool) bool {
    var pc: usize = 0;
    while (pc < code.len) {
        const op_id = code[pc];
        // `scope_make_ref` embeds a label operand this scan does not
        // track, and id 192 is ambiguous in phase-1 streams
        // (`push_empty_string` vs `scope_in_private_field`). Answer
        // conservatively in both cases.
        if (op_id == opcode.op.scope_make_ref or op_id == opcode.op.scope_in_private_field) return true;
        // This scan runs on Phase 1 code, before temporary opcodes are
        // resolved: size through the phase-1 view. If the walk cannot
        // prove the path is linear, answer conservatively.
        const size = opcode.sizeOfPhase1(op_id);
        if (size == 0 or pc + size > code.len) return true;
        if (op_id == opcode.op.goto or
            (include_conditional and (op_id == opcode.op.if_false or op_id == opcode.op.if_true)))
        {
            const target = std.mem.readInt(u32, code[pc + 1 ..][0..4], .little);
            if (target == code.len) return true;
        }
        pc += size;
    }
    return false;
}

fn functionNeedsImplicitReturn(code: []const u8) bool {
    const op_id = lastNonCleanupOpcode(code) orelse return true;
    return switch (op_id) {
        opcode.op.@"return", opcode.op.return_undef, opcode.op.return_async, opcode.op.tail_call, opcode.op.tail_call_method => false,
        opcode.op.throw => hasJumpToCurrentEnd(code, false),
        else => true,
    };
}

fn patchContinueFrame(s: *ParseState) Error!void {
    if (s.continue_frame_lens.items.len == 0) return Error.UnexpectedToken;
    const start = s.continue_frame_lens.getLast();
    for (s.continue_fixups.items[start..]) |off| {
        try patchForwardJump(s, off);
    }
    s.continue_fixups.shrinkRetainingCapacity(start);
}

fn popBreakFrameAndPatch(s: *ParseState) Error!void {
    if (s.break_frame_lens.items.len == 0 or s.continue_frame_lens.items.len == 0) return Error.UnexpectedToken;
    _ = s.continue_frame_lens.pop().?;
    _ = s.continue_frame_catch_marker_depths.pop().?;
    const start = s.break_frame_lens.pop().?;
    _ = s.break_frame_catch_marker_depths.pop().?;
    _ = s.break_frame_cleanup_drops.pop().?;
    _ = s.break_frame_cross_cleanup_drops.pop().?;
    for (s.break_fixups.items[start..]) |off| {
        try patchForwardJump(s, off);
    }
    s.break_fixups.shrinkRetainingCapacity(start);
}

fn popBreakOnlyFrameAndPatch(s: *ParseState) Error!void {
    if (s.break_frame_lens.items.len == 0) return Error.UnexpectedToken;
    const start = s.break_frame_lens.pop().?;
    _ = s.break_frame_catch_marker_depths.pop().?;
    _ = s.break_frame_cleanup_drops.pop().?;
    _ = s.break_frame_cross_cleanup_drops.pop().?;
    for (s.break_fixups.items[start..]) |off| {
        try patchForwardJump(s, off);
    }
    s.break_fixups.shrinkRetainingCapacity(start);
}

fn predeclareFunctionBodyVars(s: *ParseState) Error!void {
    if (s.peekKind() != '{') return;
    const saved_pos = s.lex.pos;
    const saved_line = s.lex.line;
    const saved_col = s.lex.col;
    const saved_got_lf = s.lex.got_lf;
    const saved_mark_pos = s.lex.mark_pos;
    const saved_mark_line = s.lex.mark_line;
    const saved_mark_col = s.lex.mark_col;
    defer {
        s.lex.pos = saved_pos;
        s.lex.line = saved_line;
        s.lex.col = saved_col;
        s.lex.got_lf = saved_got_lf;
        s.lex.mark_pos = saved_mark_pos;
        s.lex.mark_line = saved_mark_line;
        s.lex.mark_col = saved_mark_col;
    }

    var body_depth: usize = 0;
    var previous_token_kind: ?tok.TokenKind = null;
    while (true) {
        var t = s.lex.next() catch return Error.UnexpectedToken;
        defer s.lex.freeToken(&t);
        switch (t.val) {
            tok.TOK_EOF => return,
            '{' => body_depth += 1,
            '}' => {
                if (body_depth == 0) return;
                body_depth -= 1;
            },
            tok.TOK_FUNCTION => try skipFunctionInPredeclareScan(s),
            tok.TOK_VAR => try predeclareVarDeclarators(s),
            tok.TOK_TEMPLATE => try skipTemplateInPredeclareScan(s, t),
            '/', tok.TOK_DIV_ASSIGN => {
                if (try skipRegexpInPredeclareScan(s, previous_token_kind)) {
                    previous_token_kind = tok.TOK_REGEXP;
                    continue;
                }
            },
            else => {},
        }
        previous_token_kind = t.val;
    }
}

fn skipFunctionInPredeclareScan(s: *ParseState) Error!void {
    while (true) {
        var t = s.lex.next() catch return Error.UnexpectedToken;
        defer s.lex.freeToken(&t);
        if (t.val == tok.TOK_EOF) return;
        if (t.val == '{') break;
    }
    var depth: usize = 1;
    var previous_token_kind: ?tok.TokenKind = '{';
    while (depth != 0) {
        var t = s.lex.next() catch return Error.UnexpectedToken;
        defer s.lex.freeToken(&t);
        switch (t.val) {
            tok.TOK_EOF => return,
            '{' => depth += 1,
            '}' => depth -= 1,
            tok.TOK_TEMPLATE => try skipTemplateInPredeclareScan(s, t),
            '/', tok.TOK_DIV_ASSIGN => {
                if (try skipRegexpInPredeclareScan(s, previous_token_kind)) {
                    previous_token_kind = tok.TOK_REGEXP;
                    continue;
                }
            },
            else => {},
        }
        previous_token_kind = t.val;
    }
}

fn skipTemplateInPredeclareScan(s: *ParseState, first: tok.Token) Error!void {
    const first_part = first.payload.str.template orelse return Error.UnexpectedToken;
    switch (first_part) {
        .no_substitution, .tail => return,
        .head, .middle => {},
    }

    while (true) {
        var expr_depth: usize = 0;
        var previous_token_kind: ?tok.TokenKind = '{';
        while (true) {
            var t = s.lex.next() catch return Error.UnexpectedToken;
            defer s.lex.freeToken(&t);
            switch (t.val) {
                tok.TOK_EOF => {
                    return;
                },
                tok.TOK_TEMPLATE => {
                    try skipTemplateInPredeclareScan(s, t);
                    previous_token_kind = tok.TOK_TEMPLATE;
                    continue;
                },
                '/', tok.TOK_DIV_ASSIGN => {
                    if (try skipRegexpInPredeclareScan(s, previous_token_kind)) {
                        previous_token_kind = tok.TOK_REGEXP;
                        continue;
                    }
                },
                '{', '(', '[' => expr_depth += 1,
                '}', ')', ']' => {
                    if (t.val == '}' and expr_depth == 0) {
                        break;
                    }
                    if (expr_depth != 0) expr_depth -= 1;
                },
                else => {},
            }
            previous_token_kind = t.val;
        }

        var next_part = s.lex.nextTemplatePartAfterBrace() catch return Error.UnexpectedToken;
        defer s.lex.freeToken(&next_part);
        const part = next_part.payload.str.template orelse return Error.UnexpectedToken;
        switch (part) {
            .tail, .no_substitution => return,
            .head, .middle => continue,
        }
    }
}

fn predeclareVarDeclarators(s: *ParseState) Error!void {
    var depth: usize = 0;
    var want_ident = true;
    var previous_token_kind: ?tok.TokenKind = tok.TOK_VAR;
    while (true) {
        var t = s.lex.next() catch return Error.UnexpectedToken;
        defer s.lex.freeToken(&t);
        switch (t.val) {
            tok.TOK_EOF, ';' => return,
            ',' => {
                if (depth == 0) want_ident = true;
            },
            '(', '[', '{' => {
                if (depth == 0 and want_ident and (t.val == '[' or t.val == '{')) want_ident = false;
                depth += 1;
            },
            ')', ']', '}' => {
                if (depth == 0) return;
                depth -= 1;
            },
            tok.TOK_TEMPLATE => {
                try skipTemplateInPredeclareScan(s, t);
                previous_token_kind = tok.TOK_TEMPLATE;
                continue;
            },
            '/', tok.TOK_DIV_ASSIGN => {
                if (try skipRegexpInPredeclareScan(s, previous_token_kind)) {
                    previous_token_kind = tok.TOK_REGEXP;
                    continue;
                }
            },
            tok.TOK_IDENT => {
                if (want_ident and depth == 0) {
                    const atom_id = t.payload.ident.atom;
                    const fd = s.cur_func();
                    const existing_var = fd.findVar(atom_id);
                    if ((existing_var < 0 or fd.vars[@intCast(existing_var)].var_kind == .function_name) and fd.findArg(atom_id) < 0) {
                        const var_idx = if (s.in_namespace)
                            try fd.addScopeVar(atom_id, .normal, s.scope_level, true, false)
                        else
                            try fd.addScopeVar(atom_id, .normal, 0, false, false);
                        if (atomNameEquals(s, atom_id, "arguments")) {
                            fd.arguments_var_idx = @intCast(var_idx);
                        }
                    } else if (existing_var >= 0 and atomNameEquals(s, atom_id, "arguments")) {
                        fd.arguments_var_idx = existing_var;
                    }
                    want_ident = false;
                }
            },
            else => {},
        }
        previous_token_kind = t.val;
    }
}

fn skipRegexpInPredeclareScan(s: *ParseState, previous_token_kind: ?tok.TokenKind) Error!bool {
    if (!predeclareSlashStartsRegexp(s, previous_token_kind)) return false;

    const slash_offset = s.lex.mark_pos;
    var regexp_token = s.lex.rescanRegexp(slash_offset) catch return Error.UnexpectedToken;
    defer s.lex.freeToken(&regexp_token);
    return true;
}

fn predeclareSlashStartsRegexp(s: *ParseState, previous_token_kind: ?tok.TokenKind) bool {
    const previous = previous_token_kind orelse return true;
    if (previous == tok.TOK_YIELD and !s.in_generator and !(s.is_strict or s.cur_func().is_strict_mode)) {
        return false;
    }
    if (previous == tok.TOK_AWAIT and canUseAwaitAsIdentifier(s)) {
        return false;
    }
    return switch (previous) {
        '(',
        '[',
        '{',
        ',',
        ';',
        ':',
        '?',
        '=',
        '!',
        '~',
        '+',
        '-',
        '*',
        '%',
        '&',
        '|',
        '^',
        tok.TOK_ARROW,
        tok.TOK_LT,
        tok.TOK_LTE,
        tok.TOK_GT,
        tok.TOK_GTE,
        tok.TOK_EQ,
        tok.TOK_STRICT_EQ,
        tok.TOK_NEQ,
        tok.TOK_STRICT_NEQ,
        tok.TOK_SHL,
        tok.TOK_SAR,
        tok.TOK_SHR,
        tok.TOK_LAND,
        tok.TOK_LOR,
        tok.TOK_POW,
        tok.TOK_DOUBLE_QUESTION_MARK,
        tok.TOK_QUESTION_MARK_DOT,
        tok.TOK_MUL_ASSIGN,
        tok.TOK_DIV_ASSIGN,
        tok.TOK_MOD_ASSIGN,
        tok.TOK_PLUS_ASSIGN,
        tok.TOK_MINUS_ASSIGN,
        tok.TOK_SHL_ASSIGN,
        tok.TOK_SAR_ASSIGN,
        tok.TOK_SHR_ASSIGN,
        tok.TOK_AND_ASSIGN,
        tok.TOK_XOR_ASSIGN,
        tok.TOK_OR_ASSIGN,
        tok.TOK_POW_ASSIGN,
        tok.TOK_LAND_ASSIGN,
        tok.TOK_LOR_ASSIGN,
        tok.TOK_DOUBLE_QUESTION_MARK_ASSIGN,
        tok.TOK_RETURN,
        tok.TOK_CASE,
        tok.TOK_THROW,
        tok.TOK_DELETE,
        tok.TOK_VOID,
        tok.TOK_TYPEOF,
        tok.TOK_NEW,
        tok.TOK_IN,
        tok.TOK_INSTANCEOF,
        tok.TOK_YIELD,
        tok.TOK_AWAIT,
        tok.TOK_OF,
        => true,
        else => false,
    };
}

// =====================================================================
// Statement parsing
// =====================================================================

fn usingDeclarationStart(s: *ParseState) bool {
    if (s.peekKind() != tok.TOK_IDENT or !s.isIdent("using")) return false;
    if (s.token.payload.ident.has_escape) return false;
    var has_line_terminator = false;
    const next = s.peekNextKindWithLineTerminator(&has_line_terminator);
    if (has_line_terminator) return false;
    return tokenKindCanStartUsingBinding(s, next);
}

fn awaitUsingDeclarationStart(s: *ParseState) bool {
    if (s.peekKind() != tok.TOK_AWAIT) return false;
    const saved_pos = s.lex.pos;
    const saved_line = s.lex.line;
    const saved_col = s.lex.col;
    const saved_got_lf = s.lex.got_lf;
    const saved_mark_pos = s.lex.mark_pos;
    const saved_mark_line = s.lex.mark_line;
    const saved_mark_col = s.lex.mark_col;
    defer {
        s.lex.pos = saved_pos;
        s.lex.line = saved_line;
        s.lex.col = saved_col;
        s.lex.got_lf = saved_got_lf;
        s.lex.mark_pos = saved_mark_pos;
        s.lex.mark_line = saved_mark_line;
        s.lex.mark_col = saved_mark_col;
    }

    var using_token = s.lex.next() catch return false;
    defer s.lex.freeToken(&using_token);
    if (s.lex.gotLineTerminator()) return false;
    if (using_token.val != tok.TOK_IDENT) return false;
    if (using_token.payload.ident.has_escape) return false;
    if (!atomNameEquals(s, using_token.payload.ident.atom, "using")) return false;

    var binding_token = s.lex.next() catch return false;
    defer s.lex.freeToken(&binding_token);
    if (s.lex.gotLineTerminator()) return false;
    return tokenKindCanStartUsingBinding(s, binding_token.val);
}

fn directUsingDeclarationKind(s: *ParseState) ?UsingStackKind {
    if (awaitUsingDeclarationStart(s)) return .async;
    if (usingDeclarationStart(s)) return .sync;
    return null;
}

fn tokenKindCanStartUsingBinding(s: *ParseState, kind: tok.TokenKind) bool {
    return kind == tok.TOK_IDENT or
        (kind == tok.TOK_AWAIT and canUseAwaitAsIdentifier(s)) or
        (kind == tok.TOK_YIELD and !s.in_generator and !(s.is_strict or s.cur_func().is_strict_mode)) or
        (!(s.is_strict or s.cur_func().is_strict_mode) and
            (kind == tok.TOK_STATIC or kind == tok.TOK_LET or
                kind == tok.TOK_IMPLEMENTS or kind == tok.TOK_INTERFACE or kind == tok.TOK_PACKAGE or
                kind == tok.TOK_PRIVATE or kind == tok.TOK_PROTECTED or kind == tok.TOK_PUBLIC));
}

fn advanceUsingDeclarationPrefixForSnapshot(s: *ParseState, kind: UsingStackKind) bool {
    switch (kind) {
        .sync => {
            if (!usingDeclarationStart(s)) return false;
            s.advance() catch return false;
            return true;
        },
        .async => {
            if (!awaitUsingDeclarationStart(s)) return false;
            s.advance() catch return false;
            s.advance() catch return false;
            return true;
        },
    }
}

fn usingDeclarationBindingIsOf(s: *ParseState, kind: UsingStackKind) bool {
    const snapshot = takeParserSnapshot(s);
    defer restoreParserLexerSnapshot(s, snapshot);
    if (!advanceUsingDeclarationPrefixForSnapshot(s, kind)) return false;
    return s.isOfToken();
}

fn usingDeclarationBindingFollowedByEquals(s: *ParseState, kind: UsingStackKind) bool {
    const snapshot = takeParserSnapshot(s);
    defer restoreParserLexerSnapshot(s, snapshot);
    if (!advanceUsingDeclarationPrefixForSnapshot(s, kind)) return false;
    s.advance() catch return false;
    return s.peekKind() == '=';
}

fn blockDirectUsingDeclarationKind(s: *ParseState) ?UsingStackKind {
    if (s.peekKind() != @as(tok.TokenKind, @intCast('{'))) return null;
    const snapshot = takeParserSnapshot(s);
    defer restoreParserLexerSnapshot(s, snapshot);

    var depth: usize = 0;
    var result: ?UsingStackKind = null;
    var previous_token_kind: ?tok.TokenKind = null;
    while (s.peekKind() != tok.TOK_EOF) {
        const kind = s.peekKind();
        if (kind == tok.TOK_TEMPLATE) {
            skipTemplateInPredeclareScan(s, s.token) catch return result;
            s.advance() catch return result;
            previous_token_kind = tok.TOK_TEMPLATE;
            continue;
        }
        if (tokenCanStartSlashRegexp(kind)) {
            if (skipRegexpInPredeclareScan(s, previous_token_kind) catch return result) {
                s.advance() catch return result;
                previous_token_kind = tok.TOK_REGEXP;
                continue;
            }
        }

        if (kind == @as(tok.TokenKind, @intCast('{'))) {
            depth += 1;
        } else if (kind == @as(tok.TokenKind, @intCast('}'))) {
            if (depth == 0) return result;
            depth -= 1;
            s.advance() catch return result;
            if (depth == 0) return result;
            continue;
        } else if (depth == 1) {
            if (directUsingDeclarationKind(s)) |direct_kind| {
                if (direct_kind == .async) return .async;
                result = .sync;
            }
        }
        s.advance() catch return result;
        previous_token_kind = kind;
    }
    return result;
}

fn programDirectUsingDeclarationKind(s: *ParseState) ?UsingStackKind {
    const snapshot = takeParserSnapshot(s);
    defer restoreParserLexerSnapshot(s, snapshot);

    var paren_depth: usize = 0;
    var bracket_depth: usize = 0;
    var brace_depth: usize = 0;
    var previous_token_kind: ?tok.TokenKind = null;
    var result: ?UsingStackKind = null;
    while (s.peekKind() != tok.TOK_EOF) {
        if (paren_depth == 0 and bracket_depth == 0 and brace_depth == 0) {
            if (directUsingDeclarationKind(s)) |direct_kind| {
                if (direct_kind == .async) return .async;
                result = .sync;
            }
        }

        const kind = s.peekKind();
        if (kind == tok.TOK_TEMPLATE) {
            skipTemplateInPredeclareScan(s, s.token) catch return result;
            s.advance() catch return result;
            previous_token_kind = tok.TOK_TEMPLATE;
            continue;
        }
        if (tokenCanStartSlashRegexp(kind)) {
            if (skipRegexpInPredeclareScan(s, previous_token_kind) catch return result) {
                s.advance() catch return result;
                previous_token_kind = tok.TOK_REGEXP;
                continue;
            }
        }

        switch (kind) {
            '(' => paren_depth += 1,
            ')' => {
                if (paren_depth > 0) paren_depth -= 1;
            },
            '[' => bracket_depth += 1,
            ']' => {
                if (bracket_depth > 0) bracket_depth -= 1;
            },
            '{' => brace_depth += 1,
            '}' => {
                if (brace_depth > 0) brace_depth -= 1;
            },
            else => {},
        }
        s.advance() catch return result;
        previous_token_kind = kind;
    }
    return result;
}

fn emitUsingHelperCall(s: *ParseState, subtype: u8, argc: u16) Error!void {
    try s.emitOpU8(opcode.op.special_object, subtype);
    switch (subtype) {
        opcode.special_object_subtype.using_create_disposable_stack,
        opcode.special_object_subtype.using_create_async_disposable_stack,
        => {},
        opcode.special_object_subtype.using_add_sync_resource,
        opcode.special_object_subtype.using_dispose_sync_stack,
        opcode.special_object_subtype.using_dispose_sync_stack_for_throw,
        opcode.special_object_subtype.using_add_async_resource,
        opcode.special_object_subtype.using_dispose_async_stack,
        opcode.special_object_subtype.using_dispose_async_stack_for_throw,
        => {},
        else => return Error.UnexpectedToken,
    }
    try s.emitOpU16(opcode.op.call, argc);
}

fn emitCreateUsingDisposableStack(s: *ParseState, kind: UsingStackKind) Error!u16 {
    const stack_loc = try appendAnonymousTempLocal(s);
    const subtype = switch (kind) {
        .sync => opcode.special_object_subtype.using_create_disposable_stack,
        .async => opcode.special_object_subtype.using_create_async_disposable_stack,
    };
    try emitUsingHelperCall(s, subtype, 0);
    try s.emitOpU16(opcode.op.put_loc, stack_loc);
    return stack_loc;
}

fn emitUsingAwait(s: *ParseState) Error!void {
    if (s.lex.is_module and s.cur_func_stack.len == 0) s.function.ensureModule().has_top_level_await = true;
    if (!s.in_async and !(s.lex.is_module and s.cur_func_stack.len == 0)) return Error.AwaitOutsideAsyncFunction;
    try s.emitOp(opcode.op.await);
}

fn emitUsingAddResource(s: *ParseState, kind: UsingStackKind, stack_loc: u16, resource_loc: u16) Error!void {
    const subtype = switch (kind) {
        .sync => opcode.special_object_subtype.using_add_sync_resource,
        .async => opcode.special_object_subtype.using_add_async_resource,
    };
    try s.emitOpU8(opcode.op.special_object, subtype);
    try s.emitOpU16(opcode.op.get_loc, stack_loc);
    try s.emitOpU16(opcode.op.get_loc, resource_loc);
    try s.emitOpU16(opcode.op.call, 2);
    try s.emitOp(opcode.op.drop);
}

fn emitUsingDisposeStack(s: *ParseState, kind: UsingStackKind, stack_loc: u16) Error!void {
    const subtype = switch (kind) {
        .sync => opcode.special_object_subtype.using_dispose_sync_stack,
        .async => opcode.special_object_subtype.using_dispose_async_stack,
    };
    try s.emitOpU8(opcode.op.special_object, subtype);
    try s.emitOpU16(opcode.op.get_loc, stack_loc);
    try s.emitOpU16(opcode.op.call, 1);
    if (kind == .async) try emitUsingAwait(s);
    try s.emitOp(opcode.op.drop);
}

fn emitUsingDisposeStackForThrow(s: *ParseState, kind: UsingStackKind, stack_loc: u16) Error!void {
    const thrown_loc = try appendAnonymousTempLocal(s);
    try s.emitOpU16(opcode.op.put_loc, thrown_loc);
    const subtype = switch (kind) {
        .sync => opcode.special_object_subtype.using_dispose_sync_stack_for_throw,
        .async => opcode.special_object_subtype.using_dispose_async_stack_for_throw,
    };
    try s.emitOpU8(opcode.op.special_object, subtype);
    try s.emitOpU16(opcode.op.get_loc, stack_loc);
    try s.emitOpU16(opcode.op.get_loc, thrown_loc);
    try s.emitOpU16(opcode.op.call, 2);
    if (kind == .async) try emitUsingAwait(s);
    try s.emitOp(opcode.op.drop);
}

pub fn parseProgramStatements(s: *ParseState, decl_mask: DeclMask) Error!void {
    const direct_using_kind = if (s.lex.is_module) programDirectUsingDeclarationKind(s) else null;
    if (direct_using_kind == null) {
        while (s.peekKind() != tok.TOK_EOF) {
            try parseStatementOrDecl(s, decl_mask);
        }
        return;
    }

    const stack_kind = direct_using_kind.?;
    const stack_loc = try emitCreateUsingDisposableStack(s, stack_kind);
    const catch_off = try emitForwardJump(s, opcode.op.@"catch");
    s.active_catch_marker_depth += 1;
    var catch_marker_active = true;
    errdefer {
        if (catch_marker_active) s.active_catch_marker_depth -= 1;
    }
    try s.using_block_frames.append(s.function.memory.allocator, .{
        .stack_loc = stack_loc,
        .catch_marker_depth = s.active_catch_marker_depth,
        .kind = stack_kind,
    });
    errdefer _ = s.using_block_frames.pop();
    while (s.peekKind() != tok.TOK_EOF) {
        try parseStatementOrDecl(s, decl_mask);
    }
    s.active_catch_marker_depth -= 1;
    catch_marker_active = false;

    try s.emitOp(opcode.op.drop);
    try emitUsingDisposeStack(s, stack_kind, stack_loc);
    try s.emitCloseLoc(stack_loc);
    const end_off = try emitForwardJump(s, opcode.op.goto);
    try patchForwardJump(s, catch_off);
    try emitUsingDisposeStackForThrow(s, stack_kind, stack_loc);
    try patchForwardJump(s, end_off);
    _ = s.using_block_frames.pop();
}

/// Mirror `js_parse_block` (`quickjs.c:27827`).
///
/// Pushes a new lexical scope before parsing the block contents and
/// pops it on exit, so `let` / `const` declarations get attached to
/// the correct `VarScope` in `function_def.scopes`. The interim
/// pipeline ignores `function_def`, but the full FunctionDef-based
/// `resolve_variables` walks this chain.
pub fn parseBlock(s: *ParseState) Error!void {
    const direct_using_kind = blockDirectUsingDeclarationKind(s);
    const is_function_body = s.suppress_block_enter_scope;
    s.suppress_block_enter_scope = false;
    try s.expectToken('{');
    try s.pushScope();
    errdefer s.popScope();
    if (!is_function_body) try s.emitEnterScope();
    // Check for directive prologue (simplified)
    try parseDirectives(s);

    if (s.is_outer_constructor_block and !s.class_has_extends) {
        s.is_outer_constructor_block = false;
        if (s.current_parameter_properties) |props| {
            for (props.items) |prop_atom| {
                try s.emitOp(opcode.op.push_this);
                try s.emitScopeGetVar(prop_atom);
                try s.emitOpAtom(opcode.op.put_field, prop_atom);
            }
        }
    }
    if (direct_using_kind) |stack_kind| {
        const stack_loc = try emitCreateUsingDisposableStack(s, stack_kind);
        const catch_off = try emitForwardJump(s, opcode.op.@"catch");
        s.active_catch_marker_depth += 1;
        try s.using_block_frames.append(s.function.memory.allocator, .{
            .stack_loc = stack_loc,
            .catch_marker_depth = s.active_catch_marker_depth,
            .kind = stack_kind,
        });
        errdefer _ = s.using_block_frames.pop();
        while (s.peekKind() != '}' and s.peekKind() != tok.TOK_EOF) {
            try parseStatementOrDecl(s, DeclMask{ .func = true, .func_with_label = true, .other = true });
        }
        s.active_catch_marker_depth -= 1;
        try s.expectToken('}');
        try s.emitOp(opcode.op.drop);
        try emitUsingDisposeStack(s, stack_kind, stack_loc);
        try s.emitCloseLoc(stack_loc);
        const end_off = try emitForwardJump(s, opcode.op.goto);
        try patchForwardJump(s, catch_off);
        try emitUsingDisposeStackForThrow(s, stack_kind, stack_loc);
        try patchForwardJump(s, end_off);
        _ = s.using_block_frames.pop();
    } else {
        try s.using_block_frames.append(s.function.memory.allocator, .{});
        errdefer _ = s.using_block_frames.pop();
        while (s.peekKind() != '}' and s.peekKind() != tok.TOK_EOF) {
            try parseStatementOrDecl(s, DeclMask{ .func = true, .func_with_label = true, .other = true });
        }
        try s.expectToken('}');
        _ = s.using_block_frames.pop();
    }
    s.popScope();
}

/// Mirror the directive-prologue portion of `js_parse_directives`
/// (`quickjs.c:35642`) for runtime-visible strict-mode behavior.
pub fn parseDirectives(s: *ParseState) Error!void {
    // Only directives before the first non-directive statement participate in
    // strict-mode detection; non-strict directives are consumed as statements.
    var directive_contains_legacy_escape = false;
    while (s.peekKind() == tok.TOK_STRING) {
        if (!stringLiteralStatementHasDirectiveTerminator(s)) break;
        const str_payload = s.token.payload.str;
        // Check if this is "use strict"
        if (!str_payload.contains_escape and
            str_payload.bytes.len == 10 and
            std.mem.eql(u8, str_payload.bytes, "use strict"))
        {
            if (directive_contains_legacy_escape or str_payload.contains_legacy_escape) return Error.UnexpectedToken;
            s.cur_func().has_use_strict = true;
            s.is_strict = true;
            s.cur_func().is_strict_mode = true;
            s.lex.is_strict_mode = true;
        }
        if (expressionStatementKeepsCompletion(s)) {
            try emitStringLiteralValue(s, str_payload.bytes);
            try s.emitScopePutVar(ParseState.eval_ret_atom);
        }
        directive_contains_legacy_escape = directive_contains_legacy_escape or str_payload.contains_legacy_escape;
        try s.advance();
        // Check for semicolon or ASI
        if (s.isPunct(';')) {
            try s.advance();
        } else if (!s.gotLineTerminator() and
            s.peekKind() != '}' and
            s.peekKind() != tok.TOK_EOF)
        {
            // Not a directive, break
            break;
        }
    }
}

fn stringLiteralStatementHasDirectiveTerminator(s: *const ParseState) bool {
    var index = s.currentTokenEndOffset();
    const source = s.lex.source;
    while (index < source.len) {
        switch (source[index]) {
            ';', '}' => return true,
            '\n', '\r' => return !lineTerminatorContinuesStringLiteralExpression(source, index),
            ' ', '\t', 0x0B, 0x0C => {
                index += 1;
                continue;
            },
            '/' => {
                if (index + 1 >= source.len) return false;
                if (source[index + 1] == '/') return true;
                if (source[index + 1] == '*') {
                    index += 2;
                    var saw_lf = false;
                    while (index + 1 < source.len and !(source[index] == '*' and source[index + 1] == '/')) : (index += 1) {
                        if (source[index] == '\n' or source[index] == '\r') saw_lf = true;
                    }
                    if (index + 1 >= source.len) return false;
                    index += 2;
                    if (saw_lf) return true;
                    continue;
                }
                return false;
            },
            else => return false,
        }
    }
    return true;
}

fn lineTerminatorContinuesStringLiteralExpression(source: []const u8, start: usize) bool {
    var index = start;
    while (index < source.len) {
        switch (source[index]) {
            ' ', '\t', 0x0B, 0x0C, '\n', '\r' => index += 1,
            '/' => {
                if (index + 1 >= source.len) return false;
                if (source[index + 1] == '/') return false;
                if (source[index + 1] != '*') return false;
                index += 2;
                while (index + 1 < source.len and !(source[index] == '*' and source[index + 1] == '/')) : (index += 1) {}
                if (index + 1 >= source.len) return false;
                index += 2;
            },
            else => break,
        }
    }
    return startsKeywordAt(source, index, "in") or startsKeywordAt(source, index, "instanceof");
}

fn startsKeywordAt(source: []const u8, index: usize, keyword: []const u8) bool {
    if (index + keyword.len > source.len) return false;
    if (!std.mem.eql(u8, source[index .. index + keyword.len], keyword)) return false;
    if (index + keyword.len >= source.len) return true;
    return !isAsciiIdentifierContinue(source[index + keyword.len]);
}

fn isAsciiIdentifierContinue(c: u8) bool {
    return unicode.isAsciiIdentifierPartByte(c);
}

fn emitStringLiteralValue(s: *ParseState, bytes: []const u8) Error!void {
    if (bytes.len == 0) {
        try s.emitOp(opcode.op.push_empty_string);
    } else {
        const atom_id = try s.function.atoms.internString(bytes);
        defer s.function.atoms.free(atom_id);
        try s.emitOpAtom(opcode.op.push_atom_value, atom_id);
    }
}

fn rewriteTrailingPutVarRefToSetVarRef(s: *ParseState, idx: u16) Error!void {
    const code = s.currentCode();
    if (idx < 4) {
        if (code.len < 1) return Error.UnexpectedToken;
        const expected = opcode.op.put_var_ref0 + @as(u8, @intCast(idx));
        if (code[code.len - 1] != expected) return Error.UnexpectedToken;
        code[code.len - 1] = opcode.op.set_var_ref0 + @as(u8, @intCast(idx));
        return;
    }

    if (code.len < 3) return Error.UnexpectedToken;
    if (code[code.len - 3] != opcode.op.put_var_ref) return Error.UnexpectedToken;
    const encoded_idx = std.mem.readInt(u16, code[code.len - 2 ..][0..2], .little);
    if (encoded_idx != idx) return Error.UnexpectedToken;
    code[code.len - 3] = opcode.op.set_var_ref;
}

fn parseEnumDeclaration(s: *ParseState) Error!void {
    try s.expectToken(tok.TOK_ENUM);
    if (s.peekKind() != tok.TOK_IDENT) return Error.UnexpectedToken;
    const enum_atom = s.token.payload.ident.atom;
    try s.advance();

    // Register variable in current scope if not exists
    const existing_var = s.cur_func().findVar(enum_atom);
    if (existing_var < 0) {
        _ = try s.addScopeVar(enum_atom, .normal, false, false);
    }

    // Emit Enum = Enum || {}
    try s.emitScopeGetVarUndef(enum_atom);
    try s.emitOp(opcode.op.dup);
    const skip_jump = try emitForwardJump(s, opcode.op.if_true);
    try s.emitOp(opcode.op.drop);
    try s.emitOp(opcode.op.object);
    try patchForwardJump(s, skip_jump);
    try s.emitScopePutVar(enum_atom);

    try s.expectToken('{');

    var counter: i32 = 0;
    while (s.peekKind() != '}' and s.peekKind() != tok.TOK_EOF) {
        if (!isIdentifierLikeToken(s)) return Error.UnexpectedToken;
        const member_atom = identifierLikeAtom(s);
        try s.advance();

        const member_name = s.lex.atoms.name(member_atom) orelse "";

        var is_string_init = false;
        if (s.peekKind() == '=') {
            try s.advance();
            if (s.peekKind() == tok.TOK_STRING) {
                const is_simple = s.peekNextKind() == ',' or s.peekNextKind() == '}';
                if (!is_simple) return Error.UnexpectedToken;
                is_string_init = true;
                // String initializer: emit Enum.Member = "string"
                try s.emitScopeGetVar(enum_atom);
                try emitStringLiteralValue(s, s.token.payload.str.bytes);
                try s.advance();
                try s.emitOpAtom(opcode.op.put_field, member_atom);
            } else {
                var has_explicit = false;
                var val: i32 = 0;
                if (s.peekKind() == tok.TOK_NUMBER) {
                    const is_simple = s.peekNextKind() == ',' or s.peekNextKind() == '}';
                    if (!is_simple) return Error.UnexpectedToken;
                    has_explicit = true;
                    val = @intFromFloat(s.token.payload.num.value);
                    try parseAssignExpr(s);
                } else if (s.peekKind() == '-' and s.peekNextKind() == tok.TOK_NUMBER) {
                    try s.advance(); // consume '-'
                    const is_simple = s.peekNextKind() == ',' or s.peekNextKind() == '}';
                    if (!is_simple) return Error.UnexpectedToken;
                    has_explicit = true;
                    val = -@as(i32, @intFromFloat(s.token.payload.num.value));
                    try s.emitOpI32(opcode.op.push_i32, val);
                    try s.advance(); // consume the number
                } else {
                    return Error.UnexpectedToken;
                }
                if (has_explicit) {
                    counter = val;
                }
            }
        } else {
            // No initializer: emit push_i32 counter
            try s.emitOpI32(opcode.op.push_i32, counter);
        }

        if (!is_string_init) {
            // Double mapping: Enum[Enum["Member"] = value] = "Member"
            try s.emitScopeGetVar(enum_atom); // Stack: [value, outer_obj]
            try s.emitOp(opcode.op.swap); // Stack: [outer_obj, value]
            try s.emitOp(opcode.op.dup); // Stack: [outer_obj, value, value]
            try s.emitScopeGetVar(enum_atom); // Stack: [outer_obj, value, value, inner_obj]
            try s.emitOp(opcode.op.swap); // Stack: [outer_obj, value, inner_obj, value]
            try s.emitOpAtom(opcode.op.put_field, member_atom); // Stack: [outer_obj, value]
            try emitStringLiteralValue(s, member_name); // Stack: [outer_obj, value, "Member"]
            try s.emitOp(opcode.op.put_array_el);
            counter += 1;
        }

        if (s.peekKind() == ',') {
            try s.advance();
        } else if (s.peekKind() != '}') {
            return Error.UnexpectedToken;
        }
    }

    try s.expectToken('}');
    s.last_declared_atom = enum_atom;

    if (s.namespace_export) {
        if (s.current_namespace_atom) |ns_atom| {
            try s.emitScopeGetVar(ns_atom);
            try s.emitScopeGetVar(enum_atom);
            try s.emitOpAtom(opcode.op.put_field, enum_atom);
        }
    }
}

fn parseNamespaceDeclaration(s: *ParseState) Error!void {
    try s.expectToken(tok.TOK_IDENT); // Already matched "namespace" in caller
    try parseNamespaceDeclarationWithIdent(s);
}

fn parseNamespaceDeclarationWithIdent(s: *ParseState) Error!void {
    if (s.peekKind() != tok.TOK_IDENT) return Error.UnexpectedToken;
    const ns_atom = s.token.payload.ident.atom;
    try s.advance();

    // Register variable in current scope if not exists
    const existing_var = s.cur_func().findVar(ns_atom);
    if (existing_var < 0) {
        _ = try s.addScopeVar(ns_atom, .normal, false, false);
    }

    // Emit Namespace = Namespace || {}
    try s.emitScopeGetVarUndef(ns_atom);
    try s.emitOp(opcode.op.dup);
    const skip_jump = try emitForwardJump(s, opcode.op.if_true);
    try s.emitOp(opcode.op.drop);
    try s.emitOp(opcode.op.object);
    try patchForwardJump(s, skip_jump);
    try s.emitScopePutVar(ns_atom);

    if (s.peekKind() == @as(tok.TokenKind, @intCast('.'))) {
        try s.advance(); // consume '.'

        try s.pushScope();
        const saved_in_namespace = s.in_namespace;
        const saved_namespace_atom = s.current_namespace_atom;
        s.in_namespace = true;
        s.current_namespace_atom = ns_atom;
        defer {
            s.in_namespace = saved_in_namespace;
            s.current_namespace_atom = saved_namespace_atom;
            s.popScope();
        }

        try parseNamespaceDeclarationWithIdent(s);

        if (s.last_declared_atom) |nested_atom| {
            try s.emitScopeGetVar(ns_atom);
            try s.emitScopeGetVar(nested_atom);
            try s.emitOpAtom(opcode.op.put_field, nested_atom);
        }

        s.last_declared_atom = ns_atom;
        if (s.namespace_export) {
            if (s.current_namespace_atom) |parent_ns| {
                try s.emitScopeGetVar(parent_ns);
                try s.emitScopeGetVar(ns_atom);
                try s.emitOpAtom(opcode.op.put_field, ns_atom);
            }
        }
        return;
    }

    try s.expectToken('{');
    try s.pushScope();
    const saved_in_namespace = s.in_namespace;
    const saved_namespace_atom = s.current_namespace_atom;
    s.in_namespace = true;
    s.current_namespace_atom = ns_atom;
    defer {
        s.in_namespace = saved_in_namespace;
        s.current_namespace_atom = saved_namespace_atom;
        s.popScope();
    }

    while (s.peekKind() != '}' and s.peekKind() != tok.TOK_EOF) {
        try parseNamespaceStatement(s);
    }

    try s.expectToken('}');
    s.last_declared_atom = ns_atom;

    if (s.namespace_export) {
        if (saved_namespace_atom) |parent_ns| {
            try s.emitScopeGetVar(parent_ns);
            try s.emitScopeGetVar(ns_atom);
            try s.emitOpAtom(opcode.op.put_field, ns_atom);
        }
    }
}

fn parseNamespaceStatement(s: *ParseState) Error!void {
    var is_exported = false;
    if (s.peekKind() == tok.TOK_EXPORT) {
        is_exported = true;
        try s.advance();
    }

    const saved_namespace_export = s.namespace_export;
    s.namespace_export = is_exported;
    defer s.namespace_export = saved_namespace_export;

    try parseStatementOrDecl(s, DeclMask{ .func = true, .func_with_label = true, .other = true });
}

/// Mirror `js_parse_statement_or_decl` (`quickjs.c:28228`).
pub fn parseStatementOrDecl(s: *ParseState, decl_mask: DeclMask) Error!void {
    s.features.insert(.statement);
    const tok_kind = s.peekKind();

    if (s.labelStartAtom()) |label_atom| {
        if (s.isReservedLabelIdentifier(label_atom)) return Error.UnexpectedToken;
        if (s.hasActiveLabel(label_atom)) return Error.UnexpectedToken;

        try s.advance();
        try s.expectToken(':');

        const labelled_kind = s.peekKind();
        if (labelled_kind == tok.TOK_WHILE or labelled_kind == tok.TOK_DO or labelled_kind == tok.TOK_FOR or labelled_kind == tok.TOK_SWITCH) {
            const saved_pending_label = s.pending_label_atom;
            s.pending_label_atom = label_atom;
            defer s.pending_label_atom = saved_pending_label;
            try parseStatementOrDecl(s, decl_mask);
            return;
        }

        const label_frame = try s.pushLabelFrame(label_atom, false);
        errdefer s.popLabelFrame(label_frame);
        if (labelled_kind == tok.TOK_CLASS or
            (labelled_kind == tok.TOK_FUNCTION and s.peekNextKind() == @as(tok.TokenKind, @intCast('*'))) or
            (labelled_kind == tok.TOK_IDENT and s.isIdent("async") and s.peekNextKind() == tok.TOK_FUNCTION))
        {
            return Error.UnexpectedToken;
        }
        const mask = if (!s.cur_func().is_strict_mode and decl_mask.func_with_label)
            DeclMask{ .func = true, .func_with_label = true }
        else
            DeclMask{};
        try parseStatementOrDecl(s, mask);
        try s.patchLabelBreaks(label_frame);
        s.popLabelFrame(label_frame);
        return;
    }

    switch (tok_kind) {
        '{' => try parseBlock(s),
        tok.TOK_STRING => {
            const keep_completion = expressionStatementKeepsCompletion(s);
            try parseExpr2(s, ParseFlags{ .in_accepted = true, .result_needed = keep_completion });
            _ = try s.expectSemicolon();
            if (keep_completion) {
                try s.emitScopePutVar(ParseState.eval_ret_atom);
            } else if (s.suppress_expr_statement_drop) {
                s.suppress_expr_statement_drop = false;
            } else {
                try s.emitOpNoSource(opcode.op.drop);
            }
        },
        tok.TOK_ENUM => {
            if (!s.lex.is_typescript) {
                return Error.UnexpectedToken;
            }
            try parseEnumDeclaration(s);
        },
        tok.TOK_RETURN => {
            if (s.is_eval or s.return_depth == 0) return Error.UnexpectedToken;
            try s.advance();
            const has_expr = s.peekKind() != ';' and s.peekKind() != '}' and !s.gotLineTerminator();
            if (try emitCapturedReturnThroughFinally(s, has_expr)) {
                // return is emitted after the active finally block completes normally.
            } else if (has_expr) {
                // When every active catch marker is a finally-less rethrow
                // marker, drop them before evaluating the return expression:
                // catch-and-rethrow equals plain propagation, and the
                // trailing call lands in tail position (HasCallInTailPosition
                // includes finally-less Catch blocks).
                const dropped_markers_early = !s.in_constructor and !s.in_async and
                    s.active_catch_marker_depth > 0 and
                    s.active_catch_marker_depth == s.droppable_rethrow_marker_count and
                    s.return_finally_frames.items.len == 0 and
                    !hasActiveIteratorCloses(s);
                if (dropped_markers_early) try emitCatchMarkerDropsToDepth(s, 0);
                const saved_return_expr_mode = s.return_expr_mode;
                const saved_return_expr_emitted = s.return_expr_emitted_return;
                s.return_expr_mode = true;
                s.return_expr_emitted_return = false;
                try parseExpr(s);
                const emitted_return = s.return_expr_emitted_return;
                s.return_expr_mode = saved_return_expr_mode;
                s.return_expr_emitted_return = saved_return_expr_emitted;
                if (!emitted_return) {
                    if (hasActiveIteratorCloses(s) or (!dropped_markers_early and s.active_catch_marker_depth > 0 and s.return_finally_frames.items.len == 0)) {
                        const return_tmp = try appendTempLocal(s);
                        try s.emitOpU16(opcode.op.put_loc, return_tmp);
                        try emitCatchMarkerDropsToDepth(s, 0);
                        try emitActiveIteratorCloses(s);
                        try s.emitOpU16(opcode.op.get_loc, return_tmp);
                    }
                    const tail_rewrite = if (!s.in_constructor and !s.in_async and !hasActiveIteratorCloses(s))
                        rewriteTrailingCallAsTailCall(s)
                    else
                        TrailingCallRewrite.none;
                    if (tail_rewrite != .rewrote) {
                        // QuickJS folds `return f(...)` into tail-call
                        // opcodes; short-circuit paths jumping past a
                        // rewritten call still need the return to land on.
                        try s.emitOp(if (s.in_async) opcode.op.return_async else opcode.op.@"return");
                    }
                }
            } else {
                if (s.active_catch_marker_depth > 0 and s.return_finally_frames.items.len == 0) {
                    try emitCatchMarkerDropsToDepth(s, 0);
                }
                try emitActiveIteratorCloses(s);
                try s.emitOp(opcode.op.return_undef);
            }
            _ = try s.expectSemicolon();
        },
        tok.TOK_THROW => {
            try s.advance();
            if (s.gotLineTerminator()) return Error.UnexpectedToken;
            try parseExpr(s);
            try s.emitOp(opcode.op.throw);
            _ = try s.expectSemicolon();
        },
        tok.TOK_VAR, tok.TOK_LET, tok.TOK_CONST => {
            if (tok_kind == tok.TOK_LET and canTreatLetAsExpressionStatement(s)) {
                try parseLetKeywordExpressionStatement(s);
                return;
            }
            if (s.lex.is_typescript and tok_kind == tok.TOK_CONST and s.peekNextKind() == tok.TOK_ENUM) {
                try s.advance();
                try parseEnumDeclaration(s);
                return;
            }
            if (!decl_mask.other and (tok_kind == tok.TOK_LET or tok_kind == tok.TOK_CONST)) {
                return Error.UnexpectedToken;
            }
            const var_tok = tok_kind;
            try s.advance();
            s.last_var_decl_atom = null;
            s.last_var_decl_can_skip_get = false;
            s.last_var_decl_ref_idx = null;
            try parseVar(s, var_tok, false, ParseFlags.default);
            _ = try s.expectSemicolon();
            if (var_tok == tok.TOK_VAR and
                s.last_var_decl_can_skip_get and
                s.last_var_decl_atom != null and
                s.peekKind() == tok.TOK_IDENT and
                s.token.payload.ident.atom == s.last_var_decl_atom.? and
                !isAssignmentLikeToken(s.peekNextKind()))
            {
                try rewriteTrailingPutVarRefToSetVarRef(s, s.last_var_decl_ref_idx orelse return Error.UnexpectedToken);
                s.skip_next_ident_get = s.last_var_decl_atom;
            }
        },
        tok.TOK_FUNCTION => {
            if (!decl_mask.func and !decl_mask.func_with_label) {
                return Error.UnexpectedToken;
            }
            // Check for async function
            const is_async = s.isIdent("async");
            const source_start = s.currentTokenStartOffset();
            if (is_async) {
                try s.advance();
            }
            const func_kind: ParseFunctionKind = if (is_async) .async else .normal;
            try parseFunctionDecl(s, func_kind, source_start);
        },
        tok.TOK_CLASS => {
            if (!decl_mask.func) {
                return Error.UnexpectedToken;
            }
            try parseClass(s, true);
        },
        tok.TOK_IDENT => {
            if (s.lex.is_typescript and s.isIdent("namespace") and s.peekNextKind() == tok.TOK_IDENT) {
                try parseNamespaceDeclaration(s);
                return;
            }
            if (usingDeclarationStart(s)) {
                if (!decl_mask.other) return Error.UnexpectedToken;
                try parseUsingDeclaration(s, .sync);
                _ = try s.expectSemicolon();
                return;
            }
            // Check for async function declaration (async is a contextual keyword)
            if (s.isIdent("async") and s.peekNextKindNoLineTerminator(tok.TOK_FUNCTION)) {
                if (!decl_mask.func and !decl_mask.func_with_label) {
                    return Error.UnexpectedToken;
                }
                const source_start = s.currentTokenStartOffset();
                try s.advance(); // consume async
                const func_kind: ParseFunctionKind = .async;
                try parseFunctionDecl(s, func_kind, source_start);
                return;
            }
            // Not async function: fall through to expression statement.
            // Like the `else` branch, eval mode redirects the value
            // into `<ret>` instead of dropping it.
            const keep_completion = expressionStatementKeepsCompletion(s);
            try parseExpr2(s, ParseFlags{ .in_accepted = true, .result_needed = keep_completion });
            _ = try s.expectSemicolon();
            if (keep_completion) {
                try s.emitScopePutVar(ParseState.eval_ret_atom);
            } else if (s.suppress_expr_statement_drop) {
                s.suppress_expr_statement_drop = false;
            } else {
                try s.emitOpNoSource(opcode.op.drop);
            }
        },
        tok.TOK_AWAIT => {
            if (awaitUsingDeclarationStart(s)) {
                if (!decl_mask.other) return Error.UnexpectedToken;
                try parseUsingDeclaration(s, .async);
                _ = try s.expectSemicolon();
                return;
            }
            const keep_completion = expressionStatementKeepsCompletion(s);
            try parseExpr2(s, ParseFlags{ .in_accepted = true, .result_needed = keep_completion });
            _ = try s.expectSemicolon();
            if (keep_completion) {
                try s.emitScopePutVar(ParseState.eval_ret_atom);
            } else if (s.suppress_expr_statement_drop) {
                s.suppress_expr_statement_drop = false;
            } else {
                try s.emitOpNoSource(opcode.op.drop);
            }
        },
        tok.TOK_IMPORT => {
            const import_next = s.peekNextKind();
            if (import_next == @as(tok.TokenKind, @intCast('(')) or import_next == @as(tok.TokenKind, @intCast('.'))) {
                const keep_completion = expressionStatementKeepsCompletion(s);
                try parseExpr2(s, ParseFlags{ .in_accepted = true, .result_needed = keep_completion });
                _ = try s.expectSemicolon();
                if (keep_completion) {
                    try s.emitScopePutVar(ParseState.eval_ret_atom);
                } else if (s.suppress_expr_statement_drop) {
                    s.suppress_expr_statement_drop = false;
                } else {
                    try s.emitOpNoSource(opcode.op.drop);
                }
                return;
            }
            if (!decl_mask.other or !canParseModuleDeclarationHere(s)) {
                return Error.UnexpectedToken;
            }
            try parseImport(s);
        },
        tok.TOK_EXPORT => {
            if (!decl_mask.other or !canParseModuleDeclarationHere(s)) {
                return Error.UnexpectedToken;
            }
            try parseExport(s);
        },
        tok.TOK_IF => {
            try s.advance();
            try s.setEvalReturnUndefined();
            try s.expectToken('(');
            try parseExpr2(s, ParseFlags{ .in_accepted = true, .result_needed = true });
            try s.expectToken(')');
            const if_false_off = try emitForwardJump(s, opcode.op.if_false);
            const allow_annex_b_if_function = !s.is_strict and !s.cur_func().is_strict_mode;
            const then_is_annex_b_function =
                allow_annex_b_if_function and
                s.peekKind() == tok.TOK_FUNCTION and
                s.peekNextKind() != @as(tok.TokenKind, @intCast('*'));
            const then_decl_mask = if (then_is_annex_b_function) DeclMask{ .func = true } else DeclMask{};
            const saved_annex_b_if_function_decl_clause = s.annex_b_if_function_decl_clause;
            s.annex_b_if_function_decl_clause = then_is_annex_b_function;
            defer s.annex_b_if_function_decl_clause = saved_annex_b_if_function_decl_clause;
            if (then_is_annex_b_function) {
                try s.pushScope();
                errdefer s.popScope();
                try parseStatementOrDecl(s, then_decl_mask);
                s.popScope();
            } else {
                try parseStatementOrDecl(s, then_decl_mask);
            }
            s.annex_b_if_function_decl_clause = saved_annex_b_if_function_decl_clause;
            if (s.peekKind() == tok.TOK_ELSE) {
                try s.advance();
                const else_goto_off = try emitForwardJump(s, opcode.op.goto);
                // Patch if_false to land at the start of the else block.
                try patchForwardJump(s, if_false_off);
                const else_is_annex_b_function =
                    allow_annex_b_if_function and
                    s.peekKind() == tok.TOK_FUNCTION and
                    s.peekNextKind() != @as(tok.TokenKind, @intCast('*'));
                const else_decl_mask = if (else_is_annex_b_function) DeclMask{ .func = true } else DeclMask{};
                s.annex_b_if_function_decl_clause = else_is_annex_b_function;
                if (else_is_annex_b_function) {
                    try s.pushScope();
                    errdefer s.popScope();
                    try parseStatementOrDecl(s, else_decl_mask);
                    s.popScope();
                } else {
                    try parseStatementOrDecl(s, else_decl_mask);
                }
                s.annex_b_if_function_decl_clause = saved_annex_b_if_function_decl_clause;
                // Patch the goto-over-else to land after the else block.
                try patchForwardJump(s, else_goto_off);
            } else {
                // No else: patch if_false to land just past the then block.
                try patchForwardJump(s, if_false_off);
            }
        },
        tok.TOK_WHILE => {
            try s.advance();
            const loop_label = s.pending_label_atom;
            s.pending_label_atom = null;
            try s.setEvalReturnUndefined();
            try s.expectToken('(');
            // Loop top: condition is evaluated each iteration.
            const top_pc: u32 = @intCast(s.currentCodeLen());
            try parseExpr(s);
            const exit_off = try emitForwardJump(s, opcode.op.if_false);
            try s.expectToken(')');
            try pushBreakFrame(s);
            const label_frame = if (loop_label) |atom_id| try s.pushLabelFrame(atom_id, true) else null;
            try parseStatementOrDecl(s, DeclMask{});
            try patchContinueFrame(s);
            if (label_frame) |idx| try s.patchLabelContinues(idx);
            // Back-edge to the top to re-test the condition.
            try emitBackwardJump(s, opcode.op.goto, top_pc);
            // Patch the if_false exit to land here.
            try patchForwardJump(s, exit_off);
            try popBreakFrameAndPatch(s);
            if (label_frame) |idx| {
                try s.patchLabelBreaks(idx);
                s.popLabelFrame(idx);
            }
        },
        tok.TOK_WITH => try parseWith(s),
        tok.TOK_DO => {
            try s.advance();
            const loop_label = s.pending_label_atom;
            s.pending_label_atom = null;
            try s.setEvalReturnUndefined();
            // Body starts at this pc; if_true at the bottom branches back here.
            const body_pc: u32 = @intCast(s.currentCodeLen());
            try pushBreakFrame(s);
            const label_frame = if (loop_label) |atom_id| try s.pushLabelFrame(atom_id, true) else null;
            try parseStatementOrDecl(s, DeclMask{});
            try patchContinueFrame(s);
            if (label_frame) |idx| try s.patchLabelContinues(idx);
            try s.expectToken(tok.TOK_WHILE);
            try s.expectToken('(');
            try parseExpr(s);
            try s.expectToken(')');
            // Back-edge: re-enter body when the test is truthy.
            try emitBackwardJump(s, opcode.op.if_true, body_pc);
            if (s.isPunct(';')) try s.advance();
            try popBreakFrameAndPatch(s);
            if (label_frame) |idx| {
                try s.patchLabelBreaks(idx);
                s.popLabelFrame(idx);
            }
        },
        tok.TOK_FOR => {
            try s.advance();
            const loop_label = s.pending_label_atom;
            s.pending_label_atom = null;
            try s.setEvalReturnUndefined();
            if (s.peekKind() == tok.TOK_AWAIT) {
                if (!s.in_async) return Error.AwaitOutsideAsyncFunction;
                try s.advance();
                try s.expectToken('(');
                s.pending_label_atom = loop_label;
                try parseForInOf(s, true);
                return;
            }
            try s.expectToken('(');

            // Check if this is for-in or for-of
            const is_for_in_of = s.checkForInOfHead();
            if (is_for_in_of) {
                s.pending_label_atom = loop_label;
                try parseForInOf(s, false);
            } else {
                var for_scope_pushed = false;
                var for_using_stack_loc: ?u16 = null;
                var for_using_kind: UsingStackKind = .sync;
                var for_using_catch_off: ?usize = null;
                var for_using_frame_active = false;
                var for_using_catch_active = false;
                errdefer {
                    if (for_using_frame_active) _ = s.using_block_frames.pop();
                    if (for_using_catch_active) s.active_catch_marker_depth -= 1;
                    if (for_scope_pushed) s.popScope();
                }
                // C-style `for (init ; test ; update) body`. Lower as:
                //   init
                //   top: test ; if_false → end ; body ; update ; goto → top
                //   end:
                // This pattern keeps `continue` semantics consistent by
                // routing continue targets through the update block.
                if (directUsingDeclarationKind(s)) |using_kind| {
                    for_using_kind = using_kind;
                    try s.pushScope();
                    for_scope_pushed = true;
                    const stack_loc = try emitCreateUsingDisposableStack(s, using_kind);
                    for_using_stack_loc = stack_loc;
                    const catch_off = try emitForwardJump(s, opcode.op.@"catch");
                    for_using_catch_off = catch_off;
                    s.active_catch_marker_depth += 1;
                    for_using_catch_active = true;
                    try s.using_block_frames.append(s.function.memory.allocator, .{
                        .stack_loc = stack_loc,
                        .catch_marker_depth = s.active_catch_marker_depth,
                        .kind = using_kind,
                    });
                    for_using_frame_active = true;
                    try parseUsingDeclaration(s, using_kind);
                    try s.expectToken(';');
                } else if ((s.peekKind() == tok.TOK_VAR or s.peekKind() == tok.TOK_LET or s.peekKind() == tok.TOK_CONST) and
                    !s.canTreatLetAsForInitializerExpression())
                {
                    const var_tok = s.peekKind();
                    try s.advance();
                    if (var_tok == tok.TOK_LET or var_tok == tok.TOK_CONST) {
                        try s.pushScope();
                        for_scope_pushed = true;
                    }
                    const saved_tdz_at_decl = s.emit_lexical_tdz_at_decl;
                    s.emit_lexical_tdz_at_decl = for_scope_pushed;
                    defer s.emit_lexical_tdz_at_decl = saved_tdz_at_decl;
                    try parseVar(s, var_tok, false, ParseFlags{ .in_accepted = false });
                    try s.expectToken(';');
                    if (for_scope_pushed and for_using_stack_loc == null) try s.emitCloseCurrentScopeLexicals();
                } else if (s.peekKind() != ';') {
                    try parseExpr2(s, ParseFlags{ .in_accepted = false });
                    try s.emitOp(opcode.op.drop);
                    try s.expectToken(';');
                } else {
                    try s.advance(); // consume ';'
                }

                // Top of the loop — re-tested each iteration.
                try s.emitOpU32(opcode.op.label, 0);
                const top_pc: u32 = @intCast(s.currentCodeLen());

                // Test condition.
                if (s.peekKind() != ';') {
                    try parseExpr(s);
                } else {
                    try s.emitOp(opcode.op.push_true);
                }
                try s.expectToken(';');

                const exit_off = try emitForwardJump(s, opcode.op.if_false);

                // Parse the update while still inside the parenthesized
                // for-head, then move its emitted bytes after the body.
                const update_start = s.currentCodeLen();
                if (s.peekKind() != ')') {
                    try parseExpr(s);
                    try s.emitOp(opcode.op.drop);
                }
                const update_code = s.currentCode()[update_start..];
                var saved_update: []u8 = &.{};
                if (update_code.len != 0) {
                    saved_update = try s.function.memory.alloc(u8, update_code.len);
                    @memcpy(saved_update, update_code);
                }
                defer if (saved_update.len != 0) s.function.memory.free(u8, saved_update);
                try s.truncateCode(update_start);
                try s.expectToken(')');
                if (for_scope_pushed) {
                    if (s.last_var_decl_atom) |atom_id| {
                        if (forInBlockBodyVarDeclaresName(s, atom_id)) return Error.UnexpectedToken;
                    }
                }

                // Body.
                try pushBreakFrame(s);
                const label_frame = if (loop_label) |atom_id| try s.pushLabelFrame(atom_id, true) else null;
                try parseStatementOrDecl(s, DeclMask{});

                // Update: run after normal body completion and continue paths.
                try patchContinueFrame(s);
                if (label_frame) |idx| try s.patchLabelContinues(idx);
                if (for_scope_pushed and for_using_stack_loc == null) try s.emitCloseCurrentScopeLexicals();
                if (saved_update.len != 0) {
                    try relocateMovedJumpTargets(saved_update, update_start, s.currentCodeLen());
                    try s.appendBytes(saved_update);
                }

                // Back-edge to the top.
                try emitBackwardJump(s, opcode.op.goto, top_pc);

                // Patch the `if_false` exit to land here.
                try patchForwardJump(s, exit_off);
                try popBreakFrameAndPatch(s);
                if (label_frame) |idx| {
                    try s.patchLabelBreaks(idx);
                    s.popLabelFrame(idx);
                }
                if (for_using_stack_loc) |stack_loc| {
                    s.active_catch_marker_depth -= 1;
                    for_using_catch_active = false;
                    try s.emitOp(opcode.op.drop);
                    try emitUsingDisposeStack(s, for_using_kind, stack_loc);
                    try s.emitCloseLoc(stack_loc);
                    if (for_scope_pushed) try s.emitCloseCurrentScopeLexicals();
                    const end_off = try emitForwardJump(s, opcode.op.goto);
                    try patchForwardJump(s, for_using_catch_off orelse return Error.UnexpectedToken);
                    try emitUsingDisposeStackForThrow(s, for_using_kind, stack_loc);
                    try patchForwardJump(s, end_off);
                    _ = s.using_block_frames.pop();
                    for_using_frame_active = false;
                }
                if (for_scope_pushed) {
                    s.popScope();
                    for_scope_pushed = false;
                }
            }
        },
        tok.TOK_BREAK, tok.TOK_CONTINUE => {
            const is_break = s.peekKind() == tok.TOK_BREAK;
            try s.advance();
            var label_atom: ?Atom = null;
            if (!s.gotLineTerminator() and isIdentifierLikeToken(s)) {
                const atom_id = identifierLikeAtom(s);
                if (s.peekKind() == tok.TOK_IDENT and escapedIdentifierIsReservedWordForCurrentContext(s, atom_id, s.token.payload.ident.has_escape)) return Error.UnexpectedToken;
                label_atom = atom_id;
                try s.advance(); // consume the label name
            }
            _ = try s.expectSemicolon();
            if (label_atom) |atom_id| {
                if (is_break) {
                    try s.emitLabelledBreak(atom_id);
                } else {
                    try s.emitLabelledContinue(atom_id);
                }
                return;
            }
            if (is_break) {
                if (s.break_frame_lens.items.len == 0) return Error.UnexpectedToken;
                try emitUnlabelledBreak(s);
            } else {
                if (s.continue_frame_lens.items.len == 0) return Error.UnexpectedToken;
                try emitUnlabelledContinue(s);
            }
        },
        tok.TOK_SWITCH => {
            // Simplified switch lowering. Each case checks the discriminant,
            // and a matched case runs its body then jumps to the end (i.e.
            // an *implicit* break). C-style fallthrough between cases is
            // deferred to the fuller switch lowering.
            try s.advance();
            const switch_label = s.pending_label_atom;
            s.pending_label_atom = null;
            try s.expectToken('(');
            try s.setEvalReturnUndefined();
            try parseExpr(s); // discriminant on stack
            try s.expectToken(')');
            try s.expectToken('{');
            try validateSwitchCaseBlockDeclarations(s);
            try s.pushScope();
            errdefer s.popScope();
            try s.emitEnterScope();
            const saved_switch_case_block_scope = s.in_switch_case_block_scope;
            s.in_switch_case_block_scope = true;
            defer s.in_switch_case_block_scope = saved_switch_case_block_scope;
            try pushBreakOnlyFrame(s);
            setCurrentBreakCrossCleanupDrops(s, 1);
            enterSwitchContinueCleanup(s);
            defer leaveSwitchContinueCleanup(s);
            const label_frame = if (switch_label) |atom_id| try s.pushLabelFrame(atom_id, false) else null;

            // Keep unmatched case-test exits separate from matched
            // fallthrough jumps: once a case has matched, later case tests
            // are skipped and only their bodies run.
            var no_match_jumps: [64]usize = undefined;
            var no_match_jumps_count: usize = 0;
            var fallthrough_jump: ?usize = null;
            var has_default = false;
            var default_body_start: ?u32 = null;
            var default_waiting_for_body = false;

            while (s.peekKind() != '}' and s.peekKind() != tok.TOK_EOF) {
                if (s.peekKind() == tok.TOK_CASE) {
                    for (no_match_jumps[0..no_match_jumps_count]) |off| {
                        try patchForwardJump(s, off);
                    }
                    no_match_jumps_count = 0;

                    try s.advance();
                    // dup ; case_expr ; strict_eq ; if_false → next_case
                    try s.emitOp(opcode.op.dup);
                    try parseExpr(s);
                    try s.expectToken(':');
                    try s.emitOp(opcode.op.strict_eq);
                    const next_case_off = try emitForwardJump(s, opcode.op.if_false);
                    if (no_match_jumps_count >= no_match_jumps.len) return Error.UnexpectedToken;
                    no_match_jumps[no_match_jumps_count] = next_case_off;
                    no_match_jumps_count += 1;
                    if (fallthrough_jump) |off| {
                        try patchForwardJump(s, off);
                        fallthrough_jump = null;
                    }

                    // Matched: keep the discriminant on stack until the
                    // common switch epilogue, matching QuickJS's case shape.
                    const body_start = s.currentCodeLen();
                    const has_case_body = s.peekKind() != tok.TOK_CASE and
                        s.peekKind() != tok.TOK_DEFAULT and
                        s.peekKind() != '}' and
                        s.peekKind() != tok.TOK_EOF;
                    if (default_waiting_for_body and has_case_body) {
                        default_body_start = @intCast(body_start);
                        default_waiting_for_body = false;
                    }
                    const break_count_before_body = s.break_fixups.items.len;
                    while (s.peekKind() != tok.TOK_CASE and
                        s.peekKind() != tok.TOK_DEFAULT and
                        s.peekKind() != '}' and
                        s.peekKind() != tok.TOK_EOF)
                    {
                        try parseStatementOrDecl(s, DeclMask{ .func = true, .func_with_label = true, .other = true });
                    }
                    if ((s.peekKind() == tok.TOK_CASE or s.peekKind() == tok.TOK_DEFAULT) and
                        s.break_fixups.items.len == break_count_before_body and
                        caseCanFallthrough(s))
                    {
                        fallthrough_jump = try emitForwardJump(s, opcode.op.goto);
                    }
                } else if (s.peekKind() == tok.TOK_DEFAULT) {
                    if (has_default) return Error.UnexpectedToken;
                    try s.advance();
                    try s.expectToken(':');
                    if (no_match_jumps_count == 0) {
                        if (no_match_jumps_count >= no_match_jumps.len) return Error.UnexpectedToken;
                        no_match_jumps[no_match_jumps_count] = try emitForwardJump(s, opcode.op.goto);
                        no_match_jumps_count += 1;
                    }
                    const body_start = s.currentCodeLen();
                    if (fallthrough_jump) |off| {
                        try patchForwardJump(s, off);
                        fallthrough_jump = null;
                    }

                    // Default body label.
                    has_default = true;
                    const break_count_before_body = s.break_fixups.items.len;
                    while (s.peekKind() != tok.TOK_CASE and
                        s.peekKind() != tok.TOK_DEFAULT and
                        s.peekKind() != '}' and
                        s.peekKind() != tok.TOK_EOF)
                    {
                        try parseStatementOrDecl(s, DeclMask{ .func = true, .func_with_label = true, .other = true });
                    }
                    if (s.currentCodeLen() == body_start and s.peekKind() == tok.TOK_CASE) {
                        default_waiting_for_body = true;
                    } else {
                        default_body_start = @intCast(body_start);
                        default_waiting_for_body = false;
                    }
                    if (s.peekKind() == tok.TOK_CASE and
                        s.break_fixups.items.len == break_count_before_body and
                        caseCanFallthrough(s))
                    {
                        fallthrough_jump = try emitForwardJump(s, opcode.op.goto);
                    }
                } else {
                    return Error.UnexpectedToken;
                }
            }
            try s.expectToken('}');

            // No case matched — jump to default if it exists, otherwise fall
            // through to the common discriminant drop.
            for (no_match_jumps[0..no_match_jumps_count]) |off| {
                if (default_body_start) |target| {
                    try patchJumpTarget(s, off, target);
                } else {
                    try patchForwardJump(s, off);
                }
            }
            if (fallthrough_jump) |off| try patchForwardJump(s, off);
            try popBreakOnlyFrameAndPatch(s);
            if (label_frame) |idx| {
                try s.patchLabelBreaks(idx);
                s.popLabelFrame(idx);
            }
            try s.emitOp(opcode.op.drop);
            s.popScope();
        },
        tok.TOK_TRY => {
            try s.advance();
            try s.setEvalReturnUndefined();
            const has_finally = try tryStatementHasFinally(s);
            const return_finally_frame = if (has_finally) try pushReturnFinallyFrame(s) else null;
            const catch_off = try emitForwardJump(s, opcode.op.@"catch");
            s.active_catch_marker_depth += 1;
            try parseBlock(s);
            s.active_catch_marker_depth -= 1;
            try s.emitOp(opcode.op.drop);
            const end_off = try emitForwardJump(s, opcode.op.goto);
            if (s.peekKind() == tok.TOK_CATCH) {
                try s.advance();
                try patchForwardJump(s, catch_off);
                try s.pushScope();
                try s.emitEnterScope();
                var catch_bound_atom: ?Atom = null;
                if (s.peekKind() == '{') {
                    try s.emitOp(opcode.op.drop);
                } else {
                    try s.expectToken('(');
                    if (s.peekKind() == '[' or s.peekKind() == '{') {
                        if (s.peekKind() == '[' and try catchArrayPatternHasDuplicateNames(s)) return Error.UnexpectedToken;
                        const temp_idx = try appendTempLocal(s);
                        try s.emitOpU16(opcode.op.put_loc, temp_idx);
                        const kind: DestructuringKind = if (s.peekKind() == '[') .array else .object;
                        const saved_binding_is_lexical = s.destructuring_binding_is_lexical;
                        const saved_binding_is_const = s.destructuring_binding_is_const;
                        const saved_suppress_retrofit = s.suppress_destructuring_capture_retrofit;
                        s.destructuring_binding_is_lexical = true;
                        s.destructuring_binding_is_const = false;
                        s.suppress_destructuring_capture_retrofit = true;
                        defer {
                            s.destructuring_binding_is_lexical = saved_binding_is_lexical;
                            s.destructuring_binding_is_const = saved_binding_is_const;
                            s.suppress_destructuring_capture_retrofit = saved_suppress_retrofit;
                        }
                        try parseDestructuringPattern(s, kind, BindingSource{ .loc = temp_idx });
                    } else {
                        if (!isIdentifierLikeToken(s)) return Error.UnexpectedToken;
                        const catch_atom = if (s.peekKind() == tok.TOK_IDENT)
                            s.token.payload.ident.atom
                        else
                            tok.keywordAtom(s.peekKind());
                        if ((s.is_strict or s.cur_func().is_strict_mode) and
                            (atomNameEquals(s, catch_atom, "eval") or atomNameEquals(s, catch_atom, "arguments")))
                        {
                            return Error.UnexpectedToken;
                        }
                        catch_bound_atom = catch_atom;
                        _ = try s.addScopeVar(catch_atom, .normal, false, false);
                        try s.advance();
                        try s.emitScopePutVar(catch_atom);
                    }
                    try s.expectToken(')');
                }
                if (catch_bound_atom) |atom_id| {
                    if (try catchBlockHasDirectLexicalDeclaration(s, atom_id)) return Error.UnexpectedToken;
                }
                const rethrow_off = try emitForwardJump(s, opcode.op.@"catch");
                s.active_catch_marker_depth += 1;
                // Without a finally, this marker only re-throws: a `return`
                // in the catch body may drop it up front, putting a trailing
                // call into tail position (sec-static-semantics-
                // hascallintailposition lists finally-less Catch blocks).
                if (!has_finally) s.droppable_rethrow_marker_count += 1;
                try parseBlock(s);
                if (!has_finally) s.droppable_rethrow_marker_count -= 1;
                s.active_catch_marker_depth -= 1;
                try s.emitOp(opcode.op.drop);
                const catch_end_off = try emitForwardJump(s, opcode.op.goto);
                try patchForwardJump(s, rethrow_off);
                if (has_finally and s.peekKind() == tok.TOK_FINALLY) {
                    const before_finally = takeParserSnapshot(s);
                    try s.advance();
                    try parseFinallyBlockForAbruptPath(s, return_finally_frame orelse return Error.UnexpectedToken);
                    restoreParserLexerSnapshot(s, before_finally);
                }
                try s.emitOp(opcode.op.throw);
                try patchForwardJump(s, end_off);
                try patchForwardJump(s, catch_end_off);
                s.popScope();
            } else if (s.peekKind() == tok.TOK_FINALLY) {
                const normal_finally_off = end_off;
                try patchForwardJump(s, catch_off);
                try s.advance();
                const finally_snapshot = takeParserSnapshot(s);
                try parseFinallyBlockForAbruptPath(s, return_finally_frame orelse return Error.UnexpectedToken);
                try s.emitOp(opcode.op.throw);
                if (return_finally_frame) |idx| try emitControlFinallyCopies(s, idx, finally_snapshot);
                if (return_finally_frame) |idx| try emitReturnFinallyCopy(s, idx, finally_snapshot);
                try patchForwardJump(s, normal_finally_off);
                restoreParserLexerSnapshot(s, finally_snapshot);
                try parseFinallyBlockForReturnPath(s, return_finally_frame orelse return Error.UnexpectedToken);
                if (return_finally_frame) |idx| popReturnFinallyFrame(s, idx);
                return;
            } else {
                return Error.UnexpectedToken;
            }
            if (s.peekKind() == tok.TOK_FINALLY) {
                try s.advance();
                const finally_snapshot = takeParserSnapshot(s);
                if (return_finally_frame) |idx| try emitControlFinallyCopies(s, idx, finally_snapshot);
                if (return_finally_frame) |idx| try emitReturnFinallyCopy(s, idx, finally_snapshot);
                restoreParserLexerSnapshot(s, finally_snapshot);
                try parseFinallyBlockForReturnPath(s, return_finally_frame orelse return Error.UnexpectedToken);
                if (return_finally_frame) |idx| popReturnFinallyFrame(s, idx);
            }
        },
        tok.TOK_DEBUGGER => {
            try s.advance();
            _ = try s.expectSemicolon();
        },
        ';' => {
            // Empty statement
            try s.advance();
        },
        else => {
            // Expression statement.
            //
            // Mirrors `quickjs.c:28960`: in eval mode, the last
            // value is stored in `eval_ret_idx` so `eval()` can
            // return it; otherwise it's dropped. `<ret>` is a
            // non-lexical slot so the lowered bytecode is just
            // `put_loc <idx>` (or short form), which the pipeline
            // handles transparently.
            const keep_completion = expressionStatementKeepsCompletion(s);
            try parseExpr2(s, ParseFlags{ .in_accepted = true, .result_needed = keep_completion });
            _ = try s.expectSemicolon();
            if (keep_completion) {
                try s.emitScopePutVar(ParseState.eval_ret_atom);
            } else if (s.suppress_expr_statement_drop) {
                s.suppress_expr_statement_drop = false;
            } else {
                try s.emitOpNoSource(opcode.op.drop);
            }
        },
    }
}

fn parseUsingDeclaration(s: *ParseState, kind: UsingStackKind) Error!void {
    const module_top_level = s.lex.is_module and
        s.top_level_lexical_as_module_ref and
        s.cur_func_stack.len == 0 and
        s.scope_level == 0;
    if (kind == .async and !s.in_async and !module_top_level) return Error.AwaitOutsideAsyncFunction;
    if ((!module_top_level and s.scope_level == 0) or s.using_block_frames.items.len == 0) return Error.UnexpectedToken;
    const stack_loc = s.using_block_frames.items[s.using_block_frames.items.len - 1].stack_loc orelse return Error.UnexpectedToken;
    if (kind == .async) try s.advance(); // consume `await`
    try s.advance(); // consume `using`

    while (true) {
        if (!isIdentifierLikeToken(s)) return Error.UnexpectedToken;
        if (identifierLikeHasInvalidEscapeForBinding(s)) return Error.UnexpectedToken;
        const atom_id = identifierLikeAtom(s);
        if (atomNameEquals(s, atom_id, "let")) return Error.UnexpectedToken;
        if ((s.is_strict or s.cur_func().is_strict_mode) and
            (atomNameEquals(s, atom_id, "eval") or atomNameEquals(s, atom_id, "arguments")))
        {
            return Error.UnexpectedToken;
        }
        try s.registerBlockLexicalDeclaration(atom_id);
        if (module_top_level) {
            if (ParseState.findClosureVarIndex(s.cur_func(), atom_id) != null) return Error.UnexpectedToken;
            _ = try ensureTopLevelModuleDeclClosureVar(s, atom_id, true, true);
        } else {
            if (findCurrentScopeVar(s, atom_id) != null) return Error.UnexpectedToken;
            if (s.scope_level == 1 and s.cur_func().findArg(atom_id) >= 0) return Error.UnexpectedToken;
            const local_idx: u16 = @intCast(try s.addScopeVar(atom_id, .normal, true, true));
            try s.retrofitForwardLocalFunctionCapture(s.cur_func(), atom_id, local_idx);
        }
        try s.advance();

        if (s.peekKind() != '=') return Error.UnexpectedToken;
        try s.advance();
        {
            s.last_anonymous_function_expr = false;
            const saved_pending_name = s.pending_function_name;
            const saved_pending_decl = s.pending_function_is_decl;
            s.pending_function_name = atom_id;
            s.pending_function_is_decl = false;
            defer {
                s.pending_function_name = saved_pending_name;
                s.pending_function_is_decl = saved_pending_decl;
            }
            try parseAssignExpr(s);
            if (s.last_anonymous_function_expr) {
                try s.emitOpAtom(opcode.op.set_name, atom_id);
                s.last_anonymous_function_expr = false;
            }
        }
        try s.emitOp(opcode.op.dup);
        try s.emitScopePutVarInit(atom_id);
        const resource_loc = try appendAnonymousTempLocal(s);
        try s.emitOpU16(opcode.op.put_loc, resource_loc);
        try emitUsingAddResource(s, kind, stack_loc, resource_loc);
        try s.emitCloseLoc(resource_loc);

        if (s.peekKind() != ',') break;
        try s.advance();
    }
}

fn canParseModuleDeclarationHere(s: *ParseState) bool {
    return s.lex.is_module and s.cur_func_stack.len == 0 and s.scope_level == 0;
}

fn canTreatLetAsExpressionStatement(s: *ParseState) bool {
    const saved_pos = s.lex.pos;
    const saved_line = s.lex.line;
    const saved_col = s.lex.col;
    const saved_mark_pos = s.lex.mark_pos;
    const saved_mark_line = s.lex.mark_line;
    const saved_mark_col = s.lex.mark_col;
    const current_line = s.token.line_num;
    const peek_token = s.lex.next() catch return false;
    defer {
        s.lex.freeToken(@constCast(&peek_token));
        s.lex.pos = saved_pos;
        s.lex.line = saved_line;
        s.lex.col = saved_col;
        s.lex.mark_pos = saved_mark_pos;
        s.lex.mark_line = saved_mark_line;
        s.lex.mark_col = saved_mark_col;
    }
    if (peek_token.line_num == current_line) {
        return peek_token.val == @as(tok.TokenKind, @intCast('=')) or
            peek_token.val == @as(tok.TokenKind, @intCast(';'));
    }
    return peek_token.val == @as(tok.TokenKind, @intCast('{')) or peek_token.val == tok.TOK_IDENT;
}

fn parseLetKeywordExpressionStatement(s: *ParseState) Error!void {
    const keep_completion = expressionStatementKeepsCompletion(s);
    try parseExpr2(s, ParseFlags{ .in_accepted = true, .result_needed = keep_completion });
    _ = try s.expectSemicolon();
    if (keep_completion) {
        try s.emitScopePutVar(ParseState.eval_ret_atom);
    } else if (s.suppress_expr_statement_drop) {
        s.suppress_expr_statement_drop = false;
    } else {
        try s.emitOpNoSource(opcode.op.drop);
    }
}

fn tryStatementHasFinally(s: *ParseState) Error!bool {
    const snapshot = takeParserSnapshot(s);
    defer restoreParserLexerSnapshot(s, snapshot);
    try skipBlockForTryScan(s);
    if (s.peekKind() == tok.TOK_CATCH) {
        try s.advance();
        if (s.peekKind() == '(') {
            try skipBalancedDelimitedForTryScan(s, '(', ')');
        }
        try skipBlockForTryScan(s);
    }
    return s.peekKind() == tok.TOK_FINALLY;
}

fn skipBlockForTryScan(s: *ParseState) Error!void {
    if (s.peekKind() != '{') return Error.UnexpectedToken;
    try skipBalancedDelimitedForTryScan(s, '{', '}');
}

fn skipBalancedDelimitedForTryScan(s: *ParseState, open: tok.TokenKind, close: tok.TokenKind) Error!void {
    if (s.peekKind() != open) return Error.UnexpectedToken;
    var depth: usize = 0;
    var previous_token_kind: ?tok.TokenKind = null;
    while (true) {
        const kind = s.peekKind();
        if (kind == tok.TOK_EOF) return Error.UnexpectedToken;
        if (kind == tok.TOK_TEMPLATE) {
            try skipTemplateInPredeclareScan(s, s.token);
            try s.advance();
            previous_token_kind = tok.TOK_TEMPLATE;
            continue;
        }
        if (tokenCanStartSlashRegexp(kind)) {
            if (try skipRegexpInPredeclareScan(s, previous_token_kind)) {
                try s.advance();
                previous_token_kind = tok.TOK_REGEXP;
                continue;
            }
        }
        if (kind == open) depth += 1;
        if (kind == close) {
            depth -= 1;
            try s.advance();
            previous_token_kind = kind;
            if (depth == 0) return;
            continue;
        }
        try s.advance();
        previous_token_kind = kind;
    }
}

fn remainingBlockHasDirectFunctionDeclarationName(s: *ParseState, target: Atom) Error!bool {
    const snapshot = takeParserSnapshot(s);
    defer restoreParserLexerSnapshot(s, snapshot);

    var depth: usize = 0;
    while (s.peekKind() != tok.TOK_EOF) {
        const kind = s.peekKind();
        if (kind == @as(tok.TokenKind, @intCast('}'))) {
            if (depth == 0) return false;
            depth -= 1;
            s.advance() catch return false;
            continue;
        }
        if (kind == @as(tok.TokenKind, @intCast('{'))) {
            depth += 1;
            s.advance() catch return false;
            continue;
        }
        if (kind == tok.TOK_TEMPLATE) {
            skipTemplateInPredeclareScan(s, s.token) catch return false;
            s.advance() catch return false;
            continue;
        }
        if (depth == 0 and kind == tok.TOK_FUNCTION) {
            s.advance() catch return false;
            if (s.peekKind() == @as(tok.TokenKind, @intCast('*'))) s.advance() catch return false;
            if (isIdentifierLikeToken(s) and identifierLikeAtom(s) == target) return true;
            while (s.peekKind() != tok.TOK_EOF and s.peekKind() != @as(tok.TokenKind, @intCast('{'))) {
                s.advance() catch return false;
            }
            if (s.peekKind() == @as(tok.TokenKind, @intCast('{'))) {
                skipBalancedDelimitedForTryScan(s, '{', '}') catch return false;
            }
            continue;
        }
        s.advance() catch return false;
    }
    return false;
}

fn skipFunctionDeclarationInTokenScan(s: *ParseState) Error!void {
    if (s.peekKind() != tok.TOK_FUNCTION) return Error.UnexpectedToken;
    while (s.peekKind() != tok.TOK_EOF and s.peekKind() != @as(tok.TokenKind, @intCast('{'))) {
        try s.advance();
    }
    if (s.peekKind() == @as(tok.TokenKind, @intCast('{'))) {
        try skipBalancedDelimitedForTryScan(s, '{', '}');
    }
}

fn skipSingleStatementInTokenScan(s: *ParseState) Error!void {
    switch (s.peekKind()) {
        ';' => try s.advance(),
        @as(tok.TokenKind, @intCast('{')) => try skipBalancedDelimitedForTryScan(s, '{', '}'),
        tok.TOK_FUNCTION => try skipFunctionDeclarationInTokenScan(s),
        tok.TOK_IF => _ = try skipAnnexBIfFunctionDeclarationsInScan(s),
        else => {
            while (s.peekKind() != tok.TOK_EOF and
                s.peekKind() != @as(tok.TokenKind, @intCast(';')) and
                s.peekKind() != tok.TOK_ELSE and
                s.peekKind() != tok.TOK_CASE and
                s.peekKind() != tok.TOK_DEFAULT and
                s.peekKind() != @as(tok.TokenKind, @intCast('}')))
            {
                if (s.peekKind() == tok.TOK_TEMPLATE) {
                    try skipTemplateInPredeclareScan(s, s.token);
                    try s.advance();
                    continue;
                }
                try s.advance();
            }
            if (s.peekKind() == @as(tok.TokenKind, @intCast(';'))) try s.advance();
        },
    }
}

fn skipAnnexBIfFunctionDeclarationsInScan(s: *ParseState) Error!bool {
    if (s.peekKind() != tok.TOK_IF) return false;
    try s.advance();
    try skipBalancedDelimitedForTryScan(s, '(', ')');
    if (s.peekKind() == tok.TOK_FUNCTION) {
        try skipFunctionDeclarationInTokenScan(s);
    } else {
        try skipSingleStatementInTokenScan(s);
    }
    if (s.peekKind() == tok.TOK_ELSE) {
        try s.advance();
        if (s.peekKind() == tok.TOK_FUNCTION) {
            try skipFunctionDeclarationInTokenScan(s);
        } else {
            try skipSingleStatementInTokenScan(s);
        }
    }
    return true;
}

fn pushReturnFinallyFrame(s: *ParseState) Error!usize {
    const temp_name = try std.fmt.allocPrint(s.function.memory.allocator, "__finally_return_{d}", .{s.with_scope_id});
    defer s.function.memory.allocator.free(temp_name);
    s.with_scope_id += 1;
    const temp_atom = try s.function.atoms.internString(temp_name);
    defer s.function.atoms.free(temp_atom);
    const value_loc: u16 = @intCast(try s.addScopeVar(temp_atom, .normal, false, false));
    try s.return_finally_frames.append(s.function.memory.allocator, .{
        .value_loc = value_loc,
        .catch_marker_depth = s.active_catch_marker_depth,
        .break_depth = s.break_frame_lens.items.len,
        .continue_depth = s.continue_frame_lens.items.len,
        .label_depth = s.label_frames.items.len,
    });
    return s.return_finally_frames.items.len - 1;
}

fn popReturnFinallyFrame(s: *ParseState, frame_index: usize) void {
    std.debug.assert(frame_index + 1 == s.return_finally_frames.items.len);
    s.return_finally_frames.items[frame_index].deinit(s.function.memory.allocator);
    _ = s.return_finally_frames.pop().?;
}

fn enterReturnFinallyFunctionBoundary(s: *ParseState) ReturnFinallyBoundary {
    const saved = ReturnFinallyBoundary{
        .frames = s.return_finally_frames,
        .suppress_capture = s.suppress_return_finally_capture,
        .suppress_capture_depth = s.suppress_return_finally_capture_depth,
        .suppress_capture_end = s.suppress_return_finally_capture_end,
        .pending_abrupt_frames = s.finally_pending_abrupt_frames,
    };
    s.return_finally_frames = .empty;
    s.suppress_return_finally_capture = 0;
    s.suppress_return_finally_capture_depth = 0;
    s.suppress_return_finally_capture_end = 0;
    s.finally_pending_abrupt_frames = .empty;
    return saved;
}

fn leaveReturnFinallyFunctionBoundary(s: *ParseState, saved: ReturnFinallyBoundary) void {
    for (s.return_finally_frames.items) |*frame| {
        frame.deinit(s.function.memory.allocator);
    }
    s.return_finally_frames.deinit(s.function.memory.allocator);
    s.return_finally_frames = saved.frames;
    s.suppress_return_finally_capture = saved.suppress_capture;
    s.suppress_return_finally_capture_depth = saved.suppress_capture_depth;
    s.suppress_return_finally_capture_end = saved.suppress_capture_end;
    s.finally_pending_abrupt_frames.deinit(s.function.memory.allocator);
    s.finally_pending_abrupt_frames = saved.pending_abrupt_frames;
}

fn emitReturnFinallyCopy(s: *ParseState, frame_index: usize, finally_snapshot: ParserSnapshot) Error!void {
    if (s.return_finally_frames.items[frame_index].fixups.items.len == 0) return;
    const skip_return_off = try emitForwardJump(s, opcode.op.goto);
    for (s.return_finally_frames.items[frame_index].fixups.items) |off| {
        try patchForwardJump(s, off);
    }
    restoreParserLexerSnapshot(s, finally_snapshot);
    try parseFinallyBlockForReturnPath(s, frame_index);
    try emitReturnAfterFinallyCopy(s, frame_index);
    try patchForwardJump(s, skip_return_off);
}

fn emitControlFinallyCopies(s: *ParseState, frame_index: usize, finally_snapshot: ParserSnapshot) Error!void {
    try emitOneControlFinallyCopy(s, frame_index, finally_snapshot, .{ .kind = .@"continue" });
    try emitOneControlFinallyCopy(s, frame_index, finally_snapshot, .{ .kind = .@"break" });
    try emitLabelledControlFinallyCopies(s, frame_index, finally_snapshot, .@"continue");
    try emitLabelledControlFinallyCopies(s, frame_index, finally_snapshot, .@"break");
}

fn emitOneControlFinallyCopy(
    s: *ParseState,
    frame_index: usize,
    finally_snapshot: ParserSnapshot,
    target: FinallyControlTarget,
) Error!void {
    const fixups = switch (target.kind) {
        .@"break" => s.return_finally_frames.items[frame_index].break_fixups.items,
        .@"continue" => s.return_finally_frames.items[frame_index].continue_fixups.items,
    };
    if (fixups.len == 0) return;
    const skip_control_off = try emitForwardJump(s, opcode.op.goto);
    for (fixups) |off| {
        try patchForwardJump(s, off);
    }
    restoreParserLexerSnapshot(s, finally_snapshot);
    try parseFinallyBlockForReturnPath(s, frame_index);
    try emitControlAfterFinallyCopy(s, frame_index, target);
    try patchForwardJump(s, skip_control_off);
}

fn emitLabelledControlFinallyCopies(
    s: *ParseState,
    frame_index: usize,
    finally_snapshot: ParserSnapshot,
    kind: FinallyControlKind,
) Error!void {
    const fixups = switch (kind) {
        .@"break" => s.return_finally_frames.items[frame_index].labelled_break_fixups.items,
        .@"continue" => s.return_finally_frames.items[frame_index].labelled_continue_fixups.items,
    };
    for (fixups) |fixup| {
        const skip_control_off = try emitForwardJump(s, opcode.op.goto);
        try patchForwardJump(s, fixup.off);
        restoreParserLexerSnapshot(s, finally_snapshot);
        try parseFinallyBlockForReturnPath(s, frame_index);
        try emitControlAfterFinallyCopy(s, frame_index, .{
            .kind = kind,
            .label_atom = fixup.atom_id,
        });
        try patchForwardJump(s, skip_control_off);
    }
}

fn emitReturnAfterFinallyCopy(s: *ParseState, current_frame_index: usize) Error!void {
    if (nearestReturnFinallyFrameForReturn(s, current_frame_index)) |target_frame_index| {
        try s.emitOpU16(opcode.op.get_loc, s.return_finally_frames.items[current_frame_index].value_loc);
        try emitStackTopReturnThroughFinallyFrame(s, target_frame_index, true);
        return;
    }
    try emitPendingAbruptDropsForReturn(s);
    try emitActiveIteratorCloses(s);
    try s.emitOpU16(opcode.op.get_loc, s.return_finally_frames.items[current_frame_index].value_loc);
    try s.emitOp(if (s.in_async) opcode.op.return_async else opcode.op.@"return");
}

fn emitControlAfterFinallyCopy(s: *ParseState, current_frame_index: usize, target: FinallyControlTarget) Error!void {
    if (try nearestReturnFinallyFrameForControl(s, target, current_frame_index)) |target_frame_index| {
        try emitCapturedControlThroughFinallyFrame(s, target_frame_index, target, true);
        return;
    }
    switch (target.kind) {
        .@"break" => if (target.label_atom) |atom_id|
            try s.emitLabelledBreakNoFinallyCapture(atom_id)
        else
            try emitUnlabelledBreakNoFinallyCapture(s),
        .@"continue" => if (target.label_atom) |atom_id|
            try s.emitLabelledContinueNoFinallyCapture(atom_id)
        else
            try emitUnlabelledContinueNoFinallyCapture(s),
    }
}

fn emitCapturedReturnThroughFinally(s: *ParseState, has_expr: bool) Error!bool {
    const frame_index = nearestReturnFinallyFrameForReturn(s, null) orelse return false;
    if (has_expr) {
        try parseExpr(s);
    } else {
        try s.emitOp(opcode.op.undefined);
    }
    try emitStackTopReturnThroughFinallyFrame(s, frame_index, shouldDropPendingAbruptForCapture(s, frame_index));
    return true;
}

fn emitCapturedControlThroughFinally(s: *ParseState, target: FinallyControlTarget) Error!bool {
    const frame_index = (try nearestReturnFinallyFrameForControl(s, target, null)) orelse return false;
    try emitCapturedControlThroughFinallyFrame(s, frame_index, target, shouldDropPendingAbruptForCapture(s, frame_index));
    return true;
}

fn emitCapturedControlThroughFinallyFrame(s: *ParseState, frame_index: usize, target: FinallyControlTarget, drop_pending_abrupt: bool) Error!void {
    try emitCatchMarkerDropsToDepth(s, s.return_finally_frames.items[frame_index].catch_marker_depth);
    if (drop_pending_abrupt) try emitPendingAbruptDropsForControlTarget(s, target);
    const off = try emitForwardJump(s, opcode.op.goto);
    switch (target.kind) {
        .@"break" => if (target.label_atom) |atom_id|
            try s.return_finally_frames.items[frame_index].labelled_break_fixups.append(s.function.memory.allocator, .{
                .off = off,
                .atom_id = atom_id,
            })
        else
            try s.return_finally_frames.items[frame_index].break_fixups.append(s.function.memory.allocator, off),
        .@"continue" => if (target.label_atom) |atom_id|
            try s.return_finally_frames.items[frame_index].labelled_continue_fixups.append(s.function.memory.allocator, .{
                .off = off,
                .atom_id = atom_id,
            })
        else
            try s.return_finally_frames.items[frame_index].continue_fixups.append(s.function.memory.allocator, off),
    }
}

fn emitPendingAbruptDropsForControlTarget(s: *ParseState, target: FinallyControlTarget) Error!void {
    if (target.label_atom) |atom_id| {
        const label_frame_index = s.findLabelFrame(atom_id) orelse return Error.UnexpectedToken;
        try emitPendingAbruptDropsForLabel(s, label_frame_index);
        return;
    }
    switch (target.kind) {
        .@"break" => try emitPendingAbruptDropsForUnlabelledBreak(s),
        .@"continue" => try emitPendingAbruptDropsForUnlabelledContinue(s),
    }
}

fn nearestReturnFinallyFrameForReturn(s: *ParseState, exclude_frame_index: ?usize) ?usize {
    var i = s.return_finally_frames.items.len;
    while (i != 0) {
        i -= 1;
        if (exclude_frame_index != null and i == exclude_frame_index.?) continue;
        if (returnFinallyFrameSuppressed(s, i)) continue;
        return i;
    }
    return null;
}

fn nearestReturnFinallyFrameForControl(s: *ParseState, target: FinallyControlTarget, exclude_frame_index: ?usize) Error!?usize {
    var i = s.return_finally_frames.items.len;
    while (i != 0) {
        i -= 1;
        if (exclude_frame_index != null and i == exclude_frame_index.?) continue;
        if (returnFinallyFrameSuppressed(s, i)) continue;
        if (try controlTargetCrossesFinallyFrame(s, target, i)) return i;
    }
    return null;
}

fn controlTargetCrossesFinallyFrame(s: *ParseState, target: FinallyControlTarget, frame_index: usize) Error!bool {
    const frame = s.return_finally_frames.items[frame_index];
    if (target.label_atom) |atom_id| {
        const label_frame_index = s.findLabelFrame(atom_id) orelse return Error.UnexpectedToken;
        if (target.kind == .@"continue" and !s.label_frames.items[label_frame_index].allow_continue) return Error.UnexpectedToken;
        return label_frame_index < frame.label_depth;
    }
    return switch (target.kind) {
        .@"break" => s.break_frame_lens.items.len <= frame.break_depth,
        .@"continue" => s.continue_frame_lens.items.len <= frame.continue_depth,
    };
}

fn returnFinallyFrameSuppressed(s: *const ParseState, frame_index: usize) bool {
    return s.suppress_return_finally_capture != 0 and
        frame_index >= s.suppress_return_finally_capture_depth and
        frame_index < s.suppress_return_finally_capture_end;
}

fn shouldDropPendingAbruptForCapture(s: *const ParseState, frame_index: usize) bool {
    if (s.finally_pending_abrupt_frames.items.len == 0) return false;
    if (s.suppress_return_finally_capture == 0) return true;
    return frame_index < s.suppress_return_finally_capture_depth;
}

fn enterReturnFinallyFrameSuppression(s: *ParseState, frame_index: usize) ReturnFinallyCaptureSuppression {
    std.debug.assert(frame_index < s.return_finally_frames.items.len);
    const saved = ReturnFinallyCaptureSuppression{
        .count = s.suppress_return_finally_capture,
        .depth = s.suppress_return_finally_capture_depth,
        .end = s.suppress_return_finally_capture_end,
    };
    if (s.suppress_return_finally_capture == 0) {
        s.suppress_return_finally_capture_depth = frame_index;
        s.suppress_return_finally_capture_end = frame_index + 1;
    } else {
        s.suppress_return_finally_capture_depth = @min(s.suppress_return_finally_capture_depth, frame_index);
        s.suppress_return_finally_capture_end = @max(s.suppress_return_finally_capture_end, frame_index + 1);
    }
    s.suppress_return_finally_capture += 1;
    return saved;
}

fn leaveReturnFinallyFrameSuppression(s: *ParseState, saved: ReturnFinallyCaptureSuppression) void {
    s.suppress_return_finally_capture = saved.count;
    s.suppress_return_finally_capture_depth = saved.depth;
    s.suppress_return_finally_capture_end = saved.end;
}

fn parseFinallyBlockForReturnPath(s: *ParseState, frame_index: usize) Error!void {
    const saved_suppression = enterReturnFinallyFrameSuppression(s, frame_index);
    defer leaveReturnFinallyFrameSuppression(s, saved_suppression);
    try parseFinallyBlockPreservingNormalEvalRet(s);
}

fn parseFinallyBlockForAbruptPath(s: *ParseState, frame_index: usize) Error!void {
    try s.finally_pending_abrupt_frames.append(s.function.memory.allocator, .{
        .break_depth = s.break_frame_lens.items.len,
        .continue_depth = s.continue_frame_lens.items.len,
        .label_depth = s.label_frames.items.len,
    });
    defer _ = s.finally_pending_abrupt_frames.pop().?;
    try parseFinallyBlockForReturnPath(s, frame_index);
}

fn parseFinallyBlockPreservingNormalEvalRet(s: *ParseState) Error!void {
    if (s.eval_ret_idx < 0) {
        try parseBlock(s);
        return;
    }

    const temp_name = try std.fmt.allocPrint(s.function.memory.allocator, "__finally_ret_{d}", .{s.with_scope_id});
    defer s.function.memory.allocator.free(temp_name);
    s.with_scope_id += 1;
    const temp_atom = try s.function.atoms.internString(temp_name);
    defer s.function.atoms.free(temp_atom);
    _ = try s.addScopeVar(temp_atom, .normal, false, false);

    try s.emitScopeGetVar(ParseState.eval_ret_atom);
    try s.emitScopePutVar(temp_atom);
    try s.setEvalReturnUndefined();
    try parseBlock(s);
    try s.emitScopeGetVar(temp_atom);
    try s.emitScopePutVar(ParseState.eval_ret_atom);
}

fn catchArrayPatternHasDuplicateNames(s: *ParseState) Error!bool {
    const snapshot = takeParserSnapshot(s);
    defer restoreParserLexerSnapshot(s, snapshot);

    var names = std.ArrayList(Atom).empty;
    defer names.deinit(s.function.memory.allocator);

    var depth: usize = 0;
    var expect_binding = false;
    while (s.peekKind() != tok.TOK_EOF) {
        const kind = s.peekKind();
        if (kind == '[') {
            depth += 1;
            expect_binding = true;
            try s.advance();
            continue;
        }
        if (kind == ']') {
            if (depth == 0) return false;
            depth -= 1;
            try s.advance();
            if (depth == 0) break;
            expect_binding = false;
            continue;
        }
        if (kind == ',' or kind == tok.TOK_ELLIPSIS) {
            expect_binding = true;
            try s.advance();
            continue;
        }
        if (kind == '{') {
            var object_depth: usize = 0;
            while (s.peekKind() != tok.TOK_EOF) {
                if (s.peekKind() == '{') object_depth += 1;
                if (s.peekKind() == '}') {
                    if (object_depth == 0) break;
                    object_depth -= 1;
                    try s.advance();
                    if (object_depth == 0) break;
                    continue;
                }
                try s.advance();
            }
            expect_binding = false;
            continue;
        }
        if (expect_binding and kind == tok.TOK_IDENT) {
            const atom_id = s.token.payload.ident.atom;
            for (names.items) |seen| {
                if (seen == atom_id) return true;
            }
            try names.append(s.function.memory.allocator, atom_id);
            expect_binding = false;
        } else {
            expect_binding = false;
        }
        try s.advance();
    }
    return false;
}

fn catchBlockHasDirectLexicalDeclaration(s: *ParseState, atom_id: Atom) Error!bool {
    if (s.peekKind() != '{') return false;
    const snapshot = takeParserSnapshot(s);
    defer restoreParserLexerSnapshot(s, snapshot);

    var depth: usize = 0;
    while (s.peekKind() != tok.TOK_EOF) {
        const kind = s.peekKind();
        if (kind == '{') {
            depth += 1;
            try s.advance();
            continue;
        }
        if (kind == '}') {
            if (depth == 0) return false;
            depth -= 1;
            try s.advance();
            if (depth == 0) break;
            continue;
        }
        if (kind == tok.TOK_TEMPLATE) {
            try skipTemplateInPredeclareScan(s, s.token);
            try s.advance();
            continue;
        }
        if (depth == 1 and (kind == tok.TOK_LET or kind == tok.TOK_CONST or kind == tok.TOK_CLASS)) {
            try s.advance();
            if (s.peekKind() == tok.TOK_IDENT and s.token.payload.ident.atom == atom_id) return true;
            continue;
        }
        if (depth == 1 and kind == tok.TOK_IF and try skipAnnexBIfFunctionDeclarationsInScan(s)) continue;
        if (depth == 1 and kind == tok.TOK_FUNCTION) {
            try s.advance();
            if (s.peekKind() == @as(tok.TokenKind, @intCast('*'))) try s.advance();
            if (s.peekKind() == tok.TOK_IDENT and s.token.payload.ident.atom == atom_id) return true;
            continue;
        }
        try s.advance();
    }
    return false;
}

fn patchForwardJump(s: *ParseState, operand_offset: usize) Error!void {
    var code = s.currentCode();
    if (operand_offset + 4 > code.len) return Error.UnexpectedToken;
    const target: u32 = @intCast(code.len);
    std.mem.writeInt(u32, code[operand_offset..][0..4], target, .little);
}

fn patchJumpTarget(s: *ParseState, operand_offset: usize, target: u32) Error!void {
    var code = s.currentCode();
    if (operand_offset + 4 > code.len) return Error.UnexpectedToken;
    std.mem.writeInt(u32, code[operand_offset..][0..4], target, .little);
}

fn patchAbsoluteTarget(s: *ParseState, operand_offset: usize) Error!void {
    var code = s.currentCode();
    if (operand_offset + 4 > code.len) return Error.UnexpectedToken;
    std.mem.writeInt(u32, code[operand_offset..][0..4], @intCast(code.len), .little);
}

fn relocateMovedJumpTargets(code: []u8, old_start: usize, new_start: usize) Error!void {
    if (new_start == old_start) return;
    const old_end = old_start + code.len;
    var pc: usize = 0;
    while (pc < code.len) {
        const op_id = code[pc];
        const size: usize = @intCast(opcode.sizeOf(op_id));
        if (size == 0 or pc + size > code.len) return;
        if (op_id == opcode.op.if_false or op_id == opcode.op.if_true or op_id == opcode.op.goto) {
            const target = std.mem.readInt(u32, code[pc + 1 ..][0..4], .little);
            if (target >= old_start and target <= old_end) {
                const shifted = new_start + (@as(usize, @intCast(target)) - old_start);
                std.mem.writeInt(u32, code[pc + 1 ..][0..4], @intCast(shifted), .little);
            }
        }
        pc += size;
    }
}

/// Mirror `js_parse_var` (`quickjs.c:27847`).
///
/// Registers each identifier in `function_def.vars` with the correct
/// `VarKind` / `is_lexical` / `is_const` flags so the full
/// FunctionDef-based pipeline can assign local slots, emit TDZ checks,
/// and synthesise closures. For `var`, the
/// variable is attached at the function's var/arg scope (level 0)
/// per QuickJS hoisting rules; for `let`/`const`, it attaches at the
/// current lexical scope.
fn parseVar(s: *ParseState, var_tok: tok.TokenKind, export_decl: bool, parse_flags: ParseFlags) Error!void {
    const is_lexical = var_tok == tok.TOK_LET or var_tok == tok.TOK_CONST or s.in_namespace;
    const is_const = var_tok == tok.TOK_CONST;
    while (true) {
        const sloppy_keyword_var = (s.peekKind() == tok.TOK_YIELD or
            s.peekKind() == tok.TOK_STATIC or
            s.peekKind() == tok.TOK_LET or
            s.peekKind() == tok.TOK_AWAIT or
            isSloppyFutureReservedBindingToken(s)) and
            !(s.is_strict or s.cur_func().is_strict_mode) and
            !(s.peekKind() == tok.TOK_YIELD and s.in_generator) and
            !(s.peekKind() == tok.TOK_AWAIT and !canUseAwaitAsIdentifier(s));
        const binding_identifier = isIdentifierLikeToken(s);
        if (binding_identifier or sloppy_keyword_var) {
            // Simple identifier binding
            const atom_id = if (s.peekKind() == tok.TOK_IDENT) s.token.payload.ident.atom else tok.keywordAtom(s.peekKind());
            if (binding_identifier and s.peekKind() == tok.TOK_IDENT and
                escapedIdentifierIsReservedWordForBinding(s, atom_id, s.token.payload.ident.has_escape))
            {
                return Error.UnexpectedToken;
            }
            if (is_lexical and atomNameEquals(s, atom_id, "let")) return Error.UnexpectedToken;
            if ((s.is_strict or s.cur_func().is_strict_mode) and
                (atomNameEquals(s, atom_id, "eval") or atomNameEquals(s, atom_id, "arguments")))
            {
                return Error.UnexpectedToken;
            }
            if (!is_lexical) {
                try s.registerBlockVarDeclaration(atom_id);
                if (findCurrentScopeVar(s, atom_id)) |existing_idx| {
                    if (s.cur_func().vars[existing_idx].is_lexical) return Error.UnexpectedToken;
                }
                if (s.top_level_lexical_as_module_ref and s.scope_level == 0) {
                    if (ParseState.findClosureVarIndex(s.cur_func(), atom_id)) |existing_ref_idx| {
                        if (s.cur_func().closure_var[existing_ref_idx].is_lexical) return Error.UnexpectedToken;
                    }
                }
            } else {
                try s.registerBlockLexicalDeclaration(atom_id);
                if (findCurrentScopeVar(s, atom_id) != null) return Error.UnexpectedToken;
                if (s.top_level_lexical_as_module_ref and s.scope_level == 0 and ParseState.findClosureVarIndex(s.cur_func(), atom_id) != null) {
                    return Error.UnexpectedToken;
                }
                if (s.scope_level == 1 and s.cur_func().findArg(atom_id) >= 0) {
                    return Error.UnexpectedToken;
                }
            }
            s.last_var_decl_atom = atom_id;
            if (export_decl) try addModuleExportName(s, atom_id, atom_id);
            var top_level_var_ref_idx: ?u16 = null;
            var local_lexical_idx: ?u16 = null;
            try s.advance();

            // Register the declaration in `function_def.vars`. For
            // `var`, QuickJS hoists to scope 0 (`add_func_var_def`
            // / `add_arguments_var`); for `let`/`const` the current
            // lexical scope is correct.
            if (s.top_level_lexical_as_module_ref and s.scope_level == 0) {
                if (!is_lexical) {
                    top_level_var_ref_idx = ParseState.findClosureVarIndex(s.cur_func(), atom_id);
                }
                if (top_level_var_ref_idx == null) {
                    const ref_idx = try s.cur_func().addClosureVar(.{
                        .closure_type = .module_decl,
                        .is_lexical = is_lexical,
                        .is_const = is_const,
                        .var_kind = .normal,
                        .var_idx = @intCast(s.cur_func().closure_var.len),
                        .var_name = atom_id,
                    });
                    top_level_var_ref_idx = @intCast(ref_idx);
                    try s.retrofitForwardTopLevelModuleCapture(s.cur_func(), atom_id, top_level_var_ref_idx.?, is_lexical, is_const, .normal);
                }
            } else if (is_lexical) {
                local_lexical_idx = @intCast(try s.addScopeVar(atom_id, .normal, true, is_const));
                try s.retrofitForwardLocalFunctionCapture(s.cur_func(), atom_id, local_lexical_idx.?);
                if (s.cur_func_stack.len == 0 and s.scope_level == 0 and !s.is_eval and !s.top_level_lexical_as_module_ref) {
                    try s.addGlobalVar(atom_id, true, is_const);
                }
                if (s.emit_lexical_tdz_at_decl) {
                    s.cur_func().vars[local_lexical_idx.?].tdz_emitted_at_decl = true;
                }
            } else if (s.cur_func_stack.len == 0 and (!s.is_eval or s.eval_global_var_bindings)) {
                try s.addGlobalVar(atom_id, false, false);
            } else {
                // Hoist `var` to function scope (level 0).
                const existing_var = s.cur_func().findVar(atom_id);
                if (existing_var < 0) {
                    const saved = s.scope_level;
                    s.scope_level = 0;
                    defer s.scope_level = saved;
                    const var_idx = try s.addScopeVar(atom_id, .normal, false, false);
                    try s.retrofitForwardLocalFunctionCapture(s.cur_func(), atom_id, @intCast(var_idx));
                    if (atomNameEquals(s, atom_id, "arguments")) {
                        s.cur_func().arguments_var_idx = @intCast(var_idx);
                    }
                } else if (atomNameEquals(s, atom_id, "arguments")) {
                    s.cur_func().arguments_var_idx = existing_var;
                }
            }

            if (local_lexical_idx) |idx| {
                if (s.cur_func().use_short_opcodes and s.emit_lexical_tdz_at_decl) {
                    try s.emitOpU16(opcode.op.set_loc_uninitialized, idx);
                }
            }

            // Check for initializer
            if (s.peekKind() == '=') {
                try s.advance();
                s.last_anonymous_function_expr = false;
                const saved_pending_name = s.pending_function_name;
                const saved_pending_decl = s.pending_function_is_decl;
                s.pending_function_name = atom_id;
                s.pending_function_is_decl = false;
                defer {
                    s.pending_function_name = saved_pending_name;
                    s.pending_function_is_decl = saved_pending_decl;
                }
                const with_initializer_binding = if (!is_lexical and s.active_with_func_depth == s.cur_func_stack.len) s.active_with_atom else null;
                if (with_initializer_binding) |with_atom| {
                    try emitWithGetRefFallback(s, with_atom, atom_id);
                    try s.emitOp(opcode.op.drop);
                }
                try parseAssignExpr2(s, parse_flags);
                if (s.last_anonymous_function_expr) {
                    try s.emitOpAtom(opcode.op.set_name, atom_id);
                    s.last_anonymous_function_expr = false;
                }
                // Emit the proper scope-init opcode so the value is actually
                // stored in the var's slot. The pipeline (`resolve_variables`)
                // lowers these to
                // `put_loc` when the var resolves locally, or to
                // `put_var_init` / `put_var` for global lexical /
                // hoisted-global cases.
                if (top_level_var_ref_idx) |ref_idx| {
                    if (is_lexical) {
                        try s.emitScopePutVarInit(atom_id);
                    } else {
                        try s.emitPutVarRef(ref_idx);
                        s.last_var_decl_can_skip_get = true;
                        s.last_var_decl_ref_idx = ref_idx;
                    }
                } else if (is_lexical) {
                    try s.emitScopePutVarInit(atom_id);
                } else if (with_initializer_binding != null) {
                    try emitPutWithRefKeep(s, atom_id, .none);
                } else {
                    try s.emitScopePutVar(atom_id);
                }
            } else {
                // const requires initializer
                if (var_tok == tok.TOK_CONST) {
                    return Error.UnexpectedToken;
                }
                // `let x;` (no initializer) implicitly initialises to
                // undefined. We emit `undefined; scope_put_var_init`
                // so the slot is properly marked initialised — the
                // pipeline lowers this to `put_loc_check_init` for
                // lexical locals (clears TDZ flag) or `put_var_init`
                // for global lexical vars.
                if (var_tok == tok.TOK_LET) {
                    try s.emitOp(opcode.op.undefined);
                    try s.emitScopePutVarInit(atom_id);
                }
            }
            if (s.namespace_export) {
                if (s.current_namespace_atom) |ns_atom| {
                    try s.emitScopeGetVar(ns_atom);
                    try s.emitScopeGetVar(atom_id);
                    try s.emitOpAtom(opcode.op.put_field, atom_id);
                }
            }
        } else if (s.peekKind() == '[' or s.peekKind() == '{') {
            const pattern_snapshot = takeParserSnapshot(s);
            const kind: DestructuringKind = if (s.peekKind() == '[') .array else .object;
            if (is_lexical) {
                const saved_binding_is_lexical = s.destructuring_binding_is_lexical;
                const saved_binding_is_const = s.destructuring_binding_is_const;
                const saved_predeclare_only = s.destructuring_predeclare_only;
                const saved_collect_module_export_bindings = s.collect_module_export_bindings;
                s.destructuring_binding_is_lexical = true;
                s.destructuring_binding_is_const = is_const;
                s.destructuring_predeclare_only = true;
                s.collect_module_export_bindings = export_decl;
                errdefer {
                    s.destructuring_binding_is_lexical = saved_binding_is_lexical;
                    s.destructuring_binding_is_const = saved_binding_is_const;
                    s.destructuring_predeclare_only = saved_predeclare_only;
                    s.collect_module_export_bindings = saved_collect_module_export_bindings;
                }
                try parseDestructuringPattern(s, kind, null);
                s.destructuring_binding_is_lexical = saved_binding_is_lexical;
                s.destructuring_binding_is_const = saved_binding_is_const;
                s.destructuring_predeclare_only = saved_predeclare_only;
                s.collect_module_export_bindings = saved_collect_module_export_bindings;
            } else {
                const saved_binding_is_lexical = s.destructuring_binding_is_lexical;
                const saved_binding_is_const = s.destructuring_binding_is_const;
                const saved_predeclare_only = s.destructuring_predeclare_only;
                const saved_collect_module_export_bindings = s.collect_module_export_bindings;
                s.destructuring_binding_is_lexical = false;
                s.destructuring_binding_is_const = false;
                s.destructuring_predeclare_only = true;
                s.collect_module_export_bindings = export_decl;
                defer {
                    s.destructuring_binding_is_lexical = saved_binding_is_lexical;
                    s.destructuring_binding_is_const = saved_binding_is_const;
                    s.destructuring_predeclare_only = saved_predeclare_only;
                    s.collect_module_export_bindings = saved_collect_module_export_bindings;
                }
                try parseDestructuringPattern(s, kind, null);
            }
            try truncateSpeculativeParse(s, pattern_snapshot.code_len, pattern_snapshot.atom_len);
            if (s.peekKind() != '=') return Error.UnexpectedToken;
            try s.advance();
            try parseAssignExpr2(s, parse_flags);
            const temp_idx = try appendTempLocal(s);
            try s.emitOpU16(opcode.op.put_loc, temp_idx);
            const after_initializer = takeParserSnapshot(s);
            restoreParserLexerSnapshot(s, pattern_snapshot);
            const saved_binding_is_lexical = s.destructuring_binding_is_lexical;
            const saved_binding_is_const = s.destructuring_binding_is_const;
            const saved_predeclare_only = s.destructuring_predeclare_only;
            s.destructuring_binding_is_lexical = is_lexical;
            s.destructuring_binding_is_const = is_const;
            s.destructuring_predeclare_only = false;
            defer {
                s.destructuring_binding_is_lexical = saved_binding_is_lexical;
                s.destructuring_binding_is_const = saved_binding_is_const;
                s.destructuring_predeclare_only = saved_predeclare_only;
            }
            try parseDestructuringPattern(s, kind, BindingSource{ .loc = temp_idx });
            restoreParserLexerSnapshot(s, after_initializer);
        } else {
            return Error.UnexpectedToken;
        }

        // Check for comma (multiple declarations)
        if (s.peekKind() != ',') break;
        try s.advance();
    }
}

fn parseWith(s: *ParseState) Error!void {
    if (s.is_strict or s.cur_func().is_strict_mode) return Error.UnexpectedToken;
    try s.advance();
    try s.expectToken('(');
    try parseExpr(s);
    try s.expectToken(')');

    const with_name = try std.fmt.allocPrint(s.function.memory.allocator, "__with_obj_{d}", .{s.with_scope_id});
    defer s.function.memory.allocator.free(with_name);
    s.with_scope_id += 1;
    const with_atom = try s.function.atoms.internString(with_name);
    defer s.function.atoms.free(with_atom);
    const with_idx = try appendBindingLocal(s, with_atom);
    const active_with_name = try std.fmt.allocPrint(s.function.memory.allocator, "__active_with_obj_{d}", .{s.with_scope_id - 1});
    defer s.function.memory.allocator.free(active_with_name);
    const active_with_atom = try s.function.atoms.internString(active_with_name);
    defer s.function.atoms.free(active_with_atom);
    const active_with_idx = try appendBindingLocal(s, active_with_atom);
    try s.emitOp(opcode.op.to_object);
    try s.emitOp(opcode.op.dup);
    try s.emitOpU16(opcode.op.put_loc, with_idx);
    try s.emitOpU16(opcode.op.put_loc, active_with_idx);

    const saved_with_atom = s.active_with_atom;
    const saved_with_func_depth = s.active_with_func_depth;
    s.active_with_atom = with_atom;
    s.active_with_func_depth = s.cur_func_stack.len;
    defer {
        s.active_with_atom = saved_with_atom;
        s.active_with_func_depth = saved_with_func_depth;
    }
    try s.setEvalReturnUndefined();
    try parseStatementOrDecl(s, DeclMask{});
    try s.emitOp(opcode.op.undefined);
    try s.emitOpU16(opcode.op.put_loc, active_with_idx);
}

fn validateForInOfGenericAssignmentTarget(s: *ParseState, shape: LhsShape) Error!void {
    switch (shape) {
        .none => return Error.InvalidAssignmentTarget,
        .invalid_call => {
            if (s.is_strict or s.cur_func().is_strict_mode) return Error.InvalidAssignmentTarget;
        },
        .var_ref => |v| {
            if ((s.is_strict or s.cur_func().is_strict_mode) and
                (atomNameEquals(s, v.atom, "eval") or atomNameEquals(s, v.atom, "arguments")))
            {
                return Error.InvalidAssignmentTarget;
            }
        },
        .dotted, .super_dotted, .indexed, .with_ref => {},
    }
}

fn emitForInOfGenericAssignmentTarget(s: *ParseState, target_point: LexerReplayPoint) Error!void {
    const value_loc = try appendAnonymousTempLocal(s);
    try s.emitOpU16(opcode.op.put_loc, value_loc);

    const after_target = takeParserSnapshot(s);
    var restored = false;
    errdefer if (!restored) restoreParserLexerSnapshot(s, after_target);
    try restoreLexerReplayPoint(s, target_point);
    const saved_atom: ?Atom = if (peekParenthesizedBareIdent(s)) |ident| blk: {
        break :blk ident;
    } else if (isIdentifierLikeToken(s)) blk: {
        break :blk identifierLikeAtom(s);
    } else null;
    const pre_lhs_code_len = s.currentCodeLen();
    const pre_lhs_atom_len = s.currentAtomOperandLen();
    const saved_force_with_lvalue = s.force_with_lvalue;
    s.force_with_lvalue = true;
    defer s.force_with_lvalue = saved_force_with_lvalue;
    try parseLhsExpr(s, .{ .in_accepted = false });
    const shape = classifyLhs(s, pre_lhs_code_len, pre_lhs_atom_len, saved_atom);
    try validateForInOfGenericAssignmentTarget(s, shape);
    restoreParserLexerSnapshot(s, after_target);
    restored = true;

    switch (shape) {
        .var_ref => |v| {
            try s.truncateCode(v.code_pos);
            try s.truncateAtomOperands(pre_lhs_atom_len);
            try s.emitOpU16(opcode.op.get_loc, value_loc);
            try s.emitScopePutVar(v.atom);
        },
        .dotted => |d| {
            try s.truncateCode(d.code_pos);
            const atom_len = s.currentAtomOperandLen();
            if (atom_len == 0) return Error.UnexpectedToken;
            try s.truncateAtomOperands(atom_len - 1);
            try s.emitOpU16(opcode.op.get_loc, value_loc);
            try s.emitOpAtom(opcode.op.put_field, d.atom);
        },
        .super_dotted => |d| {
            try s.truncateCode(d.code_pos);
            try s.emitOpU16(opcode.op.get_loc, value_loc);
            try s.emitOp(opcode.op.put_super_value);
        },
        .indexed => |i| {
            try s.truncateCode(i.code_pos);
            try s.emitOpU16(opcode.op.get_loc, value_loc);
            try s.emitOp(opcode.op.put_array_el);
        },
        .with_ref => |w| {
            try s.truncateCode(pre_lhs_code_len);
            try s.truncateAtomOperands(pre_lhs_atom_len);
            try emitWithMakeRefFallback(s, s.active_with_atom orelse return Error.UnexpectedToken, w.atom);
            try s.emitOpU16(opcode.op.get_loc, value_loc);
            try emitPutWithRefKeep(s, w.atom, .none);
        },
        .invalid_call => {
            try s.emitOpAtomU8(opcode.op.throw_error, atom_module.null_atom, 2);
            return;
        },
        .none => return Error.InvalidAssignmentTarget,
    }
    try s.emitCloseLoc(value_loc);
}

fn declareForInOfVarBinding(s: *ParseState, atom_id: Atom) Error!void {
    if (s.top_level_lexical_as_module_ref and s.scope_level == 0) {
        if (ParseState.findClosureVarIndex(s.cur_func(), atom_id) == null) {
            const ref_idx: u16 = @intCast(try s.cur_func().addClosureVar(.{
                .closure_type = .module_decl,
                .is_lexical = false,
                .is_const = false,
                .var_kind = .normal,
                .var_idx = @intCast(s.cur_func().closure_var.len),
                .var_name = atom_id,
            }));
            try s.retrofitForwardTopLevelModuleCapture(s.cur_func(), atom_id, ref_idx, false, false, .normal);
        }
    } else if (s.cur_func_stack.len == 0 and (!s.is_eval or s.eval_global_var_bindings)) {
        try s.addGlobalVar(atom_id, false, false);
    } else if (s.cur_func().findVar(atom_id) < 0) {
        const saved = s.scope_level;
        s.scope_level = 0;
        defer s.scope_level = saved;
        const var_idx = try s.addScopeVar(atom_id, .normal, false, false);
        if (atomNameEquals(s, atom_id, "arguments")) {
            s.cur_func().arguments_var_idx = @intCast(var_idx);
        }
    } else if (atomNameEquals(s, atom_id, "arguments")) {
        s.cur_func().arguments_var_idx = s.cur_func().findVar(atom_id);
    }
}

/// Parse for-in or for-of loop
/// Mirrors `js_parse_for_in_of` in quickjs.c:27991
fn parseForInOf(s: *ParseState, is_for_await: bool) Error!void {
    // Parse left-hand side (var declaration or lvalue expression)
    const var_tok = s.peekKind();
    var target_atom: ?Atom = null;
    var target_member_base: ?Atom = null;
    var target_member_prop: ?Atom = null;
    var target_generic_lhs_point: ?LexerReplayPoint = null;
    var target_this_private_prop: ?Atom = null;
    defer if (target_this_private_prop) |atom_id| s.function.atoms.free(atom_id);
    var target_indexed_array_base: ?Atom = null;
    var target_indexed_array_index: ?i32 = null;
    var target_invalid_call = false;
    var target_array_pattern_atoms = std.ArrayList(?Atom).empty;
    defer target_array_pattern_atoms.deinit(s.function.memory.allocator);
    var target_array_pattern_member_bases = std.ArrayList(?Atom).empty;
    defer target_array_pattern_member_bases.deinit(s.function.memory.allocator);
    var target_array_pattern_member_props = std.ArrayList(?Atom).empty;
    defer target_array_pattern_member_props.deinit(s.function.memory.allocator);
    var target_array_pattern_computed_bases = std.ArrayList(?Atom).empty;
    defer target_array_pattern_computed_bases.deinit(s.function.memory.allocator);
    var target_array_pattern_computed_key_points = std.ArrayList(?LexerReplayPoint).empty;
    defer target_array_pattern_computed_key_points.deinit(s.function.memory.allocator);
    var target_array_pattern_object_points = std.ArrayList(?LexerReplayPoint).empty;
    defer target_array_pattern_object_points.deinit(s.function.memory.allocator);
    var target_array_pattern_object_props = std.ArrayList(?Atom).empty;
    defer target_array_pattern_object_props.deinit(s.function.memory.allocator);
    var target_array_pattern_object_computed_points = std.ArrayList(?LexerReplayPoint).empty;
    defer target_array_pattern_object_computed_points.deinit(s.function.memory.allocator);
    var target_array_pattern_object_computed_key_points = std.ArrayList(?LexerReplayPoint).empty;
    defer target_array_pattern_object_computed_key_points.deinit(s.function.memory.allocator);
    var target_array_pattern_default_snapshots = std.ArrayList(?ParserSnapshot).empty;
    defer target_array_pattern_default_snapshots.deinit(s.function.memory.allocator);
    var target_array_pattern_temp: ?u16 = null;
    var target_array_pattern_snapshot: ?ParserSnapshot = null;
    var target_array_pattern_kind: DestructuringKind = .array;
    var target_array_pattern_rest_atom: ?Atom = null;
    var target_array_pattern_rest_member_base: ?Atom = null;
    var target_array_pattern_rest_member_prop: ?Atom = null;
    var target_array_pattern_rest_computed_base: ?Atom = null;
    var target_array_pattern_rest_computed_key_point: ?LexerReplayPoint = null;
    var target_array_pattern_rest_object_computed_point: ?LexerReplayPoint = null;
    var target_array_pattern_rest_object_computed_key_point: ?LexerReplayPoint = null;
    var target_array_pattern_rest_index: u32 = 0;
    var target_is_decl = false;
    var target_is_lexical_decl = false;
    var target_lexical_is_const = false;
    var target_is_using_decl = false;
    var target_using_kind: UsingStackKind = .sync;
    var target_var_initializer_atom: ?Atom = null;
    var pushed_lexical_for_scope = false;
    var lexical_head_atoms = std.ArrayList(Atom).empty;
    defer lexical_head_atoms.deinit(s.function.memory.allocator);
    errdefer if (pushed_lexical_for_scope) s.popScope();
    const let_as_identifier = var_tok == tok.TOK_LET and !s.is_strict and !s.cur_func().is_strict_mode and
        (s.peekNextKind() == tok.TOK_IN or s.peekNextKind() == tok.TOK_OF);
    const direct_using_kind = directUsingDeclarationKind(s);
    const parse_using_decl = if (direct_using_kind) |using_kind|
        using_kind == .async or !usingDeclarationBindingIsOf(s, using_kind)
    else
        false;
    if (parse_using_decl) {
        const using_kind = direct_using_kind.?;
        target_using_kind = using_kind;
        if (using_kind == .async) {
            if (!s.in_async and !(s.lex.is_module and s.cur_func_stack.len == 0)) return Error.AwaitOutsideAsyncFunction;
            try s.advance();
        }
        try s.advance();
        if (!isIdentifierLikeToken(s)) return Error.UnexpectedToken;
        if (identifierLikeHasInvalidEscapeForBinding(s)) return Error.UnexpectedToken;
        const atom_id = identifierLikeAtom(s);
        if (atomNameEquals(s, atom_id, "let")) return Error.UnexpectedToken;
        if ((s.is_strict or s.cur_func().is_strict_mode) and
            (atomNameEquals(s, atom_id, "eval") or atomNameEquals(s, atom_id, "arguments")))
        {
            return Error.UnexpectedToken;
        }
        try s.pushScope();
        pushed_lexical_for_scope = true;
        _ = try s.addScopeVar(atom_id, .normal, true, true);
        target_atom = atom_id;
        target_is_decl = true;
        target_is_lexical_decl = true;
        target_lexical_is_const = true;
        target_is_using_decl = true;
        try s.advance();
        if (s.peekKind() == '=') return Error.UnexpectedToken;
    } else if ((var_tok == tok.TOK_VAR or var_tok == tok.TOK_LET or var_tok == tok.TOK_CONST) and !let_as_identifier) {
        try s.advance();
        const is_lexical = var_tok == tok.TOK_LET or var_tok == tok.TOK_CONST;
        const is_const = var_tok == tok.TOK_CONST;
        target_lexical_is_const = is_const;
        if (is_lexical) {
            try s.pushScope();
            pushed_lexical_for_scope = true;
        }
        if (s.peekKind() == @as(tok.TokenKind, @intCast('['))) {
            const pattern_snapshot = takeParserSnapshot(s);
            const has_default = try arrayPatternContainsDefault(s);
            const needs_generic_pattern = has_default or try arrayPatternContainsNestedBindingPattern(s);
            restoreParserLexerSnapshot(s, pattern_snapshot);
            if (needs_generic_pattern) {
                if (is_lexical) try rejectDuplicateSimpleArrayBindings(s);
                restoreParserLexerSnapshot(s, pattern_snapshot);
                {
                    const saved_binding_is_lexical = s.destructuring_binding_is_lexical;
                    const saved_binding_is_const = s.destructuring_binding_is_const;
                    const saved_predeclare_only = s.destructuring_predeclare_only;
                    s.destructuring_binding_is_lexical = is_lexical;
                    s.destructuring_binding_is_const = is_const;
                    s.destructuring_predeclare_only = is_lexical;
                    defer {
                        s.destructuring_binding_is_lexical = saved_binding_is_lexical;
                        s.destructuring_binding_is_const = saved_binding_is_const;
                        s.destructuring_predeclare_only = saved_predeclare_only;
                    }
                    try parseDestructuringPattern(s, .array, null);
                    try truncateSpeculativeParse(s, pattern_snapshot.code_len, pattern_snapshot.atom_len);
                }
                target_array_pattern_temp = try appendTempLocal(s);
                target_array_pattern_snapshot = pattern_snapshot;
            } else {
                try s.advance();
                while (s.peekKind() != @as(tok.TokenKind, @intCast(']')) and s.peekKind() != tok.TOK_EOF) {
                    if (s.peekKind() == tok.TOK_ELLIPSIS) {
                        try s.advance();
                        if (s.peekKind() != tok.TOK_IDENT) return Error.UnexpectedToken;
                        const rest_atom = s.token.payload.ident.atom;
                        if (is_lexical) {
                            for (target_array_pattern_atoms.items) |maybe_existing| {
                                if (maybe_existing != null and maybe_existing.? == rest_atom) return Error.UnexpectedToken;
                            }
                        }
                        if (is_lexical) {
                            _ = try s.addScopeVar(rest_atom, .normal, true, is_const);
                        } else {
                            try declareForInOfVarBinding(s, rest_atom);
                        }
                        target_array_pattern_rest_atom = rest_atom;
                        target_array_pattern_rest_index = @intCast(target_array_pattern_atoms.items.len);
                        try s.advance();
                        if (s.peekKind() != @as(tok.TokenKind, @intCast(']'))) return Error.UnexpectedToken;
                        break;
                    }
                    if (s.peekKind() == ',') {
                        try target_array_pattern_atoms.append(s.function.memory.allocator, null);
                        try s.advance();
                        continue;
                    }
                    if (s.peekKind() != tok.TOK_IDENT) return Error.UnexpectedToken;
                    const atom_id = s.token.payload.ident.atom;
                    if (is_lexical) {
                        for (target_array_pattern_atoms.items) |maybe_existing| {
                            if (maybe_existing != null and maybe_existing.? == atom_id) return Error.UnexpectedToken;
                        }
                    }
                    if (is_lexical) {
                        _ = try s.addScopeVar(atom_id, .normal, true, is_const);
                    } else {
                        try declareForInOfVarBinding(s, atom_id);
                    }
                    try target_array_pattern_atoms.append(s.function.memory.allocator, atom_id);
                    try s.advance();
                    if (s.peekKind() == ',') {
                        try s.advance();
                    } else if (s.peekKind() != @as(tok.TokenKind, @intCast(']'))) {
                        return Error.UnexpectedToken;
                    }
                }
                try s.expectToken(']');
                target_array_pattern_temp = try appendTempLocal(s);
            }
            target_is_decl = true;
            target_is_lexical_decl = is_lexical;
        } else if (s.peekKind() == @as(tok.TokenKind, @intCast('{'))) {
            const pattern_snapshot = takeParserSnapshot(s);
            {
                const saved_binding_is_lexical = s.destructuring_binding_is_lexical;
                const saved_binding_is_const = s.destructuring_binding_is_const;
                const saved_predeclare_only = s.destructuring_predeclare_only;
                s.destructuring_binding_is_lexical = is_lexical;
                s.destructuring_binding_is_const = is_const;
                s.destructuring_predeclare_only = is_lexical;
                defer {
                    s.destructuring_binding_is_lexical = saved_binding_is_lexical;
                    s.destructuring_binding_is_const = saved_binding_is_const;
                    s.destructuring_predeclare_only = saved_predeclare_only;
                }
                try parseDestructuringPattern(s, .object, null);
                try truncateSpeculativeParse(s, pattern_snapshot.code_len, pattern_snapshot.atom_len);
            }
            target_array_pattern_temp = try appendTempLocal(s);
            target_array_pattern_snapshot = pattern_snapshot;
            target_array_pattern_kind = .object;
            target_is_decl = true;
            target_is_lexical_decl = is_lexical;
        } else {
            const sloppy_keyword_var = var_tok == tok.TOK_VAR and
                (s.peekKind() == tok.TOK_YIELD or s.peekKind() == tok.TOK_STATIC or s.peekKind() == tok.TOK_LET) and
                !(s.is_strict or s.cur_func().is_strict_mode);
            if (s.peekKind() != tok.TOK_IDENT and !sloppy_keyword_var) return Error.UnexpectedToken;
            const atom_id = if (s.peekKind() == tok.TOK_IDENT) s.token.payload.ident.atom else tok.keywordAtom(s.peekKind());
            if ((s.is_strict or s.cur_func().is_strict_mode) and
                (atomNameEquals(s, atom_id, "eval") or atomNameEquals(s, atom_id, "arguments")))
            {
                return Error.UnexpectedToken;
            }
            if (is_lexical) {
                _ = try s.addScopeVar(atom_id, .normal, true, is_const);
            } else if (s.top_level_lexical_as_module_ref and s.scope_level == 0) {
                if (ParseState.findClosureVarIndex(s.cur_func(), atom_id) == null) {
                    const ref_idx: u16 = @intCast(try s.cur_func().addClosureVar(.{
                        .closure_type = .module_decl,
                        .is_lexical = false,
                        .is_const = false,
                        .var_kind = .normal,
                        .var_idx = @intCast(s.cur_func().closure_var.len),
                        .var_name = atom_id,
                    }));
                    try s.retrofitForwardTopLevelModuleCapture(s.cur_func(), atom_id, ref_idx, false, false, .normal);
                }
            } else {
                try declareForInOfVarBinding(s, atom_id);
            }
            target_atom = atom_id;
            target_is_decl = true;
            target_is_lexical_decl = is_lexical;
            try s.advance();
            if (s.peekKind() == '=') {
                if (is_lexical or s.is_strict or s.cur_func().is_strict_mode) return Error.UnexpectedToken;
                try s.advance();
                try parseAssignExpr2(s, ParseFlags{ .in_accepted = false });
                try s.emitScopePutVar(atom_id);
                target_var_initializer_atom = atom_id;
            }
        }
    } else if (let_as_identifier) {
        target_atom = tok.keywordAtom(tok.TOK_LET);
        try s.advance();
    } else if (var_tok == tok.TOK_IDENT and s.peekNextKind() == @as(tok.TokenKind, @intCast('('))) {
        const pre_lhs_code_len = s.currentCodeLen();
        const pre_lhs_atom_len = s.currentAtomOperandLen();
        const saved_atom = s.token.payload.ident.atom;
        try parseLhsExpr(s, .{ .in_accepted = false });
        const shape = classifyLhs(s, pre_lhs_code_len, pre_lhs_atom_len, saved_atom);
        if (shape != .invalid_call) return Error.UnexpectedToken;
        if (s.is_strict or s.cur_func().is_strict_mode) return Error.InvalidAssignmentTarget;
        target_invalid_call = true;
    } else if (var_tok == tok.TOK_IDENT) {
        const base_atom = s.token.payload.ident.atom;
        const base_has_escape = s.token.payload.ident.has_escape;
        try s.advance();
        if (s.peekKind() == @as(tok.TokenKind, @intCast('.'))) {
            try s.advance();
            if (s.peekKind() != tok.TOK_IDENT) return Error.UnexpectedToken;
            target_member_base = base_atom;
            target_member_prop = s.token.payload.ident.atom;
            try s.advance();
        } else {
            if (!is_for_await and !base_has_escape and atomNameEquals(s, base_atom, "async") and s.isOfToken()) return Error.UnexpectedToken;
            target_atom = base_atom;
        }
    } else if (var_tok == tok.TOK_THIS) {
        target_this_private_prop = try parseThisPrivateAssignmentTarget(s);
    } else if (var_tok == @as(tok.TokenKind, @intCast('('))) {
        if (peekParenthesizedBareIdent(s)) |atom_id| {
            try s.advance();
            try s.advance();
            target_atom = atom_id;
            try s.expectToken(')');
        } else {
            const target_point = takeLexerReplayPoint(s);
            const pre_lhs_code_len = s.currentCodeLen();
            const pre_lhs_atom_len = s.currentAtomOperandLen();
            {
                const saved_force_with_lvalue = s.force_with_lvalue;
                s.force_with_lvalue = true;
                defer s.force_with_lvalue = saved_force_with_lvalue;
                try parseLhsExpr(s, .{ .in_accepted = false });
            }
            const shape = classifyLhs(s, pre_lhs_code_len, pre_lhs_atom_len, null);
            try validateForInOfGenericAssignmentTarget(s, shape);
            try truncateSpeculativeParse(s, pre_lhs_code_len, pre_lhs_atom_len);
            target_generic_lhs_point = target_point;
        }
    } else if (var_tok == @as(tok.TokenKind, @intCast('['))) {
        const pattern_snapshot = takeParserSnapshot(s);
        const needs_generic_pattern = try arrayPatternContainsNestedAssignmentPattern(s);
        restoreParserLexerSnapshot(s, pattern_snapshot);
        if (needs_generic_pattern) {
            {
                const saved_assignment_target_mode = s.destructuring_assignment_target_mode;
                s.destructuring_assignment_target_mode = true;
                defer s.destructuring_assignment_target_mode = saved_assignment_target_mode;
                try parseDestructuringPattern(s, .array, null);
                try truncateSpeculativeParse(s, pattern_snapshot.code_len, pattern_snapshot.atom_len);
            }
            target_array_pattern_temp = try appendTempLocal(s);
            target_array_pattern_snapshot = pattern_snapshot;
        } else {
            try s.advance();
            while (s.peekKind() != @as(tok.TokenKind, @intCast(']')) and s.peekKind() != tok.TOK_EOF) {
                if (s.peekKind() == tok.TOK_ELLIPSIS) {
                    try s.advance();
                    target_array_pattern_rest_index = @intCast(target_array_pattern_atoms.items.len);
                    if (s.peekKind() == @as(tok.TokenKind, @intCast('{'))) {
                        const object_point = takeLexerReplayPoint(s);
                        const object_code_len = s.currentCodeLen();
                        const object_atom_len = s.currentAtomOperandLen();
                        try parseObjectLiteral(s, ParseFlags.default);
                        try truncateSpeculativeParse(s, object_code_len, object_atom_len);
                        if (s.peekKind() != @as(tok.TokenKind, @intCast('['))) return Error.UnexpectedToken;
                        try s.advance();
                        target_array_pattern_rest_object_computed_point = object_point;
                        target_array_pattern_rest_object_computed_key_point = takeLexerReplayPoint(s);
                        const key_code_len = s.currentCodeLen();
                        const key_atom_len = s.currentAtomOperandLen();
                        try parseExpr(s);
                        try truncateSpeculativeParse(s, key_code_len, key_atom_len);
                        try s.expectToken(']');
                    } else {
                        if (s.peekKind() != tok.TOK_IDENT and s.peekKind() != tok.TOK_LET) return Error.UnexpectedToken;
                        const rest_atom = if (s.peekKind() == tok.TOK_IDENT) s.token.payload.ident.atom else tok.keywordAtom(tok.TOK_LET);
                        if ((s.is_strict or s.cur_func().is_strict_mode) and
                            (atomNameEquals(s, rest_atom, "eval") or atomNameEquals(s, rest_atom, "arguments")))
                        {
                            return Error.UnexpectedToken;
                        }
                        try s.advance();
                        if (s.peekKind() == @as(tok.TokenKind, @intCast('.'))) {
                            try s.advance();
                            if (s.peekKind() != tok.TOK_IDENT) return Error.UnexpectedToken;
                            target_array_pattern_rest_member_base = rest_atom;
                            target_array_pattern_rest_member_prop = s.token.payload.ident.atom;
                            try s.advance();
                        } else if (s.peekKind() == @as(tok.TokenKind, @intCast('['))) {
                            try s.advance();
                            const key_point = takeLexerReplayPoint(s);
                            const key_code_len = s.currentCodeLen();
                            const key_atom_len = s.currentAtomOperandLen();
                            try parseExpr(s);
                            try truncateSpeculativeParse(s, key_code_len, key_atom_len);
                            try s.expectToken(']');
                            target_array_pattern_rest_computed_base = rest_atom;
                            target_array_pattern_rest_computed_key_point = key_point;
                        } else {
                            target_array_pattern_rest_atom = rest_atom;
                        }
                    }
                    if (s.peekKind() != @as(tok.TokenKind, @intCast(']'))) return Error.UnexpectedToken;
                    break;
                }
                if (s.peekKind() == ',') {
                    try target_array_pattern_atoms.append(s.function.memory.allocator, null);
                    try target_array_pattern_member_bases.append(s.function.memory.allocator, null);
                    try target_array_pattern_member_props.append(s.function.memory.allocator, null);
                    try target_array_pattern_computed_bases.append(s.function.memory.allocator, null);
                    try target_array_pattern_computed_key_points.append(s.function.memory.allocator, null);
                    try target_array_pattern_object_points.append(s.function.memory.allocator, null);
                    try target_array_pattern_object_props.append(s.function.memory.allocator, null);
                    try target_array_pattern_object_computed_points.append(s.function.memory.allocator, null);
                    try target_array_pattern_object_computed_key_points.append(s.function.memory.allocator, null);
                    try s.advance();
                    continue;
                }
                var atom_id: Atom = atom_module.null_atom;
                var object_point: ?LexerReplayPoint = null;
                var object_prop: ?Atom = null;
                var object_computed_point: ?LexerReplayPoint = null;
                var object_computed_key_point: ?LexerReplayPoint = null;
                if (s.peekKind() == @as(tok.TokenKind, @intCast('{'))) {
                    object_point = takeLexerReplayPoint(s);
                    const object_code_len = s.currentCodeLen();
                    const object_atom_len = s.currentAtomOperandLen();
                    try parseObjectLiteral(s, ParseFlags.default);
                    try truncateSpeculativeParse(s, object_code_len, object_atom_len);
                    if (s.peekKind() == @as(tok.TokenKind, @intCast('.'))) {
                        try s.advance();
                        if (s.peekKind() != tok.TOK_IDENT) return Error.UnexpectedToken;
                        object_prop = s.token.payload.ident.atom;
                        try s.advance();
                    } else if (s.peekKind() == @as(tok.TokenKind, @intCast('['))) {
                        object_computed_point = object_point;
                        object_point = null;
                        try s.advance();
                        const key_point = takeLexerReplayPoint(s);
                        const key_code_len = s.currentCodeLen();
                        const key_atom_len = s.currentAtomOperandLen();
                        try parseExpr(s);
                        try truncateSpeculativeParse(s, key_code_len, key_atom_len);
                        try s.expectToken(']');
                        object_computed_key_point = key_point;
                    } else {
                        return Error.UnexpectedToken;
                    }
                } else {
                    if (s.peekKind() != tok.TOK_IDENT and s.peekKind() != tok.TOK_LET) return Error.UnexpectedToken;
                    atom_id = if (s.peekKind() == tok.TOK_IDENT) s.token.payload.ident.atom else tok.keywordAtom(tok.TOK_LET);
                }
                if (object_point == null and (s.is_strict or s.cur_func().is_strict_mode) and
                    (atomNameEquals(s, atom_id, "eval") or atomNameEquals(s, atom_id, "arguments")))
                {
                    return Error.UnexpectedToken;
                }
                if (object_point != null) {
                    try target_array_pattern_atoms.append(s.function.memory.allocator, null);
                    try target_array_pattern_member_bases.append(s.function.memory.allocator, null);
                    try target_array_pattern_member_props.append(s.function.memory.allocator, null);
                    try target_array_pattern_computed_bases.append(s.function.memory.allocator, null);
                    try target_array_pattern_computed_key_points.append(s.function.memory.allocator, null);
                    try target_array_pattern_object_points.append(s.function.memory.allocator, object_point);
                    try target_array_pattern_object_props.append(s.function.memory.allocator, object_prop);
                    try target_array_pattern_object_computed_points.append(s.function.memory.allocator, null);
                    try target_array_pattern_object_computed_key_points.append(s.function.memory.allocator, null);
                } else if (object_computed_point != null) {
                    try target_array_pattern_atoms.append(s.function.memory.allocator, null);
                    try target_array_pattern_member_bases.append(s.function.memory.allocator, null);
                    try target_array_pattern_member_props.append(s.function.memory.allocator, null);
                    try target_array_pattern_computed_bases.append(s.function.memory.allocator, null);
                    try target_array_pattern_computed_key_points.append(s.function.memory.allocator, null);
                    try target_array_pattern_object_points.append(s.function.memory.allocator, null);
                    try target_array_pattern_object_props.append(s.function.memory.allocator, null);
                    try target_array_pattern_object_computed_points.append(s.function.memory.allocator, object_computed_point);
                    try target_array_pattern_object_computed_key_points.append(s.function.memory.allocator, object_computed_key_point);
                } else {
                    try s.advance();
                    if (s.peekKind() == @as(tok.TokenKind, @intCast('.'))) {
                        try s.advance();
                        if (s.peekKind() != tok.TOK_IDENT) return Error.UnexpectedToken;
                        try target_array_pattern_atoms.append(s.function.memory.allocator, null);
                        try target_array_pattern_member_bases.append(s.function.memory.allocator, atom_id);
                        try target_array_pattern_member_props.append(s.function.memory.allocator, s.token.payload.ident.atom);
                        try target_array_pattern_computed_bases.append(s.function.memory.allocator, null);
                        try target_array_pattern_computed_key_points.append(s.function.memory.allocator, null);
                        try target_array_pattern_object_points.append(s.function.memory.allocator, null);
                        try target_array_pattern_object_props.append(s.function.memory.allocator, null);
                        try target_array_pattern_object_computed_points.append(s.function.memory.allocator, null);
                        try target_array_pattern_object_computed_key_points.append(s.function.memory.allocator, null);
                        try s.advance();
                    } else if (s.peekKind() == @as(tok.TokenKind, @intCast('['))) {
                        try s.advance();
                        const key_point = takeLexerReplayPoint(s);
                        const key_code_len = s.currentCodeLen();
                        const key_atom_len = s.currentAtomOperandLen();
                        try parseExpr(s);
                        try truncateSpeculativeParse(s, key_code_len, key_atom_len);
                        try s.expectToken(']');
                        try target_array_pattern_atoms.append(s.function.memory.allocator, null);
                        try target_array_pattern_member_bases.append(s.function.memory.allocator, null);
                        try target_array_pattern_member_props.append(s.function.memory.allocator, null);
                        try target_array_pattern_computed_bases.append(s.function.memory.allocator, atom_id);
                        try target_array_pattern_computed_key_points.append(s.function.memory.allocator, key_point);
                        try target_array_pattern_object_points.append(s.function.memory.allocator, null);
                        try target_array_pattern_object_props.append(s.function.memory.allocator, null);
                        try target_array_pattern_object_computed_points.append(s.function.memory.allocator, null);
                        try target_array_pattern_object_computed_key_points.append(s.function.memory.allocator, null);
                    } else {
                        try target_array_pattern_atoms.append(s.function.memory.allocator, atom_id);
                        try target_array_pattern_member_bases.append(s.function.memory.allocator, null);
                        try target_array_pattern_member_props.append(s.function.memory.allocator, null);
                        try target_array_pattern_computed_bases.append(s.function.memory.allocator, null);
                        try target_array_pattern_computed_key_points.append(s.function.memory.allocator, null);
                        try target_array_pattern_object_points.append(s.function.memory.allocator, null);
                        try target_array_pattern_object_props.append(s.function.memory.allocator, null);
                        try target_array_pattern_object_computed_points.append(s.function.memory.allocator, null);
                        try target_array_pattern_object_computed_key_points.append(s.function.memory.allocator, null);
                    }
                }
                if (s.peekKind() == '=') {
                    const default_snapshot = takeParserSnapshot(s);
                    try s.advance();
                    try parseAssignExpr(s);
                    try truncateSpeculativeParse(s, default_snapshot.code_len, default_snapshot.atom_len);
                    try target_array_pattern_default_snapshots.append(s.function.memory.allocator, default_snapshot);
                } else {
                    try target_array_pattern_default_snapshots.append(s.function.memory.allocator, null);
                }
                if (s.peekKind() == ',') {
                    try s.advance();
                } else if (s.peekKind() != @as(tok.TokenKind, @intCast(']'))) {
                    return Error.UnexpectedToken;
                }
            }
            try s.expectToken(']');
            if (s.peekKind() == tok.TOK_IN or s.isOfToken()) {
                target_array_pattern_temp = try appendTempLocal(s);
                var has_assignment_target = false;
                for (target_array_pattern_atoms.items) |maybe_atom| {
                    if (maybe_atom != null) {
                        has_assignment_target = true;
                        break;
                    }
                }
                if (!has_assignment_target) {
                    for (target_array_pattern_member_bases.items) |maybe_atom| {
                        if (maybe_atom != null) {
                            has_assignment_target = true;
                            break;
                        }
                    }
                }
                if (!has_assignment_target) {
                    for (target_array_pattern_computed_bases.items) |maybe_atom| {
                        if (maybe_atom != null) {
                            has_assignment_target = true;
                            break;
                        }
                    }
                }
                if (!has_assignment_target) {
                    for (target_array_pattern_object_points.items) |maybe_point| {
                        if (maybe_point != null) {
                            has_assignment_target = true;
                            break;
                        }
                    }
                }
                if (!has_assignment_target) {
                    for (target_array_pattern_object_computed_points.items) |maybe_point| {
                        if (maybe_point != null) {
                            has_assignment_target = true;
                            break;
                        }
                    }
                }
                if (!has_assignment_target and
                    (target_array_pattern_rest_atom != null or
                        target_array_pattern_rest_member_base != null or
                        target_array_pattern_rest_computed_base != null or
                        target_array_pattern_rest_object_computed_point != null))
                {
                    has_assignment_target = true;
                }
                if (!has_assignment_target) target_array_pattern_snapshot = pattern_snapshot;
            } else {
                if (target_array_pattern_atoms.items.len != 1 or target_array_pattern_atoms.items[0] == null) return Error.UnexpectedToken;
                target_indexed_array_base = target_array_pattern_atoms.items[0].?;
                target_array_pattern_atoms.clearRetainingCapacity();
                try s.expectToken('[');
                if (s.peekKind() != tok.TOK_NUMBER) return Error.UnexpectedToken;
                const raw_index = s.token.payload.num.value;
                if (@trunc(raw_index) != raw_index or raw_index < 0 or raw_index > @as(f64, @floatFromInt(std.math.maxInt(i32)))) return Error.UnexpectedToken;
                target_indexed_array_index = @intFromFloat(raw_index);
                try s.advance();
                try s.expectToken(']');
            }
        }
    } else if (var_tok == @as(tok.TokenKind, @intCast('{'))) {
        const pattern_snapshot = takeParserSnapshot(s);
        {
            const saved_assignment_target_mode = s.destructuring_assignment_target_mode;
            s.destructuring_assignment_target_mode = true;
            defer s.destructuring_assignment_target_mode = saved_assignment_target_mode;
            try parseDestructuringPattern(s, .object, null);
            try truncateSpeculativeParse(s, pattern_snapshot.code_len, pattern_snapshot.atom_len);
        }
        target_array_pattern_temp = try appendTempLocal(s);
        target_array_pattern_snapshot = pattern_snapshot;
        target_array_pattern_kind = .object;
    } else {
        // Anything else is not a valid for-in/of assignment target in this
        // grammar position.
        return Error.UnexpectedToken;
    }

    // Parse 'in' or 'of'
    const in_of_tok = s.peekKind();
    const is_for_of = s.isOfToken();
    if (in_of_tok != tok.TOK_IN and !is_for_of) {
        return Error.UnexpectedToken;
    }
    if (target_is_using_decl and !is_for_of) return Error.UnexpectedToken;
    if (target_var_initializer_atom != null and is_for_of) return Error.UnexpectedToken;
    try s.advance();

    if (target_is_lexical_decl) {
        var idx = s.cur_func().scopes[@intCast(s.scope_level)].first;
        while (idx >= 0) {
            const var_idx: usize = @intCast(idx);
            const vd = &s.cur_func().vars[var_idx];
            if (vd.is_lexical) {
                try lexical_head_atoms.append(s.function.memory.allocator, vd.var_name);
                if (!vd.tdz_emitted_at_decl) {
                    try s.emitOpU16(opcode.op.set_loc_uninitialized, @intCast(var_idx));
                    vd.tdz_emitted_at_decl = true;
                }
            }
            idx = vd.scope_next;
        }
    }

    // `for-of` takes AssignmentExpression, so a comma here is a syntax error.
    // `for-in` keeps the existing Expression parsing path.
    if (is_for_of) {
        try parseAssignExpr(s);
    } else {
        try parseExpr(s);
    }
    if (target_is_lexical_decl and lexical_head_atoms.items.len != 0) {
        s.popScope();
        try s.pushScope();
        for (lexical_head_atoms.items) |atom_id| {
            _ = try s.addScopeVar(atom_id, .normal, true, target_lexical_is_const);
        }
    }
    try s.expectToken(')');
    if (target_is_lexical_decl and target_atom != null) {
        const atom_id = target_atom orelse return Error.UnexpectedToken;
        if (forInBlockBodyVarDeclaresName(s, atom_id)) return Error.UnexpectedToken;
    }

    // Initialize the iterator for the iterable on the stack.
    if (is_for_of) {
        try s.emitOp(if (is_for_await) opcode.op.for_await_of_start else opcode.op.for_of_start);
    } else {
        try s.emitOp(opcode.op.for_in_start);
    }

    // QuickJS enters for-in/of loops by jumping to the iterator step,
    // then the step branches back to the body with the next value on
    // the stack. The body begins by storing that value into the LHS.
    const next_jump_off = try emitForwardJump(s, opcode.op.goto);
    const body_pc: u32 = @intCast(s.currentCodeLen());
    const loop_label = s.pending_label_atom;
    s.pending_label_atom = null;
    try pushBreakFrame(s);
    if (is_for_of) {
        setCurrentBreakCleanupDrops(s, if (is_for_await) shared_iterator_close_marker else direct_iterator_close_marker);
    } else {
        setCurrentBreakCleanupDrops(s, 1);
    }
    const label_frame = if (loop_label) |atom_id| try s.pushLabelFrame(atom_id, true) else null;

    var iteration_using_stack_loc: ?u16 = null;
    var iteration_using_value_loc: ?u16 = null;
    var iteration_using_catch_off: ?usize = null;
    var iteration_using_frame_active = false;
    var iteration_using_catch_active = false;
    errdefer {
        if (iteration_using_frame_active) _ = s.using_block_frames.pop();
        if (iteration_using_catch_active) s.active_catch_marker_depth -= 1;
    }
    if (target_is_using_decl) {
        const value_loc = try appendAnonymousTempLocal(s);
        iteration_using_value_loc = value_loc;
        try s.emitOpU16(opcode.op.put_loc, value_loc);
        const stack_loc = try emitCreateUsingDisposableStack(s, target_using_kind);
        iteration_using_stack_loc = stack_loc;
        const catch_off = try emitForwardJump(s, opcode.op.@"catch");
        iteration_using_catch_off = catch_off;
        s.active_catch_marker_depth += 1;
        iteration_using_catch_active = true;
        try s.using_block_frames.append(s.function.memory.allocator, .{
            .stack_loc = stack_loc,
            .catch_marker_depth = s.active_catch_marker_depth,
            .kind = target_using_kind,
        });
        iteration_using_frame_active = true;
    }

    if (target_invalid_call) {
        try s.emitOpAtomU8(opcode.op.throw_error, atom_module.null_atom, 2);
    } else if (target_atom) |atom_id| {
        if (target_is_using_decl) {
            const stack_loc = iteration_using_stack_loc orelse return Error.UnexpectedToken;
            const value_loc = iteration_using_value_loc orelse return Error.UnexpectedToken;
            try s.emitOpU16(opcode.op.get_loc, value_loc);
            try s.emitOp(opcode.op.dup);
            try s.emitScopePutVarInit(atom_id);
            const resource_loc = try appendAnonymousTempLocal(s);
            try s.emitOpU16(opcode.op.put_loc, resource_loc);
            try emitUsingAddResource(s, target_using_kind, stack_loc, resource_loc);
            try s.emitCloseLoc(resource_loc);
            try s.emitCloseLoc(value_loc);
        } else if (target_is_decl) {
            if (target_is_lexical_decl) {
                try s.emitScopePutVarInit(atom_id);
            } else {
                try s.emitScopePutVar(atom_id);
            }
        } else {
            try s.emitScopePutVar(atom_id);
        }
    } else if (target_array_pattern_temp) |temp_idx| {
        try s.emitOpU16(opcode.op.put_loc, temp_idx);
        if (target_array_pattern_snapshot) |pattern_snapshot| {
            const after_head = takeParserSnapshot(s);
            if (target_array_pattern_kind == .array) {
                try emitRequireIteratorForBindingSource(s, BindingSource{ .loc = temp_idx });
            }
            restoreParserLexerSnapshot(s, pattern_snapshot);
            const saved_binding_is_lexical = s.destructuring_binding_is_lexical;
            const saved_binding_is_const = s.destructuring_binding_is_const;
            const saved_predeclare_only = s.destructuring_predeclare_only;
            const saved_assignment_target_mode = s.destructuring_assignment_target_mode;
            s.destructuring_binding_is_lexical = target_is_lexical_decl;
            s.destructuring_binding_is_const = target_lexical_is_const;
            s.destructuring_predeclare_only = false;
            s.destructuring_assignment_target_mode = !target_is_decl;
            defer {
                s.destructuring_binding_is_lexical = saved_binding_is_lexical;
                s.destructuring_binding_is_const = saved_binding_is_const;
                s.destructuring_predeclare_only = saved_predeclare_only;
                s.destructuring_assignment_target_mode = saved_assignment_target_mode;
            }
            try parseDestructuringPattern(s, target_array_pattern_kind, BindingSource{ .loc = temp_idx });
            restoreParserLexerSnapshot(s, after_head);
        } else {
            if (target_array_pattern_kind == .array) {
                try emitRequireIteratorForBindingSource(s, BindingSource{ .loc = temp_idx });
            }
            for (target_array_pattern_atoms.items, 0..) |maybe_atom, index| {
                const maybe_member_base = if (index < target_array_pattern_member_bases.items.len) target_array_pattern_member_bases.items[index] else null;
                const maybe_member_prop = if (index < target_array_pattern_member_props.items.len) target_array_pattern_member_props.items[index] else null;
                const maybe_computed_base = if (index < target_array_pattern_computed_bases.items.len) target_array_pattern_computed_bases.items[index] else null;
                const maybe_computed_key_point = if (index < target_array_pattern_computed_key_points.items.len) target_array_pattern_computed_key_points.items[index] else null;
                const maybe_object_point = if (index < target_array_pattern_object_points.items.len) target_array_pattern_object_points.items[index] else null;
                const maybe_object_prop = if (index < target_array_pattern_object_props.items.len) target_array_pattern_object_props.items[index] else null;
                const maybe_object_computed_point = if (index < target_array_pattern_object_computed_points.items.len) target_array_pattern_object_computed_points.items[index] else null;
                const maybe_object_computed_key_point = if (index < target_array_pattern_object_computed_key_points.items.len) target_array_pattern_object_computed_key_points.items[index] else null;
                const is_member_target = maybe_member_base != null and maybe_member_prop != null;
                const is_computed_target = maybe_computed_base != null and maybe_computed_key_point != null;
                const is_object_member_target = maybe_object_point != null and maybe_object_prop != null;
                const is_object_computed_target = maybe_object_computed_point != null and maybe_object_computed_key_point != null;
                const atom_id = maybe_atom orelse blk: {
                    if (is_member_target) break :blk maybe_member_base.?;
                    if (is_computed_target) break :blk maybe_computed_base.?;
                    if (is_object_member_target) break :blk maybe_object_prop.?;
                    if (is_object_computed_target) break :blk atom_module.null_atom;
                    if (is_for_of) try emitBindingElision(s, BindingSource{ .loc = temp_idx }, @intCast(index));
                    continue;
                };
                var object_computed_base_tmp: ?u16 = null;
                var object_computed_key_tmp: ?u16 = null;
                if (is_object_computed_target) {
                    try emitRequireIteratorForBindingSource(s, BindingSource{ .loc = temp_idx });
                    const after_object = takeParserSnapshot(s);
                    try restoreLexerReplayPoint(s, maybe_object_computed_point.?);
                    try parseObjectLiteral(s, ParseFlags.default);
                    restoreParserLexerSnapshot(s, after_object);
                    const base_tmp = try appendTempLocal(s);
                    try s.emitOpU16(opcode.op.put_loc, base_tmp);
                    const after_key = takeParserSnapshot(s);
                    try restoreLexerReplayPoint(s, maybe_object_computed_key_point.?);
                    try parseExpr(s);
                    restoreParserLexerSnapshot(s, after_key);
                    const key_tmp = try appendTempLocal(s);
                    try s.emitOpU16(opcode.op.put_loc, key_tmp);
                    object_computed_base_tmp = base_tmp;
                    object_computed_key_tmp = key_tmp;
                }
                try s.emitOpU8(opcode.op.special_object, opcode.special_object_subtype.dstr_get);
                try s.emitOpU16(opcode.op.get_loc, temp_idx);
                try s.emitOpI32(opcode.op.push_i32, @intCast(index));
                try s.emitOpU16(opcode.op.call, 2);
                if (index < target_array_pattern_default_snapshots.items.len) {
                    if (target_array_pattern_default_snapshots.items[index]) |default_snapshot| {
                        try s.emitOp(opcode.op.dup);
                        try s.emitOp(opcode.op.is_undefined);
                        const keep_value = try emitForwardJump(s, opcode.op.if_false);
                        try s.emitOp(opcode.op.drop);
                        const after_head = takeParserSnapshot(s);
                        restoreParserLexerSnapshot(s, default_snapshot);
                        try s.advance();
                        try parseAssignExpr(s);
                        if (!is_member_target and !is_computed_target and !is_object_member_target and !is_object_computed_target) try emitAnonymousDefaultName(s, atom_id);
                        restoreParserLexerSnapshot(s, after_head);
                        try patchForwardJump(s, keep_value);
                    }
                }
                if (is_member_target) {
                    try s.emitScopeGetVar(maybe_member_base.?);
                    try s.emitOp(opcode.op.swap);
                    try s.emitOpAtom(opcode.op.put_field, maybe_member_prop.?);
                } else if (is_computed_target) {
                    try s.emitScopeGetVar(maybe_computed_base.?);
                    const after_key = takeParserSnapshot(s);
                    try restoreLexerReplayPoint(s, maybe_computed_key_point.?);
                    try parseExpr(s);
                    restoreParserLexerSnapshot(s, after_key);
                    try s.emitOp(opcode.op.rot3l);
                    try s.emitOp(opcode.op.put_array_el);
                } else if (is_object_member_target) {
                    const after_object = takeParserSnapshot(s);
                    try restoreLexerReplayPoint(s, maybe_object_point.?);
                    try parseObjectLiteral(s, ParseFlags.default);
                    restoreParserLexerSnapshot(s, after_object);
                    try s.emitOp(opcode.op.swap);
                    try s.emitOpAtom(opcode.op.put_field, maybe_object_prop.?);
                } else if (is_object_computed_target) {
                    try s.emitOpU16(opcode.op.get_loc, object_computed_base_tmp.?);
                    try s.emitOpU16(opcode.op.get_loc, object_computed_key_tmp.?);
                    try s.emitOp(opcode.op.rot3l);
                    try s.emitOp(opcode.op.put_array_el);
                } else if (target_is_lexical_decl) {
                    try s.emitScopePutVarInit(atom_id);
                } else {
                    try s.emitScopePutVar(atom_id);
                }
            }
            if (target_array_pattern_rest_atom) |rest_atom| {
                try emitRestArrayFromSource(s, BindingSource{ .loc = temp_idx }, target_array_pattern_rest_index);
                if (target_is_lexical_decl) {
                    try s.emitScopePutVarInit(rest_atom);
                } else {
                    try s.emitScopePutVar(rest_atom);
                }
            } else if (target_array_pattern_rest_member_base) |base_atom| {
                try emitRestArrayFromSource(s, BindingSource{ .loc = temp_idx }, target_array_pattern_rest_index);
                try s.emitScopeGetVar(base_atom);
                try s.emitOp(opcode.op.swap);
                try s.emitOpAtom(opcode.op.put_field, target_array_pattern_rest_member_prop orelse return Error.UnexpectedToken);
            } else if (target_array_pattern_rest_computed_base) |base_atom| {
                try emitRestArrayFromSource(s, BindingSource{ .loc = temp_idx }, target_array_pattern_rest_index);
                try s.emitScopeGetVar(base_atom);
                const after_key = takeParserSnapshot(s);
                try restoreLexerReplayPoint(s, target_array_pattern_rest_computed_key_point orelse return Error.UnexpectedToken);
                try parseExpr(s);
                restoreParserLexerSnapshot(s, after_key);
                try s.emitOp(opcode.op.rot3l);
                try s.emitOp(opcode.op.put_array_el);
            } else if (target_array_pattern_rest_object_computed_point) |object_point| {
                try emitRequireIteratorForBindingSource(s, BindingSource{ .loc = temp_idx });
                const after_object = takeParserSnapshot(s);
                try restoreLexerReplayPoint(s, object_point);
                try parseObjectLiteral(s, ParseFlags.default);
                restoreParserLexerSnapshot(s, after_object);
                const object_tmp = try appendTempLocal(s);
                try s.emitOpU16(opcode.op.put_loc, object_tmp);
                const after_key = takeParserSnapshot(s);
                try restoreLexerReplayPoint(s, target_array_pattern_rest_object_computed_key_point orelse return Error.UnexpectedToken);
                try parseExpr(s);
                restoreParserLexerSnapshot(s, after_key);
                const key_tmp = try appendTempLocal(s);
                try s.emitOpU16(opcode.op.put_loc, key_tmp);
                try emitRestArrayFromSource(s, BindingSource{ .loc = temp_idx }, target_array_pattern_rest_index);
                try s.emitOpU16(opcode.op.get_loc, object_tmp);
                try s.emitOpU16(opcode.op.get_loc, key_tmp);
                try s.emitOp(opcode.op.rot3l);
                try s.emitOp(opcode.op.put_array_el);
            }
            if (is_for_of) try emitCloseBindingSource(s, BindingSource{ .loc = temp_idx });
        }
    } else if (target_generic_lhs_point) |target_point| {
        try emitForInOfGenericAssignmentTarget(s, target_point);
    } else if (target_member_base) |base_atom| {
        const prop_atom = target_member_prop orelse return Error.UnexpectedToken;
        try s.emitScopeGetVar(base_atom);
        try s.emitOp(opcode.op.swap);
        try s.emitOpAtom(opcode.op.put_field, prop_atom);
    } else if (target_this_private_prop) |prop_atom| {
        try emitPutThisPrivateFieldFromTop(s, prop_atom);
    } else if (target_indexed_array_base) |base_atom| {
        try s.emitScopeGetVar(base_atom);
        try s.emitOpU16(opcode.op.array_from, 1);
        try s.emitOpI32(opcode.op.push_i32, target_indexed_array_index orelse return Error.UnexpectedToken);
        try s.emitOp(opcode.op.rot3l);
        try s.emitOp(opcode.op.put_array_el);
    } else if (!target_invalid_call) {
        return Error.UnexpectedToken;
    }

    try parseStatementOrDecl(s, DeclMask{});

    if (target_is_using_decl) {
        const stack_loc = iteration_using_stack_loc orelse return Error.UnexpectedToken;
        s.active_catch_marker_depth -= 1;
        iteration_using_catch_active = false;
        try s.emitOp(opcode.op.drop);
        try emitUsingDisposeStack(s, target_using_kind, stack_loc);
        try s.emitCloseLoc(stack_loc);
        if (target_is_lexical_decl) try s.emitCloseCurrentScopeLexicals();
        const iteration_end_off = try emitForwardJump(s, opcode.op.goto);
        try patchForwardJump(s, iteration_using_catch_off orelse return Error.UnexpectedToken);
        try emitUsingDisposeStackForThrow(s, target_using_kind, stack_loc);
        try patchForwardJump(s, iteration_end_off);
        _ = s.using_block_frames.pop();
        iteration_using_frame_active = false;
        try patchContinueFrame(s);
        if (label_frame) |idx| try s.patchLabelContinues(idx);
    } else {
        try patchContinueFrame(s);
        if (label_frame) |idx| try s.patchLabelContinues(idx);
        if (target_is_lexical_decl) try s.emitCloseCurrentScopeLexicals();
    }
    try patchForwardJump(s, next_jump_off);
    if (is_for_of) {
        if (is_for_await) {
            try s.emitOpNoSource(opcode.op.dup3);
            try s.emitOpNoSource(opcode.op.drop);
            try s.emitOpU16NoSource(opcode.op.call_method, 0);
            try s.emitOpNoSource(opcode.op.await);
            try s.emitOpNoSource(opcode.op.iterator_get_value_done);
        } else {
            try s.emitOpU8(opcode.op.for_of_next, 0);
        }
    } else {
        try s.emitOp(opcode.op.for_in_next);
    }
    if (is_for_await) {
        try emitBackwardJumpNoSource(s, opcode.op.if_false, body_pc);
    } else {
        try emitBackwardJump(s, opcode.op.if_false, body_pc);
    }
    if (is_for_await) {
        try s.emitOpNoSource(opcode.op.drop);
        try popBreakFrameAndPatch(s);
        try s.emitOpNoSource(opcode.op.iterator_close);
    } else if (is_for_of) {
        try s.emitOp(opcode.op.drop);
        try s.emitOp(opcode.op.iterator_close);
        try popBreakFrameAndPatch(s);
    } else {
        try s.emitOp(opcode.op.drop);
        try s.emitOp(opcode.op.drop);
        try popBreakFrameAndPatch(s);
    }
    if (label_frame) |idx| {
        try s.patchLabelBreaks(idx);
        s.popLabelFrame(idx);
    }
    if (pushed_lexical_for_scope) {
        s.popScope();
        pushed_lexical_for_scope = false;
    }
}

fn rejectDuplicateSimpleArrayBindings(s: *ParseState) Error!void {
    const snapshot = takeParserSnapshot(s);
    defer restoreParserLexerSnapshot(s, snapshot);
    var names = std.ArrayList(Atom).empty;
    defer names.deinit(s.function.memory.allocator);

    try s.expectToken('[');
    while (s.peekKind() != ']' and s.peekKind() != tok.TOK_EOF) {
        if (s.peekKind() == ',') {
            try s.advance();
            continue;
        }
        if (s.peekKind() == tok.TOK_ELLIPSIS) try s.advance();
        if (s.peekKind() == tok.TOK_IDENT) {
            const atom_id = s.token.payload.ident.atom;
            for (names.items) |existing| {
                if (existing == atom_id) return Error.UnexpectedToken;
            }
            try names.append(s.function.memory.allocator, atom_id);
            try s.advance();
        } else if (s.peekKind() == '[' or s.peekKind() == '{') {
            try skipBalancedPatternElement(s);
        } else {
            return Error.UnexpectedToken;
        }
        if (s.peekKind() == '=') {
            try s.advance();
            try skipInitializerInBindingPattern(s);
        }
        if (s.peekKind() == ',') {
            try s.advance();
        } else if (s.peekKind() != ']') {
            return Error.UnexpectedToken;
        }
    }
    try s.expectToken(']');
}

fn arrayPatternContainsDefault(s: *ParseState) Error!bool {
    const snapshot = takeParserSnapshot(s);
    defer restoreParserLexerSnapshot(s, snapshot);
    try s.expectToken('[');
    var depth: usize = 0;
    while (true) {
        const k = s.peekKind();
        if (k == tok.TOK_EOF) return Error.UnexpectedToken;
        if (depth == 0 and k == ']') return false;
        if (depth == 0 and k == '=') return true;
        if (k == '[' or k == '{' or k == '(') depth += 1;
        if (k == ']' or k == '}' or k == ')') {
            if (depth == 0) return false;
            depth -= 1;
        }
        try s.advance();
    }
}

fn arrayPatternContainsNestedBindingPattern(s: *ParseState) Error!bool {
    const snapshot = takeParserSnapshot(s);
    defer restoreParserLexerSnapshot(s, snapshot);
    try s.expectToken('[');
    var depth: usize = 0;
    while (true) {
        const k = s.peekKind();
        if (k == tok.TOK_EOF) return Error.UnexpectedToken;
        if (depth == 0 and k == ']') return false;
        if (depth == 0 and (k == '[' or k == '{')) return true;
        if (depth == 0 and k == tok.TOK_ELLIPSIS) {
            try s.advance();
            const rest_target = s.peekKind();
            if (rest_target == '[' or rest_target == '{') return true;
            continue;
        }
        if (k == '[' or k == '{' or k == '(') depth += 1;
        if (k == ']' or k == '}' or k == ')') {
            if (depth == 0) return false;
            depth -= 1;
        }
        try s.advance();
    }
}

fn arrayPatternContainsNestedAssignmentPattern(s: *ParseState) Error!bool {
    const snapshot = takeParserSnapshot(s);
    defer restoreParserLexerSnapshot(s, snapshot);
    try s.expectToken('[');
    while (s.peekKind() != ']' and s.peekKind() != tok.TOK_EOF) {
        if (s.peekKind() == ',') {
            try s.advance();
            continue;
        }
        var is_rest = false;
        if (s.peekKind() == tok.TOK_ELLIPSIS) {
            is_rest = true;
            try s.advance();
        }
        if (s.peekKind() == '[') return true;
        if (s.peekKind() == '{') {
            try skipBalancedPatternElement(s);
            if (s.peekKind() == '.' or s.peekKind() == '[') return false;
            return true;
        }
        if (s.peekKind() == tok.TOK_THIS) return true;
        if (is_rest) return false;
        while (s.peekKind() != ',' and s.peekKind() != ']' and s.peekKind() != tok.TOK_EOF) {
            if (s.peekKind() == '=') {
                try skipInitializerInBindingPattern(s);
                break;
            }
            try s.advance();
        }
        if (s.peekKind() == ',') try s.advance();
    }
    if (s.peekKind() == tok.TOK_EOF) return Error.UnexpectedToken;
    return false;
}

fn skipBalancedPatternElement(s: *ParseState) Error!void {
    var depth: usize = 0;
    while (true) {
        const k = s.peekKind();
        if (k == tok.TOK_EOF) return Error.UnexpectedToken;
        if (k == '[' or k == '{' or k == '(') depth += 1;
        if (k == ']' or k == '}' or k == ')') {
            if (depth == 0) return;
            depth -= 1;
            try s.advance();
            if (depth == 0) return;
            continue;
        }
        try s.advance();
    }
}

fn skipInitializerInBindingPattern(s: *ParseState) Error!void {
    var depth: usize = 0;
    while (true) {
        const k = s.peekKind();
        if (k == tok.TOK_EOF) return Error.UnexpectedToken;
        if (depth == 0 and (k == ',' or k == ']' or k == '}')) return;
        if (k == '[' or k == '{' or k == '(') depth += 1;
        if (k == ']' or k == '}' or k == ')') {
            if (depth == 0) return;
            depth -= 1;
        }
        try s.advance();
    }
}

fn forInBlockBodyVarDeclaresName(s: *ParseState, atom_id: Atom) bool {
    if (s.peekKind() != @as(tok.TokenKind, @intCast('{'))) return false;
    const saved_pos = s.lex.pos;
    const saved_line = s.lex.line;
    const saved_col = s.lex.col;
    const saved_mark_pos = s.lex.mark_pos;
    const saved_mark_line = s.lex.mark_line;
    const saved_mark_col = s.lex.mark_col;
    const saved_token = s.token;
    var advanced = false;
    defer {
        if (advanced) s.lex.freeToken(&s.token);
        s.lex.pos = saved_pos;
        s.lex.line = saved_line;
        s.lex.col = saved_col;
        s.lex.mark_pos = saved_mark_pos;
        s.lex.mark_line = saved_mark_line;
        s.lex.mark_col = saved_mark_col;
        s.token = saved_token;
    }

    const advanceLocal = struct {
        fn call(state: *ParseState, did_advance: *bool) bool {
            const next = state.lex.next() catch return false;
            state.lex.freeToken(&state.token);
            state.token = next;
            did_advance.* = true;
            return true;
        }
    }.call;

    var depth: usize = 0;
    while (true) {
        const kind = s.peekKind();
        if (kind == tok.TOK_EOF) return false;
        if (kind == @as(tok.TokenKind, @intCast('{'))) {
            depth += 1;
            if (!advanceLocal(s, &advanced)) return false;
            continue;
        }
        if (kind == @as(tok.TokenKind, @intCast('}'))) {
            if (depth == 0) return false;
            depth -= 1;
            if (depth == 0) return false;
            if (!advanceLocal(s, &advanced)) return false;
            continue;
        }
        if (kind == tok.TOK_VAR) {
            if (!advanceLocal(s, &advanced)) return false;
            while (true) {
                if (s.peekKind() == tok.TOK_IDENT and s.token.payload.ident.atom == atom_id) return true;
                if (!advanceLocal(s, &advanced)) return false;
                if (s.peekKind() == ',') {
                    if (!advanceLocal(s, &advanced)) return false;
                    continue;
                }
                break;
            }
            continue;
        }
        if (!advanceLocal(s, &advanced)) return false;
    }
}

/// Parse function declaration
/// Mirrors `js_parse_function_decl` in quickjs.c:36388
fn parseFunctionDecl(s: *ParseState, func_kind: ParseFunctionKind, source_start: usize) Error!void {
    const saved_parameter_properties = s.current_parameter_properties;
    if (func_kind == .class_constructor or func_kind == .derived_class_constructor) {
        s.current_parameter_properties = std.ArrayList(Atom).empty;
    } else {
        s.current_parameter_properties = null;
    }
    defer {
        if (func_kind == .class_constructor or func_kind == .derived_class_constructor) {
            if (s.current_parameter_properties) |*props| {
                props.deinit(s.function.memory.allocator);
            }
        }
        s.current_parameter_properties = saved_parameter_properties;
    }

    try s.advance();

    // Check for generator: function*
    const is_generator = s.peekKind() == '*';
    if (is_generator) {
        try s.advance();
    }

    // Parse function name (required for declarations)
    const has_decl_name = s.peekKind() == tok.TOK_IDENT or
        (s.peekKind() == tok.TOK_AWAIT and canUseAwaitAsIdentifier(s)) or
        (s.peekKind() == tok.TOK_YIELD and !(s.is_strict or s.cur_func().is_strict_mode));
    if (!has_decl_name) {
        return Error.UnexpectedToken;
    }
    const name_atom = identifierLikeAtom(s);
    s.last_declared_atom = name_atom;
    if (s.lex.is_module and s.cur_func_stack.len == 0 and s.scope_level == 0 and hasKnownBinding(s, name_atom)) {
        return Error.UnexpectedToken;
    }
    const function_body_scope: i32 = if (s.cur_func_stack.len > 0) 1 else 0;
    if (s.scope_level > function_body_scope) try s.registerBlockLexicalDeclaration(name_atom);
    try s.advance();

    // Set generator flag for yield parsing
    const was_generator = s.in_generator;
    s.in_generator = is_generator;
    defer s.in_generator = was_generator;

    // Set async flag for await parsing
    const was_async = s.in_async;
    const is_async = func_kind == .async or func_kind == .async_generator;
    s.in_async = is_async;
    defer s.in_async = was_async;

    // Determine actual function kind based on async/generator combination
    const actual_kind: ParseFunctionKind = if (is_generator)
        if (func_kind == .async) .async_generator else .generator
    else
        func_kind;

    const saved_pending_name = s.pending_function_name;
    const saved_pending_decl = s.pending_function_is_decl;
    s.pending_function_name = name_atom;
    s.pending_function_is_decl = true;
    defer {
        s.pending_function_name = saved_pending_name;
        s.pending_function_is_decl = saved_pending_decl;
    }
    try parseFunctionParamsAndBody(s, actual_kind, source_start);
}

/// Parse function expression
/// Mirrors `js_parse_function_expr` in quickjs.c
fn parseFunctionExpr(s: *ParseState, func_kind: ParseFunctionKind, source_start: usize) Error!void {
    try s.advance();

    // Check for generator: function*
    const is_generator = s.peekKind() == '*';
    if (is_generator) {
        try s.advance();
    }

    // Parse function name (optional for expressions)
    const saved_pending_name = s.pending_function_name;
    s.pending_function_name = null;
    const has_name = s.peekKind() == tok.TOK_IDENT or
        (s.peekKind() == tok.TOK_AWAIT and !s.in_async and !s.lex.is_module) or
        (s.peekKind() == tok.TOK_YIELD and !(s.is_strict or s.cur_func().is_strict_mode));
    if (has_name) {
        const name_atom = identifierLikeAtom(s);
        if (is_generator and atomNameEquals(s, name_atom, "yield")) return Error.UnexpectedToken;
        if (func_kind == .async and is_generator and atomNameEquals(s, name_atom, "await")) return Error.UnexpectedToken;
        if ((s.is_strict or s.cur_func().is_strict_mode) and
            (atomNameEquals(s, name_atom, "eval") or atomNameEquals(s, name_atom, "arguments")))
        {
            return Error.UnexpectedToken;
        }
        s.pending_function_name = name_atom;
        try s.advance();
    }

    // Set generator flag for yield parsing
    const was_generator = s.in_generator;
    s.in_generator = is_generator;
    defer s.in_generator = was_generator;

    // Set async flag for await parsing
    const was_async = s.in_async;
    const is_async = func_kind == .async or func_kind == .async_generator;
    s.in_async = is_async;
    defer s.in_async = was_async;

    // Determine actual function kind based on async/generator combination
    const actual_kind: ParseFunctionKind = if (is_generator)
        if (func_kind == .async) .async_generator else .generator
    else
        func_kind;

    const saved_pending_decl = s.pending_function_is_decl;
    s.pending_function_is_decl = false;
    defer {
        s.pending_function_name = saved_pending_name;
        s.pending_function_is_decl = saved_pending_decl;
    }
    try parseFunctionParamsAndBody(s, actual_kind, source_start);
}

/// Parse function parameters and body
/// Shared by function declarations, expressions, and methods
fn parseFunctionParamsAndBody(s: *ParseState, func_kind: ParseFunctionKind, source_start: ?usize) Error!void {
    if (func_kind != .class_static_block) {
        s.features.insert(.function_);
    }
    switch (func_kind) {
        .async => s.features.insert(.async_function),
        .generator => s.features.insert(.generator),
        .async_generator => {
            s.features.insert(.async_function);
            s.features.insert(.generator);
            s.features.insert(.async_generator);
        },
        else => {},
    }
    s.last_function_child_index = null;
    const parent_fd = s.cur_func();
    const capture_child = s.cur_func_stack.len > 0 or s.top_level_functions_as_children;
    const saved_emit_to_function_def = s.emit_to_function_def;
    const saved_scope_level = s.scope_level;
    const saved_is_eval = s.is_eval;
    const saved_eval_ret_idx = s.eval_ret_idx;
    const saved_return_depth = s.return_depth;
    const saved_return_expr_mode = s.return_expr_mode;
    const saved_return_expr_cond_depth = s.return_expr_cond_depth;
    const saved_return_expr_emitted_return = s.return_expr_emitted_return;
    const saved_is_strict = s.is_strict;
    const saved_lex_is_strict = s.lex.is_strict_mode;
    const saved_allow_super = s.allow_super;
    const saved_allow_super_call = s.allow_super_call;
    const saved_new_target_allowed = s.new_target_allowed;
    const saved_function_expr_name_binding = s.function_expr_name_binding;
    const saved_class_field_initializer_depth = s.class_field_initializer_depth;
    const saved_class_static_field_this_atom = s.class_static_field_this_atom;
    const saved_reject_await_in_parameter_initializer = s.reject_await_in_parameter_initializer;
    const saved_in_constructor = s.in_constructor;
    s.in_constructor = func_kind == .class_constructor or func_kind == .derived_class_constructor;
    defer s.in_constructor = saved_in_constructor;
    const saved_is_outer_constructor_block = s.is_outer_constructor_block;
    s.is_outer_constructor_block = func_kind == .class_constructor or func_kind == .derived_class_constructor;
    defer s.is_outer_constructor_block = saved_is_outer_constructor_block;

    var child_pushed = false;
    errdefer if (child_pushed) {
        s.discardCurrentFunction();
        s.emit_to_function_def = saved_emit_to_function_def;
        s.scope_level = saved_scope_level;
        s.is_eval = saved_is_eval;
        s.eval_ret_idx = saved_eval_ret_idx;
        s.return_depth = saved_return_depth;
        s.return_expr_mode = saved_return_expr_mode;
        s.return_expr_cond_depth = saved_return_expr_cond_depth;
        s.return_expr_emitted_return = saved_return_expr_emitted_return;
        s.is_strict = saved_is_strict;
        s.lex.is_strict_mode = saved_lex_is_strict;
        s.new_target_allowed = saved_new_target_allowed;
    };
    const saved_return_finally = if (capture_child) enterReturnFinallyFunctionBoundary(s) else null;
    defer if (saved_return_finally) |saved| leaveReturnFinallyFunctionBoundary(s, saved);
    if (func_kind != .arrow) s.class_field_initializer_depth = 0;
    if (func_kind != .arrow) s.class_static_field_this_atom = null;
    defer s.class_field_initializer_depth = saved_class_field_initializer_depth;
    defer s.class_static_field_this_atom = saved_class_static_field_this_atom;
    s.function_expr_name_binding = switch (func_kind) {
        .normal, .async, .generator, .async_generator => if (!s.pending_function_is_decl) s.pending_function_name else null,
        else => null,
    };
    defer s.function_expr_name_binding = saved_function_expr_name_binding;
    const function_allows_super = saved_allow_super or switch (func_kind) {
        .method, .get, .set, .class_constructor, .derived_class_constructor, .class_static_block => true,
        else => false,
    };
    const function_allows_super_call = if (func_kind == .class_static_block)
        false
    else
        saved_allow_super_call or func_kind == .derived_class_constructor;
    s.allow_super = function_allows_super;
    s.allow_super_call = function_allows_super_call;
    defer s.allow_super = saved_allow_super;
    defer s.allow_super_call = saved_allow_super_call;
    const function_new_target_allowed = if (func_kind == .arrow) saved_new_target_allowed else true;
    s.new_target_allowed = function_new_target_allowed;
    defer s.new_target_allowed = saved_new_target_allowed;
    const saved_static_block = s.in_class_static_block;
    s.in_class_static_block = func_kind == .class_static_block;
    defer s.in_class_static_block = saved_static_block;
    const parent_code_len_before_child = s.currentCodeLen();

    if (capture_child) {
        const child_fd = try s.function.memory.create(function_def_mod.FunctionDef);
        var child_owned_before_push = true;
        errdefer if (child_owned_before_push) s.discardFunctionDef(child_fd);
        const child_name = s.pending_function_name orelse if (s.pending_function_is_decl) s.function.name else atom_module.ids.empty_string;
        child_fd.* = function_def_mod.FunctionDef.init(s.function.memory, s.function.atoms, child_name);
        child_fd.atoms.replace(&child_fd.filename, parent_fd.filename);
        child_fd.line_num = @intCast(s.token.line_num);
        child_fd.col_num = @intCast(s.token.col_num);
        child_fd.parent = parent_fd;
        child_fd.parent_scope_level = if (s.in_parameter_initializer) -1 else parent_fd.scope_level;
        child_fd.is_strict_mode = parent_fd.is_strict_mode or s.is_strict or s.lex.is_strict_mode;
        child_fd.is_indirect_eval = parent_fd.is_indirect_eval;
        child_fd.use_short_opcodes = parent_fd.use_short_opcodes;
        child_fd.func_type = switch (func_kind) {
            .normal, .async, .generator, .async_generator => if (s.pending_function_is_decl) .statement else .expr,
            .arrow => .arrow,
            .get => .getter,
            .set => .setter,
            .method => .method,
            .class_constructor => .class_constructor,
            .derived_class_constructor => .derived_class_constructor,
            .class_static_block => .class_static_init,
        };
        child_fd.func_kind = switch (func_kind) {
            .async => .async,
            .generator => .generator,
            .async_generator => .async_generator,
            else => .normal,
        };
        child_fd.new_target_allowed = function_new_target_allowed;
        child_fd.super_allowed = function_allows_super;
        child_fd.super_call_allowed = function_allows_super_call;
        child_fd.has_this_binding = func_kind != .arrow;
        child_fd.has_prototype = switch (func_kind) {
            .arrow, .async, .method, .get, .set, .class_static_block => false,
            else => true,
        };
        if (func_kind == .class_static_block) {
            child_fd.has_home_object = true;
            child_fd.need_home_object = true;
        }
        _ = child_fd.appendScope(-1) catch return error.OutOfMemory;
        if (func_kind == .class_constructor or func_kind == .derived_class_constructor) {
            if (func_kind == .derived_class_constructor) {
                child_fd.this_active_func_var_idx = try child_fd.addScopeVar(116, .normal, 0, false, false); // this.active_func
                child_fd.new_target_var_idx = try child_fd.addScopeVar(115, .normal, 0, false, false); // new.target
            }
            child_fd.this_var_idx = @intCast(try child_fd.addScopeVar(8, .normal, 0, func_kind == .derived_class_constructor, false));
            if (func_kind == .derived_class_constructor) {
                child_fd.vars[@intCast(child_fd.this_var_idx)].tdz_emitted_at_decl = true;
            }
            child_fd.is_derived_class_constructor = func_kind == .derived_class_constructor;
            const fields_init_var_idx = parent_fd.findVar(atom_class_fields_init);
            if (fields_init_var_idx < 0) return Error.UnexpectedToken;
            _ = try child_fd.addClosureVar(.{
                .closure_type = .local,
                .is_lexical = true,
                .is_const = true,
                .var_kind = .normal,
                .var_idx = @intCast(fields_init_var_idx),
                .var_name = atom_class_fields_init,
            });
        }
        if (!s.pending_function_is_decl) {
            if (s.pending_function_name) |name| {
                child_fd.func_var_idx = try child_fd.addScopeVar(name, .function_name, 0, false, true);
            }
        }
        if (s.pending_function_is_decl) {
            const name = s.pending_function_name orelse s.function.name;
            if (s.cur_func_stack.len == 0 and
                s.top_level_functions_as_children and
                parent_fd.scope_level == 0 and
                (!s.is_eval or !parent_fd.is_strict_mode) and
                !s.annex_b_if_function_decl_clause and
                s.findFunctionScopeVar(name) == null)
            {
                if (!s.lex.is_module and s.cur_func_stack.len == 0 and (!s.is_eval or s.eval_global_var_bindings)) {
                    try s.addGlobalAnnexBFunctionVar(name, s.eval_global_var_bindings);
                }
                const parent_ref_idx: u16 = if (ParseState.findClosureVarIndex(parent_fd, name)) |idx| blk: {
                    parent_fd.closure_var[idx].var_kind = .function_decl;
                    parent_fd.closure_var[idx].is_lexical = true;
                    break :blk idx;
                } else @intCast(try parent_fd.addClosureVar(.{
                    .closure_type = .module_decl,
                    .is_lexical = true,
                    .is_const = false,
                    .var_kind = .function_decl,
                    .var_idx = @intCast(parent_fd.closure_var.len),
                    .var_name = name,
                }));
                try s.retrofitForwardTopLevelFunctionCapture(parent_fd, name, parent_ref_idx);
                child_fd.emit_top_level_closure_init = true;
                child_fd.top_level_closure_var_idx = parent_ref_idx;
            } else {
                _ = parent_code_len_before_child;
                child_fd.child_decl_init_keep_value = false;

                // Early-error: check for duplicate lexical declaration in the
                // same scope.  Mirrors QuickJS `define_var` JS_VAR_DEF_FUNCTION_DECL
                // path (`quickjs.c:23716-23732`): duplicate LexicallyDeclaredNames
                // in a Block are a SyntaxError, except Annex B.3.3.4 allows
                // redefining a function declaration with another function declaration
                // in non-strict mode.
                if (s.visibleLexicalScopeVar(name)) |existing_idx| {
                    const existing = parent_fd.vars[existing_idx];
                    const same_scope = existing.scope_level == parent_fd.scope_level;
                    const annex_b_func_redef = same_scope and
                        !parent_fd.is_strict_mode and
                        func_kind == .normal and
                        existing.var_kind == .function_decl;
                    if (same_scope and !annex_b_func_redef) {
                        return Error.SyntaxError;
                    }
                }

                const visible_lexical_blocking_annex_b = s.visibleLexicalScopeVar(name) != null;
                const function_body_scope: i32 = if (s.cur_func_stack.len > 0) 1 else 0;
                const is_block_level_function_decl = parent_fd.scope_level > function_body_scope;
                const name_blocks_annex_b_parameter_rule =
                    parent_fd.findArg(name) >= 0 or
                    atomNameEquals(s, name, "arguments") or
                    evalAnnexBBlockedFunctionName(s, name);
                const annex_b_if_function_var = s.annex_b_if_function_decl_clause and
                    !parent_fd.is_strict_mode and
                    func_kind == .normal and
                    !visible_lexical_blocking_annex_b and
                    !name_blocks_annex_b_parameter_rule and
                    !s.in_namespace;
                const annex_b_block_function_var = is_block_level_function_decl and
                    !parent_fd.is_strict_mode and
                    func_kind == .normal and
                    !visible_lexical_blocking_annex_b and
                    !name_blocks_annex_b_parameter_rule and
                    !s.in_namespace;
                const duplicate_hoisted_block_func = is_block_level_function_decl and s.scopeHasVar(0, name);
                const function_decl_idx: u16 = if (annex_b_if_function_var) blk: {
                    const is_top_level_annex_b_if_scope =
                        parent_fd.scope_level == 0 or
                        (parent_fd.scope_level > 0 and
                            @as(usize, @intCast(parent_fd.scope_level)) < parent_fd.scopes.len and
                            parent_fd.scopes[@intCast(parent_fd.scope_level)].parent == 0);
                    const emit_global_annex_b_if = s.cur_func_stack.len == 0 and
                        s.top_level_functions_as_children and
                        ((is_top_level_annex_b_if_scope and !s.is_eval) or s.eval_global_var_bindings);
                    if (emit_global_annex_b_if) {
                        try s.addGlobalAnnexBFunctionVar(name, s.eval_global_var_bindings);
                    }
                    if (emit_global_annex_b_if) {
                        child_fd.child_decl_emit_inline = true;
                        child_fd.child_decl_emit_global_inline = true;
                        break :blk @intCast(try parent_fd.addScopeVar(name, .function_decl, parent_fd.scope_level, true, false));
                    }
                    const annex_b_var_idx = try s.ensureFunctionScopeVar(name);
                    child_fd.child_decl_annex_b_var_idx = annex_b_var_idx;
                    child_fd.child_decl_emit_inline = true;
                    break :blk @intCast(try parent_fd.addScopeVar(name, .function_decl, parent_fd.scope_level, true, false));
                } else if (s.annex_b_if_function_decl_clause and func_kind == .normal) blk: {
                    child_fd.child_decl_emit_inline = true;
                    child_fd.child_decl_skip_init = true;
                    break :blk 0;
                } else if (annex_b_block_function_var) blk: {
                    const emit_global_annex_b_block = s.cur_func_stack.len == 0 and
                        (s.eval_global_var_bindings or (!s.is_eval and s.top_level_functions_as_children));
                    if (emit_global_annex_b_block) {
                        try s.addGlobalAnnexBFunctionVar(name, s.eval_global_var_bindings);
                        child_fd.child_decl_emit_inline = true;
                        child_fd.child_decl_emit_global_inline = true;
                        break :blk @intCast(try parent_fd.addScopeVar(name, .function_decl, parent_fd.scope_level, true, false));
                    } else {
                        const annex_b_var_idx = try s.ensureFunctionScopeVar(name);
                        child_fd.child_decl_annex_b_var_idx = annex_b_var_idx;
                        child_fd.child_decl_emit_inline = true;
                        break :blk @intCast(try parent_fd.addScopeVar(name, .function_decl, parent_fd.scope_level, true, false));
                    }
                } else if ((parent_fd.is_strict_mode and is_block_level_function_decl) or
                    (is_block_level_function_decl and s.is_eval) or
                    (is_block_level_function_decl and visible_lexical_blocking_annex_b) or
                    (is_block_level_function_decl and name_blocks_annex_b_parameter_rule) or
                    (is_block_level_function_decl and s.in_switch_case_block_scope) or
                    duplicate_hoisted_block_func)
                blk: {
                    child_fd.child_decl_force_local_init = is_block_level_function_decl and name_blocks_annex_b_parameter_rule;
                    if (child_fd.child_decl_force_local_init) {
                        if (findCurrentScopeVar(s, name)) |idx| {
                            parent_fd.vars[idx].tdz_emitted_at_decl = true;
                            break :blk idx;
                        }
                    }
                    const idx: u16 = @intCast(try parent_fd.addScopeVar(name, .function_decl, parent_fd.scope_level, true, false));
                    if (child_fd.child_decl_force_local_init) parent_fd.vars[idx].tdz_emitted_at_decl = true;
                    break :blk idx;
                } else blk: {
                    // For async/generator function declarations in block scope
                    // (non-strict, no Annex B var), create a lexical binding in
                    // the current scope, matching QuickJS `define_var` path for
                    // `JS_VAR_DEF_NEW_FUNCTION_DECL` which always sets
                    // `is_lexical = 1`.
                    if (is_block_level_function_decl and func_kind != .normal) {
                        const vk: function_def_mod.VarKind = .new_function_decl;
                        break :blk @intCast(try parent_fd.addScopeVar(name, vk, parent_fd.scope_level, true, false));
                    }
                    if (s.findFunctionScopeVar(name)) |idx| break :blk idx;
                    break :blk @intCast(try parent_fd.addScopeVar(name, .function_decl, 0, false, false));
                };
                child_fd.child_decl_var_idx = function_decl_idx;
                child_fd.child_decl_emit_inline = child_fd.child_decl_emit_inline or
                    duplicate_hoisted_block_func or
                    (is_block_level_function_decl and
                        !child_fd.child_decl_force_local_init and
                        !child_fd.child_decl_emit_global_inline and
                        parent_fd.vars[function_decl_idx].is_lexical);
                if (!child_fd.child_decl_emit_global_inline and
                    !(s.annex_b_if_function_decl_clause and !annex_b_if_function_var))
                {
                    try s.retrofitForwardLocalFunctionCapture(parent_fd, name, function_decl_idx);
                }
            }
        }
        try s.pushFunction(child_fd);
        child_owned_before_push = false;
        child_pushed = true;
        s.emit_to_function_def = true;
        s.scope_level = 0;
        s.is_eval = false;
        s.eval_ret_idx = -1;
        s.return_depth = if (func_kind == .class_static_block) 0 else 1;
        s.return_expr_mode = false;
        s.return_expr_cond_depth = 0;
        s.return_expr_emitted_return = false;
    }

    const function_pending_name = s.pending_function_name;
    const function_pending_decl = s.pending_function_is_decl;
    s.pending_function_name = null;
    s.pending_function_is_decl = false;

    const is_class_static_block = func_kind == .class_static_block;
    var param_count: u32 = 0;
    var simple_param_names = std.ArrayList(Atom).empty;
    defer simple_param_names.deinit(s.function.memory.allocator);
    var has_duplicate_simple_params = false;
    var has_simple_parameter_list = true;
    var first_default_param: ?u32 = null;
    var has_rest_parameter = false;
    var all_param_names = std.ArrayList(?Atom).empty;
    defer all_param_names.deinit(s.function.memory.allocator);

    if (!is_class_static_block) {
        s.reject_await_in_parameter_initializer = func_kind == .async or func_kind == .async_generator;
        defer s.reject_await_in_parameter_initializer = saved_reject_await_in_parameter_initializer;
        try s.expectToken('(');
        all_param_names = try collectSimpleArrowParamNames(s);

        // Parse parameters, including default values, destructuring, and rest.
        while (s.peekKind() != ')' and s.peekKind() != tok.TOK_EOF) {
            var has_modifier = false;
            if (s.lex.is_typescript and (func_kind == .class_constructor or func_kind == .derived_class_constructor)) {
                while (s.isParameterModifier()) {
                    has_modifier = true;
                    try s.advance();
                }
            }
            if (isIdentifierLikeToken(s)) {
                // Simple parameter
                const param_atom = identifierLikeAtom(s);
                if (has_modifier) {
                    if (s.current_parameter_properties) |*props| {
                        try props.append(s.function.memory.allocator, param_atom);
                    }
                }
                const arg_index = param_count;
                const strict_params = s.is_strict or s.cur_func().is_strict_mode;
                if (func_kind == .set and strict_params and
                    (atomNameEquals(s, param_atom, "eval") or atomNameEquals(s, param_atom, "arguments")))
                {
                    return Error.UnexpectedToken;
                }
                for (simple_param_names.items) |existing| {
                    if (existing == param_atom) {
                        has_duplicate_simple_params = true;
                        if (strict_params) return Error.UnexpectedToken;
                        break;
                    }
                }
                try simple_param_names.append(s.function.memory.allocator, param_atom);
                if (capture_child) {
                    _ = try s.cur_func().appendArg(.{
                        .var_name = param_atom,
                        .scope_level = 0,
                        .is_lexical = false,
                        .is_const = false,
                        .var_kind = .normal,
                    });
                }
                try s.advance();
                param_count += 1;

                // Check for default value
                if (s.peekKind() == '=') {
                    has_simple_parameter_list = false;
                    if (first_default_param == null) first_default_param = arg_index;
                    try s.advance();
                    if (capture_child) {
                        try emitPushBindingSource(s, .{ .arg = arg_index });
                        try s.emitOp(opcode.op.is_undefined);
                        const keep_value = try emitForwardJump(s, opcode.op.if_false);
                        const saved_in_parameter_initializer = s.in_parameter_initializer;
                        s.in_parameter_initializer = true;
                        defer s.in_parameter_initializer = saved_in_parameter_initializer;
                        if (defaultInitializerHitsParameterTdz(s, all_param_names.items, arg_index)) {
                            try emitSyntheticTdzReference(s);
                            try s.advance();
                        } else {
                            try parseNamedBindingDefaultInitializer(s, param_atom);
                        }
                        try emitStoreBindingSourceKeep(s, .{ .arg = arg_index });
                        try s.emitOp(opcode.op.drop);
                        try patchForwardJump(s, keep_value);
                    } else {
                        const saved_in_parameter_initializer = s.in_parameter_initializer;
                        s.in_parameter_initializer = true;
                        defer s.in_parameter_initializer = saved_in_parameter_initializer;
                        try parseNamedBindingDefaultInitializer(s, param_atom);
                        try s.emitOp(opcode.op.drop);
                    }
                }
            } else if (s.peekKind() == '{') {
                // Object destructuring parameter: {a, b}
                has_simple_parameter_list = false;
                const arg_index = param_count;
                if (capture_child) try ensureDestructuringArgSlot(s, arg_index);
                try parseDestructuringParam(s, .object, if (capture_child) arg_index else null);
                param_count += 1;
            } else if (s.peekKind() == '[') {
                // Array destructuring parameter: [a, b]
                has_simple_parameter_list = false;
                const arg_index = param_count;
                if (capture_child) try ensureDestructuringArgSlot(s, arg_index);
                try parseDestructuringParam(s, .array, if (capture_child) arg_index else null);
                param_count += 1;
            } else if (s.peekKind() == tok.TOK_ELLIPSIS) {
                // Rest parameter
                s.features.insert(.spread_rest);
                has_simple_parameter_list = false;
                const arg_index = param_count;
                try s.advance();
                has_rest_parameter = true;
                if (isIdentifierLikeToken(s)) {
                    if (identifierLikeHasInvalidEscapeForBinding(s)) return Error.UnexpectedToken;
                    const rest_atom = identifierLikeAtom(s);
                    for (simple_param_names.items) |existing| {
                        if (existing == rest_atom) return Error.UnexpectedToken;
                    }
                    try simple_param_names.append(s.function.memory.allocator, rest_atom);
                    if (capture_child) {
                        const idx = try s.cur_func().appendArg(.{
                            .var_name = rest_atom,
                            .scope_level = 0,
                            .is_lexical = false,
                            .is_const = false,
                            .var_kind = .normal,
                        });
                        if (idx != @as(i32, @intCast(arg_index))) return Error.UnexpectedToken;
                        try s.emitOpU16(opcode.op.rest, @intCast(arg_index));
                        try emitStoreBindingSourceKeep(s, .{ .arg = arg_index });
                        try s.emitOp(opcode.op.drop);
                        s.cur_func().defined_arg_count = @intCast(arg_index);
                    }
                    try s.advance();
                } else if (s.peekKind() == '[') {
                    if (capture_child) {
                        try ensureDestructuringArgSlot(s, arg_index);
                        try s.emitOpU16(opcode.op.rest, @intCast(arg_index));
                        try emitStoreBindingSourceKeep(s, .{ .arg = arg_index });
                        try s.emitOp(opcode.op.drop);
                        s.cur_func().defined_arg_count = @intCast(arg_index);
                    }
                    try parseDestructuringParam(s, .array, if (capture_child) arg_index else null);
                } else if (s.peekKind() == '{') {
                    if (capture_child) {
                        try ensureDestructuringArgSlot(s, arg_index);
                        try s.emitOpU16(opcode.op.rest, @intCast(arg_index));
                        try emitStoreBindingSourceKeep(s, .{ .arg = arg_index });
                        try s.emitOp(opcode.op.drop);
                        s.cur_func().defined_arg_count = @intCast(arg_index);
                    }
                    try parseDestructuringParam(s, .object, if (capture_child) arg_index else null);
                } else {
                    return Error.UnexpectedToken;
                }
                break;
            } else {
                return Error.UnexpectedToken;
            }

            if (s.peekKind() == ',') {
                try s.advance();
            } else if (s.peekKind() != ')') {
                return Error.UnexpectedToken;
            }
        }

        try s.expectToken(')');
    }
    if (func_kind == .get and (param_count != 0 or has_rest_parameter)) return Error.UnexpectedToken;
    if (func_kind == .set and (param_count != 1 or has_rest_parameter)) return Error.UnexpectedToken;
    if (capture_child) s.cur_func().has_simple_parameter_list = has_simple_parameter_list;
    if (capture_child) {
        if (first_default_param) |defined_count| {
            s.cur_func().defined_arg_count = @intCast(defined_count);
        }
    }

    if (capture_child) try predeclareFunctionBodyVars(s);
    if (capture_child and (func_kind == .generator or func_kind == .async_generator)) {
        try s.emitOp(opcode.op.push_false);
        try s.emitOp(opcode.op.drop);
        try s.emitOp(opcode.op.push_true);
        try s.emitOp(opcode.op.drop);
    }
    // Break/continue label resolution does not cross function boundaries.
    const saved_control_frames = s.enterControlBoundary();
    var control_boundary_active = true;
    errdefer if (control_boundary_active) s.leaveControlBoundary(saved_control_frames);
    if (!capture_child) s.return_depth += 1;
    defer {
        if (!capture_child) s.return_depth -= 1;
    }
    s.suppress_block_enter_scope = true;
    try parseBlock(s);
    if (s.is_strict) s.cur_func().is_strict_mode = true;
    if (s.cur_func().is_strict_mode) {
        if (s.cur_func().has_use_strict and !has_simple_parameter_list) return Error.UnexpectedToken;
        switch (func_kind) {
            .normal, .async, .generator, .async_generator => {
                if (function_pending_name) |name| {
                    if (isInvalidStrictFunctionBindingName(s, name)) return Error.UnexpectedToken;
                }
            },
            else => {},
        }
        for (simple_param_names.items) |param_name| {
            if (isInvalidStrictFunctionBindingName(s, param_name)) return Error.UnexpectedToken;
        }
    }
    if (has_duplicate_simple_params and (func_kind != .normal or !has_simple_parameter_list or s.is_strict or s.cur_func().is_strict_mode)) return Error.UnexpectedToken;
    s.leaveControlBoundary(saved_control_frames);
    control_boundary_active = false;
    if (capture_child) {
        const code = s.currentCode();
        const needs_return = functionNeedsImplicitReturn(code);
        if (needs_return) {
            if (func_kind == .async) {
                try s.emitOp(opcode.op.undefined);
                try s.emitOp(opcode.op.return_async);
            } else if (func_kind == .generator or func_kind == .async_generator) {
                try s.emitOp(opcode.op.undefined);
                try s.emitOp(opcode.op.return_async);
            } else if (func_kind == .derived_class_constructor) {
                const this_idx = s.cur_func().this_var_idx;
                if (this_idx < 0) return Error.UnexpectedToken;
                try s.emitOpU16(opcode.op.get_loc_check, @intCast(this_idx));
                try s.emitOp(opcode.op.@"return");
            } else if (code.len != 0 and code[code.len - 1] == opcode.op.drop) {
                var mutable_code = s.currentCode();
                mutable_code[mutable_code.len - 1] = opcode.op.return_undef;
            } else {
                try s.emitOp(opcode.op.return_undef);
            }
        }
    }

    s.pending_function_name = function_pending_name;
    s.pending_function_is_decl = function_pending_decl;

    if (capture_child) {
        if (source_start) |start| try s.captureFunctionSource(s.cur_func(), start);
        const child_ptr = s.popFunction();
        child_pushed = false;
        var child_moved = false;
        errdefer if (!child_moved) {
            s.discardFunctionDef(child_ptr);
        };
        s.emit_to_function_def = saved_emit_to_function_def;
        s.scope_level = saved_scope_level;
        s.is_eval = saved_is_eval;
        s.eval_ret_idx = saved_eval_ret_idx;
        s.return_depth = saved_return_depth;
        s.return_expr_mode = saved_return_expr_mode;
        s.return_expr_cond_depth = saved_return_expr_cond_depth;
        s.return_expr_emitted_return = saved_return_expr_emitted_return;
        s.is_strict = saved_is_strict;
        s.lex.is_strict_mode = saved_lex_is_strict;
        const child_cpool_idx: u16 = @intCast(try parent_fd.appendCpool(JSValue.undefinedValue()));
        const keep_child_value = child_ptr.child_decl_init_keep_value;
        const emit_child_decl_inline = child_ptr.child_decl_emit_inline;
        const emit_child_decl_var_inline = child_ptr.child_decl_emit_var_inline;
        const child_decl_skip_init = child_ptr.child_decl_skip_init;
        const emit_child_decl_global_inline = child_ptr.child_decl_emit_global_inline;
        const child_decl_var_idx = child_ptr.child_decl_var_idx;
        const child_decl_annex_b_var_idx = child_ptr.child_decl_annex_b_var_idx;
        child_ptr.parent_cpool_idx = child_cpool_idx;
        try attachVisibleClassPrivateBoundNamesToFunction(s, child_ptr);
        try parent_fd.addChild(child_ptr.*);
        child_moved = true;
        s.function.memory.destroy(function_def_mod.FunctionDef, child_ptr);
        s.last_function_child_index = @intCast(parent_fd.child_list.len - 1);
        if (!s.pending_function_is_decl) {
            try s.emitFClosure8(@intCast(child_cpool_idx));
            s.last_anonymous_function_expr = s.pending_function_name == null;
        } else if (emit_child_decl_global_inline and !emit_child_decl_inline) {
            try s.emitFClosure8(@intCast(child_cpool_idx));
            const name = s.pending_function_name orelse s.function.name;
            try s.emitOpAtomU8(opcode.op.define_func, name, (1 << 5) | (1 << 4));
        } else if (emit_child_decl_inline) {
            if (child_decl_skip_init) return;
            std.debug.assert(child_decl_var_idx >= 0);
            try s.emitFClosure8(@intCast(child_cpool_idx));
            if (emit_child_decl_global_inline) try s.emitOp(opcode.op.dup);
            if (emit_child_decl_var_inline) {
                try s.emitOpU16(opcode.op.put_loc, @intCast(child_decl_var_idx));
            } else {
                if (child_decl_annex_b_var_idx >= 0) try s.emitOp(opcode.op.dup);
                try s.emitOpU16(opcode.op.put_loc_check_init, @intCast(child_decl_var_idx));
            }
            if (!emit_child_decl_var_inline and child_decl_annex_b_var_idx >= 0) {
                try s.emitOpU16(opcode.op.put_loc, @intCast(child_decl_annex_b_var_idx));
            }
            if (emit_child_decl_global_inline) {
                const name = s.pending_function_name orelse s.function.name;
                try s.emitOpAtomU8(opcode.op.define_func, name, 0);
            }
        } else if (keep_child_value) {
            s.skip_next_ident_get = s.pending_function_name;
        }
        if (s.namespace_export) {
            if (s.current_namespace_atom) |ns_atom| {
                const func_atom = child_ptr.func_name;
                if (func_atom != atom_module.ids.empty_string) {
                    try s.emitScopeGetVar(ns_atom);
                    try s.emitScopeGetVar(func_atom);
                    try s.emitOpAtom(opcode.op.put_field, func_atom);
                }
            }
        }
    }
}

/// Parse arrow function
/// Mirrors arrow function parsing in quickjs.c
fn parseArrowFunction(s: *ParseState, func_kind: ParseFunctionKind, source_start: usize, body_flags: ParseFlags) Error!void {
    s.features.insert(.function_);
    s.features.insert(.arrow);
    if (func_kind == .async or func_kind == .async_generator) {
        s.features.insert(.async_function);
    }
    const parent_fd = s.cur_func();
    const capture_child = s.cur_func_stack.len > 0 or s.top_level_functions_as_children;
    const saved_emit_to_function_def = s.emit_to_function_def;
    const saved_scope_level = s.scope_level;
    const saved_is_eval = s.is_eval;
    const saved_eval_ret_idx = s.eval_ret_idx;
    const saved_pending_name = s.pending_function_name;
    const saved_pending_decl = s.pending_function_is_decl;
    const saved_return_depth = s.return_depth;
    const saved_return_expr_mode = s.return_expr_mode;
    const saved_return_expr_cond_depth = s.return_expr_cond_depth;
    const saved_return_expr_emitted_return = s.return_expr_emitted_return;
    const saved_is_strict = s.is_strict;
    const saved_lex_is_strict = s.lex.is_strict_mode;
    const saved_new_target_allowed = s.new_target_allowed;
    const saved_in_constructor = s.in_constructor;
    s.in_constructor = false;
    defer s.in_constructor = saved_in_constructor;
    const saved_parameter_properties = s.current_parameter_properties;
    s.current_parameter_properties = null;
    defer s.current_parameter_properties = saved_parameter_properties;

    const arrow_new_target_allowed = saved_new_target_allowed;
    var child_pushed = false;
    errdefer if (child_pushed) {
        s.discardCurrentFunction();
        s.emit_to_function_def = saved_emit_to_function_def;
        s.scope_level = saved_scope_level;
        s.is_eval = saved_is_eval;
        s.eval_ret_idx = saved_eval_ret_idx;
        s.return_depth = saved_return_depth;
        s.return_expr_mode = saved_return_expr_mode;
        s.return_expr_cond_depth = saved_return_expr_cond_depth;
        s.return_expr_emitted_return = saved_return_expr_emitted_return;
        s.is_strict = saved_is_strict;
        s.lex.is_strict_mode = saved_lex_is_strict;
        s.new_target_allowed = saved_new_target_allowed;
    };
    const saved_return_finally = if (capture_child) enterReturnFinallyFunctionBoundary(s) else null;
    defer if (saved_return_finally) |saved| leaveReturnFinallyFunctionBoundary(s, saved);
    s.pending_function_name = null;
    s.pending_function_is_decl = false;
    defer {
        s.pending_function_name = saved_pending_name;
        s.pending_function_is_decl = saved_pending_decl;
    }

    if (capture_child) {
        const child_fd = try s.function.memory.create(function_def_mod.FunctionDef);
        var child_owned_before_push = true;
        errdefer if (child_owned_before_push) s.discardFunctionDef(child_fd);
        child_fd.* = function_def_mod.FunctionDef.init(s.function.memory, s.function.atoms, atom_module.ids.empty_string);
        child_fd.atoms.replace(&child_fd.filename, parent_fd.filename);
        child_fd.line_num = @intCast(s.token.line_num);
        child_fd.col_num = @intCast(s.token.col_num);
        child_fd.parent = parent_fd;
        child_fd.parent_scope_level = if (s.in_parameter_initializer) -1 else parent_fd.scope_level;
        child_fd.is_strict_mode = parent_fd.is_strict_mode or s.is_strict or s.lex.is_strict_mode;
        child_fd.is_indirect_eval = parent_fd.is_indirect_eval;
        child_fd.use_short_opcodes = parent_fd.use_short_opcodes;
        child_fd.func_type = .arrow;
        child_fd.func_kind = if (func_kind == .async) .async else .normal;
        child_fd.has_prototype = false;
        child_fd.new_target_allowed = arrow_new_target_allowed;
        child_fd.super_allowed = s.allow_super;
        child_fd.super_call_allowed = s.allow_super_call;
        _ = child_fd.appendScope(-1) catch return error.OutOfMemory;
        try s.pushFunction(child_fd);
        child_owned_before_push = false;
        child_pushed = true;
        s.emit_to_function_def = true;
        s.scope_level = 0;
        s.is_eval = false;
        s.eval_ret_idx = -1;
        s.return_depth = 1;
        s.return_expr_mode = false;
        s.return_expr_cond_depth = 0;
        s.return_expr_emitted_return = false;
    }
    s.new_target_allowed = arrow_new_target_allowed;
    defer s.new_target_allowed = saved_new_target_allowed;

    // Set async flag for await parsing. Arrow parameter lists inherit the
    // enclosing Await grammar parameter, while the body uses the arrow's own
    // async-ness.
    const was_async = s.in_async;
    const is_async = func_kind == .async or func_kind == .async_generator;
    const params_in_async = is_async or was_async or s.lex.is_module or s.in_class_static_block;
    s.in_async = params_in_async;
    defer s.in_async = was_async;
    const saved_reject_await_in_parameter_initializer = s.reject_await_in_parameter_initializer;
    s.reject_await_in_parameter_initializer = params_in_async;
    defer s.reject_await_in_parameter_initializer = saved_reject_await_in_parameter_initializer;

    // Parse parameters. Two valid head shapes:
    //   `ident => ...`    — single bare identifier parameter
    //   `(...) => ...`    — parenthesized parameter list
    var has_non_simple_params = false;
    if (isIdentifierLikeToken(s)) {
        // Single bare identifier parameter.
        if (identifierLikeHasInvalidEscapeForBinding(s)) return Error.UnexpectedToken;
        const param_atom = identifierLikeAtom(s);
        if ((s.is_strict or s.cur_func().is_strict_mode) and isInvalidStrictFunctionBindingName(s, param_atom)) {
            return Error.UnexpectedToken;
        }
        if (capture_child) {
            _ = try s.cur_func().appendArg(.{
                .var_name = param_atom,
                .scope_level = 0,
                .is_lexical = false,
                .is_const = false,
                .var_kind = .normal,
            });
        }
        try s.advance();
    } else {
        try s.expectToken('(');

        // Parse parameters, including default values, destructuring, and rest.
        var param_count: u32 = 0;
        var first_default_param: ?u32 = null;
        var all_param_names = try collectSimpleArrowParamNames(s);
        defer all_param_names.deinit(s.function.memory.allocator);
        var param_names: std.ArrayList(Atom) = .empty;
        defer param_names.deinit(s.function.memory.allocator);
        while (s.peekKind() != ')' and s.peekKind() != tok.TOK_EOF) {
            if (isIdentifierLikeToken(s)) {
                if (identifierLikeHasInvalidEscapeForBinding(s)) return Error.UnexpectedToken;
                const param_atom = identifierLikeAtom(s);
                try appendArrowParamBindingName(s, &param_names, param_atom);
                const arg_index = param_count;
                if (capture_child) {
                    _ = try s.cur_func().appendArg(.{
                        .var_name = param_atom,
                        .scope_level = 0,
                        .is_lexical = false,
                        .is_const = false,
                        .var_kind = .normal,
                    });
                }
                try s.advance();
                param_count += 1;
                if (s.peekKind() == '=') {
                    has_non_simple_params = true;
                    if (first_default_param == null) first_default_param = arg_index;
                    try s.advance();
                    if (capture_child) {
                        try emitPushBindingSource(s, .{ .arg = arg_index });
                        try s.emitOp(opcode.op.is_undefined);
                        const keep_value = try emitForwardJump(s, opcode.op.if_false);
                        const saved_in_parameter_initializer = s.in_parameter_initializer;
                        s.in_parameter_initializer = true;
                        defer s.in_parameter_initializer = saved_in_parameter_initializer;
                        if (defaultInitializerHitsParameterTdz(s, all_param_names.items, arg_index)) {
                            try emitSyntheticTdzReference(s);
                            try s.advance();
                        } else {
                            try parseNamedBindingDefaultInitializer(s, param_atom);
                        }
                        try emitStoreBindingSourceKeep(s, .{ .arg = arg_index });
                        try s.emitOp(opcode.op.drop);
                        try patchForwardJump(s, keep_value);
                    } else {
                        const saved_in_parameter_initializer = s.in_parameter_initializer;
                        s.in_parameter_initializer = true;
                        defer s.in_parameter_initializer = saved_in_parameter_initializer;
                        try parseNamedBindingDefaultInitializer(s, param_atom);
                        try s.emitOp(opcode.op.drop);
                    }
                }
            } else if (s.peekKind() == '{') {
                // Object destructuring parameter
                const arg_index = param_count;
                has_non_simple_params = true;
                try collectArrowPatternBindingNamesSnapshot(s, .object, &param_names);
                if (capture_child) try ensureDestructuringArgSlot(s, arg_index);
                try parseDestructuringParam(s, .object, if (capture_child) arg_index else null);
                param_count += 1;
            } else if (s.peekKind() == '[') {
                // Array destructuring parameter
                const arg_index = param_count;
                has_non_simple_params = true;
                try collectArrowPatternBindingNamesSnapshot(s, .array, &param_names);
                if (capture_child) try ensureDestructuringArgSlot(s, arg_index);
                try parseDestructuringParam(s, .array, if (capture_child) arg_index else null);
                param_count += 1;
            } else if (s.peekKind() == tok.TOK_ELLIPSIS) {
                s.features.insert(.spread_rest);
                has_non_simple_params = true;
                const arg_index = param_count;
                try s.advance();
                if (isIdentifierLikeToken(s)) {
                    if (identifierLikeHasInvalidEscapeForBinding(s)) return Error.UnexpectedToken;
                    const param_atom = identifierLikeAtom(s);
                    try appendArrowParamBindingName(s, &param_names, param_atom);
                    if (capture_child) {
                        const idx = try s.cur_func().appendArg(.{
                            .var_name = param_atom,
                            .scope_level = 0,
                            .is_lexical = false,
                            .is_const = false,
                            .var_kind = .normal,
                        });
                        if (idx != @as(i32, @intCast(arg_index))) return Error.UnexpectedToken;
                        try s.emitOpU16(opcode.op.rest, @intCast(arg_index));
                        try emitStoreBindingSourceKeep(s, .{ .arg = arg_index });
                        try s.emitOp(opcode.op.drop);
                        s.cur_func().defined_arg_count = @intCast(arg_index);
                    }
                    try s.advance();
                } else if (s.peekKind() == '[') {
                    try collectArrowPatternBindingNamesSnapshot(s, .array, &param_names);
                    if (capture_child) {
                        try ensureDestructuringArgSlot(s, arg_index);
                        try s.emitOpU16(opcode.op.rest, @intCast(arg_index));
                        try emitStoreBindingSourceKeep(s, .{ .arg = arg_index });
                        try s.emitOp(opcode.op.drop);
                        s.cur_func().defined_arg_count = @intCast(arg_index);
                    }
                    try parseDestructuringParam(s, .array, if (capture_child) arg_index else null);
                } else if (s.peekKind() == '{') {
                    try collectArrowPatternBindingNamesSnapshot(s, .object, &param_names);
                    if (capture_child) {
                        try ensureDestructuringArgSlot(s, arg_index);
                        try s.emitOpU16(opcode.op.rest, @intCast(arg_index));
                        try emitStoreBindingSourceKeep(s, .{ .arg = arg_index });
                        try s.emitOp(opcode.op.drop);
                        s.cur_func().defined_arg_count = @intCast(arg_index);
                    }
                    try parseDestructuringParam(s, .object, if (capture_child) arg_index else null);
                } else {
                    return Error.UnexpectedToken;
                }
                break;
            } else {
                return Error.UnexpectedToken;
            }

            if (s.peekKind() == ',') {
                try s.advance();
            } else if (s.peekKind() != ')') {
                return Error.UnexpectedToken;
            }
        }

        try s.expectToken(')');
        if (s.is_strict or s.cur_func().is_strict_mode) {
            for (param_names.items) |param_name| {
                if (isInvalidStrictFunctionBindingName(s, param_name)) return Error.UnexpectedToken;
            }
        }
        if (capture_child) {
            if (first_default_param) |defined_count| {
                s.cur_func().defined_arg_count = @intCast(defined_count);
            }
        }
    }

    if (capture_child) {
        s.cur_func().has_simple_parameter_list = !has_non_simple_params;
    }

    // Expect =>
    if (s.lex.got_lf) return Error.UnexpectedToken;
    try s.expectToken(tok.TOK_ARROW);
    s.in_async = is_async;

    const saved_static_block = s.in_class_static_block;
    s.in_class_static_block = false;
    defer s.in_class_static_block = saved_static_block;

    // Break/continue and active iterator cleanup do not cross function
    // boundaries. Keep arrows aligned with ordinary function bodies so a
    // return inside an arrow nested in for-of does not close the outer iterator.
    const saved_control_frames = s.enterControlBoundary();
    var control_boundary_active = true;
    errdefer if (control_boundary_active) s.leaveControlBoundary(saved_control_frames);

    // Parse body (can be block or expression).
    // parseBlock consumes its own opening '{'.
    if (s.peekKind() == '{') {
        if (has_non_simple_params and arrowBlockStartsUseStrict(s)) return Error.UnexpectedToken;
        if (!capture_child) s.return_depth += 1;
        defer {
            if (!capture_child) s.return_depth -= 1;
        }
        s.suppress_block_enter_scope = true;
        try parseBlock(s);
        if (capture_child) {
            const code = s.currentCode();
            const needs_return = functionNeedsImplicitReturn(code);
            if (needs_return) {
                if (is_async) {
                    try s.emitOp(opcode.op.undefined);
                    try s.emitOp(opcode.op.return_async);
                } else if (code.len != 0 and code[code.len - 1] == opcode.op.drop) {
                    var mutable_code = s.currentCode();
                    mutable_code[mutable_code.len - 1] = opcode.op.return_undef;
                } else {
                    try s.emitOp(opcode.op.return_undef);
                }
            }
        }
    } else {
        // Expression body
        try parseAssignExpr2(s, .{ .in_accepted = body_flags.in_accepted });
        if (rewriteTrailingCallAsTailCall(s) != .rewrote) {
            try s.emitOp(opcode.op.@"return");
        }
    }
    s.leaveControlBoundary(saved_control_frames);
    control_boundary_active = false;

    if (capture_child) {
        try s.captureFunctionSource(s.cur_func(), source_start);
        const child_ptr = s.popFunction();
        child_pushed = false;
        var child_moved = false;
        errdefer if (!child_moved) {
            s.discardFunctionDef(child_ptr);
        };
        s.emit_to_function_def = saved_emit_to_function_def;
        s.scope_level = saved_scope_level;
        s.is_eval = saved_is_eval;
        s.eval_ret_idx = saved_eval_ret_idx;
        s.return_depth = saved_return_depth;
        s.return_expr_mode = saved_return_expr_mode;
        s.return_expr_cond_depth = saved_return_expr_cond_depth;
        s.return_expr_emitted_return = saved_return_expr_emitted_return;
        s.is_strict = saved_is_strict;
        s.lex.is_strict_mode = saved_lex_is_strict;
        s.new_target_allowed = saved_new_target_allowed;
        const child_cpool_idx: u16 = @intCast(try parent_fd.appendCpool(JSValue.undefinedValue()));
        child_ptr.parent_cpool_idx = child_cpool_idx;
        try attachVisibleClassPrivateBoundNamesToFunction(s, child_ptr);
        try parent_fd.addChild(child_ptr.*);
        child_moved = true;
        s.function.memory.destroy(function_def_mod.FunctionDef, child_ptr);
        s.last_function_child_index = @intCast(parent_fd.child_list.len - 1);
        try s.emitFClosure8(@intCast(child_cpool_idx));
        s.last_anonymous_function_expr = true;
    }
}

const TrailingCallRewrite = enum {
    /// No rewrite happened; the caller must emit its return opcode.
    none,
    /// Trailing call rewritten to a tail call and nothing jumps to the
    /// current end: the tail call subsumes the return entirely.
    rewrote,
    /// Trailing call rewritten to a tail call, but short-circuit paths
    /// (`&&` / `||` / `??` / optional chains) jump to the current end
    /// carrying their own result value: the caller must still emit the
    /// return opcode for those paths to land on.
    rewrote_jump_target,
};

const TrailingScan = struct { last_op_index: usize, jump_to_end: bool };

/// Decode the current (Phase 1) code linearly to find the last
/// instruction boundary and whether any jump targets the current end.
/// Sizes come from the phase-1 metadata view (`opcode.sizeOfPhase1`),
/// which resolves the temp/short id overlap to the temp forms the
/// parser actually emits. Returns null when the stream cannot be
/// decoded, keeping tail-call rewriting disabled.
fn scanTrailingCode(code: []const u8, include_conditional: bool) ?TrailingScan {
    var pc: usize = 0;
    var last_op_index: usize = 0;
    var jump_to_end = false;
    while (pc < code.len) {
        const op_id = code[pc];
        // `scope_make_ref` embeds a label operand this scan does not
        // track; bail out rather than miss a jump to the current end.
        if (op_id == opcode.op.scope_make_ref) return null;
        // Id 192 is ambiguous in phase-1 streams (`push_empty_string`
        // short form vs `scope_in_private_field` temp); it cannot be
        // sized from the id alone.
        if (op_id == opcode.op.scope_in_private_field) return null;
        const size: usize = opcode.sizeOfPhase1(op_id);
        if (size == 0 or pc + size > code.len) return null;
        if (op_id == opcode.op.goto or
            (include_conditional and (op_id == opcode.op.if_false or op_id == opcode.op.if_true)))
        {
            const target = std.mem.readInt(u32, code[pc + 1 ..][0..4], .little);
            if (target == code.len) jump_to_end = true;
        }
        last_op_index = pc;
        pc += size;
    }
    return .{ .last_op_index = last_op_index, .jump_to_end = jump_to_end };
}

fn rewriteTrailingCallAsTailCall(s: *ParseState) TrailingCallRewrite {
    var code = s.currentCode();
    if (code.len < 3) return .none;
    const scan = scanTrailingCode(code, true) orelse return .none;
    // The trailing call opcode must be a real instruction boundary; a raw
    // `code[len - 3]` probe can hit operand payload bytes (e.g. push_i32).
    if (scan.last_op_index != code.len - 3) return .none;
    switch (code[scan.last_op_index]) {
        opcode.op.call => code[scan.last_op_index] = opcode.op.tail_call,
        opcode.op.call_method => code[scan.last_op_index] = opcode.op.tail_call_method,
        else => return .none,
    }
    return if (scan.jump_to_end) .rewrote_jump_target else .rewrote;
}

const DestructuringKind = enum { array, object };

const BindingSource = union(enum) {
    arg: u32,
    loc: u16,
};

fn appendArrowParamBindingName(s: *ParseState, names: *std.ArrayList(Atom), atom_id: Atom) Error!void {
    for (names.items) |existing| {
        if (existing == atom_id) return Error.UnexpectedToken;
    }
    try names.append(s.function.memory.allocator, atom_id);
}

fn collectArrowBindingIdentifier(s: *ParseState, names: *std.ArrayList(Atom)) Error!void {
    if (!isIdentifierLikeToken(s) or identifierLikeHasInvalidEscapeForBinding(s)) return Error.UnexpectedToken;
    const atom_id = identifierLikeAtom(s);
    try appendArrowParamBindingName(s, names, atom_id);
    try s.advance();
}

fn collectArrowPatternBindingNames(s: *ParseState, kind: DestructuringKind, names: *std.ArrayList(Atom)) Error!void {
    switch (kind) {
        .array => try collectArrowArrayBindingNames(s, names),
        .object => try collectArrowObjectBindingNames(s, names),
    }
}

fn collectArrowPatternBindingNamesSnapshot(s: *ParseState, kind: DestructuringKind, names: *std.ArrayList(Atom)) Error!void {
    const snapshot = takeParserSnapshot(s);
    defer restoreParserLexerSnapshot(s, snapshot);
    try collectArrowPatternBindingNames(s, kind, names);
}

fn collectArrowArrayBindingNames(s: *ParseState, names: *std.ArrayList(Atom)) Error!void {
    try s.expectToken('[');
    while (s.peekKind() != ']' and s.peekKind() != tok.TOK_EOF) {
        if (s.peekKind() == ',') {
            try s.advance();
            continue;
        }

        const is_rest = s.peekKind() == tok.TOK_ELLIPSIS;
        if (is_rest) try s.advance();

        if (isIdentifierLikeToken(s)) {
            try collectArrowBindingIdentifier(s, names);
        } else if (s.peekKind() == '[' or s.peekKind() == '{') {
            const nested_kind: DestructuringKind = if (s.peekKind() == '[') .array else .object;
            try collectArrowPatternBindingNames(s, nested_kind, names);
        } else {
            return Error.UnexpectedToken;
        }

        if (s.peekKind() == '=') {
            if (is_rest) return Error.UnexpectedToken;
            try s.advance();
            try skipInitializerInBindingPattern(s);
        }

        if (is_rest and s.peekKind() != ']') return Error.UnexpectedToken;
        if (s.peekKind() == ',') {
            try s.advance();
        } else if (s.peekKind() != ']') {
            return Error.UnexpectedToken;
        }
    }
    try s.expectToken(']');
}

fn collectArrowObjectBindingNames(s: *ParseState, names: *std.ArrayList(Atom)) Error!void {
    try s.expectToken('{');
    while (s.peekKind() != '}' and s.peekKind() != tok.TOK_EOF) {
        if (s.peekKind() == tok.TOK_ELLIPSIS) {
            try s.advance();
            try collectArrowBindingIdentifier(s, names);
            if (s.peekKind() != '}') return Error.UnexpectedToken;
            continue;
        }

        var prop_name: ?ObjectPropertyName = null;
        var has_binding_target = false;
        if (s.peekKind() == '[') {
            try skipBalancedPatternElement(s);
            try s.expectToken(':');
            has_binding_target = true;
        } else {
            prop_name = (try parseObjectPropertyName(s)) orelse return Error.UnexpectedToken;
        }
        defer if (prop_name) |name| {
            if (name.retained) s.function.atoms.free(name.atom);
        };

        if (has_binding_target or s.peekKind() == ':') {
            if (!has_binding_target) try s.advance();
            if (isIdentifierLikeToken(s)) {
                try collectArrowBindingIdentifier(s, names);
            } else if (s.peekKind() == '[' or s.peekKind() == '{') {
                const nested_kind: DestructuringKind = if (s.peekKind() == '[') .array else .object;
                try collectArrowPatternBindingNames(s, nested_kind, names);
            } else {
                return Error.UnexpectedToken;
            }
            if (s.peekKind() == '=') {
                try s.advance();
                try skipInitializerInBindingPattern(s);
            }
        } else {
            const name = prop_name orelse return Error.UnexpectedToken;
            if (!name.allow_shorthand or
                (name.has_escape and escapedIdentifierIsReservedWordForBinding(s, name.atom, true)))
            {
                return Error.UnexpectedToken;
            }
            try appendArrowParamBindingName(s, names, name.atom);
            if (s.peekKind() == '=') {
                try s.advance();
                try skipInitializerInBindingPattern(s);
            }
        }

        if (s.peekKind() == ',') {
            try s.advance();
        } else if (s.peekKind() != '}') {
            return Error.UnexpectedToken;
        }
    }
    try s.expectToken('}');
}

const ParserSnapshot = struct {
    pos: usize,
    line: u32,
    col: u32,
    got_lf: bool,
    mark_pos: usize,
    mark_line: u32,
    mark_col: u32,
    token: tok.Token,
    last_token_end_offset: usize,
    last_token_line_num: u32,
    last_token_col_num: u32,
    code_len: usize,
    atom_len: usize,
    features: std.EnumSet(Feature),
};

const LexerReplayPoint = struct {
    mark_pos: usize,
    mark_line: u32,
    mark_col: u32,
};

fn takeParserSnapshot(s: *ParseState) ParserSnapshot {
    return .{
        .pos = s.lex.pos,
        .line = s.lex.line,
        .col = s.lex.col,
        .got_lf = s.lex.got_lf,
        .mark_pos = s.lex.mark_pos,
        .mark_line = s.lex.mark_line,
        .mark_col = s.lex.mark_col,
        .token = s.token,
        .last_token_end_offset = s.last_token_end_offset,
        .last_token_line_num = s.last_token_line_num,
        .last_token_col_num = s.last_token_col_num,
        .code_len = s.currentCodeLen(),
        .atom_len = s.currentAtomOperandLen(),
        .features = s.features,
    };
}

fn takeLexerReplayPoint(s: *ParseState) LexerReplayPoint {
    return .{
        .mark_pos = s.lex.mark_pos,
        .mark_line = s.lex.mark_line,
        .mark_col = s.lex.mark_col,
    };
}

fn restoreLexerReplayPoint(s: *ParseState, point: LexerReplayPoint) Error!void {
    s.lex.freeToken(&s.token);
    s.lex.pos = point.mark_pos;
    s.lex.line = point.mark_line;
    s.lex.col = point.mark_col;
    s.lex.mark_pos = point.mark_pos;
    s.lex.mark_line = point.mark_line;
    s.lex.mark_col = point.mark_col;
    s.token = try s.lex.next();
}

fn objectLiteralPatternCandidateIsMemberTarget(s: *ParseState) Error!bool {
    const point = takeLexerReplayPoint(s);
    defer restoreLexerReplayPoint(s, point) catch {};
    if (s.peekKind() != @as(tok.TokenKind, @intCast('{'))) return false;

    var depth: usize = 0;
    while (s.peekKind() != tok.TOK_EOF) {
        const k = s.peekKind();
        if (k == @as(tok.TokenKind, @intCast('{'))) {
            depth += 1;
        } else if (k == @as(tok.TokenKind, @intCast('}'))) {
            if (depth == 0) return false;
            depth -= 1;
            try s.advance();
            if (depth == 0) {
                return s.peekKind() == @as(tok.TokenKind, @intCast('.')) or
                    s.peekKind() == @as(tok.TokenKind, @intCast('['));
            }
            continue;
        }
        try s.advance();
    }
    return false;
}

fn restoreParserSnapshot(s: *ParseState, snapshot: ParserSnapshot) Error!void {
    s.lex.freeToken(&s.token);
    s.lex.pos = snapshot.pos;
    s.lex.line = snapshot.line;
    s.lex.col = snapshot.col;
    s.lex.got_lf = snapshot.got_lf;
    s.lex.mark_pos = snapshot.mark_pos;
    s.lex.mark_line = snapshot.mark_line;
    s.lex.mark_col = snapshot.mark_col;
    s.token = snapshot.token;
    s.last_token_end_offset = snapshot.last_token_end_offset;
    s.last_token_line_num = snapshot.last_token_line_num;
    s.last_token_col_num = snapshot.last_token_col_num;
    try s.truncateCode(snapshot.code_len);
    try s.truncateAtomOperands(snapshot.atom_len);
    s.features = snapshot.features;
}

fn restoreParserLexerSnapshot(s: *ParseState, snapshot: ParserSnapshot) void {
    s.lex.freeToken(&s.token);
    s.lex.pos = snapshot.pos;
    s.lex.line = snapshot.line;
    s.lex.col = snapshot.col;
    s.lex.got_lf = snapshot.got_lf;
    s.lex.mark_pos = snapshot.mark_pos;
    s.lex.mark_line = snapshot.mark_line;
    s.lex.mark_col = snapshot.mark_col;
    s.token = snapshot.token;
    s.last_token_end_offset = snapshot.last_token_end_offset;
    s.last_token_line_num = snapshot.last_token_line_num;
    s.last_token_col_num = snapshot.last_token_col_num;
}

fn collectSimpleArrowParamNames(s: *ParseState) Error!std.ArrayList(?Atom) {
    const snapshot = takeParserSnapshot(s);
    defer restoreParserLexerSnapshot(s, snapshot);

    var names: std.ArrayList(?Atom) = .empty;
    errdefer names.deinit(s.function.memory.allocator);

    while (s.peekKind() != ')' and s.peekKind() != tok.TOK_EOF) {
        if (s.peekKind() == tok.TOK_IDENT) {
            try names.append(s.function.memory.allocator, s.token.payload.ident.atom);
            try s.advance();
            if (s.peekKind() == '=') {
                try s.advance();
                var depth: usize = 0;
                var previous_token_kind: ?tok.TokenKind = '=';
                while (s.peekKind() != tok.TOK_EOF) {
                    const k = s.peekKind();
                    if (depth == 0 and (k == ',' or k == ')')) break;
                    if (k == '(' or k == '[' or k == '{') depth += 1;
                    if ((k == ')' or k == ']' or k == '}') and depth > 0) depth -= 1;
                    try advanceRegexpAwareSpeculativeToken(s, &previous_token_kind);
                }
            }
        } else if (s.peekKind() == tok.TOK_ELLIPSIS) {
            try s.advance();
            if (s.peekKind() == tok.TOK_IDENT) {
                try names.append(s.function.memory.allocator, s.token.payload.ident.atom);
                try s.advance();
            } else {
                try names.append(s.function.memory.allocator, null);
            }
            break;
        } else {
            try names.append(s.function.memory.allocator, null);
            var depth: usize = 0;
            var previous_token_kind: ?tok.TokenKind = null;
            while (s.peekKind() != tok.TOK_EOF) {
                const k = s.peekKind();
                if (depth == 0 and (k == ',' or k == ')')) break;
                if (k == '(' or k == '[' or k == '{') depth += 1;
                if ((k == ')' or k == ']' or k == '}') and depth > 0) depth -= 1;
                try advanceRegexpAwareSpeculativeToken(s, &previous_token_kind);
            }
        }

        if (s.peekKind() == ',') {
            try s.advance();
        } else if (s.peekKind() != ')') {
            break;
        }
    }

    return names;
}

fn defaultInitializerHitsParameterTdz(s: *ParseState, param_names: []const ?Atom, arg_index: u32) bool {
    if (s.peekKind() != tok.TOK_IDENT) return false;
    const referenced = s.token.payload.ident.atom;
    const next = s.peekNextKind();
    if (next != ',' and next != ')') return false;
    const start: usize = @intCast(arg_index);
    if (start >= param_names.len) return false;
    for (param_names[start..]) |maybe_name| {
        if (maybe_name) |name| {
            if (name == referenced) return true;
        }
    }
    return false;
}

fn parameterInitializerContainsAwait(s: *ParseState) bool {
    const snapshot = takeParserSnapshot(s);
    defer restoreParserLexerSnapshot(s, snapshot);

    var paren_depth: usize = 0;
    var bracket_depth: usize = 0;
    var brace_depth: usize = 0;
    var previous_token_kind: ?tok.TokenKind = null;
    while (s.peekKind() != tok.TOK_EOF) {
        const k = s.peekKind();
        if (k == tok.TOK_AWAIT) return true;
        if (paren_depth == 0 and bracket_depth == 0 and brace_depth == 0 and
            (k == @as(tok.TokenKind, @intCast(',')) or k == @as(tok.TokenKind, @intCast(')'))))
        {
            return false;
        }
        switch (k) {
            '(' => paren_depth += 1,
            '[' => bracket_depth += 1,
            '{' => brace_depth += 1,
            ')' => {
                if (paren_depth == 0) return false;
                paren_depth -= 1;
            },
            ']' => {
                if (bracket_depth == 0) return false;
                bracket_depth -= 1;
            },
            '}' => {
                if (brace_depth == 0) return false;
                brace_depth -= 1;
            },
            else => {},
        }
        advanceRegexpAwareSpeculativeToken(s, &previous_token_kind) catch return false;
    }
    return false;
}

fn arrowBlockStartsUseStrict(s: *ParseState) bool {
    const snapshot = takeParserSnapshot(s);
    defer restoreParserLexerSnapshot(s, snapshot);

    if (s.peekKind() != '{') return false;
    s.advance() catch return false;
    if (s.peekKind() != tok.TOK_STRING) return false;
    const str_payload = s.token.payload.str;
    if (str_payload.bytes.len != 10 or !std.mem.eql(u8, str_payload.bytes, "use strict")) return false;
    const next = s.peekNextKind();
    return next == @as(tok.TokenKind, @intCast(';')) or next == @as(tok.TokenKind, @intCast('}'));
}

fn emitSyntheticTdzReference(s: *ParseState) Error!void {
    const temp = try appendTempLocal(s);
    try s.emitOpU16(opcode.op.set_loc_uninitialized, temp);
    try s.emitOpU16(opcode.op.get_loc_check, temp);
}

fn truncateSpeculativeParse(s: *ParseState, code_len: usize, atom_len: usize) Error!void {
    try s.truncateCode(code_len);
    try s.truncateAtomOperands(atom_len);
}

fn ensureDestructuringArgSlot(s: *ParseState, arg_index: u32) Error!void {
    const child = s.cur_func();
    while (child.args.len <= arg_index) {
        _ = try child.appendArg(.{
            .var_name = atom_module.null_atom,
            .scope_level = 0,
            .is_lexical = false,
            .is_const = false,
            .var_kind = .normal,
        });
    }
    const needed_args: i32 = @intCast(arg_index + 1);
    if (child.arg_count < needed_args) {
        child.arg_count = needed_args;
        child.defined_arg_count = needed_args;
    }
}

fn findCurrentScopeVar(s: *ParseState, atom_id: Atom) ?u16 {
    const vars = s.cur_func().vars;
    var i: usize = vars.len;
    while (i > 0) {
        i -= 1;
        if (vars[i].var_name == atom_id and vars[i].scope_level == s.scope_level) return @intCast(i);
    }
    return null;
}

fn findCurrentTopLevelLexicalClosureVar(s: *ParseState, atom_id: Atom) ?u16 {
    if (s.scope_level != 0) return null;
    for (s.cur_func().closure_var, 0..) |cv, idx| {
        if (cv.var_name == atom_id and cv.closure_type == .module_decl and cv.is_lexical) {
            return @intCast(idx);
        }
    }
    return null;
}

fn findCurrentTopLevelModuleDeclClosureVar(s: *ParseState, atom_id: Atom) ?u16 {
    if (s.scope_level != 0) return null;
    for (s.cur_func().closure_var, 0..) |cv, idx| {
        if (cv.var_name == atom_id and cv.closure_type == .module_decl) return @intCast(idx);
    }
    return null;
}

fn ensureTopLevelModuleDeclClosureVar(s: *ParseState, atom_id: Atom, is_lexical: bool, is_const: bool) Error!u16 {
    if (findCurrentTopLevelModuleDeclClosureVar(s, atom_id)) |idx| return idx;
    const ref_idx: u16 = @intCast(try s.cur_func().addClosureVar(.{
        .closure_type = .module_decl,
        .is_lexical = is_lexical,
        .is_const = is_const,
        .var_kind = .normal,
        .var_idx = @intCast(s.cur_func().closure_var.len),
        .var_name = atom_id,
    }));
    try s.retrofitForwardTopLevelModuleCapture(s.cur_func(), atom_id, ref_idx, is_lexical, is_const, .normal);
    return ref_idx;
}

fn appendBindingLocal(s: *ParseState, atom_id: Atom) Error!u16 {
    if (s.destructuring_binding_is_lexical) {
        try s.registerBlockLexicalDeclaration(atom_id);
        if (findCurrentScopeVar(s, atom_id)) |idx| {
            if (s.destructuring_predeclare_only) return Error.UnexpectedToken;
            return idx;
        }
        const idx: u16 = @intCast(try s.addScopeVar(atom_id, .normal, true, s.destructuring_binding_is_const));
        if (s.collect_module_export_bindings) {
            try addModuleExportName(s, atom_id, atom_id);
            if (s.top_level_lexical_as_module_ref and s.scope_level == 0) {
                _ = try ensureTopLevelModuleDeclClosureVar(s, atom_id, true, s.destructuring_binding_is_const);
            }
        }
        if (!s.suppress_destructuring_capture_retrofit) {
            try s.retrofitForwardLocalFunctionCapture(s.cur_func(), atom_id, idx);
        }
        if (s.emit_lexical_tdz_at_decl) {
            s.cur_func().vars[idx].tdz_emitted_at_decl = true;
            if (s.cur_func().use_short_opcodes) {
                try s.emitOpU16(opcode.op.set_loc_uninitialized, idx);
            }
        }
        return idx;
    }
    try s.registerBlockVarDeclaration(atom_id);
    const existing = s.cur_func().findVar(atom_id);
    if (existing >= 0) {
        const idx: usize = @intCast(existing);
        const entry = s.cur_func().vars[idx];
        if (!entry.is_lexical and entry.scope_level == 0 and entry.var_kind == .normal) {
            return @intCast(idx);
        }
    }
    const idx = try s.cur_func().appendVar(.{
        .var_name = atom_id,
        .scope_level = 0,
        .is_lexical = false,
        .is_const = false,
        .var_kind = .normal,
    });
    try s.retrofitForwardLocalFunctionCapture(s.cur_func(), atom_id, @intCast(idx));
    if (s.collect_module_export_bindings) {
        try addModuleExportName(s, atom_id, atom_id);
        if (s.top_level_lexical_as_module_ref and s.scope_level == 0) {
            _ = try ensureTopLevelModuleDeclClosureVar(s, atom_id, false, false);
        }
    }
    return @intCast(idx);
}

fn appendTempLocal(s: *ParseState) Error!u16 {
    return try appendAnonymousTempLocal(s);
}

fn appendAnonymousTempLocal(s: *ParseState) Error!u16 {
    const idx = try s.cur_func().appendVar(.{
        .var_name = atom_module.null_atom,
        .scope_level = 0,
        .is_lexical = false,
        .is_const = false,
        .var_kind = .normal,
    });
    return @intCast(idx);
}

fn emitPushBindingSource(s: *ParseState, source: BindingSource) Error!void {
    switch (source) {
        .arg => |idx| try s.emitOpU16(opcode.op.get_arg, @intCast(idx)),
        .loc => |idx| try s.emitOpU16(opcode.op.get_loc, idx),
    }
}

fn emitStoreBindingSourceKeep(s: *ParseState, source: BindingSource) Error!void {
    switch (source) {
        .arg => |idx| try s.emitOpU16(opcode.op.set_arg, @intCast(idx)),
        .loc => |idx| try s.emitOpU16(opcode.op.set_loc, idx),
    }
}

fn emitPutBindingLocal(s: *ParseState, idx: u16) Error!void {
    const atom_id = if (idx < s.cur_func().vars.len) s.cur_func().vars[idx].var_name else core.atom.null_atom;
    const module_ref_idx = if (atom_id != core.atom.null_atom and s.top_level_lexical_as_module_ref and s.scope_level == 0)
        findCurrentTopLevelModuleDeclClosureVar(s, atom_id)
    else
        null;
    if (s.destructuring_binding_is_lexical) {
        try s.emitOpU16(opcode.op.put_loc_check_init, idx);
        if (module_ref_idx) |ref_idx| {
            try s.emitOpU16(opcode.op.get_loc_check, idx);
            try s.emitPutVarRef(ref_idx);
        }
    } else {
        try s.emitOpU16(opcode.op.put_loc, idx);
        if (module_ref_idx) |ref_idx| {
            try s.emitOpU16(opcode.op.get_loc, idx);
            try s.emitPutVarRef(ref_idx);
        }
    }
}

fn emitBindingField(s: *ParseState, source: BindingSource, atom_id: Atom) Error!void {
    try emitPushBindingSource(s, source);
    try s.emitOpAtom(opcode.op.get_field, atom_id);
}

fn emitBindingIndex(s: *ParseState, source: BindingSource, index: u32) Error!void {
    try s.emitOpU8(opcode.op.special_object, opcode.special_object_subtype.dstr_get);
    try emitPushBindingSource(s, source);
    try s.emitOpI32(opcode.op.push_i32, @intCast(index));
    try s.emitOpU16(opcode.op.call, 2);
}

fn emitBindingElision(s: *ParseState, source: BindingSource, index: u32) Error!void {
    try s.emitOpU8(opcode.op.special_object, opcode.special_object_subtype.dstr_elide);
    try emitPushBindingSource(s, source);
    try s.emitOpI32(opcode.op.push_i32, @intCast(index));
    try s.emitOpU16(opcode.op.call, 2);
    try s.emitOp(opcode.op.drop);
}

fn emitCloseBindingSource(s: *ParseState, source: BindingSource) Error!void {
    try s.emitOpU8(opcode.op.special_object, opcode.special_object_subtype.dstr_close);
    try emitPushBindingSource(s, source);
    try s.emitOpU16(opcode.op.call, 1);
    try s.emitOp(opcode.op.drop);
}

fn emitRequireIteratorForBindingSource(s: *ParseState, source: BindingSource) Error!void {
    try s.emitOpU8(opcode.op.special_object, opcode.special_object_subtype.dstr_require_iterator);
    try emitPushBindingSource(s, source);
    try s.emitOpU16(opcode.op.call, 1);
    try emitStoreBindingSourceKeep(s, source);
    try s.emitOp(opcode.op.drop);
}

fn emitDefaultForBindingSource(s: *ParseState, source: BindingSource) Error!void {
    try emitPushBindingSource(s, source);
    try s.emitOp(opcode.op.is_undefined);
    const keep_value = try emitForwardJump(s, opcode.op.if_false);
    try parseAssignExpr(s);
    try emitStoreBindingSourceKeep(s, source);
    try s.emitOp(opcode.op.drop);
    try patchForwardJump(s, keep_value);
}

fn parseNamedBindingDefaultInitializer(s: *ParseState, atom_id: Atom) Error!void {
    if (s.reject_await_in_parameter_initializer and parameterInitializerContainsAwait(s)) {
        return Error.UnexpectedToken;
    }
    const saved_pending_name = s.pending_function_name;
    const saved_pending_decl = s.pending_function_is_decl;
    s.pending_function_name = atom_id;
    s.pending_function_is_decl = false;
    s.last_anonymous_function_expr = false;
    defer {
        s.pending_function_name = saved_pending_name;
        s.pending_function_is_decl = saved_pending_decl;
    }
    try parseAssignExpr(s);
    try emitAnonymousDefaultName(s, atom_id);
}

fn emitRequireObjectCoercibleForBindingSource(s: *ParseState, source: BindingSource) Error!void {
    try emitPushBindingSource(s, source);
    try s.emitOp(opcode.op.is_undefined_or_null);
    const keep_value = try emitForwardJump(s, opcode.op.if_false);
    try s.emitOpAtomU8(opcode.op.throw_error, atom_module.null_atom, 4);
    try patchForwardJump(s, keep_value);
}

fn emitAnonymousDefaultName(s: *ParseState, atom_id: Atom) Error!void {
    if (!s.last_anonymous_function_expr) return;
    try s.emitOpAtom(opcode.op.set_name, atom_id);
    s.last_anonymous_function_expr = false;
}

fn parseThisPrivateAssignmentTarget(s: *ParseState) Error!Atom {
    if (s.peekKind() != tok.TOK_THIS) return Error.UnexpectedToken;
    try s.advance();
    try s.expectToken('.');
    if (s.peekKind() != tok.TOK_PRIVATE_NAME or !s.in_class) return Error.UnexpectedToken;
    const private_atom = try privateNameAtom(s, s.token.payload.ident.atom);
    errdefer s.function.atoms.free(private_atom);
    if (!classPrivateNameIsBound(s, private_atom)) return Error.UnexpectedToken;
    try s.advance();
    return private_atom;
}

fn emitStoreThisPrivateReceiver(s: *ParseState) Error!u16 {
    const receiver_tmp = try appendTempLocal(s);
    try s.emitOp(opcode.op.push_this);
    try s.emitOpU16(opcode.op.put_loc, receiver_tmp);
    return receiver_tmp;
}

fn emitPutThisPrivateFieldFromReceiver(s: *ParseState, receiver_tmp: u16, private_atom: Atom) Error!void {
    try s.emitOpU16(opcode.op.get_loc, receiver_tmp);
    try s.emitOp(opcode.op.swap);
    try s.emitOpAtom(opcode.op.put_field, private_atom);
}

fn emitPutThisPrivateFieldFromTop(s: *ParseState, private_atom: Atom) Error!void {
    try s.emitOp(opcode.op.push_this);
    try s.emitOp(opcode.op.swap);
    try s.emitOpAtom(opcode.op.put_field, private_atom);
}

fn parseDestructuringPattern(s: *ParseState, kind: DestructuringKind, source: ?BindingSource) Error!void {
    s.features.insert(.destructuring);
    switch (kind) {
        .array => try parseDestructuringArrayFromSource(s, source),
        .object => try parseDestructuringObjectFromSource(s, source),
    }
}

fn consumeDuplicateDefaultInitializer(s: *ParseState) Error!void {
    const code_len = s.currentCodeLen();
    const atom_len = s.currentAtomOperandLen();
    try s.advance();
    try parseAssignExpr(s);
    try truncateSpeculativeParse(s, code_len, atom_len);
}

fn parseDestructuringParam(s: *ParseState, kind: DestructuringKind, arg_index: ?u32) Error!void {
    const source: ?BindingSource = if (arg_index) |idx| BindingSource{ .arg = idx } else null;
    const snapshot = takeParserSnapshot(s);
    try parseDestructuringPattern(s, kind, null);
    const has_default = s.peekKind() == '=';
    if (has_default) {
        try s.advance();
        try truncateSpeculativeParse(s, snapshot.code_len, snapshot.atom_len);
        if (source) |binding_source| {
            try emitDefaultForBindingSource(s, binding_source);
        } else {
            try parseAssignExpr(s);
            try s.emitOp(opcode.op.drop);
        }
    }
    if (!has_default) try truncateSpeculativeParse(s, snapshot.code_len, snapshot.atom_len);
    restoreParserLexerSnapshot(s, snapshot);

    try parseDestructuringPattern(s, kind, source);
    if (has_default and s.peekKind() == '=') {
        try consumeDuplicateDefaultInitializer(s);
    }
}

fn parseNestedDestructuringElement(
    s: *ParseState,
    kind: DestructuringKind,
    source: ?BindingSource,
    element_source: ?BindingSource,
) Error!void {
    if (source == null) {
        try parseDestructuringPattern(s, kind, null);
        if (s.peekKind() == '=') {
            try s.advance();
            try parseAssignExpr(s);
            try s.emitOp(opcode.op.drop);
        }
        return;
    }

    const nested_source = element_source orelse return Error.UnexpectedToken;
    const snapshot = takeParserSnapshot(s);
    try parseDestructuringPattern(s, kind, null);
    const has_default = s.peekKind() == '=';
    if (has_default) {
        try s.advance();
        try truncateSpeculativeParse(s, snapshot.code_len, snapshot.atom_len);
        try emitDefaultForBindingSource(s, nested_source);
    }
    if (!has_default) try truncateSpeculativeParse(s, snapshot.code_len, snapshot.atom_len);
    restoreParserLexerSnapshot(s, snapshot);

    try parseDestructuringPattern(s, kind, nested_source);
    if (has_default and s.peekKind() == '=') {
        try consumeDuplicateDefaultInitializer(s);
    }
}

fn emitRestArrayFromSource(s: *ParseState, source: BindingSource, element_index: u32) Error!void {
    try s.emitOpU8(opcode.op.special_object, opcode.special_object_subtype.dstr_rest);
    try emitPushBindingSource(s, source);
    try s.emitOpI32(opcode.op.push_i32, @intCast(element_index));
    try s.emitOpU16(opcode.op.call, 2);
}

const ObjectRestExcludedKey = union(enum) {
    atom: Atom,
    loc: u16,
};

fn appendExcludedAtomKey(s: *ParseState, excluded_keys: *std.ArrayList(ObjectRestExcludedKey), atom_id: Atom) Error!void {
    const retained = s.function.atoms.dup(atom_id);
    errdefer s.function.atoms.free(retained);
    try excluded_keys.append(s.function.memory.allocator, .{ .atom = retained });
}

const DestructuringAssignmentTargetRef = union(enum) {
    var_ref: Atom,
    dotted: struct {
        base_tmp: u16,
        prop_atom: Atom,
    },
    indexed: struct {
        base_tmp: u16,
        key_tmp: u16,
    },
    super_ref: struct {
        receiver_tmp: u16,
        base_tmp: u16,
        key_tmp: u16,
    },
};

fn emitRestObjectFromSource(s: *ParseState, source: BindingSource, excluded_keys: []const ObjectRestExcludedKey) Error!void {
    try s.emitOpU8(opcode.op.special_object, opcode.special_object_subtype.dstr_obj_rest);
    try emitPushBindingSource(s, source);
    for (excluded_keys) |excluded| switch (excluded) {
        .atom => |atom_id| try s.emitOpAtom(opcode.op.push_atom_value, atom_id),
        .loc => |idx| try s.emitOpU16(opcode.op.get_loc, idx),
    };
    try s.emitOpU16(opcode.op.call, @intCast(1 + excluded_keys.len));
}

fn arrayLiteralPatternCandidateIsMemberTarget(s: *ParseState) Error!bool {
    if (s.peekKind() != @as(tok.TokenKind, @intCast('['))) return false;
    const snapshot = takeParserSnapshot(s);
    parseArrayLiteral(s, ParseFlags.default) catch |err| switch (err) {
        error.UnexpectedToken, error.InvalidAssignmentTarget, error.YieldOutsideGenerator => {
            try truncateSpeculativeParse(s, snapshot.code_len, snapshot.atom_len);
            restoreParserLexerSnapshot(s, snapshot);
            return false;
        },
        else => return err,
    };
    const is_member = s.peekKind() == @as(tok.TokenKind, @intCast('.')) or
        s.peekKind() == @as(tok.TokenKind, @intCast('['));
    try truncateSpeculativeParse(s, snapshot.code_len, snapshot.atom_len);
    restoreParserLexerSnapshot(s, snapshot);
    return is_member;
}

fn destructuringAssignmentTargetCanStart(s: *ParseState) Error!bool {
    if (!s.destructuring_assignment_target_mode) return false;
    return switch (s.peekKind()) {
        @as(tok.TokenKind, @intCast('(')), tok.TOK_THIS, tok.TOK_SUPER => true,
        @as(tok.TokenKind, @intCast('{')) => try objectLiteralPatternCandidateIsMemberTarget(s),
        @as(tok.TokenKind, @intCast('[')) => try arrayLiteralPatternCandidateIsMemberTarget(s),
        else => false,
    };
}

fn thisPrivateAssignmentTargetFollows(s: *ParseState) Error!bool {
    if (s.peekKind() != tok.TOK_THIS) return false;
    const snapshot = takeParserSnapshot(s);
    defer restoreParserLexerSnapshot(s, snapshot);
    try s.advance();
    if (s.peekKind() != @as(tok.TokenKind, @intCast('.'))) return false;
    try s.advance();
    return s.peekKind() == tok.TOK_PRIVATE_NAME;
}

fn parseDestructuringAssignmentTargetShape(s: *ParseState) Error!LhsShape {
    const saved_atom: ?Atom = if (peekParenthesizedBareIdent(s)) |ident| blk: {
        break :blk ident;
    } else if (isIdentifierLikeToken(s)) blk: {
        break :blk identifierLikeAtom(s);
    } else null;
    const pre_lhs_code_len = s.currentCodeLen();
    const pre_lhs_atom_len = s.currentAtomOperandLen();
    const saved_force_with_lvalue = s.force_with_lvalue;
    s.force_with_lvalue = true;
    defer s.force_with_lvalue = saved_force_with_lvalue;
    try parseLhsExpr(s, ParseFlags{ .in_accepted = false });
    const shape = classifyLhs(s, pre_lhs_code_len, pre_lhs_atom_len, saved_atom);
    if (shape == .none or shape == .invalid_call or shape == .with_ref) return Error.InvalidAssignmentTarget;
    if ((s.is_strict or s.cur_func().is_strict_mode) and shape == .var_ref) {
        const atom_id = shape.var_ref.atom;
        if (atomNameEquals(s, atom_id, "eval") or atomNameEquals(s, atom_id, "arguments")) {
            return Error.InvalidAssignmentTarget;
        }
    }
    return shape;
}

fn parseDestructuringAssignmentTargetSyntax(s: *ParseState) Error!void {
    const code_len = s.currentCodeLen();
    const atom_len = s.currentAtomOperandLen();
    _ = try parseDestructuringAssignmentTargetShape(s);
    try truncateSpeculativeParse(s, code_len, atom_len);
}

fn parseDestructuringAssignmentTargetRef(s: *ParseState) Error!DestructuringAssignmentTargetRef {
    const shape = try parseDestructuringAssignmentTargetShape(s);
    switch (shape) {
        .var_ref => |v| {
            try s.truncateCode(v.code_pos);
            const atom_len = s.currentAtomOperandLen();
            if (atom_len == 0) return Error.UnexpectedToken;
            try s.truncateAtomOperands(atom_len - 1);
            return .{ .var_ref = v.atom };
        },
        .dotted => |d| {
            try s.truncateCode(d.code_pos);
            const atom_len = s.currentAtomOperandLen();
            if (atom_len == 0) return Error.UnexpectedToken;
            try s.truncateAtomOperands(atom_len - 1);
            const base_tmp = try appendTempLocal(s);
            try s.emitOpU16(opcode.op.put_loc, base_tmp);
            return .{ .dotted = .{
                .base_tmp = base_tmp,
                .prop_atom = d.atom,
            } };
        },
        .indexed => |i| {
            try s.truncateCode(i.code_pos);
            const key_tmp = try appendTempLocal(s);
            try s.emitOpU16(opcode.op.put_loc, key_tmp);
            const base_tmp = try appendTempLocal(s);
            try s.emitOpU16(opcode.op.put_loc, base_tmp);
            return .{ .indexed = .{
                .base_tmp = base_tmp,
                .key_tmp = key_tmp,
            } };
        },
        .super_dotted => |d| {
            try s.truncateCode(d.code_pos);
            const key_tmp = try appendTempLocal(s);
            try s.emitOpU16(opcode.op.put_loc, key_tmp);
            const base_tmp = try appendTempLocal(s);
            try s.emitOpU16(opcode.op.put_loc, base_tmp);
            const receiver_tmp = try appendTempLocal(s);
            try s.emitOpU16(opcode.op.put_loc, receiver_tmp);
            return .{ .super_ref = .{
                .receiver_tmp = receiver_tmp,
                .base_tmp = base_tmp,
                .key_tmp = key_tmp,
            } };
        },
        .invalid_call, .with_ref, .none => return Error.InvalidAssignmentTarget,
    }
}

fn emitPutDestructuringAssignmentTarget(s: *ParseState, target: DestructuringAssignmentTargetRef) Error!void {
    const value_tmp = try appendTempLocal(s);
    try s.emitOpU16(opcode.op.put_loc, value_tmp);
    switch (target) {
        .var_ref => |atom_id| {
            try s.emitOpU16(opcode.op.get_loc, value_tmp);
            try s.emitScopePutVar(atom_id);
        },
        .dotted => |ref| {
            try s.emitOpU16(opcode.op.get_loc, ref.base_tmp);
            try s.emitOpU16(opcode.op.get_loc, value_tmp);
            try s.emitOpAtom(opcode.op.put_field, ref.prop_atom);
        },
        .indexed => |ref| {
            try s.emitOpU16(opcode.op.get_loc, ref.base_tmp);
            try s.emitOpU16(opcode.op.get_loc, ref.key_tmp);
            try s.emitOpU16(opcode.op.get_loc, value_tmp);
            try s.emitOp(opcode.op.put_array_el);
        },
        .super_ref => |ref| {
            try s.emitOpU16(opcode.op.get_loc, ref.receiver_tmp);
            try s.emitOpU16(opcode.op.get_loc, ref.base_tmp);
            try s.emitOpU16(opcode.op.get_loc, ref.key_tmp);
            try s.emitOpU16(opcode.op.get_loc, value_tmp);
            try s.emitOp(opcode.op.put_super_value);
        },
    }
}

/// Parse object destructuring pattern
/// Mirrors object destructuring in quickjs.c
fn parseDestructuringObjectFromSource(s: *ParseState, source: ?BindingSource) Error!void {
    try s.expectToken('{');
    if (source) |binding_source| try emitRequireObjectCoercibleForBindingSource(s, binding_source);
    var excluded_keys = std.ArrayList(ObjectRestExcludedKey).empty;
    defer {
        for (excluded_keys.items) |excluded| switch (excluded) {
            .atom => |atom_id| s.function.atoms.free(atom_id),
            .loc => {},
        };
        excluded_keys.deinit(s.function.memory.allocator);
    }

    while (s.peekKind() != '}' and s.peekKind() != tok.TOK_EOF) {
        if (s.peekKind() == tok.TOK_ELLIPSIS) {
            try s.advance();
            if (s.destructuring_assignment_target_mode and try thisPrivateAssignmentTargetFollows(s)) {
                const private_atom = try parseThisPrivateAssignmentTarget(s);
                defer s.function.atoms.free(private_atom);
                if (source) |binding_source| {
                    const receiver_tmp = try emitStoreThisPrivateReceiver(s);
                    try emitRestObjectFromSource(s, binding_source, excluded_keys.items);
                    try emitPutThisPrivateFieldFromReceiver(s, receiver_tmp, private_atom);
                }
                if (s.peekKind() != '}') return Error.UnexpectedToken;
                continue;
            }
            if (try destructuringAssignmentTargetCanStart(s)) {
                if (source) |binding_source| {
                    const target_ref = try parseDestructuringAssignmentTargetRef(s);
                    try emitRestObjectFromSource(s, binding_source, excluded_keys.items);
                    try emitPutDestructuringAssignmentTarget(s, target_ref);
                } else {
                    try parseDestructuringAssignmentTargetSyntax(s);
                }
                if (s.peekKind() != '}') return Error.UnexpectedToken;
                continue;
            }
            if (s.peekKind() != tok.TOK_IDENT) return Error.UnexpectedToken;
            const rest_atom = s.token.payload.ident.atom;
            var local_index: ?u16 = null;
            try s.advance();
            if (s.destructuring_assignment_target_mode and s.peekKind() == @as(tok.TokenKind, @intCast('.'))) {
                try s.advance();
                if (s.peekKind() != tok.TOK_IDENT) return Error.UnexpectedToken;
                const target_prop = s.token.payload.ident.atom;
                if (source) |binding_source| {
                    try emitRestObjectFromSource(s, binding_source, excluded_keys.items);
                    const rest_tmp = try appendTempLocal(s);
                    try s.emitOpU16(opcode.op.put_loc, rest_tmp);
                    try s.emitScopeGetVar(rest_atom);
                    try s.emitOpU16(opcode.op.get_loc, rest_tmp);
                    try s.emitOpAtom(opcode.op.put_field, target_prop);
                }
                try s.advance();
            } else if (s.destructuring_assignment_target_mode) {
                if (source) |binding_source| {
                    try emitRestObjectFromSource(s, binding_source, excluded_keys.items);
                    try s.emitScopePutVar(rest_atom);
                }
            } else {
                if (source) |binding_source| {
                    local_index = try appendBindingLocal(s, rest_atom);
                    try emitRestObjectFromSource(s, binding_source, excluded_keys.items);
                } else if (s.destructuring_predeclare_only) {
                    _ = try appendBindingLocal(s, rest_atom);
                }
            }
            if (s.peekKind() != '}') return Error.UnexpectedToken;
            if (local_index) |idx| try emitPutBindingLocal(s, idx);
        } else if (s.peekKind() == '[') {
            try s.advance();
            if (source) |binding_source| try emitPushBindingSource(s, binding_source);
            try parseExpr(s);
            if (source != null) try s.emitOp(opcode.op.to_propkey);
            try s.expectToken(']');
            try s.expectToken(':');
            if (s.destructuring_assignment_target_mode and try thisPrivateAssignmentTargetFollows(s)) {
                const private_atom = try parseThisPrivateAssignmentTarget(s);
                defer s.function.atoms.free(private_atom);
                var receiver_tmp: ?u16 = null;
                if (source != null) receiver_tmp = try emitStoreThisPrivateReceiver(s);
                if (source != null) {
                    const excluded_tmp = try appendTempLocal(s);
                    try s.emitOp(opcode.op.dup);
                    try s.emitOpU16(opcode.op.put_loc, excluded_tmp);
                    try excluded_keys.append(s.function.memory.allocator, .{ .loc = excluded_tmp });
                    try s.emitOp(opcode.op.get_array_el);
                } else {
                    try s.emitOp(opcode.op.drop);
                }
                if (s.peekKind() == '=') {
                    try s.advance();
                    if (source != null) {
                        try s.emitOp(opcode.op.dup);
                        try s.emitOp(opcode.op.is_undefined);
                        const keep_value = try emitForwardJump(s, opcode.op.if_false);
                        try s.emitOp(opcode.op.drop);
                        try parseAssignExpr(s);
                        try patchForwardJump(s, keep_value);
                    } else {
                        try parseAssignExpr(s);
                        try s.emitOp(opcode.op.drop);
                    }
                }
                if (source != null) try emitPutThisPrivateFieldFromReceiver(s, receiver_tmp orelse return Error.UnexpectedToken, private_atom);
            } else {
                if (s.peekKind() != tok.TOK_IDENT) return Error.UnexpectedToken;
                const target_atom = s.token.payload.ident.atom;
                var local_index: ?u16 = null;
                var assignment_atom: ?Atom = null;
                try s.advance();
                if (source == null and s.destructuring_assignment_target_mode and
                    (s.peekKind() == @as(tok.TokenKind, @intCast('.')) or
                        s.peekKind() == @as(tok.TokenKind, @intCast('[')) or
                        s.peekKind() == @as(tok.TokenKind, @intCast('('))))
                {
                    if (s.peekKind() == @as(tok.TokenKind, @intCast('('))) {
                        const shape = try parseCallArgs(s, ParseFlags.default);
                        try emitPlainCallFromStack(s, shape);
                        if (s.peekKind() != @as(tok.TokenKind, @intCast('['))) return Error.UnexpectedToken;
                    }
                    if (s.peekKind() == @as(tok.TokenKind, @intCast('.'))) {
                        try s.advance();
                        if (s.peekKind() != tok.TOK_IDENT) return Error.UnexpectedToken;
                        try s.advance();
                    } else if (s.peekKind() == @as(tok.TokenKind, @intCast('['))) {
                        try s.advance();
                        try parseExpr(s);
                        try s.expectToken(']');
                    } else {
                        return Error.UnexpectedToken;
                    }
                    if (s.peekKind() == '=') {
                        try s.advance();
                        try parseAssignExpr(s);
                        try s.emitOp(opcode.op.drop);
                    }
                } else if (source != null and s.destructuring_assignment_target_mode and
                    (s.peekKind() == @as(tok.TokenKind, @intCast('.')) or
                        s.peekKind() == @as(tok.TokenKind, @intCast('[')) or
                        s.peekKind() == @as(tok.TokenKind, @intCast('('))))
                {
                    const base_tmp = try appendTempLocal(s);
                    var prop_atom: ?Atom = null;
                    var key_tmp: ?u16 = null;
                    try emitDestructuringTargetBase(s, target_atom);
                    if (s.peekKind() == @as(tok.TokenKind, @intCast('('))) {
                        const shape = try parseCallArgs(s, ParseFlags.default);
                        try emitPlainCallFromStack(s, shape);
                        if (s.peekKind() != @as(tok.TokenKind, @intCast('['))) return Error.UnexpectedToken;
                    }
                    try s.emitOpU16(opcode.op.put_loc, base_tmp);
                    if (s.peekKind() == @as(tok.TokenKind, @intCast('.'))) {
                        try s.advance();
                        if (s.peekKind() != tok.TOK_IDENT) return Error.UnexpectedToken;
                        prop_atom = s.token.payload.ident.atom;
                        try s.advance();
                    } else if (s.peekKind() == @as(tok.TokenKind, @intCast('['))) {
                        try s.advance();
                        try parseExpr(s);
                        const tmp = try appendTempLocal(s);
                        try s.emitOpU16(opcode.op.put_loc, tmp);
                        key_tmp = tmp;
                        try s.expectToken(']');
                    } else {
                        return Error.UnexpectedToken;
                    }
                    const excluded_tmp = try appendTempLocal(s);
                    try s.emitOp(opcode.op.dup);
                    try s.emitOpU16(opcode.op.put_loc, excluded_tmp);
                    try excluded_keys.append(s.function.memory.allocator, .{ .loc = excluded_tmp });
                    try s.emitOp(opcode.op.get_array_el);
                    const value_tmp = try appendTempLocal(s);
                    try s.emitOpU16(opcode.op.put_loc, value_tmp);
                    if (s.peekKind() == '=') {
                        try s.advance();
                        try s.emitOpU16(opcode.op.get_loc, value_tmp);
                        try s.emitOp(opcode.op.dup);
                        try s.emitOp(opcode.op.is_undefined);
                        const keep_value = try emitForwardJump(s, opcode.op.if_false);
                        try s.emitOp(opcode.op.drop);
                        try parseAssignExpr(s);
                        try patchForwardJump(s, keep_value);
                        try s.emitOpU16(opcode.op.put_loc, value_tmp);
                    }
                    try s.emitOpU16(opcode.op.get_loc, base_tmp);
                    if (prop_atom) |atom_id| {
                        try s.emitOpU16(opcode.op.get_loc, value_tmp);
                        try s.emitOpAtom(opcode.op.put_field, atom_id);
                    } else {
                        try s.emitOpU16(opcode.op.get_loc, key_tmp orelse return Error.UnexpectedToken);
                        try s.emitOpU16(opcode.op.get_loc, value_tmp);
                        try s.emitOp(opcode.op.put_array_el);
                    }
                } else if (source != null) {
                    const excluded_tmp = try appendTempLocal(s);
                    try s.emitOp(opcode.op.dup);
                    try s.emitOpU16(opcode.op.put_loc, excluded_tmp);
                    try excluded_keys.append(s.function.memory.allocator, .{ .loc = excluded_tmp });
                    if (s.destructuring_assignment_target_mode) {
                        assignment_atom = target_atom;
                    } else {
                        local_index = try appendBindingLocal(s, target_atom);
                        try emitDestructuringVarBindingResolution(s, target_atom);
                    }
                    try s.emitOp(opcode.op.get_array_el);
                } else if (s.destructuring_predeclare_only) {
                    _ = try appendBindingLocal(s, target_atom);
                    try s.emitOp(opcode.op.drop);
                } else {
                    try s.emitOp(opcode.op.drop);
                }
                if (s.peekKind() == '=') {
                    try s.advance();
                    if (source != null) {
                        try s.emitOp(opcode.op.dup);
                        try s.emitOp(opcode.op.is_undefined);
                        const keep_value = try emitForwardJump(s, opcode.op.if_false);
                        try s.emitOp(opcode.op.drop);
                        try parseNamedBindingDefaultInitializer(s, target_atom);
                        try patchForwardJump(s, keep_value);
                    } else {
                        try parseAssignExpr(s);
                        try s.emitOp(opcode.op.drop);
                    }
                }
                if (local_index) |idx| try emitPutBindingLocal(s, idx);
                if (assignment_atom) |atom_id| try s.emitScopePutVar(atom_id);
            }
        } else if (try parseObjectPropertyName(s)) |prop_name| {
            const prop_atom = prop_name.atom;
            defer if (prop_name.retained) s.function.atoms.free(prop_atom);
            if (source != null) try appendExcludedAtomKey(s, &excluded_keys, prop_atom);

            // Check for renaming: {a: b}
            if (s.peekKind() == ':') {
                try s.advance();
                if (s.peekKind() == tok.TOK_IDENT) {
                    const target_atom = s.token.payload.ident.atom;
                    var local_index: ?u16 = null;
                    var assignment_atom: ?Atom = null;
                    var member_base: ?Atom = null;
                    var member_prop: ?Atom = null;
                    var computed_base: ?Atom = null;
                    var computed_key_point: ?LexerReplayPoint = null;
                    var value_tmp: ?u16 = null;
                    if (source) |binding_source| {
                        if (!s.destructuring_assignment_target_mode) {
                            local_index = try appendBindingLocal(s, target_atom);
                        }
                        try emitBindingField(s, binding_source, prop_atom);
                    } else if (s.destructuring_predeclare_only) {
                        _ = try appendBindingLocal(s, target_atom);
                    }
                    try s.advance();
                    if (s.destructuring_assignment_target_mode) {
                        if (s.peekKind() == @as(tok.TokenKind, @intCast('.'))) {
                            if (source != null) {
                                const tmp = try appendTempLocal(s);
                                try s.emitOpU16(opcode.op.put_loc, tmp);
                                value_tmp = tmp;
                            }
                            try s.advance();
                            if (s.peekKind() != tok.TOK_IDENT) return Error.UnexpectedToken;
                            member_base = target_atom;
                            member_prop = s.token.payload.ident.atom;
                            try s.advance();
                        } else if (s.peekKind() == @as(tok.TokenKind, @intCast('['))) {
                            if (source != null) {
                                const tmp = try appendTempLocal(s);
                                try s.emitOpU16(opcode.op.put_loc, tmp);
                                value_tmp = tmp;
                            }
                            try s.advance();
                            computed_base = target_atom;
                            computed_key_point = takeLexerReplayPoint(s);
                            const key_code_len = s.currentCodeLen();
                            const key_atom_len = s.currentAtomOperandLen();
                            try parseExpr(s);
                            try truncateSpeculativeParse(s, key_code_len, key_atom_len);
                            try s.expectToken(']');
                        } else {
                            assignment_atom = target_atom;
                        }
                    }
                    if (s.peekKind() == '=') {
                        try s.advance();
                        if (source != null) {
                            if (value_tmp) |tmp| try s.emitOpU16(opcode.op.get_loc, tmp);
                            try s.emitOp(opcode.op.dup);
                            try s.emitOp(opcode.op.is_undefined);
                            const keep_value = try emitForwardJump(s, opcode.op.if_false);
                            try s.emitOp(opcode.op.drop);
                            if (assignment_atom != null or local_index != null) {
                                try parseNamedBindingDefaultInitializer(s, target_atom);
                            } else {
                                try parseAssignExpr(s);
                            }
                            try patchForwardJump(s, keep_value);
                        } else {
                            try parseAssignExpr(s);
                            try s.emitOp(opcode.op.drop);
                        }
                    }
                    if (local_index) |idx| try emitPutBindingLocal(s, idx);
                    if (assignment_atom) |atom_id| try s.emitScopePutVar(atom_id);
                    if (source != null and member_base != null) {
                        const base_atom = member_base.?;
                        try s.emitScopeGetVar(base_atom);
                        try s.emitOpU16(opcode.op.get_loc, value_tmp orelse return Error.UnexpectedToken);
                        try s.emitOpAtom(opcode.op.put_field, member_prop orelse return Error.UnexpectedToken);
                    } else if (source != null and computed_base != null) {
                        const base_atom = computed_base.?;
                        try s.emitScopeGetVar(base_atom);
                        const after_key = takeParserSnapshot(s);
                        try restoreLexerReplayPoint(s, computed_key_point orelse return Error.UnexpectedToken);
                        try parseExpr(s);
                        restoreParserLexerSnapshot(s, after_key);
                        try s.emitOpU16(opcode.op.get_loc, value_tmp orelse return Error.UnexpectedToken);
                        try s.emitOp(opcode.op.put_array_el);
                    }
                } else if (s.destructuring_assignment_target_mode and try thisPrivateAssignmentTargetFollows(s)) {
                    const private_atom = try parseThisPrivateAssignmentTarget(s);
                    defer s.function.atoms.free(private_atom);
                    var receiver_tmp: ?u16 = null;
                    if (source != null) receiver_tmp = try emitStoreThisPrivateReceiver(s);
                    if (source) |binding_source| {
                        try emitBindingField(s, binding_source, prop_atom);
                    }
                    if (s.peekKind() == '=') {
                        try s.advance();
                        if (source != null) {
                            try s.emitOp(opcode.op.dup);
                            try s.emitOp(opcode.op.is_undefined);
                            const keep_value = try emitForwardJump(s, opcode.op.if_false);
                            try s.emitOp(opcode.op.drop);
                            try parseAssignExpr(s);
                            try patchForwardJump(s, keep_value);
                        } else {
                            try parseAssignExpr(s);
                            try s.emitOp(opcode.op.drop);
                        }
                    }
                    if (source != null) {
                        try emitPutThisPrivateFieldFromReceiver(s, receiver_tmp orelse return Error.UnexpectedToken, private_atom);
                    }
                } else if (try destructuringAssignmentTargetCanStart(s)) {
                    if (source) |binding_source| {
                        const target_ref = try parseDestructuringAssignmentTargetRef(s);
                        try emitBindingField(s, binding_source, prop_atom);
                        if (s.peekKind() == '=') {
                            try s.advance();
                            try s.emitOp(opcode.op.dup);
                            try s.emitOp(opcode.op.is_undefined);
                            const keep_value = try emitForwardJump(s, opcode.op.if_false);
                            try s.emitOp(opcode.op.drop);
                            try parseAssignExpr(s);
                            try patchForwardJump(s, keep_value);
                        }
                        try emitPutDestructuringAssignmentTarget(s, target_ref);
                    } else {
                        try parseDestructuringAssignmentTargetSyntax(s);
                        if (s.peekKind() == '=') {
                            try s.advance();
                            try parseAssignExpr(s);
                            try s.emitOp(opcode.op.drop);
                        }
                    }
                } else if (s.peekKind() == @as(tok.TokenKind, @intCast('{')) and s.destructuring_assignment_target_mode) {
                    const object_point = takeLexerReplayPoint(s);
                    if (try objectLiteralPatternCandidateIsMemberTarget(s)) {
                        var value_tmp: ?u16 = null;
                        if (source) |binding_source| {
                            try emitBindingField(s, binding_source, prop_atom);
                            const tmp = try appendTempLocal(s);
                            try s.emitOpU16(opcode.op.put_loc, tmp);
                            value_tmp = tmp;
                        }
                        const object_code_len = s.currentCodeLen();
                        const object_atom_len = s.currentAtomOperandLen();
                        try parseObjectLiteral(s, ParseFlags.default);
                        try truncateSpeculativeParse(s, object_code_len, object_atom_len);
                        try s.advance();
                        if (s.peekKind() != tok.TOK_IDENT) return Error.UnexpectedToken;
                        const target_prop = s.token.payload.ident.atom;
                        try s.advance();
                        if (s.peekKind() == '=') {
                            try s.advance();
                            if (source != null) {
                                try s.emitOpU16(opcode.op.get_loc, value_tmp orelse return Error.UnexpectedToken);
                                try s.emitOp(opcode.op.dup);
                                try s.emitOp(opcode.op.is_undefined);
                                const keep_value = try emitForwardJump(s, opcode.op.if_false);
                                try s.emitOp(opcode.op.drop);
                                try parseAssignExpr(s);
                                try patchForwardJump(s, keep_value);
                                const value_with_default_tmp = try appendTempLocal(s);
                                try s.emitOpU16(opcode.op.put_loc, value_with_default_tmp);
                                value_tmp = value_with_default_tmp;
                            } else {
                                try parseAssignExpr(s);
                                try s.emitOp(opcode.op.drop);
                            }
                        }
                        if (source != null) {
                            const after_object = takeParserSnapshot(s);
                            try restoreLexerReplayPoint(s, object_point);
                            try parseObjectLiteral(s, ParseFlags.default);
                            restoreParserLexerSnapshot(s, after_object);
                            try s.emitOpU16(opcode.op.get_loc, value_tmp orelse return Error.UnexpectedToken);
                            try s.emitOpAtom(opcode.op.put_field, target_prop);
                        }
                    } else {
                        try restoreLexerReplayPoint(s, object_point);
                        const nested_kind: DestructuringKind = .object;
                        var nested_source: ?BindingSource = null;
                        if (source) |binding_source| {
                            const temp_idx = try appendTempLocal(s);
                            try emitBindingField(s, binding_source, prop_atom);
                            try s.emitOpU16(opcode.op.put_loc, temp_idx);
                            nested_source = BindingSource{ .loc = temp_idx };
                        }
                        try parseNestedDestructuringElement(s, nested_kind, source, nested_source);
                    }
                } else if (s.peekKind() == '[' or s.peekKind() == '{') {
                    const nested_kind: DestructuringKind = if (s.peekKind() == '[') .array else .object;
                    var nested_source: ?BindingSource = null;
                    if (source) |binding_source| {
                        const temp_idx = try appendTempLocal(s);
                        try emitBindingField(s, binding_source, prop_atom);
                        try s.emitOpU16(opcode.op.put_loc, temp_idx);
                        nested_source = BindingSource{ .loc = temp_idx };
                    }
                    try parseNestedDestructuringElement(s, nested_kind, source, nested_source);
                } else {
                    return Error.UnexpectedToken;
                }
            } else {
                if (!prop_name.allow_shorthand) return Error.UnexpectedToken;
                if (s.destructuring_assignment_target_mode and (s.is_strict or s.cur_func().is_strict_mode) and
                    (atomNameEquals(s, prop_atom, "eval") or atomNameEquals(s, prop_atom, "arguments")))
                {
                    return Error.UnexpectedToken;
                }
                var local_index: ?u16 = null;
                var assignment_atom: ?Atom = null;
                if (source) |binding_source| {
                    if (s.destructuring_assignment_target_mode) {
                        assignment_atom = prop_atom;
                    } else {
                        local_index = try appendBindingLocal(s, prop_atom);
                    }
                    try emitBindingField(s, binding_source, prop_atom);
                } else if (s.destructuring_predeclare_only) {
                    _ = try appendBindingLocal(s, prop_atom);
                }
                if (s.peekKind() == '=') {
                    try s.advance();
                    if (source != null) {
                        try s.emitOp(opcode.op.dup);
                        try s.emitOp(opcode.op.is_undefined);
                        const keep_value = try emitForwardJump(s, opcode.op.if_false);
                        try s.emitOp(opcode.op.drop);
                        try parseNamedBindingDefaultInitializer(s, prop_atom);
                        try patchForwardJump(s, keep_value);
                    } else {
                        try parseAssignExpr(s);
                        try s.emitOp(opcode.op.drop);
                    }
                }
                if (local_index) |idx| try emitPutBindingLocal(s, idx);
                if (assignment_atom) |atom_id| try s.emitScopePutVar(atom_id);
            }
        } else {
            return Error.UnexpectedToken;
        }

        if (s.peekKind() == ',') {
            try s.advance();
        } else if (s.peekKind() != '}') {
            return Error.UnexpectedToken;
        }
    }

    try s.expectToken('}');
}

/// Parse array destructuring pattern
/// Mirrors array destructuring in quickjs.c
fn parseDestructuringArrayFromSource(s: *ParseState, source: ?BindingSource) Error!void {
    try s.expectToken('[');
    if (source) |binding_source| try emitRequireIteratorForBindingSource(s, binding_source);

    var element_index: u32 = 0;
    while (s.peekKind() != ']' and s.peekKind() != tok.TOK_EOF) {
        var consumed_elision_comma = false;
        if (isIdentifierLikeToken(s) or s.peekKind() == tok.TOK_AWAIT) {
            if (s.peekKind() == tok.TOK_AWAIT and !canUseAwaitAsIdentifier(s)) return Error.UnexpectedToken;
            const elem_atom = if (s.peekKind() == tok.TOK_IDENT) s.token.payload.ident.atom else tok.keywordAtom(s.peekKind());
            const can_parse_assignment_target = s.destructuring_assignment_target_mode;
            if (can_parse_assignment_target) {
                try s.advance();
                if (s.peekKind() == @as(tok.TokenKind, @intCast('['))) {
                    if (source) |binding_source| {
                        const base_tmp = try appendTempLocal(s);
                        try emitDestructuringTargetBase(s, elem_atom);
                        try s.emitOpU16(opcode.op.put_loc, base_tmp);
                        try s.advance();
                        try parseExpr(s);
                        const key_tmp = try appendTempLocal(s);
                        try s.emitOpU16(opcode.op.put_loc, key_tmp);
                        try s.expectToken(']');
                        try emitBindingIndex(s, binding_source, element_index);
                        const value_tmp = try appendTempLocal(s);
                        try s.emitOpU16(opcode.op.put_loc, value_tmp);
                        try s.emitOpU16(opcode.op.get_loc, base_tmp);
                        try s.emitOpU16(opcode.op.get_loc, key_tmp);
                        try s.emitOpU16(opcode.op.get_loc, value_tmp);
                        try s.emitOp(opcode.op.put_array_el);
                    } else {
                        try s.advance();
                        try parseExpr(s);
                        try s.expectToken(']');
                    }
                } else if (s.peekKind() == @as(tok.TokenKind, @intCast('('))) {
                    if (source) |binding_source| {
                        const base_tmp = try appendTempLocal(s);
                        try emitDestructuringTargetBase(s, elem_atom);
                        const shape = try parseCallArgs(s, ParseFlags.default);
                        try emitPlainCallFromStack(s, shape);
                        if (s.peekKind() != @as(tok.TokenKind, @intCast('['))) return Error.UnexpectedToken;
                        try s.emitOpU16(opcode.op.put_loc, base_tmp);
                        try s.advance();
                        try parseExpr(s);
                        const key_tmp = try appendTempLocal(s);
                        try s.emitOpU16(opcode.op.put_loc, key_tmp);
                        try s.expectToken(']');
                        try emitBindingIndex(s, binding_source, element_index);
                        const value_tmp = try appendTempLocal(s);
                        try s.emitOpU16(opcode.op.put_loc, value_tmp);
                        try s.emitOpU16(opcode.op.get_loc, base_tmp);
                        try s.emitOpU16(opcode.op.get_loc, key_tmp);
                        try s.emitOpU16(opcode.op.get_loc, value_tmp);
                        try s.emitOp(opcode.op.put_array_el);
                    } else {
                        const shape = try parseCallArgs(s, ParseFlags.default);
                        try emitPlainCallFromStack(s, shape);
                        if (s.peekKind() != @as(tok.TokenKind, @intCast('['))) return Error.UnexpectedToken;
                        try s.advance();
                        try parseExpr(s);
                        try s.expectToken(']');
                    }
                } else if (s.peekKind() == @as(tok.TokenKind, @intCast('.'))) {
                    const value_tmp: ?u16 = null;
                    if (source) |binding_source| {
                        const base_tmp = try appendTempLocal(s);
                        try emitDestructuringTargetBase(s, elem_atom);
                        try s.emitOpU16(opcode.op.put_loc, base_tmp);
                        try s.advance();
                        if (s.peekKind() != tok.TOK_IDENT) return Error.UnexpectedToken;
                        const prop_atom = s.token.payload.ident.atom;
                        try s.advance();
                        try emitBindingIndex(s, binding_source, element_index);
                        const stored_value_tmp = try appendTempLocal(s);
                        try s.emitOpU16(opcode.op.put_loc, stored_value_tmp);
                        if (s.peekKind() == '=') {
                            try s.advance();
                            try s.emitOpU16(opcode.op.get_loc, stored_value_tmp);
                            try s.emitOp(opcode.op.dup);
                            try s.emitOp(opcode.op.is_undefined);
                            const keep_value = try emitForwardJump(s, opcode.op.if_false);
                            try s.emitOp(opcode.op.drop);
                            try parseAssignExpr(s);
                            try patchForwardJump(s, keep_value);
                            try s.emitOpU16(opcode.op.put_loc, stored_value_tmp);
                        }
                        try s.emitOpU16(opcode.op.get_loc, base_tmp);
                        try s.emitOpU16(opcode.op.get_loc, stored_value_tmp);
                        try s.emitOpAtom(opcode.op.put_field, prop_atom);
                        element_index += 1;
                        if (s.peekKind() == ',') {
                            try s.advance();
                            continue;
                        } else if (s.peekKind() != ']') {
                            return Error.UnexpectedToken;
                        }
                        continue;
                    }
                    try s.advance();
                    if (s.peekKind() != tok.TOK_IDENT) return Error.UnexpectedToken;
                    const prop_atom = s.token.payload.ident.atom;
                    try s.advance();
                    if (s.peekKind() == '=') {
                        try s.advance();
                        if (source != null) {
                            try s.emitOpU16(opcode.op.get_loc, value_tmp orelse return Error.UnexpectedToken);
                            try s.emitOp(opcode.op.dup);
                            try s.emitOp(opcode.op.is_undefined);
                            const keep_value = try emitForwardJump(s, opcode.op.if_false);
                            try s.emitOp(opcode.op.drop);
                            try parseAssignExpr(s);
                            try patchForwardJump(s, keep_value);
                            try s.emitOpU16(opcode.op.put_loc, value_tmp orelse return Error.UnexpectedToken);
                        } else {
                            try parseAssignExpr(s);
                            try s.emitOp(opcode.op.drop);
                        }
                    }
                    if (source != null) {
                        try s.emitScopeGetVar(elem_atom);
                        try s.emitOpU16(opcode.op.get_loc, value_tmp orelse return Error.UnexpectedToken);
                        try s.emitOpAtom(opcode.op.put_field, prop_atom);
                    }
                } else {
                    if (s.destructuring_assignment_target_mode and (s.is_strict or s.cur_func().is_strict_mode) and
                        (atomNameEquals(s, elem_atom, "eval") or atomNameEquals(s, elem_atom, "arguments")))
                    {
                        return Error.UnexpectedToken;
                    }
                    var local_index: ?u16 = null;
                    var assignment_atom: ?Atom = null;
                    if (source) |binding_source| {
                        if (s.destructuring_assignment_target_mode) {
                            assignment_atom = elem_atom;
                        } else {
                            local_index = try appendBindingLocal(s, elem_atom);
                        }
                        try emitBindingIndex(s, binding_source, element_index);
                    }
                    if (s.peekKind() == '=') {
                        try s.advance();
                        if (source != null) {
                            try s.emitOp(opcode.op.dup);
                            try s.emitOp(opcode.op.is_undefined);
                            const keep_value = try emitForwardJump(s, opcode.op.if_false);
                            try s.emitOp(opcode.op.drop);
                            try parseNamedBindingDefaultInitializer(s, elem_atom);
                            try patchForwardJump(s, keep_value);
                        } else {
                            try parseAssignExpr(s);
                            try s.emitOp(opcode.op.drop);
                        }
                    }
                    if (local_index) |idx| {
                        try emitPutBindingLocal(s, idx);
                    }
                    if (assignment_atom) |atom_id| try s.emitScopePutVar(atom_id);
                }
            } else {
                var local_index: ?u16 = null;
                if (source) |binding_source| {
                    local_index = try appendBindingLocal(s, elem_atom);
                    try emitBindingIndex(s, binding_source, element_index);
                } else if (s.destructuring_predeclare_only) {
                    _ = try appendBindingLocal(s, elem_atom);
                }
                try s.advance();

                // Check for default value
                if (s.peekKind() == '=') {
                    try s.advance();
                    if (source != null) {
                        try s.emitOp(opcode.op.dup);
                        try s.emitOp(opcode.op.is_undefined);
                        const keep_value = try emitForwardJump(s, opcode.op.if_false);
                        try s.emitOp(opcode.op.drop);
                        try parseNamedBindingDefaultInitializer(s, elem_atom);
                        try patchForwardJump(s, keep_value);
                    } else {
                        try parseAssignExpr(s);
                        try s.emitOp(opcode.op.drop);
                    }
                }
                if (local_index) |idx| {
                    try emitPutBindingLocal(s, idx);
                }
            }
        } else if (s.peekKind() == @as(tok.TokenKind, @intCast('{')) and
            s.destructuring_assignment_target_mode and
            try objectLiteralPatternCandidateIsMemberTarget(s))
        {
            const object_point = takeLexerReplayPoint(s);
            var object_tmp: ?u16 = null;
            var key_tmp: ?u16 = null;
            var value_tmp: ?u16 = null;
            const object_code_len = s.currentCodeLen();
            const object_atom_len = s.currentAtomOperandLen();
            try parseObjectLiteral(s, ParseFlags.default);
            try truncateSpeculativeParse(s, object_code_len, object_atom_len);
            const after_object = takeParserSnapshot(s);
            try restoreLexerReplayPoint(s, object_point);
            try parseObjectLiteral(s, ParseFlags.default);
            restoreParserLexerSnapshot(s, after_object);
            if (source != null) {
                const tmp = try appendTempLocal(s);
                try s.emitOpU16(opcode.op.put_loc, tmp);
                object_tmp = tmp;
            }
            var target_prop: ?Atom = null;
            if (s.peekKind() == @as(tok.TokenKind, @intCast('.'))) {
                try s.advance();
                if (s.peekKind() != tok.TOK_IDENT) return Error.UnexpectedToken;
                target_prop = s.token.payload.ident.atom;
                try s.advance();
            } else if (s.peekKind() == @as(tok.TokenKind, @intCast('['))) {
                try s.advance();
                try parseExpr(s);
                try s.expectToken(']');
                if (source != null) {
                    const tmp = try appendTempLocal(s);
                    try s.emitOpU16(opcode.op.put_loc, tmp);
                    key_tmp = tmp;
                }
            } else {
                return Error.UnexpectedToken;
            }
            if (source) |binding_source| {
                try emitBindingIndex(s, binding_source, element_index);
                const tmp = try appendTempLocal(s);
                try s.emitOpU16(opcode.op.put_loc, tmp);
                value_tmp = tmp;
            }
            if (s.peekKind() == '=') {
                try s.advance();
                if (source != null) {
                    try s.emitOpU16(opcode.op.get_loc, value_tmp orelse return Error.UnexpectedToken);
                    try s.emitOp(opcode.op.dup);
                    try s.emitOp(opcode.op.is_undefined);
                    const keep_value = try emitForwardJump(s, opcode.op.if_false);
                    try s.emitOp(opcode.op.drop);
                    try parseAssignExpr(s);
                    try patchForwardJump(s, keep_value);
                    try s.emitOpU16(opcode.op.put_loc, value_tmp orelse return Error.UnexpectedToken);
                } else {
                    try parseAssignExpr(s);
                    try s.emitOp(opcode.op.drop);
                }
            }
            if (source != null) {
                try s.emitOpU16(opcode.op.get_loc, object_tmp orelse return Error.UnexpectedToken);
                if (target_prop) |prop_atom| {
                    try s.emitOpU16(opcode.op.get_loc, value_tmp orelse return Error.UnexpectedToken);
                    try s.emitOpAtom(opcode.op.put_field, prop_atom);
                } else {
                    try s.emitOpU16(opcode.op.get_loc, key_tmp orelse return Error.UnexpectedToken);
                    try s.emitOpU16(opcode.op.get_loc, value_tmp orelse return Error.UnexpectedToken);
                    try s.emitOp(opcode.op.put_array_el);
                }
            }
        } else if (s.destructuring_assignment_target_mode and try thisPrivateAssignmentTargetFollows(s)) {
            const private_atom = try parseThisPrivateAssignmentTarget(s);
            defer s.function.atoms.free(private_atom);
            var receiver_tmp: ?u16 = null;
            if (source != null) receiver_tmp = try emitStoreThisPrivateReceiver(s);
            if (source) |binding_source| {
                try emitBindingIndex(s, binding_source, element_index);
            }
            if (s.peekKind() == '=') {
                try s.advance();
                if (source != null) {
                    try s.emitOp(opcode.op.dup);
                    try s.emitOp(opcode.op.is_undefined);
                    const keep_value = try emitForwardJump(s, opcode.op.if_false);
                    try s.emitOp(opcode.op.drop);
                    try parseAssignExpr(s);
                    try patchForwardJump(s, keep_value);
                } else {
                    try parseAssignExpr(s);
                    try s.emitOp(opcode.op.drop);
                }
            }
            if (source != null) {
                try emitPutThisPrivateFieldFromReceiver(s, receiver_tmp orelse return Error.UnexpectedToken, private_atom);
            }
        } else if (try destructuringAssignmentTargetCanStart(s)) {
            if (source) |binding_source| {
                const target_ref = try parseDestructuringAssignmentTargetRef(s);
                try emitBindingIndex(s, binding_source, element_index);
                if (s.peekKind() == '=') {
                    try s.advance();
                    try s.emitOp(opcode.op.dup);
                    try s.emitOp(opcode.op.is_undefined);
                    const keep_value = try emitForwardJump(s, opcode.op.if_false);
                    try s.emitOp(opcode.op.drop);
                    try parseAssignExpr(s);
                    try patchForwardJump(s, keep_value);
                }
                try emitPutDestructuringAssignmentTarget(s, target_ref);
            } else {
                try parseDestructuringAssignmentTargetSyntax(s);
                if (s.peekKind() == '=') {
                    try s.advance();
                    try parseAssignExpr(s);
                    try s.emitOp(opcode.op.drop);
                }
            }
        } else if (s.peekKind() == '[' or s.peekKind() == '{') {
            const nested_kind: DestructuringKind = if (s.peekKind() == '[') .array else .object;
            var nested_source: ?BindingSource = null;
            if (source) |binding_source| {
                const temp_idx = try appendTempLocal(s);
                try emitBindingIndex(s, binding_source, element_index);
                try s.emitOpU16(opcode.op.put_loc, temp_idx);
                nested_source = BindingSource{ .loc = temp_idx };
            }
            try parseNestedDestructuringElement(s, nested_kind, source, nested_source);
        } else if (s.peekKind() == tok.TOK_ELLIPSIS) {
            // Rest element: [...rest]
            try s.advance();
            if (s.destructuring_assignment_target_mode and try thisPrivateAssignmentTargetFollows(s)) {
                const private_atom = try parseThisPrivateAssignmentTarget(s);
                defer s.function.atoms.free(private_atom);
                if (source) |binding_source| {
                    const receiver_tmp = try emitStoreThisPrivateReceiver(s);
                    try emitRestArrayFromSource(s, binding_source, element_index);
                    try emitPutThisPrivateFieldFromReceiver(s, receiver_tmp, private_atom);
                }
            } else if (try destructuringAssignmentTargetCanStart(s)) {
                if (source) |binding_source| {
                    const target_ref = try parseDestructuringAssignmentTargetRef(s);
                    try emitRestArrayFromSource(s, binding_source, element_index);
                    try emitPutDestructuringAssignmentTarget(s, target_ref);
                } else {
                    try parseDestructuringAssignmentTargetSyntax(s);
                }
            } else if (isIdentifierLikeToken(s) or s.peekKind() == tok.TOK_AWAIT) {
                if (s.peekKind() == tok.TOK_AWAIT and !canUseAwaitAsIdentifier(s)) return Error.UnexpectedToken;
                const rest_atom = if (s.peekKind() == tok.TOK_IDENT) s.token.payload.ident.atom else tok.keywordAtom(s.peekKind());
                if (s.destructuring_assignment_target_mode and (s.is_strict or s.cur_func().is_strict_mode) and
                    (atomNameEquals(s, rest_atom, "eval") or atomNameEquals(s, rest_atom, "arguments")))
                {
                    return Error.UnexpectedToken;
                }
                try s.advance();
                if (s.destructuring_assignment_target_mode and s.peekKind() == @as(tok.TokenKind, @intCast('.'))) {
                    try s.advance();
                    if (s.peekKind() != tok.TOK_IDENT) return Error.UnexpectedToken;
                    const prop_atom = s.token.payload.ident.atom;
                    if (source) |binding_source| {
                        try emitRestArrayFromSource(s, binding_source, element_index);
                        const rest_tmp = try appendTempLocal(s);
                        try s.emitOpU16(opcode.op.put_loc, rest_tmp);
                        try s.emitScopeGetVar(rest_atom);
                        try s.emitOpU16(opcode.op.get_loc, rest_tmp);
                        try s.emitOpAtom(opcode.op.put_field, prop_atom);
                    }
                    try s.advance();
                } else if (s.destructuring_assignment_target_mode and s.peekKind() == @as(tok.TokenKind, @intCast('['))) {
                    try s.advance();
                    var rest_tmp: ?u16 = null;
                    if (source) |binding_source| {
                        try emitRestArrayFromSource(s, binding_source, element_index);
                        const tmp = try appendTempLocal(s);
                        try s.emitOpU16(opcode.op.put_loc, tmp);
                        rest_tmp = tmp;
                        try s.emitScopeGetVar(rest_atom);
                    }
                    try parseExpr(s);
                    try s.expectToken(']');
                    if (source != null) {
                        try s.emitOpU16(opcode.op.get_loc, rest_tmp orelse return Error.UnexpectedToken);
                        try s.emitOp(opcode.op.put_array_el);
                    }
                } else {
                    if (source) |binding_source| {
                        try emitRestArrayFromSource(s, binding_source, element_index);
                        if (s.destructuring_assignment_target_mode) {
                            try s.emitScopePutVar(rest_atom);
                        } else {
                            const local_index = try appendBindingLocal(s, rest_atom);
                            try emitPutBindingLocal(s, local_index);
                        }
                    } else if (s.destructuring_predeclare_only) {
                        _ = try appendBindingLocal(s, rest_atom);
                    }
                }
            } else if (s.peekKind() == '[' or s.peekKind() == '{') {
                if (s.peekKind() == @as(tok.TokenKind, @intCast('{')) and s.destructuring_assignment_target_mode) {
                    const object_point = takeLexerReplayPoint(s);
                    const object_code_len = s.currentCodeLen();
                    const object_atom_len = s.currentAtomOperandLen();
                    const parsed_object_literal = blk: {
                        parseObjectLiteral(s, ParseFlags.default) catch |err| switch (err) {
                            error.UnexpectedToken, error.InvalidAssignmentTarget, error.YieldOutsideGenerator => {
                                try truncateSpeculativeParse(s, object_code_len, object_atom_len);
                                try restoreLexerReplayPoint(s, object_point);
                                break :blk false;
                            },
                            else => return err,
                        };
                        try truncateSpeculativeParse(s, object_code_len, object_atom_len);
                        break :blk true;
                    };
                    if (parsed_object_literal and s.peekKind() == @as(tok.TokenKind, @intCast('['))) {
                        var object_tmp: ?u16 = null;
                        var key_tmp: ?u16 = null;
                        var rest_tmp: ?u16 = null;
                        const after_object = takeParserSnapshot(s);
                        try restoreLexerReplayPoint(s, object_point);
                        try parseObjectLiteral(s, ParseFlags.default);
                        restoreParserLexerSnapshot(s, after_object);
                        if (source != null) {
                            const tmp = try appendTempLocal(s);
                            try s.emitOpU16(opcode.op.put_loc, tmp);
                            object_tmp = tmp;
                        }
                        try s.advance();
                        try parseExpr(s);
                        try s.expectToken(']');
                        if (source != null) {
                            const key_local = try appendTempLocal(s);
                            try s.emitOpU16(opcode.op.put_loc, key_local);
                            key_tmp = key_local;
                        }
                        if (source) |binding_source| {
                            try emitRestArrayFromSource(s, binding_source, element_index);
                            const tmp = try appendTempLocal(s);
                            try s.emitOpU16(opcode.op.put_loc, tmp);
                            rest_tmp = tmp;
                        }
                        if (source != null) {
                            try s.emitOpU16(opcode.op.get_loc, object_tmp orelse return Error.UnexpectedToken);
                            try s.emitOpU16(opcode.op.get_loc, key_tmp orelse return Error.UnexpectedToken);
                            try s.emitOpU16(opcode.op.get_loc, rest_tmp orelse return Error.UnexpectedToken);
                            try s.emitOp(opcode.op.put_array_el);
                        }
                    } else {
                        const nested_kind: DestructuringKind = .object;
                        var nested_source: ?BindingSource = null;
                        if (source) |binding_source| {
                            const temp_idx = try appendTempLocal(s);
                            try emitRestArrayFromSource(s, binding_source, element_index);
                            try s.emitOpU16(opcode.op.put_loc, temp_idx);
                            nested_source = BindingSource{ .loc = temp_idx };
                        }
                        try restoreLexerReplayPoint(s, object_point);
                        try parseDestructuringPattern(s, nested_kind, nested_source);
                        if (s.peekKind() == '=') return Error.UnexpectedToken;
                    }
                } else {
                    const nested_kind: DestructuringKind = if (s.peekKind() == '[') .array else .object;
                    var nested_source: ?BindingSource = null;
                    if (source) |binding_source| {
                        const temp_idx = try appendTempLocal(s);
                        try emitRestArrayFromSource(s, binding_source, element_index);
                        try s.emitOpU16(opcode.op.put_loc, temp_idx);
                        nested_source = BindingSource{ .loc = temp_idx };
                    }
                    try parseDestructuringPattern(s, nested_kind, nested_source);
                    if (s.peekKind() == '=') return Error.UnexpectedToken;
                }
            } else {
                return Error.UnexpectedToken;
            }
            break; // Rest element must be last
        } else {
            // Skip empty slots in array destructuring
            if (s.peekKind() != @as(tok.TokenKind, @intCast(','))) return Error.UnexpectedToken;
            if (source) |binding_source| {
                try emitBindingElision(s, binding_source, element_index);
            }
            try s.advance();
            consumed_elision_comma = true;
        }

        element_index += 1;
        if (consumed_elision_comma) {
            continue;
        } else if (s.peekKind() == ',') {
            try s.advance();
        } else if (s.peekKind() != ']') {
            return Error.UnexpectedToken;
        }
    }

    try s.expectToken(']');
    if (source) |binding_source| try emitCloseBindingSource(s, binding_source);
}

// ---- Class parsing ----------------------------------------------------

/// Parse class heritage (extends clause)
/// Mirrors `js_parse_class_extends` in quickjs.c
fn parseClassHeritage(s: *ParseState) Error!void {
    if (s.peekKind() == tok.TOK_EXTENDS) {
        try s.advance();
        // ClassHeritage is `extends LeftHandSideExpression`, not a full
        // assignment expression; arrow expressions are rejected here.
        if (checkArrowHead(s) or
            checkIdentArrowHead(s) or
            checkAsyncSingleParamArrowHead(s) or
            checkAsyncParenArrowHead(s))
        {
            return Error.UnexpectedToken;
        }
        try parseLhsExpr(s, ParseFlags.default);
    }
}

/// Parse a single class element
/// Mirrors class element parsing in quickjs.c
fn parseClassElement(s: *ParseState) Error!void {
    const saved_static = s.is_static;
    const saved_in_constructor = s.in_constructor;
    defer {
        s.is_static = saved_static;
        s.in_constructor = saved_in_constructor;
    }

    // QuickJS treats `static` as a modifier only when it cannot be the
    // element name itself (`static;`, `static = ...`, `static()`).
    if (s.peekKind() == tok.TOK_STATIC) {
        const next = s.peekNextKind();
        if (next != @as(tok.TokenKind, @intCast(';')) and
            next != @as(tok.TokenKind, @intCast('}')) and
            next != @as(tok.TokenKind, @intCast('(')) and
            next != @as(tok.TokenKind, @intCast('=')))
        {
            s.is_static = true;
            try s.advance();
        }
    }

    const element_source_start = s.currentTokenStartOffset();
    var method_kind_override: ?ParseFunctionKind = null;
    if (s.peekKind() == tok.TOK_IDENT and s.isIdent("async") and
        s.peekNextKind() != @as(tok.TokenKind, @intCast(':')) and
        s.peekNextKind() != @as(tok.TokenKind, @intCast('(')) and
        s.peekNextKind() != @as(tok.TokenKind, @intCast('=')) and
        s.peekNextKind() != @as(tok.TokenKind, @intCast(';')) and
        s.peekNextKind() != @as(tok.TokenKind, @intCast('}')))
    {
        try s.advance();
        if (s.gotLineTerminator()) return Error.UnexpectedToken;
        if (s.peekKind() == @as(tok.TokenKind, @intCast('*'))) {
            try s.advance();
            method_kind_override = .async_generator;
        } else {
            method_kind_override = .async;
        }
    } else if (s.peekKind() == @as(tok.TokenKind, @intCast('*'))) {
        try s.advance();
        method_kind_override = .generator;
    }

    // Check for getter/setter. A line terminator after `get` / `set`,
    // or a following token that makes the word the element name itself,
    // leaves it to the ordinary property-name path below.
    const accessor_kind = classAccessorKind(s);
    if (accessor_kind) |is_getter| {
        try s.advance();
        // Check if this is a private getter/setter (get #x() or set #x())
        if (s.peekKind() == tok.TOK_PRIVATE_NAME) {
            const private_atom = try privateNameAtom(s, s.token.payload.ident.atom);
            defer s.function.atoms.free(private_atom);
            if (atomNameEquals(s, private_atom, "#constructor")) return Error.UnexpectedToken;
            try registerClassPrivateElement(s, private_atom, if (is_getter) .getter else .setter);
            try s.advance();
            if (s.peekKind() != '(') {
                return Error.UnexpectedToken;
            }
            // Parse parameters with proper function kind for private getter/setter
            const kind: ParseFunctionKind = if (is_getter) .get else .set;
            try parseClassElementFunction(s, kind, element_source_start);
            if (s.is_static) try s.emitOp(opcode.op.perm3);
            try s.emitOpAtomU8(opcode.op.define_method, private_atom, if (is_getter) 1 else 2);
            if (s.is_static) try s.emitOp(opcode.op.swap);
        } else if (s.peekKind() == '[') {
            try emitClassComputedMethod(s, if (is_getter) .get else .set, if (is_getter) 1 else 2, element_source_start);
        } else {
            // Regular getter/setter - parse property name (identifier, string, or number)
            const prop_name = (try parseObjectPropertyName(s)) orelse return Error.UnexpectedToken;
            const prop_atom = prop_name.atom;
            defer if (prop_name.retained) s.function.atoms.free(prop_atom);
            if (!s.is_static and prop_atom == atom_module.ids.constructor) return Error.UnexpectedToken;
            if (s.is_static and prop_atom == atom_module.ids.prototype) return Error.UnexpectedToken;
            if (s.peekKind() != '(') {
                return Error.UnexpectedToken;
            }
            // Parse parameters with proper function kind for getter/setter
            const kind: ParseFunctionKind = if (is_getter) .get else .set;
            try parseClassElementFunction(s, kind, element_source_start);
            if (s.is_static) try s.emitOp(opcode.op.perm3);
            try s.emitOpAtomU8(opcode.op.define_method, prop_atom, if (is_getter) 1 else 2);
            if (s.is_static) try s.emitOp(opcode.op.swap);
        }
        return;
    }

    // Check for private field (#x)
    if (s.peekKind() == tok.TOK_PRIVATE_NAME) {
        const private_atom = try privateNameAtom(s, s.token.payload.ident.atom);
        defer s.function.atoms.free(private_atom);
        if (atomNameEquals(s, private_atom, "#constructor")) return Error.UnexpectedToken;
        try s.advance();
        if (s.peekKind() == '(') {
            // Private method
            try registerClassPrivateElement(s, private_atom, .method);
            try parseClassElementFunction(s, method_kind_override orelse .method, element_source_start);
            if (s.is_static) try s.emitOp(opcode.op.perm3);
            try s.emitOpAtomU8(opcode.op.define_method, private_atom, 0);
            if (s.is_static) try s.emitOp(opcode.op.swap);
            if (s.peekKind() == ';') try s.advance();
            return;
        } else if (s.peekKind() == '=') {
            // Private field with initializer
            try registerClassPrivateElement(s, private_atom, .field);
            try s.advance();
            if (s.is_static) {
                try emitStaticPublicFieldInitializer(s, private_atom);
            } else {
                try emitInstancePublicFieldInitializer(s, private_atom, true);
            }
        } else {
            try registerClassPrivateElement(s, private_atom, .field);
            if (s.is_static) {
                try s.emitOp(opcode.op.swap);
                try s.emitOp(opcode.op.undefined);
                try s.emitOpAtom(opcode.op.define_field, private_atom);
                try s.emitOp(opcode.op.swap);
            } else {
                try emitInstancePublicFieldInitializer(s, private_atom, false);
            }
        }
        _ = try s.expectSemicolon();
        return;
    }

    if (s.peekKind() == '[') {
        if (s.is_static) {
            try emitStaticClassComputedElement(s, method_kind_override orelse .method, element_source_start);
        } else {
            try emitInstanceClassComputedElement(s, method_kind_override orelse .method, element_source_start);
        }
        if (s.peekKind() == ';') try s.advance();
        return;
    }

    // Check for method or field
    if (try parseObjectPropertyName(s)) |prop_name| {
        const prop_atom = prop_name.atom;
        defer if (prop_name.retained) s.function.atoms.free(prop_atom);
        const has_line_terminator_after_name = s.gotLineTerminator();
        const is_constructor = !s.is_static and prop_atom == atom_module.ids.constructor;
        if (s.is_static and prop_atom == atom_module.ids.prototype and s.peekKind() == '(') return Error.UnexpectedToken;
        if (is_constructor and method_kind_override != null) return Error.UnexpectedToken;
        if (s.is_static and atomNameEquals(s, prop_atom, "name")) {
            s.class_static_name_seen = true;
        }

        if (s.peekKind() == '(') {
            // Method or constructor
            if (is_constructor) {
                if (s.class_constructor_cpool_idx != null) return Error.UnexpectedToken;
                s.in_constructor = true;
            }
            const element_code_start = s.currentCodeLen();
            const element_atom_start = s.currentAtomOperandLen();
            // Parse parameters with proper function kind for constructor/method
            const kind: ParseFunctionKind = if (is_constructor)
                if (s.class_has_extends) .derived_class_constructor else .class_constructor
            else
                method_kind_override orelse .method;
            try parseClassElementFunction(s, kind, element_source_start);
            if (is_constructor) {
                if (s.last_function_child_index) |child_index| {
                    try s.truncateCode(element_code_start);
                    try s.truncateAtomOperands(element_atom_start);
                    const cpool_idx = s.cur_func().child_list[child_index].parent_cpool_idx;
                    if (cpool_idx < 0 or cpool_idx > std.math.maxInt(u16)) return Error.UnexpectedToken;
                    s.class_constructor_cpool_idx = @intCast(cpool_idx);
                }
                s.in_constructor = saved_in_constructor;
            } else {
                if (s.is_static) try s.emitOp(opcode.op.perm3);
                try s.emitOpAtomU8(opcode.op.define_method, prop_atom, 0);
                if (s.is_static) try s.emitOp(opcode.op.swap);
            }
            // Optional ASI semicolon after method
            if (s.peekKind() == ';') try s.advance();
        } else if (s.peekKind() == '=') {
            // Field with initializer
            if (isForbiddenPublicFieldName(s, prop_atom)) return Error.UnexpectedToken;
            try s.advance();
            if (s.is_static) {
                try emitStaticPublicFieldInitializer(s, prop_atom);
            } else {
                try emitInstancePublicFieldInitializer(s, prop_atom, true);
            }
            _ = try s.expectSemicolon();
        } else if (s.peekKind() == ';') {
            // Field without initializer, with semicolon
            if (isForbiddenPublicFieldName(s, prop_atom)) return Error.UnexpectedToken;
            try emitPublicFieldNoInitializer(s, prop_atom);
            try s.advance();
        } else {
            if (isForbiddenPublicFieldName(s, prop_atom)) return Error.UnexpectedToken;
            try emitPublicFieldNoInitializer(s, prop_atom);
            if (s.peekKind() == ';') {
                try s.advance();
            } else if (!(has_line_terminator_after_name or s.peekKind() == tok.TOK_EOF or s.isPunct('}'))) {
                return Error.UnexpectedToken;
            }
        }
    } else if (s.peekKind() == '{') {
        // Static block — parseBlock consumes its own opening '{'.
        if (!s.is_static) {
            return Error.UnexpectedToken;
        }
        try emitClassStaticBlock(s);
    } else {
        return Error.UnexpectedToken;
    }

    s.is_static = saved_static;
    s.in_constructor = saved_in_constructor;
}

fn classAccessorKind(s: *ParseState) ?bool {
    if (!(s.peekKind() == tok.TOK_IDENT and (s.isIdent("get") or s.isIdent("set")))) return null;

    var has_line_terminator = false;
    const next = s.peekNextKindWithLineTerminator(&has_line_terminator);
    if (has_line_terminator) return null;
    if (next == @as(tok.TokenKind, @intCast('(')) or
        next == @as(tok.TokenKind, @intCast('=')) or
        next == @as(tok.TokenKind, @intCast(';')) or
        next == @as(tok.TokenKind, @intCast('}')))
    {
        return null;
    }
    return s.isIdent("get");
}

fn registerClassPrivateElement(s: *ParseState, atom_id: Atom, kind: ClassPrivateElementKind) Error!void {
    for (s.class_private_elements.items) |entry| {
        if (entry.atom != atom_id) continue;
        if (classPrivateElementsConflict(entry, kind, s.is_static)) {
            return Error.UnexpectedToken;
        }
    }
    const retained = s.function.atoms.dup(atom_id);
    errdefer s.function.atoms.free(retained);
    try s.class_private_elements.append(s.function.memory.allocator, .{
        .atom = retained,
        .kind = kind,
        .is_static = s.is_static,
    });
}

fn isForbiddenPublicFieldName(s: *ParseState, atom_id: Atom) bool {
    if (!s.is_static) return atom_id == atom_module.ids.constructor;
    return atom_id == atom_module.ids.constructor or atom_id == atom_module.ids.prototype;
}

fn classNameAtom(s: *ParseState) ?Atom {
    const kind = s.peekKind();
    if (kind == tok.TOK_IDENT) {
        const atom_id = s.token.payload.ident.atom;
        if (escapedIdentifierIsReservedClassName(s, atom_id, s.token.payload.ident.has_escape)) return null;
        return atom_id;
    }
    if (kind == tok.TOK_AWAIT and canUseAwaitAsIdentifier(s)) {
        return tok.keywordAtom(kind);
    }
    return null;
}

fn escapedIdentifierIsReservedClassName(s: *ParseState, atom_id: Atom, has_escape: bool) bool {
    if (!has_escape) return false;
    return escapedIdentifierIsReservedWordForShorthandBinding(s, atom_id, has_escape) or
        ((s.lex.is_module or s.in_async or s.in_class_static_block) and atomNameEquals(s, atom_id, "await"));
}

fn emitStaticPublicFieldInitializer(s: *ParseState, atom_id: Atom) Error!void {
    const this_atom = try classStaticBlockThisTempAtom(s);
    defer s.function.atoms.free(this_atom);
    _ = try s.addScopeVar(this_atom, .normal, true, true);

    try s.emitOp(opcode.op.swap);
    try s.emitOp(opcode.op.dup);
    try s.emitScopePutVarInit(this_atom);

    const saved_static_field_this_atom = s.class_static_field_this_atom;
    const saved_new_target_allowed = s.new_target_allowed;
    const saved_allow_super = s.allow_super;
    s.class_static_field_this_atom = this_atom;
    s.new_target_allowed = true;
    s.allow_super = true;
    defer s.class_static_field_this_atom = saved_static_field_this_atom;
    defer s.new_target_allowed = saved_new_target_allowed;
    defer s.allow_super = saved_allow_super;

    s.class_field_initializer_depth += 1;
    defer s.class_field_initializer_depth -= 1;
    try parseExpr(s);
    try s.emitOp(opcode.op.set_home_object);
    if (s.last_anonymous_function_expr) {
        try s.emitOpAtom(opcode.op.set_name, atom_id);
        s.last_anonymous_function_expr = false;
    }
    try s.emitOpAtom(opcode.op.define_field, atom_id);
    try s.emitOp(opcode.op.swap);
}

fn emitPublicFieldNoInitializer(s: *ParseState, atom_id: Atom) Error!void {
    if (s.is_static) {
        try s.emitOp(opcode.op.swap);
        try s.emitOp(opcode.op.undefined);
        try s.emitOpAtom(opcode.op.define_field, atom_id);
        try s.emitOp(opcode.op.swap);
        return;
    }
    try emitInstancePublicFieldInitializer(s, atom_id, false);
}

fn emitInstancePublicFieldInitializer(s: *ParseState, atom_id: Atom, has_initializer: bool) Error!void {
    const child_index = try ensureClassFieldsInitFunction(s);
    const parent_fd = s.cur_func();
    if (child_index >= parent_fd.child_list.len) return Error.UnexpectedToken;
    const init_fd = &parent_fd.child_list[child_index];

    const saved_emit_to_function_def = s.emit_to_function_def;
    const saved_scope_level = s.scope_level;
    const saved_is_strict = s.is_strict;
    const saved_lex_is_strict = s.lex.is_strict_mode;
    const saved_allow_super = s.allow_super;
    const saved_allow_super_call = s.allow_super_call;
    const saved_new_target_allowed = s.new_target_allowed;
    const saved_in_constructor = s.in_constructor;
    const saved_last_anonymous_function_expr = s.last_anonymous_function_expr;
    const saved_last_function_child_index = s.last_function_child_index;

    try s.pushFunction(init_fd);
    s.emit_to_function_def = true;
    s.scope_level = 0;
    s.is_strict = true;
    s.lex.is_strict_mode = true;
    s.allow_super = true;
    s.allow_super_call = false;
    s.new_target_allowed = true;
    s.in_constructor = false;
    s.last_anonymous_function_expr = false;
    errdefer {
        _ = s.popFunction();
        s.emit_to_function_def = saved_emit_to_function_def;
        s.scope_level = saved_scope_level;
        s.is_strict = saved_is_strict;
        s.lex.is_strict_mode = saved_lex_is_strict;
        s.allow_super = saved_allow_super;
        s.allow_super_call = saved_allow_super_call;
        s.new_target_allowed = saved_new_target_allowed;
        s.in_constructor = saved_in_constructor;
        s.last_anonymous_function_expr = saved_last_anonymous_function_expr;
        s.last_function_child_index = saved_last_function_child_index;
    }

    try s.emitOp(opcode.op.push_this);
    if (has_initializer) {
        s.class_field_initializer_depth += 1;
        defer s.class_field_initializer_depth -= 1;
        try parseAssignExpr(s);
        if (s.last_anonymous_function_expr) {
            try s.emitOpAtom(opcode.op.set_name, atom_id);
            s.last_anonymous_function_expr = false;
        }
    } else {
        try s.emitOp(opcode.op.undefined);
    }
    try s.emitOpAtom(opcode.op.define_field, atom_id);
    try s.emitOp(opcode.op.drop);

    _ = s.popFunction();
    s.emit_to_function_def = saved_emit_to_function_def;
    s.scope_level = saved_scope_level;
    s.is_strict = saved_is_strict;
    s.lex.is_strict_mode = saved_lex_is_strict;
    s.allow_super = saved_allow_super;
    s.allow_super_call = saved_allow_super_call;
    s.new_target_allowed = saved_new_target_allowed;
    s.in_constructor = saved_in_constructor;
    s.last_anonymous_function_expr = saved_last_anonymous_function_expr;
    s.last_function_child_index = saved_last_function_child_index;
}

fn ensureClassFieldsInitFunction(s: *ParseState) Error!usize {
    if (s.class_fields_init_child_index) |child_index| return child_index;

    const parent_fd = s.cur_func();
    const child_fd = try s.function.memory.create(function_def_mod.FunctionDef);
    child_fd.* = function_def_mod.FunctionDef.init(s.function.memory, s.function.atoms, 120); // <class_fields_init>
    var child_moved = false;
    errdefer if (!child_moved) s.discardFunctionDef(child_fd);
    child_fd.atoms.replace(&child_fd.filename, parent_fd.filename);
    child_fd.line_num = @intCast(s.token.line_num);
    child_fd.col_num = @intCast(s.token.col_num);
    child_fd.parent = parent_fd;
    child_fd.parent_scope_level = parent_fd.scope_level;
    child_fd.is_strict_mode = true;
    child_fd.is_indirect_eval = parent_fd.is_indirect_eval;
    child_fd.use_short_opcodes = parent_fd.use_short_opcodes;
    child_fd.func_type = .method;
    child_fd.func_kind = .normal;
    child_fd.has_prototype = false;
    child_fd.has_home_object = true;
    child_fd.need_home_object = true;
    child_fd.has_this_binding = true;
    child_fd.new_target_allowed = true;
    child_fd.super_allowed = true;
    _ = child_fd.appendScope(-1) catch return error.OutOfMemory;
    const cpool_idx: u16 = @intCast(try parent_fd.appendCpool(JSValue.undefinedValue()));
    child_fd.parent_cpool_idx = cpool_idx;
    try parent_fd.addChild(child_fd.*);
    child_moved = true;
    s.function.memory.destroy(function_def_mod.FunctionDef, child_fd);
    const child_index: u16 = @intCast(parent_fd.child_list.len - 1);
    s.class_fields_init_child_index = child_index;
    return child_index;
}

fn finishClassFieldsInitFunction(s: *ParseState) Error!void {
    const child_index = s.class_fields_init_child_index orelse return;
    const parent_fd = s.cur_func();
    if (child_index >= parent_fd.child_list.len) return Error.UnexpectedToken;
    const init_fd = &parent_fd.child_list[child_index];
    const code = init_fd.byte_code;
    const needs_return = code.len == 0 or switch (code[code.len - 1]) {
        opcode.op.@"return", opcode.op.return_undef, opcode.op.return_async, opcode.op.throw => false,
        else => true,
    };
    if (!needs_return) return;
    try init_fd.appendByteCode(&.{opcode.op.return_undef});
}

fn attachClassFieldsInitToConstructor(
    s: *ParseState,
    constructor_cpool_idx: u16,
) Error!void {
    const init_child_index = s.class_fields_init_child_index orelse return;
    const parent_fd = s.cur_func();
    if (init_child_index >= parent_fd.child_list.len) return Error.UnexpectedToken;
    const init_cpool_idx = parent_fd.child_list[init_child_index].parent_cpool_idx;
    if (init_cpool_idx < 0) return Error.UnexpectedToken;
    for (parent_fd.child_list) |*child| {
        if (child.parent_cpool_idx != @as(i32, @intCast(constructor_cpool_idx))) continue;
        child.class_fields_init_cpool_idx = init_cpool_idx;
        return;
    }
    return Error.UnexpectedToken;
}

fn registerClassPublicInstanceField(s: *ParseState, atom_id: Atom) Error!void {
    try appendRetainedAtom(&s.class_public_instance_fields, s.function.memory.allocator, s.function.atoms, atom_id);
}

fn attachClassPublicInstanceFieldsToConstructor(
    s: *ParseState,
    cpool_idx: u16,
    field_start: usize,
) Error!void {
    if (field_start >= s.class_public_instance_fields.items.len) return;
    for (s.cur_func().child_list) |*child| {
        if (child.parent_cpool_idx != @as(i32, @intCast(cpool_idx))) continue;
        for (s.class_public_instance_fields.items[field_start..]) |atom_id| {
            try child.appendClassInstanceField(atom_id);
        }
        return;
    }
    return Error.UnexpectedToken;
}

fn attachClassDeclaredPrivateNamesToConstructor(
    s: *ParseState,
    cpool_idx: u16,
    element_start: usize,
) Error!void {
    if (element_start >= s.class_private_elements.items.len) return;
    for (s.cur_func().child_list) |*child| {
        if (child.parent_cpool_idx != @as(i32, @intCast(cpool_idx))) continue;
        for (s.class_private_elements.items[element_start..]) |entry| {
            try child.appendClassPrivateName(entry.atom);
        }
        return;
    }
    return Error.UnexpectedToken;
}

fn registerClassPrivateBoundName(s: *ParseState, atom_id: Atom) Error!void {
    for (s.class_private_bound_names.items) |existing| {
        if (existing == atom_id) return;
    }
    try appendRetainedAtom(&s.class_private_bound_names, s.function.memory.allocator, s.function.atoms, atom_id);
}

fn classPrivateNameIsBound(s: *ParseState, atom_id: Atom) bool {
    for (s.class_private_bound_names.items) |existing| {
        if (existing == atom_id) return true;
    }
    return false;
}

fn classPrivateElementsConflict(
    existing: ClassPrivateElement,
    new_kind: ClassPrivateElementKind,
    new_is_static: bool,
) bool {
    const getter_setter_pair =
        (existing.kind == .getter and new_kind == .setter) or
        (existing.kind == .setter and new_kind == .getter);
    return !getter_setter_pair or existing.is_static != new_is_static;
}

fn privateNameAtom(s: *ParseState, atom_id: Atom) Error!Atom {
    s.features.insert(.private_name);
    if (findClassPrivateBoundName(s, atom_id, 0)) |private_atom| {
        return s.function.atoms.dup(private_atom);
    }
    return newClassPrivateAtom(s, atom_id);
}

fn privateNameDeclarationAtom(s: *ParseState, atom_id: Atom, bound_start: usize) Error!Atom {
    s.features.insert(.private_name);
    if (findClassPrivateBoundName(s, atom_id, bound_start)) |private_atom| {
        return s.function.atoms.dup(private_atom);
    }
    return newClassPrivateAtom(s, atom_id);
}

fn findClassPrivateBoundName(s: *ParseState, atom_id: Atom, bound_start: usize) ?Atom {
    var i = s.class_private_bound_names.items.len;
    while (i > bound_start) {
        i -= 1;
        const private_atom = s.class_private_bound_names.items[i];
        if (privateAtomMatchesName(s, private_atom, atom_id)) return private_atom;
    }
    return null;
}

fn privateAtomMatchesName(s: *ParseState, private_atom: Atom, atom_id: Atom) bool {
    const private_name = s.function.atoms.name(private_atom) orelse return false;
    const name = s.function.atoms.name(atom_id) orelse return false;
    if (std.mem.eql(u8, private_name, name)) return true;
    if (name.len > 0 and name[0] == '#') return false;
    return private_name.len == name.len + 1 and
        private_name[0] == '#' and
        std.mem.eql(u8, private_name[1..], name);
}

fn newClassPrivateAtom(s: *ParseState, atom_id: Atom) Error!Atom {
    const name = s.function.atoms.name(atom_id) orelse return Error.InvalidIdentifier;
    if (name.len > 0 and name[0] == '#') {
        return s.function.atoms.newSymbol(name, .private);
    }
    const bytes = try s.function.memory.alloc(u8, name.len + 1);
    defer s.function.memory.free(u8, bytes);
    bytes[0] = '#';
    @memcpy(bytes[1..], name);
    return s.function.atoms.newSymbol(bytes, .private);
}

fn classComputedFieldTempAtom(s: *ParseState) Error!Atom {
    const temp_name = try std.fmt.allocPrint(s.function.memory.allocator, "__class_computed_field_{d}", .{s.with_scope_id});
    defer s.function.memory.allocator.free(temp_name);
    s.with_scope_id += 1;
    return s.function.atoms.internString(temp_name);
}

fn classStaticBlockThisTempAtom(s: *ParseState) Error!Atom {
    const temp_name = try std.fmt.allocPrint(s.function.memory.allocator, "__class_static_this_{d}", .{s.with_scope_id});
    defer s.function.memory.allocator.free(temp_name);
    s.with_scope_id += 1;
    return s.function.atoms.internString(temp_name);
}

fn parseClassElementFunction(s: *ParseState, kind: ParseFunctionKind, source_start: usize) Error!void {
    const saved_parameter_properties = s.current_parameter_properties;
    if (kind == .class_constructor or kind == .derived_class_constructor) {
        s.current_parameter_properties = std.ArrayList(Atom).empty;
    } else {
        s.current_parameter_properties = null;
    }
    defer {
        if (kind == .class_constructor or kind == .derived_class_constructor) {
            if (s.current_parameter_properties) |*props| {
                props.deinit(s.function.memory.allocator);
            }
        }
        s.current_parameter_properties = saved_parameter_properties;
    }

    const saved_pending_name = s.pending_function_name;
    const saved_pending_decl = s.pending_function_is_decl;
    const saved_in_async = s.in_async;
    const saved_in_generator = s.in_generator;
    const saved_is_strict = s.is_strict;
    const saved_allow_super = s.allow_super;
    const saved_top_level_children = s.top_level_functions_as_children;
    s.pending_function_name = null;
    s.pending_function_is_decl = false;
    s.in_async = kind == .async or kind == .async_generator;
    s.in_generator = kind == .generator or kind == .async_generator;
    s.is_strict = true;
    s.allow_super = true;
    s.top_level_functions_as_children = true;
    defer {
        s.pending_function_name = saved_pending_name;
        s.pending_function_is_decl = saved_pending_decl;
        s.in_async = saved_in_async;
        s.in_generator = saved_in_generator;
        s.is_strict = saved_is_strict;
        s.allow_super = saved_allow_super;
        s.top_level_functions_as_children = saved_top_level_children;
    }
    try parseFunctionParamsAndBody(s, kind, source_start);
    try attachClassPrivateBoundNamesToLastFunction(s);
}

fn attachClassPrivateBoundNamesToLastFunction(s: *ParseState) Error!void {
    const child_index = s.last_function_child_index orelse return;
    if (child_index >= s.cur_func().child_list.len) return;
    const child = &s.cur_func().child_list[child_index];
    try attachVisibleClassPrivateBoundNamesToFunction(s, child);
}

fn attachVisibleClassPrivateBoundNamesToFunction(s: *ParseState, child: *function_def_mod.FunctionDef) Error!void {
    for (s.class_private_bound_names.items) |atom_id| {
        try child.appendPrivateBoundName(atom_id);
    }
}

fn attachClassPrivateBoundNamesToChildren(s: *ParseState, child_start: usize) Error!void {
    var child_index = child_start;
    while (child_index < s.cur_func().child_list.len) : (child_index += 1) {
        const child = &s.cur_func().child_list[child_index];
        for (s.class_private_bound_names.items) |atom_id| {
            try child.appendPrivateBoundName(atom_id);
        }
    }
}

fn parseClassComputedName(s: *ParseState) Error!void {
    try s.expectToken('[');
    try parseAssignExpr2(s, ParseFlags.default);
    try s.emitOp(opcode.op.to_propkey);
    try expectPunct(s, ']');
}

fn deferCurrentCodeToClassStatic(s: *ParseState, code_start: usize, atom_start: usize) Error!void {
    const code = s.currentCode();
    const atoms = s.currentAtomOperands();
    if (code_start > code.len or atom_start > atoms.len) return Error.UnexpectedToken;
    const moved_len = code.len - code_start;
    if (moved_len != 0) {
        const moved = try s.function.memory.alloc(u8, moved_len);
        defer s.function.memory.free(u8, moved);
        @memcpy(moved, code[code_start..]);
        try rebaseMovedBytecodeLabels(moved, atoms[atom_start..], code_start, s.class_static_deferred_code.items.len);
        try s.class_static_deferred_code.appendSlice(s.function.memory.allocator, moved);
    }
    for (atoms[atom_start..]) |atom_id| {
        try appendRetainedAtom(&s.class_static_deferred_atoms, s.function.memory.allocator, s.function.atoms, atom_id);
    }
    try s.truncateCode(code_start);
    try s.truncateAtomOperands(atom_start);
}

fn appendClassStaticDeferred(s: *ParseState, code_start: usize, atom_start: usize) Error!void {
    if (code_start > s.class_static_deferred_code.items.len or atom_start > s.class_static_deferred_atoms.items.len) return Error.UnexpectedToken;
    if (code_start == s.class_static_deferred_code.items.len) return;
    try s.appendMovedCodeWithAtoms(
        s.class_static_deferred_code.items[code_start..],
        s.class_static_deferred_atoms.items[atom_start..],
        code_start,
    );
    s.truncateClassStaticDeferred(code_start, atom_start);
}

fn emitStaticClassComputedElement(s: *ParseState, kind: ParseFunctionKind, source_start: usize) Error!void {
    try s.emitOp(opcode.op.swap);
    try parseClassComputedName(s);
    if (s.peekKind() == '(') {
        try parseClassElementFunction(s, kind, source_start);
        try s.emitOpU8(opcode.op.define_method_computed, 0);
        try s.emitOp(opcode.op.swap);
        return;
    }
    if (kind != .method) return Error.UnexpectedToken;

    const key_atom = try classComputedFieldTempAtom(s);
    defer s.function.atoms.free(key_atom);
    _ = try s.addScopeVar(key_atom, .normal, true, true);
    try s.emitScopePutVarInit(key_atom);
    try s.emitOp(opcode.op.swap);

    const deferred_code_start = s.currentCodeLen();
    const deferred_atom_start = s.currentAtomOperandLen();
    try s.emitOp(opcode.op.swap);
    try s.emitScopeGetVar(key_atom);
    if (s.peekKind() == '=') {
        try s.advance();
        const this_atom = try classStaticBlockThisTempAtom(s);
        defer s.function.atoms.free(this_atom);
        _ = try s.addScopeVar(this_atom, .normal, true, true);
        try s.emitOp(opcode.op.swap);
        try s.emitOp(opcode.op.dup);
        try s.emitScopePutVarInit(this_atom);
        try s.emitOp(opcode.op.swap);

        const saved_static_field_this_atom = s.class_static_field_this_atom;
        const saved_new_target_allowed = s.new_target_allowed;
        const saved_allow_super = s.allow_super;
        s.class_static_field_this_atom = this_atom;
        s.new_target_allowed = true;
        s.allow_super = true;
        defer s.class_static_field_this_atom = saved_static_field_this_atom;
        defer s.new_target_allowed = saved_new_target_allowed;
        defer s.allow_super = saved_allow_super;

        s.class_field_initializer_depth += 1;
        defer s.class_field_initializer_depth -= 1;
        try parseExpr(s);
        try s.emitOp(opcode.op.set_home_object);
        if (s.last_anonymous_function_expr) {
            try s.emitOp(opcode.op.set_name_computed);
            s.last_anonymous_function_expr = false;
        }
    } else {
        try s.emitOp(opcode.op.undefined);
    }
    try s.emitOp(opcode.op.define_array_el);
    try s.emitOp(opcode.op.drop);
    try s.emitOp(opcode.op.swap);
    try deferCurrentCodeToClassStatic(s, deferred_code_start, deferred_atom_start);
    _ = try s.expectSemicolon();
}

fn emitInstanceComputedPublicFieldInitializer(s: *ParseState, key_atom: Atom, has_initializer: bool) Error!void {
    const child_index = try ensureClassFieldsInitFunction(s);
    const parent_fd = s.cur_func();
    if (child_index >= parent_fd.child_list.len) return Error.UnexpectedToken;
    const init_fd = &parent_fd.child_list[child_index];

    const saved_emit_to_function_def = s.emit_to_function_def;
    const saved_scope_level = s.scope_level;
    const saved_is_strict = s.is_strict;
    const saved_lex_is_strict = s.lex.is_strict_mode;
    const saved_allow_super = s.allow_super;
    const saved_allow_super_call = s.allow_super_call;
    const saved_new_target_allowed = s.new_target_allowed;
    const saved_in_constructor = s.in_constructor;
    const saved_last_anonymous_function_expr = s.last_anonymous_function_expr;
    const saved_last_function_child_index = s.last_function_child_index;

    try s.pushFunction(init_fd);
    s.emit_to_function_def = true;
    s.scope_level = 0;
    s.is_strict = true;
    s.lex.is_strict_mode = true;
    s.allow_super = true;
    s.allow_super_call = false;
    s.new_target_allowed = true;
    s.in_constructor = false;
    s.last_anonymous_function_expr = false;
    errdefer {
        _ = s.popFunction();
        s.emit_to_function_def = saved_emit_to_function_def;
        s.scope_level = saved_scope_level;
        s.is_strict = saved_is_strict;
        s.lex.is_strict_mode = saved_lex_is_strict;
        s.allow_super = saved_allow_super;
        s.allow_super_call = saved_allow_super_call;
        s.new_target_allowed = saved_new_target_allowed;
        s.in_constructor = saved_in_constructor;
        s.last_anonymous_function_expr = saved_last_anonymous_function_expr;
        s.last_function_child_index = saved_last_function_child_index;
    }

    try s.emitOp(opcode.op.push_this);
    try s.emitScopeGetVar(key_atom);
    if (has_initializer) {
        s.class_field_initializer_depth += 1;
        defer s.class_field_initializer_depth -= 1;
        try parseAssignExpr(s);
        if (s.last_anonymous_function_expr) {
            try s.emitOp(opcode.op.set_name_computed);
            s.last_anonymous_function_expr = false;
        }
    } else {
        try s.emitOp(opcode.op.undefined);
    }
    try s.emitOp(opcode.op.define_array_el);
    try s.emitOp(opcode.op.drop);

    _ = s.popFunction();
    s.emit_to_function_def = saved_emit_to_function_def;
    s.scope_level = saved_scope_level;
    s.is_strict = saved_is_strict;
    s.lex.is_strict_mode = saved_lex_is_strict;
    s.allow_super = saved_allow_super;
    s.allow_super_call = saved_allow_super_call;
    s.new_target_allowed = saved_new_target_allowed;
    s.in_constructor = saved_in_constructor;
    s.last_anonymous_function_expr = saved_last_anonymous_function_expr;
    s.last_function_child_index = saved_last_function_child_index;
}

fn emitInstanceClassComputedElement(s: *ParseState, kind: ParseFunctionKind, source_start: usize) Error!void {
    try parseClassComputedName(s);
    if (s.peekKind() == '(') {
        try parseClassElementFunction(s, kind, source_start);
        try s.emitOpU8(opcode.op.define_method_computed, 0);
        return;
    }
    if (kind != .method) return Error.UnexpectedToken;

    const key_atom = try classComputedFieldTempAtom(s);
    defer s.function.atoms.free(key_atom);
    _ = try s.addScopeVar(key_atom, .normal, true, true);
    try s.emitScopePutVarInit(key_atom);

    if (s.peekKind() == '=') {
        try s.advance();
        try emitInstanceComputedPublicFieldInitializer(s, key_atom, true);
    } else {
        try emitInstanceComputedPublicFieldInitializer(s, key_atom, false);
    }
    _ = try s.expectSemicolon();
}

fn emitClassComputedMethod(s: *ParseState, kind: ParseFunctionKind, define_flags: u8, source_start: usize) Error!void {
    if (s.is_static) try s.emitOp(opcode.op.swap);
    try parseClassComputedName(s);
    if (s.peekKind() != '(') return Error.UnexpectedToken;
    try parseClassElementFunction(s, kind, source_start);
    try s.emitOpU8(opcode.op.define_method_computed, define_flags);
    if (s.is_static) try s.emitOp(opcode.op.swap);
}

fn emitClassStaticBlock(s: *ParseState) Error!void {
    const this_atom = try classStaticBlockThisTempAtom(s);
    defer s.function.atoms.free(this_atom);
    _ = try s.addScopeVar(this_atom, .normal, true, true);

    try s.emitOp(opcode.op.swap);
    try s.emitOp(opcode.op.dup);
    try s.emitScopePutVarInit(this_atom);
    try s.emitOp(opcode.op.swap);

    const saved_pending_name = s.pending_function_name;
    const saved_pending_decl = s.pending_function_is_decl;
    const saved_is_strict = s.is_strict;
    const saved_lex_is_strict = s.lex.is_strict_mode;
    const saved_static_block = s.in_class_static_block;
    const saved_is_static = s.is_static;
    s.pending_function_name = null;
    s.pending_function_is_decl = false;
    s.is_strict = true;
    s.lex.is_strict_mode = true;
    s.in_class_static_block = true;
    s.is_static = false;
    defer {
        s.pending_function_name = saved_pending_name;
        s.pending_function_is_decl = saved_pending_decl;
        s.is_strict = saved_is_strict;
        s.lex.is_strict_mode = saved_lex_is_strict;
        s.in_class_static_block = saved_static_block;
        s.is_static = saved_is_static;
    }

    try parseFunctionParamsAndBody(s, .class_static_block, null);
    try attachClassPrivateBoundNamesToLastFunction(s);
    try s.emitScopeGetVar(this_atom);
    try s.emitOp(opcode.op.swap);
    try s.emitOp(opcode.op.set_home_object);
    try s.emitOpU16(opcode.op.call_method, 0);
    try s.emitOp(opcode.op.drop);
}

/// Parse class body
/// Mirrors `js_parse_class_body` in quickjs.c
fn parseClassBody(s: *ParseState) Error!void {
    try s.expectToken('{');

    while (s.peekKind() != '}' and s.peekKind() != tok.TOK_EOF) {
        if (s.peekKind() == ';') {
            try s.advance();
            continue;
        }
        try parseClassElement(s);
    }

    try s.expectToken('}');
}

fn collectClassPrivateBoundNames(s: *ParseState, bound_start: usize) Error!void {
    if (s.peekKind() != @as(tok.TokenKind, @intCast('{'))) return;

    const saved_pos = s.lex.pos;
    const saved_line = s.lex.line;
    const saved_col = s.lex.col;
    const saved_got_lf = s.lex.got_lf;
    const saved_mark_pos = s.lex.mark_pos;
    const saved_mark_line = s.lex.mark_line;
    const saved_mark_col = s.lex.mark_col;
    defer {
        s.lex.pos = saved_pos;
        s.lex.line = saved_line;
        s.lex.col = saved_col;
        s.lex.got_lf = saved_got_lf;
        s.lex.mark_pos = saved_mark_pos;
        s.lex.mark_line = saved_mark_line;
        s.lex.mark_col = saved_mark_col;
    }

    var brace_depth: usize = 1;
    var paren_depth: usize = 0;
    var bracket_depth: usize = 0;
    var prev_kind: tok.TokenKind = 0;
    while (brace_depth > 0) {
        var scan_token = try s.lex.next();
        defer s.lex.freeToken(&scan_token);
        const k = scan_token.val;
        if (k == tok.TOK_EOF) break;

        if (k == tok.TOK_PRIVATE_NAME and
            brace_depth == 1 and
            paren_depth == 0 and
            bracket_depth == 0 and
            prev_kind != @as(tok.TokenKind, @intCast('.')) and
            prev_kind != tok.TOK_QUESTION_MARK_DOT)
        {
            const private_atom = try privateNameDeclarationAtom(s, scan_token.payload.ident.atom, bound_start);
            defer s.function.atoms.free(private_atom);
            try registerClassPrivateBoundName(s, private_atom);
        }

        switch (k) {
            @as(tok.TokenKind, @intCast('/')), tok.TOK_DIV_ASSIGN => {
                if (try skipRegexpInPredeclareScan(s, prev_kind)) {
                    prev_kind = tok.TOK_REGEXP;
                    continue;
                }
            },
            tok.TOK_TEMPLATE => {
                try skipTemplateInPredeclareScan(s, scan_token);
                prev_kind = tok.TOK_TEMPLATE;
                continue;
            },
            @as(tok.TokenKind, @intCast('{')) => brace_depth += 1,
            @as(tok.TokenKind, @intCast('}')) => {
                brace_depth -= 1;
                if (brace_depth == 0) break;
            },
            @as(tok.TokenKind, @intCast('(')) => paren_depth += 1,
            @as(tok.TokenKind, @intCast(')')) => {
                if (paren_depth > 0) paren_depth -= 1;
            },
            @as(tok.TokenKind, @intCast('[')) => bracket_depth += 1,
            @as(tok.TokenKind, @intCast(']')) => {
                if (bracket_depth > 0) bracket_depth -= 1;
            },
            else => {},
        }
        prev_kind = k;
    }
}

fn emitClassLocalInitFromClassStack(s: *ParseState, local_idx: u16) Error!void {
    try s.emitOp(opcode.op.swap);
    try s.emitOp(opcode.op.dup);
    try s.emitOpU16(opcode.op.put_loc_check_init, local_idx);
    try s.emitOp(opcode.op.swap);
}

fn emitClassFieldsInitValue(s: *ParseState, class_fields_init_child_index: ?u16) Error!void {
    if (class_fields_init_child_index) |child_index| {
        const parent_fd = s.cur_func();
        if (child_index >= parent_fd.child_list.len) return Error.UnexpectedToken;
        const cpool_idx = parent_fd.child_list[child_index].parent_cpool_idx;
        if (cpool_idx < 0) return Error.UnexpectedToken;
        try s.emitFClosure(@intCast(cpool_idx));
        try s.emitOp(opcode.op.set_home_object);
    } else {
        try s.emitOp(opcode.op.undefined);
    }
}

fn emitClassFieldsInitLocalInitFromClassStack(s: *ParseState, fields_init_local_idx: u16, class_fields_init_child_index: ?u16) Error!void {
    try emitClassFieldsInitValue(s, class_fields_init_child_index);
    try s.emitOpU16(opcode.op.put_loc_check_init, fields_init_local_idx);
}

fn emitClassDeclLocalInitFromClassStack(s: *ParseState, class_local_idx: u16, fields_init_local_idx: u16, class_fields_init_child_index: ?u16) Error!void {
    try emitClassFieldsInitLocalInitFromClassStack(s, fields_init_local_idx, class_fields_init_child_index);
    try s.emitOp(opcode.op.drop);
    try s.emitOpU16(opcode.op.set_loc, class_local_idx);
    try s.emitCloseLoc(fields_init_local_idx);
}

fn emitClassDefineOperands(s: *ParseState, cpool_idx: u16) Error!void {
    try s.emitOpU32(opcode.op.push_const, cpool_idx);
}

/// Parse class declaration or expression
/// Mirrors `js_parse_class` in quickjs.c:24667
fn parseClass(s: *ParseState, is_decl: bool) Error!void {
    s.features.insert(.class_);
    const class_source_start = s.currentTokenStartOffset();
    try s.expectToken(tok.TOK_CLASS);
    if (is_decl) s.last_class_decl_atom = null;

    // Parse class name (required for declarations, optional for expressions)
    var class_name: ?Atom = null;
    if (is_decl) {
        const name_atom = classNameAtom(s) orelse return Error.UnexpectedToken;
        if (findCurrentScopeVar(s, name_atom) != null or findCurrentTopLevelLexicalClosureVar(s, name_atom) != null) {
            return Error.UnexpectedToken;
        }
        if (s.scope_level > 0) try s.registerBlockLexicalDeclaration(name_atom);
        class_name = name_atom;
        s.last_class_decl_atom = name_atom;
        try s.advance();
    } else {
        if (classNameAtom(s)) |name_atom| {
            class_name = name_atom;
            try s.advance();
        }
    }

    var class_decl_local_idx: ?u16 = null;
    var class_fields_init_local_idx: ?u16 = null;
    var top_level_class_ref_idx: ?u16 = null;
    if (is_decl) {
        const class_atom = class_name orelse return Error.UnexpectedToken;
        const class_decl_is_const = s.scope_level == 0 and s.top_level_lexical_as_module_ref;
        class_decl_local_idx = @intCast(try s.addScopeVar(class_atom, .normal, true, class_decl_is_const));
        try s.retrofitForwardLocalFunctionCapture(s.cur_func(), class_atom, class_decl_local_idx.?);
        class_fields_init_local_idx = @intCast(try s.addScopeVar(120, .normal, true, true)); // <class_fields_init>
        s.cur_func().vars[class_fields_init_local_idx.?].tdz_emitted_at_decl = true;
        if (s.scope_level == 0) {
            if (s.top_level_lexical_as_module_ref) {
                top_level_class_ref_idx = @intCast(try s.cur_func().addClosureVar(.{
                    .closure_type = .module_decl,
                    .is_lexical = true,
                    .is_const = false,
                    .var_kind = .normal,
                    .var_idx = @intCast(s.cur_func().closure_var.len),
                    .var_name = class_atom,
                }));
                try s.retrofitForwardTopLevelModuleCapture(s.cur_func(), class_atom, top_level_class_ref_idx.?, true, false, .normal);
            } else if (s.cur_func_stack.len == 0 and !s.is_eval) {
                try s.addGlobalVar(class_atom, true, false);
            }
        }
    }

    // Parse heritage (extends clause)
    const saved_has_extends = s.class_has_extends;
    const saved_in_class = s.in_class;
    const saved_is_static = s.is_static;
    const saved_is_strict = s.is_strict;
    const saved_static_name_seen = s.class_static_name_seen;
    const saved_class_constructor_cpool_idx = s.class_constructor_cpool_idx;
    const saved_class_private_elements_len = s.class_private_elements.items.len;
    const saved_class_private_bound_names_len = s.class_private_bound_names.items.len;
    const saved_class_public_instance_fields_len = s.class_public_instance_fields.items.len;
    const saved_class_static_deferred_code_len = s.class_static_deferred_code.items.len;
    const saved_class_static_deferred_atom_len = s.class_static_deferred_atoms.items.len;
    const saved_class_fields_init_child_index = s.class_fields_init_child_index;
    var class_name_scope_pushed = false;
    var class_name_local_idx: ?u16 = null;
    errdefer {
        if (class_name_scope_pushed) s.popScope();
        s.truncateClassPrivateElements(saved_class_private_elements_len);
        s.truncateClassPrivateBoundNames(saved_class_private_bound_names_len);
        s.truncateClassPublicInstanceFields(saved_class_public_instance_fields_len);
        s.truncateClassStaticDeferred(saved_class_static_deferred_code_len, saved_class_static_deferred_atom_len);
        s.class_fields_init_child_index = saved_class_fields_init_child_index;
        s.is_static = saved_is_static;
        s.is_strict = saved_is_strict;
    }

    s.in_class = true;
    s.is_static = false;
    s.is_strict = true;
    s.class_has_extends = s.peekKind() == tok.TOK_EXTENDS;
    s.class_static_name_seen = false;
    s.class_constructor_cpool_idx = null;
    s.class_fields_init_child_index = null;
    if (class_fields_init_local_idx == null) {
        class_fields_init_local_idx = @intCast(try s.addScopeVar(120, .normal, true, true)); // <class_fields_init>
        s.cur_func().vars[class_fields_init_local_idx.?].tdz_emitted_at_decl = true;
    }
    if (class_name) |class_atom| {
        try s.pushScope();
        class_name_scope_pushed = true;
        class_name_local_idx = @intCast(try s.addScopeVar(class_atom, .normal, true, true));
    }
    try parseClassHeritage(s);
    try collectClassPrivateBoundNames(s, saved_class_private_bound_names_len);

    // Parse class body. Constructor parsing records a child FunctionDef;
    // class definition bytecode references that child through push_const /
    // define_class instead of the normal fclosure expression path.
    const child_count_before_class = s.cur_func().child_list.len;
    const class_emit_start = s.currentCodeLen();
    const class_atom_start = s.currentAtomOperandLen();
    try parseClassBody(s);
    const class_source_end = s.last_token_end_offset;
    try finishClassFieldsInitFunction(s);
    try attachClassPrivateBoundNamesToChildren(s, child_count_before_class);
    try appendClassStaticDeferred(s, saved_class_static_deferred_code_len, saved_class_static_deferred_atom_len);
    const runtime_code = s.currentCode()[class_emit_start..];
    const saved_runtime_code = try s.function.memory.alloc(u8, runtime_code.len);
    defer s.function.memory.free(u8, saved_runtime_code);
    @memcpy(saved_runtime_code, runtime_code);
    const runtime_atoms = s.currentAtomOperands()[class_atom_start..];
    const saved_runtime_atoms = try s.function.memory.alloc(Atom, runtime_atoms.len);
    defer s.function.memory.free(Atom, saved_runtime_atoms);
    for (runtime_atoms, 0..) |atom_id, idx| {
        saved_runtime_atoms[idx] = s.function.atoms.dup(atom_id);
    }
    defer for (saved_runtime_atoms) |atom_id| s.function.atoms.free(atom_id);
    try s.truncateCode(class_emit_start);
    try s.truncateAtomOperands(class_atom_start);
    if (class_name_scope_pushed) {
        s.popScope();
        class_name_scope_pushed = false;
    }
    const default_constructor_name = class_name orelse if (is_decl) s.function.name else atom_module.ids.empty_string;
    const class_constructor_cpool_idx = s.class_constructor_cpool_idx orelse
        try appendDefaultClassConstructor(s, default_constructor_name);
    try s.setChildFunctionSourceByCpoolIndex(class_constructor_cpool_idx, class_source_start, class_source_end);
    const class_has_extends = s.class_has_extends;
    try attachClassPublicInstanceFieldsToConstructor(s, class_constructor_cpool_idx, saved_class_public_instance_fields_len);
    try attachClassDeclaredPrivateNamesToConstructor(s, class_constructor_cpool_idx, saved_class_private_elements_len);
    try attachClassFieldsInitToConstructor(s, class_constructor_cpool_idx);
    const parsed_class_fields_init_child_index = s.class_fields_init_child_index;

    s.in_class = saved_in_class;
    s.is_static = saved_is_static;
    s.is_strict = saved_is_strict;
    s.class_has_extends = saved_has_extends;
    const class_static_name_seen = s.class_static_name_seen;
    s.class_static_name_seen = saved_static_name_seen;
    s.class_constructor_cpool_idx = saved_class_constructor_cpool_idx;
    s.truncateClassPrivateElements(saved_class_private_elements_len);
    s.truncateClassPrivateBoundNames(saved_class_private_bound_names_len);
    s.truncateClassPublicInstanceFields(saved_class_public_instance_fields_len);
    s.truncateClassStaticDeferred(saved_class_static_deferred_code_len, saved_class_static_deferred_atom_len);
    s.class_fields_init_child_index = saved_class_fields_init_child_index;

    const name_atom = class_name orelse s.function.name;
    if (is_decl) {
        if (s.scope_level > 0) {
            const class_local_idx = class_decl_local_idx orelse return Error.UnexpectedToken;
            const fields_idx = class_fields_init_local_idx orelse return Error.UnexpectedToken;
            if (!class_has_extends) try s.emitOp(opcode.op.undefined);
            try s.emitOpU16(opcode.op.set_loc_uninitialized, fields_idx);
            try emitClassDefineOperands(s, class_constructor_cpool_idx);
            try s.emitOpAtomU8(opcode.op.define_class, name_atom, if (class_has_extends) 1 else 0);
            if (class_name_local_idx) |local_idx| try emitClassLocalInitFromClassStack(s, local_idx);
            try s.appendMovedCodeWithAtoms(saved_runtime_code, saved_runtime_atoms, class_emit_start);
            try emitClassDeclLocalInitFromClassStack(s, class_local_idx, fields_idx, parsed_class_fields_init_child_index);
            if (class_name_local_idx) |local_idx| try s.emitCloseLoc(local_idx);
            try s.emitOp(opcode.op.drop);
            if (s.namespace_export) {
                if (s.current_namespace_atom) |ns_atom| {
                    if (class_name) |class_atom| {
                        try s.emitScopeGetVar(ns_atom);
                        try s.emitScopeGetVar(class_atom);
                        try s.emitOpAtom(opcode.op.put_field, class_atom);
                    }
                }
            }
            return;
        }
        if (!class_has_extends) try s.emitOp(opcode.op.undefined);
        if (class_fields_init_local_idx) |fields_idx| try s.emitOpU16(opcode.op.set_loc_uninitialized, fields_idx);
        try emitClassDefineOperands(s, class_constructor_cpool_idx);
        try s.emitOpAtomU8(opcode.op.define_class, name_atom, if (class_has_extends) 1 else 0);
        if (class_name_local_idx) |local_idx| try emitClassLocalInitFromClassStack(s, local_idx);
        try s.appendMovedCodeWithAtoms(saved_runtime_code, saved_runtime_atoms, class_emit_start);
        if (class_decl_local_idx) |local_idx| {
            const fields_idx = class_fields_init_local_idx orelse return Error.UnexpectedToken;
            try emitClassDeclLocalInitFromClassStack(s, local_idx, fields_idx, parsed_class_fields_init_child_index);
        }
        if (class_name_local_idx) |local_idx| try s.emitCloseLoc(local_idx);
        if (top_level_class_ref_idx) |class_ref_idx| {
            try s.emitPutVarRef(@intCast(class_ref_idx));
        } else {
            try s.emitOp(opcode.op.drop);
        }
        if (s.namespace_export) {
            if (s.current_namespace_atom) |ns_atom| {
                if (class_name) |class_atom| {
                    try s.emitScopeGetVar(ns_atom);
                    try s.emitScopeGetVar(class_atom);
                    try s.emitOpAtom(opcode.op.put_field, class_atom);
                }
            }
        }
    } else {
        const expr_name_atom = class_name orelse s.pending_function_name orelse atom_module.ids.empty_string;
        if (!class_has_extends) try s.emitOp(opcode.op.undefined);
        if (class_fields_init_local_idx) |fields_idx| try s.emitOpU16(opcode.op.set_loc_uninitialized, fields_idx);
        try emitClassDefineOperands(s, class_constructor_cpool_idx);
        try s.emitOpAtomU8(opcode.op.define_class, expr_name_atom, if (class_has_extends) 1 else 0);
        if (class_fields_init_local_idx) |fields_idx| try emitClassFieldsInitLocalInitFromClassStack(s, fields_idx, parsed_class_fields_init_child_index);
        if (class_name_local_idx) |local_idx| try emitClassLocalInitFromClassStack(s, local_idx);
        try s.appendMovedCodeWithAtoms(saved_runtime_code, saved_runtime_atoms, class_emit_start);
        try s.emitOp(opcode.op.drop);
        s.last_anonymous_function_expr = class_name == null and s.pending_function_name == null and !class_static_name_seen;
    }
}

fn appendDefaultClassConstructor(s: *ParseState, name_atom: Atom) Error!u16 {
    const parent_fd = s.cur_func();
    const child_fd = try s.function.memory.create(function_def_mod.FunctionDef);
    child_fd.* = function_def_mod.FunctionDef.init(s.function.memory, s.function.atoms, name_atom);
    var child_moved = false;
    errdefer if (!child_moved) s.discardFunctionDef(child_fd);
    child_fd.atoms.replace(&child_fd.filename, parent_fd.filename);
    child_fd.line_num = @intCast(s.token.line_num);
    child_fd.col_num = @intCast(s.token.col_num);
    child_fd.parent = parent_fd;
    child_fd.parent_scope_level = parent_fd.scope_level;
    child_fd.is_strict_mode = true;
    child_fd.is_indirect_eval = parent_fd.is_indirect_eval;
    child_fd.use_short_opcodes = parent_fd.use_short_opcodes;
    child_fd.func_type = if (s.class_has_extends) .derived_class_constructor else .class_constructor;
    child_fd.func_kind = .normal;
    child_fd.has_prototype = true;
    child_fd.is_derived_class_constructor = s.class_has_extends;
    child_fd.new_target_allowed = true;
    child_fd.super_allowed = true;
    child_fd.super_call_allowed = s.class_has_extends;
    _ = child_fd.appendScope(-1) catch return error.OutOfMemory;
    child_fd.this_var_idx = @intCast(try child_fd.addScopeVar(8, .normal, 0, s.class_has_extends, false));
    if (s.class_has_extends) {
        child_fd.vars[@intCast(child_fd.this_var_idx)].tdz_emitted_at_decl = true;
    }
    const fields_init_var_idx = parent_fd.findVar(atom_class_fields_init);
    if (fields_init_var_idx < 0) return Error.UnexpectedToken;
    _ = try child_fd.addClosureVar(.{
        .closure_type = .local,
        .is_lexical = true,
        .is_const = true,
        .var_kind = .normal,
        .var_idx = @intCast(fields_init_var_idx),
        .var_name = atom_class_fields_init,
    });
    if (s.class_has_extends) {
        try child_fd.appendByteCode(&.{
            opcode.op.init_ctor,
            opcode.op.put_loc_check_init,
            0,
            0,
            opcode.op.get_var_ref_check,
            0,
            0,
            opcode.op.dup,
            opcode.op.if_false8,
            8,
            opcode.op.get_loc_check,
            0,
            0,
            opcode.op.swap,
            opcode.op.call_method,
            0,
            0,
            opcode.op.drop,
            opcode.op.get_loc_check,
            0,
            0,
            opcode.op.@"return",
        });
    } else {
        try child_fd.appendByteCode(&.{opcode.op.return_undef});
    }
    for (s.class_private_bound_names.items) |atom_id| {
        try child_fd.appendPrivateBoundName(atom_id);
    }
    const cpool_idx: u16 = @intCast(try parent_fd.appendCpool(JSValue.undefinedValue()));
    child_fd.parent_cpool_idx = cpool_idx;
    try parent_fd.addChild(child_fd.*);
    child_moved = true;
    s.function.memory.destroy(function_def_mod.FunctionDef, child_fd);
    return cpool_idx;
}

// =====================================================================
// Module parsing
// =====================================================================

const atom_default: Atom = 22; // "default"
const atom_star_default: Atom = 127; // "*default*"
const atom_star: Atom = 128; // "*"

const ModuleImportSpec = struct {
    import_name: Atom,
    local_name: Atom,
};

const ModuleExportSpec = struct {
    export_name: Atom,
    import_name: Atom,
    import_name_is_string: bool = false,
};

/// Parse import statement
/// Mirrors `js_parse_import` in quickjs.c:31312
fn parseImport(s: *ParseState) Error!void {
    try s.advance();
    var default_local_name: ?Atom = null;

    // Side-effect import: import 'module'
    if (s.peekKind() == tok.TOK_STRING) {
        const request_index = try addModuleRequestFromCurrentString(s);
        try s.advance();
        if (s.peekKind() == tok.TOK_WITH) {
            try parseWithClause(s, request_index);
        }
        _ = try s.expectSemicolon();
        return;
    }

    // Default import: import x from 'module'
    if (s.peekKind() == tok.TOK_IDENT) {
        const local_name = s.token.payload.ident.atom;
        try validateModuleImportBindingName(s, local_name);
        default_local_name = local_name;
        try s.advance();

        if (s.peekKind() != ',') {
            const request_index = try parseFromClause(s);
            try addModuleImport(s, request_index, atom_default, local_name);
            try addModuleImportBinding(s, local_name);
            // parseFromClause handles with clause, so expect semicolon after
            _ = try s.expectSemicolon();
            return;
        }
        try s.advance();
    }

    // Namespace import: import * as ns from 'module'
    if (s.peekKind() == '*') {
        try s.advance();
        // Expect 'as'
        if (!s.isIdent("as")) {
            return Error.UnexpectedToken;
        }
        try s.advance();
        // Expect namespace identifier
        if (s.peekKind() != tok.TOK_IDENT) {
            return Error.UnexpectedToken;
        }
        const local_name = s.token.payload.ident.atom;
        try validateModuleImportBindingName(s, local_name);
        try s.advance();
        const request_index = try parseFromClause(s);
        if (default_local_name) |default_name| try addModuleImport(s, request_index, atom_default, default_name);
        try addModuleImport(s, request_index, atom_star, local_name);
        if (default_local_name) |default_name| try addModuleImportBinding(s, default_name);
        try addModuleImportBinding(s, local_name);
        _ = try s.expectSemicolon();
        return;
    }

    // Named imports: import { x, y as z } from 'module'
    if (s.peekKind() == '{') {
        var imports = std.ArrayList(ModuleImportSpec).empty;
        defer freeModuleImportSpecs(s, &imports);
        try s.advance();
        while (s.peekKind() != '}' and s.peekKind() != tok.TOK_EOF) {
            // Import name (identifier or string)
            if (!isModuleNameToken(s.peekKind())) {
                return Error.UnexpectedToken;
            }
            const import_name_was_string = s.peekKind() == tok.TOK_STRING;
            const import_name_atom = try moduleImportNameAtom(s);
            const import_name_owned = s.function.atoms.dup(import_name_atom);
            if (import_name_was_string) s.function.atoms.free(import_name_atom);
            try s.advance();

            // Optional 'as' for renaming
            var local_name_atom: Atom = undefined;
            if (s.isIdent("as")) {
                try s.advance();
                if (s.peekKind() != tok.TOK_IDENT) {
                    s.function.atoms.free(import_name_owned);
                    return Error.UnexpectedToken;
                }
                local_name_atom = s.token.payload.ident.atom;
                try validateModuleImportBindingName(s, local_name_atom);
                try s.advance();
            } else if (import_name_was_string) {
                s.function.atoms.free(import_name_owned);
                return Error.UnexpectedToken;
            } else {
                local_name_atom = import_name_atom;
                try validateModuleImportBindingName(s, local_name_atom);
            }

            imports.append(s.function.memory.allocator, .{
                .import_name = import_name_owned,
                .local_name = s.function.atoms.dup(local_name_atom),
            }) catch {
                s.function.atoms.free(import_name_owned);
                return Error.OutOfMemory;
            };

            if (s.peekKind() != ',') break;
            try s.advance();
        }
        try s.expectToken('}');
        const request_index = try parseFromClause(s);
        if (default_local_name) |default_name| try addModuleImport(s, request_index, atom_default, default_name);
        for (imports.items) |entry| {
            try addModuleImport(s, request_index, entry.import_name, entry.local_name);
        }
        if (default_local_name) |default_name| try addModuleImportBinding(s, default_name);
        for (imports.items) |entry| {
            try addModuleImportBinding(s, entry.local_name);
        }
        _ = try s.expectSemicolon();
        return;
    }

    return Error.UnexpectedToken;
}

fn validateModuleImportBindingName(s: *ParseState, atom_id: Atom) Error!void {
    if (isInvalidStrictFunctionBindingName(s, atom_id)) {
        return Error.UnexpectedToken;
    }
}

fn moduleHasExportName(record: *const bytecode_module.Record, export_name: Atom) bool {
    for (record.exports) |entry| {
        if (entry.export_name == export_name) return true;
    }
    for (record.indirect_exports) |entry| {
        if (entry.export_name == export_name) return true;
    }
    for (record.star_exports) |entry| {
        if (entry.export_name != atom_star and entry.export_name == export_name) return true;
    }
    return false;
}

fn addModuleExportName(s: *ParseState, export_name: Atom, local_name: Atom) Error!void {
    const record = s.function.ensureModule();
    if (moduleHasExportName(record, export_name)) return Error.UnexpectedToken;
    record.addExport(export_name, local_name) catch return error.OutOfMemory;
}

pub fn validateModuleLocalExports(s: *ParseState) Error!void {
    const record = s.function.module_record orelse return;
    for (record.exports) |entry| {
        if (!hasKnownBinding(s, entry.local_name)) return Error.UnexpectedToken;
    }
}

fn addModuleImport(s: *ParseState, request_index: u32, import_name: Atom, local_name: Atom) Error!void {
    const record = s.function.ensureModule();
    record.addImport(request_index, import_name, local_name) catch return error.OutOfMemory;
}

fn addModuleImportAttribute(s: *ParseState, request_index: u32, key: Atom, value: Atom) Error!void {
    const record = s.function.ensureModule();
    for (record.import_attributes) |entry| {
        if (entry.request_index == request_index and entry.key == key) return Error.UnexpectedToken;
    }
    record.addImportAttribute(request_index, key, value) catch return error.OutOfMemory;
}

fn addModuleImportBinding(s: *ParseState, local_name: Atom) Error!void {
    if (hasKnownBinding(s, local_name)) return Error.UnexpectedToken;
    const ref_idx: u16 = @intCast(try s.cur_func().addClosureVar(.{
        .closure_type = .module_import,
        .is_lexical = true,
        .is_const = true,
        .var_kind = .normal,
        .var_idx = @intCast(s.cur_func().closure_var.len),
        .var_name = local_name,
    }));
    try s.retrofitForwardTopLevelModuleCapture(s.cur_func(), local_name, ref_idx, true, true, .normal);
}

fn ensureModuleDefaultExportBinding(s: *ParseState) Error!u16 {
    if (ParseState.findClosureVarIndex(s.cur_func(), atom_star_default)) |idx| return idx;
    return @intCast(try s.cur_func().addClosureVar(.{
        .closure_type = .module_decl,
        .is_lexical = true,
        .is_const = true,
        .var_kind = .normal,
        .var_idx = @intCast(s.cur_func().closure_var.len),
        .var_name = atom_star_default,
    }));
}

fn hoistLastAnonymousDefaultFunctionExport(s: *ParseState, default_ref_idx: u16) Error!void {
    const child_idx = s.last_function_child_index orelse return Error.UnexpectedToken;
    if (child_idx >= s.cur_func().child_list.len) return Error.UnexpectedToken;
    const child = &s.cur_func().child_list[child_idx];
    s.function.atoms.replace(&child.func_name, atom_default);
    child.emit_top_level_closure_init = true;
    child.top_level_closure_var_idx = default_ref_idx;
}

fn addModuleIndirectExport(s: *ParseState, request_index: u32, export_name: Atom, import_name: Atom) Error!void {
    const record = s.function.ensureModule();
    if (moduleHasExportName(record, export_name)) return Error.UnexpectedToken;
    record.addIndirectExport(request_index, export_name, import_name) catch return error.OutOfMemory;
}

fn addModuleStarExport(s: *ParseState, request_index: u32, export_name: Atom) Error!void {
    const record = s.function.ensureModule();
    if (export_name != atom_star and moduleHasExportName(record, export_name)) return Error.UnexpectedToken;
    record.addStarExport(request_index, export_name) catch return error.OutOfMemory;
}

fn addModuleRequestFromCurrentString(s: *ParseState) Error!u32 {
    const module_name = try moduleStringAtom(s);
    defer s.function.atoms.free(module_name);
    const record = s.function.ensureModule();
    return record.addRequest(module_name) catch return error.OutOfMemory;
}

fn moduleStringAtom(s: *ParseState) Error!Atom {
    if (s.peekKind() != tok.TOK_STRING) return Error.UnexpectedToken;
    return s.function.atoms.internString(s.token.payload.str.bytes) catch return error.OutOfMemory;
}

fn isModuleNameToken(kind: tok.TokenKind) bool {
    return kind == tok.TOK_IDENT or kind == tok.TOK_STRING or tok.isKeyword(kind);
}

fn moduleImportNameAtom(s: *ParseState) Error!Atom {
    return switch (s.peekKind()) {
        tok.TOK_IDENT => s.token.payload.ident.atom,
        tok.TOK_NULL...tok.TOK_AWAIT => tok.keywordAtom(s.peekKind()),
        else => try moduleStringAtom(s),
    };
}

fn isWellFormedModuleString(bytes: []const u8) bool {
    var index: usize = 0;
    while (index < bytes.len) {
        const width = std.unicode.utf8ByteSequenceLength(bytes[index]) catch return false;
        if (index + width > bytes.len) return false;
        if (width == 3 and bytes[index] == 0xED and bytes[index + 1] >= 0xA0 and bytes[index + 1] <= 0xBF) {
            if (bytes[index + 2] & 0xC0 == 0x80) return false;
        }
        _ = std.unicode.utf8Decode(bytes[index .. index + width]) catch |err| switch (err) {
            error.Utf8EncodesSurrogateHalf => return false,
            else => return false,
        };
        index += width;
    }
    return true;
}

fn freeModuleImportSpecs(s: *ParseState, imports: *std.ArrayList(ModuleImportSpec)) void {
    for (imports.items) |entry| {
        s.function.atoms.free(entry.import_name);
        s.function.atoms.free(entry.local_name);
    }
    imports.deinit(s.function.memory.allocator);
}

fn freeModuleExportSpecs(s: *ParseState, exports: *std.ArrayList(ModuleExportSpec)) void {
    for (exports.items) |entry| {
        s.function.atoms.free(entry.export_name);
        s.function.atoms.free(entry.import_name);
    }
    exports.deinit(s.function.memory.allocator);
}

/// Parse export statement
/// Mirrors `js_parse_export` in quickjs.c:31090
fn parseExport(s: *ParseState) Error!void {
    try s.advance();

    const next_tok = s.peekKind();

    // export default
    if (next_tok == tok.TOK_DEFAULT) {
        try s.advance();
        if (s.peekKind() == tok.TOK_CLASS) {
            try addModuleExportName(s, atom_default, atom_star_default);
            _ = try ensureModuleDefaultExportBinding(s);
            const saved_pending_name = s.pending_function_name;
            const saved_pending_decl = s.pending_function_is_decl;
            s.pending_function_name = atom_default;
            s.pending_function_is_decl = false;
            defer {
                s.pending_function_name = saved_pending_name;
                s.pending_function_is_decl = saved_pending_decl;
            }
            try parseClass(s, false);
            try s.emitScopePutVarInit(atom_star_default);
            return;
        } else if (s.peekKind() == tok.TOK_FUNCTION) {
            if (exportDefaultFunctionName(s)) |name_atom| {
                try addModuleExportName(s, atom_default, name_atom);
                if (hasKnownBinding(s, name_atom)) return Error.UnexpectedToken;
                const source_start = s.currentTokenStartOffset();
                try parseFunctionDecl(s, .normal, source_start);
            } else {
                try addModuleExportName(s, atom_default, atom_star_default);
                const default_ref_idx = try ensureModuleDefaultExportBinding(s);
                const source_start = s.currentTokenStartOffset();
                try parseFunctionExpr(s, .normal, source_start);
                try hoistLastAnonymousDefaultFunctionExport(s, default_ref_idx);
                try s.emitOp(opcode.op.drop);
            }
            return;
        } else if (s.peekKind() == tok.TOK_IDENT and s.isIdent("async") and s.peekNextKind() == tok.TOK_FUNCTION) {
            const source_start = s.currentTokenStartOffset();
            try s.advance();
            if (exportDefaultFunctionName(s)) |name_atom| {
                try addModuleExportName(s, atom_default, name_atom);
                if (hasKnownBinding(s, name_atom)) return Error.UnexpectedToken;
                try parseFunctionDecl(s, .async, source_start);
            } else {
                try addModuleExportName(s, atom_default, atom_star_default);
                const default_ref_idx = try ensureModuleDefaultExportBinding(s);
                try parseFunctionExpr(s, .async, source_start);
                try hoistLastAnonymousDefaultFunctionExport(s, default_ref_idx);
                try s.emitOp(opcode.op.drop);
            }
            return;
        } else {
            try addModuleExportName(s, atom_default, atom_star_default);
            _ = try ensureModuleDefaultExportBinding(s);
            try parseAssignExpr(s);
            try emitAnonymousDefaultName(s, atom_default);
            try s.emitScopePutVarInit(atom_star_default);
        }
        _ = try s.expectSemicolon();
        return;
    }

    // export { ... }
    if (next_tok == '{') {
        var export_specs = std.ArrayList(ModuleExportSpec).empty;
        defer freeModuleExportSpecs(s, &export_specs);
        try s.advance();
        while (s.peekKind() != '}' and s.peekKind() != tok.TOK_EOF) {
            // Export name (identifier or string)
            if (!isModuleNameToken(s.peekKind())) {
                return Error.UnexpectedToken;
            }
            const local_name_atom = try moduleImportNameAtom(s);
            const local_name_was_string = s.peekKind() == tok.TOK_STRING;
            if (local_name_was_string and !isWellFormedModuleString(s.token.payload.str.bytes)) {
                s.function.atoms.free(local_name_atom);
                return Error.UnexpectedToken;
            }
            var export_name_atom = local_name_atom;
            var export_name_was_string = local_name_was_string;
            try s.advance();

            // Optional 'as' for renaming
            if (s.isIdent("as")) {
                try s.advance();
                if (!isModuleNameToken(s.peekKind())) {
                    if (local_name_was_string) s.function.atoms.free(local_name_atom);
                    return Error.UnexpectedToken;
                }
                export_name_was_string = s.peekKind() == tok.TOK_STRING;
                if (export_name_was_string and !isWellFormedModuleString(s.token.payload.str.bytes)) {
                    if (local_name_was_string) s.function.atoms.free(local_name_atom);
                    return Error.UnexpectedToken;
                }
                export_name_atom = try moduleImportNameAtom(s);
                try s.advance();
            }

            export_specs.append(s.function.memory.allocator, .{
                .export_name = s.function.atoms.dup(export_name_atom),
                .import_name = s.function.atoms.dup(local_name_atom),
                .import_name_is_string = local_name_was_string,
            }) catch {
                if (local_name_was_string) s.function.atoms.free(local_name_atom);
                if (export_name_was_string and export_name_atom != local_name_atom) s.function.atoms.free(export_name_atom);
                return Error.OutOfMemory;
            };
            if (local_name_was_string) s.function.atoms.free(local_name_atom);
            if (export_name_was_string and export_name_atom != local_name_atom) s.function.atoms.free(export_name_atom);

            if (s.peekKind() != ',') break;
            try s.advance();
        }
        try s.expectToken('}');

        // Optional from clause for re-export
        if (s.isIdent("from")) {
            const request_index = try parseFromClause(s);
            for (export_specs.items) |entry| {
                try addModuleIndirectExport(s, request_index, entry.export_name, entry.import_name);
            }
        } else {
            for (export_specs.items) |entry| {
                if (entry.import_name_is_string) return Error.UnexpectedToken;
                try addModuleExportName(s, entry.export_name, entry.import_name);
            }
        }
        _ = try s.expectSemicolon();
        return;
    }

    // export * from 'module' or export * as ns from 'module'
    if (next_tok == '*') {
        try s.advance();
        // Optional 'as' for namespace re-export
        var export_name = atom_star;
        var export_name_was_string = false;
        if (s.isIdent("as")) {
            try s.advance();
            if (!isModuleNameToken(s.peekKind())) {
                return Error.UnexpectedToken;
            }
            export_name_was_string = s.peekKind() == tok.TOK_STRING;
            if (export_name_was_string and !isWellFormedModuleString(s.token.payload.str.bytes)) return Error.UnexpectedToken;
            export_name = try moduleImportNameAtom(s);
            try s.advance();
        }
        defer if (export_name_was_string) s.function.atoms.free(export_name);
        const request_index = try parseFromClause(s);
        try addModuleStarExport(s, request_index, export_name);
        _ = try s.expectSemicolon();
        return;
    }

    // export var/let/const
    if (next_tok == tok.TOK_VAR or next_tok == tok.TOK_LET or next_tok == tok.TOK_CONST) {
        const var_tok = next_tok;
        try s.advance();
        try parseVar(s, var_tok, true, ParseFlags.default);
        _ = try s.expectSemicolon();
        return;
    }

    // export function
    if (next_tok == tok.TOK_FUNCTION) {
        // Check for async function
        const is_async = s.isIdent("async");
        const source_start = s.currentTokenStartOffset();
        if (is_async) {
            try s.advance();
        }
        const func_kind: ParseFunctionKind = if (is_async) .async else .normal;
        if (exportDefaultFunctionName(s)) |name_atom| {
            try addModuleExportName(s, name_atom, name_atom);
        }
        try parseFunctionDecl(s, func_kind, source_start);
        return;
    }

    // export class
    if (next_tok == tok.TOK_CLASS) {
        try parseClass(s, true);
        if (s.last_class_decl_atom) |name_atom| try addModuleExportName(s, name_atom, name_atom);
        return;
    }

    // export async function
    if (next_tok == tok.TOK_IDENT and s.isIdent("async")) {
        // Check if next token is function
        if (s.peekNextKind() == tok.TOK_FUNCTION) {
            const source_start = s.currentTokenStartOffset();
            try s.advance(); // consume async
            const func_kind: ParseFunctionKind = .async;
            if (exportDefaultFunctionName(s)) |name_atom| {
                try addModuleExportName(s, name_atom, name_atom);
            }
            try parseFunctionDecl(s, func_kind, source_start);
            return;
        }
    }

    return Error.UnexpectedToken;
}

fn exportDefaultFunctionName(s: *ParseState) ?Atom {
    const saved_pos = s.lex.pos;
    const saved_line = s.lex.line;
    const saved_col = s.lex.col;
    const saved_mark_pos = s.lex.mark_pos;
    const saved_mark_line = s.lex.mark_line;
    const saved_mark_col = s.lex.mark_col;
    var first = s.lex.next() catch return null;
    defer {
        s.lex.freeToken(&first);
        s.lex.pos = saved_pos;
        s.lex.line = saved_line;
        s.lex.col = saved_col;
        s.lex.mark_pos = saved_mark_pos;
        s.lex.mark_line = saved_mark_line;
        s.lex.mark_col = saved_mark_col;
    }
    if (first.val == @as(tok.TokenKind, @intCast('*'))) {
        var second = s.lex.next() catch return null;
        defer s.lex.freeToken(&second);
        if (second.val == tok.TOK_IDENT) return second.payload.ident.atom;
        return null;
    }
    if (first.val == tok.TOK_IDENT) return first.payload.ident.atom;
    return null;
}

/// Parse from clause: from 'module'
/// Mirrors `js_parse_from_clause` in quickjs.c:31039
fn parseFromClause(s: *ParseState) Error!u32 {
    // Expect 'from' keyword
    if (!s.isIdent("from")) {
        return Error.UnexpectedToken;
    }
    try s.advance();

    // Expect string literal for module name
    if (s.peekKind() != tok.TOK_STRING) {
        return Error.UnexpectedToken;
    }
    const request_index = try addModuleRequestFromCurrentString(s);
    try s.advance();

    // Optional with clause for import attributes
    if (s.peekKind() == tok.TOK_WITH) {
        try parseWithClause(s, request_index);
    }
    return request_index;
}

/// Parse with clause for import attributes
/// Mirrors `js_parse_with_clause` in quickjs.c:30950
fn parseWithClause(s: *ParseState, request_index: u32) Error!void {
    try s.advance();
    try s.expectToken('{');

    while (s.peekKind() != '}' and s.peekKind() != tok.TOK_EOF) {
        // Key (identifier or string)
        if (s.peekKind() != tok.TOK_IDENT and s.peekKind() != tok.TOK_STRING) {
            return Error.UnexpectedToken;
        }
        const key_atom = if (s.peekKind() == tok.TOK_IDENT)
            s.token.payload.ident.atom
        else
            try moduleStringAtom(s);
        const key_is_string = s.peekKind() == tok.TOK_STRING;
        defer if (key_is_string) s.function.atoms.free(key_atom);
        try s.advance();

        try s.expectToken(':');

        // JSValue (string)
        if (s.peekKind() != tok.TOK_STRING) {
            return Error.UnexpectedToken;
        }
        const value_atom = try moduleStringAtom(s);
        defer s.function.atoms.free(value_atom);
        try addModuleImportAttribute(s, request_index, key_atom, value_atom);
        try s.advance();

        if (s.peekKind() != ',') break;
        try s.advance();
    }

    try s.expectToken('}');
}

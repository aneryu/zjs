//! Parser state: the `State` record with its token, scope, and emission methods, plus the types every parser module shares.

const root = @import("../parser.zig");
const lexer = root.lexer;
const token = root.token;
const diagnostics = root.diagnostics;
const identifiers = @import("identifiers.zig");
const lookahead = @import("lookahead.zig");
const emitter = @import("emitter.zig");
const expressions = @import("expressions.zig");
const statements = @import("statements.zig");
const functions = @import("functions.zig");
const classes = @import("classes.zig");
const modules = @import("modules.zig");
const typescript = @import("typescript.zig");
const Emitter = emitter.Emitter;
const declarations = @import("declarations.zig");
const closure = @import("closure.zig");

pub const std = @import("std");

pub const bytecode = @import("../bytecode.zig");

pub const atom_module = @import("../core/atom.zig");

pub const core_bigint = @import("../core/bigint.zig");

pub const core = @import("../core/root.zig");

pub const regexp_lib = @import("../libs/regexp.zig");

pub const libs_bignum = @import("../libs/bigint.zig");

pub const simple_token = @import("../simple_token.zig");

pub const unicode = @import("../libs/unicode.zig");

pub const array_list_erased = @import("../core/array_list_erased.zig");

pub const JSValue = @import("../core/value.zig").JSValue;

pub const compiler = @import("../compiler/root.zig");

pub const bytecode_function = bytecode;

pub const function_def_mod = bytecode.function_def;

pub const bytecode_module = bytecode.module;

pub const opcode = bytecode.opcode;

pub const lexer_mod = root.lexer;

pub const tok = root.token;

pub const Atom = atom_module.Atom;

pub const atom_this: Atom = atom_module.ids.this_;

pub const atom_new_target: Atom = atom_module.ids.new_target;

pub const atom_this_active_func: Atom = atom_module.ids.this_active_func;

pub const atom_home_object: Atom = atom_module.ids.home_object;

pub const atom_class_fields_init: Atom = atom_module.ids.class_fields_init;

pub const shared_iterator_close_marker: u8 = 255;

pub const direct_iterator_close_marker: u8 = 254;

pub const SourcePosition = struct {
    line_num: u32,
    col_num: u32,
};

pub const FunctionSourceStart = struct {
    offset: usize,
    line_num: u32,
    col_num: u32,
};

pub const DeclarationConflictIndexRegistry = declarations.DeclarationConflictIndexRegistry;

pub const Error = lexer_mod.Error || error{
    UnexpectedToken,
    InvalidLhs,
    InvalidNumberLiteral,
    InvalidIdentifier,
    InvalidAssignmentTarget,
    YieldOutsideGenerator,
    AwaitOutsideAsyncFunction,
    SyntaxError,
    BytecodeOverflow,
    /// Builder fail-closed invariants (double bind, foreign label). Like
    /// `ParserInvariant`, never a source-program verdict: the compile
    /// boundary reports it as an internal compiler error.
    InvalidBytecode,
    /// Parser-owned state, builder, and lowering invariants failed. This
    /// is never a source-program verdict and is reported through Q5b's
    /// internal-compiler-error boundary.
    ParserInvariant,
    // Native recursion-descent guard (QuickJS next_token
    // `js_check_stack_overflow` -> js_parse_error "stack overflow",
    // quickjs.c). Surfaced by `compile` as a catchable SyntaxError.
    StackOverflow,
};

pub const PendingDiagnostic = struct {
    pub const message_capacity = 96;

    position: diagnostics.Position,
    err: Error,
    message_buffer: [message_capacity]u8 = undefined,
    message_len: u8 = 0,

    pub fn message(self: *const PendingDiagnostic) []const u8 {
        return self.message_buffer[0..self.message_len];
    }
};

/// Parse flags mirror the QuickJS `PF_*` macros.
pub const ParseFlags = packed struct(u32) {
    in_accepted: bool = false,
    pow_allowed: bool = false,
    result_needed: bool = true,
    yield_forbidden: bool = false,
    /// TypeScript: in the whenTrue branch of `?:` an arrow head may not
    /// carry a return type, so `c ? (x) : y => z` stays a conditional
    /// (tsc `allowReturnTypeInArrowFunction`).
    arrow_return_type_forbidden: bool = false,
    _padding: u27 = 0,

    pub const default = ParseFlags{ .in_accepted = true };
};

/// Mirror `quickjs.c` — BlockEnv for break/continue/finally tracking.
pub const BlockEnv = struct {
    prev: ?*BlockEnv,
    /// Label of a labelled statement, loop or switch; null for the
    /// iterator and shared-finally cleanup entries.
    label_name: ?Atom,
    has_break_target: bool,
    has_continue_target: bool,
    /// Stack values a `break` out of this frame must drop.
    drop_count: i32,
    /// Scope level at the push; a jump out of the block closes scopes
    /// down to it.
    scope_level: i32,
    /// `active_catch_marker_depth` when the block was pushed; return
    /// cleanup unwinds catch markers down to it.
    catch_marker_depth: u32,
    has_iterator: bool,
    is_regular_stmt: bool,
};

pub const LabelFrame = struct {
    atom: Atom,
    allow_continue: bool,
    catch_marker_depth: u32,
    control_frame_depth: usize,
    break_frame_depth: usize,
    break_fixups: std.ArrayList(usize) = .empty,
    continue_fixups: std.ArrayList(usize) = .empty,
    /// Break/continue labels are parser-native LabelIds (qjs identities).
    break_label: ?compiler.LabelId = null,
    continue_label: ?compiler.LabelId = null,

    pub fn deinit(self: *LabelFrame, allocator: std.mem.Allocator) void {
        self.break_fixups.deinit(allocator);
        self.continue_fixups.deinit(allocator);
    }
};

pub const ControlFrames = struct {
    top_break: ?*BlockEnv,
    break_fixups: std.ArrayList(usize),
    break_frame_lens: std.ArrayList(usize),
    break_frame_labels: std.ArrayList(compiler.LabelId),
    break_frame_catch_marker_depths: std.ArrayList(u32),
    break_frame_cleanup_drops: std.ArrayList(u8),
    break_frame_cross_cleanup_drops: std.ArrayList(u8),
    continue_fixups: std.ArrayList(usize),
    continue_frame_lens: std.ArrayList(usize),
    continue_frame_labels: std.ArrayList(compiler.LabelId),
    continue_frame_break_frame_indices: std.ArrayList(usize),
    continue_frame_catch_marker_depths: std.ArrayList(u32),
    continue_frame_cleanup_drops: std.ArrayList(u8),
    label_frames: std.ArrayList(LabelFrame),
    pending_label_atom: ?Atom,
    active_catch_marker_depth: u32,
    using_block_frames: std.ArrayList(UsingBlockFrame),
    /// Set by `leaveControlBoundary`; a second leave is a no-op.
    left: bool = false,
};

pub const ReturnFinallyFrame = struct {
    finally_label: FinallyLabel,
    scope_level: i32,
    catch_marker_depth: u32,
    break_depth: usize,
    continue_depth: usize,
    label_depth: usize,
    block_boundary: ?*BlockEnv,
};

pub const UsingBlockFrame = struct {
    stack_loc: ?u16 = null,
    catch_label: ?compiler.LabelId = null,
    catch_marker_depth: u32 = 0,
    seen_async_hint: bool = false,
};

pub const ClassPrivateElementKind = enum {
    field,
    method,
    getter,
    setter,
};

pub const ClassPrivateElement = struct {
    atom: Atom,
    kind: ClassPrivateElementKind,
    is_static: bool,
};

pub const ReturnFinallyBoundary = struct {
    frames: std.ArrayList(ReturnFinallyFrame),
    finally_body_control_frames: std.ArrayList(FinallyBodyControlFrame),
};

/// Minimal adapter for abrupt control emitted while parsing a shared
/// finalizer body. The finalizer's own ReturnFinallyFrame is already
/// popped, so crossing this boundary must discard its
/// `[completion, gosub_pc]` pair exactly once.
pub const FinallyBodyControlFrame = struct {
    block: *BlockEnv,
    catch_marker_depth: u32,
    break_depth: usize,
    continue_depth: usize,
    label_depth: usize,
};

pub const FinallyControlKind = enum {
    @"break",
    @"continue",
};

pub const FinallyControlTarget = struct {
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

    /// `function*` / `async function*`: fold the star into the kind.
    pub fn withGenerator(kind: ParseFunctionKind, is_generator: bool) ParseFunctionKind {
        if (!is_generator) return kind;
        return if (kind == .async) .async_generator else .generator;
    }

    pub fn isAsync(kind: ParseFunctionKind) bool {
        return kind == .async or kind == .async_generator;
    }

    pub fn isGenerator(kind: ParseFunctionKind) bool {
        return kind == .generator or kind == .async_generator;
    }

    pub fn isConstructor(kind: ParseFunctionKind) bool {
        return kind == .class_constructor or kind == .derived_class_constructor;
    }

    /// Spelled with the `function` keyword: declarations, expressions and
    /// object-literal methods, as opposed to class elements, accessors,
    /// arrows and static blocks.
    pub fn isFunctionKeywordForm(kind: ParseFunctionKind) bool {
        return switch (kind) {
            .normal, .async, .generator, .async_generator => true,
            else => false,
        };
    }

    /// Class elements and accessors carry a home object for `super.x`.
    pub fn hasHomeObject(kind: ParseFunctionKind) bool {
        return switch (kind) {
            .method, .get, .set, .class_constructor, .derived_class_constructor => true,
            else => false,
        };
    }

    /// Only ordinary, generator and constructor functions get a
    /// `prototype` property.
    pub fn hasPrototype(kind: ParseFunctionKind) bool {
        return switch (kind) {
            .arrow, .async, .method, .get, .set, .class_static_block => false,
            else => true,
        };
    }

    /// The runtime `JSFunctionKindEnum` of the child bytecode.
    pub fn bytecodeKind(kind: ParseFunctionKind) bytecode.function_bytecode.FunctionKind {
        return switch (kind) {
            .async => .async,
            .generator => .generator,
            .async_generator => .async_generator,
            else => .normal,
        };
    }
};

pub const FeatureImpl = enum {
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

/// Ephemeral handle for QuickJS's trailing OP_set_class_name marker.
/// The marker stores the byte-distance back to define_class; this handle
/// additionally records the compact atom-ledger row captured at emission
/// so an inferred-name patch can update code and ownership in lockstep
/// without a per-instruction side table.
pub const ClassNamePatch = struct {
    builder: *compiler.Builder,
    define_class_pos: u32,
    atom_index: u32,
    marker_pos: u32,
};

/// `JSParseState` analogue for expression, statement, function, and class parsing.
/// Grammar context of the function whose parameters or body are being
/// parsed. `parseFunctionParamsAndBody` and `parseArrowFunction` save the
/// whole value, derive the child's from its kind and restore the whole
/// value on exit; class field initializers and static blocks do the same
/// through `FieldInitContext`.
pub const FunctionContext = struct {
    in_generator: bool = false,
    in_async: bool = false,
    /// Inside a class constructor.
    in_constructor: bool = false,
    /// The outermost constructor block has not been entered yet; TypeScript
    /// parameter properties are lowered at its start.
    is_outer_constructor_block: bool = false,
    /// `super.x` is syntactically allowed.
    allow_super: bool = false,
    /// `super(...)` is syntactically allowed.
    allow_super_call: bool = false,
    /// `new.target` is syntactically allowed. Direct eval roots inherit it
    /// from the caller; indirect eval and script roots keep it false.
    new_target_allowed: bool = false,
    /// Inside a class static initialization block.
    in_class_static_block: bool = false,
    /// Inside a parameter default initializer.
    in_parameter_initializer: bool = false,
    /// Parameter default initializers must reject `await`.
    reject_await_in_parameter_initializer: bool = false,
    /// Name a named function expression binds inside its own body.
    function_expr_name_binding: ?Atom = null,
    /// TypeScript namespace body: `var` becomes `let` and `export` attaches
    /// the declaration to the namespace object.
    in_namespace: bool = false,
    namespace_export: bool = false,
    current_namespace_atom: ?Atom = null,
};

/// A lexical scope entered with `State.openScope`. `close` emits the
/// leave marker and pops it; `pop` drops the identity only, for error
/// paths and for scopes whose leave event the caller emits itself. Both
/// are no-ops once the scope is gone, so `errdefer scope.pop(s)` stays
/// armed across the explicit close.
pub const OpenScope = struct {
    open: bool = true,

    pub fn close(self: *OpenScope, s: *State) Error!void {
        std.debug.assert(self.open);
        try s.popScope();
        self.open = false;
    }

    pub fn pop(self: *OpenScope, s: *State) void {
        if (!self.open) return;
        self.open = false;
        s.popScopeIdentity();
    }
};

/// State of the innermost class whose ClassTail is being parsed.
/// `parseClass` saves the enclosing value, starts from a fresh one and
/// restores the enclosing value on both exits. The private-element and
/// private-name lists stay on `State` because nested classes stack on
/// top of them and truncate back.
pub const ClassContext = struct {
    /// Inside a class body: private names are legal.
    in_body: bool = false,
    has_extends: bool = false,
    /// Parsing a `static` element.
    is_static: bool = false,
    /// The explicit constructor's constant-pool slot once it is parsed.
    constructor_cpool_idx: ?u16 = null,
    fields_init_child_index: ?u16 = null,
    static_init_child_index: ?u16 = null,
    instance_private_brand_needed: bool = false,
    static_private_brand_needed: bool = false,
};

pub const State = struct {
    pub const ScopeVarOptions = declarations.ScopeVarOptions;
    pub const DefineVarType = declarations.DefineVarType;
    pub const DefinedVar = declarations.DefinedVar;
    lex: *lexer_mod.Lexer,
    /// Native allocator for function defs and parser-owned slices. Its
    /// context is the account, recovered only when a reserved BigInt cell
    /// must be created before a runtime exists.
    allocator: std.mem.Allocator,
    /// Facade for FunctionDef var-index maps.
    artifacts: std.mem.Allocator,
    /// Limb allocator captured from `Runtime native allocator` at init.
    persistent: std.mem.Allocator,
    /// Lists and temporary strings freed with this parse. Captured at init
    /// and overwritten by `compile` with its arena.
    scratch: std.mem.Allocator,
    atoms: *atom_module.AtomTable,
    /// Name of the parse root; the default name for a nameless declaration.
    root_name: Atom,
    /// The module record an ECMAScript module root accumulates while parsing;
    /// `takeModuleRecord` hands it to the module artifact after finalize.
    module_record: ?bytecode.module.Record = null,
    runtime: ?*core.JSRuntime = null,
    /// Owner for unpublished constants, independent of atom-table tracing.
    allocation_runtime: *core.JSRuntime,
    /// One-token lookahead. The lexer is the source of truth; we cache
    /// the most recently produced token here so the parser can `peek`.
    token: tok.Token,
    pending_diagnostic: ?PendingDiagnostic = null,
    last_token_end_offset: usize = 0,
    last_token_line_num: u32 = 1,
    last_token_col_num: u32 = 1,
    last_opcode_source_offset: ?u32 = null,
    /// Lazily-built line-start byte offsets for O(1) (line,col)->offset
    /// conversion in `emitSourcePos`. This replaces an O(n) rescan of the
    /// whole source from byte 0 on EVERY opcode source-position emit, which
    /// made a full compile O(n^2) and dominated real-world parse time
    /// (mandreel/typescript/pdfjs Octane cases timed out; code-load 43x
    /// behind qjs). `source_line_starts[k]` is the byte offset where line
    /// (k+1) begins (line 1 -> 0). Rebuilt if the lexer source changes
    /// (direct eval / sub-parse); freed in `deinit`.
    source_line_starts: []u32 = &.{},
    source_line_starts_src: []const u8 = &.{},
    /// Scoped attribution for statement opcodes emitted after their
    /// operand expression has advanced the lexer. QuickJS emits one
    /// OP_line_num at the statement keyword before lowering the complete
    /// return/throw sequence; keeping the override here gives every
    /// synthesized opcode in that sequence the same source authority.
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
    /// The class whose ClassTail is being parsed; see `ClassContext`.
    class: ClassContext = .{},
    /// Whether declarations are currently being parsed inside the synthetic
    /// CaseBlock lexical environment for a switch statement.
    in_switch_case_block_scope: bool = false,
    /// Whether `return` is syntactically allowed in the current statement body.
    return_depth: u32 = 0,
    /// Whether the last primary expression was super.
    last_was_super: bool = false,
    /// Grammar context of the function being parsed; a function boundary
    /// replaces and restores it as a whole.
    ctx: FunctionContext = .{},
    /// Root-bytecode label identity counter. Nested FunctionDefs use their
    /// own `label_count`, matching QuickJS's per-function label namespace.
    /// Function bodies currently anchor hoist/TDZ work in the finalizer
    /// instead of emitting their QuickJS `enter_scope` marker here. The
    /// body-event unification is tracked separately from ordinary blocks.
    /// Parity/tooling mode for top-level program dumps. QuickJS-ng dumps
    /// top-level lexical bindings in the eval/module wrapper as var-ref
    /// closure variables (`module_decl`) instead of ordinary local TDZ slots.
    /// Keep this opt-in so existing expression/unit-test paths retain their
    /// current local-slot behavior until full module/eval semantics land.
    top_level_lexical_as_module_ref: bool = false,
    top_level_lexical_as_global_ref: bool = false,
    eval_global_var_bindings: bool = false,
    eval_in_parameter_initializer: bool = false,
    eval_annex_b_blocked_function_names: []const Atom = &.{},
    features: std.EnumSet(FeatureImpl) = .initEmpty(),
    last_declared_atom: ?Atom = null,
    /// TypeScript parameter properties of the constructor being parsed.
    current_parameter_properties: ?std.ArrayList(Atom) = null,
    /// TypeScript: inside the check type of `A extends B ? C : D`, a
    /// nested conditional type needs parentheses (tsc
    /// `inDisallowConditionalTypesContext`).
    ts_disallow_conditional: bool = false,
    /// TypeScript: the last `parseFunctionDecl` consumed a body-less
    /// overload signature and declared nothing.
    ts_last_decl_was_signature: bool = false,

    /// QuickJS `eval_ret_idx` mirror. When set,
    /// the slot at this local index receives the result of every
    /// expression statement (instead of the placeholder `drop`), and
    /// the caller's `finalizeEvalReturn` retrieves it at script end.
    /// `enableEvalReturn` allocates the slot using the `<ret>` atom
    /// (id 82, `quickjs-atom.h:115`). `null` means non-eval mode.
    eval_ret_idx: ?u16 = null,

    /// QuickJS `JSFunctionDef` companion state. Populated
    /// during parsing with scope chain (`pushScope`/`popScope`),
    /// variable declarations (`addScopeVar`), and later closure/label
    /// data. The FunctionDef-based `resolve_variables` / `resolve_labels`
    /// passes read from it to drive scope-chain walking, closure synthesis,
    /// TDZ, and local-slot assignment.
    ///
    /// The parser still emits to `function.code` as before; this is a
    /// parallel structure that mirrors `JSParseState.curFunc`
    ///. Tests in `qjs_parser_test.zig` assert the
    /// `vars` / `scopes` layout is populated correctly.
    function_def: function_def_mod.FunctionDef,

    /// TGC S3-b §2.2: interval root for every atom this parse obtains.
    /// Detached at construction because `initRootEmitter` returns the
    /// `State` by value -- the provider stores `&self`, so registration
    /// waits for `activateCompileRoots`, which the owner calls once the
    /// state sits at its final address (the `ReplaceMatchRoots.activate`
    /// convention). A state that never activates records nothing and
    /// costs nothing; production compiles are additionally covered by the
    /// outer scope `compile_entry.compile` opens.
    atom_scope: atom_module.CompileAtomScope,

    /// TGC S3-b: set while this state's compile-value root provider is
    /// registered. See `traceCompileValueRoots`.
    compile_value_roots_registered: bool = false,

    /// Ephemeral declaration-conflict indices keyed by the FunctionDef
    /// being parsed. They accelerate only parser-time collision queries
    /// and are never transferred into FunctionBytecode.
    declaration_conflict_indices: DeclarationConflictIndexRegistry = .empty,

    /// Stack of FunctionDef pointers for nested function parsing.
    /// Mirrors `JSParseState.curFunc` stack management. The top of
    /// the stack is the current function being parsed. When entering
    /// a nested function, we push a new FunctionDef; when exiting,
    /// we pop back to the parent.
    cur_func_stack: []*function_def_mod.FunctionDef = &.{},
    cur_func_stack_capacity: usize = 0,
    discarded_func_head: ?*function_def_mod.FunctionDef = null,

    annex_b_if_function_decl_clause: bool = false,
    last_function_child_index: ?u16 = null,
    last_class_name_patch: ?ClassNamePatch = null,
    assign_expr_depth: u32 = 0,
    last_coalesce_expr_depth: ?u32 = null,
    active_with_atom: ?Atom = null,
    with_scope_id: u32 = 0,
    active_catch_marker_depth: u32 = 0,
    emit_lexical_tdz_at_decl: bool = false,
    break_fixups: std.ArrayList(usize) = .empty,
    break_frame_lens: std.ArrayList(usize) = .empty,
    /// One LabelId per break/continue frame (qjs push_break_entry
    /// label_break/label_cont).
    break_frame_labels: std.ArrayList(compiler.LabelId) = .empty,
    continue_fixups: std.ArrayList(usize) = .empty,
    continue_frame_lens: std.ArrayList(usize) = .empty,
    continue_frame_labels: std.ArrayList(compiler.LabelId) = .empty,
    continue_frame_break_frame_indices: std.ArrayList(usize) = .empty,
    break_frame_catch_marker_depths: std.ArrayList(u32) = .empty,
    break_frame_cleanup_drops: std.ArrayList(u8) = .empty,
    break_frame_cross_cleanup_drops: std.ArrayList(u8) = .empty,
    continue_frame_catch_marker_depths: std.ArrayList(u32) = .empty,
    continue_frame_cleanup_drops: std.ArrayList(u8) = .empty,
    label_frames: std.ArrayList(LabelFrame) = .empty,
    pending_label_atom: ?Atom = null,
    return_finally_frames: std.ArrayList(ReturnFinallyFrame) = .empty,
    finally_body_control_frames: std.ArrayList(FinallyBodyControlFrame) = .empty,
    using_block_frames: std.ArrayList(UsingBlockFrame) = .empty,
    class_private_elements: std.ArrayList(ClassPrivateElement) = .empty,
    class_private_bound_names: std.ArrayList(Atom) = .empty,

    /// A parse root: `name` is the root FunctionDef's name (the filename in
    /// production) and doubles as the default name of a nameless
    /// declaration; `script_or_module` defaults to it.
    pub fn init(
        lex: *lexer_mod.Lexer,
        allocation_runtime: *core.JSRuntime,
        native: std.mem.Allocator,
        artifacts: std.mem.Allocator,
        persistent: std.mem.Allocator,
        scratch: std.mem.Allocator,
        atoms: *atom_module.AtomTable,
        name: Atom,
    ) Error!State {
        var state = State{
            .lex = lex,
            .allocation_runtime = allocation_runtime,
            .allocator = native,
            .artifacts = artifacts,
            .persistent = persistent,
            .scratch = scratch,
            .atoms = atoms,
            .root_name = name,
            .token = undefined,
            .function_def = function_def_mod.FunctionDef.init(native, artifacts, atoms, name),
            .atom_scope = atom_module.CompileAtomScope.init(atoms, if (atoms.gc_registry != null) allocation_runtime else null),
        };
        errdefer state.function_def.deinitInitFailure();
        state.function_def.script_or_module = name;
        state.function_def.line_num = 1;
        state.function_def.col_num = 1;
        // A standalone ParseState represents a script/eval-program root,
        // matching JS_Eval's non-direct defaults in QuickJS. Production
        // compile_entry overwrites these facts for direct eval/module.
        state.function_def.has_this_binding = true;
        state.function_def.arguments_allowed = true;
        // Mirror `js_new_function_def`: scope 0
        // is the function's var/arg scope, parent = -1.
        _ = try state.function_def.appendScope(-1);
        // The root's Builder is the emission destination from the first
        // event onward; attach it before any parse step can emit.
        try state.ensureBuilderForFd(&state.function_def);
        try lex.nextInto(&state.token);
        // Every standalone State is a program/eval root.  QuickJS pushes
        // its real body scope before js_parse_program (and therefore
        // before directives/declarations); scope 0 remains exclusively
        // the var/arg environment.  Only the IDENTITY is established here:
        // declaration semantics need it immediately, but the marker cannot
        // be emitted before the root's Builder exists, so
        // `beginProgramEmission` emits it as the stream's first event.
        try state.beginFunctionBodyIdentityOnly();
        // Note: cur_func_stack starts empty; curFunc() returns &function_def when empty
        return state;
    }

    /// Initialize a parser state that may emit runtime-owned constants.
    /// QuickJS's `JSParseState` always carries its `JSContext`; zjs keeps
    /// the runtime-less initializer for low-level parser-only tests, while
    /// production compilation and executable-bytecode helpers use this
    /// entry point.
    pub fn initFromRuntime(lex: *lexer_mod.Lexer, rt: *core.JSRuntime, atoms: *atom_module.AtomTable, name: Atom) Error!State {
        const facade = rt.nativeAllocator();
        return init(lex, rt, rt.nativeAllocator(), facade, facade, facade, atoms, name);
    }

    pub fn initWithRuntime(rt: *core.JSRuntime, lex: *lexer_mod.Lexer, name: Atom) Error!State {
        var state = try initFromRuntime(lex, rt, rt.atoms, name);
        state.runtime = rt;
        return state;
    }

    /// The module record of a module root, created on first use.
    pub fn ensureModule(self: *State) *bytecode.module.Record {
        if (self.module_record == null) self.module_record = bytecode.module.Record.init(self.allocator, self.atoms);
        return &self.module_record.?;
    }

    /// Move the module record out; the caller owns it from here on.
    pub fn takeModuleRecord(self: *State) ?bytecode.module.Record {
        const record = self.module_record;
        self.module_record = null;
        return record;
    }

    /// Release State-owned resources. `rt` is forwarded to
    /// `FunctionDef.deinit` so constants in `function_def.cpool` can
    /// be released.
    pub fn deinit(self: *State, rt: *core.JSRuntime) void {
        // First: every step below can free a FunctionDef the value
        // provider walks. The atom scope is the opposite -- it goes last,
        // because teardown still hands atom ids back to the table.
        self.deactivateCompileValueRoots();
        declarations.deinitDeclarationConflictIndices(self);
        self.ctx.current_namespace_atom = null;
        if (self.last_declared_atom) |_| {
            self.last_declared_atom = null;
        }
        if (self.source_line_starts.len != 0) {
            self.scratch.free(self.source_line_starts);
            self.source_line_starts = &.{};
            self.source_line_starts_src = &.{};
        }
        self.lex.freeToken(&self.token);
        // Free any nested function definitions on the stack
        const cur_func_stack = self.cur_func_stack;
        const cur_func_stack_capacity = self.cur_func_stack_capacity;
        self.cur_func_stack = &.{};
        self.cur_func_stack_capacity = 0;
        for (cur_func_stack) |fd| {
            fd.deinit(rt);
            self.allocator.destroy(fd);
        }
        if (cur_func_stack_capacity != 0) {
            self.allocator.free(cur_func_stack.ptr[0..cur_func_stack_capacity]);
        }
        var discarded_func = self.discarded_func_head;
        self.discarded_func_head = null;
        while (discarded_func) |fd| {
            const next = fd.discard_next;
            fd.discard_next = null;
            fd.deinit(rt);
            self.allocator.destroy(fd);
            discarded_func = next;
        }
        self.break_fixups.deinit(self.scratch);
        self.break_frame_lens.deinit(self.scratch);
        self.break_frame_labels.deinit(self.scratch);
        self.continue_fixups.deinit(self.scratch);
        self.continue_frame_lens.deinit(self.scratch);
        self.continue_frame_labels.deinit(self.scratch);
        self.continue_frame_break_frame_indices.deinit(self.scratch);
        self.break_frame_catch_marker_depths.deinit(self.scratch);
        self.break_frame_cleanup_drops.deinit(self.scratch);
        self.break_frame_cross_cleanup_drops.deinit(self.scratch);
        self.continue_frame_catch_marker_depths.deinit(self.scratch);
        self.continue_frame_cleanup_drops.deinit(self.scratch);
        for (self.label_frames.items) |*frame| {
            frame.deinit(self.scratch);
        }
        self.label_frames.deinit(self.scratch);
        self.return_finally_frames.deinit(self.scratch);
        self.finally_body_control_frames.deinit(self.scratch);
        self.using_block_frames.deinit(self.scratch);
        self.truncateClassPrivateElements(0);
        self.class_private_elements.deinit(self.scratch);
        self.truncateClassPrivateBoundNames(0);
        self.class_private_bound_names.deinit(self.scratch);
        self.function_def.deinit(rt);
        if (self.module_record) |*record| record.deinit();
        self.module_record = null;
        // Last: the scope has to outlive every teardown step above, all of
        // which can still hand atom ids back to the table.
        self.atom_scope.deinit();
    }

    /// TGC S3-b: precise root for everything GC-typed this compile holds.
    ///
    /// Between the first token and `createFunctionBytecode` the compile
    /// owns real GC cells -- a RegExp literal's two strings, every tagged
    /// template's frozen array pair, and one `FunctionBytecode` per nested
    /// function -- and parks all of them in `[]JSValue` cpools hanging off
    /// Zig-heap `FunctionDef`s (see `FunctionDef.traceCompileRoots` for the
    /// full inventory). Nothing on the stack points at those arrays and no
    /// tracer edge reaches them until the artifact is published, so a major
    /// landing mid-compile frees cells the finalizer is about to read --
    /// with the provider dropped, the tagged-template test in
    /// `compiler/tests.zig` aborts on exactly that.
    ///
    /// Three storages, because a def can be in exactly one of three states
    /// and only the first is reachable from the root def:
    ///   * finished nested defs, linked into their parent's `child_list`
    ///     (walked recursively from `function_def`);
    ///   * defs currently being parsed, on `cur_func_stack` -- `addChild`
    ///     runs only at the END of `parseFunctionBody`, long after
    ///     `pushFunction`, so for the whole body these are reachable
    ///     nowhere else;
    ///   * defs abandoned by speculative rollback, on `discarded_func_head`
    ///     -- unlinked from the tree but still owning their cpool until
    ///     `State.deinit`.
    fn traceCompileValueRoots(self: *State, visitor: *core.runtime.RootVisitor) core.runtime.RootTraceError!void {
        try self.function_def.traceCompileRoots(visitor);
        for (self.cur_func_stack) |fd| try fd.traceCompileRoots(visitor);
        var discarded = self.discarded_func_head;
        while (discarded) |fd| : (discarded = fd.discard_next) {
            try fd.traceCompileRoots(visitor);
        }
    }

    fn traceCompileValueRootsThunk(context: *anyopaque, visitor: *core.runtime.RootVisitor) core.runtime.RootTraceError!void {
        const self: *State = @ptrCast(@alignCast(context));
        try self.traceCompileValueRoots(visitor);
    }

    fn compileValueRootProvider(self: *State) core.runtime.RootProvider {
        return .{ .context = @ptrCast(self), .trace = traceCompileValueRootsThunk };
    }

    /// TGC S3-b: register this parse's atom-root and value-root providers.
    /// Must be called exactly once, after the `State` reached its final
    /// address (both providers store `&self`) and before the first
    /// caller-driven parse step.
    pub fn activateCompileRoots(self: *State) Error!void {
        try self.atom_scope.activate();
        if (self.runtime) |rt| {
            if (comptime core.runtime.value_root_frames_enabled) {
                try rt.registerRootProvider(self.compileValueRootProvider());
                self.compile_value_roots_registered = true;
            }
        }
    }

    fn deactivateCompileValueRoots(self: *State) void {
        if (!self.compile_value_roots_registered) return;
        self.compile_value_roots_registered = false;
        self.runtime.?.unregisterRootProvider(self.compileValueRootProvider());
    }

    pub fn setCurrentNamespaceAtom(self: *State, atom_id: ?Atom) void {
        self.ctx.current_namespace_atom = atom_id;
    }

    pub fn setLastDeclaredAtom(self: *State, atom_id: Atom) void {
        self.last_declared_atom = atom_id;
    }

    /// Get the current FunctionDef from the top of the stack.
    /// Mirrors `JSParseState.curFunc` access. Returns the root
    /// function_def when the stack is empty (top-level parsing).
    pub fn curFunc(self: *State) *function_def_mod.FunctionDef {
        if (self.cur_func_stack.len == 0) {
            return &self.function_def;
        }
        return self.cur_func_stack[self.cur_func_stack.len - 1];
    }

    /// Push a new FunctionDef onto the stack. Called when entering
    /// a nested function. Mirrors the parent link setup in
    /// `js_new_function_def`.
    pub fn pushFunction(self: *State, fd: *function_def_mod.FunctionDef) Error!void {
        const old_len = self.cur_func_stack.len;
        const new_len = self.cur_func_stack.len + 1;

        if (new_len > self.cur_func_stack_capacity) {
            const old_capacity = self.cur_func_stack_capacity;
            var new_capacity = if (old_capacity == 0)
                @as(usize, 4)
            else
                std.math.mul(usize, old_capacity, 2) catch return error.OutOfMemory;
            if (new_capacity < new_len) new_capacity = new_len;

            const next = try self.allocator.alloc(*function_def_mod.FunctionDef, new_capacity);
            errdefer self.allocator.free(next);
            @memcpy(next[0..old_len], self.cur_func_stack);
            const old_stack: []*function_def_mod.FunctionDef = if (old_capacity != 0) self.cur_func_stack.ptr[0..old_capacity] else self.cur_func_stack[0..0];
            self.cur_func_stack = next[0..old_len];
            self.cur_func_stack_capacity = new_capacity;
            if (old_capacity != 0) {
                self.allocator.free(old_stack);
            }
        }

        self.cur_func_stack = self.cur_func_stack.ptr[0..new_len];
        self.cur_func_stack[old_len] = fd;
        if (fd.builder == null) {
            try self.ensureBuilderForFd(fd);
        }
    }

    /// Pop the current FunctionDef from the stack. Called when exiting
    /// a nested function. Returns the popped FunctionDef pointer.
    pub fn popFunction(self: *State) *function_def_mod.FunctionDef {
        const fd = self.cur_func_stack[self.cur_func_stack.len - 1];
        self.cur_func_stack = self.cur_func_stack.ptr[0 .. self.cur_func_stack.len - 1];
        return fd;
    }

    pub fn discardCurrentFunction(self: *State) void {
        const fd = self.popFunction();
        self.discardFunctionDef(fd);
    }

    pub fn discardFunctionDef(self: *State, fd: *function_def_mod.FunctionDef) void {
        declarations.discardDeclarationConflictIndex(self, fd);
        if (self.runtime) |rt| {
            fd.deinit(rt);
            self.allocator.destroy(fd);
            return;
        }
        fd.discard_next = self.discarded_func_head;
        self.discarded_func_head = fd;
    }

    /// Mirror `push_scope`: allocate a new
    /// `VarScope` whose parent is the current scope, then switch
    /// `scope_level` to it. Call on entry to a new lexical block.
    pub fn pushScopeIdentity(self: *State) Error!void {
        const parent = self.scope_level;
        const new_scope = try self.curFunc().appendScope(parent);
        self.scope_level = new_scope;
        self.curFunc().scope_level = new_scope;
    }

    /// Allocate a lexical scope and emit its phase-1 entry event.  Parser
    /// state restoration on emission failure is identity-only: a failed
    /// parse must not manufacture a runtime leave event.
    pub fn pushScope(self: *State) Error!void {
        try self.pushScopeIdentity();
        errdefer self.popScopeIdentity();
        try self.emitEnterScope();
    }

    /// `pushScope` as a guard value; see `OpenScope`.
    pub fn openScope(self: *State) Error!OpenScope {
        try self.pushScope();
        return .{};
    }

    /// Create the one real function-body scope and emit its marker at the
    /// exact parser boundary consumed by `instantiate_hoisted_definitions`.
    pub fn beginFunctionBody(self: *State) Error!void {
        try self.beginFunctionBodyIdentityOnly();
        try self.emitEnterScope();
    }

    /// The identity half of `beginFunctionBody`. The program root splits
    /// the two: its scope identity must exist for declaration semantics
    /// before the root Builder is attached, and the marker is then the
    /// first event the Builder receives.
    pub fn beginFunctionBodyIdentityOnly(self: *State) Error!void {
        try self.pushScopeIdentity();
        self.curFunc().body_scope = self.scope_level;
    }

    /// Mirror `pop_scope`: restore the parent
    /// scope. Also updates `function_def.scope_first` to the outer
    /// scope's first lexical var so subsequent lookups see the
    /// correct chain.
    pub fn popScopeIdentity(self: *State) void {
        if (self.scope_level < 0) return;
        const parent = self.curFunc().scopes[@intCast(self.scope_level)].parent;
        self.scope_level = parent;
        self.curFunc().scope_level = parent;
        // Recompute scope_first for the new current scope (mirrors
        // `get_first_lexical_var` at `quickjs.c`).
        var scope = parent;
        self.curFunc().scope_first = -1;
        while (scope >= 0) {
            const s_idx = self.curFunc().scopes[@intCast(scope)].first;
            if (s_idx >= 0) {
                self.curFunc().scope_first = s_idx;
                break;
            }
            scope = self.curFunc().scopes[@intCast(scope)].parent;
        }
    }

    /// Emit the current lexical scope's phase-1 exit event, then restore
    /// the parent scope identity.
    pub fn popScope(self: *State) Error!void {
        try self.emitLeaveScope(self.scope_level);
        self.popScopeIdentity();
    }

    pub fn atFunctionBodyScope(self: *State) bool {
        return self.curFunc().body_scope >= 0 and self.scope_level == self.curFunc().body_scope;
    }

    pub fn atProgramBodyScope(self: *State) bool {
        return self.cur_func_stack.len == 0 and self.curFunc().is_eval and self.atFunctionBodyScope();
    }

    pub fn isChildScope(self: *State, scope: i32, parent_scope: i32) bool {
        if (scope < 0 or parent_scope < 0) return false;
        const scopes = self.curFunc().scopes;
        var current = scope;
        var visited: usize = 0;
        while (current >= 0 and visited <= scopes.len) : (visited += 1) {
            if (current == parent_scope) return true;
            if (@as(usize, @intCast(current)) >= scopes.len) return false;
            current = scopes[@intCast(current)].parent;
        }
        return false;
    }

    pub fn firstGlobalVarIndex(self: *State, name: Atom) ?usize {
        for (self.curFunc().global_vars, 0..) |gv, idx| {
            if (gv.var_name == name) return idx;
        }
        return null;
    }

    pub fn emitGlobalScopePutVar(self: *State, atom_id: Atom) Error!void {
        // `scope_level = -1` is a resolver-only sentinel for Annex B global
        // function binding updates: bypass block/function locals and lower to
        // final `put_var`.
        try Emitter.opAtomU16(self, opcode.op.scope_put_var, atom_id, std.math.maxInt(u16));
    }

    pub fn emitEvalVarObjectScopePutVar(self: *State, atom_id: Atom) Error!void {
        // Annex B's var-copy assignment bypasses the block lexical binding
        // but must still traverse the eval declaration environment. Scope
        // zero excludes the block-local function while retaining the
        // compiler-seeded _var_/_arg_var_ and exact caller closure targets.
        try Emitter.opAtomU16(self, opcode.op.scope_put_var, atom_id, 0);
    }

    /// Atom id reserved for the eval-return slot, mirroring
    /// `JS_ATOM__ret_` / `<ret>` (`quickjs-atom.h:115`). Used as the
    /// var name for the synthetic local that captures every
    /// expression-statement result in eval mode.
    pub const eval_ret_atom: Atom = atom_module.ids.ret;

    /// Switch the parser into eval mode and allocate the synthetic
    /// `<ret>` local that holds the result of the last evaluated
    /// expression. Mirrors `set_eval_ret_undefined` setup +
    /// `add_var(JS_ATOM__ret_)`. The
    /// caller invokes this immediately after `State.init` and
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
    pub fn enableEvalReturn(self: *State) Error!void {
        self.is_eval = true;
        self.curFunc().is_eval = true;
        self.eval_delete_bindings = true;
        try self.enableReturnCompletion();
    }

    /// Enable expression-statement completion capture without changing script
    /// declaration semantics. This supports global script execution that returns
    /// the script completion without switching to eval code semantics.
    pub fn enableReturnCompletion(self: *State) Error!void {
        // js_parse_program uses add_var, not add_scope_var. `<ret>` is a
        // scope-0 pseudo local and must never become the head of the real
        // program body lexical chain.
        const idx = try declarations.appendFunctionVarAtOrigin(self, eval_ret_atom, 0);
        self.eval_ret_idx = idx;
        // Emit the initialiser directly by slot. Every syntactic finally
        // adds another same-named `<ret>` save slot, so name lookup would
        // become ambiguous after the first one.
        try Emitter.op(self, opcode.op.undefined);
        try self.emitEvalRetPut();
    }

    pub fn emitEvalRetGet(self: *State) Error!void {
        const idx = self.eval_ret_idx orelse return;
        try Emitter.opU16(self, opcode.op.get_loc, idx);
    }

    pub fn emitEvalRetPut(self: *State) Error!void {
        const idx = self.eval_ret_idx orelse return;
        try Emitter.opU16(self, opcode.op.put_loc, idx);
    }

    /// Mirror the tail of `js_parse_program`:
    /// after the last statement is parsed, load `<ret>` and terminate the
    /// body with an explicit value-return. No-op when completion capture is
    /// disabled.
    pub fn finalizeEvalReturn(self: *State) Error!void {
        if (self.eval_ret_idx == null) return;
        try self.emitEvalRetGet();
        try Emitter.op(self, opcode.op.@"return");
    }

    /// Mirror QuickJS `set_eval_ret_undefined`:
    /// control-flow statements reset eval completion before parsing their
    /// children, and executed expression statements overwrite it.
    pub fn setEvalReturnUndefined(self: *State) Error!void {
        if (self.eval_ret_idx == null) return;
        try Emitter.op(self, opcode.op.undefined);
        try self.emitEvalRetPut();
    }

    pub fn emitReturnUndefined(self: *State) Error!void {
        // qjs js_parse_program/function tail: emit the implicit return_undef terminal.
        try Emitter.op(self, opcode.op.return_undef);
    }

    /// Advance one token. Frees the payload of the consumed token.
    pub fn advance(self: *State) Error!void {
        // Native C-stack recursion guard. Every recursive-descent path
        // (parens, arrays, objects, nested statements) consumes tokens
        // through here, so a single check mirrors QuickJS guarding
        // `next_token` and turns pathological nesting into
        // a catchable SyntaxError instead of a native stack overflow.
        if (self.runtime) |rt| {
            if (rt.checkNativeStackOverflow(0)) return self.failHere(error.StackOverflow);
        }
        // `lex.pos` is the end of the current token until nextInto starts
        // skipping trivia, matching QuickJS's `last_ptr = buf_ptr`.
        std.debug.assert(self.lex.pos == self.currentTokenEndOffset());
        self.last_token_end_offset = self.lex.pos;
        self.last_token_line_num = self.token.line_num;
        self.last_token_col_num = self.token.col_num;
        self.lex.nextIntoReplacing(&self.token) catch |err| {
            if (err != error.OutOfMemory) {
                self.setPendingDiagnostic(
                    err,
                    .{
                        .offset = self.lex.mark_pos,
                        .line = self.lex.mark_line,
                        .column = self.lex.mark_col,
                    },
                    decoratorDiagnosticMessage(self.lex.source, err, self.lex.mark_pos) orelse @errorName(err),
                );
            }
            return err;
        };
    }

    pub noinline fn setPendingDiagnostic(self: *State, err: Error, position: diagnostics.Position, message: []const u8) void {
        var pending = PendingDiagnostic{
            .position = position,
            .err = err,
        };
        const message_len = @min(message.len, pending.message_buffer.len);
        @memcpy(pending.message_buffer[0..message_len], message[0..message_len]);
        pending.message_len = @intCast(message_len);
        self.pending_diagnostic = pending;
    }

    /// `@` is lexed as an invalid identifier start. Name the real cause:
    /// decorators are outside the supported grammar.
    pub fn decoratorDiagnosticMessage(source: []const u8, err: anyerror, offset: usize) ?[]const u8 {
        if (err != error.InvalidIdentifier or offset >= source.len or source[offset] != '@') return null;
        return "decorators are not supported; remove the decorator or refactor";
    }

    /// The current token's source event, for grammar sites that pin an
    /// opcode to the construct they are parsing.
    pub fn currentSourcePosition(self: *const State) SourcePosition {
        return .{ .line_num = self.token.line_num, .col_num = self.token.col_num };
    }

    pub fn currentDiagnosticPosition(self: *const State) diagnostics.Position {
        return .{
            .offset = self.currentTokenStartOffset(),
            .line = self.token.line_num,
            .column = self.token.col_num,
        };
    }

    pub fn recordFailureHere(self: *State, err: Error) void {
        switch (err) {
            error.OutOfMemory, error.BytecodeOverflow => {},
            else => self.setPendingDiagnostic(err, self.currentDiagnosticPosition(), @errorName(err)),
        }
    }

    fn failHere(self: *State, err: Error) Error {
        self.recordFailureHere(err);
        return err;
    }

    pub fn propagateFailureHere(self: *State, err: Error) Error {
        if (self.pending_diagnostic) |pending| {
            if (pending.err == err) return err;
        }
        self.recordFailureHere(err);
        return err;
    }

    pub fn tokenKindLabel(self: *const State, kind: tok.TokenKind, buffer: []u8) []const u8 {
        const raw = @intFromEnum(kind);
        if (raw >= 0 and raw <= std.math.maxInt(u8)) {
            if (buffer.len < 3) return "token";
            buffer[0] = '\'';
            buffer[1] = @as(u8, @intCast(raw));
            buffer[2] = '\'';
            return buffer[0..3];
        }
        if (tok.isKeyword(kind)) {
            return self.atoms.name(tok.keywordAtom(kind)) orelse "keyword";
        }
        return switch (kind) {
            .number => "number",
            .string => "string",
            .template => "template",
            .ident => "identifier",
            .regexp => "regexp",
            .eof => "end of input",
            .err => "invalid token",
            .private_name => "private name",
            .arrow => "'=>'",
            .ellipsis => "'...'",
            .double_question_mark => "'??'",
            .question_mark_dot => "'?.'",
            else => "token",
        };
    }

    fn currentTokenKindLabel(self: *const State, buffer: []u8) []const u8 {
        const generic = self.tokenKindLabel(self.peekKind(), buffer);
        if (!std.mem.eql(u8, generic, "token")) return generic;
        if (self.token.len == 0 or self.token.len > buffer.len - 2) return generic;
        buffer[0] = '\'';
        @memcpy(buffer[1 .. self.token.len + 1], self.token.ptr[0..self.token.len]);
        buffer[self.token.len + 1] = '\'';
        return buffer[0 .. self.token.len + 2];
    }

    pub fn failExpectedToken(self: *State, expected: tok.TokenKind) Error {
        var expected_buffer: [8]u8 = undefined;
        const expected_name = self.tokenKindLabel(expected, &expected_buffer);
        return self.failExpectedDescription(expected_name);
    }

    fn formatExpectedGot(buffer: []u8, expected: []const u8, actual: []const u8) []const u8 {
        const prefix = "expected ";
        const mid = ", got ";
        const needed = prefix.len + expected.len + mid.len + actual.len;
        if (needed > buffer.len) return "UnexpectedToken";
        @memcpy(buffer[0..prefix.len], prefix);
        @memcpy(buffer[prefix.len..][0..expected.len], expected);
        @memcpy(buffer[prefix.len + expected.len ..][0..mid.len], mid);
        @memcpy(buffer[prefix.len + expected.len + mid.len ..][0..actual.len], actual);
        return buffer[0..needed];
    }

    pub fn failExpectedDescription(self: *State, expected: []const u8) Error {
        var actual_buffer: [16]u8 = undefined;
        const actual_name = self.currentTokenKindLabel(&actual_buffer);
        var message_buffer: [PendingDiagnostic.message_capacity]u8 = undefined;
        const message = State.formatExpectedGot(&message_buffer, expected, actual_name);
        self.setPendingDiagnostic(error.UnexpectedToken, self.currentDiagnosticPosition(), message);
        return error.UnexpectedToken;
    }

    pub fn failExpectedDescriptionAt(
        self: *State,
        expected: []const u8,
        actual: tok.TokenKind,
        position: diagnostics.Position,
    ) Error {
        var actual_buffer: [16]u8 = undefined;
        const actual_name = self.tokenKindLabel(actual, &actual_buffer);
        var message_buffer: [PendingDiagnostic.message_capacity]u8 = undefined;
        const message = State.formatExpectedGot(&message_buffer, expected, actual_name);
        return self.failWithMessage(position, message);
    }

    pub fn failUnexpectedToken(self: *State) Error {
        var actual_buffer: [16]u8 = undefined;
        const actual_name = self.currentTokenKindLabel(&actual_buffer);
        var message_buffer: [PendingDiagnostic.message_capacity]u8 = undefined;
        const message = std.fmt.bufPrint(
            &message_buffer,
            "unexpected {s}",
            .{actual_name},
        ) catch "UnexpectedToken";
        self.setPendingDiagnostic(error.UnexpectedToken, self.currentDiagnosticPosition(), message);
        return error.UnexpectedToken;
    }

    pub fn failWithMessage(self: *State, position: ?diagnostics.Position, message: []const u8) Error {
        self.setPendingDiagnostic(error.UnexpectedToken, position orelse self.currentDiagnosticPosition(), message);
        return error.UnexpectedToken;
    }

    pub fn failUndefinedLabel(self: *State, atom_id: Atom) Error {
        const label_name = self.atoms.name(atom_id) orelse return error.ParserInvariant;
        var message_buffer: [PendingDiagnostic.message_capacity]u8 = undefined;
        const message = std.fmt.bufPrint(
            &message_buffer,
            "undefined label '{s}'",
            .{label_name},
        ) catch "undefined label";
        return self.failWithMessage(null, message);
    }

    pub fn peekKind(self: *const State) tok.TokenKind {
        return self.token.val;
    }

    pub fn currentTokenStartOffset(self: *const State) usize {
        const source_ptr = @intFromPtr(self.lex.source.ptr);
        const token_ptr = @intFromPtr(self.token.ptr);
        if (token_ptr <= source_ptr) return 0;
        return @min(token_ptr - source_ptr, self.lex.source.len);
    }

    pub fn currentFunctionSourceStart(self: *const State) FunctionSourceStart {
        return .{
            .offset = self.currentTokenStartOffset(),
            .line_num = self.token.line_num,
            .col_num = self.token.col_num,
        };
    }

    pub fn currentTokenEndOffset(self: *const State) usize {
        return @min(self.currentTokenStartOffset() + self.token.len, self.lex.source.len);
    }

    pub fn captureFunctionSource(self: *State, fd: *function_def_mod.FunctionDef, source_start: usize) Error!void {
        try self.setFunctionSourceRange(fd, source_start, self.last_token_end_offset);
    }

    fn setFunctionSourceRange(
        self: *State,
        fd: *function_def_mod.FunctionDef,
        source_start: usize,
        source_end: usize,
    ) Error!void {
        if (source_end <= source_start or source_start > self.lex.source.len or source_end > self.lex.source.len) return;
        try fd.replaceSourceText(self.lex.source[source_start..source_end]);
    }

    pub fn setChildFunctionSourceByCpoolIndex(
        self: *State,
        cpool_idx: u16,
        source_start: usize,
        source_end: usize,
    ) Error!void {
        for (self.curFunc().child_list) |child| {
            if (child.parent_cpool_idx != cpool_idx) continue;
            try self.setFunctionSourceRange(child, source_start, source_end);
            return;
        }
    }

    /// Check if we got a line terminator before the current token (for ASI).
    pub fn gotLineTerminator(self: *const State) bool {
        return self.lex.gotLineTerminator();
    }

    // ---- label management ----
    // This parser still lowers jumps directly, but labelled control flow
    // mirrors QuickJS `push_break_entry` / `emit_break` enough to route
    // labels without exposing regular labelled statements to unlabelled
    // `break`.

    pub fn hasActiveLabel(s: *State, atom_id: Atom) bool {
        for (s.label_frames.items) |frame| {
            if (frame.atom == atom_id) return true;
        }
        return false;
    }

    pub fn pushLabelFrame(s: *State, atom_id: Atom, allow_continue: bool) Error!usize {
        var break_label: ?compiler.LabelId = null;
        var continue_label: ?compiler.LabelId = null;
        if (allow_continue) continue_label = try Emitter.newLabel(s);
        break_label = try Emitter.newLabel(s);
        try s.label_frames.append(s.scratch, LabelFrame{
            .atom = atom_id,
            .allow_continue = allow_continue,
            .catch_marker_depth = s.active_catch_marker_depth,
            .control_frame_depth = s.continue_frame_lens.items.len,
            .break_frame_depth = s.break_frame_lens.items.len,
            .break_label = break_label,
            .continue_label = continue_label,
        });
        return s.label_frames.items.len - 1;
    }

    pub fn patchLabelBreaks(s: *State, frame_index: usize) Error!void {
        // qjs emit_label(label_break): the merge label binds unconditionally,
        // even with zero refs (resolve_labels drops dead labels).
        if (s.label_frames.items[frame_index].break_label) |label| {
            try Emitter.bind(s, label);
        }
    }

    pub fn patchLabelContinues(s: *State, frame_index: usize) Error!void {
        // qjs emit_label(label_cont): the merge label binds unconditionally,
        // even with zero refs (resolve_labels drops dead labels).
        if (s.label_frames.items[frame_index].continue_label) |label| {
            try Emitter.bind(s, label);
        }
    }

    pub fn popLabelFrame(s: *State, frame_index: usize) void {
        std.debug.assert(frame_index + 1 == s.label_frames.items.len);
        s.label_frames.items[frame_index].deinit(s.scratch);
        _ = s.label_frames.pop().?;
    }

    pub fn findLabelFrame(s: *State, atom_id: Atom) ?usize {
        var i = s.label_frames.items.len;
        while (i != 0) {
            i -= 1;
            if (s.label_frames.items[i].atom == atom_id) return i;
        }
        return null;
    }

    pub fn emitLabelledBreak(s: *State, atom_id: Atom) Error!void {
        try emitter.emitControlThroughFinally(s, .{ .kind = .@"break", .label_atom = atom_id });
    }

    pub fn emitLabelledContinue(s: *State, atom_id: Atom) Error!void {
        try emitter.emitControlThroughFinally(s, .{ .kind = .@"continue", .label_atom = atom_id });
    }

    pub fn labelStartAtom(s: *State) ?Atom {
        if (!identifiers.isIdentifierLikeToken(s)) return null;
        if (s.peekNextKind() != .colon) return null;
        const kind = s.peekKind();
        const atom_id = identifiers.identifierLikeAtom(s);
        if (kind == .ident and identifiers.escapedIdentifierIsReservedWordForCurrentContext(s, atom_id, s.token.payload.ident.has_escape)) return null;
        return atom_id;
    }

    pub fn isReservedLabelIdentifier(s: *State, atom_id: Atom) bool {
        return (s.lex.is_module and identifiers.atomNameEquals(s, atom_id, "await")) or
            (s.ctx.in_async and identifiers.atomNameEquals(s, atom_id, "await")) or
            (s.ctx.in_class_static_block and identifiers.atomNameEquals(s, atom_id, "await")) or
            (s.ctx.in_generator and identifiers.atomNameEquals(s, atom_id, "yield")) or
            ((s.is_strict or s.curFunc().is_strict_mode) and identifiers.atomNameEquals(s, atom_id, "yield"));
    }

    fn deinitCurrentControlFrames(s: *State) void {
        const allocator = s.scratch;
        s.break_fixups.deinit(allocator);
        s.break_frame_lens.deinit(allocator);
        s.break_frame_labels.deinit(allocator);
        s.break_frame_catch_marker_depths.deinit(allocator);
        s.break_frame_cleanup_drops.deinit(allocator);
        s.break_frame_cross_cleanup_drops.deinit(allocator);
        s.continue_fixups.deinit(allocator);
        s.continue_frame_lens.deinit(allocator);
        s.continue_frame_labels.deinit(allocator);
        s.continue_frame_break_frame_indices.deinit(allocator);
        s.continue_frame_catch_marker_depths.deinit(allocator);
        s.continue_frame_cleanup_drops.deinit(allocator);
        for (s.label_frames.items) |*frame| {
            frame.deinit(allocator);
        }
        s.label_frames.deinit(allocator);
        s.using_block_frames.deinit(allocator);
    }

    pub fn enterControlBoundary(s: *State) ControlFrames {
        const saved = ControlFrames{
            .top_break = s.top_break,
            .break_fixups = s.break_fixups,
            .break_frame_lens = s.break_frame_lens,
            .break_frame_labels = s.break_frame_labels,
            .break_frame_catch_marker_depths = s.break_frame_catch_marker_depths,
            .break_frame_cleanup_drops = s.break_frame_cleanup_drops,
            .break_frame_cross_cleanup_drops = s.break_frame_cross_cleanup_drops,
            .continue_fixups = s.continue_fixups,
            .continue_frame_lens = s.continue_frame_lens,
            .continue_frame_labels = s.continue_frame_labels,
            .continue_frame_break_frame_indices = s.continue_frame_break_frame_indices,
            .continue_frame_catch_marker_depths = s.continue_frame_catch_marker_depths,
            .continue_frame_cleanup_drops = s.continue_frame_cleanup_drops,
            .label_frames = s.label_frames,
            .pending_label_atom = s.pending_label_atom,
            .active_catch_marker_depth = s.active_catch_marker_depth,
            .using_block_frames = s.using_block_frames,
        };
        s.top_break = null;
        s.break_fixups = .empty;
        s.break_frame_lens = .empty;
        s.break_frame_labels = .empty;
        s.break_frame_catch_marker_depths = .empty;
        s.break_frame_cleanup_drops = .empty;
        s.break_frame_cross_cleanup_drops = .empty;
        s.continue_fixups = .empty;
        s.continue_frame_lens = .empty;
        s.continue_frame_labels = .empty;
        s.continue_frame_break_frame_indices = .empty;
        s.continue_frame_catch_marker_depths = .empty;
        s.continue_frame_cleanup_drops = .empty;
        s.label_frames = .empty;
        s.pending_label_atom = null;
        s.active_catch_marker_depth = 0;
        s.using_block_frames = .empty;
        return saved;
    }

    /// Restore the enclosing function's control frames. A boundary is
    /// left once: an `errdefer` armed across the explicit leave does
    /// nothing.
    pub fn leaveControlBoundary(s: *State, boundary: *ControlFrames) void {
        if (boundary.left) return;
        boundary.left = true;
        const saved = boundary.*;
        s.deinitCurrentControlFrames();
        s.top_break = saved.top_break;
        s.break_fixups = saved.break_fixups;
        s.break_frame_lens = saved.break_frame_lens;
        s.break_frame_labels = saved.break_frame_labels;
        s.break_frame_catch_marker_depths = saved.break_frame_catch_marker_depths;
        s.break_frame_cleanup_drops = saved.break_frame_cleanup_drops;
        s.break_frame_cross_cleanup_drops = saved.break_frame_cross_cleanup_drops;
        s.continue_fixups = saved.continue_fixups;
        s.continue_frame_lens = saved.continue_frame_lens;
        s.continue_frame_labels = saved.continue_frame_labels;
        s.continue_frame_break_frame_indices = saved.continue_frame_break_frame_indices;
        s.continue_frame_catch_marker_depths = saved.continue_frame_catch_marker_depths;
        s.continue_frame_cleanup_drops = saved.continue_frame_cleanup_drops;
        s.label_frames = saved.label_frames;
        s.pending_label_atom = saved.pending_label_atom;
        s.active_catch_marker_depth = saved.active_catch_marker_depth;
        s.using_block_frames = saved.using_block_frames;
    }

    pub fn truncateClassPrivateElements(self: *State, len: usize) void {
        self.class_private_elements.shrinkRetainingCapacity(len);
    }

    pub fn truncateClassPrivateBoundNames(self: *State, len: usize) void {
        self.class_private_bound_names.shrinkRetainingCapacity(len);
    }

    /// Expect a semicolon, applying ASI rules. Returns true if a semicolon
    /// was present or inserted via ASI.
    pub fn expectSemicolon(s: *State) Error!bool {
        if (s.peekKind() == .semicolon) {
            try s.advance();
            return true;
        }
        // ASI: if we have a line terminator or are at EOF or closing brace,
        // insert a semicolon automatically.
        if (s.gotLineTerminator() or s.peekKind() == .eof or s.peekKind() == .rbrace) {
            return true;
        }
        return s.failExpectedToken(.semicolon);
    }

    /// Expect a specific token kind.
    pub fn expectToken(s: *State, kind: tok.TokenKind) Error!void {
        if (s.peekKind() != kind) return s.failExpectedToken(kind);
        try s.advance();
    }

    /// Peek at the next token kind without consuming the current token.
    /// Saves and restores lexer position so the cached token stays valid.
    pub fn peekNextKind(s: *State) tok.TokenKind {
        return s.peekNext().kind;
    }

    pub fn peekNextIsOfToken(s: *State) bool {
        const saved_cursor = lookahead.takeLexerCursorSnapshot(s);
        defer lookahead.restoreLexerCursorSnapshot(s, saved_cursor);
        var peek_token = s.lex.next() catch return false;
        defer s.lex.freeToken(&peek_token);
        if (peek_token.val == .kw_of) return true;
        return peek_token.val == .ident and
            !peek_token.payload.ident.has_escape and
            identifiers.atomNameEquals(s, peek_token.payload.ident.atom, "of");
    }

    pub const PeekedToken = struct {
        kind: tok.TokenKind,
        line_terminator: bool,

        /// `kind` with no line terminator in between: the restricted
        /// productions (`async function`, `get`/`set` names, ...).
        pub fn isBefore(self: PeekedToken, kind: tok.TokenKind) bool {
            return self.kind == kind and !self.line_terminator;
        }
    };

    /// The kind of the token after the current one, and whether a line
    /// terminator precedes it. Lexer errors read as end of input.
    pub fn peekNext(s: *State) PeekedToken {
        const saved_cursor = lookahead.takeLexerCursorSnapshot(s);
        defer lookahead.restoreLexerCursorSnapshot(s, saved_cursor);
        var peek_token = s.lex.next() catch return .{ .kind = .eof, .line_terminator = false };
        defer s.lex.freeToken(&peek_token);
        return .{ .kind = peek_token.val, .line_terminator = s.lex.gotLineTerminator() };
    }

    /// Mirror QuickJS's `SKIP_HAS_SEMI` dispatch at the `for` statement
    /// boundary. Every C-style for head has a top-level semicolon; heads
    /// without one are handed to the real for-in/of parser, which owns the
    /// grammar and diagnostics. This remains separate until the unified
    /// scanner can preserve the production CodeLoad layout gate.
    pub fn forHeadHasNoTopLevelSemicolon(s: *State) bool {
        const saved_cursor = lookahead.takeLexerCursorSnapshot(s);
        // The scan consumes `s.token` while advancing. Keep an independent
        // owner for the token restored at the end.
        const saved_token = s.lex.dupToken(s.token) catch return false;
        defer {
            s.lex.freeToken(&s.token);
            lookahead.restoreLexerCursorSnapshot(s, saved_cursor);
            s.token = saved_token;
        }

        const advanceLocal = struct {
            fn call(state: *State) bool {
                state.lex.nextIntoReplacing(&state.token) catch return false;
                return true;
            }
        }.call;

        var paren_depth: usize = 0;
        var bracket_depth: usize = 0;
        var brace_depth: usize = 0;
        var previous_token_kind: ?tok.TokenKind = null;
        while (true) {
            const kind = s.peekKind();
            if (kind == .eof) return false;
            if (kind == .template) {
                lookahead.skipTemplateInPredeclareScan(s, s.token) catch return false;
                if (!advanceLocal(s)) return false;
                previous_token_kind = .template;
                continue;
            }
            if (identifiers.tokenCanStartSlashRegexp(kind) and
                (lookahead.skipRegexpInPredeclareScan(s, previous_token_kind) catch return false))
            {
                if (!advanceLocal(s)) return false;
                previous_token_kind = .regexp;
                continue;
            }

            switch (kind) {
                .lparen => paren_depth += 1,
                .rparen => {
                    if (paren_depth == 0 and bracket_depth == 0 and brace_depth == 0) return true;
                    if (paren_depth == 0) return false;
                    paren_depth -= 1;
                },
                .lbracket => bracket_depth += 1,
                .rbracket => {
                    if (bracket_depth == 0) return false;
                    bracket_depth -= 1;
                },
                .lbrace => brace_depth += 1,
                .rbrace => {
                    if (brace_depth == 0) return false;
                    brace_depth -= 1;
                },
                .semicolon => if (paren_depth == 0 and bracket_depth == 0 and brace_depth == 0) return false,
                else => {},
            }
            previous_token_kind = kind;
            if (!advanceLocal(s)) return false;
        }
    }

    /// Check the still-unparsed RHS of an assignment for a direct eval
    /// call. A free closure target only needs the early Reference capture
    /// when this expression can mutate the current variable environment;
    /// emitting that representation for every ordinary closure write
    /// breaks the stack contracts of destructuring and callback code.
    ///
    /// This is a lexer-only lookahead. It preserves the parser token and
    /// lexer cursor, skips regexp/template bodies using the same helpers
    /// as the declaration pre-scan, and stops at the current expression's
    /// top-level boundary. Nested function bodies are not part of the
    /// current function's direct-eval environment.
    pub fn rhsContainsDirectEval(s: *State) bool {
        const saved_cursor = lookahead.takeLexerCursorSnapshot(s);
        // The scan advances past the current token and releases its atom.
        // Keep an independent owner for the token restored at the end;
        // copying the token struct would restore a dead identifier atom.
        const saved_token = s.lex.dupToken(s.token) catch return false;
        defer {
            s.lex.freeToken(&s.token);
            lookahead.restoreLexerCursorSnapshot(s, saved_cursor);
            s.token = saved_token;
        }

        const advanceLocal = struct {
            fn call(state: *State) bool {
                state.lex.nextIntoReplacing(&state.token) catch return false;
                return true;
            }
        }.call;

        var paren_depth: usize = 0;
        var bracket_depth: usize = 0;
        var brace_depth: usize = 0;
        var previous_token_kind: ?tok.TokenKind = null;
        var eval_candidate = false;
        // Keep a direct-eval candidate alive while closing a grouping
        // whose complete expression was `eval`. This covers `(eval)(...)`
        // and nested `((eval))(...)`, while a comma/operator inside the
        // grouping clears the flag before the closing parenthesis.
        var grouped_eval_candidate = false;

        while (true) {
            const kind = s.peekKind();
            if (kind == .eof) return false;

            if (kind == .template) {
                if (templateContainsDirectEval(s, s.token)) return true;
                eval_candidate = false;
                previous_token_kind = .template;
                if (!advanceLocal(s)) return false;
                continue;
            }
            if (kind == .kw_function) {
                lookahead.skipFunctionInPredeclareScan(s) catch return false;
                eval_candidate = false;
                previous_token_kind = .kw_function;
                if (!advanceLocal(s)) return false;
                continue;
            }
            if ((kind == .slash or kind == .div_assign) and
                (lookahead.skipRegexpInPredeclareScan(s, previous_token_kind) catch false))
            {
                eval_candidate = false;
                previous_token_kind = .regexp;
                if (!advanceLocal(s)) return false;
                continue;
            }

            if (eval_candidate and kind == .lparen) return true;
            if (kind == .rparen and
                eval_candidate and
                grouped_eval_candidate and
                paren_depth > 0)
            {
                paren_depth -= 1;
                previous_token_kind = kind;
                if (!advanceLocal(s)) return false;
                continue;
            }
            if (kind == .ident and
                !s.token.payload.ident.has_escape and
                identifiers.atomNameEquals(s, s.token.payload.ident.atom, "eval") and
                previous_token_kind != .dot)
            {
                eval_candidate = true;
                grouped_eval_candidate = previous_token_kind == .lparen;
            } else {
                eval_candidate = false;
                grouped_eval_candidate = false;
            }

            switch (kind) {
                .lparen => paren_depth += 1,
                .rparen => {
                    if (paren_depth == 0) return false;
                    paren_depth -= 1;
                },
                .lbracket => bracket_depth += 1,
                .rbracket => {
                    if (bracket_depth == 0) return false;
                    bracket_depth -= 1;
                },
                .lbrace => brace_depth += 1,
                .rbrace => {
                    if (brace_depth == 0) return false;
                    brace_depth -= 1;
                },
                .comma, .semicolon => if (paren_depth == 0 and bracket_depth == 0 and brace_depth == 0) return false,
                else => {},
            }
            previous_token_kind = kind;
            if (!advanceLocal(s)) return false;
        }
    }

    fn templateContainsDirectEval(s: *State, first: tok.Token) bool {
        const first_part = first.payload.str.template orelse return false;
        switch (first_part) {
            .no_substitution, .tail => return false,
            .head, .middle => {},
        }

        while (true) {
            var expr_depth: usize = 0;
            var previous_token_kind: ?tok.TokenKind = .lbrace;
            var eval_candidate = false;
            while (true) {
                var scan_token = s.lex.next() catch return false;
                defer s.lex.freeToken(&scan_token);
                const kind = scan_token.val;
                if (kind == .eof) return false;
                if (kind == .kw_function) {
                    lookahead.skipFunctionInPredeclareScan(s) catch return false;
                    eval_candidate = false;
                    previous_token_kind = .kw_function;
                    continue;
                }
                if (kind == .template) {
                    if (templateContainsDirectEval(s, scan_token)) return true;
                    eval_candidate = false;
                    previous_token_kind = .template;
                    continue;
                }
                if ((kind == .slash or kind == .div_assign) and
                    (lookahead.skipRegexpInPredeclareScan(s, previous_token_kind) catch false))
                {
                    eval_candidate = false;
                    previous_token_kind = .regexp;
                    continue;
                }
                if (eval_candidate and kind == .lparen) return true;
                if (kind == .ident and
                    !scan_token.payload.ident.has_escape and
                    identifiers.atomNameEquals(s, scan_token.payload.ident.atom, "eval") and
                    previous_token_kind != .dot)
                {
                    eval_candidate = true;
                } else {
                    eval_candidate = false;
                }

                switch (kind) {
                    .lbrace, .lparen, .lbracket => expr_depth += 1,
                    .rbrace, .rparen, .rbracket => {
                        if (kind == .rbrace and expr_depth == 0) break;
                        if (expr_depth == 0) return false;
                        expr_depth -= 1;
                    },
                    else => {},
                }
                previous_token_kind = kind;
            }

            var next_part: tok.Token = undefined;
            s.lex.nextTemplatePartAfterBraceInto(&next_part) catch return false;
            defer s.lex.freeToken(&next_part);
            const part = next_part.payload.str.template orelse return false;
            switch (part) {
                .tail, .no_substitution => return false,
                .head, .middle => {},
            }
        }
    }

    /// Check if the current token is an identifier with the given name
    pub inline fn isIdent(s: *State, name: []const u8) bool {
        if (s.peekKind() != .ident) return false;
        if (s.token.payload.ident.has_escape) return false;
        const ident_str = s.lex.atoms.name(s.token.payload.ident.atom) orelse return false;
        return std.mem.eql(u8, ident_str, name);
    }

    /// QuickJS `token_is_pseudo_keyword(s, JS_ATOM_async)`: contextual
    /// keyword recognition is an atom identity check, not an atom-name
    /// lookup on every ordinary identifier.
    pub inline fn isAsyncIdentifier(s: *State) bool {
        return s.peekKind() == .ident and
            !s.token.payload.ident.has_escape and
            s.token.payload.ident.atom == atom_module.ids.async_;
    }

    /// TypeScript parameter-property modifier at the current token. The
    /// word is a modifier only when a binding follows it, so a parameter
    /// named `readonly` still parses.
    pub fn isParameterModifier(s: *State) bool {
        const k = s.peekKind();
        var is_word = k == .kw_public or k == .kw_private or k == .kw_protected;
        if (!is_word and k == .ident and !s.token.payload.ident.has_escape) {
            const ident_str = s.lex.atoms.name(s.token.payload.ident.atom) orelse return false;
            is_word = std.mem.eql(u8, ident_str, "public") or
                std.mem.eql(u8, ident_str, "private") or
                std.mem.eql(u8, ident_str, "protected") or
                std.mem.eql(u8, ident_str, "readonly") or
                std.mem.eql(u8, ident_str, "override");
        }
        if (!is_word) return false;
        const next = s.peekNextKind();
        return typescript.tsKindIsIdentifierLike(next) or next == .kw_this or next == .lbrace or next == .lbracket or
            next == .ellipsis or next == .kw_public or next == .kw_private or
            next == .kw_protected;
    }

    pub fn isOfToken(s: *State) bool {
        return s.peekKind() == .kw_of or s.isIdent("of");
    }

    pub fn canTreatLetAsForInitializerExpression(s: *State) bool {
        if (s.peekKind() != .kw_let) return false;
        // qjs calls is_let(s, DECL_MASK_OTHER) for the for-initializer and
        // the for-in/of head.
        return statements.canTreatLetAsExpressionStatement(s, DeclMask{ .other = true });
    }

    pub fn markDirectEvalCall(self: *State) Error!void {
        const fd = self.curFunc();
        fd.has_eval_call = true;
    }

    /// qjs js_parse_function_decl2: emit the child
    /// closure with its parent constant-pool index. Always the wide form:
    /// phase-1 temporary opcodes overlap the short-opcode range that
    /// contains fclosure8, so resolve_labels shortens it after the temp
    /// opcodes have been erased.
    pub fn emitFClosure(self: *State, idx: u32) Error!void {
        try Emitter.opU32(self, opcode.op.fclosure, idx);
    }

    pub fn emitCloseLoc(self: *State, idx: u16) Error!void {
        // qjs close_scopes emits this phase-1 cleanup without a
        // source marker.
        try Emitter.opU16NoSource(self, opcode.op.close_loc, idx);
    }

    /// Mirror the `OP_enter_scope` emission of QuickJS `push_scope`
    ///. `resolve_variables` lowers this temp opcode
    /// to a per-scope binding refresh (TDZ re-arm + captured-slot
    /// detach, see `enterScopeRefreshSize`) so block-scoped bindings
    /// are fresh on every scope entry — the per-iteration semantics of
    /// lexicals declared inside loop bodies.
    ///
    pub fn emitEnterScope(self: *State) Error!void {
        if (self.scope_level < 0) return;
        // qjs push_scope emits the phase-1 marker with no source
        // event.
        try Emitter.opU16NoSource(self, opcode.op.enter_scope, @intCast(self.scope_level));
    }

    pub fn emitLeaveScope(self: *State, scope: i32) Error!void {
        if (scope < 0) return;
        // qjs pop_scope/close_scopes emits the phase-1 marker with no
        // source event.
        try Emitter.opU16NoSource(self, opcode.op.leave_scope, @intCast(scope));
    }

    /// Emit the same lexical-exit chain as QuickJS `close_scopes` without
    /// changing parser scope state. `scope_stop` remains active.
    pub fn closeScopes(self: *State, start_scope: i32, scope_stop: i32) Error!void {
        var scope = start_scope;
        while (scope > scope_stop) {
            if (@as(usize, @intCast(scope)) >= self.curFunc().scopes.len) return error.ParserInvariant;
            try self.emitLeaveScope(scope);
            scope = self.curFunc().scopes[@intCast(scope)].parent;
        }
    }

    // ---- Temporary scope opcode helpers ----
    // These emit scope_* opcodes that will be lowered by resolve_variables.
    // One outlined walk: leftover candidate35 still had five ~294 B
    // emitScope* copies (extra 1176). Opcode pair and source flag stay
    // runtime so LLVM cannot reconstruct the typed twins.

    noinline fn emitScopeVar(
        self: *State,
        atom_id: Atom,
        scope_op: u8,
        attach_source: bool,
    ) Error!void {
        const scope_level: u16 = @intCast(self.scope_level);
        if (attach_source) {
            // qjs resolve_scope_var consumes the same atom+scope temp
            // family.
            try Emitter.opAtomU16(self, scope_op, atom_id, scope_level);
        } else {
            try Emitter.opAtomU16NoSource(self, scope_op, atom_id, scope_level);
        }
    }

    pub inline fn emitScopeGetVar(self: *State, atom_id: Atom) Error!void {
        return self.emitScopeVar(atom_id, opcode.op.scope_get_var, true);
    }

    pub inline fn emitScopeGetVarCheckThis(self: *State, atom_id: Atom) Error!void {
        return self.emitScopeVar(atom_id, opcode.op.scope_get_var_checkthis, true);
    }

    pub inline fn emitScopePutVar(self: *State, atom_id: Atom) Error!void {
        return self.emitScopeVar(atom_id, opcode.op.scope_put_var, true);
    }

    pub inline fn emitScopePutVarNoSource(self: *State, atom_id: Atom) Error!void {
        return self.emitScopeVar(atom_id, opcode.op.scope_put_var, false);
    }

    pub inline fn emitScopeGetVarUndef(self: *State, atom_id: Atom) Error!void {
        return self.emitScopeVar(atom_id, opcode.op.scope_get_var_undef, true);
    }

    /// Emit `scope_put_var_init` for `let` / `const` initialisers.
    /// Mirrors `quickjs.c` (scope init form). The pipeline
    /// lowers this to `put_loc` when the var resolves locally, or
    /// to `put_var_init` when it's a top-level lexical global.
    pub inline fn emitScopePutVarInit(self: *State, atom_id: Atom) Error!void {
        return self.emitScopeVar(atom_id, opcode.op.scope_put_var_init, true);
    }

    pub inline fn emitScopePutVarInitNoSource(self: *State, atom_id: Atom) Error!void {
        return self.emitScopeVar(atom_id, opcode.op.scope_put_var_init, false);
    }

    pub fn emitThisValue(self: *State) Error!void {
        // qjs TOK_THIS always emits OP_scope_get_var this. Explicit `this`
        // reads use the ordinary lexical check and therefore create a TDZ
        // ReferenceError in the constructor's own realm; the caller-realm
        // checkthis opcode is reserved for the synthetic derived-return
        // fallback in emitReturnValue. Direct eval has no own ThisBinding
        // and resolves against the caller seed, so a root-eval-captured
        // `this` cannot shadow the method's this.
        try self.emitScopeGetVar(atom_this);
    }

    pub fn emitBigIntLiteral(self: *State, text: []const u8, negate: bool) Error!void {
        if (expressions.parseBigIntI32(text, negate)) |small| {
            try Emitter.opI32(self, opcode.op.push_bigint_i32, small);
            return;
        }

        const parse_text = if (std.mem.indexOfScalar(u8, text, '_')) |_| blk: {
            var normalized = std.ArrayList(u8).empty;
            errdefer normalized.deinit(self.scratch);
            for (text) |ch| {
                if (ch != '_') try normalized.append(self.scratch, ch);
            }
            break :blk try normalized.toOwnedSlice(self.scratch);
        } else text;
        defer if (parse_text.ptr != text.ptr) self.scratch.free(parse_text);

        var parsed = libs_bignum.parseAutoAlloc(self.persistent, parse_text) catch return Error.InvalidNumberLiteral;
        errdefer parsed.deinit();
        if (negate and !parsed.isZero()) parsed.negative = !parsed.negative;

        // Reserved (unregistered) heap BigInt: no GC list membership until
        // the owning FunctionBytecode is published
        // (`BigInt.registerReservedValue`), so a collection during the rest
        // of the parse can neither sweep nor need to trace it. The parser
        // carries the allocation owner explicitly in its parse state; no
        // allocator context is interpreted as a Runtime.
        const big = try core_bigint.BigInt.createExternalReserved(self.allocation_runtime);
        big.initExternalFromOwned(parsed);
        parsed = .{ .allocator = self.persistent };
        errdefer big.destroyExternalReserved(self.allocation_runtime);
        try Emitter.pushConst(self, big.valueRef());
    }

    pub fn invalidateLastOpcode(self: *State) void {
        self.activeBuilder().invalidateLastOpcode();
    }

    // State-level wrappers over compiler.Builder. Marker precedes opcode.

    /// Builder of the function currently being parsed. The unwrap fails
    /// if this FunctionDef never began emission.
    pub fn activeBuilder(self: *State) *compiler.Builder {
        return self.curFunc().builder.?;
    }

    /// Give `fd` its Builder (idempotent). Every FunctionDef emitted
    /// into during a parse owns one.
    pub fn ensureBuilderForFd(self: *State, fd: *function_def_mod.FunctionDef) compiler.builder.Error!void {
        _ = self;
        if (fd.builder == null) {
            const v2b = try fd.allocator.create(compiler.Builder);
            v2b.* = compiler.Builder.init(fd.allocator, fd.atoms);
            fd.builder = v2b;
        }
    }

    /// TEST HOOK: begin emission for the current function, allocating its
    /// Builder on first use.
    pub fn beginBuilderEmissionForTest(self: *State) compiler.builder.Error!void {
        try self.ensureBuilderForFd(self.curFunc());
    }

    /// Start a production program root. `initRootEmitter` established the
    /// body-scope identity before any Builder existed, so emit that one
    /// enter event into the freshly attached builder.
    pub fn beginProgramEmission(self: *State) compiler.builder.Error!void {
        try self.ensureBuilderForFd(self.curFunc());
        if (self.curFunc().body_scope < 0) return error.InvalidBytecode;
        const v2b = self.activeBuilder();
        const snapshot = v2b.snapshot();
        errdefer v2b.rollback(snapshot);
        // qjs push_scope emits OP_enter_scope without a source event
        // before js_parse_program.
        try v2b.emitOpU16(opcode.op.enter_scope, @intCast(self.curFunc().body_scope));
    }
    // ===== end Builder wrappers =====

};

/// Chain-exit label identity for `?.`.
pub const OptionalChainLabel = compiler.LabelId;

/// Finally-target identity for gosub emission.
pub const FinallyLabel = compiler.LabelId;

pub const atom_default: Atom = Atom.fromRaw(22); // "default"

pub const atom_star_default: Atom = Atom.fromRaw(127); // "*default*"

pub const atom_star: Atom = Atom.fromRaw(128); // "*"

pub const ParseState = State;

pub const Feature = FeatureImpl;

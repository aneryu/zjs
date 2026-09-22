//! Owns parser diagnostics, token-to-bytecode lowering, and module syntax.
pub const subsystem_name = "parser";
pub const diagnostics = struct {
    const std = @import("std");
    const atom = @import("core/atom.zig");

    pub const Position = struct {
        offset: usize = 0,
        line: u32 = 1,
        column: u32 = 1,
    };

    pub const SyntaxError = struct {
        memory: std.mem.Allocator,
        atoms: *atom.AtomTable,
        message: []u8,
        filename: atom.Atom = atom.null_atom,
        position: Position,

        pub fn create(allocator: std.mem.Allocator, atoms: *atom.AtomTable, filename: atom.Atom, position: Position, message: []const u8) !SyntaxError {
            const owned: []u8 = if (message.len == 0) &.{} else try allocator.alloc(u8, message.len);
            errdefer if (owned.len != 0) allocator.free(owned);
            if (message.len != 0) @memcpy(owned, message);
            return .{
                .memory = allocator,
                .atoms = atoms,
                .message = owned,
                .filename = filename,
                .position = position,
            };
        }

        pub fn deinit(self: *SyntaxError) void {
            const message = self.message;
            self.filename = atom.null_atom;
            self.message = &.{};
            if (message.len != 0) self.memory.free(message);
        }
    };

    pub fn advance(position: *Position, byte: u8) void {
        position.offset += 1;
        if (byte == '\n') {
            position.line += 1;
            position.column = 1;
        } else {
            position.column += 1;
        }
    }
};

pub const token = @import("token.zig");

pub const lexer = @import("lexer.zig");

const mem_ops = @import("core/memory.zig");
const parse_state = @import("parser/parse_state.zig");
const declarations = @import("parser/declarations.zig");
const closure = @import("parser/closure.zig");
const identifiers = @import("parser/identifiers.zig");
const lookahead = @import("parser/lookahead.zig");
const emitter = @import("parser/emitter.zig");
const expressions = @import("parser/expressions.zig");
const statements = @import("parser/statements.zig");
const functions = @import("parser/functions.zig");
const classes = @import("parser/classes.zig");
const modules = @import("parser/modules.zig");
const typescript = @import("parser/typescript.zig");

pub const parser_core = struct {
    //! The parser modules under `src/parser/`, re-exported for the compile
    //! entry, the tests, and embedders that spell `parser.Parser.<name>`.
    pub const declarations = @import("parser/declarations.zig");
    pub const closure = @import("parser/closure.zig");
    pub const BlockEnv = parse_state.BlockEnv;
    pub const DeclMask = parse_state.DeclMask;
    pub const Error = parse_state.Error;
    pub const Feature = parse_state.Feature;
    pub const FeatureImpl = parse_state.FeatureImpl;
    pub const ParseFlags = parse_state.ParseFlags;
    pub const ParseFunctionKind = parse_state.ParseFunctionKind;
    pub const ParseState = parse_state.ParseState;
    pub const PendingDiagnostic = parse_state.PendingDiagnostic;
    pub const State = parse_state.State;
    pub const Emitter = emitter.Emitter;
    pub const TaggedTemplateBuilderTestHook = expressions.TaggedTemplateBuilderTestHook;
    pub const emitPlainTailForTest = emitter.emitPlainTailForTest;
    pub const isLiveCode = emitter.isLiveCode;
    pub const parseAssignExpr = expressions.parseAssignExpr;
    pub const parseAssignExpr2 = expressions.parseAssignExpr2;
    pub const parseBlock = statements.parseBlock;
    pub const parseCoalesceExpr = expressions.parseCoalesceExpr;
    pub const parseCondExpr = expressions.parseCondExpr;
    pub const parseDirectives = statements.parseDirectives;
    pub const parseExpr = expressions.parseExpr;
    pub const parseExpr2 = expressions.parseExpr2;
    pub const parseExprBinary = expressions.parseExprBinary;
    pub const parseLhsExpr = expressions.parseLhsExpr;
    pub const parseLogicalAndOr = expressions.parseLogicalAndOr;
    pub const parsePostfixExpr = expressions.parsePostfixExpr;
    pub const parseProgramStatements = statements.parseProgramStatements;
    pub const parseStatementOrDecl = statements.parseStatementOrDecl;
    pub const parseUnary = expressions.parseUnary;
    pub const validateModuleLocalExports = modules.validateModuleLocalExports;
};
pub const compile_entry = struct {
    const std = @import("std");
    const platform_clock = @import("platform_clock.zig");

    const atom = @import("core/atom.zig");
    const JSRuntime = @import("core/runtime.zig").JSRuntime;
    const JSValue = @import("core/value.zig").JSValue;
    const bytecode = @import("bytecode.zig");
    const compiler = @import("compiler/root.zig");
    const unicode = @import("libs/unicode.zig");
    const lexer_mod = lexer;
    const parser_impl = parser_core;
    const token_mod = token;
    const diagnostics_mod = diagnostics;

    const ModeImpl = enum {
        script,
        module,
        eval_direct,
        eval_indirect,
    };

    const FeatureImpl = parser_core.FeatureImpl;

    const CompilePathImpl = enum {
        normal,
        syntax_error_guard,
    };

    /// Move-only module compilation product. The FunctionBytecode and module
    /// record are the two independently owned halves of one canonical module
    /// root; no parser Bytecode or arena storage escapes compilation.
    const ModuleArtifactImpl = struct {
        function_bytecode: *bytecode.FunctionBytecode,
        record: bytecode.module.Record,

        pub fn deinit(self: *ModuleArtifactImpl) void {
            self.record.deinit();
        }
    };

    /// Exactly one successful root artifact. Script/direct/indirect eval own a
    /// canonical FunctionBytecode directly; modules own the same canonical
    /// root together with their linking metadata.
    const RootArtifactImpl = union(enum) {
        none,
        function_bytecode: *bytecode.FunctionBytecode,
        module: ModuleArtifactImpl,
    };

    const ResultImpl = struct {
        artifact: RootArtifactImpl = .none,
        mode: ModeImpl,
        parse_path: CompilePathImpl = .normal,
        features: std.EnumSet(FeatureImpl) = .initEmpty(),
        syntax_error: ?diagnostics_mod.SyntaxError = null,
        direct_eval: bool = false,

        pub fn deinit(self: *ResultImpl) void {
            if (self.syntax_error) |*err| err.deinit();
            switch (self.artifact) {
                .none, .function_bytecode => {},
                .module => |owned| {
                    var artifact = owned;
                    artifact.deinit();
                },
            }
            self.artifact = .none;
        }

        pub fn functionBytecode(self: *const ResultImpl) ?*const bytecode.FunctionBytecode {
            return switch (self.artifact) {
                .function_bytecode => |fb| fb,
                .module => |artifact| artifact.function_bytecode,
                .none => null,
            };
        }

        /// Move the sole canonical ordinary root artifact out of this result.
        /// The returned FunctionBytecode value is owned by the caller and the
        /// Result becomes empty, so `deinit` cannot release a second reference.
        /// This is the producer-side ownership transfer consumed by root
        /// js_closure2; borrowed inspection remains available through
        /// `functionBytecode`.
        pub fn takeFunctionBytecodeValue(self: *ResultImpl) ?JSValue {
            const fb = switch (self.artifact) {
                .function_bytecode => |owned| owned,
                else => return null,
            };
            self.artifact = .none;
            return JSValue.functionBytecode(&fb.header);
        }

        pub fn byteCode(self: *const ResultImpl) []const u8 {
            const fb = self.functionBytecode() orelse return &.{};
            return fb.byteCode();
        }

        pub fn constants(self: *const ResultImpl) []const JSValue {
            const fb = self.functionBytecode() orelse return &.{};
            return fb.cpoolSlice();
        }

        pub fn closureVars(self: *const ResultImpl) []const bytecode.function_bytecode.BytecodeClosureVar {
            const fb = self.functionBytecode() orelse return &.{};
            return fb.closureVar();
        }

        pub fn varDefs(self: *const ResultImpl) []const bytecode.function_bytecode.BytecodeVarDef {
            const fb = self.functionBytecode() orelse return &.{};
            return fb.varDefs();
        }

        pub fn openVarRefCount(self: *const ResultImpl) u16 {
            const fb = self.functionBytecode() orelse return 0;
            return fb.openVarRefCount();
        }

        pub fn filenameAtom(self: *const ResultImpl) atom.Atom {
            const fb = self.functionBytecode() orelse return atom.null_atom;
            return fb.filenameAtom();
        }

        pub fn scriptOrModuleAtom(self: *const ResultImpl) atom.Atom {
            const fb = self.functionBytecode() orelse return atom.null_atom;
            return fb.scriptOrModule();
        }

        pub fn entryContract(self: *const ResultImpl) bytecode.EntryContract {
            const fb = self.functionBytecode() orelse return .{};
            return .{
                .new_target_allowed = fb.newTargetAllowed(),
                .super_call_allowed = fb.superCallAllowed(),
                .super_allowed = fb.superAllowed(),
                .arguments_allowed = fb.argumentsAllowed(),
            };
        }

        pub fn isStrict(self: *const ResultImpl) bool {
            const fb = self.functionBytecode() orelse return false;
            return fb.isStrictMode();
        }

        pub fn isGlobalVar(self: *const ResultImpl) bool {
            return switch (self.artifact) {
                .none => false,
                else => switch (self.mode) {
                    .script, .module => true,
                    .eval_direct, .eval_indirect => !self.isStrict(),
                },
            };
        }

        pub fn isDirectOrIndirectEval(self: *const ResultImpl) bool {
            const fb = self.functionBytecode() orelse return false;
            return fb.isDirectOrIndirectEval();
        }

        pub fn isModule(self: *const ResultImpl) bool {
            return self.mode == .module;
        }

        pub fn moduleArtifact(self: *const ResultImpl) ?*const ModuleArtifactImpl {
            return switch (self.artifact) {
                .module => &self.artifact.module,
                else => null,
            };
        }

        pub fn moduleRecord(self: *const ResultImpl) ?*const bytecode.module.Record {
            const artifact = self.moduleArtifact() orelse return null;
            return &artifact.record;
        }

        /// Move the canonical module root and its record out together. The
        /// Result becomes empty before returning, preventing either owner from
        /// being released twice.
        pub fn takeModuleArtifact(self: *ResultImpl) ?ModuleArtifactImpl {
            const artifact = switch (self.artifact) {
                .module => |owned| owned,
                else => return null,
            };
            self.artifact = .none;
            return artifact;
        }

        pub fn hasFeature(self: ResultImpl, feature: FeatureImpl) bool {
            return self.features.contains(feature);
        }
    };

    const EvalClosureSeedImpl = struct {
        var_name: atom.Atom,
        closure_type: bytecode.function_def.ClosureType = .ref,
        var_idx: ?u16 = null,
        is_lexical: bool = false,
        is_const: bool = false,
        var_kind: bytecode.function_def.VarKind = .normal,
    };

    const OptionsImpl = struct {
        mode: ModeImpl = .script,
        filename: []const u8 = "<input>",
        /// Borrowed stable ScriptOrModule identity. Direct eval supplies its
        /// caller's owned atom while retaining "<eval>" as `filename`.
        script_or_module: ?atom.Atom = null,
        strict: bool = false,
        return_completion: bool = false,
        eval_global_var_bindings: bool = false,
        eval_in_parameter_initializer: bool = false,
        eval_allows_new_target: bool = false,
        eval_allows_super_call: bool = false,
        eval_allows_super_property: bool = false,
        eval_arguments_allowed: bool = false,
        eval_annex_b_blocked_function_names: []const atom.Atom = &.{},
        eval_closure_seed: []const EvalClosureSeedImpl = &.{},
    };

    fn isPrivateEvalClosureKind(kind: bytecode.function_def.VarKind) bool {
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

    fn isPrivateSetterCompanion(atoms: *const atom.AtomTable, seed: EvalClosureSeedImpl) bool {
        if (seed.var_kind != .private_setter) return false;
        const name = atoms.name(seed.var_name) orelse return false;
        return std.mem.endsWith(u8, name, "<set>");
    }

    fn restoreDirectEvalPrivateBoundNames(
        rt: *JSRuntime,
        state: *parser_impl.ParseState,
        seeds: []const EvalClosureSeedImpl,
    ) !void {
        var restored_any = false;
        // Runtime closure lookup is nearest-first, while parser private-name
        // lookup walks this list from its tail. Reverse once to preserve the
        // same shadowing order without a second metadata carrier.
        var index = seeds.len;
        while (index > 0) {
            index -= 1;
            const seed = seeds[index];
            if (!isPrivateEvalClosureKind(seed.var_kind) or isPrivateSetterCompanion(&rt.atoms, seed)) continue;

            var already_restored = false;
            for (state.class_private_bound_names.items) |existing| {
                if (existing == seed.var_name) {
                    already_restored = true;
                    break;
                }
            }
            if (already_restored) continue;

            const retained = seed.var_name;
            state.class_private_bound_names.append(state.scratch, retained) catch |err| {
                return err;
            };
            restored_any = true;
        }
        if (restored_any) state.class.in_body = true;
    }

    fn elapsedNanosSince(start: u64) u64 {
        const end = platform_clock.monotonicNanos();
        return if (end > start) end - start else 0;
    }

    pub fn compile(compile_context: bytecode.CompileContext, source: []const u8, options: OptionsImpl) !ResultImpl {
        const rt = compile_context.realm.runtime;
        var arena = std.heap.ArenaAllocator.init(rt.nativeAllocator());
        var arena_owned = true;
        errdefer if (arena_owned) arena.deinit();

        // TGC S3-b §2.2: interval root for every atom the front end obtains.
        // The whole chain -- filename atom, lexer tokens, FunctionDef tables,
        // builder/resolve_* passes, up to the published FunctionBytecode --
        // parks its ids in plain `u32` fields no scan can see, so the scope is
        // opened here (before the first intern) and closed only after the
        // artifact that carries its own tracer edges exists. Recording is
        // ambient (`AtomTable.compile_scope`), so no call site changes.
        var atom_scope = atom.CompileAtomScope.init(&rt.atoms);
        defer atom_scope.deinit();
        try atom_scope.activate();

        const filename_atom = try rt.internAtom(options.filename);
        // QuickJS learns directive strictness while parsing the directive
        // prologue. Only an explicit host option is known before tokenization;
        // comments and source substrings are never a second strictness source.
        // JSX is not part of the grammar: `.tsx` / `.jsx` sources are
        // rejected up front instead of failing on the first `<tag>`.
        if (std.mem.endsWith(u8, options.filename, ".tsx") or std.mem.endsWith(u8, options.filename, ".jsx")) {
            var result = ResultImpl{
                .mode = options.mode,
                .direct_eval = options.mode == .eval_direct,
            };
            result.syntax_error = try diagnostics_mod.SyntaxError.create(
                rt.nativeAllocator(),
                &rt.atoms,
                filename_atom,
                .{ .line = 1, .column = 1, .offset = 0 },
                "JSX is not supported",
            );
            result.parse_path = .syntax_error_guard;
            arena.deinit();
            arena_owned = false;
            return result;
        }

        var features = std.EnumSet(FeatureImpl).initEmpty();
        var pending_diagnostic: ?parser_impl.PendingDiagnostic = null;

        var module_record: ?bytecode.module.Record = null;
        errdefer if (module_record) |*record| record.deinit();
        const canonical_root = compileQjsProgram(rt, arena.allocator(), source, options, compile_context, filename_atom, &module_record, &features, &pending_diagnostic) catch |err| switch (err) {
            error.OutOfMemory => return err,
            // qjs:libregexp.c and quickjs.c js_parse_error "stack overflow"
            error.StackOverflow => {
                var result = ResultImpl{
                    .mode = options.mode,
                    .direct_eval = options.mode == .eval_direct,
                };
                if (pending_diagnostic) |pending| {
                    try setPendingSyntaxError(&result, rt, filename_atom, &pending);
                } else {
                    try setFallbackSyntaxError(&result, rt, arena.allocator(), filename_atom, source, "stack overflow");
                }
                arena.deinit();
                arena_owned = false;
                return result;
            },
            else => {
                var result = ResultImpl{
                    .mode = options.mode,
                    .direct_eval = options.mode == .eval_direct,
                };
                if (isInternalCompilerError(err)) {
                    try setInternalCompilerError(&result, rt, filename_atom, err);
                } else if (pending_diagnostic) |pending| {
                    try setPendingSyntaxError(&result, rt, filename_atom, &pending);
                } else {
                    try setFallbackSyntaxError(&result, rt, arena.allocator(), filename_atom, source, @errorName(err));
                }
                arena.deinit();
                arena_owned = false;
                return result;
            },
        };
        var result = ResultImpl{
            .mode = options.mode,
            .direct_eval = options.mode == .eval_direct,
            .features = features,
        };
        if (options.mode == .module) {
            const record = module_record orelse return error.InvalidBytecode;
            module_record = null;
            result.artifact = .{ .module = .{
                .function_bytecode = canonical_root,
                .record = record,
            } };
        } else {
            result.artifact = .{ .function_bytecode = canonical_root };
        }
        arena.deinit();
        arena_owned = false;
        result.parse_path = .normal;
        return result;
    }

    fn compileQjsProgram(
        rt: *JSRuntime,
        scratch: std.mem.Allocator,
        source: []const u8,
        options: OptionsImpl,
        compile_context: bytecode.CompileContext,
        filename_atom: atom.Atom,
        module_record_out: *?bytecode.module.Record,
        features: *std.EnumSet(FeatureImpl),
        pending_diagnostic: *?parser_impl.PendingDiagnostic,
    ) !*bytecode.FunctionBytecode {
        const frontend_start = if (compile_context.timing != null) platform_clock.monotonicNanos() else 0;
        const effective_strict = options.strict;
        var lex = lexer_mod.Lexer.init(scratch, &rt.atoms, source);
        defer lex.deinit();
        lex.is_strict_mode = options.mode == .module or effective_strict;
        lex.is_module = options.mode == .module;
        var state = try parser_core.ParseState.initWithRuntime(rt, &lex, filename_atom);
        state.scratch = scratch;
        defer state.deinit(rt);
        if (options.script_or_module) |script_or_module| state.function_def.script_or_module = script_or_module;
        // TGC S3-b: the parse's own interval roots (atoms + cpool values),
        // nested inside the scope `compile` opened.
        try state.activateCompileRoots();
        errdefer pending_diagnostic.* = state.pending_diagnostic;
        state.is_strict = options.mode == .module or effective_strict;
        // QuickJS creates the root program FunctionDef as eval bytecode for all
        // four compile modes; eval_type/is_global_var then select declaration
        // placement. Keep parser State.is_eval separate because it controls
        // completion-value parsing rather than FunctionDef construction.
        state.function_def.is_eval = true;
        state.function_def.is_module = options.mode == .module;
        state.function_def.is_direct_eval = options.mode == .eval_direct;
        state.function_def.is_global_var = switch (options.mode) {
            .script, .module => true,
            .eval_direct, .eval_indirect => !effective_strict,
        };
        state.function_def.is_strict_mode = options.mode == .module or effective_strict;
        state.function_def.is_indirect_eval = options.mode == .eval_indirect;
        state.function_def.has_arguments_binding = false;
        state.function_def.has_this_binding = options.mode != .eval_direct;
        state.function_def.arguments_allowed = if (options.mode == .eval_direct) options.eval_arguments_allowed else true;
        // Script top-level let/const become global VarRef cells (qjs JS_CLOSURE_GLOBAL_DECL):
        // single-storage in ctx.lexicals, shared into frame.var_refs by pointer.
        state.top_level_lexical_as_global_ref = options.mode == .script;
        state.eval_global_var_bindings = (options.eval_global_var_bindings or options.mode == .eval_indirect) and
            !((options.mode == .eval_direct or options.mode == .eval_indirect) and effective_strict);
        state.eval_in_parameter_initializer = options.eval_in_parameter_initializer;
        state.ctx.new_target_allowed = options.eval_allows_new_target;
        state.function_def.new_target_allowed = options.eval_allows_new_target;
        state.ctx.allow_super_call = options.eval_allows_super_call;
        state.function_def.super_call_allowed = options.eval_allows_super_call;
        state.ctx.allow_super = options.eval_allows_super_property;
        state.function_def.super_allowed = options.eval_allows_super_property;
        state.eval_annex_b_blocked_function_names = options.eval_annex_b_blocked_function_names;
        for (options.eval_closure_seed) |seed| {
            _ = try state.function_def.addClosureVar(.{
                .closure_type = seed.closure_type,
                .is_lexical = seed.is_lexical,
                .is_const = seed.is_const,
                .var_kind = seed.var_kind,
                .var_idx = seed.var_idx orelse @as(u16, @intCast(state.function_def.closure_var.len)),
                .var_name = seed.var_name,
            });
        }
        if (options.mode == .eval_direct) {
            try restoreDirectEvalPrivateBoundNames(rt, &state, options.eval_closure_seed);
        }
        if (options.mode == .module) {
            state.ctx.in_async = true;
            state.top_level_lexical_as_module_ref = true;
            _ = state.ensureModule();
        }

        try state.beginProgramEmission();

        const return_completion = options.mode == .eval_direct or options.mode == .eval_indirect or options.return_completion;
        if (options.mode == .eval_direct or options.mode == .eval_indirect) {
            try state.enableEvalReturn();
        } else if (options.return_completion) {
            try state.enableReturnCompletion();
        }

        parser_core.parseDirectives(&state) catch |err| return state.propagateFailureHere(err);

        // qjs js_parse_program computes is_global_var after
        // js_parse_directives, once the function's JS_MODE_STRICT bit is
        // authoritative. Do the same here: directive parsing owns strictness,
        // then every declaration/capture policy consumes that single fact.
        const parsed_strict = options.mode == .module or state.is_strict or state.function_def.is_strict_mode;
        state.is_strict = parsed_strict;
        state.function_def.is_strict_mode = parsed_strict;
        state.function_def.is_global_var = switch (options.mode) {
            .script, .module => true,
            .eval_direct, .eval_indirect => !parsed_strict,
        };
        state.eval_global_var_bindings = (options.eval_global_var_bindings or options.mode == .eval_indirect) and
            !((options.mode == .eval_direct or options.mode == .eval_indirect) and parsed_strict);

        const decl_mask = parser_core.DeclMask{ .func = true, .func_with_label = true, .other = true };
        parser_core.parseProgramStatements(&state, decl_mask) catch |err| return state.propagateFailureHere(err);
        if (options.mode == .module) {
            parser_core.validateModuleLocalExports(&state) catch |err| return state.propagateFailureHere(err);
        }

        if (return_completion) {
            // Eval/script-completion form ends in `get_loc <ret>; return`.
            // Statement-level jumps patched before this epilogue land on the
            // completion load, so every reachable path terminates explicitly.
            try state.finalizeEvalReturn();
        } else {
            // Jump-aware terminator decision mirroring the function epilogues:
            // a label operand targeting the current end (post-lowering
            // `code_end`) must land on a real terminator — the dispatch has no
            // fall-off bounds check. The instruction walk also replaces the
            // former raw `code[code.len - 1]` opcode probe, whose last byte
            // could alias an operand of a multi-byte instruction.
            // qjs js_parse_program tail: js_is_live_code decides the implicit terminal.
            const needs_return = parser_core.isLiveCode(&state);
            if (needs_return) try state.emitReturnUndefined();
        }
        if (compile_context.timing) |timing| {
            timing.frontend_ns += elapsedNanosSince(frontend_start);
        }

        // Parser lists and the lexer use `scratch` (the compile arena).
        // FunctionDef buffers, module metadata, and published bytecode use
        // the runtime account directly, so the facade is not redirected.
        const finalize_start = if (compile_context.timing != null) platform_clock.monotonicNanos() else 0;
        const root_slice = try (if (options.mode == .module) blk: {
            const record = if (state.module_record) |*owned| owned else return error.InvalidBytecode;
            break :blk bytecode.pipeline.finalize.createModuleFunctionBytecode(
                &state.function_def,
                record,
                compile_context,
            );
        } else bytecode.pipeline.finalize.createFunctionBytecode(&state.function_def, compile_context));
        if (compile_context.timing) |timing| {
            timing.finalize_ns += elapsedNanosSince(finalize_start);
        }
        features.* = state.features;
        module_record_out.* = state.takeModuleRecord();
        return &root_slice[0];
    }

    fn setPendingSyntaxError(
        result: *ResultImpl,
        rt: *JSRuntime,
        filename_atom: atom.Atom,
        pending: *const parser_impl.PendingDiagnostic,
    ) !void {
        result.syntax_error = try diagnostics_mod.SyntaxError.create(
            rt.nativeAllocator(),
            &rt.atoms,
            filename_atom,
            pending.position,
            pending.message(),
        );
        result.parse_path = .syntax_error_guard;
    }

    fn isInternalCompilerError(err: anyerror) bool {
        return switch (err) {
            error.InvalidBytecode,
            error.BytecodeOverflow,
            error.InvalidTopology,
            error.InvalidOpcode,
            error.StackUnderflow,
            error.StackMismatch,
            error.ClosureVarNotFound,
            error.Pc2LineTruncated,
            error.Pc2LineOverflow,
            error.ParserInvariant,
            => true,
            else => false,
        };
    }

    comptime {
        if (!isInternalCompilerError(error.ParserInvariant))
            @compileError("ParserInvariant must use the internal compiler error reporting arm");
    }

    fn setInternalCompilerError(
        result: *ResultImpl,
        rt: *JSRuntime,
        filename_atom: atom.Atom,
        err: anyerror,
    ) !void {
        var message_buffer: [96]u8 = undefined;
        const message = std.fmt.bufPrint(
            &message_buffer,
            "internal compiler error: {s}",
            .{@errorName(err)},
        ) catch "internal compiler error";
        result.syntax_error = try diagnostics_mod.SyntaxError.create(
            rt.nativeAllocator(),
            &rt.atoms,
            filename_atom,
            .{ .line = 0, .column = 0, .offset = 0 },
            message,
        );
        result.parse_path = .syntax_error_guard;
    }

    fn setFallbackSyntaxError(
        result: *ResultImpl,
        rt: *JSRuntime,
        scratch: std.mem.Allocator,
        filename_atom: atom.Atom,
        source: []const u8,
        message: []const u8,
    ) !void {
        var lex = lexer_mod.Lexer.init(scratch, &rt.atoms, source);
        var pos = diagnostics_mod.Position{ .line = 1, .column = 1, .offset = 0 };
        var previous_token_kind: ?token_mod.TokenKind = null;
        while (true) {
            var tok: token_mod.Token = undefined;
            nextFallbackSyntaxTokenInto(&lex, &tok, previous_token_kind) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => {
                    result.syntax_error = try diagnostics_mod.SyntaxError.create(
                        rt.nativeAllocator(),
                        &rt.atoms,
                        filename_atom,
                        .{ .line = lex.mark_line, .column = lex.mark_col, .offset = lex.mark_pos },
                        parser_impl.State.decoratorDiagnosticMessage(source, err, lex.mark_pos) orelse @errorName(err),
                    );
                    result.parse_path = .syntax_error_guard;
                    return;
                },
            };
            pos = .{ .line = lex.line, .column = lex.col, .offset = lex.pos };
            if (tok.val == .eof) {
                lex.freeToken(&tok);
                break;
            }
            previous_token_kind = tok.val;
            lex.freeToken(&tok);
        }
        result.syntax_error = try diagnostics_mod.SyntaxError.create(rt.nativeAllocator(), &rt.atoms, filename_atom, pos, message);
        result.parse_path = .syntax_error_guard;
    }

    fn nextFallbackSyntaxTokenInto(lex: *lexer_mod.Lexer, out: *token_mod.Token, previous_token_kind: ?token_mod.TokenKind) lexer_mod.Error!void {
        try lex.nextInto(out);
        errdefer lex.freeToken(out);

        if ((out.val == .slash or out.val == .div_assign) and
            fallbackSlashStartsRegexp(previous_token_kind))
        {
            const slash_offset = lex.mark_pos;
            lex.freeToken(out);
            try lex.rescanRegexpInto(out, slash_offset);
        }
    }

    fn fallbackSlashStartsRegexp(previous_token_kind: ?token_mod.TokenKind) bool {
        const previous = previous_token_kind orelse return true;
        return switch (previous) {
            .lparen,
            .lbracket,
            .lbrace,
            .comma,
            .semicolon,
            .colon,
            .question,
            .assign,
            .bang,
            .tilde,
            .plus,
            .minus,
            .star,
            .percent,
            .amp,
            .pipe,
            .caret,
            .arrow,
            .lte,
            .gte,
            .eq,
            .strict_eq,
            .neq,
            .strict_neq,
            .shl,
            .sar,
            .shr,
            .land,
            .lor,
            .pow,
            .double_question_mark,
            .question_mark_dot,
            .mul_assign,
            .div_assign,
            .mod_assign,
            .plus_assign,
            .minus_assign,
            .shl_assign,
            .sar_assign,
            .shr_assign,
            .and_assign,
            .xor_assign,
            .or_assign,
            .pow_assign,
            .land_assign,
            .lor_assign,
            .double_question_mark_assign,
            .kw_return,
            .kw_case,
            .kw_throw,
            .kw_delete,
            .kw_void,
            .kw_typeof,
            .kw_new,
            .kw_in,
            .kw_instanceof,
            .kw_do,
            .kw_else,
            .kw_yield,
            .kw_await,
            => true,
            else => false,
        };
    }

    pub const Feature = FeatureImpl;
    pub const Mode = ModeImpl;
    pub const CompilePath = CompilePathImpl;
    pub const Result = ResultImpl;
    pub const ModuleArtifact = ModuleArtifactImpl;
    pub const RootArtifact = RootArtifactImpl;
    pub const Options = OptionsImpl;
    pub const EvalClosureSeed = EvalClosureSeedImpl;
    pub const CompileContext = bytecode.CompileContext;
    pub const CompilePolicy = bytecode.CompilePolicy;
};
pub const Lexer = lexer.Lexer;
pub const Token = token.Token;
pub const TokenKind = token.TokenKind;
pub const ParseState = parser_core.ParseState;
pub const Parser = parser_core;
pub const Mode = compile_entry.Mode;
pub const Feature = parser_core.Feature;
pub const CompilePath = compile_entry.CompilePath;
pub const Result = compile_entry.Result;
pub const ModuleArtifact = compile_entry.ModuleArtifact;
pub const RootArtifact = compile_entry.RootArtifact;
pub const Options = compile_entry.Options;
pub const EvalClosureSeed = compile_entry.EvalClosureSeed;
pub const CompileContext = compile_entry.CompileContext;
pub const CompilePolicy = compile_entry.CompilePolicy;
pub const compile = compile_entry.compile;

test "pending diagnostic preserves exact fields truncation replacement and OOM bypass" {
    const std = @import("std");
    // These operations own only pending_diagnostic. Deliberately leave the
    // unrelated parser machinery unavailable so the allocation-failure arms
    // cannot silently acquire a lexer/runtime dependency.
    var state: parser_core.State = undefined;
    state.pending_diagnostic = null;
    state.recordFailureHere(error.OutOfMemory);
    state.recordFailureHere(error.BytecodeOverflow);
    try std.testing.expect(state.pending_diagnostic == null);

    const position = diagnostics.Position{ .offset = 137, .line = 11, .column = 23 };
    var message = [_]u8{ 'e', 'x', 'p', 'e', 'c', 't', 'e', 'd', ' ', '\'', ')', '\'' };
    state.setPendingDiagnostic(error.UnexpectedToken, position, &message);
    message[0] = 'X';
    try std.testing.expectEqualDeep(position, state.pending_diagnostic.?.position);
    try std.testing.expectEqual(error.UnexpectedToken, state.pending_diagnostic.?.err);
    try std.testing.expectEqualStrings("expected ')'", state.pending_diagnostic.?.message());
    state.recordFailureHere(error.OutOfMemory);
    state.recordFailureHere(error.BytecodeOverflow);
    try std.testing.expectEqualDeep(position, state.pending_diagnostic.?.position);
    try std.testing.expectEqualStrings("expected ')'", state.pending_diagnostic.?.message());
    try std.testing.expectEqual(error.UnexpectedToken, state.propagateFailureHere(error.UnexpectedToken));

    var long_message: [parser_core.PendingDiagnostic.message_capacity + 17]u8 = undefined;
    for (&long_message, 0..) |*byte, i| byte.* = @intCast('!' + i % 90);
    const later = diagnostics.Position{ .offset = 271, .line = 31, .column = 47 };
    state.setPendingDiagnostic(error.SyntaxError, later, &long_message);
    try std.testing.expectEqualDeep(later, state.pending_diagnostic.?.position);
    try std.testing.expectEqual(error.SyntaxError, state.pending_diagnostic.?.err);
    try std.testing.expectEqualSlices(u8, long_message[0..parser_core.PendingDiagnostic.message_capacity], state.pending_diagnostic.?.message());
    state.setPendingDiagnostic(error.UnexpectedToken, position, "");
    try std.testing.expectEqualStrings("", state.pending_diagnostic.?.message());
    try std.testing.expectEqualDeep(position, state.pending_diagnostic.?.position);
}

test "pending diagnostic syntax error allocation propagates OOM" {
    const std = @import("std");
    const core = @import("core/root.zig");
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const account = try mem_ops.createTestRuntime(failing.allocator());
    defer account.destroy();
    var atoms = core.atom.AtomTable.init(account);
    defer atoms.deinit();
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, diagnostics.SyntaxError.create(
        account.nativeAllocator(),
        &atoms,
        core.atom.null_atom,
        .{ .offset = 137, .line = 11, .column = 23 },
        "expected ')', got '{'",
    ));
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expect(!mem_ops.hasOutstandingAllocations(account));
}

// Unified-suite tests only (`build_options.zjs_unified_test_suite`).
comptime {
    if (@import("builtin").is_test and @import("build_options").zjs_unified_test_suite) {
        _ = @import("parser/tests.zig");
    }
}

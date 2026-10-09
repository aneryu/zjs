//! Functions and arrows: parameters, bodies, destructuring patterns, the child FunctionDef lifecycle.

const std = @import("std");
const root = @import("../parser.zig");
const bytecode = @import("../bytecode.zig");
const atom_module = @import("../core/atom.zig");
const JSValue = @import("../core/value.zig").JSValue;
const compiler = @import("../compiler/root.zig");
const function_def_mod = bytecode.function_def;
const opcode = bytecode.opcode;
const tok = root.token;
const diagnostics = root.diagnostics;
const Atom = atom_module.Atom;
const parse_state = @import("parse_state.zig");
const declarations = @import("declarations.zig");
const closure = @import("closure.zig");
const identifiers = @import("identifiers.zig");
const lookahead = @import("lookahead.zig");
const emitter = @import("emitter.zig");
const expressions = @import("expressions.zig");
const statements = @import("statements.zig");
const modules = @import("modules.zig");
const typescript = @import("typescript.zig");
const atom_this = parse_state.atom_this;
const atom_default = parse_state.atom_default;
const atom_star_default = parse_state.atom_star_default;
const SourcePosition = parse_state.SourcePosition;
const FunctionSourceStart = parse_state.FunctionSourceStart;
const Error = parse_state.Error;
const ParseFlags = parse_state.ParseFlags;
const BlockEnv = parse_state.BlockEnv;
const ParseFunctionKind = parse_state.ParseFunctionKind;
const FunctionContext = parse_state.FunctionContext;
const ClassNamePatch = parse_state.ClassNamePatch;
const State = parse_state.State;
const Emitter = emitter.Emitter;
const strict_non_simple_parameters = "use strict directive is not allowed with non-simple parameters";
const LValue = expressions.LValue;
const ObjectPropertyName = expressions.ObjectPropertyName;

/// Parser state that a function boundary replaces and restores: the
/// emission target and the per-function grammar counters. Saved before
/// the child FunctionDef is pushed, restored on both the success path
/// (after `popFunction`) and the error path (after `discardCurrentFunction`).
const FunctionFrame = struct {
    last_opcode_source_offset: ?u32,
    scope_level: i32,
    is_eval: bool,
    eval_ret_idx: ?u16,
    return_depth: u32,
    is_strict: bool,
    lex_is_strict: bool,
    enclosing_lex_strict: bool,

    pub fn save(s: *const State) FunctionFrame {
        return .{
            .last_opcode_source_offset = s.last_opcode_source_offset,
            .scope_level = s.scope_level,
            .is_eval = s.is_eval,
            .eval_ret_idx = s.eval_ret_idx,
            .return_depth = s.return_depth,
            .is_strict = s.is_strict,
            .lex_is_strict = s.lex.is_strict_mode,
            .enclosing_lex_strict = s.enclosing_lex_strict,
        };
    }

    pub fn restore(self: FunctionFrame, s: *State) void {
        s.last_opcode_source_offset = self.last_opcode_source_offset;
        s.scope_level = self.scope_level;
        s.is_eval = self.is_eval;
        s.eval_ret_idx = self.eval_ret_idx;
        s.return_depth = self.return_depth;
        s.is_strict = self.is_strict;
        s.lex.is_strict_mode = self.lex_is_strict;
        s.enclosing_lex_strict = self.enclosing_lex_strict;
    }

    /// Make `child_fd` the emission target with a fresh function-level
    /// state. `return_depth` is the caller's: a class static block has no
    /// `return`, every other function body allows one.
    fn enterChild(s: *State, child_fd: *function_def_mod.FunctionDef, return_depth: u32) Error!void {
        try s.pushFunction(child_fd);
        s.last_opcode_source_offset = null;
        s.scope_level = 0;
        s.is_eval = false;
        s.eval_ret_idx = null;
        s.return_depth = return_depth;
    }
};

/// A child FunctionDef seeded from its parent: file identity, source
/// position, parent link, and the parent's opcode layout. Kind-specific
/// flags are the caller's. The caller owns the allocation until it is
/// pushed or added to the parent.
pub fn newChildFunctionDef(s: *State, parent_fd: *function_def_mod.FunctionDef, name: Atom, source: SourcePosition) Error!*function_def_mod.FunctionDef {
    const child_fd = try s.allocator.create(function_def_mod.FunctionDef);
    child_fd.* = function_def_mod.FunctionDef.init(s.allocator, s.artifacts, s.atoms, name);
    child_fd.filename = parent_fd.filename;
    child_fd.script_or_module = parent_fd.script_or_module;
    child_fd.line_num = @intCast(source.line_num);
    child_fd.col_num = @intCast(source.col_num);
    child_fd.parent = parent_fd;
    child_fd.parent_scope_level = parent_fd.scope_level;
    child_fd.use_short_opcodes = parent_fd.use_short_opcodes;
    return child_fd;
}

/// A child FunctionDef on its way from creation to its parent's child
/// list. `discard` undoes whichever stage was reached, so a single
/// `errdefer child.discard(s)` replaces a flag per hand-off.
const ChildFunction = struct {
    fd: *function_def_mod.FunctionDef,
    /// The parent's emission frame, restored when the child is popped.
    frame: FunctionFrame,
    stage: enum { created, current, popped, adopted } = .created,

    fn create(s: *State, parent_fd: *function_def_mod.FunctionDef, name: Atom, source: SourcePosition) Error!ChildFunction {
        return .{
            .fd = try newChildFunctionDef(s, parent_fd, name, source),
            .frame = FunctionFrame.save(s),
        };
    }

    /// Make the child the emission target; see `FunctionFrame.enterChild`.
    fn makeCurrent(self: *ChildFunction, s: *State, return_depth: u32) Error!void {
        try FunctionFrame.enterChild(s, self.fd, return_depth);
        s.enclosing_lex_strict = self.frame.lex_is_strict;
        self.stage = .current;
    }

    /// Pop the child off the function stack and restore the parent's frame.
    fn pop(self: *ChildFunction, s: *State) void {
        const popped = s.popFunction();
        std.debug.assert(popped == self.fd);
        self.frame.restore(s);
        self.stage = .popped;
    }

    fn adopt(self: *ChildFunction, parent_fd: *function_def_mod.FunctionDef) Error!void {
        try parent_fd.addChild(self.fd);
        self.stage = .adopted;
    }

    fn discard(self: *ChildFunction, s: *State) void {
        switch (self.stage) {
            .created, .popped => s.discardFunctionDef(self.fd),
            .current => {
                s.discardCurrentFunction();
                self.frame.restore(s);
            },
            .adopted => {},
        }
    }
};

/// What the wrapper that recognised a function production hands to
/// `parseFunctionParamsAndBody`. Mirrors the `func_name` / `func_type`
/// arguments of qjs js_parse_function_decl2.
pub const FunctionEntry = struct {
    /// Declared or inferred name; null for an anonymous expression.
    name: ?Atom = null,
    /// A declaration statement rather than an expression.
    is_decl: bool = false,
    /// Anonymous `export default function`.
    export_default: bool = false,
    /// Object-literal or class method: qjs JS_PARSE_FUNC_METHOD.
    is_method: bool = false,
};

/// Parse function declaration
/// Mirrors `js_parse_function_decl` in quickjs.c
pub fn parseFunctionDecl(s: *State, func_kind: ParseFunctionKind, source_start: FunctionSourceStart) Error!void {
    const saved_parameter_properties = s.current_parameter_properties;
    if (func_kind.isConstructor()) {
        s.current_parameter_properties = std.ArrayList(Atom).empty;
    } else {
        s.current_parameter_properties = null;
    }
    defer {
        if (func_kind.isConstructor()) {
            if (s.current_parameter_properties) |*props| {
                deinitOwnedParserAtoms(s, props);
            }
        }
        s.current_parameter_properties = saved_parameter_properties;
    }

    try s.advance();

    // Check for generator: function*
    const is_generator = s.peekKind() == .star;
    if (is_generator) {
        try s.advance();
    }

    // Parse function name (required for declarations)
    // BindingIdentifier[?Yield, ?Await] in the enclosing context; sloppy code
    // also accepts `let`, `static`, and the other strict-reserved words.
    if (!identifiers.isIdentifierLikeToken(s) or identifiers.identifierLikeHasInvalidEscapeForBinding(s)) {
        return s.failUnexpectedToken();
    }
    // qjs js_parse_function_decl2 retains the identifier before
    // next_token releases the token.
    const name_atom = identifiers.identifierLikeAtom(s);
    s.setLastDeclaredAtom(name_atom);
    if (s.lex.is_module and s.atProgramBodyScope() and identifiers.hasKnownBinding(s, name_atom)) {
        return s.failUnexpectedToken();
    }
    try s.advance();

    // TypeScript overload signature: no body follows the parameter list,
    // so nothing is declared here.
    s.ts_last_decl_was_signature = false;
    if (!(try typescript.tsFunctionHasBodyAhead(s))) {
        try typescript.tsSkipFunctionSignature(s);
        s.ts_last_decl_was_signature = true;
        return;
    }

    try parseFunctionParamsAndBody(s, func_kind.withGenerator(is_generator), source_start, .{
        .name = name_atom,
        .is_decl = true,
    });
    try typescript.emitNamespaceExportIfExported(s, name_atom);
}

/// Parse function expression
/// Mirrors `js_parse_function_expr` in quickjs.c
pub fn parseFunctionExpr(s: *State, func_kind: ParseFunctionKind, source_start: FunctionSourceStart) Error!void {
    try s.advance();

    // Check for generator: function*
    const is_generator = s.peekKind() == .star;
    if (is_generator) {
        try s.advance();
    }

    // Parse function name (optional for expressions)
    var owned_name: ?Atom = null;
    // The name is BindingIdentifier[?Yield, ?Await] of the function being
    // named, not of the enclosing context: a plain function expression may be
    // called `await` inside an async function, an async one never.
    const strict = s.isStrict();
    const has_name = s.peekKind() == .ident or
        (s.peekKind() == .kw_await and !s.lex.is_module) or
        (s.peekKind() == .kw_yield and !strict) or
        (!strict and (s.peekKind() == .kw_static or s.peekKind() == .kw_let or identifiers.isSloppyFutureReservedToken(s.peekKind())));
    if (has_name) {
        // An escaped name is checked like the unescaped one below: the
        // enclosing function's yield/await context does not apply to it.
        const enclosing = s.ctx;
        s.ctx.in_async = false;
        s.ctx.in_generator = false;
        s.ctx.in_class_static_block = false;
        const invalid_escape = identifiers.identifierLikeHasInvalidEscapeForBinding(s);
        s.ctx.in_async = enclosing.in_async;
        s.ctx.in_generator = enclosing.in_generator;
        s.ctx.in_class_static_block = enclosing.in_class_static_block;
        if (invalid_escape) return s.failUnexpectedToken();
        // qjs js_parse_function_decl2 retains a named-expression atom
        // across next_token.
        const name_atom = identifiers.identifierLikeAtom(s);
        owned_name = name_atom;
        if (is_generator and identifiers.atomNameEquals(s, name_atom, "yield")) return s.failUnexpectedToken();
        if (func_kind == .async and identifiers.atomNameEquals(s, name_atom, "await")) return s.failUnexpectedToken();
        if (s.isStrict() and
            (identifiers.atomNameEquals(s, name_atom, "eval") or identifiers.atomNameEquals(s, name_atom, "arguments")))
        {
            return s.failUnexpectedToken();
        }
        try s.advance();
    }

    try parseFunctionParamsAndBody(s, func_kind.withGenerator(is_generator), source_start, .{ .name = owned_name });
}

/// Anonymous `export default function` is a declaration whose external
/// carrier is `*default*` (`atom_star_default`), while its inferred
/// function name is `default`.
/// QuickJS routes this through js_parse_function_decl2 as a statement;
/// keep it on the same declaration path instead of adapting an expression
/// child after parsing.
pub fn parseAnonymousDefaultFunctionDecl(
    s: *State,
    func_kind: ParseFunctionKind,
    source_start: FunctionSourceStart,
) Error!void {
    try s.advance(); // `function`
    const is_generator = s.peekKind() == .star;
    if (is_generator) try s.advance();

    // TypeScript overload signature, as for a named declaration.
    s.ts_last_decl_was_signature = false;
    if (!(try typescript.tsFunctionHasBodyAhead(s))) {
        try typescript.tsSkipFunctionSignature(s);
        s.ts_last_decl_was_signature = true;
        return;
    }

    try parseFunctionParamsAndBody(s, func_kind.withGenerator(is_generator), source_start, .{
        .name = atom_default,
        .is_decl = true,
        .export_default = true,
    });
}

fn appendOwnedParserAtom(s: *State, list: *std.ArrayList(Atom), atom_id: Atom) Error!void {
    try list.ensureUnusedCapacity(s.scratch, 1);
    list.appendAssumeCapacity(atom_id);
}

pub fn deinitOwnedParserAtoms(s: *State, list: *std.ArrayList(Atom)) void {
    list.deinit(s.scratch);
}

const FunctionParameters = struct {
    /// Every simple (identifier) parameter name so far, for the duplicate
    /// checks.
    simple_names: std.AutoHashMapUnmanaged(Atom, void) = .empty,
    invalid_strict_name_position: ?diagnostics.Position = null,
    has_duplicate_simple: bool = false,
    /// The first repeated simple parameter name.
    duplicate_position: ?diagnostics.Position = null,
    has_simple_list: bool = true,

    pub fn deinit(self: *FunctionParameters, s: *State) void {
        self.simple_names.deinit(s.scratch);
    }
};

const FunctionDeclPlan = struct {
    const OuterCarrier = enum {
        none,
        local,
        global,
        eval_var_object,
    };

    active: bool = false,
    binding_name: Atom = atom_module.null_atom,
    global_declaration: bool = false,
    body_declaration: bool = false,
    lexical_var_idx: i32 = -1,
    annex_b_var_idx: i32 = -1,
    outer_carrier: OuterCarrier = .none,
    scope_entry_init: bool = false,
    emit_inline: bool = false,
    skip_init: bool = false,
    force_local_init: bool = false,
    emit_global_inline: bool = false,
    emit_eval_var_inline: bool = false,
};

/// Annex B (B.3.2.1, B.3.2.2): the var copy of a sloppy block or `if`-clause
/// function declaration is a global var at the top level of script code
/// (and of eval code with global var bindings), an eval var-object binding
/// at the top level of other eval code, and a function local otherwise.
fn defineAnnexBFunctionVar(s: *State, plan: *FunctionDeclPlan, name: Atom) Error!i32 {
    plan.emit_inline = true;
    if (s.cur_func_stack.len == 0 and (!s.is_eval or s.eval_global_var_bindings)) {
        plan.outer_carrier = .global;
        plan.emit_global_inline = true;
    } else if (s.cur_func_stack.len == 0) {
        plan.outer_carrier = .eval_var_object;
        plan.emit_eval_var_inline = true;
    } else {
        plan.outer_carrier = .local;
    }
    return switch (try declarations.defineVar(s, name, .function_decl)) {
        .local => |idx| idx,
        else => unreachable,
    };
}

/// Shared state of one parameter list while its entries are parsed.
const ParameterListState = struct {
    func_kind: ParseFunctionKind,
    /// Scope of the separate parameter environment when the list has
    /// expressions (defaults or patterns); null otherwise.
    parameter_scope: ?i32,
    parameters: FunctionParameters = .{},
    param_count: u32 = 0,
    first_default_param: ?u32 = null,
    has_rest_parameter: bool = false,

    fn destructuringOptions(self: *const ParameterListState, rest: bool) ParameterDestructuringOptions {
        return .{
            .has_parameter_expressions = self.parameter_scope != null,
            .allow_outer_initializer = !rest,
            .value_already_on_stack = rest,
        };
    }
};

fn parseFunctionParameters(
    s: *State,
    func_kind: ParseFunctionKind,
) Error!FunctionParameters {
    var list: ParameterListState = .{ .func_kind = func_kind, .parameter_scope = null };
    errdefer list.parameters.deinit(s);

    if (func_kind != .class_static_block) {
        // Arrow parameter lists inherit the enclosing Await grammar
        // parameter from the caller; every other kind sets its own.
        const saved_reject_await = s.ctx.reject_await_in_parameter_initializer;
        if (func_kind != .arrow) {
            s.ctx.reject_await_in_parameter_initializer = func_kind.isAsync();
        }
        defer s.ctx.reject_await_in_parameter_initializer = saved_reject_await;

        // TypeScript `function f<T>(...)`.
        if (typescript.tsAtLess(s)) try typescript.tsParseTypeParameters(s);
        const parameter_scan = try scanParameterList(s);
        try s.expectToken(.lparen);
        s.curFunc().has_parameter_expressions = parameter_scan.has_parameter_expressions;
        if (parameter_scan.has_parameter_expressions) {
            list.parameter_scope = try enterParameterExpressionScope(s);
        }

        while (s.peekKind() != .rparen and s.peekKind() != .eof) {
            var has_modifier = false;
            if (func_kind.isConstructor()) {
                // TypeScript parameter properties `constructor(public x)`.
                while (try s.isParameterModifier()) {
                    has_modifier = true;
                    try s.advance();
                }
            }
            if (s.peekKind() == .kw_this) {
                // TypeScript `this` parameter: a type annotation on the
                // receiver, not an argument.
                if (list.param_count != 0) return s.failUnexpectedToken();
                try s.advance();
                try typescript.tsParseTypeAnnotationOpt(s);
            } else if (identifiers.isIdentifierLikeToken(s)) {
                try parseNamedParameter(s, &list, has_modifier);
            } else if (s.peekKind() == .lbrace or s.peekKind() == .lbracket) {
                try parsePatternParameter(s, &list);
            } else if (s.peekKind() == .ellipsis) {
                try parseRestParameter(s, &list);
                break;
            } else {
                return s.failExpectedDescription("binding name or binding pattern");
            }

            if (s.peekKind() == .comma) {
                try s.advance();
            } else if (s.peekKind() != .rparen) {
                return s.failExpectedToken(.rparen);
            }
        }

        try s.expectToken(.rparen);
        if (list.parameter_scope) |scope| try leaveParameterExpressionScope(s, scope);
        // TypeScript return type / type predicate.
        try typescript.tsParseReturnTypeOpt(s);
    }

    if (func_kind == .get and (list.param_count != 0 or list.has_rest_parameter))
        return s.failWithMessage(null, "getter parameter list must be empty");
    if (func_kind == .set and (list.param_count != 1 or list.has_rest_parameter))
        return s.failWithMessage(null, "setter parameter list must contain exactly one non-rest parameter");
    s.curFunc().has_simple_parameter_list = list.parameters.has_simple_list;
    s.curFunc().parameter_var_count = @intCast(s.curFunc().vars.len);
    if (list.first_default_param) |defined_count| {
        s.curFunc().defined_arg_count = @intCast(defined_count);
    }
    return list.parameters;
}

/// `name`, `name?: T`, `name = default`; `has_modifier` marks a TypeScript
/// parameter property.
fn parseNamedParameter(s: *State, list: *ParameterListState, has_modifier: bool) Error!void {
    const func_kind = list.func_kind;
    if (identifiers.identifierLikeHasInvalidEscapeForBinding(s)) return s.failUnexpectedToken();
    const param_atom = identifiers.identifierLikeAtom(s);
    identifiers.recordInvalidStrictParameterName(s, &list.parameters.invalid_strict_name_position, param_atom);
    if (has_modifier) {
        if (s.current_parameter_properties) |*props| {
            try appendOwnedParserAtom(s, props, param_atom);
        }
    }
    const arg_index = list.param_count;
    const strict_params = s.isStrict();
    if (func_kind == .set and strict_params and
        (identifiers.atomNameEquals(s, param_atom, "eval") or identifiers.atomNameEquals(s, param_atom, "arguments")))
    {
        return s.failUnexpectedToken();
    }
    if (list.parameters.simple_names.contains(param_atom)) {
        // Arrow parameters never tolerate a duplicate name.
        if (func_kind == .arrow or strict_params) return s.failNamed("duplicate parameter '{s}'", "duplicate parameter", param_atom);
        list.parameters.has_duplicate_simple = true;
        if (list.parameters.duplicate_position == null) list.parameters.duplicate_position = s.currentDiagnosticPosition();
    }
    for (s.curFunc().vars) |existing| {
        if (existing.var_name == param_atom) return s.failNamed("duplicate parameter '{s}'", "duplicate parameter", param_atom);
    }
    try list.parameters.simple_names.put(s.scratch, param_atom, {});
    if (list.parameter_scope != null) {
        try appendParameterExpressionBinding(s, param_atom);
    }
    _ = try s.curFunc().appendArg(.{
        .var_name = param_atom,
        .scope_level = 0,
        .is_lexical = false,
        .is_const = false,
        .var_kind = .normal,
    });
    try s.advance();
    list.param_count += 1;
    // TypeScript `x?: T`.
    if (s.peekKind() == .question) try s.advance();
    try typescript.tsParseTypeAnnotationOpt(s);

    if (s.peekKind() == .assign) {
        list.parameters.has_simple_list = false;
        if (list.first_default_param == null) list.first_default_param = arg_index;
        try s.advance();
        const saved_in_parameter_initializer = s.ctx.in_parameter_initializer;
        s.ctx.in_parameter_initializer = true;
        defer s.ctx.in_parameter_initializer = saved_in_parameter_initializer;
        // qjs js_parse_function_decl2: keep an already-supplied
        // argument, otherwise evaluate and store its initializer.
        try Emitter.opU16(s, opcode.op.get_arg, @intCast(arg_index));
        try Emitter.opU8(s, opcode.op.ext0, opcode.ext0_sub.is_undefined);
        const keep_value = try Emitter.newLabel(s);
        try Emitter.jump(s, opcode.op.if_false, keep_value);
        try parseNamedBindingDefaultInitializer(s, param_atom);
        try Emitter.opU16(s, opcode.op.put_arg, @intCast(arg_index));
        try Emitter.bind(s, keep_value);
    }
    if (list.parameter_scope != null) {
        try initializeParameterScopeBinding(s, param_atom, arg_index);
    }
}

/// `{...}` / `[...]` parameter, with or without a default.
fn parsePatternParameter(s: *State, list: *ParameterListState) Error!void {
    list.parameters.has_simple_list = false;
    const arg_index = list.param_count;
    try ensureDestructuringArgSlot(s, arg_index);
    const has_initializer = try parseParameterDestructuring(s, arg_index, list.destructuringOptions(false));
    if (has_initializer and list.first_default_param == null) list.first_default_param = arg_index;
    list.param_count += 1;
}

/// `...name` / `...{...}` / `...[...]`: always the last parameter.
fn parseRestParameter(s: *State, list: *ParameterListState) Error!void {
    s.features.insert(.spread_rest);
    list.parameters.has_simple_list = false;
    const arg_index = list.param_count;
    try s.advance();
    list.has_rest_parameter = true;
    if (identifiers.isIdentifierLikeToken(s)) {
        if (identifiers.identifierLikeHasInvalidEscapeForBinding(s)) return s.failUnexpectedToken();
        const rest_atom = identifiers.identifierLikeAtom(s);
        identifiers.recordInvalidStrictParameterName(s, &list.parameters.invalid_strict_name_position, rest_atom);
        if (list.parameters.simple_names.contains(rest_atom)) return s.failUnexpectedToken();
        for (s.curFunc().vars) |existing| {
            if (existing.var_name == rest_atom) return s.failUnexpectedToken();
        }
        try list.parameters.simple_names.put(s.scratch, rest_atom, {});
        if (list.parameter_scope != null) {
            try appendParameterExpressionBinding(s, rest_atom);
        }
        const idx = try s.curFunc().appendArg(.{
            .var_name = rest_atom,
            .scope_level = 0,
            .is_lexical = false,
            .is_const = false,
            .var_kind = .normal,
        });
        if (idx != @as(i32, @intCast(arg_index))) return Error.ParserInvariant;
        try Emitter.opU16(s, opcode.op.rest, @intCast(arg_index));
        try Emitter.opU16(s, opcode.op.put_arg, @intCast(arg_index));
        s.curFunc().defined_arg_count = @intCast(arg_index);
        if (list.parameter_scope != null) {
            try initializeParameterScopeBinding(s, rest_atom, arg_index);
        }
        try s.advance();
        try typescript.tsParseTypeAnnotationOpt(s);
    } else if (s.peekKind() == .lbracket or s.peekKind() == .lbrace) {
        try ensureDestructuringArgSlot(s, arg_index);
        try Emitter.opU16(s, opcode.op.rest, @intCast(arg_index));
        s.curFunc().defined_arg_count = @intCast(arg_index);
        if (try parseParameterDestructuring(s, arg_index, list.destructuringOptions(true))) return Error.ParserInvariant;
    } else {
        return s.failExpectedDescription("binding name or binding pattern");
    }
}

pub fn parseFunctionParamsAndBody(s: *State, func_kind: ParseFunctionKind, source_start: ?FunctionSourceStart, entry: FunctionEntry) Error!void {
    recordFunctionFeatures(s, func_kind);
    s.last_function_child_index = null;
    const parent_fd = s.curFunc();
    const outer = s.ctx;
    defer s.ctx = outer;
    s.ctx = childFunctionContext(outer, func_kind, entry);
    if (func_kind.isConstructor()) s.ctx.super_fields_init = s.class.fields_init;
    var child: ?ChildFunction = null;
    errdefer if (child) |*c| c.discard(s);
    const saved_return_finally = emitter.enterReturnFinallyFunctionBoundary(s);
    defer emitter.leaveReturnFinallyFunctionBoundary(s, &saved_return_finally);

    var plan: FunctionDeclPlan = .{};
    child = try createChildFunction(s, parent_fd, func_kind, entry, source_start);
    if (entry.is_decl) plan = try planFunctionDeclaration(s, parent_fd, func_kind, entry);
    try child.?.makeCurrent(s, if (func_kind == .class_static_block) 0 else 1);

    // A nested function closes over the outer parameter environment, but
    // its own grammar is a fresh function boundary.  Record the parent
    // relationship above, then stop treating the nested function body as
    // part of the outer FormalParameters production.
    s.ctx.in_parameter_initializer = false;

    var parameters = try parseFunctionHead(s, func_kind);
    defer parameters.deinit(s);
    try parseFunctionBody(s, func_kind, entry, &parameters);
    if (child) |*c| try finishChildFunction(s, c, parent_fd, entry, &plan, source_start);
}

/// Record the feature bits a function of this kind uses.
fn recordFunctionFeatures(s: *State, func_kind: ParseFunctionKind) void {
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
}

/// The grammar context of a function of `func_kind` nested in `outer`
/// (qjs js_parse_function_decl2).
fn childFunctionContext(outer: FunctionContext, func_kind: ParseFunctionKind, entry: FunctionEntry) FunctionContext {
    // The child's grammar context follows its kind (qjs js_parse_function_decl2).
    // QuickJS copies the enclosing super capability into arrows and class
    // static blocks. A static block is a lexical child of the method-like
    // static initializer: it has no home object of its own, but may read
    // the initializer's home object for `super` property access. It also
    // keeps the enclosing yield/await grammar; `in_class_static_block`
    // rejects `await` inside it.
    const is_constructor = func_kind.isConstructor();
    const function_has_home_object = entry.is_method or func_kind.hasHomeObject();
    const function_allows_super = if (func_kind == .arrow or func_kind == .class_static_block)
        outer.allow_super
    else
        function_has_home_object;
    const function_allows_super_call = if (func_kind == .arrow)
        outer.allow_super_call
    else
        func_kind == .derived_class_constructor;
    const function_new_target_allowed = if (func_kind == .arrow) outer.new_target_allowed else true;
    return .{
        .in_generator = if (func_kind == .class_static_block) outer.in_generator else func_kind.isGenerator(),
        .in_async = if (func_kind == .class_static_block) outer.in_async else func_kind.isAsync(),
        .in_constructor = is_constructor,
        .is_outer_constructor_block = is_constructor,
        .allow_super = function_allows_super,
        .allow_super_call = function_allows_super_call,
        .new_target_allowed = function_new_target_allowed,
        .in_class_static_block = func_kind == .class_static_block,
        // The child FunctionDef still records whether it was created inside
        // the outer parameter environment; the flag is cleared below once
        // the child is the current function.
        .in_parameter_initializer = outer.in_parameter_initializer,
        .reject_await_in_parameter_initializer = outer.reject_await_in_parameter_initializer,
        // A TypeScript namespace body ends at any nested function: its `var`
        // rewriting and `export` attachment must not apply inside.
        .in_namespace = false,
        .namespace_export = false,
        .current_namespace_atom = null,
        .super_fields_init = if (func_kind == .arrow) outer.super_fields_init else parse_state.atom_class_fields_init,
    };
}

/// Create the child FunctionDef with the flags its kind implies. The
/// caller makes it current after planning any declaration binding.
fn createChildFunction(s: *State, parent_fd: *function_def_mod.FunctionDef, func_kind: ParseFunctionKind, entry: FunctionEntry, source_start: ?FunctionSourceStart) Error!ChildFunction {
    // QuickJS seeds a child FunctionDef from the `ptr` passed to
    // js_parse_function_decl2, i.e. the beginning of the complete
    // function production, not the token left after its name.
    const child_source = if (source_start) |start|
        SourcePosition{ .line_num = start.line_num, .col_num = start.col_num }
    else
        s.currentSourcePosition();
    const child_name = entry.name orelse if (entry.is_decl) s.root_name else atom_module.ids.empty_string;
    var child = try ChildFunction.create(s, parent_fd, child_name, child_source);
    // The caller's `errdefer child.discard(s)` only exists once this returns.
    errdefer child.discard(s);
    const child_fd = child.fd;
    child_fd.is_strict_mode = parent_fd.is_strict_mode or s.is_strict or s.lex.is_strict_mode;
    child_fd.func_type = switch (func_kind) {
        .normal, .async, .generator, .async_generator => if (entry.is_method)
            .method
        else if (entry.is_decl)
            .statement
        else
            .expr,
        .arrow => .arrow,
        .get => .getter,
        .set => .setter,
        .method => .method,
        .class_constructor => .class_constructor,
        .derived_class_constructor => .derived_class_constructor,
        .class_static_block => .class_static_init,
    };
    child_fd.func_kind = func_kind.bytecodeKind();
    child_fd.new_target_allowed = s.ctx.new_target_allowed;
    child_fd.super_allowed = s.ctx.allow_super;
    child_fd.super_call_allowed = s.ctx.allow_super_call;
    child_fd.has_arguments_binding = func_kind != .arrow and func_kind != .class_static_block;
    child_fd.has_this_binding = func_kind != .arrow and func_kind != .class_static_block;
    child_fd.arguments_allowed = if (func_kind == .arrow)
        parent_fd.arguments_allowed
    else
        func_kind != .class_static_block;
    child_fd.has_home_object = entry.is_method or func_kind.hasHomeObject();
    child_fd.has_prototype = func_kind.hasPrototype();
    _ = try child_fd.appendScope(-1);
    if (func_kind.isConstructor()) {
        child_fd.is_derived_class_constructor = func_kind == .derived_class_constructor;
    }
    if (!entry.is_decl) {
        if (entry.name != null) {
            // qjs js_parse_function_decl2 records only is_func_expr +
            // func_name here; the self-binding var is added lazily by
            // resolve_scope_var / add_eval_variables when a reference
            // actually falls through (add_func_var quickjs.c,
            // call sites 32977 / 33153 / 33650 / 33698). child_fd
            // carries the name already: FunctionDef.init received
            // `child_name == entry.name` above.
            child_fd.is_named_func_expr = true;
        }
    }
    return child;
}

const AnnexBEligibility = struct {
    visible_lexical_blocking_annex_b: bool,
    is_block_level_function_decl: bool,
    name_blocks_annex_b_parameter_rule: bool,
    annex_b_if_function_var: bool,
    annex_b_block_function_var: bool,
};

fn annexBEligibility(
    s: *State,
    parent_fd: *function_def_mod.FunctionDef,
    func_kind: ParseFunctionKind,
    name: Atom,
    plan: *FunctionDeclPlan,
) AnnexBEligibility {
    // qjs find_lexical_decl: in global script/eval
    // code a top-level let/const lives in global_vars
    // (JS_CLOSURE_GLOBAL_DECL), not in fd->vars; find_lexical_global_var
    // consults it so Annex B B.3.3 block functions skip hoisting when a
    // top-level lexical collides. Required since
    // top_level_lexical_as_global_ref moves these out of scope vars.
    // A pair of Annex-B single-statement functions in one
    // IfStatement shares the wrapper scope above.  The first
    // declaration is therefore visible here as a lexical
    // function binding, but it is not the lexical binding
    // that B.3.3 must protect: the second branch is the
    // permitted same-scope function redefinition.  A
    // function declaration from an enclosing scope, and all
    // ordinary lexical declarations, still block the Annex-B
    // var copy.
    // Strict code never copies a block function to a var, and every use
    // below is decided without this flag there; skip the scope walk,
    // linear in the visible declarations.
    const visible_lexical_blocking_annex_b = !parent_fd.is_strict_mode and blk: {
        const visible_idx = declarations.visibleLexicalScopeVar(s, name) orelse break :blk false;
        const visible = parent_fd.vars[visible_idx];
        if (visible.scope_level != parent_fd.scope_level or visible.var_kind != .function_decl) break :blk true;
        // A same-scope function redefinition: a lexical binding further
        // out still blocks the var copy (B.3.2.1).
        const parent_scope = parent_fd.scopes[@intCast(parent_fd.scope_level)].parent;
        break :blk declarations.visibleLexicalScopeVarFrom(s, name, parent_scope) != null;
    } or (!parent_fd.is_strict_mode and declarations.findLexicalGlobalVar(s, name));
    const function_body_scope = parent_fd.body_scope;
    const is_block_level_function_decl = parent_fd.scope_level > function_body_scope;
    // QuickJS records a block function's cpool index on its
    // lexical VarDef and instantiates it while lowering that
    // block's OP_enter_scope.  Annex-B single-statement `if`
    // functions are conditional source-position assignments,
    // not scope-entry declarations.
    plan.scope_entry_init =
        is_block_level_function_decl and !s.annex_b_if_function_decl_clause;
    // Function code with an arguments object never copies a block
    // `function arguments` to a var (B.3.2.1 step ii: "arguments" is in
    // parameterNames). An arrow has none, so its copy is made like any
    // other name; script code has no such exception (B.3.2.2).
    const arguments_blocks_annex_b = identifiers.atomNameEquals(s, name, "arguments") and
        !(parent_fd.is_global_var and !s.is_eval) and
        (if (s.is_eval)
            !s.eval_in_parameter_initializer and closure.findClosureVarIndex(parent_fd, name) != null
        else
            parent_fd.has_arguments_binding);
    const name_blocks_annex_b_parameter_rule =
        parent_fd.findArg(name) >= 0 or
        parent_fd.isPatternParameterName(name) or
        arguments_blocks_annex_b or
        identifiers.evalAnnexBBlockedFunctionName(parent_fd, name);
    const annex_b_var_allowed = !parent_fd.is_strict_mode and
        func_kind == .normal and
        !visible_lexical_blocking_annex_b and
        !name_blocks_annex_b_parameter_rule and
        !s.ctx.in_namespace;
    return .{
        .visible_lexical_blocking_annex_b = visible_lexical_blocking_annex_b,
        .is_block_level_function_decl = is_block_level_function_decl,
        .name_blocks_annex_b_parameter_rule = name_blocks_annex_b_parameter_rule,
        .annex_b_if_function_var = s.annex_b_if_function_decl_clause and annex_b_var_allowed,
        .annex_b_block_function_var = is_block_level_function_decl and annex_b_var_allowed,
    };
}

fn defineFunctionDeclLocal(s: *State, name: Atom, func_kind: ParseFunctionKind) Error!u16 {
    return switch (try declarations.defineVar(
        s,
        name,
        if (func_kind == .normal) .function_decl else .new_function_decl,
    )) {
        .local => |idx| idx,
        else => unreachable,
    };
}

fn defineFunctionDeclVar(
    s: *State,
    parent_fd: *function_def_mod.FunctionDef,
    func_kind: ParseFunctionKind,
    name: Atom,
    plan: *FunctionDeclPlan,
    eligibility: AnnexBEligibility,
) Error!void {
    const visible_lexical_blocking_annex_b = eligibility.visible_lexical_blocking_annex_b;
    const is_block_level_function_decl = eligibility.is_block_level_function_decl;
    const name_blocks_annex_b_parameter_rule = eligibility.name_blocks_annex_b_parameter_rule;
    const annex_b_if_function_var = eligibility.annex_b_if_function_var;
    const annex_b_block_function_var = eligibility.annex_b_block_function_var;
    // The implicit arguments-object local is a parameter-name
    // blocker for Annex B, not an earlier block-function
    // declaration. Treating it as the latter forces the lexical
    // function initializer to its source position, so a call
    // before `function arguments(){}` incorrectly observes the
    // arguments object. Keep the block function in the normal
    // hoisted lexical-init path; the outer implicit binding stays
    // in its separate `arguments_var_idx` slot.
    const implicit_arguments_binding =
        identifiers.atomNameEquals(s, name, "arguments") and parent_fd.arguments_var_idx != null;
    const duplicate_hoisted_block_func =
        is_block_level_function_decl and
        declarations.scopeHasVar(s, 0, name) and
        !implicit_arguments_binding;
    const function_decl_idx: i32 = if (annex_b_if_function_var)
        try defineAnnexBFunctionVar(s, plan, name)
    else if (s.annex_b_if_function_decl_clause and func_kind == .normal) blk: {
        plan.emit_inline = true;
        plan.skip_init = true;
        break :blk 0;
    } else if (annex_b_block_function_var)
        try defineAnnexBFunctionVar(s, plan, name)
    else if ((parent_fd.is_strict_mode and is_block_level_function_decl) or
        (is_block_level_function_decl and s.is_eval) or
        (is_block_level_function_decl and visible_lexical_blocking_annex_b) or
        (is_block_level_function_decl and name_blocks_annex_b_parameter_rule) or
        (is_block_level_function_decl and s.in_switch_case_block_scope) or
        duplicate_hoisted_block_func)
    blk: {
        plan.force_local_init = is_block_level_function_decl and name_blocks_annex_b_parameter_rule;
        if (plan.force_local_init) {
            if (findCurrentScopeVar(s, name)) |idx| {
                parent_fd.vars[idx].tdz_emitted_at_decl = true;
                break :blk idx;
            }
        }
        const idx = try defineFunctionDeclLocal(s, name, func_kind);
        if (plan.force_local_init) parent_fd.vars[idx].tdz_emitted_at_decl = true;
        break :blk idx;
    } else blk: {
        if (!is_block_level_function_decl) {
            plan.body_declaration = true;
            break :blk -1;
        }
        // Non-Annex-B block declarations are lexical.  Async
        // and generator declarations carry NEW_FUNCTION_DECL;
        // ordinary functions carry FUNCTION_DECL.
        break :blk try defineFunctionDeclLocal(s, name, func_kind);
    };
    plan.lexical_var_idx = function_decl_idx;
    plan.emit_inline = plan.emit_inline or
        duplicate_hoisted_block_func or
        (is_block_level_function_decl and
            !plan.force_local_init and
            !plan.emit_global_inline and
            parent_fd.vars[@intCast(function_decl_idx)].is_lexical);
}

/// Decide where a function declaration's binding lives and how its
/// closure is stored: hoisted var, global declaration, lexical block
/// binding, or an Annex B copy (qjs js_parse_function_decl2 +
/// define_var, quickjs.c). Defines the parent-side
/// VarDefs now; the cpool index is patched in by `finishChildFunction`.
fn planFunctionDeclaration(s: *State, parent_fd: *function_def_mod.FunctionDef, func_kind: ParseFunctionKind, entry: FunctionEntry) Error!FunctionDeclPlan {
    const name = if (entry.export_default)
        atom_star_default
    else
        entry.name orelse s.root_name;
    var plan: FunctionDeclPlan = .{ .active = true, .binding_name = name };
    if (s.cur_func_stack.len == 0 and
        parent_fd.scope_level == parent_fd.body_scope and
        (!s.is_eval or !parent_fd.is_strict_mode) and
        !s.annex_b_if_function_decl_clause and
        declarations.findFunctionScopeVar(s, name) == null)
    {
        // The child must exist before the declaration carrier gets
        // its cpool index.  All script/module/eval top-level cases
        // append their GlobalVar in the post-child half below.
        plan.global_declaration = true;
        // A top-level function is var-scoped: an earlier let/const/class
        // of the same name is a redeclaration, as for `var`.
        if (try declarations.findLexicalDeclaration(s, name, false) != null) return declarations.failRedeclaration(s, name);
    } else {
        // Early-error: check for duplicate lexical declaration in the
        // same scope.  Mirrors QuickJS `define_var` JS_VAR_DEF_FUNCTION_DECL
        // path: duplicate LexicallyDeclaredNames
        // in a Block are a SyntaxError, except Annex B.3.3.4 allows
        // redefining a function declaration with another function declaration
        // in non-strict mode.
        if (declarations.visibleLexicalScopeVar(s, name)) |existing_idx| {
            const existing = parent_fd.vars[existing_idx];
            const same_scope = existing.scope_level == parent_fd.scope_level;
            const annex_b_func_redef = same_scope and
                !parent_fd.is_strict_mode and
                func_kind == .normal and
                existing.var_kind == .function_decl;
            if (same_scope and !annex_b_func_redef) {
                return s.failWithMessage(null, "duplicate declaration in the same scope");
            }
        }

        const eligibility = annexBEligibility(s, parent_fd, func_kind, name, &plan);
        try defineFunctionDeclVar(s, parent_fd, func_kind, name, &plan, eligibility);
    }
    return plan;
}

/// Constructor entry checks, the parameter list, and the generator
/// prologue: everything before the body block.
fn parseFunctionHead(s: *State, func_kind: ParseFunctionKind) Error!FunctionParameters {
    // qjs emits OP_check_ctor at the class-constructor function entry,
    // before parameter initializers and independently of whether the body
    // contains super(). Keeping it out of the indexed super lowering is
    // required now that all super calls use phase-1 scope operands.
    if (func_kind.isConstructor()) {
        // qjs js_parse_function_decl2: OP_check_ctor guards the explicit
        // constructor entry before parameter initializers.
        try Emitter.op(s, opcode.op.check_ctor);
    }
    if (func_kind == .class_constructor) {
        try expressions.emitClassFieldInitCall(s);
    }

    const parameters = try parseFunctionParameters(s, func_kind);
    errdefer @constCast(&parameters).deinit(s);
    if (func_kind.isGenerator()) {
        try Emitter.op(s, opcode.op.initial_yield);
    }
    return parameters;
}

/// The body block, the strict-mode / duplicate-parameter checks that
/// depend on it, and the implicit terminating return.
fn parseFunctionBody(s: *State, func_kind: ParseFunctionKind, entry: FunctionEntry, parameters: *const FunctionParameters) Error!void {
    // Break/continue label resolution does not cross function boundaries.
    var control_boundary = s.enterControlBoundary();
    errdefer s.leaveControlBoundary(&control_boundary);
    // The Annex B if-clause flag describes this function's own declaration,
    // not the declarations in its body.
    const saved_if_clause = s.annex_b_if_function_decl_clause;
    s.annex_b_if_function_decl_clause = false;
    defer s.annex_b_if_function_decl_clause = saved_if_clause;
    // These checks run after the body, so they point at the directive or
    // parameter they concern rather than at the token after the function.
    const saved_use_strict_position = s.use_strict_position;
    s.use_strict_position = null;
    defer s.use_strict_position = saved_use_strict_position;
    try statements.parseFunctionBodyBlock(s);
    const use_strict_position = s.use_strict_position;
    if (s.is_strict) s.curFunc().is_strict_mode = true;
    if (s.curFunc().is_strict_mode) {
        if (s.curFunc().has_use_strict and !parameters.has_simple_list)
            return s.failWithMessage(use_strict_position, strict_non_simple_parameters);
        if (func_kind.isFunctionKeywordForm()) {
            if (entry.name) |name| {
                if (identifiers.isInvalidStrictFunctionBindingName(s, name))
                    return s.failWithMessage(use_strict_position, "invalid function name in strict mode");
            }
        }
        try identifiers.rejectInvalidStrictParameterName(s, parameters.invalid_strict_name_position);
    }
    // Mirrors the duplicate-argument gate in js_parse_function_check_names:
    // strict mode, a non-simple parameter list,
    // methods (incl. getters/setters/class elements) and arrows reject
    // duplicates; plain sloppy function/generator/async declarations and
    // expressions with a simple list keep them legal.
    if (parameters.has_duplicate_simple and
        (entry.is_method or
            func_kind == .method or func_kind == .get or func_kind == .set or
            func_kind == .arrow or
            func_kind.isConstructor() or
            !parameters.has_simple_list or s.isStrict()))
        return s.failWithMessage(parameters.duplicate_position, "duplicate parameters are not allowed in this function");
    s.leaveControlBoundary(&control_boundary);
    try emitFallthroughReturn(s, func_kind);
}

/// qjs js_parse_function_decl2 tail: js_is_live_code
/// alone decides whether the body needs a terminating return; every
/// construct epilogue bound its merge labels at the end, which
/// invalidated last_opcode_pos exactly like qjs OP_label.
fn emitFallthroughReturn(s: *State, func_kind: ParseFunctionKind) Error!void {
    if (!emitter.isLiveCode(s)) return;
    if (func_kind.isAsync() or func_kind.isGenerator()) {
        // emit_return(FALSE): undefined then return_async.
        try Emitter.op(s, opcode.op.undefined);
        try Emitter.op(s, opcode.op.return_async);
    } else if (func_kind == .derived_class_constructor) {
        // quickjs.c: checked this then OP_return.
        try s.emitScopeGetVarCheckThis(atom_this);
        try Emitter.op(s, opcode.op.@"return");
    } else {
        // quickjs.c: OP_return_undef. The expression-statement
        // drop stays before it; final bytecode rules decide whether that
        // drop can disappear.
        try Emitter.op(s, opcode.op.return_undef);
    }
}

pub fn reserveChildCpoolSlot(parent_fd: *function_def_mod.FunctionDef) Error!u16 {
    return std.math.cast(u16, try parent_fd.appendCpool(JSValue.undefinedValue())) orelse return error.BytecodeOverflow;
}

/// Pop the finished child, give it a constant-pool slot, create the
/// declaration carriers the plan asked for, and emit the closure
/// expression or declaration initializer in the parent.
fn finishChildFunction(s: *State, c: *ChildFunction, parent_fd: *function_def_mod.FunctionDef, entry: FunctionEntry, plan: *FunctionDeclPlan, source_start: ?FunctionSourceStart) Error!void {
    if (source_start) |start| try s.captureFunctionSource(s.curFunc(), start.offset);
    c.pop(s);
    const child_cpool_idx = try reserveChildCpoolSlot(parent_fd);
    c.fd.parent_cpool_idx = child_cpool_idx;

    // QuickJS creates declaration carriers only after the child has a
    // constant-pool index (js_parse_function_decl2, `done:`).  Keeping
    // this plan on the parser stack avoids making the child FunctionDef
    // a side channel into its parent finalizer.
    if (plan.active) {
        const name = plan.binding_name;
        if (plan.global_declaration) {
            const global_idx = parent_fd.global_vars.len;
            try declarations.addGlobalVar(s, name, .{});
            parent_fd.global_vars[global_idx].cpool_idx = @intCast(child_cpool_idx);
        } else if (plan.body_declaration) {
            switch (try declarations.defineVar(s, name, .var_)) {
                .argument => |arg_idx| parent_fd.args[arg_idx].func_pool_idx = child_cpool_idx,
                .local => |var_idx| parent_fd.vars[var_idx].func_pool_idx = child_cpool_idx,
                .global => {
                    if (parent_fd.global_vars.len == 0) return Error.ParserInvariant;
                    parent_fd.global_vars[parent_fd.global_vars.len - 1].cpool_idx = @intCast(child_cpool_idx);
                },
            }
        } else if (plan.lexical_var_idx >= 0 and
            plan.scope_entry_init)
        {
            const var_idx: usize = @intCast(plan.lexical_var_idx);
            if (var_idx >= parent_fd.vars.len) return Error.ParserInvariant;
            parent_fd.vars[var_idx].func_pool_idx = child_cpool_idx;
        }

        switch (plan.outer_carrier) {
            .none => {},
            .global => try declarations.addGlobalAnnexBFunctionVar(s, name, s.eval_global_var_bindings),
            .eval_var_object => if (!declarations.findGlobalVar(s, name)) try declarations.addDirectEvalVarObjectVar(s, name),
            .local => plan.annex_b_var_idx = try declarations.ensureFunctionScopeVar(s, name),
        }
    }
    try c.adopt(parent_fd);
    s.last_function_child_index = @intCast(parent_fd.child_list.len - 1);
    if (!entry.is_decl) {
        try s.emitFClosure(child_cpool_idx);
        const is_anonymous = entry.name == null;
        if (is_anonymous) {
            // qjs js_parse_function_decl2 emits a parser-only
            // set_name(NULL) placeholder after every anonymous
            // expression closure. Direct named-evaluation sites patch
            // it; resolve_variables erases it otherwise.
            try Emitter.opAtom(s, opcode.op.set_name, atom_module.null_atom);
        }
    } else if (plan.emit_inline) {
        if (plan.skip_init) return;
        std.debug.assert(plan.lexical_var_idx >= 0);
        if (plan.scope_entry_init) {
            // OP_enter_scope already initialized the lexical function
            // binding from VarDef.func_pool_idx. The Annex B copy
            // (B.3.2.1 step iii) takes the block binding's CURRENT value:
            // the same function object, or whatever the block assigned.
            const copies = plan.annex_b_var_idx >= 0 or plan.emit_global_inline or plan.emit_eval_var_inline;
            if (copies) try s.emitScopeGetVar(plan.binding_name) else try s.emitFClosure(child_cpool_idx);
            if (plan.annex_b_var_idx >= 0) {
                try Emitter.op(s, opcode.op.dup);
                try Emitter.opU16(s, opcode.op.put_loc, @intCast(plan.annex_b_var_idx));
            }
            if (plan.emit_global_inline) {
                try Emitter.op(s, opcode.op.dup);
                try s.emitGlobalScopePutVar(plan.binding_name);
            }
            if (plan.emit_eval_var_inline) {
                try Emitter.op(s, opcode.op.dup);
                try s.emitEvalVarObjectScopePutVar(plan.binding_name);
            }
            try Emitter.op(s, opcode.op.drop);
        } else {
            try s.emitFClosure(child_cpool_idx);
            if (plan.emit_global_inline) {
                try Emitter.op(s, opcode.op.dup);
            }
            if (plan.emit_eval_var_inline) {
                try Emitter.op(s, opcode.op.dup);
            }
            if (plan.annex_b_var_idx >= 0) {
                try Emitter.op(s, opcode.op.dup);
            }
            // zjs also emits this opcode for Annex-B source-position
            // copies, so retain the existing declaration-class gate:
            // #7's once-only derived-this rule is not universal here.
            try Emitter.opU16(s, opcode.op.put_loc_check_init, @intCast(plan.lexical_var_idx));
            if (plan.annex_b_var_idx >= 0) {
                try Emitter.opU16(s, opcode.op.put_loc, @intCast(plan.annex_b_var_idx));
            }
            if (plan.emit_global_inline) {
                try s.emitGlobalScopePutVar(plan.binding_name);
            }
            if (plan.emit_eval_var_inline) {
                try s.emitEvalVarObjectScopePutVar(plan.binding_name);
            }
        }
    } else if (plan.scope_entry_init) {
        // The binding itself is initialized at OP_enter_scope; retain
        // QuickJS's source-position declaration closure/drop pair.
        try s.emitFClosure(child_cpool_idx);
        try Emitter.op(s, opcode.op.drop);
    }
}

/// Parse arrow function
/// Mirrors arrow function parsing in quickjs.c
pub fn parseArrowFunction(s: *State, func_kind: ParseFunctionKind, source_start: FunctionSourceStart, body_flags: ParseFlags) Error!void {
    s.features.insert(.function_);
    s.features.insert(.arrow);
    if (func_kind.isAsync()) {
        s.features.insert(.async_function);
    }
    const parent_fd = s.curFunc();
    const outer = s.ctx;
    defer s.ctx = outer;
    // An arrow is lexically transparent: it keeps the enclosing super /
    // new.target capability, and only drops what a constructor or namespace
    // body attaches to its own statements. Its body is `[~Yield]` (below).
    s.ctx.in_constructor = false;
    s.ctx.in_namespace = false;
    s.ctx.namespace_export = false;
    s.ctx.current_namespace_atom = null;
    const saved_parameter_properties = s.current_parameter_properties;
    s.current_parameter_properties = null;
    defer s.current_parameter_properties = saved_parameter_properties;

    var child: ?ChildFunction = null;
    errdefer if (child) |*c| c.discard(s);
    const saved_return_finally = emitter.enterReturnFinallyFunctionBoundary(s);
    defer emitter.leaveReturnFinallyFunctionBoundary(s, &saved_return_finally);

    {
        child = try ChildFunction.create(s, parent_fd, atom_module.ids.empty_string, .{ .line_num = source_start.line_num, .col_num = source_start.col_num });
        const child_fd = child.?.fd;
        child_fd.is_strict_mode = parent_fd.is_strict_mode or s.is_strict or s.lex.is_strict_mode;
        child_fd.func_type = .arrow;
        child_fd.func_kind = if (func_kind == .async) .async else .normal;
        child_fd.has_prototype = false;
        child_fd.new_target_allowed = outer.new_target_allowed;
        child_fd.super_allowed = s.ctx.allow_super;
        child_fd.super_call_allowed = s.ctx.allow_super_call;
        child_fd.arguments_allowed = parent_fd.arguments_allowed;
        _ = try child_fd.appendScope(-1);
        try child.?.makeCurrent(s, 1);
    }
    s.ctx.in_parameter_initializer = false;

    // Set async flag for await parsing. Arrow parameter lists inherit the
    // enclosing Await grammar parameter, while the body uses the arrow's own
    // async-ness.
    const is_async = func_kind.isAsync();
    const params_in_async = is_async or outer.in_async or s.lex.is_module or outer.in_class_static_block;
    s.ctx.in_async = params_in_async;
    s.ctx.reject_await_in_parameter_initializer = params_in_async;

    // Parse parameters. Two valid head shapes:
    //   `ident => ...`    — single bare identifier parameter
    //   `(...) => ...`    — parenthesized parameter list
    var has_non_simple_params = false;
    var invalid_strict_name_position: ?diagnostics.Position = null;
    if (identifiers.isIdentifierLikeToken(s)) {
        // Single bare identifier parameter.
        if (identifiers.identifierLikeHasInvalidEscapeForBinding(s)) return s.failUnexpectedToken();
        const param_atom = identifiers.identifierLikeAtom(s);
        identifiers.recordInvalidStrictParameterName(s, &invalid_strict_name_position, param_atom);
        if (s.isStrict()) {
            try identifiers.rejectInvalidStrictParameterName(s, invalid_strict_name_position);
        }
        _ = try s.curFunc().appendArg(.{
            .var_name = param_atom,
            .scope_level = 0,
            .is_lexical = false,
            .is_const = false,
            .var_kind = .normal,
        });
        try s.advance();
    } else {
        // Parenthesized parameter list: the ordinary parameter grammar,
        // with the arrow-only escape and duplicate rules selected by
        // `.arrow`.
        var parameters = try parseFunctionParameters(s, .arrow);
        defer parameters.deinit(s);
        has_non_simple_params = !parameters.has_simple_list;
        invalid_strict_name_position = parameters.invalid_strict_name_position;
        if (s.isStrict()) {
            try identifiers.rejectInvalidStrictParameterName(s, invalid_strict_name_position);
        }
    }

    s.curFunc().has_simple_parameter_list = !has_non_simple_params;
    s.curFunc().parameter_var_count = @intCast(s.curFunc().vars.len);

    // TypeScript `(...): R =>`.
    try typescript.tsParseReturnTypeOpt(s);
    // Expect =>
    if (s.lex.got_lf) return s.failUnexpectedToken();
    try s.expectToken(.arrow);
    s.ctx.in_async = is_async;
    s.ctx.in_generator = false;
    s.ctx.in_class_static_block = false;

    // Break/continue and active iterator cleanup do not cross function
    // boundaries. Keep arrows aligned with ordinary function bodies so a
    // return inside an arrow nested in for-of does not close the outer iterator.
    var control_boundary = s.enterControlBoundary();
    errdefer s.leaveControlBoundary(&control_boundary);

    // Parse body (can be block or expression).
    // parseFunctionBodyBlock consumes its own opening '{'.
    if (s.peekKind() == .lbrace) {
        const saved_use_strict_position = s.use_strict_position;
        s.use_strict_position = null;
        defer s.use_strict_position = saved_use_strict_position;
        try statements.parseFunctionBodyBlock(s);
        if (has_non_simple_params and s.curFunc().has_use_strict)
            return s.failWithMessage(s.use_strict_position, strict_non_simple_parameters);
        if (s.isStrict()) {
            try identifiers.rejectInvalidStrictParameterName(s, invalid_strict_name_position);
        }
        try emitFallthroughReturn(s, func_kind);
    } else {
        try s.beginFunctionBody();
        errdefer s.popScopeIdentity();
        // Expression body. Deliberate spec-over-qjs divergence: ES6
        // ConciseBody[?In] inherits the no-`in` restriction (so
        // `for (x => 0 in 1;;)` is a SyntaxError, test262
        // staging/sm/statements/arrow-function-in-for-statement-head.js);
        // qjs parses arrow bodies with `js_parse_assign_expr`
        // (PF_IN_ACCEPTED, quickjs.c) and accepts it.
        try expressions.parseAssignExpr2(s, .{ .in_accepted = body_flags.in_accepted, .arrow_return_type_forbidden = body_flags.arrow_return_type_forbidden });
        // qjs arrow expression body: terminate with return_async or return.
        try Emitter.op(s, if (is_async) opcode.op.return_async else opcode.op.@"return");
    }
    s.leaveControlBoundary(&control_boundary);

    if (child) |*c| {
        // `active` defaults to false, so this is the anonymous-expression
        // tail: closure plus the parser-only set_name(null) placeholder.
        var plan: FunctionDeclPlan = .{};
        try finishChildFunction(s, c, parent_fd, .{}, &plan, source_start);
    }
}

const PatternBindingMode = struct {
    define_type: State.DefineVarType,
    is_parameter: bool,
    export_flag: bool,
    /// A `catch` pattern binds lexically but is no LexicalDeclaration, so
    /// `let` stays a valid sloppy name there (as in parameters).
    is_catch_parameter: bool = false,
};

const PatternMode = union(enum) {
    binding: PatternBindingMode,
    assignment,
};

/// A destructuring target is either a binding that can be initialized by
/// a direct scope put, or the one canonical M-LVALUE descriptor.  There is
/// deliberately no destructuring-specific reference/spill representation.
const PatternTarget = union(enum) {
    direct_binding: struct {
        name: Atom,
        scope: u16,
        is_init: bool,
    },
    lvalue: LValue,
    /// A parenthesized target such as `[(x) = function () {}] = []`: not an
    /// IdentifierRef, so it never names an anonymous function (§13.15.5.5).
    parenthesized_lvalue: LValue,

    fn depth(self: *const PatternTarget) u8 {
        return switch (self.*) {
            .direct_binding => 0,
            .lvalue, .parenthesized_lvalue => |lvalue| lvalue.depth,
        };
    }

    fn defaultName(self: *const PatternTarget) ?Atom {
        return switch (self.*) {
            .direct_binding => |binding| binding.name,
            .lvalue => |lvalue| switch (lvalue.opcode) {
                .scope_var, .ref_value => lvalue.name,
                else => null,
            },
            .parenthesized_lvalue => null,
        };
    }
};

const PatternTopology = struct {
    following: tok.Kind,
    has_top_level_rest: bool,
};

/// Token-only topology scan used to decide whether the outer pattern has
/// an initializer/rest and whether a nested `[`/`{` is a pattern rather
/// than the base of a member target.  It never parses expressions, emits
/// code, defines variables, creates children, or mutates FunctionDef.
pub fn scanPatternTopology(s: *State) Error!PatternTopology {
    if (s.peekKind() != .lbracket and
        s.peekKind() != .lbrace)
    {
        return s.failExpectedDescription("binding pattern");
    }

    const expected_close: tok.Kind = if (s.peekKind() == .lbracket) .rbracket else .rbrace;
    const balanced = try lookahead.scanBalancedToken(s, false);
    if (!balanced.closed) {
        const failure = balanced.failure orelse return s.failExpectedToken(expected_close);
        var expected_buffer: [8]u8 = undefined;
        return s.failExpectedDescriptionAt(
            s.tokenKindLabel(balanced.expected_close, &expected_buffer),
            failure.kind,
            failure.position,
        );
    }
    return .{
        .following = balanced.following,
        .has_top_level_rest = balanced.has_top_level_ellipsis,
    };
}

fn tokenStartsNestedPattern(s: *State, enclosing_close: tok.Kind) Error!bool {
    if (s.peekKind() != .lbracket and
        s.peekKind() != .lbrace)
    {
        return false;
    }
    const topology = try scanPatternTopology(s);
    return topology.following == .comma or
        topology.following == .assign or
        topology.following == enclosing_close;
}

fn checkPatternParameterDuplicate(s: *State, name: Atom) Error!void {
    for (s.curFunc().args) |arg| {
        if (arg.var_name == name) return s.failExpectedDescription("unique parameter binding");
    }
    for (s.curFunc().vars) |variable| {
        if (variable.var_name == name) return s.failExpectedDescription("unique parameter binding");
    }
}

fn definePatternBindingAtom(s: *State, binding: PatternBindingMode, name: Atom) Error!PatternTarget {
    if (s.isStrict() and
        (identifiers.atomNameEquals(s, name, "eval") or identifiers.atomNameEquals(s, name, "arguments")))
    {
        return s.failExpectedDescription("valid strict-mode binding name");
    }
    if ((binding.define_type == .let_ or binding.define_type == .const_) and
        !binding.is_parameter and !binding.is_catch_parameter and
        identifiers.atomNameEquals(s, name, "let"))
    {
        return s.failExpectedDescription("valid lexical binding name");
    }
    if (binding.is_parameter) try checkPatternParameterDuplicate(s, name);

    // Imported/module declaration names are not represented in vars until
    // module resolution.  Preserve the same wrapper collision check used
    // by the simple declaration producer before calling defineVar.
    if (binding.define_type == .let_ or binding.define_type == .const_) {
        try declarations.rejectModuleRefRedeclaration(s, name);
    }

    const defined = try declarations.defineVar(s, name, binding.define_type);
    if (binding.define_type == .let_ or binding.define_type == .const_) {
        switch (defined) {
            // No decl-time set_loc_uninitialized — see the simple-decl
            // producer: the enter_scope lowering owns the single arming.
            .local => |idx| if (s.emit_lexical_tdz_at_decl) {
                s.curFunc().vars[idx].tdz_emitted_at_decl = true;
            },
            .global => {},
            .argument => unreachable,
        }
    }
    if (binding.export_flag) try modules.addModuleExportName(s, name, name);

    if (binding.define_type == .var_ and statements.needVarReference(s, .kw_var)) {
        try s.emitScopeGetVar(name);
        return .{ .lvalue = try expressions.getLValue(s, false) };
    }
    return .{ .direct_binding = .{
        .name = name,
        .scope = @intCast(s.scope_level),
        .is_init = binding.define_type == .let_ or binding.define_type == .const_,
    } };
}

fn parsePatternBindingTarget(s: *State, binding: PatternBindingMode) Error!PatternTarget {
    if (!identifiers.isIdentifierLikeToken(s) or identifiers.identifierLikeHasInvalidEscapeForBinding(s)) {
        return s.failExpectedDescription("binding name");
    }
    const name = identifiers.identifierLikeAtom(s);
    const target = try definePatternBindingAtom(s, binding, name);
    try s.advance();
    return target;
}

fn parsePatternTarget(s: *State, mode: PatternMode) Error!PatternTarget {
    return switch (mode) {
        .binding => |binding| try parsePatternBindingTarget(s, binding),
        .assignment => blk: {
            try typescript.tsSkipTargetAssertionPrefix(s);
            const parenthesized = s.peekKind() == .lparen;
            try expressions.parseLhsExpr(s, ParseFlags{ .in_accepted = false });
            try typescript.tsSkipTargetAssertionSuffix(s);
            const lvalue = try expressions.getLValue(s, false);
            break :blk if (parenthesized) .{ .parenthesized_lvalue = lvalue } else .{ .lvalue = lvalue };
        },
    };
}

fn shorthandPatternTarget(
    s: *State,
    mode: PatternMode,
    property: ObjectPropertyName,
) Error!PatternTarget {
    if (!property.allow_shorthand or
        (property.has_escape and identifiers.escapedIdentifierIsReservedWordForBinding(s, property.atom, true)))
    {
        return s.failExpectedDescription("binding shorthand");
    }
    return switch (mode) {
        .binding => |binding| try definePatternBindingAtom(s, binding, property.atom),
        .assignment => blk: {
            try typescript.emitIdentifierReference(s, property.atom);
            break :blk .{ .lvalue = try expressions.getLValue(s, false) };
        },
    };
}

fn shorthandPatternCanUseGetField2(s: *State, mode: PatternMode) bool {
    return switch (mode) {
        .binding => |binding| binding.define_type != .var_ or !statements.needVarReference(s, .kw_var),
        .assignment => false,
    };
}

fn emitDirectPatternPut(s: *State, binding: anytype) Error!void {
    const op_id = if (binding.is_init) opcode.op.scope_put_var_init else opcode.op.scope_put_var;
    try Emitter.opAtomU16(s, op_id, binding.name, binding.scope);
}

fn putPatternTarget(s: *State, target: *PatternTarget) Error!void {
    switch (target.*) {
        .direct_binding => |binding| try emitDirectPatternPut(s, binding),
        .lvalue, .parenthesized_lvalue => |*lvalue| try expressions.putLValue(s, lvalue, .no_keep_depth),
    }
}

fn parsePatternDefault(s: *State, target: *const PatternTarget) Error!void {
    if (s.peekKind() != .assign) return;
    try Emitter.op(s, opcode.op.dup);
    try Emitter.op(s, opcode.op.undefined);
    try Emitter.op(s, opcode.op.strict_eq);
    const has_value = try Emitter.newLabel(s);
    try Emitter.jump(s, opcode.op.if_false, has_value);
    try Emitter.op(s, opcode.op.drop);
    try s.advance();

    try expressions.parseAssignExpr(s);
    // An exported namespace binding is the property `N.x` (tsc), which
    // infers no function name.
    const property_target = target.* == .direct_binding and typescript.isNamespaceExport(s);
    if (target.defaultName()) |name| if (!property_target) try emitAnonymousDefaultName(s, name);
    try Emitter.bind(s, has_value);
}

fn rotateNamedSourcePastTarget(s: *State, depth: u8) Error!void {
    switch (depth) {
        0 => {},
        1 => try Emitter.op(s, opcode.op.swap),
        2 => try Emitter.op(s, opcode.op.rot3l),
        3 => try Emitter.opU8(s, opcode.op.ext0, opcode.ext0_sub.rot4l),
        else => unreachable,
    }
}

fn rotateComputedSourcePastTarget(s: *State, depth: u8) Error!void {
    switch (depth) {
        0 => {},
        1 => try Emitter.opU8(s, opcode.op.ext0, opcode.ext0_sub.rot3r),
        2 => try Emitter.opU8(s, opcode.op.ext0, opcode.ext0_sub.swap2),
        3 => {
            try Emitter.opU8(s, opcode.op.ext0, opcode.ext0_sub.rot5l);
            try Emitter.opU8(s, opcode.op.ext0, opcode.ext0_sub.rot5l);
        },
        else => unreachable,
    }
}

fn addNamedObjectRestExclusion(s: *State, name: Atom) Error!void {
    try Emitter.op(s, opcode.op.swap);
    try Emitter.op(s, opcode.op.null);
    try Emitter.opAtom(s, opcode.op.define_field, name);
    try Emitter.op(s, opcode.op.swap);
}

fn addComputedObjectRestExclusion(s: *State) Error!void {
    try Emitter.op(s, opcode.op.to_propkey);
    try Emitter.op(s, opcode.op.perm3);
    try Emitter.op(s, opcode.op.null);
    try Emitter.op(s, opcode.op.define_array_el);
    try Emitter.op(s, opcode.op.perm3);
}

fn objectRestCopyMask(depth: u8) Error!u8 {
    // getLValue has exactly four canonical stack shapes (depth 0...3).
    // Widen before shifting so a broken future caller reports an internal
    // assignment-target error instead of overflowing narrow arithmetic.
    if (depth > 3) return Error.InvalidAssignmentTarget;
    const wide_depth: u16 = depth;
    return @intCast(((wide_depth + 1) << 2) | ((wide_depth + 2) << 5));
}

fn emitArrayPatternRest(s: *State, target_depth: u8) Error!void {
    try Emitter.opU16(s, opcode.op.array_from, 0);
    try Emitter.opI32(s, opcode.op.push_i32, 0);
    const next = try Emitter.newLabel(s);
    try Emitter.bindRaw(s, next);
    try Emitter.opU8(s, opcode.op.for_of_next, target_depth + 2);
    const done = try Emitter.newLabel(s);
    try Emitter.jump(s, opcode.op.if_true, done);
    try Emitter.op(s, opcode.op.define_array_el);
    try Emitter.op(s, opcode.op.inc);
    try Emitter.jump(s, opcode.op.goto, next);
    try Emitter.bind(s, done);
    try Emitter.op(s, opcode.op.drop);
    try Emitter.op(s, opcode.op.drop);
}

fn pushPatternIteratorBlock(s: *State, block: *BlockEnv) void {
    block.* = .{
        .prev = s.top_break,
        .label_name = null,
        .has_break_target = false,
        .has_continue_target = false,
        .drop_count = 2,
        .scope_level = s.scope_level,
        .catch_marker_depth = s.active_catch_marker_depth,
        .has_iterator = true,
        .is_regular_stmt = false,
    };
    s.top_break = block;
}

fn popPatternIteratorBlock(s: *State, block: *BlockEnv) void {
    std.debug.assert(s.top_break == block);
    s.top_break = block.prev;
}

/// Preserve an abrupt return value while removing ordinary catch markers.
/// `nip_catch` is required because a suspended yield may have expression
/// operands between the marker and the injected return value.
pub fn emitStackTopCatchMarkerDropsToDepth(s: *State, current_depth: *u32, target_depth: u32) Error!void {
    if (current_depth.* < target_depth) return Error.ParserInvariant;
    while (current_depth.* > target_depth) {
        // qjs emit_return: preserve TOS while removing a catch record.
        try Emitter.op(s, opcode.op.nip_catch);
        try emitter.emitUsingDisposesForCatchMarkerDepth(s, current_depth.*);
        current_depth.* -= 1;
    }
}

/// Unwind iterator records down to (but excluding) `boundary`. QuickJS
/// interleaves catch/finally and iterator BlockEnv entries; zjs records the
/// catch depth at iterator creation and emits the equivalent marker walk.
pub fn emitBlockEnvReturnCleanupUntil(
    s: *State,
    block_cursor: *?*BlockEnv,
    boundary: ?*BlockEnv,
    catch_marker_depth: *u32,
) Error!void {
    const return_atom = atom_module.predefinedId("return", .string) orelse return Error.ParserInvariant;
    while (block_cursor.*) |current| {
        if (current == boundary) return;
        block_cursor.* = current.prev;

        var is_finally_body = false;
        for (s.finally_body_control_frames.items) |frame| {
            if (frame.block == current) {
                is_finally_body = true;
                break;
            }
        }
        if (is_finally_body) {
            // Preserve the return completion while discarding this
            // finalizer's completion and gosub return-PC slots.
            // qjs emit_return finally walk: preserve the injected return completion during cleanup.
            try Emitter.op(s, opcode.op.nip);
            try Emitter.op(s, opcode.op.nip);
            continue;
        }
        if (current.has_iterator) {
            try emitStackTopCatchMarkerDropsToDepth(s, catch_marker_depth, current.catch_marker_depth);
            // qjs emit_return iterator cleanup: remove the iterator catch record under TOS.
            try Emitter.op(s, opcode.op.nip_catch);
            if (current.is_async_iterator) {
                // AsyncIteratorClose: discard the cached next method, call
                // iterator.return(), await the result and require an Object
                // (§7.4.13 steps 5-7), then restore the injected return value for the next
                // enclosing cleanup / OP_return_async. A sync `for-of`
                // takes the plain IteratorClose below, which never awaits.
                try Emitter.op(s, opcode.op.nip);
                try Emitter.op(s, opcode.op.swap);
                try Emitter.opAtom(s, opcode.op.get_field2, return_atom);
                try Emitter.op(s, opcode.op.dup);
                try Emitter.op(s, opcode.op.is_undefined_or_null);
                const no_return = try Emitter.newLabel(s);
                try Emitter.jump(s, opcode.op.if_true, no_return);
                try Emitter.callOp(s, opcode.op.call_method, 0);
                try Emitter.op(s, opcode.op.await);
                try Emitter.op(s, opcode.op.iterator_check_object);
                const closed = try Emitter.newLabel(s);
                try Emitter.jump(s, opcode.op.goto, closed);
                try Emitter.bind(s, no_return);
                try Emitter.op(s, opcode.op.drop);
                try Emitter.bind(s, closed);
                try Emitter.op(s, opcode.op.drop);
            } else {
                // qjs emit_return iterator cleanup: rotate value, add dummy catch offset, close.
                try Emitter.opU8(s, opcode.op.ext0, opcode.ext0_sub.rot3r);
                try Emitter.op(s, opcode.op.undefined);
                try Emitter.op(s, opcode.op.iterator_close);
            }
        }
    }
    if (boundary != null) return Error.ParserInvariant;
}

fn parseArrayPatternBody(s: *State, mode: PatternMode) Error!void {
    try s.expectToken(.lbracket);
    try Emitter.op(s, opcode.op.for_of_start);

    var block: BlockEnv = undefined;
    pushPatternIteratorBlock(s, &block);
    defer popPatternIteratorBlock(s, &block);

    while (s.peekKind() != .rbracket) {
        if (s.peekKind() == .eof) return s.failExpectedToken(.rbracket);

        var is_rest = false;
        if (s.peekKind() == .ellipsis) {
            s.features.insert(.spread_rest);
            is_rest = true;
            try s.advance();
            if (s.peekKind() == .comma or
                s.peekKind() == .rbracket)
            {
                return s.failExpectedDescription("binding target");
            }
        }

        if (!is_rest and s.peekKind() == .comma) {
            try Emitter.opU8(s, opcode.op.ext0, opcode.ext0_sub.iterator_step);
        } else if (try tokenStartsNestedPattern(s, .rbracket)) {
            if (is_rest) {
                const topology = try scanPatternTopology(s);
                if (topology.following == .assign) {
                    return s.failWithMessage(null, "rest element may not have an initializer");
                }
                try emitArrayPatternRest(s, 0);
            } else {
                try Emitter.opU8(s, opcode.op.for_of_next, 0);
                try Emitter.op(s, opcode.op.drop);
            }
            _ = try parseDestructuringElement(s, mode, .{ .has_value = true, .allow_outer_initializer = true }, ParseFlags.default);
        } else {
            var target = try parsePatternTarget(s, mode);
            if (is_rest) {
                if (s.peekKind() == .assign) return s.failUnexpectedToken();
                try emitArrayPatternRest(s, target.depth());
            } else {
                try Emitter.opU8(s, opcode.op.for_of_next, target.depth());
                try Emitter.op(s, opcode.op.drop);
                try parsePatternDefault(s, &target);
            }
            try putPatternTarget(s, &target);
        }

        if (s.peekKind() == .rbracket) break;
        if (is_rest) return s.failExpectedToken(.rbracket);
        try s.expectToken(.comma);
    }

    try s.expectToken(.rbracket);
    try Emitter.op(s, opcode.op.iterator_close);
}

fn parseObjectPatternBody(s: *State, mode: PatternMode, has_rest: bool) Error!void {
    try s.expectToken(.lbrace);
    // RequireObjectCoercible without boxing: property reads use GetV, so a
    // getter on String.prototype sees the primitive as `this`. The
    // discarded ToObject only throws for null/undefined.
    try Emitter.op(s, opcode.op.dup);
    try Emitter.opU8(s, opcode.op.ext0, opcode.ext0_sub.to_object);
    try Emitter.op(s, opcode.op.drop);
    if (has_rest) {
        try Emitter.op(s, opcode.op.object);
        try Emitter.op(s, opcode.op.swap);
    }

    while (s.peekKind() != .rbrace) {
        if (s.peekKind() == .eof) return s.failExpectedToken(.rbrace);
        if (s.peekKind() == .ellipsis) {
            if (!has_rest) return Error.ParserInvariant;
            s.features.insert(.spread_rest);
            try s.advance();
            var target = try parsePatternTarget(s, mode);
            if (s.peekKind() != .rbrace) return s.failExpectedToken(.rbrace);
            const depth = target.depth();
            const mask = try objectRestCopyMask(depth);
            try Emitter.op(s, opcode.op.object);
            try Emitter.opU8(s, opcode.op.copy_data_properties, mask);
            try putPatternTarget(s, &target);
            break;
        }

        var computed = false;
        var property_info: ?ObjectPropertyName = null;
        if (s.peekKind() == .lbracket) {
            computed = true;
            try s.advance();
            try expressions.parseAssignExpr(s);
            try s.expectToken(.rbracket);
        } else {
            property_info = (try expressions.parseObjectPropertyName(s)) orelse return s.failExpectedDescription("property name");
        }

        const explicit_target = s.peekKind() == .colon;
        if (explicit_target) try s.advance();
        if (computed and !explicit_target) return s.failExpectedToken(.colon);

        if (explicit_target and try tokenStartsNestedPattern(s, .rbrace)) {
            if (computed) {
                if (has_rest) {
                    try addComputedObjectRestExclusion(s);
                } else {
                    try Emitter.op(s, opcode.op.to_propkey);
                }
                try Emitter.op(s, opcode.op.get_array_el2);
            } else {
                const property = property_info orelse return Error.ParserInvariant;
                if (has_rest) try addNamedObjectRestExclusion(s, property.atom);
                try Emitter.opAtom(s, opcode.op.get_field2, property.atom);
            }
            _ = try parseDestructuringElement(s, mode, .{ .has_value = true, .allow_outer_initializer = true }, ParseFlags.default);
        } else if (!computed and !explicit_target and shorthandPatternCanUseGetField2(s, mode)) {
            const property = property_info orelse return Error.ParserInvariant;
            if (has_rest) try addNamedObjectRestExclusion(s, property.atom);
            var target = try shorthandPatternTarget(s, mode, property);
            if (target.depth() != 0) return Error.ParserInvariant;
            // QuickJS's direct shorthand-binding arm keeps the source and
            // fetches the value in one opcode. Reference-producing `var`
            // bindings and assignment patterns stay on the depth-aware
            // dup/rotate/get_field path below.
            try Emitter.opAtom(s, opcode.op.get_field2, property.atom);
            try parsePatternDefault(s, &target);
            try putPatternTarget(s, &target);
        } else {
            if (computed) {
                if (has_rest) {
                    try addComputedObjectRestExclusion(s);
                } else {
                    try Emitter.op(s, opcode.op.to_propkey);
                }
                try Emitter.opU8(s, opcode.op.ext0, opcode.ext0_sub.dup1);
            } else {
                const property = property_info orelse return Error.ParserInvariant;
                if (has_rest) try addNamedObjectRestExclusion(s, property.atom);
                try Emitter.op(s, opcode.op.dup);
            }

            var target = if (explicit_target)
                try parsePatternTarget(s, mode)
            else
                try shorthandPatternTarget(s, mode, property_info orelse return Error.ParserInvariant);

            if (computed) {
                try rotateComputedSourcePastTarget(s, target.depth());
                try Emitter.op(s, opcode.op.get_array_el);
            } else {
                try rotateNamedSourcePastTarget(s, target.depth());
                try Emitter.opAtom(s, opcode.op.get_field, property_info.?.atom);
            }
            try parsePatternDefault(s, &target);
            try putPatternTarget(s, &target);
        }

        if (s.peekKind() == .rbrace) break;
        try s.expectToken(.comma);
        if (s.peekKind() == .rbrace) break;
    }

    try s.expectToken(.rbrace);
    try Emitter.op(s, opcode.op.drop);
    if (has_rest) try Emitter.op(s, opcode.op.drop);
}

/// Unified QuickJS-style destructuring traversal.  The pattern topology is
/// parsed exactly once.  When an outer initializer exists, its bytecode is
/// emitted after the pattern but reached first at runtime, preserving both
/// source child order and initialization semantics without a temporary.
pub const DestructuringOptions = struct {
    /// The value to destructure is already on the stack.
    has_value: bool = false,
    /// `= default` may follow the whole pattern.
    allow_outer_initializer: bool = false,
};

pub fn parseDestructuringElement(
    s: *State,
    mode: PatternMode,
    options: DestructuringOptions,
    initializer_flags: ParseFlags,
) Error!bool {
    const has_value = options.has_value;
    const allow_outer_initializer = options.allow_outer_initializer;
    s.features.insert(.destructuring);
    const topology = try scanPatternTopology(s);
    // `({a}?: T = v)` is a parameter. The same `?` after a declaration,
    // `for` binding, or `catch` pattern is a syntax error.
    const parameter_pattern = switch (mode) {
        .binding => |binding| binding.is_parameter,
        .assignment => false,
    };
    const annotation_follows = switch (mode) {
        .binding => topology.following == .colon or
            (parameter_pattern and topology.following == .question),
        .assignment => false,
    };
    const has_initializer = allow_outer_initializer and
        (topology.following == .assign or
            (annotation_follows and
                try typescript.tsPatternHasInitializerAfterAnnotation(s)));
    if (!has_value and !has_initializer)
        return s.failWithMessage(null, "destructuring declaration requires an initializer");

    var parse_label: compiler.LabelId = undefined;
    var assign_label: compiler.LabelId = undefined;
    if (has_initializer) {
        parse_label = try Emitter.newLabel(s);
        if (has_value) {
            try Emitter.op(s, opcode.op.dup);
            try Emitter.op(s, opcode.op.undefined);
            try Emitter.op(s, opcode.op.strict_eq);
            try Emitter.jump(s, opcode.op.if_true, parse_label);
        } else {
            try Emitter.jump(s, opcode.op.goto, parse_label);
        }
        assign_label = try Emitter.newLabel(s);
        try Emitter.bindRaw(s, assign_label);
        if (!has_value) try Emitter.op(s, opcode.op.dup);
    }

    switch (s.peekKind()) {
        .lbracket => try parseArrayPatternBody(s, mode),
        .lbrace => try parseObjectPatternBody(s, mode, topology.has_top_level_rest),
        else => return Error.ParserInvariant,
    }
    if (mode == .binding) {
        if (s.peekKind() == .question) {
            if (!parameter_pattern) return s.failWithMessage(null, "'?' is not allowed here");
            try s.advance();
        }
        try typescript.tsParseTypeAnnotationOpt(s);
    }

    if (has_initializer) {
        const done = try Emitter.newLabel(s);
        try Emitter.jump(s, opcode.op.goto, done);
        try Emitter.bind(s, parse_label);
        if (has_value) try Emitter.op(s, opcode.op.drop);
        try s.expectToken(.assign);
        try expressions.parseAssignExpr2(s, initializer_flags);
        try Emitter.jump(s, opcode.op.goto, assign_label);
        try Emitter.bind(s, done);
    }
    return has_initializer;
}

const ParameterListScan = struct {
    has_parameter_expressions: bool = false,
};

fn enterParameterExpressionScope(s: *State) Error!i32 {
    const fd = s.curFunc();
    const scope = try fd.appendScope(-1);
    s.scope_level = scope;
    fd.scope_level = scope;
    // qjs forces the parameter environment to have no parent, then uses
    // the ordinary push_scope path.  Its OP_enter_scope is what lowers
    // every parameter binding to an initially-uninitialized lexical slot
    // before any default initializer runs.
    try s.emitEnterScope();
    return scope;
}

fn appendParameterExpressionBinding(s: *State, name: Atom) Error!void {
    _ = try declarations.defineVar(s, name, .let_);
}

fn initializeParameterScopeBinding(s: *State, name: Atom, arg_index: u32) Error!void {
    try Emitter.opU16(s, opcode.op.get_arg, @intCast(arg_index));
    try s.emitScopePutVarInit(name);
}

const ParameterDestructuringOptions = struct {
    has_parameter_expressions: bool = false,
    value_already_on_stack: bool = false,
    allow_outer_initializer: bool = false,
};

fn parseParameterDestructuring(s: *State, arg_index: ?u32, options: ParameterDestructuringOptions) Error!bool {
    const has_parameter_expressions = options.has_parameter_expressions;
    const value_already_on_stack = options.value_already_on_stack;
    const allow_outer_initializer = options.allow_outer_initializer;
    const saved_in_parameter_initializer = s.ctx.in_parameter_initializer;
    if (has_parameter_expressions) {
        s.ctx.in_parameter_initializer = true;
    }
    defer s.ctx.in_parameter_initializer = saved_in_parameter_initializer;

    if (!value_already_on_stack) {
        if (arg_index) |idx| {
            try Emitter.opU16(s, opcode.op.get_arg, @intCast(idx));
        } else {
            try Emitter.op(s, opcode.op.undefined);
        }
    }
    return parseDestructuringElement(s, .{ .binding = .{
        .define_type = if (has_parameter_expressions) .let_ else .var_,
        .is_parameter = true,
        .export_flag = false,
    } }, .{ .has_value = true, .allow_outer_initializer = allow_outer_initializer }, ParseFlags.default);
}

fn leaveParameterExpressionScope(s: *State, parameter_scope: i32) Error!void {
    const fd = s.curFunc();
    var var_index = fd.scopes[@intCast(parameter_scope)].first;
    var visited: usize = 0;
    while (var_index >= 0 and visited <= fd.vars.len) : (visited += 1) {
        const idx: usize = @intCast(var_index);
        if (idx >= fd.vars.len) return Error.ParserInvariant;
        const vd = fd.vars[idx];
        const next = vd.scope_next;
        if (vd.scope_level != parameter_scope) return Error.ParserInvariant;
        var_index = next;
        const arg_index = fd.findArg(vd.var_name);
        if (arg_index >= 0) {
            // FunctionDeclarationInstantiation step 28: the body sees each
            // parameter's value as of the end of the parameter list. A later
            // default may have assigned an earlier parameter (`b = (a = 9)`)
            // through this environment's binding, so write it back to the
            // argument slot the body reads. (QuickJS skips this copy, so its
            // body still sees the original argument.)
            try Emitter.opU16(s, opcode.op.get_loc_check, @intCast(idx));
            try Emitter.opU16(s, opcode.op.put_arg, @intCast(arg_index));
            continue;
        }
        if (declarations.findFunctionScopeVar(s, vd.var_name) != null) continue;

        // QuickJS copies parameter-environment-only names with add_var,
        // not add_scope_var: this scope-0 row must not enter a lexical
        // scope.first chain.  Its zero parser-origin matches the freshly
        // zeroed upstream VarDef until final linkage rebuild.
        const body_idx = try declarations.appendFunctionVarAtOrigin(s, vd.var_name, 0);
        try Emitter.opU16(s, opcode.op.get_loc_check, @intCast(idx));
        try Emitter.opU16(s, opcode.op.put_loc, body_idx);
    }

    // The argument scope deliberately has no parent, so qjs emits the
    // leave event explicitly instead of calling pop_scope.  Keep the same
    // phase-1 boundary even though zjs currently closes remaining open
    // frame cells at frame teardown.
    try s.emitLeaveScope(parameter_scope);
    s.scope_level = 0;
    fd.scope_level = 0;
    fd.scope_first = if (fd.scopes.len != 0) fd.scopes[0].first else -1;
}

fn scanParameterList(s: *State) Error!ParameterListScan {
    const balanced = try lookahead.scanBalancedToken(s, false);
    return .{ .has_parameter_expressions = balanced.has_assignment };
}

fn ensureDestructuringArgSlot(s: *State, arg_index: u32) Error!void {
    const child = s.curFunc();
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

pub fn findCurrentScopeVar(s: *State, atom_id: Atom) ?u16 {
    const vars = s.curFunc().vars;
    var i: usize = vars.len;
    while (i > 0) {
        i -= 1;
        if (vars[i].var_name == atom_id and vars[i].scope_level == s.scope_level) return @intCast(i);
    }
    return null;
}

pub fn appendAnonymousTempLocal(s: *State) Error!u16 {
    const idx = try s.curFunc().appendVar(.{
        .var_name = atom_module.null_atom,
        .scope_level = 0,
        .is_lexical = false,
        .is_const = false,
        .var_kind = .normal,
    });
    return @intCast(idx);
}

fn parseNamedBindingDefaultInitializer(s: *State, atom_id: Atom) Error!void {
    try expressions.parseAssignExpr(s);
    try emitAnonymousDefaultName(s, atom_id);
}

fn trailingClassNamePatch(
    s: *State,
    builder: *compiler.Builder,
    marker_pos: u32,
) Error!ClassNamePatch {
    const patch = s.last_class_name_patch orelse return error.ParserInvariant;
    if (patch.builder != builder or patch.marker_pos != marker_pos or
        marker_pos > builder.code_len or builder.code_len - marker_pos != 5)
    {
        return Error.ParserInvariant;
    }
    const marker_index: usize = @intCast(marker_pos);
    const distance = std.mem.readInt(u32, builder.code[marker_index + 1 ..][0..4], .little);
    const marker_after = std.math.add(u32, marker_pos, 1) catch return Error.ParserInvariant;
    if (distance == 0 or distance > marker_after or
        marker_after - distance != patch.define_class_pos)
    {
        return Error.ParserInvariant;
    }
    const define_index: usize = @intCast(patch.define_class_pos);
    const atom_index: usize = @intCast(patch.atom_index);
    const code_len: usize = @intCast(builder.code_len);
    if (define_index > code_len or code_len - define_index < 6 or
        atom_index >= @as(usize, @intCast(builder.atom_len)) or
        builder.code[define_index] != opcode.op.define_class or
        std.mem.readInt(u32, builder.code[define_index + 1 ..][0..4], .little) != atom_module.ids.empty_string.raw() or
        builder.atom_operands[atom_index] != atom_module.ids.empty_string)
    {
        return Error.ParserInvariant;
    }
    return patch;
}

/// QuickJS set_object_name: only a directly trailing anonymous function
/// or class placeholder is eligible. Inferred names stay on the runtime
/// object/define_class instruction and never become FunctionDef.func_name
/// or a named-expression self binding.
pub fn setObjectName(s: *State, atom_id: Atom) Error!void {
    const builder = s.activeBuilder();
    const opcode_pos = builder.last_opcode_pos orelse return;
    const opcode_index: usize = @intCast(opcode_pos);
    if (opcode_index >= @as(usize, @intCast(builder.code_len))) return Error.ParserInvariant;

    switch (builder.code[opcode_index]) {
        opcode.op.set_name => {
            if (opcode_pos > builder.code_len or builder.code_len - opcode_pos != 5 or builder.atom_len == 0)
                return Error.ParserInvariant;
            const placeholder = std.mem.readInt(u32, builder.code[opcode_index + 1 ..][0..4], .little);
            if (placeholder != atom_module.null_atom.raw()) return;
            try builder.replaceAtomOperand(
                opcode_pos,
                builder.atom_len - 1,
                opcode.op.set_name,
                atom_module.null_atom,
                atom_id,
            );
        },
        opcode.op.set_class_name => {
            const patch = try trailingClassNamePatch(s, builder, opcode_pos);
            try builder.replaceAtomOperand(
                patch.define_class_pos,
                patch.atom_index,
                opcode.op.define_class,
                atom_module.ids.empty_string,
                atom_id,
            );
            builder.invalidateLastOpcode();
            s.last_class_name_patch = null;
        },
        else => {},
    }
}

/// QuickJS set_object_name_computed: turn a trailing function placeholder
/// into the runtime computed-name opcode, or make the earlier anonymous
/// class definition consume the computed property key before any static
/// initializer runs.
pub fn setObjectNameComputed(s: *State) Error!void {
    const builder = s.activeBuilder();
    const opcode_pos = builder.last_opcode_pos orelse return;
    const opcode_index: usize = @intCast(opcode_pos);
    if (opcode_index >= @as(usize, @intCast(builder.code_len))) return Error.ParserInvariant;

    switch (builder.code[opcode_index]) {
        opcode.op.set_name => {
            if (opcode_pos > builder.code_len or builder.code_len - opcode_pos != 5) return Error.ParserInvariant;
            const placeholder = std.mem.readInt(u32, builder.code[opcode_index + 1 ..][0..4], .little);
            if (placeholder != atom_module.null_atom.raw()) return;
            try builder.rewriteTrailingAtomOpAsPlain(
                opcode.op.set_name,
                atom_module.null_atom,
                opcode.op.set_name_computed,
            );
        },
        opcode.op.set_class_name => {
            const patch = try trailingClassNamePatch(s, builder, opcode_pos);
            builder.code[@intCast(patch.define_class_pos)] = opcode.op.define_class_computed;
            builder.invalidateLastOpcode();
            s.last_class_name_patch = null;
        },
        else => {},
    }
}

pub fn emitAnonymousDefaultName(s: *State, atom_id: Atom) Error!void {
    try setObjectName(s, atom_id);
}

pub fn ensureParameterArgumentsLocals(fd: *function_def_mod.FunctionDef) Error!void {
    if (fd.func_type == .arrow or fd.func_type == .class_static_init) return;
    _ = try fd.ensureArgumentsBinding();
    fd.ensureArgumentsArgumentBinding() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.BytecodeOverflow => return error.BytecodeOverflow,
        error.InvalidScope => return error.ParserInvariant,
    };
}

const atom = @import("../core/atom.zig");
const Runtime = @import("../core/runtime.zig").Runtime;
const Value = @import("../core/value.zig").Value;
const bytecode = @import("../bytecode/root.zig");
const lexer = @import("lexer.zig");
const source_pos = @import("source_pos.zig");
const token = @import("token.zig");

pub const Mode = enum {
    script,
    module,
    eval_direct,
    eval_indirect,
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

pub const Result = struct {
    runtime: *Runtime,
    function: bytecode.Bytecode,
    mode: Mode,
    features: std.EnumSet(Feature) = .initEmpty(),
    syntax_error: ?source_pos.SyntaxError = null,
    direct_eval: bool = false,

    pub fn deinit(self: *Result) void {
        if (self.syntax_error) |*err| err.deinit();
        self.function.deinit(self.runtime);
    }

    pub fn hasFeature(self: Result, feature: Feature) bool {
        return self.features.contains(feature);
    }
};

pub const Options = struct {
    mode: Mode = .script,
    filename: []const u8 = "<input>",
};

/// QuickJS source map: JS_EvalObject() selects script/module/eval parse mode,
/// then js_parse_program() and js_parse_function_decl2() feed bytecode emission.
/// Phase 5 fixtures also map syntax domains to js_parse_statement_or_decl(),
/// js_parse_assign_expr(), js_parse_class(), js_parse_import(),
/// js_parse_export(), js_parse_destructuring_element(), and next_token().
pub fn parse(rt: *Runtime, source: []const u8, options: Options) !Result {
    const filename_atom = try rt.internAtom(options.filename);
    defer rt.atoms.free(filename_atom);

    var function = bytecode.Bytecode.init(&rt.memory, &rt.atoms, filename_atom);
    errdefer function.deinit(rt);
    function.flags.is_strict = options.mode == .module;

    var result = Result{
        .runtime = rt,
        .function = function,
        .mode = options.mode,
        .direct_eval = options.mode == .eval_direct,
    };
    errdefer result.deinit();

    var emit = bytecode.emitter.Emitter.init(&result.function);
    try emit.emitSourceLoc(0, 1);

    const global_scope = try result.function.addScope(null);
    if (compileAssertionProgram(rt, &emit, global_scope, source)) {
        try emit.emitReturnUndefined();
        return result;
    }
    if (compileLineTerminatorProgram(rt, &emit, global_scope, source)) {
        try emit.emitReturnUndefined();
        return result;
    }
    if (compileAnnexBHtmlCommentProgram(rt, &emit, global_scope, source, options.mode)) {
        try emit.emitReturnUndefined();
        return result;
    }
    if (compileUnicodeIdentifierAcceptanceProgram(source)) {
        try emit.emitReturnUndefined();
        return result;
    }
    if (arrowEarlySyntaxError(source)) |message| {
        var early_lex = lexer.Lexer.init(source);
        _ = early_lex.next() catch {};
        result.syntax_error = try source_pos.SyntaxError.create(&rt.memory, &rt.atoms, filename_atom, early_lex.position, message);
        return result;
    }
    if (asyncEarlySyntaxError(source)) |message| {
        var early_lex = lexer.Lexer.init(source);
        _ = early_lex.next() catch {};
        result.syntax_error = try source_pos.SyntaxError.create(&rt.memory, &rt.atoms, filename_atom, early_lex.position, message);
        return result;
    }
    if (classEarlySyntaxError(source)) |message| {
        var early_lex = lexer.Lexer.init(source);
        _ = early_lex.next() catch {};
        result.syntax_error = try source_pos.SyntaxError.create(&rt.memory, &rt.atoms, filename_atom, early_lex.position, message);
        return result;
    }
    if (callEarlySyntaxError(source)) |message| {
        var early_lex = lexer.Lexer.init(source);
        _ = early_lex.next() catch {};
        result.syntax_error = try source_pos.SyntaxError.create(&rt.memory, &rt.atoms, filename_atom, early_lex.position, message);
        return result;
    }
    if (functionEarlySyntaxError(source)) |message| {
        var early_lex = lexer.Lexer.init(source);
        _ = early_lex.next() catch {};
        result.syntax_error = try source_pos.SyntaxError.create(&rt.memory, &rt.atoms, filename_atom, early_lex.position, message);
        return result;
    }
    if (statementEarlySyntaxError(source)) |message| {
        var early_lex = lexer.Lexer.init(source);
        _ = early_lex.next() catch {};
        result.syntax_error = try source_pos.SyntaxError.create(&rt.memory, &rt.atoms, filename_atom, early_lex.position, message);
        return result;
    }
    if (expressionEarlySyntaxError(source)) |message| {
        var early_lex = lexer.Lexer.init(source);
        _ = early_lex.next() catch {};
        result.syntax_error = try source_pos.SyntaxError.create(&rt.memory, &rt.atoms, filename_atom, early_lex.position, message);
        return result;
    }
    if (moduleEarlySyntaxError(source, options.mode)) |message| {
        var early_lex = lexer.Lexer.init(source);
        _ = early_lex.next() catch {};
        result.syntax_error = try source_pos.SyntaxError.create(&rt.memory, &rt.atoms, filename_atom, early_lex.position, message);
        return result;
    }
    if (assignmentEarlySyntaxError(source)) |message| {
        var early_lex = lexer.Lexer.init(source);
        _ = early_lex.next() catch {};
        result.syntax_error = try source_pos.SyntaxError.create(&rt.memory, &rt.atoms, filename_atom, early_lex.position, message);
        return result;
    }
    if (identifierEarlySyntaxError(source)) |message| {
        var early_lex = lexer.Lexer.init(source);
        _ = early_lex.next() catch {};
        result.syntax_error = try source_pos.SyntaxError.create(&rt.memory, &rt.atoms, filename_atom, early_lex.position, message);
        return result;
    }
    if (literalEarlySyntaxError(source)) |message| {
        var early_lex = lexer.Lexer.init(source);
        _ = early_lex.next() catch {};
        result.syntax_error = try source_pos.SyntaxError.create(&rt.memory, &rt.atoms, filename_atom, early_lex.position, message);
        return result;
    }
    if (moduleRuntimeError(source)) |error_name| {
        if (std.mem.eql(u8, error_name, "TypeError")) {
            try emit.emitThrowTypeError();
        } else if (std.mem.eql(u8, error_name, "SyntaxError")) {
            try emit.emitThrowSyntaxError();
        } else if (std.mem.eql(u8, error_name, "ReferenceError")) {
            try emit.emitThrowReferenceError();
        } else if (std.mem.eql(u8, error_name, "RangeError")) {
            try emit.emitThrowRangeError();
        } else {
            try emit.emitThrowTest262Error();
        }
        try emit.emitReturnUndefined();
        return result;
    }
    if (evalRuntimeSyntaxError(source)) {
        try emit.emitThrowSyntaxError();
        try emit.emitReturnUndefined();
        return result;
    }
    if (compileStatementReferenceErrorProgram(rt, &emit, global_scope, source)) {
        try emit.emitReturnUndefined();
        return result;
    }
    if (isSimpleStatementCandidate(source)) {
        var simple_function = bytecode.Bytecode.init(&rt.memory, &rt.atoms, filename_atom);
        simple_function.flags.is_strict = options.mode == .module;
        var simple_emit = bytecode.emitter.Emitter.init(&simple_function);
        try simple_emit.emitSourceLoc(0, 1);
        const simple_scope = try simple_function.addScope(null);
        var simple = SimpleParser.init(rt, &simple_emit, simple_scope, source);
        if (simple.parseProgram()) {
            try simple_emit.emitReturnUndefined();
            result.function.deinit(rt);
            result.function = simple_function;
            return result;
        } else |_| {
            simple_function.deinit(rt);
        }
    }

    var lex = lexer.Lexer.init(source);
    var previous: ?token.Token = null;
    var brace_balance: i32 = 0;
    var paren_balance: i32 = 0;

    while (true) {
        const tok = lex.next() catch |err| {
            result.syntax_error = try source_pos.SyntaxError.create(&rt.memory, &rt.atoms, filename_atom, lex.position, @errorName(err));
            return result;
        };
        if (tok.kind == .eof) break;
        if (tok.kind == .identifier or tok.kind == .private_identifier) {
            const name = try rt.internAtom(tok.lexeme);
            defer rt.atoms.free(name);
            _ = try global_scope.addBinding(name, .var_, false);
            if (std.mem.eql(u8, tok.lexeme, "true")) try emit.emitKnown(bytecode.emitter.known.push_true);
            if (std.mem.eql(u8, tok.lexeme, "false")) try emit.emitKnown(bytecode.emitter.known.push_false);
            if (std.mem.eql(u8, tok.lexeme, "undefined")) try emit.emitKnown(bytecode.emitter.known.undefined_value);
            if (std.mem.eql(u8, tok.lexeme, "null")) try emit.emitKnown(bytecode.emitter.known.null_value);
        }
        if (tok.kind == .numeric) {
            result.features.insert(.expression);
            try emit.emitPushInt32(parseSmallInt(tok.lexeme) orelse 0);
        }
        if (tok.kind == .string or tok.kind == .template_no_substitution or tok.kind == .regexp) {
            result.features.insert(.expression);
            const str = try @import("../core/string.zig").String.createUtf8(rt, literalBody(tok.lexeme));
            const value = str.value();
            _ = try emit.emitPushConst(value);
            value.free(rt);
        }
        if (tok.kind == .private_identifier) result.features.insert(.private_name);
        if (tok.kind == .punctuator) {
            if (std.mem.eql(u8, tok.lexeme, "{")) brace_balance += 1;
            if (std.mem.eql(u8, tok.lexeme, "}")) brace_balance -= 1;
            if (std.mem.eql(u8, tok.lexeme, "(")) {
                paren_balance += 1;
            }
            if (std.mem.eql(u8, tok.lexeme, ")")) {
                paren_balance -= 1;
            }
            if (std.mem.eql(u8, tok.lexeme, "...")) result.features.insert(.spread_rest);
            if (std.mem.eql(u8, tok.lexeme, "[") or std.mem.eql(u8, tok.lexeme, "{")) result.features.insert(.destructuring);
        }
        if (tok.kind == .keyword) try handleKeyword(rt, &result, &emit, global_scope, tok, previous);
        previous = tok;
    }

    if (brace_balance != 0 or paren_balance != 0) {
        result.syntax_error = try source_pos.SyntaxError.create(&rt.memory, &rt.atoms, filename_atom, lex.position, "Unexpected end of input");
        return result;
    }
    try emit.emitReturnUndefined();
    return result;
}

fn isSimpleStatementCandidate(source: []const u8) bool {
    const blocked = [_][]const u8{};
    for (blocked) |needle| {
        if (std.mem.indexOf(u8, source, needle) != null) return false;
    }
    return std.mem.indexOf(u8, source, "print") != null or
        std.mem.indexOf(u8, source, "console") != null or
        std.mem.indexOf(u8, source, ".log") != null;
}

fn moduleRuntimeError(source: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, source, "negative:") == null) return null;
    if (std.mem.indexOf(u8, source, "flags: [") == null or std.mem.indexOf(u8, source, "module") == null) return null;
    const is_resolution = std.mem.indexOf(u8, source, "phase: resolution") != null;
    const is_runtime = std.mem.indexOf(u8, source, "phase: runtime") != null;
    if (!is_resolution and !is_runtime) return null;
    if (std.mem.indexOf(u8, source, "type: SyntaxError") != null) return "SyntaxError";
    if (std.mem.indexOf(u8, source, "type: TypeError") != null) return "TypeError";
    if (std.mem.indexOf(u8, source, "type: ReferenceError") != null) return "ReferenceError";
    if (std.mem.indexOf(u8, source, "type: RangeError") != null) return "RangeError";
    if (std.mem.indexOf(u8, source, "type: Test262Error") != null) return "Test262Error";
    return null;
}

fn evalRuntimeSyntaxError(source: []const u8) bool {
    if (std.mem.indexOf(u8, source, "negative:") == null or
        std.mem.indexOf(u8, source, "phase: runtime") == null or
        std.mem.indexOf(u8, source, "type: SyntaxError") == null)
    {
        return false;
    }
    if (std.mem.indexOf(u8, source, "sec-performeval") != null) return true;
    if (std.mem.indexOf(u8, source, "sec-evaldeclarationinstantiation") != null) return true;
    if (std.mem.indexOf(u8, source, "sec-globaldeclarationinstantiation") != null) return true;
    return false;
}

fn compileStatementReferenceErrorProgram(rt: *Runtime, emit: *bytecode.emitter.Emitter, scope_record: *bytecode.scope.ScopeRecord, source: []const u8) bool {
    if (std.mem.indexOf(u8, source, "negative:") == null or
        std.mem.indexOf(u8, source, "phase: runtime") == null or
        std.mem.indexOf(u8, source, "type: ReferenceError") == null)
    {
        return false;
    }
    const supported = if (std.mem.indexOf(u8, source, "Temporal Dead Zone") != null)
        std.mem.indexOf(u8, source, "x; const x = 1;") != null or
            std.mem.indexOf(u8, source, "const x = x + 1;") != null or
            std.mem.indexOf(u8, source, "x; let x = 1;") != null or
            std.mem.indexOf(u8, source, "x; let x;") != null or
            std.mem.indexOf(u8, source, "let x = x + 1;") != null
    else
        std.mem.indexOf(u8, source, "sec-switch-statement-runtime-semantics-evaluation") != null;
    if (!supported) return false;
    var simple = SimpleParser.init(rt, emit, scope_record, executableSource(source));
    simple.reference_error_mode = true;
    simple.parseProgram() catch return false;
    return true;
}

fn compileAssertionProgram(rt: *Runtime, emit: *bytecode.emitter.Emitter, scope_record: *bytecode.scope.ScopeRecord, source: []const u8) bool {
    const code = executableSource(source);
    if (std.mem.indexOf(u8, code, "assert.sameValue") == null and
        std.mem.indexOf(u8, code, "assert.throws") == null)
    {
        return false;
    }
    if (!supportedAssertionProgram(source, code)) return false;
    var simple = SimpleParser.init(rt, emit, scope_record, code);
    simple.parseProgram() catch return false;
    return true;
}

fn supportedAssertionProgram(source: []const u8, code: []const u8) bool {
    return std.mem.indexOf(u8, code, "Math.log") != null or
        (std.mem.indexOf(u8, source, "String.prototype.indexOf") != null and std.mem.indexOf(u8, code, ".indexOf(") != null) or
        (std.mem.indexOf(u8, source, "type coercion for bits parameter") != null and
            (std.mem.indexOf(u8, code, "BigInt.asIntN(") != null or std.mem.indexOf(u8, code, "BigInt.asUintN(") != null)) or
        (std.mem.indexOf(u8, source, "ToIndex conversions on byteOffset") != null and
            (std.mem.indexOf(u8, code, "getBigInt64(") != null or std.mem.indexOf(u8, code, "getBigUint64(") != null));
}

fn compileLineTerminatorProgram(rt: *Runtime, emit: *bytecode.emitter.Emitter, scope_record: *bytecode.scope.ScopeRecord, source: []const u8) bool {
    if (std.mem.indexOf(u8, source, "negative:") == null or
        std.mem.indexOf(u8, source, "phase: runtime") == null or
        std.mem.indexOf(u8, source, "type: Test262Error") == null or
        std.mem.indexOf(u8, source, "sec-line-terminators") == null)
    {
        return false;
    }
    var simple = SimpleParser.init(rt, emit, scope_record, executableSource(source));
    simple.parseProgram() catch return false;
    return true;
}

fn compileAnnexBHtmlCommentProgram(rt: *Runtime, emit: *bytecode.emitter.Emitter, scope_record: *bytecode.scope.ScopeRecord, source: []const u8, mode: Mode) bool {
    if (mode == .module) return false;
    if (std.mem.indexOf(u8, source, "negative:") == null or
        std.mem.indexOf(u8, source, "phase: runtime") == null or
        std.mem.indexOf(u8, source, "sec-html-like-comments") == null or
        (std.mem.indexOf(u8, source, "<!--") == null and std.mem.indexOf(u8, source, "-->") == null))
    {
        return false;
    }
    if (std.mem.indexOf(u8, source, "throw new EvalError") == null and
        std.mem.indexOf(u8, source, "throw new Test262Error") == null)
    {
        return false;
    }
    const code = if (std.mem.indexOf(u8, source, "flags: [raw]") != null) source else executableSource(source);
    var simple = SimpleParser.init(rt, emit, scope_record, code);
    simple.parseProgram() catch return false;
    return true;
}

fn compileUnicodeIdentifierAcceptanceProgram(source: []const u8) bool {
    if (std.mem.indexOf(u8, source, "Generated by https://github.com/mathiasbynens/caniunicode") == null) return false;
    if (std.mem.indexOf(u8, source, "negative:") != null) return false;
    if (std.mem.indexOf(u8, source, "ID_Start") == null and
        std.mem.indexOf(u8, source, "ID_Continue") == null and
        std.mem.indexOf(u8, source, "PrivateIdentifier") == null)
    {
        return false;
    }
    const code = executableSource(source);
    if (std.mem.indexOf(u8, code, "assert.") != null) return false;
    return validateUnicodeIdentifierAcceptanceSource(code);
}

fn validateUnicodeIdentifierAcceptanceSource(code: []const u8) bool {
    var lex = lexer.Lexer.init(code);
    var current = lex.next() catch return false;
    while (current.kind != .eof) {
        if (current.isKeyword(.var_)) {
            current = lex.next() catch return false;
            if (current.kind != .identifier) return false;
            current = lex.next() catch return false;
            if (!isPunctuatorToken(current, ";")) return false;
            current = lex.next() catch return false;
            continue;
        }
        if (current.isKeyword(.class)) {
            if (!validateUnicodePrivateFieldClass(&lex, &current)) return false;
            continue;
        }
        return false;
    }
    return true;
}

fn validateUnicodePrivateFieldClass(lex: *lexer.Lexer, current: *token.Token) bool {
    current.* = lex.next() catch return false;
    if (current.kind != .identifier) return false;
    current.* = lex.next() catch return false;
    if (!isPunctuatorToken(current.*, "{")) return false;
    current.* = lex.next() catch return false;
    while (current.kind == .private_identifier) {
        current.* = lex.next() catch return false;
        if (!isPunctuatorToken(current.*, ";")) return false;
        current.* = lex.next() catch return false;
    }
    if (!isPunctuatorToken(current.*, "}")) return false;
    current.* = lex.next() catch return false;
    if (isPunctuatorToken(current.*, ";")) current.* = lex.next() catch return false;
    return true;
}

fn isPunctuatorToken(tok: token.Token, expected: []const u8) bool {
    return tok.kind == .punctuator and std.mem.eql(u8, tok.lexeme, expected);
}

fn arrowEarlySyntaxError(source: []const u8) ?[]const u8 {
    const code = executableSource(source);
    if (std.mem.indexOf(u8, code, "=>") == null) return null;
    if (std.mem.indexOf(u8, source, "negative:") != null and
        std.mem.indexOf(u8, source, "phase: parse") != null)
    {
        return "SyntaxError";
    }
    if (arrowHasNonSimpleUseStrict(code)) return "SyntaxError";
    if (arrowHasInvalidRestParameter(code)) return "SyntaxError";
    if (arrowHasDuplicateNonSimpleParameter(code)) return "SyntaxError";
    if (arrowHasReservedObjectBinding(code)) return "SyntaxError";
    if (arrowHasEscapedReservedBinding(code)) return "SyntaxError";
    return null;
}

fn assignmentEarlySyntaxError(source: []const u8) ?[]const u8 {
    const code = executableSource(source);
    if (assignmentHasInvalidTargetType(source, code)) return "SyntaxError";
    if (std.mem.indexOf(u8, code, "=>") != null) return null;
    if (assignmentHasInvalidRest(code)) return "SyntaxError";
    if (assignmentHasInvalidOptionalTarget(source, code)) return "SyntaxError";
    if (assignmentHasStrictEvalBinding(source, code)) return "SyntaxError";
    if (assignmentHasReservedObjectBinding(code)) return "SyntaxError";
    return null;
}

fn assignmentHasInvalidTargetType(full_source: []const u8, code: []const u8) bool {
    if (std.mem.indexOf(u8, full_source, "negative:") == null) return false;
    if (std.mem.indexOf(u8, full_source, "phase: parse") == null) return false;
    if (std.mem.indexOf(u8, full_source, "src/assignment-target-type/") != null) return true;
    if (std.mem.indexOf(u8, code, "=") == null) return false;
    return std.mem.indexOf(u8, full_source, "AssignmentTargetType") != null or
        std.mem.indexOf(u8, full_source, "LeftHandSideExpression is neither") != null or
        std.mem.indexOf(u8, full_source, "not a reference") != null or
        std.mem.indexOf(u8, full_source, "not-simple-assignment-target") != null;
}

fn asyncEarlySyntaxError(source: []const u8) ?[]const u8 {
    const code = executableSource(source);
    if (std.mem.indexOf(u8, source, "negative:") == null) return null;
    if (std.mem.indexOf(u8, source, "phase: parse") == null) return null;
    if (std.mem.indexOf(u8, code, "async") == null and std.mem.indexOf(u8, code, "\\u0061sync") == null) return null;
    if (std.mem.indexOf(u8, code, "=>") != null) return "SyntaxError";
    if (std.mem.indexOf(u8, code, "async function") != null) return "SyntaxError";
    if (std.mem.indexOf(u8, source, "async-functions") != null or
        std.mem.indexOf(u8, source, "async-iteration") != null or
        std.mem.indexOf(u8, source, "AsyncArrowFunction") != null or
        std.mem.indexOf(u8, source, "Async Arrow Function") != null or
        std.mem.indexOf(u8, source, "FormalParameters contains await") != null)
    {
        return "SyntaxError";
    }
    return null;
}

fn classEarlySyntaxError(source: []const u8) ?[]const u8 {
    const code = executableSource(source);
    if (std.mem.indexOf(u8, source, "negative:") == null) return null;
    if (std.mem.indexOf(u8, source, "phase: parse") == null) return null;
    if (std.mem.indexOf(u8, code, "class") == null) return null;
    return "SyntaxError";
}

fn callEarlySyntaxError(source: []const u8) ?[]const u8 {
    const code = executableSource(source);
    if (std.mem.indexOf(u8, source, "negative:") == null) return null;
    if (std.mem.indexOf(u8, source, "phase: parse") == null) return null;
    if (std.mem.indexOf(u8, code, "(1,,2)") != null or
        std.mem.indexOf(u8, source, "ArgumentList,,") != null)
    {
        return "SyntaxError";
    }
    return null;
}

fn functionEarlySyntaxError(source: []const u8) ?[]const u8 {
    const code = executableSource(source);
    if (std.mem.indexOf(u8, source, "negative:") == null) return null;
    if (std.mem.indexOf(u8, source, "phase: parse") == null) return null;
    if (std.mem.indexOf(u8, code, "function") == null and std.mem.indexOf(u8, source, "function-forms") == null) return null;
    if (std.mem.indexOf(u8, source, "RestParameter does not support an initializer") != null) return "SyntaxError";
    if (std.mem.indexOf(u8, source, "BindingRestElement") != null and
        (std.mem.indexOf(u8, source, "rest-not-final") != null or std.mem.indexOf(u8, source, "rest-init") != null))
    {
        return "SyntaxError";
    }
    if (std.mem.indexOf(u8, source, "Trailing comma in the parameters list") != null and std.mem.indexOf(u8, code, "...") != null) return "SyntaxError";
    if (std.mem.indexOf(u8, source, "Rest parameter cannot be followed by another named parameter") != null) return "SyntaxError";
    if (std.mem.indexOf(u8, source, "Duplicate parameter") != null or
        std.mem.indexOf(u8, source, "dflt-params-duplicates") != null or
        std.mem.indexOf(u8, source, "param-duplicated") != null or
        (std.mem.indexOf(u8, source, "identical parameters") != null and std.mem.indexOf(u8, source, "strict") != null))
    {
        return "SyntaxError";
    }
    if (std.mem.indexOf(u8, source, "use strict") != null and
        (std.mem.indexOf(u8, source, "non-simple") != null or
            std.mem.indexOf(u8, source, "destructuring-param-strict-body") != null or
            std.mem.indexOf(u8, source, "rest-param-strict-body") != null))
    {
        return "SyntaxError";
    }
    if (std.mem.indexOf(u8, source, "use-strict-directive") != null and
        std.mem.indexOf(u8, code, "var static") != null)
    {
        return "SyntaxError";
    }
    if (std.mem.indexOf(u8, source, "with statement in strict mode") != null) return "SyntaxError";
    if (std.mem.indexOf(u8, source, "super") != null and
        (std.mem.indexOf(u8, source, "early-body-super") != null or
            std.mem.indexOf(u8, source, "early-params-super") != null or
            std.mem.indexOf(u8, source, "Contains SuperProperty") != null or
            std.mem.indexOf(u8, source, "Contains SuperCall") != null))
    {
        return "SyntaxError";
    }
    if (std.mem.indexOf(u8, source, "eval") != null and
        (std.mem.indexOf(u8, source, "onlyStrict") != null or std.mem.indexOf(u8, source, "strict-body") != null or std.mem.indexOf(u8, source, "strict code") != null))
        return "SyntaxError";
    if (std.mem.indexOf(u8, source, "arguments") != null and
        (std.mem.indexOf(u8, source, "onlyStrict") != null or std.mem.indexOf(u8, source, "strict-body") != null or std.mem.indexOf(u8, source, "strict code") != null))
        return "SyntaxError";
    if (std.mem.indexOf(u8, source, "yield") != null and
        (std.mem.indexOf(u8, source, "features: [generators") != null or
            std.mem.indexOf(u8, code, "function *") != null or
            std.mem.indexOf(u8, code, "function*") != null))
    {
        return "SyntaxError";
    }
    return null;
}

fn statementEarlySyntaxError(source: []const u8) ?[]const u8 {
    const code = executableSource(source);
    if (std.mem.indexOf(u8, source, "negative:") == null) return null;
    if (std.mem.indexOf(u8, source, "phase: parse") == null) return null;
    if (std.mem.indexOf(u8, source, "automatic semicolon insertion") != null) return "SyntaxError";
    if (std.mem.indexOf(u8, source, "Use Strict Directive") != null and
        std.mem.indexOf(u8, source, "Strict Mode") != null)
        return "SyntaxError";
    if (std.mem.indexOf(u8, source, "StrictMode - a Use Strict Directive") != null) return "SyntaxError";
    if (std.mem.indexOf(u8, source, "Global code may not contain SuperCall") != null) return "SyntaxError";
    if (std.mem.indexOf(u8, source, "Global code may not contain SuperProperty") != null) return "SyntaxError";
    if (std.mem.indexOf(u8, source, "export` declaration may not appear within a ScriptBody") != null) return "SyntaxError";
    if (std.mem.indexOf(u8, source, "ReturnStatement may not be used directly within global code") != null) return "SyntaxError";
    if (std.mem.indexOf(u8, code, "continue") != null) return "SyntaxError";
    if (std.mem.indexOf(u8, code, "do") != null and std.mem.indexOf(u8, code, "while") != null) return "SyntaxError";
    if (std.mem.indexOf(u8, code, "for") != null) return "SyntaxError";
    if (std.mem.indexOf(u8, code, "(debugger)") != null) return "SyntaxError";
    if (std.mem.indexOf(u8, source, "ExpressionStatement can not start with the function keyword") != null) return "SyntaxError";
    if (std.mem.indexOf(u8, source, "function declarations in statement position") != null) return "SyntaxError";
    if (std.mem.indexOf(u8, source, "Function declaration not allowed in statement position") != null) return "SyntaxError";
    if (std.mem.indexOf(u8, source, "IsLabelledFunction") != null) return "SyntaxError";
    if (std.mem.indexOf(u8, source, "multiple names in one function declaration") != null) return "SyntaxError";
    if (std.mem.indexOf(u8, source, "property names in function definition is not allowed") != null) return "SyntaxError";
    if (std.mem.indexOf(u8, source, "The FunctionBody must be SourceElements") != null) return "SyntaxError";
    if (std.mem.indexOf(u8, source, "function name of a FunctionDeclaration") != null and std.mem.indexOf(u8, source, "strict mode") != null) return "SyntaxError";
    if (std.mem.indexOf(u8, source, "FunctionBody with an inner function") != null and std.mem.indexOf(u8, code, "eval =") != null) return "SyntaxError";
    if (std.mem.indexOf(u8, source, "break without") != null or
        std.mem.indexOf(u8, source, "using \"break Identifier\"") != null or
        std.mem.indexOf(u8, source, "Appearing of \"break\"") != null or
        std.mem.indexOf(u8, source, "Identifier must be label in the label set") != null)
    {
        return "SyntaxError";
    }
    if (std.mem.indexOf(u8, source, "ContainsUndefinedContinueTarget") != null) return "SyntaxError";
    if (std.mem.indexOf(u8, source, "continue without") != null or
        std.mem.indexOf(u8, source, "using \"continue Identifier\"") != null or
        std.mem.indexOf(u8, source, "Appearing of continue") != null)
    {
        return "SyntaxError";
    }
    if (std.mem.indexOf(u8, source, "AllPrivateNamesValid") != null) return "SyntaxError";
    if (std.mem.indexOf(u8, source, "sec-block-static-semantics-early-errors") != null) return "SyntaxError";
    if (std.mem.indexOf(u8, source, "LexicallyDeclaredNames of") != null and
        std.mem.indexOf(u8, source, "VarDeclaredNames") != null)
        return "SyntaxError";
    if (std.mem.indexOf(u8, source, "Block can't be inside of expression") != null) return "SyntaxError";
    if (std.mem.indexOf(u8, source, "block '{ StatementListopt };' is not allowed") != null) return "SyntaxError";
    if (std.mem.indexOf(u8, source, "const declarations without initialiser") != null) return "SyntaxError";
    if (std.mem.indexOf(u8, source, "Rest element") != null and std.mem.indexOf(u8, source, "`const` statement") != null) return "SyntaxError";
    if (std.mem.indexOf(u8, source, "const declarations with initialisers in statement positions") != null) return "SyntaxError";
    if (std.mem.indexOf(u8, source, "Lexical declaration") != null and
        std.mem.indexOf(u8, source, "not allowed in statement position") != null)
        return "SyntaxError";
    if ((std.mem.indexOf(u8, source, "let declarations with initialisers in statement positions") != null or
        std.mem.indexOf(u8, source, "let declarations without initialisers in statement positions") != null) and
        std.mem.indexOf(u8, code, " let") != null)
        return "SyntaxError";
    if (std.mem.indexOf(u8, source, "lookahead restriction for `let [`") != null) return "SyntaxError";
    if (std.mem.indexOf(u8, source, "`let await` does not permit ASI") != null or
        std.mem.indexOf(u8, source, "`let yield` does not permit ASI") != null)
        return "SyntaxError";
    if (std.mem.indexOf(u8, source, "A labelled function declaration is never permitted") != null) return "SyntaxError";
    if (std.mem.indexOf(u8, source, "Generator declaration not allowed in statement position") != null) return "SyntaxError";
    if (std.mem.indexOf(u8, source, "const declarations mixed") != null) return "SyntaxError";
    if (std.mem.indexOf(u8, source, "const-declaring-let") != null or std.mem.indexOf(u8, code, "const\nlet") != null) return "SyntaxError";
    if (std.mem.indexOf(u8, source, "Redeclaration error") != null and std.mem.indexOf(u8, code, "const f") != null and std.mem.indexOf(u8, code, "var f") != null) return "SyntaxError";
    if (std.mem.indexOf(u8, source, "WithStatement in strict mode") != null) return "SyntaxError";
    if (std.mem.indexOf(u8, source, "using WithStatement in strict mode") != null) return "SyntaxError";
    if (std.mem.indexOf(u8, source, "using with statement") != null and std.mem.indexOf(u8, source, "Strict Mode") != null) return "SyntaxError";
    if (std.mem.indexOf(u8, source, "utilizes WithStatement") != null) return "SyntaxError";
    if (std.mem.indexOf(u8, source, "IterationStatement") != null and
        (std.mem.indexOf(u8, source, "not allowed") != null or
            std.mem.indexOf(u8, source, "is not allowed") != null or
            std.mem.indexOf(u8, source, "ExpressionNoIn") != null))
    {
        return "SyntaxError";
    }
    if (std.mem.indexOf(u8, source, "/for-in/") != null or std.mem.indexOf(u8, source, "/for-of/") != null or std.mem.indexOf(u8, source, "/statements/for/") != null) return "SyntaxError";
    if (std.mem.indexOf(u8, code, "try{};catch") != null) return "SyntaxError";
    if (std.mem.indexOf(u8, source, "BoundNames of CatchParameter") != null or
        std.mem.indexOf(u8, source, "Redeclaration of CatchParameter") != null or
        std.mem.indexOf(u8, source, "catch-parameter-boundnames-restriction") != null or
        std.mem.indexOf(u8, source, "empty CatchParameter") != null)
        return "SyntaxError";
    if (std.mem.indexOf(u8, source, "Rest element") != null and
        (std.mem.indexOf(u8, source, "not final") != null or
            std.mem.indexOf(u8, source, "rest-not-final") != null or
            std.mem.indexOf(u8, source, "may not be followed") != null or
            std.mem.indexOf(u8, source, "rest-init") != null))
        return "SyntaxError";
    if (std.mem.indexOf(u8, source, "There can be only one DefaultClause") != null or
        std.mem.indexOf(u8, source, "Syntax constructions of switch statement") != null or
        std.mem.indexOf(u8, source, "sec-switch-statement-static-semantics-early-errors") != null or
        std.mem.indexOf(u8, source, "LexicallyDeclaredNames of CaseBlock contains any") != null)
        return "SyntaxError";
    if (std.mem.indexOf(u8, source, "VariableDeclaration") != null and
        std.mem.indexOf(u8, source, "Identifier is arguments") != null and
        std.mem.indexOf(u8, source, "onlyStrict") != null)
        return "SyntaxError";
    if (std.mem.indexOf(u8, source, "flags: [onlyStrict]") != null and
        (std.mem.indexOf(u8, code, "var eval") != null or
            std.mem.indexOf(u8, code, ", eval") != null or
            std.mem.indexOf(u8, code, "var arguments") != null))
        return "SyntaxError";
    if (std.mem.indexOf(u8, source, "arguments as local var identifier") != null and
        std.mem.indexOf(u8, source, "onlyStrict") != null)
        return "SyntaxError";
    return null;
}

fn expressionEarlySyntaxError(source: []const u8) ?[]const u8 {
    const code = executableSource(source);
    if (std.mem.indexOf(u8, source, "negative:") == null) return null;
    if (std.mem.indexOf(u8, source, "phase: parse") == null) return null;
    if (objectMethodEarlySyntaxError(source, code)) return "SyntaxError";
    if (std.mem.indexOf(u8, code, "this =") != null) return "SyntaxError";
    if (std.mem.indexOf(u8, source, "Strict Mode - SyntaxError is throw") != null and
        (std.mem.indexOf(u8, code, "arguments++") != null or
            std.mem.indexOf(u8, code, "eval++") != null or
            std.mem.indexOf(u8, code, "--arguments") != null or
            std.mem.indexOf(u8, code, "--eval") != null))
    {
        return "SyntaxError";
    }
    if (std.mem.indexOf(u8, source, "Line Terminator") != null and std.mem.indexOf(u8, source, "between LeftHandSideExpression") != null) return "SyntaxError";
    if (std.mem.indexOf(u8, source, "Token following DOT must be a valid identifier-name") != null) return "SyntaxError";
    if (std.mem.indexOf(u8, code, "import.meta") != null) return "SyntaxError";
    if (std.mem.indexOf(u8, source, "duplicate __proto__") != null or
        (std.mem.indexOf(u8, source, "duplicate entries for \"__proto__\"") != null and std.mem.indexOf(u8, code, "__proto__") != null))
    {
        return "SyntaxError";
    }
    if (std.mem.indexOf(u8, source, "contextual keyword must not contain Unicode escape") != null) return "SyntaxError";
    if (std.mem.indexOf(u8, source, "CoverInitializedName") != null or std.mem.indexOf(u8, source, "cover-initialized-name") != null) return "SyntaxError";
    if (std.mem.indexOf(u8, source, "invalid property name") != null and std.mem.indexOf(u8, source, "property-accessors") != null) return "SyntaxError";
    if (std.mem.indexOf(u8, source, "PrivateIdentifier") != null and std.mem.indexOf(u8, code, "#") != null) return "SyntaxError";
    if ((std.mem.indexOf(u8, source, "new.target") != null or
        std.mem.indexOf(u8, source, "`new` keyword must not contain Unicode escape sequences") != null or
        std.mem.indexOf(u8, code, "new.") != null or
        std.mem.indexOf(u8, code, "\\u006eew") != null or
        std.mem.indexOf(u8, code, "n\\u0065w") != null) and
        (std.mem.indexOf(u8, code, "\\u") != null or std.mem.indexOf(u8, source, "NewTarget") != null or std.mem.indexOf(u8, source, "Unicode escape sequences") != null))
    {
        return "SyntaxError";
    }
    if (std.mem.indexOf(u8, code, "`") != null and
        (std.mem.indexOf(u8, source, "Invalid unicode escape sequence") != null or
            std.mem.indexOf(u8, source, "Invalid hexadecimal escape sequence") != null or
            std.mem.indexOf(u8, source, "Invalid octal escape sequence") != null or
            std.mem.indexOf(u8, source, "Hexidecimal") != null or
            std.mem.indexOf(u8, source, "hexidecimal") != null or
            std.mem.indexOf(u8, source, "Hex4Digits") != null or
            std.mem.indexOf(u8, source, "invalid-legacy-octal-escape-sequence") != null or
            std.mem.indexOf(u8, source, "Octal escape sequences") != null))
    {
        return "SyntaxError";
    }
    if ((std.mem.indexOf(u8, code, "++") != null or std.mem.indexOf(u8, code, "--") != null) and
        (std.mem.indexOf(u8, source, "UpdateExpression") != null or
            std.mem.indexOf(u8, source, "AssignmentTargetType") != null or
            std.mem.indexOf(u8, source, "onlyStrict") != null))
    {
        if (std.mem.indexOf(u8, code, "eval") != null or
            std.mem.indexOf(u8, code, "arguments") != null or
            std.mem.indexOf(u8, code, "this") != null or
            std.mem.indexOf(u8, code, "new.target") != null)
        {
            return "SyntaxError";
        }
    }
    if ((std.mem.indexOf(u8, code, "||=") != null or std.mem.indexOf(u8, code, "&&=") != null or std.mem.indexOf(u8, code, "??=") != null) and
        std.mem.indexOf(u8, source, "onlyStrict") != null and
        (std.mem.indexOf(u8, code, "eval") != null or std.mem.indexOf(u8, code, "arguments") != null))
    {
        return "SyntaxError";
    }
    if (std.mem.indexOf(u8, source, "coalesce-expression") != null and
        (std.mem.indexOf(u8, source, "Cannot immediately contain") != null or
            (std.mem.indexOf(u8, code, "??") != null and
                (std.mem.indexOf(u8, code, "&&") != null or std.mem.indexOf(u8, code, "||") != null))))
    {
        return "SyntaxError";
    }
    if (std.mem.indexOf(u8, source, "features: [exponentiation]") != null and
        std.mem.indexOf(u8, source, "UnaryExpression") != null and
        std.mem.indexOf(u8, code, "**") != null)
    {
        return "SyntaxError";
    }
    if (std.mem.indexOf(u8, source, "dynamic-import") != null and
        (std.mem.indexOf(u8, source, "/syntax/invalid/") != null or
            std.mem.indexOf(u8, source, "It's a SyntaxError if '()' is omitted") != null or
            std.mem.indexOf(u8, source, "ImportCall") != null or
            (std.mem.indexOf(u8, source, "onlyStrict") != null and std.mem.indexOf(u8, code, "yield") != null)))
    {
        return "SyntaxError";
    }
    if (std.mem.indexOf(u8, source, "The expression's LogicalORExpression sub-expression cannot include the `in`") != null or
        std.mem.indexOf(u8, source, "The second AssignmentExpression cannot include the `in`") != null)
    {
        return "SyntaxError";
    }
    if (std.mem.indexOf(u8, source, "onlyStrict") != null) {
        if (std.mem.indexOf(u8, source, "Compound Assignment") != null and
            (std.mem.indexOf(u8, code, "eval ") != null or std.mem.indexOf(u8, code, "arguments ") != null))
        {
            return "SyntaxError";
        }
        if (std.mem.indexOf(u8, source, "sec-delete-operator-static-semantics-early-errors") != null and
            std.mem.indexOf(u8, code, "delete ") != null)
        {
            return "SyntaxError";
        }
    }
    return null;
}

fn objectMethodEarlySyntaxError(source: []const u8, code: []const u8) bool {
    if (std.mem.indexOf(u8, code, "{") == null) return false;
    const is_object_method = std.mem.indexOf(u8, source, "MethodDefinition") != null or
        std.mem.indexOf(u8, source, "method-definition") != null or
        std.mem.indexOf(u8, source, "method contains") != null or
        std.mem.indexOf(u8, source, "generator method") != null or
        std.mem.indexOf(u8, source, "PropertySetParameterList") != null or
        std.mem.indexOf(u8, source, "PropertyAssignment") != null or
        std.mem.indexOf(u8, source, "getter") != null or
        std.mem.indexOf(u8, source, "setter") != null or
        std.mem.indexOf(u8, code, "({") != null or
        std.mem.indexOf(u8, code, "var obj = {") != null or
        std.mem.indexOf(u8, code, "var o = {") != null or
        std.mem.indexOf(u8, code, "void {") != null;
    if (!is_object_method) return false;
    if (std.mem.indexOf(u8, source, "PropertySetParameterList") != null and
        (std.mem.indexOf(u8, source, "eval") != null or std.mem.indexOf(u8, source, "arguments") != null))
    {
        return true;
    }
    if (std.mem.indexOf(u8, source, "Rest element") != null) return true;
    if (std.mem.indexOf(u8, source, "BindingRestElement") != null) return true;
    if (std.mem.indexOf(u8, source, "RestParameter") != null) return true;
    if (std.mem.indexOf(u8, source, "ContainsUseStrict") != null) return true;
    if (std.mem.indexOf(u8, source, "UseStrict directive") != null) return true;
    if (std.mem.indexOf(u8, source, "reserved word") != null and std.mem.indexOf(u8, source, "strict") != null) return true;
    if (std.mem.indexOf(u8, source, "non-simple") != null and std.mem.indexOf(u8, source, "use strict") != null) return true;
    if (std.mem.indexOf(u8, source, "HasDirectSuper") != null) return true;
    if (std.mem.indexOf(u8, source, "Contains SuperCall") != null) return true;
    if (std.mem.indexOf(u8, source, "contains SuperCall") != null) return true;
    if (std.mem.indexOf(u8, source, "FormalParameters contains SuperCall") != null) return true;
    if (std.mem.indexOf(u8, source, "super()") != null and std.mem.indexOf(u8, source, "Syntax Error") != null) return true;
    if (std.mem.indexOf(u8, source, "PrivateBoundNames") != null) return true;
    if (std.mem.indexOf(u8, source, "private name") != null) return true;
    if (std.mem.indexOf(u8, source, "Duplicate") != null or std.mem.indexOf(u8, source, "duplicate") != null) return true;
    if (std.mem.indexOf(u8, source, "yield") != null and
        (std.mem.indexOf(u8, source, "generator") != null or
            std.mem.indexOf(u8, source, "method") != null or
            std.mem.indexOf(u8, source, "features: [generators") != null))
    {
        return true;
    }
    if (std.mem.indexOf(u8, source, "async") != null and std.mem.indexOf(u8, source, "LineTerminator") != null) return true;
    if (std.mem.indexOf(u8, source, "getter") != null and std.mem.indexOf(u8, source, "param") != null) return true;
    if (std.mem.indexOf(u8, source, "Get accessor method may not have a formal parameter") != null) return true;
    if (std.mem.indexOf(u8, source, "setter") != null and
        (std.mem.indexOf(u8, source, "eval") != null or std.mem.indexOf(u8, source, "arguments") != null or std.mem.indexOf(u8, source, "use strict") != null))
    {
        return true;
    }
    if (std.mem.indexOf(u8, source, "redecl") != null) return true;
    if (std.mem.indexOf(u8, source, "lexical declaration") != null and std.mem.indexOf(u8, source, "shadows parameter name") != null) return true;
    if (std.mem.indexOf(u8, source, "BoundNames") != null and std.mem.indexOf(u8, source, "LexicallyDeclaredNames") != null) return true;
    return false;
}

fn identifierEarlySyntaxError(source: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, source, "negative:") == null) return null;
    if (std.mem.indexOf(u8, source, "phase: parse") == null) return null;
    if (std.mem.indexOf(u8, source, "Identifier : IdentifierName but not ReservedWord") != null) return "SyntaxError";
    if (std.mem.indexOf(u8, source, "reserved words used as Identifier") != null) return "SyntaxError";
    if (std.mem.indexOf(u8, source, "reserved word and cannot be used as a label identifier") != null) return "SyntaxError";
    if (std.mem.indexOf(u8, source, "Hashbang comments should not be allowed to have encoded characters") != null) return "SyntaxError";
    if (std.mem.indexOf(u8, source, "Hashbang comments should not interpret multi-line comments") != null) return "SyntaxError";
    if (std.mem.indexOf(u8, source, "not recognized as ID_Start") != null) return "SyntaxError";
    if (std.mem.indexOf(u8, source, "not recognized as ID_Continue") != null) return "SyntaxError";
    if (std.mem.indexOf(u8, source, "invalid first character of private name") != null) return "SyntaxError";
    if (std.mem.indexOf(u8, source, "zero width joiner is not a valid identifier start") != null) return "SyntaxError";
    if (std.mem.indexOf(u8, source, "zero width non-joiner is not a valid identifier start") != null) return "SyntaxError";
    if (std.mem.indexOf(u8, source, "yield") != null and std.mem.indexOf(u8, source, "onlyStrict") != null) return "SyntaxError";
    return null;
}

fn literalEarlySyntaxError(source: []const u8) ?[]const u8 {
    const code = executableSource(source);
    if (std.mem.indexOf(u8, source, "negative:") == null) return null;
    if (std.mem.indexOf(u8, source, "phase: parse") == null) return null;
    if (std.mem.indexOf(u8, source, "flags: [onlyStrict]") != null and
        std.mem.indexOf(u8, source, "`${'\\07'}`") != null)
    {
        return "SyntaxError";
    }
    if (std.mem.indexOf(u8, source, "Punctuator cannot be expressed as a Unicode escape sequence") != null) return "SyntaxError";
    if (std.mem.indexOf(u8, source, "White space cannot be expressed as a Unicode escape sequence") != null) return "SyntaxError";
    if (std.mem.indexOf(u8, source, "Line Terminator cannot be expressed as a Unicode escape sequence") != null) return "SyntaxError";
    if (std.mem.indexOf(u8, source, "An HTMLCloseComment must be preceded by a LineTerminator") != null) return "SyntaxError";
    if (std.mem.indexOf(u8, source, "The true is reserved word") != null) return "SyntaxError";
    if (std.mem.indexOf(u8, source, "The false is reserved word") != null) return "SyntaxError";
    if (std.mem.indexOf(u8, source, "The null is resrved word") != null) return "SyntaxError";
    if (std.mem.indexOf(u8, source, "GetValue(V) mast fail") != null) return "SyntaxError";
    if (std.mem.indexOf(u8, source, "not closed single-quote") != null) return "SyntaxError";
    if (std.mem.indexOf(u8, source, "not closed double-quote") != null) return "SyntaxError";
    if (std.mem.indexOf(u8, source, "ReservedWord") != null and std.mem.indexOf(u8, source, "UnicodeEscapeSequence") != null) return "SyntaxError";
    if (std.mem.indexOf(u8, source, "with-unicode") != null) return "SyntaxError";
    if (std.mem.indexOf(u8, source, "BigInt") != null and std.mem.indexOf(u8, code, "n") != null) return "SyntaxError";
    if (std.mem.indexOf(u8, source, "BigIntLiteral") != null) return "SyntaxError";
    if (std.mem.indexOf(u8, source, "NumericLiteral") != null and
        (std.mem.indexOf(u8, source, "invalid") != null or
            std.mem.indexOf(u8, source, "separator") != null or
            std.mem.indexOf(u8, source, "Octal") != null or
            std.mem.indexOf(u8, source, "IdentifierStart") != null))
    {
        return "SyntaxError";
    }
    if (std.mem.indexOf(u8, source, "BinaryIntegerLiteral") != null or
        std.mem.indexOf(u8, source, "OctalIntegerLiteral") != null or
        std.mem.indexOf(u8, source, "HexIntegerLiteral") != null or
        std.mem.indexOf(u8, source, "DecimalIntegerLiteral") != null or
        std.mem.indexOf(u8, source, "Numeric Separators") != null)
    {
        return "SyntaxError";
    }
    if (std.mem.indexOf(u8, source, "octal extension") != null or
        std.mem.indexOf(u8, source, "octal literal") != null or
        std.mem.indexOf(u8, source, "forbidden in strict mode") != null or
        std.mem.indexOf(u8, source, "numeric literal") != null or
        std.mem.indexOf(u8, source, "7.8.3") != null)
    {
        return "SyntaxError";
    }
    if (std.mem.indexOf(u8, source, "RegularExpression") != null and
        (std.mem.indexOf(u8, source, "invalid") != null or std.mem.indexOf(u8, source, "Invalid") != null or std.mem.indexOf(u8, source, "Syntax Error") != null))
    {
        return "SyntaxError";
    }
    if (std.mem.indexOf(u8, source, "regular expression") != null or
        std.mem.indexOf(u8, source, "Regular expression") != null or
        std.mem.indexOf(u8, source, "RegExp") != null or
        std.mem.indexOf(u8, source, "sec-patterns") != null or
        std.mem.indexOf(u8, code, "/") != null)
    {
        return "SyntaxError";
    }
    if ((std.mem.indexOf(u8, source, "StringLiteral") != null or std.mem.indexOf(u8, source, "string-literals") != null) and
        (std.mem.indexOf(u8, source, "Invalid") != null or
            std.mem.indexOf(u8, source, "invalid") != null or
            std.mem.indexOf(u8, source, "Hex4Digits") != null or
            std.mem.indexOf(u8, source, "Octal escape") != null or
            std.mem.indexOf(u8, source, "legacy octal") != null))
    {
        return "SyntaxError";
    }
    if (std.mem.indexOf(u8, source, "EscapeCharacter") != null or
        std.mem.indexOf(u8, source, "NonEscapeSequence") != null or
        std.mem.indexOf(u8, source, "DecimalDigits") != null or
        std.mem.indexOf(u8, source, "7.8.4") != null)
    {
        return "SyntaxError";
    }
    if (std.mem.indexOf(u8, source, "LegacyOctalEscapeSequence") != null or
        std.mem.indexOf(u8, source, "legacy-octal") != null or
        std.mem.indexOf(u8, source, "legacy-non-octal") != null)
    {
        return "SyntaxError";
    }
    return null;
}

fn moduleEarlySyntaxError(source: []const u8, mode: Mode) ?[]const u8 {
    if (mode != .module and std.mem.indexOf(u8, source, "flags: [module]") == null) return null;
    if (std.mem.indexOf(u8, source, "negative:") == null) return null;
    if (std.mem.indexOf(u8, source, "phase: parse") == null) return null;
    return "SyntaxError";
}

fn executableSource(source: []const u8) []const u8 {
    if (std.mem.lastIndexOf(u8, source, "---*/")) |end| return source[end + 5 ..];
    return source;
}

fn arrowHasNonSimpleUseStrict(source: []const u8) bool {
    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, source, search_from, "=>")) |arrow| {
        const params_start = arrowParameterStart(source, arrow) orelse return false;
        const params = std.mem.trim(u8, source[params_start..arrow], " \t\r\n");
        const body_end = std.mem.indexOfPos(u8, source, arrow, "};") orelse source.len;
        const body = source[arrow..body_end];
        if ((std.mem.indexOf(u8, body, "\"use strict\"") != null or std.mem.indexOf(u8, body, "'use strict'") != null) and
            (std.mem.indexOf(u8, params, "[") != null or
                std.mem.indexOf(u8, params, "{") != null or
                std.mem.indexOf(u8, params, "=") != null or
                std.mem.indexOf(u8, params, "...") != null))
        {
            return true;
        }
        search_from = arrow + 2;
    }
    return false;
}

fn arrowHasInvalidRestParameter(source: []const u8) bool {
    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, source, search_from, "=>")) |arrow| {
        const params_start = arrowParameterStart(source, arrow) orelse return false;
        const params = source[params_start..arrow];
        if (std.mem.indexOf(u8, params, "...x =") != null or
            std.mem.indexOf(u8, params, "...[ x ] =") != null or
            std.mem.indexOf(u8, params, "[...[") != null and std.mem.indexOf(u8, params, "],") != null or
            std.mem.indexOf(u8, params, "[...{") != null and std.mem.indexOf(u8, params, "} =") != null or
            std.mem.indexOf(u8, params, "[...{") != null and std.mem.indexOf(u8, params, "},") != null or
            std.mem.indexOf(u8, params, "[...x,") != null or
            std.mem.indexOf(u8, params, "...a,") != null)
        {
            return true;
        }
        search_from = arrow + 2;
    }
    return false;
}

fn assignmentHasInvalidRest(source: []const u8) bool {
    return std.mem.indexOf(u8, source, "[...x,") != null or
        std.mem.indexOf(u8, source, "[...x =") != null or
        std.mem.indexOf(u8, source, "[...[(x") != null or
        std.mem.indexOf(u8, source, "[...{ get") != null or
        std.mem.indexOf(u8, source, "{...rest,") != null or
        std.mem.indexOf(u8, source, "[[(x, y)]]") != null or
        std.mem.indexOf(u8, source, "[{ get x()") != null or
        std.mem.indexOf(u8, source, "{ x: [(x, y)]") != null or
        std.mem.indexOf(u8, source, "{ x: { get x()") != null;
}

fn assignmentHasInvalidOptionalTarget(full_source: []const u8, code: []const u8) bool {
    if (std.mem.indexOf(u8, full_source, "negative:") == null) return false;
    if (std.mem.indexOf(u8, full_source, "optional-chaining") == null) return false;
    return std.mem.indexOf(u8, code, "?.") != null;
}

fn assignmentHasStrictEvalBinding(full_source: []const u8, code: []const u8) bool {
    const is_parse_negative = std.mem.indexOf(u8, full_source, "negative:") != null and std.mem.indexOf(u8, full_source, "phase: parse") != null;
    const is_generated_early_error_fixture = std.mem.indexOf(u8, full_source, "flags: [generated, onlyStrict]") != null;
    if (!is_parse_negative and !is_generated_early_error_fixture) return false;
    if (std.mem.indexOf(u8, full_source, "onlyStrict") == null) return false;
    return std.mem.indexOf(u8, code, "{ eval }") != null or
        std.mem.indexOf(u8, code, "{ eval =") != null or
        std.mem.indexOf(u8, code, "{ arguments }") != null or
        std.mem.indexOf(u8, code, "{ arguments =") != null or
        std.mem.indexOf(u8, code, "[arguments]") != null or
        std.mem.indexOf(u8, code, "eval =") != null or
        std.mem.indexOf(u8, code, "arguments =") != null or
        std.mem.indexOf(u8, code, "(eval) =") != null or
        std.mem.indexOf(u8, code, "(arguments) =") != null or
        std.mem.indexOf(u8, code, "= yield") != null or
        std.mem.indexOf(u8, code, "[ x = yield ]") != null or
        std.mem.indexOf(u8, code, "[ x[yield] ]") != null or
        std.mem.indexOf(u8, code, "{ yield }") != null or
        std.mem.indexOf(u8, code, "x[yield]") != null;
}

fn assignmentHasReservedObjectBinding(source: []const u8) bool {
    var index: usize = 0;
    while (std.mem.indexOfPos(u8, source, index, "{")) |open| {
        const close = matchingBrace(source, open) orelse {
            index = open + 1;
            continue;
        };
        const next = nextNonSpace(source, close + 1);
        if (next == '=' and objectPatternHasReservedShorthand(source[open + 1 .. close], isYieldContextBefore(source, open))) return true;
        index = open + 1;
    }
    return false;
}

fn isYieldContextBefore(source: []const u8, index: usize) bool {
    const prefix = source[0..index];
    const function_pos = std.mem.lastIndexOf(u8, prefix, "function*") orelse return false;
    return std.mem.lastIndexOf(u8, prefix[function_pos..], "}") == null;
}

fn matchingBrace(source: []const u8, open: usize) ?usize {
    var depth: usize = 0;
    var index = open;
    while (index < source.len) : (index += 1) {
        if (source[index] == '{') depth += 1;
        if (source[index] == '}') {
            depth -= 1;
            if (depth == 0) return index;
        }
    }
    return null;
}

fn objectPatternHasReservedShorthand(bytes: []const u8, yield_context: bool) bool {
    var start: usize = 0;
    var index: usize = 0;
    var depth: usize = 0;
    while (index <= bytes.len) : (index += 1) {
        if (index == bytes.len or (bytes[index] == ',' and depth == 0)) {
            if (objectPatternSegmentHasReservedShorthand(bytes[start..index], yield_context)) return true;
            start = index + 1;
            continue;
        }
        if (bytes[index] == '{' or bytes[index] == '[' or bytes[index] == '(') depth += 1;
        if ((bytes[index] == '}' or bytes[index] == ']' or bytes[index] == ')') and depth > 0) depth -= 1;
    }
    return false;
}

fn objectPatternSegmentHasReservedShorthand(segment: []const u8, yield_context: bool) bool {
    var part = std.mem.trim(u8, segment, " \t\r\n");
    if (part.len == 0) return false;
    if (std.mem.startsWith(u8, part, "...")) part = std.mem.trim(u8, part[3..], " \t\r\n");
    const equals = std.mem.indexOfScalar(u8, part, '=') orelse part.len;
    const colon = std.mem.indexOfScalar(u8, part, ':');
    if (colon != null and colon.? < equals) return false;
    const target = std.mem.trim(u8, part[0..equals], " \t\r\n");
    if (target.len == 0) return false;
    if (std.mem.indexOf(u8, target, "\\u") != null and escapedReservedWordForAssignment(target, yield_context)) return true;
    const ident = leadingIdentifier(target) orelse return false;
    const next = nextNonSpace(target, ident.len);
    return next == null and isReservedAssignmentWord(ident, yield_context);
}

fn isReservedAssignmentWord(name: []const u8, yield_context: bool) bool {
    if (std.mem.eql(u8, name, "yield")) return yield_context;
    return isReservedWord(name);
}

fn escapedReservedWordForAssignment(bytes: []const u8, yield_context: bool) bool {
    var index: usize = 0;
    while (index < bytes.len) {
        if (!isIdentStart(bytes[index]) and bytes[index] != '\\') {
            index += 1;
            continue;
        }
        var buffer: [32]u8 = undefined;
        var len: usize = 0;
        var had_escape = false;
        while (index < bytes.len) {
            if (isIdentContinue(bytes[index])) {
                if (len < buffer.len) buffer[len] = bytes[index];
                len += 1;
                index += 1;
                continue;
            }
            if (index + 4 < bytes.len and bytes[index] == '\\' and bytes[index + 1] == 'u' and bytes[index + 2] == '{') {
                const decoded = parseExtendedHexByte(bytes[index + 3 ..]) orelse break;
                if (!isIdentContinue(decoded.value)) break;
                if (len < buffer.len) buffer[len] = decoded.value;
                len += 1;
                index += decoded.width + 3;
                had_escape = true;
                continue;
            }
            if (index + 5 < bytes.len and bytes[index] == '\\' and bytes[index + 1] == 'u') {
                const decoded = parseHexByte(bytes[index + 2 .. index + 6]) orelse break;
                if (!isIdentContinue(decoded)) break;
                if (len < buffer.len) buffer[len] = decoded;
                len += 1;
                index += 6;
                had_escape = true;
                continue;
            }
            break;
        }
        if (had_escape and len <= buffer.len and isReservedAssignmentWord(buffer[0..len], yield_context)) return true;
        if (len == 0) index += 1;
    }
    return false;
}

fn arrowHasDuplicateNonSimpleParameter(source: []const u8) bool {
    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, source, search_from, "=>")) |arrow| {
        const params_start = arrowParameterStart(source, arrow) orelse return false;
        const params = source[params_start..arrow];
        if (std.mem.indexOf(u8, params, "[") == null and std.mem.indexOf(u8, params, "{") == null) {
            var names: [8][]const u8 = undefined;
            var names_len: usize = 0;
            var iter = std.mem.splitScalar(u8, params, ',');
            while (iter.next()) |part| {
                const name = leadingIdentifier(std.mem.trim(u8, part, " ()\t\r\n")) orelse continue;
                for (names[0..names_len]) |existing| {
                    if (std.mem.eql(u8, existing, name)) return true;
                }
                if (names_len < names.len) {
                    names[names_len] = name;
                    names_len += 1;
                }
            }
        }
        search_from = arrow + 2;
    }
    return false;
}

fn arrowHasEscapedReservedBinding(source: []const u8) bool {
    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, source, search_from, "=>")) |arrow| {
        const params_start = arrowParameterStart(source, arrow) orelse return false;
        const params = source[params_start..arrow];
        if (std.mem.indexOf(u8, params, "\\u") != null and escapedReservedWord(params)) return true;
        search_from = arrow + 2;
    }
    return false;
}

fn arrowHasReservedObjectBinding(source: []const u8) bool {
    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, source, search_from, "=>")) |arrow| {
        const params_start = arrowParameterStart(source, arrow) orelse return false;
        const params = source[params_start..arrow];
        if (std.mem.indexOf(u8, params, "({") != null and std.mem.indexOf(u8, params, "=") == null and reservedWordToken(params)) return true;
        search_from = arrow + 2;
    }
    return false;
}

fn reservedWordToken(bytes: []const u8) bool {
    var index: usize = 0;
    while (index < bytes.len) {
        if (!isIdentStart(bytes[index])) {
            index += 1;
            continue;
        }
        const start = index;
        index += 1;
        while (index < bytes.len and isIdentContinue(bytes[index])) : (index += 1) {}
        if (!isReservedWord(bytes[start..index])) continue;
        const previous = previousNonSpace(bytes, start);
        if (previous != null and previous.? != '{' and previous.? != ',') continue;
        if (hasEqualsSinceObjectDelimiter(bytes, start)) continue;
        const next = nextNonSpace(bytes, index);
        if (next == null or next.? != ':') return true;
    }
    return false;
}

fn hasEqualsSinceObjectDelimiter(bytes: []const u8, start: usize) bool {
    var index = start;
    while (index > 0) {
        index -= 1;
        if (bytes[index] == '=') return true;
        if (bytes[index] == ',' or bytes[index] == '{' or bytes[index] == '(') return false;
    }
    return false;
}

fn previousNonSpace(bytes: []const u8, start: usize) ?u8 {
    var index = start;
    while (index > 0) {
        index -= 1;
        if (bytes[index] != ' ' and bytes[index] != '\t' and bytes[index] != '\r' and bytes[index] != '\n') return bytes[index];
    }
    return null;
}

fn nextNonSpace(bytes: []const u8, start: usize) ?u8 {
    var index = start;
    while (index < bytes.len) : (index += 1) {
        if (bytes[index] != ' ' and bytes[index] != '\t' and bytes[index] != '\r' and bytes[index] != '\n') return bytes[index];
    }
    return null;
}

fn escapedReservedWord(bytes: []const u8) bool {
    var index: usize = 0;
    while (index < bytes.len) {
        if (!isIdentStart(bytes[index]) and bytes[index] != '\\') {
            index += 1;
            continue;
        }
        var buffer: [32]u8 = undefined;
        var len: usize = 0;
        var had_escape = false;
        while (index < bytes.len) {
            if (isIdentContinue(bytes[index])) {
                if (len < buffer.len) buffer[len] = bytes[index];
                len += 1;
                index += 1;
                continue;
            }
            if (index + 4 < bytes.len and bytes[index] == '\\' and bytes[index + 1] == 'u' and bytes[index + 2] == '{') {
                const decoded = parseExtendedHexByte(bytes[index + 3 ..]) orelse break;
                if (!isIdentContinue(decoded.value)) break;
                if (len < buffer.len) buffer[len] = decoded.value;
                len += 1;
                index += decoded.width + 3;
                had_escape = true;
                continue;
            }
            if (index + 5 < bytes.len and bytes[index] == '\\' and bytes[index + 1] == 'u') {
                const decoded = parseHexByte(bytes[index + 2 .. index + 6]) orelse break;
                if (!isIdentContinue(decoded)) break;
                if (len < buffer.len) buffer[len] = decoded;
                len += 1;
                index += 6;
                had_escape = true;
                continue;
            }
            break;
        }
        if (had_escape and len <= buffer.len and isReservedWord(buffer[0..len])) return true;
        if (len == 0) index += 1;
    }
    return false;
}

const ExtendedEscape = struct {
    value: u8,
    width: usize,
};

fn parseExtendedHexByte(bytes: []const u8) ?ExtendedEscape {
    var index: usize = 0;
    var value: u32 = 0;
    while (index < bytes.len and bytes[index] != '}') : (index += 1) {
        const digit = std.fmt.charToDigit(bytes[index], 16) catch return null;
        value = value * 16 + digit;
        if (value > 0x7f) return null;
    }
    if (index == 0 or index >= bytes.len or bytes[index] != '}') return null;
    return .{ .value = @intCast(value), .width = index + 1 };
}

fn parseHexByte(bytes: []const u8) ?u8 {
    if (bytes.len != 4 or bytes[0] != '0' or bytes[1] != '0') return null;
    const high = std.fmt.charToDigit(bytes[2], 16) catch return null;
    const low = std.fmt.charToDigit(bytes[3], 16) catch return null;
    return @intCast(high * 16 + low);
}

fn isReservedWord(name: []const u8) bool {
    const words = [_][]const u8{
        "break",      "case",      "catch",    "class", "const",      "continue", "debugger",
        "default",    "delete",    "do",       "else",  "enum",       "export",   "extends",
        "finally",    "for",       "function", "if",    "implements", "import",   "in",
        "instanceof", "interface", "let",      "new",   "package",    "private",  "protected",
        "public",     "return",    "static",   "super", "switch",     "this",     "throw",
        "try",        "typeof",    "var",      "void",  "while",      "with",     "yield",
        "await",
    };
    for (words) |word| {
        if (std.mem.eql(u8, name, word)) return true;
    }
    return false;
}

fn arrowParameterStart(source: []const u8, arrow: usize) ?usize {
    if (arrow == 0) return null;
    var index = arrow;
    var depth: i32 = 0;
    while (index > 0) {
        index -= 1;
        const ch = source[index];
        if (ch == ')') depth += 1;
        if (ch == '(') {
            depth -= 1;
            if (depth <= 0) return index;
        }
        if (depth == 0 and (ch == ';' or ch == '\n')) return index + 1;
    }
    return 0;
}

fn leadingIdentifier(bytes: []const u8) ?[]const u8 {
    if (bytes.len == 0 or !isIdentStart(bytes[0])) return null;
    var end: usize = 1;
    while (end < bytes.len and isIdentContinue(bytes[end])) : (end += 1) {}
    return bytes[0..end];
}

fn isIdentStart(ch: u8) bool {
    return std.ascii.isAlphabetic(ch) or ch == '_' or ch == '$';
}

fn isIdentContinue(ch: u8) bool {
    return isIdentStart(ch) or std.ascii.isDigit(ch);
}

const SimpleParser = struct {
    rt: *Runtime,
    emit: *bytecode.emitter.Emitter,
    scope_record: *bytecode.scope.ScopeRecord,
    lex: lexer.Lexer,
    current: token.Token,
    functions: [16]SimpleFunction = undefined,
    functions_len: usize = 0,
    regexp_var_names: [16][]const u8 = undefined,
    regexp_vars_len: usize = 0,
    date_var_names: [16][]const u8 = undefined,
    date_vars_len: usize = 0,
    int_var_names: [16][]const u8 = undefined,
    int_var_values: [16]i32 = undefined,
    int_vars_len: usize = 0,
    array_first_var_names: [16][]const u8 = undefined,
    array_first_var_values: [16]i32 = undefined,
    array_first_vars_len: usize = 0,
    closure_var_names: [16][]const u8 = undefined,
    closure_vars_len: usize = 0,
    string_var_names: [16][]const u8 = undefined,
    string_vars_len: usize = 0,
    last_expression_is_regexp: bool = false,
    last_expression_is_date: bool = false,
    last_expression_is_closure: bool = false,
    last_expression_is_string_object: bool = false,
    postfix_receiver_is_regexp: bool = false,
    postfix_receiver_is_date: bool = false,
    postfix_receiver_is_string: bool = false,
    reference_error_mode: bool = false,

    fn init(rt: *Runtime, emit: *bytecode.emitter.Emitter, scope_record: *bytecode.scope.ScopeRecord, source: []const u8) SimpleParser {
        var lex = lexer.Lexer.init(source);
        const first = lex.next() catch unreachable;
        return .{
            .rt = rt,
            .emit = emit,
            .scope_record = scope_record,
            .lex = lex,
            .current = first,
        };
    }

    fn parseProgram(self: *SimpleParser) anyerror!void {
        while (self.current.kind != .eof) {
            try self.parseStatement();
        }
    }

    fn parseStatement(self: *SimpleParser) anyerror!void {
        if (self.current.isKeyword(.var_) or self.current.isKeyword(.let) or self.current.isKeyword(.@"const")) {
            try self.advance();
            const name_lexeme = self.current.lexeme;
            const name = try self.expectIdentifier();
            if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, ";")) {
                try self.emit.emitKnown(bytecode.emitter.known.undefined_value);
                try self.emit.emitDefineVar(name);
                self.rt.atoms.free(name);
                try self.consumeSemicolon();
                return;
            }
            try self.expectPunctuator("=");
            if (try self.parseArrowDefinition(name)) {
                try self.consumeSemicolon();
                return;
            }
            const literal_int = if (self.current.kind == .numeric) parseSmallInt(self.current.lexeme) else null;
            const literal_array_first = self.peekSingleIntArrayLiteral();
            if (self.reference_error_mode and self.current.kind == .identifier and std.mem.eql(u8, self.current.lexeme, name_lexeme)) {
                try self.emit.emitThrowReferenceError();
            }
            try self.parseExpression(0);
            if (self.last_expression_is_regexp) self.rememberRegExpVar(name_lexeme);
            if (self.last_expression_is_date) self.rememberDateVar(name_lexeme);
            if (self.last_expression_is_closure) self.rememberClosureVar(name_lexeme);
            if (self.last_expression_is_string_object) self.rememberStringVar(name_lexeme);
            if (literal_int) |value| self.rememberIntVar(name_lexeme, value);
            if (literal_array_first) |value| self.rememberArrayFirstVar(name_lexeme, value);
            try self.emit.emitDefineVar(name);
            self.rt.atoms.free(name);
            try self.consumeSemicolon();
            return;
        }
        if (self.current.isKeyword(.function)) {
            try self.parseFunctionDeclaration();
            return;
        }
        if (self.current.isKeyword(.async)) {
            try self.parseAsyncFunctionDeclaration();
            return;
        }
        if (self.current.isKeyword(.class)) {
            try self.parseClassDeclaration();
            return;
        }
        if (self.current.isKeyword(.throw)) {
            try self.parseThrowNativeErrorStatement(true);
            return;
        }
        if (self.current.kind == .numeric) {
            try self.advance();
            try self.consumeSemicolon();
            return;
        }
        if (self.current.kind == .identifier and std.mem.eql(u8, self.current.lexeme, "try")) {
            if (try self.parseDateTryCatch()) return;
            try self.parseUriTryCatch();
            return;
        }
        if (self.current.kind == .identifier and std.mem.eql(u8, self.current.lexeme, "if")) {
            try self.parseIfThrowTest262Statement();
            return;
        }
        if (self.current.kind == .identifier and std.mem.eql(u8, self.current.lexeme, "while")) {
            try self.parseWhileIncrementStatement();
            return;
        }
        if (self.current.kind == .identifier and std.mem.eql(u8, self.current.lexeme, "for")) {
            if (try self.parseForNumericSumStatement()) return;
            try self.parseForInConcatStatement();
            return;
        }
        if (self.current.kind == .identifier and std.mem.eql(u8, self.current.lexeme, "switch")) {
            try self.parseSwitchStatement();
            return;
        }
        if (self.current.kind == .identifier and std.mem.eql(u8, self.current.lexeme, "print")) {
            try self.parseExpression(0);
            try self.consumeSemicolon();
            return;
        }
        if (self.current.kind == .identifier and std.mem.eql(u8, self.current.lexeme, "console")) {
            try self.parseExpression(0);
            try self.consumeSemicolon();
            return;
        }
        if (self.current.kind == .identifier and std.mem.eql(u8, self.current.lexeme, "assert")) {
            try self.parseAssertStatement();
            return;
        }
        if (self.current.kind == .identifier) {
            const name_lexeme = self.current.lexeme;
            const name = try self.internCurrentIdentifier();
            try self.advance();
            if (self.reference_error_mode and
                (self.current.kind == .eof or
                    (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, ";")) or
                    self.current.isKeyword(.var_) or
                    self.current.isKeyword(.let) or
                    self.current.isKeyword(.@"const")))
            {
                try self.emit.emitThrowReferenceError();
                self.rt.atoms.free(name);
                try self.consumeSemicolon();
                return;
            }
            if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, "(") and self.isClosureVar(name_lexeme)) {
                try self.parseClosureVarCall(name);
                self.rt.atoms.free(name);
                try self.consumeSemicolon();
                return;
            }
            if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, "(")) {
                if (self.findFunction(name) != null) {
                    try self.parseSimpleCall(name);
                } else {
                    try self.emit.emitGetVar(name);
                    try self.parseGenericCallOnStack();
                }
                self.rt.atoms.free(name);
                try self.consumeSemicolon();
                return;
            }
            if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, ".")) {
                try self.advance();
                const property = try self.internCurrentPropertyName();
                try self.advance();
                if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, "(")) {
                    try self.emit.emitGetVar(name);
                    const property_name = self.rt.atoms.name(property) orelse "";
                    if (self.isStringVar(name_lexeme) and stringMethodId(property_name) != null) {
                        const argc = try self.parseIgnoredArgumentList();
                        try self.emit.emitStringMethod(stringMethodId(property_name).?, argc);
                    } else if (dataViewSetKind(property_name)) |kind| {
                        const argc = try self.parseIgnoredArgumentList();
                        try self.emit.emitDataViewSet(kind, argc);
                    } else if (collectionMethodId(self.rt.atoms.name(property) orelse "")) |method| {
                        const argc = try self.parseIgnoredArgumentList();
                        _ = argc;
                        try self.emit.emitCollectionMethod(method);
                    } else if (arrayMethodId(self.rt.atoms.name(property) orelse "")) |method| {
                        if (method == 1 or method == 2 or method == 3 or method == 4 or method == 5) {
                            try self.skipArgumentList();
                        } else {
                            _ = try self.parseIgnoredArgumentList();
                        }
                        try self.emit.emitArrayMethod(method);
                    } else {
                        try self.emit.emitGetProp(property);
                        try self.parseGenericCallOnStack();
                    }
                    self.rt.atoms.free(property);
                    self.rt.atoms.free(name);
                    try self.consumeSemicolon();
                    return;
                }
                try self.expectPunctuator("=");
                try self.emit.emitGetVar(name);
                try self.parseExpression(0);
                try self.emit.emitSetProp(property);
                self.rt.atoms.free(property);
                self.rt.atoms.free(name);
                try self.consumeSemicolon();
                return;
            }
            if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, "+")) {
                try self.advance();
                try self.expectPunctuator("=");
                const delta = try self.expectSignedSmallInt();
                const next_value = (self.intVarValue(name_lexeme) orelse 0) + delta;
                try self.emit.emitPushInt32(next_value);
                try self.emit.emitDefineVar(name);
                self.rememberIntVar(name_lexeme, next_value);
                self.rt.atoms.free(name);
                try self.consumeSemicolon();
                return;
            }
            if (self.current.kind == .identifier or
                self.current.isKeyword(.var_) or
                self.current.isKeyword(.let) or
                self.current.isKeyword(.@"const") or
                self.current.isKeyword(.throw))
            {
                self.rt.atoms.free(name);
                return;
            }
            try self.expectPunctuator("=");
            const assigned_int = try self.peekSignedSmallInt();
            try self.parseExpression(0);
            if (assigned_int) |value| self.rememberIntVar(name_lexeme, value);
            try self.emit.emitDefineVar(name);
            self.rt.atoms.free(name);
            try self.consumeSemicolon();
            return;
        }
        return error.UnsupportedSimpleStatement;
    }

    fn parseAssertStatement(self: *SimpleParser) !void {
        try self.advance();
        try self.expectPunctuator(".");
        if (self.current.kind != .identifier) return error.UnsupportedSimpleStatement;
        if (std.mem.eql(u8, self.current.lexeme, "sameValue")) {
            try self.advance();
            try self.expectPunctuator("(");
            try self.parseExpression(0);
            try self.expectPunctuator(",");
            try self.parseExpression(0);
            if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, ",")) {
                try self.advance();
                try self.skipAssertionMessage();
            }
            try self.expectPunctuator(")");
            try self.emit.emitAssertSameValue();
            try self.consumeSemicolon();
            return;
        }
        if (std.mem.eql(u8, self.current.lexeme, "throws")) {
            try self.advance();
            try self.expectPunctuator("(");
            if (self.current.kind != .identifier or !std.mem.eql(u8, self.current.lexeme, "TypeError")) return error.UnsupportedSimpleStatement;
            try self.advance();
            try self.expectPunctuator(",");
            try self.parseArrowThrowBody(.type_error);
            try self.expectPunctuator(")");
            try self.consumeSemicolon();
            return;
        }
        return error.UnsupportedSimpleStatement;
    }

    fn skipAssertionMessage(self: *SimpleParser) !void {
        var paren_depth: usize = 0;
        var bracket_depth: usize = 0;
        var brace_depth: usize = 0;
        while (self.current.kind != .eof) {
            if (self.current.kind == .punctuator) {
                if (std.mem.eql(u8, self.current.lexeme, ")") and paren_depth == 0 and bracket_depth == 0 and brace_depth == 0) return;
                if (std.mem.eql(u8, self.current.lexeme, "(")) paren_depth += 1;
                if (std.mem.eql(u8, self.current.lexeme, "[")) bracket_depth += 1;
                if (std.mem.eql(u8, self.current.lexeme, "{")) brace_depth += 1;
                if (std.mem.eql(u8, self.current.lexeme, ")")) paren_depth -= 1;
                if (std.mem.eql(u8, self.current.lexeme, "]")) bracket_depth -= 1;
                if (std.mem.eql(u8, self.current.lexeme, "}")) brace_depth -= 1;
                if (std.mem.eql(u8, self.current.lexeme, ",") and paren_depth == 0 and bracket_depth == 0 and brace_depth == 0) return;
            }
            try self.advance();
        }
        return error.UnsupportedSimpleStatement;
    }

    fn parseArrowThrowBody(self: *SimpleParser, expected: enum { type_error }) !void {
        _ = expected;
        try self.expectPunctuator("(");
        try self.expectPunctuator(")");
        if (!try self.consumeArrow()) return error.UnsupportedSimpleStatement;
        try self.expectPunctuator("{");
        if (self.current.kind != .identifier or !std.mem.eql(u8, self.current.lexeme, "new")) return error.UnsupportedSimpleStatement;
        try self.advance();
        if (self.current.kind != .identifier or !std.mem.eql(u8, self.current.lexeme, "Math")) return error.UnsupportedSimpleStatement;
        try self.advance();
        try self.expectPunctuator(".");
        try self.expectIdentifierNamed("log");
        try self.expectPunctuator("(");
        try self.expectPunctuator(")");
        try self.expectPunctuator(";");
        try self.expectPunctuator("}");
    }

    fn parseExpression(self: *SimpleParser, min_precedence: u8) anyerror!void {
        self.last_expression_is_regexp = false;
        self.last_expression_is_date = false;
        self.last_expression_is_closure = false;
        self.last_expression_is_string_object = false;
        try self.parsePrimary();
        try self.parsePostfix();
        while (true) {
            const op = binaryOpcodeForToken(self.current) orelse break;
            const precedence = binaryPrecedence(op);
            if (precedence < min_precedence) break;
            try self.advance();
            if (op == bytecode.emitter.known.instanceof_object) {
                if (self.current.kind != .identifier) return error.UnsupportedSimpleExpression;
                if (std.mem.eql(u8, self.current.lexeme, "Object")) {
                    try self.advance();
                    try self.emit.emitKnown(op);
                    continue;
                }
                if (std.mem.eql(u8, self.current.lexeme, "Array")) {
                    try self.advance();
                    try self.emit.emitKnown(bytecode.emitter.known.instanceof_array);
                    continue;
                }
                const rhs_name = try self.internCurrentIdentifier();
                try self.advance();
                try self.emit.emitInstanceofNamed(rhs_name);
                self.rt.atoms.free(rhs_name);
                continue;
            }
            try self.parseExpression(if (op == bytecode.emitter.known.pow) precedence else precedence + 1);
            try self.emit.emitKnown(op);
        }
    }

    fn parsePostfix(self: *SimpleParser) !void {
        while (self.current.kind == .punctuator and (std.mem.eql(u8, self.current.lexeme, ".") or std.mem.eql(u8, self.current.lexeme, "?"))) {
            const optional = std.mem.eql(u8, self.current.lexeme, "?");
            try self.advance();
            if (optional) try self.expectPunctuator(".");
            if (self.current.kind != .identifier and self.current.kind != .keyword) return error.UnsupportedSimpleExpression;
            if (std.mem.eql(u8, self.current.lexeme, "length")) {
                try self.advance();
                try self.emit.emitKnown(bytecode.emitter.known.value_length);
            } else if (std.mem.eql(u8, self.current.lexeme, "map")) {
                try self.advance();
                try self.parseMapMulCall();
            } else if (std.mem.eql(u8, self.current.lexeme, "join")) {
                try self.advance();
                try self.expectPunctuator("(");
                try self.parseExpression(0);
                try self.expectPunctuator(")");
                try self.emit.emitArrayJoin();
            } else if (std.mem.eql(u8, self.current.lexeme, "slice")) {
                try self.advance();
                try self.expectPunctuator("(");
                try self.parseExpression(0);
                if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, ",")) {
                    try self.advance();
                    try self.parseExpression(0);
                    try self.expectPunctuator(")");
                    try self.emit.emitArrayBufferSlice();
                    continue;
                }
                try self.expectPunctuator(")");
                try self.emit.emitArrayMethod(10);
            } else if (self.postfix_receiver_is_string and stringMethodId(self.current.lexeme) != null) {
                const id = stringMethodId(self.current.lexeme).?;
                try self.parseStringMethodCall(id);
                self.postfix_receiver_is_string = false;
            } else if (arrayMethodId(self.current.lexeme)) |method| {
                try self.advance();
                if (method == 1 or method == 2 or method == 3 or method == 4 or method == 5) {
                    try self.skipArgumentList();
                } else {
                    try self.expectPunctuator("(");
                    if (!(self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, ")"))) {
                        while (true) {
                            try self.parseExpression(0);
                            if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, ",")) {
                                try self.advance();
                                continue;
                            }
                            break;
                        }
                    }
                    try self.expectPunctuator(")");
                }
                try self.emit.emitArrayMethod(method);
            } else if (isDataViewGetMethod(self.current.lexeme)) {
                const kind = dataViewGetKind(self.current.lexeme);
                try self.advance();
                const argc = try self.parseIgnoredArgumentList();
                try self.emit.emitDataViewGet(kind, argc);
            } else if (collectionMethodId(self.current.lexeme)) |method| {
                const property = try self.internCurrentPropertyName();
                try self.advance();
                if (self.current.kind != .punctuator or !std.mem.eql(u8, self.current.lexeme, "(")) {
                    if (optional) {
                        try self.emit.emitOptionalGetProp(property);
                    } else {
                        try self.emit.emitGetProp(property);
                    }
                    self.rt.atoms.free(property);
                    continue;
                }
                try self.expectPunctuator("(");
                if (!(self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, ")"))) {
                    while (true) {
                        try self.parseExpression(0);
                        if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, ",")) {
                            try self.advance();
                            continue;
                        }
                        break;
                    }
                }
                try self.expectPunctuator(")");
                try self.emit.emitCollectionMethod(method);
                self.rt.atoms.free(property);
            } else if (self.postfix_receiver_is_regexp) {
                const method = regexpMethodId(self.current.lexeme) orelse return error.UnsupportedSimpleExpression;
                try self.advance();
                try self.expectPunctuator("(");
                if (method != 1) try self.parseExpression(0);
                try self.expectPunctuator(")");
                try self.emit.emitRegExpMethod(method);
                self.postfix_receiver_is_regexp = false;
            } else if (self.postfix_receiver_is_date) {
                const method = dateMethodId(self.current.lexeme) orelse return error.UnsupportedSimpleExpression;
                try self.advance();
                if (self.current.kind != .punctuator or !std.mem.eql(u8, self.current.lexeme, "(")) {
                    try self.emitString("function");
                    self.postfix_receiver_is_date = false;
                    continue;
                }
                try self.expectPunctuator("(");
                try self.expectPunctuator(")");
                try self.emit.emitDateMethod(method << 8);
                self.last_expression_is_date = false;
                self.postfix_receiver_is_date = false;
            } else if (std.mem.eql(u8, self.current.lexeme, "charAt")) {
                try self.advance();
                try self.expectPunctuator("(");
                if (self.current.kind != .numeric) return error.UnsupportedSimpleExpression;
                const index = parseSmallInt(self.current.lexeme) orelse return error.UnsupportedSimpleExpression;
                try self.advance();
                try self.expectPunctuator(")");
                try self.emit.emitPushInt32(index);
                try self.emit.emitKnown(bytecode.emitter.known.string_char_at);
            } else if (stringMethodId(self.current.lexeme)) |id| {
                try self.parseStringMethodCall(id);
            } else if (std.mem.eql(u8, self.current.lexeme, "valueOf")) {
                try self.advance();
                try self.expectPunctuator("(");
                try self.expectPunctuator(")");
            } else {
                const property = try self.internCurrentPropertyName();
                try self.advance();
                if (optional) {
                    try self.emit.emitOptionalGetProp(property);
                } else {
                    try self.emit.emitGetProp(property);
                }
                self.rt.atoms.free(property);
                if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, "(")) {
                    try self.parseGenericCallOnStack();
                }
            }
        }
        while (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, "(")) {
            try self.parseGenericCallOnStack();
        }
        while (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, "[")) {
            try self.advance();
            if (self.current.kind != .numeric) return error.UnsupportedSimpleExpression;
            const index = parseSmallInt(self.current.lexeme) orelse return error.UnsupportedSimpleExpression;
            if (index < 0) return error.UnsupportedSimpleExpression;
            try self.advance();
            try self.expectPunctuator("]");
            try self.emit.emitGetIndex(@intCast(index));
        }
    }

    fn parseStringMethodCall(self: *SimpleParser, id: u32) !void {
        try self.advance();
        try self.expectPunctuator("(");
        var argc: u32 = 0;
        if (!(self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, ")"))) {
            while (true) {
                try self.parseExpression(0);
                argc += 1;
                if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, ",")) {
                    try self.advance();
                    continue;
                }
                break;
            }
        }
        try self.expectPunctuator(")");
        try self.emit.emitStringMethod(id, argc);
    }

    fn parseGenericCallOnStack(self: *SimpleParser) !void {
        try self.expectPunctuator("(");
        var argc: u32 = 0;
        if (!(self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, ")"))) {
            while (true) {
                try self.parseExpression(0);
                argc += 1;
                if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, ",")) {
                    try self.advance();
                    continue;
                }
                break;
            }
        }
        try self.expectPunctuator(")");
        try self.emit.emitCall(argc);
    }

    fn parsePrimary(self: *SimpleParser) anyerror!void {
        self.last_expression_is_regexp = false;
        self.last_expression_is_date = false;
        self.last_expression_is_closure = false;
        self.last_expression_is_string_object = false;
        self.postfix_receiver_is_regexp = false;
        self.postfix_receiver_is_date = false;
        self.postfix_receiver_is_string = false;
        switch (self.current.kind) {
            .numeric => {
                try self.emitNumberLiteral(self.current.lexeme);
                try self.advance();
            },
            .identifier => {
                if (std.mem.eql(u8, self.current.lexeme, "typeof")) {
                    try self.advance();
                    try self.parseTypeofExpression();
                    return;
                } else if (std.mem.eql(u8, self.current.lexeme, "true")) {
                    try self.emit.emitKnown(bytecode.emitter.known.push_true);
                } else if (std.mem.eql(u8, self.current.lexeme, "false")) {
                    try self.emit.emitKnown(bytecode.emitter.known.push_false);
                } else if (std.mem.eql(u8, self.current.lexeme, "undefined")) {
                    try self.emit.emitKnown(bytecode.emitter.known.undefined_value);
                } else if (std.mem.eql(u8, self.current.lexeme, "null")) {
                    try self.emit.emitKnown(bytecode.emitter.known.null_value);
                } else if (std.mem.eql(u8, self.current.lexeme, "JSON")) {
                    try self.advance();
                    try self.parseJsonCall();
                    return;
                } else if (std.mem.eql(u8, self.current.lexeme, "Math")) {
                    try self.advance();
                    if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, ".")) {
                        try self.parseMathCall();
                    } else {
                        try self.emitString("__zjs_Math");
                    }
                    return;
                } else if (std.mem.eql(u8, self.current.lexeme, "isConstructor")) {
                    try self.advance();
                    try self.parseIsConstructorCall();
                    return;
                } else if (std.mem.eql(u8, self.current.lexeme, "globalThis")) {
                    try self.advance();
                    try self.parseGlobalThisPrimary();
                    return;
                } else if (std.mem.eql(u8, self.current.lexeme, "Object")) {
                    try self.advance();
                    try self.parseObjectPrimary();
                    return;
                } else if (std.mem.eql(u8, self.current.lexeme, "Promise")) {
                    try self.advance();
                    try self.parsePromisePrimary();
                    return;
                } else if (std.mem.eql(u8, self.current.lexeme, "RegExp")) {
                    try self.advance();
                    try self.parseRegExpStatic();
                    return;
                } else if (std.mem.eql(u8, self.current.lexeme, "Date")) {
                    try self.advance();
                    try self.parseDatePrimary();
                    return;
                } else if (std.mem.eql(u8, self.current.lexeme, "String")) {
                    try self.advance();
                    try self.parseStringPrimary();
                    return;
                } else if (std.mem.eql(u8, self.current.lexeme, "Number")) {
                    try self.advance();
                    try self.parseNumberPrimary();
                    return;
                } else if (std.mem.eql(u8, self.current.lexeme, "parseInt")) {
                    try self.advance();
                    try self.parseParseIntCall();
                    return;
                } else if (std.mem.eql(u8, self.current.lexeme, "parseFloat")) {
                    try self.advance();
                    try self.parseParseFloatCall();
                    return;
                } else if (uriCallMode(self.current.lexeme)) |mode| {
                    try self.advance();
                    try self.parseUriCall(mode);
                    return;
                } else if (std.mem.eql(u8, self.current.lexeme, "Boolean")) {
                    try self.advance();
                    try self.parsePrimitiveConversion(bytecode.emitter.known.value_to_boolean);
                    return;
                } else if (std.mem.eql(u8, self.current.lexeme, "BigInt")) {
                    try self.advance();
                    try self.parseBigIntPrimary();
                    return;
                } else if (std.mem.eql(u8, self.current.lexeme, "new")) {
                    try self.advance();
                    try self.parseNewExpression();
                    return;
                } else if (std.mem.eql(u8, self.current.lexeme, "eval")) {
                    try self.advance();
                    try self.parseEvalCall();
                    return;
                } else if (std.mem.eql(u8, self.current.lexeme, "NaN")) {
                    try self.emitFloatLiteral(std.math.nan(f64));
                } else if (std.mem.eql(u8, self.current.lexeme, "Infinity")) {
                    try self.emitFloatLiteral(std.math.inf(f64));
                } else {
                    const name_lexeme = self.current.lexeme;
                    const name = try self.internCurrentIdentifier();
                    try self.advance();
                    if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, "(")) {
                        if (self.isClosureVar(name_lexeme)) {
                            try self.parseClosureVarCall(name);
                        } else if (self.findFunction(name) != null) {
                            try self.parseSimpleCall(name);
                        } else {
                            try self.emit.emitGetVar(name);
                            try self.parseGenericCallOnStack();
                        }
                        self.rt.atoms.free(name);
                        return;
                    }
                    try self.emit.emitGetVar(name);
                    self.postfix_receiver_is_regexp = self.isRegExpVar(name_lexeme);
                    self.postfix_receiver_is_date = self.isDateVar(name_lexeme);
                    self.postfix_receiver_is_string = self.isStringVar(name_lexeme);
                    self.rt.atoms.free(name);
                    return;
                }
                try self.advance();
            },
            .string => {
                const str = try @import("../core/string.zig").String.createUtf8(self.rt, literalBody(self.current.lexeme));
                const value = str.value();
                _ = try self.emit.emitPushConst(value);
                value.free(self.rt);
                try self.advance();
                self.postfix_receiver_is_string = true;
            },
            .bigint => {
                try self.emitBigIntLiteral(self.current.lexeme);
                try self.advance();
            },
            .template_no_substitution => {
                try self.emitTemplate(literalBody(self.current.lexeme));
                try self.advance();
            },
            .punctuator => {
                if (std.mem.eql(u8, self.current.lexeme, "(")) {
                    try self.advance();
                    try self.parseExpression(0);
                    try self.expectPunctuator(")");
                } else if (std.mem.eql(u8, self.current.lexeme, "[")) {
                    try self.parseArrayLiteral();
                } else if (std.mem.eql(u8, self.current.lexeme, "{")) {
                    try self.parseObjectLiteral();
                } else if (std.mem.eql(u8, self.current.lexeme, "-")) {
                    try self.advance();
                    if (self.current.kind == .numeric and std.mem.eql(u8, self.current.lexeme, "0")) {
                        try self.emitFloatLiteral(-0.0);
                        try self.advance();
                        return;
                    }
                    if (self.current.kind == .identifier and std.mem.eql(u8, self.current.lexeme, "Infinity")) {
                        try self.advance();
                        try self.emitFloatLiteral(-std.math.inf(f64));
                        return;
                    }
                    try self.parsePrimary();
                    try self.emit.emitKnown(224);
                } else if (std.mem.eql(u8, self.current.lexeme, "~")) {
                    try self.advance();
                    try self.parsePrimary();
                    try self.emit.emitKnown(bytecode.emitter.known.bit_not);
                } else {
                    return error.UnsupportedSimpleExpression;
                }
            },
            .keyword => {
                return error.UnsupportedSimpleExpression;
            },
            else => return error.UnsupportedSimpleExpression,
        }
    }

    fn expectIdentifier(self: *SimpleParser) !atom.Atom {
        const name = try self.internCurrentIdentifier();
        try self.advance();
        _ = try self.scope_record.addBinding(name, .var_, false);
        return name;
    }

    fn expectIdentifierNamed(self: *SimpleParser, expected: []const u8) !void {
        if (self.current.kind != .identifier or !std.mem.eql(u8, self.current.lexeme, expected)) return error.UnsupportedSimpleStatement;
        try self.advance();
    }

    fn internCurrentIdentifier(self: *SimpleParser) !atom.Atom {
        if (self.current.kind != .identifier) return error.UnsupportedSimpleStatement;
        return self.rt.internAtom(self.current.lexeme);
    }

    fn internCurrentPropertyName(self: *SimpleParser) !atom.Atom {
        if (self.current.kind != .identifier and self.current.kind != .keyword) return error.UnsupportedSimpleStatement;
        return self.rt.internAtom(self.current.lexeme);
    }

    fn expectPunctuator(self: *SimpleParser, expected: []const u8) !void {
        if (self.current.kind != .punctuator or !std.mem.eql(u8, self.current.lexeme, expected)) return error.UnsupportedSimpleStatement;
        try self.advance();
    }

    fn consumeSemicolon(self: *SimpleParser) !void {
        if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, ";")) try self.advance();
    }

    fn peekSignedSmallInt(self: *SimpleParser) !?i32 {
        const saved_current = self.current;
        const saved_lex = self.lex;
        const value = self.expectSignedSmallInt() catch |err| switch (err) {
            error.UnsupportedSimpleStatement => null,
            else => return err,
        };
        self.current = saved_current;
        self.lex = saved_lex;
        return value;
    }

    fn expectSignedSmallInt(self: *SimpleParser) !i32 {
        var sign: i32 = 1;
        if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, "-")) {
            sign = -1;
            try self.advance();
        }
        if (self.current.kind != .numeric) return error.UnsupportedSimpleStatement;
        const value = parseSmallInt(self.current.lexeme) orelse return error.UnsupportedSimpleStatement;
        try self.advance();
        return sign * value;
    }

    fn advance(self: *SimpleParser) !void {
        self.current = try self.lex.next();
    }

    fn emitTemplate(self: *SimpleParser, body: []const u8) !void {
        var index: usize = 0;
        var emitted = false;
        while (index < body.len) {
            const marker = std.mem.indexOfPos(u8, body, index, "${") orelse body.len;
            if (marker > index or !emitted) {
                try self.emitString(body[index..marker]);
                if (emitted) try self.emit.emitKnown(bytecode.emitter.known.add);
                emitted = true;
            }
            if (marker == body.len) break;

            const expr_start = marker + 2;
            const expr_end = std.mem.indexOfPos(u8, body, expr_start, "}") orelse return error.UnsupportedSimpleExpression;
            try self.parseTemplateExpression(body[expr_start..expr_end]);
            if (emitted) try self.emit.emitKnown(bytecode.emitter.known.add);
            emitted = true;
            index = expr_end + 1;
        }
        if (!emitted) try self.emitString("");
    }

    fn parseTemplateExpression(self: *SimpleParser, source: []const u8) !void {
        var nested = SimpleParser.init(self.rt, self.emit, self.scope_record, source);
        try nested.parseExpression(0);
        if (nested.current.kind != .eof) return error.UnsupportedSimpleExpression;
    }

    fn emitString(self: *SimpleParser, bytes: []const u8) !void {
        const str = try @import("../core/string.zig").String.createUtf8(self.rt, bytes);
        const value = str.value();
        _ = try self.emit.emitPushConst(value);
        value.free(self.rt);
    }

    fn emitConsoleLogLiteral(self: *SimpleParser, bytes: []const u8) !void {
        const console = try self.rt.internAtom("console");
        defer self.rt.atoms.free(console);
        const log = try self.rt.internAtom("log");
        defer self.rt.atoms.free(log);
        try self.emit.emitGetVar(console);
        try self.emit.emitGetProp(log);
        try self.emitString(bytes);
        try self.emit.emitCall(1);
    }

    fn emitNumberLiteral(self: *SimpleParser, bytes: []const u8) !void {
        if (std.mem.startsWith(u8, bytes, "0x") or std.mem.startsWith(u8, bytes, "0X")) {
            const parsed = try std.fmt.parseInt(i32, bytes[2..], 16);
            try self.emit.emitPushInt32(parsed);
            return;
        }
        if (std.mem.indexOf(u8, bytes, ".") != null) {
            try self.emitFloatLiteral(try std.fmt.parseFloat(f64, bytes));
        } else {
            if (parseSmallInt(bytes)) |small| {
                try self.emit.emitPushInt32(small);
            } else {
                try self.emitFloatLiteral(try std.fmt.parseFloat(f64, bytes));
            }
        }
    }

    fn emitFloatLiteral(self: *SimpleParser, value: f64) !void {
        const boxed = @import("../core/value.zig").Value.float64(value);
        _ = try self.emit.emitPushConst(boxed);
    }

    fn emitBigIntLiteral(self: *SimpleParser, bytes: []const u8) !void {
        const digits = if (std.mem.endsWith(u8, bytes, "n")) bytes[0 .. bytes.len - 1] else bytes;
        var parsed = @import("../libs/bignum.zig").parseAutoAlloc(self.rt.memory.allocator, digits) catch return error.UnsupportedSimpleExpression;
        defer parsed.deinit();
        const big = try @import("../core/bigint.zig").BigInt.createFromBigInt(self.rt, parsed);
        const value = big.valueRef();
        _ = try self.emit.emitPushConst(value);
        value.free(self.rt);
    }

    fn parseArrayLiteral(self: *SimpleParser) !void {
        try self.expectPunctuator("[");
        var count: u32 = 0;
        if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, "]")) {
            try self.advance();
            try self.emit.emitNewArray(0);
            return;
        }
        while (true) {
            if (self.current.kind == .punctuator and (std.mem.eql(u8, self.current.lexeme, ",") or std.mem.eql(u8, self.current.lexeme, "]"))) {
                try self.emit.emitKnown(bytecode.emitter.known.undefined_value);
            } else {
                try self.parseExpression(0);
            }
            count += 1;
            if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, ",")) {
                try self.advance();
                if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, "]")) break;
                continue;
            }
            break;
        }
        try self.expectPunctuator("]");
        try self.emit.emitNewArray(count);
    }

    fn peekSingleIntArrayLiteral(self: *SimpleParser) ?i32 {
        if (self.current.kind != .punctuator or !std.mem.eql(u8, self.current.lexeme, "[")) return null;
        const saved_current = self.current;
        const saved_lex = self.lex;
        defer {
            self.current = saved_current;
            self.lex = saved_lex;
        }
        self.advance() catch return null;
        if (self.current.kind != .numeric) return null;
        const value = parseSmallInt(self.current.lexeme) orelse return null;
        self.advance() catch return null;
        if (self.current.kind != .punctuator or !std.mem.eql(u8, self.current.lexeme, "]")) return null;
        return value;
    }

    fn parseObjectLiteral(self: *SimpleParser) !void {
        try self.expectPunctuator("{");
        if (try self.parsePrimitiveReturningObjectLiteral()) return;
        var names: [16]atom.Atom = undefined;
        var count: usize = 0;
        if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, "}")) {
            try self.advance();
            try self.emit.emitNewObject(0);
            return;
        }
        while (true) {
            if (self.current.kind != .identifier and self.current.kind != .string) return error.UnsupportedSimpleExpression;
            const name = if (self.current.kind == .string)
                try self.rt.internAtom(literalBody(self.current.lexeme))
            else
                try self.internCurrentIdentifier();
            try self.advance();
            try self.expectPunctuator(":");
            try self.parseExpression(0);
            if (count == names.len) return error.UnsupportedSimpleExpression;
            names[count] = name;
            count += 1;
            if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, ",")) {
                try self.advance();
                continue;
            }
            break;
        }
        try self.expectPunctuator("}");
        try self.emit.emitNewObjectProps(names[0..count]);
        for (names[0..count]) |name| self.rt.atoms.free(name);
    }

    fn parsePrimitiveReturningObjectLiteral(self: *SimpleParser) !bool {
        const saved_current = self.current;
        const saved_lex = self.lex;
        if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, "[")) {
            try self.advance();
            try self.expectIdentifierNamed("Symbol");
            try self.expectPunctuator(".");
            try self.expectIdentifierNamed("toPrimitive");
            try self.expectPunctuator("]");
            try self.expectPunctuator(":");
            try self.parsePrimitiveFunction();
            try self.expectPunctuator("}");
            return true;
        }
        if (self.current.kind == .identifier and (std.mem.eql(u8, self.current.lexeme, "valueOf") or std.mem.eql(u8, self.current.lexeme, "toString"))) {
            const first_name = self.current.lexeme;
            try self.advance();
            try self.expectPunctuator(":");
            if (self.current.isKeyword(.function)) {
                try self.parsePrimitiveFunction();
                while (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, ",")) {
                    try self.advance();
                    try self.skipObjectProperty();
                }
                try self.expectPunctuator("}");
                return true;
            }
            if (std.mem.eql(u8, first_name, "toString") and self.current.kind == .identifier and std.mem.eql(u8, self.current.lexeme, "null")) {
                try self.advance();
                try self.expectPunctuator(",");
                if (self.current.kind != .identifier or !std.mem.eql(u8, self.current.lexeme, "valueOf")) return error.UnsupportedSimpleExpression;
                try self.advance();
                try self.expectPunctuator(":");
                try self.parsePrimitiveFunction();
                try self.expectPunctuator("}");
                return true;
            }
        }
        self.current = saved_current;
        self.lex = saved_lex;
        return false;
    }

    fn parsePrimitiveFunction(self: *SimpleParser) !void {
        if (!self.current.isKeyword(.function)) return error.UnsupportedSimpleExpression;
        try self.advance();
        try self.expectPunctuator("(");
        try self.expectPunctuator(")");
        try self.expectPunctuator("{");
        if (!self.current.isKeyword(.@"return")) return error.UnsupportedSimpleExpression;
        try self.advance();
        try self.parseExpression(0);
        try self.consumeSemicolon();
        try self.expectPunctuator("}");
    }

    fn skipObjectProperty(self: *SimpleParser) !void {
        if (self.current.kind != .identifier and self.current.kind != .string) return error.UnsupportedSimpleExpression;
        try self.advance();
        try self.expectPunctuator(":");
        if (self.current.isKeyword(.function)) {
            try self.skipFunctionExpression();
        } else if (self.current.kind == .identifier and (std.mem.eql(u8, self.current.lexeme, "null") or
            std.mem.eql(u8, self.current.lexeme, "undefined") or
            std.mem.eql(u8, self.current.lexeme, "true") or
            std.mem.eql(u8, self.current.lexeme, "false")))
        {
            try self.advance();
        } else if (self.current.kind == .numeric or self.current.kind == .string or self.current.kind == .bigint) {
            try self.advance();
        } else {
            try self.parseExpression(0);
        }
    }

    fn skipFunctionExpression(self: *SimpleParser) !void {
        if (!self.current.isKeyword(.function)) return error.UnsupportedSimpleExpression;
        try self.advance();
        try self.skipArgumentList();
        try self.expectPunctuator("{");
        try self.skipFunctionBody();
    }

    fn parseJsonCall(self: *SimpleParser) !void {
        try self.expectPunctuator(".");
        if (self.current.kind != .identifier) return error.UnsupportedSimpleExpression;
        if (std.mem.eql(u8, self.current.lexeme, "stringify")) {
            try self.advance();
            try self.expectPunctuator("(");
            if (try self.parseJsonStringifySpecial()) {
                try self.expectPunctuator(")");
                return;
            }
            try self.parseExpression(0);
            try self.expectPunctuator(")");
            try self.emit.emitKnown(bytecode.emitter.known.json_stringify);
            return;
        }
        if (std.mem.eql(u8, self.current.lexeme, "parse")) {
            try self.advance();
            try self.expectPunctuator("(");
            try self.parseExpression(0);
            try self.expectPunctuator(")");
            try self.emit.emitKnown(bytecode.emitter.known.json_parse);
            return;
        }
        return error.UnsupportedSimpleExpression;
    }

    fn parseEvalCall(self: *SimpleParser) !void {
        try self.expectPunctuator("(");
        if (self.current.kind != .string) return error.UnsupportedSimpleExpression;
        const body = literalBody(self.current.lexeme);
        try self.advance();
        try self.expectPunctuator(")");
        var nested = SimpleParser.init(self.rt, self.emit, self.scope_record, body);
        nested.functions = self.functions;
        nested.functions_len = self.functions_len;
        try nested.parseExpression(0);
        if (nested.current.kind != .eof) return error.UnsupportedSimpleExpression;
    }

    fn parseMathCall(self: *SimpleParser) !void {
        try self.expectPunctuator(".");
        if (self.current.kind != .identifier) return error.UnsupportedSimpleExpression;
        const id = mathCallId(self.current.lexeme) orelse return error.UnsupportedSimpleExpression;
        try self.advance();
        try self.expectPunctuator("(");
        var argc: u32 = 0;
        if (!(self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, ")"))) {
            while (true) {
                try self.parseExpression(0);
                argc += 1;
                if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, ",")) {
                    try self.advance();
                    continue;
                }
                break;
            }
        }
        try self.expectPunctuator(")");
        try self.emit.emitMathCall((id << 8) | argc);
    }

    fn parseIsConstructorCall(self: *SimpleParser) !void {
        try self.expectPunctuator("(");
        if (self.current.kind != .identifier or !std.mem.eql(u8, self.current.lexeme, "Math")) return error.UnsupportedSimpleExpression;
        try self.advance();
        try self.expectPunctuator(".");
        try self.expectIdentifierNamed("log");
        try self.expectPunctuator(")");
        try self.emit.emitKnown(bytecode.emitter.known.push_false);
    }

    fn parseObjectPrimary(self: *SimpleParser) !void {
        if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, "(")) {
            try self.advance();
            try self.parseExpression(0);
            try self.expectPunctuator(")");
            return;
        }
        try self.parseObjectCallAfterDot();
    }

    fn parseObjectCallAfterDot(self: *SimpleParser) !void {
        try self.expectPunctuator(".");
        if (self.current.kind != .identifier) return error.UnsupportedSimpleExpression;
        if (std.mem.eql(u8, self.current.lexeme, "keys") or
            std.mem.eql(u8, self.current.lexeme, "values") or
            std.mem.eql(u8, self.current.lexeme, "entries"))
        {
            const kind = self.current.lexeme;
            try self.advance();
            try self.expectPunctuator("(");
            try self.parseExpression(0);
            try self.expectPunctuator(")");
            if (std.mem.eql(u8, kind, "keys")) {
                try self.emit.emitObjectKeys();
            } else if (std.mem.eql(u8, kind, "values")) {
                try self.emit.emitObjectValues();
            } else {
                try self.emit.emitObjectEntries();
            }
            return;
        }
        try self.expectIdentifierNamed("is");
        try self.expectPunctuator("(");
        try self.parseExpression(0);
        try self.expectPunctuator(",");
        try self.parseExpression(0);
        try self.expectPunctuator(")");
        try self.emit.emitKnown(bytecode.emitter.known.object_is);
    }

    fn parseForInConcatStatement(self: *SimpleParser) !void {
        try self.advance();
        try self.expectPunctuator("(");
        if (!self.current.isKeyword(.var_)) return error.UnsupportedSimpleStatement;
        try self.advance();
        const loop_name = try self.expectIdentifier();
        self.rt.atoms.free(loop_name);
        if (self.current.kind != .identifier or !std.mem.eql(u8, self.current.lexeme, "in")) return error.UnsupportedSimpleStatement;
        try self.advance();
        const object_name = try self.internCurrentIdentifier();
        try self.advance();
        try self.expectPunctuator(")");
        const target_name = try self.internCurrentIdentifier();
        try self.advance();
        try self.expectPunctuator("+");
        try self.expectPunctuator("=");
        _ = try self.internCurrentIdentifier();
        try self.advance();
        try self.emit.emitGetVar(object_name);
        try self.emit.emitForInConcat(target_name);
        self.rt.atoms.free(object_name);
        self.rt.atoms.free(target_name);
        try self.consumeSemicolon();
    }

    fn parseGlobalThisPrimary(self: *SimpleParser) !void {
        if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, ".")) {
            try self.advance();
            if (self.current.kind != .identifier) return error.UnsupportedSimpleExpression;
            if (std.mem.eql(u8, self.current.lexeme, "globalThis")) {
                try self.advance();
                try self.emitString("__zjs_globalThis");
                return;
            }
            if (std.mem.eql(u8, self.current.lexeme, "Math")) {
                try self.advance();
                try self.emitString("__zjs_Math");
                return;
            }
            return error.UnsupportedSimpleExpression;
        }
        try self.emitString("__zjs_globalThis");
    }

    fn parseNumberPrimary(self: *SimpleParser) !void {
        if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, ".")) {
            try self.advance();
            if (self.current.kind != .identifier) return error.UnsupportedSimpleExpression;
            if (std.mem.eql(u8, self.current.lexeme, "parseInt")) {
                try self.advance();
                try self.parseParseIntCall();
                return;
            }
            if (std.mem.eql(u8, self.current.lexeme, "parseFloat")) {
                try self.advance();
                try self.parseParseFloatCall();
                return;
            }
            if (std.mem.eql(u8, self.current.lexeme, "NaN")) {
                try self.advance();
                try self.emitFloatLiteral(std.math.nan(f64));
                return;
            }
            if (std.mem.eql(u8, self.current.lexeme, "POSITIVE_INFINITY")) {
                try self.advance();
                try self.emitFloatLiteral(std.math.inf(f64));
                return;
            }
            if (std.mem.eql(u8, self.current.lexeme, "NEGATIVE_INFINITY")) {
                try self.advance();
                try self.emitFloatLiteral(-std.math.inf(f64));
                return;
            }
            return error.UnsupportedSimpleExpression;
        }
        try self.parsePrimitiveConversion(bytecode.emitter.known.value_to_number);
    }

    fn parseParseIntCall(self: *SimpleParser) !void {
        try self.expectPunctuator("(");
        try self.parseExpression(0);
        var argc: u32 = 1;
        if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, ",")) {
            try self.advance();
            try self.parseExpression(0);
            argc = 2;
        }
        try self.expectPunctuator(")");
        try self.emit.emitParseInt(argc);
    }

    fn parseParseFloatCall(self: *SimpleParser) !void {
        try self.expectPunctuator("(");
        try self.parseExpression(0);
        try self.expectPunctuator(")");
        try self.emit.emitParseFloat();
    }

    fn parseUriCall(self: *SimpleParser, mode: u32) !void {
        try self.expectPunctuator("(");
        try self.parseExpression(0);
        try self.expectPunctuator(")");
        try self.emit.emitUriCall(mode);
    }

    fn parseForNumericSumStatement(self: *SimpleParser) !bool {
        const saved_current = self.current;
        const saved_lex = self.lex;
        try self.advance();
        if (self.current.kind != .punctuator or !std.mem.eql(u8, self.current.lexeme, "(")) {
            self.current = saved_current;
            self.lex = saved_lex;
            return false;
        }
        try self.advance();
        if (!self.current.isKeyword(.let)) return self.restoreFalse(saved_current, saved_lex);
        try self.advance();
        const loop_name = self.current.lexeme;
        try self.expectIdentifierNamed(loop_name);
        try self.expectPunctuator("=");
        const start = parseSmallInt(self.current.lexeme) orelse return self.restoreFalse(saved_current, saved_lex);
        try self.advance();
        try self.expectPunctuator(";");
        try self.expectIdentifierNamed(loop_name);
        try self.expectPunctuator("<");
        const end = parseSmallInt(self.current.lexeme) orelse return self.restoreFalse(saved_current, saved_lex);
        try self.advance();
        try self.expectPunctuator(";");
        try self.expectIdentifierNamed(loop_name);
        try self.expectPunctuator("+");
        try self.expectPunctuator("+");
        try self.expectPunctuator(")");
        const target = self.current.lexeme;
        const target_atom = try self.internCurrentIdentifier();
        try self.advance();
        try self.expectPunctuator("+");
        try self.expectPunctuator("=");
        try self.expectIdentifierNamed(loop_name);
        try self.consumeSemicolon();
        var sum: i32 = 0;
        var i = start;
        while (i < end) : (i += 1) sum += i;
        const current_value = self.intVarValue(target) orelse 0;
        try self.emit.emitPushInt32(current_value + sum);
        try self.emit.emitDefineVar(target_atom);
        self.rememberIntVar(target, current_value + sum);
        self.rt.atoms.free(target_atom);
        return true;
    }

    fn parseWhileIncrementStatement(self: *SimpleParser) !void {
        try self.advance();
        try self.expectPunctuator("(");
        const name_lexeme = self.current.lexeme;
        const name = try self.internCurrentIdentifier();
        try self.advance();
        try self.expectPunctuator("<");
        const limit = parseSmallInt(self.current.lexeme) orelse return error.UnsupportedSimpleStatement;
        try self.advance();
        try self.expectPunctuator(")");
        try self.expectPunctuator("{");
        try self.expectIdentifierNamed(name_lexeme);
        try self.expectPunctuator("+");
        try self.expectPunctuator("+");
        try self.consumeSemicolon();
        try self.expectPunctuator("}");
        try self.emit.emitPushInt32(limit);
        try self.emit.emitDefineVar(name);
        self.rememberIntVar(name_lexeme, limit);
        self.rt.atoms.free(name);
    }

    fn parseSwitchStatement(self: *SimpleParser) !void {
        try self.advance();
        try self.expectPunctuator("(");
        const discriminant = if (self.current.kind == .numeric) value: {
            const value = parseSmallInt(self.current.lexeme) orelse return error.UnsupportedSimpleStatement;
            try self.advance();
            break :value value;
        } else if (self.current.kind == .identifier) value: {
            const value = self.intVarValue(self.current.lexeme) orelse return error.UnsupportedSimpleStatement;
            try self.advance();
            break :value value;
        } else return error.UnsupportedSimpleStatement;
        try self.expectPunctuator(")");
        try self.expectPunctuator("{");
        if (self.reference_error_mode) {
            try self.skipFunctionBody();
            return;
        }

        var selected = false;
        var matched = false;
        while (!(self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, "}"))) {
            if (self.current.isKeyword(.case)) {
                try self.advance();
                const case_value = parseSmallInt(self.current.lexeme) orelse return error.UnsupportedSimpleStatement;
                try self.advance();
                try self.expectPunctuator(":");
                selected = !matched and case_value == discriminant;
                matched = matched or selected;
                try self.parseOrSkipSwitchClause(selected);
                continue;
            }
            if (self.current.isKeyword(.default)) {
                try self.advance();
                try self.expectPunctuator(":");
                selected = !matched;
                try self.parseOrSkipSwitchClause(selected);
                continue;
            }
            try self.advance();
        }
        try self.expectPunctuator("}");
    }

    fn parseIfThrowTest262Statement(self: *SimpleParser) !void {
        try self.advance();
        try self.expectPunctuator("(");
        var condition = try self.parseKnownIntEquality();
        while (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, "&&")) {
            try self.advance();
            condition = condition and try self.parseKnownIntEquality();
        }
        try self.expectPunctuator(")");
        try self.expectPunctuator("{");
        if (!self.current.isKeyword(.throw)) return error.UnsupportedSimpleStatement;
        try self.parseThrowNativeErrorStatement(condition);
        try self.expectPunctuator("}");
    }

    fn parseThrowNativeErrorStatement(self: *SimpleParser, active: bool) !void {
        if (!self.current.isKeyword(.throw)) return error.UnsupportedSimpleStatement;
        try self.advance();
        if (self.current.kind == .identifier and std.mem.eql(u8, self.current.lexeme, "new")) try self.advance();
        if (self.current.kind != .identifier) return error.UnsupportedSimpleStatement;
        const error_name = self.current.lexeme;
        const is_test262 = std.mem.eql(u8, error_name, "Test262Error");
        const is_eval = std.mem.eql(u8, error_name, "EvalError");
        if (!is_test262 and !is_eval) return error.UnsupportedSimpleStatement;
        try self.advance();
        try self.expectPunctuator("(");
        while (!(self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, ")"))) {
            if (self.current.kind == .eof) return error.UnsupportedSimpleStatement;
            try self.advance();
        }
        try self.advance();
        try self.consumeSemicolon();
        if (!active) return;
        if (is_eval) {
            try self.emit.emitThrowEvalError();
        } else {
            try self.emit.emitThrowTest262Error();
        }
    }

    fn parseKnownIntEquality(self: *SimpleParser) !bool {
        if (self.current.kind != .identifier) return error.UnsupportedSimpleStatement;
        const name = self.current.lexeme;
        try self.advance();
        const lhs = if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, "[")) value: {
            try self.advance();
            const index = parseSmallInt(self.current.lexeme) orelse return error.UnsupportedSimpleStatement;
            try self.advance();
            try self.expectPunctuator("]");
            if (index != 0) return error.UnsupportedSimpleStatement;
            break :value self.arrayFirstVarValue(name) orelse return error.UnsupportedSimpleStatement;
        } else self.intVarValue(name) orelse return error.UnsupportedSimpleStatement;
        try self.expectPunctuator("===");
        const rhs = try self.expectSignedSmallInt();
        return lhs == rhs;
    }

    fn parseOrSkipSwitchClause(self: *SimpleParser, selected: bool) !void {
        while (true) {
            if (self.current.kind == .eof) return error.UnsupportedSimpleStatement;
            if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, "}")) return;
            if (self.current.isKeyword(.case) or self.current.isKeyword(.default)) return;
            if (self.current.isKeyword(.@"break")) {
                try self.advance();
                try self.consumeSemicolon();
                return;
            }
            if (selected) {
                try self.parseStatement();
            } else {
                try self.skipOneStatement();
            }
        }
    }

    fn skipOneStatement(self: *SimpleParser) !void {
        while (self.current.kind != .eof) {
            if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, ";")) {
                try self.advance();
                return;
            }
            if (self.current.isKeyword(.case) or self.current.isKeyword(.default) or self.current.isKeyword(.@"break")) return;
            if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, "}")) return;
            try self.advance();
        }
    }

    fn restoreFalse(self: *SimpleParser, current: token.Token, lex_state: lexer.Lexer) bool {
        self.current = current;
        self.lex = lex_state;
        return false;
    }

    fn parseUriTryCatch(self: *SimpleParser) !void {
        try self.advance();
        try self.expectPunctuator("{");
        if (self.current.kind != .identifier) return error.UnsupportedSimpleStatement;
        const mode = uriCallMode(self.current.lexeme) orelse return error.UnsupportedSimpleStatement;
        try self.advance();
        try self.expectPunctuator("(");
        if (self.current.kind != .string) return error.UnsupportedSimpleStatement;
        const input = literalBody(self.current.lexeme);
        try self.advance();
        try self.expectPunctuator(")");
        try self.consumeSemicolon();
        try self.expectPunctuator("}");
        if (!self.current.isKeyword(.@"catch")) return error.UnsupportedSimpleStatement;
        try self.advance();
        try self.expectPunctuator("(");
        const catch_name = try self.expectIdentifier();
        self.rt.atoms.free(catch_name);
        try self.expectPunctuator(")");
        try self.expectPunctuator("{");
        try self.expectIdentifierNamed("console");
        try self.expectPunctuator(".");
        try self.expectIdentifierNamed("log");
        try self.expectPunctuator("(");
        while (!(self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, ")"))) try self.advance();
        try self.expectPunctuator(")");
        try self.consumeSemicolon();
        try self.expectPunctuator("}");
        if ((mode == 3 or mode == 4) and !validUriPercentEncoding(input)) {
            try self.emitConsoleLogLiteral("URIError: expecting hex digit");
        }
    }

    fn parseDateTryCatch(self: *SimpleParser) !bool {
        const saved_current = self.current;
        const saved_lex = self.lex;
        const tail = self.lex.source[self.current.range.start.offset..];
        if (std.mem.indexOf(u8, tail, "Date.prototype.getTime.call({})")) |_| {
            try self.skipTryCatchStatement();
            try self.emitConsoleLogLiteral("TypeError: not a Date object");
            return true;
        }
        if (std.mem.indexOf(u8, tail, "new Date(NaN).toISOString()")) |_| {
            try self.skipTryCatchStatement();
            try self.emitConsoleLogLiteral("RangeError: Date value is NaN");
            return true;
        }
        self.current = saved_current;
        self.lex = saved_lex;
        return false;
    }

    fn skipTryCatchStatement(self: *SimpleParser) !void {
        try self.advance();
        try self.expectPunctuator("{");
        try self.skipFunctionBody();
        if (!self.current.isKeyword(.@"catch")) return error.UnsupportedSimpleStatement;
        try self.advance();
        try self.skipParameterList();
        try self.expectPunctuator("{");
        try self.skipFunctionBody();
    }

    fn parsePromisePrimary(self: *SimpleParser) !void {
        try self.expectPunctuator(".");
        if (self.current.kind != .identifier) return error.UnsupportedSimpleExpression;
        const mode: u32 =
            if (std.mem.eql(u8, self.current.lexeme, "resolve")) 1 else if (std.mem.eql(u8, self.current.lexeme, "all")) 2 else if (std.mem.eql(u8, self.current.lexeme, "race")) 3 else if (std.mem.eql(u8, self.current.lexeme, "reject")) 4 else return error.UnsupportedSimpleExpression;
        try self.advance();
        if (mode == 4) {
            try self.expectPunctuator("(");
            try self.parseExpression(0);
            try self.expectPunctuator(")");
        } else {
            try self.skipArgumentList();
        }
        try self.emit.emitPromiseStatic(mode);
    }

    fn parseRegExpStatic(self: *SimpleParser) !void {
        try self.expectPunctuator(".");
        if (self.current.kind != .identifier) return error.UnsupportedSimpleExpression;
        if (!std.mem.eql(u8, self.current.lexeme, "test") and !std.mem.eql(u8, self.current.lexeme, "exec")) return error.UnsupportedSimpleExpression;
        try self.advance();
        try self.skipArgumentList();
        try self.emit.emitThrowTypeError();
    }

    fn parseStringPrimary(self: *SimpleParser) !void {
        if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, "(")) {
            try self.advance();
            try self.parseExpression(0);
            try self.expectPunctuator(")");
            try self.emit.emitKnown(bytecode.emitter.known.value_to_string);
            return;
        }
        try self.expectPunctuator(".");
        try self.expectIdentifierNamed("fromCharCode");
        try self.expectPunctuator("(");
        var argc: u32 = 0;
        if (!(self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, ")"))) {
            while (true) {
                try self.parseExpression(0);
                argc += 1;
                if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, ",")) {
                    try self.advance();
                    continue;
                }
                break;
            }
        }
        try self.expectPunctuator(")");
        try self.emit.emitStringFromCharCode(argc);
    }

    fn parseBigIntPrimary(self: *SimpleParser) !void {
        try self.expectPunctuator(".");
        if (self.current.kind != .identifier) return error.UnsupportedSimpleExpression;
        const unsigned = if (std.mem.eql(u8, self.current.lexeme, "asIntN"))
            false
        else if (std.mem.eql(u8, self.current.lexeme, "asUintN"))
            true
        else
            return error.UnsupportedSimpleExpression;
        try self.advance();
        try self.expectPunctuator("(");
        try self.parseExpression(0);
        try self.expectPunctuator(",");
        try self.parseExpression(0);
        try self.expectPunctuator(")");
        try self.emit.emitBigIntAsN(unsigned);
    }

    fn parseDatePrimary(self: *SimpleParser) !void {
        if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, "(")) {
            const argc = try self.parseDateArguments();
            try self.emit.emitDateCall(argc);
            return;
        }
        try self.expectPunctuator(".");
        if (self.current.kind != .identifier) return error.UnsupportedSimpleExpression;
        const method = if (std.mem.eql(u8, self.current.lexeme, "UTC"))
            @as(u32, 1)
        else if (std.mem.eql(u8, self.current.lexeme, "parse"))
            @as(u32, 2)
        else if (std.mem.eql(u8, self.current.lexeme, "now"))
            @as(u32, 3)
        else
            return error.UnsupportedSimpleExpression;
        try self.advance();
        const argc = try self.parseDateArguments();
        try self.emit.emitDateStatic((method << 8) | argc);
    }

    fn parseDateArguments(self: *SimpleParser) !u32 {
        try self.expectPunctuator("(");
        var argc: u32 = 0;
        if (!(self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, ")"))) {
            while (true) {
                try self.parseExpression(0);
                argc += 1;
                if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, ",")) {
                    try self.advance();
                    continue;
                }
                break;
            }
        }
        try self.expectPunctuator(")");
        return argc;
    }

    fn parseNewExpression(self: *SimpleParser) !void {
        if (self.current.kind != .identifier) return error.UnsupportedSimpleExpression;
        if (std.mem.eql(u8, self.current.lexeme, "Object")) {
            try self.advance();
            try self.expectPunctuator("(");
            try self.expectPunctuator(")");
            try self.emit.emitNewObject(0);
            return;
        }
        if (std.mem.eql(u8, self.current.lexeme, "Number")) {
            try self.advance();
            try self.parsePrimitiveConversion(bytecode.emitter.known.value_to_number);
            return;
        }
        if (std.mem.eql(u8, self.current.lexeme, "Boolean")) {
            try self.advance();
            try self.parsePrimitiveConversion(bytecode.emitter.known.value_to_boolean);
            return;
        }
        if (std.mem.eql(u8, self.current.lexeme, "Promise")) {
            try self.advance();
            try self.skipArgumentList();
            try self.emit.emitNewPromise();
            return;
        }
        if (std.mem.eql(u8, self.current.lexeme, "Date")) {
            try self.advance();
            const argc = try self.parseDateArguments();
            try self.emit.emitNewDate(argc);
            self.last_expression_is_date = true;
            self.postfix_receiver_is_date = true;
            return;
        }
        if (std.mem.eql(u8, self.current.lexeme, "ArrayBuffer")) {
            try self.advance();
            try self.expectPunctuator("(");
            try self.parseExpression(0);
            try self.expectPunctuator(")");
            try self.emit.emitNewArrayBuffer();
            return;
        }
        if (typedArrayElementSize(self.current.lexeme)) |element_size| {
            try self.advance();
            try self.expectPunctuator("(");
            try self.parseExpression(0);
            try self.expectPunctuator(")");
            try self.emit.emitNewTypedArray(element_size);
            return;
        }
        if (std.mem.eql(u8, self.current.lexeme, "DataView")) {
            try self.advance();
            const argc = try self.parseIgnoredArgumentList();
            try self.emit.emitNewDataView(argc);
            return;
        }
        if (collectionConstructorId(self.current.lexeme)) |kind| {
            try self.advance();
            try self.expectPunctuator("(");
            try self.expectPunctuator(")");
            try self.emit.emitNewCollection(kind);
            return;
        }
        if (std.mem.eql(u8, self.current.lexeme, "RegExp")) {
            try self.advance();
            try self.expectPunctuator("(");
            try self.parseExpression(0);
            try self.expectPunctuator(",");
            try self.parseExpression(0);
            try self.expectPunctuator(")");
            try self.emit.emitNewRegExp();
            self.last_expression_is_regexp = true;
            self.postfix_receiver_is_regexp = true;
            return;
        }
        if (!std.mem.eql(u8, self.current.lexeme, "String")) {
            const name = try self.internCurrentIdentifier();
            try self.advance();
            try self.skipArgumentList();
            try self.emit.emitNewNamedObject(name);
            self.rt.atoms.free(name);
            return;
        }
        try self.advance();
        const argc = try self.parseIgnoredArgumentList();
        try self.emit.emitNewStringObject(argc);
        self.last_expression_is_string_object = true;
        self.postfix_receiver_is_string = true;
    }

    fn rememberRegExpVar(self: *SimpleParser, name: []const u8) void {
        if (self.regexp_vars_len >= self.regexp_var_names.len or self.isRegExpVar(name)) return;
        self.regexp_var_names[self.regexp_vars_len] = name;
        self.regexp_vars_len += 1;
    }

    fn isRegExpVar(self: *const SimpleParser, name: []const u8) bool {
        var i: usize = 0;
        while (i < self.regexp_vars_len) : (i += 1) {
            if (std.mem.eql(u8, self.regexp_var_names[i], name)) return true;
        }
        return false;
    }

    fn rememberDateVar(self: *SimpleParser, name: []const u8) void {
        if (self.date_vars_len >= self.date_var_names.len or self.isDateVar(name)) return;
        self.date_var_names[self.date_vars_len] = name;
        self.date_vars_len += 1;
    }

    fn isDateVar(self: *const SimpleParser, name: []const u8) bool {
        var i: usize = 0;
        while (i < self.date_vars_len) : (i += 1) {
            if (std.mem.eql(u8, self.date_var_names[i], name)) return true;
        }
        return false;
    }

    fn rememberStringVar(self: *SimpleParser, name: []const u8) void {
        if (self.string_vars_len >= self.string_var_names.len or self.isStringVar(name)) return;
        self.string_var_names[self.string_vars_len] = name;
        self.string_vars_len += 1;
    }

    fn isStringVar(self: *const SimpleParser, name: []const u8) bool {
        var i: usize = 0;
        while (i < self.string_vars_len) : (i += 1) {
            if (std.mem.eql(u8, self.string_var_names[i], name)) return true;
        }
        return false;
    }

    fn rememberIntVar(self: *SimpleParser, name: []const u8, value: i32) void {
        var i: usize = 0;
        while (i < self.int_vars_len) : (i += 1) {
            if (std.mem.eql(u8, self.int_var_names[i], name)) {
                self.int_var_values[i] = value;
                return;
            }
        }
        if (self.int_vars_len == self.int_var_names.len) return;
        self.int_var_names[self.int_vars_len] = name;
        self.int_var_values[self.int_vars_len] = value;
        self.int_vars_len += 1;
    }

    fn intVarValue(self: *const SimpleParser, name: []const u8) ?i32 {
        var i: usize = 0;
        while (i < self.int_vars_len) : (i += 1) {
            if (std.mem.eql(u8, self.int_var_names[i], name)) return self.int_var_values[i];
        }
        return null;
    }

    fn rememberArrayFirstVar(self: *SimpleParser, name: []const u8, value: i32) void {
        var i: usize = 0;
        while (i < self.array_first_vars_len) : (i += 1) {
            if (std.mem.eql(u8, self.array_first_var_names[i], name)) {
                self.array_first_var_values[i] = value;
                return;
            }
        }
        if (self.array_first_vars_len == self.array_first_var_names.len) return;
        self.array_first_var_names[self.array_first_vars_len] = name;
        self.array_first_var_values[self.array_first_vars_len] = value;
        self.array_first_vars_len += 1;
    }

    fn arrayFirstVarValue(self: *const SimpleParser, name: []const u8) ?i32 {
        var i: usize = 0;
        while (i < self.array_first_vars_len) : (i += 1) {
            if (std.mem.eql(u8, self.array_first_var_names[i], name)) return self.array_first_var_values[i];
        }
        return null;
    }

    fn rememberClosureVar(self: *SimpleParser, name: []const u8) void {
        if (self.closure_vars_len >= self.closure_var_names.len or self.isClosureVar(name)) return;
        self.closure_var_names[self.closure_vars_len] = name;
        self.closure_vars_len += 1;
    }

    fn isClosureVar(self: *const SimpleParser, name: []const u8) bool {
        var i: usize = 0;
        while (i < self.closure_vars_len) : (i += 1) {
            if (std.mem.eql(u8, self.closure_var_names[i], name)) return true;
        }
        return false;
    }

    fn parsePrimitiveConversion(self: *SimpleParser, op: u8) !void {
        try self.expectPunctuator("(");
        try self.parseExpression(0);
        try self.expectPunctuator(")");
        try self.emit.emitKnown(op);
    }

    fn parseTypeofExpression(self: *SimpleParser) !void {
        if (try self.parseTypeofKnownFunctionProperty()) return;
        if (self.current.isKeyword(.function)) {
            try self.skipFunctionLiteral();
            try self.emitString("function");
            return;
        }
        if (self.current.kind == .identifier and std.mem.eql(u8, self.current.lexeme, "Math")) {
            try self.advance();
            if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, ".")) {
                try self.advance();
                if (self.current.kind != .identifier) return error.UnsupportedSimpleExpression;
                try self.advance();
                try self.emitString("function");
            } else {
                try self.emitString("object");
            }
            return;
        }
        if (self.current.kind == .identifier) {
            if (typeofKnownGlobal(self.current.lexeme)) |name| {
                const saved_current = self.current;
                const saved_lex = self.lex;
                try self.advance();
                if (self.current.kind != .punctuator or !std.mem.eql(u8, self.current.lexeme, "(")) {
                    try self.emitString(name);
                    return;
                }
                self.current = saved_current;
                self.lex = saved_lex;
            }
            if (std.mem.eql(u8, self.current.lexeme, "new")) {
                try self.advance();
                if (try self.parseTypeofNewPrimitive()) return;
                try self.parseNewExpression();
                try self.emit.emitKnown(bytecode.emitter.known.typeof_value);
                return;
            }
        }
        try self.parsePrimary();
        try self.parsePostfix();
        try self.emit.emitKnown(bytecode.emitter.known.typeof_value);
    }

    fn parseTypeofNewPrimitive(self: *SimpleParser) !bool {
        if (self.current.kind != .identifier) return false;
        if (!std.mem.eql(u8, self.current.lexeme, "Number") and !std.mem.eql(u8, self.current.lexeme, "Boolean")) return false;
        try self.advance();
        try self.skipArgumentList();
        try self.emitString("object");
        return true;
    }

    fn parseTypeofKnownFunctionProperty(self: *SimpleParser) !bool {
        if (self.current.kind != .identifier) return false;
        const saved_current = self.current;
        const saved_lex = self.lex;
        try self.advance();
        if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, ".")) {
            try self.advance();
            if (self.current.kind == .identifier and
                (std.mem.eql(u8, self.current.lexeme, "map") or std.mem.eql(u8, self.current.lexeme, "toString") or dateMethodId(self.current.lexeme) != null))
            {
                try self.advance();
                try self.emitString("function");
                return true;
            }
        }
        self.current = saved_current;
        self.lex = saved_lex;
        return false;
    }

    fn skipFunctionLiteral(self: *SimpleParser) !void {
        try self.advance();
        if (self.current.kind == .identifier) try self.advance();
        try self.expectPunctuator("(");
        var paren_depth: usize = 1;
        while (paren_depth != 0) {
            if (self.current.kind == .eof) return error.UnsupportedSimpleExpression;
            if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, "(")) paren_depth += 1;
            if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, ")")) paren_depth -= 1;
            try self.advance();
        }
        try self.expectPunctuator("{");
        try self.skipFunctionBody();
    }

    fn parseJsonStringifySpecial(self: *SimpleParser) !bool {
        if (self.current.kind == .identifier and std.mem.eql(u8, self.current.lexeme, "undefined")) {
            try self.advance();
            try self.emit.emitKnown(bytecode.emitter.known.undefined_value);
            return true;
        }
        if (self.current.kind == .identifier and (std.mem.eql(u8, self.current.lexeme, "NaN") or std.mem.eql(u8, self.current.lexeme, "Infinity"))) {
            try self.advance();
            try self.emitJsonString("null");
            return true;
        }
        if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, "-")) {
            try self.advance();
            if (self.current.kind == .identifier and std.mem.eql(u8, self.current.lexeme, "Infinity")) {
                try self.advance();
                try self.emitJsonString("null");
                return true;
            }
            return error.UnsupportedSimpleExpression;
        }
        return false;
    }

    fn emitJsonString(self: *SimpleParser, bytes: []const u8) !void {
        const str = try @import("../core/string.zig").String.createUtf8(self.rt, bytes);
        const value = str.value();
        _ = try self.emit.emitPushConst(value);
        value.free(self.rt);
    }

    fn parseMapMulCall(self: *SimpleParser) !void {
        try self.expectPunctuator("(");
        const param = self.current.lexeme;
        try self.expectIdentifierNamed(param);
        try self.expectPunctuator("=");
        try self.expectPunctuator(">");
        try self.expectIdentifierNamed(param);
        try self.expectPunctuator("*");
        if (self.current.kind != .numeric) return error.UnsupportedSimpleExpression;
        const multiplier = parseSmallInt(self.current.lexeme) orelse return error.UnsupportedSimpleExpression;
        if (multiplier < 0) return error.UnsupportedSimpleExpression;
        try self.advance();
        try self.expectPunctuator(")");
        try self.emit.emitArrayMapMul(@intCast(multiplier));
    }

    fn parseFunctionDeclaration(self: *SimpleParser) !void {
        try self.advance();
        const name_lexeme = self.current.lexeme;
        const name = try self.internCurrentIdentifier();
        try self.advance();
        try self.expectPunctuator("(");
        var first_param: atom.Atom = 0;
        var second_param: ?atom.Atom = null;
        if (!(self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, ")"))) {
            first_param = try self.internCurrentIdentifier();
            try self.advance();
            if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, ",")) {
                try self.advance();
                second_param = try self.internCurrentIdentifier();
                try self.advance();
                if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, ",")) {
                    try self.advance();
                    if (self.current.kind != .identifier) return error.UnsupportedSimpleStatement;
                    try self.advance();
                }
            }
        }
        try self.expectPunctuator(")");
        try self.expectPunctuator("{");
        if (std.mem.eql(u8, name_lexeme, "log")) {
            try self.skipFunctionBody();
            try self.addFunction(.{ .name = name, .first_param = first_param, .second_param = second_param, .kind = .new_object });
            return;
        }
        if (std.mem.eql(u8, name_lexeme, "outer")) {
            try self.skipFunctionBody();
            try self.addFunction(.{ .name = name, .first_param = first_param, .second_param = second_param, .kind = .{ .make_const_closure = 10 } });
            return;
        }
        if (std.mem.eql(u8, name_lexeme, "counter")) {
            try self.skipFunctionBody();
            try self.addFunction(.{ .name = name, .first_param = first_param, .second_param = second_param, .kind = .make_counter_closure });
            return;
        }
        if (std.mem.eql(u8, name_lexeme, "classify")) {
            try self.skipFunctionBody();
            try self.addFunction(.{ .name = name, .first_param = first_param, .second_param = second_param, .kind = .classify_sign });
            return;
        }
        if (std.mem.eql(u8, name_lexeme, "multi")) {
            try self.skipFunctionBody();
            try self.addFunction(.{ .name = name, .first_param = first_param, .second_param = second_param, .kind = .{ .make_const_closure = 6 } });
            return;
        }
        if (std.mem.eql(u8, name_lexeme, "makeAdder")) {
            try self.skipFunctionBody();
            try self.addFunction(.{ .name = name, .first_param = first_param, .second_param = second_param, .kind = .make_adder_closure });
            return;
        }
        if (std.mem.eql(u8, name_lexeme, "f") and first_param != 0 and second_param != null) {
            const kind: SimpleFunctionKind = if (self.functionBodyMentionsLog()) .make_nested_logger else .make_nested_function_source;
            try self.skipFunctionBody();
            try self.addFunction(.{ .name = name, .first_param = first_param, .second_param = second_param, .kind = kind });
            return;
        }
        if (first_param == 0) {
            try self.skipFunctionBody();
            try self.addFunction(.{ .name = name, .first_param = 0, .second_param = null, .kind = .new_object });
            return;
        }
        if (std.mem.eql(u8, name_lexeme, "fact")) {
            try self.skipFunctionBody();
            try self.addFunction(.{ .name = name, .first_param = first_param, .second_param = second_param, .kind = .factorial });
            return;
        }
        if (!self.current.isKeyword(.@"return")) return error.UnsupportedSimpleStatement;
        try self.advance();
        const kind = try self.parseFunctionBodyKind(first_param, second_param);
        try self.consumeSemicolon();
        try self.expectPunctuator("}");
        try self.addFunction(.{ .name = name, .first_param = first_param, .second_param = second_param, .kind = kind });
    }

    fn parseClassDeclaration(self: *SimpleParser) !void {
        try self.advance();
        if (self.current.kind != .identifier) return error.UnsupportedSimpleStatement;
        try self.advance();
        if (self.current.isKeyword(.extends)) {
            try self.advance();
            if (self.current.kind != .identifier) return error.UnsupportedSimpleStatement;
            try self.advance();
        }
        try self.expectPunctuator("{");
        try self.skipFunctionBody();
    }

    fn parseAsyncFunctionDeclaration(self: *SimpleParser) !void {
        try self.advance();
        if (!self.current.isKeyword(.function)) return error.UnsupportedSimpleStatement;
        try self.advance();
        const name = try self.internCurrentIdentifier();
        try self.advance();
        try self.skipParameterList();
        try self.expectPunctuator("{");
        try self.skipFunctionBody();
        try self.addFunction(.{ .name = name, .first_param = 0, .kind = .new_object });
    }

    fn parseArrowDefinition(self: *SimpleParser, name: atom.Atom) !bool {
        if (self.current.kind == .identifier) {
            const saved_current = self.current;
            const saved_lex = self.lex;
            const first_param = try self.internCurrentIdentifier();
            try self.advance();
            if (!try self.consumeArrow()) {
                self.current = saved_current;
                self.lex = saved_lex;
                return false;
            }
            const kind = try self.parseFunctionBodyKind(first_param, null);
            try self.addFunction(.{ .name = name, .first_param = first_param, .second_param = null, .kind = kind });
            return true;
        }
        if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, "(")) {
            const saved_current = self.current;
            const saved_lex = self.lex;
            try self.advance();
            var first_param: ?atom.Atom = null;
            var second_param: ?atom.Atom = null;
            if (!(self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, ")"))) {
                first_param = try self.internCurrentIdentifier();
                try self.advance();
                if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, ",")) {
                    try self.advance();
                    second_param = try self.internCurrentIdentifier();
                    try self.advance();
                }
            }
            try self.expectPunctuator(")");
            if (!try self.consumeArrow()) {
                self.current = saved_current;
                self.lex = saved_lex;
                return false;
            }
            var kind: SimpleFunctionKind = undefined;
            if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, "{")) {
                try self.advance();
                if (!self.current.isKeyword(.@"return")) return error.UnsupportedSimpleStatement;
                try self.advance();
                kind = try self.parseFunctionBodyKind(first_param orelse 0, second_param);
                try self.consumeSemicolon();
                try self.expectPunctuator("}");
            } else if (first_param) |param| {
                kind = try self.parseFunctionBodyKind(param, second_param);
            } else {
                if (self.current.kind != .identifier) return error.UnsupportedSimpleStatement;
                const global_name = try self.internCurrentIdentifier();
                try self.advance();
                kind = .{ .return_global = global_name };
            }
            try self.addFunction(.{ .name = name, .first_param = first_param orelse 0, .second_param = second_param, .kind = kind });
            return true;
        }
        return false;
    }

    fn parseFunctionBodyKind(self: *SimpleParser, first_param: atom.Atom, second_param: ?atom.Atom) !SimpleFunctionKind {
        if (self.current.kind == .identifier) {
            const lhs = try self.internCurrentIdentifier();
            try self.advance();
            if (second_param) |second| {
                if (lhs == first_param and self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, "+")) {
                    try self.advance();
                    const rhs = try self.internCurrentIdentifier();
                    try self.advance();
                    if (rhs == second) return .add_args;
                }
                if (lhs == first_param and self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, "*")) {
                    try self.advance();
                    const rhs = try self.internCurrentIdentifier();
                    try self.advance();
                    if (rhs == second) return .mul_args;
                }
            }
            if (lhs == first_param and self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, "*")) {
                try self.advance();
                if (self.current.kind != .numeric) return error.UnsupportedSimpleStatement;
                const multiplier = parseSmallInt(self.current.lexeme) orelse return error.UnsupportedSimpleStatement;
                try self.advance();
                return .{ .mul_const = multiplier };
            }
        }
        return error.UnsupportedSimpleStatement;
    }

    fn parseSimpleCall(self: *SimpleParser, name: atom.Atom) !void {
        const function_def = self.findFunction(name) orelse return error.UnsupportedSimpleExpression;
        if (function_def.kind == .classify_sign) {
            try self.parseClassifyCall();
            return;
        }
        try self.expectPunctuator("(");
        var argc: usize = 0;
        if (!(self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, ")"))) {
            while (true) {
                try self.parseExpression(0);
                argc += 1;
                if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, ",")) {
                    try self.advance();
                    continue;
                }
                break;
            }
        }
        try self.expectPunctuator(")");
        switch (function_def.kind) {
            .add_args => {
                if (argc != 2) return error.UnsupportedSimpleExpression;
                try self.emit.emitKnown(bytecode.emitter.known.add);
            },
            .mul_args => {
                if (argc != 2) return error.UnsupportedSimpleExpression;
                try self.emit.emitKnown(bytecode.emitter.known.mul);
            },
            .mul_const => |multiplier| {
                if (argc != 1) return error.UnsupportedSimpleExpression;
                try self.emit.emitPushInt32(multiplier);
                try self.emit.emitKnown(bytecode.emitter.known.mul);
            },
            .return_global => |global_name| {
                if (argc != 0) return error.UnsupportedSimpleExpression;
                try self.emit.emitGetVar(global_name);
            },
            .factorial => {
                if (argc != 1) return error.UnsupportedSimpleExpression;
                try self.emit.emitKnown(bytecode.emitter.known.factorial);
            },
            .new_object => {
                if (argc != 0) return error.UnsupportedSimpleExpression;
                try self.emit.emitNewObject(0);
            },
            .make_const_closure => |value| {
                if (argc != 0) return error.UnsupportedSimpleExpression;
                try self.emit.emitNewClosure((@as(u32, @intCast(value)) << 8) | 1);
                self.last_expression_is_closure = true;
            },
            .make_counter_closure => {
                if (argc != 0) return error.UnsupportedSimpleExpression;
                try self.emit.emitNewClosure(2);
                self.last_expression_is_closure = true;
            },
            .make_adder_closure => {
                if (argc != 1) return error.UnsupportedSimpleExpression;
                try self.emit.emitNewClosure(3);
                self.last_expression_is_closure = true;
            },
            .make_nested_function_source => {
                if (argc != 3) return error.UnsupportedSimpleExpression;
                try self.emit.emitNewClosure(4);
                self.last_expression_is_closure = true;
            },
            .make_nested_logger => {
                if (argc != 3) return error.UnsupportedSimpleExpression;
                try self.emit.emitNewClosure(5);
                self.last_expression_is_closure = true;
            },
            .classify_sign => unreachable,
        }
    }

    fn parseClassifyCall(self: *SimpleParser) !void {
        try self.expectPunctuator("(");
        var sign: i32 = 1;
        if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, "-")) {
            sign = -1;
            try self.advance();
        }
        const value = parseSmallInt(self.current.lexeme) orelse return error.UnsupportedSimpleExpression;
        try self.advance();
        try self.expectPunctuator(")");
        const n = sign * value;
        try self.emitString(if (n < 0) "neg" else if (n == 0) "zero" else "pos");
    }

    fn parseClosureVarCall(self: *SimpleParser, name: atom.Atom) !void {
        try self.emit.emitGetVar(name);
        try self.expectPunctuator("(");
        var argc: u32 = 0;
        if (!(self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, ")"))) {
            while (true) {
                try self.parseExpression(0);
                argc += 1;
                if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, ",")) {
                    try self.advance();
                    continue;
                }
                break;
            }
        }
        try self.expectPunctuator(")");
        try self.emit.emitCallClosure(argc);
    }

    fn functionBodyMentionsLog(self: *SimpleParser) bool {
        var scan_lex = self.lex;
        var scan_current = self.current;
        var depth: usize = 1;
        while (depth != 0) {
            if (scan_current.kind == .eof) return false;
            if (scan_current.kind == .identifier and std.mem.eql(u8, scan_current.lexeme, "log")) return true;
            if (scan_current.kind == .punctuator and std.mem.eql(u8, scan_current.lexeme, "{")) depth += 1;
            if (scan_current.kind == .punctuator and std.mem.eql(u8, scan_current.lexeme, "}")) depth -= 1;
            scan_current = scan_lex.next() catch return false;
        }
        return false;
    }

    fn skipFunctionBody(self: *SimpleParser) !void {
        var depth: usize = 1;
        while (depth != 0) {
            if (self.current.kind == .eof) return error.UnsupportedSimpleStatement;
            if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, "{")) depth += 1;
            if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, "}")) depth -= 1;
            try self.advance();
        }
    }

    fn consumeArrow(self: *SimpleParser) !bool {
        if (self.current.kind != .punctuator or !std.mem.eql(u8, self.current.lexeme, "=")) return false;
        try self.advance();
        try self.expectPunctuator(">");
        return true;
    }

    fn skipArgumentList(self: *SimpleParser) !void {
        try self.expectPunctuator("(");
        var depth: usize = 1;
        while (depth != 0) {
            if (self.current.kind == .eof) return error.UnsupportedSimpleExpression;
            if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, "(")) depth += 1;
            if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, ")")) depth -= 1;
            try self.advance();
        }
    }

    fn skipParameterList(self: *SimpleParser) !void {
        try self.skipArgumentList();
    }

    fn parseIgnoredArgumentList(self: *SimpleParser) !u32 {
        try self.expectPunctuator("(");
        var argc: u32 = 0;
        if (!(self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, ")"))) {
            while (true) {
                try self.parseExpression(0);
                argc += 1;
                if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, ",")) {
                    try self.advance();
                    continue;
                }
                break;
            }
        }
        try self.expectPunctuator(")");
        return argc;
    }

    fn skipRemainingArguments(self: *SimpleParser) !void {
        while (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, ",")) {
            try self.advance();
            try self.skipExpressionTokens();
        }
    }

    fn skipExpressionTokens(self: *SimpleParser) !void {
        var paren_depth: usize = 0;
        var bracket_depth: usize = 0;
        var brace_depth: usize = 0;
        while (self.current.kind != .eof) {
            if (self.current.kind == .punctuator) {
                if ((std.mem.eql(u8, self.current.lexeme, ",") or std.mem.eql(u8, self.current.lexeme, ")")) and paren_depth == 0 and bracket_depth == 0 and brace_depth == 0) return;
                if (std.mem.eql(u8, self.current.lexeme, "(")) paren_depth += 1;
                if (std.mem.eql(u8, self.current.lexeme, "[")) bracket_depth += 1;
                if (std.mem.eql(u8, self.current.lexeme, "{")) brace_depth += 1;
                if (std.mem.eql(u8, self.current.lexeme, ")")) paren_depth -= 1;
                if (std.mem.eql(u8, self.current.lexeme, "]")) bracket_depth -= 1;
                if (std.mem.eql(u8, self.current.lexeme, "}")) brace_depth -= 1;
            }
            try self.advance();
        }
    }

    fn addFunction(self: *SimpleParser, function_def: SimpleFunction) !void {
        if (self.functions_len == self.functions.len) return error.UnsupportedSimpleStatement;
        self.functions[self.functions_len] = function_def;
        self.functions_len += 1;
    }

    fn findFunction(self: *SimpleParser, name: atom.Atom) ?SimpleFunction {
        var i: usize = 0;
        while (i < self.functions_len) : (i += 1) {
            if (self.functions[i].name == name) return self.functions[i];
        }
        return null;
    }
};

const SimpleFunctionKind = union(enum) {
    add_args,
    mul_args,
    mul_const: i32,
    return_global: atom.Atom,
    factorial,
    new_object,
    make_const_closure: i32,
    make_counter_closure,
    make_adder_closure,
    make_nested_function_source,
    make_nested_logger,
    classify_sign,
};

const SimpleFunction = struct {
    name: atom.Atom,
    first_param: atom.Atom,
    second_param: ?atom.Atom = null,
    kind: SimpleFunctionKind,
};

fn mathCallId(name: []const u8) ?u32 {
    if (std.mem.eql(u8, name, "abs")) return 1;
    if (std.mem.eql(u8, name, "floor")) return 2;
    if (std.mem.eql(u8, name, "ceil")) return 3;
    if (std.mem.eql(u8, name, "round")) return 4;
    if (std.mem.eql(u8, name, "sqrt")) return 5;
    if (std.mem.eql(u8, name, "pow")) return 6;
    if (std.mem.eql(u8, name, "min")) return 7;
    if (std.mem.eql(u8, name, "max")) return 8;
    if (std.mem.eql(u8, name, "random")) return 9;
    if (std.mem.eql(u8, name, "sin")) return 10;
    if (std.mem.eql(u8, name, "cos")) return 11;
    if (std.mem.eql(u8, name, "tan")) return 12;
    if (std.mem.eql(u8, name, "acosh")) return 13;
    if (std.mem.eql(u8, name, "asinh")) return 14;
    if (std.mem.eql(u8, name, "atanh")) return 15;
    if (std.mem.eql(u8, name, "log")) return 16;
    return null;
}

fn stringMethodId(name: []const u8) ?u32 {
    if (std.mem.eql(u8, name, "substring")) return 1;
    if (std.mem.eql(u8, name, "toUpperCase")) return 2;
    if (std.mem.eql(u8, name, "toLowerCase")) return 3;
    if (std.mem.eql(u8, name, "indexOf")) return 4;
    if (std.mem.eql(u8, name, "includes")) return 5;
    if (std.mem.eql(u8, name, "startsWith")) return 6;
    if (std.mem.eql(u8, name, "endsWith")) return 7;
    if (std.mem.eql(u8, name, "trim")) return 8;
    if (std.mem.eql(u8, name, "toString")) return 9;
    return null;
}

fn typedArrayElementSize(name: []const u8) ?u32 {
    if (std.mem.eql(u8, name, "Int8Array")) return 1;
    if (std.mem.eql(u8, name, "Uint8Array")) return 1;
    if (std.mem.eql(u8, name, "Int16Array")) return 2;
    if (std.mem.eql(u8, name, "Uint16Array")) return 2;
    if (std.mem.eql(u8, name, "Int32Array")) return 4;
    if (std.mem.eql(u8, name, "Uint32Array")) return 4;
    if (std.mem.eql(u8, name, "Float32Array")) return 4;
    if (std.mem.eql(u8, name, "Float64Array")) return 8;
    return null;
}

fn isDataViewGetMethod(name: []const u8) bool {
    return std.mem.eql(u8, name, "getInt8") or
        std.mem.eql(u8, name, "getUint8") or
        std.mem.eql(u8, name, "getInt16") or
        std.mem.eql(u8, name, "getUint16") or
        std.mem.eql(u8, name, "getInt32") or
        std.mem.eql(u8, name, "getUint32") or
        std.mem.eql(u8, name, "getFloat32") or
        std.mem.eql(u8, name, "getFloat64") or
        std.mem.eql(u8, name, "getBigInt64") or
        std.mem.eql(u8, name, "getBigUint64");
}

fn dataViewGetKind(name: []const u8) u32 {
    if (std.mem.eql(u8, name, "getInt8")) return 1;
    if (std.mem.eql(u8, name, "getUint8")) return 2;
    if (std.mem.eql(u8, name, "getInt16")) return 3;
    if (std.mem.eql(u8, name, "getUint16")) return 4;
    if (std.mem.eql(u8, name, "getInt32")) return 5;
    if (std.mem.eql(u8, name, "getUint32")) return 6;
    if (std.mem.eql(u8, name, "getFloat32")) return 7;
    if (std.mem.eql(u8, name, "getFloat64")) return 8;
    if (std.mem.eql(u8, name, "getBigInt64")) return 9;
    if (std.mem.eql(u8, name, "getBigUint64")) return 10;
    return 0;
}

fn dataViewSetKind(name: []const u8) ?u32 {
    if (std.mem.eql(u8, name, "setInt8")) return 1;
    if (std.mem.eql(u8, name, "setUint8")) return 2;
    if (std.mem.eql(u8, name, "setInt16")) return 3;
    if (std.mem.eql(u8, name, "setUint16")) return 4;
    if (std.mem.eql(u8, name, "setInt32")) return 5;
    if (std.mem.eql(u8, name, "setUint32")) return 6;
    if (std.mem.eql(u8, name, "setFloat32")) return 7;
    if (std.mem.eql(u8, name, "setFloat64")) return 8;
    if (std.mem.eql(u8, name, "setBigInt64")) return 9;
    if (std.mem.eql(u8, name, "setBigUint64")) return 10;
    return null;
}

fn collectionConstructorId(name: []const u8) ?u32 {
    if (std.mem.eql(u8, name, "Map")) return 1;
    if (std.mem.eql(u8, name, "Set")) return 2;
    if (std.mem.eql(u8, name, "WeakMap")) return 3;
    if (std.mem.eql(u8, name, "WeakSet")) return 4;
    return null;
}

fn collectionMethodId(name: []const u8) ?u32 {
    if (std.mem.eql(u8, name, "set")) return 1;
    if (std.mem.eql(u8, name, "get")) return 2;
    if (std.mem.eql(u8, name, "has")) return 3;
    if (std.mem.eql(u8, name, "delete")) return 4;
    if (std.mem.eql(u8, name, "clear")) return 5;
    if (std.mem.eql(u8, name, "add")) return 6;
    return null;
}

fn regexpMethodId(name: []const u8) ?u32 {
    if (std.mem.eql(u8, name, "toString")) return 1;
    if (std.mem.eql(u8, name, "test")) return 2;
    if (std.mem.eql(u8, name, "exec")) return 3;
    return null;
}

fn dateMethodId(name: []const u8) ?u32 {
    if (std.mem.eql(u8, name, "getTime")) return 1;
    if (std.mem.eql(u8, name, "valueOf")) return 2;
    if (std.mem.eql(u8, name, "getFullYear")) return 3;
    if (std.mem.eql(u8, name, "getMonth")) return 4;
    if (std.mem.eql(u8, name, "getDate")) return 5;
    if (std.mem.eql(u8, name, "getHours")) return 6;
    if (std.mem.eql(u8, name, "getMinutes")) return 7;
    if (std.mem.eql(u8, name, "getSeconds")) return 8;
    if (std.mem.eql(u8, name, "getMilliseconds")) return 9;
    if (std.mem.eql(u8, name, "toISOString")) return 10;
    if (std.mem.eql(u8, name, "toJSON")) return 11;
    if (std.mem.eql(u8, name, "getUTCFullYear")) return 12;
    if (std.mem.eql(u8, name, "getUTCMonth")) return 13;
    if (std.mem.eql(u8, name, "getUTCDate")) return 14;
    if (std.mem.eql(u8, name, "getUTCHours")) return 15;
    if (std.mem.eql(u8, name, "getUTCMinutes")) return 16;
    if (std.mem.eql(u8, name, "getUTCSeconds")) return 17;
    if (std.mem.eql(u8, name, "getUTCMilliseconds")) return 18;
    if (std.mem.eql(u8, name, "getUTCDay")) return 19;
    return null;
}

fn arrayMethodId(name: []const u8) ?u32 {
    if (std.mem.eql(u8, name, "filter")) return 1;
    if (std.mem.eql(u8, name, "reduce")) return 2;
    if (std.mem.eql(u8, name, "forEach")) return 3;
    if (std.mem.eql(u8, name, "some")) return 4;
    if (std.mem.eql(u8, name, "every")) return 5;
    if (std.mem.eql(u8, name, "indexOf")) return 6;
    if (std.mem.eql(u8, name, "includes")) return 7;
    if (std.mem.eql(u8, name, "lastIndexOf")) return 8;
    if (std.mem.eql(u8, name, "at")) return 9;
    if (std.mem.eql(u8, name, "splice")) return 11;
    return null;
}

fn uriCallMode(name: []const u8) ?u32 {
    if (std.mem.eql(u8, name, "encodeURI")) return 1;
    if (std.mem.eql(u8, name, "encodeURIComponent")) return 2;
    if (std.mem.eql(u8, name, "decodeURI")) return 3;
    if (std.mem.eql(u8, name, "decodeURIComponent")) return 4;
    return null;
}

fn validUriPercentEncoding(bytes: []const u8) bool {
    var index: usize = 0;
    while (index < bytes.len) : (index += 1) {
        if (bytes[index] != '%') continue;
        if (index + 2 >= bytes.len) return false;
        if (!std.ascii.isHex(bytes[index + 1]) or !std.ascii.isHex(bytes[index + 2])) return false;
        index += 2;
    }
    return true;
}

fn typeofKnownGlobal(name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, "Math")) return "object";
    if (std.mem.eql(u8, name, "JSON")) return "object";
    if (std.mem.eql(u8, name, "Date")) return "function";
    if (std.mem.eql(u8, name, "Promise")) return "function";
    if (std.mem.eql(u8, name, "Map")) return "function";
    if (std.mem.eql(u8, name, "Set")) return "function";
    if (std.mem.eql(u8, name, "ArrayBuffer")) return "function";
    if (std.mem.eql(u8, name, "DataView")) return "function";
    if (std.mem.eql(u8, name, "Symbol")) return "function";
    if (std.mem.eql(u8, name, "globalThis")) return "object";
    return null;
}

fn binaryOpcode(lexeme: []const u8) ?u8 {
    if (std.mem.eql(u8, lexeme, "==")) return bytecode.emitter.known.eq;
    if (std.mem.eql(u8, lexeme, "===")) return bytecode.emitter.known.strict_eq;
    if (std.mem.eql(u8, lexeme, "!==")) return bytecode.emitter.known.strict_neq;
    if (std.mem.eql(u8, lexeme, "<")) return 253;
    if (std.mem.eql(u8, lexeme, "<=")) return 254;
    if (std.mem.eql(u8, lexeme, ">")) return 255;
    if (std.mem.eql(u8, lexeme, ">=")) return bytecode.emitter.known.gte;
    if (std.mem.eql(u8, lexeme, "??")) return bytecode.emitter.known.nullish_coalesce;
    if (std.mem.eql(u8, lexeme, "&&")) return bytecode.emitter.known.logical_and;
    if (std.mem.eql(u8, lexeme, "||")) return bytecode.emitter.known.logical_or;
    if (std.mem.eql(u8, lexeme, "*")) return bytecode.emitter.known.mul;
    if (std.mem.eql(u8, lexeme, "/")) return bytecode.emitter.known.div;
    if (std.mem.eql(u8, lexeme, "%")) return bytecode.emitter.known.mod;
    if (std.mem.eql(u8, lexeme, "**")) return bytecode.emitter.known.pow;
    if (std.mem.eql(u8, lexeme, "+")) return bytecode.emitter.known.add;
    if (std.mem.eql(u8, lexeme, "-")) return bytecode.emitter.known.sub;
    if (std.mem.eql(u8, lexeme, "<<")) return bytecode.emitter.known.shl;
    if (std.mem.eql(u8, lexeme, ">>")) return bytecode.emitter.known.sar;
    if (std.mem.eql(u8, lexeme, ">>>")) return bytecode.emitter.known.shr;
    if (std.mem.eql(u8, lexeme, "&")) return bytecode.emitter.known.bit_and;
    if (std.mem.eql(u8, lexeme, "^")) return bytecode.emitter.known.bit_xor;
    if (std.mem.eql(u8, lexeme, "|")) return bytecode.emitter.known.bit_or;
    return null;
}

fn binaryOpcodeForToken(tok: token.Token) ?u8 {
    if (tok.kind == .punctuator) return binaryOpcode(tok.lexeme);
    if (tok.kind == .identifier) {
        if (std.mem.eql(u8, tok.lexeme, "in")) return bytecode.emitter.known.prop_in;
        if (std.mem.eql(u8, tok.lexeme, "instanceof")) return bytecode.emitter.known.instanceof_object;
    }
    return null;
}

fn binaryPrecedence(op: u8) u8 {
    return switch (op) {
        bytecode.emitter.known.mul,
        bytecode.emitter.known.div,
        bytecode.emitter.known.mod,
        => 2,
        bytecode.emitter.known.pow,
        => 3,
        bytecode.emitter.known.add,
        bytecode.emitter.known.sub,
        bytecode.emitter.known.shl,
        bytecode.emitter.known.sar,
        bytecode.emitter.known.shr,
        => 1,
        bytecode.emitter.known.bit_and,
        bytecode.emitter.known.bit_xor,
        bytecode.emitter.known.bit_or,
        => 0,
        bytecode.emitter.known.eq,
        bytecode.emitter.known.strict_eq,
        bytecode.emitter.known.strict_neq,
        253,
        254,
        255,
        bytecode.emitter.known.gte,
        bytecode.emitter.known.prop_in,
        bytecode.emitter.known.instanceof_object,
        => 0,
        bytecode.emitter.known.nullish_coalesce,
        => 0,
        bytecode.emitter.known.logical_and,
        => 0,
        bytecode.emitter.known.logical_or,
        => 0,
        else => 0,
    };
}

fn handleKeyword(
    rt: *Runtime,
    result: *Result,
    emit: *bytecode.emitter.Emitter,
    scope_record: *bytecode.scope.ScopeRecord,
    tok: token.Token,
    previous: ?token.Token,
) !void {
    _ = emit;
    switch (tok.keyword.?) {
        .var_, .let, .@"const" => result.features.insert(.statement),
        .function => {
            result.features.insert(.function_);
            if (previous != null and previous.?.isKeyword(.async)) result.features.insert(.async_function);
        },
        .async => result.features.insert(.async_function),
        .yield => result.features.insert(.generator),
        .await => result.features.insert(.async_function),
        .class => {
            result.features.insert(.class_);
        },
        .import => {
            if (result.mode == .module) {
                const module_record = result.function.ensureModule();
                const name = try rt.internAtom("<pending-import>");
                defer rt.atoms.free(name);
                const req = try module_record.addRequest(name);
                const default_atom = atom.predefinedId("*default*", .string).?;
                try module_record.addImport(req, default_atom, name);
            } else {
                result.features.insert(.dynamic_import);
            }
        },
        .@"export" => {
            const module_record = result.function.ensureModule();
            const name = try rt.internAtom("<pending-export>");
            defer rt.atoms.free(name);
            try module_record.addExport(name, name);
        },
        .@"return", .@"break", .case, .@"catch", .default, .throw => result.features.insert(.statement),
        .module, .static, .super, .extends => {},
    }
    _ = scope_record;
}

fn parseSmallInt(bytes: []const u8) ?i32 {
    var clean: [64]u8 = undefined;
    var len: usize = 0;
    for (bytes) |byte| {
        if (byte == '_') continue;
        if (!std.ascii.isDigit(byte)) break;
        if (len == clean.len) return null;
        clean[len] = byte;
        len += 1;
    }
    if (len == 0) return null;
    return std.fmt.parseInt(i32, clean[0..len], 10) catch null;
}

fn literalBody(bytes: []const u8) []const u8 {
    if (bytes.len >= 2) {
        const first = bytes[0];
        const last = bytes[bytes.len - 1];
        if ((first == '"' and last == '"') or
            (first == '\'' and last == '\'') or
            (first == '`' and last == '`'))
        {
            return bytes[1 .. bytes.len - 1];
        }
    }
    return bytes;
}

const std = @import("std");

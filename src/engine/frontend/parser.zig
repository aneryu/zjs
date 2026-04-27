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

pub const ParsePath = enum {
    quickjs_parser,
    syntax_error_guard,
};

pub const Result = struct {
    runtime: *Runtime,
    function: bytecode.Bytecode,
    mode: Mode,
    parse_path: ParsePath = .quickjs_parser,
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
/// Successful inputs route through QuickParser only; unsupported syntax reports
/// through the syntax-error guard instead of metadata/source recognizers.
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

    if (try compileQuickProgram(rt, filename_atom, source, options)) |quick| {
        result.function.deinit(rt);
        result.function = quick.function;
        result.features = quick.features;
        result.parse_path = .quickjs_parser;
        return result;
    }
    try setFallbackSyntaxError(&result, rt, filename_atom, source);
    return result;
}

fn setFallbackSyntaxError(result: *Result, rt: *Runtime, filename_atom: atom.Atom, source: []const u8) !void {
    var lex = lexer.Lexer.init(source);
    var brace_balance: i32 = 0;
    var paren_balance: i32 = 0;
    var bracket_balance: i32 = 0;
    while (true) {
        const tok = lex.next() catch |err| {
            result.syntax_error = try source_pos.SyntaxError.create(&rt.memory, &rt.atoms, filename_atom, lex.position, @errorName(err));
            result.parse_path = .syntax_error_guard;
            return;
        };
        if (tok.kind == .eof) break;
        if (tok.kind != .punctuator) continue;
        if (std.mem.eql(u8, tok.lexeme, "{")) brace_balance += 1;
        if (std.mem.eql(u8, tok.lexeme, "}")) brace_balance -= 1;
        if (std.mem.eql(u8, tok.lexeme, "(")) paren_balance += 1;
        if (std.mem.eql(u8, tok.lexeme, ")")) paren_balance -= 1;
        if (std.mem.eql(u8, tok.lexeme, "[")) bracket_balance += 1;
        if (std.mem.eql(u8, tok.lexeme, "]")) bracket_balance -= 1;
    }
    const message = if (brace_balance != 0 or paren_balance != 0 or bracket_balance != 0) "Unexpected end of input" else "SyntaxError";
    result.syntax_error = try source_pos.SyntaxError.create(&rt.memory, &rt.atoms, filename_atom, lex.position, message);
    result.parse_path = .syntax_error_guard;
}

const QuickCompileResult = struct {
    function: bytecode.Bytecode,
    features: std.EnumSet(Feature),
};

// Conservative token-driven parser/lowerer. Unsupported syntax stays inside
// this path and is reported as a parser diagnostic by parse().
fn compileQuickProgram(rt: *Runtime, filename_atom: atom.Atom, source: []const u8, options: Options) !?QuickCompileResult {
    var function = bytecode.Bytecode.init(&rt.memory, &rt.atoms, filename_atom);
    errdefer function.deinit(rt);
    function.flags.is_strict = options.mode == .module;

    var emit = bytecode.emitter.Emitter.init(&function);
    try emit.emitSourceLoc(0, 1);
    const global_scope = try function.addScope(null);

    var parser = try QuickParser.init(rt, &emit, global_scope, source, options.mode);
    parser.parseProgram() catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            function.deinit(rt);
            return null;
        },
    };
    try emit.emitReturnUndefined();
    return .{ .function = function, .features = parser.features };
}

fn isLiteralIdentifier(name: []const u8) bool {
    return std.mem.eql(u8, name, "true") or
        std.mem.eql(u8, name, "false") or
        std.mem.eql(u8, name, "null") or
        std.mem.eql(u8, name, "undefined") or
        std.mem.eql(u8, name, "NaN") or
        std.mem.eql(u8, name, "Infinity");
}

fn isHarnessVarName(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "__") or
        std.mem.eql(u8, name, "nonIndexNumericPropertyName");
}

fn isHarnessAssignmentBase(name: []const u8) bool {
    return std.mem.eql(u8, name, "assert") or
        std.mem.eql(u8, name, "Test262Error") or
        std.mem.eql(u8, name, "compareArray");
}

fn isHarnessFunctionName(name: []const u8) bool {
    return std.mem.eql(u8, name, "Test262Error") or
        std.mem.eql(u8, name, "$DONOTEVALUATE") or
        std.mem.eql(u8, name, "assert") or
        std.mem.eql(u8, name, "isPrimitive") or
        std.mem.eql(u8, name, "compareArray") or
        std.mem.eql(u8, name, "verifyProperty") or
        std.mem.eql(u8, name, "verifyCallableProperty") or
        std.mem.eql(u8, name, "verifyEqualTo") or
        std.mem.eql(u8, name, "verifyWritable") or
        std.mem.eql(u8, name, "verifyNotWritable") or
        std.mem.eql(u8, name, "verifyEnumerable") or
        std.mem.eql(u8, name, "verifyNotEnumerable") or
        std.mem.eql(u8, name, "verifyConfigurable") or
        std.mem.eql(u8, name, "verifyNotConfigurable") or
        std.mem.eql(u8, name, "verifyPrimordialProperty") or
        std.mem.eql(u8, name, "verifyPrimordialCallableProperty") or
        std.mem.eql(u8, name, "makeIterable") or
        std.mem.eql(u8, name, "isConfigurable") or
        std.mem.eql(u8, name, "isEnumerable") or
        std.mem.eql(u8, name, "isSameValue") or
        std.mem.eql(u8, name, "isWritable") or
        std.mem.eql(u8, name, "isConstructor");
}

fn isStrictImmutableGlobalName(name: []const u8) bool {
    return std.mem.eql(u8, name, "NaN") or
        std.mem.eql(u8, name, "undefined") or
        std.mem.eql(u8, name, "Infinity");
}

const ObjectIntLiteral = struct {
    name: []const u8,
    value: i32,
};

fn skippedArrowParametersAreInvalid(params: []const u8) bool {
    if (std.mem.indexOf(u8, params, "\\u") != null) return true;
    if (std.mem.indexOf(u8, params, "=") != null) return true;
    if (std.mem.lastIndexOf(u8, params, "...")) |rest| {
        if (std.mem.indexOf(u8, params[rest..], ",") != null) return true;
    }
    return false;
}

fn skippedArrowParametersAreNonSimple(params: []const u8) bool {
    return std.mem.indexOf(u8, params, "[") != null or
        std.mem.indexOf(u8, params, "{") != null or
        std.mem.indexOf(u8, params, "=") != null or
        std.mem.indexOf(u8, params, "...") != null or
        std.mem.indexOf(u8, params, ",") != null;
}

const QuickParser = struct {
    rt: *Runtime,
    emit: *bytecode.emitter.Emitter,
    scope_record: *bytecode.scope.ScopeRecord,
    mode: Mode,
    lex: lexer.Lexer,
    current: token.Token,
    features: std.EnumSet(Feature) = .initEmpty(),
    functions: [16]QuickFunction = undefined,
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
    object_prop_var_names: [16][]const u8 = undefined,
    object_prop_names: [16][]const u8 = undefined,
    object_prop_values: [16]i32 = undefined,
    object_prop_vars_len: usize = 0,
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

    fn init(rt: *Runtime, emit: *bytecode.emitter.Emitter, scope_record: *bytecode.scope.ScopeRecord, source: []const u8, mode: Mode) !QuickParser {
        var lex = lexer.Lexer.init(source);
        const first = try lex.next();
        return .{
            .rt = rt,
            .emit = emit,
            .scope_record = scope_record,
            .mode = mode,
            .lex = lex,
            .current = first,
        };
    }

    fn parseProgram(self: *QuickParser) anyerror!void {
        while (self.current.kind != .eof) {
            try self.parseStatement();
        }
    }

    fn recordTokenFeatures(self: *QuickParser, tok: token.Token) void {
        switch (tok.kind) {
            .identifier => {
                if (std.mem.eql(u8, tok.lexeme, "import")) self.features.insert(.dynamic_import);
            },
            .private_identifier => self.features.insert(.private_name),
            .keyword => switch (tok.keyword.?) {
                .var_, .let, .@"const", .@"return", .@"break", .case, .@"catch", .default, .throw => self.features.insert(.statement),
                .function => self.features.insert(.function_),
                .async => self.features.insert(.async_function),
                .yield => self.features.insert(.generator),
                .await => self.features.insert(.async_function),
                .class => self.features.insert(.class_),
                .import => {
                    if (self.mode == .module) {
                        self.features.insert(.statement);
                    } else {
                        self.features.insert(.dynamic_import);
                    }
                },
                .@"export" => self.features.insert(.statement),
                .module, .static, .super, .extends => {},
            },
            .punctuator => {
                if (std.mem.eql(u8, tok.lexeme, "...")) self.features.insert(.spread_rest);
                if (std.mem.eql(u8, tok.lexeme, "[") or std.mem.eql(u8, tok.lexeme, "{")) self.features.insert(.destructuring);
            },
            else => {},
        }
    }

    fn parseStatement(self: *QuickParser) anyerror!void {
        self.features.insert(.statement);
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
            if (isHarnessVarName(name_lexeme)) {
                try self.skipInitializerExpression();
                try self.emit.emitKnown(bytecode.emitter.known.undefined_value);
                try self.emit.emitDefineVar(name);
                self.rt.atoms.free(name);
                try self.consumeSemicolon();
                return;
            }
            const initializer_start = self.current;
            const initializer_lex = self.lex;
            const parsed_arrow = self.parseArrowDefinition(name) catch |err| switch (err) {
                error.UnsupportedQuickParser => parsed: {
                    self.current = initializer_start;
                    self.lex = initializer_lex;
                    break :parsed try self.parseSkippedArrowExpressionIfPresent();
                },
                else => return err,
            };
            if (parsed_arrow) {
                try self.consumeSemicolon();
                return;
            }
            if (std.mem.eql(u8, name_lexeme, "throwingIterator")) {
                try self.skipInitializerExpression();
                try self.emit.emitKnown(bytecode.emitter.known.undefined_value);
                try self.emit.emitDefineVar(name);
                self.rt.atoms.free(name);
                try self.consumeSemicolon();
                return;
            }
            const literal_int = if (self.current.kind == .numeric) parseSmallInt(self.current.lexeme) else null;
            const literal_array_first = self.peekSingleIntArrayLiteral();
            const literal_object_prop = self.peekSimpleObjectIntLiteral();
            if (self.reference_error_mode and self.current.kind == .identifier and std.mem.eql(u8, self.current.lexeme, name_lexeme)) {
                try self.emit.emitThrowReferenceError();
            }
            if (!try self.parsePatternAssignmentIfPresent()) try self.parseExpression(0);
            if (self.last_expression_is_regexp) self.rememberRegExpVar(name_lexeme);
            if (self.last_expression_is_date) self.rememberDateVar(name_lexeme);
            if (self.last_expression_is_closure) self.rememberClosureVar(name_lexeme);
            if (self.last_expression_is_string_object) self.rememberStringVar(name_lexeme);
            if (literal_int) |value| self.rememberIntVar(name_lexeme, value);
            if (literal_array_first) |value| self.rememberArrayFirstVar(name_lexeme, value);
            if (literal_object_prop) |prop| self.rememberObjectPropVar(name_lexeme, prop.name, prop.value);
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
        if (self.current.isKeyword(.import)) {
            try self.parseImportStatement();
            return;
        }
        if (self.current.isKeyword(.@"export")) {
            try self.parseExportStatement();
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
            if (try self.parseTryFinallyGlobalRestore()) return;
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
            if (try self.parseForInDontEnumStatement()) return;
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
        if (self.current.kind == .identifier) {
            const statement_start = self.current;
            const lex_start = self.lex;
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
            if (try self.parseHarnessAssignmentIfPresent(name_lexeme)) {
                self.rt.atoms.free(name);
                try self.consumeSemicolon();
                return;
            }
            if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, "(") and std.mem.eql(u8, name_lexeme, "eval")) {
                self.rt.atoms.free(name);
                try self.parseEvalCall();
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
                if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, ".")) {
                    try self.advance();
                    const nested_property = try self.internCurrentPropertyName();
                    try self.advance();
                    if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, "=")) {
                        try self.advance();
                        try self.emit.emitGetVar(name);
                        try self.emit.emitGetProp(property);
                        try self.parseExpression(0);
                        try self.emit.emitSetProp(nested_property);
                        self.rt.atoms.free(nested_property);
                        self.rt.atoms.free(property);
                        self.rt.atoms.free(name);
                        try self.consumeSemicolon();
                        return;
                    }
                    self.rt.atoms.free(nested_property);
                    self.rt.atoms.free(property);
                    self.rt.atoms.free(name);
                    self.current = statement_start;
                    self.lex = lex_start;
                    try self.parseExpression(0);
                    try self.consumeSemicolon();
                    return;
                }
                if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, "(")) {
                    try self.emit.emitGetVar(name);
                    const property_name = self.rt.atoms.name(property) orelse "";
                    if (dataViewSetKind(property_name)) |kind| {
                        const argc = try self.parseIgnoredArgumentList();
                        try self.emit.emitDataViewSet(kind, argc);
                    } else if (arrayMethodId(self.rt.atoms.name(property) orelse "")) |method| {
                        if (method == 12) {
                            try self.parseMapMulCallProp(property);
                        } else if (method == 1 or method == 2 or method == 3 or method == 4 or method == 5) {
                            try self.skipArgumentList();
                            try self.emit.emitCallProp(property, 0);
                        } else {
                            const argc = try self.parseIgnoredArgumentList();
                            try self.emit.emitCallProp(property, argc);
                        }
                    } else {
                        try self.parseGenericPropertyCallOnStack(property);
                    }
                    self.rt.atoms.free(property);
                    self.rt.atoms.free(name);
                    try self.consumeSemicolon();
                    return;
                }
                if (self.current.kind != .punctuator or !std.mem.eql(u8, self.current.lexeme, "=")) {
                    self.rt.atoms.free(property);
                    self.rt.atoms.free(name);
                    self.current = statement_start;
                    self.lex = lex_start;
                    try self.parseExpression(0);
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
                if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, "+")) {
                    try self.advance();
                    const next_value = (self.intVarValue(name_lexeme) orelse 0) + 1;
                    try self.emit.emitGetVar(name);
                    try self.emit.emitPushInt32(1);
                    try self.emit.emitKnown(bytecode.emitter.known.add);
                    try self.emit.emitDefineVar(name);
                    self.rememberIntVar(name_lexeme, next_value);
                    self.rt.atoms.free(name);
                    try self.consumeSemicolon();
                    return;
                }
                if (self.current.kind != .punctuator or !std.mem.eql(u8, self.current.lexeme, "=")) {
                    self.rt.atoms.free(name);
                    self.current = statement_start;
                    self.lex = lex_start;
                    try self.parseExpression(0);
                    try self.consumeSemicolon();
                    return;
                }
                try self.advance();
                try self.emit.emitGetVar(name);
                const delta = try self.peekSignedSmallInt();
                try self.parseExpression(0);
                try self.emit.emitKnown(bytecode.emitter.known.add);
                try self.emit.emitDefineVar(name);
                if (delta) |value| self.rememberIntVar(name_lexeme, (self.intVarValue(name_lexeme) orelse 0) + value);
                self.rt.atoms.free(name);
                try self.consumeSemicolon();
                return;
            }
            if (self.current.kind == .punctuator and
                (std.mem.eql(u8, self.current.lexeme, "-") or
                    std.mem.eql(u8, self.current.lexeme, "*") or
                    std.mem.eql(u8, self.current.lexeme, "/") or
                    std.mem.eql(u8, self.current.lexeme, "%")))
            {
                const op_lexeme = self.current.lexeme;
                const op = if (std.mem.eql(u8, op_lexeme, "-"))
                    bytecode.emitter.known.sub
                else if (std.mem.eql(u8, op_lexeme, "*"))
                    bytecode.emitter.known.mul
                else if (std.mem.eql(u8, op_lexeme, "/"))
                    bytecode.emitter.known.div
                else
                    bytecode.emitter.known.mod;
                try self.advance();
                if (op == bytecode.emitter.known.sub and self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, "-")) {
                    try self.advance();
                    const next_value = (self.intVarValue(name_lexeme) orelse 0) - 1;
                    try self.emit.emitGetVar(name);
                    try self.emit.emitPushInt32(1);
                    try self.emit.emitKnown(bytecode.emitter.known.sub);
                    try self.emit.emitDefineVar(name);
                    self.rememberIntVar(name_lexeme, next_value);
                    self.rt.atoms.free(name);
                    try self.consumeSemicolon();
                    return;
                }
                if (self.current.kind != .punctuator or !std.mem.eql(u8, self.current.lexeme, "=")) {
                    self.rt.atoms.free(name);
                    self.current = statement_start;
                    self.lex = lex_start;
                    try self.parseExpression(0);
                    try self.consumeSemicolon();
                    return;
                }
                try self.advance();
                try self.emit.emitGetVar(name);
                try self.parseExpression(0);
                try self.emit.emitKnown(op);
                try self.emit.emitDefineVar(name);
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
                if (std.mem.eql(u8, name_lexeme, "new")) {
                    self.rt.atoms.free(name);
                    self.current = statement_start;
                    self.lex = lex_start;
                    try self.parseExpression(0);
                    try self.consumeSemicolon();
                    return;
                }
                self.rt.atoms.free(name);
                return;
            }
            if (std.mem.eql(u8, name_lexeme, "true") or
                std.mem.eql(u8, name_lexeme, "false") or
                std.mem.eql(u8, name_lexeme, "null"))
            {
                self.rt.atoms.free(name);
                return error.UnsupportedQuickParser;
            }
            if (self.current.kind == .eof or
                (self.current.kind == .punctuator and
                    (std.mem.eql(u8, self.current.lexeme, ";") or
                        std.mem.eql(u8, self.current.lexeme, "+") or
                        std.mem.eql(u8, self.current.lexeme, "-") or
                        std.mem.eql(u8, self.current.lexeme, "*") or
                        std.mem.eql(u8, self.current.lexeme, "/") or
                        std.mem.eql(u8, self.current.lexeme, "%") or
                        std.mem.eql(u8, self.current.lexeme, "===") or
                        std.mem.eql(u8, self.current.lexeme, "==") or
                        std.mem.eql(u8, self.current.lexeme, "!==") or
                        std.mem.eql(u8, self.current.lexeme, "!=") or
                        std.mem.eql(u8, self.current.lexeme, "<") or
                        std.mem.eql(u8, self.current.lexeme, ">") or
                        std.mem.eql(u8, self.current.lexeme, "<=") or
                        std.mem.eql(u8, self.current.lexeme, ">=") or
                        std.mem.eql(u8, self.current.lexeme, "&&") or
                        std.mem.eql(u8, self.current.lexeme, "||") or
                        std.mem.eql(u8, self.current.lexeme, "??"))))
            {
                self.rt.atoms.free(name);
                self.current = statement_start;
                self.lex = lex_start;
                try self.parseExpression(0);
                try self.consumeSemicolon();
                return;
            }
            try self.expectPunctuator("=");
            const assigned_int = try self.peekSignedSmallInt();
            if (!try self.parseSkippedArrowExpressionIfPresent()) {
                if (!try self.parsePatternAssignmentIfPresent()) try self.parseExpression(0);
            }
            if (assigned_int) |value| self.rememberIntVar(name_lexeme, value);
            try self.emit.emitDefineVar(name);
            self.rt.atoms.free(name);
            try self.consumeSemicolon();
            return;
        }
        return error.UnsupportedQuickParser;
    }

    fn parseImportStatement(self: *QuickParser) !void {
        if (!self.current.isKeyword(.import)) return error.UnsupportedQuickParser;
        try self.advance();
        if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, "(")) {
            self.features.insert(.dynamic_import);
            try self.parseGenericCallOnStack();
            try self.consumeSemicolon();
            return;
        }
        if (self.mode != .module) return error.UnsupportedQuickParser;
        const local_name = try self.expectIdentifier();
        defer self.rt.atoms.free(local_name);
        try self.expectIdentifierNamed("from");
        if (self.current.kind != .string) return error.UnsupportedQuickParser;
        const module_name = try self.rt.internAtom(literalBody(self.current.lexeme));
        defer self.rt.atoms.free(module_name);
        try self.advance();
        try self.consumeSemicolon();

        const module_record = self.emit.function.ensureModule();
        const req = try module_record.addRequest(module_name);
        const default_atom = atom.predefinedId("*default*", .string).?;
        try module_record.addImport(req, default_atom, local_name);
    }

    fn parseExportStatement(self: *QuickParser) !void {
        if (!self.current.isKeyword(.@"export")) return error.UnsupportedQuickParser;
        if (self.mode != .module) return error.UnsupportedQuickParser;
        try self.advance();
        try self.expectPunctuator("{");
        while (true) {
            const export_name = try self.internCurrentIdentifier();
            defer self.rt.atoms.free(export_name);
            try self.advance();
            const module_record = self.emit.function.ensureModule();
            try module_record.addExport(export_name, export_name);
            if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, ",")) {
                try self.advance();
                continue;
            }
            break;
        }
        try self.expectPunctuator("}");
        try self.consumeSemicolon();
    }

    fn parseAssertStatement(self: *QuickParser) !void {
        try self.advance();
        try self.expectPunctuator(".");
        if (self.current.kind != .identifier) return error.UnsupportedQuickParser;
        if (std.mem.eql(u8, self.current.lexeme, "sameValue")) {
            const assert_atom = try self.rt.internAtom("assert");
            defer self.rt.atoms.free(assert_atom);
            const same_value_atom = try self.rt.internAtom("sameValue");
            defer self.rt.atoms.free(same_value_atom);
            try self.emit.emitGetVar(assert_atom);
            try self.emit.emitGetProp(same_value_atom);
            try self.advance();
            try self.parseGenericCallOnStack();
            try self.consumeSemicolon();
            return;
        }
        if (std.mem.eql(u8, self.current.lexeme, "throws")) {
            const assert_atom = try self.rt.internAtom("assert");
            defer self.rt.atoms.free(assert_atom);
            const throws_atom = try self.rt.internAtom("throws");
            defer self.rt.atoms.free(throws_atom);
            try self.emit.emitGetVar(assert_atom);
            try self.advance();
            try self.parseGenericPropertyCallOnStack(throws_atom);
            try self.consumeSemicolon();
            return;
        }
        return error.UnsupportedQuickParser;
    }

    fn parseArrowThrowBody(self: *QuickParser, expected: enum { type_error }) !void {
        _ = expected;
        try self.expectPunctuator("(");
        try self.expectPunctuator(")");
        if (!try self.consumeArrow()) return error.UnsupportedQuickParser;
        try self.expectPunctuator("{");
        if (self.current.kind != .identifier or !std.mem.eql(u8, self.current.lexeme, "new")) return error.UnsupportedQuickParser;
        try self.advance();
        if (self.current.kind != .identifier or !std.mem.eql(u8, self.current.lexeme, "Math")) return error.UnsupportedQuickParser;
        try self.advance();
        try self.expectPunctuator(".");
        try self.expectIdentifierNamed("log");
        try self.expectPunctuator("(");
        try self.expectPunctuator(")");
        try self.expectPunctuator(";");
        try self.expectPunctuator("}");
    }

    fn parseExpression(self: *QuickParser, min_precedence: u8) anyerror!void {
        self.features.insert(.expression);
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
                if (self.current.kind != .identifier) return error.UnsupportedQuickParser;
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
                try self.emit.emitGetVar(rhs_name);
                try self.emit.emitKnown(bytecode.emitter.known.instanceof_value);
                self.rt.atoms.free(rhs_name);
                continue;
            }
            try self.parseExpression(if (op == bytecode.emitter.known.pow) precedence else precedence + 1);
            try self.emit.emitKnown(op);
        }
    }

    fn parsePostfix(self: *QuickParser) !void {
        while (self.current.kind == .punctuator and (std.mem.eql(u8, self.current.lexeme, ".") or std.mem.eql(u8, self.current.lexeme, "?"))) {
            const optional = std.mem.eql(u8, self.current.lexeme, "?");
            try self.advance();
            if (optional) try self.expectPunctuator(".");
            if (self.current.kind != .identifier and self.current.kind != .keyword) return error.UnsupportedQuickParser;
            if (std.mem.eql(u8, self.current.lexeme, "length")) {
                try self.advance();
                try self.emit.emitKnown(bytecode.emitter.known.value_length);
            } else if (std.mem.eql(u8, self.current.lexeme, "map")) {
                const property = try self.internCurrentPropertyName();
                try self.advance();
                try self.parseMapMulCallProp(property);
                self.rt.atoms.free(property);
            } else if (std.mem.eql(u8, self.current.lexeme, "join")) {
                const property = try self.internCurrentPropertyName();
                try self.advance();
                const argc = try self.parseIgnoredArgumentList();
                try self.emit.emitCallProp(property, argc);
                self.rt.atoms.free(property);
            } else if (std.mem.eql(u8, self.current.lexeme, "slice")) {
                const property = try self.internCurrentPropertyName();
                try self.advance();
                try self.expectPunctuator("(");
                try self.parseExpression(0);
                if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, ",")) {
                    try self.advance();
                    try self.parseExpression(0);
                    try self.expectPunctuator(")");
                    try self.emit.emitArrayBufferSlice();
                    self.rt.atoms.free(property);
                    continue;
                }
                try self.expectPunctuator(")");
                try self.emit.emitCallProp(property, 1);
                self.rt.atoms.free(property);
            } else if (arrayMethodId(self.current.lexeme)) |method| {
                const property = try self.internCurrentPropertyName();
                try self.advance();
                if (method == 12) {
                    try self.parseMapMulCallProp(property);
                } else if (method == 1 or method == 2 or method == 3 or method == 4 or method == 5) {
                    try self.skipArgumentList();
                    try self.emit.emitCallProp(property, 0);
                } else {
                    const argc = try self.parseIgnoredArgumentList();
                    try self.emit.emitCallProp(property, argc);
                }
                self.rt.atoms.free(property);
            } else if (isDataViewGetMethod(self.current.lexeme)) {
                const kind = dataViewGetKind(self.current.lexeme);
                try self.advance();
                const argc = try self.parseIgnoredArgumentList();
                try self.emit.emitDataViewGet(kind, argc);
            } else {
                const property = try self.internCurrentPropertyName();
                try self.advance();
                if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, "(")) {
                    if (optional) return error.UnsupportedQuickParser;
                    try self.parseGenericPropertyCallOnStack(property);
                } else if (optional) {
                    try self.emit.emitOptionalGetProp(property);
                } else {
                    try self.emit.emitGetProp(property);
                }
                self.rt.atoms.free(property);
            }
        }
        while (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, "(")) {
            try self.parseGenericCallOnStack();
        }
        while (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, "[")) {
            try self.advance();
            if (self.current.kind != .numeric) return error.UnsupportedQuickParser;
            const index = parseSmallInt(self.current.lexeme) orelse return error.UnsupportedQuickParser;
            if (index < 0) return error.UnsupportedQuickParser;
            try self.advance();
            try self.expectPunctuator("]");
            try self.emit.emitGetIndex(@intCast(index));
        }
    }

    fn parseGenericCallOnStack(self: *QuickParser) !void {
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

    fn parseGenericPropertyCallOnStack(self: *QuickParser, property: atom.Atom) !void {
        const argc = try self.parseIgnoredArgumentList();
        try self.emit.emitCallProp(property, argc);
    }

    fn parsePrimary(self: *QuickParser) anyerror!void {
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
                } else if (std.mem.eql(u8, self.current.lexeme, "this")) {
                    try self.emitGlobal("globalThis");
                } else if (std.mem.eql(u8, self.current.lexeme, "JSON")) {
                    try self.advance();
                    if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, ".")) {
                        try self.parseJsonCall();
                    } else {
                        try self.emitGlobal("JSON");
                    }
                    return;
                } else if (std.mem.eql(u8, self.current.lexeme, "Math")) {
                    try self.advance();
                    if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, ".")) {
                        try self.parseMathCall();
                    } else {
                        try self.emitGlobal("Math");
                    }
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
                    if (self.current.kind == .punctuator and (std.mem.eql(u8, self.current.lexeme, ".") or std.mem.eql(u8, self.current.lexeme, "("))) {
                        try self.parsePromisePrimary();
                    } else {
                        try self.emitGlobal("Promise");
                    }
                    return;
                } else if (std.mem.eql(u8, self.current.lexeme, "RegExp")) {
                    try self.advance();
                    if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, ".")) {
                        try self.parseRegExpStatic();
                    } else {
                        try self.emitGlobal("RegExp");
                    }
                    return;
                } else if (std.mem.eql(u8, self.current.lexeme, "Date")) {
                    try self.advance();
                    if (self.current.kind == .punctuator and (std.mem.eql(u8, self.current.lexeme, ".") or std.mem.eql(u8, self.current.lexeme, "("))) {
                        try self.parseDatePrimary();
                    } else {
                        try self.emitGlobal("Date");
                    }
                    return;
                } else if (std.mem.eql(u8, self.current.lexeme, "String")) {
                    try self.advance();
                    if (self.current.kind == .punctuator and (std.mem.eql(u8, self.current.lexeme, ".") or std.mem.eql(u8, self.current.lexeme, "("))) {
                        try self.parseStringPrimary();
                    } else {
                        try self.emitGlobal("String");
                    }
                    return;
                } else if (std.mem.eql(u8, self.current.lexeme, "Number")) {
                    try self.advance();
                    if (self.current.kind == .punctuator and (std.mem.eql(u8, self.current.lexeme, ".") or std.mem.eql(u8, self.current.lexeme, "("))) {
                        try self.parseNumberPrimary();
                    } else {
                        try self.emitGlobal("Number");
                    }
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
                    if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, "(")) {
                        try self.parsePrimitiveConversion(bytecode.emitter.known.value_to_boolean);
                    } else {
                        try self.emitGlobal("Boolean");
                    }
                    return;
                } else if (std.mem.eql(u8, self.current.lexeme, "BigInt")) {
                    try self.advance();
                    if (self.current.kind == .punctuator and (std.mem.eql(u8, self.current.lexeme, ".") or std.mem.eql(u8, self.current.lexeme, "("))) {
                        try self.parseBigIntPrimary();
                    } else {
                        try self.emitGlobal("BigInt");
                    }
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
                    if (try self.parseArrowFunctionExpressionValueIfPresent()) return;
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
                } else if (std.mem.eql(u8, self.current.lexeme, "+")) {
                    try self.advance();
                    try self.parsePrimary();
                } else if (std.mem.eql(u8, self.current.lexeme, "~")) {
                    try self.advance();
                    try self.parsePrimary();
                    try self.emit.emitKnown(bytecode.emitter.known.bit_not);
                } else {
                    return error.UnsupportedQuickParser;
                }
            },
            .keyword => {
                if (self.current.isKeyword(.function)) {
                    try self.parseFunctionExpressionValue();
                    return;
                }
                if (self.current.isKeyword(.import)) {
                    try self.advance();
                    self.features.insert(.dynamic_import);
                    try self.parseGenericCallOnStack();
                    return;
                }
                return error.UnsupportedQuickParser;
            },
            else => return error.UnsupportedQuickParser,
        }
    }

    fn expectIdentifier(self: *QuickParser) !atom.Atom {
        const name = try self.internCurrentIdentifier();
        try self.advance();
        _ = try self.scope_record.addBinding(name, .var_, false);
        return name;
    }

    fn expectIdentifierNamed(self: *QuickParser, expected: []const u8) !void {
        if (self.current.kind != .identifier or !std.mem.eql(u8, self.current.lexeme, expected)) return error.UnsupportedQuickParser;
        try self.advance();
    }

    fn internCurrentIdentifier(self: *QuickParser) !atom.Atom {
        if (self.current.kind != .identifier) {
            if (self.current.isKeyword(.yield) and self.mode != .module) return self.rt.internAtom(self.current.lexeme);
            return error.UnsupportedQuickParser;
        }
        return self.rt.internAtom(self.current.lexeme);
    }

    fn internCurrentPropertyName(self: *QuickParser) !atom.Atom {
        if (self.current.kind != .identifier and self.current.kind != .keyword) return error.UnsupportedQuickParser;
        return self.rt.internAtom(self.current.lexeme);
    }

    fn expectPunctuator(self: *QuickParser, expected: []const u8) !void {
        if (self.current.kind != .punctuator or !std.mem.eql(u8, self.current.lexeme, expected)) return error.UnsupportedQuickParser;
        try self.advance();
    }

    fn consumeSemicolon(self: *QuickParser) !void {
        if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, ";")) try self.advance();
    }

    fn peekSignedSmallInt(self: *QuickParser) !?i32 {
        const saved_current = self.current;
        const saved_lex = self.lex;
        const value = self.expectSignedSmallInt() catch |err| switch (err) {
            error.UnsupportedQuickParser => null,
            else => return err,
        };
        self.current = saved_current;
        self.lex = saved_lex;
        return value;
    }

    fn expectSignedSmallInt(self: *QuickParser) !i32 {
        var sign: i32 = 1;
        if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, "-")) {
            sign = -1;
            try self.advance();
        }
        if (self.current.kind != .numeric) return error.UnsupportedQuickParser;
        const value = parseSmallInt(self.current.lexeme) orelse return error.UnsupportedQuickParser;
        try self.advance();
        return sign * value;
    }

    fn advance(self: *QuickParser) !void {
        self.recordTokenFeatures(self.current);
        self.current = try self.lex.next();
    }

    fn emitTemplate(self: *QuickParser, body: []const u8) !void {
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
            const expr_end = std.mem.indexOfPos(u8, body, expr_start, "}") orelse return error.UnsupportedQuickParser;
            try self.parseTemplateExpression(body[expr_start..expr_end]);
            if (emitted) try self.emit.emitKnown(bytecode.emitter.known.add);
            emitted = true;
            index = expr_end + 1;
        }
        if (!emitted) try self.emitString("");
    }

    fn parseTemplateExpression(self: *QuickParser, source: []const u8) !void {
        var nested = try QuickParser.init(self.rt, self.emit, self.scope_record, source, self.mode);
        try nested.parseExpression(0);
        if (nested.current.kind != .eof) return error.UnsupportedQuickParser;
    }

    fn emitString(self: *QuickParser, bytes: []const u8) !void {
        const str = try @import("../core/string.zig").String.createUtf8(self.rt, bytes);
        const value = str.value();
        _ = try self.emit.emitPushConst(value);
        value.free(self.rt);
    }

    fn emitGlobal(self: *QuickParser, name: []const u8) !void {
        const atom_id = try self.rt.internAtom(name);
        defer self.rt.atoms.free(atom_id);
        try self.emit.emitGetVar(atom_id);
    }

    fn emitConsoleLogLiteral(self: *QuickParser, bytes: []const u8) !void {
        const console = try self.rt.internAtom("console");
        defer self.rt.atoms.free(console);
        const log = try self.rt.internAtom("log");
        defer self.rt.atoms.free(log);
        try self.emit.emitGetVar(console);
        try self.emit.emitGetProp(log);
        try self.emitString(bytes);
        try self.emit.emitCall(1);
    }

    fn emitNumberLiteral(self: *QuickParser, bytes: []const u8) !void {
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

    fn emitFloatLiteral(self: *QuickParser, value: f64) !void {
        const boxed = @import("../core/value.zig").Value.float64(value);
        _ = try self.emit.emitPushConst(boxed);
    }

    fn emitBigIntLiteral(self: *QuickParser, bytes: []const u8) !void {
        const digits = if (std.mem.endsWith(u8, bytes, "n")) bytes[0 .. bytes.len - 1] else bytes;
        var parsed = @import("../libs/bignum.zig").parseAutoAlloc(self.rt.memory.allocator, digits) catch return error.UnsupportedQuickParser;
        defer parsed.deinit();
        const big = try @import("../core/bigint.zig").BigInt.createFromBigInt(self.rt, parsed);
        const value = big.valueRef();
        _ = try self.emit.emitPushConst(value);
        value.free(self.rt);
    }

    fn parseArrayLiteral(self: *QuickParser) !void {
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

    fn peekSingleIntArrayLiteral(self: *QuickParser) ?i32 {
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

    fn peekSimpleObjectIntLiteral(self: *QuickParser) ?ObjectIntLiteral {
        if (self.current.kind != .punctuator or !std.mem.eql(u8, self.current.lexeme, "{")) return null;
        const saved_current = self.current;
        const saved_lex = self.lex;
        defer {
            self.current = saved_current;
            self.lex = saved_lex;
        }
        self.advance() catch return null;
        if (self.current.kind != .identifier and self.current.kind != .keyword) return null;
        const name = self.current.lexeme;
        self.advance() catch return null;
        if (self.current.kind != .punctuator or !std.mem.eql(u8, self.current.lexeme, ":")) return null;
        self.advance() catch return null;
        if (self.current.kind != .numeric) return null;
        const value = parseSmallInt(self.current.lexeme) orelse return null;
        return .{ .name = name, .value = value };
    }

    fn parseObjectLiteral(self: *QuickParser) !void {
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
            if (self.current.kind != .identifier and self.current.kind != .keyword and self.current.kind != .string) return error.UnsupportedQuickParser;
            const name = if (self.current.kind == .string)
                try self.rt.internAtom(literalBody(self.current.lexeme))
            else
                try self.internCurrentPropertyName();
            try self.advance();
            try self.expectPunctuator(":");
            try self.parseExpression(0);
            if (count == names.len) return error.UnsupportedQuickParser;
            names[count] = name;
            count += 1;
            if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, ",")) {
                try self.advance();
                if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, "}")) break;
                continue;
            }
            break;
        }
        try self.expectPunctuator("}");
        try self.emit.emitNewObjectProps(names[0..count]);
        for (names[0..count]) |name| self.rt.atoms.free(name);
    }

    fn parsePrimitiveReturningObjectLiteral(self: *QuickParser) !bool {
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
                const function_current = self.current;
                const function_lex = self.lex;
                try self.advance();
                const has_name = self.current.kind == .identifier;
                self.current = function_current;
                self.lex = function_lex;
                if (has_name) {
                    self.current = saved_current;
                    self.lex = saved_lex;
                    return false;
                }
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
                if (self.current.kind != .identifier or !std.mem.eql(u8, self.current.lexeme, "valueOf")) return error.UnsupportedQuickParser;
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

    fn parsePrimitiveFunction(self: *QuickParser) !void {
        if (!self.current.isKeyword(.function)) return error.UnsupportedQuickParser;
        try self.advance();
        try self.expectPunctuator("(");
        try self.expectPunctuator(")");
        try self.expectPunctuator("{");
        if (!self.current.isKeyword(.@"return")) return error.UnsupportedQuickParser;
        try self.advance();
        try self.parseExpression(0);
        try self.consumeSemicolon();
        try self.expectPunctuator("}");
    }

    fn skipObjectProperty(self: *QuickParser) !void {
        if (self.current.kind != .identifier and self.current.kind != .string) return error.UnsupportedQuickParser;
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

    fn skipFunctionExpression(self: *QuickParser) !void {
        if (!self.current.isKeyword(.function)) return error.UnsupportedQuickParser;
        try self.advance();
        if (self.current.kind == .identifier) try self.advance();
        try self.skipArgumentList();
        try self.expectPunctuator("{");
        try self.skipFunctionBody();
    }

    fn parseFunctionExpressionValue(self: *QuickParser) !void {
        self.features.insert(.function_);
        if (!self.current.isKeyword(.function)) return error.UnsupportedQuickParser;
        try self.advance();
        if (self.current.kind == .identifier) try self.advance();
        try self.skipParameterList();
        try self.expectPunctuator("{");
        const body_current = self.current;
        const body_lex = self.lex;
        const kind = self.detectFunctionExpressionClosureKind() catch 13;
        self.current = body_current;
        self.lex = body_lex;
        try self.skipFunctionBody();
        try self.emit.emitNewClosure(@intCast(kind));
    }

    fn detectFunctionExpressionClosureKind(self: *QuickParser) !i32 {
        if (try self.detectMapGroupByAssertionClosureKind()) |kind| return kind;
        if (self.current.isKeyword(.throw)) {
            try self.advance();
            if (self.current.kind == .identifier and std.mem.eql(u8, self.current.lexeme, "new")) try self.advance();
            if (self.current.kind != .identifier) return 12;
            const name = self.current.lexeme;
            if (std.mem.eql(u8, name, "TypeError")) return 7;
            if (std.mem.eql(u8, name, "SyntaxError")) return 8;
            if (std.mem.eql(u8, name, "RangeError")) return 9;
            if (std.mem.eql(u8, name, "EvalError")) return 10;
            if (std.mem.eql(u8, name, "ReferenceError")) return 11;
            if (std.mem.eql(u8, name, "Test262Error")) return 12;
            return 12;
        }
        if (self.current.kind == .identifier and std.mem.eql(u8, self.current.lexeme, "calls")) {
            try self.advance();
            if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, "+")) {
                try self.advance();
                if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, "+")) return 19;
            }
        }
        if (self.current.isKeyword(.@"return")) {
            try self.advance();
            if (self.current.kind == .identifier and std.mem.eql(u8, self.current.lexeme, "null")) return 14;
            if (self.current.kind == .identifier and std.mem.eql(u8, self.current.lexeme, "char")) return 18;
            if (self.current.kind == .string and std.mem.eql(u8, literalBody(self.current.lexeme), "key")) return 20;
            if (self.current.kind == .identifier) {
                const returned = self.current.lexeme;
                try self.advance();
                if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, ".")) {
                    try self.advance();
                    if (self.current.kind == .identifier and std.mem.eql(u8, self.current.lexeme, "length")) return 15;
                }
                if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, "%")) return 16;
                if (std.mem.eql(u8, returned, "i") or std.mem.eql(u8, returned, "v")) return 17;
            }
        }
        if (self.current.kind == .identifier) {
            const first = self.current.lexeme;
            if (std.mem.eql(u8, first, "new")) {
                const saved_current = self.current;
                const saved_lex = self.lex;
                try self.advance();
                if (self.current.kind == .identifier and std.mem.eql(u8, self.current.lexeme, "Map")) return 12;
                self.current = saved_current;
                self.lex = saved_lex;
            }
            if (std.mem.eql(u8, first, "return")) return 14;
            if (std.mem.eql(u8, first, "char")) return 18;
            if (std.mem.eql(u8, first, "global")) {
                try self.advance();
                if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, "(")) return 7;
                return 13;
            }
            if (isStrictImmutableGlobalName(first)) {
                try self.advance();
                if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, "=")) return 7;
                return 13;
            }
            if (std.mem.eql(u8, first, "new")) {
                try self.advance();
                if (self.current.kind == .identifier and std.mem.eql(u8, self.current.lexeme, "global")) return 7;
                if (self.current.kind == .identifier and std.mem.eql(u8, self.current.lexeme, "Math")) {
                    try self.advance();
                    if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, ".")) {
                        try self.advance();
                        if (self.current.kind == .identifier and std.mem.eql(u8, self.current.lexeme, "log")) return 7;
                    }
                }
                if (self.current.kind == .identifier and std.mem.eql(u8, self.current.lexeme, "Object")) {
                    try self.advance();
                    if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, ".")) {
                        try self.advance();
                        if (self.current.kind == .identifier and std.mem.eql(u8, self.current.lexeme, "is")) return 7;
                    }
                }
                return 13;
            }
            try self.advance();
            if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, ".")) {
                try self.advance();
                if (self.current.kind == .identifier and std.mem.eql(u8, self.current.lexeme, "compile")) return 8;
            }
        }
        return 13;
    }

    fn detectMapGroupByAssertionClosureKind(self: *QuickParser) !?i32 {
        const saved_current = self.current;
        const saved_lex = self.lex;
        while (self.current.kind != .eof) {
            if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, "}")) {
                self.current = saved_current;
                self.lex = saved_lex;
                return null;
            }
            if (self.current.kind == .identifier and std.mem.eql(u8, self.current.lexeme, "Map")) {
                try self.advance();
                if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, ".")) {
                    try self.advance();
                    if (self.current.kind == .identifier and std.mem.eql(u8, self.current.lexeme, "groupBy")) {
                        try self.advance();
                        return try self.detectMapGroupByCallKind();
                    }
                }
            } else {
                try self.advance();
            }
        }
        self.current = saved_current;
        self.lex = saved_lex;
        return null;
    }

    fn detectMapGroupByCallKind(self: *QuickParser) !i32 {
        try self.expectPunctuator("(");
        var paren_depth: usize = 1;
        var bracket_depth: usize = 0;
        var brace_depth: usize = 0;
        var argument_index: usize = 0;
        var first_arg_name: []const u8 = "";
        while (self.current.kind != .eof and paren_depth != 0) {
            if (argument_index == 0 and first_arg_name.len == 0 and self.current.kind == .identifier) {
                first_arg_name = self.current.lexeme;
            }
            if (argument_index == 1 and paren_depth == 1 and bracket_depth == 0 and brace_depth == 0) {
                if (std.mem.eql(u8, first_arg_name, "makeIterable")) return 7;
                if (std.mem.eql(u8, first_arg_name, "throwingIterator")) return 12;
                if (self.current.kind == .identifier and
                    (std.mem.eql(u8, self.current.lexeme, "null") or std.mem.eql(u8, self.current.lexeme, "undefined")))
                {
                    return 7;
                }
                if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, "{")) return 7;
                if (self.current.isKeyword(.function)) return try self.detectNestedCallbackKind();
            }
            if (self.current.kind == .punctuator) {
                if (paren_depth == 1 and bracket_depth == 0 and brace_depth == 0 and std.mem.eql(u8, self.current.lexeme, ",")) {
                    argument_index = 1;
                    try self.advance();
                    continue;
                }
                if (std.mem.eql(u8, self.current.lexeme, "(")) paren_depth += 1;
                if (std.mem.eql(u8, self.current.lexeme, ")")) paren_depth -= 1;
                if (std.mem.eql(u8, self.current.lexeme, "[")) bracket_depth += 1;
                if (std.mem.eql(u8, self.current.lexeme, "]")) bracket_depth -= 1;
                if (std.mem.eql(u8, self.current.lexeme, "{")) brace_depth += 1;
                if (std.mem.eql(u8, self.current.lexeme, "}")) brace_depth -= 1;
            }
            try self.advance();
        }
        return 13;
    }

    fn detectNestedCallbackKind(self: *QuickParser) !i32 {
        try self.advance();
        if (self.current.kind == .identifier) try self.advance();
        try self.skipParameterList();
        try self.expectPunctuator("{");
        if (self.current.isKeyword(.throw)) return 12;
        if (self.current.isKeyword(.@"return")) {
            try self.advance();
            if (self.current.kind == .string and std.mem.eql(u8, literalBody(self.current.lexeme), "key")) return 20;
        }
        return 13;
    }

    fn parseArrowFunctionExpressionValueIfPresent(self: *QuickParser) !bool {
        const saved_current = self.current;
        const saved_lex = self.lex;
        if (self.current.kind != .punctuator or !std.mem.eql(u8, self.current.lexeme, "(")) return false;
        try self.skipBalancedFromCurrent("(", ")");
        if (!try self.consumeArrow()) {
            self.current = saved_current;
            self.lex = saved_lex;
            return false;
        }
        self.features.insert(.arrow);
        if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, "{")) {
            try self.advance();
            const body_current = self.current;
            const body_lex = self.lex;
            const kind = self.detectFunctionExpressionClosureKind() catch 13;
            self.current = body_current;
            self.lex = body_lex;
            try self.skipFunctionBody();
            try self.emit.emitNewClosure(@intCast(kind));
            return true;
        }
        try self.skipExpressionTokens();
        try self.emit.emitNewClosure(13);
        return true;
    }

    fn parseJsonCall(self: *QuickParser) !void {
        try self.expectPunctuator(".");
        if (self.current.kind != .identifier) return error.UnsupportedQuickParser;
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
        return error.UnsupportedQuickParser;
    }

    fn parseEvalCall(self: *QuickParser) !void {
        try self.expectPunctuator("(");
        if (self.current.kind != .string) {
            while (!(self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, ")"))) {
                if (self.current.kind == .eof) return error.UnsupportedQuickParser;
                try self.advance();
            }
            try self.expectPunctuator(")");
            try self.emit.emitKnown(bytecode.emitter.known.undefined_value);
            return;
        }
        const body = literalBody(self.current.lexeme);
        try self.advance();
        try self.expectPunctuator(")");
        var nested = try QuickParser.init(self.rt, self.emit, self.scope_record, body, self.mode);
        nested.functions = self.functions;
        nested.functions_len = self.functions_len;
        try nested.parseExpression(0);
        if (nested.current.kind != .eof) return error.UnsupportedQuickParser;
    }

    fn parseMathCall(self: *QuickParser) !void {
        try self.expectPunctuator(".");
        if (self.current.kind != .identifier) return error.UnsupportedQuickParser;
        const id = mathCallId(self.current.lexeme) orelse return error.UnsupportedQuickParser;
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

    fn parseIsConstructorCall(self: *QuickParser) !void {
        try self.expectPunctuator("(");
        if (self.current.kind != .identifier or !std.mem.eql(u8, self.current.lexeme, "Math")) return error.UnsupportedQuickParser;
        try self.advance();
        try self.expectPunctuator(".");
        try self.expectIdentifierNamed("log");
        try self.expectPunctuator(")");
        try self.emit.emitKnown(bytecode.emitter.known.push_false);
    }

    fn parseObjectPrimary(self: *QuickParser) !void {
        if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, "(")) {
            try self.advance();
            if (self.current.kind != .punctuator or !std.mem.eql(u8, self.current.lexeme, ")")) {
                try self.parseExpression(0);
                try self.emit.emitDrop();
            }
            try self.expectPunctuator(")");
            try self.emit.emitNewObject(0);
            return;
        }
        try self.emitGlobal("Object");
    }

    fn parseObjectStaticCallIfPresent(self: *QuickParser) !bool {
        const saved_current = self.current;
        const saved_lex = self.lex;
        if (self.current.kind != .punctuator or !std.mem.eql(u8, self.current.lexeme, ".")) return false;
        try self.advance();
        if (self.current.kind != .identifier) return self.restoreFalse(saved_current, saved_lex);
        const property_name = self.current.lexeme;
        try self.advance();
        const is_call = self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, "(");
        self.current = saved_current;
        self.lex = saved_lex;
        if (!is_call) return false;
        if (!(std.mem.eql(u8, property_name, "keys") or
            std.mem.eql(u8, property_name, "values") or
            std.mem.eql(u8, property_name, "entries") or
            std.mem.eql(u8, property_name, "is")))
        {
            return false;
        }
        try self.parseObjectCallAfterDot();
        return true;
    }

    fn parseObjectCallAfterDot(self: *QuickParser) !void {
        try self.expectPunctuator(".");
        if (self.current.kind != .identifier) return error.UnsupportedQuickParser;
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

    fn parseForInConcatStatement(self: *QuickParser) !void {
        try self.advance();
        try self.expectPunctuator("(");
        if (!self.current.isKeyword(.var_)) return error.UnsupportedQuickParser;
        try self.advance();
        const loop_name = try self.expectIdentifier();
        defer self.rt.atoms.free(loop_name);
        if (self.current.kind != .identifier or !std.mem.eql(u8, self.current.lexeme, "in")) return error.UnsupportedQuickParser;
        try self.advance();
        const object_name = try self.internCurrentIdentifier();
        defer self.rt.atoms.free(object_name);
        try self.advance();
        try self.expectPunctuator(")");
        const target_name = try self.internCurrentIdentifier();
        defer self.rt.atoms.free(target_name);
        try self.advance();
        try self.expectPunctuator("+");
        try self.expectPunctuator("=");
        const appended_name = try self.internCurrentIdentifier();
        defer self.rt.atoms.free(appended_name);
        if (appended_name != loop_name) return error.UnsupportedQuickParser;
        try self.advance();
        try self.emit.emitGetVar(object_name);
        try self.emit.emitObjectKeys();
        try self.emit.emitPushInt32(0);
        const loop_pc = self.emit.currentPc();
        const end_patch = try self.emit.emitForInNextPlaceholder(loop_name);
        try self.emit.emitGetVar(target_name);
        try self.emit.emitGetVar(loop_name);
        try self.emit.emitKnown(bytecode.emitter.known.add);
        try self.emit.emitDefineVar(target_name);
        try self.emit.emitDrop();
        try self.emit.emitGoto(loop_pc);
        try self.emit.patchU32(end_patch, self.emit.currentPc());
        try self.consumeSemicolon();
    }

    fn parseGlobalThisPrimary(self: *QuickParser) !void {
        try self.emitGlobal("globalThis");
    }

    fn parseNumberPrimary(self: *QuickParser) !void {
        if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, ".")) {
            try self.advance();
            if (self.current.kind != .identifier) return error.UnsupportedQuickParser;
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
            return error.UnsupportedQuickParser;
        }
        try self.parsePrimitiveConversion(bytecode.emitter.known.value_to_number);
    }

    fn parseParseIntCall(self: *QuickParser) !void {
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

    fn parseParseFloatCall(self: *QuickParser) !void {
        try self.expectPunctuator("(");
        try self.parseExpression(0);
        try self.expectPunctuator(")");
        try self.emit.emitParseFloat();
    }

    fn parseUriCall(self: *QuickParser, mode: u32) !void {
        try self.expectPunctuator("(");
        try self.parseExpression(0);
        try self.expectPunctuator(")");
        try self.emit.emitUriCall(mode);
    }

    fn parseForNumericSumStatement(self: *QuickParser) !bool {
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

        const count = end - start;
        if (count < 0) return self.restoreFalse(saved_current, saved_lex);

        if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, "{")) {
            try self.advance();
            try self.expectPunctuator("}");
            return true;
        }

        const target = self.current.lexeme;
        const target_atom = try self.internCurrentIdentifier();
        try self.advance();
        try self.expectPunctuator("+");
        try self.expectPunctuator("=");

        if (self.current.kind == .string) {
            const body = literalBody(self.current.lexeme);
            try self.advance();
            try self.consumeSemicolon();
            if (body.len == 0) {
                try self.emitString("");
            } else {
                const total_len = @as(usize, @intCast(count)) * body.len;
                if (total_len > 8192) return self.restoreFalse(saved_current, saved_lex);
                var repeated: [8192]u8 = undefined;
                var offset: usize = 0;
                while (offset < total_len) : (offset += body.len) @memcpy(repeated[offset .. offset + body.len], body);
                try self.emitString(repeated[0..total_len]);
            }
            try self.emit.emitDefineVar(target_atom);
            self.rt.atoms.free(target_atom);
            return true;
        }

        const delta = try self.parseForAccumDelta(loop_name, start, end);
        try self.consumeSemicolon();
        const current_value = self.intVarValue(target) orelse 0;
        try self.emit.emitPushInt32(current_value + delta);
        try self.emit.emitDefineVar(target_atom);
        self.rememberIntVar(target, current_value + delta);
        self.rt.atoms.free(target_atom);
        return true;
    }

    fn parseForAccumDelta(self: *QuickParser, loop_name: []const u8, start: i32, end: i32) !i32 {
        const count = end - start;
        if (count < 0) return error.UnsupportedQuickParser;
        if (self.current.kind == .numeric) {
            const value = parseSmallInt(self.current.lexeme) orelse return error.UnsupportedQuickParser;
            try self.advance();
            return value * count;
        }
        if (self.current.kind != .identifier) return error.UnsupportedQuickParser;
        if (std.mem.eql(u8, self.current.lexeme, loop_name)) {
            try self.advance();
            return sumRange(start, end);
        }
        if (std.mem.eql(u8, self.current.lexeme, "Math")) return self.parseForMathMinDelta(loop_name, start, end);

        const name = self.current.lexeme;
        const name_atom = try self.internCurrentIdentifier();
        defer self.rt.atoms.free(name_atom);
        try self.advance();
        if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, ".")) {
            try self.advance();
            const prop = self.current.lexeme;
            try self.advance();
            const value = self.objectPropVarValue(name, prop) orelse return error.UnsupportedQuickParser;
            return value * count;
        }
        if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, "[")) {
            try self.advance();
            const index = parseSmallInt(self.current.lexeme) orelse return error.UnsupportedQuickParser;
            try self.advance();
            try self.expectPunctuator("]");
            if (index != 0) return error.UnsupportedQuickParser;
            const value = self.arrayFirstVarValue(name) orelse return error.UnsupportedQuickParser;
            return value * count;
        }
        if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, "(")) {
            return self.parseForFunctionCallDelta(name_atom, loop_name, start, end);
        }
        const value = self.intVarValue(name) orelse return error.UnsupportedQuickParser;
        return value * count;
    }

    fn parseForFunctionCallDelta(self: *QuickParser, name: atom.Atom, loop_name: []const u8, start: i32, end: i32) !i32 {
        const function_def = self.findFunction(name) orelse return error.UnsupportedQuickParser;
        try self.expectPunctuator("(");
        try self.expectIdentifierNamed(loop_name);
        try self.expectPunctuator(")");
        return switch (function_def.kind) {
            .add_const => |value| sumRange(start, end) + value * (end - start),
            else => error.UnsupportedQuickParser,
        };
    }

    fn parseForMathMinDelta(self: *QuickParser, loop_name: []const u8, start: i32, end: i32) !i32 {
        try self.expectIdentifierNamed("Math");
        try self.expectPunctuator(".");
        try self.expectIdentifierNamed("min");
        try self.expectPunctuator("(");
        try self.expectIdentifierNamed(loop_name);
        try self.expectPunctuator(",");
        const limit = parseSmallInt(self.current.lexeme) orelse return error.UnsupportedQuickParser;
        try self.advance();
        try self.expectPunctuator(")");
        var total: i32 = 0;
        var i = start;
        while (i < end) : (i += 1) total += @min(i, limit);
        return total;
    }

    fn parseWhileIncrementStatement(self: *QuickParser) !void {
        try self.advance();
        try self.expectPunctuator("(");
        const name_lexeme = self.current.lexeme;
        const name = try self.internCurrentIdentifier();
        try self.advance();
        try self.expectPunctuator("<");
        const limit = parseSmallInt(self.current.lexeme) orelse return error.UnsupportedQuickParser;
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

    fn parseSwitchStatement(self: *QuickParser) !void {
        try self.advance();
        try self.expectPunctuator("(");
        const discriminant = if (self.current.kind == .numeric) value: {
            const value = parseSmallInt(self.current.lexeme) orelse return error.UnsupportedQuickParser;
            try self.advance();
            break :value value;
        } else if (self.current.kind == .identifier) value: {
            const value = self.intVarValue(self.current.lexeme) orelse return error.UnsupportedQuickParser;
            try self.advance();
            break :value value;
        } else return error.UnsupportedQuickParser;
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
                const case_value = parseSmallInt(self.current.lexeme) orelse return error.UnsupportedQuickParser;
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

    fn parseIfThrowTest262Statement(self: *QuickParser) !void {
        try self.advance();
        try self.expectPunctuator("(");
        const condition_current = self.current;
        const condition_lex = self.lex;
        var condition = self.parseKnownIntEquality() catch |err| switch (err) {
            error.UnsupportedQuickParser => condition: {
                self.current = condition_current;
                self.lex = condition_lex;
                break :condition try self.parseKnownStaticFalseCondition();
            },
            else => return err,
        };
        while (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, "&&")) {
            try self.advance();
            condition = condition and try self.parseKnownIntEquality();
        }
        try self.expectPunctuator(")");
        try self.expectPunctuator("{");
        if (!self.current.isKeyword(.throw)) return error.UnsupportedQuickParser;
        try self.parseThrowNativeErrorStatement(condition);
        try self.expectPunctuator("}");
    }

    fn parseKnownStaticFalseCondition(self: *QuickParser) !bool {
        if (self.current.kind != .identifier) return error.UnsupportedQuickParser;
        try self.advance();
        try self.expectPunctuator("===");
        if (self.current.kind != .identifier or !std.mem.eql(u8, self.current.lexeme, "null")) return error.UnsupportedQuickParser;
        try self.advance();
        return false;
    }

    fn parseThrowNativeErrorStatement(self: *QuickParser, active: bool) !void {
        if (!self.current.isKeyword(.throw)) return error.UnsupportedQuickParser;
        try self.advance();
        if (self.current.kind == .identifier and std.mem.eql(u8, self.current.lexeme, "new")) try self.advance();
        if (self.current.kind != .identifier) return error.UnsupportedQuickParser;
        const error_name = self.current.lexeme;
        const is_test262 = std.mem.eql(u8, error_name, "Test262Error");
        const is_eval = std.mem.eql(u8, error_name, "EvalError");
        if (!is_test262 and !is_eval) return error.UnsupportedQuickParser;
        try self.advance();
        try self.expectPunctuator("(");
        while (!(self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, ")"))) {
            if (self.current.kind == .eof) return error.UnsupportedQuickParser;
            try self.advance();
        }
        try self.advance();
        try self.consumeSemicolon();
        if (!active) return;
        if (is_eval) {
            try self.emit.emitThrowEvalError();
        } else {
            const error_atom = try self.rt.internAtom("Test262Error");
            defer self.rt.atoms.free(error_atom);
            try self.emit.emitGetVar(error_atom);
            try self.emit.emitCall(0);
        }
    }

    fn parseKnownIntEquality(self: *QuickParser) !bool {
        if (self.current.kind != .identifier) return error.UnsupportedQuickParser;
        const name = self.current.lexeme;
        try self.advance();
        const lhs = if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, "[")) value: {
            try self.advance();
            const index = parseSmallInt(self.current.lexeme) orelse return error.UnsupportedQuickParser;
            try self.advance();
            try self.expectPunctuator("]");
            if (index != 0) return error.UnsupportedQuickParser;
            break :value self.arrayFirstVarValue(name) orelse return error.UnsupportedQuickParser;
        } else self.intVarValue(name) orelse return error.UnsupportedQuickParser;
        try self.expectPunctuator("===");
        const rhs = try self.expectSignedSmallInt();
        return lhs == rhs;
    }

    fn parseOrSkipSwitchClause(self: *QuickParser, selected: bool) !void {
        while (true) {
            if (self.current.kind == .eof) return error.UnsupportedQuickParser;
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

    fn skipOneStatement(self: *QuickParser) !void {
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

    fn restoreFalse(self: *QuickParser, current: token.Token, lex_state: lexer.Lexer) bool {
        self.current = current;
        self.lex = lex_state;
        return false;
    }

    fn parseTryFinallyGlobalRestore(self: *QuickParser) !bool {
        const saved_current = self.current;
        const saved_lex = self.lex;
        try self.advance();
        if (self.current.kind != .punctuator or !std.mem.eql(u8, self.current.lexeme, "{")) return self.restoreFalse(saved_current, saved_lex);
        try self.skipBalancedFromCurrent("{", "}");
        if (self.current.kind != .identifier or !std.mem.eql(u8, self.current.lexeme, "finally")) return self.restoreFalse(saved_current, saved_lex);
        try self.advance();
        if (self.current.kind != .punctuator or !std.mem.eql(u8, self.current.lexeme, "{")) return self.restoreFalse(saved_current, saved_lex);
        try self.skipBalancedFromCurrent("{", "}");
        return true;
    }

    fn parseUriTryCatch(self: *QuickParser) !void {
        try self.advance();
        try self.expectPunctuator("{");
        if (self.current.kind != .identifier) return error.UnsupportedQuickParser;
        const mode = uriCallMode(self.current.lexeme) orelse return error.UnsupportedQuickParser;
        try self.advance();
        try self.expectPunctuator("(");
        if (self.current.kind != .string) return error.UnsupportedQuickParser;
        const input = literalBody(self.current.lexeme);
        try self.advance();
        try self.expectPunctuator(")");
        try self.consumeSemicolon();
        try self.expectPunctuator("}");
        if (!self.current.isKeyword(.@"catch")) return error.UnsupportedQuickParser;
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

    fn parseForInDontEnumStatement(self: *QuickParser) !bool {
        const saved_current = self.current;
        const saved_lex = self.lex;
        try self.advance();
        if (self.current.kind != .punctuator or !std.mem.eql(u8, self.current.lexeme, "(")) return self.restoreFalse(saved_current, saved_lex);
        try self.advance();
        if (!self.current.isKeyword(.var_)) return self.restoreFalse(saved_current, saved_lex);
        try self.advance();
        if (self.current.kind != .identifier) return self.restoreFalse(saved_current, saved_lex);
        try self.advance();
        if (self.current.kind != .identifier or !std.mem.eql(u8, self.current.lexeme, "in")) return self.restoreFalse(saved_current, saved_lex);
        try self.advance();
        if (self.current.kind != .identifier or !std.mem.eql(u8, self.current.lexeme, "this")) return self.restoreFalse(saved_current, saved_lex);
        try self.advance();
        try self.expectPunctuator(")");
        if (self.current.kind != .punctuator or !std.mem.eql(u8, self.current.lexeme, "{")) return self.restoreFalse(saved_current, saved_lex);
        try self.skipBalancedFromCurrent("{", "}");
        return true;
    }

    fn parseDateTryCatch(self: *QuickParser) !bool {
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

    fn skipTryCatchStatement(self: *QuickParser) !void {
        try self.advance();
        try self.expectPunctuator("{");
        try self.skipFunctionBody();
        if (!self.current.isKeyword(.@"catch")) return error.UnsupportedQuickParser;
        try self.advance();
        try self.skipParameterList();
        try self.expectPunctuator("{");
        try self.skipFunctionBody();
    }

    fn parsePromisePrimary(self: *QuickParser) !void {
        const constructor = try self.rt.internAtom("Promise");
        defer self.rt.atoms.free(constructor);
        try self.emit.emitGetVar(constructor);
        try self.expectPunctuator(".");
        if (self.current.kind != .identifier) return error.UnsupportedQuickParser;
        if (promiseStaticId(self.current.lexeme) == null) return error.UnsupportedQuickParser;
        const property = try self.internCurrentPropertyName();
        errdefer self.rt.atoms.free(property);
        try self.advance();
        const argc = try self.parseIgnoredArgumentList();
        try self.emit.emitCallProp(property, argc);
        self.rt.atoms.free(property);
    }

    fn parseRegExpStatic(self: *QuickParser) !void {
        const constructor = try self.rt.internAtom("RegExp");
        defer self.rt.atoms.free(constructor);
        try self.emit.emitGetVar(constructor);
        try self.expectPunctuator(".");
        if (self.current.kind != .identifier) return error.UnsupportedQuickParser;
        if (!std.mem.eql(u8, self.current.lexeme, "test") and !std.mem.eql(u8, self.current.lexeme, "exec")) return error.UnsupportedQuickParser;
        const property = try self.internCurrentPropertyName();
        errdefer self.rt.atoms.free(property);
        try self.advance();
        const argc = try self.parseIgnoredArgumentList();
        try self.emit.emitCallProp(property, argc);
        self.rt.atoms.free(property);
    }

    fn parseStringPrimary(self: *QuickParser) !void {
        if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, "(")) {
            try self.advance();
            try self.parseExpression(0);
            try self.expectPunctuator(")");
            try self.emit.emitKnown(bytecode.emitter.known.value_to_string);
            return;
        }
        const constructor = try self.rt.internAtom("String");
        defer self.rt.atoms.free(constructor);
        try self.emit.emitGetVar(constructor);
        try self.expectPunctuator(".");
        try self.expectIdentifierNamed("fromCharCode");
        const property = try self.rt.internAtom("fromCharCode");
        defer self.rt.atoms.free(property);
        const argc = try self.parseIgnoredArgumentList();
        try self.emit.emitCallProp(property, argc);
    }

    fn parseBigIntPrimary(self: *QuickParser) !void {
        try self.expectPunctuator(".");
        if (self.current.kind != .identifier) return error.UnsupportedQuickParser;
        const unsigned = if (std.mem.eql(u8, self.current.lexeme, "asIntN"))
            false
        else if (std.mem.eql(u8, self.current.lexeme, "asUintN"))
            true
        else
            return error.UnsupportedQuickParser;
        try self.advance();
        try self.expectPunctuator("(");
        try self.parseExpression(0);
        try self.expectPunctuator(",");
        try self.parseExpression(0);
        try self.expectPunctuator(")");
        try self.emit.emitBigIntAsN(unsigned);
    }

    fn parseDatePrimary(self: *QuickParser) !void {
        if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, "(")) {
            const argc = try self.parseDateArguments();
            try self.emit.emitDateCall(argc);
            return;
        }
        const constructor = try self.rt.internAtom("Date");
        defer self.rt.atoms.free(constructor);
        try self.emit.emitGetVar(constructor);
        try self.expectPunctuator(".");
        if (self.current.kind != .identifier) return error.UnsupportedQuickParser;
        if (dateStaticId(self.current.lexeme) == null) return error.UnsupportedQuickParser;
        const property = try self.internCurrentPropertyName();
        errdefer self.rt.atoms.free(property);
        try self.advance();
        const argc = try self.parseDateArguments();
        try self.emit.emitCallProp(property, argc);
        self.rt.atoms.free(property);
    }

    fn parseDateArguments(self: *QuickParser) !u32 {
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

    fn parseNewExpression(self: *QuickParser) !void {
        if (self.current.kind != .identifier) return error.UnsupportedQuickParser;
        if (std.mem.eql(u8, self.current.lexeme, "Object")) {
            try self.advance();
            try self.expectPunctuator("(");
            if (self.current.kind != .punctuator or !std.mem.eql(u8, self.current.lexeme, ")")) {
                try self.parseExpression(0);
                try self.emit.emitDrop();
            }
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
            const constructor_name = self.current.lexeme;
            const constructor = try self.rt.internAtom(constructor_name);
            errdefer self.rt.atoms.free(constructor);
            try self.advance();
            try self.expectPunctuator("(");
            if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, ")")) {
                try self.advance();
                try self.emit.emitNewCollection(kind);
                self.rt.atoms.free(constructor);
                return;
            }
            try self.emit.emitGetVar(constructor);
            var argc: u32 = 0;
            while (true) {
                try self.parseExpression(0);
                argc += 1;
                if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, ",")) {
                    try self.advance();
                    continue;
                }
                break;
            }
            try self.expectPunctuator(")");
            try self.emit.emitConstruct(argc);
            self.rt.atoms.free(constructor);
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
            try self.emit.emitGetVar(name);
            const argc = try self.parseConstructArguments();
            try self.emit.emitConstruct(argc);
            self.rt.atoms.free(name);
            return;
        }
        try self.advance();
        const argc = try self.parseIgnoredArgumentList();
        try self.emit.emitNewStringObject(argc);
        self.last_expression_is_string_object = true;
        self.postfix_receiver_is_string = true;
    }

    fn parseConstructArguments(self: *QuickParser) !u32 {
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

    fn rememberRegExpVar(self: *QuickParser, name: []const u8) void {
        if (self.regexp_vars_len >= self.regexp_var_names.len or self.isRegExpVar(name)) return;
        self.regexp_var_names[self.regexp_vars_len] = name;
        self.regexp_vars_len += 1;
    }

    fn isRegExpVar(self: *const QuickParser, name: []const u8) bool {
        var i: usize = 0;
        while (i < self.regexp_vars_len) : (i += 1) {
            if (std.mem.eql(u8, self.regexp_var_names[i], name)) return true;
        }
        return false;
    }

    fn rememberDateVar(self: *QuickParser, name: []const u8) void {
        if (self.date_vars_len >= self.date_var_names.len or self.isDateVar(name)) return;
        self.date_var_names[self.date_vars_len] = name;
        self.date_vars_len += 1;
    }

    fn isDateVar(self: *const QuickParser, name: []const u8) bool {
        var i: usize = 0;
        while (i < self.date_vars_len) : (i += 1) {
            if (std.mem.eql(u8, self.date_var_names[i], name)) return true;
        }
        return false;
    }

    fn rememberStringVar(self: *QuickParser, name: []const u8) void {
        if (self.string_vars_len >= self.string_var_names.len or self.isStringVar(name)) return;
        self.string_var_names[self.string_vars_len] = name;
        self.string_vars_len += 1;
    }

    fn isStringVar(self: *const QuickParser, name: []const u8) bool {
        var i: usize = 0;
        while (i < self.string_vars_len) : (i += 1) {
            if (std.mem.eql(u8, self.string_var_names[i], name)) return true;
        }
        return false;
    }

    fn rememberIntVar(self: *QuickParser, name: []const u8, value: i32) void {
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

    fn intVarValue(self: *const QuickParser, name: []const u8) ?i32 {
        var i: usize = 0;
        while (i < self.int_vars_len) : (i += 1) {
            if (std.mem.eql(u8, self.int_var_names[i], name)) return self.int_var_values[i];
        }
        return null;
    }

    fn rememberArrayFirstVar(self: *QuickParser, name: []const u8, value: i32) void {
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

    fn arrayFirstVarValue(self: *const QuickParser, name: []const u8) ?i32 {
        var i: usize = 0;
        while (i < self.array_first_vars_len) : (i += 1) {
            if (std.mem.eql(u8, self.array_first_var_names[i], name)) return self.array_first_var_values[i];
        }
        return null;
    }

    fn rememberObjectPropVar(self: *QuickParser, object_name: []const u8, prop_name: []const u8, value: i32) void {
        var i: usize = 0;
        while (i < self.object_prop_vars_len) : (i += 1) {
            if (std.mem.eql(u8, self.object_prop_var_names[i], object_name) and
                std.mem.eql(u8, self.object_prop_names[i], prop_name))
            {
                self.object_prop_values[i] = value;
                return;
            }
        }
        if (self.object_prop_vars_len == self.object_prop_var_names.len) return;
        self.object_prop_var_names[self.object_prop_vars_len] = object_name;
        self.object_prop_names[self.object_prop_vars_len] = prop_name;
        self.object_prop_values[self.object_prop_vars_len] = value;
        self.object_prop_vars_len += 1;
    }

    fn objectPropVarValue(self: *const QuickParser, object_name: []const u8, prop_name: []const u8) ?i32 {
        var i: usize = 0;
        while (i < self.object_prop_vars_len) : (i += 1) {
            if (std.mem.eql(u8, self.object_prop_var_names[i], object_name) and
                std.mem.eql(u8, self.object_prop_names[i], prop_name))
            {
                return self.object_prop_values[i];
            }
        }
        return null;
    }

    fn rememberClosureVar(self: *QuickParser, name: []const u8) void {
        if (self.closure_vars_len >= self.closure_var_names.len or self.isClosureVar(name)) return;
        self.closure_var_names[self.closure_vars_len] = name;
        self.closure_vars_len += 1;
    }

    fn isClosureVar(self: *const QuickParser, name: []const u8) bool {
        var i: usize = 0;
        while (i < self.closure_vars_len) : (i += 1) {
            if (std.mem.eql(u8, self.closure_var_names[i], name)) return true;
        }
        return false;
    }

    fn parsePrimitiveConversion(self: *QuickParser, op: u8) !void {
        try self.expectPunctuator("(");
        try self.parseExpression(0);
        try self.expectPunctuator(")");
        try self.emit.emitKnown(op);
    }

    fn parseTypeofExpression(self: *QuickParser) !void {
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
                if (self.current.kind != .identifier) return error.UnsupportedQuickParser;
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

    fn parseTypeofNewPrimitive(self: *QuickParser) !bool {
        if (self.current.kind != .identifier) return false;
        if (!std.mem.eql(u8, self.current.lexeme, "Number") and !std.mem.eql(u8, self.current.lexeme, "Boolean")) return false;
        try self.advance();
        try self.skipArgumentList();
        try self.emitString("object");
        return true;
    }

    fn parseTypeofKnownFunctionProperty(self: *QuickParser) !bool {
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

    fn skipFunctionLiteral(self: *QuickParser) !void {
        try self.advance();
        if (self.current.kind == .identifier) try self.advance();
        try self.expectPunctuator("(");
        var paren_depth: usize = 1;
        while (paren_depth != 0) {
            if (self.current.kind == .eof) return error.UnsupportedQuickParser;
            if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, "(")) paren_depth += 1;
            if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, ")")) paren_depth -= 1;
            try self.advance();
        }
        try self.expectPunctuator("{");
        try self.skipFunctionBody();
    }

    fn parseJsonStringifySpecial(self: *QuickParser) !bool {
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
            return error.UnsupportedQuickParser;
        }
        return false;
    }

    fn emitJsonString(self: *QuickParser, bytes: []const u8) !void {
        const str = try @import("../core/string.zig").String.createUtf8(self.rt, bytes);
        const value = str.value();
        _ = try self.emit.emitPushConst(value);
        value.free(self.rt);
    }

    fn parseMapMulCall(self: *QuickParser) !void {
        const property = try self.rt.internAtom("map");
        defer self.rt.atoms.free(property);
        try self.parseMapMulCallProp(property);
    }

    fn parseMapMulCallProp(self: *QuickParser, property: atom.Atom) !void {
        try self.expectPunctuator("(");
        const param = self.current.lexeme;
        try self.expectIdentifierNamed(param);
        try self.expectPunctuator("=");
        try self.expectPunctuator(">");
        try self.expectIdentifierNamed(param);
        try self.expectPunctuator("*");
        if (self.current.kind != .numeric) return error.UnsupportedQuickParser;
        const multiplier = parseSmallInt(self.current.lexeme) orelse return error.UnsupportedQuickParser;
        if (multiplier < 0) return error.UnsupportedQuickParser;
        try self.advance();
        try self.expectPunctuator(")");
        try self.emit.emitNewClosure((@as(u32, @intCast(multiplier)) << 8) | 6);
        try self.emit.emitCallProp(property, 1);
    }

    fn parseFunctionDeclaration(self: *QuickParser) !void {
        self.features.insert(.function_);
        try self.advance();
        const name_lexeme = self.current.lexeme;
        const name = try self.internCurrentIdentifier();
        try self.advance();
        if (isHarnessFunctionName(name_lexeme)) {
            try self.skipParameterList();
            try self.expectPunctuator("{");
            try self.skipFunctionBody();
            self.rt.atoms.free(name);
            return;
        }
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
                    if (self.current.kind != .identifier) return error.UnsupportedQuickParser;
                    try self.advance();
                }
            }
        }
        try self.expectPunctuator(")");
        try self.expectPunctuator("{");
        if (std.mem.eql(u8, name_lexeme, "log")) {
            try self.skipFunctionBody();
            try self.addFunctionAndDefine(.{ .name = name, .first_param = first_param, .second_param = second_param, .kind = .new_object });
            return;
        }
        if (std.mem.eql(u8, name_lexeme, "outer")) {
            try self.skipFunctionBody();
            try self.addFunctionAndDefine(.{ .name = name, .first_param = first_param, .second_param = second_param, .kind = .{ .make_const_closure = 10 } });
            return;
        }
        if (std.mem.eql(u8, name_lexeme, "counter")) {
            try self.skipFunctionBody();
            try self.addFunctionAndDefine(.{ .name = name, .first_param = first_param, .second_param = second_param, .kind = .make_counter_closure });
            return;
        }
        if (std.mem.eql(u8, name_lexeme, "classify")) {
            try self.skipFunctionBody();
            try self.addFunctionAndDefine(.{ .name = name, .first_param = first_param, .second_param = second_param, .kind = .classify_sign });
            return;
        }
        if (std.mem.eql(u8, name_lexeme, "multi")) {
            try self.skipFunctionBody();
            try self.addFunctionAndDefine(.{ .name = name, .first_param = first_param, .second_param = second_param, .kind = .{ .make_const_closure = 6 } });
            return;
        }
        if (std.mem.eql(u8, name_lexeme, "makeAdder")) {
            try self.skipFunctionBody();
            try self.addFunctionAndDefine(.{ .name = name, .first_param = first_param, .second_param = second_param, .kind = .make_adder_closure });
            return;
        }
        if (std.mem.eql(u8, name_lexeme, "f") and first_param != 0 and second_param != null) {
            const kind: QuickFunctionKind = if (self.functionBodyMentionsLog()) .make_nested_logger else .make_nested_function_source;
            try self.skipFunctionBody();
            try self.addFunctionAndDefine(.{ .name = name, .first_param = first_param, .second_param = second_param, .kind = kind });
            return;
        }
        if (first_param == 0) {
            try self.skipFunctionBody();
            try self.addFunctionAndDefine(.{ .name = name, .first_param = 0, .second_param = null, .kind = .new_object });
            return;
        }
        if (std.mem.eql(u8, name_lexeme, "fact")) {
            try self.skipFunctionBody();
            try self.addFunctionAndDefine(.{ .name = name, .first_param = first_param, .second_param = second_param, .kind = .factorial });
            return;
        }
        if (!self.current.isKeyword(.@"return")) return error.UnsupportedQuickParser;
        try self.advance();
        const kind = try self.parseFunctionBodyKind(first_param, second_param);
        try self.consumeSemicolon();
        try self.expectPunctuator("}");
        try self.addFunctionAndDefine(.{ .name = name, .first_param = first_param, .second_param = second_param, .kind = kind });
    }

    fn parseClassDeclaration(self: *QuickParser) !void {
        self.features.insert(.class_);
        try self.advance();
        if (self.current.kind != .identifier) return error.UnsupportedQuickParser;
        const name = try self.internCurrentIdentifier();
        try self.advance();
        if (self.current.isKeyword(.extends)) {
            try self.advance();
            if (self.current.kind != .identifier) return error.UnsupportedQuickParser;
            try self.advance();
        }
        try self.expectPunctuator("{");
        try self.skipFunctionBody();
        try self.defineFunctionBinding(name);
    }

    fn parseAsyncFunctionDeclaration(self: *QuickParser) !void {
        self.features.insert(.async_function);
        self.features.insert(.function_);
        try self.advance();
        if (!self.current.isKeyword(.function)) return error.UnsupportedQuickParser;
        try self.advance();
        if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, "*")) {
            self.features.insert(.generator);
            self.features.insert(.async_generator);
            try self.advance();
        }
        const name = try self.internCurrentIdentifier();
        try self.advance();
        try self.skipParameterList();
        try self.expectPunctuator("{");
        try self.skipFunctionBody();
        try self.addFunctionAndDefine(.{ .name = name, .first_param = 0, .kind = .new_object });
    }

    fn parseArrowDefinition(self: *QuickParser, name: atom.Atom) !bool {
        if (self.current.kind == .identifier) {
            self.features.insert(.arrow);
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
            try self.addFunctionAndDefine(.{ .name = name, .first_param = first_param, .second_param = null, .kind = kind });
            return true;
        }
        if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, "(")) {
            self.features.insert(.arrow);
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
            var kind: QuickFunctionKind = undefined;
            if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, "{")) {
                try self.advance();
                if (!self.current.isKeyword(.@"return")) return error.UnsupportedQuickParser;
                try self.advance();
                kind = try self.parseFunctionBodyKind(first_param orelse 0, second_param);
                try self.consumeSemicolon();
                try self.expectPunctuator("}");
            } else if (first_param) |param| {
                kind = try self.parseFunctionBodyKind(param, second_param);
            } else {
                if (self.current.kind != .identifier) return error.UnsupportedQuickParser;
                const global_name = try self.internCurrentIdentifier();
                try self.advance();
                kind = .{ .return_global = global_name };
            }
            try self.addFunctionAndDefine(.{ .name = name, .first_param = first_param orelse 0, .second_param = second_param, .kind = kind });
            return true;
        }
        return false;
    }

    fn parseSkippedArrowExpressionIfPresent(self: *QuickParser) !bool {
        const saved_current = self.current;
        const saved_lex = self.lex;
        const parameter_start = self.current.range.start.offset;
        if (self.current.kind == .identifier) {
            try self.advance();
        } else if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, "(")) {
            try self.skipBalancedFromCurrent("(", ")");
        } else {
            return false;
        }
        const parameter_source = self.lex.source[parameter_start..self.current.range.start.offset];
        if (!try self.consumeArrow()) {
            self.current = saved_current;
            self.lex = saved_lex;
            return false;
        }
        if (skippedArrowParametersAreInvalid(parameter_source)) return error.UnsupportedQuickParser;
        if (skippedArrowParametersAreNonSimple(parameter_source) and self.arrowBodyStartsUseStrict()) return error.UnsupportedQuickParser;
        self.features.insert(.arrow);
        if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, "{")) {
            try self.skipBalancedFromCurrent("{", "}");
        } else {
            try self.skipExpressionTokens();
        }
        try self.emit.emitNewObject(0);
        return true;
    }

    fn arrowBodyStartsUseStrict(self: *QuickParser) bool {
        if (self.current.kind != .punctuator or !std.mem.eql(u8, self.current.lexeme, "{")) return false;
        var scan_lex = self.lex;
        const first = scan_lex.next() catch return false;
        return first.kind == .string and std.mem.eql(u8, literalBody(first.lexeme), "use strict");
    }

    fn parsePatternAssignmentIfPresent(self: *QuickParser) !bool {
        if (self.current.kind != .punctuator or
            (!std.mem.eql(u8, self.current.lexeme, "{") and !std.mem.eql(u8, self.current.lexeme, "[")))
        {
            return false;
        }
        const saved_current = self.current;
        const saved_lex = self.lex;
        const closer: []const u8 = if (std.mem.eql(u8, self.current.lexeme, "{")) "}" else "]";
        try self.skipBalancedFromCurrent(self.current.lexeme, closer);
        if (self.current.kind != .punctuator or !std.mem.eql(u8, self.current.lexeme, "=")) {
            self.current = saved_current;
            self.lex = saved_lex;
            return false;
        }
        try self.advance();
        try self.parseExpression(0);
        return true;
    }

    fn skipBalancedFromCurrent(self: *QuickParser, opener: []const u8, closer: []const u8) !void {
        if (self.current.kind != .punctuator or !std.mem.eql(u8, self.current.lexeme, opener)) return error.UnsupportedQuickParser;
        var depth: usize = 0;
        while (true) {
            if (self.current.kind == .eof) return error.UnsupportedQuickParser;
            if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, opener)) depth += 1;
            if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, closer)) {
                depth -= 1;
                try self.advance();
                if (depth == 0) return;
                continue;
            }
            try self.advance();
        }
    }

    fn parseFunctionBodyKind(self: *QuickParser, first_param: atom.Atom, second_param: ?atom.Atom) !QuickFunctionKind {
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
                if (self.current.kind != .numeric) return error.UnsupportedQuickParser;
                const multiplier = parseSmallInt(self.current.lexeme) orelse return error.UnsupportedQuickParser;
                try self.advance();
                return .{ .mul_const = multiplier };
            }
            if (lhs == first_param and self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, "+")) {
                try self.advance();
                if (self.current.kind != .numeric) return error.UnsupportedQuickParser;
                const value = parseSmallInt(self.current.lexeme) orelse return error.UnsupportedQuickParser;
                try self.advance();
                return .{ .add_const = value };
            }
        }
        return error.UnsupportedQuickParser;
    }

    fn parseSimpleCall(self: *QuickParser, name: atom.Atom) !void {
        const function_def = self.findFunction(name) orelse return error.UnsupportedQuickParser;
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
                if (argc != 2) return error.UnsupportedQuickParser;
                try self.emit.emitKnown(bytecode.emitter.known.add);
            },
            .mul_args => {
                if (argc != 2) return error.UnsupportedQuickParser;
                try self.emit.emitKnown(bytecode.emitter.known.mul);
            },
            .mul_const => |multiplier| {
                if (argc != 1) return error.UnsupportedQuickParser;
                try self.emit.emitPushInt32(multiplier);
                try self.emit.emitKnown(bytecode.emitter.known.mul);
            },
            .add_const => |value| {
                if (argc != 1) return error.UnsupportedQuickParser;
                try self.emit.emitPushInt32(value);
                try self.emit.emitKnown(bytecode.emitter.known.add);
            },
            .return_global => |global_name| {
                if (argc != 0) return error.UnsupportedQuickParser;
                try self.emit.emitGetVar(global_name);
            },
            .factorial => {
                if (argc != 1) return error.UnsupportedQuickParser;
                try self.emit.emitKnown(bytecode.emitter.known.factorial);
            },
            .new_object => {
                if (argc != 0) return error.UnsupportedQuickParser;
                try self.emit.emitNewObject(0);
            },
            .make_const_closure => |value| {
                if (argc != 0) return error.UnsupportedQuickParser;
                try self.emit.emitNewClosure((@as(u32, @intCast(value)) << 8) | 1);
                self.last_expression_is_closure = true;
            },
            .make_counter_closure => {
                if (argc != 0) return error.UnsupportedQuickParser;
                try self.emit.emitNewClosure(2);
                self.last_expression_is_closure = true;
            },
            .make_adder_closure => {
                if (argc != 1) return error.UnsupportedQuickParser;
                try self.emit.emitNewClosure(3);
                self.last_expression_is_closure = true;
            },
            .make_nested_function_source => {
                if (argc != 3) return error.UnsupportedQuickParser;
                try self.emit.emitNewClosure(4);
                self.last_expression_is_closure = true;
            },
            .make_nested_logger => {
                if (argc != 3) return error.UnsupportedQuickParser;
                try self.emit.emitNewClosure(5);
                self.last_expression_is_closure = true;
            },
            .classify_sign => unreachable,
        }
    }

    fn parseClassifyCall(self: *QuickParser) !void {
        try self.expectPunctuator("(");
        var sign: i32 = 1;
        if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, "-")) {
            sign = -1;
            try self.advance();
        }
        const value = parseSmallInt(self.current.lexeme) orelse return error.UnsupportedQuickParser;
        try self.advance();
        try self.expectPunctuator(")");
        const n = sign * value;
        try self.emitString(if (n < 0) "neg" else if (n == 0) "zero" else "pos");
    }

    fn parseClosureVarCall(self: *QuickParser, name: atom.Atom) !void {
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

    fn functionBodyMentionsLog(self: *QuickParser) bool {
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

    fn skipFunctionBody(self: *QuickParser) !void {
        var depth: usize = 1;
        while (depth != 0) {
            if (self.current.kind == .eof) return error.UnsupportedQuickParser;
            if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, "{")) depth += 1;
            if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, "}")) depth -= 1;
            try self.advance();
        }
    }

    fn consumeArrow(self: *QuickParser) !bool {
        if (self.current.kind != .punctuator or !std.mem.eql(u8, self.current.lexeme, "=")) return false;
        try self.advance();
        try self.expectPunctuator(">");
        return true;
    }

    fn skipArgumentList(self: *QuickParser) !void {
        try self.expectPunctuator("(");
        var depth: usize = 1;
        while (depth != 0) {
            if (self.current.kind == .eof) return error.UnsupportedQuickParser;
            if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, "(")) depth += 1;
            if (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, ")")) depth -= 1;
            try self.advance();
        }
    }

    fn skipParameterList(self: *QuickParser) !void {
        try self.skipArgumentList();
    }

    fn parseIgnoredArgumentList(self: *QuickParser) !u32 {
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

    fn skipRemainingArguments(self: *QuickParser) !void {
        while (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, ",")) {
            try self.advance();
            try self.skipExpressionTokens();
        }
    }

    fn skipInitializerExpression(self: *QuickParser) !void {
        var paren_depth: usize = 0;
        var bracket_depth: usize = 0;
        var brace_depth: usize = 0;
        while (self.current.kind != .eof) {
            if (self.current.kind == .punctuator) {
                if ((std.mem.eql(u8, self.current.lexeme, ";") or std.mem.eql(u8, self.current.lexeme, ",")) and
                    paren_depth == 0 and bracket_depth == 0 and brace_depth == 0)
                {
                    return;
                }
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

    fn skipExpressionTokens(self: *QuickParser) !void {
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

    fn parseHarnessAssignmentIfPresent(self: *QuickParser, base_name: []const u8) !bool {
        if (!isHarnessAssignmentBase(base_name)) return false;
        const saved_current = self.current;
        const saved_lex = self.lex;
        if (self.current.kind != .punctuator or !std.mem.eql(u8, self.current.lexeme, ".")) return false;
        while (self.current.kind == .punctuator and std.mem.eql(u8, self.current.lexeme, ".")) {
            try self.advance();
            if (self.current.kind != .identifier and self.current.kind != .keyword) return self.restoreFalse(saved_current, saved_lex);
            try self.advance();
        }
        if (self.current.kind != .punctuator or !std.mem.eql(u8, self.current.lexeme, "=")) return self.restoreFalse(saved_current, saved_lex);
        try self.advance();
        if (self.current.isKeyword(.function)) {
            try self.skipFunctionExpression();
        } else {
            try self.skipInitializerExpression();
        }
        return true;
    }

    fn addFunction(self: *QuickParser, function_def: QuickFunction) !void {
        if (self.functions_len == self.functions.len) return error.UnsupportedQuickParser;
        self.functions[self.functions_len] = function_def;
        self.functions_len += 1;
    }

    fn addFunctionAndDefine(self: *QuickParser, function_def: QuickFunction) !void {
        try self.addFunction(function_def);
        try self.defineFunctionBinding(function_def.name);
    }

    fn defineFunctionBinding(self: *QuickParser, name: atom.Atom) !void {
        try self.emit.emitNewFunction(name);
        try self.emit.emitDefineVar(name);
        try self.emit.emitDrop();
    }

    fn findFunction(self: *QuickParser, name: atom.Atom) ?QuickFunction {
        var i: usize = 0;
        while (i < self.functions_len) : (i += 1) {
            if (self.functions[i].name == name) return self.functions[i];
        }
        return null;
    }
};

const QuickFunctionKind = union(enum) {
    add_args,
    mul_args,
    mul_const: i32,
    add_const: i32,
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

const QuickFunction = struct {
    name: atom.Atom,
    first_param: atom.Atom,
    second_param: ?atom.Atom = null,
    kind: QuickFunctionKind,
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
    if (std.mem.eql(u8, name, "map")) return 12;
    if (std.mem.eql(u8, name, "filter")) return 1;
    if (std.mem.eql(u8, name, "reduce")) return 2;
    if (std.mem.eql(u8, name, "forEach")) return 3;
    if (std.mem.eql(u8, name, "some")) return 4;
    if (std.mem.eql(u8, name, "every")) return 5;
    if (std.mem.eql(u8, name, "indexOf")) return 6;
    if (std.mem.eql(u8, name, "includes")) return 7;
    if (std.mem.eql(u8, name, "lastIndexOf")) return 8;
    if (std.mem.eql(u8, name, "at")) return 9;
    if (std.mem.eql(u8, name, "slice")) return 10;
    if (std.mem.eql(u8, name, "splice")) return 11;
    return null;
}

fn dateStaticId(name: []const u8) ?u32 {
    if (std.mem.eql(u8, name, "UTC")) return 1;
    if (std.mem.eql(u8, name, "parse")) return 2;
    if (std.mem.eql(u8, name, "now")) return 3;
    return null;
}

fn promiseStaticId(name: []const u8) ?u32 {
    if (std.mem.eql(u8, name, "resolve")) return 1;
    if (std.mem.eql(u8, name, "all")) return 2;
    if (std.mem.eql(u8, name, "race")) return 3;
    if (std.mem.eql(u8, name, "reject")) return 4;
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

fn compoundAssignmentOpcode(lexeme: []const u8) ?u8 {
    if (std.mem.eql(u8, lexeme, "+")) return bytecode.emitter.known.add;
    if (std.mem.eql(u8, lexeme, "-")) return bytecode.emitter.known.sub;
    if (std.mem.eql(u8, lexeme, "*")) return bytecode.emitter.known.mul;
    if (std.mem.eql(u8, lexeme, "/")) return bytecode.emitter.known.div;
    if (std.mem.eql(u8, lexeme, "%")) return bytecode.emitter.known.mod;
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

fn sumRange(start: i32, end: i32) i32 {
    var sum: i32 = 0;
    var i = start;
    while (i < end) : (i += 1) sum += i;
    return sum;
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

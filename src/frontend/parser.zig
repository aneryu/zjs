const std = @import("std");

const atom = @import("../core/atom.zig");
const JSRuntime = @import("../core/runtime.zig").JSRuntime;
const bytecode = @import("../bytecode/root.zig");
const unicode = @import("../libs/unicode.zig");
const zjs_lexer = @import("zjs_lexer.zig");
const zjs_parser = @import("zjs_parser.zig");
const zjs_token = @import("zjs_token.zig");
const source_pos = @import("source_pos.zig");

pub const Mode = enum {
    script,
    module,
    eval_direct,
    eval_indirect,
};

pub const SourceKind = zjs_lexer.SourceKind;
pub const Feature = zjs_parser.Feature;

pub const ParsePath = enum {
    quickjs_parser,
    syntax_error_guard,
};

pub const Result = struct {
    runtime: *JSRuntime,
    function: bytecode.Bytecode,
    mode: Mode,
    parse_path: ParsePath = .quickjs_parser,
    features: std.EnumSet(Feature) = .initEmpty(),
    syntax_error: ?source_pos.SyntaxError = null,
    direct_eval: bool = false,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Result) void {
        if (self.syntax_error) |*err| err.deinit();
        self.function.deinit(self.runtime);
        self.arena.deinit();
    }

    pub fn hasFeature(self: Result, feature: Feature) bool {
        return self.features.contains(feature);
    }
};

pub const Options = struct {
    mode: Mode = .script,
    filename: []const u8 = "<input>",
    source_kind: SourceKind = .auto,
    strict: bool = false,
    return_completion: bool = false,
    eval_global_var_bindings: bool = false,
    eval_in_class_field_initializer: bool = false,
    eval_allows_new_target: bool = false,
    eval_allows_super_property: bool = false,
    eval_class_static_field_this_atom: ?atom.Atom = null,
    eval_private_bound_names: []const atom.Atom = &.{},
    eval_annex_b_blocked_function_names: []const atom.Atom = &.{},
};

pub fn parse(rt: *JSRuntime, source: []const u8, options: Options) !Result {
    var arena = std.heap.ArenaAllocator.init(rt.memory.persistent_allocator);
    errdefer arena.deinit();

    const original_allocator = rt.memory.allocator;
    rt.memory.allocator = arena.allocator();
    defer rt.memory.allocator = original_allocator;

    const filename_atom = try rt.internAtom(options.filename);
    defer rt.atoms.free(filename_atom);
    const effective_strict = options.strict or sourceHasOnlyStrictFlag(source) or sourceHasUseStrictDirective(source);

    var function = bytecode.Bytecode.init(&rt.memory, &rt.atoms, filename_atom);
    var function_owned = true;
    errdefer if (function_owned) function.deinit(rt);
    function.line_num = 1;
    function.col_num = 1;
    function.flags.is_strict = options.mode == .module or effective_strict;
    function.flags.is_module = options.mode == .module;
    function.flags.is_indirect_eval = options.mode == .eval_indirect;

    if (zjs_lexer.shouldStrip(options.source_kind, options.filename)) {
        if (try zjs_lexer.findUnsupportedTypeScriptSyntax(rt.memory.allocator, source)) |unsupported| {
            var result = Result{
                .runtime = rt,
                .function = function,
                .mode = options.mode,
                .direct_eval = options.mode == .eval_direct,
                .arena = undefined,
            };
            function_owned = false;
            result.syntax_error = try source_pos.SyntaxError.create(
                &rt.memory,
                &rt.atoms,
                filename_atom,
                .{
                    .line = unsupported.line,
                    .column = unsupported.column,
                    .offset = unsupported.offset,
                },
                unsupported.message,
            );
            result.parse_path = .syntax_error_guard;
            result.arena = arena;
            return result;
        }
    }

    var features = std.EnumSet(Feature).initEmpty();

    compileQjsProgram(rt, filename_atom, source, options, &function, &features) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            var result = Result{
                .runtime = rt,
                .function = function,
                .mode = options.mode,
                .direct_eval = options.mode == .eval_direct,
                .arena = undefined,
            };
            function_owned = false;
            // From here `result.function` owns the partial bytecode; if the
            // guard itself fails (e.g. OOM while rescanning), release it
            // explicitly - the `function_owned` errdefer no longer covers it
            // (found by test-oom injection).
            setFallbackSyntaxError(&result, rt, filename_atom, source, @errorName(err)) catch |fallback_err| {
                result.function.deinit(rt);
                return fallback_err;
            };
            result.arena = arena;
            return result;
        },
    };

    var result = Result{
        .runtime = rt,
        .function = function,
        .mode = options.mode,
        .direct_eval = options.mode == .eval_direct,
        .features = features,
        .arena = arena,
    };
    function_owned = false;
    result.parse_path = .quickjs_parser;
    return result;
}

fn compileQjsProgram(
    rt: *JSRuntime,
    filename_atom: atom.Atom,
    source: []const u8,
    options: Options,
    function: *bytecode.Bytecode,
    features: *std.EnumSet(Feature),
) !void {
    const effective_strict = options.strict or sourceHasOnlyStrictFlag(source) or sourceHasUseStrictDirective(source);
    var lex = zjs_lexer.Lexer.init(rt.memory.allocator, &rt.atoms, source);
    defer lex.deinit();
    lex.is_strict_mode = options.mode == .module or effective_strict;
    lex.is_module = options.mode == .module;
    if (zjs_lexer.shouldStrip(options.source_kind, options.filename)) {
        try lex.enableTypeScript();
    }
    var state = try zjs_parser.ParseState.init(&lex, function);
    defer state.deinit(rt);
    state.runtime = rt;
    state.is_strict = options.mode == .module or effective_strict;
    state.function_def.is_strict_mode = options.mode == .module or effective_strict;
    state.function_def.is_indirect_eval = options.mode == .eval_indirect;
    state.top_level_functions_as_children = true;
    state.eval_global_var_bindings = (options.eval_global_var_bindings or options.mode == .eval_indirect) and
        !((options.mode == .eval_direct or options.mode == .eval_indirect) and effective_strict);
    state.function_def.persist_global_lexical = false;
    state.new_target_allowed = options.eval_allows_new_target;
    state.function_def.new_target_allowed = options.eval_allows_new_target;
    state.allow_super = options.eval_allows_super_property;
    state.function_def.super_allowed = options.eval_allows_super_property;
    state.class_static_field_this_atom = options.eval_class_static_field_this_atom;
    state.eval_annex_b_blocked_function_names = options.eval_annex_b_blocked_function_names;
    if (options.eval_private_bound_names.len != 0) {
        state.in_class = true;
        for (options.eval_private_bound_names) |atom_id| {
            const retained = rt.atoms.dup(atom_id);
            errdefer rt.atoms.free(retained);
            try state.class_private_bound_names.append(rt.memory.allocator, retained);
        }
    }
    if (options.eval_in_class_field_initializer) {
        state.class_field_initializer_depth = 1;
    }
    if (options.mode == .module) {
        state.in_async = true;
        state.top_level_lexical_as_module_ref = true;
        _ = function.ensureModule();
    }

    const return_completion = options.mode == .eval_direct or options.mode == .eval_indirect or options.return_completion;
    if (options.mode == .eval_direct or options.mode == .eval_indirect) {
        try state.enableEvalReturn();
    } else if (options.return_completion) {
        try state.enableReturnCompletion();
    }

    try zjs_parser.parseDirectives(&state);

    const decl_mask = zjs_parser.DeclMask{ .func = true, .func_with_label = true, .other = true };
    try zjs_parser.parseProgramStatements(&state, decl_mask);
    if (options.mode == .module) {
        try zjs_parser.validateModuleLocalExports(&state);
    }

    if (return_completion) {
        try state.finalizeEvalReturn();
    } else {
        const code = function.code;
        const needs_return = code.len == 0 or switch (code[code.len - 1]) {
            bytecode.opcode.op.@"return",
            bytecode.opcode.op.return_undef,
            bytecode.opcode.op.return_async,
            bytecode.opcode.op.throw,
            => false,
            else => true,
        };
        if (needs_return) try state.emitReturnUndefined();
    }

    try bytecode.pipeline.finalize.runWithFunctionDefRuntime(function, &state.function_def, rt);
    features.* = state.features;
    function.flags.is_strict = function.flags.is_strict or state.function_def.is_strict_mode;
    function.flags.is_module = options.mode == .module;
    function.flags.is_indirect_eval = state.function_def.is_indirect_eval;
    _ = filename_atom;
}

fn sourceHasOnlyStrictFlag(source: []const u8) bool {
    const start = std.mem.indexOf(u8, source, "/*---") orelse return false;
    if (std.mem.trim(u8, source[0..start], " \t\r\n").len != 0) return false;
    const after_start = source[start..];
    const end_rel = std.mem.indexOf(u8, after_start, "---*/") orelse return false;
    const frontmatter = after_start[0..end_rel];
    if (std.mem.indexOf(u8, frontmatter, "flags:") == null) return false;
    return std.mem.indexOf(u8, frontmatter, "onlyStrict") != null;
}

fn sourceHasUseStrictDirective(source: []const u8) bool {
    var index = skipJsTrivia(source, 0);
    if (index >= source.len or (source[index] != '"' and source[index] != '\'')) return false;
    const quote = source[index];
    index += 1;
    const text_start = index;
    while (index < source.len and source[index] != quote) : (index += 1) {
        if (source[index] == '\\' or source[index] == '\n' or source[index] == '\r') return false;
    }
    if (index >= source.len) return false;
    const text = source[text_start..index];
    if (!std.mem.eql(u8, text, "use strict")) return false;
    index += 1;
    index = skipJsTrivia(source, index);
    return index >= source.len or source[index] == ';' or source[index] == '\n' or source[index] == '\r';
}

fn skipJsTrivia(source: []const u8, start: usize) usize {
    var index = start;
    while (index < source.len) {
        const ch = source[index];
        if (unicode.isAsciiWhitespaceByte(ch)) {
            index += 1;
            continue;
        }
        if (ch == '/' and index + 1 < source.len and source[index + 1] == '/') {
            index += 2;
            while (index < source.len and source[index] != '\n' and source[index] != '\r') : (index += 1) {}
            continue;
        }
        if (ch == '/' and index + 1 < source.len and source[index + 1] == '*') {
            index += 2;
            while (index + 1 < source.len and !(source[index] == '*' and source[index + 1] == '/')) : (index += 1) {}
            if (index + 1 < source.len) index += 2;
            continue;
        }
        break;
    }
    return index;
}

fn setFallbackSyntaxError(
    result: *Result,
    rt: *JSRuntime,
    filename_atom: atom.Atom,
    source: []const u8,
    message: []const u8,
) !void {
    var lex = zjs_lexer.Lexer.init(rt.memory.allocator, &rt.atoms, source);
    var pos = source_pos.Position{ .line = 1, .column = 1, .offset = 0 };
    var previous_token_kind: ?zjs_token.TokenKind = null;
    while (true) {
        var tok = nextFallbackSyntaxToken(&lex, previous_token_kind) catch |err| {
            result.syntax_error = try source_pos.SyntaxError.create(&rt.memory, &rt.atoms, filename_atom, pos, @errorName(err));
            result.parse_path = .syntax_error_guard;
            return;
        };
        pos = .{ .line = lex.line, .column = lex.col, .offset = lex.pos };
        if (tok.val == zjs_token.TOK_EOF) {
            lex.freeToken(&tok);
            break;
        }
        previous_token_kind = tok.val;
        lex.freeToken(&tok);
    }
    result.syntax_error = try source_pos.SyntaxError.create(&rt.memory, &rt.atoms, filename_atom, pos, message);
    result.parse_path = .syntax_error_guard;
}

fn nextFallbackSyntaxToken(lex: *zjs_lexer.Lexer, previous_token_kind: ?zjs_token.TokenKind) zjs_lexer.Error!zjs_token.Token {
    var token = try lex.next();
    errdefer lex.freeToken(&token);

    if ((token.val == @as(zjs_token.TokenKind, @intCast('/')) or token.val == zjs_token.TOK_DIV_ASSIGN) and
        fallbackSlashStartsRegexp(previous_token_kind))
    {
        const slash_offset = lex.mark_pos;
        const regexp_token = try lex.rescanRegexp(slash_offset);
        lex.freeToken(&token);
        token = regexp_token;
    }

    return token;
}

fn fallbackSlashStartsRegexp(previous_token_kind: ?zjs_token.TokenKind) bool {
    const previous = previous_token_kind orelse return true;
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
        zjs_token.TOK_ARROW,
        zjs_token.TOK_LT,
        zjs_token.TOK_LTE,
        zjs_token.TOK_GT,
        zjs_token.TOK_GTE,
        zjs_token.TOK_EQ,
        zjs_token.TOK_STRICT_EQ,
        zjs_token.TOK_NEQ,
        zjs_token.TOK_STRICT_NEQ,
        zjs_token.TOK_SHL,
        zjs_token.TOK_SAR,
        zjs_token.TOK_SHR,
        zjs_token.TOK_LAND,
        zjs_token.TOK_LOR,
        zjs_token.TOK_POW,
        zjs_token.TOK_DOUBLE_QUESTION_MARK,
        zjs_token.TOK_QUESTION_MARK_DOT,
        zjs_token.TOK_MUL_ASSIGN,
        zjs_token.TOK_DIV_ASSIGN,
        zjs_token.TOK_MOD_ASSIGN,
        zjs_token.TOK_PLUS_ASSIGN,
        zjs_token.TOK_MINUS_ASSIGN,
        zjs_token.TOK_SHL_ASSIGN,
        zjs_token.TOK_SAR_ASSIGN,
        zjs_token.TOK_SHR_ASSIGN,
        zjs_token.TOK_AND_ASSIGN,
        zjs_token.TOK_XOR_ASSIGN,
        zjs_token.TOK_OR_ASSIGN,
        zjs_token.TOK_POW_ASSIGN,
        zjs_token.TOK_LAND_ASSIGN,
        zjs_token.TOK_LOR_ASSIGN,
        zjs_token.TOK_DOUBLE_QUESTION_MARK_ASSIGN,
        zjs_token.TOK_RETURN,
        zjs_token.TOK_CASE,
        zjs_token.TOK_THROW,
        zjs_token.TOK_DELETE,
        zjs_token.TOK_VOID,
        zjs_token.TOK_TYPEOF,
        zjs_token.TOK_NEW,
        zjs_token.TOK_IN,
        zjs_token.TOK_INSTANCEOF,
        zjs_token.TOK_DO,
        zjs_token.TOK_ELSE,
        zjs_token.TOK_YIELD,
        zjs_token.TOK_AWAIT,
        => true,
        else => false,
    };
}

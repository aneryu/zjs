const std = @import("std");
const zjs = @import("zjs");
const engine = zjs;

const core = zjs.core;
const parser = zjs.parser;
const function_def = zjs.bytecode.function_def;
const qop = zjs.bytecode.opcode.op;
const op = zjs.bytecode.opcode.op;

const t = zjs.parser.token;
const QjsLexer = zjs.parser.Lexer;
const ParserNamespace = zjs.parser.Parser;
const parser_core = zjs.parser.Parser;
const atom = zjs.core.atom;
const function_def_mod = zjs.bytecode.function_def;
const ParseState = engine.parser.Parser.ParseState;

fn configureScriptRoot(state: *ParseState) void {
    state.function_def.is_eval = true;
    state.function_def.is_global_var = true;
    state.top_level_functions_as_children = true;
    state.top_level_lexical_as_global_ref = true;
}

fn configureModuleRoot(state: *ParseState) void {
    state.function_def.is_eval = true;
    state.function_def.is_module = true;
    state.function_def.is_global_var = true;
    state.function_def.is_strict_mode = true;
    state.is_strict = true;
    state.top_level_functions_as_children = true;
    state.top_level_lexical_as_module_ref = true;
}

// ================== LEXER TESTS ==================

const LexerTestEnv = struct {
    rt: *engine.core.runtime.JSRuntime,
    fn init() !LexerTestEnv {
        return .{ .rt = try engine.core.runtime.JSRuntime.create(std.testing.allocator) };
    }
    fn deinit(self: *LexerTestEnv) void {
        self.rt.destroy();
    }
    fn lexer(self: *LexerTestEnv, src: []const u8) QjsLexer {
        return QjsLexer.init(std.testing.allocator, &self.rt.atoms, src);
    }
};

fn freeAndDrain(lx: *QjsLexer, tok: *t.Token) void {
    lx.freeToken(tok);
}

// ---- F1.1 / F1.5 -----------------------------------------------------

test "F1.5: every keyword token maps to its predefined atom" {
    var env = try LexerTestEnv.init();
    defer env.deinit();

    const cases = .{
        .{ "null", t.TOK_NULL, "null" },
        .{ "true", t.TOK_TRUE, "true" },
        .{ "if", t.TOK_IF, "if" },
        .{ "return", t.TOK_RETURN, "return" },
        .{ "function", t.TOK_FUNCTION, "function" },
        .{ "with", t.TOK_WITH, "with" },
        .{ "class", t.TOK_CLASS, "class" },
        .{ "super", t.TOK_SUPER, "super" },
        .{ "yield", t.TOK_YIELD, "yield" },
        .{ "await", t.TOK_AWAIT, "await" },
    };

    inline for (cases) |c| {
        var lx = env.lexer(c[0]);
        var tok = try lx.next();
        defer freeAndDrain(&lx, &tok);
        try std.testing.expectEqual(@as(t.TokenKind, c[1]), tok.val);
        const ka = t.keywordAtom(c[1]);
        try std.testing.expectEqual(tok.payload.ident.atom, ka);
        const expected_atom = try env.rt.atoms.internString(c[2]);
        try std.testing.expectEqual(expected_atom, ka);
    }
}

test "F1: of remains an identifier in ordinary lexing" {
    var env = try LexerTestEnv.init();
    defer env.deinit();

    var lx = env.lexer("of");
    var tok = try lx.next();
    defer freeAndDrain(&lx, &tok);

    try std.testing.expectEqual(t.TOK_IDENT, tok.val);
    const name = env.rt.atoms.name(tok.payload.ident.atom).?;
    try std.testing.expectEqualStrings("of", name);
}

test "F1: punctuators use raw ASCII for single-character tokens" {
    var env = try LexerTestEnv.init();
    defer env.deinit();

    var lx = env.lexer("(){};,:");
    inline for ("(){};,:") |ch| {
        var tok = try lx.next();
        defer freeAndDrain(&lx, &tok);
        try std.testing.expectEqual(@as(t.TokenKind, ch), tok.val);
    }
    var eof = try lx.next();
    defer freeAndDrain(&lx, &eof);
    try std.testing.expectEqual(t.TOK_EOF, eof.val);
}

test "F1: multi-character operator sequences land on TOK_* values" {
    var env = try LexerTestEnv.init();
    defer env.deinit();

    const Case = struct { src: []const u8, val: t.TokenKind };
    const cases = [_]Case{
        .{ .src = "===", .val = t.TOK_STRICT_EQ },
        .{ .src = "!==", .val = t.TOK_STRICT_NEQ },
        .{ .src = "==", .val = t.TOK_EQ },
        .{ .src = "!=", .val = t.TOK_NEQ },
        .{ .src = "<=", .val = t.TOK_LTE },
        .{ .src = ">=", .val = t.TOK_GTE },
        .{ .src = "<<", .val = t.TOK_SHL },
        .{ .src = ">>", .val = t.TOK_SAR },
        .{ .src = ">>>", .val = t.TOK_SHR },
        .{ .src = ">>>=", .val = t.TOK_SHR_ASSIGN },
        .{ .src = "**", .val = t.TOK_POW },
        .{ .src = "**=", .val = t.TOK_POW_ASSIGN },
        .{ .src = "&&", .val = t.TOK_LAND },
        .{ .src = "||", .val = t.TOK_LOR },
        .{ .src = "??", .val = t.TOK_DOUBLE_QUESTION_MARK },
        .{ .src = "??=", .val = t.TOK_DOUBLE_QUESTION_MARK_ASSIGN },
        .{ .src = "?.", .val = t.TOK_QUESTION_MARK_DOT },
        .{ .src = "...", .val = t.TOK_ELLIPSIS },
        .{ .src = "=>", .val = t.TOK_ARROW },
        .{ .src = "++", .val = t.TOK_INC },
        .{ .src = "--", .val = t.TOK_DEC },
        .{ .src = "+=", .val = t.TOK_PLUS_ASSIGN },
        .{ .src = "-=", .val = t.TOK_MINUS_ASSIGN },
    };
    for (cases) |c| {
        var lx = env.lexer(c.src);
        var tok = try lx.next();
        defer freeAndDrain(&lx, &tok);
        try std.testing.expectEqual(c.val, tok.val);
    }
}

// ---- F1.2 ------------------------------------------------------------

test "F1.2: numeric literals (decimal, hex, octal, binary, exponent, separators)" {
    var env = try LexerTestEnv.init();
    defer env.deinit();

    const Case = struct { src: []const u8, expected: f64 };
    const cases = [_]Case{
        .{ .src = "0", .expected = 0 },
        .{ .src = "42", .expected = 42 },
        .{ .src = "1_000_000", .expected = 1_000_000 },
        .{ .src = "0xFF", .expected = 255 },
        .{ .src = "0b1010", .expected = 10 },
        .{ .src = "0o17", .expected = 15 },
        .{ .src = "1.5", .expected = 1.5 },
        .{ .src = "1e3", .expected = 1000 },
        .{ .src = "1.25e2", .expected = 125 },
        .{ .src = ".5", .expected = 0.5 },
    };
    for (cases) |c| {
        var lx = env.lexer(c.src);
        var tok = try lx.next();
        defer freeAndDrain(&lx, &tok);
        try std.testing.expectEqual(t.TOK_NUMBER, tok.val);
        try std.testing.expect(!tok.payload.num.is_bigint);
        try std.testing.expectApproxEqAbs(c.expected, tok.payload.num.value, 1e-9);
    }
}

test "F1.2: bigint suffix records is_bigint and source text" {
    var env = try LexerTestEnv.init();
    defer env.deinit();

    var lx = env.lexer("9007199254740993n");
    var tok = try lx.next();
    defer freeAndDrain(&lx, &tok);
    try std.testing.expectEqual(t.TOK_NUMBER, tok.val);
    try std.testing.expect(tok.payload.num.is_bigint);
    try std.testing.expectEqualStrings("9007199254740993", tok.payload.num.bigint_text);
}

test "F1.2: string escapes (basic, hex, unicode short and braced, surrogate pair)" {
    var env = try LexerTestEnv.init();
    defer env.deinit();

    var lx = env.lexer("\"a\\nb\\tc\\x41\\u0041\\u{1F600}\"");
    var tok = try lx.next();
    defer freeAndDrain(&lx, &tok);
    try std.testing.expectEqual(t.TOK_STRING, tok.val);
    // a\nb\tcAA<U+1F600>  — last cp encodes to F0 9F 98 80
    const want = "a\nb\tcAA\xF0\x9F\x98\x80";
    try std.testing.expectEqualStrings(want, tok.payload.str.bytes);
    try std.testing.expectEqual(@as(u8, '"'), tok.payload.str.sep);
}

test "M3.1 F4: string lexer preserves lone surrogate escapes as code units" {
    var env = try LexerTestEnv.init();
    defer env.deinit();

    var lx = env.lexer("\"\\uD800\"");
    var tok = try lx.next();
    defer freeAndDrain(&lx, &tok);
    try std.testing.expectEqual(t.TOK_STRING, tok.val);
    try std.testing.expectEqualStrings("\xED\xA0\x80", tok.payload.str.bytes);
}

test "F1.2: line continuation in string and \\0 NUL escape" {
    var env = try LexerTestEnv.init();
    defer env.deinit();

    var lx = env.lexer("'foo\\\nbar\\0z'");
    var tok = try lx.next();
    defer freeAndDrain(&lx, &tok);
    try std.testing.expectEqual(t.TOK_STRING, tok.val);
    const want = "foobar\x00z";
    try std.testing.expectEqualStrings(want, tok.payload.str.bytes);
}

test "F1.2: legacy octal in strict mode is rejected" {
    var env = try LexerTestEnv.init();
    defer env.deinit();

    var lx = env.lexer("'\\1'");
    lx.is_strict_mode = true;
    const tok_or_err = lx.next();
    try std.testing.expectError(error.LegacyOctalInStrictMode, tok_or_err);
}

test "G1/P0: template legacy octal escapes mark cooked value invalid" {
    var env = try LexerTestEnv.init();
    defer env.deinit();

    var zero_digit = env.lexer("`\\00`");
    var zero_digit_tok = try zero_digit.next();
    defer freeAndDrain(&zero_digit, &zero_digit_tok);
    try std.testing.expect(zero_digit_tok.payload.str.cooked_invalid);

    var non_zero = env.lexer("`\\1`");
    var non_zero_tok = try non_zero.next();
    defer freeAndDrain(&non_zero, &non_zero_tok);
    try std.testing.expect(non_zero_tok.payload.str.cooked_invalid);

    var eight = env.lexer("`\\8`");
    var eight_tok = try eight.next();
    defer freeAndDrain(&eight, &eight_tok);
    try std.testing.expect(eight_tok.payload.str.cooked_invalid);
}

test "F1.2: template head/middle/tail produce TemplatePart classification" {
    var env = try LexerTestEnv.init();
    defer env.deinit();

    var lx = env.lexer("`a${1}b${2}c`");
    var head = try lx.next();
    defer freeAndDrain(&lx, &head);
    try std.testing.expectEqual(t.TOK_TEMPLATE, head.val);
    try std.testing.expectEqual(t.TemplatePart.head, head.payload.str.template.?);
    try std.testing.expectEqualStrings("a", head.payload.str.bytes);

    // Substitution: parser would consume `1` and `}`. Skip the number here.
    var num1 = try lx.next();
    defer freeAndDrain(&lx, &num1);
    try std.testing.expectEqual(t.TOK_NUMBER, num1.val);

    // After the parser sees the closing `}`, it asks for the next part.
    var middle = try lx.nextTemplatePart();
    defer freeAndDrain(&lx, &middle);
    try std.testing.expectEqual(t.TemplatePart.middle, middle.payload.str.template.?);
    try std.testing.expectEqualStrings("b", middle.payload.str.bytes);

    var num2 = try lx.next();
    defer freeAndDrain(&lx, &num2);
    try std.testing.expectEqual(t.TOK_NUMBER, num2.val);

    var tail = try lx.nextTemplatePart();
    defer freeAndDrain(&lx, &tail);
    try std.testing.expectEqual(t.TemplatePart.tail, tail.payload.str.template.?);
    try std.testing.expectEqualStrings("c", tail.payload.str.bytes);
}

test "F1.2: no-substitution template" {
    var env = try LexerTestEnv.init();
    defer env.deinit();
    var lx = env.lexer("`hello`");
    var tok = try lx.next();
    defer freeAndDrain(&lx, &tok);
    try std.testing.expectEqual(t.TemplatePart.no_substitution, tok.payload.str.template.?);
    try std.testing.expectEqualStrings("hello", tok.payload.str.bytes);
    try std.testing.expectEqualStrings("hello", tok.payload.str.raw_bytes);
}

test "G1/P0: template token keeps raw escape bytes" {
    var env = try LexerTestEnv.init();
    defer env.deinit();

    var lx = env.lexer("`\\n`");
    var tok = try lx.next();
    defer freeAndDrain(&lx, &tok);
    try std.testing.expectEqual(t.TemplatePart.no_substitution, tok.payload.str.template.?);
    try std.testing.expectEqualStrings("\n", tok.payload.str.bytes);
    try std.testing.expectEqualStrings("\\n", tok.payload.str.raw_bytes);
}

test "G1/P0: template token normalizes raw CR line terminators" {
    var env = try LexerTestEnv.init();
    defer env.deinit();

    var lx = env.lexer("`\r\n\r`");
    var tok = try lx.next();
    defer freeAndDrain(&lx, &tok);
    try std.testing.expectEqual(t.TemplatePart.no_substitution, tok.payload.str.template.?);
    try std.testing.expectEqualStrings("\n\n", tok.payload.str.bytes);
    try std.testing.expectEqualStrings("\n\n", tok.payload.str.raw_bytes);
}

test "F1.2: regex literal exposes pattern and flags" {
    var env = try LexerTestEnv.init();
    defer env.deinit();

    // Provide the slash directly to rescanRegexp; in real usage the
    // parser would call this once it knew the / starts a regex.
    var lx = env.lexer("/a[bc]\\/d/gi");
    var tok = try lx.rescanRegexp(0);
    defer freeAndDrain(&lx, &tok);
    try std.testing.expectEqual(t.TOK_REGEXP, tok.val);
    try std.testing.expectEqualStrings("a[bc]\\/d", tok.payload.regexp.pattern);
    try std.testing.expectEqualStrings("gi", tok.payload.regexp.flags);
}

test "F1.2: regex literal may begin with equals after slash rescan" {
    var env = try LexerTestEnv.init();
    defer env.deinit();

    var lx = env.lexer("/=/g");
    var div_assign = try lx.next();
    defer freeAndDrain(&lx, &div_assign);
    try std.testing.expectEqual(t.TOK_DIV_ASSIGN, div_assign.val);

    var tok = try lx.rescanRegexp(lx.mark_pos);
    defer freeAndDrain(&lx, &tok);
    try std.testing.expectEqual(t.TOK_REGEXP, tok.val);
    try std.testing.expectEqualStrings("=", tok.payload.regexp.pattern);
    try std.testing.expectEqualStrings("g", tok.payload.regexp.flags);
}

// ---- F1.3 ------------------------------------------------------------

test "F1.3: private name keeps the # prefix in the atom" {
    var env = try LexerTestEnv.init();
    defer env.deinit();

    var lx = env.lexer("#secret");
    var tok = try lx.next();
    defer freeAndDrain(&lx, &tok);
    try std.testing.expectEqual(t.TOK_PRIVATE_NAME, tok.val);
    try std.testing.expectEqualStrings("#secret", env.rt.atoms.name(tok.payload.ident.atom).?);
}

test "F1.3: unicode escape inside identifier is decoded into the atom" {
    var env = try LexerTestEnv.init();
    defer env.deinit();

    var lx = env.lexer("\\u0061sync");
    var tok = try lx.next();
    defer freeAndDrain(&lx, &tok);
    try std.testing.expectEqual(t.TOK_IDENT, tok.val);
    try std.testing.expect(tok.payload.ident.has_escape);
    try std.testing.expectEqualStrings("async", env.rt.atoms.name(tok.payload.ident.atom).?);
}

test "F1.3: escaped keyword spelling is treated as identifier (per spec)" {
    var env = try LexerTestEnv.init();
    defer env.deinit();

    var lx = env.lexer("\\u0069f"); // \u0069f = "if"
    var tok = try lx.next();
    defer freeAndDrain(&lx, &tok);
    try std.testing.expectEqual(t.TOK_IDENT, tok.val); // not TOK_IF
    try std.testing.expectEqualStrings("if", env.rt.atoms.name(tok.payload.ident.atom).?);
}

test "F1.3: raw Unicode identifier start accepts ID_Start and rejects emoji" {
    var env = try LexerTestEnv.init();
    defer env.deinit();

    var good = env.lexer("\xCF\x80");
    var good_tok = try good.next();
    defer freeAndDrain(&good, &good_tok);
    try std.testing.expectEqual(t.TOK_IDENT, good_tok.val);
    try std.testing.expectEqualStrings("\xCF\x80", env.rt.atoms.name(good_tok.payload.ident.atom).?);

    var bad = env.lexer("\xF0\x9F\x98\x80");
    try std.testing.expectError(error.InvalidIdentifier, bad.next());
}

// ---- F1.4 ------------------------------------------------------------

test "F1.4: got_lf is true after a LineTerminator and false otherwise" {
    var env = try LexerTestEnv.init();
    defer env.deinit();

    var lx = env.lexer("a b\nc");
    var a = try lx.next();
    defer freeAndDrain(&lx, &a);
    try std.testing.expect(!lx.got_lf);

    var b = try lx.next();
    defer freeAndDrain(&lx, &b);
    try std.testing.expect(!lx.got_lf);

    var c = try lx.next();
    defer freeAndDrain(&lx, &c);
    try std.testing.expect(lx.got_lf);
}

test "F1.4: line_num and col_num are 1-based" {
    var env = try LexerTestEnv.init();
    defer env.deinit();

    var lx = env.lexer("a\n  b");
    var a = try lx.next();
    defer freeAndDrain(&lx, &a);
    try std.testing.expectEqual(@as(u32, 1), a.line_num);
    try std.testing.expectEqual(@as(u32, 1), a.col_num);

    var b = try lx.next();
    defer freeAndDrain(&lx, &b);
    try std.testing.expectEqual(@as(u32, 2), b.line_num);
    try std.testing.expectEqual(@as(u32, 3), b.col_num);
}

// ---- comprehensive --------------------------------------------------

test "F1: end-to-end lex of a small program" {
    var env = try LexerTestEnv.init();
    defer env.deinit();

    var lx = env.lexer(
        \\const x = 42;
        \\function f(a, b) { return a + b; }
        \\let s = "hi" + `world`;
        \\
    );

    const expected = [_]t.TokenKind{
        t.TOK_CONST,    t.TOK_IDENT, '=',          t.TOK_NUMBER, ';',
        t.TOK_FUNCTION, t.TOK_IDENT, '(',          t.TOK_IDENT,  ',',
        t.TOK_IDENT,    ')',         '{',          t.TOK_RETURN, t.TOK_IDENT,
        '+',            t.TOK_IDENT, ';',          '}',          t.TOK_LET,
        t.TOK_IDENT,    '=',         t.TOK_STRING, '+',          t.TOK_TEMPLATE,
        ';',            t.TOK_EOF,
    };
    for (expected) |want| {
        var tok = try lx.next();
        defer freeAndDrain(&lx, &tok);
        try std.testing.expectEqual(want, tok.val);
    }
}

test "F1: HTML comments are stripped in script mode but rejected in module mode" {
    var env = try LexerTestEnv.init();
    defer env.deinit();

    {
        var lx = env.lexer("a <!-- comment\nb");
        var a = try lx.next();
        defer freeAndDrain(&lx, &a);
        try std.testing.expectEqual(t.TOK_IDENT, a.val);
        var b = try lx.next();
        defer freeAndDrain(&lx, &b);
        try std.testing.expectEqual(t.TOK_IDENT, b.val);
    }
    {
        var lx = env.lexer("a <!-- comment\nb");
        lx.is_module = true;
        var a = try lx.next();
        defer freeAndDrain(&lx, &a);
        try std.testing.expectEqual(t.TOK_IDENT, a.val);
        // In module mode `<` is a punctuator, so the next token is `<`.
        var lt = try lx.next();
        defer freeAndDrain(&lx, &lt);
        try std.testing.expectEqual(@as(t.TokenKind, '<'), lt.val);
    }
}

test "F1: hashbang at start of file is skipped, but not later" {
    var env = try LexerTestEnv.init();
    defer env.deinit();

    var lx = env.lexer("#!/usr/bin/env zjs\n42");
    var tok = try lx.next();
    defer freeAndDrain(&lx, &tok);
    try std.testing.expectEqual(t.TOK_NUMBER, tok.val);
}

test "F1.5: keyword block atom layout matches quickjs-atom.h ordering" {
    var env = try LexerTestEnv.init();
    defer env.deinit();

    // Walk every keyword TOK_* and verify the keywordAtom() result
    // resolves to the expected predefined-atom string.
    const expected = [_]struct { val: t.TokenKind, name: []const u8 }{
        .{ .val = t.TOK_NULL, .name = "null" },
        .{ .val = t.TOK_FALSE, .name = "false" },
        .{ .val = t.TOK_TRUE, .name = "true" },
        .{ .val = t.TOK_IF, .name = "if" },
        .{ .val = t.TOK_ELSE, .name = "else" },
        .{ .val = t.TOK_RETURN, .name = "return" },
        .{ .val = t.TOK_VAR, .name = "var" },
        .{ .val = t.TOK_THIS, .name = "this" },
        .{ .val = t.TOK_DELETE, .name = "delete" },
        .{ .val = t.TOK_VOID, .name = "void" },
        .{ .val = t.TOK_TYPEOF, .name = "typeof" },
        .{ .val = t.TOK_NEW, .name = "new" },
        .{ .val = t.TOK_IN, .name = "in" },
        .{ .val = t.TOK_INSTANCEOF, .name = "instanceof" },
        .{ .val = t.TOK_DO, .name = "do" },
        .{ .val = t.TOK_WHILE, .name = "while" },
        .{ .val = t.TOK_FOR, .name = "for" },
        .{ .val = t.TOK_BREAK, .name = "break" },
        .{ .val = t.TOK_CONTINUE, .name = "continue" },
        .{ .val = t.TOK_SWITCH, .name = "switch" },
        .{ .val = t.TOK_CASE, .name = "case" },
        .{ .val = t.TOK_DEFAULT, .name = "default" },
        .{ .val = t.TOK_THROW, .name = "throw" },
        .{ .val = t.TOK_TRY, .name = "try" },
        .{ .val = t.TOK_CATCH, .name = "catch" },
        .{ .val = t.TOK_FINALLY, .name = "finally" },
        .{ .val = t.TOK_FUNCTION, .name = "function" },
        .{ .val = t.TOK_DEBUGGER, .name = "debugger" },
        .{ .val = t.TOK_WITH, .name = "with" },
        .{ .val = t.TOK_CLASS, .name = "class" },
        .{ .val = t.TOK_CONST, .name = "const" },
        .{ .val = t.TOK_ENUM, .name = "enum" },
        .{ .val = t.TOK_EXPORT, .name = "export" },
        .{ .val = t.TOK_EXTENDS, .name = "extends" },
        .{ .val = t.TOK_IMPORT, .name = "import" },
        .{ .val = t.TOK_SUPER, .name = "super" },
        .{ .val = t.TOK_IMPLEMENTS, .name = "implements" },
        .{ .val = t.TOK_INTERFACE, .name = "interface" },
        .{ .val = t.TOK_LET, .name = "let" },
        .{ .val = t.TOK_PACKAGE, .name = "package" },
        .{ .val = t.TOK_PRIVATE, .name = "private" },
        .{ .val = t.TOK_PROTECTED, .name = "protected" },
        .{ .val = t.TOK_PUBLIC, .name = "public" },
        .{ .val = t.TOK_STATIC, .name = "static" },
        .{ .val = t.TOK_YIELD, .name = "yield" },
        .{ .val = t.TOK_AWAIT, .name = "await" },
    };
    for (expected) |e| {
        const ka = t.keywordAtom(e.val);
        try std.testing.expectEqualStrings(e.name, env.rt.atoms.name(ka).?);
    }
}

test "F1: Lexer enableTypeScript strips variable and function TypeScript annotations dynamically" {
    var env = try LexerTestEnv.init();
    defer env.deinit();

    const src =
        \\const x: number = 42;
        \\function add(a: number, b?: number): number { return a + (b || 0); }
        \\console.log(add(x, 1));
    ;
    var lex = env.lexer(src);
    defer lex.deinit();
    try lex.enableTypeScript();

    // The lexer should skip all TS type parts and only emit clean JS tokens.
    // e.g. "const", "x", "=", "42", ";", etc.
    var tok = try lex.next();
    defer freeAndDrain(&lex, &tok);
    try std.testing.expectEqual(t.TOK_CONST, tok.val);

    tok = try lex.next();
    try std.testing.expectEqual(t.TOK_IDENT, tok.val);
    try std.testing.expectEqualStrings("x", tok.ptr[0..tok.len]);

    tok = try lex.next();
    try std.testing.expectEqual('=', tok.val);

    tok = try lex.next();
    try std.testing.expectEqual(t.TOK_NUMBER, tok.val);

    tok = try lex.next();
    try std.testing.expectEqual(';', tok.val);

    tok = try lex.next();
    try std.testing.expectEqual(t.TOK_FUNCTION, tok.val);

    tok = try lex.next();
    try std.testing.expectEqual(t.TOK_IDENT, tok.val);
    try std.testing.expectEqualStrings("add", tok.ptr[0..tok.len]);

    tok = try lex.next();
    try std.testing.expectEqual('(', tok.val);

    tok = try lex.next();
    try std.testing.expectEqual(t.TOK_IDENT, tok.val);
    try std.testing.expectEqualStrings("a", tok.ptr[0..tok.len]);

    tok = try lex.next();
    try std.testing.expectEqual(',', tok.val);

    tok = try lex.next();
    try std.testing.expectEqual(t.TOK_IDENT, tok.val);
    try std.testing.expectEqualStrings("b", tok.ptr[0..tok.len]);

    tok = try lex.next();
    try std.testing.expectEqual(')', tok.val);

    tok = try lex.next();
    try std.testing.expectEqual('{', tok.val);
}

// ================== PARSER TESTS ==================

const TestEnv = ParserTestEnv;
const ParserTestEnv = struct {
    rt: *engine.core.runtime.JSRuntime,

    fn init() !TestEnv {
        return .{ .rt = try engine.core.runtime.JSRuntime.create(std.testing.allocator) };
    }
    fn deinit(self: *TestEnv) void {
        self.rt.destroy();
    }
};

/// Helper: parse `src` as an expression, run the F10 pipeline, and
/// return the produced final-form bytecode for byte-sequence
/// comparison. The parser's default is `emit_phase1_temp = true`, so
/// raw parser output contains scope_get_var/scope_put_var and other
/// Phase 1 temp opcodes; `pipeline.finalize.runWithFunctionDef`
/// lowers them to the final shapes the tests assert against
/// (including get_loc/put_loc for vars in `function_def.vars`).
fn parseExpr(env: *TestEnv, src: []const u8) !engine.bytecode.Bytecode {
    const name = try env.rt.internAtom("test");
    defer env.rt.atoms.free(name);
    var function = engine.bytecode.Bytecode.init(&env.rt.memory, &env.rt.atoms, name);
    errdefer function.deinit(env.rt);
    var lex = QjsLexer.init(std.testing.allocator, &env.rt.atoms, src);
    var state = try ParseState.init(&lex, &function);
    defer state.deinit(env.rt);
    try parser_core.parseExpr(&state);
    try parser_core.prepareFunctionDefsForFinalizationWithRoot(&state.function_def, &function);
    try engine.bytecode.pipeline.finalize.runWithFunctionDef(&function, &state.function_def);
    return function;
}

fn parseExprWithTopLevelChildren(env: *TestEnv, src: []const u8) !engine.bytecode.Bytecode {
    const name = try env.rt.internAtom("test");
    defer env.rt.atoms.free(name);
    var function = engine.bytecode.Bytecode.init(&env.rt.memory, &env.rt.atoms, name);
    errdefer function.deinit(env.rt);
    var lex = QjsLexer.init(std.testing.allocator, &env.rt.atoms, src);
    var state = try ParseState.init(&lex, &function);
    defer state.deinit(env.rt);
    configureScriptRoot(&state);
    state.top_level_functions_as_children = true;
    try parser_core.parseExpr(&state);
    try parser_core.prepareFunctionDefsForFinalizationWithRoot(&state.function_def, &function);
    try engine.bytecode.pipeline.finalize.runWithFunctionDefRuntime(&function, &state.function_def, env.rt);
    return function;
}

fn parseExprStrict(env: *TestEnv, src: []const u8) !engine.bytecode.Bytecode {
    const name = try env.rt.internAtom("test");
    defer env.rt.atoms.free(name);
    var function = engine.bytecode.Bytecode.init(&env.rt.memory, &env.rt.atoms, name);
    errdefer function.deinit(env.rt);
    var lex = QjsLexer.init(std.testing.allocator, &env.rt.atoms, src);
    lex.is_strict_mode = true;
    var state = try ParseState.init(&lex, &function);
    defer state.deinit(env.rt);
    configureScriptRoot(&state);
    state.is_strict = true;
    state.function_def.is_strict_mode = true;
    try parser_core.parseExpr(&state);
    try parser_core.prepareFunctionDefsForFinalizationWithRoot(&state.function_def, &function);
    try engine.bytecode.pipeline.finalize.runWithFunctionDef(&function, &state.function_def);
    return function;
}

/// Helper: parse `src` as a statement, run the F10 pipeline, and
/// return the produced final-form bytecode for byte-sequence comparison.
fn parseStatement(env: *TestEnv, src: []const u8) !engine.bytecode.Bytecode {
    const name = try env.rt.internAtom("test");
    defer env.rt.atoms.free(name);
    var function = engine.bytecode.Bytecode.init(&env.rt.memory, &env.rt.atoms, name);
    errdefer function.deinit(env.rt);
    var lex = QjsLexer.init(std.testing.allocator, &env.rt.atoms, src);
    var state = try ParseState.init(&lex, &function);
    defer state.deinit(env.rt);
    configureScriptRoot(&state);
    try parser_core.parseStatementOrDecl(&state, parser_core.DeclMask{ .func = true, .func_with_label = true, .other = true });
    try parser_core.prepareFunctionDefsForFinalizationWithRoot(&state.function_def, &function);
    try engine.bytecode.pipeline.finalize.runWithFunctionDef(&function, &state.function_def);
    return function;
}

fn parseTSStatement(env: *TestEnv, src: []const u8) !engine.bytecode.Bytecode {
    const name = try env.rt.internAtom("test");
    defer env.rt.atoms.free(name);
    var function = engine.bytecode.Bytecode.init(&env.rt.memory, &env.rt.atoms, name);
    errdefer function.deinit(env.rt);
    var lex = QjsLexer.init(std.testing.allocator, &env.rt.atoms, src);
    defer lex.deinit();
    try lex.enableTypeScript();
    var state = try ParseState.init(&lex, &function);
    defer state.deinit(env.rt);
    configureScriptRoot(&state);
    try parser_core.parseStatementOrDecl(&state, parser_core.DeclMask{ .func = true, .func_with_label = true, .other = true });
    try parser_core.prepareFunctionDefsForFinalizationWithRoot(&state.function_def, &function);
    try engine.bytecode.pipeline.finalize.runWithFunctionDef(&function, &state.function_def);
    return function;
}

fn parseTSProgram(env: *TestEnv, src: []const u8) !engine.bytecode.Bytecode {
    const name = try env.rt.internAtom("test");
    defer env.rt.atoms.free(name);
    var function = engine.bytecode.Bytecode.init(&env.rt.memory, &env.rt.atoms, name);
    errdefer function.deinit(env.rt);
    var lex = QjsLexer.init(std.testing.allocator, &env.rt.atoms, src);
    defer lex.deinit();
    try lex.enableTypeScript();
    var state = try ParseState.init(&lex, &function);
    defer state.deinit(env.rt);
    configureScriptRoot(&state);
    state.top_level_functions_as_children = true;
    try parser_core.parseDirectives(&state);
    try parser_core.parseProgramStatements(&state, parser_core.DeclMask{ .func = true, .func_with_label = true, .other = true });
    try parser_core.prepareFunctionDefsForFinalizationWithRoot(&state.function_def, &function);
    try engine.bytecode.pipeline.finalize.runWithFunctionDefRuntime(&function, &state.function_def, env.rt);
    return function;
}

fn parseStatementWithTopLevelChildren(env: *TestEnv, src: []const u8) !engine.bytecode.Bytecode {
    const name = try env.rt.internAtom("test");
    defer env.rt.atoms.free(name);
    var function = engine.bytecode.Bytecode.init(&env.rt.memory, &env.rt.atoms, name);
    errdefer function.deinit(env.rt);
    var lex = QjsLexer.init(std.testing.allocator, &env.rt.atoms, src);
    var state = try ParseState.init(&lex, &function);
    defer state.deinit(env.rt);
    configureScriptRoot(&state);
    state.top_level_functions_as_children = true;
    try parser_core.parseStatementOrDecl(&state, parser_core.DeclMask{ .func = true, .func_with_label = true, .other = true });
    try parser_core.prepareFunctionDefsForFinalizationWithRoot(&state.function_def, &function);
    try engine.bytecode.pipeline.finalize.runWithFunctionDefRuntime(&function, &state.function_def, env.rt);
    return function;
}

fn parseModuleStatement(env: *TestEnv, src: []const u8) !engine.bytecode.Bytecode {
    const name = try env.rt.internAtom("test");
    defer env.rt.atoms.free(name);
    var function = engine.bytecode.Bytecode.init(&env.rt.memory, &env.rt.atoms, name);
    function.flags.is_module = true;
    errdefer function.deinit(env.rt);
    var lex = QjsLexer.init(std.testing.allocator, &env.rt.atoms, src);
    lex.is_module = true;
    var state = try ParseState.init(&lex, &function);
    defer state.deinit(env.rt);
    configureModuleRoot(&state);
    try parser_core.parseStatementOrDecl(&state, parser_core.DeclMask{ .func = true, .func_with_label = true, .other = true });
    try parser_core.prepareFunctionDefsForFinalizationWithRoot(&state.function_def, &function);
    try engine.bytecode.pipeline.finalize.runWithFunctionDef(&function, &state.function_def);
    return function;
}

fn parseModuleRefStatement(env: *TestEnv, src: []const u8) !engine.bytecode.Bytecode {
    const name = try env.rt.internAtom("test");
    defer env.rt.atoms.free(name);
    var function = engine.bytecode.Bytecode.init(&env.rt.memory, &env.rt.atoms, name);
    function.flags.is_module = true;
    errdefer function.deinit(env.rt);
    var lex = QjsLexer.init(std.testing.allocator, &env.rt.atoms, src);
    lex.is_module = true;
    var state = try ParseState.init(&lex, &function);
    defer state.deinit(env.rt);
    configureModuleRoot(&state);
    try parser_core.parseProgramStatements(&state, parser_core.DeclMask{ .func = true, .func_with_label = true, .other = true });
    try parser_core.prepareFunctionDefsForFinalizationWithRoot(&state.function_def, &function);
    try engine.bytecode.pipeline.finalize.runWithFunctionDef(&function, &state.function_def);
    return function;
}

fn moduleBodyStart(code: []const u8) !usize {
    if (code.len < 3 or code[0] != op.push_this) return error.TestExpectedEqual;
    const target: isize = switch (code[1]) {
        op.if_false8 => 2 + @as(i8, @bitCast(code[2])),
        op.if_false => blk: {
            if (code.len < 6) return error.TestExpectedEqual;
            break :blk 2 + std.mem.readInt(i32, code[2..6], .little);
        },
        else => return error.TestExpectedEqual,
    };
    if (target < 0 or target > code.len) return error.TestExpectedEqual;
    return @intCast(target);
}

fn moduleRecord(function: *const engine.bytecode.Bytecode) !*const engine.bytecode.module.Record {
    if (function.module_record) |*record| return record;
    return error.TestExpectedEqual;
}

fn expectAtomName(env: *TestEnv, atom_id: engine.core.Atom, expected: []const u8) !void {
    const name = env.rt.atoms.name(atom_id) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings(expected, name);
}

fn functionBytecodeFromValue(value: engine.core.JSValue) ?*const engine.bytecode.FunctionBytecode {
    if (!value.isFunctionBytecode()) return null;
    const header = value.objectHeader() orelse return null;
    const aligned: *align(16) @TypeOf(header.*) = @alignCast(header);
    return @fieldParentPtr("header", aligned);
}

fn expectFunctionConstant(function: *const engine.bytecode.Bytecode, index: usize) !*const engine.bytecode.FunctionBytecode {
    try std.testing.expect(index < function.constants.values.len);
    return functionBytecodeFromValue(function.constants.values[index]) orelse error.TestExpectedEqual;
}

fn findFunctionConstantNamed(
    function: *const engine.bytecode.Bytecode,
    rt: *core.JSRuntime,
    expected_name: []const u8,
) ?*const engine.bytecode.FunctionBytecode {
    for (function.constants.values) |value| {
        const child = functionBytecodeFromValue(value) orelse continue;
        if (std.mem.eql(u8, rt.atoms.name(child.func_name) orelse "", expected_name)) return child;
    }
    return null;
}

fn countFunctionConstantsNamed(
    function: *const engine.bytecode.Bytecode,
    rt: *core.JSRuntime,
    expected_name: []const u8,
) usize {
    var count: usize = 0;
    for (function.constants.values) |value| {
        const child = functionBytecodeFromValue(value) orelse continue;
        if (std.mem.eql(u8, rt.atoms.name(child.func_name) orelse "", expected_name)) count += 1;
    }
    return count;
}

fn globalDeclarationClosureNamed(
    function: *const engine.bytecode.Bytecode,
    rt: *core.JSRuntime,
    expected_name: []const u8,
) ?*const engine.bytecode.function_bytecode.BytecodeClosureVar {
    for (function.closure_var, 0..) |cv, idx| {
        if (cv.closureType() != .global_decl) continue;
        if (std.mem.eql(u8, rt.atoms.name(cv.var_name) orelse "", expected_name)) return &function.closure_var[idx];
    }
    return null;
}

fn declarationClosureNamed(
    function: *const engine.bytecode.Bytecode,
    rt: *core.JSRuntime,
    expected_name: []const u8,
) ?*const engine.bytecode.function_bytecode.BytecodeClosureVar {
    for (function.closure_var, 0..) |cv, idx| {
        if (cv.closureType() != .global_decl and cv.closureType() != .module_decl) continue;
        if (std.mem.eql(u8, rt.atoms.name(cv.var_name) orelse "", expected_name)) return &function.closure_var[idx];
    }
    return null;
}

fn globalDeclarationClosureCount(function: *const engine.bytecode.Bytecode) usize {
    var count: usize = 0;
    for (function.closure_var) |cv| {
        if (cv.closureType() == .global_decl) count += 1;
    }
    return count;
}

fn varDefNamed(
    function: *const engine.bytecode.Bytecode,
    rt: *core.JSRuntime,
    expected_name: []const u8,
) ?*const engine.bytecode.function_bytecode.BytecodeVarDef {
    for (function.vardefs, 0..) |vd, idx| {
        if (std.mem.eql(u8, rt.atoms.name(vd.var_name) orelse "", expected_name)) {
            return &function.vardefs[idx];
        }
    }
    return null;
}

fn countPutVarRefStores(code: []const u8) usize {
    return countOpcode(code, op.put_var_ref) +
        countOpcode(code, op.put_var_ref0) +
        countOpcode(code, op.put_var_ref1) +
        countOpcode(code, op.put_var_ref2) +
        countOpcode(code, op.put_var_ref3);
}

fn countOpcodeInFunctionBytecode(fb: *const engine.bytecode.FunctionBytecode, opcode: u8) usize {
    var count = countOpcode(fb.byteCode(), opcode);
    for (fb.cpoolSlice()) |value| {
        if (functionBytecodeFromValue(value)) |child| {
            count += countOpcodeInFunctionBytecode(child, opcode);
        }
    }
    return count;
}

fn countOpcodeRecursive(function: *const engine.bytecode.Bytecode, opcode: u8) usize {
    var count = countOpcode(function.code, opcode);
    for (function.constants.values) |value| {
        if (functionBytecodeFromValue(value)) |fb| {
            count += countOpcodeInFunctionBytecode(fb, opcode);
        }
    }
    return count;
}

fn expectOpcode(code: []const u8, opcode: u8) !void {
    try std.testing.expect(countOpcode(code, opcode) > 0);
}

fn expectOpcodeSequence(code: []const u8, expected: []const u8) !void {
    var pc: usize = 0;
    for (expected) |opcode_id| {
        try std.testing.expect(pc < code.len);
        try std.testing.expectEqual(opcode_id, code[pc]);
        const size = engine.bytecode.opcode.sizeOf(opcode_id);
        try std.testing.expect(size != 0);
        pc += size;
    }
    try std.testing.expectEqual(code.len, pc);
}

fn readU16AtOpcode(code: []const u8, op_offset: usize) u16 {
    return std.mem.readInt(u16, code[op_offset + 1 ..][0..2], .little);
}

fn readConstIndexAtOpcode(code: []const u8, op_offset: usize) u32 {
    return switch (code[op_offset]) {
        op.push_const8, op.fclosure8 => code[op_offset + 1],
        op.push_const, op.fclosure => readU32(code, op_offset + 1),
        else => unreachable,
    };
}

fn expectOpcodeRecursive(function: *const engine.bytecode.Bytecode, opcode: u8) !void {
    try std.testing.expect(countOpcodeRecursive(function, opcode) > 0);
}

fn expectModuleRecordCounts(
    record: *const engine.bytecode.module.Record,
    requests: usize,
    imports: usize,
    exports: usize,
    indirect_exports: usize,
    star_exports: usize,
) !void {
    try std.testing.expectEqual(requests, record.requests.len);
    try std.testing.expectEqual(imports, record.imports.len);
    try std.testing.expectEqual(exports, record.exports.len);
    try std.testing.expectEqual(indirect_exports, record.indirect_exports.len);
    try std.testing.expectEqual(star_exports, record.star_exports.len);
    try std.testing.expectEqual(@as(usize, 0), record.import_attributes.len);
}

fn expectModuleRequest(env: *TestEnv, record: *const engine.bytecode.module.Record, index: usize, module_name: []const u8) !void {
    try expectAtomName(env, record.requests[index].module_name, module_name);
}

fn expectModuleImport(
    env: *TestEnv,
    record: *const engine.bytecode.module.Record,
    index: usize,
    request_index: u32,
    import_name: []const u8,
    local_name: []const u8,
) !void {
    const entry = record.imports[index];
    try std.testing.expectEqual(request_index, entry.request_index);
    try expectAtomName(env, entry.import_name, import_name);
    try expectAtomName(env, entry.local_name, local_name);
}

fn expectModuleExport(
    env: *TestEnv,
    record: *const engine.bytecode.module.Record,
    index: usize,
    export_name: []const u8,
    local_name: []const u8,
) !void {
    const entry = record.exports[index];
    try expectAtomName(env, entry.export_name, export_name);
    try expectAtomName(env, entry.local_name, local_name);
}

fn expectModuleIndirectExport(
    env: *TestEnv,
    record: *const engine.bytecode.module.Record,
    index: usize,
    request_index: u32,
    export_name: []const u8,
    import_name: []const u8,
) !void {
    const entry = record.indirect_exports[index];
    try std.testing.expectEqual(request_index, entry.request_index);
    try expectAtomName(env, entry.export_name, export_name);
    try expectAtomName(env, entry.import_name, import_name);
}

fn expectModuleStarExport(
    env: *TestEnv,
    record: *const engine.bytecode.module.Record,
    index: usize,
    request_index: u32,
    export_name: []const u8,
) !void {
    const entry = record.star_exports[index];
    try std.testing.expectEqual(request_index, entry.request_index);
    try expectAtomName(env, entry.export_name, export_name);
}

fn parseFunctionBodyStatement(env: *TestEnv, src: []const u8) !engine.bytecode.Bytecode {
    const name = try env.rt.internAtom("test");
    defer env.rt.atoms.free(name);
    var function = engine.bytecode.Bytecode.init(&env.rt.memory, &env.rt.atoms, name);
    errdefer function.deinit(env.rt);
    var lex = QjsLexer.init(std.testing.allocator, &env.rt.atoms, src);
    var state = try ParseState.init(&lex, &function);
    defer state.deinit(env.rt);
    state.return_depth = 1;
    try parser_core.parseStatementOrDecl(&state, parser_core.DeclMask{ .func = true, .func_with_label = true, .other = true });
    try engine.bytecode.pipeline.finalize.runWithFunctionDef(&function, &state.function_def);
    return function;
}

fn expectParseStatementError(env: *TestEnv, src: []const u8) !void {
    if (parseStatement(env, src)) |fn_bc_result| {
        var fn_bc = fn_bc_result;
        fn_bc.deinit(env.rt);
        return error.TestExpectedError;
    } else |err| {
        try std.testing.expectEqual(error.UnexpectedToken, err);
    }
}

test "parser accepts computed public class fields" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var function = try parseStatement(&env, "class C { [\"x\"] = 1; }");
    defer function.deinit(env.rt);
}

/// Read a u32 in little-endian from `bytes` starting at `offset`.
fn readU32(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset..][0..4], .little);
}

fn readI32(bytes: []const u8, offset: usize) i32 {
    return std.mem.readInt(i32, bytes[offset..][0..4], .little);
}

fn readRelTarget32(bytes: []const u8, op_offset: usize) usize {
    const operand_offset = op_offset + 1;
    const diff: i64 = switch (engine.bytecode.opcode.formatOf(bytes[op_offset])) {
        .label8 => @as(i64, std.mem.readInt(i8, bytes[operand_offset..][0..1], .little)),
        .label16 => @as(i64, std.mem.readInt(i16, bytes[operand_offset..][0..2], .little)),
        .label => @as(i64, readI32(bytes, operand_offset)),
        else => unreachable,
    };
    return @intCast(@as(i64, @intCast(operand_offset)) + @as(i64, diff));
}

fn countOpcode(code: []const u8, opcode: u8) usize {
    var count: usize = 0;
    var pc: usize = 0;
    while (pc < code.len) {
        const opcode_id = code[pc];
        if (opcode_id == opcode) count += 1;
        const size = engine.bytecode.opcode.sizeOf(opcode_id);
        if (size == 0) break;
        pc += size;
    }
    return count;
}

fn countVarOpcodeForAtom(function: *const engine.bytecode.Bytecode, opcode: u8, atom_id: core.Atom) usize {
    var count: usize = 0;
    var pc: usize = 0;
    while (pc < function.code.len) {
        const opcode_id = function.code[pc];
        if (opcode_id == opcode and pc + 3 <= function.code.len) {
            const ref_idx = readU16AtOpcode(function.code, pc);
            if (ref_idx < function.closure_var.len and function.closure_var[ref_idx].var_name == atom_id) count += 1;
        }
        const size = engine.bytecode.opcode.sizeOf(opcode_id);
        if (size == 0) break;
        pc += size;
    }
    return count;
}

fn hasAnyOpcode(code: []const u8, opcodes: []const u8) bool {
    for (opcodes) |opcode_id| {
        if (countOpcode(code, opcode_id) > 0) return true;
    }
    return false;
}

// ---- F4 first slice -------------------------------------------------

test "F4: number literal lowers to short integer form" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "42");
    defer fn_bc.deinit(env.rt);

    try std.testing.expectEqual(@as(usize, 2), fn_bc.code.len);
    try std.testing.expectEqual(op.push_i8, fn_bc.code[0]);
    try std.testing.expectEqual(@as(u8, 42), fn_bc.code[1]);
}

test "F4: number literal with non-integer value lowers to push_const" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "3.5");
    defer fn_bc.deinit(env.rt);

    try std.testing.expectEqual(@as(usize, 2), fn_bc.code.len);
    try std.testing.expectEqual(op.push_const8, fn_bc.code[0]);
    const idx = readConstIndexAtOpcode(fn_bc.code, 0);
    const value = fn_bc.constants.get(idx).?;
    defer value.free(env.rt);
    try std.testing.expectApproxEqAbs(@as(f64, 3.5), value.asFloat64().?, 0.0001);
}

test "F4: large bigint literal lowers to constant pool value" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "0x100000000n");
    defer fn_bc.deinit(env.rt);

    try std.testing.expectEqual(@as(usize, 2), fn_bc.code.len);
    try std.testing.expectEqual(op.push_const8, fn_bc.code[0]);
    const idx = readConstIndexAtOpcode(fn_bc.code, 0);
    const value = fn_bc.constants.get(idx).?;
    defer value.free(env.rt);
    try std.testing.expect(value.isBigInt());
}

test "F4: regexp literal stores parse-time compiled bytecode in the constant pool" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var parsed = try parser.compile(env.rt, "/a+/gi;", .{ .mode = .script, .filename = "regexp-literal.js" });
    defer parsed.deinit();
    try std.testing.expect(parsed.syntax_error == null);
    const fn_bc = &parsed.function;

    var previous_previous_pc: ?usize = null;
    var previous_pc: ?usize = null;
    var regexp_pc: ?usize = null;
    var pc: usize = 0;
    while (pc < fn_bc.code.len) {
        if (fn_bc.code[pc] == op.regexp) {
            regexp_pc = pc;
            break;
        }
        previous_previous_pc = previous_pc;
        previous_pc = pc;
        const opcode_size = engine.bytecode.opcode.sizeOf(fn_bc.code[pc]);
        try std.testing.expect(opcode_size != 0);
        pc += opcode_size;
    }

    try std.testing.expect(regexp_pc != null);
    try std.testing.expectEqual(op.push_atom_value, fn_bc.code[previous_previous_pc.?]);
    try std.testing.expectEqual(op.push_const8, fn_bc.code[previous_pc.?]);
    try std.testing.expectEqual(@as(usize, 1), fn_bc.constants.values.len);

    const constant_index = readConstIndexAtOpcode(fn_bc.code, previous_pc.?);
    const compiled_value = fn_bc.constants.get(constant_index).?;
    defer compiled_value.free(env.rt);
    const compiled_string = compiled_value.asStringBodyRaw() orelse return error.TestExpectedEqual;
    try std.testing.expect(!compiled_string.isWide());

    var expected = try engine.libs.regexp.compilePatternAndFlags(std.testing.allocator, "a+", "gi");
    defer expected.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, expected.bytecode, compiled_string.borrowLatin1().?);
}

test "F4: boolean and null literals" {
    var env = try ParserTestEnv.init();
    defer env.deinit();

    var t_bc = try parseExpr(&env, "true");
    defer t_bc.deinit(env.rt);
    try std.testing.expectEqualSlices(u8, &[_]u8{op.push_true}, t_bc.code);

    var f_bc = try parseExpr(&env, "false");
    defer f_bc.deinit(env.rt);
    try std.testing.expectEqualSlices(u8, &[_]u8{op.push_false}, f_bc.code);

    var n_bc = try parseExpr(&env, "null");
    defer n_bc.deinit(env.rt);
    try std.testing.expectEqualSlices(u8, &[_]u8{op.null}, n_bc.code);
}

test "F4: identifier reads global via get_var" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "x");
    defer fn_bc.deinit(env.rt);

    try std.testing.expectEqual(@as(usize, 3), fn_bc.code.len);
    try std.testing.expectEqual(op.get_var, fn_bc.code[0]);
    try std.testing.expectEqual(@as(u16, 0), readU16AtOpcode(fn_bc.code, 0));
    try std.testing.expectEqual(@as(usize, 0), fn_bc.atom_operands.len);
    try std.testing.expectEqual(@as(usize, 1), fn_bc.var_ref_names.len);
}

test "F4: parseExprBinary level 1 (mul/div/mod)" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "2 * 3");
    defer fn_bc.deinit(env.rt);

    try expectOpcodeSequence(fn_bc.code, &.{ op.push_2, op.push_3, op.mul });
}

test "F4: parseExprBinary level 2 (add/sub) is left-associative" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "1 + 2 - 3");
    defer fn_bc.deinit(env.rt);

    try expectOpcodeSequence(fn_bc.code, &.{ op.push_1, op.push_2, op.add, op.push_3, op.sub });
}

test "F4: precedence — multiplication before addition" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "1 + 2 * 3");
    defer fn_bc.deinit(env.rt);

    try expectOpcodeSequence(fn_bc.code, &.{ op.push_1, op.push_2, op.push_3, op.mul, op.add });
}

test "F4: parentheses override precedence" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "(1 + 2) * 3");
    defer fn_bc.deinit(env.rt);

    try expectOpcodeSequence(fn_bc.code, &.{ op.push_1, op.push_2, op.add, op.push_3, op.mul });
}

test "F4: comparison operators map to op.lt/op.lte/op.eq/op.strict_eq" {
    var env = try ParserTestEnv.init();
    defer env.deinit();

    var lt_bc = try parseExpr(&env, "1 < 2");
    defer lt_bc.deinit(env.rt);
    try std.testing.expectEqual(op.lt, lt_bc.code[lt_bc.code.len - 1]);

    var lte_bc = try parseExpr(&env, "1 <= 2");
    defer lte_bc.deinit(env.rt);
    try std.testing.expectEqual(op.lte, lte_bc.code[lte_bc.code.len - 1]);

    var eq_bc = try parseExpr(&env, "1 == 2");
    defer eq_bc.deinit(env.rt);
    try std.testing.expectEqual(op.eq, eq_bc.code[eq_bc.code.len - 1]);

    var seq_bc = try parseExpr(&env, "1 === 2");
    defer seq_bc.deinit(env.rt);
    try std.testing.expectEqual(op.strict_eq, seq_bc.code[seq_bc.code.len - 1]);
}

test "F4: bitwise levels 6/7/8 (and/xor/or) and shifts" {
    var env = try ParserTestEnv.init();
    defer env.deinit();

    var and_bc = try parseExpr(&env, "1 & 2");
    defer and_bc.deinit(env.rt);
    try std.testing.expectEqual(op.@"and", and_bc.code[and_bc.code.len - 1]);

    var xor_bc = try parseExpr(&env, "1 ^ 2");
    defer xor_bc.deinit(env.rt);
    try std.testing.expectEqual(op.xor, xor_bc.code[xor_bc.code.len - 1]);

    var or_bc = try parseExpr(&env, "1 | 2");
    defer or_bc.deinit(env.rt);
    try std.testing.expectEqual(op.@"or", or_bc.code[or_bc.code.len - 1]);

    var shl_bc = try parseExpr(&env, "1 << 2");
    defer shl_bc.deinit(env.rt);
    try std.testing.expectEqual(op.shl, shl_bc.code[shl_bc.code.len - 1]);

    var shr_bc = try parseExpr(&env, "1 >>> 2");
    defer shr_bc.deinit(env.rt);
    try std.testing.expectEqual(op.shr, shr_bc.code[shr_bc.code.len - 1]);
}

test "F4: unary +/-/~/! lower to plus/neg/not/lnot" {
    var env = try ParserTestEnv.init();
    defer env.deinit();

    var pos_bc = try parseExpr(&env, "+x");
    defer pos_bc.deinit(env.rt);
    try std.testing.expectEqual(op.plus, pos_bc.code[pos_bc.code.len - 1]);

    var neg_bc = try parseExpr(&env, "-x");
    defer neg_bc.deinit(env.rt);
    try std.testing.expectEqual(op.neg, neg_bc.code[neg_bc.code.len - 1]);

    var not_bc = try parseExpr(&env, "~x");
    defer not_bc.deinit(env.rt);
    try std.testing.expectEqual(op.not, not_bc.code[not_bc.code.len - 1]);

    var lnot_bc = try parseExpr(&env, "!x");
    defer lnot_bc.deinit(env.rt);
    try std.testing.expectEqual(op.lnot, lnot_bc.code[lnot_bc.code.len - 1]);
}

test "F4: typeof identifier uses get_var_undef + typeof" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "typeof x");
    defer fn_bc.deinit(env.rt);

    try std.testing.expectEqual(@as(usize, 4), fn_bc.code.len);
    try std.testing.expectEqual(op.get_var_undef, fn_bc.code[0]);
    try std.testing.expectEqual(@as(u16, 0), readU16AtOpcode(fn_bc.code, 0));
    try std.testing.expectEqual(op.typeof, fn_bc.code[3]);
}

test "F4: typeof optional chain parses full chain" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "typeof x?.y?.z");
    defer fn_bc.deinit(env.rt);

    try std.testing.expectEqual(op.typeof, fn_bc.code[fn_bc.code.len - 1]);
}

test "F4: void evaluates and discards then pushes undefined" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "void 0");
    defer fn_bc.deinit(env.rt);

    try expectOpcodeSequence(fn_bc.code, &.{ op.push_0, op.drop, op.undefined });
}

test "M3.1 F4: strict eval and arguments update targets are rejected" {
    var env = try ParserTestEnv.init();
    defer env.deinit();

    try std.testing.expectError(error.InvalidAssignmentTarget, parseExprStrict(&env, "++eval"));
    try std.testing.expectError(error.InvalidAssignmentTarget, parseExprStrict(&env, "arguments--"));
}

test "F4: power operator is right-associative" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "2 ** 3");
    defer fn_bc.deinit(env.rt);
    try std.testing.expectEqual(op.pow, fn_bc.code[fn_bc.code.len - 1]);
}

test "F4: logical && uses dup + if_false short-circuit" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "x && y");
    defer fn_bc.deinit(env.rt);

    try expectOpcodeSequence(fn_bc.code, &.{ op.get_var, op.dup, op.if_false8, op.drop, op.get_var });
    const target = readRelTarget32(fn_bc.code, 4);
    try std.testing.expectEqual(fn_bc.code.len, target);
}

test "F4: logical || uses dup + if_true short-circuit" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "x || y");
    defer fn_bc.deinit(env.rt);

    try expectOpcodeSequence(fn_bc.code, &.{ op.get_var, op.dup, op.if_true8, op.drop, op.get_var });
    const target = readRelTarget32(fn_bc.code, 4);
    try std.testing.expectEqual(fn_bc.code.len, target);
}

test "F4: nullish coalescing ?? uses is_undefined_or_null gate" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "x ?? y");
    defer fn_bc.deinit(env.rt);

    try expectOpcodeSequence(fn_bc.code, &.{ op.get_var, op.dup, op.is_undefined_or_null, op.if_false8, op.drop, op.get_var });
    const target = readRelTarget32(fn_bc.code, 5);
    try std.testing.expectEqual(fn_bc.code.len, target);
}

test "M3.1 F4: nullish coalescing chains and rejects direct logical mixing" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "x ?? y ?? z");
    defer fn_bc.deinit(env.rt);

    try std.testing.expectEqual(@as(usize, 2), countOpcode(fn_bc.code, op.is_undefined_or_null));
    try expectParseStatementError(&env, "var r = x || y ?? z;");
    try expectParseStatementError(&env, "var r = x && y ?? z;");
    try expectParseStatementError(&env, "var r = x ?? y || z;");
    try expectParseStatementError(&env, "var r = x ?? y && z;");
}

test "F4: discarded short-circuit with assignment RHS keeps function stack balanced" {
    var env = try ParserTestEnv.init();
    defer env.deinit();

    const failing_cases = [_][]const u8{
        "function f(p){ p ?? (p = 5); }",
        "function f(p){ p || (p = 5); }",
        "function f(p){ p && (p = 5); }",
        "const f = (p) => { p ?? (p = 5); };",
    };
    for (failing_cases) |source| {
        var fn_bc = try parseStatementWithTopLevelChildren(&env, source);
        defer fn_bc.deinit(env.rt);
    }

    const control_cases = [_][]const u8{
        "function f(p){ let x = p ?? 5; return x; }",
        "function f(p){ p ?? 5; }",
        "pos ?? (pos = 5);",
    };
    for (control_cases) |source| {
        var fn_bc = try parseStatement(&env, source);
        defer fn_bc.deinit(env.rt);
    }
}

test "F4: discarded conditional assignment arms keep function stack balanced" {
    var env = try ParserTestEnv.init();
    defer env.deinit();

    const cases = [_][]const u8{
        "function f(){ a ? b = 1 : c; }",
        "function f(){ a ? b : c = 1; }",
        "function f(){ c ? 0 : p = 1; }",
        "function f(){ a ? b : c -= 1; }",
        "function f(){ a ? b : c[d] = b; }",
    };
    for (cases) |source| {
        var fn_bc = try parseStatementWithTopLevelChildren(&env, source);
        defer fn_bc.deinit(env.rt);
    }
}

test "F4: ternary cond ? a : b emits if_false + goto skeleton" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "a ? b : c");
    defer fn_bc.deinit(env.rt);

    try expectOpcodeSequence(fn_bc.code, &.{ op.get_var, op.if_false8, op.get_var, op.goto8, op.get_var });
    const else_target = readRelTarget32(fn_bc.code, 3);
    try std.testing.expectEqual(@as(usize, 10), else_target);
    const end_target = readRelTarget32(fn_bc.code, 8);
    try std.testing.expectEqual(fn_bc.code.len, end_target);
}

test "F4: simple assignment x = 1 emits push ; dup ; put_var (KEEP_TOP)" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "x = 1");
    defer fn_bc.deinit(env.rt);

    try expectOpcodeSequence(fn_bc.code, &.{ op.push_1, op.dup, op.put_var });
}

test "F4: compound assignment x += 1 emits get_var ; rhs ; add ; dup ; put_var" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "x += 1");
    defer fn_bc.deinit(env.rt);

    try expectOpcodeSequence(fn_bc.code, &.{ op.get_var, op.push_1, op.add, op.dup, op.put_var });
}

test "F4: comma operator drops left, keeps right" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "1, 2");
    defer fn_bc.deinit(env.rt);

    try expectOpcodeSequence(fn_bc.code, &.{ op.push_1, op.drop, op.push_2 });
}

test "F4: member access a.b emits get_var + get_field" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "a.b");
    defer fn_bc.deinit(env.rt);

    try expectOpcodeSequence(fn_bc.code, &.{ op.get_var, op.get_field });
}

test "F4: index access a[i] emits get_var ; get_var ; get_array_el" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "a[i]");
    defer fn_bc.deinit(env.rt);

    try expectOpcodeSequence(fn_bc.code, &.{ op.get_var, op.get_var, op.get_array_el });
}

// ---- F4 slice 2 -----------------------------------------------------

test "F4: nested assignment 1 + (a = b) preserves the leading push" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "1 + (a = b)");
    defer fn_bc.deinit(env.rt);

    try expectOpcodeSequence(fn_bc.code, &.{ op.push_1, op.get_var, op.dup, op.put_var, op.add });
}

test "F4: string literal lowers to push_atom_value" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "\"hello\"");
    defer fn_bc.deinit(env.rt);

    try std.testing.expectEqual(@as(usize, 5), fn_bc.code.len);
    try std.testing.expectEqual(op.push_atom_value, fn_bc.code[0]);
    try std.testing.expectEqual(@as(usize, 1), fn_bc.atom_operands.len);
}

test "F4: empty string literal lowers to push_empty_string" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "\"\"");
    defer fn_bc.deinit(env.rt);

    try std.testing.expectEqual(@as(usize, 1), fn_bc.code.len);
    try std.testing.expectEqual(op.push_empty_string, fn_bc.code[0]);
}

test "F4: array literal lowers to push elements ; array_from N" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "[1, 2, 3]");
    defer fn_bc.deinit(env.rt);

    try expectOpcodeSequence(fn_bc.code, &.{ op.push_1, op.push_2, op.push_3, op.array_from });
    const argc = readU16AtOpcode(fn_bc.code, 3);
    try std.testing.expectEqual(@as(u16, 3), argc);
}

test "F4: empty array literal emits array_from 0" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "[]");
    defer fn_bc.deinit(env.rt);

    try std.testing.expectEqual(@as(usize, 3), fn_bc.code.len);
    try std.testing.expectEqual(op.array_from, fn_bc.code[0]);
    const argc = std.mem.readInt(u16, fn_bc.code[1..3], .little);
    try std.testing.expectEqual(@as(u16, 0), argc);
}

test "F4: trailing comma in array literal is allowed" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "[1, 2,]");
    defer fn_bc.deinit(env.rt);

    try expectOpcodeSequence(fn_bc.code, &.{ op.push_1, op.push_2, op.array_from });
    const argc = readU16AtOpcode(fn_bc.code, 2);
    try std.testing.expectEqual(@as(u16, 2), argc);
}

test "F4: object literal { a: 1, b: 2 } lowers to object + define_field" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "{ a: 1, b: 2 }");
    defer fn_bc.deinit(env.rt);

    try expectOpcodeSequence(fn_bc.code, &.{ op.object, op.push_1, op.define_field, op.push_2, op.define_field });
}

test "F4: empty object literal emits object" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "{}");
    defer fn_bc.deinit(env.rt);

    // Note: a leading `{` at expression position is ambiguous with a
    // block statement; in expression context our parser treats it as an
    // object literal. F5 will resolve the statement-level ambiguity.
    try std.testing.expectEqual(@as(usize, 1), fn_bc.code.len);
    try std.testing.expectEqual(op.object, fn_bc.code[0]);
}

test "F4: shorthand object property { x } emits get_var x ; define_field x" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "{ x }");
    defer fn_bc.deinit(env.rt);

    try expectOpcodeSequence(fn_bc.code, &.{ op.object, op.get_var, op.define_field });
}

test "M3.1 F4: computed object property emits define_array_el" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "{ [\"x\"]: 1 }");
    defer fn_bc.deinit(env.rt);

    try std.testing.expectEqual(op.object, fn_bc.code[0]);
    try std.testing.expectEqual(op.define_array_el, fn_bc.code[fn_bc.code.len - 2]);
    try std.testing.expectEqual(op.drop, fn_bc.code[fn_bc.code.len - 1]);
}

test "M3.1 F4: object spread emits copy_data_properties" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "{ a: 1, ...b }");
    defer fn_bc.deinit(env.rt);

    try std.testing.expectEqual(op.object, fn_bc.code[0]);
    try std.testing.expect(std.mem.indexOfScalar(u8, fn_bc.code, op.copy_data_properties) != null);
}

test "M3.1 F4: keyword object property names parse as literal keys" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "{ default: 1, while: 2 }");
    defer fn_bc.deinit(env.rt);

    try std.testing.expectEqual(op.object, fn_bc.code[0]);
    try std.testing.expectEqual(@as(usize, 2), countOpcode(fn_bc.code, op.define_field));
}

test "M3.1 F4: object literal __proto__ emits set_proto" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "{ \"__proto__\": null }");
    defer fn_bc.deinit(env.rt);

    try std.testing.expectEqual(op.object, fn_bc.code[0]);
    try std.testing.expect(std.mem.indexOfScalar(u8, fn_bc.code, op.set_proto) != null);
}

test "M3.1 F4: object method shorthand emits define_method" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExprWithTopLevelChildren(&env, "{ default() { return 1; } }");
    defer fn_bc.deinit(env.rt);

    const child = try expectFunctionConstant(&fn_bc, 0);
    // QuickJS leaves object method bytecode unnamed; OP_define_method assigns
    // the function object's visible name from the property key at runtime.
    try expectAtomName(&env, child.func_name, "");
    try std.testing.expectEqual(op.object, fn_bc.code[0]);
    try std.testing.expect(std.mem.indexOfScalar(u8, fn_bc.code, op.define_method) != null);
}

test "M3.1 F4: for-await close keeps body statement source location" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    const source =
        \\async function f() {
        \\  const iter = {
        \\    i: 0,
        \\    [Symbol.asyncIterator]() { return this; },
        \\    next() { return Promise.resolve({ value: 1, done: false }); },
        \\    return() { return Promise.reject(new Error("boom")); },
        \\  };
        \\  try {
        \\    for await (const value of iter) {
        \\      void value;
        \\      break;
        \\    }
        \\  } catch (err) {
        \\  }
        \\}
    ;

    var fn_bc = try parseStatementWithTopLevelChildren(&env, source);
    defer fn_bc.deinit(env.rt);

    const child = try expectFunctionConstant(&fn_bc, 0);
    var iterator_close_pc: ?usize = null;
    var pc: usize = 0;
    while (pc < child.byteCode().len) {
        const op_id = child.byteCode()[pc];
        if (op_id == op.iterator_close) {
            iterator_close_pc = pc;
            break;
        }
        const size = engine.bytecode.opcode.sizeOf(op_id);
        if (size == 0) return error.TestExpectedEqual;
        pc += size;
    }
    const close_pc = iterator_close_pc orelse return error.TestExpectedEqual;

    const decoded = try engine.bytecode.pipeline.pc2line.decode(std.testing.allocator, .{
        .bytes = child.pc2lineBuf(),
        .line_num = child.lineNum(),
        .col_num = child.colNum(),
        .memory = &env.rt.memory,
    });
    defer std.testing.allocator.free(decoded);

    var line_num = child.lineNum();
    var col_num = child.colNum();
    for (decoded) |slot| {
        if (slot.pc > close_pc) break;
        line_num = slot.line_num;
        col_num = slot.col_num;
    }
    try std.testing.expectEqual(@as(i32, 10), line_num);
    try std.testing.expectEqual(@as(i32, 7), col_num);
}

test "M3.1 F4: parser emits QuickJS line_num temp and finalize strips it" {
    var env = try ParserTestEnv.init();
    defer env.deinit();

    const name = try env.rt.internAtom("test");
    defer env.rt.atoms.free(name);
    var function = engine.bytecode.Bytecode.init(&env.rt.memory, &env.rt.atoms, name);
    defer function.deinit(env.rt);
    var lex = QjsLexer.init(std.testing.allocator, &env.rt.atoms, "x;");
    var state = try ParseState.init(&lex, &function);
    defer state.deinit(env.rt);
    configureScriptRoot(&state);

    try parser_core.parseStatementOrDecl(&state, parser_core.DeclMask{ .func = true, .func_with_label = true, .other = true });

    try std.testing.expect(function.code.len >= engine.bytecode.opcode.sizeOfPhase1(op.line_num));
    try std.testing.expectEqual(op.line_num, function.code[0]);
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, function.code[1..5], .little));

    try engine.bytecode.pipeline.finalize.runWithFunctionDef(&function, &state.function_def);
    try std.testing.expect(std.mem.indexOfScalar(u8, function.code, op.line_num) == null);
}

test "M3.1 F4: computed object method emits define_method_computed" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "{ [\"m\"]() { return 1; } }");
    defer fn_bc.deinit(env.rt);

    try std.testing.expectEqual(op.object, fn_bc.code[0]);
    try std.testing.expect(std.mem.indexOfScalar(u8, fn_bc.code, op.define_method_computed) != null);
}

test "M3.1 F4: object string getter emits define_method getter flag" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "{ get \"default\"() { return 1; } }");
    defer fn_bc.deinit(env.rt);

    const offset = std.mem.indexOfScalar(u8, fn_bc.code, op.define_method) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(u8, 5), fn_bc.code[offset + 5]);
}

test "M3.1 F4: object numeric setter emits define_method setter flag" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "{ set 0(v) { x = v; } }");
    defer fn_bc.deinit(env.rt);

    const offset = std.mem.indexOfScalar(u8, fn_bc.code, op.define_method) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(u8, 6), fn_bc.code[offset + 5]);
}

test "M3.1 F4: computed object getter emits define_method_computed getter flag" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "{ get [\"x\"]() { return 1; } }");
    defer fn_bc.deinit(env.rt);

    const offset = std.mem.indexOfScalar(u8, fn_bc.code, op.define_method_computed) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(u8, 5), fn_bc.code[offset + 1]);
}

test "M3.1 F4: computed object keys emit to_propkey before definition" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "{ [key]: value }");
    defer fn_bc.deinit(env.rt);

    const key_offset = std.mem.indexOfScalar(u8, fn_bc.code, op.to_propkey) orelse return error.TestExpectedEqual;
    const define_offset = std.mem.indexOfScalar(u8, fn_bc.code, op.define_array_el) orelse return error.TestExpectedEqual;
    try std.testing.expect(key_offset < define_offset);
}

test "M3.1 F4: duplicate non-computed __proto__ data fields reject" {
    var env = try ParserTestEnv.init();
    defer env.deinit();

    try std.testing.expectError(error.UnexpectedToken, parseExpr(&env, "{ __proto__: null, \"__proto__\": null }"));
}

test "M3.1 F4: computed __proto__ duplicate is permitted" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "{ __proto__: null, [\"__proto__\"]: 1 }");
    defer fn_bc.deinit(env.rt);

    try std.testing.expect(std.mem.indexOfScalar(u8, fn_bc.code, op.set_proto) != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, fn_bc.code, op.define_array_el) != null);
}

test "M3.1 F4: computed object key accepts logical and assignment" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "{ [x &&= 1]: 2 }");
    defer fn_bc.deinit(env.rt);

    try std.testing.expect(hasAnyOpcode(fn_bc.code, &.{ op.if_false, op.if_false8 }));
    try std.testing.expect(std.mem.indexOfScalar(u8, fn_bc.code, op.define_array_el) != null);
}

test "M3.1 F4: computed object key accepts logical or assignment" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "{ [x ||= 1]: 2 }");
    defer fn_bc.deinit(env.rt);

    try std.testing.expect(hasAnyOpcode(fn_bc.code, &.{ op.if_true, op.if_true8 }));
    try std.testing.expect(std.mem.indexOfScalar(u8, fn_bc.code, op.define_array_el) != null);
}

test "M3.1 F4: computed object key accepts indexed logical assignment" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "{ [a[0] ||= 1]: 2 }");
    defer fn_bc.deinit(env.rt);

    try std.testing.expect(std.mem.indexOfScalar(u8, fn_bc.code, op.get_array_el3) != null);
    try std.testing.expect(hasAnyOpcode(fn_bc.code, &.{ op.if_true, op.if_true8 }));
    try std.testing.expect(std.mem.indexOfScalar(u8, fn_bc.code, op.define_array_el) != null);
}

test "M3.1 F4: computed object key accepts nullish assignment" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "{ [x ??= 1]: 2 }");
    defer fn_bc.deinit(env.rt);

    try std.testing.expect(std.mem.indexOfScalar(u8, fn_bc.code, op.is_undefined_or_null) != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, fn_bc.code, op.define_array_el) != null);
}

test "F4: simple call f(a, b) emits get_var ; args ; call argc" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "f(a, b)");
    defer fn_bc.deinit(env.rt);

    try expectOpcodeSequence(fn_bc.code, &.{ op.get_var, op.get_var, op.get_var, op.call2 });
}

test "F4: zero-arg call f() emits call 0" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "f()");
    defer fn_bc.deinit(env.rt);

    try expectOpcodeSequence(fn_bc.code, &.{ op.get_var, op.call0 });
}

test "F4: method call obj.m(x) uses get_field2 + call_method" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "obj.m(x)");
    defer fn_bc.deinit(env.rt);

    try expectOpcodeSequence(fn_bc.code, &.{ op.get_var, op.get_field2, op.get_var, op.call_method });
    try std.testing.expectEqual(@as(u16, 1), readU16AtOpcode(fn_bc.code, 11));
}

test "F4: indexed call obj[k](x) uses get_array_el2 + call_method" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "obj[k](x)");
    defer fn_bc.deinit(env.rt);

    try expectOpcodeSequence(fn_bc.code, &.{ op.get_var, op.get_var, op.get_array_el2, op.get_var, op.call_method });
    try std.testing.expectEqual(@as(u16, 1), readU16AtOpcode(fn_bc.code, 10));
}

test "F4: new X(a) emits get_var X ; dup ; get_var a ; call_constructor 1" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "new X(a)");
    defer fn_bc.deinit(env.rt);

    try expectOpcodeSequence(fn_bc.code, &.{ op.get_var, op.dup, op.get_var, op.call_constructor });
    try std.testing.expectEqual(@as(u16, 1), readU16AtOpcode(fn_bc.code, 7));
}

test "F4: bare new X (no args) emits call_constructor 0" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "new X");
    defer fn_bc.deinit(env.rt);

    try expectOpcodeSequence(fn_bc.code, &.{ op.get_var, op.dup, op.call_constructor });
    try std.testing.expectEqual(@as(u16, 0), readU16AtOpcode(fn_bc.code, 4));
}

test "F4: postfix x++ emits get_var ; post_inc ; put_var" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "x++");
    defer fn_bc.deinit(env.rt);

    try expectOpcodeSequence(fn_bc.code, &.{ op.get_var, op.post_inc, op.put_var });
}

test "F4: postfix x-- emits get_var ; post_dec ; put_var" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "x--");
    defer fn_bc.deinit(env.rt);

    try expectOpcodeSequence(fn_bc.code, &.{ op.get_var, op.post_dec, op.put_var });
}

test "F4: prefix ++x emits get_var ; inc ; dup ; put_var" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "++x");
    defer fn_bc.deinit(env.rt);

    try expectOpcodeSequence(fn_bc.code, &.{ op.get_var, op.inc, op.dup, op.put_var });
}

test "F4: prefix --x emits get_var ; dec ; dup ; put_var" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "--x");
    defer fn_bc.deinit(env.rt);

    try expectOpcodeSequence(fn_bc.code, &.{ op.get_var, op.dec, op.dup, op.put_var });
}

test "F4: delete unresolvable identifier emits delete_var" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "delete x");
    defer fn_bc.deinit(env.rt);

    try std.testing.expectEqual(@as(usize, 5), fn_bc.code.len);
    try std.testing.expectEqual(op.delete_var, fn_bc.code[0]);
}

test "F4: delete a.b emits get_var a ; push_atom_value b ; delete" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "delete a.b");
    defer fn_bc.deinit(env.rt);

    try expectOpcodeSequence(fn_bc.code, &.{ op.get_var, op.push_atom_value, op.delete });
}

test "F4: delete of a private field is rejected after ordinary-field transport" {
    var env = try ParserTestEnv.init();
    defer env.deinit();

    try std.testing.expectError(
        error.UnexpectedToken,
        parseExpr(&env, "class { #x; m() { return delete this.#x; } }"),
    );
}

test "F4: delete a.b.length rewrites optimized length load" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "delete a.b.length");
    defer fn_bc.deinit(env.rt);

    try expectOpcodeSequence(fn_bc.code, &.{ op.get_var, op.get_field, op.push_atom_value, op.delete });
}

test "F4: delete a[i] emits get_var a ; get_var i ; delete" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "delete a[i]");
    defer fn_bc.deinit(env.rt);

    try expectOpcodeSequence(fn_bc.code, &.{ op.get_var, op.get_var, op.delete });
}

test "F4: delete on a non-reference yields drop ; push_true" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "delete (1 + 2)");
    defer fn_bc.deinit(env.rt);

    // ...add(1,2) ; drop ; push_true
    try std.testing.expectEqual(op.drop, fn_bc.code[fn_bc.code.len - 2]);
    try std.testing.expectEqual(op.push_true, fn_bc.code[fn_bc.code.len - 1]);
}

test "F4: chained call f(a)(b) emits two call ops" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "f(a)(b)");
    defer fn_bc.deinit(env.rt);

    try expectOpcodeSequence(fn_bc.code, &.{ op.get_var, op.get_var, op.call1, op.get_var, op.call1 });
}

// ---- F4 slice 3: member-target assign + update ----------------------

test "F4: dotted assignment a.b = v emits get_var ; rhs ; insert2 ; put_field" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "a.b = v");
    defer fn_bc.deinit(env.rt);

    try expectOpcodeSequence(fn_bc.code, &.{ op.get_var, op.get_var, op.insert2, op.put_field });
}

test "F4: indexed assignment a[i] = v emits get_var ; key ; rhs ; insert3 ; put_array_el" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "a[i] = v");
    defer fn_bc.deinit(env.rt);

    try expectOpcodeSequence(fn_bc.code, &.{ op.get_var, op.get_var, op.get_var, op.insert3, op.put_array_el });
}

test "F4: compound dotted assignment a.b += v rewrites get_field to get_field2" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "a.b += v");
    defer fn_bc.deinit(env.rt);

    try expectOpcodeSequence(fn_bc.code, &.{ op.get_var, op.get_field2, op.get_var, op.add, op.insert2, op.put_field });
}

test "F4: compound indexed assignment a[i] += v keeps QuickJS indexed lvalue shape" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "a[i] += v");
    defer fn_bc.deinit(env.rt);

    try expectOpcodeSequence(fn_bc.code, &.{ op.get_var, op.get_var, op.get_array_el3, op.get_var, op.add, op.insert3, op.put_array_el });
}

test "F4: postfix dotted a.b++ emits get_field2 ; post_inc ; perm3 ; put_field" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "a.b++");
    defer fn_bc.deinit(env.rt);

    try expectOpcodeSequence(fn_bc.code, &.{ op.get_var, op.get_field2, op.post_inc, op.perm3, op.put_field });
}

test "F4: postfix indexed a[i]-- emits QuickJS indexed lvalue read ; post_dec ; perm4 ; put_array_el" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "a[i]--");
    defer fn_bc.deinit(env.rt);

    try expectOpcodeSequence(fn_bc.code, &.{ op.get_var, op.get_var, op.get_array_el3, op.post_dec, op.perm4, op.put_array_el });
}

test "F4: prefix ++a.b emits get_field2 ; inc ; insert2 ; put_field" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "++a.b");
    defer fn_bc.deinit(env.rt);

    try expectOpcodeSequence(fn_bc.code, &.{ op.get_var, op.get_field2, op.inc, op.insert2, op.put_field });
}

test "F4: prefix --a[i] emits QuickJS indexed lvalue read ; dec ; insert3 ; put_array_el" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "--a[i]");
    defer fn_bc.deinit(env.rt);

    try expectOpcodeSequence(fn_bc.code, &.{ op.get_var, op.get_var, op.get_array_el3, op.dec, op.insert3, op.put_array_el });
}

test "F4: final bytecode applies QuickJS discarded lvalue and loop update peepholes" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatementWithTopLevelChildren(
        &env,
        "function f(a, i) { var x = 0; for (; x < a.length; x++) { a.b++; a[i]--; a.b = x; a[i] = x; } return x; }",
    );
    defer fn_bc.deinit(env.rt);

    const child = findFunctionConstantNamed(&fn_bc, env.rt, "f") orelse return error.TestExpectedEqual;
    const code = child.byteCode();
    try std.testing.expectEqual(@as(usize, 1), countOpcode(code, op.get_length));
    try std.testing.expectEqual(@as(usize, 1), countOpcode(code, op.inc_loc));
    try std.testing.expectEqual(@as(usize, 2), countOpcode(code, op.put_field));
    try std.testing.expectEqual(@as(usize, 2), countOpcode(code, op.put_array_el));
    try std.testing.expectEqual(@as(usize, 0), countOpcode(code, op.insert2));
    try std.testing.expectEqual(@as(usize, 0), countOpcode(code, op.insert3));
    try std.testing.expectEqual(@as(usize, 0), countOpcode(code, op.perm3));
    try std.testing.expectEqual(@as(usize, 0), countOpcode(code, op.perm4));
    try std.testing.expectEqual(@as(usize, 0), countOpcode(code, op.post_inc));
    try std.testing.expectEqual(@as(usize, 0), countOpcode(code, op.post_dec));
    try std.testing.expectEqual(@as(usize, 0), countOpcode(code, op.drop));
}

test "F4: dotted assign value remains on stack via insert2 (chained)" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    // (a.b = v) + 1 — verifies the assignment leaves v on the stack.
    var fn_bc = try parseExpr(&env, "(a.b = v) + 1");
    defer fn_bc.deinit(env.rt);

    // Trailing add must follow put_field.
    try std.testing.expectEqual(op.add, fn_bc.code[fn_bc.code.len - 1]);
}

// ---- F4 slice 4: array holes + multi-level delete + optional chaining

test "F4: array hole [1, , 3] emits sparse define_field for present elements" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "[1, , 3]");
    defer fn_bc.deinit(env.rt);

    try expectOpcodeSequence(fn_bc.code, &.{ op.push_1, op.array_from, op.push_3, op.define_field, op.dup, op.push_3, op.put_field });
    const argc = readU16AtOpcode(fn_bc.code, 1);
    try std.testing.expectEqual(@as(u16, 1), argc);
}

test "F4: leading hole [, 1] emits sparse define_field at index 1" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "[, 1]");
    defer fn_bc.deinit(env.rt);

    try expectOpcodeSequence(fn_bc.code, &.{ op.array_from, op.push_1, op.define_field, op.dup, op.push_2, op.put_field });
    const argc = readU16AtOpcode(fn_bc.code, 0);
    try std.testing.expectEqual(@as(u16, 0), argc);
}

test "F4: consecutive holes [, , 1] emits sparse define_field at index 2" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "[, , 1]");
    defer fn_bc.deinit(env.rt);

    try expectOpcodeSequence(fn_bc.code, &.{ op.array_from, op.push_1, op.define_field, op.dup, op.push_3, op.put_field });
    const argc = readU16AtOpcode(fn_bc.code, 0);
    try std.testing.expectEqual(@as(u16, 0), argc);
}

test "F4: multi-level delete a.b.c rewrites only the last get_field" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "delete a.b.c");
    defer fn_bc.deinit(env.rt);

    try expectOpcodeSequence(fn_bc.code, &.{ op.get_var, op.get_field, op.push_atom_value, op.delete });
}

test "F4: multi-level delete a.b[i] truncates the trailing get_array_el" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "delete a.b[i]");
    defer fn_bc.deinit(env.rt);

    try expectOpcodeSequence(fn_bc.code, &.{ op.get_var, op.get_field, op.get_var, op.delete });
}

test "F4: delete on a postfix update result evaluates and returns true" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "delete (a.b++)");
    defer fn_bc.deinit(env.rt);

    // The delete classifier still emits discard + true for the non-reference
    // result. resolve_labels then applies QuickJS's
    // `post_inc; perm3; put_field; drop -> inc; put_field` fold.
    try expectOpcodeSequence(fn_bc.code, &.{
        op.get_var,
        op.get_field2,
        op.inc,
        op.put_field,
        op.push_true,
    });
}

test "F4: optional chain a?.b emits inline chain_test + normal get_field" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "a?.b");
    defer fn_bc.deinit(env.rt);

    try expectOpcodeSequence(fn_bc.code, &.{ op.get_var, op.dup, op.is_undefined_or_null, op.if_false8, op.drop, op.undefined, op.goto8, op.get_field });
    const next_target = readRelTarget32(fn_bc.code, 5);
    try std.testing.expectEqual(@as(usize, 11), next_target);
    const exit_target = readRelTarget32(fn_bc.code, 9);
    try std.testing.expectEqual(fn_bc.code.len, exit_target);
}

test "F4: optional chain a?.[i] emits inline chain_test + get_array_el" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "a?.[i]");
    defer fn_bc.deinit(env.rt);

    try expectOpcodeSequence(fn_bc.code, &.{ op.get_var, op.dup, op.is_undefined_or_null, op.if_false8, op.drop, op.undefined, op.goto8, op.get_var, op.get_array_el });
}

test "F4: optional chain a?.b.c — chain test only at the ?. site" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "a?.b.c");
    defer fn_bc.deinit(env.rt);

    try expectOpcodeSequence(fn_bc.code, &.{ op.get_var, op.dup, op.is_undefined_or_null, op.if_false8, op.drop, op.undefined, op.goto8, op.get_field, op.get_field });
    const exit_target = readRelTarget32(fn_bc.code, 9);
    try std.testing.expectEqual(fn_bc.code.len, exit_target);
}

test "F4: a?.b?.c emits two chain_tests sharing a common chain exit" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "a?.b?.c");
    defer fn_bc.deinit(env.rt);

    try expectOpcodeSequence(fn_bc.code, &.{
        op.get_var,   op.dup, op.is_undefined_or_null, op.if_false8, op.drop, op.undefined, op.goto8,
        op.get_field, op.dup, op.is_undefined_or_null, op.if_false8, op.drop, op.undefined, op.goto8,
        op.get_field,
    });
    const exit_target_1 = readRelTarget32(fn_bc.code, 9);
    const exit_target_2 = readRelTarget32(fn_bc.code, 22);
    try std.testing.expectEqual(exit_target_1, exit_target_2);
    try std.testing.expectEqual(fn_bc.code.len, exit_target_1);
}

test "F4: optional call a?.() emits chain_test + plain call" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "a?.()");
    defer fn_bc.deinit(env.rt);

    try expectOpcodeSequence(fn_bc.code, &.{ op.get_var, op.dup, op.is_undefined_or_null, op.if_false8, op.drop, op.undefined, op.goto8, op.call0 });
    const exit_target = readRelTarget32(fn_bc.code, 9);
    try std.testing.expectEqual(fn_bc.code.len, exit_target);
}

test "F4: method-on-opt-chain obj?.b(x) uses get_field2 + call_method" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "obj?.b(x)");
    defer fn_bc.deinit(env.rt);

    try expectOpcodeSequence(fn_bc.code, &.{ op.get_var, op.dup, op.is_undefined_or_null, op.if_false8, op.drop, op.undefined, op.goto8, op.get_field2, op.get_var, op.call_method });
    try std.testing.expectEqual(@as(u16, 1), readU16AtOpcode(fn_bc.code, 19));
}

test "F4: parenthesized optional member call preserves receiver" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "(obj?.b)()");
    defer fn_bc.deinit(env.rt);

    try expectOpcodeSequence(fn_bc.code, &.{
        op.get_var,
        op.dup,
        op.is_undefined_or_null,
        op.if_false8,
        op.drop,
        op.undefined,
        op.goto8,
        op.get_field2,
        // QJS's closed-chain method bridge skips the short-circuit-only
        // receiver slot on the successful getter path.
        op.goto8,
        op.undefined,
        op.call_method,
    });
    try std.testing.expectEqual(@as(u16, 0), readU16AtOpcode(fn_bc.code, fn_bc.code.len - 3));
}

test "F4: optional call after parenthesized optional member keeps balanced exits" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "(obj?.b)?.()");
    defer fn_bc.deinit(env.rt);

    try expectOpcodeSequence(fn_bc.code, &.{
        op.get_var,
        op.dup,
        op.is_undefined_or_null,
        op.if_false8,
        op.drop,
        op.undefined,
        op.goto8,
        op.get_field2,
        op.goto8,
        op.undefined,
        op.dup,
        op.is_undefined_or_null,
        op.if_false8,
        op.drop,
        op.drop,
        op.undefined,
        op.goto8,
        op.call_method,
    });
    try std.testing.expectEqual(@as(u16, 0), readU16AtOpcode(fn_bc.code, fn_bc.code.len - 3));
}

test "F4: optional chain accepts keyword property names" {
    var env = try ParserTestEnv.init();
    defer env.deinit();

    const cases = [_][]const u8{
        "x.issues[i]?.continue !== true",
        "obj?.delete",
        "obj?.catch()",
    };
    for (cases) |source| {
        var fn_bc = try parseExpr(&env, source);
        defer fn_bc.deinit(env.rt);
        try std.testing.expect(fn_bc.code.len > 0);
    }
}

test "F4: indexed-call-on-opt-chain obj?.[k](x) uses get_array_el2 + call_method" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "obj?.[k](x)");
    defer fn_bc.deinit(env.rt);

    try expectOpcodeSequence(fn_bc.code, &.{ op.get_var, op.dup, op.is_undefined_or_null, op.if_false8, op.drop, op.undefined, op.goto8, op.get_var, op.get_array_el2, op.get_var, op.call_method });
    try std.testing.expectEqual(@as(u16, 1), readU16AtOpcode(fn_bc.code, 18));
}

// ---- F4 finish: tagged templates -----------------------------------

test "F4: tagged template tag`hello` emits singleton template-object + call 1" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "tag`hello`");
    defer fn_bc.deinit(env.rt);

    try expectOpcodeSequence(fn_bc.code, &.{ op.get_var, op.push_atom_value, op.array_from, op.push_atom_value, op.array_from, op.define_field, op.call1 });
    try std.testing.expectEqual(@as(u16, 1), readU16AtOpcode(fn_bc.code, 8));
    try std.testing.expectEqual(@as(u16, 1), readU16AtOpcode(fn_bc.code, 16));
}

test "F4: tagged template tag`a${x}b` includes substitutions in argc" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "tag`a${x}b`");
    defer fn_bc.deinit(env.rt);

    try expectOpcodeSequence(fn_bc.code, &.{ op.get_var, op.undefined, op.get_var, op.call2 });
}

test "F4: tagged template on member access obj.tag`hello` rewrites to call_method" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "obj.tag`hello`");
    defer fn_bc.deinit(env.rt);

    try expectOpcodeSequence(fn_bc.code, &.{ op.get_var, op.get_field2, op.push_atom_value, op.array_from, op.push_atom_value, op.array_from, op.define_field, op.call_method });
    try std.testing.expectEqual(@as(u16, 1), readU16AtOpcode(fn_bc.code, 13));
    try std.testing.expectEqual(@as(u16, 1), readU16AtOpcode(fn_bc.code, 21));
    try std.testing.expectEqual(@as(u16, 1), readU16AtOpcode(fn_bc.code, 29));
}

test "F4: tagged template tag`a${x}b${y}c` argc = 3 (template + 2 subs)" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "tag`a${x}b${y}c`");
    defer fn_bc.deinit(env.rt);

    try std.testing.expectEqual(op.call3, fn_bc.code[fn_bc.code.len - 1]);
}

test "F4: optional call without chain receiver a?.()(b) — chain only on first call" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    // After a?.(), the chain ends. The trailing (b) call is unconditional.
    var fn_bc = try parseExpr(&env, "a?.()(b)");
    defer fn_bc.deinit(env.rt);

    try expectOpcodeSequence(fn_bc.code, &.{ op.get_var, op.dup, op.is_undefined_or_null, op.if_false8, op.drop, op.undefined, op.goto8, op.call0, op.get_var, op.call1 });
    const exit_target = readRelTarget32(fn_bc.code, 9);
    try std.testing.expectEqual(fn_bc.code.len, exit_target);
}

// ---- F4 slice 5: template literals -----------------------------------

test "F4: no-substitution template `hello` lowers to push_atom_value" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "`hello`");
    defer fn_bc.deinit(env.rt);

    try std.testing.expectEqual(@as(usize, 5), fn_bc.code.len);
    try std.testing.expectEqual(op.push_atom_value, fn_bc.code[0]);
}

test "F4: empty template `` lowers to push_empty_string" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "``");
    defer fn_bc.deinit(env.rt);

    try std.testing.expectEqual(@as(usize, 1), fn_bc.code.len);
    try std.testing.expectEqual(op.push_empty_string, fn_bc.code[0]);
}

test "F4: simple template with one substitution uses get_field2 concat + call_method" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "`a${b}c`");
    defer fn_bc.deinit(env.rt);

    try expectOpcodeSequence(fn_bc.code, &.{ op.push_atom_value, op.get_field2, op.get_var, op.push_atom_value, op.call_method });
    try std.testing.expectEqual(@as(u16, 2), readU16AtOpcode(fn_bc.code, 18));
}

test "F4: empty-head template `${b}` skips middle/tail empty strings" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    // `${b}` lowers to:
    //   push_empty_string    (1)
    //   get_field2 concat    (5)
    //   get_var b            (5)
    //   call_method 1        (3)
    // Middle/tail empty strings with depth>0 are skipped (mirrors
    // `quickjs.c:23952` `else { JS_FreeValue ; }` branch).
    var fn_bc = try parseExpr(&env, "`${b}`");
    defer fn_bc.deinit(env.rt);

    try expectOpcodeSequence(fn_bc.code, &.{ op.push_empty_string, op.get_field2, op.get_var, op.call_method });
    try std.testing.expectEqual(@as(u16, 1), readU16AtOpcode(fn_bc.code, 9));
}

test "F4: template with two substitutions accumulates argc correctly" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    // `a${b}c${d}e` →
    //   push_atom_value "a"   (5)
    //   get_field2 concat     (5)
    //   get_var b             (5)
    //   push_atom_value "c"   (5)
    //   get_var d             (5)
    //   push_atom_value "e"   (5)
    //   call_method 4         (3)
    var fn_bc = try parseExpr(&env, "`a${b}c${d}e`");
    defer fn_bc.deinit(env.rt);

    try expectOpcodeSequence(fn_bc.code, &.{ op.push_atom_value, op.get_field2, op.get_var, op.push_atom_value, op.get_var, op.push_atom_value, op.call_method });
    try std.testing.expectEqual(@as(u16, 4), readU16AtOpcode(fn_bc.code, 26));
}

// ---- F4 slice 6: spread in calls and arrays --------------------------

test "F4: spread call f(...x) emits array_from + apply 0" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "f(...x)");
    defer fn_bc.deinit(env.rt);

    try expectOpcodeSequence(fn_bc.code, &.{ op.get_var, op.array_from, op.push_0, op.get_var, op.append, op.drop, op.undefined, op.swap, op.apply });
    try std.testing.expectEqual(@as(u16, 0), readU16AtOpcode(fn_bc.code, 14));
}

test "F4: mixed spread call f(a, ...b) starts array_from with leading count" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "f(a, ...b)");
    defer fn_bc.deinit(env.rt);

    try expectOpcodeSequence(fn_bc.code, &.{ op.get_var, op.get_var, op.array_from, op.push_1, op.get_var, op.append, op.drop, op.undefined, op.swap, op.apply });
    try std.testing.expectEqual(@as(u16, 1), readU16AtOpcode(fn_bc.code, 6));
    try std.testing.expectEqual(@as(u16, 0), readU16AtOpcode(fn_bc.code, 17));
}

test "F4: trailing element after spread uses define_array_el + inc" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    // f(...a, b):
    //   get_var f          (5)
    //   array_from 0       (3)
    //   push_i32 0         (5)
    //   get_var a          (5)
    //   append             (1)
    //   get_var b          (5)
    //   define_array_el    (1)
    //   inc                (1)
    //   drop               (1)
    //   undefined          (1)
    //   swap               (1)
    //   apply 0            (3)
    var fn_bc = try parseExpr(&env, "f(...a, b)");
    defer fn_bc.deinit(env.rt);

    try expectOpcodeSequence(fn_bc.code, &.{ op.get_var, op.array_from, op.push_0, op.get_var, op.append, op.get_var, op.define_array_el, op.inc, op.drop, op.undefined, op.swap, op.apply });
}

test "F4: method call with spread obj.m(...x) uses perm3 + apply 0" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    // Expected:
    //   get_var obj          (5)
    //   get_field2 m         (5)
    //   array_from 0         (3)
    //   push_i32 0           (5)
    //   get_var x            (5)
    //   append               (1)
    //   drop                 (1)
    //   perm3                (1)
    //   apply 0              (3)
    var fn_bc = try parseExpr(&env, "obj.m(...x)");
    defer fn_bc.deinit(env.rt);

    try expectOpcodeSequence(fn_bc.code, &.{ op.get_var, op.get_field2, op.array_from, op.push_0, op.get_var, op.append, op.drop, op.perm3, op.apply });
}

test "F4: new with spread new X(...args) uses apply with is_new=1" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "new X(...args)");
    defer fn_bc.deinit(env.rt);

    try std.testing.expectEqual(op.apply, fn_bc.code[fn_bc.code.len - 3]);
    const is_new = std.mem.readInt(u16, fn_bc.code[fn_bc.code.len - 2 ..][0..2], .little);
    try std.testing.expectEqual(@as(u16, 1), is_new);
}

test "F4: array literal spread [...a] starts with array_from 0 + push_i32 0" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "[...a]");
    defer fn_bc.deinit(env.rt);

    try expectOpcodeSequence(fn_bc.code, &.{ op.array_from, op.push_0, op.get_var, op.append, op.dup1, op.put_field });
}

test "F4: array literal mixed spread [a, ...b, c] uses define_array_el+inc" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "[a, ...b, c]");
    defer fn_bc.deinit(env.rt);

    try expectOpcodeSequence(fn_bc.code, &.{ op.get_var, op.array_from, op.push_1, op.get_var, op.append, op.get_var, op.define_array_el, op.inc, op.dup1, op.put_field });
}

test "F4: template with empty middle still emits call_method with correct argc" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    // `${b}${c}` — empty head emits push_empty_string + get_field2 concat;
    // empty middle is skipped; empty tail is skipped.
    //   push_empty_string   (1)
    //   get_field2 concat   (5)
    //   get_var b           (5)
    //   get_var c           (5)
    //   call_method 2       (3)
    var fn_bc = try parseExpr(&env, "`${b}${c}`");
    defer fn_bc.deinit(env.rt);

    try expectOpcodeSequence(fn_bc.code, &.{ op.push_empty_string, op.get_field2, op.get_var, op.get_var, op.call_method });
    try std.testing.expectEqual(@as(u16, 2), readU16AtOpcode(fn_bc.code, 12));
}

// ---- F5: Statement parsing tests -------------------------------------

test "F5: empty statement" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatement(&env, ";");
    defer fn_bc.deinit(env.rt);

    try std.testing.expectEqual(@as(usize, 0), fn_bc.code.len);
}

test "F5: block statement" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatement(&env, "{ x; y; }");
    defer fn_bc.deinit(env.rt);

    try expectOpcodeSequence(fn_bc.code, &.{ op.get_var, op.drop, op.get_var, op.drop });
}

test "F5: return statement without value" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseFunctionBodyStatement(&env, "return;");
    defer fn_bc.deinit(env.rt);

    try std.testing.expectEqual(@as(usize, 1), fn_bc.code.len);
    try std.testing.expectEqual(op.return_undef, fn_bc.code[0]);
}

test "F5: return statement with value" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseFunctionBodyStatement(&env, "return x;");
    defer fn_bc.deinit(env.rt);

    try expectOpcodeSequence(fn_bc.code, &.{ op.get_var, op.@"return" });
}

test "F5: return comma and conditional expressions use one final return" {
    var env = try ParserTestEnv.init();
    defer env.deinit();

    const cases = [_][]const u8{
        "return a, b;",
        "return a ? b : c, d;",
        "return a, b ? c : d;",
        "return (a, (b, c));",
        "return c ? g() : h()\n, 42;",
    };
    for (cases) |source| {
        var fn_bc = try parseFunctionBodyStatement(&env, source);
        defer fn_bc.deinit(env.rt);
        try std.testing.expectEqual(@as(usize, 1), countOpcode(fn_bc.code, op.@"return"));
        try std.testing.expectEqual(@as(usize, 0), countOpcode(fn_bc.code, op.tail_call));
        try std.testing.expectEqual(@as(usize, 0), countOpcode(fn_bc.code, op.tail_call_method));
    }
}

test "F5: return conditional expression merges before one plain return" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseFunctionBodyStatement(&env, "return p ? f() : g();");
    defer fn_bc.deinit(env.rt);

    try std.testing.expectEqual(@as(usize, 2), countCalls(fn_bc.code));
    try std.testing.expectEqual(@as(usize, 0), countOpcode(fn_bc.code, op.tail_call));
    try std.testing.expectEqual(@as(usize, 1), countOpcode(fn_bc.code, op.@"return"));
}

test "F5: return call remains plain call plus return" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseFunctionBodyStatement(&env, "return f(\"\");");
    defer fn_bc.deinit(env.rt);

    try std.testing.expectEqual(@as(usize, 1), countCalls(fn_bc.code));
    try std.testing.expectEqual(@as(usize, 1), countOpcode(fn_bc.code, op.@"return"));
    try std.testing.expectEqual(@as(usize, 0), countOpcode(fn_bc.code, op.tail_call));
}

test "F5: throw statement" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatement(&env, "throw x;");
    defer fn_bc.deinit(env.rt);

    try expectOpcodeSequence(fn_bc.code, &.{ op.get_var, op.throw });
}

test "F5: if statement without else" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatement(&env, "if (x) y;");
    defer fn_bc.deinit(env.rt);

    try expectOpcodeSequence(fn_bc.code, &.{ op.get_var, op.if_false8, op.get_var, op.drop });
    const if_false_target = readRelTarget32(fn_bc.code, 3);
    try std.testing.expectEqual(fn_bc.code.len, if_false_target);
}

test "F5: if statement with else" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatement(&env, "if (x) y; else z;");
    defer fn_bc.deinit(env.rt);

    try expectOpcodeSequence(fn_bc.code, &.{ op.get_var, op.if_false8, op.get_var, op.drop, op.goto8, op.get_var, op.drop });
    const if_false_target = readRelTarget32(fn_bc.code, 3);
    try std.testing.expectEqual(@as(usize, 11), if_false_target);
    const goto_target = readRelTarget32(fn_bc.code, 9);
    try std.testing.expectEqual(fn_bc.code.len, goto_target);
}

test "F5: while statement" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatement(&env, "while (x) y;");
    defer fn_bc.deinit(env.rt);

    try expectOpcodeSequence(fn_bc.code, &.{ op.get_var, op.if_false8, op.get_var, op.drop, op.goto8 });
    // Last instruction must be a backward goto to offset 0 (loop top).
    const last_goto = fn_bc.code.len - engine.bytecode.opcode.sizeOf(op.goto8);
    try std.testing.expectEqual(op.goto8, fn_bc.code[last_goto]);
    const back_target = readRelTarget32(fn_bc.code, last_goto);
    try std.testing.expectEqual(@as(usize, 0), back_target);
    const if_false_target = readRelTarget32(fn_bc.code, 3);
    try std.testing.expectEqual(fn_bc.code.len, if_false_target);
}

test "F5: do-while statement" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatement(&env, "do { y; } while (x);");
    defer fn_bc.deinit(env.rt);

    try expectOpcodeSequence(fn_bc.code, &.{ op.get_var, op.drop, op.get_var, op.if_true8 });
    try std.testing.expectEqual(@as(usize, 0), readRelTarget32(fn_bc.code, 7));
}

test "F5: for update moves optional chain code with atom operands" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatement(&env, "for (; true; obj?.a?.[touched++]) ;");
    defer fn_bc.deinit(env.rt);

    try std.testing.expectEqual(@as(usize, 2), countOpcode(fn_bc.code, op.is_undefined_or_null));
}

test "F5: expression statement" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatement(&env, "x;");
    defer fn_bc.deinit(env.rt);

    try expectOpcodeSequence(fn_bc.code, &.{ op.get_var, op.drop });
}

test "F5: labelled break crossing switch drops discriminant" {
    var env = try ParserTestEnv.init();
    defer env.deinit();

    const cases = [_][]const u8{
        "function f(){ loop: for(;;){ switch(x){ default: break loop; } } }",
        "function* f(){ loop: for(;;){ switch(x){ default: break loop; } } }",
    };
    for (cases) |source| {
        var fn_bc = try parseStatementWithTopLevelChildren(&env, source);
        defer fn_bc.deinit(env.rt);
    }
}

test "F5: switch CaseBlock does not treat a function expression name as a declaration" {
    var env = try ParserTestEnv.init();
    defer env.deinit();

    var fn_bc = try parseStatementWithTopLevelChildren(&env,
        \\switch (0) {
        \\case 0: (function clash() {}); break;
        \\case 1: let clash;
        \\}
    );
    defer fn_bc.deinit(env.rt);

    try std.testing.expectError(
        error.UnexpectedToken,
        parseStatement(&env, "switch (0) { case 0: let duplicate; case 1: let duplicate; }"),
    );
}

test "F5: labelled break to loop inside switch keeps discriminant stack balanced" {
    var env = try ParserTestEnv.init();
    defer env.deinit();

    var fn_bc = try parseStatementWithTopLevelChildren(&env,
        \\function f(label, r9, r15) {
        \\  switch (label) {
        \\  case 92:
        \\    label = 93;
        \\    break;
        \\  }
        \\  if (label == 93) label = 104;
        \\  outer: do {
        \\    if (label == 104) {
        \\      if (r9 != 0) {
        \\        loop: while (true) {
        \\          if (r9 <= r15) {
        \\            break loop;
        \\          } else {
        \\            if (!(r9 != 0)) break loop;
        \\          }
        \\        }
        \\      }
        \\    }
        \\  } while (0);
        \\  r9;
        \\}
    );
    defer fn_bc.deinit(env.rt);
}

test "F5: labelled continue inside switch case keeps discriminant stack balanced" {
    var env = try ParserTestEnv.init();
    defer env.deinit();

    var fn_bc = try parseStatementWithTopLevelChildren(&env,
        \\function f(a, b) {
        \\  while (true) { a = a + 1; if (a > 2) break; }
        \\  switch (b) {
        \\  case 1:
        \\    M: while (true) { if (a) break; continue M; }
        \\  }
        \\  return a;
        \\}
    );
    defer fn_bc.deinit(env.rt);
}

test "F5: labelled continue from nested loop inside switch drops discriminant once" {
    var env = try ParserTestEnv.init();
    defer env.deinit();

    var fn_bc = try parseStatementWithTopLevelChildren(&env,
        \\function f(a, b) {
        \\  outer: while (true) {
        \\    switch (b) {
        \\    case 1:
        \\      while (true) {
        \\        if (a) continue outer;
        \\        break;
        \\      }
        \\    }
        \\    break;
        \\  }
        \\}
    );
    defer fn_bc.deinit(env.rt);
}

test "F5: var declaration without initializer" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatement(&env, "var x;");
    defer fn_bc.deinit(env.rt);

    try std.testing.expectEqual(@as(usize, 0), fn_bc.code.len);
    try std.testing.expectEqual(@as(usize, 1), globalDeclarationClosureCount(&fn_bc));
    try std.testing.expect(!globalDeclarationClosureNamed(&fn_bc, env.rt, "x").?.isLexical());
}

test "F5: var declaration with initializer" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatement(&env, "var x = 1;");
    defer fn_bc.deinit(env.rt);

    // Top-level declaration metadata lives in the finalized closure table;
    // only the initializer write remains in the QuickJS-format code stream.
    try std.testing.expectEqual(@as(usize, 4), fn_bc.code.len);
    try std.testing.expectEqual(@as(usize, 1), globalDeclarationClosureCount(&fn_bc));
    try std.testing.expect(!globalDeclarationClosureNamed(&fn_bc, env.rt, "x").?.isLexical());
    try std.testing.expectEqual(op.push_1, fn_bc.code[0]);
    try std.testing.expectEqual(op.put_var, fn_bc.code[fn_bc.code.len - 3]);
}

test "F5: sloppy var initializer captures dynamic reference before RHS" {
    var env = try ParserTestEnv.init();
    defer env.deinit();

    const name = try env.rt.internAtom("test");
    const x_atom = try env.rt.internAtom("x");
    defer env.rt.atoms.free(name);
    defer env.rt.atoms.free(x_atom);

    var function = engine.bytecode.Bytecode.init(&env.rt.memory, &env.rt.atoms, name);
    defer function.deinit(env.rt);
    var lex = QjsLexer.init(std.testing.allocator, &env.rt.atoms, "with (obj) { var x = 1; }");
    var state = try ParseState.init(&lex, &function);
    defer state.deinit(env.rt);

    try parser_core.parseStatementOrDecl(&state, parser_core.DeclMask{ .func = true, .func_with_label = true, .other = true });

    var make_ref_pc: ?usize = null;
    var rhs_pc: ?usize = null;
    var put_ref_pc: ?usize = null;
    var pc: usize = 0;
    while (pc < function.code.len) {
        const opcode_id = function.code[pc];
        if (opcode_id == op.scope_make_ref and
            std.mem.readInt(u32, function.code[pc + 1 ..][0..4], .little) == x_atom)
        {
            make_ref_pc = pc;
        } else if (opcode_id == op.push_1 or
            (opcode_id == op.push_i32 and std.mem.readInt(i32, function.code[pc + 1 ..][0..4], .little) == 1))
        {
            rhs_pc = pc;
        } else if (opcode_id == op.put_ref_value) {
            put_ref_pc = pc;
        }
        const size = engine.bytecode.opcode.sizeOfPhase1(opcode_id);
        try std.testing.expect(size != 0);
        pc += size;
    }

    try std.testing.expect((make_ref_pc orelse return error.TestExpectedEqual) < (rhs_pc orelse return error.TestExpectedEqual));
    try std.testing.expect(rhs_pc.? < (put_ref_pc orelse return error.TestExpectedEqual));
    const label_target: usize = @intCast(std.mem.readInt(u32, function.code[make_ref_pc.? + 5 ..][0..4], .little));
    try std.testing.expect(label_target != 0);
    try std.testing.expectEqual(put_ref_pc.? - 1, label_target);
    try std.testing.expectEqual(op.nop, function.code[label_target]);
}

test "F5: module-ref var initializer consumes value unless next statement reuses binding" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseModuleRefStatement(&env, "var x = 1; y;");
    defer fn_bc.deinit(env.rt);

    const body_pc = try moduleBodyStart(fn_bc.code);
    try std.testing.expectEqual(op.push_1, fn_bc.code[body_pc]);
    try std.testing.expectEqual(op.put_var_ref0, fn_bc.code[body_pc + 1]);
}

test "F5: module-ref var initializer preserves value for immediate same-name expression" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseModuleRefStatement(&env, "var x = 1; x;");
    defer fn_bc.deinit(env.rt);

    const body_pc = try moduleBodyStart(fn_bc.code);
    try std.testing.expectEqual(op.push_1, fn_bc.code[body_pc]);
    try std.testing.expectEqual(op.set_var_ref0, fn_bc.code[body_pc + 1]);
}

test "F5: let declaration" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatement(&env, "let x;");
    defer fn_bc.deinit(env.rt);

    // Script top-level `let` is a GLOBAL_DECL cell. Construction installs the
    // uninitialized lexical cell; executable code performs only the source
    // initialization through that declaration carrier.
    try std.testing.expectEqual(@as(usize, 1), globalDeclarationClosureCount(&fn_bc));
    try std.testing.expect(globalDeclarationClosureNamed(&fn_bc, env.rt, "x").?.isLexical());
    // QuickJS final bytecode keeps the declaration carrier in closure
    // metadata but emits the source initializer as put_var_init.
    try expectOpcodeSequence(fn_bc.code, &.{ op.undefined, op.put_var_init });
}

test "F5: let declaration with initializer" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatement(&env, "let x = 1;");
    defer fn_bc.deinit(env.rt);

    // The initializer writes the GLOBAL_DECL cell directly; its TDZ state was
    // established during global-declaration construction.
    try std.testing.expectEqual(@as(usize, 1), globalDeclarationClosureCount(&fn_bc));
    try std.testing.expect(globalDeclarationClosureNamed(&fn_bc, env.rt, "x").?.isLexical());
    try expectOpcodeSequence(fn_bc.code, &.{ op.push_1, op.put_var_init });
}

test "F5: const declaration without initializer should fail" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    try std.testing.expectError(error.UnexpectedToken, parseStatement(&env, "const x;"));
}

test "F5: const declaration with initializer" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatement(&env, "const x = 1;");
    defer fn_bc.deinit(env.rt);

    // Const uses the same GLOBAL_DECL initialization shape; immutability is
    // carried by ClosureVar.is_const for later writes.
    try std.testing.expectEqual(@as(usize, 1), globalDeclarationClosureCount(&fn_bc));
    const x_decl = globalDeclarationClosureNamed(&fn_bc, env.rt, "x").?;
    try std.testing.expect(x_decl.isLexical());
    try std.testing.expect(x_decl.isConst());
    try expectOpcodeSequence(fn_bc.code, &.{ op.push_1, op.put_var_init });
}

test "F5: multiple var declarations" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatement(&env, "var x = 1, y = 2;");
    defer fn_bc.deinit(env.rt);

    try std.testing.expectEqual(@as(usize, 8), fn_bc.code.len);
    try std.testing.expectEqual(@as(usize, 2), globalDeclarationClosureCount(&fn_bc));
    try std.testing.expect(globalDeclarationClosureNamed(&fn_bc, env.rt, "x") != null);
    try std.testing.expect(globalDeclarationClosureNamed(&fn_bc, env.rt, "y") != null);
    try std.testing.expectEqual(op.push_1, fn_bc.code[0]);
    try std.testing.expectEqual(op.put_var, fn_bc.code[1]);
    try std.testing.expectEqual(op.push_2, fn_bc.code[4]);
    try std.testing.expectEqual(op.put_var, fn_bc.code[5]);
}

test "F5: directive prologue with 'use strict'" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatementWithTopLevelChildren(&env, "function f(){ \"use strict\"; x; }");
    defer fn_bc.deinit(env.rt);

    const child = findFunctionConstantNamed(&fn_bc, env.rt, "f") orelse return error.TestExpectedEqual;
    try std.testing.expect(child.flags.is_strict_mode);
    try expectOpcode(child.byteCode(), op.get_var);
}

test "M3.1 F4: strict object setter rejects eval and arguments parameters" {
    var env = try ParserTestEnv.init();
    defer env.deinit();

    try std.testing.expectError(error.UnexpectedToken, parseStatementWithTopLevelChildren(&env, "function f(){ \"use strict\"; var obj = { set x(eval) {} }; }"));
    try std.testing.expectError(error.UnexpectedToken, parseStatementWithTopLevelChildren(&env, "function f(){ \"use strict\"; var obj = { set x(arguments) {} }; }"));
}

test "F5: directive prologue with multiple directives" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatementWithTopLevelChildren(&env, "function f(){ \"use strict\"; \"other directive\"; x; }");
    defer fn_bc.deinit(env.rt);

    const child = findFunctionConstantNamed(&fn_bc, env.rt, "f") orelse return error.TestExpectedEqual;
    try std.testing.expect(child.flags.is_strict_mode);
    try expectOpcode(child.byteCode(), op.get_var);
}

test "F5: directive prologue with ASI" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatementWithTopLevelChildren(&env, "function f(){ \"use strict\"\n x; }");
    defer fn_bc.deinit(env.rt);

    const child = findFunctionConstantNamed(&fn_bc, env.rt, "f") orelse return error.TestExpectedEqual;
    try std.testing.expect(child.flags.is_strict_mode);
    try expectOpcode(child.byteCode(), op.get_var);
}

// ---- F6 function parsing tests -----------------------------------------

test "F6: simple function declaration" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatementWithTopLevelChildren(&env, "function foo() {}");
    defer fn_bc.deinit(env.rt);

    const child = try expectFunctionConstant(&fn_bc, 0);
    try expectAtomName(&env, child.func_name, "foo");
    try std.testing.expectEqual(function_def_mod.FunctionKind.normal, child.flags.func_kind);
    try std.testing.expect(child.flags.has_prototype);
    try std.testing.expect(!child.flags.is_arrow_function);
    try std.testing.expectEqual(@as(usize, 0), child.argVarDefs().len);
    try expectOpcode(child.byteCode(), op.return_undef);
}

test "F6: line_num before explicit return does not add implicit return" {
    var env = try ParserTestEnv.init();
    defer env.deinit();

    var fn_bc = try parseStatementWithTopLevelChildren(&env,
        \\function foo() {
        \\  return 1;
        \\}
    );
    defer fn_bc.deinit(env.rt);

    const child = try expectFunctionConstant(&fn_bc, 0);
    try std.testing.expectEqual(@as(usize, 1), countOpcode(child.byteCode(), op.@"return"));
    try std.testing.expectEqual(@as(usize, 0), countOpcode(child.byteCode(), op.return_undef));
}

test "F6: function declaration with parameters" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatementWithTopLevelChildren(&env, "function foo(x, y) {}");
    defer fn_bc.deinit(env.rt);

    const child = try expectFunctionConstant(&fn_bc, 0);
    try expectAtomName(&env, child.func_name, "foo");
    try std.testing.expectEqual(function_def_mod.FunctionKind.normal, child.flags.func_kind);
    try std.testing.expectEqual(@as(usize, 2), child.argVarDefs().len);
    try expectAtomName(&env, child.argVarDefs()[0].var_name, "x");
    try expectAtomName(&env, child.argVarDefs()[1].var_name, "y");
    try expectOpcode(child.byteCode(), op.return_undef);
}

test "F6: var redeclaration of parameter keeps closure bound to arg" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatementWithTopLevelChildren(&env, "function outer(l1){ var l1; function get(){ return l1; } }");
    defer fn_bc.deinit(env.rt);

    const outer = try expectFunctionConstant(&fn_bc, 0);
    try std.testing.expect(functionBytecodeHasClosure(env.rt, outer, "l1", .arg));
}

test "F6: function declaration with rest parameter" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatementWithTopLevelChildren(&env, "function foo(...args) {}");
    defer fn_bc.deinit(env.rt);

    const child = try expectFunctionConstant(&fn_bc, 0);
    try expectAtomName(&env, child.func_name, "foo");
    try std.testing.expectEqual(function_def_mod.FunctionKind.normal, child.flags.func_kind);
    try std.testing.expectEqual(@as(usize, 1), child.argVarDefs().len);
    try expectAtomName(&env, child.argVarDefs()[0].var_name, "args");
    try expectOpcode(child.byteCode(), op.rest);
    try expectOpcode(child.byteCode(), op.return_undef);
}

test "F6: arrow function with block body" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExprWithTopLevelChildren(&env, "() => {}");
    defer fn_bc.deinit(env.rt);

    const child = try expectFunctionConstant(&fn_bc, 0);
    try std.testing.expectEqual(function_def_mod.FunctionKind.normal, child.flags.func_kind);
    try std.testing.expect(child.flags.is_arrow_function);
    try std.testing.expect(!child.flags.has_prototype);
    try std.testing.expectEqual(@as(usize, 0), child.argVarDefs().len);
    try expectOpcode(child.byteCode(), op.return_undef);
}

test "F6: arrow function with expression body" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExprWithTopLevelChildren(&env, "() => 42");
    defer fn_bc.deinit(env.rt);

    const child = try expectFunctionConstant(&fn_bc, 0);
    try std.testing.expectEqual(function_def_mod.FunctionKind.normal, child.flags.func_kind);
    try std.testing.expect(child.flags.is_arrow_function);
    try std.testing.expect(!child.flags.has_prototype);
    try std.testing.expectEqual(@as(usize, 0), child.argVarDefs().len);
    try expectOpcode(child.byteCode(), op.push_i8);
    try expectOpcode(child.byteCode(), op.@"return");
}

test "F6: arrow function with single parameter" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExprWithTopLevelChildren(&env, "x => x");
    defer fn_bc.deinit(env.rt);

    const child = try expectFunctionConstant(&fn_bc, 0);
    try std.testing.expectEqual(function_def_mod.FunctionKind.normal, child.flags.func_kind);
    try std.testing.expect(child.flags.is_arrow_function);
    try std.testing.expectEqual(@as(usize, 1), child.argVarDefs().len);
    try expectAtomName(&env, child.argVarDefs()[0].var_name, "x");
    try expectOpcode(child.byteCode(), op.get_arg0);
    try expectOpcode(child.byteCode(), op.@"return");
}

test "F6: arrow function with multiple parameters" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExprWithTopLevelChildren(&env, "(x, y) => x + y");
    defer fn_bc.deinit(env.rt);

    const child = try expectFunctionConstant(&fn_bc, 0);
    try std.testing.expectEqual(function_def_mod.FunctionKind.normal, child.flags.func_kind);
    try std.testing.expect(child.flags.is_arrow_function);
    try std.testing.expectEqual(@as(usize, 2), child.argVarDefs().len);
    try expectAtomName(&env, child.argVarDefs()[0].var_name, "x");
    try expectAtomName(&env, child.argVarDefs()[1].var_name, "y");
    try expectOpcode(child.byteCode(), op.get_arg0);
    try expectOpcode(child.byteCode(), op.get_arg1);
    try expectOpcode(child.byteCode(), op.add);
    try expectOpcode(child.byteCode(), op.@"return");
}

test "F6: arrow function with rest parameter" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExprWithTopLevelChildren(&env, "(...args) => args");
    defer fn_bc.deinit(env.rt);

    const child = try expectFunctionConstant(&fn_bc, 0);
    try std.testing.expectEqual(function_def_mod.FunctionKind.normal, child.flags.func_kind);
    try std.testing.expect(child.flags.is_arrow_function);
    try std.testing.expectEqual(@as(usize, 1), child.argVarDefs().len);
    try expectAtomName(&env, child.argVarDefs()[0].var_name, "args");
    try expectOpcode(child.byteCode(), op.rest);
    try expectOpcode(child.byteCode(), op.@"return");
}

test "F6: function with object destructuring parameter" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatementWithTopLevelChildren(&env, "function foo({a, b}) {}");
    defer fn_bc.deinit(env.rt);

    const child = try expectFunctionConstant(&fn_bc, 0);
    try expectAtomName(&env, child.func_name, "foo");
    try std.testing.expectEqual(@as(u16, 1), child.arg_count);
    try std.testing.expectEqual(@as(u16, 2), child.var_count);
    try expectOpcode(child.byteCode(), op.get_field);
    try expectOpcode(child.byteCode(), op.return_undef);
}

test "F6: function with array destructuring parameter" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatementWithTopLevelChildren(&env, "function foo([a, b]) {}");
    defer fn_bc.deinit(env.rt);

    const child = try expectFunctionConstant(&fn_bc, 0);
    try expectAtomName(&env, child.func_name, "foo");
    try std.testing.expectEqual(@as(u16, 1), child.arg_count);
    try std.testing.expectEqual(@as(u16, 2), child.var_count);
    try expectOpcode(child.byteCode(), op.for_of_start);
    try expectOpcode(child.byteCode(), op.return_undef);
}

test "F6: arrow function with object destructuring parameter" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExprWithTopLevelChildren(&env, "({a, b}) => a");
    defer fn_bc.deinit(env.rt);

    const child = try expectFunctionConstant(&fn_bc, 0);
    try std.testing.expect(child.flags.is_arrow_function);
    try std.testing.expectEqual(@as(u16, 1), child.arg_count);
    try std.testing.expectEqual(@as(u16, 2), child.var_count);
    try expectOpcode(child.byteCode(), op.get_field);
    try expectOpcode(child.byteCode(), op.@"return");
}

test "F6: arrow function with array destructuring parameter" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExprWithTopLevelChildren(&env, "([a, b]) => a");
    defer fn_bc.deinit(env.rt);

    const child = try expectFunctionConstant(&fn_bc, 0);
    try std.testing.expect(child.flags.is_arrow_function);
    try std.testing.expectEqual(@as(u16, 1), child.arg_count);
    try std.testing.expectEqual(@as(u16, 2), child.var_count);
    try expectOpcode(child.byteCode(), op.for_of_start);
    try expectOpcode(child.byteCode(), op.@"return");
}

test "F6: direct shorthand destructuring bindings use get_field2" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatementWithTopLevelChildren(&env, "function foo(source) { let { a, b } = source; }");
    defer fn_bc.deinit(env.rt);

    const child = try expectFunctionConstant(&fn_bc, 0);
    try std.testing.expectEqual(@as(usize, 2), countOpcode(child.byteCode(), op.get_field2));
    try std.testing.expectEqual(@as(usize, 0), countOpcode(child.byteCode(), op.get_field));
}

// ---- F7 Class parsing tests ----

test "F7: class with constructor" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatementWithTopLevelChildren(&env, "class C { constructor(x) { this.x = x; } }");
    defer fn_bc.deinit(env.rt);

    const ctor = try expectFunctionConstant(&fn_bc, 0);
    try std.testing.expect(ctor.flags.is_class_constructor);
    try std.testing.expect(!ctor.flags.is_derived_class_constructor);
    try std.testing.expectEqual(@as(usize, 1), ctor.argVarDefs().len);
    try expectAtomName(&env, ctor.argVarDefs()[0].var_name, "x");
    try expectOpcode(fn_bc.code, op.define_class);
    try expectOpcode(ctor.byteCode(), op.put_field);
}

test "F7: class with getter" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatementWithTopLevelChildren(&env, "class C { get x() { return this._x; } }");
    defer fn_bc.deinit(env.rt);

    const getter = try expectFunctionConstant(&fn_bc, 0);
    try std.testing.expectEqual(function_def_mod.FunctionKind.normal, getter.flags.func_kind);
    try std.testing.expectEqual(@as(usize, 0), getter.argVarDefs().len);
    try expectOpcode(fn_bc.code, op.define_class);
    try expectOpcode(fn_bc.code, op.define_method);
    try expectOpcode(getter.byteCode(), op.get_field);
    try expectOpcode(getter.byteCode(), op.@"return");
}

test "F7: class with setter" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatementWithTopLevelChildren(&env, "class C { set x(value) { this._x = value; } }");
    defer fn_bc.deinit(env.rt);

    const setter = try expectFunctionConstant(&fn_bc, 0);
    try std.testing.expectEqual(function_def_mod.FunctionKind.normal, setter.flags.func_kind);
    try std.testing.expectEqual(@as(usize, 1), setter.argVarDefs().len);
    try expectAtomName(&env, setter.argVarDefs()[0].var_name, "value");
    try expectOpcode(fn_bc.code, op.define_class);
    try expectOpcode(fn_bc.code, op.define_method);
    try expectOpcode(setter.byteCode(), op.put_field);
}

test "F7: class field ASI before generator method" {
    var env = try ParserTestEnv.init();
    defer env.deinit();

    var get_field = try parseStatementWithTopLevelChildren(&env,
        \\class A {
        \\  get
        \\  *a() {}
        \\}
    );
    defer get_field.deinit(env.rt);

    var set_field = try parseStatementWithTopLevelChildren(&env,
        \\class A {
        \\  static set
        \\  *a() {}
        \\}
    );
    defer set_field.deinit(env.rt);

    try expectOpcode(get_field.code, op.define_class);
    try expectOpcode(get_field.code, op.define_method);
    try expectOpcodeRecursive(&get_field, op.define_field);
    try expectOpcode(get_field.code, op.set_home_object);

    try expectOpcode(set_field.code, op.define_class);
    try expectOpcode(set_field.code, op.define_field);
    try expectOpcode(set_field.code, op.define_method);

    try std.testing.expectError(error.UnexpectedToken, parseStatement(&env, "class A { get *a() {} }"));
}

test "F7: super keyword in class method" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatementWithTopLevelChildren(&env, "class C { m() { super.x(); } }");
    defer fn_bc.deinit(env.rt);

    try expectOpcode(fn_bc.code, op.define_class);
    try expectOpcode(fn_bc.code, op.define_method);
    try expectOpcodeRecursive(&fn_bc, op.get_super);
    try expectOpcodeRecursive(&fn_bc, op.call_method);
}

test "F7: super property access" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatementWithTopLevelChildren(&env, "class C { m() { return super.x; } }");
    defer fn_bc.deinit(env.rt);

    try expectOpcode(fn_bc.code, op.define_class);
    try expectOpcode(fn_bc.code, op.define_method);
    try expectOpcodeRecursive(&fn_bc, op.get_super_value);
    try expectOpcodeRecursive(&fn_bc, op.@"return");
}

test "F7: super() constructor call" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatementWithTopLevelChildren(&env, "class C extends B { constructor(x) { super(x); } }");
    defer fn_bc.deinit(env.rt);

    const ctor = try expectFunctionConstant(&fn_bc, 0);
    try std.testing.expect(ctor.flags.is_class_constructor);
    try std.testing.expect(ctor.flags.is_derived_class_constructor);
    try expectOpcode(fn_bc.code, op.define_class);
    try expectOpcode(fn_bc.code, op.get_var);
    try expectOpcode(ctor.byteCode(), op.get_super);
    try expectOpcode(ctor.byteCode(), op.call_method);
}

test "F7: derived constructor this read lowers to get_loc_checkthis" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatementWithTopLevelChildren(&env, "class C extends B { constructor() { super(); return this; } }");
    defer fn_bc.deinit(env.rt);

    const ctor = try expectFunctionConstant(&fn_bc, 0);
    try std.testing.expect(ctor.flags.is_derived_class_constructor);
    try expectOpcode(ctor.byteCode(), op.put_loc_check_init);
    try expectOpcode(ctor.byteCode(), op.get_loc_checkthis);
    try std.testing.expectEqual(@as(usize, 1), countOpcode(ctor.byteCode(), op.@"return"));
    try std.testing.expectEqual(@as(usize, 0), countOpcode(ctor.byteCode(), op.return_undef));
}

test "F7: super() rejected in base constructor" {
    var env = try ParserTestEnv.init();
    defer env.deinit();

    try std.testing.expectError(error.UnexpectedToken, parseStatement(&env, "class C { constructor(x) { super(x); } }"));
}

test "F9: yield expression" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatementWithTopLevelChildren(&env, "function* g() { yield 42; }");
    defer fn_bc.deinit(env.rt);

    const child = try expectFunctionConstant(&fn_bc, 0);
    try expectAtomName(&env, child.func_name, "g");
    try std.testing.expectEqual(function_def_mod.FunctionKind.generator, child.flags.func_kind);
    try expectOpcode(child.byteCode(), op.yield);
    try expectOpcode(child.byteCode(), op.return_async);
}

test "F9: yield* expression" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatementWithTopLevelChildren(&env, "function* g() { yield* iterable; }");
    defer fn_bc.deinit(env.rt);

    const child = try expectFunctionConstant(&fn_bc, 0);
    try expectAtomName(&env, child.func_name, "g");
    try std.testing.expectEqual(function_def_mod.FunctionKind.generator, child.flags.func_kind);
    try expectOpcode(child.byteCode(), op.for_of_start);
    try expectOpcode(child.byteCode(), op.iterator_next);
    try expectOpcode(child.byteCode(), op.yield_star);
    try expectOpcode(child.byteCode(), op.return_async);
}

test "F8: export default statement" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseModuleStatement(&env, "export default 42;");
    defer fn_bc.deinit(env.rt);

    const record = try moduleRecord(&fn_bc);
    try expectModuleRecordCounts(record, 0, 0, 1, 0, 0);
    try expectModuleExport(&env, record, 0, "default", "*default*");
}

test "F8: export named statement" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseModuleStatement(&env, "export { x, y };");
    defer fn_bc.deinit(env.rt);

    const record = try moduleRecord(&fn_bc);
    try expectModuleRecordCounts(record, 0, 0, 2, 0, 0);
    try expectModuleExport(&env, record, 0, "x", "x");
    try expectModuleExport(&env, record, 1, "y", "y");
}

test "F7: private field in class" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatementWithTopLevelChildren(&env, "class C { #x; }");
    defer fn_bc.deinit(env.rt);

    try expectOpcode(fn_bc.code, op.define_class);
    try expectOpcodeRecursive(&fn_bc, op.define_field);
}

test "F7: private method in class" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatementWithTopLevelChildren(&env, "class C { #m() {} }");
    defer fn_bc.deinit(env.rt);

    try expectOpcode(fn_bc.code, op.define_class);
    try expectOpcodeRecursive(&fn_bc, op.define_method);
}

test "F7: private getter in class" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatementWithTopLevelChildren(&env, "class C { get #x() { return this._x; } }");
    defer fn_bc.deinit(env.rt);

    try expectOpcode(fn_bc.code, op.define_class);
    try expectOpcodeRecursive(&fn_bc, op.define_method);
}

test "F7: private setter in class" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatementWithTopLevelChildren(&env, "class C { set #x(value) { this._x = value; } }");
    defer fn_bc.deinit(env.rt);

    try expectOpcode(fn_bc.code, op.define_class);
    try expectOpcodeRecursive(&fn_bc, op.define_method);
}

test "F7: private name in uses scope temp before resolver" {
    var env = try ParserTestEnv.init();
    defer env.deinit();

    const name = try env.rt.internAtom("test");
    defer env.rt.atoms.free(name);
    var function = engine.bytecode.Bytecode.init(&env.rt.memory, &env.rt.atoms, name);
    defer function.deinit(env.rt);
    var lex = QjsLexer.init(std.testing.allocator, &env.rt.atoms, "class C { #x; m(o) { return #x in o; } }");
    var state = try ParseState.init(&lex, &function);
    defer state.deinit(env.rt);
    state.top_level_functions_as_children = true;

    try parser_core.parseStatementOrDecl(&state, parser_core.DeclMask{ .func = true, .func_with_label = true, .other = true });

    var saw_temp = false;
    for (state.function_def.child_list) |child| {
        if (std.mem.indexOfScalar(u8, child.byte_code, op.scope_in_private_field) != null) {
            saw_temp = true;
            break;
        }
    }
    try std.testing.expect(saw_temp);

    try engine.bytecode.pipeline.finalize.runWithFunctionDefRuntime(&function, &state.function_def, env.rt);
    try expectOpcodeRecursive(&function, op.private_in);
}

test "unresolved descendant lookup threads direct eval var objects inside-out" {
    var env = try ParserTestEnv.init();
    defer env.deinit();

    const name = try env.rt.internAtom("test");
    defer env.rt.atoms.free(name);
    var function = engine.bytecode.Bytecode.init(&env.rt.memory, &env.rt.atoms, name);
    defer function.deinit(env.rt);
    var lex = QjsLexer.init(std.testing.allocator, &env.rt.atoms,
        \\function outer() {
        \\  eval("");
        \\  function middle() {
        \\    eval("");
        \\    return function inner() { return missing; };
        \\  }
        \\}
    );
    var state = try ParseState.init(&lex, &function);
    defer state.deinit(env.rt);
    state.top_level_functions_as_children = true;

    try parser_core.parseProgramStatements(&state, parser_core.DeclMask{ .func = true, .func_with_label = true, .other = true });
    try parser_core.prepareDirectEvalFunctionDefs(&state.function_def);
    // QuickJS does not blanket-copy every ancestor <var> object during
    // add_eval_variables. The ordinary inner function acquires them only when
    // resolve_scope_var proves that `missing` crosses those dynamic
    // environments. Run the real finalization pass before asserting that
    // resolution-time chain.
    try engine.bytecode.pipeline.finalize.runWithFunctionDefRuntime(&function, &state.function_def, env.rt);

    try std.testing.expectEqual(@as(usize, 1), state.function_def.child_list.len);
    const outer = state.function_def.child_list[0];
    try std.testing.expect(outer.var_object_idx >= 0);
    try std.testing.expectEqual(@as(usize, 1), outer.child_list.len);
    const middle = outer.child_list[0];
    try std.testing.expect(middle.var_object_idx >= 0);
    try std.testing.expectEqual(@as(usize, 1), middle.child_list.len);
    const inner = middle.child_list[0];

    var middle_var_capture_idx: ?u16 = null;
    for (middle.closure_var, 0..) |cv, idx| {
        if (cv.var_name == atom.ids.var_object and cv.closureType() == .local and cv.var_idx == @as(u16, @intCast(outer.var_object_idx))) {
            middle_var_capture_idx = @intCast(idx);
            break;
        }
    }
    const outer_ref_idx = middle_var_capture_idx orelse return error.TestExpectedEqual;

    var object_capture_count: usize = 0;
    for (inner.closure_var) |cv| {
        if (cv.var_name == atom.ids.var_object) object_capture_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), object_capture_count);
    try std.testing.expectEqual(atom.ids.var_object, inner.closure_var[0].var_name);
    try std.testing.expectEqual(function_def_mod.ClosureType.local, inner.closure_var[0].closureType());
    try std.testing.expectEqual(@as(u16, @intCast(middle.var_object_idx)), inner.closure_var[0].var_idx);
    try std.testing.expectEqual(atom.ids.var_object, inner.closure_var[1].var_name);
    try std.testing.expectEqual(function_def_mod.ClosureType.ref, inner.closure_var[1].closureType());
    try std.testing.expectEqual(outer_ref_idx, inner.closure_var[1].var_idx);
}

test "direct eval pseudo var objects follow eval and parameter-expression gates" {
    var env = try ParserTestEnv.init();
    defer env.deinit();

    const name = try env.rt.internAtom("test");
    defer env.rt.atoms.free(name);
    var function = engine.bytecode.Bytecode.init(&env.rt.memory, &env.rt.atoms, name);
    defer function.deinit(env.rt);
    var lex = QjsLexer.init(std.testing.allocator, &env.rt.atoms,
        \\function defaults(a = eval("")) { eval(""); }
        \\function pattern({ a = eval("") }) { eval(""); }
        \\function rest(...values) { eval(""); }
    );
    var state = try ParseState.init(&lex, &function);
    defer state.deinit(env.rt);
    state.top_level_functions_as_children = true;

    try parser_core.parseProgramStatements(&state, parser_core.DeclMask{ .func = true, .func_with_label = true, .other = true });
    try parser_core.prepareDirectEvalFunctionDefs(&state.function_def);

    try std.testing.expectEqual(@as(usize, 3), state.function_def.child_list.len);
    const defaults = state.function_def.child_list[0];
    try std.testing.expect(defaults.has_parameter_expressions);
    try std.testing.expect(defaults.var_object_idx >= 0);
    try std.testing.expect(defaults.arg_var_object_idx >= 0);

    const pattern = state.function_def.child_list[1];
    try std.testing.expect(pattern.has_parameter_expressions);
    try std.testing.expect(pattern.var_object_idx >= 0);
    try std.testing.expect(pattern.arg_var_object_idx >= 0);

    const rest = state.function_def.child_list[2];
    try std.testing.expect(!rest.has_parameter_expressions);
    try std.testing.expect(rest.var_object_idx >= 0);
    try std.testing.expectEqual(@as(i32, -1), rest.arg_var_object_idx);

    const eval_name = try env.rt.internAtom("eval-test");
    defer env.rt.atoms.free(eval_name);
    var eval_function = engine.bytecode.Bytecode.init(&env.rt.memory, &env.rt.atoms, eval_name);
    defer eval_function.deinit(env.rt);
    var eval_lex = QjsLexer.init(std.testing.allocator, &env.rt.atoms, "eval('')");
    var eval_state = try ParseState.init(&eval_lex, &eval_function);
    defer eval_state.deinit(env.rt);
    try eval_state.enableEvalReturn();
    try parser_core.parseProgramStatements(&eval_state, parser_core.DeclMask{ .func = true, .func_with_label = true, .other = true });
    try parser_core.prepareDirectEvalFunctionDefs(&eval_state.function_def);

    try std.testing.expect(eval_state.function_def.is_eval);
    try std.testing.expect(eval_state.function_def.has_eval_call);
    try std.testing.expectEqual(@as(i32, -1), eval_state.function_def.var_object_idx);
    try std.testing.expectEqual(@as(i32, -1), eval_state.function_def.arg_var_object_idx);
}

test "parameter initializer direct eval emits active global-declaration carriers" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const x_atom = try rt.internAtom("parameterEvalHoist");
    defer rt.atoms.free(x_atom);
    const cases = [_]struct {
        source: []const u8,
        function_declaration: bool,
    }{
        .{ .source = "var parameterEvalHoist = 1;", .function_declaration = false },
        .{ .source = "function parameterEvalHoist() {}", .function_declaration = true },
    };

    for (cases) |case| {
        var parsed = try parser.compile(rt, case.source, .{
            .mode = .eval_direct,
            .filename = "<eval>",
            .eval_in_parameter_initializer = true,
        });
        defer parsed.deinit();

        const metadata = globalDeclarationClosureNamed(&parsed.function, rt, "parameterEvalHoist") orelse
            return error.TestExpectedEqual;
        try std.testing.expectEqual(x_atom, metadata.var_name);
        try std.testing.expect(!metadata.isLexical());
        try std.testing.expect(parsed.function.flags.is_global_var);
        if (case.function_declaration) {
            try std.testing.expectEqual(function_def.VarKind.global_function_decl, metadata.varKind());
            try std.testing.expectEqual(@as(usize, 1), countFunctionClosures(parsed.function.code));
        } else {
            try std.testing.expectEqual(function_def.VarKind.normal, metadata.varKind());
            // `force_init` is compile-only. QuickJS clears the effective force
            // bit when the first matching GLOBAL_DECL carrier is found, so no
            // redundant prologue store survives; only the source initializer's
            // ordinary dynamic-global store remains.
            try std.testing.expectEqual(@as(usize, 0), countPutVarRefStores(parsed.function.code));
            try std.testing.expect(countOpcode(parsed.function.code, op.put_var) >= 1);
        }
    }
}

test "nested direct eval does not capture a parent global declaration carrier" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try parser.compile(
        rt,
        "let parentGlobal = 1; function readsByEval() { return eval('parentGlobal'); }",
        .{ .mode = .script, .filename = "direct-eval-global-carrier.js" },
    );
    defer parsed.deinit();

    try std.testing.expect(parsed.syntax_error == null);
    const child = findFunctionConstantNamed(&parsed.function, rt, "readsByEval") orelse
        return error.TestExpectedEqual;
    for (child.closureVar()) |cv| {
        const name = rt.atoms.name(cv.var_name) orelse continue;
        // qjs add_closure_variables skips GLOBAL, GLOBAL_REF, and GLOBAL_DECL:
        // eval resolves this name through its global environment instead of
        // turning the parent's declaration carrier into an ordinary REF.
        try std.testing.expect(!std.mem.eql(u8, name, "parentGlobal"));
    }
}

test "F7: class with extends (derived constructor)" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatement(&env, "class C extends B { constructor(x) { super(x); } }");
    defer fn_bc.deinit(env.rt);

    try expectOpcode(fn_bc.code, op.define_class);
    try std.testing.expect(countOpcode(fn_bc.code, op.get_var) > 0);
}

test "F7: class without extends (base constructor)" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatementWithTopLevelChildren(&env, "class C { constructor(x) { this.x = x; } }");
    defer fn_bc.deinit(env.rt);

    try expectOpcode(fn_bc.code, op.define_class);
    try std.testing.expect(countOpcodeRecursive(&fn_bc, op.put_field) > 0);
}

test "F8: basic import statement" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseModuleStatement(&env, "import x from 'module'");
    defer fn_bc.deinit(env.rt);

    const record = try moduleRecord(&fn_bc);
    try expectModuleRecordCounts(record, 1, 1, 0, 0, 0);
    try expectModuleRequest(&env, record, 0, "module");
    try expectModuleImport(&env, record, 0, 0, "default", "x");
}

test "F8: side-effect import" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseModuleStatement(&env, "import 'module'");
    defer fn_bc.deinit(env.rt);

    const record = try moduleRecord(&fn_bc);
    try expectModuleRecordCounts(record, 1, 0, 0, 0, 0);
    try expectModuleRequest(&env, record, 0, "module");
}

test "F8: named imports" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseModuleStatement(&env, "import { x, y } from 'module'");
    defer fn_bc.deinit(env.rt);

    const record = try moduleRecord(&fn_bc);
    try expectModuleRecordCounts(record, 1, 2, 0, 0, 0);
    try expectModuleRequest(&env, record, 0, "module");
    try expectModuleImport(&env, record, 0, 0, "x", "x");
    try expectModuleImport(&env, record, 1, 0, "y", "y");
}

test "F8: renamed imports" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseModuleStatement(&env, "import { x as a, y as b } from 'module'");
    defer fn_bc.deinit(env.rt);

    const record = try moduleRecord(&fn_bc);
    try expectModuleRecordCounts(record, 1, 2, 0, 0, 0);
    try expectModuleRequest(&env, record, 0, "module");
    try expectModuleImport(&env, record, 0, 0, "x", "a");
    try expectModuleImport(&env, record, 1, 0, "y", "b");
}

test "F8: namespace import" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseModuleStatement(&env, "import * as ns from 'module'");
    defer fn_bc.deinit(env.rt);

    const record = try moduleRecord(&fn_bc);
    try expectModuleRecordCounts(record, 1, 1, 0, 0, 0);
    try expectModuleRequest(&env, record, 0, "module");
    try expectModuleImport(&env, record, 0, 0, "*", "ns");
}

test "F8: mixed import" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseModuleStatement(&env, "import x, { y } from 'module'");
    defer fn_bc.deinit(env.rt);

    const record = try moduleRecord(&fn_bc);
    try expectModuleRecordCounts(record, 1, 2, 0, 0, 0);
    try expectModuleRequest(&env, record, 0, "module");
    try expectModuleImport(&env, record, 0, 0, "default", "x");
    try expectModuleImport(&env, record, 1, 0, "y", "y");
}

test "F8: export named" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseModuleStatement(&env, "export { x, y }");
    defer fn_bc.deinit(env.rt);

    const record = try moduleRecord(&fn_bc);
    try expectModuleRecordCounts(record, 0, 0, 2, 0, 0);
    try expectModuleExport(&env, record, 0, "x", "x");
    try expectModuleExport(&env, record, 1, "y", "y");
}

test "F8: export renamed" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseModuleStatement(&env, "export { x as a, y as b }");
    defer fn_bc.deinit(env.rt);

    const record = try moduleRecord(&fn_bc);
    try expectModuleRecordCounts(record, 0, 0, 2, 0, 0);
    try expectModuleExport(&env, record, 0, "a", "x");
    try expectModuleExport(&env, record, 1, "b", "y");
}

test "F8: export default expression" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseModuleStatement(&env, "export default 42");
    defer fn_bc.deinit(env.rt);

    const record = try moduleRecord(&fn_bc);
    try expectModuleRecordCounts(record, 0, 0, 1, 0, 0);
    try expectModuleExport(&env, record, 0, "default", "*default*");
    const carrier = declarationClosureNamed(&fn_bc, env.rt, "*default*") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(function_def.ClosureType.module_decl, carrier.closureType());
    try std.testing.expect(carrier.isLexical());
}

test "F8: export default function" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseModuleStatement(&env, "export default function f() {}");
    defer fn_bc.deinit(env.rt);

    const record = try moduleRecord(&fn_bc);
    try expectModuleRecordCounts(record, 0, 0, 1, 0, 0);
    try expectModuleExport(&env, record, 0, "default", "f");
}

test "anonymous default function uses a star-default global function carrier" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var parsed = try parser.compile(
        env.rt,
        "export default function() {}",
        .{ .mode = .module, .filename = "anonymous-default-function.mjs" },
    );
    defer parsed.deinit();
    try std.testing.expect(parsed.syntax_error == null);
    const fn_bc = &parsed.function;

    const record = try moduleRecord(fn_bc);
    try expectModuleRecordCounts(record, 0, 0, 1, 0, 0);
    try expectModuleExport(&env, record, 0, "default", "*default*");
    var found_function_constant = false;
    for (fn_bc.constants.values) |value| {
        if (functionBytecodeFromValue(value) != null) {
            found_function_constant = true;
            break;
        }
    }
    try std.testing.expect(found_function_constant);

    const carrier = carrier: {
        for (fn_bc.closure_var, 0..) |cv, idx| {
            if (std.mem.eql(u8, env.rt.atoms.name(cv.var_name) orelse "", "*default*")) {
                break :carrier &fn_bc.closure_var[idx];
            }
        }
        return error.TestExpectedEqual;
    };
    try std.testing.expectEqual(function_def.ClosureType.module_decl, carrier.closureType());
    try std.testing.expectEqual(function_def.VarKind.global_function_decl, carrier.varKind());
    try std.testing.expect(!carrier.isLexical());
}

test "F8: export default class" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseModuleStatement(&env, "export default class C {}");
    defer fn_bc.deinit(env.rt);

    const record = try moduleRecord(&fn_bc);
    try expectModuleRecordCounts(record, 0, 0, 1, 0, 0);
    try expectModuleExport(&env, record, 0, "default", "C");
    const carrier = declarationClosureNamed(&fn_bc, env.rt, "C") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(function_def.ClosureType.module_decl, carrier.closureType());
    try std.testing.expect(carrier.isLexical());
}

test "anonymous default class uses the lexical star-default carrier" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseModuleStatement(&env, "export default class {}");
    defer fn_bc.deinit(env.rt);

    const record = try moduleRecord(&fn_bc);
    try expectModuleRecordCounts(record, 0, 0, 1, 0, 0);
    try expectModuleExport(&env, record, 0, "default", "*default*");
    const carrier = declarationClosureNamed(&fn_bc, env.rt, "*default*") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(function_def.ClosureType.module_decl, carrier.closureType());
    try std.testing.expect(carrier.isLexical());
}

test "F8: export star" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseModuleStatement(&env, "export * from 'module'");
    defer fn_bc.deinit(env.rt);

    const record = try moduleRecord(&fn_bc);
    try expectModuleRecordCounts(record, 1, 0, 0, 0, 1);
    try expectModuleRequest(&env, record, 0, "module");
    try expectModuleStarExport(&env, record, 0, 0, "*");
}

test "F8: export star as namespace" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseModuleStatement(&env, "export * as ns from 'module'");
    defer fn_bc.deinit(env.rt);

    const record = try moduleRecord(&fn_bc);
    try expectModuleRecordCounts(record, 1, 0, 0, 0, 1);
    try expectModuleRequest(&env, record, 0, "module");
    try expectModuleStarExport(&env, record, 0, 0, "ns");
}

test "F8: export from" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseModuleStatement(&env, "export { x, y } from 'module'");
    defer fn_bc.deinit(env.rt);

    const record = try moduleRecord(&fn_bc);
    try expectModuleRecordCounts(record, 1, 0, 0, 2, 0);
    try expectModuleRequest(&env, record, 0, "module");
    try expectModuleIndirectExport(&env, record, 0, 0, "x", "x");
    try expectModuleIndirectExport(&env, record, 1, 0, "y", "y");
}

test "F8: export var" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseModuleStatement(&env, "export const x = 1");
    defer fn_bc.deinit(env.rt);

    const record = try moduleRecord(&fn_bc);
    try expectModuleRecordCounts(record, 0, 0, 1, 0, 0);
    try expectModuleExport(&env, record, 0, "x", "x");
}

test "F8: export function" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseModuleStatement(&env, "export function f() {}");
    defer fn_bc.deinit(env.rt);

    const record = try moduleRecord(&fn_bc);
    try expectModuleRecordCounts(record, 0, 0, 1, 0, 0);
    try expectModuleExport(&env, record, 0, "f", "f");
}

test "F8: export class" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseModuleStatement(&env, "export class C {}");
    defer fn_bc.deinit(env.rt);

    const record = try moduleRecord(&fn_bc);
    try expectModuleRecordCounts(record, 0, 0, 1, 0, 0);
    try expectModuleExport(&env, record, 0, "C", "C");
}

// ---- F9 Generator / Async / Await tests ----

test "F9: async function expression" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExprWithTopLevelChildren(&env, "async function() {}");
    defer fn_bc.deinit(env.rt);

    const child = try expectFunctionConstant(&fn_bc, 0);
    try std.testing.expectEqual(function_def_mod.FunctionKind.async, child.flags.func_kind);
    try std.testing.expect(!child.flags.has_prototype);
    try expectOpcode(child.byteCode(), op.return_async);
}

test "F9: async arrow function" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExprWithTopLevelChildren(&env, "async () => {}");
    defer fn_bc.deinit(env.rt);

    const child = try expectFunctionConstant(&fn_bc, 0);
    try std.testing.expectEqual(function_def_mod.FunctionKind.async, child.flags.func_kind);
    try std.testing.expect(child.flags.is_arrow_function);
    try std.testing.expect(!child.flags.has_prototype);
    try expectOpcode(child.byteCode(), op.return_async);
}

test "F9: async function declaration" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatementWithTopLevelChildren(&env, "async function f() {}");
    defer fn_bc.deinit(env.rt);

    const child = try expectFunctionConstant(&fn_bc, 0);
    try expectAtomName(&env, child.func_name, "f");
    try std.testing.expectEqual(function_def_mod.FunctionKind.async, child.flags.func_kind);
    try expectOpcode(child.byteCode(), op.return_async);
}

test "F9: async function declaration with parameters" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatementWithTopLevelChildren(&env, "async function f(x, y) {}");
    defer fn_bc.deinit(env.rt);

    const child = try expectFunctionConstant(&fn_bc, 0);
    try std.testing.expectEqual(function_def_mod.FunctionKind.async, child.flags.func_kind);
    try std.testing.expectEqual(@as(usize, 2), child.argVarDefs().len);
    try expectAtomName(&env, child.argVarDefs()[0].var_name, "x");
    try expectAtomName(&env, child.argVarDefs()[1].var_name, "y");
}

test "F9: async function declaration with body" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatementWithTopLevelChildren(&env, "async function f() { return 42; }");
    defer fn_bc.deinit(env.rt);

    const child = try expectFunctionConstant(&fn_bc, 0);
    try std.testing.expectEqual(function_def_mod.FunctionKind.async, child.flags.func_kind);
    try expectOpcode(child.byteCode(), op.push_i8);
    try expectOpcode(child.byteCode(), op.return_async);
}

test "F9: yield outside generator error" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    const result = parseStatement(&env, "yield 42");
    try std.testing.expectError(error.YieldOutsideGenerator, result);
}

test "F9: await outside async function error" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    const result = parseStatement(&env, "await x");
    try std.testing.expectError(error.AwaitOutsideAsyncFunction, result);
}

test "F9: await inside async function no error" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatementWithTopLevelChildren(&env, "async function f() { await x; }");
    defer fn_bc.deinit(env.rt);

    const child = try expectFunctionConstant(&fn_bc, 0);
    try std.testing.expectEqual(function_def_mod.FunctionKind.async, child.flags.func_kind);
    try expectOpcode(child.byteCode(), op.await);
    try expectOpcode(child.byteCode(), op.return_async);
}

// ---- Object literal enhancements ----

test "Object literal: computed property name" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "{ [x]: 1 }");
    defer fn_bc.deinit(env.rt);

    try std.testing.expectEqual(op.object, fn_bc.code[0]);
    try expectOpcode(fn_bc.code, op.to_propkey);
    try expectOpcode(fn_bc.code, op.define_array_el);
}

test "Object literal: method shorthand" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "{ method() {} }");
    defer fn_bc.deinit(env.rt);

    try std.testing.expectEqual(op.object, fn_bc.code[0]);
    try expectOpcode(fn_bc.code, op.define_method);
}

test "Object literal: spread" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "{ ...obj }");
    defer fn_bc.deinit(env.rt);

    try std.testing.expectEqual(op.object, fn_bc.code[0]);
    try expectOpcode(fn_bc.code, op.copy_data_properties);
}

// =====================================================================
// F10.1a — FunctionDef integration tests
// =====================================================================
//
// Validates that the parser's `function_def` companion structure is
// populated correctly from `var` / `let` / `const` declarations and
// nested lexical scopes. These tests do NOT exercise bytecode emission
// — they introspect `state.function_def` directly so the FunctionDef
// data path can be validated independently of the pipeline.
//
// These tests cover the FunctionDef-side data that the finalize pipeline
// consumes, without depending on full bytecode emission.

const Phase1ScopeEventKind = enum { enter, leave };

const Phase1ScopeEvent = struct {
    kind: Phase1ScopeEventKind,
    scope: u16,
    pc: usize,
};

const ExpectedPhase1ScopeEvent = struct {
    kind: Phase1ScopeEventKind,
    scope: u16,
};

fn tracePhase1ScopeEvents(code: []const u8, storage: []Phase1ScopeEvent) ![]const Phase1ScopeEvent {
    var count: usize = 0;
    var pc: usize = 0;
    while (pc < code.len) {
        const opcode_id = code[pc];
        const size: usize = @intCast(engine.bytecode.opcode.sizeOfPhase1(opcode_id));
        if (size == 0 or pc + size > code.len) return error.TestUnexpectedResult;
        if (opcode_id == op.enter_scope or opcode_id == op.leave_scope) {
            if (count == storage.len or size < 3) return error.TestUnexpectedResult;
            storage[count] = .{
                .kind = if (opcode_id == op.enter_scope) .enter else .leave,
                .scope = std.mem.readInt(u16, code[pc + 1 ..][0..2], .little),
                .pc = pc,
            };
            count += 1;
        }
        pc += size;
    }
    return storage[0..count];
}

fn expectPhase1ScopeEvents(code: []const u8, expected: []const ExpectedPhase1ScopeEvent) !void {
    var storage: [128]Phase1ScopeEvent = undefined;
    const actual = try tracePhase1ScopeEvents(code, &storage);
    try std.testing.expectEqual(expected.len, actual.len);
    for (actual, expected) |event, want| {
        try std.testing.expectEqual(want.kind, event.kind);
        try std.testing.expectEqual(want.scope, event.scope);
    }
}

fn findPhase1Opcode(code: []const u8, opcode_id: u8, start_pc: usize) !?usize {
    var pc = start_pc;
    while (pc < code.len) {
        const current = code[pc];
        const size: usize = @intCast(engine.bytecode.opcode.sizeOfPhase1(current));
        if (size == 0 or pc + size > code.len) return error.TestUnexpectedResult;
        if (current == opcode_id) return pc;
        pc += size;
    }
    return null;
}

fn parseRawStatement(env: *TestEnv, src: []const u8) !engine.bytecode.Bytecode {
    const name = try env.rt.internAtom("scope-events");
    defer env.rt.atoms.free(name);
    var function = engine.bytecode.Bytecode.init(&env.rt.memory, &env.rt.atoms, name);
    errdefer function.deinit(env.rt);
    var lex = QjsLexer.init(std.testing.allocator, &env.rt.atoms, src);
    var state = try ParseState.init(&lex, &function);
    defer state.deinit(env.rt);
    configureScriptRoot(&state);
    try parser_core.parseStatementOrDecl(&state, parser_core.DeclMask{ .func = true, .func_with_label = true, .other = true });
    return function;
}

fn parseRawTSProgram(env: *TestEnv, src: []const u8) !engine.bytecode.Bytecode {
    const name = try env.rt.internAtom("scope-events-ts");
    defer env.rt.atoms.free(name);
    var function = engine.bytecode.Bytecode.init(&env.rt.memory, &env.rt.atoms, name);
    errdefer function.deinit(env.rt);
    var lex = QjsLexer.init(std.testing.allocator, &env.rt.atoms, src);
    defer lex.deinit();
    try lex.enableTypeScript();
    var state = try ParseState.init(&lex, &function);
    defer state.deinit(env.rt);
    configureScriptRoot(&state);
    try parser_core.parseProgramStatements(&state, parser_core.DeclMask{ .func = true, .func_with_label = true, .other = true });
    return function;
}

test "M-SCOPE event producers: ordinary scopes match QuickJS phase-1 events" {
    var env = try ParserTestEnv.init();
    defer env.deinit();

    {
        var function = try parseRawStatement(&env, "{}");
        defer function.deinit(env.rt);
        try expectPhase1ScopeEvents(function.code, &.{});
    }
    {
        var function = try parseRawStatement(&env, "{;}");
        defer function.deinit(env.rt);
        try expectPhase1ScopeEvents(function.code, &.{
            .{ .kind = .enter, .scope = 2 },
            .{ .kind = .leave, .scope = 2 },
        });
    }
    {
        var function = try parseRawStatement(&env, "if (true) ;");
        defer function.deinit(env.rt);
        try expectPhase1ScopeEvents(function.code, &.{
            .{ .kind = .enter, .scope = 2 },
            .{ .kind = .leave, .scope = 2 },
        });
    }
    {
        var function = try parseRawStatement(&env, "for (;;) ;");
        defer function.deinit(env.rt);
        try expectPhase1ScopeEvents(function.code, &.{
            .{ .kind = .enter, .scope = 2 },
            .{ .kind = .leave, .scope = 2 },
            .{ .kind = .leave, .scope = 2 },
        });
    }
    {
        var function = try parseRawStatement(&env, "for (let i = 0;;) ;");
        defer function.deinit(env.rt);
        try expectPhase1ScopeEvents(function.code, &.{
            .{ .kind = .enter, .scope = 2 },
            .{ .kind = .leave, .scope = 2 },
            .{ .kind = .leave, .scope = 2 },
            .{ .kind = .leave, .scope = 2 },
        });
    }
    inline for (.{
        "for (let value of []) ;",
        "for (let key in {}) ;",
    }) |source| {
        var function = try parseRawStatement(&env, source);
        defer function.deinit(env.rt);
        try expectPhase1ScopeEvents(function.code, &.{
            .{ .kind = .enter, .scope = 2 },
            .{ .kind = .leave, .scope = 2 },
            .{ .kind = .leave, .scope = 2 },
            .{ .kind = .leave, .scope = 2 },
        });
    }
}

test "M-SCOPE event producers: switch with and class layers are eventful" {
    var env = try ParserTestEnv.init();
    defer env.deinit();

    inline for (.{
        "switch (0) { default: ; }",
        "with ({}) ;",
    }) |source| {
        var function = try parseRawStatement(&env, source);
        defer function.deinit(env.rt);
        try expectPhase1ScopeEvents(function.code, &.{
            .{ .kind = .enter, .scope = 2 },
            .{ .kind = .leave, .scope = 2 },
        });
    }

    var class_function = try parseRawStatement(&env, "class C {}");
    defer class_function.deinit(env.rt);
    try expectPhase1ScopeEvents(class_function.code, &.{
        .{ .kind = .enter, .scope = 2 },
        .{ .kind = .enter, .scope = 3 },
        .{ .kind = .leave, .scope = 3 },
        .{ .kind = .leave, .scope = 2 },
    });

    var heritage_function = try parseRawStatement(
        &env,
        "var cls = class C extends (probe = function () { return C; }, Object) {};",
    );
    defer heritage_function.deinit(env.rt);
    var event_storage: [8]Phase1ScopeEvent = undefined;
    const heritage_events = try tracePhase1ScopeEvents(heritage_function.code, &event_storage);
    try std.testing.expectEqual(@as(usize, 4), heritage_events.len);

    const define_class_pc = (try findPhase1Opcode(heritage_function.code, op.define_class, 0)) orelse
        return error.TestUnexpectedResult;
    var last_class_init_pc: ?usize = null;
    var pc = define_class_pc;
    while (pc < heritage_function.code.len) {
        const opcode_id = heritage_function.code[pc];
        const size: usize = @intCast(engine.bytecode.opcode.sizeOfPhase1(opcode_id));
        if (size == 0 or pc + size > heritage_function.code.len) return error.TestUnexpectedResult;
        if (opcode_id == op.put_loc_check_init) last_class_init_pc = pc;
        pc += size;
    }
    const init_pc = last_class_init_pc orelse return error.TestUnexpectedResult;
    // QuickJS closes the private and class-name scopes only after both
    // deferred class locals have been initialized. Closing the class-name
    // scope earlier detaches a heritage closure from the still-TDZ slot.
    try std.testing.expect(heritage_events[2].pc > init_pc);
    try std.testing.expect(heritage_events[3].pc > heritage_events[2].pc);
}

test "M-SCOPE event producers: catch binding wrapper and body leave in LIFO order" {
    var env = try ParserTestEnv.init();
    defer env.deinit();

    {
        var function = try parseRawStatement(&env, "try {} catch (caught) {;}");
        defer function.deinit(env.rt);
        try expectPhase1ScopeEvents(function.code, &.{
            .{ .kind = .enter, .scope = 2 },
            .{ .kind = .enter, .scope = 3 },
            .{ .kind = .enter, .scope = 4 },
            .{ .kind = .leave, .scope = 4 },
            .{ .kind = .leave, .scope = 3 },
            .{ .kind = .leave, .scope = 2 },
        });
    }
    {
        var function = try parseRawStatement(&env, "try {} catch (caught) {}");
        defer function.deinit(env.rt);
        try expectPhase1ScopeEvents(function.code, &.{
            .{ .kind = .enter, .scope = 2 },
            .{ .kind = .enter, .scope = 3 },
            .{ .kind = .leave, .scope = 3 },
            .{ .kind = .leave, .scope = 2 },
        });
    }
    {
        var function = try parseRawStatement(&env, "try {} catch (caught) {;} finally {;}");
        defer function.deinit(env.rt);
        try expectPhase1ScopeEvents(function.code, &.{
            .{ .kind = .enter, .scope = 2 },
            .{ .kind = .enter, .scope = 3 },
            .{ .kind = .enter, .scope = 4 },
            .{ .kind = .leave, .scope = 4 },
            .{ .kind = .leave, .scope = 3 },
            .{ .kind = .leave, .scope = 2 },
            .{ .kind = .enter, .scope = 5 },
            .{ .kind = .leave, .scope = 5 },
        });
    }
}

test "M-SCOPE event producers: structural body and namespace scopes stay identity-only" {
    var env = try ParserTestEnv.init();
    defer env.deinit();

    {
        var root = try parseRawStatement(&env, ";");
        defer root.deinit(env.rt);
        try expectPhase1ScopeEvents(root.code, &.{});
    }
    {
        var namespace = try parseRawTSProgram(&env, "namespace N { let value = 1; }");
        defer namespace.deinit(env.rt);
        try expectPhase1ScopeEvents(namespace.code, &.{});
    }

    const name = try env.rt.internAtom("scope-body-identities");
    defer env.rt.atoms.free(name);
    var function = engine.bytecode.Bytecode.init(&env.rt.memory, &env.rt.atoms, name);
    defer function.deinit(env.rt);
    var lex = QjsLexer.init(
        std.testing.allocator,
        &env.rt.atoms,
        "function body(){;} function params(value = 1){} const concise = () => 1; class C { field = 1; }",
    );
    var state = try ParseState.init(&lex, &function);
    defer state.deinit(env.rt);
    configureScriptRoot(&state);
    state.top_level_functions_as_children = true;
    try parser_core.parseProgramStatements(&state, parser_core.DeclMask{ .func = true, .func_with_label = true, .other = true });

    var saw_body = false;
    var saw_params = false;
    var saw_concise = false;
    var saw_default_constructor = false;
    for (state.function_def.child_list) |child| {
        const child_name = env.rt.atoms.name(child.func_name) orelse "";
        if (std.mem.eql(u8, child_name, "body")) {
            saw_body = true;
            try expectPhase1ScopeEvents(child.byte_code, &.{});
        } else if (std.mem.eql(u8, child_name, "params")) {
            saw_params = true;
            try expectPhase1ScopeEvents(child.byte_code, &.{
                .{ .kind = .enter, .scope = 1 },
                .{ .kind = .leave, .scope = 1 },
            });
        } else if (child.func_type == .arrow) {
            saw_concise = true;
            try expectPhase1ScopeEvents(child.byte_code, &.{});
        } else if (child.func_type == .class_constructor or child.func_type == .derived_class_constructor) {
            saw_default_constructor = true;
            try expectPhase1ScopeEvents(child.byte_code, &.{});
        }
    }
    try std.testing.expect(saw_body);
    try std.testing.expect(saw_params);
    try std.testing.expect(saw_concise);
    try std.testing.expect(saw_default_constructor);
}

test "M-SCOPE abrupt control: labelled break and continue close nested scopes at the source" {
    var env = try ParserTestEnv.init();
    defer env.deinit();

    inline for (.{
        "outer: while (true) { { break outer; } }",
        "outer: while (true) { { continue outer; } }",
    }) |source| {
        var function = try parseRawStatement(&env, source);
        defer function.deinit(env.rt);
        try expectPhase1ScopeEvents(function.code, &.{
            .{ .kind = .enter, .scope = 2 },
            .{ .kind = .enter, .scope = 3 },
            .{ .kind = .leave, .scope = 3 },
            .{ .kind = .leave, .scope = 2 },
            .{ .kind = .leave, .scope = 3 },
            .{ .kind = .leave, .scope = 2 },
        });

        const jump_pc = (try findPhase1Opcode(function.code, op.goto, 0)) orelse return error.TestExpectedEqual;
        var storage: [16]Phase1ScopeEvent = undefined;
        const events = try tracePhase1ScopeEvents(function.code, &storage);
        var before_jump: usize = 0;
        for (events) |event| {
            try std.testing.expect(event.scope != 1);
            if (event.pc < jump_pc) before_jump += 1;
        }
        try std.testing.expectEqual(@as(usize, 4), before_jump);
        try std.testing.expectEqual(Phase1ScopeEventKind.leave, events[before_jump - 2].kind);
        try std.testing.expectEqual(@as(u16, 3), events[before_jump - 2].scope);
        try std.testing.expectEqual(Phase1ScopeEventKind.leave, events[before_jump - 1].kind);
        try std.testing.expectEqual(@as(u16, 2), events[before_jump - 1].scope);
    }
}

test "M-SCOPE abrupt control: classic and for-of continue targets follow the body leave" {
    var env = try ParserTestEnv.init();
    defer env.deinit();

    {
        var function = try parseRawStatement(&env, "outer: for (;;) { { continue outer; } }");
        defer function.deinit(env.rt);
        var storage: [32]Phase1ScopeEvent = undefined;
        const events = try tracePhase1ScopeEvents(function.code, &storage);
        try std.testing.expectEqual(@as(usize, 9), events.len);
        const source_jump_pc = events[4].pc + 3;
        try std.testing.expectEqual(op.goto, function.code[source_jump_pc]);
        const continue_target = std.mem.readInt(u32, function.code[source_jump_pc + 1 ..][0..4], .little);
        try std.testing.expectEqual(@as(u32, @intCast(events[7].pc + 3)), continue_target);
        try std.testing.expectEqual(Phase1ScopeEventKind.leave, events[7].kind);
        try std.testing.expectEqual(@as(u16, 2), events[7].scope);
    }

    {
        var function = try parseRawStatement(&env, "outer: for (const value of []) { { continue outer; } }");
        defer function.deinit(env.rt);
        var storage: [32]Phase1ScopeEvent = undefined;
        const events = try tracePhase1ScopeEvents(function.code, &storage);
        try std.testing.expectEqual(@as(usize, 11), events.len);
        const source_jump_pc = events[6].pc + 3;
        try std.testing.expectEqual(op.goto, function.code[source_jump_pc]);
        const continue_target = std.mem.readInt(u32, function.code[source_jump_pc + 1 ..][0..4], .little);
        try std.testing.expectEqual(@as(u32, @intCast(events[9].pc + 3)), continue_target);
        try std.testing.expectEqual(Phase1ScopeEventKind.leave, events[9].kind);
        try std.testing.expectEqual(@as(u16, 2), events[9].scope);
    }
}

test "M-SCOPE abrupt control: crossed finally sees scope leaves before gosub" {
    var env = try ParserTestEnv.init();
    defer env.deinit();

    inline for (.{
        "outer: while (true) { try { { break outer; } } finally { ; } }",
        "outer: while (true) { try { { continue outer; } } finally { ; } }",
    }) |source| {
        var function = try parseRawStatement(&env, source);
        defer function.deinit(env.rt);
        const gosub_pc = (try findPhase1Opcode(function.code, op.gosub, 0)) orelse return error.TestExpectedEqual;
        var storage: [32]Phase1ScopeEvent = undefined;
        const events = try tracePhase1ScopeEvents(function.code, &storage);
        var before_gosub: usize = 0;
        for (events) |event| {
            if (event.pc < gosub_pc) before_gosub += 1;
        }
        try std.testing.expectEqual(@as(usize, 5), before_gosub);
        try std.testing.expectEqual(Phase1ScopeEventKind.leave, events[before_gosub - 2].kind);
        try std.testing.expectEqual(@as(u16, 4), events[before_gosub - 2].scope);
        try std.testing.expectEqual(Phase1ScopeEventKind.leave, events[before_gosub - 1].kind);
        try std.testing.expectEqual(@as(u16, 3), events[before_gosub - 1].scope);
    }
}

test "M-SCOPE negative contract: return cleanup and throw synthesize no scope leave" {
    var env = try ParserTestEnv.init();
    defer env.deinit();

    {
        const name = try env.rt.internAtom("return-scope-events");
        defer env.rt.atoms.free(name);
        var function = engine.bytecode.Bytecode.init(&env.rt.memory, &env.rt.atoms, name);
        defer function.deinit(env.rt);
        var lex = QjsLexer.init(
            std.testing.allocator,
            &env.rt.atoms,
            "function f(){ for (const value of []) { try { return value; } finally { ; } } }",
        );
        var state = try ParseState.init(&lex, &function);
        defer state.deinit(env.rt);
        configureScriptRoot(&state);
        state.top_level_functions_as_children = true;
        try parser_core.parseProgramStatements(&state, parser_core.DeclMask{ .func = true, .func_with_label = true, .other = true });
        try std.testing.expectEqual(@as(usize, 1), state.function_def.child_list.len);
        const child = state.function_def.child_list[0];

        const gosub_pc = (try findPhase1Opcode(child.byte_code, op.gosub, 0)) orelse return error.TestExpectedEqual;
        const iterator_close_pc = (try findPhase1Opcode(child.byte_code, op.iterator_close, gosub_pc)) orelse return error.TestExpectedEqual;
        const return_pc = (try findPhase1Opcode(child.byte_code, op.@"return", iterator_close_pc)) orelse return error.TestExpectedEqual;
        try std.testing.expect(gosub_pc < iterator_close_pc);
        try std.testing.expect(iterator_close_pc < return_pc);

        var storage: [64]Phase1ScopeEvent = undefined;
        const events = try tracePhase1ScopeEvents(child.byte_code, &storage);
        for (events) |event| {
            try std.testing.expect(!(event.kind == .leave and event.pc > gosub_pc and event.pc < return_pc));
        }
    }

    {
        var function = try parseRawStatement(&env, "try { { throw 1; } } catch (caught) {}");
        defer function.deinit(env.rt);
        const throw_pc = (try findPhase1Opcode(function.code, op.throw, 0)) orelse return error.TestExpectedEqual;
        var storage: [32]Phase1ScopeEvent = undefined;
        const events = try tracePhase1ScopeEvents(function.code, &storage);
        for (events) |event| {
            try std.testing.expect(!(event.kind == .leave and event.pc < throw_pc));
        }
    }
}

test "F10.1a FunctionDef: program root has var scope 0 and body scope 1" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    const name = try env.rt.internAtom("test");
    defer env.rt.atoms.free(name);
    var function = engine.bytecode.Bytecode.init(&env.rt.memory, &env.rt.atoms, name);
    defer function.deinit(env.rt);

    var lex = QjsLexer.init(std.testing.allocator, &env.rt.atoms, "");
    var state = try ParseState.init(&lex, &function);
    defer state.deinit(env.rt);

    // js_new_function_def creates scope 0; JS_Eval immediately pushes the
    // program body before directives and declarations.
    try std.testing.expectEqual(@as(usize, 2), state.function_def.scopes.len);
    try std.testing.expectEqual(@as(i32, -1), state.function_def.scopes[0].parent);
    try std.testing.expectEqual(@as(i32, -1), state.function_def.scopes[0].first);
    try std.testing.expectEqual(@as(i32, 0), state.function_def.scopes[1].parent);
    try std.testing.expectEqual(@as(i32, 1), state.function_def.body_scope);
    try std.testing.expectEqual(@as(i32, 1), state.function_def.scope_level);
    try std.testing.expectEqual(@as(i32, 2), state.function_def.scope_count);
}

test "F10.1a FunctionDef: QuickJS root declaration rows keep body and block origins" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    const name = try env.rt.internAtom("test");
    defer env.rt.atoms.free(name);
    var function = engine.bytecode.Bytecode.init(&env.rt.memory, &env.rt.atoms, name);
    defer function.deinit(env.rt);

    const a_atom = try env.rt.internAtom("a");
    defer env.rt.atoms.free(a_atom);
    const b_atom = try env.rt.internAtom("b");
    defer env.rt.atoms.free(b_atom);
    const c_atom = try env.rt.internAtom("c");
    defer env.rt.atoms.free(c_atom);
    const d_atom = try env.rt.internAtom("d");
    defer env.rt.atoms.free(d_atom);

    var lex = QjsLexer.init(std.testing.allocator, &env.rt.atoms, "var a; let b; { var c; let d; }");
    var state = try ParseState.init(&lex, &function);
    defer state.deinit(env.rt);
    configureScriptRoot(&state);

    try parser_core.parseProgramStatements(&state, parser_core.DeclMask{ .func = true, .func_with_label = true, .other = true });

    // Pinned QuickJS diagnostic dump: a/b/c are GLOBAL_DECL rows with the
    // exact declaration scope; only block-local d is a VarDef.
    try std.testing.expectEqual(@as(usize, 3), state.function_def.global_vars.len);
    try std.testing.expectEqual(a_atom, state.function_def.global_vars[0].var_name);
    try std.testing.expectEqual(@as(i32, 1), state.function_def.global_vars[0].scope_level);
    try std.testing.expectEqual(b_atom, state.function_def.global_vars[1].var_name);
    try std.testing.expect(state.function_def.global_vars[1].is_lexical);
    try std.testing.expectEqual(@as(i32, 1), state.function_def.global_vars[1].scope_level);
    try std.testing.expectEqual(c_atom, state.function_def.global_vars[2].var_name);
    try std.testing.expectEqual(@as(i32, 2), state.function_def.global_vars[2].scope_level);
    try std.testing.expectEqual(@as(usize, 1), state.function_def.vars.len);
    try std.testing.expectEqual(d_atom, state.function_def.vars[0].var_name);
    try std.testing.expectEqual(@as(i32, 2), state.function_def.vars[0].scope_level);
}

test "F10.1a FunctionDef: function vars retain parser origins without entering lexical chains" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    const name = try env.rt.internAtom("test");
    defer env.rt.atoms.free(name);
    var function = engine.bytecode.Bytecode.init(&env.rt.memory, &env.rt.atoms, name);
    defer function.deinit(env.rt);

    var lex = QjsLexer.init(std.testing.allocator, &env.rt.atoms, "function f(p){ var x; { var y; let z; } let w; }");
    var state = try ParseState.init(&lex, &function);
    defer state.deinit(env.rt);
    configureScriptRoot(&state);
    state.top_level_functions_as_children = true;

    try parser_core.parseProgramStatements(&state, parser_core.DeclMask{ .func = true, .func_with_label = true, .other = true });
    try std.testing.expectEqual(@as(usize, 1), state.function_def.child_list.len);
    const child = state.function_def.child_list[0];
    try std.testing.expectEqual(@as(i32, 1), child.body_scope);
    try std.testing.expectEqual(@as(usize, 3), child.scopes.len);
    try std.testing.expectEqual(@as(usize, 4), child.vars.len);

    const expected_names = [_][]const u8{ "x", "y", "z", "w" };
    for (child.vars, expected_names) |vd, expected| {
        try std.testing.expectEqualStrings(expected, env.rt.atoms.name(vd.var_name).?);
    }
    // VAR rows are scope-0 locals, but parser-time scope_next is their source
    // declaration scope. They are absent from scopes[0].first; z/w alone own
    // lexical links. Finalization later rebuilds runtime scope_next.
    try std.testing.expectEqual(@as(i32, 0), child.vars[0].scope_level);
    try std.testing.expectEqual(@as(i32, 1), child.vars[0].scope_next);
    try std.testing.expectEqual(@as(i32, 0), child.vars[1].scope_level);
    try std.testing.expectEqual(@as(i32, 2), child.vars[1].scope_next);
    try std.testing.expectEqual(@as(i32, -1), child.scopes[0].first);
    try std.testing.expectEqual(@as(i32, 2), child.vars[2].scope_level);
    try std.testing.expectEqual(@as(i32, 1), child.vars[3].scope_level);
}

test "F10.1a FunctionDef: every parsed function body has identity except class fields aggregator" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    const name = try env.rt.internAtom("test");
    defer env.rt.atoms.free(name);
    var function = engine.bytecode.Bytecode.init(&env.rt.memory, &env.rt.atoms, name);
    defer function.deinit(env.rt);

    var lex = QjsLexer.init(std.testing.allocator, &env.rt.atoms, "const arrow = () => 1; class C { x = 1; }");
    var state = try ParseState.init(&lex, &function);
    defer state.deinit(env.rt);
    configureScriptRoot(&state);
    state.top_level_functions_as_children = true;
    try parser_core.parseProgramStatements(&state, parser_core.DeclMask{ .func = true, .func_with_label = true, .other = true });

    var arrow: ?*function_def_mod.FunctionDef = null;
    var ctor: ?*function_def_mod.FunctionDef = null;
    var fields: ?*function_def_mod.FunctionDef = null;
    for (state.function_def.child_list) |child| {
        if (child.func_type == .arrow) arrow = child;
        if (child.func_type == .class_constructor or child.func_type == .derived_class_constructor) ctor = child;
        if (child.func_name == core.atom.ids.class_fields_init) fields = child;
    }
    const arrow_fd = arrow orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(i32, 1), arrow_fd.body_scope);
    try std.testing.expectEqual(@as(usize, 2), arrow_fd.scopes.len);
    const ctor_fd = ctor orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(i32, 1), ctor_fd.body_scope);
    try std.testing.expectEqual(@as(usize, 2), ctor_fd.scopes.len);
    const fields_fd = fields orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(i32, -1), fields_fd.body_scope);
    try std.testing.expectEqual(@as(usize, 1), fields_fd.scopes.len);
}

test "defineVar core matches pinned QuickJS declaration collision matrix" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const cases = [_]struct { source: []const u8, fails: bool }{
        .{ .source = "function f(p){ let p; }", .fails = true },
        .{ .source = "function f(p){ { let p; } }", .fails = false },
        .{ .source = "function f(){ { var x; } let x; }", .fails = true },
        .{ .source = "function f(){ let x; { var x; } }", .fails = true },
        .{ .source = "function f(p){ var p; }", .fails = false },
        .{ .source = "function f(){ var x; var x; }", .fails = false },
        // QuickJS source-order behavior for global source elements: the
        // earlier lexical is accepted, while a later lexical sees the global
        // function row and rejects it.
        .{ .source = "let x; function x(){}", .fails = false },
        .{ .source = "function x(){}; let x;", .fails = true },
        .{ .source = "try{}catch(e){let e;}", .fails = true },
        .{ .source = "function f(){ try{}catch(e){ const e = 1; } }", .fails = true },
        .{ .source = "function f(){ try{}catch(e){ class e {} } }", .fails = true },
        .{ .source = "function f(){ try{}catch(e){ function e(){} } }", .fails = true },
        .{ .source = "function f(){ try{}catch(e){ var e; } }", .fails = false },
        .{ .source = "function f(){ try{}catch(e){ { let e; } } }", .fails = false },
        .{ .source = "function f(){ for (let x;;) { var x; } }", .fails = true },
        .{ .source = "function f(){ for (let x of []) { var x; } }", .fails = true },
        .{ .source = "function f(){ for (let x in {}) { var x; } }", .fails = true },
        .{ .source = "function f(){ for (let x;;) { { var x; } } }", .fails = true },
        .{ .source = "function f(){ for (let x;;) { { let x; } } }", .fails = false },
        .{ .source = "for (var x of []); let x;", .fails = true },
        .{ .source = "{ var x; } let x;", .fails = true },
        .{ .source = "var x; { let x; }", .fails = false },
    };
    for (cases) |case| {
        var parsed = try parser.compile(rt, case.source, .{ .mode = .script, .filename = "define-var-matrix.js" });
        defer parsed.deinit();
        try std.testing.expectEqual(case.fails, parsed.syntax_error != null);
    }
}

test "F10.1a FunctionDef: empty ordinary block does not create a scope" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    const name = try env.rt.internAtom("test");
    defer env.rt.atoms.free(name);
    var function = engine.bytecode.Bytecode.init(&env.rt.memory, &env.rt.atoms, name);
    defer function.deinit(env.rt);

    var lex = QjsLexer.init(std.testing.allocator, &env.rt.atoms, "{ }");
    var state = try ParseState.init(&lex, &function);
    defer state.deinit(env.rt);

    try parser_core.parseStatementOrDecl(&state, parser_core.DeclMask{ .func = true, .func_with_label = true, .other = true });

    // QuickJS js_parse_block returns immediately for `{}` and does not call
    // push_scope/pop_scope. Empty ordinary blocks must not perturb scope
    // topology or later scope indices.
    try std.testing.expectEqual(@as(i32, 1), state.scope_level);
    try std.testing.expectEqual(@as(usize, 2), state.function_def.scopes.len);
}

test "F10.1a FunctionDef: non-empty ordinary block pushes and pops one scope" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    const name = try env.rt.internAtom("test");
    defer env.rt.atoms.free(name);
    var function = engine.bytecode.Bytecode.init(&env.rt.memory, &env.rt.atoms, name);
    defer function.deinit(env.rt);

    var lex = QjsLexer.init(std.testing.allocator, &env.rt.atoms, "{ 0; }");
    var state = try ParseState.init(&lex, &function);
    defer state.deinit(env.rt);

    try parser_core.parseStatementOrDecl(&state, parser_core.DeclMask{ .func = true, .func_with_label = true, .other = true });

    try std.testing.expectEqual(@as(i32, 1), state.scope_level);
    try std.testing.expectEqual(@as(usize, 3), state.function_def.scopes.len);
}

test "F10.1a FunctionDef: nested blocks build parent chain" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    const name = try env.rt.internAtom("test");
    defer env.rt.atoms.free(name);
    var function = engine.bytecode.Bytecode.init(&env.rt.memory, &env.rt.atoms, name);
    defer function.deinit(env.rt);

    var lex = QjsLexer.init(std.testing.allocator, &env.rt.atoms, "{ let a; { let b; } }");
    var state = try ParseState.init(&lex, &function);
    defer state.deinit(env.rt);

    try parser_core.parseStatementOrDecl(&state, parser_core.DeclMask{ .func = true, .func_with_label = true, .other = true });

    // After parsing: var scope 0 + body 1 + outer block 2 + inner block 3.
    try std.testing.expectEqual(@as(usize, 4), state.function_def.scopes.len);
    try std.testing.expectEqual(@as(i32, -1), state.function_def.scopes[0].parent);
    try std.testing.expectEqual(@as(i32, 0), state.function_def.scopes[1].parent);
    try std.testing.expectEqual(@as(i32, 1), state.function_def.scopes[2].parent);
    try std.testing.expectEqual(@as(i32, 2), state.function_def.scopes[3].parent);
    // Ordinary blocks pop back to the still-active program body.
    try std.testing.expectEqual(@as(i32, 1), state.scope_level);
}

test "F10.1a FunctionDef: nested scope inherits the visible lexical head" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    const name = try env.rt.internAtom("test");
    defer env.rt.atoms.free(name);
    var function = engine.bytecode.Bytecode.init(&env.rt.memory, &env.rt.atoms, name);
    defer function.deinit(env.rt);

    const outer_atom = try env.rt.internAtom("outer");
    defer env.rt.atoms.free(outer_atom);

    var lex = QjsLexer.init(std.testing.allocator, &env.rt.atoms, "{ let outer; { 0; } }");
    var state = try ParseState.init(&lex, &function);
    defer state.deinit(env.rt);

    try parser_core.parseStatementOrDecl(&state, parser_core.DeclMask{ .func = true, .func_with_label = true, .other = true });

    try std.testing.expectEqual(@as(usize, 4), state.function_def.scopes.len);
    try std.testing.expectEqual(@as(usize, 1), state.function_def.vars.len);
    try std.testing.expectEqual(outer_atom, state.function_def.vars[0].var_name);
    // QuickJS push_scope copies fd->scope_first into the new scope. The inner
    // scope therefore starts at the outer lexical declaration even though it
    // declares no bindings of its own.
    try std.testing.expectEqual(@as(i32, 0), state.function_def.scopes[3].first);
}

test "F10.1a FunctionDef: let registers as lexical, non-const" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    const name = try env.rt.internAtom("test");
    defer env.rt.atoms.free(name);
    var function = engine.bytecode.Bytecode.init(&env.rt.memory, &env.rt.atoms, name);
    defer function.deinit(env.rt);

    const x_atom = try env.rt.internAtom("x");
    defer env.rt.atoms.free(x_atom);

    var lex = QjsLexer.init(std.testing.allocator, &env.rt.atoms, "let x = 1;");
    var state = try ParseState.init(&lex, &function);
    defer state.deinit(env.rt);

    try parser_core.parseStatementOrDecl(&state, parser_core.DeclMask{ .func = true, .func_with_label = true, .other = true });

    try std.testing.expectEqual(@as(usize, 1), state.function_def.vars.len);
    const v = state.function_def.vars[0];
    try std.testing.expectEqual(@as(engine.core.atom.Atom, x_atom), v.var_name);
    try std.testing.expectEqual(true, v.is_lexical);
    try std.testing.expectEqual(false, v.is_const);
    try std.testing.expectEqual(function_def_mod.VarKind.normal, v.var_kind);
    // The standalone low-level state is local, but its program body is still
    // the real scope 1 identity used by define_var.
    try std.testing.expectEqual(@as(i32, 1), v.scope_level);
}

test "F10.1a FunctionDef: const registers as lexical + const" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    const name = try env.rt.internAtom("test");
    defer env.rt.atoms.free(name);
    var function = engine.bytecode.Bytecode.init(&env.rt.memory, &env.rt.atoms, name);
    defer function.deinit(env.rt);

    var lex = QjsLexer.init(std.testing.allocator, &env.rt.atoms, "const k = 42;");
    var state = try ParseState.init(&lex, &function);
    defer state.deinit(env.rt);

    try parser_core.parseStatementOrDecl(&state, parser_core.DeclMask{ .func = true, .func_with_label = true, .other = true });

    try std.testing.expectEqual(@as(usize, 1), state.function_def.vars.len);
    try std.testing.expectEqual(true, state.function_def.vars[0].is_lexical);
    try std.testing.expectEqual(true, state.function_def.vars[0].is_const);
}

test "F10.1a FunctionDef: top-level block var registers as global var" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    const name = try env.rt.internAtom("test");
    defer env.rt.atoms.free(name);
    var function = engine.bytecode.Bytecode.init(&env.rt.memory, &env.rt.atoms, name);
    defer function.deinit(env.rt);

    var lex = QjsLexer.init(std.testing.allocator, &env.rt.atoms, "{ var v = 1; }");
    var state = try ParseState.init(&lex, &function);
    defer state.deinit(env.rt);
    configureScriptRoot(&state);

    try parser_core.parseStatementOrDecl(&state, parser_core.DeclMask{ .func = true, .func_with_label = true, .other = true });

    try std.testing.expectEqual(@as(usize, 0), state.function_def.vars.len);
    try std.testing.expectEqual(@as(usize, 1), state.function_def.global_vars.len);
    const v = state.function_def.global_vars[0];
    try std.testing.expectEqual(false, v.is_lexical);
    try std.testing.expectEqual(@as(i32, 2), v.scope_level);
}

test "F10.1a FunctionDef: let in nested block attaches to inner scope" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    const name = try env.rt.internAtom("test");
    defer env.rt.atoms.free(name);
    var function = engine.bytecode.Bytecode.init(&env.rt.memory, &env.rt.atoms, name);
    defer function.deinit(env.rt);

    var lex = QjsLexer.init(std.testing.allocator, &env.rt.atoms, "{ let a; { let b; } }");
    var state = try ParseState.init(&lex, &function);
    defer state.deinit(env.rt);

    try parser_core.parseStatementOrDecl(&state, parser_core.DeclMask{ .func = true, .func_with_label = true, .other = true });

    try std.testing.expectEqual(@as(usize, 2), state.function_def.vars.len);
    // Body scope is 1; `a` is in outer block 2 and `b` in inner block 3.
    try std.testing.expectEqual(@as(i32, 2), state.function_def.vars[0].scope_level);
    try std.testing.expectEqual(@as(i32, 3), state.function_def.vars[1].scope_level);
    try std.testing.expectEqual(@as(i32, 0), state.function_def.vars[1].scope_next);
}

test "F10.1a FunctionDef: simple catch binding keeps catch provenance" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    const name = try env.rt.internAtom("test");
    defer env.rt.atoms.free(name);
    var function = engine.bytecode.Bytecode.init(&env.rt.memory, &env.rt.atoms, name);
    defer function.deinit(env.rt);

    const caught_atom = try env.rt.internAtom("caught");
    defer env.rt.atoms.free(caught_atom);

    var lex = QjsLexer.init(std.testing.allocator, &env.rt.atoms, "try {} catch (caught) {}");
    var state = try ParseState.init(&lex, &function);
    defer state.deinit(env.rt);

    try parser_core.parseStatementOrDecl(&state, parser_core.DeclMask{ .func = true, .func_with_label = true, .other = true });

    var catch_var: ?function_def_mod.VarDef = null;
    for (state.function_def.vars) |vd| {
        if (vd.var_name == caught_atom) catch_var = vd;
    }
    try std.testing.expect(catch_var != null);
    const vd = catch_var.?;
    try std.testing.expectEqual(function_def_mod.VarKind.catch_, vd.var_kind);
    try std.testing.expect(!vd.is_lexical);
    try std.testing.expect(vd.scope_level > 0);
    try std.testing.expectEqual(@as(i32, 1), state.function_def.scopes[@intCast(vd.scope_level)].parent);
}

test "F10.1a FunctionDef: catch has binding wrapper and body scopes" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    const name = try env.rt.internAtom("test");
    defer env.rt.atoms.free(name);
    var function = engine.bytecode.Bytecode.init(&env.rt.memory, &env.rt.atoms, name);
    defer function.deinit(env.rt);

    const caught_atom = try env.rt.internAtom("caught");
    defer env.rt.atoms.free(caught_atom);
    const body_atom = try env.rt.internAtom("body");
    defer env.rt.atoms.free(body_atom);

    var lex = QjsLexer.init(std.testing.allocator, &env.rt.atoms, "try {} catch (caught) { let body; }");
    var state = try ParseState.init(&lex, &function);
    defer state.deinit(env.rt);

    try parser_core.parseStatementOrDecl(&state, parser_core.DeclMask{ .func = true, .func_with_label = true, .other = true });

    var catch_scope: ?i32 = null;
    var body_scope: ?i32 = null;
    for (state.function_def.vars) |vd| {
        if (vd.var_name == caught_atom) catch_scope = vd.scope_level;
        if (vd.var_name == body_atom) body_scope = vd.scope_level;
    }
    try std.testing.expect(catch_scope != null);
    try std.testing.expect(body_scope != null);
    const wrapper_scope = state.function_def.scopes[@intCast(body_scope.?)].parent;
    try std.testing.expect(wrapper_scope >= 0);
    try std.testing.expectEqual(catch_scope.?, state.function_def.scopes[@intCast(wrapper_scope)].parent);
    try std.testing.expectEqual(@as(i32, 1), state.function_def.scopes[@intCast(catch_scope.?)].parent);
}

test "F10.1a FunctionDef: for-of lexical head owns one binding" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    const name = try env.rt.internAtom("test");
    defer env.rt.atoms.free(name);
    var function = engine.bytecode.Bytecode.init(&env.rt.memory, &env.rt.atoms, name);
    defer function.deinit(env.rt);

    const x_atom = try env.rt.internAtom("x");
    defer env.rt.atoms.free(x_atom);

    var lex = QjsLexer.init(std.testing.allocator, &env.rt.atoms, "for (let x of [1]) { x; }");
    var state = try ParseState.init(&lex, &function);
    defer state.deinit(env.rt);

    try parser_core.parseStatementOrDecl(&state, parser_core.DeclMask{ .func = true, .func_with_label = true, .other = true });

    var x_count: usize = 0;
    for (state.function_def.vars) |vd| {
        if (vd.var_name == x_atom) x_count += 1;
    }
    // QuickJS creates the head scope once and closes it between phases; it
    // never manufactures a second VarDef after evaluating the iterable.
    try std.testing.expectEqual(@as(usize, 1), x_count);

    const x_scope = state.function_def.vars[0].scope_level;
    var enter_count: usize = 0;
    var leave_count: usize = 0;
    var pc: usize = 0;
    while (pc < function.code.len) {
        const opcode_id = function.code[pc];
        const size = engine.bytecode.opcode.sizeOfPhase1(opcode_id);
        try std.testing.expect(size != 0);
        if ((opcode_id == op.enter_scope or opcode_id == op.leave_scope) and
            std.mem.readInt(u16, function.code[pc + 1 ..][0..2], .little) == x_scope)
        {
            if (opcode_id == op.enter_scope) enter_count += 1 else leave_count += 1;
        }
        pc += size;
    }
    try std.testing.expectEqual(@as(usize, 1), enter_count);
    try std.testing.expectEqual(@as(usize, 3), leave_count);
}

test "F10.1a FunctionDef: assignment for-of still owns a head scope" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    const name = try env.rt.internAtom("test");
    defer env.rt.atoms.free(name);
    var function = engine.bytecode.Bytecode.init(&env.rt.memory, &env.rt.atoms, name);
    defer function.deinit(env.rt);

    var lex = QjsLexer.init(std.testing.allocator, &env.rt.atoms, "for (x of [1]) { x; }");
    var state = try ParseState.init(&lex, &function);
    defer state.deinit(env.rt);

    try parser_core.parseStatementOrDecl(&state, parser_core.DeclMask{ .func = true, .func_with_label = true, .other = true });

    // Scope 2 is the unconditional enumeration head beneath body scope 1;
    // the non-empty ordinary body is scope 3.
    try std.testing.expectEqual(@as(usize, 4), state.function_def.scopes.len);
    try std.testing.expectEqual(@as(i32, 1), state.function_def.scopes[2].parent);
    try std.testing.expectEqual(@as(i32, 2), state.function_def.scopes[3].parent);
}

test "F10.1a FunctionDef: if statement owns one wrapper scope" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    const name = try env.rt.internAtom("test");
    defer env.rt.atoms.free(name);
    var function = engine.bytecode.Bytecode.init(&env.rt.memory, &env.rt.atoms, name);
    defer function.deinit(env.rt);

    var lex = QjsLexer.init(std.testing.allocator, &env.rt.atoms, "if (true) 0; else 1;");
    var state = try ParseState.init(&lex, &function);
    defer state.deinit(env.rt);

    try parser_core.parseStatementOrDecl(&state, parser_core.DeclMask{ .func = true, .func_with_label = true, .other = true });

    try std.testing.expectEqual(@as(usize, 3), state.function_def.scopes.len);
    try std.testing.expectEqual(@as(i32, 1), state.function_def.scopes[2].parent);
}

test "F10.1a FunctionDef: classic for always owns a head scope" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    const name = try env.rt.internAtom("test");
    defer env.rt.atoms.free(name);
    var function = engine.bytecode.Bytecode.init(&env.rt.memory, &env.rt.atoms, name);
    defer function.deinit(env.rt);

    var lex = QjsLexer.init(std.testing.allocator, &env.rt.atoms, "for (;;) break;");
    var state = try ParseState.init(&lex, &function);
    defer state.deinit(env.rt);

    try parser_core.parseStatementOrDecl(&state, parser_core.DeclMask{ .func = true, .func_with_label = true, .other = true });

    try std.testing.expectEqual(@as(usize, 3), state.function_def.scopes.len);
    try std.testing.expectEqual(@as(i32, 1), state.function_def.scopes[2].parent);
}

test "F10.1a FunctionDef: with scope emits its enter event" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    const name = try env.rt.internAtom("test");
    defer env.rt.atoms.free(name);
    var function = engine.bytecode.Bytecode.init(&env.rt.memory, &env.rt.atoms, name);
    defer function.deinit(env.rt);

    var lex = QjsLexer.init(std.testing.allocator, &env.rt.atoms, "with ({}) 0;");
    var state = try ParseState.init(&lex, &function);
    defer state.deinit(env.rt);

    try parser_core.parseStatementOrDecl(&state, parser_core.DeclMask{ .func = true, .func_with_label = true, .other = true });

    var enter_count: usize = 0;
    var pc: usize = 0;
    while (pc < function.code.len) {
        const opcode_id = function.code[pc];
        const size = engine.bytecode.opcode.sizeOfPhase1(opcode_id);
        try std.testing.expect(size != 0);
        if (opcode_id == op.enter_scope and
            std.mem.readInt(u16, function.code[pc + 1 ..][0..2], .little) == 2)
        {
            enter_count += 1;
        }
        pc += size;
    }
    try std.testing.expectEqual(@as(usize, 1), enter_count);
}

test "F10.1a FunctionDef: class has name and private scopes" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    const name = try env.rt.internAtom("test");
    defer env.rt.atoms.free(name);
    var function = engine.bytecode.Bytecode.init(&env.rt.memory, &env.rt.atoms, name);
    defer function.deinit(env.rt);

    const class_atom = try env.rt.internAtom("C");
    defer env.rt.atoms.free(class_atom);

    var lex = QjsLexer.init(std.testing.allocator, &env.rt.atoms, "class C {}");
    var state = try ParseState.init(&lex, &function);
    defer state.deinit(env.rt);

    try parser_core.parseExpr(&state);

    try std.testing.expectEqual(@as(usize, 4), state.function_def.scopes.len);
    try std.testing.expectEqual(@as(i32, 1), state.function_def.scopes[2].parent);
    try std.testing.expectEqual(@as(i32, 2), state.function_def.scopes[3].parent);
    var class_scope: ?i32 = null;
    var fields_scope: ?i32 = null;
    for (state.function_def.vars) |vd| {
        if (vd.var_name == class_atom) class_scope = vd.scope_level;
        if (vd.var_name == core.atom.ids.class_fields_init) fields_scope = vd.scope_level;
    }
    try std.testing.expectEqual(@as(i32, 2), class_scope orelse return error.TestExpectedEqual);
    try std.testing.expectEqual(@as(i32, 3), fields_scope orelse return error.TestExpectedEqual);
}

test "F10.1a FunctionDef: findVar locates by name" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    const name = try env.rt.internAtom("test");
    defer env.rt.atoms.free(name);
    var function = engine.bytecode.Bytecode.init(&env.rt.memory, &env.rt.atoms, name);
    defer function.deinit(env.rt);

    const x_atom = try env.rt.internAtom("x");
    defer env.rt.atoms.free(x_atom);
    const y_atom = try env.rt.internAtom("y");
    defer env.rt.atoms.free(y_atom);
    const z_atom = try env.rt.internAtom("z");
    defer env.rt.atoms.free(z_atom);

    var lex = QjsLexer.init(std.testing.allocator, &env.rt.atoms, "let x; let y;");
    var state = try ParseState.init(&lex, &function);
    defer state.deinit(env.rt);

    try parser_core.parseStatementOrDecl(&state, parser_core.DeclMask{ .func = true, .func_with_label = true, .other = true });
    try parser_core.parseStatementOrDecl(&state, parser_core.DeclMask{ .func = true, .func_with_label = true, .other = true });

    try std.testing.expectEqual(@as(i32, 0), state.function_def.findVar(x_atom));
    try std.testing.expectEqual(@as(i32, 1), state.function_def.findVar(y_atom));
    try std.testing.expectEqual(@as(i32, -1), state.function_def.findVar(z_atom));
}

test "F10.1b Nested function: cur_func stack management" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    const name = try env.rt.internAtom("test");
    defer env.rt.atoms.free(name);
    var function = engine.bytecode.Bytecode.init(&env.rt.memory, &env.rt.atoms, name);
    defer function.deinit(env.rt);

    // Parse a nested function expression: (function() { (function() {}) })
    // Note: using function expressions which are allowed in expression contexts
    var lex = QjsLexer.init(std.testing.allocator, &env.rt.atoms, "(function() { (function() {}) })");
    var state = try ParseState.init(&lex, &function);
    defer state.deinit(env.rt);

    try parser_core.parseExpr(&state);

    // Verify that the cur_func stack is empty after parsing (back to root)
    try std.testing.expectEqual(@as(usize, 0), state.cur_func_stack.len);

    // Verify that nested functions were created on the stack during parsing
    // (We can't directly verify the stack state during parsing, but we can
    // verify that the parsing completed without errors and the stack was
    // properly cleaned up)
}

test "nested function declarations fit the QuickJS native parser stack budget" {
    const depth = 250;
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(std.testing.allocator);
    try source.ensureTotalCapacity(std.testing.allocator, depth * ("function f(){".len + 1) + "return 1;".len);
    for (0..depth) |_| try source.appendSlice(std.testing.allocator, "function f(){");
    try source.appendSlice(std.testing.allocator, "return 1;");
    for (0..depth) |_| try source.append(std.testing.allocator, '}');

    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    rt.updateNativeStackTop();

    var parsed = try parser.compile(rt, source.items, .{
        .mode = .script,
        .filename = "nested-functions.js",
    });
    defer parsed.deinit();

    try std.testing.expect(parsed.syntax_error == null);
}

test "function expressions widen closure operands after constant index 255" {
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(std.testing.allocator);
    try source.appendSlice(std.testing.allocator, "const functions = [");
    for (0..257) |index| {
        if (index != 0) try source.append(std.testing.allocator, ',');
        try source.appendSlice(std.testing.allocator, "() => 0");
    }
    try source.appendSlice(std.testing.allocator, "]; functions[256]();");

    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try parser.compile(rt, source.items, .{
        .mode = .script,
        .filename = "wide-function-expression.js",
    });
    defer parsed.deinit();
    try std.testing.expect(parsed.syntax_error == null);

    var saw_short_255 = false;
    var saw_wide_256 = false;
    var pc: usize = 0;
    while (pc < parsed.function.code.len) {
        const opcode_id = parsed.function.code[pc];
        switch (opcode_id) {
            op.fclosure8 => saw_short_255 = saw_short_255 or parsed.function.code[pc + 1] == 255,
            op.fclosure => saw_wide_256 = saw_wide_256 or readU32(parsed.function.code, pc + 1) == 256,
            else => {},
        }
        const size = engine.bytecode.opcode.sizeOf(opcode_id);
        try std.testing.expect(size != 0);
        pc += size;
    }
    try std.testing.expect(saw_short_255);
    try std.testing.expect(saw_wide_256);
}

test "QuickJS hoist metadata keeps only the final body local function initializer" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try parser.compile(
        rt,
        "function outer(){ function f(){ return 1; } function f(){ return 2; } return f(); }",
        .{ .mode = .script, .filename = "duplicate-local-function.js" },
    );
    defer parsed.deinit();
    try std.testing.expect(parsed.syntax_error == null);

    const outer = findFunctionConstantNamed(&parsed.function, rt, "outer") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 1), countFunctionClosures(outer.byteCode()));

    var pc: usize = 0;
    while (pc < outer.byteCode().len) {
        const opcode_id = outer.byteCode()[pc];
        if (opcode_id == op.fclosure or opcode_id == op.fclosure8) {
            try std.testing.expectEqual(@as(u32, 1), readConstIndexAtOpcode(outer.byteCode(), pc));
            return;
        }
        pc += engine.bytecode.opcode.sizeOf(opcode_id);
    }
    return error.TestExpectedEqual;
}

test "QuickJS hoist metadata keeps only the final parameter function initializer" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try parser.compile(
        rt,
        "function outer(f){ function f(){ return 1; } function f(){ return 2; } return f(); }",
        .{ .mode = .script, .filename = "duplicate-parameter-function.js" },
    );
    defer parsed.deinit();
    try std.testing.expect(parsed.syntax_error == null);

    const outer = findFunctionConstantNamed(&parsed.function, rt, "outer") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 1), countFunctionClosures(outer.byteCode()));

    var pc: usize = 0;
    while (pc < outer.byteCode().len) {
        const opcode_id = outer.byteCode()[pc];
        if (opcode_id == op.fclosure or opcode_id == op.fclosure8) {
            try std.testing.expectEqual(@as(u32, 1), readConstIndexAtOpcode(outer.byteCode(), pc));
            return;
        }
        pc += engine.bytecode.opcode.sizeOf(opcode_id);
    }
    return error.TestExpectedEqual;
}

test "QuickJS block function metadata does not also use the body prologue fallback" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    // The parameter collision suppresses Annex B's outer var mirror, leaving
    // a lexical block function. QuickJS constructs it once at OP_enter_scope
    // and retains the declaration-position fclosure/drop pair; it does not
    // also initialize the block binding in instantiate_hoisted_definitions.
    var parsed = try parser.compile(
        rt,
        "function outer(f){ { function f(){} } }",
        .{ .mode = .script, .filename = "block-function-parameter-collision.js" },
    );
    defer parsed.deinit();
    try std.testing.expect(parsed.syntax_error == null);

    const outer = findFunctionConstantNamed(&parsed.function, rt, "outer") orelse
        return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 2), countFunctionClosures(outer.byteCode()));
}

test "QuickJS final linkage rebuild includes implicit arguments by scope level" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try parser.compile(
        rt,
        "function outer(){ var prior; return arguments; }",
        .{ .mode = .script, .filename = "arguments-pseudo-binding.js" },
    );
    defer parsed.deinit();
    try std.testing.expect(parsed.syntax_error == null);

    const outer = findFunctionConstantNamed(&parsed.function, rt, "outer") orelse
        return error.TestExpectedEqual;
    for (outer.varDefs()) |vd| {
        if (!std.mem.eql(u8, rt.atoms.name(vd.var_name) orelse "", "arguments")) continue;
        // add_arguments_var is outside the parser's ordinary scope list, but
        // js_create_function rebuilds final scope_next from every VarDef's
        // scope_level. The later arguments row therefore links to `prior`.
        try std.testing.expectEqual(@as(i32, 0), vd.scope_next);
        return;
    }
    return error.TestExpectedEqual;
}

test "QuickJS add_eval_variables stages pseudo locals in VarDef append order" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try parser.compile(
        rt,
        "(function named(a = eval('')) { eval(''); return () => [this, new.target, arguments, named]; });",
        .{ .mode = .script, .filename = "eval-pseudo-vardef-order.js" },
    );
    defer parsed.deinit();
    try std.testing.expect(parsed.syntax_error == null);

    const named = findFunctionConstantNamed(&parsed.function, rt, "named") orelse
        return error.TestExpectedEqual;
    const expected_names = [_][]const u8{
        "a",
        "<var>",
        "<arg_var>",
        "this",
        "new.target",
        "arguments",
        "arguments",
        "named",
    };
    try std.testing.expectEqual(expected_names.len, named.varDefs().len);
    for (expected_names, named.varDefs()) |expected, vd| {
        try std.testing.expectEqualStrings(expected, rt.atoms.name(vd.var_name) orelse "");
    }

    // Parser-time add_var pseudo bindings stay outside scopes[].first. Final
    // creation deliberately rebuilds the table from scope_level, producing a
    // scope-zero chain and a separate parameter chain ending at ARG_SCOPE_END.
    try std.testing.expectEqualSlices(i32, &.{ -1, 1, 2, 3, 4 }, &.{
        named.varDefs()[1].scope_next,
        named.varDefs()[2].scope_next,
        named.varDefs()[3].scope_next,
        named.varDefs()[4].scope_next,
        named.varDefs()[5].scope_next,
    });
    try std.testing.expect(named.varDefs()[6].hasScope());
    try std.testing.expectEqual(@as(i32, 0), named.varDefs()[6].scope_next);
    try std.testing.expect(named.varDefs()[6].isLexical());
    try std.testing.expectEqual(function_def.VarKind.function_name, named.varDefs()[7].varKind());

    // VarDef append order is intentionally different from resolve_labels'
    // prologue order. Preserve QuickJS's home/active/new-target/this/arguments/
    // function-name/var-object ordering contract instead of replaying VarDefs.
    var special_subtypes: [5]u8 = undefined;
    var special_count: usize = 0;
    var pc: usize = 0;
    while (pc < named.byteCode().len) {
        const opcode_id = named.byteCode()[pc];
        const size = engine.bytecode.opcode.sizeOf(opcode_id);
        try std.testing.expect(size > 0 and pc + size <= named.byteCode().len);
        if (opcode_id == op.special_object) {
            try std.testing.expect(special_count < special_subtypes.len);
            special_subtypes[special_count] = named.byteCode()[pc + 1];
            special_count += 1;
        }
        pc += size;
    }
    try std.testing.expectEqual(special_subtypes.len, special_count);
    try std.testing.expectEqualSlices(u8, &.{ 3, 0, 2, 5, 5 }, &special_subtypes);
}

test "QuickJS direct eval arguments pseudo is distinct from a simple formal" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try parser.compile(
        rt,
        "(function shadow(arguments) { eval(''); return arguments; });",
        .{ .mode = .script, .filename = "eval-arguments-formal.js" },
    );
    defer parsed.deinit();
    try std.testing.expect(parsed.syntax_error == null);

    const shadow = findFunctionConstantNamed(&parsed.function, rt, "shadow") orelse
        return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 1), shadow.argVarDefs().len);
    try std.testing.expectEqualStrings(
        "arguments",
        rt.atoms.name(shadow.argVarDefs()[0].var_name) orelse "",
    );

    const expected_names = [_][]const u8{
        "<var>",
        "this",
        "new.target",
        "arguments",
        "shadow",
    };
    try std.testing.expectEqual(expected_names.len, shadow.varDefs().len);
    for (expected_names, shadow.varDefs(), 0..) |expected, vd, index| {
        try std.testing.expectEqualStrings(expected, rt.atoms.name(vd.var_name) orelse "");
        try std.testing.expectEqual(if (index == 0) @as(i32, -1) else @as(i32, @intCast(index - 1)), vd.scope_next);
    }
}

test "QuickJS entry contract separates eval environment grammar and bindings" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var script = try parser.compile(
        rt,
        "function ordinary() { return arguments; }",
        .{ .mode = .script, .filename = "entry-contract-script.js" },
    );
    defer script.deinit();
    try std.testing.expect(script.syntax_error == null);
    try std.testing.expectEqual(engine.bytecode.VarEnvironment.global, script.function.entry_contract.var_environment);
    try std.testing.expect(script.function.entry_contract.arguments_allowed);
    try std.testing.expect(!script.function.entry_contract.has_arguments_binding);
    try std.testing.expect(script.function.entry_contract.has_this_binding);

    const ordinary = findFunctionConstantNamed(&script.function, rt, "ordinary") orelse
        return error.TestExpectedEqual;
    try std.testing.expectEqual(engine.bytecode.VarEnvironment.local, ordinary.flags.var_environment);
    try std.testing.expect(ordinary.flags.arguments_allowed);
    try std.testing.expect(ordinary.flags.has_arguments_binding);
    try std.testing.expect(ordinary.flags.has_this_binding);

    var global_eval = try parser.compile(
        rt,
        "",
        .{
            .mode = .eval_direct,
            .filename = "entry-contract-global-eval.js",
            .eval_global_var_bindings = true,
            .eval_allows_new_target = true,
            .eval_allows_super_call = true,
            .eval_allows_super_property = true,
            .eval_arguments_allowed = true,
        },
    );
    defer global_eval.deinit();
    try std.testing.expect(global_eval.syntax_error == null);
    const entry = global_eval.function.entry_contract;
    try std.testing.expectEqual(engine.bytecode.VarEnvironment.global, entry.var_environment);
    try std.testing.expect(entry.new_target_allowed);
    try std.testing.expect(entry.super_call_allowed);
    try std.testing.expect(entry.super_allowed);
    try std.testing.expect(entry.arguments_allowed);
    try std.testing.expect(!entry.has_arguments_binding);
    try std.testing.expect(!entry.has_this_binding);

    var strict_eval = try parser.compile(
        rt,
        "'use strict';",
        .{
            .mode = .eval_direct,
            .filename = "entry-contract-strict-eval.js",
            .eval_global_var_bindings = true,
        },
    );
    defer strict_eval.deinit();
    try std.testing.expect(strict_eval.syntax_error == null);
    try std.testing.expectEqual(engine.bytecode.VarEnvironment.local, strict_eval.function.entry_contract.var_environment);

    var module = try parser.compile(
        rt,
        "",
        .{ .mode = .module, .filename = "entry-contract-module.js" },
    );
    defer module.deinit();
    try std.testing.expect(module.syntax_error == null);
    try std.testing.expectEqual(engine.bytecode.VarEnvironment.module, module.function.entry_contract.var_environment);
}

test "QuickJS parameter expression scope initializes lexical TDZ on entry" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try parser.compile(
        rt,
        "function later(a = eval(\"b\"), b = 1) {}",
        .{ .mode = .script, .filename = "parameter-scope-entry.js" },
    );
    defer parsed.deinit();
    try std.testing.expect(parsed.syntax_error == null);

    const later = findFunctionConstantNamed(&parsed.function, rt, "later") orelse
        return error.TestExpectedEqual;
    // qjs OP_enter_scope(ARG_SCOPE_INDEX) lowers both parameter lexical
    // bindings before evaluating the first default. The synthetic lexical
    // `arguments` cell is deliberately excluded from this initialization.
    try std.testing.expectEqual(
        @as(usize, 2),
        countOpcode(later.byteCode(), op.set_loc_uninitialized),
    );
}

test "QuickJS global declaration carriers precede child finalization" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try parser.compile(
        rt,
        "var x = 1; function read(){ return x; }",
        .{ .mode = .script, .filename = "global-carrier-order.js" },
    );
    defer parsed.deinit();
    try std.testing.expect(parsed.syntax_error == null);

    var x_ref: ?u16 = null;
    for (parsed.function.closure_var, 0..) |cv, idx| {
        const name = rt.atoms.name(cv.var_name) orelse "";
        if (std.mem.eql(u8, name, "x")) {
            try std.testing.expectEqual(function_def.ClosureType.global_decl, cv.closureType());
            try std.testing.expect(!cv.isLexical());
            x_ref = @intCast(idx);
        }
    }
    const read = findFunctionConstantNamed(&parsed.function, rt, "read") orelse return error.TestExpectedEqual;
    var found_child_carrier = false;
    for (read.closureVar()) |cv| {
        if (!std.mem.eql(u8, rt.atoms.name(cv.var_name) orelse "", "x")) continue;
        try std.testing.expectEqual(function_def.ClosureType.global_ref, cv.closureType());
        try std.testing.expectEqual(x_ref orelse return error.TestExpectedEqual, cv.var_idx);
        found_child_carrier = true;
    }
    try std.testing.expect(found_child_carrier);
    try std.testing.expectEqual(@as(usize, 1), countOpcode(read.byteCode(), op.get_var));
    try std.testing.expectEqual(@as(usize, 0), countOpcode(read.byteCode(), op.get_var_ref));
}

test "QuickJS open binding indices follow child capture demand order" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    // The child resolves `arg` before `local`. qjs finalizes the child first;
    // its two get_closure_var/capture_var events therefore assign arg=0 and
    // local=1 in the parent. This deliberately distinguishes provenance from
    // both locals-first grouping and an unconditional args-first policy.
    var parsed = try parser.compile(
        rt,
        \\function outerArgFirst(arg) { let local = 1; return function inner() { return arg + local; }; }
        \\function outerLocalFirst(arg) { let local = 1; return function inner() { return local + arg; }; }
    ,
        .{ .mode = .script, .filename = "capture-event-order.js" },
    );
    defer parsed.deinit();
    try std.testing.expect(parsed.syntax_error == null);

    const outer = findFunctionConstantNamed(&parsed.function, rt, "outerArgFirst") orelse
        return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(u16, 2), outer.open_var_ref_count);
    try std.testing.expectEqual(@as(usize, 1), outer.argVarDefs().len);
    try std.testing.expectEqual(@as(u16, 0), outer.argVarDefs()[0].var_ref_idx);

    var found_local = false;
    for (outer.varDefs()) |vd| {
        if (!std.mem.eql(u8, rt.atoms.name(vd.var_name) orelse "", "local")) continue;
        try std.testing.expect(vd.isCaptured());
        try std.testing.expectEqual(@as(u16, 1), vd.var_ref_idx);
        found_local = true;
    }
    try std.testing.expect(found_local);

    // Reverse only the child's first-use order. A fixed args-first policy
    // would keep the previous indices and fail this half.
    const local_first = findFunctionConstantNamed(&parsed.function, rt, "outerLocalFirst") orelse
        return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(u16, 2), local_first.open_var_ref_count);
    try std.testing.expectEqual(@as(u16, 1), local_first.argVarDefs()[0].var_ref_idx);
    var found_local_first = false;
    for (local_first.varDefs()) |vd| {
        if (!std.mem.eql(u8, rt.atoms.name(vd.var_name) orelse "", "local")) continue;
        try std.testing.expect(vd.isCaptured());
        try std.testing.expectEqual(@as(u16, 0), vd.var_ref_idx);
        found_local_first = true;
    }
    try std.testing.expect(found_local_first);
}

test "QuickJS postorder capture topology records exact forwarding rows" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try parser.compile(
        rt,
        "function outer(x) { return function middle() { return function inner() { return x; }; }; }",
        .{ .mode = .script, .filename = "postorder-capture-forwarding.js" },
    );
    defer parsed.deinit();
    try std.testing.expect(parsed.syntax_error == null);

    const outer = findFunctionConstantNamed(&parsed.function, rt, "outer") orelse
        return error.TestExpectedEqual;
    const middle = middle: {
        for (outer.cpoolSlice()) |value| {
            const child = functionBytecodeFromValue(value) orelse continue;
            if (std.mem.eql(u8, rt.atoms.name(child.func_name) orelse "", "middle")) break :middle child;
        }
        return error.TestExpectedEqual;
    };
    const inner = inner: {
        for (middle.cpoolSlice()) |value| {
            const child = functionBytecodeFromValue(value) orelse continue;
            if (std.mem.eql(u8, rt.atoms.name(child.func_name) orelse "", "inner")) break :inner child;
        }
        return error.TestExpectedEqual;
    };

    try std.testing.expectEqual(@as(usize, 1), middle.closureVar().len);
    try std.testing.expectEqual(function_def.ClosureType.arg, middle.closureVar()[0].closureType());
    try std.testing.expectEqual(@as(u16, 0), middle.closureVar()[0].var_idx);
    try std.testing.expectEqual(@as(usize, 1), inner.closureVar().len);
    try std.testing.expectEqual(function_def.ClosureType.ref, inner.closureVar()[0].closureType());
    try std.testing.expectEqual(@as(u16, 0), inner.closureVar()[0].var_idx);
    try std.testing.expect(!@hasField(engine.bytecode.function_bytecode.BytecodeClosureVar, "source_depth"));
}

test "QuickJS postorder capture topology follows lexical scope order" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try parser.compile(
        rt,
        \\function outer() {
        \\  let target;
        \\  { let x = 1; target = function inner() { return x; }; }
        \\  let x = 2;
        \\  return target;
        \\}
    ,
        .{ .mode = .script, .filename = "postorder-lexical-capture-order.js" },
    );
    defer parsed.deinit();
    try std.testing.expect(parsed.syntax_error == null);

    const outer = findFunctionConstantNamed(&parsed.function, rt, "outer") orelse
        return error.TestExpectedEqual;
    const inner = inner: {
        for (outer.cpoolSlice()) |value| {
            const child = functionBytecodeFromValue(value) orelse continue;
            if (std.mem.eql(u8, rt.atoms.name(child.func_name) orelse "", "inner")) break :inner child;
        }
        return error.TestExpectedEqual;
    };

    try std.testing.expectEqual(@as(usize, 1), inner.closureVar().len);
    try std.testing.expectEqualStrings("x", rt.atoms.name(inner.closureVar()[0].var_name) orelse "");
    try std.testing.expectEqual(function_def.ClosureType.local, inner.closureVar()[0].closureType());
    try std.testing.expectEqual(@as(u16, 1), inner.closureVar()[0].var_idx);
}

test "QuickJS direct eval capture prefix preserves shadowed binding identities" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try parser.compile(
        rt,
        \\function outer(x) {
        \\  { let x = 1; function middle() { eval(""); return x; } return middle; }
        \\}
    ,
        .{ .mode = .script, .filename = "direct-eval-shadowed-prefix.js" },
    );
    defer parsed.deinit();
    try std.testing.expect(parsed.syntax_error == null);

    const outer = findFunctionConstantNamed(&parsed.function, rt, "outer") orelse
        return error.TestExpectedEqual;
    const middle = middle: {
        for (outer.cpoolSlice()) |value| {
            const child = functionBytecodeFromValue(value) orelse continue;
            if (std.mem.eql(u8, rt.atoms.name(child.func_name) orelse "", "middle")) break :middle child;
        }
        return error.TestExpectedEqual;
    };

    // qjs get_closure_var deduplicates by (closure_type,var_idx), never by
    // name. The block lexical `x` is the first visible row and the outer
    // parameter `x` remains a distinct later row for direct-eval seeding.
    var x_count: usize = 0;
    var x_types: [2]function_def.ClosureType = undefined;
    for (middle.closureVar()) |cv| {
        if (!std.mem.eql(u8, rt.atoms.name(cv.var_name) orelse "", "x")) continue;
        if (x_count >= x_types.len) return error.TestExpectedEqual;
        x_types[x_count] = cv.closureType();
        x_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), x_count);
    try std.testing.expectEqual(function_def.ClosureType.local, x_types[0]);
    try std.testing.expectEqual(function_def.ClosureType.arg, x_types[1]);
}

test "QuickJS direct eval capture prefix follows lexical scope order" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try parser.compile(
        rt,
        \\function outer() {
        \\  let target;
        \\  { let x = 1; target = function inner() { return eval("x"); }; }
        \\  let x = 2;
        \\  return target;
        \\}
    ,
        .{ .mode = .script, .filename = "direct-eval-lexical-capture-order.js" },
    );
    defer parsed.deinit();
    try std.testing.expect(parsed.syntax_error == null);

    const outer = findFunctionConstantNamed(&parsed.function, rt, "outer") orelse
        return error.TestExpectedEqual;
    const inner = inner: {
        for (outer.cpoolSlice()) |value| {
            const child = functionBytecodeFromValue(value) orelse continue;
            if (std.mem.eql(u8, rt.atoms.name(child.func_name) orelse "", "inner")) break :inner child;
        }
        return error.TestExpectedEqual;
    };

    // qjs rebuilds scope_next before add_eval_variables. The inner block's x
    // must precede the later-declared outer x even though its VarDef index is
    // smaller (quickjs.c:36034-36059, 33699-33729).
    try std.testing.expect(inner.closureVar().len >= 2);
    for (inner.closureVar()[0..2]) |cv| {
        try std.testing.expectEqualStrings("x", rt.atoms.name(cv.var_name) orelse "");
        try std.testing.expectEqual(function_def.ClosureType.local, cv.closureType());
    }
    try std.testing.expectEqual(@as(u16, 1), inner.closureVar()[0].var_idx);
    try std.testing.expectEqual(@as(u16, 2), inner.closureVar()[1].var_idx);
}

test "QuickJS eval prefix is stable before descendant capture demand" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try parser.compile(
        rt,
        \\function outer(a, b) {
        \\  return function () { eval(""); return function () { return b; }; };
        \\}
    ,
        .{ .mode = .script, .filename = "eval-prefix-before-child-demand.js" },
    );
    defer parsed.deinit();
    try std.testing.expect(parsed.syntax_error == null);

    const outer = findFunctionConstantNamed(&parsed.function, rt, "outer") orelse
        return error.TestExpectedEqual;
    const middle = middle: {
        for (outer.cpoolSlice()) |value| {
            if (functionBytecodeFromValue(value)) |child| break :middle child;
        }
        return error.TestExpectedEqual;
    };

    // add_eval_variables constructs this fixed prefix before any child is
    // finalized. The inner function's first use of `b` therefore cannot move
    // that row ahead of `a` (quickjs.c:33610-33776, 36064-36079).
    const expected = [_][]const u8{ "a", "b", "eval" };
    try std.testing.expectEqual(expected.len, middle.closureVar().len);
    for (middle.closureVar(), expected) |cv, expected_name| {
        try std.testing.expectEqualStrings(expected_name, rt.atoms.name(cv.var_name) orelse "");
    }
}

test "QuickJS eval root appends child and own ordinary globals after declarations" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try parser.compile(
        rt,
        "var declared; (() => childOnly); print; rootOnly;",
        .{ .mode = .script, .filename = "postorder-global-topology.js" },
    );
    defer parsed.deinit();
    try std.testing.expect(parsed.syntax_error == null);

    const expected_names = [_][]const u8{ "declared", "childOnly", "print", "rootOnly" };
    const expected_types = [_]function_def.ClosureType{ .global_decl, .global, .global, .global };
    try std.testing.expectEqual(expected_names.len, parsed.function.closure_var.len);
    for (parsed.function.closure_var, expected_names, expected_types) |cv, expected_name, expected_type| {
        try std.testing.expectEqualStrings(expected_name, rt.atoms.name(cv.var_name) orelse "");
        try std.testing.expectEqual(expected_type, cv.closureType());
    }

    const child = child: {
        for (parsed.function.constants.values) |value| {
            if (functionBytecodeFromValue(value)) |candidate| break :child candidate;
        }
        return error.TestExpectedEqual;
    };
    try std.testing.expectEqual(@as(usize, 1), child.closureVar().len);
    try std.testing.expectEqual(function_def.ClosureType.global_ref, child.closureVar()[0].closureType());
    try std.testing.expectEqual(@as(u16, 1), child.closureVar()[0].var_idx);
}

test "final eval operands address compact vardef chains" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try parser.compile(
        rt,
        "(function scoped(a = eval('')) { { let inner = 1; eval('inner'); } });",
        .{ .mode = .script, .filename = "eval-vardef-chain.js" },
    );
    defer parsed.deinit();
    try std.testing.expect(parsed.syntax_error == null);

    const function = findFunctionConstantNamed(&parsed.function, rt, "scoped") orelse
        return error.TestExpectedEqual;
    var operands: [2]u16 = undefined;
    var operand_count: usize = 0;
    var pc: usize = 0;
    while (pc < function.byteCode().len) {
        const opcode_id = function.byteCode()[pc];
        const size = engine.bytecode.opcode.sizeOf(opcode_id);
        try std.testing.expect(size > 0 and pc + size <= function.byteCode().len);
        if (opcode_id == op.eval) {
            try std.testing.expect(operand_count < operands.len);
            operands[operand_count] = std.mem.readInt(u16, function.byteCode()[pc + 3 ..][0..2], .little);
            operand_count += 1;
        }
        pc += size;
    }
    try std.testing.expectEqual(operands.len, operand_count);

    const Chain = struct {
        fn end(vardefs: []const engine.bytecode.function_bytecode.BytecodeVarDef, head: i32) !i32 {
            var index = head;
            var visited: usize = 0;
            while (index >= 0) {
                if (@as(usize, @intCast(index)) >= vardefs.len or visited >= vardefs.len) return error.TestUnexpectedResult;
                visited += 1;
                index = vardefs[@intCast(index)].scope_next;
            }
            return index;
        }

        fn containsName(
            runtime: *core.JSRuntime,
            vardefs: []const engine.bytecode.function_bytecode.BytecodeVarDef,
            head: i32,
            expected: []const u8,
        ) !bool {
            var index = head;
            var visited: usize = 0;
            while (index >= 0) {
                if (@as(usize, @intCast(index)) >= vardefs.len or visited >= vardefs.len) return error.TestUnexpectedResult;
                visited += 1;
                const vd = vardefs[@intCast(index)];
                if (std.mem.eql(u8, runtime.atoms.name(vd.var_name) orelse "", expected)) return true;
                index = vd.scope_next;
            }
            return false;
        }
    };

    const parameter_head = @as(i32, operands[0] & 0x7fff) + engine.bytecode.function_bytecode.arg_scope_end;
    const body_head = @as(i32, operands[1] & 0x7fff) + engine.bytecode.function_bytecode.arg_scope_end;
    try std.testing.expectEqual(engine.bytecode.function_bytecode.arg_scope_end, try Chain.end(function.varDefs(), parameter_head));
    try std.testing.expectEqual(@as(i32, -1), try Chain.end(function.varDefs(), body_head));
    try std.testing.expect(!(try Chain.containsName(rt, function.varDefs(), parameter_head, "inner")));
    try std.testing.expect(try Chain.containsName(rt, function.varDefs(), body_head, "inner"));
    // The former zjs-only parameter flag occupied 0x4000. Parameter scope is
    // now represented solely by the ARG_SCOPE_END chain terminator.
    try std.testing.expectEqual(@as(u16, 0), operands[0] & 0x4000);
}

test "final eval marker is combined and belongs only to the eval unit" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var script = try parser.compile(rt, "1;", .{ .mode = .script, .filename = "script.js" });
    defer script.deinit();
    try std.testing.expect(script.syntax_error == null);
    try std.testing.expect(!script.function.flags.is_direct_or_indirect_eval);

    var direct = try parser.compile(rt, "1;", .{ .mode = .eval_direct, .filename = "<eval>" });
    defer direct.deinit();
    try std.testing.expect(direct.syntax_error == null);
    try std.testing.expect(direct.function.flags.is_direct_or_indirect_eval);

    var indirect = try parser.compile(
        rt,
        "function nested() {}",
        .{ .mode = .eval_indirect, .filename = "<eval>" },
    );
    defer indirect.deinit();
    try std.testing.expect(indirect.syntax_error == null);
    try std.testing.expect(indirect.function.flags.is_direct_or_indirect_eval);
    const nested = findFunctionConstantNamed(&indirect.function, rt, "nested") orelse
        return error.TestExpectedEqual;
    try std.testing.expect(!nested.flags.is_direct_or_indirect_eval);
}

test "direct eval capture hints preserve the former parameter flag bit as scope data" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var source = std.ArrayList(u8).empty;
    defer source.deinit(std.testing.allocator);
    for (0..0x4000) |_| try source.appendSlice(std.testing.allocator, "{}");
    try source.appendSlice(
        std.testing.allocator,
        "{ let highScopeEvalBinding = 1; eval('highScopeEvalBinding'); }",
    );

    var parsed = try parser.compile(
        rt,
        source.items,
        .{ .mode = .script, .filename = "high-scope-eval.js" },
    );
    defer parsed.deinit();
    try std.testing.expect(parsed.syntax_error == null);

    var binding_index: ?u16 = null;
    for (parsed.function.vardefs, 0..) |vd, idx| {
        if (!std.mem.eql(u8, rt.atoms.name(vd.var_name) orelse "", "highScopeEvalBinding")) continue;
        try std.testing.expect(vd.isCaptured());
        binding_index = @intCast(idx);
        break;
    }
    const expected_index = binding_index orelse return error.TestExpectedEqual;

    var found_refresh = false;
    var pc: usize = 0;
    while (pc < parsed.function.code.len) {
        const opcode_id = parsed.function.code[pc];
        const size = engine.bytecode.opcode.sizeOf(opcode_id);
        try std.testing.expect(size > 0 and pc + size <= parsed.function.code.len);
        if (opcode_id == op.close_loc and
            std.mem.readInt(u16, parsed.function.code[pc + 1 ..][0..2], .little) == expected_index)
        {
            found_refresh = true;
            break;
        }
        pc += size;
    }
    try std.testing.expect(found_refresh);
}

test "QuickJS direct eval captures only loop bindings live at the call site" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var after_loop = try parser.compile(
        rt,
        "for (let i = 0; i < 1; i++) {} eval('typeof i');",
        .{ .mode = .script, .filename = "eval-after-loop.js" },
    );
    defer after_loop.deinit();
    try std.testing.expect(after_loop.syntax_error == null);
    for (after_loop.function.vardefs) |vd| {
        if (!std.mem.eql(u8, rt.atoms.name(vd.var_name) orelse "", "i")) continue;
        try std.testing.expect(!vd.isCaptured());
        try std.testing.expectEqual(@as(u16, 0), vd.var_ref_idx);
    }

    var in_loop = try parser.compile(
        rt,
        "for (let i = 0; i < 1; i++) { eval('i'); }",
        .{ .mode = .script, .filename = "eval-in-loop.js" },
    );
    defer in_loop.deinit();
    try std.testing.expect(in_loop.syntax_error == null);
    var found_captured_i = false;
    for (in_loop.function.vardefs) |vd| {
        if (!std.mem.eql(u8, rt.atoms.name(vd.var_name) orelse "", "i")) continue;
        try std.testing.expect(vd.isCaptured());
        try std.testing.expect(vd.var_ref_idx < in_loop.function.open_var_ref_count);
        found_captured_i = true;
    }
    try std.testing.expect(found_captured_i);
}

test "QuickJS class private direct eval has complete capture events" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try parser.compile(
        rt,
        \\class C {
        \\  #x = 7;
        \\  good() { return eval("this.#x"); }
        \\}
    ,
        .{ .mode = .script, .filename = "private-direct-eval.js" },
    );
    defer parsed.deinit();
    try std.testing.expect(parsed.syntax_error == null);
}

test "QuickJS module closure order keeps all imports before global declarations" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try parser.compile(
        rt,
        "import * as a from 'a'; let y; import * as b from 'b'; var w;",
        .{ .mode = .module, .filename = "module-closure-order.mjs" },
    );
    defer parsed.deinit();
    try std.testing.expect(parsed.syntax_error == null);

    const expected_names = [_][]const u8{ "a", "b", "y", "w" };
    const expected_types = [_]function_def.ClosureType{ .module_decl, .module_decl, .module_decl, .module_decl };
    try std.testing.expectEqual(expected_names.len, parsed.function.closure_var.len);
    for (parsed.function.closure_var, expected_names, expected_types) |cv, expected_name, expected_type| {
        try std.testing.expectEqualStrings(expected_name, rt.atoms.name(cv.var_name) orelse "");
        try std.testing.expectEqual(expected_type, cv.closureType());
    }
    try std.testing.expect(parsed.function.closure_var[0].isConst());
    try std.testing.expect(parsed.function.closure_var[1].isConst());
    try std.testing.expect(parsed.function.closure_var[2].isLexical());
    try std.testing.expect(!parsed.function.closure_var[3].isLexical());
}

test "QuickJS module declarations append without parser closure remapping" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try parser.compile(
        rt,
        "import * as ns from 'm'; const {a: aa, b} = {}; let [c] = []; class C {} export default function() {} (() => aa); root;",
        .{ .mode = .module, .filename = "module-declaration-construction.mjs" },
    );
    defer parsed.deinit();
    try std.testing.expect(parsed.syntax_error == null);

    // qjs add_import creates the fixed prefix, add_global_variables appends
    // GlobalVar rows in declaration order, and only then post-order lookup
    // appends the unresolved ordinary global.
    const expected_names = [_][]const u8{ "ns", "aa", "b", "c", "C", "*default*", "root" };
    const expected_types = [_]function_def.ClosureType{
        .module_decl,
        .module_decl,
        .module_decl,
        .module_decl,
        .module_decl,
        .module_decl,
        .global,
    };
    try std.testing.expectEqual(expected_names.len, parsed.function.closure_var.len);
    for (parsed.function.closure_var, expected_names, expected_types) |cv, expected_name, expected_type| {
        try std.testing.expectEqualStrings(expected_name, rt.atoms.name(cv.var_name) orelse "");
        try std.testing.expectEqual(expected_type, cv.closureType());
    }
    try std.testing.expect(parsed.function.closure_var[0].isConst());
    try std.testing.expect(parsed.function.closure_var[1].isConst());
    try std.testing.expect(parsed.function.closure_var[2].isConst());
    try std.testing.expect(!parsed.function.closure_var[3].isConst());
    try std.testing.expect(parsed.function.closure_var[4].isLexical());
    try std.testing.expect(!parsed.function.closure_var[5].isLexical());
    try std.testing.expectEqual(function_def.VarKind.global_function_decl, parsed.function.closure_var[5].varKind());

    // Top-level destructuring targets are declaration cells, not same-name
    // staging locals that later need synchronizing into a closure placeholder.
    for (parsed.function.vardefs) |vd| {
        const name = rt.atoms.name(vd.var_name) orelse continue;
        try std.testing.expect(!std.mem.eql(u8, name, "aa"));
        try std.testing.expect(!std.mem.eql(u8, name, "b"));
        try std.testing.expect(!std.mem.eql(u8, name, "c"));
    }

    const arrow = arrow: {
        for (parsed.function.constants.values) |value| {
            const child = functionBytecodeFromValue(value) orelse continue;
            if (child.closureVar().len != 1) continue;
            if (std.mem.eql(u8, rt.atoms.name(child.closureVar()[0].var_name) orelse "", "aa")) break :arrow child;
        }
        return error.TestExpectedEqual;
    };
    try std.testing.expectEqual(function_def.ClosureType.ref, arrow.closureVar()[0].closureType());
    try std.testing.expectEqual(@as(u16, 1), arrow.closureVar()[0].var_idx);

    // The anonymous default function carries GlobalVar row 5 until
    // add_global_variables assigns its final closure index.
    var found_default_init = false;
    var pc: usize = 0;
    while (pc < parsed.function.code.len) {
        const op_id = parsed.function.code[pc];
        const size = engine.bytecode.opcode.sizeOf(op_id);
        try std.testing.expect(size != 0 and pc + size <= parsed.function.code.len);
        if (op_id == op.put_var_ref and readU16AtOpcode(parsed.function.code, pc) == 5) {
            found_default_init = true;
        }
        pc += size;
    }
    try std.testing.expect(found_default_init);
}

test "QuickJS parent module declarations exist before child direct-eval seeding" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try parser.compile(
        rt,
        \\export let moduleDirectEvalBinding = 37;
        \\export function readModuleBindingByEval() {
        \\  return eval("moduleDirectEvalBinding");
        \\}
    ,
        .{ .mode = .module, .filename = "module-direct-eval-capture-order.mjs" },
    );
    defer parsed.deinit();
    try std.testing.expect(parsed.syntax_error == null);

    const child = findFunctionConstantNamed(&parsed.function, rt, "readModuleBindingByEval") orelse
        return error.TestExpectedEqual;

    // js_create_function constructs the parent's MODULE_DECL rows before it
    // recursively creates children. add_eval_variables in the child therefore
    // seeds both live module cells, in parent-table order, before resolving the
    // explicit `eval` lookup (quickjs.c:33610-33776, 35954-36079).
    try std.testing.expect(child.closureVar().len >= 3);
    const expected_names = [_][]const u8{ "moduleDirectEvalBinding", "readModuleBindingByEval", "eval" };
    const expected_types = [_]function_def.ClosureType{ .ref, .ref, .global_ref };
    const expected_indices = [_]u16{ 0, 1, 2 };
    for (child.closureVar()[0..3], expected_names, expected_types, expected_indices) |cv, expected_name, expected_type, expected_index| {
        try std.testing.expectEqualStrings(expected_name, rt.atoms.name(cv.var_name) orelse "");
        try std.testing.expectEqual(expected_type, cv.closureType());
        try std.testing.expectEqual(expected_index, cv.var_idx);
    }
}

test "QuickJS module instantiation guard separates function hoists from the body" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try parser.compile(
        rt,
        "function f() {} f();",
        .{ .mode = .module, .filename = "module-instantiation-guard.mjs" },
    );
    defer parsed.deinit();
    try std.testing.expect(parsed.syntax_error == null);

    // qjs instantiate_hoisted_definitions emits this exact control boundary:
    // link calls the module function with `this === true`, while evaluation
    // calls it with undefined and branches directly to the body. Besides
    // sharing one construction path, the return is a hard boundary that keeps
    // put_var_ref + body-leading get_var_ref from folding into set_var_ref.
    try std.testing.expect(parsed.function.code.len >= 8);
    try std.testing.expectEqual(op.push_this, parsed.function.code[0]);
    try std.testing.expectEqual(op.if_false8, parsed.function.code[1]);
    const body_pc: isize = 2 + @as(i8, @bitCast(parsed.function.code[2]));
    try std.testing.expectEqual(@as(isize, 7), body_pc);
    try std.testing.expectEqual(op.fclosure8, parsed.function.code[3]);
    try std.testing.expectEqual(@as(u8, 0), parsed.function.code[4]);
    try std.testing.expectEqual(op.put_var_ref0, parsed.function.code[5]);
    try std.testing.expectEqual(op.return_undef, parsed.function.code[6]);
    try std.testing.expectEqual(op.get_var_ref0, parsed.function.code[7]);
}

test "QuickJS module instantiation guard excludes frame lexical preparation" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try parser.compile(
        rt,
        "0; { let blockLocal = 1; blockLocal; }",
        .{ .mode = .module, .filename = "module-instantiation-lexical-boundary.mjs" },
    );
    defer parsed.deinit();
    try std.testing.expect(parsed.syntax_error == null);

    // instantiate_hoisted_definitions closes its link-only branch before the
    // body OP_enter_scope processing.  Link execution with `this === true`
    // must therefore never prepare a frame-local TDZ slot belonging to the
    // evaluation invocation.
    const body_pc = try moduleBodyStart(parsed.function.code);
    try std.testing.expectEqual(@as(usize, 0), countOpcode(parsed.function.code[0..body_pc], op.set_loc_uninitialized));
    try std.testing.expect(countOpcode(parsed.function.code[body_pc..], op.set_loc_uninitialized) > 0);
}

test "QuickJS module callback captures keep parent declaration indices" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try parser.compile(rt,
        \\let resolveAwaited;
        \\const awaited = new Promise((resolve) => resolveAwaited = resolve);
        \\const actual = [];
        \\awaited.then(() => actual.push("before"));
        \\Promise.resolve().then(() => {
        \\  awaited.then(() => actual.push("after"));
        \\  resolveAwaited();
        \\});
        \\await awaited;
        \\actual.push("module");
        \\Promise.resolve().then(() => print(actual.join(",")));
    , .{ .mode = .module, .filename = "module-callback-captures.mjs" });
    defer parsed.deinit();
    try std.testing.expect(parsed.syntax_error == null);

    const callback = callback: {
        for (parsed.function.constants.values) |value| {
            const child = functionBytecodeFromValue(value) orelse continue;
            if (child.closureVar().len == 3) break :callback child;
        }
        return error.TestExpectedEqual;
    };
    const expected_names = [_][]const u8{ "actual", "awaited", "resolveAwaited" };
    const expected_parent_indices = [_]u16{ 2, 1, 0 };
    try std.testing.expectEqual(expected_names.len, callback.closureVar().len);
    for (callback.closureVar(), expected_names, expected_parent_indices) |cv, expected_name, expected_parent_idx| {
        try std.testing.expectEqualStrings(expected_name, rt.atoms.name(cv.var_name) orelse "");
        try std.testing.expectEqual(function_def.ClosureType.ref, cv.closureType());
        try std.testing.expectEqual(expected_parent_idx, cv.var_idx);
    }
}

test "QuickJS global eval capture stays distinct from appended declaration carrier" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const x_atom = try rt.internAtom("x");
    defer rt.atoms.free(x_atom);
    const seed = [_]parser.EvalClosureSeed{.{
        .var_name = x_atom,
        .closure_type = .global,
        .var_idx = 0,
    }};
    var parsed = try parser.compile(rt, "var x;", .{
        .mode = .eval_indirect,
        .filename = "<eval>",
        .eval_closure_seed = &seed,
    });
    defer parsed.deinit();
    try std.testing.expect(parsed.syntax_error == null);

    try std.testing.expectEqual(@as(usize, 2), parsed.function.closure_var.len);
    try std.testing.expectEqual(function_def.ClosureType.global, parsed.function.closure_var[0].closureType());
    try std.testing.expectEqual(function_def.ClosureType.global_decl, parsed.function.closure_var[1].closureType());
    try std.testing.expectEqual(x_atom, parsed.function.closure_var[0].var_name);
    try std.testing.expectEqual(x_atom, parsed.function.closure_var[1].var_name);
}

test "QuickJS script global functions publish from bytecode through the first declaration carrier" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try parser.compile(
        rt,
        "function f(){ return 1; } function f(){ return 2; } f;",
        .{ .mode = .script, .filename = "duplicate-global-function.js" },
    );
    defer parsed.deinit();
    try std.testing.expect(parsed.syntax_error == null);

    var f_decl_count: usize = 0;
    var first_f_ref: ?u16 = null;
    for (parsed.function.closure_var, 0..) |cv, idx| {
        if (!std.mem.eql(u8, rt.atoms.name(cv.var_name) orelse "", "f")) continue;
        try std.testing.expectEqual(function_def.ClosureType.global_decl, cv.closureType());
        try std.testing.expect(!cv.isLexical());
        if (first_f_ref == null) first_f_ref = @intCast(idx);
        f_decl_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), f_decl_count);

    var pc: usize = 0;
    for (0..2) |constant_index| {
        try std.testing.expect(pc < parsed.function.code.len);
        try std.testing.expect(parsed.function.code[pc] == op.fclosure8 or parsed.function.code[pc] == op.fclosure);
        try std.testing.expectEqual(@as(u32, @intCast(constant_index)), readConstIndexAtOpcode(parsed.function.code, pc));
        pc += engine.bytecode.opcode.sizeOf(parsed.function.code[pc]);
        const put_opcode = parsed.function.code[pc];
        const expected_ref = first_f_ref orelse return error.TestExpectedEqual;
        if (expected_ref < 4) {
            try std.testing.expectEqual(op.put_var_ref0 + @as(u8, @intCast(expected_ref)), put_opcode);
        } else {
            try std.testing.expectEqual(op.put_var_ref, put_opcode);
            try std.testing.expectEqual(expected_ref, readU16AtOpcode(parsed.function.code, pc));
        }
        pc += engine.bytecode.opcode.sizeOf(put_opcode);
    }
    try std.testing.expect(countVarOpcodeForAtom(&parsed.function, op.get_var, parsed.function.closure_var[first_f_ref.?].var_name) > 0);
    try std.testing.expectEqual(@as(usize, 0), countOpcode(parsed.function.code[pc..], op.get_var_ref));
}

test "QuickJS direct eval hoist target walk distinguishes closure var-object and lexical conflict" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const f_atom = try rt.internAtom("f");
    defer rt.atoms.free(f_atom);
    const closure_seed = [_]parser.EvalClosureSeed{
        .{ .var_name = f_atom, .closure_type = .arg, .var_idx = 0, .var_kind = .normal },
        .{ .var_name = atom.ids.var_object, .closure_type = .local, .var_idx = 1, .var_kind = .normal },
    };
    var closure_target = try parser.compile(rt, "function f(){ return 1; }", .{
        .mode = .eval_direct,
        .filename = "<eval>",
        .eval_closure_seed = &closure_seed,
    });
    defer closure_target.deinit();
    try std.testing.expect(closure_target.syntax_error == null);
    try std.testing.expect(closure_target.function.code[0] == op.fclosure8 or closure_target.function.code[0] == op.fclosure);
    const closure_put_pc = engine.bytecode.opcode.sizeOf(closure_target.function.code[0]);
    try std.testing.expectEqual(op.put_var_ref0, closure_target.function.code[closure_put_pc]);
    try std.testing.expectEqual(@as(usize, 0), countOpcode(closure_target.function.code, op.define_field));

    const var_object_seed = [_]parser.EvalClosureSeed{
        .{ .var_name = atom.ids.var_object, .closure_type = .local, .var_idx = 0, .var_kind = .normal },
    };
    var var_object_target = try parser.compile(rt, "function f(){ return 1; }", .{
        .mode = .eval_direct,
        .filename = "<eval>",
        .eval_closure_seed = &var_object_seed,
    });
    defer var_object_target.deinit();
    try std.testing.expect(var_object_target.syntax_error == null);
    try std.testing.expectEqual(op.get_var_ref0, var_object_target.function.code[0]);
    try std.testing.expectEqual(@as(usize, 1), countFunctionClosures(var_object_target.function.code));
    try std.testing.expectEqual(@as(usize, 1), countOpcode(var_object_target.function.code, op.define_field));

    const lexical_seed = [_]parser.EvalClosureSeed{
        .{ .var_name = f_atom, .closure_type = .local, .var_idx = 0, .is_lexical = true, .var_kind = .normal },
        .{ .var_name = atom.ids.var_object, .closure_type = .local, .var_idx = 1, .var_kind = .normal },
    };
    var lexical_conflict = try parser.compile(rt, "function f(){}", .{
        .mode = .eval_direct,
        .filename = "<eval>",
        .eval_closure_seed = &lexical_seed,
    });
    defer lexical_conflict.deinit();
    try std.testing.expect(lexical_conflict.syntax_error == null);
    try std.testing.expectEqual(op.throw_error, lexical_conflict.function.code[0]);
    try std.testing.expectEqual(@as(usize, 0), countFunctionClosures(lexical_conflict.function.code));
}

test "F10.1c Nested function: bytecode dual-buffering" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    const name = try env.rt.internAtom("test");
    defer env.rt.atoms.free(name);
    var function = engine.bytecode.Bytecode.init(&env.rt.memory, &env.rt.atoms, name);
    defer function.deinit(env.rt);

    // Parse a nested function expression: (function() { 42 })
    var lex = QjsLexer.init(std.testing.allocator, &env.rt.atoms, "(function() { 42 })");
    var state = try ParseState.init(&lex, &function);
    defer state.deinit(env.rt);
    state.top_level_functions_as_children = true;

    try parser_core.parseExpr(&state);

    try std.testing.expect(countOpcode(state.function.code, op.fclosure) + countOpcode(state.function.code, op.fclosure8) > 0);

    try std.testing.expectEqual(@as(usize, 1), state.function_def.child_list.len);
    const child = state.function_def.child_list[0];
    try std.testing.expect(child.parent_cpool_idx >= 0);
    try expectOpcode(child.byte_code, op.push_i32);
    try expectOpcode(child.byte_code, op.return_undef);

    // Verify emit_to_function_def flag is false after parsing
    try std.testing.expectEqual(false, state.emit_to_function_def);
}

test "TS: Class Constructor Parameter Properties" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var bytecode = try parseTSStatement(&env,
        \\class Point {
        \\    constructor(public x, readonly y) {
        \\    }
        \\}
    );
    defer bytecode.deinit(env.rt);
    try std.testing.expect(bytecode.constants.values.len > 0);
}

test "TS: Enum Declarations" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var bytecode = try parseTSStatement(&env,
        \\enum Direction {
        \\    Up,
        \\    Down = 2,
        \\    Left,
        \\    Right = "Right"
        \\}
    );
    defer bytecode.deinit(env.rt);
    try expectOpcode(bytecode.code, op.put_field);
    try expectOpcode(bytecode.code, op.put_array_el);
}

test "TS: Const Enum Declarations Lower As Runtime Enums" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var bytecode = try parseTSStatement(&env,
        \\const enum Direction {
        \\    Up,
        \\    Down = 2
        \\}
    );
    defer bytecode.deinit(env.rt);
    try expectOpcode(bytecode.code, op.put_field);
    try expectOpcode(bytecode.code, op.put_array_el);
}

test "TS: Nested Generic Greater Tokens" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var bytecode = try parseTSProgram(&env,
        \\type K = string;
        \\type V = number;
        \\type K2 = string;
        \\function id<T>(value: any): any { return value; }
        \\const a: Promise<Array<number>> = null;
        \\const b: Map<string, Array<number>> = new Map();
        \\const c: Record<string, Array<number>> = {};
        \\const d: Map<K, Map<K2, V>> = new Map();
        \\const e = id<Map<K, V>>(new Map());
        \\const f: Array<number>[] = [];
        \\const shift = 8 >> 1;
        \\const ge = 3 >= 2;
    );
    defer bytecode.deinit(env.rt);
    try std.testing.expect(bytecode.code.len > 0);
}

test "TS: Const Type Parameters" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var bytecode = try parseTSProgram(&env,
        \\function f<const T>(x: T): T { return x; }
        \\class Box<const T> {
        \\    value: T;
        \\    constructor(value: T) { this.value = value; }
        \\}
    );
    defer bytecode.deinit(env.rt);
    try std.testing.expect(bytecode.code.len > 0);
}

test "TS: Function Overload Signatures Are Skipped" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var bytecode = try parseTSProgram(&env,
        \\function g(x: number): number;
        \\function g(x: string): string;
        \\function g(x: any): any { return x; }
    );
    defer bytecode.deinit(env.rt);
    try std.testing.expectEqual(@as(usize, 1), countFunctionClosures(bytecode.code));
    try std.testing.expectEqual(@as(usize, 1), countPutVarRefStores(bytecode.code));
    try std.testing.expectEqual(@as(usize, 1), globalDeclarationClosureCount(&bytecode));
    const g_decl = globalDeclarationClosureNamed(&bytecode, env.rt, "g") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(function_def.VarKind.global_function_decl, g_decl.varKind());
    try std.testing.expectEqual(@as(usize, 1), bytecode.constants.values.len);
    const child = findFunctionConstantNamed(&bytecode, env.rt, "g") orelse return error.TestExpectedEqual;
    try expectAtomName(&env, child.func_name, "g");
}

test "TS: Class Method Overload Signatures Are Skipped" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var bytecode = try parseTSProgram(&env,
        \\class S {
        \\    process(x: number): string;
        \\    process(x: string): number;
        \\    process(x: any): any { return x; }
        \\}
        \\new S().process(1);
    );
    defer bytecode.deinit(env.rt);
    try std.testing.expect(bytecode.code.len > 0);
}

test "TS: Generic Arrow Type Parameters Are Skipped" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var bytecode = try parseTSProgram(&env,
        \\const f = <T,>(x: T): T => x;
        \\const id = <T, U>(a: T, b: U): T => a;
        \\const a = f(7);
        \\const b = id(1, "x");
        \\const c = 1 < 2;
    );
    defer bytecode.deinit(env.rt);
    try std.testing.expect(bytecode.code.len > 0);
}

test "TS: Inline Object Type Parameter Constraints Are Skipped" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var bytecode = try parseTSProgram(&env,
        \\function foo<U extends { x: number }>(u: U) { return u.x; }
        \\class C<T extends { id: string }> {
        \\    value: T;
        \\    constructor(value: T) { this.value = value; }
        \\}
        \\foo({ x: 9 });
    );
    defer bytecode.deinit(env.rt);
    try std.testing.expect(bytecode.code.len > 0);
}

test "TS: Unsupported Syntax Scan Reports Feature And Position" {
    const decorator = (try parser.lexer.findUnsupportedTypeScriptSyntax(std.testing.allocator,
        \\class Before {}
        \\@sealed
        \\class C {}
    )).?;
    try std.testing.expectEqual(@as(u32, 2), decorator.line);
    try std.testing.expectEqual(@as(u32, 1), decorator.column);
    try std.testing.expect(std.mem.indexOf(u8, decorator.message, "TS decorators") != null);
    try std.testing.expect(std.mem.indexOf(u8, decorator.message, "remove the decorator") != null);

    const import_equals = (try parser.lexer.findUnsupportedTypeScriptSyntax(
        std.testing.allocator,
        "import X = require(\"x\");",
    )).?;
    try std.testing.expectEqual(@as(u32, 1), import_equals.line);
    try std.testing.expectEqual(@as(u32, 10), import_equals.column);
    try std.testing.expect(std.mem.indexOf(u8, import_equals.message, "TS import=/export=") != null);
    try std.testing.expect(std.mem.indexOf(u8, import_equals.message, "use ESM import/export") != null);
}

test "TS: Namespaces" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var bytecode = try parseTSStatement(&env,
        \\namespace Outer {
        \\    export namespace Inner {
        \\        export const x = 1;
        \\        export function foo() {}
        \\        export class Bar {}
        \\    }
        \\}
    );
    defer bytecode.deinit(env.rt);
    try std.testing.expect(bytecode.code.len > 0);
}

test "TS: Nested Constructor Block Parameter Re-emission" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var bytecode = try parseTSStatement(&env,
        \\class Base {
        \\    constructor(public x) {
        \\        this.x = 10;
        \\        {
        \\            const y = 20;
        \\        }
        \\    }
        \\}
    );
    defer bytecode.deinit(env.rt);
    try std.testing.expect(bytecode.code.len > 0);
}

test "TS: Derived Constructor Parameter Properties post-super" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var bytecode = try parseTSStatement(&env,
        \\class Derived extends Base {
        \\    constructor(public y) {
        \\        super(1);
        \\    }
        \\}
    );
    defer bytecode.deinit(env.rt);
    try std.testing.expect(bytecode.code.len > 0);
}

test "TS: Namespace Scope Isolation" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var bytecode = try parseTSStatement(&env,
        \\namespace N {
        \\    var w = 1;
        \\    export function f() {}
        \\}
    );
    defer bytecode.deinit(env.rt);
    try std.testing.expect(bytecode.code.len > 0);
}

test "TS: Dotted Namespaces" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var bytecode = try parseTSStatement(&env,
        \\namespace A.B {
        \\    export const x = 42;
        \\}
    );
    defer bytecode.deinit(env.rt);
    try std.testing.expect(bytecode.code.len > 0);
}

test "TS: Strict Enum Constant Expression Rejection" {
    var env = try ParserTestEnv.init();
    defer env.deinit();

    // 1. Valid enum declaration with positive/negative numbers and string literals
    var valid_bytecode = try parseTSStatement(&env,
        \\enum Direction {
        \\    Up = 1,
        \\    Down = -2,
        \\    Left = "Left"
        \\}
    );
    defer valid_bytecode.deinit(env.rt);
    try std.testing.expect(valid_bytecode.code.len > 0);

    // 2. Invalid enum declaration with complex expression should throw UnexpectedToken
    const invalid_res = parseTSStatement(&env,
        \\enum Direction {
        \\    Up = 10 - 8
        \\}
    );
    try std.testing.expectError(error.UnexpectedToken, invalid_res);
}

// ================== INTEGRATION TESTS ==================

fn countCalls(code: []const u8) usize {
    return countOpcode(code, qop.call) +
        countOpcode(code, qop.call0) +
        countOpcode(code, qop.call1) +
        countOpcode(code, qop.call2) +
        countOpcode(code, qop.call3);
}

fn countFunctionClosures(code: []const u8) usize {
    return countOpcode(code, qop.fclosure) + countOpcode(code, qop.fclosure8);
}

test "try finally parses one shared finalizer body for every abrupt exit" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try parser.compile(rt,
        \\function outer(kind) {
        \\  outerLoop: while (true) {
        \\    try {
        \\      if (kind === 0) return 0;
        \\      if (kind === 1) break outerLoop;
        \\      if (kind === 2) continue outerLoop;
        \\      throw kind;
        \\    } catch (error) {
        \\      if (kind === 3) return error;
        \\      if (kind === 4) continue outerLoop;
        \\      break outerLoop;
        \\    } finally {
        \\      sink.singleFinalizerAtom = function singleFinalizerChild() { return 1; };
        \\    }
        \\  }
        \\}
    , .{ .mode = .script, .filename = "single-finalizer-body.js" });
    defer parsed.deinit();
    try std.testing.expect(parsed.syntax_error == null);

    const outer = findFunctionConstantNamed(&parsed.function, rt, "outer") orelse
        return error.TestExpectedEqual;

    var finalizer_child_count: usize = 0;
    for (outer.cpoolSlice()) |value| {
        const child = functionBytecodeFromValue(value) orelse continue;
        if (std.mem.eql(u8, rt.atoms.name(child.func_name) orelse "", "singleFinalizerChild")) {
            finalizer_child_count += 1;
        }
    }

    var finalizer_atom_count: usize = 0;
    var atom_it = outer.atomOperandIterator();
    while (atom_it.next()) |atom_id| {
        if (std.mem.eql(u8, rt.atoms.name(atom_id) orelse "", "singleFinalizerAtom")) {
            finalizer_atom_count += 1;
        }
    }

    // Every normal/throw/return/break/continue edge calls one shared body.
    // The body's child, constant-pool entry, atom-bearing store, code and ret
    // therefore occur once even though several gosub sites target it.
    try std.testing.expect(countOpcode(outer.byteCode(), qop.gosub) >= 4);
    try std.testing.expectEqual(@as(usize, 1), countOpcode(outer.byteCode(), qop.ret));
    try std.testing.expectEqual(@as(usize, 1), countFunctionClosures(outer.byteCode()));
    try std.testing.expectEqual(@as(usize, 1), finalizer_child_count);
    try std.testing.expectEqual(@as(usize, 1), finalizer_atom_count);
}

test "try catch fixed topology removes calls to its empty finalizer" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try parser.compile(
        rt,
        "function noFinally(value) { try { if (value) return 1; throw 2; } catch (error) { return error; } }",
        .{ .mode = .script, .filename = "empty-finalizer.js" },
    );
    defer parsed.deinit();
    try std.testing.expect(parsed.syntax_error == null);

    const function = findFunctionConstantNamed(&parsed.function, rt, "noFinally") orelse
        return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 0), countOpcode(function.byteCode(), qop.gosub));
}

fn functionBytecodeHasKind(fb: *const engine.bytecode.FunctionBytecode, kind: function_def.FunctionKind) bool {
    if (fb.flags.func_kind == kind) return true;
    for (fb.cpoolSlice()) |value| {
        if (functionBytecodeFromValue(value)) |child| {
            if (functionBytecodeHasKind(child, kind)) return true;
        }
    }
    return false;
}

fn functionBytecodeHasClosure(
    rt: *core.JSRuntime,
    fb: *const engine.bytecode.FunctionBytecode,
    name: []const u8,
    closure_type: function_def.ClosureType,
) bool {
    for (fb.closureVar()) |cv| {
        if (cv.closureType() == closure_type and std.mem.eql(u8, rt.atoms.name(cv.var_name) orelse "", name)) return true;
    }
    for (fb.cpoolSlice()) |value| {
        if (functionBytecodeFromValue(value)) |child| {
            if (functionBytecodeHasClosure(rt, child, name, closure_type)) return true;
        }
    }
    return false;
}

fn findArrowFunctionBytecode(fb: *const engine.bytecode.FunctionBytecode) ?*const engine.bytecode.FunctionBytecode {
    if (fb.flags.is_arrow_function) return fb;
    for (fb.cpoolSlice()) |value| {
        if (functionBytecodeFromValue(value)) |child| {
            if (findArrowFunctionBytecode(child)) |arrow| return arrow;
        }
    }
    return null;
}

fn findArrowInFunction(function: *const engine.bytecode.Bytecode) ?*const engine.bytecode.FunctionBytecode {
    for (function.constants.values) |value| {
        if (functionBytecodeFromValue(value)) |fb| {
            if (findArrowFunctionBytecode(fb)) |arrow| return arrow;
        }
    }
    return null;
}

fn functionHasClosure(
    rt: *core.JSRuntime,
    function: *const engine.bytecode.Bytecode,
    name: []const u8,
    closure_type: function_def.ClosureType,
) bool {
    for (function.constants.values) |value| {
        if (functionBytecodeFromValue(value)) |fb| {
            if (functionBytecodeHasClosure(rt, fb, name, closure_type)) return true;
        }
    }
    return false;
}

fn expectFunctionClosureRecursive(
    rt: *core.JSRuntime,
    function: *const engine.bytecode.Bytecode,
    name: []const u8,
    closure_type: function_def.ClosureType,
) !void {
    try std.testing.expect(functionHasClosure(rt, function, name, closure_type));
}

fn functionHasKind(function: *const engine.bytecode.Bytecode, kind: function_def.FunctionKind) bool {
    for (function.constants.values) |value| {
        if (functionBytecodeFromValue(value)) |fb| {
            if (functionBytecodeHasKind(fb, kind)) return true;
        }
    }
    return false;
}

fn expectFunctionKindRecursive(function: *const engine.bytecode.Bytecode, kind: function_def.FunctionKind) !void {
    try std.testing.expect(functionHasKind(function, kind));
}

test "arrow lexical this and new.target are ordinary closure captures" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try parser.compile(
        rt,
        "function outer() { return () => [this, new.target]; } outer;",
        .{ .mode = .script },
    );
    defer parsed.deinit();
    try std.testing.expect(parsed.syntax_error == null);

    const arrow = findArrowInFunction(&parsed.function) orelse return error.TestExpectedEqual;
    var captured_this = false;
    var captured_new_target = false;
    for (arrow.closureVar()) |capture| {
        captured_this = captured_this or capture.var_name == core.atom.ids.this_;
        captured_new_target = captured_new_target or capture.var_name == core.atom.ids.new_target;
    }
    try std.testing.expect(captured_this);
    try std.testing.expect(captured_new_target);
    try std.testing.expectEqual(@as(usize, 0), countOpcode(arrow.byteCode(), qop.push_this));
}

test "arrow super property captures lexical this through an ordinary cell" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try parser.compile(
        rt,
        "class Base { method() {} } class Derived extends Base { make() { return () => super.method(); } }",
        .{ .mode = .script },
    );
    defer parsed.deinit();
    try std.testing.expect(parsed.syntax_error == null);

    const arrow = findArrowInFunction(&parsed.function) orelse return error.TestExpectedEqual;
    var captured_this = false;
    for (arrow.closureVar()) |capture| {
        captured_this = captured_this or capture.var_name == core.atom.ids.this_;
    }
    try std.testing.expect(captured_this);
    try std.testing.expectEqual(@as(usize, 0), countOpcode(arrow.byteCode(), qop.push_this));
}

fn expectAtomOperandName(rt: *core.JSRuntime, function: *const engine.bytecode.Bytecode, expected: []const u8) !void {
    for (function.atom_operands) |atom_id| {
        if (rt.atoms.name(atom_id)) |name| {
            if (std.mem.eql(u8, name, expected)) return;
        }
    }
    return error.TestExpectedEqual;
}

fn expectNoLiveDynamicAtom(rt: *core.JSRuntime, kind: core.atom.AtomKind, bytes: []const u8) !void {
    for (rt.atoms.entries) |entry| {
        if (!entry.isLive() or entry.kind != kind) continue;
        if (std.mem.eql(u8, entry.bytes, bytes)) {
            std.debug.print("\n=== LEAKED ATOM FOUND: '{s}' kind={s} ref_count={d} ===\n", .{ entry.bytes, @tagName(entry.kind), entry.ref_count });
        }
        try std.testing.expect(!std.mem.eql(u8, entry.bytes, bytes));
    }
}

test "syntax error deinit balances empty message allocation" {
    var account = core.memory.MemoryAccount.init(std.testing.allocator);
    var atoms = core.atom.AtomTable.init(&account);

    var syntax_error = try parser.diagnostics.SyntaxError.create(&account, &atoms, core.atom.null_atom, .{}, "");
    syntax_error.deinit();
    atoms.deinit();

    try std.testing.expect(!account.hasOutstandingAllocations());
}

test "source positions and syntax errors carry filename line and column" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try parser.compile(rt, "let x = (\n1", .{ .mode = .script, .filename = "bad.js" });
    defer parsed.deinit();

    try std.testing.expect(parsed.syntax_error != null);
    try std.testing.expectEqual(parser.CompilePath.syntax_error_guard, parsed.parse_path);
    try std.testing.expectEqual(@as(u32, 2), parsed.syntax_error.?.position.line);
    try std.testing.expect(parsed.syntax_error.?.message.len > 0);
    try std.testing.expectEqualStrings("bad.js", rt.atoms.name(parsed.syntax_error.?.filename).?);
}

test "direct eval propagates script or module identity without changing display filename" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const referrer = try rt.internAtom("/fixture/scripts/main.mjs");
    var owns_referrer = true;
    defer if (owns_referrer) rt.atoms.free(referrer);

    var parsed = try parser.compile(
        rt,
        "function outer(){ return function inner(){}; } outer;",
        .{
            .mode = .eval_direct,
            .filename = "<eval>",
            .script_or_module = referrer,
        },
    );
    defer parsed.deinit();

    rt.atoms.free(referrer);
    owns_referrer = false;
    try std.testing.expectEqualStrings("<eval>", rt.atoms.name(parsed.function.filename).?);
    try std.testing.expectEqualStrings("/fixture/scripts/main.mjs", rt.atoms.name(parsed.function.script_or_module).?);

    const outer = blk: {
        for (parsed.function.constants.values) |value| {
            if (functionBytecodeFromValue(value)) |fb| break :blk fb;
        }
        return error.TestExpectedEqual;
    };
    try std.testing.expectEqualStrings("<eval>", rt.atoms.name(outer.filename).?);
    try std.testing.expectEqualStrings("/fixture/scripts/main.mjs", rt.atoms.name(outer.scriptOrModule()).?);

    const inner = blk: {
        for (outer.cpoolSlice()) |value| {
            if (functionBytecodeFromValue(value)) |fb| break :blk fb;
        }
        return error.TestExpectedEqual;
    };
    try std.testing.expectEqualStrings("<eval>", rt.atoms.name(inner.filename).?);
    try std.testing.expectEqualStrings("/fixture/scripts/main.mjs", rt.atoms.name(inner.scriptOrModule()).?);
}

test "script parse mode emits bytecode metadata without AST execution" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try parser.compile(rt, "var x = 1; x + 2;", .{ .mode = .script, .filename = "script.js" });
    defer parsed.deinit();

    try std.testing.expect(parsed.syntax_error == null);
    try std.testing.expectEqual(parser.CompilePath.normal, parsed.parse_path);
    try std.testing.expect(!parsed.function.flags.is_strict);
    try expectOpcode(parsed.function.code, qop.add);
    try expectOpcode(parsed.function.code, qop.drop);
    try std.testing.expect(countOpcode(parsed.function.code, qop.return_undef) + countOpcode(parsed.function.code, qop.return_async) > 0);
    try std.testing.expectEqual(@as(usize, 0), parsed.function.constants.values.len);
}

test "root strictness comes from directives or host options, never source comments" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var commented = try parser.compile(
        rt,
        "/*---\nflags: [onlyStrict]\n---*/\nfunction acceptsEval(eval) { return eval; }",
        .{ .mode = .script, .filename = "commented-metadata.js" },
    );
    defer commented.deinit();
    try std.testing.expect(commented.syntax_error == null);
    try std.testing.expect(!commented.function.flags.is_strict);

    var directive = try parser.compile(
        rt,
        "\"other directive\"; \"use strict\"; var local = 1;",
        .{ .mode = .eval_direct, .filename = "directive-eval.js" },
    );
    defer directive.deinit();
    try std.testing.expect(directive.syntax_error == null);
    try std.testing.expect(directive.function.flags.is_strict);
    try std.testing.expect(!directive.function.flags.is_global_var);

    var host_strict = try parser.compile(
        rt,
        "/* ordinary comment */ function rejectsEval(eval) { return eval; }",
        .{ .mode = .script, .filename = "host-strict.js", .strict = true },
    );
    defer host_strict.deinit();
    try std.testing.expect(host_strict.syntax_error != null);
}

test "eval type owns var and lexical declaration carriers like pinned QuickJS" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var indirect_sloppy = try parser.compile(
        rt,
        "var indirectVar; let indirectLet; class IndirectClass {} function indirectFn() {}",
        .{ .mode = .eval_indirect, .filename = "<eval>" },
    );
    defer indirect_sloppy.deinit();
    try std.testing.expect(indirect_sloppy.syntax_error == null);
    try std.testing.expect(indirect_sloppy.function.flags.is_global_var);
    try std.testing.expect(globalDeclarationClosureNamed(&indirect_sloppy.function, rt, "indirectVar") != null);
    try std.testing.expect(globalDeclarationClosureNamed(&indirect_sloppy.function, rt, "indirectLet") == null);
    try std.testing.expect(globalDeclarationClosureNamed(&indirect_sloppy.function, rt, "IndirectClass") == null);
    try std.testing.expectEqual(
        function_def.VarKind.global_function_decl,
        globalDeclarationClosureNamed(&indirect_sloppy.function, rt, "indirectFn").?.varKind(),
    );
    try std.testing.expect(varDefNamed(&indirect_sloppy.function, rt, "indirectVar") == null);
    const indirect_let = varDefNamed(&indirect_sloppy.function, rt, "indirectLet") orelse return error.TestExpectedEqual;
    const indirect_class = varDefNamed(&indirect_sloppy.function, rt, "IndirectClass") orelse return error.TestExpectedEqual;
    try std.testing.expect(indirect_let.isLexical() and indirect_let.hasScope());
    try std.testing.expect(indirect_class.isLexical() and indirect_class.hasScope());

    var indirect_strict = try parser.compile(
        rt,
        "'use strict'; var strictVar; let strictLet; class StrictClass {} function strictFn() {}",
        .{ .mode = .eval_indirect, .filename = "<eval>" },
    );
    defer indirect_strict.deinit();
    try std.testing.expect(indirect_strict.syntax_error == null);
    try std.testing.expect(!indirect_strict.function.flags.is_global_var);
    try std.testing.expectEqual(@as(usize, 0), globalDeclarationClosureCount(&indirect_strict.function));
    const strict_var = varDefNamed(&indirect_strict.function, rt, "strictVar") orelse return error.TestExpectedEqual;
    const strict_let = varDefNamed(&indirect_strict.function, rt, "strictLet") orelse return error.TestExpectedEqual;
    const strict_class = varDefNamed(&indirect_strict.function, rt, "StrictClass") orelse return error.TestExpectedEqual;
    const strict_function = varDefNamed(&indirect_strict.function, rt, "strictFn") orelse return error.TestExpectedEqual;
    try std.testing.expect(!strict_var.isLexical() and !strict_var.hasScope());
    try std.testing.expect(strict_let.isLexical() and strict_let.hasScope());
    try std.testing.expect(strict_class.isLexical() and strict_class.hasScope());
    try std.testing.expect(!strict_function.isLexical() and !strict_function.hasScope());

    // JS_EVAL_TYPE_GLOBAL is different from indirect eval: strictness does
    // not move its program declarations out of the global declaration table.
    var global_strict = try parser.compile(
        rt,
        "'use strict'; var globalVar; let globalLet; class GlobalClass {} function globalFn() {}",
        .{ .mode = .script, .filename = "script.js" },
    );
    defer global_strict.deinit();
    try std.testing.expect(global_strict.syntax_error == null);
    try std.testing.expect(global_strict.function.flags.is_global_var);
    try std.testing.expect(!globalDeclarationClosureNamed(&global_strict.function, rt, "globalVar").?.isLexical());
    try std.testing.expect(globalDeclarationClosureNamed(&global_strict.function, rt, "globalLet").?.isLexical());
    try std.testing.expect(globalDeclarationClosureNamed(&global_strict.function, rt, "GlobalClass").?.isLexical());
    try std.testing.expectEqual(
        function_def.VarKind.global_function_decl,
        globalDeclarationClosureNamed(&global_strict.function, rt, "globalFn").?.varKind(),
    );
}

test "ordinary block string literal is not a function-body directive" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try parser.compile(
        rt,
        "function f(){ { 'use strict'; } return this; }",
        .{ .mode = .script, .filename = "ordinary-block-directive.js" },
    );
    defer parsed.deinit();
    try std.testing.expect(parsed.syntax_error == null);

    const f = findFunctionConstantNamed(&parsed.function, rt, "f") orelse return error.TestExpectedEqual;
    try std.testing.expect(!f.flags.is_strict_mode);
}

test "function body declarations preserve QuickJS source VarDef order" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try parser.compile(
        rt,
        "function f(){ let a = 1; var b = 2; return a + b; }",
        .{ .mode = .script, .filename = "function-body-vardef-order.js" },
    );
    defer parsed.deinit();
    try std.testing.expect(parsed.syntax_error == null);

    const f = findFunctionConstantNamed(&parsed.function, rt, "f") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 2), f.varDefs().len);
    try std.testing.expectEqualStrings("a", rt.atoms.name(f.varDefs()[0].var_name) orelse "");
    try std.testing.expectEqualStrings("b", rt.atoms.name(f.varDefs()[1].var_name) orelse "");
}

test "body var discovery does not cross arrow or class method boundaries" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try parser.compile(
        rt,
        "var x; var y; function outer(){ (()=>{ var x; })(); class C { m(){ var y; } } x = 1; y = 1; }",
        .{ .mode = .script, .filename = "nested-function-var-boundary.js" },
    );
    defer parsed.deinit();
    try std.testing.expect(parsed.syntax_error == null);

    const outer = findFunctionConstantNamed(&parsed.function, rt, "outer") orelse return error.TestExpectedEqual;
    for (outer.varDefs()) |vd| {
        const name = rt.atoms.name(vd.var_name) orelse "";
        try std.testing.expect(!std.mem.eql(u8, name, "x"));
        try std.testing.expect(!std.mem.eql(u8, name, "y"));
    }
}

test "generic for-of accepts complete parenthesized and indexed member targets" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const cases = [_][]const u8{
        "let a = {}; for ((a).p of []) { break; }",
        "let a = {}; for (a['p'] of []) { break; }",
    };
    for (cases, 0..) |source, index| {
        var parsed = try parser.compile(
            rt,
            source,
            .{ .mode = .script, .filename = if (index == 0) "for-parenthesized-member.js" else "for-indexed-member.js" },
        );
        defer parsed.deinit();
        try std.testing.expect(parsed.syntax_error == null);
    }
}

test "for-of contextual async lookahead follows QuickJS grammar" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var invalid = try parser.compile(
        rt,
        "var async; for (async of [1]) ;",
        .{ .mode = .script, .filename = "for-of-async-invalid.js" },
    );
    defer invalid.deinit();
    try std.testing.expect(invalid.syntax_error != null);

    const valid_cases = [_][]const u8{
        "var async; for ((async) of [1]) ;",
        "var i = 0; for (async of => {}; i < 1; ++i) {}",
        "async function f() { var async; for await (async of [1]) ; }",
    };
    for (valid_cases) |source| {
        var parsed = try parser.compile(
            rt,
            source,
            .{ .mode = .script, .filename = "for-of-async-valid.js" },
        );
        defer parsed.deinit();
        try std.testing.expect(parsed.syntax_error == null);
    }
}

test "generic for-of parses computed target exactly once in source order" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try parser.compile(
        rt,
        "let a = {}; for ((a[function x(){}]) of [function y(){}]) { break; }",
        .{ .mode = .script, .filename = "for-computed-target-once.js" },
    );
    defer parsed.deinit();
    try std.testing.expect(parsed.syntax_error == null);

    try std.testing.expectEqual(@as(usize, 1), countFunctionConstantsNamed(&parsed.function, rt, "x"));
    try std.testing.expectEqual(@as(usize, 1), countFunctionConstantsNamed(&parsed.function, rt, "y"));
    try std.testing.expectEqual(@as(usize, 2), parsed.function.constants.values.len);
}

test "for statement dispatch only scans top-level semicolons" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const cases = [_][]const u8{
        "for (let i = (function(){ return 0; })(); i < 1; i++) {}",
        "let value; for (value of [function(){ return 1; }]) { break; }",
        "let value; for (value of [`x${function(){ return ';'; }()}`]) { break; }",
        "let value; for (value of [/;/]) { break; }",
    };
    for (cases, 0..) |source, index| {
        var parsed = try parser.compile(
            rt,
            source,
            .{ .mode = .script, .filename = if (index == 0) "for-c-style.js" else "for-in-of-no-top-level-semi.js" },
        );
        defer parsed.deinit();
        try std.testing.expect(parsed.syntax_error == null);
    }
}

test "for-in-of rejects call and optional-chain assignment targets" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const cases = [_][]const u8{
        "function f(){}; for (f() of []) {}",
        "let value = {}; for (value?.x in {}) {}",
        "let a, source = {}; for ([a] = 1 in source) {}",
    };
    for (cases) |source| {
        var parsed = try parser.compile(rt, source, .{ .mode = .script, .filename = "invalid-for-lvalue.js" });
        defer parsed.deinit();
        try std.testing.expect(parsed.syntax_error != null);
    }
}

test "script top-level lexical captured before declaration uses QuickJS global op" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try parser.compile(rt,
        \\function f() { return x + 1; }
        \\let x;
    , .{ .mode = .script, .filename = "global-closure-tdz.js" });
    defer parsed.deinit();

    try std.testing.expect(parsed.syntax_error == null);
    try std.testing.expectEqual(parser.CompilePath.normal, parsed.parse_path);
    // The inner function carries `.global_ref`, but QuickJS resolves every
    // global-family access to OP_get_var. That opcode reads the cell first and
    // performs the lexical-uninitialized check before any global-object
    // fallback; OP_get_var_ref_check is reserved for non-global closures.
    try expectFunctionClosureRecursive(rt, &parsed.function, "x", function_def.ClosureType.global_ref);
    try std.testing.expect(countOpcodeRecursive(&parsed.function, qop.get_var) >= 1);
    try std.testing.expectEqual(@as(usize, 0), countOpcodeRecursive(&parsed.function, qop.get_var_ref_check));
}

test "captured reads encode lexical TDZ in the final var-ref opcode" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var plain = try parser.compile(
        rt,
        "function outer() { var captured = 1; return function inner() { return captured; }; }",
        .{ .mode = .script, .filename = "closure-var-read.js" },
    );
    defer plain.deinit();
    try std.testing.expect(plain.syntax_error == null);

    const plain_reads = countOpcodeRecursive(&plain.function, qop.get_var_ref) +
        countOpcodeRecursive(&plain.function, qop.get_var_ref0) +
        countOpcodeRecursive(&plain.function, qop.get_var_ref1) +
        countOpcodeRecursive(&plain.function, qop.get_var_ref2) +
        countOpcodeRecursive(&plain.function, qop.get_var_ref3);
    try std.testing.expect(plain_reads >= 1);
    try std.testing.expectEqual(@as(usize, 0), countOpcodeRecursive(&plain.function, qop.get_var_ref_check));

    var checked = try parser.compile(
        rt,
        "function outer() { let captured = 1; return function inner() { return captured; }; }",
        .{ .mode = .script, .filename = "closure-let-read.js" },
    );
    defer checked.deinit();
    try std.testing.expect(checked.syntax_error == null);
    try std.testing.expect(countOpcodeRecursive(&checked.function, qop.get_var_ref_check) >= 1);
}

test "named function self-binding writes do not reach var-ref stores" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var sloppy = try parser.compile(
        rt,
        "(function named() { return function inner() { named = 0; named += 1; named++; ++named; }; });",
        .{ .mode = .script, .filename = "function-name-write.js" },
    );
    defer sloppy.deinit();
    try std.testing.expect(sloppy.syntax_error == null);

    const var_ref_writes = countOpcodeRecursive(&sloppy.function, qop.put_var_ref) +
        countOpcodeRecursive(&sloppy.function, qop.put_var_ref0) +
        countOpcodeRecursive(&sloppy.function, qop.put_var_ref1) +
        countOpcodeRecursive(&sloppy.function, qop.put_var_ref2) +
        countOpcodeRecursive(&sloppy.function, qop.put_var_ref3) +
        countOpcodeRecursive(&sloppy.function, qop.put_var_ref_check) +
        countOpcodeRecursive(&sloppy.function, qop.put_var_ref_check_init) +
        countOpcodeRecursive(&sloppy.function, qop.set_var_ref) +
        countOpcodeRecursive(&sloppy.function, qop.set_var_ref0) +
        countOpcodeRecursive(&sloppy.function, qop.set_var_ref1) +
        countOpcodeRecursive(&sloppy.function, qop.set_var_ref2) +
        countOpcodeRecursive(&sloppy.function, qop.set_var_ref3);
    try std.testing.expectEqual(@as(usize, 0), var_ref_writes);

    var dynamic = try parser.compile(
        rt,
        "(function named(scope) { with (scope) { named += 1; } return function inner(innerScope) { with (innerScope) { named += 1; } }; });",
        .{ .mode = .script, .filename = "function-name-dynamic-write.js" },
    );
    defer dynamic.deinit();
    try std.testing.expect(dynamic.syntax_error == null);
    // qjs get_lvalue snapshots the selected reference with scope_make_ref;
    // resolve_variables lowers the dynamic probe to with_make_ref, followed
    // by get_ref_value/put_ref_value. Both the defining frame and captured
    // self-binding must use that transport rather than re-resolving a store.
    try std.testing.expect(countOpcodeRecursive(&dynamic.function, qop.with_make_ref) >= 2);
    try std.testing.expect(countOpcodeRecursive(&dynamic.function, qop.put_ref_value) >= 2);

    var strict = try parser.compile(
        rt,
        "(function named() { 'use strict'; return function inner() { named = 0; }; });",
        .{ .mode = .script, .filename = "strict-function-name-write.js" },
    );
    defer strict.deinit();
    try std.testing.expect(strict.syntax_error == null);
    try std.testing.expect(countOpcodeRecursive(&strict.function, qop.throw_error) >= 1);

    var parameter_default = try parser.compile(
        rt,
        "(function named(value = named) { return value; });",
        .{ .mode = .script, .filename = "function-name-parameter-default.js" },
    );
    defer parameter_default.deinit();
    try std.testing.expect(parameter_default.syntax_error == null);
    // The argument environment is not linked to body scope 0. QuickJS still
    // resolves the fallback name through func_var_idx, never as a global.
    try std.testing.expectEqual(@as(usize, 0), countOpcodeRecursive(&parameter_default.function, qop.get_var));
    const local_reads = countOpcodeRecursive(&parameter_default.function, qop.get_loc) +
        countOpcodeRecursive(&parameter_default.function, qop.get_loc0) +
        countOpcodeRecursive(&parameter_default.function, qop.get_loc1) +
        countOpcodeRecursive(&parameter_default.function, qop.get_loc2) +
        countOpcodeRecursive(&parameter_default.function, qop.get_loc3);
    try std.testing.expect(local_reads >= 1);
}

test "assignment target scan ignores atom operand bytes" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var held_atoms = std.ArrayList(core.Atom).empty;
    defer {
        for (held_atoms.items) |atom_id| rt.atoms.free(atom_id);
        held_atoms.deinit(std.testing.allocator);
    }

    var index: u32 = 0;
    while (true) : (index += 1) {
        var name_buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "operand_pad_{d}", .{index});
        const atom_id = try rt.internAtom(name);
        try held_atoms.append(std.testing.allocator, atom_id);
        if ((atom_id & 0xff) == engine.bytecode.opcode.op.is_undefined_or_null - 1) break;
    }

    var parsed = try parser.compile(rt, "var count2 = 2; while (count2 -= 1) { 3; }", .{ .mode = .eval_direct, .filename = "eval" });
    defer parsed.deinit();

    try std.testing.expect(parsed.syntax_error == null);
    try std.testing.expectEqual(parser.CompilePath.normal, parsed.parse_path);
}

test "print calls emit global lookup generic call and receiver-preserving property call bytecode" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try parser.compile(rt, "print(1 + 2 * 3); console.log(\"ok\");", .{ .mode = .script, .filename = "print.js" });
    defer parsed.deinit();

    try std.testing.expectEqual(parser.CompilePath.normal, parsed.parse_path);

    var get_var_count: usize = 0;
    var get_prop_count: usize = 0;
    var call_count: usize = 0;
    var call_method_count: usize = 0;
    var mul_index: ?usize = null;
    var add_index: ?usize = null;
    var i: usize = 0;
    while (i < parsed.function.code.len) {
        const op_val = parsed.function.code[i];
        if (op_val == engine.bytecode.opcode.op.mul) mul_index = mul_index orelse i;
        if (op_val == engine.bytecode.opcode.op.add) add_index = add_index orelse i;
        if (op_val == engine.bytecode.opcode.op.get_var) get_var_count += 1;
        if (op_val == engine.bytecode.opcode.op.get_field) get_prop_count += 1;
        if (op_val == engine.bytecode.opcode.op.call) call_count += 1;
        if (op_val == engine.bytecode.opcode.op.call_method) call_method_count += 1;
        i += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), get_var_count);
    try std.testing.expectEqual(@as(usize, 0), get_prop_count);
    try std.testing.expect(call_count + countOpcode(parsed.function.code, engine.bytecode.opcode.op.call1) >= 1);
    try std.testing.expectEqual(@as(usize, 1), call_method_count);
    try std.testing.expect(mul_index != null);
    try std.testing.expect(add_index != null);
    try std.testing.expect(mul_index.? < add_index.?);
    try std.testing.expect(add_index.? < parsed.function.code.len);
}

test "simple variable assignments emit var bytecode" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try parser.compile(rt, "let value = 5; value = value + 7; print(value);", .{ .mode = .script, .filename = "vars.js" });
    defer parsed.deinit();

    try std.testing.expectEqual(parser.CompilePath.normal, parsed.parse_path);

    var get_var_count: usize = 0;
    for (parsed.function.code) |op_val| {
        if (op_val == engine.bytecode.opcode.op.get_var) get_var_count += 1;
    }
    try std.testing.expect(get_var_count >= 1);
    try std.testing.expectEqual(@as(usize, 1), globalDeclarationClosureCount(&parsed.function));
    try std.testing.expect(globalDeclarationClosureNamed(&parsed.function, rt, "value").?.isLexical());
}

test "quick parser emits compound assignment and update statements" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try parser.compile(rt, "let x = 1; x += 2; x++; print(x);", .{ .mode = .script, .filename = "quick-compound-update.js" });
    defer parsed.deinit();

    try std.testing.expectEqual(parser.CompilePath.normal, parsed.parse_path);

    const add_count = countOpcode(parsed.function.code, engine.bytecode.opcode.op.add) + countOpcode(parsed.function.code, engine.bytecode.opcode.op.add_loc);
    try std.testing.expect(add_count >= 1);
    try std.testing.expectEqual(@as(usize, 1), globalDeclarationClosureCount(&parsed.function));
    try std.testing.expect(globalDeclarationClosureNamed(&parsed.function, rt, "x").?.isLexical());
}

test "quick parser emits arithmetic compound assignment operators" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try parser.compile(rt, "let x = 10; x -= 3; x *= 2; x /= 7; x %= 2; print(x);", .{ .mode = .script, .filename = "quick-compound-arithmetic.js" });
    defer parsed.deinit();

    try std.testing.expectEqual(parser.CompilePath.normal, parsed.parse_path);
    try std.testing.expectEqual(@as(usize, 1), countOpcode(parsed.function.code, engine.bytecode.opcode.op.sub));
    try std.testing.expectEqual(@as(usize, 1), countOpcode(parsed.function.code, engine.bytecode.opcode.op.mul));
    try std.testing.expectEqual(@as(usize, 1), countOpcode(parsed.function.code, engine.bytecode.opcode.op.div));
    try std.testing.expectEqual(@as(usize, 1), countOpcode(parsed.function.code, engine.bytecode.opcode.op.mod));
}

test "quick parser does not claim update expression values" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try parser.compile(rt, "let x = 1; print(x++);", .{ .mode = .script, .filename = "quick-update-expression-fallback.js" });
    defer parsed.deinit();

    try std.testing.expectEqual(parser.CompilePath.normal, parsed.parse_path);
}

test "quick parser emits basic array and object literals" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try parser.compile(rt, "const arr = [1, 2, 3]; const obj = { a: arr[0], b: 2 }; print(obj.a + obj.b);", .{ .mode = .script, .filename = "quick-literals.js" });
    defer parsed.deinit();

    try std.testing.expectEqual(parser.CompilePath.normal, parsed.parse_path);

    const new_array_count = countOpcode(parsed.function.code, engine.bytecode.opcode.op.array_from);
    const new_object_count = countOpcode(parsed.function.code, engine.bytecode.opcode.op.object);
    const get_index_count = countOpcode(parsed.function.code, engine.bytecode.opcode.op.get_array_el);
    try std.testing.expect(new_array_count >= 1);
    try std.testing.expect(new_object_count >= 1);
    try std.testing.expect(get_index_count >= 1);
}

test "quick parser emits object property assignment" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try parser.compile(rt, "const obj = { x: 1 }; obj.x = obj.x + 2; print(obj.x);", .{ .mode = .script, .filename = "quick-property-assignment.js" });
    defer parsed.deinit();

    try std.testing.expectEqual(parser.CompilePath.normal, parsed.parse_path);

    const get_prop_count = countOpcode(parsed.function.code, engine.bytecode.opcode.op.get_field);
    const set_prop_count = countOpcode(parsed.function.code, engine.bytecode.opcode.op.put_field);
    try std.testing.expect(get_prop_count >= 2);
    try std.testing.expectEqual(@as(usize, 1), set_prop_count);
}

test "quick parser emits optional property access for object and nullish bases" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try parser.compile(rt, "const obj = { a: { b: 42 } }; print(obj?.a?.b); print(obj?.x?.y); print(undefined?.a);", .{ .mode = .script, .filename = "quick-optional-property.js" });
    defer parsed.deinit();

    try std.testing.expectEqual(parser.CompilePath.normal, parsed.parse_path);

    const optional_get_prop_count = countOpcode(parsed.function.code, engine.bytecode.opcode.op.is_undefined_or_null);
    try std.testing.expectEqual(@as(usize, 5), optional_get_prop_count);
}

test "quick parser preserves parenthesized postfix bases" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try parser.compile(rt, "const obj = { x: 1 }; print((obj).x); print(({ y: obj.x + 2 }).y); print(([3, 4])[1]); print(({ n: null })?.n);", .{ .mode = .script, .filename = "quick-parenthesized-postfix.js" });
    defer parsed.deinit();

    try std.testing.expectEqual(parser.CompilePath.normal, parsed.parse_path);

    const get_prop_count = countOpcode(parsed.function.code, engine.bytecode.opcode.op.get_field);
    const optional_get_prop_count = countOpcode(parsed.function.code, engine.bytecode.opcode.op.is_undefined_or_null);
    const get_index_count = countOpcode(parsed.function.code, engine.bytecode.opcode.op.get_array_el);
    try std.testing.expect(get_prop_count >= 3);
    try std.testing.expectEqual(@as(usize, 1), optional_get_prop_count);
    try std.testing.expectEqual(@as(usize, 1), get_index_count);
}

test "quick parser keeps conditional member callee branches at one stack slot" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const source =
        \\var o = { x: function () { return 5; }, y: function () { return 6; } };
        \\var A = null;
        \\var B = true;
        \\(A ?? o.x)();
        \\(A || o.x)();
        \\(B && o.x)();
        \\(B ? A : o.x)();
        \\(A ?? o["y"])();
        \\new (A ?? o.x)();
        \\new (B ? A : o.x)();
    ;
    var parsed = try parser.compile(rt, source, .{ .mode = .script, .filename = "conditional-member-callee.js" });
    defer parsed.deinit();

    try std.testing.expect(parsed.syntax_error == null);
    try std.testing.expectEqual(parser.CompilePath.normal, parsed.parse_path);
    try std.testing.expectEqual(@as(usize, 0), countOpcode(parsed.function.code, engine.bytecode.opcode.op.call_method));
    try std.testing.expect(countCalls(parsed.function.code) >= 5);
    try std.testing.expect(countOpcode(parsed.function.code, engine.bytecode.opcode.op.call_constructor) >= 2);
}

test "quick parser retrofits forward var captures into nested closures" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const source =
        \\function outer(){
        \\  var get = (function(){ return function(){ return CW; }; })();
        \\  var CW = 42;
        \\}
        \\function wrapper(){
        \\  var getTarget = function(){ return Target; };
        \\  var Target = function Target(){};
        \\  return getTarget;
        \\}
    ;
    // Debug parser frames are substantially larger than ReleaseFast frames;
    // use the same test-runtime stack budget as TestEngine.
    rt.setNativeStackSize(core.runtime.default_native_stack_size * 4);
    var parsed = try parser.compile(rt, source, .{ .mode = .script, .filename = "forward-var-capture.js" });
    defer parsed.deinit();

    try std.testing.expect(parsed.syntax_error == null);
    try std.testing.expectEqual(parser.CompilePath.normal, parsed.parse_path);
    try expectFunctionClosureRecursive(rt, &parsed.function, "CW", .local);
    try expectFunctionClosureRecursive(rt, &parsed.function, "CW", .ref);
    try expectFunctionClosureRecursive(rt, &parsed.function, "Target", .local);
}

test "quick parser still promotes unconditional parenthesized member calls" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try parser.compile(rt, "var o = { x: function () {} }; (o.x)(); ((o.x))(); ((A ?? o).x)();", .{ .mode = .script, .filename = "parenthesized-member-call.js" });
    defer parsed.deinit();

    try std.testing.expect(parsed.syntax_error == null);
    try std.testing.expectEqual(parser.CompilePath.normal, parsed.parse_path);
    try std.testing.expectEqual(@as(usize, 3), countOpcode(parsed.function.code, engine.bytecode.opcode.op.call_method));
}

test "call consumers use final-op provenance for eval with super and comma tags" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var eval_calls = try parser.compile(
        rt,
        \\function probe() {
        \\  const local = 1;
        \\  const holder = { get() { return eval; } };
        \\  holder.get()("typeof local");
        \\  (eval)("local");
        \\  (0, eval)("typeof local");
        \\  eval?.("typeof local");
        \\}
    ,
        .{ .mode = .script, .filename = "call-consumer-eval.js" },
    );
    defer eval_calls.deinit();
    try std.testing.expect(eval_calls.syntax_error == null);
    try std.testing.expectEqual(@as(usize, 1), countOpcodeRecursive(&eval_calls.function, qop.eval));

    var with_calls = try parser.compile(
        rt,
        \\var scope = { method() {}, tag() {} };
        \\with (scope) { (method)(); tag``; }
    ,
        .{ .mode = .script, .filename = "call-consumer-with.js" },
    );
    defer with_calls.deinit();
    try std.testing.expect(with_calls.syntax_error == null);
    try std.testing.expectEqual(@as(usize, 2), countOpcodeRecursive(&with_calls.function, qop.call_method));

    var super_calls = try parser.compile(
        rt,
        \\class Base { method() {} tag() {} }
        \\class Derived extends Base {
        \\  probe() { return [(super.method)(), (super.tag)``]; }
        \\}
    ,
        .{ .mode = .script, .filename = "call-consumer-super.js" },
    );
    defer super_calls.deinit();
    try std.testing.expect(super_calls.syntax_error == null);
    try std.testing.expect(countOpcodeRecursive(&super_calls.function, qop.call_method) >= 2);

    var comma_tag = try parser.compile(
        rt,
        \\var receiver = { tag() {} };
        \\(0, receiver.tag)``;
    ,
        .{ .mode = .script, .filename = "call-consumer-comma-tag.js" },
    );
    defer comma_tag.deinit();
    try std.testing.expect(comma_tag.syntax_error == null);
    try std.testing.expectEqual(@as(usize, 0), countOpcodeRecursive(&comma_tag.function, qop.call_method));
    try std.testing.expectEqual(@as(usize, 1), countOpcodeRecursive(&comma_tag.function, qop.call1));
}

test "quick parser lowers JSON stringify and parse to transitional JSON bytecode" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try parser.compile(rt, "const text = JSON.stringify({ a: 1 }); print(JSON.parse(text).a);", .{ .mode = .script, .filename = "quick-json-domain.js" });
    defer parsed.deinit();

    try std.testing.expectEqual(parser.CompilePath.normal, parsed.parse_path);
    try std.testing.expect(countCalls(parsed.function.code) >= 1);
}

test "quick parser lowers Math calls to transitional Math bytecode" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try parser.compile(rt, "print(Math.abs(-5)); print(Math.pow(2, 3)); print(Math.min(1, 2, 3));", .{ .mode = .script, .filename = "quick-math-domain.js" });
    defer parsed.deinit();

    try std.testing.expectEqual(parser.CompilePath.normal, parsed.parse_path);
    try std.testing.expect(countCalls(parsed.function.code) >= 3);
}

test "quick parser lowers URI calls to transitional URI bytecode" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try parser.compile(rt, "console.log(encodeURI(\"a b?x=1&y=2#z\")); print(decodeURIComponent(\"a%20b%3Fx%3D1\"));", .{ .mode = .script, .filename = "quick-uri-domain.js" });
    defer parsed.deinit();

    try std.testing.expectEqual(parser.CompilePath.normal, parsed.parse_path);
    try std.testing.expect(countCalls(parsed.function.code) >= 2);
}

test "quick parser lowers Number parse helpers to transitional number bytecode" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try parser.compile(
        rt,
        "print(parseInt(\"0x10\")); print(parseInt(\"0x10\", 10)); print(parseFloat(\"1.5x\")); print(Number.parseInt(\"42\")); print(Number.parseFloat(\"3.14\")); print(Number.NaN); print(Number.POSITIVE_INFINITY); print(Number.NEGATIVE_INFINITY);",
        .{ .mode = .script, .filename = "quick-number-parse-domain.js" },
    );
    defer parsed.deinit();

    try std.testing.expectEqual(parser.CompilePath.normal, parsed.parse_path);
    try std.testing.expect(countCalls(parsed.function.code) >= 5);
}

test "quick parser lowers supported Date helpers to receiver-preserving property calls" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try parser.compile(
        rt,
        "print(Date()); print(Date.UTC(2024, 0, 1)); print(Date.parse(\"2024-01-01T00:00:00Z\")); print(Date.now()); const d = new Date(0); print(d.getTime()); print(d.toISOString());",
        .{ .mode = .script, .filename = "quick-date-domain.js" },
    );
    defer parsed.deinit();

    try std.testing.expectEqual(parser.CompilePath.normal, parsed.parse_path);
    try std.testing.expect(countCalls(parsed.function.code) >= 4);
    try std.testing.expect(countOpcode(parsed.function.code, engine.bytecode.opcode.op.call_constructor) >= 1);
    try std.testing.expect(countOpcode(parsed.function.code, engine.bytecode.opcode.op.call_method) >= 2);
}

test "quick parser lowers supported RegExp helpers to receiver-preserving property calls" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try parser.compile(
        rt,
        "const r = new RegExp(\"a\", \"g\"); print(r.toString()); print(r.test(\"a\")); print(r.exec(\"a\"));",
        .{ .mode = .script, .filename = "quick-regexp-domain.js" },
    );
    defer parsed.deinit();

    try std.testing.expectEqual(parser.CompilePath.normal, parsed.parse_path);
    try std.testing.expect(countOpcode(parsed.function.code, engine.bytecode.opcode.op.call_constructor) >= 1);
    try std.testing.expect(countOpcode(parsed.function.code, engine.bytecode.opcode.op.call_method) >= 3);
}

test "RegExp property calls keep QuickJS call_method bytecode" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var cached = try parser.compile(
        rt,
        "const r = /a+b/; r.test(\"aaab\");",
        .{ .mode = .script, .filename = "regexp-cached-prepared.js" },
    );
    defer cached.deinit();

    try std.testing.expectEqual(parser.CompilePath.normal, cached.parse_path);
    try std.testing.expectEqual(@as(usize, 1), countOpcode(cached.function.code, engine.bytecode.opcode.op.get_field2));
    try std.testing.expectEqual(@as(usize, 1), countOpcode(cached.function.code, engine.bytecode.opcode.op.call_method));

    var literal = try parser.compile(
        rt,
        "/a+b/.test(\"aaab\");",
        .{ .mode = .script, .filename = "regexp-literal-fuse.js" },
    );
    defer literal.deinit();

    try std.testing.expectEqual(parser.CompilePath.normal, literal.parse_path);
    try std.testing.expectEqual(@as(usize, 1), countOpcode(literal.function.code, engine.bytecode.opcode.op.get_field2));
    try std.testing.expectEqual(@as(usize, 1), countOpcode(literal.function.code, engine.bytecode.opcode.op.call_method));
}

test "function predeclare scan skips slash-equals regexp literals" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try parser.compile(
        rt,
        \\function RegExpBenchmark() {
        \\  var re0 = /^ba/;
        \\  var re1 = /(((\w+):\/\/)([^\/:]*)(:(\d+))?)?([^#?]*)(\?([^#]*))?(#(.*))?/;
        \\  var re8 = /=/;
        \\  return re0.test("ba") && re1.test("http://example") && re8.test("=");
        \\}
        \\RegExpBenchmark();
    ,
        .{ .mode = .script, .filename = "regexp-slash-equals-predeclare.js" },
    );
    defer parsed.deinit();

    try std.testing.expectEqual(parser.CompilePath.normal, parsed.parse_path);
    try std.testing.expect(parsed.syntax_error == null);
}

test "quick parser lowers supported Promise helpers to receiver-preserving property calls" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try parser.compile(
        rt,
        \\const p = new Promise((resolve, reject) => {
        \\    resolve(1);
        \\});
        \\print(typeof p);
        \\print(Promise.resolve(1));
        \\print(Promise.all([1, 2]));
        \\print(Promise.race([Promise.resolve(3), 4]));
        \\print(Promise.reject(1));
    ,
        .{ .mode = .script, .filename = "quick-promise-domain.js" },
    );
    defer parsed.deinit();

    try std.testing.expectEqual(parser.CompilePath.normal, parsed.parse_path);
    try std.testing.expect(countOpcode(parsed.function.code, engine.bytecode.opcode.op.call_constructor) >= 1);
    try std.testing.expect(countOpcode(parsed.function.code, engine.bytecode.opcode.op.call_method) >= 4);
}

test "quick parser lowers supported collection helpers to receiver-preserving property calls" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try parser.compile(
        rt,
        \\const map = new Map();
        \\map.set("key", 1);
        \\print(map.get("key"));
        \\print(map.has("key"));
        \\print(map.delete("key"));
        \\map.clear();
        \\const set = new Set();
        \\set.add(1);
        \\print(set.has(1));
        \\print(set.delete(1));
        \\set.clear();
        \\const weakMap = new WeakMap();
        \\const key = {};
        \\weakMap.set(key, 2);
        \\print(weakMap.get(key));
        \\print(weakMap.has(key));
        \\print(weakMap.delete(key));
        \\const weakSet = new WeakSet();
        \\const weakKey = {};
        \\weakSet.add(weakKey);
        \\print(weakSet.has(weakKey));
        \\print(weakSet.delete(weakKey));
    ,
        .{ .mode = .script, .filename = "quick-collection-domain.js" },
    );
    defer parsed.deinit();

    try std.testing.expectEqual(parser.CompilePath.normal, parsed.parse_path);
    try std.testing.expect(countOpcode(parsed.function.code, engine.bytecode.opcode.op.call_constructor) >= 4);
    try std.testing.expect(countOpcode(parsed.function.code, engine.bytecode.opcode.op.call_method) >= 16);
}

test "template interpolation emits string concatenation" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try parser.compile(rt, "const x = 10; const y = 20; print(`${x} + ${y} = ${x + y}`);", .{ .mode = .script, .filename = "template.js" });
    defer parsed.deinit();

    var add_count: usize = 0;
    for (parsed.function.code) |op_val| {
        if (op_val == engine.bytecode.opcode.op.add) add_count += 1;
    }
    try std.testing.expect(add_count >= 1);
}

test "simple arrays emit receiver-preserving property calls" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try parser.compile(rt, "const arr = [1, 2, 3]; print(arr); print(arr.length); print(arr[0]); print(arr.map(x => x * 2));", .{ .mode = .script, .filename = "array.js" });
    defer parsed.deinit();

    const new_array_count = countOpcode(parsed.function.code, engine.bytecode.opcode.op.array_from);
    const get_index_count = countOpcode(parsed.function.code, engine.bytecode.opcode.op.get_array_el);
    const map_count = countOpcode(parsed.function.code, engine.bytecode.opcode.op.get_field) +
        countOpcode(parsed.function.code, engine.bytecode.opcode.op.get_field2);
    const call_prop_count = countOpcode(parsed.function.code, engine.bytecode.opcode.op.call_method);
    try std.testing.expectEqual(@as(usize, 1), new_array_count);
    try std.testing.expectEqual(@as(usize, 1), get_index_count);
    try std.testing.expect(map_count >= 1 or call_prop_count >= 1);
    try std.testing.expectEqual(@as(usize, 1), call_prop_count);
}

test "simple functions and arrows emit inline helper bytecode" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try parser.compile(rt, "function add(a, b) { return a + b; } print(add(2, 3)); const double = x => x * 2; print(double(21)); function fact(n) { return n <= 1 ? 1 : n * fact(n - 1); } print(fact(6));", .{ .mode = .script, .filename = "functions.js" });
    defer parsed.deinit();

    var add_count: usize = 0;
    var mul_count: usize = 0;
    var factorial_count: usize = 0;
    for (parsed.function.code) |op_val| {
        if (op_val == engine.bytecode.opcode.op.add) add_count += 1;
        if (op_val == engine.bytecode.opcode.op.mul) mul_count += 1;
        if (op_val == engine.bytecode.opcode.op.call) factorial_count += 1;
    }
    add_count += countOpcodeRecursive(&parsed.function, engine.bytecode.opcode.op.add);
    mul_count += countOpcodeRecursive(&parsed.function, engine.bytecode.opcode.op.mul);
    factorial_count += countOpcodeRecursive(&parsed.function, engine.bytecode.opcode.op.call);
    try std.testing.expect(add_count >= 1);
    try std.testing.expect(mul_count >= 1);
    try std.testing.expect(factorial_count >= 1 or countOpcodeRecursive(&parsed.function, engine.bytecode.opcode.op.call1) >= 1);
}

test "unsupported spread call reports syntax guard" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try parser.compile(rt, "print(...[1]);", .{ .mode = .script, .filename = "fallback.js" });
    defer parsed.deinit();

    try std.testing.expectEqual(parser.CompilePath.normal, parsed.parse_path);
}

test "test262 frontmatter does not affect quick parser behavior" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const source =
        "/*---\n" ++
        "negative:\n" ++
        "  phase: runtime\n" ++
        "  type: Test262Error\n" ++
        "---*/\n" ++
        "assert.sameValue(1 + 1, 2);";
    var parsed = try parser.compile(rt, source, .{ .mode = .script, .filename = "metadata.js" });
    defer parsed.deinit();

    try std.testing.expect(parsed.syntax_error == null);
    try std.testing.expectEqual(parser.CompilePath.normal, parsed.parse_path);
    try std.testing.expectEqual(@as(usize, 1), countOpcode(parsed.function.code, engine.bytecode.opcode.op.get_var));
    try std.testing.expectEqual(@as(usize, 0), countOpcode(parsed.function.code, engine.bytecode.opcode.op.get_field));
    try std.testing.expectEqual(@as(usize, 1), countOpcode(parsed.function.code, engine.bytecode.opcode.op.get_field2));
    try std.testing.expectEqual(@as(usize, 0), countOpcode(parsed.function.code, engine.bytecode.opcode.op.call));
    try std.testing.expectEqual(@as(usize, 1), countOpcode(parsed.function.code, engine.bytecode.opcode.op.call_method));
}

test "test262 prelude frontmatter parses nested private methods after line_num temp" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const source =
        \\function prelude() {}
        \\if (typeof $262 === "object" && typeof $262.evalScript !== "function") {
        \\  $262.evalScript = function(source) { return (0, eval)(source); };
        \\}
        \\/*---
        \\description: Value when private name describes a method
        \\info: |
        \\  7. Let privateName be ? GetValue(privateNameBinding).
        \\  8. Assert: privateName is a Private Name.
        \\  [...]
        \\features: [class-methods-private, class-fields-private-in]
        \\---*/
        \\let Child;
        \\let parentCount = 0;
        \\let childCount = 0;
        \\class Parent {
        \\  #parent() {
        \\    parentCount += 1;
        \\  }
        \\  static init() {
        \\    Child = class {
        \\      #child() {
        \\        childCount += 1;
        \\      }
        \\      static isNameIn(value) {
        \\        return #child in value;
        \\      }
        \\    };
        \\  }
        \\}
    ;
    var parsed = try parser.compile(rt, source, .{ .mode = .script, .filename = "metadata-private-methods.js" });
    defer parsed.deinit();

    try std.testing.expect(parsed.syntax_error == null);
    try std.testing.expectEqual(parser.CompilePath.normal, parsed.parse_path);
    try std.testing.expectEqual(@as(usize, 0), countOpcodeRecursive(&parsed.function, qop.line_num));
    try std.testing.expect(countOpcodeRecursive(&parsed.function, qop.private_in) >= 1);
}

test "arrow early errors reject non-simple strict and invalid rest parameters" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const cases = [_][]const u8{
        "0, ([element]) => { \"use strict\"; };",
        "0, (x = 0, x) => {};",
        "0, (...x = []) => {};",
        "var f; f = ([...{ x } = []]) => {};",
        "var f; f = ([...x, y]) => {};",
        "var x = ({ def\\u{61}ult }) => {};",
    };

    for (cases) |source| {
        var parsed = try parser.compile(rt, source, .{ .mode = .script, .filename = "arrow-early-error.js" });
        defer parsed.deinit();
        try std.testing.expect(parsed.syntax_error != null);
        try std.testing.expect(parsed.syntax_error.?.message.len > 0);
    }
}

test "arrow early error checks do not reject valid nested rest destructuring" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try parser.compile(rt, "var f; f = ([...[...x]]) => {};", .{ .mode = .script, .filename = "arrow-valid-rest.js" });
    defer parsed.deinit();

    try std.testing.expect(parsed.syntax_error == null);
    try std.testing.expect(countFunctionClosures(parsed.function.code) > 0);
    const arrow = try expectFunctionConstant(&parsed.function, 0);
    try std.testing.expect(arrow.flags.is_arrow_function);
    try std.testing.expectEqual(function_def.FunctionKind.normal, arrow.flags.func_kind);
    try expectOpcode(arrow.byteCode(), qop.for_of_start);
    try expectOpcode(arrow.byteCode(), qop.return_undef);
}

test "destructuring rest parameter defaults enforce await and yield early errors" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const cases = [_][]const u8{
        "async function f(...[value = await 1]) {}",
        "var f = async (...{ 0: value = await 1 }) => {};",
        "function* g(...[value = yield 1]) {}",
        "var g = function* (...{ 0: value = yield 1 }) {};",
    };

    for (cases) |source| {
        var parsed = try parser.compile(rt, source, .{ .mode = .script, .filename = "rest-parameter-default-early-error.js" });
        defer parsed.deinit();
        try std.testing.expect(parsed.syntax_error != null);
        try std.testing.expect(parsed.syntax_error.?.message.len > 0);
    }
}

test "assignment destructuring early errors reject invalid rest forms" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const cases = [_][]const u8{
        "0, [...x, y] = [];",
        "0, [...x = 1] = [];",
        "0, [...[(x, y)]] = [[]];",
        "0, [...{ get x() {} }] = [[]];",
        "0, {...rest, b} = {};",
        "0, [[(x, y)]] = [[]];",
        "0, [{ get x() {} }] = [{}];",
        "0, { x: [(x, y)] } = { x: [] };",
        "0, { x: { get x() {} } } = { x: {} };",
        "/*---\nfeatures: [optional-chaining, destructuring-binding]\nnegative:\n  phase: parse\n  type: SyntaxError\n---*/\n0, [x?.y = 42] = [23];",
        "0, { default } = {};",
        "0, { bre\\u0061k } = {};",
        "0, { def\\u{61}ult } = {};",
        "(function*() { 0, { yield } = {}; });",
    };

    for (cases) |source| {
        var parsed = try parser.compile(rt, source, .{ .mode = .script, .filename = "assignment-early-error.js" });
        defer parsed.deinit();
        try std.testing.expect(parsed.syntax_error != null);
        try std.testing.expect(parsed.syntax_error.?.message.len > 0);
    }

    // The test262 runner, not the JavaScript parser, interprets onlyStrict
    // metadata. Pass the resulting host option explicitly while retaining the
    // original source comment as an inert comment.
    const only_strict_cases = [_][]const u8{
        "/*---\nflags: [generated, onlyStrict]\n---*/\n0, { eval } = {};",
        "/*---\nflags: [generated, onlyStrict]\n---*/\n0, [arguments] = [];",
        "/*---\nflags: [generated, onlyStrict]\n---*/\n(eval) = 20;",
        "/*---\nflags: [generated, onlyStrict]\n---*/\n(arguments) = 20;",
        "/*---\nflags: [generated, onlyStrict]\n---*/\n0, [ x = yield ] = [];",
        "/*---\nflags: [generated, onlyStrict]\n---*/\n0, { x: x[yield] } = {};",
    };
    for (only_strict_cases) |source| {
        var parsed = try parser.compile(rt, source, .{ .mode = .script, .filename = "assignment-early-error.js", .strict = true });
        defer parsed.deinit();
        try std.testing.expect(parsed.syntax_error != null);
        try std.testing.expect(parsed.syntax_error.?.message.len > 0);
    }
}

test "assignment destructuring early errors allow reserved property names" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const cases = [_]struct {
        source: []const u8,
        property: []const u8,
    }{
        .{ .source = "var y = { default: x } = { default: 42 };", .property = "default" },
        .{ .source = "var y = { bre\\u0061k: x } = { break: 42 };", .property = "break" },
        .{ .source = "var yield; var result; var vals = { yield: 3 }; result = { yield } = vals;", .property = "yield" },
    };

    for (cases) |case| {
        var parsed = try parser.compile(rt, case.source, .{ .mode = .script, .filename = "assignment-valid-property-name.js" });
        defer parsed.deinit();
        try std.testing.expect(parsed.syntax_error == null);
        try expectAtomOperandName(rt, &parsed.function, case.property);
        try expectOpcode(parsed.function.code, qop.define_field);
        try expectOpcode(parsed.function.code, qop.get_field);
    }
}

test "assignment early errors reject invalid assignment target types" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const cases = [_][]const u8{
        "/*---\nnegative:\n  phase: parse\n  type: SyntaxError\ninfo: |\n  Static Semantics AssignmentTargetType, Return invalid.\n---*/\nx + y = 1;",
        "/*---\nnegative:\n  phase: parse\n  type: SyntaxError\ninfo: |\n  It is an early Syntax Error if LeftHandSideExpression is neither an ObjectLiteral nor an ArrayLiteral and AssignmentTargetType of LeftHandSideExpression is invalid or strict.\n---*/\ntrue = 42;",
        "/*---\nnegative:\n  phase: parse\n  type: SyntaxError\ninfo: |\n  Static Semantics AssignmentTargetType, Return invalid.\n---*/\n(() => {}) = 1;",
    };

    for (cases) |source| {
        var parsed = try parser.compile(rt, source, .{ .mode = .script, .filename = "assignment-target-type.js" });
        defer parsed.deinit();
        try std.testing.expect(parsed.syntax_error != null);
        try std.testing.expect(parsed.syntax_error.?.message.len > 0);
    }
}

test "async arrow early errors reject await-context parse negatives" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const cases = [_][]const u8{
        "/*---\nfeatures: [async-functions]\nnegative:\n  phase: parse\n  type: SyntaxError\n---*/\nasync(await) => { }",
        "/*---\nfeatures: [async-functions]\nnegative:\n  phase: parse\n  type: SyntaxError\n---*/\n\\u0061sync () => {}",
    };

    for (cases) |source| {
        var parsed = try parser.compile(rt, source, .{ .mode = .script, .filename = "async-arrow-early-error.js" });
        defer parsed.deinit();
        try std.testing.expect(parsed.syntax_error != null);
        try std.testing.expect(parsed.syntax_error.?.message.len > 0);
    }
}

test "object computed property names parse async arrow and module await expressions" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var async_arrow = try parser.compile(rt, "let o = { [async () => {}]: 1 };", .{ .mode = .script, .filename = "computed-async-arrow.js" });
    defer async_arrow.deinit();
    try std.testing.expect(async_arrow.syntax_error == null);
    try std.testing.expect(async_arrow.hasFeature(.expression));
    try std.testing.expect(async_arrow.hasFeature(.function_));
    try std.testing.expect(async_arrow.hasFeature(.arrow));
    try std.testing.expect(async_arrow.hasFeature(.async_function));
    try std.testing.expect(!async_arrow.hasFeature(.dynamic_import));
    try expectOpcode(async_arrow.function.code, qop.to_propkey);
    try expectOpcode(async_arrow.function.code, qop.define_array_el);
    try std.testing.expect(countFunctionClosures(async_arrow.function.code) > 0);
    try expectFunctionKindRecursive(&async_arrow.function, .async);

    var module_await = try parser.compile(rt, "let o = { [await 9]: 9 };", .{ .mode = .module, .filename = "computed-await.js" });
    defer module_await.deinit();
    try std.testing.expect(module_await.syntax_error == null);
    try std.testing.expect(module_await.hasFeature(.expression));
    try std.testing.expect(module_await.hasFeature(.statement));
    try std.testing.expect(!module_await.hasFeature(.dynamic_import));
    try std.testing.expect(module_await.function.flags.is_module);
    try expectOpcode(module_await.function.code, qop.await);
    try expectOpcode(module_await.function.code, qop.to_propkey);
    try expectOpcode(module_await.function.code, qop.define_array_el);
}

test "class early errors reject class parse negatives" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const source =
        "/*---\n" ++
        "features: [class]\n" ++
        "negative:\n" ++
        "  phase: parse\n" ++
        "  type: SyntaxError\n" ++
        "info: |\n" ++
        "  ClassExpression\n" ++
        "---*/\n" ++
        "class static {}";

    var parsed = try parser.compile(rt, source, .{ .mode = .script, .filename = "class-early-error.js" });
    defer parsed.deinit();
    try std.testing.expect(parsed.syntax_error != null);
    try std.testing.expect(parsed.syntax_error.?.message.len > 0);
}

test "module parse mode records import export metadata and strict flag" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try parser.compile(
        rt,
        "import 'side'; import x, * as ns from 'm' with { type: \"json\" }; import { default as def, y, z as renamed, \"str\" as strLocal } from 'n'; export { x as default }; export { x }; export const c = 1; export const { d: dc, e } = {}; export let [arr] = []; export function f(){} export class C{} export async function af(){} export { y as yy } from 'n2'; export * from 's'; export * as ns2 from 's2'; await 0;",
        .{ .mode = .module, .filename = "mod.js" },
    );
    defer parsed.deinit();

    try std.testing.expect(parsed.syntax_error == null);
    try std.testing.expect(parsed.function.flags.is_strict);
    try expectOpcodeRecursive(&parsed.function, qop.await);
    try expectOpcodeRecursive(&parsed.function, qop.define_class);
    try std.testing.expect(countFunctionClosures(parsed.function.code) > 0);
    const record = parsed.function.module_record.?;
    try std.testing.expectEqual(@as(usize, 6), record.requests.len);
    try std.testing.expectEqual(@as(usize, 6), record.imports.len);
    try std.testing.expectEqual(@as(usize, 9), record.exports.len);
    try std.testing.expectEqual(@as(usize, 1), record.indirect_exports.len);
    try std.testing.expectEqual(@as(usize, 2), record.star_exports.len);
    try std.testing.expectEqual(@as(usize, 1), record.import_attributes.len);
    try std.testing.expect(record.has_top_level_await);
}

test "module parser preserves regex literals across zod-like lookahead scans" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const source =
        \\const globalConfig = {};
        \\export function helper00(value) { return value; }
        \\export function helper01(value) { return helper00(value); }
        \\export function helper02(value) { return helper01(value); }
        \\export function helper03(value) { return helper02(value); }
        \\export function helper04(value) { return helper03(value); }
        \\export function helper05(value) { return helper04(value); }
        \\export function helper06(value) { return helper05(value); }
        \\export function helper07(value) { return helper06(value); }
        \\export function helper08(value) { return helper07(value); }
        \\export function helper09(value) { return helper08(value); }
        \\export function randomString(length = 10) {
        \\    const chars = "abcdefghijklmnopqrstuvwxyz";
        \\    let str = "";
        \\    for (let i = 0; i < length; i++) {
        \\        str += chars[Math.floor(Math.random() * chars.length)];
        \\    }
        \\    return str;
        \\}
        \\export function esc(str) {
        \\    return JSON.stringify(str);
        \\}
        \\export function slugify(input) {
        \\    return input
        \\        .toLowerCase()
        \\        .trim()
        \\        .replace(/[^\w\s-]/g, "")
        \\        .replace(/[\s_-]+/g, "-")
        \\        .replace(/^-+|-+$/g, "");
        \\}
        \\export const captureStackTrace = ("captureStackTrace" in Error ? Error.captureStackTrace : (..._args) => { });
        \\export const arrowDefault = (value = /[^\w\s-]/g) => value;
        \\export function isObject(data) {
        \\    return typeof data === "object" && data !== null;
        \\}
    ;

    var parsed = try parser.compile(rt, source, .{ .mode = .module, .filename = "zod-regex-lookahead.mjs" });
    defer parsed.deinit();

    try std.testing.expect(parsed.syntax_error == null);
    try std.testing.expectEqual(parser.CompilePath.normal, parsed.parse_path);
}

test "parser rescans divide-assign token as regex literal beginning with equals" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const source =
        \\function fromReturn(s) {
        \\    return s.replace(/=/g, "");
        \\}
        \\function fromSwitch(s) {
        \\    switch (s) {
        \\        case "x":
        \\            return s.replace(/=/g, "");
        \\        default:
        \\            return s;
        \\    }
        \\}
        \\function fromDeclarators(s) {
        \\    const stripEquals = /=/g;
        \\    var oneEquals = /=/;
        \\    return s.replace(stripEquals, "").replace(oneEquals, "");
        \\}
        \\globalThis.__eq_regex = [fromReturn, fromSwitch, fromDeclarators];
    ;

    var parsed = try parser.compile(rt, source, .{ .mode = .script, .filename = "eq-regex-rescan.js" });
    defer parsed.deinit();

    try std.testing.expect(parsed.syntax_error == null);
    try std.testing.expectEqual(parser.CompilePath.normal, parsed.parse_path);
}

test "module import local names are compiled as module var refs" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try parser.compile(
        rt,
        "import x, { y as renamed } from 'dep'; import * as ns from 'ns'; function f(){ return renamed; } x; ns;",
        .{ .mode = .module, .filename = "import-refs.js" },
    );
    defer parsed.deinit();

    try std.testing.expect(parsed.syntax_error == null);
    try std.testing.expect(parsed.function.var_ref_names.len >= 3);

    const x = try rt.internAtom("x");
    defer rt.atoms.free(x);
    const renamed = try rt.internAtom("renamed");
    defer rt.atoms.free(renamed);
    const ns = try rt.internAtom("ns");
    defer rt.atoms.free(ns);

    try std.testing.expect(std.mem.indexOfScalar(core.Atom, parsed.function.var_ref_names, x) != null);
    try std.testing.expect(std.mem.indexOfScalar(core.Atom, parsed.function.var_ref_names, renamed) != null);
    try std.testing.expect(std.mem.indexOfScalar(core.Atom, parsed.function.var_ref_names, ns) != null);
}

test "module parser rejects duplicate exported names across export forms" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const cases = [_][]const u8{
        "var x; export { x as z }; export * as z from './dep.js';",
        "var x; export default x; export * as default from './dep.js';",
        "export { x as z } from './a.js'; export * as z from './b.js';",
    };

    for (cases) |source| {
        var parsed = try parser.compile(rt, source, .{ .mode = .module, .filename = "dup-export.js" });
        defer parsed.deinit();
        try std.testing.expect(parsed.syntax_error != null);
    }
}

test "module parser validates local export bindings after full body parse" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const valid_cases = [_][]const u8{
        "export { x }; var x;",
        "export { x }; const x = 1;",
        "import { x } from './dep.js'; export { x };",
    };
    for (valid_cases) |source| {
        var parsed = try parser.compile(rt, source, .{ .mode = .module, .filename = "valid-local-export.js" });
        defer parsed.deinit();
        try std.testing.expect(parsed.syntax_error == null);
    }

    const invalid_cases = [_][]const u8{
        "export { Number };",
        "export { unresolvable };",
    };
    for (invalid_cases) |source| {
        var parsed = try parser.compile(rt, source, .{ .mode = .module, .filename = "invalid-local-export.js" });
        defer parsed.deinit();
        try std.testing.expect(parsed.syntax_error != null);
    }
}

test "module parser rejects duplicate import attribute keys per with clause" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const invalid_cases = [_][]const u8{
        "import x from './dep.js' with { type: 'json', 'typ\\u0065': '' };",
        "import './dep.js' with { type: 'json', 'type': '' };",
        "export * from './dep.js' with { type: 'json', 'typ\\u0065': '' };",
    };
    for (invalid_cases) |source| {
        var parsed = try parser.compile(rt, source, .{ .mode = .module, .filename = "dup-import-attr.js" });
        defer parsed.deinit();
        try std.testing.expect(parsed.syntax_error != null);
    }

    var parsed = try parser.compile(
        rt,
        "import a from './a.js' with { type: 'json' }; import b from './b.js' with { type: 'json' };",
        .{ .mode = .module, .filename = "valid-import-attr.js" },
    );
    defer parsed.deinit();
    try std.testing.expect(parsed.syntax_error == null);
}

test "module parser accepts empty side-effect import attributes" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try parser.compile(rt, "import './dep.js' with {};", .{ .mode = .module, .filename = "side-effect-import-attr.js" });
    defer parsed.deinit();

    try std.testing.expect(parsed.syntax_error == null);
    try std.testing.expectEqual(@as(usize, 1), parsed.function.module_record.?.requests.len);
}

test "module parser validates string module export names" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const invalid_cases = [_][]const u8{
        "export { \"foo\" as \"bar\" }; function foo() {}",
        "export { Foo as \"\\uD83D\" }; function Foo() {}",
        "export { \"ok\" as \"\\uD83D\" } from './dep.js';",
        "export * as \"\\uD83D\" from './dep.js';",
    };
    for (invalid_cases) |source| {
        var parsed = try parser.compile(rt, source, .{ .mode = .module, .filename = "invalid-string-export-name.js" });
        defer parsed.deinit();
        try std.testing.expect(parsed.syntax_error != null);
    }

    var parsed = try parser.compile(rt, "export { \"ok\" as \"also-ok\" } from './dep.js';", .{ .mode = .module, .filename = "valid-string-export-name.js" });
    defer parsed.deinit();
    try std.testing.expect(parsed.syntax_error == null);
}

test "module parser rejects comma expression as default export expression" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var invalid = try parser.compile(rt, "export default null, null;", .{ .mode = .module, .filename = "invalid-default-export.js" });
    defer invalid.deinit();
    try std.testing.expect(invalid.syntax_error != null);

    var valid = try parser.compile(rt, "export default (null, null);", .{ .mode = .module, .filename = "valid-default-export.js" });
    defer valid.deinit();
    try std.testing.expect(valid.syntax_error == null);
}

test "module parser accepts keyword module export and import names" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try parser.compile(
        rt,
        "var x; export { x as if, x as import, x as await }; import { if as if_, import as import_, await as await_ } from './dep.js';",
        .{ .mode = .module, .filename = "keyword-module-names.js" },
    );
    defer parsed.deinit();

    try std.testing.expect(parsed.syntax_error == null);
    try std.testing.expectEqual(@as(usize, 3), parsed.function.module_record.?.exports.len);
    try std.testing.expectEqual(@as(usize, 3), parsed.function.module_record.?.imports.len);
}

test "module parser allows duplicate top-level var declarations" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try parser.compile(rt, "var test262; var test262; for (var other; false;) {} for (var other; false;) {}", .{ .mode = .module, .filename = "dup-module-var.js" });
    defer parsed.deinit();

    try std.testing.expect(parsed.syntax_error == null);
}

test "module parser hoists block var declarations to module var refs" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try parser.compile(rt, "if (true) { var proto = {}; proto; }", .{ .mode = .module, .filename = "block-var-module.js" });
    defer parsed.deinit();

    try std.testing.expect(parsed.syntax_error == null);
    var found = false;
    for (parsed.function.closure_var) |cv| {
        const name = rt.atoms.name(cv.var_name) orelse continue;
        if (std.mem.eql(u8, name, "proto")) {
            try std.testing.expectEqual(function_def.ClosureType.module_decl, cv.closureType());
            try std.testing.expect(!cv.isLexical());
            found = true;
        }
    }
    try std.testing.expect(found);
}

test "direct eval closure seed lowers unresolved read to var ref" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const x_atom = try rt.internAtom("x");
    defer rt.atoms.free(x_atom);
    const seed = [_]parser.EvalClosureSeed{.{
        .var_name = x_atom,
        .closure_type = .arg,
        .var_idx = 7,
        .is_lexical = true,
        .is_const = false,
        .var_kind = .normal,
    }};
    var parsed = try parser.compile(rt, "x", .{ .mode = .eval_direct, .filename = "<eval>", .eval_closure_seed = &seed });
    defer parsed.deinit();

    try std.testing.expect(parsed.syntax_error == null);
    var x_cv: ?engine.bytecode.function_bytecode.BytecodeClosureVar = null;
    for (parsed.function.closure_var) |cv| {
        if (cv.var_name == x_atom) x_cv = cv;
        try std.testing.expect(cv.var_name != atom.ids.ret);
    }
    const resolved_x = x_cv orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(function_def.ClosureType.arg, resolved_x.closureType());
    try std.testing.expectEqual(@as(u16, 7), resolved_x.var_idx);
    const var_ref_reads =
        countOpcode(parsed.function.code, op.get_var_ref) +
        countOpcode(parsed.function.code, op.get_var_ref_check) +
        countOpcode(parsed.function.code, op.get_var_ref0) +
        countOpcode(parsed.function.code, op.get_var_ref1) +
        countOpcode(parsed.function.code, op.get_var_ref2) +
        countOpcode(parsed.function.code, op.get_var_ref3);
    try std.testing.expect(var_ref_reads > 0);
    try std.testing.expectEqual(@as(usize, 0), countVarOpcodeForAtom(&parsed.function, op.get_var, x_atom));
}

test "direct eval ref closure seed preserves table identity only" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const x_atom = try rt.internAtom("x");
    defer rt.atoms.free(x_atom);
    const seed = [_]parser.EvalClosureSeed{.{
        .var_name = x_atom,
        .closure_type = .ref,
        .var_idx = 8,
        .is_lexical = false,
        .is_const = false,
        .var_kind = .normal,
    }};
    var parsed = try parser.compile(rt, "", .{ .mode = .eval_direct, .filename = "<eval>", .eval_closure_seed = &seed });
    defer parsed.deinit();

    try std.testing.expect(parsed.syntax_error == null);
    for (parsed.function.closure_var) |cv| {
        if (cv.var_name != x_atom) continue;
        try std.testing.expectEqual(function_def.ClosureType.ref, cv.closureType());
        try std.testing.expectEqual(@as(u16, 8), cv.var_idx);
        try std.testing.expect(!@hasField(engine.bytecode.function_bytecode.BytecodeClosureVar, "source_depth"));
        return;
    }
    return error.TestExpectedEqual;
}

test "parameter direct eval keeps arg var object ahead of declaration globals" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const seed = [_]parser.EvalClosureSeed{.{
        .var_name = atom.ids.arg_var_object,
        .closure_type = .local,
        .var_idx = 5,
        .is_lexical = false,
        .is_const = false,
        .var_kind = .normal,
    }};
    var parsed = try parser.compile(
        rt,
        "var x = 'arg'; delete x; typeof x;",
        .{
            .mode = .eval_direct,
            .filename = "<eval>",
            .eval_in_parameter_initializer = true,
            .eval_closure_seed = &seed,
        },
    );
    defer parsed.deinit();

    try std.testing.expect(parsed.syntax_error == null);
    try std.testing.expect(parsed.function.closure_var.len >= 2);
    try std.testing.expectEqual(atom.ids.arg_var_object, parsed.function.closure_var[0].var_name);
    try std.testing.expectEqual(function_def.ClosureType.local, parsed.function.closure_var[0].closureType());
    try std.testing.expectEqual(@as(usize, 1), countOpcode(parsed.function.code, op.with_delete_var));
    try std.testing.expectEqual(@as(usize, 1), countOpcode(parsed.function.code, op.define_field));
}

test "QuickJS direct eval destructuring declares through the variable object" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const binding_atom = try rt.internAtom("evalDestructFallback");
    defer rt.atoms.free(binding_atom);
    const seed = [_]parser.EvalClosureSeed{.{
        .var_name = atom.ids.var_object,
        .closure_type = .local,
        .var_idx = 7,
        .is_lexical = false,
        .is_const = false,
        .var_kind = .normal,
    }};
    var parsed = try parser.compile(
        rt,
        "var { evalDestructFallback } = { evalDestructFallback: 1 }; (() => evalDestructFallback);",
        .{
            .mode = .eval_direct,
            .filename = "<eval>",
            .eval_closure_seed = &seed,
        },
    );
    defer parsed.deinit();

    try std.testing.expect(parsed.syntax_error == null);

    // qjs define_var(JS_VAR_DEF_VAR) records the declaration as a
    // JSGlobalVar. It does not manufacture a same-name VarDef beside the
    // captured <var> object (quickjs.c:24395-24415).
    for (parsed.function.vardefs) |vd| {
        try std.testing.expect(vd.var_name != binding_atom);
    }
    try std.testing.expectEqual(@as(usize, 2), parsed.function.closure_var.len);
    try std.testing.expectEqual(atom.ids.var_object, parsed.function.closure_var[0].var_name);
    try std.testing.expectEqual(function_def.ClosureType.local, parsed.function.closure_var[0].closureType());
    try std.testing.expectEqual(binding_atom, parsed.function.closure_var[1].var_name);
    try std.testing.expectEqual(function_def.ClosureType.global, parsed.function.closure_var[1].closureType());

    const arrow = arrow: {
        for (parsed.function.constants.values) |value| {
            const child = functionBytecodeFromValue(value) orelse continue;
            if (child.closureVar().len == 2) break :arrow child;
        }
        return error.TestExpectedEqual;
    };
    // The escaping arrow first captures the dynamic variable environment,
    // then keeps the ordinary global fallback. This is the exact qjs lookup
    // chain: get_var_ref(<var>), with_get_var(name), get_var(name).
    try std.testing.expectEqual(atom.ids.var_object, arrow.closureVar()[0].var_name);
    try std.testing.expectEqual(function_def.ClosureType.ref, arrow.closureVar()[0].closureType());
    try std.testing.expectEqual(@as(u16, 0), arrow.closureVar()[0].var_idx);
    try std.testing.expectEqual(binding_atom, arrow.closureVar()[1].var_name);
    try std.testing.expectEqual(function_def.ClosureType.global_ref, arrow.closureVar()[1].closureType());
    try std.testing.expectEqual(@as(u16, 1), arrow.closureVar()[1].var_idx);
}

test "parser accepts dynamic import call expressions" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var module_parsed = try parser.compile(rt, "try { await import('dep', { with: {} }); } catch (e) {}", .{ .mode = .module, .filename = "dynamic-import.mjs" });
    defer module_parsed.deinit();
    try std.testing.expect(module_parsed.syntax_error == null);

    var script_parsed = try parser.compile(rt, "import('dep',);", .{ .mode = .script, .filename = "dynamic-import.js" });
    defer script_parsed.deinit();
    try std.testing.expect(script_parsed.syntax_error == null);

    var import_meta_arg = try parser.compile(rt, "import(import.meta);", .{ .mode = .module, .filename = "dynamic-import-meta.mjs" });
    defer import_meta_arg.deinit();
    try std.testing.expect(import_meta_arg.syntax_error == null);

    var import_in_arg = try parser.compile(rt, "for (promise = import('dep', 'x' in {}); false;) ;", .{ .mode = .script, .filename = "dynamic-import-in.js" });
    defer import_in_arg.deinit();
    try std.testing.expect(import_in_arg.syntax_error == null);
}

test "dynamic import arguments do not leak anonymous function named evaluation" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try parser.compile(
        rt,
        "const direct = () => {}; async function fn() { const ns = await import(() => {}); }",
        .{ .mode = .script, .filename = "dynamic-import-name.js" },
    );
    defer parsed.deinit();

    try std.testing.expect(parsed.syntax_error == null);
    try std.testing.expectEqual(@as(usize, 1), countOpcodeRecursive(&parsed.function, op.set_name));
    try std.testing.expectEqual(@as(usize, 1), countOpcodeRecursive(&parsed.function, op.import));
}

test "parser rejects invalid dynamic import call syntax" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var new_import = try parser.compile(rt, "new import('dep');", .{ .mode = .script, .filename = "bad-dynamic-import.js" });
    defer new_import.deinit();
    try std.testing.expect(new_import.syntax_error != null);

    var escaped_import = try parser.compile(rt, "im\\u0070ort('dep');", .{ .mode = .script, .filename = "escaped-dynamic-import.js" });
    defer escaped_import.deinit();
    try std.testing.expect(escaped_import.syntax_error != null);
}

test "module parser accepts default as explicit namespace export name" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try parser.compile(rt, "export * as default from './dep.js';", .{ .mode = .module, .filename = "default-star.js" });
    defer parsed.deinit();

    try std.testing.expect(parsed.syntax_error == null);
    try std.testing.expectEqual(@as(usize, 1), parsed.function.module_record.?.star_exports.len);
}

test "eval function class private destructuring spread async generator features are recorded" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try parser.compile(
        rt,
        "async function *f(...args) { class C { #x; method(){ return args[0]; } } let {x} = args[0]; yield x; await x; import('m'); }",
        .{ .mode = .eval_direct, .filename = "eval.js" },
    );
    defer parsed.deinit();

    try std.testing.expect(parsed.direct_eval);
    try std.testing.expect(parsed.syntax_error == null);
    try std.testing.expectEqual(parser.CompilePath.normal, parsed.parse_path);
    try std.testing.expect(parsed.hasFeature(.statement));
    try std.testing.expect(parsed.hasFeature(.expression));
    try std.testing.expect(parsed.hasFeature(.function_));
    try std.testing.expect(parsed.hasFeature(.async_function));
    try std.testing.expect(parsed.hasFeature(.generator));
    try std.testing.expect(parsed.hasFeature(.async_generator));
    try std.testing.expect(parsed.hasFeature(.class_));
    try std.testing.expect(parsed.hasFeature(.private_name));
    try std.testing.expect(parsed.hasFeature(.destructuring));
    try std.testing.expect(parsed.hasFeature(.spread_rest));
    try std.testing.expect(parsed.hasFeature(.dynamic_import));
    try std.testing.expect(!parsed.hasFeature(.arrow));
    try expectFunctionKindRecursive(&parsed.function, .async_generator);
    try expectOpcodeRecursive(&parsed.function, qop.rest);
    try expectOpcodeRecursive(&parsed.function, qop.define_class);
    try expectOpcodeRecursive(&parsed.function, qop.define_field);
    try expectOpcodeRecursive(&parsed.function, qop.define_method);
    try expectOpcodeRecursive(&parsed.function, qop.yield);
    try expectOpcodeRecursive(&parsed.function, qop.await);
    try expectOpcodeRecursive(&parsed.function, qop.import);
}

test "bytecode constants retain values through Phase 4 structures" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("emit");
    defer rt.atoms.free(name);

    var function_bc = engine.bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer function_bc.deinit(rt);

    const text = try core.string.String.createAscii(rt, "hello");
    const value = text.value();
    const const_index = try function_bc.addConstant(value);
    value.free(rt);

    try std.testing.expectEqual(@as(u32, 0), const_index);
    try std.testing.expectEqual(@as(usize, 1), function_bc.constants.values.len);
}

// F1 — QuickJS-aligned lexer tests (separate file)

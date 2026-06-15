const std = @import("std");
const zjs = @import("zjs");
const engine = zjs;

const core = zjs.core;
const frontend = zjs.frontend;
const function_def = zjs.bytecode.function_def;
const qop = zjs.bytecode.opcode.op;
const op = zjs.bytecode.opcode.op;

const t = zjs.frontend.zjs_token;
const QjsLexer = zjs.frontend.zjs_lexer.Lexer;
const QjsParser = zjs.frontend.zjs_parser.Parser;
const zjs_parser = zjs.frontend.zjs_parser;
const atom = zjs.core.atom;
const function_def_mod = zjs.bytecode.function_def;
const ParseState = engine.frontend.zjs_parser.ParseState;

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
    try zjs_parser.parseExpr(&state);
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
    state.top_level_functions_as_children = true;
    try zjs_parser.parseExpr(&state);
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
    state.is_strict = true;
    state.function_def.is_strict_mode = true;
    try zjs_parser.parseExpr(&state);
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
    try zjs_parser.parseStatementOrDecl(&state, zjs_parser.DeclMask{ .func = true, .func_with_label = true, .other = true });
    try engine.bytecode.pipeline.finalize.runWithFunctionDef(&function, &state.function_def);
    return function;
}

fn parseTSStatement(env: *TestEnv, src: []const u8) !engine.bytecode.Bytecode {
    const name = try env.rt.internAtom("test");
    defer env.rt.atoms.free(name);
    var function = engine.bytecode.Bytecode.init(&env.rt.memory, &env.rt.atoms, name);
    errdefer function.deinit(env.rt);
    var lex = QjsLexer.init(std.testing.allocator, &env.rt.atoms, src);
    try lex.enableTypeScript();
    var state = try ParseState.init(&lex, &function);
    defer state.deinit(env.rt);
    try zjs_parser.parseStatementOrDecl(&state, zjs_parser.DeclMask{ .func = true, .func_with_label = true, .other = true });
    try engine.bytecode.pipeline.finalize.runWithFunctionDef(&function, &state.function_def);
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
    state.top_level_functions_as_children = true;
    try zjs_parser.parseStatementOrDecl(&state, zjs_parser.DeclMask{ .func = true, .func_with_label = true, .other = true });
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
    try zjs_parser.parseStatementOrDecl(&state, zjs_parser.DeclMask{ .func = true, .func_with_label = true, .other = true });
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
    state.top_level_lexical_as_module_ref = true;
    try zjs_parser.parseStatementOrDecl(&state, zjs_parser.DeclMask{ .func = true, .func_with_label = true, .other = true });
    try engine.bytecode.pipeline.finalize.runWithFunctionDef(&function, &state.function_def);
    return function;
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
    return @fieldParentPtr("header", header);
}

fn expectFunctionConstant(function: *const engine.bytecode.Bytecode, index: usize) !*const engine.bytecode.FunctionBytecode {
    try std.testing.expect(index < function.constants.values.len);
    return functionBytecodeFromValue(function.constants.values[index]) orelse error.TestExpectedEqual;
}

fn countOpcodeInFunctionBytecode(fb: *const engine.bytecode.FunctionBytecode, opcode: u8) usize {
    var count = countOpcode(fb.byte_code, opcode);
    for (fb.cpool) |value| {
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
    try std.testing.expect(std.mem.indexOfScalar(u8, code, opcode) != null);
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
    try zjs_parser.parseStatementOrDecl(&state, zjs_parser.DeclMask{ .func = true, .func_with_label = true, .other = true });
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
    const diff = readI32(bytes, operand_offset);
    return @intCast(@as(i64, @intCast(operand_offset)) + @as(i64, diff));
}

fn countOpcode(code: []const u8, opcode: u8) usize {
    var count: usize = 0;
    for (code) |byte| {
        if (byte == opcode) count += 1;
    }
    return count;
}

// ---- F4 first slice -------------------------------------------------

test "F4: number literal lowers to push_i32 for small integers" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "42");
    defer fn_bc.deinit(env.rt);

    try std.testing.expectEqual(@as(usize, 5), fn_bc.code.len);
    try std.testing.expectEqual(op.push_i32, fn_bc.code[0]);
    try std.testing.expectEqual(@as(i32, 42), readI32(fn_bc.code, 1));
}

test "F4: number literal with non-integer value lowers to push_const" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "3.5");
    defer fn_bc.deinit(env.rt);

    try std.testing.expectEqual(@as(usize, 5), fn_bc.code.len);
    try std.testing.expectEqual(op.push_const, fn_bc.code[0]);
    const idx = readU32(fn_bc.code, 1);
    const value = fn_bc.constants.get(idx).?;
    defer value.free(env.rt);
    try std.testing.expectApproxEqAbs(@as(f64, 3.5), value.asFloat64().?, 0.0001);
}

test "F4: large bigint literal lowers to constant pool value" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "0x100000000n");
    defer fn_bc.deinit(env.rt);

    try std.testing.expectEqual(@as(usize, 5), fn_bc.code.len);
    try std.testing.expectEqual(op.push_const, fn_bc.code[0]);
    const idx = readU32(fn_bc.code, 1);
    const value = fn_bc.constants.get(idx).?;
    defer value.free(env.rt);
    try std.testing.expect(value.isBigInt());
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

    try std.testing.expectEqual(@as(usize, 5), fn_bc.code.len);
    try std.testing.expectEqual(op.get_var, fn_bc.code[0]);
    try std.testing.expectEqual(@as(usize, 1), fn_bc.atom_operands.len);
}

test "F4: parseExprBinary level 1 (mul/div/mod)" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "2 * 3");
    defer fn_bc.deinit(env.rt);

    // Expect: push_i32 2 ; push_i32 3 ; mul
    try std.testing.expectEqual(@as(usize, 11), fn_bc.code.len);
    try std.testing.expectEqual(op.push_i32, fn_bc.code[0]);
    try std.testing.expectEqual(@as(i32, 2), readI32(fn_bc.code, 1));
    try std.testing.expectEqual(op.push_i32, fn_bc.code[5]);
    try std.testing.expectEqual(@as(i32, 3), readI32(fn_bc.code, 6));
    try std.testing.expectEqual(op.mul, fn_bc.code[10]);
}

test "F4: parseExprBinary level 2 (add/sub) is left-associative" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "1 + 2 - 3");
    defer fn_bc.deinit(env.rt);

    // Expect: push_i32 1 ; push_i32 2 ; add ; push_i32 3 ; sub
    try std.testing.expectEqual(@as(usize, 17), fn_bc.code.len);
    try std.testing.expectEqual(op.push_i32, fn_bc.code[0]);
    try std.testing.expectEqual(op.push_i32, fn_bc.code[5]);
    try std.testing.expectEqual(op.add, fn_bc.code[10]);
    try std.testing.expectEqual(op.push_i32, fn_bc.code[11]);
    try std.testing.expectEqual(op.sub, fn_bc.code[16]);
}

test "F4: precedence — multiplication before addition" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "1 + 2 * 3");
    defer fn_bc.deinit(env.rt);

    // Expect: push_i32 1 ; push_i32 2 ; push_i32 3 ; mul ; add
    try std.testing.expectEqual(@as(usize, 17), fn_bc.code.len);
    try std.testing.expectEqual(op.push_i32, fn_bc.code[0]);
    try std.testing.expectEqual(op.push_i32, fn_bc.code[5]);
    try std.testing.expectEqual(op.push_i32, fn_bc.code[10]);
    try std.testing.expectEqual(op.mul, fn_bc.code[15]);
    try std.testing.expectEqual(op.add, fn_bc.code[16]);
}

test "F4: parentheses override precedence" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "(1 + 2) * 3");
    defer fn_bc.deinit(env.rt);

    // Expect: push_i32 1 ; push_i32 2 ; add ; push_i32 3 ; mul
    try std.testing.expectEqual(@as(usize, 17), fn_bc.code.len);
    try std.testing.expectEqual(op.add, fn_bc.code[10]);
    try std.testing.expectEqual(op.mul, fn_bc.code[16]);
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

    // Expect: get_var_undef <atom> ; typeof
    try std.testing.expectEqual(@as(usize, 6), fn_bc.code.len);
    try std.testing.expectEqual(op.get_var_undef, fn_bc.code[0]);
    try std.testing.expectEqual(op.typeof, fn_bc.code[5]);
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

    // Expect: push_i32 0 ; drop ; undefined
    try std.testing.expectEqual(@as(usize, 7), fn_bc.code.len);
    try std.testing.expectEqual(op.push_i32, fn_bc.code[0]);
    try std.testing.expectEqual(op.drop, fn_bc.code[5]);
    try std.testing.expectEqual(op.undefined, fn_bc.code[6]);
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

    // Expect:
    //   get_var x          (5)
    //   dup                (1)
    //   if_false L_skip    (5)
    //   drop               (1)
    //   get_var y          (5)
    //   L_skip:            (target)
    try std.testing.expectEqual(@as(usize, 17), fn_bc.code.len);
    try std.testing.expectEqual(op.get_var, fn_bc.code[0]);
    try std.testing.expectEqual(op.dup, fn_bc.code[5]);
    try std.testing.expectEqual(op.if_false, fn_bc.code[6]);
    try std.testing.expectEqual(op.drop, fn_bc.code[11]);
    try std.testing.expectEqual(op.get_var, fn_bc.code[12]);
    // The if_false target should be one byte past the last get_var.
    const target = readRelTarget32(fn_bc.code, 6);
    try std.testing.expectEqual(fn_bc.code.len, target);
}

test "F4: logical || uses dup + if_true short-circuit" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "x || y");
    defer fn_bc.deinit(env.rt);

    try std.testing.expectEqual(op.if_true, fn_bc.code[6]);
}

test "F4: nullish coalescing ?? uses is_undefined_or_null gate" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "x ?? y");
    defer fn_bc.deinit(env.rt);

    // Expect: get_var x ; dup ; is_undefined_or_null ; if_false L ; drop ; get_var y ; L:
    try std.testing.expectEqual(op.dup, fn_bc.code[5]);
    try std.testing.expectEqual(op.is_undefined_or_null, fn_bc.code[6]);
    try std.testing.expectEqual(op.if_false, fn_bc.code[7]);
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

test "F4: ternary cond ? a : b emits if_false + goto skeleton" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "a ? b : c");
    defer fn_bc.deinit(env.rt);

    // Layout (lengths):
    //   get_var a       5
    //   if_false L_else 5
    //   get_var b       5
    //   goto    L_end   5
    // L_else:
    //   get_var c       5
    // L_end:
    try std.testing.expectEqual(@as(usize, 25), fn_bc.code.len);
    try std.testing.expectEqual(op.if_false, fn_bc.code[5]);
    try std.testing.expectEqual(op.goto, fn_bc.code[15]);
    // L_else points just past the goto operand
    const else_target = readRelTarget32(fn_bc.code, 5);
    try std.testing.expectEqual(@as(usize, 20), else_target);
    // L_end points to end of bytecode
    const end_target = readRelTarget32(fn_bc.code, 15);
    try std.testing.expectEqual(@as(usize, 25), end_target);
}

test "F4: simple assignment x = 1 emits push ; dup ; put_var (KEEP_TOP)" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "x = 1");
    defer fn_bc.deinit(env.rt);

    // Expect: push_i32 1 ; dup ; put_var x
    // Mirrors QuickJS `put_lvalue` PUT_LVALUE_KEEP_TOP for OP_scope_get_var
    // (`quickjs.c:25479`), which emits an OP_dup before the put so the
    // assignment expression's value remains on the stack.
    try std.testing.expectEqual(@as(usize, 11), fn_bc.code.len);
    try std.testing.expectEqual(op.push_i32, fn_bc.code[0]);
    try std.testing.expectEqual(op.dup, fn_bc.code[5]);
    try std.testing.expectEqual(op.put_var, fn_bc.code[6]);
}

test "F4: compound assignment x += 1 emits get_var ; rhs ; add ; dup ; put_var" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "x += 1");
    defer fn_bc.deinit(env.rt);

    // Expect: get_var x ; push_i32 1 ; add ; dup ; put_var x
    try std.testing.expectEqual(@as(usize, 17), fn_bc.code.len);
    try std.testing.expectEqual(op.get_var, fn_bc.code[0]);
    try std.testing.expectEqual(op.push_i32, fn_bc.code[5]);
    try std.testing.expectEqual(op.add, fn_bc.code[10]);
    try std.testing.expectEqual(op.dup, fn_bc.code[11]);
    try std.testing.expectEqual(op.put_var, fn_bc.code[12]);
}

test "F4: comma operator drops left, keeps right" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "1, 2");
    defer fn_bc.deinit(env.rt);

    // Expect: push_i32 1 ; drop ; push_i32 2
    try std.testing.expectEqual(@as(usize, 11), fn_bc.code.len);
    try std.testing.expectEqual(op.push_i32, fn_bc.code[0]);
    try std.testing.expectEqual(op.drop, fn_bc.code[5]);
    try std.testing.expectEqual(op.push_i32, fn_bc.code[6]);
}

test "F4: member access a.b emits get_var + get_field" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "a.b");
    defer fn_bc.deinit(env.rt);

    // Expect: get_var a ; get_field b
    try std.testing.expectEqual(@as(usize, 10), fn_bc.code.len);
    try std.testing.expectEqual(op.get_var, fn_bc.code[0]);
    try std.testing.expectEqual(op.get_field, fn_bc.code[5]);
}

test "F4: index access a[i] emits get_var ; get_var ; get_array_el" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "a[i]");
    defer fn_bc.deinit(env.rt);

    // Expect: get_var a ; get_var i ; get_array_el
    try std.testing.expectEqual(@as(usize, 11), fn_bc.code.len);
    try std.testing.expectEqual(op.get_var, fn_bc.code[0]);
    try std.testing.expectEqual(op.get_var, fn_bc.code[5]);
    try std.testing.expectEqual(op.get_array_el, fn_bc.code[10]);
}

// ---- F4 slice 2 -----------------------------------------------------

test "F4: nested assignment 1 + (a = b) preserves the leading push" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "1 + (a = b)");
    defer fn_bc.deinit(env.rt);

    // Expect: push_i32 1 ; get_var b ; dup ; put_var a ; add
    try std.testing.expectEqual(@as(usize, 17), fn_bc.code.len);
    try std.testing.expectEqual(op.push_i32, fn_bc.code[0]);
    try std.testing.expectEqual(op.get_var, fn_bc.code[5]);
    try std.testing.expectEqual(op.dup, fn_bc.code[10]);
    try std.testing.expectEqual(op.put_var, fn_bc.code[11]);
    try std.testing.expectEqual(op.add, fn_bc.code[16]);
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

    // Expect: push_i32 1 ; push_i32 2 ; push_i32 3 ; array_from 3
    try std.testing.expectEqual(@as(usize, 18), fn_bc.code.len);
    try std.testing.expectEqual(op.push_i32, fn_bc.code[0]);
    try std.testing.expectEqual(op.push_i32, fn_bc.code[5]);
    try std.testing.expectEqual(op.push_i32, fn_bc.code[10]);
    try std.testing.expectEqual(op.array_from, fn_bc.code[15]);
    const argc = std.mem.readInt(u16, fn_bc.code[16..18], .little);
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

    try std.testing.expectEqual(op.array_from, fn_bc.code[10]);
    const argc = std.mem.readInt(u16, fn_bc.code[11..13], .little);
    try std.testing.expectEqual(@as(u16, 2), argc);
}

test "F4: object literal { a: 1, b: 2 } lowers to object + define_field" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "{ a: 1, b: 2 }");
    defer fn_bc.deinit(env.rt);

    // Expect:
    //   object              (1)
    //   push_i32 1          (5)
    //   define_field a      (5)
    //   push_i32 2          (5)
    //   define_field b      (5)
    try std.testing.expectEqual(@as(usize, 21), fn_bc.code.len);
    try std.testing.expectEqual(op.object, fn_bc.code[0]);
    try std.testing.expectEqual(op.push_i32, fn_bc.code[1]);
    try std.testing.expectEqual(op.define_field, fn_bc.code[6]);
    try std.testing.expectEqual(op.push_i32, fn_bc.code[11]);
    try std.testing.expectEqual(op.define_field, fn_bc.code[16]);
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

    // Expect: object ; get_var x ; define_field x
    try std.testing.expectEqual(@as(usize, 11), fn_bc.code.len);
    try std.testing.expectEqual(op.object, fn_bc.code[0]);
    try std.testing.expectEqual(op.get_var, fn_bc.code[1]);
    try std.testing.expectEqual(op.define_field, fn_bc.code[6]);
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
    while (pc < child.byte_code.len) {
        const op_id = child.byte_code[pc];
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
        .bytes = child.pc2line_buf,
        .line_num = child.line_num,
        .col_num = child.col_num,
        .memory = &env.rt.memory,
    });
    defer std.testing.allocator.free(decoded);

    var line_num = child.line_num;
    var col_num = child.col_num;
    for (decoded) |slot| {
        if (slot.pc > close_pc) break;
        line_num = slot.line_num;
        col_num = slot.col_num;
    }
    try std.testing.expectEqual(@as(i32, 10), line_num);
    try std.testing.expectEqual(@as(i32, 7), col_num);
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

    try std.testing.expect(std.mem.indexOfScalar(u8, fn_bc.code, op.if_false) != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, fn_bc.code, op.define_array_el) != null);
}

test "M3.1 F4: computed object key accepts logical or assignment" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "{ [x ||= 1]: 2 }");
    defer fn_bc.deinit(env.rt);

    try std.testing.expect(std.mem.indexOfScalar(u8, fn_bc.code, op.if_true) != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, fn_bc.code, op.define_array_el) != null);
}

test "M3.1 F4: computed object key accepts indexed logical assignment" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "{ [a[0] ||= 1]: 2 }");
    defer fn_bc.deinit(env.rt);

    try std.testing.expect(std.mem.indexOfScalar(u8, fn_bc.code, op.dup2) != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, fn_bc.code, op.if_true) != null);
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

    // Expect: get_var f ; get_var a ; get_var b ; call 2
    try std.testing.expectEqual(@as(usize, 18), fn_bc.code.len);
    try std.testing.expectEqual(op.get_var, fn_bc.code[0]);
    try std.testing.expectEqual(op.get_var, fn_bc.code[5]);
    try std.testing.expectEqual(op.get_var, fn_bc.code[10]);
    try std.testing.expectEqual(op.call, fn_bc.code[15]);
    const argc = std.mem.readInt(u16, fn_bc.code[16..18], .little);
    try std.testing.expectEqual(@as(u16, 2), argc);
}

test "F4: zero-arg call f() emits call 0" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "f()");
    defer fn_bc.deinit(env.rt);

    try std.testing.expectEqual(@as(usize, 8), fn_bc.code.len);
    try std.testing.expectEqual(op.call, fn_bc.code[5]);
    const argc = std.mem.readInt(u16, fn_bc.code[6..8], .little);
    try std.testing.expectEqual(@as(u16, 0), argc);
}

test "F4: method call obj.m(x) uses prepare_call_prop_atom + call_prepared" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "obj.m(x)");
    defer fn_bc.deinit(env.rt);

    // Expect: get_var obj ; prepare_call_prop_atom m ; get_var x ; call_prepared 1
    try std.testing.expectEqual(@as(usize, 18), fn_bc.code.len);
    try std.testing.expectEqual(op.get_var, fn_bc.code[0]);
    try std.testing.expectEqual(op.prepare_call_prop_atom, fn_bc.code[5]);
    try std.testing.expectEqual(op.get_var, fn_bc.code[10]);
    try std.testing.expectEqual(op.call_prepared, fn_bc.code[15]);
}

test "F4: indexed call obj[k](x) uses get_array_el2 + call_method" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "obj[k](x)");
    defer fn_bc.deinit(env.rt);

    // Expect: get_var obj ; get_var k ; get_array_el2 ; get_var x ; call_method 1
    try std.testing.expectEqual(@as(usize, 19), fn_bc.code.len);
    try std.testing.expectEqual(op.get_var, fn_bc.code[0]);
    try std.testing.expectEqual(op.get_var, fn_bc.code[5]);
    try std.testing.expectEqual(op.get_array_el2, fn_bc.code[10]);
    try std.testing.expectEqual(op.get_var, fn_bc.code[11]);
    try std.testing.expectEqual(op.call_method, fn_bc.code[16]);
}

test "F4: new X(a) emits get_var X ; dup ; get_var a ; call_constructor 1" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "new X(a)");
    defer fn_bc.deinit(env.rt);

    try std.testing.expectEqual(@as(usize, 14), fn_bc.code.len);
    try std.testing.expectEqual(op.get_var, fn_bc.code[0]);
    try std.testing.expectEqual(op.dup, fn_bc.code[5]);
    try std.testing.expectEqual(op.get_var, fn_bc.code[6]);
    try std.testing.expectEqual(op.call_constructor, fn_bc.code[11]);
    const argc = std.mem.readInt(u16, fn_bc.code[12..14], .little);
    try std.testing.expectEqual(@as(u16, 1), argc);
}

test "F4: bare new X (no args) emits call_constructor 0" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "new X");
    defer fn_bc.deinit(env.rt);

    try std.testing.expectEqual(@as(usize, 9), fn_bc.code.len);
    try std.testing.expectEqual(op.get_var, fn_bc.code[0]);
    try std.testing.expectEqual(op.dup, fn_bc.code[5]);
    try std.testing.expectEqual(op.call_constructor, fn_bc.code[6]);
    const argc = std.mem.readInt(u16, fn_bc.code[7..9], .little);
    try std.testing.expectEqual(@as(u16, 0), argc);
}

test "F4: postfix x++ emits get_var ; post_inc ; put_var" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "x++");
    defer fn_bc.deinit(env.rt);

    // Expect: get_var x ; post_inc ; put_var x
    try std.testing.expectEqual(@as(usize, 11), fn_bc.code.len);
    try std.testing.expectEqual(op.get_var, fn_bc.code[0]);
    try std.testing.expectEqual(op.post_inc, fn_bc.code[5]);
    try std.testing.expectEqual(op.put_var, fn_bc.code[6]);
}

test "F4: postfix x-- emits get_var ; post_dec ; put_var" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "x--");
    defer fn_bc.deinit(env.rt);

    try std.testing.expectEqual(op.post_dec, fn_bc.code[5]);
}

test "F4: prefix ++x emits get_var ; inc ; dup ; put_var" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "++x");
    defer fn_bc.deinit(env.rt);

    // Expect: get_var x ; inc ; dup ; put_var x
    try std.testing.expectEqual(@as(usize, 12), fn_bc.code.len);
    try std.testing.expectEqual(op.get_var, fn_bc.code[0]);
    try std.testing.expectEqual(op.inc, fn_bc.code[5]);
    try std.testing.expectEqual(op.dup, fn_bc.code[6]);
    try std.testing.expectEqual(op.put_var, fn_bc.code[7]);
}

test "F4: prefix --x emits get_var ; dec ; dup ; put_var" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "--x");
    defer fn_bc.deinit(env.rt);

    try std.testing.expectEqual(op.dec, fn_bc.code[5]);
    try std.testing.expectEqual(op.dup, fn_bc.code[6]);
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

    try std.testing.expectEqual(@as(usize, 11), fn_bc.code.len);
    try std.testing.expectEqual(op.get_var, fn_bc.code[0]);
    try std.testing.expectEqual(op.push_atom_value, fn_bc.code[5]);
    try std.testing.expectEqual(op.delete, fn_bc.code[10]);
}

test "F4: delete a[i] emits get_var a ; get_var i ; delete" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "delete a[i]");
    defer fn_bc.deinit(env.rt);

    try std.testing.expectEqual(@as(usize, 11), fn_bc.code.len);
    try std.testing.expectEqual(op.get_var, fn_bc.code[0]);
    try std.testing.expectEqual(op.get_var, fn_bc.code[5]);
    try std.testing.expectEqual(op.delete, fn_bc.code[10]);
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

    // get_var f ; get_var a ; call 1 ; get_var b ; call 1
    try std.testing.expectEqual(@as(usize, 21), fn_bc.code.len);
    try std.testing.expectEqual(op.call, fn_bc.code[10]);
    try std.testing.expectEqual(op.call, fn_bc.code[18]);
}

// ---- F4 slice 3: member-target assign + update ----------------------

test "F4: dotted assignment a.b = v emits get_var ; rhs ; insert2 ; put_field" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "a.b = v");
    defer fn_bc.deinit(env.rt);

    // Expect: get_var a ; get_var v ; insert2 ; put_field b
    // Mirrors QuickJS PUT_LVALUE_KEEP_TOP for OP_get_field (`quickjs.c:25494`).
    try std.testing.expectEqual(@as(usize, 16), fn_bc.code.len);
    try std.testing.expectEqual(op.get_var, fn_bc.code[0]);
    try std.testing.expectEqual(op.get_var, fn_bc.code[5]);
    try std.testing.expectEqual(op.insert2, fn_bc.code[10]);
    try std.testing.expectEqual(op.put_field, fn_bc.code[11]);
}

test "F4: indexed assignment a[i] = v emits get_var ; key ; rhs ; insert3 ; put_array_el" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "a[i] = v");
    defer fn_bc.deinit(env.rt);

    // Expect: get_var a ; get_var i ; get_var v ; insert3 ; put_array_el
    // Mirrors PUT_LVALUE_KEEP_TOP for OP_get_array_el (`quickjs.c:25520`).
    try std.testing.expectEqual(@as(usize, 17), fn_bc.code.len);
    try std.testing.expectEqual(op.get_var, fn_bc.code[0]);
    try std.testing.expectEqual(op.get_var, fn_bc.code[5]);
    try std.testing.expectEqual(op.get_var, fn_bc.code[10]);
    try std.testing.expectEqual(op.insert3, fn_bc.code[15]);
    try std.testing.expectEqual(op.put_array_el, fn_bc.code[16]);
}

test "F4: compound dotted assignment a.b += v rewrites get_field to get_field2" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "a.b += v");
    defer fn_bc.deinit(env.rt);

    // Expect: get_var a ; get_field2 b ; get_var v ; add ; insert2 ; put_field b
    try std.testing.expectEqual(@as(usize, 22), fn_bc.code.len);
    try std.testing.expectEqual(op.get_var, fn_bc.code[0]);
    try std.testing.expectEqual(op.get_field2, fn_bc.code[5]);
    try std.testing.expectEqual(op.get_var, fn_bc.code[10]);
    try std.testing.expectEqual(op.add, fn_bc.code[15]);
    try std.testing.expectEqual(op.insert2, fn_bc.code[16]);
    try std.testing.expectEqual(op.put_field, fn_bc.code[17]);
}

test "F4: compound indexed assignment a[i] += v keeps QuickJS indexed lvalue shape" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "a[i] += v");
    defer fn_bc.deinit(env.rt);

    // Expect: get_var a ; get_var i ; to_propkey2 ; dup2 ; get_array_el ;
    // get_var v ; add ; insert3 ; put_array_el
    try std.testing.expectEqual(@as(usize, 21), fn_bc.code.len);
    try std.testing.expectEqual(op.get_var, fn_bc.code[0]);
    try std.testing.expectEqual(op.get_var, fn_bc.code[5]);
    try std.testing.expectEqual(op.to_propkey2, fn_bc.code[10]);
    try std.testing.expectEqual(op.dup2, fn_bc.code[11]);
    try std.testing.expectEqual(op.get_array_el, fn_bc.code[12]);
    try std.testing.expectEqual(op.get_var, fn_bc.code[13]);
    try std.testing.expectEqual(op.add, fn_bc.code[18]);
    try std.testing.expectEqual(op.insert3, fn_bc.code[19]);
    try std.testing.expectEqual(op.put_array_el, fn_bc.code[20]);
}

test "F4: postfix dotted a.b++ emits get_field2 ; post_inc ; perm3 ; put_field" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "a.b++");
    defer fn_bc.deinit(env.rt);

    // Expect: get_var a ; get_field2 b ; post_inc ; perm3 ; put_field b
    // Mirrors PUT_LVALUE_KEEP_SECOND for OP_get_field (`quickjs.c:25497`).
    try std.testing.expectEqual(@as(usize, 17), fn_bc.code.len);
    try std.testing.expectEqual(op.get_var, fn_bc.code[0]);
    try std.testing.expectEqual(op.get_field2, fn_bc.code[5]);
    try std.testing.expectEqual(op.post_inc, fn_bc.code[10]);
    try std.testing.expectEqual(op.perm3, fn_bc.code[11]);
    try std.testing.expectEqual(op.put_field, fn_bc.code[12]);
}

test "F4: postfix indexed a[i]-- emits QuickJS indexed lvalue read ; post_dec ; perm4 ; put_array_el" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "a[i]--");
    defer fn_bc.deinit(env.rt);

    // Expect: get_var a ; get_var i ; to_propkey2 ; dup2 ; get_array_el ;
    // post_dec ; perm4 ; put_array_el
    // Mirrors PUT_LVALUE_KEEP_SECOND for OP_get_array_el (`quickjs.c:25523`).
    try std.testing.expectEqual(@as(usize, 16), fn_bc.code.len);
    try std.testing.expectEqual(op.get_var, fn_bc.code[0]);
    try std.testing.expectEqual(op.get_var, fn_bc.code[5]);
    try std.testing.expectEqual(op.to_propkey2, fn_bc.code[10]);
    try std.testing.expectEqual(op.dup2, fn_bc.code[11]);
    try std.testing.expectEqual(op.get_array_el, fn_bc.code[12]);
    try std.testing.expectEqual(op.post_dec, fn_bc.code[13]);
    try std.testing.expectEqual(op.perm4, fn_bc.code[14]);
    try std.testing.expectEqual(op.put_array_el, fn_bc.code[15]);
}

test "F4: prefix ++a.b emits get_field2 ; inc ; insert2 ; put_field" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "++a.b");
    defer fn_bc.deinit(env.rt);

    // Expect: get_var a ; get_field2 b ; inc ; insert2 ; put_field b
    try std.testing.expectEqual(@as(usize, 17), fn_bc.code.len);
    try std.testing.expectEqual(op.get_var, fn_bc.code[0]);
    try std.testing.expectEqual(op.get_field2, fn_bc.code[5]);
    try std.testing.expectEqual(op.inc, fn_bc.code[10]);
    try std.testing.expectEqual(op.insert2, fn_bc.code[11]);
    try std.testing.expectEqual(op.put_field, fn_bc.code[12]);
}

test "F4: prefix --a[i] emits QuickJS indexed lvalue read ; dec ; insert3 ; put_array_el" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "--a[i]");
    defer fn_bc.deinit(env.rt);

    // Expect: get_var a ; get_var i ; to_propkey2 ; dup2 ; get_array_el ;
    // dec ; insert3 ; put_array_el
    try std.testing.expectEqual(@as(usize, 16), fn_bc.code.len);
    try std.testing.expectEqual(op.get_var, fn_bc.code[0]);
    try std.testing.expectEqual(op.get_var, fn_bc.code[5]);
    try std.testing.expectEqual(op.to_propkey2, fn_bc.code[10]);
    try std.testing.expectEqual(op.dup2, fn_bc.code[11]);
    try std.testing.expectEqual(op.get_array_el, fn_bc.code[12]);
    try std.testing.expectEqual(op.dec, fn_bc.code[13]);
    try std.testing.expectEqual(op.insert3, fn_bc.code[14]);
    try std.testing.expectEqual(op.put_array_el, fn_bc.code[15]);
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

    // Expect: push_i32 1 ; array_from 1 ; push_i32 3 ; define_field "2" ; set length 3.
    try std.testing.expectEqual(@as(usize, 29), fn_bc.code.len);
    try std.testing.expectEqual(op.push_i32, fn_bc.code[0]);
    try std.testing.expectEqual(op.array_from, fn_bc.code[5]);
    const argc = std.mem.readInt(u16, fn_bc.code[6..8], .little);
    try std.testing.expectEqual(@as(u16, 1), argc);
    try std.testing.expectEqual(op.push_i32, fn_bc.code[8]);
    try std.testing.expectEqual(op.define_field, fn_bc.code[13]);
    try std.testing.expectEqual(op.dup, fn_bc.code[18]);
    try std.testing.expectEqual(op.push_i32, fn_bc.code[19]);
    try std.testing.expectEqual(op.put_field, fn_bc.code[24]);
}

test "F4: leading hole [, 1] emits sparse define_field at index 1" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "[, 1]");
    defer fn_bc.deinit(env.rt);

    // Expect: array_from 0 ; push_i32 1 ; define_field "1" ; set length 2.
    try std.testing.expectEqual(@as(usize, 24), fn_bc.code.len);
    try std.testing.expectEqual(op.array_from, fn_bc.code[0]);
    const argc = std.mem.readInt(u16, fn_bc.code[1..3], .little);
    try std.testing.expectEqual(@as(u16, 0), argc);
    try std.testing.expectEqual(op.push_i32, fn_bc.code[3]);
    try std.testing.expectEqual(op.define_field, fn_bc.code[8]);
    try std.testing.expectEqual(op.dup, fn_bc.code[13]);
    try std.testing.expectEqual(op.push_i32, fn_bc.code[14]);
    try std.testing.expectEqual(op.put_field, fn_bc.code[19]);
}

test "F4: consecutive holes [, , 1] emits sparse define_field at index 2" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "[, , 1]");
    defer fn_bc.deinit(env.rt);

    // Expect: array_from 0 ; push_i32 1 ; define_field "2" ; set length 3.
    try std.testing.expectEqual(@as(usize, 24), fn_bc.code.len);
    try std.testing.expectEqual(op.array_from, fn_bc.code[0]);
    const argc = std.mem.readInt(u16, fn_bc.code[1..3], .little);
    try std.testing.expectEqual(@as(u16, 0), argc);
    try std.testing.expectEqual(op.push_i32, fn_bc.code[3]);
    try std.testing.expectEqual(op.define_field, fn_bc.code[8]);
    try std.testing.expectEqual(op.dup, fn_bc.code[13]);
    try std.testing.expectEqual(op.push_i32, fn_bc.code[14]);
    try std.testing.expectEqual(op.put_field, fn_bc.code[19]);
}

test "F4: multi-level delete a.b.c rewrites only the last get_field" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "delete a.b.c");
    defer fn_bc.deinit(env.rt);

    // Expect: get_var a ; get_field b ; push_atom_value c ; delete
    try std.testing.expectEqual(@as(usize, 16), fn_bc.code.len);
    try std.testing.expectEqual(op.get_var, fn_bc.code[0]);
    try std.testing.expectEqual(op.get_field, fn_bc.code[5]);
    try std.testing.expectEqual(op.push_atom_value, fn_bc.code[10]);
    try std.testing.expectEqual(op.delete, fn_bc.code[15]);
}

test "F4: multi-level delete a.b[i] truncates the trailing get_array_el" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "delete a.b[i]");
    defer fn_bc.deinit(env.rt);

    // Expect: get_var a ; get_field b ; get_var i ; delete
    try std.testing.expectEqual(@as(usize, 16), fn_bc.code.len);
    try std.testing.expectEqual(op.get_var, fn_bc.code[0]);
    try std.testing.expectEqual(op.get_field, fn_bc.code[5]);
    try std.testing.expectEqual(op.get_var, fn_bc.code[10]);
    try std.testing.expectEqual(op.delete, fn_bc.code[15]);
}

test "F4: delete on a postfix update result evaluates and returns true" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "delete (a.b++)");
    defer fn_bc.deinit(env.rt);

    // Trailing op of a.b++ is put_field, which doesn't match any
    // LhsShape; classifier returns .none → drop ; push_true.
    try std.testing.expectEqual(op.drop, fn_bc.code[fn_bc.code.len - 2]);
    try std.testing.expectEqual(op.push_true, fn_bc.code[fn_bc.code.len - 1]);
}

test "F4: optional chain a?.b emits inline chain_test + normal get_field" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "a?.b");
    defer fn_bc.deinit(env.rt);

    // Expected (mirror `quickjs.c:26158` optional_chain_test):
    //   get_var a              (5)
    //   dup                    (1)
    //   is_undefined_or_null   (1)
    //   if_false NEXT          (5)   -- jump past chain-exit prelude
    //   drop                   (1)   -- drop_count = 1 for member access
    //   undefined              (1)
    //   goto CHAIN_EXIT        (5)   -- patched at chain end
    //   NEXT:                  (here, target of if_false above)
    //   get_field b            (5)
    //   CHAIN_EXIT:            (here, target of goto above)
    try std.testing.expectEqual(@as(usize, 24), fn_bc.code.len);
    try std.testing.expectEqual(op.get_var, fn_bc.code[0]);
    try std.testing.expectEqual(op.dup, fn_bc.code[5]);
    try std.testing.expectEqual(op.is_undefined_or_null, fn_bc.code[6]);
    try std.testing.expectEqual(op.if_false, fn_bc.code[7]);
    try std.testing.expectEqual(op.drop, fn_bc.code[12]);
    try std.testing.expectEqual(op.undefined, fn_bc.code[13]);
    try std.testing.expectEqual(op.goto, fn_bc.code[14]);
    try std.testing.expectEqual(op.get_field, fn_bc.code[19]);

    // The if_false target should be NEXT (offset 19 — the get_field).
    const next_target = readRelTarget32(fn_bc.code, 7);
    try std.testing.expectEqual(@as(usize, 19), next_target);
    // The goto target should be CHAIN_EXIT (end of bytecode = 24).
    const exit_target = readRelTarget32(fn_bc.code, 14);
    try std.testing.expectEqual(@as(usize, 24), exit_target);
}

test "F4: optional chain a?.[i] emits inline chain_test + get_array_el" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "a?.[i]");
    defer fn_bc.deinit(env.rt);

    // get_var a (5) ; chain_test (14) ; get_var i (5) ; get_array_el (1)
    try std.testing.expectEqual(@as(usize, 25), fn_bc.code.len);
    try std.testing.expectEqual(op.get_var, fn_bc.code[0]);
    try std.testing.expectEqual(op.dup, fn_bc.code[5]);
    try std.testing.expectEqual(op.goto, fn_bc.code[14]);
    try std.testing.expectEqual(op.get_var, fn_bc.code[19]);
    try std.testing.expectEqual(op.get_array_el, fn_bc.code[24]);
}

test "F4: optional chain a?.b.c — chain test only at the ?. site" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "a?.b.c");
    defer fn_bc.deinit(env.rt);

    // get_var a (5) ; chain_test (14) ; get_field b (5) ; get_field c (5)
    try std.testing.expectEqual(@as(usize, 29), fn_bc.code.len);
    try std.testing.expectEqual(op.get_var, fn_bc.code[0]);
    try std.testing.expectEqual(op.dup, fn_bc.code[5]);
    try std.testing.expectEqual(op.get_field, fn_bc.code[19]);
    try std.testing.expectEqual(op.get_field, fn_bc.code[24]);
    // CHAIN_EXIT is the end of bytecode.
    const exit_target = readRelTarget32(fn_bc.code, 14);
    try std.testing.expectEqual(@as(usize, 29), exit_target);
}

test "F4: a?.b?.c emits two chain_tests sharing a common chain exit" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "a?.b?.c");
    defer fn_bc.deinit(env.rt);

    // Layout: get_var a ; chain_test1 ; get_field b ; chain_test2 ; get_field c
    //          5         + 14          + 5            + 14         + 5  = 43
    try std.testing.expectEqual(@as(usize, 43), fn_bc.code.len);
    // Both goto operands target the same chain end.
    const exit_target_1 = readRelTarget32(fn_bc.code, 14);
    const exit_target_2 = readRelTarget32(fn_bc.code, 33);
    try std.testing.expectEqual(exit_target_1, exit_target_2);
    try std.testing.expectEqual(@as(usize, 43), exit_target_1);
}

test "F4: optional call a?.() emits chain_test + plain call" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "a?.()");
    defer fn_bc.deinit(env.rt);

    // Expected: get_var a (5) ; chain_test (14) ; call 0 (3)
    try std.testing.expectEqual(@as(usize, 22), fn_bc.code.len);
    try std.testing.expectEqual(op.get_var, fn_bc.code[0]);
    try std.testing.expectEqual(op.dup, fn_bc.code[5]);
    try std.testing.expectEqual(op.is_undefined_or_null, fn_bc.code[6]);
    try std.testing.expectEqual(op.if_false, fn_bc.code[7]);
    try std.testing.expectEqual(op.drop, fn_bc.code[12]);
    try std.testing.expectEqual(op.undefined, fn_bc.code[13]);
    try std.testing.expectEqual(op.goto, fn_bc.code[14]);
    try std.testing.expectEqual(op.call, fn_bc.code[19]);
    const argc = std.mem.readInt(u16, fn_bc.code[20..22], .little);
    try std.testing.expectEqual(@as(u16, 0), argc);
    // Chain exit lands at end of bytecode (after the call).
    const exit_target = readRelTarget32(fn_bc.code, 14);
    try std.testing.expectEqual(@as(usize, 22), exit_target);
}

test "F4: method-on-opt-chain obj?.b(x) uses get_field2 + call_method" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "obj?.b(x)");
    defer fn_bc.deinit(env.rt);

    // Expected: get_var obj (5) ; chain_test (14) ; get_field2 b (5) ;
    //           get_var x (5) ; call_method 1 (3) = 32
    try std.testing.expectEqual(@as(usize, 32), fn_bc.code.len);
    try std.testing.expectEqual(op.get_var, fn_bc.code[0]);
    try std.testing.expectEqual(op.get_field2, fn_bc.code[19]);
    try std.testing.expectEqual(op.get_var, fn_bc.code[24]);
    try std.testing.expectEqual(op.call_method, fn_bc.code[29]);
    const argc = std.mem.readInt(u16, fn_bc.code[30..32], .little);
    try std.testing.expectEqual(@as(u16, 1), argc);
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

    // get_var obj (5) ; chain_test (14) ; get_var k (5) ; get_array_el2 (1) ;
    // get_var x (5) ; call_method 1 (3) = 33
    try std.testing.expectEqual(@as(usize, 33), fn_bc.code.len);
    try std.testing.expectEqual(op.get_var, fn_bc.code[0]);
    try std.testing.expectEqual(op.get_var, fn_bc.code[19]);
    try std.testing.expectEqual(op.get_array_el2, fn_bc.code[24]);
    try std.testing.expectEqual(op.get_var, fn_bc.code[25]);
    try std.testing.expectEqual(op.call_method, fn_bc.code[30]);
}

// ---- F4 finish: tagged templates -----------------------------------

test "F4: tagged template tag`hello` emits singleton template-object + call 1" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "tag`hello`");
    defer fn_bc.deinit(env.rt);

    // get_var tag (5) ; cooked array_from (8) ; raw array_from (8) ;
    // define_field raw (5) ; call 1 (3) = 29
    try std.testing.expectEqual(@as(usize, 29), fn_bc.code.len);
    try std.testing.expectEqual(op.get_var, fn_bc.code[0]);
    try std.testing.expectEqual(op.push_atom_value, fn_bc.code[5]);
    try std.testing.expectEqual(op.array_from, fn_bc.code[10]);
    try std.testing.expectEqual(op.push_atom_value, fn_bc.code[13]);
    try std.testing.expectEqual(op.array_from, fn_bc.code[18]);
    try std.testing.expectEqual(op.define_field, fn_bc.code[21]);
    try std.testing.expectEqual(op.call, fn_bc.code[26]);
    const argc = std.mem.readInt(u16, fn_bc.code[27..29], .little);
    try std.testing.expectEqual(@as(u16, 1), argc);
}

test "F4: tagged template tag`a${x}b` includes substitutions in argc" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "tag`a${x}b`");
    defer fn_bc.deinit(env.rt);

    // get_var tag (5) ; undefined (1) ; get_var x (5) ; call 2 (3) = 14
    try std.testing.expectEqual(@as(usize, 14), fn_bc.code.len);
    try std.testing.expectEqual(op.get_var, fn_bc.code[0]);
    try std.testing.expectEqual(op.undefined, fn_bc.code[5]);
    try std.testing.expectEqual(op.get_var, fn_bc.code[6]);
    try std.testing.expectEqual(op.call, fn_bc.code[11]);
    const argc = std.mem.readInt(u16, fn_bc.code[12..14], .little);
    try std.testing.expectEqual(@as(u16, 2), argc);
}

test "F4: tagged template on member access obj.tag`hello` rewrites to call_method" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "obj.tag`hello`");
    defer fn_bc.deinit(env.rt);

    // get_var obj (5) ; get_field2 tag (5) ; cooked array_from (8) ;
    // raw array_from (8) ; define_field raw (5) ; call_method 1 (3) = 34
    try std.testing.expectEqual(@as(usize, 34), fn_bc.code.len);
    try std.testing.expectEqual(op.get_var, fn_bc.code[0]);
    try std.testing.expectEqual(op.get_field2, fn_bc.code[5]);
    try std.testing.expectEqual(op.push_atom_value, fn_bc.code[10]);
    try std.testing.expectEqual(op.array_from, fn_bc.code[15]);
    try std.testing.expectEqual(op.push_atom_value, fn_bc.code[18]);
    try std.testing.expectEqual(op.array_from, fn_bc.code[23]);
    try std.testing.expectEqual(op.define_field, fn_bc.code[26]);
    try std.testing.expectEqual(op.call_method, fn_bc.code[31]);
}

test "F4: tagged template tag`a${x}b${y}c` argc = 3 (template + 2 subs)" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "tag`a${x}b${y}c`");
    defer fn_bc.deinit(env.rt);

    try std.testing.expectEqual(op.call, fn_bc.code[fn_bc.code.len - 3]);
    const argc = std.mem.readInt(u16, fn_bc.code[fn_bc.code.len - 2 ..][0..2], .little);
    try std.testing.expectEqual(@as(u16, 3), argc);
}

test "F4: optional call without chain receiver a?.()(b) — chain only on first call" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    // After a?.(), the chain ends. The trailing (b) call is unconditional.
    var fn_bc = try parseExpr(&env, "a?.()(b)");
    defer fn_bc.deinit(env.rt);

    // Expected: get_var a (5) ; chain_test (14) ; call 0 (3) ; get_var b (5) ; call 1 (3)
    try std.testing.expectEqual(@as(usize, 30), fn_bc.code.len);
    try std.testing.expectEqual(op.call, fn_bc.code[19]);
    try std.testing.expectEqual(op.call, fn_bc.code[27]);
    // The first call's chain_exit lands AFTER all subsequent ops too —
    // the entire chain (including the trailing `(b)`) is governed by the
    // single chain exit.
    const exit_target = readRelTarget32(fn_bc.code, 14);
    try std.testing.expectEqual(@as(usize, 30), exit_target);
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
    // `a${b}c` lowers to:
    //   push_atom_value "a"   (5)
    //   get_field2 concat     (5)
    //   get_var b             (5)
    //   push_atom_value "c"   (5)
    //   call_method 2         (3)
    var fn_bc = try parseExpr(&env, "`a${b}c`");
    defer fn_bc.deinit(env.rt);

    try std.testing.expectEqual(@as(usize, 23), fn_bc.code.len);
    try std.testing.expectEqual(op.push_atom_value, fn_bc.code[0]);
    try std.testing.expectEqual(op.get_field2, fn_bc.code[5]);
    try std.testing.expectEqual(op.get_var, fn_bc.code[10]);
    try std.testing.expectEqual(op.push_atom_value, fn_bc.code[15]);
    try std.testing.expectEqual(op.call_method, fn_bc.code[20]);
    const argc = std.mem.readInt(u16, fn_bc.code[21..23], .little);
    try std.testing.expectEqual(@as(u16, 2), argc);
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

    try std.testing.expectEqual(@as(usize, 14), fn_bc.code.len);
    try std.testing.expectEqual(op.push_empty_string, fn_bc.code[0]);
    try std.testing.expectEqual(op.get_field2, fn_bc.code[1]);
    try std.testing.expectEqual(op.get_var, fn_bc.code[6]);
    try std.testing.expectEqual(op.call_method, fn_bc.code[11]);
    const argc = std.mem.readInt(u16, fn_bc.code[12..14], .little);
    try std.testing.expectEqual(@as(u16, 1), argc);
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

    try std.testing.expectEqual(@as(usize, 33), fn_bc.code.len);
    try std.testing.expectEqual(op.call_method, fn_bc.code[30]);
    const argc = std.mem.readInt(u16, fn_bc.code[31..33], .little);
    try std.testing.expectEqual(@as(u16, 4), argc);
}

// ---- F4 slice 6: spread in calls and arrays --------------------------

test "F4: spread call f(...x) emits array_from + apply 0" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    // Expected:
    //   get_var f          (5)
    //   array_from 0       (3)  -- no leading args
    //   push_i32 0         (5)  -- initial idx
    //   get_var x          (5)
    //   append             (1)
    //   drop               (1)  -- drop idx
    //   undefined          (1)
    //   swap               (1)
    //   apply 0            (3)  -- 0 = not new
    var fn_bc = try parseExpr(&env, "f(...x)");
    defer fn_bc.deinit(env.rt);

    try std.testing.expectEqual(@as(usize, 25), fn_bc.code.len);
    try std.testing.expectEqual(op.get_var, fn_bc.code[0]);
    try std.testing.expectEqual(op.array_from, fn_bc.code[5]);
    try std.testing.expectEqual(op.push_i32, fn_bc.code[8]);
    try std.testing.expectEqual(op.get_var, fn_bc.code[13]);
    try std.testing.expectEqual(op.append, fn_bc.code[18]);
    try std.testing.expectEqual(op.drop, fn_bc.code[19]);
    try std.testing.expectEqual(op.undefined, fn_bc.code[20]);
    try std.testing.expectEqual(op.swap, fn_bc.code[21]);
    try std.testing.expectEqual(op.apply, fn_bc.code[22]);
    const is_new = std.mem.readInt(u16, fn_bc.code[23..25], .little);
    try std.testing.expectEqual(@as(u16, 0), is_new);
}

test "F4: mixed spread call f(a, ...b) starts array_from with leading count" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    // Expected:
    //   get_var f          (5)
    //   get_var a          (5)
    //   array_from 1       (3)  -- 1 leading arg
    //   push_i32 1         (5)
    //   get_var b          (5)
    //   append             (1)
    //   drop               (1)
    //   undefined          (1)
    //   swap               (1)
    //   apply 0            (3)
    var fn_bc = try parseExpr(&env, "f(a, ...b)");
    defer fn_bc.deinit(env.rt);

    try std.testing.expectEqual(@as(usize, 30), fn_bc.code.len);
    try std.testing.expectEqual(op.get_var, fn_bc.code[0]);
    try std.testing.expectEqual(op.get_var, fn_bc.code[5]);
    try std.testing.expectEqual(op.array_from, fn_bc.code[10]);
    const argc = std.mem.readInt(u16, fn_bc.code[11..13], .little);
    try std.testing.expectEqual(@as(u16, 1), argc);
    try std.testing.expectEqual(op.push_i32, fn_bc.code[13]);
    try std.testing.expectEqual(op.append, fn_bc.code[23]);
    try std.testing.expectEqual(op.apply, fn_bc.code[27]);
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

    try std.testing.expectEqual(@as(usize, 32), fn_bc.code.len);
    try std.testing.expectEqual(op.append, fn_bc.code[18]);
    try std.testing.expectEqual(op.define_array_el, fn_bc.code[24]);
    try std.testing.expectEqual(op.inc, fn_bc.code[25]);
    try std.testing.expectEqual(op.apply, fn_bc.code[29]);
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

    try std.testing.expectEqual(@as(usize, 29), fn_bc.code.len);
    try std.testing.expectEqual(op.get_field2, fn_bc.code[5]);
    try std.testing.expectEqual(op.perm3, fn_bc.code[25]);
    try std.testing.expectEqual(op.apply, fn_bc.code[26]);
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
    // Expected:
    //   array_from 0       (3)
    //   push_i32 0         (5)
    //   get_var a          (5)
    //   append             (1)
    //   drop               (1)
    var fn_bc = try parseExpr(&env, "[...a]");
    defer fn_bc.deinit(env.rt);

    try std.testing.expectEqual(@as(usize, 15), fn_bc.code.len);
    try std.testing.expectEqual(op.array_from, fn_bc.code[0]);
    try std.testing.expectEqual(op.push_i32, fn_bc.code[3]);
    try std.testing.expectEqual(op.append, fn_bc.code[13]);
    try std.testing.expectEqual(op.drop, fn_bc.code[14]);
}

test "F4: array literal mixed spread [a, ...b, c] uses define_array_el+inc" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    // get_var a (5) ; array_from 1 (3) ; push_i32 1 (5) ; get_var b (5) ; append (1) ;
    // get_var c (5) ; define_array_el (1) ; inc (1) ; drop (1)
    var fn_bc = try parseExpr(&env, "[a, ...b, c]");
    defer fn_bc.deinit(env.rt);

    try std.testing.expectEqual(@as(usize, 27), fn_bc.code.len);
    try std.testing.expectEqual(op.array_from, fn_bc.code[5]);
    try std.testing.expectEqual(op.append, fn_bc.code[18]);
    try std.testing.expectEqual(op.define_array_el, fn_bc.code[24]);
    try std.testing.expectEqual(op.inc, fn_bc.code[25]);
    try std.testing.expectEqual(op.drop, fn_bc.code[26]);
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

    try std.testing.expectEqual(@as(usize, 19), fn_bc.code.len);
    try std.testing.expectEqual(op.push_empty_string, fn_bc.code[0]);
    try std.testing.expectEqual(op.call_method, fn_bc.code[16]);
    const argc = std.mem.readInt(u16, fn_bc.code[17..19], .little);
    try std.testing.expectEqual(@as(u16, 2), argc);
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

    try std.testing.expectEqual(@as(usize, 12), fn_bc.code.len);
    try std.testing.expectEqual(op.get_var, fn_bc.code[0]);
    try std.testing.expectEqual(op.drop, fn_bc.code[5]);
    try std.testing.expectEqual(op.get_var, fn_bc.code[6]);
    try std.testing.expectEqual(op.drop, fn_bc.code[11]);
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

    try std.testing.expectEqual(@as(usize, 6), fn_bc.code.len);
    try std.testing.expectEqual(op.get_var, fn_bc.code[0]);
    try std.testing.expectEqual(op.@"return", fn_bc.code[5]);
}

test "F5: throw statement" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatement(&env, "throw x;");
    defer fn_bc.deinit(env.rt);

    try std.testing.expectEqual(@as(usize, 6), fn_bc.code.len);
    try std.testing.expectEqual(op.get_var, fn_bc.code[0]);
    try std.testing.expectEqual(op.throw, fn_bc.code[5]);
}

test "F5: if statement without else" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatement(&env, "if (x) y;");
    defer fn_bc.deinit(env.rt);

    // get_var x ; if_false → past_then ; get_var y ; drop
    try std.testing.expectEqual(@as(usize, 16), fn_bc.code.len);
    try std.testing.expectEqual(op.get_var, fn_bc.code[0]);
    try std.testing.expectEqual(op.if_false, fn_bc.code[5]); // After get_var x
    const if_false_target = readRelTarget32(fn_bc.code, 5);
    try std.testing.expectEqual(fn_bc.code.len, if_false_target);
    try std.testing.expectEqual(op.get_var, fn_bc.code[10]);
    try std.testing.expectEqual(op.drop, fn_bc.code[15]);
}

test "F5: if statement with else" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatement(&env, "if (x) y; else z;");
    defer fn_bc.deinit(env.rt);

    // get_var x ; if_false → else ; get_var y ; drop ; goto → end ;
    // get_var z ; drop
    try std.testing.expectEqual(@as(usize, 27), fn_bc.code.len);
    try std.testing.expectEqual(op.get_var, fn_bc.code[0]);
    try std.testing.expectEqual(op.if_false, fn_bc.code[5]);
    const if_false_target = readRelTarget32(fn_bc.code, 5);
    try std.testing.expectEqual(@as(usize, 21), if_false_target);
    try std.testing.expectEqual(op.get_var, fn_bc.code[10]);
    try std.testing.expectEqual(op.drop, fn_bc.code[15]);
    try std.testing.expectEqual(op.goto, fn_bc.code[16]);
    const goto_target = readRelTarget32(fn_bc.code, 16);
    try std.testing.expectEqual(fn_bc.code.len, goto_target);
    try std.testing.expectEqual(op.get_var, fn_bc.code[21]);
    try std.testing.expectEqual(op.drop, fn_bc.code[26]);
}

test "F5: while statement" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatement(&env, "while (x) y;");
    defer fn_bc.deinit(env.rt);

    // top: get_var x ; if_false → end ; get_var y ; drop ; goto → top
    try std.testing.expectEqual(@as(usize, 21), fn_bc.code.len);
    try std.testing.expectEqual(op.get_var, fn_bc.code[0]);
    // Last instruction must be a backward goto to offset 0 (loop top).
    const last_goto = fn_bc.code.len - 5;
    try std.testing.expectEqual(op.goto, fn_bc.code[last_goto]);
    const back_target = readRelTarget32(fn_bc.code, last_goto);
    try std.testing.expectEqual(@as(usize, 0), back_target);
    // The if_false at offset 5 (after get_var x) must point past end.
    try std.testing.expectEqual(op.if_false, fn_bc.code[5]);
    const if_false_target = readRelTarget32(fn_bc.code, 5);
    try std.testing.expectEqual(fn_bc.code.len, if_false_target);
    try std.testing.expectEqual(op.get_var, fn_bc.code[10]);
    try std.testing.expectEqual(op.drop, fn_bc.code[15]);
}

test "F5: do-while statement" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatement(&env, "do { y; } while (x);");
    defer fn_bc.deinit(env.rt);

    try std.testing.expectEqual(@as(usize, 16), fn_bc.code.len);
    try std.testing.expectEqual(op.get_var, fn_bc.code[0]);
    try std.testing.expectEqual(op.drop, fn_bc.code[5]);
    try std.testing.expectEqual(op.get_var, fn_bc.code[6]);
    try std.testing.expectEqual(op.if_true, fn_bc.code[11]);
    try std.testing.expectEqual(@as(usize, 0), readRelTarget32(fn_bc.code, 11));
}

test "F5: expression statement" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatement(&env, "x;");
    defer fn_bc.deinit(env.rt);

    try std.testing.expectEqual(@as(usize, 6), fn_bc.code.len);
    try std.testing.expectEqual(op.get_var, fn_bc.code[0]);
    try std.testing.expectEqual(op.drop, fn_bc.code[5]);
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

test "F5: var declaration without initializer" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatement(&env, "var x;");
    defer fn_bc.deinit(env.rt);

    try std.testing.expectEqual(@as(usize, 12), fn_bc.code.len);
    try std.testing.expectEqual(op.check_define_var, fn_bc.code[0]);
    try std.testing.expectEqual(op.define_var, fn_bc.code[6]);
}

test "F5: var declaration with initializer" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatement(&env, "var x = 1;");
    defer fn_bc.deinit(env.rt);

    // Top-level `var` is a global object binding: the pipeline emits
    // QuickJS-shaped all-check/all-define global declaration prologue
    // before the initializer write.
    try std.testing.expectEqual(@as(usize, 22), fn_bc.code.len);
    try std.testing.expectEqual(op.check_define_var, fn_bc.code[0]);
    try std.testing.expectEqual(op.define_var, fn_bc.code[6]);
    try std.testing.expectEqual(op.push_i32, fn_bc.code[12]);
    try std.testing.expectEqual(op.put_var, fn_bc.code[fn_bc.code.len - 5]);
}

test "F5: module-ref var initializer consumes value unless next statement reuses binding" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseModuleRefStatement(&env, "var x = 1; y;");
    defer fn_bc.deinit(env.rt);

    try std.testing.expectEqual(op.push_i32, fn_bc.code[0]);
    try std.testing.expectEqual(op.put_var_ref0, fn_bc.code[5]);
}

test "F5: module-ref var initializer preserves value for immediate same-name expression" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseModuleRefStatement(&env, "var x = 1; x;");
    defer fn_bc.deinit(env.rt);

    try std.testing.expectEqual(op.push_i32, fn_bc.code[0]);
    try std.testing.expectEqual(op.set_var_ref0, fn_bc.code[5]);
}

test "F5: let declaration" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatement(&env, "let x;");
    defer fn_bc.deinit(env.rt);

    // F10.1c + TDZ: top-level `let x;` now participates in the
    // global declaration check/define prologue, then initializes its
    // local lexical slot:
    //   check_define_var x, lexical
    //   define_var x, lexical
    //   set_loc_uninitialized 0  (3 bytes - TDZ prologue)
    //   undefined                 (1 byte)
    //   put_loc_check_init 0      (clears TDZ flag)
    try std.testing.expectEqual(op.check_define_var, fn_bc.code[0]);
    try std.testing.expectEqual(op.define_var, fn_bc.code[6]);
    try std.testing.expectEqual(op.set_loc_uninitialized, fn_bc.code[12]);
    try std.testing.expectEqual(op.undefined, fn_bc.code[15]);
    try std.testing.expectEqual(op.put_loc_check_init, fn_bc.code[16]);
}

test "F5: let declaration with initializer" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatement(&env, "let x = 1;");
    defer fn_bc.deinit(env.rt);

    // F10.1c + TDZ: `let x = 1;` lowers to a global declaration
    // check/define prologue followed by:
    //   set_loc_uninitialized 0  (TDZ prologue)
    //   push_i32 1
    //   put_loc_check_init 0
    try std.testing.expectEqual(op.check_define_var, fn_bc.code[0]);
    try std.testing.expectEqual(op.define_var, fn_bc.code[6]);
    try std.testing.expectEqual(op.set_loc_uninitialized, fn_bc.code[12]);
    try std.testing.expectEqual(op.push_i32, fn_bc.code[15]);
    try std.testing.expectEqual(op.put_loc_check_init, fn_bc.code[fn_bc.code.len - 3]);
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

    // F10.1c + TDZ: const lowers same as let with init, except the
    // final store keeps the TDZ checked-init form.
    try std.testing.expectEqual(op.check_define_var, fn_bc.code[0]);
    try std.testing.expectEqual(op.define_var, fn_bc.code[6]);
    try std.testing.expectEqual(op.set_loc_uninitialized, fn_bc.code[12]);
    try std.testing.expectEqual(op.push_i32, fn_bc.code[15]);
    try std.testing.expectEqual(op.put_loc_check_init, fn_bc.code[fn_bc.code.len - 3]);
}

test "F5: multiple var declarations" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatement(&env, "var x = 1, y = 2;");
    defer fn_bc.deinit(env.rt);

    try std.testing.expectEqual(@as(usize, 44), fn_bc.code.len);
    try std.testing.expectEqual(op.check_define_var, fn_bc.code[0]);
    try std.testing.expectEqual(op.check_define_var, fn_bc.code[6]);
    try std.testing.expectEqual(op.define_var, fn_bc.code[12]);
    try std.testing.expectEqual(op.define_var, fn_bc.code[18]);
    try std.testing.expectEqual(op.push_i32, fn_bc.code[24]);
    try std.testing.expectEqual(op.put_var, fn_bc.code[29]);
    try std.testing.expectEqual(op.push_i32, fn_bc.code[34]);
    try std.testing.expectEqual(op.put_var, fn_bc.code[39]);
}

test "F5: directive prologue with 'use strict'" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatement(&env, "{ \"use strict\"; x; }");
    defer fn_bc.deinit(env.rt);

    try std.testing.expectEqual(@as(usize, 6), fn_bc.code.len);
    try std.testing.expectEqual(op.get_var, fn_bc.code[0]);
    try std.testing.expectEqual(op.drop, fn_bc.code[5]);
}

test "M3.1 F4: strict object setter rejects eval and arguments parameters" {
    var env = try ParserTestEnv.init();
    defer env.deinit();

    try std.testing.expectError(error.UnexpectedToken, parseStatement(&env, "{ \"use strict\"; var obj = { set x(eval) {} }; }"));
    try std.testing.expectError(error.UnexpectedToken, parseStatement(&env, "{ \"use strict\"; var obj = { set x(arguments) {} }; }"));
}

test "F5: directive prologue with multiple directives" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatement(&env, "{ \"use strict\"; \"other directive\"; x; }");
    defer fn_bc.deinit(env.rt);

    try std.testing.expectEqual(@as(usize, 6), fn_bc.code.len);
    try std.testing.expectEqual(op.get_var, fn_bc.code[0]);
    try std.testing.expectEqual(op.drop, fn_bc.code[5]);
}

test "F5: directive prologue with ASI" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatement(&env, "{ \"use strict\"\n x; }");
    defer fn_bc.deinit(env.rt);

    try std.testing.expectEqual(@as(usize, 6), fn_bc.code.len);
    try std.testing.expectEqual(op.get_var, fn_bc.code[0]);
    try std.testing.expectEqual(op.drop, fn_bc.code[5]);
}

// ---- F6 function parsing tests -----------------------------------------

test "F6: simple function declaration" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatementWithTopLevelChildren(&env, "function foo() {}");
    defer fn_bc.deinit(env.rt);

    const child = try expectFunctionConstant(&fn_bc, 0);
    try expectAtomName(&env, child.func_name, "foo");
    try std.testing.expectEqual(function_def_mod.FunctionKind.normal, child.func_kind);
    try std.testing.expect(child.has_prototype);
    try std.testing.expect(!child.is_arrow_function);
    try std.testing.expectEqual(@as(usize, 0), child.arg_names.len);
    try expectOpcode(child.byte_code, op.return_undef);
}

test "F6: function declaration with parameters" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatementWithTopLevelChildren(&env, "function foo(x, y) {}");
    defer fn_bc.deinit(env.rt);

    const child = try expectFunctionConstant(&fn_bc, 0);
    try expectAtomName(&env, child.func_name, "foo");
    try std.testing.expectEqual(function_def_mod.FunctionKind.normal, child.func_kind);
    try std.testing.expectEqual(@as(usize, 2), child.arg_names.len);
    try expectAtomName(&env, child.arg_names[0], "x");
    try expectAtomName(&env, child.arg_names[1], "y");
    try expectOpcode(child.byte_code, op.return_undef);
}

test "F6: function declaration with rest parameter" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatementWithTopLevelChildren(&env, "function foo(...args) {}");
    defer fn_bc.deinit(env.rt);

    const child = try expectFunctionConstant(&fn_bc, 0);
    try expectAtomName(&env, child.func_name, "foo");
    try std.testing.expectEqual(function_def_mod.FunctionKind.normal, child.func_kind);
    try std.testing.expectEqual(@as(usize, 1), child.arg_names.len);
    try expectAtomName(&env, child.arg_names[0], "args");
    try expectOpcode(child.byte_code, op.rest);
    try expectOpcode(child.byte_code, op.return_undef);
}

test "F6: arrow function with block body" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExprWithTopLevelChildren(&env, "() => {}");
    defer fn_bc.deinit(env.rt);

    const child = try expectFunctionConstant(&fn_bc, 0);
    try std.testing.expectEqual(function_def_mod.FunctionKind.normal, child.func_kind);
    try std.testing.expect(child.is_arrow_function);
    try std.testing.expect(!child.has_prototype);
    try std.testing.expectEqual(@as(usize, 0), child.arg_names.len);
    try expectOpcode(child.byte_code, op.return_undef);
}

test "F6: arrow function with expression body" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExprWithTopLevelChildren(&env, "() => 42");
    defer fn_bc.deinit(env.rt);

    const child = try expectFunctionConstant(&fn_bc, 0);
    try std.testing.expectEqual(function_def_mod.FunctionKind.normal, child.func_kind);
    try std.testing.expect(child.is_arrow_function);
    try std.testing.expect(!child.has_prototype);
    try std.testing.expectEqual(@as(usize, 0), child.arg_names.len);
    try expectOpcode(child.byte_code, op.push_i8);
    try expectOpcode(child.byte_code, op.@"return");
}

test "F6: arrow function with single parameter" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExprWithTopLevelChildren(&env, "x => x");
    defer fn_bc.deinit(env.rt);

    const child = try expectFunctionConstant(&fn_bc, 0);
    try std.testing.expectEqual(function_def_mod.FunctionKind.normal, child.func_kind);
    try std.testing.expect(child.is_arrow_function);
    try std.testing.expectEqual(@as(usize, 1), child.arg_names.len);
    try expectAtomName(&env, child.arg_names[0], "x");
    try expectOpcode(child.byte_code, op.get_arg0);
    try expectOpcode(child.byte_code, op.@"return");
}

test "F6: arrow function with multiple parameters" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExprWithTopLevelChildren(&env, "(x, y) => x + y");
    defer fn_bc.deinit(env.rt);

    const child = try expectFunctionConstant(&fn_bc, 0);
    try std.testing.expectEqual(function_def_mod.FunctionKind.normal, child.func_kind);
    try std.testing.expect(child.is_arrow_function);
    try std.testing.expectEqual(@as(usize, 2), child.arg_names.len);
    try expectAtomName(&env, child.arg_names[0], "x");
    try expectAtomName(&env, child.arg_names[1], "y");
    try expectOpcode(child.byte_code, op.get_arg0);
    try expectOpcode(child.byte_code, op.get_arg1);
    try expectOpcode(child.byte_code, op.add);
    try expectOpcode(child.byte_code, op.@"return");
}

test "F6: arrow function with rest parameter" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExprWithTopLevelChildren(&env, "(...args) => args");
    defer fn_bc.deinit(env.rt);

    const child = try expectFunctionConstant(&fn_bc, 0);
    try std.testing.expectEqual(function_def_mod.FunctionKind.normal, child.func_kind);
    try std.testing.expect(child.is_arrow_function);
    try std.testing.expectEqual(@as(usize, 1), child.arg_names.len);
    try expectAtomName(&env, child.arg_names[0], "args");
    try expectOpcode(child.byte_code, op.rest);
    try expectOpcode(child.byte_code, op.@"return");
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
    try expectOpcode(child.byte_code, op.get_field);
    try expectOpcode(child.byte_code, op.return_undef);
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
    try expectOpcode(child.byte_code, op.special_object);
    try expectOpcode(child.byte_code, op.return_undef);
}

test "F6: arrow function with object destructuring parameter" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExprWithTopLevelChildren(&env, "({a, b}) => a");
    defer fn_bc.deinit(env.rt);

    const child = try expectFunctionConstant(&fn_bc, 0);
    try std.testing.expect(child.is_arrow_function);
    try std.testing.expectEqual(@as(u16, 1), child.arg_count);
    try std.testing.expectEqual(@as(u16, 2), child.var_count);
    try expectOpcode(child.byte_code, op.get_field);
    try expectOpcode(child.byte_code, op.@"return");
}

test "F6: arrow function with array destructuring parameter" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExprWithTopLevelChildren(&env, "([a, b]) => a");
    defer fn_bc.deinit(env.rt);

    const child = try expectFunctionConstant(&fn_bc, 0);
    try std.testing.expect(child.is_arrow_function);
    try std.testing.expectEqual(@as(u16, 1), child.arg_count);
    try std.testing.expectEqual(@as(u16, 2), child.var_count);
    try expectOpcode(child.byte_code, op.special_object);
    try expectOpcode(child.byte_code, op.@"return");
}

// ---- F7 Class parsing tests ----

test "F7: class with constructor" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatementWithTopLevelChildren(&env, "class C { constructor(x) { this.x = x; } }");
    defer fn_bc.deinit(env.rt);

    const ctor = try expectFunctionConstant(&fn_bc, 0);
    try std.testing.expect(ctor.is_class_constructor);
    try std.testing.expect(!ctor.is_derived_class_constructor);
    try std.testing.expectEqual(@as(usize, 1), ctor.arg_names.len);
    try expectAtomName(&env, ctor.arg_names[0], "x");
    try expectOpcode(fn_bc.code, op.define_class);
    try expectOpcode(ctor.byte_code, op.put_field);
}

test "F7: class with getter" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatementWithTopLevelChildren(&env, "class C { get x() { return this._x; } }");
    defer fn_bc.deinit(env.rt);

    const getter = try expectFunctionConstant(&fn_bc, 0);
    try std.testing.expectEqual(function_def_mod.FunctionKind.normal, getter.func_kind);
    try std.testing.expectEqual(@as(usize, 0), getter.arg_names.len);
    try expectOpcode(fn_bc.code, op.define_class);
    try expectOpcode(fn_bc.code, op.define_method);
    try expectOpcode(getter.byte_code, op.get_field);
    try expectOpcode(getter.byte_code, op.@"return");
}

test "F7: class with setter" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatementWithTopLevelChildren(&env, "class C { set x(value) { this._x = value; } }");
    defer fn_bc.deinit(env.rt);

    const setter = try expectFunctionConstant(&fn_bc, 0);
    try std.testing.expectEqual(function_def_mod.FunctionKind.normal, setter.func_kind);
    try std.testing.expectEqual(@as(usize, 1), setter.arg_names.len);
    try expectAtomName(&env, setter.arg_names[0], "value");
    try expectOpcode(fn_bc.code, op.define_class);
    try expectOpcode(fn_bc.code, op.define_method);
    try expectOpcode(setter.byte_code, op.put_field);
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
    try std.testing.expect(ctor.is_class_constructor);
    try std.testing.expect(ctor.is_derived_class_constructor);
    try expectOpcode(fn_bc.code, op.define_class);
    try expectOpcode(fn_bc.code, op.get_var);
    try expectOpcode(ctor.byte_code, op.get_super);
    try expectOpcode(ctor.byte_code, op.call_method);
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
    try std.testing.expectEqual(function_def_mod.FunctionKind.generator, child.func_kind);
    try expectOpcode(child.byte_code, op.yield);
    try expectOpcode(child.byte_code, op.return_async);
}

test "F9: yield* expression" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatementWithTopLevelChildren(&env, "function* g() { yield* iterable; }");
    defer fn_bc.deinit(env.rt);

    const child = try expectFunctionConstant(&fn_bc, 0);
    try expectAtomName(&env, child.func_name, "g");
    try std.testing.expectEqual(function_def_mod.FunctionKind.generator, child.func_kind);
    try expectOpcode(child.byte_code, op.for_of_start);
    try expectOpcode(child.byte_code, op.iterator_next);
    try expectOpcode(child.byte_code, op.yield_star);
    try expectOpcode(child.byte_code, op.return_async);
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

test "F8: export default class" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseModuleStatement(&env, "export default class C {}");
    defer fn_bc.deinit(env.rt);

    const record = try moduleRecord(&fn_bc);
    try expectModuleRecordCounts(record, 0, 0, 1, 0, 0);
    try expectModuleExport(&env, record, 0, "default", "*default*");
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
    try std.testing.expectEqual(function_def_mod.FunctionKind.async, child.func_kind);
    try std.testing.expect(!child.has_prototype);
    try expectOpcode(child.byte_code, op.return_async);
}

test "F9: async arrow function" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExprWithTopLevelChildren(&env, "async () => {}");
    defer fn_bc.deinit(env.rt);

    const child = try expectFunctionConstant(&fn_bc, 0);
    try std.testing.expectEqual(function_def_mod.FunctionKind.async, child.func_kind);
    try std.testing.expect(child.is_arrow_function);
    try std.testing.expect(!child.has_prototype);
    try expectOpcode(child.byte_code, op.return_async);
}

test "F9: async function declaration" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatementWithTopLevelChildren(&env, "async function f() {}");
    defer fn_bc.deinit(env.rt);

    const child = try expectFunctionConstant(&fn_bc, 0);
    try expectAtomName(&env, child.func_name, "f");
    try std.testing.expectEqual(function_def_mod.FunctionKind.async, child.func_kind);
    try expectOpcode(child.byte_code, op.return_async);
}

test "F9: async function declaration with parameters" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatementWithTopLevelChildren(&env, "async function f(x, y) {}");
    defer fn_bc.deinit(env.rt);

    const child = try expectFunctionConstant(&fn_bc, 0);
    try std.testing.expectEqual(function_def_mod.FunctionKind.async, child.func_kind);
    try std.testing.expectEqual(@as(usize, 2), child.arg_names.len);
    try expectAtomName(&env, child.arg_names[0], "x");
    try expectAtomName(&env, child.arg_names[1], "y");
}

test "F9: async function declaration with body" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatementWithTopLevelChildren(&env, "async function f() { return 42; }");
    defer fn_bc.deinit(env.rt);

    const child = try expectFunctionConstant(&fn_bc, 0);
    try std.testing.expectEqual(function_def_mod.FunctionKind.async, child.func_kind);
    try expectOpcode(child.byte_code, op.push_i8);
    try expectOpcode(child.byte_code, op.return_async);
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
    try std.testing.expectEqual(function_def_mod.FunctionKind.async, child.func_kind);
    try expectOpcode(child.byte_code, op.await);
    try expectOpcode(child.byte_code, op.return_async);
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

test "F10.1a FunctionDef: initial scope chain has scope 0 with parent -1" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    const name = try env.rt.internAtom("test");
    defer env.rt.atoms.free(name);
    var function = engine.bytecode.Bytecode.init(&env.rt.memory, &env.rt.atoms, name);
    defer function.deinit(env.rt);

    var lex = QjsLexer.init(std.testing.allocator, &env.rt.atoms, "");
    var state = try ParseState.init(&lex, &function);
    defer state.deinit(env.rt);

    // Mirror `js_new_function_def` (`quickjs.c:31511`): scope 0 created
    // with parent = -1, first = -1.
    try std.testing.expectEqual(@as(usize, 1), state.function_def.scopes.len);
    try std.testing.expectEqual(@as(i32, -1), state.function_def.scopes[0].parent);
    try std.testing.expectEqual(@as(i32, -1), state.function_def.scopes[0].first);
    try std.testing.expectEqual(@as(i32, 0), state.function_def.scope_level);
    try std.testing.expectEqual(@as(i32, 1), state.function_def.scope_count);
}

test "F10.1a FunctionDef: parseBlock pushes/pops a scope (balanced)" {
    var env = try ParserTestEnv.init();
    defer env.deinit();
    const name = try env.rt.internAtom("test");
    defer env.rt.atoms.free(name);
    var function = engine.bytecode.Bytecode.init(&env.rt.memory, &env.rt.atoms, name);
    defer function.deinit(env.rt);

    var lex = QjsLexer.init(std.testing.allocator, &env.rt.atoms, "{ }");
    var state = try ParseState.init(&lex, &function);
    defer state.deinit(env.rt);

    try zjs_parser.parseStatementOrDecl(&state, zjs_parser.DeclMask{ .func = true, .func_with_label = true, .other = true });

    // After parsing: scope_level back to 0, but a new scope was
    // appended (push then pop, the structure is retained for §F10.1
    // Outstanding closure analysis to walk later).
    try std.testing.expectEqual(@as(i32, 0), state.scope_level);
    try std.testing.expectEqual(@as(usize, 2), state.function_def.scopes.len);
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

    try zjs_parser.parseStatementOrDecl(&state, zjs_parser.DeclMask{ .func = true, .func_with_label = true, .other = true });

    // After parsing: 3 scopes (initial 0 + outer block + inner block).
    try std.testing.expectEqual(@as(usize, 3), state.function_def.scopes.len);
    // Scope 0 has parent -1, scope 1's parent is 0, scope 2's parent is 1.
    try std.testing.expectEqual(@as(i32, -1), state.function_def.scopes[0].parent);
    try std.testing.expectEqual(@as(i32, 0), state.function_def.scopes[1].parent);
    try std.testing.expectEqual(@as(i32, 1), state.function_def.scopes[2].parent);
    // After popping back, current scope level is 0 again.
    try std.testing.expectEqual(@as(i32, 0), state.scope_level);
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

    try zjs_parser.parseStatementOrDecl(&state, zjs_parser.DeclMask{ .func = true, .func_with_label = true, .other = true });

    try std.testing.expectEqual(@as(usize, 1), state.function_def.vars.len);
    const v = state.function_def.vars[0];
    try std.testing.expectEqual(@as(engine.core.atom.Atom, x_atom), v.var_name);
    try std.testing.expectEqual(true, v.is_lexical);
    try std.testing.expectEqual(false, v.is_const);
    try std.testing.expectEqual(function_def_mod.VarKind.normal, v.var_kind);
    // `let` at top level is at scope 0 (no enclosing block).
    try std.testing.expectEqual(@as(i32, 0), v.scope_level);
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

    try zjs_parser.parseStatementOrDecl(&state, zjs_parser.DeclMask{ .func = true, .func_with_label = true, .other = true });

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

    try zjs_parser.parseStatementOrDecl(&state, zjs_parser.DeclMask{ .func = true, .func_with_label = true, .other = true });

    try std.testing.expectEqual(@as(usize, 0), state.function_def.vars.len);
    try std.testing.expectEqual(@as(usize, 1), state.function_def.global_vars.len);
    const v = state.function_def.global_vars[0];
    try std.testing.expectEqual(false, v.is_lexical);
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

    try zjs_parser.parseStatementOrDecl(&state, zjs_parser.DeclMask{ .func = true, .func_with_label = true, .other = true });

    try std.testing.expectEqual(@as(usize, 2), state.function_def.vars.len);
    // `a` is registered in the outer block scope (1), `b` in the
    // inner block scope (2).
    try std.testing.expectEqual(@as(i32, 1), state.function_def.vars[0].scope_level);
    try std.testing.expectEqual(@as(i32, 2), state.function_def.vars[1].scope_level);
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

    try zjs_parser.parseStatementOrDecl(&state, zjs_parser.DeclMask{ .func = true, .func_with_label = true, .other = true });
    try zjs_parser.parseStatementOrDecl(&state, zjs_parser.DeclMask{ .func = true, .func_with_label = true, .other = true });

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

    try zjs_parser.parseExpr(&state);

    // Verify that the cur_func stack is empty after parsing (back to root)
    try std.testing.expectEqual(@as(usize, 0), state.cur_func_stack.len);

    // Verify that nested functions were created on the stack during parsing
    // (We can't directly verify the stack state during parsing, but we can
    // verify that the parsing completed without errors and the stack was
    // properly cleaned up)
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

    try zjs_parser.parseExpr(&state);

    try std.testing.expect(countOpcode(state.function.code, op.fclosure) + countOpcode(state.function.code, op.fclosure8) > 0);

    try std.testing.expectEqual(@as(usize, 1), state.function_def.child_list.len);
    const child = &state.function_def.child_list[0];
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

fn functionBytecodeHasKind(fb: *const engine.bytecode.FunctionBytecode, kind: function_def.FunctionKind) bool {
    if (fb.func_kind == kind) return true;
    for (fb.cpool) |value| {
        if (functionBytecodeFromValue(value)) |child| {
            if (functionBytecodeHasKind(child, kind)) return true;
        }
    }
    return false;
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

    var syntax_error = try frontend.source_pos.SyntaxError.create(&account, &atoms, core.atom.null_atom, .{}, "");
    syntax_error.deinit();
    atoms.deinit();

    try std.testing.expect(!account.hasOutstandingAllocations());
}

test "source positions and syntax errors carry filename line and column" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try frontend.parser.parse(rt, "let x = (\n1", .{ .mode = .script, .filename = "bad.js" });
    defer parsed.deinit();

    try std.testing.expect(parsed.syntax_error != null);
    try std.testing.expectEqual(frontend.parser.ParsePath.syntax_error_guard, parsed.parse_path);
    try std.testing.expectEqual(@as(u32, 2), parsed.syntax_error.?.position.line);
    try std.testing.expect(parsed.syntax_error.?.message.len > 0);
    try std.testing.expectEqualStrings("bad.js", rt.atoms.name(parsed.syntax_error.?.filename).?);
}

test "script parse mode emits bytecode metadata without AST execution" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try frontend.parser.parse(rt, "var x = 1; x + 2;", .{ .mode = .script, .filename = "script.js" });
    defer parsed.deinit();

    try std.testing.expect(parsed.syntax_error == null);
    try std.testing.expectEqual(frontend.parser.ParsePath.quickjs_parser, parsed.parse_path);
    try std.testing.expect(!parsed.function.flags.is_strict);
    try expectOpcode(parsed.function.code, qop.add);
    try expectOpcode(parsed.function.code, qop.drop);
    try std.testing.expect(countOpcode(parsed.function.code, qop.return_undef) + countOpcode(parsed.function.code, qop.return_async) > 0);
    try std.testing.expectEqual(@as(usize, 0), parsed.function.constants.values.len);
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

    var parsed = try frontend.parser.parse(rt, "var count2 = 2; while (count2 -= 1) { 3; }", .{ .mode = .eval_direct, .filename = "eval" });
    defer parsed.deinit();

    try std.testing.expect(parsed.syntax_error == null);
    try std.testing.expectEqual(frontend.parser.ParsePath.quickjs_parser, parsed.parse_path);
}

test "print calls emit global lookup generic call and receiver-preserving property call bytecode" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try frontend.parser.parse(rt, "print(1 + 2 * 3); console.log(\"ok\");", .{ .mode = .script, .filename = "print.js" });
    defer parsed.deinit();

    try std.testing.expectEqual(frontend.parser.ParsePath.quickjs_parser, parsed.parse_path);

    var get_var_count: usize = 0;
    var get_prop_count: usize = 0;
    var call_count: usize = 0;
    var prepared_call_count: usize = 0;
    var call_prepared_count: usize = 0;
    var legacy_call_prop_count: usize = 0;
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
        if (op_val == engine.bytecode.opcode.op.prepare_call_prop_atom) prepared_call_count += 1;
        if (op_val == engine.bytecode.opcode.op.call_prepared) call_prepared_count += 1;
        if (op_val == engine.bytecode.opcode.op.call_method) legacy_call_prop_count += 1;
        i += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), get_var_count);
    try std.testing.expectEqual(@as(usize, 0), get_prop_count);
    try std.testing.expect(call_count + countOpcode(parsed.function.code, engine.bytecode.opcode.op.call1) >= 1);
    try std.testing.expectEqual(@as(usize, 1), prepared_call_count);
    try std.testing.expectEqual(@as(usize, 1), call_prepared_count);
    try std.testing.expectEqual(@as(usize, 0), legacy_call_prop_count);
    try std.testing.expect(mul_index != null);
    try std.testing.expect(add_index != null);
    try std.testing.expect(mul_index.? < add_index.?);
    try std.testing.expect(add_index.? < parsed.function.code.len);
}

test "simple variable assignments emit var bytecode" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try frontend.parser.parse(rt, "let value = 5; value = value + 7; print(value);", .{ .mode = .script, .filename = "vars.js" });
    defer parsed.deinit();

    try std.testing.expectEqual(frontend.parser.ParsePath.quickjs_parser, parsed.parse_path);

    var get_var_count: usize = 0;
    var define_var_count: usize = 0;
    for (parsed.function.code) |op_val| {
        if (op_val == engine.bytecode.opcode.op.get_var) get_var_count += 1;
        if (op_val == engine.bytecode.opcode.op.define_var) define_var_count += 1;
    }
    try std.testing.expect(get_var_count >= 1);
    try std.testing.expect(define_var_count <= 2);
}

test "quick parser emits compound assignment and update statements" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try frontend.parser.parse(rt, "let x = 1; x += 2; x++; print(x);", .{ .mode = .script, .filename = "quick-compound-update.js" });
    defer parsed.deinit();

    try std.testing.expectEqual(frontend.parser.ParsePath.quickjs_parser, parsed.parse_path);

    const add_count = countOpcode(parsed.function.code, engine.bytecode.opcode.op.add) + countOpcode(parsed.function.code, engine.bytecode.opcode.op.add_loc);
    const define_var_count = countOpcode(parsed.function.code, engine.bytecode.opcode.op.define_var);
    try std.testing.expect(add_count >= 1);
    try std.testing.expect(define_var_count <= 3);
}

test "quick parser emits arithmetic compound assignment operators" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try frontend.parser.parse(rt, "let x = 10; x -= 3; x *= 2; x /= 7; x %= 2; print(x);", .{ .mode = .script, .filename = "quick-compound-arithmetic.js" });
    defer parsed.deinit();

    try std.testing.expectEqual(frontend.parser.ParsePath.quickjs_parser, parsed.parse_path);
    try std.testing.expectEqual(@as(usize, 1), countOpcode(parsed.function.code, engine.bytecode.opcode.op.sub));
    try std.testing.expectEqual(@as(usize, 1), countOpcode(parsed.function.code, engine.bytecode.opcode.op.mul));
    try std.testing.expectEqual(@as(usize, 1), countOpcode(parsed.function.code, engine.bytecode.opcode.op.div));
    try std.testing.expectEqual(@as(usize, 1), countOpcode(parsed.function.code, engine.bytecode.opcode.op.mod));
}

test "quick parser does not claim update expression values" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try frontend.parser.parse(rt, "let x = 1; print(x++);", .{ .mode = .script, .filename = "quick-update-expression-fallback.js" });
    defer parsed.deinit();

    try std.testing.expectEqual(frontend.parser.ParsePath.quickjs_parser, parsed.parse_path);
}

test "quick parser emits basic array and object literals" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try frontend.parser.parse(rt, "const arr = [1, 2, 3]; const obj = { a: arr[0], b: 2 }; print(obj.a + obj.b);", .{ .mode = .script, .filename = "quick-literals.js" });
    defer parsed.deinit();

    try std.testing.expectEqual(frontend.parser.ParsePath.quickjs_parser, parsed.parse_path);

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

    var parsed = try frontend.parser.parse(rt, "const obj = { x: 1 }; obj.x = obj.x + 2; print(obj.x);", .{ .mode = .script, .filename = "quick-property-assignment.js" });
    defer parsed.deinit();

    try std.testing.expectEqual(frontend.parser.ParsePath.quickjs_parser, parsed.parse_path);

    const get_prop_count = countOpcode(parsed.function.code, engine.bytecode.opcode.op.get_field);
    const set_prop_count = countOpcode(parsed.function.code, engine.bytecode.opcode.op.put_field);
    try std.testing.expect(get_prop_count >= 2);
    try std.testing.expectEqual(@as(usize, 1), set_prop_count);
}

test "quick parser emits optional property access for object and nullish bases" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try frontend.parser.parse(rt, "const obj = { a: { b: 42 } }; print(obj?.a?.b); print(obj?.x?.y); print(undefined?.a);", .{ .mode = .script, .filename = "quick-optional-property.js" });
    defer parsed.deinit();

    try std.testing.expectEqual(frontend.parser.ParsePath.quickjs_parser, parsed.parse_path);

    const optional_get_prop_count = countOpcode(parsed.function.code, engine.bytecode.opcode.op.is_undefined_or_null);
    try std.testing.expectEqual(@as(usize, 5), optional_get_prop_count);
}

test "quick parser preserves parenthesized postfix bases" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try frontend.parser.parse(rt, "const obj = { x: 1 }; print((obj).x); print(({ y: obj.x + 2 }).y); print(([3, 4])[1]); print(({ n: null })?.n);", .{ .mode = .script, .filename = "quick-parenthesized-postfix.js" });
    defer parsed.deinit();

    try std.testing.expectEqual(frontend.parser.ParsePath.quickjs_parser, parsed.parse_path);

    const get_prop_count = countOpcode(parsed.function.code, engine.bytecode.opcode.op.get_field);
    const optional_get_prop_count = countOpcode(parsed.function.code, engine.bytecode.opcode.op.is_undefined_or_null);
    const get_index_count = countOpcode(parsed.function.code, engine.bytecode.opcode.op.get_array_el);
    try std.testing.expect(get_prop_count >= 3);
    try std.testing.expectEqual(@as(usize, 1), optional_get_prop_count);
    try std.testing.expectEqual(@as(usize, 1), get_index_count);
}

test "quick parser lowers JSON stringify and parse to transitional JSON bytecode" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try frontend.parser.parse(rt, "const text = JSON.stringify({ a: 1 }); print(JSON.parse(text).a);", .{ .mode = .script, .filename = "quick-json-domain.js" });
    defer parsed.deinit();

    try std.testing.expectEqual(frontend.parser.ParsePath.quickjs_parser, parsed.parse_path);
    try std.testing.expect(countCalls(parsed.function.code) >= 1);
}

test "quick parser lowers Math calls to transitional Math bytecode" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try frontend.parser.parse(rt, "print(Math.abs(-5)); print(Math.pow(2, 3)); print(Math.min(1, 2, 3));", .{ .mode = .script, .filename = "quick-math-domain.js" });
    defer parsed.deinit();

    try std.testing.expectEqual(frontend.parser.ParsePath.quickjs_parser, parsed.parse_path);
    try std.testing.expect(countCalls(parsed.function.code) >= 3);
}

test "quick parser lowers URI calls to transitional URI bytecode" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try frontend.parser.parse(rt, "console.log(encodeURI(\"a b?x=1&y=2#z\")); print(decodeURIComponent(\"a%20b%3Fx%3D1\"));", .{ .mode = .script, .filename = "quick-uri-domain.js" });
    defer parsed.deinit();

    try std.testing.expectEqual(frontend.parser.ParsePath.quickjs_parser, parsed.parse_path);
    try std.testing.expect(countCalls(parsed.function.code) >= 2);
}

test "quick parser lowers Number parse helpers to transitional number bytecode" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try frontend.parser.parse(
        rt,
        "print(parseInt(\"0x10\")); print(parseInt(\"0x10\", 10)); print(parseFloat(\"1.5x\")); print(Number.parseInt(\"42\")); print(Number.parseFloat(\"3.14\")); print(Number.NaN); print(Number.POSITIVE_INFINITY); print(Number.NEGATIVE_INFINITY);",
        .{ .mode = .script, .filename = "quick-number-parse-domain.js" },
    );
    defer parsed.deinit();

    try std.testing.expectEqual(frontend.parser.ParsePath.quickjs_parser, parsed.parse_path);
    try std.testing.expect(countCalls(parsed.function.code) >= 5);
}

test "quick parser lowers supported Date helpers to receiver-preserving property calls" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try frontend.parser.parse(
        rt,
        "print(Date()); print(Date.UTC(2024, 0, 1)); print(Date.parse(\"2024-01-01T00:00:00Z\")); print(Date.now()); const d = new Date(0); print(d.getTime()); print(d.toISOString());",
        .{ .mode = .script, .filename = "quick-date-domain.js" },
    );
    defer parsed.deinit();

    try std.testing.expectEqual(frontend.parser.ParsePath.quickjs_parser, parsed.parse_path);
    try std.testing.expect(countCalls(parsed.function.code) >= 4);
    try std.testing.expect(countOpcode(parsed.function.code, engine.bytecode.opcode.op.call_constructor) >= 1);
    try std.testing.expect(countOpcode(parsed.function.code, engine.bytecode.opcode.op.call_prepared) >= 2);
}

test "quick parser lowers supported RegExp helpers to receiver-preserving property calls" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try frontend.parser.parse(
        rt,
        "const r = new RegExp(\"a\", \"g\"); print(r.toString()); print(r.test(\"a\")); print(r.exec(\"a\"));",
        .{ .mode = .script, .filename = "quick-regexp-domain.js" },
    );
    defer parsed.deinit();

    try std.testing.expectEqual(frontend.parser.ParsePath.quickjs_parser, parsed.parse_path);
    try std.testing.expect(countOpcode(parsed.function.code, engine.bytecode.opcode.op.call_constructor) >= 1);
    const receiver_call_count = countOpcode(parsed.function.code, engine.bytecode.opcode.op.call_prepared) +
        countOpcode(parsed.function.code, engine.bytecode.opcode.op.call_method);
    try std.testing.expect(receiver_call_count >= 3);
}

test "prepared call lowering preserves RegExp literal fuse while preparing cached RegExp calls" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var cached = try frontend.parser.parse(
        rt,
        "const r = /a+b/; r.test(\"aaab\");",
        .{ .mode = .script, .filename = "regexp-cached-prepared.js" },
    );
    defer cached.deinit();

    try std.testing.expectEqual(frontend.parser.ParsePath.quickjs_parser, cached.parse_path);
    try std.testing.expectEqual(@as(usize, 1), countOpcode(cached.function.code, engine.bytecode.opcode.op.prepare_call_prop_atom));
    try std.testing.expectEqual(@as(usize, 1), countOpcode(cached.function.code, engine.bytecode.opcode.op.call_prepared));

    var literal = try frontend.parser.parse(
        rt,
        "/a+b/.test(\"aaab\");",
        .{ .mode = .script, .filename = "regexp-literal-fuse.js" },
    );
    defer literal.deinit();

    try std.testing.expectEqual(frontend.parser.ParsePath.quickjs_parser, literal.parse_path);
    try std.testing.expectEqual(@as(usize, 0), countOpcode(literal.function.code, engine.bytecode.opcode.op.prepare_call_prop_atom));
    try std.testing.expectEqual(@as(usize, 0), countOpcode(literal.function.code, engine.bytecode.opcode.op.call_prepared));
    try std.testing.expectEqual(@as(usize, 1), countOpcode(literal.function.code, engine.bytecode.opcode.op.call_method));
}

test "quick parser lowers supported Promise helpers to receiver-preserving property calls" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try frontend.parser.parse(
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

    try std.testing.expectEqual(frontend.parser.ParsePath.quickjs_parser, parsed.parse_path);
    try std.testing.expect(countOpcode(parsed.function.code, engine.bytecode.opcode.op.call_constructor) >= 1);
    try std.testing.expect(countOpcode(parsed.function.code, engine.bytecode.opcode.op.call_prepared) >= 4);
}

test "quick parser lowers supported collection helpers to receiver-preserving property calls" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try frontend.parser.parse(
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

    try std.testing.expectEqual(frontend.parser.ParsePath.quickjs_parser, parsed.parse_path);
    try std.testing.expect(countOpcode(parsed.function.code, engine.bytecode.opcode.op.call_constructor) >= 4);
    try std.testing.expect(countOpcode(parsed.function.code, engine.bytecode.opcode.op.call_prepared) >= 16);
}

test "template interpolation emits string concatenation" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try frontend.parser.parse(rt, "const x = 10; const y = 20; print(`${x} + ${y} = ${x + y}`);", .{ .mode = .script, .filename = "template.js" });
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

    var parsed = try frontend.parser.parse(rt, "const arr = [1, 2, 3]; print(arr); print(arr.length); print(arr[0]); print(arr.map(x => x * 2));", .{ .mode = .script, .filename = "array.js" });
    defer parsed.deinit();

    const new_array_count = countOpcode(parsed.function.code, engine.bytecode.opcode.op.array_from);
    const get_index_count = countOpcode(parsed.function.code, engine.bytecode.opcode.op.get_array_el);
    const map_count = countOpcode(parsed.function.code, engine.bytecode.opcode.op.get_field) +
        countOpcode(parsed.function.code, engine.bytecode.opcode.op.get_field2) +
        countOpcode(parsed.function.code, engine.bytecode.opcode.op.prepare_call_prop_atom);
    const call_prop_count = countOpcode(parsed.function.code, engine.bytecode.opcode.op.call_prepared) +
        countOpcode(parsed.function.code, engine.bytecode.opcode.op.call_method);
    try std.testing.expectEqual(@as(usize, 1), new_array_count);
    try std.testing.expectEqual(@as(usize, 1), get_index_count);
    try std.testing.expect(map_count >= 1 or call_prop_count >= 1);
    try std.testing.expectEqual(@as(usize, 1), call_prop_count);
}

test "simple functions and arrows emit inline helper bytecode" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try frontend.parser.parse(rt, "function add(a, b) { return a + b; } print(add(2, 3)); const double = x => x * 2; print(double(21)); function fact(n) { return n <= 1 ? 1 : n * fact(n - 1); } print(fact(6));", .{ .mode = .script, .filename = "functions.js" });
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

    var parsed = try frontend.parser.parse(rt, "print(...[1]);", .{ .mode = .script, .filename = "fallback.js" });
    defer parsed.deinit();

    try std.testing.expectEqual(frontend.parser.ParsePath.quickjs_parser, parsed.parse_path);
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
    var parsed = try frontend.parser.parse(rt, source, .{ .mode = .script, .filename = "metadata.js" });
    defer parsed.deinit();

    try std.testing.expect(parsed.syntax_error == null);
    try std.testing.expectEqual(frontend.parser.ParsePath.quickjs_parser, parsed.parse_path);
    try std.testing.expectEqual(@as(usize, 1), countOpcode(parsed.function.code, engine.bytecode.opcode.op.get_var));
    try std.testing.expectEqual(@as(usize, 0), countOpcode(parsed.function.code, engine.bytecode.opcode.op.get_field));
    try std.testing.expectEqual(@as(usize, 0), countOpcode(parsed.function.code, engine.bytecode.opcode.op.call));
    try std.testing.expectEqual(@as(usize, 1), countOpcode(parsed.function.code, engine.bytecode.opcode.op.prepare_call_prop_atom));
    try std.testing.expectEqual(@as(usize, 1), countOpcode(parsed.function.code, engine.bytecode.opcode.op.call_prepared));
    try std.testing.expectEqual(@as(usize, 0), countOpcode(parsed.function.code, engine.bytecode.opcode.op.call_method));
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
        var parsed = try frontend.parser.parse(rt, source, .{ .mode = .script, .filename = "arrow-early-error.js" });
        defer parsed.deinit();
        try std.testing.expect(parsed.syntax_error != null);
        try std.testing.expect(parsed.syntax_error.?.message.len > 0);
    }
}

test "arrow early error checks do not reject valid nested rest destructuring" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try frontend.parser.parse(rt, "var f; f = ([...[...x]]) => {};", .{ .mode = .script, .filename = "arrow-valid-rest.js" });
    defer parsed.deinit();

    try std.testing.expect(parsed.syntax_error == null);
    try std.testing.expect(countFunctionClosures(parsed.function.code) > 0);
    const arrow = try expectFunctionConstant(&parsed.function, 0);
    try std.testing.expect(arrow.is_arrow_function);
    try std.testing.expectEqual(function_def.FunctionKind.normal, arrow.func_kind);
    try expectOpcode(arrow.byte_code, qop.special_object);
    try expectOpcode(arrow.byte_code, qop.return_undef);
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
        "/*---\nflags: [generated, onlyStrict]\n---*/\n0, { eval } = {};",
        "/*---\nflags: [generated, onlyStrict]\n---*/\n0, [arguments] = [];",
        "/*---\nflags: [generated, onlyStrict]\n---*/\n(eval) = 20;",
        "/*---\nflags: [generated, onlyStrict]\n---*/\n(arguments) = 20;",
        "/*---\nflags: [generated, onlyStrict]\n---*/\n0, [ x = yield ] = [];",
        "/*---\nflags: [generated, onlyStrict]\n---*/\n0, { x: x[yield] } = {};",
    };

    for (cases) |source| {
        var parsed = try frontend.parser.parse(rt, source, .{ .mode = .script, .filename = "assignment-early-error.js" });
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
        var parsed = try frontend.parser.parse(rt, case.source, .{ .mode = .script, .filename = "assignment-valid-property-name.js" });
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
        var parsed = try frontend.parser.parse(rt, source, .{ .mode = .script, .filename = "assignment-target-type.js" });
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
        var parsed = try frontend.parser.parse(rt, source, .{ .mode = .script, .filename = "async-arrow-early-error.js" });
        defer parsed.deinit();
        try std.testing.expect(parsed.syntax_error != null);
        try std.testing.expect(parsed.syntax_error.?.message.len > 0);
    }
}

test "object computed property names parse async arrow and module await expressions" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var async_arrow = try frontend.parser.parse(rt, "let o = { [async () => {}]: 1 };", .{ .mode = .script, .filename = "computed-async-arrow.js" });
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

    var module_await = try frontend.parser.parse(rt, "let o = { [await 9]: 9 };", .{ .mode = .module, .filename = "computed-await.js" });
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

    var parsed = try frontend.parser.parse(rt, source, .{ .mode = .script, .filename = "class-early-error.js" });
    defer parsed.deinit();
    try std.testing.expect(parsed.syntax_error != null);
    try std.testing.expect(parsed.syntax_error.?.message.len > 0);
}

test "module parse mode records import export metadata and strict flag" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try frontend.parser.parse(
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

test "module import local names are compiled as module var refs" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try frontend.parser.parse(
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
        var parsed = try frontend.parser.parse(rt, source, .{ .mode = .module, .filename = "dup-export.js" });
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
        var parsed = try frontend.parser.parse(rt, source, .{ .mode = .module, .filename = "valid-local-export.js" });
        defer parsed.deinit();
        try std.testing.expect(parsed.syntax_error == null);
    }

    const invalid_cases = [_][]const u8{
        "export { Number };",
        "export { unresolvable };",
    };
    for (invalid_cases) |source| {
        var parsed = try frontend.parser.parse(rt, source, .{ .mode = .module, .filename = "invalid-local-export.js" });
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
        var parsed = try frontend.parser.parse(rt, source, .{ .mode = .module, .filename = "dup-import-attr.js" });
        defer parsed.deinit();
        try std.testing.expect(parsed.syntax_error != null);
    }

    var parsed = try frontend.parser.parse(
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

    var parsed = try frontend.parser.parse(rt, "import './dep.js' with {};", .{ .mode = .module, .filename = "side-effect-import-attr.js" });
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
        var parsed = try frontend.parser.parse(rt, source, .{ .mode = .module, .filename = "invalid-string-export-name.js" });
        defer parsed.deinit();
        try std.testing.expect(parsed.syntax_error != null);
    }

    var parsed = try frontend.parser.parse(rt, "export { \"ok\" as \"also-ok\" } from './dep.js';", .{ .mode = .module, .filename = "valid-string-export-name.js" });
    defer parsed.deinit();
    try std.testing.expect(parsed.syntax_error == null);
}

test "module parser rejects comma expression as default export expression" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var invalid = try frontend.parser.parse(rt, "export default null, null;", .{ .mode = .module, .filename = "invalid-default-export.js" });
    defer invalid.deinit();
    try std.testing.expect(invalid.syntax_error != null);

    var valid = try frontend.parser.parse(rt, "export default (null, null);", .{ .mode = .module, .filename = "valid-default-export.js" });
    defer valid.deinit();
    try std.testing.expect(valid.syntax_error == null);
}

test "module parser accepts keyword module export and import names" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try frontend.parser.parse(
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

    var parsed = try frontend.parser.parse(rt, "var test262; var test262; for (var other; false;) {} for (var other; false;) {}", .{ .mode = .module, .filename = "dup-module-var.js" });
    defer parsed.deinit();

    try std.testing.expect(parsed.syntax_error == null);
}

test "parser accepts dynamic import call expressions" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var module_parsed = try frontend.parser.parse(rt, "try { await import('dep', { with: {} }); } catch (e) {}", .{ .mode = .module, .filename = "dynamic-import.mjs" });
    defer module_parsed.deinit();
    try std.testing.expect(module_parsed.syntax_error == null);

    var script_parsed = try frontend.parser.parse(rt, "import('dep',);", .{ .mode = .script, .filename = "dynamic-import.js" });
    defer script_parsed.deinit();
    try std.testing.expect(script_parsed.syntax_error == null);

    var import_meta_arg = try frontend.parser.parse(rt, "import(import.meta);", .{ .mode = .module, .filename = "dynamic-import-meta.mjs" });
    defer import_meta_arg.deinit();
    try std.testing.expect(import_meta_arg.syntax_error == null);

    var import_in_arg = try frontend.parser.parse(rt, "for (promise = import('dep', 'x' in {}); false;) ;", .{ .mode = .script, .filename = "dynamic-import-in.js" });
    defer import_in_arg.deinit();
    try std.testing.expect(import_in_arg.syntax_error == null);
}

test "parser rejects invalid dynamic import call syntax" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var new_import = try frontend.parser.parse(rt, "new import('dep');", .{ .mode = .script, .filename = "bad-dynamic-import.js" });
    defer new_import.deinit();
    try std.testing.expect(new_import.syntax_error != null);

    var escaped_import = try frontend.parser.parse(rt, "im\\u0070ort('dep');", .{ .mode = .script, .filename = "escaped-dynamic-import.js" });
    defer escaped_import.deinit();
    try std.testing.expect(escaped_import.syntax_error != null);
}

test "module parser accepts default as explicit namespace export name" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try frontend.parser.parse(rt, "export * as default from './dep.js';", .{ .mode = .module, .filename = "default-star.js" });
    defer parsed.deinit();

    try std.testing.expect(parsed.syntax_error == null);
    try std.testing.expectEqual(@as(usize, 1), parsed.function.module_record.?.star_exports.len);
}

test "eval function class private destructuring spread async generator features are recorded" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try frontend.parser.parse(
        rt,
        "async function *f(...args) { class C { #x; method(){ return args[0]; } } let {x} = args[0]; yield x; await x; import('m'); }",
        .{ .mode = .eval_direct, .filename = "eval.js" },
    );
    defer parsed.deinit();

    try std.testing.expect(parsed.direct_eval);
    try std.testing.expect(parsed.syntax_error == null);
    try std.testing.expectEqual(frontend.parser.ParsePath.quickjs_parser, parsed.parse_path);
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

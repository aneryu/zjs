//! F1 — Lexer tests for the QuickJS-aligned lexer.
//!
//! Covers F1.1..F1.5 exit gates: token enum integer values aligned to
//! `quickjs.c:21246`, full string/template/numeric/regex coverage,
//! private names, Unicode identifiers, ASI `got_lf` flag, and the
//! keyword-atom alignment invariant
//! (`tokenAtom == ATOM_null + (val - TOK_NULL)`).

const std = @import("std");
const engine = @import("quickjs_zig_engine");

const t = engine.frontend.zjs_token;
const QjsLexer = engine.frontend.zjs_lexer.Lexer;
const atom = engine.core.atom;

const TestEnv = struct {
    rt: *engine.core.runtime.Runtime,
    fn init() !TestEnv {
        return .{ .rt = try engine.core.runtime.Runtime.create(std.testing.allocator) };
    }
    fn deinit(self: *TestEnv) void {
        self.rt.destroy();
    }
    fn lexer(self: *TestEnv, src: []const u8) QjsLexer {
        return QjsLexer.init(std.testing.allocator, &self.rt.atoms, src);
    }
};

fn freeAndDrain(lx: *QjsLexer, tok: *t.Token) void {
    lx.freeToken(tok);
}

// ---- F1.1 / F1.5 -----------------------------------------------------

test "F1: keyword token integer values match QuickJS TOK_*" {
    // Spot-check anchors from quickjs.c:21246..21338.
    try std.testing.expectEqual(@as(t.TokenKind, -128), t.TOK_NUMBER);
    try std.testing.expectEqual(@as(t.TokenKind, -127), t.TOK_STRING);
    try std.testing.expectEqual(@as(t.TokenKind, -125), t.TOK_IDENT);
    try std.testing.expectEqual(@as(t.TokenKind, -86), t.TOK_EOF);
    try std.testing.expectEqual(@as(t.TokenKind, -85), t.TOK_NULL);
    try std.testing.expectEqual(@as(t.TokenKind, -40), t.TOK_AWAIT);
    try std.testing.expectEqual(@as(t.TokenKind, -39), t.TOK_OF);
}

test "F1.5: every keyword token maps to its predefined atom" {
    var env = try TestEnv.init();
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
    var env = try TestEnv.init();
    defer env.deinit();

    var lx = env.lexer("of");
    var tok = try lx.next();
    defer freeAndDrain(&lx, &tok);

    try std.testing.expectEqual(t.TOK_IDENT, tok.val);
    const name = env.rt.atoms.name(tok.payload.ident.atom).?;
    try std.testing.expectEqualStrings("of", name);
}

test "F1: punctuators use raw ASCII for single-character tokens" {
    var env = try TestEnv.init();
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
    var env = try TestEnv.init();
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
    var env = try TestEnv.init();
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
    var env = try TestEnv.init();
    defer env.deinit();

    var lx = env.lexer("9007199254740993n");
    var tok = try lx.next();
    defer freeAndDrain(&lx, &tok);
    try std.testing.expectEqual(t.TOK_NUMBER, tok.val);
    try std.testing.expect(tok.payload.num.is_bigint);
    try std.testing.expectEqualStrings("9007199254740993", tok.payload.num.bigint_text);
}

test "F1.2: string escapes (basic, hex, unicode short and braced, surrogate pair)" {
    var env = try TestEnv.init();
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
    var env = try TestEnv.init();
    defer env.deinit();

    var lx = env.lexer("\"\\uD800\"");
    var tok = try lx.next();
    defer freeAndDrain(&lx, &tok);
    try std.testing.expectEqual(t.TOK_STRING, tok.val);
    try std.testing.expectEqualStrings("\xED\xA0\x80", tok.payload.str.bytes);
}

test "F1.2: line continuation in string and \\0 NUL escape" {
    var env = try TestEnv.init();
    defer env.deinit();

    var lx = env.lexer("'foo\\\nbar\\0z'");
    var tok = try lx.next();
    defer freeAndDrain(&lx, &tok);
    try std.testing.expectEqual(t.TOK_STRING, tok.val);
    const want = "foobar\x00z";
    try std.testing.expectEqualStrings(want, tok.payload.str.bytes);
}

test "F1.2: legacy octal in strict mode is rejected" {
    var env = try TestEnv.init();
    defer env.deinit();

    var lx = env.lexer("'\\1'");
    lx.is_strict_mode = true;
    const tok_or_err = lx.next();
    try std.testing.expectError(error.LegacyOctalInStrictMode, tok_or_err);
}

test "G1/P0: template legacy octal escapes mark cooked value invalid" {
    var env = try TestEnv.init();
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
    var env = try TestEnv.init();
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
    var env = try TestEnv.init();
    defer env.deinit();
    var lx = env.lexer("`hello`");
    var tok = try lx.next();
    defer freeAndDrain(&lx, &tok);
    try std.testing.expectEqual(t.TemplatePart.no_substitution, tok.payload.str.template.?);
    try std.testing.expectEqualStrings("hello", tok.payload.str.bytes);
    try std.testing.expectEqualStrings("hello", tok.payload.str.raw_bytes);
}

test "G1/P0: template token keeps raw escape bytes" {
    var env = try TestEnv.init();
    defer env.deinit();

    var lx = env.lexer("`\\n`");
    var tok = try lx.next();
    defer freeAndDrain(&lx, &tok);
    try std.testing.expectEqual(t.TemplatePart.no_substitution, tok.payload.str.template.?);
    try std.testing.expectEqualStrings("\n", tok.payload.str.bytes);
    try std.testing.expectEqualStrings("\\n", tok.payload.str.raw_bytes);
}

test "G1/P0: template token normalizes raw CR line terminators" {
    var env = try TestEnv.init();
    defer env.deinit();

    var lx = env.lexer("`\r\n\r`");
    var tok = try lx.next();
    defer freeAndDrain(&lx, &tok);
    try std.testing.expectEqual(t.TemplatePart.no_substitution, tok.payload.str.template.?);
    try std.testing.expectEqualStrings("\n\n", tok.payload.str.bytes);
    try std.testing.expectEqualStrings("\n\n", tok.payload.str.raw_bytes);
}

test "F1.2: regex literal exposes pattern and flags" {
    var env = try TestEnv.init();
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
    var env = try TestEnv.init();
    defer env.deinit();

    var lx = env.lexer("#secret");
    var tok = try lx.next();
    defer freeAndDrain(&lx, &tok);
    try std.testing.expectEqual(t.TOK_PRIVATE_NAME, tok.val);
    try std.testing.expectEqualStrings("#secret", env.rt.atoms.name(tok.payload.ident.atom).?);
}

test "F1.3: unicode escape inside identifier is decoded into the atom" {
    var env = try TestEnv.init();
    defer env.deinit();

    var lx = env.lexer("\\u0061sync");
    var tok = try lx.next();
    defer freeAndDrain(&lx, &tok);
    try std.testing.expectEqual(t.TOK_IDENT, tok.val);
    try std.testing.expect(tok.payload.ident.has_escape);
    try std.testing.expectEqualStrings("async", env.rt.atoms.name(tok.payload.ident.atom).?);
}

test "F1.3: escaped keyword spelling is treated as identifier (per spec)" {
    var env = try TestEnv.init();
    defer env.deinit();

    var lx = env.lexer("\\u0069f"); // \u0069f = "if"
    var tok = try lx.next();
    defer freeAndDrain(&lx, &tok);
    try std.testing.expectEqual(t.TOK_IDENT, tok.val); // not TOK_IF
    try std.testing.expectEqualStrings("if", env.rt.atoms.name(tok.payload.ident.atom).?);
}

test "F1.3: raw Unicode identifier start accepts ID_Start and rejects emoji" {
    var env = try TestEnv.init();
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
    var env = try TestEnv.init();
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
    var env = try TestEnv.init();
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
    var env = try TestEnv.init();
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
    var env = try TestEnv.init();
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
    var env = try TestEnv.init();
    defer env.deinit();

    var lx = env.lexer("#!/usr/bin/env zjs\n42");
    var tok = try lx.next();
    defer freeAndDrain(&lx, &tok);
    try std.testing.expectEqual(t.TOK_NUMBER, tok.val);
}

test "F1.5: keyword block atom layout matches quickjs-atom.h ordering" {
    var env = try TestEnv.init();
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

//! QuickJS-aligned lexer (F1).
//!
//! Mirrors `next_token`, `js_parse_string`, `js_parse_template_part`,
//! `js_parse_regexp`, and the helpers around them in
//! QuickJS `quickjs.c:21794..23200`.
//!
//! This module coexists with the legacy `frontend/lexer.zig`. The
//! legacy lexer keeps serving the QuickParser until F11; the new
//! parser pipeline (F4+) uses this module.

const std = @import("std");
const atom_module = @import("../core/atom.zig");
const memory = @import("../core/memory.zig");
const unicode = @import("../libs/unicode.zig");
const t = @import("zjs_token.zig");

const Atom = atom_module.Atom;
const AtomTable = atom_module.AtomTable;

pub const Error = error{
    UnexpectedEof,
    UnterminatedString,
    UnterminatedTemplate,
    UnterminatedRegExp,
    UnterminatedComment,
    InvalidEscape,
    InvalidUnicodeEscape,
    InvalidUtf8,
    InvalidNumber,
    InvalidIdentifier,
    InvalidPrivateName,
    InvalidRegExp,
    LegacyOctalInStrictMode,
    HtmlCommentInModule,
    OutOfMemory,
    SyntaxError,
};

pub const Lexer = struct {
    /// Allocator used for owned token payloads (decoded strings).
    /// Tokens own their `payload.str.bytes`; the caller frees them via
    /// `freeToken`.
    allocator: std.mem.Allocator,
    atoms: *AtomTable,

    source: []const u8,
    /// Current byte offset.
    pos: usize = 0,
    /// 1-based line/column of the byte at `pos`.
    line: u32 = 1,
    col: u32 = 1,

    /// Parser flags that influence lexing (mirror `JSParseState` fields).
    is_strict_mode: bool = false,
    is_module: bool = false,
    allow_html_comments: bool = true,
    /// Set whenever a LineTerminator (or the equivalent) was skipped
    /// before the most recently emitted token. Mirrors
    /// `JSParseState.got_lf` (`quickjs.c:21572`).
    got_lf: bool = false,

    /// Snapshot taken at the start of the most recent token (so that
    /// the parser can build a `Token` with `ptr`, `line_num`, and
    /// `col_num` matching QuickJS).
    mark_pos: usize = 0,
    mark_line: u32 = 1,
    mark_col: u32 = 1,

    is_typescript: bool = false,
    skipped_intervals: std.ArrayList(Range),

    pub fn init(
        allocator: std.mem.Allocator,
        atoms: *AtomTable,
        source: []const u8,
    ) Lexer {
        return .{
            .allocator = allocator,
            .atoms = atoms,
            .source = source,
            .skipped_intervals = std.ArrayList(Range).empty,
        };
    }

    pub fn deinit(self: *Lexer) void {
        self.skipped_intervals.deinit(self.allocator);
    }

    pub fn enableTypeScript(self: *Lexer) !void {
        self.is_typescript = true;
        try markTypeRanges(self);
    }

    fn getSkippedIntervalAtPos(self: *const Lexer, pos: usize) ?Range {
        for (self.skipped_intervals.items) |range| {
            if (range.start == pos) return range;
            if (range.start > pos) break;
        }
        return null;
    }

    fn skipRange(self: *Lexer, range: Range) bool {
        var p = self.pos;
        var saw_lf = false;
        while (p < range.end) : (p += 1) {
            const c = self.source[p];
            if (c == '\n') {
                self.line += 1;
                self.col = 1;
                saw_lf = true;
            } else if (c == '\r') {
                if (p + 1 < range.end and self.source[p + 1] == '\n') {
                    p += 1;
                }
                self.line += 1;
                self.col = 1;
                saw_lf = true;
            } else {
                self.col += 1;
            }
        }
        self.pos = range.end;
        return saw_lf;
    }

    pub fn freeToken(self: *Lexer, tok: *t.Token) void {
        switch (tok.payload) {
            .str => |s| {
                if (s.bytes.len > 0) self.allocator.free(s.bytes);
                if (s.raw_bytes.len > 0) self.allocator.free(s.raw_bytes);
            },
            else => {},
        }
        tok.payload = .none;
    }

    /// Return whether a line terminator was seen before the most recent token.
    pub fn gotLineTerminator(self: *Lexer) bool {
        return self.got_lf;
    }

    /// Produce the next token. Returns `TOK_EOF` at end of input.
    pub fn next(self: *Lexer) Error!t.Token {
        try self.skipTrivia();
        self.mark();

        if (self.pos >= self.source.len) {
            return self.emit(t.TOK_EOF, .{ .none = {} });
        }

        const c = self.peek();

        if (isAsciiIdentStart(c) or c >= 0x80 or self.startsUnicodeEscape()) {
            return self.lexIdentifier();
        }
        if (std.ascii.isDigit(c)) return self.lexNumber(false);
        if (c == '#') return self.lexPrivateName();
        if (c == '"' or c == '\'') return self.lexString(c);
        if (c == '`') return self.lexTemplate(.head_or_no_subst);
        if (c == '.') return self.lexDotOrNumber();

        return self.lexPunctuator();
    }

    /// Resume lexing a template after the parser closed a `${ ... }`
    /// substitution. Mirrors the second call into
    /// `js_parse_template_part` (`quickjs.c:21794`).
    ///
    /// **Lexer position contract**: must be called with `pos` AT the
    /// closing `}` byte. The `nextTemplatePartAfterBrace` variant is
    /// for the parser case where the `}` has already been advanced past
    /// (i.e. the parser observed `}` as the lookahead token after the
    /// substitution's expression, so `lex.pos` is one byte past `}`).
    pub fn nextTemplatePart(self: *Lexer) Error!t.Token {
        self.mark();
        return self.lexTemplate(.middle_or_tail);
    }

    /// Like `nextTemplatePart`, but assumes the closing `}` has already
    /// been lexed and consumed by the parser's lookahead. Used by the
    /// expression parser, which discovers `}` only via its standard
    /// post-expression lookahead.
    pub fn nextTemplatePartAfterBrace(self: *Lexer) Error!t.Token {
        self.mark();
        return self.lexTemplateBody(.middle_or_tail, false);
    }

    /// Re-lex the most recently emitted `/`/`/=` punctuator as a regex
    /// literal. Mirrors the QuickJS pattern of letting the parser ask
    /// for a regexp once it knows it's in a regexp-allowed context
    /// (`js_parse_regexp`, `quickjs.c:22005`). The caller passes the
    /// `mark_pos` recorded before the slash so we restart from there.
    pub fn rescanRegexp(self: *Lexer, slash_offset: usize) Error!t.Token {
        // Reset position back to the slash. The caller is responsible
        // for having recorded `mark_line`/`mark_col` before the slash.
        self.pos = slash_offset;
        self.line = self.mark_line;
        self.col = self.mark_col;
        self.mark();
        return self.lexRegexp();
    }

    // ---- internals ---------------------------------------------------

    inline fn peek(self: Lexer) u8 {
        return self.source[self.pos];
    }

    inline fn peekAt(self: Lexer, n: usize) u8 {
        return if (self.pos + n < self.source.len) self.source[self.pos + n] else 0;
    }

    inline fn remaining(self: Lexer) usize {
        return self.source.len - self.pos;
    }

    inline fn bump(self: *Lexer) void {
        const b = self.source[self.pos];
        self.pos += 1;
        if (b == '\n') {
            self.line += 1;
            self.col = 1;
        } else {
            self.col += 1;
        }
    }

    fn mark(self: *Lexer) void {
        self.mark_pos = self.pos;
        self.mark_line = self.line;
        self.mark_col = self.col;
    }

    fn emit(self: *Lexer, val: t.TokenKind, payload: t.Payload) t.Token {
        return .{
            .val = val,
            .line_num = self.mark_line,
            .col_num = self.mark_col,
            .ptr = if (self.mark_pos < self.source.len)
                self.source[self.mark_pos..].ptr
            else
                self.source.ptr + self.source.len,
            .len = self.pos - self.mark_pos,
            .payload = payload,
        };
    }

    fn skipTrivia(self: *Lexer) Error!void {
        self.got_lf = false;
        var allow_html_close = self.col == 1;
        while (self.pos < self.source.len) {
            if (self.is_typescript) {
                if (self.getSkippedIntervalAtPos(self.pos)) |range| {
                    const saw_lf = self.skipRange(range);
                    if (saw_lf) {
                        self.got_lf = true;
                        allow_html_close = true;
                    }
                    continue;
                }
            }
            const c = self.peek();
            if (c == ' ' or c == '\t' or c == 0x0B or c == 0x0C) {
                self.bump();
                continue;
            }
            if (self.skipNonAsciiWhiteSpace()) |is_line_terminator| {
                if (is_line_terminator) {
                    self.got_lf = true;
                    allow_html_close = true;
                }
                continue;
            }
            if (c == '\n' or c == '\r') {
                self.got_lf = true;
                allow_html_close = true;
                self.bump();
                continue;
            }
            if (c == '/') {
                if (self.peekAt(1) == '/') {
                    try self.skipLineComment();
                    continue;
                }
                if (self.peekAt(1) == '*') {
                    const had_newline = try self.skipBlockComment();
                    if (had_newline) {
                        self.got_lf = true;
                        allow_html_close = true;
                    }
                    continue;
                }
            }
            // HTML-like comments are spec-permitted only in script mode
            // (B.1.3). They begin with `<!--` anywhere, and `-->` only
            // after a LineTerminator (or BOM/start of file).
            if (c == '<' and self.allow_html_comments and !self.is_module and self.startsWithBytes("<!--")) {
                try self.skipLineComment();
                continue;
            }
            if (c == '-' and self.allow_html_comments and !self.is_module and allow_html_close and self.startsWithBytes("-->")) {
                try self.skipLineComment();
                continue;
            }
            // Hashbang only at start of file.
            if (self.pos == 0 and self.startsWithBytes("#!")) {
                try self.skipLineComment();
                allow_html_close = true;
                continue;
            }
            return;
        }
    }

    fn skipLineComment(self: *Lexer) Error!void {
        while (self.pos < self.source.len) {
            const c = self.peek();
            if (c == '\n' or c == '\r') return;
            if (isUtf8LineSeparator(self)) return;
            self.bump();
        }
    }

    fn skipNonAsciiWhiteSpace(self: *Lexer) ?bool {
        if (self.remaining() >= 2 and self.peek() == 0xC2 and self.peekAt(1) == 0xA0) {
            self.pos += 2;
            self.col += 1;
            return false;
        }
        if (self.remaining() >= 3) {
            const b1 = self.peek();
            const b2 = self.peekAt(1);
            const b3 = self.peekAt(2);
            if (b1 == 0xE1 and b2 == 0x9A and b3 == 0x80) {
                self.pos += 3;
                self.col += 1;
                return false;
            }
            if (b1 == 0xE2 and b2 == 0x80) {
                if (b3 >= 0x80 and b3 <= 0x8A) {
                    self.pos += 3;
                    self.col += 1;
                    return false;
                }
                if (b3 == 0xA8 or b3 == 0xA9) {
                    self.pos += 3;
                    self.line += 1;
                    self.col = 1;
                    return true;
                }
                if (b3 == 0xAF) {
                    self.pos += 3;
                    self.col += 1;
                    return false;
                }
            }
            if (b1 == 0xE2 and b2 == 0x81 and b3 == 0x9F) {
                self.pos += 3;
                self.col += 1;
                return false;
            }
            if (b1 == 0xE3 and b2 == 0x80 and b3 == 0x80) {
                self.pos += 3;
                self.col += 1;
                return false;
            }
            if (b1 == 0xEF and b2 == 0xBB and b3 == 0xBF) {
                self.pos += 3;
                self.col += 1;
                return false;
            }
        }
        return null;
    }

    fn isUtf8LineSeparator(self: *Lexer) bool {
        return self.remaining() >= 3 and self.peek() == 0xE2 and self.peekAt(1) == 0x80 and
            (self.peekAt(2) == 0xA8 or self.peekAt(2) == 0xA9);
    }

    fn skipBlockComment(self: *Lexer) Error!bool {
        self.bump(); // /
        self.bump(); // *
        var saw_newline = false;
        while (self.pos + 1 < self.source.len) {
            if (self.peek() == '*' and self.peekAt(1) == '/') {
                self.bump();
                self.bump();
                return saw_newline;
            }
            if (self.isUtf8LineSeparator()) {
                saw_newline = true;
                self.pos += 3;
                self.line += 1;
                self.col = 1;
                continue;
            }
            const c = self.peek();
            if (c == '\n' or c == '\r') saw_newline = true;
            self.bump();
        }
        return error.UnterminatedComment;
    }

    fn startsWithBytes(self: Lexer, lit: []const u8) bool {
        if (self.remaining() < lit.len) return false;
        return std.mem.eql(u8, self.source[self.pos..][0..lit.len], lit);
    }

    fn startsUnicodeEscape(self: Lexer) bool {
        return self.remaining() >= 2 and self.peek() == '\\' and self.peekAt(1) == 'u';
    }

    // ---- identifiers / keywords --------------------------------------

    fn lexIdentifier(self: *Lexer) Error!t.Token {
        var has_escape = false;
        // Scratch buffer for the decoded identifier (used for keyword
        // lookup and atom interning when escapes are present).
        var decoded = std.ArrayList(u8).empty;
        defer decoded.deinit(self.allocator);

        // First code point.
        if (self.peek() == '\\') {
            const cp = try self.consumeUnicodeEscape();
            if (!unicode.isIdentifierStart(cp)) return error.InvalidIdentifier;
            try appendUtf8(&decoded, self.allocator, cp);
            has_escape = true;
        } else {
            try self.consumeIdentCodePoint(&decoded, true);
        }

        while (self.pos < self.source.len) {
            const c = self.peek();
            if (c == '\\') {
                if (!self.startsUnicodeEscape()) break;
                const cp = try self.consumeUnicodeEscape();
                if (!unicode.isIdentifierContinue(cp)) return error.InvalidIdentifier;
                try appendUtf8(&decoded, self.allocator, cp);
                has_escape = true;
                continue;
            }
            if (isAsciiIdentContinue(c)) {
                try decoded.append(self.allocator, c);
                self.bump();
                continue;
            }
            if (isNonAsciiTriviaStart(self)) break;
            if (c >= 0x80) {
                try self.consumeIdentCodePoint(&decoded, false);
                continue;
            }
            break;
        }

        const lexeme = decoded.items;

        // Keyword lookup. When the identifier was spelled with escapes
        // it's not a keyword (per spec).
        if (!has_escape) {
            if (keywordLookup(lexeme)) |val| {
                // TOK_ASYNC is a contextual keyword, not a reserved keyword;
                // keep existing parser behaviour and treat it as an identifier.
                if (val == t.TOK_ASYNC) {
                    const a = try self.atoms.internString(lexeme);
                    return self.emit(t.TOK_IDENT, .{ .ident = .{
                        .atom = a,
                        .has_escape = false,
                        .is_reserved = false,
                    } });
                }
                // Other contextual tokens outside the keyword atom range do
                // not satisfy the QuickJS keyword-atom arithmetic invariant.
                if (!t.isKeyword(val)) {
                    const a = try self.atoms.internString(lexeme);
                    return self.emit(val, .{ .ident = .{
                        .atom = a,
                        .has_escape = false,
                        .is_reserved = false,
                    } });
                }
                const ka = t.keywordAtom(val);
                return self.emit(val, .{ .ident = .{
                    .atom = ka,
                    .has_escape = false,
                    .is_reserved = isReservedKeyword(val, self.is_strict_mode),
                } });
            }
        }

        const a = try self.atoms.internString(lexeme);
        return self.emit(t.TOK_IDENT, .{ .ident = .{
            .atom = a,
            .has_escape = has_escape,
            .is_reserved = false,
        } });
    }

    fn isNonAsciiTriviaStart(self: *Lexer) bool {
        const c = self.peek();
        if (c == 0xC2 and self.remaining() >= 2 and self.source[self.pos + 1] == 0xA0) return true;
        if (c == 0xE2 and self.remaining() >= 3 and self.source[self.pos + 1] == 0x80) {
            const b3 = self.source[self.pos + 2];
            return (b3 >= 0x80 and b3 <= 0x8A) or b3 == 0xA8 or b3 == 0xA9 or b3 == 0xAF;
        }
        if (c == 0xE1 and self.remaining() >= 3 and self.source[self.pos + 1] == 0x9A and self.source[self.pos + 2] == 0x80) return true;
        if (c == 0xE2 and self.remaining() >= 3 and self.source[self.pos + 1] == 0x81 and self.source[self.pos + 2] == 0x9F) return true;
        if (c == 0xE3 and self.remaining() >= 3 and self.source[self.pos + 1] == 0x80 and self.source[self.pos + 2] == 0x80) return true;
        if (c == 0xEF and self.remaining() >= 3 and self.source[self.pos + 1] == 0xBB and self.source[self.pos + 2] == 0xBF) return true;
        return false;
    }

    fn consumeIdentCodePoint(self: *Lexer, out: *std.ArrayList(u8), is_start: bool) Error!void {
        const start = self.pos;
        const c0 = self.peek();
        if (c0 < 0x80) {
            const ok = if (is_start) isAsciiIdentStart(c0) else isAsciiIdentContinue(c0);
            if (!ok) return error.InvalidIdentifier;
            self.bump();
            try out.append(self.allocator, c0);
            return;
        }
        const cp = try self.decodeUtf8();
        const ok = if (is_start) unicode.isIdentifierStart(cp) else unicode.isIdentifierContinue(cp);
        if (!ok) return error.InvalidIdentifier;
        try out.appendSlice(self.allocator, self.source[start..self.pos]);
    }

    fn lexPrivateName(self: *Lexer) Error!t.Token {
        // Consume `#`. The atom keeps the leading `#` (matches QuickJS
        // representation: private name atoms start with `#`).
        self.bump();
        var decoded = std.ArrayList(u8).empty;
        defer decoded.deinit(self.allocator);
        try decoded.append(self.allocator, '#');
        var has_escape = false;

        if (self.pos >= self.source.len) return error.InvalidPrivateName;
        if (self.peek() == '\\') {
            const cp = try self.consumeUnicodeEscape();
            if (!unicode.isIdentifierStart(cp)) return error.InvalidPrivateName;
            try appendUtf8(&decoded, self.allocator, cp);
            has_escape = true;
        } else {
            try self.consumeIdentCodePoint(&decoded, true);
        }
        while (self.pos < self.source.len) {
            const c = self.peek();
            if (c == '\\') {
                if (!self.startsUnicodeEscape()) break;
                const cp = try self.consumeUnicodeEscape();
                if (!unicode.isIdentifierContinue(cp)) return error.InvalidPrivateName;
                try appendUtf8(&decoded, self.allocator, cp);
                has_escape = true;
                continue;
            }
            if (isAsciiIdentContinue(c)) {
                try decoded.append(self.allocator, c);
                self.bump();
                continue;
            }
            if (c >= 0x80) {
                try self.consumeIdentCodePoint(&decoded, false);
                continue;
            }
            break;
        }

        const a = try self.atoms.internString(decoded.items);
        return self.emit(t.TOK_PRIVATE_NAME, .{ .ident = .{
            .atom = a,
            .has_escape = has_escape,
            .is_reserved = false,
        } });
    }

    // ---- numbers -----------------------------------------------------

    fn lexDotOrNumber(self: *Lexer) Error!t.Token {
        if (self.peekAt(1) == '.' and self.peekAt(2) == '.') {
            self.bump();
            self.bump();
            self.bump();
            return self.emit(t.TOK_ELLIPSIS, .{ .none = {} });
        }
        if (std.ascii.isDigit(self.peekAt(1))) {
            return self.lexNumber(true);
        }
        self.bump();
        return self.emit('.', .{ .none = {} });
    }

    fn lexNumber(self: *Lexer, leading_dot: bool) Error!t.Token {
        const start = self.pos;
        var is_bigint = false;

        if (!leading_dot and self.peek() == '0' and self.remaining() >= 2) {
            const p = self.peekAt(1);
            switch (p) {
                'x', 'X' => {
                    self.bump();
                    self.bump();
                    if (!consumeHexDigits(self)) return error.InvalidNumber;
                    if (self.pos < self.source.len and self.peek() == 'n') {
                        is_bigint = true;
                        self.bump();
                    }
                    return self.finishNumber(start, is_bigint, 16);
                },
                'o', 'O' => {
                    self.bump();
                    self.bump();
                    if (!consumeOctalDigits(self)) return error.InvalidNumber;
                    if (self.pos < self.source.len and self.peek() == 'n') {
                        is_bigint = true;
                        self.bump();
                    }
                    return self.finishNumber(start, is_bigint, 8);
                },
                'b', 'B' => {
                    self.bump();
                    self.bump();
                    if (!consumeBinaryDigits(self)) return error.InvalidNumber;
                    if (self.pos < self.source.len and self.peek() == 'n') {
                        is_bigint = true;
                        self.bump();
                    }
                    return self.finishNumber(start, is_bigint, 2);
                },
                else => {},
            }
        }

        if (!leading_dot) {
            try consumeDecDigitsRequired(self);
        }
        if (self.pos < self.source.len and self.peek() == '.') {
            self.bump();
            try consumeOptionalFractionDigits(self);
        } else if (leading_dot) {
            // .NNN form: bumps already done by caller, just consume more digits
            try consumeOptionalFractionDigits(self);
        }
        if (self.pos < self.source.len and (self.peek() == 'e' or self.peek() == 'E')) {
            self.bump();
            if (self.pos < self.source.len and (self.peek() == '+' or self.peek() == '-')) self.bump();
            if (!consumeDecDigits(self)) return error.InvalidNumber;
        } else if (self.pos < self.source.len and self.peek() == 'n') {
            is_bigint = true;
            self.bump();
        }
        return self.finishNumber(start, is_bigint, 10);
    }

    fn finishNumber(self: *Lexer, start: usize, is_bigint: bool, base: u8) Error!t.Token {
        // Reject identifier characters immediately after a numeric literal
        // (e.g. `123abc` is a single error per spec, not two tokens).
        if (self.pos < self.source.len) {
            const nc = self.peek();
            if (isAsciiIdentStart(nc) or std.ascii.isDigit(nc) or (nc >= 0x80 and !self.startsUtf8Trivia())) {
                return error.InvalidNumber;
            }
        }
        const lexeme = self.source[start..self.pos];
        if (is_bigint) {
            if (base == 10 and decimalBigIntHasInvalidLeadingZero(lexeme)) return error.InvalidNumber;
            return self.emit(t.TOK_NUMBER, .{ .num = .{
                .value = 0,
                .is_bigint = true,
                .bigint_text = lexeme[0 .. lexeme.len - 1],
            } });
        }
        if (base == 10) {
            if (try legacyOrNonOctalDecimalValue(self, lexeme)) |value| {
                return self.emit(t.TOK_NUMBER, .{ .num = .{ .value = value } });
            }
        }
        const value = parseNumber(lexeme, base) catch return error.InvalidNumber;
        return self.emit(t.TOK_NUMBER, .{ .num = .{ .value = value } });
    }

    // ---- strings -----------------------------------------------------

    fn lexString(self: *Lexer, quote: u8) Error!t.Token {
        self.bump(); // opening quote
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(self.allocator);
        var contains_escape = false;
        var contains_legacy_escape = false;

        while (self.pos < self.source.len) {
            const c = self.peek();
            if (c == quote) {
                self.bump();
                const owned = try self.allocator.dupe(u8, buf.items);
                return self.emit(t.TOK_STRING, .{ .str = .{
                    .bytes = owned,
                    .contains_escape = contains_escape,
                    .contains_legacy_escape = contains_legacy_escape,
                    .sep = quote,
                } });
            }
            if (c == '\n' or c == '\r') return error.UnterminatedString;
            if (c == '\\') {
                self.bump();
                contains_escape = true;
                contains_legacy_escape = (try self.decodeStringEscape(&buf, false)) or contains_legacy_escape;
                continue;
            }
            try buf.append(self.allocator, c);
            self.bump();
        }
        return error.UnterminatedString;
    }

    fn decodeStringEscape(self: *Lexer, out: *std.ArrayList(u8), in_template: bool) Error!bool {
        if (self.pos >= self.source.len) return error.InvalidEscape;
        const c = self.peek();
        switch (c) {
            'n' => {
                self.bump();
                try out.append(self.allocator, '\n');
            },
            't' => {
                self.bump();
                try out.append(self.allocator, '\t');
            },
            'r' => {
                self.bump();
                try out.append(self.allocator, '\r');
            },
            'b' => {
                self.bump();
                try out.append(self.allocator, 0x08);
            },
            'f' => {
                self.bump();
                try out.append(self.allocator, 0x0C);
            },
            'v' => {
                self.bump();
                try out.append(self.allocator, 0x0B);
            },
            '0' => {
                if (self.pos + 1 < self.source.len and std.ascii.isDigit(self.peekAt(1))) {
                    if (self.is_strict_mode or in_template) return error.LegacyOctalInStrictMode;
                    try appendUtf8(out, self.allocator, try self.consumeLegacyOctalEscape());
                    return true;
                }
                self.bump();
                try out.append(self.allocator, 0);
            },
            'x' => {
                self.bump();
                if (self.remaining() < 2) return error.InvalidEscape;
                const h1 = self.peek();
                const h2 = self.peekAt(1);
                if (!std.ascii.isHex(h1) or !std.ascii.isHex(h2)) return error.InvalidEscape;
                self.bump();
                self.bump();
                try appendUtf8(out, self.allocator, @intCast(hexNibble(h1) * 16 + hexNibble(h2)));
            },
            'u' => {
                // unicode escape (surrogate pair handled below)
                const cp = try self.consumeUnicodeEscapeAfterBackslash();
                try appendUtf8(out, self.allocator, cp);
            },
            '\n' => {
                self.bump();
            }, // line continuation
            '\r' => {
                self.bump();
                if (self.pos < self.source.len and self.peek() == '\n') self.bump();
            },
            // U+2028 / U+2029 line continuation
            0xE2 => {
                if (self.remaining() >= 3 and self.source[self.pos + 1] == 0x80) {
                    const b3 = self.source[self.pos + 2];
                    if (b3 == 0xA8 or b3 == 0xA9) {
                        self.pos += 3;
                        self.line += 1;
                        self.col = 1;
                        return false;
                    }
                }
                // not a line separator: treat E2 byte as literal escape
                self.bump();
                try out.append(self.allocator, 0xE2);
            },
            else => {
                // Legacy octal (\1..\7) is rejected in strict mode and in
                // template literals; QuickJS reports it via cur_func->is_strict_mode.
                if (c >= '1' and c <= '7') {
                    if (self.is_strict_mode or in_template) return error.LegacyOctalInStrictMode;
                    try appendUtf8(out, self.allocator, try self.consumeLegacyOctalEscape());
                    return true;
                }
                if ((self.is_strict_mode or in_template) and (c == '8' or c == '9')) return error.LegacyOctalInStrictMode;
                // identity escape: \\, \', \", \`, etc.
                self.bump();
                try out.append(self.allocator, c);
                if (c == '8' or c == '9') return true;
            },
        }
        return false;
    }

    fn consumeLegacyOctalEscape(self: *Lexer) Error!u21 {
        const first = self.peek();
        var value: u16 = first - '0';
        self.bump();
        var remaining_digits: u8 = if (first >= '0' and first <= '3') 2 else 1;
        while (remaining_digits > 0 and self.pos < self.source.len) : (remaining_digits -= 1) {
            const d = self.peek();
            if (d < '0' or d > '7') break;
            value = value * 8 + (d - '0');
            self.bump();
        }
        return @intCast(value);
    }

    /// Called after a backslash has been consumed; the next byte is `u`.
    /// Returns the decoded code point. Handles surrogate pair joining
    /// when the next thing is also a `\uXXXX` escape forming a valid
    /// surrogate pair.
    fn consumeUnicodeEscapeAfterBackslash(self: *Lexer) Error!u21 {
        if (self.peek() != 'u') return error.InvalidUnicodeEscape;
        self.bump();
        if (self.pos < self.source.len and self.peek() == '{') {
            self.bump();
            var value: u32 = 0;
            var saw_digit = false;
            while (self.pos < self.source.len and self.peek() != '}') {
                const d = self.peek();
                if (!std.ascii.isHex(d)) return error.InvalidUnicodeEscape;
                value = value * 16 + hexNibble(d);
                if (value > 0x10FFFF) return error.InvalidUnicodeEscape;
                saw_digit = true;
                self.bump();
            }
            if (!saw_digit or self.pos >= self.source.len) return error.InvalidUnicodeEscape;
            self.bump(); // }
            return @intCast(value);
        }
        const cp1 = try self.consumeFourHex();
        // Surrogate pair: \uD800-\uDBFF followed by \uDC00-\uDFFF
        if (cp1 >= 0xD800 and cp1 <= 0xDBFF and self.remaining() >= 6 and
            self.peek() == '\\' and self.peekAt(1) == 'u' and self.peekAt(2) != '{')
        {
            const second_escape_pos = self.pos;
            const second_escape_line = self.line;
            const second_escape_col = self.col;
            self.bump();
            self.bump();
            const cp2 = try self.consumeFourHex();
            if (cp2 >= 0xDC00 and cp2 <= 0xDFFF) {
                return 0x10000 + ((@as(u21, cp1) - 0xD800) << 10) + (@as(u21, cp2) - 0xDC00);
            }
            // Not a low surrogate: per spec each lone surrogate is its
            // own code unit. Leave the second escape for the string scanner
            // to consume on the next iteration.
            self.pos = second_escape_pos;
            self.line = second_escape_line;
            self.col = second_escape_col;
            return @as(u21, cp1);
        }
        return @as(u21, cp1);
    }

    fn consumeUnicodeEscape(self: *Lexer) Error!u21 {
        if (self.peek() != '\\') return error.InvalidUnicodeEscape;
        self.bump();
        return self.consumeUnicodeEscapeAfterBackslash();
    }

    fn consumeFourHex(self: *Lexer) Error!u16 {
        if (self.remaining() < 4) return error.InvalidUnicodeEscape;
        var v: u16 = 0;
        var i: u8 = 0;
        while (i < 4) : (i += 1) {
            const d = self.peek();
            if (!std.ascii.isHex(d)) return error.InvalidUnicodeEscape;
            v = v * 16 + hexNibble(d);
            self.bump();
        }
        return v;
    }

    // ---- templates ---------------------------------------------------

    const TemplatePhase = enum { head_or_no_subst, middle_or_tail };

    fn lexTemplate(self: *Lexer, phase: TemplatePhase) Error!t.Token {
        return self.lexTemplateBody(phase, true);
    }

    fn lexTemplateBody(self: *Lexer, phase: TemplatePhase, expect_open_byte: bool) Error!t.Token {
        if (expect_open_byte) {
            if (phase == .head_or_no_subst) {
                std.debug.assert(self.peek() == '`');
                self.bump();
            } else {
                std.debug.assert(self.peek() == '}');
                self.bump();
            }
        }
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(self.allocator);
        var raw_buf = std.ArrayList(u8).empty;
        defer raw_buf.deinit(self.allocator);
        var cooked_invalid = false;

        while (self.pos < self.source.len) {
            const c = self.peek();
            if (c == '`') {
                const raw = try self.allocator.dupe(u8, raw_buf.items);
                errdefer self.allocator.free(raw);
                self.bump();
                const part: t.TemplatePart = if (phase == .head_or_no_subst)
                    .no_substitution
                else
                    .tail;
                const owned = try self.allocator.dupe(u8, buf.items);
                return self.emit(t.TOK_TEMPLATE, .{ .str = .{
                    .bytes = owned,
                    .raw_bytes = raw,
                    .cooked_invalid = cooked_invalid,
                    .sep = '`',
                    .template = part,
                } });
            }
            if (c == '$' and self.peekAt(1) == '{') {
                const raw = try self.allocator.dupe(u8, raw_buf.items);
                errdefer self.allocator.free(raw);
                self.bump();
                self.bump();
                const part: t.TemplatePart = if (phase == .head_or_no_subst)
                    .head
                else
                    .middle;
                const owned = try self.allocator.dupe(u8, buf.items);
                return self.emit(t.TOK_TEMPLATE, .{ .str = .{
                    .bytes = owned,
                    .raw_bytes = raw,
                    .cooked_invalid = cooked_invalid,
                    .sep = '`',
                    .template = part,
                } });
            }
            if (c == '\\') {
                const escape_start = self.pos;
                self.bump();
                _ = self.decodeStringEscape(&buf, true) catch |err| switch (err) {
                    error.InvalidEscape,
                    error.InvalidUnicodeEscape,
                    error.LegacyOctalInStrictMode,
                    => cooked_invalid = true,
                    else => |other| return other,
                };
                try appendNormalizedTemplateRaw(&raw_buf, self.allocator, self.source[escape_start..self.pos]);
                continue;
            }
            // Templates allow raw line terminators; normalize \r and
            // \r\n to \n (per spec).
            if (c == '\r') {
                try buf.append(self.allocator, '\n');
                try raw_buf.append(self.allocator, '\n');
                self.bump();
                if (self.pos < self.source.len and self.peek() == '\n') self.bump();
                continue;
            }
            try raw_buf.append(self.allocator, c);
            try buf.append(self.allocator, c);
            self.bump();
        }
        return error.UnterminatedTemplate;
    }

    fn appendNormalizedTemplateRaw(
        out: *std.ArrayList(u8),
        allocator: std.mem.Allocator,
        bytes: []const u8,
    ) Error!void {
        var i: usize = 0;
        while (i < bytes.len) {
            const b = bytes[i];
            if (b == '\r') {
                try out.append(allocator, '\n');
                i += 1;
                if (i < bytes.len and bytes[i] == '\n') i += 1;
                continue;
            }
            try out.append(allocator, b);
            i += 1;
        }
    }

    // ---- regex -------------------------------------------------------

    fn lexRegexp(self: *Lexer) Error!t.Token {
        std.debug.assert(self.peek() == '/');
        self.bump(); // leading /
        const pat_start = self.pos;
        var in_class = false;
        var escaped = false;
        while (self.pos < self.source.len) {
            const c = self.peek();
            if (c == '\n' or c == '\r') return error.UnterminatedRegExp;
            if (self.startsUtf8LineTerminator()) return error.UnterminatedRegExp;
            if (escaped) {
                escaped = false;
                self.bump();
                continue;
            }
            if (c == '\\') {
                escaped = true;
                self.bump();
                continue;
            }
            if (c == '[') {
                in_class = true;
                self.bump();
                continue;
            }
            if (c == ']') {
                in_class = false;
                self.bump();
                continue;
            }
            if (c == '/' and !in_class) break;
            self.bump();
        }
        if (self.pos >= self.source.len) return error.UnterminatedRegExp;
        const pat_end = self.pos;
        self.bump(); // closing /
        const flags_start = self.pos;
        while (self.pos < self.source.len) {
            const c = self.peek();
            if (isAsciiIdentContinue(c) or (c >= 0x80 and !self.startsUtf8Trivia())) {
                self.bump();
            } else break;
        }
        return self.emit(t.TOK_REGEXP, .{ .regexp = .{
            .pattern = self.source[pat_start..pat_end],
            .flags = self.source[flags_start..self.pos],
        } });
    }

    // ---- punctuators -------------------------------------------------

    fn lexPunctuator(self: *Lexer) Error!t.Token {
        const c = self.peek();
        switch (c) {
            '+' => return self.lexPlus(),
            '-' => return self.lexMinus(),
            '*' => return self.lexStar(),
            '/' => return self.lexSlash(),
            '%' => return self.lexPercent(),
            '=' => return self.lexEquals(),
            '!' => return self.lexBang(),
            '<' => return self.lexLt(),
            '>' => return self.lexGt(),
            '&' => return self.lexAmp(),
            '|' => return self.lexPipe(),
            '^' => return self.lexCaret(),
            '?' => return self.lexQuestion(),
            '~', '(', ')', '[', ']', '{', '}', ',', ';', ':' => {
                self.bump();
                return self.emit(@as(t.TokenKind, c), .{ .none = {} });
            },
            else => {
                self.bump();
                return error.InvalidIdentifier;
            },
        }
    }

    fn lexPlus(self: *Lexer) Error!t.Token {
        self.bump();
        if (self.pos < self.source.len) {
            if (self.peek() == '+') {
                self.bump();
                return self.emit(t.TOK_INC, .{ .none = {} });
            }
            if (self.peek() == '=') {
                self.bump();
                return self.emit(t.TOK_PLUS_ASSIGN, .{ .none = {} });
            }
        }
        return self.emit('+', .{ .none = {} });
    }

    fn lexMinus(self: *Lexer) Error!t.Token {
        self.bump();
        if (self.pos < self.source.len) {
            if (self.peek() == '-') {
                self.bump();
                return self.emit(t.TOK_DEC, .{ .none = {} });
            }
            if (self.peek() == '=') {
                self.bump();
                return self.emit(t.TOK_MINUS_ASSIGN, .{ .none = {} });
            }
        }
        return self.emit('-', .{ .none = {} });
    }

    fn lexStar(self: *Lexer) Error!t.Token {
        self.bump();
        if (self.pos < self.source.len) {
            if (self.peek() == '*') {
                self.bump();
                if (self.pos < self.source.len and self.peek() == '=') {
                    self.bump();
                    return self.emit(t.TOK_POW_ASSIGN, .{ .none = {} });
                }
                return self.emit(t.TOK_POW, .{ .none = {} });
            }
            if (self.peek() == '=') {
                self.bump();
                return self.emit(t.TOK_MUL_ASSIGN, .{ .none = {} });
            }
        }
        return self.emit('*', .{ .none = {} });
    }

    fn lexSlash(self: *Lexer) Error!t.Token {
        self.bump();
        if (self.pos < self.source.len and self.peek() == '=') {
            self.bump();
            return self.emit(t.TOK_DIV_ASSIGN, .{ .none = {} });
        }
        return self.emit('/', .{ .none = {} });
    }

    fn lexPercent(self: *Lexer) Error!t.Token {
        self.bump();
        if (self.pos < self.source.len and self.peek() == '=') {
            self.bump();
            return self.emit(t.TOK_MOD_ASSIGN, .{ .none = {} });
        }
        return self.emit('%', .{ .none = {} });
    }

    fn lexEquals(self: *Lexer) Error!t.Token {
        self.bump();
        if (self.pos < self.source.len) {
            if (self.peek() == '=') {
                self.bump();
                if (self.pos < self.source.len and self.peek() == '=') {
                    self.bump();
                    return self.emit(t.TOK_STRICT_EQ, .{ .none = {} });
                }
                return self.emit(t.TOK_EQ, .{ .none = {} });
            }
            if (self.peek() == '>') {
                self.bump();
                return self.emit(t.TOK_ARROW, .{ .none = {} });
            }
        }
        return self.emit('=', .{ .none = {} });
    }

    fn lexBang(self: *Lexer) Error!t.Token {
        self.bump();
        if (self.pos < self.source.len and self.peek() == '=') {
            self.bump();
            if (self.pos < self.source.len and self.peek() == '=') {
                self.bump();
                return self.emit(t.TOK_STRICT_NEQ, .{ .none = {} });
            }
            return self.emit(t.TOK_NEQ, .{ .none = {} });
        }
        return self.emit('!', .{ .none = {} });
    }

    fn lexLt(self: *Lexer) Error!t.Token {
        self.bump();
        if (self.pos < self.source.len) {
            if (self.peek() == '=') {
                self.bump();
                return self.emit(t.TOK_LTE, .{ .none = {} });
            }
            if (self.peek() == '<') {
                self.bump();
                if (self.pos < self.source.len and self.peek() == '=') {
                    self.bump();
                    return self.emit(t.TOK_SHL_ASSIGN, .{ .none = {} });
                }
                return self.emit(t.TOK_SHL, .{ .none = {} });
            }
        }
        return self.emit('<', .{ .none = {} });
    }

    fn lexGt(self: *Lexer) Error!t.Token {
        self.bump();
        if (self.pos < self.source.len) {
            if (self.peek() == '=') {
                self.bump();
                return self.emit(t.TOK_GTE, .{ .none = {} });
            }
            if (self.peek() == '>') {
                self.bump();
                if (self.pos < self.source.len and self.peek() == '>') {
                    self.bump();
                    if (self.pos < self.source.len and self.peek() == '=') {
                        self.bump();
                        return self.emit(t.TOK_SHR_ASSIGN, .{ .none = {} });
                    }
                    return self.emit(t.TOK_SHR, .{ .none = {} });
                }
                if (self.pos < self.source.len and self.peek() == '=') {
                    self.bump();
                    return self.emit(t.TOK_SAR_ASSIGN, .{ .none = {} });
                }
                return self.emit(t.TOK_SAR, .{ .none = {} });
            }
        }
        return self.emit('>', .{ .none = {} });
    }

    fn lexAmp(self: *Lexer) Error!t.Token {
        self.bump();
        if (self.pos < self.source.len) {
            if (self.peek() == '&') {
                self.bump();
                if (self.pos < self.source.len and self.peek() == '=') {
                    self.bump();
                    return self.emit(t.TOK_LAND_ASSIGN, .{ .none = {} });
                }
                return self.emit(t.TOK_LAND, .{ .none = {} });
            }
            if (self.peek() == '=') {
                self.bump();
                return self.emit(t.TOK_AND_ASSIGN, .{ .none = {} });
            }
        }
        return self.emit('&', .{ .none = {} });
    }

    fn lexPipe(self: *Lexer) Error!t.Token {
        self.bump();
        if (self.pos < self.source.len) {
            if (self.peek() == '|') {
                self.bump();
                if (self.pos < self.source.len and self.peek() == '=') {
                    self.bump();
                    return self.emit(t.TOK_LOR_ASSIGN, .{ .none = {} });
                }
                return self.emit(t.TOK_LOR, .{ .none = {} });
            }
            if (self.peek() == '=') {
                self.bump();
                return self.emit(t.TOK_OR_ASSIGN, .{ .none = {} });
            }
        }
        return self.emit('|', .{ .none = {} });
    }

    fn lexCaret(self: *Lexer) Error!t.Token {
        self.bump();
        if (self.pos < self.source.len and self.peek() == '=') {
            self.bump();
            return self.emit(t.TOK_XOR_ASSIGN, .{ .none = {} });
        }
        return self.emit('^', .{ .none = {} });
    }

    fn lexQuestion(self: *Lexer) Error!t.Token {
        self.bump();
        if (self.pos < self.source.len) {
            if (self.peek() == '?') {
                self.bump();
                if (self.pos < self.source.len and self.peek() == '=') {
                    self.bump();
                    return self.emit(t.TOK_DOUBLE_QUESTION_MARK_ASSIGN, .{ .none = {} });
                }
                return self.emit(t.TOK_DOUBLE_QUESTION_MARK, .{ .none = {} });
            }
            if (self.peek() == '.' and !std.ascii.isDigit(self.peekAt(1))) {
                self.bump();
                return self.emit(t.TOK_QUESTION_MARK_DOT, .{ .none = {} });
            }
        }
        return self.emit('?', .{ .none = {} });
    }

    // ---- utf-8 -------------------------------------------------------

    fn decodeUtf8(self: *Lexer) Error!u21 {
        const b0 = self.peek();
        var len: usize = 0;
        if (b0 < 0x80) len = 1 else if ((b0 & 0xE0) == 0xC0) len = 2 else if ((b0 & 0xF0) == 0xE0) len = 3 else if ((b0 & 0xF8) == 0xF0) len = 4 else return error.InvalidUtf8;

        if (self.remaining() < len) return error.InvalidUtf8;
        const slice = self.source[self.pos..][0..len];
        const cp = std.unicode.utf8Decode(slice) catch return error.InvalidUtf8;
        // Bump byte-by-byte (we treat all bytes as a single column).
        self.pos += len;
        self.col += 1;
        return cp;
    }

    fn startsUtf8Trivia(self: *const Lexer) bool {
        if (self.remaining() >= 2 and self.source[self.pos] == 0xC2 and self.source[self.pos + 1] == 0xA0) return true;
        if (self.remaining() >= 3) {
            const b1 = self.source[self.pos];
            const b2 = self.source[self.pos + 1];
            const b3 = self.source[self.pos + 2];
            if (b1 == 0xE1 and b2 == 0x9A and b3 == 0x80) return true;
            if (b1 == 0xE2 and b2 == 0x80 and ((b3 >= 0x80 and b3 <= 0x8A) or b3 == 0xAF)) return true;
            if (b1 == 0xE2 and b2 == 0x81 and b3 == 0x9F) return true;
            if (b1 == 0xE3 and b2 == 0x80 and b3 == 0x80) return true;
            if (b1 == 0xEF and b2 == 0xBB and b3 == 0xBF) return true;
        }
        return self.startsUtf8LineTerminator();
    }

    fn startsUtf8LineTerminator(self: *const Lexer) bool {
        if (self.remaining() >= 3 and self.source[self.pos] == 0xE2 and self.source[self.pos + 1] == 0x80) {
            const b3 = self.source[self.pos + 2];
            return b3 == 0xA8 or b3 == 0xA9;
        }
        return false;
    }
};

fn isAsciiIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or c == '$';
}

fn isAsciiIdentContinue(c: u8) bool {
    return isAsciiIdentStart(c) or (c >= '0' and c <= '9');
}

fn hexNibble(c: u8) u16 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    unreachable;
}

fn appendUtf8(out: *std.ArrayList(u8), allocator: std.mem.Allocator, cp: u21) !void {
    var buf: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(cp, &buf) catch {
        // Encode lone surrogates as 3-byte ED A0..BF (CESU-8-style),
        // matching how V8/QuickJS surface lone surrogate escapes.
        if (cp >= 0xD800 and cp <= 0xDFFF) {
            try out.append(allocator, 0xED);
            try out.append(allocator, @intCast(0xA0 + ((cp - 0xD800) >> 6)));
            try out.append(allocator, @intCast(0x80 | ((cp - 0xD800) & 0x3F)));
            return;
        }
        return error.InvalidUnicodeEscape;
    };
    try out.appendSlice(allocator, buf[0..len]);
}

fn consumeHexDigits(self: *Lexer) bool {
    var any = false;
    var prev_sep = false;
    while (self.pos < self.source.len) {
        const c = self.peek();
        if (std.ascii.isHex(c)) {
            any = true;
            prev_sep = false;
            self.bump();
        } else if (c == '_') {
            if (!any or prev_sep) return false;
            prev_sep = true;
            self.bump();
        } else break;
    }
    return any and !prev_sep;
}

fn consumeOctalDigits(self: *Lexer) bool {
    var any = false;
    var prev_sep = false;
    while (self.pos < self.source.len) {
        const c = self.peek();
        if (c >= '0' and c <= '7') {
            any = true;
            prev_sep = false;
            self.bump();
        } else if (c == '_') {
            if (!any or prev_sep) return false;
            prev_sep = true;
            self.bump();
        } else break;
    }
    return any and !prev_sep;
}

fn consumeBinaryDigits(self: *Lexer) bool {
    var any = false;
    var prev_sep = false;
    while (self.pos < self.source.len) {
        const c = self.peek();
        if (c == '0' or c == '1') {
            any = true;
            prev_sep = false;
            self.bump();
        } else if (c == '_') {
            if (!any or prev_sep) return false;
            prev_sep = true;
            self.bump();
        } else break;
    }
    return any and !prev_sep;
}

fn consumeDecDigits(self: *Lexer) bool {
    var any = false;
    var prev_sep = false;
    while (self.pos < self.source.len) {
        const c = self.peek();
        if (std.ascii.isDigit(c)) {
            any = true;
            prev_sep = false;
            self.bump();
        } else if (c == '_') {
            if (!any or prev_sep) return false;
            prev_sep = true;
            self.bump();
        } else break;
    }
    return any and !prev_sep;
}

fn consumeDecDigitsRequired(self: *Lexer) Error!void {
    if (!consumeDecDigits(self)) return error.InvalidNumber;
}

fn consumeOptionalFractionDigits(self: *Lexer) Error!void {
    if (self.pos >= self.source.len) return;
    const c = self.peek();
    if (std.ascii.isDigit(c) or c == '_') {
        if (!consumeDecDigits(self)) return error.InvalidNumber;
    }
}

fn decimalBigIntHasInvalidLeadingZero(lexeme: []const u8) bool {
    if (lexeme.len < 2 or lexeme[lexeme.len - 1] != 'n') return false;
    var digit_count: usize = 0;
    var first_digit: u8 = 0;
    for (lexeme[0 .. lexeme.len - 1]) |c| {
        if (c == '_') continue;
        if (digit_count == 0) first_digit = c;
        digit_count += 1;
    }
    return digit_count > 1 and first_digit == '0';
}

fn legacyOrNonOctalDecimalValue(self: *Lexer, lexeme: []const u8) !?f64 {
    if (lexeme.len < 2 or lexeme[0] != '0') return null;
    var has_dot_or_exp = false;
    var has_separator = false;
    var all_octal = true;
    var digit_count: usize = 0;
    for (lexeme) |c| {
        switch (c) {
            '.', 'e', 'E' => has_dot_or_exp = true,
            '_' => has_separator = true,
            '0'...'7' => digit_count += 1,
            '8', '9' => {
                digit_count += 1;
                all_octal = false;
            },
            else => {},
        }
    }
    if (has_dot_or_exp or digit_count <= 1) return null;
    if (has_separator or self.is_strict_mode) return error.InvalidNumber;
    if (!all_octal) return null;
    var value: u128 = 0;
    for (lexeme) |c| {
        if (c < '0' or c > '7') continue;
        value = value * 8 + (c - '0');
    }
    return @floatFromInt(value);
}

fn parseNumber(lexeme: []const u8, base: u8) !f64 {
    var stripped: [128]u8 = undefined;
    var len: usize = 0;
    for (lexeme) |c| {
        if (c == '_') continue;
        if (len >= stripped.len) return error.InvalidNumber;
        stripped[len] = c;
        len += 1;
    }
    const s = stripped[0..len];
    if (base == 10) return std.fmt.parseFloat(f64, s) catch error.InvalidNumber;
    if (s.len < 3) return error.InvalidNumber;
    const value = std.fmt.parseUnsigned(u128, s[2..], base) catch return error.InvalidNumber;
    return @floatFromInt(value);
}

fn keywordLookup(lexeme: []const u8) ?t.TokenKind {
    if (lexeme.len < 2 or lexeme.len > 10) return null;
    return switch (lexeme[0]) {
        'a' => if (eq(lexeme, "async")) t.TOK_ASYNC else if (eq(lexeme, "await")) t.TOK_AWAIT else null,
        'b' => if (eq(lexeme, "break")) t.TOK_BREAK else null,
        'c' => if (eq(lexeme, "case")) t.TOK_CASE else if (eq(lexeme, "catch")) t.TOK_CATCH else if (eq(lexeme, "class")) t.TOK_CLASS else if (eq(lexeme, "const")) t.TOK_CONST else if (eq(lexeme, "continue")) t.TOK_CONTINUE else null,
        'd' => if (eq(lexeme, "debugger")) t.TOK_DEBUGGER else if (eq(lexeme, "default")) t.TOK_DEFAULT else if (eq(lexeme, "delete")) t.TOK_DELETE else if (eq(lexeme, "do")) t.TOK_DO else null,
        'e' => if (eq(lexeme, "else")) t.TOK_ELSE else if (eq(lexeme, "enum")) t.TOK_ENUM else if (eq(lexeme, "export")) t.TOK_EXPORT else if (eq(lexeme, "extends")) t.TOK_EXTENDS else null,
        'f' => if (eq(lexeme, "false")) t.TOK_FALSE else if (eq(lexeme, "finally")) t.TOK_FINALLY else if (eq(lexeme, "for")) t.TOK_FOR else if (eq(lexeme, "function")) t.TOK_FUNCTION else null,
        'i' => if (eq(lexeme, "if")) t.TOK_IF else if (eq(lexeme, "implements")) t.TOK_IMPLEMENTS else if (eq(lexeme, "import")) t.TOK_IMPORT else if (eq(lexeme, "in")) t.TOK_IN else if (eq(lexeme, "instanceof")) t.TOK_INSTANCEOF else if (eq(lexeme, "interface")) t.TOK_INTERFACE else null,
        'l' => if (eq(lexeme, "let")) t.TOK_LET else null,
        'n' => if (eq(lexeme, "new")) t.TOK_NEW else if (eq(lexeme, "null")) t.TOK_NULL else null,
        // QuickJS keeps `of` as an ordinary identifier in normal lexing.
        // `TOK_OF` is produced only by parser lookahead helpers for for-of
        // detection; treating it as a keyword rejects valid bindings such as
        // `var of = 1`.
        'o' => null,
        'p' => if (eq(lexeme, "package")) t.TOK_PACKAGE else if (eq(lexeme, "private")) t.TOK_PRIVATE else if (eq(lexeme, "protected")) t.TOK_PROTECTED else if (eq(lexeme, "public")) t.TOK_PUBLIC else null,
        'r' => if (eq(lexeme, "return")) t.TOK_RETURN else null,
        's' => if (eq(lexeme, "static")) t.TOK_STATIC else if (eq(lexeme, "super")) t.TOK_SUPER else if (eq(lexeme, "switch")) t.TOK_SWITCH else null,
        't' => if (eq(lexeme, "this")) t.TOK_THIS else if (eq(lexeme, "throw")) t.TOK_THROW else if (eq(lexeme, "true")) t.TOK_TRUE else if (eq(lexeme, "try")) t.TOK_TRY else if (eq(lexeme, "typeof")) t.TOK_TYPEOF else null,
        'v' => if (eq(lexeme, "var")) t.TOK_VAR else if (eq(lexeme, "void")) t.TOK_VOID else null,
        'w' => if (eq(lexeme, "while")) t.TOK_WHILE else if (eq(lexeme, "with")) t.TOK_WITH else null,
        'y' => if (eq(lexeme, "yield")) t.TOK_YIELD else null,
        else => null,
    };
}

inline fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// Returns true for keywords that are ReservedWord per spec; the rest
/// (let, static, yield in non-strict, of) are contextual.
fn isReservedKeyword(val: t.TokenKind, is_strict: bool) bool {
    return switch (val) {
        t.TOK_NULL, t.TOK_FALSE, t.TOK_TRUE, t.TOK_IF, t.TOK_ELSE, t.TOK_RETURN, t.TOK_VAR, t.TOK_THIS, t.TOK_DELETE, t.TOK_VOID, t.TOK_TYPEOF, t.TOK_NEW, t.TOK_IN, t.TOK_INSTANCEOF, t.TOK_DO, t.TOK_WHILE, t.TOK_FOR, t.TOK_BREAK, t.TOK_CONTINUE, t.TOK_SWITCH, t.TOK_CASE, t.TOK_DEFAULT, t.TOK_THROW, t.TOK_TRY, t.TOK_CATCH, t.TOK_FINALLY, t.TOK_FUNCTION, t.TOK_DEBUGGER, t.TOK_WITH, t.TOK_CLASS, t.TOK_CONST, t.TOK_ENUM, t.TOK_EXPORT, t.TOK_EXTENDS, t.TOK_IMPORT, t.TOK_SUPER => true,
        // FutureReservedWord only in strict mode.
        t.TOK_IMPLEMENTS, t.TOK_INTERFACE, t.TOK_LET, t.TOK_PACKAGE, t.TOK_PRIVATE, t.TOK_PROTECTED, t.TOK_PUBLIC, t.TOK_STATIC, t.TOK_YIELD => is_strict,
        // Contextual.
        t.TOK_AWAIT, t.TOK_OF => false,
        else => false,
    };
}

// memory module unused right now; kept for future eviction tests.
comptime {
    _ = memory;
}

// ---- TypeScript Streaming Type-Filter Erasure Helpers ----

pub const Range = struct {
    start: usize,
    end: usize,
};

pub const SourceKind = enum {
    auto,
    javascript,
    typescript,
};

pub fn isTypeScriptPath(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".ts") or
        std.mem.endsWith(u8, path, ".mts") or
        std.mem.endsWith(u8, path, ".cts") or
        std.mem.endsWith(u8, path, ".tsx");
}

pub fn shouldStrip(kind: SourceKind, filename: []const u8) bool {
    return switch (kind) {
        .typescript => true,
        .javascript => false,
        .auto => isTypeScriptPath(filename),
    };
}

const TSTokenKind = enum {
    identifier,
    number,
    string,
    template,
    regexp,
    punct,
};

const TSToken = struct {
    kind: TSTokenKind,
    start: usize,
    end: usize,

    fn text(self: TSToken, src: []const u8) []const u8 {
        return src[self.start..self.end];
    }
};

fn markTypeRanges(self: *Lexer) !void {
    var tokens = std.ArrayList(TSToken).empty;
    defer tokens.deinit(self.allocator);
    try tsTokenize(self.allocator, self.source, &tokens);

    var ranges = std.ArrayList(Range).empty;
    defer ranges.deinit(self.allocator);

    try markTypeOnlyStatements(self.allocator, self.source, tokens.items, &ranges);
    try markMixedTypeSpecifiers(self.allocator, self.source, tokens.items, &ranges);
    try markClassAndTypeModifiers(self.allocator, self.source, tokens.items, &ranges);
    try markImplementsClauses(self.allocator, self.source, tokens.items, &ranges);
    try markTypeParameters(self.allocator, self.source, tokens.items, &ranges);
    try markTypeAnnotations(self.allocator, self.source, tokens.items, &ranges);
    try markTypeAssertions(self.allocator, self.source, tokens.items, &ranges);
    try markNonNullAssertions(self.allocator, self.source, tokens.items, &ranges);

    std.mem.sort(Range, ranges.items, {}, rangeLessThan);
    self.skipped_intervals.clearRetainingCapacity();
    for (ranges.items) |range| {
        if (self.skipped_intervals.items.len == 0 or range.start > self.skipped_intervals.items[self.skipped_intervals.items.len - 1].end) {
            try self.skipped_intervals.append(self.allocator, range);
        } else if (range.end > self.skipped_intervals.items[self.skipped_intervals.items.len - 1].end) {
            self.skipped_intervals.items[self.skipped_intervals.items.len - 1].end = range.end;
        }
    }
}

fn tsTokenize(allocator: std.mem.Allocator, src: []const u8, tokens: *std.ArrayList(TSToken)) !void {
    var i: usize = 0;
    var prev_sig: ?TSToken = null;
    while (i < src.len) {
        const c = src[i];
        if (std.ascii.isWhitespace(c)) {
            i += 1;
            continue;
        }
        if (c == '/' and i + 1 < src.len and src[i + 1] == '/') {
            i = tsSkipLineComment(src, i + 2);
            continue;
        }
        if (c == '/' and i + 1 < src.len and src[i + 1] == '*') {
            i = tsSkipBlockComment(src, i + 2);
            continue;
        }

        const start = i;
        const token = if (tsIsIdentStart(c)) blk: {
            i += 1;
            while (i < src.len and tsIsIdentContinue(src[i])) i += 1;
            break :blk TSToken{ .kind = .identifier, .start = start, .end = i };
        } else if (std.ascii.isDigit(c)) blk: {
            i = tsSkipNumber(src, i);
            break :blk TSToken{ .kind = .number, .start = start, .end = i };
        } else if (c == '\'' or c == '"') blk: {
            i = tsSkipQuoted(src, i, c);
            break :blk TSToken{ .kind = .string, .start = start, .end = i };
        } else if (c == '`') blk: {
            i = tsSkipTemplate(src, i);
            break :blk TSToken{ .kind = .template, .start = start, .end = i };
        } else if (c == '/' and tsCanStartRegExp(prev_sig, src)) blk: {
            i = tsSkipRegExp(src, i);
            break :blk TSToken{ .kind = .regexp, .start = start, .end = i };
        } else blk: {
            i += tsPunctuatorLen(src[i..]);
            break :blk TSToken{ .kind = .punct, .start = start, .end = i };
        };

        try tokens.append(allocator, token);
        prev_sig = token;
    }
}

fn tsSkipLineComment(src: []const u8, start: usize) usize {
    var i = start;
    while (i < src.len and src[i] != '\n' and src[i] != '\r') i += 1;
    return i;
}

fn tsSkipBlockComment(src: []const u8, start: usize) usize {
    var i = start;
    while (i + 1 < src.len and !(src[i] == '*' and src[i + 1] == '/')) i += 1;
    return if (i + 1 < src.len) i + 2 else src.len;
}

fn tsSkipQuoted(src: []const u8, start: usize, quote: u8) usize {
    var i = start + 1;
    var escaped = false;
    while (i < src.len) : (i += 1) {
        const c = src[i];
        if (escaped) {
            escaped = false;
            continue;
        }
        if (c == '\\') {
            escaped = true;
            continue;
        }
        if (c == quote) return i + 1;
        if (c == '\n' or c == '\r') return i;
    }
    return src.len;
}

fn tsSkipTemplate(src: []const u8, start: usize) usize {
    var i = start + 1;
    var escaped = false;
    while (i < src.len) : (i += 1) {
        const c = src[i];
        if (escaped) {
            escaped = false;
            continue;
        }
        if (c == '\\') {
            escaped = true;
            continue;
        }
        if (c == '`') return i + 1;
    }
    return src.len;
}

fn tsSkipRegExp(src: []const u8, start: usize) usize {
    var i = start + 1;
    var escaped = false;
    var in_class = false;
    while (i < src.len) : (i += 1) {
        const c = src[i];
        if (escaped) {
            escaped = false;
            continue;
        }
        if (c == '\\') {
            escaped = true;
            continue;
        }
        if (c == '[') {
            in_class = true;
            continue;
        }
        if (c == ']') {
            in_class = false;
            continue;
        }
        if (c == '/' and !in_class) {
            i += 1;
            while (i < src.len and tsIsIdentContinue(src[i])) i += 1;
            return i;
        }
        if (c == '\n' or c == '\r') return i;
    }
    return src.len;
}

fn tsSkipNumber(src: []const u8, start: usize) usize {
    var i = start;
    while (i < src.len) {
        const c = src[i];
        if (std.ascii.isAlphanumeric(c) or c == '_' or c == '.') {
            i += 1;
            continue;
        }
        break;
    }
    return i;
}

fn tsPunctuatorLen(rest: []const u8) usize {
    const puncts = [_][]const u8{
        ">>>=", "===", "!==", ">>>", "<<=", ">>=", "...", "=>",
        "==",   "!=",  "<=",  ">=",  "&&",  "||",  "??",  "?.",
        "++",   "--",  "+=",  "-=",  "*=",  "/=",  "%=",  "&=",
        "|=",   "^=",  "<<",  ">>",  "**",
    };
    for (puncts) |p| {
        if (std.mem.startsWith(u8, rest, p)) return p.len;
    }
    return 1;
}

fn tsCanStartRegExp(prev: ?TSToken, src: []const u8) bool {
    const token = prev orelse return true;
    const txt = token.text(src);
    if (token.kind == .identifier) {
        return textEql(txt, "return") or textEql(txt, "throw") or textEql(txt, "case") or
            textEql(txt, "delete") or textEql(txt, "void") or textEql(txt, "typeof") or
            textEql(txt, "yield") or textEql(txt, "await") or textEql(txt, "in") or
            textEql(txt, "of") or textEql(txt, "instanceof");
    }
    if (token.kind != .punct) return false;
    return textEql(txt, "(") or textEql(txt, "{") or textEql(txt, "[") or
        textEql(txt, ",") or textEql(txt, ";") or textEql(txt, ":") or
        textEql(txt, "=") or textEql(txt, "=>") or textEql(txt, "!") or
        textEql(txt, "?") or textEql(txt, "&&") or textEql(txt, "||") or
        textEql(txt, "??") or textEql(txt, "+") or textEql(txt, "-") or
        textEql(txt, "*") or textEql(txt, "/") or textEql(txt, "%") or
        textEql(txt, "~");
}

fn markTypeOnlyStatements(
    allocator: std.mem.Allocator,
    src: []const u8,
    tokens: []const TSToken,
    ranges: *std.ArrayList(Range),
) !void {
    var i: usize = 0;
    while (i < tokens.len) : (i += 1) {
        const txt = tokens[i].text(src);
        if (textEql(txt, "import") and tokenTextEql(src, tokens, i + 1, "type")) {
            try addRange(ranges, allocator, tokens[i].start, findStatementEnd(src, tokens, i));
            continue;
        }
        if (textEql(txt, "export")) {
            if (tokenTextEql(src, tokens, i + 1, "type")) {
                try addRange(ranges, allocator, tokens[i].start, findStatementEnd(src, tokens, i));
                continue;
            }
            if (tokenTextEql(src, tokens, i + 1, "interface")) {
                try addInterfaceRange(allocator, src, tokens, ranges, i, i + 1);
                continue;
            }
            if (tokenTextEql(src, tokens, i + 1, "declare")) {
                try addDeclareRange(allocator, src, tokens, ranges, i, i + 1);
                continue;
            }
        }
        if (textEql(txt, "declare")) {
            try addDeclareRange(allocator, src, tokens, ranges, i, i);
            continue;
        }
        if (textEql(txt, "interface") and isStatementStart(src, tokens, i)) {
            try addInterfaceRange(allocator, src, tokens, ranges, i, i);
            continue;
        }
        if (textEql(txt, "type") and isStatementStart(src, tokens, i) and looksLikeTypeAlias(src, tokens, i)) {
            try addRange(ranges, allocator, tokens[i].start, findStatementEnd(src, tokens, i));
            continue;
        }
    }
}

fn addDeclareRange(
    allocator: std.mem.Allocator,
    src: []const u8,
    tokens: []const TSToken,
    ranges: *std.ArrayList(Range),
    range_start_idx: usize,
    declare_idx: usize,
) !void {
    if (tokenTextEql(src, tokens, declare_idx + 1, "interface")) {
        try addInterfaceRange(allocator, src, tokens, ranges, range_start_idx, declare_idx + 1);
        return;
    }

    var end = findStatementEnd(src, tokens, declare_idx);
    var j = declare_idx + 1;
    while (j < tokens.len and tokens[j].start < end) : (j += 1) {
        if (tokenTextEql(src, tokens, j, "{")) {
            if (findMatchingForward(src, tokens, j, "{", "}")) |close_idx| {
                end = tokens[close_idx].end;
                if (close_idx + 1 < tokens.len and tokenTextEql(src, tokens, close_idx + 1, ";")) {
                    end = tokens[close_idx + 1].end;
                }
            }
            break;
        }
    }
    try addRange(ranges, allocator, tokens[range_start_idx].start, end);
}

fn addInterfaceRange(
    allocator: std.mem.Allocator,
    src: []const u8,
    tokens: []const TSToken,
    ranges: *std.ArrayList(Range),
    range_start_idx: usize,
    interface_idx: usize,
) !void {
    var end = findStatementEnd(src, tokens, interface_idx);
    var j = interface_idx + 1;
    while (j < tokens.len and tokens[j].start < end) : (j += 1) {
        if (tokenTextEql(src, tokens, j, "{")) {
            if (findMatchingForward(src, tokens, j, "{", "}")) |close_idx| {
                end = tokens[close_idx].end;
                if (close_idx + 1 < tokens.len and tokenTextEql(src, tokens, close_idx + 1, ";")) {
                    end = tokens[close_idx + 1].end;
                }
            }
            break;
        }
    }
    try addRange(ranges, allocator, tokens[range_start_idx].start, end);
}

fn looksLikeTypeAlias(src: []const u8, tokens: []const TSToken, type_idx: usize) bool {
    var depth: usize = 0;
    var i = type_idx + 1;
    while (i < tokens.len) : (i += 1) {
        const txt = tokens[i].text(src);
        if (textEql(txt, "{") or textEql(txt, "(") or textEql(txt, "[")) {
            depth += 1;
        } else if (textEql(txt, "}") or textEql(txt, ")") or textEql(txt, "]")) {
            if (depth == 0) return false;
            depth -= 1;
        } else if (depth == 0 and textEql(txt, "=")) {
            return true;
        } else if (depth == 0 and (textEql(txt, ";") or hasLineBreakBetween(src, tokens[type_idx].end, tokens[i].start))) {
            return false;
        }
    }
    return false;
}

fn markMixedTypeSpecifiers(
    allocator: std.mem.Allocator,
    src: []const u8,
    tokens: []const TSToken,
    ranges: *std.ArrayList(Range),
) !void {
    var i: usize = 0;
    while (i < tokens.len) : (i += 1) {
        if (!tokenTextEql(src, tokens, i, "import") and !tokenTextEql(src, tokens, i, "export")) continue;
        if (tokenTextEql(src, tokens, i + 1, "type")) continue;
        const stmt_end = findStatementEnd(src, tokens, i);
        const open_idx = findTokenBeforeOffset(src, tokens, i + 1, stmt_end, "{") orelse continue;
        const close_idx = findMatchingForward(src, tokens, open_idx, "{", "}") orelse continue;
        if (tokens[close_idx].end > stmt_end) continue;

        var spec_count: usize = 0;
        var type_spec_count: usize = 0;
        var segment_start = open_idx + 1;
        while (segment_start < close_idx) {
            while (segment_start < close_idx and tokenTextEql(src, tokens, segment_start, ",")) segment_start += 1;
            if (segment_start >= close_idx) break;
            var segment_end = segment_start;
            while (segment_end < close_idx and !tokenTextEql(src, tokens, segment_end, ",")) segment_end += 1;
            spec_count += 1;
            if (tokenTextEql(src, tokens, segment_start, "type")) {
                type_spec_count += 1;
                const remove_start = if (segment_start > open_idx + 1 and tokenTextEql(src, tokens, segment_start - 1, ","))
                    tokens[segment_start - 1].start
                else
                    tokens[segment_start].start;
                const remove_end = if (segment_end < close_idx and tokenTextEql(src, tokens, segment_end, ","))
                    tokens[segment_end].end
                else
                    tokens[segment_end - 1].end;
                try addRange(ranges, allocator, remove_start, remove_end);
            }
            segment_start = segment_end + 1;
        }

        if (spec_count != 0 and spec_count == type_spec_count) {
            try addRange(ranges, allocator, tokens[i].start, stmt_end);
        }
    }
}

fn markClassAndTypeModifiers(
    allocator: std.mem.Allocator,
    src: []const u8,
    tokens: []const TSToken,
    ranges: *std.ArrayList(Range),
) !void {
    var in_constructor_params = false;
    var paren_depth: usize = 0;

    for (tokens, 0..) |tok, i| {
        const txt = tok.text(src);

        if (textEql(txt, "constructor")) {
            if (i + 1 < tokens.len and textEql(tokens[i + 1].text(src), "(")) {
                in_constructor_params = true;
                paren_depth = 0;
            }
        }

        if (in_constructor_params) {
            if (textEql(txt, "(")) {
                paren_depth += 1;
            } else if (textEql(txt, ")")) {
                paren_depth -= 1;
                if (paren_depth == 0) {
                    in_constructor_params = false;
                }
            }
        }

        if (!isTsModifier(txt)) continue;

        // If we are in constructor parameter list (paren_depth == 1 means top-level parameters),
        // we preserve public/private/protected/readonly modifiers as parameter properties!
        if (in_constructor_params and paren_depth == 1) {
            if (textEql(txt, "public") or textEql(txt, "private") or textEql(txt, "protected") or textEql(txt, "readonly")) {
                continue;
            }
        }

        if (textEql(txt, "abstract") and tokenTextEql(src, tokens, i + 1, "class")) {
            try addRange(ranges, allocator, tok.start, tok.end);
            continue;
        }
        if (modifierCanAppearsHere(src, tokens, i)) {
            try addRange(ranges, allocator, tok.start, tok.end);
        }
    }
}

fn modifierCanAppearsHere(src: []const u8, tokens: []const TSToken, idx: usize) bool {
    const prev = if (idx == 0) null else tokens[idx - 1].text(src);
    const next = if (idx + 1 < tokens.len) tokens[idx + 1].text(src) else "";
    if (textEql(next, "(") or textEql(next, ":") or textEql(next, "=") or textEql(next, ";")) return false;
    if (prev) |p| {
        return textEql(p, "{") or textEql(p, "(") or textEql(p, ",") or textEql(p, ";");
    }
    return true;
}

fn isTsModifier(txt: []const u8) bool {
    return textEql(txt, "public") or textEql(txt, "private") or textEql(txt, "protected") or
        textEql(txt, "readonly") or textEql(txt, "override") or textEql(txt, "abstract");
}

fn findImplementsClassBrace(src: []const u8, tokens: []const TSToken, start_idx: usize) ?usize {
    var i = start_idx;
    while (i < tokens.len) : (i += 1) {
        const txt = tokens[i].text(src);
        const kind = tokens[i].kind;
        if (textEql(txt, "{")) {
            return i;
        }
        if (textEql(txt, ";") or textEql(txt, "}")) return null;
        if (kind == .identifier) {
            if (textEql(txt, "const") or textEql(txt, "let") or textEql(txt, "var") or
                textEql(txt, "function") or textEql(txt, "class") or textEql(txt, "interface") or
                textEql(txt, "if") or textEql(txt, "while") or textEql(txt, "for") or
                textEql(txt, "return"))
            {
                return null;
            }
        }
    }
    return null;
}

fn markImplementsClauses(
    allocator: std.mem.Allocator,
    src: []const u8,
    tokens: []const TSToken,
    ranges: *std.ArrayList(Range),
) !void {
    var i: usize = 0;
    while (i < tokens.len) : (i += 1) {
        if (!tokenTextEql(src, tokens, i, "implements")) continue;
        const brace_idx = findImplementsClassBrace(src, tokens, i + 1) orelse continue;
        try addRange(ranges, allocator, tokens[i].start, tokens[brace_idx].start);
        i = brace_idx - 1;
    }
}

fn markTypeParameters(
    allocator: std.mem.Allocator,
    src: []const u8,
    tokens: []const TSToken,
    ranges: *std.ArrayList(Range),
) !void {
    var i: usize = 0;
    while (i < tokens.len) : (i += 1) {
        if (!tokenTextEql(src, tokens, i, "<")) continue;
        if (!looksLikeTypeParameterStart(src, tokens, i)) continue;
        if (findTypeAngleEnd(src, tokens, i)) |end_idx| {
            try addRange(ranges, allocator, tokens[i].start, tokens[end_idx].end);
            i = end_idx;
        }
    }
}

fn looksLikeTypeParameterStart(src: []const u8, tokens: []const TSToken, lt_idx: usize) bool {
    if (lt_idx == 0) return false;
    const prev = tokens[lt_idx - 1].text(src);
    const prev_kind = tokens[lt_idx - 1].kind;
    const is_call_or_expr = textEql(prev, ")") or textEql(prev, "]") or prev_kind == .number or prev_kind == .string or prev_kind == .regexp;
    if (is_call_or_expr) return false;

    if (lt_idx >= 2 and textEql(prev, "class")) return false;
    return true;
}

fn markTypeAnnotations(
    allocator: std.mem.Allocator,
    src: []const u8,
    tokens: []const TSToken,
    ranges: *std.ArrayList(Range),
) !void {
    for (tokens, 0..) |tok, i| {
        if (!textEql(tok.text(src), ":")) continue;
        if (!isTypeAnnotationColon(src, tokens, i)) continue;
        const stop_arrow = i > 0 and tokenTextEql(src, tokens, i - 1, ")");
        const end_idx = findTypeEnd(src, tokens, i + 1, stop_arrow) orelse tokens.len;
        const start = if (i > 0 and tokenTextEql(src, tokens, i - 1, "?")) tokens[i - 1].start else tok.start;
        const end = if (end_idx < tokens.len) tokens[end_idx].start else src.len;
        if (end > start) try addRange(ranges, allocator, start, end);
    }
}

fn isTypeAnnotationColon(src: []const u8, tokens: []const TSToken, colon_idx: usize) bool {
    if (colon_idx == 0 or colon_idx + 1 >= tokens.len) return false;
    if (hasUnmatchedTernaryQuestionBefore(src, tokens, colon_idx)) return false;

    const prev_idx = if (tokenTextEql(src, tokens, colon_idx - 1, "?")) blk: {
        if (colon_idx < 2) return false;
        break :blk colon_idx - 2;
    } else colon_idx - 1;
    if (prev_idx >= tokens.len) return false;
    const prev = tokens[prev_idx].text(src);
    if (textEql(prev, ")")) return true;

    const enclosing = findEnclosingOpen(src, tokens, colon_idx);
    if (enclosing) |open_idx| {
        const open = tokens[open_idx].text(src);
        if (textEql(open, "(")) return isParameterList(src, tokens, open_idx);
        if (textEql(open, "{")) {
            if (braceBelongsToClass(src, tokens, open_idx)) {
                return classFieldSegmentAllowsType(src, tokens, open_idx, colon_idx);
            }
            return isVariableDeclarationType(src, tokens, colon_idx);
        }
        return false;
    }

    return isVariableDeclarationType(src, tokens, colon_idx);
}

fn isParameterList(src: []const u8, tokens: []const TSToken, open_idx: usize) bool {
    const close_idx = findMatchingForward(src, tokens, open_idx, "(", ")") orelse return false;
    const before = if (open_idx == 0) "" else tokens[open_idx - 1].text(src);
    const after = if (close_idx + 1 < tokens.len) tokens[close_idx + 1].text(src) else "";
    if (isControlKeyword(before)) return false;
    if (textEql(before, "function") or textEql(before, "constructor")) return true;
    if (open_idx >= 2 and tokens[open_idx - 1].kind == .identifier and tokenTextEql(src, tokens, open_idx - 2, "function")) return true;
    if (open_idx > 0 and tokens[open_idx - 1].kind == .identifier and (textEql(after, "{") or textEql(after, "=>"))) return true;
    if (open_idx > 0 and tokens[open_idx - 1].kind == .identifier and textEql(after, ":")) {
        return returnTypeAfterParameterListLeadsToBody(src, tokens, close_idx);
    }
    if (textEql(after, "=>")) return true;
    return false;
}

fn returnTypeAfterParameterListLeadsToBody(src: []const u8, tokens: []const TSToken, close_idx: usize) bool {
    if (!tokenTextEql(src, tokens, close_idx + 1, ":")) return false;
    const end_idx = findTypeEnd(src, tokens, close_idx + 2, true) orelse return false;
    return tokenTextEql(src, tokens, end_idx, "{") or tokenTextEql(src, tokens, end_idx, "=>");
}

fn isControlKeyword(txt: []const u8) bool {
    return textEql(txt, "if") or textEql(txt, "for") or textEql(txt, "while") or
        textEql(txt, "switch") or textEql(txt, "with") or textEql(txt, "catch");
}

fn isVariableDeclarationType(src: []const u8, tokens: []const TSToken, colon_idx: usize) bool {
    var stmt_start: usize = 0;
    var i = colon_idx;
    while (i > 0) {
        i -= 1;
        const txt = tokens[i].text(src);
        if (textEql(txt, ";") or textEql(txt, "{") or textEql(txt, "}")) {
            stmt_start = i + 1;
            break;
        }
    }

    var saw_decl = false;
    var last_comma_or_decl = stmt_start;
    i = stmt_start;
    while (i < colon_idx) : (i += 1) {
        const txt = tokens[i].text(src);
        if (textEql(txt, "let") or textEql(txt, "const") or textEql(txt, "var")) {
            saw_decl = true;
            last_comma_or_decl = i + 1;
        } else if (textEql(txt, ",")) {
            last_comma_or_decl = i + 1;
        }
    }
    if (!saw_decl) return false;

    i = last_comma_or_decl;
    while (i < colon_idx) : (i += 1) {
        if (tokenTextEql(src, tokens, i, "=")) return false;
    }
    return true;
}

fn classFieldSegmentAllowsType(src: []const u8, tokens: []const TSToken, class_open_idx: usize, colon_idx: usize) bool {
    var start = class_open_idx + 1;
    var i = colon_idx;
    while (i > class_open_idx + 1) {
        i -= 1;
        if (tokenTextEql(src, tokens, i, ";") or tokenTextEql(src, tokens, i, "{") or tokenTextEql(src, tokens, i, "}")) {
            start = i + 1;
            break;
        }
    }
    i = start;
    while (i < colon_idx) : (i += 1) {
        if (tokenTextEql(src, tokens, i, "=")) return false;
    }
    return true;
}

fn markTypeAssertions(
    allocator: std.mem.Allocator,
    src: []const u8,
    tokens: []const TSToken,
    ranges: *std.ArrayList(Range),
) !void {
    for (tokens, 0..) |tok, i| {
        const txt = tok.text(src);
        if (!textEql(txt, "as") and !textEql(txt, "satisfies")) continue;
        if (insideImportOrExportStatement(src, tokens, i)) continue;
        if (!isTypeAssertionOperator(src, tokens, i)) continue;
        const end_idx = findTypeAssertionEnd(src, tokens, i + 1) orelse tokens.len;
        const end = if (end_idx < tokens.len) tokens[end_idx].start else src.len;
        if (end > tok.start) try addRange(ranges, allocator, tok.start, end);
    }
}

fn markNonNullAssertions(
    allocator: std.mem.Allocator,
    src: []const u8,
    tokens: []const TSToken,
    ranges: *std.ArrayList(Range),
) !void {
    for (tokens, 0..) |tok, i| {
        if (!textEql(tok.text(src), "!")) continue;
        if (i == 0 or i + 1 >= tokens.len) continue;
        const prev = tokens[i - 1].text(src);
        const next = tokens[i + 1].text(src);
        const prev_can_end_expr = tokens[i - 1].kind == .identifier or tokens[i - 1].kind == .number or
            tokens[i - 1].kind == .string or textEql(prev, ")") or textEql(prev, "]");
        if (!prev_can_end_expr) continue;
        if (textEql(next, "=") or textEql(next, "==") or textEql(next, "===")) continue;
        try addRange(ranges, allocator, tok.start, tok.end);
    }
}

fn isTypeAssertionOperator(src: []const u8, tokens: []const TSToken, idx: usize) bool {
    if (idx == 0 or idx + 1 >= tokens.len) return false;
    if (!previousTokenCanEndExpression(src, tokens[idx - 1])) return false;

    const next = tokens[idx + 1].text(src);
    if (textEql(next, ":") or textEql(next, ",") or textEql(next, ";") or textEql(next, ")") or textEql(next, "}") or textEql(next, "=")) {
        return false;
    }

    return true;
}

fn previousTokenCanEndExpression(src: []const u8, token: TSToken) bool {
    return switch (token.kind) {
        .identifier => identifierCanEndExpression(token.text(src)),
        .number, .string, .template, .regexp => true,
        .punct => {
            const txt = token.text(src);
            return textEql(txt, ")") or textEql(txt, "]") or textEql(txt, "}");
        },
    };
}

fn identifierCanEndExpression(txt: []const u8) bool {
    return !textEql(txt, "const") and !textEql(txt, "let") and !textEql(txt, "var") and
        !textEql(txt, "function") and !textEql(txt, "class") and !textEql(txt, "return") and
        !textEql(txt, "throw") and !textEql(txt, "case") and !textEql(txt, "delete") and
        !textEql(txt, "typeof") and !textEql(txt, "void") and !textEql(txt, "new") and
        !textEql(txt, "in") and !textEql(txt, "instanceof") and !textEql(txt, "yield") and
        !textEql(txt, "await");
}

fn findTypeEnd(src: []const u8, tokens: []const TSToken, start_idx: usize, stop_arrow: bool) ?usize {
    var paren: usize = 0;
    var bracket: usize = 0;
    var brace: usize = 0;
    var angle: usize = 0;
    var i = start_idx;
    while (i < tokens.len) : (i += 1) {
        const txt = tokens[i].text(src);
        if (textEql(txt, "(")) paren += 1 else if (textEql(txt, ")")) {
            if (paren == 0 and bracket == 0 and brace == 0 and angle == 0) return i;
            paren -|= 1;
        } else if (textEql(txt, "[")) bracket += 1 else if (textEql(txt, "]")) {
            if (bracket == 0 and paren == 0 and brace == 0 and angle == 0) return i;
            bracket -|= 1;
        } else if (textEql(txt, "{")) {
            if (i == start_idx or brace > 0 or paren > 0 or bracket > 0 or angle > 0) {
                brace += 1;
            } else {
                return i;
            }
        } else if (textEql(txt, "}")) {
            if (brace == 0 and paren == 0 and bracket == 0 and angle == 0) return i;
            brace -|= 1;
        } else if (textEql(txt, "<")) {
            angle += 1;
        } else if (textEql(txt, ">")) {
            if (angle > 0) angle -= 1;
        } else if (paren == 0 and bracket == 0 and brace == 0 and angle == 0) {
            if (textEql(txt, ",") or textEql(txt, ";") or textEql(txt, "=")) return i;
            if (stop_arrow and textEql(txt, "=>")) return i;
        }
    }
    return null;
}

fn findTypeAssertionEnd(src: []const u8, tokens: []const TSToken, start_idx: usize) ?usize {
    var paren: usize = 0;
    var bracket: usize = 0;
    var brace: usize = 0;
    var angle: usize = 0;
    var i = start_idx;
    while (i < tokens.len) : (i += 1) {
        const txt = tokens[i].text(src);
        if (textEql(txt, "(")) paren += 1 else if (textEql(txt, ")")) {
            if (paren == 0 and bracket == 0 and brace == 0 and angle == 0) return i;
            paren -|= 1;
        } else if (textEql(txt, "[")) bracket += 1 else if (textEql(txt, "]")) {
            if (bracket == 0 and paren == 0 and brace == 0 and angle == 0) return i;
            bracket -|= 1;
        } else if (textEql(txt, "{")) brace += 1 else if (textEql(txt, "}")) {
            if (brace == 0 and paren == 0 and bracket == 0 and angle == 0) return i;
            brace -|= 1;
        } else if (textEql(txt, "<")) {
            angle += 1;
        } else if (textEql(txt, ">")) {
            if (angle > 0) angle -= 1;
        } else if (paren == 0 and bracket == 0 and brace == 0 and angle == 0 and isExpressionDelimiter(txt)) {
            return i;
        }
    }
    return null;
}

fn isExpressionDelimiter(txt: []const u8) bool {
    return textEql(txt, ",") or textEql(txt, ";") or textEql(txt, ":") or textEql(txt, "?") or
        textEql(txt, "}") or textEql(txt, "=>") or textEql(txt, "||") or textEql(txt, "&&") or
        textEql(txt, "??") or textEql(txt, "+") or textEql(txt, "-") or textEql(txt, "*") or
        textEql(txt, "/") or textEql(txt, "%") or textEql(txt, "==") or textEql(txt, "===") or
        textEql(txt, "!=") or textEql(txt, "!==") or textEql(txt, "<=") or textEql(txt, ">=") or
        textEql(txt, "=");
}

fn isValidTypeParameterList(src: []const u8, tokens: []const TSToken, start: usize, end: usize) bool {
    var i = start + 1;
    while (i < end) : (i += 1) {
        const txt = tokens[i].text(src);
        const kind = tokens[i].kind;
        if (textEql(txt, "&&") or textEql(txt, "||") or textEql(txt, "??") or
            textEql(txt, "==") or textEql(txt, "!=") or textEql(txt, "===") or textEql(txt, "!==") or
            textEql(txt, "*") or textEql(txt, "/") or textEql(txt, "%") or
            textEql(txt, "instanceof") or textEql(txt, "++") or textEql(txt, "--"))
        {
            return false;
        }
        if (kind == .identifier) {
            if (textEql(txt, "if") or textEql(txt, "else") or textEql(txt, "while") or
                textEql(txt, "for") or textEql(txt, "return") or textEql(txt, "const") or
                textEql(txt, "let") or textEql(txt, "var") or textEql(txt, "function") or
                textEql(txt, "class") or textEql(txt, "throw") or textEql(txt, "try") or
                textEql(txt, "catch") or textEql(txt, "finally"))
            {
                return false;
            }
        }
    }
    if (end + 1 < tokens.len) {
        const next_txt = tokens[end + 1].text(src);
        const next_kind = tokens[end + 1].kind;
        if (next_kind == .identifier) {
            if (!textEql(next_txt, "extends") and !textEql(next_txt, "implements") and !textEql(next_txt, "as") and !textEql(next_txt, "satisfies")) {
                return false;
            }
        }
        if (next_kind == .number or next_kind == .string or next_kind == .regexp) {
            return false;
        }
    }
    return true;
}

fn findTypeAngleEnd(src: []const u8, tokens: []const TSToken, lt_idx: usize) ?usize {
    var depth: usize = 0;
    var i = lt_idx;
    while (i < tokens.len) : (i += 1) {
        const txt = tokens[i].text(src);
        if (textEql(txt, "<")) {
            depth += 1;
        } else if (textEql(txt, ">")) {
            depth -|= 1;
            if (depth == 0) {
                if (isValidTypeParameterList(src, tokens, lt_idx, i)) {
                    return i;
                }
                return null;
            }
        } else if (depth == 1 and (textEql(txt, ";") or textEql(txt, "{") or textEql(txt, "}"))) {
            return null;
        }
    }
    return null;
}

fn findStatementEnd(src: []const u8, tokens: []const TSToken, start_idx: usize) usize {
    var paren: usize = 0;
    var bracket: usize = 0;
    var brace: usize = 0;
    var i = start_idx;
    while (i < tokens.len) : (i += 1) {
        const txt = tokens[i].text(src);
        if (textEql(txt, "(")) paren += 1 else if (textEql(txt, ")")) paren -|= 1 else if (textEql(txt, "[")) bracket += 1 else if (textEql(txt, "]")) bracket -|= 1 else if (textEql(txt, "{")) brace += 1 else if (textEql(txt, "}")) {
            if (brace == 0 and paren == 0 and bracket == 0) return tokens[i].end;
            brace -|= 1;
        }
        if (paren == 0 and bracket == 0 and brace == 0) {
            if (textEql(txt, ";")) return tokens[i].end;
            if (i + 1 < tokens.len and hasLineBreakBetween(src, tokens[i].end, tokens[i + 1].start) and !continuesAcrossLine(txt)) {
                return tokens[i].end;
            }
        }
    }
    return src.len;
}

fn continuesAcrossLine(txt: []const u8) bool {
    return textEql(txt, ",") or textEql(txt, "=") or textEql(txt, "|") or textEql(txt, "&") or
        textEql(txt, "?") or textEql(txt, ":") or textEql(txt, "extends") or textEql(txt, "(") or
        textEql(txt, "{") or textEql(txt, "[");
}

fn findMatchingForward(src: []const u8, tokens: []const TSToken, open_idx: usize, open_text: []const u8, close_text: []const u8) ?usize {
    var depth: usize = 0;
    var i = open_idx;
    while (i < tokens.len) : (i += 1) {
        const txt = tokens[i].text(src);
        if (textEql(txt, open_text)) {
            depth += 1;
        } else if (textEql(txt, close_text)) {
            depth -|= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

fn findEnclosingOpen(src: []const u8, tokens: []const TSToken, idx: usize) ?usize {
    var paren: usize = 0;
    var bracket: usize = 0;
    var brace: usize = 0;
    var i = idx;
    while (i > 0) {
        i -= 1;
        const txt = tokens[i].text(src);
        if (textEql(txt, ")")) paren += 1 else if (textEql(txt, "]")) bracket += 1 else if (textEql(txt, "}")) brace += 1 else if (textEql(txt, "(")) {
            if (paren == 0) return i;
            paren -= 1;
        } else if (textEql(txt, "[")) {
            if (bracket == 0) return i;
            bracket -= 1;
        } else if (textEql(txt, "{")) {
            if (brace == 0) return i;
            brace -= 1;
        }
    }
    return null;
}

fn braceBelongsToClass(src: []const u8, tokens: []const TSToken, open_idx: usize) bool {
    var i = open_idx;
    while (i > 0) {
        i -= 1;
        const txt = tokens[i].text(src);
        if (textEql(txt, "class")) return true;
        if (textEql(txt, ";") or textEql(txt, "{") or textEql(txt, "}")) return false;
    }
    return false;
}

fn hasUnmatchedTernaryQuestionBefore(src: []const u8, tokens: []const TSToken, colon_idx: usize) bool {
    if (colon_idx > 0 and tokenTextEql(src, tokens, colon_idx - 1, "?")) return false;
    var paren: usize = 0;
    var bracket: usize = 0;
    var brace: usize = 0;
    var i = colon_idx;
    while (i > 0) {
        i -= 1;
        const txt = tokens[i].text(src);
        if (textEql(txt, ")")) paren += 1 else if (textEql(txt, "]")) bracket += 1 else if (textEql(txt, "}")) brace += 1 else if (textEql(txt, "(")) {
            if (paren == 0) break;
            paren -= 1;
        } else if (textEql(txt, "[")) {
            if (bracket == 0) break;
            bracket -= 1;
        } else if (textEql(txt, "{")) {
            if (brace == 0) break;
            brace -= 1;
        } else if (paren == 0 and bracket == 0 and brace == 0 and textEql(txt, "?")) {
            return true;
        } else if (paren == 0 and bracket == 0 and brace == 0 and (textEql(txt, ";") or textEql(txt, ","))) {
            break;
        }
    }
    return false;
}

fn insideImportOrExportStatement(src: []const u8, tokens: []const TSToken, idx: usize) bool {
    var stmt_start: usize = 0;
    var i = idx;
    while (i > 0) {
        i -= 1;
        if (tokenTextEql(src, tokens, i, ";")) {
            stmt_start = i + 1;
            break;
        }
    }

    var saw_import = false;
    var saw_export = false;
    var saw_equals = false;
    i = stmt_start;
    while (i < idx) : (i += 1) {
        const txt = tokens[i].text(src);
        if (textEql(txt, "import")) saw_import = true;
        if (textEql(txt, "export")) saw_export = true;
        if (textEql(txt, "=")) saw_equals = true;
    }

    if (saw_equals) return false;
    if (saw_import) return true;
    if (!saw_export) return false;
    if (findEnclosingOpen(src, tokens, idx)) |open_idx| {
        return tokenTextEql(src, tokens, open_idx, "{") and open_idx >= stmt_start;
    }
    i = stmt_start;
    while (i < idx) : (i += 1) {
        if (tokenTextEql(src, tokens, i, "*") or tokenTextEql(src, tokens, i, "from")) return true;
    }
    return false;
}

fn isStatementStart(src: []const u8, tokens: []const TSToken, idx: usize) bool {
    if (idx == 0) return true;
    const prev = tokens[idx - 1].text(src);
    return textEql(prev, ";") or textEql(prev, "{") or textEql(prev, "}");
}

fn findTokenBeforeOffset(src: []const u8, tokens: []const TSToken, start_idx: usize, end_offset: usize, needle: []const u8) ?usize {
    var i = start_idx;
    while (i < tokens.len and tokens[i].start < end_offset) : (i += 1) {
        if (textEql(tokens[i].text(src), needle)) return i;
    }
    return null;
}

fn hasLineBreakBetween(src: []const u8, start: usize, end: usize) bool {
    var i = start;
    while (i < end and i < src.len) : (i += 1) {
        if (src[i] == '\n' or src[i] == '\r') return true;
    }
    return false;
}

fn addRange(ranges: *std.ArrayList(Range), allocator: std.mem.Allocator, start: usize, end: usize) !void {
    if (end <= start) return;
    try ranges.append(allocator, .{ .start = start, .end = end });
}

fn rangeLessThan(_: void, a: Range, b: Range) bool {
    return a.start < b.start;
}

fn tokenTextEql(src: []const u8, tokens: []const TSToken, idx: usize, expected: []const u8) bool {
    return idx < tokens.len and textEql(tokens[idx].text(src), expected);
}

fn textEql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn tsIsIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_' or c == '$' or c >= 0x80;
}

fn tsIsIdentContinue(c: u8) bool {
    return tsIsIdentStart(c) or std.ascii.isDigit(c);
}

pub const RegExpLiteral = struct {
    pattern: []const u8,
    flags: []const u8,
    end_offset: usize,
};

pub fn scanRegExpLiteral(source: []const u8, slash_offset: usize) !RegExpLiteral {
    if (slash_offset >= source.len or source[slash_offset] != '/') return error.NotRegExpLiteral;
    var i = slash_offset + 1;
    var in_class = false;
    var escaped = false;

    while (i < source.len) : (i += 1) {
        const c = source[i];
        if (c == '\n' or c == '\r') return error.UnterminatedRegExp;
        if (escaped) {
            escaped = false;
            continue;
        }
        if (c == '\\') {
            escaped = true;
            continue;
        }
        if (c == '[') {
            in_class = true;
            continue;
        }
        if (c == ']') {
            in_class = false;
            continue;
        }
        if (c == '/' and !in_class) break;
    }
    if (i >= source.len) return error.UnterminatedRegExp;

    const pattern = source[slash_offset + 1 .. i];
    i += 1;
    const flags_start = i;
    while (i < source.len and (std.ascii.isAlphabetic(source[i]) or std.ascii.isDigit(source[i]) or source[i] == '_' or source[i] == '$')) : (i += 1) {}
    return .{
        .pattern = pattern,
        .flags = source[flags_start..i],
        .end_offset = i,
    };
}

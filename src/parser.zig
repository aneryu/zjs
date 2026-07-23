pub const subsystem_name = "parser";

pub const diagnostics = struct {
    const atom = @import("core/atom.zig");
    const memory = @import("core/memory.zig");

    pub const Position = struct {
        offset: usize = 0,
        line: u32 = 1,
        column: u32 = 1,
    };

    pub const Range = struct {
        start: Position,
        end: Position,
    };

    pub const SyntaxError = struct {
        memory: *memory.MemoryAccount,
        atoms: *atom.AtomTable,
        message: []u8,
        filename: atom.Atom = atom.null_atom,
        position: Position,

        pub fn create(account: *memory.MemoryAccount, atoms: *atom.AtomTable, filename: atom.Atom, position: Position, message: []const u8) !SyntaxError {
            const owned: []u8 = if (message.len == 0) &.{} else try account.alloc(u8, message.len);
            errdefer if (owned.len != 0) account.free(u8, owned);
            if (message.len != 0) @memcpy(owned, message);
            return .{
                .memory = account,
                .atoms = atoms,
                .message = owned,
                .filename = atoms.dup(filename),
                .position = position,
            };
        }

        pub fn deinit(self: *SyntaxError) void {
            const filename = self.filename;
            const message = self.message;
            self.filename = atom.null_atom;
            self.message = &.{};
            if (filename != atom.null_atom) self.atoms.free(filename);
            if (message.len != 0) self.memory.free(u8, message);
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

pub const token = struct {
    //! QuickJS-aligned token API mirroring `JSToken` and `TOK_*` from
    //! QuickJS `quickjs.c:21246..21645`.
    //!
    //! Strong-alignment contract:
    //!   * `Kind` integer values match `enum { TOK_NUMBER = -128, ... }`
    //!     in `quickjs.c:21246` exactly.
    //!   * Single-character punctuators reuse their raw ASCII byte (so `+`
    //!     is `0x2B`, `;` is `0x3B`, …) — QuickJS does the same.
    //!   * The keyword block `TOK_NULL..TOK_AWAIT` is laid out so that
    //!     `tokenAtomFromKeyword(tok) == ATOM_null + (tok - TOK_NULL)`
    //!     because `quickjs-atom.h:29..76` matches `quickjs.c:21291..21338`
    //!     row-for-row. `keywordAtomAlignmentTest` enforces the invariant.

    const std = @import("std");
    const atom = @import("core/atom.zig");

    /// QuickJS-equivalent of `enum { TOK_NUMBER = -128, ... }`.
    /// Stored as `i16` to make signedness and overflow explicit.
    pub const Kind = i16;

    pub const TOK_NUMBER: Kind = -128;
    pub const TOK_STRING: Kind = -127;
    pub const TOK_TEMPLATE: Kind = -126;
    pub const TOK_IDENT: Kind = -125;
    pub const TOK_REGEXP: Kind = -124;

    // Order is significant: js_parse_assign_expr2 derives the assignment
    // opcode from `OP_mul + (op - TOK_MUL_ASSIGN)`.
    pub const TOK_MUL_ASSIGN: Kind = -123;
    pub const TOK_DIV_ASSIGN: Kind = -122;
    pub const TOK_MOD_ASSIGN: Kind = -121;
    pub const TOK_PLUS_ASSIGN: Kind = -120;
    pub const TOK_MINUS_ASSIGN: Kind = -119;
    pub const TOK_SHL_ASSIGN: Kind = -118;
    pub const TOK_SAR_ASSIGN: Kind = -117;
    pub const TOK_SHR_ASSIGN: Kind = -116;
    pub const TOK_AND_ASSIGN: Kind = -115;
    pub const TOK_XOR_ASSIGN: Kind = -114;
    pub const TOK_OR_ASSIGN: Kind = -113;
    pub const TOK_POW_ASSIGN: Kind = -112;
    pub const TOK_LAND_ASSIGN: Kind = -111;
    pub const TOK_LOR_ASSIGN: Kind = -110;
    pub const TOK_DOUBLE_QUESTION_MARK_ASSIGN: Kind = -109;

    pub const TOK_DEC: Kind = -108;
    pub const TOK_INC: Kind = -107;
    pub const TOK_SHL: Kind = -106;
    pub const TOK_SAR: Kind = -105;
    pub const TOK_SHR: Kind = -104;
    pub const TOK_LT: Kind = -103;
    pub const TOK_LTE: Kind = -102;
    pub const TOK_GT: Kind = -101;
    pub const TOK_GTE: Kind = -100;
    pub const TOK_EQ: Kind = -99;
    pub const TOK_STRICT_EQ: Kind = -98;
    pub const TOK_NEQ: Kind = -97;
    pub const TOK_STRICT_NEQ: Kind = -96;
    pub const TOK_LAND: Kind = -95;
    pub const TOK_LOR: Kind = -94;
    pub const TOK_POW: Kind = -93;
    pub const TOK_ARROW: Kind = -92;
    pub const TOK_ELLIPSIS: Kind = -91;
    pub const TOK_DOUBLE_QUESTION_MARK: Kind = -90;
    pub const TOK_QUESTION_MARK_DOT: Kind = -89;
    pub const TOK_ERROR: Kind = -88;
    pub const TOK_PRIVATE_NAME: Kind = -87;
    pub const TOK_EOF: Kind = -86;

    // Keyword block — order MUST match `quickjs-atom.h:29..76` so that
    // `s->token.u.ident.atom == ATOM_null + (s->token.val - TOK_NULL)`
    // for any keyword token, exactly like QuickJS.
    pub const TOK_NULL: Kind = -85;
    pub const TOK_FALSE: Kind = -84;
    pub const TOK_TRUE: Kind = -83;
    pub const TOK_IF: Kind = -82;
    pub const TOK_ELSE: Kind = -81;
    pub const TOK_RETURN: Kind = -80;
    pub const TOK_VAR: Kind = -79;
    pub const TOK_THIS: Kind = -78;
    pub const TOK_DELETE: Kind = -77;
    pub const TOK_VOID: Kind = -76;
    pub const TOK_TYPEOF: Kind = -75;
    pub const TOK_NEW: Kind = -74;
    pub const TOK_IN: Kind = -73;
    pub const TOK_INSTANCEOF: Kind = -72;
    pub const TOK_DO: Kind = -71;
    pub const TOK_WHILE: Kind = -70;
    pub const TOK_FOR: Kind = -69;
    pub const TOK_BREAK: Kind = -68;
    pub const TOK_CONTINUE: Kind = -67;
    pub const TOK_SWITCH: Kind = -66;
    pub const TOK_CASE: Kind = -65;
    pub const TOK_DEFAULT: Kind = -64;
    pub const TOK_THROW: Kind = -63;
    pub const TOK_TRY: Kind = -62;
    pub const TOK_CATCH: Kind = -61;
    pub const TOK_FINALLY: Kind = -60;
    pub const TOK_FUNCTION: Kind = -59;
    pub const TOK_DEBUGGER: Kind = -58;
    pub const TOK_WITH: Kind = -57;
    pub const TOK_CLASS: Kind = -56;
    pub const TOK_CONST: Kind = -55;
    pub const TOK_ENUM: Kind = -54;
    pub const TOK_EXPORT: Kind = -53;
    pub const TOK_EXTENDS: Kind = -52;
    pub const TOK_IMPORT: Kind = -51;
    pub const TOK_SUPER: Kind = -50;
    pub const TOK_IMPLEMENTS: Kind = -49;
    pub const TOK_INTERFACE: Kind = -48;
    pub const TOK_LET: Kind = -47;
    pub const TOK_PACKAGE: Kind = -46;
    pub const TOK_PRIVATE: Kind = -45;
    pub const TOK_PROTECTED: Kind = -44;
    pub const TOK_PUBLIC: Kind = -43;
    pub const TOK_STATIC: Kind = -42;
    pub const TOK_YIELD: Kind = -41;
    pub const TOK_AWAIT: Kind = -40;
    pub const TOK_OF: Kind = -39;
    pub const TOK_ASYNC: Kind = -38;

    pub const TOK_FIRST_KEYWORD: Kind = TOK_NULL;
    pub const TOK_LAST_KEYWORD: Kind = TOK_AWAIT;

    pub fn isKeyword(val: Kind) bool {
        return val >= TOK_FIRST_KEYWORD and val <= TOK_LAST_KEYWORD;
    }

    /// Map a keyword token id to its predefined atom. Mirrors the QuickJS
    /// invariant `s->token.u.ident.atom = atom_null + (val - TOK_NULL)`
    /// (see `quickjs.c:21649`). Predefined atom ids start at 1 and the
    /// 47 keywords occupy ids 1..47 in `quickjs-atom.h:29..76`.
    pub fn keywordAtom(val: Kind) atom.Atom {
        std.debug.assert(isKeyword(val));
        return atom.ids.null_ + @as(atom.Atom, @intCast(val - TOK_NULL));
    }

    /// Per-token payload union (mirrors JSToken's anonymous union).
    pub const TemplatePart = enum(u8) {
        no_substitution, // `...`
        head, // `... ${
        middle, // }... ${
        tail, // }...`
    };

    pub const Payload = union(enum) {
        none,
        /// TOK_NUMBER — for now we keep both the lexeme bytes and the parsed
        /// double; bigint is reported via `is_bigint`. F4 will move to a
        /// JSValue payload (matching `JSToken.u.num.val`).
        num: struct {
            value: f64,
            is_bigint: bool = false,
            bigint_text: []const u8 = "",
        },
        /// TOK_STRING / TOK_TEMPLATE — owns the decoded UTF-8 byte slice.
        /// `sep` matches QuickJS `JSToken.u.str.sep` (`'`, `"`, `` ` ``, or
        /// the substitution delimiter).
        str: struct {
            bytes: []u8,
            raw_bytes: []u8 = &.{},
            cooked_invalid: bool = false,
            contains_escape: bool = false,
            contains_legacy_escape: bool = false,
            sep: u8,
            template: ?TemplatePart = null,
        },
        /// TOK_IDENT, TOK_PRIVATE_NAME, and any keyword.
        ident: struct {
            atom: atom.Atom,
            has_escape: bool,
            is_reserved: bool,
        },
        /// TOK_REGEXP — pattern + flags as raw source bytes (compiled in F12).
        regexp: struct {
            pattern: []const u8,
            flags: []const u8,
        },
    };

    /// QuickJS-aligned token. Mirrors `JSToken` (quickjs.c:21539) with the
    /// same field set (`val`, `line_num`, `col_num`, `ptr`) plus a sum type
    /// for the per-kind payload. Lifetime: `payload.str.bytes` and optional
    /// `payload.str.raw_bytes` are owned by
    /// the lexer's allocator; `payload.regexp.{pattern,flags}` are slices
    /// into the source buffer.
    pub const TokenImpl = struct {
        val: Kind,
        line_num: u32,
        col_num: u32,
        /// Pointer to the first byte of the token in the source buffer.
        ptr: [*]const u8,
        /// Length of the token in source bytes. Not present in JSToken
        /// (which uses `s->buf_ptr - s->mark`); we expose it for tests.
        len: usize,
        payload: Payload,
    };

    test "F1: keyword token integer values match QuickJS TOK_*" {
        // Spot-check anchors from quickjs.c:21246..21338.
        try std.testing.expectEqual(@as(Kind, -128), TOK_NUMBER);
        try std.testing.expectEqual(@as(Kind, -127), TOK_STRING);
        try std.testing.expectEqual(@as(Kind, -125), TOK_IDENT);
        try std.testing.expectEqual(@as(Kind, -86), TOK_EOF);
        try std.testing.expectEqual(@as(Kind, -85), TOK_NULL);
        try std.testing.expectEqual(@as(Kind, -40), TOK_AWAIT);
        try std.testing.expectEqual(@as(Kind, -39), TOK_OF);
    }
    pub const TokenKind = Kind;
    pub const Token = TokenImpl;
};

pub const lexer = struct {
    //! QuickJS-aligned lexer.
    //!
    //! Mirrors `next_token`, `js_parse_string`, `js_parse_template_part`,
    //! `js_parse_regexp`, and the helpers around them in
    //! QuickJS `quickjs.c:21794..23200`.
    //!

    const std = @import("std");
    const atom_module = @import("core/atom.zig");
    const memory = @import("core/memory.zig");
    const unicode = @import("libs/unicode.zig");
    const t = token;

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

    pub const LexerImpl = struct {
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
        ) LexerImpl {
            return .{
                .allocator = allocator,
                .atoms = atoms,
                .source = source,
                .skipped_intervals = std.ArrayList(Range).empty,
            };
        }

        pub fn deinit(self: *LexerImpl) void {
            self.skipped_intervals.deinit(self.allocator);
        }

        pub fn enableTypeScript(self: *LexerImpl) !void {
            self.is_typescript = true;
            try markTypeRanges(self);
        }

        fn getSkippedIntervalAtPos(self: *const LexerImpl, pos: usize) ?Range {
            for (self.skipped_intervals.items) |range| {
                if (range.start == pos) return range;
                if (range.start > pos) break;
            }
            return null;
        }

        fn skipRange(self: *LexerImpl, range: Range) bool {
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

        pub fn freeToken(self: *LexerImpl, tok: *t.Token) void {
            switch (tok.payload) {
                .str => |s| {
                    if (s.bytes.len > 0 and !self.isSourceSlice(s.bytes)) self.allocator.free(s.bytes);
                    if (s.raw_bytes.len > 0 and !self.isSourceSlice(s.raw_bytes)) self.allocator.free(s.raw_bytes);
                },
                else => {},
            }
            tok.payload = .none;
        }

        fn isSourceSlice(self: *const LexerImpl, bytes: []const u8) bool {
            if (bytes.len == 0) return true;
            const source_start = @intFromPtr(self.source.ptr);
            const source_end = source_start + self.source.len;
            const bytes_start = @intFromPtr(bytes.ptr);
            const bytes_end = bytes_start + bytes.len;
            return bytes_start >= source_start and bytes_end <= source_end;
        }

        /// Return whether a line terminator was seen before the most recent token.
        pub fn gotLineTerminator(self: *LexerImpl) bool {
            return self.got_lf;
        }

        /// Produce the next token. Returns `TOK_EOF` at end of input.
        pub fn next(self: *LexerImpl) Error!t.Token {
            try self.skipTrivia();
            self.mark();

            if (self.pos >= self.source.len) {
                return self.emit(t.TOK_EOF, .{ .none = {} });
            }

            const c = self.peek();

            if (isAsciiIdentStart(c) or c >= 0x80 or self.startsUnicodeEscape()) {
                return self.lexIdentifier();
            }
            if (isDecimalDigit(c)) return self.lexNumber(false);
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
        /// **LexerImpl position contract**: must be called with `pos` AT the
        /// closing `}` byte. The `nextTemplatePartAfterBrace` variant is
        /// for the parser case where the `}` has already been advanced past
        /// (i.e. the parser observed `}` as the lookahead token after the
        /// substitution's expression, so `lex.pos` is one byte past `}`).
        pub fn nextTemplatePart(self: *LexerImpl) Error!t.Token {
            self.mark();
            return self.lexTemplate(.middle_or_tail);
        }

        /// Like `nextTemplatePart`, but assumes the closing `}` has already
        /// been lexed and consumed by the parser's lookahead. Used by the
        /// expression parser, which discovers `}` only via its standard
        /// post-expression lookahead.
        pub fn nextTemplatePartAfterBrace(self: *LexerImpl) Error!t.Token {
            self.mark();
            return self.lexTemplateBody(.middle_or_tail, false);
        }

        /// Re-lex the most recently emitted `/`/`/=` punctuator as a regex
        /// literal. Mirrors the QuickJS pattern of letting the parser ask
        /// for a regexp once it knows it's in a regexp-allowed context
        /// (`js_parse_regexp`, `quickjs.c:22005`). The caller passes the
        /// `mark_pos` recorded before the slash so we restart from there.
        pub fn rescanRegexp(self: *LexerImpl, slash_offset: usize) Error!t.Token {
            // Reset position back to the slash. The caller is responsible
            // for having recorded `mark_line`/`mark_col` before the slash.
            self.pos = slash_offset;
            self.line = self.mark_line;
            self.col = self.mark_col;
            self.mark();
            return self.lexRegexp();
        }

        // ---- internals ---------------------------------------------------

        inline fn peek(self: *const LexerImpl) u8 {
            return self.source[self.pos];
        }

        inline fn peekAt(self: *const LexerImpl, n: usize) u8 {
            return if (self.pos + n < self.source.len) self.source[self.pos + n] else 0;
        }

        inline fn remaining(self: *const LexerImpl) usize {
            return self.source.len - self.pos;
        }

        inline fn bump(self: *LexerImpl) void {
            const b = self.source[self.pos];
            self.pos += 1;
            if (b == '\n') {
                self.line += 1;
                self.col = 1;
            } else {
                self.col += 1;
            }
        }

        fn mark(self: *LexerImpl) void {
            self.mark_pos = self.pos;
            self.mark_line = self.line;
            self.mark_col = self.col;
        }

        fn emit(self: *LexerImpl, val: t.TokenKind, payload: t.Payload) t.Token {
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

        fn skipTrivia(self: *LexerImpl) Error!void {
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

        fn skipLineComment(self: *LexerImpl) Error!void {
            while (self.pos < self.source.len) {
                const c = self.peek();
                if (c == '\n' or c == '\r') return;
                if (isUtf8LineSeparator(self)) return;
                self.bump();
            }
        }

        fn skipNonAsciiWhiteSpace(self: *LexerImpl) ?bool {
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

        fn isUtf8LineSeparator(self: *LexerImpl) bool {
            return self.remaining() >= 3 and self.peek() == 0xE2 and self.peekAt(1) == 0x80 and
                (self.peekAt(2) == 0xA8 or self.peekAt(2) == 0xA9);
        }

        fn skipBlockComment(self: *LexerImpl) Error!bool {
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

        fn startsWithBytes(self: *const LexerImpl, lit: []const u8) bool {
            if (self.remaining() < lit.len) return false;
            return std.mem.eql(u8, self.source[self.pos..][0..lit.len], lit);
        }

        fn startsUnicodeEscape(self: *const LexerImpl) bool {
            return self.remaining() >= 2 and self.peek() == '\\' and self.peekAt(1) == 'u';
        }

        // ---- identifiers / keywords --------------------------------------

        fn lexIdentifier(self: *LexerImpl) Error!t.Token {
            if (try self.lexAsciiIdentifierNoEscape()) |ident_token| return ident_token;

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

        fn lexAsciiIdentifierNoEscape(self: *LexerImpl) Error!?t.Token {
            if (self.peek() == '\\' or self.peek() >= 0x80) return null;

            const start = self.pos;
            const start_line = self.line;
            const start_col = self.col;
            self.bump();
            while (self.pos < self.source.len) {
                const c = self.peek();
                if (isAsciiIdentContinue(c)) {
                    self.bump();
                    continue;
                }
                if (c == '\\' or c >= 0x80) {
                    self.pos = start;
                    self.line = start_line;
                    self.col = start_col;
                    return null;
                }
                break;
            }

            const lexeme = self.source[start..self.pos];
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

            const a = try self.atoms.internString(lexeme);
            return self.emit(t.TOK_IDENT, .{ .ident = .{
                .atom = a,
                .has_escape = false,
                .is_reserved = false,
            } });
        }

        fn isNonAsciiTriviaStart(self: *LexerImpl) bool {
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

        fn consumeIdentCodePoint(self: *LexerImpl, out: *std.ArrayList(u8), is_start: bool) Error!void {
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

        fn lexPrivateName(self: *LexerImpl) Error!t.Token {
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

        fn lexDotOrNumber(self: *LexerImpl) Error!t.Token {
            if (self.peekAt(1) == '.' and self.peekAt(2) == '.') {
                self.bump();
                self.bump();
                self.bump();
                return self.emit(t.TOK_ELLIPSIS, .{ .none = {} });
            }
            if (isDecimalDigit(self.peekAt(1))) {
                return self.lexNumber(true);
            }
            self.bump();
            return self.emit('.', .{ .none = {} });
        }

        fn lexNumber(self: *LexerImpl, leading_dot: bool) Error!t.Token {
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

        fn finishNumber(self: *LexerImpl, start: usize, is_bigint: bool, base: u8) Error!t.Token {
            // Reject identifier characters immediately after a numeric literal
            // (e.g. `123abc` is a single error per spec, not two tokens).
            if (self.pos < self.source.len) {
                const nc = self.peek();
                if (isAsciiIdentContinue(nc) or (nc >= 0x80 and !self.startsUtf8Trivia())) {
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

        fn lexString(self: *LexerImpl, quote: u8) Error!t.Token {
            self.bump(); // opening quote
            const content_start = self.pos;
            while (self.pos < self.source.len) {
                const c = self.peek();
                if (c == quote) {
                    const bytes = @constCast(self.source[content_start..self.pos]);
                    self.bump();
                    return self.emit(t.TOK_STRING, .{ .str = .{
                        .bytes = bytes,
                        .contains_escape = false,
                        .contains_legacy_escape = false,
                        .sep = quote,
                    } });
                }
                if (c == '\n' or c == '\r') return error.UnterminatedString;
                if (c == '\\') break;
                self.bump();
            }
            if (self.pos >= self.source.len) return error.UnterminatedString;

            var buf = std.ArrayList(u8).empty;
            defer buf.deinit(self.allocator);
            try buf.appendSlice(self.allocator, self.source[content_start..self.pos]);
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

        fn decodeStringEscape(self: *LexerImpl, out: *std.ArrayList(u8), in_template: bool) Error!bool {
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
                    if (self.pos + 1 < self.source.len and isDecimalDigit(self.peekAt(1))) {
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
                    if (!unicode.isAsciiHexDigitByte(h1) or !unicode.isAsciiHexDigitByte(h2)) return error.InvalidEscape;
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

        fn consumeLegacyOctalEscape(self: *LexerImpl) Error!u21 {
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
        fn consumeUnicodeEscapeAfterBackslash(self: *LexerImpl) Error!u21 {
            if (self.peek() != 'u') return error.InvalidUnicodeEscape;
            self.bump();
            if (self.pos < self.source.len and self.peek() == '{') {
                self.bump();
                var value: u32 = 0;
                var saw_digit = false;
                while (self.pos < self.source.len and self.peek() != '}') {
                    const d = self.peek();
                    if (!unicode.isAsciiHexDigitByte(d)) return error.InvalidUnicodeEscape;
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

        fn consumeUnicodeEscape(self: *LexerImpl) Error!u21 {
            if (self.peek() != '\\') return error.InvalidUnicodeEscape;
            self.bump();
            return self.consumeUnicodeEscapeAfterBackslash();
        }

        fn consumeFourHex(self: *LexerImpl) Error!u16 {
            if (self.remaining() < 4) return error.InvalidUnicodeEscape;
            var v: u16 = 0;
            var i: u8 = 0;
            while (i < 4) : (i += 1) {
                const d = self.peek();
                if (!unicode.isAsciiHexDigitByte(d)) return error.InvalidUnicodeEscape;
                v = v * 16 + hexNibble(d);
                self.bump();
            }
            return v;
        }

        // ---- templates ---------------------------------------------------

        const TemplatePhase = enum { head_or_no_subst, middle_or_tail };

        fn lexTemplate(self: *LexerImpl, phase: TemplatePhase) Error!t.Token {
            return self.lexTemplateBody(phase, true);
        }

        fn lexTemplateBody(self: *LexerImpl, phase: TemplatePhase, expect_open_byte: bool) Error!t.Token {
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

        fn lexRegexp(self: *LexerImpl) Error!t.Token {
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

        fn lexPunctuator(self: *LexerImpl) Error!t.Token {
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

        fn lexPlus(self: *LexerImpl) Error!t.Token {
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

        fn lexMinus(self: *LexerImpl) Error!t.Token {
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

        fn lexStar(self: *LexerImpl) Error!t.Token {
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

        fn lexSlash(self: *LexerImpl) Error!t.Token {
            self.bump();
            if (self.pos < self.source.len and self.peek() == '=') {
                self.bump();
                return self.emit(t.TOK_DIV_ASSIGN, .{ .none = {} });
            }
            return self.emit('/', .{ .none = {} });
        }

        fn lexPercent(self: *LexerImpl) Error!t.Token {
            self.bump();
            if (self.pos < self.source.len and self.peek() == '=') {
                self.bump();
                return self.emit(t.TOK_MOD_ASSIGN, .{ .none = {} });
            }
            return self.emit('%', .{ .none = {} });
        }

        fn lexEquals(self: *LexerImpl) Error!t.Token {
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

        fn lexBang(self: *LexerImpl) Error!t.Token {
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

        fn lexLt(self: *LexerImpl) Error!t.Token {
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

        fn lexGt(self: *LexerImpl) Error!t.Token {
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

        fn lexAmp(self: *LexerImpl) Error!t.Token {
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

        fn lexPipe(self: *LexerImpl) Error!t.Token {
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

        fn lexCaret(self: *LexerImpl) Error!t.Token {
            self.bump();
            if (self.pos < self.source.len and self.peek() == '=') {
                self.bump();
                return self.emit(t.TOK_XOR_ASSIGN, .{ .none = {} });
            }
            return self.emit('^', .{ .none = {} });
        }

        fn lexQuestion(self: *LexerImpl) Error!t.Token {
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
                if (self.peek() == '.' and !isDecimalDigit(self.peekAt(1))) {
                    self.bump();
                    return self.emit(t.TOK_QUESTION_MARK_DOT, .{ .none = {} });
                }
            }
            return self.emit('?', .{ .none = {} });
        }

        // ---- utf-8 -------------------------------------------------------

        fn decodeUtf8(self: *LexerImpl) Error!u21 {
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

        fn startsUtf8Trivia(self: *const LexerImpl) bool {
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

        fn startsUtf8LineTerminator(self: *const LexerImpl) bool {
            if (self.remaining() >= 3 and self.source[self.pos] == 0xE2 and self.source[self.pos + 1] == 0x80) {
                const b3 = self.source[self.pos + 2];
                return b3 == 0xA8 or b3 == 0xA9;
            }
            return false;
        }
    };

    fn isAsciiIdentStart(c: u8) bool {
        return unicode.isAsciiIdentifierStartByte(c);
    }

    fn isAsciiIdentContinue(c: u8) bool {
        return unicode.isAsciiIdentifierPartByte(c);
    }

    fn hexNibble(c: u8) u16 {
        return unicode.asciiHexDigitValueByte(c) orelse unreachable;
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

    fn isHexDigit(c: u8) bool {
        return unicode.isAsciiHexDigitByte(c);
    }

    fn isOctalDigit(c: u8) bool {
        return unicode.isAsciiOctalDigitByte(c);
    }

    fn isBinaryDigit(c: u8) bool {
        return unicode.isAsciiBinaryDigitByte(c);
    }

    fn isDecimalDigit(c: u8) bool {
        return unicode.isAsciiDigitByte(c);
    }

    fn consumeDigitRun(self: *LexerImpl, comptime isDigit: fn (u8) bool) bool {
        var any = false;
        var prev_sep = false;
        while (self.pos < self.source.len) {
            const c = self.peek();
            if (isDigit(c)) {
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

    fn consumeHexDigits(self: *LexerImpl) bool {
        return consumeDigitRun(self, isHexDigit);
    }

    fn consumeOctalDigits(self: *LexerImpl) bool {
        return consumeDigitRun(self, isOctalDigit);
    }

    fn consumeBinaryDigits(self: *LexerImpl) bool {
        return consumeDigitRun(self, isBinaryDigit);
    }

    fn consumeDecDigits(self: *LexerImpl) bool {
        return consumeDigitRun(self, isDecimalDigit);
    }

    fn consumeDecDigitsRequired(self: *LexerImpl) Error!void {
        if (!consumeDecDigits(self)) return error.InvalidNumber;
    }

    fn consumeOptionalFractionDigits(self: *LexerImpl) Error!void {
        if (self.pos >= self.source.len) return;
        const c = self.peek();
        if (isDecimalDigit(c) or c == '_') {
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

    fn legacyOrNonOctalDecimalValue(self: *LexerImpl, lexeme: []const u8) !?f64 {
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

    pub const TypeScriptUnsupportedSyntax = struct {
        message: []const u8,
        offset: usize,
        line: u32,
        column: u32,
    };

    pub const SourceKindImpl = enum {
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

    pub fn shouldStrip(kind: SourceKindImpl, filename: []const u8) bool {
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

    fn markTypeRanges(self: *LexerImpl) !void {
        var tokens = std.ArrayList(TSToken).empty;
        defer tokens.deinit(self.allocator);
        try tsTokenize(self.allocator, self.source, &tokens);

        var ranges = std.ArrayList(Range).empty;
        defer ranges.deinit(self.allocator);

        try markTypeOnlyStatements(self.allocator, self.source, tokens.items, &ranges);
        try markMixedTypeSpecifiers(self.allocator, self.source, tokens.items, &ranges);
        try markClassAndTypeModifiers(self.allocator, self.source, tokens.items, &ranges);
        try markImplementsClauses(self.allocator, self.source, tokens.items, &ranges);
        try markFunctionOverloadSignatures(self.allocator, self.source, tokens.items, &ranges);
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

    pub fn findUnsupportedTypeScriptSyntax(
        allocator: std.mem.Allocator,
        src: []const u8,
    ) !?TypeScriptUnsupportedSyntax {
        var tokens = std.ArrayList(TSToken).empty;
        defer tokens.deinit(allocator);
        try tsTokenize(allocator, src, &tokens);

        for (tokens.items, 0..) |ts_token, i| {
            const txt = ts_token.text(src);
            if (textEql(txt, "@")) {
                return unsupportedSyntaxAt(
                    src,
                    ts_token.start,
                    "TS decorators are not supported by fun's type-strip; remove the decorator or refactor",
                );
            }
            if (textEql(txt, "import")) {
                if (tokenTextEql(src, tokens.items, i + 1, "=")) {
                    return unsupportedSyntaxAt(
                        src,
                        tokens.items[i + 1].start,
                        "TS import=/export= (CommonJS-style) is not supported; use ESM import/export",
                    );
                }
                if (i + 2 < tokens.items.len and
                    tokens.items[i + 1].kind == .identifier and
                    tokenTextEql(src, tokens.items, i + 2, "="))
                {
                    return unsupportedSyntaxAt(
                        src,
                        tokens.items[i + 2].start,
                        "TS import=/export= (CommonJS-style) is not supported; use ESM import/export",
                    );
                }
            }
            if (textEql(txt, "export") and tokenTextEql(src, tokens.items, i + 1, "=")) {
                return unsupportedSyntaxAt(
                    src,
                    tokens.items[i + 1].start,
                    "TS import=/export= (CommonJS-style) is not supported; use ESM import/export",
                );
            }
        }

        return null;
    }

    fn unsupportedSyntaxAt(src: []const u8, offset: usize, message: []const u8) TypeScriptUnsupportedSyntax {
        var line: u32 = 1;
        var column: u32 = 1;
        var i: usize = 0;
        while (i < offset and i < src.len) : (i += 1) {
            if (src[i] == '\n') {
                line += 1;
                column = 1;
            } else if (src[i] == '\r') {
                if (i + 1 < offset and i + 1 < src.len and src[i + 1] == '\n') {
                    i += 1;
                }
                line += 1;
                column = 1;
            } else {
                column += 1;
            }
        }
        return .{
            .message = message,
            .offset = @min(offset, src.len),
            .line = line,
            .column = column,
        };
    }

    fn tsTokenize(allocator: std.mem.Allocator, src: []const u8, tokens: *std.ArrayList(TSToken)) !void {
        var i: usize = 0;
        var prev_sig: ?TSToken = null;
        while (i < src.len) {
            const c = src[i];
            if (unicode.isAsciiWhitespaceByte(c)) {
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
            const ts_token = if (tsIsIdentStart(c)) blk: {
                i += 1;
                while (i < src.len and tsIsIdentContinue(src[i])) i += 1;
                break :blk TSToken{ .kind = .identifier, .start = start, .end = i };
            } else if (isDecimalDigit(c)) blk: {
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

            try tokens.append(allocator, ts_token);
            prev_sig = ts_token;
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
            if (unicode.isAsciiWordByte(c) or c == '.') {
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
        const prev_token = prev orelse return true;
        const txt = prev_token.text(src);
        if (prev_token.kind == .identifier) {
            return textEql(txt, "return") or textEql(txt, "throw") or textEql(txt, "case") or
                textEql(txt, "delete") or textEql(txt, "void") or textEql(txt, "typeof") or
                textEql(txt, "yield") or textEql(txt, "await") or textEql(txt, "in") or
                textEql(txt, "of") or textEql(txt, "instanceof");
        }
        if (prev_token.kind != .punct) return false;
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

    fn markFunctionOverloadSignatures(
        allocator: std.mem.Allocator,
        src: []const u8,
        tokens: []const TSToken,
        ranges: *std.ArrayList(Range),
    ) !void {
        var i: usize = 0;
        while (i < tokens.len) : (i += 1) {
            if (!tokenTextEql(src, tokens, i, "function")) continue;

            var range_start_idx = i;
            if (i >= 1 and tokenTextEql(src, tokens, i - 1, "async") and !hasLineBreakBetween(src, tokens[i - 1].end, tokens[i].start)) {
                range_start_idx = i - 1;
            }
            if (range_start_idx >= 1 and tokenTextEql(src, tokens, range_start_idx - 1, "default")) {
                range_start_idx -= 1;
            }
            if (range_start_idx >= 1 and tokenTextEql(src, tokens, range_start_idx - 1, "export")) {
                range_start_idx -= 1;
            }

            var j = i + 1;
            if (tokenTextEql(src, tokens, j, "*")) j += 1;
            if (j >= tokens.len or tokens[j].kind != .identifier) continue;
            j += 1;

            if (tokenTextEql(src, tokens, j, "<")) {
                const type_params = findTypeAngleEnd(src, tokens, j) orelse continue;
                j = type_params.index + 1;
            }

            if (!tokenTextEql(src, tokens, j, "(")) continue;
            const close_idx = findMatchingForward(src, tokens, j, "(", ")") orelse continue;
            j = close_idx + 1;

            const semi_idx = if (tokenTextEql(src, tokens, j, ":")) blk: {
                const ret_end = findTypeEnd(src, tokens, j + 1, false) orelse continue;
                if (!tokenTextEql(src, tokens, ret_end.index, ";")) continue;
                break :blk ret_end.index;
            } else blk: {
                if (!tokenTextEql(src, tokens, j, ";")) continue;
                break :blk j;
            };

            try addRange(ranges, allocator, tokens[range_start_idx].start, tokens[semi_idx].end);
            i = semi_idx;
        }

        try markClassMethodOverloadSignatures(allocator, src, tokens, ranges);
    }

    const ClassMethodSignature = struct {
        start_idx: usize,
        name_idx: usize,
        end_idx: usize,
        has_body: bool,
    };

    fn markClassMethodOverloadSignatures(
        allocator: std.mem.Allocator,
        src: []const u8,
        tokens: []const TSToken,
        ranges: *std.ArrayList(Range),
    ) !void {
        var i: usize = 0;
        while (i < tokens.len) : (i += 1) {
            if (!tokenTextEql(src, tokens, i, "class")) continue;

            const open_idx = findClassBodyOpen(src, tokens, i) orelse continue;
            const close_idx = findMatchingForward(src, tokens, open_idx, "{", "}") orelse continue;

            var member_idx = open_idx + 1;
            while (member_idx < close_idx) {
                member_idx = skipClassMemberSeparators(src, tokens, member_idx, close_idx);
                if (member_idx >= close_idx) break;

                const sig = parseClassMethodSignature(src, tokens, member_idx, close_idx) orelse {
                    member_idx = nextClassMemberStart(src, tokens, member_idx, close_idx);
                    continue;
                };

                if (!sig.has_body and hasFollowingClassMethodImplementation(src, tokens, sig.name_idx, sig.end_idx + 1, close_idx)) {
                    try addRange(ranges, allocator, tokens[sig.start_idx].start, tokens[sig.end_idx].end);
                }
                member_idx = sig.end_idx + 1;
            }

            i = close_idx;
        }
    }

    fn findClassBodyOpen(src: []const u8, tokens: []const TSToken, class_idx: usize) ?usize {
        var angle: usize = 0;
        var paren: usize = 0;
        var bracket: usize = 0;
        var brace: usize = 0;

        var i = class_idx + 1;
        while (i < tokens.len) : (i += 1) {
            const txt = tokens[i].text(src);
            if (textEql(txt, "<")) {
                angle += 1;
            } else if (startsWithGreater(txt) and angle > 0) {
                _ = consumeTypeAngleClosers(txt, tokens[i].start, &angle);
            } else if (textEql(txt, "(")) {
                paren += 1;
            } else if (textEql(txt, ")")) {
                if (paren == 0) return null;
                paren -= 1;
            } else if (textEql(txt, "[")) {
                bracket += 1;
            } else if (textEql(txt, "]")) {
                if (bracket == 0) return null;
                bracket -= 1;
            } else if (textEql(txt, "{")) {
                if (angle == 0 and paren == 0 and bracket == 0 and brace == 0) return i;
                brace += 1;
            } else if (textEql(txt, "}")) {
                if (brace == 0) return null;
                brace -= 1;
            } else if (angle == 0 and paren == 0 and bracket == 0 and brace == 0 and textEql(txt, ";")) {
                return null;
            }
        }
        return null;
    }

    fn skipClassMemberSeparators(src: []const u8, tokens: []const TSToken, start_idx: usize, class_close_idx: usize) usize {
        var i = start_idx;
        while (i < class_close_idx and tokenTextEql(src, tokens, i, ";")) : (i += 1) {}
        return i;
    }

    fn parseClassMethodSignature(src: []const u8, tokens: []const TSToken, member_start: usize, class_close_idx: usize) ?ClassMethodSignature {
        var i = member_start;
        while (i < class_close_idx and isClassMethodModifierAt(src, tokens, i)) : (i += 1) {}
        if (i >= class_close_idx) return null;

        if (tokenTextEql(src, tokens, i, "*")) i += 1;
        if (i >= class_close_idx or tokens[i].kind != .identifier) return null;

        const name_idx = i;
        i += 1;

        if (tokenTextEql(src, tokens, i, "<")) {
            const type_params = findTypeAngleEnd(src, tokens, i) orelse return null;
            i = type_params.index + 1;
        }

        if (!tokenTextEql(src, tokens, i, "(")) return null;
        const close_params_idx = findMatchingForward(src, tokens, i, "(", ")") orelse return null;
        if (close_params_idx >= class_close_idx) return null;
        i = close_params_idx + 1;

        if (tokenTextEql(src, tokens, i, ":")) {
            const ret_end = findTypeEnd(src, tokens, i + 1, false) orelse return null;
            i = ret_end.index;
        }

        if (tokenTextEql(src, tokens, i, ";")) {
            return .{
                .start_idx = member_start,
                .name_idx = name_idx,
                .end_idx = i,
                .has_body = false,
            };
        }

        if (tokenTextEql(src, tokens, i, "{")) {
            const body_close_idx = findMatchingForward(src, tokens, i, "{", "}") orelse return null;
            if (body_close_idx > class_close_idx) return null;
            return .{
                .start_idx = member_start,
                .name_idx = name_idx,
                .end_idx = body_close_idx,
                .has_body = true,
            };
        }

        return null;
    }

    fn isClassMethodModifierAt(src: []const u8, tokens: []const TSToken, idx: usize) bool {
        const txt = tokens[idx].text(src);
        if (isTsModifier(txt)) return true;
        if (textEql(txt, "static") or textEql(txt, "async")) {
            return !tokenTextEql(src, tokens, idx + 1, "(");
        }
        return false;
    }

    fn hasFollowingClassMethodImplementation(src: []const u8, tokens: []const TSToken, name_idx: usize, start_idx: usize, class_close_idx: usize) bool {
        var i = start_idx;
        while (i < class_close_idx) {
            i = skipClassMemberSeparators(src, tokens, i, class_close_idx);
            if (i >= class_close_idx) return false;

            const sig = parseClassMethodSignature(src, tokens, i, class_close_idx) orelse return false;
            if (!sameTokenText(src, tokens[name_idx], tokens[sig.name_idx])) return false;
            if (sig.has_body) return true;
            i = sig.end_idx + 1;
        }
        return false;
    }

    fn sameTokenText(src: []const u8, a: TSToken, b: TSToken) bool {
        return textEql(a.text(src), b.text(src));
    }

    fn nextClassMemberStart(src: []const u8, tokens: []const TSToken, start_idx: usize, class_close_idx: usize) usize {
        var paren: usize = 0;
        var bracket: usize = 0;
        var brace: usize = 0;

        var i = start_idx;
        while (i < class_close_idx) : (i += 1) {
            const txt = tokens[i].text(src);
            if (textEql(txt, "(")) {
                paren += 1;
            } else if (textEql(txt, ")")) {
                paren -|= 1;
            } else if (textEql(txt, "[")) {
                bracket += 1;
            } else if (textEql(txt, "]")) {
                bracket -|= 1;
            } else if (textEql(txt, "{")) {
                if (paren == 0 and bracket == 0 and brace == 0) {
                    if (findMatchingForward(src, tokens, i, "{", "}")) |close_idx| {
                        return @min(close_idx + 1, class_close_idx);
                    }
                    return class_close_idx;
                }
                brace += 1;
            } else if (textEql(txt, "}")) {
                if (brace == 0) return class_close_idx;
                brace -= 1;
            } else if (paren == 0 and bracket == 0 and brace == 0 and textEql(txt, ";")) {
                return i + 1;
            }
        }
        return class_close_idx;
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
                try addRange(ranges, allocator, tokens[i].start, end_idx.end);
                i = end_idx.index;
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
            const end_pos = findTypeEnd(src, tokens, i + 1, stop_arrow);
            const start = if (i > 0 and tokenTextEql(src, tokens, i - 1, "?")) tokens[i - 1].start else tok.start;
            const end = if (end_pos) |pos| pos.end else src.len;
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
        const owner_idx = parameterListOwnerIndex(src, tokens, open_idx) orelse return false;
        const before = tokens[owner_idx].text(src);
        const after = if (close_idx + 1 < tokens.len) tokens[close_idx + 1].text(src) else "";
        if (isControlKeyword(before)) return false;
        if (textEql(before, "function") or textEql(before, "constructor")) return true;
        if (owner_idx >= 1 and tokens[owner_idx].kind == .identifier and tokenTextEql(src, tokens, owner_idx - 1, "function")) return true;
        if (tokens[owner_idx].kind == .identifier and (textEql(after, "{") or textEql(after, "=>"))) return true;
        if (tokens[owner_idx].kind == .identifier and textEql(after, ":")) {
            return returnTypeAfterParameterListLeadsToBody(src, tokens, close_idx);
        }
        if (textEql(after, ":")) return returnTypeAfterParameterListLeadsToBody(src, tokens, close_idx);
        if (textEql(after, "=>")) return true;
        return false;
    }

    fn parameterListOwnerIndex(src: []const u8, tokens: []const TSToken, open_idx: usize) ?usize {
        if (open_idx == 0) return null;
        var owner_idx = open_idx - 1;
        if (startsWithGreater(tokens[owner_idx].text(src))) {
            const type_start = findTypeAngleStartBackward(src, tokens, owner_idx) orelse return null;
            if (type_start == 0) return null;
            owner_idx = type_start - 1;
        }
        return owner_idx;
    }

    fn findTypeAngleStartBackward(src: []const u8, tokens: []const TSToken, gt_idx: usize) ?usize {
        var depth = leadingGreaterCount(tokens[gt_idx].text(src));
        if (depth == 0) return null;
        var i = gt_idx;
        while (i > 0) {
            i -= 1;
            const txt = tokens[i].text(src);
            if (startsWithGreater(txt)) {
                depth += leadingGreaterCount(txt);
            } else if (textEql(txt, "<")) {
                if (depth == 1) return i;
                depth -= 1;
            }
        }
        return null;
    }

    fn leadingGreaterCount(txt: []const u8) usize {
        var count: usize = 0;
        while (count < txt.len and txt[count] == '>') : (count += 1) {}
        return count;
    }

    fn returnTypeAfterParameterListLeadsToBody(src: []const u8, tokens: []const TSToken, close_idx: usize) bool {
        if (!tokenTextEql(src, tokens, close_idx + 1, ":")) return false;
        const end_idx = findTypeEnd(src, tokens, close_idx + 2, true) orelse return false;
        return tokenTextEql(src, tokens, end_idx.index, "{") or tokenTextEql(src, tokens, end_idx.index, "=>");
    }

    fn isControlKeyword(txt: []const u8) bool {
        return textEql(txt, "if") or textEql(txt, "for") or textEql(txt, "while") or
            textEql(txt, "switch") or textEql(txt, "with") or textEql(txt, "catch");
    }

    fn isVariableDeclarationKeyword(txt: []const u8) bool {
        return textEql(txt, "let") or textEql(txt, "const") or textEql(txt, "var");
    }

    fn isVariableDeclarationType(src: []const u8, tokens: []const TSToken, colon_idx: usize) bool {
        var stmt_start: usize = 0;
        var paren: usize = 0;
        var bracket: usize = 0;
        var brace: usize = 0;
        var i = colon_idx;
        while (i > 0) {
            i -= 1;
            const txt = tokens[i].text(src);
            if (textEql(txt, ")")) {
                paren += 1;
            } else if (textEql(txt, "]")) {
                bracket += 1;
            } else if (textEql(txt, "}")) {
                brace += 1;
            } else if (textEql(txt, "(")) {
                if (paren == 0) {
                    stmt_start = i + 1;
                    break;
                }
                paren -= 1;
            } else if (textEql(txt, "[")) {
                if (bracket == 0) {
                    stmt_start = i + 1;
                    break;
                }
                bracket -= 1;
            } else if (textEql(txt, "{")) {
                if (brace == 0) {
                    stmt_start = i + 1;
                    break;
                }
                brace -= 1;
            } else if (paren == 0 and bracket == 0 and brace == 0 and textEql(txt, ";")) {
                stmt_start = i + 1;
                break;
            }
        }

        var saw_decl = false;
        var last_comma_or_decl = stmt_start;
        paren = 0;
        bracket = 0;
        brace = 0;
        i = stmt_start;
        while (i < colon_idx) : (i += 1) {
            const txt = tokens[i].text(src);
            if (paren == 0 and bracket == 0 and brace == 0 and isVariableDeclarationKeyword(txt)) {
                saw_decl = true;
                last_comma_or_decl = i + 1;
            } else if (textEql(txt, "(")) {
                paren += 1;
            } else if (textEql(txt, ")")) {
                paren -|= 1;
            } else if (textEql(txt, "[")) {
                bracket += 1;
            } else if (textEql(txt, "]")) {
                bracket -|= 1;
            } else if (textEql(txt, "{")) {
                brace += 1;
            } else if (textEql(txt, "}")) {
                brace -|= 1;
            } else if (paren == 0 and bracket == 0 and brace == 0 and textEql(txt, ",")) {
                last_comma_or_decl = i + 1;
            }
        }
        if (!saw_decl) return false;

        paren = 0;
        bracket = 0;
        brace = 0;
        i = last_comma_or_decl;
        while (i < colon_idx) : (i += 1) {
            const txt = tokens[i].text(src);
            if (textEql(txt, "(")) {
                paren += 1;
            } else if (textEql(txt, ")")) {
                paren -|= 1;
            } else if (textEql(txt, "[")) {
                bracket += 1;
            } else if (textEql(txt, "]")) {
                bracket -|= 1;
            } else if (textEql(txt, "{")) {
                brace += 1;
            } else if (textEql(txt, "}")) {
                brace -|= 1;
            } else if (paren == 0 and bracket == 0 and brace == 0 and textEql(txt, "=")) {
                return false;
            }
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
            const end_pos = findTypeAssertionEnd(src, tokens, i + 1);
            const end = if (end_pos) |pos| pos.end else src.len;
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

    fn previousTokenCanEndExpression(src: []const u8, prev_token: TSToken) bool {
        return switch (prev_token.kind) {
            .identifier => identifierCanEndExpression(prev_token.text(src)),
            .number, .string, .template, .regexp => true,
            .punct => {
                const txt = prev_token.text(src);
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

    const TypeScanEnd = struct {
        index: usize,
        end: usize,
    };

    fn findTypeEnd(src: []const u8, tokens: []const TSToken, start_idx: usize, stop_arrow: bool) ?TypeScanEnd {
        var paren: usize = 0;
        var bracket: usize = 0;
        var brace: usize = 0;
        var angle: usize = 0;
        var i = start_idx;
        while (i < tokens.len) : (i += 1) {
            const txt = tokens[i].text(src);
            if (textEql(txt, "(")) paren += 1 else if (textEql(txt, ")")) {
                if (paren == 0 and bracket == 0 and brace == 0 and angle == 0) return .{ .index = i, .end = tokens[i].start };
                paren -|= 1;
            } else if (textEql(txt, "[")) bracket += 1 else if (textEql(txt, "]")) {
                if (bracket == 0 and paren == 0 and brace == 0 and angle == 0) return .{ .index = i, .end = tokens[i].start };
                bracket -|= 1;
            } else if (textEql(txt, "{")) {
                if (i == start_idx or brace > 0 or paren > 0 or bracket > 0 or angle > 0) {
                    brace += 1;
                } else {
                    return .{ .index = i, .end = tokens[i].start };
                }
            } else if (textEql(txt, "}")) {
                if (brace == 0 and paren == 0 and bracket == 0 and angle == 0) return .{ .index = i, .end = tokens[i].start };
                brace -|= 1;
            } else if (textEql(txt, "<")) {
                angle += 1;
            } else if (startsWithGreater(txt) and angle > 0) {
                if (consumeTypeAngleClosers(txt, tokens[i].start, &angle)) |partial_end| {
                    if (partial_end < tokens[i].end) return .{ .index = i, .end = partial_end };
                }
            } else if (paren == 0 and bracket == 0 and brace == 0 and angle == 0) {
                if (textEql(txt, ",") or textEql(txt, ";") or textEql(txt, "=")) return .{ .index = i, .end = tokens[i].start };
                if (stop_arrow and textEql(txt, "=>")) return .{ .index = i, .end = tokens[i].start };
            }
        }
        return null;
    }

    fn findTypeAssertionEnd(src: []const u8, tokens: []const TSToken, start_idx: usize) ?TypeScanEnd {
        var paren: usize = 0;
        var bracket: usize = 0;
        var brace: usize = 0;
        var angle: usize = 0;
        var i = start_idx;
        while (i < tokens.len) : (i += 1) {
            const txt = tokens[i].text(src);
            if (textEql(txt, "(")) paren += 1 else if (textEql(txt, ")")) {
                if (paren == 0 and bracket == 0 and brace == 0 and angle == 0) return .{ .index = i, .end = tokens[i].start };
                paren -|= 1;
            } else if (textEql(txt, "[")) bracket += 1 else if (textEql(txt, "]")) {
                if (bracket == 0 and paren == 0 and brace == 0 and angle == 0) return .{ .index = i, .end = tokens[i].start };
                bracket -|= 1;
            } else if (textEql(txt, "{")) brace += 1 else if (textEql(txt, "}")) {
                if (brace == 0 and paren == 0 and bracket == 0 and angle == 0) return .{ .index = i, .end = tokens[i].start };
                brace -|= 1;
            } else if (textEql(txt, "<")) {
                angle += 1;
            } else if (startsWithGreater(txt) and angle > 0) {
                if (consumeTypeAngleClosers(txt, tokens[i].start, &angle)) |partial_end| {
                    if (partial_end < tokens[i].end) return .{ .index = i, .end = partial_end };
                }
            } else if (paren == 0 and bracket == 0 and brace == 0 and angle == 0 and isExpressionDelimiter(txt)) {
                return .{ .index = i, .end = tokens[i].start };
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
                    textEql(txt, "for") or textEql(txt, "return") or
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
            } else if (!typeParameterListCanBeFollowedBy(next_txt)) {
                return false;
            }
            if (next_kind == .number or next_kind == .string or next_kind == .regexp) {
                return false;
            }
        }
        return true;
    }

    fn typeParameterListCanBeFollowedBy(txt: []const u8) bool {
        return textEql(txt, "(") or textEql(txt, "{") or textEql(txt, "[") or
            textEql(txt, ",") or textEql(txt, "=>") or textEql(txt, "=") or
            textEql(txt, ":") or textEql(txt, ";") or textEql(txt, ")") or
            textEql(txt, "]") or textEql(txt, "|") or textEql(txt, "&") or
            textEql(txt, ".") or textEql(txt, "?") or textEql(txt, "!");
    }

    fn findTypeAngleEnd(src: []const u8, tokens: []const TSToken, lt_idx: usize) ?TypeScanEnd {
        var depth: usize = 0;
        var paren: usize = 0;
        var bracket: usize = 0;
        var brace: usize = 0;
        var i = lt_idx;
        while (i < tokens.len) : (i += 1) {
            const txt = tokens[i].text(src);
            if (textEql(txt, "<")) {
                depth += 1;
            } else if (textEql(txt, "(")) {
                paren += 1;
            } else if (textEql(txt, ")")) {
                if (paren == 0 and bracket == 0 and brace == 0 and depth == 1) return null;
                paren -|= 1;
            } else if (textEql(txt, "[")) {
                bracket += 1;
            } else if (textEql(txt, "]")) {
                if (bracket == 0 and paren == 0 and brace == 0 and depth == 1) return null;
                bracket -|= 1;
            } else if (textEql(txt, "{")) {
                brace += 1;
            } else if (textEql(txt, "}")) {
                if (brace == 0 and paren == 0 and bracket == 0 and depth == 1) return null;
                brace -|= 1;
            } else if (startsWithGreater(txt) and depth > 0) {
                if (consumeTypeAngleClosers(txt, tokens[i].start, &depth)) |end| {
                    if (paren != 0 or bracket != 0 or brace != 0) return null;
                    if (isValidTypeParameterList(src, tokens, lt_idx, i)) {
                        return .{ .index = i, .end = end };
                    }
                    return null;
                }
            } else if (depth == 1 and paren == 0 and bracket == 0 and brace == 0 and textEql(txt, ";")) {
                return null;
            }
        }
        return null;
    }

    fn startsWithGreater(txt: []const u8) bool {
        return txt.len > 0 and txt[0] == '>';
    }

    fn consumeTypeAngleClosers(txt: []const u8, token_start: usize, depth: *usize) ?usize {
        var consumed: usize = 0;
        while (consumed < txt.len and txt[consumed] == '>' and depth.* > 0) : (consumed += 1) {
            depth.* -= 1;
            if (depth.* == 0) {
                return token_start + consumed + 1;
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
            if (textEql(txt, "class")) {
                return (findClassBodyOpen(src, tokens, i) orelse return false) == open_idx;
            }
            if (textEql(txt, ";")) return false;
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
        return unicode.isAsciiIdentifierStartByte(c) or c >= 0x80;
    }

    fn tsIsIdentContinue(c: u8) bool {
        return tsIsIdentStart(c) or unicode.isAsciiDigitByte(c);
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
        while (i < source.len and unicode.isAsciiIdentifierPartByte(source[i])) : (i += 1) {}
        return .{
            .pattern = pattern,
            .flags = source[flags_start..i],
            .end_offset = i,
        };
    }
    pub const SourceKind = SourceKindImpl;
    pub const Lexer = LexerImpl;
};

pub const parser_core = struct {
    //! QuickJS-aligned parser.
    //!
    //! Mirrors `js_parse_expr` family in `quickjs.c:27049..27645` row-for-row:
    //!
    //!     parseExpr            -> parseExpr2(PF_IN_ACCEPTED)
    //!     parseExpr2(flags)    -> parseAssignExpr2(flags); while ',' { drop ; ... }
    //!     parseAssignExpr2     -> parseCondExpr(flags); if assign-op { ... }
    //!     parseCondExpr        -> parseCoalesceExpr; if '?' { ... }
    //!     parseCoalesceExpr    -> parseLogicalAndOr(OP_or); if '??' { ... }
    //!     parseLogicalAndOr    -> parseExprBinary(level=8) ; while op_match { ... }
    //!     parseExprBinary(L,f) -> if L==0 parseUnary ; switch(L) on token table
    //!     parseUnary           -> handle delete/void/typeof/+/-/~/!/++/--/await ; ** if PF_POW_ALLOWED
    //!     parsePostfixExpr     -> parseLhsExpr ; postfix ++/--
    //!     parseLhsExpr         -> primary or new ... ; member chain
    //!
    //! This parser emits real QuickJS opcode ids (`bytecode.opcode.op.<name>`)
    //! into the bytecode buffer and is validated against QuickJS semantics through
    //! focused conformance and regression slices.
    //!

    const std = @import("std");
    const bytecode = @import("bytecode.zig");

    const atom_module = @import("core/atom.zig");
    const core_bigint = @import("core/bigint.zig");
    const core = @import("core/root.zig");
    const regexp_lib = @import("libs/regexp.zig");
    const libs_bignum = @import("libs/bigint.zig");
    const unicode = @import("libs/unicode.zig");
    const memory = @import("core/memory.zig");
    const JSValue = @import("core/value.zig").JSValue;

    const bytecode_function = bytecode;
    const function_def_mod = bytecode.function_def;
    const bytecode_module = bytecode.module;
    const opcode = bytecode.opcode;

    const lexer_mod = lexer;
    const tok = token;

    const Atom = atom_module.Atom;

    const atom_this: Atom = atom_module.ids.this_;
    const atom_new_target: Atom = atom_module.ids.new_target;
    const atom_this_active_func: Atom = atom_module.ids.this_active_func;
    const atom_home_object: Atom = atom_module.ids.home_object;
    const atom_class_fields_init: Atom = atom_module.ids.class_fields_init;
    const atom_var_object: Atom = atom_module.ids.var_object; // "<var>"
    const atom_arg_var_object: Atom = atom_module.ids.arg_var_object; // "<arg_var>"
    const shared_iterator_close_marker: u8 = 255;
    const direct_iterator_close_marker: u8 = 254;

    const SourcePosition = struct {
        line_num: u32,
        col_num: u32,
    };

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
        // Native recursion-descent guard (QuickJS next_token
        // `js_check_stack_overflow` -> js_parse_error "stack overflow",
        // quickjs.c:22836). Surfaced by `compile` as a catchable SyntaxError.
        StackOverflow,
    };

    /// Parse flags mirror the QuickJS `PF_*` macros (`quickjs.c:21358..21370`).
    pub const ParseFlags = packed struct(u32) {
        in_accepted: bool = false,
        pow_allowed: bool = false,
        arrow_func: bool = false,
        trailing_comma_ok: bool = false,
        result_needed: bool = true,
        yield_forbidden: bool = false,
        _padding: u26 = 0,

        pub const default = ParseFlags{ .in_accepted = true };
    };

    fn forceResultNeeded(flags: ParseFlags) ParseFlags {
        var value_flags = flags;
        value_flags.result_needed = true;
        return value_flags;
    }

    /// Mirror `quickjs.c:21352` — BlockEnv for break/continue/finally tracking.
    pub const BlockEnv = struct {
        prev: ?*BlockEnv,
        label_name: Atom,
        label_break: i32,
        label_cont: i32,
        drop_count: i32,
        label_finally: i32,
        scope_level: i32,
        catch_marker_depth: u32,
        has_iterator: bool,
        is_regular_stmt: bool,
    };

    const LabelFrame = struct {
        atom: Atom,
        allow_continue: bool,
        catch_marker_depth: u32,
        control_frame_depth: usize,
        break_frame_depth: usize,
        break_fixups: std.ArrayList(usize) = .empty,
        continue_fixups: std.ArrayList(usize) = .empty,

        fn deinit(self: *LabelFrame, allocator: std.mem.Allocator) void {
            self.break_fixups.deinit(allocator);
            self.continue_fixups.deinit(allocator);
        }
    };

    const ControlFrames = struct {
        top_break: ?*BlockEnv,
        break_fixups: std.ArrayList(usize),
        break_frame_lens: std.ArrayList(usize),
        break_frame_catch_marker_depths: std.ArrayList(u32),
        break_frame_cleanup_drops: std.ArrayList(u8),
        break_frame_cross_cleanup_drops: std.ArrayList(u8),
        continue_fixups: std.ArrayList(usize),
        continue_frame_lens: std.ArrayList(usize),
        continue_frame_break_frame_indices: std.ArrayList(usize),
        continue_frame_catch_marker_depths: std.ArrayList(u32),
        continue_frame_cleanup_drops: std.ArrayList(u8),
        label_frames: std.ArrayList(LabelFrame),
        pending_label_atom: ?Atom,
        active_catch_marker_depth: u32,
        using_block_frames: std.ArrayList(UsingBlockFrame),
    };

    const ReturnFinallyFrame = struct {
        finally_label: ParserLabelRef,
        scope_level: i32,
        catch_marker_depth: u32,
        break_depth: usize,
        continue_depth: usize,
        label_depth: usize,
        block_boundary: ?*BlockEnv,
    };

    const DisposalHint = core.object.DisposalHint;

    const UsingBlockFrame = struct {
        stack_loc: ?u16 = null,
        catch_off: ?usize = null,
        catch_marker_depth: u32 = 0,
        seen_async_hint: bool = false,
    };

    const ClassPrivateElementKind = enum {
        field,
        method,
        getter,
        setter,
    };

    const ClassPrivateElement = struct {
        atom: Atom,
        kind: ClassPrivateElementKind,
        is_static: bool,
    };

    const ReturnFinallyBoundary = struct {
        frames: std.ArrayList(ReturnFinallyFrame),
        finally_body_control_frames: std.ArrayList(FinallyBodyControlFrame),
    };

    /// Minimal adapter for abrupt control emitted while parsing a shared
    /// finalizer body. The finalizer's own ReturnFinallyFrame is already
    /// popped, so crossing this boundary must discard its
    /// `[completion, gosub_pc]` pair exactly once.
    const FinallyBodyControlFrame = struct {
        block: *BlockEnv,
        catch_marker_depth: u32,
        break_depth: usize,
        continue_depth: usize,
        label_depth: usize,
    };

    const FinallyControlKind = enum {
        @"break",
        @"continue",
    };

    const FinallyControlTarget = struct {
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

    /// Function kind. Mirrors QuickJS `JSFunctionKindEnum`.
    pub const FunctionKind = enum {
        normal,
        generator,
        async,
        async_generator,
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

    /// Class element kind. Mirrors QuickJS class element types.
    pub const ClassElementKind = enum {
        field,
        method,
        getter,
        setter,
        static_field,
        static_method,
        static_getter,
        static_setter,
        private_field,
        private_method,
        private_getter,
        private_setter,
        static_block,
    };

    /// `JSParseState` analogue for expression, statement, function, and class parsing.
    pub const State = struct {
        lex: *lexer_mod.Lexer,
        function: *bytecode_function.Bytecode,
        runtime: ?*core.JSRuntime = null,
        /// One-token lookahead. The lexer is the source of truth; we cache
        /// the most recently produced token here so the parser can `peek`.
        token: tok.Token,
        last_token_end_offset: usize = 0,
        last_token_line_num: u32 = 1,
        last_token_col_num: u32 = 1,
        last_opcode_source_offset: ?u32 = null,
        /// Scoped attribution for statement opcodes emitted after their
        /// operand expression has advanced the lexer. QuickJS emits one
        /// OP_line_num at the statement keyword before lowering the complete
        /// return/throw sequence; keeping the override here gives every
        /// synthesized opcode in that sequence the same source authority.
        opcode_source_override: ?SourcePosition = null,
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
        /// Whether we're inside a class body.
        in_class: bool = false,
        /// Whether the current class has an extends clause.
        class_has_extends: bool = false,
        /// Whether the current class body defines a static `name` member.
        class_static_name_seen: bool = false,
        /// Whether we're in a static class element context.
        is_static: bool = false,
        /// Whether statement parsing is inside a class static initialization block.
        in_class_static_block: bool = false,
        /// Whether declarations are currently being parsed inside the synthetic
        /// CaseBlock lexical environment for a switch statement.
        in_switch_case_block_scope: bool = false,
        /// Whether `return` is syntactically allowed in the current statement body.
        return_depth: u32 = 0,
        /// Whether we're in a constructor.
        in_constructor: bool = false,
        /// Whether we are currently parsing the outermost constructor block.
        is_outer_constructor_block: bool = false,
        /// Whether `super` is syntactically allowed in the current function body.
        allow_super: bool = false,
        /// Whether direct `super(...)` constructor calls are syntactically allowed.
        allow_super_call: bool = false,
        /// Whether the last primary expression was super.
        last_was_super: bool = false,
        /// Prefix update parses the lvalue after consuming `++` / `--`, so
        /// the identifier parser cannot see an assignment-like lookahead.
        /// Whether we're in a generator function.
        in_generator: bool = false,
        /// Whether we're in an async function.
        in_async: bool = false,
        /// Whether parameter default initializer parsing must reject `await`.
        reject_await_in_parameter_initializer: bool = false,
        /// Whether `new.target` is syntactically allowed in the current function
        /// context. Direct eval roots inherit this from the caller; indirect eval
        /// and top-level script roots keep it false.
        new_target_allowed: bool = false,
        /// Whether to emit temporary scope opcodes for the finalize pipeline.
        /// When true, emits scope_get_var/scope_put_var/scope_get_var_undef
        /// instead of the final get_var/put_var/get_var_undef opcodes.
        ///
        /// **Default is `true`** for parser output that still needs finalization.
        /// Callers run `bytecode.pipeline.finalize.run` after parsing to
        /// lower the temp opcodes to their final shapes. The pipeline:
        ///   * shrinks scope_get_var (7 bytes) → get_var (3 bytes), and
        ///     equivalents for scope_put_var / scope_get_var_undef;
        ///   * lowers enter_scope / leave_scope into their binding effects and
        ///     drops the temporary markers themselves (OP_label is also dropped);
        ///   * patches every absolute u32 jump operand using an
        ///     old→new pc map so `&&`/`||`/`??`/`?:` keep working
        ///     across the byte-offset shift.
        ///
        /// Setting this to `false` skips temp emission entirely (the
        /// parser writes final-form opcodes directly), which is useful
        /// for golden-byte tests that assert the lowered shape and want
        /// to bypass the pipeline.
        emit_phase1_temp: bool = true,
        /// Root-bytecode label identity counter. Nested FunctionDefs use their
        /// own `label_count`, matching QuickJS's per-function label namespace.
        root_parser_label_count: u32 = 0,
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
        top_level_functions_as_children: bool = false,
        eval_global_var_bindings: bool = false,
        eval_in_parameter_initializer: bool = false,
        eval_annex_b_blocked_function_names: []const Atom = &.{},
        features: std.EnumSet(FeatureImpl) = .initEmpty(),
        in_namespace: bool = false,
        current_namespace_atom: ?Atom = null,
        last_declared_atom: ?Atom = null,
        current_parameter_properties: ?std.ArrayList(Atom) = null,
        namespace_export: bool = false,

        /// QuickJS `eval_ret_idx` mirror (`quickjs.c:21480`). When ≥ 0,
        /// the slot at this local index receives the result of every
        /// expression statement (instead of the placeholder `drop`), and
        /// the caller's `finalizeEvalReturn` retrieves it at script end.
        /// `enableEvalReturn` allocates the slot using the `<ret>` atom
        /// (id 82, `quickjs-atom.h:115`). `-1` means non-eval mode.
        eval_ret_idx: i32 = -1,

        /// QuickJS `JSFunctionDef` companion state. Populated
        /// during parsing with scope chain (`pushScope`/`popScope`),
        /// variable declarations (`addScopeVar`), and later closure/label
        /// data. The FunctionDef-based `resolve_variables` / `resolve_labels`
        /// passes read from it to drive scope-chain walking, closure synthesis,
        /// TDZ, and local-slot assignment.
        ///
        /// The parser still emits to `function.code` as before; this is a
        /// parallel structure that mirrors `JSParseState.cur_func`
        /// (`quickjs.c:21581`). Tests in `qjs_parser_test.zig` assert the
        /// `vars` / `scopes` layout is populated correctly.
        function_def: function_def_mod.FunctionDef,

        /// Stack of FunctionDef pointers for nested function parsing.
        /// Mirrors `JSParseState.cur_func` stack management. The top of
        /// the stack is the current function being parsed. When entering
        /// a nested function, we push a new FunctionDef; when exiting,
        /// we pop back to the parent.
        cur_func_stack: []*function_def_mod.FunctionDef = &.{},
        cur_func_stack_capacity: usize = 0,
        discarded_func_head: ?*function_def_mod.FunctionDef = null,

        /// When true, emit bytecode to the current FunctionDef's byte_code
        /// buffer instead of the Bytecode object's code buffer. Used for
        /// nested functions to maintain separate bytecode buffers.
        emit_to_function_def: bool = false,
        pending_function_name: ?Atom = null,
        pending_function_is_decl: bool = false,
        pending_function_export_default: bool = false,
        annex_b_if_function_decl_clause: bool = false,
        function_expr_name_binding: ?Atom = null,
        in_parameter_initializer: bool = false,
        last_function_child_index: ?u16 = null,
        class_constructor_cpool_idx: ?u16 = null,
        last_anonymous_function_expr: bool = false,
        last_primary_was_arrow_function: bool = false,
        last_var_decl_atom: ?Atom = null,
        last_class_decl_atom: ?Atom = null,
        // True while parsing the parameter list of a class/object-literal
        // method. Mirrors qjs func_type == JS_PARSE_FUNC_METHOD in the
        // duplicate-argument check gate (quickjs.c:36443-36448).
        parsing_method_params: bool = false,
        assign_expr_depth: u32 = 0,
        last_coalesce_expr_depth: ?u32 = null,
        active_with_atom: ?Atom = null,
        with_scope_id: u32 = 0,
        active_catch_marker_depth: u32 = 0,
        emit_lexical_tdz_at_decl: bool = false,
        break_fixups: std.ArrayList(usize) = .empty,
        break_frame_lens: std.ArrayList(usize) = .empty,
        continue_fixups: std.ArrayList(usize) = .empty,
        continue_frame_lens: std.ArrayList(usize) = .empty,
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
        class_fields_init_child_index: ?u16 = null,
        class_static_init_child_index: ?u16 = null,
        class_instance_private_brand_needed: bool = false,
        class_static_private_brand_needed: bool = false,

        fn initRootEmitter(
            lex: *lexer_mod.Lexer,
            function: *bytecode_function.Bytecode,
            emit_root_to_function_def: bool,
        ) Error!State {
            var state = State{
                .lex = lex,
                .function = function,
                .token = undefined,
                .function_def = function_def_mod.FunctionDef.init(function.memory, function.atoms, function.name),
                .emit_to_function_def = emit_root_to_function_def,
            };
            errdefer state.function_def.deinitInitFailure();
            state.function_def.atoms.replace(&state.function_def.script_or_module, function.script_or_module);
            state.function_def.line_num = 1;
            state.function_def.col_num = 1;
            // A standalone ParseState represents a script/eval-program root,
            // matching JS_Eval's non-direct defaults in QuickJS. Production
            // compile_entry overwrites these facts for direct eval/module.
            state.function_def.has_this_binding = true;
            state.function_def.arguments_allowed = true;
            // Mirror `js_new_function_def` (`quickjs.c:31511`): scope 0
            // is the function's var/arg scope, parent = -1.
            _ = state.function_def.appendScope(-1) catch return error.OutOfMemory;
            state.token = try lex.next();
            // Every standalone State is a program/eval root.  QuickJS pushes
            // its real body scope before js_parse_program (and therefore
            // before directives/declarations); scope 0 remains exclusively
            // the var/arg environment.  Body enter/hoist emission is a later
            // phase checkpoint, but declaration semantics need the identity
            // now.
            try state.beginFunctionBody();
            // Note: cur_func_stack starts empty; cur_func() returns &function_def when empty
            return state;
        }

        pub fn init(lex: *lexer_mod.Lexer, function: *bytecode_function.Bytecode) Error!State {
            return initRootEmitter(lex, function, false);
        }

        /// Initialize a parser state that may emit runtime-owned constants.
        /// QuickJS's `JSParseState` always carries its `JSContext`; zjs keeps
        /// the runtime-less initializer for low-level parser-only tests, while
        /// production compilation and executable-bytecode helpers use this
        /// entry point.
        pub fn initWithRuntime(
            rt: *core.JSRuntime,
            lex: *lexer_mod.Lexer,
            function: *bytecode_function.Bytecode,
        ) Error!State {
            var state = try init(lex, function);
            state.runtime = rt;
            return state;
        }

        /// Production ordinary script/eval roots emit into their real
        /// FunctionDef from the first body-scope marker onward. This lets the
        /// root take the exact same recursive finalizer as every child instead
        /// of first constructing a mutable Bytecode twin.
        pub fn initCanonicalRootWithRuntime(
            rt: *core.JSRuntime,
            lex: *lexer_mod.Lexer,
            function: *bytecode_function.Bytecode,
        ) Error!State {
            var state = try initRootEmitter(lex, function, true);
            state.runtime = rt;
            return state;
        }

        /// Release State-owned resources. `rt` is forwarded to
        /// `FunctionDef.deinit` so constants in `function_def.cpool` can
        /// be released. `anytype` matches `Bytecode.deinit`'s signature
        /// so callers pass their existing runtime pointer.
        pub fn deinit(self: *State, rt: anytype) void {
            self.lex.freeToken(&self.token);
            // Free any nested function definitions on the stack
            const cur_func_stack = self.cur_func_stack;
            const cur_func_stack_capacity = self.cur_func_stack_capacity;
            self.cur_func_stack = &.{};
            self.cur_func_stack_capacity = 0;
            for (cur_func_stack) |fd| {
                fd.deinit(rt);
                self.function.memory.destroy(function_def_mod.FunctionDef, fd);
            }
            if (cur_func_stack_capacity != 0) {
                self.function.memory.free(*function_def_mod.FunctionDef, cur_func_stack.ptr[0..cur_func_stack_capacity]);
            }
            var discarded_func = self.discarded_func_head;
            self.discarded_func_head = null;
            while (discarded_func) |fd| {
                const next = fd.discard_next;
                fd.discard_next = null;
                fd.deinit(rt);
                self.function.memory.destroy(function_def_mod.FunctionDef, fd);
                discarded_func = next;
            }
            self.break_fixups.deinit(self.function.memory.allocator);
            self.break_frame_lens.deinit(self.function.memory.allocator);
            self.continue_fixups.deinit(self.function.memory.allocator);
            self.continue_frame_lens.deinit(self.function.memory.allocator);
            self.continue_frame_break_frame_indices.deinit(self.function.memory.allocator);
            self.break_frame_catch_marker_depths.deinit(self.function.memory.allocator);
            self.break_frame_cleanup_drops.deinit(self.function.memory.allocator);
            self.break_frame_cross_cleanup_drops.deinit(self.function.memory.allocator);
            self.continue_frame_catch_marker_depths.deinit(self.function.memory.allocator);
            self.continue_frame_cleanup_drops.deinit(self.function.memory.allocator);
            for (self.label_frames.items) |*frame| {
                frame.deinit(self.function.memory.allocator);
            }
            self.label_frames.deinit(self.function.memory.allocator);
            self.return_finally_frames.deinit(self.function.memory.allocator);
            self.finally_body_control_frames.deinit(self.function.memory.allocator);
            self.using_block_frames.deinit(self.function.memory.allocator);
            self.truncateClassPrivateElements(0);
            self.class_private_elements.deinit(self.function.memory.allocator);
            self.truncateClassPrivateBoundNames(0);
            self.class_private_bound_names.deinit(self.function.memory.allocator);
            self.function_def.deinit(rt);
        }

        /// Get the current FunctionDef from the top of the stack.
        /// Mirrors `JSParseState.cur_func` access. Returns the root
        /// function_def when the stack is empty (top-level parsing).
        fn cur_func(self: *State) *function_def_mod.FunctionDef {
            if (self.cur_func_stack.len == 0) {
                return &self.function_def;
            }
            return self.cur_func_stack[self.cur_func_stack.len - 1];
        }

        fn funcAtVirtualIndex(self: *State, idx: usize) *function_def_mod.FunctionDef {
            if (idx == 0) return &self.function_def;
            return self.cur_func_stack[idx - 1];
        }

        /// Push a new FunctionDef onto the stack. Called when entering
        /// a nested function. Mirrors the parent link setup in
        /// `js_new_function_def` (`quickjs.c:31484-31490`).
        fn pushFunction(self: *State, fd: *function_def_mod.FunctionDef) Error!void {
            const old_len = self.cur_func_stack.len;
            const new_len = self.cur_func_stack.len + 1;

            if (new_len > self.cur_func_stack_capacity) {
                const old_capacity = self.cur_func_stack_capacity;
                var new_capacity = if (old_capacity == 0)
                    @as(usize, 4)
                else
                    std.math.mul(usize, old_capacity, 2) catch return error.OutOfMemory;
                if (new_capacity < new_len) new_capacity = new_len;

                const next = try self.function.memory.alloc(*function_def_mod.FunctionDef, new_capacity);
                errdefer self.function.memory.free(*function_def_mod.FunctionDef, next);
                @memcpy(next[0..old_len], self.cur_func_stack);
                const old_stack: []*function_def_mod.FunctionDef = if (old_capacity != 0) self.cur_func_stack.ptr[0..old_capacity] else self.cur_func_stack[0..0];
                self.cur_func_stack = next[0..old_len];
                self.cur_func_stack_capacity = new_capacity;
                if (old_capacity != 0) {
                    self.function.memory.free(*function_def_mod.FunctionDef, old_stack);
                }
            }

            self.cur_func_stack = self.cur_func_stack.ptr[0..new_len];
            self.cur_func_stack[old_len] = fd;
        }

        /// Pop the current FunctionDef from the stack. Called when exiting
        /// a nested function. Returns the popped FunctionDef pointer.
        fn popFunction(self: *State) *function_def_mod.FunctionDef {
            const fd = self.cur_func_stack[self.cur_func_stack.len - 1];
            self.cur_func_stack = self.cur_func_stack.ptr[0 .. self.cur_func_stack.len - 1];
            return fd;
        }

        fn discardCurrentFunction(self: *State) void {
            const fd = self.popFunction();
            self.discardFunctionDef(fd);
        }

        fn discardFunctionDef(self: *State, fd: *function_def_mod.FunctionDef) void {
            if (self.runtime) |rt| {
                fd.deinit(rt);
                self.function.memory.destroy(function_def_mod.FunctionDef, fd);
                return;
            }
            fd.discard_next = self.discarded_func_head;
            self.discarded_func_head = fd;
        }

        /// Mirror `push_scope` (`quickjs.c:23486`): allocate a new
        /// `VarScope` whose parent is the current scope, then switch
        /// `scope_level` to it. Call on entry to a new lexical block.
        pub fn pushScopeIdentity(self: *State) Error!void {
            const parent = self.scope_level;
            const new_scope = self.cur_func().appendScope(parent) catch return error.OutOfMemory;
            self.scope_level = new_scope;
            self.cur_func().scope_level = new_scope;
        }

        /// Allocate a lexical scope and emit its phase-1 entry event.  Parser
        /// state restoration on emission failure is identity-only: a failed
        /// parse must not manufacture a runtime leave event.
        pub fn pushScope(self: *State) Error!void {
            try self.pushScopeIdentity();
            errdefer self.popScopeIdentity();
            try self.emitEnterScope();
        }

        /// Create the one real function-body scope and emit its marker at the
        /// exact parser boundary consumed by `instantiate_hoisted_definitions`.
        pub fn beginFunctionBody(self: *State) Error!void {
            try self.pushScopeIdentity();
            errdefer self.popScopeIdentity();
            self.cur_func().body_scope = self.scope_level;
            try self.emitEnterScope();
        }

        /// Function bodies remain the current scope through finalization, just
        /// as in QuickJS. There is no body leave event or identity pop.
        pub fn finishFunctionBody(self: *State) void {
            _ = self;
        }

        /// Mirror `pop_scope` (`quickjs.c:23532`): restore the parent
        /// scope. Also updates `function_def.scope_first` to the outer
        /// scope's first lexical var so subsequent lookups see the
        /// correct chain.
        pub fn popScopeIdentity(self: *State) void {
            if (self.scope_level < 0) return;
            const parent = self.cur_func().scopes[@intCast(self.scope_level)].parent;
            self.scope_level = parent;
            self.cur_func().scope_level = parent;
            // Recompute scope_first for the new current scope (mirrors
            // `get_first_lexical_var` at `quickjs.c:23521`).
            var scope = parent;
            self.cur_func().scope_first = -1;
            while (scope >= 0) {
                const s_idx = self.cur_func().scopes[@intCast(scope)].first;
                if (s_idx >= 0) {
                    self.cur_func().scope_first = s_idx;
                    break;
                }
                scope = self.cur_func().scopes[@intCast(scope)].parent;
            }
        }

        /// Emit the current lexical scope's phase-1 exit event, then restore
        /// the parent scope identity.
        pub fn popScope(self: *State) Error!void {
            try self.emitLeaveScope(self.scope_level);
            self.popScopeIdentity();
        }

        /// Register a variable declaration in `function_def.vars`.
        /// Mirrors `add_scope_var` (`quickjs.c:23577`). `kind` selects
        /// the `VarKind` (normal for `var`, normal + is_lexical for let,
        /// normal + is_lexical + is_const for const). Returns the var
        /// index. Currently informational only; the interim pipeline
        /// ignores `function_def` and relies on global fallback for all
        /// var references.
        pub fn addScopeVar(
            self: *State,
            name: Atom,
            kind: function_def_mod.VarKind,
            is_lexical: bool,
            is_const: bool,
        ) Error!i32 {
            return self.cur_func().addScopeVar(name, kind, self.scope_level, is_lexical, is_const) catch return error.OutOfMemory;
        }

        /// Parser-time declaration classes accepted by QuickJS `define_var`.
        /// Private names and pseudo locals deliberately bypass this API, just
        /// as upstream uses add_private_class_field/add_var for those rows.
        pub const DefineVarType = enum {
            with_,
            let_,
            const_,
            function_decl,
            new_function_decl,
            catch_,
            var_,
        };

        /// The physical binding selected by `defineVar`.  QuickJS encodes the
        /// same three outcomes as a local index, ARGUMENT_VAR_OFFSET, or
        /// GLOBAL_VAR_OFFSET; a tagged result avoids importing those C bit
        /// sentinels into Zig consumers.
        pub const DefinedVar = union(enum) {
            local: u16,
            argument: u16,
            global,
        };

        const LexicalDeclaration = union(enum) {
            local: u16,
            global,
        };

        fn atFunctionBodyScope(self: *State) bool {
            return self.cur_func().body_scope >= 0 and self.scope_level == self.cur_func().body_scope;
        }

        fn atProgramBodyScope(self: *State) bool {
            return self.cur_func_stack.len == 0 and self.cur_func().is_eval and self.atFunctionBodyScope();
        }

        fn isChildScope(self: *State, scope: i32, parent_scope: i32) bool {
            if (scope < 0 or parent_scope < 0) return false;
            const scopes = self.cur_func().scopes;
            var current = scope;
            var visited: usize = 0;
            while (current >= 0 and visited <= scopes.len) : (visited += 1) {
                if (current == parent_scope) return true;
                if (@as(usize, @intCast(current)) >= scopes.len) return false;
                current = scopes[@intCast(current)].parent;
            }
            return false;
        }

        fn firstGlobalVarIndex(self: *State, name: Atom) ?usize {
            for (self.cur_func().global_vars, 0..) |gv, idx| {
                if (gv.var_name == name) return idx;
            }
            return null;
        }

        /// QuickJS `find_lexical_decl` (quickjs.c:24087).  `scope_first`
        /// already denotes the complete visible chain; do not rebuild a
        /// parallel name ledger here.  Only global-eval (not module/direct
        /// eval) adds the GLOBAL_VAR_OFFSET lexical fallback.
        fn findLexicalDeclaration(self: *State, name: Atom, check_catch: bool) ?LexicalDeclaration {
            const fd = self.cur_func();
            var var_idx = fd.scope_first;
            var visited: usize = 0;
            while (var_idx >= 0 and visited <= fd.vars.len) : (visited += 1) {
                if (@as(usize, @intCast(var_idx)) >= fd.vars.len) break;
                const vd = fd.vars[@intCast(var_idx)];
                if (vd.var_name == name and (vd.is_lexical or (check_catch and vd.var_kind == .catch_))) {
                    return .{ .local = @intCast(var_idx) };
                }
                var_idx = vd.scope_next;
            }
            if (fd.is_eval and
                !fd.is_direct_eval and
                !fd.is_indirect_eval and
                !fd.is_module and
                self.findLexicalGlobalVar(name))
            {
                return .global;
            }
            return null;
        }

        /// QuickJS `find_var_in_child_scope` (quickjs.c:24048).  A function
        /// `var` remains a scope-0 row, but until final scope-link rebuilding
        /// its `scope_next` field is the lexical scope where the declaration
        /// occurred.  Such rows are intentionally absent from scope.first.
        fn findFunctionVarInChildScope(self: *State, name: Atom, scope_level: i32) ?u16 {
            for (self.cur_func().vars, 0..) |vd, idx| {
                if (vd.var_name != name or vd.scope_level != 0) continue;
                if (self.isChildScope(vd.scope_next, scope_level)) return @intCast(idx);
            }
            return null;
        }

        fn appendFunctionVarAtOrigin(self: *State, name: Atom, origin_scope: i32) Error!u16 {
            const idx = self.cur_func().appendVar(.{
                .var_name = name,
                .scope_level = 0,
                .scope_next = origin_scope,
                .is_lexical = false,
                .is_const = false,
                .var_kind = .normal,
            }) catch return error.OutOfMemory;
            return @intCast(idx);
        }

        /// Single declaration-semantics owner mirroring QuickJS `define_var`
        /// (quickjs.c:24303).  Syntax-token restrictions stay in the thin
        /// producer wrappers; every scope collision and physical row choice
        /// belongs here.
        pub fn defineVar(self: *State, name: Atom, var_def_type: DefineVarType) Error!DefinedVar {
            const fd = self.cur_func();
            switch (var_def_type) {
                .with_ => {
                    return .{ .local = @intCast(try self.addScopeVar(name, .normal, false, false)) };
                },
                .let_, .const_, .function_decl, .new_function_decl => {
                    if (self.findLexicalDeclaration(name, true)) |decl| switch (decl) {
                        .local => |idx| {
                            const existing = fd.vars[idx];
                            if (existing.scope_level == self.scope_level) {
                                const sloppy_function_redefinition = !fd.is_strict_mode and
                                    var_def_type == .function_decl and
                                    existing.var_kind == .function_decl;
                                if (!sloppy_function_redefinition) return Error.UnexpectedToken;
                            } else if (existing.var_kind == .catch_ and existing.scope_level + 2 == self.scope_level) {
                                return Error.UnexpectedToken;
                            }
                        },
                        .global => if (self.atFunctionBodyScope()) return Error.UnexpectedToken,
                    };

                    if (var_def_type != .function_decl and
                        var_def_type != .new_function_decl and
                        self.atFunctionBodyScope() and
                        fd.findArg(name) >= 0)
                    {
                        return Error.UnexpectedToken;
                    }
                    if (self.findFunctionVarInChildScope(name, self.scope_level) != null) {
                        return Error.UnexpectedToken;
                    }
                    if (fd.is_global_var) {
                        if (self.firstGlobalVarIndex(name)) |global_idx| {
                            const gv = fd.global_vars[global_idx];
                            if (self.isChildScope(gv.scope_level, self.scope_level)) {
                                return Error.UnexpectedToken;
                            }
                        }
                    }

                    // eval_type GLOBAL/MODULE body lexicals are declaration
                    // carriers, not frame locals.  Direct eval deliberately
                    // takes the add_scope_var branch even when sloppy.
                    if (fd.is_eval and
                        !fd.is_direct_eval and
                        !fd.is_indirect_eval and
                        self.atFunctionBodyScope())
                    {
                        try self.addGlobalVar(name, true, var_def_type == .const_);
                        return .global;
                    }

                    const kind: function_def_mod.VarKind = switch (var_def_type) {
                        .function_decl => .function_decl,
                        .new_function_decl => .new_function_decl,
                        else => .normal,
                    };
                    return .{ .local = @intCast(try self.addScopeVar(
                        name,
                        kind,
                        true,
                        var_def_type == .const_,
                    )) };
                },
                .catch_ => {
                    return .{ .local = @intCast(try self.addScopeVar(name, .catch_, false, false)) };
                },
                .var_ => {
                    if (self.findLexicalDeclaration(name, false) != null) {
                        return Error.UnexpectedToken;
                    }
                    if (fd.is_global_var) {
                        if (self.firstGlobalVarIndex(name)) |global_idx| {
                            const gv = fd.global_vars[global_idx];
                            if (gv.is_lexical and
                                gv.scope_level == self.scope_level and
                                fd.is_module)
                            {
                                return Error.UnexpectedToken;
                            }
                        }
                        try self.addGlobalVar(name, false, false);
                        return .global;
                    }
                    if (self.findFunctionScopeVar(name)) |idx| return .{ .local = idx };
                    const arg_idx = fd.findArg(name);
                    if (arg_idx >= 0) return .{ .argument = @intCast(arg_idx) };

                    const idx = try self.appendFunctionVarAtOrigin(name, self.scope_level);
                    if (atomNameEquals(self, name, "arguments") and fd.has_arguments_binding) {
                        fd.arguments_var_idx = idx;
                    }
                    return .{ .local = idx };
                },
            }
        }

        fn scopeHasVar(self: *State, scope_idx: i32, name: Atom) bool {
            if (scope_idx < 0 or @as(usize, @intCast(scope_idx)) >= self.cur_func().scopes.len) return false;
            var var_idx = self.cur_func().scopes[@intCast(scope_idx)].first;
            while (var_idx >= 0 and @as(usize, @intCast(var_idx)) < self.cur_func().vars.len) {
                const var_def = self.cur_func().vars[@intCast(var_idx)];
                if (var_def.scope_level != scope_idx) break;
                if (var_def.var_name == name) return true;
                var_idx = var_def.scope_next;
            }
            return false;
        }

        fn visibleLexicalScopeVar(self: *State, name: Atom) ?u16 {
            var scope_idx = self.scope_level;
            while (scope_idx >= 0 and @as(usize, @intCast(scope_idx)) < self.cur_func().scopes.len) {
                var var_idx = self.cur_func().scopes[@intCast(scope_idx)].first;
                while (var_idx >= 0 and @as(usize, @intCast(var_idx)) < self.cur_func().vars.len) {
                    const var_def = self.cur_func().vars[@intCast(var_idx)];
                    if (var_def.scope_level != scope_idx) break;
                    if (var_def.var_name == name and var_def.is_lexical) return @intCast(var_idx);
                    var_idx = var_def.scope_next;
                }
                scope_idx = self.cur_func().scopes[@intCast(scope_idx)].parent;
            }
            return null;
        }

        /// qjs find_lexical_global_var (quickjs.c:24078): a global_vars entry with
        /// is_lexical set (a top-level let/const declared as JS_CLOSURE_GLOBAL_DECL).
        fn findLexicalGlobalVar(self: *State, name: Atom) bool {
            for (self.cur_func().global_vars) |gv| {
                if (gv.var_name == name and gv.is_lexical) return true;
            }
            return false;
        }

        /// qjs find_global_var (quickjs.c:24066): any global_vars entry with this
        /// name — top-level var, hoisted function declaration, or lexical.
        fn findGlobalVar(self: *State, name: Atom) bool {
            for (self.cur_func().global_vars) |gv| {
                if (gv.var_name == name) return true;
            }
            return false;
        }

        /// True when a lexical declaration is being made at the body scope of
        /// global script or global sloppy-eval code, where qjs runs the
        /// `fd->is_global_var` redefinition check of define_var
        /// (quickjs.c:24352-24360). At the body scope every global_vars entry
        /// satisfies is_child_scope(hf->scope_level, fd->scope_level), so the
        /// check degenerates to find_global_var.
        fn atGlobalLexicalBodyScope(self: *State) bool {
            return self.atProgramBodyScope() and
                !self.top_level_lexical_as_module_ref and
                (!self.is_eval or self.eval_global_var_bindings);
        }

        fn lexicalBodyDeclarationConflictsWithGlobalVar(self: *State, name: Atom) bool {
            if (!self.atProgramBodyScope()) return false;
            if (self.atGlobalLexicalBodyScope()) return self.findGlobalVar(name);
            return self.is_eval and
                !self.eval_global_var_bindings and
                !self.eval_in_parameter_initializer and
                self.findGlobalVar(name);
        }

        fn ensureFunctionScopeVar(self: *State, name: Atom) Error!u16 {
            if (self.findFunctionScopeVar(name)) |idx| return idx;
            // Annex-B's create_func_var path calls add_var directly and thus
            // never links this row into scope 0's lexical chain.  Zero is the
            // parser-era origin value left by QuickJS's zero-initialized row.
            return try self.appendFunctionVarAtOrigin(name, 0);
        }

        fn findFunctionScopeVar(self: *State, name: Atom) ?u16 {
            const vars = self.cur_func().vars;
            var i = vars.len;
            while (i > 0) {
                i -= 1;
                if (vars[i].var_name == name and vars[i].scope_level == 0) return @intCast(i);
            }
            return null;
        }

        fn addGlobalVar(self: *State, name: Atom, is_lexical: bool, is_const: bool) Error!void {
            return self.cur_func().appendGlobalVar(.{
                .cpool_idx = -1,
                .force_init = false,
                .is_configurable = self.eval_global_var_bindings and !is_lexical,
                .is_lexical = is_lexical,
                .is_const = is_const,
                .scope_level = self.scope_level,
                .var_name = name,
            }) catch return error.OutOfMemory;
        }

        fn addGlobalAnnexBFunctionVar(self: *State, name: Atom, is_configurable: bool) Error!void {
            return self.cur_func().appendGlobalVar(.{
                .cpool_idx = -1,
                // QuickJS only forces the Annex-B var copy in strict code;
                // Annex B itself is a sloppy-code rule, so this declaration
                // must not be classified as a global function initializer.
                .force_init = false,
                .is_configurable = is_configurable,
                .is_lexical = false,
                .is_const = false,
                .scope_level = 0,
                .var_name = name,
            }) catch return error.OutOfMemory;
        }

        fn addDirectEvalVarObjectVar(self: *State, name: Atom) Error!void {
            const fd = self.cur_func();
            fd.appendGlobalVar(.{
                .cpool_idx = -1,
                .force_init = true,
                .is_configurable = true,
                .is_lexical = false,
                .is_const = false,
                .scope_level = 0,
                .var_name = name,
            }) catch return error.OutOfMemory;
        }

        fn emitGlobalScopePutVar(self: *State, atom_id: Atom) Error!void {
            // `scope_level = -1` is a resolver-only sentinel for Annex B global
            // function binding updates: bypass block/function locals and lower to
            // final `put_var`.
            try self.emitOpAtomU16(opcode.op.scope_put_var, atom_id, std.math.maxInt(u16));
        }

        fn emitEvalVarObjectScopePutVar(self: *State, atom_id: Atom) Error!void {
            // Annex B's var-copy assignment bypasses the block lexical binding
            // but must still traverse the eval declaration environment. Scope
            // zero excludes the block-local function while retaining the
            // compiler-seeded _var_/_arg_var_ and exact caller closure targets.
            try self.emitOpAtomU16(opcode.op.scope_put_var, atom_id, 0);
        }

        /// Atom id reserved for the eval-return slot, mirroring
        /// `JS_ATOM__ret_` / `<ret>` (`quickjs-atom.h:115`). Used as the
        /// var name for the synthetic local that captures every
        /// expression-statement result in eval mode.
        pub const eval_ret_atom: Atom = atom_module.ids.ret;

        /// Switch the parser into eval mode and allocate the synthetic
        /// `<ret>` local that holds the result of the last evaluated
        /// expression. Mirrors `set_eval_ret_undefined` setup +
        /// `add_var(JS_ATOM__ret_)` (`quickjs.c:28219`/`28834`). The
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
            self.cur_func().is_eval = true;
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
            const idx = try self.appendFunctionVarAtOrigin(eval_ret_atom, 0);
            self.eval_ret_idx = idx;
            self.cur_func().eval_ret_idx = idx;
            // Emit the initialiser directly by slot. Every syntactic finally
            // adds another same-named `<ret>` save slot, so name lookup would
            // become ambiguous after the first one.
            try self.emitOp(opcode.op.undefined);
            try self.emitEvalRetPut();
        }

        fn emitEvalRetGet(self: *State) Error!void {
            if (self.eval_ret_idx < 0) return;
            try self.emitOpU16(opcode.op.get_loc, @intCast(self.eval_ret_idx));
        }

        fn emitEvalRetPut(self: *State) Error!void {
            if (self.eval_ret_idx < 0) return;
            try self.emitOpU16(opcode.op.put_loc, @intCast(self.eval_ret_idx));
        }

        /// Mirror the tail of `js_parse_program` (`quickjs.c:31459`):
        /// after the last statement is parsed, load `<ret>` and terminate the
        /// body with an explicit value-return. No-op when completion capture is
        /// disabled.
        pub fn finalizeEvalReturn(self: *State) Error!void {
            if (self.eval_ret_idx < 0) return;
            try self.emitEvalRetGet();
            try self.emitOp(opcode.op.@"return");
        }

        /// Mirror QuickJS `set_eval_ret_undefined` (`quickjs.c:28219-28226`):
        /// control-flow statements reset eval completion before parsing their
        /// children, and executed expression statements overwrite it.
        pub fn setEvalReturnUndefined(self: *State) Error!void {
            if (self.eval_ret_idx < 0) return;
            try self.emitOp(opcode.op.undefined);
            try self.emitEvalRetPut();
        }

        pub fn emitReturnUndefined(self: *State) Error!void {
            try self.emitOp(opcode.op.return_undef);
        }

        /// Advance one token. Frees the payload of the consumed token.
        fn advance(self: *State) Error!void {
            // Native C-stack recursion guard. Every recursive-descent path
            // (parens, arrays, objects, nested statements) consumes tokens
            // through here, so a single check mirrors QuickJS guarding
            // `next_token` (quickjs.c:22836) and turns pathological nesting into
            // a catchable SyntaxError instead of a native stack overflow.
            if (self.runtime) |rt| {
                if (rt.checkNativeStackOverflow(0)) return error.StackOverflow;
            }
            self.last_token_end_offset = self.currentTokenEndOffset();
            self.last_token_line_num = self.token.line_num;
            self.last_token_col_num = self.token.col_num;
            self.lex.freeToken(&self.token);
            self.token = try self.lex.next();
        }

        pub fn peekKind(self: *const State) tok.TokenKind {
            return self.token.val;
        }

        fn currentTokenStartOffset(self: *const State) usize {
            const source_ptr = @intFromPtr(self.lex.source.ptr);
            const token_ptr = @intFromPtr(self.token.ptr);
            if (token_ptr <= source_ptr) return 0;
            return @min(token_ptr - source_ptr, self.lex.source.len);
        }

        fn currentTokenEndOffset(self: *const State) usize {
            return @min(self.currentTokenStartOffset() + self.token.len, self.lex.source.len);
        }

        fn captureFunctionSource(self: *State, fd: *function_def_mod.FunctionDef, source_start: usize) Error!void {
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

        fn setChildFunctionSourceByCpoolIndex(
            self: *State,
            cpool_idx: u16,
            source_start: usize,
            source_end: usize,
        ) Error!void {
            for (self.cur_func().child_list) |child| {
                if (child.parent_cpool_idx != cpool_idx) continue;
                try self.setFunctionSourceRange(child, source_start, source_end);
                return;
            }
        }

        fn isPunct(self: *const State, ch: u8) bool {
            return self.token.val == @as(tok.TokenKind, @intCast(ch));
        }

        /// Check if we got a line terminator before the current token (for ASI).
        fn gotLineTerminator(self: *const State) bool {
            return self.lex.gotLineTerminator();
        }

        // ---- label management ----
        // This parser still lowers jumps directly, but labelled control flow
        // mirrors QuickJS `push_break_entry` / `emit_break` enough to route
        // labels without exposing regular labelled statements to unlabelled
        // `break`.

        fn hasActiveLabel(s: *State, atom_id: Atom) bool {
            for (s.label_frames.items) |frame| {
                if (frame.atom == atom_id) return true;
            }
            return false;
        }

        fn pushLabelFrame(s: *State, atom_id: Atom, allow_continue: bool) Error!usize {
            try s.label_frames.append(s.function.memory.allocator, LabelFrame{
                .atom = atom_id,
                .allow_continue = allow_continue,
                .catch_marker_depth = s.active_catch_marker_depth,
                .control_frame_depth = s.continue_frame_lens.items.len,
                .break_frame_depth = s.break_frame_lens.items.len,
            });
            return s.label_frames.items.len - 1;
        }

        fn patchLabelBreaks(s: *State, frame_index: usize) Error!void {
            for (s.label_frames.items[frame_index].break_fixups.items) |off| {
                try patchForwardJump(s, off);
            }
        }

        fn patchLabelContinues(s: *State, frame_index: usize) Error!void {
            for (s.label_frames.items[frame_index].continue_fixups.items) |off| {
                try patchForwardJump(s, off);
            }
        }

        fn popLabelFrame(s: *State, frame_index: usize) void {
            std.debug.assert(frame_index + 1 == s.label_frames.items.len);
            s.label_frames.items[frame_index].deinit(s.function.memory.allocator);
            _ = s.label_frames.pop().?;
        }

        fn findLabelFrame(s: *State, atom_id: Atom) ?usize {
            var i = s.label_frames.items.len;
            while (i != 0) {
                i -= 1;
                if (s.label_frames.items[i].atom == atom_id) return i;
            }
            return null;
        }

        fn emitLabelledBreak(s: *State, atom_id: Atom) Error!void {
            try emitControlThroughFinally(s, .{ .kind = .@"break", .label_atom = atom_id });
        }

        fn emitLabelledBreakNoFinallyCapture(s: *State, atom_id: Atom) Error!void {
            const frame_index = findLabelFrame(s, atom_id) orelse return Error.UnexpectedToken;
            try emitCatchMarkerDropsToDepth(s, s.label_frames.items[frame_index].catch_marker_depth);
            var frame_depth = s.break_frame_cleanup_drops.items.len;
            while (frame_depth > s.label_frames.items[frame_index].break_frame_depth) {
                frame_depth -= 1;
                try emitCrossFrameCleanup(s, s.break_frame_cross_cleanup_drops.items[frame_depth]);
            }
            if (s.label_frames.items[frame_index].allow_continue and s.label_frames.items[frame_index].break_frame_depth > 0) {
                try emitUnlabelledBreakCleanup(s, s.break_frame_cleanup_drops.items[s.label_frames.items[frame_index].break_frame_depth - 1]);
            }
            const off = try emitForwardJumpNoSource(s, opcode.op.goto);
            try s.label_frames.items[frame_index].break_fixups.append(s.function.memory.allocator, off);
        }

        fn emitLabelledContinue(s: *State, atom_id: Atom) Error!void {
            try emitControlThroughFinally(s, .{ .kind = .@"continue", .label_atom = atom_id });
        }

        fn emitLabelledContinueNoFinallyCapture(s: *State, atom_id: Atom) Error!void {
            const frame_index = findLabelFrame(s, atom_id) orelse return Error.UnexpectedToken;
            if (!s.label_frames.items[frame_index].allow_continue) return Error.UnexpectedToken;
            try emitCatchMarkerDropsToDepth(s, s.label_frames.items[frame_index].catch_marker_depth);
            var frame_depth = s.continue_frame_lens.items.len;
            while (frame_depth > s.label_frames.items[frame_index].control_frame_depth) {
                frame_depth -= 1;
                const break_frame_index = s.continue_frame_break_frame_indices.items[frame_depth];
                try emitCrossFrameCleanup(s, s.break_frame_cross_cleanup_drops.items[break_frame_index]);
            }
            if (s.label_frames.items[frame_index].control_frame_depth > 0) {
                try emitCrossFrameCleanup(s, s.continue_frame_cleanup_drops.items[s.label_frames.items[frame_index].control_frame_depth - 1]);
            }
            const off = try emitForwardJumpNoSource(s, opcode.op.goto);
            try s.label_frames.items[frame_index].continue_fixups.append(s.function.memory.allocator, off);
        }

        fn labelStartAtom(s: *State) ?Atom {
            if (!isIdentifierLikeToken(s)) return null;
            if (s.peekNextKind() != @as(tok.TokenKind, @intCast(':'))) return null;
            const kind = s.peekKind();
            const atom_id = identifierLikeAtom(s);
            if (kind == tok.TOK_IDENT and escapedIdentifierIsReservedWordForCurrentContext(s, atom_id, s.token.payload.ident.has_escape)) return null;
            return atom_id;
        }

        fn isReservedLabelIdentifier(s: *State, atom_id: Atom) bool {
            return (s.lex.is_module and atomNameEquals(s, atom_id, "await")) or
                (s.in_async and atomNameEquals(s, atom_id, "await")) or
                (s.in_class_static_block and atomNameEquals(s, atom_id, "await")) or
                (s.in_generator and atomNameEquals(s, atom_id, "yield")) or
                ((s.is_strict or s.cur_func().is_strict_mode) and atomNameEquals(s, atom_id, "yield"));
        }

        fn deinitCurrentControlFrames(s: *State) void {
            const allocator = s.function.memory.allocator;
            s.break_fixups.deinit(allocator);
            s.break_frame_lens.deinit(allocator);
            s.break_frame_catch_marker_depths.deinit(allocator);
            s.break_frame_cleanup_drops.deinit(allocator);
            s.break_frame_cross_cleanup_drops.deinit(allocator);
            s.continue_fixups.deinit(allocator);
            s.continue_frame_lens.deinit(allocator);
            s.continue_frame_break_frame_indices.deinit(allocator);
            s.continue_frame_catch_marker_depths.deinit(allocator);
            s.continue_frame_cleanup_drops.deinit(allocator);
            for (s.label_frames.items) |*frame| {
                frame.deinit(allocator);
            }
            s.label_frames.deinit(allocator);
            s.using_block_frames.deinit(allocator);
        }

        fn enterControlBoundary(s: *State) ControlFrames {
            const saved = ControlFrames{
                .top_break = s.top_break,
                .break_fixups = s.break_fixups,
                .break_frame_lens = s.break_frame_lens,
                .break_frame_catch_marker_depths = s.break_frame_catch_marker_depths,
                .break_frame_cleanup_drops = s.break_frame_cleanup_drops,
                .break_frame_cross_cleanup_drops = s.break_frame_cross_cleanup_drops,
                .continue_fixups = s.continue_fixups,
                .continue_frame_lens = s.continue_frame_lens,
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
            s.break_frame_catch_marker_depths = .empty;
            s.break_frame_cleanup_drops = .empty;
            s.break_frame_cross_cleanup_drops = .empty;
            s.continue_fixups = .empty;
            s.continue_frame_lens = .empty;
            s.continue_frame_break_frame_indices = .empty;
            s.continue_frame_catch_marker_depths = .empty;
            s.continue_frame_cleanup_drops = .empty;
            s.label_frames = .empty;
            s.pending_label_atom = null;
            s.active_catch_marker_depth = 0;
            s.using_block_frames = .empty;
            return saved;
        }

        fn leaveControlBoundary(s: *State, saved: ControlFrames) void {
            s.deinitCurrentControlFrames();
            s.top_break = saved.top_break;
            s.break_fixups = saved.break_fixups;
            s.break_frame_lens = saved.break_frame_lens;
            s.break_frame_catch_marker_depths = saved.break_frame_catch_marker_depths;
            s.break_frame_cleanup_drops = saved.break_frame_cleanup_drops;
            s.break_frame_cross_cleanup_drops = saved.break_frame_cross_cleanup_drops;
            s.continue_fixups = saved.continue_fixups;
            s.continue_frame_lens = saved.continue_frame_lens;
            s.continue_frame_break_frame_indices = saved.continue_frame_break_frame_indices;
            s.continue_frame_catch_marker_depths = saved.continue_frame_catch_marker_depths;
            s.continue_frame_cleanup_drops = saved.continue_frame_cleanup_drops;
            s.label_frames = saved.label_frames;
            s.pending_label_atom = saved.pending_label_atom;
            s.active_catch_marker_depth = saved.active_catch_marker_depth;
            s.using_block_frames = saved.using_block_frames;
        }

        fn truncateClassPrivateElements(self: *State, len: usize) void {
            var i = len;
            while (i < self.class_private_elements.items.len) : (i += 1) {
                self.function.atoms.free(self.class_private_elements.items[i].atom);
            }
            self.class_private_elements.shrinkRetainingCapacity(len);
        }

        fn truncateClassPrivateBoundNames(self: *State, len: usize) void {
            var i = len;
            while (i < self.class_private_bound_names.items.len) : (i += 1) {
                self.function.atoms.free(self.class_private_bound_names.items[i]);
            }
            self.class_private_bound_names.shrinkRetainingCapacity(len);
        }

        /// Expect a semicolon, applying ASI rules. Returns true if a semicolon
        /// was present or inserted via ASI.
        fn expectSemicolon(s: *State) Error!bool {
            if (s.isPunct(';')) {
                try s.advance();
                return true;
            }
            // ASI: if we have a line terminator or are at EOF or closing brace,
            // insert a semicolon automatically.
            if (s.gotLineTerminator() or s.peekKind() == tok.TOK_EOF or s.isPunct('}')) {
                return true;
            }
            return Error.UnexpectedToken;
        }

        /// Expect a specific token kind.
        fn expectToken(s: *State, kind: tok.TokenKind) Error!void {
            if (s.peekKind() != kind) return Error.UnexpectedToken;
            try s.advance();
        }

        /// Peek at the next token kind without consuming the current token.
        /// Saves and restores lexer position so the cached token stays valid.
        fn peekNextKind(s: *State) tok.TokenKind {
            const saved_pos = s.lex.pos;
            const saved_line = s.lex.line;
            const saved_col = s.lex.col;
            const saved_got_lf = s.lex.got_lf;
            const saved_mark_pos = s.lex.mark_pos;
            const saved_mark_line = s.lex.mark_line;
            const saved_mark_col = s.lex.mark_col;
            defer {
                s.lex.pos = saved_pos;
                s.lex.line = saved_line;
                s.lex.col = saved_col;
                s.lex.got_lf = saved_got_lf;
                s.lex.mark_pos = saved_mark_pos;
                s.lex.mark_line = saved_mark_line;
                s.lex.mark_col = saved_mark_col;
            }
            var peek_token = s.lex.next() catch return tok.TOK_EOF;
            defer s.lex.freeToken(&peek_token);
            return peek_token.val;
        }

        fn peekNextIsOfToken(s: *State) bool {
            const saved_pos = s.lex.pos;
            const saved_line = s.lex.line;
            const saved_col = s.lex.col;
            const saved_got_lf = s.lex.got_lf;
            const saved_mark_pos = s.lex.mark_pos;
            const saved_mark_line = s.lex.mark_line;
            const saved_mark_col = s.lex.mark_col;
            defer {
                s.lex.pos = saved_pos;
                s.lex.line = saved_line;
                s.lex.col = saved_col;
                s.lex.got_lf = saved_got_lf;
                s.lex.mark_pos = saved_mark_pos;
                s.lex.mark_line = saved_mark_line;
                s.lex.mark_col = saved_mark_col;
            }
            var peek_token = s.lex.next() catch return false;
            defer s.lex.freeToken(&peek_token);
            if (peek_token.val == tok.TOK_OF) return true;
            return peek_token.val == tok.TOK_IDENT and
                !peek_token.payload.ident.has_escape and
                atomNameEquals(s, peek_token.payload.ident.atom, "of");
        }

        fn peekNextKindNoLineTerminator(s: *State, expected: tok.TokenKind) bool {
            const saved_pos = s.lex.pos;
            const saved_line = s.lex.line;
            const saved_col = s.lex.col;
            const saved_got_lf = s.lex.got_lf;
            const saved_mark_pos = s.lex.mark_pos;
            const saved_mark_line = s.lex.mark_line;
            const saved_mark_col = s.lex.mark_col;
            defer {
                s.lex.pos = saved_pos;
                s.lex.line = saved_line;
                s.lex.col = saved_col;
                s.lex.got_lf = saved_got_lf;
                s.lex.mark_pos = saved_mark_pos;
                s.lex.mark_line = saved_mark_line;
                s.lex.mark_col = saved_mark_col;
            }
            var peek_token = s.lex.next() catch return false;
            defer s.lex.freeToken(&peek_token);
            const matched = peek_token.val == expected and !s.lex.gotLineTerminator();
            return matched;
        }

        fn peekNextKindWithLineTerminator(s: *State, line_terminator: *bool) tok.TokenKind {
            const saved_pos = s.lex.pos;
            const saved_line = s.lex.line;
            const saved_col = s.lex.col;
            const saved_got_lf = s.lex.got_lf;
            const saved_mark_pos = s.lex.mark_pos;
            const saved_mark_line = s.lex.mark_line;
            const saved_mark_col = s.lex.mark_col;
            defer {
                s.lex.pos = saved_pos;
                s.lex.line = saved_line;
                s.lex.col = saved_col;
                s.lex.got_lf = saved_got_lf;
                s.lex.mark_pos = saved_mark_pos;
                s.lex.mark_line = saved_mark_line;
                s.lex.mark_col = saved_mark_col;
            }
            var peek_token = s.lex.next() catch return tok.TOK_EOF;
            defer s.lex.freeToken(&peek_token);
            line_terminator.* = s.lex.gotLineTerminator();
            return peek_token.val;
        }

        /// Mirror QuickJS's `SKIP_HAS_SEMI` dispatch at the `for` statement
        /// boundary. Every C-style for head has a top-level semicolon; heads
        /// without one are handed to the real for-in/of parser, which owns the
        /// grammar and diagnostics. This scan tracks delimiters only and never
        /// tries to classify the left-hand-side shape.
        fn forHeadHasNoTopLevelSemicolon(s: *State) bool {
            const saved_pos = s.lex.pos;
            const saved_line = s.lex.line;
            const saved_col = s.lex.col;
            const saved_got_lf = s.lex.got_lf;
            const saved_mark_pos = s.lex.mark_pos;
            const saved_mark_line = s.lex.mark_line;
            const saved_mark_col = s.lex.mark_col;
            const saved_token = s.token;
            var advanced = false;
            defer {
                if (advanced) s.lex.freeToken(&s.token);
                s.lex.pos = saved_pos;
                s.lex.line = saved_line;
                s.lex.col = saved_col;
                s.lex.got_lf = saved_got_lf;
                s.lex.mark_pos = saved_mark_pos;
                s.lex.mark_line = saved_mark_line;
                s.lex.mark_col = saved_mark_col;
                s.token = saved_token;
            }

            const advanceLocal = struct {
                fn call(state: *State, did_advance: *bool) bool {
                    const next = state.lex.next() catch return false;
                    state.lex.freeToken(&state.token);
                    state.token = next;
                    did_advance.* = true;
                    return true;
                }
            }.call;

            var paren_depth: usize = 0;
            var bracket_depth: usize = 0;
            var brace_depth: usize = 0;
            var previous_token_kind: ?tok.TokenKind = null;
            while (true) {
                const kind = s.peekKind();
                if (kind == tok.TOK_EOF) return false;
                if (kind == tok.TOK_TEMPLATE) {
                    skipTemplateInPredeclareScan(s, s.token) catch return false;
                    if (!advanceLocal(s, &advanced)) return false;
                    previous_token_kind = tok.TOK_TEMPLATE;
                    continue;
                }
                if (tokenCanStartSlashRegexp(kind) and
                    (skipRegexpInPredeclareScan(s, previous_token_kind) catch return false))
                {
                    if (!advanceLocal(s, &advanced)) return false;
                    previous_token_kind = tok.TOK_REGEXP;
                    continue;
                }

                switch (kind) {
                    '(' => paren_depth += 1,
                    ')' => {
                        if (paren_depth == 0 and bracket_depth == 0 and brace_depth == 0) return true;
                        if (paren_depth == 0) return false;
                        paren_depth -= 1;
                    },
                    '[' => bracket_depth += 1,
                    ']' => {
                        if (bracket_depth == 0) return false;
                        bracket_depth -= 1;
                    },
                    '{' => brace_depth += 1,
                    '}' => {
                        if (brace_depth == 0) return false;
                        brace_depth -= 1;
                    },
                    ';' => if (paren_depth == 0 and bracket_depth == 0 and brace_depth == 0) return false,
                    else => {},
                }
                previous_token_kind = kind;
                if (!advanceLocal(s, &advanced)) return false;
            }
        }

        /// Check if the current token is an identifier with the given name
        fn isIdent(s: *State, name: []const u8) bool {
            if (s.peekKind() != tok.TOK_IDENT) return false;
            if (s.token.payload.ident.has_escape) return false;
            const ident_str = s.lex.atoms.name(s.token.payload.ident.atom) orelse return false;
            return std.mem.eql(u8, ident_str, name);
        }

        fn isParameterModifier(s: *State) bool {
            const k = s.peekKind();
            if (k == tok.TOK_PUBLIC or k == tok.TOK_PRIVATE or k == tok.TOK_PROTECTED) return true;
            if (k == tok.TOK_IDENT) {
                if (s.token.payload.ident.has_escape) return false;
                const ident_str = s.lex.atoms.name(s.token.payload.ident.atom) orelse return false;
                return std.mem.eql(u8, ident_str, "public") or
                    std.mem.eql(u8, ident_str, "private") or
                    std.mem.eql(u8, ident_str, "protected") or
                    std.mem.eql(u8, ident_str, "readonly");
            }
            return false;
        }

        fn isOfToken(s: *State) bool {
            return s.peekKind() == tok.TOK_OF or s.isIdent("of");
        }

        fn canTreatLetAsForInitializerExpression(s: *State) bool {
            if (s.peekKind() != tok.TOK_LET) return false;
            // qjs calls is_let(s, DECL_MASK_OTHER) for the for-initializer and
            // the for-in/of head (quickjs.c:29164, quickjs.c:28703).
            return canTreatLetAsExpressionStatement(s, DeclMask{ .other = true });
        }

        // ---- emit primitives -------------------------------------------------
        //
        // Direct byte writes into `function.code`. Keep these local until the
        // remaining legacy emitter callers are retired.

        const EmissionSnapshot = struct {
            code_len: usize,
            atom_len: usize,
            source_loc_len: usize,
            label_count: u32,
            last_opcode_pos: i32,
            last_opcode_source_offset: ?u32,
        };

        fn takeEmissionSnapshot(self: *State) EmissionSnapshot {
            return .{
                .code_len = self.currentCodeLen(),
                .atom_len = self.currentAtomOperandLen(),
                .source_loc_len = if (self.emit_to_function_def)
                    self.cur_func().source_loc_slots.len
                else
                    self.function.source_loc_slots.len,
                .label_count = self.currentParserLabelCount(),
                .last_opcode_pos = self.cur_func().last_opcode_pos,
                .last_opcode_source_offset = self.last_opcode_source_offset,
            };
        }

        /// Restore every fallible stream touched by a parser-phase emission.
        /// QuickJS poisons the whole compile after a DynBuf failure; zjs returns
        /// OOM and keeps the runtime usable, so no consumer may observe the
        /// half-published code/atom/source/provenance state that QuickJS never
        /// resumes from.
        fn rollbackEmission(self: *State, snapshot: EmissionSnapshot) void {
            if (self.emit_to_function_def) {
                const fd = self.cur_func();
                fd.truncateAtomOperands(snapshot.atom_len);
                fd.truncateSourceLocs(snapshot.source_loc_len);
                fd.truncateByteCode(snapshot.code_len);
            } else {
                self.function.truncateAtomOperands(snapshot.atom_len);
                self.function.truncateSourceLocs(snapshot.source_loc_len);
                self.function.truncateCode(snapshot.code_len);
            }
            self.setParserLabelCount(snapshot.label_count);
            self.cur_func().last_opcode_pos = snapshot.last_opcode_pos;
            self.last_opcode_source_offset = snapshot.last_opcode_source_offset;
        }

        fn commitLastOpcode(self: *State, opcode_pos: usize) void {
            self.cur_func().last_opcode_pos = @intCast(opcode_pos);
        }

        fn currentParserLabelCount(self: *State) u32 {
            if (!self.emit_to_function_def) return self.root_parser_label_count;
            std.debug.assert(self.cur_func().label_count >= 0);
            return @intCast(self.cur_func().label_count);
        }

        fn setParserLabelCount(self: *State, count: u32) void {
            if (self.emit_to_function_def) {
                self.cur_func().label_count = @intCast(count);
            } else {
                self.root_parser_label_count = count;
            }
        }

        fn emitOpcodeBytesNoSource(self: *State, bytes: []const u8) Error!void {
            const snapshot = self.takeEmissionSnapshot();
            errdefer self.rollbackEmission(snapshot);
            const opcode_pos = self.currentCodeLen();
            try self.appendBytesNoSource(bytes);
            self.commitLastOpcode(opcode_pos);
        }

        /// Prepare every growable buffer used by a source-less emitter
        /// transaction without changing its visible state. QuickJS relies on
        /// a poisoned DynBuf after OOM; zjs must remain usable, so lvalue
        /// detach/owner transfer only begins after these claims succeed.
        fn reserveEmission(self: *State, code_bytes: usize, atom_operands: usize) Error!void {
            if (self.emit_to_function_def) {
                try self.cur_func().reserveByteCode(code_bytes);
                try self.cur_func().reserveAtomOperands(atom_operands);
            } else {
                try self.function.reserveCode(code_bytes);
                try self.function.reserveAtomOperands(atom_operands);
            }
        }

        fn appendBytesNoSourceAssumeCapacity(self: *State, bytes: []const u8) void {
            if (self.emit_to_function_def) {
                self.cur_func().appendByteCodeAssumeCapacity(bytes);
            } else {
                self.function.appendCodeAssumeCapacity(bytes);
            }
        }

        fn appendAtomOperandAssumeCapacity(self: *State, atom_id: Atom) void {
            if (self.emit_to_function_def) {
                self.cur_func().appendAtomOperandAssumeCapacity(atom_id);
            } else {
                self.function.retainAtomOperandAssumeCapacity(atom_id);
            }
        }

        fn appendOwnedAtomOperandAssumeCapacity(self: *State, atom_id: Atom) void {
            if (self.emit_to_function_def) {
                self.cur_func().appendAtomOperandOwnedAssumeCapacity(atom_id);
            } else {
                self.function.retainAtomOperandOwnedAssumeCapacity(atom_id);
            }
        }

        fn emitOpcodeBytesNoSourceAssumeCapacity(self: *State, bytes: []const u8) void {
            const opcode_pos = self.currentCodeLen();
            self.appendBytesNoSourceAssumeCapacity(bytes);
            self.commitLastOpcode(opcode_pos);
        }

        fn markDirectEvalCall(self: *State) Error!void {
            const fd = self.cur_func();
            fd.has_eval_call = true;
        }

        fn emitOp(self: *State, op_id: u8) Error!void {
            try self.appendBytes(&[_]u8{op_id});
        }

        fn emitOpAt(self: *State, op_id: u8, line_num: u32, col_num: u32) Error!void {
            try self.appendBytesAt(&[_]u8{op_id}, line_num, col_num);
        }

        fn emitOpNoSource(self: *State, op_id: u8) Error!void {
            try self.emitOpcodeBytesNoSource(&[_]u8{op_id});
        }

        fn emitOpU8(self: *State, op_id: u8, val: u8) Error!void {
            try self.appendBytes(&[_]u8{ op_id, val });
        }

        fn emitOpU16(self: *State, op_id: u8, val: u16) Error!void {
            var bytes: [3]u8 = undefined;
            bytes[0] = op_id;
            std.mem.writeInt(u16, bytes[1..3], val, .little);
            try self.appendBytes(&bytes);
        }

        fn emitOpU16NoSource(self: *State, op_id: u8, val: u16) Error!void {
            var bytes: [3]u8 = undefined;
            bytes[0] = op_id;
            std.mem.writeInt(u16, bytes[1..3], val, .little);
            try self.emitOpcodeBytesNoSource(&bytes);
        }

        fn emitOpU16At(self: *State, op_id: u8, val: u16, line_num: u32, col_num: u32) Error!void {
            var bytes: [3]u8 = undefined;
            bytes[0] = op_id;
            std.mem.writeInt(u16, bytes[1..3], val, .little);
            try self.appendBytesAt(&bytes, line_num, col_num);
        }

        fn emitOpI32(self: *State, op_id: u8, val: i32) Error!void {
            var bytes: [5]u8 = undefined;
            bytes[0] = op_id;
            std.mem.writeInt(i32, bytes[1..5], val, .little);
            try self.appendBytes(&bytes);
        }

        fn emitOpU32(self: *State, op_id: u8, val: u32) Error!void {
            var bytes: [5]u8 = undefined;
            bytes[0] = op_id;
            std.mem.writeInt(u32, bytes[1..5], val, .little);
            try self.appendBytes(&bytes);
        }

        fn emitOpU32NoSource(self: *State, op_id: u8, val: u32) Error!void {
            var bytes: [5]u8 = undefined;
            bytes[0] = op_id;
            std.mem.writeInt(u32, bytes[1..5], val, .little);
            try self.emitOpcodeBytesNoSource(&bytes);
        }

        fn emitOpU32At(self: *State, op_id: u8, val: u32, line_num: u32, col_num: u32) Error!void {
            var bytes: [5]u8 = undefined;
            bytes[0] = op_id;
            std.mem.writeInt(u32, bytes[1..5], val, .little);
            try self.appendBytesAt(&bytes, line_num, col_num);
        }

        fn sourceOffsetForLineCol(self: *const State, line_num: u32, col_num: u32) u32 {
            if (line_num <= 1 and col_num <= 1) return 0;
            var line: u32 = 1;
            var col: u32 = 1;
            for (self.lex.source, 0..) |byte, index| {
                if (line == line_num and col == col_num) return @intCast(index);
                if (byte == '\n') {
                    line += 1;
                    col = 1;
                } else {
                    col += 1;
                }
            }
            return @intCast(self.lex.source.len);
        }

        fn emitSourcePos(self: *State, line_num: u32, col_num: u32) Error!void {
            if (!self.emit_phase1_temp) return;
            const source_offset = self.sourceOffsetForLineCol(line_num, col_num);
            if (self.last_opcode_source_offset) |last| {
                if (last == source_offset) return;
            }
            var bytes: [5]u8 = undefined;
            bytes[0] = opcode.op.line_num;
            std.mem.writeInt(u32, bytes[1..5], source_offset, .little);
            try self.appendBytesNoSource(&bytes);
            self.last_opcode_source_offset = source_offset;
        }

        fn currentSourcePosition(self: *State) SourcePosition {
            if (self.opcode_source_override) |source| return source;
            const loc_line = if (self.last_token_line_num >= self.token.line_num) self.last_token_line_num else self.token.line_num;
            const loc_col = if (loc_line == self.last_token_line_num) self.last_token_col_num else self.token.col_num;
            return .{ .line_num = loc_line, .col_num = loc_col };
        }

        fn emitFClosure8(self: *State, idx: u8) Error!void {
            // Phase-1 temporary opcodes overlap the short-opcode range that
            // contains fclosure8. Keep parser output in the wide form until
            // resolve_labels shortens it after temp opcodes have been erased.
            if (self.emit_phase1_temp) {
                try self.emitOpU32(opcode.op.fclosure, idx);
                return;
            }
            try self.emitOpU8(opcode.op.fclosure8, idx);
        }

        fn emitFClosure(self: *State, idx: u32) Error!void {
            if (idx < 256) {
                try self.emitFClosure8(@intCast(idx));
            } else {
                try self.emitOpU32(opcode.op.fclosure, idx);
            }
        }

        fn emitCloseLoc(self: *State, idx: u16) Error!void {
            try self.emitOpU16NoSource(opcode.op.close_loc, idx);
        }

        /// Mirror the `OP_enter_scope` emission of QuickJS `push_scope`
        /// (`quickjs.c:23486`). `resolve_variables` lowers this temp opcode
        /// to a per-scope binding refresh (TDZ re-arm + captured-slot
        /// detach, see `enterScopeRefreshSize`) so block-scoped bindings
        /// are fresh on every scope entry — the per-iteration semantics of
        /// lexicals declared inside loop bodies.
        ///
        fn emitEnterScope(self: *State) Error!void {
            if (!self.emit_phase1_temp) return;
            if (self.scope_level < 0) return;
            try self.emitOpU16NoSource(opcode.op.enter_scope, @intCast(self.scope_level));
        }

        fn emitLeaveScope(self: *State, scope: i32) Error!void {
            if (!self.emit_phase1_temp) return;
            if (scope < 0) return;
            try self.emitOpU16NoSource(opcode.op.leave_scope, @intCast(scope));
        }

        /// Emit the same lexical-exit chain as QuickJS `close_scopes` without
        /// changing parser scope state. `scope_stop` remains active.
        fn closeScopes(self: *State, start_scope: i32, scope_stop: i32) Error!void {
            var scope = start_scope;
            while (scope > scope_stop) {
                if (@as(usize, @intCast(scope)) >= self.cur_func().scopes.len) return Error.UnexpectedToken;
                try self.emitLeaveScope(scope);
                scope = self.cur_func().scopes[@intCast(scope)].parent;
            }
        }

        fn emitOpAtom(self: *State, op_id: u8, atom_id: Atom) Error!void {
            const snapshot = self.takeEmissionSnapshot();
            errdefer self.rollbackEmission(snapshot);
            if (self.emit_to_function_def) {
                try self.cur_func().appendAtomOperand(atom_id);
            } else {
                try self.function.retainAtomOperand(atom_id);
            }
            try self.emitOpU32(op_id, atom_id);
        }

        fn emitOpAtomNoSource(self: *State, op_id: u8, atom_id: Atom) Error!void {
            const snapshot = self.takeEmissionSnapshot();
            errdefer self.rollbackEmission(snapshot);
            if (self.emit_to_function_def) {
                try self.cur_func().appendAtomOperand(atom_id);
            } else {
                try self.function.retainAtomOperand(atom_id);
            }
            var bytes: [5]u8 = undefined;
            bytes[0] = op_id;
            std.mem.writeInt(u32, bytes[1..5], atom_id, .little);
            try self.emitOpcodeBytesNoSource(&bytes);
        }

        fn appendOwnedAtomOperand(self: *State, atom_id: Atom) Error!void {
            if (self.emit_to_function_def) {
                try self.cur_func().appendAtomOperandOwned(atom_id);
            } else {
                try self.function.retainAtomOperandOwned(atom_id);
            }
        }

        fn takeLastAtomOperand(self: *State) Error!Atom {
            if (self.currentAtomOperandLen() == 0) return Error.UnexpectedToken;
            return if (self.emit_to_function_def)
                self.cur_func().takeLastAtomOperand()
            else
                self.function.takeLastAtomOperand();
        }

        // ---- Temporary scope opcode helpers ----
        // These emit scope_* opcodes that will be lowered by resolve_variables.

        fn emitOpAtomU16(self: *State, op_id: u8, atom_id: Atom, u16_val: u16) Error!void {
            const snapshot = self.takeEmissionSnapshot();
            errdefer self.rollbackEmission(snapshot);
            if (self.emit_to_function_def) {
                try self.cur_func().appendAtomOperand(atom_id);
            } else {
                try self.function.retainAtomOperand(atom_id);
            }
            var bytes: [7]u8 = undefined;
            bytes[0] = op_id;
            std.mem.writeInt(u32, bytes[1..5], atom_id, .little);
            std.mem.writeInt(u16, bytes[5..7], u16_val, .little);
            try self.appendBytes(&bytes);
        }

        fn emitOpAtomU16NoSource(self: *State, op_id: u8, atom_id: Atom, u16_val: u16) Error!void {
            const snapshot = self.takeEmissionSnapshot();
            errdefer self.rollbackEmission(snapshot);
            if (self.emit_to_function_def) {
                try self.cur_func().appendAtomOperand(atom_id);
            } else {
                try self.function.retainAtomOperand(atom_id);
            }
            var bytes: [7]u8 = undefined;
            bytes[0] = op_id;
            std.mem.writeInt(u32, bytes[1..5], atom_id, .little);
            std.mem.writeInt(u16, bytes[5..7], u16_val, .little);
            try self.emitOpcodeBytesNoSource(&bytes);
        }

        fn emitOpAtomU8(self: *State, op_id: u8, atom_id: Atom, u8_val: u8) Error!void {
            const snapshot = self.takeEmissionSnapshot();
            errdefer self.rollbackEmission(snapshot);
            if (self.emit_to_function_def) {
                try self.cur_func().appendAtomOperand(atom_id);
            } else {
                try self.function.retainAtomOperand(atom_id);
            }
            var bytes: [6]u8 = undefined;
            bytes[0] = op_id;
            std.mem.writeInt(u32, bytes[1..5], atom_id, .little);
            bytes[5] = u8_val;
            try self.appendBytes(&bytes);
        }

        fn emitOpAtomLabelU8(self: *State, op_id: u8, atom_id: Atom, label: u32, u8_val: u8) Error!usize {
            const snapshot = self.takeEmissionSnapshot();
            errdefer self.rollbackEmission(snapshot);
            if (self.emit_to_function_def) {
                try self.cur_func().appendAtomOperand(atom_id);
            } else {
                try self.function.retainAtomOperand(atom_id);
            }
            var bytes: [10]u8 = undefined;
            bytes[0] = op_id;
            std.mem.writeInt(u32, bytes[1..5], atom_id, .little);
            std.mem.writeInt(u32, bytes[5..9], label, .little);
            bytes[9] = u8_val;
            const loc = self.currentSourcePosition();
            _ = try self.emitSourcePosAndLoc(loc.line_num, loc.col_num);
            const label_offset = self.currentCodeLen() + 5;
            try self.emitOpcodeBytesNoSource(&bytes);
            return label_offset;
        }

        fn emitScopeGetVar(self: *State, atom_id: Atom) Error!void {
            try self.ensureClosureVar(atom_id);
            if (self.emit_phase1_temp) {
                try self.emitOpAtomU16(opcode.op.scope_get_var, atom_id, @intCast(self.scope_level));
            } else {
                try self.emitGlobalVarOp(opcode.op.get_var, atom_id);
            }
        }

        fn emitScopeGetRef(self: *State, atom_id: Atom) Error!void {
            try self.ensureClosureVar(atom_id);
            if (self.emit_phase1_temp) {
                try self.emitOpAtomU16(opcode.op.scope_get_ref, atom_id, @intCast(self.scope_level));
            } else {
                try self.emitGlobalVarOp(opcode.op.get_var, atom_id);
            }
        }

        fn emitScopeGetVarCheckThis(self: *State, atom_id: Atom) Error!void {
            try self.ensureClosureVar(atom_id);
            if (self.emit_phase1_temp) {
                try self.emitOpAtomU16(opcode.op.scope_get_var_checkthis, atom_id, @intCast(self.scope_level));
            } else {
                try self.emitGlobalVarOp(opcode.op.get_var, atom_id);
            }
        }

        fn emitScopePutVar(self: *State, atom_id: Atom) Error!void {
            try self.ensureClosureVar(atom_id);
            if (self.emit_phase1_temp) {
                try self.emitOpAtomU16(opcode.op.scope_put_var, atom_id, @intCast(self.scope_level));
            } else {
                try self.emitGlobalVarOp(opcode.op.put_var, atom_id);
            }
        }

        fn emitScopePutVarNoSource(self: *State, atom_id: Atom) Error!void {
            try self.ensureClosureVar(atom_id);
            if (self.emit_phase1_temp) {
                try self.emitOpAtomU16NoSource(opcode.op.scope_put_var, atom_id, @intCast(self.scope_level));
            } else {
                try self.emitGlobalVarOpNoSource(opcode.op.put_var, atom_id);
            }
        }

        fn emitScopeDeleteVar(self: *State, atom_id: Atom) Error!void {
            if (self.emit_phase1_temp) {
                try self.emitOpAtomU16(opcode.op.scope_delete_var, atom_id, @intCast(self.scope_level));
            } else {
                try self.emitOpAtom(opcode.op.delete_var, atom_id);
            }
        }

        fn emitScopeGetVarUndef(self: *State, atom_id: Atom) Error!void {
            try self.ensureClosureVar(atom_id);
            if (self.emit_phase1_temp) {
                try self.emitOpAtomU16(opcode.op.scope_get_var_undef, atom_id, @intCast(self.scope_level));
            } else {
                try self.emitGlobalVarOp(opcode.op.get_var_undef, atom_id);
            }
        }

        /// Emit `scope_put_var_init` for `let` / `const` initialisers.
        /// Mirrors `quickjs.c:282` (scope init form). The pipeline
        /// lowers this to `put_loc` when the var resolves locally, or
        /// to `put_var_init` when it's a top-level lexical global.
        fn emitScopePutVarInit(self: *State, atom_id: Atom) Error!void {
            try self.ensureClosureVar(atom_id);
            if (self.emit_phase1_temp) {
                try self.emitOpAtomU16(opcode.op.scope_put_var_init, atom_id, @intCast(self.scope_level));
            } else {
                try self.emitGlobalVarOp(opcode.op.put_var_init, atom_id);
            }
        }

        fn emitScopePutVarInitNoSource(self: *State, atom_id: Atom) Error!void {
            try self.ensureClosureVar(atom_id);
            if (self.emit_phase1_temp) {
                try self.emitOpAtomU16NoSource(opcode.op.scope_put_var_init, atom_id, @intCast(self.scope_level));
            } else {
                try self.emitGlobalVarOpNoSource(opcode.op.put_var_init, atom_id);
            }
        }

        fn emitThisValue(self: *State) Error!void {
            if (self.emit_to_function_def and self.cur_func().has_this_binding) {
                // Explicit `this` reads use the ordinary lexical check and
                // therefore create a TDZ ReferenceError in the constructor's
                // own realm. The caller-realm checkthis opcode is reserved for
                // the synthetic derived-return fallback in emitReturnValue.
                try self.emitScopeGetVar(atom_this);
            } else if (self.emit_to_function_def and
                (self.cur_func().func_type == .arrow or self.cur_func().func_type == .class_static_init))
            {
                // Arrows and class static blocks have no own ThisBinding.
                // Resolve the nearest lexical owner's hidden `this` local
                // through the ordinary closure chain.
                try self.emitScopeGetVar(atom_this);
            } else {
                try self.emitOp(opcode.op.push_this);
            }
        }

        fn ensureImplicitArgumentsLocal(fd: *function_def_mod.FunctionDef) Error!?u16 {
            if (fd.parent == null or fd.func_type == .arrow or fd.func_type == .class_static_init) return null;
            if (fd.arguments_var_idx >= 0) return @intCast(fd.arguments_var_idx);

            const arguments_atom = atom_module.ids.arguments;
            if (fd.findVar(arguments_atom) >= 0 or fd.findArg(arguments_atom) >= 0) return null;

            // qjs add_arguments_var uses add_var: `arguments` is a special
            // fallback after ordinary scope/var/argument lookup, not a member
            // of the lexical scope linked list.
            const idx = fd.ensureArgumentsBinding() catch return error.OutOfMemory;
            return @intCast(idx);
        }

        fn isDynamicEnvironmentCaptureAtom(atom_id: Atom) bool {
            return atom_id == atom_module.ids.with_object or
                atom_id == atom_module.ids.var_object or
                atom_id == atom_module.ids.arg_var_object;
        }

        fn ensureClosureVar(self: *State, atom_id: Atom) Error!void {
            if (!self.emit_to_function_def) return;
            // FunctionDef parser output is QuickJS phase-1 name+scope
            // bytecode. Binding discovery belongs to the final topology pass,
            // after declarations and eval pseudo locals have been staged.
            if (self.emit_phase1_temp) return;
            const current = self.cur_func();
            // `arguments` is a binding of the current non-arrow function, so
            // it must be materialized before looking for a binding in any
            // parent. This mirrors QuickJS resolve_scope_var(), where the
            // current function's arguments pseudo-variable wins over outer
            // lexical declarations with the same name.
            if (atom_id == atom_module.ids.arguments) {
                // An explicit `arguments` parameter (including a binding in a
                // destructuring parameter) is the current binding. Do not
                // replace it with the implicit arguments-object pseudo local
                // merely because it is referenced by a later initializer.
                // A body-only `var arguments` is not visible from the separate
                // parameter environment and therefore deliberately does not
                // satisfy this guard.
                if (!hasVisibleCurrentBinding(current, atom_id, self.scope_level)) {
                    const needs_parameter_arguments_cell =
                        self.in_parameter_initializer and
                        current.has_parameter_expressions and
                        current.func_type != .arrow and
                        current.func_type != .class_static_init and
                        (current.arguments_arg_idx >= 0 or
                            (current.arguments_var_idx < 0 and current.findVar(atom_id) >= 0));
                    if (needs_parameter_arguments_cell) {
                        try ensureParameterArgumentsLocals(current);
                    } else {
                        _ = try State.ensureImplicitArgumentsLocal(current);
                    }
                }
            }
            if (current.findVar(atom_id) >= 0 or current.findArg(atom_id) >= 0) {
                // A flat name hit resolves locally with no capture needed. But
                // zjs findVar is flat while qjs find_var is scope_level==0
                // only: a block-scoped shadow that is *not* visible from this
                // reference's scope chain must still materialize the lazy
                // self-binding (`function rec(){ { let rec; } return rec; }`
                // resolves to the self-binding — qjs falls through to
                // add_func_var, quickjs.c:32975-32978).
                if (current.is_named_func_expr and atom_id == current.func_name and
                    !hasVisibleCurrentBinding(current, atom_id, self.scope_level))
                {
                    _ = try current.ensureFuncExprSelfBinding();
                }
                return;
            }
            for (current.closure_var) |cv| {
                if (cv.var_name == atom_id) return;
            }
            // Falling-through reference to the function expression's own
            // name: materialize the self-binding on demand and resolve to it
            // (resolve_scope_var quickjs.c:32975-32978). Sits after the
            // `arguments` block and the local/arg/closure early-returns —
            // the same precedence the eager var had.
            if (current.is_named_func_expr and atom_id == current.func_name) {
                _ = try current.ensureFuncExprSelfBinding();
                return;
            }
            if (try self.ensureArrowSpecialCapture(atom_id)) return;

            // Phase-1 scope bytecode is resolved only after every child and
            // declaration is complete. Do not invent ordinary closure rows
            // while parsing: the post-order resolver replays the exact
            // resolve_scope_var/get_closure_var event from this opcode. The
            // non-temp legacy emitter still needs its immediate indexed row.
            if (self.emit_phase1_temp) return;

            var parent_index = self.cur_func_stack.len;
            var visible_scope_level = current.parent_scope_level;
            var parameter_environment_only = current.parent_parameter_environment_only;
            while (parent_index > 0) {
                parent_index -= 1;
                const parent = self.funcAtVirtualIndex(parent_index);
                if (try self.findVisibleParentVarCapturingWith(parent_index, parent, atom_id, visible_scope_level)) |parent_var| {
                    try self.ensureClosureChain(parent_index, .{
                        .closure_type = .local,
                        .is_lexical = parent.vars[@intCast(parent_var)].is_lexical,
                        .is_const = parent.vars[@intCast(parent_var)].is_const,
                        .var_kind = parent.vars[@intCast(parent_var)].var_kind,
                        .var_idx = @intCast(parent_var),
                        .var_name = atom_id,
                    });
                    return;
                }
                const parent_arg = parent.findArg(atom_id);
                if (parent_arg >= 0) {
                    try self.ensureClosureChain(parent_index, .{
                        .closure_type = .arg,
                        .is_lexical = false,
                        .is_const = false,
                        .var_kind = .normal,
                        .var_idx = @intCast(parent_arg),
                        .var_name = atom_id,
                    });
                    return;
                }
                if (atom_id == atom_module.ids.arguments) {
                    const needs_parameter_arguments_cell =
                        parameter_environment_only and
                        parent.has_parameter_expressions and
                        parent.func_type != .arrow and
                        parent.func_type != .class_static_init and
                        (parent.arguments_arg_idx >= 0 or
                            (parent.arguments_var_idx < 0 and parent.findVar(atom_id) >= 0));
                    if (needs_parameter_arguments_cell) {
                        try ensureParameterArgumentsLocals(parent);
                        try self.ensureClosureChain(parent_index, .{
                            .closure_type = .local,
                            .is_lexical = true,
                            .is_const = false,
                            .var_kind = .normal,
                            .var_idx = @intCast(parent.arguments_arg_idx),
                            .var_name = atom_id,
                        });
                        return;
                    }
                    if (try State.ensureImplicitArgumentsLocal(parent)) |arguments_var_idx| {
                        try self.ensureClosureChain(parent_index, .{
                            .closure_type = .local,
                            .is_lexical = false,
                            .is_const = false,
                            .var_kind = .normal,
                            .var_idx = arguments_var_idx,
                            .var_name = atom_id,
                        });
                        return;
                    }
                }
                visible_scope_level = parent.parent_scope_level;
                parameter_environment_only = parent.parent_parameter_environment_only;
                for (parent.closure_var, 0..) |cv, idx| {
                    if (isDynamicEnvironmentCaptureAtom(cv.var_name)) {
                        try self.ensureClosureChain(parent_index, .{
                            .closure_type = .ref,
                            .is_lexical = cv.isLexical(),
                            .is_const = cv.isConst(),
                            .var_kind = cv.varKind(),
                            .var_idx = @intCast(idx),
                            .var_name = cv.var_name,
                        });
                        continue;
                    }
                    if (cv.var_name == atom_id) {
                        try self.ensureClosureChain(parent_index, .{
                            .closure_type = .ref,
                            .is_lexical = cv.isLexical(),
                            .is_const = cv.isConst(),
                            .var_kind = cv.varKind(),
                            .var_idx = @intCast(idx),
                            .var_name = atom_id,
                        });
                        return;
                    }
                }
            }
        }

        /// qjs models an arrow's lexical `this` and `new.target` as normal
        /// closure variables created on demand. Materialize the corresponding
        /// hidden local on the nearest non-arrow FunctionDef, then let the same
        /// ref chain used by user bindings carry it through nested arrows.
        fn ensureArrowSpecialCapture(self: *State, atom_id: Atom) Error!bool {
            const current = self.cur_func();
            if (current.func_type != .arrow) return false;
            if (atom_id != atom_this and atom_id != atom_new_target) return false;

            var parent_index = self.cur_func_stack.len;
            while (parent_index > 0) {
                parent_index -= 1;
                const parent = self.funcAtVirtualIndex(parent_index);
                if (parent.func_type == .arrow) continue;

                const var_idx: u16 = if (atom_id == atom_this) blk: {
                    break :blk @intCast(parent.ensureThisBinding() catch return error.OutOfMemory);
                } else blk: {
                    if (!parent.new_target_allowed) return false;
                    break :blk @intCast(parent.ensureNewTargetBinding() catch return error.OutOfMemory);
                };
                const source_var = parent.vars[var_idx];
                try self.ensureClosureChain(parent_index, .{
                    .closure_type = .local,
                    .is_lexical = source_var.is_lexical,
                    .is_const = source_var.is_const,
                    .var_kind = source_var.var_kind,
                    .var_idx = var_idx,
                    .var_name = atom_id,
                });
                return true;
            }
            return false;
        }

        fn findVisibleParentVarCapturingWith(
            self: *State,
            parent_index: usize,
            parent: *function_def_mod.FunctionDef,
            atom_id: Atom,
            visible_scope_level: i32,
        ) Error!?i32 {
            var scope_idx = visible_scope_level;
            while (scope_idx >= 0 and @as(usize, @intCast(scope_idx)) < parent.scopes.len) {
                var var_idx = parent.scopes[@intCast(scope_idx)].first;
                while (var_idx >= 0) {
                    const idx: usize = @intCast(var_idx);
                    if (idx >= parent.vars.len) return Error.UnexpectedToken;
                    const vd = parent.vars[idx];
                    if (vd.scope_level != scope_idx) break;
                    if (vd.var_name == atom_id) return var_idx;
                    if (atom_id != atom_module.ids.with_object and vd.var_name == atom_module.ids.with_object) {
                        try self.ensureClosureChain(parent_index, .{
                            .closure_type = .local,
                            .is_lexical = false,
                            .is_const = false,
                            .var_kind = .normal,
                            .var_idx = @intCast(idx),
                            .var_name = vd.var_name,
                        });
                    }
                    var_idx = vd.scope_next;
                }
                scope_idx = parent.scopes[@intCast(scope_idx)].parent;
            }

            var i: usize = parent.vars.len;
            while (i > 0) {
                i -= 1;
                const vd = parent.vars[i];
                if (vd.var_name == atom_id and vd.var_kind == .function_name) return @intCast(i);
            }
            // Nested falling-through reference to an enclosing named function
            // expression's own name: materialize the parent's self-binding at
            // the exact fallback position the eager var used to occupy
            // (resolve_scope_var enclosing-function leg, quickjs.c:
            // 33151-33155), keeping capture order unchanged.
            if (parent.is_named_func_expr and atom_id == parent.func_name) {
                return try parent.ensureFuncExprSelfBinding();
            }
            return null;
        }

        fn ensureClosureChain(self: *State, source_index: usize, source_value: function_def_mod.ClosureVar.Init) Error!void {
            const source = function_def_mod.ClosureVar.init(source_value);
            const source_fd = self.funcAtVirtualIndex(source_index);
            switch (source.closureType()) {
                .local => if (source.var_idx < source_fd.vars.len) {
                    source_fd.vars[source.var_idx].is_captured = true;
                },
                .arg => if (source.var_idx < source_fd.args.len) {
                    source_fd.args[source.var_idx].is_captured = true;
                },
                else => {},
            }
            var parent_ref_idx: ?u16 = null;
            var child_index = source_index + 1;
            while (child_index <= self.cur_func_stack.len) : (child_index += 1) {
                const child = self.funcAtVirtualIndex(child_index);
                const cv = if (child_index == source_index + 1) source else function_def_mod.ClosureVar.init(.{
                    .closure_type = .ref,
                    .is_lexical = source.isLexical(),
                    .is_const = source.isConst(),
                    .var_kind = source.varKind(),
                    .var_idx = parent_ref_idx orelse return Error.UnexpectedToken,
                    .var_name = source.var_name,
                });
                var existing: ?u16 = null;
                for (child.closure_var, 0..) |candidate, idx| {
                    const same_capture = candidate.closureType() == cv.closureType() and
                        candidate.var_idx == cv.var_idx;
                    // qjs get_closure_var uses binding identity only. Same-name
                    // lexicals/args from distinct environments must remain
                    // separate rows so lookup-first-match can model shadowing.
                    if (same_capture) {
                        existing = @intCast(idx);
                        break;
                    }
                }
                if (existing) |idx| {
                    parent_ref_idx = idx;
                    continue;
                }
                parent_ref_idx = @intCast(try child.addClosureVar(cv.toInit()));
            }
        }

        fn findClosureVarIndex(fd: *const function_def_mod.FunctionDef, atom_id: Atom) ?u16 {
            for (fd.closure_var, 0..) |cv, idx| {
                if (cv.var_name == atom_id) return @intCast(idx);
            }
            return null;
        }

        fn findGlobalClosureVarIndex(fd: *const function_def_mod.FunctionDef, atom_id: Atom) ?u16 {
            for (fd.closure_var, 0..) |cv, idx| {
                if (cv.var_name != atom_id) continue;
                switch (cv.closureType()) {
                    .global, .global_ref, .global_decl, .module_decl, .module_import => return @intCast(idx),
                    else => {},
                }
            }
            return null;
        }

        fn ensureGlobalClosureVarIndex(self: *State, atom_id: Atom) Error!u16 {
            const fd = self.cur_func();
            if (findGlobalClosureVarIndex(fd, atom_id)) |idx| return idx;
            const idx = fd.addClosureVar(.{
                .closure_type = .global,
                .is_lexical = false,
                .is_const = false,
                .var_kind = .normal,
                .var_idx = 0,
                .var_name = atom_id,
            }) catch return Error.OutOfMemory;
            if (idx < 0 or idx > std.math.maxInt(u16)) return Error.UnexpectedToken;
            return @intCast(idx);
        }

        fn emitGlobalVarOp(self: *State, op_id: u8, atom_id: Atom) Error!void {
            const ref_idx = try self.ensureGlobalClosureVarIndex(atom_id);
            try self.emitOpU16(op_id, ref_idx);
        }

        fn emitGlobalVarOpNoSource(self: *State, op_id: u8, atom_id: Atom) Error!void {
            const ref_idx = try self.ensureGlobalClosureVarIndex(atom_id);
            try self.emitOpU16NoSource(op_id, ref_idx);
        }

        fn scopeChainContains(fd: *const function_def_mod.FunctionDef, start_scope: i32, target_scope: i32) bool {
            var scope_idx = start_scope;
            while (scope_idx >= 0 and @as(usize, @intCast(scope_idx)) < fd.scopes.len) {
                if (scope_idx == target_scope) return true;
                scope_idx = fd.scopes[@intCast(scope_idx)].parent;
            }
            return false;
        }

        fn hasVisibleCurrentBinding(
            fd: *const function_def_mod.FunctionDef,
            atom_id: Atom,
            scope_level: i32,
        ) bool {
            if (fd.findArg(atom_id) >= 0) return true;
            var index = fd.vars.len;
            while (index > 0) {
                index -= 1;
                const vd = fd.vars[index];
                if (vd.var_name == atom_id and scopeChainContains(fd, scope_level, vd.scope_level)) return true;
            }
            return false;
        }

        fn emitPushConst(self: *State, value: JSValue) Error!void {
            const snapshot = self.takeEmissionSnapshot();
            errdefer self.rollbackEmission(snapshot);
            try self.emitOpU32(opcode.op.push_const, 0);
            const opcode_pos: usize = @intCast(self.cur_func().last_opcode_pos);
            const idx = if (self.emit_to_function_def or self.top_level_functions_as_children)
                try self.cur_func().appendCpool(value)
            else
                try self.function.addConstant(value);
            std.mem.writeInt(u32, self.currentCode()[opcode_pos + 1 ..][0..4], idx, .little);
        }

        fn emitPushConstOwned(self: *State, value: JSValue) Error!void {
            var value_owned = true;
            errdefer if (value_owned) value.free(self.runtime.?);
            const snapshot = self.takeEmissionSnapshot();
            errdefer self.rollbackEmission(snapshot);
            try self.emitOpU32(opcode.op.push_const, 0);
            const opcode_pos: usize = @intCast(self.cur_func().last_opcode_pos);
            const idx = if (self.emit_to_function_def or self.top_level_functions_as_children)
                try self.cur_func().appendCpoolOwned(value)
            else
                try self.function.constants.appendOwned(value);
            value_owned = false;
            std.mem.writeInt(u32, self.currentCode()[opcode_pos + 1 ..][0..4], idx, .little);
        }

        fn emitBigIntLiteral(self: *State, text: []const u8, negate: bool) Error!void {
            if (parseBigIntI32(text, negate)) |small| {
                try self.emitOpI32(opcode.op.push_bigint_i32, small);
                return;
            }

            const parse_text = if (std.mem.indexOfScalar(u8, text, '_')) |_| blk: {
                var normalized = std.ArrayList(u8).empty;
                errdefer normalized.deinit(self.function.memory.allocator);
                for (text) |ch| {
                    if (ch != '_') normalized.append(self.function.memory.allocator, ch) catch return Error.OutOfMemory;
                }
                break :blk normalized.toOwnedSlice(self.function.memory.allocator) catch return Error.OutOfMemory;
            } else text;
            defer if (parse_text.ptr != text.ptr) self.function.memory.allocator.free(parse_text);

            var parsed = libs_bignum.parseAutoAlloc(self.function.memory.persistent_allocator, parse_text) catch return Error.InvalidNumberLiteral;
            errdefer parsed.deinit();
            if (negate and !parsed.isZero()) parsed.negative = !parsed.negative;

            const big = self.function.memory.create(core_bigint.BigInt) catch return Error.OutOfMemory;
            big.* = .{
                .header = .{},
                .value = parsed,
            };
            parsed = .{ .allocator = self.function.memory.persistent_allocator };
            try self.emitPushConstOwned(big.valueRef());
        }

        fn appendBytes(self: *State, bytes: []const u8) Error!void {
            const loc = self.currentSourcePosition();
            try self.appendBytesAt(bytes, loc.line_num, loc.col_num);
        }

        fn invalidateLastOpcode(self: *State) void {
            self.cur_func().last_opcode_pos = -1;
        }

        fn appendBytesNoSource(self: *State, bytes: []const u8) Error!void {
            if (self.emit_to_function_def) {
                try self.cur_func().appendByteCode(bytes);
            } else {
                try self.function.appendCode(bytes);
            }
        }

        fn emitSourcePosAndLoc(self: *State, line_num: u32, col_num: u32) Error!usize {
            const snapshot = self.takeEmissionSnapshot();
            errdefer self.rollbackEmission(snapshot);
            try self.emitSourcePos(line_num, col_num);
            if (self.emit_to_function_def) {
                const pc: u32 = @intCast(self.cur_func().byte_code.len);
                try self.cur_func().appendSourceLoc(pc, @intCast(line_num), @intCast(col_num));
                return pc;
            } else {
                const pc: u32 = @intCast(self.function.code.len);
                try self.function.appendSourceLoc(pc, @intCast(line_num), @intCast(col_num));
                return pc;
            }
        }

        fn appendBytesAt(self: *State, bytes: []const u8, line_num: u32, col_num: u32) Error!void {
            const snapshot = self.takeEmissionSnapshot();
            errdefer self.rollbackEmission(snapshot);
            _ = try self.emitSourcePosAndLoc(line_num, col_num);
            const opcode_pos = self.currentCodeLen();
            try self.appendBytesNoSource(bytes);
            self.commitLastOpcode(opcode_pos);
        }

        fn currentCodeLen(self: *State) usize {
            if (self.emit_to_function_def) return self.cur_func().byte_code.len;
            return self.function.code.len;
        }

        fn currentCode(self: *State) []u8 {
            if (self.emit_to_function_def) return self.cur_func().byte_code;
            return self.function.code;
        }

        fn currentAtomOperands(self: *State) []Atom {
            if (self.emit_to_function_def) return self.cur_func().atom_operands;
            return self.function.atom_operands;
        }

        fn appendMovedCodeWithAtoms(self: *State, code: []u8, atoms: []const Atom, old_base: usize) Error!void {
            const new_base = self.currentCodeLen();

            // A moved-bytecode splice is a transaction over three pieces of
            // state: the detached input, the destination code, and the
            // destination atom stream.  Validate the complete input and claim
            // both destination buffers before rebasing a single label.  Once
            // rebasing begins, every remaining operation is allocation-free.
            try validateMovedBytecodeLabels(code, atoms, old_base, new_base);
            try self.reserveEmission(code.len, atoms.len);
            rebaseMovedBytecodeLabelsAssumeValidated(code, atoms, old_base, new_base);
            self.appendBytesNoSourceAssumeCapacity(code);
            for (atoms) |atom_id| self.appendAtomOperandAssumeCapacity(atom_id);
            // A splice is a control-flow construction boundary.  QuickJS
            // never lets get_lvalue reach through one to an opcode emitted in
            // a detached buffer.
            self.invalidateLastOpcode();
        }

        /// Drop bytes appended after `target_len`. Used by parseAssignExpr2 /
        /// parsePostfixExpr to roll back a speculative LHS emission once an
        /// assignment / update operator is recognised. Atom operand counts are
        /// rolled back via `truncateAtomOperands`; callers must coordinate the
        /// two so retain/free ref-counts stay balanced.
        ///
        /// The growable-slice scheme keeps the backing buffer alive across
        /// truncation so a re-emission after rollback does not have to
        /// reallocate.
        fn truncateCode(self: *State, target_len: usize) Error!void {
            if (self.cur_func().last_opcode_pos >= 0 and
                @as(usize, @intCast(self.cur_func().last_opcode_pos)) >= target_len)
            {
                self.invalidateLastOpcode();
            }
            if (self.emit_to_function_def) {
                self.cur_func().truncateByteCode(target_len);
            } else {
                self.function.truncateCode(target_len);
            }
        }

        /// Drop atom-operand entries beyond `target_len`, releasing the held
        /// atom refcounts. The retain happens in `emitOpAtom`/`retainAtomOperand`.
        fn truncateAtomOperands(self: *State, target_len: usize) Error!void {
            if (self.emit_to_function_def) {
                self.cur_func().truncateAtomOperands(target_len);
                return;
            }
            self.function.truncateAtomOperands(target_len);
        }

        fn currentAtomOperandLen(self: *State) usize {
            return if (self.emit_to_function_def)
                self.cur_func().atom_operands.len
            else
                self.function.atom_operands.len;
        }
    };

    /// Check if `<ident> =>` is the arrow function head shape.
    /// Saves and restores lexer position so the cached token stays valid.
    fn checkIdentArrowHead(s: *State) bool {
        const saved_pos = s.lex.pos;
        const saved_line = s.lex.line;
        const saved_col = s.lex.col;
        const saved_got_lf = s.lex.got_lf;
        const saved_mark_pos = s.lex.mark_pos;
        const saved_mark_line = s.lex.mark_line;
        const saved_mark_col = s.lex.mark_col;
        defer {
            s.lex.pos = saved_pos;
            s.lex.line = saved_line;
            s.lex.col = saved_col;
            s.lex.got_lf = saved_got_lf;
            s.lex.mark_pos = saved_mark_pos;
            s.lex.mark_line = saved_mark_line;
            s.lex.mark_col = saved_mark_col;
        }

        var peek_token = nextRegexpAwareLookaheadToken(s, s.peekKind()) catch return false;
        defer s.lex.freeToken(&peek_token);
        return peek_token.val == tok.TOK_ARROW;
    }

    fn checkAsyncSingleParamArrowHead(s: *State) bool {
        if (!(s.peekKind() == tok.TOK_IDENT and s.isIdent("async"))) return false;
        if (s.token.payload.ident.has_escape) return false;

        const saved_pos = s.lex.pos;
        const saved_line = s.lex.line;
        const saved_col = s.lex.col;
        const saved_got_lf = s.lex.got_lf;
        const saved_mark_pos = s.lex.mark_pos;
        const saved_mark_line = s.lex.mark_line;
        const saved_mark_col = s.lex.mark_col;

        defer {
            s.lex.pos = saved_pos;
            s.lex.line = saved_line;
            s.lex.col = saved_col;
            s.lex.got_lf = saved_got_lf;
            s.lex.mark_pos = saved_mark_pos;
            s.lex.mark_line = saved_mark_line;
            s.lex.mark_col = saved_mark_col;
        }

        var param_token = nextRegexpAwareLookaheadToken(s, s.peekKind()) catch return false;
        defer s.lex.freeToken(&param_token);
        if (s.lex.gotLineTerminator()) return false;
        if (param_token.val != tok.TOK_IDENT) return false;

        var arrow_token = nextRegexpAwareLookaheadToken(s, param_token.val) catch return false;
        defer s.lex.freeToken(&arrow_token);
        if (s.lex.gotLineTerminator()) return false;
        return arrow_token.val == tok.TOK_ARROW;
    }

    /// Check if contextual `async` is followed by a parenthesized async arrow head:
    /// `async (...) =>`.
    fn checkAsyncParenArrowHead(s: *State) bool {
        if (!(s.peekKind() == tok.TOK_IDENT and s.isIdent("async"))) return false;
        if (s.token.payload.ident.has_escape) return false;

        const saved_pos = s.lex.pos;
        const saved_line = s.lex.line;
        const saved_col = s.lex.col;
        const saved_got_lf = s.lex.got_lf;
        const saved_mark_pos = s.lex.mark_pos;
        const saved_mark_line = s.lex.mark_line;
        const saved_mark_col = s.lex.mark_col;

        defer {
            s.lex.pos = saved_pos;
            s.lex.line = saved_line;
            s.lex.col = saved_col;
            s.lex.got_lf = saved_got_lf;
            s.lex.mark_pos = saved_mark_pos;
            s.lex.mark_line = saved_mark_line;
            s.lex.mark_col = saved_mark_col;
        }

        var previous_token_kind: tok.TokenKind = s.peekKind();
        var open_token = nextRegexpAwareLookaheadToken(s, previous_token_kind) catch return false;
        defer s.lex.freeToken(&open_token);
        if (s.lex.gotLineTerminator()) return false;
        if (open_token.val != '(') return false;
        previous_token_kind = open_token.val;

        var depth: i32 = 1;
        while (depth > 0) {
            var scan_token = nextRegexpAwareLookaheadToken(s, previous_token_kind) catch return false;
            const k = scan_token.val;
            s.lex.freeToken(&scan_token);
            if (k == tok.TOK_EOF) return false;
            if (k == '(') depth += 1;
            if (k == ')') depth -= 1;
            previous_token_kind = k;
            if (depth == 0) break;
        }

        var arrow_token = nextRegexpAwareLookaheadToken(s, previous_token_kind) catch return false;
        defer s.lex.freeToken(&arrow_token);
        return arrow_token.val == tok.TOK_ARROW and !s.lex.gotLineTerminator();
    }

    /// Check if we're at an arrow function head
    /// Mirrors `js_parse_skip_parens_token` in quickjs.c:24194.
    ///
    /// Saves the lexer position, scans forward with scratch tokens, then
    /// restores the lexer so the cached parser token remains valid.
    fn checkArrowHead(s: *State) bool {
        const saved_pos = s.lex.pos;
        const saved_line = s.lex.line;
        const saved_col = s.lex.col;
        const saved_got_lf = s.lex.got_lf;
        const saved_mark_pos = s.lex.mark_pos;
        const saved_mark_line = s.lex.mark_line;
        const saved_mark_col = s.lex.mark_col;
        defer {
            s.lex.pos = saved_pos;
            s.lex.line = saved_line;
            s.lex.col = saved_col;
            s.lex.got_lf = saved_got_lf;
            s.lex.mark_pos = saved_mark_pos;
            s.lex.mark_line = saved_mark_line;
            s.lex.mark_col = saved_mark_col;
        }

        var previous_token_kind: tok.TokenKind = s.peekKind();
        if (s.peekKind() == '(') {
            var depth: i32 = 1;
            while (depth > 0) {
                var scan_token = nextRegexpAwareLookaheadToken(s, previous_token_kind) catch return false;
                const k = scan_token.val;
                s.lex.freeToken(&scan_token);
                if (k == tok.TOK_EOF) return false;
                if (k == '(') depth += 1;
                if (k == ')') depth -= 1;
                previous_token_kind = k;
                if (depth == 0) break;
            }
        } else if (s.peekKind() == tok.TOK_IDENT) {
            var arrow_token = nextRegexpAwareLookaheadToken(s, previous_token_kind) catch return false;
            defer s.lex.freeToken(&arrow_token);
            return arrow_token.val == tok.TOK_ARROW;
        } else {
            return false;
        }

        var arrow_token = nextRegexpAwareLookaheadToken(s, previous_token_kind) catch return false;
        defer s.lex.freeToken(&arrow_token);
        return arrow_token.val == tok.TOK_ARROW;
    }

    fn nextRegexpAwareLookaheadToken(s: *State, previous_token_kind: ?tok.TokenKind) Error!tok.Token {
        var lookahead_token = s.lex.next() catch return Error.UnexpectedToken;
        errdefer s.lex.freeToken(&lookahead_token);
        try rescanLookaheadTokenIfRegexp(s, &lookahead_token, previous_token_kind);
        return lookahead_token;
    }

    fn rescanLookaheadTokenIfRegexp(s: *State, lookahead_token: *tok.Token, previous_token_kind: ?tok.TokenKind) Error!void {
        if (!(lookahead_token.val == @as(tok.TokenKind, @intCast('/')) or lookahead_token.val == tok.TOK_DIV_ASSIGN)) return;
        if (!predeclareSlashStartsRegexp(s, previous_token_kind)) return;

        const slash_offset = s.lex.mark_pos;
        const regexp_token = s.lex.rescanRegexp(slash_offset) catch return Error.UnexpectedToken;
        s.lex.freeToken(lookahead_token);
        lookahead_token.* = regexp_token;
    }

    fn advanceRegexpAwareSpeculativeToken(s: *State, previous_token_kind: *?tok.TokenKind) Error!void {
        try rescanLookaheadTokenIfRegexp(s, &s.token, previous_token_kind.*);
        previous_token_kind.* = s.peekKind();
        try s.advance();
    }

    // =====================================================================
    // Expression parser entry points (mirror QuickJS function names).
    // =====================================================================

    /// `js_parse_expr` (`quickjs.c:27645`).
    pub fn parseExpr(s: *State) Error!void {
        return parseExpr2(s, ParseFlags.default);
    }

    /// `js_parse_expr2` (`quickjs.c:27621`). Comma operator.
    pub fn parseExpr2(s: *State, flags: ParseFlags) Error!void {
        s.features.insert(.expression);
        var operand_flags = flags;
        try parseAssignExpr2(s, operand_flags);
        var saw_comma = false;
        while (s.isPunct(',')) {
            saw_comma = true;
            try s.advance();
            // Discard left-hand side; `a, b` evaluates to b.
            try s.emitOp(opcode.op.drop);
            operand_flags.result_needed = flags.result_needed;
            try parseAssignExpr2(s, operand_flags);
        }
        if (saw_comma) {
            s.last_anonymous_function_expr = false;
            // QuickJS invalidates last_opcode_pos after parsing the rightmost
            // operand of a comma expression: `(a, b)` is a value, never an
            // lvalue merely because `b` ended in a getter.
            s.invalidateLastOpcode();
        }
    }

    /// `js_parse_assign_expr` (`quickjs.c:27615`).
    pub fn parseAssignExpr(s: *State) Error!void {
        return parseAssignExpr2(s, ParseFlags.default);
    }

    /// `js_parse_assign_expr2` (`quickjs.c:27311`). Assignment-target check
    /// and compound-assignment lowering for identifiers, member targets,
    /// destructuring, and arrow cover forms.
    pub fn parseAssignExpr2(s: *State, flags: ParseFlags) Error!void {
        // std.debug.print("parseAssignExpr2: s.token.val={d} ('{c}')\n", .{ s.token.val, @as(u8, @intCast(if (s.token.val >= 0 and s.token.val <= 255) s.token.val else ' ' )) });
        s.assign_expr_depth += 1;
        const current_assign_depth = s.assign_expr_depth;
        if (s.last_coalesce_expr_depth == current_assign_depth) {
            s.last_coalesce_expr_depth = null;
        }
        defer s.assign_expr_depth -= 1;

        if (try parseDestructuringAssignment(s, flags)) return;
        // QuickJS keeps only this source atom for anonymous-function naming;
        // assignment-target identity itself comes exclusively from the last
        // emitted opcode below.
        const direct_lhs_atom: ?Atom = if (isIdentifierLikeToken(s)) identifierLikeAtom(s) else null;

        try parseCondExpr(s, flags);

        const op_kind = s.peekKind();
        const assign_opcode = compoundAssignOpcode(op_kind);
        const logical_assign = logicalAssignKind(op_kind);
        const is_plain_assign = op_kind == @as(tok.TokenKind, @intCast('='));
        if (!is_plain_assign and assign_opcode == null and logical_assign == null) return;
        const operator_source = SourcePosition{
            .line_num = s.token.line_num,
            .col_num = s.token.col_num,
        };

        if (s.last_coalesce_expr_depth == current_assign_depth) {
            return Error.InvalidAssignmentTarget;
        }

        try s.advance(); // consume the assignment operator
        var lvalue = try getLValue(s, !is_plain_assign);
        defer lvalue.deinit(s);

        if (logical_assign) |kind| {
            try emitLogicalAssignLValue(s, flags, &lvalue, kind, direct_lhs_atom);
            return;
        }

        const rhs_flags = ParseFlags{ .in_accepted = flags.in_accepted };
        try parseAssignExpr2(s, rhs_flags);
        if (assign_opcode) |op_byte| {
            const emission_snapshot = s.takeEmissionSnapshot();
            errdefer s.rollbackEmission(emission_snapshot);
            _ = try s.emitSourcePosAndLoc(operator_source.line_num, operator_source.col_num);
            try s.emitOpNoSource(op_byte);
        }

        if (direct_lhs_atom != null and lvalue.owns_name and
            lvalue.name == direct_lhs_atom.? and s.last_anonymous_function_expr)
        {
            try s.emitOpAtom(opcode.op.set_name, lvalue.name);
            s.last_anonymous_function_expr = false;
        } else if (s.last_anonymous_function_expr) {
            s.last_anonymous_function_expr = false;
        }

        try putLValue(s, &lvalue, .keep_top);
    }

    fn parseDestructuringAssignment(s: *State, flags: ParseFlags) Error!bool {
        if (s.peekKind() != @as(tok.TokenKind, @intCast('[')) and
            s.peekKind() != @as(tok.TokenKind, @intCast('{')))
        {
            return false;
        }
        const topology = try scanPatternTopology(s);
        if (topology.following != @as(tok.TokenKind, @intCast('='))) return false;
        _ = try parseDestructuringElement(
            s,
            .assignment,
            false,
            true,
            ParseFlags{ .in_accepted = flags.in_accepted },
        );
        return true;
    }

    const LogicalAssignKind = enum {
        land,
        lor,
        nullish,
    };

    fn emitLogicalAssignLValue(
        s: *State,
        flags: ParseFlags,
        lvalue: *LValue,
        kind: LogicalAssignKind,
        direct_lhs_atom: ?Atom,
    ) Error!void {
        try s.emitOpNoSource(opcode.op.dup);
        if (kind == .nullish) try s.emitOpNoSource(opcode.op.is_undefined_or_null);
        const skip_assign = try emitForwardJumpNoSource(
            s,
            if (kind == .lor) opcode.op.if_true else opcode.op.if_false,
        );
        try s.emitOpNoSource(opcode.op.drop);

        const rhs_flags = ParseFlags{ .in_accepted = flags.in_accepted };
        try parseAssignExpr2(s, rhs_flags);
        if (direct_lhs_atom != null and lvalue.owns_name and
            lvalue.name == direct_lhs_atom.? and s.last_anonymous_function_expr)
        {
            try s.emitOpAtom(opcode.op.set_name, lvalue.name);
            s.last_anonymous_function_expr = false;
        } else if (s.last_anonymous_function_expr) {
            s.last_anonymous_function_expr = false;
        }

        switch (lvalue.depth) {
            0 => try s.emitOpNoSource(opcode.op.dup),
            1 => try s.emitOpNoSource(opcode.op.insert2),
            2 => try s.emitOpNoSource(opcode.op.insert3),
            3 => try s.emitOpNoSource(opcode.op.insert4),
            else => unreachable,
        }
        try putLValue(s, lvalue, .no_keep_depth);
        const end = try emitForwardJumpNoSource(s, opcode.op.goto);

        try patchForwardJump(s, skip_assign);
        var depth = lvalue.depth;
        while (depth != 0) : (depth -= 1) try s.emitOpNoSource(opcode.op.nip);
        try patchForwardJump(s, end);
    }

    const LValueOpcode = enum {
        scope_var,
        field,
        private_field,
        array_element,
        super_value,
        ref_value,
    };

    /// Compile-time ownership descriptor returned by QuickJS-style
    /// get_lvalue. `name` owns the retained atom removed from the getter's
    /// atom-operand stream until putLValue transfers or releases it.
    const LValue = struct {
        opcode: LValueOpcode,
        scope: u16 = 0,
        name: Atom = atom_module.null_atom,
        owns_name: bool = false,
        label_offset: ?usize = null,
        depth: u8,

        fn deinit(self: *LValue, s: *State) void {
            if (self.owns_name) {
                s.function.atoms.free(self.name);
                self.owns_name = false;
            }
        }
    };

    const PutLValueMode = enum {
        no_keep,
        no_keep_depth,
        keep_top,
        keep_second,
        no_keep_bottom,
    };

    fn hasWithScopeFrom(fd_start: *const function_def_mod.FunctionDef, scope_start: i32) bool {
        var fd: ?*const function_def_mod.FunctionDef = fd_start;
        var scope = scope_start;
        while (fd) |current| {
            if (!current.is_strict_mode) {
                var scope_cursor = scope;
                while (scope_cursor >= 0 and @as(usize, @intCast(scope_cursor)) < current.scopes.len) {
                    var var_idx = current.scopes[@intCast(scope_cursor)].first;
                    while (var_idx >= 0 and @as(usize, @intCast(var_idx)) < current.vars.len) {
                        const vd = current.vars[@intCast(var_idx)];
                        if (vd.scope_level != scope_cursor) break;
                        if (vd.var_name == atom_module.ids.with_object) return true;
                        var_idx = vd.scope_next;
                    }
                    scope_cursor = current.scopes[@intCast(scope_cursor)].parent;
                }
            }
            scope = current.parent_scope_level;
            fd = current.parent;
        }
        return false;
    }

    /// Emit the make-ref half of `get_lvalue` after aggregate reservation.
    /// The operand receives a borrowed duplicate; the descriptor keeps the
    /// retained atom removed from the original getter.
    fn emitScopeMakeRefForLValueAssumeCapacity(s: *State, atom_id: Atom, scope: u16) usize {
        std.debug.assert(s.emit_phase1_temp);
        s.appendAtomOperandAssumeCapacity(atom_id);
        var bytes: [11]u8 = undefined;
        bytes[0] = opcode.op.scope_make_ref;
        std.mem.writeInt(u32, bytes[1..5], atom_id, .little);
        std.mem.writeInt(u32, bytes[5..9], 0, .little);
        std.mem.writeInt(u16, bytes[9..11], scope, .little);
        const label_offset = s.currentCodeLen() + 5;
        s.emitOpcodeBytesNoSourceAssumeCapacity(&bytes);
        return label_offset;
    }

    fn emitBorrowedAtomOpAssumeCapacity(s: *State, op_id: u8, atom_id: Atom) void {
        s.appendAtomOperandAssumeCapacity(atom_id);
        var bytes: [5]u8 = undefined;
        bytes[0] = op_id;
        std.mem.writeInt(u32, bytes[1..5], atom_id, .little);
        s.emitOpcodeBytesNoSourceAssumeCapacity(&bytes);
    }

    fn emitBorrowedAtomU16OpAssumeCapacity(s: *State, op_id: u8, atom_id: Atom, scope: u16) void {
        s.appendAtomOperandAssumeCapacity(atom_id);
        var bytes: [7]u8 = undefined;
        bytes[0] = op_id;
        std.mem.writeInt(u32, bytes[1..5], atom_id, .little);
        std.mem.writeInt(u16, bytes[5..7], scope, .little);
        s.emitOpcodeBytesNoSourceAssumeCapacity(&bytes);
    }

    fn emitOpNoSourceAssumeCapacity(s: *State, op_id: u8) void {
        s.emitOpcodeBytesNoSourceAssumeCapacity(&[_]u8{op_id});
    }

    fn reemitLValueGetterAssumeCapacity(s: *State, lvalue: *const LValue) void {
        switch (lvalue.opcode) {
            .scope_var => {
                std.debug.assert(s.emit_phase1_temp);
                emitBorrowedAtomU16OpAssumeCapacity(s, opcode.op.scope_get_var, lvalue.name, lvalue.scope);
            },
            .field => emitBorrowedAtomOpAssumeCapacity(s, opcode.op.get_field2, lvalue.name),
            .private_field => {
                std.debug.assert(s.emit_phase1_temp);
                emitBorrowedAtomU16OpAssumeCapacity(s, opcode.op.scope_get_private_field2, lvalue.name, lvalue.scope);
            },
            .array_element => emitOpNoSourceAssumeCapacity(s, opcode.op.get_array_el3),
            .super_value => {
                emitOpNoSourceAssumeCapacity(s, opcode.op.to_propkey);
                emitOpNoSourceAssumeCapacity(s, opcode.op.dup3);
                emitOpNoSourceAssumeCapacity(s, opcode.op.get_super_value);
            },
            .ref_value => emitOpNoSourceAssumeCapacity(s, opcode.op.get_ref_value),
        }
    }

    /// QuickJS `get_lvalue`: the emitter-maintained last opcode is the sole
    /// target fact. No token, source-tail, or byte-length classifier is used.
    fn getLValue(s: *State, keep: bool) Error!LValue {
        const fd = s.cur_func();
        if (fd.last_opcode_pos < 0) return Error.InvalidAssignmentTarget;
        const pos: usize = @intCast(fd.last_opcode_pos);
        const code = s.currentCode();
        if (pos >= code.len) return Error.InvalidAssignmentTarget;
        const op_id = code[pos];

        var lvalue: LValue = undefined;
        var getter_size: usize = 0;
        var replacement_size: usize = 0;
        switch (op_id) {
            opcode.op.scope_get_var => {
                getter_size = 7;
                if (!s.emit_phase1_temp or pos + getter_size != code.len) return Error.InvalidAssignmentTarget;
                const name: Atom = std.mem.readInt(u32, code[pos + 1 ..][0..4], .little);
                const scope = std.mem.readInt(u16, code[pos + 5 ..][0..2], .little);
                if ((s.is_strict or fd.is_strict_mode) and
                    (atomNameEquals(s, name, "eval") or atomNameEquals(s, name, "arguments")))
                {
                    return Error.InvalidAssignmentTarget;
                }
                if (name == atom_this or name == atom_new_target) return Error.InvalidAssignmentTarget;
                if (s.currentAtomOperandLen() == 0 or s.currentAtomOperands()[s.currentAtomOperandLen() - 1] != name) {
                    return Error.UnexpectedToken;
                }
                // Any topology allocation must happen while the original
                // getter and its atom retain are still fully observable.
                try s.ensureClosureVar(name);
                const with_scope = hasWithScopeFrom(fd, scope);
                replacement_size = if (with_scope) 11 + @as(usize, @intFromBool(keep)) else if (keep) getter_size else 0;
                try s.reserveEmission(replacement_size -| getter_size, 0);

                const owned_name = s.takeLastAtomOperand() catch unreachable;
                s.truncateCode(pos) catch unreachable;
                lvalue = .{
                    .opcode = .scope_var,
                    .scope = scope,
                    .name = owned_name,
                    .owns_name = true,
                    .depth = 0,
                };
                if (with_scope) {
                    lvalue.opcode = .ref_value;
                    lvalue.depth = 2;
                    lvalue.label_offset = emitScopeMakeRefForLValueAssumeCapacity(s, owned_name, scope);
                }
            },
            opcode.op.get_field => {
                getter_size = 5;
                if (pos + getter_size != code.len) return Error.InvalidAssignmentTarget;
                const name: Atom = std.mem.readInt(u32, code[pos + 1 ..][0..4], .little);
                if (s.currentAtomOperandLen() == 0 or s.currentAtomOperands()[s.currentAtomOperandLen() - 1] != name) {
                    return Error.UnexpectedToken;
                }
                replacement_size = if (keep) getter_size else 0;
                try s.reserveEmission(replacement_size -| getter_size, 0);
                const owned_name = s.takeLastAtomOperand() catch unreachable;
                s.truncateCode(pos) catch unreachable;
                lvalue = .{ .opcode = .field, .name = owned_name, .owns_name = true, .depth = 1 };
            },
            opcode.op.scope_get_private_field => {
                getter_size = 7;
                if (!s.emit_phase1_temp or pos + getter_size != code.len) return Error.InvalidAssignmentTarget;
                const name: Atom = std.mem.readInt(u32, code[pos + 1 ..][0..4], .little);
                const scope = std.mem.readInt(u16, code[pos + 5 ..][0..2], .little);
                if (s.currentAtomOperandLen() == 0 or s.currentAtomOperands()[s.currentAtomOperandLen() - 1] != name) {
                    return Error.UnexpectedToken;
                }
                replacement_size = if (keep) getter_size else 0;
                try s.reserveEmission(replacement_size -| getter_size, 0);
                const owned_name = s.takeLastAtomOperand() catch unreachable;
                s.truncateCode(pos) catch unreachable;
                lvalue = .{
                    .opcode = .private_field,
                    .scope = scope,
                    .name = owned_name,
                    .owns_name = true,
                    .depth = 1,
                };
            },
            opcode.op.get_array_el => {
                getter_size = 1;
                if (pos + getter_size != code.len) return Error.InvalidAssignmentTarget;
                replacement_size = @intFromBool(keep);
                try s.reserveEmission(replacement_size -| getter_size, 0);
                s.truncateCode(pos) catch unreachable;
                lvalue = .{ .opcode = .array_element, .depth = 2 };
            },
            opcode.op.get_super_value => {
                getter_size = 1;
                if (pos + getter_size != code.len) return Error.InvalidAssignmentTarget;
                replacement_size = if (keep) 3 else 0;
                try s.reserveEmission(replacement_size -| getter_size, 0);
                s.truncateCode(pos) catch unreachable;
                lvalue = .{ .opcode = .super_value, .depth = 3 };
            },
            else => return Error.InvalidAssignmentTarget,
        }

        if (keep) reemitLValueGetterAssumeCapacity(s, &lvalue);
        return lvalue;
    }

    /// QuickJS `put_lvalue`, including the five stack-preservation modes.
    fn putLValue(s: *State, lvalue: *LValue, mode: PutLValueMode) Error!void {
        const shuffle_op: ?u8 = switch (lvalue.opcode) {
            .scope_var => switch (mode) {
                .keep_top => opcode.op.dup,
                .no_keep, .no_keep_depth, .keep_second, .no_keep_bottom => null,
            },
            .field, .private_field => switch (mode) {
                .no_keep, .no_keep_depth => null,
                .keep_top => opcode.op.insert2,
                .keep_second => opcode.op.perm3,
                .no_keep_bottom => opcode.op.swap,
            },
            .array_element, .ref_value => switch (mode) {
                .no_keep => opcode.op.nop,
                .no_keep_depth => null,
                .keep_top => opcode.op.insert3,
                .keep_second => opcode.op.perm4,
                .no_keep_bottom => opcode.op.rot3l,
            },
            .super_value => switch (mode) {
                .no_keep, .no_keep_depth => null,
                .keep_top => opcode.op.insert4,
                .keep_second => opcode.op.perm5,
                .no_keep_bottom => opcode.op.rot4l,
            },
        };

        const setter_size: usize = switch (lvalue.opcode) {
            .scope_var => 7,
            .field => 5,
            .private_field => 7,
            .array_element, .ref_value, .super_value => 1,
        };
        const atom_count: usize = switch (lvalue.opcode) {
            .scope_var, .field, .private_field => 1,
            .array_element, .ref_value, .super_value => 0,
        };

        switch (lvalue.opcode) {
            .scope_var => if (!s.emit_phase1_temp or !lvalue.owns_name) return Error.InvalidAssignmentTarget,
            .field => if (!lvalue.owns_name) return Error.InvalidAssignmentTarget,
            .private_field => if (!s.emit_phase1_temp or !lvalue.owns_name) return Error.InvalidAssignmentTarget,
            .ref_value => {
                if (!lvalue.owns_name) return Error.InvalidAssignmentTarget;
                const offset = lvalue.label_offset orelse return Error.UnexpectedToken;
                if (offset + 4 > s.currentCodeLen()) return Error.UnexpectedToken;
            },
            .array_element, .super_value => {},
        }

        // After this point the operation is a no-fail commit. Any allocation
        // failure above leaves code, atom stream, provenance and descriptor
        // ownership exactly as they were on entry.
        try s.reserveEmission(setter_size + @as(usize, @intFromBool(shuffle_op != null)), atom_count);

        var ref_label_target: ?u32 = null;
        if (lvalue.opcode == .ref_value) {
            ref_label_target = @intCast(s.currentCodeLen());
            s.function.atoms.free(lvalue.name);
            lvalue.owns_name = false;
            // QuickJS emits a normal label here: it is a provenance boundary,
            // while the absolute target is published after the tail commits.
            s.invalidateLastOpcode();
        }
        if (shuffle_op) |op_id| emitOpNoSourceAssumeCapacity(s, op_id);

        switch (lvalue.opcode) {
            .scope_var => {
                s.appendOwnedAtomOperandAssumeCapacity(lvalue.name);
                lvalue.owns_name = false;
                var bytes: [7]u8 = undefined;
                bytes[0] = opcode.op.scope_put_var;
                std.mem.writeInt(u32, bytes[1..5], lvalue.name, .little);
                std.mem.writeInt(u16, bytes[5..7], lvalue.scope, .little);
                s.emitOpcodeBytesNoSourceAssumeCapacity(&bytes);
            },
            .field => {
                s.appendOwnedAtomOperandAssumeCapacity(lvalue.name);
                lvalue.owns_name = false;
                var bytes: [5]u8 = undefined;
                bytes[0] = opcode.op.put_field;
                std.mem.writeInt(u32, bytes[1..5], lvalue.name, .little);
                s.emitOpcodeBytesNoSourceAssumeCapacity(&bytes);
            },
            .private_field => {
                s.appendOwnedAtomOperandAssumeCapacity(lvalue.name);
                lvalue.owns_name = false;
                var bytes: [7]u8 = undefined;
                bytes[0] = opcode.op.scope_put_private_field;
                std.mem.writeInt(u32, bytes[1..5], lvalue.name, .little);
                std.mem.writeInt(u16, bytes[5..7], lvalue.scope, .little);
                s.emitOpcodeBytesNoSourceAssumeCapacity(&bytes);
            },
            .array_element => emitOpNoSourceAssumeCapacity(s, opcode.op.put_array_el),
            .ref_value => emitOpNoSourceAssumeCapacity(s, opcode.op.put_ref_value),
            .super_value => emitOpNoSourceAssumeCapacity(s, opcode.op.put_super_value),
        }
        if (ref_label_target) |target| {
            var code = s.currentCode();
            const offset = lvalue.label_offset.?;
            std.debug.assert(offset + 4 <= code.len);
            std.mem.writeInt(u32, code[offset..][0..4], target, .little);
        }
    }

    fn isNonLexicalBinding(s: *State, atom_id: Atom) bool {
        for (s.cur_func().closure_var) |cv| {
            if (cv.var_name == atom_id) return !cv.isLexical();
        }
        for (s.cur_func().vars) |v| {
            if (v.var_name == atom_id) return !v.is_lexical;
        }
        return s.emit_to_function_def;
    }

    fn hasKnownBinding(s: *State, atom_id: Atom) bool {
        for (s.cur_func().closure_var) |cv| {
            if (cv.var_name == atom_id) return true;
        }
        // QuickJS keeps top-level declarations in `global_vars` until
        // add_global_variables materializes their closure rows.  Binding
        // queries performed during parsing (notably local-export validation
        // and module redeclaration checks) must therefore consult the
        // declaration table directly rather than relying on parser-created
        // closure placeholders.
        for (s.cur_func().global_vars) |gv| {
            if (gv.var_name == atom_id) return true;
        }
        var scope = s.scope_level;
        while (scope >= 0 and @as(usize, @intCast(scope)) < s.cur_func().scopes.len) {
            var idx = s.cur_func().scopes[@intCast(scope)].first;
            while (idx >= 0 and @as(usize, @intCast(idx)) < s.cur_func().vars.len) {
                const v = s.cur_func().vars[@intCast(idx)];
                if (v.scope_level != scope) break;
                if (v.var_name == atom_id) return true;
                idx = v.scope_next;
            }
            scope = s.cur_func().scopes[@intCast(scope)].parent;
        }
        for (s.cur_func().args) |a| {
            if (a.var_name == atom_id) return true;
        }
        return false;
    }

    fn evalDeleteBindingIsConfigurable(is_lexical: bool, var_kind: function_def_mod.VarKind) bool {
        return !is_lexical or var_kind == .function_decl;
    }

    fn evalClosureBindingIsConfigurable(s: *State, owner_index: usize, cv: function_def_mod.ClosureVar) bool {
        const owner = s.funcAtVirtualIndex(owner_index);
        switch (cv.closureType()) {
            .local => {
                if (owner_index == 0) return s.eval_delete_bindings and evalDeleteBindingIsConfigurable(cv.isLexical(), cv.varKind());
                const parent = s.funcAtVirtualIndex(owner_index - 1);
                if (cv.var_idx >= parent.vars.len) return false;
                const v = parent.vars[cv.var_idx];
                return parent.is_eval and evalDeleteBindingIsConfigurable(v.is_lexical, v.var_kind);
            },
            .ref => {
                if (owner_index == 0) return false;
                const parent = s.funcAtVirtualIndex(owner_index - 1);
                if (cv.var_idx >= parent.closure_var.len) return false;
                return evalClosureBindingIsConfigurable(s, owner_index - 1, parent.closure_var[cv.var_idx]);
            },
            // `.module_decl` belongs in the configurable group: an eval top-level
            // function declaration is recorded as a `.module_decl` (is_lexical,
            // var_kind=.function_decl), and `delete x` on it must return true
            // (configurable) per non-strict eval semantics. Genuine ES-module
            // top-level decls never reach here (modules are always strict, and
            // owner.is_eval is false). Matches ours/322af2f.
            .global_decl, .global, .global_ref, .module_decl => {
                return (owner.is_eval or s.eval_delete_bindings) and evalDeleteBindingIsConfigurable(cv.isLexical(), cv.varKind());
            },
            .arg, .module_import => return false,
        }
    }

    fn hasEvalNonLexicalBinding(s: *State, atom_id: Atom) bool {
        if (!s.eval_delete_bindings) return false;
        if (s.is_eval) {
            for (s.cur_func().vars) |v| {
                if (v.var_name == atom_id) return evalDeleteBindingIsConfigurable(v.is_lexical, v.var_kind);
            }
            // Top-level eval declarations live in GlobalVar until
            // add_global_variables/finalization. Deletion is parsed before
            // that carrier exists, so consult the declaration record itself
            // instead of depending on the retired parser closure placeholder.
            for (s.cur_func().global_vars) |gv| {
                if (gv.var_name == atom_id) return !gv.is_lexical;
            }
            for (s.cur_func().closure_var) |cv| {
                if (cv.var_name == atom_id) return evalClosureBindingIsConfigurable(s, s.cur_func_stack.len, cv);
            }
            return false;
        }
        if (hasCurrentFunctionBinding(s, atom_id)) return false;
        for (s.cur_func().closure_var) |cv| {
            if (cv.var_name == atom_id) return evalClosureBindingIsConfigurable(s, s.cur_func_stack.len, cv);
        }
        return false;
    }

    fn shouldSnapshotStrictUnresolvedAssignment(s: *State, atom_id: Atom) bool {
        if (!(s.is_strict or s.cur_func().is_strict_mode)) return false;
        if (hasKnownBinding(s, atom_id)) return false;
        if (hasEvalNonLexicalBinding(s, atom_id)) return false;
        return true;
    }

    fn hasCurrentFunctionBinding(s: *State, atom_id: Atom) bool {
        return s.cur_func().findVar(atom_id) >= 0 or s.cur_func().findArg(atom_id) >= 0;
    }

    fn argumentsIdentifierIsForbidden(s: *State) bool {
        // QuickJS parses every field initializer in a synthetic method whose
        // FunctionDef has arguments_allowed=false (quickjs.c:36472). Both
        // instance and static initializers now use that real function
        // boundary, and arrows inherit its entry contract.
        return !s.cur_func().arguments_allowed;
    }

    fn atomListContains(list: []const Atom, atom_id: Atom) bool {
        for (list) |item| {
            if (item == atom_id) return true;
        }
        return false;
    }

    fn appendRetainedAtom(list: *std.ArrayList(Atom), allocator: std.mem.Allocator, atoms: *atom_module.AtomTable, atom_id: Atom) Error!void {
        const retained = atoms.dup(atom_id);
        errdefer atoms.free(retained);
        try list.append(allocator, retained);
    }

    fn tokenStartsPrimaryExpression(k: tok.TokenKind) bool {
        return k == tok.TOK_NUMBER or
            k == tok.TOK_STRING or
            k == tok.TOK_TEMPLATE or
            k == tok.TOK_TRUE or
            k == tok.TOK_FALSE or
            k == tok.TOK_NULL or
            k == tok.TOK_THIS or
            k == tok.TOK_SUPER or
            k == tok.TOK_CLASS or
            k == tok.TOK_FUNCTION or
            k == tok.TOK_IDENT or
            k == tok.TOK_LET or
            k == tok.TOK_YIELD or
            k == @as(tok.TokenKind, @intCast('(')) or
            k == @as(tok.TokenKind, @intCast('[')) or
            k == @as(tok.TokenKind, @intCast('{')) or
            k == @as(tok.TokenKind, @intCast('/')) or
            k == tok.TOK_DIV_ASSIGN;
    }

    fn tokenStartsYieldExpressionOperand(k: tok.TokenKind) bool {
        return tokenStartsPrimaryExpression(k) and !tokenCanStartSlashRegexp(k);
    }

    fn tokenCanStartSlashRegexp(k: tok.TokenKind) bool {
        return k == @as(tok.TokenKind, @intCast('/')) or k == tok.TOK_DIV_ASSIGN;
    }

    /// `js_parse_cond_expr` (`quickjs.c:27282`). `a ? b : c`.
    pub fn parseCondExpr(s: *State, flags: ParseFlags) Error!void {
        try parseCoalesceExpr(s, flags);
        if (s.isPunct('?')) {
            try s.advance();
            var then_flags = forceResultNeeded(flags);
            then_flags.in_accepted = true;
            const else_flags = forceResultNeeded(flags);
            // Short-circuit: if false, jump to else branch. The parser emits
            // absolute u32 offsets; `resolve_labels` lowers them to relative
            // goto8/goto16 forms.
            const else_jump_offset = try emitForwardJump(s, opcode.op.if_false);
            try parseAssignExprWithoutPendingFunctionName(s, then_flags);
            const end_jump_offset = try emitForwardJump(s, opcode.op.goto);
            try patchForwardJump(s, else_jump_offset);
            try expectPunct(s, ':');
            try parseAssignExprWithoutPendingFunctionName(s, else_flags);
            try patchForwardJump(s, end_jump_offset);
            s.last_anonymous_function_expr = false;
        }
    }

    /// `js_parse_coalesce_expr` (`quickjs.c:27254`). `a ?? b`.
    pub fn parseCoalesceExpr(s: *State, flags: ParseFlags) Error!void {
        try parseLogicalAndOr(s, tok.TOK_LOR, flags);
        if (s.peekKind() == tok.TOK_DOUBLE_QUESTION_MARK) {
            s.last_coalesce_expr_depth = s.assign_expr_depth;
            var end_jumps: std.ArrayList(usize) = .empty;
            defer end_jumps.deinit(s.lex.allocator);
            const rhs_flags = forceResultNeeded(flags);

            while (s.peekKind() == tok.TOK_DOUBLE_QUESTION_MARK) {
                try s.advance();
                // Short-circuit on non-nullish: `a ?? b` keeps a if not
                // null/undefined, else evaluates b. All successful
                // non-nullish tests jump to the common end label, matching
                // QuickJS's single-label lowering for chained `??`.
                try s.emitOp(opcode.op.dup);
                try s.emitOp(opcode.op.is_undefined_or_null);
                const skip_jump = try emitForwardJump(s, opcode.op.if_false);
                try end_jumps.append(s.lex.allocator, skip_jump);
                try s.emitOp(opcode.op.drop);
                try parseExprBinaryWithoutPendingFunctionName(s, 8, rhs_flags);
            }
            for (end_jumps.items) |skip_jump| {
                try patchForwardJump(s, skip_jump);
            }
            s.last_anonymous_function_expr = false;
        }
    }

    /// `js_parse_logical_and_or` (`quickjs.c:27213`). `a && b` / `a || b`.
    pub fn parseLogicalAndOr(s: *State, op_kind: tok.TokenKind, flags: ParseFlags) Error!void {
        if (op_kind == tok.TOK_LOR) {
            try parseLogicalAndOr(s, tok.TOK_LAND, flags);
            while (s.peekKind() == tok.TOK_LOR) {
                try s.advance();
                // `a || b` → `dup ; if_true L_skip ; drop ; <b> ; L_skip:`
                try s.emitOp(opcode.op.dup);
                const skip_jump = try emitForwardJump(s, opcode.op.if_true);
                try s.emitOp(opcode.op.drop);
                try parseLogicalAndOrWithoutPendingFunctionName(s, tok.TOK_LAND, forceResultNeeded(flags));
                try patchForwardJump(s, skip_jump);
                s.last_anonymous_function_expr = false;
                if (s.peekKind() != tok.TOK_LOR and s.peekKind() == tok.TOK_DOUBLE_QUESTION_MARK) {
                    return Error.UnexpectedToken;
                }
            }
        } else {
            try parseExprBinary(s, 8, flags);
            while (s.peekKind() == tok.TOK_LAND) {
                try s.advance();
                // `a && b` → `dup ; if_false L_skip ; drop ; <b> ; L_skip:`
                try s.emitOp(opcode.op.dup);
                const skip_jump = try emitForwardJump(s, opcode.op.if_false);
                try s.emitOp(opcode.op.drop);
                try parseExprBinaryWithoutPendingFunctionName(s, 8, forceResultNeeded(flags));
                try patchForwardJump(s, skip_jump);
                s.last_anonymous_function_expr = false;
                if (s.peekKind() != tok.TOK_LAND and s.peekKind() == tok.TOK_DOUBLE_QUESTION_MARK) {
                    return Error.UnexpectedToken;
                }
            }
        }
    }

    /// `js_parse_expr_binary` (`quickjs.c:27049`). Pratt-style with hand
    /// rolled level table. Levels 1..8 covered, including private-name `in`.
    pub fn parseExprBinary(s: *State, level: u8, flags: ParseFlags) Error!void {
        if (level == 0) {
            return parseUnary(s, ParseFlags{
                .in_accepted = flags.in_accepted,
                .pow_allowed = true,
                .result_needed = flags.result_needed,
                .yield_forbidden = flags.yield_forbidden,
            });
        }
        if (level == 4 and flags.in_accepted and s.peekKind() == tok.TOK_PRIVATE_NAME and s.peekNextKind() == tok.TOK_IN) {
            s.features.insert(.private_name);
            const private_atom = findClassPrivateBoundName(s, s.token.payload.ident.atom, 0) orelse return Error.UnexpectedToken;
            const retained_private_atom = s.function.atoms.dup(private_atom);
            defer s.function.atoms.free(retained_private_atom);
            try s.advance();
            try s.expectToken(tok.TOK_IN);
            if (checkArrowHead(s) or
                checkIdentArrowHead(s) or
                checkAsyncSingleParamArrowHead(s) or
                checkAsyncParenArrowHead(s))
            {
                return Error.UnexpectedToken;
            }
            try parseExprBinary(s, level - 1, flags);
            try s.emitOpAtomU16(opcode.op.scope_in_private_field, retained_private_atom, @intCast(s.scope_level));
            return;
        }
        try parseExprBinary(s, level - 1, flags);
        while (true) {
            const op_byte = matchBinaryOp(s.peekKind(), level, flags) orelse return;
            try s.advance();
            if (s.in_generator and s.peekKind() == tok.TOK_YIELD) return Error.UnexpectedToken;
            try parseExprBinaryWithoutPendingFunctionName(s, level - 1, flags);
            try s.emitOp(op_byte);
            s.last_anonymous_function_expr = false;
        }
    }

    fn parseAssignExprWithoutPendingFunctionName(s: *State, flags: ParseFlags) Error!void {
        const saved_name = s.pending_function_name;
        const saved_decl = s.pending_function_is_decl;
        s.pending_function_name = null;
        s.pending_function_is_decl = false;
        defer {
            s.pending_function_name = saved_name;
            s.pending_function_is_decl = saved_decl;
        }
        try parseAssignExpr2(s, flags);
    }

    fn parseLogicalAndOrWithoutPendingFunctionName(s: *State, op_kind: tok.TokenKind, flags: ParseFlags) Error!void {
        const saved_name = s.pending_function_name;
        const saved_decl = s.pending_function_is_decl;
        s.pending_function_name = null;
        s.pending_function_is_decl = false;
        defer {
            s.pending_function_name = saved_name;
            s.pending_function_is_decl = saved_decl;
        }
        try parseLogicalAndOr(s, op_kind, flags);
    }

    fn parseExprBinaryWithoutPendingFunctionName(s: *State, level: u8, flags: ParseFlags) Error!void {
        const saved_name = s.pending_function_name;
        const saved_decl = s.pending_function_is_decl;
        s.pending_function_name = null;
        s.pending_function_is_decl = false;
        defer {
            s.pending_function_name = saved_name;
            s.pending_function_is_decl = saved_decl;
        }
        try parseExprBinary(s, level, flags);
    }

    /// `js_parse_unary` (`quickjs.c:26922`). Covers prefix `+`, `-`, `~`,
    /// `!`, `void`, `typeof`, `delete`, prefix `++`/`--`, right-associative
    /// `**`, contextual `yield`, and contextual `await`.
    pub fn parseUnary(s: *State, flags: ParseFlags) Error!void {
        const k = s.peekKind();
        if (k == @as(tok.TokenKind, @intCast('+'))) {
            try s.advance();
            try parseUnary(s, .{ .pow_allowed = false, .in_accepted = flags.in_accepted, .yield_forbidden = true });
            try s.emitOp(opcode.op.plus);
            return;
        }
        if (k == @as(tok.TokenKind, @intCast('-'))) {
            const operator_line_num = s.token.line_num;
            const operator_col_num = s.token.col_num;
            try s.advance();
            if (s.cur_func().use_short_opcodes and
                s.peekKind() == tok.TOK_NUMBER and
                !s.token.payload.num.is_bigint)
            {
                const value = s.token.payload.num.value;
                if (value != 0 and numberIsExactI32(value)) {
                    try s.emitOpI32(opcode.op.push_i32, -@as(i32, @intFromFloat(value)));
                    try s.advance();
                    return;
                }
            }
            try parseUnary(s, .{ .pow_allowed = false, .in_accepted = flags.in_accepted, .yield_forbidden = true });
            const last_opcode_is_inline_bigint = blk: {
                const last_opcode_pos = s.cur_func().last_opcode_pos;
                if (last_opcode_pos < 0) break :blk false;
                const pos: usize = @intCast(last_opcode_pos);
                const code = s.currentCode();
                break :blk pos + 5 == code.len and code[pos] == opcode.op.push_bigint_i32;
            };
            if (last_opcode_is_inline_bigint) {
                try s.emitOpAt(opcode.op.neg, operator_line_num, operator_col_num);
            } else {
                try s.emitOp(opcode.op.neg);
            }
            return;
        }
        if (k == @as(tok.TokenKind, @intCast('~'))) {
            try s.advance();
            try parseUnary(s, .{ .pow_allowed = false, .in_accepted = flags.in_accepted, .yield_forbidden = true });
            try s.emitOp(opcode.op.not);
            return;
        }
        if (k == @as(tok.TokenKind, @intCast('!'))) {
            try s.advance();
            try parseUnary(s, .{ .pow_allowed = false, .in_accepted = flags.in_accepted, .yield_forbidden = true });
            try s.emitOp(opcode.op.lnot);
            return;
        }
        if (k == tok.TOK_VOID) {
            try s.advance();
            try parseUnary(s, .{ .pow_allowed = false, .in_accepted = flags.in_accepted, .yield_forbidden = true });
            try s.emitOpNoSource(opcode.op.drop);
            try s.emitOpNoSource(opcode.op.undefined);
            return;
        }
        if (k == tok.TOK_TYPEOF) {
            try s.advance();
            try parseUnary(s, .{ .pow_allowed = false, .in_accepted = flags.in_accepted, .yield_forbidden = true });
            // QuickJS patches only the actual last phase-1 scope getter. A
            // member/call/comma/control tail therefore remains untouched.
            const fd = s.cur_func();
            if (fd.last_opcode_pos >= 0) {
                const pos: usize = @intCast(fd.last_opcode_pos);
                const code = s.currentCode();
                if (pos < code.len and code[pos] == opcode.op.scope_get_var) {
                    code[pos] = opcode.op.scope_get_var_undef;
                }
            }
            try s.emitOp(opcode.op.typeof);
            return;
        }
        if (k == tok.TOK_DELETE) {
            try s.advance();
            return parseDelete(s, flags);
        }
        if (k == tok.TOK_INC or k == tok.TOK_DEC) {
            const update_op: u8 = if (k == tok.TOK_INC) opcode.op.inc else opcode.op.dec;
            const operator_source = SourcePosition{
                .line_num = s.token.line_num,
                .col_num = s.token.col_num,
            };
            try s.advance();
            try parseUnary(s, .{ .in_accepted = flags.in_accepted });
            var lvalue = try getLValue(s, true);
            defer lvalue.deinit(s);
            const emission_snapshot = s.takeEmissionSnapshot();
            errdefer s.rollbackEmission(emission_snapshot);
            _ = try s.emitSourcePosAndLoc(operator_source.line_num, operator_source.col_num);
            try s.emitOpNoSource(update_op);
            try putLValue(s, &lvalue, .keep_top);
            if (flags.pow_allowed and s.peekKind() == tok.TOK_POW) {
                try s.advance();
                try parseUnary(s, ParseFlags{ .in_accepted = flags.in_accepted, .pow_allowed = true });
                try s.emitOp(opcode.op.pow);
            }
            return;
        }
        // Handle yield expressions in generator functions.
        if (s.in_class_static_block and (k == tok.TOK_AWAIT or k == tok.TOK_YIELD)) {
            return Error.UnexpectedToken;
        }
        if (k == tok.TOK_YIELD) {
            if (flags.yield_forbidden) return Error.UnexpectedToken;
            if (s.in_parameter_initializer and s.in_generator) return Error.UnexpectedToken;
            if (!s.in_generator) {
                if (s.is_strict or s.cur_func().is_strict_mode) return Error.YieldOutsideGenerator;
                var next_has_line_terminator = false;
                const next_kind = s.peekNextKindWithLineTerminator(&next_has_line_terminator);
                if (!next_has_line_terminator and
                    next_kind != @as(tok.TokenKind, @intCast('(')) and
                    next_kind != @as(tok.TokenKind, @intCast('[')) and
                    next_kind != tok.TOK_TEMPLATE and
                    tokenStartsYieldExpressionOperand(next_kind))
                {
                    return Error.YieldOutsideGenerator;
                }
                return parsePostfixExpr(s, flags);
            }
            try s.advance();
            // Check for yield*. A line terminator after `yield` ends the
            // YieldExpression before any following operand.
            const has_line_terminator = s.lex.got_lf;
            if (has_line_terminator and s.peekKind() == '*') return Error.UnexpectedToken;
            const is_yield_star = !has_line_terminator and s.peekKind() == '*';
            if (is_yield_star) {
                try s.advance();
                try parseAssignExpr2(s, ParseFlags{ .in_accepted = flags.in_accepted });
                try emitYieldStarDelegation(s, s.in_async);
            } else {
                // Check if there's an expression after yield
                // yield without an expression is equivalent to yield undefined
                if (has_line_terminator or
                    s.peekKind() == @as(tok.TokenKind, @intCast(';')) or
                    s.peekKind() == @as(tok.TokenKind, @intCast(',')) or
                    s.peekKind() == @as(tok.TokenKind, @intCast(':')) or
                    s.peekKind() == @as(tok.TokenKind, @intCast('}')) or
                    s.peekKind() == @as(tok.TokenKind, @intCast(']')) or
                    s.peekKind() == @as(tok.TokenKind, @intCast(')')) or
                    s.peekKind() == tok.TOK_EOF)
                {
                    // yield without expression
                    try s.emitOp(opcode.op.undefined);
                } else {
                    // yield with expression
                    try parseAssignExpr2(s, ParseFlags{ .in_accepted = flags.in_accepted });
                }
                try s.emitOp(opcode.op.yield);
                const normal_resume = try emitForwardJump(s, opcode.op.if_false);
                try emitReturnValue(s, s.in_async and s.in_generator);
                try patchForwardJump(s, normal_resume);
            }
            return;
        }
        // Handle await expressions in async functions.
        if (k == tok.TOK_AWAIT) {
            // AwaitExpression is forbidden in formal-parameter initializers
            // of async functions.  Reject the actual grammar production here,
            // not every lexical `await` token in the initializer: IdentifierName
            // uses such as `({ await: 1 }).await` remain valid.
            if (s.in_parameter_initializer and s.reject_await_in_parameter_initializer) {
                return Error.UnexpectedToken;
            }
            const top_level_module_await = s.lex.is_module and s.cur_func_stack.len == 0;
            if (!s.in_async and !top_level_module_await) {
                const next_kind = s.peekNextKind();
                if (canUseAwaitAsIdentifier(s) and
                    (!tokenCanStartExpression(next_kind) or
                        next_kind == @as(tok.TokenKind, @intCast('(')) or
                        next_kind == @as(tok.TokenKind, @intCast('.')) or
                        next_kind == @as(tok.TokenKind, @intCast('[')) or
                        next_kind == tok.TOK_INC or
                        next_kind == tok.TOK_DEC))
                {
                    try parsePostfixExpr(s, flags);
                    return;
                }
                return Error.AwaitOutsideAsyncFunction;
            }
            if (top_level_module_await) s.function.ensureModule().has_top_level_await = true;
            try s.advance();
            // `await`'s operand is a UnaryExpression (spec AwaitExpression:
            // `await UnaryExpression`; qjs js_parse_unary TOK_AWAIT parses a
            // unary operand), NOT an AssignmentExpression — so
            // `await Promise.resolve(2) * x` is `(await …) * x`, not
            // `await (… * x)`.
            try parseUnary(s, flags);
            try s.emitOp(opcode.op.await);
            return;
        }
        try parsePostfixExpr(s, flags);
        // PF_POW_ALLOWED: `a ** b` is right-associative and only allowed
        // when no unary prefix was consumed.
        if (flags.pow_allowed and s.peekKind() == tok.TOK_POW) {
            try s.advance();
            try parseUnary(s, ParseFlags{ .in_accepted = flags.in_accepted, .pow_allowed = true });
            try s.emitOp(opcode.op.pow);
        }
    }

    fn emitYieldStarDelegation(s: *State, is_async: bool) Error!void {
        const done_atom = atom_module.predefinedId("done", .string) orelse return Error.UnexpectedToken;
        const value_atom = atom_module.predefinedId("value", .string) orelse return Error.UnexpectedToken;

        try s.emitOp(if (is_async) opcode.op.for_await_of_start else opcode.op.for_of_start);
        try s.emitOp(opcode.op.drop);
        try s.emitOp(opcode.op.undefined);
        try s.emitOp(opcode.op.undefined);

        const loop_pc: u32 = @intCast(s.currentCodeLen());
        try s.emitOp(opcode.op.iterator_next);
        if (is_async) try s.emitOp(opcode.op.await);
        try s.emitOp(opcode.op.iterator_check_object);
        try s.emitOpAtom(opcode.op.get_field2, done_atom);
        const label_next = try emitForwardJump(s, opcode.op.if_true);

        const yield_pc: u32 = @intCast(s.currentCodeLen());
        if (is_async) {
            try s.emitOpAtom(opcode.op.get_field, value_atom);
            try s.emitOp(opcode.op.async_yield_star);
        } else {
            try s.emitOp(opcode.op.yield_star);
        }
        try s.emitOp(opcode.op.dup);
        const label_return = try emitForwardJump(s, opcode.op.if_true);
        try s.emitOp(opcode.op.drop);
        try emitBackwardJump(s, opcode.op.goto, loop_pc);

        try patchForwardJump(s, label_return);
        try s.emitOpI32(opcode.op.push_i32, 2);
        try s.emitOp(opcode.op.strict_eq);
        const label_throw = try emitForwardJump(s, opcode.op.if_true);

        if (is_async) try s.emitOp(opcode.op.await);
        try s.emitOpU8(opcode.op.iterator_call, 0);
        const label_return1 = try emitForwardJump(s, opcode.op.if_true);
        if (is_async) try s.emitOp(opcode.op.await);
        try s.emitOp(opcode.op.iterator_check_object);
        try s.emitOpAtom(opcode.op.get_field2, done_atom);
        try emitBackwardJump(s, opcode.op.if_false, yield_pc);

        try s.emitOpAtom(opcode.op.get_field, value_atom);

        try patchForwardJump(s, label_return1);
        try s.emitOp(opcode.op.nip);
        try s.emitOp(opcode.op.nip);
        try s.emitOp(opcode.op.nip);
        if (is_async) try s.emitOp(opcode.op.await);
        try emitReturnValue(s, false);

        try patchForwardJump(s, label_throw);
        try s.emitOpU8(opcode.op.iterator_call, 1);
        const label_throw1 = try emitForwardJump(s, opcode.op.if_true);
        if (is_async) try s.emitOp(opcode.op.await);
        try s.emitOp(opcode.op.iterator_check_object);
        try s.emitOpAtom(opcode.op.get_field2, done_atom);
        try emitBackwardJump(s, opcode.op.if_false, yield_pc);
        const goto_next = try emitForwardJump(s, opcode.op.goto);

        try patchForwardJump(s, label_throw1);
        try s.emitOpU8(opcode.op.iterator_call, 2);
        const label_throw2 = try emitForwardJump(s, opcode.op.if_true);
        if (is_async) try s.emitOp(opcode.op.await);
        try patchForwardJump(s, label_throw2);
        try s.emitOpAtomU8(opcode.op.throw_error, atom_module.null_atom, 4);

        try patchForwardJump(s, label_next);
        try patchForwardJump(s, goto_next);
        try s.emitOpAtom(opcode.op.get_field, value_atom);
        try s.emitOp(opcode.op.nip);
        try s.emitOp(opcode.op.nip);
        try s.emitOp(opcode.op.nip);
    }

    /// Emit `this` for a super-property receiver. Synthetic field initializer
    /// methods own a normal receiver binding; nested arrows/static blocks
    /// resolve it through the ordinary closure chain.
    fn emitSuperThis(s: *State) Error!void {
        if (s.emit_to_function_def) {
            // QuickJS emits the same scope lookup in methods and nested
            // arrows; resolve_pseudo_var decides whether this is an owner
            // local or a closure over the nearest ThisBinding.
            try s.emitScopeGetVar(atom_this);
            return;
        }
        try s.emitOp(opcode.op.push_this);
    }

    /// Emit the `[this, home_object]` pair consumed by a super property
    /// reference. FunctionDef-backed methods use ordinary pseudo-variable
    /// resolution; low-level mutable root fixtures use the frame
    /// special-object opcode.
    fn emitSuperThisAndHomeObject(s: *State) Error!void {
        try emitSuperThis(s);
        if (s.emit_to_function_def) {
            try s.emitScopeGetVar(atom_home_object);
        } else {
            try s.emitOpU8(opcode.op.special_object, opcode.special_object_subtype.home_object);
        }
    }

    fn isDeleteSuperReference(s: *State) bool {
        if (s.peekKind() != tok.TOK_SUPER) return false;
        const next = s.peekNextKind();
        return next == @as(tok.TokenKind, @intCast('.')) or next == @as(tok.TokenKind, @intCast('['));
    }

    fn parseDeleteSuperReference(s: *State, flags: ParseFlags) Error!void {
        try s.advance(); // super
        if (s.peekKind() == @as(tok.TokenKind, @intCast('.'))) {
            try s.advance();
            const name = if (s.peekKind() == tok.TOK_IDENT)
                s.token.payload.ident.atom
            else if (tok.isKeyword(s.peekKind()))
                tok.keywordAtom(s.peekKind())
            else if (s.peekKind() == tok.TOK_DELETE)
                @as(Atom, 9)
            else if (s.peekKind() == tok.TOK_CATCH)
                @as(Atom, 25)
            else
                return Error.UnexpectedToken;
            try s.advance();
            if (s.peekKind() == @as(tok.TokenKind, @intCast('('))) {
                try s.emitOp(opcode.op.get_super);
                try s.emitOpAtom(opcode.op.push_atom_value, name);
                try s.emitOp(opcode.op.get_super_value);
                const shape = try parseCallArgs(s, flags);
                switch (shape) {
                    .direct => |argc| try s.emitOpU16(opcode.op.call, argc),
                    .applied => try s.emitOpU16(opcode.op.apply, 0),
                }
                try s.emitOp(opcode.op.drop);
                try s.emitOp(opcode.op.push_true);
                return;
            }
        } else if (s.peekKind() == @as(tok.TokenKind, @intCast('['))) {
            try s.advance();
            try s.emitOp(opcode.op.push_this);
            try s.emitOp(opcode.op.drop);
            try parseExpr(s);
            try expectPunct(s, ']');
        } else {
            return Error.UnexpectedToken;
        }
        try emitDeleteSuperError(s);
    }

    fn emitDeleteSuperError(s: *State) Error!void {
        try s.emitOpAtomU8(opcode.op.throw_error, atom_module.null_atom, 3);
    }

    fn endsWithGetSuperValue(code: []const u8, min_pos: usize) bool {
        return code.len > min_pos and code[code.len - 1] == opcode.op.get_super_value;
    }

    /// `js_parse_delete` (`quickjs.c:26829`). Generic implementation: parse
    /// a unary-style operand normally, then classify the trailing emission
    /// and rewrite it into a delete shape:
    ///
    ///   * `var_ref a`     → truncate `get_var a` ; emit `delete_var a`
    ///   * `dotted obj.b`  → in-place rewrite trailing `get_field b` to
    ///                       `push_atom_value b` (same byte length); emit
    ///                       `delete`
    ///   * `indexed a[i]`  → truncate trailing `get_array_el` (1 byte);
    ///                       emit `delete`
    ///   * `none`          → operand is not a reference; per spec return
    ///                       `true` after evaluating the operand for side
    ///                       effects: emit `drop ; push_true`
    ///
    /// This handles arbitrary chain depths (`delete a.b.c`,
    /// `delete a.b[i]`, etc.) because the rewrite touches only the final
    /// access. Optional-chain `delete a?.b` / `delete super.x` /
    /// `delete #priv` are deferred.
    fn parseDelete(s: *State, flags: ParseFlags) Error!void {
        try parseUnary(s, .{ .pow_allowed = false, .in_accepted = flags.in_accepted });
        const fd = s.cur_func();
        if (fd.last_opcode_pos < 0) {
            try s.emitOp(opcode.op.drop);
            try s.emitOp(opcode.op.push_true);
            return;
        }

        const pos: usize = @intCast(fd.last_opcode_pos);
        const code = s.currentCode();
        if (pos >= code.len) return Error.UnexpectedToken;
        switch (code[pos]) {
            opcode.op.get_field_opt_chain, opcode.op.get_array_el_opt_chain => try rewriteOptionalChainDelete(s, pos),
            opcode.op.get_field => {
                const atom_id: Atom = std.mem.readInt(u32, code[pos + 1 ..][0..4], .little);
                if (atomNameIsPrivate(s, atom_id)) return Error.UnexpectedToken;
                // Same-width atom opcode: the retained operand stays in its
                // exact stream position while the getter becomes a key push.
                code[pos] = opcode.op.push_atom_value;
                try s.emitOp(opcode.op.delete);
            },
            opcode.op.get_array_el => {
                try s.truncateCode(pos);
                try s.emitOp(opcode.op.delete);
            },
            opcode.op.get_length => {
                try s.truncateCode(pos);
                try s.emitOpAtom(opcode.op.push_atom_value, atom_module.ids.length);
                try s.emitOp(opcode.op.delete);
            },
            opcode.op.scope_get_var => {
                if (!s.emit_phase1_temp or pos + 7 > code.len) return Error.UnexpectedToken;
                const name: Atom = std.mem.readInt(u32, code[pos + 1 ..][0..4], .little);
                if (name == atom_this or name == atom_new_target) {
                    try s.emitOp(opcode.op.drop);
                    try s.emitOp(opcode.op.push_true);
                } else if (s.is_strict or fd.is_strict_mode) {
                    return Error.UnexpectedToken;
                } else {
                    code[pos] = opcode.op.scope_delete_var;
                }
            },
            opcode.op.scope_get_private_field => return Error.UnexpectedToken,
            opcode.op.get_super_value => {
                try s.truncateCode(pos);
                try emitDeleteSuperError(s);
            },
            else => {
                try s.emitOp(opcode.op.drop);
                try s.emitOp(opcode.op.push_true);
            },
        }
    }

    /// `js_parse_delete` OP_get_field_opt_chain / OP_get_array_el_opt_chain
    /// handling (`quickjs.c:27512-27562`): delete of an optional-chain
    /// member access. qjs reads the chain label out of the `*_opt_chain`
    /// opcode, truncates the access, emits `OP_delete`, then routes the
    /// chain's short-circuit path through a `drop ; push_true` pad:
    ///
    ///     push_atom_value <prop> ; delete ; goto NEXT
    ///     OPT_CHAIN: drop ; push_true
    ///     NEXT:
    ///
    /// The pseudo getter is immediately followed by the raw shared-label
    /// marker, so delete consumes label identity directly without collecting
    /// exits or recognising an emitted byte signature.
    fn rewriteOptionalChainDelete(s: *State, pos: usize) Error!void {
        var code = s.currentCode();
        const field_form = code[pos] == opcode.op.get_field_opt_chain;
        const getter_size: usize = if (field_form) 5 else 1;
        const raw_label_pos = pos + getter_size;
        if (raw_label_pos + 5 != code.len or code[raw_label_pos] != opcode.op.label) {
            return Error.UnexpectedToken;
        }
        const optional_label = ParserLabelRef{
            .id = std.mem.readInt(u32, code[raw_label_pos + 1 ..][0..4], .little),
        };
        if (optional_label.id == 0 or optional_label.id >= opcode.op.parser_label_tag) return Error.UnexpectedToken;

        if (field_form) {
            const atom_id: Atom = std.mem.readInt(u32, code[pos + 1 ..][0..4], .little);
            if (atomNameIsPrivate(s, atom_id)) {
                // Baseline private transport uses an ordinary field opcode.
                // Preserve QJS's observable `delete this?.#x` no-op: both the
                // accessed and short-circuit paths discard one value and true.
                try s.reserveEmission(2, 0);
                code = s.currentCode();
                code[pos] = opcode.op.get_field;
                s.invalidateLastOpcode();
                emitOpNoSourceAssumeCapacity(s, opcode.op.drop);
                emitOpNoSourceAssumeCapacity(s, opcode.op.push_true);
                return;
            }
        }

        // Field form keeps its five-byte atom operand; indexed form removes
        // the one-byte getter. Both then emit the exact QJS two-label bridge.
        try s.reserveEmission(if (field_form) 13 else 12, 0);
        const next_label = newParserLabel(s);
        code = s.currentCode();
        if (field_form) {
            code[pos] = opcode.op.push_atom_value;
            s.truncateCode(raw_label_pos) catch unreachable;
        } else {
            s.truncateCode(pos) catch unreachable;
        }
        emitOpNoSourceAssumeCapacity(s, opcode.op.delete);
        emitGotoParserLabelNoSourceAssumeCapacity(s, next_label);
        emitParserLabelNoSourceAssumeCapacity(s, optional_label);
        emitOpNoSourceAssumeCapacity(s, opcode.op.drop);
        emitOpNoSourceAssumeCapacity(s, opcode.op.push_true);
        emitParserLabelNoSourceAssumeCapacity(s, next_label);
    }

    fn isMemberStart(k: tok.TokenKind) bool {
        return k == @as(tok.TokenKind, @intCast('.')) or
            k == @as(tok.TokenKind, @intCast('[')) or
            k == @as(tok.TokenKind, @intCast('('));
    }

    const CallReferenceKind = enum {
        plain,
        method,
        direct_eval,
    };

    const CallConsumerKind = enum {
        normal,
        template,
    };

    const PreparedCallReference = struct {
        kind: CallReferenceKind,
        optional_drop_count: u8,
    };

    /// QuickJS call-site consumer (`js_parse_postfix_expr`): classify and
    /// rewrite only the actual last opcode. Producers never choose a receiver
    /// form by peeking at the following token.
    fn prepareCallReference(
        s: *State,
        consumer: CallConsumerKind,
        has_optional_site: bool,
    ) Error!PreparedCallReference {
        const fd = s.cur_func();
        if (fd.last_opcode_pos < 0) return .{ .kind = .plain, .optional_drop_count = 1 };
        const pos: usize = @intCast(fd.last_opcode_pos);
        var code = s.currentCode();
        if (pos >= code.len) return Error.UnexpectedToken;

        switch (code[pos]) {
            opcode.op.get_field_opt_chain, opcode.op.get_array_el_opt_chain => {
                const getter_size: usize = if (code[pos] == opcode.op.get_field_opt_chain) 5 else 1;
                const raw_label_pos = pos + getter_size;
                if (raw_label_pos + 5 != code.len or code[raw_label_pos] != opcode.op.label) {
                    return Error.UnexpectedToken;
                }
                const optional_label = ParserLabelRef{
                    .id = std.mem.readInt(u32, code[raw_label_pos + 1 ..][0..4], .little),
                };
                if (optional_label.id == 0 or optional_label.id >= opcode.op.parser_label_tag) return Error.UnexpectedToken;

                // Claim the net growth before rewriting/truncating. The bridge
                // is then a no-fail commit and the pseudo getter remains intact
                // on OOM.
                try s.reserveEmission(11, 0);
                const next_label = newParserLabel(s);
                code = s.currentCode();
                code[pos] = if (getter_size == 5) opcode.op.get_field2 else opcode.op.get_array_el2;
                s.truncateCode(raw_label_pos) catch unreachable;
                emitGotoParserLabelNoSourceAssumeCapacity(s, next_label);
                emitParserLabelNoSourceAssumeCapacity(s, optional_label);
                emitOpNoSourceAssumeCapacity(s, opcode.op.undefined);
                emitParserLabelNoSourceAssumeCapacity(s, next_label);
                return .{ .kind = .method, .optional_drop_count = 2 };
            },
            opcode.op.get_field => {
                if (pos + 5 != code.len) return .{ .kind = .plain, .optional_drop_count = 1 };
                code[pos] = opcode.op.get_field2;
                return .{ .kind = .method, .optional_drop_count = 2 };
            },
            opcode.op.scope_get_private_field => {
                if (!s.emit_phase1_temp or pos + 7 != code.len) {
                    return .{ .kind = .plain, .optional_drop_count = 1 };
                }
                code[pos] = opcode.op.scope_get_private_field2;
                return .{ .kind = .method, .optional_drop_count = 2 };
            },
            opcode.op.get_array_el => {
                if (pos + 1 != code.len) return .{ .kind = .plain, .optional_drop_count = 1 };
                code[pos] = opcode.op.get_array_el2;
                return .{ .kind = .method, .optional_drop_count = 2 };
            },
            opcode.op.get_super_value => {
                if (pos + 1 != code.len) return .{ .kind = .plain, .optional_drop_count = 1 };
                // The existing stack is `[this, func]`; get_array_el is the
                // same-width marker QuickJS uses for method dispatch.
                code[pos] = opcode.op.get_array_el;
                return .{ .kind = .method, .optional_drop_count = 2 };
            },
            opcode.op.scope_get_var => {
                if (!s.emit_phase1_temp or pos + 7 != code.len) {
                    return .{ .kind = .plain, .optional_drop_count = 1 };
                }
                const name: Atom = std.mem.readInt(u32, code[pos + 1 ..][0..4], .little);
                const scope = std.mem.readInt(u16, code[pos + 5 ..][0..2], .little);
                if (consumer == .normal and !has_optional_site and atomNameEquals(s, name, "eval")) {
                    return .{ .kind = .direct_eval, .optional_drop_count = 1 };
                }
                if (hasWithScopeFrom(fd, scope)) {
                    code[pos] = opcode.op.scope_get_ref;
                    return .{ .kind = .method, .optional_drop_count = 1 };
                }
            },
            else => {},
        }
        return .{ .kind = .plain, .optional_drop_count = 1 };
    }

    fn emitPreparedCall(
        s: *State,
        prepared: PreparedCallReference,
        shape: CallArgsShape,
        line_num: u32,
        col_num: u32,
    ) Error!void {
        const snapshot = s.takeEmissionSnapshot();
        errdefer s.rollbackEmission(snapshot);
        _ = try s.emitSourcePosAndLoc(line_num, col_num);

        switch (shape) {
            .direct => |argc| switch (prepared.kind) {
                .plain => try s.emitOpU16NoSource(opcode.op.call, argc),
                .method => try s.emitOpU16NoSource(opcode.op.call_method, argc),
                .direct_eval => {
                    const eval_scope: u16 = @intCast(s.scope_level);
                    try s.emitOpU32NoSource(opcode.op.eval, @as(u32, argc) | (@as(u32, eval_scope) << 16));
                },
            },
            .applied => switch (prepared.kind) {
                .plain => {
                    try s.emitOpNoSource(opcode.op.undefined);
                    try s.emitOpNoSource(opcode.op.swap);
                    try s.emitOpU16NoSource(opcode.op.apply, 0);
                },
                .method => {
                    try s.emitOpNoSource(opcode.op.perm3);
                    try s.emitOpU16NoSource(opcode.op.apply, 0);
                },
                .direct_eval => {
                    const eval_scope: u16 = @intCast(s.scope_level);
                    try s.emitOpU16NoSource(opcode.op.apply_eval, eval_scope);
                },
            },
        }
        if (prepared.kind == .direct_eval) try s.markDirectEvalCall();
    }

    fn emitPlainCallFromStack(s: *State, shape: CallArgsShape) Error!void {
        switch (shape) {
            .direct => |argc| try s.emitOpU16(opcode.op.call, argc),
            .applied => {
                try s.emitOp(opcode.op.undefined);
                try s.emitOp(opcode.op.swap);
                try s.emitOpU16(opcode.op.apply, 0);
            },
        }
    }

    /// `js_parse_postfix_expr` (`quickjs.c:26176`). Wraps `parseLhsExpr`
    /// with the postfix `++` / `--` update operators.
    pub fn parsePostfixExpr(s: *State, flags: ParseFlags) Error!void {
        try parseLhsExpr(s, flags);

        const k = s.peekKind();
        if (k != tok.TOK_INC and k != tok.TOK_DEC) return;
        // ASI: per QuickJS (`quickjs.c:26206`), a postfix `++` / `--` after
        // a LineTerminator is forbidden. The lexer's `got_lf` flag tracks that.
        if (s.lex.got_lf) return;

        var lvalue = try getLValue(s, true);
        defer lvalue.deinit(s);
        const operator_source = SourcePosition{
            .line_num = s.token.line_num,
            .col_num = s.token.col_num,
        };
        const update_op: u8 = if (k == tok.TOK_INC) opcode.op.post_inc else opcode.op.post_dec;
        try s.advance(); // consume `++` or `--`

        const emission_snapshot = s.takeEmissionSnapshot();
        errdefer s.rollbackEmission(emission_snapshot);
        _ = try s.emitSourcePosAndLoc(operator_source.line_num, operator_source.col_num);
        try s.emitOpNoSource(update_op);
        try putLValue(s, &lvalue, .keep_second);
    }

    /// `js_parse_left_hand_side_expr` (`quickjs.c:24487`). Primary
    /// expression followed by zero or more member accesses (`.x`, `[x]`),
    /// function calls (`(...)`), and `new` constructions.
    ///
    /// Each `?.` access emits QuickJS's inline `optional_chain_test` and
    /// branches to one shared parser label. The chain closes with a raw label
    /// marker, so call/delete consume its identity from the real last getter;
    /// no per-exit buffer or byte-signature recovery is involved.
    pub fn parseLhsExpr(s: *State, flags: ParseFlags) Error!void {
        if (s.peekKind() == tok.TOK_NEW) {
            try parseNewExpr(s, flags);
        } else {
            try parsePrimary(s, flags);
        }
        const primary_was_arrow_function = s.last_primary_was_arrow_function;
        s.last_primary_was_arrow_function = false;
        if (primary_was_arrow_function) {
            return;
        }
        const was_super = s.last_was_super;
        var optional_chain_label: ?ParserLabelRef = null;
        try parseMemberChain(s, flags, &optional_chain_label);
        if (optional_chain_label) |label| {
            const getter_end = s.currentCodeLen();
            // Like QuickJS `emit_label_raw`, the marker carries label identity
            // but does not replace the last real opcode.
            try emitParserLabelRawNoSource(s, label);
            const fd = s.cur_func();
            if (fd.last_opcode_pos >= 0) {
                const pos: usize = @intCast(fd.last_opcode_pos);
                const code = s.currentCode();
                if (pos + 5 == getter_end and code[pos] == opcode.op.get_field) {
                    code[pos] = opcode.op.get_field_opt_chain;
                } else if (pos + 1 == getter_end and code[pos] == opcode.op.get_array_el) {
                    code[pos] = opcode.op.get_array_el_opt_chain;
                } else {
                    s.invalidateLastOpcode();
                }
            }
        }
        // Handle super() constructor calls after member chain.
        if (was_super and optional_chain_label == null and s.peekKind() == @as(tok.TokenKind, @intCast('('))) {
            if (!s.allow_super_call) return Error.UnexpectedToken;
            const call_source = SourceLoc{ .line = s.token.line_num, .col = s.token.col_num };
            const active_func_idx = s.cur_func().this_active_func_var_idx;
            const new_target_idx = s.cur_func().new_target_var_idx;
            const this_idx = s.cur_func().this_var_idx;
            if (active_func_idx < 0 or new_target_idx < 0 or this_idx < 0) {
                try emitCapturedSuperConstructorCall(s, flags, call_source);
                s.last_was_super = false;
                return;
            }
            const code = s.currentCode();
            if (code.len == 0 or code[code.len - 1] != opcode.op.get_super) return Error.UnexpectedToken;
            try s.truncateCode(code.len - 1);
            try s.emitOpU16(opcode.op.get_loc, @intCast(active_func_idx));
            try s.emitOp(opcode.op.get_super);
            try s.emitOpU16(opcode.op.get_loc, @intCast(new_target_idx));
            const shape = try parseCallArgs(s, flags);
            switch (shape) {
                .direct => |argc| try s.emitOpU16At(opcode.op.call_constructor, argc, call_source.line, call_source.col),
                .applied => try s.emitOpU16At(opcode.op.apply, 1, call_source.line, call_source.col),
            }
            try s.emitOp(opcode.op.dup);
            try s.emitOpU16(opcode.op.put_loc_check_init, @intCast(this_idx));
            try emitClassFieldInitCall(s);
            if (s.in_constructor and s.class_has_extends) {
                if (s.current_parameter_properties) |props| {
                    for (props.items) |prop_atom| {
                        try s.emitThisValue();
                        try s.emitScopeGetVar(prop_atom);
                        try s.emitOpAtom(opcode.op.put_field, prop_atom);
                    }
                }
            }
            s.last_was_super = false;
        }
    }

    const SourceLoc = struct {
        line: u32,
        col: u32,
    };

    fn emitCapturedSuperConstructorCall(s: *State, flags: ParseFlags, loc: ?SourceLoc) Error!void {
        const code = s.currentCode();
        if (code.len == 0 or code[code.len - 1] != opcode.op.get_super) return Error.UnexpectedToken;
        try s.truncateCode(code.len - 1);

        try s.emitScopeGetVar(atom_this_active_func);
        try s.emitOp(opcode.op.get_super);
        try s.emitScopeGetVar(atom_new_target);
        const shape = try parseCallArgs(s, flags);
        switch (shape) {
            .direct => |argc| {
                if (loc) |source_loc| {
                    try s.emitOpU16At(opcode.op.call_constructor, argc, source_loc.line, source_loc.col);
                } else {
                    try s.emitOpU16(opcode.op.call_constructor, argc);
                }
            },
            .applied => {
                if (loc) |source_loc| {
                    try s.emitOpU16At(opcode.op.apply, 1, source_loc.line, source_loc.col);
                } else {
                    try s.emitOpU16(opcode.op.apply, 1);
                }
            },
        }
        try s.emitOp(opcode.op.dup);
        try s.emitScopePutVarInit(atom_this);
        try emitClassFieldInitCall(s);
        if (s.in_constructor and s.class_has_extends) {
            if (s.current_parameter_properties) |props| {
                for (props.items) |prop_atom| {
                    try s.emitScopeGetVar(atom_this);
                    try s.emitScopeGetVar(prop_atom);
                    try s.emitOpAtom(opcode.op.put_field, prop_atom);
                }
            }
        }
    }

    /// Initialize the current class's instance elements from the lexical
    /// `<class_fields_init>` closure. Both names stay as phase-1 scope
    /// operands so a direct constructor uses locals while an arrow containing
    /// `super()` receives the ordinary threaded captures.
    fn emitClassFieldInitCall(s: *State) Error!void {
        try s.emitScopeGetVar(atom_class_fields_init);
        try s.emitOp(opcode.op.dup);
        const skip_call = try emitForwardJump(s, opcode.op.if_false);
        try s.emitScopeGetVar(atom_this);
        try s.emitOp(opcode.op.swap);
        try s.emitOpU16(opcode.op.call_method, 0);
        try patchForwardJump(s, skip_call);
        try s.emitOp(opcode.op.drop);
    }

    fn parseNewExpr(s: *State, flags: ParseFlags) Error!void {
        try s.advance(); // consume 'new'
        if (s.peekKind() == @as(tok.TokenKind, @intCast('.'))) {
            try s.advance();
            if (s.peekKind() != tok.TOK_IDENT or
                s.token.payload.ident.has_escape or
                !atomNameEquals(s, s.token.payload.ident.atom, "target"))
            {
                return Error.UnexpectedToken;
            }
            if (!s.new_target_allowed) return Error.UnexpectedToken;
            try s.advance();
            if (s.emit_to_function_def) {
                try s.emitScopeGetVar(atom_new_target);
            } else {
                try s.emitOpU8(opcode.op.special_object, 3);
            }
            return;
        }
        if (s.peekKind() == tok.TOK_NEW) {
            try parseNewExpr(s, flags);
            // The member tail following the inner NewExpression binds to the
            // inner `new`'s result: `new new F().m` is `new ((new F()).m)`.
            // qjs gets this from the recursive `js_parse_postfix_expr(s, 0)`
            // (`quickjs.c:27016`) whose postfix loop consumes `.x`/`[x]`
            // before the outer `new` applies.
            try parseNewCalleeMemberAccess(s, flags);
        } else if (s.peekKind() == tok.TOK_IMPORT) {
            if (s.peekNextKind() != @as(tok.TokenKind, @intCast('.'))) return Error.UnexpectedToken;
            try parsePrimary(s, flags);
            if (s.last_primary_was_arrow_function) return Error.UnexpectedToken;
            try parseNewCalleeMemberAccess(s, flags);
        } else {
            try parsePrimary(s, flags);
            if (s.last_primary_was_arrow_function) return Error.UnexpectedToken;
            try parseNewCalleeMemberAccess(s, flags);
        }
        if (s.peekKind() == @as(tok.TokenKind, @intCast('('))) {
            const call_line = s.token.line_num;
            const call_col = s.token.col_num;
            try s.emitOp(opcode.op.dup);
            const shape = try parseCallArgs(s, flags);
            s.last_anonymous_function_expr = false;
            switch (shape) {
                .direct => |argc| try s.emitOpU16At(opcode.op.call_constructor, argc, call_line, call_col),
                .applied => {
                    // `new X(...args)`. Stack here: [func, func(dup =
                    // new.target), array]. QuickJS FUNC_CALL_NEW emits
                    // `perm3 ; apply 1` (`quickjs.c:27359-27364`,
                    // "obj func array -> func obj array") so apply consumes
                    // the dup'd callee as the new.target slot. The previous
                    // `undefined ; swap` synthesized an extra `this` slot and
                    // left the dup'd callee on the stack, permanently
                    // off-balancing the verifier depth (StackMismatch at any
                    // merge point: try/catch bookkeeping, loop back-edges).
                    try s.emitOp(opcode.op.perm3);
                    try s.emitOpU16At(opcode.op.apply, 1, call_line, call_col); // 1 = is_new
                },
            }
        } else {
            // `new X` (no args) is equivalent to `new X()`.
            const call_line = s.token.line_num;
            const call_col = s.token.col_num;
            try s.emitOp(opcode.op.dup);
            try s.emitOpU16At(opcode.op.call_constructor, 0, call_line, call_col);
        }
    }

    fn parseNewCalleeMemberAccess(s: *State, flags: ParseFlags) Error!void {
        while (true) {
            const k = s.peekKind();
            if (k == @as(tok.TokenKind, @intCast('.'))) {
                try s.advance();
                const private_name = s.peekKind() == tok.TOK_PRIVATE_NAME;
                const raw_name = if (s.peekKind() == tok.TOK_IDENT or private_name)
                    s.token.payload.ident.atom
                else if (tok.isKeyword(s.peekKind()))
                    tok.keywordAtom(s.peekKind())
                else if (s.peekKind() == tok.TOK_DELETE)
                    @as(Atom, 9)
                else if (s.peekKind() == tok.TOK_CATCH)
                    @as(Atom, 25)
                else
                    return Error.UnexpectedToken;
                if (private_name and !s.in_class) return Error.UnexpectedToken;
                const private_atom = if (private_name) try privateNameAtom(s, raw_name) else null;
                defer if (private_atom) |atom_id| s.function.atoms.free(atom_id);
                if (private_atom) |atom_id| {
                    if (!classPrivateNameIsBound(s, atom_id)) return Error.UnexpectedToken;
                }
                const name = private_atom orelse raw_name;
                const retained_name = s.function.atoms.dup(name);
                defer s.function.atoms.free(retained_name);
                try s.advance();
                if (private_name) {
                    try s.emitOpAtomU16(opcode.op.scope_get_private_field, retained_name, @intCast(s.scope_level));
                } else {
                    try s.emitOpAtom(opcode.op.get_field, retained_name);
                }
            } else if (k == @as(tok.TokenKind, @intCast('['))) {
                try s.advance();
                try parseExpr(s);
                try expectPunct(s, ']');
                try s.emitOp(opcode.op.get_array_el);
            } else if (k == tok.TOK_TEMPLATE) {
                try parseTaggedTemplateInvocation(s);
            } else {
                _ = flags;
                return;
            }
        }
    }

    fn parseMemberChain(s: *State, flags: ParseFlags, optional_chain_label: *?ParserLabelRef) Error!void {
        while (true) {
            const k = s.peekKind();
            if (k == @as(tok.TokenKind, @intCast('.'))) {
                s.last_anonymous_function_expr = false;
                try s.advance();
                const private_name = s.peekKind() == tok.TOK_PRIVATE_NAME;
                const raw_name = if (s.peekKind() == tok.TOK_IDENT or private_name)
                    s.token.payload.ident.atom
                else if (tok.isKeyword(s.peekKind()))
                    tok.keywordAtom(s.peekKind())
                else if (s.peekKind() == tok.TOK_DELETE)
                    @as(Atom, 9)
                else if (s.peekKind() == tok.TOK_CATCH)
                    @as(Atom, 25)
                else
                    return Error.UnexpectedToken;
                if (private_name and !s.in_class) return Error.UnexpectedToken;
                const private_atom = if (private_name) try privateNameAtom(s, raw_name) else null;
                defer if (private_atom) |atom_id| s.function.atoms.free(atom_id);
                if (private_atom) |atom_id| {
                    if (s.last_was_super or !classPrivateNameIsBound(s, atom_id)) return Error.UnexpectedToken;
                }
                const name = private_atom orelse raw_name;
                const retained_name = s.function.atoms.dup(name);
                defer s.function.atoms.free(retained_name);
                try s.advance();
                const was_super = s.last_was_super;
                s.last_was_super = false;
                if (was_super) {
                    const fd = s.cur_func();
                    if (fd.last_opcode_pos < 0) return Error.UnexpectedToken;
                    const super_pos: usize = @intCast(fd.last_opcode_pos);
                    const code = s.currentCode();
                    if (super_pos + 1 != code.len or code[super_pos] != opcode.op.get_super) return Error.UnexpectedToken;
                    try s.truncateCode(super_pos);
                    try emitSuperThisAndHomeObject(s);
                    try s.emitOp(opcode.op.get_super);
                    try s.emitOpAtom(opcode.op.push_atom_value, retained_name);
                    try s.emitOp(opcode.op.get_super_value);
                } else if (private_name) {
                    try s.emitOpAtomU16(opcode.op.scope_get_private_field, retained_name, @intCast(s.scope_level));
                } else {
                    try s.emitOpAtom(opcode.op.get_field, retained_name);
                }
            } else if (k == tok.TOK_QUESTION_MARK_DOT) {
                s.last_anonymous_function_expr = false;
                if (s.last_was_super) return Error.UnexpectedToken;
                try s.advance();
                const next = s.peekKind();
                if (next == @as(tok.TokenKind, @intCast('('))) {
                    const call_line = s.token.line_num;
                    const call_col = s.token.col_num;
                    const prepared = try prepareCallReference(s, .normal, true);
                    try emitOptionalChainTest(s, optional_chain_label, prepared.optional_drop_count);
                    const shape = try parseCallArgs(s, flags);
                    s.last_anonymous_function_expr = false;
                    try emitPreparedCall(s, prepared, shape, call_line, call_col);
                } else if (next == @as(tok.TokenKind, @intCast('['))) {
                    try emitOptionalChainTest(s, optional_chain_label, 1);
                    try s.advance();
                    try parseExpr(s);
                    try expectPunct(s, ']');
                    try s.emitOp(opcode.op.get_array_el);
                } else if (next == tok.TOK_IDENT or next == tok.TOK_PRIVATE_NAME or tok.isKeyword(next) or next == tok.TOK_DELETE or next == tok.TOK_CATCH) {
                    try emitOptionalChainTest(s, optional_chain_label, 1);
                    const private_name = next == tok.TOK_PRIVATE_NAME;
                    const raw_name = if (next == tok.TOK_IDENT or private_name)
                        s.token.payload.ident.atom
                    else if (tok.isKeyword(next))
                        tok.keywordAtom(next)
                    else if (next == tok.TOK_DELETE)
                        @as(Atom, 9)
                    else if (next == tok.TOK_CATCH)
                        @as(Atom, 25)
                    else
                        unreachable;
                    if (private_name and !s.in_class) return Error.UnexpectedToken;
                    const private_atom = if (private_name) try privateNameAtom(s, raw_name) else null;
                    defer if (private_atom) |atom_id| s.function.atoms.free(atom_id);
                    if (private_atom) |atom_id| {
                        if (!classPrivateNameIsBound(s, atom_id)) return Error.UnexpectedToken;
                    }
                    const name = private_atom orelse raw_name;
                    const retained_name = s.function.atoms.dup(name);
                    defer s.function.atoms.free(retained_name);
                    try s.advance();
                    if (private_name) {
                        try s.emitOpAtomU16(opcode.op.scope_get_private_field, retained_name, @intCast(s.scope_level));
                    } else {
                        try s.emitOpAtom(opcode.op.get_field, retained_name);
                    }
                } else {
                    return Error.UnexpectedToken;
                }
            } else if (k == @as(tok.TokenKind, @intCast('['))) {
                s.last_anonymous_function_expr = false;
                const was_super = s.last_was_super;
                s.last_was_super = false;
                try s.advance();
                if (was_super) {
                    const fd = s.cur_func();
                    if (fd.last_opcode_pos < 0) return Error.UnexpectedToken;
                    const super_pos: usize = @intCast(fd.last_opcode_pos);
                    const code = s.currentCode();
                    if (super_pos + 1 != code.len or code[super_pos] != opcode.op.get_super) return Error.UnexpectedToken;
                    try s.truncateCode(super_pos);
                    try emitSuperThisAndHomeObject(s);
                    try s.emitOp(opcode.op.get_super);
                }
                try parseExpr(s);
                try expectPunct(s, ']');
                if (was_super) {
                    try s.emitOp(opcode.op.get_super_value);
                } else {
                    try s.emitOp(opcode.op.get_array_el);
                }
            } else if (k == @as(tok.TokenKind, @intCast('('))) {
                s.last_anonymous_function_expr = false;
                const callee_line = s.token.line_num;
                const callee_col = s.token.col_num;
                const was_super = s.last_was_super;
                s.last_was_super = false;
                if (was_super and !s.allow_super_call) return Error.UnexpectedToken;
                if (was_super) {
                    const active_func_idx = s.cur_func().this_active_func_var_idx;
                    const new_target_idx = s.cur_func().new_target_var_idx;
                    const this_idx = s.cur_func().this_var_idx;
                    if (active_func_idx < 0 or new_target_idx < 0 or this_idx < 0) {
                        try emitCapturedSuperConstructorCall(s, flags, .{ .line = callee_line, .col = callee_col });
                        s.last_anonymous_function_expr = false;
                        continue;
                    }
                    const code = s.currentCode();
                    if (code.len == 0 or code[code.len - 1] != opcode.op.get_super) return Error.UnexpectedToken;
                    try s.truncateCode(code.len - 1);
                    try s.emitOpU16(opcode.op.get_loc, @intCast(active_func_idx));
                    try s.emitOp(opcode.op.get_super);
                    try s.emitOpU16(opcode.op.get_loc, @intCast(new_target_idx));
                    const shape = try parseCallArgs(s, flags);
                    s.last_anonymous_function_expr = false;
                    switch (shape) {
                        .direct => |argc| try s.emitOpU16At(opcode.op.call_constructor, argc, callee_line, callee_col),
                        .applied => try s.emitOpU16At(opcode.op.apply, 1, callee_line, callee_col),
                    }
                    try s.emitOp(opcode.op.dup);
                    try s.emitOpU16(opcode.op.put_loc_check_init, @intCast(this_idx));
                    try emitClassFieldInitCall(s);
                    continue;
                }
                const prepared = try prepareCallReference(s, .normal, false);
                const shape = try parseCallArgs(s, flags);
                s.last_anonymous_function_expr = false;
                try emitPreparedCall(s, prepared, shape, callee_line, callee_col);
            } else if (k == tok.TOK_TEMPLATE) {
                if (optional_chain_label.* != null) return Error.UnexpectedToken;
                try parseTaggedTemplateInvocation(s);
            } else {
                break;
            }
        }
    }

    fn parseTaggedTemplateInvocation(s: *State) Error!void {
        s.last_anonymous_function_expr = false;
        const call_line = s.token.line_num;
        const call_col = s.token.col_num;
        const prepared = try prepareCallReference(s, .template, false);

        const first_part = s.token.payload.str.template orelse return Error.UnexpectedToken;
        if (first_part == .no_substitution) {
            if (s.runtime) |rt| {
                var builder = try TaggedTemplateObjectBuilder.init(rt);
                defer builder.deinit();
                try builder.addPart(s.token.payload.str.bytes, s.token.payload.str.raw_bytes, s.token.payload.str.cooked_invalid);
                try builder.finish();
                try s.emitPushConst(builder.template_value);
            } else {
                try emitTaggedTemplateSingletonObject(s, s.token.payload.str.bytes, s.token.payload.str.raw_bytes);
            }
            try s.advance();
            try emitPreparedCall(s, prepared, .{ .direct = 1 }, call_line, call_col);
            s.last_anonymous_function_expr = false;
            return;
        }

        var template_builder = if (s.runtime) |rt| try TaggedTemplateObjectBuilder.init(rt) else null;
        defer if (template_builder) |*builder| builder.deinit();
        if (template_builder) |*builder| {
            try s.emitPushConst(builder.template_value);
        } else {
            try s.emitOp(opcode.op.undefined); // parser-only fallback placeholder
        }
        var argc: u16 = 1; // template object counts as the first arg
        while (true) {
            const part = s.token.payload.str.template orelse return Error.UnexpectedToken;
            if (template_builder) |*builder| {
                try builder.addPart(s.token.payload.str.bytes, s.token.payload.str.raw_bytes, s.token.payload.str.cooked_invalid);
            }
            if (part == .no_substitution or part == .tail) {
                try s.advance();
                break;
            }
            try s.advance();
            try parseExpr(s);
            argc += 1;
            if (s.peekKind() != @as(tok.TokenKind, @intCast('}'))) return Error.UnexpectedToken;
            s.lex.freeToken(&s.token);
            s.token = try s.lex.nextTemplatePartAfterBrace();
        }
        if (template_builder) |*builder| try builder.finish();
        try emitPreparedCall(s, prepared, .{ .direct = argc }, call_line, call_col);
        s.last_anonymous_function_expr = false;
    }

    /// Result of parsing a `(...)` argument list. When the list contains a
    /// spread (`...x`), QuickJS switches to an `apply`-based lowering that
    /// builds an args array on the stack; the caller-side dispatch differs
    /// for normal call / method call / `new` / `super(...)`.
    const CallArgsShape = union(enum) {
        /// No spread. Stack contract: argc args on top of stack; caller
        /// emits `call`/`call_method`/`call_constructor` with this argc.
        direct: u16,
        /// One or more spreads. The args array is now on top of the stack
        /// (above whatever was there: func / obj+func / etc.). Caller is
        /// responsible for the final `apply <is_new>` opcode and any
        /// stack-rearrange (`undefined ; swap` for plain calls;
        /// `perm3` for method calls / `new`). Mirrors `quickjs.c:26667-26706`.
        applied,
    };

    /// Emit the QuickJS `optional_chain_test` sequence (`quickjs.c:26158`):
    ///
    ///     dup
    ///     is_undefined_or_null
    ///     if_false NEXT          ; if NOT null/undef, skip to NEXT
    ///     drop * drop_count       ; remove the dup'd receiver (and any
    ///                              ;   companion stack entries)
    ///     undefined               ; chain result on null/undef
    ///     goto CHAIN_EXIT         ; jump to chain end (patched later)
    ///     NEXT:                   ; resume normal access here
    ///
    /// The CHAIN_EXIT goto offset is recorded so `parseLhsExpr` can patch
    /// it to the post-chain byte. `drop_count` is 1 for member access
    /// (`?.b` / `?.[k]`) and 2 for method call after a member dup
    /// (`obj?.b()` / `?.()`); slice 7 only handles the member-access cases.
    fn emitOptionalChainTest(
        s: *State,
        optional_chain_label: *?ParserLabelRef,
        drop_count: u8,
    ) Error!void {
        const snapshot = s.takeEmissionSnapshot();
        const old_label = optional_chain_label.*;
        errdefer {
            s.rollbackEmission(snapshot);
            optional_chain_label.* = old_label;
        }
        if (optional_chain_label.* == null) optional_chain_label.* = newParserLabel(s);
        try s.emitOp(opcode.op.dup);
        try s.emitOp(opcode.op.is_undefined_or_null);
        const next_jump = try emitForwardJump(s, opcode.op.if_false);
        var i: u8 = 0;
        while (i < drop_count) : (i += 1) {
            try s.emitOp(opcode.op.drop);
        }
        try s.emitOp(opcode.op.undefined);
        try emitGotoParserLabelNoSource(s, optional_chain_label.*.?);
        try patchForwardJump(s, next_jump);
    }

    /// Parse a `(arg0, arg1, ...)` argument list and return the call shape.
    /// Caller consumed nothing yet — this consumes the leading `(` and the
    /// matching `)`.
    fn parseCallArgs(s: *State, flags: ParseFlags) Error!CallArgsShape {
        _ = flags;
        try expectPunct(s, '(');
        // Call arguments always parse with `PF_IN_ACCEPTED`
        // (`js_parse_assign_expr`, quickjs.c:26630/26744) — argument
        // positions reset the for-init no-`in` restriction.
        const arg_flags = ParseFlags.default;
        var argc: u16 = 0;
        var has_spread = false;
        while (s.peekKind() != @as(tok.TokenKind, @intCast(')'))) {
            if (s.peekKind() == tok.TOK_ELLIPSIS) {
                has_spread = true;
                break;
            }
            try parseAssignExpr2(s, arg_flags);
            argc += 1;
            if (s.peekKind() == @as(tok.TokenKind, @intCast(','))) {
                try s.advance();
                continue;
            }
            break;
        }
        if (!has_spread) {
            try expectPunct(s, ')');
            return .{ .direct = argc };
        }
        s.features.insert(.spread_rest);
        // Spread path mirrors `quickjs.c:26633..26664`. The leading args
        // become an array, then each remaining arg is appended (via the
        // iterator protocol for spread, via define_array_el+inc otherwise).
        try s.emitOpU16(opcode.op.array_from, argc);
        try s.emitOpI32(opcode.op.push_i32, @intCast(argc));
        while (s.peekKind() != @as(tok.TokenKind, @intCast(')'))) {
            if (s.peekKind() == tok.TOK_ELLIPSIS) {
                try s.advance();
                try parseAssignExpr2(s, arg_flags);
                try s.emitOp(opcode.op.append);
            } else {
                try parseAssignExpr2(s, arg_flags);
                try s.emitOp(opcode.op.define_array_el);
                try s.emitOp(opcode.op.inc);
            }
            if (s.peekKind() == @as(tok.TokenKind, @intCast(','))) {
                try s.advance();
                continue;
            }
            break;
        }
        try expectPunct(s, ')');
        try s.emitOp(opcode.op.drop); // drop the index, leave array on stack
        return .applied;
    }

    fn parseRegExpLiteral(s: *State) Error!void {
        const slash_offset = s.lex.mark_pos;
        s.lex.freeToken(&s.token);
        s.token = try s.lex.rescanRegexp(slash_offset);
        const pattern = s.token.payload.regexp.pattern;
        const flags = s.token.payload.regexp.flags;

        // QuickJS publishes the source pattern as the first constant-pool
        // operand before compiling the regexp. Keep the raw source spelling,
        // but decode its UTF-8 bytes into the runtime's Latin-1/UTF-16 string
        // representation instead of interning it as an atom.
        const pattern_string = core.string.String.createUtf8(s.runtime.?, pattern) catch |err| switch (err) {
            error.OutOfMemory, error.StringTooLong => return Error.OutOfMemory,
            error.InvalidUtf8 => return Error.InvalidUtf8,
        };
        try s.emitPushConstOwned(pattern_string.value());

        var compiled = regexp_lib.compilePatternAndFlags(s.function.memory.allocator, pattern, flags) catch |err| switch (err) {
            error.OutOfMemory => return Error.OutOfMemory,
            else => return Error.InvalidRegExp,
        };
        defer compiled.deinit(s.function.memory.allocator);
        // qjs compiles a literal once while parsing, stores the lre bytecode as
        // an 8-bit JSString constant, and lets OP_regexp share that immutable
        // string with each fresh RegExp instance (quickjs.c:26891-26913,
        // 47565-47668). ZJS used to discard this validation result and emit the
        // flags string, forcing the runtime constructor to compile on every
        // literal evaluation.
        const compiled_string = core.string.String.createLatin1(s.runtime.?, compiled.bytecode) catch |err| switch (err) {
            error.OutOfMemory, error.StringTooLong => return Error.OutOfMemory,
        };
        try s.emitPushConstOwned(compiled_string.value());
        try s.emitOp(opcode.op.regexp);
        try s.advance();
    }

    /// Parse a primary expression. `js_parse_primary_expr` lives inside
    /// `js_parse_postfix_expr` in QuickJS (`quickjs.c:25500..25800`).
    fn parsePrimary(s: *State, flags: ParseFlags) Error!void {
        const k = s.peekKind();
        s.last_primary_was_arrow_function = false;
        switch (k) {
            tok.TOK_NUMBER => {
                const value = s.token.payload.num.value;
                // Encode small integers with push_i32 to match QuickJS.
                if (s.token.payload.num.is_bigint) {
                    try s.emitBigIntLiteral(s.token.payload.num.bigint_text, false);
                } else if (numberIsExactI32(value)) {
                    try s.emitOpI32(opcode.op.push_i32, @as(i32, @intFromFloat(value)));
                } else {
                    try s.emitPushConst(JSValue.float64(value));
                }
                try s.advance();
            },
            tok.TOK_STRING => {
                // QuickJS emits `OP_push_atom_value <atom>` here, including
                // for the empty string. resolve_labels selects the short
                // push_empty_string form only when the value stays live.
                try emitStringLiteralValue(s, s.token.payload.str.bytes);
                try s.advance();
            },
            @as(tok.TokenKind, @intCast('/')), tok.TOK_DIV_ASSIGN => try parseRegExpLiteral(s),
            tok.TOK_TEMPLATE => return parseTemplate(s, flags),
            tok.TOK_TRUE => {
                try s.emitOp(opcode.op.push_true);
                try s.advance();
            },
            tok.TOK_FALSE => {
                try s.emitOp(opcode.op.push_false);
                try s.advance();
            },
            tok.TOK_NULL => {
                try s.emitOp(opcode.op.null);
                try s.advance();
            },
            tok.TOK_THIS => {
                try s.emitThisValue();
                try s.advance();
                s.last_was_super = false;
            },
            tok.TOK_SUPER => {
                if (!s.allow_super) return Error.UnexpectedToken;
                // Emit get_super; runtime semantics depend on constructor context.
                try s.emitOp(opcode.op.get_super);
                try s.advance();
                s.last_was_super = true;
            },
            tok.TOK_IMPORT => {
                if (s.peekNextKind() == @as(tok.TokenKind, @intCast('.'))) {
                    if (!s.lex.is_module or s.is_eval) return Error.UnexpectedToken;
                    try s.advance();
                    try s.advance();
                    if (s.peekKind() != tok.TOK_IDENT or
                        s.token.payload.ident.has_escape or
                        !atomNameEquals(s, s.token.payload.ident.atom, "meta"))
                    {
                        return Error.UnexpectedToken;
                    }
                    try s.advance();
                    try s.emitOpU8(opcode.op.special_object, opcode.special_object_subtype.import_meta);
                    s.last_was_super = false;
                    return;
                }
                try parseDynamicImportCall(s, flags);
                s.last_was_super = false;
            },
            tok.TOK_CLASS => {
                // Class expression
                try parseClass(s, false);
            },
            tok.TOK_FUNCTION => {
                // Function expression: function or async function
                // Check for async function
                const is_async = s.isIdent("async");
                const source_start = s.currentTokenStartOffset();
                if (is_async) {
                    try s.advance();
                }
                const func_kind: ParseFunctionKind = if (is_async) .async else .normal;
                try parseFunctionExpr(s, func_kind, source_start);
            },
            tok.TOK_IDENT,
            tok.TOK_AWAIT,
            tok.TOK_YIELD,
            tok.TOK_STATIC,
            tok.TOK_IMPLEMENTS,
            tok.TOK_INTERFACE,
            tok.TOK_PACKAGE,
            tok.TOK_PRIVATE,
            tok.TOK_PROTECTED,
            tok.TOK_PUBLIC,
            => {
                if (!isIdentifierLikeToken(s)) return Error.UnexpectedToken;
                if (s.peekKind() == tok.TOK_AWAIT and !canUseAwaitAsIdentifier(s)) return Error.AwaitOutsideAsyncFunction;
                if (s.peekKind() == tok.TOK_YIELD and (s.in_generator or s.is_strict or s.cur_func().is_strict_mode)) return Error.YieldOutsideGenerator;
                if (s.peekKind() == tok.TOK_IDENT and
                    escapedIdentifierIsReservedWordForCurrentContext(s, s.token.payload.ident.atom, s.token.payload.ident.has_escape))
                {
                    return Error.UnexpectedToken;
                }
                if (s.peekKind() == tok.TOK_IDENT and
                    s.token.payload.ident.has_escape and
                    atomNameEquals(s, s.token.payload.ident.atom, "import") and
                    s.peekNextKind() == @as(tok.TokenKind, @intCast('(')))
                {
                    return Error.UnexpectedToken;
                }
                if (s.peekKind() == tok.TOK_IDENT and
                    s.token.payload.ident.has_escape and
                    atomNameEquals(s, s.token.payload.ident.atom, "import") and
                    s.peekNextKind() == @as(tok.TokenKind, @intCast('.')))
                {
                    return Error.UnexpectedToken;
                }
                if (checkAsyncSingleParamArrowHead(s)) {
                    const source_start = s.currentTokenStartOffset();
                    try s.advance(); // consume async
                    try parseArrowFunction(s, .async, source_start, flags);
                    s.last_primary_was_arrow_function = true;
                    return;
                }
                if (checkAsyncParenArrowHead(s)) {
                    const source_start = s.currentTokenStartOffset();
                    try s.advance(); // consume async
                    try parseArrowFunction(s, .async, source_start, flags);
                    s.last_primary_was_arrow_function = true;
                    return;
                }
                // Check for async function (async is a contextual keyword)
                if (s.isIdent("async") and s.peekNextKindNoLineTerminator(tok.TOK_FUNCTION)) {
                    const source_start = s.currentTokenStartOffset();
                    try s.advance(); // consume async
                    const func_kind: ParseFunctionKind = .async;
                    try parseFunctionExpr(s, func_kind, source_start);
                    s.last_was_super = false;
                    return;
                }
                // Check if this is an arrow function: ident => or async ident =>
                // Use proper lexer state save/restore for the lookahead so we
                // don't desynchronize the lexer position from the cached token.
                if (checkIdentArrowHead(s)) {
                    // Check for async arrow function
                    const is_async = s.isIdent("async");
                    const func_kind: ParseFunctionKind = if (is_async) .async else .normal;
                    const source_start = s.currentTokenStartOffset();
                    if (is_async) {
                        try s.advance();
                    }
                    try parseArrowFunction(s, func_kind, source_start, flags);
                    s.last_primary_was_arrow_function = true;
                    return;
                }
                const ident = identifierLikeAtom(s);
                if (argumentsIdentifierIsForbidden(s) and atomNameEquals(s, ident, "arguments")) {
                    return Error.UnexpectedToken;
                }
                // Identifier production is independent of its consumer.
                // Assignment and call sites rewrite this exact last opcode
                // after the complete operand has been parsed.
                try s.emitScopeGetVar(ident);
                try s.advance();
                s.last_was_super = false;
            },
            tok.TOK_LET => {
                if (s.is_strict or s.cur_func().is_strict_mode) return Error.UnexpectedToken;
                try s.emitScopeGetVar(tok.keywordAtom(tok.TOK_LET));
                try s.advance();
                s.last_was_super = false;
            },
            else => {
                if (k == @as(tok.TokenKind, @intCast('('))) {
                    // Check if this is an arrow function
                    if (checkArrowHead(s)) {
                        // Check for async arrow function
                        const is_async = s.isIdent("async");
                        const func_kind: ParseFunctionKind = if (is_async) .async else .normal;
                        const source_start = s.currentTokenStartOffset();
                        if (is_async) {
                            try s.advance();
                        }
                        try parseArrowFunction(s, func_kind, source_start, flags);
                        s.last_primary_was_arrow_function = true;
                        return;
                    }
                    try s.advance();
                    // Parenthesized group: mirrors `js_parse_expr_paren`
                    // (`quickjs.c:26195`) -> `js_parse_expr` which parses
                    // with `PF_IN_ACCEPTED` set — grouping resets the
                    // for-init no-`in` restriction (and unary-context
                    // restrictions like the yield guard).
                    try parseExpr2(s, ParseFlags.default);
                    try expectPunct(s, ')');
                    return;
                }
                if (k == @as(tok.TokenKind, @intCast('['))) {
                    return parseArrayLiteral(s, flags);
                }
                if (k == @as(tok.TokenKind, @intCast('{'))) {
                    return parseObjectLiteral(s, flags);
                }
                return Error.UnexpectedToken;
            },
        }
    }

    fn parseDynamicImportCall(s: *State, flags: ParseFlags) Error!void {
        _ = flags;
        s.features.insert(.dynamic_import);
        try s.advance();
        try expectPunct(s, '(');
        const import_flags = ParseFlags.default;
        try parseAssignExpr2(s, import_flags);
        if (s.peekKind() == @as(tok.TokenKind, @intCast(','))) {
            try s.advance();
            if (s.peekKind() == @as(tok.TokenKind, @intCast(')'))) {
                try s.emitOp(opcode.op.undefined);
            } else {
                try parseAssignExpr2(s, import_flags);
                if (s.peekKind() == @as(tok.TokenKind, @intCast(','))) try s.advance();
            }
        } else {
            try s.emitOp(opcode.op.undefined);
        }
        try expectPunct(s, ')');
        try s.emitOp(opcode.op.import);
        // ImportCall itself evaluates to a Promise. An anonymous function in
        // either argument is nested and must not escape as the named-
        // evaluation result of an enclosing declaration (qjs clears
        // `func_name` after parsing call arguments).
        s.last_anonymous_function_expr = false;
    }

    /// `js_parse_template` (`quickjs.c:23880`). Non-tagged template literals
    /// lower `\`a${b}c${d}e\`` to:
    ///
    ///     push_atom_value "a"
    ///     get_field2 concat
    ///     <expr b>
    ///     push_atom_value "c"
    ///     <expr d>
    ///     push_atom_value "e"
    ///     call_method <depth-1>
    ///
    /// matching QuickJS's `String.prototype.concat`-based concatenation
    /// strategy. Empty middle/tail strings are skipped (unless they are the
    /// only content, where depth==0 forces an emit). Tagged templates
    /// (`tag\`...\``) and lazy raw-string evaluation follow the `call=1`
    /// branch in `js_parse_template`.
    fn parseTemplate(s: *State, flags: ParseFlags) Error!void {
        _ = flags;
        var depth: u16 = 0;
        while (s.peekKind() == tok.TOK_TEMPLATE) {
            const part_payload = s.token.payload.str;
            const bytes = part_payload.bytes;
            const part = part_payload.template orelse return Error.UnexpectedToken;
            if (part_payload.cooked_invalid) return Error.InvalidEscape;

            if (bytes.len != 0 or depth == 0) {
                try emitStringLiteralValue(s, bytes);
                if (depth == 0) {
                    if (part == .no_substitution) {
                        // Whole template is a single string constant; skip
                        // the concat-method setup and just consume the token.
                        try s.advance();
                        return;
                    }
                    const concat_atom = try s.function.atoms.internString("concat");
                    defer s.function.atoms.free(concat_atom);
                    try s.emitOpAtom(opcode.op.get_field2, concat_atom);
                }
                depth += 1;
            }

            if (part == .tail) {
                try s.emitOpU16(opcode.op.call_method, depth - 1);
                try s.advance(); // consume the tail TOK_TEMPLATE
                return;
            }
            // .head or .middle: parse the substitution expression and
            // resume template lexing after the closing `}`.
            try s.advance(); // consume head/middle TOK_TEMPLATE
            try parseExpr(s);
            depth += 1;
            if (s.peekKind() != @as(tok.TokenKind, @intCast('}'))) return Error.UnexpectedToken;
            // The lookahead `}` has already moved lex.pos one byte past it;
            // free the token and ask the lexer for the next template part
            // (middle or tail) without re-bumping.
            s.lex.freeToken(&s.token);
            s.token = try s.lex.nextTemplatePartAfterBrace();
        }
        return Error.UnexpectedToken;
    }

    fn emitTaggedTemplateSingletonObject(s: *State, bytes: []const u8, raw_bytes: []const u8) Error!void {
        const cooked_atom = try s.function.atoms.internString(bytes);
        defer s.function.atoms.free(cooked_atom);
        try s.emitOpAtom(opcode.op.push_atom_value, cooked_atom);
        try s.emitOpU16(opcode.op.array_from, 1);

        const raw_atom = try s.function.atoms.internString(raw_bytes);
        defer s.function.atoms.free(raw_atom);
        try s.emitOpAtom(opcode.op.push_atom_value, raw_atom);
        try s.emitOpU16(opcode.op.array_from, 1);

        const raw_name = try s.function.atoms.internString("raw");
        defer s.function.atoms.free(raw_name);
        try s.emitOpAtom(opcode.op.define_field, raw_name);
    }

    const TaggedTemplateObjectBuilder = struct {
        rt: *core.JSRuntime,
        template_value: JSValue,
        raw_value: JSValue,
        template_object: *core.Object,
        raw_array: *core.Object,
        depth: u32 = 0,

        fn init(rt: *core.JSRuntime) Error!TaggedTemplateObjectBuilder {
            const template_object = core.Object.createArray(rt, null) catch return Error.OutOfMemory;
            errdefer core.Object.destroyFromHeader(rt, &template_object.header);
            const raw_array = core.Object.createArray(rt, null) catch return Error.OutOfMemory;
            errdefer core.Object.destroyFromHeader(rt, &raw_array.header);

            const raw_value = raw_array.value();
            const raw_atom = try rt.internAtom("raw");
            defer rt.atoms.free(raw_atom);
            template_object.defineOwnProperty(rt, raw_atom, core.Descriptor.data(raw_value, false, false, false)) catch return Error.UnexpectedToken;
            return .{
                .rt = rt,
                .template_value = template_object.value(),
                .raw_value = raw_value,
                .template_object = template_object,
                .raw_array = raw_array,
            };
        }

        fn deinit(self: *TaggedTemplateObjectBuilder) void {
            self.template_value.free(self.rt);
            self.raw_value.free(self.rt);
        }

        fn addPart(
            self: *TaggedTemplateObjectBuilder,
            cooked_bytes: []const u8,
            raw_bytes: []const u8,
            cooked_invalid: bool,
        ) Error!void {
            const cooked_value = if (cooked_invalid) core.JSValue.undefinedValue() else blk: {
                const cooked = core.string.String.createUtf8(self.rt, cooked_bytes) catch return Error.InvalidUtf8;
                break :blk cooked.value();
            };
            defer cooked_value.free(self.rt);
            self.template_object.defineOwnProperty(
                self.rt,
                core.atom.atomFromUInt32(self.depth),
                core.Descriptor.data(cooked_value, true, true, true),
            ) catch return Error.UnexpectedToken;

            const raw = core.string.String.createUtf8(self.rt, raw_bytes) catch return Error.InvalidUtf8;
            const raw_value = raw.value();
            defer raw_value.free(self.rt);
            self.raw_array.defineOwnProperty(
                self.rt,
                core.atom.atomFromUInt32(self.depth),
                core.Descriptor.data(raw_value, true, true, true),
            ) catch return Error.UnexpectedToken;
            self.depth += 1;
        }

        fn finish(self: *TaggedTemplateObjectBuilder) Error!void {
            self.raw_array.freeze(self.rt) catch return Error.OutOfMemory;
            self.template_object.freeze(self.rt) catch return Error.OutOfMemory;
        }
    };

    /// `js_parse_array_literal` (`quickjs.c:25194`). The QuickJS strategy
    /// switches dynamically: leading
    /// non-spread elements collect into an `array_from <count>`; on the
    /// first spread, the parser pushes `<count>` as the running index,
    /// then alternates between `define_array_el; inc` (for plain entries)
    /// and `append` (for spread entries). The trailing `drop` removes
    /// the index, leaving the constructed array on the stack.
    fn parseArrayLiteral(s: *State, flags: ParseFlags) Error!void {
        _ = flags;
        try s.advance(); // consume '['
        var count: u16 = 0;
        var sparse_active = false;
        var sparse_index: u32 = 0;
        var spread_active = false;
        while (s.peekKind() != @as(tok.TokenKind, @intCast(']'))) {
            if (s.peekKind() == @as(tok.TokenKind, @intCast(','))) {
                // Hole — leading or interior. QuickJS switches to an
                // object-style sparse array shape: `array_from <dense-prefix>`
                // followed by `define_field "<index>"` for present elements.
                if (spread_active) {
                    try s.emitOp(opcode.op.inc);
                } else {
                    if (!sparse_active) {
                        try s.emitOpU16(opcode.op.array_from, count);
                        sparse_active = true;
                        sparse_index = count;
                    }
                    sparse_index += 1;
                }
                try s.advance();
                continue;
            }
            if (s.peekKind() == tok.TOK_ELLIPSIS) {
                s.features.insert(.spread_rest);
                if (!spread_active) {
                    // Switch from collect-then-array_from to running-array
                    // mode. Emit array_from on the leading elements and push
                    // <count> as the initial index.
                    try s.emitOpU16(opcode.op.array_from, count);
                    try s.emitOpI32(opcode.op.push_i32, @intCast(count));
                    spread_active = true;
                }
                try s.advance();
                // Array elements always parse with `PF_IN_ACCEPTED`
                // (`js_parse_assign_expr`, quickjs.c:28283) — the bracket
                // resets the for-init no-`in` restriction.
                try parseAssignExprWithoutPendingFunctionName(s, ParseFlags.default);
                s.last_anonymous_function_expr = false;
                try s.emitOp(opcode.op.append);
            } else {
                try parseAssignExprWithoutPendingFunctionName(s, ParseFlags.default);
                s.last_anonymous_function_expr = false;
                if (spread_active) {
                    try s.emitOp(opcode.op.define_array_el);
                    try s.emitOp(opcode.op.inc);
                } else if (sparse_active) {
                    var index_buf: [16]u8 = undefined;
                    const index_name = std.fmt.bufPrint(&index_buf, "{d}", .{sparse_index}) catch return Error.UnexpectedToken;
                    const index_atom = try s.function.atoms.internString(index_name);
                    defer s.function.atoms.free(index_atom);
                    try s.emitOpAtom(opcode.op.define_field, index_atom);
                    sparse_index += 1;
                } else {
                    count += 1;
                }
            }
            if (s.peekKind() == @as(tok.TokenKind, @intCast(','))) {
                try s.advance();
                continue;
            }
            break;
        }
        try expectPunct(s, ']');
        if (spread_active) {
            try s.emitOp(opcode.op.dup1);
            try s.emitOpAtom(opcode.op.put_field, atom_module.ids.length);
        } else if (!sparse_active) {
            try s.emitOpU16(opcode.op.array_from, count);
        } else {
            try s.emitOp(opcode.op.dup);
            try s.emitOpI32(opcode.op.push_i32, @intCast(sparse_index));
            try s.emitOpAtom(opcode.op.put_field, atom_module.ids.length);
        }
    }

    /// `js_parse_object_literal` (`quickjs.c:24361`). Supports ordinary,
    /// shorthand, computed, method, accessor, spread, and `__proto__` forms.
    fn parseObjectLiteral(s: *State, flags: ParseFlags) Error!void {
        try s.advance(); // consume '{'
        try s.emitOp(opcode.op.object);
        var proto_field_seen = false;
        if (s.peekKind() != @as(tok.TokenKind, @intCast('}'))) {
            while (true) {
                try parseObjectProperty(s, flags, &proto_field_seen);
                if (s.peekKind() == @as(tok.TokenKind, @intCast(','))) {
                    try s.advance();
                    if (s.peekKind() == @as(tok.TokenKind, @intCast('}'))) break;
                    continue;
                }
                break;
            }
        }
        try expectPunct(s, '}');
    }

    fn parseObjectProperty(s: *State, flags: ParseFlags, proto_field_seen: *bool) Error!void {
        _ = flags;
        const k = s.peekKind();
        const property_source_start = s.currentTokenStartOffset();
        // Property keys/values always parse with `PF_IN_ACCEPTED`
        // (`js_parse_assign_expr`, quickjs.c:28283) — the object literal
        // resets the for-init no-`in` restriction.
        const computed_flags = ParseFlags.default;

        // Spread property: ...obj
        if (k == tok.TOK_ELLIPSIS) {
            s.features.insert(.spread_rest);
            try s.advance();
            try parseAssignExpr2(s, ParseFlags.default);
            try s.emitOp(opcode.op.null); // dummy excludeList, matching QuickJS object-spread lowering
            try s.emitOpU8(opcode.op.copy_data_properties, 2 | (1 << 2) | (0 << 5));
            try s.emitOp(opcode.op.drop); // excludeList
            try s.emitOp(opcode.op.drop); // source
            return;
        }

        if (k == @as(tok.TokenKind, @intCast('*'))) {
            try s.advance();
            if (s.peekKind() == @as(tok.TokenKind, @intCast('['))) {
                try s.advance();
                try parseAssignExpr2(s, computed_flags);
                try expectPunct(s, ']');
                if (s.peekKind() != @as(tok.TokenKind, @intCast('('))) return Error.UnexpectedToken;
                try emitObjectMethodFunction(s, null, .generator, property_source_start);
                try s.emitOpU8(opcode.op.define_method_computed, 4);
                return;
            }
            const name_info = (try parseObjectPropertyName(s)) orelse return Error.UnexpectedToken;
            const name = name_info.atom;
            defer if (name_info.retained) s.function.atoms.free(name);
            if (s.peekKind() != @as(tok.TokenKind, @intCast('('))) return Error.UnexpectedToken;
            try emitObjectMethodFunction(s, null, .generator, property_source_start);
            try s.emitOpAtomU8(opcode.op.define_method, name, 4);
            return;
        }

        if (k == tok.TOK_IDENT and s.isIdent("async") and
            s.peekNextKind() != @as(tok.TokenKind, @intCast(':')) and
            s.peekNextKind() != @as(tok.TokenKind, @intCast('(')) and
            s.peekNextKind() != @as(tok.TokenKind, @intCast(',')) and
            s.peekNextKind() != @as(tok.TokenKind, @intCast('}')))
        {
            try s.advance();
            if (s.gotLineTerminator()) return Error.UnexpectedToken;
            const func_kind: ParseFunctionKind = if (s.peekKind() == @as(tok.TokenKind, @intCast('*'))) blk: {
                try s.advance();
                break :blk .async_generator;
            } else .async;
            if (s.peekKind() == @as(tok.TokenKind, @intCast('['))) {
                try s.advance();
                try parseAssignExpr2(s, computed_flags);
                try expectPunct(s, ']');
                if (s.peekKind() != @as(tok.TokenKind, @intCast('('))) return Error.UnexpectedToken;
                try emitObjectMethodFunction(s, null, func_kind, property_source_start);
                try s.emitOpU8(opcode.op.define_method_computed, 4);
                return;
            }
            const name_info = (try parseObjectPropertyName(s)) orelse return Error.UnexpectedToken;
            const name = name_info.atom;
            defer if (name_info.retained) s.function.atoms.free(name);
            if (s.peekKind() != @as(tok.TokenKind, @intCast('('))) return Error.UnexpectedToken;
            try emitObjectMethodFunction(s, null, func_kind, property_source_start);
            try s.emitOpAtomU8(opcode.op.define_method, name, 4);
            return;
        }

        // Computed property name: [expr]: value
        if (k == @as(tok.TokenKind, @intCast('['))) {
            try s.advance();
            s.features.insert(.expression);
            try parseAssignExpr2(s, computed_flags);
            try expectPunct(s, ']');
            if (s.peekKind() == @as(tok.TokenKind, @intCast('('))) {
                try emitObjectMethodFunction(s, null, .method, property_source_start);
                try s.emitOpU8(opcode.op.define_method_computed, 4);
            } else {
                try expectPunct(s, ':');
                try s.emitOp(opcode.op.to_propkey);
                try parseAssignExprWithPendingFunctionName(s, ParseFlags.default, null);
                if (s.last_anonymous_function_expr) {
                    try s.emitOp(opcode.op.set_name_computed);
                    s.last_anonymous_function_expr = false;
                }
                try s.emitOp(opcode.op.define_array_el);
                try s.emitOp(opcode.op.drop);
            }
            return;
        }

        if (try parseObjectPropertyName(s)) |name_info| {
            const name = name_info.atom;
            defer if (name_info.retained) s.function.atoms.free(name);
            const is_getter = !name_info.has_escape and atomNameEquals(s, name, "get");
            const is_setter = !name_info.has_escape and atomNameEquals(s, name, "set");
            if ((is_getter or is_setter) and
                s.peekKind() != @as(tok.TokenKind, @intCast(':')) and
                s.peekKind() != @as(tok.TokenKind, @intCast('(')))
            {
                try parseObjectAccessorProperty(s, computed_flags, if (is_getter) .get else .set, if (is_getter) 1 else 2, property_source_start);
            } else if (s.peekKind() == @as(tok.TokenKind, @intCast(':'))) {
                try s.advance();
                try parseAssignExprWithPendingFunctionName(s, ParseFlags.default, if (name_info.is_proto) null else name);
                if (name_info.is_proto) {
                    if (proto_field_seen.*) return Error.UnexpectedToken;
                    proto_field_seen.* = true;
                    try s.emitOp(opcode.op.set_proto);
                } else {
                    if (s.last_anonymous_function_expr) {
                        try s.emitOpAtom(opcode.op.set_name, name);
                        s.last_anonymous_function_expr = false;
                    }
                    try s.emitOpAtom(opcode.op.define_field, name);
                }
            } else if (s.peekKind() == @as(tok.TokenKind, @intCast('('))) {
                try emitObjectMethodFunction(s, null, .method, property_source_start);
                try s.emitOpAtomU8(opcode.op.define_method, name, 4);
            } else if (name_info.allow_shorthand) {
                // Shorthand `{ x }` is an ordinary identifier read. Keep the
                // producer uniform and let scope resolution decide whether a
                // surrounding with-object supplies the value.
                try s.emitScopeGetVar(name);
                try s.emitOpAtom(opcode.op.define_field, name);
            } else {
                return Error.UnexpectedToken;
            }
            return;
        }
        return Error.UnexpectedToken;
    }

    fn parseObjectAccessorProperty(
        s: *State,
        flags: ParseFlags,
        func_kind: ParseFunctionKind,
        define_flags: u8,
        source_start: usize,
    ) Error!void {
        if (s.peekKind() == @as(tok.TokenKind, @intCast('['))) {
            try s.advance();
            try parseAssignExpr2(s, flags);
            try expectPunct(s, ']');
            if (s.peekKind() != @as(tok.TokenKind, @intCast('('))) return Error.UnexpectedToken;
            try emitObjectMethodFunction(s, null, func_kind, source_start);
            try s.emitOpU8(opcode.op.define_method_computed, define_flags | 4);
            return;
        }

        const name_info = (try parseObjectPropertyName(s)) orelse return Error.UnexpectedToken;
        const name = name_info.atom;
        defer if (name_info.retained) s.function.atoms.free(name);
        if (s.peekKind() != @as(tok.TokenKind, @intCast('('))) return Error.UnexpectedToken;
        try emitObjectMethodFunction(s, null, func_kind, source_start);
        try s.emitOpAtomU8(opcode.op.define_method, name, define_flags | 4);
    }

    const ObjectPropertyName = struct {
        atom: Atom,
        is_proto: bool,
        allow_shorthand: bool,
        has_escape: bool,
        retained: bool,
    };

    fn parseObjectPropertyName(s: *State) Error!?ObjectPropertyName {
        const k = s.peekKind();
        var atom_id: Atom = undefined;
        var retained = false;
        var allow_shorthand = false;
        var has_escape = false;

        if (k == tok.TOK_IDENT or (k == tok.TOK_AWAIT and canUseAwaitAsIdentifier(s))) {
            atom_id = if (k == tok.TOK_IDENT) s.token.payload.ident.atom else tok.keywordAtom(k);
            has_escape = k == tok.TOK_IDENT and s.token.payload.ident.has_escape;
            allow_shorthand = k == tok.TOK_AWAIT or !escapedIdentifierIsReservedWordForShorthandBinding(s, atom_id, has_escape);
            try s.advance();
        } else if (tok.isKeyword(k)) {
            atom_id = tok.keywordAtom(k);
            allow_shorthand = (k == tok.TOK_YIELD and !s.in_generator and !(s.is_strict or s.cur_func().is_strict_mode)) or
                (k == tok.TOK_LET and !(s.is_strict or s.cur_func().is_strict_mode));
            try s.advance();
        } else if (k == tok.TOK_STRING) {
            atom_id = try s.function.atoms.internString(s.token.payload.str.bytes);
            retained = true;
            try s.advance();
        } else if (k == tok.TOK_NUMBER) {
            const is_bigint = s.token.payload.num.is_bigint;
            const text = if (is_bigint)
                try formatBigIntPropertyName(s, s.token.payload.num.bigint_text)
            else blk: {
                var buf: [32]u8 = undefined;
                break :blk formatFiniteNumber(&buf, s.token.payload.num.value) catch
                    return Error.InvalidNumberLiteral;
            };
            defer if (is_bigint) s.function.memory.allocator.free(text);
            atom_id = try s.function.atoms.internString(text);
            retained = true;
            try s.advance();
        } else {
            return null;
        }
        return .{
            .atom = atom_id,
            .is_proto = atomNameEquals(s, atom_id, "__proto__"),
            .allow_shorthand = allow_shorthand,
            .has_escape = has_escape,
            .retained = retained,
        };
    }

    fn escapedIdentifierIsReservedWordForBinding(s: *State, atom_id: Atom, has_escape: bool) bool {
        if (!has_escape) return false;
        const name = s.function.atoms.name(atom_id) orelse return false;
        const strict = s.is_strict or s.cur_func().is_strict_mode;
        return std.mem.eql(u8, name, "null") or
            std.mem.eql(u8, name, "false") or
            std.mem.eql(u8, name, "true") or
            std.mem.eql(u8, name, "if") or
            std.mem.eql(u8, name, "else") or
            std.mem.eql(u8, name, "return") or
            std.mem.eql(u8, name, "var") or
            std.mem.eql(u8, name, "this") or
            std.mem.eql(u8, name, "delete") or
            std.mem.eql(u8, name, "void") or
            std.mem.eql(u8, name, "typeof") or
            std.mem.eql(u8, name, "new") or
            std.mem.eql(u8, name, "in") or
            std.mem.eql(u8, name, "instanceof") or
            std.mem.eql(u8, name, "do") or
            std.mem.eql(u8, name, "while") or
            std.mem.eql(u8, name, "for") or
            std.mem.eql(u8, name, "break") or
            std.mem.eql(u8, name, "continue") or
            std.mem.eql(u8, name, "switch") or
            std.mem.eql(u8, name, "case") or
            std.mem.eql(u8, name, "default") or
            std.mem.eql(u8, name, "throw") or
            std.mem.eql(u8, name, "try") or
            std.mem.eql(u8, name, "catch") or
            std.mem.eql(u8, name, "finally") or
            std.mem.eql(u8, name, "function") or
            std.mem.eql(u8, name, "debugger") or
            std.mem.eql(u8, name, "with") or
            std.mem.eql(u8, name, "class") or
            std.mem.eql(u8, name, "const") or
            std.mem.eql(u8, name, "enum") or
            std.mem.eql(u8, name, "export") or
            std.mem.eql(u8, name, "extends") or
            std.mem.eql(u8, name, "import") or
            std.mem.eql(u8, name, "super") or
            (strict and (std.mem.eql(u8, name, "implements") or
                std.mem.eql(u8, name, "interface") or
                std.mem.eql(u8, name, "let") or
                std.mem.eql(u8, name, "package") or
                std.mem.eql(u8, name, "private") or
                std.mem.eql(u8, name, "protected") or
                std.mem.eql(u8, name, "public") or
                std.mem.eql(u8, name, "static"))) or
            ((s.in_generator or strict) and std.mem.eql(u8, name, "yield")) or
            ((s.in_async or s.lex.is_module or s.in_class_static_block) and std.mem.eql(u8, name, "await"));
    }

    fn escapedIdentifierIsReservedWordForShorthandBinding(s: *State, atom_id: Atom, has_escape: bool) bool {
        if (!has_escape) return false;
        const name = s.function.atoms.name(atom_id) orelse return false;
        return escapedIdentifierIsReservedWordForBinding(s, atom_id, has_escape) or
            std.mem.eql(u8, name, "implements") or
            std.mem.eql(u8, name, "interface") or
            std.mem.eql(u8, name, "let") or
            std.mem.eql(u8, name, "package") or
            std.mem.eql(u8, name, "private") or
            std.mem.eql(u8, name, "protected") or
            std.mem.eql(u8, name, "public") or
            std.mem.eql(u8, name, "static") or
            std.mem.eql(u8, name, "yield");
    }

    fn escapedIdentifierIsReservedWordForCurrentContext(s: *State, atom_id: Atom, has_escape: bool) bool {
        return has_escape and
            (escapedIdentifierIsReservedWordForBinding(s, atom_id, has_escape) or
                atomNameEquals(s, atom_id, "null") or
                atomNameEquals(s, atom_id, "false") or
                atomNameEquals(s, atom_id, "true") or
                (s.in_async and atomNameEquals(s, atom_id, "await")) or
                (s.lex.is_module and atomNameEquals(s, atom_id, "await")) or
                (s.in_class_static_block and atomNameEquals(s, atom_id, "await")) or
                (s.in_generator and atomNameEquals(s, atom_id, "yield")) or
                ((s.is_strict or s.cur_func().is_strict_mode) and atomNameEquals(s, atom_id, "yield")));
    }

    fn isInvalidStrictFunctionBindingName(s: *State, atom_id: Atom) bool {
        return atomNameEquals(s, atom_id, "eval") or atomNameEquals(s, atom_id, "arguments");
    }

    fn canUseAwaitAsIdentifier(s: *State) bool {
        return !s.in_async and !s.lex.is_module and !s.in_class_static_block;
    }

    fn isIdentifierLikeToken(s: *State) bool {
        return s.peekKind() == tok.TOK_IDENT or
            (s.peekKind() == tok.TOK_AWAIT and canUseAwaitAsIdentifier(s)) or
            (s.peekKind() == tok.TOK_YIELD and !s.in_generator and !(s.is_strict or s.cur_func().is_strict_mode)) or
            isSloppyFutureReservedBindingToken(s) or
            (!(s.is_strict or s.cur_func().is_strict_mode) and
                (s.peekKind() == tok.TOK_STATIC or s.peekKind() == tok.TOK_LET));
    }

    fn isSloppyFutureReservedBindingToken(s: *State) bool {
        return !(s.is_strict or s.cur_func().is_strict_mode) and isSloppyFutureReservedToken(s.peekKind());
    }

    fn isSloppyFutureReservedToken(kind: tok.TokenKind) bool {
        return switch (kind) {
            tok.TOK_IMPLEMENTS,
            tok.TOK_INTERFACE,
            tok.TOK_PACKAGE,
            tok.TOK_PRIVATE,
            tok.TOK_PROTECTED,
            tok.TOK_PUBLIC,
            => true,
            else => false,
        };
    }

    fn tokenCanStartExpression(kind: tok.TokenKind) bool {
        return kind == tok.TOK_IDENT or
            kind == tok.TOK_AWAIT or
            kind == tok.TOK_YIELD or
            kind == tok.TOK_NUMBER or
            kind == tok.TOK_STRING or
            kind == tok.TOK_TRUE or
            kind == tok.TOK_FALSE or
            kind == tok.TOK_NULL or
            kind == tok.TOK_THIS or
            kind == tok.TOK_FUNCTION or
            kind == tok.TOK_CLASS or
            kind == @as(tok.TokenKind, @intCast('(')) or
            kind == @as(tok.TokenKind, @intCast('[')) or
            kind == @as(tok.TokenKind, @intCast('{'));
    }

    fn identifierLikeAtom(s: *State) Atom {
        return if (s.peekKind() == tok.TOK_IDENT) s.token.payload.ident.atom else tok.keywordAtom(s.peekKind());
    }

    fn identifierLikeHasInvalidEscapeForBinding(s: *State) bool {
        return s.peekKind() == tok.TOK_IDENT and
            escapedIdentifierIsReservedWordForBinding(s, s.token.payload.ident.atom, s.token.payload.ident.has_escape);
    }

    fn isCurrentFunctionExpressionName(s: *State, atom_id: Atom) bool {
        return if (s.function_expr_name_binding) |name| name == atom_id else false;
    }

    fn emitObjectMethodFunction(s: *State, name: ?Atom, func_kind: ParseFunctionKind, source_start: usize) Error!void {
        const saved_name = s.pending_function_name;
        const saved_decl = s.pending_function_is_decl;
        const saved_top_level_children = s.top_level_functions_as_children;
        const saved_in_generator = s.in_generator;
        const saved_in_async = s.in_async;
        const saved_allow_super = s.allow_super;
        const saved_parsing_method_params = s.parsing_method_params;
        s.pending_function_name = name;
        s.pending_function_is_decl = false;
        s.top_level_functions_as_children = true;
        s.in_generator = func_kind == .generator or func_kind == .async_generator;
        s.in_async = func_kind == .async or func_kind == .async_generator;
        s.allow_super = true;
        s.parsing_method_params = true;
        defer {
            s.pending_function_name = saved_name;
            s.pending_function_is_decl = saved_decl;
            s.top_level_functions_as_children = saved_top_level_children;
            s.in_generator = saved_in_generator;
            s.in_async = saved_in_async;
            s.allow_super = saved_allow_super;
            s.parsing_method_params = saved_parsing_method_params;
        }
        try parseFunctionParamsAndBody(s, func_kind, source_start);
        // Object literal methods are named by OP_define_method. Do not let
        // function-expression name inference escape and name the object literal
        // itself in assignments such as `var obj = { method() {} }`.
        s.last_anonymous_function_expr = false;
    }

    fn parseAssignExprWithPendingFunctionName(s: *State, flags: ParseFlags, name: ?Atom) Error!void {
        const saved_name = s.pending_function_name;
        const saved_decl = s.pending_function_is_decl;
        s.pending_function_name = name;
        s.pending_function_is_decl = false;
        defer {
            s.pending_function_name = saved_name;
            s.pending_function_is_decl = saved_decl;
        }
        try parseAssignExpr2(s, flags);
    }

    fn atomNameEquals(s: *State, atom_id: Atom, name: []const u8) bool {
        return if (s.function.atoms.name(atom_id)) |atom_name| std.mem.eql(u8, atom_name, name) else false;
    }

    fn atomsNameEqual(s: *State, left: Atom, right: Atom) bool {
        if (left == right) return true;
        const left_name = s.function.atoms.name(left) orelse return false;
        const right_name = s.function.atoms.name(right) orelse return false;
        return std.mem.eql(u8, left_name, right_name);
    }

    fn evalAnnexBBlockedFunctionName(s: *State, atom_id: Atom) bool {
        for (s.eval_annex_b_blocked_function_names) |blocked| {
            if (atomsNameEqual(s, atom_id, blocked)) return true;
        }
        return false;
    }

    fn atomNameIsPrivate(s: *State, atom_id: Atom) bool {
        return s.function.atoms.kind(atom_id) == .private;
    }

    fn formatFiniteNumber(buffer: []u8, value: f64) ![]const u8 {
        const abs_value = @abs(value);
        if (abs_value != 0 and (abs_value < 0.000001 or abs_value >= 1000000000000000000000.0)) {
            return std.fmt.bufPrint(buffer, "{e}", .{value});
        }
        return std.fmt.bufPrint(buffer, "{d}", .{value});
    }

    fn formatBigIntPropertyName(s: *State, text: []const u8) Error![]const u8 {
        const parse_text = if (std.mem.indexOfScalar(u8, text, '_')) |_| blk: {
            var normalized = std.ArrayList(u8).empty;
            errdefer normalized.deinit(s.function.memory.allocator);
            for (text) |ch| {
                if (ch != '_') normalized.append(s.function.memory.allocator, ch) catch return Error.OutOfMemory;
            }
            break :blk normalized.toOwnedSlice(s.function.memory.allocator) catch return Error.OutOfMemory;
        } else text;
        defer if (parse_text.ptr != text.ptr) s.function.memory.allocator.free(parse_text);

        var parsed = libs_bignum.parseAutoAlloc(s.function.memory.allocator, parse_text) catch return Error.InvalidNumberLiteral;
        defer parsed.deinit();
        return parsed.formatBase10Alloc(s.function.memory.allocator) catch return Error.OutOfMemory;
    }

    // =====================================================================
    // Helpers
    // =====================================================================

    /// Map an assignment-operator token to its compound-arithmetic opcode.
    /// Returns `null` for plain `=` and non-assignment tokens.
    fn compoundAssignOpcode(k: tok.TokenKind) ?u8 {
        return switch (k) {
            tok.TOK_MUL_ASSIGN => opcode.op.mul,
            tok.TOK_DIV_ASSIGN => opcode.op.div,
            tok.TOK_MOD_ASSIGN => opcode.op.mod,
            tok.TOK_PLUS_ASSIGN => opcode.op.add,
            tok.TOK_MINUS_ASSIGN => opcode.op.sub,
            tok.TOK_SHL_ASSIGN => opcode.op.shl,
            tok.TOK_SAR_ASSIGN => opcode.op.sar,
            tok.TOK_SHR_ASSIGN => opcode.op.shr,
            tok.TOK_AND_ASSIGN => opcode.op.@"and",
            tok.TOK_XOR_ASSIGN => opcode.op.xor,
            tok.TOK_OR_ASSIGN => opcode.op.@"or",
            tok.TOK_POW_ASSIGN => opcode.op.pow,
            else => null,
        };
    }

    fn logicalAssignKind(k: tok.TokenKind) ?LogicalAssignKind {
        return switch (k) {
            tok.TOK_LAND_ASSIGN => .land,
            tok.TOK_LOR_ASSIGN => .lor,
            tok.TOK_DOUBLE_QUESTION_MARK_ASSIGN => .nullish,
            else => null,
        };
    }

    /// Mirror `quickjs.c:27083..27201` — token-to-opcode level table.
    fn matchBinaryOp(k: tok.TokenKind, level: u8, flags: ParseFlags) ?u8 {
        return switch (level) {
            1 => switch (k) {
                @as(tok.TokenKind, @intCast('*')) => opcode.op.mul,
                @as(tok.TokenKind, @intCast('/')) => opcode.op.div,
                @as(tok.TokenKind, @intCast('%')) => opcode.op.mod,
                else => null,
            },
            2 => switch (k) {
                @as(tok.TokenKind, @intCast('+')) => opcode.op.add,
                @as(tok.TokenKind, @intCast('-')) => opcode.op.sub,
                else => null,
            },
            3 => switch (k) {
                tok.TOK_SHL => opcode.op.shl,
                tok.TOK_SAR => opcode.op.sar,
                tok.TOK_SHR => opcode.op.shr,
                else => null,
            },
            4 => switch (k) {
                @as(tok.TokenKind, @intCast('<')) => opcode.op.lt,
                @as(tok.TokenKind, @intCast('>')) => opcode.op.gt,
                tok.TOK_LTE => opcode.op.lte,
                tok.TOK_GTE => opcode.op.gte,
                tok.TOK_INSTANCEOF => opcode.op.instanceof,
                tok.TOK_IN => if (flags.in_accepted) opcode.op.in else null,
                else => null,
            },
            5 => switch (k) {
                tok.TOK_EQ => opcode.op.eq,
                tok.TOK_NEQ => opcode.op.neq,
                tok.TOK_STRICT_EQ => opcode.op.strict_eq,
                tok.TOK_STRICT_NEQ => opcode.op.strict_neq,
                else => null,
            },
            6 => switch (k) {
                @as(tok.TokenKind, @intCast('&')) => opcode.op.@"and",
                else => null,
            },
            7 => switch (k) {
                @as(tok.TokenKind, @intCast('^')) => opcode.op.xor,
                else => null,
            },
            8 => switch (k) {
                @as(tok.TokenKind, @intCast('|')) => opcode.op.@"or",
                else => null,
            },
            else => null,
        };
    }

    fn expectPunct(s: *State, ch: u8) Error!void {
        if (!s.isPunct(ch)) return Error.UnexpectedToken;
        try s.advance();
    }

    fn numberIsExactI32(value: f64) bool {
        if (std.math.isNan(value) or std.math.isInf(value)) return false;
        if (value < @as(f64, std.math.minInt(i32)) or value > @as(f64, std.math.maxInt(i32))) return false;
        const truncated: f64 = @floatFromInt(@as(i32, @intFromFloat(value)));
        return truncated == value;
    }

    fn parseBigIntI32(text: []const u8, negate: bool) ?i32 {
        const magnitude = std.fmt.parseInt(i64, text, 0) catch return null;
        const signed = if (negate) -magnitude else magnitude;
        if (signed < std.math.minInt(i32) or signed > std.math.maxInt(i32)) return null;
        return @intCast(signed);
    }

    /// Emit a forward-jump opcode with a placeholder absolute target. The
    /// caller passes the offset back to `patchForwardJump` once the target
    /// is known. The parser uses absolute u32 offsets; `resolve_labels`
    /// lowers these to relative `goto8`/`goto16`/`label`s.
    fn emitForwardJump(s: *State, op_id: u8) Error!usize {
        var bytes: [5]u8 = undefined;
        bytes[0] = op_id;
        std.mem.writeInt(u32, bytes[1..5], 0, .little);
        const loc = s.currentSourcePosition();
        try s.appendBytesAt(&bytes, loc.line_num, loc.col_num);
        return @as(usize, @intCast(s.cur_func().last_opcode_pos)) + 1;
    }

    fn emitForwardJumpNoSource(s: *State, op_id: u8) Error!usize {
        var bytes: [5]u8 = undefined;
        bytes[0] = op_id;
        std.mem.writeInt(u32, bytes[1..5], 0, .little);
        const operand_offset = s.currentCodeLen() + 1;
        try s.emitOpcodeBytesNoSource(&bytes);
        return operand_offset;
    }

    const ParserLabelRef = struct {
        id: u32,
    };

    fn newParserLabel(s: *State) ParserLabelRef {
        const count = s.currentParserLabelCount();
        std.debug.assert(count < opcode.op.parser_label_tag - 1);
        const id = count + 1; // zero remains the legacy anonymous boundary marker
        s.setParserLabelCount(id);
        return .{ .id = id };
    }

    fn emitParserLabelJump(s: *State, op_id: u8, label: ParserLabelRef) Error!void {
        if (opcode.formatOf(op_id) != .label or op_id == opcode.op.label) return Error.UnexpectedToken;
        var bytes: [5]u8 = undefined;
        bytes[0] = op_id;
        std.mem.writeInt(u32, bytes[1..5], opcode.op.parser_label_tag | label.id, .little);
        const loc = s.currentSourcePosition();
        try s.appendBytesAt(&bytes, loc.line_num, loc.col_num);
    }

    fn emitParserLabelJumpNoSource(s: *State, op_id: u8, label: ParserLabelRef) Error!void {
        if (opcode.formatOf(op_id) != .label or op_id == opcode.op.label) return Error.UnexpectedToken;
        var bytes: [5]u8 = undefined;
        bytes[0] = op_id;
        std.mem.writeInt(u32, bytes[1..5], opcode.op.parser_label_tag | label.id, .little);
        try s.emitOpcodeBytesNoSource(&bytes);
    }

    fn emitParserLabelJumpNoSourceAssumeCapacity(s: *State, op_id: u8, label: ParserLabelRef) void {
        std.debug.assert(opcode.formatOf(op_id) == .label and op_id != opcode.op.label);
        var bytes: [5]u8 = undefined;
        bytes[0] = op_id;
        std.mem.writeInt(u32, bytes[1..5], opcode.op.parser_label_tag | label.id, .little);
        s.emitOpcodeBytesNoSourceAssumeCapacity(&bytes);
    }

    fn emitGotoParserLabelNoSource(s: *State, label: ParserLabelRef) Error!void {
        try emitParserLabelJumpNoSource(s, opcode.op.goto, label);
    }

    fn emitGotoParserLabelNoSourceAssumeCapacity(s: *State, label: ParserLabelRef) void {
        emitParserLabelJumpNoSourceAssumeCapacity(s, opcode.op.goto, label);
    }

    /// Raw labels preserve the preceding real opcode as call/delete
    /// provenance. Normal labels additionally invalidate it at the merge.
    fn emitParserLabelRawNoSource(s: *State, label: ParserLabelRef) Error!void {
        const snapshot = s.takeEmissionSnapshot();
        errdefer s.rollbackEmission(snapshot);
        var bytes: [5]u8 = undefined;
        bytes[0] = opcode.op.label;
        std.mem.writeInt(u32, bytes[1..5], label.id, .little);
        try s.appendBytesNoSource(&bytes);
    }

    fn emitParserLabelRawNoSourceAssumeCapacity(s: *State, label: ParserLabelRef) void {
        var bytes: [5]u8 = undefined;
        bytes[0] = opcode.op.label;
        std.mem.writeInt(u32, bytes[1..5], label.id, .little);
        s.appendBytesNoSourceAssumeCapacity(&bytes);
    }

    fn emitParserLabelNoSource(s: *State, label: ParserLabelRef) Error!void {
        try emitParserLabelRawNoSource(s, label);
        s.invalidateLastOpcode();
    }

    fn emitParserLabelNoSourceAssumeCapacity(s: *State, label: ParserLabelRef) void {
        emitParserLabelRawNoSourceAssumeCapacity(s, label);
        s.invalidateLastOpcode();
    }

    /// Emit a jump opcode whose target is already known (for backward jumps,
    /// e.g. while-loop continue or for-loop back edge). `resolve_labels`
    /// lowers these to relative `goto8`/`goto16`.
    fn emitBackwardJump(s: *State, op_id: u8, target: u32) Error!void {
        var bytes: [5]u8 = undefined;
        bytes[0] = op_id;
        std.mem.writeInt(u32, bytes[1..5], target, .little);
        const loc = s.currentSourcePosition();
        try s.appendBytesAt(&bytes, loc.line_num, loc.col_num);
    }

    fn emitBackwardJumpNoSource(s: *State, op_id: u8, target: u32) Error!void {
        var bytes: [5]u8 = undefined;
        bytes[0] = op_id;
        std.mem.writeInt(u32, bytes[1..5], target, .little);
        try s.emitOpcodeBytesNoSource(&bytes);
    }

    const ParserPhaseInstruction = struct {
        size: u8,
        is_temp: bool = false,
    };

    fn parserPhaseAtomTempInstruction(code: []const u8, atoms: []const Atom, pc: usize, atom_index: usize) ?ParserPhaseInstruction {
        const op_id = code[pc];
        const size: u8 = switch (op_id) {
            opcode.op.scope_get_var_undef,
            opcode.op.scope_get_var,
            opcode.op.scope_put_var,
            opcode.op.scope_delete_var,
            opcode.op.scope_get_ref,
            opcode.op.scope_put_var_init,
            opcode.op.scope_get_var_checkthis,
            opcode.op.scope_get_private_field,
            opcode.op.scope_get_private_field2,
            opcode.op.scope_put_private_field,
            opcode.op.scope_in_private_field,
            => 7,
            opcode.op.scope_make_ref => 11,
            opcode.op.get_field_opt_chain => 5,
            else => return null,
        };
        if (pc + size > code.len or atom_index >= atoms.len) return null;
        if (std.mem.readInt(u32, code[pc + 1 ..][0..4], .little) != atoms[atom_index]) return null;
        return .{ .size = size, .is_temp = true };
    }

    fn parserPhaseInstruction(code: []const u8, atoms: []const Atom, pc: usize, atom_index: usize) ParserPhaseInstruction {
        if (parserPhaseAtomTempInstruction(code, atoms, pc, atom_index)) |temp_instr| return temp_instr;
        const op_id = code[pc];
        switch (op_id) {
            opcode.op.enter_scope,
            opcode.op.leave_scope,
            opcode.op.label,
            opcode.op.get_array_el_opt_chain,
            opcode.op.set_class_name,
            opcode.op.line_num,
            => return .{ .size = opcode.sizeOfPhase1(op_id), .is_temp = true },
            else => {},
        }
        return .{ .size = opcode.sizeOf(code[pc]) };
    }

    fn parserPhaseInstructionHasAtom(op_id: u8, is_temp: bool) bool {
        if (is_temp) return switch (op_id) {
            opcode.op.scope_get_var_undef,
            opcode.op.scope_get_var,
            opcode.op.scope_put_var,
            opcode.op.scope_delete_var,
            opcode.op.scope_make_ref,
            opcode.op.scope_get_ref,
            opcode.op.scope_put_var_init,
            opcode.op.scope_get_var_checkthis,
            opcode.op.scope_get_private_field,
            opcode.op.scope_get_private_field2,
            opcode.op.scope_put_private_field,
            opcode.op.scope_in_private_field,
            opcode.op.get_field_opt_chain,
            => true,
            else => false,
        };

        return switch (opcode.formatOf(op_id)) {
            .atom, .atom_u8, .atom_u16, .atom_label_u8, .atom_label_u16 => true,
            else => false,
        };
    }

    fn parserPhaseLabelOperandOffset(op_id: u8, pc: usize, is_temp: bool) ?usize {
        if (is_temp and op_id == opcode.op.scope_make_ref) return pc + 5;
        return switch (opcode.formatOf(op_id)) {
            .label => if (op_id == opcode.op.label) null else pc + 1,
            .atom_label_u8, .atom_label_u16 => pc + 5,
            .label_u16 => pc + 1,
            else => null,
        };
    }

    fn validateMovedBytecodeLabels(code: []const u8, atoms: []const Atom, old_base: usize, new_base: usize) Error!void {
        if (old_base > std.math.maxInt(usize) - code.len) return Error.UnexpectedToken;
        const old_end = old_base + code.len;
        const delta = @as(i128, @intCast(new_base)) - @as(i128, @intCast(old_base));
        var pc: usize = 0;
        var atom_index: usize = 0;
        while (pc < code.len) {
            const op_id = code[pc];
            const instr = parserPhaseInstruction(code, atoms, pc, atom_index);
            const size = instr.size;
            if (size == 0 or pc + size > code.len) return Error.UnexpectedToken;

            const label_offset = parserPhaseLabelOperandOffset(op_id, pc, instr.is_temp);
            if (label_offset) |offset| {
                if (offset > code.len or code.len - offset < 4) return Error.UnexpectedToken;
                const target = std.mem.readInt(u32, code[offset..][0..4], .little);
                if (target >= old_base and target <= old_end) {
                    const rebased = @as(i128, @intCast(target)) + delta;
                    if (rebased < 0 or rebased > std.math.maxInt(u32)) return Error.UnexpectedToken;
                }
            }

            if (parserPhaseInstructionHasAtom(op_id, instr.is_temp)) {
                if (atom_index >= atoms.len) return Error.UnexpectedToken;
                atom_index += 1;
            }
            pc += size;
        }
        if (atom_index != atoms.len) return Error.UnexpectedToken;
    }

    fn rebaseMovedBytecodeLabelsAssumeValidated(code: []u8, atoms: []const Atom, old_base: usize, new_base: usize) void {
        if (old_base == new_base) return;
        const old_end = old_base + code.len;
        const delta = @as(i128, @intCast(new_base)) - @as(i128, @intCast(old_base));
        var pc: usize = 0;
        var atom_index: usize = 0;
        while (pc < code.len) {
            const op_id = code[pc];
            const instr = parserPhaseInstruction(code, atoms, pc, atom_index);
            const label_offset = parserPhaseLabelOperandOffset(op_id, pc, instr.is_temp);
            if (label_offset) |offset| {
                const target = std.mem.readInt(u32, code[offset..][0..4], .little);
                if (target >= old_base and target <= old_end) {
                    const rebased = @as(i128, @intCast(target)) + delta;
                    std.debug.assert(rebased >= 0 and rebased <= std.math.maxInt(u32));
                    std.mem.writeInt(u32, code[offset..][0..4], @intCast(rebased), .little);
                }
            }
            if (parserPhaseInstructionHasAtom(op_id, instr.is_temp)) atom_index += 1;
            pc += instr.size;
        }
        std.debug.assert(atom_index == atoms.len);
    }

    fn rebaseMovedBytecodeLabels(code: []u8, atoms: []const Atom, old_base: usize, new_base: usize) Error!void {
        try validateMovedBytecodeLabels(code, atoms, old_base, new_base);
        rebaseMovedBytecodeLabelsAssumeValidated(code, atoms, old_base, new_base);
    }

    fn pushBreakFrame(s: *State) Error!void {
        try s.break_frame_lens.append(s.function.memory.allocator, s.break_fixups.items.len);
        try s.continue_frame_lens.append(s.function.memory.allocator, s.continue_fixups.items.len);
        try s.continue_frame_break_frame_indices.append(s.function.memory.allocator, s.break_frame_lens.items.len - 1);
        try s.break_frame_catch_marker_depths.append(s.function.memory.allocator, s.active_catch_marker_depth);
        try s.break_frame_cleanup_drops.append(s.function.memory.allocator, 0);
        try s.break_frame_cross_cleanup_drops.append(s.function.memory.allocator, 0);
        try s.continue_frame_catch_marker_depths.append(s.function.memory.allocator, s.active_catch_marker_depth);
        try s.continue_frame_cleanup_drops.append(s.function.memory.allocator, 0);
    }

    fn pushBreakOnlyFrame(s: *State) Error!void {
        try s.break_frame_lens.append(s.function.memory.allocator, s.break_fixups.items.len);
        try s.break_frame_catch_marker_depths.append(s.function.memory.allocator, s.active_catch_marker_depth);
        try s.break_frame_cleanup_drops.append(s.function.memory.allocator, 0);
        try s.break_frame_cross_cleanup_drops.append(s.function.memory.allocator, 0);
    }

    /// Put a real break/continue target in the same ordered environment chain
    /// that already carries iterator and shared-finally-body cleanup.  Jump
    /// operands remain owned by the existing fixup lists; the non-negative
    /// label fields mean that this environment has the corresponding target.
    fn pushControlBlock(
        s: *State,
        block: *BlockEnv,
        label_name: ?Atom,
        has_break_target: bool,
        has_continue_target: bool,
        is_regular_stmt: bool,
        scope_level: i32,
        drop_count: i32,
        has_iterator: bool,
    ) void {
        block.* = .{
            .prev = s.top_break,
            .label_name = label_name orelse atom_module.null_atom,
            .label_break = if (has_break_target) 0 else -1,
            .label_cont = if (has_continue_target) 0 else -1,
            .drop_count = drop_count,
            .label_finally = -1,
            .scope_level = scope_level,
            .catch_marker_depth = s.active_catch_marker_depth,
            .has_iterator = has_iterator,
            .is_regular_stmt = is_regular_stmt,
        };
        s.top_break = block;
    }

    fn popControlBlock(s: *State, block: *BlockEnv) void {
        std.debug.assert(s.top_break == block);
        s.top_break = block.prev;
    }

    fn setCurrentBreakCleanupDrops(s: *State, drops: u8) void {
        if (s.break_frame_cleanup_drops.items.len == 0) return;
        s.break_frame_cleanup_drops.items[s.break_frame_cleanup_drops.items.len - 1] = drops;
        s.break_frame_cross_cleanup_drops.items[s.break_frame_cross_cleanup_drops.items.len - 1] = drops;
    }

    fn setCurrentBreakCrossCleanupDrops(s: *State, drops: u8) void {
        if (s.break_frame_cross_cleanup_drops.items.len == 0) return;
        s.break_frame_cross_cleanup_drops.items[s.break_frame_cross_cleanup_drops.items.len - 1] = drops;
    }

    fn emitUnlabelledBreakCleanup(s: *State, cleanup_drops: u8) Error!void {
        if (cleanup_drops == shared_iterator_close_marker) return;
        try emitCrossFrameCleanup(s, cleanup_drops);
    }

    fn emitCrossFrameCleanup(s: *State, cleanup_drops: u8) Error!void {
        if (cleanup_drops == shared_iterator_close_marker or cleanup_drops == direct_iterator_close_marker) {
            try s.emitOpNoSource(opcode.op.iterator_close);
            return;
        }
        var remaining = cleanup_drops;
        while (remaining > 0) : (remaining -= 1) {
            try s.emitOpNoSource(opcode.op.drop);
        }
    }

    fn emitCatchMarkerDropsFromDepth(s: *State, current_depth: *u32, target_depth: u32) Error!void {
        if (current_depth.* < target_depth) return Error.UnexpectedToken;
        while (current_depth.* > target_depth) {
            try s.emitOpNoSource(opcode.op.drop);
            try emitUsingDisposesForCatchMarkerDepth(s, current_depth.*);
            current_depth.* -= 1;
        }
    }

    fn emitCatchMarkerDropsToDepth(s: *State, target_depth: u32) Error!void {
        var current_depth = s.active_catch_marker_depth;
        try emitCatchMarkerDropsFromDepth(s, &current_depth, target_depth);
    }

    fn emitUsingDisposesForCatchMarkerDepth(s: *State, depth: u32) Error!void {
        var i = s.using_block_frames.items.len;
        while (i != 0) {
            i -= 1;
            const frame = s.using_block_frames.items[i];
            if (frame.catch_marker_depth != depth) continue;
            const stack_loc = frame.stack_loc orelse continue;
            try emitUsingDisposeStack(s, stack_loc, frame.seen_async_hint);
            try s.emitCloseLoc(stack_loc);
        }
    }

    fn emitUnlabelledBreak(s: *State) Error!void {
        if (s.break_frame_lens.items.len == 0) return;
        try emitControlThroughFinally(s, .{ .kind = .@"break" });
    }

    fn emitUnlabelledBreakNoFinallyCapture(s: *State) Error!void {
        try emitCatchMarkerDropsToDepth(s, s.break_frame_catch_marker_depths.getLast());
        try emitUnlabelledBreakCleanup(s, s.break_frame_cleanup_drops.getLast());
        const off = try emitForwardJumpNoSource(s, opcode.op.goto);
        try s.break_fixups.append(s.function.memory.allocator, off);
    }

    fn emitUnlabelledContinue(s: *State) Error!void {
        if (s.continue_frame_lens.items.len == 0) return;
        try emitControlThroughFinally(s, .{ .kind = .@"continue" });
    }

    fn emitUnlabelledContinueNoFinallyCapture(s: *State) Error!void {
        try emitCatchMarkerDropsToDepth(s, s.continue_frame_catch_marker_depths.getLast());
        try emitCrossFrameCleanup(s, s.continue_frame_cleanup_drops.getLast());
        const off = try emitForwardJumpNoSource(s, opcode.op.goto);
        try s.continue_fixups.append(s.function.memory.allocator, off);
    }

    fn enterSwitchContinueCleanup(s: *State) void {
        for (s.continue_frame_cleanup_drops.items) |*drops| {
            if (drops.* != shared_iterator_close_marker and drops.* != direct_iterator_close_marker) drops.* += 1;
        }
    }

    fn leaveSwitchContinueCleanup(s: *State) void {
        for (s.continue_frame_cleanup_drops.items) |*drops| {
            if (drops.* != shared_iterator_close_marker and drops.* != direct_iterator_close_marker and drops.* > 0) drops.* -= 1;
        }
    }

    fn emitActiveIteratorCloses(s: *State) Error!void {
        var index = s.break_frame_cleanup_drops.items.len;
        while (index != 0) {
            index -= 1;
            try emitCrossFrameCleanup(s, s.break_frame_cleanup_drops.items[index]);
        }
    }

    fn hasActiveIteratorCloses(s: *State) bool {
        for (s.break_frame_cleanup_drops.items) |drops| {
            if (drops != 0) return true;
        }
        return false;
    }

    fn expressionStatementKeepsCompletion(s: *const State) bool {
        return s.eval_ret_idx >= 0 and !s.lex.is_module;
    }

    fn caseCanFallthrough(s: *State) bool {
        const op_id = lastOpcode(s.currentCode(), s.currentAtomOperands()) orelse return true;
        return switch (op_id) {
            opcode.op.goto,
            opcode.op.@"return",
            opcode.op.return_undef,
            opcode.op.return_async,
            opcode.op.throw,
            => false,
            else => true,
        };
    }

    /// QuickJS `js_is_live_code`: only the straight-line predecessor matters
    /// while constructing a statement's fixed control-flow topology.
    fn isLiveCode(s: *State) bool {
        const op_id = lastNonCleanupOpcode(s.currentCode(), s.currentAtomOperands()) orelse return true;
        const terminal = switch (op_id) {
            opcode.op.goto,
            opcode.op.@"return",
            opcode.op.return_undef,
            opcode.op.return_async,
            opcode.op.tail_call,
            opcode.op.tail_call_method,
            opcode.op.throw,
            opcode.op.throw_error,
            opcode.op.ret,
            => true,
            else => false,
        };
        if (!terminal) return true;
        // zjs patches loop/branch exits to the current absolute byte offset
        // instead of emitting a physical OP_label at every merge. Such an
        // incoming edge makes the merge live even when the preceding linear
        // instruction is a back-edge or return.
        return hasAbsoluteJumpToCurrentEnd(s.currentCode(), s.currentAtomOperands());
    }

    fn lastOpcode(code: []const u8, atoms: []const Atom) ?u8 {
        return lastParserPhaseOpcode(code, atoms, false);
    }

    fn lastNonCleanupOpcode(code: []const u8, atoms: []const Atom) ?u8 {
        return lastParserPhaseOpcode(code, atoms, true);
    }

    fn lastParserPhaseOpcode(code: []const u8, atoms: []const Atom, skip_cleanup: bool) ?u8 {
        var pc: usize = 0;
        var atom_index: usize = 0;
        var last: ?u8 = null;
        while (pc < code.len) {
            const op_id = code[pc];
            const instr = parserPhaseInstruction(code, atoms, pc, atom_index);
            const size: usize = instr.size;
            if (size == 0 or pc + size > code.len) return null;
            if (op_id != opcode.op.line_num and
                !(skip_cleanup and (op_id == opcode.op.leave_scope or op_id == opcode.op.close_loc)))
            {
                last = op_id;
            }
            if (parserPhaseInstructionHasAtom(op_id, instr.is_temp)) atom_index += 1;
            pc += size;
        }
        return last;
    }

    /// Offset where the trailing cleanup-only run begins: the maximal code
    /// suffix consisting of the ops `lastParserPhaseOpcode(skip_cleanup=true)`
    /// skips (line_num / leave_scope / close_loc). Equals `code.len` when the
    /// last instruction is a real op. Malformed code yields 0 so the caller's
    /// jump-to-end answer degrades conservatively (treat as end-targeting).
    fn trailingCleanupStart(code: []const u8, atoms: []const Atom) usize {
        var pc: usize = 0;
        var atom_index: usize = 0;
        var tail_start: usize = 0;
        while (pc < code.len) {
            const op_id = code[pc];
            const instr = parserPhaseInstruction(code, atoms, pc, atom_index);
            const size: usize = instr.size;
            if (size == 0 or pc + size > code.len) return 0;
            if (op_id != opcode.op.line_num and
                op_id != opcode.op.leave_scope and
                op_id != opcode.op.close_loc)
            {
                tail_start = pc + size;
            }
            if (parserPhaseInstructionHasAtom(op_id, instr.is_temp)) atom_index += 1;
            pc += size;
        }
        return tail_start;
    }

    /// True when any label operand (goto / if_* / gosub / catch / with-* /
    /// scope_make_ref families — everything `parserPhaseLabelOperandOffset`
    /// knows) targets the current end of `code`, INCLUDING the trailing
    /// cleanup run (line_num / leave_scope / close_loc): those trailing ops
    /// either vanish during lowering (line_num, leave_scope, uncaptured
    /// close_loc — so the resolved target becomes `code_end`) or execute and
    /// then fall off it. The register-resident dispatch mirrors qjs and has no
    /// per-op fall-off bounds check, so every such jump must land on a real
    /// terminator appended by the epilogues (qjs shape: emit_return after
    /// js_is_live_code, quickjs.c js_parse_function_decl2 tail).
    pub fn hasJumpToCurrentEnd(code: []const u8, atoms: []const Atom) bool {
        const tail_start = trailingCleanupStart(code, atoms);
        var pc: usize = 0;
        var atom_index: usize = 0;
        while (pc < code.len) {
            const op_id = code[pc];
            const instr = parserPhaseInstruction(code, atoms, pc, atom_index);
            const size: usize = instr.size;
            if (size == 0 or pc + size > code.len) return true;
            if (parserPhaseLabelOperandOffset(op_id, pc, instr.is_temp)) |offset| {
                const target = std.mem.readInt(u32, code[offset..][0..4], .little);
                if (target >= tail_start) return true;
            }
            if (parserPhaseInstructionHasAtom(op_id, instr.is_temp)) atom_index += 1;
            pc += size;
        }
        return false;
    }

    /// Statement-local variant used by `isLiveCode`. Tagged parser labels may
    /// name handlers emitted later and therefore are not incoming edges to the
    /// current merge; already-patched absolute loop/branch exits are.
    fn hasAbsoluteJumpToCurrentEnd(code: []const u8, atoms: []const Atom) bool {
        const tail_start = trailingCleanupStart(code, atoms);
        var pc: usize = 0;
        var atom_index: usize = 0;
        while (pc < code.len) {
            const op_id = code[pc];
            const instr = parserPhaseInstruction(code, atoms, pc, atom_index);
            const size: usize = instr.size;
            if (size == 0 or pc + size > code.len) return true;
            if (parserPhaseLabelOperandOffset(op_id, pc, instr.is_temp)) |offset| {
                const target = std.mem.readInt(u32, code[offset..][0..4], .little);
                if ((target & opcode.op.parser_label_tag) == 0 and target >= tail_start) return true;
            }
            if (parserPhaseInstructionHasAtom(op_id, instr.is_temp)) atom_index += 1;
            pc += size;
        }
        return false;
    }

    /// Straight-line liveness only: does the fall-through path need an
    /// implicit `return_undef`? Jump-to-end reachability is the caller's
    /// separate `hasJumpToCurrentEnd` OR — a body whose last real op is a
    /// terminator can still be entered at its end by a finished-construct
    /// jump (if/else arm, break), and that path needs a landing terminator.
    pub fn functionNeedsImplicitReturn(code: []const u8, atoms: []const Atom) bool {
        const op_id = lastNonCleanupOpcode(code, atoms) orelse return true;
        return switch (op_id) {
            opcode.op.@"return",
            opcode.op.return_undef,
            opcode.op.return_async,
            opcode.op.tail_call,
            opcode.op.tail_call_method,
            opcode.op.throw,
            => false,
            else => true,
        };
    }

    fn patchContinueFrame(s: *State) Error!void {
        if (s.continue_frame_lens.items.len == 0) return Error.UnexpectedToken;
        const start = s.continue_frame_lens.getLast();
        for (s.continue_fixups.items[start..]) |off| {
            try patchForwardJump(s, off);
        }
        s.continue_fixups.shrinkRetainingCapacity(start);
    }

    fn popBreakFrameAndPatch(s: *State) Error!void {
        if (s.break_frame_lens.items.len == 0 or s.continue_frame_lens.items.len == 0) return Error.UnexpectedToken;
        _ = s.continue_frame_lens.pop().?;
        _ = s.continue_frame_break_frame_indices.pop().?;
        _ = s.continue_frame_catch_marker_depths.pop().?;
        _ = s.continue_frame_cleanup_drops.pop().?;
        const start = s.break_frame_lens.pop().?;
        _ = s.break_frame_catch_marker_depths.pop().?;
        _ = s.break_frame_cleanup_drops.pop().?;
        _ = s.break_frame_cross_cleanup_drops.pop().?;
        for (s.break_fixups.items[start..]) |off| {
            try patchForwardJump(s, off);
        }
        s.break_fixups.shrinkRetainingCapacity(start);
    }

    fn popBreakOnlyFrameAndPatch(s: *State) Error!void {
        if (s.break_frame_lens.items.len == 0) return Error.UnexpectedToken;
        const start = s.break_frame_lens.pop().?;
        _ = s.break_frame_catch_marker_depths.pop().?;
        _ = s.break_frame_cleanup_drops.pop().?;
        _ = s.break_frame_cross_cleanup_drops.pop().?;
        for (s.break_fixups.items[start..]) |off| {
            try patchForwardJump(s, off);
        }
        s.break_fixups.shrinkRetainingCapacity(start);
    }

    fn skipFunctionInPredeclareScan(s: *State) Error!void {
        while (true) {
            var t = try s.lex.next();
            defer s.lex.freeToken(&t);
            if (t.val == tok.TOK_EOF) return;
            if (t.val == '{') break;
        }
        var depth: usize = 1;
        var previous_token_kind: ?tok.TokenKind = '{';
        while (depth != 0) {
            var t = try s.lex.next();
            defer s.lex.freeToken(&t);
            switch (t.val) {
                tok.TOK_EOF => return,
                '{' => depth += 1,
                '}' => depth -= 1,
                tok.TOK_TEMPLATE => try skipTemplateInPredeclareScan(s, t),
                '/', tok.TOK_DIV_ASSIGN => {
                    if (try skipRegexpInPredeclareScan(s, previous_token_kind)) {
                        previous_token_kind = tok.TOK_REGEXP;
                        continue;
                    }
                },
                else => {},
            }
            previous_token_kind = t.val;
        }
    }

    fn skipTemplateInPredeclareScan(s: *State, first: tok.Token) Error!void {
        const first_part = first.payload.str.template orelse return Error.UnexpectedToken;
        switch (first_part) {
            .no_substitution, .tail => return,
            .head, .middle => {},
        }

        while (true) {
            var expr_depth: usize = 0;
            var previous_token_kind: ?tok.TokenKind = '{';
            while (true) {
                var t = try s.lex.next();
                defer s.lex.freeToken(&t);
                switch (t.val) {
                    tok.TOK_EOF => {
                        return;
                    },
                    tok.TOK_FUNCTION => {
                        try skipFunctionInPredeclareScan(s);
                    },
                    tok.TOK_TEMPLATE => {
                        try skipTemplateInPredeclareScan(s, t);
                        previous_token_kind = tok.TOK_TEMPLATE;
                        continue;
                    },
                    '/', tok.TOK_DIV_ASSIGN => {
                        if (try skipRegexpInPredeclareScan(s, previous_token_kind)) {
                            previous_token_kind = tok.TOK_REGEXP;
                            continue;
                        }
                    },
                    '{', '(', '[' => expr_depth += 1,
                    '}', ')', ']' => {
                        if (t.val == '}' and expr_depth == 0) {
                            break;
                        }
                        if (expr_depth != 0) expr_depth -= 1;
                    },
                    else => {},
                }
                previous_token_kind = t.val;
            }

            var next_part = try s.lex.nextTemplatePartAfterBrace();
            defer s.lex.freeToken(&next_part);
            const part = next_part.payload.str.template orelse return Error.UnexpectedToken;
            switch (part) {
                .tail, .no_substitution => return,
                .head, .middle => continue,
            }
        }
    }

    fn skipRegexpInPredeclareScan(s: *State, previous_token_kind: ?tok.TokenKind) Error!bool {
        if (!predeclareSlashStartsRegexp(s, previous_token_kind)) return false;

        const slash_offset = s.lex.mark_pos;
        var regexp_token = try s.lex.rescanRegexp(slash_offset);
        defer s.lex.freeToken(&regexp_token);
        return true;
    }

    fn predeclareSlashStartsRegexp(s: *State, previous_token_kind: ?tok.TokenKind) bool {
        const previous = previous_token_kind orelse return true;
        if (previous == tok.TOK_YIELD and !s.in_generator and !(s.is_strict or s.cur_func().is_strict_mode)) {
            return false;
        }
        if (previous == tok.TOK_AWAIT and canUseAwaitAsIdentifier(s)) {
            return false;
        }
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
            tok.TOK_ARROW,
            tok.TOK_LT,
            tok.TOK_LTE,
            tok.TOK_GT,
            tok.TOK_GTE,
            tok.TOK_EQ,
            tok.TOK_STRICT_EQ,
            tok.TOK_NEQ,
            tok.TOK_STRICT_NEQ,
            tok.TOK_SHL,
            tok.TOK_SAR,
            tok.TOK_SHR,
            tok.TOK_LAND,
            tok.TOK_LOR,
            tok.TOK_POW,
            tok.TOK_DOUBLE_QUESTION_MARK,
            tok.TOK_QUESTION_MARK_DOT,
            tok.TOK_MUL_ASSIGN,
            tok.TOK_DIV_ASSIGN,
            tok.TOK_MOD_ASSIGN,
            tok.TOK_PLUS_ASSIGN,
            tok.TOK_MINUS_ASSIGN,
            tok.TOK_SHL_ASSIGN,
            tok.TOK_SAR_ASSIGN,
            tok.TOK_SHR_ASSIGN,
            tok.TOK_AND_ASSIGN,
            tok.TOK_XOR_ASSIGN,
            tok.TOK_OR_ASSIGN,
            tok.TOK_POW_ASSIGN,
            tok.TOK_LAND_ASSIGN,
            tok.TOK_LOR_ASSIGN,
            tok.TOK_DOUBLE_QUESTION_MARK_ASSIGN,
            tok.TOK_RETURN,
            tok.TOK_CASE,
            tok.TOK_THROW,
            tok.TOK_DELETE,
            tok.TOK_VOID,
            tok.TOK_TYPEOF,
            tok.TOK_NEW,
            tok.TOK_IN,
            tok.TOK_INSTANCEOF,
            tok.TOK_YIELD,
            tok.TOK_AWAIT,
            tok.TOK_OF,
            => true,
            else => false,
        };
    }

    // =====================================================================
    // Statement parsing
    // =====================================================================

    fn usingDeclarationStart(s: *State) bool {
        if (s.peekKind() != tok.TOK_IDENT or !s.isIdent("using")) return false;
        if (s.token.payload.ident.has_escape) return false;
        var has_line_terminator = false;
        const next = s.peekNextKindWithLineTerminator(&has_line_terminator);
        if (has_line_terminator) return false;
        return tokenKindCanStartUsingBinding(s, next);
    }

    fn awaitUsingDeclarationStart(s: *State) bool {
        if (s.peekKind() != tok.TOK_AWAIT) return false;
        const saved_pos = s.lex.pos;
        const saved_line = s.lex.line;
        const saved_col = s.lex.col;
        const saved_got_lf = s.lex.got_lf;
        const saved_mark_pos = s.lex.mark_pos;
        const saved_mark_line = s.lex.mark_line;
        const saved_mark_col = s.lex.mark_col;
        defer {
            s.lex.pos = saved_pos;
            s.lex.line = saved_line;
            s.lex.col = saved_col;
            s.lex.got_lf = saved_got_lf;
            s.lex.mark_pos = saved_mark_pos;
            s.lex.mark_line = saved_mark_line;
            s.lex.mark_col = saved_mark_col;
        }

        var using_token = s.lex.next() catch return false;
        defer s.lex.freeToken(&using_token);
        if (s.lex.gotLineTerminator()) return false;
        if (using_token.val != tok.TOK_IDENT) return false;
        if (using_token.payload.ident.has_escape) return false;
        if (!atomNameEquals(s, using_token.payload.ident.atom, "using")) return false;

        var binding_token = s.lex.next() catch return false;
        defer s.lex.freeToken(&binding_token);
        if (s.lex.gotLineTerminator()) return false;
        return tokenKindCanStartUsingBinding(s, binding_token.val);
    }

    fn directUsingDeclarationKind(s: *State) ?DisposalHint {
        if (awaitUsingDeclarationStart(s)) return .async;
        if (usingDeclarationStart(s)) return .sync;
        return null;
    }

    fn tokenKindCanStartUsingBinding(s: *State, kind: tok.TokenKind) bool {
        return kind == tok.TOK_IDENT or
            (kind == tok.TOK_AWAIT and canUseAwaitAsIdentifier(s)) or
            (kind == tok.TOK_YIELD and !s.in_generator and !(s.is_strict or s.cur_func().is_strict_mode)) or
            (!(s.is_strict or s.cur_func().is_strict_mode) and
                (kind == tok.TOK_STATIC or kind == tok.TOK_LET or
                    kind == tok.TOK_IMPLEMENTS or kind == tok.TOK_INTERFACE or kind == tok.TOK_PACKAGE or
                    kind == tok.TOK_PRIVATE or kind == tok.TOK_PROTECTED or kind == tok.TOK_PUBLIC));
    }

    fn advanceUsingDeclarationPrefixForLookahead(s: *State, kind: DisposalHint) bool {
        switch (kind) {
            .sync => {
                if (!usingDeclarationStart(s)) return false;
                s.advance() catch return false;
                return true;
            },
            .async => {
                if (!awaitUsingDeclarationStart(s)) return false;
                s.advance() catch return false;
                s.advance() catch return false;
                return true;
            },
        }
    }

    fn usingDeclarationBindingIsOf(s: *State, kind: DisposalHint) bool {
        const snapshot = takeParserSnapshot(s);
        defer restoreParserLexerSnapshot(s, snapshot);
        if (!advanceUsingDeclarationPrefixForLookahead(s, kind)) return false;
        return s.isOfToken();
    }

    fn emitCreateUsingDisposableStack(s: *State) Error!u16 {
        const stack_loc = try appendAnonymousTempLocal(s);
        try s.emitOp(opcode.op.using_create_stack);
        try s.emitOpU16(opcode.op.put_loc, stack_loc);
        return stack_loc;
    }

    fn emitUsingAwait(s: *State) Error!void {
        if (s.lex.is_module and s.cur_func_stack.len == 0) s.function.ensureModule().has_top_level_await = true;
        if (!s.in_async and !(s.lex.is_module and s.cur_func_stack.len == 0)) return Error.AwaitOutsideAsyncFunction;
        try s.emitOp(opcode.op.await);
    }

    fn emitUsingAddResource(s: *State, kind: DisposalHint, stack_loc: u16, resource_loc: u16) Error!void {
        try s.emitOpU16(opcode.op.get_loc, stack_loc);
        try s.emitOpU16(opcode.op.get_loc, resource_loc);
        try s.emitOpU8(opcode.op.using_add_resource, @intFromEnum(kind));
    }

    fn emitUsingAwaitIfNeeded(s: *State, may_be_async: bool) Error!void {
        if (!may_be_async) return;
        try s.emitOp(opcode.op.dup);
        try s.emitOp(opcode.op.is_undefined);
        const skip_await = try emitForwardJump(s, opcode.op.if_true);
        try emitUsingAwait(s);
        try patchForwardJump(s, skip_await);
    }

    fn emitUsingDisposeStack(s: *State, stack_loc: u16, may_be_async: bool) Error!void {
        try s.emitOpU16(opcode.op.get_loc, stack_loc);
        try s.emitOp(opcode.op.using_dispose_stack);
        try emitUsingAwaitIfNeeded(s, may_be_async);
        try s.emitOp(opcode.op.drop);
    }

    fn emitUsingDisposeStackForThrow(s: *State, stack_loc: u16, may_be_async: bool) Error!void {
        try s.emitOpU16(opcode.op.get_loc, stack_loc);
        try s.emitOp(opcode.op.swap);
        try s.emitOp(opcode.op.using_dispose_stack_for_throw);
        try emitUsingAwaitIfNeeded(s, may_be_async);
        try s.emitOp(opcode.op.drop);
    }

    fn armCurrentUsingBlockFrame(s: *State) Error!u16 {
        if (s.using_block_frames.items.len == 0) return Error.UnexpectedToken;
        const frame_index = s.using_block_frames.items.len - 1;
        if (s.using_block_frames.items[frame_index].stack_loc) |stack_loc| return stack_loc;

        const stack_loc = try emitCreateUsingDisposableStack(s);
        const catch_off = try emitForwardJump(s, opcode.op.@"catch");
        s.active_catch_marker_depth += 1;
        s.using_block_frames.items[frame_index] = .{
            .stack_loc = stack_loc,
            .catch_off = catch_off,
            .catch_marker_depth = s.active_catch_marker_depth,
        };
        return stack_loc;
    }

    fn noteUsingResourceHint(s: *State, hint: DisposalHint) Error!void {
        if (s.using_block_frames.items.len == 0) return Error.UnexpectedToken;
        if (hint == .async) {
            s.using_block_frames.items[s.using_block_frames.items.len - 1].seen_async_hint = true;
        }
    }

    fn finalizeCurrentUsingBlockFrame(s: *State) Error!void {
        if (s.using_block_frames.items.len == 0) return Error.UnexpectedToken;
        const frame = s.using_block_frames.items[s.using_block_frames.items.len - 1];
        const stack_loc = frame.stack_loc orelse {
            _ = s.using_block_frames.pop();
            return;
        };
        const catch_off = frame.catch_off orelse return Error.UnexpectedToken;
        if (frame.catch_marker_depth != s.active_catch_marker_depth or s.active_catch_marker_depth == 0) {
            return Error.UnexpectedToken;
        }

        s.active_catch_marker_depth -= 1;
        try s.emitOp(opcode.op.drop);
        try emitUsingDisposeStack(s, stack_loc, frame.seen_async_hint);
        try s.emitCloseLoc(stack_loc);
        const end_off = try emitForwardJump(s, opcode.op.goto);
        try patchForwardJump(s, catch_off);
        try emitUsingDisposeStackForThrow(s, stack_loc, frame.seen_async_hint);
        try patchForwardJump(s, end_off);
        _ = s.using_block_frames.pop();
    }

    fn restoreUsingBlockFramesAfterError(s: *State, frame_len: usize, catch_marker_depth: u32) void {
        while (s.using_block_frames.items.len > frame_len) {
            _ = s.using_block_frames.pop();
        }
        s.active_catch_marker_depth = catch_marker_depth;
    }

    pub fn parseProgramStatements(s: *State, decl_mask: DeclMask) Error!void {
        const frame_len = s.using_block_frames.items.len;
        const catch_marker_depth = s.active_catch_marker_depth;
        try s.using_block_frames.append(s.function.memory.allocator, .{});
        errdefer restoreUsingBlockFramesAfterError(s, frame_len, catch_marker_depth);
        while (s.peekKind() != tok.TOK_EOF) {
            try parseStatementOrDecl(s, decl_mask);
        }
        try finalizeCurrentUsingBlockFrame(s);
    }

    fn parseBlockContentsAfterOpen(s: *State) Error!void {
        if (s.is_outer_constructor_block and !s.class_has_extends) {
            s.is_outer_constructor_block = false;
            if (s.current_parameter_properties) |props| {
                for (props.items) |prop_atom| {
                    try s.emitOp(opcode.op.push_this);
                    try s.emitScopeGetVar(prop_atom);
                    try s.emitOpAtom(opcode.op.put_field, prop_atom);
                }
            }
        }
        const frame_len = s.using_block_frames.items.len;
        const catch_marker_depth = s.active_catch_marker_depth;
        try s.using_block_frames.append(s.function.memory.allocator, .{});
        errdefer restoreUsingBlockFramesAfterError(s, frame_len, catch_marker_depth);
        while (s.peekKind() != '}' and s.peekKind() != tok.TOK_EOF) {
            try parseStatementOrDecl(s, DeclMask{ .func = true, .func_with_label = true, .other = true });
        }
        try s.expectToken('}');
        try finalizeCurrentUsingBlockFrame(s);
    }

    /// Mirror QuickJS `js_parse_block`: an empty ordinary block does not
    /// allocate a lexical scope, and directive prologues are not recognized
    /// here. Function bodies use `parseFunctionBodyBlock` below.
    pub fn parseBlock(s: *State) Error!void {
        try s.expectToken('{');
        if (s.peekKind() == '}') {
            try s.expectToken('}');
            return;
        }

        try s.pushScope();
        errdefer s.popScopeIdentity();
        try parseBlockContentsAfterOpen(s);
        try s.popScope();
    }

    /// Mirror the distinct function-body path in QuickJS
    /// `js_parse_function_decl2`: body scope and directives belong to the
    /// FormalParameters/FunctionBody production, not to ordinary blocks.
    fn parseFunctionBodyBlock(s: *State) Error!void {
        try s.expectToken('{');
        try s.beginFunctionBody();
        errdefer s.popScopeIdentity();
        try parseDirectives(s);
        try parseBlockContentsAfterOpen(s);
        s.finishFunctionBody();
    }

    /// Mirror the directive-prologue portion of `js_parse_directives`
    /// (`quickjs.c:35642`) for runtime-visible strict-mode behavior.
    pub fn parseDirectives(s: *State) Error!void {
        // Only directives before the first non-directive statement participate in
        // strict-mode detection; non-strict directives are consumed as statements.
        var directive_contains_legacy_escape = false;
        while (s.peekKind() == tok.TOK_STRING) {
            if (!stringLiteralStatementHasDirectiveTerminator(s)) break;
            const str_payload = s.token.payload.str;
            // Check if this is "use strict"
            if (!str_payload.contains_escape and
                str_payload.bytes.len == 10 and
                std.mem.eql(u8, str_payload.bytes, "use strict"))
            {
                if (directive_contains_legacy_escape or str_payload.contains_legacy_escape) return Error.UnexpectedToken;
                s.cur_func().has_use_strict = true;
                s.is_strict = true;
                s.cur_func().is_strict_mode = true;
                s.lex.is_strict_mode = true;
            }
            if (expressionStatementKeepsCompletion(s)) {
                try emitStringLiteralValue(s, str_payload.bytes);
                try s.emitEvalRetPut();
            }
            directive_contains_legacy_escape = directive_contains_legacy_escape or str_payload.contains_legacy_escape;
            try s.advance();
            // Check for semicolon or ASI
            if (s.isPunct(';')) {
                try s.advance();
            } else if (!s.gotLineTerminator() and
                s.peekKind() != '}' and
                s.peekKind() != tok.TOK_EOF)
            {
                // Not a directive, break
                break;
            }
        }
    }

    fn stringLiteralStatementHasDirectiveTerminator(s: *const State) bool {
        var index = s.currentTokenEndOffset();
        const source = s.lex.source;
        while (index < source.len) {
            switch (source[index]) {
                ';', '}' => return true,
                '\n', '\r' => return !lineTerminatorContinuesStringLiteralExpression(source, index),
                ' ', '\t', 0x0B, 0x0C => {
                    index += 1;
                    continue;
                },
                '/' => {
                    if (index + 1 >= source.len) return false;
                    if (source[index + 1] == '/') return true;
                    if (source[index + 1] == '*') {
                        index += 2;
                        var saw_lf = false;
                        while (index + 1 < source.len and !(source[index] == '*' and source[index + 1] == '/')) : (index += 1) {
                            if (source[index] == '\n' or source[index] == '\r') saw_lf = true;
                        }
                        if (index + 1 >= source.len) return false;
                        index += 2;
                        if (saw_lf) return true;
                        continue;
                    }
                    return false;
                },
                else => return false,
            }
        }
        return true;
    }

    fn lineTerminatorContinuesStringLiteralExpression(source: []const u8, start: usize) bool {
        var index = start;
        while (index < source.len) {
            switch (source[index]) {
                ' ', '\t', 0x0B, 0x0C, '\n', '\r' => index += 1,
                '/' => {
                    if (index + 1 >= source.len) return false;
                    if (source[index + 1] == '/') return false;
                    if (source[index + 1] != '*') return false;
                    index += 2;
                    while (index + 1 < source.len and !(source[index] == '*' and source[index + 1] == '/')) : (index += 1) {}
                    if (index + 1 >= source.len) return false;
                    index += 2;
                },
                else => break,
            }
        }
        return startsKeywordAt(source, index, "in") or startsKeywordAt(source, index, "instanceof");
    }

    fn startsKeywordAt(source: []const u8, index: usize, keyword: []const u8) bool {
        if (index + keyword.len > source.len) return false;
        if (!std.mem.eql(u8, source[index .. index + keyword.len], keyword)) return false;
        if (index + keyword.len >= source.len) return true;
        return !isAsciiIdentifierContinue(source[index + keyword.len]);
    }

    fn isAsciiIdentifierContinue(c: u8) bool {
        return unicode.isAsciiIdentifierPartByte(c);
    }

    fn emitStringLiteralValue(s: *State, bytes: []const u8) Error!void {
        const atom_id = try s.function.atoms.internString(bytes);
        defer s.function.atoms.free(atom_id);

        // QuickJS's emit_push_const(..., as_atom = true) keeps ordinary
        // string atoms as push_atom_value, but a canonical numeric name is a
        // tagged-int atom and therefore falls back to an owned cpool string.
        // Runtime-less parser fragments cannot own JSValues and retain their
        // existing atom-only fallback, like the tagged-template test path.
        if (atom_module.isTaggedInt(atom_id)) {
            if (s.runtime) |rt| {
                const string = core.string.String.createUtf8(rt, bytes) catch |err| switch (err) {
                    error.OutOfMemory, error.StringTooLong => return Error.OutOfMemory,
                    error.InvalidUtf8 => return Error.InvalidUtf8,
                };
                try s.emitPushConstOwned(string.value());
                return;
            }
        }
        try s.emitOpAtom(opcode.op.push_atom_value, atom_id);
    }

    fn parseEnumDeclaration(s: *State) Error!void {
        try s.expectToken(tok.TOK_ENUM);
        if (s.peekKind() != tok.TOK_IDENT) return Error.UnexpectedToken;
        const enum_atom = s.token.payload.ident.atom;
        try s.advance();

        // Register variable in current scope if not exists
        const existing_var = s.cur_func().findVar(enum_atom);
        if (existing_var < 0) {
            _ = try s.addScopeVar(enum_atom, .normal, false, false);
        }

        // Emit Enum = Enum || {}
        try s.emitScopeGetVarUndef(enum_atom);
        try s.emitOp(opcode.op.dup);
        const skip_jump = try emitForwardJump(s, opcode.op.if_true);
        try s.emitOp(opcode.op.drop);
        try s.emitOp(opcode.op.object);
        try patchForwardJump(s, skip_jump);
        try s.emitScopePutVar(enum_atom);

        try s.expectToken('{');

        var counter: i32 = 0;
        while (s.peekKind() != '}' and s.peekKind() != tok.TOK_EOF) {
            if (!isIdentifierLikeToken(s)) return Error.UnexpectedToken;
            const member_atom = identifierLikeAtom(s);
            try s.advance();

            const member_name = s.lex.atoms.name(member_atom) orelse "";

            var is_string_init = false;
            if (s.peekKind() == '=') {
                try s.advance();
                if (s.peekKind() == tok.TOK_STRING) {
                    const is_simple = s.peekNextKind() == ',' or s.peekNextKind() == '}';
                    if (!is_simple) return Error.UnexpectedToken;
                    is_string_init = true;
                    // String initializer: emit Enum.Member = "string"
                    try s.emitScopeGetVar(enum_atom);
                    try emitStringLiteralValue(s, s.token.payload.str.bytes);
                    try s.advance();
                    try s.emitOpAtom(opcode.op.put_field, member_atom);
                } else {
                    var has_explicit = false;
                    var val: i32 = 0;
                    if (s.peekKind() == tok.TOK_NUMBER) {
                        const is_simple = s.peekNextKind() == ',' or s.peekNextKind() == '}';
                        if (!is_simple) return Error.UnexpectedToken;
                        has_explicit = true;
                        val = @intFromFloat(s.token.payload.num.value);
                        try parseAssignExpr(s);
                    } else if (s.peekKind() == '-' and s.peekNextKind() == tok.TOK_NUMBER) {
                        try s.advance(); // consume '-'
                        const is_simple = s.peekNextKind() == ',' or s.peekNextKind() == '}';
                        if (!is_simple) return Error.UnexpectedToken;
                        has_explicit = true;
                        val = -@as(i32, @intFromFloat(s.token.payload.num.value));
                        try s.emitOpI32(opcode.op.push_i32, val);
                        try s.advance(); // consume the number
                    } else {
                        return Error.UnexpectedToken;
                    }
                    if (has_explicit) {
                        counter = val;
                    }
                }
            } else {
                // No initializer: emit push_i32 counter
                try s.emitOpI32(opcode.op.push_i32, counter);
            }

            if (!is_string_init) {
                // Double mapping: Enum[Enum["Member"] = value] = "Member"
                try s.emitScopeGetVar(enum_atom); // Stack: [value, outer_obj]
                try s.emitOp(opcode.op.swap); // Stack: [outer_obj, value]
                try s.emitOp(opcode.op.dup); // Stack: [outer_obj, value, value]
                try s.emitScopeGetVar(enum_atom); // Stack: [outer_obj, value, value, inner_obj]
                try s.emitOp(opcode.op.swap); // Stack: [outer_obj, value, inner_obj, value]
                try s.emitOpAtom(opcode.op.put_field, member_atom); // Stack: [outer_obj, value]
                try emitStringLiteralValue(s, member_name); // Stack: [outer_obj, value, "Member"]
                try s.emitOp(opcode.op.put_array_el);
                counter += 1;
            }

            if (s.peekKind() == ',') {
                try s.advance();
            } else if (s.peekKind() != '}') {
                return Error.UnexpectedToken;
            }
        }

        try s.expectToken('}');
        s.last_declared_atom = enum_atom;

        if (s.namespace_export) {
            if (s.current_namespace_atom) |ns_atom| {
                try s.emitScopeGetVar(ns_atom);
                try s.emitScopeGetVar(enum_atom);
                try s.emitOpAtom(opcode.op.put_field, enum_atom);
            }
        }
    }

    fn parseNamespaceDeclaration(s: *State) Error!void {
        try s.expectToken(tok.TOK_IDENT); // Already matched "namespace" in caller
        try parseNamespaceDeclarationWithIdent(s);
    }

    fn parseNamespaceDeclarationWithIdent(s: *State) Error!void {
        if (s.peekKind() != tok.TOK_IDENT) return Error.UnexpectedToken;
        const ns_atom = s.token.payload.ident.atom;
        try s.advance();

        // Register variable in current scope if not exists
        const existing_var = s.cur_func().findVar(ns_atom);
        if (existing_var < 0) {
            _ = try s.addScopeVar(ns_atom, .normal, false, false);
        }

        // Emit Namespace = Namespace || {}
        try s.emitScopeGetVarUndef(ns_atom);
        try s.emitOp(opcode.op.dup);
        const skip_jump = try emitForwardJump(s, opcode.op.if_true);
        try s.emitOp(opcode.op.drop);
        try s.emitOp(opcode.op.object);
        try patchForwardJump(s, skip_jump);
        try s.emitScopePutVar(ns_atom);

        if (s.peekKind() == @as(tok.TokenKind, @intCast('.'))) {
            try s.advance(); // consume '.'

            try s.pushScopeIdentity();
            const saved_in_namespace = s.in_namespace;
            const saved_namespace_atom = s.current_namespace_atom;
            s.in_namespace = true;
            s.current_namespace_atom = ns_atom;
            defer {
                s.in_namespace = saved_in_namespace;
                s.current_namespace_atom = saved_namespace_atom;
                s.popScopeIdentity();
            }

            try parseNamespaceDeclarationWithIdent(s);

            if (s.last_declared_atom) |nested_atom| {
                try s.emitScopeGetVar(ns_atom);
                try s.emitScopeGetVar(nested_atom);
                try s.emitOpAtom(opcode.op.put_field, nested_atom);
            }

            s.last_declared_atom = ns_atom;
            if (s.namespace_export) {
                if (s.current_namespace_atom) |parent_ns| {
                    try s.emitScopeGetVar(parent_ns);
                    try s.emitScopeGetVar(ns_atom);
                    try s.emitOpAtom(opcode.op.put_field, ns_atom);
                }
            }
            return;
        }

        try s.expectToken('{');
        try s.pushScopeIdentity();
        const saved_in_namespace = s.in_namespace;
        const saved_namespace_atom = s.current_namespace_atom;
        s.in_namespace = true;
        s.current_namespace_atom = ns_atom;
        defer {
            s.in_namespace = saved_in_namespace;
            s.current_namespace_atom = saved_namespace_atom;
            s.popScopeIdentity();
        }

        while (s.peekKind() != '}' and s.peekKind() != tok.TOK_EOF) {
            try parseNamespaceStatement(s);
        }

        try s.expectToken('}');
        s.last_declared_atom = ns_atom;

        if (s.namespace_export) {
            if (saved_namespace_atom) |parent_ns| {
                try s.emitScopeGetVar(parent_ns);
                try s.emitScopeGetVar(ns_atom);
                try s.emitOpAtom(opcode.op.put_field, ns_atom);
            }
        }
    }

    fn parseNamespaceStatement(s: *State) Error!void {
        var is_exported = false;
        if (s.peekKind() == tok.TOK_EXPORT) {
            is_exported = true;
            try s.advance();
        }

        const saved_namespace_export = s.namespace_export;
        s.namespace_export = is_exported;
        defer s.namespace_export = saved_namespace_export;

        try parseStatementOrDecl(s, DeclMask{ .func = true, .func_with_label = true, .other = true });
    }

    /// Mirror `js_parse_statement_or_decl` (`quickjs.c:28228`).
    pub fn parseStatementOrDecl(s: *State, decl_mask: DeclMask) Error!void {
        s.features.insert(.statement);
        const tok_kind = s.peekKind();

        // Keep recursive function declarations out of the large statement
        // dispatcher. Debug codegen otherwise retains storage for every switch
        // arm across every nested body and exhausts the native stack budget.
        if (tok_kind == tok.TOK_FUNCTION) {
            if (!decl_mask.func and !decl_mask.func_with_label) return Error.UnexpectedToken;
            const source_start = s.currentTokenStartOffset();
            try parseFunctionDecl(s, .normal, source_start);
            return;
        }
        if (tok_kind == tok.TOK_IDENT and
            s.isIdent("async") and
            s.peekNextKindNoLineTerminator(tok.TOK_FUNCTION))
        {
            if (!decl_mask.func and !decl_mask.func_with_label) return Error.UnexpectedToken;
            const source_start = s.currentTokenStartOffset();
            try s.advance();
            try parseFunctionDecl(s, .async, source_start);
            return;
        }

        try parseStatementOrDeclSlow(s, decl_mask);
    }

    fn parseStatementOrDeclSlow(s: *State, decl_mask: DeclMask) Error!void {
        const tok_kind = s.peekKind();

        if (s.labelStartAtom()) |label_atom| {
            if (s.isReservedLabelIdentifier(label_atom)) return Error.UnexpectedToken;
            if (s.hasActiveLabel(label_atom)) return Error.UnexpectedToken;

            try s.advance();
            try s.expectToken(':');

            const labelled_kind = s.peekKind();
            if (labelled_kind == tok.TOK_WHILE or labelled_kind == tok.TOK_DO or labelled_kind == tok.TOK_FOR or labelled_kind == tok.TOK_SWITCH) {
                const saved_pending_label = s.pending_label_atom;
                s.pending_label_atom = label_atom;
                defer s.pending_label_atom = saved_pending_label;
                try parseStatementOrDecl(s, decl_mask);
                return;
            }

            const label_frame = try s.pushLabelFrame(label_atom, false);
            errdefer s.popLabelFrame(label_frame);
            var label_block: BlockEnv = undefined;
            pushControlBlock(s, &label_block, label_atom, true, false, true, s.scope_level, 0, false);
            var label_block_active = true;
            defer if (label_block_active) popControlBlock(s, &label_block);
            if (labelled_kind == tok.TOK_CLASS or
                (labelled_kind == tok.TOK_FUNCTION and s.peekNextKind() == @as(tok.TokenKind, @intCast('*'))) or
                (labelled_kind == tok.TOK_IDENT and s.isIdent("async") and s.peekNextKind() == tok.TOK_FUNCTION))
            {
                return Error.UnexpectedToken;
            }
            const mask = if (!s.cur_func().is_strict_mode and decl_mask.func_with_label)
                DeclMask{ .func = true, .func_with_label = true }
            else
                DeclMask{};
            try parseStatementOrDecl(s, mask);
            popControlBlock(s, &label_block);
            label_block_active = false;
            try s.patchLabelBreaks(label_frame);
            s.popLabelFrame(label_frame);
            return;
        }

        switch (tok_kind) {
            '{' => try parseBlock(s),
            tok.TOK_STRING => {
                const keep_completion = expressionStatementKeepsCompletion(s);
                try parseExpr2(s, ParseFlags{ .in_accepted = true, .result_needed = keep_completion });
                _ = try s.expectSemicolon();
                if (keep_completion) {
                    try s.emitEvalRetPut();
                } else {
                    try s.emitOpNoSource(opcode.op.drop);
                }
            },
            tok.TOK_ENUM => {
                if (!s.lex.is_typescript) {
                    return Error.UnexpectedToken;
                }
                try parseEnumDeclaration(s);
            },
            tok.TOK_RETURN => {
                if (s.is_eval or s.return_depth == 0) return Error.UnexpectedToken;
                const statement_source = SourcePosition{
                    .line_num = s.token.line_num,
                    .col_num = s.token.col_num,
                };
                try s.advance();
                const has_expr = s.peekKind() != ';' and s.peekKind() != '}' and !s.gotLineTerminator();
                if (has_expr) try parseExpr(s);
                const return_snapshot = s.takeEmissionSnapshot();
                errdefer s.rollbackEmission(return_snapshot);
                const updated_source_loc = try reattributeReturnTailCallSource(s, has_expr, statement_source);
                errdefer if (updated_source_loc) |updated| restoreSourceLoc(s, updated);
                const saved_source_override = s.opcode_source_override;
                s.opcode_source_override = statement_source;
                defer s.opcode_source_override = saved_source_override;
                try emitParsedReturn(s, has_expr);
                _ = try s.expectSemicolon();
            },
            tok.TOK_THROW => {
                const statement_source = SourcePosition{
                    .line_num = s.token.line_num,
                    .col_num = s.token.col_num,
                };
                try s.advance();
                if (s.gotLineTerminator()) return Error.UnexpectedToken;
                try parseExpr(s);
                const saved_source_override = s.opcode_source_override;
                s.opcode_source_override = statement_source;
                defer s.opcode_source_override = saved_source_override;
                try s.emitOp(opcode.op.throw);
                _ = try s.expectSemicolon();
            },
            tok.TOK_VAR, tok.TOK_LET, tok.TOK_CONST => {
                if (tok_kind == tok.TOK_LET and canTreatLetAsExpressionStatement(s, decl_mask)) {
                    try parseLetKeywordExpressionStatement(s);
                    return;
                }
                if (s.lex.is_typescript and tok_kind == tok.TOK_CONST and s.peekNextKind() == tok.TOK_ENUM) {
                    try s.advance();
                    try parseEnumDeclaration(s);
                    return;
                }
                if (!decl_mask.other and (tok_kind == tok.TOK_LET or tok_kind == tok.TOK_CONST)) {
                    return Error.UnexpectedToken;
                }
                const var_tok = tok_kind;
                try s.advance();
                s.last_var_decl_atom = null;
                try parseVar(s, var_tok, false, ParseFlags.default);
                _ = try s.expectSemicolon();
            },
            tok.TOK_FUNCTION => {
                if (!decl_mask.func and !decl_mask.func_with_label) {
                    return Error.UnexpectedToken;
                }
                // Check for async function
                const is_async = s.isIdent("async");
                const source_start = s.currentTokenStartOffset();
                if (is_async) {
                    try s.advance();
                }
                const func_kind: ParseFunctionKind = if (is_async) .async else .normal;
                try parseFunctionDecl(s, func_kind, source_start);
            },
            tok.TOK_CLASS => {
                if (!decl_mask.func) {
                    return Error.UnexpectedToken;
                }
                try parseClass(s, true);
            },
            tok.TOK_IDENT => {
                if (s.lex.is_typescript and s.isIdent("namespace") and s.peekNextKind() == tok.TOK_IDENT) {
                    try parseNamespaceDeclaration(s);
                    return;
                }
                if (usingDeclarationStart(s)) {
                    if (!decl_mask.other) return Error.UnexpectedToken;
                    try parseUsingDeclaration(s, .sync);
                    _ = try s.expectSemicolon();
                    return;
                }
                // Check for async function declaration (async is a contextual keyword)
                if (s.isIdent("async") and s.peekNextKindNoLineTerminator(tok.TOK_FUNCTION)) {
                    if (!decl_mask.func and !decl_mask.func_with_label) {
                        return Error.UnexpectedToken;
                    }
                    const source_start = s.currentTokenStartOffset();
                    try s.advance(); // consume async
                    const func_kind: ParseFunctionKind = .async;
                    try parseFunctionDecl(s, func_kind, source_start);
                    return;
                }
                // Not async function: fall through to expression statement.
                // Like the `else` branch, eval mode redirects the value
                // into `<ret>` instead of dropping it.
                const keep_completion = expressionStatementKeepsCompletion(s);
                try parseExpr2(s, ParseFlags{ .in_accepted = true, .result_needed = keep_completion });
                _ = try s.expectSemicolon();
                if (keep_completion) {
                    try s.emitEvalRetPut();
                } else {
                    try s.emitOpNoSource(opcode.op.drop);
                }
            },
            tok.TOK_AWAIT => {
                if (awaitUsingDeclarationStart(s)) {
                    if (!decl_mask.other) return Error.UnexpectedToken;
                    try parseUsingDeclaration(s, .async);
                    _ = try s.expectSemicolon();
                    return;
                }
                const keep_completion = expressionStatementKeepsCompletion(s);
                try parseExpr2(s, ParseFlags{ .in_accepted = true, .result_needed = keep_completion });
                _ = try s.expectSemicolon();
                if (keep_completion) {
                    try s.emitEvalRetPut();
                } else {
                    try s.emitOpNoSource(opcode.op.drop);
                }
            },
            tok.TOK_IMPORT => {
                const import_next = s.peekNextKind();
                if (import_next == @as(tok.TokenKind, @intCast('(')) or import_next == @as(tok.TokenKind, @intCast('.'))) {
                    const keep_completion = expressionStatementKeepsCompletion(s);
                    try parseExpr2(s, ParseFlags{ .in_accepted = true, .result_needed = keep_completion });
                    _ = try s.expectSemicolon();
                    if (keep_completion) {
                        try s.emitEvalRetPut();
                    } else {
                        try s.emitOpNoSource(opcode.op.drop);
                    }
                    return;
                }
                if (!decl_mask.other or !canParseModuleDeclarationHere(s)) {
                    return Error.UnexpectedToken;
                }
                try parseImport(s);
            },
            tok.TOK_EXPORT => {
                if (!decl_mask.other or !canParseModuleDeclarationHere(s)) {
                    return Error.UnexpectedToken;
                }
                try parseExport(s);
            },
            tok.TOK_IF => {
                try s.advance();
                // QuickJS creates one wrapper scope for the whole IfStatement,
                // before the condition. Both Annex-B clauses share it.
                try s.pushScope();
                errdefer s.popScopeIdentity();
                try s.setEvalReturnUndefined();
                try s.expectToken('(');
                try parseExpr2(s, ParseFlags{ .in_accepted = true, .result_needed = true });
                try s.expectToken(')');
                const if_false_off = try emitForwardJump(s, opcode.op.if_false);
                const allow_annex_b_if_function = !s.is_strict and !s.cur_func().is_strict_mode;
                const then_is_annex_b_function =
                    allow_annex_b_if_function and
                    s.peekKind() == tok.TOK_FUNCTION and
                    s.peekNextKind() != @as(tok.TokenKind, @intCast('*'));
                const then_decl_mask = if (then_is_annex_b_function) DeclMask{ .func = true } else DeclMask{};
                const saved_annex_b_if_function_decl_clause = s.annex_b_if_function_decl_clause;
                s.annex_b_if_function_decl_clause = then_is_annex_b_function;
                defer s.annex_b_if_function_decl_clause = saved_annex_b_if_function_decl_clause;
                try parseStatementOrDecl(s, then_decl_mask);
                s.annex_b_if_function_decl_clause = saved_annex_b_if_function_decl_clause;
                if (s.peekKind() == tok.TOK_ELSE) {
                    try s.advance();
                    const else_goto_off = try emitForwardJump(s, opcode.op.goto);
                    // Patch if_false to land at the start of the else block.
                    try patchForwardJump(s, if_false_off);
                    const else_is_annex_b_function =
                        allow_annex_b_if_function and
                        s.peekKind() == tok.TOK_FUNCTION and
                        s.peekNextKind() != @as(tok.TokenKind, @intCast('*'));
                    const else_decl_mask = if (else_is_annex_b_function) DeclMask{ .func = true } else DeclMask{};
                    s.annex_b_if_function_decl_clause = else_is_annex_b_function;
                    try parseStatementOrDecl(s, else_decl_mask);
                    s.annex_b_if_function_decl_clause = saved_annex_b_if_function_decl_clause;
                    // Patch the goto-over-else to land after the else block.
                    try patchForwardJump(s, else_goto_off);
                } else {
                    // No else: patch if_false to land just past the then block.
                    try patchForwardJump(s, if_false_off);
                }
                try s.popScope();
            },
            tok.TOK_WHILE => {
                try s.advance();
                const loop_label = s.pending_label_atom;
                s.pending_label_atom = null;
                try s.setEvalReturnUndefined();
                try s.expectToken('(');
                // Loop top: condition is evaluated each iteration.
                const top_pc: u32 = @intCast(s.currentCodeLen());
                try parseExpr(s);
                const exit_off = try emitForwardJump(s, opcode.op.if_false);
                try s.expectToken(')');
                try pushBreakFrame(s);
                const label_frame = if (loop_label) |atom_id| try s.pushLabelFrame(atom_id, true) else null;
                var loop_block: BlockEnv = undefined;
                pushControlBlock(s, &loop_block, loop_label, true, true, false, s.scope_level, 0, false);
                var loop_block_active = true;
                defer if (loop_block_active) popControlBlock(s, &loop_block);
                try parseStatementOrDecl(s, DeclMask{});
                try patchContinueFrame(s);
                if (label_frame) |idx| try s.patchLabelContinues(idx);
                // Back-edge to the top to re-test the condition.
                try emitBackwardJump(s, opcode.op.goto, top_pc);
                // Patch the if_false exit to land here.
                try patchForwardJump(s, exit_off);
                popControlBlock(s, &loop_block);
                loop_block_active = false;
                try popBreakFrameAndPatch(s);
                if (label_frame) |idx| {
                    try s.patchLabelBreaks(idx);
                    s.popLabelFrame(idx);
                }
            },
            tok.TOK_WITH => try parseWith(s),
            tok.TOK_DO => {
                try s.advance();
                const loop_label = s.pending_label_atom;
                s.pending_label_atom = null;
                try s.setEvalReturnUndefined();
                // Body starts at this pc; if_true at the bottom branches back here.
                const body_pc: u32 = @intCast(s.currentCodeLen());
                try pushBreakFrame(s);
                const label_frame = if (loop_label) |atom_id| try s.pushLabelFrame(atom_id, true) else null;
                var loop_block: BlockEnv = undefined;
                pushControlBlock(s, &loop_block, loop_label, true, true, false, s.scope_level, 0, false);
                var loop_block_active = true;
                defer if (loop_block_active) popControlBlock(s, &loop_block);
                try parseStatementOrDecl(s, DeclMask{});
                try patchContinueFrame(s);
                if (label_frame) |idx| try s.patchLabelContinues(idx);
                try s.expectToken(tok.TOK_WHILE);
                try s.expectToken('(');
                try parseExpr(s);
                try s.expectToken(')');
                // Back-edge: re-enter body when the test is truthy.
                try emitBackwardJump(s, opcode.op.if_true, body_pc);
                if (s.isPunct(';')) try s.advance();
                popControlBlock(s, &loop_block);
                loop_block_active = false;
                try popBreakFrameAndPatch(s);
                if (label_frame) |idx| {
                    try s.patchLabelBreaks(idx);
                    s.popLabelFrame(idx);
                }
            },
            tok.TOK_FOR => {
                try s.advance();
                const loop_label = s.pending_label_atom;
                s.pending_label_atom = null;
                try s.setEvalReturnUndefined();
                if (s.peekKind() == tok.TOK_AWAIT) {
                    if (!s.in_async) return Error.AwaitOutsideAsyncFunction;
                    try s.advance();
                    try s.expectToken('(');
                    s.pending_label_atom = loop_label;
                    try parseForInOf(s, true);
                    return;
                }
                try s.expectToken('(');

                // QuickJS routes every head without a top-level semicolon to
                // the for-in/of grammar; that parser performs the real LHS and
                // `in`/`of` validation.
                const is_for_in_of = s.forHeadHasNoTopLevelSemicolon();
                if (is_for_in_of) {
                    s.pending_label_atom = loop_label;
                    try parseForInOf(s, false);
                } else {
                    const block_scope_level = s.scope_level;
                    var for_scope_pushed = false;
                    var for_head_is_lexical = false;
                    var for_has_initializer = false;
                    const for_using_frame_len = s.using_block_frames.items.len;
                    const for_using_catch_marker_depth = s.active_catch_marker_depth;
                    var for_using_frame_active = false;
                    errdefer {
                        if (for_using_frame_active) {
                            restoreUsingBlockFramesAfterError(s, for_using_frame_len, for_using_catch_marker_depth);
                        }
                        if (for_scope_pushed) s.popScopeIdentity();
                    }
                    // C-style `for (init ; test ; update) body`. Lower as:
                    //   init
                    //   top: test ; if_false → end ; body ; update ; goto → top
                    //   end:
                    // This pattern keeps `continue` semantics consistent by
                    // routing continue targets through the update block.
                    // QuickJS creates this head scope for every classic for,
                    // even when the initializer is empty or non-lexical.
                    try s.pushScope();
                    for_scope_pushed = true;
                    if (directUsingDeclarationKind(s)) |using_kind| {
                        for_head_is_lexical = true;
                        for_has_initializer = true;
                        try s.using_block_frames.append(s.function.memory.allocator, .{});
                        for_using_frame_active = true;
                        try parseUsingDeclaration(s, using_kind);
                        try s.expectToken(';');
                    } else if ((s.peekKind() == tok.TOK_VAR or s.peekKind() == tok.TOK_LET or s.peekKind() == tok.TOK_CONST) and
                        !s.canTreatLetAsForInitializerExpression())
                    {
                        const var_tok = s.peekKind();
                        try s.advance();
                        if (var_tok == tok.TOK_LET or var_tok == tok.TOK_CONST) {
                            for_head_is_lexical = true;
                        }
                        for_has_initializer = true;
                        const saved_tdz_at_decl = s.emit_lexical_tdz_at_decl;
                        s.emit_lexical_tdz_at_decl = for_head_is_lexical;
                        defer s.emit_lexical_tdz_at_decl = saved_tdz_at_decl;
                        try parseVar(s, var_tok, false, ParseFlags{ .in_accepted = false });
                        try s.expectToken(';');
                    } else if (s.peekKind() != ';') {
                        for_has_initializer = true;
                        try parseExpr2(s, ParseFlags{ .in_accepted = false });
                        try s.emitOp(opcode.op.drop);
                        try s.expectToken(';');
                    } else {
                        try s.advance(); // consume ';'
                    }
                    if (for_has_initializer) try s.closeScopes(s.scope_level, block_scope_level);

                    // Top of the loop — re-tested each iteration.
                    try s.emitOpU32(opcode.op.label, 0);
                    const top_pc: u32 = @intCast(s.currentCodeLen());

                    // Test condition.
                    if (s.peekKind() != ';') {
                        try parseExpr(s);
                    } else {
                        try s.emitOp(opcode.op.push_true);
                    }
                    try s.expectToken(';');

                    const exit_off = try emitForwardJump(s, opcode.op.if_false);

                    // Parse the update while still inside the parenthesized
                    // for-head, then move its emitted bytes after the body.
                    const update_start = s.currentCodeLen();
                    const update_atom_start = s.currentAtomOperandLen();
                    if (s.peekKind() != ')') {
                        // Phase 1 keeps the normal expression result and emits
                        // the discard explicitly, like QuickJS. The final pass
                        // owns the `post_inc; put; drop` -> `inc_loc` rewrite.
                        try parseExpr2(s, ParseFlags{ .in_accepted = true, .result_needed = false });
                        try s.emitOp(opcode.op.drop);
                    }
                    const update_code = s.currentCode()[update_start..];
                    const update_atoms = s.currentAtomOperands()[update_atom_start..];
                    var saved_update: []u8 = &.{};
                    if (update_code.len != 0) {
                        saved_update = try s.function.memory.alloc(u8, update_code.len);
                        @memcpy(saved_update, update_code);
                    }
                    defer if (saved_update.len != 0) s.function.memory.free(u8, saved_update);
                    var saved_update_atoms: []Atom = &.{};
                    if (update_atoms.len != 0) {
                        saved_update_atoms = try s.function.memory.alloc(Atom, update_atoms.len);
                        for (update_atoms, saved_update_atoms) |atom_id, *slot| {
                            slot.* = s.function.atoms.dup(atom_id);
                        }
                    }
                    defer if (saved_update_atoms.len != 0) {
                        for (saved_update_atoms) |atom_id| s.function.atoms.free(atom_id);
                        s.function.memory.free(Atom, saved_update_atoms);
                    };
                    try s.truncateCode(update_start);
                    try s.truncateAtomOperands(update_atom_start);
                    try s.expectToken(')');
                    // Body.
                    try pushBreakFrame(s);
                    const label_frame = if (loop_label) |atom_id| try s.pushLabelFrame(atom_id, true) else null;
                    var loop_block: BlockEnv = undefined;
                    pushControlBlock(s, &loop_block, loop_label, true, true, false, s.scope_level, 0, false);
                    var loop_block_active = true;
                    defer if (loop_block_active) popControlBlock(s, &loop_block);
                    try parseStatementOrDecl(s, DeclMask{});

                    // Update: run after normal body completion and continue paths.
                    try s.closeScopes(s.scope_level, block_scope_level);
                    try patchContinueFrame(s);
                    if (label_frame) |idx| try s.patchLabelContinues(idx);
                    if (saved_update.len != 0) {
                        try s.appendMovedCodeWithAtoms(saved_update, saved_update_atoms, update_start);
                    }

                    // Back-edge to the top.
                    try emitBackwardJump(s, opcode.op.goto, top_pc);

                    // Patch the `if_false` exit to land here.
                    try patchForwardJump(s, exit_off);
                    popControlBlock(s, &loop_block);
                    loop_block_active = false;
                    try popBreakFrameAndPatch(s);
                    if (label_frame) |idx| {
                        try s.patchLabelBreaks(idx);
                        s.popLabelFrame(idx);
                    }
                    if (for_using_frame_active) {
                        try finalizeCurrentUsingBlockFrame(s);
                        for_using_frame_active = false;
                    }
                    if (for_scope_pushed) {
                        try s.popScope();
                        for_scope_pushed = false;
                    }
                }
            },
            tok.TOK_BREAK, tok.TOK_CONTINUE => {
                const is_break = s.peekKind() == tok.TOK_BREAK;
                try s.advance();
                var label_atom: ?Atom = null;
                if (!s.gotLineTerminator() and isIdentifierLikeToken(s)) {
                    const atom_id = identifierLikeAtom(s);
                    if (s.peekKind() == tok.TOK_IDENT and escapedIdentifierIsReservedWordForCurrentContext(s, atom_id, s.token.payload.ident.has_escape)) return Error.UnexpectedToken;
                    label_atom = atom_id;
                    try s.advance(); // consume the label name
                }
                _ = try s.expectSemicolon();
                if (label_atom) |atom_id| {
                    if (is_break) {
                        try s.emitLabelledBreak(atom_id);
                    } else {
                        try s.emitLabelledContinue(atom_id);
                    }
                    return;
                }
                if (is_break) {
                    if (s.break_frame_lens.items.len == 0) return Error.UnexpectedToken;
                    try emitUnlabelledBreak(s);
                } else {
                    if (s.continue_frame_lens.items.len == 0) return Error.UnexpectedToken;
                    try emitUnlabelledContinue(s);
                }
            },
            tok.TOK_SWITCH => {
                // Simplified switch lowering. Each case checks the discriminant,
                // and a matched case runs its body then jumps to the end (i.e.
                // an *implicit* break). C-style fallthrough between cases is
                // deferred to the fuller switch lowering.
                try s.advance();
                const switch_label = s.pending_label_atom;
                s.pending_label_atom = null;
                try s.expectToken('(');
                try s.setEvalReturnUndefined();
                try parseExpr(s); // discriminant on stack
                try s.expectToken(')');
                try s.expectToken('{');
                try s.pushScope();
                errdefer s.popScopeIdentity();
                const saved_switch_case_block_scope = s.in_switch_case_block_scope;
                s.in_switch_case_block_scope = true;
                defer s.in_switch_case_block_scope = saved_switch_case_block_scope;
                try pushBreakOnlyFrame(s);
                setCurrentBreakCrossCleanupDrops(s, 1);
                enterSwitchContinueCleanup(s);
                defer leaveSwitchContinueCleanup(s);
                const label_frame = if (switch_label) |atom_id| try s.pushLabelFrame(atom_id, false) else null;
                var switch_block: BlockEnv = undefined;
                pushControlBlock(s, &switch_block, switch_label, true, false, false, s.scope_level, 1, false);
                var switch_block_active = true;
                defer if (switch_block_active) popControlBlock(s, &switch_block);

                // Keep unmatched case-test exits separate from matched
                // fallthrough jumps: once a case has matched, later case tests
                // are skipped and only their bodies run.
                var no_match_jumps: [64]usize = undefined;
                var no_match_jumps_count: usize = 0;
                var fallthrough_jump: ?usize = null;
                var has_default = false;
                var default_body_start: ?u32 = null;
                var default_waiting_for_body = false;

                while (s.peekKind() != '}' and s.peekKind() != tok.TOK_EOF) {
                    if (s.peekKind() == tok.TOK_CASE) {
                        for (no_match_jumps[0..no_match_jumps_count]) |off| {
                            try patchForwardJump(s, off);
                        }
                        no_match_jumps_count = 0;

                        try s.advance();
                        // dup ; case_expr ; strict_eq ; if_false → next_case
                        try s.emitOp(opcode.op.dup);
                        try parseExpr(s);
                        try s.expectToken(':');
                        try s.emitOp(opcode.op.strict_eq);
                        const next_case_off = try emitForwardJump(s, opcode.op.if_false);
                        if (no_match_jumps_count >= no_match_jumps.len) return Error.UnexpectedToken;
                        no_match_jumps[no_match_jumps_count] = next_case_off;
                        no_match_jumps_count += 1;
                        if (fallthrough_jump) |off| {
                            try patchForwardJump(s, off);
                            fallthrough_jump = null;
                        }

                        // Matched: keep the discriminant on stack until the
                        // common switch epilogue, matching QuickJS's case shape.
                        const body_start = s.currentCodeLen();
                        const has_case_body = s.peekKind() != tok.TOK_CASE and
                            s.peekKind() != tok.TOK_DEFAULT and
                            s.peekKind() != '}' and
                            s.peekKind() != tok.TOK_EOF;
                        if (default_waiting_for_body and has_case_body) {
                            default_body_start = @intCast(body_start);
                            default_waiting_for_body = false;
                        }
                        const break_count_before_body = s.break_fixups.items.len;
                        while (s.peekKind() != tok.TOK_CASE and
                            s.peekKind() != tok.TOK_DEFAULT and
                            s.peekKind() != '}' and
                            s.peekKind() != tok.TOK_EOF)
                        {
                            try parseStatementOrDecl(s, DeclMask{ .func = true, .func_with_label = true, .other = true });
                        }
                        if ((s.peekKind() == tok.TOK_CASE or s.peekKind() == tok.TOK_DEFAULT) and
                            s.break_fixups.items.len == break_count_before_body and
                            caseCanFallthrough(s))
                        {
                            fallthrough_jump = try emitForwardJump(s, opcode.op.goto);
                        }
                    } else if (s.peekKind() == tok.TOK_DEFAULT) {
                        if (has_default) return Error.UnexpectedToken;
                        try s.advance();
                        try s.expectToken(':');
                        if (no_match_jumps_count == 0) {
                            if (no_match_jumps_count >= no_match_jumps.len) return Error.UnexpectedToken;
                            no_match_jumps[no_match_jumps_count] = try emitForwardJump(s, opcode.op.goto);
                            no_match_jumps_count += 1;
                        }
                        const body_start = s.currentCodeLen();
                        if (fallthrough_jump) |off| {
                            try patchForwardJump(s, off);
                            fallthrough_jump = null;
                        }

                        // Default body label.
                        has_default = true;
                        const break_count_before_body = s.break_fixups.items.len;
                        while (s.peekKind() != tok.TOK_CASE and
                            s.peekKind() != tok.TOK_DEFAULT and
                            s.peekKind() != '}' and
                            s.peekKind() != tok.TOK_EOF)
                        {
                            try parseStatementOrDecl(s, DeclMask{ .func = true, .func_with_label = true, .other = true });
                        }
                        if (s.currentCodeLen() == body_start and s.peekKind() == tok.TOK_CASE) {
                            default_waiting_for_body = true;
                        } else {
                            default_body_start = @intCast(body_start);
                            default_waiting_for_body = false;
                        }
                        if (s.peekKind() == tok.TOK_CASE and
                            s.break_fixups.items.len == break_count_before_body and
                            caseCanFallthrough(s))
                        {
                            fallthrough_jump = try emitForwardJump(s, opcode.op.goto);
                        }
                    } else {
                        return Error.UnexpectedToken;
                    }
                }
                try s.expectToken('}');

                // No case matched — jump to default if it exists, otherwise fall
                // through to the common discriminant drop.
                for (no_match_jumps[0..no_match_jumps_count]) |off| {
                    if (default_body_start) |target| {
                        try patchJumpTarget(s, off, target);
                    } else {
                        try patchForwardJump(s, off);
                    }
                }
                if (fallthrough_jump) |off| try patchForwardJump(s, off);
                popControlBlock(s, &switch_block);
                switch_block_active = false;
                try popBreakOnlyFrameAndPatch(s);
                if (label_frame) |idx| {
                    try s.patchLabelBreaks(idx);
                    s.popLabelFrame(idx);
                }
                try s.emitOp(opcode.op.drop);
                try s.popScope();
            },
            tok.TOK_TRY => {
                try s.advance();
                try s.setEvalReturnUndefined();

                const label_catch = newParserLabel(s);
                const label_catch2 = newParserLabel(s);
                const label_finally = newParserLabel(s);
                const label_end = newParserLabel(s);

                try emitParserLabelJump(s, opcode.op.@"catch", label_catch);
                const outer_catch_depth = s.active_catch_marker_depth;
                s.active_catch_marker_depth += 1;
                const try_frame = try pushReturnFinallyFrame(s, label_finally, outer_catch_depth);
                var try_frame_active = true;
                errdefer {
                    if (try_frame_active) popReturnFinallyFrame(s, try_frame);
                    s.active_catch_marker_depth = outer_catch_depth;
                }

                try parseBlock(s);

                popReturnFinallyFrame(s, try_frame);
                try_frame_active = false;
                s.active_catch_marker_depth = outer_catch_depth;

                if (isLiveCode(s)) {
                    try s.emitOpNoSource(opcode.op.drop);
                    try s.emitOpNoSource(opcode.op.undefined);
                    try emitParserLabelJumpNoSource(s, opcode.op.gosub, label_finally);
                    try s.emitOpNoSource(opcode.op.drop);
                    try emitParserLabelJumpNoSource(s, opcode.op.goto, label_end);
                }

                if (s.peekKind() == tok.TOK_CATCH) {
                    try s.advance();
                    try emitParserLabelNoSource(s, label_catch);

                    try s.pushScope();
                    var catch_binding_scope_active = true;
                    errdefer if (catch_binding_scope_active) s.popScopeIdentity();
                    if (s.peekKind() == '{') {
                        try s.emitOpNoSource(opcode.op.drop);
                    } else {
                        try s.expectToken('(');
                        if (s.peekKind() == '[' or s.peekKind() == '{') {
                            _ = try parseDestructuringElement(
                                s,
                                .{ .binding = .{
                                    .define_type = .let_,
                                    .is_parameter = false,
                                    .export_flag = false,
                                } },
                                true,
                                true,
                                ParseFlags.default,
                            );
                        } else {
                            if (!isIdentifierLikeToken(s)) return Error.UnexpectedToken;
                            const catch_atom = if (s.peekKind() == tok.TOK_IDENT)
                                s.token.payload.ident.atom
                            else
                                tok.keywordAtom(s.peekKind());
                            if ((s.is_strict or s.cur_func().is_strict_mode) and
                                (atomNameEquals(s, catch_atom, "eval") or atomNameEquals(s, catch_atom, "arguments")))
                            {
                                return Error.UnexpectedToken;
                            }
                            _ = try s.defineVar(catch_atom, .catch_);
                            try s.advance();
                            try s.emitScopePutVar(catch_atom);
                        }
                        try s.expectToken(')');
                    }

                    try emitParserLabelJump(s, opcode.op.@"catch", label_catch2);
                    const catch_body_outer_depth = s.active_catch_marker_depth;
                    s.active_catch_marker_depth += 1;
                    const catch_frame = try pushReturnFinallyFrame(s, label_finally, catch_body_outer_depth);
                    var catch_frame_active = true;
                    errdefer {
                        if (catch_frame_active) popReturnFinallyFrame(s, catch_frame);
                        s.active_catch_marker_depth = catch_body_outer_depth;
                    }

                    // QuickJS owns a wrapper scope for the catch statement in
                    // addition to the catch-binding scope and the ordinary
                    // block's own scope.
                    try s.pushScope();
                    var catch_wrapper_scope_active = true;
                    errdefer if (catch_wrapper_scope_active) s.popScopeIdentity();
                    try parseBlock(s);

                    popReturnFinallyFrame(s, catch_frame);
                    catch_frame_active = false;
                    s.active_catch_marker_depth = catch_body_outer_depth;
                    try s.popScope();
                    catch_wrapper_scope_active = false;
                    try s.popScope();
                    catch_binding_scope_active = false;

                    if (isLiveCode(s)) {
                        try s.emitOpNoSource(opcode.op.drop);
                        try s.emitOpNoSource(opcode.op.undefined);
                        try emitParserLabelJumpNoSource(s, opcode.op.gosub, label_finally);
                        try s.emitOpNoSource(opcode.op.drop);
                        try emitParserLabelJumpNoSource(s, opcode.op.goto, label_end);
                    }

                    try emitParserLabelNoSource(s, label_catch2);
                    try emitParserLabelJumpNoSource(s, opcode.op.gosub, label_finally);
                    try s.emitOpNoSource(opcode.op.throw);
                } else if (s.peekKind() == tok.TOK_FINALLY) {
                    try emitParserLabelNoSource(s, label_catch);
                    try emitParserLabelJumpNoSource(s, opcode.op.gosub, label_finally);
                    try s.emitOpNoSource(opcode.op.throw);
                } else {
                    return Error.UnexpectedToken;
                }

                try emitParserLabelNoSource(s, label_finally);
                if (s.peekKind() == tok.TOK_FINALLY) {
                    try s.advance();
                    try parseSharedFinallyBlock(s);
                }
                try s.emitOpNoSource(opcode.op.ret);
                try emitParserLabelNoSource(s, label_end);
            },
            tok.TOK_DEBUGGER => {
                try s.advance();
                _ = try s.expectSemicolon();
            },
            ';' => {
                // Empty statement
                try s.advance();
            },
            else => {
                // Expression statement.
                //
                // Mirrors `quickjs.c:28960`: in eval mode, the last
                // value is stored in `eval_ret_idx` so `eval()` can
                // return it; otherwise it's dropped. `<ret>` is a
                // non-lexical slot so the lowered bytecode is just
                // `put_loc <idx>` (or short form), which the pipeline
                // handles transparently.
                const keep_completion = expressionStatementKeepsCompletion(s);
                try parseExpr2(s, ParseFlags{ .in_accepted = true, .result_needed = keep_completion });
                _ = try s.expectSemicolon();
                if (keep_completion) {
                    try s.emitEvalRetPut();
                } else {
                    try s.emitOpNoSource(opcode.op.drop);
                }
            },
        }
    }

    fn parseUsingDeclaration(s: *State, kind: DisposalHint) Error!void {
        const module_top_level = s.lex.is_module and
            s.top_level_lexical_as_module_ref and
            s.atProgramBodyScope();
        if (kind == .async and !s.in_async and !module_top_level) return Error.AwaitOutsideAsyncFunction;
        if ((!module_top_level and s.atProgramBodyScope()) or s.using_block_frames.items.len == 0) return Error.UnexpectedToken;
        if (kind == .async) try s.advance(); // consume `await`
        try s.advance(); // consume `using`

        while (true) {
            if (!isIdentifierLikeToken(s)) return Error.UnexpectedToken;
            if (identifierLikeHasInvalidEscapeForBinding(s)) return Error.UnexpectedToken;
            const atom_id = identifierLikeAtom(s);
            if (atomNameEquals(s, atom_id, "let")) return Error.UnexpectedToken;
            if ((s.is_strict or s.cur_func().is_strict_mode) and
                (atomNameEquals(s, atom_id, "eval") or atomNameEquals(s, atom_id, "arguments")))
            {
                return Error.UnexpectedToken;
            }
            if (module_top_level and hasKnownBinding(s, atom_id)) return Error.UnexpectedToken;
            _ = try s.defineVar(atom_id, .const_);
            try s.advance();

            if (s.peekKind() != '=') return Error.UnexpectedToken;
            try s.advance();
            const stack_loc = try armCurrentUsingBlockFrame(s);
            {
                s.last_anonymous_function_expr = false;
                const saved_pending_name = s.pending_function_name;
                const saved_pending_decl = s.pending_function_is_decl;
                s.pending_function_name = atom_id;
                s.pending_function_is_decl = false;
                defer {
                    s.pending_function_name = saved_pending_name;
                    s.pending_function_is_decl = saved_pending_decl;
                }
                try parseAssignExpr(s);
                if (s.last_anonymous_function_expr) {
                    try s.emitOpAtom(opcode.op.set_name, atom_id);
                    s.last_anonymous_function_expr = false;
                }
            }
            try s.emitOp(opcode.op.dup);
            try s.emitScopePutVarInit(atom_id);
            const resource_loc = try appendAnonymousTempLocal(s);
            try s.emitOpU16(opcode.op.put_loc, resource_loc);
            try emitUsingAddResource(s, kind, stack_loc, resource_loc);
            try noteUsingResourceHint(s, kind);
            try s.emitCloseLoc(resource_loc);

            if (s.peekKind() != ',') break;
            try s.advance();
        }
    }

    fn canParseModuleDeclarationHere(s: *State) bool {
        return s.lex.is_module and s.atProgramBodyScope();
    }

    /// Mirrors QuickJS `is_let` (quickjs.c:28619), inverted: returns true when
    /// a leading `let` token introduces an ExpressionStatement instead of a
    /// lexical declaration. In qjs, `let [` never introduces an
    /// ExpressionStatement; `let` followed by `{`, a non-reserved identifier,
    /// `let`, `yield`, or `await` is a declaration when there is no
    /// intervening line terminator OR when scanning for a Declaration
    /// (decl_mask & DECL_MASK_OTHER). Anything else is an expression. In
    /// strict mode qjs lexes `let` as TOK_LET and never consults is_let, so
    /// `let` is always a declaration there.
    fn canTreatLetAsExpressionStatement(s: *State, decl_mask: DeclMask) bool {
        if (s.is_strict or s.cur_func().is_strict_mode) return false;
        const saved_pos = s.lex.pos;
        const saved_line = s.lex.line;
        const saved_col = s.lex.col;
        const saved_got_lf = s.lex.got_lf;
        const saved_mark_pos = s.lex.mark_pos;
        const saved_mark_line = s.lex.mark_line;
        const saved_mark_col = s.lex.mark_col;
        const current_line = s.token.line_num;
        const peek_token = s.lex.next() catch return false;
        defer {
            s.lex.freeToken(@constCast(&peek_token));
            s.lex.pos = saved_pos;
            s.lex.line = saved_line;
            s.lex.col = saved_col;
            s.lex.got_lf = saved_got_lf;
            s.lex.mark_pos = saved_mark_pos;
            s.lex.mark_line = saved_mark_line;
            s.lex.mark_col = saved_mark_col;
        }
        const val = peek_token.val;
        if (val == @as(tok.TokenKind, @intCast('['))) {
            // `let [` is a syntax restriction: it never introduces an
            // ExpressionStatement (quickjs.c:28632).
            return false;
        }
        // qjs checks `{`, non-reserved TOK_IDENT, TOK_LET, TOK_YIELD and
        // TOK_AWAIT. In sloppy mode qjs lexes the contextual keywords
        // (static, implements, interface, package, private, protected,
        // public) as plain identifiers (update_token_ident); zjs gives them
        // distinct tokens, so they are matched explicitly here.
        const declaration_start = val == @as(tok.TokenKind, @intCast('{')) or
            val == tok.TOK_IDENT or
            val == tok.TOK_LET or
            val == tok.TOK_YIELD or
            val == tok.TOK_AWAIT or
            val == tok.TOK_STATIC or
            isSloppyFutureReservedToken(val);
        if (declaration_start) {
            // Check for possible ASI if not scanning for a Declaration
            // (quickjs.c:28644-28652).
            if (peek_token.line_num == current_line or decl_mask.other) return false;
            return true;
        }
        return true;
    }

    fn parseLetKeywordExpressionStatement(s: *State) Error!void {
        const keep_completion = expressionStatementKeepsCompletion(s);
        try parseExpr2(s, ParseFlags{ .in_accepted = true, .result_needed = keep_completion });
        _ = try s.expectSemicolon();
        if (keep_completion) {
            try s.emitEvalRetPut();
        } else {
            try s.emitOpNoSource(opcode.op.drop);
        }
    }

    fn pushReturnFinallyFrame(
        s: *State,
        finally_label: ParserLabelRef,
        catch_marker_depth: u32,
    ) Error!usize {
        if (catch_marker_depth > s.active_catch_marker_depth) return Error.UnexpectedToken;
        try s.return_finally_frames.append(s.function.memory.allocator, .{
            .finally_label = finally_label,
            .scope_level = s.scope_level,
            .catch_marker_depth = catch_marker_depth,
            .break_depth = s.break_frame_lens.items.len,
            .continue_depth = s.continue_frame_lens.items.len,
            .label_depth = s.label_frames.items.len,
            .block_boundary = s.top_break,
        });
        return s.return_finally_frames.items.len - 1;
    }

    fn popReturnFinallyFrame(s: *State, frame_index: usize) void {
        std.debug.assert(frame_index + 1 == s.return_finally_frames.items.len);
        _ = s.return_finally_frames.pop().?;
    }

    fn enterReturnFinallyFunctionBoundary(s: *State) ReturnFinallyBoundary {
        const saved = ReturnFinallyBoundary{
            .frames = s.return_finally_frames,
            .finally_body_control_frames = s.finally_body_control_frames,
        };
        s.return_finally_frames = .empty;
        s.finally_body_control_frames = .empty;
        return saved;
    }

    fn leaveReturnFinallyFunctionBoundary(s: *State, saved: *const ReturnFinallyBoundary) void {
        s.return_finally_frames.deinit(s.function.memory.allocator);
        s.return_finally_frames = saved.frames;
        s.finally_body_control_frames.deinit(s.function.memory.allocator);
        s.finally_body_control_frames = saved.finally_body_control_frames;
    }

    fn controlTargetCrossesFinallyFrame(s: *State, target: FinallyControlTarget, frame_index: usize) Error!bool {
        const frame = s.return_finally_frames.items[frame_index];
        if (target.label_atom) |atom_id| {
            const label_frame_index = s.findLabelFrame(atom_id) orelse return Error.UnexpectedToken;
            if (target.kind == .@"continue" and !s.label_frames.items[label_frame_index].allow_continue) {
                return Error.UnexpectedToken;
            }
            return label_frame_index < frame.label_depth;
        }
        return switch (target.kind) {
            .@"break" => s.break_frame_lens.items.len <= frame.break_depth,
            .@"continue" => s.continue_frame_lens.items.len <= frame.continue_depth,
        };
    }

    fn controlTargetCrossesFinallyBody(s: *State, target: FinallyControlTarget, frame_index: usize) Error!bool {
        const frame = s.finally_body_control_frames.items[frame_index];
        if (target.label_atom) |atom_id| {
            const label_frame_index = s.findLabelFrame(atom_id) orelse return Error.UnexpectedToken;
            if (target.kind == .@"continue" and !s.label_frames.items[label_frame_index].allow_continue) {
                return Error.UnexpectedToken;
            }
            return label_frame_index < frame.label_depth;
        }
        return switch (target.kind) {
            .@"break" => s.break_frame_lens.items.len <= frame.break_depth,
            .@"continue" => s.continue_frame_lens.items.len <= frame.continue_depth,
        };
    }

    /// Parse the syntactic finalizer once. Its BlockEnv is the ordered seam
    /// used by return/control walkers to discard the completion and gosub PC
    /// only when an abrupt completion crosses out of this body.
    fn parseSharedFinallyBlock(s: *State) Error!void {
        var block = BlockEnv{
            .prev = s.top_break,
            .label_name = atom_module.null_atom,
            .label_break = -1,
            .label_cont = -1,
            .drop_count = 2,
            .label_finally = -1,
            .scope_level = s.scope_level,
            .catch_marker_depth = s.active_catch_marker_depth,
            .has_iterator = false,
            .is_regular_stmt = false,
        };
        s.top_break = &block;
        defer {
            std.debug.assert(s.top_break == &block);
            s.top_break = block.prev;
        }

        try s.finally_body_control_frames.append(s.function.memory.allocator, .{
            .block = &block,
            .catch_marker_depth = s.active_catch_marker_depth,
            .break_depth = s.break_frame_lens.items.len,
            .continue_depth = s.continue_frame_lens.items.len,
            .label_depth = s.label_frames.items.len,
        });
        defer _ = s.finally_body_control_frames.pop().?;

        var saved_eval_ret_idx: ?u16 = null;
        if (s.eval_ret_idx >= 0) {
            const idx = try s.appendFunctionVarAtOrigin(State.eval_ret_atom, 0);
            saved_eval_ret_idx = idx;
            try s.emitEvalRetGet();
            try s.emitOpU16(opcode.op.put_loc, idx);
            try s.setEvalReturnUndefined();
        }

        try parseBlock(s);

        if (saved_eval_ret_idx) |idx| {
            try s.emitOpU16(opcode.op.get_loc, idx);
            try s.emitEvalRetPut();
        }
    }

    /// Emit a return whose value is already on TOS. The mutable BlockEnv and
    /// catch cursors ensure each iterator/catch record is unwound once while
    /// all active finalizers share the same gosub target.
    fn emitReturnValue(s: *State, await_before_unwind: bool) Error!void {
        if (await_before_unwind) try s.emitOp(opcode.op.await);

        var block_cursor = s.top_break;
        var catch_marker_depth = s.active_catch_marker_depth;
        var frame_index = s.return_finally_frames.items.len;
        while (frame_index != 0) {
            frame_index -= 1;
            const frame = s.return_finally_frames.items[frame_index];
            try emitBlockEnvReturnCleanupUntil(s, &block_cursor, frame.block_boundary, &catch_marker_depth);
            try emitStackTopCatchMarkerDropsToDepth(s, &catch_marker_depth, frame.catch_marker_depth);
            try emitParserLabelJumpNoSource(s, opcode.op.gosub, frame.finally_label);
        }
        try emitBlockEnvReturnCleanupUntil(s, &block_cursor, null, &catch_marker_depth);
        try emitStackTopCatchMarkerDropsToDepth(s, &catch_marker_depth, 0);
        try emitFunctionReturn(s, true);
    }

    /// Complete a return after its optional expression has been parsed exactly
    /// once. Async-generator explicit values await before any cleanup, matching
    /// QuickJS emit_return.
    const UpdatedSourceLoc = struct {
        index: usize,
        previous: bytecode.pipeline_pc2line.SourceLocSlot,
    };

    fn restoreSourceLoc(s: *State, updated: UpdatedSourceLoc) void {
        const slots = if (s.emit_to_function_def)
            s.cur_func().source_loc_slots
        else
            s.function.source_loc_slots;
        std.debug.assert(updated.index < slots.len);
        slots[updated.index] = updated.previous;
    }

    fn reattributeReturnTailCallSource(s: *State, has_expr: bool, source: SourcePosition) Error!?UpdatedSourceLoc {
        if (!has_expr or s.in_async or s.in_generator or (s.in_constructor and s.class_has_extends)) return null;
        if (s.return_finally_frames.items.len != 0 or
            s.finally_body_control_frames.items.len != 0 or
            s.top_break != null or
            s.active_catch_marker_depth != 0)
        {
            return null;
        }

        // QuickJS resolve_labels recognizes `call[method] ; OP_line_num ;
        // return`, attributes the call/tail-call PC to the return keyword, and
        // only then shortens the opcode. zjs intentionally keeps ordinary
        // calls, but its diagnostic PC must retain the same source mapping.
        const last_opcode_pos = s.cur_func().last_opcode_pos;
        if (last_opcode_pos < 0) return null;
        const pc_index: usize = @intCast(last_opcode_pos);
        const pc: u32 = @intCast(pc_index);
        const code = s.currentCode();
        if (pc_index >= code.len) return null;
        const op_id = code[pc_index];
        if (op_id != opcode.op.call and op_id != opcode.op.call_method) return null;

        const slots = if (s.emit_to_function_def)
            s.cur_func().source_loc_slots
        else
            s.function.source_loc_slots;
        var index = slots.len;
        while (index != 0) {
            index -= 1;
            if (slots[index].pc < pc) break;
            if (slots[index].pc == pc) {
                const previous = slots[index];
                slots[index].line_num = @intCast(source.line_num);
                slots[index].col_num = @intCast(source.col_num);
                return .{ .index = index, .previous = previous };
            }
        }
        if (s.emit_to_function_def) {
            try s.cur_func().appendSourceLoc(pc, @intCast(source.line_num), @intCast(source.col_num));
        } else {
            try s.function.appendSourceLoc(pc, @intCast(source.line_num), @intCast(source.col_num));
        }
        return null;
    }

    fn emitParsedReturn(s: *State, has_expr: bool) Error!void {
        const needs_value = has_expr or
            s.in_async or
            s.in_generator or
            s.return_finally_frames.items.len != 0 or
            s.finally_body_control_frames.items.len != 0 or
            s.top_break != null or
            s.active_catch_marker_depth != 0;
        if (!needs_value) {
            try emitFunctionReturn(s, false);
            return;
        }
        if (!has_expr) try s.emitOp(opcode.op.undefined);
        try emitReturnValue(s, has_expr and s.in_async and s.in_generator);
    }

    fn emitFunctionReturn(s: *State, has_value: bool) Error!void {
        var value_on_stack = has_value;
        if (!value_on_stack and (s.in_async or s.in_generator)) {
            try s.emitOp(opcode.op.undefined);
            value_on_stack = true;
        }

        if (s.in_constructor and s.class_has_extends) {
            if (value_on_stack) {
                try s.emitOp(opcode.op.check_ctor_return);
                const return_value = try emitForwardJump(s, opcode.op.if_false);
                try s.emitOp(opcode.op.drop);
                try s.emitScopeGetVarCheckThis(atom_this);
                try patchForwardJump(s, return_value);
            } else {
                try s.emitScopeGetVarCheckThis(atom_this);
            }
            try s.emitOp(opcode.op.@"return");
        } else if (s.in_async or s.in_generator) {
            try s.emitOp(opcode.op.return_async);
        } else {
            try s.emitOp(if (value_on_stack) opcode.op.@"return" else opcode.op.return_undef);
        }
    }

    fn emitCapturedControlThroughFinally(s: *State, target: FinallyControlTarget) Error!bool {
        var frame_index = s.return_finally_frames.items.len;
        while (frame_index != 0) {
            frame_index -= 1;
            if (try controlTargetCrossesFinallyFrame(s, target, frame_index)) {
                try emitControlThroughFinally(s, target);
                return true;
            }
        }
        var body_index = s.finally_body_control_frames.items.len;
        while (body_index != 0) {
            body_index -= 1;
            if (try controlTargetCrossesFinallyBody(s, target, body_index)) {
                try emitControlThroughFinally(s, target);
                return true;
            }
        }
        return false;
    }

    const ResolvedFinallyControlTarget = struct {
        depth: usize,
        catch_marker_depth: u32,
        cleanup_drops: u8,
        label_frame_index: ?usize,
    };

    fn resolveFinallyControlTarget(s: *State, target: FinallyControlTarget) Error!ResolvedFinallyControlTarget {
        if (target.label_atom) |atom_id| {
            const label_index = s.findLabelFrame(atom_id) orelse return Error.UnexpectedToken;
            const label_frame = s.label_frames.items[label_index];
            return switch (target.kind) {
                .@"break" => .{
                    .depth = label_frame.break_frame_depth,
                    .catch_marker_depth = label_frame.catch_marker_depth,
                    .cleanup_drops = if (label_frame.allow_continue and label_frame.break_frame_depth > 0)
                        s.break_frame_cleanup_drops.items[label_frame.break_frame_depth - 1]
                    else
                        0,
                    .label_frame_index = label_index,
                },
                .@"continue" => blk: {
                    if (!label_frame.allow_continue or label_frame.control_frame_depth == 0) {
                        return Error.UnexpectedToken;
                    }
                    break :blk .{
                        .depth = label_frame.control_frame_depth,
                        .catch_marker_depth = label_frame.catch_marker_depth,
                        .cleanup_drops = s.continue_frame_cleanup_drops.items[label_frame.control_frame_depth - 1],
                        .label_frame_index = label_index,
                    };
                },
            };
        }

        return switch (target.kind) {
            .@"break" => blk: {
                if (s.break_frame_lens.items.len == 0) return Error.UnexpectedToken;
                break :blk .{
                    .depth = s.break_frame_lens.items.len,
                    .catch_marker_depth = s.break_frame_catch_marker_depths.getLast(),
                    .cleanup_drops = s.break_frame_cleanup_drops.getLast(),
                    .label_frame_index = null,
                };
            },
            .@"continue" => blk: {
                if (s.continue_frame_lens.items.len == 0) return Error.UnexpectedToken;
                break :blk .{
                    .depth = s.continue_frame_lens.items.len,
                    .catch_marker_depth = s.continue_frame_catch_marker_depths.getLast(),
                    .cleanup_drops = s.continue_frame_cleanup_drops.getLast(),
                    .label_frame_index = null,
                };
            },
        };
    }

    fn controlBlockMatchesTarget(block: *const BlockEnv, target: FinallyControlTarget) bool {
        if (target.label_atom) |atom_id| {
            return switch (target.kind) {
                .@"break" => block.label_break >= 0 and block.label_name == atom_id,
                .@"continue" => block.label_cont >= 0 and block.label_name == atom_id,
            };
        }
        return switch (target.kind) {
            .@"break" => block.label_break >= 0 and !block.is_regular_stmt,
            .@"continue" => block.label_cont >= 0,
        };
    }

    fn emitResolvedControlJump(
        s: *State,
        target: FinallyControlTarget,
        resolved: ResolvedFinallyControlTarget,
    ) Error!void {
        const off = try emitForwardJumpNoSource(s, opcode.op.goto);
        if (resolved.label_frame_index) |label_index| {
            switch (target.kind) {
                .@"break" => try s.label_frames.items[label_index].break_fixups.append(s.function.memory.allocator, off),
                .@"continue" => try s.label_frames.items[label_index].continue_fixups.append(s.function.memory.allocator, off),
            }
        } else switch (target.kind) {
            .@"break" => try s.break_fixups.append(s.function.memory.allocator, off),
            .@"continue" => try s.continue_fixups.append(s.function.memory.allocator, off),
        }
    }

    fn emitCrossedControlBlockCleanup(s: *State, block: *const BlockEnv) Error!void {
        var dropped: i32 = 0;
        if (block.has_iterator) {
            try s.emitOpNoSource(opcode.op.iterator_close);
            dropped = 3;
        }
        while (dropped < block.drop_count) : (dropped += 1) {
            try s.emitOpNoSource(opcode.op.drop);
        }
        if (block.label_finally >= 0) {
            try s.emitOpNoSource(opcode.op.undefined);
            try emitParserLabelJumpNoSource(
                s,
                opcode.op.gosub,
                .{ .id = @intCast(block.label_finally) },
            );
            try s.emitOpNoSource(opcode.op.drop);
        }
    }

    /// Walk ordered control environments up to `boundary`.  Scope exits are
    /// emitted before each target test, exactly like QuickJS `emit_break`;
    /// crossed iterator/drop/finally cleanup follows that environment's scope
    /// exits before the walker advances to its parent.
    fn emitControlBlocksUntil(
        s: *State,
        target: FinallyControlTarget,
        resolved: ResolvedFinallyControlTarget,
        block_cursor: *?*BlockEnv,
        boundary: ?*BlockEnv,
        scope_cursor: *i32,
        catch_marker_depth: *u32,
    ) Error!bool {
        while (block_cursor.*) |current| {
            if (current == boundary) return false;

            try s.closeScopes(scope_cursor.*, current.scope_level);
            scope_cursor.* = current.scope_level;
            if (controlBlockMatchesTarget(current, target)) {
                try emitCatchMarkerDropsFromDepth(s, catch_marker_depth, resolved.catch_marker_depth);
                // zjs's array-backed fixups do not all land on a QuickJS-style
                // physical break label before the target epilogue. Preserve
                // the target frame's established stack cleanup while the
                // BlockEnv walker owns only crossed-environment cleanup.
                switch (target.kind) {
                    .@"break" => try emitUnlabelledBreakCleanup(s, resolved.cleanup_drops),
                    .@"continue" => {},
                }
                try emitResolvedControlJump(s, target, resolved);
                return true;
            }

            try emitCatchMarkerDropsFromDepth(s, catch_marker_depth, current.catch_marker_depth);
            try emitCrossedControlBlockCleanup(s, current);
            block_cursor.* = current.prev;
        }
        if (boundary != null) return Error.UnexpectedToken;
        return false;
    }

    fn emitControlThroughFinally(s: *State, target: FinallyControlTarget) Error!void {
        const resolved = try resolveFinallyControlTarget(s, target);
        var block_cursor = s.top_break;
        var scope_cursor = s.scope_level;
        var catch_marker_depth = s.active_catch_marker_depth;

        var return_index = s.return_finally_frames.items.len;
        while (return_index != 0) {
            return_index -= 1;
            if (!try controlTargetCrossesFinallyFrame(s, target, return_index)) continue;
            const return_frame = s.return_finally_frames.items[return_index];
            if (try emitControlBlocksUntil(
                s,
                target,
                resolved,
                &block_cursor,
                return_frame.block_boundary,
                &scope_cursor,
                &catch_marker_depth,
            )) return;
            try s.closeScopes(scope_cursor, return_frame.scope_level);
            scope_cursor = return_frame.scope_level;
            try emitCatchMarkerDropsFromDepth(s, &catch_marker_depth, return_frame.catch_marker_depth);
            try s.emitOpNoSource(opcode.op.undefined);
            try emitParserLabelJumpNoSource(s, opcode.op.gosub, return_frame.finally_label);
            try s.emitOpNoSource(opcode.op.drop);
        }

        if (try emitControlBlocksUntil(
            s,
            target,
            resolved,
            &block_cursor,
            null,
            &scope_cursor,
            &catch_marker_depth,
        )) return;
        return Error.UnexpectedToken;
    }

    fn patchForwardJump(s: *State, operand_offset: usize) Error!void {
        var code = s.currentCode();
        if (operand_offset + 4 > code.len) return Error.UnexpectedToken;
        const target: u32 = @intCast(code.len);
        std.mem.writeInt(u32, code[operand_offset..][0..4], target, .little);
        // Patching to the current position represents a normal QuickJS label.
        // A control-flow merge cannot inherit an lvalue from one predecessor.
        s.invalidateLastOpcode();
    }

    fn patchJumpTarget(s: *State, operand_offset: usize, target: u32) Error!void {
        var code = s.currentCode();
        if (operand_offset + 4 > code.len) return Error.UnexpectedToken;
        std.mem.writeInt(u32, code[operand_offset..][0..4], target, .little);
    }

    fn patchAbsoluteTarget(s: *State, operand_offset: usize) Error!void {
        var code = s.currentCode();
        if (operand_offset + 4 > code.len) return Error.UnexpectedToken;
        std.mem.writeInt(u32, code[operand_offset..][0..4], @intCast(code.len), .little);
        s.invalidateLastOpcode();
    }

    fn relocateMovedJumpTargets(code: []u8, old_start: usize, new_start: usize) Error!void {
        if (new_start == old_start) return;
        const old_end = old_start + code.len;
        var pc: usize = 0;
        while (pc < code.len) {
            const op_id = code[pc];
            const size: usize = @intCast(opcode.sizeOf(op_id));
            if (size == 0 or pc + size > code.len) return;
            if (op_id == opcode.op.if_false or op_id == opcode.op.if_true or op_id == opcode.op.goto) {
                const target = std.mem.readInt(u32, code[pc + 1 ..][0..4], .little);
                if (target >= old_start and target <= old_end) {
                    const shifted = new_start + (@as(usize, @intCast(target)) - old_start);
                    std.mem.writeInt(u32, code[pc + 1 ..][0..4], @intCast(shifted), .little);
                }
            }
            pc += size;
        }
    }

    /// Mirror `js_parse_var` (`quickjs.c:27847`).
    ///
    /// Registers each identifier in `function_def.vars` with the correct
    /// `VarKind` / `is_lexical` / `is_const` flags so the full
    /// FunctionDef-based pipeline can assign local slots, emit TDZ checks,
    /// and synthesise closures. For `var`, the
    /// variable is attached at the function's var/arg scope (level 0)
    /// per QuickJS hoisting rules; for `let`/`const`, it attaches at the
    /// current lexical scope.
    fn needVarReference(s: *State, var_tok: tok.TokenKind) bool {
        if (var_tok != tok.TOK_VAR) return false;

        const fd = s.cur_func();
        if (!s.is_strict and !fd.is_strict_mode and !s.lex.is_module) return true;

        const is_global_var = s.cur_func_stack.len == 0 and
            (!s.is_eval or s.eval_global_var_bindings);
        return is_global_var and !s.lex.is_module;
    }

    fn parseVar(s: *State, var_tok: tok.TokenKind, export_decl: bool, parse_flags: ParseFlags) Error!void {
        const is_lexical = var_tok == tok.TOK_LET or var_tok == tok.TOK_CONST or s.in_namespace;
        const is_const = var_tok == tok.TOK_CONST;
        while (true) {
            const sloppy_keyword_var = (s.peekKind() == tok.TOK_YIELD or
                s.peekKind() == tok.TOK_STATIC or
                s.peekKind() == tok.TOK_LET or
                s.peekKind() == tok.TOK_AWAIT or
                isSloppyFutureReservedBindingToken(s)) and
                !(s.is_strict or s.cur_func().is_strict_mode) and
                !(s.peekKind() == tok.TOK_YIELD and s.in_generator) and
                !(s.peekKind() == tok.TOK_AWAIT and !canUseAwaitAsIdentifier(s));
            const binding_identifier = isIdentifierLikeToken(s);
            if (binding_identifier or sloppy_keyword_var) {
                // Simple identifier binding
                const atom_id = if (s.peekKind() == tok.TOK_IDENT) s.token.payload.ident.atom else tok.keywordAtom(s.peekKind());
                if (binding_identifier and s.peekKind() == tok.TOK_IDENT and
                    escapedIdentifierIsReservedWordForBinding(s, atom_id, s.token.payload.ident.has_escape))
                {
                    return Error.UnexpectedToken;
                }
                if (is_lexical and atomNameEquals(s, atom_id, "let")) return Error.UnexpectedToken;
                if ((s.is_strict or s.cur_func().is_strict_mode) and
                    (atomNameEquals(s, atom_id, "eval") or atomNameEquals(s, atom_id, "arguments")))
                {
                    return Error.UnexpectedToken;
                }
                s.last_var_decl_atom = atom_id;
                var local_lexical_idx: ?u16 = null;
                try s.advance();

                // Imported/module-declaration names are represented outside
                // vars/global_vars until module resolution.  Preserve that
                // QJS module-name collision at the token wrapper boundary;
                // all ordinary declaration collisions are owned by defineVar.
                if (is_lexical and s.top_level_lexical_as_module_ref and s.atProgramBodyScope() and hasKnownBinding(s, atom_id)) {
                    return Error.UnexpectedToken;
                }

                var hoisted_arguments_var_idx: ?i32 = null;
                if (!is_lexical and atomNameEquals(s, atom_id, "arguments") and
                    s.cur_func().func_type != .arrow and
                    s.cur_func().func_type != .class_static_init and
                    s.cur_func().has_parameter_expressions and
                    s.cur_func().arguments_var_idx >= 0 and
                    s.cur_func().arguments_arg_idx < 0)
                {
                    const body_arguments_idx: u16 = @intCast(s.cur_func().arguments_var_idx);
                    hoisted_arguments_var_idx = body_arguments_idx;
                    try ensureParameterArgumentsLocals(s.cur_func());
                }

                const defined = try s.defineVar(atom_id, if (is_lexical)
                    (if (is_const) .const_ else .let_)
                else
                    .var_);
                if (is_lexical) {
                    switch (defined) {
                        .local => |idx| {
                            local_lexical_idx = idx;
                            if (s.emit_lexical_tdz_at_decl) {
                                s.cur_func().vars[idx].tdz_emitted_at_decl = true;
                            }
                        },
                        .global => {},
                        .argument => unreachable,
                    }
                } else if (atomNameEquals(s, atom_id, "arguments")) {
                    switch (defined) {
                        .local => |idx| s.cur_func().arguments_var_idx = hoisted_arguments_var_idx orelse idx,
                        .argument => {},
                        .global => {},
                    }
                }
                if (export_decl) try addModuleExportName(s, atom_id, atom_id);

                if (local_lexical_idx) |idx| {
                    if (s.emit_lexical_tdz_at_decl) {
                        try s.emitOpU16(opcode.op.set_loc_uninitialized, idx);
                    }
                }

                // Check for initializer
                if (s.peekKind() == '=') {
                    const initializer_source = SourcePosition{
                        .line_num = s.token.line_num,
                        .col_num = s.token.col_num,
                    };
                    try s.advance();
                    s.last_anonymous_function_expr = false;
                    const saved_pending_name = s.pending_function_name;
                    const saved_pending_decl = s.pending_function_is_decl;
                    s.pending_function_name = atom_id;
                    s.pending_function_is_decl = false;
                    defer {
                        s.pending_function_name = saved_pending_name;
                        s.pending_function_is_decl = saved_pending_decl;
                    }
                    const capture_reference = needVarReference(s, var_tok);
                    var declaration_lvalue: ?LValue = null;
                    defer if (declaration_lvalue) |*lvalue| lvalue.deinit(s);
                    if (capture_reference) {
                        // qjs js_parse_var emits the ordinary getter and lets
                        // get_lvalue decide whether a with-scope reference is
                        // required. This keeps declaration assignment on the
                        // same descriptor and exact label target as ordinary
                        // assignment; no unpatched scope_make_ref is exposed
                        // to the resolver.
                        try s.emitScopeGetVar(atom_id);
                        declaration_lvalue = try getLValue(s, false);
                    }
                    try parseAssignExpr2(s, parse_flags);
                    if (s.last_anonymous_function_expr) {
                        try s.emitOpAtom(opcode.op.set_name, atom_id);
                        s.last_anonymous_function_expr = false;
                    }
                    // QJS pins this source event to the `=` token and then emits
                    // put_lvalue/the direct put without another source marker.
                    const emission_snapshot = s.takeEmissionSnapshot();
                    errdefer s.rollbackEmission(emission_snapshot);
                    _ = try s.emitSourcePosAndLoc(initializer_source.line_num, initializer_source.col_num);
                    if (declaration_lvalue) |*lvalue| {
                        try putLValue(s, lvalue, .no_keep);
                    } else if (is_lexical) {
                        try s.emitScopePutVarInitNoSource(atom_id);
                    } else {
                        try s.emitScopePutVarNoSource(atom_id);
                    }
                } else {
                    // const requires initializer
                    if (var_tok == tok.TOK_CONST) {
                        return Error.UnexpectedToken;
                    }
                    // `let x;` (no initializer) implicitly initialises to
                    // undefined. We emit `undefined; scope_put_var_init`
                    // so the slot is properly marked initialised — the
                    // pipeline lowers this to `put_loc_check_init` for
                    // lexical locals (clears TDZ flag) or `put_var_init`
                    // for global lexical vars.
                    if (var_tok == tok.TOK_LET) {
                        try s.emitOp(opcode.op.undefined);
                        try s.emitScopePutVarInit(atom_id);
                    }
                }
                if (s.namespace_export) {
                    if (s.current_namespace_atom) |ns_atom| {
                        try s.emitScopeGetVar(ns_atom);
                        try s.emitScopeGetVar(atom_id);
                        try s.emitOpAtom(opcode.op.put_field, atom_id);
                    }
                }
            } else if (s.peekKind() == '[' or s.peekKind() == '{') {
                try s.emitOp(opcode.op.undefined);
                const has_initializer = try parseDestructuringElement(
                    s,
                    .{ .binding = .{
                        .define_type = if (is_lexical)
                            (if (is_const) .const_ else .let_)
                        else
                            .var_,
                        .is_parameter = false,
                        .export_flag = export_decl,
                    } },
                    true,
                    true,
                    parse_flags,
                );
                if (!has_initializer) return Error.UnexpectedToken;
            } else {
                return Error.UnexpectedToken;
            }

            // Check for comma (multiple declarations)
            if (s.peekKind() != ',') break;
            try s.advance();
        }
    }

    fn parseWith(s: *State) Error!void {
        if (s.is_strict or s.cur_func().is_strict_mode) return Error.UnexpectedToken;
        try s.advance();
        try s.expectToken('(');
        try parseExpr(s);
        try s.expectToken(')');

        try s.pushScope();
        errdefer s.popScopeIdentity();
        const with_atom = atom_module.ids.with_object;
        const with_idx: u16 = switch (try s.defineVar(with_atom, .with_)) {
            .local => |idx| idx,
            else => unreachable,
        };
        try s.emitOp(opcode.op.to_object);
        try s.emitOpU16(opcode.op.put_loc, with_idx);

        const saved_with_atom = s.active_with_atom;
        s.active_with_atom = with_atom;
        defer {
            s.active_with_atom = saved_with_atom;
        }
        try s.setEvalReturnUndefined();
        try parseStatementOrDecl(s, DeclMask{});
        try s.popScope();
    }

    fn declareForInOfVarBinding(s: *State, atom_id: Atom) Error!void {
        const defined = try s.defineVar(atom_id, .var_);
        if (atomNameEquals(s, atom_id, "arguments") and s.cur_func().has_arguments_binding) {
            switch (defined) {
                .local => |idx| s.cur_func().arguments_var_idx = idx,
                .argument, .global => {},
            }
        }
    }

    /// Parse for-in or for-of loop
    /// Mirrors `js_parse_for_in_of` in quickjs.c:27991
    fn parseForInOf(s: *State, is_for_await: bool) Error!void {
        const block_scope_level = s.scope_level;
        const var_tok = s.peekKind();
        var target_atom: ?Atom = null;
        var target_is_lexical_decl = false;
        var target_is_pattern = false;
        var target_is_using_decl = false;
        var target_using_kind: DisposalHint = .sync;
        var target_var_initializer_atom: ?Atom = null;
        var iteration_using_value_loc: ?u16 = null;

        var pushed_for_scope = false;
        errdefer if (pushed_for_scope) s.popScopeIdentity();
        try s.pushScope();
        pushed_for_scope = true;

        // Initial entry skips the target. Each successful iterator step later
        // branches to this exact one-pass target block with its value on TOS.
        const expression_jump_offset = try emitForwardJump(s, opcode.op.goto);
        const assignment_pc: u32 = @intCast(s.currentCodeLen());

        const let_as_identifier = var_tok == tok.TOK_LET and
            !s.is_strict and !s.cur_func().is_strict_mode and
            s.peekNextKind() == tok.TOK_IN;
        const direct_using_kind = directUsingDeclarationKind(s);
        const parse_using_decl = if (direct_using_kind) |using_kind|
            using_kind == .async or !usingDeclarationBindingIsOf(s, using_kind)
        else
            false;

        if (parse_using_decl) {
            const using_kind = direct_using_kind.?;
            target_using_kind = using_kind;
            if (using_kind == .async) {
                if (!s.in_async and !(s.lex.is_module and s.cur_func_stack.len == 0)) {
                    return Error.AwaitOutsideAsyncFunction;
                }
                try s.advance();
            }
            try s.advance();
            if (!isIdentifierLikeToken(s) or identifierLikeHasInvalidEscapeForBinding(s)) {
                return Error.UnexpectedToken;
            }
            const atom_id = identifierLikeAtom(s);
            if (atomNameEquals(s, atom_id, "let")) return Error.UnexpectedToken;
            if ((s.is_strict or s.cur_func().is_strict_mode) and
                (atomNameEquals(s, atom_id, "eval") or atomNameEquals(s, atom_id, "arguments")))
            {
                return Error.UnexpectedToken;
            }
            _ = try s.defineVar(atom_id, .const_);
            target_atom = atom_id;
            target_is_lexical_decl = true;
            target_is_using_decl = true;
            try s.advance();
            if (s.peekKind() == @as(tok.TokenKind, @intCast('='))) return Error.UnexpectedToken;

            const value_loc = try appendAnonymousTempLocal(s);
            iteration_using_value_loc = value_loc;
            try s.emitOpU16(opcode.op.put_loc, value_loc);
        } else if ((var_tok == tok.TOK_VAR or var_tok == tok.TOK_LET or var_tok == tok.TOK_CONST) and
            !let_as_identifier)
        {
            try s.advance();
            const is_lexical = var_tok == tok.TOK_LET or var_tok == tok.TOK_CONST;
            const is_const = var_tok == tok.TOK_CONST;
            target_is_lexical_decl = is_lexical;

            if (s.peekKind() == @as(tok.TokenKind, @intCast('[')) or
                s.peekKind() == @as(tok.TokenKind, @intCast('{')))
            {
                target_is_pattern = true;
                _ = try parseDestructuringElement(
                    s,
                    .{ .binding = .{
                        .define_type = if (is_lexical)
                            (if (is_const) .const_ else .let_)
                        else
                            .var_,
                        .is_parameter = false,
                        .export_flag = false,
                    } },
                    true,
                    false,
                    ParseFlags.default,
                );
            } else {
                const sloppy_keyword_var = var_tok == tok.TOK_VAR and
                    (s.peekKind() == tok.TOK_YIELD or s.peekKind() == tok.TOK_STATIC or
                        s.peekKind() == tok.TOK_LET or s.peekKind() == tok.TOK_AWAIT or
                        isSloppyFutureReservedBindingToken(s)) and
                    !(s.is_strict or s.cur_func().is_strict_mode);
                if (!isIdentifierLikeToken(s) and !sloppy_keyword_var) return Error.UnexpectedToken;
                if (identifierLikeHasInvalidEscapeForBinding(s)) return Error.UnexpectedToken;
                const atom_id = identifierLikeAtom(s);
                if (is_lexical and atomNameEquals(s, atom_id, "let")) return Error.UnexpectedToken;
                if ((s.is_strict or s.cur_func().is_strict_mode) and
                    (atomNameEquals(s, atom_id, "eval") or atomNameEquals(s, atom_id, "arguments")))
                {
                    return Error.UnexpectedToken;
                }
                if (is_lexical) {
                    _ = try s.defineVar(atom_id, if (is_const) .const_ else .let_);
                } else {
                    try declareForInOfVarBinding(s, atom_id);
                    target_var_initializer_atom = atom_id;
                }
                target_atom = atom_id;
                try s.advance();
                if (is_lexical) {
                    try s.emitScopePutVarInit(atom_id);
                } else {
                    try s.emitScopePutVar(atom_id);
                }
            }
        } else {
            if (!is_for_await and var_tok == tok.TOK_IDENT and
                !s.token.payload.ident.has_escape and
                atomNameEquals(s, s.token.payload.ident.atom, "async") and
                s.peekNextIsOfToken())
            {
                return Error.UnexpectedToken;
            }

            const is_pattern = if (var_tok == @as(tok.TokenKind, @intCast('[')) or
                var_tok == @as(tok.TokenKind, @intCast('{')))
            blk: {
                const topology = try scanPatternTopology(s);
                break :blk topology.following == tok.TOK_IN or
                    topology.following == tok.TOK_IDENT or
                    topology.following == @as(tok.TokenKind, @intCast('='));
            } else false;

            if (is_pattern) {
                target_is_pattern = true;
                _ = try parseDestructuringElement(
                    s,
                    .assignment,
                    true,
                    true,
                    ParseFlags.default,
                );
            } else {
                try parseLhsExpr(s, .{ .in_accepted = false });
                var lvalue = try getLValue(s, false);
                defer lvalue.deinit(s);
                try putLValue(s, &lvalue, .no_keep_bottom);
            }
        }

        const body_jump_offset = try emitForwardJump(s, opcode.op.goto);
        try patchForwardJump(s, expression_jump_offset);

        // Annex-B legacy initializer: only sloppy non-lexical simple
        // for-in declarations accept it.
        var has_var_initializer = false;
        if (s.peekKind() == @as(tok.TokenKind, @intCast('='))) {
            if (target_var_initializer_atom == null or target_is_pattern or
                target_is_lexical_decl or s.is_strict or s.cur_func().is_strict_mode)
            {
                return Error.UnexpectedToken;
            }
            has_var_initializer = true;
            try s.advance();
            try parseAssignExpr2(s, ParseFlags{ .in_accepted = false });
            try s.emitScopePutVar(target_var_initializer_atom.?);
        }

        const in_of_tok = s.peekKind();
        const is_for_of = s.isOfToken();
        if (in_of_tok != tok.TOK_IN and !is_for_of) return Error.UnexpectedToken;
        if (target_is_using_decl and !is_for_of) return Error.UnexpectedToken;
        if (has_var_initializer and is_for_of) return Error.UnexpectedToken;
        if (is_for_await and !is_for_of) return Error.UnexpectedToken;
        try s.advance();

        if (is_for_of) {
            try parseAssignExpr(s);
        } else {
            try parseExpr(s);
        }
        try s.closeScopes(s.scope_level, block_scope_level);
        try s.expectToken(')');

        if (is_for_of) {
            try s.emitOp(if (is_for_await) opcode.op.for_await_of_start else opcode.op.for_of_start);
        } else {
            try s.emitOp(opcode.op.for_in_start);
        }

        const next_jump_off = try emitForwardJump(s, opcode.op.goto);
        try patchForwardJump(s, body_jump_offset);

        const loop_label = s.pending_label_atom;
        s.pending_label_atom = null;
        try pushBreakFrame(s);
        if (is_for_of) {
            setCurrentBreakCleanupDrops(s, if (is_for_await) shared_iterator_close_marker else direct_iterator_close_marker);
        } else {
            setCurrentBreakCleanupDrops(s, 1);
        }
        const label_frame = if (loop_label) |atom_id| try s.pushLabelFrame(atom_id, true) else null;

        var loop_block: BlockEnv = undefined;
        pushControlBlock(
            s,
            &loop_block,
            loop_label,
            true,
            true,
            false,
            block_scope_level,
            if (is_for_of) 3 else 1,
            is_for_of,
        );
        var loop_block_active = true;
        defer if (loop_block_active) popControlBlock(s, &loop_block);

        const iteration_using_frame_len = s.using_block_frames.items.len;
        const iteration_using_catch_marker_depth = s.active_catch_marker_depth;
        var iteration_using_frame_active = false;
        errdefer {
            if (iteration_using_frame_active) {
                restoreUsingBlockFramesAfterError(s, iteration_using_frame_len, iteration_using_catch_marker_depth);
            }
        }
        if (target_is_using_decl) {
            try s.using_block_frames.append(s.function.memory.allocator, .{});
            iteration_using_frame_active = true;
            const stack_loc = try armCurrentUsingBlockFrame(s);

            const atom_id = target_atom orelse return Error.UnexpectedToken;
            const value_loc = iteration_using_value_loc orelse return Error.UnexpectedToken;
            try s.emitOpU16(opcode.op.get_loc, value_loc);
            try s.emitOp(opcode.op.dup);
            try s.emitScopePutVarInit(atom_id);
            const resource_loc = try appendAnonymousTempLocal(s);
            try s.emitOpU16(opcode.op.put_loc, resource_loc);
            try emitUsingAddResource(s, target_using_kind, stack_loc, resource_loc);
            try noteUsingResourceHint(s, target_using_kind);
            try s.emitCloseLoc(resource_loc);
            try s.emitCloseLoc(value_loc);
        }

        try parseStatementOrDecl(s, DeclMask{});

        if (target_is_using_decl) {
            try finalizeCurrentUsingBlockFrame(s);
            iteration_using_frame_active = false;
        }

        try s.closeScopes(s.scope_level, block_scope_level);
        try patchContinueFrame(s);
        if (label_frame) |idx| try s.patchLabelContinues(idx);
        try patchForwardJump(s, next_jump_off);
        if (is_for_of) {
            if (is_for_await) {
                try s.emitOpNoSource(opcode.op.for_await_of_next);
                try s.emitOpNoSource(opcode.op.await);
                try s.emitOpNoSource(opcode.op.iterator_get_value_done);
            } else {
                try s.emitOpU8(opcode.op.for_of_next, 0);
            }
        } else {
            try s.emitOp(opcode.op.for_in_next);
        }

        if (is_for_await) {
            try emitBackwardJumpNoSource(s, opcode.op.if_false, assignment_pc);
        } else {
            try emitBackwardJump(s, opcode.op.if_false, assignment_pc);
        }

        if (is_for_await) {
            try s.emitOpNoSource(opcode.op.drop);
            try popBreakFrameAndPatch(s);
            try s.emitOpNoSource(opcode.op.iterator_close);
        } else if (is_for_of) {
            try s.emitOp(opcode.op.drop);
            try s.emitOp(opcode.op.iterator_close);
            try popBreakFrameAndPatch(s);
        } else {
            try s.emitOp(opcode.op.drop);
            try s.emitOp(opcode.op.drop);
            try popBreakFrameAndPatch(s);
        }
        if (label_frame) |idx| {
            try s.patchLabelBreaks(idx);
            s.popLabelFrame(idx);
        }

        popControlBlock(s, &loop_block);
        loop_block_active = false;
        if (pushed_for_scope) {
            try s.popScope();
            pushed_for_scope = false;
        }
    }
    fn arrayPatternContainsNestedBindingPattern(s: *State) Error!bool {
        const snapshot = takeParserSnapshot(s);
        defer restoreParserLexerSnapshot(s, snapshot);
        try s.expectToken('[');
        var depth: usize = 0;
        while (true) {
            const k = s.peekKind();
            if (k == tok.TOK_EOF) return Error.UnexpectedToken;
            if (depth == 0 and k == ']') return false;
            if (depth == 0 and (k == '[' or k == '{')) return true;
            if (depth == 0 and k == tok.TOK_ELLIPSIS) {
                try s.advance();
                const rest_target = s.peekKind();
                if (rest_target == '[' or rest_target == '{') return true;
                continue;
            }
            if (k == '[' or k == '{' or k == '(') depth += 1;
            if (k == ']' or k == '}' or k == ')') {
                if (depth == 0) return false;
                depth -= 1;
            }
            try s.advance();
        }
    }

    fn arrayPatternContainsNestedAssignmentPattern(s: *State) Error!bool {
        const snapshot = takeParserSnapshot(s);
        defer restoreParserLexerSnapshot(s, snapshot);
        try s.expectToken('[');
        while (s.peekKind() != ']' and s.peekKind() != tok.TOK_EOF) {
            if (s.peekKind() == ',') {
                try s.advance();
                continue;
            }
            var is_rest = false;
            if (s.peekKind() == tok.TOK_ELLIPSIS) {
                is_rest = true;
                try s.advance();
            }
            if (s.peekKind() == '[') return true;
            if (s.peekKind() == '{') {
                try skipBalancedPatternElement(s);
                if (s.peekKind() == '.' or s.peekKind() == '[') return false;
                return true;
            }
            if (s.peekKind() == tok.TOK_THIS) return true;
            if (is_rest) return false;
            while (s.peekKind() != ',' and s.peekKind() != ']' and s.peekKind() != tok.TOK_EOF) {
                if (s.peekKind() == '=') {
                    try skipInitializerInBindingPattern(s);
                    break;
                }
                try s.advance();
            }
            if (s.peekKind() == ',') try s.advance();
        }
        if (s.peekKind() == tok.TOK_EOF) return Error.UnexpectedToken;
        return false;
    }

    fn skipBalancedPatternElement(s: *State) Error!void {
        var depth: usize = 0;
        while (true) {
            const k = s.peekKind();
            if (k == tok.TOK_EOF) return Error.UnexpectedToken;
            if (k == '[' or k == '{' or k == '(') depth += 1;
            if (k == ']' or k == '}' or k == ')') {
                if (depth == 0) return;
                depth -= 1;
                try s.advance();
                if (depth == 0) return;
                continue;
            }
            try s.advance();
        }
    }

    fn skipInitializerInBindingPattern(s: *State) Error!void {
        var depth: usize = 0;
        while (true) {
            const k = s.peekKind();
            if (k == tok.TOK_EOF) return Error.UnexpectedToken;
            if (depth == 0 and (k == ',' or k == ']' or k == '}')) return;
            if (k == '[' or k == '{' or k == '(') depth += 1;
            if (k == ']' or k == '}' or k == ')') {
                if (depth == 0) return;
                depth -= 1;
            }
            try s.advance();
        }
    }

    /// Parse function declaration
    /// Mirrors `js_parse_function_decl` in quickjs.c:36388
    fn parseFunctionDecl(s: *State, func_kind: ParseFunctionKind, source_start: usize) Error!void {
        const saved_parameter_properties = s.current_parameter_properties;
        if (func_kind == .class_constructor or func_kind == .derived_class_constructor) {
            s.current_parameter_properties = std.ArrayList(Atom).empty;
        } else {
            s.current_parameter_properties = null;
        }
        defer {
            if (func_kind == .class_constructor or func_kind == .derived_class_constructor) {
                if (s.current_parameter_properties) |*props| {
                    props.deinit(s.function.memory.allocator);
                }
            }
            s.current_parameter_properties = saved_parameter_properties;
        }

        try s.advance();

        // Check for generator: function*
        const is_generator = s.peekKind() == '*';
        if (is_generator) {
            try s.advance();
        }

        // Parse function name (required for declarations)
        const has_decl_name = s.peekKind() == tok.TOK_IDENT or
            (s.peekKind() == tok.TOK_AWAIT and canUseAwaitAsIdentifier(s)) or
            (s.peekKind() == tok.TOK_YIELD and !(s.is_strict or s.cur_func().is_strict_mode));
        if (!has_decl_name) {
            return Error.UnexpectedToken;
        }
        const name_atom = identifierLikeAtom(s);
        s.last_declared_atom = name_atom;
        if (s.lex.is_module and s.atProgramBodyScope() and hasKnownBinding(s, name_atom)) {
            return Error.UnexpectedToken;
        }
        try s.advance();

        // Set generator flag for yield parsing
        const was_generator = s.in_generator;
        s.in_generator = is_generator;
        defer s.in_generator = was_generator;

        // Set async flag for await parsing
        const was_async = s.in_async;
        const is_async = func_kind == .async or func_kind == .async_generator;
        s.in_async = is_async;
        defer s.in_async = was_async;

        // Determine actual function kind based on async/generator combination
        const actual_kind: ParseFunctionKind = if (is_generator)
            if (func_kind == .async) .async_generator else .generator
        else
            func_kind;

        const saved_pending_name = s.pending_function_name;
        const saved_pending_decl = s.pending_function_is_decl;
        s.pending_function_name = name_atom;
        s.pending_function_is_decl = true;
        defer {
            s.pending_function_name = saved_pending_name;
            s.pending_function_is_decl = saved_pending_decl;
        }
        try parseFunctionParamsAndBody(s, actual_kind, source_start);
    }

    /// Parse function expression
    /// Mirrors `js_parse_function_expr` in quickjs.c
    fn parseFunctionExpr(s: *State, func_kind: ParseFunctionKind, source_start: usize) Error!void {
        try s.advance();

        // Check for generator: function*
        const is_generator = s.peekKind() == '*';
        if (is_generator) {
            try s.advance();
        }

        // Parse function name (optional for expressions)
        const saved_pending_name = s.pending_function_name;
        s.pending_function_name = null;
        const has_name = s.peekKind() == tok.TOK_IDENT or
            (s.peekKind() == tok.TOK_AWAIT and !s.in_async and !s.lex.is_module) or
            (s.peekKind() == tok.TOK_YIELD and !(s.is_strict or s.cur_func().is_strict_mode));
        if (has_name) {
            const name_atom = identifierLikeAtom(s);
            if (is_generator and atomNameEquals(s, name_atom, "yield")) return Error.UnexpectedToken;
            if (func_kind == .async and is_generator and atomNameEquals(s, name_atom, "await")) return Error.UnexpectedToken;
            if ((s.is_strict or s.cur_func().is_strict_mode) and
                (atomNameEquals(s, name_atom, "eval") or atomNameEquals(s, name_atom, "arguments")))
            {
                return Error.UnexpectedToken;
            }
            s.pending_function_name = name_atom;
            try s.advance();
        }

        // Set generator flag for yield parsing
        const was_generator = s.in_generator;
        s.in_generator = is_generator;
        defer s.in_generator = was_generator;

        // Set async flag for await parsing
        const was_async = s.in_async;
        const is_async = func_kind == .async or func_kind == .async_generator;
        s.in_async = is_async;
        defer s.in_async = was_async;

        // Determine actual function kind based on async/generator combination
        const actual_kind: ParseFunctionKind = if (is_generator)
            if (func_kind == .async) .async_generator else .generator
        else
            func_kind;

        const saved_pending_decl = s.pending_function_is_decl;
        s.pending_function_is_decl = false;
        defer {
            s.pending_function_name = saved_pending_name;
            s.pending_function_is_decl = saved_pending_decl;
        }
        try parseFunctionParamsAndBody(s, actual_kind, source_start);
    }

    /// Anonymous `export default function` is a declaration whose external
    /// carrier is `_default_`, while its inferred function name is `default`.
    /// QuickJS routes this through js_parse_function_decl2 as a statement;
    /// keep it on the same declaration path instead of adapting an expression
    /// child after parsing.
    fn parseAnonymousDefaultFunctionDecl(
        s: *State,
        func_kind: ParseFunctionKind,
        source_start: usize,
    ) Error!void {
        try s.advance(); // `function`
        const is_generator = s.peekKind() == '*';
        if (is_generator) try s.advance();

        const was_generator = s.in_generator;
        s.in_generator = is_generator;
        defer s.in_generator = was_generator;

        const was_async = s.in_async;
        s.in_async = func_kind == .async or func_kind == .async_generator;
        defer s.in_async = was_async;

        const actual_kind: ParseFunctionKind = if (is_generator)
            if (func_kind == .async) .async_generator else .generator
        else
            func_kind;
        const saved_pending_name = s.pending_function_name;
        const saved_pending_decl = s.pending_function_is_decl;
        const saved_export_default = s.pending_function_export_default;
        s.pending_function_name = atom_default;
        s.pending_function_is_decl = true;
        s.pending_function_export_default = true;
        defer {
            s.pending_function_name = saved_pending_name;
            s.pending_function_is_decl = saved_pending_decl;
            s.pending_function_export_default = saved_export_default;
        }
        try parseFunctionParamsAndBody(s, actual_kind, source_start);
    }

    /// Parse function parameters and body
    /// Shared by function declarations, expressions, and methods
    fn deinitParserList(comptime T: type, s: *State, list: *std.ArrayList(T)) void {
        list.deinit(s.function.memory.allocator);
    }

    const FunctionParameters = struct {
        simple_names: std.ArrayList(Atom) = .empty,
        has_duplicate_simple: bool = false,
        has_simple_list: bool = true,

        fn deinit(self: *FunctionParameters, s: *State) void {
            deinitParserList(Atom, s, &self.simple_names);
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

    fn parseFunctionParameters(
        s: *State,
        func_kind: ParseFunctionKind,
        capture_child: bool,
    ) Error!FunctionParameters {
        var parameters: FunctionParameters = .{};
        errdefer parameters.deinit(s);

        var param_count: u32 = 0;
        var first_default_param: ?u32 = null;
        var has_rest_parameter = false;
        const is_class_static_block = func_kind == .class_static_block;

        if (!is_class_static_block) {
            const saved_reject_await = s.reject_await_in_parameter_initializer;
            s.reject_await_in_parameter_initializer = func_kind == .async or func_kind == .async_generator;
            defer s.reject_await_in_parameter_initializer = saved_reject_await;

            try s.expectToken('(');
            const parameter_scan = try scanParameterList(s);
            if (capture_child) s.cur_func().has_parameter_expressions = parameter_scan.has_parameter_expressions;
            const parameter_scope = if (capture_child and parameter_scan.has_parameter_expressions)
                try enterParameterExpressionScope(s)
            else
                null;

            while (s.peekKind() != ')' and s.peekKind() != tok.TOK_EOF) {
                var has_modifier = false;
                if (s.lex.is_typescript and (func_kind == .class_constructor or func_kind == .derived_class_constructor)) {
                    while (s.isParameterModifier()) {
                        has_modifier = true;
                        try s.advance();
                    }
                }
                if (isIdentifierLikeToken(s)) {
                    const param_atom = identifierLikeAtom(s);
                    if (has_modifier) {
                        if (s.current_parameter_properties) |*props| {
                            try props.append(s.function.memory.allocator, param_atom);
                        }
                    }
                    const arg_index = param_count;
                    const strict_params = s.is_strict or s.cur_func().is_strict_mode;
                    if (func_kind == .set and strict_params and
                        (atomNameEquals(s, param_atom, "eval") or atomNameEquals(s, param_atom, "arguments")))
                    {
                        return Error.UnexpectedToken;
                    }
                    for (parameters.simple_names.items) |existing| {
                        if (existing == param_atom) {
                            parameters.has_duplicate_simple = true;
                            if (strict_params) return Error.UnexpectedToken;
                            break;
                        }
                    }
                    for (s.cur_func().vars) |existing| {
                        if (existing.var_name == param_atom) return Error.UnexpectedToken;
                    }
                    try parameters.simple_names.append(s.function.memory.allocator, param_atom);
                    if (capture_child) {
                        if (parameter_scope != null) {
                            try appendParameterExpressionBinding(s, param_atom);
                        }
                        _ = try s.cur_func().appendArg(.{
                            .var_name = param_atom,
                            .scope_level = 0,
                            .is_lexical = false,
                            .is_const = false,
                            .var_kind = .normal,
                        });
                    }
                    try s.advance();
                    param_count += 1;

                    if (s.peekKind() == '=') {
                        parameters.has_simple_list = false;
                        if (first_default_param == null) first_default_param = arg_index;
                        try s.advance();
                        if (capture_child) {
                            try s.emitOpU16(opcode.op.get_arg, @intCast(arg_index));
                            try s.emitOp(opcode.op.is_undefined);
                            const keep_value = try emitForwardJump(s, opcode.op.if_false);
                            const saved_in_parameter_initializer = s.in_parameter_initializer;
                            s.in_parameter_initializer = true;
                            defer s.in_parameter_initializer = saved_in_parameter_initializer;
                            try parseNamedBindingDefaultInitializer(s, param_atom);
                            try s.emitOpU16(opcode.op.put_arg, @intCast(arg_index));
                            try patchForwardJump(s, keep_value);
                        } else {
                            const saved_in_parameter_initializer = s.in_parameter_initializer;
                            s.in_parameter_initializer = true;
                            defer s.in_parameter_initializer = saved_in_parameter_initializer;
                            try parseNamedBindingDefaultInitializer(s, param_atom);
                            try s.emitOp(opcode.op.drop);
                        }
                    }
                    if (parameter_scope != null) {
                        try initializeParameterScopeBinding(s, param_atom, arg_index);
                    }
                } else if (s.peekKind() == '{') {
                    parameters.has_simple_list = false;
                    const arg_index = param_count;
                    if (capture_child) try ensureDestructuringArgSlot(s, arg_index);
                    const has_initializer = try parseParameterDestructuring(
                        s,
                        if (capture_child) arg_index else null,
                        parameter_scope != null,
                        false,
                        true,
                    );
                    if (has_initializer and first_default_param == null) first_default_param = arg_index;
                    param_count += 1;
                } else if (s.peekKind() == '[') {
                    parameters.has_simple_list = false;
                    const arg_index = param_count;
                    if (capture_child) try ensureDestructuringArgSlot(s, arg_index);
                    const has_initializer = try parseParameterDestructuring(
                        s,
                        if (capture_child) arg_index else null,
                        parameter_scope != null,
                        false,
                        true,
                    );
                    if (has_initializer and first_default_param == null) first_default_param = arg_index;
                    param_count += 1;
                } else if (s.peekKind() == tok.TOK_ELLIPSIS) {
                    s.features.insert(.spread_rest);
                    parameters.has_simple_list = false;
                    const arg_index = param_count;
                    try s.advance();
                    has_rest_parameter = true;
                    if (isIdentifierLikeToken(s)) {
                        if (identifierLikeHasInvalidEscapeForBinding(s)) return Error.UnexpectedToken;
                        const rest_atom = identifierLikeAtom(s);
                        for (parameters.simple_names.items) |existing| {
                            if (existing == rest_atom) return Error.UnexpectedToken;
                        }
                        for (s.cur_func().vars) |existing| {
                            if (existing.var_name == rest_atom) return Error.UnexpectedToken;
                        }
                        try parameters.simple_names.append(s.function.memory.allocator, rest_atom);
                        if (capture_child) {
                            if (parameter_scope != null) {
                                try appendParameterExpressionBinding(s, rest_atom);
                            }
                            const idx = try s.cur_func().appendArg(.{
                                .var_name = rest_atom,
                                .scope_level = 0,
                                .is_lexical = false,
                                .is_const = false,
                                .var_kind = .normal,
                            });
                            if (idx != @as(i32, @intCast(arg_index))) return Error.UnexpectedToken;
                            try s.emitOpU16(opcode.op.rest, @intCast(arg_index));
                            try s.emitOpU16(opcode.op.put_arg, @intCast(arg_index));
                            s.cur_func().defined_arg_count = @intCast(arg_index);
                        }
                        if (parameter_scope != null) {
                            try initializeParameterScopeBinding(s, rest_atom, arg_index);
                        }
                        try s.advance();
                    } else if (s.peekKind() == '[') {
                        if (capture_child) {
                            try ensureDestructuringArgSlot(s, arg_index);
                            try s.emitOpU16(opcode.op.rest, @intCast(arg_index));
                            s.cur_func().defined_arg_count = @intCast(arg_index);
                        } else {
                            try s.emitOp(opcode.op.undefined);
                        }
                        if (try parseParameterDestructuring(
                            s,
                            if (capture_child) arg_index else null,
                            parameter_scope != null,
                            true,
                            false,
                        )) return Error.UnexpectedToken;
                    } else if (s.peekKind() == '{') {
                        if (capture_child) {
                            try ensureDestructuringArgSlot(s, arg_index);
                            try s.emitOpU16(opcode.op.rest, @intCast(arg_index));
                            s.cur_func().defined_arg_count = @intCast(arg_index);
                        } else {
                            try s.emitOp(opcode.op.undefined);
                        }
                        if (try parseParameterDestructuring(
                            s,
                            if (capture_child) arg_index else null,
                            parameter_scope != null,
                            true,
                            false,
                        )) return Error.UnexpectedToken;
                    } else {
                        return Error.UnexpectedToken;
                    }
                    break;
                } else {
                    return Error.UnexpectedToken;
                }

                if (s.peekKind() == ',') {
                    try s.advance();
                } else if (s.peekKind() != ')') {
                    return Error.UnexpectedToken;
                }
            }

            try s.expectToken(')');
            if (parameter_scope) |scope| try leaveParameterExpressionScope(s, scope);
        }

        if (func_kind == .get and (param_count != 0 or has_rest_parameter)) return Error.UnexpectedToken;
        if (func_kind == .set and (param_count != 1 or has_rest_parameter)) return Error.UnexpectedToken;
        if (capture_child) s.cur_func().has_simple_parameter_list = parameters.has_simple_list;
        if (capture_child) {
            if (first_default_param) |defined_count| {
                s.cur_func().defined_arg_count = @intCast(defined_count);
            }
        }
        return parameters;
    }

    fn parseFunctionParamsAndBody(s: *State, func_kind: ParseFunctionKind, source_start: ?usize) Error!void {
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
        s.last_function_child_index = null;
        const parent_fd = s.cur_func();
        const capture_child = s.cur_func_stack.len > 0 or s.top_level_functions_as_children;
        var function_decl_plan: FunctionDeclPlan = .{};
        // Consume the method-context marker set by emitObjectMethodFunction /
        // parseClassElementFunction so nested functions parsed inside this
        // function's parameters or body do not inherit it. Mirrors qjs
        // fd->func_type == JS_PARSE_FUNC_METHOD (quickjs.c:36443-36448).
        const is_method_params = s.parsing_method_params;
        s.parsing_method_params = false;
        const saved_emit_to_function_def = s.emit_to_function_def;
        const saved_last_opcode_source_offset = s.last_opcode_source_offset;
        const saved_scope_level = s.scope_level;
        const saved_is_eval = s.is_eval;
        const saved_eval_ret_idx = s.eval_ret_idx;
        const saved_return_depth = s.return_depth;
        const saved_is_strict = s.is_strict;
        const saved_lex_is_strict = s.lex.is_strict_mode;
        const saved_allow_super = s.allow_super;
        const saved_allow_super_call = s.allow_super_call;
        const saved_new_target_allowed = s.new_target_allowed;
        const saved_function_expr_name_binding = s.function_expr_name_binding;
        const saved_in_constructor = s.in_constructor;
        s.in_constructor = func_kind == .class_constructor or func_kind == .derived_class_constructor;
        defer s.in_constructor = saved_in_constructor;
        const saved_is_outer_constructor_block = s.is_outer_constructor_block;
        s.is_outer_constructor_block = func_kind == .class_constructor or func_kind == .derived_class_constructor;
        defer s.is_outer_constructor_block = saved_is_outer_constructor_block;

        var child_pushed = false;
        errdefer if (child_pushed) {
            s.discardCurrentFunction();
            s.emit_to_function_def = saved_emit_to_function_def;
            s.last_opcode_source_offset = saved_last_opcode_source_offset;
            s.scope_level = saved_scope_level;
            s.is_eval = saved_is_eval;
            s.eval_ret_idx = saved_eval_ret_idx;
            s.return_depth = saved_return_depth;
            s.is_strict = saved_is_strict;
            s.lex.is_strict_mode = saved_lex_is_strict;
            s.new_target_allowed = saved_new_target_allowed;
        };
        const saved_return_finally = if (capture_child) enterReturnFinallyFunctionBoundary(s) else null;
        defer if (saved_return_finally) |*saved| leaveReturnFinallyFunctionBoundary(s, saved);
        s.function_expr_name_binding = switch (func_kind) {
            .normal, .async, .generator, .async_generator => if (!s.pending_function_is_decl) s.pending_function_name else null,
            else => null,
        };
        defer s.function_expr_name_binding = saved_function_expr_name_binding;
        // QuickJS copies the enclosing super capability into arrows and class
        // static blocks. A static block is a lexical child of the method-like
        // static initializer: it has no home object of its own, but may read
        // the initializer's home object for `super` property access.
        const function_has_home_object = is_method_params or switch (func_kind) {
            .method, .get, .set, .class_constructor, .derived_class_constructor => true,
            else => false,
        };
        const function_allows_super = if (func_kind == .arrow or func_kind == .class_static_block)
            saved_allow_super
        else
            function_has_home_object;
        const function_allows_super_call = if (func_kind == .arrow)
            saved_allow_super_call
        else
            func_kind == .derived_class_constructor;
        s.allow_super = function_allows_super;
        s.allow_super_call = function_allows_super_call;
        defer s.allow_super = saved_allow_super;
        defer s.allow_super_call = saved_allow_super_call;
        const function_new_target_allowed = if (func_kind == .arrow) saved_new_target_allowed else true;
        s.new_target_allowed = function_new_target_allowed;
        defer s.new_target_allowed = saved_new_target_allowed;
        const saved_static_block = s.in_class_static_block;
        s.in_class_static_block = func_kind == .class_static_block;
        defer s.in_class_static_block = saved_static_block;
        const parent_code_len_before_child = s.currentCodeLen();

        if (capture_child) {
            const child_fd = try s.function.memory.create(function_def_mod.FunctionDef);
            var child_owned_before_push = true;
            errdefer if (child_owned_before_push) s.discardFunctionDef(child_fd);
            const child_name = s.pending_function_name orelse if (s.pending_function_is_decl) s.function.name else atom_module.ids.empty_string;
            child_fd.* = function_def_mod.FunctionDef.init(s.function.memory, s.function.atoms, child_name);
            child_fd.atoms.replace(&child_fd.filename, parent_fd.filename);
            child_fd.atoms.replace(&child_fd.script_or_module, parent_fd.script_or_module);
            child_fd.line_num = @intCast(s.token.line_num);
            child_fd.col_num = @intCast(s.token.col_num);
            child_fd.parent = parent_fd;
            child_fd.parent_scope_level = parent_fd.scope_level;
            child_fd.parent_parameter_environment_only = s.in_parameter_initializer;
            child_fd.is_strict_mode = parent_fd.is_strict_mode or s.is_strict or s.lex.is_strict_mode;
            child_fd.use_short_opcodes = parent_fd.use_short_opcodes;
            child_fd.func_type = switch (func_kind) {
                .normal, .async, .generator, .async_generator => if (is_method_params)
                    .method
                else if (s.pending_function_is_decl)
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
            child_fd.func_kind = switch (func_kind) {
                .async => .async,
                .generator => .generator,
                .async_generator => .async_generator,
                else => .normal,
            };
            child_fd.new_target_allowed = function_new_target_allowed;
            child_fd.super_allowed = function_allows_super;
            child_fd.super_call_allowed = function_allows_super_call;
            child_fd.has_arguments_binding = func_kind != .arrow and func_kind != .class_static_block;
            child_fd.has_this_binding = func_kind != .arrow and func_kind != .class_static_block;
            child_fd.arguments_allowed = if (func_kind == .arrow)
                parent_fd.arguments_allowed
            else
                func_kind != .class_static_block;
            child_fd.has_home_object = function_has_home_object;
            child_fd.has_prototype = switch (func_kind) {
                .arrow, .async, .method, .get, .set, .class_static_block => false,
                else => true,
            };
            _ = child_fd.appendScope(-1) catch return error.OutOfMemory;
            if (func_kind == .class_constructor or func_kind == .derived_class_constructor) {
                child_fd.is_derived_class_constructor = func_kind == .derived_class_constructor;
            }
            if (!s.pending_function_is_decl) {
                if (s.pending_function_name != null) {
                    // qjs js_parse_function_decl2 records only is_func_expr +
                    // func_name here; the self-binding var is added lazily by
                    // resolve_scope_var / add_eval_variables when a reference
                    // actually falls through (add_func_var quickjs.c:24208,
                    // call sites 32977 / 33153 / 33650 / 33698). child_fd
                    // carries the name already: FunctionDef.init received
                    // `child_name == s.pending_function_name` above.
                    child_fd.is_named_func_expr = true;
                }
            }
            if (s.pending_function_is_decl) {
                const name = if (s.pending_function_export_default)
                    atom_star_default
                else
                    s.pending_function_name orelse s.function.name;
                function_decl_plan.active = true;
                function_decl_plan.binding_name = name;
                if (s.cur_func_stack.len == 0 and
                    s.top_level_functions_as_children and
                    parent_fd.scope_level == parent_fd.body_scope and
                    (!s.is_eval or !parent_fd.is_strict_mode) and
                    !s.annex_b_if_function_decl_clause and
                    s.findFunctionScopeVar(name) == null)
                {
                    // The child must exist before the declaration carrier gets
                    // its cpool index.  All script/module/eval top-level cases
                    // append their GlobalVar in the post-child half below.
                    function_decl_plan.global_declaration = true;
                } else {
                    _ = parent_code_len_before_child;
                    // Early-error: check for duplicate lexical declaration in the
                    // same scope.  Mirrors QuickJS `define_var` JS_VAR_DEF_FUNCTION_DECL
                    // path (`quickjs.c:23716-23732`): duplicate LexicallyDeclaredNames
                    // in a Block are a SyntaxError, except Annex B.3.3.4 allows
                    // redefining a function declaration with another function declaration
                    // in non-strict mode.
                    if (s.visibleLexicalScopeVar(name)) |existing_idx| {
                        const existing = parent_fd.vars[existing_idx];
                        const same_scope = existing.scope_level == parent_fd.scope_level;
                        const annex_b_func_redef = same_scope and
                            !parent_fd.is_strict_mode and
                            func_kind == .normal and
                            existing.var_kind == .function_decl;
                        if (same_scope and !annex_b_func_redef) {
                            return Error.SyntaxError;
                        }
                    }

                    // qjs find_lexical_decl (quickjs.c:24099): in global script/eval
                    // code a top-level let/const lives in global_vars
                    // (JS_CLOSURE_GLOBAL_DECL), not in fd->vars; find_lexical_global_var
                    // consults it so Annex B B.3.3 block functions skip hoisting when a
                    // top-level lexical collides. Required since
                    // top_level_lexical_as_global_ref moves these out of scope vars.
                    const visible_lexical_blocking_annex_b =
                        s.visibleLexicalScopeVar(name) != null or s.findLexicalGlobalVar(name);
                    const function_body_scope = parent_fd.body_scope;
                    const is_block_level_function_decl = parent_fd.scope_level > function_body_scope;
                    // QuickJS records a block function's cpool index on its
                    // lexical VarDef and instantiates it while lowering that
                    // block's OP_enter_scope.  Annex-B single-statement `if`
                    // functions are conditional source-position assignments,
                    // not scope-entry declarations.
                    function_decl_plan.scope_entry_init =
                        is_block_level_function_decl and !s.annex_b_if_function_decl_clause;
                    const arguments_blocks_annex_b = atomNameEquals(s, name, "arguments") and
                        (!s.is_eval or
                            (!s.eval_in_parameter_initializer and State.findClosureVarIndex(parent_fd, name) != null));
                    const name_blocks_annex_b_parameter_rule =
                        parent_fd.findArg(name) >= 0 or
                        arguments_blocks_annex_b or
                        evalAnnexBBlockedFunctionName(s, name);
                    const annex_b_if_function_var = s.annex_b_if_function_decl_clause and
                        !parent_fd.is_strict_mode and
                        func_kind == .normal and
                        !visible_lexical_blocking_annex_b and
                        !name_blocks_annex_b_parameter_rule and
                        !s.in_namespace;
                    const annex_b_block_function_var = is_block_level_function_decl and
                        !parent_fd.is_strict_mode and
                        func_kind == .normal and
                        !visible_lexical_blocking_annex_b and
                        !name_blocks_annex_b_parameter_rule and
                        !s.in_namespace;
                    // The implicit arguments-object local is a parameter-name
                    // blocker for Annex B, not an earlier block-function
                    // declaration. Treating it as the latter forces the lexical
                    // function initializer to its source position, so a call
                    // before `function arguments(){}` incorrectly observes the
                    // arguments object. Keep the block function in the normal
                    // hoisted lexical-init path; the outer implicit binding stays
                    // in its separate `arguments_var_idx` slot.
                    const implicit_arguments_binding =
                        atomNameEquals(s, name, "arguments") and parent_fd.arguments_var_idx >= 0;
                    const duplicate_hoisted_block_func =
                        is_block_level_function_decl and
                        s.scopeHasVar(0, name) and
                        !implicit_arguments_binding;
                    const function_decl_idx: i32 = if (annex_b_if_function_var) blk: {
                        const is_top_level_annex_b_if_scope =
                            parent_fd.scope_level == parent_fd.body_scope or
                            (parent_fd.scope_level > parent_fd.body_scope and
                                @as(usize, @intCast(parent_fd.scope_level)) < parent_fd.scopes.len and
                                parent_fd.scopes[@intCast(parent_fd.scope_level)].parent == parent_fd.body_scope);
                        const emit_global_annex_b_if = s.top_level_functions_as_children and
                            s.cur_func_stack.len == 0 and
                            ((is_top_level_annex_b_if_scope and !s.is_eval) or s.eval_global_var_bindings);
                        if (emit_global_annex_b_if) {
                            function_decl_plan.outer_carrier = .global;
                            function_decl_plan.emit_inline = true;
                            function_decl_plan.emit_global_inline = true;
                            break :blk switch (try s.defineVar(name, .function_decl)) {
                                .local => |idx| idx,
                                else => unreachable,
                            };
                        }
                        if (s.is_eval and !s.eval_global_var_bindings and s.cur_func_stack.len == 0) {
                            function_decl_plan.outer_carrier = .eval_var_object;
                            function_decl_plan.emit_inline = true;
                            function_decl_plan.emit_eval_var_inline = true;
                            break :blk switch (try s.defineVar(name, .function_decl)) {
                                .local => |idx| idx,
                                else => unreachable,
                            };
                        }
                        function_decl_plan.outer_carrier = .local;
                        function_decl_plan.emit_inline = true;
                        break :blk switch (try s.defineVar(name, .function_decl)) {
                            .local => |idx| idx,
                            else => unreachable,
                        };
                    } else if (s.annex_b_if_function_decl_clause and func_kind == .normal) blk: {
                        function_decl_plan.emit_inline = true;
                        function_decl_plan.skip_init = true;
                        break :blk 0;
                    } else if (annex_b_block_function_var) blk: {
                        const emit_global_annex_b_block = s.cur_func_stack.len == 0 and
                            (s.eval_global_var_bindings or (!s.is_eval and s.top_level_functions_as_children));
                        if (emit_global_annex_b_block) {
                            function_decl_plan.outer_carrier = .global;
                            function_decl_plan.emit_inline = true;
                            function_decl_plan.emit_global_inline = true;
                            break :blk switch (try s.defineVar(name, .function_decl)) {
                                .local => |idx| idx,
                                else => unreachable,
                            };
                        } else if (s.is_eval and !s.eval_global_var_bindings and s.cur_func_stack.len == 0) {
                            function_decl_plan.outer_carrier = .eval_var_object;
                            function_decl_plan.emit_inline = true;
                            function_decl_plan.emit_eval_var_inline = true;
                            break :blk switch (try s.defineVar(name, .function_decl)) {
                                .local => |idx| idx,
                                else => unreachable,
                            };
                        } else {
                            function_decl_plan.outer_carrier = .local;
                            function_decl_plan.emit_inline = true;
                            break :blk switch (try s.defineVar(name, .function_decl)) {
                                .local => |idx| idx,
                                else => unreachable,
                            };
                        }
                    } else if ((parent_fd.is_strict_mode and is_block_level_function_decl) or
                        (is_block_level_function_decl and s.is_eval) or
                        (is_block_level_function_decl and visible_lexical_blocking_annex_b) or
                        (is_block_level_function_decl and name_blocks_annex_b_parameter_rule) or
                        (is_block_level_function_decl and s.in_switch_case_block_scope) or
                        duplicate_hoisted_block_func)
                    blk: {
                        function_decl_plan.force_local_init = is_block_level_function_decl and name_blocks_annex_b_parameter_rule;
                        if (function_decl_plan.force_local_init) {
                            if (findCurrentScopeVar(s, name)) |idx| {
                                parent_fd.vars[idx].tdz_emitted_at_decl = true;
                                break :blk idx;
                            }
                        }
                        const idx: u16 = switch (try s.defineVar(
                            name,
                            if (func_kind == .normal) .function_decl else .new_function_decl,
                        )) {
                            .local => |local_idx| local_idx,
                            else => unreachable,
                        };
                        if (function_decl_plan.force_local_init) parent_fd.vars[idx].tdz_emitted_at_decl = true;
                        break :blk idx;
                    } else blk: {
                        if (!is_block_level_function_decl) {
                            function_decl_plan.body_declaration = true;
                            break :blk -1;
                        }
                        // Non-Annex-B block declarations are lexical.  Async
                        // and generator declarations carry NEW_FUNCTION_DECL;
                        // ordinary functions carry FUNCTION_DECL.
                        break :blk switch (try s.defineVar(
                            name,
                            if (func_kind == .normal) .function_decl else .new_function_decl,
                        )) {
                            .local => |idx| idx,
                            else => unreachable,
                        };
                    };
                    function_decl_plan.lexical_var_idx = function_decl_idx;
                    function_decl_plan.emit_inline = function_decl_plan.emit_inline or
                        duplicate_hoisted_block_func or
                        (is_block_level_function_decl and
                            !function_decl_plan.force_local_init and
                            !function_decl_plan.emit_global_inline and
                            parent_fd.vars[@intCast(function_decl_idx)].is_lexical);
                }
            }
            try s.pushFunction(child_fd);
            child_owned_before_push = false;
            child_pushed = true;
            s.emit_to_function_def = true;
            s.last_opcode_source_offset = null;
            s.scope_level = 0;
            s.is_eval = false;
            s.eval_ret_idx = -1;
            s.return_depth = if (func_kind == .class_static_block) 0 else 1;
        }

        // A nested function closes over the outer parameter environment, but
        // its own grammar is a fresh function boundary.  Record the parent
        // relationship above, then stop treating the nested function body as
        // part of the outer FormalParameters production.
        const saved_outer_parameter_initializer = s.in_parameter_initializer;
        s.in_parameter_initializer = false;
        defer s.in_parameter_initializer = saved_outer_parameter_initializer;

        const function_pending_name = s.pending_function_name;
        const function_pending_decl = s.pending_function_is_decl;
        const function_pending_export_default = s.pending_function_export_default;
        s.pending_function_name = null;
        s.pending_function_is_decl = false;
        s.pending_function_export_default = false;

        // qjs emits OP_check_ctor at the class-constructor function entry,
        // before parameter initializers and independently of whether the body
        // contains super(). Keeping it out of the indexed super lowering is
        // required now that all super calls use phase-1 scope operands.
        if (capture_child and (func_kind == .class_constructor or func_kind == .derived_class_constructor)) {
            try s.emitOp(opcode.op.check_ctor);
        }
        if (capture_child and func_kind == .class_constructor) {
            try emitClassFieldInitCall(s);
        }

        var parameters = try parseFunctionParameters(s, func_kind, capture_child);
        defer parameters.deinit(s);
        if (capture_child and (func_kind == .generator or func_kind == .async_generator)) {
            try s.emitOp(opcode.op.initial_yield);
        }
        // Break/continue label resolution does not cross function boundaries.
        const saved_control_frames = s.enterControlBoundary();
        var control_boundary_active = true;
        errdefer if (control_boundary_active) s.leaveControlBoundary(saved_control_frames);
        if (!capture_child) s.return_depth += 1;
        defer {
            if (!capture_child) s.return_depth -= 1;
        }
        try parseFunctionBodyBlock(s);
        if (s.is_strict) s.cur_func().is_strict_mode = true;
        if (s.cur_func().is_strict_mode) {
            if (s.cur_func().has_use_strict and !parameters.has_simple_list) return Error.UnexpectedToken;
            switch (func_kind) {
                .normal, .async, .generator, .async_generator => {
                    if (function_pending_name) |name| {
                        if (isInvalidStrictFunctionBindingName(s, name)) return Error.UnexpectedToken;
                    }
                },
                else => {},
            }
            for (parameters.simple_names.items) |param_name| {
                if (isInvalidStrictFunctionBindingName(s, param_name)) return Error.UnexpectedToken;
            }
        }
        // Mirrors the duplicate-argument gate in js_parse_function_check_names
        // (quickjs.c:36443-36448): strict mode, a non-simple parameter list,
        // methods (incl. getters/setters/class elements) and arrows reject
        // duplicates; plain sloppy function/generator/async declarations and
        // expressions with a simple list keep them legal.
        if (parameters.has_duplicate_simple and
            (is_method_params or
                func_kind == .method or func_kind == .get or func_kind == .set or
                func_kind == .arrow or
                func_kind == .class_constructor or func_kind == .derived_class_constructor or
                !parameters.has_simple_list or s.is_strict or s.cur_func().is_strict_mode))
            return Error.UnexpectedToken;
        s.leaveControlBoundary(saved_control_frames);
        control_boundary_active = false;
        if (capture_child) {
            const code = s.currentCode();
            const atoms = s.currentAtomOperands();
            // A jump targeting the current end (post-lowering `code_end`) needs
            // a real terminator to land on — the dispatch has no fall-off
            // bounds check (qjs-aligned; qjs functions always end in a return).
            const jump_to_end = hasJumpToCurrentEnd(code, atoms);
            const needs_return = jump_to_end or functionNeedsImplicitReturn(code, atoms);
            if (needs_return) {
                if (func_kind == .async) {
                    try s.emitOp(opcode.op.undefined);
                    try s.emitOp(opcode.op.return_async);
                } else if (func_kind == .generator or func_kind == .async_generator) {
                    try s.emitOp(opcode.op.undefined);
                    try s.emitOp(opcode.op.return_async);
                } else if (func_kind == .derived_class_constructor) {
                    try s.emitScopeGetVarCheckThis(atom_this);
                    try s.emitOp(opcode.op.@"return");
                } else {
                    // Keep QuickJS's parser shape: the expression-statement
                    // drop remains before the appended terminator. Final
                    // bytecode rules decide whether that drop can disappear.
                    try s.emitOp(opcode.op.return_undef);
                }
            }
        }

        s.pending_function_name = function_pending_name;
        s.pending_function_is_decl = function_pending_decl;
        s.pending_function_export_default = function_pending_export_default;

        if (capture_child) {
            if (source_start) |start| try s.captureFunctionSource(s.cur_func(), start);
            const child_ptr = s.popFunction();
            child_pushed = false;
            var child_moved = false;
            errdefer if (!child_moved) {
                s.discardFunctionDef(child_ptr);
            };
            s.emit_to_function_def = saved_emit_to_function_def;
            s.last_opcode_source_offset = saved_last_opcode_source_offset;
            s.scope_level = saved_scope_level;
            s.is_eval = saved_is_eval;
            s.eval_ret_idx = saved_eval_ret_idx;
            s.return_depth = saved_return_depth;
            s.is_strict = saved_is_strict;
            s.lex.is_strict_mode = saved_lex_is_strict;
            const child_cpool_idx: u16 = @intCast(try parent_fd.appendCpool(JSValue.undefinedValue()));
            child_ptr.parent_cpool_idx = child_cpool_idx;

            // QuickJS creates declaration carriers only after the child has a
            // constant-pool index (js_parse_function_decl2, `done:`).  Keeping
            // this plan on the parser stack avoids making the child FunctionDef
            // a side channel into its parent finalizer.
            if (function_decl_plan.active) {
                const name = function_decl_plan.binding_name;
                if (function_decl_plan.global_declaration) {
                    const global_idx = parent_fd.global_vars.len;
                    try s.addGlobalVar(name, false, false);
                    parent_fd.global_vars[global_idx].cpool_idx = @intCast(child_cpool_idx);
                } else if (function_decl_plan.body_declaration) {
                    switch (try s.defineVar(name, .var_)) {
                        .argument => |arg_idx| parent_fd.args[arg_idx].func_pool_idx = @intCast(child_cpool_idx),
                        .local => |var_idx| parent_fd.vars[var_idx].func_pool_idx = @intCast(child_cpool_idx),
                        .global => {
                            if (parent_fd.global_vars.len == 0) return Error.UnexpectedToken;
                            parent_fd.global_vars[parent_fd.global_vars.len - 1].cpool_idx = @intCast(child_cpool_idx);
                        },
                    }
                } else if (function_decl_plan.lexical_var_idx >= 0 and
                    function_decl_plan.scope_entry_init)
                {
                    const var_idx: usize = @intCast(function_decl_plan.lexical_var_idx);
                    if (var_idx >= parent_fd.vars.len) return Error.UnexpectedToken;
                    parent_fd.vars[var_idx].func_pool_idx = @intCast(child_cpool_idx);
                }

                switch (function_decl_plan.outer_carrier) {
                    .none => {},
                    .global => try s.addGlobalAnnexBFunctionVar(name, s.eval_global_var_bindings),
                    .eval_var_object => if (!s.findGlobalVar(name)) try s.addDirectEvalVarObjectVar(name),
                    .local => function_decl_plan.annex_b_var_idx = try s.ensureFunctionScopeVar(name),
                }
            }
            try parent_fd.addChild(child_ptr);
            child_moved = true;
            s.last_function_child_index = @intCast(parent_fd.child_list.len - 1);
            if (!s.pending_function_is_decl) {
                try s.emitFClosure(child_cpool_idx);
                s.last_anonymous_function_expr = s.pending_function_name == null;
            } else if (function_decl_plan.emit_inline) {
                if (function_decl_plan.skip_init) return;
                std.debug.assert(function_decl_plan.lexical_var_idx >= 0);
                try s.emitFClosure(child_cpool_idx);
                if (function_decl_plan.scope_entry_init) {
                    // OP_enter_scope already initialized the lexical function
                    // binding from VarDef.func_pool_idx.  The source-position
                    // closure is retained only for QuickJS's Annex B copy (or
                    // as the otherwise-discarded declaration value).
                    if (function_decl_plan.annex_b_var_idx >= 0) {
                        try s.emitOp(opcode.op.dup);
                        try s.emitOpU16(opcode.op.put_loc, @intCast(function_decl_plan.annex_b_var_idx));
                    }
                    if (function_decl_plan.emit_global_inline) {
                        try s.emitOp(opcode.op.dup);
                        try s.emitGlobalScopePutVar(function_decl_plan.binding_name);
                    }
                    if (function_decl_plan.emit_eval_var_inline) {
                        try s.emitOp(opcode.op.dup);
                        try s.emitEvalVarObjectScopePutVar(function_decl_plan.binding_name);
                    }
                    try s.emitOp(opcode.op.drop);
                } else {
                    if (function_decl_plan.emit_global_inline) try s.emitOp(opcode.op.dup);
                    if (function_decl_plan.emit_eval_var_inline) try s.emitOp(opcode.op.dup);
                    if (function_decl_plan.annex_b_var_idx >= 0) try s.emitOp(opcode.op.dup);
                    // zjs also emits this opcode for Annex-B source-position
                    // copies, so retain the existing declaration-class gate:
                    // #7's once-only derived-this rule is not universal here.
                    try s.emitOpU16(opcode.op.put_loc_check_init, @intCast(function_decl_plan.lexical_var_idx));
                    if (function_decl_plan.annex_b_var_idx >= 0) {
                        try s.emitOpU16(opcode.op.put_loc, @intCast(function_decl_plan.annex_b_var_idx));
                    }
                    if (function_decl_plan.emit_global_inline) {
                        try s.emitGlobalScopePutVar(function_decl_plan.binding_name);
                    }
                    if (function_decl_plan.emit_eval_var_inline) {
                        try s.emitEvalVarObjectScopePutVar(function_decl_plan.binding_name);
                    }
                }
            } else if (function_decl_plan.scope_entry_init) {
                // The binding itself is initialized at OP_enter_scope; retain
                // QuickJS's source-position declaration closure/drop pair.
                try s.emitFClosure(child_cpool_idx);
                try s.emitOp(opcode.op.drop);
            }
            if (s.namespace_export) {
                if (s.current_namespace_atom) |ns_atom| {
                    const func_atom = child_ptr.func_name;
                    if (func_atom != atom_module.ids.empty_string) {
                        try s.emitScopeGetVar(ns_atom);
                        try s.emitScopeGetVar(func_atom);
                        try s.emitOpAtom(opcode.op.put_field, func_atom);
                    }
                }
            }
        }
    }

    /// Parse arrow function
    /// Mirrors arrow function parsing in quickjs.c
    fn parseArrowFunction(s: *State, func_kind: ParseFunctionKind, source_start: usize, body_flags: ParseFlags) Error!void {
        s.features.insert(.function_);
        s.features.insert(.arrow);
        if (func_kind == .async or func_kind == .async_generator) {
            s.features.insert(.async_function);
        }
        const parent_fd = s.cur_func();
        const capture_child = s.cur_func_stack.len > 0 or s.top_level_functions_as_children;
        const saved_emit_to_function_def = s.emit_to_function_def;
        const saved_last_opcode_source_offset = s.last_opcode_source_offset;
        const saved_scope_level = s.scope_level;
        const saved_is_eval = s.is_eval;
        const saved_eval_ret_idx = s.eval_ret_idx;
        const saved_pending_name = s.pending_function_name;
        const saved_pending_decl = s.pending_function_is_decl;
        const saved_return_depth = s.return_depth;
        const saved_is_strict = s.is_strict;
        const saved_lex_is_strict = s.lex.is_strict_mode;
        const saved_new_target_allowed = s.new_target_allowed;
        const saved_in_constructor = s.in_constructor;
        s.in_constructor = false;
        defer s.in_constructor = saved_in_constructor;
        const saved_parameter_properties = s.current_parameter_properties;
        s.current_parameter_properties = null;
        defer s.current_parameter_properties = saved_parameter_properties;

        const arrow_new_target_allowed = saved_new_target_allowed;
        var child_pushed = false;
        errdefer if (child_pushed) {
            s.discardCurrentFunction();
            s.emit_to_function_def = saved_emit_to_function_def;
            s.last_opcode_source_offset = saved_last_opcode_source_offset;
            s.scope_level = saved_scope_level;
            s.is_eval = saved_is_eval;
            s.eval_ret_idx = saved_eval_ret_idx;
            s.return_depth = saved_return_depth;
            s.is_strict = saved_is_strict;
            s.lex.is_strict_mode = saved_lex_is_strict;
            s.new_target_allowed = saved_new_target_allowed;
        };
        const saved_return_finally = if (capture_child) enterReturnFinallyFunctionBoundary(s) else null;
        defer if (saved_return_finally) |*saved| leaveReturnFinallyFunctionBoundary(s, saved);
        s.pending_function_name = null;
        s.pending_function_is_decl = false;
        defer {
            s.pending_function_name = saved_pending_name;
            s.pending_function_is_decl = saved_pending_decl;
        }

        if (capture_child) {
            const child_fd = try s.function.memory.create(function_def_mod.FunctionDef);
            var child_owned_before_push = true;
            errdefer if (child_owned_before_push) s.discardFunctionDef(child_fd);
            child_fd.* = function_def_mod.FunctionDef.init(s.function.memory, s.function.atoms, atom_module.ids.empty_string);
            child_fd.atoms.replace(&child_fd.filename, parent_fd.filename);
            child_fd.atoms.replace(&child_fd.script_or_module, parent_fd.script_or_module);
            child_fd.line_num = @intCast(s.token.line_num);
            child_fd.col_num = @intCast(s.token.col_num);
            child_fd.parent = parent_fd;
            child_fd.parent_scope_level = parent_fd.scope_level;
            child_fd.parent_parameter_environment_only = s.in_parameter_initializer;
            child_fd.is_strict_mode = parent_fd.is_strict_mode or s.is_strict or s.lex.is_strict_mode;
            child_fd.use_short_opcodes = parent_fd.use_short_opcodes;
            child_fd.func_type = .arrow;
            child_fd.func_kind = if (func_kind == .async) .async else .normal;
            child_fd.has_prototype = false;
            child_fd.new_target_allowed = arrow_new_target_allowed;
            child_fd.super_allowed = s.allow_super;
            child_fd.super_call_allowed = s.allow_super_call;
            child_fd.arguments_allowed = parent_fd.arguments_allowed;
            _ = child_fd.appendScope(-1) catch return error.OutOfMemory;
            try s.pushFunction(child_fd);
            child_owned_before_push = false;
            child_pushed = true;
            s.emit_to_function_def = true;
            s.last_opcode_source_offset = null;
            s.scope_level = 0;
            s.is_eval = false;
            s.eval_ret_idx = -1;
            s.return_depth = 1;
        }
        const saved_outer_parameter_initializer = s.in_parameter_initializer;
        s.in_parameter_initializer = false;
        defer s.in_parameter_initializer = saved_outer_parameter_initializer;
        s.new_target_allowed = arrow_new_target_allowed;
        defer s.new_target_allowed = saved_new_target_allowed;

        // Set async flag for await parsing. Arrow parameter lists inherit the
        // enclosing Await grammar parameter, while the body uses the arrow's own
        // async-ness.
        const was_async = s.in_async;
        const is_async = func_kind == .async or func_kind == .async_generator;
        const params_in_async = is_async or was_async or s.lex.is_module or s.in_class_static_block;
        s.in_async = params_in_async;
        defer s.in_async = was_async;
        const saved_reject_await_in_parameter_initializer = s.reject_await_in_parameter_initializer;
        s.reject_await_in_parameter_initializer = params_in_async;
        defer s.reject_await_in_parameter_initializer = saved_reject_await_in_parameter_initializer;

        // Parse parameters. Two valid head shapes:
        //   `ident => ...`    — single bare identifier parameter
        //   `(...) => ...`    — parenthesized parameter list
        var has_non_simple_params = false;
        if (isIdentifierLikeToken(s)) {
            // Single bare identifier parameter.
            if (identifierLikeHasInvalidEscapeForBinding(s)) return Error.UnexpectedToken;
            const param_atom = identifierLikeAtom(s);
            if ((s.is_strict or s.cur_func().is_strict_mode) and isInvalidStrictFunctionBindingName(s, param_atom)) {
                return Error.UnexpectedToken;
            }
            if (capture_child) {
                _ = try s.cur_func().appendArg(.{
                    .var_name = param_atom,
                    .scope_level = 0,
                    .is_lexical = false,
                    .is_const = false,
                    .var_kind = .normal,
                });
            }
            try s.advance();
        } else {
            try s.expectToken('(');

            // Parse parameters, including default values, destructuring, and rest.
            var param_count: u32 = 0;
            var first_default_param: ?u32 = null;
            const parameter_scan = try scanParameterList(s);
            if (capture_child) s.cur_func().has_parameter_expressions = parameter_scan.has_parameter_expressions;
            const parameter_scope = if (capture_child and parameter_scan.has_parameter_expressions)
                try enterParameterExpressionScope(s)
            else
                null;
            var param_names: std.ArrayList(Atom) = .empty;
            defer param_names.deinit(s.function.memory.allocator);
            while (s.peekKind() != ')' and s.peekKind() != tok.TOK_EOF) {
                if (isIdentifierLikeToken(s)) {
                    if (identifierLikeHasInvalidEscapeForBinding(s)) return Error.UnexpectedToken;
                    const param_atom = identifierLikeAtom(s);
                    try appendArrowParamBindingName(s, &param_names, param_atom);
                    for (s.cur_func().vars) |existing| {
                        if (existing.var_name == param_atom) return Error.UnexpectedToken;
                    }
                    const arg_index = param_count;
                    if (capture_child) {
                        if (parameter_scope != null) {
                            try appendParameterExpressionBinding(s, param_atom);
                        }
                        _ = try s.cur_func().appendArg(.{
                            .var_name = param_atom,
                            .scope_level = 0,
                            .is_lexical = false,
                            .is_const = false,
                            .var_kind = .normal,
                        });
                    }
                    try s.advance();
                    param_count += 1;
                    if (s.peekKind() == '=') {
                        has_non_simple_params = true;
                        if (first_default_param == null) first_default_param = arg_index;
                        try s.advance();
                        if (capture_child) {
                            try s.emitOpU16(opcode.op.get_arg, @intCast(arg_index));
                            try s.emitOp(opcode.op.is_undefined);
                            const keep_value = try emitForwardJump(s, opcode.op.if_false);
                            const saved_in_parameter_initializer = s.in_parameter_initializer;
                            s.in_parameter_initializer = true;
                            defer s.in_parameter_initializer = saved_in_parameter_initializer;
                            try parseNamedBindingDefaultInitializer(s, param_atom);
                            try s.emitOpU16(opcode.op.put_arg, @intCast(arg_index));
                            try patchForwardJump(s, keep_value);
                        } else {
                            const saved_in_parameter_initializer = s.in_parameter_initializer;
                            s.in_parameter_initializer = true;
                            defer s.in_parameter_initializer = saved_in_parameter_initializer;
                            try parseNamedBindingDefaultInitializer(s, param_atom);
                            try s.emitOp(opcode.op.drop);
                        }
                    }
                    if (parameter_scope != null) {
                        try initializeParameterScopeBinding(s, param_atom, arg_index);
                    }
                } else if (s.peekKind() == '{') {
                    // Object destructuring parameter
                    const arg_index = param_count;
                    has_non_simple_params = true;
                    if (capture_child) try ensureDestructuringArgSlot(s, arg_index);
                    const has_initializer = try parseParameterDestructuring(
                        s,
                        if (capture_child) arg_index else null,
                        parameter_scope != null,
                        false,
                        true,
                    );
                    if (has_initializer and first_default_param == null) first_default_param = arg_index;
                    param_count += 1;
                } else if (s.peekKind() == '[') {
                    // Array destructuring parameter
                    const arg_index = param_count;
                    has_non_simple_params = true;
                    if (capture_child) try ensureDestructuringArgSlot(s, arg_index);
                    const has_initializer = try parseParameterDestructuring(
                        s,
                        if (capture_child) arg_index else null,
                        parameter_scope != null,
                        false,
                        true,
                    );
                    if (has_initializer and first_default_param == null) first_default_param = arg_index;
                    param_count += 1;
                } else if (s.peekKind() == tok.TOK_ELLIPSIS) {
                    s.features.insert(.spread_rest);
                    has_non_simple_params = true;
                    const arg_index = param_count;
                    try s.advance();
                    if (isIdentifierLikeToken(s)) {
                        if (identifierLikeHasInvalidEscapeForBinding(s)) return Error.UnexpectedToken;
                        const param_atom = identifierLikeAtom(s);
                        try appendArrowParamBindingName(s, &param_names, param_atom);
                        for (s.cur_func().vars) |existing| {
                            if (existing.var_name == param_atom) return Error.UnexpectedToken;
                        }
                        if (capture_child) {
                            if (parameter_scope != null) {
                                try appendParameterExpressionBinding(s, param_atom);
                            }
                            const idx = try s.cur_func().appendArg(.{
                                .var_name = param_atom,
                                .scope_level = 0,
                                .is_lexical = false,
                                .is_const = false,
                                .var_kind = .normal,
                            });
                            if (idx != @as(i32, @intCast(arg_index))) return Error.UnexpectedToken;
                            try s.emitOpU16(opcode.op.rest, @intCast(arg_index));
                            try s.emitOpU16(opcode.op.put_arg, @intCast(arg_index));
                            s.cur_func().defined_arg_count = @intCast(arg_index);
                        }
                        if (parameter_scope != null) {
                            try initializeParameterScopeBinding(s, param_atom, arg_index);
                        }
                        try s.advance();
                    } else if (s.peekKind() == '[') {
                        if (capture_child) {
                            try ensureDestructuringArgSlot(s, arg_index);
                            try s.emitOpU16(opcode.op.rest, @intCast(arg_index));
                            s.cur_func().defined_arg_count = @intCast(arg_index);
                        } else {
                            try s.emitOp(opcode.op.undefined);
                        }
                        if (try parseParameterDestructuring(
                            s,
                            if (capture_child) arg_index else null,
                            parameter_scope != null,
                            true,
                            false,
                        )) return Error.UnexpectedToken;
                    } else if (s.peekKind() == '{') {
                        if (capture_child) {
                            try ensureDestructuringArgSlot(s, arg_index);
                            try s.emitOpU16(opcode.op.rest, @intCast(arg_index));
                            s.cur_func().defined_arg_count = @intCast(arg_index);
                        } else {
                            try s.emitOp(opcode.op.undefined);
                        }
                        if (try parseParameterDestructuring(
                            s,
                            if (capture_child) arg_index else null,
                            parameter_scope != null,
                            true,
                            false,
                        )) return Error.UnexpectedToken;
                    } else {
                        return Error.UnexpectedToken;
                    }
                    break;
                } else {
                    return Error.UnexpectedToken;
                }

                if (s.peekKind() == ',') {
                    try s.advance();
                } else if (s.peekKind() != ')') {
                    return Error.UnexpectedToken;
                }
            }

            try s.expectToken(')');
            if (parameter_scope) |scope| try leaveParameterExpressionScope(s, scope);
            if (s.is_strict or s.cur_func().is_strict_mode) {
                for (param_names.items) |param_name| {
                    if (isInvalidStrictFunctionBindingName(s, param_name)) return Error.UnexpectedToken;
                }
            }
            if (capture_child) {
                if (first_default_param) |defined_count| {
                    s.cur_func().defined_arg_count = @intCast(defined_count);
                }
            }
        }

        if (capture_child) {
            s.cur_func().has_simple_parameter_list = !has_non_simple_params;
        }

        // Expect =>
        if (s.lex.got_lf) return Error.UnexpectedToken;
        try s.expectToken(tok.TOK_ARROW);
        s.in_async = is_async;

        const saved_static_block = s.in_class_static_block;
        s.in_class_static_block = false;
        defer s.in_class_static_block = saved_static_block;

        // Break/continue and active iterator cleanup do not cross function
        // boundaries. Keep arrows aligned with ordinary function bodies so a
        // return inside an arrow nested in for-of does not close the outer iterator.
        const saved_control_frames = s.enterControlBoundary();
        var control_boundary_active = true;
        errdefer if (control_boundary_active) s.leaveControlBoundary(saved_control_frames);

        // Parse body (can be block or expression).
        // parseFunctionBodyBlock consumes its own opening '{'.
        if (s.peekKind() == '{') {
            if (!capture_child) s.return_depth += 1;
            defer {
                if (!capture_child) s.return_depth -= 1;
            }
            try parseFunctionBodyBlock(s);
            if (has_non_simple_params and s.cur_func().has_use_strict) return Error.UnexpectedToken;
            if (capture_child) {
                const code = s.currentCode();
                const atoms = s.currentAtomOperands();
                // See the function-body epilogue: an end-targeting jump must
                // land on a real terminator (no dispatch fall-off check).
                const jump_to_end = hasJumpToCurrentEnd(code, atoms);
                const needs_return = jump_to_end or functionNeedsImplicitReturn(code, atoms);
                if (needs_return) {
                    if (is_async) {
                        try s.emitOp(opcode.op.undefined);
                        try s.emitOp(opcode.op.return_async);
                    } else {
                        try s.emitOp(opcode.op.return_undef);
                    }
                }
            }
        } else {
            try s.beginFunctionBody();
            errdefer s.popScopeIdentity();
            // Expression body. Deliberate spec-over-qjs divergence: ES6
            // ConciseBody[?In] inherits the no-`in` restriction (so
            // `for (x => 0 in 1;;)` is a SyntaxError, test262
            // staging/sm/statements/arrow-function-in-for-statement-head.js);
            // qjs parses arrow bodies with `js_parse_assign_expr`
            // (PF_IN_ACCEPTED, quickjs.c:31829) and accepts it.
            try parseAssignExpr2(s, .{ .in_accepted = body_flags.in_accepted });
            try s.emitOp(if (is_async) opcode.op.return_async else opcode.op.@"return");
            s.finishFunctionBody();
        }
        s.leaveControlBoundary(saved_control_frames);
        control_boundary_active = false;

        if (capture_child) {
            try s.captureFunctionSource(s.cur_func(), source_start);
            const child_ptr = s.popFunction();
            child_pushed = false;
            var child_moved = false;
            errdefer if (!child_moved) {
                s.discardFunctionDef(child_ptr);
            };
            s.emit_to_function_def = saved_emit_to_function_def;
            s.last_opcode_source_offset = saved_last_opcode_source_offset;
            s.scope_level = saved_scope_level;
            s.is_eval = saved_is_eval;
            s.eval_ret_idx = saved_eval_ret_idx;
            s.return_depth = saved_return_depth;
            s.is_strict = saved_is_strict;
            s.lex.is_strict_mode = saved_lex_is_strict;
            s.new_target_allowed = saved_new_target_allowed;
            const child_cpool_idx: u16 = @intCast(try parent_fd.appendCpool(JSValue.undefinedValue()));
            child_ptr.parent_cpool_idx = child_cpool_idx;
            try parent_fd.addChild(child_ptr);
            child_moved = true;
            s.last_function_child_index = @intCast(parent_fd.child_list.len - 1);
            try s.emitFClosure(child_cpool_idx);
            s.last_anonymous_function_expr = true;
        }
    }

    const DestructuringKind = enum { array, object };

    const PatternBindingMode = struct {
        define_type: State.DefineVarType,
        is_parameter: bool,
        export_flag: bool,
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

        fn depth(self: *const PatternTarget) u8 {
            return switch (self.*) {
                .direct_binding => 0,
                .lvalue => |lvalue| lvalue.depth,
            };
        }

        fn defaultName(self: *const PatternTarget) ?Atom {
            return switch (self.*) {
                .direct_binding => |binding| binding.name,
                .lvalue => |lvalue| switch (lvalue.opcode) {
                    .scope_var, .ref_value => lvalue.name,
                    else => null,
                },
            };
        }

        fn deinit(self: *PatternTarget, s: *State) void {
            switch (self.*) {
                .direct_binding => {},
                .lvalue => |*lvalue| lvalue.deinit(s),
            }
        }
    };

    const PatternTopology = struct {
        following: tok.TokenKind,
        has_top_level_rest: bool,
    };

    /// Token-only topology scan used to decide whether the outer pattern has
    /// an initializer/rest and whether a nested `[`/`{` is a pattern rather
    /// than the base of a member target.  It never parses expressions, emits
    /// code, defines variables, creates children, or mutates FunctionDef.
    fn scanPatternTopology(s: *State) Error!PatternTopology {
        if (s.peekKind() != @as(tok.TokenKind, @intCast('[')) and
            s.peekKind() != @as(tok.TokenKind, @intCast('{')))
        {
            return Error.UnexpectedToken;
        }

        const snapshot = takeParserSnapshot(s);
        defer restoreParserLexerSnapshot(s, snapshot);

        var depth: usize = 0;
        var has_top_level_rest = false;
        var previous_token_kind: ?tok.TokenKind = null;
        while (true) {
            const kind = s.peekKind();
            if (kind == tok.TOK_EOF) return Error.UnexpectedToken;
            if (kind == tok.TOK_TEMPLATE) {
                // A template token owns its `${ ... }` delimiters in the
                // lexer. Skip the complete template so delimiters inside a
                // substitution cannot terminate the outer topology scan.
                try skipTemplateInPredeclareScan(s, s.token);
                previous_token_kind = tok.TOK_TEMPLATE;
                try s.advance();
                continue;
            }
            if (kind == @as(tok.TokenKind, @intCast('[')) or
                kind == @as(tok.TokenKind, @intCast('{')) or
                kind == @as(tok.TokenKind, @intCast('(')))
            {
                depth += 1;
            } else if (kind == @as(tok.TokenKind, @intCast(']')) or
                kind == @as(tok.TokenKind, @intCast('}')) or
                kind == @as(tok.TokenKind, @intCast(')')))
            {
                if (depth == 0) return Error.UnexpectedToken;
                depth -= 1;
                try advanceRegexpAwareSpeculativeToken(s, &previous_token_kind);
                if (depth == 0) {
                    return .{
                        .following = s.peekKind(),
                        .has_top_level_rest = has_top_level_rest,
                    };
                }
                continue;
            } else if (kind == tok.TOK_ELLIPSIS and depth == 1) {
                has_top_level_rest = true;
            }
            try advanceRegexpAwareSpeculativeToken(s, &previous_token_kind);
        }
    }

    fn tokenStartsNestedPattern(s: *State, enclosing_close: tok.TokenKind) Error!bool {
        if (s.peekKind() != @as(tok.TokenKind, @intCast('[')) and
            s.peekKind() != @as(tok.TokenKind, @intCast('{')))
        {
            return false;
        }
        const topology = try scanPatternTopology(s);
        return topology.following == @as(tok.TokenKind, @intCast(',')) or
            topology.following == @as(tok.TokenKind, @intCast('=')) or
            topology.following == enclosing_close;
    }

    fn checkPatternParameterDuplicate(s: *State, name: Atom) Error!void {
        for (s.cur_func().args) |arg| {
            if (arg.var_name == name) return Error.UnexpectedToken;
        }
        for (s.cur_func().vars) |variable| {
            if (variable.var_name == name) return Error.UnexpectedToken;
        }
    }

    fn definePatternBindingAtom(s: *State, binding: PatternBindingMode, name: Atom) Error!PatternTarget {
        if ((s.is_strict or s.cur_func().is_strict_mode) and
            (atomNameEquals(s, name, "eval") or atomNameEquals(s, name, "arguments")))
        {
            return Error.UnexpectedToken;
        }
        if ((binding.define_type == .let_ or binding.define_type == .const_) and
            atomNameEquals(s, name, "let"))
        {
            return Error.UnexpectedToken;
        }
        if (binding.is_parameter) try checkPatternParameterDuplicate(s, name);

        // Imported/module declaration names are not represented in vars until
        // module resolution.  Preserve the same wrapper collision check used
        // by the simple declaration producer before calling defineVar.
        if ((binding.define_type == .let_ or binding.define_type == .const_) and
            s.top_level_lexical_as_module_ref and s.atProgramBodyScope() and
            hasKnownBinding(s, name))
        {
            return Error.UnexpectedToken;
        }

        const defined = try s.defineVar(name, binding.define_type);
        if (binding.define_type == .let_ or binding.define_type == .const_) {
            switch (defined) {
                .local => |idx| if (s.emit_lexical_tdz_at_decl) {
                    s.cur_func().vars[idx].tdz_emitted_at_decl = true;
                    try s.emitOpU16(opcode.op.set_loc_uninitialized, idx);
                },
                .global => {},
                .argument => unreachable,
            }
        }
        if (binding.export_flag) try addModuleExportName(s, name, name);

        if (binding.define_type == .var_ and needVarReference(s, tok.TOK_VAR)) {
            try s.emitScopeGetVar(name);
            return .{ .lvalue = try getLValue(s, false) };
        }
        return .{ .direct_binding = .{
            .name = name,
            .scope = @intCast(s.scope_level),
            .is_init = binding.define_type == .let_ or binding.define_type == .const_,
        } };
    }

    fn parsePatternBindingTarget(s: *State, binding: PatternBindingMode) Error!PatternTarget {
        if (!isIdentifierLikeToken(s) or identifierLikeHasInvalidEscapeForBinding(s)) {
            return Error.UnexpectedToken;
        }
        const name = identifierLikeAtom(s);
        var target = try definePatternBindingAtom(s, binding, name);
        errdefer target.deinit(s);
        try s.advance();
        return target;
    }

    fn parsePatternTarget(s: *State, mode: PatternMode) Error!PatternTarget {
        return switch (mode) {
            .binding => |binding| try parsePatternBindingTarget(s, binding),
            .assignment => blk: {
                try parseLhsExpr(s, ParseFlags{ .in_accepted = false });
                break :blk .{ .lvalue = try getLValue(s, false) };
            },
        };
    }

    fn shorthandPatternTarget(
        s: *State,
        mode: PatternMode,
        property: ObjectPropertyName,
    ) Error!PatternTarget {
        if (!property.allow_shorthand or
            (property.has_escape and escapedIdentifierIsReservedWordForBinding(s, property.atom, true)))
        {
            return Error.UnexpectedToken;
        }
        return switch (mode) {
            .binding => |binding| try definePatternBindingAtom(s, binding, property.atom),
            .assignment => blk: {
                try s.emitScopeGetVar(property.atom);
                break :blk .{ .lvalue = try getLValue(s, false) };
            },
        };
    }

    fn shorthandPatternCanUseGetField2(s: *State, mode: PatternMode) bool {
        return switch (mode) {
            .binding => |binding| binding.define_type != .var_ or !needVarReference(s, tok.TOK_VAR),
            .assignment => false,
        };
    }

    fn emitDirectPatternPut(s: *State, binding: anytype) Error!void {
        try s.ensureClosureVar(binding.name);
        if (s.emit_phase1_temp) {
            try s.emitOpAtomU16(
                if (binding.is_init) opcode.op.scope_put_var_init else opcode.op.scope_put_var,
                binding.name,
                binding.scope,
            );
        } else if (binding.is_init) {
            try s.emitGlobalVarOp(opcode.op.put_var_init, binding.name);
        } else {
            try s.emitGlobalVarOp(opcode.op.put_var, binding.name);
        }
    }

    fn putPatternTarget(s: *State, target: *PatternTarget) Error!void {
        switch (target.*) {
            .direct_binding => |binding| try emitDirectPatternPut(s, binding),
            .lvalue => |*lvalue| try putLValue(s, lvalue, .no_keep_depth),
        }
    }

    fn parsePatternDefault(s: *State, target: *const PatternTarget) Error!void {
        if (s.peekKind() != @as(tok.TokenKind, @intCast('='))) return;
        try s.emitOp(opcode.op.dup);
        try s.emitOp(opcode.op.undefined);
        try s.emitOp(opcode.op.strict_eq);
        const has_value = try emitForwardJump(s, opcode.op.if_false);
        try s.emitOp(opcode.op.drop);
        try s.advance();

        const saved_pending_name = s.pending_function_name;
        const saved_pending_decl = s.pending_function_is_decl;
        s.pending_function_name = target.defaultName();
        s.pending_function_is_decl = false;
        s.last_anonymous_function_expr = false;
        defer {
            s.pending_function_name = saved_pending_name;
            s.pending_function_is_decl = saved_pending_decl;
        }
        try parseAssignExpr(s);
        if (target.defaultName()) |name| try emitAnonymousDefaultName(s, name);
        try patchForwardJump(s, has_value);
    }

    fn rotateNamedSourcePastTarget(s: *State, depth: u8) Error!void {
        switch (depth) {
            0 => {},
            1 => try s.emitOp(opcode.op.swap),
            2 => try s.emitOp(opcode.op.rot3l),
            3 => try s.emitOp(opcode.op.rot4l),
            else => unreachable,
        }
    }

    fn rotateComputedSourcePastTarget(s: *State, depth: u8) Error!void {
        switch (depth) {
            0 => {},
            1 => try s.emitOp(opcode.op.rot3r),
            2 => try s.emitOp(opcode.op.swap2),
            3 => {
                try s.emitOp(opcode.op.rot5l);
                try s.emitOp(opcode.op.rot5l);
            },
            else => unreachable,
        }
    }

    fn addNamedObjectRestExclusion(s: *State, name: Atom) Error!void {
        try s.emitOp(opcode.op.swap);
        try s.emitOp(opcode.op.null);
        try s.emitOpAtom(opcode.op.define_field, name);
        try s.emitOp(opcode.op.swap);
    }

    fn addComputedObjectRestExclusion(s: *State) Error!void {
        try s.emitOp(opcode.op.to_propkey);
        try s.emitOp(opcode.op.perm3);
        try s.emitOp(opcode.op.null);
        try s.emitOp(opcode.op.define_array_el);
        try s.emitOp(opcode.op.perm3);
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
        try s.emitOpU16(opcode.op.array_from, 0);
        try s.emitOpI32(opcode.op.push_i32, 0);
        const next_pc: u32 = @intCast(s.currentCodeLen());
        try s.emitOpU8(opcode.op.for_of_next, target_depth + 2);
        const done = try emitForwardJump(s, opcode.op.if_true);
        try s.emitOp(opcode.op.define_array_el);
        try s.emitOp(opcode.op.inc);
        try emitBackwardJump(s, opcode.op.goto, next_pc);
        try patchForwardJump(s, done);
        try s.emitOp(opcode.op.drop);
        try s.emitOp(opcode.op.drop);
    }

    fn pushPatternIteratorBlock(s: *State, block: *BlockEnv) void {
        block.* = .{
            .prev = s.top_break,
            .label_name = atom_module.null_atom,
            .label_break = -1,
            .label_cont = -1,
            .drop_count = 2,
            .label_finally = -1,
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
    fn emitStackTopCatchMarkerDropsToDepth(s: *State, current_depth: *u32, target_depth: u32) Error!void {
        if (current_depth.* < target_depth) return Error.UnexpectedToken;
        while (current_depth.* > target_depth) {
            try s.emitOp(opcode.op.nip_catch);
            try emitUsingDisposesForCatchMarkerDepth(s, current_depth.*);
            current_depth.* -= 1;
        }
    }

    /// Unwind iterator records down to (but excluding) `boundary`. QuickJS
    /// interleaves catch/finally and iterator BlockEnv entries; zjs records the
    /// catch depth at iterator creation and emits the equivalent marker walk.
    fn emitBlockEnvReturnCleanupUntil(
        s: *State,
        block_cursor: *?*BlockEnv,
        boundary: ?*BlockEnv,
        catch_marker_depth: *u32,
    ) Error!void {
        const async_generator = s.in_async and s.in_generator;
        const return_atom = if (async_generator)
            atom_module.predefinedId("return", .string) orelse return Error.UnexpectedToken
        else
            atom_module.null_atom;
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
                try s.emitOp(opcode.op.nip);
                try s.emitOp(opcode.op.nip);
                continue;
            }
            if (current.has_iterator) {
                try emitStackTopCatchMarkerDropsToDepth(s, catch_marker_depth, current.catch_marker_depth);
                try s.emitOp(opcode.op.nip_catch);
                if (async_generator) {
                    // QuickJS emit_return (quickjs.c:28422-28440): discard the
                    // cached next method, call iterator.return(), require an
                    // Object result, await it, then restore the injected return
                    // value for the next enclosing cleanup / OP_return_async.
                    try s.emitOp(opcode.op.nip);
                    try s.emitOp(opcode.op.swap);
                    try s.emitOpAtom(opcode.op.get_field2, return_atom);
                    try s.emitOp(opcode.op.dup);
                    try s.emitOp(opcode.op.is_undefined_or_null);
                    const no_return = try emitForwardJump(s, opcode.op.if_true);
                    try s.emitOpU16(opcode.op.call_method, 0);
                    try s.emitOp(opcode.op.iterator_check_object);
                    try s.emitOp(opcode.op.await);
                    const closed = try emitForwardJump(s, opcode.op.goto);
                    try patchForwardJump(s, no_return);
                    try s.emitOp(opcode.op.drop);
                    try patchForwardJump(s, closed);
                    try s.emitOp(opcode.op.drop);
                } else {
                    try s.emitOp(opcode.op.rot3r);
                    try s.emitOp(opcode.op.undefined);
                    try s.emitOp(opcode.op.iterator_close);
                }
            }
        }
        if (boundary != null) return Error.UnexpectedToken;
    }

    fn parseArrayPatternBody(s: *State, mode: PatternMode) Error!void {
        try s.expectToken('[');
        try s.emitOp(opcode.op.for_of_start);

        var block: BlockEnv = undefined;
        pushPatternIteratorBlock(s, &block);
        var block_active = true;
        defer if (block_active) popPatternIteratorBlock(s, &block);

        while (s.peekKind() != @as(tok.TokenKind, @intCast(']'))) {
            if (s.peekKind() == tok.TOK_EOF) return Error.UnexpectedToken;

            var is_rest = false;
            if (s.peekKind() == tok.TOK_ELLIPSIS) {
                s.features.insert(.spread_rest);
                is_rest = true;
                try s.advance();
                if (s.peekKind() == @as(tok.TokenKind, @intCast(',')) or
                    s.peekKind() == @as(tok.TokenKind, @intCast(']')))
                {
                    return Error.UnexpectedToken;
                }
            }

            if (!is_rest and s.peekKind() == @as(tok.TokenKind, @intCast(','))) {
                try s.emitOpU8(opcode.op.for_of_next, 0);
                try s.emitOp(opcode.op.drop);
                try s.emitOp(opcode.op.drop);
            } else if (try tokenStartsNestedPattern(s, @as(tok.TokenKind, @intCast(']')))) {
                if (is_rest) {
                    const topology = try scanPatternTopology(s);
                    if (topology.following == @as(tok.TokenKind, @intCast('='))) return Error.UnexpectedToken;
                    try emitArrayPatternRest(s, 0);
                } else {
                    try s.emitOpU8(opcode.op.for_of_next, 0);
                    try s.emitOp(opcode.op.drop);
                }
                _ = try parseDestructuringElement(s, mode, true, true, ParseFlags.default);
            } else {
                var target = try parsePatternTarget(s, mode);
                defer target.deinit(s);
                if (is_rest) {
                    if (s.peekKind() == @as(tok.TokenKind, @intCast('='))) return Error.UnexpectedToken;
                    try emitArrayPatternRest(s, target.depth());
                } else {
                    try s.emitOpU8(opcode.op.for_of_next, target.depth());
                    try s.emitOp(opcode.op.drop);
                    try parsePatternDefault(s, &target);
                }
                try putPatternTarget(s, &target);
            }

            if (s.peekKind() == @as(tok.TokenKind, @intCast(']'))) break;
            if (is_rest) return Error.UnexpectedToken;
            try s.expectToken(',');
        }

        try s.expectToken(']');
        try s.emitOp(opcode.op.iterator_close);
        popPatternIteratorBlock(s, &block);
        block_active = false;
    }

    fn parseObjectPatternBody(s: *State, mode: PatternMode, has_rest: bool) Error!void {
        try s.expectToken('{');
        try s.emitOp(opcode.op.to_object);
        if (has_rest) {
            try s.emitOp(opcode.op.object);
            try s.emitOp(opcode.op.swap);
        }

        while (s.peekKind() != @as(tok.TokenKind, @intCast('}'))) {
            if (s.peekKind() == tok.TOK_EOF) return Error.UnexpectedToken;
            if (s.peekKind() == tok.TOK_ELLIPSIS) {
                if (!has_rest) return Error.UnexpectedToken;
                s.features.insert(.spread_rest);
                try s.advance();
                var target = try parsePatternTarget(s, mode);
                defer target.deinit(s);
                if (s.peekKind() != @as(tok.TokenKind, @intCast('}'))) return Error.UnexpectedToken;
                try s.emitOp(opcode.op.object);
                const depth = target.depth();
                const mask = try objectRestCopyMask(depth);
                try s.emitOpU8(opcode.op.copy_data_properties, mask);
                try putPatternTarget(s, &target);
                break;
            }

            var computed = false;
            var property_info: ?ObjectPropertyName = null;
            if (s.peekKind() == @as(tok.TokenKind, @intCast('['))) {
                computed = true;
                try s.advance();
                try parseAssignExpr(s);
                try s.expectToken(']');
            } else {
                property_info = (try parseObjectPropertyName(s)) orelse return Error.UnexpectedToken;
            }
            defer if (property_info) |property| {
                if (property.retained) s.function.atoms.free(property.atom);
            };

            const explicit_target = s.peekKind() == @as(tok.TokenKind, @intCast(':'));
            if (explicit_target) try s.advance();
            if (computed and !explicit_target) return Error.UnexpectedToken;

            if (explicit_target and try tokenStartsNestedPattern(s, @as(tok.TokenKind, @intCast('}')))) {
                if (computed) {
                    if (has_rest) try addComputedObjectRestExclusion(s) else try s.emitOp(opcode.op.to_propkey);
                    try s.emitOp(opcode.op.get_array_el2);
                } else {
                    const property = property_info orelse return Error.UnexpectedToken;
                    if (has_rest) try addNamedObjectRestExclusion(s, property.atom);
                    try s.emitOpAtom(opcode.op.get_field2, property.atom);
                }
                _ = try parseDestructuringElement(s, mode, true, true, ParseFlags.default);
            } else if (!computed and !explicit_target and shorthandPatternCanUseGetField2(s, mode)) {
                const property = property_info orelse return Error.UnexpectedToken;
                if (has_rest) try addNamedObjectRestExclusion(s, property.atom);
                var target = try shorthandPatternTarget(s, mode, property);
                defer target.deinit(s);
                if (target.depth() != 0) return Error.UnexpectedToken;
                // QuickJS's direct shorthand-binding arm keeps the source and
                // fetches the value in one opcode. Reference-producing `var`
                // bindings and assignment patterns stay on the depth-aware
                // dup/rotate/get_field path below.
                try s.emitOpAtom(opcode.op.get_field2, property.atom);
                try parsePatternDefault(s, &target);
                try putPatternTarget(s, &target);
            } else {
                if (computed) {
                    if (has_rest) try addComputedObjectRestExclusion(s) else try s.emitOp(opcode.op.to_propkey);
                    try s.emitOp(opcode.op.dup1);
                } else {
                    const property = property_info orelse return Error.UnexpectedToken;
                    if (has_rest) try addNamedObjectRestExclusion(s, property.atom);
                    try s.emitOp(opcode.op.dup);
                }

                var target = if (explicit_target)
                    try parsePatternTarget(s, mode)
                else
                    try shorthandPatternTarget(s, mode, property_info orelse return Error.UnexpectedToken);
                defer target.deinit(s);

                if (computed) {
                    try rotateComputedSourcePastTarget(s, target.depth());
                    try s.emitOp(opcode.op.get_array_el);
                } else {
                    try rotateNamedSourcePastTarget(s, target.depth());
                    try s.emitOpAtom(opcode.op.get_field, property_info.?.atom);
                }
                try parsePatternDefault(s, &target);
                try putPatternTarget(s, &target);
            }

            if (s.peekKind() == @as(tok.TokenKind, @intCast('}'))) break;
            try s.expectToken(',');
            if (s.peekKind() == @as(tok.TokenKind, @intCast('}'))) break;
        }

        try s.expectToken('}');
        try s.emitOp(opcode.op.drop);
        if (has_rest) try s.emitOp(opcode.op.drop);
    }

    /// Unified QuickJS-style destructuring traversal.  The pattern topology is
    /// parsed exactly once.  When an outer initializer exists, its bytecode is
    /// emitted after the pattern but reached first at runtime, preserving both
    /// source child order and initialization semantics without a temporary.
    fn parseDestructuringElement(
        s: *State,
        mode: PatternMode,
        has_value: bool,
        allow_outer_initializer: bool,
        initializer_flags: ParseFlags,
    ) Error!bool {
        s.features.insert(.destructuring);
        const topology = try scanPatternTopology(s);
        const has_initializer = allow_outer_initializer and
            topology.following == @as(tok.TokenKind, @intCast('='));
        if (!has_value and !has_initializer) return Error.UnexpectedToken;

        var parse_jump: ?usize = null;
        var assign_pc: u32 = @intCast(s.currentCodeLen());
        if (has_initializer) {
            if (has_value) {
                try s.emitOp(opcode.op.dup);
                try s.emitOp(opcode.op.undefined);
                try s.emitOp(opcode.op.strict_eq);
                parse_jump = try emitForwardJump(s, opcode.op.if_true);
            } else {
                parse_jump = try emitForwardJump(s, opcode.op.goto);
            }
            assign_pc = @intCast(s.currentCodeLen());
            if (!has_value) try s.emitOp(opcode.op.dup);
        }

        switch (s.peekKind()) {
            @as(tok.TokenKind, @intCast('[')) => try parseArrayPatternBody(s, mode),
            @as(tok.TokenKind, @intCast('{')) => try parseObjectPatternBody(s, mode, topology.has_top_level_rest),
            else => return Error.UnexpectedToken,
        }

        if (has_initializer) {
            const done = try emitForwardJump(s, opcode.op.goto);
            try patchForwardJump(s, parse_jump orelse return Error.UnexpectedToken);
            if (has_value) try s.emitOp(opcode.op.drop);
            try s.expectToken('=');
            s.last_anonymous_function_expr = false;
            try parseAssignExpr2(s, initializer_flags);
            s.last_anonymous_function_expr = false;
            try emitBackwardJump(s, opcode.op.goto, assign_pc);
            try patchForwardJump(s, done);
        }
        return has_initializer;
    }

    fn appendArrowParamBindingName(s: *State, names: *std.ArrayList(Atom), atom_id: Atom) Error!void {
        for (names.items) |existing| {
            if (existing == atom_id) return Error.UnexpectedToken;
        }
        try names.append(s.function.memory.allocator, atom_id);
    }

    const ParserSnapshot = struct {
        pos: usize,
        line: u32,
        col: u32,
        got_lf: bool,
        mark_pos: usize,
        mark_line: u32,
        mark_col: u32,
        token: tok.Token,
        last_token_end_offset: usize,
        last_token_line_num: u32,
        last_token_col_num: u32,
        last_opcode_source_offset: ?u32,
        last_opcode_pos: i32,
        code_len: usize,
        atom_len: usize,
        source_loc_len: usize,
        label_count: u32,
        features: std.EnumSet(FeatureImpl),
    };

    fn takeParserSnapshot(s: *State) ParserSnapshot {
        return .{
            .pos = s.lex.pos,
            .line = s.lex.line,
            .col = s.lex.col,
            .got_lf = s.lex.got_lf,
            .mark_pos = s.lex.mark_pos,
            .mark_line = s.lex.mark_line,
            .mark_col = s.lex.mark_col,
            .token = s.token,
            .last_token_end_offset = s.last_token_end_offset,
            .last_token_line_num = s.last_token_line_num,
            .last_token_col_num = s.last_token_col_num,
            .last_opcode_source_offset = s.last_opcode_source_offset,
            .last_opcode_pos = s.cur_func().last_opcode_pos,
            .code_len = s.currentCodeLen(),
            .atom_len = s.currentAtomOperandLen(),
            .source_loc_len = if (s.emit_to_function_def)
                s.cur_func().source_loc_slots.len
            else
                s.function.source_loc_slots.len,
            .label_count = s.currentParserLabelCount(),
            .features = s.features,
        };
    }

    fn restoreParserLexerSnapshot(s: *State, snapshot: ParserSnapshot) void {
        s.lex.freeToken(&s.token);
        s.lex.pos = snapshot.pos;
        s.lex.line = snapshot.line;
        s.lex.col = snapshot.col;
        s.lex.got_lf = snapshot.got_lf;
        s.lex.mark_pos = snapshot.mark_pos;
        s.lex.mark_line = snapshot.mark_line;
        s.lex.mark_col = snapshot.mark_col;
        s.token = snapshot.token;
        s.last_token_end_offset = snapshot.last_token_end_offset;
        s.last_token_line_num = snapshot.last_token_line_num;
        s.last_token_col_num = snapshot.last_token_col_num;
    }

    const ParameterListScan = struct {
        has_parameter_expressions: bool = false,
    };

    fn enterParameterExpressionScope(s: *State) Error!i32 {
        const fd = s.cur_func();
        const scope = fd.appendScope(-1) catch return error.OutOfMemory;
        s.scope_level = scope;
        fd.scope_level = scope;
        // qjs forces the parameter environment to have no parent, then uses
        // the ordinary push_scope path.  Its OP_enter_scope is what lowers
        // every parameter binding to an initially-uninitialized lexical slot
        // before any default initializer runs (quickjs.c:36699-36706).
        try s.emitEnterScope();
        return scope;
    }

    fn appendParameterExpressionBinding(s: *State, name: Atom) Error!void {
        _ = try s.defineVar(name, .let_);
    }

    fn initializeParameterScopeBinding(s: *State, name: Atom, arg_index: u32) Error!void {
        try s.emitOpU16(opcode.op.get_arg, @intCast(arg_index));
        try s.emitScopePutVarInit(name);
    }

    fn parseParameterDestructuring(
        s: *State,
        arg_index: ?u32,
        has_parameter_expressions: bool,
        value_already_on_stack: bool,
        allow_outer_initializer: bool,
    ) Error!bool {
        const saved_in_parameter_initializer = s.in_parameter_initializer;
        if (has_parameter_expressions) {
            s.in_parameter_initializer = true;
        }
        defer s.in_parameter_initializer = saved_in_parameter_initializer;

        if (!value_already_on_stack) {
            if (arg_index) |idx| {
                try s.emitOpU16(opcode.op.get_arg, @intCast(idx));
            } else {
                try s.emitOp(opcode.op.undefined);
            }
        }
        return parseDestructuringElement(
            s,
            .{ .binding = .{
                .define_type = if (has_parameter_expressions) .let_ else .var_,
                .is_parameter = true,
                .export_flag = false,
            } },
            true,
            allow_outer_initializer,
            ParseFlags.default,
        );
    }

    fn leaveParameterExpressionScope(s: *State, parameter_scope: i32) Error!void {
        const fd = s.cur_func();
        var var_index = fd.scopes[@intCast(parameter_scope)].first;
        var visited: usize = 0;
        while (var_index >= 0 and visited <= fd.vars.len) : (visited += 1) {
            const idx: usize = @intCast(var_index);
            if (idx >= fd.vars.len) return Error.UnexpectedToken;
            const vd = fd.vars[idx];
            const next = vd.scope_next;
            if (vd.scope_level != parameter_scope) return Error.UnexpectedToken;
            var_index = next;
            if (fd.findArg(vd.var_name) >= 0 or s.findFunctionScopeVar(vd.var_name) != null) continue;

            // QuickJS copies parameter-environment-only names with add_var,
            // not add_scope_var: this scope-0 row must not enter a lexical
            // scope.first chain.  Its zero parser-origin matches the freshly
            // zeroed upstream VarDef until final linkage rebuild.
            const body_idx = try s.appendFunctionVarAtOrigin(vd.var_name, 0);
            try s.emitOpU16(opcode.op.get_loc_check, @intCast(idx));
            try s.emitOpU16(opcode.op.put_loc, body_idx);
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
        const snapshot = takeParserSnapshot(s);
        defer restoreParserLexerSnapshot(s, snapshot);

        var scan = ParameterListScan{};

        while (s.peekKind() != ')' and s.peekKind() != tok.TOK_EOF) {
            if (s.peekKind() == tok.TOK_IDENT) {
                try s.advance();
                if (s.peekKind() == '=') {
                    scan.has_parameter_expressions = true;
                    try s.advance();
                    var depth: usize = 0;
                    var previous_token_kind: ?tok.TokenKind = '=';
                    while (s.peekKind() != tok.TOK_EOF) {
                        const k = s.peekKind();
                        if (depth == 0 and (k == ',' or k == ')')) break;
                        if (k == '=') scan.has_parameter_expressions = true;
                        if (k == '(' or k == '[' or k == '{') depth += 1;
                        if ((k == ')' or k == ']' or k == '}') and depth > 0) depth -= 1;
                        try advanceRegexpAwareSpeculativeToken(s, &previous_token_kind);
                    }
                }
            } else if (s.peekKind() == tok.TOK_ELLIPSIS) {
                try s.advance();
                if (s.peekKind() == tok.TOK_IDENT) {
                    try s.advance();
                }
                var depth: usize = 0;
                var previous_token_kind: ?tok.TokenKind = tok.TOK_ELLIPSIS;
                while (s.peekKind() != tok.TOK_EOF) {
                    const k = s.peekKind();
                    if (depth == 0 and k == ')') break;
                    if (k == '=') scan.has_parameter_expressions = true;
                    if (k == '(' or k == '[' or k == '{') depth += 1;
                    if ((k == ')' or k == ']' or k == '}') and depth > 0) depth -= 1;
                    try advanceRegexpAwareSpeculativeToken(s, &previous_token_kind);
                }
                break;
            } else {
                var depth: usize = 0;
                var previous_token_kind: ?tok.TokenKind = null;
                while (s.peekKind() != tok.TOK_EOF) {
                    const k = s.peekKind();
                    if (depth == 0 and (k == ',' or k == ')')) break;
                    if (k == '=') scan.has_parameter_expressions = true;
                    if (k == '(' or k == '[' or k == '{') depth += 1;
                    if ((k == ')' or k == ']' or k == '}') and depth > 0) depth -= 1;
                    try advanceRegexpAwareSpeculativeToken(s, &previous_token_kind);
                }
            }

            if (s.peekKind() == ',') {
                try s.advance();
            } else if (s.peekKind() != ')') {
                break;
            }
        }

        return scan;
    }

    fn ensureDestructuringArgSlot(s: *State, arg_index: u32) Error!void {
        const child = s.cur_func();
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

    fn findCurrentScopeVar(s: *State, atom_id: Atom) ?u16 {
        const vars = s.cur_func().vars;
        var i: usize = vars.len;
        while (i > 0) {
            i -= 1;
            if (vars[i].var_name == atom_id and vars[i].scope_level == s.scope_level) return @intCast(i);
        }
        return null;
    }

    fn appendTempLocal(s: *State) Error!u16 {
        return try appendAnonymousTempLocal(s);
    }

    fn appendAnonymousTempLocal(s: *State) Error!u16 {
        const idx = try s.cur_func().appendVar(.{
            .var_name = atom_module.null_atom,
            .scope_level = 0,
            .is_lexical = false,
            .is_const = false,
            .var_kind = .normal,
        });
        return @intCast(idx);
    }

    fn parseNamedBindingDefaultInitializer(s: *State, atom_id: Atom) Error!void {
        const saved_pending_name = s.pending_function_name;
        const saved_pending_decl = s.pending_function_is_decl;
        s.pending_function_name = atom_id;
        s.pending_function_is_decl = false;
        s.last_anonymous_function_expr = false;
        defer {
            s.pending_function_name = saved_pending_name;
            s.pending_function_is_decl = saved_pending_decl;
        }
        try parseAssignExpr(s);
        try emitAnonymousDefaultName(s, atom_id);
    }

    fn emitAnonymousDefaultName(s: *State, atom_id: Atom) Error!void {
        if (!s.last_anonymous_function_expr) return;
        try s.emitOpAtom(opcode.op.set_name, atom_id);
        s.last_anonymous_function_expr = false;
    }

    // ---- Class parsing ----------------------------------------------------

    /// Parse class heritage (extends clause)
    /// Mirrors `js_parse_class_extends` in quickjs.c
    fn parseClassHeritage(s: *State) Error!void {
        if (s.peekKind() == tok.TOK_EXTENDS) {
            try s.advance();
            // ClassHeritage is `extends LeftHandSideExpression`, not a full
            // assignment expression; arrow expressions are rejected here.
            if (checkArrowHead(s) or
                checkIdentArrowHead(s) or
                checkAsyncSingleParamArrowHead(s) or
                checkAsyncParenArrowHead(s))
            {
                return Error.UnexpectedToken;
            }
            try parseLhsExpr(s, ParseFlags.default);
        }
    }

    /// Parse a single class element
    /// Mirrors class element parsing in quickjs.c
    fn parseClassElement(s: *State) Error!void {
        const saved_static = s.is_static;
        const saved_in_constructor = s.in_constructor;
        defer {
            s.is_static = saved_static;
            s.in_constructor = saved_in_constructor;
        }

        // QuickJS treats `static` as a modifier only when it cannot be the
        // element name itself (`static;`, `static = ...`, `static()`).
        if (s.peekKind() == tok.TOK_STATIC) {
            const next = s.peekNextKind();
            if (next != @as(tok.TokenKind, @intCast(';')) and
                next != @as(tok.TokenKind, @intCast('}')) and
                next != @as(tok.TokenKind, @intCast('(')) and
                next != @as(tok.TokenKind, @intCast('=')))
            {
                s.is_static = true;
                try s.advance();
            }
        }

        const element_source_start = s.currentTokenStartOffset();
        var method_kind_override: ?ParseFunctionKind = null;
        if (s.peekKind() == tok.TOK_IDENT and s.isIdent("async") and
            s.peekNextKind() != @as(tok.TokenKind, @intCast(':')) and
            s.peekNextKind() != @as(tok.TokenKind, @intCast('(')) and
            s.peekNextKind() != @as(tok.TokenKind, @intCast('=')) and
            s.peekNextKind() != @as(tok.TokenKind, @intCast(';')) and
            s.peekNextKind() != @as(tok.TokenKind, @intCast('}')))
        {
            try s.advance();
            if (s.gotLineTerminator()) return Error.UnexpectedToken;
            if (s.peekKind() == @as(tok.TokenKind, @intCast('*'))) {
                try s.advance();
                method_kind_override = .async_generator;
            } else {
                method_kind_override = .async;
            }
        } else if (s.peekKind() == @as(tok.TokenKind, @intCast('*'))) {
            try s.advance();
            method_kind_override = .generator;
        }

        // Check for getter/setter. A line terminator after `get` / `set`,
        // or a following token that makes the word the element name itself,
        // leaves it to the ordinary property-name path below.
        const accessor_kind = classAccessorKind(s);
        if (accessor_kind) |is_getter| {
            try s.advance();
            // Check if this is a private getter/setter (get #x() or set #x())
            if (s.peekKind() == tok.TOK_PRIVATE_NAME) {
                const private_atom = try privateNameAtom(s, s.token.payload.ident.atom);
                defer s.function.atoms.free(private_atom);
                if (atomNameEquals(s, private_atom, "#constructor")) return Error.UnexpectedToken;
                try registerClassPrivateElement(s, private_atom, if (is_getter) .getter else .setter);
                try preparePrivateAccessorBinding(s, private_atom, is_getter);
                try s.advance();
                if (s.peekKind() != '(') {
                    return Error.UnexpectedToken;
                }
                // Parse parameters with proper function kind for private getter/setter
                const kind: ParseFunctionKind = if (is_getter) .get else .set;
                try parseClassElementFunction(s, kind, element_source_start);
                try markPrivateBrandNeeded(s);
                if (s.is_static) try s.emitOp(opcode.op.perm3);
                try s.emitOp(opcode.op.set_home_object);
                if (is_getter) {
                    try s.emitScopePutVarInit(private_atom);
                } else {
                    const setter_atom = try privateSetterAtom(s, private_atom);
                    defer s.function.atoms.free(setter_atom);
                    _ = try addPrivateClassBinding(s, setter_atom, .private_setter);
                    try s.emitScopePutVarInit(setter_atom);
                }
                if (s.is_static) try s.emitOp(opcode.op.swap);
            } else if (s.peekKind() == '[') {
                try emitClassComputedMethod(s, if (is_getter) .get else .set, if (is_getter) 1 else 2, element_source_start);
            } else {
                // Regular getter/setter - parse property name (identifier, string, or number)
                const prop_name = (try parseObjectPropertyName(s)) orelse return Error.UnexpectedToken;
                const prop_atom = prop_name.atom;
                defer if (prop_name.retained) s.function.atoms.free(prop_atom);
                if (!s.is_static and prop_atom == atom_module.ids.constructor) return Error.UnexpectedToken;
                if (s.is_static and prop_atom == atom_module.ids.prototype) return Error.UnexpectedToken;
                if (s.peekKind() != '(') {
                    return Error.UnexpectedToken;
                }
                // Parse parameters with proper function kind for getter/setter
                const kind: ParseFunctionKind = if (is_getter) .get else .set;
                try parseClassElementFunction(s, kind, element_source_start);
                if (s.is_static) try s.emitOp(opcode.op.perm3);
                try s.emitOpAtomU8(opcode.op.define_method, prop_atom, if (is_getter) 1 else 2);
                if (s.is_static) try s.emitOp(opcode.op.swap);
            }
            return;
        }

        // Check for private field (#x)
        if (s.peekKind() == tok.TOK_PRIVATE_NAME) {
            const private_atom = try privateNameAtom(s, s.token.payload.ident.atom);
            defer s.function.atoms.free(private_atom);
            if (atomNameEquals(s, private_atom, "#constructor")) return Error.UnexpectedToken;
            try s.advance();
            if (s.peekKind() == '(') {
                // Private method
                try registerClassPrivateElement(s, private_atom, .method);
                try parseClassElementFunction(s, method_kind_override orelse .method, element_source_start);
                _ = try addPrivateClassBinding(s, private_atom, .private_method);
                try markPrivateBrandNeeded(s);
                if (s.is_static) try s.emitOp(opcode.op.perm3);
                try s.emitOp(opcode.op.set_home_object);
                try s.emitOpAtom(opcode.op.set_name, private_atom);
                try s.emitScopePutVarInit(private_atom);
                if (s.is_static) try s.emitOp(opcode.op.swap);
                if (s.peekKind() == ';') try s.advance();
                return;
            } else if (s.peekKind() == '=') {
                // Private field with initializer
                try registerClassPrivateElement(s, private_atom, .field);
                try addPrivateClassFieldBinding(s, private_atom);
                try s.advance();
                if (s.is_static) {
                    try emitStaticFieldInitializer(s, private_atom, true, false, true);
                } else {
                    try emitInstanceFieldInitializer(s, private_atom, true, true);
                }
            } else {
                try registerClassPrivateElement(s, private_atom, .field);
                try addPrivateClassFieldBinding(s, private_atom);
                if (s.is_static) {
                    try emitStaticFieldInitializer(s, private_atom, true, false, false);
                } else {
                    try emitInstanceFieldInitializer(s, private_atom, false, true);
                }
            }
            _ = try s.expectSemicolon();
            return;
        }

        if (s.peekKind() == '[') {
            if (s.is_static) {
                try emitStaticClassComputedElement(s, method_kind_override orelse .method, element_source_start);
            } else {
                try emitInstanceClassComputedElement(s, method_kind_override orelse .method, element_source_start);
            }
            if (s.peekKind() == ';') try s.advance();
            return;
        }

        // Check for method or field
        if (try parseObjectPropertyName(s)) |prop_name| {
            const prop_atom = prop_name.atom;
            defer if (prop_name.retained) s.function.atoms.free(prop_atom);
            const has_line_terminator_after_name = s.gotLineTerminator();
            const is_constructor = !s.is_static and prop_atom == atom_module.ids.constructor;
            if (s.is_static and prop_atom == atom_module.ids.prototype and s.peekKind() == '(') return Error.UnexpectedToken;
            if (is_constructor and method_kind_override != null) return Error.UnexpectedToken;
            if (s.is_static and atomNameEquals(s, prop_atom, "name")) {
                s.class_static_name_seen = true;
            }

            if (s.peekKind() == '(') {
                // Method or constructor
                if (is_constructor) {
                    if (s.class_constructor_cpool_idx != null) return Error.UnexpectedToken;
                    s.in_constructor = true;
                }
                const element_code_start = s.currentCodeLen();
                const element_atom_start = s.currentAtomOperandLen();
                // Parse parameters with proper function kind for constructor/method
                const kind: ParseFunctionKind = if (is_constructor)
                    if (s.class_has_extends) .derived_class_constructor else .class_constructor
                else
                    method_kind_override orelse .method;
                try parseClassElementFunction(s, kind, element_source_start);
                if (is_constructor) {
                    if (s.last_function_child_index) |child_index| {
                        try s.truncateCode(element_code_start);
                        try s.truncateAtomOperands(element_atom_start);
                        const cpool_idx = s.cur_func().child_list[child_index].parent_cpool_idx;
                        if (cpool_idx < 0 or cpool_idx > std.math.maxInt(u16)) return Error.UnexpectedToken;
                        s.class_constructor_cpool_idx = @intCast(cpool_idx);
                    }
                    s.in_constructor = saved_in_constructor;
                } else {
                    if (s.is_static) try s.emitOp(opcode.op.perm3);
                    try s.emitOpAtomU8(opcode.op.define_method, prop_atom, 0);
                    if (s.is_static) try s.emitOp(opcode.op.swap);
                }
                // Optional ASI semicolon after method
                if (s.peekKind() == ';') try s.advance();
            } else if (s.peekKind() == '=') {
                // Field with initializer
                if (isForbiddenPublicFieldName(s, prop_atom)) return Error.UnexpectedToken;
                try s.advance();
                if (s.is_static) {
                    try emitStaticFieldInitializer(s, prop_atom, false, false, true);
                } else {
                    try emitInstanceFieldInitializer(s, prop_atom, true, false);
                }
                _ = try s.expectSemicolon();
            } else if (s.peekKind() == ';') {
                // Field without initializer, with semicolon
                if (isForbiddenPublicFieldName(s, prop_atom)) return Error.UnexpectedToken;
                try emitPublicFieldNoInitializer(s, prop_atom);
                try s.advance();
            } else {
                if (isForbiddenPublicFieldName(s, prop_atom)) return Error.UnexpectedToken;
                try emitPublicFieldNoInitializer(s, prop_atom);
                if (s.peekKind() == ';') {
                    try s.advance();
                } else if (!(has_line_terminator_after_name or s.peekKind() == tok.TOK_EOF or s.isPunct('}'))) {
                    return Error.UnexpectedToken;
                }
            }
        } else if (s.peekKind() == '{') {
            // Static block — parseBlock consumes its own opening '{'.
            if (!s.is_static) {
                return Error.UnexpectedToken;
            }
            try emitClassStaticBlock(s);
        } else {
            return Error.UnexpectedToken;
        }

        s.is_static = saved_static;
        s.in_constructor = saved_in_constructor;
    }

    fn classAccessorKind(s: *State) ?bool {
        if (!(s.peekKind() == tok.TOK_IDENT and (s.isIdent("get") or s.isIdent("set")))) return null;

        var has_line_terminator = false;
        const next = s.peekNextKindWithLineTerminator(&has_line_terminator);
        if (has_line_terminator) return null;
        if (next == @as(tok.TokenKind, @intCast('(')) or
            next == @as(tok.TokenKind, @intCast('=')) or
            next == @as(tok.TokenKind, @intCast(';')) or
            next == @as(tok.TokenKind, @intCast('}')))
        {
            return null;
        }
        return s.isIdent("get");
    }

    fn registerClassPrivateElement(s: *State, atom_id: Atom, kind: ClassPrivateElementKind) Error!void {
        for (s.class_private_elements.items) |entry| {
            if (entry.atom != atom_id) continue;
            if (classPrivateElementsConflict(entry, kind, s.is_static)) {
                return Error.UnexpectedToken;
            }
        }
        const retained = s.function.atoms.dup(atom_id);
        errdefer s.function.atoms.free(retained);
        try s.class_private_elements.append(s.function.memory.allocator, .{
            .atom = retained,
            .kind = kind,
            .is_static = s.is_static,
        });
    }

    /// QuickJS `add_private_class_field`: every private element is represented
    /// by a lexical const VarDef. Only the parser-time row retains the static
    /// discriminator used to validate getter/setter pairing.
    fn addPrivateClassBinding(s: *State, atom_id: Atom, kind: function_def_mod.VarKind) Error!u16 {
        const idx = try s.addScopeVar(atom_id, kind, true, true);
        if (idx < 0 or @as(usize, @intCast(idx)) >= s.cur_func().vars.len) return Error.UnexpectedToken;
        s.cur_func().vars[@intCast(idx)].is_static_private = s.is_static;
        return @intCast(idx);
    }

    fn addPrivateClassFieldBinding(s: *State, atom_id: Atom) Error!void {
        _ = try addPrivateClassBinding(s, atom_id, .private_field);
        try s.emitOpAtom(opcode.op.private_symbol, atom_id);
        try s.emitScopePutVarInit(atom_id);
    }

    fn preparePrivateAccessorBinding(s: *State, atom_id: Atom, is_getter: bool) Error!void {
        if (findCurrentScopeVar(s, atom_id)) |idx| {
            const vd = &s.cur_func().vars[idx];
            if (vd.is_static_private != s.is_static) return Error.UnexpectedToken;
            const expected: function_def_mod.VarKind = if (is_getter) .private_setter else .private_getter;
            if (vd.var_kind != expected) return Error.UnexpectedToken;
            vd.var_kind = .private_getter_setter;
            return;
        }
        _ = try addPrivateClassBinding(s, atom_id, if (is_getter) .private_getter else .private_setter);
    }

    fn privateSetterAtom(s: *State, private_atom: Atom) Error!Atom {
        const name = s.function.atoms.name(private_atom) orelse return Error.InvalidIdentifier;
        const suffix = "<set>";
        const bytes = try s.function.memory.alloc(u8, name.len + suffix.len);
        defer s.function.memory.free(u8, bytes);
        @memcpy(bytes[0..name.len], name);
        @memcpy(bytes[name.len..], suffix);
        return s.function.atoms.newSymbol(bytes, .private);
    }

    fn markPrivateBrandNeeded(s: *State) Error!void {
        if (s.is_static) {
            s.class_static_private_brand_needed = true;
            return;
        }
        s.class_instance_private_brand_needed = true;
        const child_index = try ensureClassFieldsInitFunction(s);
        const parent = s.cur_func();
        if (child_index >= parent.child_list.len) return Error.UnexpectedToken;
        const init_fd = parent.child_list[child_index];
        if (init_fd.byte_code.len == 0) return Error.UnexpectedToken;
        switch (init_fd.byte_code[0]) {
            opcode.op.push_false => init_fd.byte_code[0] = opcode.op.push_true,
            // Multiple private methods/accessors share the same initializer
            // prologue. Patching it is deliberately idempotent.
            opcode.op.push_true => {},
            else => return Error.UnexpectedToken,
        }
    }

    fn isForbiddenPublicFieldName(s: *State, atom_id: Atom) bool {
        if (!s.is_static) return atom_id == atom_module.ids.constructor;
        return atom_id == atom_module.ids.constructor or atom_id == atom_module.ids.prototype;
    }

    fn classNameAtom(s: *State) ?Atom {
        const kind = s.peekKind();
        if (kind == tok.TOK_IDENT) {
            const atom_id = s.token.payload.ident.atom;
            if (escapedIdentifierIsReservedClassName(s, atom_id, s.token.payload.ident.has_escape)) return null;
            return atom_id;
        }
        if (kind == tok.TOK_AWAIT and canUseAwaitAsIdentifier(s)) {
            return tok.keywordAtom(kind);
        }
        return null;
    }

    fn escapedIdentifierIsReservedClassName(s: *State, atom_id: Atom, has_escape: bool) bool {
        if (!has_escape) return false;
        return escapedIdentifierIsReservedWordForShorthandBinding(s, atom_id, has_escape) or
            ((s.lex.is_module or s.in_async or s.in_class_static_block) and atomNameEquals(s, atom_id, "await"));
    }

    fn emitStaticFieldInitializer(
        s: *State,
        atom_id: Atom,
        is_private: bool,
        is_computed: bool,
        has_initializer: bool,
    ) Error!void {
        const child_index = try ensureClassStaticInitFunction(s);
        const parent_fd = s.cur_func();
        if (child_index >= parent_fd.child_list.len) return Error.UnexpectedToken;
        const init_fd = parent_fd.child_list[child_index];

        const saved_emit_to_function_def = s.emit_to_function_def;
        const saved_last_opcode_source_offset = s.last_opcode_source_offset;
        const saved_scope_level = s.scope_level;
        const saved_is_strict = s.is_strict;
        const saved_lex_is_strict = s.lex.is_strict_mode;
        const saved_allow_super = s.allow_super;
        const saved_allow_super_call = s.allow_super_call;
        const saved_new_target_allowed = s.new_target_allowed;
        const saved_in_constructor = s.in_constructor;
        const saved_last_anonymous_function_expr = s.last_anonymous_function_expr;
        const saved_last_function_child_index = s.last_function_child_index;

        try s.pushFunction(init_fd);
        s.emit_to_function_def = true;
        s.last_opcode_source_offset = null;
        s.scope_level = 0;
        s.is_strict = true;
        s.lex.is_strict_mode = true;
        s.allow_super = true;
        s.allow_super_call = false;
        s.new_target_allowed = true;
        s.in_constructor = false;
        s.last_anonymous_function_expr = false;
        errdefer {
            _ = s.popFunction();
            s.emit_to_function_def = saved_emit_to_function_def;
            s.last_opcode_source_offset = saved_last_opcode_source_offset;
            s.scope_level = saved_scope_level;
            s.is_strict = saved_is_strict;
            s.lex.is_strict_mode = saved_lex_is_strict;
            s.allow_super = saved_allow_super;
            s.allow_super_call = saved_allow_super_call;
            s.new_target_allowed = saved_new_target_allowed;
            s.in_constructor = saved_in_constructor;
            s.last_anonymous_function_expr = saved_last_anonymous_function_expr;
            s.last_function_child_index = saved_last_function_child_index;
        }

        try s.emitScopeGetVar(atom_this);
        if (is_private or is_computed) try s.emitScopeGetVar(atom_id);
        if (has_initializer) {
            try parseAssignExpr(s);
            if (s.last_anonymous_function_expr) {
                if (is_computed) {
                    try s.emitOp(opcode.op.set_name_computed);
                } else {
                    try s.emitOpAtom(opcode.op.set_name, atom_id);
                }
                s.last_anonymous_function_expr = false;
            }
        } else {
            try s.emitOp(opcode.op.undefined);
        }
        if (is_private) {
            try s.emitOp(opcode.op.define_private_field);
            try s.emitOp(opcode.op.drop);
        } else if (is_computed) {
            try s.emitOp(opcode.op.define_array_el);
            try s.emitOp(opcode.op.drop);
        } else {
            try s.emitOpAtom(opcode.op.define_field, atom_id);
            try s.emitOp(opcode.op.drop);
        }

        _ = s.popFunction();
        s.emit_to_function_def = saved_emit_to_function_def;
        s.last_opcode_source_offset = saved_last_opcode_source_offset;
        s.scope_level = saved_scope_level;
        s.is_strict = saved_is_strict;
        s.lex.is_strict_mode = saved_lex_is_strict;
        s.allow_super = saved_allow_super;
        s.allow_super_call = saved_allow_super_call;
        s.new_target_allowed = saved_new_target_allowed;
        s.in_constructor = saved_in_constructor;
        s.last_anonymous_function_expr = saved_last_anonymous_function_expr;
        s.last_function_child_index = saved_last_function_child_index;
    }

    fn emitPublicFieldNoInitializer(s: *State, atom_id: Atom) Error!void {
        if (s.is_static) {
            try emitStaticFieldInitializer(s, atom_id, false, false, false);
            return;
        }
        try emitInstanceFieldInitializer(s, atom_id, false, false);
    }

    fn emitInstanceFieldInitializer(
        s: *State,
        atom_id: Atom,
        has_initializer: bool,
        is_private: bool,
    ) Error!void {
        const child_index = try ensureClassFieldsInitFunction(s);
        const parent_fd = s.cur_func();
        if (child_index >= parent_fd.child_list.len) return Error.UnexpectedToken;
        const init_fd = parent_fd.child_list[child_index];

        const saved_emit_to_function_def = s.emit_to_function_def;
        const saved_last_opcode_source_offset = s.last_opcode_source_offset;
        const saved_scope_level = s.scope_level;
        const saved_is_strict = s.is_strict;
        const saved_lex_is_strict = s.lex.is_strict_mode;
        const saved_allow_super = s.allow_super;
        const saved_allow_super_call = s.allow_super_call;
        const saved_new_target_allowed = s.new_target_allowed;
        const saved_in_constructor = s.in_constructor;
        const saved_last_anonymous_function_expr = s.last_anonymous_function_expr;
        const saved_last_function_child_index = s.last_function_child_index;

        try s.pushFunction(init_fd);
        s.emit_to_function_def = true;
        s.last_opcode_source_offset = null;
        s.scope_level = 0;
        s.is_strict = true;
        s.lex.is_strict_mode = true;
        s.allow_super = true;
        s.allow_super_call = false;
        s.new_target_allowed = true;
        s.in_constructor = false;
        s.last_anonymous_function_expr = false;
        errdefer {
            _ = s.popFunction();
            s.emit_to_function_def = saved_emit_to_function_def;
            s.last_opcode_source_offset = saved_last_opcode_source_offset;
            s.scope_level = saved_scope_level;
            s.is_strict = saved_is_strict;
            s.lex.is_strict_mode = saved_lex_is_strict;
            s.allow_super = saved_allow_super;
            s.allow_super_call = saved_allow_super_call;
            s.new_target_allowed = saved_new_target_allowed;
            s.in_constructor = saved_in_constructor;
            s.last_anonymous_function_expr = saved_last_anonymous_function_expr;
            s.last_function_child_index = saved_last_function_child_index;
        }

        try s.emitOp(opcode.op.push_this);
        if (is_private) try s.emitScopeGetVar(atom_id);
        if (has_initializer) {
            try parseAssignExpr(s);
            if (s.last_anonymous_function_expr) {
                try s.emitOpAtom(opcode.op.set_name, atom_id);
                s.last_anonymous_function_expr = false;
            }
        } else {
            try s.emitOp(opcode.op.undefined);
        }
        if (is_private) {
            try s.emitOp(opcode.op.define_private_field);
        } else {
            try s.emitOpAtom(opcode.op.define_field, atom_id);
        }
        try s.emitOp(opcode.op.drop);

        _ = s.popFunction();
        s.emit_to_function_def = saved_emit_to_function_def;
        s.last_opcode_source_offset = saved_last_opcode_source_offset;
        s.scope_level = saved_scope_level;
        s.is_strict = saved_is_strict;
        s.lex.is_strict_mode = saved_lex_is_strict;
        s.allow_super = saved_allow_super;
        s.allow_super_call = saved_allow_super_call;
        s.new_target_allowed = saved_new_target_allowed;
        s.in_constructor = saved_in_constructor;
        s.last_anonymous_function_expr = saved_last_anonymous_function_expr;
        s.last_function_child_index = saved_last_function_child_index;
    }

    fn ensureClassFieldsInitFunction(s: *State) Error!usize {
        if (s.class_fields_init_child_index) |child_index| return child_index;
        const child_index = try createClassFieldsInitFunction(s, true);
        s.class_fields_init_child_index = @intCast(child_index);
        return child_index;
    }

    fn ensureClassStaticInitFunction(s: *State) Error!usize {
        if (s.class_static_init_child_index) |child_index| return child_index;
        const child_index = try createClassFieldsInitFunction(s, false);
        s.class_static_init_child_index = @intCast(child_index);
        return child_index;
    }

    fn createClassFieldsInitFunction(s: *State, include_instance_brand_prologue: bool) Error!usize {
        const parent_fd = s.cur_func();
        const child_fd = try s.function.memory.create(function_def_mod.FunctionDef);
        child_fd.* = function_def_mod.FunctionDef.init(s.function.memory, s.function.atoms, atom_class_fields_init);
        var child_moved = false;
        errdefer if (!child_moved) s.discardFunctionDef(child_fd);
        child_fd.atoms.replace(&child_fd.filename, parent_fd.filename);
        child_fd.atoms.replace(&child_fd.script_or_module, parent_fd.script_or_module);
        child_fd.line_num = @intCast(s.token.line_num);
        child_fd.col_num = @intCast(s.token.col_num);
        child_fd.parent = parent_fd;
        child_fd.parent_scope_level = parent_fd.scope_level;
        child_fd.is_strict_mode = true;
        child_fd.use_short_opcodes = parent_fd.use_short_opcodes;
        child_fd.func_type = .method;
        child_fd.func_kind = .normal;
        child_fd.has_prototype = false;
        child_fd.has_home_object = true;
        child_fd.need_home_object = true;
        child_fd.has_this_binding = true;
        child_fd.new_target_allowed = true;
        child_fd.super_allowed = true;
        child_fd.arguments_allowed = false;
        _ = child_fd.appendScope(-1) catch return error.OutOfMemory;
        if (include_instance_brand_prologue) {
            // QJS emits a dormant instance-brand prologue for every instance
            // initializer child and patches only the first opcode when a
            // private method or accessor appears. Static initialization brands
            // the constructor before invoking its separate child.
            var brand_prefix: [15]u8 = undefined;
            brand_prefix[0] = opcode.op.push_false;
            brand_prefix[1] = opcode.op.if_false;
            // Keep this as a phase-1 absolute target. Resolving home_object may
            // shrink the following scope opcode, and resolve_variables remaps
            // this target before resolve_labels picks the final short branch.
            std.mem.writeInt(u32, brand_prefix[2..6], brand_prefix.len, .little);
            brand_prefix[6] = opcode.op.push_this;
            brand_prefix[7] = opcode.op.scope_get_var;
            std.mem.writeInt(u32, brand_prefix[8..12], atom_module.ids.home_object, .little);
            std.mem.writeInt(u16, brand_prefix[12..14], 0, .little);
            brand_prefix[14] = opcode.op.add_brand;
            try child_fd.appendByteCode(&brand_prefix);
            try child_fd.appendAtomOperand(atom_module.ids.home_object);
        }
        const cpool_idx: u16 = @intCast(try parent_fd.appendCpool(JSValue.undefinedValue()));
        child_fd.parent_cpool_idx = cpool_idx;
        try parent_fd.addChild(child_fd);
        child_moved = true;
        const child_index: u16 = @intCast(parent_fd.child_list.len - 1);
        return child_index;
    }

    fn finishClassFieldsInitFunction(s: *State) Error!void {
        const child_index = s.class_fields_init_child_index orelse return;
        try finishClassInitFunction(s, child_index);
    }

    fn finishClassStaticInitFunction(s: *State) Error!void {
        const child_index = s.class_static_init_child_index orelse return;
        try finishClassInitFunction(s, child_index);
    }

    fn finishClassInitFunction(s: *State, child_index: usize) Error!void {
        const parent_fd = s.cur_func();
        if (child_index >= parent_fd.child_list.len) return Error.UnexpectedToken;
        const init_fd = parent_fd.child_list[child_index];
        const code = init_fd.byte_code;
        const needs_return = code.len == 0 or switch (code[code.len - 1]) {
            opcode.op.@"return", opcode.op.return_undef, opcode.op.return_async, opcode.op.throw => false,
            else => true,
        };
        if (!needs_return) return;
        try init_fd.appendByteCode(&.{opcode.op.return_undef});
    }

    fn registerClassPrivateBoundName(s: *State, atom_id: Atom) Error!void {
        for (s.class_private_bound_names.items) |existing| {
            if (existing == atom_id) return;
        }
        try appendRetainedAtom(&s.class_private_bound_names, s.function.memory.allocator, s.function.atoms, atom_id);
    }

    fn classPrivateNameIsBound(s: *State, atom_id: Atom) bool {
        for (s.class_private_bound_names.items) |existing| {
            if (existing == atom_id) return true;
        }
        return false;
    }

    fn classPrivateElementsConflict(
        existing: ClassPrivateElement,
        new_kind: ClassPrivateElementKind,
        new_is_static: bool,
    ) bool {
        const getter_setter_pair =
            (existing.kind == .getter and new_kind == .setter) or
            (existing.kind == .setter and new_kind == .getter);
        return !getter_setter_pair or existing.is_static != new_is_static;
    }

    fn privateNameAtom(s: *State, atom_id: Atom) Error!Atom {
        s.features.insert(.private_name);
        if (findClassPrivateBoundName(s, atom_id, 0)) |private_atom| {
            return s.function.atoms.dup(private_atom);
        }
        return newClassPrivateAtom(s, atom_id);
    }

    fn privateNameDeclarationAtom(s: *State, atom_id: Atom, bound_start: usize) Error!Atom {
        s.features.insert(.private_name);
        if (findClassPrivateBoundName(s, atom_id, bound_start)) |private_atom| {
            return s.function.atoms.dup(private_atom);
        }
        return newClassPrivateAtom(s, atom_id);
    }

    fn findClassPrivateBoundName(s: *State, atom_id: Atom, bound_start: usize) ?Atom {
        var i = s.class_private_bound_names.items.len;
        while (i > bound_start) {
            i -= 1;
            const private_atom = s.class_private_bound_names.items[i];
            if (privateAtomMatchesName(s, private_atom, atom_id)) return private_atom;
        }
        return null;
    }

    fn privateAtomMatchesName(s: *State, private_atom: Atom, atom_id: Atom) bool {
        const private_name = s.function.atoms.name(private_atom) orelse return false;
        const name = s.function.atoms.name(atom_id) orelse return false;
        if (std.mem.eql(u8, private_name, name)) return true;
        if (name.len > 0 and name[0] == '#') return false;
        return private_name.len == name.len + 1 and
            private_name[0] == '#' and
            std.mem.eql(u8, private_name[1..], name);
    }

    fn newClassPrivateAtom(s: *State, atom_id: Atom) Error!Atom {
        const name = s.function.atoms.name(atom_id) orelse return Error.InvalidIdentifier;
        if (name.len > 0 and name[0] == '#') {
            return s.function.atoms.newSymbol(name, .private);
        }
        const bytes = try s.function.memory.alloc(u8, name.len + 1);
        defer s.function.memory.free(u8, bytes);
        bytes[0] = '#';
        @memcpy(bytes[1..], name);
        return s.function.atoms.newSymbol(bytes, .private);
    }

    fn classComputedFieldTempAtom(s: *State) Error!Atom {
        const temp_name = try std.fmt.allocPrint(s.function.memory.allocator, "__class_computed_field_{d}", .{s.with_scope_id});
        defer s.function.memory.allocator.free(temp_name);
        s.with_scope_id += 1;
        return s.function.atoms.internString(temp_name);
    }

    fn parseClassElementFunction(s: *State, kind: ParseFunctionKind, source_start: usize) Error!void {
        const saved_parameter_properties = s.current_parameter_properties;
        if (kind == .class_constructor or kind == .derived_class_constructor) {
            s.current_parameter_properties = std.ArrayList(Atom).empty;
        } else {
            s.current_parameter_properties = null;
        }
        defer {
            if (kind == .class_constructor or kind == .derived_class_constructor) {
                if (s.current_parameter_properties) |*props| {
                    props.deinit(s.function.memory.allocator);
                }
            }
            s.current_parameter_properties = saved_parameter_properties;
        }

        const saved_pending_name = s.pending_function_name;
        const saved_pending_decl = s.pending_function_is_decl;
        const saved_in_async = s.in_async;
        const saved_in_generator = s.in_generator;
        const saved_is_strict = s.is_strict;
        const saved_allow_super = s.allow_super;
        const saved_top_level_children = s.top_level_functions_as_children;
        const saved_parsing_method_params = s.parsing_method_params;
        s.pending_function_name = null;
        s.pending_function_is_decl = false;
        s.in_async = kind == .async or kind == .async_generator;
        s.in_generator = kind == .generator or kind == .async_generator;
        s.is_strict = true;
        s.allow_super = true;
        s.top_level_functions_as_children = true;
        s.parsing_method_params = true;
        defer {
            s.pending_function_name = saved_pending_name;
            s.pending_function_is_decl = saved_pending_decl;
            s.in_async = saved_in_async;
            s.in_generator = saved_in_generator;
            s.is_strict = saved_is_strict;
            s.allow_super = saved_allow_super;
            s.top_level_functions_as_children = saved_top_level_children;
            s.parsing_method_params = saved_parsing_method_params;
        }
        try parseFunctionParamsAndBody(s, kind, source_start);
    }

    fn parseClassComputedName(s: *State) Error!void {
        try s.expectToken('[');
        try parseAssignExpr2(s, ParseFlags.default);
        try s.emitOp(opcode.op.to_propkey);
        try expectPunct(s, ']');
    }

    fn emitStaticClassComputedElement(s: *State, kind: ParseFunctionKind, source_start: usize) Error!void {
        try s.emitOp(opcode.op.swap);
        try parseClassComputedName(s);
        if (s.peekKind() == '(') {
            try parseClassElementFunction(s, kind, source_start);
            try s.emitOpU8(opcode.op.define_method_computed, 0);
            try s.emitOp(opcode.op.swap);
            return;
        }
        if (kind != .method) return Error.UnexpectedToken;

        const key_atom = try classComputedFieldTempAtom(s);
        defer s.function.atoms.free(key_atom);
        _ = try s.defineVar(key_atom, .const_);
        try s.emitScopePutVarInit(key_atom);
        try s.emitOp(opcode.op.swap);

        if (s.peekKind() == '=') {
            try s.advance();
            try emitStaticFieldInitializer(s, key_atom, false, true, true);
        } else {
            try emitStaticFieldInitializer(s, key_atom, false, true, false);
        }
        _ = try s.expectSemicolon();
    }

    fn emitInstanceComputedPublicFieldInitializer(s: *State, key_atom: Atom, has_initializer: bool) Error!void {
        const child_index = try ensureClassFieldsInitFunction(s);
        const parent_fd = s.cur_func();
        if (child_index >= parent_fd.child_list.len) return Error.UnexpectedToken;
        const init_fd = parent_fd.child_list[child_index];

        const saved_emit_to_function_def = s.emit_to_function_def;
        const saved_last_opcode_source_offset = s.last_opcode_source_offset;
        const saved_scope_level = s.scope_level;
        const saved_is_strict = s.is_strict;
        const saved_lex_is_strict = s.lex.is_strict_mode;
        const saved_allow_super = s.allow_super;
        const saved_allow_super_call = s.allow_super_call;
        const saved_new_target_allowed = s.new_target_allowed;
        const saved_in_constructor = s.in_constructor;
        const saved_last_anonymous_function_expr = s.last_anonymous_function_expr;
        const saved_last_function_child_index = s.last_function_child_index;

        try s.pushFunction(init_fd);
        s.emit_to_function_def = true;
        s.last_opcode_source_offset = null;
        s.scope_level = 0;
        s.is_strict = true;
        s.lex.is_strict_mode = true;
        s.allow_super = true;
        s.allow_super_call = false;
        s.new_target_allowed = true;
        s.in_constructor = false;
        s.last_anonymous_function_expr = false;
        errdefer {
            _ = s.popFunction();
            s.emit_to_function_def = saved_emit_to_function_def;
            s.last_opcode_source_offset = saved_last_opcode_source_offset;
            s.scope_level = saved_scope_level;
            s.is_strict = saved_is_strict;
            s.lex.is_strict_mode = saved_lex_is_strict;
            s.allow_super = saved_allow_super;
            s.allow_super_call = saved_allow_super_call;
            s.new_target_allowed = saved_new_target_allowed;
            s.in_constructor = saved_in_constructor;
            s.last_anonymous_function_expr = saved_last_anonymous_function_expr;
            s.last_function_child_index = saved_last_function_child_index;
        }

        try s.emitOp(opcode.op.push_this);
        try s.emitScopeGetVar(key_atom);
        if (has_initializer) {
            try parseAssignExpr(s);
            if (s.last_anonymous_function_expr) {
                try s.emitOp(opcode.op.set_name_computed);
                s.last_anonymous_function_expr = false;
            }
        } else {
            try s.emitOp(opcode.op.undefined);
        }
        try s.emitOp(opcode.op.define_array_el);
        try s.emitOp(opcode.op.drop);

        _ = s.popFunction();
        s.emit_to_function_def = saved_emit_to_function_def;
        s.last_opcode_source_offset = saved_last_opcode_source_offset;
        s.scope_level = saved_scope_level;
        s.is_strict = saved_is_strict;
        s.lex.is_strict_mode = saved_lex_is_strict;
        s.allow_super = saved_allow_super;
        s.allow_super_call = saved_allow_super_call;
        s.new_target_allowed = saved_new_target_allowed;
        s.in_constructor = saved_in_constructor;
        s.last_anonymous_function_expr = saved_last_anonymous_function_expr;
        s.last_function_child_index = saved_last_function_child_index;
    }

    fn emitInstanceClassComputedElement(s: *State, kind: ParseFunctionKind, source_start: usize) Error!void {
        try parseClassComputedName(s);
        if (s.peekKind() == '(') {
            try parseClassElementFunction(s, kind, source_start);
            try s.emitOpU8(opcode.op.define_method_computed, 0);
            return;
        }
        if (kind != .method) return Error.UnexpectedToken;

        const key_atom = try classComputedFieldTempAtom(s);
        defer s.function.atoms.free(key_atom);
        _ = try s.defineVar(key_atom, .const_);
        try s.emitScopePutVarInit(key_atom);

        if (s.peekKind() == '=') {
            try s.advance();
            try emitInstanceComputedPublicFieldInitializer(s, key_atom, true);
        } else {
            try emitInstanceComputedPublicFieldInitializer(s, key_atom, false);
        }
        _ = try s.expectSemicolon();
    }

    fn emitClassComputedMethod(s: *State, kind: ParseFunctionKind, define_flags: u8, source_start: usize) Error!void {
        if (s.is_static) try s.emitOp(opcode.op.swap);
        try parseClassComputedName(s);
        if (s.peekKind() != '(') return Error.UnexpectedToken;
        try parseClassElementFunction(s, kind, source_start);
        try s.emitOpU8(opcode.op.define_method_computed, define_flags);
        if (s.is_static) try s.emitOp(opcode.op.swap);
    }

    fn emitClassStaticBlock(s: *State) Error!void {
        const child_index = try ensureClassStaticInitFunction(s);
        const parent_fd = s.cur_func();
        if (child_index >= parent_fd.child_list.len) return Error.UnexpectedToken;
        const init_fd = parent_fd.child_list[child_index];

        const saved_emit_to_function_def = s.emit_to_function_def;
        const saved_last_opcode_source_offset = s.last_opcode_source_offset;
        const saved_scope_level = s.scope_level;
        const saved_pending_name = s.pending_function_name;
        const saved_pending_decl = s.pending_function_is_decl;
        const saved_is_strict = s.is_strict;
        const saved_lex_is_strict = s.lex.is_strict_mode;
        const saved_static_block = s.in_class_static_block;
        const saved_is_static = s.is_static;
        const saved_allow_super = s.allow_super;
        const saved_allow_super_call = s.allow_super_call;
        const saved_new_target_allowed = s.new_target_allowed;
        const saved_in_constructor = s.in_constructor;
        const saved_last_anonymous_function_expr = s.last_anonymous_function_expr;
        const saved_last_function_child_index = s.last_function_child_index;

        try s.pushFunction(init_fd);
        s.emit_to_function_def = true;
        s.last_opcode_source_offset = null;
        s.scope_level = 0;
        s.pending_function_name = null;
        s.pending_function_is_decl = false;
        s.is_strict = true;
        s.lex.is_strict_mode = true;
        s.in_class_static_block = true;
        s.is_static = false;
        s.allow_super = true;
        s.allow_super_call = false;
        s.new_target_allowed = true;
        s.in_constructor = false;
        s.last_anonymous_function_expr = false;
        errdefer {
            _ = s.popFunction();
            s.emit_to_function_def = saved_emit_to_function_def;
            s.last_opcode_source_offset = saved_last_opcode_source_offset;
            s.scope_level = saved_scope_level;
            s.pending_function_name = saved_pending_name;
            s.pending_function_is_decl = saved_pending_decl;
            s.is_strict = saved_is_strict;
            s.lex.is_strict_mode = saved_lex_is_strict;
            s.in_class_static_block = saved_static_block;
            s.is_static = saved_is_static;
            s.allow_super = saved_allow_super;
            s.allow_super_call = saved_allow_super_call;
            s.new_target_allowed = saved_new_target_allowed;
            s.in_constructor = saved_in_constructor;
            s.last_anonymous_function_expr = saved_last_anonymous_function_expr;
            s.last_function_child_index = saved_last_function_child_index;
        }

        try parseFunctionParamsAndBody(s, .class_static_block, null);
        s.last_anonymous_function_expr = false;
        try s.emitScopeGetVar(atom_this);
        try s.emitOp(opcode.op.swap);
        try s.emitOpU16(opcode.op.call_method, 0);
        try s.emitOp(opcode.op.drop);

        _ = s.popFunction();
        s.emit_to_function_def = saved_emit_to_function_def;
        s.last_opcode_source_offset = saved_last_opcode_source_offset;
        s.scope_level = saved_scope_level;
        s.pending_function_name = saved_pending_name;
        s.pending_function_is_decl = saved_pending_decl;
        s.is_strict = saved_is_strict;
        s.lex.is_strict_mode = saved_lex_is_strict;
        s.in_class_static_block = saved_static_block;
        s.is_static = saved_is_static;
        s.allow_super = saved_allow_super;
        s.allow_super_call = saved_allow_super_call;
        s.new_target_allowed = saved_new_target_allowed;
        s.in_constructor = saved_in_constructor;
        s.last_anonymous_function_expr = saved_last_anonymous_function_expr;
        s.last_function_child_index = saved_last_function_child_index;
    }

    /// Parse class body
    /// Mirrors `js_parse_class_body` in quickjs.c
    fn parseClassBodyAfterOpen(s: *State) Error!void {
        while (s.peekKind() != '}' and s.peekKind() != tok.TOK_EOF) {
            if (s.peekKind() == ';') {
                try s.advance();
                continue;
            }
            try parseClassElement(s);
        }

        try s.expectToken('}');
    }

    fn collectClassPrivateBoundNames(s: *State, bound_start: usize) Error!void {
        if (s.peekKind() != @as(tok.TokenKind, @intCast('{'))) return;

        const saved_pos = s.lex.pos;
        const saved_line = s.lex.line;
        const saved_col = s.lex.col;
        const saved_got_lf = s.lex.got_lf;
        const saved_mark_pos = s.lex.mark_pos;
        const saved_mark_line = s.lex.mark_line;
        const saved_mark_col = s.lex.mark_col;
        defer {
            s.lex.pos = saved_pos;
            s.lex.line = saved_line;
            s.lex.col = saved_col;
            s.lex.got_lf = saved_got_lf;
            s.lex.mark_pos = saved_mark_pos;
            s.lex.mark_line = saved_mark_line;
            s.lex.mark_col = saved_mark_col;
        }

        var brace_depth: usize = 1;
        var paren_depth: usize = 0;
        var bracket_depth: usize = 0;
        var prev_kind: tok.TokenKind = 0;
        while (brace_depth > 0) {
            var scan_token = try s.lex.next();
            defer s.lex.freeToken(&scan_token);
            const k = scan_token.val;
            if (k == tok.TOK_EOF) break;

            if (k == tok.TOK_PRIVATE_NAME and
                brace_depth == 1 and
                paren_depth == 0 and
                bracket_depth == 0 and
                prev_kind != @as(tok.TokenKind, @intCast('.')) and
                prev_kind != tok.TOK_QUESTION_MARK_DOT)
            {
                const private_atom = try privateNameDeclarationAtom(s, scan_token.payload.ident.atom, bound_start);
                defer s.function.atoms.free(private_atom);
                try registerClassPrivateBoundName(s, private_atom);
            }

            switch (k) {
                @as(tok.TokenKind, @intCast('/')), tok.TOK_DIV_ASSIGN => {
                    if (try skipRegexpInPredeclareScan(s, prev_kind)) {
                        prev_kind = tok.TOK_REGEXP;
                        continue;
                    }
                },
                tok.TOK_TEMPLATE => {
                    try skipTemplateInPredeclareScan(s, scan_token);
                    prev_kind = tok.TOK_TEMPLATE;
                    continue;
                },
                @as(tok.TokenKind, @intCast('{')) => brace_depth += 1,
                @as(tok.TokenKind, @intCast('}')) => {
                    brace_depth -= 1;
                    if (brace_depth == 0) break;
                },
                @as(tok.TokenKind, @intCast('(')) => paren_depth += 1,
                @as(tok.TokenKind, @intCast(')')) => {
                    if (paren_depth > 0) paren_depth -= 1;
                },
                @as(tok.TokenKind, @intCast('[')) => bracket_depth += 1,
                @as(tok.TokenKind, @intCast(']')) => {
                    if (bracket_depth > 0) bracket_depth -= 1;
                },
                else => {},
            }
            prev_kind = k;
        }
    }

    fn emitClassLocalInitFromClassStack(s: *State, local_idx: u16) Error!void {
        try s.emitOp(opcode.op.swap);
        try s.emitOp(opcode.op.dup);
        try s.emitOpU16(opcode.op.put_loc_check_init, local_idx);
        try s.emitOp(opcode.op.swap);
    }

    fn emitClassFieldsInitValue(s: *State, class_fields_init_child_index: ?u16) Error!void {
        if (class_fields_init_child_index) |child_index| {
            const parent_fd = s.cur_func();
            if (child_index >= parent_fd.child_list.len) return Error.UnexpectedToken;
            const cpool_idx = parent_fd.child_list[child_index].parent_cpool_idx;
            if (cpool_idx < 0) return Error.UnexpectedToken;
            try s.emitFClosure(@intCast(cpool_idx));
            try s.emitOp(opcode.op.set_home_object);
        } else {
            try s.emitOp(opcode.op.undefined);
        }
    }

    fn emitClassFieldsInitLocalInitFromClassStack(s: *State, fields_init_local_idx: u16, class_fields_init_child_index: ?u16) Error!void {
        try emitClassFieldsInitValue(s, class_fields_init_child_index);
        try s.emitOpU16(opcode.op.put_loc_check_init, fields_init_local_idx);
    }

    fn emitClassStaticInitCall(s: *State, class_static_init_child_index: ?u16) Error!void {
        const child_index = class_static_init_child_index orelse return;
        const parent_fd = s.cur_func();
        if (child_index >= parent_fd.child_list.len) return Error.UnexpectedToken;
        const cpool_idx = parent_fd.child_list[child_index].parent_cpool_idx;
        if (cpool_idx < 0) return Error.UnexpectedToken;

        // The class constructor is the sole stack value here. Duplicate it as
        // the call receiver/home object, then invoke the lexical static
        // initializer immediately. Mirrors quickjs.c:25735-25744.
        try s.emitOp(opcode.op.dup);
        try s.emitFClosure(@intCast(cpool_idx));
        try s.emitOp(opcode.op.set_home_object);
        try s.emitOpU16(opcode.op.call_method, 0);
        try s.emitOp(opcode.op.drop);
    }

    /// The class stack is `[constructor, prototype]`. Private instance members
    /// use the prototype as their home object, so pre-create its brand before
    /// user code can make the prototype non-extensible. Static members brand
    /// the constructor itself. Both sequences preserve the class stack.
    fn emitClassPrivateBrands(s: *State, instance_needed: bool, static_needed: bool) Error!void {
        if (instance_needed) {
            try s.emitOp(opcode.op.dup);
            try s.emitOp(opcode.op.null);
            try s.emitOp(opcode.op.swap);
            try s.emitOp(opcode.op.add_brand);
        }
        if (static_needed) {
            try s.emitOp(opcode.op.swap);
            try s.emitOp(opcode.op.dup);
            try s.emitOp(opcode.op.dup);
            try s.emitOp(opcode.op.add_brand);
            try s.emitOp(opcode.op.swap);
        }
    }

    fn emitClassDefineOperands(s: *State, cpool_idx: u16) Error!void {
        try s.emitOpU32(opcode.op.push_const, cpool_idx);
    }

    /// Parse class declaration or expression
    /// Mirrors `js_parse_class` in quickjs.c:24667
    fn parseClass(s: *State, is_decl: bool) Error!void {
        s.features.insert(.class_);
        const class_source_start = s.currentTokenStartOffset();
        try s.expectToken(tok.TOK_CLASS);
        if (is_decl) s.last_class_decl_atom = null;

        // Parse class name (required for declarations, optional for expressions)
        var class_name: ?Atom = null;
        if (is_decl) {
            const name_atom = classNameAtom(s) orelse return Error.UnexpectedToken;
            class_name = name_atom;
            s.last_class_decl_atom = name_atom;
            try s.advance();
        } else {
            if (classNameAtom(s)) |name_atom| {
                class_name = name_atom;
                try s.advance();
            }
        }

        var class_decl_local_idx: ?u16 = null;
        var class_fields_init_local_idx: ?u16 = null;
        var top_level_class_binding = false;

        // Parse heritage (extends clause)
        const saved_has_extends = s.class_has_extends;
        const saved_in_class = s.in_class;
        const saved_is_static = s.is_static;
        const saved_is_strict = s.is_strict;
        const saved_lex_is_strict = s.lex.is_strict_mode;
        const saved_static_name_seen = s.class_static_name_seen;
        const saved_class_constructor_cpool_idx = s.class_constructor_cpool_idx;
        const saved_class_private_elements_len = s.class_private_elements.items.len;
        const saved_class_private_bound_names_len = s.class_private_bound_names.items.len;
        const saved_class_fields_init_child_index = s.class_fields_init_child_index;
        const saved_class_static_init_child_index = s.class_static_init_child_index;
        const saved_class_instance_private_brand_needed = s.class_instance_private_brand_needed;
        const saved_class_static_private_brand_needed = s.class_static_private_brand_needed;
        var class_outer_scope_pushed = false;
        var class_private_scope_pushed = false;
        var class_name_local_idx: ?u16 = null;
        errdefer {
            if (class_private_scope_pushed) s.popScopeIdentity();
            if (class_outer_scope_pushed) s.popScopeIdentity();
            s.truncateClassPrivateElements(saved_class_private_elements_len);
            s.truncateClassPrivateBoundNames(saved_class_private_bound_names_len);
            s.class_fields_init_child_index = saved_class_fields_init_child_index;
            s.class_static_init_child_index = saved_class_static_init_child_index;
            s.class_instance_private_brand_needed = saved_class_instance_private_brand_needed;
            s.class_static_private_brand_needed = saved_class_static_private_brand_needed;
            s.is_static = saved_is_static;
            s.is_strict = saved_is_strict;
            s.lex.is_strict_mode = saved_lex_is_strict;
        }

        s.in_class = true;
        s.is_static = false;
        s.is_strict = true;
        // The whole ClassTail — heritage, computed keys, method/getter/setter
        // bodies, and field initializers — is strict code for the LEXER as
        // well: legacy octal literals (08, 0777) and octal/\8 string escapes
        // are SyntaxErrors. Mirrors js_parse_class quickjs.c:25289-25291
        // ("classes are parsed and executed in strict mode",
        // fd->js_mode |= JS_MODE_STRICT) gating the tokenizer octal checks
        // (quickjs.c:23021 number literals, 22530-22536 string escapes).
        s.lex.is_strict_mode = true;
        s.class_has_extends = s.peekKind() == tok.TOK_EXTENDS;
        s.class_static_name_seen = false;
        s.class_constructor_cpool_idx = null;
        s.class_fields_init_child_index = null;
        s.class_static_init_child_index = null;
        s.class_instance_private_brand_needed = false;
        s.class_static_private_brand_needed = false;
        // QuickJS creates the class-name scope even for an anonymous class.
        // The binding itself is appended only after heritage parsing, but the
        // completed scope chain still makes a named class TDZ-visible there.
        try s.pushScope();
        class_outer_scope_pushed = true;
        try parseClassHeritage(s);
        if (class_name) |class_atom| {
            class_name_local_idx = switch (try s.defineVar(class_atom, .const_)) {
                .local => |idx| idx,
                else => unreachable,
            };
        }
        try collectClassPrivateBoundNames(s, saved_class_private_bound_names_len);
        try s.expectToken('{');
        try s.pushScope();
        class_private_scope_pushed = true;
        class_fields_init_local_idx = switch (try s.defineVar(atom_class_fields_init, .const_)) {
            .local => |idx| idx,
            else => unreachable,
        };
        s.cur_func().vars[class_fields_init_local_idx.?].tdz_emitted_at_decl = true;

        // Parse class body. Constructor parsing records a child FunctionDef;
        // class definition bytecode references that child through push_const /
        // define_class instead of the normal fclosure expression path.
        const class_emit_start = s.currentCodeLen();
        const class_atom_start = s.currentAtomOperandLen();
        try parseClassBodyAfterOpen(s);
        const class_source_end = s.last_token_end_offset;
        try finishClassFieldsInitFunction(s);
        try finishClassStaticInitFunction(s);
        const runtime_code = s.currentCode()[class_emit_start..];
        const saved_runtime_code = try s.function.memory.alloc(u8, runtime_code.len);
        defer s.function.memory.free(u8, saved_runtime_code);
        @memcpy(saved_runtime_code, runtime_code);
        const runtime_atoms = s.currentAtomOperands()[class_atom_start..];
        const saved_runtime_atoms = try s.function.memory.alloc(Atom, runtime_atoms.len);
        defer s.function.memory.free(Atom, saved_runtime_atoms);
        for (runtime_atoms, 0..) |atom_id, idx| {
            saved_runtime_atoms[idx] = s.function.atoms.dup(atom_id);
        }
        defer for (saved_runtime_atoms) |atom_id| s.function.atoms.free(atom_id);
        try s.truncateCode(class_emit_start);
        try s.truncateAtomOperands(class_atom_start);
        const default_constructor_name = class_name orelse if (is_decl) s.function.name else atom_module.ids.empty_string;
        const class_constructor_cpool_idx = s.class_constructor_cpool_idx orelse
            try appendDefaultClassConstructor(s, default_constructor_name);
        const class_private_scope_level = s.scope_level;
        if (class_private_scope_pushed) {
            s.popScopeIdentity();
            class_private_scope_pushed = false;
        }
        const class_outer_scope_level = s.scope_level;
        if (class_outer_scope_pushed) {
            s.popScopeIdentity();
            class_outer_scope_pushed = false;
        }
        try s.setChildFunctionSourceByCpoolIndex(class_constructor_cpool_idx, class_source_start, class_source_end);
        const class_has_extends = s.class_has_extends;
        const parsed_class_fields_init_child_index = s.class_fields_init_child_index;
        const parsed_class_static_init_child_index = s.class_static_init_child_index;
        const class_instance_private_brand_needed = s.class_instance_private_brand_needed;
        const class_static_private_brand_needed = s.class_static_private_brand_needed;

        s.in_class = saved_in_class;
        s.is_static = saved_is_static;
        s.is_strict = saved_is_strict;
        s.lex.is_strict_mode = saved_lex_is_strict;
        s.class_has_extends = saved_has_extends;
        const class_static_name_seen = s.class_static_name_seen;
        s.class_static_name_seen = saved_static_name_seen;
        s.class_constructor_cpool_idx = saved_class_constructor_cpool_idx;
        s.truncateClassPrivateElements(saved_class_private_elements_len);
        s.truncateClassPrivateBoundNames(saved_class_private_bound_names_len);
        s.class_fields_init_child_index = saved_class_fields_init_child_index;
        s.class_static_init_child_index = saved_class_static_init_child_index;
        s.class_instance_private_brand_needed = saved_class_instance_private_brand_needed;
        s.class_static_private_brand_needed = saved_class_static_private_brand_needed;

        const name_atom = class_name orelse s.function.name;
        if (is_decl) {
            // QuickJS appends the outer class-statement LET only after the
            // complete ClassTail (including computed keys and the synthetic
            // fields initializer) has been parsed.  The inner CONST above is
            // the binding visible from heritage/body code; final scope-entry
            // lowering still establishes the outer LET's TDZ before runtime
            // evaluation starts.
            const declaration_atom = class_name orelse return Error.UnexpectedToken;
            if (s.top_level_lexical_as_module_ref and s.atProgramBodyScope() and hasKnownBinding(s, declaration_atom)) {
                return Error.UnexpectedToken;
            }
            switch (try s.defineVar(declaration_atom, .let_)) {
                .local => |idx| class_decl_local_idx = idx,
                .global => top_level_class_binding = true,
                .argument => unreachable,
            }
            if (!class_has_extends) try s.emitOp(opcode.op.undefined);
            if (class_fields_init_local_idx) |fields_idx| try s.emitOpU16(opcode.op.set_loc_uninitialized, fields_idx);
            try emitClassDefineOperands(s, class_constructor_cpool_idx);
            try s.emitOpAtomU8(opcode.op.define_class, name_atom, if (class_has_extends) 1 else 0);
            if (class_name_local_idx) |local_idx| try emitClassLocalInitFromClassStack(s, local_idx);
            try emitClassPrivateBrands(s, class_instance_private_brand_needed, class_static_private_brand_needed);
            try s.appendMovedCodeWithAtoms(saved_runtime_code, saved_runtime_atoms, class_emit_start);
            const fields_idx = class_fields_init_local_idx orelse return Error.UnexpectedToken;
            try emitClassFieldsInitLocalInitFromClassStack(s, fields_idx, parsed_class_fields_init_child_index);
            try s.emitOp(opcode.op.drop);
            try emitClassStaticInitCall(s, parsed_class_static_init_child_index);
            // Parsing restores the outer scope identity before emitting this
            // deferred class runtime sequence so the declaration binding is
            // defined in its containing scope. Keep the runtime exits at the
            // canonical QuickJS position: after the private/name locals are
            // initialized, before the outer class-statement binding is stored.
            try s.emitLeaveScope(class_private_scope_level);
            try s.emitLeaveScope(class_outer_scope_level);
            if (class_decl_local_idx) |local_idx| {
                try s.emitOpU16(opcode.op.set_loc, local_idx);
            } else if (!top_level_class_binding) {
                return Error.UnexpectedToken;
            }
            if (top_level_class_binding) {
                try s.emitScopePutVarInit(name_atom);
            } else {
                try s.emitOp(opcode.op.drop);
            }
            if (s.namespace_export) {
                if (s.current_namespace_atom) |ns_atom| {
                    if (class_name) |class_atom| {
                        try s.emitScopeGetVar(ns_atom);
                        try s.emitScopeGetVar(class_atom);
                        try s.emitOpAtom(opcode.op.put_field, class_atom);
                    }
                }
            }
        } else {
            const expr_name_atom = class_name orelse s.pending_function_name orelse atom_module.ids.empty_string;
            if (!class_has_extends) try s.emitOp(opcode.op.undefined);
            if (class_fields_init_local_idx) |fields_idx| try s.emitOpU16(opcode.op.set_loc_uninitialized, fields_idx);
            try emitClassDefineOperands(s, class_constructor_cpool_idx);
            try s.emitOpAtomU8(opcode.op.define_class, expr_name_atom, if (class_has_extends) 1 else 0);
            if (class_fields_init_local_idx) |fields_idx| try emitClassFieldsInitLocalInitFromClassStack(s, fields_idx, parsed_class_fields_init_child_index);
            if (class_name_local_idx) |local_idx| try emitClassLocalInitFromClassStack(s, local_idx);
            try emitClassPrivateBrands(s, class_instance_private_brand_needed, class_static_private_brand_needed);
            try s.appendMovedCodeWithAtoms(saved_runtime_code, saved_runtime_atoms, class_emit_start);
            try s.emitOp(opcode.op.drop);
            try emitClassStaticInitCall(s, parsed_class_static_init_child_index);
            // Like QuickJS js_parse_class, leave both inner class scopes only
            // after their deferred initialization and static runtime work.
            try s.emitLeaveScope(class_private_scope_level);
            try s.emitLeaveScope(class_outer_scope_level);
            s.last_anonymous_function_expr = class_name == null and s.pending_function_name == null and !class_static_name_seen;
        }
    }

    fn appendClassFieldInitCallToFunctionDef(
        fd: *function_def_mod.FunctionDef,
        this_idx: u16,
    ) Error!void {
        var code: [18]u8 = undefined;
        code[0] = opcode.op.scope_get_var;
        std.mem.writeInt(u32, code[1..5], atom_class_fields_init, .little);
        std.mem.writeInt(u16, code[5..7], @intCast(fd.scope_level), .little);
        code[7] = opcode.op.dup;
        code[8] = opcode.op.if_false8;
        code[9] = 8;
        code[10] = opcode.op.get_loc_check;
        std.mem.writeInt(u16, code[11..13], this_idx, .little);
        code[13] = opcode.op.swap;
        code[14] = opcode.op.call_method;
        std.mem.writeInt(u16, code[15..17], 0, .little);
        code[17] = opcode.op.drop;
        try fd.appendAtomOperand(atom_class_fields_init);
        try fd.appendByteCode(&code);
    }

    fn appendDefaultClassConstructor(s: *State, name_atom: Atom) Error!u16 {
        const parent_fd = s.cur_func();
        const child_fd = try s.function.memory.create(function_def_mod.FunctionDef);
        child_fd.* = function_def_mod.FunctionDef.init(s.function.memory, s.function.atoms, name_atom);
        var child_moved = false;
        errdefer if (!child_moved) s.discardFunctionDef(child_fd);
        child_fd.atoms.replace(&child_fd.filename, parent_fd.filename);
        child_fd.atoms.replace(&child_fd.script_or_module, parent_fd.script_or_module);
        child_fd.line_num = @intCast(s.token.line_num);
        child_fd.col_num = @intCast(s.token.col_num);
        child_fd.parent = parent_fd;
        child_fd.parent_scope_level = parent_fd.scope_level;
        child_fd.is_strict_mode = true;
        child_fd.use_short_opcodes = parent_fd.use_short_opcodes;
        child_fd.func_type = if (s.class_has_extends) .derived_class_constructor else .class_constructor;
        child_fd.func_kind = .normal;
        child_fd.has_arguments_binding = s.class_has_extends;
        child_fd.arguments_allowed = s.class_has_extends;
        child_fd.has_this_binding = true;
        child_fd.has_home_object = true;
        // zjs currently also uses this flag for constructibility; keep it set
        // until those two contracts are split.
        child_fd.has_prototype = true;
        child_fd.is_derived_class_constructor = s.class_has_extends;
        child_fd.new_target_allowed = true;
        child_fd.super_allowed = true;
        child_fd.super_call_allowed = s.class_has_extends;
        _ = child_fd.appendScope(-1) catch return error.OutOfMemory;
        const body_scope = child_fd.appendScope(0) catch return error.OutOfMemory;
        child_fd.body_scope = body_scope;
        child_fd.scope_level = body_scope;
        // Pinned qjs default base constructors enter through OP_check_ctor.
        // Default derived constructors use OP_init_ctor below, whose handler
        // performs the new.target gate while initializing derived state.
        if (!s.class_has_extends) {
            try child_fd.appendByteCode(&.{opcode.op.check_ctor});
        }
        var body_marker: [3]u8 = undefined;
        body_marker[0] = opcode.op.enter_scope;
        std.mem.writeInt(u16, body_marker[1..3], @intCast(body_scope), .little);
        try child_fd.appendByteCode(&body_marker);
        const this_idx_i32 = child_fd.ensureThisBinding() catch return error.OutOfMemory;
        if (this_idx_i32 < 0 or this_idx_i32 > std.math.maxInt(u16)) return Error.UnexpectedToken;
        const this_idx: u16 = @intCast(this_idx_i32);
        if (s.class_has_extends) {
            try child_fd.appendByteCode(&.{
                opcode.op.init_ctor,
                opcode.op.put_loc_check_init,
                @truncate(this_idx),
                @truncate(this_idx >> 8),
            });
            try appendClassFieldInitCallToFunctionDef(child_fd, this_idx);
            try child_fd.appendByteCode(&.{
                opcode.op.get_loc_check,
                @truncate(this_idx),
                @truncate(this_idx >> 8),
                opcode.op.@"return",
            });
        } else {
            try appendClassFieldInitCallToFunctionDef(child_fd, this_idx);
            try child_fd.appendByteCode(&.{opcode.op.return_undef});
        }
        const cpool_idx: u16 = @intCast(try parent_fd.appendCpool(JSValue.undefinedValue()));
        child_fd.parent_cpool_idx = cpool_idx;
        try parent_fd.addChild(child_fd);
        child_moved = true;
        return cpool_idx;
    }

    // =====================================================================
    // Module parsing
    // =====================================================================

    const atom_default: Atom = 22; // "default"
    const atom_star_default: Atom = 127; // "*default*"
    const atom_star: Atom = 128; // "*"

    const ModuleImportSpec = struct {
        import_name: Atom,
        local_name: Atom,
    };

    const ModuleExportSpec = struct {
        export_name: Atom,
        import_name: Atom,
        import_name_is_string: bool = false,
    };

    /// Parse import statement
    /// Mirrors `js_parse_import` in quickjs.c:31312
    fn parseImport(s: *State) Error!void {
        try s.advance();
        var default_local_name: ?Atom = null;

        // Side-effect import: import 'module'
        if (s.peekKind() == tok.TOK_STRING) {
            const request_index = try addModuleRequestFromCurrentString(s);
            try s.advance();
            if (s.peekKind() == tok.TOK_WITH) {
                try parseWithClause(s, request_index);
            }
            _ = try s.expectSemicolon();
            return;
        }

        // Default import: import x from 'module'
        if (s.peekKind() == tok.TOK_IDENT) {
            const local_name = s.token.payload.ident.atom;
            try validateModuleImportBindingName(s, local_name);
            default_local_name = local_name;
            try s.advance();

            if (s.peekKind() != ',') {
                const request_index = try parseFromClause(s);
                try addModuleImportBinding(s, request_index, atom_default, local_name, false);
                // parseFromClause handles with clause, so expect semicolon after
                _ = try s.expectSemicolon();
                return;
            }
            try s.advance();
        }

        // Namespace import: import * as ns from 'module'
        if (s.peekKind() == '*') {
            try s.advance();
            // Expect 'as'
            if (!s.isIdent("as")) {
                return Error.UnexpectedToken;
            }
            try s.advance();
            // Expect namespace identifier
            if (s.peekKind() != tok.TOK_IDENT) {
                return Error.UnexpectedToken;
            }
            const local_name = s.token.payload.ident.atom;
            try validateModuleImportBindingName(s, local_name);
            try s.advance();
            const request_index = try parseFromClause(s);
            if (default_local_name) |default_name| {
                try addModuleImportBinding(s, request_index, atom_default, default_name, false);
            }
            try addModuleImportBinding(s, request_index, atom_star, local_name, true);
            _ = try s.expectSemicolon();
            return;
        }

        // Named imports: import { x, y as z } from 'module'
        if (s.peekKind() == '{') {
            var imports = std.ArrayList(ModuleImportSpec).empty;
            defer freeModuleImportSpecs(s, &imports);
            try s.advance();
            while (s.peekKind() != '}' and s.peekKind() != tok.TOK_EOF) {
                // Import name (identifier or string)
                if (!isModuleNameToken(s.peekKind())) {
                    return Error.UnexpectedToken;
                }
                const import_name_was_string = s.peekKind() == tok.TOK_STRING;
                const import_name_atom = try moduleImportNameAtom(s);
                const import_name_owned = s.function.atoms.dup(import_name_atom);
                if (import_name_was_string) s.function.atoms.free(import_name_atom);
                try s.advance();

                // Optional 'as' for renaming
                var local_name_atom: Atom = undefined;
                if (s.isIdent("as")) {
                    try s.advance();
                    if (s.peekKind() != tok.TOK_IDENT) {
                        s.function.atoms.free(import_name_owned);
                        return Error.UnexpectedToken;
                    }
                    local_name_atom = s.token.payload.ident.atom;
                    try validateModuleImportBindingName(s, local_name_atom);
                    try s.advance();
                } else if (import_name_was_string) {
                    s.function.atoms.free(import_name_owned);
                    return Error.UnexpectedToken;
                } else {
                    local_name_atom = import_name_atom;
                    try validateModuleImportBindingName(s, local_name_atom);
                }

                imports.append(s.function.memory.allocator, .{
                    .import_name = import_name_owned,
                    .local_name = s.function.atoms.dup(local_name_atom),
                }) catch {
                    s.function.atoms.free(import_name_owned);
                    return Error.OutOfMemory;
                };

                if (s.peekKind() != ',') break;
                try s.advance();
            }
            try s.expectToken('}');
            const request_index = try parseFromClause(s);
            if (default_local_name) |default_name| {
                try addModuleImportBinding(s, request_index, atom_default, default_name, false);
            }
            for (imports.items) |entry| {
                try addModuleImportBinding(s, request_index, entry.import_name, entry.local_name, false);
            }
            _ = try s.expectSemicolon();
            return;
        }

        return Error.UnexpectedToken;
    }

    fn validateModuleImportBindingName(s: *State, atom_id: Atom) Error!void {
        if (isInvalidStrictFunctionBindingName(s, atom_id)) {
            return Error.UnexpectedToken;
        }
    }

    fn moduleHasExportName(record: *const bytecode_module.Record, export_name: Atom) bool {
        for (record.exports) |entry| {
            if (entry.export_name == export_name) return true;
        }
        for (record.indirect_exports) |entry| {
            if (entry.export_name == export_name) return true;
        }
        for (record.star_exports) |entry| {
            if (entry.export_name != atom_star and entry.export_name == export_name) return true;
        }
        return false;
    }

    fn addModuleExportName(s: *State, export_name: Atom, local_name: Atom) Error!void {
        const record = s.function.ensureModule();
        if (moduleHasExportName(record, export_name)) return Error.UnexpectedToken;
        record.addExport(export_name, local_name) catch return error.OutOfMemory;
    }

    pub fn validateModuleLocalExports(s: *State) Error!void {
        const record = s.function.module_record orelse return;
        for (record.exports) |entry| {
            if (!hasKnownBinding(s, entry.local_name)) return Error.UnexpectedToken;
        }
    }

    fn addModuleImportAttribute(s: *State, request_index: u32, key: Atom, value: Atom) Error!void {
        const record = s.function.ensureModule();
        for (record.import_attributes) |entry| {
            if (entry.request_index == request_index and entry.key == key) return Error.UnexpectedToken;
        }
        record.addImportAttribute(request_index, key, value) catch return error.OutOfMemory;
    }

    fn addModuleImportBinding(
        s: *State,
        request_index: u32,
        import_name: Atom,
        local_name: Atom,
        is_namespace: bool,
    ) Error!void {
        if (hasKnownBinding(s, local_name)) return Error.UnexpectedToken;
        if (s.cur_func().closure_var.len > std.math.maxInt(u16)) return error.BytecodeOverflow;
        const raw_var_idx = try s.cur_func().addClosureVar(.{
            // qjs add_import: namespace imports own a MODULE_DECL slot that
            // linking fills with the namespace cell; named/default imports are
            // MODULE_IMPORT aliases of an exported binding.
            .closure_type = if (is_namespace) .module_decl else .module_import,
            .is_lexical = true,
            .is_const = true,
            .var_kind = .normal,
            .var_idx = @intCast(s.cur_func().closure_var.len),
            .var_name = local_name,
        });
        if (raw_var_idx < 0 or raw_var_idx > std.math.maxInt(u16)) return error.BytecodeOverflow;
        const record = s.function.ensureModule();
        record.addImport(
            request_index,
            import_name,
            local_name,
            @intCast(raw_var_idx),
            is_namespace,
        ) catch return error.OutOfMemory;
    }

    fn ensureModuleDefaultExportBinding(s: *State) Error!void {
        switch (try s.defineVar(atom_star_default, .let_)) {
            .global => {},
            .local, .argument => return Error.UnexpectedToken,
        }
    }

    fn addModuleIndirectExport(
        s: *State,
        request_index: u32,
        export_name: Atom,
        import_name: Atom,
        is_namespace: bool,
    ) Error!void {
        const record = s.function.ensureModule();
        if (moduleHasExportName(record, export_name)) return Error.UnexpectedToken;
        record.addIndirectExport(request_index, export_name, import_name, is_namespace) catch return error.OutOfMemory;
    }

    fn addModuleStarExport(s: *State, request_index: u32, export_name: Atom) Error!void {
        const record = s.function.ensureModule();
        if (export_name != atom_star and moduleHasExportName(record, export_name)) return Error.UnexpectedToken;
        record.addStarExport(request_index, export_name) catch return error.OutOfMemory;
    }

    fn addModuleRequestFromCurrentString(s: *State) Error!u32 {
        const module_name = try moduleStringAtom(s);
        defer s.function.atoms.free(module_name);
        const record = s.function.ensureModule();
        return record.addRequest(module_name) catch return error.OutOfMemory;
    }

    fn moduleStringAtom(s: *State) Error!Atom {
        if (s.peekKind() != tok.TOK_STRING) return Error.UnexpectedToken;
        return s.function.atoms.internString(s.token.payload.str.bytes) catch return error.OutOfMemory;
    }

    fn isModuleNameToken(kind: tok.TokenKind) bool {
        return kind == tok.TOK_IDENT or kind == tok.TOK_STRING or tok.isKeyword(kind);
    }

    fn moduleImportNameAtom(s: *State) Error!Atom {
        return switch (s.peekKind()) {
            tok.TOK_IDENT => s.token.payload.ident.atom,
            tok.TOK_NULL...tok.TOK_AWAIT => tok.keywordAtom(s.peekKind()),
            else => try moduleStringAtom(s),
        };
    }

    fn isWellFormedModuleString(bytes: []const u8) bool {
        var index: usize = 0;
        while (index < bytes.len) {
            const width = std.unicode.utf8ByteSequenceLength(bytes[index]) catch return false;
            if (index + width > bytes.len) return false;
            if (width == 3 and bytes[index] == 0xED and bytes[index + 1] >= 0xA0 and bytes[index + 1] <= 0xBF) {
                if (bytes[index + 2] & 0xC0 == 0x80) return false;
            }
            _ = std.unicode.utf8Decode(bytes[index .. index + width]) catch |err| switch (err) {
                error.Utf8EncodesSurrogateHalf => return false,
                else => return false,
            };
            index += width;
        }
        return true;
    }

    fn freeModuleImportSpecs(s: *State, imports: *std.ArrayList(ModuleImportSpec)) void {
        for (imports.items) |entry| {
            s.function.atoms.free(entry.import_name);
            s.function.atoms.free(entry.local_name);
        }
        imports.deinit(s.function.memory.allocator);
    }

    fn freeModuleExportSpecs(s: *State, exports: *std.ArrayList(ModuleExportSpec)) void {
        for (exports.items) |entry| {
            s.function.atoms.free(entry.export_name);
            s.function.atoms.free(entry.import_name);
        }
        exports.deinit(s.function.memory.allocator);
    }

    /// Parse export statement
    /// Mirrors `js_parse_export` in quickjs.c:31090
    fn parseExport(s: *State) Error!void {
        try s.advance();

        const next_tok = s.peekKind();

        // export default
        if (next_tok == tok.TOK_DEFAULT) {
            try s.advance();
            if (s.peekKind() == tok.TOK_CLASS) {
                if (exportDefaultClassName(s)) |name_atom| {
                    try parseClass(s, true);
                    try addModuleExportName(s, atom_default, name_atom);
                } else {
                    const saved_pending_name = s.pending_function_name;
                    const saved_pending_decl = s.pending_function_is_decl;
                    s.pending_function_name = atom_default;
                    s.pending_function_is_decl = false;
                    defer {
                        s.pending_function_name = saved_pending_name;
                        s.pending_function_is_decl = saved_pending_decl;
                    }
                    try parseClass(s, false);
                    try ensureModuleDefaultExportBinding(s);
                    try s.emitScopePutVarInit(atom_star_default);
                    try addModuleExportName(s, atom_default, atom_star_default);
                }
                return;
            } else if (s.peekKind() == tok.TOK_FUNCTION) {
                if (exportDefaultFunctionName(s)) |name_atom| {
                    const source_start = s.currentTokenStartOffset();
                    try parseFunctionDecl(s, .normal, source_start);
                    try addModuleExportName(s, atom_default, name_atom);
                } else {
                    const source_start = s.currentTokenStartOffset();
                    try parseAnonymousDefaultFunctionDecl(s, .normal, source_start);
                    try addModuleExportName(s, atom_default, atom_star_default);
                }
                return;
            } else if (s.peekKind() == tok.TOK_IDENT and s.isIdent("async") and s.peekNextKind() == tok.TOK_FUNCTION) {
                const source_start = s.currentTokenStartOffset();
                try s.advance();
                if (exportDefaultFunctionName(s)) |name_atom| {
                    try parseFunctionDecl(s, .async, source_start);
                    try addModuleExportName(s, atom_default, name_atom);
                } else {
                    try parseAnonymousDefaultFunctionDecl(s, .async, source_start);
                    try addModuleExportName(s, atom_default, atom_star_default);
                }
                return;
            } else {
                try parseAssignExpr(s);
                try emitAnonymousDefaultName(s, atom_default);
                try ensureModuleDefaultExportBinding(s);
                try s.emitScopePutVarInit(atom_star_default);
                try addModuleExportName(s, atom_default, atom_star_default);
            }
            _ = try s.expectSemicolon();
            return;
        }

        // export { ... }
        if (next_tok == '{') {
            var export_specs = std.ArrayList(ModuleExportSpec).empty;
            defer freeModuleExportSpecs(s, &export_specs);
            try s.advance();
            while (s.peekKind() != '}' and s.peekKind() != tok.TOK_EOF) {
                // Export name (identifier or string)
                if (!isModuleNameToken(s.peekKind())) {
                    return Error.UnexpectedToken;
                }
                const local_name_atom = try moduleImportNameAtom(s);
                const local_name_was_string = s.peekKind() == tok.TOK_STRING;
                if (local_name_was_string and !isWellFormedModuleString(s.token.payload.str.bytes)) {
                    s.function.atoms.free(local_name_atom);
                    return Error.UnexpectedToken;
                }
                var export_name_atom = local_name_atom;
                var export_name_was_string = local_name_was_string;
                try s.advance();

                // Optional 'as' for renaming
                if (s.isIdent("as")) {
                    try s.advance();
                    if (!isModuleNameToken(s.peekKind())) {
                        if (local_name_was_string) s.function.atoms.free(local_name_atom);
                        return Error.UnexpectedToken;
                    }
                    export_name_was_string = s.peekKind() == tok.TOK_STRING;
                    if (export_name_was_string and !isWellFormedModuleString(s.token.payload.str.bytes)) {
                        if (local_name_was_string) s.function.atoms.free(local_name_atom);
                        return Error.UnexpectedToken;
                    }
                    export_name_atom = try moduleImportNameAtom(s);
                    try s.advance();
                }

                export_specs.append(s.function.memory.allocator, .{
                    .export_name = s.function.atoms.dup(export_name_atom),
                    .import_name = s.function.atoms.dup(local_name_atom),
                    .import_name_is_string = local_name_was_string,
                }) catch {
                    if (local_name_was_string) s.function.atoms.free(local_name_atom);
                    if (export_name_was_string and export_name_atom != local_name_atom) s.function.atoms.free(export_name_atom);
                    return Error.OutOfMemory;
                };
                if (local_name_was_string) s.function.atoms.free(local_name_atom);
                if (export_name_was_string and export_name_atom != local_name_atom) s.function.atoms.free(export_name_atom);

                if (s.peekKind() != ',') break;
                try s.advance();
            }
            try s.expectToken('}');

            // Optional from clause for re-export
            if (s.isIdent("from")) {
                const request_index = try parseFromClause(s);
                for (export_specs.items) |entry| {
                    try addModuleIndirectExport(s, request_index, entry.export_name, entry.import_name, false);
                }
            } else {
                for (export_specs.items) |entry| {
                    if (entry.import_name_is_string) return Error.UnexpectedToken;
                    try addModuleExportName(s, entry.export_name, entry.import_name);
                }
            }
            _ = try s.expectSemicolon();
            return;
        }

        // export * from 'module' or export * as ns from 'module'
        if (next_tok == '*') {
            try s.advance();
            // Optional 'as' for namespace re-export
            var export_name = atom_star;
            var export_name_was_string = false;
            var is_namespace = false;
            if (s.isIdent("as")) {
                is_namespace = true;
                try s.advance();
                if (!isModuleNameToken(s.peekKind())) {
                    return Error.UnexpectedToken;
                }
                export_name_was_string = s.peekKind() == tok.TOK_STRING;
                if (export_name_was_string and !isWellFormedModuleString(s.token.payload.str.bytes)) return Error.UnexpectedToken;
                export_name = try moduleImportNameAtom(s);
                try s.advance();
            }
            defer if (export_name_was_string) s.function.atoms.free(export_name);
            const request_index = try parseFromClause(s);
            if (is_namespace) {
                try addModuleIndirectExport(s, request_index, export_name, atom_star, true);
            } else {
                try addModuleStarExport(s, request_index, export_name);
            }
            _ = try s.expectSemicolon();
            return;
        }

        // export var/let/const
        if (next_tok == tok.TOK_VAR or next_tok == tok.TOK_LET or next_tok == tok.TOK_CONST) {
            const var_tok = next_tok;
            try s.advance();
            try parseVar(s, var_tok, true, ParseFlags.default);
            _ = try s.expectSemicolon();
            return;
        }

        // export function
        if (next_tok == tok.TOK_FUNCTION) {
            // Check for async function
            const is_async = s.isIdent("async");
            const source_start = s.currentTokenStartOffset();
            if (is_async) {
                try s.advance();
            }
            const func_kind: ParseFunctionKind = if (is_async) .async else .normal;
            const name_atom = exportDefaultFunctionName(s);
            try parseFunctionDecl(s, func_kind, source_start);
            if (name_atom) |name| try addModuleExportName(s, name, name);
            return;
        }

        // export class
        if (next_tok == tok.TOK_CLASS) {
            try parseClass(s, true);
            if (s.last_class_decl_atom) |name_atom| try addModuleExportName(s, name_atom, name_atom);
            return;
        }

        // export async function
        if (next_tok == tok.TOK_IDENT and s.isIdent("async")) {
            // Check if next token is function
            if (s.peekNextKind() == tok.TOK_FUNCTION) {
                const source_start = s.currentTokenStartOffset();
                try s.advance(); // consume async
                const func_kind: ParseFunctionKind = .async;
                const name_atom = exportDefaultFunctionName(s);
                try parseFunctionDecl(s, func_kind, source_start);
                if (name_atom) |name| try addModuleExportName(s, name, name);
                return;
            }
        }

        return Error.UnexpectedToken;
    }

    fn exportDefaultFunctionName(s: *State) ?Atom {
        const saved_pos = s.lex.pos;
        const saved_line = s.lex.line;
        const saved_col = s.lex.col;
        const saved_mark_pos = s.lex.mark_pos;
        const saved_mark_line = s.lex.mark_line;
        const saved_mark_col = s.lex.mark_col;
        var first = s.lex.next() catch return null;
        defer {
            s.lex.freeToken(&first);
            s.lex.pos = saved_pos;
            s.lex.line = saved_line;
            s.lex.col = saved_col;
            s.lex.mark_pos = saved_mark_pos;
            s.lex.mark_line = saved_mark_line;
            s.lex.mark_col = saved_mark_col;
        }
        if (first.val == @as(tok.TokenKind, @intCast('*'))) {
            var second = s.lex.next() catch return null;
            defer s.lex.freeToken(&second);
            if (second.val == tok.TOK_IDENT) return second.payload.ident.atom;
            return null;
        }
        if (first.val == tok.TOK_IDENT) return first.payload.ident.atom;
        return null;
    }

    fn exportDefaultClassName(s: *State) ?Atom {
        const saved_pos = s.lex.pos;
        const saved_line = s.lex.line;
        const saved_col = s.lex.col;
        const saved_mark_pos = s.lex.mark_pos;
        const saved_mark_line = s.lex.mark_line;
        const saved_mark_col = s.lex.mark_col;
        var name = s.lex.next() catch return null;
        defer {
            s.lex.freeToken(&name);
            s.lex.pos = saved_pos;
            s.lex.line = saved_line;
            s.lex.col = saved_col;
            s.lex.mark_pos = saved_mark_pos;
            s.lex.mark_line = saved_mark_line;
            s.lex.mark_col = saved_mark_col;
        }
        return if (name.val == tok.TOK_IDENT) name.payload.ident.atom else null;
    }

    /// Parse from clause: from 'module'
    /// Mirrors `js_parse_from_clause` in quickjs.c:31039
    fn parseFromClause(s: *State) Error!u32 {
        // Expect 'from' keyword
        if (!s.isIdent("from")) {
            return Error.UnexpectedToken;
        }
        try s.advance();

        // Expect string literal for module name
        if (s.peekKind() != tok.TOK_STRING) {
            return Error.UnexpectedToken;
        }
        const request_index = try addModuleRequestFromCurrentString(s);
        try s.advance();

        // Optional with clause for import attributes
        if (s.peekKind() == tok.TOK_WITH) {
            try parseWithClause(s, request_index);
        }
        return request_index;
    }

    /// Parse with clause for import attributes
    /// Mirrors `js_parse_with_clause` in quickjs.c:30950
    fn parseWithClause(s: *State, request_index: u32) Error!void {
        try s.advance();
        try s.expectToken('{');

        while (s.peekKind() != '}' and s.peekKind() != tok.TOK_EOF) {
            // Key (identifier or string)
            if (s.peekKind() != tok.TOK_IDENT and s.peekKind() != tok.TOK_STRING) {
                return Error.UnexpectedToken;
            }
            const key_atom = if (s.peekKind() == tok.TOK_IDENT)
                s.token.payload.ident.atom
            else
                try moduleStringAtom(s);
            const key_is_string = s.peekKind() == tok.TOK_STRING;
            defer if (key_is_string) s.function.atoms.free(key_atom);
            try s.advance();

            try s.expectToken(':');

            // JSValue (string)
            if (s.peekKind() != tok.TOK_STRING) {
                return Error.UnexpectedToken;
            }
            const value_atom = try moduleStringAtom(s);
            defer s.function.atoms.free(value_atom);
            try addModuleImportAttribute(s, request_index, key_atom, value_atom);
            try s.advance();

            if (s.peekKind() != ',') break;
            try s.advance();
        }

        try s.expectToken('}');
    }

    fn ensureParameterArgumentsLocals(fd: *function_def_mod.FunctionDef) Error!void {
        if (fd.func_type == .arrow or fd.func_type == .class_static_init) return;
        _ = fd.ensureArgumentsBinding() catch return error.OutOfMemory;
        fd.ensureArgumentsArgumentBinding() catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidScope => return error.UnexpectedToken,
        };
    }

    pub const ParseState = State;
    pub const Feature = FeatureImpl;
};
pub const compile_entry = struct {
    const std = @import("std");

    const atom = @import("core/atom.zig");
    const JSRuntime = @import("core/runtime.zig").JSRuntime;
    const JSValue = @import("core/value.zig").JSValue;
    const bytecode = @import("bytecode.zig");
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

    const SourceKindImpl = lexer_mod.SourceKindImpl;
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

        pub fn deinit(self: *ModuleArtifactImpl, runtime: *JSRuntime) void {
            self.record.deinit();
            JSValue.functionBytecode(&self.function_bytecode.header).free(runtime);
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
        runtime: *JSRuntime,
        artifact: RootArtifactImpl = .none,
        mode: ModeImpl,
        parse_path: CompilePathImpl = .normal,
        features: std.EnumSet(FeatureImpl) = .initEmpty(),
        syntax_error: ?diagnostics_mod.SyntaxError = null,
        direct_eval: bool = false,

        pub fn deinit(self: *ResultImpl) void {
            if (self.syntax_error) |*err| err.deinit();
            switch (self.artifact) {
                .none => {},
                .function_bytecode => |fb| JSValue.functionBytecode(&fb.header).free(self.runtime),
                .module => |owned| {
                    var artifact = owned;
                    artifact.deinit(self.runtime);
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
        source_kind: SourceKindImpl = .auto,
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

            const retained = rt.atoms.dup(seed.var_name);
            state.class_private_bound_names.append(rt.memory.allocator, retained) catch |err| {
                rt.atoms.free(retained);
                return err;
            };
            restored_any = true;
        }
        if (restored_any) state.in_class = true;
    }

    pub fn compile(compile_context: bytecode.CompileContext, source: []const u8, options: OptionsImpl) !ResultImpl {
        const rt = compile_context.realm.runtime;
        var arena = std.heap.ArenaAllocator.init(rt.memory.persistent_allocator);
        var arena_owned = true;
        errdefer if (arena_owned) arena.deinit();

        const original_allocator = rt.memory.allocator;
        rt.memory.allocator = arena.allocator();
        defer rt.memory.allocator = original_allocator;

        const filename_atom = try rt.internAtom(options.filename);
        defer rt.atoms.free(filename_atom);
        // QuickJS learns directive strictness while parsing the directive
        // prologue. Only an explicit host option is known before tokenization;
        // comments and source substrings are never a second strictness source.
        const effective_strict = options.strict;

        var function = bytecode.Bytecode.init(&rt.memory, &rt.atoms, filename_atom);
        var function_owned = true;
        errdefer if (function_owned) function.deinit(rt);
        if (options.script_or_module) |script_or_module| {
            function.atoms.replace(&function.script_or_module, script_or_module);
        }
        function.line_num = 1;
        function.col_num = 1;
        function.flags.is_strict = options.mode == .module or effective_strict;
        function.flags.is_global_var = switch (options.mode) {
            .script, .module => true,
            .eval_direct, .eval_indirect => !effective_strict,
        };
        function.flags.is_module = options.mode == .module;
        function.flags.is_direct_or_indirect_eval = options.mode == .eval_direct or options.mode == .eval_indirect;

        if (lexer_mod.shouldStrip(options.source_kind, options.filename)) {
            if (try lexer_mod.findUnsupportedTypeScriptSyntax(rt.memory.allocator, source)) |unsupported| {
                var result = ResultImpl{
                    .runtime = rt,
                    .mode = options.mode,
                    .direct_eval = options.mode == .eval_direct,
                };
                result.syntax_error = try diagnostics_mod.SyntaxError.create(
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
                function.deinit(rt);
                function_owned = false;
                arena.deinit();
                arena_owned = false;
                return result;
            }
        }

        var features = std.EnumSet(FeatureImpl).initEmpty();

        const canonical_root = compileQjsProgram(rt, filename_atom, source, options, compile_context, &function, &features) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                var result = ResultImpl{
                    .runtime = rt,
                    .mode = options.mode,
                    .direct_eval = options.mode == .eval_direct,
                };
                try setFallbackSyntaxError(&result, rt, filename_atom, source, @errorName(err));
                function.deinit(rt);
                function_owned = false;
                arena.deinit();
                arena_owned = false;
                return result;
            },
        };
        var canonical_root_owned = true;
        errdefer if (canonical_root_owned) JSValue.functionBytecode(&canonical_root.header).free(rt);

        var result = ResultImpl{
            .runtime = rt,
            .mode = options.mode,
            .direct_eval = options.mode == .eval_direct,
            .features = features,
        };
        if (options.mode == .module) {
            const record = function.module_record orelse return error.InvalidBytecode;
            function.module_record = null;
            result.artifact = .{ .module = .{
                .function_bytecode = canonical_root,
                .record = record,
            } };
        } else {
            result.artifact = .{ .function_bytecode = canonical_root };
        }
        canonical_root_owned = false;
        function.deinit(rt);
        function_owned = false;
        arena.deinit();
        arena_owned = false;
        result.parse_path = .normal;
        return result;
    }

    fn compileQjsProgram(
        rt: *JSRuntime,
        filename_atom: atom.Atom,
        source: []const u8,
        options: OptionsImpl,
        compile_context: bytecode.CompileContext,
        function: *bytecode.Bytecode,
        features: *std.EnumSet(FeatureImpl),
    ) !*bytecode.FunctionBytecode {
        const effective_strict = options.strict;
        var lex = lexer_mod.Lexer.init(rt.memory.allocator, &rt.atoms, source);
        defer lex.deinit();
        lex.is_strict_mode = options.mode == .module or effective_strict;
        lex.is_module = options.mode == .module;
        if (lexer_mod.shouldStrip(options.source_kind, options.filename)) {
            try lex.enableTypeScript();
        }
        var state = try parser_core.ParseState.initCanonicalRootWithRuntime(rt, &lex, function);
        defer state.deinit(rt);
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
        state.top_level_functions_as_children = true;
        // Script top-level let/const become global VarRef cells (qjs JS_CLOSURE_GLOBAL_DECL):
        // single-storage in ctx.lexicals, shared into frame.var_refs by pointer.
        state.top_level_lexical_as_global_ref = options.mode == .script;
        state.eval_global_var_bindings = (options.eval_global_var_bindings or options.mode == .eval_indirect) and
            !((options.mode == .eval_direct or options.mode == .eval_indirect) and effective_strict);
        state.eval_in_parameter_initializer = options.eval_in_parameter_initializer;
        state.new_target_allowed = options.eval_allows_new_target;
        state.function_def.new_target_allowed = options.eval_allows_new_target;
        state.allow_super_call = options.eval_allows_super_call;
        state.function_def.super_call_allowed = options.eval_allows_super_call;
        state.allow_super = options.eval_allows_super_property;
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

        try parser_core.parseDirectives(&state);

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
        function.flags.is_strict = parsed_strict;
        function.flags.is_global_var = state.function_def.is_global_var;

        const decl_mask = parser_core.DeclMask{ .func = true, .func_with_label = true, .other = true };
        try parser_core.parseProgramStatements(&state, decl_mask);
        if (options.mode == .module) {
            try parser_core.validateModuleLocalExports(&state);
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
            const code = function.code;
            const atoms = function.atom_operands;
            const needs_return = parser_impl.hasJumpToCurrentEnd(code, atoms) or
                parser_impl.functionNeedsImplicitReturn(code, atoms);
            if (needs_return) try state.emitReturnUndefined();
        }

        // Parsing intentionally redirects the operation allocator to the
        // short-lived arena. Finalization may use that facade for scratch
        // lists, but the published FB must be built under the runtime's stable
        // allocation policy. FunctionDef buffers, module metadata, and FB
        // storage use MemoryAccount ownership directly; this scoped switch
        // additionally prevents a future finalizer helper from accidentally
        // retaining an arena-backed allocation. Restore it before State.deinit
        // so parser scratch still unwinds under the allocator that created it.
        const parse_allocator = rt.memory.allocator;
        rt.memory.allocator = compile_context.artifactAllocator();
        defer rt.memory.allocator = parse_allocator;
        const root_slice = if (options.mode == .module) blk: {
            const record = if (function.module_record) |*owned| owned else return error.InvalidBytecode;
            break :blk try bytecode.pipeline.finalize.createModuleFunctionBytecode(
                &state.function_def,
                record,
                compile_context,
            );
        } else try bytecode.pipeline.finalize.createFunctionBytecode(&state.function_def, compile_context);
        features.* = state.features;
        _ = filename_atom;
        return &root_slice[0];
    }

    fn setFallbackSyntaxError(
        result: *ResultImpl,
        rt: *JSRuntime,
        filename_atom: atom.Atom,
        source: []const u8,
        message: []const u8,
    ) !void {
        var lex = lexer_mod.Lexer.init(rt.memory.allocator, &rt.atoms, source);
        var pos = diagnostics_mod.Position{ .line = 1, .column = 1, .offset = 0 };
        var previous_token_kind: ?token_mod.TokenKind = null;
        while (true) {
            var tok = nextFallbackSyntaxToken(&lex, previous_token_kind) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => {
                    result.syntax_error = try diagnostics_mod.SyntaxError.create(&rt.memory, &rt.atoms, filename_atom, pos, @errorName(err));
                    result.parse_path = .syntax_error_guard;
                    return;
                },
            };
            pos = .{ .line = lex.line, .column = lex.col, .offset = lex.pos };
            if (tok.val == token_mod.TOK_EOF) {
                lex.freeToken(&tok);
                break;
            }
            previous_token_kind = tok.val;
            lex.freeToken(&tok);
        }
        result.syntax_error = try diagnostics_mod.SyntaxError.create(&rt.memory, &rt.atoms, filename_atom, pos, message);
        result.parse_path = .syntax_error_guard;
    }

    fn nextFallbackSyntaxToken(lex: *lexer_mod.Lexer, previous_token_kind: ?token_mod.TokenKind) lexer_mod.Error!token_mod.Token {
        var fallback_token = try lex.next();
        errdefer lex.freeToken(&fallback_token);

        if ((fallback_token.val == @as(token_mod.TokenKind, @intCast('/')) or fallback_token.val == token_mod.TOK_DIV_ASSIGN) and
            fallbackSlashStartsRegexp(previous_token_kind))
        {
            const slash_offset = lex.mark_pos;
            const regexp_token = try lex.rescanRegexp(slash_offset);
            lex.freeToken(&fallback_token);
            fallback_token = regexp_token;
        }

        return fallback_token;
    }

    fn fallbackSlashStartsRegexp(previous_token_kind: ?token_mod.TokenKind) bool {
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
            token_mod.TOK_ARROW,
            token_mod.TOK_LT,
            token_mod.TOK_LTE,
            token_mod.TOK_GT,
            token_mod.TOK_GTE,
            token_mod.TOK_EQ,
            token_mod.TOK_STRICT_EQ,
            token_mod.TOK_NEQ,
            token_mod.TOK_STRICT_NEQ,
            token_mod.TOK_SHL,
            token_mod.TOK_SAR,
            token_mod.TOK_SHR,
            token_mod.TOK_LAND,
            token_mod.TOK_LOR,
            token_mod.TOK_POW,
            token_mod.TOK_DOUBLE_QUESTION_MARK,
            token_mod.TOK_QUESTION_MARK_DOT,
            token_mod.TOK_MUL_ASSIGN,
            token_mod.TOK_DIV_ASSIGN,
            token_mod.TOK_MOD_ASSIGN,
            token_mod.TOK_PLUS_ASSIGN,
            token_mod.TOK_MINUS_ASSIGN,
            token_mod.TOK_SHL_ASSIGN,
            token_mod.TOK_SAR_ASSIGN,
            token_mod.TOK_SHR_ASSIGN,
            token_mod.TOK_AND_ASSIGN,
            token_mod.TOK_XOR_ASSIGN,
            token_mod.TOK_OR_ASSIGN,
            token_mod.TOK_POW_ASSIGN,
            token_mod.TOK_LAND_ASSIGN,
            token_mod.TOK_LOR_ASSIGN,
            token_mod.TOK_DOUBLE_QUESTION_MARK_ASSIGN,
            token_mod.TOK_RETURN,
            token_mod.TOK_CASE,
            token_mod.TOK_THROW,
            token_mod.TOK_DELETE,
            token_mod.TOK_VOID,
            token_mod.TOK_TYPEOF,
            token_mod.TOK_NEW,
            token_mod.TOK_IN,
            token_mod.TOK_INSTANCEOF,
            token_mod.TOK_DO,
            token_mod.TOK_ELSE,
            token_mod.TOK_YIELD,
            token_mod.TOK_AWAIT,
            => true,
            else => false,
        };
    }

    pub const SourceKind = SourceKindImpl;
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
pub const SourceKind = compile_entry.SourceKind;
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

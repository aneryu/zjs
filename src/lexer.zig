//! QuickJS-aligned lexer namespace, parameterized by the token representation.
pub fn namespace(comptime token: type) type {
    return struct {
        //! QuickJS-aligned lexer.
        //!
        //! Mirrors `next_token`, `js_parse_string`, `js_parse_template_part`,
        //! `js_parse_regexp`, and the helpers around them in
        //! QuickJS `quickjs.c:21794..23200`.
        //!
        const std = @import("std");
        const atom_module = @import("core/atom.zig");
        const simple_token = @import("simple_token.zig");
        const unicode = @import("libs/unicode.zig");
        const number_format = @import("libs/number_format.zig");
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

            pub fn init(
                allocator: std.mem.Allocator,
                atoms: *AtomTable,
                source: []const u8,
            ) LexerImpl {
                return .{
                    .allocator = allocator,
                    .atoms = atoms,
                    .source = source,
                };
            }

            pub fn deinit(self: *LexerImpl) void {
                _ = self;
            }

            /// TypeScript generic closers. The parser asks for one `>` while the
            /// current token is `>>`, `>>>`, `>=`, `>>=`, or `>>>=`: re-cut the
            /// token to the single leading `>` and park the cursor right after
            /// it, so the remaining bytes are lexed again as their own token.
            /// Mirrors the TypeScript scanner's `reScanGreaterToken`.
            pub fn splitGreaterThan(self: *LexerImpl, tok: *t.Token) void {
                std.debug.assert(tok.len >= 2 and tok.ptr[0] == '>');
                self.splitLeadingByte(tok, '>');
            }

            /// Same re-cut for `<<` and `<<=` when a type argument list or type
            /// parameter list starts with the first `<` (`f<<T>() => T>(x)`).
            pub fn splitLessThan(self: *LexerImpl, tok: *t.Token) void {
                std.debug.assert(tok.len >= 2 and tok.ptr[0] == '<');
                self.splitLeadingByte(tok, '<');
            }

            fn splitLeadingByte(self: *LexerImpl, tok: *t.Token, byte: u8) void {
                const start = @intFromPtr(tok.ptr) - @intFromPtr(self.source.ptr);
                self.pos = start + 1;
                self.line = tok.line_num;
                self.col = tok.col_num + 1;
                tok.val = @enumFromInt(byte);
                tok.len = 1;
                tok.payload = .none;
            }

            inline fn releaseTokenPayload(self: *LexerImpl, tok: *t.Token) void {
                switch (tok.payload) {
                    .str => |s| {
                        if (s.bytes.len > 0 and !self.isSourceSlice(s.bytes)) self.allocator.free(s.bytes);
                        if (s.raw_bytes.len > 0 and !self.isSourceSlice(s.raw_bytes)) self.allocator.free(s.raw_bytes);
                    },
                    // qjs free_token releases every identifier/private-name atom
                    // here (quickjs.c:22190-22208). TGC S3-c: the token's id is
                    // an ordinary borrow now -- the compile scope roots it and
                    // the sweep retires it, so dropping the payload is all that
                    // is left.
                    else => {},
                }
            }

            pub fn freeToken(self: *LexerImpl, tok: *t.Token) void {
                self.releaseTokenPayload(tok);
                tok.payload = .none;
            }

            /// QuickJS `next_token` releases the current JSToken and overwrites it
            /// in one operation. Keep the same hot-path lifetime here: clearing a
            /// tagged union writes its full backing storage, which is unnecessary
            /// immediately before `nextInto` replaces every field. On lexer error
            /// the old payload has already been released, so invalidate it before
            /// returning to keep State.deinit safe.
            pub fn nextIntoReplacing(self: *LexerImpl, out: *t.Token) Error!void {
                self.releaseTokenPayload(out);
                self.nextInto(out) catch |err| {
                    out.payload = .none;
                    return err;
                };
            }

            /// Retain every owned token payload for a speculative parser snapshot.
            /// The returned token is an independent owner and must eventually be
            /// passed to `freeToken` or transferred back into parser state.
            pub fn dupToken(self: *LexerImpl, tok: t.Token) Error!t.Token {
                var copy = tok;
                switch (tok.payload) {
                    .ident => |ident| {
                        var retained = ident;
                        retained.atom = ident.atom;
                        copy.payload = .{ .ident = retained };
                    },
                    .str => |str| {
                        var retained = str;
                        const owns_bytes = str.bytes.len > 0 and !self.isSourceSlice(str.bytes);
                        const owns_raw = str.raw_bytes.len > 0 and !self.isSourceSlice(str.raw_bytes);
                        if (owns_bytes) retained.bytes = try self.allocator.dupe(u8, str.bytes);
                        errdefer if (owns_bytes) self.allocator.free(retained.bytes);
                        if (owns_raw) retained.raw_bytes = try self.allocator.dupe(u8, str.raw_bytes);
                        copy.payload = .{ .str = retained };
                    },
                    else => {},
                }
                return copy;
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
                var result: t.Token = undefined;
                try self.nextInto(&result);
                return result;
            }

            /// QuickJS's `next_token` writes the next `JSToken` directly into the
            /// parse state. Hot speculative scans provide the final storage so a
            /// large Token is not copied out of an error-union return buffer.
            pub fn nextInto(self: *LexerImpl, out: *t.Token) Error!void {
                try self.skipTrivia();
                self.mark();

                if (self.pos >= self.source.len) {
                    self.emitInto(out, .eof, .{ .none = {} });
                    return;
                }

                const c = self.peek();

                if (isAsciiIdentStart(c) or c >= 0x80 or self.startsUnicodeEscape()) {
                    return self.lexIdentifier(out);
                }
                if (isDecimalDigit(c)) {
                    return self.lexNumber(out, false);
                }
                if (c == '#') {
                    return self.lexPrivateName(out);
                }
                if (c == '"' or c == '\'') {
                    return self.lexString(out, c);
                }
                if (c == '`') {
                    return self.lexTemplate(out, .head_or_no_subst);
                }
                if (c == '.') {
                    return self.lexDotOrNumber(out);
                }
                return self.lexPunctuator(out);
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
                var result: t.Token = undefined;
                try self.nextTemplatePartInto(&result);
                return result;
            }

            pub fn nextTemplatePartInto(self: *LexerImpl, out: *t.Token) Error!void {
                self.mark();
                return self.lexTemplate(out, .middle_or_tail);
            }

            /// Like `nextTemplatePart`, but assumes the closing `}` has already
            /// been lexed and consumed by the parser's lookahead. Used by the
            /// expression parser, which discovers `}` only via its standard
            /// post-expression lookahead.
            pub fn nextTemplatePartAfterBrace(self: *LexerImpl) Error!t.Token {
                var result: t.Token = undefined;
                try self.nextTemplatePartAfterBraceInto(&result);
                return result;
            }

            pub fn nextTemplatePartAfterBraceInto(self: *LexerImpl, out: *t.Token) Error!void {
                self.mark();
                return self.lexTemplateBody(out, .middle_or_tail, false);
            }

            /// Re-lex the most recently emitted `/`/`/=` punctuator as a regex
            /// literal. Mirrors the QuickJS pattern of letting the parser ask
            /// for a regexp once it knows it's in a regexp-allowed context
            /// (`js_parse_regexp`, `quickjs.c:22005`). The caller passes the
            /// `mark_pos` recorded before the slash so we restart from there.
            pub fn rescanRegexp(self: *LexerImpl, slash_offset: usize) Error!t.Token {
                var result: t.Token = undefined;
                try self.rescanRegexpInto(&result, slash_offset);
                return result;
            }

            pub fn rescanRegexpInto(self: *LexerImpl, out: *t.Token, slash_offset: usize) Error!void {
                // Reset position back to the slash. The caller is responsible
                // for having recorded `mark_line`/`mark_col` before the slash.
                self.pos = slash_offset;
                self.line = self.mark_line;
                self.col = self.mark_col;
                self.mark();
                return self.lexRegexp(out);
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

            /// QuickJS `peek_token(..., TRUE)` equivalent for the identifier-arrow
            /// test. It is non-owning and does not mutate lexer state. Inputs that
            /// need the full lexer error path return `null` so the caller falls
            /// back to ordinary tokenization.
            pub fn simpleNextIsArrowNoLineTerminator(self: *const LexerImpl) ?bool {
                var pos = self.pos;
                return switch (simple_token.next(self.source, &pos, true)) {
                    .arrow => true,
                    .unsupported => null,
                    else => false,
                };
            }

            /// Non-owning fast path for the common parenthesized-expression case.
            /// The helper returns null whenever raw bytes are not sufficient to
            /// distinguish structure, preserving the full lexer as the oracle.
            pub fn simpleCurrentParenIsArrowHead(self: *const LexerImpl) ?bool {
                return simple_token.parenArrowAfterOpen(self.source, self.pos);
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

            inline fn emitInto(self: *LexerImpl, out: *t.Token, val: t.TokenKind, payload: t.Payload) void {
                out.* = .{
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
                    const c = self.peek();
                    if (c == ' ' or c == '\t' or c == 0x0B or c == 0x0C) {
                        self.bump();
                        continue;
                    }
                    if (c >= 0x80) {
                        if (self.skipNonAsciiWhiteSpace()) |is_line_terminator| {
                            if (is_line_terminator) {
                                self.got_lf = true;
                                allow_html_close = true;
                            }
                            continue;
                        }
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

            fn lexIdentifier(self: *LexerImpl, out: *t.Token) Error!void {
                if (try self.lexAsciiIdentifierNoEscape(out)) return;

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
                try self.emitIdentifierOrKeyword(out, lexeme, has_escape);
            }

            fn lexAsciiIdentifierNoEscape(self: *LexerImpl, out: *t.Token) Error!bool {
                if (self.peek() == '\\' or self.peek() >= 0x80) return false;

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
                        return false;
                    }
                    break;
                }

                const lexeme = self.source[start..self.pos];
                try self.emitIdentifierOrKeyword(out, lexeme, false);
                return true;
            }

            fn emitIdentifierOrKeyword(self: *LexerImpl, out: *t.Token, lexeme: []const u8, has_escape: bool) Error!void {
                // Keep the compact keyword dispatch ahead of the general atom
                // table. zjs stores predefined spellings in immutable static
                // storage, so routing keywords through std.HashMap would make the
                // common literal/control-word path materially more expensive than
                // QuickJS's preseeded atom hash.
                if (!has_escape) {
                    if (keywordLookup(lexeme)) |val| {
                        if (t.isKeyword(val)) {
                            const a = t.keywordAtom(val);
                            self.emitInto(out, val, .{ .ident = .{
                                .atom = a,
                                .has_escape = false,
                                .is_reserved = isReservedKeyword(val, self.is_strict_mode),
                            } });
                            return;
                        }
                    }
                }

                const a = try self.atoms.internString(lexeme);
                self.emitInto(out, .ident, .{ .ident = .{
                    .atom = a,
                    .has_escape = has_escape,
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

            fn lexPrivateName(self: *LexerImpl, out: *t.Token) Error!void {
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
                self.emitInto(out, .private_name, .{ .ident = .{
                    .atom = a,
                    .has_escape = has_escape,
                    .is_reserved = false,
                } });
            }

            // ---- numbers -----------------------------------------------------

            fn lexDotOrNumber(self: *LexerImpl, out: *t.Token) Error!void {
                if (self.peekAt(1) == '.' and self.peekAt(2) == '.') {
                    self.bump();
                    self.bump();
                    self.bump();
                    self.emitInto(out, .ellipsis, .{ .none = {} });
                    return;
                }
                if (isDecimalDigit(self.peekAt(1))) {
                    return self.lexNumber(out, true);
                }
                self.bump();
                self.emitInto(out, .dot, .{ .none = {} });
            }

            fn lexNumber(self: *LexerImpl, out: *t.Token, leading_dot: bool) Error!void {
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
                            return self.finishNumber(out, start, is_bigint, 16);
                        },
                        'o', 'O' => {
                            self.bump();
                            self.bump();
                            if (!consumeOctalDigits(self)) return error.InvalidNumber;
                            if (self.pos < self.source.len and self.peek() == 'n') {
                                is_bigint = true;
                                self.bump();
                            }
                            return self.finishNumber(out, start, is_bigint, 8);
                        },
                        'b', 'B' => {
                            self.bump();
                            self.bump();
                            if (!consumeBinaryDigits(self)) return error.InvalidNumber;
                            if (self.pos < self.source.len and self.peek() == 'n') {
                                is_bigint = true;
                                self.bump();
                            }
                            return self.finishNumber(out, start, is_bigint, 2);
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
                return self.finishNumber(out, start, is_bigint, 10);
            }

            fn finishNumber(self: *LexerImpl, out: *t.Token, start: usize, is_bigint: bool, base: u8) Error!void {
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
                    self.emitInto(out, .number, .{ .num = .{
                        .value = 0,
                        .is_bigint = true,
                        .bigint_text = lexeme[0 .. lexeme.len - 1],
                    } });
                    return;
                }
                if (base == 10) {
                    if (try legacyOrNonOctalDecimalValue(self, lexeme)) |value| {
                        self.emitInto(out, .number, .{ .num = .{ .value = value } });
                        return;
                    }
                }
                const value = parseNumberLiteral(lexeme) orelse return error.InvalidNumber;
                self.emitInto(out, .number, .{ .num = .{ .value = value } });
            }

            // ---- strings -----------------------------------------------------

            fn lexString(self: *LexerImpl, out: *t.Token, quote: u8) Error!void {
                self.bump(); // opening quote
                const content_start = self.pos;
                while (self.pos < self.source.len) {
                    const c = self.peek();
                    if (c == quote) {
                        const bytes = @constCast(self.source[content_start..self.pos]);
                        self.bump();
                        self.emitInto(out, .string, .{ .str = .{
                            .bytes = bytes,
                            .contains_escape = false,
                            .contains_legacy_escape = false,
                            .sep = quote,
                        } });
                        return;
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
                        self.emitInto(out, .string, .{ .str = .{
                            .bytes = owned,
                            .contains_escape = contains_escape,
                            .contains_legacy_escape = contains_legacy_escape,
                            .sep = quote,
                        } });
                        return;
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
                        // template literals; QuickJS reports it via curFunc->is_strict_mode.
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

            fn lexTemplate(self: *LexerImpl, out: *t.Token, phase: TemplatePhase) Error!void {
                return self.lexTemplateBody(out, phase, true);
            }

            fn lexTemplateBody(self: *LexerImpl, out: *t.Token, phase: TemplatePhase, expect_open_byte: bool) Error!void {
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
                        self.emitInto(out, .template, .{ .str = .{
                            .bytes = owned,
                            .raw_bytes = raw,
                            .cooked_invalid = cooked_invalid,
                            .sep = '`',
                            .template = part,
                        } });
                        return;
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
                        self.emitInto(out, .template, .{ .str = .{
                            .bytes = owned,
                            .raw_bytes = raw,
                            .cooked_invalid = cooked_invalid,
                            .sep = '`',
                            .template = part,
                        } });
                        return;
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

            fn lexRegexp(self: *LexerImpl, out: *t.Token) Error!void {
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
                self.emitInto(out, .regexp, .{ .regexp = .{
                    .pattern = self.source[pat_start..pat_end],
                    .flags = self.source[flags_start..self.pos],
                } });
            }

            // ---- punctuators -------------------------------------------------

            fn lexPunctuator(self: *LexerImpl, out: *t.Token) Error!void {
                const c = self.peek();
                switch (c) {
                    '+' => return self.lexPlus(out),
                    '-' => return self.lexMinus(out),
                    '*' => return self.lexStar(out),
                    '/' => return self.lexSlash(out),
                    '%' => return self.lexPercent(out),
                    '=' => return self.lexEquals(out),
                    '!' => return self.lexBang(out),
                    '<' => return self.lexLt(out),
                    '>' => return self.lexGt(out),
                    '&' => return self.lexAmp(out),
                    '|' => return self.lexPipe(out),
                    '^' => return self.lexCaret(out),
                    '?' => return self.lexQuestion(out),
                    '~', '(', ')', '[', ']', '{', '}', ',', ';', ':' => {
                        self.bump();
                        self.emitInto(out, @enumFromInt(c), .{ .none = {} });
                    },
                    else => {
                        self.bump();
                        return error.InvalidIdentifier;
                    },
                }
            }

            fn lexPlus(self: *LexerImpl, out: *t.Token) Error!void {
                self.bump();
                if (self.pos < self.source.len) {
                    if (self.peek() == '+') {
                        self.bump();
                        self.emitInto(out, .inc, .{ .none = {} });
                        return;
                    }
                    if (self.peek() == '=') {
                        self.bump();
                        self.emitInto(out, .plus_assign, .{ .none = {} });
                        return;
                    }
                }
                self.emitInto(out, .plus, .{ .none = {} });
            }

            fn lexMinus(self: *LexerImpl, out: *t.Token) Error!void {
                self.bump();
                if (self.pos < self.source.len) {
                    if (self.peek() == '-') {
                        self.bump();
                        self.emitInto(out, .dec, .{ .none = {} });
                        return;
                    }
                    if (self.peek() == '=') {
                        self.bump();
                        self.emitInto(out, .minus_assign, .{ .none = {} });
                        return;
                    }
                }
                self.emitInto(out, .minus, .{ .none = {} });
            }

            fn lexStar(self: *LexerImpl, out: *t.Token) Error!void {
                self.bump();
                if (self.pos < self.source.len) {
                    if (self.peek() == '*') {
                        self.bump();
                        if (self.pos < self.source.len and self.peek() == '=') {
                            self.bump();
                            self.emitInto(out, .pow_assign, .{ .none = {} });
                            return;
                        }
                        self.emitInto(out, .pow, .{ .none = {} });
                        return;
                    }
                    if (self.peek() == '=') {
                        self.bump();
                        self.emitInto(out, .mul_assign, .{ .none = {} });
                        return;
                    }
                }
                self.emitInto(out, .star, .{ .none = {} });
            }

            fn lexSlash(self: *LexerImpl, out: *t.Token) Error!void {
                self.bump();
                if (self.pos < self.source.len and self.peek() == '=') {
                    self.bump();
                    self.emitInto(out, .div_assign, .{ .none = {} });
                    return;
                }
                self.emitInto(out, .slash, .{ .none = {} });
            }

            fn lexPercent(self: *LexerImpl, out: *t.Token) Error!void {
                self.bump();
                if (self.pos < self.source.len and self.peek() == '=') {
                    self.bump();
                    self.emitInto(out, .mod_assign, .{ .none = {} });
                    return;
                }
                self.emitInto(out, .percent, .{ .none = {} });
            }

            fn lexEquals(self: *LexerImpl, out: *t.Token) Error!void {
                self.bump();
                if (self.pos < self.source.len) {
                    if (self.peek() == '=') {
                        self.bump();
                        if (self.pos < self.source.len and self.peek() == '=') {
                            self.bump();
                            self.emitInto(out, .strict_eq, .{ .none = {} });
                            return;
                        }
                        self.emitInto(out, .eq, .{ .none = {} });
                        return;
                    }
                    if (self.peek() == '>') {
                        self.bump();
                        self.emitInto(out, .arrow, .{ .none = {} });
                        return;
                    }
                }
                self.emitInto(out, .assign, .{ .none = {} });
            }

            fn lexBang(self: *LexerImpl, out: *t.Token) Error!void {
                self.bump();
                if (self.pos < self.source.len and self.peek() == '=') {
                    self.bump();
                    if (self.pos < self.source.len and self.peek() == '=') {
                        self.bump();
                        self.emitInto(out, .strict_neq, .{ .none = {} });
                        return;
                    }
                    self.emitInto(out, .neq, .{ .none = {} });
                    return;
                }
                self.emitInto(out, .bang, .{ .none = {} });
            }

            fn lexLt(self: *LexerImpl, out: *t.Token) Error!void {
                self.bump();
                if (self.pos < self.source.len) {
                    if (self.peek() == '=') {
                        self.bump();
                        self.emitInto(out, .lte, .{ .none = {} });
                        return;
                    }
                    if (self.peek() == '<') {
                        self.bump();
                        if (self.pos < self.source.len and self.peek() == '=') {
                            self.bump();
                            self.emitInto(out, .shl_assign, .{ .none = {} });
                            return;
                        }
                        self.emitInto(out, .shl, .{ .none = {} });
                        return;
                    }
                }
                self.emitInto(out, .lt, .{ .none = {} });
            }

            fn lexGt(self: *LexerImpl, out: *t.Token) Error!void {
                self.bump();
                if (self.pos < self.source.len) {
                    if (self.peek() == '=') {
                        self.bump();
                        self.emitInto(out, .gte, .{ .none = {} });
                        return;
                    }
                    if (self.peek() == '>') {
                        self.bump();
                        if (self.pos < self.source.len and self.peek() == '>') {
                            self.bump();
                            if (self.pos < self.source.len and self.peek() == '=') {
                                self.bump();
                                self.emitInto(out, .shr_assign, .{ .none = {} });
                                return;
                            }
                            self.emitInto(out, .shr, .{ .none = {} });
                            return;
                        }
                        if (self.pos < self.source.len and self.peek() == '=') {
                            self.bump();
                            self.emitInto(out, .sar_assign, .{ .none = {} });
                            return;
                        }
                        self.emitInto(out, .sar, .{ .none = {} });
                        return;
                    }
                }
                self.emitInto(out, .gt, .{ .none = {} });
            }

            fn lexAmp(self: *LexerImpl, out: *t.Token) Error!void {
                self.bump();
                if (self.pos < self.source.len) {
                    if (self.peek() == '&') {
                        self.bump();
                        if (self.pos < self.source.len and self.peek() == '=') {
                            self.bump();
                            self.emitInto(out, .land_assign, .{ .none = {} });
                            return;
                        }
                        self.emitInto(out, .land, .{ .none = {} });
                        return;
                    }
                    if (self.peek() == '=') {
                        self.bump();
                        self.emitInto(out, .and_assign, .{ .none = {} });
                        return;
                    }
                }
                self.emitInto(out, .amp, .{ .none = {} });
            }

            fn lexPipe(self: *LexerImpl, out: *t.Token) Error!void {
                self.bump();
                if (self.pos < self.source.len) {
                    if (self.peek() == '|') {
                        self.bump();
                        if (self.pos < self.source.len and self.peek() == '=') {
                            self.bump();
                            self.emitInto(out, .lor_assign, .{ .none = {} });
                            return;
                        }
                        self.emitInto(out, .lor, .{ .none = {} });
                        return;
                    }
                    if (self.peek() == '=') {
                        self.bump();
                        self.emitInto(out, .or_assign, .{ .none = {} });
                        return;
                    }
                }
                self.emitInto(out, .pipe, .{ .none = {} });
            }

            fn lexCaret(self: *LexerImpl, out: *t.Token) Error!void {
                self.bump();
                if (self.pos < self.source.len and self.peek() == '=') {
                    self.bump();
                    self.emitInto(out, .xor_assign, .{ .none = {} });
                    return;
                }
                self.emitInto(out, .caret, .{ .none = {} });
            }

            fn lexQuestion(self: *LexerImpl, out: *t.Token) Error!void {
                self.bump();
                if (self.pos < self.source.len) {
                    if (self.peek() == '?') {
                        self.bump();
                        if (self.pos < self.source.len and self.peek() == '=') {
                            self.bump();
                            self.emitInto(out, .double_question_mark_assign, .{ .none = {} });
                            return;
                        }
                        self.emitInto(out, .double_question_mark, .{ .none = {} });
                        return;
                    }
                    if (self.peek() == '.' and !isDecimalDigit(self.peekAt(1))) {
                        self.bump();
                        self.emitInto(out, .question_mark_dot, .{ .none = {} });
                        return;
                    }
                }
                self.emitInto(out, .question, .{ .none = {} });
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

        /// qjs `js_parse_number` -> `js_atof` with `ATOD_ACCEPT_BIN_OCT |
        /// ATOD_ACCEPT_UNDERSCORES`. The lexer has already fixed the extent of
        /// the literal and validated separator placement; legacy octal and the
        /// BigInt suffix are handled before reaching here.
        fn parseNumberLiteral(lexeme: []const u8) ?f64 {
            return number_format.parseNumberExact(lexeme, 0, .{ .accept_bin_oct = true, .accept_underscores = true });
        }

        fn keywordLookup(lexeme: []const u8) ?t.TokenKind {
            if (lexeme.len < 2 or lexeme.len > 10) return null;
            return switch (lexeme.len) {
                2 => switch (lexeme[0]) {
                    'd' => if (eq(lexeme, "do")) .kw_do else null,
                    'i' => if (eq(lexeme, "if")) .kw_if else if (eq(lexeme, "in")) .kw_in else null,
                    // QuickJS keeps `of` as an ordinary identifier in normal
                    // lexing. TOK_OF exists only for parser lookahead.
                    else => null,
                },
                3 => switch (lexeme[0]) {
                    'f' => if (eq(lexeme, "for")) .kw_for else null,
                    'l' => if (eq(lexeme, "let")) .kw_let else null,
                    'n' => if (eq(lexeme, "new")) .kw_new else null,
                    't' => if (eq(lexeme, "try")) .kw_try else null,
                    'v' => if (eq(lexeme, "var")) .kw_var else null,
                    else => null,
                },
                4 => switch (lexeme[0]) {
                    'c' => if (eq(lexeme, "case")) .kw_case else null,
                    'e' => if (eq(lexeme, "else")) .kw_else else if (eq(lexeme, "enum")) .kw_enum else null,
                    'n' => if (eq(lexeme, "null")) .kw_null else null,
                    't' => if (eq(lexeme, "this")) .kw_this else if (eq(lexeme, "true")) .kw_true else null,
                    'v' => if (eq(lexeme, "void")) .kw_void else null,
                    'w' => if (eq(lexeme, "with")) .kw_with else null,
                    else => null,
                },
                5 => switch (lexeme[0]) {
                    'a' => if (eq(lexeme, "async")) .kw_async else if (eq(lexeme, "await")) .kw_await else null,
                    'b' => if (eq(lexeme, "break")) .kw_break else null,
                    'c' => if (eq(lexeme, "catch")) .kw_catch else if (eq(lexeme, "class")) .kw_class else if (eq(lexeme, "const")) .kw_const else null,
                    'f' => if (eq(lexeme, "false")) .kw_false else null,
                    's' => if (eq(lexeme, "super")) .kw_super else null,
                    't' => if (eq(lexeme, "throw")) .kw_throw else null,
                    'w' => if (eq(lexeme, "while")) .kw_while else null,
                    'y' => if (eq(lexeme, "yield")) .kw_yield else null,
                    else => null,
                },
                6 => switch (lexeme[0]) {
                    'd' => if (eq(lexeme, "delete")) .kw_delete else null,
                    'e' => if (eq(lexeme, "export")) .kw_export else null,
                    'i' => if (eq(lexeme, "import")) .kw_import else null,
                    'p' => if (eq(lexeme, "public")) .kw_public else null,
                    'r' => if (eq(lexeme, "return")) .kw_return else null,
                    's' => if (eq(lexeme, "static")) .kw_static else if (eq(lexeme, "switch")) .kw_switch else null,
                    't' => if (eq(lexeme, "typeof")) .kw_typeof else null,
                    else => null,
                },
                7 => switch (lexeme[0]) {
                    'd' => if (eq(lexeme, "default")) .kw_default else null,
                    'e' => if (eq(lexeme, "extends")) .kw_extends else null,
                    'f' => if (eq(lexeme, "finally")) .kw_finally else null,
                    'p' => if (eq(lexeme, "package")) .kw_package else if (eq(lexeme, "private")) .kw_private else null,
                    else => null,
                },
                8 => switch (lexeme[0]) {
                    'c' => if (eq(lexeme, "continue")) .kw_continue else null,
                    'd' => if (eq(lexeme, "debugger")) .kw_debugger else null,
                    'f' => if (eq(lexeme, "function")) .kw_function else null,
                    else => null,
                },
                9 => switch (lexeme[0]) {
                    'i' => if (eq(lexeme, "interface")) .kw_interface else null,
                    'p' => if (eq(lexeme, "protected")) .kw_protected else null,
                    else => null,
                },
                10 => switch (lexeme[0]) {
                    'i' => if (eq(lexeme, "implements")) .kw_implements else if (eq(lexeme, "instanceof")) .kw_instanceof else null,
                    else => null,
                },
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
                .kw_null, .kw_false, .kw_true, .kw_if, .kw_else, .kw_return, .kw_var, .kw_this, .kw_delete, .kw_void, .kw_typeof, .kw_new, .kw_in, .kw_instanceof, .kw_do, .kw_while, .kw_for, .kw_break, .kw_continue, .kw_switch, .kw_case, .kw_default, .kw_throw, .kw_try, .kw_catch, .kw_finally, .kw_function, .kw_debugger, .kw_with, .kw_class, .kw_const, .kw_enum, .kw_export, .kw_extends, .kw_import, .kw_super => true,
                // FutureReservedWord only in strict mode.
                .kw_implements, .kw_interface, .kw_let, .kw_package, .kw_private, .kw_protected, .kw_public, .kw_static, .kw_yield => is_strict,
                // Contextual.
                .kw_await, .kw_of => false,
                else => false,
            };
        }

        pub const Lexer = LexerImpl;
    };
}

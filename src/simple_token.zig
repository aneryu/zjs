//! Non-owning source lookahead for the small token subset used by QuickJS
//! `simple_next_token`. It never allocates or mutates lexer state. Callers must
//! fall back to the full lexer when `.unsupported` is returned.

const std = @import("std");
const unicode = @import("libs/unicode.zig");

pub const Kind = enum {
    import_keyword,
    export_keyword,
    identifier,
    arrow,
    line_terminator,
    dot,
    left_paren,
    other,
    eof,
    unsupported,
};

const Decoded = struct {
    codepoint: u21,
    width: usize,
};

/// Scan one token beginning at `pos.*`, skipping trivia. When
/// `no_line_terminator` is true, a line terminator in the skipped trivia is
/// returned instead of crossed. `pos.*` is local caller state; the engine
/// lexer is never touched.
pub fn next(source: []const u8, pos: *usize, no_line_terminator: bool) Kind {
    var p = pos.*;
    while (p < source.len) {
        const c = source[p];
        switch (c) {
            '\r', '\n' => {
                if (no_line_terminator) return finish(pos, p, .line_terminator);
                p += 1;
                continue;
            },
            ' ', '\t', 0x0b, 0x0c => {
                p += 1;
                continue;
            },
            '/' => {
                if (p + 1 >= source.len) return finish(pos, p + 1, .other);
                if (source[p + 1] == '/') {
                    // QuickJS peek_token(..., TRUE) treats a line comment as a
                    // line terminator without scanning its body.
                    if (no_line_terminator) return finish(pos, p, .line_terminator);
                    if (!skipLineComment(source, &p)) return finish(pos, p, .unsupported);
                    continue;
                }
                if (source[p + 1] != '*') return finish(pos, p + 1, .other);

                p += 2;
                var closed = false;
                while (p < source.len) {
                    const comment_byte = source[p];
                    if (comment_byte == '\r' or comment_byte == '\n') {
                        if (no_line_terminator) return finish(pos, p, .line_terminator);
                        p += 1;
                        continue;
                    }
                    // The full lexer recognizes Unicode LS/PS inside block
                    // comments. Keep this raw scanner conservative on every
                    // non-ASCII byte rather than duplicating that error path.
                    if (comment_byte >= 0x80 and no_line_terminator) {
                        return finish(pos, p, .unsupported);
                    }
                    if (comment_byte == '*' and p + 1 < source.len and source[p + 1] == '/') {
                        p += 2;
                        closed = true;
                        break;
                    }
                    p += 1;
                }
                if (!closed) return finish(pos, p, .unsupported);
                continue;
            },
            '=' => {
                if (p + 1 < source.len and source[p + 1] == '>') {
                    return finish(pos, p + 2, .arrow);
                }
                return finish(pos, p + 1, .other);
            },
            '.' => return finish(pos, p + 1, .dot),
            '(' => return finish(pos, p + 1, .left_paren),
            'i' => return identifierOrKeyword(source, pos, p, "import", .import_keyword),
            'e' => return identifierOrKeyword(source, pos, p, "export", .export_keyword),
            else => {
                if (unicode.isAsciiIdentifierStartByte(c)) {
                    return finish(pos, p + 1, .identifier);
                }
                if (c >= 0x80) {
                    const decoded = decodeAt(source, p) orelse return finish(pos, p, .unsupported);
                    if (unicode.isEcmaLineTerminatorCodePoint(decoded.codepoint)) {
                        if (no_line_terminator) return finish(pos, p, .line_terminator);
                        p += decoded.width;
                        continue;
                    }
                    if (unicode.isEcmaWhitespaceOrLineTerminatorCodePoint(decoded.codepoint)) {
                        p += decoded.width;
                        continue;
                    }
                    if (unicode.isIdentifierStart(decoded.codepoint)) {
                        return finish(pos, p + decoded.width, .identifier);
                    }
                    return finish(pos, p + decoded.width, .other);
                }
                return finish(pos, p + 1, .other);
            },
        }
    }
    return finish(pos, p, .eof);
}

pub const BalancedFollowing = enum {
    arrow,
    assignment,
    comma,
    right_paren,
    right_bracket,
    right_brace,
    identifier,
    in_keyword,
    line_terminator,
    other,
    eof,
};

pub const BalancedScan = struct {
    following: BalancedFollowing = .eof,
    closed: bool = false,
    has_top_level_semicolon: bool = false,
    has_top_level_ellipsis: bool = false,
    has_assignment: bool = false,
};

/// Starting immediately after an already-lexed `opening`, scan to its matching
/// delimiter and classify the following token without materializing tokens.
/// This is the borrowed-token equivalent of QuickJS
/// `js_parse_skip_parens_token`: regexp context and the three topology bits are
/// preserved, while source requiring the full template/Unicode/mode-aware
/// lexer returns `null` and lets the caller fall back.
pub fn balancedAfterOpen(
    source: []const u8,
    start: usize,
    opening: u8,
    no_line_terminator: bool,
) ?BalancedScan {
    if (opening != '(' and opening != '[' and opening != '{') return null;

    var p = start;
    var delimiters: [256]u8 = undefined;
    delimiters[0] = 0;
    delimiters[1] = opening;
    var level: usize = 2;
    var regexp_context: RegexpContext = .allowed;
    var previous_word_start: usize = 0;
    var previous_word_end: usize = 0;
    var result: BalancedScan = .{};

    while (p < source.len) {
        switch (source[p]) {
            ' ', '\t', 0x0b, 0x0c, '\r', '\n' => p += 1,
            '(', '[', '{' => {
                if (level >= delimiters.len) return null;
                delimiters[level] = source[p];
                level += 1;
                p += 1;
                regexp_context = .allowed;
            },
            ')', ']', '}' => |closing| {
                if (level <= 1) return result;
                const expected: u8 = switch (closing) {
                    ')' => '(',
                    ']' => '[',
                    '}' => '{',
                    else => unreachable,
                };
                level -= 1;
                if (delimiters[level] != expected) return result;
                p += 1;
                if (level == 1) {
                    result.closed = true;
                    result.following = scanFollowing(source, p, no_line_terminator) orelse return null;
                    return result;
                }
                regexp_context = .disallowed;
            },
            '\'', '"' => {
                if (!skipQuoted(source, &p, source[p])) return null;
                regexp_context = .disallowed;
            },
            '/' => {
                if (p + 1 >= source.len) return null;
                switch (source[p + 1]) {
                    '/' => if (!skipLineComment(source, &p)) return null,
                    '*' => if (!skipBlockComment(source, &p)) return null,
                    else => switch (if (regexp_context == .identifier)
                        identifierRegexpContext(source[previous_word_start..previous_word_end])
                    else
                        regexp_context) {
                        .allowed => {
                            if (!skipRegexp(source, &p)) return null;
                            regexp_context = .disallowed;
                        },
                        .disallowed => {
                            p += 1;
                            if (p < source.len and source[p] == '=') p += 1;
                            regexp_context = .allowed;
                        },
                        .identifier, .mode_dependent => return null,
                    },
                }
            },
            '+', '-' => |operator| {
                if (operator == '-' and startsWithAt(source, p, "-->")) return null;
                if (p + 1 < source.len and source[p + 1] == operator) {
                    p += 2;
                    regexp_context = .disallowed;
                } else {
                    p += 1;
                    if (p < source.len and source[p] == '=') p += 1;
                    regexp_context = .allowed;
                }
            },
            '.' => {
                if (startsWithAt(source, p, "...")) {
                    if (level == 2) result.has_top_level_ellipsis = true;
                    p += 3;
                    regexp_context = .allowed;
                } else if (p + 1 < source.len and isAsciiDigit(source[p + 1])) {
                    skipNumberLike(source, &p);
                    regexp_context = .disallowed;
                } else {
                    p += 1;
                    regexp_context = .allowed;
                }
            },
            '0'...'9' => {
                skipNumberLike(source, &p);
                regexp_context = .disallowed;
            },
            // Template substitutions need the full template lexer.
            // Identifier escapes can also change keyword boundaries.
            '`', '\\' => return null,
            '<' => {
                if (startsWithAt(source, p, "<!--")) return null;
                p += 1;
                if (p < source.len and (source[p] == '=' or source[p] == '<')) p += 1;
                regexp_context = .allowed;
            },
            '#', '$', '_', 'a'...'z', 'A'...'Z' => {
                const word_start = p;
                if (source[p] == '#') {
                    p += 1;
                    if (p >= source.len or !unicode.isAsciiIdentifierStartByte(source[p])) return null;
                }
                while (p < source.len and unicode.isAsciiIdentifierPartByte(source[p])) p += 1;
                if (source[word_start] == '#') {
                    regexp_context = .disallowed;
                } else {
                    previous_word_start = word_start;
                    previous_word_end = p;
                    regexp_context = .identifier;
                }
            },
            '=' => {
                if (p + 1 >= source.len or (source[p + 1] != '=' and source[p + 1] != '>')) {
                    result.has_assignment = true;
                }
                p += 1;
                while (p < source.len and isPunctuatorContinuation(source[p])) p += 1;
                regexp_context = .allowed;
            },
            ';' => {
                if (level == 2) result.has_top_level_semicolon = true;
                p += 1;
                regexp_context = .allowed;
            },
            '!', '*', '%', '&', '|', '^', '~', '?', ':', ',', '>' => {
                p += 1;
                // The exact width is irrelevant here. Consuming the remaining
                // ASCII punctuator bytes avoids treating them as a second
                // significant token while preserving QuickJS's default
                // "regexp allowed after operator" rule.
                while (p < source.len and isPunctuatorContinuation(source[p])) p += 1;
                regexp_context = .allowed;
            },
            else => {
                if (source[p] >= 0x80) return null;
                // Unknown ASCII is either invalid source or a syntax form this
                // small scanner does not model. Let the full lexer diagnose it.
                return null;
            },
        }
    }
    return result;
}

/// Compatibility helper for the identifier/parenthesized-arrow callers.
pub fn parenArrowAfterOpen(source: []const u8, start: usize) ?bool {
    const balanced = balancedAfterOpen(source, start, '(', true) orelse return null;
    return balanced.closed and balanced.following == .arrow;
}

fn scanFollowing(source: []const u8, start: usize, no_line_terminator: bool) ?BalancedFollowing {
    var p = start;
    while (p < source.len) {
        const c = source[p];
        switch (c) {
            ' ', '\t', 0x0b, 0x0c => p += 1,
            '\r', '\n' => {
                if (no_line_terminator) return .line_terminator;
                p += 1;
            },
            '/' => {
                if (p + 1 >= source.len) return .other;
                if (source[p + 1] == '/') {
                    if (no_line_terminator) return .line_terminator;
                    if (!skipLineComment(source, &p)) return null;
                    continue;
                }
                if (source[p + 1] != '*') return .other;

                p += 2;
                var closed = false;
                while (p < source.len) {
                    if (source[p] == '\r' or source[p] == '\n') {
                        if (no_line_terminator) return .line_terminator;
                        p += 1;
                        continue;
                    }
                    if (source[p] >= 0x80) {
                        const decoded = decodeAt(source, p) orelse return null;
                        if (unicode.isEcmaLineTerminatorCodePoint(decoded.codepoint)) {
                            if (no_line_terminator) return .line_terminator;
                        }
                        p += decoded.width;
                        continue;
                    }
                    if (source[p] == '*' and p + 1 < source.len and source[p + 1] == '/') {
                        p += 2;
                        closed = true;
                        break;
                    }
                    p += 1;
                }
                if (!closed) return null;
            },
            '=' => {
                if (p + 1 < source.len and source[p + 1] == '>') return .arrow;
                // Pattern topology only needs the plain assignment token.
                // `==` / `===` are equality operators and must leave an
                // object/array literal on the expression path, exactly as the
                // full lexer returns TOK_EQ/TOK_STRICT_EQ rather than '='.
                if (p + 1 < source.len and source[p + 1] == '=') return .other;
                return .assignment;
            },
            ',' => return .comma,
            ')' => return .right_paren,
            ']' => return .right_bracket,
            '}' => return .right_brace,
            else => {
                if (unicode.isAsciiIdentifierStartByte(c)) {
                    const word_start = p;
                    p += 1;
                    while (p < source.len and unicode.isAsciiIdentifierPartByte(source[p])) p += 1;
                    return if (matches(source[word_start..p], "in")) .in_keyword else .identifier;
                }
                if (c == '\\') return null;
                if (c < 0x80) return .other;
                const decoded = decodeAt(source, p) orelse return null;
                if (unicode.isEcmaLineTerminatorCodePoint(decoded.codepoint)) {
                    if (no_line_terminator) return .line_terminator;
                    p += decoded.width;
                    continue;
                }
                if (unicode.isEcmaWhitespaceOrLineTerminatorCodePoint(decoded.codepoint)) {
                    p += decoded.width;
                    continue;
                }
                if (unicode.isIdentifierStart(decoded.codepoint)) return null;
                return .other;
            },
        }
    }
    return .eof;
}

const RegexpContext = enum {
    allowed,
    disallowed,
    /// Defer keyword classification until a following slash makes it
    /// observable. Most identifiers in an arrow-head scan never need it.
    identifier,
    /// `await` and strict-only future keywords depend on parser mode. Only a
    /// following slash needs to force fallback; any later real token replaces
    /// this state.
    mode_dependent,
};

noinline fn identifierRegexpContext(word: []const u8) RegexpContext {
    if (word.len > 0 and word[0] == '#') return .disallowed;
    if (word.len == 0) return .disallowed;

    // Length and first byte reduce every identifier to at most a few fixed
    // comparisons. In particular, minified one-byte names never enter a
    // general keyword table or hash path.
    return switch (word.len) {
        2 => switch (word[0]) {
            'i' => if (matches(word, "if") or matches(word, "in")) .allowed else .disallowed,
            'd' => if (matches(word, "do")) .allowed else .disallowed,
            'o' => if (matches(word, "of")) .allowed else .disallowed,
            else => .disallowed,
        },
        3 => switch (word[0]) {
            'v' => if (matches(word, "var")) .allowed else .disallowed,
            'n' => if (matches(word, "new")) .allowed else .disallowed,
            'f' => if (matches(word, "for")) .allowed else .disallowed,
            't' => if (matches(word, "try")) .allowed else .disallowed,
            'l' => if (matches(word, "let")) .mode_dependent else .disallowed,
            else => .disallowed,
        },
        4 => switch (word[0]) {
            'e' => if (matches(word, "else") or matches(word, "enum")) .allowed else .disallowed,
            'v' => if (matches(word, "void")) .allowed else .disallowed,
            'w' => if (matches(word, "with")) .allowed else .disallowed,
            'c' => if (matches(word, "case")) .allowed else .disallowed,
            // null / true / this are exact QuickJS disallowed cases and fall
            // through with ordinary identifiers.
            else => .disallowed,
        },
        5 => switch (word[0]) {
            'w' => if (matches(word, "while")) .allowed else .disallowed,
            'b' => if (matches(word, "break")) .allowed else .disallowed,
            't' => if (matches(word, "throw")) .allowed else .disallowed,
            'c' => if (matches(word, "catch") or matches(word, "class") or matches(word, "const")) .allowed else .disallowed,
            's' => if (matches(word, "super")) .allowed else .disallowed,
            'y' => if (matches(word, "yield")) .allowed else .disallowed,
            'a' => if (matches(word, "await")) .mode_dependent else .disallowed,
            // false is an exact QuickJS disallowed case.
            else => .disallowed,
        },
        6 => switch (word[0]) {
            'r' => if (matches(word, "return")) .allowed else .disallowed,
            'd' => if (matches(word, "delete")) .allowed else .disallowed,
            't' => if (matches(word, "typeof")) .allowed else .disallowed,
            's' => if (matches(word, "switch")) .allowed else if (matches(word, "static")) .mode_dependent else .disallowed,
            'e' => if (matches(word, "export")) .allowed else .disallowed,
            'i' => if (matches(word, "import")) .allowed else .disallowed,
            'p' => if (matches(word, "public")) .mode_dependent else .disallowed,
            else => .disallowed,
        },
        7 => switch (word[0]) {
            'd' => if (matches(word, "default")) .allowed else .disallowed,
            'f' => if (matches(word, "finally")) .allowed else .disallowed,
            'e' => if (matches(word, "extends")) .allowed else .disallowed,
            'p' => if (matches(word, "package") or matches(word, "private")) .mode_dependent else .disallowed,
            else => .disallowed,
        },
        8 => switch (word[0]) {
            'c' => if (matches(word, "continue")) .allowed else .disallowed,
            'f' => if (matches(word, "function")) .allowed else .disallowed,
            'd' => if (matches(word, "debugger")) .allowed else .disallowed,
            else => .disallowed,
        },
        9 => switch (word[0]) {
            'i' => if (matches(word, "interface")) .mode_dependent else .disallowed,
            'p' => if (matches(word, "protected")) .mode_dependent else .disallowed,
            else => .disallowed,
        },
        10 => switch (word[0]) {
            'i' => if (matches(word, "instanceof")) .allowed else if (matches(word, "implements")) .mode_dependent else .disallowed,
            else => .disallowed,
        },
        else => .disallowed,
    };
}

fn skipRegexp(source: []const u8, pos: *usize) bool {
    var p = pos.* + 1;
    var in_class = false;
    while (p < source.len) {
        const c = source[p];
        if (c == '\r' or c == '\n') return false;
        if (c >= 0x80) return false;
        if (c == '\\') {
            p += 1;
            if (p >= source.len or source[p] == '\r' or source[p] == '\n') return false;
            p += 1;
            continue;
        }
        if (c == '[') {
            in_class = true;
            p += 1;
            continue;
        }
        if (c == ']' and in_class) {
            in_class = false;
            p += 1;
            continue;
        }
        if (c == '/' and !in_class) {
            p += 1;
            while (p < source.len and unicode.isAsciiIdentifierPartByte(source[p])) p += 1;
            if (p < source.len and (source[p] == '\\' or source[p] >= 0x80)) return false;
            pos.* = p;
            return true;
        }
        p += 1;
    }
    return false;
}

fn skipNumberLike(source: []const u8, pos: *usize) void {
    var p = pos.*;
    var previous: u8 = 0;
    while (p < source.len) {
        const c = source[p];
        if (isAsciiDigit(c) or unicode.isAsciiIdentifierPartByte(c) or c == '.' or c == '_') {
            previous = c;
            p += 1;
            continue;
        }
        if ((c == '+' or c == '-') and (previous == 'e' or previous == 'E')) {
            previous = c;
            p += 1;
            continue;
        }
        break;
    }
    pos.* = p;
}

inline fn matches(value: []const u8, candidate: []const u8) bool {
    return std.mem.eql(u8, value, candidate);
}

fn isAsciiDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isPunctuatorContinuation(c: u8) bool {
    return switch (c) {
        '=', '!', '*', '&', '|', '^', '?', '>', '<' => true,
        else => false,
    };
}

fn skipQuoted(source: []const u8, pos: *usize, quote: u8) bool {
    var p = pos.* + 1;
    while (p < source.len) {
        const c = source[p];
        if (c == quote) {
            pos.* = p + 1;
            return true;
        }
        if (c == '\\') {
            p += 1;
            if (p >= source.len) return false;
            if (source[p] == '\r' and p + 1 < source.len and source[p + 1] == '\n') p += 1;
            p += 1;
            continue;
        }
        if (c == '\r' or c == '\n') return false;
        if (c >= 0x80) {
            const decoded = decodeAt(source, p) orelse return false;
            if (unicode.isEcmaLineTerminatorCodePoint(decoded.codepoint)) return false;
            p += decoded.width;
            continue;
        }
        p += 1;
    }
    return false;
}

fn skipLineComment(source: []const u8, pos: *usize) bool {
    var p = pos.* + 2;
    while (p < source.len) {
        if (source[p] == '\r' or source[p] == '\n') break;
        if (source[p] >= 0x80) {
            const decoded = decodeAt(source, p) orelse {
                pos.* = p;
                return false;
            };
            if (unicode.isEcmaLineTerminatorCodePoint(decoded.codepoint)) break;
            p += decoded.width;
            continue;
        }
        p += 1;
    }
    pos.* = p;
    return true;
}

fn skipBlockComment(source: []const u8, pos: *usize) bool {
    var p = pos.* + 2;
    while (p + 1 < source.len) : (p += 1) {
        if (source[p] == '*' and source[p + 1] == '/') {
            pos.* = p + 2;
            return true;
        }
    }
    return false;
}

fn startsWithAt(source: []const u8, start: usize, needle: []const u8) bool {
    return start + needle.len <= source.len and std.mem.eql(u8, source[start .. start + needle.len], needle);
}

fn identifierOrKeyword(
    source: []const u8,
    pos: *usize,
    start: usize,
    keyword: []const u8,
    keyword_kind: Kind,
) Kind {
    if (start + keyword.len > source.len or
        !std.mem.eql(u8, source[start .. start + keyword.len], keyword))
    {
        return finish(pos, start + 1, .identifier);
    }

    const end = start + keyword.len;
    if (end == source.len) return finish(pos, end, keyword_kind);

    const next_byte = source[end];
    if (next_byte < 0x80) {
        return finish(
            pos,
            end,
            if (unicode.isAsciiIdentifierPartByte(next_byte)) .identifier else keyword_kind,
        );
    }

    const decoded = decodeAt(source, end) orelse return finish(pos, end, .unsupported);
    return finish(
        pos,
        end,
        if (unicode.isIdentifierContinue(decoded.codepoint)) .identifier else keyword_kind,
    );
}

fn decodeAt(source: []const u8, start: usize) ?Decoded {
    const width = std.unicode.utf8ByteSequenceLength(source[start]) catch return null;
    if (start + width > source.len) return null;
    const codepoint = std.unicode.utf8Decode(source[start .. start + width]) catch return null;
    return .{ .codepoint = codepoint, .width = width };
}

fn finish(pos: *usize, next_pos: usize, kind: Kind) Kind {
    pos.* = next_pos;
    return kind;
}

test "simple token recognizes module and arrow lookahead without ownership" {
    var pos: usize = 0;
    try std.testing.expectEqual(Kind.import_keyword, next("/* lead */ import x", &pos, false));
    try std.testing.expectEqual(Kind.identifier, next("/* lead */ import x", &pos, false));

    pos = 0;
    try std.testing.expectEqual(Kind.export_keyword, next("\xEF\xBB\xBFexport{}", &pos, false));

    pos = 0;
    try std.testing.expectEqual(Kind.arrow, next(" /* same line */ =>", &pos, true));
    pos = 0;
    try std.testing.expectEqual(Kind.line_terminator, next(" /* line\n break */ =>", &pos, true));
    pos = 0;
    try std.testing.expectEqual(Kind.line_terminator, next(" // comment", &pos, true));
}

test "simple token keeps Unicode and malformed trivia on audited paths" {
    var pos: usize = 0;
    try std.testing.expectEqual(Kind.line_terminator, next("\xE2\x80\xA8=>", &pos, true));

    pos = 0;
    try std.testing.expectEqual(Kind.arrow, next("\xC2\xA0=>", &pos, true));

    pos = 0;
    try std.testing.expectEqual(Kind.unsupported, next("/* \xCF\x80 */ =>", &pos, true));

    pos = 0;
    try std.testing.expectEqual(Kind.unsupported, next("/* unterminated", &pos, true));

    pos = 0;
    try std.testing.expectEqual(Kind.identifier, next("import\xCF\x80", &pos, false));

    pos = 0;
    try std.testing.expectEqual(Kind.export_keyword, next("// \xCF\x80\xE2\x80\xA8export {}", &pos, false));
}

test "paren arrow scanner decides context-free ASCII heads" {
    try std.testing.expectEqual(true, parenArrowAfterOpen("(a, (b + c)) => a", 1));
    try std.testing.expectEqual(true, parenArrowAfterOpen("(a = ')', /* ) */ b) => b", 1));
    try std.testing.expectEqual(true, parenArrowAfterOpen("(a // )\n) => a", 1));
    try std.testing.expectEqual(true, parenArrowAfterOpen("(a / b) => a", 1));
    try std.testing.expectEqual(true, parenArrowAfterOpen("(a = /\\)/) => a", 1));
    try std.testing.expectEqual(true, parenArrowAfterOpen("(a = /[()]/) => a", 1));
    try std.testing.expectEqual(true, parenArrowAfterOpen("(a = '\xCF\x80)') => a", 1));
    try std.testing.expectEqual(false, parenArrowAfterOpen("(a + (b)) * c", 1));
    try std.testing.expectEqual(false, parenArrowAfterOpen("(a / b) + c", 1));
    try std.testing.expectEqual(false, parenArrowAfterOpen("(function(){ return /\\)/.test(')'); })()", 1));
    try std.testing.expectEqual(false, parenArrowAfterOpen("(a)\n=> a", 1));
    try std.testing.expectEqual(false, parenArrowAfterOpen("(unterminated", 1));
}

test "paren arrow scanner defers context-sensitive source" {
    try std.testing.expectEqual(@as(?bool, null), parenArrowAfterOpen("(`/\\)/`) => 1", 1));
    try std.testing.expectEqual(@as(?bool, null), parenArrowAfterOpen("(a\\u0062) => a", 1));
    try std.testing.expectEqual(@as(?bool, null), parenArrowAfterOpen("(\xCF\x80) => 1", 1));
    try std.testing.expectEqual(@as(?bool, null), parenArrowAfterOpen("(a = '\xE2\x80\xA8') => a", 1));
    try std.testing.expectEqual(@as(?bool, null), parenArrowAfterOpen("(a // \xCF\x80\xE2\x80\xA8) => a", 1));
    try std.testing.expectEqual(@as(?bool, null), parenArrowAfterOpen("(a <!-- )\n) => a", 1));
}

test "borrowed balanced scanner preserves QuickJS topology bits" {
    const pattern = balancedAfterOpen("[a, { b: /}/ }, ...rest] = rhs", 1, '[', false).?;
    try std.testing.expect(pattern.closed);
    try std.testing.expectEqual(BalancedFollowing.assignment, pattern.following);
    try std.testing.expect(pattern.has_top_level_ellipsis);
    try std.testing.expect(!pattern.has_assignment);

    const params = balancedAfterOpen("(a, b = (c = 1)) {", 1, '(', false).?;
    try std.testing.expect(params.closed);
    try std.testing.expectEqual(BalancedFollowing.other, params.following);
    try std.testing.expect(params.has_assignment);

    const traditional_for = balancedAfterOpen("(i = 0; i < n; i++) body", 1, '(', false).?;
    try std.testing.expect(traditional_for.has_top_level_semicolon);
    try std.testing.expect(traditional_for.has_assignment);

    const equality = balancedAfterOpen("{} == rhs", 1, '{', false).?;
    try std.testing.expect(equality.closed);
    try std.testing.expectEqual(BalancedFollowing.other, equality.following);

    const strict_equality = balancedAfterOpen("[] === rhs", 1, '[', false).?;
    try std.testing.expect(strict_equality.closed);
    try std.testing.expectEqual(BalancedFollowing.other, strict_equality.following);
}

test "borrowed balanced scanner matches delimiters and falls back conservatively" {
    const nested = balancedAfterOpen("{ a: [')', /]/] }, next", 1, '{', false).?;
    try std.testing.expect(nested.closed);
    try std.testing.expectEqual(BalancedFollowing.comma, nested.following);

    const mismatched = balancedAfterOpen("[a, b} = rhs", 1, '[', false).?;
    try std.testing.expect(!mismatched.closed);

    try std.testing.expectEqual(
        @as(?BalancedScan, null),
        balancedAfterOpen("[`template`] = rhs", 1, '[', false),
    );
    try std.testing.expectEqual(
        @as(?BalancedScan, null),
        balancedAfterOpen("[a\\u0062] = rhs", 1, '[', false),
    );
}

test "regexp context keyword dispatch matches QuickJS skip-parens classes" {
    const allowed = [_][]const u8{
        "if",     "else",    "return",   "var",      "delete",
        "void",   "typeof",  "new",      "in",       "instanceof",
        "do",     "while",   "for",      "break",    "continue",
        "switch", "case",    "default",  "throw",    "try",
        "catch",  "finally", "function", "debugger", "with",
        "class",  "const",   "enum",     "export",   "extends",
        "import", "super",   "of",       "yield",
    };
    for (allowed) |word| try std.testing.expectEqual(RegexpContext.allowed, identifierRegexpContext(word));

    const mode_dependent = [_][]const u8{
        "implements", "interface", "let",    "package", "private",
        "protected",  "public",    "static", "await",
    };
    for (mode_dependent) |word| try std.testing.expectEqual(RegexpContext.mode_dependent, identifierRegexpContext(word));

    const disallowed = [_][]const u8{ "null", "false", "true", "this", "a", "async", "returns" };
    for (disallowed) |word| try std.testing.expectEqual(RegexpContext.disallowed, identifierRegexpContext(word));
}

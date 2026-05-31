//! zjs engine frontend layer: TypeScript erasure before QuickJS parsing.
//! See docs/fun_zjs_subtree_architecture.md §3-§4.

const std = @import("std");

pub const SourceKind = enum {
    auto,
    javascript,
    typescript,
};

const TokenKind = enum {
    identifier,
    number,
    string,
    template,
    regexp,
    punct,
};

const Token = struct {
    kind: TokenKind,
    start: usize,
    end: usize,

    fn text(self: Token, source: []const u8) []const u8 {
        return source[self.start..self.end];
    }
};

const Range = struct {
    start: usize,
    end: usize,
};

pub fn shouldStrip(kind: SourceKind, filename: []const u8) bool {
    return switch (kind) {
        .typescript => true,
        .javascript => false,
        .auto => isTypeScriptPath(filename),
    };
}

pub fn isTypeScriptPath(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".ts") or
        std.mem.endsWith(u8, path, ".mts") or
        std.mem.endsWith(u8, path, ".cts") or
        std.mem.endsWith(u8, path, ".tsx");
}

pub fn strip(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    var tokens = std.ArrayList(Token).empty;
    defer tokens.deinit(allocator);
    try tokenize(allocator, source, &tokens);

    var ranges = std.ArrayList(Range).empty;
    defer ranges.deinit(allocator);

    try markTypeOnlyStatements(allocator, source, tokens.items, &ranges);
    try markMixedTypeSpecifiers(allocator, source, tokens.items, &ranges);
    try markClassAndTypeModifiers(allocator, source, tokens.items, &ranges);
    try markImplementsClauses(allocator, source, tokens.items, &ranges);
    try markTypeParameters(allocator, source, tokens.items, &ranges);
    try markTypeAnnotations(allocator, source, tokens.items, &ranges);
    try markTypeAssertions(allocator, source, tokens.items, &ranges);
    try markNonNullAssertions(allocator, source, tokens.items, &ranges);

    return renderWithoutRanges(allocator, source, ranges.items);
}

fn tokenize(allocator: std.mem.Allocator, source: []const u8, tokens: *std.ArrayList(Token)) !void {
    var i: usize = 0;
    var prev_sig: ?Token = null;
    while (i < source.len) {
        const c = source[i];
        if (std.ascii.isWhitespace(c)) {
            i += 1;
            continue;
        }
        if (c == '/' and i + 1 < source.len and source[i + 1] == '/') {
            i = skipLineComment(source, i + 2);
            continue;
        }
        if (c == '/' and i + 1 < source.len and source[i + 1] == '*') {
            i = skipBlockComment(source, i + 2);
            continue;
        }

        const start = i;
        const token = if (isIdentStart(c)) blk: {
            i += 1;
            while (i < source.len and isIdentContinue(source[i])) i += 1;
            break :blk Token{ .kind = .identifier, .start = start, .end = i };
        } else if (std.ascii.isDigit(c)) blk: {
            i = skipNumber(source, i);
            break :blk Token{ .kind = .number, .start = start, .end = i };
        } else if (c == '\'' or c == '"') blk: {
            i = skipQuoted(source, i, c);
            break :blk Token{ .kind = .string, .start = start, .end = i };
        } else if (c == '`') blk: {
            i = skipTemplate(source, i);
            break :blk Token{ .kind = .template, .start = start, .end = i };
        } else if (c == '/' and canStartRegExp(prev_sig, source)) blk: {
            i = skipRegExp(source, i);
            break :blk Token{ .kind = .regexp, .start = start, .end = i };
        } else blk: {
            i += punctuatorLen(source[i..]);
            break :blk Token{ .kind = .punct, .start = start, .end = i };
        };

        try tokens.append(allocator, token);
        prev_sig = token;
    }
}

fn skipLineComment(source: []const u8, start: usize) usize {
    var i = start;
    while (i < source.len and source[i] != '\n' and source[i] != '\r') i += 1;
    return i;
}

fn skipBlockComment(source: []const u8, start: usize) usize {
    var i = start;
    while (i + 1 < source.len and !(source[i] == '*' and source[i + 1] == '/')) i += 1;
    return if (i + 1 < source.len) i + 2 else source.len;
}

fn skipQuoted(source: []const u8, start: usize, quote: u8) usize {
    var i = start + 1;
    var escaped = false;
    while (i < source.len) : (i += 1) {
        const c = source[i];
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
    return source.len;
}

fn skipTemplate(source: []const u8, start: usize) usize {
    var i = start + 1;
    var escaped = false;
    while (i < source.len) : (i += 1) {
        const c = source[i];
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
    return source.len;
}

fn skipRegExp(source: []const u8, start: usize) usize {
    var i = start + 1;
    var escaped = false;
    var in_class = false;
    while (i < source.len) : (i += 1) {
        const c = source[i];
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
            while (i < source.len and isIdentContinue(source[i])) i += 1;
            return i;
        }
        if (c == '\n' or c == '\r') return i;
    }
    return source.len;
}

fn skipNumber(source: []const u8, start: usize) usize {
    var i = start;
    while (i < source.len) {
        const c = source[i];
        if (std.ascii.isAlphanumeric(c) or c == '_' or c == '.') {
            i += 1;
            continue;
        }
        break;
    }
    return i;
}

fn punctuatorLen(rest: []const u8) usize {
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

fn canStartRegExp(prev: ?Token, source: []const u8) bool {
    const token = prev orelse return true;
    const text = token.text(source);
    if (token.kind == .identifier) {
        return textEql(text, "return") or textEql(text, "throw") or textEql(text, "case") or
            textEql(text, "delete") or textEql(text, "void") or textEql(text, "typeof") or
            textEql(text, "yield") or textEql(text, "await") or textEql(text, "in") or
            textEql(text, "of") or textEql(text, "instanceof");
    }
    if (token.kind != .punct) return false;
    return textEql(text, "(") or textEql(text, "{") or textEql(text, "[") or
        textEql(text, ",") or textEql(text, ";") or textEql(text, ":") or
        textEql(text, "=") or textEql(text, "=>") or textEql(text, "!") or
        textEql(text, "?") or textEql(text, "&&") or textEql(text, "||") or
        textEql(text, "??") or textEql(text, "+") or textEql(text, "-") or
        textEql(text, "*") or textEql(text, "/") or textEql(text, "%") or
        textEql(text, "~");
}

fn markTypeOnlyStatements(
    allocator: std.mem.Allocator,
    source: []const u8,
    tokens: []const Token,
    ranges: *std.ArrayList(Range),
) !void {
    var i: usize = 0;
    while (i < tokens.len) : (i += 1) {
        const text = tokens[i].text(source);
        if (textEql(text, "import") and tokenTextEql(source, tokens, i + 1, "type")) {
            try addRange(ranges, allocator, tokens[i].start, findStatementEnd(source, tokens, i));
            continue;
        }
        if (textEql(text, "export")) {
            if (tokenTextEql(source, tokens, i + 1, "type")) {
                try addRange(ranges, allocator, tokens[i].start, findStatementEnd(source, tokens, i));
                continue;
            }
            if (tokenTextEql(source, tokens, i + 1, "interface")) {
                try addInterfaceRange(allocator, source, tokens, ranges, i, i + 1);
                continue;
            }
            if (tokenTextEql(source, tokens, i + 1, "declare")) {
                try addDeclareRange(allocator, source, tokens, ranges, i, i + 1);
                continue;
            }
        }
        if (textEql(text, "declare")) {
            try addDeclareRange(allocator, source, tokens, ranges, i, i);
            continue;
        }
        if (textEql(text, "interface") and isStatementStart(source, tokens, i)) {
            try addInterfaceRange(allocator, source, tokens, ranges, i, i);
            continue;
        }
        if (textEql(text, "type") and isStatementStart(source, tokens, i) and looksLikeTypeAlias(source, tokens, i)) {
            try addRange(ranges, allocator, tokens[i].start, findStatementEnd(source, tokens, i));
            continue;
        }
    }
}

fn addDeclareRange(
    allocator: std.mem.Allocator,
    source: []const u8,
    tokens: []const Token,
    ranges: *std.ArrayList(Range),
    range_start_idx: usize,
    declare_idx: usize,
) !void {
    if (tokenTextEql(source, tokens, declare_idx + 1, "interface")) {
        try addInterfaceRange(allocator, source, tokens, ranges, range_start_idx, declare_idx + 1);
        return;
    }

    var end = findStatementEnd(source, tokens, declare_idx);
    var j = declare_idx + 1;
    while (j < tokens.len and tokens[j].start < end) : (j += 1) {
        if (tokenTextEql(source, tokens, j, "{")) {
            if (findMatchingForward(source, tokens, j, "{", "}")) |close_idx| {
                end = tokens[close_idx].end;
                if (close_idx + 1 < tokens.len and tokenTextEql(source, tokens, close_idx + 1, ";")) {
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
    source: []const u8,
    tokens: []const Token,
    ranges: *std.ArrayList(Range),
    range_start_idx: usize,
    interface_idx: usize,
) !void {
    var end = findStatementEnd(source, tokens, interface_idx);
    var j = interface_idx + 1;
    while (j < tokens.len and tokens[j].start < end) : (j += 1) {
        if (tokenTextEql(source, tokens, j, "{")) {
            if (findMatchingForward(source, tokens, j, "{", "}")) |close_idx| {
                end = tokens[close_idx].end;
                if (close_idx + 1 < tokens.len and tokenTextEql(source, tokens, close_idx + 1, ";")) {
                    end = tokens[close_idx + 1].end;
                }
            }
            break;
        }
    }
    try addRange(ranges, allocator, tokens[range_start_idx].start, end);
}

fn looksLikeTypeAlias(source: []const u8, tokens: []const Token, type_idx: usize) bool {
    var depth: usize = 0;
    var i = type_idx + 1;
    while (i < tokens.len) : (i += 1) {
        const text = tokens[i].text(source);
        if (textEql(text, "{") or textEql(text, "(") or textEql(text, "[")) {
            depth += 1;
        } else if (textEql(text, "}") or textEql(text, ")") or textEql(text, "]")) {
            if (depth == 0) return false;
            depth -= 1;
        } else if (depth == 0 and textEql(text, "=")) {
            return true;
        } else if (depth == 0 and (textEql(text, ";") or hasLineBreakBetween(source, tokens[type_idx].end, tokens[i].start))) {
            return false;
        }
    }
    return false;
}

fn markMixedTypeSpecifiers(
    allocator: std.mem.Allocator,
    source: []const u8,
    tokens: []const Token,
    ranges: *std.ArrayList(Range),
) !void {
    var i: usize = 0;
    while (i < tokens.len) : (i += 1) {
        if (!tokenTextEql(source, tokens, i, "import") and !tokenTextEql(source, tokens, i, "export")) continue;
        if (tokenTextEql(source, tokens, i + 1, "type")) continue;
        const stmt_end = findStatementEnd(source, tokens, i);
        const open_idx = findTokenBeforeOffset(source, tokens, i + 1, stmt_end, "{") orelse continue;
        const close_idx = findMatchingForward(source, tokens, open_idx, "{", "}") orelse continue;
        if (tokens[close_idx].end > stmt_end) continue;

        var spec_count: usize = 0;
        var type_spec_count: usize = 0;
        var segment_start = open_idx + 1;
        while (segment_start < close_idx) {
            while (segment_start < close_idx and tokenTextEql(source, tokens, segment_start, ",")) segment_start += 1;
            if (segment_start >= close_idx) break;
            var segment_end = segment_start;
            while (segment_end < close_idx and !tokenTextEql(source, tokens, segment_end, ",")) segment_end += 1;
            spec_count += 1;
            if (tokenTextEql(source, tokens, segment_start, "type")) {
                type_spec_count += 1;
                const remove_start = if (segment_start > open_idx + 1 and tokenTextEql(source, tokens, segment_start - 1, ","))
                    tokens[segment_start - 1].start
                else
                    tokens[segment_start].start;
                const remove_end = if (segment_end < close_idx and tokenTextEql(source, tokens, segment_end, ","))
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
    source: []const u8,
    tokens: []const Token,
    ranges: *std.ArrayList(Range),
) !void {
    for (tokens, 0..) |tok, i| {
        const text = tok.text(source);
        if (!isTsModifier(text)) continue;
        if (isConstructorParameterPropertyModifier(source, tokens, i)) {
            return error.SyntaxError;
        }
        if (textEql(text, "abstract") and tokenTextEql(source, tokens, i + 1, "class")) {
            try addRange(ranges, allocator, tok.start, tok.end);
            continue;
        }
        if (modifierCanAppearHere(source, tokens, i)) {
            try addRange(ranges, allocator, tok.start, tok.end);
        }
    }
}

fn isTsModifier(text: []const u8) bool {
    return textEql(text, "public") or textEql(text, "private") or textEql(text, "protected") or
        textEql(text, "readonly") or textEql(text, "override") or textEql(text, "abstract");
}

fn isConstructorParameterPropertyModifier(source: []const u8, tokens: []const Token, idx: usize) bool {
    const text = tokens[idx].text(source);
    if (!textEql(text, "public") and !textEql(text, "private") and !textEql(text, "protected") and !textEql(text, "readonly")) {
        return false;
    }

    const prev = if (idx == 0) "" else tokens[idx - 1].text(source);
    if (!textEql(prev, "(") and !textEql(prev, ",")) return false;

    if (idx + 1 >= tokens.len) return false;
    const next = tokens[idx + 1].text(source);
    if (textEql(next, ":") or textEql(next, ")") or textEql(next, "=") or textEql(next, ",")) return false;

    const open_idx = findEnclosingOpen(source, tokens, idx) orelse return false;
    return open_idx > 0 and tokenTextEql(source, tokens, open_idx, "(") and tokenTextEql(source, tokens, open_idx - 1, "constructor");
}

fn modifierCanAppearHere(source: []const u8, tokens: []const Token, idx: usize) bool {
    const prev = if (idx == 0) null else tokens[idx - 1].text(source);
    const next = if (idx + 1 < tokens.len) tokens[idx + 1].text(source) else "";
    if (textEql(next, "(") or textEql(next, ":") or textEql(next, "=") or textEql(next, ";")) return false;
    if (prev) |p| {
        return textEql(p, "{") or textEql(p, "(") or textEql(p, ",") or textEql(p, ";");
    }
    return true;
}

fn markImplementsClauses(
    allocator: std.mem.Allocator,
    source: []const u8,
    tokens: []const Token,
    ranges: *std.ArrayList(Range),
) !void {
    for (tokens, 0..) |tok, i| {
        if (!textEql(tok.text(source), "implements")) continue;
        var j = i + 1;
        while (j < tokens.len) : (j += 1) {
            if (tokenTextEql(source, tokens, j, "{")) {
                try addRange(ranges, allocator, tok.start, tokens[j].start);
                break;
            }
            if (tokenTextEql(source, tokens, j, ";")) break;
        }
    }
}

fn markTypeParameters(
    allocator: std.mem.Allocator,
    source: []const u8,
    tokens: []const Token,
    ranges: *std.ArrayList(Range),
) !void {
    for (tokens, 0..) |tok, i| {
        if (!textEql(tok.text(source), "<")) continue;
        const close_idx = findTypeAngleEnd(source, tokens, i) orelse continue;
        if (close_idx + 1 >= tokens.len) continue;
        const next = tokens[close_idx + 1].text(source);
        if (!textEql(next, "(") and !textEql(next, "{") and !textEql(next, "extends") and !textEql(next, "implements")) continue;
        if (!looksLikeTypeParameterStart(source, tokens, i)) continue;
        try addRange(ranges, allocator, tok.start, tokens[close_idx].end);
    }
}

fn looksLikeTypeParameterStart(source: []const u8, tokens: []const Token, lt_idx: usize) bool {
    if (lt_idx == 0 or lt_idx + 1 >= tokens.len) return false;
    const prev = tokens[lt_idx - 1].text(source);
    if (textEql(prev, ">") or textEql(prev, ")") or textEql(prev, "]") or textEql(prev, ".")) return true;
    if (tokens[lt_idx - 1].kind == .identifier) return true;
    if (textEql(prev, "=") or textEql(prev, "(") or textEql(prev, ",")) return true;
    return false;
}

fn markTypeAnnotations(
    allocator: std.mem.Allocator,
    source: []const u8,
    tokens: []const Token,
    ranges: *std.ArrayList(Range),
) !void {
    for (tokens, 0..) |tok, i| {
        if (!textEql(tok.text(source), ":")) continue;
        if (!isTypeAnnotationColon(source, tokens, i)) continue;
        const stop_arrow = i > 0 and tokenTextEql(source, tokens, i - 1, ")");
        const end_idx = findTypeEnd(source, tokens, i + 1, stop_arrow) orelse tokens.len;
        const start = if (i > 0 and tokenTextEql(source, tokens, i - 1, "?")) tokens[i - 1].start else tok.start;
        const end = if (end_idx < tokens.len) tokens[end_idx].start else source.len;
        if (end > start) try addRange(ranges, allocator, start, end);
    }
}

fn isTypeAnnotationColon(source: []const u8, tokens: []const Token, colon_idx: usize) bool {
    if (colon_idx == 0 or colon_idx + 1 >= tokens.len) return false;
    if (hasUnmatchedTernaryQuestionBefore(source, tokens, colon_idx)) return false;

    const prev_idx = if (tokenTextEql(source, tokens, colon_idx - 1, "?")) blk: {
        if (colon_idx < 2) return false;
        break :blk colon_idx - 2;
    } else colon_idx - 1;
    if (prev_idx >= tokens.len) return false;
    const prev = tokens[prev_idx].text(source);
    if (textEql(prev, ")")) return true;

    const enclosing = findEnclosingOpen(source, tokens, colon_idx);
    if (enclosing) |open_idx| {
        const open = tokens[open_idx].text(source);
        if (textEql(open, "(")) return isParameterList(source, tokens, open_idx);
        if (textEql(open, "{")) return braceBelongsToClass(source, tokens, open_idx) and classFieldSegmentAllowsType(source, tokens, open_idx, colon_idx);
        return false;
    }

    return isVariableDeclarationType(source, tokens, colon_idx);
}

fn isParameterList(source: []const u8, tokens: []const Token, open_idx: usize) bool {
    const close_idx = findMatchingForward(source, tokens, open_idx, "(", ")") orelse return false;
    const before = if (open_idx == 0) "" else tokens[open_idx - 1].text(source);
    const after = if (close_idx + 1 < tokens.len) tokens[close_idx + 1].text(source) else "";
    if (isControlKeyword(before)) return false;
    if (textEql(before, "function") or textEql(before, "constructor")) return true;
    if (open_idx >= 2 and tokens[open_idx - 1].kind == .identifier and tokenTextEql(source, tokens, open_idx - 2, "function")) return true;
    if (open_idx > 0 and tokens[open_idx - 1].kind == .identifier and (textEql(after, "{") or textEql(after, "=>"))) return true;
    if (open_idx > 0 and tokens[open_idx - 1].kind == .identifier and textEql(after, ":")) {
        return returnTypeAfterParameterListLeadsToBody(source, tokens, close_idx);
    }
    if (textEql(after, "=>")) return true;
    return false;
}

fn returnTypeAfterParameterListLeadsToBody(source: []const u8, tokens: []const Token, close_idx: usize) bool {
    if (!tokenTextEql(source, tokens, close_idx + 1, ":")) return false;
    const end_idx = findTypeEnd(source, tokens, close_idx + 2, true) orelse return false;
    return tokenTextEql(source, tokens, end_idx, "{") or tokenTextEql(source, tokens, end_idx, "=>");
}

fn isControlKeyword(text: []const u8) bool {
    return textEql(text, "if") or textEql(text, "for") or textEql(text, "while") or
        textEql(text, "switch") or textEql(text, "with") or textEql(text, "catch");
}

fn isVariableDeclarationType(source: []const u8, tokens: []const Token, colon_idx: usize) bool {
    var stmt_start: usize = 0;
    var i = colon_idx;
    while (i > 0) {
        i -= 1;
        const text = tokens[i].text(source);
        if (textEql(text, ";") or textEql(text, "{") or textEql(text, "}")) {
            stmt_start = i + 1;
            break;
        }
    }

    var saw_decl = false;
    var last_comma_or_decl = stmt_start;
    i = stmt_start;
    while (i < colon_idx) : (i += 1) {
        const text = tokens[i].text(source);
        if (textEql(text, "let") or textEql(text, "const") or textEql(text, "var")) {
            saw_decl = true;
            last_comma_or_decl = i + 1;
        } else if (textEql(text, ",")) {
            last_comma_or_decl = i + 1;
        }
    }
    if (!saw_decl) return false;

    i = last_comma_or_decl;
    while (i < colon_idx) : (i += 1) {
        if (tokenTextEql(source, tokens, i, "=")) return false;
    }
    return true;
}

fn classFieldSegmentAllowsType(source: []const u8, tokens: []const Token, class_open_idx: usize, colon_idx: usize) bool {
    var start = class_open_idx + 1;
    var i = colon_idx;
    while (i > class_open_idx + 1) {
        i -= 1;
        if (tokenTextEql(source, tokens, i, ";") or tokenTextEql(source, tokens, i, "{") or tokenTextEql(source, tokens, i, "}")) {
            start = i + 1;
            break;
        }
    }
    i = start;
    while (i < colon_idx) : (i += 1) {
        if (tokenTextEql(source, tokens, i, "=")) return false;
    }
    return true;
}

fn markTypeAssertions(
    allocator: std.mem.Allocator,
    source: []const u8,
    tokens: []const Token,
    ranges: *std.ArrayList(Range),
) !void {
    for (tokens, 0..) |tok, i| {
        const text = tok.text(source);
        if (!textEql(text, "as") and !textEql(text, "satisfies")) continue;
        if (insideImportOrExportStatement(source, tokens, i)) continue;
        if (!isTypeAssertionOperator(source, tokens, i)) continue;
        const end_idx = findTypeAssertionEnd(source, tokens, i + 1) orelse tokens.len;
        const end = if (end_idx < tokens.len) tokens[end_idx].start else source.len;
        if (end > tok.start) try addRange(ranges, allocator, tok.start, end);
    }
}

fn markNonNullAssertions(
    allocator: std.mem.Allocator,
    source: []const u8,
    tokens: []const Token,
    ranges: *std.ArrayList(Range),
) !void {
    for (tokens, 0..) |tok, i| {
        if (!textEql(tok.text(source), "!")) continue;
        if (i == 0 or i + 1 >= tokens.len) continue;
        const prev = tokens[i - 1].text(source);
        const next = tokens[i + 1].text(source);
        const prev_can_end_expr = tokens[i - 1].kind == .identifier or tokens[i - 1].kind == .number or
            tokens[i - 1].kind == .string or textEql(prev, ")") or textEql(prev, "]");
        if (!prev_can_end_expr) continue;
        if (textEql(next, "=") or textEql(next, "==") or textEql(next, "===")) continue;
        try addRange(ranges, allocator, tok.start, tok.end);
    }
}

fn isTypeAssertionOperator(source: []const u8, tokens: []const Token, idx: usize) bool {
    if (idx == 0 or idx + 1 >= tokens.len) return false;
    if (!previousTokenCanEndExpression(source, tokens[idx - 1])) return false;

    const next = tokens[idx + 1].text(source);
    if (textEql(next, ":") or textEql(next, ",") or textEql(next, ";") or textEql(next, ")") or textEql(next, "}") or textEql(next, "=")) {
        return false;
    }

    return true;
}

fn previousTokenCanEndExpression(source: []const u8, token: Token) bool {
    return switch (token.kind) {
        .identifier => identifierCanEndExpression(token.text(source)),
        .number, .string, .template, .regexp => true,
        .punct => {
            const text = token.text(source);
            return textEql(text, ")") or textEql(text, "]") or textEql(text, "}");
        },
    };
}

fn identifierCanEndExpression(text: []const u8) bool {
    return !textEql(text, "const") and !textEql(text, "let") and !textEql(text, "var") and
        !textEql(text, "function") and !textEql(text, "class") and !textEql(text, "return") and
        !textEql(text, "throw") and !textEql(text, "case") and !textEql(text, "delete") and
        !textEql(text, "typeof") and !textEql(text, "void") and !textEql(text, "new") and
        !textEql(text, "in") and !textEql(text, "instanceof") and !textEql(text, "yield") and
        !textEql(text, "await");
}

fn findTypeEnd(source: []const u8, tokens: []const Token, start_idx: usize, stop_arrow: bool) ?usize {
    var paren: usize = 0;
    var bracket: usize = 0;
    var brace: usize = 0;
    var angle: usize = 0;
    var i = start_idx;
    while (i < tokens.len) : (i += 1) {
        const text = tokens[i].text(source);
        if (textEql(text, "(")) paren += 1 else if (textEql(text, ")")) {
            if (paren == 0 and bracket == 0 and brace == 0 and angle == 0) return i;
            paren -|= 1;
        } else if (textEql(text, "[")) bracket += 1 else if (textEql(text, "]")) {
            if (bracket == 0 and paren == 0 and brace == 0 and angle == 0) return i;
            bracket -|= 1;
        } else if (textEql(text, "{")) {
            if (i == start_idx or brace > 0 or paren > 0 or bracket > 0 or angle > 0) {
                brace += 1;
            } else {
                return i;
            }
        } else if (textEql(text, "}")) {
            if (brace == 0 and paren == 0 and bracket == 0 and angle == 0) return i;
            brace -|= 1;
        } else if (textEql(text, "<")) {
            angle += 1;
        } else if (textEql(text, ">")) {
            if (angle > 0) angle -= 1;
        } else if (paren == 0 and bracket == 0 and brace == 0 and angle == 0) {
            if (textEql(text, ",") or textEql(text, ";") or textEql(text, "=")) return i;
            if (stop_arrow and textEql(text, "=>")) return i;
        }
    }
    return null;
}

fn findTypeAssertionEnd(source: []const u8, tokens: []const Token, start_idx: usize) ?usize {
    var paren: usize = 0;
    var bracket: usize = 0;
    var brace: usize = 0;
    var angle: usize = 0;
    var i = start_idx;
    while (i < tokens.len) : (i += 1) {
        const text = tokens[i].text(source);
        if (textEql(text, "(")) paren += 1 else if (textEql(text, ")")) {
            if (paren == 0 and bracket == 0 and brace == 0 and angle == 0) return i;
            paren -|= 1;
        } else if (textEql(text, "[")) bracket += 1 else if (textEql(text, "]")) {
            if (bracket == 0 and paren == 0 and brace == 0 and angle == 0) return i;
            bracket -|= 1;
        } else if (textEql(text, "{")) brace += 1 else if (textEql(text, "}")) {
            if (brace == 0 and paren == 0 and bracket == 0 and angle == 0) return i;
            brace -|= 1;
        } else if (textEql(text, "<")) {
            angle += 1;
        } else if (textEql(text, ">")) {
            if (angle > 0) angle -= 1;
        } else if (paren == 0 and bracket == 0 and brace == 0 and angle == 0 and isExpressionDelimiter(text)) {
            return i;
        }
    }
    return null;
}

fn isExpressionDelimiter(text: []const u8) bool {
    return textEql(text, ",") or textEql(text, ";") or textEql(text, ":") or textEql(text, "?") or
        textEql(text, "}") or textEql(text, "=>") or textEql(text, "||") or textEql(text, "&&") or
        textEql(text, "??") or textEql(text, "+") or textEql(text, "-") or textEql(text, "*") or
        textEql(text, "/") or textEql(text, "%") or textEql(text, "==") or textEql(text, "===") or
        textEql(text, "!=") or textEql(text, "!==") or textEql(text, "<=") or textEql(text, ">=") or
        textEql(text, "=");
}

fn findTypeAngleEnd(source: []const u8, tokens: []const Token, lt_idx: usize) ?usize {
    var depth: usize = 0;
    var i = lt_idx;
    while (i < tokens.len) : (i += 1) {
        const text = tokens[i].text(source);
        if (textEql(text, "<")) {
            depth += 1;
        } else if (textEql(text, ">")) {
            depth -|= 1;
            if (depth == 0) return i;
        } else if (depth == 1 and (textEql(text, ";") or textEql(text, "{") or textEql(text, "}"))) {
            return null;
        }
    }
    return null;
}

fn findStatementEnd(source: []const u8, tokens: []const Token, start_idx: usize) usize {
    var paren: usize = 0;
    var bracket: usize = 0;
    var brace: usize = 0;
    var i = start_idx;
    while (i < tokens.len) : (i += 1) {
        const text = tokens[i].text(source);
        if (textEql(text, "(")) paren += 1 else if (textEql(text, ")")) paren -|= 1 else if (textEql(text, "[")) bracket += 1 else if (textEql(text, "]")) bracket -|= 1 else if (textEql(text, "{")) brace += 1 else if (textEql(text, "}")) {
            if (brace == 0 and paren == 0 and bracket == 0) return tokens[i].end;
            brace -|= 1;
        }
        if (paren == 0 and bracket == 0 and brace == 0) {
            if (textEql(text, ";")) return tokens[i].end;
            if (i + 1 < tokens.len and hasLineBreakBetween(source, tokens[i].end, tokens[i + 1].start) and !continuesAcrossLine(text)) {
                return tokens[i].end;
            }
        }
    }
    return source.len;
}

fn continuesAcrossLine(text: []const u8) bool {
    return textEql(text, ",") or textEql(text, "=") or textEql(text, "|") or textEql(text, "&") or
        textEql(text, "?") or textEql(text, ":") or textEql(text, "extends") or textEql(text, "(") or
        textEql(text, "{") or textEql(text, "[");
}

fn findMatchingForward(source: []const u8, tokens: []const Token, open_idx: usize, open_text: []const u8, close_text: []const u8) ?usize {
    var depth: usize = 0;
    var i = open_idx;
    while (i < tokens.len) : (i += 1) {
        const text = tokens[i].text(source);
        if (textEql(text, open_text)) {
            depth += 1;
        } else if (textEql(text, close_text)) {
            depth -|= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

fn findEnclosingOpen(source: []const u8, tokens: []const Token, idx: usize) ?usize {
    var paren: usize = 0;
    var bracket: usize = 0;
    var brace: usize = 0;
    var i = idx;
    while (i > 0) {
        i -= 1;
        const text = tokens[i].text(source);
        if (textEql(text, ")")) paren += 1 else if (textEql(text, "]")) bracket += 1 else if (textEql(text, "}")) brace += 1 else if (textEql(text, "(")) {
            if (paren == 0) return i;
            paren -= 1;
        } else if (textEql(text, "[")) {
            if (bracket == 0) return i;
            bracket -= 1;
        } else if (textEql(text, "{")) {
            if (brace == 0) return i;
            brace -= 1;
        }
    }
    return null;
}

fn braceBelongsToClass(source: []const u8, tokens: []const Token, open_idx: usize) bool {
    var i = open_idx;
    while (i > 0) {
        i -= 1;
        const text = tokens[i].text(source);
        if (textEql(text, "class")) return true;
        if (textEql(text, ";") or textEql(text, "{") or textEql(text, "}")) return false;
    }
    return false;
}

fn hasUnmatchedTernaryQuestionBefore(source: []const u8, tokens: []const Token, colon_idx: usize) bool {
    if (colon_idx > 0 and tokenTextEql(source, tokens, colon_idx - 1, "?")) return false;
    var paren: usize = 0;
    var bracket: usize = 0;
    var brace: usize = 0;
    var i = colon_idx;
    while (i > 0) {
        i -= 1;
        const text = tokens[i].text(source);
        if (textEql(text, ")")) paren += 1 else if (textEql(text, "]")) bracket += 1 else if (textEql(text, "}")) brace += 1 else if (textEql(text, "(")) {
            if (paren == 0) break;
            paren -= 1;
        } else if (textEql(text, "[")) {
            if (bracket == 0) break;
            bracket -= 1;
        } else if (textEql(text, "{")) {
            if (brace == 0) break;
            brace -= 1;
        } else if (paren == 0 and bracket == 0 and brace == 0 and textEql(text, "?")) {
            return true;
        } else if (paren == 0 and bracket == 0 and brace == 0 and (textEql(text, ";") or textEql(text, ","))) {
            break;
        }
    }
    return false;
}

fn insideImportOrExportStatement(source: []const u8, tokens: []const Token, idx: usize) bool {
    var stmt_start: usize = 0;
    var i = idx;
    while (i > 0) {
        i -= 1;
        if (tokenTextEql(source, tokens, i, ";")) {
            stmt_start = i + 1;
            break;
        }
    }

    var saw_import = false;
    var saw_export = false;
    var saw_equals = false;
    i = stmt_start;
    while (i < idx) : (i += 1) {
        const text = tokens[i].text(source);
        if (textEql(text, "import")) saw_import = true;
        if (textEql(text, "export")) saw_export = true;
        if (textEql(text, "=")) saw_equals = true;
    }

    if (saw_equals) return false;
    if (saw_import) return true;
    if (!saw_export) return false;
    if (findEnclosingOpen(source, tokens, idx)) |open_idx| {
        return tokenTextEql(source, tokens, open_idx, "{") and open_idx >= stmt_start;
    }
    i = stmt_start;
    while (i < idx) : (i += 1) {
        if (tokenTextEql(source, tokens, i, "*") or tokenTextEql(source, tokens, i, "from")) return true;
    }
    return false;
}

fn isStatementStart(source: []const u8, tokens: []const Token, idx: usize) bool {
    if (idx == 0) return true;
    const prev = tokens[idx - 1].text(source);
    return textEql(prev, ";") or textEql(prev, "{") or textEql(prev, "}");
}

fn findTokenBeforeOffset(source: []const u8, tokens: []const Token, start_idx: usize, end_offset: usize, needle: []const u8) ?usize {
    var i = start_idx;
    while (i < tokens.len and tokens[i].start < end_offset) : (i += 1) {
        if (textEql(tokens[i].text(source), needle)) return i;
    }
    return null;
}

fn hasLineBreakBetween(source: []const u8, start: usize, end: usize) bool {
    var i = start;
    while (i < end and i < source.len) : (i += 1) {
        if (source[i] == '\n' or source[i] == '\r') return true;
    }
    return false;
}

fn addRange(ranges: *std.ArrayList(Range), allocator: std.mem.Allocator, start: usize, end: usize) !void {
    if (end <= start) return;
    try ranges.append(allocator, .{ .start = start, .end = end });
}

fn renderWithoutRanges(allocator: std.mem.Allocator, source: []const u8, ranges: []Range) ![]u8 {
    std.mem.sort(Range, ranges, {}, rangeLessThan);
    var merged = std.ArrayList(Range).empty;
    defer merged.deinit(allocator);
    for (ranges) |range| {
        if (merged.items.len == 0 or range.start > merged.items[merged.items.len - 1].end) {
            try merged.append(allocator, range);
        } else if (range.end > merged.items[merged.items.len - 1].end) {
            merged.items[merged.items.len - 1].end = range.end;
        }
    }

    var output = try allocator.alloc(u8, source.len);
    @memcpy(output, source);
    for (merged.items) |range| {
        for (output[range.start..range.end], source[range.start..range.end]) |*out, original| {
            out.* = if (original == '\n' or original == '\r') original else ' ';
        }
    }
    return output;
}

fn rangeLessThan(_: void, a: Range, b: Range) bool {
    return a.start < b.start;
}

fn tokenTextEql(source: []const u8, tokens: []const Token, idx: usize, expected: []const u8) bool {
    return idx < tokens.len and textEql(tokens[idx].text(source), expected);
}

fn textEql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_' or c == '$' or c >= 0x80;
}

fn isIdentContinue(c: u8) bool {
    return isIdentStart(c) or std.ascii.isDigit(c);
}

test "strip removes variable and function TypeScript annotations" {
    const source =
        \\const x: number = 42;
        \\function add(a: number, b?: number): number { return a + (b || 0); }
        \\console.log(add(x, 1));
    ;
    const stripped = try strip(std.testing.allocator, source);
    defer std.testing.allocator.free(stripped);

    try std.testing.expect(std.mem.indexOf(u8, stripped, ": number") == null);
    try std.testing.expect(std.mem.indexOf(u8, stripped, "b?") == null);
    try std.testing.expect(std.mem.indexOf(u8, stripped, "function add") != null);
    try std.testing.expect(std.mem.indexOf(u8, stripped, "console.log") != null);
}

test "strip removes method parameter and return annotations" {
    const source =
        \\class C { m(x: number): number { return x; } }
        \\const object = { m(x: number): number { return x; } };
    ;
    const stripped = try strip(std.testing.allocator, source);
    defer std.testing.allocator.free(stripped);

    try std.testing.expect(std.mem.indexOf(u8, stripped, "x: number") == null);
    try std.testing.expect(std.mem.indexOf(u8, stripped, "): number") == null);
    try std.testing.expect(std.mem.indexOf(u8, stripped, "class C") != null);
    try std.testing.expect(std.mem.indexOf(u8, stripped, "const object") != null);
}

test "strip rejects constructor parameter properties" {
    try std.testing.expectError(
        error.SyntaxError,
        strip(std.testing.allocator, "class Box { constructor(public value: number) {} }"),
    );
    try std.testing.expectError(
        error.SyntaxError,
        strip(std.testing.allocator, "class Box { constructor(readonly value: number) {} }"),
    );
}

test "strip removes type declarations and type-only imports" {
    const source =
        \\import type { Foo } from "./types";
        \\import { type Bar, baz } from "./values";
        \\export type Named = Foo & Bar;
        \\interface Shape { x: number }
        \\const value: Foo = baz as Foo;
    ;
    const stripped = try strip(std.testing.allocator, source);
    defer std.testing.allocator.free(stripped);

    try std.testing.expect(std.mem.indexOf(u8, stripped, "import type") == null);
    try std.testing.expect(std.mem.indexOf(u8, stripped, "type Bar") == null);
    try std.testing.expect(std.mem.indexOf(u8, stripped, "export type") == null);
    try std.testing.expect(std.mem.indexOf(u8, stripped, "interface Shape") == null);
    try std.testing.expect(std.mem.indexOf(u8, stripped, "baz") != null);
    try std.testing.expect(std.mem.indexOf(u8, stripped, "as Foo") == null);
}

test "strip preserves import/export aliases while removing expression assertions" {
    const source =
        \\import { source as renamed } from "./dep";
        \\export { renamed as value };
        \\export const runtime = renamed as number;
    ;
    const stripped = try strip(std.testing.allocator, source);
    defer std.testing.allocator.free(stripped);

    try std.testing.expect(std.mem.indexOf(u8, stripped, "source as renamed") != null);
    try std.testing.expect(std.mem.indexOf(u8, stripped, "renamed as value") != null);
    try std.testing.expect(std.mem.indexOf(u8, stripped, "renamed as number") == null);
}

test "strip preserves runtime as and satisfies property names" {
    const source =
        \\const obj = { as: 1, satisfies: 2 };
        \\const value = obj.as + obj.satisfies;
        \\const as = 3;
        \\const satisfies = 4;
    ;
    const stripped = try strip(std.testing.allocator, source);
    defer std.testing.allocator.free(stripped);

    try std.testing.expect(std.mem.indexOf(u8, stripped, "as: 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, stripped, "satisfies: 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, stripped, "obj.as") != null);
    try std.testing.expect(std.mem.indexOf(u8, stripped, "obj.satisfies") != null);
    try std.testing.expect(std.mem.indexOf(u8, stripped, "const as = 3") != null);
    try std.testing.expect(std.mem.indexOf(u8, stripped, "const satisfies = 4") != null);
}

test "strip preserves object literal runtime colons" {
    const source =
        \\const obj: { x: number } = { x: 1, nested: { y: 2 } };
        \\console.log(obj.x + obj.nested.y);
    ;
    const stripped = try strip(std.testing.allocator, source);
    defer std.testing.allocator.free(stripped);

    try std.testing.expect(std.mem.indexOf(u8, stripped, "{ x: 1, nested: { y: 2 } }") != null);
}

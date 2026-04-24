const regexp_literal = @import("regexp_literal.zig");
const source_pos = @import("source_pos.zig");
const token = @import("token.zig");

pub const Lexer = struct {
    source: []const u8,
    index: usize = 0,
    position: source_pos.Position = .{},
    previous: ?token.Token = null,

    pub fn init(source: []const u8) Lexer {
        return .{ .source = source };
    }

    pub fn next(self: *Lexer) !token.Token {
        try self.skipTrivia();
        const start = self.position;
        if (self.index >= self.source.len) return self.emit(.eof, "", start, null);

        const c = self.peek();
        if (std.ascii.isAlphabetic(c) or c == '_' or c == '$') return self.identifier(start);
        if (std.ascii.isDigit(c)) return self.numeric(start);
        if (c == '#') return self.privateIdentifier(start);
        if (c == '\'' or c == '"') return self.string(start, c);
        if (c == '`') return self.template(start);
        if (c == '/' and regexp_literal.shouldStartRegExp(self.previous)) return self.regexp(start);
        if (c == '.' and self.index + 2 < self.source.len and self.source[self.index + 1] == '.' and self.source[self.index + 2] == '.') {
            self.bump();
            self.bump();
            self.bump();
            return self.emit(.punctuator, self.source[start.offset..self.index], start, null);
        }

        self.bump();
        return self.emit(.punctuator, self.source[start.offset..self.index], start, null);
    }

    fn identifier(self: *Lexer, start: source_pos.Position) token.Token {
        while (self.index < self.source.len and isIdentContinue(self.peek())) self.bump();
        const lexeme = self.source[start.offset..self.index];
        return if (token.keywordFor(lexeme)) |keyword|
            self.emit(.keyword, lexeme, start, keyword)
        else
            self.emit(.identifier, lexeme, start, null);
    }

    fn privateIdentifier(self: *Lexer, start: source_pos.Position) !token.Token {
        self.bump();
        if (self.index >= self.source.len or !isIdentStart(self.peek())) return error.InvalidPrivateName;
        while (self.index < self.source.len and isIdentContinue(self.peek())) self.bump();
        return self.emit(.private_identifier, self.source[start.offset..self.index], start, null);
    }

    fn numeric(self: *Lexer, start: source_pos.Position) token.Token {
        if (self.peek() == '0' and self.index + 1 < self.source.len) {
            const prefix = self.source[self.index + 1];
            if (prefix == 'x' or prefix == 'X' or prefix == 'b' or prefix == 'B' or prefix == 'o' or prefix == 'O') {
                self.bump();
                self.bump();
                while (self.index < self.source.len and (std.ascii.isHex(self.peek()) or self.peek() == '_')) self.bump();
                if (self.index < self.source.len and self.peek() == 'n') {
                    self.bump();
                    return self.emit(.bigint, self.source[start.offset..self.index], start, null);
                }
                return self.emit(.numeric, self.source[start.offset..self.index], start, null);
            }
        }

        while (self.index < self.source.len and (std.ascii.isDigit(self.peek()) or self.peek() == '_')) self.bump();
        if (self.index < self.source.len and self.peek() == '.') {
            self.bump();
            while (self.index < self.source.len and (std.ascii.isDigit(self.peek()) or self.peek() == '_')) self.bump();
        }
        if (self.index < self.source.len and self.peek() == 'n') {
            self.bump();
            return self.emit(.bigint, self.source[start.offset..self.index], start, null);
        }
        return self.emit(.numeric, self.source[start.offset..self.index], start, null);
    }

    fn string(self: *Lexer, start: source_pos.Position, quote: u8) !token.Token {
        self.bump();
        var escaped = false;
        while (self.index < self.source.len) {
            const c = self.peek();
            self.bump();
            if (escaped) {
                escaped = false;
                continue;
            }
            if (c == '\\') {
                escaped = true;
                continue;
            }
            if (c == quote) return self.emit(.string, self.source[start.offset..self.index], start, null);
            if (c == '\n' or c == '\r') return error.UnterminatedString;
        }
        return error.UnterminatedString;
    }

    fn template(self: *Lexer, start: source_pos.Position) !token.Token {
        self.bump();
        var escaped = false;
        while (self.index < self.source.len) {
            const c = self.peek();
            self.bump();
            if (escaped) {
                escaped = false;
                continue;
            }
            if (c == '\\') {
                escaped = true;
                continue;
            }
            if (c == '`') return self.emit(.template_no_substitution, self.source[start.offset..self.index], start, null);
        }
        return error.UnterminatedTemplate;
    }

    fn regexp(self: *Lexer, start: source_pos.Position) !token.Token {
        const literal = try regexp_literal.scan(self.source, self.index);
        while (self.index < literal.end_offset) self.bump();
        return self.emit(.regexp, self.source[start.offset..self.index], start, null);
    }

    fn skipTrivia(self: *Lexer) !void {
        while (self.index < self.source.len) {
            const c = self.peek();
            if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
                self.bump();
                continue;
            }
            if (c == '/' and self.index + 1 < self.source.len and self.source[self.index + 1] == '/') {
                while (self.index < self.source.len and self.peek() != '\n') self.bump();
                continue;
            }
            if (c == '/' and self.index + 1 < self.source.len and self.source[self.index + 1] == '*') {
                self.bump();
                self.bump();
                while (self.index + 1 < self.source.len and !(self.peek() == '*' and self.source[self.index + 1] == '/')) self.bump();
                if (self.index + 1 >= self.source.len) return error.UnterminatedComment;
                self.bump();
                self.bump();
                continue;
            }
            return;
        }
    }

    fn emit(self: *Lexer, kind: token.Kind, lexeme: []const u8, start: source_pos.Position, keyword: ?token.Keyword) token.Token {
        const out = token.Token{
            .kind = kind,
            .lexeme = lexeme,
            .range = .{ .start = start, .end = self.position },
            .keyword = keyword,
        };
        if (kind != .eof) self.previous = out;
        return out;
    }

    fn peek(self: Lexer) u8 {
        return self.source[self.index];
    }

    fn bump(self: *Lexer) void {
        const c = self.source[self.index];
        self.index += 1;
        source_pos.advance(&self.position, c);
    }
};

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_' or c == '$';
}

fn isIdentContinue(c: u8) bool {
    return isIdentStart(c) or std.ascii.isDigit(c);
}

const std = @import("std");

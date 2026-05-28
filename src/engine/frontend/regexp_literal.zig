const source_pos = @import("source_pos.zig");

pub const Literal = struct {
    pattern: []const u8,
    flags: []const u8,
    end_offset: usize,
};

pub fn scan(source: []const u8, slash_offset: usize) !Literal {
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
    while (i < source.len and isIdentContinue(source[i])) : (i += 1) {}
    return .{
        .pattern = pattern,
        .flags = source[flags_start..i],
        .end_offset = i,
    };
}

pub fn shouldStartRegExp(previous: ?@import("token.zig").Token) bool {
    const token = previous orelse return true;
    if (token.kind == .keyword) return token.isKeyword(.@"return") or token.isKeyword(.case) or token.isKeyword(.throw);
    if (token.kind == .punctuator) {
        return std.mem.indexOfScalar(u8, "({[=,:;!&|?", token.lexeme[0]) != null;
    }
    return false;
}

fn isIdentContinue(c: u8) bool {
    return std.ascii.isAlphabetic(c) or std.ascii.isDigit(c) or c == '_' or c == '$';
}

const std = @import("std");

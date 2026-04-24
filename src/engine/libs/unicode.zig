const tables = @import("unicode_tables.zig");

pub fn isIdentifierStart(c: u21) bool {
    return switch (tables.asciiCategory(c)) {
        .uppercase_letter, .lowercase_letter, .identifier_start => true,
        else => c >= 0x80,
    };
}

pub fn isIdentifierContinue(c: u21) bool {
    return isIdentifierStart(c) or tables.asciiCategory(c) == .decimal_number;
}

pub fn toUpperAscii(c: u8) u8 {
    if (c >= 'a' and c <= 'z') return c - 32;
    return c;
}

pub fn toLowerAscii(c: u8) u8 {
    if (c >= 'A' and c <= 'Z') return c + 32;
    return c;
}

pub fn equalsIgnoreAsciiCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (toLowerAscii(ca) != toLowerAscii(cb)) return false;
    }
    return true;
}

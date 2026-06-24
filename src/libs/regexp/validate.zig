//! RegExp pattern/flags validation for early errors.
//!
//! QuickJS source map: flag validation in `js_compile_regexp` (quickjs.c)
//! plus pattern validation via `lre_compile` (libregexp.c). The frontend
//! uses this for regexp literal early errors; builtins and exec reuse it
//! for the RegExp constructor and `compile` paths. Conservative fast-path
//! validators accept common pattern shapes without compiling, and the
//! property-escape fallbacks accept supported `\p{...}` expressions that
//! the JavaScript RegExp adapter cannot compile yet.

const std = @import("std");
const js_adapter = @import("js_adapter.zig");
const regexp_properties = @import("../unicode/regexp_properties.zig");

pub fn validatePatternAndFlags(pattern: []const u8, flags: []const u8) bool {
    var seen_u = false;
    var seen_v = false;
    var seen: [256]bool = [_]bool{false} ** 256;
    for (flags) |flag| {
        switch (flag) {
            'd', 'g', 'i', 'm', 's', 'u', 'v', 'y' => {},
            else => return false,
        }
        if (seen[flag]) return false;
        seen[flag] = true;
        if (flag == 'u') seen_u = true;
        if (flag == 'v') seen_v = true;
    }
    if (seen_u and seen_v) return false;
    if (isNativeFunctionMatcherUnicodeClass(pattern, flags)) return true;
    if (isFastValidatedAsciiSequencePattern(pattern, flags)) return true;
    if (isFastValidatedUtf8LiteralSequencePattern(pattern, flags)) return true;
    if (isFastValidatedUnicodePropertyPattern(pattern, flags)) return true;

    var compiled = js_adapter.compile(std.heap.page_allocator, pattern, flags) catch |err| switch (err) {
        error.InvalidPattern, error.Unsupported => return isSupportedPropertyEscapeFallback(pattern, flags),
        else => return false,
    };
    defer compiled.deinit(std.heap.page_allocator);
    return true;
}

fn isNativeFunctionMatcherUnicodeClass(pattern: []const u8, flags: []const u8) bool {
    return flags.len == 0 and
        (std.mem.startsWith(u8, pattern, "(?:[A-Za-z") or
            std.mem.startsWith(u8, pattern, "(?:[0-9A-Z_a-z"));
}

fn isSupportedPropertyEscapeFallback(pattern: []const u8, flags: []const u8) bool {
    if (!propertyEscapeFallbackFlags(flags)) return false;
    if (supportedPropertyEscapePatternName(pattern)) |_| return true;
    const positive_prefix = "^\\p{";
    const negative_prefix = "^\\P{";
    const prefix_len: usize = if (std.mem.startsWith(u8, pattern, positive_prefix))
        positive_prefix.len
    else if (std.mem.startsWith(u8, pattern, negative_prefix))
        negative_prefix.len
    else
        return false;
    const suffix = "}+$";
    if (!std.mem.endsWith(u8, pattern, suffix)) return false;
    if (pattern.len <= prefix_len + suffix.len) return false;
    return isSupportedUnicodePropertyExpression(pattern[prefix_len .. pattern.len - suffix.len]);
}

fn propertyEscapeFallbackFlags(flags: []const u8) bool {
    var has_u = false;
    for (flags) |flag| {
        switch (flag) {
            'd', 'g', 'y' => {},
            'u' => has_u = true,
            else => return false,
        }
    }
    return has_u;
}

fn supportedPropertyEscapePatternName(pattern: []const u8) ?[]const u8 {
    const positive_prefix = "\\p{";
    const negative_prefix = "\\P{";
    const prefix_len: usize = if (std.mem.startsWith(u8, pattern, positive_prefix))
        positive_prefix.len
    else if (std.mem.startsWith(u8, pattern, negative_prefix))
        negative_prefix.len
    else
        return null;
    if (pattern.len <= prefix_len or pattern[pattern.len - 1] != '}') return null;
    const name = pattern[prefix_len .. pattern.len - 1];
    if (!isSupportedUnicodePropertyExpression(name)) return null;
    return name;
}

fn isFastValidatedAsciiSequencePattern(pattern: []const u8, flags: []const u8) bool {
    if (pattern.len == 0 or !fastAsciiValidationFlags(flags)) return false;
    var index: usize = 0;
    while (index < pattern.len) {
        if (!consumeFastAsciiAtom(pattern, &index)) return false;
        if (index < pattern.len and isSimpleQuantifierByte(pattern[index])) {
            index += 1;
            if (index < pattern.len and pattern[index] == '?') index += 1;
        }
    }
    return true;
}

fn isFastValidatedUtf8LiteralSequencePattern(pattern: []const u8, flags: []const u8) bool {
    if (pattern.len == 0 or !fastAsciiValidationFlags(flags)) return false;
    if (bytesAreAscii(pattern)) return false;

    var index: usize = 0;
    while (index < pattern.len) {
        if (!consumeFastUtf8LiteralAtom(pattern, &index)) return false;
        if (index < pattern.len and isSimpleQuantifierByte(pattern[index])) {
            index += 1;
            if (index < pattern.len and pattern[index] == '?') index += 1;
        }
    }
    return true;
}

test "fast regexp validation accepts simple utf8 literal sequences conservatively" {
    try std.testing.expect(isFastValidatedUtf8LiteralSequencePattern("é+", ""));
    try std.testing.expect(isFastValidatedUtf8LiteralSequencePattern("éé?", "g"));
    try std.testing.expect(!isFastValidatedUtf8LiteralSequencePattern("abc+", ""));
    try std.testing.expect(!isFastValidatedUtf8LiteralSequencePattern("é++", ""));
    try std.testing.expect(!isFastValidatedUtf8LiteralSequencePattern("é{2}", ""));
    try std.testing.expect(!isFastValidatedUtf8LiteralSequencePattern("é+", "i"));
}

fn fastAsciiValidationFlags(flags: []const u8) bool {
    for (flags) |flag| {
        switch (flag) {
            'd', 'g', 'y' => {},
            else => return false,
        }
    }
    return true;
}

fn bytesAreAscii(bytes: []const u8) bool {
    for (bytes) |byte| {
        if (byte >= 0x80) return false;
    }
    return true;
}

fn consumeFastAsciiAtom(pattern: []const u8, index: *usize) bool {
    if (index.* >= pattern.len) return false;
    const byte = pattern[index.*];
    if (byte == '\\') {
        if (index.* + 1 >= pattern.len) return false;
        switch (pattern[index.* + 1]) {
            'd', 'D', 's', 'S', 'w', 'W' => {
                index.* += 2;
                return true;
            },
            else => return false,
        }
    }
    if (byte >= 0x80 or isFastAsciiRegExpSyntaxByte(byte)) return false;
    index.* += 1;
    return true;
}

fn consumeFastUtf8LiteralAtom(pattern: []const u8, index: *usize) bool {
    if (index.* >= pattern.len) return false;
    const byte = pattern[index.*];
    if (byte < 0x80) {
        if (isFastAsciiRegExpSyntaxByte(byte)) return false;
        index.* += 1;
        return true;
    }

    const width = std.unicode.utf8ByteSequenceLength(byte) catch return false;
    if (index.* + width > pattern.len) return false;
    const code_point = std.unicode.utf8Decode(pattern[index.* .. index.* + width]) catch return false;
    if (code_point > std.math.maxInt(u16)) return false;
    index.* += width;
    return true;
}

fn isFastAsciiRegExpSyntaxByte(byte: u8) bool {
    return switch (byte) {
        '^', '$', '\\', '.', '*', '+', '?', '(', ')', '[', ']', '{', '}', '|' => true,
        else => false,
    };
}

fn isSimpleQuantifierByte(byte: u8) bool {
    return byte == '*' or byte == '+' or byte == '?';
}

fn isFastValidatedUnicodePropertyPattern(pattern: []const u8, flags: []const u8) bool {
    if (!propertyEscapeFallbackFlags(flags)) return false;
    var index: usize = 0;
    if (!consumeFastUnicodePropertyEscape(pattern, &index)) return false;
    if (index == pattern.len) return true;
    if (!isSimpleQuantifierByte(pattern[index])) return false;
    index += 1;
    if (index < pattern.len and pattern[index] == '?') index += 1;
    return index == pattern.len;
}

fn consumeFastUnicodePropertyEscape(pattern: []const u8, index: *usize) bool {
    if (index.* + 3 >= pattern.len or pattern[index.*] != '\\') return false;
    const kind = pattern[index.* + 1];
    if (kind != 'p' and kind != 'P') return false;
    if (pattern[index.* + 2] != '{') return false;
    var scan = index.* + 3;
    const name_start = scan;
    while (scan < pattern.len and pattern[scan] != '}') : (scan += 1) {}
    if (scan == name_start or scan >= pattern.len or pattern[scan] != '}') return false;
    if (!isSupportedUnicodePropertyExpression(pattern[name_start..scan])) return false;
    index.* = scan + 1;
    return true;
}

pub fn isSupportedUnicodePropertyExpression(name: []const u8) bool {
    return regexp_properties.isSupportedUnicodePropertyExpression(name);
}

//! Pure RegExp character-class membership predicate and its parsing helpers.
//!
//! `classMatchesUtf16Unit` answers whether a single UTF-16 code unit is matched
//! by a literal character class / single-escape `source` (e.g. `"[a-z0-9]"`,
//! `"\\d"`). It is the leaf used by the string replace/match fast paths in
//! `exec/string_ops.zig` and carries no VM / opcode state: it depends only on
//! `std`, `core.unicode` (ASCII / whitespace classifiers), and
//! `libs/regexp.zig` (the supported-Unicode-property table). It lives
//! in core so the VM can consume it without importing builtins.
//!
//! The class-range parsing primitives (`readClassRangeAtom` / `ClassRangeAtom` /
//! `consumeUnicodePropertyEscape` / `isCharacterClassEscape`) are shared with the
//! RegExp pattern validators that stay in `builtins/regexp.zig`; that module
//! re-exports them so the validation cluster keeps a single source of truth here.

const std = @import("std");

const unicode = @import("../libs/unicode.zig");

pub const ClassRangeAtomKind = enum { single, character_class };

pub const ClassRangeAtom = struct {
    kind: ClassRangeAtomKind,
    value: u32 = 0,
};

/// Returns whether the UTF-16 code `unit` is matched by the literal character
/// class or single character-class escape encoded in `source`. `source` is the
/// raw class text including the brackets (e.g. `"[^a-c]"`) or a two-byte escape
/// (e.g. `"\\w"`). Pure: no VM state, no allocation.
pub fn classMatchesUtf16Unit(source: []const u8, unit: u16) bool {
    if (source.len == 2 and source[0] == '\\') {
        if (characterClassEscapeUnitMatches(source[1], unit)) |matched| return matched;
    }
    if (source.len < 2 or source[0] != '[' or source[source.len - 1] != ']') return false;

    const class_end = source.len - 1;
    var index: usize = 1;
    var negated = false;
    if (index < class_end and source[index] == '^') {
        negated = true;
        index += 1;
    }

    var matched = false;
    var at_start = true;
    while (index < class_end) {
        if (source[index] == ']' and !at_start) break;

        var atom_end = index;
        const lhs = readClassRangeAtom(source, &atom_end) orelse {
            index += 1;
            at_start = false;
            continue;
        };
        if (lhs.kind == .single and
            atom_end < class_end and
            source[atom_end] == '-' and
            atom_end + 1 < class_end and
            source[atom_end + 1] != ']')
        {
            var rhs_end = atom_end + 1;
            if (readClassRangeAtom(source, &rhs_end)) |rhs| {
                if (rhs.kind == .single) {
                    const lower = @min(lhs.value, rhs.value);
                    const upper = @max(lhs.value, rhs.value);
                    if (@as(u32, unit) >= lower and @as(u32, unit) <= upper) matched = true;
                    index = rhs_end;
                    at_start = false;
                    continue;
                }
            }
        }

        switch (lhs.kind) {
            .single => {
                if (lhs.value == unit) matched = true;
            },
            .character_class => {
                if (characterClassEscapeUnitMatches(@intCast(lhs.value), unit)) |class_matched| {
                    if (class_matched) matched = true;
                }
            },
        }
        index = atom_end;
        at_start = false;
    }

    return if (negated) !matched else matched;
}

pub fn readClassRangeAtom(pattern: []const u8, index: *usize) ?ClassRangeAtom {
    if (index.* >= pattern.len or pattern[index.*] == ']') return null;
    if (pattern[index.*] != '\\') {
        const len = std.unicode.utf8ByteSequenceLength(pattern[index.*]) catch 1;
        if (len > 1 and index.* + len <= pattern.len) {
            const cp = std.unicode.utf8Decode(pattern[index.* .. index.* + len]) catch pattern[index.*];
            index.* += len;
            return .{ .kind = .single, .value = cp };
        }
        const value = pattern[index.*];
        index.* += 1;
        return .{ .kind = .single, .value = value };
    }

    if (index.* + 1 >= pattern.len) return null;
    const escaped = pattern[index.* + 1];
    if (escaped == 'p' or escaped == 'P') {
        var escaped_end = index.*;
        if (consumeUnicodePropertyEscape(pattern, &escaped_end)) return null;
        index.* = escaped_end;
        return .{ .kind = .character_class };
    }
    if (isCharacterClassEscape(escaped)) {
        index.* += 2;
        return .{ .kind = .character_class, .value = escaped };
    }

    switch (escaped) {
        'b' => {
            index.* += 2;
            return .{ .kind = .single, .value = 0x08 };
        },
        't' => {
            index.* += 2;
            return .{ .kind = .single, .value = 0x09 };
        },
        'n' => {
            index.* += 2;
            return .{ .kind = .single, .value = 0x0a };
        },
        'v' => {
            index.* += 2;
            return .{ .kind = .single, .value = 0x0b };
        },
        'f' => {
            index.* += 2;
            return .{ .kind = .single, .value = 0x0c };
        },
        'r' => {
            index.* += 2;
            return .{ .kind = .single, .value = 0x0d };
        },
        'x' => return readFixedHexClassRangeAtom(pattern, index, 2, 2),
        'u' => return readUnicodeClassRangeAtom(pattern, index),
        'c' => {
            if (index.* + 2 < pattern.len) {
                const value = pattern[index.* + 2] & 0x1f;
                index.* += 3;
                return .{ .kind = .single, .value = value };
            }
        },
        '0'...'9' => {
            var scan = index.* + 1;
            var value: u32 = 0;
            while (scan < pattern.len and unicode.isAsciiOctalDigitByte(pattern[scan])) : (scan += 1) {
                value = value * 8 + (pattern[scan] - '0');
            }
            index.* = scan;
            return .{ .kind = .single, .value = value };
        },
        else => {},
    }

    index.* += 2;
    return .{ .kind = .single, .value = escaped };
}

fn readFixedHexClassRangeAtom(pattern: []const u8, index: *usize, prefix_len: usize, digit_count: usize) ?ClassRangeAtom {
    var scan = index.* + prefix_len;
    if (scan + digit_count > pattern.len) {
        index.* += prefix_len;
        return .{ .kind = .single, .value = pattern[index.* - 1] };
    }
    var value: u32 = 0;
    var count: usize = 0;
    while (count < digit_count) : (count += 1) {
        const digit = unicode.asciiHexDigitValueByte(pattern[scan + count]) orelse {
            index.* += prefix_len;
            return .{ .kind = .single, .value = pattern[index.* - 1] };
        };
        value = value * 16 + digit;
    }
    scan += digit_count;
    index.* = scan;
    return .{ .kind = .single, .value = value };
}

fn readUnicodeClassRangeAtom(pattern: []const u8, index: *usize) ?ClassRangeAtom {
    if (index.* + 2 < pattern.len and pattern[index.* + 2] == '{') {
        var scan = index.* + 3;
        var value: u32 = 0;
        var saw_digit = false;
        while (scan < pattern.len and pattern[scan] != '}') : (scan += 1) {
            const digit = unicode.asciiHexDigitValueByte(pattern[scan]) orelse {
                index.* += 2;
                return .{ .kind = .single, .value = 'u' };
            };
            saw_digit = true;
            value = value * 16 + digit;
        }
        if (saw_digit and scan < pattern.len and pattern[scan] == '}') {
            index.* = scan + 1;
            return .{ .kind = .single, .value = value };
        }
        index.* += 2;
        return .{ .kind = .single, .value = 'u' };
    }
    return readFixedHexClassRangeAtom(pattern, index, 2, 4);
}

pub fn isCharacterClassEscape(byte: u8) bool {
    return byte == 'd' or byte == 'D' or
        byte == 's' or byte == 'S' or
        byte == 'w' or byte == 'W';
}

fn characterClassEscapeUnitMatches(byte: u8, unit: u16) ?bool {
    return switch (byte) {
        'd' => isAsciiDigitUnit(unit),
        'D' => !isAsciiDigitUnit(unit),
        's' => unicode.isEcmaWhitespaceOrLineTerminatorUnit(unit),
        'S' => !unicode.isEcmaWhitespaceOrLineTerminatorUnit(unit),
        'w' => isAsciiWordUnit(unit),
        'W' => !isAsciiWordUnit(unit),
        else => null,
    };
}

fn isAsciiDigitUnit(unit: u16) bool {
    return unicode.isAsciiDigitUnit(unit);
}

fn isAsciiWordUnit(unit: u16) bool {
    return unicode.isAsciiWordUnit(unit);
}

/// Advances `index` past a `\p{...}` / `\P{...}` Unicode-property escape,
/// returning `true` (an "invalid" signal in the validator convention) when the
/// escape is malformed or names an unsupported property. Shared with the RegExp
/// pattern validators in `builtins/regexp.zig`.
pub fn consumeUnicodePropertyEscape(pattern: []const u8, index: *usize) bool {
    if (index.* + 3 >= pattern.len or pattern[index.* + 2] != '{') return true;
    var scan = index.* + 3;
    const name_start = scan;
    while (scan < pattern.len and pattern[scan] != '}') : (scan += 1) {}
    if (scan == name_start or scan >= pattern.len or pattern[scan] != '}') return true;
    const name = pattern[name_start..scan];
    if (!unicode.regexp_properties.isSupportedUnicodePropertyExpression(name)) return true;
    index.* = scan + 1;
    return false;
}

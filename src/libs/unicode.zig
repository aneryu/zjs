const std = @import("std");

const data = @import("unicode/data.zig");
const names = @import("unicode/names.zig");
const properties = @import("unicode/properties.zig");

pub const regexp_properties = @import("unicode/regexp_properties.zig");

pub const Category = enum {
    uppercase_letter,
    lowercase_letter,
    decimal_number,
    identifier_start,
    identifier_continue,
    other,
};

pub fn asciiCategory(c: u21) Category {
    if (c >= 'A' and c <= 'Z') return .uppercase_letter;
    if (c >= 'a' and c <= 'z') return .lowercase_letter;
    if (c >= '0' and c <= '9') return .decimal_number;
    if (c == '_' or c == '$') return .identifier_start;
    return .other;
}

pub const case_mapping_max_len = 3;
const unicode_limit: u21 = 0x110000;
const max_code_point: u21 = 0x10ffff;
pub const char_range_sentinel: u32 = std.math.maxInt(u32);
const high_surrogate_min: u21 = 0xd800;
const high_surrogate_max: u21 = 0xdbff;
const low_surrogate_min: u21 = 0xdc00;
const low_surrogate_max: u21 = 0xdfff;

pub const CaseMapping = struct {
    codepoints: [case_mapping_max_len]u21,
    len: usize,
};

pub const NormalizationForm = enum {
    nfc,
    nfd,
    nfkc,
    nfkd,
};

pub const CodePointRange = struct {
    lo: u21,
    hi: u21,
};

pub const ecmaWhitespaceOrLineTerminatorRanges = [_]CodePointRange{
    .{ .lo = 0x0009, .hi = 0x000d + 1 },
    .{ .lo = 0x0020, .hi = 0x0020 + 1 },
    .{ .lo = 0x00a0, .hi = 0x00a0 + 1 },
    .{ .lo = 0x1680, .hi = 0x1680 + 1 },
    .{ .lo = 0x2000, .hi = 0x200a + 1 },
    .{ .lo = 0x2028, .hi = 0x2029 + 1 },
    .{ .lo = 0x202f, .hi = 0x202f + 1 },
    .{ .lo = 0x205f, .hi = 0x205f + 1 },
    .{ .lo = 0x3000, .hi = 0x3000 + 1 },
    .{ .lo = 0xfeff, .hi = 0xfeff + 1 },
};

pub const SurrogatePair = struct {
    high: u16,
    low: u16,
};

const UnicodeError = std.mem.Allocator.Error || error{InvalidProperty};

pub fn isIdentifierStart(c: u21) bool {
    if (c == 0x200c or c == 0x200d) return false;
    return switch (asciiCategory(c)) {
        .uppercase_letter, .lowercase_letter, .identifier_start => true,
        else => if (c < 0x80) false else isInTable(c, data.unicode_prop_ID_Start_table[0..], data.unicode_prop_ID_Start_index[0..]),
    };
}

pub fn isIdentifierContinue(c: u21) bool {
    return switch (asciiCategory(c)) {
        .uppercase_letter, .lowercase_letter, .identifier_start, .decimal_number => true,
        else => if (c < 0x80) false else isIdentifierStart(c) or
            isInTable(c, data.unicode_prop_ID_Continue1_table[0..], data.unicode_prop_ID_Continue1_index[0..]) or
            c == 0x200c or c == 0x200d,
    };
}

pub fn caseConvert(c: u21, to_lower: bool) CaseMapping {
    const raw = caseConv(c, if (to_lower) 1 else 0);
    var codepoints: [case_mapping_max_len]u21 = undefined;
    for (raw.codepoints[0..raw.len], 0..) |cp, i| codepoints[i] = @intCast(cp);
    return .{ .codepoints = codepoints, .len = raw.len };
}

pub fn regexpCanonicalize(c: u21, is_unicode: bool) u21 {
    if (c < 128) {
        if (is_unicode) {
            if (c >= 'A' and c <= 'Z') return c - 'A' + 'a';
        } else {
            if (c >= 'a' and c <= 'z') return c - 'a' + 'A';
        }
        return c;
    }

    if (findCaseEntry(c)) |entry| {
        return @intCast(caseFoldingEntry(c, entry.idx, entry.value, is_unicode));
    }
    return c;
}

pub fn isCased(c: u21) bool {
    if (findCaseEntry(c) != null) return true;
    return isInTable(c, data.unicode_prop_Cased1_table[0..], data.unicode_prop_Cased1_index[0..]);
}

pub fn isCaseIgnorable(c: u21) bool {
    return isInTable(c, data.unicode_prop_Case_Ignorable_table[0..], data.unicode_prop_Case_Ignorable_index[0..]);
}

pub fn isWhiteSpace(c: u21) bool {
    return isInTable(c, data.unicode_prop_White_Space_table[0..], data.unicode_prop_White_Space_index[0..]);
}

pub fn isEcmaLineTerminatorCodePoint(cp: u21) bool {
    return cp == '\n' or cp == '\r' or cp == 0x2028 or cp == 0x2029;
}

pub fn isEcmaLineTerminatorUnit(unit: u16) bool {
    return isEcmaLineTerminatorCodePoint(@intCast(unit));
}

pub fn isEcmaWhitespaceOrLineTerminatorCodePoint(cp: u21) bool {
    inline for (ecmaWhitespaceOrLineTerminatorRanges) |range| {
        if (cp >= range.lo and cp < range.hi) return true;
    }
    return false;
}

pub fn isEcmaWhitespaceOrLineTerminatorUnit(unit: u16) bool {
    return isEcmaWhitespaceOrLineTerminatorCodePoint(@intCast(unit));
}

pub fn isAsciiWhitespaceByte(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r' or byte == 0x0b or byte == 0x0c;
}

pub fn isAsciiDigitUnit(unit: u16) bool {
    return isAsciiDigitCodePoint(@intCast(unit));
}

pub fn isAsciiAlphaUnit(unit: u16) bool {
    return isAsciiAlphaCodePoint(@intCast(unit));
}

pub fn isAsciiLowerUnit(unit: u16) bool {
    return isAsciiLowerCodePoint(@intCast(unit));
}

pub fn isAsciiWordUnit(unit: u16) bool {
    return isAsciiWordCodePoint(@intCast(unit));
}

pub fn isAsciiIdentifierStartByte(byte: u8) bool {
    return isAsciiAlphaByte(byte) or byte == '_' or byte == '$';
}

pub fn isAsciiIdentifierPartByte(byte: u8) bool {
    return isAsciiIdentifierStartByte(byte) or isAsciiDigitByte(byte);
}

pub fn asciiRadixDigitValueByte(byte: u8) ?u8 {
    if (byte >= '0' and byte <= '9') return byte - '0';
    if (byte >= 'a' and byte <= 'f') return byte - 'a' + 10;
    if (byte >= 'A' and byte <= 'F') return byte - 'A' + 10;
    if (byte >= 'g' and byte <= 'z') return byte - 'a' + 10;
    if (byte >= 'G' and byte <= 'Z') return byte - 'A' + 10;
    return null;
}

pub fn isAsciiBinaryDigitByte(byte: u8) bool {
    return byte == '0' or byte == '1';
}

pub fn isAsciiOctalDigitByte(byte: u8) bool {
    return byte >= '0' and byte <= '7';
}

pub fn isAsciiDigitByte(byte: u8) bool {
    return isAsciiDigitCodePoint(byte);
}

pub fn isAsciiUpperByte(byte: u8) bool {
    return isAsciiUpperCodePoint(byte);
}

pub fn isAsciiLowerByte(byte: u8) bool {
    return isAsciiLowerCodePoint(byte);
}

pub fn isAsciiAlphaByte(byte: u8) bool {
    return isAsciiUpperByte(byte) or isAsciiLowerByte(byte);
}

pub fn isAsciiAlphanumericByte(byte: u8) bool {
    return isAsciiAlphaByte(byte) or isAsciiDigitByte(byte);
}

pub fn isAsciiWordByte(byte: u8) bool {
    return isAsciiAlphanumericByte(byte) or byte == '_';
}

pub fn asciiHexDigitValueByte(byte: u8) ?u8 {
    const value = asciiRadixDigitValueByte(byte) orelse return null;
    if (value >= 16) return null;
    return value;
}

pub fn asciiUpperHexDigitValueByte(byte: u8) ?u8 {
    if (byte >= '0' and byte <= '9') return byte - '0';
    if (byte >= 'A' and byte <= 'F') return byte - 'A' + 10;
    return null;
}

pub fn asciiLowerHexDigitChar(nibble: usize) u8 {
    std.debug.assert(nibble < 16);
    return "0123456789abcdef"[nibble];
}

pub fn asciiUpperHexDigitChar(nibble: usize) u8 {
    std.debug.assert(nibble < 16);
    return "0123456789ABCDEF"[nibble];
}

pub fn isAsciiHexDigitByte(byte: u8) bool {
    return asciiHexDigitValueByte(byte) != null;
}

pub fn asciiHexDigitValueUnit(unit: u16) ?u8 {
    if (unit > std.math.maxInt(u8)) return null;
    return asciiHexDigitValueByte(@intCast(unit));
}

pub fn isAsciiHexDigitUnit(unit: u16) bool {
    return asciiHexDigitValueUnit(unit) != null;
}

pub fn isAsciiDigitCodePoint(cp: u21) bool {
    return cp >= '0' and cp <= '9';
}

pub fn isAsciiUpperCodePoint(cp: u21) bool {
    return cp >= 'A' and cp <= 'Z';
}

pub fn isAsciiLowerCodePoint(cp: u21) bool {
    return cp >= 'a' and cp <= 'z';
}

pub fn isAsciiAlphaCodePoint(cp: u21) bool {
    return isAsciiUpperCodePoint(cp) or isAsciiLowerCodePoint(cp);
}

pub fn isAsciiAlphanumericCodePoint(cp: u21) bool {
    return isAsciiAlphaCodePoint(cp) or isAsciiDigitCodePoint(cp);
}

pub fn isAsciiWordCodePoint(cp: u21) bool {
    return isAsciiAlphanumericCodePoint(cp) or cp == '_';
}

pub fn isHighSurrogateUnit(unit: u16) bool {
    return isHighSurrogateCodePoint(@intCast(unit));
}

pub fn isLowSurrogateUnit(unit: u16) bool {
    return isLowSurrogateCodePoint(@intCast(unit));
}

pub fn isHighSurrogateCodePoint(cp: u21) bool {
    return cp >= high_surrogate_min and cp <= high_surrogate_max;
}

pub fn isLowSurrogateCodePoint(cp: u21) bool {
    return cp >= low_surrogate_min and cp <= low_surrogate_max;
}

pub fn isSurrogateCodePoint(cp: u21) bool {
    return isHighSurrogateCodePoint(cp) or isLowSurrogateCodePoint(cp);
}

pub fn codePointFromSurrogatePair(high: u16, low: u16) u21 {
    return 0x10000 + ((@as(u21, high) - high_surrogate_min) << 10) + (@as(u21, low) - low_surrogate_min);
}

pub fn surrogatePairFromCodePoint(code_point: u21) SurrogatePair {
    const value = code_point - 0x10000;
    return .{
        .high = @intCast(high_surrogate_min + (value >> 10)),
        .low = @intCast(low_surrogate_min + (value & 0x3ff)),
    };
}

pub fn appendUtf16CodePoint(allocator: std.mem.Allocator, units: *std.ArrayList(u16), code_point: u21) std.mem.Allocator.Error!void {
    if (code_point <= std.math.maxInt(u16)) {
        try units.append(allocator, @intCast(code_point));
        return;
    }
    const pair = surrogatePairFromCodePoint(code_point);
    try units.append(allocator, pair.high);
    try units.append(allocator, pair.low);
}

pub fn appendUtf8CodePoint(allocator: std.mem.Allocator, buffer: *std.ArrayList(u8), cp: u32) std.mem.Allocator.Error!void {
    if (cp <= 0x7f) {
        try buffer.append(allocator, @intCast(cp));
    } else if (cp <= 0x7ff) {
        try buffer.append(allocator, @intCast(0xc0 | (cp >> 6)));
        try buffer.append(allocator, @intCast(0x80 | (cp & 0x3f)));
    } else if (cp <= 0xffff) {
        try buffer.append(allocator, @intCast(0xe0 | (cp >> 12)));
        try buffer.append(allocator, @intCast(0x80 | ((cp >> 6) & 0x3f)));
        try buffer.append(allocator, @intCast(0x80 | (cp & 0x3f)));
    } else {
        try buffer.append(allocator, @intCast(0xf0 | (cp >> 18)));
        try buffer.append(allocator, @intCast(0x80 | ((cp >> 12) & 0x3f)));
        try buffer.append(allocator, @intCast(0x80 | ((cp >> 6) & 0x3f)));
        try buffer.append(allocator, @intCast(0x80 | (cp & 0x3f)));
    }
}

pub fn appendUtf16UnitsAsUtf8(allocator: std.mem.Allocator, buffer: *std.ArrayList(u8), units: []const u16) std.mem.Allocator.Error!void {
    var index: usize = 0;
    while (index < units.len) : (index += 1) {
        const unit = units[index];
        if (isHighSurrogateUnit(unit) and index + 1 < units.len) {
            const next = units[index + 1];
            if (isLowSurrogateUnit(next)) {
                try appendUtf8CodePoint(allocator, buffer, codePointFromSurrogatePair(unit, next));
                index += 1;
                continue;
            }
        }
        try appendUtf8CodePoint(allocator, buffer, unit);
    }
}

/// Returns owned UTF-32 code points. Caller must free with the same allocator.
pub fn normalizeAlloc(allocator: std.mem.Allocator, src: []const u32, form: NormalizationForm) std.mem.Allocator.Error![]u32 {
    if (form == .nfc) {
        var all_latin1 = true;
        for (src) |c| {
            if (c >= 0x100) {
                all_latin1 = false;
                break;
            }
        }
        if (all_latin1) {
            const out = try allocator.alloc(u32, src.len);
            @memcpy(out, src);
            return out;
        }
    }

    var out = std.ArrayList(u32).empty;
    errdefer out.deinit(allocator);
    try toNfdRec(allocator, &out, src, form == .nfkc or form == .nfkd);
    sortCanonicalCombiningClass(out.items);

    if (out.items.len <= 1 or form == .nfd or form == .nfkd) {
        return try out.toOwnedSlice(allocator);
    }

    var i: usize = 1;
    var out_len: usize = 1;
    while (i < out.items.len) {
        var last_cc = combiningClass(out.items[i]);
        var starter_pos: isize = @intCast(out_len);
        starter_pos -= 1;
        var blocked = false;
        while (starter_pos >= 0) {
            const cc = combiningClass(out.items[@intCast(starter_pos)]);
            if (cc == 0) break;
            if (cc >= last_cc) {
                blocked = true;
                break;
            }
            last_cc = 256;
            starter_pos -= 1;
        }
        if (!blocked and starter_pos >= 0) {
            const composed = composePair(out.items[@intCast(starter_pos)], out.items[i]);
            if (composed != 0) {
                out.items[@intCast(starter_pos)] = composed;
                i += 1;
                continue;
            }
        }
        out.items[out_len] = out.items[i];
        out_len += 1;
        i += 1;
    }
    out.shrinkRetainingCapacity(out_len);
    return try out.toOwnedSlice(allocator);
}

/// Returns owned QuickJS-style boundary points: [lo, hi, lo, hi, ...].
/// Caller must free with the same allocator.
pub fn propertyRangePointsAlloc(
    allocator: std.mem.Allocator,
    expr: []const u8,
    inverted: bool,
) UnicodeError![]u32 {
    var buffer = try propertyRangePoints(allocator, expr, inverted);
    defer buffer.deinit();
    const items = buffer.items();
    const points = try allocator.alloc(u32, items.len);
    @memcpy(points, items);
    return points;
}

pub fn propertyRangePoints(
    allocator: std.mem.Allocator,
    expr: []const u8,
    inverted: bool,
) UnicodeError!CharRange {
    var ranges = try propertyRangeSet(allocator, expr);
    errdefer ranges.deinit();

    if (inverted) try ranges.invert();
    ranges.compress();
    return ranges;
}

fn propertyRangeSet(allocator: std.mem.Allocator, expr: []const u8) UnicodeError!RangeSet {
    const equals = std.mem.indexOfScalar(u8, expr, '=');
    const name = if (equals) |pos| expr[0..pos] else expr;
    const value = if (equals) |pos| expr[pos + 1 ..] else "";
    if (name.len == 0 or name.len >= 64 or value.len >= 64) return error.InvalidProperty;

    return if (std.mem.eql(u8, name, "Script") or std.mem.eql(u8, name, "sc"))
        scriptRanges(allocator, value, false)
    else if (std.mem.eql(u8, name, "Script_Extensions") or std.mem.eql(u8, name, "scx"))
        scriptRanges(allocator, value, true)
    else if (std.mem.eql(u8, name, "General_Category") or std.mem.eql(u8, name, "gc"))
        generalCategory(allocator, value)
    else if (value.len == 0) blk: {
        break :blk generalCategory(allocator, name) catch |err| switch (err) {
            error.InvalidProperty => try unicodeProp(allocator, name),
            else => return err,
        };
    } else return error.InvalidProperty;
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

const RawCaseMapping = struct {
    codepoints: [case_mapping_max_len]u32,
    len: usize,
};

const CaseEntry = struct {
    idx: usize,
    value: u32,
};

const RUN_TYPE_U = 0;
const RUN_TYPE_L = 1;
const RUN_TYPE_UF = 2;
const RUN_TYPE_LF = 3;
const RUN_TYPE_UL = 4;
const RUN_TYPE_LSU = 5;
const RUN_TYPE_U2L_399_EXT2 = 6;
const RUN_TYPE_UF_D20 = 7;
const RUN_TYPE_UF_D1_EXT = 8;
const RUN_TYPE_U_EXT = 9;
const RUN_TYPE_LF_EXT = 10;
const RUN_TYPE_UF_EXT2 = 11;
const RUN_TYPE_LF_EXT2 = 12;
const RUN_TYPE_UF_EXT3 = 13;

fn caseConv1(c: u32, conv_type: u32) u32 {
    return caseConv(@intCast(c), conv_type).codepoints[0];
}

fn caseConv(c_in: u21, conv_type: u32) RawCaseMapping {
    var c: u32 = c_in;
    if (c < 128) {
        if (conv_type != 0) {
            if (c >= 'A' and c <= 'Z') c = c - 'A' + 'a';
        } else {
            if (c >= 'a' and c <= 'z') c = c - 'a' + 'A';
        }
    } else if (findCaseEntry(c_in)) |entry| {
        return caseConvEntry(c, conv_type, entry.idx, entry.value);
    }
    return .{ .codepoints = .{ c, undefined, undefined }, .len = 1 };
}

fn caseConvEntry(c_in: u32, conv_type: u32, idx: usize, v: u32) RawCaseMapping {
    var c = c_in;
    var res: [case_mapping_max_len]u32 = undefined;
    const is_lower = conv_type != 0;
    const typ = (v >> (32 - 17 - 7 - 4)) & 0xf;
    const data1 = ((v & 0xf) << 8) | data.case_conv_table2[idx];
    const code = v >> (32 - 17);
    switch (typ) {
        RUN_TYPE_U, RUN_TYPE_L, RUN_TYPE_UF, RUN_TYPE_LF => {
            if (conv_type == (typ & 1) or (typ >= RUN_TYPE_UF and conv_type == 2)) {
                c = c - code + (data.case_conv_table1[@intCast(data1)] >> (32 - 17));
            }
        },
        RUN_TYPE_UL => {
            const a = c - code;
            if ((a & 1) == (if (is_lower) @as(u32, 0) else 1)) c = (a ^ 1) + code;
        },
        RUN_TYPE_LSU => {
            const a = c - code;
            if (a == 1) {
                c = if (is_lower) c + 1 else c - 1;
            } else if (a == (if (is_lower) @as(u32, 0) else 2)) {
                c = if (is_lower) c + 2 else c - 2;
            }
        },
        RUN_TYPE_U2L_399_EXT2 => {
            if (!is_lower) {
                res[0] = c - code + data.case_conv_ext[data1 >> 6];
                res[1] = 0x399;
                return .{ .codepoints = res, .len = 2 };
            }
            c = c - code + data.case_conv_ext[data1 & 0x3f];
        },
        RUN_TYPE_UF_D20 => {
            if (conv_type != 1) c = data1 + if (conv_type == 2) @as(u32, 0x20) else 0;
        },
        RUN_TYPE_UF_D1_EXT => {
            if (conv_type != 1) c = data.case_conv_ext[@intCast(data1)] + if (conv_type == 2) @as(u32, 1) else 0;
        },
        RUN_TYPE_U_EXT, RUN_TYPE_LF_EXT => {
            if (is_lower == (typ == RUN_TYPE_LF_EXT)) c = data.case_conv_ext[@intCast(data1)];
        },
        RUN_TYPE_LF_EXT2 => {
            if (is_lower) {
                res[0] = c - code + data.case_conv_ext[data1 >> 6];
                res[1] = data.case_conv_ext[data1 & 0x3f];
                return .{ .codepoints = res, .len = 2 };
            }
        },
        RUN_TYPE_UF_EXT2 => {
            if (conv_type != 1) {
                res[0] = c - code + data.case_conv_ext[data1 >> 6];
                res[1] = data.case_conv_ext[data1 & 0x3f];
                if (conv_type == 2) {
                    res[0] = caseConv1(res[0], 1);
                    res[1] = caseConv1(res[1], 1);
                }
                return .{ .codepoints = res, .len = 2 };
            }
        },
        else => {
            if (conv_type != 1) {
                res[0] = data.case_conv_ext[data1 >> 8];
                res[1] = data.case_conv_ext[(data1 >> 4) & 0xf];
                res[2] = data.case_conv_ext[data1 & 0xf];
                if (conv_type == 2) {
                    res[0] = caseConv1(res[0], 1);
                    res[1] = caseConv1(res[1], 1);
                    res[2] = caseConv1(res[2], 1);
                }
                return .{ .codepoints = res, .len = 3 };
            }
        },
    }
    res[0] = c;
    return .{ .codepoints = res, .len = 1 };
}

fn caseFoldingEntry(c_in: u21, idx: usize, v: u32, is_unicode: bool) u32 {
    var c: u32 = c_in;
    if (is_unicode) {
        const folded = caseConvEntry(c, 2, idx, v);
        if (folded.len == 1) {
            c = folded.codepoints[0];
        } else if (c == 0xfb06) {
            c = 0xfb05;
        } else if (c == 0x01fd3) {
            c = 0x390;
        } else if (c == 0x01fe3) {
            c = 0x3b0;
        }
    } else if (c < 128) {
        if (c >= 'a' and c <= 'z') c = c - 'a' + 'A';
    } else {
        const folded = caseConvEntry(c, 0, idx, v);
        if (folded.len == 1 and folded.codepoints[0] >= 128) c = folded.codepoints[0];
    }
    return c;
}

fn findCaseEntry(c: u21) ?CaseEntry {
    var idx_min: isize = 0;
    var idx_max: isize = @intCast(data.case_conv_table1.len - 1);
    while (idx_min <= idx_max) {
        const idx: usize = @intCast(@divTrunc(idx_max + idx_min, 2));
        const v = data.case_conv_table1[idx];
        const code = v >> (32 - 17);
        const len = (v >> (32 - 17 - 7)) & 0x7f;
        if (c < code) {
            idx_max = @as(isize, @intCast(idx)) - 1;
        } else if (c >= code + len) {
            idx_min = @as(isize, @intCast(idx)) + 1;
        } else {
            return .{ .idx = idx, .value = v };
        }
    }
    return null;
}

fn getLe24(bytes: []const u8, offset: usize) u32 {
    return @as(u32, bytes[offset]) | (@as(u32, bytes[offset + 1]) << 8) | (@as(u32, bytes[offset + 2]) << 16);
}

const IndexPosition = struct {
    code: u32,
    pos: usize,
};

fn getIndexPosition(c: u21, index_table: []const u8) ?IndexPosition {
    const index_len = index_table.len / 3;
    if (index_len == 0) return null;
    var idx_min: usize = 0;
    var v = getLe24(index_table, 0);
    var code = v & ((1 << 21) - 1);
    if (c < code) return .{ .code = 0, .pos = 0 };

    var idx_max = index_len - 1;
    code = getLe24(index_table, idx_max * 3) & ((1 << 21) - 1);
    if (c >= code) return null;

    while (idx_max - idx_min > 1) {
        const idx = (idx_max + idx_min) / 2;
        v = getLe24(index_table, idx * 3);
        code = v & ((1 << 21) - 1);
        if (c < code) {
            idx_max = idx;
        } else {
            idx_min = idx;
        }
    }
    v = getLe24(index_table, idx_min * 3);
    return .{
        .code = v & ((1 << 21) - 1),
        .pos = (idx_min + 1) * 32 + @as(usize, @intCast(v >> 21)),
    };
}

fn isInTable(c: u21, table: []const u8, index_table: []const u8) bool {
    const pos = getIndexPosition(c, index_table) orelse return false;
    var p = pos.pos;
    var code = pos.code;
    var bit = false;
    while (p < table.len) {
        const b = table[p];
        p += 1;
        if (b < 64) {
            code += (b >> 3) + 1;
            if (c < code) return bit;
            bit = !bit;
            code += (b & 7) + 1;
        } else if (b >= 0x80) {
            code += b - 0x80 + 1;
        } else if (b < 0x60) {
            code += ((@as(u32, b - 0x40) << 8) | table[p]) + 1;
            p += 1;
        } else {
            code += ((@as(u32, b - 0x60) << 16) | (@as(u32, table[p]) << 8) | table[p + 1]) + 1;
            p += 2;
        }
        if (c < code) return bit;
        bit = !bit;
    }
    return false;
}

const DECOMP_TYPE_C1 = 0;
const DECOMP_TYPE_L1 = 1;
const DECOMP_TYPE_L2 = 2;
const DECOMP_TYPE_L3 = 3;
const DECOMP_TYPE_L4 = 4;
const DECOMP_TYPE_L5 = 5;
const DECOMP_TYPE_L6 = 6;
const DECOMP_TYPE_L7 = 7;
const DECOMP_TYPE_LL1 = 8;
const DECOMP_TYPE_LL2 = 9;
const DECOMP_TYPE_S1 = 10;
const DECOMP_TYPE_S2 = 11;
const DECOMP_TYPE_S3 = 12;
const DECOMP_TYPE_S4 = 13;
const DECOMP_TYPE_S5 = 14;
const DECOMP_TYPE_I1 = 15;
const DECOMP_TYPE_I2_0 = 16;
const DECOMP_TYPE_I2_1 = 17;
const DECOMP_TYPE_I3_1 = 18;
const DECOMP_TYPE_I3_2 = 19;
const DECOMP_TYPE_I4_1 = 20;
const DECOMP_TYPE_I4_2 = 21;
const DECOMP_TYPE_B1 = 22;
const DECOMP_TYPE_B2 = 23;
const DECOMP_TYPE_B3 = 24;
const DECOMP_TYPE_B4 = 25;
const DECOMP_TYPE_B5 = 26;
const DECOMP_TYPE_B6 = 27;
const DECOMP_TYPE_B7 = 28;
const DECOMP_TYPE_B8 = 29;
const DECOMP_TYPE_B18 = 30;
const DECOMP_TYPE_LS2 = 31;
const DECOMP_TYPE_PAT3 = 32;
const DECOMP_TYPE_S2_UL = 33;
const DECOMP_TYPE_LS2_UL = 34;

const unicode_decomp_len_max = 18;

fn shortCode(c: u32) u32 {
    return if (c < 0x80)
        c
    else if (c < 0x80 + 0x50)
        c - 0x80 + 0x300
    else switch (c - 0x80 - 0x50) {
        0 => 0x2044,
        1 => 0x2215,
        else => 0,
    };
}

fn lowerSimple(c_in: u32) u32 {
    var c = c_in;
    if (c < 0x100 or (c >= 0x410 and c <= 0x42f)) {
        c += 0x20;
    } else {
        c += 1;
    }
    return c;
}

fn get16(bytes: []const u8, offset: usize) u32 {
    return @as(u32, bytes[offset]) | (@as(u32, bytes[offset + 1]) << 8);
}

fn decompEntry(res: *[unicode_decomp_len_max]u32, c_in: u32, idx: usize, code: u32, len: u32, typ: u32) usize {
    var c = c_in;
    if (typ == DECOMP_TYPE_C1) {
        res[0] = data.unicode_decomp_table2[idx];
        return 1;
    }

    var d = data.unicode_decomp_data[@intCast(data.unicode_decomp_table2[idx])..];
    switch (typ) {
        DECOMP_TYPE_L1, DECOMP_TYPE_L2, DECOMP_TYPE_L3, DECOMP_TYPE_L4, DECOMP_TYPE_L5, DECOMP_TYPE_L6, DECOMP_TYPE_L7 => {
            const l: usize = @intCast(typ - DECOMP_TYPE_L1 + 1);
            const base: usize = @intCast((c - code) * @as(u32, @intCast(l)) * 2);
            for (0..l) |i| {
                const c1 = get16(d, base + 2 * i);
                if (c1 == 0) return 0;
                res[i] = c1;
            }
            return l;
        },
        DECOMP_TYPE_LL1, DECOMP_TYPE_LL2 => {
            const l: usize = @intCast(typ - DECOMP_TYPE_LL1 + 1);
            var k: usize = @intCast((c - code) * @as(u32, @intCast(l)));
            const p: usize = @intCast(len * @as(u32, @intCast(l)) * 2);
            for (0..l) |i| {
                const c1 = get16(d, 2 * k) | ((@as(u32, (d[p + (k / 4)] >> @intCast((k % 4) * 2)) & 3)) << 16);
                if (c1 == 0) return 0;
                res[i] = c1;
                k += 1;
            }
            return l;
        },
        DECOMP_TYPE_S1, DECOMP_TYPE_S2, DECOMP_TYPE_S3, DECOMP_TYPE_S4, DECOMP_TYPE_S5 => {
            const l: usize = @intCast(typ - DECOMP_TYPE_S1 + 1);
            const base: usize = @intCast((c - code) * @as(u32, @intCast(l)));
            for (0..l) |i| {
                const c1 = shortCode(d[base + i]);
                if (c1 == 0) return 0;
                res[i] = c1;
            }
            return l;
        },
        DECOMP_TYPE_I1 => return decompTypeI(res, c, code, d, 1, 0),
        DECOMP_TYPE_I2_0, DECOMP_TYPE_I2_1, DECOMP_TYPE_I3_1, DECOMP_TYPE_I3_2, DECOMP_TYPE_I4_1, DECOMP_TYPE_I4_2 => {
            const l: usize = @intCast(2 + ((typ - DECOMP_TYPE_I2_0) >> 1));
            const p: usize = @intCast(((typ - DECOMP_TYPE_I2_0) & 1) + if (l > 2) @as(u32, 1) else 0);
            return decompTypeI(res, c, code, d, l, p);
        },
        DECOMP_TYPE_B18 => return decompTypeB(res, c, code, d, 18),
        DECOMP_TYPE_B1, DECOMP_TYPE_B2, DECOMP_TYPE_B3, DECOMP_TYPE_B4, DECOMP_TYPE_B5, DECOMP_TYPE_B6, DECOMP_TYPE_B7, DECOMP_TYPE_B8 => {
            return decompTypeB(res, c, code, d, @intCast(typ - DECOMP_TYPE_B1 + 1));
        },
        DECOMP_TYPE_LS2 => {
            const base: usize = @intCast((c - code) * 3);
            const c0 = get16(d, base);
            if (c0 == 0) return 0;
            res[0] = c0;
            res[1] = shortCode(d[base + 2]);
            return 2;
        },
        DECOMP_TYPE_PAT3 => {
            res[0] = get16(d, 0);
            res[2] = get16(d, 2);
            const base: usize = @intCast(4 + (c - code) * 2);
            res[1] = get16(d, base);
            return 3;
        },
        DECOMP_TYPE_S2_UL, DECOMP_TYPE_LS2_UL => {
            const c1 = c - code;
            if (typ == DECOMP_TYPE_S2_UL) {
                const base: usize = @intCast(c1 & ~@as(u32, 1));
                c = shortCode(d[base]);
                d = d[base + 1 ..];
            } else {
                const base: usize = @intCast((c1 >> 1) * 3);
                c = get16(d, base);
                d = d[base + 2 ..];
            }
            if ((c1 & 1) != 0) c = lowerSimple(c);
            res[0] = c;
            res[1] = shortCode(d[0]);
            return 2;
        },
        else => return 0,
    }
}

fn decompTypeI(res: *[unicode_decomp_len_max]u32, c: u32, code: u32, d: []const u8, l: usize, p: usize) usize {
    for (0..l) |i| {
        var c1 = get16(d, 2 * i);
        if (i == p) c1 += c - code;
        res[i] = c1;
    }
    return l;
}

fn decompTypeB(res: *[unicode_decomp_len_max]u32, c: u32, code: u32, d: []const u8, l: usize) usize {
    const c_min = get16(d, 0);
    const base = 2 + @as(usize, @intCast(c - code)) * l;
    for (0..l) |i| {
        var c1: u32 = d[base + i];
        if (c1 == 0xff) {
            c1 = 0x20;
        } else {
            c1 += c_min;
        }
        res[i] = c1;
    }
    return l;
}

fn decompChar(res: *[unicode_decomp_len_max]u32, c: u32, is_compat1: bool) usize {
    var idx_min: isize = 0;
    var idx_max: isize = @intCast(data.unicode_decomp_table1.len - 1);
    while (idx_min <= idx_max) {
        const idx: usize = @intCast(@divTrunc(idx_max + idx_min, 2));
        const v = data.unicode_decomp_table1[idx];
        const code = v >> (32 - 18);
        const len = (v >> (32 - 18 - 7)) & 0x7f;
        if (c < code) {
            idx_max = @as(isize, @intCast(idx)) - 1;
        } else if (c >= code + len) {
            idx_min = @as(isize, @intCast(idx)) + 1;
        } else {
            const is_compat = (v & 1) != 0;
            if (!is_compat1 and is_compat) break;
            const typ = (v >> (32 - 18 - 7 - 6)) & 0x3f;
            return decompEntry(res, c, idx, code, len, typ);
        }
    }
    return 0;
}

fn unicodeComposePair(c0: u32, c1: u32) u32 {
    var idx_min: isize = 0;
    var idx_max: isize = @intCast(data.unicode_comp_table.len - 1);
    while (idx_min <= idx_max) {
        const idx: usize = @intCast(@divTrunc(idx_max + idx_min, 2));
        const idx1 = data.unicode_comp_table[idx];
        const d_idx: usize = idx1 >> 6;
        const d_offset = idx1 & 0x3f;
        const v = data.unicode_decomp_table1[d_idx];
        const code = v >> (32 - 18);
        const len = (v >> (32 - 18 - 7)) & 0x7f;
        const typ = (v >> (32 - 18 - 7 - 6)) & 0x3f;
        const ch = code + d_offset;
        var pair: [unicode_decomp_len_max]u32 = undefined;
        _ = decompEntry(&pair, ch, d_idx, code, len, typ);
        var d: i64 = @as(i64, c0) - @as(i64, pair[0]);
        if (d == 0) d = @as(i64, c1) - @as(i64, pair[1]);
        if (d < 0) {
            idx_max = @as(isize, @intCast(idx)) - 1;
        } else if (d > 0) {
            idx_min = @as(isize, @intCast(idx)) + 1;
        } else {
            return ch;
        }
    }
    return 0;
}

fn combiningClass(c: u32) u32 {
    const pos = getIndexPosition(@intCast(c), data.unicode_cc_index[0..]) orelse return 0;
    var code = pos.code;
    var p = pos.pos;
    while (p < data.unicode_cc_table.len) {
        const b = data.unicode_cc_table[p];
        p += 1;
        var n: u32 = b & 0x3f;
        const typ = b >> 6;
        if (n < 48) {} else if (n < 56) {
            n = ((n - 48) << 8) | data.unicode_cc_table[p];
            p += 1;
            n += 48;
        } else {
            n = ((n - 56) << 16) | (@as(u32, data.unicode_cc_table[p]) << 8) | data.unicode_cc_table[p + 1];
            p += 2;
            n += 48 + (1 << 11);
        }
        if (typ <= 1) p += 1;
        const c1 = code + n + 1;
        if (c < c1) {
            return switch (typ) {
                0 => data.unicode_cc_table[p - 1],
                1 => data.unicode_cc_table[p - 1] + c - code,
                2 => 0,
                else => 230,
            };
        }
        code = c1;
    }
    return 0;
}

fn sortCanonicalCombiningClass(buf: []u32) void {
    var i: usize = 0;
    while (i < buf.len) {
        const cc = combiningClass(buf[i]);
        if (cc == 0) {
            i += 1;
            continue;
        }
        const start = i;
        var j = i + 1;
        while (j < buf.len) : (j += 1) {
            const ch1 = buf[j];
            const cc1 = combiningClass(ch1);
            if (cc1 == 0) break;
            var k = j;
            while (k > start) : (k -= 1) {
                if (combiningClass(buf[k - 1]) <= cc1) break;
                buf[k] = buf[k - 1];
            }
            buf[k] = ch1;
        }
        i = j + 1;
    }
}

fn toNfdRec(allocator: std.mem.Allocator, out: *std.ArrayList(u32), src: []const u32, is_compat: bool) std.mem.Allocator.Error!void {
    for (src) |input_c| {
        var c = input_c;
        if (c >= 0xac00 and c < 0xd7a4) {
            c -= 0xac00;
            try out.append(allocator, 0x1100 + c / 588);
            try out.append(allocator, 0x1161 + (c % 588) / 28);
            const v = c % 28;
            if (v != 0) try out.append(allocator, 0x11a7 + v);
        } else {
            var res: [unicode_decomp_len_max]u32 = undefined;
            const len = decompChar(&res, c, is_compat);
            if (len != 0) {
                try toNfdRec(allocator, out, res[0..len], is_compat);
            } else {
                try out.append(allocator, c);
            }
        }
    }
}

fn composePair(c0: u32, c1: u32) u32 {
    if (c0 >= 0x1100 and c0 < 0x1100 + 19 and c1 >= 0x1161 and c1 < 0x1161 + 21) {
        return 0xac00 + (c0 - 0x1100) * 588 + (c1 - 0x1161) * 28;
    }
    if (c0 >= 0xac00 and c0 < 0xac00 + 11172 and (c0 - 0xac00) % 28 == 0 and c1 >= 0x11a7 and c1 < 0x11a7 + 28) {
        return c0 + c1 - 0x11a7;
    }
    return unicodeComposePair(c0, c1);
}

pub const CharRangePointRange = struct {
    lo: u32,
    hi: u32,
};

pub const CharRange = struct {
    allocator: std.mem.Allocator,
    points: std.ArrayList(u32),

    pub fn init(allocator: std.mem.Allocator) CharRange {
        return .{ .allocator = allocator, .points = .empty };
    }

    pub fn deinit(self: *CharRange) void {
        self.points.deinit(self.allocator);
    }

    pub fn items(self: *const CharRange) []const u32 {
        return self.points.items;
    }

    pub fn addInterval(self: *CharRange, lo: u32, hi: u32) std.mem.Allocator.Error!void {
        if (hi <= lo) return;
        try self.points.ensureUnusedCapacity(self.allocator, 2);
        self.points.appendAssumeCapacity(lo);
        self.points.appendAssumeCapacity(hi);
    }

    pub fn appendPoints(self: *CharRange, points: []const u32) std.mem.Allocator.Error!void {
        try self.points.appendSlice(self.allocator, points);
    }

    pub fn addSet(self: *CharRange, other: *const CharRange) std.mem.Allocator.Error!void {
        try self.appendPoints(other.points.items);
    }

    pub fn normalize(self: *CharRange) void {
        self.sortAndRemoveOverlap();
    }

    pub fn compress(self: *CharRange) void {
        self.compressAdjacent();
    }

    fn compressAdjacent(self: *CharRange) void {
        const pts = self.points.items;
        var read: usize = 0;
        var write: usize = 0;
        while (read + 1 < pts.len) {
            if (pts[read] == pts[read + 1]) {
                read += 2;
                continue;
            }
            var end = read;
            while (end + 3 < pts.len and pts[end + 1] == pts[end + 2]) {
                end += 2;
            }
            pts[write] = pts[read];
            pts[write + 1] = pts[end + 1];
            write += 2;
            read = end + 2;
        }
        self.points.shrinkRetainingCapacity(write);
    }

    pub fn sortAndRemoveOverlap(self: *CharRange) void {
        insertionSortPointPairs(self.points.items);
        self.compressOverlapping();
    }

    fn compressOverlapping(self: *CharRange) void {
        const pts = self.points.items;
        var read: usize = 0;
        var write: usize = 0;
        while (read + 1 < pts.len) {
            if (pts[read] == pts[read + 1]) {
                read += 2;
                continue;
            }
            var end = read;
            var hi = pts[read + 1];
            while (end + 3 < pts.len and pts[end + 2] <= hi) {
                end += 2;
                if (pts[end + 1] > hi) hi = pts[end + 1];
            }
            pts[write] = pts[read];
            pts[write + 1] = hi;
            write += 2;
            read = end + 2;
        }
        self.points.shrinkRetainingCapacity(write);
    }

    pub fn unionWith(self: *CharRange, other: *const CharRange) std.mem.Allocator.Error!void {
        try self.opWith(other, .op_union);
    }

    pub fn intersectWith(self: *CharRange, other: *const CharRange) std.mem.Allocator.Error!void {
        try self.opWith(other, .op_inter);
    }

    pub fn xorWith(self: *CharRange, other: *const CharRange) std.mem.Allocator.Error!void {
        try self.opWith(other, .op_xor);
    }

    pub fn subWith(self: *CharRange, other: *const CharRange) std.mem.Allocator.Error!void {
        try self.opWith(other, .op_sub);
    }

    const BinaryOp = enum {
        op_union,
        op_inter,
        op_xor,
        op_sub,
    };

    fn opWith(self: *CharRange, other: *const CharRange, op: BinaryOp) std.mem.Allocator.Error!void {
        var out = try makeOp(self.allocator, self, other, op);
        self.points.deinit(self.allocator);
        self.points = out.points;
        out.points = .empty;
    }

    fn makeOp(
        allocator: std.mem.Allocator,
        a: *const CharRange,
        b: *const CharRange,
        op: BinaryOp,
    ) std.mem.Allocator.Error!CharRange {
        var out = CharRange.init(allocator);
        errdefer out.deinit();
        try out.points.ensureTotalCapacity(allocator, a.points.items.len + b.points.items.len);

        var a_idx: usize = 0;
        var b_idx: usize = 0;
        while (true) {
            const point = if (a_idx < a.points.items.len and b_idx < b.points.items.len)
                if (a.points.items[a_idx] < b.points.items[b_idx]) blk: {
                    const p = a.points.items[a_idx];
                    a_idx += 1;
                    break :blk p;
                } else if (a.points.items[a_idx] == b.points.items[b_idx]) blk: {
                    const p = a.points.items[a_idx];
                    a_idx += 1;
                    b_idx += 1;
                    break :blk p;
                } else blk: {
                    const p = b.points.items[b_idx];
                    b_idx += 1;
                    break :blk p;
                }
            else if (a_idx < a.points.items.len) blk: {
                const p = a.points.items[a_idx];
                a_idx += 1;
                break :blk p;
            } else if (b_idx < b.points.items.len) blk: {
                const p = b.points.items[b_idx];
                b_idx += 1;
                break :blk p;
            } else break;

            const is_in = switch (op) {
                .op_union => ((a_idx & 1) != 0) or ((b_idx & 1) != 0),
                .op_inter => ((a_idx & 1) != 0) and ((b_idx & 1) != 0),
                .op_xor => ((a_idx & 1) != 0) != ((b_idx & 1) != 0),
                .op_sub => ((a_idx & 1) != 0) and ((b_idx & 1) == 0),
            };
            if (is_in != ((out.points.items.len & 1) != 0)) {
                try out.points.append(allocator, point);
            }
        }
        out.compress();
        return out;
    }

    pub fn invert(self: *CharRange) std.mem.Allocator.Error!void {
        const len = self.points.items.len;
        try self.points.resize(self.allocator, len + 2);
        @memmove(self.points.items[1 .. len + 1], self.points.items[0..len]);
        self.points.items[0] = 0;
        self.points.items[len + 1] = char_range_sentinel;
        self.compress();
    }

    pub fn regexpCanonicalize(self: *CharRange, is_unicode: bool) std.mem.Allocator.Error!void {
        self.compress();

        var cr_mask = try unicodeCase1(self.allocator, if (is_unicode) properties.CASE_F else properties.CASE_U);
        defer cr_mask.deinit();

        var cr_inter = try makeOp(self.allocator, &cr_mask, self, .op_inter);
        defer cr_inter.deinit();

        try cr_mask.invert();
        var cr_sub = try makeOp(self.allocator, &cr_mask, self, .op_inter);
        defer cr_sub.deinit();

        var cr_result = CharRange.init(self.allocator);
        defer cr_result.deinit();

        var d_start: u32 = char_range_sentinel;
        var d_end: u32 = char_range_sentinel;
        var idx: usize = 0;
        var v = data.case_conv_table1[idx];
        var code = v >> (32 - 17);
        var len = (v >> (32 - 17 - 7)) & 0x7f;

        var range_index: usize = 0;
        while (range_index < cr_inter.rangeCount()) : (range_index += 1) {
            const range = cr_inter.rangeAt(range_index);
            var c = range.lo;
            while (c < range.hi) : (c += 1) {
                while (!(c >= code and c < code + len)) {
                    idx += 1;
                    std.debug.assert(idx < data.case_conv_table1.len);
                    v = data.case_conv_table1[idx];
                    code = v >> (32 - 17);
                    len = (v >> (32 - 17 - 7)) & 0x7f;
                }

                const d = caseFoldingEntry(@intCast(c), idx, v, is_unicode);
                if (d_start == char_range_sentinel) {
                    d_start = d;
                    d_end = d + 1;
                } else if (d_end == d) {
                    d_end += 1;
                } else {
                    try cr_result.addInterval(d_start, d_end);
                    d_start = d;
                    d_end = d + 1;
                }
            }
        }
        if (d_start != char_range_sentinel) try cr_result.addInterval(d_start, d_end);
        cr_result.sortAndRemoveOverlap();

        var unioned = try makeOp(self.allocator, &cr_result, &cr_sub, .op_union);
        self.points.deinit(self.allocator);
        self.points = unioned.points;
        unioned.points = .empty;
    }

    pub fn rangeCount(self: *const CharRange) usize {
        return self.points.items.len / 2;
    }

    pub fn rangeAt(self: *const CharRange, index: usize) CharRangePointRange {
        const pts = self.points.items;
        return .{
            .lo = pts[index * 2],
            .hi = pts[index * 2 + 1],
        };
    }

    pub fn isEmpty(self: *const CharRange) bool {
        return self.points.items.len == 0;
    }

    pub fn lastHi(self: *const CharRange) u32 {
        return self.points.items[self.points.items.len - 1];
    }
};

const RangeSet = CharRange;

fn insertionSortPointPairs(points: []u32) void {
    var i: usize = 2;
    while (i < points.len) : (i += 2) {
        const lo = points[i];
        const hi = points[i + 1];
        var j = i;
        while (j >= 2 and points[j - 2] > lo) : (j -= 2) {
            points[j] = points[j - 2];
            points[j + 1] = points[j - 1];
        }
        points[j] = lo;
        points[j + 1] = hi;
    }
}

fn generalCategory(allocator: std.mem.Allocator, name: []const u8) UnicodeError!RangeSet {
    const gc = names.gcIndex(name) orelse return error.InvalidProperty;
    return try unicodeGeneralCategory1(allocator, names.gcMaskByIndex(gc));
}

fn unicodeGeneralCategory1(allocator: std.mem.Allocator, gc_mask: u32) std.mem.Allocator.Error!RangeSet {
    var cr = RangeSet.init(allocator);
    errdefer cr.deinit();
    var p: usize = 0;
    var c: u32 = 0;
    while (p < data.unicode_gc_table.len) {
        const b = data.unicode_gc_table[p];
        p += 1;
        var n: u32 = b >> 5;
        const v = b & 0x1f;
        if (n == 7) {
            n = data.unicode_gc_table[p];
            p += 1;
            if (n < 128) {
                n += 7;
            } else if (n < 128 + 64) {
                n = ((n - 128) << 8) | data.unicode_gc_table[p];
                p += 1;
                n += 7 + 128;
            } else {
                n = ((n - 128 - 64) << 16) | (@as(u32, data.unicode_gc_table[p]) << 8) | data.unicode_gc_table[p + 1];
                p += 2;
                n += 7 + 128 + (1 << 14);
            }
        }
        var c0 = c;
        c += n + 1;
        if (v == 31) {
            const upper_lower = gc_mask & (names.gcBit("Lu") | names.gcBit("Ll"));
            if (upper_lower != 0) {
                if (upper_lower == (names.gcBit("Lu") | names.gcBit("Ll"))) {
                    try cr.addInterval(c0, c);
                } else {
                    if ((gc_mask & names.gcBit("Ll")) != 0) c0 += 1;
                    while (c0 < c) : (c0 += 2) try cr.addInterval(c0, c0 + 1);
                }
            }
        } else if (((gc_mask >> @intCast(v)) & 1) != 0) {
            try cr.addInterval(c0, c);
        }
    }
    return cr;
}

fn unicodeProp1(allocator: std.mem.Allocator, prop: data.Prop) UnicodeError!RangeSet {
    const table = data.propTable(prop) orelse return error.InvalidProperty;
    var cr = RangeSet.init(allocator);
    errdefer cr.deinit();
    try cr.points.ensureTotalCapacity(allocator, table.len);

    var p: usize = 0;
    var c: u32 = 0;
    var bit = false;
    while (p < table.len) {
        var c0 = c;
        const b = table[p];
        p += 1;
        if (b < 64) {
            c += (b >> 3) + 1;
            if (bit) try cr.addInterval(c0, c);
            bit = !bit;
            c0 = c;
            c += (b & 7) + 1;
        } else if (b >= 0x80) {
            c += b - 0x80 + 1;
        } else if (b < 0x60) {
            c += ((@as(u32, b - 0x40) << 8) | table[p]) + 1;
            p += 1;
        } else {
            c += ((@as(u32, b - 0x60) << 16) | (@as(u32, table[p]) << 8) | table[p + 1]) + 1;
            p += 2;
        }
        if (bit) try cr.addInterval(c0, c);
        bit = !bit;
    }
    return cr;
}

fn unicodeCase1(allocator: std.mem.Allocator, case_mask: u32) std.mem.Allocator.Error!RangeSet {
    var cr = RangeSet.init(allocator);
    errdefer cr.deinit();
    if (case_mask == 0) return cr;
    try cr.points.ensureTotalCapacity(allocator, data.case_conv_table1.len * 2);

    const tab_run_mask = [_]u32{
        (1 << RUN_TYPE_U) | (1 << RUN_TYPE_UF) | (1 << RUN_TYPE_UL) | (1 << RUN_TYPE_LSU) | (1 << RUN_TYPE_U2L_399_EXT2) | (1 << RUN_TYPE_UF_D20) | (1 << RUN_TYPE_UF_D1_EXT) | (1 << RUN_TYPE_U_EXT) | (1 << RUN_TYPE_UF_EXT2) | (1 << RUN_TYPE_UF_EXT3),
        (1 << RUN_TYPE_L) | (1 << RUN_TYPE_LF) | (1 << RUN_TYPE_UL) | (1 << RUN_TYPE_LSU) | (1 << RUN_TYPE_U2L_399_EXT2) | (1 << RUN_TYPE_LF_EXT) | (1 << RUN_TYPE_LF_EXT2),
        (1 << RUN_TYPE_UF) | (1 << RUN_TYPE_LF) | (1 << RUN_TYPE_UL) | (1 << RUN_TYPE_LSU) | (1 << RUN_TYPE_U2L_399_EXT2) | (1 << RUN_TYPE_LF_EXT) | (1 << RUN_TYPE_LF_EXT2) | (1 << RUN_TYPE_UF_D20) | (1 << RUN_TYPE_UF_D1_EXT) | (1 << RUN_TYPE_UF_EXT2) | (1 << RUN_TYPE_UF_EXT3),
    };
    var mask: u32 = 0;
    for (tab_run_mask, 0..) |run_mask, i| {
        if (((case_mask >> @intCast(i)) & 1) != 0) mask |= run_mask;
    }
    for (data.case_conv_table1) |v| {
        const typ = (v >> (32 - 17 - 7 - 4)) & 0xf;
        var code = v >> (32 - 17);
        const len = (v >> (32 - 17 - 7)) & 0x7f;
        if (((mask >> @intCast(typ)) & 1) == 0) continue;
        switch (typ) {
            RUN_TYPE_UL => {
                if ((case_mask & properties.CASE_U) != 0 and (case_mask & (properties.CASE_L | properties.CASE_F)) != 0) {
                    try cr.addInterval(code, code + len);
                } else {
                    code += if ((case_mask & properties.CASE_U) != 0) @as(u32, 1) else 0;
                    var i: u32 = 0;
                    while (i < len) : (i += 2) try cr.addInterval(code + i, code + i + 1);
                }
            },
            RUN_TYPE_LSU => {
                if ((case_mask & properties.CASE_U) != 0 and (case_mask & (properties.CASE_L | properties.CASE_F)) != 0) {
                    try cr.addInterval(code, code + len);
                } else {
                    if ((case_mask & properties.CASE_U) == 0) try cr.addInterval(code, code + 1);
                    try cr.addInterval(code + 1, code + 2);
                    if ((case_mask & properties.CASE_U) != 0) try cr.addInterval(code + 2, code + 3);
                }
            },
            else => try cr.addInterval(code, code + len),
        }
    }
    return cr;
}

fn unicodePropOps(allocator: std.mem.Allocator, ops: []const properties.Op) UnicodeError!RangeSet {
    var stack: [4]RangeSet = undefined;
    var stack_len: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < stack_len) : (i += 1) stack[i].deinit();
    }

    for (ops) |op| {
        switch (op) {
            .gc => |mask| {
                std.debug.assert(stack_len < stack.len);
                stack[stack_len] = try unicodeGeneralCategory1(allocator, mask);
                stack_len += 1;
            },
            .prop => |prop_idx| {
                std.debug.assert(stack_len < stack.len);
                stack[stack_len] = try unicodeProp1(allocator, prop_idx);
                stack_len += 1;
            },
            .case_mask => |mask| {
                std.debug.assert(stack_len < stack.len);
                stack[stack_len] = try unicodeCase1(allocator, mask);
                stack_len += 1;
            },
            .op_union => {
                std.debug.assert(stack_len >= 2);
                try stack[stack_len - 2].unionWith(&stack[stack_len - 1]);
                stack[stack_len - 1].deinit();
                stack_len -= 1;
            },
            .op_inter => {
                std.debug.assert(stack_len >= 2);
                try stack[stack_len - 2].intersectWith(&stack[stack_len - 1]);
                stack[stack_len - 1].deinit();
                stack_len -= 1;
            },
            .op_xor => {
                std.debug.assert(stack_len >= 2);
                try stack[stack_len - 2].xorWith(&stack[stack_len - 1]);
                stack[stack_len - 1].deinit();
                stack_len -= 1;
            },
            .op_invert => {
                std.debug.assert(stack_len >= 1);
                try stack[stack_len - 1].invert();
            },
        }
    }

    std.debug.assert(stack_len == 1);
    return stack[0];
}

fn unicodeProp(allocator: std.mem.Allocator, name: []const u8) UnicodeError!RangeSet {
    const prop = names.propIndex(name) orelse return error.InvalidProperty;

    if (properties.derived(prop)) |derived| {
        switch (derived) {
            .ascii => {
                var cr = RangeSet.init(allocator);
                errdefer cr.deinit();
                try cr.addInterval(0x00, 0x80);
                return cr;
            },
            .any => {
                var cr = RangeSet.init(allocator);
                errdefer cr.deinit();
                try cr.addInterval(0, unicode_limit);
                return cr;
            },
            .ops => |ops| return try unicodePropOps(allocator, ops),
        }
    }

    return try unicodeProp1(allocator, prop);
}

fn scriptRanges(allocator: std.mem.Allocator, script_name: []const u8, is_ext: bool) UnicodeError!RangeSet {
    const script_idx = names.scriptIndex(script_name) orelse return error.InvalidProperty;
    const script_idx_value = @intFromEnum(script_idx);
    const is_common = script_idx == data.Script.Common or script_idx == data.Script.Inherited;

    var base = RangeSet.init(allocator);
    errdefer base.deinit();
    var p: usize = 0;
    var c: u32 = 0;
    while (p < data.unicode_script_table.len) {
        const b = data.unicode_script_table[p];
        p += 1;
        const typ = b >> 7;
        var n: u32 = b & 0x7f;
        if (n < 96) {} else if (n < 112) {
            n = ((n - 96) << 8) | data.unicode_script_table[p];
            p += 1;
            n += 96;
        } else {
            n = ((n - 112) << 16) | (@as(u32, data.unicode_script_table[p]) << 8) | data.unicode_script_table[p + 1];
            p += 2;
            n += 96 + (1 << 12);
        }
        const c1 = c + n + 1;
        if (typ != 0) {
            const v = data.unicode_script_table[p];
            p += 1;
            if (v == script_idx_value or script_idx == data.Script.Unknown) try base.addInterval(c, c1);
        }
        c = c1;
    }
    if (script_idx == data.Script.Unknown) try base.invert();

    if (!is_ext) return base;

    var ext = RangeSet.init(allocator);
    defer ext.deinit();
    p = 0;
    c = 0;
    while (p < data.unicode_script_ext_table.len) {
        const b = data.unicode_script_ext_table[p];
        p += 1;
        var n: u32 = 0;
        if (b < 128) {
            n = b;
        } else if (b < 128 + 64) {
            n = ((@as(u32, b) - 128) << 8) | data.unicode_script_ext_table[p];
            p += 1;
            n += 128;
        } else {
            n = ((@as(u32, b) - 128 - 64) << 16) | (@as(u32, data.unicode_script_ext_table[p]) << 8) | data.unicode_script_ext_table[p + 1];
            p += 2;
            n += 128 + (1 << 14);
        }
        const c1 = c + n + 1;
        const v_len = data.unicode_script_ext_table[p];
        p += 1;
        if (is_common) {
            if (v_len != 0) try ext.addInterval(c, c1);
        } else {
            for (data.unicode_script_ext_table[p .. p + v_len]) |value| {
                if (value == script_idx_value) {
                    try ext.addInterval(c, c1);
                    break;
                }
            }
        }
        p += v_len;
        c = c1;
    }
    if (is_common) {
        try ext.invert();
        try base.intersectWith(&ext);
    } else {
        try base.unionWith(&ext);
    }
    return base;
}

pub fn addSequenceProperty(
    allocator: std.mem.Allocator,
    comptime Context: type,
    ctx: *Context,
    prop_name: []const u8,
    comptime callback: fn (*Context, []const u21) std.mem.Allocator.Error!void,
) UnicodeError!bool {
    const prop = names.sequencePropIndex(prop_name) orelse return false;
    try sequenceProp1(allocator, Context, ctx, prop, callback);
    return true;
}

pub fn isSequencePropertyName(prop_name: []const u8) bool {
    return names.sequencePropIndex(prop_name) != null;
}

const sequence_max_len = 16;

fn sequenceProp1(
    allocator: std.mem.Allocator,
    comptime Context: type,
    ctx: *Context,
    prop: data.SequenceProp,
    comptime callback: fn (*Context, []const u21) std.mem.Allocator.Error!void,
) UnicodeError!void {
    switch (prop) {
        .Basic_Emoji => {
            try emitPropertySequences(allocator, Context, ctx, data.Prop.Basic_Emoji1, &.{}, callback);
            try emitPropertySequences(allocator, Context, ctx, data.Prop.Basic_Emoji2, &.{0xfe0f}, callback);
        },
        .RGI_Emoji_Modifier_Sequence => {
            var cr = try unicodeProp1(allocator, data.Prop.Emoji_Modifier_Base);
            defer cr.deinit();
            cr.normalize();

            var seq: [sequence_max_len]u21 = undefined;
            var range_index: usize = 0;
            while (range_index < cr.rangeCount()) : (range_index += 1) {
                const range = cr.rangeAt(range_index);
                var c = range.lo;
                while (c < range.hi) : (c += 1) {
                    var j: u21 = 0;
                    while (j < 5) : (j += 1) {
                        seq[0] = @intCast(c);
                        seq[1] = 0x1f3fb + j;
                        try callback(ctx, seq[0..2]);
                    }
                }
            }
        },
        .RGI_Emoji_Flag_Sequence => {
            var cr = try unicodeProp1(allocator, data.Prop.RGI_Emoji_Flag_Sequence);
            defer cr.deinit();
            cr.normalize();

            var seq: [sequence_max_len]u21 = undefined;
            var range_index: usize = 0;
            while (range_index < cr.rangeCount()) : (range_index += 1) {
                const range = cr.rangeAt(range_index);
                var c = range.lo;
                while (c < range.hi) : (c += 1) {
                    const c0 = c / 26;
                    const c1 = c % 26;
                    seq[0] = @intCast(0x1f1e6 + c0);
                    seq[1] = @intCast(0x1f1e6 + c1);
                    try callback(ctx, seq[0..2]);
                }
            }
        },
        .RGI_Emoji_ZWJ_Sequence => try emitZwjSequences(Context, ctx, callback),
        .RGI_Emoji_Tag_Sequence => {
            var seq: [sequence_max_len]u21 = undefined;
            var i: usize = 0;
            while (i < data.unicode_rgi_emoji_tag_sequence.len) {
                var j: usize = 0;
                seq[j] = 0x1f3f4;
                j += 1;
                while (true) {
                    const c = data.unicode_rgi_emoji_tag_sequence[i];
                    i += 1;
                    if (c == 0) break;
                    std.debug.assert(j < seq.len);
                    seq[j] = 0xe0000 + @as(u21, c);
                    j += 1;
                }
                std.debug.assert(j < seq.len);
                seq[j] = 0xe007f;
                j += 1;
                try callback(ctx, seq[0..j]);
            }
        },
        .Emoji_Keycap_Sequence => try emitPropertySequences(allocator, Context, ctx, data.Prop.Emoji_Keycap_Sequence, &.{ 0xfe0f, 0x20e3 }, callback),
        .RGI_Emoji => {
            var i = @intFromEnum(data.SequenceProp.Basic_Emoji);
            while (i <= @intFromEnum(data.SequenceProp.RGI_Emoji_ZWJ_Sequence)) : (i += 1) {
                try sequenceProp1(allocator, Context, ctx, @enumFromInt(i), callback);
            }
        },
    }
}

fn emitPropertySequences(
    allocator: std.mem.Allocator,
    comptime Context: type,
    ctx: *Context,
    prop: data.Prop,
    comptime suffix: []const u21,
    comptime callback: fn (*Context, []const u21) std.mem.Allocator.Error!void,
) UnicodeError!void {
    var cr = try unicodeProp1(allocator, prop);
    defer cr.deinit();
    cr.normalize();

    var seq: [sequence_max_len]u21 = undefined;
    var range_index: usize = 0;
    while (range_index < cr.rangeCount()) : (range_index += 1) {
        const range = cr.rangeAt(range_index);
        var c = range.lo;
        while (c < range.hi) : (c += 1) {
            seq[0] = @intCast(c);
            inline for (suffix, 0..) |cp, i| seq[i + 1] = cp;
            try callback(ctx, seq[0 .. suffix.len + 1]);
        }
    }
}

fn emitZwjSequences(
    comptime Context: type,
    ctx: *Context,
    comptime callback: fn (*Context, []const u21) std.mem.Allocator.Error!void,
) std.mem.Allocator.Error!void {
    var i: usize = 0;
    while (i < data.unicode_rgi_emoji_zwj_sequence.len) {
        const len = data.unicode_rgi_emoji_zwj_sequence[i];
        i += 1;

        var seq: [sequence_max_len]u21 = undefined;
        var mod_pos: [2]usize = undefined;
        var k: usize = 0;
        var mod: u2 = 0;
        var mod_count: usize = 0;
        var hc_pos: ?usize = null;

        var j: usize = 0;
        while (j < len) : (j += 1) {
            var code = @as(u16, data.unicode_rgi_emoji_zwj_sequence[i]) |
                (@as(u16, data.unicode_rgi_emoji_zwj_sequence[i + 1]) << 8);
            i += 2;

            const pres = code >> 15;
            const mod1: u2 = @intCast((code >> 13) & 3);
            code &= 0x1fff;
            const c: u21 = if (code < 0x1000)
                0x2000 + @as(u21, code)
            else
                0x1f000 + (@as(u21, code) - 0x1000);

            if (c == 0x1f9b0) hc_pos = k;
            std.debug.assert(k < seq.len);
            seq[k] = c;
            k += 1;

            if (mod1 != 0) {
                std.debug.assert(mod_count < mod_pos.len);
                mod = mod1;
                mod_pos[mod_count] = k;
                mod_count += 1;
                std.debug.assert(k < seq.len);
                seq[k] = 0;
                k += 1;
            }
            if (pres != 0) {
                std.debug.assert(k < seq.len);
                seq[k] = 0xfe0f;
                k += 1;
            }
            if (j < len - 1) {
                std.debug.assert(k < seq.len);
                seq[k] = 0x200d;
                k += 1;
            }
        }

        const n_mod: usize = switch (mod) {
            1 => 5,
            2 => 25,
            3 => 20,
            else => 1,
        };
        const n_hc: usize = if (hc_pos != null) 4 else 1;

        var hc_idx: usize = 0;
        while (hc_idx < n_hc) : (hc_idx += 1) {
            var mod_idx: usize = 0;
            while (mod_idx < n_mod) : (mod_idx += 1) {
                if (hc_pos) |pos| seq[pos] = 0x1f9b0 + @as(u21, @intCast(hc_idx));

                switch (mod) {
                    1 => seq[mod_pos[0]] = 0x1f3fb + @as(u21, @intCast(mod_idx)),
                    2, 3 => {
                        var skin0 = mod_idx / 5;
                        const skin1 = mod_idx % 5;
                        if (mod == 3 and skin0 >= skin1) skin0 += 1;
                        seq[mod_pos[0]] = 0x1f3fb + @as(u21, @intCast(skin0));
                        seq[mod_pos[1]] = 0x1f3fb + @as(u21, @intCast(skin1));
                    },
                    else => {},
                }
                try callback(ctx, seq[0..k]);
            }
        }
    }
}

test "unicode functionality" {
    try std.testing.expect(isIdentifierStart('A'));
    try std.testing.expect(isIdentifierStart(0x03c0));
    try std.testing.expect(!isIdentifierStart(0x01f600));
    try std.testing.expect(isIdentifierContinue('9'));
    try std.testing.expect(isIdentifierContinue(0x200c));
    try std.testing.expectEqual(@as(u8, 'A'), toUpperAscii('a'));
    try std.testing.expect(equalsIgnoreAsciiCase("AbC", "aBc"));
    try std.testing.expectEqual(@as(u21, 'k'), regexpCanonicalize(0x212a, true));
    try std.testing.expectEqual(@as(u21, 's'), regexpCanonicalize(0x017f, true));

    const nfc_input = [_]u32{ 0x1e9b, 0x0323 };
    const nfc = try normalizeAlloc(std.testing.allocator, &nfc_input, .nfc);
    defer std.testing.allocator.free(nfc);
    try std.testing.expectEqualSlices(u32, &[_]u32{ 0x1e9b, 0x0323 }, nfc);
    const nfd = try normalizeAlloc(std.testing.allocator, &nfc_input, .nfd);
    defer std.testing.allocator.free(nfd);
    try std.testing.expectEqualSlices(u32, &[_]u32{ 0x017f, 0x0323, 0x0307 }, nfd);
    const nfkc = try normalizeAlloc(std.testing.allocator, &nfc_input, .nfkc);
    defer std.testing.allocator.free(nfkc);
    try std.testing.expectEqualSlices(u32, &[_]u32{0x1e69}, nfkc);
    const nfkd = try normalizeAlloc(std.testing.allocator, &nfc_input, .nfkd);
    defer std.testing.allocator.free(nfkd);
    try std.testing.expectEqualSlices(u32, &[_]u32{ 0x0073, 0x0323, 0x0307 }, nfkd);

    var ascii_ranges = try propertyRangePoints(std.testing.allocator, "ASCII", false);
    defer ascii_ranges.deinit();
    try std.testing.expect(pointsContain(ascii_ranges.items(), 'A'));
    try std.testing.expect(!pointsContain(ascii_ranges.items(), 0x80));
    var non_ascii_ranges = try propertyRangePoints(std.testing.allocator, "ASCII", true);
    defer non_ascii_ranges.deinit();
    try std.testing.expect(!pointsContain(non_ascii_ranges.items(), 'A'));
    try std.testing.expect(pointsContain(non_ascii_ranges.items(), 0x80));
    try std.testing.expect(pointsContain(non_ascii_ranges.items(), 0x10ffff));
    var greek_ranges = try propertyRangePoints(std.testing.allocator, "Script=Greek", false);
    defer greek_ranges.deinit();
    try std.testing.expect(pointsContain(greek_ranges.items(), 0x03c0));
    try std.testing.expect(!pointsContain(greek_ranges.items(), 'A'));
    try std.testing.expect(!pointsContain(greek_ranges.items(), 0x038b));

    var unknown_script_ranges = try propertyRangePoints(std.testing.allocator, "Script=Unknown", false);
    defer unknown_script_ranges.deinit();
    try std.testing.expect(pointsContain(unknown_script_ranges.items(), 0x038b));
    try std.testing.expect(pointsContain(unknown_script_ranges.items(), 0x0e01f0));
    try std.testing.expect(pointsContain(unknown_script_ranges.items(), 0x10ffff));
    try std.testing.expect(!pointsContain(unknown_script_ranges.items(), 0x03c0));

    var unknown_script_ext_ranges = try propertyRangePoints(std.testing.allocator, "Script_Extensions=Unknown", false);
    defer unknown_script_ext_ranges.deinit();
    try std.testing.expect(pointsContain(unknown_script_ext_ranges.items(), 0x038b));
    try std.testing.expect(pointsContain(unknown_script_ext_ranges.items(), 0x0e01f0));
    try std.testing.expect(pointsContain(unknown_script_ext_ranges.items(), 0x10ffff));
    try std.testing.expect(!pointsContain(unknown_script_ext_ranges.items(), 0x03c0));

    try std.testing.expectError(error.InvalidProperty, propertyRangePoints(std.testing.allocator, "ID_Compat_Math_Start", false));
    try std.testing.expectError(error.InvalidProperty, propertyRangePoints(std.testing.allocator, "ID_Compat_Math_Continue", false));
    try std.testing.expectError(error.InvalidProperty, propertyRangePoints(std.testing.allocator, "InCB", false));
}

test "regexp unicode shortcut matches range builder boundaries" {
    const expressions = [_][]const u8{
        "ASCII",
        "Any",
        "Assigned",
        "Math",
        "Lowercase",
        "Uppercase",
        "Cased",
        "Alphabetic",
        "Grapheme_Base",
        "Grapheme_Extend",
        "ID_Start",
        "ID_Continue",
        "XID_Start",
        "XID_Continue",
        "Changes_When_Uppercased",
        "Changes_When_Lowercased",
        "Changes_When_Casemapped",
        "Changes_When_Titlecased",
        "Changes_When_Casefolded",
        "Changes_When_NFKC_Casefolded",
        "gc=Lu",
        "General_Category=L",
        "Script=Greek",
        "Script_Extensions=Greek",
        "Script=Unknown",
        "Script_Extensions=Unknown",
        "Script_Extensions=Inherited",
    };

    for (expressions) |expr| {
        try expectRegexpShortcutMatchesRangeBuilder(expr);
    }
}

test "unicode surrogate range helpers cover boundaries" {
    try std.testing.expect(!isHighSurrogateUnit(0xd7ff));
    try std.testing.expect(isHighSurrogateUnit(0xd800));
    try std.testing.expect(isHighSurrogateUnit(0xdbff));
    try std.testing.expect(!isHighSurrogateUnit(0xdc00));

    try std.testing.expect(!isLowSurrogateUnit(0xdbff));
    try std.testing.expect(isLowSurrogateUnit(0xdc00));
    try std.testing.expect(isLowSurrogateUnit(0xdfff));
    try std.testing.expect(!isLowSurrogateUnit(0xe000));

    try std.testing.expect(isHighSurrogateCodePoint(0xd800));
    try std.testing.expect(isLowSurrogateCodePoint(0xdfff));
    try std.testing.expect(!isHighSurrogateCodePoint(0x10000));
    try std.testing.expect(!isLowSurrogateCodePoint(0x10ffff));
    try std.testing.expect(isSurrogateCodePoint(0xd800));
    try std.testing.expect(isSurrogateCodePoint(0xdfff));
    try std.testing.expect(!isSurrogateCodePoint(0xe000));

    try std.testing.expectEqual(@as(u21, 0x10000), codePointFromSurrogatePair(0xd800, 0xdc00));
    try std.testing.expectEqual(@as(u21, 0x1f600), codePointFromSurrogatePair(0xd83d, 0xde00));
    try std.testing.expectEqual(@as(u21, 0x10ffff), codePointFromSurrogatePair(0xdbff, 0xdfff));

    try std.testing.expectEqual(SurrogatePair{ .high = 0xd800, .low = 0xdc00 }, surrogatePairFromCodePoint(0x10000));
    try std.testing.expectEqual(SurrogatePair{ .high = 0xd83d, .low = 0xde00 }, surrogatePairFromCodePoint(0x1f600));
    try std.testing.expectEqual(SurrogatePair{ .high = 0xdbff, .low = 0xdfff }, surrogatePairFromCodePoint(0x10ffff));
}

test "unicode UTF-16 append helper emits BMP units and surrogate pairs" {
    var out = std.ArrayList(u16).empty;
    defer out.deinit(std.testing.allocator);

    try appendUtf16CodePoint(std.testing.allocator, &out, 'A');
    try appendUtf16CodePoint(std.testing.allocator, &out, 0xd800);
    try appendUtf16CodePoint(std.testing.allocator, &out, 0x1f600);
    try std.testing.expectEqualSlices(u16, &.{ 'A', 0xd800, 0xd83d, 0xde00 }, out.items);
}

test "unicode UTF-8 append helper preserves existing surrogate-half encoding" {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(std.testing.allocator);

    try appendUtf8CodePoint(std.testing.allocator, &out, 'A');
    try std.testing.expectEqualStrings("A", out.items);

    out.clearRetainingCapacity();
    try appendUtf8CodePoint(std.testing.allocator, &out, 0x00e9);
    try std.testing.expectEqualSlices(u8, "\xc3\xa9", out.items);

    out.clearRetainingCapacity();
    try appendUtf8CodePoint(std.testing.allocator, &out, 0xd800);
    try std.testing.expectEqualSlices(u8, "\xed\xa0\x80", out.items);

    out.clearRetainingCapacity();
    try appendUtf8CodePoint(std.testing.allocator, &out, 0x1f600);
    try std.testing.expectEqualSlices(u8, "\xf0\x9f\x98\x80", out.items);
}

test "unicode UTF-16 append helper combines surrogate pairs and preserves lone halves" {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(std.testing.allocator);

    try appendUtf16UnitsAsUtf8(std.testing.allocator, &out, &.{ 'A', 0x00e9, 0xd83d, 0xde00, 0xd800 });
    try std.testing.expectEqualSlices(u8, "A\xc3\xa9\xf0\x9f\x98\x80\xed\xa0\x80", out.items);
}

test "unicode ascii character helpers cover ECMAScript regexp sets" {
    try std.testing.expect(isAsciiDigitUnit('0'));
    try std.testing.expect(isAsciiDigitUnit('9'));
    try std.testing.expect(!isAsciiDigitUnit('/'));
    try std.testing.expect(!isAsciiDigitUnit(':'));

    try std.testing.expect(isAsciiAlphaCodePoint('A'));
    try std.testing.expect(isAsciiAlphaCodePoint('z'));
    try std.testing.expect(!isAsciiAlphaCodePoint('_'));
    try std.testing.expect(!isAsciiAlphaCodePoint(0x80));

    try std.testing.expect(isAsciiWordUnit('_'));
    try std.testing.expect(isAsciiWordUnit('a'));
    try std.testing.expect(isAsciiWordUnit('9'));
    try std.testing.expect(!isAsciiWordUnit('-'));
    try std.testing.expect(!isAsciiWordCodePoint(0x80));
}

test "unicode ECMAScript whitespace and line terminator helper covers spec units" {
    const whitespace_units = [_]u16{
        0x0009,
        0x000a,
        0x000b,
        0x000c,
        0x000d,
        0x0020,
        0x00a0,
        0x1680,
        0x2000,
        0x2001,
        0x2002,
        0x2003,
        0x2004,
        0x2005,
        0x2006,
        0x2007,
        0x2008,
        0x2009,
        0x200a,
        0x2028,
        0x2029,
        0x202f,
        0x205f,
        0x3000,
        0xfeff,
    };
    for (whitespace_units) |unit| {
        try std.testing.expect(isEcmaWhitespaceOrLineTerminatorUnit(unit));
        try std.testing.expect(isEcmaWhitespaceOrLineTerminatorCodePoint(unit));
        try std.testing.expect(rangesContain(ecmaWhitespaceOrLineTerminatorRanges[0..], unit));
    }

    const non_whitespace_units = [_]u16{
        0x0008,
        0x000e,
        'A',
        '_',
        0x180e,
        0x200b,
        0x2060,
        0xfffe,
    };
    for (non_whitespace_units) |unit| {
        try std.testing.expect(!isEcmaWhitespaceOrLineTerminatorUnit(unit));
        try std.testing.expect(!isEcmaWhitespaceOrLineTerminatorCodePoint(unit));
        try std.testing.expect(!rangesContain(ecmaWhitespaceOrLineTerminatorRanges[0..], unit));
    }
}

test "unicode ECMAScript line terminator helpers cover unit and code point forms" {
    const line_terminators = [_]u21{ '\n', '\r', 0x2028, 0x2029 };
    for (line_terminators) |cp| {
        try std.testing.expect(isEcmaLineTerminatorCodePoint(cp));
        try std.testing.expect(isEcmaLineTerminatorUnit(@intCast(cp)));
    }

    const non_line_terminators = [_]u21{ 0x000b, 0x000c, ' ', 0x0085, 0x2000, 0xfeff, 0x10000 };
    for (non_line_terminators) |cp| {
        try std.testing.expect(!isEcmaLineTerminatorCodePoint(cp));
        if (cp <= std.math.maxInt(u16)) {
            try std.testing.expect(!isEcmaLineTerminatorUnit(@intCast(cp)));
        }
    }
}

test "unicode ascii identifier byte helpers cover ECMAScript starts and parts" {
    try std.testing.expect(isAsciiIdentifierStartByte('A'));
    try std.testing.expect(isAsciiIdentifierStartByte('z'));
    try std.testing.expect(isAsciiIdentifierStartByte('_'));
    try std.testing.expect(isAsciiIdentifierStartByte('$'));
    try std.testing.expect(!isAsciiIdentifierStartByte('0'));
    try std.testing.expect(!isAsciiIdentifierStartByte(0x80));

    try std.testing.expect(isAsciiIdentifierPartByte('A'));
    try std.testing.expect(isAsciiIdentifierPartByte('9'));
    try std.testing.expect(isAsciiIdentifierPartByte('_'));
    try std.testing.expect(isAsciiIdentifierPartByte('$'));
    try std.testing.expect(!isAsciiIdentifierPartByte('-'));
    try std.testing.expect(!isAsciiIdentifierPartByte(0x80));
}

test "unicode ascii whitespace byte helper covers source scanners" {
    try std.testing.expect(isAsciiWhitespaceByte(' '));
    try std.testing.expect(isAsciiWhitespaceByte('\t'));
    try std.testing.expect(isAsciiWhitespaceByte('\n'));
    try std.testing.expect(isAsciiWhitespaceByte('\r'));
    try std.testing.expect(isAsciiWhitespaceByte(0x0b));
    try std.testing.expect(isAsciiWhitespaceByte(0x0c));
    try std.testing.expect(!isAsciiWhitespaceByte('a'));
    try std.testing.expect(!isAsciiWhitespaceByte(0x85));
}

test "unicode ascii digit byte helpers cover numeric literal digit sets" {
    try std.testing.expect(isAsciiBinaryDigitByte('0'));
    try std.testing.expect(isAsciiBinaryDigitByte('1'));
    try std.testing.expect(!isAsciiBinaryDigitByte('2'));

    try std.testing.expect(isAsciiOctalDigitByte('0'));
    try std.testing.expect(isAsciiOctalDigitByte('7'));
    try std.testing.expect(!isAsciiOctalDigitByte('8'));

    try std.testing.expect(isAsciiDigitByte('0'));
    try std.testing.expect(isAsciiDigitByte('9'));
    try std.testing.expect(!isAsciiDigitByte('/'));
    try std.testing.expect(!isAsciiDigitByte(':'));
}

test "unicode ascii alpha byte helpers cover ECMAScript ASCII classes" {
    try std.testing.expect(isAsciiUpperByte('A'));
    try std.testing.expect(isAsciiUpperByte('Z'));
    try std.testing.expect(!isAsciiUpperByte('a'));

    try std.testing.expect(isAsciiLowerByte('a'));
    try std.testing.expect(isAsciiLowerByte('z'));
    try std.testing.expect(!isAsciiLowerByte('A'));

    try std.testing.expect(isAsciiAlphaByte('A'));
    try std.testing.expect(isAsciiAlphaByte('z'));
    try std.testing.expect(!isAsciiAlphaByte('_'));

    try std.testing.expect(isAsciiAlphanumericByte('A'));
    try std.testing.expect(isAsciiAlphanumericByte('9'));
    try std.testing.expect(!isAsciiAlphanumericByte('_'));

    try std.testing.expect(isAsciiWordByte('_'));
    try std.testing.expect(isAsciiWordByte('a'));
    try std.testing.expect(isAsciiWordByte('9'));
    try std.testing.expect(!isAsciiWordByte('-'));
}

test "unicode ascii hex helpers cover digit values" {
    try std.testing.expectEqual(@as(u8, 0), asciiHexDigitValueByte('0'));
    try std.testing.expectEqual(@as(u8, 9), asciiHexDigitValueByte('9'));
    try std.testing.expectEqual(@as(u8, 10), asciiHexDigitValueByte('a'));
    try std.testing.expectEqual(@as(u8, 15), asciiHexDigitValueByte('f'));
    try std.testing.expectEqual(@as(u8, 10), asciiHexDigitValueByte('A'));
    try std.testing.expectEqual(@as(u8, 15), asciiHexDigitValueByte('F'));
    try std.testing.expectEqual(@as(?u8, null), asciiHexDigitValueByte('g'));
    try std.testing.expectEqual(@as(?u8, null), asciiHexDigitValueByte('/'));

    try std.testing.expectEqual(@as(u8, 15), asciiHexDigitValueUnit('F'));
    try std.testing.expectEqual(@as(?u8, null), asciiHexDigitValueUnit(0x100));

    try std.testing.expect(isAsciiHexDigitByte('0'));
    try std.testing.expect(isAsciiHexDigitByte('f'));
    try std.testing.expect(isAsciiHexDigitByte('F'));
    try std.testing.expect(!isAsciiHexDigitByte('g'));
    try std.testing.expect(!isAsciiHexDigitByte('_'));

    try std.testing.expect(isAsciiHexDigitUnit('a'));
    try std.testing.expect(!isAsciiHexDigitUnit(0x100));

    try std.testing.expectEqual(@as(u8, 0), asciiUpperHexDigitValueByte('0'));
    try std.testing.expectEqual(@as(u8, 9), asciiUpperHexDigitValueByte('9'));
    try std.testing.expectEqual(@as(u8, 10), asciiUpperHexDigitValueByte('A'));
    try std.testing.expectEqual(@as(u8, 15), asciiUpperHexDigitValueByte('F'));
    try std.testing.expectEqual(@as(?u8, null), asciiUpperHexDigitValueByte('a'));
    try std.testing.expectEqual(@as(?u8, null), asciiUpperHexDigitValueByte('g'));

    try std.testing.expectEqual(@as(u8, '0'), asciiLowerHexDigitChar(0));
    try std.testing.expectEqual(@as(u8, 'a'), asciiLowerHexDigitChar(10));
    try std.testing.expectEqual(@as(u8, 'f'), asciiLowerHexDigitChar(15));

    try std.testing.expectEqual(@as(u8, '0'), asciiUpperHexDigitChar(0));
    try std.testing.expectEqual(@as(u8, 'A'), asciiUpperHexDigitChar(10));
    try std.testing.expectEqual(@as(u8, 'F'), asciiUpperHexDigitChar(15));
}

test "unicode ascii radix digit helper covers base-36 digit values" {
    try std.testing.expectEqual(@as(u8, 0), asciiRadixDigitValueByte('0'));
    try std.testing.expectEqual(@as(u8, 9), asciiRadixDigitValueByte('9'));
    try std.testing.expectEqual(@as(u8, 10), asciiRadixDigitValueByte('a'));
    try std.testing.expectEqual(@as(u8, 35), asciiRadixDigitValueByte('z'));
    try std.testing.expectEqual(@as(u8, 10), asciiRadixDigitValueByte('A'));
    try std.testing.expectEqual(@as(u8, 35), asciiRadixDigitValueByte('Z'));
    try std.testing.expectEqual(@as(?u8, null), asciiRadixDigitValueByte('_'));
    try std.testing.expectEqual(@as(?u8, null), asciiRadixDigitValueByte(0x80));
}

fn rangesContain(ranges: []const CodePointRange, code_point: u21) bool {
    for (ranges) |range| {
        if (code_point >= range.lo and code_point < range.hi) return true;
    }
    return false;
}

fn pointsContain(points: []const u32, code_point: u21) bool {
    var i: usize = 0;
    while (i + 1 < points.len) : (i += 2) {
        if (code_point >= points[i] and code_point < points[i + 1]) return true;
    }
    return false;
}

fn expectRegexpShortcutMatchesRangeBuilder(expr: []const u8) !void {
    var ranges = try propertyRangePoints(std.testing.allocator, expr, false);
    defer ranges.deinit();
    const points = ranges.items();

    try expectRegexpShortcutPointMatchesRanges(expr, points, 0);
    try expectRegexpShortcutPointMatchesRanges(expr, points, 0x2e2f);
    try expectRegexpShortcutPointMatchesRanges(expr, points, max_code_point);

    var i: usize = 0;
    while (i + 1 < points.len) : (i += 2) {
        const lo = points[i];
        const hi = points[i + 1];
        if (lo > 0 and lo <= max_code_point) try expectRegexpShortcutPointMatchesRanges(expr, points, @intCast(lo - 1));
        if (lo <= max_code_point) try expectRegexpShortcutPointMatchesRanges(expr, points, @intCast(lo));
        if (hi > 0 and hi - 1 <= max_code_point) try expectRegexpShortcutPointMatchesRanges(expr, points, @intCast(hi - 1));
        if (hi <= max_code_point) try expectRegexpShortcutPointMatchesRanges(expr, points, @intCast(hi));
    }
}

fn expectRegexpShortcutPointMatchesRanges(expr: []const u8, points: []const u32, code_point: u21) !void {
    const actual = regexp_properties.isUnicodePropertyMatches(code_point, expr);
    const expected = pointsContain(points, code_point);
    if (actual != expected) {
        std.debug.print("regexp unicode shortcut mismatch expr={s} code_point=0x{x} actual={} expected={}\n", .{
            expr,
            code_point,
            actual,
            expected,
        });
        return error.TestUnexpectedResult;
    }
}

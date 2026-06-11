const std = @import("std");

const data = @import("unicode_data.zig");

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

/// Returns owned half-open Unicode code point ranges. Caller must free with the same allocator.
pub fn propertyRangesAlloc(
    allocator: std.mem.Allocator,
    expr: []const u8,
    inverted: bool,
) UnicodeError![]CodePointRange {
    const equals = std.mem.indexOfScalar(u8, expr, '=');
    const name = if (equals) |pos| expr[0..pos] else expr;
    const value = if (equals) |pos| expr[pos + 1 ..] else "";
    if (name.len == 0 or name.len >= 64 or value.len >= 64) return error.InvalidProperty;

    var ranges = if (std.mem.eql(u8, name, "Script") or std.mem.eql(u8, name, "sc"))
        try scriptRanges(allocator, value, false)
    else if (std.mem.eql(u8, name, "Script_Extensions") or std.mem.eql(u8, name, "scx"))
        try scriptRanges(allocator, value, true)
    else if (std.mem.eql(u8, name, "General_Category") or std.mem.eql(u8, name, "gc"))
        try generalCategory(allocator, value)
    else if (value.len == 0) blk: {
        break :blk generalCategory(allocator, name) catch |err| switch (err) {
            error.InvalidProperty => try unicodeProperty(allocator, name),
            else => return err,
        };
    } else return error.InvalidProperty;
    errdefer ranges.deinit();

    if (inverted) try ranges.invert();
    return try ranges.toOwnedSlice();
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

const RangeSet = struct {
    allocator: std.mem.Allocator,
    ranges: std.ArrayList(CodePointRange),

    fn init(allocator: std.mem.Allocator) RangeSet {
        return .{ .allocator = allocator, .ranges = .empty };
    }

    fn deinit(self: *RangeSet) void {
        self.ranges.deinit(self.allocator);
    }

    fn addInterval(self: *RangeSet, lo_in: u32, hi_in: u32) std.mem.Allocator.Error!void {
        if (hi_in <= lo_in or lo_in >= unicode_limit) return;
        const hi = @min(hi_in, unicode_limit);
        if (hi <= lo_in) return;
        try self.ranges.append(self.allocator, .{ .lo = @intCast(lo_in), .hi = @intCast(hi) });
    }

    fn normalize(self: *RangeSet) void {
        std.mem.sort(CodePointRange, self.ranges.items, {}, rangeLessThan);
        if (self.ranges.items.len <= 1) return;
        var write: usize = 0;
        var read: usize = 1;
        while (read < self.ranges.items.len) : (read += 1) {
            const current = self.ranges.items[read];
            if (current.lo <= self.ranges.items[write].hi) {
                if (current.hi > self.ranges.items[write].hi) self.ranges.items[write].hi = current.hi;
            } else {
                write += 1;
                self.ranges.items[write] = current;
            }
        }
        self.ranges.shrinkRetainingCapacity(write + 1);
    }

    fn unionWith(self: *RangeSet, other: *RangeSet) std.mem.Allocator.Error!void {
        try self.ranges.appendSlice(self.allocator, other.ranges.items);
        self.normalize();
    }

    fn intersectWith(self: *RangeSet, other: *RangeSet) std.mem.Allocator.Error!void {
        self.normalize();
        other.normalize();
        var out = std.ArrayList(CodePointRange).empty;
        errdefer out.deinit(self.allocator);
        var lhs: usize = 0;
        var rhs: usize = 0;
        while (lhs < self.ranges.items.len and rhs < other.ranges.items.len) {
            const a = self.ranges.items[lhs];
            const b = other.ranges.items[rhs];
            const lo = @max(a.lo, b.lo);
            const hi = @min(a.hi, b.hi);
            if (lo < hi) try out.append(self.allocator, .{ .lo = lo, .hi = hi });
            if (a.hi < b.hi) {
                lhs += 1;
            } else {
                rhs += 1;
            }
        }
        self.ranges.deinit(self.allocator);
        self.ranges = out;
    }

    fn xorWith(self: *RangeSet, other: *RangeSet) std.mem.Allocator.Error!void {
        self.normalize();
        other.normalize();
        var points = std.ArrayList(u21).empty;
        defer points.deinit(self.allocator);
        try points.ensureTotalCapacity(self.allocator, self.ranges.items.len * 2 + other.ranges.items.len * 2);
        for (self.ranges.items) |range| {
            try points.append(self.allocator, range.lo);
            try points.append(self.allocator, range.hi);
        }
        for (other.ranges.items) |range| {
            try points.append(self.allocator, range.lo);
            try points.append(self.allocator, range.hi);
        }
        std.mem.sort(u21, points.items, {}, u21LessThan);

        var out = std.ArrayList(CodePointRange).empty;
        errdefer out.deinit(self.allocator);
        var in_a = false;
        var in_b = false;
        var index: usize = 0;
        var last: u21 = 0;
        while (index < points.items.len) {
            const point = points.items[index];
            if (point > last and (in_a != in_b)) {
                try out.append(self.allocator, .{ .lo = last, .hi = point });
            }
            while (index < points.items.len and points.items[index] == point) : (index += 1) {
                if (pointBelongsToBoundary(self.ranges.items, point)) in_a = !in_a;
                if (pointBelongsToBoundary(other.ranges.items, point)) in_b = !in_b;
            }
            last = point;
        }
        self.ranges.deinit(self.allocator);
        self.ranges = out;
    }

    fn invert(self: *RangeSet) std.mem.Allocator.Error!void {
        self.normalize();
        var out = std.ArrayList(CodePointRange).empty;
        errdefer out.deinit(self.allocator);
        var cursor: u21 = 0;
        for (self.ranges.items) |range| {
            if (cursor < range.lo) try out.append(self.allocator, .{ .lo = cursor, .hi = range.lo });
            if (cursor < range.hi) cursor = range.hi;
        }
        if (cursor < unicode_limit) try out.append(self.allocator, .{ .lo = cursor, .hi = unicode_limit });
        self.ranges.deinit(self.allocator);
        self.ranges = out;
    }

    fn toOwnedSlice(self: *RangeSet) std.mem.Allocator.Error![]CodePointRange {
        self.normalize();
        return try self.ranges.toOwnedSlice(self.allocator);
    }
};

fn rangeLessThan(_: void, lhs: CodePointRange, rhs: CodePointRange) bool {
    return lhs.lo < rhs.lo or (lhs.lo == rhs.lo and lhs.hi < rhs.hi);
}

fn u21LessThan(_: void, lhs: u21, rhs: u21) bool {
    return lhs < rhs;
}

fn pointBelongsToBoundary(ranges: []const CodePointRange, point: u21) bool {
    for (ranges) |range| {
        if (range.lo == point or range.hi == point) return true;
    }
    return false;
}

fn findName(name_table: []const u8, name: []const u8) ?usize {
    var p: usize = 0;
    var pos: usize = 0;
    while (p < name_table.len and name_table[p] != 0) : (pos += 1) {
        while (p < name_table.len) {
            const start = p;
            while (p < name_table.len and name_table[p] != 0 and name_table[p] != ',') : (p += 1) {}
            if (std.mem.eql(u8, name_table[start..p], name)) return pos;
            if (p >= name_table.len or name_table[p] == 0) break;
            p += 1;
        }
        while (p < name_table.len and name_table[p] != 0) : (p += 1) {}
        if (p < name_table.len) p += 1;
    }
    return null;
}

fn gcMask(comptime name: []const u8) u32 {
    return @as(u32, 1) << @intCast(@field(data.GC, name));
}

fn generalCategory(allocator: std.mem.Allocator, name: []const u8) UnicodeError!RangeSet {
    const gc_idx = findName(data.unicode_gc_name_table[0..], name) orelse return error.InvalidProperty;
    const gc_mask_table = [_]u32{
        gcMask("Lu") | gcMask("Ll") | gcMask("Lt"),
        gcMask("Lu") | gcMask("Ll") | gcMask("Lt") | gcMask("Lm") | gcMask("Lo"),
        gcMask("Mn") | gcMask("Mc") | gcMask("Me"),
        gcMask("Nd") | gcMask("Nl") | gcMask("No"),
        gcMask("Sm") | gcMask("Sc") | gcMask("Sk") | gcMask("So"),
        gcMask("Pc") | gcMask("Pd") | gcMask("Ps") | gcMask("Pe") | gcMask("Pi") | gcMask("Pf") | gcMask("Po"),
        gcMask("Zs") | gcMask("Zl") | gcMask("Zp"),
        gcMask("Cc") | gcMask("Cf") | gcMask("Cs") | gcMask("Co") | gcMask("Cn"),
    };
    const mask = if (gc_idx <= data.GC.Co)
        @as(u32, 1) << @intCast(gc_idx)
    else
        gc_mask_table[gc_idx - data.GC.LC];
    return try generalCategoryMask(allocator, mask);
}

fn generalCategoryMask(allocator: std.mem.Allocator, gc_mask: u32) std.mem.Allocator.Error!RangeSet {
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
            const upper_lower = gc_mask & (gcMask("Lu") | gcMask("Ll"));
            if (upper_lower != 0) {
                if (upper_lower == (gcMask("Lu") | gcMask("Ll"))) {
                    try cr.addInterval(c0, c);
                } else {
                    if ((gc_mask & gcMask("Ll")) != 0) c0 += 1;
                    while (c0 < c) : (c0 += 2) try cr.addInterval(c0, c0 + 1);
                }
            }
        } else if (((gc_mask >> @intCast(v)) & 1) != 0) {
            try cr.addInterval(c0, c);
        }
    }
    return cr;
}

fn propTableRanges(allocator: std.mem.Allocator, prop_idx: usize) UnicodeError!RangeSet {
    if (prop_idx >= data.unicode_prop_table.len) return error.InvalidProperty;
    const table = data.unicode_prop_table[prop_idx];
    var cr = RangeSet.init(allocator);
    errdefer cr.deinit();
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

const CASE_U = 1 << 0;
const CASE_L = 1 << 1;
const CASE_F = 1 << 2;

fn unicodeCaseRanges(allocator: std.mem.Allocator, case_mask: u32) std.mem.Allocator.Error!RangeSet {
    var cr = RangeSet.init(allocator);
    errdefer cr.deinit();
    if (case_mask == 0) return cr;

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
                if ((case_mask & CASE_U) != 0 and (case_mask & (CASE_L | CASE_F)) != 0) {
                    try cr.addInterval(code, code + len);
                } else {
                    code += if ((case_mask & CASE_U) != 0) @as(u32, 1) else 0;
                    var i: u32 = 0;
                    while (i < len) : (i += 2) try cr.addInterval(code + i, code + i + 1);
                }
            },
            RUN_TYPE_LSU => {
                if ((case_mask & CASE_U) != 0 and (case_mask & (CASE_L | CASE_F)) != 0) {
                    try cr.addInterval(code, code + len);
                } else {
                    if ((case_mask & CASE_U) == 0) try cr.addInterval(code, code + 1);
                    try cr.addInterval(code + 1, code + 2);
                    if ((case_mask & CASE_U) != 0) try cr.addInterval(code + 2, code + 3);
                }
            },
            else => try cr.addInterval(code, code + len),
        }
    }
    return cr;
}

fn unicodeProperty(allocator: std.mem.Allocator, name: []const u8) UnicodeError!RangeSet {
    const found = findName(data.unicode_prop_name_table[0..], name) orelse return error.InvalidProperty;
    const prop_idx = found + data.Prop.ASCII_Hex_Digit;

    switch (prop_idx) {
        data.Prop.ASCII => {
            var cr = RangeSet.init(allocator);
            errdefer cr.deinit();
            try cr.addInterval(0x00, 0x80);
            return cr;
        },
        data.Prop.Any => {
            var cr = RangeSet.init(allocator);
            errdefer cr.deinit();
            try cr.addInterval(0, unicode_limit);
            return cr;
        },
        data.Prop.Assigned => {
            var cr = try generalCategoryMask(allocator, gcMask("Cn"));
            errdefer cr.deinit();
            try cr.invert();
            return cr;
        },
        data.Prop.Math => return try unionGcProp(allocator, gcMask("Sm"), data.Prop.Other_Math),
        data.Prop.Lowercase => return try unionGcProp(allocator, gcMask("Ll"), data.Prop.Other_Lowercase),
        data.Prop.Uppercase => return try unionGcProp(allocator, gcMask("Lu"), data.Prop.Other_Uppercase),
        data.Prop.Cased => {
            var cr = try generalCategoryMask(allocator, gcMask("Lu") | gcMask("Ll") | gcMask("Lt"));
            errdefer cr.deinit();
            var upper = try propTableRanges(allocator, data.Prop.Other_Uppercase);
            defer upper.deinit();
            try cr.unionWith(&upper);
            var lower = try propTableRanges(allocator, data.Prop.Other_Lowercase);
            defer lower.deinit();
            try cr.unionWith(&lower);
            return cr;
        },
        data.Prop.Alphabetic => {
            var cr = try generalCategoryMask(allocator, gcMask("Lu") | gcMask("Ll") | gcMask("Lt") | gcMask("Lm") | gcMask("Lo") | gcMask("Nl"));
            errdefer cr.deinit();
            var upper = try propTableRanges(allocator, data.Prop.Other_Uppercase);
            defer upper.deinit();
            try cr.unionWith(&upper);
            var lower = try propTableRanges(allocator, data.Prop.Other_Lowercase);
            defer lower.deinit();
            try cr.unionWith(&lower);
            var alpha = try propTableRanges(allocator, data.Prop.Other_Alphabetic);
            defer alpha.deinit();
            try cr.unionWith(&alpha);
            return cr;
        },
        data.Prop.Grapheme_Base => {
            var cr = try generalCategoryMask(allocator, gcMask("Cc") | gcMask("Cf") | gcMask("Cs") | gcMask("Co") | gcMask("Cn") | gcMask("Zl") | gcMask("Zp") | gcMask("Me") | gcMask("Mn"));
            errdefer cr.deinit();
            var other = try propTableRanges(allocator, data.Prop.Other_Grapheme_Extend);
            defer other.deinit();
            try cr.unionWith(&other);
            try cr.invert();
            return cr;
        },
        data.Prop.Grapheme_Extend => return try unionGcProp(allocator, gcMask("Me") | gcMask("Mn"), data.Prop.Other_Grapheme_Extend),
        data.Prop.XID_Start => return try xidProperty(allocator, true),
        data.Prop.XID_Continue => return try xidProperty(allocator, false),
        data.Prop.Changes_When_Uppercased => return try unicodeCaseRanges(allocator, CASE_U),
        data.Prop.Changes_When_Lowercased => return try unicodeCaseRanges(allocator, CASE_L),
        data.Prop.Changes_When_Casemapped => return try unicodeCaseRanges(allocator, CASE_U | CASE_L | CASE_F),
        data.Prop.Changes_When_Titlecased => return try xorCaseProp(allocator, CASE_U, data.Prop.Changes_When_Titlecased1),
        data.Prop.Changes_When_Casefolded => return try xorCaseProp(allocator, CASE_F, data.Prop.Changes_When_Casefolded1),
        data.Prop.Changes_When_NFKC_Casefolded => return try xorCaseProp(allocator, CASE_F, data.Prop.Changes_When_NFKC_Casefolded1),
        data.Prop.ID_Continue => {
            var cr = try propTableRanges(allocator, data.Prop.ID_Start);
            errdefer cr.deinit();
            var cont = try propTableRanges(allocator, data.Prop.ID_Continue1);
            defer cont.deinit();
            try cr.xorWith(&cont);
            return cr;
        },
        else => return try propTableRanges(allocator, prop_idx),
    }
}

fn unionGcProp(allocator: std.mem.Allocator, mask: u32, prop_idx: usize) UnicodeError!RangeSet {
    var cr = try generalCategoryMask(allocator, mask);
    errdefer cr.deinit();
    var prop = try propTableRanges(allocator, prop_idx);
    defer prop.deinit();
    try cr.unionWith(&prop);
    return cr;
}

fn xidProperty(allocator: std.mem.Allocator, start: bool) UnicodeError!RangeSet {
    const base_mask = if (start)
        gcMask("Lu") | gcMask("Ll") | gcMask("Lt") | gcMask("Lm") | gcMask("Lo") | gcMask("Nl")
    else
        gcMask("Lu") | gcMask("Ll") | gcMask("Lt") | gcMask("Lm") | gcMask("Lo") | gcMask("Nl") | gcMask("Mn") | gcMask("Mc") | gcMask("Nd") | gcMask("Pc");
    var allowed = try generalCategoryMask(allocator, base_mask);
    errdefer allowed.deinit();
    var other_start = try propTableRanges(allocator, data.Prop.Other_ID_Start);
    defer other_start.deinit();
    try allowed.unionWith(&other_start);
    if (!start) {
        var other_continue = try propTableRanges(allocator, data.Prop.Other_ID_Continue);
        defer other_continue.deinit();
        try allowed.unionWith(&other_continue);
    }

    var excluded = try propTableRanges(allocator, data.Prop.Pattern_Syntax);
    defer excluded.deinit();
    var pattern_ws = try propTableRanges(allocator, data.Prop.Pattern_White_Space);
    defer pattern_ws.deinit();
    try excluded.unionWith(&pattern_ws);
    var xid_extra = try propTableRanges(allocator, if (start) data.Prop.XID_Start1 else data.Prop.XID_Continue1);
    defer xid_extra.deinit();
    try excluded.unionWith(&xid_extra);
    try excluded.invert();
    try allowed.intersectWith(&excluded);
    return allowed;
}

fn xorCaseProp(allocator: std.mem.Allocator, case_mask: u32, prop_idx: usize) UnicodeError!RangeSet {
    var cr = try unicodeCaseRanges(allocator, case_mask);
    errdefer cr.deinit();
    var prop = try propTableRanges(allocator, prop_idx);
    defer prop.deinit();
    try cr.xorWith(&prop);
    return cr;
}

fn scriptRanges(allocator: std.mem.Allocator, script_name: []const u8, is_ext: bool) UnicodeError!RangeSet {
    const script_idx = scriptIndex(script_name) orelse return error.InvalidProperty;
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
        const v: u32 = if (typ == 0) 0 else blk: {
            const value = data.unicode_script_table[p];
            p += 1;
            break :blk value;
        };
        const c1 = c + n + 1;
        if (v == script_idx) try base.addInterval(c, c1);
        c = c1;
    }
    if (script_idx == data.Script.Unknown) try base.addInterval(c, unicode_limit);

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
                if (value == script_idx) {
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

fn scriptIndex(script_name: []const u8) ?u32 {
    if (std.mem.eql(u8, script_name, "Unknown") or std.mem.eql(u8, script_name, "Zzzz")) return data.Script.Unknown;
    const found = findName(data.unicode_script_name_table[0..], script_name) orelse return null;
    return @intCast(found + data.Script.Unknown + 1);
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

    const ascii_ranges = try propertyRangesAlloc(std.testing.allocator, "ASCII", false);
    defer std.testing.allocator.free(ascii_ranges);
    try std.testing.expect(rangesContain(ascii_ranges, 'A'));
    try std.testing.expect(!rangesContain(ascii_ranges, 0x80));
    const non_ascii_ranges = try propertyRangesAlloc(std.testing.allocator, "ASCII", true);
    defer std.testing.allocator.free(non_ascii_ranges);
    try std.testing.expect(!rangesContain(non_ascii_ranges, 'A'));
    try std.testing.expect(rangesContain(non_ascii_ranges, 0x80));
    try std.testing.expect(rangesContain(non_ascii_ranges, 0x10ffff));
    const greek_ranges = try propertyRangesAlloc(std.testing.allocator, "Script=Greek", false);
    defer std.testing.allocator.free(greek_ranges);
    try std.testing.expect(rangesContain(greek_ranges, 0x03c0));
    try std.testing.expect(!rangesContain(greek_ranges, 'A'));
    try std.testing.expect(!rangesContain(greek_ranges, 0x038b));

    const unknown_script_ranges = try propertyRangesAlloc(std.testing.allocator, "Script=Unknown", false);
    defer std.testing.allocator.free(unknown_script_ranges);
    try std.testing.expect(rangesContain(unknown_script_ranges, 0x038b));
    try std.testing.expect(rangesContain(unknown_script_ranges, 0x0e01f0));
    try std.testing.expect(rangesContain(unknown_script_ranges, 0x10ffff));
    try std.testing.expect(!rangesContain(unknown_script_ranges, 0x03c0));

    const unknown_script_ext_ranges = try propertyRangesAlloc(std.testing.allocator, "Script_Extensions=Unknown", false);
    defer std.testing.allocator.free(unknown_script_ext_ranges);
    try std.testing.expect(rangesContain(unknown_script_ext_ranges, 0x038b));
    try std.testing.expect(rangesContain(unknown_script_ext_ranges, 0x0e01f0));
    try std.testing.expect(rangesContain(unknown_script_ext_ranges, 0x10ffff));
    try std.testing.expect(!rangesContain(unknown_script_ext_ranges, 0x03c0));
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

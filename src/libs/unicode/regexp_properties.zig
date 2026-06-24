// RegExp Unicode property lookup.
const std = @import("std");
const data = @import("data.zig");
const names = @import("names.zig");
const max_code_point: u21 = 0x10ffff;

// --- Runtime Zero-Allocation Evaluators ---

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

const CASE_U = 1 << 0;
const CASE_L = 1 << 1;
const CASE_F = 1 << 2;

const lu_mask = names.gcBit("Lu");
const ll_mask = names.gcBit("Ll");
const lt_mask = names.gcBit("Lt");
const lm_mask = names.gcBit("Lm");
const lo_mask = names.gcBit("Lo");
const mn_mask = names.gcBit("Mn");
const mc_mask = names.gcBit("Mc");
const me_mask = names.gcBit("Me");
const nd_mask = names.gcBit("Nd");
const nl_mask = names.gcBit("Nl");
const sm_mask = names.gcBit("Sm");
const pc_mask = names.gcBit("Pc");
const zl_mask = names.gcBit("Zl");
const zp_mask = names.gcBit("Zp");
const cc_mask = names.gcBit("Cc");
const cf_mask = names.gcBit("Cf");
const cs_mask = names.gcBit("Cs");
const co_mask = names.gcBit("Co");
const cn_mask = names.gcBit("Cn");

const PropOp = union(enum) {
    gc: u32,
    prop: usize,
    case_mask: u32,
    op_union,
    op_inter,
    op_xor,
    op_invert,
};

fn unicodeGeneralCategory1(code_point: u21, gc_mask: u32) bool {
    var p: []const u8 = &data.unicode_gc_table;
    var c: u32 = 0;
    while (p.len > 0) {
        const b = p[0];
        p = p[1..];
        var n: u32 = b >> 5;
        const v: u32 = b & 0x1f;

        if (n == 7) {
            const next_b = p[0];
            p = p[1..];
            if (next_b < 128) {
                n = next_b + 7;
            } else if (next_b < 128 + 64) {
                n = @as(u32, next_b - 128) << 8;
                n |= p[0];
                p = p[1..];
                n += 7 + 128;
            } else {
                n = @as(u32, next_b - 128 - 64) << 16;
                n |= @as(u32, p[0]) << 8;
                n |= p[1];
                p = p[2..];
                n += 7 + 128 + (1 << 14);
            }
        }

        const c0 = c;
        c += n + 1;

        if (code_point >= c0 and code_point < c) {
            if (v == 31) {
                const upper_lower = gc_mask & (lu_mask | ll_mask);
                if (upper_lower != 0) {
                    if (upper_lower == (lu_mask | ll_mask)) {
                        return true;
                    } else {
                        var temp_c0 = c0;
                        if ((gc_mask & ll_mask) != 0) temp_c0 += 1;
                        if (code_point < temp_c0) return false;
                        return (code_point - temp_c0) % 2 == 0;
                    }
                }
            } else if (((gc_mask >> @intCast(v)) & 1) != 0) {
                return true;
            }
            break;
        }
    }
    return false;
}

fn unicodeProp1(code_point: u21, prop_idx: usize) bool {
    if (prop_idx >= data.unicode_prop_table.len) return false;
    const table = data.unicode_prop_table[prop_idx];
    var p: usize = 0;
    var c: u32 = 0;
    var bit = false;
    while (p < table.len) {
        var c0 = c;
        const b = table[p];
        p += 1;
        if (b < 64) {
            c += (b >> 3) + 1;
            if (bit and code_point >= c0 and code_point < c) return true;
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
        if (bit and code_point >= c0 and code_point < c) return true;
        bit = !bit;
    }
    return false;
}

fn unicodeCase1(code_point: u21, case_mask: u32) bool {
    if (case_mask == 0) return false;
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
        const code = v >> (32 - 17);
        const len = (v >> (32 - 17 - 7)) & 0x7f;
        if (((mask >> @intCast(typ)) & 1) == 0) continue;
        if (code_point >= code and code_point < code + len) {
            switch (typ) {
                RUN_TYPE_UL => {
                    if ((case_mask & CASE_U) != 0 and (case_mask & (CASE_L | CASE_F)) != 0) {
                        return true;
                    } else {
                        const offset = if ((case_mask & CASE_U) != 0) @as(u32, 1) else 0;
                        return ((code_point - code) % 2) == offset;
                    }
                },
                RUN_TYPE_LSU => {
                    if ((case_mask & CASE_U) != 0 and (case_mask & (CASE_L | CASE_F)) != 0) {
                        return true;
                    } else {
                        if ((case_mask & CASE_U) == 0) {
                            if (code_point == code or code_point == code + 1) return true;
                        } else {
                            if (code_point == code + 1 or code_point == code + 2) return true;
                        }
                        return false;
                    }
                },
                else => return true,
            }
        }
    }
    return false;
}

// Boolean equivalent of QuickJS unicode_prop_ops() for a single code point.
fn unicodePropOps(code_point: u21, comptime ops: []const PropOp) bool {
    var stack: [4]bool = undefined;
    var stack_len: usize = 0;

    inline for (ops) |op| {
        switch (op) {
            .gc => |mask| {
                stack[stack_len] = unicodeGeneralCategory1(code_point, mask);
                stack_len += 1;
            },
            .prop => |prop_idx| {
                stack[stack_len] = unicodeProp1(code_point, prop_idx);
                stack_len += 1;
            },
            .case_mask => |mask| {
                stack[stack_len] = unicodeCase1(code_point, mask);
                stack_len += 1;
            },
            .op_union => {
                stack[stack_len - 2] = stack[stack_len - 2] or stack[stack_len - 1];
                stack_len -= 1;
            },
            .op_inter => {
                stack[stack_len - 2] = stack[stack_len - 2] and stack[stack_len - 1];
                stack_len -= 1;
            },
            .op_xor => {
                stack[stack_len - 2] = stack[stack_len - 2] != stack[stack_len - 1];
                stack_len -= 1;
            },
            .op_invert => stack[stack_len - 1] = !stack[stack_len - 1],
        }
    }

    std.debug.assert(stack_len == 1);
    return stack[0];
}

fn unicodeProp(code_point: u21, prop_idx: usize) bool {
    switch (prop_idx) {
        data.Prop.ASCII => return code_point < 0x80,
        data.Prop.Any => return code_point < 0x110000,
        data.Prop.Assigned => return unicodePropOps(code_point, &.{
            .{ .gc = cn_mask },
            .op_invert,
        }),
        data.Prop.Math => return unicodePropOps(code_point, &.{
            .{ .gc = sm_mask },
            .{ .prop = data.Prop.Other_Math },
            .op_union,
        }),
        data.Prop.Lowercase => return unicodePropOps(code_point, &.{
            .{ .gc = ll_mask },
            .{ .prop = data.Prop.Other_Lowercase },
            .op_union,
        }),
        data.Prop.Uppercase => return unicodePropOps(code_point, &.{
            .{ .gc = lu_mask },
            .{ .prop = data.Prop.Other_Uppercase },
            .op_union,
        }),
        data.Prop.Cased => return unicodePropOps(code_point, &.{
            .{ .gc = lu_mask | ll_mask | lt_mask },
            .{ .prop = data.Prop.Other_Uppercase },
            .op_union,
            .{ .prop = data.Prop.Other_Lowercase },
            .op_union,
        }),
        data.Prop.Alphabetic => return unicodePropOps(code_point, &.{
            .{ .gc = lu_mask | ll_mask | lt_mask | lm_mask | lo_mask | nl_mask },
            .{ .prop = data.Prop.Other_Uppercase },
            .op_union,
            .{ .prop = data.Prop.Other_Lowercase },
            .op_union,
            .{ .prop = data.Prop.Other_Alphabetic },
            .op_union,
        }),
        data.Prop.Grapheme_Base => return unicodePropOps(code_point, &.{
            .{ .gc = cc_mask | cf_mask | cs_mask | co_mask | cn_mask | zl_mask | zp_mask | me_mask | mn_mask },
            .{ .prop = data.Prop.Other_Grapheme_Extend },
            .op_union,
            .op_invert,
        }),
        data.Prop.Grapheme_Extend => return unicodePropOps(code_point, &.{
            .{ .gc = me_mask | mn_mask },
            .{ .prop = data.Prop.Other_Grapheme_Extend },
            .op_union,
        }),
        data.Prop.ID_Continue => return unicodePropOps(code_point, &.{
            .{ .prop = data.Prop.ID_Start },
            .{ .prop = data.Prop.ID_Continue1 },
            .op_xor,
        }),
        data.Prop.XID_Start => return unicodePropOps(code_point, &.{
            .{ .gc = lu_mask | ll_mask | lt_mask | lm_mask | lo_mask | nl_mask },
            .{ .prop = data.Prop.Other_ID_Start },
            .op_union,
            .{ .prop = data.Prop.Pattern_Syntax },
            .{ .prop = data.Prop.Pattern_White_Space },
            .op_union,
            .{ .prop = data.Prop.XID_Start1 },
            .op_union,
            .op_invert,
            .op_inter,
        }),
        data.Prop.XID_Continue => return unicodePropOps(code_point, &.{
            .{ .gc = lu_mask | ll_mask | lt_mask | lm_mask | lo_mask | nl_mask | mn_mask | mc_mask | nd_mask | pc_mask },
            .{ .prop = data.Prop.Other_ID_Start },
            .op_union,
            .{ .prop = data.Prop.Other_ID_Continue },
            .op_union,
            .{ .prop = data.Prop.Pattern_Syntax },
            .{ .prop = data.Prop.Pattern_White_Space },
            .op_union,
            .{ .prop = data.Prop.XID_Continue1 },
            .op_union,
            .op_invert,
            .op_inter,
        }),
        data.Prop.Changes_When_Titlecased => return unicodePropOps(code_point, &.{
            .{ .case_mask = CASE_U },
            .{ .prop = data.Prop.Changes_When_Titlecased1 },
            .op_xor,
        }),
        data.Prop.Changes_When_Casefolded => return unicodePropOps(code_point, &.{
            .{ .case_mask = CASE_F },
            .{ .prop = data.Prop.Changes_When_Casefolded1 },
            .op_xor,
        }),
        data.Prop.Changes_When_NFKC_Casefolded => return unicodePropOps(code_point, &.{
            .{ .case_mask = CASE_F },
            .{ .prop = data.Prop.Changes_When_NFKC_Casefolded1 },
            .op_xor,
        }),
        data.Prop.Changes_When_Uppercased => return unicodeCase1(code_point, CASE_U),
        data.Prop.Changes_When_Lowercased => return unicodeCase1(code_point, CASE_L),
        data.Prop.Changes_When_Casemapped => return unicodeCase1(code_point, CASE_U | CASE_L | CASE_F),
        else => return unicodeProp1(code_point, prop_idx),
    }
}

fn unicode_script(code_point: u21, script_idx: u32, is_ext: bool) bool {
    const is_common = script_idx == data.Script.Common or script_idx == data.Script.Inherited;
    var p: []const u8 = &data.unicode_script_table;
    var c: u32 = 0;
    var primary_match = false;
    var found_range = false;
    while (p.len > 0) {
        const b = p[0];
        p = p[1..];
        const type_bit = b >> 7;
        var n: u32 = b & 0x7f;
        if (n < 96) {
            // no-op
        } else if (n < 112) {
            n = (n - 96) << 8;
            n |= p[0];
            p = p[1..];
            n += 96;
        } else {
            n = (n - 112) << 16;
            n |= @as(u32, p[0]) << 8;
            n |= p[1];
            p = p[2..];
            n += 96 + (1 << 12);
        }

        var v: u32 = 0;
        if (type_bit != 0) {
            v = p[0];
            p = p[1..];
        }

        const c1 = c + n + 1;
        if (code_point >= c and code_point < c1) {
            found_range = true;
            if (v == script_idx) {
                primary_match = true;
            }
            break;
        }
        c = c1;
    }
    if (!found_range and code_point >= c and code_point <= max_code_point and script_idx == data.Script.Unknown) {
        primary_match = true;
    }

    if (!is_ext) {
        return primary_match;
    }

    var p_ext: []const u8 = &data.unicode_script_ext_table;
    c = 0;
    var ext_match = false;
    var ext_has_any = false;
    while (p_ext.len > 0) {
        const b = p_ext[0];
        p_ext = p_ext[1..];
        var n: u32 = 0;
        if (b < 128) {
            n = b;
        } else if (b < 128 + 64) {
            n = @as(u32, b - 128) << 8;
            n |= p_ext[0];
            p_ext = p_ext[1..];
            n += 128;
        } else {
            n = @as(u32, b - 128 - 64) << 16;
            n |= @as(u32, p_ext[0]) << 8;
            n |= p_ext[1];
            p_ext = p_ext[2..];
            n += 128 + (1 << 14);
        }

        const c1 = c + n + 1;
        const v_len = p_ext[0];
        p_ext = p_ext[1..];

        if (code_point >= c and code_point < c1) {
            if (is_common) {
                if (v_len != 0) {
                    ext_has_any = true;
                }
            } else {
                for (p_ext[0..v_len]) |val| {
                    if (val == script_idx) {
                        ext_match = true;
                        break;
                    }
                }
            }
            break;
        }

        p_ext = p_ext[v_len..];
        c = c1;
    }

    if (is_common) {
        return primary_match and !ext_has_any;
    } else {
        return primary_match or ext_match;
    }
}

// --- Public Interface ---

pub fn isSupportedUnicodePropertyExpression(name: []const u8) bool {
    return names.parsePropertyExpression(name) != null;
}

pub fn isUnicodePropertyMatches(code_point: u21, name: []const u8) bool {
    return switch (names.parsePropertyExpression(name) orelse return false) {
        .script => |script| unicode_script(code_point, script.idx, script.is_ext),
        .gc_mask => |mask| unicodeGeneralCategory1(code_point, mask),
        .prop_idx => |prop_idx| unicodeProp(code_point, prop_idx),
    };
}

test "regexp unicode script properties include Unknown sentinel" {
    try std.testing.expect(isUnicodePropertyMatches(0x038b, "Script=Unknown"));
    try std.testing.expect(isUnicodePropertyMatches(0x038b, "Script=Zzzz"));
    try std.testing.expect(isUnicodePropertyMatches(0x038b, "sc=Unknown"));
    try std.testing.expect(isUnicodePropertyMatches(0x038b, "sc=Zzzz"));
    try std.testing.expect(isUnicodePropertyMatches(0x038b, "Script_Extensions=Unknown"));
    try std.testing.expect(isUnicodePropertyMatches(0x038b, "Script_Extensions=Zzzz"));
    try std.testing.expect(isUnicodePropertyMatches(0x038b, "scx=Unknown"));
    try std.testing.expect(isUnicodePropertyMatches(0x038b, "scx=Zzzz"));
    try std.testing.expect(isUnicodePropertyMatches(0x0e01f0, "Script=Unknown"));
    try std.testing.expect(isUnicodePropertyMatches(0x10ffff, "Script=Unknown"));
    try std.testing.expect(isUnicodePropertyMatches(0x0e01f0, "Script_Extensions=Unknown"));
    try std.testing.expect(isUnicodePropertyMatches(0x10ffff, "Script_Extensions=Unknown"));

    try std.testing.expect(!isUnicodePropertyMatches(0x03c0, "Script=Unknown"));
    try std.testing.expect(!isUnicodePropertyMatches(0x03c0, "Script_Extensions=Unknown"));
    try std.testing.expect(isUnicodePropertyMatches(0x03c0, "Script=Greek"));
    try std.testing.expect(isUnicodePropertyMatches(0x03c0, "Script_Extensions=Greek"));
}

test "regexp unicode script extensions exclude explicit Inherited extensions" {
    try std.testing.expect(isUnicodePropertyMatches(0x0300, "Script=Inherited"));
    try std.testing.expect(!isUnicodePropertyMatches(0x0300, "Script_Extensions=Inherited"));
}

test "regexp unicode ID properties use generated QuickJS tables" {
    try std.testing.expect(isUnicodePropertyMatches('A', "ID_Start"));
    try std.testing.expect(isUnicodePropertyMatches('_', "ID_Continue"));
    try std.testing.expect(!isUnicodePropertyMatches(0x2e2f, "ID_Start"));
    try std.testing.expect(!isUnicodePropertyMatches(0x2e2f, "ID_Continue"));
}

test "regexp unicode property parser rejects bare script values" {
    try std.testing.expect(!isSupportedUnicodePropertyExpression("Greek"));
    try std.testing.expect(!isSupportedUnicodePropertyExpression("Grek"));
    try std.testing.expect(!isUnicodePropertyMatches(0x03c0, "Greek"));
    try std.testing.expect(!isUnicodePropertyMatches(0x03c0, "Grek"));
    try std.testing.expect(isUnicodePropertyMatches(0x03c0, "Script=Greek"));
}

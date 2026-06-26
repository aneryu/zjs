const data = @import("data.zig");
const names = @import("names.zig");

pub const CASE_U = 1 << 0;
pub const CASE_L = 1 << 1;
pub const CASE_F = 1 << 2;

pub const Op = union(enum) {
    gc: u32,
    prop: data.Prop,
    case_mask: u32,
    op_union,
    op_inter,
    op_xor,
    op_invert,
};

pub const Derived = union(enum) {
    ascii,
    any,
    ops: []const Op,
};

const assigned_ops = [_]Op{
    .{ .gc = names.gcBit("Cn") },
    .op_invert,
};

const math_ops = [_]Op{
    .{ .gc = names.gcBit("Sm") },
    .{ .prop = data.Prop.Other_Math },
    .op_union,
};

const lowercase_ops = [_]Op{
    .{ .gc = names.gcBit("Ll") },
    .{ .prop = data.Prop.Other_Lowercase },
    .op_union,
};

const uppercase_ops = [_]Op{
    .{ .gc = names.gcBit("Lu") },
    .{ .prop = data.Prop.Other_Uppercase },
    .op_union,
};

const cased_ops = [_]Op{
    .{ .gc = names.gcBit("Lu") | names.gcBit("Ll") | names.gcBit("Lt") },
    .{ .prop = data.Prop.Other_Uppercase },
    .op_union,
    .{ .prop = data.Prop.Other_Lowercase },
    .op_union,
};

const alphabetic_ops = [_]Op{
    .{ .gc = names.gcBit("Lu") | names.gcBit("Ll") | names.gcBit("Lt") | names.gcBit("Lm") | names.gcBit("Lo") | names.gcBit("Nl") },
    .{ .prop = data.Prop.Other_Uppercase },
    .op_union,
    .{ .prop = data.Prop.Other_Lowercase },
    .op_union,
    .{ .prop = data.Prop.Other_Alphabetic },
    .op_union,
};

const grapheme_base_ops = [_]Op{
    .{ .gc = names.gcBit("Cc") | names.gcBit("Cf") | names.gcBit("Cs") | names.gcBit("Co") | names.gcBit("Cn") | names.gcBit("Zl") | names.gcBit("Zp") | names.gcBit("Me") | names.gcBit("Mn") },
    .{ .prop = data.Prop.Other_Grapheme_Extend },
    .op_union,
    .op_invert,
};

const grapheme_extend_ops = [_]Op{
    .{ .gc = names.gcBit("Me") | names.gcBit("Mn") },
    .{ .prop = data.Prop.Other_Grapheme_Extend },
    .op_union,
};

const xid_start_ops = [_]Op{
    .{ .gc = names.gcBit("Lu") | names.gcBit("Ll") | names.gcBit("Lt") | names.gcBit("Lm") | names.gcBit("Lo") | names.gcBit("Nl") },
    .{ .prop = data.Prop.Other_ID_Start },
    .op_union,
    .{ .prop = data.Prop.Pattern_Syntax },
    .{ .prop = data.Prop.Pattern_White_Space },
    .op_union,
    .{ .prop = data.Prop.XID_Start1 },
    .op_union,
    .op_invert,
    .op_inter,
};

const xid_continue_ops = [_]Op{
    .{ .gc = names.gcBit("Lu") | names.gcBit("Ll") | names.gcBit("Lt") | names.gcBit("Lm") | names.gcBit("Lo") | names.gcBit("Nl") | names.gcBit("Mn") | names.gcBit("Mc") | names.gcBit("Nd") | names.gcBit("Pc") },
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
};

const changes_when_uppercased_ops = [_]Op{
    .{ .case_mask = CASE_U },
};

const changes_when_lowercased_ops = [_]Op{
    .{ .case_mask = CASE_L },
};

const changes_when_casemapped_ops = [_]Op{
    .{ .case_mask = CASE_U | CASE_L | CASE_F },
};

const changes_when_titlecased_ops = [_]Op{
    .{ .case_mask = CASE_U },
    .{ .prop = data.Prop.Changes_When_Titlecased1 },
    .op_xor,
};

const changes_when_casefolded_ops = [_]Op{
    .{ .case_mask = CASE_F },
    .{ .prop = data.Prop.Changes_When_Casefolded1 },
    .op_xor,
};

const changes_when_nfkc_casefolded_ops = [_]Op{
    .{ .case_mask = CASE_F },
    .{ .prop = data.Prop.Changes_When_NFKC_Casefolded1 },
    .op_xor,
};

const id_continue_ops = [_]Op{
    .{ .prop = data.Prop.ID_Start },
    .{ .prop = data.Prop.ID_Continue1 },
    .op_xor,
};

pub fn derived(prop: data.Prop) ?Derived {
    return switch (prop) {
        .ASCII => .ascii,
        .Any => .any,
        .Assigned => .{ .ops = assigned_ops[0..] },
        .Math => .{ .ops = math_ops[0..] },
        .Lowercase => .{ .ops = lowercase_ops[0..] },
        .Uppercase => .{ .ops = uppercase_ops[0..] },
        .Cased => .{ .ops = cased_ops[0..] },
        .Alphabetic => .{ .ops = alphabetic_ops[0..] },
        .Grapheme_Base => .{ .ops = grapheme_base_ops[0..] },
        .Grapheme_Extend => .{ .ops = grapheme_extend_ops[0..] },
        .XID_Start => .{ .ops = xid_start_ops[0..] },
        .XID_Continue => .{ .ops = xid_continue_ops[0..] },
        .Changes_When_Uppercased => .{ .ops = changes_when_uppercased_ops[0..] },
        .Changes_When_Lowercased => .{ .ops = changes_when_lowercased_ops[0..] },
        .Changes_When_Casemapped => .{ .ops = changes_when_casemapped_ops[0..] },
        .Changes_When_Titlecased => .{ .ops = changes_when_titlecased_ops[0..] },
        .Changes_When_Casefolded => .{ .ops = changes_when_casefolded_ops[0..] },
        .Changes_When_NFKC_Casefolded => .{ .ops = changes_when_nfkc_casefolded_ops[0..] },
        .ID_Continue => .{ .ops = id_continue_ops[0..] },
        else => null,
    };
}

pub fn isSupported(prop: data.Prop) bool {
    return data.propTable(prop) != null or derived(prop) != null;
}

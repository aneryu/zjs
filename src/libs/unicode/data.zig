//! Immutable Unicode tables from QuickJS `libunicode-table.h`, stored as a
//! little-endian blob and sliced at comptime. Decoding stays in `unicode.zig`.
//!
//! `tables.bin` layout, all integers little-endian:
//! `ZJSU` magic, u32 version (1), u32 table count, then count ×
//! `{name_off, data_off, n_elem, elem_size}` (u32 each), then NUL-terminated
//! names, then payloads (each table 4-byte aligned). `u8` tables are views
//! into the blob; `u16`/`u32` tables are decoded to native ints.

const std = @import("std");

const blob = @embedFile("tables.bin");

fn blobU32(comptime offset: usize) u32 {
    return std.mem.readInt(u32, blob[offset..][0..4], .little);
}

fn tableBytes(comptime name: []const u8, comptime elem_size: u32) []const u8 {
    @setEvalBranchQuota(500000);
    comptime {
        if (blob.len < 12 or !std.mem.eql(u8, blob[0..4], "ZJSU")) {
            @compileError("unicode tables.bin magic mismatch");
        }
        if (blobU32(4) != 1) @compileError("unicode tables.bin version mismatch");
        const n_tables = blobU32(8);
        var i: usize = 0;
        while (i < n_tables) : (i += 1) {
            const base = 12 + i * 16;
            const name_off = blobU32(base);
            const data_off = blobU32(base + 4);
            const n_elem = blobU32(base + 8);
            const found_size = blobU32(base + 12);
            const found = std.mem.sliceTo(blob[name_off..], 0);
            if (!std.mem.eql(u8, found, name)) continue;
            if (found_size != elem_size) @compileError(name ++ " element size mismatch");
            return blob[data_off .. data_off + n_elem * elem_size];
        }
        @compileError("missing unicode table: " ++ name);
    }
}

fn tableInts(comptime T: type, comptime name: []const u8) []const T {
    const bytes = tableBytes(name, @sizeOf(T));
    const n_elem = bytes.len / @sizeOf(T);
    var tmp: [n_elem]T = undefined;
    for (0..n_elem) |j| {
        tmp[j] = std.mem.readInt(T, bytes[j * @sizeOf(T) ..][0..@sizeOf(T)], .little);
    }
    const frozen = tmp;
    return &frozen;
}

pub const case_conv_table1 = tableInts(u32, "case_conv_table1");
pub const case_conv_table2 = tableBytes("case_conv_table2", 1);
pub const case_conv_ext = tableInts(u16, "case_conv_ext");
pub const unicode_prop_Cased1_table = tableBytes("unicode_prop_Cased1_table", 1);
pub const unicode_prop_Cased1_index = tableBytes("unicode_prop_Cased1_index", 1);
pub const unicode_prop_Case_Ignorable_table = tableBytes("unicode_prop_Case_Ignorable_table", 1);
pub const unicode_prop_Case_Ignorable_index = tableBytes("unicode_prop_Case_Ignorable_index", 1);
pub const unicode_prop_ID_Start_table = tableBytes("unicode_prop_ID_Start_table", 1);
pub const unicode_prop_ID_Start_index = tableBytes("unicode_prop_ID_Start_index", 1);
pub const unicode_prop_ID_Continue1_table = tableBytes("unicode_prop_ID_Continue1_table", 1);
pub const unicode_prop_ID_Continue1_index = tableBytes("unicode_prop_ID_Continue1_index", 1);
pub const unicode_cc_table = tableBytes("unicode_cc_table", 1);
pub const unicode_cc_index = tableBytes("unicode_cc_index", 1);
pub const unicode_decomp_table1 = tableInts(u32, "unicode_decomp_table1");
pub const unicode_decomp_table2 = tableInts(u16, "unicode_decomp_table2");
pub const unicode_decomp_data = tableBytes("unicode_decomp_data", 1);
pub const unicode_comp_table = tableInts(u16, "unicode_comp_table");
pub const unicode_gc_table = tableBytes("unicode_gc_table", 1);
pub const unicode_script_table = tableBytes("unicode_script_table", 1);
pub const unicode_script_ext_table = tableBytes("unicode_script_ext_table", 1);
pub const unicode_prop_Hyphen_table = tableBytes("unicode_prop_Hyphen_table", 1);
pub const unicode_prop_Other_Math_table = tableBytes("unicode_prop_Other_Math_table", 1);
pub const unicode_prop_Other_Alphabetic_table = tableBytes("unicode_prop_Other_Alphabetic_table", 1);
pub const unicode_prop_Other_Lowercase_table = tableBytes("unicode_prop_Other_Lowercase_table", 1);
pub const unicode_prop_Other_Uppercase_table = tableBytes("unicode_prop_Other_Uppercase_table", 1);
pub const unicode_prop_Other_Grapheme_Extend_table = tableBytes("unicode_prop_Other_Grapheme_Extend_table", 1);
pub const unicode_prop_Other_Default_Ignorable_Code_Point_table = tableBytes("unicode_prop_Other_Default_Ignorable_Code_Point_table", 1);
pub const unicode_prop_Other_ID_Start_table = tableBytes("unicode_prop_Other_ID_Start_table", 1);
pub const unicode_prop_Other_ID_Continue_table = tableBytes("unicode_prop_Other_ID_Continue_table", 1);
pub const unicode_prop_Prepended_Concatenation_Mark_table = tableBytes("unicode_prop_Prepended_Concatenation_Mark_table", 1);
pub const unicode_prop_XID_Start1_table = tableBytes("unicode_prop_XID_Start1_table", 1);
pub const unicode_prop_XID_Continue1_table = tableBytes("unicode_prop_XID_Continue1_table", 1);
pub const unicode_prop_Changes_When_Titlecased1_table = tableBytes("unicode_prop_Changes_When_Titlecased1_table", 1);
pub const unicode_prop_Changes_When_Casefolded1_table = tableBytes("unicode_prop_Changes_When_Casefolded1_table", 1);
pub const unicode_prop_Changes_When_NFKC_Casefolded1_table = tableBytes("unicode_prop_Changes_When_NFKC_Casefolded1_table", 1);
pub const unicode_prop_Basic_Emoji1_table = tableBytes("unicode_prop_Basic_Emoji1_table", 1);
pub const unicode_prop_Basic_Emoji2_table = tableBytes("unicode_prop_Basic_Emoji2_table", 1);
pub const unicode_prop_RGI_Emoji_Modifier_Sequence_table = tableBytes("unicode_prop_RGI_Emoji_Modifier_Sequence_table", 1);
pub const unicode_prop_RGI_Emoji_Flag_Sequence_table = tableBytes("unicode_prop_RGI_Emoji_Flag_Sequence_table", 1);
pub const unicode_prop_Emoji_Keycap_Sequence_table = tableBytes("unicode_prop_Emoji_Keycap_Sequence_table", 1);
pub const unicode_prop_ASCII_Hex_Digit_table = tableBytes("unicode_prop_ASCII_Hex_Digit_table", 1);
pub const unicode_prop_Bidi_Control_table = tableBytes("unicode_prop_Bidi_Control_table", 1);
pub const unicode_prop_Dash_table = tableBytes("unicode_prop_Dash_table", 1);
pub const unicode_prop_Deprecated_table = tableBytes("unicode_prop_Deprecated_table", 1);
pub const unicode_prop_Diacritic_table = tableBytes("unicode_prop_Diacritic_table", 1);
pub const unicode_prop_Extender_table = tableBytes("unicode_prop_Extender_table", 1);
pub const unicode_prop_Hex_Digit_table = tableBytes("unicode_prop_Hex_Digit_table", 1);
pub const unicode_prop_IDS_Unary_Operator_table = tableBytes("unicode_prop_IDS_Unary_Operator_table", 1);
pub const unicode_prop_IDS_Binary_Operator_table = tableBytes("unicode_prop_IDS_Binary_Operator_table", 1);
pub const unicode_prop_IDS_Trinary_Operator_table = tableBytes("unicode_prop_IDS_Trinary_Operator_table", 1);
pub const unicode_prop_Ideographic_table = tableBytes("unicode_prop_Ideographic_table", 1);
pub const unicode_prop_Join_Control_table = tableBytes("unicode_prop_Join_Control_table", 1);
pub const unicode_prop_Logical_Order_Exception_table = tableBytes("unicode_prop_Logical_Order_Exception_table", 1);
pub const unicode_prop_Modifier_Combining_Mark_table = tableBytes("unicode_prop_Modifier_Combining_Mark_table", 1);
pub const unicode_prop_Noncharacter_Code_Point_table = tableBytes("unicode_prop_Noncharacter_Code_Point_table", 1);
pub const unicode_prop_Pattern_Syntax_table = tableBytes("unicode_prop_Pattern_Syntax_table", 1);
pub const unicode_prop_Pattern_White_Space_table = tableBytes("unicode_prop_Pattern_White_Space_table", 1);
pub const unicode_prop_Quotation_Mark_table = tableBytes("unicode_prop_Quotation_Mark_table", 1);
pub const unicode_prop_Radical_table = tableBytes("unicode_prop_Radical_table", 1);
pub const unicode_prop_Regional_Indicator_table = tableBytes("unicode_prop_Regional_Indicator_table", 1);
pub const unicode_prop_Sentence_Terminal_table = tableBytes("unicode_prop_Sentence_Terminal_table", 1);
pub const unicode_prop_Soft_Dotted_table = tableBytes("unicode_prop_Soft_Dotted_table", 1);
pub const unicode_prop_Terminal_Punctuation_table = tableBytes("unicode_prop_Terminal_Punctuation_table", 1);
pub const unicode_prop_Unified_Ideograph_table = tableBytes("unicode_prop_Unified_Ideograph_table", 1);
pub const unicode_prop_Variation_Selector_table = tableBytes("unicode_prop_Variation_Selector_table", 1);
pub const unicode_prop_White_Space_table = tableBytes("unicode_prop_White_Space_table", 1);
pub const unicode_prop_Bidi_Mirrored_table = tableBytes("unicode_prop_Bidi_Mirrored_table", 1);
pub const unicode_prop_Emoji_table = tableBytes("unicode_prop_Emoji_table", 1);
pub const unicode_prop_Emoji_Component_table = tableBytes("unicode_prop_Emoji_Component_table", 1);
pub const unicode_prop_Emoji_Modifier_table = tableBytes("unicode_prop_Emoji_Modifier_table", 1);
pub const unicode_prop_Emoji_Modifier_Base_table = tableBytes("unicode_prop_Emoji_Modifier_Base_table", 1);
pub const unicode_prop_Emoji_Presentation_table = tableBytes("unicode_prop_Emoji_Presentation_table", 1);
pub const unicode_prop_Extended_Pictographic_table = tableBytes("unicode_prop_Extended_Pictographic_table", 1);
pub const unicode_prop_Default_Ignorable_Code_Point_table = tableBytes("unicode_prop_Default_Ignorable_Code_Point_table", 1);
pub const unicode_rgi_emoji_tag_sequence = tableBytes("unicode_rgi_emoji_tag_sequence", 1);
pub const unicode_rgi_emoji_zwj_sequence = tableBytes("unicode_rgi_emoji_zwj_sequence", 1);
pub const unicode_gc_name_table = tableBytes("unicode_gc_name_table", 1);
pub const unicode_script_name_table = tableBytes("unicode_script_name_table", 1);
pub const unicode_prop_name_table = tableBytes("unicode_prop_name_table", 1);
pub const unicode_sequence_prop_name_table = tableBytes("unicode_sequence_prop_name_table", 1);

pub const GC = enum(u8) {
    Cn,
    Lu,
    Ll,
    Lt,
    Lm,
    Lo,
    Mn,
    Mc,
    Me,
    Nd,
    Nl,
    No,
    Sm,
    Sc,
    Sk,
    So,
    Pc,
    Pd,
    Ps,
    Pe,
    Pi,
    Pf,
    Po,
    Zs,
    Zl,
    Zp,
    Cc,
    Cf,
    Cs,
    Co,
    LC,
    L,
    M,
    N,
    S,
    P,
    Z,
    C,

    pub fn count() usize {
        return @typeInfo(@This()).@"enum".fields.len;
    }
};

pub const Script = enum(u16) {
    Unknown,
    Adlam,
    Ahom,
    Anatolian_Hieroglyphs,
    Arabic,
    Armenian,
    Avestan,
    Balinese,
    Bamum,
    Bassa_Vah,
    Batak,
    Beria_Erfe,
    Bengali,
    Bhaiksuki,
    Bopomofo,
    Brahmi,
    Braille,
    Buginese,
    Buhid,
    Canadian_Aboriginal,
    Carian,
    Caucasian_Albanian,
    Chakma,
    Cham,
    Cherokee,
    Chorasmian,
    Common,
    Coptic,
    Cuneiform,
    Cypriot,
    Cyrillic,
    Cypro_Minoan,
    Deseret,
    Devanagari,
    Dives_Akuru,
    Dogra,
    Duployan,
    Egyptian_Hieroglyphs,
    Elbasan,
    Elymaic,
    Ethiopic,
    Garay,
    Georgian,
    Glagolitic,
    Gothic,
    Grantha,
    Greek,
    Gujarati,
    Gunjala_Gondi,
    Gurmukhi,
    Gurung_Khema,
    Han,
    Hangul,
    Hanifi_Rohingya,
    Hanunoo,
    Hatran,
    Hebrew,
    Hiragana,
    Imperial_Aramaic,
    Inherited,
    Inscriptional_Pahlavi,
    Inscriptional_Parthian,
    Javanese,
    Kaithi,
    Kannada,
    Katakana,
    Katakana_Or_Hiragana,
    Kawi,
    Kayah_Li,
    Kharoshthi,
    Khmer,
    Khojki,
    Khitan_Small_Script,
    Khudawadi,
    Kirat_Rai,
    Lao,
    Latin,
    Lepcha,
    Limbu,
    Linear_A,
    Linear_B,
    Lisu,
    Lycian,
    Lydian,
    Makasar,
    Mahajani,
    Malayalam,
    Mandaic,
    Manichaean,
    Marchen,
    Masaram_Gondi,
    Medefaidrin,
    Meetei_Mayek,
    Mende_Kikakui,
    Meroitic_Cursive,
    Meroitic_Hieroglyphs,
    Miao,
    Modi,
    Mongolian,
    Mro,
    Multani,
    Myanmar,
    Nabataean,
    Nag_Mundari,
    Nandinagari,
    New_Tai_Lue,
    Newa,
    Nko,
    Nushu,
    Nyiakeng_Puachue_Hmong,
    Ogham,
    Ol_Chiki,
    Ol_Onal,
    Old_Hungarian,
    Old_Italic,
    Old_North_Arabian,
    Old_Permic,
    Old_Persian,
    Old_Sogdian,
    Old_South_Arabian,
    Old_Turkic,
    Old_Uyghur,
    Oriya,
    Osage,
    Osmanya,
    Pahawh_Hmong,
    Palmyrene,
    Pau_Cin_Hau,
    Phags_Pa,
    Phoenician,
    Psalter_Pahlavi,
    Rejang,
    Runic,
    Samaritan,
    Saurashtra,
    Sharada,
    Shavian,
    Siddham,
    Sidetic,
    SignWriting,
    Sinhala,
    Sogdian,
    Sora_Sompeng,
    Soyombo,
    Sundanese,
    Sunuwar,
    Syloti_Nagri,
    Syriac,
    Tagalog,
    Tagbanwa,
    Tai_Le,
    Tai_Tham,
    Tai_Viet,
    Tai_Yo,
    Takri,
    Tamil,
    Tangut,
    Telugu,
    Thaana,
    Thai,
    Tibetan,
    Tifinagh,
    Tirhuta,
    Tangsa,
    Todhri,
    Tolong_Siki,
    Toto,
    Tulu_Tigalari,
    Ugaritic,
    Vai,
    Vithkuqi,
    Wancho,
    Warang_Citi,
    Yezidi,
    Yi,
    Zanabazar_Square,

    pub fn count() usize {
        return @typeInfo(@This()).@"enum".fields.len;
    }
};

pub const Prop = enum(u8) {
    Hyphen,
    Other_Math,
    Other_Alphabetic,
    Other_Lowercase,
    Other_Uppercase,
    Other_Grapheme_Extend,
    Other_Default_Ignorable_Code_Point,
    Other_ID_Start,
    Other_ID_Continue,
    Prepended_Concatenation_Mark,
    ID_Continue1,
    XID_Start1,
    XID_Continue1,
    Changes_When_Titlecased1,
    Changes_When_Casefolded1,
    Changes_When_NFKC_Casefolded1,
    Basic_Emoji1,
    Basic_Emoji2,
    RGI_Emoji_Modifier_Sequence,
    RGI_Emoji_Flag_Sequence,
    Emoji_Keycap_Sequence,
    ASCII_Hex_Digit,
    Bidi_Control,
    Dash,
    Deprecated,
    Diacritic,
    Extender,
    Hex_Digit,
    IDS_Unary_Operator,
    IDS_Binary_Operator,
    IDS_Trinary_Operator,
    Ideographic,
    Join_Control,
    Logical_Order_Exception,
    Modifier_Combining_Mark,
    Noncharacter_Code_Point,
    Pattern_Syntax,
    Pattern_White_Space,
    Quotation_Mark,
    Radical,
    Regional_Indicator,
    Sentence_Terminal,
    Soft_Dotted,
    Terminal_Punctuation,
    Unified_Ideograph,
    Variation_Selector,
    White_Space,
    Bidi_Mirrored,
    Emoji,
    Emoji_Component,
    Emoji_Modifier,
    Emoji_Modifier_Base,
    Emoji_Presentation,
    Extended_Pictographic,
    Default_Ignorable_Code_Point,
    ID_Start,
    Case_Ignorable,
    ASCII,
    Alphabetic,
    Any,
    Assigned,
    Cased,
    Changes_When_Casefolded,
    Changes_When_Casemapped,
    Changes_When_Lowercased,
    Changes_When_NFKC_Casefolded,
    Changes_When_Titlecased,
    Changes_When_Uppercased,
    Grapheme_Base,
    Grapheme_Extend,
    ID_Continue,
    ID_Compat_Math_Start,
    ID_Compat_Math_Continue,
    InCB,
    Lowercase,
    Math,
    Uppercase,
    XID_Continue,
    XID_Start,
    Cased1,
};

pub const SequenceProp = enum(u8) {
    Basic_Emoji,
    Emoji_Keycap_Sequence,
    RGI_Emoji_Modifier_Sequence,
    RGI_Emoji_Flag_Sequence,
    RGI_Emoji_Tag_Sequence,
    RGI_Emoji_ZWJ_Sequence,
    RGI_Emoji,

    pub fn count() usize {
        return @typeInfo(@This()).@"enum".fields.len;
    }
};

pub const prop_table_backed_last = Prop.Case_Ignorable;
pub const prop_public_first = Prop.ASCII_Hex_Digit;
pub const prop_public_last = Prop.XID_Start;

pub const unicode_prop_table = blk: {
    const len = @intFromEnum(prop_table_backed_last) + 1;
    var tables: [len][]const u8 = undefined;
    for (@typeInfo(Prop).@"enum".fields[0..len], 0..) |field, i| {
        if (field.value != i) @compileError("Prop enum must be contiguous for unicode_prop_table");
        tables[i] = @field(@This(), "unicode_prop_" ++ field.name ++ "_table")[0..];
    }
    break :blk tables;
};

pub fn propTable(prop: Prop) ?[]const u8 {
    const idx = @intFromEnum(prop);
    if (idx >= unicode_prop_table.len) return null;
    return unicode_prop_table[idx];
}

test "embedded unicode tables keep QuickJS encodings" {
    try std.testing.expectEqual(@as(u32, 0x00209a30), case_conv_table1[0]);
    try std.testing.expectEqual(@as(u32, 0xf4912201), case_conv_table1[case_conv_table1.len - 1]);
    try std.testing.expectEqual(@as(usize, 378), case_conv_table1.len);
    try std.testing.expectEqual(@as(u8, 0x01), case_conv_table2[0]);
    try std.testing.expectEqual(@as(u16, 0x0399), case_conv_ext[0]);
    try std.testing.expectEqual(@as(u8, 0x40), unicode_prop_Cased1_table[0]);
    try std.testing.expectEqual(@as(u8, 0x43), unicode_gc_name_table[0]); // 'C' of Cn
    try std.testing.expect(propTable(.ID_Start) != null);
    try std.testing.expectEqual(@as(?[]const u8, null), propTable(.ASCII));
}

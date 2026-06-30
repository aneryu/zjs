pub const subsystem_name = "bytecode";

pub const opcode = struct {
    const std = @import("std");

    // QuickJS opcode metadata, inlined from the previous generated table.
    // Keep this table aligned with QuickJS quickjs-opcode.h / quickjs.c opcode_info.
    //
    // Layout mirrors QuickJS (`quickjs.c:1166` + `quickjs.c:21826`):
    //   - DEF entries get sequential ids 0..op_count-1.
    //   - def (temp) entries take ids op_temp_start..op_temp_end-1, which
    //     OVERLAP the short opcodes in the same range. Temp ops exist only
    //     in phase-1 streams (parser output, before resolve_labels); short
    //     ops only exist afterwards, so sharing the id space is sound.
    //   - `opcode_info` is filled in file order: temp entries sit exactly at
    //     their id, short entries are shifted op_temp_count slots past their
    //     id (QuickJS `short_opcode_info`). Do not index it with a raw id;
    //     use the view functions in opcode.zig (`sizeOf` for final-form
    //     bytecode, `sizeOfPhase1` for phase-1 streams, and friends).

    /// Operand format tags, from the FMT() list in quickjs-opcode.h.
    pub const Format = enum {
        none,
        none_int,
        none_loc,
        none_arg,
        none_var_ref,
        u8,
        i8,
        loc8,
        const8,
        label8,
        u16,
        i16,
        label16,
        npop,
        npopx,
        npop_u16,
        loc,
        arg,
        var_ref,
        u32,
        i32,
        @"const",
        label,
        atom,
        atom_u8,
        atom_u16,
        atom_label_u8,
        atom_label_u16,
        label_u16,
    };

    /// One row of opcode metadata (QuickJS `JSOpCode`).
    pub const Info = struct {
        name: []const u8,
        size: u8,
        n_pop: u8,
        n_push: u8,
        fmt: Format,
    };

    pub const op = struct {
        pub const invalid: u8 = 0;
        pub const push_i32: u8 = 1;
        pub const push_const: u8 = 2;
        pub const fclosure: u8 = 3;
        pub const push_atom_value: u8 = 4;
        pub const private_symbol: u8 = 5;
        pub const @"undefined": u8 = 6;
        pub const @"null": u8 = 7;
        pub const push_this: u8 = 8;
        pub const push_false: u8 = 9;
        pub const push_true: u8 = 10;
        pub const object: u8 = 11;
        pub const special_object: u8 = 12;
        pub const rest: u8 = 13;
        pub const drop: u8 = 14;
        pub const nip: u8 = 15;
        pub const nip1: u8 = 16;
        pub const dup: u8 = 17;
        pub const dup1: u8 = 18;
        pub const dup2: u8 = 19;
        pub const dup3: u8 = 20;
        pub const insert2: u8 = 21;
        pub const insert3: u8 = 22;
        pub const insert4: u8 = 23;
        pub const perm3: u8 = 24;
        pub const perm4: u8 = 25;
        pub const perm5: u8 = 26;
        pub const swap: u8 = 27;
        pub const swap2: u8 = 28;
        pub const rot3l: u8 = 29;
        pub const rot3r: u8 = 30;
        pub const rot4l: u8 = 31;
        pub const rot5l: u8 = 32;
        pub const call_constructor: u8 = 33;
        pub const call: u8 = 34;
        pub const tail_call: u8 = 35;
        pub const call_method: u8 = 36;
        pub const tail_call_method: u8 = 37;
        pub const array_from: u8 = 38;
        pub const apply: u8 = 39;
        pub const @"return": u8 = 40;
        pub const return_undef: u8 = 41;
        pub const check_ctor_return: u8 = 42;
        pub const check_ctor: u8 = 43;
        pub const init_ctor: u8 = 44;
        pub const check_brand: u8 = 45;
        pub const add_brand: u8 = 46;
        pub const return_async: u8 = 47;
        pub const throw: u8 = 48;
        pub const throw_error: u8 = 49;
        pub const eval: u8 = 50;
        pub const apply_eval: u8 = 51;
        pub const regexp: u8 = 52;
        pub const get_super: u8 = 53;
        pub const import: u8 = 54;
        pub const get_var_undef: u8 = 55;
        pub const get_var: u8 = 56;
        pub const put_var: u8 = 57;
        pub const put_var_init: u8 = 58;
        pub const get_ref_value: u8 = 59;
        pub const put_ref_value: u8 = 60;
        pub const get_field: u8 = 61;
        pub const get_field2: u8 = 62;
        pub const put_field: u8 = 63;
        pub const get_private_field: u8 = 64;
        pub const put_private_field: u8 = 65;
        pub const define_private_field: u8 = 66;
        pub const get_array_el: u8 = 67;
        pub const get_array_el2: u8 = 68;
        pub const get_array_el3: u8 = 69;
        pub const put_array_el: u8 = 70;
        pub const get_super_value: u8 = 71;
        pub const put_super_value: u8 = 72;
        pub const define_field: u8 = 73;
        pub const set_name: u8 = 74;
        pub const set_name_computed: u8 = 75;
        pub const set_proto: u8 = 76;
        pub const set_home_object: u8 = 77;
        pub const define_array_el: u8 = 78;
        pub const append: u8 = 79;
        pub const copy_data_properties: u8 = 80;
        pub const define_method: u8 = 81;
        pub const define_method_computed: u8 = 82;
        pub const define_class: u8 = 83;
        pub const define_class_computed: u8 = 84;
        pub const get_loc: u8 = 85;
        pub const put_loc: u8 = 86;
        pub const set_loc: u8 = 87;
        pub const get_arg: u8 = 88;
        pub const put_arg: u8 = 89;
        pub const set_arg: u8 = 90;
        pub const get_var_ref: u8 = 91;
        pub const put_var_ref: u8 = 92;
        pub const set_var_ref: u8 = 93;
        pub const set_loc_uninitialized: u8 = 94;
        pub const get_loc_check: u8 = 95;
        pub const put_loc_check: u8 = 96;
        pub const set_loc_check: u8 = 97;
        pub const put_loc_check_init: u8 = 98;
        pub const get_loc_checkthis: u8 = 99;
        pub const get_var_ref_check: u8 = 100;
        pub const put_var_ref_check: u8 = 101;
        pub const put_var_ref_check_init: u8 = 102;
        pub const close_loc: u8 = 103;
        pub const if_false: u8 = 104;
        pub const if_true: u8 = 105;
        pub const goto: u8 = 106;
        pub const @"catch": u8 = 107;
        pub const gosub: u8 = 108;
        pub const ret: u8 = 109;
        pub const nip_catch: u8 = 110;
        pub const to_object: u8 = 111;
        pub const to_propkey: u8 = 112;
        pub const with_get_var: u8 = 113;
        pub const with_put_var: u8 = 114;
        pub const with_delete_var: u8 = 115;
        pub const with_make_ref: u8 = 116;
        pub const with_get_ref: u8 = 117;
        pub const make_loc_ref: u8 = 118;
        pub const make_arg_ref: u8 = 119;
        pub const make_var_ref_ref: u8 = 120;
        pub const make_var_ref: u8 = 121;
        pub const for_in_start: u8 = 122;
        pub const for_of_start: u8 = 123;
        pub const for_await_of_start: u8 = 124;
        pub const for_in_next: u8 = 125;
        pub const for_of_next: u8 = 126;
        pub const for_await_of_next: u8 = 127;
        pub const iterator_check_object: u8 = 128;
        pub const iterator_get_value_done: u8 = 129;
        pub const iterator_close: u8 = 130;
        pub const iterator_next: u8 = 131;
        pub const iterator_call: u8 = 132;
        pub const initial_yield: u8 = 133;
        pub const yield: u8 = 134;
        pub const yield_star: u8 = 135;
        pub const async_yield_star: u8 = 136;
        pub const await: u8 = 137;
        pub const neg: u8 = 138;
        pub const plus: u8 = 139;
        pub const dec: u8 = 140;
        pub const inc: u8 = 141;
        pub const post_dec: u8 = 142;
        pub const post_inc: u8 = 143;
        pub const dec_loc: u8 = 144;
        pub const inc_loc: u8 = 145;
        pub const add_loc: u8 = 146;
        pub const not: u8 = 147;
        pub const lnot: u8 = 148;
        pub const typeof: u8 = 149;
        pub const delete: u8 = 150;
        pub const delete_var: u8 = 151;
        pub const mul: u8 = 152;
        pub const div: u8 = 153;
        pub const mod: u8 = 154;
        pub const add: u8 = 155;
        pub const sub: u8 = 156;
        pub const pow: u8 = 157;
        pub const shl: u8 = 158;
        pub const sar: u8 = 159;
        pub const shr: u8 = 160;
        pub const lt: u8 = 161;
        pub const lte: u8 = 162;
        pub const gt: u8 = 163;
        pub const gte: u8 = 164;
        pub const instanceof: u8 = 165;
        pub const in: u8 = 166;
        pub const eq: u8 = 167;
        pub const neq: u8 = 168;
        pub const strict_eq: u8 = 169;
        pub const strict_neq: u8 = 170;
        pub const @"and": u8 = 171;
        pub const xor: u8 = 172;
        pub const @"or": u8 = 173;
        pub const is_undefined_or_null: u8 = 174;
        pub const private_in: u8 = 175;
        pub const push_bigint_i32: u8 = 176;
        pub const nop: u8 = 177;
        pub const push_minus1: u8 = 178;
        pub const push_0: u8 = 179;
        pub const push_1: u8 = 180;
        pub const push_2: u8 = 181;
        pub const push_3: u8 = 182;
        pub const push_4: u8 = 183;
        pub const push_5: u8 = 184;
        pub const push_6: u8 = 185;
        pub const push_7: u8 = 186;
        pub const push_i8: u8 = 187;
        pub const push_i16: u8 = 188;
        pub const push_const8: u8 = 189;
        pub const fclosure8: u8 = 190;
        pub const push_empty_string: u8 = 191;
        pub const get_loc8: u8 = 192;
        pub const put_loc8: u8 = 193;
        pub const set_loc8: u8 = 194;
        pub const get_loc0: u8 = 195;
        pub const get_loc1: u8 = 196;
        pub const get_loc2: u8 = 197;
        pub const get_loc3: u8 = 198;
        pub const put_loc0: u8 = 199;
        pub const put_loc1: u8 = 200;
        pub const put_loc2: u8 = 201;
        pub const put_loc3: u8 = 202;
        pub const set_loc0: u8 = 203;
        pub const set_loc1: u8 = 204;
        pub const set_loc2: u8 = 205;
        pub const set_loc3: u8 = 206;
        pub const get_arg0: u8 = 207;
        pub const get_arg1: u8 = 208;
        pub const get_arg2: u8 = 209;
        pub const get_arg3: u8 = 210;
        pub const put_arg0: u8 = 211;
        pub const put_arg1: u8 = 212;
        pub const put_arg2: u8 = 213;
        pub const put_arg3: u8 = 214;
        pub const set_arg0: u8 = 215;
        pub const set_arg1: u8 = 216;
        pub const set_arg2: u8 = 217;
        pub const set_arg3: u8 = 218;
        pub const get_var_ref0: u8 = 219;
        pub const get_var_ref1: u8 = 220;
        pub const get_var_ref2: u8 = 221;
        pub const get_var_ref3: u8 = 222;
        pub const put_var_ref0: u8 = 223;
        pub const put_var_ref1: u8 = 224;
        pub const put_var_ref2: u8 = 225;
        pub const put_var_ref3: u8 = 226;
        pub const set_var_ref0: u8 = 227;
        pub const set_var_ref1: u8 = 228;
        pub const set_var_ref2: u8 = 229;
        pub const set_var_ref3: u8 = 230;
        pub const get_length: u8 = 231;
        pub const if_false8: u8 = 232;
        pub const if_true8: u8 = 233;
        pub const goto8: u8 = 234;
        pub const goto16: u8 = 235;
        pub const call0: u8 = 236;
        pub const call1: u8 = 237;
        pub const call2: u8 = 238;
        pub const call3: u8 = 239;
        pub const is_undefined: u8 = 240;
        pub const is_null: u8 = 241;
        pub const typeof_is_undefined: u8 = 242;
        pub const typeof_is_function: u8 = 243;

        // Temporary opcodes (phase-1 emit, erased before resolve_labels).
        // Ids overlap the short opcodes above; phase-1 streams and final
        // streams must use the matching opcode.zig view to size them.
        pub const enter_scope: u8 = 178;
        pub const leave_scope: u8 = 179;
        pub const label: u8 = 180;
        pub const scope_get_var_undef: u8 = 181;
        pub const scope_get_var: u8 = 182;
        pub const scope_put_var: u8 = 183;
        pub const scope_delete_var: u8 = 184;
        pub const scope_make_ref: u8 = 185;
        pub const scope_get_ref: u8 = 186;
        pub const scope_put_var_init: u8 = 187;
        pub const scope_get_var_checkthis: u8 = 188;
        pub const scope_get_private_field: u8 = 189;
        pub const scope_get_private_field2: u8 = 190;
        pub const scope_put_private_field: u8 = 191;
        pub const scope_in_private_field: u8 = 192;
        pub const get_field_opt_chain: u8 = 193;
        pub const get_array_el_opt_chain: u8 = 194;
        pub const set_class_name: u8 = 195;
        pub const line_num: u8 = 196;

        /// Number of real (DEF) opcodes; ids 0..op_count-1 are claimed.
        pub const op_count: u16 = 244;
        /// First id of the temp/short overlap range (OP_nop + 1).
        pub const op_temp_start: u8 = 178;
        /// One past the last temp id (exclusive).
        pub const op_temp_end: u8 = 197;
        /// Number of temp opcodes (= short-entry shift in `opcode_info`).
        pub const op_temp_count: u8 = 19;
    };

    pub const op_info_len: usize = 263;

    /// Merged metadata table in quickjs-opcode.h file order (see header
    /// comment for the index layout).
    pub const opcode_info: [op_info_len]Info = .{
        .{ .name = "invalid", .size = 1, .n_pop = 0, .n_push = 0, .fmt = .none }, // [0] id 0
        .{ .name = "push_i32", .size = 5, .n_pop = 0, .n_push = 1, .fmt = .i32 }, // [1] id 1
        .{ .name = "push_const", .size = 5, .n_pop = 0, .n_push = 1, .fmt = .@"const" }, // [2] id 2
        .{ .name = "fclosure", .size = 5, .n_pop = 0, .n_push = 1, .fmt = .@"const" }, // [3] id 3
        .{ .name = "push_atom_value", .size = 5, .n_pop = 0, .n_push = 1, .fmt = .atom }, // [4] id 4
        .{ .name = "private_symbol", .size = 5, .n_pop = 0, .n_push = 1, .fmt = .atom }, // [5] id 5
        .{ .name = "undefined", .size = 1, .n_pop = 0, .n_push = 1, .fmt = .none }, // [6] id 6
        .{ .name = "null", .size = 1, .n_pop = 0, .n_push = 1, .fmt = .none }, // [7] id 7
        .{ .name = "push_this", .size = 1, .n_pop = 0, .n_push = 1, .fmt = .none }, // [8] id 8
        .{ .name = "push_false", .size = 1, .n_pop = 0, .n_push = 1, .fmt = .none }, // [9] id 9
        .{ .name = "push_true", .size = 1, .n_pop = 0, .n_push = 1, .fmt = .none }, // [10] id 10
        .{ .name = "object", .size = 1, .n_pop = 0, .n_push = 1, .fmt = .none }, // [11] id 11
        .{ .name = "special_object", .size = 2, .n_pop = 0, .n_push = 1, .fmt = .u8 }, // [12] id 12
        .{ .name = "rest", .size = 3, .n_pop = 0, .n_push = 1, .fmt = .u16 }, // [13] id 13
        .{ .name = "drop", .size = 1, .n_pop = 1, .n_push = 0, .fmt = .none }, // [14] id 14
        .{ .name = "nip", .size = 1, .n_pop = 2, .n_push = 1, .fmt = .none }, // [15] id 15
        .{ .name = "nip1", .size = 1, .n_pop = 3, .n_push = 2, .fmt = .none }, // [16] id 16
        .{ .name = "dup", .size = 1, .n_pop = 1, .n_push = 2, .fmt = .none }, // [17] id 17
        .{ .name = "dup1", .size = 1, .n_pop = 2, .n_push = 3, .fmt = .none }, // [18] id 18
        .{ .name = "dup2", .size = 1, .n_pop = 2, .n_push = 4, .fmt = .none }, // [19] id 19
        .{ .name = "dup3", .size = 1, .n_pop = 3, .n_push = 6, .fmt = .none }, // [20] id 20
        .{ .name = "insert2", .size = 1, .n_pop = 2, .n_push = 3, .fmt = .none }, // [21] id 21
        .{ .name = "insert3", .size = 1, .n_pop = 3, .n_push = 4, .fmt = .none }, // [22] id 22
        .{ .name = "insert4", .size = 1, .n_pop = 4, .n_push = 5, .fmt = .none }, // [23] id 23
        .{ .name = "perm3", .size = 1, .n_pop = 3, .n_push = 3, .fmt = .none }, // [24] id 24
        .{ .name = "perm4", .size = 1, .n_pop = 4, .n_push = 4, .fmt = .none }, // [25] id 25
        .{ .name = "perm5", .size = 1, .n_pop = 5, .n_push = 5, .fmt = .none }, // [26] id 26
        .{ .name = "swap", .size = 1, .n_pop = 2, .n_push = 2, .fmt = .none }, // [27] id 27
        .{ .name = "swap2", .size = 1, .n_pop = 4, .n_push = 4, .fmt = .none }, // [28] id 28
        .{ .name = "rot3l", .size = 1, .n_pop = 3, .n_push = 3, .fmt = .none }, // [29] id 29
        .{ .name = "rot3r", .size = 1, .n_pop = 3, .n_push = 3, .fmt = .none }, // [30] id 30
        .{ .name = "rot4l", .size = 1, .n_pop = 4, .n_push = 4, .fmt = .none }, // [31] id 31
        .{ .name = "rot5l", .size = 1, .n_pop = 5, .n_push = 5, .fmt = .none }, // [32] id 32
        .{ .name = "call_constructor", .size = 3, .n_pop = 2, .n_push = 1, .fmt = .npop }, // [33] id 33
        .{ .name = "call", .size = 3, .n_pop = 1, .n_push = 1, .fmt = .npop }, // [34] id 34
        .{ .name = "tail_call", .size = 3, .n_pop = 1, .n_push = 0, .fmt = .npop }, // [35] id 35
        .{ .name = "call_method", .size = 3, .n_pop = 2, .n_push = 1, .fmt = .npop }, // [36] id 36
        .{ .name = "tail_call_method", .size = 3, .n_pop = 2, .n_push = 0, .fmt = .npop }, // [37] id 37
        .{ .name = "array_from", .size = 3, .n_pop = 0, .n_push = 1, .fmt = .npop }, // [38] id 38
        .{ .name = "apply", .size = 3, .n_pop = 3, .n_push = 1, .fmt = .u16 }, // [39] id 39
        .{ .name = "return", .size = 1, .n_pop = 1, .n_push = 0, .fmt = .none }, // [40] id 40
        .{ .name = "return_undef", .size = 1, .n_pop = 0, .n_push = 0, .fmt = .none }, // [41] id 41
        .{ .name = "check_ctor_return", .size = 1, .n_pop = 1, .n_push = 2, .fmt = .none }, // [42] id 42
        .{ .name = "check_ctor", .size = 1, .n_pop = 0, .n_push = 0, .fmt = .none }, // [43] id 43
        .{ .name = "init_ctor", .size = 1, .n_pop = 0, .n_push = 1, .fmt = .none }, // [44] id 44
        .{ .name = "check_brand", .size = 1, .n_pop = 2, .n_push = 2, .fmt = .none }, // [45] id 45
        .{ .name = "add_brand", .size = 1, .n_pop = 2, .n_push = 0, .fmt = .none }, // [46] id 46
        .{ .name = "return_async", .size = 1, .n_pop = 1, .n_push = 0, .fmt = .none }, // [47] id 47
        .{ .name = "throw", .size = 1, .n_pop = 1, .n_push = 0, .fmt = .none }, // [48] id 48
        .{ .name = "throw_error", .size = 6, .n_pop = 0, .n_push = 0, .fmt = .atom_u8 }, // [49] id 49
        .{ .name = "eval", .size = 5, .n_pop = 1, .n_push = 1, .fmt = .npop_u16 }, // [50] id 50
        .{ .name = "apply_eval", .size = 3, .n_pop = 2, .n_push = 1, .fmt = .u16 }, // [51] id 51
        .{ .name = "regexp", .size = 1, .n_pop = 2, .n_push = 1, .fmt = .none }, // [52] id 52
        .{ .name = "get_super", .size = 1, .n_pop = 1, .n_push = 1, .fmt = .none }, // [53] id 53
        .{ .name = "import", .size = 1, .n_pop = 2, .n_push = 1, .fmt = .none }, // [54] id 54
        .{ .name = "get_var_undef", .size = 3, .n_pop = 0, .n_push = 1, .fmt = .var_ref }, // [55] id 55
        .{ .name = "get_var", .size = 3, .n_pop = 0, .n_push = 1, .fmt = .var_ref }, // [56] id 56
        .{ .name = "put_var", .size = 3, .n_pop = 1, .n_push = 0, .fmt = .var_ref }, // [57] id 57
        .{ .name = "put_var_init", .size = 3, .n_pop = 1, .n_push = 0, .fmt = .var_ref }, // [58] id 58
        .{ .name = "get_ref_value", .size = 1, .n_pop = 2, .n_push = 3, .fmt = .none }, // [59] id 59
        .{ .name = "put_ref_value", .size = 1, .n_pop = 3, .n_push = 0, .fmt = .none }, // [60] id 60
        .{ .name = "get_field", .size = 5, .n_pop = 1, .n_push = 1, .fmt = .atom }, // [61] id 61
        .{ .name = "get_field2", .size = 5, .n_pop = 1, .n_push = 2, .fmt = .atom }, // [62] id 62
        .{ .name = "put_field", .size = 5, .n_pop = 2, .n_push = 0, .fmt = .atom }, // [63] id 63
        .{ .name = "get_private_field", .size = 1, .n_pop = 2, .n_push = 1, .fmt = .none }, // [64] id 64
        .{ .name = "put_private_field", .size = 1, .n_pop = 3, .n_push = 0, .fmt = .none }, // [65] id 65
        .{ .name = "define_private_field", .size = 1, .n_pop = 3, .n_push = 1, .fmt = .none }, // [66] id 66
        .{ .name = "get_array_el", .size = 1, .n_pop = 2, .n_push = 1, .fmt = .none }, // [67] id 67
        .{ .name = "get_array_el2", .size = 1, .n_pop = 2, .n_push = 2, .fmt = .none }, // [68] id 68
        .{ .name = "get_array_el3", .size = 1, .n_pop = 2, .n_push = 3, .fmt = .none }, // [69] id 69
        .{ .name = "put_array_el", .size = 1, .n_pop = 3, .n_push = 0, .fmt = .none }, // [70] id 70
        .{ .name = "get_super_value", .size = 1, .n_pop = 3, .n_push = 1, .fmt = .none }, // [71] id 71
        .{ .name = "put_super_value", .size = 1, .n_pop = 4, .n_push = 0, .fmt = .none }, // [72] id 72
        .{ .name = "define_field", .size = 5, .n_pop = 2, .n_push = 1, .fmt = .atom }, // [73] id 73
        .{ .name = "set_name", .size = 5, .n_pop = 1, .n_push = 1, .fmt = .atom }, // [74] id 74
        .{ .name = "set_name_computed", .size = 1, .n_pop = 2, .n_push = 2, .fmt = .none }, // [75] id 75
        .{ .name = "set_proto", .size = 1, .n_pop = 2, .n_push = 1, .fmt = .none }, // [76] id 76
        .{ .name = "set_home_object", .size = 1, .n_pop = 2, .n_push = 2, .fmt = .none }, // [77] id 77
        .{ .name = "define_array_el", .size = 1, .n_pop = 3, .n_push = 2, .fmt = .none }, // [78] id 78
        .{ .name = "append", .size = 1, .n_pop = 3, .n_push = 2, .fmt = .none }, // [79] id 79
        .{ .name = "copy_data_properties", .size = 2, .n_pop = 3, .n_push = 3, .fmt = .u8 }, // [80] id 80
        .{ .name = "define_method", .size = 6, .n_pop = 2, .n_push = 1, .fmt = .atom_u8 }, // [81] id 81
        .{ .name = "define_method_computed", .size = 2, .n_pop = 3, .n_push = 1, .fmt = .u8 }, // [82] id 82
        .{ .name = "define_class", .size = 6, .n_pop = 2, .n_push = 2, .fmt = .atom_u8 }, // [83] id 83
        .{ .name = "define_class_computed", .size = 6, .n_pop = 3, .n_push = 3, .fmt = .atom_u8 }, // [84] id 84
        .{ .name = "get_loc", .size = 3, .n_pop = 0, .n_push = 1, .fmt = .loc }, // [85] id 85
        .{ .name = "put_loc", .size = 3, .n_pop = 1, .n_push = 0, .fmt = .loc }, // [86] id 86
        .{ .name = "set_loc", .size = 3, .n_pop = 1, .n_push = 1, .fmt = .loc }, // [87] id 87
        .{ .name = "get_arg", .size = 3, .n_pop = 0, .n_push = 1, .fmt = .arg }, // [88] id 88
        .{ .name = "put_arg", .size = 3, .n_pop = 1, .n_push = 0, .fmt = .arg }, // [89] id 89
        .{ .name = "set_arg", .size = 3, .n_pop = 1, .n_push = 1, .fmt = .arg }, // [90] id 90
        .{ .name = "get_var_ref", .size = 3, .n_pop = 0, .n_push = 1, .fmt = .var_ref }, // [91] id 91
        .{ .name = "put_var_ref", .size = 3, .n_pop = 1, .n_push = 0, .fmt = .var_ref }, // [92] id 92
        .{ .name = "set_var_ref", .size = 3, .n_pop = 1, .n_push = 1, .fmt = .var_ref }, // [93] id 93
        .{ .name = "set_loc_uninitialized", .size = 3, .n_pop = 0, .n_push = 0, .fmt = .loc }, // [94] id 94
        .{ .name = "get_loc_check", .size = 3, .n_pop = 0, .n_push = 1, .fmt = .loc }, // [95] id 95
        .{ .name = "put_loc_check", .size = 3, .n_pop = 1, .n_push = 0, .fmt = .loc }, // [96] id 96
        .{ .name = "set_loc_check", .size = 3, .n_pop = 1, .n_push = 1, .fmt = .loc }, // [97] id 97
        .{ .name = "put_loc_check_init", .size = 3, .n_pop = 1, .n_push = 0, .fmt = .loc }, // [98] id 98
        .{ .name = "get_loc_checkthis", .size = 3, .n_pop = 0, .n_push = 1, .fmt = .loc }, // [99] id 99
        .{ .name = "get_var_ref_check", .size = 3, .n_pop = 0, .n_push = 1, .fmt = .var_ref }, // [100] id 100
        .{ .name = "put_var_ref_check", .size = 3, .n_pop = 1, .n_push = 0, .fmt = .var_ref }, // [101] id 101
        .{ .name = "put_var_ref_check_init", .size = 3, .n_pop = 1, .n_push = 0, .fmt = .var_ref }, // [102] id 102
        .{ .name = "close_loc", .size = 3, .n_pop = 0, .n_push = 0, .fmt = .loc }, // [103] id 103
        .{ .name = "if_false", .size = 5, .n_pop = 1, .n_push = 0, .fmt = .label }, // [104] id 104
        .{ .name = "if_true", .size = 5, .n_pop = 1, .n_push = 0, .fmt = .label }, // [105] id 105
        .{ .name = "goto", .size = 5, .n_pop = 0, .n_push = 0, .fmt = .label }, // [106] id 106
        .{ .name = "catch", .size = 5, .n_pop = 0, .n_push = 1, .fmt = .label }, // [107] id 107
        .{ .name = "gosub", .size = 5, .n_pop = 0, .n_push = 0, .fmt = .label }, // [108] id 108
        .{ .name = "ret", .size = 1, .n_pop = 1, .n_push = 0, .fmt = .none }, // [109] id 109
        .{ .name = "nip_catch", .size = 1, .n_pop = 2, .n_push = 1, .fmt = .none }, // [110] id 110
        .{ .name = "to_object", .size = 1, .n_pop = 1, .n_push = 1, .fmt = .none }, // [111] id 111
        .{ .name = "to_propkey", .size = 1, .n_pop = 1, .n_push = 1, .fmt = .none }, // [112] id 112
        .{ .name = "with_get_var", .size = 10, .n_pop = 1, .n_push = 0, .fmt = .atom_label_u8 }, // [113] id 113
        .{ .name = "with_put_var", .size = 10, .n_pop = 2, .n_push = 1, .fmt = .atom_label_u8 }, // [114] id 114
        .{ .name = "with_delete_var", .size = 10, .n_pop = 1, .n_push = 0, .fmt = .atom_label_u8 }, // [115] id 115
        .{ .name = "with_make_ref", .size = 10, .n_pop = 1, .n_push = 0, .fmt = .atom_label_u8 }, // [116] id 116
        .{ .name = "with_get_ref", .size = 10, .n_pop = 1, .n_push = 0, .fmt = .atom_label_u8 }, // [117] id 117
        .{ .name = "make_loc_ref", .size = 7, .n_pop = 0, .n_push = 2, .fmt = .atom_u16 }, // [118] id 118
        .{ .name = "make_arg_ref", .size = 7, .n_pop = 0, .n_push = 2, .fmt = .atom_u16 }, // [119] id 119
        .{ .name = "make_var_ref_ref", .size = 7, .n_pop = 0, .n_push = 2, .fmt = .atom_u16 }, // [120] id 120
        .{ .name = "make_var_ref", .size = 5, .n_pop = 0, .n_push = 2, .fmt = .atom }, // [121] id 121
        .{ .name = "for_in_start", .size = 1, .n_pop = 1, .n_push = 1, .fmt = .none }, // [122] id 122
        .{ .name = "for_of_start", .size = 1, .n_pop = 1, .n_push = 3, .fmt = .none }, // [123] id 123
        .{ .name = "for_await_of_start", .size = 1, .n_pop = 1, .n_push = 3, .fmt = .none }, // [124] id 124
        .{ .name = "for_in_next", .size = 1, .n_pop = 1, .n_push = 3, .fmt = .none }, // [125] id 125
        .{ .name = "for_of_next", .size = 2, .n_pop = 3, .n_push = 5, .fmt = .u8 }, // [126] id 126
        .{ .name = "for_await_of_next", .size = 1, .n_pop = 3, .n_push = 4, .fmt = .none }, // [127] id 127
        .{ .name = "iterator_check_object", .size = 1, .n_pop = 1, .n_push = 1, .fmt = .none }, // [128] id 128
        .{ .name = "iterator_get_value_done", .size = 1, .n_pop = 2, .n_push = 3, .fmt = .none }, // [129] id 129
        .{ .name = "iterator_close", .size = 1, .n_pop = 3, .n_push = 0, .fmt = .none }, // [130] id 130
        .{ .name = "iterator_next", .size = 1, .n_pop = 4, .n_push = 4, .fmt = .none }, // [131] id 131
        .{ .name = "iterator_call", .size = 2, .n_pop = 4, .n_push = 5, .fmt = .u8 }, // [132] id 132
        .{ .name = "initial_yield", .size = 1, .n_pop = 0, .n_push = 0, .fmt = .none }, // [133] id 133
        .{ .name = "yield", .size = 1, .n_pop = 1, .n_push = 2, .fmt = .none }, // [134] id 134
        .{ .name = "yield_star", .size = 1, .n_pop = 1, .n_push = 2, .fmt = .none }, // [135] id 135
        .{ .name = "async_yield_star", .size = 1, .n_pop = 1, .n_push = 2, .fmt = .none }, // [136] id 136
        .{ .name = "await", .size = 1, .n_pop = 1, .n_push = 1, .fmt = .none }, // [137] id 137
        .{ .name = "neg", .size = 1, .n_pop = 1, .n_push = 1, .fmt = .none }, // [138] id 138
        .{ .name = "plus", .size = 1, .n_pop = 1, .n_push = 1, .fmt = .none }, // [139] id 139
        .{ .name = "dec", .size = 1, .n_pop = 1, .n_push = 1, .fmt = .none }, // [140] id 140
        .{ .name = "inc", .size = 1, .n_pop = 1, .n_push = 1, .fmt = .none }, // [141] id 141
        .{ .name = "post_dec", .size = 1, .n_pop = 1, .n_push = 2, .fmt = .none }, // [142] id 142
        .{ .name = "post_inc", .size = 1, .n_pop = 1, .n_push = 2, .fmt = .none }, // [143] id 143
        .{ .name = "dec_loc", .size = 2, .n_pop = 0, .n_push = 0, .fmt = .loc8 }, // [144] id 144
        .{ .name = "inc_loc", .size = 2, .n_pop = 0, .n_push = 0, .fmt = .loc8 }, // [145] id 145
        .{ .name = "add_loc", .size = 2, .n_pop = 1, .n_push = 0, .fmt = .loc8 }, // [146] id 146
        .{ .name = "not", .size = 1, .n_pop = 1, .n_push = 1, .fmt = .none }, // [147] id 147
        .{ .name = "lnot", .size = 1, .n_pop = 1, .n_push = 1, .fmt = .none }, // [148] id 148
        .{ .name = "typeof", .size = 1, .n_pop = 1, .n_push = 1, .fmt = .none }, // [149] id 149
        .{ .name = "delete", .size = 1, .n_pop = 2, .n_push = 1, .fmt = .none }, // [150] id 150
        .{ .name = "delete_var", .size = 5, .n_pop = 0, .n_push = 1, .fmt = .atom }, // [151] id 151
        .{ .name = "mul", .size = 1, .n_pop = 2, .n_push = 1, .fmt = .none }, // [152] id 152
        .{ .name = "div", .size = 1, .n_pop = 2, .n_push = 1, .fmt = .none }, // [153] id 153
        .{ .name = "mod", .size = 1, .n_pop = 2, .n_push = 1, .fmt = .none }, // [154] id 154
        .{ .name = "add", .size = 1, .n_pop = 2, .n_push = 1, .fmt = .none }, // [155] id 155
        .{ .name = "sub", .size = 1, .n_pop = 2, .n_push = 1, .fmt = .none }, // [156] id 156
        .{ .name = "pow", .size = 1, .n_pop = 2, .n_push = 1, .fmt = .none }, // [157] id 157
        .{ .name = "shl", .size = 1, .n_pop = 2, .n_push = 1, .fmt = .none }, // [158] id 158
        .{ .name = "sar", .size = 1, .n_pop = 2, .n_push = 1, .fmt = .none }, // [159] id 159
        .{ .name = "shr", .size = 1, .n_pop = 2, .n_push = 1, .fmt = .none }, // [160] id 160
        .{ .name = "lt", .size = 1, .n_pop = 2, .n_push = 1, .fmt = .none }, // [161] id 161
        .{ .name = "lte", .size = 1, .n_pop = 2, .n_push = 1, .fmt = .none }, // [162] id 162
        .{ .name = "gt", .size = 1, .n_pop = 2, .n_push = 1, .fmt = .none }, // [163] id 163
        .{ .name = "gte", .size = 1, .n_pop = 2, .n_push = 1, .fmt = .none }, // [164] id 164
        .{ .name = "instanceof", .size = 1, .n_pop = 2, .n_push = 1, .fmt = .none }, // [165] id 165
        .{ .name = "in", .size = 1, .n_pop = 2, .n_push = 1, .fmt = .none }, // [166] id 166
        .{ .name = "eq", .size = 1, .n_pop = 2, .n_push = 1, .fmt = .none }, // [167] id 167
        .{ .name = "neq", .size = 1, .n_pop = 2, .n_push = 1, .fmt = .none }, // [168] id 168
        .{ .name = "strict_eq", .size = 1, .n_pop = 2, .n_push = 1, .fmt = .none }, // [169] id 169
        .{ .name = "strict_neq", .size = 1, .n_pop = 2, .n_push = 1, .fmt = .none }, // [170] id 170
        .{ .name = "and", .size = 1, .n_pop = 2, .n_push = 1, .fmt = .none }, // [171] id 171
        .{ .name = "xor", .size = 1, .n_pop = 2, .n_push = 1, .fmt = .none }, // [172] id 172
        .{ .name = "or", .size = 1, .n_pop = 2, .n_push = 1, .fmt = .none }, // [173] id 173
        .{ .name = "is_undefined_or_null", .size = 1, .n_pop = 1, .n_push = 1, .fmt = .none }, // [174] id 174
        .{ .name = "private_in", .size = 1, .n_pop = 2, .n_push = 1, .fmt = .none }, // [175] id 175
        .{ .name = "push_bigint_i32", .size = 5, .n_pop = 0, .n_push = 1, .fmt = .i32 }, // [176] id 176
        .{ .name = "nop", .size = 1, .n_pop = 0, .n_push = 0, .fmt = .none }, // [177] id 177
        .{ .name = "enter_scope", .size = 3, .n_pop = 0, .n_push = 0, .fmt = .u16 }, // [178] id 178 (temp)
        .{ .name = "leave_scope", .size = 3, .n_pop = 0, .n_push = 0, .fmt = .u16 }, // [179] id 179 (temp)
        .{ .name = "label", .size = 5, .n_pop = 0, .n_push = 0, .fmt = .label }, // [180] id 180 (temp)
        .{ .name = "scope_get_var_undef", .size = 7, .n_pop = 0, .n_push = 1, .fmt = .atom_u16 }, // [181] id 181 (temp)
        .{ .name = "scope_get_var", .size = 7, .n_pop = 0, .n_push = 1, .fmt = .atom_u16 }, // [182] id 182 (temp)
        .{ .name = "scope_put_var", .size = 7, .n_pop = 1, .n_push = 0, .fmt = .atom_u16 }, // [183] id 183 (temp)
        .{ .name = "scope_delete_var", .size = 7, .n_pop = 0, .n_push = 1, .fmt = .atom_u16 }, // [184] id 184 (temp)
        .{ .name = "scope_make_ref", .size = 11, .n_pop = 0, .n_push = 2, .fmt = .atom_label_u16 }, // [185] id 185 (temp)
        .{ .name = "scope_get_ref", .size = 7, .n_pop = 0, .n_push = 2, .fmt = .atom_u16 }, // [186] id 186 (temp)
        .{ .name = "scope_put_var_init", .size = 7, .n_pop = 0, .n_push = 2, .fmt = .atom_u16 }, // [187] id 187 (temp)
        .{ .name = "scope_get_var_checkthis", .size = 7, .n_pop = 0, .n_push = 1, .fmt = .atom_u16 }, // [188] id 188 (temp)
        .{ .name = "scope_get_private_field", .size = 7, .n_pop = 1, .n_push = 1, .fmt = .atom_u16 }, // [189] id 189 (temp)
        .{ .name = "scope_get_private_field2", .size = 7, .n_pop = 1, .n_push = 2, .fmt = .atom_u16 }, // [190] id 190 (temp)
        .{ .name = "scope_put_private_field", .size = 7, .n_pop = 2, .n_push = 0, .fmt = .atom_u16 }, // [191] id 191 (temp)
        .{ .name = "scope_in_private_field", .size = 7, .n_pop = 1, .n_push = 1, .fmt = .atom_u16 }, // [192] id 192 (temp)
        .{ .name = "get_field_opt_chain", .size = 5, .n_pop = 1, .n_push = 1, .fmt = .atom }, // [193] id 193 (temp)
        .{ .name = "get_array_el_opt_chain", .size = 1, .n_pop = 2, .n_push = 1, .fmt = .none }, // [194] id 194 (temp)
        .{ .name = "set_class_name", .size = 5, .n_pop = 1, .n_push = 1, .fmt = .u32 }, // [195] id 195 (temp)
        .{ .name = "line_num", .size = 5, .n_pop = 0, .n_push = 0, .fmt = .u32 }, // [196] id 196 (temp)
        .{ .name = "push_minus1", .size = 1, .n_pop = 0, .n_push = 1, .fmt = .none_int }, // [197] id 178 (short, shifted)
        .{ .name = "push_0", .size = 1, .n_pop = 0, .n_push = 1, .fmt = .none_int }, // [198] id 179 (short, shifted)
        .{ .name = "push_1", .size = 1, .n_pop = 0, .n_push = 1, .fmt = .none_int }, // [199] id 180 (short, shifted)
        .{ .name = "push_2", .size = 1, .n_pop = 0, .n_push = 1, .fmt = .none_int }, // [200] id 181 (short, shifted)
        .{ .name = "push_3", .size = 1, .n_pop = 0, .n_push = 1, .fmt = .none_int }, // [201] id 182 (short, shifted)
        .{ .name = "push_4", .size = 1, .n_pop = 0, .n_push = 1, .fmt = .none_int }, // [202] id 183 (short, shifted)
        .{ .name = "push_5", .size = 1, .n_pop = 0, .n_push = 1, .fmt = .none_int }, // [203] id 184 (short, shifted)
        .{ .name = "push_6", .size = 1, .n_pop = 0, .n_push = 1, .fmt = .none_int }, // [204] id 185 (short, shifted)
        .{ .name = "push_7", .size = 1, .n_pop = 0, .n_push = 1, .fmt = .none_int }, // [205] id 186 (short, shifted)
        .{ .name = "push_i8", .size = 2, .n_pop = 0, .n_push = 1, .fmt = .i8 }, // [206] id 187 (short, shifted)
        .{ .name = "push_i16", .size = 3, .n_pop = 0, .n_push = 1, .fmt = .i16 }, // [207] id 188 (short, shifted)
        .{ .name = "push_const8", .size = 2, .n_pop = 0, .n_push = 1, .fmt = .const8 }, // [208] id 189 (short, shifted)
        .{ .name = "fclosure8", .size = 2, .n_pop = 0, .n_push = 1, .fmt = .const8 }, // [209] id 190 (short, shifted)
        .{ .name = "push_empty_string", .size = 1, .n_pop = 0, .n_push = 1, .fmt = .none }, // [210] id 191 (short, shifted)
        .{ .name = "get_loc8", .size = 2, .n_pop = 0, .n_push = 1, .fmt = .loc8 }, // [211] id 192 (short, shifted)
        .{ .name = "put_loc8", .size = 2, .n_pop = 1, .n_push = 0, .fmt = .loc8 }, // [212] id 193 (short, shifted)
        .{ .name = "set_loc8", .size = 2, .n_pop = 1, .n_push = 1, .fmt = .loc8 }, // [213] id 194 (short, shifted)
        .{ .name = "get_loc0", .size = 1, .n_pop = 0, .n_push = 1, .fmt = .none_loc }, // [214] id 195 (short, shifted)
        .{ .name = "get_loc1", .size = 1, .n_pop = 0, .n_push = 1, .fmt = .none_loc }, // [215] id 196 (short, shifted)
        .{ .name = "get_loc2", .size = 1, .n_pop = 0, .n_push = 1, .fmt = .none_loc }, // [216] id 197 (short, shifted)
        .{ .name = "get_loc3", .size = 1, .n_pop = 0, .n_push = 1, .fmt = .none_loc }, // [217] id 198 (short, shifted)
        .{ .name = "put_loc0", .size = 1, .n_pop = 1, .n_push = 0, .fmt = .none_loc }, // [218] id 199 (short, shifted)
        .{ .name = "put_loc1", .size = 1, .n_pop = 1, .n_push = 0, .fmt = .none_loc }, // [219] id 200 (short, shifted)
        .{ .name = "put_loc2", .size = 1, .n_pop = 1, .n_push = 0, .fmt = .none_loc }, // [220] id 201 (short, shifted)
        .{ .name = "put_loc3", .size = 1, .n_pop = 1, .n_push = 0, .fmt = .none_loc }, // [221] id 202 (short, shifted)
        .{ .name = "set_loc0", .size = 1, .n_pop = 1, .n_push = 1, .fmt = .none_loc }, // [222] id 203 (short, shifted)
        .{ .name = "set_loc1", .size = 1, .n_pop = 1, .n_push = 1, .fmt = .none_loc }, // [223] id 204 (short, shifted)
        .{ .name = "set_loc2", .size = 1, .n_pop = 1, .n_push = 1, .fmt = .none_loc }, // [224] id 205 (short, shifted)
        .{ .name = "set_loc3", .size = 1, .n_pop = 1, .n_push = 1, .fmt = .none_loc }, // [225] id 206 (short, shifted)
        .{ .name = "get_arg0", .size = 1, .n_pop = 0, .n_push = 1, .fmt = .none_arg }, // [226] id 207 (short, shifted)
        .{ .name = "get_arg1", .size = 1, .n_pop = 0, .n_push = 1, .fmt = .none_arg }, // [227] id 208 (short, shifted)
        .{ .name = "get_arg2", .size = 1, .n_pop = 0, .n_push = 1, .fmt = .none_arg }, // [228] id 209 (short, shifted)
        .{ .name = "get_arg3", .size = 1, .n_pop = 0, .n_push = 1, .fmt = .none_arg }, // [229] id 210 (short, shifted)
        .{ .name = "put_arg0", .size = 1, .n_pop = 1, .n_push = 0, .fmt = .none_arg }, // [230] id 211 (short, shifted)
        .{ .name = "put_arg1", .size = 1, .n_pop = 1, .n_push = 0, .fmt = .none_arg }, // [231] id 212 (short, shifted)
        .{ .name = "put_arg2", .size = 1, .n_pop = 1, .n_push = 0, .fmt = .none_arg }, // [232] id 213 (short, shifted)
        .{ .name = "put_arg3", .size = 1, .n_pop = 1, .n_push = 0, .fmt = .none_arg }, // [233] id 214 (short, shifted)
        .{ .name = "set_arg0", .size = 1, .n_pop = 1, .n_push = 1, .fmt = .none_arg }, // [234] id 215 (short, shifted)
        .{ .name = "set_arg1", .size = 1, .n_pop = 1, .n_push = 1, .fmt = .none_arg }, // [235] id 216 (short, shifted)
        .{ .name = "set_arg2", .size = 1, .n_pop = 1, .n_push = 1, .fmt = .none_arg }, // [236] id 217 (short, shifted)
        .{ .name = "set_arg3", .size = 1, .n_pop = 1, .n_push = 1, .fmt = .none_arg }, // [237] id 218 (short, shifted)
        .{ .name = "get_var_ref0", .size = 1, .n_pop = 0, .n_push = 1, .fmt = .none_var_ref }, // [238] id 219 (short, shifted)
        .{ .name = "get_var_ref1", .size = 1, .n_pop = 0, .n_push = 1, .fmt = .none_var_ref }, // [239] id 220 (short, shifted)
        .{ .name = "get_var_ref2", .size = 1, .n_pop = 0, .n_push = 1, .fmt = .none_var_ref }, // [240] id 221 (short, shifted)
        .{ .name = "get_var_ref3", .size = 1, .n_pop = 0, .n_push = 1, .fmt = .none_var_ref }, // [241] id 222 (short, shifted)
        .{ .name = "put_var_ref0", .size = 1, .n_pop = 1, .n_push = 0, .fmt = .none_var_ref }, // [242] id 223 (short, shifted)
        .{ .name = "put_var_ref1", .size = 1, .n_pop = 1, .n_push = 0, .fmt = .none_var_ref }, // [243] id 224 (short, shifted)
        .{ .name = "put_var_ref2", .size = 1, .n_pop = 1, .n_push = 0, .fmt = .none_var_ref }, // [244] id 225 (short, shifted)
        .{ .name = "put_var_ref3", .size = 1, .n_pop = 1, .n_push = 0, .fmt = .none_var_ref }, // [245] id 226 (short, shifted)
        .{ .name = "set_var_ref0", .size = 1, .n_pop = 1, .n_push = 1, .fmt = .none_var_ref }, // [246] id 227 (short, shifted)
        .{ .name = "set_var_ref1", .size = 1, .n_pop = 1, .n_push = 1, .fmt = .none_var_ref }, // [247] id 228 (short, shifted)
        .{ .name = "set_var_ref2", .size = 1, .n_pop = 1, .n_push = 1, .fmt = .none_var_ref }, // [248] id 229 (short, shifted)
        .{ .name = "set_var_ref3", .size = 1, .n_pop = 1, .n_push = 1, .fmt = .none_var_ref }, // [249] id 230 (short, shifted)
        .{ .name = "get_length", .size = 1, .n_pop = 1, .n_push = 1, .fmt = .none }, // [250] id 231 (short, shifted)
        .{ .name = "if_false8", .size = 2, .n_pop = 1, .n_push = 0, .fmt = .label8 }, // [251] id 232 (short, shifted)
        .{ .name = "if_true8", .size = 2, .n_pop = 1, .n_push = 0, .fmt = .label8 }, // [252] id 233 (short, shifted)
        .{ .name = "goto8", .size = 2, .n_pop = 0, .n_push = 0, .fmt = .label8 }, // [253] id 234 (short, shifted)
        .{ .name = "goto16", .size = 3, .n_pop = 0, .n_push = 0, .fmt = .label16 }, // [254] id 235 (short, shifted)
        .{ .name = "call0", .size = 1, .n_pop = 1, .n_push = 1, .fmt = .npopx }, // [255] id 236 (short, shifted)
        .{ .name = "call1", .size = 1, .n_pop = 1, .n_push = 1, .fmt = .npopx }, // [256] id 237 (short, shifted)
        .{ .name = "call2", .size = 1, .n_pop = 1, .n_push = 1, .fmt = .npopx }, // [257] id 238 (short, shifted)
        .{ .name = "call3", .size = 1, .n_pop = 1, .n_push = 1, .fmt = .npopx }, // [258] id 239 (short, shifted)
        .{ .name = "is_undefined", .size = 1, .n_pop = 1, .n_push = 1, .fmt = .none }, // [259] id 240 (short, shifted)
        .{ .name = "is_null", .size = 1, .n_pop = 1, .n_push = 1, .fmt = .none }, // [260] id 241 (short, shifted)
        .{ .name = "typeof_is_undefined", .size = 1, .n_pop = 1, .n_push = 1, .fmt = .none }, // [261] id 242 (short, shifted)
        .{ .name = "typeof_is_function", .size = 1, .n_pop = 1, .n_push = 1, .fmt = .none }, // [262] id 243 (short, shifted)
    };

    pub const Kind = enum {
        normal,
        temp,
        short,
    };

    pub const Metadata = struct {
        index: u16,
        name: []const u8,
        size: u8,
        n_pop: u8,
        n_push: u8,
        format: Format,
        kind: Kind,

        pub fn stackDelta(self: Metadata) i16 {
            return @as(i16, self.n_push) - @as(i16, self.n_pop);
        }
    };

    pub const special_object_subtype = struct {
        pub const arguments: u8 = 0;
        pub const mapped_arguments: u8 = 1;
        pub const current_function: u8 = 2;
        pub const new_target: u8 = 3;
        pub const home_object_or_import_meta: u8 = 4;
        // QuickJS reserves 5..7 for var object, import.meta, and null-proto.
        pub const dstr_get: u8 = 8;
        pub const dstr_elide: u8 = 9;
        pub const dstr_rest: u8 = 10;
        pub const dstr_obj_rest: u8 = 11;
        pub const dstr_close: u8 = 12;
        pub const dstr_require_iterator: u8 = 13;
        pub const using_create_disposable_stack: u8 = 14;
        pub const using_add_sync_resource: u8 = 15;
        pub const using_dispose_sync_stack: u8 = 16;
        pub const using_dispose_sync_stack_for_throw: u8 = 17;
        pub const using_create_async_disposable_stack: u8 = 18;
        pub const using_add_async_resource: u8 = 19;
        pub const using_dispose_async_stack: u8 = 20;
        pub const using_dispose_async_stack_for_throw: u8 = 21;
    };

    /// Final-view lookup, for bytecode after `resolve_labels`: ids in the
    /// temp/short overlap range (op_temp_start..op_temp_end-1) resolve to
    /// the SHORT opcode entry, stored `op.op_temp_count` slots past the
    /// id. Mirrors QuickJS `short_opcode_info` (quickjs.c:21842). Returns
    /// null for ids no opcode claims (op.op_count..255).
    fn finalInfo(op_id: u8) ?*const Info {
        if (op_id >= op.op_count) return null;
        const index: usize = if (op_id >= op.op_temp_start)
            @as(usize, op_id) + op.op_temp_count
        else
            op_id;
        return &opcode_info[index];
    }

    /// Phase-1-view lookup, for parser-emitted streams before
    /// `resolve_labels`: ids in the temp/short overlap range resolve to
    /// the TEMP opcode entry at its id position. Mirrors QuickJS's bare
    /// `opcode_info[op]` indexing (quickjs.c:21826). zjs deviation: the
    /// parser also emits some final-form opcodes above the overlap range
    /// in phase 1 (`get_length`, `if_false8`, `is_undefined`, ...), so
    /// ids outside the overlap fall through to the final view (the two
    /// views agree everywhere but the overlap).
    ///
    /// Caveat: id 192 is genuinely ambiguous in phase-1 streams — the
    /// parser emits both `push_empty_string` (short form, 1 byte) and
    /// `scope_in_private_field` (temp, 7 bytes). This view reports the
    /// temp entry; scanners that may encounter both must disambiguate
    /// from context or bail out.
    fn phase1Info(op_id: u8) ?*const Info {
        if (op_id >= op.op_temp_start and op_id < op.op_temp_end)
            return &opcode_info[op_id];
        return finalInfo(op_id);
    }

    /// Total byte length (opcode + operands) in final-form bytecode, or 0
    /// if no opcode claims that id.
    pub fn sizeOf(op_id: u8) u8 {
        return if (finalInfo(op_id)) |info| info.size else 0;
    }

    /// Total byte length (opcode + operands) in phase-1 streams (temp
    /// opcodes take the overlap range), or 0 if no opcode claims that id.
    pub fn sizeOfPhase1(op_id: u8) u8 {
        return if (phase1Info(op_id)) |info| info.size else 0;
    }

    /// Operand format in final-form bytecode (short forms in the overlap
    /// range).
    pub fn formatOf(op_id: u8) Format {
        return if (finalInfo(op_id)) |info| info.fmt else .none;
    }

    /// Operand format in phase-1 streams (temp forms in the overlap
    /// range).
    pub fn formatOfPhase1(op_id: u8) Format {
        return if (phase1Info(op_id)) |info| info.fmt else .none;
    }

    /// Opcode name in final-form bytecode, or "" if no opcode claims that
    /// id.
    pub fn nameOf(op_id: u8) []const u8 {
        return if (finalInfo(op_id)) |info| info.name else "";
    }

    /// Opcode name in phase-1 streams (temp names in the overlap range).
    pub fn nameOfPhase1(op_id: u8) []const u8 {
        return if (phase1Info(op_id)) |info| info.name else "";
    }

    /// Stack pop count in final-form bytecode.
    pub fn nPopOf(op_id: u8) u8 {
        return if (finalInfo(op_id)) |info| info.n_pop else 0;
    }

    /// Stack pop count in phase-1 streams.
    pub fn nPopOfPhase1(op_id: u8) u8 {
        return if (phase1Info(op_id)) |info| info.n_pop else 0;
    }

    /// Stack push count in final-form bytecode.
    pub fn nPushOf(op_id: u8) u8 {
        return if (finalInfo(op_id)) |info| info.n_push else 0;
    }

    /// Stack push count in phase-1 streams.
    pub fn nPushOfPhase1(op_id: u8) u8 {
        return if (phase1Info(op_id)) |info| info.n_push else 0;
    }

    test "opcode metadata exposes size format and stack effects" {
        try std.testing.expectEqual(@as(u8, 5), sizeOf(op.push_i32));
        try std.testing.expectEqual(Format.i32, formatOf(op.push_i32));
        try std.testing.expectEqual(@as(u8, 0), nPopOf(op.push_i32));
        try std.testing.expectEqual(@as(u8, 1), nPushOf(op.push_i32));

        try std.testing.expectEqual(Format.npop, formatOf(op.call));
        try std.testing.expectEqual(@as(u8, 3), sizeOf(op.call));
        try std.testing.expectEqual(@as(u8, 1), nPopOf(op.call));
        try std.testing.expectEqual(@as(u8, 1), nPushOf(op.call));

        try std.testing.expectEqual(Format.label, formatOf(op.goto));
        try std.testing.expectEqual(@as(u8, 5), sizeOf(op.goto));

        try std.testing.expectEqual(Format.none_int, formatOf(op.push_0));
        try std.testing.expectEqual(@as(u8, 1), sizeOf(op.push_0));
    }

    test "final view resolves short forms in the temp overlap range" {
        // push_minus1..push_7 share ids with enter_scope..scope_get_ref.
        try std.testing.expectEqual(@as(u8, 1), sizeOf(op.push_minus1));
        try std.testing.expectEqualStrings("push_minus1", nameOf(op.push_minus1));
        try std.testing.expectEqual(@as(u8, 2), sizeOf(op.push_i8));
        try std.testing.expectEqual(@as(u8, 3), sizeOf(op.push_i16));
        try std.testing.expectEqual(@as(u8, 2), sizeOf(op.fclosure8));
        try std.testing.expectEqual(@as(u8, 2), sizeOf(op.get_loc8));
        try std.testing.expectEqual(Format.loc8, formatOf(op.set_loc8));
        // Unclaimed ids report no entry.
        try std.testing.expectEqual(@as(u8, 0), sizeOf(255));
        try std.testing.expectEqualStrings("", nameOf(255));
    }

    test "phase-1 view resolves temp forms in the overlap range" {
        try std.testing.expectEqual(@as(u8, 3), sizeOfPhase1(op.enter_scope));
        try std.testing.expectEqual(@as(u8, 3), sizeOfPhase1(op.leave_scope));
        try std.testing.expectEqual(@as(u8, 5), sizeOfPhase1(op.label));
        try std.testing.expectEqual(@as(u8, 7), sizeOfPhase1(op.scope_get_var));
        try std.testing.expectEqual(@as(u8, 7), sizeOfPhase1(op.scope_put_var_init));
        try std.testing.expectEqual(@as(u8, 11), sizeOfPhase1(op.scope_make_ref));
        try std.testing.expectEqual(@as(u8, 7), sizeOfPhase1(op.scope_in_private_field));
        try std.testing.expectEqual(@as(u8, 5), sizeOfPhase1(op.get_field_opt_chain));
        try std.testing.expectEqual(@as(u8, 5), sizeOfPhase1(op.line_num));
        try std.testing.expectEqualStrings("scope_get_var", nameOfPhase1(op.scope_get_var));
        try std.testing.expectEqual(Format.atom_u16, formatOfPhase1(op.scope_get_var));
        try std.testing.expectEqual(Format.atom_label_u16, formatOfPhase1(op.scope_make_ref));
        // Outside the overlap range the two views agree; the parser emits
        // some final-form opcodes (and normal ones) in phase 1 too.
        try std.testing.expectEqual(@as(u8, 5), sizeOfPhase1(op.push_bigint_i32));
        try std.testing.expectEqual(@as(u8, 5), sizeOfPhase1(op.eval));
        try std.testing.expectEqual(@as(u8, 3), sizeOfPhase1(op.apply_eval));
        try std.testing.expectEqual(@as(u8, 10), sizeOfPhase1(op.with_get_var));
        try std.testing.expectEqual(sizeOf(op.get_length), sizeOfPhase1(op.get_length));
        try std.testing.expectEqual(sizeOf(op.if_false8), sizeOfPhase1(op.if_false8));
        try std.testing.expectEqual(sizeOf(op.is_undefined), sizeOfPhase1(op.is_undefined));
    }

    test "QuickJS opcode table has no host print opcode names" {
        inline for (@typeInfo(op).@"struct".decls) |decl| {
            try std.testing.expect(!std.mem.eql(u8, decl.name, "host_print"));
            try std.testing.expect(!std.mem.eql(u8, decl.name, "host_print_n"));
        }
    }
};

pub const format = struct {
    pub const Operand = enum {
        none,
        u8,
        i8,
        u16,
        i16,
        u32,
        i32,
        atom,
        constant,
        label,
        local,
        argument,
        var_ref,
        npop,
    };

    pub const Description = struct {
        operands: []const Operand,

        pub fn immediateSize(self: Description) usize {
            var total: usize = 0;
            for (self.operands) |operand| total += operandSize(operand);
            return total;
        }
    };

    pub fn describe(fmt: opcode.Format) Description {
        return switch (fmt) {
            .none, .none_int, .none_loc, .none_arg, .none_var_ref => .{ .operands = &.{} },
            .u8 => .{ .operands = &.{.u8} },
            .i8 => .{ .operands = &.{.i8} },
            .loc8 => .{ .operands = &.{.local} },
            .const8 => .{ .operands = &.{.constant} },
            .label8 => .{ .operands = &.{.label} },
            .u16 => .{ .operands = &.{.u16} },
            .i16 => .{ .operands = &.{.i16} },
            .label16 => .{ .operands = &.{.label} },
            .npop, .npopx => .{ .operands = &.{.npop} },
            .npop_u16 => .{ .operands = &.{ .npop, .u16 } },
            .loc => .{ .operands = &.{.local} },
            .arg => .{ .operands = &.{.argument} },
            .var_ref => .{ .operands = &.{.var_ref} },
            .u32 => .{ .operands = &.{.u32} },
            .i32 => .{ .operands = &.{.i32} },
            .@"const" => .{ .operands = &.{.constant} },
            .label => .{ .operands = &.{.label} },
            .atom => .{ .operands = &.{.atom} },
            .atom_u8 => .{ .operands = &.{ .atom, .u8 } },
            .atom_u16 => .{ .operands = &.{ .atom, .u16 } },
            .atom_label_u8 => .{ .operands = &.{ .atom, .label, .u8 } },
            .atom_label_u16 => .{ .operands = &.{ .atom, .label, .u16 } },
            .label_u16 => .{ .operands = &.{ .label, .u16 } },
        };
    }

    pub fn operandSize(operand: Operand) usize {
        return switch (operand) {
            .none => 0,
            .u8, .i8 => 1,
            .u16, .i16, .local, .argument, .var_ref, .npop => 2,
            .u32, .i32, .atom, .constant, .label => 4,
        };
    }

    test "format metadata computes immediate operand widths" {
        const std = @import("std");
        try std.testing.expectEqual(@as(usize, 0), describe(.none).immediateSize());
        try std.testing.expectEqual(@as(usize, 4), describe(.i32).immediateSize());
        try std.testing.expectEqual(@as(usize, 5), describe(.atom_u8).immediateSize());
        try std.testing.expectEqual(@as(usize, 10), describe(.atom_label_u16).immediateSize());
    }
};

pub const constant = struct {
    const memory = @import("core/memory.zig");
    const atom = @import("core/atom.zig");
    const JSValue = @import("core/value.zig").JSValue;

    fn dupOwnedValue(atoms: *atom.AtomTable, value: JSValue) JSValue {
        _ = atoms;
        return value.dup();
    }

    fn takeOwnedValue(atoms: *atom.AtomTable, value: JSValue) JSValue {
        _ = atoms;
        return value;
    }

    fn freeOwnedValue(atoms: *atom.AtomTable, value: JSValue, rt: anytype) void {
        _ = atoms;
        value.free(rt);
    }

    pub const Pool = struct {
        memory: *memory.MemoryAccount,
        atoms: *atom.AtomTable,
        values: []JSValue = &.{},

        pub fn init(account: *memory.MemoryAccount, atoms: *atom.AtomTable) Pool {
            return .{ .memory = account, .atoms = atoms };
        }

        pub fn deinit(self: *Pool, rt: anytype) void {
            const values = self.values;
            self.values = &.{};
            for (values) |*slot| {
                const value = slot.*;
                slot.* = JSValue.undefinedValue();
                freeOwnedValue(self.atoms, value, rt);
            }
            if (values.len != 0) self.memory.free(JSValue, values);
        }

        pub fn append(self: *Pool, value: JSValue) !u32 {
            const old_values = self.values;
            const next = try self.memory.alloc(JSValue, self.values.len + 1);
            errdefer self.memory.free(JSValue, next);
            @memcpy(next[0..old_values.len], old_values);
            next[old_values.len] = dupOwnedValue(self.atoms, value);
            self.values = next;
            if (old_values.len != 0) self.memory.free(JSValue, old_values);
            return @intCast(self.values.len - 1);
        }

        pub fn appendOwned(self: *Pool, value: JSValue) !u32 {
            const old_values = self.values;
            const next = try self.memory.alloc(JSValue, self.values.len + 1);
            errdefer self.memory.free(JSValue, next);
            @memcpy(next[0..old_values.len], old_values);
            next[old_values.len] = takeOwnedValue(self.atoms, value);
            self.values = next;
            if (old_values.len != 0) self.memory.free(JSValue, old_values);
            return @intCast(self.values.len - 1);
        }

        pub fn get(self: Pool, index: usize) ?JSValue {
            if (index >= self.values.len) return null;
            return self.values[index].dup();
        }
    };
};

pub const debug = struct {
    const atom = @import("core/atom.zig");
    const memory = @import("core/memory.zig");

    pub const SourcePosition = struct {
        pc: u32,
        line: u32,
        column: u32 = 0,
    };

    pub const Table = struct {
        memory: *memory.MemoryAccount,
        atoms: *atom.AtomTable,
        filename: atom.Atom = atom.null_atom,
        positions: []SourcePosition = &.{},

        pub fn init(account: *memory.MemoryAccount, atoms: *atom.AtomTable, filename: atom.Atom) Table {
            return .{
                .memory = account,
                .atoms = atoms,
                .filename = atoms.dup(filename),
            };
        }

        pub fn deinit(self: *Table) void {
            const filename = self.filename;
            const positions = self.positions;
            self.filename = atom.null_atom;
            self.positions = &.{};
            if (filename != atom.null_atom) self.atoms.free(filename);
            if (positions.len != 0) self.memory.free(SourcePosition, positions);
        }

        pub fn add(self: *Table, position: SourcePosition) !void {
            const old_positions = self.positions;
            const next = try self.memory.alloc(SourcePosition, self.positions.len + 1);
            errdefer self.memory.free(SourcePosition, next);
            @memcpy(next[0..old_positions.len], old_positions);
            next[old_positions.len] = position;
            self.positions = next;
            if (old_positions.len != 0) self.memory.free(SourcePosition, old_positions);
        }

        pub fn lineForPc(self: Table, pc: u32) ?u32 {
            var best: ?SourcePosition = null;
            for (self.positions) |position| {
                if (position.pc <= pc and (best == null or position.pc >= best.?.pc)) best = position;
            }
            return if (best) |position| position.line else null;
        }
    };
};

pub const module = struct {
    const atom = @import("core/atom.zig");
    const memory = @import("core/memory.zig");

    pub const Request = struct {
        module_name: atom.Atom,
    };

    pub const Import = struct {
        request_index: u32,
        import_name: atom.Atom,
        local_name: atom.Atom,
    };

    pub const Export = struct {
        export_name: atom.Atom,
        local_name: atom.Atom,
    };

    pub const IndirectExport = struct {
        request_index: u32,
        export_name: atom.Atom,
        import_name: atom.Atom,
    };

    pub const StarExport = struct {
        request_index: u32,
        export_name: atom.Atom,
    };

    pub const ImportAttribute = struct {
        request_index: u32,
        key: atom.Atom,
        value: atom.Atom,
    };

    pub const Record = struct {
        memory: *memory.MemoryAccount,
        atoms: *atom.AtomTable,
        requests: []Request = &.{},
        imports: []Import = &.{},
        exports: []Export = &.{},
        indirect_exports: []IndirectExport = &.{},
        star_exports: []StarExport = &.{},
        import_attributes: []ImportAttribute = &.{},
        has_top_level_await: bool = false,

        pub fn init(account: *memory.MemoryAccount, atoms: *atom.AtomTable) Record {
            return .{ .memory = account, .atoms = atoms };
        }

        pub fn deinit(self: *Record) void {
            const requests = self.requests;
            const imports = self.imports;
            const exports = self.exports;
            const indirect_exports = self.indirect_exports;
            const star_exports = self.star_exports;
            const import_attributes = self.import_attributes;
            self.requests = &.{};
            self.imports = &.{};
            self.exports = &.{};
            self.indirect_exports = &.{};
            self.star_exports = &.{};
            self.import_attributes = &.{};
            self.has_top_level_await = false;

            for (requests) |request| self.atoms.free(request.module_name);
            for (imports) |entry| {
                self.atoms.free(entry.import_name);
                self.atoms.free(entry.local_name);
            }
            for (exports) |entry| {
                self.atoms.free(entry.export_name);
                self.atoms.free(entry.local_name);
            }
            for (indirect_exports) |entry| {
                self.atoms.free(entry.export_name);
                self.atoms.free(entry.import_name);
            }
            for (star_exports) |entry| self.atoms.free(entry.export_name);
            for (import_attributes) |entry| {
                self.atoms.free(entry.key);
                self.atoms.free(entry.value);
            }
            if (requests.len != 0) self.memory.free(Request, requests);
            if (imports.len != 0) self.memory.free(Import, imports);
            if (exports.len != 0) self.memory.free(Export, exports);
            if (indirect_exports.len != 0) self.memory.free(IndirectExport, indirect_exports);
            if (star_exports.len != 0) self.memory.free(StarExport, star_exports);
            if (import_attributes.len != 0) self.memory.free(ImportAttribute, import_attributes);
        }

        pub fn addRequest(self: *Record, module_name: atom.Atom) !u32 {
            const index = self.requests.len;
            const owned_module_name = self.atoms.dup(module_name);
            errdefer self.atoms.free(owned_module_name);
            try append(self.memory, Request, &self.requests, .{ .module_name = owned_module_name });
            return @intCast(index);
        }

        pub fn addImport(self: *Record, request_index: u32, import_name: atom.Atom, local_name: atom.Atom) !void {
            const owned_import_name = self.atoms.dup(import_name);
            errdefer self.atoms.free(owned_import_name);
            const owned_local_name = self.atoms.dup(local_name);
            errdefer self.atoms.free(owned_local_name);
            try append(self.memory, Import, &self.imports, .{
                .request_index = request_index,
                .import_name = owned_import_name,
                .local_name = owned_local_name,
            });
        }

        pub fn addExport(self: *Record, export_name: atom.Atom, local_name: atom.Atom) !void {
            const owned_export_name = self.atoms.dup(export_name);
            errdefer self.atoms.free(owned_export_name);
            const owned_local_name = self.atoms.dup(local_name);
            errdefer self.atoms.free(owned_local_name);
            try append(self.memory, Export, &self.exports, .{
                .export_name = owned_export_name,
                .local_name = owned_local_name,
            });
        }

        pub fn addIndirectExport(self: *Record, request_index: u32, export_name: atom.Atom, import_name: atom.Atom) !void {
            const owned_export_name = self.atoms.dup(export_name);
            errdefer self.atoms.free(owned_export_name);
            const owned_import_name = self.atoms.dup(import_name);
            errdefer self.atoms.free(owned_import_name);
            try append(self.memory, IndirectExport, &self.indirect_exports, .{
                .request_index = request_index,
                .export_name = owned_export_name,
                .import_name = owned_import_name,
            });
        }

        pub fn addStarExport(self: *Record, request_index: u32, export_name: atom.Atom) !void {
            const owned_export_name = self.atoms.dup(export_name);
            errdefer self.atoms.free(owned_export_name);
            try append(self.memory, StarExport, &self.star_exports, .{
                .request_index = request_index,
                .export_name = owned_export_name,
            });
        }

        pub fn addImportAttribute(self: *Record, request_index: u32, key: atom.Atom, value: atom.Atom) !void {
            const owned_key = self.atoms.dup(key);
            errdefer self.atoms.free(owned_key);
            const owned_value = self.atoms.dup(value);
            errdefer self.atoms.free(owned_value);
            try append(self.memory, ImportAttribute, &self.import_attributes, .{
                .request_index = request_index,
                .key = owned_key,
                .value = owned_value,
            });
        }
    };

    fn append(account: *memory.MemoryAccount, comptime T: type, slice: *[]T, item: T) !void {
        const next = try account.alloc(T, slice.*.len + 1);
        errdefer account.free(T, next);
        @memcpy(next[0..slice.*.len], slice.*);
        next[slice.*.len] = item;
        const old = slice.*;
        slice.* = next;
        if (old.len != 0) account.free(T, old);
    }
};

pub const function_bytecode = struct {
    const std = @import("std");

    const atom = @import("core/atom.zig");
    const gc = @import("core/gc.zig");
    const memory = @import("core/memory.zig");
    const runtime = @import("core/runtime.zig");
    const shape = @import("core/shape.zig");
    const JSValue = @import("core/value.zig").JSValue;

    /// Mirrors `JSFunctionKindEnum` (`quickjs.c:761`).
    pub const FunctionKind = enum(u2) {
        normal = 0,
        generator = 1 << 0,
        async = 1 << 1,
        async_generator = 3, // generator | async
    };

    /// Mirrors `JSClosureTypeEnum` (`quickjs.c:675`).
    pub const ClosureType = enum(u3) {
        local, // 'var_idx' is the index of a local variable in the parent function
        arg, // 'var_idx' is the index of an argument variable in the parent function
        ref, // 'var_idx' is the index of a closure variable in the parent function
        global_ref, // 'var_idx' is the index of a closure variable referencing a global variable
        global_decl, // global variable declaration (eval code only)
        global, // global variable (eval code only)
        module_decl, // definition of a module variable (eval code only)
        module_import, // definition of a module import (eval code only)
    };

    /// Mirrors `JSVarKindEnum` (`quickjs.c:707`).
    pub const VarKind = enum(u4) {
        normal,
        function_decl, // lexical var with function declaration
        new_function_decl, // lexical var with async/generator function declaration
        catch_,
        function_name, // function expression name
        private_field,
        private_method,
        private_getter,
        private_setter,
        private_getter_setter,
    };

    /// Mirrors `JSVarDef` (`quickjs.c:724`).
    pub const VarDef = struct {
        var_name: atom.Atom,
        scope_level: i32, // index into scopes of this variable lexical scope
        scope_next: i32 = -1, // index into vars of the next variable in the same or enclosing lexical scope
        is_lexical: bool = false,
        is_const: bool = false,
        is_captured: bool = false,
        tdz_emitted_at_decl: bool = false,
        var_kind: VarKind = .normal,
    };

    /// Mirrors `JSClosureVar` (`quickjs.c:687`).
    pub const ClosureVar = struct {
        closure_type: ClosureType,
        is_lexical: bool = false,
        is_const: bool = false,
        var_kind: VarKind = .normal,
        var_idx: u16, // index to a normal variable of the parent function, or index to a closure variable
        var_name: atom.Atom,
    };

    /// Mirrors `JSGlobalVar` (`quickjs.c:713`).
    pub const GlobalVar = struct {
        cpool_idx: i32,
        force_init: bool = false,
        is_configurable: bool = false,
        is_lexical: bool = false,
        is_const: bool = false,
        scope_level: i32,
        var_name: atom.Atom,
    };

    pub const CallSiteKind = enum(u8) {
        prop_atom,
    };

    pub const CallSite = struct {
        kind: CallSiteKind = .prop_atom,
        atom_id: atom.Atom,
        prepare_pc: u32,
        call_pc: u32,
        ic_slot_index: usize = std.math.maxInt(usize),
    };

    /// Mirrors `JSFunctionBytecode` (`quickjs.c:768-804`).
    ///
    /// This is the final compiled bytecode structure produced by the
    /// js_create_function equivalent. It contains the fully processed bytecode
    /// after all bytecode pipeline phases. Core owns this GC object so runtime,
    /// object graph cleanup, and tracing can operate without depending on the
    /// bytecode compile-time module.
    ///
    /// Field order matches QuickJS exactly for strong alignment (§1.5.3).
    ///
    /// Storage layout: the finalize pipeline packs every read-only artifact
    /// slice (byte_code, cpool, atom tables, vardefs, pc2line, source, ...)
    /// into a single `block` allocation; the slice fields then point inside
    /// that block (see `BlockBuilder`). Fixtures that populate the fields with
    /// individual allocations leave `block` empty, and `deinit` falls back to
    /// the legacy per-slice frees.
    pub const FunctionBytecodeImpl = struct {
        pub const gc_kind_tag: u8 = @intFromEnum(gc.GcKind.function_bytecode);
        comptime {
            // align(16) forces this many-pointer-field struct to keep header at
            // offset 0 (Zig would otherwise reorder it deep into the struct).
            std.debug.assert(@offsetOf(@This(), "header") == 0);
        }
        header: gc.GCObjectHeader align(16),
        memory: *memory.MemoryAccount,
        atoms: *atom.AtomTable,

        /// Consolidated storage for the read-only slices below. Empty when the
        /// fields were populated with individual allocations (fixture path).
        block: []u8 = &.{},

        // Flags (mirrors JSFunctionBytecode packed fields, same order as quickjs.c:770-782)
        is_strict_mode: bool = false,
        runtime_strict_mode: bool = false,
        has_prototype: bool = false,
        has_simple_parameter_list: bool = true,
        is_class_constructor: bool = false,
        is_derived_class_constructor: bool = false,
        need_home_object: bool = false,
        func_kind: FunctionKind = .normal,
        is_arrow_function: bool = false,
        new_target_allowed: bool = false,
        super_call_allowed: bool = false,
        super_allowed: bool = false,
        arguments_allowed: bool = false,
        backtrace_barrier: bool = false,
        is_indirect_eval: bool = false,
        has_eval_call: bool = false,

        // Bytecode (quickjs.c:783-784)
        byte_code: []u8 = &.{},
        byte_code_len: i32 = 0,
        generator_body_pc: usize = 0,
        atom_operands: []atom.Atom = &.{},
        arg_names: []atom.Atom = &.{},
        var_names: []atom.Atom = &.{},
        var_is_lexical: []bool = &.{},
        var_is_const: []bool = &.{},
        // Lexical scope level per local slot (parallels var_is_lexical). Distinguishes
        // a top-level (scope_level == 0) lexical from a block-level shadower.
        var_scope_level: []i32 = &.{},
        var_ref_names: []atom.Atom = &.{},
        var_ref_is_lexical: []bool = &.{},
        var_ref_is_const: []bool = &.{},
        var_ref_is_global_decl: []bool = &.{},
        global_var_names: []atom.Atom = &.{},
        global_vars: []GlobalVar = &.{},

        // Metadata (quickjs.c:785-792)
        func_name: atom.Atom,
        vardefs: []VarDef = &.{},
        closure_var: []ClosureVar = &.{},
        class_instance_fields: []atom.Atom = &.{},
        private_bound_names: []atom.Atom = &.{},
        class_private_names: []atom.Atom = &.{},
        class_fields_init: ?JSValue = null,
        arg_count: u16 = 0,
        var_count: u16 = 0,
        defined_arg_count: u16 = 0,
        stack_size: u16 = 0,
        var_ref_count: u16 = 0,
        closure_var_count: u16 = 0,
        cpool_count: i32 = 0,
        call_sites: []CallSite = &.{},

        /// Cached execution view used by the VM call machinery. QuickJS keeps a
        /// direct `JSFunctionBytecode *` on function objects and dispatches from
        /// that pointer; zjs still exposes the older `bytecode.Bytecode` execution
        /// API, so finalized bytecode stores one borrowed view and the VM passes a
        /// pointer to it instead of rebuilding the view per call.
        execution_view: ?*anyopaque = null,
        execution_view_owned: bool = false,
        execution_view_heap_size: usize = 0,
        execution_view_destroy: ?*const fn (*memory.MemoryAccount, *anyopaque) void = null,

        // Note: QuickJS has 'realm' field (JSContext *) here; Zig version
        // tracks this differently via the runtime context.

        // Constant pool (contains child Function objects) (quickjs.c:796)
        cpool: []JSValue = &.{},

        // Source location (quickjs.c:797-803)
        filename: atom.Atom,
        line_num: i32 = 0,
        col_num: i32 = 0,
        source_len: i32 = 0,
        pc2line_len: i32 = 0,
        pc2line_buf: []u8 = &.{},
        source: ?[]const u8 = null,

        pub fn init(account: *memory.MemoryAccount, atoms: *atom.AtomTable, name: atom.Atom) FunctionBytecodeImpl {
            return .{
                .header = .{},
                .memory = account,
                .atoms = atoms,
                .func_name = atoms.dup(name),
                .filename = atoms.dup(name),
            };
        }

        pub fn deinit(self: *FunctionBytecodeImpl, rt: anytype) void {
            // When `block` owns the storage the per-slice frees are skipped;
            // only the per-element atom/value references are released and the
            // block is freed once at the end.
            const owned = self.block.len == 0;

            const execution_view = self.execution_view;
            const execution_view_owned = self.execution_view_owned;
            const execution_view_destroy = self.execution_view_destroy;
            self.execution_view = null;
            self.execution_view_owned = false;
            self.execution_view_heap_size = 0;
            self.execution_view_destroy = null;
            if (execution_view_owned) {
                if (execution_view_destroy) |destroy| {
                    if (execution_view) |ptr| destroy(self.memory, ptr);
                }
            }

            const func_name = self.func_name;
            const filename = self.filename;
            self.func_name = atom.null_atom;
            self.filename = atom.null_atom;
            self.atoms.free(func_name);
            self.atoms.free(filename);

            const byte_code = self.byte_code;
            self.byte_code = &.{};
            self.byte_code_len = 0;
            if (owned and byte_code.len != 0) self.memory.free(u8, byte_code);
            releaseAtomSlice(self.atoms, self.memory, &self.atom_operands, owned);
            releaseAtomSlice(self.atoms, self.memory, &self.arg_names, owned);
            releaseAtomSlice(self.atoms, self.memory, &self.var_names, owned);
            releaseSlice(bool, self.memory, &self.var_is_lexical, owned);
            releaseSlice(bool, self.memory, &self.var_is_const, owned);
            releaseSlice(i32, self.memory, &self.var_scope_level, owned);
            releaseAtomSlice(self.atoms, self.memory, &self.var_ref_names, owned);
            releaseSlice(bool, self.memory, &self.var_ref_is_lexical, owned);
            releaseSlice(bool, self.memory, &self.var_ref_is_const, owned);
            releaseSlice(bool, self.memory, &self.var_ref_is_global_decl, owned);
            releaseAtomSlice(self.atoms, self.memory, &self.global_var_names, owned);

            const global_vars = self.global_vars;
            self.global_vars = &.{};
            for (global_vars) |*gv| self.atoms.free(gv.var_name);
            if (owned and global_vars.len != 0) self.memory.free(GlobalVar, global_vars);

            const vardefs = self.vardefs;
            self.vardefs = &.{};
            for (vardefs) |*v| self.atoms.free(v.var_name);
            if (owned and vardefs.len != 0) self.memory.free(VarDef, vardefs);

            const closure_var = self.closure_var;
            self.closure_var = &.{};
            for (closure_var) |*cv| self.atoms.free(cv.var_name);
            if (owned and closure_var.len != 0) self.memory.free(ClosureVar, closure_var);

            releaseAtomSlice(self.atoms, self.memory, &self.class_instance_fields, owned);
            releaseAtomSlice(self.atoms, self.memory, &self.private_bound_names, owned);
            releaseAtomSlice(self.atoms, self.memory, &self.class_private_names, owned);
            const class_fields_init = self.class_fields_init;
            self.class_fields_init = null;
            if (class_fields_init) |stored| stored.free(rt);

            const cpool = self.cpool;
            self.cpool = &.{};
            for (cpool) |*slot| {
                const value = slot.*;
                slot.* = JSValue.undefinedValue();
                value.free(rt);
            }
            if (owned and cpool.len != 0) self.memory.free(JSValue, cpool);

            const pc2line_buf = self.pc2line_buf;
            self.pc2line_buf = &.{};
            self.pc2line_len = 0;
            if (owned and pc2line_buf.len != 0) self.memory.free(u8, pc2line_buf);

            releaseCallSites(self.atoms, self.memory, &self.call_sites, owned);
            if (self.source) |src| {
                self.source = null;
                if (owned) self.memory.free(u8, @constCast(src));
            }
            self.source_len = 0;

            self.class_fields_init = null;
            self.cpool = &.{};

            const block = self.block;
            self.block = &.{};
            if (block.len != 0) self.memory.freeAlignedBytes(block, block_alignment);
        }

        pub fn heapByteSize(self: *const FunctionBytecodeImpl) usize {
            var bytes: usize = @sizeOf(FunctionBytecodeImpl);
            bytes = addSaturating(bytes, self.execution_view_heap_size);
            if (self.block.len != 0) return addSaturating(bytes, self.block.len);
            bytes = addSliceBytes(bytes, u8, self.byte_code.len);
            bytes = addSliceBytes(bytes, atom.Atom, self.atom_operands.len);
            bytes = addSliceBytes(bytes, atom.Atom, self.arg_names.len);
            bytes = addSliceBytes(bytes, atom.Atom, self.var_names.len);
            bytes = addSliceBytes(bytes, bool, self.var_is_lexical.len);
            bytes = addSliceBytes(bytes, bool, self.var_is_const.len);
            bytes = addSliceBytes(bytes, i32, self.var_scope_level.len);
            bytes = addSliceBytes(bytes, atom.Atom, self.var_ref_names.len);
            bytes = addSliceBytes(bytes, bool, self.var_ref_is_lexical.len);
            bytes = addSliceBytes(bytes, bool, self.var_ref_is_const.len);
            bytes = addSliceBytes(bytes, bool, self.var_ref_is_global_decl.len);
            bytes = addSliceBytes(bytes, atom.Atom, self.global_var_names.len);
            bytes = addSliceBytes(bytes, GlobalVar, self.global_vars.len);
            bytes = addSliceBytes(bytes, VarDef, self.vardefs.len);
            bytes = addSliceBytes(bytes, ClosureVar, self.closure_var.len);
            bytes = addSliceBytes(bytes, atom.Atom, self.class_instance_fields.len);
            bytes = addSliceBytes(bytes, atom.Atom, self.private_bound_names.len);
            bytes = addSliceBytes(bytes, atom.Atom, self.class_private_names.len);
            bytes = addSliceBytes(bytes, JSValue, self.cpool.len);
            bytes = addSliceBytes(bytes, u8, self.pc2line_buf.len);
            bytes = addSliceBytes(bytes, CallSite, self.call_sites.len);
            if (self.source) |source| bytes = addSaturating(bytes, source.len);
            return bytes;
        }

    };

    /// Alignment of the consolidated `FunctionBytecodeImpl.block` allocation. Must
    /// cover the widest element type packed into the block.
    pub const block_alignment: std.mem.Alignment = .fromByteUnits(@max(
        @alignOf(JSValue),
        @alignOf(CallSite),
        @alignOf(VarDef),
        @alignOf(ClosureVar),
        @alignOf(atom.Atom),
    ));

    /// Computes the offsets/total size of the consolidated storage block.
    /// Callers reserve segments (largest alignment first keeps padding minimal)
    /// and then materialize them with `blockSlice` after a single allocation.
    pub const BlockBuilder = struct {
        size: usize = 0,

        pub fn reserve(self: *BlockBuilder, comptime T: type, len: usize) usize {
            const offset = std.mem.alignForward(usize, self.size, @alignOf(T));
            self.size = offset + len * @sizeOf(T);
            return offset;
        }
    };

    /// Reinterpret a segment of a `block_alignment`-aligned block as a typed
    /// slice. `offset` must come from `BlockBuilder.reserve` with the same `T`.
    pub fn blockSlice(block: []u8, comptime T: type, offset: usize, len: usize) []T {
        if (len == 0) return &.{};
        std.debug.assert(offset + len * @sizeOf(T) <= block.len);
        const ptr: [*]T = @ptrCast(@alignCast(block.ptr + offset));
        return ptr[0..len];
    }

    fn releaseAtomSlice(atoms: *atom.AtomTable, mem: *memory.MemoryAccount, slot: *[]atom.Atom, owned: bool) void {
        const items = slot.*;
        slot.* = &.{};
        for (items) |atom_id| atoms.free(atom_id);
        if (owned and items.len != 0) mem.free(atom.Atom, items);
    }

    fn releaseCallSites(atoms: *atom.AtomTable, mem: *memory.MemoryAccount, slot: *[]CallSite, owned: bool) void {
        const items = slot.*;
        slot.* = &.{};
        for (items) |site| atoms.free(site.atom_id);
        if (owned and items.len != 0) mem.free(CallSite, items);
    }

    fn releaseSlice(comptime T: type, mem: *memory.MemoryAccount, slot: *[]T, owned: bool) void {
        const items = slot.*;
        slot.* = &.{};
        if (owned and items.len != 0) mem.free(T, items);
    }

    fn addSliceBytes(total: usize, comptime T: type, len: usize) usize {
        const slice_bytes = std.math.mul(usize, @sizeOf(T), len) catch std.math.maxInt(usize);
        return addSaturating(total, slice_bytes);
    }

    fn addSaturating(a: usize, b: usize) usize {
        return std.math.add(usize, a, b) catch std.math.maxInt(usize);
    }

    pub fn destroyFunctionBytecode(header: *gc.ObjectHeader, destroy_ctx: ?*anyopaque) void {
        const rt: *runtime.JSRuntime = @ptrCast(@alignCast(destroy_ctx orelse return));
        destroyFromHeader(rt, header);
    }

    pub fn destroyFromHeader(rt: anytype, header: *gc.Header) void {
        const self: *FunctionBytecodeImpl = @alignCast(@fieldParentPtr("header", header));
        self.deinit(rt);
        rt.memory.free(FunctionBytecodeImpl, self[0..1]);
    }
    pub const FunctionBytecode = FunctionBytecodeImpl;
};

pub const function_def = struct {
    //! `FunctionDefImpl` — mirrors `JSFunctionDef` (`quickjs.c:21420`).
    //!
    //! This is the Phase 1 compilation state used by the parser to
    //! collect variable bindings, scopes, labels, and temporary bytecode.
    //! After Phase 2/Phase 3 pipeline, it's lowered to `FunctionBytecode`
    //! (`JSFunctionBytecode` at `quickjs.c:768`).

    const std = @import("std");
    const atom = @import("core/atom.zig");
    const function_bytecode_mod = function_bytecode;
    const memory = @import("core/memory.zig");
    const JSValue = @import("core/value.zig").JSValue;

    fn dupOwnedValue(atoms: *atom.AtomTable, value: JSValue) JSValue {
        _ = atoms;
        return value.dup();
    }

    fn takeOwnedValue(atoms: *atom.AtomTable, value: JSValue) JSValue {
        _ = atoms;
        return value;
    }

    fn freeOwnedValue(atoms: *atom.AtomTable, value: JSValue, rt: anytype) void {
        _ = atoms;
        value.free(rt);
    }

    pub const FunctionKind = function_bytecode_mod.FunctionKind;

    /// Mirrors `JSParseFunctionEnum` (`quickjs.c:21401`).
    pub const ParseFunctionKind = enum(u7) {
        statement,
        var_, // renamed from 'var' (reserved keyword in Zig)
        expr,
        arrow,
        getter,
        setter,
        method,
        class_static_init,
        class_constructor,
        derived_class_constructor,
    };

    pub const ClosureType = function_bytecode_mod.ClosureType;
    pub const VarKind = function_bytecode_mod.VarKind;
    pub const VarDef = function_bytecode_mod.VarDef;

    pub const DirectCallKind = enum(u8) {
        prop_atom,
    };

    pub const DirectCallSite = struct {
        kind: DirectCallKind = .prop_atom,
        prepare_pc: u32,
        call_pc: u32,
        atom_id: atom.Atom,
        argc: u16,
    };

    /// Mirrors `JSVarScope` (`quickjs.c:702`).
    pub const VarScope = struct {
        parent: i32, // index into scopes of the enclosing scope
        first: i32, // index into vars of the last variable in this scope
    };

    pub const ClosureVar = function_bytecode_mod.ClosureVar;

    pub const GlobalVar = function_bytecode_mod.GlobalVar;

    /// Mirrors `RelocEntry` (`quickjs.c:21374`).
    pub const RelocEntry = struct {
        next: ?*RelocEntry = null,
        addr: i32,
        size: i32,
        label: i32,
    };

    /// Mirrors `LabelSlot` (`quickjs.c:21387`).
    pub const LabelSlot = struct {
        ref_count: i32 = 0,
        pos: i32 = -1, // phase 1 address, -1 means not resolved yet
        pos2: i32 = -1, // phase 2 address, -1 means not resolved yet
        addr: i32 = -1, // phase 3 address, -1 means not resolved yet
        first_reloc: ?*RelocEntry = null,
    };

    /// Mirrors `JumpSlot` (`quickjs.c:21380`).
    pub const JumpSlot = struct {
        op: i32,
        size: i32,
        pos: i32,
        label: i32,
    };

    /// Generic geometric growth helper for FunctionDefImpl hot buffers.
    ///
    /// Maintains the contract that `slice.*.len` is the *used* count while the
    /// allocator-owned backing buffer is `slice.*.ptr[0..capacity.*]`. Returns a
    /// writable view of the freshly grown tail (length `n`).
    ///
    /// Each append used to do `alloc(old + n) + memcpy + free(old)`, making
    /// repeated appends O(n²). Geometric growth (capacity doubling, with an
    /// 8-element floor) reduces total cost to amortised O(1) per item.
    fn growSliceBy(
        comptime T: type,
        mem: *memory.MemoryAccount,
        slice: *[]T,
        capacity: *usize,
        n: usize,
    ) ![]T {
        const used = slice.len;
        const new_used = used + n;
        if (new_used <= capacity.*) {
            slice.* = slice.ptr[0..new_used];
            return slice.ptr[used..new_used];
        }
        var new_cap: usize = if (capacity.* == 0) 8 else capacity.* * 2;
        if (new_cap < new_used) new_cap = new_used;
        const new_buf = try mem.alloc(T, new_cap);
        @memcpy(new_buf[0..used], slice.*);
        var old_buf: []T = &.{};
        if (capacity.* != 0) old_buf = slice.ptr[0..capacity.*];
        slice.* = new_buf[0..new_used];
        capacity.* = new_cap;
        if (old_buf.len != 0) mem.free(T, old_buf);
        return slice.ptr[used..new_used];
    }

    /// Free the full backing buffer of a growable slice and reset both the
    /// visible slice and its capacity.
    fn freeGrowableSlice(
        comptime T: type,
        mem: *memory.MemoryAccount,
        slice: *[]T,
        capacity: *usize,
    ) void {
        var old_buf: []T = &.{};
        if (capacity.* != 0) old_buf = slice.ptr[0..capacity.*];
        slice.* = &.{};
        capacity.* = 0;
        if (old_buf.len != 0) mem.free(T, old_buf);
    }

    fn freeGrowableAtomSlice(
        atoms: *atom.AtomTable,
        mem: *memory.MemoryAccount,
        slice: *[]atom.Atom,
        capacity: *usize,
    ) void {
        const items = slice.*;
        const old_capacity = capacity.*;
        slice.* = &.{};
        capacity.* = 0;
        for (items) |atom_id| atoms.free(atom_id);
        if (old_capacity != 0) {
            mem.free(atom.Atom, items.ptr[0..old_capacity]);
        } else if (items.len != 0) {
            mem.free(atom.Atom, items);
        }
    }

    fn freeGrowableDirectCallSites(
        atoms: *atom.AtomTable,
        mem: *memory.MemoryAccount,
        slice: *[]DirectCallSite,
        capacity: *usize,
    ) void {
        const items = slice.*;
        const old_capacity = capacity.*;
        slice.* = &.{};
        capacity.* = 0;
        for (items) |site| atoms.free(site.atom_id);
        if (old_capacity != 0) {
            mem.free(DirectCallSite, items.ptr[0..old_capacity]);
        } else if (items.len != 0) {
            mem.free(DirectCallSite, items);
        }
    }

    fn freeGrowableNamedSlice(
        comptime T: type,
        atoms: *atom.AtomTable,
        mem: *memory.MemoryAccount,
        slice: *[]T,
        capacity: *usize,
    ) void {
        const items = slice.*;
        const old_capacity = capacity.*;
        slice.* = &.{};
        capacity.* = 0;
        for (items) |*item| atoms.free(item.var_name);
        if (old_capacity != 0) {
            mem.free(T, items.ptr[0..old_capacity]);
        } else if (items.len != 0) {
            mem.free(T, items);
        }
    }

    /// Mirrors `JSFunctionDef` (`quickjs.c:21420`).
    pub const FunctionDefImpl = struct {
        memory: *memory.MemoryAccount,
        atoms: *atom.AtomTable,
        parent: ?*FunctionDefImpl = null,
        discard_next: ?*FunctionDefImpl = null,
        parent_cpool_idx: i32 = -1,
        parent_scope_level: i32 = 0,

        // Flags — packed as in QuickJS
        is_eval: bool = false,
        is_global_var: bool = false,
        is_func_expr: bool = false,
        has_home_object: bool = false,
        has_prototype: bool = false,
        has_simple_parameter_list: bool = true,
        has_parameter_expressions: bool = false,
        has_use_strict: bool = false,
        has_eval_call: bool = false,
        has_arguments_binding: bool = false,
        has_this_binding: bool = false,
        new_target_allowed: bool = false,
        super_call_allowed: bool = false,
        super_allowed: bool = false,
        arguments_allowed: bool = false,
        is_derived_class_constructor: bool = false,
        in_function_body: bool = false,
        backtrace_barrier: bool = false,
        need_home_object: bool = false,
        use_short_opcodes: bool = false,
        has_await: bool = false,
        is_indirect_eval: bool = false,

        func_kind: FunctionKind = .normal,
        func_type: ParseFunctionKind = .statement,
        is_strict_mode: bool = false,
        func_name: atom.Atom,

        // Variables
        vars: []VarDef = &.{},
        vars_capacity: usize = 0,
        vars_htab: []u32 = &.{},
        var_count: i32 = 0,
        args: []VarDef = &.{},
        args_capacity: usize = 0,
        arg_count: i32 = 0,
        defined_arg_count: i32 = 0,
        var_ref_count: i32 = 0,
        var_object_idx: i32 = -1,
        arg_var_object_idx: i32 = -1,
        arguments_var_idx: i32 = -1,
        arguments_arg_idx: i32 = -1,
        func_var_idx: i32 = -1,
        eval_ret_idx: i32 = -1,
        this_var_idx: i32 = -1,
        new_target_var_idx: i32 = -1,
        this_active_func_var_idx: i32 = -1,
        home_object_var_idx: i32 = -1,

        // Scopes
        scope_level: i32 = 0,
        scope_first: i32 = 0,
        scope_count: i32 = 0,
        scopes: []VarScope = &.{},
        scopes_capacity: usize = 0,

        // Global variables
        global_vars: []GlobalVar = &.{},
        global_vars_capacity: usize = 0,
        global_var_count: i32 = 0,

        // Bytecode (Phase 1)
        byte_code: []u8 = &.{},
        byte_code_capacity: usize = 0,
        atom_operands: []atom.Atom = &.{},
        atom_operands_capacity: usize = 0,
        direct_call_sites: []DirectCallSite = &.{},
        direct_call_sites_capacity: usize = 0,
        last_opcode_pos: i32 = -1,

        // Labels
        label_slots: []LabelSlot = &.{},
        label_count: i32 = 0,

        // Constant pool
        cpool: []JSValue = &.{},
        cpool_capacity: usize = 0,
        cpool_count: i32 = 0,

        // Closure variables
        closure_var: []ClosureVar = &.{},
        closure_var_capacity: usize = 0,
        closure_var_count: i32 = 0,

        // Public instance fields without initializers. Kept for older parser paths;
        // the QuickJS-style class field initializer function is tracked separately.
        class_instance_fields: []atom.Atom = &.{},
        class_instance_fields_capacity: usize = 0,
        private_bound_names: []atom.Atom = &.{},
        private_bound_names_capacity: usize = 0,
        class_private_names: []atom.Atom = &.{},
        class_private_names_capacity: usize = 0,
        class_fields_init_cpool_idx: i32 = -1,

        // Jumps
        jump_slots: []JumpSlot = &.{},
        jump_count: i32 = 0,

        // Source location
        source_loc_slots: []pipeline_pc2line.SourceLocSlot = &.{},
        source_loc_capacity: usize = 0,
        source_loc_count: i32 = 0,
        line_number_last: i32 = 0,
        line_number_last_pc: i32 = 0,
        col_number_last: i32 = 0,

        // pc2line table
        filename: atom.Atom,
        line_num: i32 = 0,
        col_num: i32 = 0,
        source_text: ?[]const u8 = null,

        // Child functions (nested functions)
        child_list: []*FunctionDefImpl = &.{},
        child_list_capacity: usize = 0,
        emit_top_level_closure_init: bool = false,
        top_level_closure_var_idx: i32 = -1,
        child_decl_init_keep_value: bool = false,
        child_decl_var_idx: i32 = -1,
        child_decl_annex_b_var_idx: i32 = -1,
        child_decl_emit_inline: bool = false,
        child_decl_emit_var_inline: bool = false,
        child_decl_skip_init: bool = false,
        child_decl_force_local_init: bool = false,
        child_decl_emit_global_inline: bool = false,

        pub fn init(account: *memory.MemoryAccount, atoms: *atom.AtomTable, name: atom.Atom) FunctionDefImpl {
            return .{
                .memory = account,
                .atoms = atoms,
                .func_name = atoms.dup(name),
                .filename = atoms.dup(name),
            };
        }

        pub fn deinitInitFailure(self: *FunctionDefImpl) void {
            const func_name = self.func_name;
            const filename = self.filename;
            self.func_name = atom.null_atom;
            self.filename = atom.null_atom;
            self.atoms.free(func_name);
            self.atoms.free(filename);
            freeGrowableSlice(VarScope, self.memory, &self.scopes, &self.scopes_capacity);
            self.scope_count = 0;
        }

        /// Append a `VarScope` to `scopes`. Mirrors `push_scope`
        /// (`quickjs.c:23486`): the new scope records its parent index
        /// and inherits an empty `first` (no vars yet). Returns the index
        /// of the newly added scope (== new `scope_level`).
        pub fn appendScope(self: *FunctionDefImpl, parent: i32) !i32 {
            const tail = try growSliceBy(VarScope, self.memory, &self.scopes, &self.scopes_capacity, 1);
            tail[0] = .{ .parent = parent, .first = -1 };
            self.scope_count += 1;
            const idx: i32 = @intCast(self.scopes.len - 1);
            return idx;
        }

        /// Append a `VarDef` to `vars`. Mirrors `add_var`
        /// (`quickjs.c:23554`). The caller is responsible for setting
        /// `scope_level`, `var_kind`, `is_lexical`, `is_const`. The atom
        /// is duplicated; the caller keeps ownership of its copy.
        /// Returns the index of the new var.
        pub fn appendVar(self: *FunctionDefImpl, var_def: VarDef) !i32 {
            const tail = try growSliceBy(VarDef, self.memory, &self.vars, &self.vars_capacity, 1);
            tail[0] = var_def;
            tail[0].var_name = self.atoms.dup(var_def.var_name);
            self.var_count += 1;
            const idx: i32 = @intCast(self.vars.len - 1);
            return idx;
        }

        pub fn appendGlobalVar(self: *FunctionDefImpl, global_var: GlobalVar) !void {
            const tail = try growSliceBy(GlobalVar, self.memory, &self.global_vars, &self.global_vars_capacity, 1);
            tail[0] = global_var;
            tail[0].var_name = self.atoms.dup(global_var.var_name);
            self.global_var_count = @intCast(self.global_vars.len);
        }

        /// Append a formal argument definition. Mirrors the `args` side of
        /// QuickJS function metadata; parser lowering resolves matching
        /// identifier references to `get_arg*` opcodes.
        pub fn appendArg(self: *FunctionDefImpl, var_def: VarDef) !i32 {
            const tail = try growSliceBy(VarDef, self.memory, &self.args, &self.args_capacity, 1);
            tail[0] = var_def;
            tail[0].var_name = self.atoms.dup(var_def.var_name);
            self.arg_count = @intCast(self.args.len);
            self.defined_arg_count = @intCast(self.args.len);
            return @intCast(self.args.len - 1);
        }

        /// Append a child FunctionDefImpl to `child_list`. Mirrors
        /// `list_add_tail(&fd->link, &parent->child_list)` in
        /// `js_new_function_def` (`quickjs.c:31487`). The parent takes
        /// ownership of the child pointer.
        pub fn addChild(self: *FunctionDefImpl, child: *FunctionDefImpl) !void {
            const tail = try growSliceBy(*FunctionDefImpl, self.memory, &self.child_list, &self.child_list_capacity, 1);
            child.parent = self;
            child.discard_next = null;
            tail[0] = child;
        }

        /// Mirror `add_scope_var` (`quickjs.c:23577`): add a var and
        /// attach it to `scope_level`'s scope (updates `scope_first`).
        pub fn addScopeVar(
            self: *FunctionDefImpl,
            name: atom.Atom,
            var_kind: VarKind,
            scope_level: i32,
            is_lexical: bool,
            is_const: bool,
        ) !i32 {
            const prev_first: i32 = if (scope_level >= 0 and @as(usize, @intCast(scope_level)) < self.scopes.len)
                self.scopes[@intCast(scope_level)].first
            else
                -1;
            const idx = try self.appendVar(.{
                .var_name = name,
                .scope_level = scope_level,
                .scope_next = prev_first,
                .is_lexical = is_lexical,
                .is_const = is_const,
                .var_kind = var_kind,
            });
            if (scope_level >= 0 and @as(usize, @intCast(scope_level)) < self.scopes.len) {
                self.scopes[@intCast(scope_level)].first = idx;
                self.scope_first = idx;
            }
            return idx;
        }

        /// Append a closure variable entry. Used for top-level module/eval
        /// bindings and, later, captured parent-scope variables.
        pub fn addClosureVar(self: *FunctionDefImpl, closure_var: ClosureVar) !i32 {
            const tail = try growSliceBy(ClosureVar, self.memory, &self.closure_var, &self.closure_var_capacity, 1);
            tail[0] = closure_var;
            tail[0].var_name = self.atoms.dup(closure_var.var_name);
            self.closure_var_count = @intCast(self.closure_var.len);
            self.var_ref_count = @intCast(self.closure_var.len);
            return @intCast(self.closure_var.len - 1);
        }

        pub fn appendClassInstanceField(self: *FunctionDefImpl, atom_id: atom.Atom) !void {
            const tail = try growSliceBy(atom.Atom, self.memory, &self.class_instance_fields, &self.class_instance_fields_capacity, 1);
            tail[0] = self.atoms.dup(atom_id);
        }

        pub fn appendPrivateBoundName(self: *FunctionDefImpl, atom_id: atom.Atom) !void {
            for (self.private_bound_names) |existing| {
                if (existing == atom_id) return;
            }
            const tail = try growSliceBy(atom.Atom, self.memory, &self.private_bound_names, &self.private_bound_names_capacity, 1);
            tail[0] = self.atoms.dup(atom_id);
        }

        pub fn appendClassPrivateName(self: *FunctionDefImpl, atom_id: atom.Atom) !void {
            for (self.class_private_names) |existing| {
                if (existing == atom_id) return;
            }
            const tail = try growSliceBy(atom.Atom, self.memory, &self.class_private_names, &self.class_private_names_capacity, 1);
            tail[0] = self.atoms.dup(atom_id);
        }

        /// Find a var by name, searching newest-first. Returns the var
        /// index or `-1` if not found. Mirrors the htab-free path of
        /// `find_var` (`quickjs.c:23378`).
        pub fn findVar(self: *const FunctionDefImpl, name: atom.Atom) i32 {
            var i: usize = self.vars.len;
            while (i > 0) {
                i -= 1;
                if (self.vars[i].var_name == name) return @intCast(i);
            }
            return -1;
        }

        pub fn findArg(self: *const FunctionDefImpl, name: atom.Atom) i32 {
            var i: usize = self.args.len;
            while (i > 0) {
                i -= 1;
                if (self.args[i].var_name == name) return @intCast(i);
            }
            return -1;
        }

        /// Append bytes to the byte_code buffer. Used for nested function
        /// bytecode emission during parsing.
        pub fn appendByteCode(self: *FunctionDefImpl, bytes: []const u8) !void {
            if (bytes.len == 0) return;
            if (bytesMayContainEvalCall(bytes)) self.has_eval_call = true;
            const tail = try growSliceBy(u8, self.memory, &self.byte_code, &self.byte_code_capacity, bytes.len);
            @memcpy(tail, bytes);
        }

        pub fn appendSourceLoc(self: *FunctionDefImpl, pc: u32, line_num: i32, col_num: i32) !void {
            if (line_num <= 0 or col_num <= 0) return;
            const tail = try growSliceBy(pipeline_pc2line.SourceLocSlot, self.memory, &self.source_loc_slots, &self.source_loc_capacity, 1);
            tail[0] = .{ .pc = pc, .line_num = line_num, .col_num = col_num };
            self.source_loc_count = @intCast(self.source_loc_slots.len);
        }

        pub fn appendAtomOperand(self: *FunctionDefImpl, atom_id: atom.Atom) !void {
            const tail = try growSliceBy(atom.Atom, self.memory, &self.atom_operands, &self.atom_operands_capacity, 1);
            tail[0] = self.atoms.dup(atom_id);
        }

        pub fn appendDirectCallSite(self: *FunctionDefImpl, site: DirectCallSite) !void {
            const tail = try growSliceBy(DirectCallSite, self.memory, &self.direct_call_sites, &self.direct_call_sites_capacity, 1);
            tail[0] = site;
            tail[0].atom_id = self.atoms.dup(site.atom_id);
        }

        pub fn appendCpool(self: *FunctionDefImpl, value: JSValue) !u32 {
            const tail = try growSliceBy(JSValue, self.memory, &self.cpool, &self.cpool_capacity, 1);
            tail[0] = dupOwnedValue(self.atoms, value);
            self.cpool_count = @intCast(self.cpool.len);
            return @intCast(self.cpool.len - 1);
        }

        pub fn appendCpoolOwned(self: *FunctionDefImpl, value: JSValue) !u32 {
            const tail = try growSliceBy(JSValue, self.memory, &self.cpool, &self.cpool_capacity, 1);
            tail[0] = takeOwnedValue(self.atoms, value);
            self.cpool_count = @intCast(self.cpool.len);
            return @intCast(self.cpool.len - 1);
        }

        /// Truncate `byte_code` to `target_len` bytes, leaving capacity intact so
        /// re-emission after speculative rollback does not require reallocation.
        pub fn truncateByteCode(self: *FunctionDefImpl, target_len: usize) void {
            std.debug.assert(target_len <= self.byte_code.len);
            self.byte_code = self.byte_code.ptr[0..target_len];
        }

        /// Truncate `atom_operands` to `target_len` entries, releasing the
        /// per-element atom refcounts but keeping the backing buffer.
        pub fn truncateAtomOperands(self: *FunctionDefImpl, target_len: usize) void {
            std.debug.assert(target_len <= self.atom_operands.len);
            var i: usize = target_len;
            while (i < self.atom_operands.len) : (i += 1) {
                self.atoms.free(self.atom_operands[i]);
            }
            self.atom_operands = self.atom_operands.ptr[0..target_len];
        }

        pub fn deinit(self: *FunctionDefImpl, rt: anytype) void {
            const func_name = self.func_name;
            const filename = self.filename;
            self.func_name = atom.null_atom;
            self.filename = atom.null_atom;
            self.atoms.free(func_name);
            self.atoms.free(filename);

            freeGrowableNamedSlice(VarDef, self.atoms, self.memory, &self.vars, &self.vars_capacity);
            if (self.vars_htab.len != 0) self.memory.free(u32, self.vars_htab);

            freeGrowableNamedSlice(VarDef, self.atoms, self.memory, &self.args, &self.args_capacity);

            freeGrowableSlice(VarScope, self.memory, &self.scopes, &self.scopes_capacity);

            freeGrowableNamedSlice(GlobalVar, self.atoms, self.memory, &self.global_vars, &self.global_vars_capacity);

            freeGrowableSlice(u8, self.memory, &self.byte_code, &self.byte_code_capacity);
            freeGrowableAtomSlice(self.atoms, self.memory, &self.atom_operands, &self.atom_operands_capacity);
            freeGrowableDirectCallSites(self.atoms, self.memory, &self.direct_call_sites, &self.direct_call_sites_capacity);

            const old_label_slots = self.label_slots;
            self.label_slots = &.{};
            // Free label reloc entries
            for (old_label_slots) |*ls| {
                var reloc = ls.first_reloc;
                ls.first_reloc = null;
                while (reloc) |r| {
                    const next = r.next;
                    self.memory.free(RelocEntry, r[0..1]);
                    reloc = next;
                }
            }
            if (old_label_slots.len != 0) self.memory.free(LabelSlot, old_label_slots);

            const old_cpool = self.cpool;
            const old_cpool_capacity = self.cpool_capacity;
            self.cpool = &.{};
            self.cpool_capacity = 0;
            self.cpool_count = 0;
            for (old_cpool) |*slot| {
                const value = slot.*;
                slot.* = JSValue.undefinedValue();
                freeOwnedValue(self.atoms, value, rt);
            }
            if (old_cpool_capacity != 0) self.memory.free(JSValue, old_cpool.ptr[0..old_cpool_capacity]);

            freeGrowableNamedSlice(ClosureVar, self.atoms, self.memory, &self.closure_var, &self.closure_var_capacity);

            freeGrowableAtomSlice(self.atoms, self.memory, &self.class_instance_fields, &self.class_instance_fields_capacity);
            freeGrowableAtomSlice(self.atoms, self.memory, &self.private_bound_names, &self.private_bound_names_capacity);
            freeGrowableAtomSlice(self.atoms, self.memory, &self.class_private_names, &self.class_private_names_capacity);

            if (self.jump_slots.len != 0) self.memory.free(JumpSlot, self.jump_slots);

            freeGrowableSlice(pipeline_pc2line.SourceLocSlot, self.memory, &self.source_loc_slots, &self.source_loc_capacity);
            if (self.source_text) |source| self.memory.free(u8, @constCast(source));

            const old_child_list = self.child_list;
            const old_child_list_capacity = self.child_list_capacity;
            self.child_list = &.{};
            self.child_list_capacity = 0;
            for (old_child_list) |child| {
                child.deinit(rt);
                self.memory.destroy(FunctionDefImpl, child);
            }

            self.vars_htab = &.{};
            self.discard_next = null;
            self.class_fields_init_cpool_idx = -1;
            self.jump_slots = &.{};
            self.source_text = null;
            self.emit_top_level_closure_init = false;
            self.top_level_closure_var_idx = -1;
            self.child_decl_init_keep_value = false;
            self.child_decl_var_idx = -1;
            self.child_decl_annex_b_var_idx = -1;
            self.child_decl_emit_inline = false;
            self.child_decl_emit_var_inline = false;
            self.child_decl_skip_init = false;
            self.child_decl_force_local_init = false;
            self.child_decl_emit_global_inline = false;
            if (old_child_list_capacity != 0) self.memory.free(*FunctionDefImpl, old_child_list.ptr[0..old_child_list_capacity]);
        }
    };

    fn bytesMayContainEvalCall(bytes: []const u8) bool {
        return std.mem.indexOfScalar(u8, bytes, opcode.op.eval) != null or
            std.mem.indexOfScalar(u8, bytes, opcode.op.apply_eval) != null;
    }
    pub const FunctionDef = FunctionDefImpl;
};

pub const pipeline_pc2line = struct {
    //! Phase 3b: compute_pc2line_info
    //!
    //! Mirrors `compute_pc2line_info` at `quickjs.c:33995`.
    //!
    //! Encodes a sequence of (pc, line, col) source-location slots into a
    //! compact buffer, mirroring QuickJS's pc2line format byte-for-byte.
    //!
    //! ## Encoding
    //!
    //! For each transition from the previous (last_pc, last_line, last_col)
    //! to (pc, line, col):
    //!
    //!   diff_pc   = pc   - last_pc       (must be >= 0)
    //!   diff_line = line - last_line
    //!   diff_col  = col  - last_col
    //!
    //! If `diff_pc < 0` or `(diff_line == 0 and diff_col == 0)` — skip.
    //!
    //! Compact form (single byte + sleb128 col), when both:
    //!   - PC2LINE_BASE <= diff_line < PC2LINE_BASE + PC2LINE_RANGE
    //!   - diff_pc <= PC2LINE_DIFF_PC_MAX
    //!
    //!   byte = (diff_line - PC2LINE_BASE) + diff_pc * PC2LINE_RANGE + PC2LINE_OP_FIRST
    //!   followed by sleb128(diff_col)
    //!
    //! Long form (marker 0 + leb128 pc + sleb128 line + sleb128 col):
    //!   byte = 0
    //!   leb128(diff_pc)
    //!   sleb128(diff_line)
    //!   sleb128(diff_col)

    const std = @import("std");
    const memory = @import("core/memory.zig");

    /// PC2LINE encoding constants (mirror `quickjs.c:756`).
    pub const PC2LINE_BASE: i32 = -1;
    pub const PC2LINE_RANGE: i32 = 5;
    pub const PC2LINE_OP_FIRST: i32 = 1;
    pub const PC2LINE_DIFF_PC_MAX: i32 = (255 - PC2LINE_OP_FIRST) / PC2LINE_RANGE; // = 50

    /// One source-location slot — mirrors `SourceLocSlot` (`quickjs.c:21395`).
    pub const SourceLocSlot = struct {
        pc: u32,
        line_num: i32,
        col_num: i32,
    };

    /// Encoded pc2line buffer plus the (line, col) at pc=0 needed for decoding.
    pub const Encoded = struct {
        bytes: []u8,
        line_num: i32,
        col_num: i32,
        memory: *memory.MemoryAccount,

        pub fn deinit(self: *Encoded) void {
            const bytes = self.bytes;
            self.bytes = &.{};
            if (bytes.len != 0) self.memory.free(u8, bytes);
        }
    };

    /// Encode a sequence of source-location slots into a pc2line buffer.
    ///
    /// `start_line_num` and `start_col_num` are the function's starting
    /// position (used as the implicit pc=0 reference, matching QuickJS's
    /// `s->line_num` / `s->col_num`).
    pub fn encode(
        account: *memory.MemoryAccount,
        slots: []const SourceLocSlot,
        start_line_num: i32,
        start_col_num: i32,
    ) !Encoded {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(account.allocator);

        var last_line_num: i32 = start_line_num;
        var last_col_num: i32 = start_col_num;
        var last_pc: u32 = 0;

        for (slots) |slot| {
            if (slot.line_num < 0) continue;
            if (slot.pc < last_pc) continue;

            const diff_pc: i32 = @intCast(slot.pc - last_pc);
            const diff_line: i32 = slot.line_num - last_line_num;
            const diff_col: i32 = slot.col_num - last_col_num;
            if (diff_line == 0 and diff_col == 0) continue;

            if (diff_line >= PC2LINE_BASE and
                diff_line < PC2LINE_BASE + PC2LINE_RANGE and
                diff_pc <= PC2LINE_DIFF_PC_MAX)
            {
                const byte: u8 = @intCast(
                    (diff_line - PC2LINE_BASE) + diff_pc * PC2LINE_RANGE + PC2LINE_OP_FIRST,
                );
                try buf.append(account.allocator, byte);
            } else {
                try buf.append(account.allocator, 0);
                try putLeb128(&buf, account.allocator, @intCast(diff_pc));
                try putSleb128(&buf, account.allocator, diff_line);
            }
            try putSleb128(&buf, account.allocator, diff_col);

            last_pc = slot.pc;
            last_line_num = slot.line_num;
            last_col_num = slot.col_num;
        }

        const owned: []u8 = if (buf.items.len == 0) &.{} else blk: {
            const bytes = try account.alloc(u8, buf.items.len);
            @memcpy(bytes, buf.items);
            break :blk bytes;
        };
        return .{
            .bytes = owned,
            .line_num = start_line_num,
            .col_num = start_col_num,
            .memory = account,
        };
    }

    /// Decode the pc2line buffer back into a sequence of (pc, line, col).
    /// Inverse of `encode`. Used by tests and by the runtime when reporting
    /// source positions for stack traces.
    pub fn decode(
        allocator: std.mem.Allocator,
        encoded: Encoded,
    ) ![]SourceLocSlot {
        var slots: std.ArrayList(SourceLocSlot) = .empty;
        defer slots.deinit(allocator);

        var pc: u32 = 0;
        var line_num: i32 = encoded.line_num;
        var col_num: i32 = encoded.col_num;
        var i: usize = 0;
        while (i < encoded.bytes.len) {
            const op = encoded.bytes[i];
            i += 1;
            if (op == 0) {
                const diff_pc = try readLeb128(encoded.bytes, &i);
                const diff_line = try readSleb128(encoded.bytes, &i);
                pc += @intCast(diff_pc);
                line_num += diff_line;
            } else {
                const adjusted: i32 = @as(i32, op) - PC2LINE_OP_FIRST;
                const diff_pc: i32 = @divFloor(adjusted, PC2LINE_RANGE);
                const diff_line: i32 = @mod(adjusted, PC2LINE_RANGE) + PC2LINE_BASE;
                pc += @intCast(diff_pc);
                line_num += diff_line;
            }
            const diff_col = try readSleb128(encoded.bytes, &i);
            col_num += diff_col;

            try slots.append(allocator, .{
                .pc = pc,
                .line_num = line_num,
                .col_num = col_num,
            });
        }
        return slots.toOwnedSlice(allocator);
    }

    // ---- LEB128 helpers ----

    fn putLeb128(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u32) !void {
        var v = value;
        while (true) {
            const byte: u8 = @intCast(v & 0x7f);
            v >>= 7;
            if (v == 0) {
                try buf.append(allocator, byte);
                return;
            }
            try buf.append(allocator, byte | 0x80);
        }
    }

    fn putSleb128(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, value: i32) !void {
        var v = value;
        while (true) {
            const byte: u8 = @intCast(@as(u32, @bitCast(v)) & 0x7f);
            // Arithmetic right shift: preserve sign bit.
            v >>= 7;
            // Done when v is fully sign-extended and the sign bit of the
            // last 7-bit group matches (so the consumer reconstructs the
            // sign correctly).
            const sign_bit = (byte & 0x40) != 0;
            if ((v == 0 and !sign_bit) or (v == -1 and sign_bit)) {
                try buf.append(allocator, byte);
                return;
            }
            try buf.append(allocator, byte | 0x80);
        }
    }

    fn readLeb128(bytes: []const u8, i: *usize) !u32 {
        var result: u32 = 0;
        var shift: u5 = 0;
        while (true) {
            if (i.* >= bytes.len) return error.Pc2LineTruncated;
            const byte = bytes[i.*];
            i.* += 1;
            result |= @as(u32, byte & 0x7f) << shift;
            if ((byte & 0x80) == 0) return result;
            shift += 7;
            if (shift >= 32) return error.Pc2LineOverflow;
        }
    }

    fn readSleb128(bytes: []const u8, i: *usize) !i32 {
        var result: i32 = 0;
        var shift: u5 = 0;
        while (true) {
            if (i.* >= bytes.len) return error.Pc2LineTruncated;
            const byte = bytes[i.*];
            i.* += 1;
            result |= @as(i32, @intCast(byte & 0x7f)) << shift;
            shift += 7;
            if ((byte & 0x80) == 0) {
                // Sign-extend if the highest data bit of the final group is set.
                if (shift < 32 and (byte & 0x40) != 0) {
                    result |= @as(i32, -1) << shift;
                }
                return result;
            }
            if (shift >= 32) return error.Pc2LineOverflow;
        }
    }

    test "pc2line: empty slot list produces empty buffer" {
        var account = memory.MemoryAccount.init(std.testing.allocator);
        var encoded = try encode(&account, &.{}, 1, 0);
        defer encoded.deinit();
        try std.testing.expectEqual(@as(usize, 0), encoded.bytes.len);
    }

    test "pc2line: compact encoding for small line/pc deltas" {
        var account = memory.MemoryAccount.init(std.testing.allocator);
        // Two slots: same line, small pc delta. Compact form is one byte
        // (line/pc compact) plus a sleb128 col diff.
        const slots = [_]SourceLocSlot{
            .{ .pc = 0, .line_num = 1, .col_num = 1 },
            .{ .pc = 5, .line_num = 1, .col_num = 4 },
        };
        var encoded = try encode(&account, &slots, 1, 1);
        defer encoded.deinit();

        // First slot has diff_pc=0, diff_line=0, diff_col=0 from start (1,1) → skipped.
        // Second slot has diff_pc=5, diff_line=0, diff_col=3 from previous.
        // Compact byte = (0 - (-1)) + 5*5 + 1 = 1 + 25 + 1 = 27, then sleb128(3) = 0x03.
        try std.testing.expectEqual(@as(usize, 2), encoded.bytes.len);
        try std.testing.expectEqual(@as(u8, 27), encoded.bytes[0]);
        try std.testing.expectEqual(@as(u8, 3), encoded.bytes[1]);
    }

    test "pc2line: long encoding for large pc delta" {
        var account = memory.MemoryAccount.init(std.testing.allocator);
        const slots = [_]SourceLocSlot{
            .{ .pc = 100, .line_num = 2, .col_num = 1 },
        };
        var encoded = try encode(&account, &slots, 1, 1);
        defer encoded.deinit();

        // diff_pc=100 > MAX(50) → long form: 0, leb128(100), sleb128(1), sleb128(0).
        try std.testing.expectEqual(@as(usize, 4), encoded.bytes.len);
        try std.testing.expectEqual(@as(u8, 0), encoded.bytes[0]);
        try std.testing.expectEqual(@as(u8, 100), encoded.bytes[1]);
        try std.testing.expectEqual(@as(u8, 1), encoded.bytes[2]); // sleb128(1) for diff_line
        try std.testing.expectEqual(@as(u8, 0), encoded.bytes[3]); // sleb128(0) for diff_col
    }

    test "pc2line: encode/decode round-trip" {
        var account = memory.MemoryAccount.init(std.testing.allocator);
        const input_slots = [_]SourceLocSlot{
            .{ .pc = 5, .line_num = 1, .col_num = 4 },
            .{ .pc = 10, .line_num = 2, .col_num = 1 },
            .{ .pc = 200, .line_num = 5, .col_num = 12 },
            .{ .pc = 250, .line_num = 5, .col_num = 25 },
        };
        var encoded = try encode(&account, &input_slots, 1, 1);
        defer encoded.deinit();

        const decoded = try decode(std.testing.allocator, encoded);
        defer std.testing.allocator.free(decoded);

        try std.testing.expectEqual(input_slots.len, decoded.len);
        for (input_slots, decoded) |expected, actual| {
            try std.testing.expectEqual(expected.pc, actual.pc);
            try std.testing.expectEqual(expected.line_num, actual.line_num);
            try std.testing.expectEqual(expected.col_num, actual.col_num);
        }
    }

    test "pc2line: skips slots with no real change or backward pc" {
        var account = memory.MemoryAccount.init(std.testing.allocator);
        const slots = [_]SourceLocSlot{
            .{ .pc = 10, .line_num = 1, .col_num = 5 },
            .{ .pc = 10, .line_num = 1, .col_num = 5 }, // duplicate → skipped
            .{ .pc = 5, .line_num = 1, .col_num = 5 }, // backward pc → skipped
            .{ .pc = 15, .line_num = -1, .col_num = 5 }, // line < 0 → skipped
            .{ .pc = 20, .line_num = 1, .col_num = 8 }, // valid
        };
        var encoded = try encode(&account, &slots, 1, 1);
        defer encoded.deinit();

        const decoded = try decode(std.testing.allocator, encoded);
        defer std.testing.allocator.free(decoded);

        try std.testing.expectEqual(@as(usize, 2), decoded.len);
        try std.testing.expectEqual(@as(u32, 10), decoded[0].pc);
        try std.testing.expectEqual(@as(u32, 20), decoded[1].pc);
    }

    test "pc2line: negative line delta encoded compactly" {
        var account = memory.MemoryAccount.init(std.testing.allocator);
        const slots = [_]SourceLocSlot{
            .{ .pc = 5, .line_num = 5, .col_num = 1 },
            .{ .pc = 10, .line_num = 4, .col_num = 1 }, // diff_line = -1, in compact range
        };
        var encoded = try encode(&account, &slots, 1, 1);
        defer encoded.deinit();

        const decoded = try decode(std.testing.allocator, encoded);
        defer std.testing.allocator.free(decoded);

        try std.testing.expectEqual(@as(usize, 2), decoded.len);
        try std.testing.expectEqual(@as(i32, 5), decoded[0].line_num);
        try std.testing.expectEqual(@as(i32, 4), decoded[1].line_num);
    }
};

pub const pipeline_resolve_variables = struct {
    //! resolve_variables
    //!
    //! Mirrors `resolve_variables` at `quickjs.c:33622`.
    //!
    //! Walks the lexical chain, resolves variable references, and replaces
    //! temporary scope opcodes with their final forms.

    const std = @import("std");
    const atom = @import("core/atom.zig");
    const memory = @import("core/memory.zig");
    const bytecode_function = function_mod;
    const function_def_mod = function_def;

    const EVAL_CLASS_FIELD_INITIALIZER_FLAG: u16 = 0x8000;
    const EVAL_SCOPE_INDEX_MASK: u16 = 0x7fff;

    pub const Error = error{
        OutOfMemory,
        InvalidBytecode,
        NoFunctionDef,
        NoParentScope,
        ClosureVarNotFound,
    };

    /// JSContext for variable resolution.
    pub const JSContext = struct {
        function: *bytecode_function.Bytecode,
        memory: *memory.MemoryAccount,
        atoms: *atom.AtomTable,
        /// Optional FunctionDef driving local-slot lookup. When non-null,
        /// `resolve_variables` lowers `scope_get_var` / `scope_put_var` to
        /// local, closure, or QuickJS-style global closure-var references.
        function_def: ?*function_def_mod.FunctionDef = null,

        pub fn init(function: *bytecode_function.Bytecode) JSContext {
            return .{
                .function = function,
                .memory = function.memory,
                .atoms = function.atoms,
            };
        }

        pub fn initWithFunctionDef(
            function: *bytecode_function.Bytecode,
            fd: *function_def_mod.FunctionDef,
        ) JSContext {
            return .{
                .function = function,
                .memory = function.memory,
                .atoms = function.atoms,
                .function_def = fd,
            };
        }
    };

    /// Run variable resolution on a function.
    ///
    /// Input: a Bytecode whose code contains temporary scope opcodes only.
    /// Output: the same Bytecode with temporary opcodes replaced by final forms.
    ///
    /// This implementation:
    /// - Linear scan over byte_code
    /// - Replaces scope_get_var → get_var
    /// - Replaces scope_put_var → put_var
    /// - Replaces scope_get_var_undef → get_var_undef
    /// - Drops enter_scope/leave_scope
    ///
    /// Full QuickJS alignment (closure variables, TDZ, eval) will be added
    /// when FunctionDef is integrated into the parser.
    /// Total byte length (opcode + operands) for `op_id` in final-form
    /// (non-temp) encoding, from the generated metadata table. Returns 1
    /// for ids with no table entry so callers can safely fall through
    /// unknown opcodes one byte at a time (matching QuickJS's unknown-op
    /// pass-through). Temp opcodes this pass consumes are special-cased
    /// at each walk site (or use `inputInstrSizeForRefTailScan`).
    fn instrSize(op_id: u8) usize {
        const total = opcode.sizeOf(op_id);
        return if (total == 0) 1 else total;
    }

    fn fclosureEncodingSize(cpool_idx: i32) error{InvalidBytecode}!usize {
        if (cpool_idx < 0) return error.InvalidBytecode;
        return if (@as(u32, @intCast(cpool_idx)) <= std.math.maxInt(u8)) 2 else 5;
    }

    fn emitFClosure(output: []u8, out_idx: *usize, cpool_idx: i32) error{InvalidBytecode}!void {
        if (cpool_idx < 0) return error.InvalidBytecode;
        const idx: u32 = @intCast(cpool_idx);
        if (idx <= std.math.maxInt(u8)) {
            if (out_idx.* + 2 > output.len) return error.InvalidBytecode;
            output[out_idx.*] = opcode.op.fclosure8;
            output[out_idx.* + 1] = @intCast(idx);
            out_idx.* += 2;
            return;
        }
        if (out_idx.* + 5 > output.len) return error.InvalidBytecode;
        output[out_idx.*] = opcode.op.fclosure;
        std.mem.writeInt(u32, output[out_idx.* + 1 ..][0..4], idx, .little);
        out_idx.* += 5;
    }

    /// Returns true if the opcode at `op_id` is a temporary
    /// variable-scope opcode that `resolve_variables` needs to lower.
    /// All four are 7-byte `atom_u16` forms.
    fn isScopeVarOp(op_id: u8) bool {
        return op_id == opcode.op.scope_get_var or
            op_id == opcode.op.scope_put_var or
            op_id == opcode.op.scope_get_var_undef or
            op_id == opcode.op.scope_get_var_checkthis or
            op_id == opcode.op.scope_put_var_init;
    }

    /// Returns true if the opcode is a scope_delete_var / scope_get_ref
    /// temporary. Both are 7-byte `atom_u16` forms, same layout as the
    /// basic scope_*_var family. `scope_make_ref` is an 11-byte
    /// `atom_label_u16` form and is handled separately.
    fn isScopeRefOp(op_id: u8) bool {
        return op_id == opcode.op.scope_get_ref or
            op_id == opcode.op.scope_delete_var;
    }

    /// Returns true if the opcode at `op_id` is a temporary
    /// private field opcode that `resolve_variables` needs to lower.
    fn isScopePrivateFieldOp(op_id: u8) bool {
        return op_id == opcode.op.scope_get_private_field or
            op_id == opcode.op.scope_get_private_field2 or
            op_id == opcode.op.scope_put_private_field or
            op_id == opcode.op.scope_in_private_field;
    }

    fn isScopePrivateFieldAt(func: *const bytecode_function.Bytecode, pc: usize, atom_operand_idx: usize) bool {
        if (pc + 7 > func.code.len) return false;
        if (!isScopePrivateFieldOp(func.code[pc])) return false;
        if (atom_operand_idx >= func.atom_operands.len) return false;
        const encoded_atom = std.mem.readInt(u32, func.code[pc + 1 ..][0..4], .little);
        return func.atom_operands[atom_operand_idx] == encoded_atom;
    }

    /// Maps a scope_* private field opcode to its final form.
    fn lowerScopePrivateFieldOp(op_id: u8) u8 {
        return switch (op_id) {
            opcode.op.scope_get_private_field => opcode.op.get_private_field,
            opcode.op.scope_get_private_field2 => opcode.op.get_private_field,
            opcode.op.scope_put_private_field => opcode.op.put_private_field,
            opcode.op.scope_in_private_field => opcode.op.private_in,
            else => unreachable,
        };
    }

    /// Maps a scope_* var opcode to its global-form counterpart (3-byte
    /// var_ref form). Used when the variable doesn't resolve to a local
    /// slot in `function_def.vars`. `scope_put_var_init` lowers to
    /// `put_var_init` (initialise-once binding for top-level
    /// `let`/`const`); the others use their plain counterparts.
    fn lowerScopeVarOpGlobal(op_id: u8) u8 {
        return switch (op_id) {
            opcode.op.scope_get_var, opcode.op.scope_get_var_checkthis => opcode.op.get_var,
            opcode.op.scope_put_var => opcode.op.put_var,
            opcode.op.scope_get_var_undef => opcode.op.get_var_undef,
            opcode.op.scope_put_var_init => opcode.op.put_var_init,
            else => unreachable,
        };
    }

    /// Maps a scope_* var opcode to its local-form counterpart (3-byte
    /// loc form). `scope_get_var_undef` collapses to `get_loc` since
    /// locals are always defined (frame allocates them up front, default
    /// value is `undefined`). `scope_put_var_init` collapses to
    /// `put_loc` for the local case. The TDZ-aware `put_loc_check_init`
    /// variant remains open for broader lexical-initialization coverage.
    fn lowerScopeVarOpLocal(op_id: u8) u8 {
        return switch (op_id) {
            opcode.op.scope_get_var, opcode.op.scope_get_var_checkthis => opcode.op.get_loc,
            opcode.op.scope_put_var => opcode.op.put_loc,
            opcode.op.scope_get_var_undef => opcode.op.get_loc,
            opcode.op.scope_put_var_init => opcode.op.put_loc,
            else => unreachable,
        };
    }

    /// Shortest-form local-slot opcode triple. Mirrors `put_short_code`
    /// (`quickjs.c:34140`):
    /// - `idx ∈ [0, 4)` → 1-byte short forms `get_loc0..3` / `put_loc0..3`
    ///   / `set_loc0..3` (idx encoded in opcode id).
    /// - `idx ∈ [4, 256)` → 2-byte `get_loc8` / `put_loc8` / `set_loc8`
    ///   (1-byte op + u8 idx).
    /// - `idx ∈ [256, 65536)` → 3-byte `get_loc` / `put_loc` / `set_loc`
    ///   (1-byte op + u16 idx).
    const ShortLocForm = struct {
        /// Selected opcode id.
        op_id: u8,
        /// Total byte length (1, 2, or 3) the encoder will produce.
        size: u8,
        /// Operand byte width (0 for short, 1 for u8, 2 for u16).
        operand_size: u8,
    };

    fn selectShortLoc(base_op: u8, idx: u16) ShortLocForm {
        if (idx < 4) {
            const short_base: u8 = switch (base_op) {
                opcode.op.get_loc => opcode.op.get_loc0,
                opcode.op.put_loc => opcode.op.put_loc0,
                opcode.op.set_loc => opcode.op.set_loc0,
                else => unreachable,
            };
            return .{
                .op_id = short_base + @as(u8, @intCast(idx)),
                .size = 1,
                .operand_size = 0,
            };
        }
        if (idx < 256) {
            const op_id: u8 = switch (base_op) {
                opcode.op.get_loc => opcode.op.get_loc8,
                opcode.op.put_loc => opcode.op.put_loc8,
                opcode.op.set_loc => opcode.op.set_loc8,
                else => unreachable,
            };
            return .{ .op_id = op_id, .size = 2, .operand_size = 1 };
        }
        return .{ .op_id = base_op, .size = 3, .operand_size = 2 };
    }

    fn shortOpcodesEnabled(ctx: *const JSContext) bool {
        const fd = ctx.function_def orelse return false;
        return fd.use_short_opcodes;
    }

    fn selectLocForm(ctx: *const JSContext, base_op: u8, idx: u16) ShortLocForm {
        if (shortOpcodesEnabled(ctx)) return selectShortLoc(base_op, idx);
        return .{ .op_id = base_op, .size = 3, .operand_size = 2 };
    }

    fn scopeChainContains(fd: *const function_def_mod.FunctionDef, start_scope: i32, target_scope: i32) bool {
        var scope_idx = start_scope;
        while (scope_idx >= 0 and @as(usize, @intCast(scope_idx)) < fd.scopes.len) {
            if (scope_idx == target_scope) return true;
            scope_idx = fd.scopes[@intCast(scope_idx)].parent;
        }
        return false;
    }

    fn closureVarIsRuntimeVarRef(cv: function_def_mod.ClosureVar) bool {
        return switch (cv.closure_type) {
            // `.global`/`.global_ref` are codex's index-based global atom carriers
            // (no runtime cell) — skip them. `.global_decl` IS the shared top-level
            // let/const VarRef cell (frame.var_refs[idx], qjs JS_CLOSURE_GLOBAL_DECL),
            // so it MUST resolve here: otherwise a `r = <call/eval expr>` reassignment
            // (whose global-ref tail rewrite cannot fire across the call) lowers
            // scope_make_ref to make_var_ref<atom> instead of make_var_ref_ref<idx>
            // and put_ref_value never writes through the cell the closures read.
            .global, .global_ref => false,
            else => true,
        };
    }

    fn lookupClosureVar(ctx: *const JSContext, atom_id: u32) ?u16 {
        const fd = ctx.function_def orelse return null;
        for (fd.closure_var, 0..) |cv, idx| {
            if (!closureVarIsRuntimeVarRef(cv)) continue;
            if (cv.var_name == atom_id) return @intCast(idx);
        }
        var maybe_parent = fd.parent;
        var visible_scope_level = fd.parent_scope_level;
        while (maybe_parent) |parent| {
            for (parent.closure_var, 0..) |cv, idx| {
                if (!closureVarIsRuntimeVarRef(cv)) continue;
                if (cv.var_name == atom_id) return @intCast(idx);
            }
            if (findVisibleParentVar(parent, atom_id, visible_scope_level)) |parent_var| {
                return @intCast(parent_var);
            }
            const parent_arg = parent.findArg(atom_id);
            if (parent_arg >= 0) return @intCast(parent_arg);
            visible_scope_level = parent.parent_scope_level;
            maybe_parent = parent.parent;
        }
        return null;
    }

    fn lookupGlobalClosureVar(ctx: *const JSContext, atom_id: u32) ?u16 {
        const fd = ctx.function_def orelse return null;
        for (fd.closure_var, 0..) |cv, idx| {
            if (cv.var_name != atom_id) continue;
            switch (cv.closure_type) {
                .global, .global_ref, .global_decl, .module_decl, .module_import => return @intCast(idx),
                else => {},
            }
        }
        return null;
    }

    fn ensureGlobalClosureVar(ctx: *JSContext, atom_id: u32) Error!u16 {
        if (lookupGlobalClosureVar(ctx, atom_id)) |idx| return idx;
        const fd = ctx.function_def orelse return error.NoFunctionDef;
        const idx = try fd.addClosureVar(.{
            .closure_type = .global,
            .is_lexical = false,
            .is_const = false,
            .var_kind = .normal,
            .var_idx = 0,
            .var_name = atom_id,
        });
        if (idx < 0 or idx > std.math.maxInt(u16)) return error.InvalidBytecode;
        return @intCast(idx);
    }

    fn emitGlobalVarOp(ctx: *JSContext, output: []u8, out_idx: *usize, op_id: u8, atom_id: u32) Error!void {
        if (out_idx.* + 3 > output.len) return error.InvalidBytecode;
        const ref_idx = try ensureGlobalClosureVar(ctx, atom_id);
        output[out_idx.*] = op_id;
        std.mem.writeInt(u16, output[out_idx.* + 1 ..][0..2], ref_idx, .little);
        out_idx.* += 3;
    }

    fn lookupTopLevelModuleLexicalClosureVar(ctx: *const JSContext, atom_id: u32, scope_level: i32) ?u16 {
        if (scope_level != 0) return null;
        const fd = ctx.function_def orelse return null;
        for (fd.closure_var, 0..) |cv, idx| {
            if (cv.var_name == atom_id and (cv.closure_type == .module_decl or cv.closure_type == .global_decl) and cv.is_lexical) return @intCast(idx);
        }
        return null;
    }

    fn preferTopLevelModuleClassBinding(ctx: *const JSContext, atom_id: u32, loc_idx: u16) ?u16 {
        const fd = ctx.function_def orelse return null;
        if (loc_idx >= fd.vars.len) return null;
        const vd = fd.vars[loc_idx];
        if (vd.var_name != atom_id or vd.scope_level != 0 or !vd.is_lexical or !vd.is_const) return null;
        for (fd.closure_var, 0..) |cv, idx| {
            if (cv.var_name == atom_id and cv.closure_type == .module_decl and cv.is_lexical and !cv.is_const) return @intCast(idx);
        }
        return null;
    }

    fn closureVarKind(ctx: *const JSContext, idx: u16) function_def_mod.VarKind {
        const fd = ctx.function_def orelse return .normal;
        if (idx >= fd.closure_var.len) return .normal;
        return fd.closure_var[idx].var_kind;
    }

    fn closureVarKindForAtom(ctx: *const JSContext, atom_id: u32) function_def_mod.VarKind {
        const fd = ctx.function_def orelse return .normal;
        for (fd.closure_var) |cv| {
            if (!closureVarIsRuntimeVarRef(cv)) continue;
            if (cv.var_name == atom_id) return cv.var_kind;
        }
        var maybe_parent = fd.parent;
        var visible_scope_level = fd.parent_scope_level;
        while (maybe_parent) |parent| {
            for (parent.closure_var) |cv| {
                if (!closureVarIsRuntimeVarRef(cv)) continue;
                if (cv.var_name == atom_id) return cv.var_kind;
            }
            if (findVisibleParentVar(parent, atom_id, visible_scope_level)) |parent_var| {
                return parent.vars[@intCast(parent_var)].var_kind;
            }
            visible_scope_level = parent.parent_scope_level;
            maybe_parent = parent.parent;
        }
        return .normal;
    }

    fn closureVarIsLexicalForAtom(ctx: *const JSContext, atom_id: u32) bool {
        const fd = ctx.function_def orelse return true;
        for (fd.closure_var) |cv| {
            if (!closureVarIsRuntimeVarRef(cv)) continue;
            if (cv.var_name == atom_id) return cv.is_lexical;
        }
        var maybe_parent = fd.parent;
        while (maybe_parent) |parent| {
            for (parent.closure_var) |cv| {
                if (!closureVarIsRuntimeVarRef(cv)) continue;
                if (cv.var_name == atom_id) return cv.is_lexical;
            }
            maybe_parent = parent.parent;
        }
        return true;
    }

    fn lowerScopeVarOpForClosure(ctx: *const JSContext, atom_id: u32, ref_idx: u16, op_id: u8) u8 {
        var ref_op = lowerScopeVarOpClosure(op_id);
        if (op_id == opcode.op.scope_get_var and (closureVarKind(ctx, ref_idx) == .function_decl or closureVarKindForAtom(ctx, atom_id) == .function_decl or !closureVarIsLexicalForAtom(ctx, atom_id))) {
            ref_op = opcode.op.get_var_ref;
        }
        if (op_id == opcode.op.scope_put_var and !closureVarIsLexicalForAtom(ctx, atom_id)) {
            ref_op = opcode.op.put_var_ref;
        }
        return ref_op;
    }

    fn findVisibleParentVar(fd: *const function_def_mod.FunctionDef, atom_id: u32, visible_scope_level: i32) ?i32 {
        var i: usize = fd.vars.len;
        while (i > 0) {
            i -= 1;
            const vd = fd.vars[i];
            if (vd.var_name != atom_id) continue;
            if (vd.var_kind == .function_name or scopeChainContains(fd, visible_scope_level, vd.scope_level)) return @intCast(i);
        }
        return null;
    }

    const PrivateFieldResolution = struct {
        idx: u16,
        is_ref: bool,
        var_kind: function_def_mod.VarKind,
    };

    fn resolvePrivateField(ctx: *const JSContext, atom_id: u32, scope_level: i32) ?PrivateFieldResolution {
        const fd = ctx.function_def orelse return null;

        var scope_idx = scope_level;
        while (scope_idx >= 0 and @as(usize, @intCast(scope_idx)) < fd.scopes.len) {
            var idx: i32 = fd.scopes[@intCast(scope_idx)].first;
            while (idx >= 0 and @as(usize, @intCast(idx)) < fd.vars.len) {
                const vd = fd.vars[@intCast(idx)];
                if (vd.var_name == atom_id and isPrivateVarKind(vd.var_kind)) {
                    return .{ .idx = @intCast(idx), .is_ref = false, .var_kind = vd.var_kind };
                }
                idx = vd.scope_next;
            }
            scope_idx = fd.scopes[@intCast(scope_idx)].parent;
        }

        for (fd.closure_var, 0..) |cv, idx| {
            if (cv.var_name == atom_id and isPrivateVarKind(cv.var_kind)) {
                return .{ .idx = @intCast(idx), .is_ref = true, .var_kind = cv.var_kind };
            }
        }

        return null;
    }

    fn hasVisiblePrivateBoundName(ctx: *const JSContext, atom_id: u32) bool {
        const fd = ctx.function_def orelse return false;
        for (fd.private_bound_names) |private_atom| {
            if (private_atom == atom_id) return true;
        }
        for (fd.class_private_names) |private_atom| {
            if (private_atom == atom_id) return true;
        }
        return false;
    }

    fn canLowerPrivateInAsBoundSymbol(ctx: *const JSContext, op_id: u8, atom_id: u32) bool {
        return op_id == opcode.op.scope_in_private_field and hasVisiblePrivateBoundName(ctx, atom_id);
    }

    fn isPrivateVarKind(kind: function_def_mod.VarKind) bool {
        return switch (kind) {
            .private_field,
            .private_method,
            .private_getter,
            .private_setter,
            .private_getter_setter,
            => true,
            else => false,
        };
    }

    fn privateAccessorSize(ctx: *const JSContext, res: PrivateFieldResolution) usize {
        return if (res.is_ref) selectVarRefForm(ctx, opcode.op.get_var_ref, res.idx).size else selectLocForm(ctx, opcode.op.get_loc, res.idx).size;
    }

    fn writePrivateAccessor(ctx: *const JSContext, output: []u8, out_idx: *usize, res: PrivateFieldResolution) void {
        if (res.is_ref) {
            const form = selectVarRefForm(ctx, opcode.op.get_var_ref, res.idx);
            output[out_idx.*] = form.op_id;
            switch (form.operand_size) {
                0 => {},
                2 => std.mem.writeInt(u16, output[out_idx.* + 1 ..][0..2], res.idx, .little),
                else => unreachable,
            }
            out_idx.* += form.size;
            return;
        }

        const form = selectLocForm(ctx, opcode.op.get_loc, res.idx);
        output[out_idx.*] = form.op_id;
        switch (form.operand_size) {
            0 => {},
            1 => output[out_idx.* + 1] = @intCast(res.idx),
            2 => std.mem.writeInt(u16, output[out_idx.* + 1 ..][0..2], res.idx, .little),
            else => unreachable,
        }
        out_idx.* += form.size;
    }

    fn loweredPrivateFieldSize(ctx: *const JSContext, op_id: u8, res: PrivateFieldResolution) !usize {
        if (res.var_kind != .private_field and op_id != opcode.op.scope_in_private_field) return error.ClosureVarNotFound;
        const accessor_size = privateAccessorSize(ctx, res);
        return switch (op_id) {
            opcode.op.scope_get_private_field => accessor_size + 1,
            opcode.op.scope_get_private_field2 => 1 + accessor_size + 1,
            opcode.op.scope_put_private_field => accessor_size + 1,
            opcode.op.scope_in_private_field => accessor_size + 1,
            else => unreachable,
        };
    }

    fn writeLoweredPrivateField(ctx: *const JSContext, output: []u8, out_idx: *usize, op_id: u8, res: PrivateFieldResolution) !void {
        if (res.var_kind != .private_field and op_id != opcode.op.scope_in_private_field) return error.ClosureVarNotFound;
        if (op_id == opcode.op.scope_get_private_field2) {
            output[out_idx.*] = opcode.op.dup;
            out_idx.* += 1;
        }
        writePrivateAccessor(ctx, output, out_idx, res);
        output[out_idx.*] = lowerScopePrivateFieldOp(op_id);
        out_idx.* += 1;
    }

    /// True if the local slot `loc_idx` is captured by a closure — either the
    /// parser marked it (`ensureClosureChain` sets `VarDef.is_captured`, the
    /// `capture_var` equivalent of quickjs.c:33022) or a child FunctionDef
    /// references the slot through its closure_var table (retrofit capture
    /// paths that do not set the flag).
    pub fn localIsCaptured(fd: *const function_def_mod.FunctionDef, loc_idx: u16) bool {
        if (loc_idx < fd.vars.len and fd.vars[loc_idx].is_captured) return true;
        for (fd.child_list) |child| {
            for (child.closure_var) |cv| {
                if ((cv.closure_type == .local or cv.closure_type == .ref) and cv.var_idx == loc_idx) return true;
            }
        }
        return false;
    }

    /// Lexical vars with `.normal` kind get their TDZ bit re-armed on scope
    /// entry. Block function declarations are excluded: their inline
    /// `fclosure` init does not always clear the TDZ bit, so re-arming them
    /// would fault later reads (QuickJS re-instantiates them in
    /// `enter_scope` instead, quickjs.c:34488).
    fn varNeedsTdzRearm(vd: function_def_mod.VarDef) bool {
        return vd.is_lexical and vd.var_kind == .normal;
    }

    /// Byte size of the `enter_scope <scope>` lowering. Mirrors the QuickJS
    /// `OP_enter_scope` case (quickjs.c:34476): one `set_loc_uninitialized`
    /// per lexical var of the scope. In addition zjs emits one `close_loc`
    /// per captured var: QuickJS detaches captured stack slots at
    /// `OP_leave_scope` (quickjs.c:34510) and at break/continue jump sites
    /// (`close_scopes`, quickjs.c:27948); zjs's boxed-cell model instead
    /// detaches at scope *entry*, which dominates every re-entry path
    /// (normal back-edge, `continue`, jumps out of inner blocks) with a
    /// single emission site. This is observationally equivalent because
    /// local slots are never reused and a detached cell is only reachable
    /// through the closures that captured it.
    fn enterScopeRefreshSize(ctx: *const JSContext, scope: i32) usize {
        const fd = ctx.function_def orelse return 0;
        if (scope < 0 or @as(usize, @intCast(scope)) >= fd.scopes.len) return 0;
        var total: usize = 0;
        var idx = fd.scopes[@intCast(scope)].first;
        while (idx >= 0 and @as(usize, @intCast(idx)) < fd.vars.len) {
            const vd = fd.vars[@intCast(idx)];
            if (vd.scope_level != scope) break;
            if (localIsCaptured(fd, @intCast(idx))) total += 3;
            if (varNeedsTdzRearm(vd)) total += 3;
            idx = vd.scope_next;
        }
        return total;
    }

    /// Emit the `enter_scope` lowering described in `enterScopeRefreshSize`.
    fn writeEnterScopeRefresh(ctx: *const JSContext, output: []u8, out_idx: *usize, scope: i32) void {
        const fd = ctx.function_def orelse return;
        if (scope < 0 or @as(usize, @intCast(scope)) >= fd.scopes.len) return;
        var idx = fd.scopes[@intCast(scope)].first;
        while (idx >= 0 and @as(usize, @intCast(idx)) < fd.vars.len) {
            const vd = fd.vars[@intCast(idx)];
            if (vd.scope_level != scope) break;
            const loc_idx: u16 = @intCast(idx);
            if (localIsCaptured(fd, loc_idx)) {
                output[out_idx.*] = opcode.op.close_loc;
                std.mem.writeInt(u16, output[out_idx.* + 1 ..][0..2], loc_idx, .little);
                out_idx.* += 3;
            }
            if (varNeedsTdzRearm(vd)) {
                output[out_idx.*] = opcode.op.set_loc_uninitialized;
                std.mem.writeInt(u16, output[out_idx.* + 1 ..][0..2], loc_idx, .little);
                out_idx.* += 3;
            }
            idx = vd.scope_next;
        }
    }

    fn isAncestorLocalOrArg(ctx: *const JSContext, atom_id: u32) bool {
        const fd = ctx.function_def orelse return false;
        var maybe_parent = fd.parent;
        var depth: usize = 1;
        while (maybe_parent) |parent| {
            if (parent.findVar(atom_id) >= 0) return depth > 1;
            if (parent.findArg(atom_id) >= 0) return true;
            maybe_parent = parent.parent;
            depth += 1;
        }
        return false;
    }

    fn lowerScopeVarOpClosure(op_id: u8) u8 {
        return switch (op_id) {
            opcode.op.scope_get_var, opcode.op.scope_get_var_checkthis => opcode.op.get_var_ref_check,
            opcode.op.scope_get_var_undef => opcode.op.get_var_ref,
            opcode.op.scope_put_var => opcode.op.put_var_ref_check,
            opcode.op.scope_put_var_init => opcode.op.put_var_ref,
            else => unreachable,
        };
    }

    fn selectShortVarRef(base_op: u8, idx: u16) ShortLocForm {
        if (idx < 4) {
            const short_base: u8 = switch (base_op) {
                opcode.op.get_var_ref => opcode.op.get_var_ref0,
                opcode.op.put_var_ref => opcode.op.put_var_ref0,
                opcode.op.set_var_ref => opcode.op.set_var_ref0,
                else => return .{ .op_id = base_op, .size = 3, .operand_size = 2 },
            };
            return .{
                .op_id = short_base + @as(u8, @intCast(idx)),
                .size = 1,
                .operand_size = 0,
            };
        }
        return .{ .op_id = base_op, .size = 3, .operand_size = 2 };
    }

    fn selectVarRefForm(ctx: *const JSContext, base_op: u8, idx: u16) ShortLocForm {
        if (shortOpcodesEnabled(ctx)) return selectShortVarRef(base_op, idx);
        return .{ .op_id = base_op, .size = 3, .operand_size = 2 };
    }

    fn selectShortArg(base_op: u8, idx: u16) ShortLocForm {
        if (idx < 4) {
            const short_base: u8 = switch (base_op) {
                opcode.op.get_arg => opcode.op.get_arg0,
                opcode.op.put_arg => opcode.op.put_arg0,
                else => unreachable,
            };
            return .{
                .op_id = short_base + @as(u8, @intCast(idx)),
                .size = 1,
                .operand_size = 0,
            };
        }
        return .{ .op_id = base_op, .size = 3, .operand_size = 2 };
    }

    fn selectArgForm(ctx: *const JSContext, base_op: u8, idx: u16) ShortLocForm {
        if (shortOpcodesEnabled(ctx)) return selectShortArg(base_op, idx);
        return .{ .op_id = base_op, .size = 3, .operand_size = 2 };
    }

    fn lookupArg(ctx: *const JSContext, atom_id: u32) ?u16 {
        const fd = ctx.function_def orelse return null;
        const idx = fd.findArg(atom_id);
        if (idx < 0) return null;
        return @intCast(idx);
    }

    fn scopedLocalShadowsArg(ctx: *const JSContext, loc_idx: u16) bool {
        const fd = ctx.function_def orelse return false;
        if (loc_idx >= fd.vars.len) return false;
        const vd = fd.vars[loc_idx];
        return vd.is_lexical and vd.scope_level > 0;
    }

    fn lowerScopeVarOpArg(op_id: u8) ?u8 {
        return switch (op_id) {
            opcode.op.scope_get_var, opcode.op.scope_get_var_undef, opcode.op.scope_get_var_checkthis => opcode.op.get_arg,
            opcode.op.scope_put_var, opcode.op.scope_put_var_init => opcode.op.put_arg,
            else => null,
        };
    }

    /// If the FunctionDef has a `VarDef` for `atom_id`, return its var
    /// index. Mirrors a simplified `find_var` (`quickjs.c:23378`) — this
    /// scan ignores arg vs var split. Full scope-chain walking with closure
    /// classification remains tied to the eval / closure residual tests.
    fn lookupLocal(ctx: *const JSContext, atom_id: u32) ?u16 {
        const fd = ctx.function_def orelse return null;
        const idx = fd.findVar(atom_id);
        if (idx < 0) return null;
        return @intCast(idx);
    }

    /// Resolve a variable by walking the current function's scope at
    /// `scope_level`. Mirrors the local-only portion of
    /// `resolve_scope_var` (`quickjs.c:32377-32420`). Returns the local
    /// var index if found, or null otherwise.
    ///
    /// NOTE: parent-scope traversal + `get_closure_var` synthesis is still
    /// incomplete for the remaining eval / arguments interaction debts. We keep
    /// this fallback local-only where the caller has not provided closure metadata.
    fn resolveScopeVar(ctx: *const JSContext, atom_id: u32, scope_level: i32) ?u16 {
        const fd = ctx.function_def orelse return null;

        // Check the current scope level chain.
        var scope_idx = scope_level;
        while (scope_idx >= 0 and @as(usize, @intCast(scope_idx)) < fd.scopes.len) {
            var idx: i32 = fd.scopes[@intCast(scope_idx)].first;
            while (idx >= 0 and @as(usize, @intCast(idx)) < fd.vars.len) {
                const vd = &fd.vars[@intCast(idx)];
                if (vd.var_name == atom_id) return @intCast(idx);
                idx = vd.scope_next;
            }
            scope_idx = fd.scopes[@intCast(scope_idx)].parent;
        }

        // Fall back to a flat var scan for legacy callers that don't
        // record scope_level on every emission.
        if (fd.use_short_opcodes) {
            var flat_i: usize = fd.vars.len;
            while (flat_i > 0) {
                flat_i -= 1;
                const v = fd.vars[flat_i];
                if (v.var_name == atom_id and scopeChainContains(fd, scope_level, v.scope_level)) return @intCast(flat_i);
            }
            return null;
        }
        var flat_i: usize = fd.vars.len;
        while (flat_i > 0) {
            flat_i -= 1;
            const vd = fd.vars[flat_i];
            if (vd.var_name == atom_id and scopeChainContains(fd, scope_level, vd.scope_level)) return @intCast(flat_i);
        }
        return null;
    }

    const LocalOrArg = union(enum) {
        local: u16,
        arg: u16,
    };

    fn resolveLocalOrArg(ctx: *const JSContext, atom_id: u32, scope_level: i32) ?LocalOrArg {
        const local_idx = resolveScopeVar(ctx, atom_id, scope_level);
        if (local_idx) |idx| {
            if (scopedLocalShadowsArg(ctx, idx)) return .{ .local = idx };
        }
        if (lookupArg(ctx, atom_id)) |arg_idx| return .{ .arg = arg_idx };
        if (local_idx) |idx| return .{ .local = idx };
        return null;
    }

    /// True iff the local at `loc_idx` is a lexical (`let`/`const`) var
    /// — these need TDZ check variants. `var` slots return false (var
    /// is hoisted and starts as `undefined`, no TDZ).
    fn isLexicalLocal(ctx: *const JSContext, loc_idx: u16) bool {
        const fd = ctx.function_def orelse return false;
        if (loc_idx >= fd.vars.len) return false;
        return fd.vars[loc_idx].is_lexical;
    }

    fn isEvalNonLexicalLocal(ctx: *const JSContext, loc_idx: u16) bool {
        const fd = ctx.function_def orelse return false;
        if (!fd.is_eval and !bytecodeFunctionIsEval(ctx)) return false;
        if (loc_idx >= fd.vars.len) return false;
        return !fd.vars[loc_idx].is_lexical;
    }

    fn bytecodeFunctionIsEval(ctx: *const JSContext) bool {
        const name = ctx.atoms.name(ctx.function.name) orelse return false;
        return std.mem.eql(u8, name, "<eval>");
    }

    fn isConstLocal(ctx: *const JSContext, loc_idx: u16) bool {
        const fd = ctx.function_def orelse return false;
        if (loc_idx >= fd.vars.len) return false;
        return fd.vars[loc_idx].is_const;
    }

    fn localTdzEmittedAtDecl(ctx: *const JSContext, loc_idx: u16) bool {
        const fd = ctx.function_def orelse return false;
        if (loc_idx >= fd.vars.len) return false;
        return fd.vars[loc_idx].tdz_emitted_at_decl;
    }

    fn useUncheckedLexicalLocals(ctx: *const JSContext) bool {
        const fd = ctx.function_def orelse return false;
        return fd.use_short_opcodes;
    }

    /// Promote a Phase-1 var op to its TDZ-checked counterpart for
    /// lexical locals. Mirrors the `_check` family in QuickJS:
    /// - `scope_get_var` / `scope_get_var_undef` → `get_loc_check`
    ///   (throws ReferenceError if slot is uninitialised).
    /// - `scope_put_var` → `put_loc_check` (throws ReferenceError if
    ///   uninitialised, then stores).
    /// - `scope_put_var_init` → `put_loc_check_init` (stores and
    ///   clears the uninitialised flag).
    ///
    /// All check variants are 3-byte u16 forms (no short variants in
    /// QuickJS), so callers must NOT run `selectShortLoc` on the result.
    fn lowerScopeVarOpLexical(op_id: u8) u8 {
        return switch (op_id) {
            opcode.op.scope_get_var => opcode.op.get_loc_check,
            opcode.op.scope_get_var_undef => opcode.op.get_loc_check,
            opcode.op.scope_get_var_checkthis => opcode.op.get_loc_checkthis,
            opcode.op.scope_put_var => opcode.op.put_loc_check,
            opcode.op.scope_put_var_init => opcode.op.put_loc_check_init,
            else => unreachable,
        };
    }

    /// Returns true if `op_id`'s table format carries a leading atom
    /// operand at `bytes[1..5]`. Used to track the atom-operand list in
    /// lockstep with bytecode rewriting.
    fn hasAtomOperand(op_id: u8) bool {
        const fmt = opcode.formatOf(op_id);
        return fmt == .atom or fmt == .atom_u8 or fmt == .atom_u16 or
            fmt == .atom_label_u8 or fmt == .atom_label_u16;
    }

    /// Describes the location and kind of an absolute label operand
    /// embedded in the output bytecode. The parser emits jump targets as
    /// absolute u32 byte offsets (`emitForwardJump` / `emitBackwardJump`);
    /// when `resolve_variables` shrinks opcodes that precede those
    /// targets, the stored absolute values go stale. We collect each
    /// jump's operand position here during the main walk, then rewrite
    /// the targets at the end using the old→new pc map.
    const JumpSite = struct {
        /// Byte offset within the *output* buffer where the u32 target
        /// operand begins. Always points to a 4-byte little-endian field.
        operand_pos: usize,
    };

    const GLOBAL_REF_TAIL_NONE: u8 = 0;
    const GLOBAL_REF_TAIL_PUT: u8 = 1;
    const GLOBAL_REF_TAIL_DUP_PUT: u8 = 2;

    const GlobalRefPutTail = struct {
        pc: usize,
        original_size: usize,
        kind: u8,
    };

    /// Returns the byte offset within this opcode of the absolute u32
    /// label operand, or `null` if the format has no such operand. Only
    /// the `.label` format (u32 absolute target) is relevant for the
    /// interim pipeline — the parser does not yet emit label8 / label16
    /// short forms.
    fn labelOperandOffset(op_id: u8) ?usize {
        const fmt = opcode.formatOf(op_id);
        return switch (fmt) {
            .label => 1, // u32 target at bytes[1..5]
            .atom_label_u8, .atom_label_u16 => 5, // atom at bytes[1..5], target at bytes[5..9]
            else => null,
        };
    }

    fn globalRefPutTailReplacementSize(kind: u8) usize {
        return switch (kind) {
            GLOBAL_REF_TAIL_PUT => 3,
            GLOBAL_REF_TAIL_DUP_PUT => 4,
            else => 0,
        };
    }

    fn decodeGlobalRefPutTail(code: []const u8, pc: usize) ?GlobalRefPutTail {
        if (pc >= code.len) return null;
        if (code[pc] == opcode.op.put_ref_value) {
            return .{ .pc = pc, .original_size = 1, .kind = GLOBAL_REF_TAIL_PUT };
        }
        if (pc + 2 > code.len or code[pc + 1] != opcode.op.put_ref_value) return null;
        return switch (code[pc]) {
            opcode.op.insert3 => .{ .pc = pc, .original_size = 2, .kind = GLOBAL_REF_TAIL_DUP_PUT },
            opcode.op.nop, opcode.op.perm4, opcode.op.rot3l => .{ .pc = pc, .original_size = 2, .kind = GLOBAL_REF_TAIL_PUT },
            else => null,
        };
    }

    /// Instruction size for the Phase 1 input stream this pass consumes:
    /// temp opcodes in the overlap range size as their temp forms
    /// (`opcode.sizeOfPhase1`). Returns null when the stream cannot be
    /// decoded, stopping the tail scan.
    fn inputInstrSizeForRefTailScan(code: []const u8, pc: usize) ?usize {
        if (pc >= code.len) return null;
        const size: usize = opcode.sizeOfPhase1(code[pc]);
        if (size == 0 or pc + size > code.len) return null;
        return size;
    }

    fn stopsGlobalRefTailScan(op_id: u8) bool {
        if (op_id == opcode.op.scope_make_ref or
            op_id == opcode.op.scope_get_ref or
            op_id == opcode.op.scope_delete_var or
            op_id == opcode.op.eval or
            op_id == opcode.op.apply_eval or
            op_id == opcode.op.@"return" or
            op_id == opcode.op.return_undef or
            op_id == opcode.op.return_async or
            op_id == opcode.op.throw or
            op_id == opcode.op.goto or
            op_id == opcode.op.goto8 or
            op_id == opcode.op.goto16 or
            op_id == opcode.op.if_false or
            op_id == opcode.op.if_false8 or
            op_id == opcode.op.if_true or
            op_id == opcode.op.if_true8 or
            op_id == opcode.op.@"catch" or
            op_id == opcode.op.label or
            op_id == opcode.op.gosub or
            op_id == opcode.op.ret or
            op_id == opcode.op.call or
            op_id == opcode.op.call0 or
            op_id == opcode.op.call1 or
            op_id == opcode.op.call2 or
            op_id == opcode.op.call3 or
            op_id == opcode.op.call_method or
            op_id == opcode.op.tail_call or
            op_id == opcode.op.tail_call_method)
        {
            return true;
        }
        return false;
    }

    fn findGlobalRefPutTail(code: []const u8, make_ref_pc: usize) ?GlobalRefPutTail {
        if (make_ref_pc + 11 > code.len or code[make_ref_pc] != opcode.op.scope_make_ref) return null;
        const label_pc = std.mem.readInt(u32, code[make_ref_pc + 5 ..][0..4], .little);
        if (label_pc > make_ref_pc and label_pc < code.len) {
            if (decodeGlobalRefPutTail(code, @intCast(label_pc))) |tail| return tail;
        }

        var pc = make_ref_pc + 11;
        var steps: usize = 0;
        while (pc < code.len and steps < 16) : (steps += 1) {
            if (decodeGlobalRefPutTail(code, pc)) |tail| return tail;
            const op_id = code[pc];
            if (stopsGlobalRefTailScan(op_id)) return null;
            const size = inputInstrSizeForRefTailScan(code, pc) orelse return null;
            pc += size;
        }
        return null;
    }

    fn scopeMakeRefResolvesToGlobal(ctx: *const JSContext, atom_id: u32, scope_level: i16) bool {
        if (lookupTopLevelModuleLexicalClosureVar(ctx, atom_id, scope_level) != null) return false;
        if (resolveLocalOrArg(ctx, atom_id, scope_level) != null) return false;
        if (lookupClosureVar(ctx, atom_id) != null) return false;
        return true;
    }

    fn functionIsStrict(ctx: *const JSContext) bool {
        if (ctx.function_def) |fd| return fd.is_strict_mode;
        return ctx.function.flags.is_strict or ctx.function.flags.runtime_strict;
    }

    fn functionDeclaresGlobalVar(ctx: *const JSContext, atom_id: u32) bool {
        const fd = ctx.function_def orelse return false;
        for (fd.global_vars) |global_var| {
            if (global_var.var_name == atom_id) return true;
        }
        return false;
    }

    fn functionHasGlobalFunctionVarCpool(fd: *const function_def_mod.FunctionDef, cpool_idx: i32) bool {
        if (cpool_idx < 0) return false;
        for (fd.global_vars) |global_var| {
            if (global_var.is_lexical or global_var.cpool_idx != cpool_idx) continue;
            return true;
        }
        return false;
    }

    fn canOptimizeGlobalRefPutTail(ctx: *const JSContext, atom_id: u32) bool {
        return !functionIsStrict(ctx) or functionDeclaresGlobalVar(ctx, atom_id);
    }

    pub fn run(ctx: *JSContext) !void {
        const func = ctx.function;

        // First pass: compute output size (in bytes) and atom count.
        // Temporary scope-var opcodes shrink from 7 bytes to 5 bytes. The
        // enter_scope / leave_scope pair (3 bytes each) is dropped. All
        // other opcodes copy through at their table-reported size.
        //
        // We also count the number of jump opcodes (format `.label`) so
        // we can size the pc-map and the jump-site list ahead of the
        // second pass.
        //
        // Count lexical locals so we can size the TDZ prologue. Each
        // lexical slot needs an `OP_set_loc_uninitialized <u16 idx>`
        // (3 bytes) emitted before the body so `get_loc_check` knows
        // the slot is in TDZ. `var` slots don't need this — they're
        // already undefined.
        var prologue_lexical_count: usize = 0;
        if (ctx.function_def) |fd| {
            for (fd.vars) |v| {
                if (v.is_lexical and !v.tdz_emitted_at_decl) prologue_lexical_count += 1;
            }
        }
        const prologue_size: usize = prologue_lexical_count * 3;
        var top_level_closure_init_size: usize = 0;
        var child_decl_init_size: usize = 0;
        if (ctx.function_def) |fd| {
            for (fd.child_list) |child| {
                if (child.emit_top_level_closure_init) {
                    if (functionHasGlobalFunctionVarCpool(fd, child.parent_cpool_idx)) continue;
                    if (child.parent_cpool_idx < 0 or child.top_level_closure_var_idx < 0) continue;
                    top_level_closure_init_size += try fclosureEncodingSize(child.parent_cpool_idx) + selectVarRefForm(ctx, opcode.op.put_var_ref, @intCast(child.top_level_closure_var_idx)).size;
                    continue;
                }
                if (child.child_decl_emit_inline) continue;
                if (child.func_type != .statement) continue;
                const arg_idx_i = if (child.child_decl_force_local_init) -1 else fd.findArg(child.func_name);
                const form = if (arg_idx_i >= 0)
                    selectArgForm(ctx, opcode.op.put_arg, @intCast(arg_idx_i))
                else blk: {
                    const var_idx_i = if (child.child_decl_var_idx >= 0) child.child_decl_var_idx else fd.findVar(child.func_name);
                    if (var_idx_i < 0) continue;
                    break :blk selectLocForm(ctx, if (child.child_decl_init_keep_value) opcode.op.set_loc else opcode.op.put_loc, @intCast(var_idx_i));
                };
                child_decl_init_size += try fclosureEncodingSize(child.parent_cpool_idx) + form.size;
            }
        }

        const init_bypassed = if (ctx.function_def) |fd| blk: {
            const bytes = try ctx.memory.alloc(bool, fd.vars.len);
            // The block below allocates and can fail with InvalidBytecode; the
            // owning `defer` only binds after `break :blk`, so error exits inside
            // the block must release `bytes` here (found by test-oom injection).
            errdefer if (bytes.len != 0) ctx.memory.free(bool, bytes);
            @memset(bytes, false);

            // Pre-pass: find init_pc for each var and check if any forward jump bypasses it
            const init_pc = try ctx.memory.alloc(?usize, fd.vars.len);
            @memset(init_pc, null);
            defer ctx.memory.free(?usize, init_pc);

            // First scan to find init_pc
            var pc: usize = 0;
            var scan_atom_idx: usize = 0;
            while (pc < func.code.len) {
                const op = func.code[pc];
                if (op == opcode.op.eval) {
                    if (pc + 5 > func.code.len) return error.InvalidBytecode;
                    pc += 5;
                } else if (op == opcode.op.apply_eval) {
                    if (pc + 2 > func.code.len) return error.InvalidBytecode;
                    pc += 2;
                } else if (op == opcode.op.line_num) {
                    if (pc + 5 > func.code.len) return error.InvalidBytecode;
                    pc += 5;
                } else if (isScopeVarOp(op)) {
                    if (pc + 7 > func.code.len) return error.InvalidBytecode;
                    const atom_id = std.mem.readInt(u32, func.code[pc + 1 ..][0..4], .little);
                    const scope_level = std.mem.readInt(i16, func.code[pc + 5 ..][0..2], .little);
                    if (op == opcode.op.scope_put_var_init) {
                        if (resolveLocalOrArg(ctx, atom_id, scope_level)) |binding| switch (binding) {
                            .local => |loc_idx| {
                                if (loc_idx < fd.vars.len) {
                                    if (init_pc[loc_idx] == null) {
                                        init_pc[loc_idx] = pc;
                                    }
                                }
                            },
                            else => {},
                        };
                    }
                    scan_atom_idx += 1;
                    pc += 7;
                } else if (isScopePrivateFieldAt(func, pc, scan_atom_idx)) {
                    if (pc + 7 > func.code.len) return error.InvalidBytecode;
                    scan_atom_idx += 1;
                    pc += 7;
                } else if (op == opcode.op.scope_make_ref) {
                    if (pc + 11 > func.code.len) return error.InvalidBytecode;
                    scan_atom_idx += 1;
                    pc += 11;
                } else if (isScopeRefOp(op)) {
                    if (pc + 7 > func.code.len) return error.InvalidBytecode;
                    scan_atom_idx += 1;
                    pc += 7;
                } else if (op == opcode.op.enter_scope or op == opcode.op.leave_scope) {
                    if (pc + 3 > func.code.len) return error.InvalidBytecode;
                    pc += 3;
                } else {
                    const size = instrSize(op);
                    if (pc + size > func.code.len) return error.InvalidBytecode;
                    if (hasAtomOperand(op)) {
                        scan_atom_idx += 1;
                    }
                    pc += size;
                }
            }

            // Second scan to check for bypassing forward jumps
            pc = 0;
            scan_atom_idx = 0;
            while (pc < func.code.len) {
                const op = func.code[pc];
                var size: usize = undefined;
                var is_scope_var = false;

                if (op == opcode.op.eval) {
                    size = 5;
                } else if (op == opcode.op.apply_eval) {
                    size = 2;
                } else if (op == opcode.op.line_num) {
                    size = 5;
                } else if (isScopeVarOp(op)) {
                    size = 7;
                    is_scope_var = true;
                } else if (isScopePrivateFieldAt(func, pc, scan_atom_idx)) {
                    size = 7;
                    scan_atom_idx += 1;
                } else if (op == opcode.op.scope_make_ref) {
                    size = 11;
                    scan_atom_idx += 1;
                } else if (isScopeRefOp(op)) {
                    size = 7;
                    scan_atom_idx += 1;
                } else if (op == opcode.op.enter_scope or op == opcode.op.leave_scope) {
                    size = 3;
                } else {
                    size = instrSize(op);
                    if (hasAtomOperand(op)) {
                        scan_atom_idx += 1;
                    }
                }

                if (pc + size > func.code.len) return error.InvalidBytecode;

                if (labelOperandOffset(op)) |offset| {
                    if (pc + offset + 4 <= func.code.len) {
                        const old_target = std.mem.readInt(u32, func.code[pc + offset ..][0..4], .little);
                        if (old_target > pc) { // forward jump
                            for (fd.vars, 0..) |_, loc_idx| {
                                if (init_pc[loc_idx]) |ipc| {
                                    if (pc < ipc and old_target > ipc) {
                                        bytes[loc_idx] = true;
                                    }
                                }
                            }
                        }
                    }
                }

                if (is_scope_var) {
                    scan_atom_idx += 1;
                }
                pc += size;
            }

            break :blk bytes;
        } else @as([]bool, &.{});
        defer if (init_bypassed.len != 0) ctx.memory.free(bool, init_bypassed);

        var output_size: usize = top_level_closure_init_size + child_decl_init_size + prologue_size;
        var output_atom_count: usize = 0;
        var jump_count: usize = 0;
        var i: usize = 0;
        var scan_atom_idx: usize = 0;
        var global_ref_tail_atoms: []atom.Atom = if (func.code.len == 0) &.{} else try ctx.memory.alloc(atom.Atom, func.code.len);
        defer if (global_ref_tail_atoms.len != 0) ctx.memory.free(atom.Atom, global_ref_tail_atoms);
        var global_ref_tail_kinds: []u8 = if (func.code.len == 0) &.{} else try ctx.memory.alloc(u8, func.code.len);
        defer if (global_ref_tail_kinds.len != 0) ctx.memory.free(u8, global_ref_tail_kinds);
        if (global_ref_tail_atoms.len != 0) @memset(global_ref_tail_atoms, atom.null_atom);
        if (global_ref_tail_kinds.len != 0) @memset(global_ref_tail_kinds, GLOBAL_REF_TAIL_NONE);
        const var_initialized = if (ctx.function_def) |fd| blk: {
            const bytes = try ctx.memory.alloc(bool, fd.vars.len);
            @memset(bytes, false);
            break :blk bytes;
        } else @as([]bool, &.{});
        defer if (var_initialized.len != 0) ctx.memory.free(bool, var_initialized);
        while (i < func.code.len) {
            const op = func.code[i];
            if (global_ref_tail_kinds.len != 0 and global_ref_tail_kinds[i] != GLOBAL_REF_TAIL_NONE) {
                output_size += globalRefPutTailReplacementSize(global_ref_tail_kinds[i]);
                i += (decodeGlobalRefPutTail(func.code, i) orelse return error.InvalidBytecode).original_size;
                continue;
            }
            // Handle OP_eval and OP_apply_eval scope_idx rewrite (mirrors quickjs.c:33690-33702)
            if (op == opcode.op.eval) {
                if (i + 5 > func.code.len) return error.InvalidBytecode;
                // Format: call_argc (u16) + scope_idx (u16)
                _ = std.mem.readInt(u16, func.code[i + 1 ..][0..2], .little); // call_argc
                const raw_scope_idx = std.mem.readInt(u16, func.code[i + 3 ..][0..2], .little);
                const scope_idx = raw_scope_idx & EVAL_SCOPE_INDEX_MASK;

                // Rewrite scope_idx to s->scopes[scope].first + 1
                const fd = ctx.function_def orelse {
                    // If no FunctionDef, copy through as-is
                    output_size += 5;
                    i += 5;
                    continue;
                };
                if (@as(usize, @intCast(scope_idx)) < fd.scopes.len) {
                    // Direct-eval-visible bindings are materialized by the parser
                    // and VM eval overlay; this pass only remaps the scope index.
                    _ = fd.scopes[@intCast(scope_idx)].first + 1; // new_scope_idx
                    output_size += 5;
                    i += 5;
                    continue;
                } else {
                    // Invalid scope_idx, copy through as-is
                    output_size += 5;
                    i += 5;
                    continue;
                }
            } else if (op == opcode.op.apply_eval) {
                if (i + 2 > func.code.len) return error.InvalidBytecode;
                // Format: scope_idx (u16)
                const raw_scope_idx = std.mem.readInt(u16, func.code[i + 1 ..][0..2], .little);
                const scope_idx = raw_scope_idx & EVAL_SCOPE_INDEX_MASK;

                // Rewrite scope_idx to s->scopes[scope].first + 1
                const fd = ctx.function_def orelse {
                    // If no FunctionDef, copy through as-is
                    output_size += 2;
                    i += 2;
                    continue;
                };
                if (@as(usize, @intCast(scope_idx)) < fd.scopes.len) {
                    // Direct-eval-visible bindings are materialized by the parser
                    // and VM eval overlay; this pass only remaps the scope index.
                    _ = fd.scopes[@intCast(scope_idx)].first + 1; // new_scope_idx
                    output_size += 2;
                    i += 2;
                    continue;
                } else {
                    // Invalid scope_idx, copy through as-is
                    output_size += 2;
                    i += 2;
                    continue;
                }
            } else if (op == opcode.op.line_num) {
                if (i + 5 > func.code.len) return error.InvalidBytecode;
                i += 5;
                continue;
            } else if (isScopeVarOp(op)) {
                if (i + 7 > func.code.len) return error.InvalidBytecode;
                const atom_id = std.mem.readInt(u32, func.code[i + 1 ..][0..4], .little);
                const scope_level = std.mem.readInt(i16, func.code[i + 5 ..][0..2], .little);
                if (scope_level < 0) {
                    output_size += 3;
                } else if (lookupTopLevelModuleLexicalClosureVar(ctx, atom_id, scope_level)) |ref_idx| {
                    const ref_op = lowerScopeVarOpForClosure(ctx, atom_id, ref_idx, op);
                    const form = selectVarRefForm(ctx, ref_op, ref_idx);
                    output_size += form.size;
                } else if (resolveLocalOrArg(ctx, atom_id, scope_level)) |binding| switch (binding) {
                    .arg => |arg_idx| {
                        const arg_op = lowerScopeVarOpArg(op).?;
                        const form = selectArgForm(ctx, arg_op, arg_idx);
                        output_size += form.size;
                    },
                    .local => |loc_idx| {
                        if (preferTopLevelModuleClassBinding(ctx, atom_id, loc_idx)) |ref_idx| {
                            const ref_op = lowerScopeVarOpForClosure(ctx, atom_id, ref_idx, op);
                            const form = selectVarRefForm(ctx, ref_op, ref_idx);
                            output_size += form.size;
                        } else if (blk: {
                            if (!isLexicalLocal(ctx, loc_idx)) break :blk false;
                            if (op == opcode.op.scope_get_var_checkthis) break :blk true;
                            if (!useUncheckedLexicalLocals(ctx)) break :blk true;
                            if (op == opcode.op.scope_put_var_init) {
                                break :blk isConstLocal(ctx, loc_idx);
                            } else if (op == opcode.op.scope_put_var) {
                                if (isConstLocal(ctx, loc_idx)) break :blk true;
                                const init_safe = var_initialized[loc_idx] and !init_bypassed[loc_idx];
                                break :blk !init_safe and localTdzEmittedAtDecl(ctx, loc_idx);
                            } else {
                                const init_safe = var_initialized[loc_idx] and !init_bypassed[loc_idx];
                                break :blk !init_safe and (isConstLocal(ctx, loc_idx) or localTdzEmittedAtDecl(ctx, loc_idx));
                            }
                        }) {
                            // Lexical: 3-byte TDZ-check variant.
                            output_size += 3;
                        } else {
                            // var: shortest form (1, 2, or 3 bytes).
                            const local_op = lowerScopeVarOpLocal(op);
                            const form = selectLocForm(ctx, local_op, loc_idx);
                            output_size += form.size;
                        }
                        if (op == opcode.op.scope_put_var_init and loc_idx < var_initialized.len) {
                            var_initialized[loc_idx] = true;
                        }
                    },
                } else if (lookupClosureVar(ctx, atom_id)) |ref_idx| {
                    const ref_op = lowerScopeVarOpForClosure(ctx, atom_id, ref_idx, op);
                    const form = selectVarRefForm(ctx, ref_op, ref_idx);
                    output_size += form.size;
                } else {
                    // Global: QuickJS `var_ref` u16 form.
                    output_size += 3;
                }
                scan_atom_idx += 1;
                i += 7;
            } else if (isScopePrivateFieldAt(func, i, scan_atom_idx)) {
                const atom_id = std.mem.readInt(u32, func.code[i + 1 ..][0..4], .little);
                const scope_level = std.mem.readInt(i16, func.code[i + 5 ..][0..2], .little);
                if (resolvePrivateField(ctx, atom_id, scope_level)) |res| {
                    output_size += try loweredPrivateFieldSize(ctx, op, res);
                } else if (canLowerPrivateInAsBoundSymbol(ctx, op, atom_id)) {
                    output_size += 6; // private_symbol <atom> ; private_in
                    output_atom_count += 1;
                } else {
                    return error.ClosureVarNotFound;
                }
                scan_atom_idx += 1;
                i += 7;
            } else if (op == opcode.op.scope_make_ref) {
                if (i + 11 > func.code.len) return error.InvalidBytecode;
                const atom_id = std.mem.readInt(u32, func.code[i + 1 ..][0..4], .little);
                const scope_level = std.mem.readInt(i16, func.code[i + 9 ..][0..2], .little);
                if (canOptimizeGlobalRefPutTail(ctx, atom_id) and scopeMakeRefResolvesToGlobal(ctx, atom_id, scope_level)) {
                    if (findGlobalRefPutTail(func.code, i)) |tail| {
                        if (tail.pc < global_ref_tail_kinds.len and global_ref_tail_kinds[tail.pc] == GLOBAL_REF_TAIL_NONE) {
                            global_ref_tail_atoms[tail.pc] = atom_id;
                            global_ref_tail_kinds[tail.pc] = tail.kind;
                            scan_atom_idx += 1;
                            i += 11;
                            continue;
                        }
                    }
                }
                if (resolveLocalOrArg(ctx, atom_id, scope_level) != null) {
                    output_size += 7;
                    output_atom_count += 1;
                } else if (lookupClosureVar(ctx, atom_id) != null) {
                    output_size += 7;
                    output_atom_count += 1;
                } else {
                    output_size += 5;
                    output_atom_count += 1;
                }
                scan_atom_idx += 1;
                i += 11;
            } else if (isScopeRefOp(op)) {
                // scope_delete_var / scope_get_ref: 7-byte atom_u16.
                if (i + 7 > func.code.len) return error.InvalidBytecode;
                const atom_id = std.mem.readInt(u32, func.code[i + 1 ..][0..4], .little);
                const scope_level = std.mem.readInt(i16, func.code[i + 5 ..][0..2], .little);
                if (op == opcode.op.scope_delete_var) {
                    if (resolveScopeVar(ctx, atom_id, scope_level)) |loc_idx| {
                        if (isEvalNonLexicalLocal(ctx, loc_idx)) {
                            // Eval-created `var` bindings are deletable environment
                            // bindings; keep a dynamic delete so the VM can remove
                            // the var-ref cell.
                            output_size += 5;
                            output_atom_count += 1;
                        } else {
                            // Local var: delete returns false (1 byte).
                            output_size += 1;
                        }
                    } else if (lookupArg(ctx, atom_id) != null or lookupClosureVar(ctx, atom_id) != null) {
                        // Local / arg / closure var: delete returns false (1 byte).
                        output_size += 1;
                    } else {
                        // Global: OP_delete_var <atom> (5 bytes + 1 atom).
                        output_size += 5;
                        output_atom_count += 1;
                    }
                } else if (op == opcode.op.scope_get_ref) {
                    if (resolveLocalOrArg(ctx, atom_id, scope_level)) |binding| switch (binding) {
                        .arg => |arg_idx| {
                            // OP_undefined (1) + OP_get_arg/short (1-3).
                            const form = selectArgForm(ctx, opcode.op.get_arg, arg_idx);
                            output_size += 1 + form.size;
                        },
                        .local => |loc_idx| {
                            // OP_undefined (1) + OP_get_loc/short (1-3).
                            if (isLexicalLocal(ctx, loc_idx)) {
                                output_size += 1 + 3; // undefined + get_loc_check
                            } else {
                                const form = selectLocForm(ctx, opcode.op.get_loc, loc_idx);
                                output_size += 1 + form.size;
                            }
                        },
                    } else if (lookupClosureVar(ctx, atom_id)) |ref_idx| {
                        // OP_undefined (1) + OP_get_var_ref (1-3).
                        const form = selectVarRefForm(ctx, opcode.op.get_var_ref, ref_idx);
                        output_size += 1 + form.size;
                    } else {
                        // Global: OP_undefined (1) + OP_get_var (3).
                        output_size += 1 + 3;
                    }
                }
                scan_atom_idx += 1;
                i += 7;
            } else if (op == opcode.op.enter_scope or op == opcode.op.leave_scope) {
                if (i + 3 > func.code.len) return error.InvalidBytecode;
                if (op == opcode.op.enter_scope) {
                    const scope = std.mem.readInt(u16, func.code[i + 1 ..][0..2], .little);
                    output_size += enterScopeRefreshSize(ctx, scope);
                }
                i += 3;
            } else {
                const size = instrSize(op);
                output_size += size;
                if (hasAtomOperand(op)) {
                    output_atom_count += 1;
                    scan_atom_idx += 1;
                }
                if (labelOperandOffset(op) != null) jump_count += 1;
                i += size;
            }
        }

        // Keep empty outputs as inert slices so later bytecode ownership has a
        // stable representation without touching allocator accounting.
        const output: []u8 = if (output_size == 0)
            &.{}
        else
            try ctx.memory.alloc(u8, output_size);
        var output_owned = output.len != 0;
        errdefer if (output_owned) ctx.memory.free(u8, output);
        const output_atoms: []atom.Atom = if (output_atom_count == 0)
            &.{}
        else
            try ctx.memory.alloc(atom.Atom, output_atom_count);
        var output_atoms_owned = output_atoms.len != 0;
        var out_atom_idx: usize = 0;
        errdefer if (output_atoms_owned) {
            for (output_atoms[0..out_atom_idx]) |atom_id| ctx.atoms.free(atom_id);
            ctx.memory.free(atom.Atom, output_atoms);
        };

        // Scratch arrays for pc-map and jump sites (use raw allocator so
        // we don't pollute the MemoryAccount counters; these are freed
        // before `run` returns).
        const allocator = ctx.memory.allocator;
        // `pc_map[old_pc + 1]` holds the new pc that the instruction
        // previously at `old_pc` now starts at. Entry `pc_map[0]` is
        // unused (0 maps to 0 trivially). Dropped instructions (the
        // enter/leave scope pair) map their old pc to the new pc of the
        // *next* kept instruction, so a jump that targets them still
        // lands on a valid instruction boundary.
        const pc_map = try allocator.alloc(usize, func.code.len + 1);
        defer allocator.free(pc_map);
        @memset(pc_map, 0);
        const jump_sites = try allocator.alloc(JumpSite, jump_count);
        defer allocator.free(jump_sites);

        // Second pass: walk input + atom_operands in lockstep. Every
        // opcode with an atom format consumes one entry from the input
        // `func.atom_operands` list; we re-retain it for `output_atoms`
        // so refcounts stay balanced. Jump operand sites are recorded
        // into `jump_sites` for post-pass patching.
        var out_idx: usize = 0;
        var in_atom_idx: usize = 0;
        var out_jump_idx: usize = 0;

        // Emit the TDZ prologue: one `set_loc_uninitialized <idx>` per
        // lexical local. This marks the slots so `get_loc_check` /
        // `put_loc_check` throw `ReferenceError` until
        // `put_loc_check_init` runs.
        if (ctx.function_def) |fd| {
            var var_idx = fd.vars.len;
            while (var_idx > 0) {
                var_idx -= 1;
                const v = fd.vars[var_idx];
                if (!v.is_lexical or v.tdz_emitted_at_decl) continue;
                output[out_idx] = opcode.op.set_loc_uninitialized;
                std.mem.writeInt(u16, output[out_idx + 1 ..][0..2], @intCast(var_idx), .little);
                out_idx += 3;
            }
        }

        if (ctx.function_def) |fd| {
            for (fd.child_list) |child| {
                if (child.emit_top_level_closure_init) {
                    if (functionHasGlobalFunctionVarCpool(fd, child.parent_cpool_idx)) continue;
                    if (child.parent_cpool_idx < 0 or child.top_level_closure_var_idx < 0) return error.InvalidBytecode;
                    try emitFClosure(output, &out_idx, child.parent_cpool_idx);
                    const ref_idx: u16 = @intCast(child.top_level_closure_var_idx);
                    const form = selectVarRefForm(ctx, opcode.op.put_var_ref, ref_idx);
                    output[out_idx] = form.op_id;
                    switch (form.operand_size) {
                        0 => {},
                        2 => std.mem.writeInt(u16, output[out_idx + 1 ..][0..2], ref_idx, .little),
                        else => unreachable,
                    }
                    out_idx += form.size;
                    continue;
                }
                if (child.child_decl_emit_inline) continue;
                if (child.func_type != .statement) continue;
                if (child.parent_cpool_idx < 0) return error.InvalidBytecode;
                try emitFClosure(output, &out_idx, child.parent_cpool_idx);
                const arg_idx_i = if (child.child_decl_force_local_init) -1 else fd.findArg(child.func_name);
                const form = if (arg_idx_i >= 0)
                    selectArgForm(ctx, opcode.op.put_arg, @intCast(arg_idx_i))
                else blk: {
                    const var_idx_i = if (child.child_decl_var_idx >= 0) child.child_decl_var_idx else fd.findVar(child.func_name);
                    if (var_idx_i < 0) return error.InvalidBytecode;
                    const var_idx: u16 = @intCast(var_idx_i);
                    break :blk selectLocForm(ctx, if (child.child_decl_init_keep_value) opcode.op.set_loc else opcode.op.put_loc, var_idx);
                };
                const binding_idx: u16 = if (arg_idx_i >= 0) @intCast(arg_idx_i) else blk: {
                    const var_idx_i = if (child.child_decl_var_idx >= 0) child.child_decl_var_idx else fd.findVar(child.func_name);
                    if (var_idx_i < 0) return error.InvalidBytecode;
                    break :blk @intCast(var_idx_i);
                };
                output[out_idx] = form.op_id;
                switch (form.operand_size) {
                    0 => {},
                    1 => output[out_idx + 1] = @intCast(binding_idx),
                    2 => std.mem.writeInt(u16, output[out_idx + 1 ..][0..2], binding_idx, .little),
                    else => unreachable,
                }
                out_idx += form.size;
            }
        }

        const var_initialized_pass2 = if (ctx.function_def) |fd| blk: {
            const bytes = try ctx.memory.alloc(bool, fd.vars.len);
            @memset(bytes, false);
            break :blk bytes;
        } else @as([]bool, &.{});
        defer if (var_initialized_pass2.len != 0) ctx.memory.free(bool, var_initialized_pass2);

        i = 0;
        while (i < func.code.len) {
            // pc_map for input pc i maps to output pc out_idx (after the
            // global_vars pre-pass and TDZ prologue), so jumps that reference
            // the post-prologue body resolve correctly.
            pc_map[i] = out_idx;
            const op = func.code[i];
            if (global_ref_tail_kinds.len != 0 and global_ref_tail_kinds[i] != GLOBAL_REF_TAIL_NONE) {
                const atom_id = global_ref_tail_atoms[i];
                if (global_ref_tail_kinds[i] == GLOBAL_REF_TAIL_DUP_PUT) {
                    output[out_idx] = opcode.op.dup;
                    out_idx += 1;
                }
                try emitGlobalVarOp(ctx, output, &out_idx, opcode.op.put_var, atom_id);
                i += (decodeGlobalRefPutTail(func.code, i) orelse return error.InvalidBytecode).original_size;
                continue;
            }
            // Handle OP_eval and OP_apply_eval scope_idx rewrite (mirrors quickjs.c:33690-33702)
            if (op == opcode.op.eval) {
                if (i + 5 > func.code.len) return error.InvalidBytecode;
                const call_argc = std.mem.readInt(u16, func.code[i + 1 ..][0..2], .little);
                const raw_scope_idx = std.mem.readInt(u16, func.code[i + 3 ..][0..2], .little);
                const scope_idx = raw_scope_idx & EVAL_SCOPE_INDEX_MASK;
                const scope_flags = raw_scope_idx & ~EVAL_SCOPE_INDEX_MASK;

                const fd = ctx.function_def orelse {
                    // If no FunctionDef, copy through as-is
                    @memcpy(output[out_idx .. out_idx + 5], func.code[i .. i + 5]);
                    out_idx += 5;
                    i += 5;
                    continue;
                };
                if (@as(usize, @intCast(scope_idx)) < fd.scopes.len) {
                    // Direct-eval-visible bindings are materialized by the parser
                    // and VM eval overlay; this pass only remaps the scope index.
                    const new_scope_idx: u16 = @intCast(fd.scopes[@intCast(scope_idx)].first + 1);
                    output[out_idx] = opcode.op.eval;
                    std.mem.writeInt(u16, output[out_idx + 1 ..][0..2], call_argc, .little);
                    std.mem.writeInt(u16, output[out_idx + 3 ..][0..2], new_scope_idx | scope_flags, .little);
                    out_idx += 5;
                    i += 5;
                    continue;
                } else {
                    // Invalid scope_idx, copy through as-is
                    @memcpy(output[out_idx .. out_idx + 5], func.code[i .. i + 5]);
                    out_idx += 5;
                    i += 5;
                    continue;
                }
            } else if (op == opcode.op.apply_eval) {
                if (i + 2 > func.code.len) return error.InvalidBytecode;
                const raw_scope_idx = std.mem.readInt(u16, func.code[i + 1 ..][0..2], .little);
                const scope_idx = raw_scope_idx & EVAL_SCOPE_INDEX_MASK;
                const scope_flags = raw_scope_idx & ~EVAL_SCOPE_INDEX_MASK;

                const fd = ctx.function_def orelse {
                    // If no FunctionDef, copy through as-is
                    @memcpy(output[out_idx .. out_idx + 2], func.code[i .. i + 2]);
                    out_idx += 2;
                    i += 2;
                    continue;
                };
                if (@as(usize, @intCast(scope_idx)) < fd.scopes.len) {
                    // Direct-eval-visible bindings are materialized by the parser
                    // and VM eval overlay; this pass only remaps the scope index.
                    const new_scope_idx: u16 = @intCast(fd.scopes[@intCast(scope_idx)].first + 1);
                    output[out_idx] = opcode.op.apply_eval;
                    std.mem.writeInt(u16, output[out_idx + 1 ..][0..2], new_scope_idx | scope_flags, .little);
                    out_idx += 2;
                    i += 2;
                    continue;
                } else {
                    // Invalid scope_idx, copy through as-is
                    @memcpy(output[out_idx .. out_idx + 2], func.code[i .. i + 2]);
                    out_idx += 2;
                    i += 2;
                    continue;
                }
            } else if (op == opcode.op.line_num) {
                if (i + 5 > func.code.len) return error.InvalidBytecode;
                i += 5;
                continue;
            } else if (isScopeVarOp(op)) {
                if (i + 7 > func.code.len) return error.InvalidBytecode;
                const atom_id = std.mem.readInt(u32, func.code[i + 1 ..][0..4], .little);
                const scope_level = std.mem.readInt(i16, func.code[i + 5 ..][0..2], .little);
                if (scope_level < 0) {
                    try emitGlobalVarOp(ctx, output, &out_idx, lowerScopeVarOpGlobal(op), atom_id);
                    in_atom_idx += 1;
                } else if (lookupTopLevelModuleLexicalClosureVar(ctx, atom_id, scope_level)) |ref_idx| {
                    const ref_op = lowerScopeVarOpForClosure(ctx, atom_id, ref_idx, op);
                    const form = selectVarRefForm(ctx, ref_op, ref_idx);
                    output[out_idx] = form.op_id;
                    switch (form.operand_size) {
                        0 => {},
                        2 => std.mem.writeInt(u16, output[out_idx + 1 ..][0..2], ref_idx, .little),
                        else => unreachable,
                    }
                    out_idx += form.size;
                    in_atom_idx += 1;
                } else if (resolveLocalOrArg(ctx, atom_id, scope_level)) |binding| switch (binding) {
                    .arg => |arg_idx| {
                        const arg_op = lowerScopeVarOpArg(op).?;
                        const form = selectArgForm(ctx, arg_op, arg_idx);
                        output[out_idx] = form.op_id;
                        switch (form.operand_size) {
                            0 => {},
                            2 => std.mem.writeInt(u16, output[out_idx + 1 ..][0..2], arg_idx, .little),
                            else => unreachable,
                        }
                        out_idx += form.size;
                        in_atom_idx += 1;
                    },
                    .local => |loc_idx| {
                        if (preferTopLevelModuleClassBinding(ctx, atom_id, loc_idx)) |ref_idx| {
                            const ref_op = lowerScopeVarOpForClosure(ctx, atom_id, ref_idx, op);
                            const form = selectVarRefForm(ctx, ref_op, ref_idx);
                            output[out_idx] = form.op_id;
                            switch (form.operand_size) {
                                0 => {},
                                2 => std.mem.writeInt(u16, output[out_idx + 1 ..][0..2], ref_idx, .little),
                                else => unreachable,
                            }
                            out_idx += form.size;
                        } else if (blk: {
                            if (!isLexicalLocal(ctx, loc_idx)) break :blk false;
                            if (op == opcode.op.scope_get_var_checkthis) break :blk true;
                            if (!useUncheckedLexicalLocals(ctx)) break :blk true;
                            if (op == opcode.op.scope_put_var_init) {
                                break :blk isConstLocal(ctx, loc_idx);
                            } else if (op == opcode.op.scope_put_var) {
                                if (isConstLocal(ctx, loc_idx)) break :blk true;
                                const init_safe = var_initialized_pass2[loc_idx] and !init_bypassed[loc_idx];
                                break :blk !init_safe and localTdzEmittedAtDecl(ctx, loc_idx);
                            } else {
                                const init_safe = var_initialized_pass2[loc_idx] and !init_bypassed[loc_idx];
                                break :blk !init_safe and (isConstLocal(ctx, loc_idx) or localTdzEmittedAtDecl(ctx, loc_idx));
                            }
                        }) {
                            output[out_idx] = lowerScopeVarOpLexical(op);
                            std.mem.writeInt(u16, output[out_idx + 1 ..][0..2], loc_idx, .little);
                            out_idx += 3;
                        } else {
                            const local_op = lowerScopeVarOpLocal(op);
                            const form = selectLocForm(ctx, local_op, loc_idx);
                            output[out_idx] = form.op_id;
                            switch (form.operand_size) {
                                0 => {},
                                1 => output[out_idx + 1] = @intCast(loc_idx),
                                2 => std.mem.writeInt(u16, output[out_idx + 1 ..][0..2], loc_idx, .little),
                                else => unreachable,
                            }
                            out_idx += form.size;
                        }
                        if (op == opcode.op.scope_put_var_init and loc_idx < var_initialized_pass2.len) {
                            var_initialized_pass2[loc_idx] = true;
                        }
                        in_atom_idx += 1;
                    },
                } else if (lookupClosureVar(ctx, atom_id)) |ref_idx| {
                    const ref_op = lowerScopeVarOpForClosure(ctx, atom_id, ref_idx, op);
                    const form = selectVarRefForm(ctx, ref_op, ref_idx);
                    output[out_idx] = form.op_id;
                    switch (form.operand_size) {
                        0 => {},
                        2 => std.mem.writeInt(u16, output[out_idx + 1 ..][0..2], ref_idx, .little),
                        else => unreachable,
                    }
                    out_idx += form.size;
                    in_atom_idx += 1;
                } else {
                    try emitGlobalVarOp(ctx, output, &out_idx, lowerScopeVarOpGlobal(op), atom_id);
                    in_atom_idx += 1;
                }
                i += 7;
            } else if (isScopePrivateFieldAt(func, i, in_atom_idx)) {
                const atom_id = std.mem.readInt(u32, func.code[i + 1 ..][0..4], .little);
                const scope_level = std.mem.readInt(i16, func.code[i + 5 ..][0..2], .little);
                if (resolvePrivateField(ctx, atom_id, scope_level)) |res| {
                    try writeLoweredPrivateField(ctx, output, &out_idx, op, res);
                } else if (canLowerPrivateInAsBoundSymbol(ctx, op, atom_id)) {
                    output[out_idx] = opcode.op.private_symbol;
                    std.mem.writeInt(u32, output[out_idx + 1 ..][0..4], atom_id, .little);
                    output_atoms[out_atom_idx] = func.atoms.dup(atom_id);
                    out_idx += 5;
                    out_atom_idx += 1;
                    output[out_idx] = opcode.op.private_in;
                    out_idx += 1;
                } else {
                    return error.ClosureVarNotFound;
                }
                in_atom_idx += 1;
                i += 7;
            } else if (op == opcode.op.scope_make_ref) {
                if (i + 11 > func.code.len) return error.InvalidBytecode;
                const atom_id = std.mem.readInt(u32, func.code[i + 1 ..][0..4], .little);
                const scope_level = std.mem.readInt(i16, func.code[i + 9 ..][0..2], .little);
                if (canOptimizeGlobalRefPutTail(ctx, atom_id) and scopeMakeRefResolvesToGlobal(ctx, atom_id, scope_level)) {
                    if (findGlobalRefPutTail(func.code, i)) |tail| {
                        if (tail.pc < global_ref_tail_kinds.len and
                            global_ref_tail_kinds[tail.pc] != GLOBAL_REF_TAIL_NONE and
                            global_ref_tail_atoms[tail.pc] == atom_id)
                        {
                            in_atom_idx += 1;
                            i += 11;
                            continue;
                        }
                    }
                }
                if (resolveLocalOrArg(ctx, atom_id, scope_level)) |binding| switch (binding) {
                    .arg => |arg_idx| {
                        output[out_idx] = opcode.op.make_arg_ref;
                        std.mem.writeInt(u32, output[out_idx + 1 ..][0..4], atom_id, .little);
                        std.mem.writeInt(u16, output[out_idx + 5 ..][0..2], arg_idx, .little);
                        output_atoms[out_atom_idx] = func.atoms.dup(atom_id);
                        out_idx += 7;
                        out_atom_idx += 1;
                    },
                    .local => |loc_idx| {
                        output[out_idx] = opcode.op.make_loc_ref;
                        std.mem.writeInt(u32, output[out_idx + 1 ..][0..4], atom_id, .little);
                        std.mem.writeInt(u16, output[out_idx + 5 ..][0..2], loc_idx, .little);
                        output_atoms[out_atom_idx] = func.atoms.dup(atom_id);
                        out_idx += 7;
                        out_atom_idx += 1;
                    },
                } else if (lookupClosureVar(ctx, atom_id)) |ref_idx| {
                    output[out_idx] = opcode.op.make_var_ref_ref;
                    std.mem.writeInt(u32, output[out_idx + 1 ..][0..4], atom_id, .little);
                    std.mem.writeInt(u16, output[out_idx + 5 ..][0..2], ref_idx, .little);
                    output_atoms[out_atom_idx] = func.atoms.dup(atom_id);
                    out_idx += 7;
                    out_atom_idx += 1;
                } else {
                    output[out_idx] = opcode.op.make_var_ref;
                    std.mem.writeInt(u32, output[out_idx + 1 ..][0..4], atom_id, .little);
                    output_atoms[out_atom_idx] = func.atoms.dup(atom_id);
                    out_idx += 5;
                    out_atom_idx += 1;
                }
                in_atom_idx += 1;
                i += 11;
            } else if (isScopeRefOp(op)) {
                if (i + 7 > func.code.len) return error.InvalidBytecode;
                const atom_id = std.mem.readInt(u32, func.code[i + 1 ..][0..4], .little);
                const scope_level = std.mem.readInt(i16, func.code[i + 5 ..][0..2], .little);
                if (op == opcode.op.scope_delete_var) {
                    if (resolveScopeVar(ctx, atom_id, scope_level)) |loc_idx| {
                        if (isEvalNonLexicalLocal(ctx, loc_idx)) {
                            output[out_idx] = opcode.op.delete_var;
                            std.mem.writeInt(u32, output[out_idx + 1 ..][0..4], atom_id, .little);
                            output_atoms[out_atom_idx] = func.atoms.dup(atom_id);
                            out_idx += 5;
                            out_atom_idx += 1;
                        } else {
                            output[out_idx] = opcode.op.push_false;
                            out_idx += 1;
                        }
                    } else if (lookupArg(ctx, atom_id) != null or lookupClosureVar(ctx, atom_id) != null) {
                        output[out_idx] = opcode.op.push_false;
                        out_idx += 1;
                    } else {
                        output[out_idx] = opcode.op.delete_var;
                        std.mem.writeInt(u32, output[out_idx + 1 ..][0..4], atom_id, .little);
                        output_atoms[out_atom_idx] = func.atoms.dup(atom_id);
                        out_idx += 5;
                        out_atom_idx += 1;
                    }
                    in_atom_idx += 1;
                } else {
                    // scope_get_ref: emit OP_undefined + get accessor.
                    output[out_idx] = opcode.op.undefined;
                    out_idx += 1;
                    if (resolveLocalOrArg(ctx, atom_id, scope_level)) |binding| switch (binding) {
                        .arg => |arg_idx| {
                            const form = selectArgForm(ctx, opcode.op.get_arg, arg_idx);
                            output[out_idx] = form.op_id;
                            switch (form.operand_size) {
                                0 => {},
                                2 => std.mem.writeInt(u16, output[out_idx + 1 ..][0..2], arg_idx, .little),
                                else => unreachable,
                            }
                            out_idx += form.size;
                        },
                        .local => |loc_idx| {
                            if (isLexicalLocal(ctx, loc_idx)) {
                                output[out_idx] = opcode.op.get_loc_check;
                                std.mem.writeInt(u16, output[out_idx + 1 ..][0..2], loc_idx, .little);
                                out_idx += 3;
                            } else {
                                const form = selectLocForm(ctx, opcode.op.get_loc, loc_idx);
                                output[out_idx] = form.op_id;
                                switch (form.operand_size) {
                                    0 => {},
                                    1 => output[out_idx + 1] = @intCast(loc_idx),
                                    2 => std.mem.writeInt(u16, output[out_idx + 1 ..][0..2], loc_idx, .little),
                                    else => unreachable,
                                }
                                out_idx += form.size;
                            }
                        },
                    } else if (lookupClosureVar(ctx, atom_id)) |ref_idx| {
                        const form = selectVarRefForm(ctx, opcode.op.get_var_ref, ref_idx);
                        output[out_idx] = form.op_id;
                        switch (form.operand_size) {
                            0 => {},
                            2 => std.mem.writeInt(u16, output[out_idx + 1 ..][0..2], ref_idx, .little),
                            else => unreachable,
                        }
                        out_idx += form.size;
                    } else {
                        try emitGlobalVarOp(ctx, output, &out_idx, opcode.op.get_var, atom_id);
                    }
                    in_atom_idx += 1;
                }
                i += 7;
            } else if (op == opcode.op.enter_scope or op == opcode.op.leave_scope) {
                if (i + 3 > func.code.len) return error.InvalidBytecode;
                if (op == opcode.op.enter_scope) {
                    const scope = std.mem.readInt(u16, func.code[i + 1 ..][0..2], .little);
                    writeEnterScopeRefresh(ctx, output, &out_idx, scope);
                }
                i += 3;
            } else {
                const size = instrSize(op);
                if (i + size > func.code.len) return error.InvalidBytecode;
                @memcpy(output[out_idx .. out_idx + size], func.code[i .. i + size]);
                if (hasAtomOperand(op)) {
                    if (in_atom_idx >= func.atom_operands.len) return error.InvalidBytecode;
                    const atom_id = if (size >= 5) blk: {
                        const encoded_atom = std.mem.readInt(u32, func.code[i + 1 ..][0..4], .little);
                        if (encoded_atom != atom.null_atom and func.atoms.kind(encoded_atom) == null) {
                            // The atom operand list owns the retain. If an older
                            // rewrite left a stale wide immediate, resynchronise it
                            // before the final FunctionBytecode takes ownership.
                            const retained_atom = func.atom_operands[in_atom_idx];
                            std.mem.writeInt(u32, output[out_idx + 1 ..][0..4], retained_atom, .little);
                            break :blk retained_atom;
                        }
                        break :blk encoded_atom;
                    } else func.atom_operands[in_atom_idx];
                    if (size >= 5) std.mem.writeInt(u32, output[out_idx + 1 ..][0..4], atom_id, .little);
                    output_atoms[out_atom_idx] = func.atoms.dup(atom_id);
                    out_atom_idx += 1;
                    in_atom_idx += 1;
                }
                if (labelOperandOffset(op)) |offset| {
                    jump_sites[out_jump_idx] = .{ .operand_pos = out_idx + offset };
                    out_jump_idx += 1;
                }
                out_idx += size;
                i += size;
            }
        }
        // Terminal entry: pc_map[old_len] == out_idx handles jumps that
        // target exactly one-past-the-end (e.g. loop exit to the next
        // instruction after the final byte).
        pc_map[func.code.len] = out_idx;

        // Patch jump targets using the pc map. Each site stored an
        // absolute u32 target that was valid against the *input* code
        // layout; rewrite it to the new post-lowering position.
        for (jump_sites[0..out_jump_idx]) |site| {
            const old_target = std.mem.readInt(u32, output[site.operand_pos..][0..4], .little);
            // Targets outside `[0, func.code.len]` indicate a parser bug,
            // but we treat them as identity rather than panicking so the
            // pipeline stays robust to unfamiliar inputs.
            const new_target: u32 = if (old_target <= func.code.len)
                @intCast(pc_map[old_target])
            else
                old_target;
            std.mem.writeInt(u32, output[site.operand_pos..][0..4], new_target, .little);
        }

        // Build exact-fit buffers before mutating the function. Either trim
        // allocation may fail, and the original temporary buffers must remain
        // owned by the local errdefer path until every fallible step is complete.
        const code_to_install: []u8 = if (out_idx < output.len) blk: {
            if (out_idx == 0) break :blk &.{};
            const trimmed = try ctx.memory.alloc(u8, out_idx);
            @memcpy(trimmed, output[0..out_idx]);
            break :blk trimmed;
        } else output;
        var code_to_install_owned = code_to_install.len != 0 and code_to_install.ptr != output.ptr;
        errdefer if (code_to_install_owned) ctx.memory.free(u8, code_to_install);

        const atoms_to_install: []atom.Atom = if (out_atom_idx < output_atoms.len) blk: {
            if (out_atom_idx == 0) break :blk &.{};
            const trimmed = try ctx.memory.alloc(atom.Atom, out_atom_idx);
            @memcpy(trimmed, output_atoms[0..out_atom_idx]);
            break :blk trimmed;
        } else output_atoms;
        var atoms_to_install_owned = atoms_to_install.len != 0 and atoms_to_install.ptr != output_atoms.ptr;
        errdefer if (atoms_to_install_owned) ctx.memory.free(atom.Atom, atoms_to_install);

        // Replace the old code buffer. `installCode` frees any prior buffer,
        // including capacity allocated by the parser via geometric growth.
        func.remapSourceLocs(pc_map);
        func.remapDirectCallSites(pc_map);
        if (code_to_install.ptr != output.ptr and output_owned) {
            ctx.memory.free(u8, output);
            output_owned = false;
        }
        func.installCode(code_to_install);
        if (code_to_install_owned) code_to_install_owned = false;
        if (code_to_install.ptr == output.ptr) output_owned = false;

        // Replace atom_operands: release old entries, install new ones.
        for (func.atom_operands) |old_atom| func.atoms.free(old_atom);
        if (atoms_to_install.ptr != output_atoms.ptr and output_atoms_owned) {
            ctx.memory.free(atom.Atom, output_atoms);
            output_atoms_owned = false;
        }
        func.installAtomOperands(atoms_to_install);
        if (atoms_to_install_owned) atoms_to_install_owned = false;
        if (atoms_to_install.ptr == output_atoms.ptr) output_atoms_owned = false;
    }
};

pub const pipeline_resolve_labels = struct {
    //! Phase 3a: resolve_labels
    //!
    //! Mirrors `resolve_labels` at `quickjs.c:34197`.
    //!
    //! This phase injects function prologue, rewrites absolute jumps to
    //! relative forms, and selects short-form opcodes.

    const std = @import("std");
    const atom = @import("core/atom.zig");
    const memory = @import("core/memory.zig");
    const bytecode_function = function_mod;
    const function_def_mod = function_def;

    // Special object subtypes (mirrors quickjs.c:17410-17416)
    const SPECIAL_OBJECT_ARGUMENTS: u8 = 0;
    const SPECIAL_OBJECT_MAPPED_ARGUMENTS: u8 = 1;
    const SPECIAL_OBJECT_THIS_FUNC: u8 = 2;
    const SPECIAL_OBJECT_NEW_TARGET: u8 = 3;
    const SPECIAL_OBJECT_HOME_OBJECT: u8 = 4;
    const SPECIAL_OBJECT_VAR_OBJECT: u8 = 5;
    const SPECIAL_OBJECT_IMPORT_META: u8 = 6;
    const SPECIAL_OBJECT_NULL_PROTO: u8 = 7;

    pub const Error = error{
        InvalidBytecode,
    };

    /// JSContext for label resolution.
    pub const JSContext = struct {
        function: *bytecode_function.Bytecode,
        memory: *memory.MemoryAccount,
        atoms: *atom.AtomTable,
        /// Optional FunctionDef for function prologue emission. When non-null,
        /// `resolve_labels` emits OP_special_object sequences for special
        /// variables (home_object, this_active_func, new_target, arguments, etc.).
        function_def: ?*const function_def_mod.FunctionDef = null,

        pub fn init(function: *bytecode_function.Bytecode) JSContext {
            return .{
                .function = function,
                .memory = function.memory,
                .atoms = function.atoms,
            };
        }

        pub fn initWithFunctionDef(
            function: *bytecode_function.Bytecode,
            fd: *const function_def_mod.FunctionDef,
        ) JSContext {
            return .{
                .function = function,
                .memory = function.memory,
                .atoms = function.atoms,
                .function_def = fd,
            };
        }
    };

    /// Total byte length (opcode + operands) for `op_id` in final-form
    /// (non-temp) encoding, from the generated metadata table. This pass's
    /// input contains no temp opcode except `label` (resolve_variables
    /// erased the rest), and `label` is special-cased at each walk site,
    /// so the final view is the correct one here — phase-2 streams may
    /// already carry final-form ids like `fclosure8` whose temp-view size
    /// would differ. Unknown ids fall back to 1 to keep the walker
    /// progressing.
    fn instrSize(op_id: u8) usize {
        const total = opcode.sizeOf(op_id);
        return if (total == 0) 1 else total;
    }

    fn isJumpOp(op_id: u8) bool {
        return op_id == opcode.op.if_false or
            op_id == opcode.op.if_true or
            op_id == opcode.op.goto or
            op_id == opcode.op.@"catch";
    }

    fn isAtomLabelU8Op(op_id: u8) bool {
        return op_id == opcode.op.with_get_var or
            op_id == opcode.op.with_put_var or
            op_id == opcode.op.with_delete_var or
            op_id == opcode.op.with_make_ref or
            op_id == opcode.op.with_get_ref;
    }

    const ShortSlotForm = struct {
        op_id: u8,
        size: u8,
        operand_size: u8,
    };

    fn selectShortSlot(op_id: u8, idx: u16) ?ShortSlotForm {
        const short_base: ?u8 = switch (op_id) {
            opcode.op.get_loc => opcode.op.get_loc0,
            opcode.op.put_loc => opcode.op.put_loc0,
            opcode.op.set_loc => opcode.op.set_loc0,
            opcode.op.get_arg => opcode.op.get_arg0,
            opcode.op.put_arg => opcode.op.put_arg0,
            opcode.op.set_arg => opcode.op.set_arg0,
            opcode.op.get_var_ref => opcode.op.get_var_ref0,
            opcode.op.put_var_ref => opcode.op.put_var_ref0,
            opcode.op.set_var_ref => opcode.op.set_var_ref0,
            else => null,
        };
        const base = short_base orelse return null;
        if (idx < 4) {
            return .{
                .op_id = base + @as(u8, @intCast(idx)),
                .size = 1,
                .operand_size = 0,
            };
        }

        const loc8_op: ?u8 = switch (op_id) {
            opcode.op.get_loc => opcode.op.get_loc8,
            opcode.op.put_loc => opcode.op.put_loc8,
            opcode.op.set_loc => opcode.op.set_loc8,
            else => null,
        };
        if (loc8_op) |loc_op| {
            if (idx < 256) {
                return .{ .op_id = loc_op, .size = 2, .operand_size = 1 };
            }
        }
        return .{ .op_id = op_id, .size = 3, .operand_size = 2 };
    }

    fn jumpTarget(code: []const u8, pc: usize) !usize {
        if (pc + 5 > code.len) return error.InvalidBytecode;
        const target = std.mem.readInt(u32, code[pc + 1 ..][0..4], .little);
        if (target > code.len) return error.InvalidBytecode;
        return @intCast(target);
    }

    fn atomLabelTarget(code: []const u8, pc: usize) !usize {
        if (pc + 10 > code.len) return error.InvalidBytecode;
        const target = std.mem.readInt(u32, code[pc + 5 ..][0..4], .little);
        if (target > code.len) return error.InvalidBytecode;
        return @intCast(target);
    }

    fn skipLabels(code: []const u8, pc: usize) !usize {
        var cursor = pc;
        while (cursor < code.len and code[cursor] == opcode.op.label) {
            if (cursor + 5 > code.len) return error.InvalidBytecode;
            cursor += 5;
        }
        return cursor;
    }

    fn threadedJumpTarget(code: []const u8, pc: usize) !usize {
        const original = try jumpTarget(code, pc);
        var target = original;
        var depth: usize = 0;
        while (depth < 10) : (depth += 1) {
            const target_pc = try skipLabels(code, target);
            if (target_pc >= code.len or code[target_pc] != opcode.op.goto) return target;
            const next = try jumpTarget(code, target_pc);
            if (next == target) return original;
            target = next;
        }
        return original;
    }

    fn resolvedJumpTarget(code: []const u8, pc: usize) !usize {
        return switch (code[pc]) {
            opcode.op.goto, opcode.op.if_false, opcode.op.if_true => threadedJumpTarget(code, pc),
            else => jumpTarget(code, pc),
        };
    }

    fn relOffset(from_pc: usize, target_pc: usize) i64 {
        return @as(i64, @intCast(target_pc)) - @as(i64, @intCast(from_pc + 1));
    }

    fn jumpSizeForOffset(op_id: u8, diff: i64, use_short_opcodes: bool) usize {
        if (op_id == opcode.op.@"catch") return 5;
        if (use_short_opcodes) {
            if (diff >= std.math.minInt(i8) and diff <= std.math.maxInt(i8)) return 2;
            if (op_id == opcode.op.goto and diff >= std.math.minInt(i16) and diff <= std.math.maxInt(i16)) return 3;
        }
        return 5;
    }

    fn jumpOpForSize(op_id: u8, size: usize) u8 {
        return switch (size) {
            2 => switch (op_id) {
                opcode.op.if_false => opcode.op.if_false8,
                opcode.op.if_true => opcode.op.if_true8,
                opcode.op.goto => opcode.op.goto8,
                else => unreachable,
            },
            3 => switch (op_id) {
                opcode.op.goto => opcode.op.goto16,
                else => op_id,
            },
            5 => op_id,
            else => unreachable,
        };
    }

    fn loweredPushI32Size(value: i32, use_short_opcodes: bool) usize {
        if (!use_short_opcodes) return 5;
        if (value >= -1 and value <= 7) return 1;
        if (value >= std.math.minInt(i8) and value <= std.math.maxInt(i8)) return 2;
        if (value >= std.math.minInt(i16) and value <= std.math.maxInt(i16)) return 3;
        return 5;
    }

    fn loweredInstrSize(code: []const u8, pc: usize, use_short_opcodes: bool) usize {
        const op = code[pc];
        if (!use_short_opcodes) return instrSize(op);
        if (op == opcode.op.push_i32 and pc + 5 <= code.len) {
            const value = std.mem.readInt(i32, code[pc + 1 ..][0..4], .little);
            return loweredPushI32Size(value, use_short_opcodes);
        }
        if (op == opcode.op.call and pc + 3 <= code.len) {
            const argc = std.mem.readInt(u16, code[pc + 1 ..][0..2], .little);
            if (argc <= 3) return 1;
        }
        if ((op == opcode.op.push_const or op == opcode.op.fclosure) and pc + 5 <= code.len) {
            const idx = std.mem.readInt(u32, code[pc + 1 ..][0..4], .little);
            if (idx < 256) return 2;
        }
        if (pc + 3 <= code.len) {
            const idx = std.mem.readInt(u16, code[pc + 1 ..][0..2], .little);
            if (selectShortSlot(op, idx)) |form| return form.size;
        }
        return instrSize(op);
    }

    fn hasAtomOperand(op_id: u8) bool {
        const fmt = opcode.formatOf(op_id);
        return fmt == .atom or fmt == .atom_u8 or fmt == .atom_u16 or
            fmt == .atom_label_u8 or fmt == .atom_label_u16;
    }

    fn hasJumpTargetInRange(code: []const u8, start_pc: usize, end_pc: usize) bool {
        var scan_pc: usize = 0;
        while (scan_pc < code.len) {
            const op_id = code[scan_pc];
            const size = if (op_id == opcode.op.label) 5 else instrSize(op_id);
            if (size == 0 or scan_pc + size > code.len) return false;
            const target = if (isJumpOp(op_id))
                (jumpTarget(code, scan_pc) catch return false)
            else if (isAtomLabelU8Op(op_id))
                (atomLabelTarget(code, scan_pc) catch return false)
            else
                null;
            if (target) |target_pc| {
                if (target_pc >= start_pc and target_pc < end_pc) return true;
            }
            scan_pc += size;
        }
        return false;
    }

    const ConstantTestPeephole = struct {
        taken: bool,
        jump_pc: usize,
        total_size: usize,
    };

    fn matchConstantTestPeephole(code: []const u8, pc: usize) ?ConstantTestPeephole {
        if (pc + 10 > code.len or code[pc] != opcode.op.push_i32) return null;
        const jump_pc = pc + 5;
        const jump_op = code[jump_pc];
        if (jump_op != opcode.op.if_false and jump_op != opcode.op.if_true) return null;
        if (hasJumpTargetInRange(code, pc + 1, pc + 10)) return null;
        const value = std.mem.readInt(i32, code[pc + 1 ..][0..4], .little);
        const truthy = value != 0;
        return .{
            .taken = if (jump_op == opcode.op.if_true) truthy else !truthy,
            .jump_pc = jump_pc,
            .total_size = 10,
        };
    }

    const PushI32NegPeephole = struct {
        value: i32,
        total_size: usize,
    };

    fn matchPushI32NegPeephole(code: []const u8, pc: usize) ?PushI32NegPeephole {
        if (pc + 6 > code.len or code[pc] != opcode.op.push_i32 or code[pc + 5] != opcode.op.neg) return null;
        if (hasJumpTargetInRange(code, pc + 1, pc + 6)) return null;
        const value = std.mem.readInt(i32, code[pc + 1 ..][0..4], .little);
        if (value == std.math.minInt(i32) or value == 0) return null;
        return .{ .value = -value, .total_size = 6 };
    }

    fn deadCodePastGotoSize(code: []const u8, pc: usize) ?usize {
        if (pc >= code.len or code[pc] != opcode.op.goto) return null;
        const goto_size = instrSize(opcode.op.goto);
        var scan_pc = pc + goto_size;
        var skipped: usize = 0;
        while (scan_pc < code.len) {
            if (hasJumpTargetTo(code, scan_pc)) break;
            const op_id = code[scan_pc];
            const size = if (op_id == opcode.op.label) 5 else instrSize(op_id);
            if (size == 0 or scan_pc + size > code.len) return null;
            if (hasAtomOperand(op_id)) return null;
            scan_pc += size;
            skipped += size;
        }
        return if (skipped == 0) null else skipped;
    }

    fn undefinedDropPairSize(code: []const u8, pc: usize) ?usize {
        if (pc + 2 > code.len) return null;
        if (code[pc] == opcode.op.undefined and code[pc + 1] == opcode.op.drop) return 2;
        return null;
    }

    const AddLocPeephole = struct {
        idx: u16,
        rhs_op: u8,
        rhs_size: usize,
        total_size: usize,
    };

    fn matchAddLocPeephole(code: []const u8, pc: usize) ?AddLocPeephole {
        if (pc + 3 > code.len) return null;
        const first_op = code[pc];
        if (first_op != opcode.op.get_loc) return null;
        const idx = std.mem.readInt(u16, code[pc + 1 ..][0..2], .little);
        if (idx >= 256) return null;

        const rhs_pc = pc + 3;
        if (rhs_pc >= code.len) return null;
        const rhs_op = code[rhs_pc];

        const rhs_size = switch (rhs_op) {
            opcode.op.push_i32, opcode.op.push_const, opcode.op.push_atom_value => @as(usize, 5),
            opcode.op.get_loc, opcode.op.get_arg, opcode.op.get_var_ref => @as(usize, 3),
            else => return null,
        };

        const suffix_pc = rhs_pc + rhs_size;
        if (suffix_pc + 6 > code.len) return null;

        if (code[suffix_pc] != opcode.op.add) return null;
        if (code[suffix_pc + 1] != opcode.op.dup) return null;
        if (code[suffix_pc + 2] != opcode.op.put_loc) return null;

        const put_idx = std.mem.readInt(u16, code[suffix_pc + 3 ..][0..2], .little);
        if (put_idx != idx) return null;

        if (code[suffix_pc + 5] != opcode.op.drop) return null;

        var offset: usize = 1;
        const total_len = rhs_size + 9;
        while (offset < total_len) : (offset += 1) {
            if (hasJumpTargetTo(code, pc + offset)) return null;
        }

        return .{
            .idx = idx,
            .rhs_op = rhs_op,
            .rhs_size = rhs_size,
            .total_size = total_len,
        };
    }

    fn isTerminalOp(op_id: u8) bool {
        return switch (op_id) {
            opcode.op.goto,
            opcode.op.@"return",
            opcode.op.return_undef,
            opcode.op.return_async,
            opcode.op.tail_call,
            opcode.op.tail_call_method,
            opcode.op.throw,
            => true,
            else => false,
        };
    }

    fn isCleanupOp(op_id: u8) bool {
        return op_id == opcode.op.label or op_id == opcode.op.leave_scope or op_id == opcode.op.close_loc;
    }

    fn hasJumpTargetTo(code: []const u8, target_pc: usize) bool {
        var scan_pc: usize = 0;
        while (scan_pc < code.len) {
            const op_id = code[scan_pc];
            const size = if (op_id == opcode.op.label) 5 else instrSize(op_id);
            if (size == 0 or scan_pc + size > code.len) return false;
            if (isJumpOp(op_id)) {
                if ((jumpTarget(code, scan_pc) catch return false) == target_pc) return true;
            } else if (isAtomLabelU8Op(op_id)) {
                if ((atomLabelTarget(code, scan_pc) catch return false) == target_pc) return true;
            }
            scan_pc += size;
        }
        return false;
    }

    fn redundantReturnUndefSize(code: []const u8, pc: usize) ?usize {
        if (pc >= code.len or code[pc] != opcode.op.return_undef) return null;
        if (hasJumpTargetTo(code, pc)) return null;
        var scan_pc: usize = 0;
        var last_non_cleanup: ?u8 = null;
        while (scan_pc < pc) {
            const op_id = code[scan_pc];
            const size = if (op_id == opcode.op.label) 5 else instrSize(op_id);
            if (size == 0 or scan_pc + size > code.len) return null;
            if (!isCleanupOp(op_id)) last_non_cleanup = op_id;
            scan_pc += size;
        }
        if (last_non_cleanup) |op_id| {
            if (isTerminalOp(op_id)) return 1;
        }
        return null;
    }

    fn emitPushI32Value(output: []u8, out_idx: *usize, value: i32, use_short_opcodes: bool) void {
        if (use_short_opcodes) {
            if (value >= -1 and value <= 7) {
                output[out_idx.*] = switch (value) {
                    -1 => opcode.op.push_minus1,
                    0 => opcode.op.push_0,
                    1 => opcode.op.push_1,
                    2 => opcode.op.push_2,
                    3 => opcode.op.push_3,
                    4 => opcode.op.push_4,
                    5 => opcode.op.push_5,
                    6 => opcode.op.push_6,
                    7 => opcode.op.push_7,
                    else => unreachable,
                };
                out_idx.* += 1;
                return;
            }
            if (value >= std.math.minInt(i8) and value <= std.math.maxInt(i8)) {
                output[out_idx.*] = opcode.op.push_i8;
                output[out_idx.* + 1] = @bitCast(@as(i8, @intCast(value)));
                out_idx.* += 2;
                return;
            }
            if (value >= std.math.minInt(i16) and value <= std.math.maxInt(i16)) {
                output[out_idx.*] = opcode.op.push_i16;
                std.mem.writeInt(i16, output[out_idx.* + 1 ..][0..2], @intCast(value), .little);
                out_idx.* += 3;
                return;
            }
        }
        output[out_idx.*] = opcode.op.push_i32;
        std.mem.writeInt(i32, output[out_idx.* + 1 ..][0..4], value, .little);
        out_idx.* += 5;
    }

    fn emitLoweredInstruction(code: []const u8, pc: usize, output: []u8, out_idx: *usize, use_short_opcodes: bool) !void {
        const op = code[pc];
        if (op == opcode.op.push_i32 and pc + 5 <= code.len) {
            const value = std.mem.readInt(i32, code[pc + 1 ..][0..4], .little);
            emitPushI32Value(output, out_idx, value, use_short_opcodes);
            return;
        }
        if (use_short_opcodes and op == opcode.op.call and pc + 3 <= code.len) {
            const argc = std.mem.readInt(u16, code[pc + 1 ..][0..2], .little);
            if (argc <= 3) {
                output[out_idx.*] = switch (argc) {
                    0 => opcode.op.call0,
                    1 => opcode.op.call1,
                    2 => opcode.op.call2,
                    3 => opcode.op.call3,
                    else => unreachable,
                };
                out_idx.* += 1;
                return;
            }
        }
        if (use_short_opcodes and (op == opcode.op.push_const or op == opcode.op.fclosure) and pc + 5 <= code.len) {
            const idx = std.mem.readInt(u32, code[pc + 1 ..][0..4], .little);
            if (idx < 256) {
                output[out_idx.*] = if (op == opcode.op.push_const) opcode.op.push_const8 else opcode.op.fclosure8;
                output[out_idx.* + 1] = @intCast(idx);
                out_idx.* += 2;
                return;
            }
        }
        if (use_short_opcodes and pc + 3 <= code.len) {
            const idx = std.mem.readInt(u16, code[pc + 1 ..][0..2], .little);
            if (selectShortSlot(op, idx)) |form| {
                output[out_idx.*] = form.op_id;
                switch (form.operand_size) {
                    0 => {},
                    1 => output[out_idx.* + 1] = @intCast(idx),
                    2 => std.mem.writeInt(u16, output[out_idx.* + 1 ..][0..2], idx, .little),
                    else => return error.InvalidBytecode,
                }
                out_idx.* += form.size;
                return;
            }
        }
        const size = instrSize(op);
        if (pc + size > code.len) return error.InvalidBytecode;
        @memcpy(output[out_idx.* .. out_idx.* + size], code[pc .. pc + size]);
        out_idx.* += size;
    }

    fn computeLayout(ctx: *const JSContext, positions: []usize, sizes: []usize, use_short_opcodes: bool, initial_pc: usize) !usize {
        const code = ctx.function.code;
        @memset(positions, 0);
        @memset(sizes, 0);

        var changed = true;
        var final_size: usize = 0;
        var pass: usize = 0;
        // Short-form jumps and instruction shrinkage can cascade through large
        // generated files; keep iterating past the old small fixed cap, while
        // still retaining a hard guard against accidental oscillation.
        const max_passes = 64;
        while (changed and pass < max_passes) : (pass += 1) {
            changed = false;
            var out_pc: usize = initial_pc;
            var pc: usize = 0;
            while (pc < code.len) {
                positions[pc] = out_pc;
                const op = code[pc];
                const old_size = sizes[pc];
                const in_size = if (op == opcode.op.label) 5 else instrSize(op);
                if (pc + in_size > code.len) return error.InvalidBytecode;

                const new_size: usize = if (op == opcode.op.label)
                    0
                else if (undefinedDropPairSize(code, pc) != null)
                    0
                else if (redundantReturnUndefSize(code, pc) != null)
                    0
                else if (matchAddLocPeephole(code, pc)) |_|
                    loweredInstrSize(code, pc + 3, use_short_opcodes) + 2
                else if (matchConstantTestPeephole(code, pc)) |p| blk: {
                    if (!p.taken) break :blk 0;
                    const target = try resolvedJumpTarget(code, p.jump_pc);
                    const target_pc = positions[target];
                    const diff = relOffset(out_pc, target_pc);
                    break :blk jumpSizeForOffset(opcode.op.goto, diff, use_short_opcodes);
                } else if (matchPushI32NegPeephole(code, pc)) |p|
                    loweredPushI32Size(p.value, use_short_opcodes)
                else if (isAtomLabelU8Op(op))
                    instrSize(op)
                else if (isJumpOp(op)) blk: {
                    const target = try resolvedJumpTarget(code, pc);
                    const target_pc = positions[target];
                    const diff = relOffset(out_pc, target_pc);
                    break :blk jumpSizeForOffset(op, diff, use_short_opcodes);
                } else loweredInstrSize(code, pc, use_short_opcodes);

                sizes[pc] = new_size;
                if (old_size != new_size) changed = true;
                const next_pc = pc + (undefinedDropPairSize(code, pc) orelse (redundantReturnUndefSize(code, pc) orelse (if (matchAddLocPeephole(code, pc)) |p| p.total_size else if (matchConstantTestPeephole(code, pc)) |p| p.total_size else if (matchPushI32NegPeephole(code, pc)) |p| p.total_size else in_size + (deadCodePastGotoSize(code, pc) orelse 0))));
                var boundary_pc = pc + 1;
                while (boundary_pc <= next_pc and boundary_pc < positions.len) : (boundary_pc += 1) {
                    positions[boundary_pc] = out_pc + new_size;
                }
                out_pc += new_size;
                pc = next_pc;
            }
            positions[code.len] = out_pc;
            final_size = out_pc;
        }
        if (changed) return error.InvalidBytecode;
        return final_size;
    }

    fn emitJumpToTarget(op: u8, target: usize, output: []u8, out_idx: *usize, positions: []const usize, size: usize) !void {
        const target_pc = positions[target];
        const current_pc = out_idx.*;
        const diff = relOffset(current_pc, target_pc);
        output[out_idx.*] = jumpOpForSize(op, size);
        switch (size) {
            2 => {
                output[out_idx.* + 1] = @bitCast(@as(i8, @intCast(diff)));
            },
            3 => {
                std.mem.writeInt(i16, output[out_idx.* + 1 ..][0..2], @intCast(diff), .little);
            },
            5 => {
                std.mem.writeInt(i32, output[out_idx.* + 1 ..][0..4], @intCast(diff), .little);
            },
            else => return error.InvalidBytecode,
        }
        out_idx.* += size;
    }

    fn emitJump(code: []const u8, pc: usize, output: []u8, out_idx: *usize, positions: []const usize, size: usize) !void {
        const op = code[pc];
        const target = try resolvedJumpTarget(code, pc);
        try emitJumpToTarget(op, target, output, out_idx, positions, size);
    }

    fn emitAtomLabelU8(code: []const u8, pc: usize, output: []u8, out_idx: *usize, positions: []const usize) !void {
        if (pc + 10 > code.len) return error.InvalidBytecode;
        const target = try atomLabelTarget(code, pc);
        const target_pc = positions[target];
        const current_pc = out_idx.*;
        const diff = @as(i64, @intCast(target_pc)) - @as(i64, @intCast(current_pc + 5));
        if (diff < std.math.minInt(i32) or diff > std.math.maxInt(i32)) return error.InvalidBytecode;
        output[out_idx.*] = code[pc];
        @memcpy(output[out_idx.* + 1 .. out_idx.* + 5], code[pc + 1 .. pc + 5]);
        std.mem.writeInt(i32, output[out_idx.* + 5 ..][0..4], @intCast(diff), .little);
        output[out_idx.* + 9] = code[pc + 9];
        out_idx.* += 10;
    }

    /// Emit the function prologue with OP_special_object sequences.
    /// Mirrors `quickjs.c:34232-34294`.
    fn emitFunctionPrologue(ctx: *const JSContext, output: []u8, out_idx: *usize) !void {
        const fd = ctx.function_def orelse return;

        // home_object
        if (fd.home_object_var_idx >= 0) {
            output[out_idx.*] = opcode.op.special_object;
            output[out_idx.* + 1] = SPECIAL_OBJECT_HOME_OBJECT;
            output[out_idx.* + 2] = opcode.op.put_loc;
            std.mem.writeInt(u16, output[out_idx.* + 3 ..][0..2], @intCast(fd.home_object_var_idx), .little);
            out_idx.* += 5;
        }

        // this_active_func
        if (fd.this_active_func_var_idx >= 0) {
            output[out_idx.*] = opcode.op.special_object;
            output[out_idx.* + 1] = SPECIAL_OBJECT_THIS_FUNC;
            output[out_idx.* + 2] = opcode.op.put_loc;
            std.mem.writeInt(u16, output[out_idx.* + 3 ..][0..2], @intCast(fd.this_active_func_var_idx), .little);
            out_idx.* += 5;
        }

        // new_target
        if (fd.new_target_var_idx >= 0) {
            output[out_idx.*] = opcode.op.special_object;
            output[out_idx.* + 1] = SPECIAL_OBJECT_NEW_TARGET;
            output[out_idx.* + 2] = opcode.op.put_loc;
            std.mem.writeInt(u16, output[out_idx.* + 3 ..][0..2], @intCast(fd.new_target_var_idx), .little);
            out_idx.* += 5;
        }

        // this (special handling for derived class constructors)
        if (fd.this_var_idx >= 0) {
            if (fd.is_derived_class_constructor) {
                output[out_idx.*] = opcode.op.set_loc_uninitialized;
                std.mem.writeInt(u16, output[out_idx.* + 1 ..][0..2], @intCast(fd.this_var_idx), .little);
                out_idx.* += 3;
            } else {
                output[out_idx.*] = opcode.op.push_this;
                out_idx.* += 1;
                output[out_idx.*] = opcode.op.put_loc;
                std.mem.writeInt(u16, output[out_idx.* + 1 ..][0..2], @intCast(fd.this_var_idx), .little);
                out_idx.* += 3;
            }
        }

        // arguments
        if (fd.arguments_var_idx >= 0) {
            if (fd.is_strict_mode or !fd.has_simple_parameter_list) {
                output[out_idx.*] = opcode.op.special_object;
                output[out_idx.* + 1] = SPECIAL_OBJECT_ARGUMENTS;
                out_idx.* += 2;
            } else {
                // Mapped arguments - capture all args (simplified)
                output[out_idx.*] = opcode.op.special_object;
                output[out_idx.* + 1] = SPECIAL_OBJECT_MAPPED_ARGUMENTS;
                out_idx.* += 2;
            }
            if (fd.arguments_arg_idx >= 0) {
                output[out_idx.*] = opcode.op.set_loc;
                std.mem.writeInt(u16, output[out_idx.* + 1 ..][0..2], @intCast(fd.arguments_arg_idx), .little);
                out_idx.* += 3;
            }
            output[out_idx.*] = opcode.op.put_loc;
            std.mem.writeInt(u16, output[out_idx.* + 1 ..][0..2], @intCast(fd.arguments_var_idx), .little);
            out_idx.* += 3;
        }

        // func_var (reference to current function)
        if (fd.func_var_idx >= 0) {
            output[out_idx.*] = opcode.op.special_object;
            output[out_idx.* + 1] = SPECIAL_OBJECT_THIS_FUNC;
            output[out_idx.* + 2] = opcode.op.put_loc;
            std.mem.writeInt(u16, output[out_idx.* + 3 ..][0..2], @intCast(fd.func_var_idx), .little);
            out_idx.* += 5;
        }

        // var_object
        if (fd.var_object_idx >= 0) {
            output[out_idx.*] = opcode.op.special_object;
            output[out_idx.* + 1] = SPECIAL_OBJECT_VAR_OBJECT;
            output[out_idx.* + 2] = opcode.op.put_loc;
            std.mem.writeInt(u16, output[out_idx.* + 3 ..][0..2], @intCast(fd.var_object_idx), .little);
            out_idx.* += 5;
        }

        // arg_var_object
        if (fd.arg_var_object_idx >= 0) {
            output[out_idx.*] = opcode.op.special_object;
            output[out_idx.* + 1] = SPECIAL_OBJECT_VAR_OBJECT;
            output[out_idx.* + 2] = opcode.op.put_loc;
            std.mem.writeInt(u16, output[out_idx.* + 3 ..][0..2], @intCast(fd.arg_var_object_idx), .little);
            out_idx.* += 5;
        }
    }

    pub fn run(ctx: *JSContext) !void {
        const func = ctx.function;
        const use_short_opcodes = if (ctx.function_def) |fd| fd.use_short_opcodes else false;

        // Calculate function prologue size
        var prologue_size: usize = 0;
        if (ctx.function_def) |fd| {
            if (fd.home_object_var_idx >= 0) prologue_size += 5;
            if (fd.this_active_func_var_idx >= 0) prologue_size += 5;
            if (fd.new_target_var_idx >= 0) prologue_size += 5;
            if (fd.this_var_idx >= 0) {
                if (fd.is_derived_class_constructor) {
                    prologue_size += 3;
                } else {
                    prologue_size += 4; // push_this (1) + put_loc (3)
                }
            }
            if (fd.arguments_var_idx >= 0) {
                prologue_size += 2; // special_object
                if (fd.arguments_arg_idx >= 0) prologue_size += 3;
                prologue_size += 3; // put_loc
            }
            if (fd.func_var_idx >= 0) prologue_size += 5;
            if (fd.var_object_idx >= 0) prologue_size += 5;
            if (fd.arg_var_object_idx >= 0) prologue_size += 5;
        }

        const positions = try ctx.memory.alloc(usize, func.code.len + 1);
        defer ctx.memory.free(usize, positions);
        const sizes = try ctx.memory.alloc(usize, func.code.len + 1);
        defer ctx.memory.free(usize, sizes);

        // First pass: compute the old-pc -> new-pc layout. OP_label is
        // dropped; jumps are rewritten from parser absolute targets to the
        // pc-relative form expected after resolve_labels.
        const output_size = try computeLayout(ctx, positions, sizes, use_short_opcodes, prologue_size);

        // Keep empty output as an inert slice so bytecode ownership stays explicit
        // without touching allocator accounting.
        const output: []u8 = if (output_size == 0)
            &.{}
        else
            try ctx.memory.alloc(u8, output_size);
        errdefer if (output.len != 0) ctx.memory.free(u8, output);

        // Second pass: emit prologue and copy (dropping labels).
        var out_idx: usize = 0;
        try emitFunctionPrologue(ctx, output, &out_idx);
        var i: usize = 0;
        while (i < func.code.len) {
            const op = func.code[i];
            if (op == opcode.op.label) {
                i += 5;
            } else if (undefinedDropPairSize(func.code, i)) |pair_size| {
                i += pair_size;
            } else if (redundantReturnUndefSize(func.code, i)) |return_size| {
                i += return_size;
            } else if (matchAddLocPeephole(func.code, i)) |p| {
                try emitLoweredInstruction(func.code, i + 3, output, &out_idx, use_short_opcodes);
                output[out_idx] = opcode.op.add_loc;
                output[out_idx + 1] = @intCast(p.idx);
                out_idx += 2;
                i += p.total_size;
            } else if (matchConstantTestPeephole(func.code, i)) |p| {
                if (p.taken) {
                    const size = sizes[i];
                    const target = try resolvedJumpTarget(func.code, p.jump_pc);
                    try emitJumpToTarget(opcode.op.goto, target, output, &out_idx, positions, size);
                }
                i += p.total_size;
            } else if (matchPushI32NegPeephole(func.code, i)) |p| {
                emitPushI32Value(output, &out_idx, p.value, use_short_opcodes);
                i += p.total_size;
            } else if (isJumpOp(op)) {
                const size = sizes[i];
                try emitJump(func.code, i, output, &out_idx, positions, size);
                i += instrSize(op) + (deadCodePastGotoSize(func.code, i) orelse 0);
            } else if (isAtomLabelU8Op(op)) {
                try emitAtomLabelU8(func.code, i, output, &out_idx, positions);
                i += instrSize(op);
            } else {
                const size = instrSize(op);
                if (i + size > func.code.len) return error.InvalidBytecode;
                try emitLoweredInstruction(func.code, i, output, &out_idx, use_short_opcodes);
                i += size;
            }
        }

        // Replace the old code. `output` is sized to `output_size`, the
        // worst-case post-lowering layout; trim it to `out_idx` before
        // installing so capacity tracking stays accurate.
        func.remapSourceLocs(positions);
        func.remapDirectCallSites(positions);
        if (out_idx < output.len) {
            const trimmed = try ctx.memory.alloc(u8, out_idx);
            @memcpy(trimmed, output[0..out_idx]);
            ctx.memory.free(u8, output);
            func.installCode(trimmed);
        } else {
            func.installCode(output);
        }
    }
};

pub const pipeline_stack_size = struct {
    //! Phase 3c: compute_stack_size
    //!
    //! Mirrors `compute_stack_size` at `quickjs.c:35167`.
    //!
    //! Performs a BFS over the bytecode graph to compute the maximum
    //! stack depth. Validates that:
    //!   - no path causes a stack underflow
    //!   - the same pc is never revisited with a different stack level
    //!   - max stack depth never exceeds `JS_STACK_SIZE_MAX`
    //!
    //! Operates on bytecode that has already been through `resolve_labels`
    //! (jumps are relative); the BFS walks fall-through and jump
    //! successors symmetrically.

    const std = @import("std");

    /// `JS_STACK_SIZE_MAX` mirror.
    pub const JS_STACK_SIZE_MAX: u16 = 0xFFFE;

    /// Sentinel: pc has not yet been visited.
    const STACK_LEVEL_UNVISITED: u16 = 0xFFFF;

    pub const Error = error{
        StackUnderflow,
        StackOverflow,
        StackMismatch,
        InvalidOpcode,
        BytecodeOverflow,
        OutOfMemory,
    };

    /// Options for the BFS.
    pub const Options = struct {};

    /// Compute the maximum stack size required to execute `bytecode`.
    ///
    /// Returns 0 for empty bytecode (no instructions to execute).
    pub fn compute(bytecode: []const u8, options: Options) Error!u16 {
        if (bytecode.len == 0) return 0;

        const allocator = std.heap.page_allocator;
        const stack_level_tab = try allocator.alloc(u16, bytecode.len);
        defer allocator.free(stack_level_tab);
        @memset(stack_level_tab, STACK_LEVEL_UNVISITED);
        const catch_pos_tab = try allocator.alloc(i32, bytecode.len);
        defer allocator.free(catch_pos_tab);
        @memset(catch_pos_tab, -1);

        var pc_stack: std.ArrayList(u32) = .empty;
        defer pc_stack.deinit(allocator);

        // Seed: entry pc=0 with stack level 0.
        try seed(stack_level_tab, catch_pos_tab, &pc_stack, allocator, 0, 0, -1);

        var stack_len_max: u16 = 0;

        while (pc_stack.pop()) |pos_any| {
            const pos: u32 = pos_any;
            var stack_len = stack_level_tab[pos];
            var catch_pos = catch_pos_tab[pos];
            const op = bytecode[pos];
            if (op == 0) return error.InvalidOpcode;
            _ = options;
            const meta = metadataFor(op) orelse return error.InvalidOpcode;
            const pos_next = pos + meta.size;
            if (pos_next > bytecode.len) return error.BytecodeOverflow;

            // Compute n_pop, accounting for npop/npop_u16/npopx variable forms.
            var n_pop: u32 = meta.n_pop;
            switch (meta.format) {
                .npop, .npop_u16 => {
                    if (pos + 1 + 2 > bytecode.len) return error.BytecodeOverflow;
                    n_pop += std.mem.readInt(u16, bytecode[pos + 1 ..][0..2], .little);
                },
                .npopx => {
                    // OP_call0..call3: extra args = (op - OP_call0).
                    n_pop += @as(u32, op) - @as(u32, opcode.op.call0);
                },
                else => {},
            }

            if (stack_len < n_pop) {
                return error.StackUnderflow;
            }
            const new_stack_i32: i32 = @as(i32, stack_len) - @as(i32, @intCast(n_pop)) + @as(i32, meta.n_push);
            if (new_stack_i32 < 0) return error.StackUnderflow;
            if (new_stack_i32 > JS_STACK_SIZE_MAX) return error.StackOverflow;
            stack_len = @intCast(new_stack_i32);
            if (stack_len > stack_len_max) stack_len_max = stack_len;

            // Dispatch on opcode name (we don't have the OP_* enum exposed
            // generically). Using name comparison is fine: the table is
            // small and this code runs once per function_mod.
            const name = meta.name;
            if (eq(name, "return") or eq(name, "return_undef") or eq(name, "return_async") or
                eq(name, "throw") or eq(name, "throw_error") or
                eq(name, "tail_call") or eq(name, "tail_call_method") or
                eq(name, "ret"))
            {
                continue; // terminator: no successors.
            }

            // Jump-style opcodes. For Phase 3a-resolved bytecode, jumps are
            // pc-relative.
            if (eq(name, "goto")) {
                const diff = std.mem.readInt(i32, bytecode[pos + 1 ..][0..4], .little);
                const target = relTarget(pos, 1, diff);
                try seed(stack_level_tab, catch_pos_tab, &pc_stack, allocator, target, stack_len, catch_pos);
                continue;
            } else if (eq(name, "goto16")) {
                const diff = std.mem.readInt(i16, bytecode[pos + 1 ..][0..2], .little);
                const target = relTarget(pos, 1, @intCast(diff));
                try seed(stack_level_tab, catch_pos_tab, &pc_stack, allocator, target, stack_len, catch_pos);
                continue;
            } else if (eq(name, "goto8")) {
                const diff: i8 = @bitCast(bytecode[pos + 1]);
                const target = relTarget(pos, 1, @intCast(diff));
                try seed(stack_level_tab, catch_pos_tab, &pc_stack, allocator, target, stack_len, catch_pos);
                continue;
            } else if (eq(name, "if_true") or eq(name, "if_false")) {
                const diff = std.mem.readInt(i32, bytecode[pos + 1 ..][0..4], .little);
                const target = relTarget(pos, 1, diff);
                try seed(stack_level_tab, catch_pos_tab, &pc_stack, allocator, target, stack_len, catch_pos);
                // fall through.
            } else if (eq(name, "if_true8") or eq(name, "if_false8")) {
                const diff: i8 = @bitCast(bytecode[pos + 1]);
                const target = relTarget(pos, 1, @intCast(diff));
                try seed(stack_level_tab, catch_pos_tab, &pc_stack, allocator, target, stack_len, catch_pos);
                // fall through.
            } else if (op == opcode.op.gosub) {
                const diff = std.mem.readInt(i32, bytecode[pos + 1 ..][0..4], .little);
                const target = relTarget(pos, 1, diff);
                try seed(stack_level_tab, catch_pos_tab, &pc_stack, allocator, target, stack_len + 1, catch_pos);
                // fall through.
            } else if (op == opcode.op.with_get_var or op == opcode.op.with_delete_var) {
                const diff = std.mem.readInt(i32, bytecode[pos + 5 ..][0..4], .little);
                const target = relTarget(pos, 5, diff);
                try seed(stack_level_tab, catch_pos_tab, &pc_stack, allocator, target, stack_len + 1, catch_pos);
                // fall through.
            } else if (op == opcode.op.with_make_ref or op == opcode.op.with_get_ref) {
                const diff = std.mem.readInt(i32, bytecode[pos + 5 ..][0..4], .little);
                const target = relTarget(pos, 5, diff);
                try seed(stack_level_tab, catch_pos_tab, &pc_stack, allocator, target, stack_len + 2, catch_pos);
                // fall through.
            } else if (op == opcode.op.with_put_var) {
                const diff = std.mem.readInt(i32, bytecode[pos + 5 ..][0..4], .little);
                const target = relTarget(pos, 5, diff);
                if (stack_len == 0) return error.StackUnderflow;
                try seed(stack_level_tab, catch_pos_tab, &pc_stack, allocator, target, stack_len - 1, catch_pos);
                // fall through.
            } else if (eq(name, "catch")) {
                const diff = std.mem.readInt(i32, bytecode[pos + 1 ..][0..4], .little);
                const target = relTarget(pos, 1, diff);
                try seed(stack_level_tab, catch_pos_tab, &pc_stack, allocator, target, stack_len, catch_pos);
                catch_pos = @intCast(pos);
            } else if (op == opcode.op.for_of_start or op == opcode.op.for_await_of_start) {
                catch_pos = @intCast(pos);
            } else if (op == opcode.op.drop or op == opcode.op.nip or op == opcode.op.nip1 or op == opcode.op.iterator_close) {
                const catch_level = if (op == opcode.op.iterator_close)
                    stack_len + 2
                else if (op == opcode.op.nip or op == opcode.op.nip1) blk: {
                    if (stack_len == 0) return error.StackUnderflow;
                    break :blk stack_len - 1;
                } else stack_len;
                catch_pos = maybePopCatchPos(bytecode, stack_level_tab, catch_pos_tab, catch_pos, catch_level);
            } else if (op == opcode.op.nip_catch) {
                if (catch_pos < 0) return error.InvalidOpcode;
                const catch_idx: usize = @intCast(catch_pos);
                stack_len = stack_level_tab[catch_idx];
                if (bytecode[catch_idx] != opcode.op.@"catch") stack_len += 1;
                stack_len += 1;
                catch_pos = catch_pos_tab[catch_idx];
            }

            // Fall-through.
            try seed(stack_level_tab, catch_pos_tab, &pc_stack, allocator, pos_next, stack_len, catch_pos);
        }

        return stack_len_max;
    }

    const OpMeta = struct {
        name: []const u8,
        size: u8,
        n_pop: u8,
        n_push: u8,
        format: opcode.Format,
    };

    fn metadataFor(op_id: u8) ?OpMeta {
        const size = opcode.sizeOf(op_id);
        const name = opcode.nameOf(op_id);
        if (size == 0 or name.len == 0) return null;
        return .{
            .name = name,
            .size = size,
            .n_pop = opcode.nPopOf(op_id),
            .n_push = opcode.nPushOf(op_id),
            .format = opcode.formatOf(op_id),
        };
    }

    fn seed(
        stack_level_tab: []u16,
        catch_pos_tab: []i32,
        pc_stack: *std.ArrayList(u32),
        allocator: std.mem.Allocator,
        pos: u32,
        stack_len: u16,
        catch_pos: i32,
    ) Error!void {
        if (pos == stack_level_tab.len) return;
        if (pos > stack_level_tab.len) return error.BytecodeOverflow;
        const existing = stack_level_tab[pos];
        if (existing == STACK_LEVEL_UNVISITED) {
            stack_level_tab[pos] = stack_len;
            catch_pos_tab[pos] = catch_pos;
            try pc_stack.append(allocator, pos);
        } else if (existing != stack_len) {
            return error.StackMismatch;
        } else if (catch_pos_tab[pos] != catch_pos) {
            return error.StackMismatch;
        }
    }

    fn maybePopCatchPos(bytecode: []const u8, stack_level_tab: []const u16, catch_pos_tab: []const i32, catch_pos: i32, catch_level: u16) i32 {
        if (catch_pos < 0) return catch_pos;
        const catch_idx: usize = @intCast(catch_pos);
        var level = stack_level_tab[catch_idx];
        if (bytecode[catch_idx] != opcode.op.@"catch") level += 1;
        if (catch_level == level) return catch_pos_tab[catch_idx];
        return catch_pos;
    }

    fn relTarget(pos: u32, operand_offset: u32, diff: i32) u32 {
        const base: i64 = @as(i64, pos) + @as(i64, operand_offset);
        return @intCast(base + diff);
    }

    fn eq(a: []const u8, b: []const u8) bool {
        return std.mem.eql(u8, a, b);
    }

    test "stack_size: empty bytecode produces zero stack" {
        const result = try compute(&.{}, .{});
        try std.testing.expectEqual(@as(u16, 0), result);
    }

    test "stack_size: simple push + return_undef gives stack=1" {
        const op = opcode.op;

        // push_i32 <42> ; return_undef
        var bc = [_]u8{0} ** 6;
        bc[0] = op.push_i32;
        std.mem.writeInt(i32, bc[1..5], 42, .little);
        bc[5] = op.return_undef;

        const result = try compute(&bc, .{});
        try std.testing.expectEqual(@as(u16, 1), result);
    }

    test "stack_size: push push add return gives stack=2" {
        const op = opcode.op;

        // push_i32 1 ; push_i32 2 ; add ; return_undef
        var bc = [_]u8{0} ** 12;
        bc[0] = op.push_i32;
        std.mem.writeInt(i32, bc[1..5], 1, .little);
        bc[5] = op.push_i32;
        std.mem.writeInt(i32, bc[6..10], 2, .little);
        bc[10] = op.add;
        bc[11] = op.return_undef;

        const result = try compute(&bc, .{});
        try std.testing.expectEqual(@as(u16, 2), result);
    }

    test "stack_size: stack underflow detected" {
        const op = opcode.op;

        // drop without anything on the stack → underflow.
        const bc = [_]u8{ op.drop, op.return_undef };
        const result = compute(&bc, .{});
        try std.testing.expectError(error.StackUnderflow, result);
    }

    test "stack_size: relative goto explored" {
        const op = opcode.op;

        // push_i32 7 ; goto +1 (skip drop) ; drop ; return_undef
        // Layout (pc): 0: push_i32, 5: goto, 10: drop, 11: return_undef.
        // Goto operand at pc+1 = 6, target = pos + 1 + diff. We want to
        // reach pc=11, so diff = 11 - (5 + 1) = 5.
        var bc = [_]u8{0} ** 12;
        bc[0] = op.push_i32;
        std.mem.writeInt(i32, bc[1..5], 7, .little);
        bc[5] = op.goto;
        std.mem.writeInt(i32, bc[6..10], 5, .little);
        bc[10] = op.drop; // skipped by goto
        bc[11] = op.return_undef;

        const result = try compute(&bc, .{});
        // The drop is unreachable, so max stack = 1 (push_i32) and no underflow.
        try std.testing.expectEqual(@as(u16, 1), result);
    }

    test "stack_size: catch handler edge contributes to max stack" {
        const op = opcode.op;

        // catch +5 (handler at pc=6) ; return_undef ; push_i32 9 ; return_undef
        // The normal fallthrough only reaches stack depth 1 from the catch marker.
        // The exception edge reaches the handler with the thrown value on the
        // stack, then push_i32 raises the required max stack to 2.
        var bc = [_]u8{0} ** 12;
        bc[0] = op.@"catch";
        std.mem.writeInt(i32, bc[1..5], 5, .little);
        bc[5] = op.return_undef;
        bc[6] = op.push_i32;
        std.mem.writeInt(i32, bc[7..11], 9, .little);
        bc[11] = op.return_undef;

        const result = try compute(&bc, .{});
        try std.testing.expectEqual(@as(u16, 2), result);
    }

    test "stack_size: indexed method call QuickJS shape is strict-computable" {
        const op = opcode.op;

        // get_var obj ; get_var key ; get_array_el2 ; get_var arg ; call_method 1 ; drop ; return_undef
        var bc = [_]u8{0} ** 15;
        bc[0] = op.get_var;
        std.mem.writeInt(u16, bc[1..3], 0, .little);
        bc[3] = op.get_var;
        std.mem.writeInt(u16, bc[4..6], 1, .little);
        bc[6] = op.get_array_el2;
        bc[7] = op.get_var;
        std.mem.writeInt(u16, bc[8..10], 2, .little);
        bc[10] = op.call_method;
        std.mem.writeInt(u16, bc[11..13], 1, .little);
        bc[13] = op.drop;
        bc[14] = op.return_undef;

        const result = try compute(&bc, .{});
        try std.testing.expectEqual(@as(u16, 3), result);
    }

    test "stack_size: indexed compound assignment QuickJS shape is strict-computable" {
        const op = opcode.op;

        // get_var obj ; get_var key ; get_array_el3 ;
        // get_var rhs ; add ; insert3 ; put_array_el ; undefined ; return
        var bc = [_]u8{0} ** 15;
        bc[0] = op.get_var;
        std.mem.writeInt(u16, bc[1..3], 0, .little);
        bc[3] = op.get_var;
        std.mem.writeInt(u16, bc[4..6], 1, .little);
        bc[6] = op.get_array_el3;
        bc[7] = op.get_var;
        std.mem.writeInt(u16, bc[8..10], 2, .little);
        bc[10] = op.add;
        bc[11] = op.insert3;
        bc[12] = op.put_array_el;
        bc[13] = op.undefined;
        bc[14] = op.@"return";

        const result = try compute(&bc, .{});
        try std.testing.expectEqual(@as(u16, 4), result);
    }

    test "stack_size: regexp literal QuickJS shape is strict-computable" {
        const op = opcode.op;

        // push_atom_value "a" ; push_atom_value "g" ; regexp ; return_undef
        var bc = [_]u8{0} ** 12;
        bc[0] = op.push_atom_value;
        bc[5] = op.push_atom_value;
        bc[10] = op.regexp;
        bc[11] = op.return_undef;

        const result = try compute(&bc, .{});
        try std.testing.expectEqual(@as(u16, 2), result);
    }

    test "stack_size: bare new expression QuickJS shape is strict-computable" {
        const op = opcode.op;

        // get_var X ; dup ; call_constructor 0 ; drop ; return_undef
        var bc = [_]u8{0} ** 9;
        bc[0] = op.get_var;
        std.mem.writeInt(u16, bc[1..3], 0, .little);
        bc[3] = op.dup;
        bc[4] = op.call_constructor;
        std.mem.writeInt(u16, bc[5..7], 0, .little);
        bc[7] = op.drop;
        bc[8] = op.return_undef;

        const result = try compute(&bc, .{});
        try std.testing.expectEqual(@as(u16, 2), result);
    }

    test "stack_size: super method call shape is strict-computable" {
        const op = opcode.op;

        // push_this ; special_object home ; get_super ; push_atom_value x ;
        // get_array_el ; tail_call_method 0
        var bc = [_]u8{0} ** 16;
        bc[0] = op.push_this;
        bc[1] = op.special_object;
        bc[2] = 4;
        bc[3] = op.get_super;
        bc[4] = op.push_atom_value;
        bc[9] = op.get_array_el;
        bc[10] = op.tail_call_method;
        std.mem.writeInt(u16, bc[11..13], 0, .little);

        const result = try compute(bc[0..13], .{});
        try std.testing.expectEqual(@as(u16, 3), result);
    }

    test "stack_size: super property value shape is strict-computable" {
        const op = opcode.op;

        // push_this ; special_object home ; get_super ; push_atom_value x ;
        // get_super_value ; return
        var bc = [_]u8{0} ** 12;
        bc[0] = op.push_this;
        bc[1] = op.special_object;
        bc[2] = 4;
        bc[3] = op.get_super;
        bc[4] = op.push_atom_value;
        bc[9] = op.get_super_value;
        bc[10] = op.@"return";

        const result = try compute(bc[0..11], .{});
        try std.testing.expectEqual(@as(u16, 3), result);
    }

    test "stack_size: base class declaration QuickJS shape is strict-computable" {
        const op = opcode.op;

        // set_loc_uninitialized C ; undefined ; set_loc_uninitialized <class_fields_init> ;
        // push_const ctor ; define_class ; undefined ; put_loc fields ; drop ;
        // set_loc C ; close_loc fields ; put_var_ref C ; return_undef
        var bc = [_]u8{0} ** 35;
        bc[0] = op.set_loc_uninitialized;
        std.mem.writeInt(u16, bc[1..3], 0, .little);
        bc[3] = op.undefined;
        bc[4] = op.set_loc_uninitialized;
        std.mem.writeInt(u16, bc[5..7], 1, .little);
        bc[7] = op.push_const;
        bc[12] = op.define_class;
        bc[18] = op.undefined;
        bc[19] = op.put_loc;
        std.mem.writeInt(u16, bc[20..22], 1, .little);
        bc[22] = op.drop;
        bc[23] = op.set_loc;
        std.mem.writeInt(u16, bc[24..26], 0, .little);
        bc[26] = op.close_loc;
        std.mem.writeInt(u16, bc[27..29], 1, .little);
        bc[29] = op.put_var_ref;
        std.mem.writeInt(u16, bc[30..32], 0, .little);
        bc[32] = op.return_undef;

        const result = try compute(bc[0..33], .{});
        try std.testing.expectEqual(@as(u16, 3), result);
    }

    test "stack_size: default derived constructor QuickJS shape is strict-computable" {
        const op = opcode.op;

        // set_loc_uninitialized this ; init_ctor ; put_loc_check_init this ;
        // get_var_ref_check <class_fields_init> ; dup ; if_false8 8 ;
        // get_loc_check this ; swap ; call_method 0 ; drop ; get_loc_check this ; return
        var bc = [_]u8{0} ** 25;
        bc[0] = op.set_loc_uninitialized;
        std.mem.writeInt(u16, bc[1..3], 0, .little);
        bc[3] = op.init_ctor;
        bc[4] = op.put_loc_check_init;
        std.mem.writeInt(u16, bc[5..7], 0, .little);
        bc[7] = op.get_var_ref_check;
        std.mem.writeInt(u16, bc[8..10], 0, .little);
        bc[10] = op.dup;
        bc[11] = op.if_false8;
        bc[12] = 8;
        bc[13] = op.get_loc_check;
        std.mem.writeInt(u16, bc[14..16], 0, .little);
        bc[16] = op.swap;
        bc[17] = op.call_method;
        std.mem.writeInt(u16, bc[18..20], 0, .little);
        bc[20] = op.drop;
        bc[21] = op.get_loc_check;
        std.mem.writeInt(u16, bc[22..24], 0, .little);
        bc[24] = op.@"return";

        const result = try compute(&bc, .{});
        try std.testing.expectEqual(@as(u16, 2), result);
    }

    test "stack_size: for-of iterator close catch position is strict-computable" {
        const op = opcode.op;

        // array_from 0 ; for_of_start ; goto next ; body: put_loc0 ; goto next ;
        // exit: drop ; iterator_close ; return_undef ;
        // next: for_of_next 0 ; if_false body ; drop ; iterator_close ; return_undef
        var bc = [_]u8{0} ** 19;
        bc[0] = op.array_from;
        std.mem.writeInt(u16, bc[1..3], 0, .little);
        bc[3] = op.for_of_start;
        bc[4] = op.goto8;
        bc[5] = 7;
        bc[6] = op.put_loc0;
        bc[7] = op.goto8;
        bc[8] = 4;
        bc[9] = op.drop;
        bc[10] = op.iterator_close;
        bc[11] = op.return_undef;
        bc[12] = op.for_of_next;
        bc[13] = 0;
        bc[14] = op.if_false8;
        bc[15] = @bitCast(@as(i8, -9));
        bc[16] = op.drop;
        bc[17] = op.iterator_close;
        bc[18] = op.return_undef;

        const result = try compute(&bc, .{});
        try std.testing.expectEqual(@as(u16, 5), result);
    }
};

pub const pipeline_finalize = struct {
    //! Finalization: js_create_function equivalent
    //!
    //! Mirrors `js_create_function` at `quickjs.c:35401`.
    //!
    //! This walks the child_list of FunctionDefs, runs all pipeline phases,
    //! and installs the final FunctionBytecode into the parent's cpool.

    const std = @import("std");
    const atom = @import("core/atom.zig");
    const memory_mod = @import("core/memory.zig");
    const fb_mod = function_bytecode;
    const bytecode_function = function_mod;
    const function_def_mod = function_def;

    const resolve_variables = pipeline_resolve_variables;
    const resolve_labels = pipeline_resolve_labels;
    const pc2line = pipeline_pc2line;
    const stack_size = pipeline_stack_size;
    const JSValue = @import("core/value.zig").JSValue;

    pub const FinalizeError = error{
        OutOfMemory,
        InvalidBytecode,
        InvalidOpcode,
        BytecodeOverflow,
        StackUnderflow,
        StackOverflow,
        StackMismatch,
        ClosureVarNotFound,
        Pc2LineTruncated,
        Pc2LineOverflow,
    };

    /// JSContext for finalization.
    pub const JSContext = struct {
        // For the interim Bytecode-based implementation, we just need
        // the function to process. The full FunctionDef-based version
        // will include parent/child relationship tracking.
    };

    /// Create a FunctionBytecode from a FunctionDef.
    ///
    /// This mirrors `js_create_function` at `quickjs.c:35401`. It:
    /// 1. Recursively processes child functions (child_list walk)
    /// 2. Runs all pipeline phases on the FunctionDef
    /// 3. Allocates and populates a FunctionBytecode structure
    /// 4. Returns the FunctionBytecode
    ///
    pub fn createFunctionBytecode(fd: *function_def_mod.FunctionDef, rt: anytype) FinalizeError![]fb_mod.FunctionBytecode {
        try installChildFunctionBytecodes(fd, rt);

        var lowered = bytecode_function.Bytecode.init(fd.memory, fd.atoms, fd.func_name);
        defer lowered.deinit(rt);
        lowered.line_num = fd.line_num;
        lowered.col_num = fd.col_num;
        // Move the parser-built buffers instead of copying them. QuickJS runs
        // its passes directly on `fd->byte_code` and performs a single copy
        // into the packed JSFunctionBytecode (quickjs.c:36188/36226); moving
        // ownership of the growable code and atom-operand buffers into the
        // lowered carrier gives the same copy count. The FunctionDef keeps
        // only the variable/scope metadata the passes consult.
        lowered.code = fd.byte_code;
        lowered.code_capacity = fd.byte_code_capacity;
        fd.byte_code = &.{};
        fd.byte_code_capacity = 0;
        lowered.atom_operands = fd.atom_operands;
        lowered.atom_operands_capacity = fd.atom_operands_capacity;
        fd.atom_operands = &.{};
        fd.atom_operands_capacity = 0;
        for (fd.direct_call_sites) |site| {
            try lowered.appendDirectCallSite(.{
                .kind = .prop_atom,
                .prepare_pc = site.prepare_pc,
                .call_pc = site.call_pc,
                .atom_id = site.atom_id,
                .argc = site.argc,
            });
        }
        for (fd.source_loc_slots) |slot| try lowered.appendSourceLoc(slot.pc, slot.line_num, slot.col_num);
        try runPhases(&lowered, fd, fd);

        // Allocate FunctionBytecode as a single-element slice. Caller is
        // responsible for releasing the returned GC object.
        const slice = try fd.memory.alloc(fb_mod.FunctionBytecode, 1);
        const fb = &slice[0];
        fb.* = fb_mod.FunctionBytecode.init(fd.memory, fd.atoms, fd.func_name);

        var registered = false;
        var committed = false;
        errdefer if (!committed) {
            if (registered) rt.gc.unlinkObject(&fb.header);
            fb.deinit(rt);
            fd.memory.free(fb_mod.FunctionBytecode, slice);
        };

        // Copy flags and metadata
        fb.is_strict_mode = fd.is_strict_mode;
        fb.has_prototype = fd.has_prototype;
        fb.has_simple_parameter_list = fd.has_simple_parameter_list;
        fb.is_class_constructor = fd.func_type == .class_constructor or fd.func_type == .derived_class_constructor;
        fb.is_derived_class_constructor = fd.is_derived_class_constructor;
        fb.need_home_object = fd.need_home_object;
        fb.func_kind = fd.func_kind;
        fb.is_arrow_function = fd.func_type == .arrow;
        fb.new_target_allowed = fd.new_target_allowed;
        fb.super_call_allowed = fd.super_call_allowed;
        fb.super_allowed = fd.super_allowed;
        fb.arguments_allowed = fd.arguments_allowed;
        fb.backtrace_barrier = fd.backtrace_barrier;
        fb.is_indirect_eval = fd.is_indirect_eval;
        fb.has_eval_call = bytecodeHasEvalCall(lowered.code);

        // Pack all read-only artifact slices into a single block allocation.
        // Segments are reserved largest-alignment-first to minimize padding;
        // the slice fields below point into `fb.block` and `deinit` releases
        // the whole block at once.
        const source_len: usize = if (fd.source_text) |source| source.len else 0;
        var layout = fb_mod.BlockBuilder{};
        const execution_view_off = layout.reserve(bytecode_function.Bytecode, 1);
        const cpool_off = layout.reserve(JSValue, fd.cpool.len);
        const call_sites_off = layout.reserve(fb_mod.CallSite, lowered.call_sites.len);
        const vardefs_off = layout.reserve(function_def_mod.VarDef, fd.vars.len);
        const closure_var_off = layout.reserve(function_def_mod.ClosureVar, fd.closure_var.len);
        const atom_operands_off = layout.reserve(atom.Atom, lowered.atom_operands.len);
        const arg_names_off = layout.reserve(atom.Atom, fd.args.len);
        const var_names_off = layout.reserve(atom.Atom, fd.vars.len);
        const var_ref_names_off = layout.reserve(atom.Atom, fd.closure_var.len);
        const global_var_names_off = layout.reserve(atom.Atom, fd.global_vars.len);
        const global_vars_off = layout.reserve(function_def_mod.GlobalVar, fd.global_vars.len);
        const class_instance_fields_off = layout.reserve(atom.Atom, fd.class_instance_fields.len);
        const private_bound_names_off = layout.reserve(atom.Atom, fd.private_bound_names.len);
        const class_private_names_off = layout.reserve(atom.Atom, fd.class_private_names.len);
        // Reserve one extra trailing byte for an `op.return` sentinel (see below):
        // it lets the register-resident dispatch drop the per-op fall-off-end bounds
        // check, matching qjs (whose parser terminates every function with a return).
        const byte_code_off = layout.reserve(u8, lowered.code.len + 1);
        const pc2line_off = layout.reserve(u8, lowered.pc2line_buf.len);
        const source_off = layout.reserve(u8, source_len);
        const var_is_lexical_off = layout.reserve(bool, fd.vars.len);
        const var_is_const_off = layout.reserve(bool, fd.vars.len);
        const var_scope_level_off = layout.reserve(i32, fd.vars.len);
        const var_ref_is_lexical_off = layout.reserve(bool, fd.closure_var.len);
        const var_ref_is_const_off = layout.reserve(bool, fd.closure_var.len);
        const var_ref_is_global_decl_off = layout.reserve(bool, fd.closure_var.len);
        fb.block = try fd.memory.allocAlignedBytes(layout.size, fb_mod.block_alignment);
        const block = fb.block;

        // Copy lowered bytecode.
        if (lowered.code.len > 0) {
            fb.byte_code = fb_mod.blockSlice(block, u8, byte_code_off, lowered.code.len);
            @memcpy(fb.byte_code, lowered.code);
            fb.byte_code_len = @intCast(lowered.code.len);
            // Trailing `op.return` sentinel just past the visible code slice. Eval
            // completion and `goto`-to-end patterns leave code that "falls off" the
            // end without a terminating return; on fall-off the dispatch reads this
            // sentinel and returns the stack top — exactly the completion value the
            // old per-op bounds-checked fall-off path produced. Functions that do
            // end in a real return hit it first and never observe the sentinel.
            fb_mod.blockSlice(block, u8, byte_code_off, lowered.code.len + 1)[lowered.code.len] = opcode.op.@"return";
            if (fd.func_kind == .generator or fd.func_kind == .async_generator) {
                fb.generator_body_pc = findGeneratorBodyMarker(lowered.code) orelse 0;
            }
        }
        if (lowered.atom_operands.len > 0) {
            const atom_operands = fb_mod.blockSlice(block, atom.Atom, atom_operands_off, lowered.atom_operands.len);
            for (lowered.atom_operands, atom_operands) |atom_id, *out| out.* = fd.atoms.dup(atom_id);
            fb.atom_operands = atom_operands;
        }
        if (lowered.call_sites.len > 0) {
            const call_sites = fb_mod.blockSlice(block, fb_mod.CallSite, call_sites_off, lowered.call_sites.len);
            for (lowered.call_sites, call_sites) |site, *out| {
                out.* = site;
                out.atom_id = fd.atoms.dup(site.atom_id);
            }
            fb.call_sites = call_sites;
        }
        if (fd.args.len > 0) {
            const arg_names = fb_mod.blockSlice(block, atom.Atom, arg_names_off, fd.args.len);
            for (fd.args, arg_names) |arg, *out| out.* = fd.atoms.dup(arg.var_name);
            fb.arg_names = arg_names;
        }

        // Copy vardefs plus the var-name metadata views.
        if (fd.vars.len > 0) {
            const var_names = fb_mod.blockSlice(block, atom.Atom, var_names_off, fd.vars.len);
            const var_is_lexical = fb_mod.blockSlice(block, bool, var_is_lexical_off, fd.vars.len);
            const var_is_const = fb_mod.blockSlice(block, bool, var_is_const_off, fd.vars.len);
            const var_scope_level = fb_mod.blockSlice(block, i32, var_scope_level_off, fd.vars.len);
            for (fd.vars, var_names, var_is_lexical, var_is_const, var_scope_level) |v, *name, *is_lexical, *is_const, *scope_level| {
                name.* = fd.atoms.dup(v.var_name);
                is_lexical.* = v.is_lexical;
                is_const.* = v.is_const;
                scope_level.* = v.scope_level;
            }
            fb.var_names = var_names;
            fb.var_is_lexical = var_is_lexical;
            fb.var_is_const = var_is_const;
            fb.var_scope_level = var_scope_level;

            const vardefs = fb_mod.blockSlice(block, function_def_mod.VarDef, vardefs_off, fd.vars.len);
            @memcpy(vardefs, fd.vars);
            for (vardefs) |*v| v.var_name = fd.atoms.dup(v.var_name);
            fb.vardefs = vardefs;
        }

        // Copy closure_var plus the var-ref metadata views.
        if (fd.closure_var.len > 0) {
            const var_ref_names = fb_mod.blockSlice(block, atom.Atom, var_ref_names_off, fd.closure_var.len);
            const var_ref_is_lexical = fb_mod.blockSlice(block, bool, var_ref_is_lexical_off, fd.closure_var.len);
            const var_ref_is_const = fb_mod.blockSlice(block, bool, var_ref_is_const_off, fd.closure_var.len);
            const var_ref_is_global_decl = fb_mod.blockSlice(block, bool, var_ref_is_global_decl_off, fd.closure_var.len);
            for (fd.closure_var, var_ref_names, var_ref_is_lexical, var_ref_is_const, var_ref_is_global_decl) |cv, *name, *is_lexical, *is_const, *is_global_decl| {
                name.* = fd.atoms.dup(cv.var_name);
                is_lexical.* = cv.is_lexical;
                is_const.* = cv.is_const;
                is_global_decl.* = cv.closure_type == .global_decl;
            }
            fb.var_ref_names = var_ref_names;
            fb.var_ref_is_lexical = var_ref_is_lexical;
            fb.var_ref_is_const = var_ref_is_const;
            fb.var_ref_is_global_decl = var_ref_is_global_decl;

            const closure_var = fb_mod.blockSlice(block, function_def_mod.ClosureVar, closure_var_off, fd.closure_var.len);
            @memcpy(closure_var, fd.closure_var);
            for (closure_var) |*cv| cv.var_name = fd.atoms.dup(cv.var_name);
            fb.closure_var = closure_var;
        }

        if (fd.global_vars.len > 0) {
            const global_var_names = fb_mod.blockSlice(block, atom.Atom, global_var_names_off, fd.global_vars.len);
            for (fd.global_vars, global_var_names) |gv, *out| out.* = fd.atoms.dup(gv.var_name);
            fb.global_var_names = global_var_names;

            const global_vars = fb_mod.blockSlice(block, function_def_mod.GlobalVar, global_vars_off, fd.global_vars.len);
            for (fd.global_vars, global_vars) |gv, *out| {
                out.* = gv;
                out.var_name = fd.atoms.dup(gv.var_name);
            }
            fb.global_vars = global_vars;
        }
        if (fd.class_instance_fields.len > 0) {
            const fields = fb_mod.blockSlice(block, atom.Atom, class_instance_fields_off, fd.class_instance_fields.len);
            for (fd.class_instance_fields, fields) |atom_id, *out| out.* = fd.atoms.dup(atom_id);
            fb.class_instance_fields = fields;
        }
        if (fd.private_bound_names.len > 0) {
            const names = fb_mod.blockSlice(block, atom.Atom, private_bound_names_off, fd.private_bound_names.len);
            for (fd.private_bound_names, names) |atom_id, *out| out.* = fd.atoms.dup(atom_id);
            fb.private_bound_names = names;
        }
        if (fd.class_private_names.len > 0) {
            const names = fb_mod.blockSlice(block, atom.Atom, class_private_names_off, fd.class_private_names.len);
            for (fd.class_private_names, names) |atom_id, *out| out.* = fd.atoms.dup(atom_id);
            fb.class_private_names = names;
        }

        // Copy metadata counts
        fb.arg_count = @intCast(fd.arg_count);
        fb.var_count = @intCast(fd.var_count);
        fb.defined_arg_count = @intCast(fd.defined_arg_count);
        fb.var_ref_count = @intCast(fd.var_ref_count);
        fb.closure_var_count = @intCast(fd.closure_var_count);
        fb.stack_size = lowered.stack_size;

        // Copy source location
        fb.atoms.replace(&fb.filename, fd.filename);
        fb.line_num = fd.line_num;
        fb.col_num = fd.col_num;
        if (lowered.pc2line_buf.len != 0) {
            fb.pc2line_buf = fb_mod.blockSlice(block, u8, pc2line_off, lowered.pc2line_buf.len);
            @memcpy(fb.pc2line_buf, lowered.pc2line_buf);
            fb.pc2line_len = @intCast(lowered.pc2line_buf.len);
        }
        if (fd.source_text) |source| {
            const owned = fb_mod.blockSlice(block, u8, source_off, source.len);
            @memcpy(owned, source);
            fb.source = owned;
            fb.source_len = @intCast(source.len);
        }

        // Copy constants.
        if (fd.cpool.len > 0) {
            const cpool = fb_mod.blockSlice(block, JSValue, cpool_off, fd.cpool.len);
            fb.cpool_count = @intCast(fd.cpool.len);
            for (fd.cpool, cpool) |value, *out| out.* = value.dup();
            fb.cpool = cpool;
        }
        bytecode_function.installCachedBytecodeView(fb, &fb_mod.blockSlice(block, bytecode_function.Bytecode, execution_view_off, 1)[0]);

        if (std.c.getenv("ZJS_DISASM") != null) {
            const dump_mod = bytecode_dump;
            var disbuf: [65536]u8 = undefined;
            var diswriter = std.Io.Writer.fixed(&disbuf);
            const view = bytecode_function.asBytecodeView(fb, rt);
            dump_mod.dumpBytecode(&diswriter, &view, .{ .show_raw_bytes = true }) catch {};
            std.debug.print("{s}\n", .{diswriter.buffered()});
        }

        try rt.gc.addWithSize(&fb.header, fb.heapByteSize());
        registered = true;

        committed = true;
        return slice;
    }

    fn findGeneratorBodyMarker(code: []const u8) ?usize {
        const op = opcode.op;
        var i: usize = 0;
        while (i + 4 <= code.len) : (i += 1) {
            if (code[i] == op.push_false and
                code[i + 1] == op.drop and
                code[i + 2] == op.push_true and
                code[i + 3] == op.drop)
            {
                return i + 4;
            }
        }
        return null;
    }

    /// Run all pipeline phases on a compile/execution `Bytecode`.
    ///
    /// This path is used by callers that execute a `Bytecode` object directly
    /// instead of first materialising a GC-owned `FunctionBytecode` artifact:
    /// 1. Run Phase 2 (resolve_variables)
    /// 2. Run Phase 3a (resolve_labels)
    /// 3. Run Phase 3b (pc2line)
    /// 4. Run Phase 3c (stack_size)
    ///
    /// `createFunctionBytecode` is the QuickJS-style storage path. It lowers a
    /// `FunctionDef`, stores the result in `FunctionBytecode`, and the VM obtains
    /// a borrowed execution view with `bytecode.asBytecodeView`.
    pub fn run(function: *bytecode_function.Bytecode) !void {
        return runWithFunctionDef(function, null);
    }

    /// Variant that consumes a `FunctionDef` for local-slot lookup. When
    /// `fd` is non-null, `resolve_variables` lowers `scope_get_var` /
    /// `scope_put_var` to `get_loc` / `put_loc` for any atom found in
    /// `fd.vars`; this also propagates `fd.var_count` onto the produced
    /// `Bytecode.var_count` so the VM frame can size its locals array.
    /// Also processes child FunctionDefs recursively.
    pub fn runWithFunctionDef(
        function: *bytecode_function.Bytecode,
        fd: ?*function_def_mod.FunctionDef,
    ) !void {
        try runPhases(function, fd, fd);
        if (fd) |def| try syncFunctionDefCpool(function, def);
    }

    /// JSRuntime-aware variant used when the parser produced FunctionDef child
    /// entries. It recursively materialises child FunctionBytecode objects and
    /// installs them into the executable Bytecode constant pool so `fclosure*`
    /// operands have real callees.
    pub fn runWithFunctionDefRuntime(
        function: *bytecode_function.Bytecode,
        fd: ?*function_def_mod.FunctionDef,
        rt: anytype,
    ) !void {
        if (fd) |def| {
            try installChildFunctionBytecodes(def, rt);
            try syncFunctionDefCpool(function, def);
        }
        try runPhases(function, fd, fd);
    }

    fn runPhases(
        function: *bytecode_function.Bytecode,
        fd: ?*const function_def_mod.FunctionDef,
        fd_mut: ?*function_def_mod.FunctionDef,
    ) !void {
        // Phase 2: resolve_variables (with optional FunctionDef).
        var resolve_ctx = if (fd_mut) |def|
            resolve_variables.JSContext.initWithFunctionDef(function, def)
        else
            resolve_variables.JSContext.init(function);
        resolve_variables.run(&resolve_ctx) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidBytecode, error.NoFunctionDef, error.NoParentScope => return error.InvalidBytecode,
            error.ClosureVarNotFound => return error.ClosureVarNotFound,
        };

        // Peephole: fuse `get_locN; inc/dec; put_locN` triples into a single
        // `inc_loc`/`dec_loc` (mirrors QuickJS OP_inc_loc). Runs after
        // resolve_variables (locals are now in SHORT form) and before
        // resolve_labels (jump operands are still absolute u32; OP_label
        // markers are still present to keep jump targets off the triple).
        try fuseIncLoc(function, function.memory);

        // After resolve_variables, enable short opcodes for resolve_labels
        // (mirrors quickjs.c:35101 where use_short_opcodes is set after
        // the resolve_variables pass completes).
        if (fd_mut) |def| {
            def.use_short_opcodes = true;
        }

        // Phase 3a: resolve_labels (with optional FunctionDef prologue metadata).
        var labels_ctx = if (fd) |def|
            resolve_labels.JSContext.initWithFunctionDef(function, def)
        else
            resolve_labels.JSContext.init(function);
        try resolve_labels.run(&labels_ctx);

        // Propagate locals count so the VM frame can size its `locals`
        // array. `createFunctionBytecode` copies the same lowered metadata
        // into the final GC-owned function artifact.
        if (fd) |def| {
            if (def.var_count >= 0) {
                function.var_count = @intCast(def.var_count);
            }
            if (def.arg_count >= 0) {
                function.arg_count = @intCast(def.arg_count);
            }
            try syncBytecodeVarNames(function, def);
            try syncBytecodeVarRefNames(function, def);
            try syncBytecodeGlobalVarNames(function, def);
            try removeUncapturedCloseLoc(function, def);
        }

        // Phase 3b: pc2line from remapped Bytecode source slots.
        try encodePc2Line(function);

        // Phase 3c: compute_stack_size over resolved QuickJS-format bytecode.
        function.stack_size = try computeStackSizeForCurrentBytecode(function.code);

        // Defensive fall-off-end backstop for the register-resident dispatch (which
        // dropped the per-op bounds check): parser output always ends in a cold
        // terminator, but guarantee a hand-built top-level Bytecode can never run a
        // hot opcode off the end into heap garbage. Hidden past code.len.
        try function.ensureTrailingReturnSentinel();
    }

    fn computeStackSizeForCurrentBytecode(code: []const u8) !u16 {
        return stack_size.compute(code, .{});
    }

    /// Byte length of an opcode in the post-resolve_variables stream. At this
    /// pipeline stage `OP_label` (size 5) markers are still present and must be
    /// stepped over explicitly, exactly as resolve_variables / resolve_labels do.
    fn fuseInstrSize(op_id: u8) usize {
        if (op_id == opcode.op.label) return 5;
        const total = opcode.sizeOf(op_id);
        return if (total == 0) 1 else total;
    }

    /// Byte offset within `op_id` of an absolute u32 jump target, or null when
    /// the opcode carries no label operand. Mirrors resolve_variables'
    /// `labelOperandOffset`: at this stage targets are still absolute u32.
    fn fuseLabelOperandOffset(op_id: u8) ?usize {
        return switch (opcode.formatOf(op_id)) {
            .label => 1, // u32 target at bytes[1..5]
            .atom_label_u8, .atom_label_u16 => 5, // atom at bytes[1..5], target at bytes[5..9]
            else => null,
        };
    }

    /// Decode a `get_loc` form at `pc`: the short forms get_loc0..get_loc3 /
    /// get_loc8, or the wide u16 `get_loc` (id 87). Returns the local index and
    /// byte size, or null for any other opcode.
    ///
    /// NOTE: this pass runs between resolve_variables and resolve_labels.
    /// resolve_variables emits the WIDE `get_loc`/`put_loc` form here (it only
    /// enables short-opcode selection AFTER it returns; resolve_labels is what
    /// shortens loc forms). We therefore decode both forms and fuse whenever the
    /// index fits the 2-byte `inc_loc`/`dec_loc` loc8 encoding (idx < 256). The
    /// short forms are decoded too so the pass stays correct if it is ever moved
    /// after short-form selection.
    const LocOp = struct { idx: usize, size: usize };

    fn decodeGetLoc(code: []const u8, pc: usize) ?LocOp {
        const op = opcode.op;
        return switch (code[pc]) {
            op.get_loc0, op.get_loc1, op.get_loc2, op.get_loc3 => .{
                .idx = code[pc] - op.get_loc0,
                .size = 1,
            },
            op.get_loc8 => blk: {
                if (pc + 2 > code.len) break :blk null;
                break :blk .{ .idx = code[pc + 1], .size = 2 };
            },
            op.get_loc => blk: {
                if (pc + 3 > code.len) break :blk null;
                break :blk .{ .idx = std.mem.readInt(u16, code[pc + 1 ..][0..2], .little), .size = 3 };
            },
            else => null,
        };
    }

    fn decodePutLoc(code: []const u8, pc: usize) ?LocOp {
        const op = opcode.op;
        return switch (code[pc]) {
            op.put_loc0, op.put_loc1, op.put_loc2, op.put_loc3 => .{
                .idx = code[pc] - op.put_loc0,
                .size = 1,
            },
            op.put_loc8 => blk: {
                if (pc + 2 > code.len) break :blk null;
                break :blk .{ .idx = code[pc + 1], .size = 2 };
            },
            op.put_loc => blk: {
                if (pc + 3 > code.len) break :blk null;
                break :blk .{ .idx = std.mem.readInt(u16, code[pc + 1 ..][0..2], .little), .size = 3 };
            },
            else => null,
        };
    }

    /// A single-value, side-effect-free, no-pop operand op that may legally sit
    /// between `get_loc(n)` and `add` in the add_loc fuse pattern. Mirrors the
    /// operand set in QuickJS's add_loc peephole (quickjs.c:35417-35458:
    /// push_atom_value / push_i32 / get_loc / get_arg / get_var_ref), extended with
    /// zjs's compact push encodings. All are nPop=0/nPush=1 with no control flow,
    /// so replacing `get_loc(n) W add put_loc(n)` with `W add_loc(n)` is value- and
    /// stack-neutral. (scope ops sharing push_minus1..push_7 ids are already gone:
    /// resolve_variables runs before this pass.)
    fn isFusableAddLocOperand(op_id: u8) bool {
        const op = opcode.op;
        return switch (op_id) {
            op.push_i32,
            op.push_const,
            op.push_const8,
            op.push_atom_value,
            op.push_minus1,
            op.push_0,
            op.push_1,
            op.push_2,
            op.push_3,
            op.push_4,
            op.push_5,
            op.push_6,
            op.push_7,
            op.get_loc,
            op.get_loc8,
            op.get_loc0,
            op.get_loc1,
            op.get_loc2,
            op.get_loc3,
            op.get_arg,
            op.get_arg0,
            op.get_arg1,
            op.get_arg2,
            op.get_arg3,
            op.get_var_ref,
            op.get_var_ref0,
            op.get_var_ref1,
            op.get_var_ref2,
            op.get_var_ref3,
            => true,
            else => false,
        };
    }

    /// Peephole pass: fuse a contiguous `get_locN; inc/dec; put_locN` triple
    /// (same local index, idx < 256) into a single 2-byte `inc_loc`/`dec_loc`
    /// (`loc8` format), matching QuickJS's `OP_inc_loc` / `OP_dec_loc`.
    /// Also fuses `get_locN; W; add; put_locN` (W a single-value operand op) into
    /// `W; add_loc(n)`, QuickJS's add_loc peephole (quickjs.c:35417-35458).
    ///
    /// Modeled on the tail of `resolve_variables.run`: at this pipeline stage
    /// jump operands are ABSOLUTE u32 targets and `OP_label` markers (size 5)
    /// are still in the stream. Because the match must be CONTIGUOUS in the byte
    /// stream, no `OP_label` can sit inside a fused triple, so no jump target can
    /// land mid-triple. We build a pc_map over every old pc, remap all absolute
    /// u32 jump targets through it, and remap source-locs / direct-call-sites,
    /// then install the compacted code via `installCode`. There are no atom
    /// operands in any fused op, so `atom_operands` is left untouched.
    pub fn fuseIncLoc(function: *bytecode_function.Bytecode, mem: *memory_mod.MemoryAccount) !void {
        const op = opcode.op;
        const code = function.code;
        if (code.len == 0) return;

        // Output is always <= input (each fused triple shrinks 2->.. -> 2 bytes,
        // i.e. it never grows). Allocate worst-case (== input length).
        const output = try mem.alloc(u8, code.len);
        var output_owned = true;
        errdefer if (output_owned) mem.free(u8, output);

        const pc_map = try mem.alloc(usize, code.len + 1);
        defer mem.free(usize, pc_map);
        @memset(pc_map, 0);

        var i: usize = 0;
        var out_idx: usize = 0;
        while (i < code.len) {
            const op_id = code[i];
            pc_map[i] = out_idx;

            // Try to match a contiguous get_loc; inc/dec; put_loc triple.
            if (decodeGetLoc(code, i)) |get| {
                const mid_pc = i + get.size;
                if (mid_pc < code.len and
                    (code[mid_pc] == op.inc or code[mid_pc] == op.dec))
                {
                    const put_pc = mid_pc + 1; // inc/dec is size 1
                    if (put_pc < code.len) {
                        if (decodePutLoc(code, put_pc)) |put| {
                            if (put.idx == get.idx and get.idx < 256) {
                                // Emit the fused 2-byte loc8 op.
                                output[out_idx] = if (code[mid_pc] == op.inc)
                                    op.inc_loc
                                else
                                    op.dec_loc;
                                output[out_idx + 1] = @intCast(get.idx);
                                // Map the two removed positions (inc/dec, put_loc)
                                // to the new pc of the emitted op. They are never
                                // jump targets, but map them safely.
                                pc_map[mid_pc] = out_idx;
                                pc_map[put_pc] = out_idx;
                                out_idx += 2;
                                i = put_pc + put.size;
                                continue;
                            }
                        }
                    }
                }

                // get_loc(n); W; add; put_loc(n)  ->  W; add_loc(n)
                // (QuickJS add_loc peephole, quickjs.c:35417-35458). W is a single
                // side-effect-free value op. Contiguity guarantees no OP_label (and
                // thus no jump target) lands inside the match, so it is jump-safe by
                // the same argument as the inc/dec fuse above.
                if (get.idx < 256) {
                    const w_pc = i + get.size;
                    if (w_pc < code.len and isFusableAddLocOperand(code[w_pc])) {
                        const w_size = fuseInstrSize(code[w_pc]);
                        const add_pc = w_pc + w_size;
                        if (add_pc < code.len and code[add_pc] == op.add) {
                            const put2_pc = add_pc + 1; // add is size 1
                            if (put2_pc < code.len) {
                                if (decodePutLoc(code, put2_pc)) |put| {
                                    if (put.idx == get.idx) {
                                        // Copy W verbatim, then emit add_loc(n).
                                        if (i + get.size + w_size > code.len) return error.InvalidBytecode;
                                        @memcpy(output[out_idx .. out_idx + w_size], code[w_pc .. w_pc + w_size]);
                                        pc_map[w_pc] = out_idx;
                                        out_idx += w_size;
                                        output[out_idx] = op.add_loc;
                                        output[out_idx + 1] = @intCast(get.idx);
                                        pc_map[add_pc] = out_idx;
                                        pc_map[put2_pc] = out_idx;
                                        out_idx += 2;
                                        i = put2_pc + put.size;
                                        continue;
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // No fuse: copy the op verbatim.
            const size = fuseInstrSize(op_id);
            if (i + size > code.len) return error.InvalidBytecode;
            @memcpy(output[out_idx .. out_idx + size], code[i .. i + size]);
            out_idx += size;
            i += size;
        }
        // Terminal entry: a jump that targets exactly one-past-the-end resolves
        // to the new end of the stream.
        pc_map[code.len] = out_idx;

        // Patch absolute u32 jump targets in the OUTPUT through pc_map.
        var scan: usize = 0;
        while (scan < out_idx) {
            const out_op = output[scan];
            const out_size = fuseInstrSize(out_op);
            if (scan + out_size > out_idx) break;
            if (fuseLabelOperandOffset(out_op)) |offset| {
                const operand_pos = scan + offset;
                const old_target = std.mem.readInt(u32, output[operand_pos..][0..4], .little);
                const new_target: u32 = if (old_target <= code.len)
                    @intCast(pc_map[old_target])
                else
                    old_target;
                std.mem.writeInt(u32, output[operand_pos..][0..4], new_target, .little);
            }
            scan += out_size;
        }

        // Build an exact-fit buffer (output is <= input). Keep the temporary
        // buffer owned via errdefer until every fallible step succeeds.
        const code_to_install: []u8 = if (out_idx < output.len) blk: {
            if (out_idx == 0) break :blk &.{};
            const trimmed = try mem.alloc(u8, out_idx);
            @memcpy(trimmed, output[0..out_idx]);
            break :blk trimmed;
        } else output;
        var code_to_install_owned = code_to_install.len != 0 and code_to_install.ptr != output.ptr;
        errdefer if (code_to_install_owned) mem.free(u8, code_to_install);

        function.remapSourceLocs(pc_map);
        function.remapDirectCallSites(pc_map);
        if (code_to_install.ptr != output.ptr) {
            mem.free(u8, output);
            output_owned = false;
        }
        function.installCode(code_to_install);
        if (code_to_install_owned) code_to_install_owned = false;
        if (code_to_install.ptr == output.ptr) output_owned = false;
    }

    fn removeUncapturedCloseLoc(
        function: *bytecode_function.Bytecode,
        fd: *const function_def_mod.FunctionDef,
    ) !void {
        var remove_count: usize = 0;
        var pc: usize = 0;
        while (pc < function.code.len) {
            const op_id = function.code[pc];
            const size = opcode.sizeOf(op_id);
            if (size == 0 or pc + size > function.code.len) return error.InvalidBytecode;
            if (op_id == opcode.op.close_loc) {
                const loc_idx = std.mem.readInt(u16, function.code[pc + 1 ..][0..2], .little);
                if (!localIsCapturedByChild(fd, loc_idx)) remove_count += size;
            }
            pc += size;
        }
        if (remove_count == 0) return;

        const old_code = function.code;
        const next_len = old_code.len - remove_count;
        const next = try function.memory.alloc(u8, next_len);
        errdefer function.memory.free(u8, next);
        const pc_map = try function.memory.alloc(usize, old_code.len + 1);
        defer function.memory.free(usize, pc_map);

        pc = 0;
        var out: usize = 0;
        while (pc < old_code.len) {
            const op_id = old_code[pc];
            const size = opcode.sizeOf(op_id);
            if (size == 0 or pc + size > old_code.len) return error.InvalidBytecode;

            var boundary = pc;
            while (boundary < pc + size) : (boundary += 1) pc_map[boundary] = out;
            if (op_id == opcode.op.close_loc) {
                const loc_idx = std.mem.readInt(u16, old_code[pc + 1 ..][0..2], .little);
                if (!localIsCapturedByChild(fd, loc_idx)) {
                    pc += size;
                    continue;
                }
            }

            @memcpy(next[out..][0..size], old_code[pc..][0..size]);
            out += size;
            pc += size;
        }
        pc_map[old_code.len] = out;
        try patchRelativeJumpsAfterPcMap(old_code, next, pc_map);
        function.remapSourceLocs(pc_map);
        function.remapDirectCallSites(pc_map);
        function.installCode(next);
    }

    fn patchRelativeJumpsAfterPcMap(old_code: []const u8, new_code: []u8, pc_map: []const usize) !void {
        var pc: usize = 0;
        while (pc < old_code.len) {
            const op_id = old_code[pc];
            const size = opcode.sizeOf(op_id);
            if (size == 0 or pc + size > old_code.len) return error.InvalidBytecode;
            if (relativeJumpWidth(op_id)) |width| {
                const old_operand_pc = pc + 1;
                const old_target = relativeTarget(old_code, old_operand_pc, width);
                if (old_target < 0 or old_target > old_code.len) return error.InvalidBytecode;
                const new_pc = pc_map[pc];
                if (new_pc + size <= new_code.len) {
                    const new_operand_pc = new_pc + 1;
                    const new_target = pc_map[@intCast(old_target)];
                    const diff = @as(i64, @intCast(new_target)) - @as(i64, @intCast(new_operand_pc));
                    try writeRelativeDiff(new_code[new_operand_pc..], width, diff);
                }
            }
            pc += size;
        }
    }

    fn relativeJumpWidth(op_id: u8) ?usize {
        return switch (op_id) {
            opcode.op.if_false8, opcode.op.if_true8, opcode.op.goto8 => 1,
            opcode.op.goto16 => 2,
            opcode.op.if_false, opcode.op.if_true, opcode.op.goto, opcode.op.@"catch", opcode.op.gosub => 4,
            else => null,
        };
    }

    fn relativeTarget(code: []const u8, operand_pc: usize, width: usize) i64 {
        const diff: i64 = switch (width) {
            1 => @as(i8, @bitCast(code[operand_pc])),
            2 => std.mem.readInt(i16, code[operand_pc..][0..2], .little),
            4 => std.mem.readInt(i32, code[operand_pc..][0..4], .little),
            else => unreachable,
        };
        return @as(i64, @intCast(operand_pc)) + diff;
    }

    fn writeRelativeDiff(bytes: []u8, width: usize, diff: i64) !void {
        switch (width) {
            1 => bytes[0] = @bitCast(@as(i8, @intCast(diff))),
            2 => std.mem.writeInt(i16, bytes[0..2], @intCast(diff), .little),
            4 => std.mem.writeInt(i32, bytes[0..4], @intCast(diff), .little),
            else => return error.InvalidBytecode,
        }
    }

    const localIsCapturedByChild = resolve_variables.localIsCaptured;

    fn encodePc2Line(function: *bytecode_function.Bytecode) !void {
        if (function.source_loc_slots.len == 0) {
            function.installPc2Line(&.{}, function.line_num, function.col_num);
            return;
        }
        var encoded = try pc2line.encode(function.memory, function.source_loc_slots, function.line_num, function.col_num);
        defer encoded.deinit();
        if (encoded.bytes.len == 0) {
            function.installPc2Line(&.{}, encoded.line_num, encoded.col_num);
            return;
        }
        const owned = try function.memory.alloc(u8, encoded.bytes.len);
        @memcpy(owned, encoded.bytes);
        function.installPc2Line(owned, encoded.line_num, encoded.col_num);
    }

    fn syncBytecodeVarNames(function: *bytecode_function.Bytecode, fd: *const function_def_mod.FunctionDef) !void {
        if (function.var_names.len != 0) {
            const var_names = function.var_names;
            function.var_names = &.{};
            for (var_names) |atom_id| function.atoms.free(atom_id);
            function.memory.free(atom.Atom, var_names);
        }
        if (function.var_is_lexical.len != 0) {
            const var_is_lexical = function.var_is_lexical;
            function.var_is_lexical = &.{};
            function.memory.free(bool, var_is_lexical);
        }
        if (function.var_is_const.len != 0) {
            const var_is_const = function.var_is_const;
            function.var_is_const = &.{};
            function.memory.free(bool, var_is_const);
        }
        if (function.var_scope_level.len != 0) {
            const var_scope_level = function.var_scope_level;
            function.var_scope_level = &.{};
            function.memory.free(i32, var_scope_level);
        }
        if (fd.vars.len == 0) return;

        const metadata = try copyVarNameMetadata(function.memory, function.atoms, fd.vars);
        function.var_names = metadata.names;
        function.var_is_lexical = metadata.is_lexical;
        function.var_is_const = metadata.is_const;
        function.var_scope_level = metadata.scope_level;
    }

    const VarNameMetadata = struct {
        names: []atom.Atom,
        is_lexical: []bool,
        is_const: []bool,
        scope_level: []i32,
    };

    fn copyVarNameMetadata(memory: anytype, atoms: *atom.AtomTable, vars: []const function_def_mod.VarDef) !VarNameMetadata {
        const names = try memory.alloc(atom.Atom, vars.len);
        var initialized: usize = 0;
        errdefer {
            for (names[0..initialized]) |atom_id| atoms.free(atom_id);
            memory.free(atom.Atom, names);
        }
        const is_lexical = try memory.alloc(bool, vars.len);
        errdefer memory.free(bool, is_lexical);
        const is_const = try memory.alloc(bool, vars.len);
        errdefer memory.free(bool, is_const);
        const scope_level = try memory.alloc(i32, vars.len);
        errdefer memory.free(i32, scope_level);

        for (vars, 0..) |v, idx| {
            names[idx] = atoms.dup(v.var_name);
            is_lexical[idx] = v.is_lexical;
            is_const[idx] = v.is_const;
            scope_level[idx] = v.scope_level;
            initialized += 1;
        }

        return .{ .names = names, .is_lexical = is_lexical, .is_const = is_const, .scope_level = scope_level };
    }

    fn syncBytecodeVarRefNames(function: *bytecode_function.Bytecode, fd: *const function_def_mod.FunctionDef) !void {
        if (function.var_ref_names.len != 0) {
            const var_ref_names = function.var_ref_names;
            function.var_ref_names = &.{};
            for (var_ref_names) |atom_id| function.atoms.free(atom_id);
            function.memory.free(atom.Atom, var_ref_names);
        }
        if (function.var_ref_is_lexical.len != 0) {
            const var_ref_is_lexical = function.var_ref_is_lexical;
            function.var_ref_is_lexical = &.{};
            function.memory.free(bool, var_ref_is_lexical);
        }
        if (function.var_ref_is_const.len != 0) {
            const var_ref_is_const = function.var_ref_is_const;
            function.var_ref_is_const = &.{};
            function.memory.free(bool, var_ref_is_const);
        }
        if (function.var_ref_is_global_decl.len != 0) {
            const var_ref_is_global_decl = function.var_ref_is_global_decl;
            function.var_ref_is_global_decl = &.{};
            function.memory.free(bool, var_ref_is_global_decl);
        }
        if (function.closure_var.len != 0) {
            const closure_var = function.closure_var;
            function.closure_var = &.{};
            for (closure_var) |*cv| function.atoms.free(cv.var_name);
            function.memory.free(function_def_mod.ClosureVar, closure_var);
        }
        if (fd.closure_var.len == 0) return;
        const names = try function.memory.alloc(atom.Atom, fd.closure_var.len);
        errdefer function.memory.free(atom.Atom, names);
        const is_lexical = try function.memory.alloc(bool, fd.closure_var.len);
        errdefer function.memory.free(bool, is_lexical);
        const is_const = try function.memory.alloc(bool, fd.closure_var.len);
        const is_global_decl = try function.memory.alloc(bool, fd.closure_var.len);
        const closure_var = try function.memory.alloc(function_def_mod.ClosureVar, fd.closure_var.len);
        var initialized: usize = 0;
        var initialized_closure: usize = 0;
        errdefer {
            for (names[0..initialized]) |atom_id| function.atoms.free(atom_id);
            function.memory.free(bool, is_const);
            function.memory.free(bool, is_global_decl);
            for (closure_var[0..initialized_closure]) |*cv| function.atoms.free(cv.var_name);
            function.memory.free(function_def_mod.ClosureVar, closure_var);
        }
        for (fd.closure_var, 0..) |cv, idx| {
            names[idx] = fd.atoms.dup(cv.var_name);
            is_lexical[idx] = cv.is_lexical;
            is_const[idx] = cv.is_const;
            is_global_decl[idx] = cv.closure_type == .global_decl;
            closure_var[idx] = cv;
            closure_var[idx].var_name = fd.atoms.dup(cv.var_name);
            initialized += 1;
            initialized_closure += 1;
        }
        function.var_ref_names = names;
        function.var_ref_is_lexical = is_lexical;
        function.var_ref_is_const = is_const;
        function.var_ref_is_global_decl = is_global_decl;
        function.closure_var = closure_var;
    }

    fn syncBytecodeGlobalVarNames(function: *bytecode_function.Bytecode, fd: *const function_def_mod.FunctionDef) !void {
        if (function.global_var_names.len != 0) {
            const global_var_names = function.global_var_names;
            function.global_var_names = &.{};
            for (global_var_names) |atom_id| function.atoms.free(atom_id);
            function.memory.free(atom.Atom, global_var_names);
        }
        if (function.global_vars.len != 0) {
            const global_vars = function.global_vars;
            function.global_vars = &.{};
            for (global_vars) |*gv| function.atoms.free(gv.var_name);
            function.memory.free(function_def_mod.GlobalVar, global_vars);
        }
        if (fd.global_vars.len == 0) return;
        function.global_var_names = try function.memory.alloc(atom.Atom, fd.global_vars.len);
        var initialized_names: usize = 0;
        errdefer {
            for (function.global_var_names[0..initialized_names]) |atom_id| function.atoms.free(atom_id);
            function.memory.free(atom.Atom, function.global_var_names);
            function.global_var_names = &.{};
        }
        function.global_vars = try function.memory.alloc(function_def_mod.GlobalVar, fd.global_vars.len);
        var initialized_vars: usize = 0;
        errdefer {
            for (function.global_vars[0..initialized_vars]) |*gv| function.atoms.free(gv.var_name);
            function.memory.free(function_def_mod.GlobalVar, function.global_vars);
            function.global_vars = &.{};
        }
        for (fd.global_vars, 0..) |gv, idx| {
            function.global_var_names[idx] = fd.atoms.dup(gv.var_name);
            initialized_names += 1;
            function.global_vars[idx] = gv;
            function.global_vars[idx].var_name = fd.atoms.dup(gv.var_name);
            initialized_vars += 1;
        }
    }

    fn installChildFunctionBytecodes(fd: *function_def_mod.FunctionDef, rt: anytype) FinalizeError!void {
        for (fd.child_list) |child| {
            const cpool_idx = child.parent_cpool_idx;
            if (cpool_idx < 0 or @as(usize, @intCast(cpool_idx)) >= fd.cpool.len) {
                return error.InvalidBytecode;
            }
            const fb_slice = try createFunctionBytecode(child, rt);
            const fb = &fb_slice[0];
            const value = JSValue.functionBytecode(&fb.header);
            const idx: usize = @intCast(cpool_idx);
            const old_value = fd.cpool[idx];
            fd.cpool[idx] = value;
            old_value.free(rt);
        }

        for (fd.child_list) |child| {
            if (child.class_fields_init_cpool_idx < 0) continue;
            if (child.parent_cpool_idx < 0 or
                @as(usize, @intCast(child.parent_cpool_idx)) >= fd.cpool.len or
                @as(usize, @intCast(child.class_fields_init_cpool_idx)) >= fd.cpool.len)
            {
                return error.InvalidBytecode;
            }
            const ctor_value = fd.cpool[@intCast(child.parent_cpool_idx)];
            const init_value = fd.cpool[@intCast(child.class_fields_init_cpool_idx)];
            const ctor_fb = functionBytecodeFromValueMutable(ctor_value) orelse return error.InvalidBytecode;
            const next_value = init_value.dup();
            const old_value = ctor_fb.class_fields_init;
            ctor_fb.class_fields_init = next_value;
            if (old_value) |stored| stored.free(rt);
        }
    }

    fn bytecodeHasEvalCall(code: []const u8) bool {
        var pc: usize = 0;
        while (pc < code.len) {
            const op_id = code[pc];
            const size = opcode.sizeOf(op_id);
            if (size == 0 or pc + size > code.len) return true;
            if (op_id == opcode.op.eval or op_id == opcode.op.apply_eval) return true;
            pc += size;
        }
        return false;
    }

    fn functionBytecodeFromValueMutable(value: JSValue) ?*fb_mod.FunctionBytecode {
        const header = value.objectHeader() orelse return null;
        if (header.meta().kind != .function_bytecode) return null;
        const aligned: *align(16) @TypeOf(header.*) = @alignCast(header);
        return @fieldParentPtr("header", aligned);
    }

    fn syncFunctionDefCpool(function: *bytecode_function.Bytecode, fd: *const function_def_mod.FunctionDef) !void {
        if (fd.cpool.len == 0) return;
        if (function.constants.values.len != 0) return error.InvalidBytecode;
        for (fd.cpool) |value| {
            _ = try function.addConstant(value);
        }
    }
};

const function_mod = struct {
    const std = @import("std");
    const build_options = @import("build_options");
    const atom = @import("core/atom.zig");
    const function_bytecode_mod = function_bytecode;
    const memory = @import("core/memory.zig");
    const JSValue = @import("core/value.zig").JSValue;
    const pc2line = pipeline_pc2line;
    const runtime = @import("core/runtime.zig");

    /// Generic geometric growth helper, identical in shape to the FunctionDef
    /// helper of the same name. Keeps `slice.*.len` as the *used* count and
    /// `slice.*.ptr[0..capacity.*]` as the allocator-owned buffer. Returns the
    /// freshly grown tail (length `n`).
    fn growSliceBy(
        comptime T: type,
        mem: *memory.MemoryAccount,
        slice: *[]T,
        capacity: *usize,
        n: usize,
    ) ![]T {
        const used = slice.len;
        const new_used = used + n;
        if (new_used <= capacity.*) {
            slice.* = slice.ptr[0..new_used];
            return slice.ptr[used..new_used];
        }
        var new_cap: usize = if (capacity.* == 0) 8 else capacity.* * 2;
        if (new_cap < new_used) new_cap = new_used;
        const new_buf = try mem.alloc(T, new_cap);
        @memcpy(new_buf[0..used], slice.*);
        var old_buf: []T = &.{};
        if (capacity.* != 0) old_buf = slice.ptr[0..capacity.*];
        slice.* = new_buf[0..new_used];
        capacity.* = new_cap;
        if (old_buf.len != 0) mem.free(T, old_buf);
        return slice.ptr[used..new_used];
    }

    fn freeGrowableSlice(
        comptime T: type,
        mem: *memory.MemoryAccount,
        slice: *[]T,
        capacity: *usize,
    ) void {
        var old_buf: []T = &.{};
        if (capacity.* != 0) old_buf = slice.ptr[0..capacity.*];
        slice.* = &.{};
        capacity.* = 0;
        if (old_buf.len != 0) mem.free(T, old_buf);
    }

    fn freeOwnedAtomSlice(atoms: *atom.AtomTable, mem: *memory.MemoryAccount, slot: *[]atom.Atom) void {
        const items = slot.*;
        slot.* = &.{};
        for (items) |atom_id| atoms.free(atom_id);
        if (items.len != 0) mem.free(atom.Atom, items);
    }

    fn freeOwnedClosureVarSlice(atoms: *atom.AtomTable, mem: *memory.MemoryAccount, slot: *[]function_bytecode_mod.ClosureVar) void {
        const items = slot.*;
        slot.* = &.{};
        for (items) |*cv| atoms.free(cv.var_name);
        if (items.len != 0) mem.free(function_bytecode_mod.ClosureVar, items);
    }

    fn freeOwnedGlobalVarSlice(atoms: *atom.AtomTable, mem: *memory.MemoryAccount, slot: *[]function_bytecode_mod.GlobalVar) void {
        const items = slot.*;
        slot.* = &.{};
        for (items) |*gv| atoms.free(gv.var_name);
        if (items.len != 0) mem.free(function_bytecode_mod.GlobalVar, items);
    }

    fn freeGrowableAtomSlice(
        atoms: *atom.AtomTable,
        mem: *memory.MemoryAccount,
        slice: *[]atom.Atom,
        capacity: *usize,
    ) void {
        const items = slice.*;
        const old_capacity = capacity.*;
        slice.* = &.{};
        capacity.* = 0;
        for (items) |atom_id| atoms.free(atom_id);
        if (old_capacity != 0) {
            mem.free(atom.Atom, items.ptr[0..old_capacity]);
        } else if (items.len != 0) {
            mem.free(atom.Atom, items);
        }
    }

    fn freeOwnedSlice(comptime T: type, mem: *memory.MemoryAccount, slot: *[]T) void {
        const items = slot.*;
        slot.* = &.{};
        if (items.len != 0) mem.free(T, items);
    }

    pub const Flags = packed struct(u16) {
        has_prototype: bool = false,
        has_simple_parameter_list: bool = true,
        is_derived_class_constructor: bool = false,
        need_home_object: bool = false,
        is_async: bool = false,
        is_generator: bool = false,
        is_strict: bool = false,
        runtime_strict: bool = false,
        is_global_var: bool = false,
        is_module: bool = false,
        is_indirect_eval: bool = false,
        has_eval_call: bool = false,
        backtrace_barrier: bool = false,
        reserved: u3 = 0,
    };

    /// Compatibility aliases for finalized runtime function bytecode.
    /// The GC object lives in core; bytecode keeps opcode-aware helpers below.
    pub const DirectCallKind = enum(u8) {
        prop_atom,
    };

    pub const DirectCallSite = struct {
        kind: DirectCallKind = .prop_atom,
        prepare_pc: u32,
        call_pc: u32,
        atom_id: atom.Atom,
        argc: u16,
    };

    pub const BytecodeImpl = struct {
        memory: *memory.MemoryAccount,
        atoms: *atom.AtomTable,
        name: atom.Atom,
        filename: atom.Atom,
        line_num: i32 = 1,
        col_num: i32 = 1,
        pc2line_buf: []u8 = &.{},
        owns_pc2line_buf: bool = false,
        pc2line_start_line: i32 = 1,
        pc2line_start_col: i32 = 1,
        source_loc_slots: []pipeline_pc2line.SourceLocSlot = &.{},
        source_loc_capacity: usize = 0,
        flags: Flags = .{},
        /// Precomputed bytecode-only half of simple inline-call eligibility.
        /// Call-site predicates remain checked in the exec inline-call path.
        simple_inline_eligible: bool = false,
        arg_count: u16 = 0,
        var_count: u16 = 0,
        stack_size: u16 = 0,
        /// `code` and `atom_operands` are mutated by the parser via geometric
        /// growth (see `appendCode` / `retainAtomOperand`). The visible slice
        /// length is the *used* count; the backing buffer is sized by
        /// `code_capacity` / `atom_operands_capacity`. After
        /// `resolve_variables` rewrites the buffers in place these stay 0
        /// because that pass installs slices that exactly fit the resolved
        /// length.
        code: []u8 = &.{},
        code_capacity: usize = 0,
        atom_operands: []atom.Atom = &.{},
        atom_operands_capacity: usize = 0,
        arg_names: []atom.Atom = &.{},
        var_names: []atom.Atom = &.{},
        var_is_lexical: []bool = &.{},
        var_is_const: []bool = &.{},
        // Lexical scope level (`JSVarDef.scope_level`) per local slot. Top-level
        // (scope_level == 0) lexicals participate in the global-lexical sync; a
        // block-level shadower (scope_level > 0) that happens to share a name with
        // a top-level `let`/`const` must NOT. Mirrors qjs, where a block `let` is a
        // pure frame local (`add_scope_var`) with no tie to the global_decl cell.
        var_scope_level: []i32 = &.{},
        var_ref_names: []atom.Atom = &.{},
        var_ref_is_lexical: []bool = &.{},
        var_ref_is_const: []bool = &.{},
        // True for each var-ref that is a top-level script lexical (closure_type
        // == .global_decl, qjs JS_CLOSURE_GLOBAL_DECL). Distinguishes top-level
        // let/const from hoisted function-decl closure vars at instantiation.
        var_ref_is_global_decl: []bool = &.{},
        closure_var: []function_bytecode_mod.ClosureVar = &.{},
        global_var_names: []atom.Atom = &.{},
        global_vars: []function_bytecode_mod.GlobalVar = &.{},
        private_bound_names: []atom.Atom = &.{},
        constants: constant.Pool,
        module_record: ?module.Record = null,
        debug_table: ?debug.Table = null,
        direct_call_sites: []DirectCallSite = &.{},
        direct_call_sites_capacity: usize = 0,
        call_sites: []function_bytecode_mod.CallSite = &.{},
        call_sites_capacity: usize = 0,

        pub fn init(account: *memory.MemoryAccount, atoms: *atom.AtomTable, name: atom.Atom) BytecodeImpl {
            return .{
                .memory = account,
                .atoms = atoms,
                .name = atoms.dup(name),
                .filename = atoms.dup(name),
                .constants = constant.Pool.init(account, atoms),
            };
        }

        pub fn deinit(self: *BytecodeImpl, rt: anytype) void {
            const name = self.name;
            const filename = self.filename;
            self.name = atom.null_atom;
            self.filename = atom.null_atom;
            self.atoms.free(name);
            self.atoms.free(filename);
            freeGrowableAtomSlice(self.atoms, self.memory, &self.atom_operands, &self.atom_operands_capacity);
            freeOwnedAtomSlice(self.atoms, self.memory, &self.arg_names);
            freeOwnedAtomSlice(self.atoms, self.memory, &self.var_names);
            freeOwnedSlice(bool, self.memory, &self.var_is_lexical);
            freeOwnedSlice(bool, self.memory, &self.var_is_const);
            freeOwnedSlice(i32, self.memory, &self.var_scope_level);
            freeOwnedAtomSlice(self.atoms, self.memory, &self.var_ref_names);
            freeOwnedSlice(bool, self.memory, &self.var_ref_is_lexical);
            freeOwnedSlice(bool, self.memory, &self.var_ref_is_const);
            freeOwnedSlice(bool, self.memory, &self.var_ref_is_global_decl);
            freeOwnedClosureVarSlice(self.atoms, self.memory, &self.closure_var);
            freeOwnedAtomSlice(self.atoms, self.memory, &self.global_var_names);
            freeOwnedGlobalVarSlice(self.atoms, self.memory, &self.global_vars);
            freeOwnedAtomSlice(self.atoms, self.memory, &self.private_bound_names);
            freeGrowableSlice(u8, self.memory, &self.code, &self.code_capacity);
            freeGrowableSlice(pipeline_pc2line.SourceLocSlot, self.memory, &self.source_loc_slots, &self.source_loc_capacity);
            const pc2line_buf = self.pc2line_buf;
            const owns_pc2line_buf = self.owns_pc2line_buf;
            self.pc2line_buf = &.{};
            self.owns_pc2line_buf = false;
            self.constants.deinit(rt);
            var module_record = self.module_record;
            var debug_table = self.debug_table;
            self.module_record = null;
            self.debug_table = null;
            if (module_record) |*record| record.deinit();
            if (debug_table) |*table| table.deinit();
            self.deinitDirectCallSites();
            self.deinitCallSites();
            if (owns_pc2line_buf and pc2line_buf.len != 0) self.memory.free(u8, pc2line_buf);
        }

        pub fn setCode(self: *BytecodeImpl, bytes: []const u8) !void {
            freeGrowableSlice(u8, self.memory, &self.code, &self.code_capacity);
            if (bytes.len == 0) {
                self.code = &.{};
                self.code_capacity = 0;
                return;
            }
            // Allocate one extra trailing byte holding an `op.return` sentinel.
            // qjs-aligned: every real function is terminated by a return, so the
            // register-resident dispatch carries no per-op fall-off-end bounds
            // check. Hand-authored test bytecode that omits a terminator reads this
            // sentinel on fall-off and returns the stack top — exactly the
            // completion value the old bounds-checked fall-off produced. The
            // sentinel sits just past the visible `code` slice; terminated
            // bytecode hits its own return first and never observes it.
            const owned = try self.memory.alloc(u8, bytes.len + 1);
            errdefer self.memory.free(u8, owned);
            @memcpy(owned[0..bytes.len], bytes);
            owned[bytes.len] = opcode.op.@"return";
            self.code = owned[0..bytes.len];
            self.code_capacity = bytes.len + 1;
        }

        /// Append bytes to `code` with geometric growth. The visible slice
        /// length tracks the used count so callers can read `code.len` for
        /// the current size, while reallocations are amortised O(1).
        pub fn appendCode(self: *BytecodeImpl, bytes: []const u8) !void {
            if (bytes.len == 0) return;
            if (bytesMayContainEvalCall(bytes)) self.flags.has_eval_call = true;
            const tail = try growSliceBy(u8, self.memory, &self.code, &self.code_capacity, bytes.len);
            @memcpy(tail, bytes);
        }

        /// Ensure a trailing `op.return` sentinel one byte past the visible `code`
        /// slice without changing `code.len` (mirrors setCode). Defensive backstop
        /// for the register-resident dispatch's removed fall-off-end bounds check:
        /// parser-produced code always ends in a cold terminator and never reads it,
        /// but a hand-built top-level `BytecodeImpl` ending in a hot opcode would
        /// otherwise read `code[code.len]` (heap garbage) on fall-off.
        pub fn ensureTrailingReturnSentinel(self: *BytecodeImpl) !void {
            if (self.code.len == 0) return;
            const len = self.code.len;
            _ = try growSliceBy(u8, self.memory, &self.code, &self.code_capacity, 1);
            self.code = self.code[0..len];
            self.code.ptr[len] = opcode.op.@"return";
        }

        pub fn appendSourceLoc(self: *BytecodeImpl, pc: u32, line_num: i32, col_num: i32) !void {
            if (line_num <= 0 or col_num <= 0) return;
            const tail = try growSliceBy(pipeline_pc2line.SourceLocSlot, self.memory, &self.source_loc_slots, &self.source_loc_capacity, 1);
            tail[0] = .{ .pc = pc, .line_num = line_num, .col_num = col_num };
        }

        pub fn remapSourceLocs(self: *BytecodeImpl, old_to_new_pc: []const usize) void {
            if (self.source_loc_slots.len == 0) return;
            for (self.source_loc_slots) |*slot| {
                if (slot.pc >= old_to_new_pc.len) continue;
                slot.pc = @intCast(old_to_new_pc[slot.pc]);
            }
        }

        pub fn remapDirectCallSites(self: *BytecodeImpl, old_to_new_pc: []const usize) void {
            if (self.direct_call_sites.len == 0) return;
            for (self.direct_call_sites) |*site| {
                if (site.prepare_pc < old_to_new_pc.len) {
                    site.prepare_pc = @intCast(old_to_new_pc[site.prepare_pc]);
                } else {
                    site.prepare_pc = std.math.maxInt(u32);
                }
                if (site.call_pc < old_to_new_pc.len) {
                    site.call_pc = @intCast(old_to_new_pc[site.call_pc]);
                } else {
                    site.call_pc = std.math.maxInt(u32);
                }
            }
        }

        /// Truncate `code` back to `target_len` bytes, preserving capacity so
        /// re-emission after speculative rollback does not reallocate.
        pub fn truncateCode(self: *BytecodeImpl, target_len: usize) void {
            std.debug.assert(target_len <= self.code.len);
            self.code = self.code.ptr[0..target_len];
        }

        /// Replace the `code` buffer with an exact-fit slice. Used by pipeline
        /// passes that fully rewrite the buffer (e.g. `resolve_variables`).
        /// The provided slice is taken over; any prior buffer is freed.
        pub fn installCode(self: *BytecodeImpl, owned: []u8) void {
            freeGrowableSlice(u8, self.memory, &self.code, &self.code_capacity);
            self.code = owned;
            self.code_capacity = owned.len;
        }

        pub fn installPc2Line(self: *BytecodeImpl, owned: []u8, start_line_num: i32, start_col_num: i32) void {
            const old = self.pc2line_buf;
            const old_owned = self.owns_pc2line_buf;
            self.pc2line_buf = owned;
            self.owns_pc2line_buf = owned.len != 0;
            self.pc2line_start_line = start_line_num;
            self.pc2line_start_col = start_col_num;
            if (old_owned and old.len != 0) self.memory.free(u8, old);
        }

        /// Replace the `atom_operands` buffer with an exact-fit slice. The
        /// provided slice is taken over; any prior buffer is freed and atom
        /// refcounts already held by `atom_operands` are NOT released by this
        /// helper (callers must release them explicitly when needed).
        pub fn installAtomOperands(self: *BytecodeImpl, owned: []atom.Atom) void {
            freeGrowableSlice(atom.Atom, self.memory, &self.atom_operands, &self.atom_operands_capacity);
            self.atom_operands = owned;
            self.atom_operands_capacity = owned.len;
        }

        pub fn addConstant(self: *BytecodeImpl, value: JSValue) !u32 {
            return self.constants.append(value);
        }

        pub fn retainAtomOperand(self: *BytecodeImpl, atom_id: atom.Atom) !void {
            const tail = try growSliceBy(atom.Atom, self.memory, &self.atom_operands, &self.atom_operands_capacity, 1);
            tail[0] = self.atoms.dup(atom_id);
        }

        /// Truncate `atom_operands` to `target_len` entries, releasing the
        /// per-element atom refcounts but keeping the backing buffer.
        pub fn truncateAtomOperands(self: *BytecodeImpl, target_len: usize) void {
            std.debug.assert(target_len <= self.atom_operands.len);
            var i: usize = target_len;
            while (i < self.atom_operands.len) : (i += 1) {
                self.atoms.free(self.atom_operands[i]);
            }
            self.atom_operands = self.atom_operands.ptr[0..target_len];
        }

        pub fn appendDirectCallSite(self: *BytecodeImpl, site: DirectCallSite) !void {
            const tail = try growSliceBy(DirectCallSite, self.memory, &self.direct_call_sites, &self.direct_call_sites_capacity, 1);
            tail[0] = site;
            tail[0].atom_id = self.atoms.dup(site.atom_id);
        }

        pub fn appendCallSite(self: *BytecodeImpl, site: function_bytecode_mod.CallSite) !u16 {
            if (self.call_sites.len >= std.math.maxInt(u16)) return error.BytecodeOverflow;
            const tail = try growSliceBy(function_bytecode_mod.CallSite, self.memory, &self.call_sites, &self.call_sites_capacity, 1);
            tail[0] = site;
            tail[0].atom_id = self.atoms.dup(site.atom_id);
            return @intCast(self.call_sites.len - 1);
        }

        pub fn deinitDirectCallSites(self: *BytecodeImpl) void {
            const items = self.direct_call_sites;
            const capacity = self.direct_call_sites_capacity;
            self.direct_call_sites = &.{};
            self.direct_call_sites_capacity = 0;
            for (items) |site| self.atoms.free(site.atom_id);
            if (capacity != 0) self.memory.free(DirectCallSite, items.ptr[0..capacity]);
        }

        pub fn deinitCallSites(self: *BytecodeImpl) void {
            const items = self.call_sites;
            const capacity = self.call_sites_capacity;
            self.call_sites = &.{};
            self.call_sites_capacity = 0;
            for (items) |site| self.atoms.free(site.atom_id);
            if (capacity != 0) self.memory.free(function_bytecode_mod.CallSite, items.ptr[0..capacity]);
        }

        pub fn ensureModule(self: *BytecodeImpl) *module.Record {
            if (self.module_record == null) self.module_record = module.Record.init(self.memory, self.atoms);
            return &self.module_record.?;
        }

        pub fn ensureDebug(self: *BytecodeImpl, filename: atom.Atom) *debug.Table {
            if (self.debug_table == null) self.debug_table = debug.Table.init(self.memory, self.atoms, filename);
            return &self.debug_table.?;
        }
    };

    /// Return a borrowed `BytecodeImpl` execution view for the current VM.
    ///
    /// The returned value does not own any slices and must not be deinitialized.
    /// It intentionally omits compile-only fields such as scopes, modules, and
    /// debug tables; those remain on the compile-time `BytecodeImpl` representation.
    pub fn asBytecodeView(fb: *const FunctionBytecode, rt: *runtime.JSRuntime) BytecodeImpl {
        return makeBytecodeView(fb, &rt.memory, &rt.atoms);
    }

    fn makeBytecodeView(fb: *const FunctionBytecode, mem: *memory.MemoryAccount, atoms: *atom.AtomTable) BytecodeImpl {
        return .{
            .memory = mem,
            .atoms = atoms,
            .name = fb.func_name,
            .filename = fb.filename,
            .line_num = fb.line_num,
            .col_num = fb.col_num,
            .pc2line_buf = fb.pc2line_buf,
            .owns_pc2line_buf = false,
            .pc2line_start_line = fb.line_num,
            .pc2line_start_col = fb.col_num,
            .flags = .{
                .has_prototype = fb.has_prototype,
                .has_simple_parameter_list = fb.has_simple_parameter_list,
                .is_derived_class_constructor = fb.is_derived_class_constructor,
                .is_async = fb.func_kind == .async or fb.func_kind == .async_generator,
                .is_generator = fb.func_kind == .generator or fb.func_kind == .async_generator,
                .is_strict = fb.is_strict_mode,
                .runtime_strict = fb.runtime_strict_mode,
                .is_indirect_eval = fb.is_indirect_eval,
                .has_eval_call = fb.has_eval_call,
                .backtrace_barrier = fb.backtrace_barrier,
            },
            .simple_inline_eligible = fb.func_kind == .normal and
                !fb.is_class_constructor and !fb.is_derived_class_constructor and
                !fb.is_arrow_function and !fb.is_strict_mode and !fb.runtime_strict_mode and
                fb.has_simple_parameter_list and !fb.has_eval_call and fb.global_vars.len == 0,
            .arg_count = fb.arg_count,
            .var_count = fb.var_count,
            .stack_size = fb.stack_size,
            .code = fb.byte_code,
            .atom_operands = fb.atom_operands,
            .arg_names = fb.arg_names,
            .var_names = fb.var_names,
            .var_is_lexical = fb.var_is_lexical,
            .var_is_const = fb.var_is_const,
            .var_scope_level = fb.var_scope_level,
            .var_ref_names = fb.var_ref_names,
            .var_ref_is_lexical = fb.var_ref_is_lexical,
            .var_ref_is_const = fb.var_ref_is_const,
            .var_ref_is_global_decl = fb.var_ref_is_global_decl,
            .closure_var = fb.closure_var,
            .global_var_names = fb.global_var_names,
            .global_vars = fb.global_vars,
            .private_bound_names = fb.private_bound_names,
            .call_sites = fb.call_sites,
            .constants = .{ .memory = mem, .atoms = atoms, .values = fb.cpool },
        };
    }

    pub fn cachedBytecodeView(fb: *const FunctionBytecode) ?*const BytecodeImpl {
        const ptr = fb.execution_view orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    pub fn installCachedBytecodeView(fb: *FunctionBytecode, view: *BytecodeImpl) void {
        view.* = makeBytecodeView(fb, fb.memory, fb.atoms);
        fb.execution_view = view;
        fb.execution_view_owned = false;
        fb.execution_view_heap_size = 0;
        fb.execution_view_destroy = null;
    }

    pub fn ensureCachedBytecodeView(fb: *const FunctionBytecode, rt: *runtime.JSRuntime) !*const BytecodeImpl {
        if (@This().cachedBytecodeView(fb)) |view| return view;
        const mutable_fb: *FunctionBytecode = @constCast(fb);
        const view = try rt.memory.create(BytecodeImpl);
        view.* = makeBytecodeView(fb, &rt.memory, &rt.atoms);
        mutable_fb.execution_view = view;
        mutable_fb.execution_view_owned = true;
        mutable_fb.execution_view_heap_size = @sizeOf(BytecodeImpl);
        mutable_fb.execution_view_destroy = destroyCachedBytecodeView;
        return view;
    }

    pub fn refreshCachedBytecodeView(fb: *FunctionBytecode) void {
        const view = @This().cachedBytecodeView(fb) orelse return;
        @constCast(view).* = makeBytecodeView(fb, fb.memory, fb.atoms);
    }

    fn destroyCachedBytecodeView(mem: *memory.MemoryAccount, ptr: *anyopaque) void {
        const view: *BytecodeImpl = @ptrCast(@alignCast(ptr));
        mem.destroy(BytecodeImpl, view);
    }

    fn bytesMayContainEvalCall(bytes: []const u8) bool {
        return std.mem.indexOfScalar(u8, bytes, opcode.op.eval) != null or
            std.mem.indexOfScalar(u8, bytes, opcode.op.apply_eval) != null;
    }

    pub const destroyFunctionBytecode = function_bytecode_mod.destroyFunctionBytecode;
    pub const destroyFromHeader = function_bytecode_mod.destroyFromHeader;
    pub const Bytecode = BytecodeImpl;
};

pub const dump = struct {
    //! Bytecode dumper.
    //!
    //! Walks a `Bytecode.code` buffer and prints a human-readable disassembly
    //! similar in spirit to `qjs --bytecode-dump`. Shared by tooling and tests
    //! that need to inspect emitted bytecode.

    const std = @import("std");

    /// Disassembly options.
    pub const Options = struct {
        /// When true, prepend the byte offset of each instruction.
        show_offsets: bool = true,
        /// When true, also dump the raw bytes of each instruction.
        show_raw_bytes: bool = false,
    };

    /// Walk `bc.code` and emit a one-instruction-per-line listing into
    /// `writer`. Unknown opcode ids are printed as `?<id>` and the walker
    /// advances by 1 byte so the dump is robust to malformed input.
    pub fn dumpBytecode(
        writer: *std.Io.Writer,
        bc: *const function_mod.Bytecode,
        opts: Options,
    ) !void {
        try writer.print("=== bytecode ===\n", .{});
        try writer.print("name        : {s}\n", .{bc.atoms.name(bc.name) orelse "?"});
        try writer.print("arg_count   : {d}\n", .{bc.arg_count});
        try writer.print("var_count   : {d}\n", .{bc.var_count});
        try writer.print("stack_size  : {d}\n", .{bc.stack_size});
        try writer.print("code_len    : {d}\n", .{bc.code.len});
        try writer.print("atoms       : {d}\n", .{bc.atom_operands.len});
        try writer.print("constants   : {d}\n", .{bc.constants.values.len});
        try writer.print("--- instructions ---\n", .{});

        var pc: usize = 0;
        var atom_idx: usize = 0;
        while (pc < bc.code.len) {
            const op_id = bc.code[pc];
            const reported_size = opcode.sizeOf(op_id);
            const size: usize = if (reported_size == 0) 1 else @intCast(reported_size);
            const end = @min(pc + size, bc.code.len);

            if (opts.show_offsets) {
                try writer.print("{d:>5}: ", .{pc});
            }

            const op_name = opcode.nameOf(op_id);
            if (op_name.len == 0) {
                try writer.print("?<{d}>", .{op_id});
            } else {
                try writer.print("{s}", .{op_name});
            }

            const fmt = opcode.formatOf(op_id);
            try printOperands(writer, bc, fmt, bc.code[pc..end], &atom_idx);

            if (opts.show_raw_bytes) {
                try writer.print("    ; raw=", .{});
                for (bc.code[pc..end]) |b| try writer.print("{x:0>2} ", .{b});
            }
            try writer.print("\n", .{});

            if (size == 0) break; // safety
            pc += size;
        }

        try writer.print("--- end ---\n", .{});
    }

    fn printOperands(
        writer: *std.Io.Writer,
        bc: *const function_mod.Bytecode,
        fmt: opcode.Format,
        body: []const u8,
        atom_idx: *usize,
    ) !void {
        switch (fmt) {
            .none, .none_int, .none_loc, .none_arg, .none_var_ref => {},

            .u8, .npopx => {
                if (body.len >= 2) try writer.print(" {d}", .{body[1]});
            },
            .i8, .label8 => {
                if (body.len >= 2) try writer.print(" {d}", .{@as(i8, @bitCast(body[1]))});
            },
            .loc8, .const8 => {
                if (body.len >= 2) try writer.print(" {d}", .{body[1]});
            },

            .u16, .loc, .arg, .var_ref, .npop, .label16 => {
                if (body.len >= 3) {
                    const v = std.mem.readInt(u16, body[1..][0..2], .little);
                    try writer.print(" {d}", .{v});
                }
            },
            .i16 => {
                if (body.len >= 3) {
                    const v = std.mem.readInt(i16, body[1..][0..2], .little);
                    try writer.print(" {d}", .{v});
                }
            },
            .npop_u16 => {
                if (body.len >= 5) {
                    const a = std.mem.readInt(u16, body[1..][0..2], .little);
                    const b = std.mem.readInt(u16, body[3..][0..2], .little);
                    try writer.print(" {d},{d}", .{ a, b });
                }
            },

            .u32, .label, .@"const" => {
                if (body.len >= 5) {
                    const v = std.mem.readInt(u32, body[1..][0..4], .little);
                    try writer.print(" {d}", .{v});
                }
            },
            .i32 => {
                if (body.len >= 5) {
                    const v = std.mem.readInt(i32, body[1..][0..4], .little);
                    try writer.print(" {d}", .{v});
                }
            },
            .atom => {
                try writeAtomOperand(writer, bc, atom_idx);
            },
            .atom_u8 => {
                try writeAtomOperand(writer, bc, atom_idx);
                if (body.len >= 6) try writer.print(", {d}", .{body[5]});
            },
            .atom_u16 => {
                try writeAtomOperand(writer, bc, atom_idx);
                if (body.len >= 7) {
                    const v = std.mem.readInt(u16, body[5..][0..2], .little);
                    try writer.print(", {d}", .{v});
                }
            },
            .atom_label_u8 => {
                try writeAtomOperand(writer, bc, atom_idx);
                if (body.len >= 10) {
                    const lbl = std.mem.readInt(u32, body[5..][0..4], .little);
                    try writer.print(", L{d}, {d}", .{ lbl, body[9] });
                }
            },
            .atom_label_u16 => {
                try writeAtomOperand(writer, bc, atom_idx);
                if (body.len >= 11) {
                    const lbl = std.mem.readInt(u32, body[5..][0..4], .little);
                    const v = std.mem.readInt(u16, body[9..][0..2], .little);
                    try writer.print(", L{d}, {d}", .{ lbl, v });
                }
            },
            .label_u16 => {
                if (body.len >= 7) {
                    const lbl = std.mem.readInt(u32, body[1..][0..4], .little);
                    const v = std.mem.readInt(u16, body[5..][0..2], .little);
                    try writer.print(" L{d}, {d}", .{ lbl, v });
                }
            },
        }
    }

    fn writeAtomOperand(
        writer: *std.Io.Writer,
        bc: *const function_mod.Bytecode,
        atom_idx: *usize,
    ) !void {
        if (atom_idx.* >= bc.atom_operands.len) {
            try writer.print(" <atom?>", .{});
            return;
        }
        const a = bc.atom_operands[atom_idx.*];
        atom_idx.* += 1;
        if (bc.atoms.name(a)) |s| {
            try writer.print(" \"{s}\"", .{s});
        } else {
            try writer.print(" <atom#{d}>", .{a});
        }
    }
};

pub const pipeline = struct {
    pub const resolve_variables = pipeline_resolve_variables;
    pub const resolve_labels = pipeline_resolve_labels;
    pub const pc2line = pipeline_pc2line;
    pub const stack_size = pipeline_stack_size;
    pub const finalize = pipeline_finalize;
};

const bytecode_dump = dump;
pub const Bytecode = function_mod.Bytecode;
pub const FunctionBytecode = function_bytecode.FunctionBytecode;
pub const FunctionDef = function_def.FunctionDef;
pub const asBytecodeView = function_mod.asBytecodeView;
pub const cachedBytecodeView = function_mod.cachedBytecodeView;
pub const installCachedBytecodeView = function_mod.installCachedBytecodeView;
pub const ensureCachedBytecodeView = function_mod.ensureCachedBytecodeView;
pub const refreshCachedBytecodeView = function_mod.refreshCachedBytecodeView;

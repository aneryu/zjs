//! Defines opcode metadata and the bytecode, module, and function carriers.
pub const subsystem_name = "bytecode";
const core_context = @import("core/context.zig");

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
    pub const Format = enum(u8) {
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

    /// Phase-1 scope operand flag: the LHS reference has already selected its
    /// environment, so the fallback put must resolve only the static chain.
    pub const scope_no_dynamic_env_flag: u16 = 0x8000;
    pub const scope_no_dynamic_env_max_level: u16 = 0x7ffe;

    /// One row of opcode metadata (QuickJS `JSOpCode`).
    pub const Info = struct {
        name: []const u8,
        size: u8,
        n_pop: u8,
        n_push: u8,
        fmt: Format,
    };

    /// Production metadata consumed by final-bytecode hot passes. QuickJS
    /// omits the diagnostic opcode name unless DUMP_BYTECODE is enabled, so
    /// its production `JSOpCode` row is exactly these four bytes. Keep the
    /// richer `Info` table for dumps and general tooling, but do not make each
    /// verifier instruction stride across a 24-byte row just to read these
    /// four fields.
    pub const CompactInfo = extern struct {
        size: u8,
        n_pop: u8,
        n_push: u8,
        fmt: Format,
    };

    comptime {
        if (@sizeOf(CompactInfo) != 4) @compileError("CompactInfo must mirror production QuickJS JSOpCode");
        // Force `physical` to be analyzed here. Zig analyses nested
        // containers lazily, so its assertions would otherwise fire only in
        // builds that happen to reference it -- verified: without this line
        // an id/name mismatch injected into the table compiles clean under
        // `zig build zjs` and is caught only by `zig build test`. An
        // assertion that runs in one build configuration is not a guard.
        _ = physical.ledger;
        // Same lazy-analysis trap as `physical`, hit a second time: without
        // this, `decode.layout_table` is never evaluated in a build that does
        // not use it, and a declaration hole injected into the legacy runs
        // compiles clean under `zig build zjs`. Verified by injection.
        _ = decode.layout_table.len;
    }

    /// Flags byte (operand offset 9) of `dyn_env_probe`, the single opcode
    /// covering all five dynamic-environment binding operations.  `kind`
    /// selects what runs once the binding is found; `is_with` selects whether
    /// @@unscopables participates.  These used to be five opcodes, and the
    /// with/var-object axis was spelled two different ways depending on which
    /// one it was (a bool for four of them, a three-valued enum for the put
    /// form whose third value had no emitter).
    pub const dyn_env = struct {
        /// Not named `Kind`: the enclosing `opcode` namespace already has one
        /// (the normal/temp/short opcode phase).
        pub const ProbeKind = enum(u3) {
            read = 0,
            delete = 1,
            put = 2,
            get_ref = 3,
            make_ref = 4,
        };

        const kind_mask: u8 = 0b0000_0111;
        const is_with_bit: u8 = 0b0000_1000;

        pub const Flags = struct {
            kind: ProbeKind,
            /// A `with (obj)` environment consults @@unscopables before it
            /// accepts the binding.  An eval variable object has no such hook.
            is_with: bool,

            pub fn encode(self: Flags) u8 {
                return @as(u8, @intFromEnum(self.kind)) |
                    (if (self.is_with) is_with_bit else 0);
            }

            /// Fall-through (binding absent) stack effect.  The taken branch
            /// is described by `branchStackDelta`.
            pub fn stackPop(self: Flags) u8 {
                return switch (self.kind) {
                    .put => 2,
                    else => 1,
                };
            }

            pub fn stackPush(self: Flags) u8 {
                return switch (self.kind) {
                    .put => 1,
                    else => 0,
                };
            }

            /// Stack level at the `done` label, relative to the level after
            /// the fall-through effect above.
            pub fn branchStackDelta(self: Flags) i8 {
                return switch (self.kind) {
                    // Drops the probed object, pushes the result.
                    .read, .delete => 1,
                    // Keeps the probed object underneath the result.
                    .get_ref, .make_ref => 2,
                    // Consumes the stored value the fall-through leaves alone.
                    .put => -1,
                };
            }
        };

        pub fn decode(byte: u8) ?Flags {
            if (byte & ~(kind_mask | is_with_bit) != 0) return null;
            const kind: ProbeKind = switch (byte & kind_mask) {
                0 => .read,
                1 => .delete,
                2 => .put,
                3 => .get_ref,
                4 => .make_ref,
                else => return null,
            };
            return .{ .kind = kind, .is_with = byte & is_with_bit != 0 };
        }
    };

    /// zjs extension carried by the existing `throw_error` opcode for
    /// Annex-B runtime errors on CallExpression assignment targets.
    pub const throw_error_invalid_assignment_target: u8 = 5;

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
        pub const dup: u8 = 17;
        /// Fusion last-round (using-prefix reclaim of zoo-cold `dup1`). `get_loc8` + leftover `push_i8`.
        pub const get_loc8_push_i8: u8 = 18;
        /// Fusion v4 (using-prefix reclaim of zoo-cold `dup2`). `push_0` + leftover `or`.
        pub const push_0_or: u8 = 19;
        /// Fusion last-round (using-prefix reclaim of zoo-cold `dup3`). `push_i8` + leftover `add`.
        pub const push_i8_add: u8 = 20;
        pub const insert2: u8 = 21;
        pub const insert3: u8 = 22;
        /// Fusion v4 (using-prefix reclaim). `push_2` + leftover `sar`.
        pub const push_2_sar: u8 = 23;
        pub const perm3: u8 = 24;
        pub const perm4: u8 = 25;
        /// Fusion v4 (using-prefix reclaim). `sar` + leftover `get_array_el`.
        pub const sar_get_array_el: u8 = 26;
        pub const swap: u8 = 27;
        /// Fusion last-round (using-prefix reclaim of zoo-cold `swap2`). `push_0` + leftover `shr`.
        pub const push_0_shr: u8 = 28;
        pub const rot3l: u8 = 29;
        /// Fusion last-round (using-prefix reclaim of zoo-cold `rot3r`). `get_loc8` + leftover `push_1`.
        pub const get_loc8_push_1: u8 = 30;
        /// Fusion last-round (using-prefix reclaim of zoo-cold `rot4l`). `get_var_ref0` + leftover `get_loc8`.
        pub const get_var_ref0_get_loc8: u8 = 31;
        /// Fusion v4 (using-prefix reclaim). `get_loc8` + leftover `push_2`
        /// (also leftover `push_0` / `push_0_shr` / `push_0_or` — same slot).
        pub const get_loc8_push_2: u8 = 32;
        pub const call_constructor: u8 = 33;
        pub const call: u8 = 34;
        pub const tail_call: u8 = 35;
        pub const call_method: u8 = 36;
        pub const tail_call_method: u8 = 37;
        pub const array_from: u8 = 38;
        pub const apply: u8 = 39;
        pub const @"return": u8 = 40;
        pub const return_undef: u8 = 41;
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
        pub const define_field: u8 = 73;
        pub const set_name: u8 = 74;
        pub const set_name_computed: u8 = 75;
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
        pub const to_propkey: u8 = 112;
        pub const dyn_env_probe: u8 = 113;
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
        /// ToNumber（一元 `+`）。QuickJS 叫 `OP_plus`；改名是因为那个名字
        /// 在 2026-08-27 的跨引擎审计里直接导致了一次误判——按名字比对时
        /// 「三家都没有 plus」，按语义读实现才发现三家的 `ToNumber` 就是它。
        pub const to_number: u8 = 139;
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
        /// Fusion v3 (using-prefix reclaim of the three zoo-cold type tests).
        /// `get_field` + leftover `get_field2`. Size/stack match `get_field`.
        pub const get_field_field2: u8 = 240;
        pub const is_null: u8 = 241;
        /// `get_var` + leftover `get_field`. Size/stack match `get_var`.
        pub const get_var_field: u8 = 242;
        /// `get_loc2` + leftover `get_field2`. Size/stack match `get_loc2`.
        pub const get_loc2_field2: u8 = 243;
        /// zjs-only ERM prefix. Operand is `using_sub` (create/dispose/
        /// dispose_throw, or `add_base+hint`). Frees 245–247 for fusion v2.
        pub const using: u8 = 244;
        /// Emit-time fusion: `get_field2` + `call_method`. Size/stack match
        /// `get_field2`; the following `call_method` stays in the stream (poll
        /// lives in `op_call_method`).
        pub const get_field2_call_method: u8 = 245;
        /// Emit-time fusion: `get_loc2` + `get_field`. Size/stack match
        /// `get_loc2`; the following `get_field` stays in the stream.
        pub const get_loc2_field: u8 = 246;
        /// Emit-time fusion: `eq` + `if_false8`. Size/stack match `eq`;
        /// the following `if_false8` stays in the stream (poll lives there).
        pub const eq_if_false8: u8 = 247;
        /// zjs-only: L1 rewritten `this.m.apply(this, arguments)` site.
        /// Same encoding as `call_method` (u16 argc). Never emitted by the
        /// parser; specialized copies only.
        pub const call_method_apply_fwd: u8 = 248;
        /// Emit-time fusion: `get_loc0` + `get_field`. Size/stack match
        /// `get_loc0`; the following `get_field` stays in the stream.
        pub const get_loc0_field: u8 = 249;
        /// Emit-time fusion: `lt` + `if_false8`. Size/stack match `lt`;
        /// the following `if_false8` stays in the stream (poll lives there).
        pub const cmp_if_false8: u8 = 250;
        /// Emit-time fusion: `put_loc8` + `get_loc8`. Size/stack match
        /// `put_loc8`; the following `get_loc8` stays in the stream.
        pub const put_loc8_get_loc8: u8 = 251;
        /// Emit-time fusion: `push_this` + `put_loc0`. Size/stack match
        /// `push_this`; the following `put_loc0` stays in the stream.
        pub const push_this_put_loc0: u8 = 252;
        /// Emit-time fusion: `put_loc0` + `get_loc0`. Size/stack match
        /// `put_loc0`; the following `get_loc0` stays in the stream.

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

        /// Parser-phase label references use the ordinary 32-bit jump operand
        /// with this tag until `resolve_variables` binds them to absolute PCs.
        /// Real parser byte offsets are constrained below 2 GiB.
        pub const parser_label_tag: u32 = 0x8000_0000;

        /// Number of real (DEF) opcodes; ids 0..op_count-1 are claimed.
        pub const op_count: u16 = 254;
        /// First id of the temp/short overlap range (OP_nop + 1).
        pub const op_temp_start: u8 = 178;
        /// One past the last temp id (exclusive).
        pub const op_temp_end: u8 = 197;
        /// Number of temp opcodes (= short-entry shift in `opcode_info`).
        pub const op_temp_count: u8 = 19;
    };

    /// Operand of `op.using` (244). `add_base + DisposalHint` is add_resource.
    pub const using_sub = struct {
        pub const create: u8 = 0;
        pub const dispose: u8 = 1;
        pub const dispose_throw: u8 = 2;
        /// Reclaimed type-test shorts (were ids 240/242/243).
        pub const is_undefined: u8 = 3;
        pub const typeof_is_undefined: u8 = 4;
        pub const typeof_is_function: u8 = 5;
        /// Reclaimed zoo-cold shorts (were ids 23/32/26/19) for fusion v4.
        pub const insert4: u8 = 6;
        pub const rot5l: u8 = 7;
        pub const perm5: u8 = 8;
        pub const dup2: u8 = 9;
        pub const swap2: u8 = 10;
        pub const rot3r: u8 = 11;
        pub const rot4l: u8 = 12;
        pub const dup3: u8 = 13;
        pub const dup1: u8 = 14;

        /// Cold-plane reclamations (2026-08-27, opcode-space reclaim). These
        /// opcodes execute 0 times in 41.9 billion across the benchmark suite;
        /// they pay a second-level branch they will never notice, and hand
        /// their first-class ids to the typed family. See
        /// docs/perf/opcode-space-survey.md §7.
        pub const check_ctor_return: u8 = 15;
        pub const set_proto: u8 = 16;
        pub const put_super_value: u8 = 17;
        pub const to_object: u8 = 18;

        /// Add-resource hints occupy everything from here up, so the free
        /// sub-slots are the gap below it. Raised from 16 to 64 to open that
        /// gap (encoding is internal to a single compilation).
        pub const add_base: u8 = 64;

        pub fn add(hint: u8) u8 {
            return add_base + hint;
        }

        pub fn isAdd(sub: u8) bool {
            return sub >= add_base;
        }

        pub fn addHint(sub: u8) u8 {
            return sub - add_base;
        }

        pub fn stackPop(sub: u8) u8 {
            if (isAdd(sub)) return 2;
            return switch (sub) {
                create => 0,
                dispose => 1,
                dispose_throw => 2,
                is_undefined, typeof_is_undefined, typeof_is_function => 1,
                insert4 => 4,
                rot5l, perm5 => 5,
                dup2 => 2,
                swap2, rot4l => 4,
                rot3r => 3,
                dup3 => 3,
                dup1 => 2,
                check_ctor_return => 1,
                set_proto => 2,
                put_super_value => 4,
                to_object => 1,
                else => 0,
            };
        }

        pub fn stackPush(sub: u8) u8 {
            if (isAdd(sub)) return 0;
            return switch (sub) {
                create => 1,
                dispose => 1,
                dispose_throw => 1,
                is_undefined, typeof_is_undefined, typeof_is_function => 1,
                insert4, rot5l, perm5 => 5,
                dup2, swap2, rot4l => 4,
                rot3r => 3,
                dup3 => 6,
                dup1 => 3,
                check_ctor_return => 2,
                set_proto => 1,
                put_super_value => 0,
                to_object => 1,
                else => 0,
            };
        }
    };

    pub const op_info_len: usize = 273;

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
        .{ .name = "unused_16", .size = 1, .n_pop = 0, .n_push = 0, .fmt = .none }, // [16] id 16 -- RETIRED 2026-08-27 (no emission site, 0 executions in 41.9e9), available
        .{ .name = "dup", .size = 1, .n_pop = 1, .n_push = 2, .fmt = .none }, // [17] id 17
        .{ .name = "get_loc8_push_i8", .size = 2, .n_pop = 0, .n_push = 1, .fmt = .loc8 }, // [18] id 18
        .{ .name = "push_0_or", .size = 1, .n_pop = 0, .n_push = 1, .fmt = .none }, // [19] id 19
        .{ .name = "push_i8_add", .size = 2, .n_pop = 0, .n_push = 1, .fmt = .i8 }, // [20] id 20
        .{ .name = "insert2", .size = 1, .n_pop = 2, .n_push = 3, .fmt = .none }, // [21] id 21
        .{ .name = "insert3", .size = 1, .n_pop = 3, .n_push = 4, .fmt = .none }, // [22] id 22
        .{ .name = "push_2_sar", .size = 1, .n_pop = 0, .n_push = 1, .fmt = .none }, // [23] id 23
        .{ .name = "perm3", .size = 1, .n_pop = 3, .n_push = 3, .fmt = .none }, // [24] id 24
        .{ .name = "perm4", .size = 1, .n_pop = 4, .n_push = 4, .fmt = .none }, // [25] id 25
        .{ .name = "sar_get_array_el", .size = 1, .n_pop = 2, .n_push = 1, .fmt = .none }, // [26] id 26
        .{ .name = "swap", .size = 1, .n_pop = 2, .n_push = 2, .fmt = .none }, // [27] id 27
        .{ .name = "push_0_shr", .size = 1, .n_pop = 0, .n_push = 1, .fmt = .none }, // [28] id 28
        .{ .name = "rot3l", .size = 1, .n_pop = 3, .n_push = 3, .fmt = .none }, // [29] id 29
        .{ .name = "get_loc8_push_1", .size = 2, .n_pop = 0, .n_push = 1, .fmt = .loc8 }, // [30] id 30
        .{ .name = "get_var_ref0_get_loc8", .size = 1, .n_pop = 0, .n_push = 1, .fmt = .none }, // [31] id 31
        .{ .name = "get_loc8_push_2", .size = 2, .n_pop = 0, .n_push = 1, .fmt = .loc8 }, // [32] id 32
        .{ .name = "call_constructor", .size = 3, .n_pop = 2, .n_push = 1, .fmt = .npop }, // [33] id 33
        .{ .name = "call", .size = 3, .n_pop = 1, .n_push = 1, .fmt = .npop }, // [34] id 34
        .{ .name = "tail_call", .size = 3, .n_pop = 1, .n_push = 0, .fmt = .npop }, // [35] id 35
        .{ .name = "call_method", .size = 3, .n_pop = 2, .n_push = 1, .fmt = .npop }, // [36] id 36
        .{ .name = "tail_call_method", .size = 3, .n_pop = 2, .n_push = 0, .fmt = .npop }, // [37] id 37
        .{ .name = "array_from", .size = 3, .n_pop = 0, .n_push = 1, .fmt = .npop }, // [38] id 38
        .{ .name = "apply", .size = 3, .n_pop = 3, .n_push = 1, .fmt = .u16 }, // [39] id 39
        .{ .name = "return", .size = 1, .n_pop = 1, .n_push = 0, .fmt = .none }, // [40] id 40
        .{ .name = "return_undef", .size = 1, .n_pop = 0, .n_push = 0, .fmt = .none }, // [41] id 41
        .{ .name = "unused_42", .size = 1, .n_pop = 0, .n_push = 0, .fmt = .none }, // [42] id 42 -- RECLAIMED 2026-08-27, available
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
        .{ .name = "unused_72", .size = 1, .n_pop = 0, .n_push = 0, .fmt = .none }, // [72] id 72 -- RECLAIMED 2026-08-27 (cold plane; 3/3 engines have no super-write opcode), available
        .{ .name = "define_field", .size = 5, .n_pop = 2, .n_push = 1, .fmt = .atom }, // [73] id 73
        .{ .name = "set_name", .size = 5, .n_pop = 1, .n_push = 1, .fmt = .atom }, // [74] id 74
        .{ .name = "set_name_computed", .size = 1, .n_pop = 2, .n_push = 2, .fmt = .none }, // [75] id 75
        .{ .name = "unused_76", .size = 1, .n_pop = 0, .n_push = 0, .fmt = .none }, // [76] id 76 -- RECLAIMED 2026-08-27 (cold plane), available
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
        .{ .name = "unused_111", .size = 1, .n_pop = 0, .n_push = 0, .fmt = .none }, // [111] id 111 -- RECLAIMED 2026-08-27 (cold plane), available
        .{ .name = "to_propkey", .size = 1, .n_pop = 1, .n_push = 1, .fmt = .none }, // [112] id 112
        // The row carries the non-put stack effect; the put form's 2/1 comes
        // from the flags byte, like the `using` cold plane's sub table.
        .{ .name = "dyn_env_probe", .size = 10, .n_pop = 1, .n_push = 0, .fmt = .atom_label_u8 }, // [113] id 113
        .{ .name = "unused_114", .size = 1, .n_pop = 0, .n_push = 0, .fmt = .none }, // [114] id 114 -- MERGED 2026-08-27 into dyn_env_probe (was with_put_var), available
        .{ .name = "unused_115", .size = 1, .n_pop = 0, .n_push = 0, .fmt = .none }, // [115] id 115 -- MERGED 2026-08-27 into dyn_env_probe (was with_delete_var), available
        .{ .name = "unused_116", .size = 1, .n_pop = 0, .n_push = 0, .fmt = .none }, // [116] id 116 -- MERGED 2026-08-27 into dyn_env_probe (was with_make_ref), available
        .{ .name = "unused_117", .size = 1, .n_pop = 0, .n_push = 0, .fmt = .none }, // [117] id 117 -- MERGED 2026-08-27 into dyn_env_probe (was with_get_ref), available
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
        .{ .name = "to_number", .size = 1, .n_pop = 1, .n_push = 1, .fmt = .none }, // [139] id 139
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
        .{ .name = "get_field_field2", .size = 5, .n_pop = 1, .n_push = 1, .fmt = .atom }, // [259] id 240
        .{ .name = "is_null", .size = 1, .n_pop = 1, .n_push = 1, .fmt = .none }, // [260] id 241 (short, shifted)
        .{ .name = "get_var_field", .size = 3, .n_pop = 0, .n_push = 1, .fmt = .var_ref }, // [261] id 242
        .{ .name = "get_loc2_field2", .size = 1, .n_pop = 0, .n_push = 1, .fmt = .none_loc }, // [262] id 243
        .{ .name = "using", .size = 2, .n_pop = 0, .n_push = 1, .fmt = .u8 }, // [263] id 244
        .{ .name = "get_field2_call_method", .size = 5, .n_pop = 1, .n_push = 2, .fmt = .atom }, // [264] id 245
        .{ .name = "get_loc2_field", .size = 1, .n_pop = 0, .n_push = 1, .fmt = .none_loc }, // [265] id 246
        .{ .name = "eq_if_false8", .size = 1, .n_pop = 2, .n_push = 1, .fmt = .none }, // [266] id 247
        .{ .name = "call_method_apply_fwd", .size = 3, .n_pop = 2, .n_push = 1, .fmt = .npop }, // [267] id 248
        .{ .name = "get_loc0_field", .size = 1, .n_pop = 0, .n_push = 1, .fmt = .none_loc }, // [268] id 249
        .{ .name = "cmp_if_false8", .size = 1, .n_pop = 2, .n_push = 1, .fmt = .none }, // [269] id 250
        .{ .name = "put_loc8_get_loc8", .size = 2, .n_pop = 1, .n_push = 0, .fmt = .loc8 }, // [270] id 251
        .{ .name = "push_this_put_loc0", .size = 1, .n_pop = 0, .n_push = 1, .fmt = .none }, // [271] id 252
        .{ .name = "unused_253", .size = 1, .n_pop = 0, .n_push = 0, .fmt = .none }, // [272] id 253 -- RETIRED 2026-08-27 (R0): 8 executions in 41.9e9; fusion rule removed, available
    };

    /// Name-free production view of `opcode_info`, matching QuickJS's
    /// non-DUMP_BYTECODE table layout. Generated from the single authoritative
    /// table above so temporary/short overlap metadata cannot drift.
    pub const compact_opcode_info: [op_info_len]CompactInfo = blk: {
        var table: [op_info_len]CompactInfo = undefined;
        for (opcode_info, 0..) |info, index| {
            table[index] = .{
                .size = info.size,
                .n_pop = info.n_pop,
                .n_push = info.n_push,
                .fmt = info.fmt,
            };
        }
        break :blk table;
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
        pub const home_object: u8 = 4;
        pub const var_object: u8 = 5;
        pub const import_meta: u8 = 6;
        pub const null_proto: u8 = 7;
        pub const dstr_get: u8 = 8;
        pub const dstr_elide: u8 = 9;
        pub const dstr_rest: u8 = 10;
        pub const dstr_obj_rest: u8 = 11;
        pub const dstr_close: u8 = 12;
        pub const dstr_require_iterator: u8 = 13;
    };

    /// Final-view lookup, for bytecode after `resolve_labels`: ids in the
    /// temp/short overlap range (op_temp_start..op_temp_end-1) resolve to
    /// the SHORT opcode entry, stored `op.op_temp_count` slots past the
    /// id. Mirrors QuickJS `short_opcode_info` (quickjs.c:21842). Returns
    /// null for ids no opcode claims (op.op_count..255).
    pub inline fn finalInfo(op_id: u8) ?*const Info {
        if (op_id >= op.op_count) return null;
        const index: usize = if (op_id >= op.op_temp_start)
            @as(usize, op_id) + op.op_temp_count
        else
            op_id;
        return &opcode_info[index];
    }

    /// Compact final-view lookup for production hot passes. The index mapping
    /// is the same `short_opcode_info` mapping as `finalInfo`.
    pub inline fn finalCompactInfo(op_id: u8) ?*const CompactInfo {
        if (op_id >= op.op_count) return null;
        const index: usize = if (op_id >= op.op_temp_start)
            @as(usize, op_id) + op.op_temp_count
        else
            op_id;
        return &compact_opcode_info[index];
    }

    /// Phase-1-view lookup, for parser-emitted streams before
    /// `resolve_labels`: ids in the temp/short overlap range resolve to
    /// the TEMP opcode entry at its id position. Mirrors QuickJS's bare
    /// `opcode_info[op]` indexing (quickjs.c:21826). zjs deviation: the
    /// parser also emits some final-form opcodes above the overlap range
    /// in phase 1 (`get_length`, `if_false8`, `is_undefined`, ...), so
    /// ids outside the overlap fall through to the final view (the two
    /// views agree everywhere but the overlap).
    /// The parser keeps empty strings in the wide `push_atom_value` form;
    /// `resolve_labels` alone introduces `push_empty_string`. Consequently,
    /// overlap id 192 is only the temp `scope_in_private_field` in phase 1.
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

    /// F0a0 (§11.7 D9): the physical half of the declaration source — a
    /// derived mirror of the id space, a mechanically generated ledger, and
    /// comptime assertions that both agree with `opcode_info`.
    ///
    /// **Scope boundary, and it is checkable**: everything here must stay
    /// expressible in the vocabulary the table already has. The moment this
    /// needs a `LogicalOpcode` it has crossed into F0a1, which is blocked on
    /// the §10.8 freeze. `PhysicalSlotState` from the design carries a
    /// `LogicalOpcode` payload for exactly that reason and is deliberately
    /// NOT used here.
    ///
    /// The ledger exists because the id budget was previously a number
    /// people re-derived by hand and quoted from memory. It is now a single
    /// derived fact that cannot drift from the table without failing to
    /// compile.
    pub const physical = struct {
        /// Slot classification in today's terms only.
        pub const SlotState = enum {
            /// A final-form opcode claims this id and the row names it.
            claimed,
            /// The row survives as `unused_<id>` so table indices do not
            /// shift, but the id itself has been reclaimed and is available.
            reclaimed,
            /// No row at all: the id is past `op_count`.
            no_row,
        };

        const unused_prefix = "unused_";

        fn isReclaimedName(name: []const u8) bool {
            return name.len > unused_prefix.len and
                std.mem.eql(u8, name[0..unused_prefix.len], unused_prefix);
        }

        /// Comptime table, not a per-call classification. The naming
        /// convention is the declaration, but reading it at run time meant a
        /// seven-byte compare for every instruction the decoder touched --
        /// measured as -4.08% on CodeLoad, the benchmark that exercises the
        /// compile path. Classify once.
        const state_table: [256]SlotState = blk: {
            @setEvalBranchQuota(8000);
            var t: [256]SlotState = undefined;
            for (&t, 0..) |*slot, raw| {
                const info = finalInfo(@intCast(raw));
                slot.* = if (info) |row|
                    (if (isReclaimedName(row.name)) .reclaimed else .claimed)
                else
                    .no_row;
            }
            break :blk t;
        };

        pub inline fn stateOf(op_id: u8) SlotState {
            return state_table[op_id];
        }

        pub const Ledger = struct {
            /// Ids a final-form opcode still claims.
            claimed: u16,
            /// Reclaimed ids that keep an `unused_<id>` row.
            reclaimed: u16,
            /// Ids with no row at all (past `op_count`).
            no_row: u16,

            /// What the roadmap calls "free": reclaimed plus never-claimed.
            pub fn free(self: Ledger) u16 {
                return self.reclaimed + self.no_row;
            }

            pub fn total(self: Ledger) u16 {
                return self.claimed + self.reclaimed + self.no_row;
            }
        };

        pub const ledger: Ledger = blk: {
            @setEvalBranchQuota(4000);
            var acc = Ledger{ .claimed = 0, .reclaimed = 0, .no_row = 0 };
            for (0..256) |raw| {
                switch (stateOf(@intCast(raw))) {
                    .claimed => acc.claimed += 1,
                    .reclaimed => acc.reclaimed += 1,
                    .no_row => acc.no_row += 1,
                }
            }
            break :blk acc;
        };

        comptime {
            @setEvalBranchQuota(20000);
            // Every id classifies, exactly once.
            if (ledger.total() != 256)
                @compileError("physical ledger does not cover the 8-bit id space");

            // A row exists iff the id is below op_count.
            for (0..256) |raw| {
                const id: u8 = @intCast(raw);
                const has_row = finalInfo(id) != null;
                if (has_row != (id < op.op_count))
                    @compileError("row presence disagrees with op_count");
            }

            // A reclaimed row must name its own id. Renaming a row to
            // `unused_N` with the wrong N is a silent way to lose track of
            // which id was actually freed, and nothing else would catch it.
            for (0..op.op_count) |raw| {
                const id: u8 = @intCast(raw);
                const info = finalInfo(id).?;
                if (!isReclaimedName(info.name)) continue;
                const digits = info.name[unused_prefix.len..];
                var parsed: u16 = 0;
                for (digits) |c| {
                    if (c < '0' or c > '9')
                        @compileError("reclaimed row name is not `unused_<decimal>`");
                    parsed = parsed * 10 + (c - '0');
                }
                if (parsed != id)
                    @compileError("reclaimed row names an id other than its own");

                // A reclaimed row must also carry the canonical dead shape.
                // Without this, renaming a live opcode's row to `unused_<its
                // own id>` is self-consistent and compiles clean, silently
                // marking an id free while its handler and emit sites are
                // still there. The shape is the only physical-layer signal
                // available at F0a0 scope -- whether an opcode is still
                // emitted is logical-layer knowledge (F0a1).
                if (info.size != 1 or info.n_pop != 0 or info.n_push != 0 or info.fmt != .none)
                    @compileError("reclaimed row does not carry the canonical dead shape (size 1, 0/0, fmt none)");
            }

            // The temp/short overlap is the structure that makes a naive
            // "count the rows" wrong, so pin it: in that range the phase-1
            // view and the final view must resolve to different rows.
            for (op.op_temp_start..op.op_temp_end) |raw| {
                const id: u8 = @intCast(raw);
                if (phase1Info(id).? == finalInfo(id).?)
                    @compileError("temp/short overlap range does not actually overlap");
            }
        }
    };

    /// F0a1 (§10.8 合同 1 + 5a、不变量 5/6；gate 见 §10.8 末表): the logical
    /// half of the declaration source lives in `src/opcode_logical.zig`,
    /// which imports nothing from here so the dependency stays
    /// exec -> bytecode -> logical (P0-3). This block is the join: it proves
    /// the logical declaration and the physical table describe the same
    /// instruction set.
    pub const logical = @import("opcode_logical.zig");

    comptime {
        @setEvalBranchQuota(40000);

        // Format mirror agrees field for field. Ownership of Format moves to
        // the declaration source at G0; until then a reorder here must break
        // the build rather than silently re-map every operand template.
        const mine = @typeInfo(Format).@"enum".fields;
        const theirs = @typeInfo(logical.Format).@"enum".fields;
        if (mine.len != theirs.len)
            @compileError("logical.Format has a different field count than opcode.Format");
        for (mine, theirs) |a, b| {
            if (!std.mem.eql(u8, a.name, b.name) or a.value != b.value)
                @compileError("logical.Format disagrees with opcode.Format field for field");
        }

        // Every final logical form names a claimed physical id, and every
        // claimed id has exactly one final form. This is what makes the two
        // halves one instruction set rather than two lists.
        var seen = [_]bool{false} ** 256;
        for (@typeInfo(logical.LogicalOpcode).@"enum".fields) |f| {
            if (f.value >= 300) continue; // compiler-only or cold-plane form
            if (f.value > 255)
                @compileError("final logical form has a value outside the 8-bit id space");
            const id: u8 = @intCast(f.value);
            if (physical.stateOf(id) != .claimed)
                @compileError("final logical form names an id that is not claimed");
            const info = finalInfo(id).?;
            if (!std.mem.eql(u8, info.name, f.name))
                @compileError("final logical form and physical row disagree on the name");
            if (seen[id]) @compileError("two final logical forms claim the same id");
            seen[id] = true;
        }
        for (0..256) |raw| {
            const id: u8 = @intCast(raw);
            if (physical.stateOf(id) == .claimed and !seen[id])
                @compileError("a claimed physical id has no final logical form");
        }

        // Contract 1: operand declaration and physical row must agree on
        // size. Payload widths sum to `size - 1`; burned-in operands add
        // nothing. This is what proves the templates describe the encoding
        // that actually ships, and it is why kind and width are separate
        // axes -- `loc8` is a local in one byte, `loc` a local in two.
        for (@typeInfo(logical.LogicalOpcode).@"enum".fields) |f| {
            // Three ranges: final forms below 300 own a physical id;
            // compiler-only forms at 300+ have their row at their temp id in
            // the phase-1 view (four of the operand overrides are temp forms,
            // so skipping them would leave a quarter of the override table
            // unproven); cold-plane residents at 400+ own no id at all and
            // are checked separately.
            if (f.value >= 400) continue;
            const id: u8 = if (f.value >= 300)
                op.op_temp_start + @as(u8, @intCast(f.value - 300))
            else
                @intCast(f.value);
            const info = if (f.value >= 300) phase1Info(id).? else finalInfo(id).?;
            const form: logical.LogicalOpcode = @enumFromInt(f.value);
            const fmt: logical.Format = @enumFromInt(@intFromEnum(info.fmt));
            const operands = logical.operandsOf(form, fmt);
            var payload: usize = 0;
            for (operands) |operand| {
                switch (operand.source) {
                    .payload => |pl| payload += switch (pl.width) {
                        .u8, .i8 => 1,
                        .u16, .i16 => 2,
                        .u32, .i32 => 4,
                    },
                    .fixed => {},
                }
                // Assertion 15: addressing operands carry a dataflow
                // direction, everything else must not pretend to.
                const addressing = switch (operand.kind) {
                    .local_slot, .arg_slot, .var_ref_slot => true,
                    else => false,
                };
                if (addressing and operand.flow == null)
                    @compileError("slot operand is missing its flow");
                if (!addressing and operand.flow != null)
                    @compileError("non-addressing operand declares a flow");
            }
            if (payload + 1 != info.size)
                @compileError("declared operand widths do not sum to the physical row size");
        }

        // Invariant 5 applied to the override table: exactly one source of
        // truth per form. A format that is ambiguous must be overridden; a
        // format that is not must not be.
        for (logical.operand_overrides) |o| {
            const raw: u16 = @intFromEnum(o.form);
            if (raw >= 400) @compileError("cold-plane form cannot use an operand override yet");
            const id: u8 = if (raw >= 300)
                op.op_temp_start + @as(u8, @intCast(raw - 300))
            else
                @intCast(raw);
            const info = if (raw >= 300) phase1Info(id).? else finalInfo(id).?;
            const fmt: logical.Format = @enumFromInt(@intFromEnum(info.fmt));
            if (logical.operandTemplate(fmt) != null)
                @compileError("operand override shadows an unambiguous format template");
        }

        // Contract 5a / P0-6. The affine expressions must reproduce the
        // physical row's constant part, and the operand tables must cover
        // exactly the operand's accepted value set (assertion 17).
        for (logical.dynamic_stack) |d| {
            const id: u8 = @intCast(@intFromEnum(d.form));
            const info = finalInfo(id).?;
            switch (d.shape) {
                .affine => |expr| switch (expr) {
                    .affine => |a| {
                        // The fixed part of the expression is the row's own
                        // pop/push; only the scaled part is new information.
                        if (a.pop_base != info.n_pop or a.push_base != info.n_push)
                            @compileError("affine stack expression disagrees with the physical row's constant part");
                    },
                    else => @compileError("dynamic_stack .affine shape must hold an affine expression"),
                },
                .operand_table_from_legacy => {},
            }
        }

        // `using`: every one of the 256 sub values is accepted (the switch
        // has an `else` arm and the add range is open), so coverage means
        // all 256. This is why the rows are generated rather than listed.
        {
            var covered: usize = 0;
            for (0..256) |raw| {
                const sub: u8 = @intCast(raw);
                _ = using_sub.stackPop(sub);
                _ = using_sub.stackPush(sub);
                covered += 1;
            }
            if (covered != 256)
                @compileError("using sub table does not cover its whole operand space");
        }

        // `dyn_env_probe`: only ten of the 256 flag bytes decode. Coverage is
        // over the ACCEPTED set, so the assertion is that the decoder and the
        // effect agree on exactly which bytes those are -- a byte the decoder
        // rejects must have no effect defined, and one it accepts must.
        {
            var accepted: usize = 0;
            for (0..256) |raw| {
                const byte: u8 = @intCast(raw);
                if (dyn_env.decode(byte)) |flags| {
                    accepted += 1;
                    // Fall-through and branch effects must both be defined.
                    _ = flags.stackPop();
                    _ = flags.stackPush();
                    _ = flags.branchStackDelta();
                }
            }
            if (accepted != 10)
                @compileError("dyn_env_probe accepts a different number of flag bytes than its effect table covers");
        }

        // Contract 5a, cross-checked against the shipping stack pass rather
        // than restated: the branch edge of `dyn_env_probe` must equal the
        // fall-through effect plus the declared delta, for every accepted
        // kind. This is the check that would catch the declaration drifting
        // away from `computeStackSize`.
        for (0..256) |raw| {
            const byte: u8 = @intCast(raw);
            const flags = dyn_env.decode(byte) orelse continue;
            const fall_through: i32 = @as(i32, flags.stackPush()) - @as(i32, flags.stackPop());
            const branch: i32 = fall_through + flags.branchStackDelta();
            const expected: i32 = switch (flags.kind) {
                .read, .delete => 0, // drops the object, pushes the result
                .get_ref, .make_ref => 1, // keeps the object underneath
                .put => -2, // consumes both the object and the stored value
            };
            if (branch != expected)
                @compileError("dyn_env_probe branch-edge height disagrees with contract 5a");
        }

        // The declared cold-plane slot must be the slot the carrier actually
        // uses. Without this the sixteen demoted opcodes are declared but
        // unanchored, which is the same blindness the demotion caused in the
        // first place -- a name in one place and a number in another.
        for (@typeInfo(logical.LogicalOpcode).@"enum".fields) |f| {
            if (f.value < 400) continue;
            const form: logical.LogicalOpcode = @enumFromInt(f.value);
            const plane = logical.planeOf(form);
            switch (plane) {
                .sub => |sub| {
                    if (sub.carrier != .using)
                        @compileError("only the `using` carrier exists today");
                    // The logical name is `using_<sub>`; the slot must match
                    // the `using_sub` constant of that name.
                    const bare = f.name["using_".len..];
                    var matched = false;
                    for (@typeInfo(using_sub).@"struct".decls) |d| {
                        if (!std.mem.eql(u8, d.name, bare)) continue;
                        if (@field(using_sub, d.name) != sub.slot)
                            @compileError("declared cold-plane slot disagrees with using_sub");
                        matched = true;
                    }
                    if (!matched)
                        @compileError("cold-plane form names a sub that using_sub does not declare");
                },
                .main => @compileError("a 400+ logical id must be a cold-plane resident"),
            }
        }

        // Invariant 5 migration mirror, proved rather than assumed: the
        // derived inline policy must reproduce the hand-written reject list
        // exactly, form for form, before that list is deleted. A silent
        // difference here is precisely the defect class this replaces --
        // nothing else would notice, because the only observable effect is
        // which bodies get inlined.
        {
            const hand_written = [_]u8{
                op.eval,            op.apply_eval,          op.special_object,
                op.fclosure,        op.fclosure8,           op.apply,
                op.rest,            op.initial_yield,       op.yield,
                op.yield_star,      op.async_yield_star,    op.await,
                op.return_async,    op.get_super,           op.get_super_value,
                op.get_private_field, op.put_private_field, op.define_private_field,
                op.define_class,    op.define_class_computed, op.import,
                op.dyn_env_probe,   op.make_loc_ref,        op.make_arg_ref,
                op.make_var_ref_ref, op.make_var_ref,       op.gosub,
                op.@"catch",        op.nip_catch,           op.tail_call,
                op.tail_call_method,
            };
            for (0..256) |raw| {
                const id: u8 = @intCast(raw);
                if (physical.stateOf(id) != .claimed) continue;
                var in_list = false;
                for (hand_written) |listed| {
                    if (listed == id) in_list = true;
                }
                const form: logical.LogicalOpcode = @enumFromInt(id);
                const declared = logical.traitsOf(form).inline_policy == .forbidden;
                if (in_list != declared)
                    @compileError("declared inline policy disagrees with the hand-written reject list");
            }
            // The carrier resident the old list could only reach through a
            // special case must be declared forbidden on the form itself.
            if (logical.traitsOf(.using_put_super_value).inline_policy != .forbidden)
                @compileError("demoted put_super_value lost its inline policy");

            // Same proof for the second hand-written table, which lived in
            // exec/small_inline.zig.
            const forward_list = [_]u8{
                op.apply, op.apply_eval, op.rest, op.eval,
                op.dyn_env_probe, op.fclosure, op.fclosure8,
            };
            for (0..256) |raw| {
                const id: u8 = @intCast(raw);
                if (physical.stateOf(id) != .claimed) continue;
                var in_list = false;
                for (forward_list) |listed| {
                    if (listed == id) in_list = true;
                }
                const form: logical.LogicalOpcode = @enumFromInt(id);
                const declared = logical.traitsOf(form).forward_policy == .forbidden;
                if (in_list != declared)
                    @compileError("declared forward policy disagrees with the hand-written list");
            }
        }

        // P0-2 authority direction: the declaration states the burned-in
        // value and this checks `direct_id - base_id` against it. Never the
        // reverse -- an id that is aliased or moved to a carrier would leave
        // the reverse derivation undefined.
        for (logical.legacy_embedded) |run| {
            const base_id: u16 = @intFromEnum(run.first);
            if (base_id >= 300) @compileError("legacy embedded run starts at a compiler-only form");
            var k: u8 = 0;
            while (k < run.count) : (k += 1) {
                const id: u16 = base_id + k;
                if (id > 255) @compileError("legacy embedded run leaves the id space");
                const member_id: u8 = @intCast(id);
                if (physical.stateOf(member_id) != .claimed)
                    @compileError("legacy embedded run covers an unclaimed id");
                // direct_id - base_id must equal the declared step.
                if (@as(i33, id) - @as(i33, base_id) != @as(i33, k))
                    @compileError("legacy embedded run is not contiguous");
                // Contiguity alone is too weak: ids 195..203 are get_loc0..3
                // then put_loc0..3, so a run declared four too long stays
                // claimed and contiguous while silently spilling into the
                // next family. Verified by injection -- without this check
                // `get_loc0 count = 9` compiles clean.
                const member: logical.LogicalOpcode = @enumFromInt(member_id);
                if (logical.familyOf(member) != logical.familyOf(run.first))
                    @compileError("legacy embedded run spills into another semantic family");
            }
        }
    }

    /// F0b (§10.8 合同 2): the structured decode layer. Consumers stop
    /// reading `code[pc + 1]` and stop switching on the physical id.
    ///
    /// Two layers, per P1-1: hot consumers take a `Header` and reach for
    /// `operandAt` only when they need a value; the fully expanded view is
    /// for cold consumers (disassembler, validator, diff tooling) and is
    /// composed from these two. Zero allocation, no ledger copying, and the
    /// layout is resolved through a comptime table so nothing is recomputed
    /// per call.
    pub const decode = struct {
        pub const Domain = enum { lowered, final };

        pub const Encoding = union(enum) {
            direct: u8,
            carrier: struct { carrier: u8, tag: u8 },
        };

        pub const OperandSlot = struct {
            kind: logical.OperandKind,
            flow: ?logical.Flow,
            /// Byte offset from `payload_pc`, or null for a burned-in value.
            offset: ?u8,
            width: ?logical.Width,
            fixed: i33,
        };

        pub const max_operands = blk: {
            var m: usize = 0;
            for (@typeInfo(logical.Format).@"enum".fields) |f| {
                const fmt: logical.Format = @enumFromInt(f.value);
                if (logical.operandTemplate(fmt)) |t| {
                    if (t.len > m) m = t.len;
                }
            }
            for (logical.operand_overrides) |o| {
                if (o.operands.len > m) m = o.operands.len;
            }
            break :blk m;
        };

        pub const OperandLayout = struct {
            len: u8,
            slots: [max_operands]OperandSlot,

            /// Precomputed answers to the two questions the final-artifact
            /// validator asks of every instruction it walks.
            ///
            /// Without them the validator loops over slots once per
            /// instruction. That loop -- not the checks inside it -- was the
            /// entire cost of the F0b migration: profiling the CodeLoad
            /// compile path on 2026-08-28 put the migrated validator at 72M
            /// instructions where the unmigrated one had been inlined into
            /// the walk and cost nothing measurable, which is the whole of
            /// the +69M regression. The unmigrated validator asked two
            /// questions of a format byte; asking the same two questions of
            /// a slot list means iterating it. So the answers move to
            /// comptime, and the questions stay form-keyed.
            atom_slot: ?u8,
            var_ref_slot: ?u8,
        };

        const layout_table_len = blk: {
            var m: usize = 0;
            for (@typeInfo(logical.LogicalOpcode).@"enum".fields) |f| {
                if (f.value > m) m = f.value;
            }
            break :blk m + 1;
        };

        /// Sparse but stable: indexed by the logical id so `layoutOf` hands
        /// back a pointer rather than rebuilding a layout per decode.
        const layout_table: [layout_table_len]?OperandLayout = blk: {
            @setEvalBranchQuota(60000);
            var table = [_]?OperandLayout{null} ** layout_table_len;
            for (@typeInfo(logical.LogicalOpcode).@"enum".fields) |f| {
                if (f.value >= 400) continue; // carrier residents: F0c
                const id: u8 = if (f.value >= 300)
                    op.op_temp_start + @as(u8, @intCast(f.value - 300))
                else
                    @intCast(f.value);
                const info = if (f.value >= 300) phase1Info(id).? else finalInfo(id).?;
                const form: logical.LogicalOpcode = @enumFromInt(f.value);
                const fmt: logical.Format = @enumFromInt(@intFromEnum(info.fmt));
                const operands = logical.operandsOf(form, fmt);
                var layout = OperandLayout{ .len = @intCast(operands.len), .slots = undefined, .atom_slot = null, .var_ref_slot = null };
                var offset: u8 = 0;
                for (operands, 0..) |operand, i| {
                    switch (operand.source) {
                        .payload => |pl| {
                            const w: u8 = switch (pl.width) {
                                .u8, .i8 => 1,
                                .u16, .i16 => 2,
                                .u32, .i32 => 4,
                            };
                            layout.slots[i] = .{
                                .kind = operand.kind,
                                .flow = operand.flow,
                                .offset = offset,
                                .width = pl.width,
                                .fixed = 0,
                            };
                            offset += w;
                        },
                        .fixed => {
                            // The template's fixed value is a placeholder --
                            // `.none_loc` cannot know whether it is get_loc0
                            // or get_loc2. The real value comes from the
                            // legacy run (P0-2's authority direction:
                            // declaration states base, member value is
                            // base + step). A burned-in operand with no run
                            // covering it is a declaration hole, so this
                            // fails closed rather than defaulting to zero.
                            var resolved: ?i33 = null;
                            for (logical.legacy_embedded) |run| {
                                if (run.operand_index != i) continue;
                                const base: u16 = @intFromEnum(run.first);
                                if (f.value < base or f.value >= base + run.count) continue;
                                resolved = run.base_value + @as(i33, f.value - base);
                            }
                            const value = resolved orelse
                                @compileError("burned-in operand has no legacy embedded run: " ++ f.name);
                            // Cross-check against an authority that is not
                            // the legacy table: the opcode's own name, which
                            // comes from the physical row. `get_loc2`'s slot
                            // must be 2 whatever the run declares. Without
                            // this a wrong base_value is self-consistent and
                            // nothing catches it -- verified by injection.
                            if (nameEncodedOperand(f.name)) |from_name| {
                                if (from_name != value)
                                    @compileError("burned-in value disagrees with the opcode name: " ++ f.name);
                            }
                            layout.slots[i] = .{
                                .kind = operand.kind,
                                .flow = operand.flow,
                                .offset = null,
                                .width = null,
                                .fixed = value,
                            };
                        },
                    }
                }
                var j = operands.len;
                while (j < max_operands) : (j += 1) {
                    layout.slots[j] = .{ .kind = .imm, .flow = null, .offset = null, .width = null, .fixed = 0 };
                }
                for (0..layout.len) |i| {
                    switch (layout.slots[i].kind) {
                        .atom => layout.atom_slot = @intCast(i),
                        .var_ref_slot => layout.var_ref_slot = @intCast(i),
                        else => {},
                    }
                }
                table[f.value] = layout;
            }
            break :blk table;
        };

        /// The value a burned-in operand carries according to the opcode's
        /// own name: `get_loc2` -> 2, `push_3` -> 3, `call1` -> 1,
        /// `push_minus1` -> -1, `get_loc2_field` -> 2. Null when the name
        /// encodes nothing, which is the honest answer for the forms whose
        /// fixed value is not in their name.
        fn nameEncodedOperand(name: []const u8) ?i33 {
            if (std.mem.eql(u8, name, "push_minus1")) return -1;
            const markers = [_][]const u8{ "_var_ref", "_loc", "_arg", "push_", "call" };
            for (markers) |marker| {
                const at = std.mem.indexOf(u8, name, marker) orelse continue;
                const rest = name[at + marker.len ..];
                if (rest.len == 0 or rest[0] < '0' or rest[0] > '9') continue;
                var value: i33 = 0;
                var i: usize = 0;
                while (i < rest.len and rest[i] >= '0' and rest[i] <= '9') : (i += 1)
                    value = value * 10 + (rest[i] - '0');
                return value;
            }
            return null;
        }

        /// One row per form, four bytes, one load per question.
        ///
        /// The F0b migration cost 3.68% of the CodeLoad score, and this is
        /// where nearly all of it was: the byte-oriented code it replaced
        /// took ONE table -- it read `size`, `n_pop` and `n_push` off a
        /// single compact row -- while the migrated path took four, two in
        /// `headerAt` (`finalCompactInfo`, `stateOf`) and two more in
        /// `stackEffect` (`dynamic_by_form`, `finalCompactInfo` again). The
        /// second of those is the worst: `dynamic_by_form` is an array of
        /// optional tagged unions sized for the widest shape, so the common
        /// case paid a wide load to learn it had nothing to do.
        ///
        /// Nothing about F0b required that. The key stays the form; only
        /// the number of tables changes.
        pub const FormRow = extern struct {
            size: u8,
            pop: u8,
            push: u8,
            flags: u8,

            pub const claimed_bit: u8 = 1;
            pub const dynamic_bit: u8 = 2;
            /// The form carries an atom operand. Every atom slot sits at
            /// payload offset 0 (asserted below at table-build time), so a
            /// consumer holding this bit may read the atom at pc+1 without
            /// consulting the wide layout. Replaces the five-way format
            /// comparison `hasAtomFormat` that reader passes carried.
            pub const atom_bit: u8 = 4;
            /// The form carries a label operand (any width). Lets a
            /// validator reject the whole class of label-bearing forms it
            /// did not explicitly admit, instead of maintaining a rejection
            /// list of formats that must be extended by hand when a form is
            /// added.
            pub const label_bit: u8 = 32;
            /// Bits 3-4: width in bytes (0, 1 or 2) of the leading index
            /// operand -- the slot/argc/const-pool immediates the shortening
            /// matchers compare. Derived from the same format whitelist the
            /// readers previously switched on, so the mapping lives in ONE
            /// comptime place instead of per consumer.
            pub const index_width_shift: u3 = 3;

            pub inline fn isClaimed(self: FormRow) bool {
                return self.flags & claimed_bit != 0;
            }
            pub inline fn isDynamic(self: FormRow) bool {
                return self.flags & dynamic_bit != 0;
            }
            pub inline fn hasAtom(self: FormRow) bool {
                return self.flags & atom_bit != 0;
            }
            pub inline fn hasLabel(self: FormRow) bool {
                return self.flags & label_bit != 0;
            }
            pub inline fn indexWidth(self: FormRow) u8 {
                return (self.flags >> index_width_shift) & 3;
            }
        };

        pub const form_row: [layout_table_len]FormRow = blk: {
            @setEvalBranchQuota(60000);
            var t = [_]FormRow{.{ .size = 0, .pop = 0, .push = 0, .flags = 0 }} ** layout_table_len;
            for (@typeInfo(logical.LogicalOpcode).@"enum".fields) |f| {
                if (f.value >= 400) continue; // carrier residents: F0c
                const id: u8 = if (f.value >= 300)
                    op.op_temp_start + @as(u8, @intCast(f.value - 300))
                else
                    @intCast(f.value);
                const info = if (f.value >= 300) phase1Info(id).? else finalCompactInfo(id).?;
                var flags: u8 = 0;
                if (f.value >= 300 or physical.stateOf(id) == .claimed)
                    flags |= FormRow.claimed_bit;
                if (dynamic_by_form[f.value] != null) flags |= FormRow.dynamic_bit;
                switch (info.fmt) {
                    .atom, .atom_u8, .atom_u16, .atom_label_u8, .atom_label_u16 => {
                        flags |= FormRow.atom_bit;
                        // The atom_bit contract: pc+1 is the atom. Check it
                        // against the layout rather than assuming it.
                        const lay = layout_table[f.value].?;
                        if (lay.atom_slot == null or
                            lay.slots[lay.atom_slot.?].offset != 0)
                            @compileError("atom operand not at payload offset 0 for " ++ f.name);
                    },
                    else => {},
                }
                switch (info.fmt) {
                    .label, .label8, .label16, .label_u16, .atom_label_u8, .atom_label_u16 => {
                        flags |= FormRow.label_bit;
                        // Consumers derive the label's offset as
                        // 1 + (hasAtom ? 4 : 0); prove the layout agrees.
                        const lay = layout_table[f.value].?;
                        var found = false;
                        for (0..lay.len) |slot_i| {
                            if (lay.slots[slot_i].kind == .label) {
                                const want: u8 = if (flags & FormRow.atom_bit != 0) 4 else 0;
                                if (lay.slots[slot_i].offset != want)
                                    @compileError("label operand offset breaks the 1+4*atom rule for " ++ f.name);
                                found = true;
                            }
                        }
                        if (!found) @compileError("label format without a label slot for " ++ f.name);
                    },
                    else => {},
                }
                const index_width: u8 = switch (info.fmt) {
                    .u8, .i8, .loc8, .const8 => 1,
                    .u16, .npop, .loc, .arg, .var_ref => 2,
                    else => 0,
                };
                if (index_width != 0) {
                    // The indexWidth contract mirrors atom_bit's: the index
                    // operand is the LEADING operand, so holders of a nonzero
                    // width may read at pc+1 without the wide layout.
                    const lay = layout_table[f.value].?;
                    if (lay.len == 0 or lay.slots[0].offset != 0)
                        @compileError("index operand not at payload offset 0 for " ++ f.name);
                }
                flags |= index_width << FormRow.index_width_shift;
                t[f.value] = .{
                    .size = info.size,
                    .pop = info.n_pop,
                    .push = info.n_push,
                    .flags = flags,
                };
            }
            break :blk t;
        };

        /// Domain rows for the two full-stream compiler walks, indexed by
        /// the PHYSICAL id so a decode is one load. The remapping (temp
        /// range -> 300+), the side-table rejections (label/line_num) and
        /// the claimed test are baked into the row at comptime -- this is
        /// the same lesson the F0b regression taught at the final domain:
        /// the hand table these replace was fast precisely because those
        /// decisions were baked, and expanding them into per-instruction
        /// arithmetic measured +29M instructions in resolve_variables.run.
        /// Size zero is the reject sentinel (unclaimed, reclaimed, or a
        /// side-table entity in this domain).
        pub const DomainRow = extern struct {
            size: u8,
            flags: u8,
            form_index: u16,
        };

        fn domainRowFor(index: u16, reject: bool) DomainRow {
            const row = form_row[index];
            const ok = !reject and row.isClaimed() and row.size != 0;
            return .{
                .size = if (ok) row.size else 0,
                .flags = row.flags,
                .form_index = index,
            };
        }

        pub const phase1_row: [256]DomainRow = blk: {
            @setEvalBranchQuota(20000);
            var t: [256]DomainRow = undefined;
            for (0..256) |i| {
                const id: u8 = @intCast(i);
                if (id >= op.op_count) {
                    t[i] = .{ .size = 0, .flags = 0, .form_index = 0 };
                    continue;
                }
                const index: u16 = if (id >= op.op_temp_start and id < op.op_temp_end)
                    @as(u16, 300) + (id - op.op_temp_start)
                else
                    id;
                // Compare by value: a reclaimed id has no enum tag, so the
                // conversion is illegal exactly on the inputs the sentinel
                // exists to reject (invariant 5, comptime edition).
                const side_table = index == @intFromEnum(logical.LogicalOpcode.label) or
                    index == @intFromEnum(logical.LogicalOpcode.line_num);
                t[i] = domainRowFor(index, side_table);
            }
            break :blk t;
        };

        /// Parser-domain candidate rows: the temp interpretation of the
        /// overlap range, with atom-less temps marked forced. Everything
        /// else falls back to `final_parser_row`.
        pub const parser_temp_row: [256]DomainRow = blk: {
            @setEvalBranchQuota(20000);
            var t: [256]DomainRow = undefined;
            for (0..256) |i| {
                const id: u8 = @intCast(i);
                if (id < op.op_temp_start or id >= op.op_temp_end) {
                    t[i] = .{ .size = 0, .flags = 0, .form_index = 0 };
                    continue;
                }
                const index: u16 = @as(u16, 300) + (id - op.op_temp_start);
                const side_table = index == @intFromEnum(logical.LogicalOpcode.label) or
                    index == @intFromEnum(logical.LogicalOpcode.line_num);
                t[i] = domainRowFor(index, side_table);
            }
            break :blk t;
        };

        pub const final_parser_row: [256]DomainRow = blk: {
            @setEvalBranchQuota(20000);
            var t: [256]DomainRow = undefined;
            for (0..256) |i| {
                const id: u8 = @intCast(i);
                if (id >= op.op_count) {
                    t[i] = .{ .size = 0, .flags = 0, .form_index = 0 };
                    continue;
                }
                t[i] = domainRowFor(id, false);
            }
            break :blk t;
        };

        /// Parser-domain decode, for the MIXED Builder stream (contract 2,
        /// 2026-08-28 revision). In that stream an id in the temp range may
        /// be either the temp instruction or an already-selected final
        /// short opcode, and the only thing that can tell them apart is the
        /// atom ledger: the temp interpretation of an atom-carrying temp id
        /// must find its own atom at the ledger cursor. The ledger is
        /// therefore an INPUT of this domain, not state a caller threads
        /// around the decoder -- which is why this entry does not share
        /// `headerAt`'s signature.
        ///
        /// Classification is derived from the declaration, not listed:
        /// a temp form with an atom operand is a candidate (disambiguate),
        /// `label`/`line_num` are rejected (side-table entities in the v2
        /// Builder), and every other temp form IS the temp interpretation.
        /// The retired hand-written tables in cfg.zig enumerated the same
        /// three classes by id; a comptime assertion there proved the
        /// derived view identical before they were deleted.
        pub inline fn headerAtParser(
            code: []const u8,
            atoms_ledger: []const u32,
            pc: u32,
            atom_index: u32,
        ) Error!Header {
            if (pc >= code.len) return error.BytecodeOverflow;
            const id = code[pc];
            const trow = parser_temp_row[id];
            if (trow.size != 0) {
                const form: logical.LogicalOpcode = @enumFromInt(trow.form_index);
                if (trow.flags & FormRow.atom_bit != 0) {
                    // Candidate: the temp interpretation must find its own
                    // atom at the ledger cursor; otherwise fall through to
                    // the final interpretation of the same byte.
                    const end = @as(usize, pc) + trow.size;
                    if (end <= code.len and atom_index < atoms_ledger.len) {
                        const operand = std.mem.readInt(u32, code[pc + 1 ..][0..4], .little);
                        if (operand == atoms_ledger[atom_index])
                            return .{ .form = form, .instruction_pc = pc, .size = trow.size, .flags = trow.flags };
                    }
                } else {
                    const end = @as(usize, pc) + trow.size;
                    if (end > code.len) return error.BytecodeOverflow;
                    return .{ .form = form, .instruction_pc = pc, .size = trow.size, .flags = trow.flags };
                }
            } else if (id >= op.op_temp_start and id < op.op_temp_end) {
                // A temp-range id with a zero temp row is a side-table
                // entity (label/line_num): corruption in this stream.
                return error.InvalidOpcode;
            }
            const row = final_parser_row[id];
            if (row.size == 0) return error.InvalidOpcode;
            const next = @as(usize, pc) + row.size;
            if (next > code.len) return error.BytecodeOverflow;
            return .{ .form = @enumFromInt(row.form_index), .instruction_pc = pc, .size = row.size, .flags = row.flags };
        }

        /// Strict phase-1 decode: temp-range ids are ALWAYS the temp
        /// interpretation (no mixing), and an atom-carrying instruction is
        /// only valid if its operand matches the ledger cursor -- the check
        /// both validates the stream and authorizes the caller to consume
        /// the ledger entry without re-reading the operand.
        pub inline fn headerAtPhase1(
            code: []const u8,
            atoms_ledger: []const u32,
            pc: u32,
            atom_index: u32,
        ) Error!Header {
            if (pc >= code.len) return error.BytecodeOverflow;
            const row = phase1_row[code[pc]];
            if (row.size == 0 or row.size > code.len - pc)
                return error.InvalidOpcode;
            if (row.flags & FormRow.atom_bit != 0) {
                if (row.size < 5 or atom_index >= atoms_ledger.len)
                    return error.InvalidOpcode;
                const operand = std.mem.readInt(u32, code[pc + 1 ..][0..4], .little);
                if (operand != atoms_ledger[atom_index]) return error.InvalidOpcode;
            }
            return .{ .form = @enumFromInt(row.form_index), .instruction_pc = pc, .size = row.size, .flags = row.flags };
        }

        /// Contract 3, stage A for the slot/argc families: which SHORTER
        /// form encodes `wide` with operand value `idx`, or null to stay
        /// wide. Derived at comptime from the declaration's two axes -- the
        /// semantic family (get_loc0/get_loc8/get_loc are one family) and
        /// the burned-in operand values (legacy_embedded) -- so the
        /// shortening table cannot drift from the forms it selects among.
        /// The hand-written `shortSlotOp` arithmetic this replaces adds idx
        /// to a base id; that is exactly the id-derived semantics P0-2
        /// exists to remove from the compiler.
        pub const ShortSelection = struct {
            /// burned[i] is the form whose sole operand is burned in as i.
            burned: [4]?logical.LogicalOpcode,
            /// The u8-payload variant, if the family has one.
            byte: ?logical.LogicalOpcode,
        };

        pub fn shortSelectionOf(comptime wide: logical.LogicalOpcode) ShortSelection {
            comptime {
                @setEvalBranchQuota(200000);
                var sel = ShortSelection{ .burned = .{ null, null, null, null }, .byte = null };
                const fam = logical.familyOf(wide);
                for (@typeInfo(logical.LogicalOpcode).@"enum".fields) |f| {
                    const form: logical.LogicalOpcode = @enumFromInt(f.value);
                    if (form == wide or logical.familyOf(form) != fam) continue;
                    if (f.value >= 300) continue; // final forms only
                    const lay = layout_table[f.value] orelse continue;
                    if (lay.len != 1) continue;
                    const slot = lay.slots[0];
                    if (slot.offset == null) {
                        // burned variant
                        if (slot.fixed >= 0 and slot.fixed < 4)
                            sel.burned[@intCast(slot.fixed)] = form;
                    } else if (slot.width == .u8) {
                        if (sel.byte != null)
                            @compileError("two byte-wide variants in family " ++ @tagName(fam));
                        sel.byte = form;
                    }
                }
                return sel;
            }
        }

        /// Stage-A selection for small integer pushes: the form whose
        /// burned-in immediate IS the value, derived from the push_int
        /// family's declarations. Replaces the writer's `push_0 + value`
        /// id arithmetic -- the same P0-2 id-derived semantics the slot
        /// shortener carried.
        pub const push_int_selection: [9]?logical.LogicalOpcode = blk: {
            @setEvalBranchQuota(200000);
            var t = [_]?logical.LogicalOpcode{null} ** 9;
            for (@typeInfo(logical.LogicalOpcode).@"enum".fields) |f| {
                if (f.value >= 300) continue;
                const form: logical.LogicalOpcode = @enumFromInt(f.value);
                if (logical.familyOf(form) != .push_int) continue;
                const lay = layout_table[f.value] orelse continue;
                if (lay.len != 1 or lay.slots[0].offset != null) continue;
                const v = lay.slots[0].fixed;
                if (v >= -1 and v <= 7) t[@intCast(v + 1)] = form;
            }
            break :blk t;
        };

        pub inline fn selectPushIntForm(value: i32) ?logical.LogicalOpcode {
            if (value < -1 or value > 7) return null;
            return push_int_selection[@intCast(value + 1)];
        }

        /// The same selection, table-driven for callers whose wide form is
        /// a runtime value (the writer helpers take the op to emit as a
        /// parameter). One row per form, built from `shortSelectionOf`.
        pub const short_selection_table: [layout_table_len]ShortSelection = blk: {
            @setEvalBranchQuota(400000);
            var t = [_]ShortSelection{.{ .burned = .{ null, null, null, null }, .byte = null }} ** layout_table_len;
            for (@typeInfo(logical.LogicalOpcode).@"enum".fields) |f| {
                const form: logical.LogicalOpcode = @enumFromInt(f.value);
                t[f.value] = shortSelectionOf(form);
            }
            break :blk t;
        };

        /// Stage-A selection as one call: the burned variant if the value
        /// fits, else the byte variant, else null (stay wide). `size` of
        /// the selected form comes from `form_row`, which is what makes the
        /// capacity precomputation and the writer consume the same plan
        /// (contract 3: encodedSize and emitInstruction may not each keep
        /// their own conditional ladder).
        pub inline fn selectSlotShortForm(
            wide: logical.LogicalOpcode,
            idx: u16,
        ) ?logical.LogicalOpcode {
            const sel = short_selection_table[@intFromEnum(wide)];
            if (idx < 4) {
                if (sel.burned[@intCast(idx)]) |short_form| return short_form;
            }
            if (idx < 256) {
                if (sel.byte) |byte_form| return byte_form;
            }
            return null;
        }

        /// The instruction's total size for a statically-known form.
        /// Runtime matchers use it for their `next_pc` arithmetic so the
        /// increment cannot drift from the declaration.
        pub inline fn sizeOfForm(comptime form: logical.LogicalOpcode) u8 {
            const size = comptime form_row[@intFromEnum(form)].size;
            comptime if (size == 0) @compileError("no size for " ++ @tagName(form));
            return size;
        }

        /// The declared value of a burned-in operand (`get_loc0`'s slot is
        /// 0, `push_2` is 2). Runtime matchers previously hard-coded these;
        /// the numbers were correct, but nothing connected them to the
        /// declaration that defines them.
        pub inline fn burnedOperandOf(
            comptime form: logical.LogicalOpcode,
            comptime index: usize,
        ) comptime_int {
            comptime {
                const lay = layout_table[@intFromEnum(form)] orelse
                    @compileError("no layout for " ++ @tagName(form));
                if (index >= lay.len)
                    @compileError("operand index out of range for " ++ @tagName(form));
                const slot = lay.slots[index];
                if (slot.offset != null)
                    @compileError("operand of " ++ @tagName(form) ++ " is in the payload, not burned in");
                return slot.fixed;
            }
        }

        /// Byte offset of operand `index` within the instruction (i.e.
        /// relative to the opcode byte), resolved at comptime for call
        /// sites that just matched the form and therefore know it
        /// statically. `T` is checked against the declared width, so a
        /// caller cannot silently read four bytes out of a two-byte slot.
        ///
        /// This is how a reader pass satisfies contract 2's "offsets come
        /// from the declaration" without paying for it: the generated code
        /// is identical to the hand-written `position + 1` / `position + 5`
        /// it replaces -- the magic number is simply derived instead of
        /// asserted-by-comment.
        pub inline fn operandOffsetOf(
            comptime form: logical.LogicalOpcode,
            comptime index: usize,
            comptime T: type,
        ) u8 {
            comptime {
                const lay = layout_table[@intFromEnum(form)] orelse
                    @compileError("no layout for " ++ @tagName(form));
                if (index >= lay.len)
                    @compileError("operand index out of range for " ++ @tagName(form));
                const slot = lay.slots[index];
                const offset = slot.offset orelse
                    @compileError("operand of " ++ @tagName(form) ++ " is burned into the id, not in the payload");
                const width: usize = switch (slot.width orelse
                    @compileError("operand of " ++ @tagName(form) ++ " has no payload width")) {
                    .u8, .i8 => 1,
                    .u16, .i16 => 2,
                    .u32, .i32 => 4,
                };
                if (width != @sizeOf(T))
                    @compileError("width mismatch reading operand of " ++ @tagName(form));
                return 1 + offset;
            }
        }

        pub fn layoutOf(form: logical.LogicalOpcode) *const OperandLayout {
            return &(layout_table[@intFromEnum(form)].?);
        }

        /// Eight bytes, and that is the whole design constraint.
        ///
        /// Contract 2 lists domain, encoding, canonical, payload_pc, next_pc
        /// and layout as header fields. They are a comptime parameter and
        /// accessors instead, because a struct that size stays live across a
        /// decode loop body and the compiler spills it: `perf annotate` on
        /// the migrated stack pass showed `str x9, [sp, #32]` and
        /// `ldr x2, [sp, #40]` among its hottest instructions, where the
        /// unmigrated pass had none -- it kept one byte and one pointer live.
        /// Everything dropped here is derivable in a single arithmetic op,
        /// so nothing is lost but the spill.
        pub const Header = struct {
            form: logical.LogicalOpcode,
            instruction_pc: u32,
            size: u8,
            /// The row's flag byte, carried because it fills the byte the
            /// struct was already padding to eight: `headerAt` has the row
            /// in hand, so this costs neither a field's worth of size nor a
            /// second table load at the consumer.
            flags: u8,

            pub inline fn hasAtom(self: Header) bool {
                return self.flags & FormRow.atom_bit != 0;
            }
            pub inline fn hasLabel(self: Header) bool {
                return self.flags & FormRow.label_bit != 0;
            }
            /// True for compiler-only (phase-1 / temp) forms. The form
            /// value ranges are the declaration's plane encoding: final
            /// forms sit at their physical id, lowered-only forms at 300+.
            pub inline fn isLowered(self: Header) bool {
                return @intFromEnum(self.form) >= 300;
            }
            /// 0, 1 or 2 -- see `FormRow.index_width_shift`.
            pub inline fn indexWidth(self: Header) u8 {
                return (self.flags >> FormRow.index_width_shift) & 3;
            }

            pub inline fn payload_pc(self: Header) u32 {
                return self.instruction_pc + 1;
            }

            pub inline fn next_pc(self: Header) u32 {
                return self.instruction_pc + self.size;
            }

            /// Aliases are never emitted, so today this is always true; it
            /// becomes real when F0c introduces them.
            pub inline fn canonical(self: Header) bool {
                _ = self;
                return true;
            }

            /// Contract 2 lists `family` and `layout` as header fields. They
            /// are accessors instead, because building them eagerly is what
            /// a decode costs: `familyOf` is a 263-arm switch and the layout
            /// is a ~50-byte struct, and the compile path now decodes every
            /// instruction about three times (stack pass, artifact
            /// validator, inline scanner). Measured, not assumed.
            pub inline fn family(self: Header) logical.SemanticFamily {
                return logical.familyOf(self.form);
            }

            pub inline fn layout(self: Header) *const OperandLayout {
                return layoutOf(self.form);
            }
        };

        pub const Error = error{ InvalidOpcode, BytecodeOverflow };

        // A reclaimed slot keeps a row -- the canonical dead shape, which
        // the ledger asserts -- so "the row table has an entry" does NOT
        // mean "the slot is claimed"; it only means `id < op_count`. Ten
        // slots are reclaimed today, and `headerAt`'s `stateOf` call is the
        // only thing that rejects them. Recorded because the reverse was
        // assumed once, and the assertion that tested the assumption is
        // what disproved it.
        comptime {
            @setEvalBranchQuota(20000);
            var reclaimed_with_row: usize = 0;
            for (0..op.op_count) |i| {
                const id: u8 = @intCast(i);
                if (finalCompactInfo(id) != null and physical.stateOf(id) != .claimed)
                    reclaimed_with_row += 1;
            }
            if (reclaimed_with_row != physical.ledger.reclaimed)
                @compileError("a reclaimed slot lost its canonical dead row");
        }

        pub fn headerAt(comptime domain: Domain, code: []const u8, pc: u32) Error!Header {
            if (pc >= code.len) return error.BytecodeOverflow;
            const id = code[pc];
            if (id >= op.op_count) return error.InvalidOpcode;
            // The index is computed as a number and the row is consulted
            // BEFORE `@enumFromInt`. A reclaimed id has no tag in
            // `LogicalOpcode`, so converting first and validating after
            // would be illegal behaviour on exactly the inputs invariant 5
            // exists to reject -- which is how the unit suite caught it.
            //
            // Carrier members are F0c: the sub space has no layout yet, so a
            // carrier decodes as itself and the tag is read as its operand.
            const index: u16 = switch (domain) {
                .final => id,
                .lowered => if (id >= op.op_temp_start and id < op.op_temp_end)
                    @as(u16, 300) + (id - op.op_temp_start)
                else
                    id,
            };
            // One row, one load: size and the claimed test come off the same
            // four bytes. See `FormRow` for why that is the whole point.
            const row = form_row[index];
            if (!row.isClaimed()) return error.InvalidOpcode;
            const form: logical.LogicalOpcode = @enumFromInt(index);
            const next = @as(usize, pc) + row.size;
            if (next > code.len) return error.BytecodeOverflow;
            return .{ .form = form, .instruction_pc = pc, .size = row.size, .flags = row.flags };
        }

        /// Burned-in operands are restored to their declared value, so a
        /// consumer never has to know which forms carry payload bytes.
        pub fn operandAt(h: Header, code: []const u8, index: usize, comptime T: type) Error!T {
            if (index >= h.layout().len) return error.InvalidOpcode;
            const slot = h.layout().slots[index];
            const offset = slot.offset orelse return @intCast(slot.fixed);
            const at = h.payload_pc() + offset;
            return switch (slot.width.?) {
                .u8 => @intCast(code[at]),
                .i8 => @intCast(@as(i8, @bitCast(code[at]))),
                .u16 => @intCast(std.mem.readInt(u16, code[at..][0..2], .little)),
                .i16 => @intCast(std.mem.readInt(i16, code[at..][0..2], .little)),
                .u32 => @intCast(std.mem.readInt(u32, code[at..][0..4], .little)),
                .i32 => @intCast(std.mem.readInt(i32, code[at..][0..4], .little)),
            };
        }

        pub const StackEffect = struct { pop: u32, push: u32 };

        /// The fall-through stack effect, resolved through the declaration.
        /// Dynamic forms evaluate their declared expression; everything else
        /// mirrors the physical row, which is the sanctioned migration path
        /// (invariant 5: at G0 the mirror goes away and a form without a
        /// declared effect stops compiling).
        /// Comptime index, not a scan. The declaration is a list because
        /// that is how it reads; consulting it per instruction is not.
        const dynamic_by_form: [512]?logical.DynamicStack.Shape = blk: {
            @setEvalBranchQuota(20000);
            var t = [_]?logical.DynamicStack.Shape{null} ** 512;
            for (logical.dynamic_stack) |d| t[@intFromEnum(d.form)] = d.shape;
            break :blk t;
        };

        /// No domain parameter: the form already carries it, because the
        /// lowered-only opcodes live at 300+ and the row table is keyed by
        /// form. That the parameter became dead is a small confirmation
        /// that form, not the physical id, is the right key.
        pub fn stackEffect(h: Header, code: []const u8) Error!StackEffect {
            const row = form_row[@intFromEnum(h.form)];
            if (!row.isDynamic()) return .{ .pop = row.pop, .push = row.push };
            if (dynamic_by_form[@intFromEnum(h.form)]) |shape| {
                switch (shape) {
                    .affine => |expr| switch (expr) {
                        .affine => |a| {
                            const v = try operandAt(h, code, a.operand_index, i64);
                            return .{
                                .pop = @intCast(@as(i64, a.pop_base) + @as(i64, a.pop_scale) * v),
                                .push = @intCast(@as(i64, a.push_base) + @as(i64, a.push_scale) * v),
                            };
                        },
                        .fixed => |f| return .{ .pop = f.pop, .push = f.push },
                        .operand_table => return error.InvalidOpcode,
                    },
                    .operand_table_from_legacy => |t| {
                        const raw = try operandAt(h, code, t.operand_index, u8);
                        return switch (h.form) {
                            .using => .{ .pop = using_sub.stackPop(raw), .push = using_sub.stackPush(raw) },
                            .dyn_env_probe => blk2: {
                                const flags = dyn_env.decode(raw) orelse return error.InvalidOpcode;
                                break :blk2 .{ .pop = flags.stackPop(), .push = flags.stackPush() };
                            },
                            else => error.InvalidOpcode,
                        };
                    },
                }
            }
            return .{ .pop = row.pop, .push = row.push };
        }

        /// A jump target is a decoded value, not an offset the consumer
        /// recomputes. The base is the label operand's own address, which is
        /// exactly the arithmetic every hand-rolled site had to repeat.
        pub fn targetOfLabel(h: Header, code: []const u8, index: usize) Error!u32 {
            if (index >= h.layout().len) return error.InvalidOpcode;
            const slot = h.layout().slots[index];
            if (slot.kind != .label) return error.InvalidOpcode;
            const offset = slot.offset orelse return error.InvalidOpcode;
            const diff = try operandAt(h, code, index, i64);
            const base: i64 = @as(i64, h.payload_pc()) + offset;
            const target = base + diff;
            if (target < 0 or target > code.len) return error.BytecodeOverflow;
            return @intCast(target);
        }

        /// One byte compare for a direct form -- the hot matcher must not
        /// pay for the structured path (P1-1).
        pub inline fn matchesFormAt(code: []const u8, pc: u32, form: logical.LogicalOpcode) bool {
            const raw = @intFromEnum(form);
            if (raw >= 300) return false;
            return pc < code.len and code[pc] == @as(u8, @intCast(raw));
        }
    };

    test "a demoted opcode keeps its scanner policy (5.2 clause 3)" {
        // The defect this replaces: `put_super_value` was demoted behind the
        // `using` carrier, and the scanner matched on opcode identity, so a
        // body containing `super.x = v` silently became inlinable. No test
        // went red then, because the only observable difference is which
        // bodies get optimised. Policy now travels with the form, so the
        // carrier is asked about its resident.
        const resident = logical.subForm(using_sub.put_super_value).?;
        try std.testing.expectEqual(logical.LogicalOpcode.using_put_super_value, resident);
        try std.testing.expectEqual(
            logical.InlinePolicy.forbidden,
            logical.traitsOf(resident).inline_policy,
        );

        // Every resident is reachable from its tag, and a tag no resident
        // claims decodes to null rather than to something plausible.
        inline for (@typeInfo(logical.LogicalOpcode).@"enum".fields) |f| {
            if (f.value >= 400) {
                const tag: u8 = @intCast(f.value - 400);
                try std.testing.expectEqual(
                    @as(?logical.LogicalOpcode, @enumFromInt(f.value)),
                    logical.subForm(tag),
                );
            }
        }
        try std.testing.expectEqual(@as(?logical.LogicalOpcode, null), logical.subForm(200));
    }

    test "decode layer round-trips every direct form against the raw reads" {
        // The decoder must agree with the hand-written reads it replaces, on
        // every form, or migrating a consumer is a coin flip. Build a
        // one-instruction stream per form and compare.
        @setEvalBranchQuota(200000);
        var buf: [16]u8 = undefined;
        inline for (@typeInfo(logical.LogicalOpcode).@"enum".fields) |f| {
            if (f.value < 300) {
                const id: u8 = @intCast(f.value);
                const info = finalInfo(id).?;
                @memset(&buf, 0);
                buf[0] = id;
                // Distinguishable payload so an off-by-one offset shows up.
                for (1..info.size) |i| buf[i] = @intCast(0x10 + i);
                const h = try opcode.decode.headerAt(.final, buf[0..info.size], 0);
                try std.testing.expectEqual(@as(u32, info.size), h.next_pc());
                try std.testing.expectEqual(@as(u32, 1), h.payload_pc());
                try std.testing.expect(h.canonical());
                try std.testing.expectEqual(f.value, @intFromEnum(h.form));

                // Every payload operand must read back exactly what a raw
                // read at the same offset would give.
                for (0..h.layout().len) |i| {
                    const slot = h.layout().slots[i];
                    const offset = slot.offset orelse continue;
                    const at = 1 + @as(usize, offset);
                    const expected: i64 = switch (slot.width.?) {
                        .u8 => buf[at],
                        .i8 => @as(i8, @bitCast(buf[at])),
                        .u16 => std.mem.readInt(u16, buf[at..][0..2], .little),
                        .i16 => std.mem.readInt(i16, buf[at..][0..2], .little),
                        .u32 => std.mem.readInt(u32, buf[at..][0..4], .little),
                        .i32 => std.mem.readInt(i32, buf[at..][0..4], .little),
                    };
                    try std.testing.expectEqual(expected, try opcode.decode.operandAt(h, buf[0..info.size], i, i64));
                }
            }
        }
    }

    test "decode layer restores burned-in operands and rejects bad input" {
        var buf = [_]u8{0} ** 4;

        // A burned-in operand has no payload byte; the decoder must hand back
        // the declared value so consumers need not know which forms are
        // which. get_loc2's slot is 2, push_3's immediate is 3.
        buf[0] = op.get_loc2;
        var h = try opcode.decode.headerAt(.final, buf[0..1], 0);
        try std.testing.expectEqual(@as(u16, 2), try opcode.decode.operandAt(h, buf[0..1], 0, u16));
        try std.testing.expectEqual(logical.OperandKind.local_slot, h.layout().slots[0].kind);
        try std.testing.expectEqual(logical.Flow.read_write, h.layout().slots[0].flow.?);

        buf[0] = op.push_3;
        h = try opcode.decode.headerAt(.final, buf[0..1], 0);
        try std.testing.expectEqual(@as(i32, 3), try opcode.decode.operandAt(h, buf[0..1], 0, i32));

        // A reclaimed id is not decodable, and a truncated instruction is an
        // overflow rather than a silent short read.
        buf[0] = 114; // reclaimed by the with_* merge
        try std.testing.expectError(error.InvalidOpcode, opcode.decode.headerAt(.final, buf[0..1], 0));
        buf[0] = op.push_i32; // size 5
        try std.testing.expectError(error.BytecodeOverflow, opcode.decode.headerAt(.final, buf[0..3], 0));

        // The hot matcher stays a byte compare and never claims a
        // compiler-only form.
        buf[0] = op.get_loc2;
        try std.testing.expect(decode.matchesFormAt(buf[0..1], 0, .get_loc2));
        try std.testing.expect(!decode.matchesFormAt(buf[0..1], 0, .get_loc3));
        try std.testing.expect(!decode.matchesFormAt(buf[0..1], 0, .enter_scope));
    }

    test "logical forms and physical rows are one instruction set" {
        // 263 forms: 244 final (one per claimed id) plus 19 compiler-only.
        const counts = comptime blk: {
            var final_count: usize = 0;
            var temp_count: usize = 0;
            var sub_count: usize = 0;
            for (@typeInfo(logical.LogicalOpcode).@"enum".fields) |f| {
                if (f.value >= 400) sub_count += 1 else if (f.value >= 300) temp_count += 1 else final_count += 1;
            }
            break :blk .{ .final = final_count, .temp = temp_count, .sub = sub_count };
        };
        try std.testing.expectEqual(@as(usize, 244), counts.final);
        try std.testing.expectEqual(@as(usize, 19), counts.temp);
        // The `using` carrier's residents: three of its own operations plus
        // the sixteen opcodes demoted into it. Declaring them is what keeps
        // the demoted set inside the single source rather than outside it.
        try std.testing.expectEqual(@as(usize, 19), counts.sub);
        try std.testing.expectEqual(logical.SemanticFamily.using_sub, logical.familyOf(.using_set_proto));
        try std.testing.expect(logical.planeOf(.using_set_proto) == .sub);
        try std.testing.expect(logical.planeOf(.get_loc0) == .main);
        try std.testing.expectEqual(@as(u16, 244), physical.ledger.claimed);

        // Family is a rollup, never an identity: the width variants of one
        // family must share it while remaining distinct forms.
        try std.testing.expectEqual(logical.SemanticFamily.get_loc, logical.familyOf(.get_loc0));
        try std.testing.expectEqual(logical.SemanticFamily.get_loc, logical.familyOf(.get_loc8));
        try std.testing.expectEqual(logical.SemanticFamily.get_loc, logical.familyOf(.get_loc));
        try std.testing.expect(logical.LogicalOpcode.get_loc0 != logical.LogicalOpcode.get_loc8);

        // The rollup must not collapse the frequency asymmetry that makes it
        // unusable as an identity key (push_const 25,524 vs push_const8
        // 9,550,185 in the census).
        try std.testing.expectEqual(logical.familyOf(.push_const), logical.familyOf(.push_const8));
        try std.testing.expect(logical.LogicalOpcode.push_const != logical.LogicalOpcode.push_const8);
    }

    test "physical ledger is derived, not asserted by hand" {
        // The three facts the roadmap and the design documents quote. They are
        // pinned here so a reclaim lands as one declaration edit and the
        // budget follows, instead of being restated in prose.
        try std.testing.expectEqual(@as(u16, 244), physical.ledger.claimed);
        try std.testing.expectEqual(@as(u16, 10), physical.ledger.reclaimed);
        try std.testing.expectEqual(@as(u16, 2), physical.ledger.no_row);
        try std.testing.expectEqual(@as(u16, 12), physical.ledger.free());
        try std.testing.expectEqual(@as(u16, 256), physical.ledger.total());

        // Spot-check the classification against ids verified by hand.
        try std.testing.expectEqual(physical.SlotState.claimed, physical.stateOf(op.dyn_env_probe));
        try std.testing.expectEqual(physical.SlotState.reclaimed, physical.stateOf(114));
        try std.testing.expectEqual(physical.SlotState.no_row, physical.stateOf(255));
    }

    test "dyn_env_probe flags round-trip and reject undefined encodings" {
        for ([_]dyn_env.ProbeKind{ .read, .delete, .put, .get_ref, .make_ref }) |kind| {
            for ([_]bool{ false, true }) |is_with| {
                const flags = dyn_env.Flags{ .kind = kind, .is_with = is_with };
                const decoded = dyn_env.decode(flags.encode()) orelse
                    return error.TestExpectedEqual;
                try std.testing.expectEqual(kind, decoded.kind);
                try std.testing.expectEqual(is_with, decoded.is_with);
            }
        }
        // The kind field has three unassigned values and the top three bits
        // are reserved; both must fail closed rather than alias a real kind.
        try std.testing.expectEqual(@as(?dyn_env.Flags, null), dyn_env.decode(5));
        try std.testing.expectEqual(@as(?dyn_env.Flags, null), dyn_env.decode(7));
        try std.testing.expectEqual(@as(?dyn_env.Flags, null), dyn_env.decode(0b0010_0000));

        // The row carries the four non-put kinds; the put form's effect comes
        // from the flags byte, so the two must not drift apart.
        const row_pop = nPopOf(op.dyn_env_probe);
        const row_push = nPushOf(op.dyn_env_probe);
        for ([_]dyn_env.ProbeKind{ .read, .delete, .get_ref, .make_ref }) |kind| {
            const flags = dyn_env.Flags{ .kind = kind, .is_with = false };
            try std.testing.expectEqual(row_pop, flags.stackPop());
            try std.testing.expectEqual(row_push, flags.stackPush());
        }
        const put = dyn_env.Flags{ .kind = .put, .is_with = false };
        try std.testing.expectEqual(@as(u8, 2), put.stackPop());
        try std.testing.expectEqual(@as(u8, 1), put.stackPush());

        // The taken edge lands one deeper for a value-producing probe, two for
        // a reference-producing one, and one shallower for a store.
        try std.testing.expectEqual(@as(i8, 1), (dyn_env.Flags{ .kind = .read, .is_with = true }).branchStackDelta());
        try std.testing.expectEqual(@as(i8, 1), (dyn_env.Flags{ .kind = .delete, .is_with = true }).branchStackDelta());
        try std.testing.expectEqual(@as(i8, 2), (dyn_env.Flags{ .kind = .get_ref, .is_with = true }).branchStackDelta());
        try std.testing.expectEqual(@as(i8, 2), (dyn_env.Flags{ .kind = .make_ref, .is_with = true }).branchStackDelta());
        try std.testing.expectEqual(@as(i8, -1), put.branchStackDelta());
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
        try std.testing.expectEqual(@as(u8, 10), sizeOfPhase1(op.dyn_env_probe));
        try std.testing.expectEqual(sizeOf(op.get_length), sizeOfPhase1(op.get_length));
        try std.testing.expectEqual(sizeOf(op.if_false8), sizeOfPhase1(op.if_false8));
        try std.testing.expectEqual(sizeOf(op.get_field_field2), sizeOfPhase1(op.get_field_field2));
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
        /// Final index into the module root FunctionBytecode closure table.
        var_idx: u16,
        is_namespace: bool,
    };

    pub const Export = struct {
        export_name: atom.Atom,
        local_name: atom.Atom,
        /// Filled by the module root finalizer after addGlobalVariables has
        /// established the complete closure topology.
        var_idx: u16 = 0,
    };

    pub const IndirectExport = struct {
        request_index: u32,
        export_name: atom.Atom,
        import_name: atom.Atom,
        is_namespace: bool,
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

        pub fn addImport(
            self: *Record,
            request_index: u32,
            import_name: atom.Atom,
            local_name: atom.Atom,
            var_idx: u16,
            is_namespace: bool,
        ) !void {
            const owned_import_name = self.atoms.dup(import_name);
            errdefer self.atoms.free(owned_import_name);
            const owned_local_name = self.atoms.dup(local_name);
            errdefer self.atoms.free(owned_local_name);
            try append(self.memory, Import, &self.imports, .{
                .request_index = request_index,
                .import_name = owned_import_name,
                .local_name = owned_local_name,
                .var_idx = var_idx,
                .is_namespace = is_namespace,
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

        pub fn addIndirectExport(
            self: *Record,
            request_index: u32,
            export_name: atom.Atom,
            import_name: atom.Atom,
            is_namespace: bool,
        ) !void {
            const owned_export_name = self.atoms.dup(export_name);
            errdefer self.atoms.free(owned_export_name);
            const owned_import_name = self.atoms.dup(import_name);
            errdefer self.atoms.free(owned_import_name);
            try append(self.memory, IndirectExport, &self.indirect_exports, .{
                .request_index = request_index,
                .export_name = owned_export_name,
                .import_name = owned_import_name,
                .is_namespace = is_namespace,
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

/// Grammar facts fixed when bytecode is entered and inherited by a direct
/// eval. Variable-environment, `arguments`, and `this` binding identity is
/// deliberately absent: canonical roots are real function objects, and final
/// vardef/closure topology is the sole authority for those bindings.
///
/// The four `*_allowed` bits mirror JSFunctionBytecode exactly.
pub const EntryContract = packed struct(u8) {
    new_target_allowed: bool = false,
    super_call_allowed: bool = false,
    super_allowed: bool = false,
    arguments_allowed: bool = false,
    _reserved: u4 = 0,

    comptime {
        if (@sizeOf(@This()) != 1) @compileError("EntryContract must remain one byte");
    }
};

/// Immutable semantic policy shared by one root compilation and every child
/// FunctionDef finalized beneath it.
pub const CompilePolicy = struct {
    runtime_strict: bool = false,
};

/// Optional compile-phase diagnostics. This state is owned by the caller and
/// remains on its stack; neither parser nor published bytecode retains it.
pub const CompileTiming = struct {
    frontend_ns: u64 = 0,
    finalize_ns: u64 = 0,
};

/// Production compilation authority. The borrowed realm is retained once by
/// every FunctionBytecode at publication, matching QuickJS's
/// `b->realm = JS_DupContext(ctx)` for both roots and recursively-finalized
/// children. The context itself is non-owning; published artifacts own their
/// independent `RealmRef`s.
pub const CompileContext = struct {
    realm: *core_context.RealmContext,
    policy: CompilePolicy = .{},
    timing: ?*CompileTiming = null,

    pub inline fn artifactAllocator(self: CompileContext) @import("std").mem.Allocator {
        return self.realm.runtime.memory.persistent_allocator;
    }
};

pub const function_bytecode = struct {
    const std = @import("std");
    const builtin = @import("builtin");
    const build_options = @import("build_options");

    const atom = @import("core/atom.zig");
    const bulk_memory = @import("core/bulk_memory.zig");
    const context = @import("core/context.zig");
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
        normal = 0,
        function_decl = 1, // lexical var with function declaration
        new_function_decl = 2, // lexical var with async/generator function declaration
        catch_ = 3,
        function_name = 4, // function expression name
        private_field = 5,
        private_method = 6,
        private_getter = 7,
        private_setter = 8,
        private_getter_setter = 9,
        /// QuickJS JS_VAR_GLOBAL_FUNCTION_DECL: validation/property surgery
        /// class for a non-lexical GLOBAL_DECL carrier. Distinct from a local
        /// lexical function declaration; initialization still lives in the
        /// fclosure/put_var_ref prefix.
        global_function_decl = 10,
    };

    /// Sentinel used when a local/argument binding has no frame-open cell.
    /// Valid binding indices are dense in `[0, open_var_ref_count)`.
    pub const no_open_binding: u16 = std.math.maxInt(u16);

    /// QuickJS's special end marker for a lexical chain that terminates in the
    /// separate parameter environment (`ARG_SCOPE_END`, quickjs.c:636).
    pub const arg_scope_end: i32 = -2;

    /// Mirrors `JSVarDef` (`quickjs.c:724`).
    pub const VarDef = struct {
        var_name: atom.Atom,
        scope_level: i32, // index into scopes of this variable lexical scope
        scope_next: i32 = -1, // index into vars of the next variable in the same or enclosing lexical scope
        /// Constant-pool entry for the function declaration hoisted into this
        /// binding.  As in QuickJS, duplicate body declarations overwrite this
        /// one slot, so the prologue emits only the last initializer.
        func_pool_idx: i32 = -1,
        is_lexical: bool = false,
        is_const: bool = false,
        is_captured: bool = false,
        /// Parser-only discriminator used while pairing private accessors.
        /// QuickJS drops this bit when JSVarDef becomes JSBytecodeVarDef.
        is_static_private: bool = false,
        tdz_emitted_at_decl: bool = false,
        var_kind: VarKind = .normal,
        /// Stable index into the owning frame's open-binding table. This is the
        /// zjs counterpart of qjs `JSVarDef.var_ref_idx`; locals and arguments
        /// remain plain JSValue slots regardless of capture state.
        open_binding_idx: u16 = no_open_binding,
    };

    /// Final runtime variable row, mirroring `JSBytecodeVarDef`
    /// (`quickjs.c:654-670`). Unlike the compile-time `VarDef`, this carries
    /// only data read after finalization. Arguments and locals occupy one
    /// contiguous table in `FunctionBytecode`, with arguments first.
    pub const BytecodeVarDef = extern struct {
        var_name: atom.Atom,
        scope_next: i32 = -1,
        flags: u8 = 0,
        reserved: u8 = 0,
        var_ref_idx: u16 = 0,

        const is_const_mask: u8 = 1 << 0;
        const is_lexical_mask: u8 = 1 << 1;
        const is_captured_mask: u8 = 1 << 2;
        const has_scope_mask: u8 = 1 << 3;
        const var_kind_shift = 4;
        const var_kind_mask: u8 = 0xf << var_kind_shift;

        pub const Init = struct {
            var_name: atom.Atom,
            scope_next: i32 = -1,
            is_const: bool = false,
            is_lexical: bool = false,
            is_captured: bool = false,
            has_scope: bool = false,
            var_kind: VarKind = .normal,
            var_ref_idx: u16 = 0,
        };

        pub fn init(value: Init) BytecodeVarDef {
            return .{
                .var_name = value.var_name,
                .scope_next = value.scope_next,
                .flags = (if (value.is_const) is_const_mask else 0) |
                    (if (value.is_lexical) is_lexical_mask else 0) |
                    (if (value.is_captured) is_captured_mask else 0) |
                    (if (value.has_scope) has_scope_mask else 0) |
                    (@as(u8, @intFromEnum(value.var_kind)) << var_kind_shift),
                .var_ref_idx = if (value.is_captured) value.var_ref_idx else 0,
            };
        }

        pub fn fromCompile(vd: VarDef, scope_next: i32) BytecodeVarDef {
            return init(.{
                .var_name = vd.var_name,
                .scope_next = scope_next,
                .is_const = vd.is_const,
                .is_lexical = vd.is_lexical,
                .is_captured = vd.is_captured,
                .has_scope = vd.scope_level != 0,
                .var_kind = vd.var_kind,
                // QuickJS leaves this zero for uncaptured rows and consults it
                // only when is_captured is set. Do not persist zjs's compile-
                // time no_open_binding sentinel into the runtime artifact.
                .var_ref_idx = if (vd.is_captured) vd.open_binding_idx else 0,
            });
        }

        pub inline fn isConst(self: BytecodeVarDef) bool {
            return self.flags & is_const_mask != 0;
        }

        pub inline fn isLexical(self: BytecodeVarDef) bool {
            return self.flags & is_lexical_mask != 0;
        }

        pub inline fn isCaptured(self: BytecodeVarDef) bool {
            return self.flags & is_captured_mask != 0;
        }

        pub inline fn hasScope(self: BytecodeVarDef) bool {
            return self.flags & has_scope_mask != 0;
        }

        pub inline fn varKind(self: BytecodeVarDef) VarKind {
            return @enumFromInt((self.flags & var_kind_mask) >> var_kind_shift);
        }
    };

    /// Shared compile/final closure row, byte-for-byte matching QuickJS's
    /// `JSClosureVar` on the supported little-endian targets. Explicit bytes
    /// make the bit contract independent of Zig packed-struct layout rules.
    pub const ClosureVar = extern struct {
        flags: u8,
        kind_flags: u8,
        var_idx: u16, // index to a normal variable of the parent function, or index to a closure variable
        var_name: atom.Atom,

        const closure_type_mask: u8 = 0x07;
        const is_lexical_mask: u8 = 1 << 3;
        const is_const_mask: u8 = 1 << 4;
        const var_kind_mask: u8 = 0x0f;

        pub const Init = struct {
            closure_type: ClosureType,
            is_lexical: bool = false,
            is_const: bool = false,
            var_kind: VarKind = .normal,
            var_idx: u16,
            var_name: atom.Atom,
        };

        pub fn init(value: Init) ClosureVar {
            return .{
                .flags = @as(u8, @intFromEnum(value.closure_type)) |
                    (if (value.is_lexical) is_lexical_mask else 0) |
                    (if (value.is_const) is_const_mask else 0),
                .kind_flags = @intFromEnum(value.var_kind),
                .var_idx = value.var_idx,
                .var_name = value.var_name,
            };
        }

        pub inline fn closureType(self: ClosureVar) ClosureType {
            return @enumFromInt(self.flags & closure_type_mask);
        }

        pub inline fn isLexical(self: ClosureVar) bool {
            return self.flags & is_lexical_mask != 0;
        }

        pub inline fn isConst(self: ClosureVar) bool {
            return self.flags & is_const_mask != 0;
        }

        pub inline fn varKind(self: ClosureVar) VarKind {
            return @enumFromInt(self.kind_flags & var_kind_mask);
        }

        pub fn toInit(self: ClosureVar) Init {
            return .{
                .closure_type = self.closureType(),
                .is_lexical = self.isLexical(),
                .is_const = self.isConst(),
                .var_kind = self.varKind(),
                .var_idx = self.var_idx,
                .var_name = self.var_name,
            };
        }
    };

    /// Finalization transfers the same physical row instead of translating to
    /// a second, layout-divergent Zig struct.
    pub const BytecodeClosureVar = ClosureVar;

    /// Compile-time result of resolving an eval declaration's variable
    /// environment. The index variants address the finalized closure_var table.
    pub const EvalBindingTarget = union(enum(u8)) {
        unresolved,
        global,
        closure: u16,
        var_object: u16,
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
        eval_target: EvalBindingTarget = .unresolved,
    };

    /// Exact optional QuickJS debug tail (`JSFunctionBytecode.debug`). It is
    /// stored inline immediately after the 96-byte base when `has_debug` is
    /// set, never as a separately allocated box.
    pub const DebugInfo = extern struct {
        filename: atom.Atom,
        source_len: i32,
        pc2line_len: i32,
        _padding: u32,
        pc2line_buf: ?[*]u8,
        /// NUL-terminated allocation whose logical length is `source_len`.
        source_ptr: ?[*:0]const u8,

        comptime {
            std.debug.assert(@sizeOf(@This()) == 32);
            std.debug.assert(@alignOf(@This()) == 8);
            std.debug.assert(@offsetOf(@This(), "filename") == 0x00);
            std.debug.assert(@offsetOf(@This(), "source_len") == 0x04);
            std.debug.assert(@offsetOf(@This(), "pc2line_len") == 0x08);
            std.debug.assert(@offsetOf(@This(), "_padding") == 0x0c);
            std.debug.assert(@offsetOf(@This(), "pc2line_buf") == 0x10);
            std.debug.assert(@offsetOf(@This(), "source_ptr") == 0x18);
            std.debug.assert(@sizeOf(?[*]u8) == @sizeOf(usize));
            std.debug.assert(@sizeOf(?[*:0]const u8) == @sizeOf(usize));
        }
    };

    /// zjs execution classifications with no QuickJS header counterpart.
    /// They are published once by the finalizer and read directly from the FB;
    /// no attach/call path may scan bytecode or allocate a parallel record.
    pub const ExactArgsLeafKind = enum(u2) {
        none = 0,
        sloppy = 1,
        raw_this = 2,
    };

    pub const ExecutionFlags = packed struct(u16) {
        has_mapped_arguments: bool = false,
        simple_inline_eligible: bool = false,
        strict_simple_inline_eligible: bool = false,
        strict_simple_snapshot_inline_eligible: bool = false,
        simple_inline_empty_leaf: bool = false,
        raw_this_inline_empty_leaf: bool = false,
        simple_inline_exact_args_leaf: bool = false,
        raw_this_inline_exact_args_leaf: bool = false,
        exact_args_leaf_kind: ExactArgsLeafKind = .none,
        capture_leaf_kind: ExactArgsLeafKind = .none,
        /// The finalized root is an ECMAScript module body.
        is_module: bool = false,
        /// Publication-time image of the entry-opcode probe
        /// `byte_code[0] == OP_check_ctor` (base-class constructors): plain
        /// [[Call]] must take the authoritative slow path so rejection runs
        /// with full construct-context semantics. Published code is immutable,
        /// so hoisting the probe out of per-call resolution is exact. qjs
        /// needs no such bit — its OP_check_ctor throws inside the callee
        /// (quickjs.c:18253) — but zjs's inline frame constructors must reject
        /// before entering. Derived constructors keep the canonical qjs
        /// header bit; this covers only the base-class entry probe.
        entry_rejects_plain_call: bool = false,
        /// Geometry-only small-function body-expansion candidate. Not the
        /// existing same-machine `simple_inline_eligible` Entry path.
        small_inline_eligible: bool = false,
        /// This image contains a rewritten L1 apply-forward site
        /// (`op.call_method_apply_fwd`). Consulted by constructor TAKE and
        /// D8-L1 native_caller attach — not by vanilla `op_call_method`.
        apply_forward_inlined: bool = false,
    };

    /// Immutable execution policy published before a FunctionBytecode escapes.
    /// Hot call resolution takes one coherent 16-bit snapshot and threads it
    /// through the selected inline target.
    pub const CallFacts = packed struct(u16) {
        execution: ExecutionFlags = .{},

        comptime {
            std.debug.assert(@sizeOf(@This()) == 2);
            std.debug.assert(@bitOffsetOf(@This(), "execution") == 0);
        }
    };

    /// Widest named-property reserve the constructor allocation profile will
    /// learn. Larger instances still construct; they just stop growing the hint.
    pub const max_ctor_alloc_capacity: u16 = 32;

    pub const CtorAllocState = enum(u8) {
        empty = 0,
        live = 1,
        inert = 2,
    };

    /// Learned property-slot reserve for `new`. Zero-fill is `empty`.
    /// Lives in the FB hot tail (not Object/Shape) so qjs's 96-byte header
    /// offsets stay untouched. No heap pointers — GC mark is unchanged.
    pub const CtorAllocProfile = extern struct {
        capacity: u16 = 0,
        state: CtorAllocState = .empty,
        _pad: [5]u8 = @splat(0),

        comptime {
            std.debug.assert(@sizeOf(@This()) == 8);
        }
    };

    /// Hot zjs-only state placed immediately after the exact code bytes. Code
    /// has byte alignment, so canonical access must use `*align(1)`. The
    /// execution snapshot is two bytes; explicit padding preserves the
    /// four-byte ScriptOrModule offset.
    ///
    /// The total stays a multiple of eight: `LegacyExecutionAdapter` places its
    /// aligned back-pointer at `base + 96 + @sizeOf(@This())`.
    pub const FunctionBytecodeHotExtension = extern struct {
        call_facts: function_bytecode.CallFacts,
        /// Preserve ScriptOrModule's aligned offset without widening CallFacts
        /// back into a second semantic carrier.
        _call_facts_padding: u16 = 0,
        /// Stable ScriptOrModule identity used as the dynamic-import referrer.
        script_or_module: atom.Atom,
        ctor_alloc: CtorAllocProfile = .{},
        _ctor_alloc_pad: [48]u8 = @splat(0),

        comptime {
            std.debug.assert(@sizeOf(@This()) == 64);
            std.debug.assert(@sizeOf(@This()) % 8 == 0);
            std.debug.assert(@offsetOf(@This(), "call_facts") == 0x00);
            std.debug.assert(@offsetOf(@This(), "_call_facts_padding") == 0x02);
            std.debug.assert(@offsetOf(@This(), "script_or_module") == 0x04);
            std.debug.assert(@offsetOf(@This(), "ctor_alloc") == 0x08);
        }
    };

    /// The only negative byte-code length. It discriminates the non-escaping
    /// stack adapter whose extension is fixed at base+96 from every canonical
    /// packed FunctionBytecode, whose checked layout always has len >= 0.
    pub const legacy_byte_code_len_sentinel: i32 = -1;

    /// Mirrors `JSFunctionBytecode` (`quickjs.c:768-804`).
    ///
    /// This is the final compiled bytecode structure produced by the
    /// js_create_function equivalent. It contains the fully processed bytecode
    /// after all bytecode pipeline phases. Core owns this GC object so runtime,
    /// object graph cleanup, and tracing can operate without depending on the
    /// bytecode compile-time module.
    ///
    /// The fixed record is the exact 96-byte, align-8 QuickJS core header.
    /// Optional debug metadata and zjs-only state are addressed as inline FAM
    /// tails and therefore cannot perturb any core offset.
    pub const FunctionBytecodeImpl = extern struct {
        pub const gc_kind_tag: u8 = @intFromEnum(gc.GcKind.function_bytecode);

        /// Logical initialization carrier only. The physical representation is
        /// `js_mode` plus the two explicit integer bytes below; accessors apply
        /// masks so no Zig packed-bitfield layout is trusted.
        pub const Flags = struct {
            is_strict_mode: bool = false,
            runtime_strict_mode: bool = false,
            has_prototype: bool = false,
            has_simple_parameter_list: bool = true,
            is_derived_class_constructor: bool = false,
            need_home_object: bool = false,
            func_kind: FunctionKind = .normal,
            new_target_allowed: bool = false,
            super_call_allowed: bool = false,
            super_allowed: bool = false,
            arguments_allowed: bool = false,
            is_direct_or_indirect_eval: bool = false,
        };

        pub const js_mode_strict_mask: u8 = 1 << 0;
        pub const byte17_has_prototype_mask: u8 = 1 << 0;
        pub const byte17_simple_parameters_mask: u8 = 1 << 1;
        pub const byte17_derived_constructor_mask: u8 = 1 << 2;
        pub const byte17_need_home_object_mask: u8 = 1 << 3;
        pub const byte17_func_kind_shift: u3 = 4;
        pub const byte17_func_kind_mask: u8 = 0b11 << byte17_func_kind_shift;
        pub const byte17_new_target_mask: u8 = 1 << 6;
        pub const byte17_super_call_mask: u8 = 1 << 7;
        pub const byte18_super_mask: u8 = 1 << 0;
        pub const byte18_arguments_mask: u8 = 1 << 1;
        pub const byte18_has_debug_mask: u8 = 1 << 2;
        pub const byte18_rom_mask: u8 = 1 << 3;
        pub const byte18_eval_mask: u8 = 1 << 4;
        /// Named zjs extension bits in QuickJS's otherwise-unused high bits.
        pub const byte18_has_extension_mask: u8 = 1 << 5;
        pub const byte18_runtime_strict_mask: u8 = 1 << 6;

        // quickjs.c JSFunctionBytecode, exact offsets on the pinned 64-bit ABI.
        header: gc.GCObjectHeader, // 0x00
        js_mode: u8, // 0x10
        flag_byte17: u8, // 0x11
        flag_byte18: u8, // 0x12
        _flag_padding0: u8, // 0x13, js_mallocz zero hole
        /// Header-resident image of the hot-extension CallFacts word, living
        /// in QuickJS's 0x13..0x17 flag-padding hole so no core offset moves.
        /// The FAM tail behind the code bytes stays authoritative (it is what
        /// layout/serialization own); both copies are written together by the
        /// only two publication funnels (publishExecutionFlags /
        /// setExecutionFlags), so per-call resolution reads one fixed-offset
        /// halfword instead of a code-ptr + code-len dependent tail load that
        /// touches the far end of the bytecode array every call.
        call_facts_mirror: function_bytecode.CallFacts, // 0x14
        _flag_padding: [2]u8, // 0x16..0x17, js_mallocz zero holes
        byte_code: ?[*]u8, // 0x18
        byte_code_len: i32, // 0x20
        func_name: atom.Atom,
        vardefs: ?[*]BytecodeVarDef, // 0x28
        closure_var: ?[*]BytecodeClosureVar, // 0x30
        arg_count: u16, // 0x38
        var_count: u16,
        defined_arg_count: u16,
        stack_size: u16,
        var_ref_count: u16, // 0x40, open local/argument VarRefs
        _realm_padding: [6]u8,
        realm: context.RealmRef, // 0x48
        cpool: ?[*]JSValue, // 0x50
        cpool_count: i32,
        closure_var_count: i32,

        comptime {
            std.debug.assert(@sizeOf(@This()) == 96);
            std.debug.assert(@alignOf(@This()) == 8);
            std.debug.assert(@offsetOf(@This(), "header") == 0x00);
            std.debug.assert(@offsetOf(@This(), "js_mode") == 0x10);
            std.debug.assert(@offsetOf(@This(), "flag_byte17") == 0x11);
            std.debug.assert(@offsetOf(@This(), "flag_byte18") == 0x12);
            std.debug.assert(@offsetOf(@This(), "_flag_padding0") == 0x13);
            std.debug.assert(@offsetOf(@This(), "call_facts_mirror") == 0x14);
            std.debug.assert(@offsetOf(@This(), "_flag_padding") == 0x16);
            std.debug.assert(@offsetOf(@This(), "byte_code") == 0x18);
            std.debug.assert(@offsetOf(@This(), "byte_code_len") == 0x20);
            std.debug.assert(@offsetOf(@This(), "func_name") == 0x24);
            std.debug.assert(@offsetOf(@This(), "vardefs") == 0x28);
            std.debug.assert(@offsetOf(@This(), "closure_var") == 0x30);
            std.debug.assert(@offsetOf(@This(), "arg_count") == 0x38);
            std.debug.assert(@offsetOf(@This(), "var_count") == 0x3a);
            std.debug.assert(@offsetOf(@This(), "defined_arg_count") == 0x3c);
            std.debug.assert(@offsetOf(@This(), "stack_size") == 0x3e);
            std.debug.assert(@offsetOf(@This(), "var_ref_count") == 0x40);
            std.debug.assert(@offsetOf(@This(), "_realm_padding") == 0x42);
            std.debug.assert(@offsetOf(@This(), "realm") == 0x48);
            std.debug.assert(@offsetOf(@This(), "cpool") == 0x50);
            std.debug.assert(@offsetOf(@This(), "cpool_count") == 0x58);
            std.debug.assert(@offsetOf(@This(), "closure_var_count") == 0x5c);
            std.debug.assert(@sizeOf(?[*]BytecodeVarDef) == @sizeOf(usize));
            std.debug.assert(@sizeOf(?[*]BytecodeClosureVar) == @sizeOf(usize));
            std.debug.assert(@sizeOf(?[*]JSValue) == @sizeOf(usize));
            std.debug.assert(@sizeOf(context.RealmRef) == @sizeOf(usize));
            std.debug.assert(@alignOf(DebugInfo) <= @alignOf(@This()));
        }

        inline fn bit(byte: u8, mask: u8) bool {
            return byte & mask != 0;
        }

        inline fn assignBit(byte: *u8, mask: u8, enabled: bool) void {
            if (enabled) byte.* |= mask else byte.* &= ~mask;
        }

        pub inline fn hasDebug(self: *const FunctionBytecodeImpl) bool {
            return bit(self.flag_byte18, byte18_has_debug_mask);
        }

        pub inline fn hasExtension(self: *const FunctionBytecodeImpl) bool {
            return bit(self.flag_byte18, byte18_has_extension_mask);
        }

        pub fn layout(self: *const FunctionBytecodeImpl) function_bytecode.FunctionLayout {
            return function_bytecode.FunctionLayout.fromFunction(self) catch unreachable;
        }

        pub inline fn famBytes(self: *const FunctionBytecodeImpl) usize {
            return self.layout().famBytes();
        }

        pub inline fn debugInfo(self: *const FunctionBytecodeImpl) ?*const DebugInfo {
            if (!self.hasDebug()) return null;
            const bytes: [*]const u8 = @ptrCast(self);
            return @ptrCast(@alignCast(bytes + @sizeOf(FunctionBytecodeImpl)));
        }

        pub inline fn debugInfoMut(self: *FunctionBytecodeImpl) ?*DebugInfo {
            if (!self.hasDebug()) return null;
            const bytes: [*]u8 = @ptrCast(self);
            return @ptrCast(@alignCast(bytes + @sizeOf(FunctionBytecodeImpl)));
        }

        pub inline fn hotExtension(self: *const FunctionBytecodeImpl) ?*align(1) const FunctionBytecodeHotExtension {
            if (!bit(self.flag_byte18, byte18_has_extension_mask)) return null;
            // Canonical production bytecode is non-empty and self-owned. The
            // hot extension begins at exact code_end, so CallFacts needs no
            // table/count walk or alignment arithmetic.
            if (self.byte_code) |ptr| {
                return canonicalHotExtension(ptr, self.byte_code_len);
            }
            return self.hotExtensionSlow();
        }

        pub inline fn hotExtensionMut(self: *FunctionBytecodeImpl) ?*align(1) FunctionBytecodeHotExtension {
            if (!bit(self.flag_byte18, byte18_has_extension_mask)) return null;
            if (self.byte_code) |ptr| {
                return @constCast(canonicalHotExtension(ptr, self.byte_code_len));
            }
            return self.hotExtensionMutSlow();
        }

        inline fn canonicalHotAddress(code_ptr: [*]const u8, code_len: i32) usize {
            std.debug.assert(code_len > 0);
            @setRuntimeSafety(false);
            // FunctionLayout checked this addition before publishing the
            // canonical self-pointer and length.
            return @intFromPtr(code_ptr) +% @as(usize, @intCast(code_len));
        }

        inline fn canonicalHotExtension(
            code_ptr: [*]const u8,
            code_len: i32,
        ) *align(1) const FunctionBytecodeHotExtension {
            return @ptrFromInt(canonicalHotAddress(code_ptr, code_len));
        }

        noinline fn hotExtensionSlow(self: *const FunctionBytecodeImpl) *align(1) const FunctionBytecodeHotExtension {
            const bytes: [*]const u8 = @ptrCast(self);
            if (self.byte_code_len == function_bytecode.legacy_byte_code_len_sentinel) {
                return @ptrCast(bytes + @sizeOf(FunctionBytecodeImpl));
            }
            const offset = self.layout().hot_off orelse unreachable;
            return @ptrCast(bytes + offset);
        }

        noinline fn hotExtensionMutSlow(self: *FunctionBytecodeImpl) *align(1) FunctionBytecodeHotExtension {
            const bytes: [*]u8 = @ptrCast(self);
            if (self.byte_code_len == function_bytecode.legacy_byte_code_len_sentinel) {
                return @ptrCast(bytes + @sizeOf(FunctionBytecodeImpl));
            }
            const offset = self.layout().hot_off orelse unreachable;
            return @ptrCast(bytes + offset);
        }

        inline fn hotExtensionRequiredMut(self: *FunctionBytecodeImpl) *align(1) FunctionBytecodeHotExtension {
            return self.hotExtensionMut() orelse unreachable;
        }

        /// Fast-path accessor for callers that have already established a
        /// canonical non-empty code pointer and extension presence. It skips
        /// the optional-tail discriminator; general consumers must use
        /// `callFacts()` below.
        pub inline fn canonicalCallFacts(self: *const FunctionBytecodeImpl) function_bytecode.CallFacts {
            // Production publication rejects empty code and always installs
            // the zjs tail, and every publication funnel writes the header
            // mirror together with the authoritative FAM word — so the hot
            // read is one fixed-offset halfword instead of a code-ptr +
            // code-len dependent load that touches the far end of the
            // bytecode array. Keep the mirror self-checking in Debug so
            // fixture/embedding misuse fails at the contract boundary.
            std.debug.assert(self.hasExtension());
            std.debug.assert(self.byte_code != null);
            std.debug.assert(self.byte_code_len > 0);
            if (comptime builtin.mode == .Debug) {
                @setRuntimeSafety(false);
                const code_ptr = self.byte_code orelse unreachable;
                const code_len: usize = @intCast(self.byte_code_len);
                const hot: *align(1) const FunctionBytecodeHotExtension =
                    @ptrFromInt(@intFromPtr(code_ptr) +% code_len);
                std.debug.assert(@as(u16, @bitCast(hot.call_facts)) ==
                    @as(u16, @bitCast(self.call_facts_mirror)));
            }
            return self.call_facts_mirror;
        }

        pub fn applyFlags(self: *FunctionBytecodeImpl, flags: Flags) void {
            assignBit(&self.js_mode, js_mode_strict_mask, flags.is_strict_mode);
            assignBit(&self.flag_byte17, byte17_has_prototype_mask, flags.has_prototype);
            assignBit(&self.flag_byte17, byte17_simple_parameters_mask, flags.has_simple_parameter_list);
            assignBit(&self.flag_byte17, byte17_derived_constructor_mask, flags.is_derived_class_constructor);
            assignBit(&self.flag_byte17, byte17_need_home_object_mask, flags.need_home_object);
            self.flag_byte17 = (self.flag_byte17 & ~byte17_func_kind_mask) |
                (@as(u8, @intFromEnum(flags.func_kind)) << byte17_func_kind_shift);
            assignBit(&self.flag_byte17, byte17_new_target_mask, flags.new_target_allowed);
            assignBit(&self.flag_byte17, byte17_super_call_mask, flags.super_call_allowed);
            assignBit(&self.flag_byte18, byte18_super_mask, flags.super_allowed);
            assignBit(&self.flag_byte18, byte18_arguments_mask, flags.arguments_allowed);
            assignBit(&self.flag_byte18, byte18_eval_mask, flags.is_direct_or_indirect_eval);
            assignBit(&self.flag_byte18, byte18_runtime_strict_mask, flags.runtime_strict_mode);
        }

        pub inline fn setFunctionKind(self: *FunctionBytecodeImpl, kind: FunctionKind) void {
            self.flag_byte17 = (self.flag_byte17 & ~byte17_func_kind_mask) |
                (@as(u8, @intFromEnum(kind)) << byte17_func_kind_shift);
        }
        pub inline fn functionKind(self: *const FunctionBytecodeImpl) FunctionKind {
            return @enumFromInt((self.flag_byte17 & byte17_func_kind_mask) >> byte17_func_kind_shift);
        }
        pub inline fn setHasPrototype(self: *FunctionBytecodeImpl, value: bool) void {
            assignBit(&self.flag_byte17, byte17_has_prototype_mask, value);
        }
        pub inline fn hasPrototype(self: *const FunctionBytecodeImpl) bool {
            return bit(self.flag_byte17, byte17_has_prototype_mask);
        }
        pub inline fn setHasSimpleParameterList(self: *FunctionBytecodeImpl, value: bool) void {
            assignBit(&self.flag_byte17, byte17_simple_parameters_mask, value);
        }
        pub inline fn hasSimpleParameterList(self: *const FunctionBytecodeImpl) bool {
            return bit(self.flag_byte17, byte17_simple_parameters_mask);
        }
        pub inline fn isDerivedClassConstructor(self: *const FunctionBytecodeImpl) bool {
            return bit(self.flag_byte17, byte17_derived_constructor_mask);
        }
        pub inline fn setIsDerivedClassConstructor(self: *FunctionBytecodeImpl, value: bool) void {
            assignBit(&self.flag_byte17, byte17_derived_constructor_mask, value);
        }
        pub inline fn needHomeObject(self: *const FunctionBytecodeImpl) bool {
            return bit(self.flag_byte17, byte17_need_home_object_mask);
        }
        pub inline fn newTargetAllowed(self: *const FunctionBytecodeImpl) bool {
            return bit(self.flag_byte17, byte17_new_target_mask);
        }
        pub inline fn superCallAllowed(self: *const FunctionBytecodeImpl) bool {
            return bit(self.flag_byte17, byte17_super_call_mask);
        }
        pub inline fn superAllowed(self: *const FunctionBytecodeImpl) bool {
            return bit(self.flag_byte18, byte18_super_mask);
        }
        pub inline fn argumentsAllowed(self: *const FunctionBytecodeImpl) bool {
            return bit(self.flag_byte18, byte18_arguments_mask);
        }
        pub inline fn isDirectOrIndirectEval(self: *const FunctionBytecodeImpl) bool {
            return bit(self.flag_byte18, byte18_eval_mask);
        }
        pub inline fn callFacts(self: *const FunctionBytecodeImpl) function_bytecode.CallFacts {
            const hot = self.hotExtension() orelse return .{};
            return hot.call_facts;
        }
        pub inline fn ctorAllocProfile(self: *const FunctionBytecodeImpl) ?*align(1) const function_bytecode.CtorAllocProfile {
            const hot = self.hotExtension() orelse return null;
            return &hot.ctor_alloc;
        }
        pub inline fn ctorAllocProfileMut(self: *const FunctionBytecodeImpl) ?*align(1) function_bytecode.CtorAllocProfile {
            const hot = self.hotExtension() orelse return null;
            return &@constCast(hot).ctor_alloc;
        }
        pub inline fn legacyBytecodeAdapter(self: *const FunctionBytecodeImpl) ?*const function_mod.BytecodeImpl {
            // The negative length is the complete representation
            // discriminator: checked canonical layouts can never publish it.
            // Only that stack adapter has the fixed pointer immediately after
            // its base+96 hot extension; canonical FBs have no pointer side.
            if (self.byte_code_len != function_bytecode.legacy_byte_code_len_sentinel) return null;
            std.debug.assert(self.hasExtension());
            const bytes: [*]const u8 = @ptrCast(self);
            const slot: *const ?*const function_mod.BytecodeImpl = @ptrCast(@alignCast(
                bytes + @sizeOf(FunctionBytecodeImpl) + @sizeOf(FunctionBytecodeHotExtension),
            ));
            return slot.*;
        }
        pub inline fn setLegacyBytecodeAdapter(self: *FunctionBytecodeImpl, value: ?*const function_mod.BytecodeImpl) void {
            std.debug.assert(self.byte_code_len == function_bytecode.legacy_byte_code_len_sentinel);
            std.debug.assert(self.hasExtension());
            const bytes: [*]u8 = @ptrCast(self);
            const slot: *?*const function_mod.BytecodeImpl = @ptrCast(@alignCast(
                bytes + @sizeOf(FunctionBytecodeImpl) + @sizeOf(FunctionBytecodeHotExtension),
            ));
            slot.* = value;
        }
        pub inline fn openVarRefCount(self: *const FunctionBytecodeImpl) u16 {
            return self.var_ref_count;
        }
        pub inline fn closureVarCount(self: *const FunctionBytecodeImpl) usize {
            std.debug.assert(self.closure_var_count >= 0);
            return @intCast(self.closure_var_count);
        }
        pub inline fn filenameAtom(self: *const FunctionBytecodeImpl) atom.Atom {
            if (self.legacyBytecodeAdapter()) |legacy| return legacy.filename;
            const dbg = self.debugInfo() orelse return atom.null_atom;
            return dbg.filename;
        }

        // Slice accessors materialize a `[]T` from the bare pointer + length pair.
        // The VM/readers use these instead of touching the raw fields.
        /// Hot-path sibling of `byteCode` for callers holding a proven
        /// materialization invariant: a resolved InlineTarget (its published
        /// call_facts and code[0] eligibility reads exist only for finalized,
        /// materialized FBs) or a resumed caller (its bytecode is executing).
        /// Skips the optional probe branch the interpreter otherwise re-runs
        /// on every call entry and return republication.
        pub inline fn byteCodeAssumeMaterialized(self: *const FunctionBytecodeImpl) []u8 {
            std.debug.assert(self.byte_code != null and self.byte_code_len > 0);
            return self.byte_code.?[0..@intCast(self.byte_code_len)];
        }

        pub inline fn byteCode(self: *const FunctionBytecodeImpl) []u8 {
            // Canonical compiler-produced FBs always have exact, non-empty
            // code in the QJS core pointer/length pair. Keep that path to the
            // two fixed header loads: the Debug tail-dispatch bound assertion
            // calls this accessor for every opcode, so probing the optional
            // legacy extension first would put tail-layout branches in the
            // ordinary interpreter loop. Only the non-escaping mutable-
            // bytecode fixture adapter deliberately leaves the core pointer
            // null.
            if (self.byte_code) |ptr| {
                std.debug.assert(self.byte_code_len > 0);
                return ptr[0..@intCast(self.byte_code_len)];
            }
            return self.byteCodeSlow();
        }

        /// Outlined migration/fixture arm for byteCode(). Keeping the optional
        /// extension walk out of every Debug threaded-handler instantiation is
        /// as important as keeping it off the dynamic production path.
        noinline fn byteCodeSlow(self: *const FunctionBytecodeImpl) []u8 {
            if (self.legacyBytecodeAdapter()) |legacy| return @constCast(legacy.code);
            std.debug.assert(self.byte_code_len >= 0);
            const len: usize = @intCast(self.byte_code_len);
            if (len == 0) {
                return &.{};
            }
            unreachable;
        }
        pub inline fn allVarDefs(self: *const FunctionBytecodeImpl) []BytecodeVarDef {
            if (self.legacyBytecodeAdapter()) |legacy| {
                std.debug.assert(legacy.argdefs.len == 0);
                return @constCast(legacy.vardefs);
            }
            const count: usize = @as(usize, self.arg_count) + @as(usize, self.var_count);
            if (count == 0) {
                std.debug.assert(self.vardefs == null);
                return &.{};
            }
            return (self.vardefs orelse unreachable)[0..count];
        }
        pub inline fn argVarDefs(self: *const FunctionBytecodeImpl) []BytecodeVarDef {
            if (self.legacyBytecodeAdapter()) |legacy| return @constCast(legacy.argdefs);
            return self.allVarDefs()[0..self.arg_count];
        }
        pub inline fn localVarDefs(self: *const FunctionBytecodeImpl) []BytecodeVarDef {
            if (self.legacyBytecodeAdapter()) |legacy| return @constCast(legacy.vardefs);
            return self.allVarDefs()[self.arg_count..];
        }
        /// Compatibility name for readers whose indices address frame locals.
        pub inline fn varDefs(self: *const FunctionBytecodeImpl) []BytecodeVarDef {
            return self.localVarDefs();
        }
        pub inline fn closureVar(self: *const FunctionBytecodeImpl) []BytecodeClosureVar {
            if (self.legacyBytecodeAdapter()) |legacy| return @constCast(legacy.closure_var);
            const count = self.closureVarCount();
            if (count == 0) {
                std.debug.assert(self.closure_var == null);
                return &.{};
            }
            return (self.closure_var orelse unreachable)[0..count];
        }
        pub inline fn cpoolSlice(self: *const FunctionBytecodeImpl) []JSValue {
            if (self.legacyBytecodeAdapter()) |legacy| return legacy.constants.values;
            std.debug.assert(self.cpool_count >= 0);
            const count: usize = @intCast(self.cpool_count);
            if (count == 0) {
                std.debug.assert(self.cpool == null);
                return &.{};
            }
            return (self.cpool orelse unreachable)[0..count];
        }
        pub inline fn constantAt(self: *const FunctionBytecodeImpl, index: usize) ?JSValue {
            const values = self.cpoolSlice();
            if (index >= values.len) return null;
            return values[index].dup();
        }
        pub inline fn funcName(self: *const FunctionBytecodeImpl) atom.Atom {
            return self.func_name;
        }
        pub inline fn varRefIsLexicalAt(self: *const FunctionBytecodeImpl, idx: usize) bool {
            if (self.legacyBytecodeAdapter()) |legacy| return legacy.varRefIsLexicalAt(idx);
            const closure_vars = self.closureVar();
            return idx < closure_vars.len and closure_vars[idx].isLexical();
        }
        pub inline fn varRefIsConstAt(self: *const FunctionBytecodeImpl, idx: usize) bool {
            if (self.legacyBytecodeAdapter()) |legacy| return legacy.varRefIsConstAt(idx);
            const closure_vars = self.closureVar();
            return idx < closure_vars.len and closure_vars[idx].isConst();
        }
        pub inline fn varRefIsGlobalDeclAt(self: *const FunctionBytecodeImpl, idx: usize) bool {
            if (self.legacyBytecodeAdapter()) |legacy| return legacy.varRefIsGlobalDeclAt(idx);
            const closure_vars = self.closureVar();
            return idx < closure_vars.len and closure_vars[idx].closureType() == .global_decl;
        }
        pub inline fn varRefNamesLen(self: *const FunctionBytecodeImpl) usize {
            if (self.legacyBytecodeAdapter()) |legacy| return legacy.varRefNamesLen();
            return self.closureVarCount();
        }
        pub inline fn varRefName(self: *const FunctionBytecodeImpl, idx: usize) atom.Atom {
            if (self.legacyBytecodeAdapter()) |legacy| return legacy.varRefName(idx);
            return self.closureVar()[idx].var_name;
        }
        pub inline fn localOpenBindingIndex(self: *const FunctionBytecodeImpl, idx: usize) ?u16 {
            const vardefs = self.varDefs();
            if (idx >= vardefs.len) return null;
            return if (vardefs[idx].isCaptured()) vardefs[idx].var_ref_idx else null;
        }
        pub inline fn argOpenBindingIndex(self: *const FunctionBytecodeImpl, idx: usize) ?u16 {
            const argdefs = self.argVarDefs();
            if (idx >= argdefs.len) return null;
            return if (argdefs[idx].isCaptured()) argdefs[idx].var_ref_idx else null;
        }
        pub inline fn isGlobalVar(self: *const FunctionBytecodeImpl) bool {
            // `is_global_var` is a compile-time FunctionDef fact in QuickJS.
            // Canonical roots complete closure2 before VM entry; only focused
            // mutable-bytecode fixture adapters still ask the runtime to
            // instantiate declarations.
            return if (self.legacyBytecodeAdapter()) |legacy| legacy.flags.is_global_var else false;
        }
        pub inline fn isModule(self: *const FunctionBytecodeImpl) bool {
            return self.callFacts().execution.is_module;
        }
        pub inline fn isAsync(self: *const FunctionBytecodeImpl) bool {
            return self.functionKind() == .async or self.functionKind() == .async_generator;
        }
        pub inline fn isGenerator(self: *const FunctionBytecodeImpl) bool {
            return self.functionKind() == .generator or self.functionKind() == .async_generator;
        }
        pub inline fn entryContract(self: *const FunctionBytecodeImpl) EntryContract {
            if (self.legacyBytecodeAdapter()) |legacy| return legacy.entry_contract;
            return .{
                .new_target_allowed = self.newTargetAllowed(),
                .super_call_allowed = self.superCallAllowed(),
                .super_allowed = self.superAllowed(),
                .arguments_allowed = self.argumentsAllowed(),
            };
        }
        pub inline fn isStrictMode(self: *const FunctionBytecodeImpl) bool {
            // LegacyExecutionAdapter copies this fact into the QJS js_mode
            // byte during init, so both representations share the direct core
            // load and ordinary calls never need an extension probe.
            return bit(self.js_mode, js_mode_strict_mask);
        }
        pub inline fn runtimeStrictMode(self: *const FunctionBytecodeImpl) bool {
            // As above, applyFlags publishes the adapter's policy into the
            // named zjs bit before the wrapper can escape to execution.
            return bit(self.flag_byte18, byte18_runtime_strict_mask);
        }
        pub inline fn executionFlags(self: *const FunctionBytecodeImpl) ExecutionFlags {
            return self.callFacts().execution;
        }
        pub inline fn setExecutionFlags(self: *FunctionBytecodeImpl, value: ExecutionFlags) void {
            const hot = self.hotExtensionRequiredMut();
            var facts = hot.call_facts;
            facts.execution = value;
            hot.call_facts = facts;
            // Keep the header-resident hot mirror coherent with the
            // authoritative FAM word (canonicalCallFacts reads the mirror).
            self.call_facts_mirror = facts;
        }
        pub inline fn hasMappedArguments(self: *const FunctionBytecodeImpl) bool {
            return self.executionFlags().has_mapped_arguments;
        }
        pub inline fn simpleInlineEligible(self: *const FunctionBytecodeImpl) bool {
            return self.executionFlags().simple_inline_eligible;
        }
        pub inline fn strictSimpleInlineEligible(self: *const FunctionBytecodeImpl) bool {
            return self.executionFlags().strict_simple_inline_eligible;
        }
        pub inline fn strictSimpleSnapshotInlineEligible(self: *const FunctionBytecodeImpl) bool {
            return self.executionFlags().strict_simple_snapshot_inline_eligible;
        }
        pub inline fn simpleInlineEmptyLeaf(self: *const FunctionBytecodeImpl) bool {
            return self.executionFlags().simple_inline_empty_leaf;
        }
        pub inline fn rawThisInlineEmptyLeaf(self: *const FunctionBytecodeImpl) bool {
            return self.executionFlags().raw_this_inline_empty_leaf;
        }
        pub inline fn simpleInlineExactArgsLeaf(self: *const FunctionBytecodeImpl) bool {
            return self.executionFlags().simple_inline_exact_args_leaf;
        }
        pub inline fn rawThisInlineExactArgsLeaf(self: *const FunctionBytecodeImpl) bool {
            return self.executionFlags().raw_this_inline_exact_args_leaf;
        }
        pub inline fn exactArgsLeafKind(self: *const FunctionBytecodeImpl) ExactArgsLeafKind {
            return self.executionFlags().exact_args_leaf_kind;
        }
        pub inline fn captureLeafKind(self: *const FunctionBytecodeImpl) ExactArgsLeafKind {
            return self.executionFlags().capture_leaf_kind;
        }
        pub inline fn smallInlineEligible(self: *const FunctionBytecodeImpl) bool {
            return self.executionFlags().small_inline_eligible;
        }
        pub inline fn applyForwardInlined(self: *const FunctionBytecodeImpl) bool {
            return self.executionFlags().apply_forward_inlined;
        }
        pub inline fn pc2lineBuf(self: *const FunctionBytecodeImpl) []u8 {
            if (self.legacyBytecodeAdapter()) |legacy| return @constCast(legacy.pc2line_buf);
            const dbg = self.debugInfo() orelse return &.{};
            std.debug.assert(dbg.pc2line_len >= 0);
            const len: usize = @intCast(dbg.pc2line_len);
            if (len == 0) {
                std.debug.assert(dbg.pc2line_buf == null);
                return &.{};
            }
            return (dbg.pc2line_buf orelse unreachable)[0..len];
        }
        /// Length of the pc2line buffer, or 0 when no debug info was captured.
        pub inline fn pc2lineLen(self: *const FunctionBytecodeImpl) i32 {
            if (self.legacyBytecodeAdapter()) |legacy| return @intCast(legacy.pc2line_buf.len);
            const dbg = self.debugInfo() orelse return 0;
            return dbg.pc2line_len;
        }
        /// Starting source line, or 0 when no debug info was captured.
        pub inline fn lineNum(self: *const FunctionBytecodeImpl) i32 {
            const bytes = self.pc2lineBuf();
            if (bytes.len != 0) {
                if (pipeline_pc2line.decodeHeader(bytes)) |header| return header.line_num else |_| return 0;
            }
            // A focused mutable-bytecode fixture adapter is the sole remaining
            // parallel-coordinate exception. A present but malformed encoded
            // buffer never falls through to it.
            if (self.legacyBytecodeAdapter()) |legacy| return legacy.line_num;
            return 0;
        }
        /// Starting source column, or 0 when no debug info was captured.
        pub inline fn colNum(self: *const FunctionBytecodeImpl) i32 {
            const bytes = self.pc2lineBuf();
            if (bytes.len != 0) {
                if (pipeline_pc2line.decodeHeader(bytes)) |header| return header.col_num else |_| return 0;
            }
            // See lineNum(): only an empty mutable fixture buffer may use the
            // adapter's temporary parallel start coordinate.
            if (self.legacyBytecodeAdapter()) |legacy| return legacy.col_num;
            return 0;
        }
        /// Original source text, or `null` if none was captured. Materializes the
        /// `[]const u8` from the boxed `source_ptr` + `source_len` pair.
        pub inline fn sourceText(self: *const FunctionBytecodeImpl) ?[]const u8 {
            if (self.legacyBytecodeAdapter() != null) return null;
            const dbg = self.debugInfo() orelse return null;
            const ptr = dbg.source_ptr orelse return null;
            std.debug.assert(dbg.source_len >= 0);
            return ptr[0..@intCast(dbg.source_len)];
        }

        pub inline fn scriptOrModule(self: *const FunctionBytecodeImpl) atom.Atom {
            if (self.legacyBytecodeAdapter()) |legacy| return legacy.script_or_module;
            if (self.hotExtension()) |hot| {
                if (hot.script_or_module != atom.null_atom) return hot.script_or_module;
            }
            return self.filenameAtom();
        }

        fn createRaw(
            account: *memory.MemoryAccount,
            layout_value: function_bytecode.FunctionLayout,
        ) !*FunctionBytecodeImpl {
            const result = try account.createWithFam(FunctionBytecodeImpl, layout_value.famBytes());
            const payload: [*]u8 = @ptrCast(result);
            bulk_memory.fillByte(payload[0..layout_value.mainPayloadBytes()], 0);
            assignBit(&result.flag_byte18, byte18_has_debug_mask, layout_value.has_debug);
            assignBit(&result.flag_byte18, byte18_has_extension_mask, layout_value.has_extension);
            // Seed every layout-driving count and self-pointer before any
            // extension accessor runs. The W1c5 extension follows exact code,
            // so a partially seeded header cannot locate it safely.
            layout_value.seedHeader(result);
            for (layout_value.cpoolSliceMut(result)) |*slot| slot.* = JSValue.undefinedValue();
            // There is no binary-bytecode reader yet. Preserve QuickJS's ROM
            // bit position as a permanently-zero hole for every current producer.
            std.debug.assert(!bit(result.flag_byte18, byte18_rom_mask));
            return result;
        }

        /// Sole production main-allocation owner. It owns no atoms/values until
        /// the finalizer's no-fail commit, but its complete packed payload and
        /// canonical self-pointers already exist.
        pub fn createProductionShell(account: *memory.MemoryAccount, layout_value: function_bytecode.FunctionLayout) !*FunctionBytecodeImpl {
            std.debug.assert(layout_value.has_debug and layout_value.has_extension);
            return createRaw(account, layout_value);
        }

        pub const FixtureOptions = struct {
            name: atom.Atom = atom.ids.empty_string,
            realm: ?*context.RealmContext = null,
            flags: Flags = .{},
            arg_count: u16 = 0,
            var_count: u16 = 0,
            defined_arg_count: u16 = 0,
            stack_size: u16 = 0,
            var_ref_count: u16 = 0,
            closure_var_count: usize = 0,
            cpool_count: usize = 0,
            byte_code: []const u8 = &.{},
            has_debug: bool = false,
            /// Most fixtures need zjs-only mutable facts. Set false only when
            /// the fixture intentionally has no extension tail.
            has_extension: bool = true,
            filename: atom.Atom = atom.null_atom,
            script_or_module: atom.Atom = atom.null_atom,
        };

        /// Fixture-only constructor. It uses the same packed FAM topology as
        /// production; tests may fill initialized table slots before GC
        /// publication and may explicitly omit debug and/or extension tails.
        pub fn createFixture(rt: *runtime.JSRuntime, options: FixtureOptions) !*FunctionBytecodeImpl {
            if (options.defined_arg_count > options.arg_count) return error.BytecodeOverflow;
            const has_extension = options.has_extension or options.script_or_module != atom.null_atom;
            const layout_value = try function_bytecode.FunctionLayout.init(
                options.has_debug,
                has_extension,
                options.cpool_count,
                options.arg_count,
                options.var_count,
                options.closure_var_count,
                options.byte_code.len,
            );
            const fb = try createRaw(&rt.memory, layout_value);
            var raw_owned = true;
            errdefer if (raw_owned) rt.memory.destroyWithFam(FunctionBytecodeImpl, fb, layout_value.famBytes());

            const byte_code = layout_value.byteCodeSliceMut(fb);
            @memcpy(byte_code, options.byte_code);

            fb.applyFlags(options.flags);
            fb.defined_arg_count = options.defined_arg_count;
            fb.stack_size = options.stack_size;
            fb.var_ref_count = options.var_ref_count;

            fb.func_name = rt.atoms.dup(options.name);
            if (options.has_debug) {
                const dbg = fb.debugInfoMut().?;
                dbg.filename = rt.atoms.dup(if (options.filename == atom.null_atom) options.name else options.filename);
            }
            if (options.script_or_module != atom.null_atom) {
                fb.hotExtensionRequiredMut().script_or_module = rt.atoms.dup(options.script_or_module);
            }
            if (options.realm) |realm| fb.realm = context.RealmRef.retain(realm);
            dupBytecodeAtoms(byte_code, &rt.atoms);

            raw_owned = false;
            return fb;
        }

        pub fn destroyUnpublishedFixture(self: *FunctionBytecodeImpl, rt: *runtime.JSRuntime) void {
            const layout_value = self.layout();
            self.deinitWithLayout(rt, layout_value);
            rt.memory.destroyWithFam(FunctionBytecodeImpl, self, layout_value.famBytes());
        }

        /// Final no-fail phase of a fixture transaction. All fallible values,
        /// side boxes, and cycle edges must be prepared before this call.
        pub fn publishFixtureNoFail(self: *FunctionBytecodeImpl, rt: *runtime.JSRuntime) void {
            rt.gc.addInitializedWithSizeNoFail(&self.header, self.heapByteSize());
        }

        pub inline fn realmContext(self: *const FunctionBytecodeImpl) ?*context.RealmContext {
            // Production FBs publish the authoritative RealmRef directly in
            // the QJS core header. Probe that fixed load before consulting the
            // nullable legacy adapter; W1b3c guarantees every compiler output
            // owns a realm while the stack-only adapter leaves this slot null.
            if (self.realm.borrow()) |realm| return realm;
            return self.realmContextSlow();
        }

        noinline fn realmContextSlow(self: *const FunctionBytecodeImpl) ?*context.RealmContext {
            // Next-entry inline specs borrow the entry realm in the hot pad
            // (not RealmRef) so GC does not visit or retain it. See appendix B.
            if (self.hotExtension()) |hot| {
                const raw = std.mem.readInt(usize, hot._ctor_alloc_pad[@sizeOf(usize)..][0..@sizeOf(usize)], .little);
                if (raw != 0 and raw != 0xaaaaaaaaaaaaaaaa) {
                    return @ptrFromInt(raw);
                }
            }
            if (self.legacyBytecodeAdapter()) |legacy| return legacy.realm;
            return null;
        }

        /// Utility for independently-built fixtures: walk final-form bytecode
        /// and duplicate every inline atom owner. Production finalization moves
        /// those owners from the lowering ledger without refcount churn.
        ///
        /// In every atom operand format (`atom`, `atom_u8`, `atom_u16`,
        /// `atom_label_u8`, `atom_label_u16`) the 4-byte atom is the first
        /// operand at `pc + 1`; `hasAtomOperandFmt` selects those formats.
        pub fn dupBytecodeAtoms(byte_code: []const u8, atoms: *atom.AtomTable) void {
            var pc: usize = 0;
            while (pc < byte_code.len) {
                const op_id = byte_code[pc];
                const size: usize = opcode.sizeOf(op_id);
                if (size == 0) break; // unknown id: bail rather than loop
                if (pc + size <= byte_code.len and hasAtomOperandFmt(op_id)) {
                    const atom_id = std.mem.readInt(u32, byte_code[pc + 1 ..][0..4], .little);
                    _ = atoms.dup(atom_id);
                }
                pc += size;
            }
        }

        /// Walk finalized bytecode and free one owner per atom-operand opcode.
        /// Production received these refs by move; fixtures may pair this with
        /// `dupBytecodeAtoms`. Both paths use the same inline owner topology.
        pub fn freeBytecodeAtoms(byte_code: []const u8, atoms: *atom.AtomTable) void {
            var pc: usize = 0;
            while (pc < byte_code.len) {
                const op_id = byte_code[pc];
                const size: usize = opcode.sizeOf(op_id);
                if (size == 0) break;
                if (pc + size <= byte_code.len and hasAtomOperandFmt(op_id)) {
                    const atom_id = std.mem.readInt(u32, byte_code[pc + 1 ..][0..4], .little);
                    atoms.free(atom_id);
                }
                pc += size;
            }
        }

        /// True when the final-form opcode carries an atom operand (its atom is
        /// always the 4-byte field at `pc + 1`). Mirrors the pipeline's
        /// `hasAtomOperand` but lives here so the retention walk is self-contained.
        inline fn hasAtomOperandFmt(op_id: u8) bool {
            const fmt = opcode.formatOf(op_id);
            return fmt == .atom or fmt == .atom_u8 or fmt == .atom_u16 or
                fmt == .atom_label_u8 or fmt == .atom_label_u16;
        }

        /// Iterator over the atom operands embedded in final-form bytecode.
        /// Replaces reads of the removed `atom_operands` array for runtime
        /// consumers (direct-eval scope scans). Yields each atom-operand
        /// opcode's inline 4-byte atom in bytecode order — the same sequence the
        /// former array held. Does not touch refcounts.
        pub const BytecodeAtomIterator = struct {
            byte_code: []const u8,
            pc: usize = 0,

            pub fn next(self: *BytecodeAtomIterator) ?atom.Atom {
                while (self.pc < self.byte_code.len) {
                    const op_id = self.byte_code[self.pc];
                    const size: usize = opcode.sizeOf(op_id);
                    if (size == 0) return null; // unknown id: stop
                    const has_atom = self.pc + size <= self.byte_code.len and hasAtomOperandFmt(op_id);
                    const atom_id: ?atom.Atom = if (has_atom)
                        std.mem.readInt(u32, self.byte_code[self.pc + 1 ..][0..4], .little)
                    else
                        null;
                    self.pc += size;
                    if (atom_id) |a| return a;
                }
                return null;
            }
        };

        /// Convenience constructor for `BytecodeAtomIterator` over this FB.
        pub fn atomOperandIterator(self: *const FunctionBytecodeImpl) BytecodeAtomIterator {
            return .{ .byte_code = self.byteCode() };
        }

        pub fn deinit(self: *FunctionBytecodeImpl, rt: anytype) void {
            self.deinitWithLayout(rt, self.layout());
        }

        fn deinitWithLayout(
            self: *FunctionBytecodeImpl,
            rt: anytype,
            layout_value: function_bytecode.FunctionLayout,
        ) void {
            const mem = &rt.memory;
            const atoms = &rt.atoms;
            // Capture the one checked layout and every inline view before
            // clearing an owner field. The hot extension follows code, so no
            // teardown step may try to rediscover it from cleared state.
            const hot_extension_ptr = layout_value.hotExtensionPtrMut(self);
            const debug_ptr = self.debugInfoMut();
            const byte_code = layout_value.byteCodeSliceMut(self);
            const vardefs = layout_value.vardefsSliceMut(self);
            const cpool = layout_value.cpoolSliceMut(self);
            const closure_var = layout_value.closureVarSliceMut(self);

            // Small-inline CallerState lives in the hot pad and is found via
            // the live code pointer. Tear it down before the code pointer is
            // cleared.
            if (rt.small_inline_destroy) |cb| cb(rt, @ptrCast(self));

            self.byte_code = null;
            self.byte_code_len = 0;
            // The finalized bytecode owns one moved atom ref per atom-operand
            // opcode; release them by re-walking the code before its backing
            // buffer is freed, as qjs does in free_function_bytecode.
            freeBytecodeAtoms(byte_code, atoms);
            // The compact vardef table owns arg_count + var_count atom refs.
            for (vardefs) |*v| atoms.free(v.var_name);
            self.vardefs = null;

            // Match QuickJS's owner order: constant-pool child functions and
            // values are released before closure-name atoms and before Realm.
            self.cpool = null;
            self.cpool_count = 0;
            for (cpool) |*slot| {
                const value = slot.*;
                slot.* = JSValue.undefinedValue();
                value.free(rt);
            }

            // closure_var sized by `closure_var_count`. The former separate
            // `var_ref_names` name array was a redundant mirror of
            // `closure_var[i].var_name` and was
            // removed; every reader now derives the var-ref name from
            // `closure_var[i].var_name` (see `Bytecode.varRefName`).
            for (closure_var) |*cv| atoms.free(cv.var_name);
            self.closure_var = null;
            self.closure_var_count = 0;

            // Match QuickJS free_function_bytecode ordering: release child
            // constants before JS_FreeContext(b->realm). A nested FB may be
            // the reference that keeps this same realm alive during teardown.
            self.realm.deinit();

            const func_name = self.func_name;
            self.func_name = atom.null_atom;
            atoms.free(func_name);

            // Source and pc2line remain exact independent allocations; every
            // table and code byte above lives in the main FAM.
            if (debug_ptr) |dbg| {
                const filename = dbg.filename;
                dbg.filename = atom.null_atom;
                atoms.free(filename);
                std.debug.assert(dbg.pc2line_len >= 0);
                const pc2line_len: usize = @intCast(dbg.pc2line_len);
                const pc2line_buf: []u8 = if (pc2line_len == 0)
                    &.{}
                else
                    (dbg.pc2line_buf orelse unreachable)[0..pc2line_len];
                dbg.pc2line_buf = null;
                dbg.pc2line_len = 0;
                if (pc2line_buf.len != 0) mem.free(u8, pc2line_buf);
                if (dbg.source_ptr) |src_ptr| {
                    std.debug.assert(dbg.source_len >= 0);
                    const logical_len: usize = @intCast(dbg.source_len);
                    const src = src_ptr[0 .. logical_len + 1];
                    dbg.source_ptr = null;
                    dbg.source_len = 0;
                    mem.free(u8, @constCast(src));
                }
            }

            if (hot_extension_ptr) |hot| {
                const script_or_module = hot.script_or_module;
                hot.script_or_module = atom.null_atom;
                if (script_or_module != atom.null_atom) atoms.free(script_or_module);
            }

            // Pass B receives only the header pointer. Preserve the minimum
            // sizing state it needs to reconstruct this exact FAM length after
            // Pass A has released all owners and nulled their pointers.
            if (rt.gc.phase == .remove_cycles or rt.gc.phase == .deinit) {
                layout_value.restoreSizing(self);
            }
        }

        pub fn heapByteSize(self: *const FunctionBytecodeImpl) usize {
            return self.heapByteSizeWithLayout(self.layout());
        }

        fn heapByteSizeWithLayout(
            self: *const FunctionBytecodeImpl,
            layout_value: function_bytecode.FunctionLayout,
        ) usize {
            var bytes: usize = layout_value.mainPayloadBytes();
            if (self.debugInfo()) |dbg| {
                bytes = addSliceBytes(bytes, u8, @intCast(dbg.pc2line_len));
                if (dbg.source_ptr != null) bytes = addSaturating(bytes, @as(usize, @intCast(dbg.source_len)) + 1);
            }
            return bytes;
        }
    };

    /// Sole checked authority for the W1c5 main FunctionBytecode allocation.
    /// Offsets are absolute from the 96-byte FB base and follow QuickJS's
    /// allocation order exactly: optional debug, cpool, vardefs, closure rows,
    /// and exact code bytes. Core segments have no inserted padding. The
    /// eight-byte hot extension starts at exact code_end and is the complete
    /// canonical zjs tail.
    pub const FunctionLayout = struct {
        has_debug: bool,
        has_extension: bool,
        cpool_count: usize,
        arg_count: usize,
        var_count: usize,
        closure_var_count: usize,
        byte_code_len: usize,
        cpool_off: usize,
        vardefs_off: usize,
        closure_var_off: usize,
        byte_code_off: usize,
        byte_code_end: usize,
        hot_off: ?usize,
        total_size: usize,

        pub fn init(
            has_debug: bool,
            has_extension: bool,
            cpool_count: usize,
            arg_count: usize,
            var_count: usize,
            closure_var_count: usize,
            byte_code_len: usize,
        ) error{BytecodeOverflow}!@This() {
            if (arg_count > std.math.maxInt(u16) or var_count > std.math.maxInt(u16) or
                cpool_count > std.math.maxInt(i32) or closure_var_count > std.math.maxInt(i32) or
                byte_code_len > std.math.maxInt(i32))
            {
                return error.BytecodeOverflow;
            }
            const vardef_count = std.math.add(usize, arg_count, var_count) catch return error.BytecodeOverflow;
            const debug_bytes: usize = if (has_debug) @sizeOf(DebugInfo) else 0;
            const cpool_off = std.math.add(usize, @sizeOf(FunctionBytecodeImpl), debug_bytes) catch return error.BytecodeOverflow;
            const cpool_bytes = std.math.mul(usize, cpool_count, @sizeOf(JSValue)) catch return error.BytecodeOverflow;
            const vardefs_off = std.math.add(usize, cpool_off, cpool_bytes) catch return error.BytecodeOverflow;
            const vardef_bytes = std.math.mul(usize, vardef_count, @sizeOf(BytecodeVarDef)) catch return error.BytecodeOverflow;
            const closure_var_off = std.math.add(usize, vardefs_off, vardef_bytes) catch return error.BytecodeOverflow;
            const closure_bytes = std.math.mul(usize, closure_var_count, @sizeOf(BytecodeClosureVar)) catch return error.BytecodeOverflow;
            const byte_code_off = std.math.add(usize, closure_var_off, closure_bytes) catch return error.BytecodeOverflow;
            const byte_code_end = std.math.add(usize, byte_code_off, byte_code_len) catch return error.BytecodeOverflow;
            const hot_off: ?usize = if (has_extension) byte_code_end else null;
            const total_size = if (hot_off) |offset|
                std.math.add(usize, offset, @sizeOf(FunctionBytecodeHotExtension)) catch return error.BytecodeOverflow
            else
                byte_code_end;

            // The pinned QuickJS order is naturally aligned for both supported
            // JSValue representations; padding there would be a layout bug.
            std.debug.assert(cpool_off % @alignOf(JSValue) == 0);
            std.debug.assert(vardefs_off % @alignOf(BytecodeVarDef) == 0);
            std.debug.assert(closure_var_off % @alignOf(BytecodeClosureVar) == 0);
            if (hot_off) |offset| std.debug.assert(offset == byte_code_end);

            return .{
                .has_debug = has_debug,
                .has_extension = has_extension,
                .cpool_count = cpool_count,
                .arg_count = arg_count,
                .var_count = var_count,
                .closure_var_count = closure_var_count,
                .byte_code_len = byte_code_len,
                .cpool_off = cpool_off,
                .vardefs_off = vardefs_off,
                .closure_var_off = closure_var_off,
                .byte_code_off = byte_code_off,
                .byte_code_end = byte_code_end,
                .hot_off = hot_off,
                .total_size = total_size,
            };
        }

        pub fn fromFunction(fb: *const FunctionBytecodeImpl) error{ InvalidBytecode, BytecodeOverflow }!@This() {
            if (fb.cpool_count < 0 or fb.closure_var_count < 0 or fb.byte_code_len < 0) return error.InvalidBytecode;
            return init(
                fb.hasDebug(),
                fb.hasExtension(),
                @intCast(fb.cpool_count),
                fb.arg_count,
                fb.var_count,
                @intCast(fb.closure_var_count),
                @intCast(fb.byte_code_len),
            );
        }

        pub inline fn famBytes(self: @This()) usize {
            return self.total_size - @sizeOf(FunctionBytecodeImpl);
        }

        pub inline fn mainPayloadBytes(self: @This()) usize {
            return self.total_size;
        }

        pub fn cpoolSliceMut(self: @This(), fb: *FunctionBytecodeImpl) []JSValue {
            return packedSlice(fb, JSValue, self.cpool_off, self.cpool_count, self.total_size);
        }

        pub fn vardefsSliceMut(self: @This(), fb: *FunctionBytecodeImpl) []BytecodeVarDef {
            return packedSlice(fb, BytecodeVarDef, self.vardefs_off, self.arg_count + self.var_count, self.total_size);
        }

        pub fn closureVarSliceMut(self: @This(), fb: *FunctionBytecodeImpl) []BytecodeClosureVar {
            return packedSlice(fb, BytecodeClosureVar, self.closure_var_off, self.closure_var_count, self.total_size);
        }

        pub fn byteCodeSliceMut(self: @This(), fb: *FunctionBytecodeImpl) []u8 {
            return packedSlice(fb, u8, self.byte_code_off, self.byte_code_len, self.total_size);
        }

        fn hotExtensionPtrMut(self: @This(), fb: *FunctionBytecodeImpl) ?*align(1) FunctionBytecodeHotExtension {
            const offset = self.hot_off orelse return null;
            const bytes: [*]u8 = @ptrCast(fb);
            return @ptrCast(bytes + offset);
        }

        fn seedHeader(self: @This(), fb: *FunctionBytecodeImpl) void {
            fb.arg_count = @intCast(self.arg_count);
            fb.var_count = @intCast(self.var_count);
            fb.cpool_count = @intCast(self.cpool_count);
            fb.closure_var_count = @intCast(self.closure_var_count);
            fb.byte_code_len = @intCast(self.byte_code_len);
            const cpool = self.cpoolSliceMut(fb);
            const vardefs = self.vardefsSliceMut(fb);
            const closure_var = self.closureVarSliceMut(fb);
            const byte_code = self.byteCodeSliceMut(fb);
            fb.cpool = if (cpool.len == 0) null else cpool.ptr;
            fb.vardefs = if (vardefs.len == 0) null else vardefs.ptr;
            fb.closure_var = if (closure_var.len == 0) null else closure_var.ptr;
            fb.byte_code = if (byte_code.len == 0) null else byte_code.ptr;
        }

        fn restoreSizing(self: @This(), fb: *FunctionBytecodeImpl) void {
            fb.arg_count = @intCast(self.arg_count);
            fb.var_count = @intCast(self.var_count);
            fb.cpool_count = @intCast(self.cpool_count);
            fb.closure_var_count = @intCast(self.closure_var_count);
            fb.byte_code_len = @intCast(self.byte_code_len);
        }
    };

    fn packedSlice(
        fb: *FunctionBytecodeImpl,
        comptime T: type,
        offset: usize,
        len: usize,
        total_size: usize,
    ) []T {
        if (len == 0) return &.{};
        const byte_len = len * @sizeOf(T);
        std.debug.assert(offset + byte_len <= total_size);
        const bytes: [*]u8 = @ptrCast(fb);
        const ptr: [*]T = @ptrCast(@alignCast(bytes + offset));
        return ptr[0..len];
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
        const layout_value = self.layout();
        self.deinitWithLayout(rt, layout_value);
        // Cycle removal and runtime deinit both defer the struct-free until all
        // sibling resource destructors have released their edges.
        if (rt.gc.phase == .remove_cycles or rt.gc.phase == .deinit) {
            rt.gc.deferCycleStructFree(header);
            return;
        }
        rt.memory.destroyWithFam(FunctionBytecodeImpl, self, layout_value.famBytes());
    }

    pub fn freeCycleDeferredStruct(rt: anytype, header: *gc.Header) void {
        const self: *FunctionBytecodeImpl = @alignCast(@fieldParentPtr("header", header));
        // deinit intentionally preserves the two physical-tail presence bits.
        rt.memory.destroyWithFam(FunctionBytecodeImpl, self, self.famBytes());
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
    const compiler = @import("compiler/root.zig");

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

    /// Mirrors `JSVarScope` (`quickjs.c:702`).
    pub const VarScope = struct {
        parent: i32, // index into scopes of the enclosing scope
        first: i32, // index into vars of the last variable in this scope
    };

    pub const ClosureVar = function_bytecode_mod.ClosureVar;

    pub const EvalBindingTarget = function_bytecode_mod.EvalBindingTarget;

    pub const GlobalVar = function_bytecode_mod.GlobalVar;

    /// Compile-only state for the single QuickJS `js_create_function`
    /// preparation pass.  A FunctionDef is prepared before any child and is
    /// resolved only after every child has completed.
    pub const FinalizationState = enum {
        unprepared,
        prepared,
        resolved,
    };

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
    inline fn growSliceBy(
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

        return growSliceBySlow(T, mem, slice, capacity, used, new_used);
    }

    /// QuickJS keeps `js_resize_array` inline and enters its no-inline
    /// `js_realloc_array` only when the requested length exceeds capacity.
    /// Preserve that call shape without changing this backing's growth policy
    /// or its used-length/owned-capacity contract.
    noinline fn growSliceBySlow(
        comptime T: type,
        mem: *memory.MemoryAccount,
        slice: *[]T,
        capacity: *usize,
        used: usize,
        new_used: usize,
    ) ![]T {
        std.debug.assert(new_used > capacity.*);
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
        parent_parameter_environment_only: bool = false,

        // Flags — packed as in QuickJS
        is_eval: bool = false,
        is_global_var: bool = false,
        is_module: bool = false,
        is_direct_eval: bool = false,
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
        need_home_object: bool = false,
        use_short_opcodes: bool = false,
        has_await: bool = false,
        is_indirect_eval: bool = false,
        /// QuickJS reaches `var_object_test` (qjs:32973) only from binding-walk
        /// events: a `<with>` row on the current chain (qjs:33037-33042), the
        /// current function's var_object/arg_var_object (qjs:33180-33192), a
        /// parent-chain environment (qjs:33217-33267), or an eval closure row
        /// (qjs:33307).  It never asks "may this function need dynamic-env
        /// probes" once per operand.  This monotone flag records that a
        /// runtime-var-ref closure row naming a dynamic-env object atom was
        /// appended (see `addClosureVar`, the single closure-row growth path),
        /// so resolve_variables can gate its per-op probe qualification on one
        /// load.  Never cleared: rows are never removed, so a true value stays
        /// an exact "such a row exists" fact for the def's lifetime, and a
        /// false value proves no probe walk can ever be required.
        closure_var_may_have_dynamic_env: bool = false,

        func_kind: FunctionKind = .normal,
        func_type: ParseFunctionKind = .statement,
        is_strict_mode: bool = false,
        /// qjs `fd->is_func_expr && fd->func_name != JS_ATOM_NULL`: this def
        /// is a *named* function expression. Its self-binding var
        /// (`func_var_idx`, kind `.function_name`) and the matching
        /// `special_object THIS_FUNC ; put_loc` prologue materialize lazily on
        /// the first falling-through reference — mirroring qjs, where
        /// add_func_var is only called from resolve_scope_var
        /// (quickjs.c:32975-32978 / 33151-33155) and add_eval_variables
        /// (quickjs.c:33649-33650 / 33697-33698), never unconditionally.
        is_named_func_expr: bool = false,
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
        /// qjs `JSFunctionDef.var_ref_count`: number of local/argument
        /// bindings captured so far. It is advanced by the first capture
        /// event, independently from `closure_var_count` (which describes
        /// cells imported by this function from its parent).
        var_ref_count: i32 = 0,
        finalization_state: FinalizationState = .unprepared,
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
        /// Scope whose OP_enter_scope is intentionally suppressed because
        /// instantiate_hoisted_definitions and its lexical initialization are
        /// injected at the function body boundary.  Like QuickJS, a freshly
        /// allocated FunctionDef has no body until its parser/default-ctor
        /// producer pushes one; the synthetic class-fields aggregator is the
        /// intentional no-body exception.
        body_scope: i32 = -1,
        scope_first: i32 = -1,
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
        last_opcode_pos: i32 = -1,
        /// QCP-1 stage 2P: compiler-v2 emission backend for this function's
        /// parse. Heap-allocated when a v2 parse begins for this function
        /// (stage 5 wires production; for now only the parser test hook does);
        /// released in `deinit`. One optional pointer keeps @sizeOf impact
        /// minimal.
        v2_builder: ?*compiler.Builder = null,
        /// See `FlowTailSummary`. Born valid-empty; the class machinery's
        /// direct byte injections invalidate at their sites and the next
        /// query rebuilds from whatever is present.
        flow_tail: FlowTailSummary = .{},

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
        /// Stable ScriptOrModule identity, separately owned from `filename` so
        /// direct eval can retain its caller's referrer while displaying <eval>.
        script_or_module: atom.Atom,
        // Source coordinates are one-based at the compiler boundary. Even a
        // synthetic/no-source FunctionDef therefore has the canonical (1,1)
        // pc2line header rather than a separate zero-coordinate sentinel.
        line_num: i32 = 1,
        col_num: i32 = 1,
        /// Logical source bytes backed by a `len + 1` allocation with a NUL at
        /// `source_text[len]`. Finalization transfers this exact owner to the FB.
        source_text: ?[:0]const u8 = null,

        // Child functions (nested functions)
        child_list: []*FunctionDefImpl = &.{},
        child_list_capacity: usize = 0,

        pub fn init(account: *memory.MemoryAccount, atoms: *atom.AtomTable, name: atom.Atom) FunctionDefImpl {
            return .{
                .memory = account,
                .atoms = atoms,
                .func_name = atoms.dup(name),
                .filename = atoms.dup(name),
                .script_or_module = atoms.dup(name),
            };
        }

        pub fn replaceSourceText(self: *FunctionDefImpl, source: []const u8) !void {
            const allocation_len = std.math.add(usize, source.len, 1) catch return error.OutOfMemory;
            const allocation = try self.memory.alloc(u8, allocation_len);
            @memcpy(allocation[0..source.len], source);
            allocation[source.len] = 0;
            const owned: [:0]const u8 = allocation[0..source.len :0];
            const old = self.source_text;
            self.source_text = owned;
            if (old) |existing| self.memory.free(u8, @constCast(existing.ptr[0 .. existing.len + 1]));
        }

        pub fn deinitInitFailure(self: *FunctionDefImpl) void {
            const func_name = self.func_name;
            const filename = self.filename;
            const script_or_module = self.script_or_module;
            self.func_name = atom.null_atom;
            self.filename = atom.null_atom;
            self.script_or_module = atom.null_atom;
            self.atoms.free(func_name);
            self.atoms.free(filename);
            self.atoms.free(script_or_module);
            // A root emitter attaches its Builder before the first token is
            // lexed (`ParseState.initRootEmitter`), so an initializer that
            // fails after that point owns one exactly like a fully built
            // FunctionDef does. Release it on the same terms as `deinit`.
            if (self.v2_builder) |v2b| {
                self.v2_builder = null;
                v2b.deinit();
                self.memory.destroy(compiler.Builder, v2b);
            }
            freeGrowableSlice(VarScope, self.memory, &self.scopes, &self.scopes_capacity);
            self.scope_count = 0;
        }

        /// Append a `VarScope` to `scopes`. Mirrors `push_scope`
        /// (`quickjs.c:23486`): the new scope records its parent index
        /// and inherits the current visible binding head. Returns the index
        /// of the newly added scope (== new `scope_level`).
        pub fn appendScope(self: *FunctionDefImpl, parent: i32) !i32 {
            const tail = try growSliceBy(VarScope, self.memory, &self.scopes, &self.scopes_capacity, 1);
            tail[0] = .{ .parent = parent, .first = self.scope_first };
            self.scope_count += 1;
            const idx: i32 = @intCast(self.scopes.len - 1);
            return idx;
        }

        /// Destructively rebuild the final scope linkage once, exactly where
        /// QuickJS does so at the start of `js_create_function`
        /// (quickjs.c:36034-36059).  From this point onward `scopes[].first`
        /// and `VarDef.scope_next` are the sole lexical-chain authority.
        pub fn rebuildFinalScopeLinks(self: *FunctionDefImpl) error{InvalidScope}!void {
            if (self.scopes.len == 0 or self.scope_count != @as(i32, @intCast(self.scopes.len))) return error.InvalidScope;
            if (self.scopes[0].parent != -1) return error.InvalidScope;
            if (self.has_parameter_expressions) {
                if (self.scopes.len <= 1 or self.scopes[1].parent != -1) return error.InvalidScope;
            }
            if (self.body_scope >= 0 and @as(usize, @intCast(self.body_scope)) >= self.scopes.len) {
                return error.InvalidScope;
            }

            for (self.scopes, 0..) |*scope, scope_index| {
                if (scope_index != 0) {
                    if (scope.parent < -1 or
                        (scope.parent >= 0 and @as(usize, @intCast(scope.parent)) >= scope_index))
                    {
                        return error.InvalidScope;
                    }
                }
                scope.first = -1;
            }
            if (self.has_parameter_expressions) {
                self.scopes[1].first = function_bytecode_mod.arg_scope_end;
            }

            for (self.vars, 0..) |*vd, index| {
                if (vd.scope_level < 0 or @as(usize, @intCast(vd.scope_level)) >= self.scopes.len) {
                    return error.InvalidScope;
                }
                vd.scope_next = self.scopes[@intCast(vd.scope_level)].first;
                self.scopes[@intCast(vd.scope_level)].first = @intCast(index);
            }
            var scope_index: usize = 2;
            while (scope_index < self.scopes.len) : (scope_index += 1) {
                const parent = self.scopes[scope_index].parent;
                if (parent < 0) return error.InvalidScope;
                if (self.scopes[scope_index].first < 0) {
                    self.scopes[scope_index].first = self.scopes[@intCast(parent)].first;
                }
            }
            for (self.vars) |*vd| {
                if (vd.scope_next < 0 and vd.scope_level > 1) {
                    const parent = self.scopes[@intCast(vd.scope_level)].parent;
                    if (parent < 0) return error.InvalidScope;
                    vd.scope_next = self.scopes[@intCast(parent)].first;
                }
            }

            self.scope_first = if (self.scope_level >= 0 and
                @as(usize, @intCast(self.scope_level)) < self.scopes.len)
                self.scopes[@intCast(self.scope_level)].first
            else
                -1;
        }

        /// Prove the finalized lexical topology without allocating or changing
        /// it.  QuickJS rebuilds these links once in `js_create_function`, then
        /// its resolver consumes them without per-node bounds/cycle checks.  V2
        /// uses the same boundary: production resolution calls this once after
        /// descendant-driven mutations are complete, while standalone walkers
        /// retain their defensive checks.
        ///
        /// Scope 0 and scope 1 have independent terminal sentinels.  Every
        /// deeper scope either owns an exact-scope prefix or inherits its
        /// already-proven parent head, matching `rebuildFinalScopeLinks` above.
        pub fn validateFinalScopeLinks(self: *const FunctionDefImpl) error{InvalidScope}!void {
            if (self.scopes.len == 0) {
                // Synthetic resolve_variables fixtures may contain no lexical
                // scopes at all.  The retained per-operand scope bound prevents
                // a trusted walker from indexing this vacuous topology.
                if (self.scope_count != 0 or self.body_scope >= 0 or self.scope_first != -1) {
                    return error.InvalidScope;
                }
                return;
            }
            if (self.scopes.len > std.math.maxInt(i32) or
                self.vars.len > @as(usize, std.math.maxInt(u16)) + 1 or
                self.scope_count != @as(i32, @intCast(self.scopes.len)))
            {
                return error.InvalidScope;
            }
            if (self.scopes[0].parent != -1) return error.InvalidScope;
            if (self.has_parameter_expressions and
                (self.scopes.len <= 1 or self.scopes[1].parent != -1))
            {
                return error.InvalidScope;
            }
            if (self.body_scope >= 0 and @as(usize, @intCast(self.body_scope)) >= self.scopes.len) {
                return error.InvalidScope;
            }

            for (self.scopes, 0..) |scope, scope_index| {
                if (scope_index != 0 and
                    (scope.parent < -1 or
                        (scope.parent >= 0 and @as(usize, @intCast(scope.parent)) >= scope_index)))
                {
                    return error.InvalidScope;
                }
                if (scope_index >= 2 and scope.parent < 0) return error.InvalidScope;

                const expected_terminal: i32 = if (scope_index == 0)
                    -1
                else if (scope_index == 1)
                    if (self.has_parameter_expressions)
                        function_bytecode_mod.arg_scope_end
                    else
                        -1
                else
                    self.scopes[@intCast(scope.parent)].first;

                var index = scope.first;
                var visited: usize = 0;
                while (index != expected_terminal) {
                    if (index < 0 or
                        @as(usize, @intCast(index)) >= self.vars.len or
                        visited >= self.vars.len)
                    {
                        return error.InvalidScope;
                    }
                    visited += 1;
                    const vd = self.vars[@intCast(index)];
                    if (vd.scope_level != @as(i32, @intCast(scope_index))) {
                        return error.InvalidScope;
                    }
                    index = vd.scope_next;
                }
            }

            // Unlinked pseudo rows are valid, but every row still names a real
            // lexical level.  This also protects later flat scope-0 scans.
            for (self.vars) |vd| {
                if (vd.scope_level < 0 or @as(usize, @intCast(vd.scope_level)) >= self.scopes.len) {
                    return error.InvalidScope;
                }
            }
        }

        /// Release the parse-only GlobalVar ledger only after its hoist plan
        /// has been installed successfully into resolved bytecode.
        pub fn consumeGlobalVars(self: *FunctionDefImpl) void {
            const globals = self.global_vars;
            const capacity = self.global_vars_capacity;
            self.global_vars = &.{};
            self.global_vars_capacity = 0;
            self.global_var_count = 0;
            for (globals) |*gv| {
                const name = gv.var_name;
                gv.var_name = atom.null_atom;
                self.atoms.free(name);
            }
            if (capacity != 0) self.memory.free(GlobalVar, globals.ptr[0..capacity]);
        }

        /// Mirror qjs add_func_var (quickjs.c:24208-24219): create the named
        /// function expression's self-binding var on demand, idempotent via
        /// `func_var_idx`. QuickJS marks the binding const only when the
        /// defining function is strict; sloppy writes are discarded during
        /// scope resolution instead of reaching the runtime cell.
        pub fn ensureFuncExprSelfBinding(self: *FunctionDefImpl) !i32 {
            if (self.func_var_idx < 0) {
                // add_func_var uses add_var, not add_scope_var: the binding is
                // a special fallback after ordinary scopes/vars/arguments and
                // must not participate in the lexical scope linked list.
                self.func_var_idx = try self.appendVar(.{
                    .var_name = self.func_name,
                    .scope_level = 0,
                    // qjs add_var zero-initializes scope_next. These special
                    // fallbacks are intentionally outside scopes[].first.
                    .scope_next = 0,
                    .is_const = self.is_strict_mode,
                    .var_kind = .function_name,
                });
            }
            return self.func_var_idx;
        }

        /// QuickJS pseudo bindings are appended with `add_var`, after the
        /// ordinary scope graph has been built. They are deliberately absent
        /// from `scopes[].first`: `resolve_pseudo_var` reaches them only after
        /// ordinary current-scope lookup has failed.
        pub fn ensureThisBinding(self: *FunctionDefImpl) !i32 {
            if (self.this_var_idx < 0) {
                self.this_var_idx = try self.appendVar(.{
                    .var_name = atom.ids.this_,
                    .scope_level = 0,
                    .scope_next = 0,
                    .is_lexical = self.is_derived_class_constructor,
                    .var_kind = .normal,
                });
                if (self.is_derived_class_constructor) {
                    // resolve_labels owns the single TDZ initialization in
                    // the function prologue.
                    self.vars[@intCast(self.this_var_idx)].tdz_emitted_at_decl = true;
                }
            }
            return self.this_var_idx;
        }

        pub fn ensureNewTargetBinding(self: *FunctionDefImpl) !i32 {
            if (self.new_target_var_idx < 0) {
                self.new_target_var_idx = try self.appendVar(.{
                    .var_name = atom.ids.new_target,
                    .scope_level = 0,
                    .scope_next = 0,
                    .var_kind = .normal,
                });
            }
            return self.new_target_var_idx;
        }

        pub fn ensureThisActiveFunctionBinding(self: *FunctionDefImpl) !i32 {
            if (self.this_active_func_var_idx < 0) {
                self.this_active_func_var_idx = try self.appendVar(.{
                    .var_name = atom.ids.this_active_func,
                    .scope_level = 0,
                    .scope_next = 0,
                    .var_kind = .normal,
                });
            }
            return self.this_active_func_var_idx;
        }

        pub fn ensureHomeObjectBinding(self: *FunctionDefImpl) !i32 {
            if (self.home_object_var_idx < 0) {
                self.home_object_var_idx = try self.appendVar(.{
                    .var_name = atom.ids.home_object,
                    .scope_level = 0,
                    .scope_next = 0,
                    .var_kind = .normal,
                });
            }
            // QuickJS publishes need_home_object when either the explicit
            // parser bit or the resolved home-object pseudo local is present.
            self.need_home_object = true;
            return self.home_object_var_idx;
        }

        /// Mirror qjs add_arguments_var: the field, rather than a name scan,
        /// owns the identity. An explicit parameter named `arguments` does
        /// not suppress this pseudo binding when direct eval requires it.
        pub fn ensureArgumentsBinding(self: *FunctionDefImpl) !i32 {
            if (self.arguments_var_idx < 0) {
                self.arguments_var_idx = try self.appendVar(.{
                    .var_name = atom.ids.arguments,
                    .scope_level = 0,
                    .scope_next = 0,
                    .var_kind = .normal,
                });
            }
            return self.arguments_var_idx;
        }

        /// Mirror qjs add_arguments_arg. This is the sole pseudo binding that
        /// is manually linked into a scope after normal scope construction.
        /// If an explicit parameter binding already occupies argument scope,
        /// it wins and no synthetic alias is recorded for the prologue copy.
        pub fn ensureArgumentsArgumentBinding(self: *FunctionDefImpl) !void {
            // This is callable after the ordinary one-shot rebuild, including
            // while a descendant resolves a prepared parent.  Refuse malformed
            // input before following it, and leave a freshly proven topology
            // before any caller can resume a trusted production walk.
            try self.validateFinalScopeLinks();
            if (self.arguments_arg_idx >= 0) return;
            const argument_scope_level: i32 = 1;
            if (@as(usize, @intCast(argument_scope_level)) >= self.scopes.len) {
                return error.InvalidScope;
            }

            var scope_idx = self.scopes[@intCast(argument_scope_level)].first;
            while (scope_idx >= 0) {
                if (@as(usize, @intCast(scope_idx)) >= self.vars.len) return error.InvalidScope;
                const vd = self.vars[@intCast(scope_idx)];
                if (vd.scope_level != argument_scope_level) break;
                if (vd.var_name == atom.ids.arguments) return;
                scope_idx = vd.scope_next;
            }

            const idx = try self.appendVar(.{
                .var_name = atom.ids.arguments,
                .scope_level = argument_scope_level,
                .scope_next = self.scopes[@intCast(argument_scope_level)].first,
                .is_lexical = true,
                .var_kind = .normal,
            });
            self.scopes[@intCast(argument_scope_level)].first = idx;
            self.arguments_arg_idx = idx;
            try self.validateFinalScopeLinks();
        }

        /// `arguments_var_idx` is also used for the lazy pseudo binding that
        /// represents the function's body arguments object. A source-level
        /// `var arguments` replaces that pseudo row with a real function var;
        /// its parser origin is retained in `scope_next` (the synthetic row
        /// has the zero origin used by `add_var`). Parameter-initializer
        /// closures need this distinction: without a body declaration they
        /// share the function arguments binding, while `var arguments`
        /// deliberately shadows it with a separate body binding.
        pub fn hasExplicitArgumentsVar(self: *const FunctionDefImpl) bool {
            if (self.arguments_var_idx < 0) return false;
            const idx: usize = @intCast(self.arguments_var_idx);
            if (idx >= self.vars.len) return false;
            return self.vars[idx].scope_next != 0;
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
        pub fn addClosureVar(self: *FunctionDefImpl, init_value: ClosureVar.Init) !i32 {
            const tail = try growSliceBy(ClosureVar, self.memory, &self.closure_var, &self.closure_var_capacity, 1);
            tail[0] = ClosureVar.init(init_value);
            tail[0].var_name = self.atoms.dup(init_value.var_name);
            self.closure_var_count = @intCast(self.closure_var.len);
            // Maintain the dynamic-env possibility flag at the single growth
            // point (qjs:32973 var_object_test precondition; see the field
            // doc).  The predicate mirrors the resolver's per-row test in
            // `closureVarRangeHasDynamicEnvObjects` exactly.
            if (binding_rules.closureVarIsRuntimeVarRef(tail[0]) and
                binding_rules.isDynamicEnvObjectAtom(tail[0].var_name))
            {
                self.closure_var_may_have_dynamic_env = true;
            }
            return @intCast(self.closure_var.len - 1);
        }

        const CaptureError = error{ InvalidBytecode, BytecodeOverflow };

        fn captureBinding(self: *FunctionDefImpl, vd: *VarDef) CaptureError!void {
            if (vd.open_binding_idx != function_bytecode_mod.no_open_binding) {
                vd.is_captured = true;
                return;
            }
            if (self.var_ref_count < 0) return error.InvalidBytecode;
            const next: u32 = @intCast(self.var_ref_count);
            if (next >= function_bytecode_mod.no_open_binding) return error.BytecodeOverflow;
            vd.is_captured = true;
            vd.open_binding_idx = @intCast(next);
            self.var_ref_count += 1;
        }

        /// qjs `capture_var(fd, &fd->vars[idx])`: the first real capture event
        /// assigns the stable owner-frame cell index immediately.
        pub fn captureLocal(self: *FunctionDefImpl, idx: usize) CaptureError!void {
            if (idx >= self.vars.len) return error.InvalidBytecode;
            try self.captureBinding(&self.vars[idx]);
        }

        /// qjs `capture_var(fd, &fd->args[idx])`.
        pub fn captureArg(self: *FunctionDefImpl, idx: usize) CaptureError!void {
            if (idx >= self.args.len) return error.InvalidBytecode;
            try self.captureBinding(&self.args[idx]);
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
            const tail = try growSliceBy(u8, self.memory, &self.byte_code, &self.byte_code_capacity, bytes.len);
            @memcpy(tail, bytes);
        }

        /// Reserve parser-phase code capacity without publishing any bytes.
        /// This is the recoverable-OOM counterpart of QuickJS `dbuf_claim`:
        /// allocation happens before an emitter transaction detaches an
        /// lvalue getter or transfers an atom owner.
        pub fn reserveByteCode(self: *FunctionDefImpl, additional: usize) !void {
            if (additional == 0) return;
            const used = self.byte_code.len;
            _ = try growSliceBy(u8, self.memory, &self.byte_code, &self.byte_code_capacity, additional);
            self.byte_code = self.byte_code.ptr[0..used];
        }

        /// Append after `reserveByteCode`. No allocation or error is possible.
        pub fn appendByteCodeAssumeCapacity(self: *FunctionDefImpl, bytes: []const u8) void {
            if (bytes.len == 0) return;
            const used = self.byte_code.len;
            std.debug.assert(used + bytes.len <= self.byte_code_capacity);
            self.byte_code = self.byte_code.ptr[0 .. used + bytes.len];
            @memcpy(self.byte_code[used..], bytes);
        }

        pub fn appendSourceLoc(self: *FunctionDefImpl, pc: u32, line_num: i32, col_num: i32) !void {
            if (line_num <= 0 or col_num <= 0) return;
            // The phase-2 streaming source remap (P2-R1T) requires
            // non-decreasing slot pcs; producers append at the emission end.
            std.debug.assert(self.source_loc_slots.len == 0 or
                self.source_loc_slots[self.source_loc_slots.len - 1].pc <= pc);
            const tail = try growSliceBy(pipeline_pc2line.SourceLocSlot, self.memory, &self.source_loc_slots, &self.source_loc_capacity, 1);
            tail[0] = .{ .pc = pc, .line_num = line_num, .col_num = col_num };
            self.source_loc_count = @intCast(self.source_loc_slots.len);
        }

        /// Roll back parser-phase source locations without releasing the backing
        /// allocation. Emission commits bytecode, atom operands, and pc2line
        /// provenance as one transaction, so this operation must not allocate.
        pub fn truncateSourceLocs(self: *FunctionDefImpl, target_len: usize) void {
            std.debug.assert(target_len <= self.source_loc_slots.len);
            self.source_loc_slots = self.source_loc_slots.ptr[0..target_len];
            self.source_loc_count = @intCast(target_len);
        }

        pub fn appendAtomOperand(self: *FunctionDefImpl, atom_id: atom.Atom) !void {
            const tail = try growSliceBy(atom.Atom, self.memory, &self.atom_operands, &self.atom_operands_capacity, 1);
            tail[0] = self.atoms.dup(atom_id);
        }

        /// Reserve atom-operand capacity without retaining or publishing an
        /// atom. Paired with the assume-capacity append helpers below.
        pub fn reserveAtomOperands(self: *FunctionDefImpl, additional: usize) !void {
            if (additional == 0) return;
            const used = self.atom_operands.len;
            _ = try growSliceBy(atom.Atom, self.memory, &self.atom_operands, &self.atom_operands_capacity, additional);
            self.atom_operands = self.atom_operands.ptr[0..used];
        }

        pub fn appendAtomOperandAssumeCapacity(self: *FunctionDefImpl, atom_id: atom.Atom) void {
            const used = self.atom_operands.len;
            std.debug.assert(used < self.atom_operands_capacity);
            self.atom_operands = self.atom_operands.ptr[0 .. used + 1];
            self.atom_operands[used] = self.atoms.dup(atom_id);
        }

        /// Append an atom reference whose ownership is transferred by the
        /// caller.  Used by parser get_lvalue/put_lvalue when the retained
        /// operand of a removed getter becomes the operand of its setter.
        pub fn appendAtomOperandOwned(self: *FunctionDefImpl, atom_id: atom.Atom) !void {
            const tail = try growSliceBy(atom.Atom, self.memory, &self.atom_operands, &self.atom_operands_capacity, 1);
            tail[0] = atom_id;
        }

        pub fn appendAtomOperandOwnedAssumeCapacity(self: *FunctionDefImpl, atom_id: atom.Atom) void {
            const used = self.atom_operands.len;
            std.debug.assert(used < self.atom_operands_capacity);
            self.atom_operands = self.atom_operands.ptr[0 .. used + 1];
            self.atom_operands[used] = atom_id;
        }

        /// Remove the final operand entry without releasing its atom.  The
        /// caller becomes responsible for either transferring or freeing it.
        pub fn takeLastAtomOperand(self: *FunctionDefImpl) atom.Atom {
            std.debug.assert(self.atom_operands.len != 0);
            const atom_id = self.atom_operands[self.atom_operands.len - 1];
            self.atom_operands = self.atom_operands.ptr[0 .. self.atom_operands.len - 1];
            return atom_id;
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
            const script_or_module = self.script_or_module;
            self.func_name = atom.null_atom;
            self.filename = atom.null_atom;
            self.script_or_module = atom.null_atom;
            self.atoms.free(func_name);
            self.atoms.free(filename);
            self.atoms.free(script_or_module);

            // Parse-time/error-path backstop; successful v2 lowering
            // releases the builder at its consumption point.
            if (self.v2_builder) |v2b| {
                self.v2_builder = null;
                v2b.deinit();
                self.memory.destroy(compiler.Builder, v2b);
            }

            freeGrowableNamedSlice(VarDef, self.atoms, self.memory, &self.vars, &self.vars_capacity);
            if (self.vars_htab.len != 0) self.memory.free(u32, self.vars_htab);

            freeGrowableNamedSlice(VarDef, self.atoms, self.memory, &self.args, &self.args_capacity);

            freeGrowableSlice(VarScope, self.memory, &self.scopes, &self.scopes_capacity);

            freeGrowableNamedSlice(GlobalVar, self.atoms, self.memory, &self.global_vars, &self.global_vars_capacity);

            freeGrowableSlice(u8, self.memory, &self.byte_code, &self.byte_code_capacity);
            freeGrowableAtomSlice(self.atoms, self.memory, &self.atom_operands, &self.atom_operands_capacity);
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

            if (self.jump_slots.len != 0) self.memory.free(JumpSlot, self.jump_slots);

            freeGrowableSlice(pipeline_pc2line.SourceLocSlot, self.memory, &self.source_loc_slots, &self.source_loc_capacity);
            if (self.source_text) |source| self.memory.free(u8, @constCast(source.ptr[0 .. source.len + 1]));

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
            self.jump_slots = &.{};
            self.source_text = null;
            if (old_child_list_capacity != 0) self.memory.free(*FunctionDefImpl, old_child_list.ptr[0..old_child_list_capacity]);
        }
    };

    pub const FunctionDef = FunctionDefImpl;
};

/// Incrementally-maintained parser flow-tail summary backing the O(1)
/// last-opcode / end-jump queries (mirrors the qjs `fd->last_opcode_pos`
/// discipline, quickjs.c:22067/23809, extended to zjs's absolute-target
/// patching of loop/branch exits). `valid=false` means the summary must be
/// rebuilt from the code before use; every mutation path that is not routed
/// through the parser's unified emission/publish primitives (moved-bytecode
/// splices, direct FunctionDef appends by the class machinery,
/// watermark-lowering operand rewrites) invalidates instead of tracking.
pub const FlowTailSummary = struct {
    /// Last opcode ignoring only line_num markers.
    last_non_line_op: ?u8 = null,
    /// Last opcode ignoring line_num / leave_scope / close_loc.
    last_non_cleanup_op: ?u8 = null,
    /// End offset of the last non-cleanup opcode (== `trailingCleanupStart`).
    tail_start: u32 = 0,
    /// Maximum untagged absolute label-operand value currently in the code.
    max_absolute_target: u32 = 0,
    /// Number of label operands currently holding tagged parser-label ids.
    tagged_target_count: u32 = 0,
    /// One-deep history so `truncateCode` rolling back exactly the most
    /// recent single-instruction emission (speculative LHS -> put form)
    /// restores precisely instead of invalidating on the hot path.
    prev_last_non_line_op: ?u8 = null,
    prev_last_non_cleanup_op: ?u8 = null,
    prev_tail_start: u32 = 0,
    prev_op_pos: u32 = 0,
    has_prev: bool = false,
    /// The most recent note changed tagged/watermark bookkeeping, so the
    /// one-deep rollback cannot restore it; truncation must invalidate.
    last_note_had_label: bool = false,
    /// Streams are born empty and valid; every mutation path that bypasses
    /// the parser's unified emission/publish primitives must set this false.
    valid: bool = true,
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

    /// Encoded pc2line buffer. Like QuickJS, the first two ULEB128 values are
    /// the function's zero-based starting line and column; transition records
    /// follow immediately. There is no parallel coordinate authority.
    pub const Encoded = struct {
        bytes: []u8,
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
        // First pass validates every delta and computes the exact encoded
        // length. The second pass writes directly into one accounted owner;
        // there is no growable temporary or shrink/copy allocation.
        var measure = Encoder{};
        try encodeInto(&measure, slots, start_line_num, start_col_num);
        const owned = try account.alloc(u8, measure.index);
        errdefer account.free(u8, owned);
        var writer = Encoder{ .output = owned };
        try encodeInto(&writer, slots, start_line_num, start_col_num);
        if (writer.index != owned.len) return error.Pc2LineOverflow;
        return .{
            .bytes = owned,
            .memory = account,
        };
    }

    const Encoder = struct {
        output: ?[]u8 = null,
        index: usize = 0,

        fn putByte(self: *Encoder, byte: u8) !void {
            const next = std.math.add(usize, self.index, 1) catch return error.Pc2LineOverflow;
            if (self.output) |out| {
                if (self.index >= out.len) return error.Pc2LineOverflow;
                out[self.index] = byte;
            }
            self.index = next;
        }

        fn putLeb128(self: *Encoder, value: u32) !void {
            var v = value;
            while (true) {
                const byte: u8 = @intCast(v & 0x7f);
                v >>= 7;
                if (v == 0) {
                    try self.putByte(byte);
                    return;
                }
                try self.putByte(byte | 0x80);
            }
        }

        fn putSleb128(self: *Encoder, value: i32) !void {
            // QuickJS's dbuf_put_sleb128 uses zig-zag signed-to-unsigned
            // mapping followed by ordinary ULEB128.
            const bits: u32 = @bitCast(value);
            const encoded = (bits << 1) ^ (0 -% (bits >> 31));
            try self.putLeb128(encoded);
        }
    };

    fn encodeInto(
        encoder: *Encoder,
        slots: []const SourceLocSlot,
        start_line_num: i32,
        start_col_num: i32,
    ) !void {
        if (start_line_num <= 0 or start_col_num <= 0) return error.Pc2LineOverflow;
        const initial_line: u32 = std.math.cast(u32, start_line_num - 1) orelse return error.Pc2LineOverflow;
        const initial_col: u32 = std.math.cast(u32, start_col_num - 1) orelse return error.Pc2LineOverflow;
        try encoder.putLeb128(initial_line);
        try encoder.putLeb128(initial_col);

        var last_line_num: i32 = start_line_num;
        var last_col_num: i32 = start_col_num;
        var last_pc: u32 = 0;
        for (slots) |slot| {
            if (slot.line_num < 0 or slot.pc < last_pc) continue;

            const diff_pc = slot.pc - last_pc;
            const diff_line = std.math.sub(i32, slot.line_num, last_line_num) catch return error.Pc2LineOverflow;
            const diff_col = std.math.sub(i32, slot.col_num, last_col_num) catch return error.Pc2LineOverflow;
            if (diff_line == 0 and diff_col == 0) continue;

            if (diff_line >= PC2LINE_BASE and
                diff_line < PC2LINE_BASE + PC2LINE_RANGE and
                diff_pc <= @as(u32, @intCast(PC2LINE_DIFF_PC_MAX)))
            {
                try encoder.putByte(@intCast(
                    (diff_line - PC2LINE_BASE) + @as(i32, @intCast(diff_pc)) * PC2LINE_RANGE + PC2LINE_OP_FIRST,
                ));
            } else {
                try encoder.putByte(0);
                try encoder.putLeb128(diff_pc);
                try encoder.putSleb128(diff_line);
            }
            try encoder.putSleb128(diff_col);

            last_pc = slot.pc;
            last_line_num = slot.line_num;
            last_col_num = slot.col_num;
        }
    }

    pub const Header = struct {
        line_num: i32,
        col_num: i32,
        payload_offset: usize,
    };

    /// Decode QuickJS's two mandatory pc2line header values without
    /// allocating. Stored values are zero-based; engine source locations are
    /// one-based.
    pub fn decodeHeader(bytes: []const u8) !Header {
        var index: usize = 0;
        const stored_line = try readLeb128(bytes, &index);
        const stored_col = try readLeb128(bytes, &index);
        const line_num = std.math.cast(i32, stored_line) orelse return error.Pc2LineOverflow;
        const col_num = std.math.cast(i32, stored_col) orelse return error.Pc2LineOverflow;
        if (line_num == std.math.maxInt(i32) or col_num == std.math.maxInt(i32)) return error.Pc2LineOverflow;
        return .{
            .line_num = line_num + 1,
            .col_num = col_num + 1,
            .payload_offset = index,
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

        const header = try decodeHeader(encoded.bytes);
        var pc: u32 = 0;
        var line_num: i32 = header.line_num;
        var col_num: i32 = header.col_num;
        var i: usize = header.payload_offset;
        while (i < encoded.bytes.len) {
            const op = encoded.bytes[i];
            i += 1;
            if (op == 0) {
                const diff_pc = try readLeb128(encoded.bytes, &i);
                const diff_line = try readSleb128(encoded.bytes, &i);
                pc = std.math.add(u32, pc, diff_pc) catch return error.Pc2LineOverflow;
                line_num = std.math.add(i32, line_num, diff_line) catch return error.Pc2LineOverflow;
            } else {
                const adjusted: i32 = @as(i32, op) - PC2LINE_OP_FIRST;
                const diff_pc: i32 = @divFloor(adjusted, PC2LINE_RANGE);
                const diff_line: i32 = @mod(adjusted, PC2LINE_RANGE) + PC2LINE_BASE;
                pc = std.math.add(u32, pc, @intCast(diff_pc)) catch return error.Pc2LineOverflow;
                line_num = std.math.add(i32, line_num, diff_line) catch return error.Pc2LineOverflow;
            }
            const diff_col = try readSleb128(encoded.bytes, &i);
            col_num = std.math.add(i32, col_num, diff_col) catch return error.Pc2LineOverflow;

            try slots.append(allocator, .{
                .pc = pc,
                .line_num = line_num,
                .col_num = col_num,
            });
        }
        return slots.toOwnedSlice(allocator);
    }

    /// Resolve the source location at `target_pc` with the same strict
    /// malformed-buffer behavior as QuickJS `find_line_num`. The header is the
    /// location before the first transition, so a target before the first slot
    /// (and a buffer with no slots) resolves to the function definition.
    pub fn findSourceLocation(bytes: []const u8, target_pc: u32) !SourceLocSlot {
        const header = try decodeHeader(bytes);
        var current = SourceLocSlot{
            .pc = 0,
            .line_num = header.line_num,
            .col_num = header.col_num,
        };
        var i = header.payload_offset;
        while (i < bytes.len) {
            const marker = bytes[i];
            i += 1;

            var next_pc = current.pc;
            var next_line = current.line_num;
            if (marker == 0) {
                const diff_pc = try readLeb128(bytes, &i);
                const diff_line = try readSleb128(bytes, &i);
                next_pc = std.math.add(u32, next_pc, diff_pc) catch return error.Pc2LineOverflow;
                next_line = std.math.add(i32, next_line, diff_line) catch return error.Pc2LineOverflow;
            } else {
                const adjusted: i32 = @as(i32, marker) - PC2LINE_OP_FIRST;
                const diff_pc: u32 = @intCast(@divFloor(adjusted, PC2LINE_RANGE));
                const diff_line: i32 = @mod(adjusted, PC2LINE_RANGE) + PC2LINE_BASE;
                next_pc = std.math.add(u32, next_pc, diff_pc) catch return error.Pc2LineOverflow;
                next_line = std.math.add(i32, next_line, diff_line) catch return error.Pc2LineOverflow;
            }
            const diff_col = try readSleb128(bytes, &i);
            const next_col = std.math.add(i32, current.col_num, diff_col) catch return error.Pc2LineOverflow;

            if (target_pc < next_pc) return current;
            current = .{
                .pc = next_pc,
                .line_num = next_line,
                .col_num = next_col,
            };
        }
        return current;
    }

    // ---- LEB128 helpers ----

    fn readLeb128(bytes: []const u8, i: *usize) !u32 {
        var result: u32 = 0;
        var shift: u32 = 0;
        while (true) {
            if (i.* >= bytes.len) return error.Pc2LineTruncated;
            const byte = bytes[i.*];
            i.* += 1;
            const payload: u32 = byte & 0x7f;
            if (shift == 28 and payload > 0x0f) return error.Pc2LineOverflow;
            result |= payload << @intCast(shift);
            if ((byte & 0x80) == 0) return result;
            if (shift == 28) return error.Pc2LineOverflow;
            shift += 7;
        }
    }

    fn readSleb128(bytes: []const u8, i: *usize) !i32 {
        const encoded = try readLeb128(bytes, i);
        const decoded: u32 = (encoded >> 1) ^ (0 -% (encoded & 1));
        return @bitCast(decoded);
    }

    test "pc2line: empty slot list contains the mandatory QuickJS header" {
        var account = memory.MemoryAccount.init(std.testing.allocator);
        var encoded = try encode(&account, &.{}, 1, 1);
        try std.testing.expectEqualSlices(u8, &.{ 0, 0 }, encoded.bytes);
        try std.testing.expectEqual(@as(usize, 1), account.alloc_calls);
        try std.testing.expectEqual(@as(usize, 1), account.allocation_count);
        try std.testing.expectEqual(@as(usize, 1), account.peak_allocation_count);
        const header = try decodeHeader(encoded.bytes);
        try std.testing.expectEqual(@as(i32, 1), header.line_num);
        try std.testing.expectEqual(@as(i32, 1), header.col_num);
        try std.testing.expectEqual(@as(usize, 2), header.payload_offset);
        encoded.deinit();
        try std.testing.expectEqual(@as(usize, 0), account.allocation_count);
    }

    test "pc2line: QuickJS header is zero-based ULEB128 byte-for-byte" {
        var account = memory.MemoryAccount.init(std.testing.allocator);
        var encoded = try encode(&account, &.{}, 130, 257);
        defer encoded.deinit();

        // 130 - 1 = 129 -> 0x81 0x01; 257 - 1 = 256 -> 0x80 0x02.
        try std.testing.expectEqualSlices(u8, &.{ 0x81, 0x01, 0x80, 0x02 }, encoded.bytes);
        const header = try decodeHeader(encoded.bytes);
        try std.testing.expectEqual(@as(i32, 130), header.line_num);
        try std.testing.expectEqual(@as(i32, 257), header.col_num);
        try std.testing.expectEqual(encoded.bytes.len, header.payload_offset);
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
        // Compact byte = (0 - (-1)) + 5*5 + 1 = 1 + 25 + 1 = 27, then
        // QuickJS zig-zag sleb128(3) = uleb128(6) = 0x06.
        try std.testing.expectEqualSlices(u8, &.{ 0, 0, 27, 6 }, encoded.bytes);
    }

    test "pc2line: long encoding for large pc delta" {
        var account = memory.MemoryAccount.init(std.testing.allocator);
        const slots = [_]SourceLocSlot{
            .{ .pc = 100, .line_num = 2, .col_num = 1 },
        };
        var encoded = try encode(&account, &slots, 1, 1);
        defer encoded.deinit();

        // diff_pc=100 > MAX(50) → long form: 0, leb128(100),
        // zig-zag sleb128(1)=2, zig-zag sleb128(0)=0.
        try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 100, 2, 0 }, encoded.bytes);
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

    test "pc2line: source lookup covers definition, slots, and trailing pc" {
        var account = memory.MemoryAccount.init(std.testing.allocator);
        const input_slots = [_]SourceLocSlot{
            .{ .pc = 5, .line_num = 11, .col_num = 7 },
            .{ .pc = 12, .line_num = 14, .col_num = 2 },
        };
        var encoded = try encode(&account, &input_slots, 10, 3);
        defer encoded.deinit();

        const before = try findSourceLocation(encoded.bytes, 4);
        try std.testing.expectEqual(@as(i32, 10), before.line_num);
        try std.testing.expectEqual(@as(i32, 3), before.col_num);

        const first = try findSourceLocation(encoded.bytes, 5);
        try std.testing.expectEqual(@as(i32, 11), first.line_num);
        try std.testing.expectEqual(@as(i32, 7), first.col_num);

        const middle = try findSourceLocation(encoded.bytes, 11);
        try std.testing.expectEqual(@as(i32, 11), middle.line_num);
        try std.testing.expectEqual(@as(i32, 7), middle.col_num);

        const trailing = try findSourceLocation(encoded.bytes, 1000);
        try std.testing.expectEqual(@as(i32, 14), trailing.line_num);
        try std.testing.expectEqual(@as(i32, 2), trailing.col_num);
    }

    test "pc2line: malformed header or transition never returns a partial location" {
        try std.testing.expectError(error.Pc2LineTruncated, decodeHeader(&.{}));
        try std.testing.expectError(error.Pc2LineTruncated, decodeHeader(&.{0}));
        try std.testing.expectError(
            error.Pc2LineOverflow,
            decodeHeader(&.{ 0x80, 0x80, 0x80, 0x80, 0x10, 0 }),
        );

        // Valid 1:1 header followed by a truncated long record and a compact
        // record missing its signed column delta.
        try std.testing.expectError(error.Pc2LineTruncated, findSourceLocation(&.{ 0, 0, 0 }, 0));
        try std.testing.expectError(error.Pc2LineTruncated, findSourceLocation(&.{ 0, 0, 1 }, 0));

        // Signed deltas use QuickJS zig-zag over ULEB, so the same fifth-group
        // u32 overflow rule applies to them.
        try std.testing.expectError(
            error.Pc2LineOverflow,
            findSourceLocation(&.{ 0, 0, 0, 0, 0x80, 0x80, 0x80, 0x80, 0x10 }, 0),
        );
    }

    test "pc2line: full u32 pc delta is encoded without narrowing traps" {
        var account = memory.MemoryAccount.init(std.testing.allocator);
        const slots = [_]SourceLocSlot{
            .{ .pc = std.math.maxInt(u32), .line_num = 1, .col_num = 2 },
        };
        var encoded = try encode(&account, &slots, 1, 1);
        defer encoded.deinit();

        const decoded = try decode(std.testing.allocator, encoded);
        defer std.testing.allocator.free(decoded);
        try std.testing.expectEqual(@as(usize, 1), decoded.len);
        try std.testing.expectEqual(std.math.maxInt(u32), decoded[0].pc);
        try std.testing.expectEqual(@as(i32, 2), decoded[0].col_num);
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

    test "pc2line: QuickJS signed deltas use zig-zag bytes" {
        var account = memory.MemoryAccount.init(std.testing.allocator);
        const slots = [_]SourceLocSlot{
            .{ .pc = 1, .line_num = 1, .col_num = 1 },
        };
        var encoded = try encode(&account, &slots, 1, 2);
        defer encoded.deinit();

        // Header is (line-1=0, col-1=1). The compact transition marker is 7;
        // QuickJS maps signed column delta -1 to unsigned 1 before ULEB.
        try std.testing.expectEqualSlices(u8, &.{ 0, 1, 7, 1 }, encoded.bytes);

        const long_slots = [_]SourceLocSlot{
            .{ .pc = 100, .line_num = 1, .col_num = 1 },
        };
        var long_encoded = try encode(&account, &long_slots, 2, 3);
        defer long_encoded.deinit();
        // Header=(1,2), long marker, pc delta 100, then zig-zag(-1)=1
        // and zig-zag(-2)=3. This pins signed transition bytes independently
        // of the symmetric decoder.
        try std.testing.expectEqualSlices(u8, &.{ 1, 2, 0, 100, 1, 3 }, long_encoded.bytes);
    }
};

pub const binding_rules = struct {
    //! Binding resolution rules.
    //!
    //! Mirrors the binding decisions and lowering writers of
    //! `resolve_variables` at `quickjs.c:33622`: lexical-chain walk order,
    //! closure-source threading, dynamic-environment probe planning, private
    //! brand resolution, and the exact byte forms each decision writes.
    //!
    //! This is a rule library, not a pass. `compiler/resolve_variables.zig`
    //! owns the pass structure (block CFG, LabelId operands, transactional
    //! output) and calls in here for every binding decision, so there is one
    //! definition of QuickJS binding semantics in the tree.

    const std = @import("std");
    const atom = @import("core/atom.zig");
    const memory = @import("core/memory.zig");
    const bytecode_function = function_mod;
    const function_def_mod = function_def;

    const EVAL_SCOPE_HEAD_BIAS: i32 = -function_bytecode.arg_scope_end;
    const atom_var_object: atom.Atom = atom.ids.var_object; // "<var>"
    const exact_scope_binding_index_threshold: usize = 64;
    const ExactScopeBindingIndex = std.AutoHashMapUnmanaged(u64, u16);

    const ScopeOperand = struct {
        level: i16,
        no_dynamic_env: bool,
    };

    fn decodeScopeOperand(bytes: *const [2]u8) ScopeOperand {
        const raw = std.mem.readInt(u16, bytes, .little);
        if (raw == std.math.maxInt(u16)) {
            return .{ .level = -1, .no_dynamic_env = false };
        }
        return .{
            .level = @intCast(raw & ~opcode.scope_no_dynamic_env_flag),
            .no_dynamic_env = (raw & opcode.scope_no_dynamic_env_flag) != 0,
        };
    }

    pub const Error = error{
        OutOfMemory,
        InvalidBytecode,
        BytecodeOverflow,
        NoFunctionDef,
        NoParentScope,
        ClosureVarNotFound,
    };

    fn markEvalCapturedVariables(fd: *function_def_mod.FunctionDef, scope_level: u16) Error!void {
        if (scope_level >= fd.scopes.len) return error.InvalidBytecode;
        var index = fd.scopes[scope_level].first;
        var visited: usize = 0;
        while (index >= 0) {
            if (@as(usize, @intCast(index)) >= fd.vars.len or visited >= fd.vars.len) {
                return error.InvalidBytecode;
            }
            visited += 1;
            const local_index: usize = @intCast(index);
            fd.captureLocal(local_index) catch |err| return switch (err) {
                error.InvalidBytecode => error.InvalidBytecode,
                error.BytecodeOverflow => error.BytecodeOverflow,
            };
            index = fd.vars[local_index].scope_next;
        }
        if (index != -1 and index != function_bytecode.arg_scope_end) return error.InvalidBytecode;
    }

    fn encodeEvalScopeHead(fd: *const function_def_mod.FunctionDef, scope_level: u16) Error!u16 {
        if (scope_level >= fd.scopes.len) return error.InvalidBytecode;
        const head = fd.scopes[scope_level].first;
        const encoded = head + EVAL_SCOPE_HEAD_BIAS;
        if (encoded < 0 or encoded > std.math.maxInt(u16)) return error.BytecodeOverflow;
        return @intCast(encoded);
    }

    /// The FunctionDef parent relation is borrowed and intentionally has no
    /// arbitrary nesting cap.  Floyd's walk makes both the production proof
    /// and standalone fallback fail closed on a synthetic parent cycle without
    /// allocating a visited set.
    fn validateFunctionDefParentChain(start: *function_def_mod.FunctionDef) error{InvalidBytecode}!void {
        var slow: ?*function_def_mod.FunctionDef = start;
        var fast: ?*function_def_mod.FunctionDef = start;
        while (true) {
            slow = if (slow) |node| node.parent else return;
            fast = if (fast) |node| node.parent else return;
            fast = if (fast) |node| node.parent else return;
            if (slow == fast) return error.InvalidBytecode;
        }
    }

    const ScopeLinkProof = enum(u2) {
        none,
        current,
        tree,
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
        /// Advanced only by structural validation, never by mutable FunctionDef
        /// lifecycle state.  Current-scope lookup needs `.current`; the first
        /// actual parent miss upgrades it to `.tree` before ancestor links are
        /// consumed.
        scope_link_proof: ScopeLinkProof = .none,
        /// Immutable sizing/write-pass accelerator built only after topology
        /// analysis has appended every demand-created local. The linked scope
        /// chain remains authoritative for outer-scope, with, and argument-
        /// environment ordering.
        exact_scope_bindings: ExactScopeBindingIndex = .empty,
        exact_scope_binding_var_count: ?usize = null,
        exact_scope_binding_scope_count: ?usize = null,
        exact_scope_binding_topology_fingerprint: ?u64 = null,

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

        /// Establish the no-allocation topology proof consumed by the V2-only
        /// resolver specialization.  The current FunctionDef is always proven
        /// at `run` entry. Ancestors are proven lazily on the first real parent
        /// miss, keeping all callers fail closed without charging functions
        /// whose bindings are entirely local.
        pub fn proveScopeLinksForResolution(self: *JSContext) Error!void {
            self.scope_link_proof = .none;
            const fd = self.function_def orelse return error.NoFunctionDef;
            fd.validateFinalScopeLinks() catch return error.InvalidBytecode;
            self.scope_link_proof = .current;
        }

        fn proveParentScopeLinksForResolution(self: *JSContext) Error!void {
            if (self.scope_link_proof == .tree) return;
            if (self.scope_link_proof != .current) return error.InvalidBytecode;
            const fd = self.function_def orelse return error.NoFunctionDef;
            try validateFunctionDefParentChain(fd);
            var maybe_parent = fd.parent;
            while (maybe_parent) |parent| {
                parent.validateFinalScopeLinks() catch return error.InvalidBytecode;
                maybe_parent = parent.parent;
            }
            self.scope_link_proof = .tree;
        }

        fn exactScopeBindingKey(scope_level: i32, atom_id: atom.Atom) ?u64 {
            if (scope_level < 0) return null;
            return (@as(u64, @intCast(scope_level)) << 32) | atom_id;
        }

        fn mixExactScopeTopologyFingerprint(fingerprint: *u64, value: anytype) void {
            var stable_value = value;
            fingerprint.* = std.hash.Wyhash.hash(fingerprint.*, std.mem.asBytes(&stable_value));
        }

        /// Snapshot every field which can change exact-scope lookup order.
        /// Validation runs before the lowered buffers are published, so a
        /// future post-index topology write fails closed instead of committing
        /// output produced from stale cached indices.
        fn exactScopeTopologyFingerprint(fd: *const function_def_mod.FunctionDef) u64 {
            var fingerprint: u64 = 0;
            mixExactScopeTopologyFingerprint(&fingerprint, fd.scopes.len);
            mixExactScopeTopologyFingerprint(&fingerprint, fd.vars.len);
            for (fd.scopes) |scope| {
                mixExactScopeTopologyFingerprint(&fingerprint, scope.first);
            }
            for (fd.vars) |vd| {
                mixExactScopeTopologyFingerprint(&fingerprint, vd.var_name);
                mixExactScopeTopologyFingerprint(&fingerprint, vd.scope_level);
                mixExactScopeTopologyFingerprint(&fingerprint, vd.scope_next);
            }
            return fingerprint;
        }

        fn prepareExactScopeBindingIndex(self: *JSContext) Error!void {
            const fd = self.function_def orelse return;
            if (fd.vars.len < exact_scope_binding_index_threshold) return;
            if (fd.vars.len > std.math.maxInt(u16)) return error.BytecodeOverflow;
            errdefer self.deinitExactScopeBindingIndex();
            try self.exact_scope_bindings.ensureTotalCapacity(
                self.memory.allocator,
                @intCast(fd.vars.len),
            );

            // Index only the exact-scope prefix rooted at each authoritative
            // scopes[].first chain. An inherited head belongs to an outer
            // scope, and scope-0 pseudo/function rows appended with appendVar
            // are intentionally absent from this chain. The first matching
            // row is the newest declaration and must win on duplicates.
            for (fd.scopes, 0..) |scope, scope_index| {
                var index = scope.first;
                var visited: usize = 0;
                while (index >= 0) {
                    if (@as(usize, @intCast(index)) >= fd.vars.len or visited >= fd.vars.len) {
                        return error.InvalidBytecode;
                    }
                    visited += 1;
                    const local_index: usize = @intCast(index);
                    const vd = fd.vars[local_index];
                    if (vd.scope_level != @as(i32, @intCast(scope_index))) break;
                    const key = exactScopeBindingKey(vd.scope_level, vd.var_name).?;
                    if (!self.exact_scope_bindings.contains(key)) {
                        self.exact_scope_bindings.putAssumeCapacity(key, @intCast(local_index));
                    }
                    index = vd.scope_next;
                }
            }
            self.exact_scope_binding_var_count = fd.vars.len;
            self.exact_scope_binding_scope_count = fd.scopes.len;
            self.exact_scope_binding_topology_fingerprint = exactScopeTopologyFingerprint(fd);
        }

        fn deinitExactScopeBindingIndex(self: *JSContext) void {
            self.exact_scope_bindings.deinit(self.memory.allocator);
            self.exact_scope_bindings = .empty;
            self.exact_scope_binding_var_count = null;
            self.exact_scope_binding_scope_count = null;
            self.exact_scope_binding_topology_fingerprint = null;
        }

        fn exactScopeBinding(
            self: *const JSContext,
            fd: *const function_def_mod.FunctionDef,
            atom_id: atom.Atom,
            scope_level: i32,
        ) ?u16 {
            const indexed_var_count = self.exact_scope_binding_var_count orelse return null;
            const indexed_scope_count = self.exact_scope_binding_scope_count orelse return null;
            // A future post-topology append must never consult stale indices.
            // The caller falls back to the semantic linked-chain path and run()
            // also rejects any topology drift before publishing output.
            if (fd.vars.len != indexed_var_count or fd.scopes.len != indexed_scope_count) return null;
            if (scope_level < 0 or @as(usize, @intCast(scope_level)) >= fd.scopes.len) return null;
            const head = fd.scopes[@intCast(scope_level)].first;
            if (head < 0 or @as(usize, @intCast(head)) >= fd.vars.len) return null;
            // An empty scope inherits its parent's head. Such a scope must use
            // the full chain so nearest-binding and ARG_SCOPE_END semantics
            // remain solely defined by the existing representation.
            if (fd.vars[@intCast(head)].scope_level != scope_level) return null;
            const key = exactScopeBindingKey(scope_level, atom_id) orelse return null;
            const index = self.exact_scope_bindings.get(key) orelse return null;
            if (index >= fd.vars.len) return null;
            const vd = fd.vars[index];
            if (vd.scope_level != scope_level or vd.var_name != atom_id) return null;
            return index;
        }

        fn validateExactScopeBindingVersion(self: *const JSContext) Error!void {
            const indexed_var_count = self.exact_scope_binding_var_count orelse return;
            const indexed_scope_count = self.exact_scope_binding_scope_count orelse return error.InvalidBytecode;
            const indexed_fingerprint = self.exact_scope_binding_topology_fingerprint orelse return error.InvalidBytecode;
            const fd = self.function_def orelse return error.NoFunctionDef;
            if (fd.vars.len != indexed_var_count or
                fd.scopes.len != indexed_scope_count or
                exactScopeTopologyFingerprint(fd) != indexed_fingerprint)
            {
                return error.InvalidBytecode;
            }
        }
    };

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

    fn closureVarIsRuntimeVarRef(cv: function_def_mod.ClosureVar) bool {
        return switch (cv.closureType()) {
            // `.global` is the sole atom-only carrier. GLOBAL_REF and
            // GLOBAL_DECL both own/alias a real VarRef cell at construction;
            // whether ordinary access stays dynamic is a separate question
            // answered by closureVarSourceIsDynamicGlobal below.
            .global => false,
            .local, .arg, .ref, .global_ref, .global_decl, .module_decl, .module_import => true,
        };
    }

    fn closureVarSourceIsDynamicGlobal(fd: *const function_def_mod.FunctionDef, start_idx: usize) bool {
        var owner = fd;
        var idx = start_idx;
        var hops: usize = 0;
        while (idx < owner.closure_var.len and hops < 64) : (hops += 1) {
            const cv = owner.closure_var[idx];
            switch (cv.closureType()) {
                .global, .global_ref, .global_decl => return true,
                .ref => {
                    const parent = owner.parent orelse return false;
                    owner = parent;
                    idx = cv.var_idx;
                },
                .module_decl => return false,
                .local, .arg, .module_import => return false,
            }
        }
        return false;
    }

    fn lookupClosureVar(ctx: *const JSContext, atom_id: u32) ?u16 {
        const fd = ctx.function_def orelse return null;
        for (fd.closure_var, 0..) |cv, idx| {
            if (!closureVarIsRuntimeVarRef(cv)) continue;
            if (closureVarSourceIsDynamicGlobal(fd, idx)) continue;
            if (cv.var_name == atom_id) return @intCast(idx);
        }
        // resolveBindingTopology/get_closure_var must have installed an entry
        // in the *current* function before lowering begins.  A parent closure,
        // local, or argument index is in a different index space and can never
        // be emitted as this function's var-ref operand (quickjs.c:32736-32760,
        // 33290-33354).  The former ancestor fallback merely hid a missing
        // topology event and could address an unrelated current row.
        return null;
    }

    fn lookupGlobalClosureVar(ctx: *const JSContext, atom_id: u32) ?u16 {
        const fd = ctx.function_def orelse return null;
        for (fd.closure_var, 0..) |cv, idx| {
            if (cv.var_name != atom_id) continue;
            switch (cv.closureType()) {
                .global, .global_ref, .global_decl, .module_decl, .module_import => return @intCast(idx),
                else => {},
            }
        }
        return null;
    }

    fn addOrFindClosureSource(
        fd: *function_def_mod.FunctionDef,
        closure_type: function_def_mod.ClosureType,
        source_idx: u16,
        source: function_def_mod.ClosureVar,
    ) Error!u16 {
        for (fd.closure_var, 0..) |cv, idx| {
            // QuickJS get_closure_var identity is exactly
            // (closure_type,var_idx); the atom is lookup metadata only.
            if (cv.closureType() != closure_type or cv.var_idx != source_idx) continue;
            return @intCast(idx);
        }
        const idx = try fd.addClosureVar(.{
            .closure_type = closure_type,
            .is_lexical = source.isLexical(),
            .is_const = source.isConst(),
            .var_kind = source.varKind(),
            .var_idx = source_idx,
            .var_name = source.var_name,
        });
        if (idx < 0 or idx > std.math.maxInt(u16)) return error.InvalidBytecode;
        return @intCast(idx);
    }

    /// QuickJS get_closure_var recursion for a source already owned by an
    /// ancestor. Each intermediate function receives one identity-deduped
    /// row pointing at its direct parent; global sources retain GLOBAL_REF.
    fn threadClosureSource(
        target: *function_def_mod.FunctionDef,
        source_owner: *function_def_mod.FunctionDef,
        source_idx: u16,
        source: function_def_mod.ClosureVar,
        source_type: function_def_mod.ClosureType,
    ) Error!u16 {
        const parent = target.parent orelse return error.NoParentScope;
        const direct_source = parent == source_owner;
        const parent_idx = if (direct_source)
            source_idx
        else
            try threadClosureSource(parent, source_owner, source_idx, source, source_type);
        const target_type: function_def_mod.ClosureType = if (direct_source)
            source_type
        else if (source_type == .global_ref)
            .global_ref
        else
            .ref;
        switch (target_type) {
            .local, .arg, .ref, .global_ref => {},
            .global, .global_decl, .module_decl, .module_import => return error.InvalidBytecode,
        }
        return addOrFindClosureSource(target, target_type, parent_idx, source);
    }

    fn ensureGlobalClosureVar(ctx: *JSContext, atom_id: u32) Error!u16 {
        if (lookupGlobalClosureVar(ctx, atom_id)) |idx| return idx;
        const fd = ctx.function_def orelse return error.NoFunctionDef;

        // resolve_scope_var creates an unresolved ordinary-global carrier in
        // the eval root, even when the first demand comes from a descendant;
        // get_closure_var then threads GLOBAL_REF rows back down. This makes
        // every function share one root identity and, because children are
        // finalized first, preserves child-demand-before-parent-demand order.
        var root = fd;
        while (!root.is_eval) root = root.parent orelse break;

        var root_idx: ?u16 = null;
        for (root.closure_var, 0..) |cv, idx| {
            if (cv.var_name != atom_id) continue;
            switch (cv.closureType()) {
                .global, .global_ref, .global_decl => {
                    root_idx = @intCast(idx);
                    break;
                },
                else => {},
            }
        }
        if (root_idx == null) {
            const idx = try root.addClosureVar(.{
                .closure_type = .global,
                .is_lexical = false,
                .is_const = false,
                .var_kind = .normal,
                .var_idx = 0,
                .var_name = atom_id,
            });
            if (idx < 0 or idx > std.math.maxInt(u16)) return error.InvalidBytecode;
            root_idx = @intCast(idx);
        }

        if (root == fd) return root_idx.?;
        const source = root.closure_var[root_idx.?];
        return threadClosureSource(fd, root, root_idx.?, source, .global_ref);
    }

    fn emitGlobalVarOp(ctx: *JSContext, output: []u8, out_idx: *usize, op_id: u8, atom_id: u32) Error!void {
        if (out_idx.* + 3 > output.len) return error.InvalidBytecode;
        const ref_idx = lookupGlobalClosureVar(ctx, atom_id) orelse return error.ClosureVarNotFound;
        output[out_idx.*] = op_id;
        std.mem.writeInt(u16, output[out_idx.* + 1 ..][0..2], ref_idx, .little);
        out_idx.* += 3;
    }

    fn lookupTopLevelModuleLexicalClosureVar(ctx: *const JSContext, atom_id: u32, scope_level: i32) ?u16 {
        if (scope_level != 0) return null;
        const fd = ctx.function_def orelse return null;
        for (fd.closure_var, 0..) |cv, idx| {
            if (cv.var_name == atom_id and (cv.closureType() == .module_decl or cv.closureType() == .global_decl) and cv.isLexical()) return @intCast(idx);
        }
        return null;
    }

    fn preferTopLevelModuleClassBinding(ctx: *const JSContext, atom_id: u32, loc_idx: u16) ?u16 {
        const fd = ctx.function_def orelse return null;
        if (loc_idx >= fd.vars.len) return null;
        const vd = fd.vars[loc_idx];
        if (vd.var_name != atom_id or vd.scope_level != 0 or !vd.is_lexical or !vd.is_const) return null;
        for (fd.closure_var, 0..) |cv, idx| {
            if (cv.var_name == atom_id and cv.closureType() == .module_decl and cv.isLexical() and !cv.isConst()) return @intCast(idx);
        }
        return null;
    }

    fn closureVarKind(ctx: *const JSContext, idx: u16) function_def_mod.VarKind {
        const fd = ctx.function_def orelse return .normal;
        if (idx >= fd.closure_var.len) return .normal;
        return fd.closure_var[idx].varKind();
    }

    /// qjs resolve_scope_var `has_idx` (quickjs.c:33301-33306): a write
    /// (`OP_scope_put_var`) or reference capture (`OP_scope_make_ref`) that
    /// resolves to a const closure variable compiles to
    /// `OP_throw_error <name> JS_THROW_VAR_RO` instead of a store. The global
    /// families are exempt — qjs routes them to `has_global_idx`
    /// (quickjs.c:33251) which has no such check; global const writes stay on
    /// the runtime global-lexical-cell path (TDZ ReferenceError precedence,
    /// OP_put_var quickjs.c:18490-18525).
    ///
    /// This compile-time throw is what makes module import bindings read-only:
    /// imports register `is_const` at parse time (add_import quickjs.c:31882)
    /// and their frame slot is a direct alias of the exporting module's cell
    /// (js_inner_module_linking quickjs.c:30765-30777) — the shared cell
    /// itself carries no const flag, so the write must never reach it.
    fn closureVarWriteThrowsReadOnly(ctx: *const JSContext, ref_idx: u16) bool {
        const fd = ctx.function_def orelse return false;
        if (ref_idx >= fd.closure_var.len) return false;
        return closureVarConstWriteThrows(fd, ref_idx);
    }

    fn closureVarConstWriteThrows(start_fd: *const function_def_mod.FunctionDef, start_idx: u16) bool {
        var fd = start_fd;
        var cv = fd.closure_var[start_idx];
        if (!cv.isConst()) return false;
        // Follow the capture chain to its base closure var. The finalized
        // resolver threads local/module sources through descendants as plain
        // `.ref` rows, while eval-root GLOBAL families are re-derived as
        // `.global_ref`, matching resolve_scope_var (quickjs.c:33196-33206).
        // Const-write treatment is therefore decided by the base identity,
        // not by the immediate forwarding row alone.
        var hops: usize = 0;
        while ((cv.closureType() == .ref or cv.closureType() == .global_ref) and hops < 64) : (hops += 1) {
            const parent = fd.parent orelse break;
            if (cv.var_idx >= parent.closure_var.len) break;
            fd = parent;
            cv = parent.closure_var[cv.var_idx];
        }
        return switch (cv.closureType()) {
            .global, .global_decl, .global_ref => false,
            .local, .arg, .ref, .module_decl, .module_import => true,
        };
    }

    /// `OP_throw_error <atom:u32> <type:u8>` — 6 bytes, one atom operand.
    const throw_error_instr_size: usize = 6;
    const JS_THROW_VAR_RO: u8 = 0; // quickjs.c:18334
    const JS_THROW_VAR_REDECL: u8 = 1; // quickjs.c:18335
    fn writeThrowVarReadOnly(func: *bytecode_function.Bytecode, output: []u8, out_idx: *usize, output_atoms: []atom.Atom, out_atom_idx: *usize, atom_id: u32) void {
        writeThrowVarError(func, output, out_idx, output_atoms, out_atom_idx, atom_id, JS_THROW_VAR_RO);
    }

    fn writeThrowVarError(
        func: *bytecode_function.Bytecode,
        output: []u8,
        out_idx: *usize,
        output_atoms: []atom.Atom,
        out_atom_idx: *usize,
        atom_id: u32,
        error_type: u8,
    ) void {
        output[out_idx.*] = opcode.op.throw_error;
        std.mem.writeInt(u32, output[out_idx.* + 1 ..][0..4], atom_id, .little);
        output[out_idx.* + 5] = error_type;
        output_atoms[out_atom_idx.*] = func.atoms.dup(atom_id);
        out_idx.* += throw_error_instr_size;
        out_atom_idx.* += 1;
    }

    fn writeThrowVarRedeclaration(func: *bytecode_function.Bytecode, output: []u8, out_idx: *usize, output_atoms: []atom.Atom, out_atom_idx: *usize, atom_id: u32) void {
        output[out_idx.*] = opcode.op.throw_error;
        std.mem.writeInt(u32, output[out_idx.* + 1 ..][0..4], atom_id, .little);
        output[out_idx.* + 5] = JS_THROW_VAR_REDECL;
        output_atoms[out_atom_idx.*] = func.atoms.dup(atom_id);
        out_idx.* += throw_error_instr_size;
        out_atom_idx.* += 1;
    }

    fn lowerScopeVarOpForClosure(ctx: *const JSContext, atom_id: u32, ref_idx: u16, op_id: u8) u8 {
        var ref_op = lowerScopeVarOpClosure(op_id);
        const fd = ctx.function_def orelse return ref_op;
        if (ref_idx >= fd.closure_var.len) return ref_op;
        const resolved = fd.closure_var[ref_idx];
        // QuickJS resolve_scope_var keeps BindThisValue's initialize-once
        // guard after `this` has escaped into a closure (quickjs.c:33355-33364).
        // The parser intentionally carries only name+scope here; choose the
        // checked final opcode now that this function's exact ref index exists.
        if (op_id == opcode.op.scope_put_var_init and atom_id == atom.ids.this_) {
            ref_op = opcode.op.put_var_ref_check_init;
        }
        // qjs has_idx reads s->closure_var[idx] directly after get_closure_var
        // selected that exact identity (quickjs.c:33301-33364).  Do not search
        // the same atom through the current and parent functions again: two
        // same-name closure rows may have different lexical metadata, and the
        // resolved ref_idx is the authoritative row.
        if ((op_id == opcode.op.scope_get_var or op_id == opcode.op.scope_get_var_undef) and
            (resolved.varKind() == .function_decl or !resolved.isLexical()))
        {
            ref_op = opcode.op.get_var_ref;
        }
        if (op_id == opcode.op.scope_put_var and !resolved.isLexical()) {
            ref_op = opcode.op.put_var_ref;
        }
        return ref_op;
    }

    test "resolved closure identity owns lexical opcode selection" {
        const runtime_mod = @import("core/runtime.zig");
        const rt = try runtime_mod.JSRuntime.create(std.testing.allocator);
        defer rt.destroy();

        const name = try rt.internAtom("resolved-closure-opcode-selection");
        defer rt.atoms.free(name);
        const binding = try rt.internAtom("same-name-closure");
        defer rt.atoms.free(binding);

        var fd = function_def_mod.FunctionDef.init(&rt.memory, &rt.atoms, name);
        defer fd.deinit(rt);
        _ = try fd.addClosureVar(.{
            .closure_type = .local,
            .is_lexical = false,
            .is_const = false,
            .var_kind = .normal,
            .var_idx = 0,
            .var_name = binding,
        });
        const lexical_idx = try fd.addClosureVar(.{
            .closure_type = .local,
            .is_lexical = true,
            .is_const = false,
            .var_kind = .normal,
            .var_idx = 1,
            .var_name = binding,
        });

        var bc = bytecode_function.Bytecode.init(&rt.memory, &rt.atoms, name);
        defer bc.deinit(rt);
        const ctx = JSContext.initWithFunctionDef(&bc, &fd);
        try std.testing.expectEqual(
            opcode.op.get_var_ref_check,
            lowerScopeVarOpForClosure(&ctx, binding, @intCast(lexical_idx), opcode.op.scope_get_var),
        );
        try std.testing.expectEqual(
            opcode.op.get_var_ref_check,
            lowerScopeVarOpForClosure(&ctx, binding, @intCast(lexical_idx), opcode.op.scope_get_var_undef),
        );
        try std.testing.expectEqual(
            opcode.op.get_var_ref,
            lowerScopeVarOpForClosure(&ctx, binding, 0, opcode.op.scope_get_var_undef),
        );
        try std.testing.expectEqual(
            opcode.op.put_var_ref_check,
            lowerScopeVarOpForClosure(&ctx, binding, @intCast(lexical_idx), opcode.op.scope_put_var),
        );
    }

    const PrivateFieldResolution = struct {
        idx: u16,
        is_ref: bool,
        var_kind: function_def_mod.VarKind,
    };

    fn resolvePrivateField(ctx: *const JSContext, atom_id: u32, scope_level: i32) ?PrivateFieldResolution {
        const fd = ctx.function_def orelse return null;

        if (scope_level >= 0 and @as(usize, @intCast(scope_level)) < fd.scopes.len) {
            var idx = fd.scopes[@intCast(scope_level)].first;
            var visited: usize = 0;
            while (idx >= 0) {
                if (@as(usize, @intCast(idx)) >= fd.vars.len or visited >= fd.vars.len) return null;
                visited += 1;
                const vd = fd.vars[@intCast(idx)];
                if (vd.var_name == atom_id and isPrivateVarKind(vd.var_kind)) {
                    return .{ .idx = @intCast(idx), .is_ref = false, .var_kind = vd.var_kind };
                }
                idx = vd.scope_next;
            }
        }

        for (fd.closure_var, 0..) |cv, idx| {
            if (cv.var_name == atom_id and isPrivateVarKind(cv.varKind())) {
                return .{ .idx = @intCast(idx), .is_ref = true, .var_kind = cv.varKind() };
            }
        }

        return null;
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

    fn isPrivateSetterCompanionName(ctx: *const JSContext, private_atom: atom.Atom, candidate_atom: atom.Atom) bool {
        const private_name = ctx.atoms.name(private_atom) orelse return false;
        const candidate_name = ctx.atoms.name(candidate_atom) orelse return false;
        const suffix = "<set>";
        return candidate_name.len == private_name.len + suffix.len and
            std.mem.eql(u8, candidate_name[0..private_name.len], private_name) and
            std.mem.eql(u8, candidate_name[private_name.len..], suffix);
    }

    fn resolvePrivateSetter(ctx: *const JSContext, atom_id: atom.Atom, scope_level: i32) ?PrivateFieldResolution {
        const fd = ctx.function_def orelse return null;

        if (scope_level >= 0 and @as(usize, @intCast(scope_level)) < fd.scopes.len) {
            var idx = fd.scopes[@intCast(scope_level)].first;
            var visited: usize = 0;
            while (idx >= 0) {
                if (@as(usize, @intCast(idx)) >= fd.vars.len or visited >= fd.vars.len) return null;
                visited += 1;
                const vd = fd.vars[@intCast(idx)];
                if (vd.var_kind == .private_setter and isPrivateSetterCompanionName(ctx, atom_id, vd.var_name)) {
                    return .{ .idx = @intCast(idx), .is_ref = false, .var_kind = vd.var_kind };
                }
                idx = vd.scope_next;
            }
        }

        for (fd.closure_var, 0..) |cv, idx| {
            if (cv.varKind() == .private_setter and isPrivateSetterCompanionName(ctx, atom_id, cv.var_name)) {
                return .{ .idx = @intCast(idx), .is_ref = true, .var_kind = cv.varKind() };
            }
        }
        return null;
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

    fn loweredPrivateFieldSize(ctx: *const JSContext, op_id: u8, atom_id: atom.Atom, scope_level: i32, res: PrivateFieldResolution) !usize {
        const accessor_size = privateAccessorSize(ctx, res);
        return switch (op_id) {
            opcode.op.scope_get_private_field, opcode.op.scope_get_private_field2 => switch (res.var_kind) {
                .private_field => accessor_size + 1 + @as(usize, @intFromBool(op_id == opcode.op.scope_get_private_field2)),
                .private_method => accessor_size + 1 + @as(usize, @intFromBool(op_id == opcode.op.scope_get_private_field)),
                .private_getter, .private_getter_setter => accessor_size + 4 + @as(usize, @intFromBool(op_id == opcode.op.scope_get_private_field2)),
                .private_setter => throw_error_instr_size,
                else => return error.ClosureVarNotFound,
            },
            opcode.op.scope_put_private_field => switch (res.var_kind) {
                .private_field => accessor_size + 1,
                .private_method, .private_getter => throw_error_instr_size,
                .private_setter, .private_getter_setter => blk: {
                    const setter = resolvePrivateSetter(ctx, atom_id, scope_level) orelse return error.ClosureVarNotFound;
                    break :blk privateAccessorSize(ctx, setter) + 9;
                },
                else => return error.ClosureVarNotFound,
            },
            opcode.op.scope_in_private_field => accessor_size + 1,
            else => unreachable,
        };
    }

    fn loweredPrivateFieldAtomCount(op_id: u8, res: PrivateFieldResolution) usize {
        return switch (op_id) {
            opcode.op.scope_get_private_field, opcode.op.scope_get_private_field2 => @intFromBool(res.var_kind == .private_setter),
            opcode.op.scope_put_private_field => @intFromBool(res.var_kind == .private_method or res.var_kind == .private_getter),
            opcode.op.scope_in_private_field => 0,
            else => unreachable,
        };
    }

    fn writePrivateCallMethodZero(output: []u8, out_idx: *usize) void {
        output[out_idx.*] = opcode.op.call_method;
        std.mem.writeInt(u16, output[out_idx.* + 1 ..][0..2], 0, .little);
        out_idx.* += 3;
    }

    fn writeLoweredPrivateField(
        ctx: *const JSContext,
        output: []u8,
        out_idx: *usize,
        output_atoms: []atom.Atom,
        out_atom_idx: *usize,
        op_id: u8,
        atom_id: atom.Atom,
        scope_level: i32,
        res: PrivateFieldResolution,
    ) !void {
        switch (op_id) {
            opcode.op.scope_get_private_field, opcode.op.scope_get_private_field2 => switch (res.var_kind) {
                .private_field => {
                    if (op_id == opcode.op.scope_get_private_field2) {
                        output[out_idx.*] = opcode.op.dup;
                        out_idx.* += 1;
                    }
                    writePrivateAccessor(ctx, output, out_idx, res);
                    output[out_idx.*] = opcode.op.get_private_field;
                    out_idx.* += 1;
                },
                .private_method => {
                    writePrivateAccessor(ctx, output, out_idx, res);
                    output[out_idx.*] = opcode.op.check_brand;
                    out_idx.* += 1;
                    if (op_id == opcode.op.scope_get_private_field) {
                        output[out_idx.*] = opcode.op.nip;
                        out_idx.* += 1;
                    }
                },
                .private_getter, .private_getter_setter => {
                    if (op_id == opcode.op.scope_get_private_field2) {
                        output[out_idx.*] = opcode.op.dup;
                        out_idx.* += 1;
                    }
                    writePrivateAccessor(ctx, output, out_idx, res);
                    output[out_idx.*] = opcode.op.check_brand;
                    out_idx.* += 1;
                    writePrivateCallMethodZero(output, out_idx);
                },
                .private_setter => writeThrowVarReadOnly(ctx.function, output, out_idx, output_atoms, out_atom_idx, atom_id),
                else => return error.ClosureVarNotFound,
            },
            opcode.op.scope_put_private_field => switch (res.var_kind) {
                .private_field => {
                    writePrivateAccessor(ctx, output, out_idx, res);
                    output[out_idx.*] = opcode.op.put_private_field;
                    out_idx.* += 1;
                },
                .private_method, .private_getter => writeThrowVarReadOnly(ctx.function, output, out_idx, output_atoms, out_atom_idx, atom_id),
                .private_setter, .private_getter_setter => {
                    const setter = resolvePrivateSetter(ctx, atom_id, scope_level) orelse return error.ClosureVarNotFound;
                    writePrivateAccessor(ctx, output, out_idx, setter);
                    output[out_idx.*] = opcode.op.swap;
                    out_idx.* += 1;
                    output[out_idx.*] = opcode.op.using;
                    output[out_idx.* + 1] = opcode.using_sub.rot3r;
                    out_idx.* += 2;
                    output[out_idx.*] = opcode.op.check_brand;
                    out_idx.* += 1;
                    output[out_idx.*] = opcode.op.rot3l;
                    out_idx.* += 1;
                    output[out_idx.*] = opcode.op.call_method;
                    std.mem.writeInt(u16, output[out_idx.* + 1 ..][0..2], 1, .little);
                    out_idx.* += 3;
                    output[out_idx.*] = opcode.op.drop;
                    out_idx.* += 1;
                },
                else => return error.ClosureVarNotFound,
            },
            opcode.op.scope_in_private_field => {
                writePrivateAccessor(ctx, output, out_idx, res);
                output[out_idx.*] = opcode.op.private_in;
                out_idx.* += 1;
            },
            else => unreachable,
        }
    }

    /// Ordinary lexical vars get their TDZ bit re-armed on scope entry.
    /// Function declarations take the other QuickJS OP_enter_scope arm and
    /// are initialized from their VarDef.func_pool_idx instead.
    fn varNeedsTdzRearm(vd: function_def_mod.VarDef) bool {
        return vd.is_lexical and (vd.var_kind == .normal or isPrivateVarKind(vd.var_kind));
    }

    fn varNeedsScopeFunctionInit(vd: function_def_mod.VarDef) bool {
        return vd.is_lexical and vd.func_pool_idx >= 0 and
            (vd.var_kind == .function_decl or vd.var_kind == .new_function_decl);
    }

    /// Byte size of the `enter_scope <scope>` lowering. Mirrors the QuickJS
    /// `OP_enter_scope` case (quickjs.c:34398): initialize only the bindings
    /// declared by this exact scope. Captured cells are detached exclusively
    /// by the corresponding leave marker.
    fn enterScopeRefreshSize(ctx: *const JSContext, scope: i32) Error!usize {
        const fd = ctx.function_def orelse return 0;
        if (scope < 0 or @as(usize, @intCast(scope)) >= fd.scopes.len) return 0;
        var total: usize = 0;
        var idx = fd.scopes[@intCast(scope)].first;
        while (idx >= 0 and @as(usize, @intCast(idx)) < fd.vars.len) {
            const vd = fd.vars[@intCast(idx)];
            if (vd.scope_level != scope) break;
            if (idx != fd.arguments_arg_idx) {
                if (varNeedsScopeFunctionInit(vd)) {
                    total += try fclosureEncodingSize(vd.func_pool_idx) +
                        selectLocForm(ctx, opcode.op.put_loc, @intCast(idx)).size;
                } else if (varNeedsTdzRearm(vd)) {
                    total += 3;
                }
            }
            idx = vd.scope_next;
        }
        return total;
    }

    /// Emit the `enter_scope` lowering described in `enterScopeRefreshSize`.
    fn writeEnterScopeRefresh(ctx: *const JSContext, output: []u8, out_idx: *usize, scope: i32) Error!void {
        const fd = ctx.function_def orelse return;
        if (scope < 0 or @as(usize, @intCast(scope)) >= fd.scopes.len) return;

        var idx = fd.scopes[@intCast(scope)].first;
        while (idx >= 0 and @as(usize, @intCast(idx)) < fd.vars.len) {
            const vd = fd.vars[@intCast(idx)];
            if (vd.scope_level != scope) break;
            const loc_idx: u16 = @intCast(idx);
            if (idx != fd.arguments_arg_idx) {
                if (varNeedsScopeFunctionInit(vd)) {
                    try emitFClosure(output, out_idx, vd.func_pool_idx);
                    writeSelectedLocForm(output, out_idx, selectLocForm(ctx, opcode.op.put_loc, loc_idx), loc_idx);
                } else if (varNeedsTdzRearm(vd)) {
                    output[out_idx.*] = opcode.op.set_loc_uninitialized;
                    std.mem.writeInt(u16, output[out_idx.* + 1 ..][0..2], loc_idx, .little);
                    out_idx.* += 3;
                }
            }
            idx = vd.scope_next;
        }
    }

    /// Byte size of QuickJS `OP_leave_scope` lowering: detach each captured
    /// local declared by exactly this scope. The inherited tail belongs to
    /// enclosing scopes and must not be closed here.
    fn leaveScopeCloseSize(ctx: *const JSContext, scope: i32) usize {
        const fd = ctx.function_def orelse return 0;
        if (scope < 0 or @as(usize, @intCast(scope)) >= fd.scopes.len) return 0;
        var total: usize = 0;
        var idx = fd.scopes[@intCast(scope)].first;
        while (idx >= 0 and @as(usize, @intCast(idx)) < fd.vars.len) {
            const vd = fd.vars[@intCast(idx)];
            if (vd.scope_level != scope) break;
            if (vd.is_captured) total += 3;
            idx = vd.scope_next;
        }
        return total;
    }

    fn writeLeaveScopeClose(ctx: *const JSContext, output: []u8, out_idx: *usize, scope: i32) void {
        const fd = ctx.function_def orelse return;
        if (scope < 0 or @as(usize, @intCast(scope)) >= fd.scopes.len) return;
        var idx = fd.scopes[@intCast(scope)].first;
        while (idx >= 0 and @as(usize, @intCast(idx)) < fd.vars.len) {
            const vd = fd.vars[@intCast(idx)];
            if (vd.scope_level != scope) break;
            const loc_idx: u16 = @intCast(idx);
            if (vd.is_captured) {
                output[out_idx.*] = opcode.op.close_loc;
                std.mem.writeInt(u16, output[out_idx.* + 1 ..][0..2], loc_idx, .little);
                out_idx.* += 3;
            }
            idx = vd.scope_next;
        }
    }

    fn lowerScopeVarOpClosure(op_id: u8) u8 {
        return switch (op_id) {
            // qjs 33352-33376: `scope_get_var` and `scope_get_var_undef`
            // share the lexical → `get_var_ref_check` rewrite. `typeof`
            // of an uninitialized import/let must still throw TDZ.
            opcode.op.scope_get_var, opcode.op.scope_get_var_checkthis, opcode.op.scope_get_var_undef => opcode.op.get_var_ref_check,
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

    /// QuickJS checks the named function-expression binding after the current
    /// scope/var/argument lookup, including while the argument scope is active
    /// (resolve_scope_var quickjs.c:32975-32978). That scope deliberately does
    /// not link to the body scope, so the ordinary scope walk cannot find the
    /// lazily materialized function-name slot for a default initializer.
    fn lookupCurrentFunctionName(ctx: *const JSContext, atom_id: u32) ?u16 {
        const fd = ctx.function_def orelse return null;
        if (fd.func_var_idx < 0) return null;
        const idx: usize = @intCast(fd.func_var_idx);
        if (idx >= fd.vars.len) return null;
        const vd = fd.vars[idx];
        if (vd.var_name != atom_id or vd.var_kind != .function_name) return null;
        return @intCast(idx);
    }

    fn lookupCurrentPseudoBinding(ctx: *const JSContext, atom_id: atom.Atom) ?u16 {
        const fd = ctx.function_def orelse return null;
        if (!fd.has_this_binding) return null;
        const idx_i32 = if (atom_id == atom.ids.home_object)
            fd.home_object_var_idx
        else if (atom_id == atom.ids.this_active_func)
            fd.this_active_func_var_idx
        else if (atom_id == atom.ids.new_target)
            fd.new_target_var_idx
        else if (atom_id == atom.ids.this_)
            fd.this_var_idx
        else
            return null;
        if (idx_i32 < 0 or @as(usize, @intCast(idx_i32)) >= fd.vars.len) return null;
        const idx: u16 = @intCast(idx_i32);
        if (fd.vars[idx].var_name != atom_id) return null;
        return idx;
    }

    fn lowerScopeVarOpArg(op_id: u8) ?u8 {
        return switch (op_id) {
            opcode.op.scope_get_var, opcode.op.scope_get_var_undef, opcode.op.scope_get_var_checkthis => opcode.op.get_arg,
            opcode.op.scope_put_var, opcode.op.scope_put_var_init => opcode.op.put_arg,
            else => null,
        };
    }

    /// Resolve the local half of QuickJS `resolve_scope_var`: walk the one
    /// destructively rebuilt `first/scope_next` chain, then (unless it ends at
    /// ARG_SCOPE_END) run newest-first `find_var` over scope-0 rows. Scope 1 is
    /// deliberately not made to inherit scope 0 by `js_create_function`.
    const ScopeVarLookup = struct {
        local: ?u16 = null,
        argument_environment_only: bool = false,
    };

    /// Preserve the terminal scope-chain sentinel together with the binding.
    /// QuickJS keeps `idx` from the one linked walk and tests ARG_SCOPE_END
    /// directly; losing it here used to make V2 walk the same chain again on
    /// every miss merely to decide whether formal arguments are visible.
    inline fn resolveScopeVarLookupImpl(
        comptime use_exact_scope_index: bool,
        comptime trust_final_scope_links: bool,
        ctx: *const JSContext,
        atom_id: u32,
        scope_level: i32,
    ) ScopeVarLookup {
        const fd = ctx.function_def orelse return .{};
        if (scope_level < 0 or @as(usize, @intCast(scope_level)) >= fd.scopes.len) return .{};
        if (comptime use_exact_scope_index) {
            if (ctx.exactScopeBinding(fd, atom_id, scope_level)) |idx| return .{ .local = idx };
        }
        if (comptime trust_final_scope_links) std.debug.assert(ctx.scope_link_proof != .none);
        var idx = fd.scopes[@intCast(scope_level)].first;
        var visited: usize = 0;
        while (idx >= 0) {
            if (comptime !trust_final_scope_links) {
                if (@as(usize, @intCast(idx)) >= fd.vars.len or visited >= fd.vars.len) return .{};
                visited += 1;
            }
            const vd = fd.vars[@intCast(idx)];
            if (vd.var_name == atom_id) return .{ .local = @intCast(idx) };
            idx = vd.scope_next;
        }
        if (idx == function_bytecode.arg_scope_end) {
            return .{ .argument_environment_only = true };
        }
        var flat_i: usize = fd.vars.len;
        while (flat_i > 0) {
            flat_i -= 1;
            const vd = &fd.vars[flat_i];
            if (vd.var_name == atom_id and vd.scope_level == 0) {
                return .{ .local = @intCast(flat_i) };
            }
        }
        return .{};
    }

    inline fn resolveScopeVarImpl(
        comptime use_exact_scope_index: bool,
        comptime trust_final_scope_links: bool,
        ctx: *const JSContext,
        atom_id: u32,
        scope_level: i32,
    ) ?u16 {
        return resolveScopeVarLookupImpl(
            use_exact_scope_index,
            trust_final_scope_links,
            ctx,
            atom_id,
            scope_level,
        ).local;
    }

    inline fn resolveScopeVar(ctx: *const JSContext, atom_id: u32, scope_level: i32) ?u16 {
        return resolveScopeVarImpl(true, false, ctx, atom_id, scope_level);
    }

    const LocalOrArg = union(enum) {
        local: u16,
        arg: u16,
    };

    /// Final identity selected by QuickJS's `resolve_scope_var` walk.  Keeping
    /// this four-way result lets compiler-v2 carry the binding discovered by
    /// topology directly into opcode selection instead of searching the same
    /// local/closure chains again for every scope opcode.
    const ScopeVarBinding = union(enum) {
        local: u16,
        arg: u16,
        closure: u16,
        global: u16,
    };

    inline fn resolveLocalOrArgImpl(
        comptime use_exact_scope_index: bool,
        comptime trust_final_scope_links: bool,
        ctx: *const JSContext,
        atom_id: u32,
        scope_level: i32,
    ) ?LocalOrArg {
        const fd = ctx.function_def orelse return null;
        const lookup = resolveScopeVarLookupImpl(
            use_exact_scope_index,
            trust_final_scope_links,
            ctx,
            atom_id,
            scope_level,
        );
        if (lookup.local) |idx| return .{ .local = idx };

        // ARG_SCOPE_END suppresses the ordinary find_var pass (which includes
        // formal arguments), but pseudo bindings remain visible. This ordering
        // is the local half of qjs resolve_scope_var.
        if (!lookup.argument_environment_only) {
            if (lookupArg(ctx, atom_id)) |arg_idx| return .{ .arg = arg_idx };
        }
        if (lookupCurrentPseudoBinding(ctx, atom_id)) |idx| return .{ .local = idx };
        if (atom_id == atom.ids.arguments and fd.arguments_var_idx >= 0) {
            return .{ .local = @intCast(fd.arguments_var_idx) };
        }
        if (lookupCurrentFunctionName(ctx, atom_id)) |idx| return .{ .local = idx };
        return null;
    }

    inline fn resolveLocalOrArg(ctx: *const JSContext, atom_id: u32, scope_level: i32) ?LocalOrArg {
        return resolveLocalOrArgImpl(true, false, ctx, atom_id, scope_level);
    }

    const EvalVarObjectProbe = union(enum) {
        local: u16,
        ref: u16,
        with_local: u16,
        with_ref: u16,
    };

    fn isEvalVarObjectAtom(atom_id: atom.Atom) bool {
        return atom_id == atom.ids.arg_var_object or atom_id == atom_var_object;
    }

    fn isDynamicEnvObjectAtom(atom_id: atom.Atom) bool {
        return isEvalVarObjectAtom(atom_id) or atom_id == atom.ids.with_object;
    }

    fn closureVarRangeHasDynamicEnvObjects(
        fd: *const function_def_mod.FunctionDef,
        start: usize,
    ) bool {
        // A stale cursor must fail closed: callers use false only as proof that
        // the second, V2-specific probe walk can be skipped.
        if (start > fd.closure_var.len) return true;
        for (fd.closure_var[start..]) |cv| {
            if (closureVarIsRuntimeVarRef(cv) and isDynamicEnvObjectAtom(cv.var_name)) return true;
        }
        return false;
    }

    fn functionHasDynamicEnvObjects(ctx: *const JSContext) bool {
        const fd = ctx.function_def orelse return false;
        if (fd.var_object_idx >= 0 or fd.arg_var_object_idx >= 0) return true;
        for (fd.vars) |vd| {
            if (vd.var_name == atom.ids.with_object) return true;
        }
        return closureVarRangeHasDynamicEnvObjects(fd, 0);
    }

    fn scopeUsesArgumentEnvironmentOnly(fd: *const function_def_mod.FunctionDef, scope_level: i32) bool {
        if (!fd.has_parameter_expressions or scope_level < 0 or
            @as(usize, @intCast(scope_level)) >= fd.scopes.len) return false;
        var idx = fd.scopes[@intCast(scope_level)].first;
        var visited: usize = 0;
        while (idx >= 0) {
            if (@as(usize, @intCast(idx)) >= fd.vars.len or visited >= fd.vars.len) return false;
            visited += 1;
            idx = fd.vars[@intCast(idx)].scope_next;
        }
        return idx == function_bytecode.arg_scope_end;
    }

    const ClosureDynamicEnvProbeIterator = struct {
        fd: ?*const function_def_mod.FunctionDef,
        stop_idx: usize,
        next_idx: usize = 0,

        fn init(ctx: *const JSContext, atom_id: atom.Atom) ClosureDynamicEnvProbeIterator {
            const fd = ctx.function_def orelse return .{
                .fd = null,
                .stop_idx = 0,
            };
            var stop_idx = fd.closure_var.len;
            for (fd.closure_var, 0..) |cv, idx| {
                // A catch binding is only visible while its catch block is
                // active, and global-family rows are the fallback after the
                // dynamic environment objects. Neither row terminates the
                // var-object probe chain for a reference outside that static
                // binding. Lexical/local/argument rows still stop it.
                const stops_probe = !isDynamicEnvObjectAtom(cv.var_name) and
                    cv.var_name == atom_id and
                    cv.varKind() != .catch_ and
                    !closureVarIsGlobalFamily(cv);
                if (stops_probe) {
                    stop_idx = idx;
                    break;
                }
            }
            return .{
                .fd = fd,
                .stop_idx = stop_idx,
            };
        }

        fn next(self: *ClosureDynamicEnvProbeIterator) ?usize {
            const fd = self.fd orelse return null;
            while (self.next_idx < self.stop_idx) {
                const idx = self.next_idx;
                self.next_idx += 1;
                const cv = fd.closure_var[idx];
                if (!closureVarIsRuntimeVarRef(cv) or !isDynamicEnvObjectAtom(cv.var_name)) continue;
                return idx;
            }
            return null;
        }
    };

    const LocalWithProbeIterator = struct {
        fd: ?*const function_def_mod.FunctionDef,
        atom_id: atom.Atom,
        next_var_idx: i32,

        fn init(ctx: *const JSContext, atom_id: atom.Atom, scope_level: i32) LocalWithProbeIterator {
            const fd = ctx.function_def;
            const first = if (fd) |def|
                if (scope_level >= 0 and @as(usize, @intCast(scope_level)) < def.scopes.len)
                    def.scopes[@intCast(scope_level)].first
                else
                    -1
            else
                -1;
            return .{ .fd = fd, .atom_id = atom_id, .next_var_idx = first };
        }

        fn next(self: *LocalWithProbeIterator) ?u16 {
            const fd = self.fd orelse return null;
            var visited: usize = 0;
            while (self.next_var_idx >= 0 and visited < fd.vars.len) {
                visited += 1;
                const idx = self.next_var_idx;
                if (@as(usize, @intCast(idx)) >= fd.vars.len) return null;
                const vd = fd.vars[@intCast(idx)];
                self.next_var_idx = vd.scope_next;
                if (vd.var_name == self.atom_id) {
                    self.next_var_idx = -1;
                    return null;
                }
                if (vd.var_name == atom.ids.with_object) return @intCast(idx);
            }
            return null;
        }
    };

    fn staticBindingStopsDynamicEnvProbes(ctx: *const JSContext, atom_id: atom.Atom, scope_level: i32) bool {
        if (lookupTopLevelModuleLexicalClosureVar(ctx, atom_id, scope_level) != null) return true;
        // Direct eval receives a visible catch parameter as a closure row.
        // That row is the active lexical environment for the eval itself and
        // must win over the eval var object. Ordinary local/argument closure
        // rows remain dynamically probeable: a direct eval can insert a
        // same-named var binding that subsequent caller code observes.
        if (bytecodeFunctionIsEval(ctx)) {
            if (lookupClosureVar(ctx, atom_id)) |ref_idx| {
                if (closureVarKind(ctx, ref_idx) == .catch_) return true;
            }
        }
        const binding = resolveLocalOrArg(ctx, atom_id, scope_level) orelse return false;
        return switch (binding) {
            .arg => true,
            .local => |loc_idx| blk: {
                const fd = ctx.function_def orelse break :blk false;
                if (loc_idx >= fd.vars.len) break :blk false;
                const vd = fd.vars[loc_idx];
                if (vd.var_kind == .catch_ and !scopeContainsBinding(fd, scope_level, vd.scope_level)) {
                    break :blk false;
                }
                break :blk !isEvalNonLexicalLocal(ctx, loc_idx);
            },
        };
    }

    fn scopeVarDynamicProbeEligible(atom_id: atom.Atom, scope_level: i32) bool {
        return scope_level >= 0 and
            atom_id != atom.ids.ret and
            !isDynamicEnvObjectAtom(atom_id);
    }

    /// Binding-aware form of `staticBindingStopsDynamicEnvProbes`.  The old
    /// helper has to rediscover the local/closure identity by name; compiler-v2
    /// already owns that result from the topology walk.
    fn resolvedBindingStopsDynamicEnvProbes(
        ctx: *const JSContext,
        atom_id: atom.Atom,
        scope_level: i32,
        binding: ScopeVarBinding,
    ) bool {
        return switch (binding) {
            .arg => true,
            .local => |loc_idx| blk: {
                const fd = ctx.function_def orelse break :blk false;
                if (loc_idx >= fd.vars.len) break :blk false;
                const vd = fd.vars[loc_idx];
                if (vd.var_kind == .catch_ and
                    !scopeContainsBinding(fd, scope_level, vd.scope_level))
                {
                    break :blk false;
                }
                break :blk !isEvalNonLexicalLocal(ctx, loc_idx);
            },
            .closure => |ref_idx| blk: {
                const fd = ctx.function_def orelse break :blk false;
                if (ref_idx >= fd.closure_var.len) break :blk false;
                const cv = fd.closure_var[ref_idx];
                if (scope_level == 0 and cv.var_name == atom_id and
                    (cv.closureType() == .module_decl or cv.closureType() == .global_decl) and
                    cv.isLexical())
                {
                    break :blk true;
                }
                break :blk bytecodeFunctionIsEval(ctx) and cv.varKind() == .catch_;
            },
            .global => false,
        };
    }

    fn closureDynamicEnvProbeIteratorInitResolved(
        ctx: *const JSContext,
        binding: ScopeVarBinding,
    ) ClosureDynamicEnvProbeIterator {
        const fd = ctx.function_def orelse return .{ .fd = null, .stop_idx = 0 };
        var stop_idx = fd.closure_var.len;
        switch (binding) {
            .closure => |ref_idx| if (ref_idx < fd.closure_var.len) {
                const cv = fd.closure_var[ref_idx];
                if (!isDynamicEnvObjectAtom(cv.var_name) and
                    cv.varKind() != .catch_ and
                    !closureVarIsGlobalFamily(cv))
                {
                    stop_idx = ref_idx;
                }
            },
            else => {},
        }
        return .{ .fd = fd, .stop_idx = stop_idx };
    }

    fn scopeContainsBinding(
        fd: *const function_def_mod.FunctionDef,
        reference_scope: i32,
        binding_scope: i32,
    ) bool {
        if (reference_scope < 0 or binding_scope < 0) return false;
        var scope = reference_scope;
        var visited: usize = 0;
        while (scope >= 0 and @as(usize, @intCast(scope)) < fd.scopes.len and visited <= fd.scopes.len) : (visited += 1) {
            if (scope == binding_scope) return true;
            scope = fd.scopes[@intCast(scope)].parent;
        }
        return false;
    }

    const EvalVarObjectProbeKind = enum {
        read,
        delete,
        put,
        get_ref,
        make_ref,

        fn matches(self: EvalVarObjectProbeKind, op_id: u8) bool {
            return switch (self) {
                .read => op_id == opcode.op.scope_get_var or op_id == opcode.op.scope_get_var_undef,
                .delete => op_id == opcode.op.scope_delete_var,
                .put => op_id == opcode.op.scope_put_var,
                .get_ref => op_id == opcode.op.scope_get_ref,
                .make_ref => op_id == opcode.op.scope_make_ref,
            };
        }

        fn wireKind(self: EvalVarObjectProbeKind) opcode.dyn_env.ProbeKind {
            return switch (self) {
                .read => .read,
                .delete => .delete,
                .put => .put,
                .get_ref => .get_ref,
                .make_ref => .make_ref,
            };
        }
    };

    const EvalVarObjectProbePlan = struct {
        count: usize = 0,
        prefix_size: usize = 0,
    };

    fn evalVarObjectProbePlan(
        ctx: *const JSContext,
        atom_id: atom.Atom,
        scope_level: i32,
        op_id: u8,
        kind: EvalVarObjectProbeKind,
    ) ?EvalVarObjectProbePlan {
        if (!kind.matches(op_id) or scope_level < 0 or isDynamicEnvObjectAtom(atom_id)) return null;
        // Eval completion is an implementation-local frame slot. It must never
        // consult with/Proxy or a variable object, even when those environments
        // precede ordinary user bindings at the call site.
        if (atom_id == atom.ids.ret) return null;
        const fd = ctx.function_def orelse return null;
        // Every kind now lowers to the same opcode, so the size oracle no
        // longer varies with it.  It is still read from the table rather than
        // written as a literal, so a format change stays a one-line edit.
        const probe_size = opcode.sizeOf(opcode.op.dyn_env_probe);
        var plan = EvalVarObjectProbePlan{};
        var with_iter = LocalWithProbeIterator.init(ctx, atom_id, scope_level);
        while (with_iter.next()) |idx| {
            plan.count += 1;
            plan.prefix_size += evalVarObjectProbeAccessorSize(ctx, .{ .with_local = idx }) + probe_size;
        }
        if (staticBindingStopsDynamicEnvProbes(ctx, atom_id, scope_level)) {
            return if (plan.count == 0) null else plan;
        }
        // A variable object may acquire any free name from a later direct eval;
        // probe eligibility therefore depends on environment order, not on the
        // current eval unit's hoisted-name list.
        if (!scopeUsesArgumentEnvironmentOnly(fd, scope_level) and fd.var_object_idx >= 0) {
            plan.count += 1;
            plan.prefix_size += evalVarObjectProbeAccessorSize(ctx, .{ .local = @intCast(fd.var_object_idx) }) + probe_size;
        }
        if (fd.arg_var_object_idx >= 0) {
            plan.count += 1;
            plan.prefix_size += evalVarObjectProbeAccessorSize(ctx, .{ .local = @intCast(fd.arg_var_object_idx) }) + probe_size;
        }
        var closure_iter = ClosureDynamicEnvProbeIterator.init(ctx, atom_id);
        while (closure_iter.next()) |idx| {
            plan.count += 1;
            plan.prefix_size += evalVarObjectProbeAccessorSize(ctx, evalVarObjectClosureProbe(fd.closure_var[idx], idx)) + probe_size;
        }
        return if (plan.count == 0) null else plan;
    }

    const ScopeVarAction = struct {
        selected: ShortLocForm,
        index: u16 = 0,

        fn size(self: ScopeVarAction) usize {
            return self.selected.size;
        }

        fn atomCount(self: ScopeVarAction) usize {
            return @intFromBool(self.selected.op_id == opcode.op.throw_error);
        }

        fn form(selected: ShortLocForm, index: u16) ScopeVarAction {
            return .{ .selected = selected, .index = index };
        }

        fn throwReadonly() ScopeVarAction {
            return .{ .selected = .{
                .op_id = opcode.op.throw_error,
                .size = @intCast(throw_error_instr_size),
                .operand_size = 0,
            } };
        }

        fn dropAction() ScopeVarAction {
            return .{ .selected = .{
                .op_id = opcode.op.drop,
                .size = 1,
                .operand_size = 0,
            } };
        }
    };

    const ScopeVarProbePlan = struct {
        count: u32 = 0,
        prefix_size: u32 = 0,

        fn from(plan: ?EvalVarObjectProbePlan) Error!ScopeVarProbePlan {
            const resolved = plan orelse return .{};
            if (resolved.count > std.math.maxInt(u32) or
                resolved.prefix_size > std.math.maxInt(u32))
            {
                return error.BytecodeOverflow;
            }
            return .{
                .count = @intCast(resolved.count),
                .prefix_size = @intCast(resolved.prefix_size),
            };
        }
    };

    /// Transactional equivalent of QuickJS's one-pass `resolve_scope_var`
    /// decision. zjs sizes exact output buffers before writing them, so retain
    /// the already-resolved final form rather than repeating scope, closure,
    /// and dynamic-environment scans in the write pass.
    const ScopeVarLoweringPlan = struct {
        action: ScopeVarAction,
        probe: ScopeVarProbePlan = .{},
    };
    fn scopeVarProbeKind(op_id: u8, no_dynamic_env: bool) ?EvalVarObjectProbeKind {
        if (op_id == opcode.op.scope_put_var) {
            return if (no_dynamic_env) null else .put;
        }
        if (op_id == opcode.op.scope_get_var or op_id == opcode.op.scope_get_var_undef) {
            return .read;
        }
        return null;
    }

    fn globalScopeVarAction(ctx: *const JSContext, atom_id: atom.Atom, op_id: u8) Error!ScopeVarAction {
        const ref_idx = lookupGlobalClosureVar(ctx, atom_id) orelse return error.ClosureVarNotFound;
        return ScopeVarAction.form(
            .{
                .op_id = lowerScopeVarOpGlobal(op_id),
                .size = 3,
                .operand_size = 2,
            },
            ref_idx,
        );
    }

    fn closureScopeVarAction(
        ctx: *const JSContext,
        atom_id: atom.Atom,
        ref_idx: u16,
        op_id: u8,
    ) ScopeVarAction {
        if (op_id == opcode.op.scope_put_var and closureVarWriteThrowsReadOnly(ctx, ref_idx)) {
            return ScopeVarAction.throwReadonly();
        }
        if (op_id == opcode.op.scope_put_var and closureVarKind(ctx, ref_idx) == .function_name) {
            return ScopeVarAction.dropAction();
        }
        const ref_op = lowerScopeVarOpForClosure(ctx, atom_id, ref_idx, op_id);
        return ScopeVarAction.form(selectVarRefForm(ctx, ref_op, ref_idx), ref_idx);
    }

    // Keep the full binding classifier out of the caller's hot walk: it is
    // compile-time-only, while the caller also owns both bytecode walks and
    // their transactional allocation state.
    noinline fn planScopeVarAction(
        ctx: *const JSContext,
        atom_id: atom.Atom,
        scope_level: i32,
        op_id: u8,
    ) Error!ScopeVarAction {
        if (scope_level < 0) return globalScopeVarAction(ctx, atom_id, op_id);
        if (lookupTopLevelModuleLexicalClosureVar(ctx, atom_id, scope_level)) |ref_idx| {
            return closureScopeVarAction(ctx, atom_id, ref_idx, op_id);
        }
        if (resolveLocalOrArg(ctx, atom_id, scope_level)) |binding| switch (binding) {
            .arg => |arg_idx| {
                const arg_op = lowerScopeVarOpArg(op_id).?;
                return ScopeVarAction.form(selectArgForm(ctx, arg_op, arg_idx), arg_idx);
            },
            .local => |loc_idx| {
                if (isEvalNonLexicalLocal(ctx, loc_idx)) {
                    return globalScopeVarAction(ctx, atom_id, op_id);
                }
                if (preferTopLevelModuleClassBinding(ctx, atom_id, loc_idx)) |ref_idx| {
                    return closureScopeVarAction(ctx, atom_id, ref_idx, op_id);
                }
                if (op_id == opcode.op.scope_put_var and localWriteThrowsReadOnly(ctx, loc_idx)) {
                    return ScopeVarAction.throwReadonly();
                }
                if (op_id == opcode.op.scope_put_var and localIsFunctionName(ctx, loc_idx)) {
                    return ScopeVarAction.dropAction();
                }
                if (localLexicalAccessNeedsCheck(ctx, atom_id, loc_idx, op_id)) {
                    return ScopeVarAction.form(
                        .{
                            .op_id = lowerScopeVarOpLexical(op_id),
                            .size = 3,
                            .operand_size = 2,
                        },
                        loc_idx,
                    );
                }
                const local_op = lowerScopeVarOpLocal(op_id);
                return ScopeVarAction.form(selectLocForm(ctx, local_op, loc_idx), loc_idx);
            },
        };
        if (lookupClosureVar(ctx, atom_id)) |ref_idx| {
            return closureScopeVarAction(ctx, atom_id, ref_idx, op_id);
        }
        return globalScopeVarAction(ctx, atom_id, op_id);
    }

    /// Opcode half of QuickJS `resolve_scope_var` for an identity already
    /// returned by the topology walk.  This is deliberately only a projection
    /// of the resolved identity: it does not introduce a cache or a second
    /// representation of the instruction stream.
    fn planResolvedScopeVarAction(
        ctx: *const JSContext,
        atom_id: atom.Atom,
        op_id: u8,
        binding: ScopeVarBinding,
    ) Error!ScopeVarAction {
        return switch (binding) {
            .arg => |arg_idx| blk: {
                const arg_op = lowerScopeVarOpArg(op_id) orelse return error.InvalidBytecode;
                break :blk ScopeVarAction.form(selectArgForm(ctx, arg_op, arg_idx), arg_idx);
            },
            .local => |loc_idx| blk: {
                if (op_id == opcode.op.scope_put_var and localWriteThrowsReadOnly(ctx, loc_idx)) {
                    break :blk ScopeVarAction.throwReadonly();
                }
                if (op_id == opcode.op.scope_put_var and localIsFunctionName(ctx, loc_idx)) {
                    break :blk ScopeVarAction.dropAction();
                }
                if (localLexicalAccessNeedsCheck(ctx, atom_id, loc_idx, op_id)) {
                    break :blk ScopeVarAction.form(
                        .{
                            .op_id = lowerScopeVarOpLexical(op_id),
                            .size = 3,
                            .operand_size = 2,
                        },
                        loc_idx,
                    );
                }
                const local_op = lowerScopeVarOpLocal(op_id);
                break :blk ScopeVarAction.form(selectLocForm(ctx, local_op, loc_idx), loc_idx);
            },
            .closure => |ref_idx| closureScopeVarAction(ctx, atom_id, ref_idx, op_id),
            .global => |ref_idx| ScopeVarAction.form(
                .{
                    .op_id = lowerScopeVarOpGlobal(op_id),
                    .size = 3,
                    .operand_size = 2,
                },
                ref_idx,
            ),
        };
    }

    fn planScopeVarLowering(
        ctx: *const JSContext,
        atom_id: atom.Atom,
        scope_operand: ScopeOperand,
        op_id: u8,
        has_dynamic_env_objects: bool,
    ) Error!ScopeVarLoweringPlan {
        var plan = ScopeVarLoweringPlan{
            .action = try planScopeVarAction(ctx, atom_id, scope_operand.level, op_id),
        };
        if (has_dynamic_env_objects) {
            const kind = scopeVarProbeKind(op_id, scope_operand.no_dynamic_env) orelse return plan;
            plan.probe = try ScopeVarProbePlan.from(evalVarObjectProbePlan(
                ctx,
                atom_id,
                scope_operand.level,
                op_id,
                kind,
            ));
        }
        return plan;
    }

    fn writeScopeVarAction(
        func: *bytecode_function.Bytecode,
        output: []u8,
        out_idx: *usize,
        output_atoms: []atom.Atom,
        out_atom_idx: *usize,
        atom_id: atom.Atom,
        action: ScopeVarAction,
    ) Error!void {
        if (out_idx.* + action.size() > output.len) return error.InvalidBytecode;
        if (action.selected.op_id == opcode.op.throw_error) {
            if (out_atom_idx.* >= output_atoms.len) return error.InvalidBytecode;
            writeThrowVarReadOnly(func, output, out_idx, output_atoms, out_atom_idx, atom_id);
        } else if (action.selected.op_id == opcode.op.drop) {
            output[out_idx.*] = opcode.op.drop;
            out_idx.* += 1;
        } else {
            writeSelectedLocForm(output, out_idx, action.selected, action.index);
        }
    }

    fn evalVarObjectProbeAccessorSize(ctx: *const JSContext, probe: EvalVarObjectProbe) usize {
        return switch (probe) {
            .local, .with_local => |idx| selectLocForm(ctx, opcode.op.get_loc, idx).size,
            .ref, .with_ref => |idx| selectVarRefForm(ctx, opcode.op.get_var_ref, idx).size,
        };
    }

    fn evalVarObjectProbeIsWith(probe: EvalVarObjectProbe) bool {
        return switch (probe) {
            .with_local, .with_ref => true,
            .local, .ref => false,
        };
    }

    fn evalVarObjectClosureProbe(cv: function_def_mod.ClosureVar, idx: usize) EvalVarObjectProbe {
        return if (cv.var_name == atom.ids.with_object)
            .{ .with_ref = @intCast(idx) }
        else
            .{ .ref = @intCast(idx) };
    }

    fn loweredScopeDeleteVarSize(ctx: *const JSContext, atom_id: u32, scope_level: i32) usize {
        if (resolveScopeVar(ctx, atom_id, scope_level)) |loc_idx| {
            return if (isEvalNonLexicalLocal(ctx, loc_idx)) 5 else 1;
        }
        if (lookupArg(ctx, atom_id) != null or
            lookupCurrentFunctionName(ctx, atom_id) != null or
            lookupClosureVar(ctx, atom_id) != null) return 1;
        return 5;
    }

    fn loweredScopeGetRefSize(ctx: *const JSContext, atom_id: u32, scope_level: i32) usize {
        if (resolveLocalOrArg(ctx, atom_id, scope_level)) |binding| return switch (binding) {
            .arg => |arg_idx| 1 + selectArgForm(ctx, opcode.op.get_arg, arg_idx).size,
            .local => |loc_idx| if (isEvalNonLexicalLocal(ctx, loc_idx))
                1 + 3
            else if (isLexicalLocal(ctx, loc_idx))
                1 + 3
            else
                1 + selectLocForm(ctx, opcode.op.get_loc, loc_idx).size,
        };
        if (lookupClosureVar(ctx, atom_id)) |ref_idx| {
            return 1 + selectVarRefForm(ctx, opcode.op.get_var_ref, ref_idx).size;
        }
        return 1 + 3;
    }

    fn loweredScopeMakeRefSize(ctx: *const JSContext, atom_id: u32, scope_level: i32) usize {
        if (resolveLocalOrArg(ctx, atom_id, scope_level)) |binding| return switch (binding) {
            .arg => 7,
            .local => |loc_idx| if (isEvalNonLexicalLocal(ctx, loc_idx))
                5
            else if (localWriteThrowsReadOnly(ctx, loc_idx))
                throw_error_instr_size
            else if (localIsFunctionName(ctx, loc_idx))
                1 + selectLocForm(ctx, opcode.op.get_loc, loc_idx).size + 5 + 5
            else
                7,
        };
        if (lookupClosureVar(ctx, atom_id)) |ref_idx| {
            if (closureVarWriteThrowsReadOnly(ctx, ref_idx)) return throw_error_instr_size;
            if (closureVarKind(ctx, ref_idx) == .function_name) {
                return 1 + selectVarRefForm(ctx, opcode.op.get_var_ref, ref_idx).size + 5 + 5;
            }
            return 7;
        }
        return 5;
    }

    fn loweredScopeMakeRefAtomCount(ctx: *const JSContext, atom_id: u32, scope_level: i32) usize {
        if (resolveLocalOrArg(ctx, atom_id, scope_level)) |binding| return switch (binding) {
            .local => |loc_idx| if (!isEvalNonLexicalLocal(ctx, loc_idx) and
                !localWriteThrowsReadOnly(ctx, loc_idx) and
                localIsFunctionName(ctx, loc_idx))
                2
            else
                1,
            .arg => 1,
        };
        if (lookupClosureVar(ctx, atom_id)) |ref_idx| {
            return if (!closureVarWriteThrowsReadOnly(ctx, ref_idx) and
                closureVarKind(ctx, ref_idx) == .function_name)
                2
            else
                1;
        }
        return 1;
    }

    fn writeEvalVarObjectProbeAccessor(ctx: *const JSContext, output: []u8, out_idx: *usize, probe: EvalVarObjectProbe) Error!void {
        switch (probe) {
            .local, .with_local => |idx| {
                const form = selectLocForm(ctx, opcode.op.get_loc, idx);
                if (out_idx.* + form.size > output.len) return error.InvalidBytecode;
                output[out_idx.*] = form.op_id;
                switch (form.operand_size) {
                    0 => {},
                    1 => output[out_idx.* + 1] = @intCast(idx),
                    2 => std.mem.writeInt(u16, output[out_idx.* + 1 ..][0..2], idx, .little),
                    else => unreachable,
                }
                out_idx.* += form.size;
            },
            .ref, .with_ref => |idx| {
                const form = selectVarRefForm(ctx, opcode.op.get_var_ref, idx);
                if (out_idx.* + form.size > output.len) return error.InvalidBytecode;
                output[out_idx.*] = form.op_id;
                switch (form.operand_size) {
                    0 => {},
                    2 => std.mem.writeInt(u16, output[out_idx.* + 1 ..][0..2], idx, .little),
                    else => unreachable,
                }
                out_idx.* += form.size;
            },
        }
    }

    fn writeLoweredScopeDeleteVar(
        ctx: *const JSContext,
        func: *bytecode_function.Bytecode,
        output: []u8,
        out_idx: *usize,
        output_atoms: []atom.Atom,
        out_atom_idx: *usize,
        atom_id: u32,
        scope_level: i32,
    ) Error!void {
        if (resolveScopeVar(ctx, atom_id, scope_level)) |loc_idx| {
            if (isEvalNonLexicalLocal(ctx, loc_idx)) {
                output[out_idx.*] = opcode.op.delete_var;
                std.mem.writeInt(u32, output[out_idx.* + 1 ..][0..4], atom_id, .little);
                output_atoms[out_atom_idx.*] = func.atoms.dup(atom_id);
                out_idx.* += 5;
                out_atom_idx.* += 1;
            } else {
                output[out_idx.*] = opcode.op.push_false;
                out_idx.* += 1;
            }
        } else if (lookupArg(ctx, atom_id) != null or
            lookupCurrentFunctionName(ctx, atom_id) != null or
            lookupClosureVar(ctx, atom_id) != null)
        {
            output[out_idx.*] = opcode.op.push_false;
            out_idx.* += 1;
        } else {
            output[out_idx.*] = opcode.op.delete_var;
            std.mem.writeInt(u32, output[out_idx.* + 1 ..][0..4], atom_id, .little);
            output_atoms[out_atom_idx.*] = func.atoms.dup(atom_id);
            out_idx.* += 5;
            out_atom_idx.* += 1;
        }
    }

    fn writeLoweredScopeGetRef(
        ctx: *JSContext,
        output: []u8,
        out_idx: *usize,
        atom_id: u32,
        scope_level: i32,
    ) Error!void {
        output[out_idx.*] = opcode.op.undefined;
        out_idx.* += 1;
        if (resolveLocalOrArg(ctx, atom_id, scope_level)) |binding| switch (binding) {
            .arg => |arg_idx| {
                const form = selectArgForm(ctx, opcode.op.get_arg, arg_idx);
                output[out_idx.*] = form.op_id;
                switch (form.operand_size) {
                    0 => {},
                    2 => std.mem.writeInt(u16, output[out_idx.* + 1 ..][0..2], arg_idx, .little),
                    else => unreachable,
                }
                out_idx.* += form.size;
            },
            .local => |loc_idx| {
                if (isEvalNonLexicalLocal(ctx, loc_idx)) {
                    try emitGlobalVarOp(ctx, output, out_idx, opcode.op.get_var, atom_id);
                } else if (isLexicalLocal(ctx, loc_idx)) {
                    output[out_idx.*] = opcode.op.get_loc_check;
                    std.mem.writeInt(u16, output[out_idx.* + 1 ..][0..2], loc_idx, .little);
                    out_idx.* += 3;
                } else {
                    const form = selectLocForm(ctx, opcode.op.get_loc, loc_idx);
                    output[out_idx.*] = form.op_id;
                    switch (form.operand_size) {
                        0 => {},
                        1 => output[out_idx.* + 1] = @intCast(loc_idx),
                        2 => std.mem.writeInt(u16, output[out_idx.* + 1 ..][0..2], loc_idx, .little),
                        else => unreachable,
                    }
                    out_idx.* += form.size;
                }
            },
        } else if (lookupClosureVar(ctx, atom_id)) |ref_idx| {
            const form = selectVarRefForm(ctx, opcode.op.get_var_ref, ref_idx);
            output[out_idx.*] = form.op_id;
            switch (form.operand_size) {
                0 => {},
                2 => std.mem.writeInt(u16, output[out_idx.* + 1 ..][0..2], ref_idx, .little),
                else => unreachable,
            }
            out_idx.* += form.size;
        } else {
            try emitGlobalVarOp(ctx, output, out_idx, opcode.op.get_var, atom_id);
        }
    }

    /// QuickJS resolve_scope_var builds a disposable `{ name: binding }`
    /// reference for sloppy function-expression names. Reference-form
    /// assignments then update that object property, leaving the immutable
    /// self-binding untouched (quickjs.c:33012-33024, 33310-33322).
    fn writeFunctionNameDummyRef(
        func: *bytecode_function.Bytecode,
        output: []u8,
        out_idx: *usize,
        output_atoms: []atom.Atom,
        out_atom_idx: *usize,
        atom_id: u32,
        get_form: ShortLocForm,
        binding_idx: u16,
    ) void {
        output[out_idx.*] = opcode.op.object;
        out_idx.* += 1;
        writeSelectedLocForm(output, out_idx, get_form, binding_idx);

        output[out_idx.*] = opcode.op.define_field;
        std.mem.writeInt(u32, output[out_idx.* + 1 ..][0..4], atom_id, .little);
        output_atoms[out_atom_idx.*] = func.atoms.dup(atom_id);
        out_idx.* += 5;
        out_atom_idx.* += 1;

        output[out_idx.*] = opcode.op.push_atom_value;
        std.mem.writeInt(u32, output[out_idx.* + 1 ..][0..4], atom_id, .little);
        output_atoms[out_atom_idx.*] = func.atoms.dup(atom_id);
        out_idx.* += 5;
        out_atom_idx.* += 1;
    }

    fn writeLoweredScopeMakeRef(
        ctx: *const JSContext,
        func: *bytecode_function.Bytecode,
        output: []u8,
        out_idx: *usize,
        output_atoms: []atom.Atom,
        out_atom_idx: *usize,
        atom_id: u32,
        scope_level: i32,
    ) Error!void {
        if (resolveLocalOrArg(ctx, atom_id, scope_level)) |binding| switch (binding) {
            .arg => |arg_idx| {
                output[out_idx.*] = opcode.op.make_arg_ref;
                std.mem.writeInt(u32, output[out_idx.* + 1 ..][0..4], atom_id, .little);
                std.mem.writeInt(u16, output[out_idx.* + 5 ..][0..2], arg_idx, .little);
                output_atoms[out_atom_idx.*] = func.atoms.dup(atom_id);
                out_idx.* += 7;
                out_atom_idx.* += 1;
            },
            .local => |loc_idx| {
                if (isEvalNonLexicalLocal(ctx, loc_idx)) {
                    output[out_idx.*] = opcode.op.make_var_ref;
                    std.mem.writeInt(u32, output[out_idx.* + 1 ..][0..4], atom_id, .little);
                    output_atoms[out_atom_idx.*] = func.atoms.dup(atom_id);
                    out_idx.* += 5;
                    out_atom_idx.* += 1;
                } else if (localWriteThrowsReadOnly(ctx, loc_idx)) {
                    writeThrowVarReadOnly(func, output, out_idx, output_atoms, out_atom_idx, atom_id);
                } else if (localIsFunctionName(ctx, loc_idx)) {
                    writeFunctionNameDummyRef(
                        func,
                        output,
                        out_idx,
                        output_atoms,
                        out_atom_idx,
                        atom_id,
                        selectLocForm(ctx, opcode.op.get_loc, loc_idx),
                        loc_idx,
                    );
                } else {
                    output[out_idx.*] = opcode.op.make_loc_ref;
                    std.mem.writeInt(u32, output[out_idx.* + 1 ..][0..4], atom_id, .little);
                    std.mem.writeInt(u16, output[out_idx.* + 5 ..][0..2], loc_idx, .little);
                    output_atoms[out_atom_idx.*] = func.atoms.dup(atom_id);
                    out_idx.* += 7;
                    out_atom_idx.* += 1;
                }
            },
        } else if (lookupClosureVar(ctx, atom_id)) |ref_idx| {
            if (closureVarWriteThrowsReadOnly(ctx, ref_idx)) {
                writeThrowVarReadOnly(func, output, out_idx, output_atoms, out_atom_idx, atom_id);
            } else if (closureVarKind(ctx, ref_idx) == .function_name) {
                writeFunctionNameDummyRef(
                    func,
                    output,
                    out_idx,
                    output_atoms,
                    out_atom_idx,
                    atom_id,
                    selectVarRefForm(ctx, opcode.op.get_var_ref, ref_idx),
                    ref_idx,
                );
            } else {
                output[out_idx.*] = opcode.op.make_var_ref_ref;
                std.mem.writeInt(u32, output[out_idx.* + 1 ..][0..4], atom_id, .little);
                std.mem.writeInt(u16, output[out_idx.* + 5 ..][0..2], ref_idx, .little);
                output_atoms[out_atom_idx.*] = func.atoms.dup(atom_id);
                out_idx.* += 7;
                out_atom_idx.* += 1;
            }
        } else {
            output[out_idx.*] = opcode.op.make_var_ref;
            std.mem.writeInt(u32, output[out_idx.* + 1 ..][0..4], atom_id, .little);
            output_atoms[out_atom_idx.*] = func.atoms.dup(atom_id);
            out_idx.* += 5;
            out_atom_idx.* += 1;
        }
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
        // QuickJS marks every root program FunctionDef `is_eval`; that flag
        // controls global-declaration construction, not whether compiler
        // temporaries should become dynamic eval bindings. Only actual direct
        // or indirect eval units take this lowering path.
        if (!fd.is_direct_eval and !fd.is_indirect_eval and !bytecodeFunctionIsEval(ctx)) return false;
        if (fd.is_strict_mode or ctx.function.flags.is_strict) return false;
        if (loc_idx >= fd.vars.len) return false;
        const vd = fd.vars[loc_idx];
        // `<ret>` is the eval engine's private completion slot, not a
        // user-declared `var`. It must remain frame-local even in sloppy eval;
        // publishing it as a global/eval binding makes direct eval depend on
        // whether its caller happened to request a script completion value.
        // Demand-created `this`/`new.target`/home-object locals are likewise
        // compiler-owned frame state. Canonical indirect-eval roots expose
        // their own `this` through this path; it is never a dynamic eval var.
        if (vd.var_name == atom.ids.ret or isPseudoBindingAtom(vd.var_name)) return false;
        if (vd.scope_level != 0 or vd.is_lexical) return false;
        return vd.var_kind == .normal or
            vd.var_kind == .function_decl or
            vd.var_kind == .new_function_decl;
    }

    fn bytecodeFunctionIsEval(ctx: *const JSContext) bool {
        // Variable resolution runs before the final FunctionBytecode flags are
        // published.  QuickJS makes these decisions from the live
        // JSFunctionDef::is_eval field, not from the finished bytecode flag
        // (whose QuickJS use is script/module-name lookup).  Keep the finished
        // flag only as the exact fallback for synthetic callers without an fd.
        if (ctx.function_def) |fd| return fd.is_direct_eval or fd.is_indirect_eval;
        return ctx.function.flags.is_direct_or_indirect_eval;
    }

    fn localIsFunctionName(ctx: *const JSContext, loc_idx: u16) bool {
        const fd = ctx.function_def orelse return false;
        return loc_idx < fd.vars.len and fd.vars[loc_idx].var_kind == .function_name;
    }

    /// QuickJS resolves writes/references to const locals directly to
    /// OP_throw_error. Function-expression names are const exactly when their
    /// defining function is strict; sloppy names are handled by the discard
    /// and dummy-reference lowering paths above.
    fn localWriteThrowsReadOnly(ctx: *const JSContext, loc_idx: u16) bool {
        const fd = ctx.function_def orelse return false;
        if (loc_idx >= fd.vars.len) return false;
        return fd.vars[loc_idx].is_const;
    }

    /// Promote a Phase-1 var op to its TDZ-checked counterpart for
    /// lexical locals. Mirrors the `_check` family in QuickJS:
    /// - `scope_get_var` / `scope_get_var_undef` → `get_loc_check`
    ///   (throws ReferenceError if slot is uninitialised).
    /// - `scope_put_var` → `put_loc_check` (throws ReferenceError if
    ///   uninitialised, then stores).
    /// - derived-constructor `this` initialization → `put_loc_check_init`
    ///   (the only lexical initialization QuickJS checks for re-entry).
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

    /// QuickJS keeps ordinary lexical reads/writes TDZ-checked, but lowers an
    /// ordinary `scope_put_var_init` to bare `put_loc`; only the derived
    /// constructor's `this` binding uses `put_loc_check_init` so `super()`
    /// cannot initialize it twice (quickjs.c:33068-33087).
    fn localLexicalAccessNeedsCheck(ctx: *const JSContext, atom_id: atom.Atom, loc_idx: u16, op_id: u8) bool {
        if (!isLexicalLocal(ctx, loc_idx)) return false;
        return op_id != opcode.op.scope_put_var_init or atom_id == atom.ids.this_;
    }

    fn writeSelectedLocForm(output: []u8, out_idx: *usize, form: ShortLocForm, loc_idx: u16) void {
        output[out_idx.*] = form.op_id;
        switch (form.operand_size) {
            0 => {},
            1 => output[out_idx.* + 1] = @intCast(loc_idx),
            2 => std.mem.writeInt(u16, output[out_idx.* + 1 ..][0..2], loc_idx, .little),
            else => unreachable,
        }
        out_idx.* += form.size;
    }

    fn markReferenceTakenBinding(ctx: *const JSContext, atom_id: atom.Atom, scope_level: i16) Error!void {
        const fd = ctx.function_def orelse return;
        const binding = resolveLocalOrArg(ctx, atom_id, scope_level) orelse return;
        switch (binding) {
            .local => |idx| if (idx < fd.vars.len) {
                // QuickJS's function-name dummy-reference arm never calls
                // capture_var: the temporary object owns the write target.
                if (fd.vars[idx].var_kind != .function_name) {
                    fd.captureLocal(idx) catch return error.InvalidBytecode;
                }
            },
            .arg => |idx| if (idx < fd.args.len) {
                fd.captureArg(idx) catch return error.InvalidBytecode;
            },
        }
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

    fn canOptimizeGlobalRefPutTail(ctx: *const JSContext, atom_id: u32) bool {
        return !functionIsStrict(ctx) or functionDeclaresGlobalVar(ctx, atom_id);
    }

    fn closureVarIsGlobalFamily(cv: function_def_mod.ClosureVar) bool {
        return switch (cv.closureType()) {
            .global, .global_ref, .global_decl, .module_decl, .module_import => true,
            .local, .arg, .ref => false,
        };
    }

    /// Resolve each eval hoist against the finalized closure order. Dynamic
    /// environment objects and real bindings deliberately share one ordered
    /// walk: the first applicable entry is the declaration environment.
    fn resolveEvalGlobalVarTargets(fd: *function_def_mod.FunctionDef) Error!void {
        for (fd.global_vars) |*gv| {
            if (!fd.is_eval) {
                gv.eval_target = .global;
                continue;
            }

            gv.eval_target = .global;
            for (fd.closure_var, 0..) |cv, idx| {
                if (cv.var_name == gv.var_name) {
                    // Annex B.3.4's same-name simple catch binding is not the
                    // VariableDeclarationEnvironment used for a direct-eval
                    // `var`. Skip it so the dynamic var object can receive
                    // the hoisted binding; the eval initializer still uses
                    // the catch reference for the assignment itself.
                    if (gv.cpool_idx < 0 and cv.varKind() == .catch_) continue;
                    // For every other closure, instantiate_hoisted_definitions
                    // stops at the first same-name binding.
                    if (idx > std.math.maxInt(u16)) return error.InvalidBytecode;
                    gv.eval_target = .{ .closure = @intCast(idx) };
                    break;
                }
                if (isEvalVarObjectAtom(cv.var_name) and closureVarIsRuntimeVarRef(cv)) {
                    if (idx > std.math.maxInt(u16)) return error.InvalidBytecode;
                    gv.eval_target = .{ .var_object = @intCast(idx) };
                    break;
                }
            }
        }
    }

    fn hasDirectEvalLexicalRedeclaration(
        fd: *const function_def_mod.FunctionDef,
        gv: function_def_mod.GlobalVar,
    ) bool {
        if (!fd.is_direct_eval) return false;
        for (fd.closure_var) |cv| {
            // add_global_variables appends global-family entries at the end;
            // QuickJS's validation walk stops there (quickjs.c:34209-34215).
            if (closureVarIsGlobalFamily(cv)) return false;
            if (cv.var_name == gv.var_name) {
                // Annex B.3.4 excludes the same-name simple catch environment
                // from EvalDeclarationInstantiation's conflict walk. Continue
                // so an outer lexical still rejects the declaration.
                if (gv.cpool_idx < 0 and cv.varKind() == .catch_) continue;
                return cv.isLexical();
            }
            if (isEvalVarObjectAtom(cv.var_name)) return false;
        }
        return false;
    }

    fn findClosureName(fd: *const function_def_mod.FunctionDef, atom_id: atom.Atom) ?u16 {
        for (fd.closure_var, 0..) |cv, idx| {
            if (cv.var_name == atom_id) return @intCast(idx);
        }
        return null;
    }

    fn isPseudoBindingAtom(atom_id: atom.Atom) bool {
        return atom_id == atom.ids.home_object or
            atom_id == atom.ids.this_active_func or
            atom_id == atom.ids.new_target or
            atom_id == atom.ids.this_;
    }

    fn threadParentLocalSource(
        target: *function_def_mod.FunctionDef,
        parent: *function_def_mod.FunctionDef,
        local_idx: u16,
    ) Error!u16 {
        if (local_idx >= parent.vars.len) return error.InvalidBytecode;
        parent.captureLocal(local_idx) catch return error.InvalidBytecode;
        const vd = parent.vars[local_idx];
        return threadClosureSource(target, parent, local_idx, function_def_mod.ClosureVar.init(.{
            .closure_type = .local,
            .is_lexical = vd.is_lexical,
            .is_const = vd.is_const,
            .var_kind = vd.var_kind,
            .var_idx = local_idx,
            .var_name = vd.var_name,
        }), .local);
    }

    fn threadParentArgSource(
        target: *function_def_mod.FunctionDef,
        parent: *function_def_mod.FunctionDef,
        arg_idx: u16,
    ) Error!u16 {
        if (arg_idx >= parent.args.len) return error.InvalidBytecode;
        parent.captureArg(arg_idx) catch return error.InvalidBytecode;
        const arg = parent.args[arg_idx];
        return threadClosureSource(target, parent, arg_idx, function_def_mod.ClosureVar.init(.{
            .closure_type = .arg,
            .is_lexical = arg.is_lexical,
            .is_const = arg.is_const,
            .var_kind = arg.var_kind,
            .var_idx = arg_idx,
            .var_name = arg.var_name,
        }), .arg);
    }

    /// Scope-chain half of qjs resolve_scope_var. While looking for the named
    /// source, every preceding `with` environment is itself a capture event.
    /// `first/scope_next` is already the complete finalized visible chain.
    const ParentScopedSource = struct {
        local: ?u16 = null,
        argument_environment_only: bool = false,
    };

    fn discoverParentScopedSource(
        comptime trust_final_scope_links: bool,
        target: *function_def_mod.FunctionDef,
        parent: *function_def_mod.FunctionDef,
        atom_id: atom.Atom,
        start_scope: i32,
    ) Error!ParentScopedSource {
        if (start_scope < 0 or @as(usize, @intCast(start_scope)) >= parent.scopes.len) {
            return error.InvalidBytecode;
        }
        var var_idx = parent.scopes[@intCast(start_scope)].first;
        var visited_vars: usize = 0;
        while (var_idx >= 0) {
            if (comptime !trust_final_scope_links) {
                if (@as(usize, @intCast(var_idx)) >= parent.vars.len or
                    visited_vars >= parent.vars.len) return error.InvalidBytecode;
                visited_vars += 1;
            }
            const vd = parent.vars[@intCast(var_idx)];
            if (vd.var_name == atom_id) return .{ .local = @intCast(var_idx) };
            if (!isPseudoBindingAtom(atom_id) and vd.var_name == atom.ids.with_object) {
                _ = try threadParentLocalSource(target, parent, @intCast(var_idx));
            }
            var_idx = vd.scope_next;
        }
        if (var_idx != -1 and var_idx != function_bytecode.arg_scope_end) return error.InvalidBytecode;
        return .{ .argument_environment_only = var_idx == function_bytecode.arg_scope_end };
    }

    fn threadParentEvalObject(
        target: *function_def_mod.FunctionDef,
        parent: *function_def_mod.FunctionDef,
        local_idx_i32: i32,
    ) Error!u16 {
        if (local_idx_i32 < 0 or local_idx_i32 > std.math.maxInt(u16)) return error.InvalidBytecode;
        return threadParentLocalSource(target, parent, @intCast(local_idx_i32));
    }

    fn ensureParentArgumentsBinding(parent: *function_def_mod.FunctionDef) Error!u16 {
        _ = parent.ensureArgumentsBinding() catch return error.OutOfMemory;
        if (parent.arguments_var_idx < 0 or parent.arguments_var_idx > std.math.maxInt(u16)) {
            return error.InvalidBytecode;
        }
        return @intCast(parent.arguments_var_idx);
    }

    fn ensureCurrentPseudoBinding(
        fd: *function_def_mod.FunctionDef,
        atom_id: atom.Atom,
    ) Error!?u16 {
        if (!fd.has_this_binding) return null;
        const idx_i32 = if (atom_id == atom.ids.home_object)
            fd.ensureHomeObjectBinding() catch return error.OutOfMemory
        else if (atom_id == atom.ids.this_active_func)
            fd.ensureThisActiveFunctionBinding() catch return error.OutOfMemory
        else if (atom_id == atom.ids.new_target)
            fd.ensureNewTargetBinding() catch return error.OutOfMemory
        else if (atom_id == atom.ids.this_)
            fd.ensureThisBinding() catch return error.OutOfMemory
        else
            return null;
        if (idx_i32 < 0 or idx_i32 > std.math.maxInt(u16)) return error.InvalidBytecode;
        return @intCast(idx_i32);
    }

    /// Select the same current-function closure identity as the lowering half:
    /// a real runtime ref wins, while dynamic-global carriers are the fallback.
    /// Unlike the former `findClosureName` guard this returns the chosen index,
    /// so the caller never needs a second name scan.
    fn findResolvedClosureBinding(
        fd: *const function_def_mod.FunctionDef,
        atom_id: atom.Atom,
    ) ?ScopeVarBinding {
        var global_idx: ?u16 = null;
        for (fd.closure_var, 0..) |cv, idx_usize| {
            if (cv.var_name != atom_id) continue;
            const idx: u16 = @intCast(idx_usize);
            if (closureVarIsRuntimeVarRef(cv) and
                !closureVarSourceIsDynamicGlobal(fd, idx_usize))
            {
                return .{ .closure = idx };
            }
            if (global_idx == null and closureVarIsGlobalFamily(cv)) {
                global_idx = idx;
            }
        }
        return if (global_idx) |idx| .{ .global = idx } else null;
    }

    /// Continue QuickJS's resolve_scope_var walk after the current function's
    /// scope/var/argument lookup missed.  Keep parent traversal, closure
    /// threading, and demand-created bindings out of the overwhelmingly common
    /// local/argument path: those operations need fallible calls and a large
    /// spill frame, while QuickJS reaches them only after the same local miss.
    noinline fn resolveBindingTopologyAfterCurrentMiss(
        comptime trust_final_scope_links: bool,
        ctx: *JSContext,
        atom_id: atom.Atom,
    ) Error!ScopeVarBinding {
        const fd = ctx.function_def orelse return error.NoFunctionDef;
        if (comptime trust_final_scope_links) {
            std.debug.assert(ctx.scope_link_proof != .none);
        }
        // Current-function fallbacks mirror resolve_scope_var exactly: normal
        // scope/var/argument lookup first, then pseudo variables, implicit
        // arguments, and finally a named function-expression self binding.
        // Parser bytecode therefore stays name+scope; this final topology pass
        // is the single point that can append a demand-created special local.
        if (try ensureCurrentPseudoBinding(fd, atom_id)) |idx| return .{ .local = idx };
        if (atom_id == atom.ids.arguments and fd.has_arguments_binding) {
            const idx_i32 = fd.ensureArgumentsBinding() catch return error.OutOfMemory;
            if (idx_i32 < 0 or idx_i32 > std.math.maxInt(u16)) return error.InvalidBytecode;
            return .{ .local = @intCast(idx_i32) };
        }
        if (fd.is_named_func_expr and atom_id == fd.func_name) {
            const idx_i32 = fd.ensureFuncExprSelfBinding() catch return error.OutOfMemory;
            if (idx_i32 < 0 or idx_i32 > std.math.maxInt(u16)) return error.InvalidBytecode;
            return .{ .local = @intCast(idx_i32) };
        }

        // Fixed prefixes/imports and already-threaded child demands are final
        // binding identities. The selected row is returned directly instead
        // of using a name-only guard and rediscovering it in the planner.
        if (findResolvedClosureBinding(fd, atom_id)) |binding| return binding;

        if (fd.parent != null) {
            if (comptime trust_final_scope_links) {
                try ctx.proveParentScopeLinksForResolution();
            } else {
                try validateFunctionDefParentChain(fd);
            }
        }

        var maybe_parent = fd.parent;
        var visible_scope_level = fd.parent_scope_level;
        while (maybe_parent) |parent| {
            const scoped_source = try discoverParentScopedSource(
                trust_final_scope_links,
                fd,
                parent,
                atom_id,
                visible_scope_level,
            );
            const argument_environment_only = scoped_source.argument_environment_only;
            if (scoped_source.local) |local_idx| {
                return .{ .closure = try threadParentLocalSource(fd, parent, local_idx) };
            }

            // An arrow created while a parameter initializer is evaluated is
            // linked to the parameter environment, not to the function-body
            // var environment.  The synthetic `arguments` cell is normally
            // created by add_eval_variables, but this capture is also valid
            // without a direct eval in the parent, so materialize the same
            // scope-1 cell on demand before the body-var/arguments fallback.
            if (atom_id == atom.ids.arguments and
                argument_environment_only and
                parent.has_arguments_binding and
                parent.has_parameter_expressions and
                parent.func_type != .arrow and
                parent.func_type != .class_static_init)
            {
                _ = parent.ensureArgumentsBinding() catch return error.OutOfMemory;
                parent.ensureArgumentsArgumentBinding() catch |err| return switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                    error.InvalidScope => error.InvalidBytecode,
                };
                const parameter_arguments_idx = if (parent.hasExplicitArgumentsVar())
                    parent.arguments_arg_idx
                else
                    parent.arguments_var_idx;
                if (parameter_arguments_idx >= 0) {
                    return .{ .closure = try threadParentLocalSource(
                        fd,
                        parent,
                        @intCast(parameter_arguments_idx),
                    ) };
                }
            }

            if (!argument_environment_only) {
                // QuickJS's finalized scope chain deliberately stops before
                // scope 0, then resolve_scope_var calls find_var: function
                // vars are scope-0 rows even when their parser-era
                // `scope_next` stores a block declaration origin.  They must
                // not be linked into scope.first merely to make descendants
                // discover them.
                var function_var_idx = parent.vars.len;
                while (function_var_idx > 0) {
                    function_var_idx -= 1;
                    const vd = &parent.vars[function_var_idx];
                    if (vd.var_name == atom_id and vd.scope_level == 0) {
                        return .{ .closure = try threadParentLocalSource(
                            fd,
                            parent,
                            @intCast(function_var_idx),
                        ) };
                    }
                }
                const arg_idx_i32 = parent.findArg(atom_id);
                if (arg_idx_i32 >= 0) {
                    const arg_idx: u16 = @intCast(arg_idx_i32);
                    return .{ .closure = try threadParentArgSource(fd, parent, arg_idx) };
                }
            }

            if (try ensureCurrentPseudoBinding(parent, atom_id)) |local_idx| {
                return .{ .closure = try threadParentLocalSource(fd, parent, local_idx) };
            }

            if (atom_id == atom.ids.arguments and parent.has_arguments_binding) {
                const local_idx = try ensureParentArgumentsBinding(parent);
                return .{ .closure = try threadParentLocalSource(fd, parent, local_idx) };
            }

            if (parent.is_named_func_expr and atom_id == parent.func_name) {
                const local_idx_i32 = parent.ensureFuncExprSelfBinding() catch return error.OutOfMemory;
                if (local_idx_i32 < 0 or local_idx_i32 > std.math.maxInt(u16)) return error.InvalidBytecode;
                return .{ .closure = try threadParentLocalSource(
                    fd,
                    parent,
                    @intCast(local_idx_i32),
                ) };
            }

            if (!isPseudoBindingAtom(atom_id)) {
                if (!argument_environment_only and parent.var_object_idx >= 0) {
                    _ = try threadParentEvalObject(fd, parent, parent.var_object_idx);
                }
                if (parent.arg_var_object_idx >= 0) {
                    _ = try threadParentEvalObject(fd, parent, parent.arg_var_object_idx);
                }
            }

            if (parent.is_eval) {
                for (parent.closure_var, 0..) |source, source_idx_usize| {
                    if (source_idx_usize > std.math.maxInt(u16)) return error.InvalidBytecode;
                    const source_idx: u16 = @intCast(source_idx_usize);
                    if (source.var_name == atom_id) {
                        const source_type: function_def_mod.ClosureType = switch (source.closureType()) {
                            .global, .global_ref, .global_decl => .global_ref,
                            .local, .arg, .ref, .module_decl, .module_import => .ref,
                        };
                        const idx = try threadClosureSource(fd, parent, source_idx, source, source_type);
                        return if (source_type == .global_ref)
                            .{ .global = idx }
                        else
                            .{ .closure = idx };
                    }
                    if (!isPseudoBindingAtom(atom_id) and isDynamicEnvObjectAtom(source.var_name)) {
                        _ = try threadClosureSource(fd, parent, source_idx, source, .ref);
                    }
                }
                break;
            }

            visible_scope_level = parent.parent_scope_level;
            maybe_parent = parent.parent;
        }

        return .{ .global = try ensureGlobalClosureVar(ctx, atom_id) };
    }

    /// Discover one scope-bytecode binding after all declarations and child
    /// FunctionDefs exist. This is the topology half of QuickJS
    /// resolve_scope_var/get_closure_var: source identity is found from final
    /// scope metadata, capture_var fires at the owner, and every intermediate
    /// row is appended in child-finalization/bytecode encounter order.  The
    /// returned identity is the row that the same QuickJS walk just selected.
    inline fn resolveBindingTopologyResultImpl(
        comptime use_exact_scope_index: bool,
        comptime trust_final_scope_links: bool,
        ctx: *JSContext,
        atom_id: atom.Atom,
        scope_level: i32,
    ) Error!ScopeVarBinding {
        if (scope_level >= 0) {
            if (resolveLocalOrArgImpl(
                use_exact_scope_index,
                trust_final_scope_links,
                ctx,
                atom_id,
                scope_level,
            )) |binding| {
                return switch (binding) {
                    .local => |idx| .{ .local = idx },
                    .arg => |idx| .{ .arg = idx },
                };
            }
        }
        return resolveBindingTopologyAfterCurrentMiss(trust_final_scope_links, ctx, atom_id);
    }

    fn resolveBindingTopologyResult(
        ctx: *JSContext,
        atom_id: atom.Atom,
        scope_level: i32,
    ) Error!ScopeVarBinding {
        return resolveBindingTopologyResultImpl(true, false, ctx, atom_id, scope_level);
    }

    /// Complete the binding classification needed by ordinary scope-var
    /// lowering. Module lexical precedence and sloppy-eval locals are action
    /// semantics, so normalize them once here rather than in a later lookup.
    fn resolveScopeVarBindingTopologyImpl(
        comptime use_exact_scope_index: bool,
        comptime trust_final_scope_links: bool,
        ctx: *JSContext,
        atom_id: atom.Atom,
        scope_level: i32,
    ) Error!ScopeVarBinding {
        const discovered = try resolveBindingTopologyResultImpl(
            use_exact_scope_index,
            trust_final_scope_links,
            ctx,
            atom_id,
            scope_level,
        );
        if (scope_level < 0) {
            return .{ .global = try ensureGlobalClosureVar(ctx, atom_id) };
        }
        if (lookupTopLevelModuleLexicalClosureVar(ctx, atom_id, scope_level)) |ref_idx| {
            return .{ .closure = ref_idx };
        }
        return switch (discovered) {
            .local => |loc_idx| blk: {
                if (isEvalNonLexicalLocal(ctx, loc_idx)) {
                    break :blk .{ .global = try ensureGlobalClosureVar(ctx, atom_id) };
                }
                if (preferTopLevelModuleClassBinding(ctx, atom_id, loc_idx)) |ref_idx| {
                    break :blk .{ .closure = ref_idx };
                }
                break :blk discovered;
            },
            else => discovered,
        };
    }

    fn resolveScopeVarBindingTopology(
        ctx: *JSContext,
        atom_id: atom.Atom,
        scope_level: i32,
    ) Error!ScopeVarBinding {
        return resolveScopeVarBindingTopologyImpl(true, false, ctx, atom_id, scope_level);
    }

    const ScopeVarBindingKind = enum(u8) {
        local,
        arg,
        closure,
        global,
    };

    /// QuickJS `resolve_scope_var` discovers the binding and selects the final
    /// opcode in one routine. Keep the production V2 scope-op path equally
    /// fused: its surface inlines this semantic walk into `lowerScopeVar`, so
    /// discovery, action selection, and writing share one outlined compiler
    /// entry. The exact-index compatibility wrapper below remains outlined,
    /// while reference/private consumers retain the standalone topology API.
    /// This is only a call-shape change; lookup order and data structures stay
    /// identical to the linked-scope QuickJS path above.
    /// Register-sized result of the QuickJS-shaped binding walk.  The former
    /// tagged-union pair was 10 bytes, which forced the outlined resolver to
    /// return through caller-owned stack memory even though both identities
    /// are u16 and the selected instruction is at most three bytes of
    /// metadata.  Keep the semantic representation (`ScopeVarBinding` and
    /// `ScopeVarAction`) at the API edges, but carry the hot result in one
    /// integer exactly like QuickJS keeps `idx`, `var_idx`, and `op` in the
    /// resolving routine.
    const ResolvedScopeVarPlan = packed struct(u64) {
        binding_index: u16,
        action_index: u16,
        action_op_id: u8,
        action_size: u8,
        action_operand_size: u8,
        binding_kind: ScopeVarBindingKind,

        fn init(
            resolved_binding: ScopeVarBinding,
            resolved_action: ScopeVarAction,
        ) ResolvedScopeVarPlan {
            const base: ResolvedScopeVarPlan = .{
                .binding_index = 0,
                .action_index = resolved_action.index,
                .action_op_id = resolved_action.selected.op_id,
                .action_size = resolved_action.selected.size,
                .action_operand_size = resolved_action.selected.operand_size,
                .binding_kind = .local,
            };
            return switch (resolved_binding) {
                .local => |index| withBinding(base, .local, index),
                .arg => |index| withBinding(base, .arg, index),
                .closure => |index| withBinding(base, .closure, index),
                .global => |index| withBinding(base, .global, index),
            };
        }

        inline fn withBinding(
            base: ResolvedScopeVarPlan,
            kind: ScopeVarBindingKind,
            index: u16,
        ) ResolvedScopeVarPlan {
            var result = base;
            result.binding_kind = kind;
            result.binding_index = index;
            return result;
        }

        inline fn binding(self: ResolvedScopeVarPlan) ScopeVarBinding {
            return switch (self.binding_kind) {
                .local => .{ .local = self.binding_index },
                .arg => .{ .arg = self.binding_index },
                .closure => .{ .closure = self.binding_index },
                .global => .{ .global = self.binding_index },
            };
        }

        inline fn action(self: ResolvedScopeVarPlan) ScopeVarAction {
            return .{
                .selected = .{
                    .op_id = self.action_op_id,
                    .size = self.action_size,
                    .operand_size = self.action_operand_size,
                },
                .index = self.action_index,
            };
        }
    };

    inline fn resolveScopeVarPlanImpl(
        comptime use_exact_scope_index: bool,
        comptime trust_final_scope_links: bool,
        ctx: *JSContext,
        atom_id: atom.Atom,
        scope_level: i32,
        op_id: u8,
    ) Error!ResolvedScopeVarPlan {
        const discovered = try @call(
            .always_inline,
            resolveBindingTopologyResultImpl,
            .{ use_exact_scope_index, trust_final_scope_links, ctx, atom_id, scope_level },
        );
        const binding: ScopeVarBinding = if (scope_level < 0)
            .{ .global = try ensureGlobalClosureVar(ctx, atom_id) }
        else if (lookupTopLevelModuleLexicalClosureVar(ctx, atom_id, scope_level)) |ref_idx|
            .{ .closure = ref_idx }
        else switch (discovered) {
            .local => |loc_idx| blk: {
                if (isEvalNonLexicalLocal(ctx, loc_idx)) {
                    break :blk .{ .global = try ensureGlobalClosureVar(ctx, atom_id) };
                }
                if (preferTopLevelModuleClassBinding(ctx, atom_id, loc_idx)) |ref_idx| {
                    break :blk .{ .closure = ref_idx };
                }
                break :blk discovered;
            },
            else => discovered,
        };
        const action = try @call(
            .always_inline,
            planResolvedScopeVarAction,
            .{ ctx, atom_id, op_id, binding },
        );
        return ResolvedScopeVarPlan.init(binding, action);
    }

    noinline fn resolveScopeVarPlan(
        ctx: *JSContext,
        atom_id: atom.Atom,
        scope_level: i32,
        op_id: u8,
    ) Error!ResolvedScopeVarPlan {
        return resolveScopeVarPlanImpl(true, false, ctx, atom_id, scope_level, op_id);
    }

    inline fn resolveScopeVarPlanV2(
        ctx: *JSContext,
        atom_id: atom.Atom,
        scope_level: i32,
        op_id: u8,
    ) Error!ResolvedScopeVarPlan {
        return resolveScopeVarPlanImpl(false, true, ctx, atom_id, scope_level, op_id);
    }

    fn resolveBindingTopology(ctx: *JSContext, atom_id: atom.Atom, scope_level: i32) Error!void {
        _ = try resolveBindingTopologyResult(ctx, atom_id, scope_level);
    }

    inline fn resolveBindingTopologyV2(ctx: *JSContext, atom_id: atom.Atom, scope_level: i32) Error!void {
        _ = try resolveBindingTopologyResultImpl(false, true, ctx, atom_id, scope_level);
    }

    inline fn resolveScopeVarBindingTopologyV2(
        ctx: *JSContext,
        atom_id: atom.Atom,
        scope_level: i32,
    ) Error!ScopeVarBinding {
        return resolveScopeVarBindingTopologyImpl(false, true, ctx, atom_id, scope_level);
    }

    const PrivateBindingOwner = struct {
        fd: *function_def_mod.FunctionDef,
        local_idx: u16,
    };

    fn privateBindingOwner(ctx: *const JSContext, res: PrivateFieldResolution) ?PrivateBindingOwner {
        var carrier = ctx.function_def orelse return null;
        if (!res.is_ref) {
            if (res.idx >= carrier.vars.len or !isPrivateVarKind(carrier.vars[res.idx].var_kind)) return null;
            return .{ .fd = carrier, .local_idx = res.idx };
        }

        var closure_idx = res.idx;
        var hops: usize = 0;
        while (hops < 64) : (hops += 1) {
            if (closure_idx >= carrier.closure_var.len) return null;
            const cv = carrier.closure_var[closure_idx];
            switch (cv.closureType()) {
                .local => {
                    const owner = carrier.parent orelse return null;
                    if (cv.var_idx >= owner.vars.len or !isPrivateVarKind(owner.vars[cv.var_idx].var_kind)) return null;
                    return .{ .fd = owner, .local_idx = cv.var_idx };
                },
                .ref => {
                    carrier = carrier.parent orelse return null;
                    closure_idx = cv.var_idx;
                },
                .arg, .global, .global_ref, .global_decl, .module_decl, .module_import => return null,
            }
        }
        return null;
    }

    fn findPrivateSetterOwnerBinding(
        ctx: *const JSContext,
        private_atom: atom.Atom,
        owner: PrivateBindingOwner,
    ) ?u16 {
        if (owner.local_idx >= owner.fd.vars.len) return null;
        const private_vd = owner.fd.vars[owner.local_idx];
        for (owner.fd.vars, 0..) |vd, idx| {
            if (vd.scope_level != private_vd.scope_level or vd.var_kind != .private_setter) continue;
            if (isPrivateSetterCompanionName(ctx, private_atom, vd.var_name)) return @intCast(idx);
        }
        return null;
    }

    fn resolvePrivateBindingTopology(
        ctx: *JSContext,
        op_id: u8,
        atom_id: atom.Atom,
        scope_level: i32,
    ) Error!void {
        // Private operands use the ordinary lexical/capture machinery, but a
        // miss is never an ordinary global. Validate the VarKind immediately
        // after threading so the compatibility side-name tables cannot turn
        // an absent declaration into a binding.
        try resolveBindingTopology(ctx, atom_id, scope_level);
        const private = resolvePrivateField(ctx, atom_id, scope_level) orelse return error.ClosureVarNotFound;

        if (op_id != opcode.op.scope_put_private_field or
            (private.var_kind != .private_setter and private.var_kind != .private_getter_setter)) return;
        if (resolvePrivateSetter(ctx, atom_id, scope_level) != null) return;

        const owner = privateBindingOwner(ctx, private) orelse return error.ClosureVarNotFound;
        const setter_idx = findPrivateSetterOwnerBinding(ctx, atom_id, owner) orelse return error.ClosureVarNotFound;
        const current = ctx.function_def orelse return error.NoFunctionDef;
        if (owner.fd != current) _ = try threadParentLocalSource(current, owner.fd, setter_idx);
        if (resolvePrivateSetter(ctx, atom_id, scope_level) == null) return error.ClosureVarNotFound;
    }

    /// Decide whether a make-ref name is genuinely global without creating a
    /// closure row. This is used only for the QuickJS tail fold that removes
    /// the make-ref itself; surviving events go through
    /// `resolveBindingTopology` below.
    fn makeRefBindingIsGlobal(ctx: *const JSContext, atom_id: atom.Atom, scope_level: i32) bool {
        const fd = ctx.function_def orelse return true;
        if (lookupTopLevelModuleLexicalClosureVar(ctx, atom_id, scope_level) != null or
            resolveLocalOrArg(ctx, atom_id, scope_level) != null or
            lookupClosureVar(ctx, atom_id) != null or
            (fd.is_named_func_expr and fd.func_name == atom_id) or
            (atom_id == atom.ids.arguments and fd.has_arguments_binding))
        {
            return false;
        }

        var maybe_parent = fd.parent;
        var visible_scope = fd.parent_scope_level;
        while (maybe_parent) |parent| {
            if (visible_scope >= 0 and @as(usize, @intCast(visible_scope)) < parent.scopes.len) {
                var idx = parent.scopes[@intCast(visible_scope)].first;
                var visited: usize = 0;
                while (idx >= 0) {
                    if (@as(usize, @intCast(idx)) >= parent.vars.len or visited >= parent.vars.len) return false;
                    visited += 1;
                    const vd = parent.vars[@intCast(idx)];
                    if (vd.var_name == atom_id) return false;
                    idx = vd.scope_next;
                }
                if (idx != function_bytecode.arg_scope_end) {
                    if (parent.findArg(atom_id) >= 0) return false;
                    for (parent.vars) |vd| {
                        if (vd.scope_level == 0 and vd.var_name == atom_id) return false;
                    }
                }
            }
            if ((isPseudoBindingAtom(atom_id) and parent.has_this_binding) or
                (atom_id == atom.ids.arguments and parent.has_arguments_binding) or
                (parent.is_named_func_expr and parent.func_name == atom_id))
            {
                return false;
            }
            for (parent.closure_var) |cv| {
                if (cv.var_name != atom_id) continue;
                return switch (cv.closureType()) {
                    .global, .global_ref, .global_decl => true,
                    .local, .arg, .ref, .module_decl, .module_import => false,
                };
            }
            visible_scope = parent.parent_scope_level;
            maybe_parent = parent.parent;
        }
        return true;
    }

    /// The decision/writer surface `compiler/resolve_variables.zig`
    /// consumes. Everything the compiler is allowed to reach is named once
    /// here; nothing else in this namespace is exported.
    pub const surface = struct {
        pub const ScopeOperandAlias = ScopeOperand;
        pub const ScopeVarActionAlias = ScopeVarAction;
        pub const ScopeVarBindingAlias = ScopeVarBinding;
        pub const ResolvedScopeVarPlanAlias = ResolvedScopeVarPlan;
        pub const ScopeVarProbePlanAlias = EvalVarObjectProbePlan;
        pub const EvalVarObjectProbeAlias = EvalVarObjectProbe;
        pub const EvalVarObjectProbeKindAlias = EvalVarObjectProbeKind;
        pub const PrivateFieldResolutionAlias = PrivateFieldResolution;

        pub const decodeScopeOperand = binding_rules.decodeScopeOperand;
        pub const markEvalCapturedVariables = binding_rules.markEvalCapturedVariables;
        pub const encodeEvalScopeHead = binding_rules.encodeEvalScopeHead;
        pub const resolveBindingTopology = binding_rules.resolveBindingTopologyV2;
        pub const resolveScopeVarBindingTopology = binding_rules.resolveScopeVarBindingTopologyV2;
        pub const resolveScopeVarPlan = binding_rules.resolveScopeVarPlanV2;
        pub const resolvedScopeVarPlanBinding = ResolvedScopeVarPlan.binding;
        pub const resolvedScopeVarPlanAction = ResolvedScopeVarPlan.action;
        pub const planScopeVarLowering = binding_rules.planScopeVarLowering;
        pub const planResolvedScopeVarAction = binding_rules.planResolvedScopeVarAction;
        pub const scopeVarActionSize = ScopeVarAction.size;
        pub const scopeVarActionAtomCount = ScopeVarAction.atomCount;
        pub const writeScopeVarAction = binding_rules.writeScopeVarAction;
        pub const functionHasDynamicEnvObjects = binding_rules.functionHasDynamicEnvObjects;
        pub const closureVarRangeHasDynamicEnvObjects = binding_rules.closureVarRangeHasDynamicEnvObjects;

        pub const scopeVarProbeKind = binding_rules.scopeVarProbeKind;
        pub const scopeVarProbeWireKind = EvalVarObjectProbeKind.wireKind;
        pub const evalVarObjectProbePlan = binding_rules.evalVarObjectProbePlan;
        pub const scopeVarDynamicProbeEligible = binding_rules.scopeVarDynamicProbeEligible;
        pub const evalVarObjectProbeAccessorSize = binding_rules.evalVarObjectProbeAccessorSize;
        pub const writeEvalVarObjectProbeAccessor = binding_rules.writeEvalVarObjectProbeAccessor;
        pub const localWithProbeIteratorInit = LocalWithProbeIterator.init;
        pub const localWithProbeIteratorNext = LocalWithProbeIterator.next;
        pub const closureDynamicEnvProbeIteratorInit = ClosureDynamicEnvProbeIterator.init;
        pub const closureDynamicEnvProbeIteratorInitResolved = binding_rules.closureDynamicEnvProbeIteratorInitResolved;
        pub const closureDynamicEnvProbeIteratorNext = ClosureDynamicEnvProbeIterator.next;
        pub const staticBindingStopsDynamicEnvProbes = binding_rules.staticBindingStopsDynamicEnvProbes;
        pub const resolvedBindingStopsDynamicEnvProbes = binding_rules.resolvedBindingStopsDynamicEnvProbes;
        pub const scopeUsesArgumentEnvironmentOnly = binding_rules.scopeUsesArgumentEnvironmentOnly;
        pub const evalVarObjectClosureProbe = binding_rules.evalVarObjectClosureProbe;
        pub const evalVarObjectProbeIsWith = binding_rules.evalVarObjectProbeIsWith;

        pub const loweredScopeDeleteVarSize = binding_rules.loweredScopeDeleteVarSize;
        pub const writeLoweredScopeDeleteVar = binding_rules.writeLoweredScopeDeleteVar;
        pub const loweredScopeGetRefSize = binding_rules.loweredScopeGetRefSize;
        pub const writeLoweredScopeGetRef = binding_rules.writeLoweredScopeGetRef;
        pub const loweredScopeMakeRefSize = binding_rules.loweredScopeMakeRefSize;
        pub const loweredScopeMakeRefAtomCount = binding_rules.loweredScopeMakeRefAtomCount;
        pub const writeLoweredScopeMakeRef = binding_rules.writeLoweredScopeMakeRef;
        pub const markReferenceTakenBinding = binding_rules.markReferenceTakenBinding;
        pub const makeRefBindingIsGlobal = binding_rules.makeRefBindingIsGlobal;
        pub const canOptimizeGlobalRefPutTail = binding_rules.canOptimizeGlobalRefPutTail;

        pub const resolvePrivateBindingTopology = binding_rules.resolvePrivateBindingTopology;
        pub const resolvePrivateField = binding_rules.resolvePrivateField;
        pub const loweredPrivateFieldSize = binding_rules.loweredPrivateFieldSize;
        pub const loweredPrivateFieldAtomCount = binding_rules.loweredPrivateFieldAtomCount;
        pub const writeLoweredPrivateField = binding_rules.writeLoweredPrivateField;

        pub const enterScopeRefreshSize = binding_rules.enterScopeRefreshSize;
        pub const writeEnterScopeRefresh = binding_rules.writeEnterScopeRefresh;
        pub const leaveScopeCloseSize = binding_rules.leaveScopeCloseSize;
        pub const writeLeaveScopeClose = binding_rules.writeLeaveScopeClose;

        pub const resolveEvalGlobalVarTargets = binding_rules.resolveEvalGlobalVarTargets;
        pub const hasDirectEvalLexicalRedeclaration = binding_rules.hasDirectEvalLexicalRedeclaration;
        pub const throw_error_instr_size = binding_rules.throw_error_instr_size;
        pub const writeThrowVarRedeclaration = binding_rules.writeThrowVarRedeclaration;
    };
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
    const bulk_memory = @import("core/bulk_memory.zig");

    /// `JS_STACK_SIZE_MAX` mirror.
    pub const JS_STACK_SIZE_MAX: u16 = 0xFFFE;

    /// Sentinel: pc has not yet been visited.
    const STACK_LEVEL_UNVISITED: u16 = 0xFFFF;

    const ScratchRow = struct {
        stack_level: u16,
        catch_pos: i32,
        pending_pc: u32,
    };
    const scratch_bytes_per_position =
        @sizeOf(@FieldType(ScratchRow, "stack_level")) +
        @sizeOf(@FieldType(ScratchRow, "catch_pos")) +
        @sizeOf(@FieldType(ScratchRow, "pending_pc"));
    const stack_scratch_position_capacity = 256;
    const stack_scratch_bytes =
        stack_scratch_position_capacity * scratch_bytes_per_position +
        @alignOf(i32) - 1;

    pub const Error = error{
        StackUnderflow,
        StackOverflow,
        StackMismatch,
        InvalidOpcode,
        InvalidFinalArtifact,
        BytecodeOverflow,
        ReachableFalloff,
        OutOfMemory,
    };

    /// Extra production-artifact proof fused into the stack-size walk. The
    /// atom ledger is ordered by physical instruction position, so its cursor
    /// remains linear even though stack propagation follows the control-flow
    /// graph. Whenever the graph walk reaches that linear frontier, both
    /// proofs consume the same opcode metadata lookup.
    pub const FinalArtifactValidation = struct {
        atom_owners: []const u32,
        closure_var_count: usize,
    };

    /// Options for the BFS.
    pub const Options = struct {
        /// Fallback owner for verifier scratch that exceeds the small-function
        /// stack budget. The default preserves the standalone verifier API;
        /// production finalization supplies the runtime-accounted allocator.
        scratch_allocator: std.mem.Allocator = std.heap.page_allocator,

        /// When non-null, receives the return-balance proof: true iff every
        /// reachable `return` / `return_undef` terminator completes with an
        /// EMPTY operand stack once the return value is popped. The parser
        /// elides trailing expression-statement drops and keeps switch
        /// discriminants live across `return` (qjs releases both in the done:
        /// local_buf..sp loop, quickjs.c:20701-20706), so this is a
        /// per-return-site fact, not a validity check: `compute` still
        /// succeeds for unbalanced functions. Sole consumer is the zero-arg
        /// empty-leaf publication gate in final execution-flag publication, whose
        /// normal-return arm runs a narrow epilogue with no operand-release
        /// loop. Piggybacks on this BFS because the per-pc levels here are
        /// exact (`seed` rejects any pc revisited at a different level), so
        /// branchy-but-balanced bodies keep their proof — a linear scan would
        /// have to refuse them conservatively.
        returns_balanced_out: ?*bool = null,

        /// Packed-finalize-only validation. Standalone stack-size callers leave
        /// this null because their producing pipeline retains its own output
        /// proof.
        final_artifact: ?FinalArtifactValidation = null,
    };

    const FinalArtifactValidator = struct {
        config: FinalArtifactValidation,
        pc: usize = 0,
        owner_index: usize = 0,

        /// F0b: driven by the decoded header. The operand kinds carry what
        /// this used to rediscover from the format, and the two closure-slot
        /// arms collapse into one -- a `var_ref_slot` is a `var_ref_slot`
        /// whether its value sits in a payload byte or in the opcode.
        ///
        /// The arm that went away is the one P0-2 rules out by name: the old
        /// `none_var_ref` case recovered the slot as `op_id - get_var_ref0`,
        /// deriving a semantic operand from the physical id. That derivation
        /// loses its definition the moment an id is aliased or moved behind a
        /// carrier, which is exactly what this work does to ids.
        /// `inline` is load-bearing, not a hint. The unmigrated validator was
        /// small enough that LLVM inlined it into both walkers; the migrated
        /// one is not, and the per-instruction call was measured at 72M
        /// instructions on the CodeLoad compile path (2026-08-28).
        inline fn validateKnownInstruction(
            self: *FinalArtifactValidator,
            bytecode: []const u8,
            h: opcode.decode.Header,
        ) Error!void {
            const size: usize = h.size;
            if (size == 0 or size > bytecode.len - self.pc)
                return error.InvalidFinalArtifact;

            const lay = h.layout();
            if (lay.atom_slot) |i| {
                if (self.owner_index >= self.config.atom_owners.len)
                    return error.InvalidFinalArtifact;
                const encoded = opcode.decode.operandAt(h, bytecode, i, u32) catch
                    return error.InvalidFinalArtifact;
                if (encoded != self.config.atom_owners[self.owner_index])
                    return error.InvalidFinalArtifact;
                self.owner_index += 1;
            }
            if (lay.var_ref_slot) |i| {
                const idx = opcode.decode.operandAt(h, bytecode, i, u32) catch
                    return error.InvalidFinalArtifact;
                if (idx >= self.config.closure_var_count)
                    return error.InvalidFinalArtifact;
            }
            self.pc += size;
        }

        /// F0b behaviour change, deliberate: `headerAt` rejects an id that
        /// the ledger says is reclaimed, where the old metadata lookup would
        /// hand back the `unused_N` row and walk it as a one-byte
        /// instruction. A reclaimed id must never appear in a final artifact
        /// (11.5 clause 2), so failing validation is the correct reading; the
        /// old path could have let one through.
        ///
        /// Validate physical instructions before `limit`. Overshooting `limit`
        /// is intentional: a malformed jump into an operand remains the stack
        /// verifier's diagnosis, while the linear proof still consumes the
        /// containing instruction exactly once as before this fusion.
        fn validateBefore(
            self: *FinalArtifactValidator,
            bytecode: []const u8,
            limit: usize,
        ) Error!void {
            while (self.pc < limit) {
                const h = opcode.decode.headerAt(.final, bytecode, @intCast(self.pc)) catch
                    return error.InvalidFinalArtifact;
                try self.validateKnownInstruction(bytecode, h);
            }
        }

        fn finish(self: *FinalArtifactValidator, bytecode: []const u8) Error!void {
            try self.validateBefore(bytecode, bytecode.len);
            if (self.pc != bytecode.len or self.owner_index != self.config.atom_owners.len)
                return error.InvalidFinalArtifact;
        }
    };

    /// Compute the maximum stack size required to execute `bytecode`.
    ///
    /// Rejects empty bytecode and every reachable fall-through past the final
    /// instruction: finalized production bodies must end in an explicit
    /// terminator on every path.
    pub fn compute(bytecode: []const u8, options: Options) Error!u16 {
        if (options.returns_balanced_out) |out| out.* = true;
        if (bytecode.len == 0) return error.ReachableFalloff;

        // MultiArrayList stores these fields as one tightly packed SoA owner:
        // 2 + 4 + 4 bytes per bytecode position. Check the exact allocation
        // arithmetic before initCapacity performs its unchecked multiply.
        _ = std.math.mul(usize, scratch_bytes_per_position, bytecode.len) catch
            return error.OutOfMemory;

        var stack_fallback = std.heap.stackFallback(stack_scratch_bytes, options.scratch_allocator);
        const scratch_allocator = stack_fallback.get();
        var scratch = try std.MultiArrayList(ScratchRow).initCapacity(scratch_allocator, bytecode.len);
        defer scratch.deinit(scratch_allocator);
        scratch.len = bytecode.len;
        const scratch_slices = scratch.slice();

        const stack_level_tab = scratch_slices.items(.stack_level);
        bulk_memory.fillByte(std.mem.sliceAsBytes(stack_level_tab), 0xff);
        const catch_pos_tab = scratch_slices.items(.catch_pos);
        // Match QuickJS compute_stack_size: catch_pos_tab does not need a
        // sentinel fill. `seed` publishes catch_pos before it publishes the pc
        // to pending_pc, and every later read is guarded by a visited
        // stack_level_tab entry.
        const pending_pc = scratch_slices.items(.pending_pc);
        var pending_len: usize = 0;
        var final_validator: ?FinalArtifactValidator = if (options.final_artifact) |config|
            .{ .config = config }
        else
            null;
        // Before this proof was fused, the stack verifier completed first and
        // the artifact walk ran only after it succeeded.  Keep that public
        // error priority: an artifact mismatch is remembered while the graph
        // walk continues, then reported only if the stack proof succeeds.
        var final_artifact_invalid = false;

        // Seed: entry pc=0 with stack level 0.
        try seed(stack_level_tab, catch_pos_tab, pending_pc, &pending_len, 0, 0, -1);

        var stack_len_max: u16 = 0;

        while (pending_len != 0) {
            pending_len -= 1;
            const pos = pending_pc[pending_len];
            var stack_len = stack_level_tab[pos];
            var catch_pos = catch_pos_tab[pos];
            // F0b: one structured decode per instruction. Nothing below reads
            // a payload byte by hand, and the control-flow switch keys on the
            // logical form rather than the physical id -- which is the point:
            // a reclaimed or re-encoded id must not silently change what this
            // pass believes an instruction is.
            const h = opcode.decode.headerAt(.final, bytecode, pos) catch |err| switch (err) {
                error.InvalidOpcode => return error.InvalidOpcode,
                error.BytecodeOverflow => return error.BytecodeOverflow,
            };
            if (!final_artifact_invalid) {
                if (final_validator) |*validator| {
                    validator.validateBefore(bytecode, pos) catch |err| switch (err) {
                        error.InvalidFinalArtifact => final_artifact_invalid = true,
                        else => return err,
                    };
                }
            }
            if (h.form == .invalid) return error.InvalidOpcode;
            // Both proofs now share the one decoded header instead of a
            // separately looked-up metadata row.
            const pos_next = h.next_pc();

            // Effects come from the declaration, not from a format switch
            // here. `npop`, `npop_u16` and `npopx` (call0..3, whose count is
            // burned into the opcode) all evaluate the same affine
            // expression, and `using`/`dyn_env_probe` read their operand
            // table -- the three special cases this pass used to carry are
            // now one call.
            const effect = opcode.decode.stackEffect(h, bytecode) catch |err| switch (err) {
                error.InvalidOpcode => return error.InvalidOpcode,
                error.BytecodeOverflow => return error.BytecodeOverflow,
            };
            const n_pop: u32 = effect.pop;
            const n_push: u32 = effect.push;
            // Two opcodes carry their stack effect in an operand byte instead
            // of the table: the `using` cold plane's sub-opcode, and
            // `dyn_env_probe`'s kind.
            var dyn_env_flags: ?opcode.dyn_env.Flags = null;
            // Only the branch edge still needs the decoded flags; the
            // fall-through effect already came from `stackEffect`.
            if (h.form == .dyn_env_probe) {
                const raw = opcode.decode.operandAt(h, bytecode, 2, u8) catch
                    return error.BytecodeOverflow;
                dyn_env_flags = opcode.dyn_env.decode(raw) orelse return error.InvalidOpcode;
            }

            if (stack_len < n_pop) {
                return error.StackUnderflow;
            }
            const new_stack_i32: i32 = @as(i32, stack_len) - @as(i32, @intCast(n_pop)) + @as(i32, @intCast(n_push));
            if (new_stack_i32 < 0) return error.StackUnderflow;
            if (new_stack_i32 > JS_STACK_SIZE_MAX) return error.StackOverflow;
            stack_len = @intCast(new_stack_i32);
            if (stack_len > stack_len_max) stack_len_max = stack_len;

            if (!final_artifact_invalid) {
                if (final_validator) |*validator| {
                    if (validator.pc == pos) {
                        validator.validateKnownInstruction(bytecode, h) catch |err| switch (err) {
                            error.InvalidFinalArtifact => final_artifact_invalid = true,
                            else => return err,
                        };
                    }
                }
            }

            // QuickJS dispatches directly on the numeric opcode. Apart from
            // avoiding string comparisons, this keeps all control-flow
            // classification auditable against compute_stack_size's switch.
            switch (h.form) {
                .@"return", .return_undef => {
                    // `stack_len` already includes the return-value pop.
                    if (stack_len != 0) {
                        if (options.returns_balanced_out) |out| out.* = false;
                    }
                    continue;
                },
                .return_async,
                .throw,
                .throw_error,
                .tail_call,
                .tail_call_method,
                .ret,
                => continue,
                .goto, .goto16, .goto8 => {
                    const target = try opcode.decode.targetOfLabel(h, bytecode, 0);
                    try seed(stack_level_tab, catch_pos_tab, pending_pc, &pending_len, target, stack_len, catch_pos);
                    continue;
                },
                .if_true, .if_false, .if_true8, .if_false8 => {
                    const target = try opcode.decode.targetOfLabel(h, bytecode, 0);
                    try seed(stack_level_tab, catch_pos_tab, pending_pc, &pending_len, target, stack_len, catch_pos);
                },
                .gosub => {
                    const target = try opcode.decode.targetOfLabel(h, bytecode, 0);
                    try seed(stack_level_tab, catch_pos_tab, pending_pc, &pending_len, target, stack_len + 1, catch_pos);
                },
                .dyn_env_probe => {
                    const target = try opcode.decode.targetOfLabel(h, bytecode, 1);
                    const delta = (dyn_env_flags orelse return error.InvalidOpcode).branchStackDelta();
                    const branch_level = @as(i32, stack_len) + delta;
                    if (branch_level < 0) return error.StackUnderflow;
                    if (branch_level > JS_STACK_SIZE_MAX) return error.StackOverflow;
                    try seed(stack_level_tab, catch_pos_tab, pending_pc, &pending_len, target, @intCast(branch_level), catch_pos);
                },
                .@"catch" => {
                    const target = try opcode.decode.targetOfLabel(h, bytecode, 0);
                    try seed(stack_level_tab, catch_pos_tab, pending_pc, &pending_len, target, stack_len, catch_pos);
                    catch_pos = @intCast(pos);
                },
                .for_of_start, .for_await_of_start => catch_pos = @intCast(pos),
                .drop, .nip, .iterator_close => {
                    const catch_level = switch (h.form) {
                        .iterator_close => stack_len + 2,
                        .nip => blk: {
                            if (stack_len == 0) return error.StackUnderflow;
                            break :blk stack_len - 1;
                        },
                        else => stack_len,
                    };
                    catch_pos = maybePopCatchPos(bytecode, stack_level_tab, catch_pos_tab, catch_pos, catch_level);
                },
                .nip_catch => {
                    if (catch_pos < 0) return error.InvalidOpcode;
                    const catch_idx: usize = @intCast(catch_pos);
                    stack_len = stack_level_tab[catch_idx];
                    if (!opcode.decode.matchesFormAt(bytecode, @intCast(catch_idx), .@"catch")) stack_len += 1;
                    stack_len += 1;
                    catch_pos = catch_pos_tab[catch_idx];
                },
                else => {},
            }

            // Fall-through.
            try seed(stack_level_tab, catch_pos_tab, pending_pc, &pending_len, pos_next, stack_len, catch_pos);
        }

        if (!final_artifact_invalid) {
            if (final_validator) |*validator| {
                validator.finish(bytecode) catch |err| switch (err) {
                    error.InvalidFinalArtifact => final_artifact_invalid = true,
                    else => return err,
                };
            }
        }
        if (final_artifact_invalid) return error.InvalidFinalArtifact;
        return stack_len_max;
    }

    fn seed(
        stack_level_tab: []u16,
        catch_pos_tab: []i32,
        pending_pc: []u32,
        pending_len: *usize,
        pos: u32,
        stack_len: u16,
        catch_pos: i32,
    ) Error!void {
        if (pos == stack_level_tab.len) return error.ReachableFalloff;
        if (pos > stack_level_tab.len) return error.BytecodeOverflow;
        const existing = stack_level_tab[pos];
        if (existing == STACK_LEVEL_UNVISITED) {
            stack_level_tab[pos] = stack_len;
            catch_pos_tab[pos] = catch_pos;
            std.debug.assert(pending_len.* < pending_pc.len);
            pending_pc[pending_len.*] = pos;
            pending_len.* += 1;
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

    test "stack_size: empty bytecode is reachable falloff" {
        try std.testing.expectError(error.ReachableFalloff, compute(&.{}, .{}));
    }

    test "stack_size: fused final artifact proof accepts owners and var refs" {
        const owned_atom: u32 = 700;
        var bc = [_]u8{0} ** 10;
        bc[0] = opcode.op.push_atom_value;
        std.mem.writeInt(u32, bc[1..5], owned_atom, .little);
        bc[5] = opcode.op.drop;
        bc[6] = opcode.op.get_var_ref;
        std.mem.writeInt(u16, bc[7..9], 0, .little);
        bc[9] = opcode.op.@"return";

        try std.testing.expectEqual(@as(u16, 1), try compute(&bc, .{
            .final_artifact = .{
                .atom_owners = &.{owned_atom},
                .closure_var_count = 1,
            },
        }));
    }

    test "stack_size: fused final artifact proof validates unreachable tail" {
        const encoded_atom: u32 = 701;
        const wrong_owner: u32 = 702;
        var bc = [_]u8{0} ** 6;
        bc[0] = opcode.op.return_undef;
        bc[1] = opcode.op.push_atom_value;
        std.mem.writeInt(u32, bc[2..6], encoded_atom, .little);

        try std.testing.expectError(error.InvalidFinalArtifact, compute(&bc, .{
            .final_artifact = .{
                .atom_owners = &.{wrong_owner},
                .closure_var_count = 0,
            },
        }));
    }

    test "stack_size: fused final artifact proof rejects wide and short var refs" {
        var wide = [_]u8{ opcode.op.get_var_ref, 1, 0, opcode.op.@"return" };
        try std.testing.expectError(error.InvalidFinalArtifact, compute(&wide, .{
            .final_artifact = .{ .atom_owners = &.{}, .closure_var_count = 1 },
        }));

        const short = [_]u8{ opcode.op.get_var_ref1, opcode.op.@"return" };
        try std.testing.expectError(error.InvalidFinalArtifact, compute(&short, .{
            .final_artifact = .{ .atom_owners = &.{}, .closure_var_count = 1 },
        }));
    }

    test "stack_size: fused final artifact proof preserves stack diagnostic priority" {
        const invalid_opcode = [_]u8{0xff};
        try std.testing.expectError(error.InvalidOpcode, compute(&invalid_opcode, .{
            .final_artifact = .{ .atom_owners = &.{}, .closure_var_count = 0 },
        }));

        const truncated_atom = [_]u8{opcode.op.push_atom_value};
        try std.testing.expectError(error.BytecodeOverflow, compute(&truncated_atom, .{
            .final_artifact = .{ .atom_owners = &.{}, .closure_var_count = 0 },
        }));

        const invalid_var_ref_with_underflow = [_]u8{
            opcode.op.put_var_ref,
            0,
            0,
            opcode.op.return_undef,
        };
        try std.testing.expectError(error.StackUnderflow, compute(&invalid_var_ref_with_underflow, .{
            .final_artifact = .{ .atom_owners = &.{}, .closure_var_count = 0 },
        }));

        const encoded_atom: u32 = 703;
        const wrong_owner: u32 = 704;
        var earlier_artifact_mismatch = [_]u8{0} ** 8;
        earlier_artifact_mismatch[0] = opcode.op.push_atom_value;
        std.mem.writeInt(u32, earlier_artifact_mismatch[1..5], encoded_atom, .little);
        earlier_artifact_mismatch[5] = opcode.op.drop;
        earlier_artifact_mismatch[6] = opcode.op.drop;
        earlier_artifact_mismatch[7] = opcode.op.return_undef;
        try std.testing.expectError(error.StackUnderflow, compute(&earlier_artifact_mismatch, .{
            .final_artifact = .{ .atom_owners = &.{wrong_owner}, .closure_var_count = 0 },
        }));
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

        // push_atom_value "a" ; push_const compiled_bytecode ; regexp ; return_undef
        var bc = [_]u8{0} ** 12;
        bc[0] = op.push_atom_value;
        bc[5] = op.push_const;
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
        // get_loc_check this ; swap ; call_method 0 ; drop ;
        // get_loc_checkthis this ; return
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
        bc[21] = op.get_loc_checkthis;
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
    const runtime_mod = @import("core/runtime.zig");
    const fb_mod = function_bytecode;
    const bytecode_function = function_mod;
    const function_def_mod = function_def;

    const pc2line = pipeline_pc2line;
    const stack_size = pipeline_stack_size;
    const JSValue = @import("core/value.zig").JSValue;
    const compiler = @import("compiler/root.zig");

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

    fn isVarInArgumentScope(vd: function_def_mod.VarDef) bool {
        return vd.var_name == atom.ids.home_object or
            vd.var_name == atom.ids.this_active_func or
            vd.var_name == atom.ids.new_target or
            vd.var_name == atom.ids.this_ or
            vd.var_name == atom.ids.arg_var_object or
            vd.var_kind == .function_name;
    }

    fn captureEvalParentLocal(
        target: *function_def_mod.FunctionDef,
        owner: *function_def_mod.FunctionDef,
        local_idx: usize,
        normalize_unscoped: bool,
    ) FinalizeError!void {
        if (local_idx > std.math.maxInt(u16)) return error.BytecodeOverflow;
        const source_idx: u16 = @intCast(local_idx);
        if (source_idx >= owner.vars.len) return error.InvalidBytecode;
        owner.captureLocal(source_idx) catch return error.InvalidBytecode;
        const vd = owner.vars[source_idx];
        // QuickJS add_eval_variables preserves scoped binding attributes, but
        // deliberately forwards ancestor unscoped locals as non-const NORMAL
        // rows. In particular, a named-function self binding loses its
        // FUNCTION_NAME write protection only along this descendant-eval path.
        _ = binding_rules.threadClosureSource(
            target,
            owner,
            source_idx,
            function_def_mod.ClosureVar.init(.{
                .closure_type = .local,
                .is_lexical = vd.is_lexical,
                .is_const = if (normalize_unscoped) false else vd.is_const,
                .var_kind = if (normalize_unscoped) .normal else vd.var_kind,
                .var_idx = source_idx,
                .var_name = vd.var_name,
            }),
            .local,
        ) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.BytecodeOverflow => error.BytecodeOverflow,
            else => error.InvalidBytecode,
        };
    }

    fn captureEvalParentArg(
        target: *function_def_mod.FunctionDef,
        owner: *function_def_mod.FunctionDef,
        arg_idx: usize,
    ) FinalizeError!void {
        if (arg_idx > std.math.maxInt(u16)) return error.BytecodeOverflow;
        const source_idx: u16 = @intCast(arg_idx);
        if (source_idx >= owner.args.len) return error.InvalidBytecode;
        owner.captureArg(source_idx) catch return error.InvalidBytecode;
        const arg = owner.args[source_idx];
        // Ancestor arguments use the same add_eval_variables normalization:
        // lexical provenance is retained, while const/kind are ordinary.
        _ = binding_rules.threadClosureSource(
            target,
            owner,
            source_idx,
            function_def_mod.ClosureVar.init(.{
                .closure_type = .arg,
                .is_lexical = arg.is_lexical,
                .is_const = false,
                .var_kind = .normal,
                .var_idx = source_idx,
                .var_name = arg.var_name,
            }),
            .arg,
        ) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.BytecodeOverflow => error.BytecodeOverflow,
            else => error.InvalidBytecode,
        };
    }

    fn addEvalVariables(fd: *function_def_mod.FunctionDef) FinalizeError!void {
        if (!fd.has_eval_call) return;

        if (!fd.is_eval and !fd.is_strict_mode) {
            if (fd.var_object_idx < 0) {
                fd.var_object_idx = fd.appendVar(.{
                    .var_name = atom.ids.var_object,
                    .scope_level = 0,
                    .scope_next = 0,
                    .var_kind = .normal,
                }) catch return error.OutOfMemory;
            }
            if (fd.has_parameter_expressions and fd.arg_var_object_idx < 0) {
                fd.arg_var_object_idx = fd.appendVar(.{
                    .var_name = atom.ids.arg_var_object,
                    .scope_level = 0,
                    .scope_next = 0,
                    .var_kind = .normal,
                }) catch return error.OutOfMemory;
            }
        }

        var has_this_binding = fd.has_this_binding;
        if (has_this_binding) {
            _ = fd.ensureThisBinding() catch return error.OutOfMemory;
            _ = fd.ensureNewTargetBinding() catch return error.OutOfMemory;
            if (fd.is_derived_class_constructor) {
                _ = fd.ensureThisActiveFunctionBinding() catch return error.OutOfMemory;
            }
            if (fd.has_home_object) _ = fd.ensureHomeObjectBinding() catch return error.OutOfMemory;
        }
        var has_arguments_binding = fd.has_arguments_binding;
        if (has_arguments_binding) {
            _ = fd.ensureArgumentsBinding() catch return error.OutOfMemory;
            if (fd.has_parameter_expressions and !fd.is_strict_mode) {
                fd.ensureArgumentsArgumentBinding() catch |err| return switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                    error.InvalidScope => error.InvalidBytecode,
                };
            }
        }
        if (fd.is_named_func_expr) _ = fd.ensureFuncExprSelfBinding() catch return error.OutOfMemory;

        for (fd.args, 0..) |_, arg_idx| try fd.captureArg(arg_idx);
        for (fd.vars, 0..) |vd, local_idx| {
            if (vd.scope_level != 0 or vd.var_name == atom.ids.ret or vd.var_name == atom.null_atom) continue;
            try fd.captureLocal(local_idx);
        }

        var maybe_parent = fd.parent;
        var visible_scope = fd.parent_scope_level;
        while (maybe_parent) |parent| {
            if (parent.finalization_state != .prepared) return error.InvalidBytecode;
            if (!has_this_binding and parent.has_this_binding) {
                _ = parent.ensureThisBinding() catch return error.OutOfMemory;
                _ = parent.ensureNewTargetBinding() catch return error.OutOfMemory;
                if (parent.is_derived_class_constructor) {
                    _ = parent.ensureThisActiveFunctionBinding() catch return error.OutOfMemory;
                }
                if (parent.has_home_object) _ = parent.ensureHomeObjectBinding() catch return error.OutOfMemory;
                has_this_binding = true;
            }
            if (!has_arguments_binding and parent.has_arguments_binding) {
                _ = parent.ensureArgumentsBinding() catch return error.OutOfMemory;
                has_arguments_binding = true;
            }
            if (parent.is_named_func_expr) _ = parent.ensureFuncExprSelfBinding() catch return error.OutOfMemory;

            if (visible_scope < 0 or @as(usize, @intCast(visible_scope)) >= parent.scopes.len) {
                return error.InvalidBytecode;
            }
            var scope_idx = parent.scopes[@intCast(visible_scope)].first;
            var visited: usize = 0;
            while (scope_idx >= 0) {
                if (@as(usize, @intCast(scope_idx)) >= parent.vars.len or visited >= parent.vars.len) {
                    return error.InvalidBytecode;
                }
                visited += 1;
                try captureEvalParentLocal(fd, parent, @intCast(scope_idx), false);
                scope_idx = parent.vars[@intCast(scope_idx)].scope_next;
            }

            if (scope_idx != function_bytecode.arg_scope_end) {
                if (scope_idx != -1) return error.InvalidBytecode;
                for (parent.args, 0..) |arg, arg_idx| {
                    if (arg.var_name == atom.null_atom) continue;
                    try captureEvalParentArg(fd, parent, arg_idx);
                }
                for (parent.vars, 0..) |vd, local_idx| {
                    if (vd.scope_level != 0 or vd.var_name == atom.ids.ret or vd.var_name == atom.null_atom) continue;
                    try captureEvalParentLocal(fd, parent, local_idx, true);
                }
            } else {
                for (parent.vars, 0..) |vd, local_idx| {
                    if (vd.scope_level == 0 and isVarInArgumentScope(vd)) {
                        try captureEvalParentLocal(fd, parent, local_idx, true);
                    }
                }
            }

            if (parent.is_eval) {
                for (parent.closure_var, 0..) |cv, closure_idx| {
                    switch (cv.closureType()) {
                        .global, .global_ref, .global_decl => continue,
                        .local, .arg, .ref, .module_decl, .module_import => {},
                    }
                    if (closure_idx > std.math.maxInt(u16)) return error.BytecodeOverflow;
                    _ = binding_rules.threadClosureSource(
                        fd,
                        parent,
                        @intCast(closure_idx),
                        cv,
                        .ref,
                    ) catch |err| return switch (err) {
                        error.OutOfMemory => error.OutOfMemory,
                        error.BytecodeOverflow => error.BytecodeOverflow,
                        else => error.InvalidBytecode,
                    };
                }
            }

            visible_scope = parent.parent_scope_level;
            maybe_parent = parent.parent;
        }
    }

    fn addGlobalVariables(fd: *function_def_mod.FunctionDef) FinalizeError!void {
        if (!fd.is_eval) return;
        var need_global_closures = true;
        if (fd.is_direct_eval and !fd.is_strict_mode) {
            for (fd.closure_var) |cv| {
                if (cv.var_name == atom.ids.var_object or cv.var_name == atom.ids.arg_var_object) {
                    need_global_closures = false;
                    break;
                }
            }
        }
        if (!need_global_closures) return;

        const closure_type: function_def_mod.ClosureType = if (fd.is_module) .module_decl else .global_decl;
        for (fd.global_vars, 0..) |gv, global_idx| {
            if (global_idx > std.math.maxInt(u16)) return error.BytecodeOverflow;
            const var_kind: function_def_mod.VarKind = if (gv.cpool_idx >= 0 and !gv.is_lexical)
                .global_function_decl
            else
                .normal;
            _ = fd.addClosureVar(.{
                .closure_type = closure_type,
                .is_lexical = gv.is_lexical,
                .is_const = gv.is_const,
                .var_kind = var_kind,
                .var_idx = @intCast(global_idx),
                .var_name = gv.var_name,
            }) catch return error.OutOfMemory;
        }
    }

    fn prepareCurrentBeforeChildren(
        fd: *function_def_mod.FunctionDef,
        root_module_record: ?*module.Record,
    ) FinalizeError!void {
        if (fd.finalization_state != .unprepared) return error.InvalidBytecode;
        if (fd.parent) |parent| {
            if (parent.finalization_state != .prepared) return error.InvalidBytecode;
        }

        // QCP-1 v2: resolve_variables_v2 validates its own compact input
        // (validateInput + fail-closed walk) when compileFunctionV2 consumes
        // the attached builder. There is no phase-1 code array to validate:
        // the compact Builder is the only lowering input the compiler accepts.
        if (fd.v2_builder == null) return error.InvalidBytecode;
        fd.var_ref_count = 0;
        for (fd.vars) |*vd| {
            vd.is_captured = false;
            vd.open_binding_idx = function_bytecode.no_open_binding;
        }
        for (fd.args) |*arg| {
            arg.is_captured = false;
            arg.open_binding_idx = function_bytecode.no_open_binding;
        }
        fd.rebuildFinalScopeLinks() catch return error.InvalidBytecode;
        try addEvalVariables(fd);
        try addGlobalVariables(fd);
        if (root_module_record) |record| {
            if (!fd.is_module) return error.InvalidBytecode;
            const max_closure_count = @as(usize, std.math.maxInt(u16)) + 1;
            if (fd.closure_var.len > max_closure_count) return error.BytecodeOverflow;
            for (record.imports) |entry| {
                if (entry.var_idx >= fd.closure_var.len) return error.InvalidBytecode;
                const closure = fd.closure_var[entry.var_idx];
                if (closure.var_name != entry.local_name) return error.InvalidBytecode;
                const expected_type: function_def_mod.ClosureType = if (entry.is_namespace)
                    .module_decl
                else
                    .module_import;
                if (closure.closureType() != expected_type) return error.InvalidBytecode;
            }
            for (record.exports) |*entry| {
                var var_idx: ?u16 = null;
                for (fd.closure_var, 0..) |closure, index| {
                    if (closure.var_name != entry.local_name) continue;
                    if (index > std.math.maxInt(u16)) return error.BytecodeOverflow;
                    var_idx = @intCast(index);
                    break;
                }
                entry.var_idx = var_idx orelse return error.ClosureVarNotFound;
            }
        }
        fd.finalization_state = .prepared;
    }

    /// Prove the finalized event-driven frame contract while source metadata
    /// is still available. No vars/args grouping is part of the contract:
    /// every assigned index must be unique and the complete set must be dense.
    fn validateOpenBindingIndices(fd: *const function_def_mod.FunctionDef, count: u16) FinalizeError!void {
        const seen = fd.memory.alloc(bool, count) catch return error.OutOfMemory;
        defer fd.memory.free(bool, seen);
        @memset(seen, false);

        var captured_count: u32 = 0;
        for (fd.vars) |vd| {
            if (!vd.is_captured) {
                if (vd.open_binding_idx != function_bytecode.no_open_binding) return error.InvalidBytecode;
                continue;
            }
            if (vd.open_binding_idx >= count) return error.InvalidBytecode;
            if (seen[vd.open_binding_idx]) return error.InvalidBytecode;
            seen[vd.open_binding_idx] = true;
            captured_count += 1;
        }
        for (fd.args) |arg| {
            if (!arg.is_captured) {
                if (arg.open_binding_idx != function_bytecode.no_open_binding) return error.InvalidBytecode;
                continue;
            }
            if (arg.open_binding_idx >= count) return error.InvalidBytecode;
            if (seen[arg.open_binding_idx]) return error.InvalidBytecode;
            seen[arg.open_binding_idx] = true;
            captured_count += 1;
        }
        if (captured_count != count or fd.var_ref_count != count) return error.InvalidBytecode;
    }

    /// Create a FunctionBytecode from a FunctionDef.
    ///
    /// This mirrors `js_create_function` at `quickjs.c:35401`. It:
    /// 1. Recursively processes child functions (child_list walk)
    /// 2. Runs all pipeline phases on the FunctionDef
    /// 3. Allocates and populates a FunctionBytecode structure
    /// 4. Returns the FunctionBytecode
    ///
    pub fn createFunctionBytecode(fd: *function_def_mod.FunctionDef, compile_context: CompileContext) FinalizeError![]fb_mod.FunctionBytecode {
        const disasm_enabled = std.c.getenv("ZJS_DISASM") != null;
        try validateRuntimeIdentity(fd, compile_context.realm.runtime);
        try installChildFunctionBytecodes(fd, null, compile_context, disasm_enabled);
        return createFunctionBytecodeAfterChildren(fd, compile_context, disasm_enabled);
    }

    /// Finalize an ECMAScript module root through the same canonical
    /// FunctionBytecode topology as script and eval roots. The record is
    /// borrowed during finalization; its local export indices are fixed before
    /// any child FunctionDef is traversed.
    pub fn createModuleFunctionBytecode(
        fd: *function_def_mod.FunctionDef,
        record: *module.Record,
        compile_context: CompileContext,
    ) FinalizeError![]fb_mod.FunctionBytecode {
        const disasm_enabled = std.c.getenv("ZJS_DISASM") != null;
        if (!fd.is_module) return error.InvalidBytecode;
        try validateRuntimeIdentity(fd, compile_context.realm.runtime);
        if (record.memory != fd.memory or record.atoms != fd.atoms) return error.InvalidBytecode;
        try installChildFunctionBytecodes(fd, record, compile_context, disasm_enabled);
        return createFunctionBytecodeAfterChildren(fd, compile_context, disasm_enabled);
    }

    fn validateRuntimeIdentity(fd: *const function_def_mod.FunctionDef, rt: *runtime_mod.JSRuntime) FinalizeError!void {
        // FunctionDef buffers and atom owners must be released by the same
        // Runtime that accounts, registers, and eventually destroys the FB.
        // Reject a mismatched public caller before any owner is moved.
        if (fd.memory != &rt.memory or fd.atoms != &rt.atoms) return error.InvalidBytecode;
    }

    fn validatePreLoweringArtifactShape(fd: *const function_def_mod.FunctionDef) FinalizeError!void {
        if (fd.arg_count < 0 or @as(usize, @intCast(fd.arg_count)) != fd.args.len) return error.InvalidBytecode;
        if (fd.var_count < 0 or @as(usize, @intCast(fd.var_count)) != fd.vars.len) return error.InvalidBytecode;
        if (fd.defined_arg_count < 0 or fd.defined_arg_count > fd.arg_count) return error.InvalidBytecode;
        if (fd.args.len > std.math.maxInt(u16) or
            fd.vars.len > std.math.maxInt(u16) or
            @as(usize, @intCast(fd.defined_arg_count)) > std.math.maxInt(u16))
        {
            return error.BytecodeOverflow;
        }
    }

    fn validateFinalArtifactShape(
        fd: *const function_def_mod.FunctionDef,
        lowered: *const bytecode_function.Bytecode,
    ) FinalizeError!usize {
        if (fd.arg_count < 0 or @as(usize, @intCast(fd.arg_count)) != fd.args.len) return error.InvalidBytecode;
        if (fd.var_count < 0 or @as(usize, @intCast(fd.var_count)) != fd.vars.len) return error.InvalidBytecode;
        if (fd.defined_arg_count < 0 or fd.defined_arg_count > fd.arg_count) return error.InvalidBytecode;
        if (fd.cpool_count < 0 or @as(usize, @intCast(fd.cpool_count)) != fd.cpool.len) return error.InvalidBytecode;
        if (fd.closure_var_count < 0 or @as(usize, @intCast(fd.closure_var_count)) != fd.closure_var.len) return error.InvalidBytecode;

        if (fd.args.len > std.math.maxInt(u16) or
            fd.vars.len > std.math.maxInt(u16) or
            @as(usize, @intCast(fd.defined_arg_count)) > std.math.maxInt(u16) or
            fd.cpool.len > std.math.maxInt(i32) or
            fd.closure_var.len > std.math.maxInt(i32) or
            lowered.code.len > std.math.maxInt(i32) or
            lowered.pc2line_buf.len > std.math.maxInt(i32))
        {
            return error.BytecodeOverflow;
        }
        if (fd.source_text) |source| {
            if (source.len > std.math.maxInt(i32)) return error.BytecodeOverflow;
            _ = std.math.add(usize, source.len, 1) catch return error.BytecodeOverflow;
        }
        return std.math.add(usize, fd.args.len, fd.vars.len) catch return error.BytecodeOverflow;
    }

    fn createFunctionBytecodeAfterChildren(
        fd: *function_def_mod.FunctionDef,
        compile_context: CompileContext,
        disasm_enabled: bool,
    ) FinalizeError![]fb_mod.FunctionBytecode {
        const rt = compile_context.realm.runtime;
        // Lowering publishes arg/var counts to u16 fields, so malformed or
        // oversized FunctionDefs must be rejected before it can cast them.
        try validatePreLoweringArtifactShape(fd);
        // The canonical lowering carrier has no diagnostic/name owners of its
        // own. FunctionDef remains the source of those owners until commit.
        var lowered = bytecode_function.Bytecode.init(fd.memory, fd.atoms, atom.null_atom);
        defer lowered.deinit(rt);
        lowered.line_num = fd.line_num;
        lowered.col_num = fd.col_num;
        // Finalization policy is fixed on FunctionDef before parsing and is
        // visible to every lowering phase, not patched onto the published FB
        // afterwards. This matters for strict-only frame geometry such as
        // mapped-arguments capture decisions.
        lowered.flags.is_strict = fd.is_strict_mode;
        lowered.flags.runtime_strict = compile_context.policy.runtime_strict;
        // QCP-1 v2 lowering releases its compact producer at the consumption
        // point and transfers final buffers to `lowered`. There is no second
        // backend: an absent Builder is a compile error, not a fallback.
        if (fd.finalization_state != .prepared) return error.InvalidBytecode;
        compiler.compileFunctionV2ForPackedFinalize(&lowered, fd) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidBytecode, error.NoFunctionDef, error.NoParentScope => return error.InvalidBytecode,
            error.BytecodeOverflow => return error.BytecodeOverflow,
            error.ClosureVarNotFound => return error.ClosureVarNotFound,
        };
        std.debug.assert(fd.v2_builder == null);
        fd.consumeGlobalVars();
        fd.finalization_state = .resolved;
        fd.use_short_opcodes = true;
        try publishLoweredMetadata(true, true, &lowered, fd, fd, false);

        _ = try validateFinalArtifactShape(fd, &lowered);

        // Preflight the exact packed FunctionBytecode layout before the first
        // artifact allocation. Source and pc2line remain independent moved
        // owners, matching QuickJS's debug-tail ownership.
        if (lowered.code.len == 0) return error.InvalidBytecode;
        const layout = try fb_mod.FunctionLayout.init(
            true,
            true,
            fd.cpool.len,
            fd.args.len,
            fd.vars.len,
            fd.closure_var.len,
            lowered.code.len,
        );

        // Every fallible artifact allocation happens before owner commit.
        const fb = try fb_mod.FunctionBytecode.createProductionShell(fd.memory, layout);
        const slice = fb[0..1];
        var shell_owned = true;
        errdefer if (shell_owned) fd.memory.destroyWithFam(fb_mod.FunctionBytecode, fb, layout.famBytes());
        const dbg = fb.debugInfoMut().?;
        const hot_extension = layout.hotExtensionPtrMut(fb).?;

        // Populate owner-free FAM storage. Code bytes contain numeric atom IDs,
        // while every row/value slot is initialized with its non-owning null
        // sentinel. An allocation failure above can therefore free the single
        // raw FB allocation without touching FunctionDef's owners.
        const cpool = layout.cpoolSliceMut(fb);
        const vardefs = layout.vardefsSliceMut(fb);
        for (fd.args, vardefs[0..fd.args.len]) |arg, *out| {
            out.* = fb_mod.BytecodeVarDef.fromCompile(arg, arg.scope_next);
            out.var_name = atom.null_atom;
        }
        for (fd.vars, vardefs[fd.args.len..]) |local, *out| {
            out.* = fb_mod.BytecodeVarDef.fromCompile(local, local.scope_next);
            out.var_name = atom.null_atom;
        }

        const closure_var = layout.closureVarSliceMut(fb);
        for (fd.closure_var, closure_var) |compile_cv, *runtime_cv| {
            runtime_cv.* = compile_cv;
            runtime_cv.var_name = atom.null_atom;
        }

        const byte_code = layout.byteCodeSliceMut(fb);
        @memcpy(byte_code, lowered.code);

        // --- No-fail owner commit. No `try` or allocation is allowed below. ---
        fb.applyFlags(.{
            .is_strict_mode = fd.is_strict_mode,
            .runtime_strict_mode = compile_context.policy.runtime_strict,
            .has_prototype = fd.has_prototype,
            .has_simple_parameter_list = fd.has_simple_parameter_list,
            .is_derived_class_constructor = fd.is_derived_class_constructor,
            .need_home_object = fd.need_home_object,
            .func_kind = fd.func_kind,
            .new_target_allowed = fd.new_target_allowed,
            .super_call_allowed = fd.super_call_allowed,
            .super_allowed = fd.super_allowed,
            .arguments_allowed = fd.arguments_allowed,
            .is_direct_or_indirect_eval = fd.is_direct_eval or fd.is_indirect_eval,
        });
        fb.defined_arg_count = @intCast(fd.defined_arg_count);
        fb.stack_size = lowered.stack_size;
        fb.var_ref_count = lowered.open_var_ref_count;

        // Realm retention is an infallible refcount operation and belongs to
        // the no-fail commit, matching QuickJS's late JS_DupContext.
        fb.realm = @TypeOf(fb.realm).retain(compile_context.realm);

        fb.func_name = fd.func_name;
        fd.func_name = atom.null_atom;
        dbg.filename = fd.filename;
        fd.filename = atom.null_atom;
        hot_extension.script_or_module = fd.script_or_module;
        fd.script_or_module = atom.null_atom;

        for (fd.args, vardefs[0..fd.args.len]) |*arg, *out| {
            out.var_name = arg.var_name;
            arg.var_name = atom.null_atom;
        }
        for (fd.vars, vardefs[fd.args.len..][0..fd.vars.len]) |*local, *out| {
            out.var_name = local.var_name;
            local.var_name = atom.null_atom;
        }
        for (fd.closure_var, closure_var) |*compile_cv, *runtime_cv| {
            runtime_cv.var_name = compile_cv.var_name;
            compile_cv.var_name = atom.null_atom;
        }

        for (fd.cpool, cpool) |*source, *out| {
            out.* = source.*;
            source.* = JSValue.undefinedValue();
        }
        fd.cpool_count = 0;

        // The copied code is now authoritative for these atom owners. Clear
        // every scratch-ledger slot without changing its backing pointer or
        // capacity; lowered.deinit then frees only the raw backing allocation.
        for (lowered.atom_operands) |*owner| owner.* = atom.null_atom;

        const pc2line_buf = lowered.pc2line_buf;
        lowered.pc2line_buf = &.{};
        lowered.owns_pc2line_buf = false;
        dbg.pc2line_buf = if (pc2line_buf.len == 0) null else pc2line_buf.ptr;
        dbg.pc2line_len = @intCast(pc2line_buf.len);

        if (fd.source_text) |source| {
            dbg.source_ptr = source.ptr;
            dbg.source_len = @intCast(source.len);
            fd.source_text = null;
        }

        bytecode_function.publishExecutionFlags(
            fb,
            lowered.flags.materializes_arguments_object,
            lowered.flags.has_mapped_arguments,
            lowered.leaf_returns_balanced,
            fd.has_eval_call,
            fd.is_derived_class_constructor or
                fd.func_type == .class_constructor or
                fd.func_type == .derived_class_constructor,
            fd.is_module,
        );

        shell_owned = false;
        rt.gc.addInitializedWithSizeNoFail(&fb.header, fb.heapByteSizeWithLayout(layout));

        if (disasm_enabled) {
            const dump_mod = bytecode_dump;
            var disbuf: [65536]u8 = undefined;
            var diswriter = std.Io.Writer.fixed(&disbuf);
            dump_mod.dumpFunctionBytecode(&diswriter, fb, &rt.atoms, .{ .show_raw_bytes = true }) catch {};
            std.debug.print("{s}\n", .{diswriter.buffered()});
        }
        return slice;
    }

    /// Lower a compile/execution `Bytecode` from the compact V2 producer.
    ///
    /// This path is used by callers that execute a `Bytecode` object directly
    /// instead of first materialising a GC-owned `FunctionBytecode` artifact.
    /// There is exactly one backend: `compiler`. A `FunctionDef` without an
    /// attached `Builder` has no compiler input and fails closed.
    ///
    /// `createFunctionBytecode` is the QuickJS-style storage path. It lowers a
    /// `FunctionDef`, stores the result in `FunctionBytecode`, and the VM
    /// executes that finalized record directly.
    ///
    /// Variant that consumes a `FunctionDef` for local-slot lookup: the V2
    /// resolve pass lowers `scope_get_var` / `scope_put_var` to `get_loc` /
    /// `put_loc` for any atom found in `fd.vars`, and propagates
    /// `fd.var_count` onto the produced `Bytecode.var_count` so the VM frame
    /// can size its locals array.
    pub fn runWithFunctionDef(
        function: *bytecode_function.Bytecode,
        fd: *function_def_mod.FunctionDef,
    ) !void {
        if (fd.child_list.len != 0) return error.InvalidBytecode;
        try prepareCurrentBeforeChildren(fd, null);
        try lowerAttachedBuilder(function, fd);
        try syncFunctionDefCpool(function, fd);
    }

    /// JSRuntime-aware variant used when the parser produced FunctionDef child
    /// entries. It recursively materialises child FunctionBytecode objects and
    /// installs them into the executable Bytecode constant pool so `fclosure*`
    /// operands have real callees.
    pub fn runWithFunctionDefRuntime(
        function: *bytecode_function.Bytecode,
        fd: *function_def_mod.FunctionDef,
        compile_context: CompileContext,
    ) !void {
        const rt = compile_context.realm.runtime;
        const disasm_enabled = std.c.getenv("ZJS_DISASM") != null;
        if (function.memory != &rt.memory or function.atoms != &rt.atoms or
            function.memory != fd.memory or function.atoms != fd.atoms)
        {
            return error.InvalidBytecode;
        }
        try installChildFunctionBytecodes(fd, null, compile_context, disasm_enabled);
        try syncFunctionDefCpool(function, fd);
        try lowerAttachedBuilder(function, fd);
    }

    /// The lowering `createFunctionBytecode` performs for a FunctionDef that
    /// carries a compact Builder, factored out so the fragment-level entries
    /// above reach the same product the production path publishes.
    fn lowerAttachedBuilder(
        function: *bytecode_function.Bytecode,
        def: *function_def_mod.FunctionDef,
    ) !void {
        if (def.finalization_state != .prepared) return error.InvalidBytecode;
        try compiler.compileFunctionV2(function, def);
        std.debug.assert(def.v2_builder == null);
        def.consumeGlobalVars();
        def.finalization_state = .resolved;
        def.use_short_opcodes = true;
        try publishLoweredMetadata(true, false, function, def, def, true);
    }

    fn publishLoweredMetadata(
        comptime arguments_object_from_function_def: bool,
        comptime validate_final_artifact: bool,
        function: *bytecode_function.Bytecode,
        fd: ?*const function_def_mod.FunctionDef,
        fd_mut: ?*function_def_mod.FunctionDef,
        publish_mutable_metadata: bool,
    ) !void {

        // qjs captures every formal parameter before creating a mapped
        // arguments object. Do the same here, then assign one exact, stable
        // table index to every captured local/argument. Runtime frame sizing
        // and every identity consumer use this metadata; there is no
        // address-search or "extra capacity" fallback.
        if (fd_mut) |def| {
            // resolve_variables marks each direct-eval chain in bytecode order
            // while converting its parser scope operand to the final chain head.
            // Production V2's only arguments-object producer is the S4
            // prologue, emitted from this exact QuickJS identity field. Keep
            // the general final-code scan for synthetic and legacy callers.
            const materializes_arguments_object = if (comptime arguments_object_from_function_def)
                def.arguments_var_idx >= 0
            else
                bytecode_function.codeMaterializesArgumentsObject(function.code);
            function.flags.materializes_arguments_object = materializes_arguments_object;
            const mapped_arguments = !def.is_strict_mode and
                !function.flags.runtime_strict and
                def.has_simple_parameter_list and
                materializes_arguments_object;
            function.flags.has_mapped_arguments = mapped_arguments;
            if (mapped_arguments) {
                for (def.args, 0..) |_, arg_idx| try def.captureArg(arg_idx);
            }
            // `no_open_binding` is the sentinel index, so 65,535 captured
            // bindings (valid indices 0...65,534) are representable.
            if (def.var_ref_count < 0 or def.var_ref_count > function_bytecode.no_open_binding) return error.BytecodeOverflow;
            function.open_var_ref_count = @intCast(def.var_ref_count);
            try validateOpenBindingIndices(def, function.open_var_ref_count);
        }

        // Propagate locals count so the VM frame can size its `locals`
        // array. `createFunctionBytecode` copies the same lowered metadata
        // into the final GC-owned function artifact.
        if (fd) |def| {
            // The mutable root Bytecode is the Zig-only execution twin of
            // QuickJS's FunctionBytecode. Keep the construction gate on the
            // artifact itself; callers and test helpers must not have to
            // remember to republish FunctionDef.is_global_var separately.
            function.flags.is_global_var = def.is_global_var;
            function.entry_contract = .{
                .new_target_allowed = def.new_target_allowed,
                .super_call_allowed = def.super_call_allowed,
                .super_allowed = def.super_allowed,
                .arguments_allowed = def.arguments_allowed,
            };
            if (def.var_count >= 0) {
                function.var_count = @intCast(def.var_count);
            }
            if (def.arg_count >= 0) {
                function.arg_count = @intCast(def.arg_count);
            }
            if (publish_mutable_metadata) {
                try syncBytecodeVarNames(function, def);
                try syncBytecodeArgDefs(function, def);
                try syncBytecodeVarRefNames(function, def);
            }
        }

        // Phase 3b: pc2line from remapped Bytecode source slots.
        try encodePc2Line(function);

        // Phase 3c: compute_stack_size over resolved QuickJS-format bytecode.
        // The packed production path folds its final topology, atom-owner and
        // var-ref proof into this walk. Direct Bytecode callers retain the
        // self-contained resolve_labels proof and do not repeat it here.
        const FinalArtifact = if (validate_final_artifact) stack_size.FinalArtifactValidation else void;
        const final_artifact: FinalArtifact = if (comptime validate_final_artifact) blk: {
            const def = fd orelse return error.InvalidBytecode;
            break :blk .{
                .atom_owners = function.atom_operands,
                .closure_var_count = def.closure_var.len,
            };
        } else {};
        function.stack_size = try computeStackSizeForCurrentBytecode(
            validate_final_artifact,
            function,
            &function.leaf_returns_balanced,
            final_artifact,
        );
    }

    // Keep the final bytecode verification walk as its own compiler stage.
    // Whole-program source deletion otherwise let Zig/LLVM fold this into the
    // packed finalizer; the resulting backend-stall regression was the carrier
    // behind QCP-1B's crypto/code-load shift. See the decision record §9.3.
    noinline fn computeStackSizeForCurrentBytecode(
        comptime validate_final_artifact: bool,
        function: *bytecode_function.Bytecode,
        leaf_returns_balanced: *bool,
        final_artifact: if (validate_final_artifact) stack_size.FinalArtifactValidation else void,
    ) FinalizeError!u16 {
        // Parser compilation switches MemoryAccount.allocator to the stable,
        // accounted artifact allocator before entering finalization. Direct
        // finalize callers likewise carry the runtime's current allocator.
        return stack_size.compute(function.code, .{
            .scratch_allocator = function.memory.allocator,
            .returns_balanced_out = leaf_returns_balanced,
            .final_artifact = if (comptime validate_final_artifact) final_artifact else null,
        }) catch |err| switch (err) {
            // Reachable falloff is a verifier diagnosis; consumers of the
            // finalize pipeline observe the established invalid-bytecode API.
            error.ReachableFalloff => error.InvalidBytecode,
            error.InvalidFinalArtifact => error.InvalidBytecode,
            else => |other| other,
        };
    }

    fn encodePc2Line(function: *bytecode_function.Bytecode) !void {
        var encoded = try pc2line.encode(function.memory, function.source_loc_slots, function.line_num, function.col_num);
        defer encoded.deinit();
        // `encode` already produced the exact-sized final owner. Transfer it
        // into the lowered carrier; FunctionBytecode takes the same allocation
        // at commit, so no temporary/copy/shrink path remains.
        function.installPc2Line(encoded.bytes);
        encoded.bytes = &.{};
    }

    fn syncBytecodeVarNames(function: *bytecode_function.Bytecode, fd: *const function_def_mod.FunctionDef) !void {
        if (function.vardefs.len != 0) {
            const vardefs = function.vardefs;
            function.vardefs = &.{};
            for (vardefs) |*v| function.atoms.free(v.var_name);
            function.memory.free(fb_mod.BytecodeVarDef, vardefs);
        }
        if (fd.vars.len == 0) return;

        const vardefs = try function.memory.alloc(fb_mod.BytecodeVarDef, fd.vars.len);
        var initialized: usize = 0;
        errdefer {
            for (vardefs[0..initialized]) |*v| function.atoms.free(v.var_name);
            function.memory.free(fb_mod.BytecodeVarDef, vardefs);
        }
        for (fd.vars, 0..) |v, idx| {
            vardefs[idx] = fb_mod.BytecodeVarDef.fromCompile(v, v.scope_next);
            vardefs[idx].var_name = function.atoms.dup(v.var_name);
            initialized += 1;
        }
        function.vardefs = vardefs;
    }

    fn syncBytecodeArgDefs(function: *bytecode_function.Bytecode, fd: *const function_def_mod.FunctionDef) !void {
        if (function.argdefs.len != 0) {
            const argdefs = function.argdefs;
            function.argdefs = &.{};
            for (argdefs) |*arg| function.atoms.free(arg.var_name);
            function.memory.free(fb_mod.BytecodeVarDef, argdefs);
        }
        if (fd.args.len == 0) return;

        const argdefs = try function.memory.alloc(fb_mod.BytecodeVarDef, fd.args.len);
        var initialized: usize = 0;
        errdefer {
            for (argdefs[0..initialized]) |*arg| function.atoms.free(arg.var_name);
            function.memory.free(fb_mod.BytecodeVarDef, argdefs);
        }
        for (fd.args, argdefs) |arg, *out| {
            out.* = fb_mod.BytecodeVarDef.fromCompile(arg, arg.scope_next);
            out.var_name = function.atoms.dup(arg.var_name);
            initialized += 1;
        }
        function.argdefs = argdefs;
    }

    fn syncBytecodeVarRefNames(function: *bytecode_function.Bytecode, fd: *const function_def_mod.FunctionDef) !void {
        if (function.var_ref_names.len != 0) {
            const var_ref_names = function.var_ref_names;
            function.var_ref_names = &.{};
            for (var_ref_names) |atom_id| function.atoms.free(atom_id);
            function.memory.free(atom.Atom, var_ref_names);
        }
        if (function.closure_var.len != 0) {
            const closure_var = function.closure_var;
            function.closure_var = &.{};
            for (closure_var) |*cv| function.atoms.free(cv.var_name);
            function.memory.free(fb_mod.BytecodeClosureVar, closure_var);
        }
        if (fd.closure_var.len == 0) return;
        const names = try function.memory.alloc(atom.Atom, fd.closure_var.len);
        errdefer function.memory.free(atom.Atom, names);
        const closure_var = try function.memory.alloc(fb_mod.BytecodeClosureVar, fd.closure_var.len);
        var initialized: usize = 0;
        var initialized_closure: usize = 0;
        errdefer {
            for (names[0..initialized]) |atom_id| function.atoms.free(atom_id);
            for (closure_var[0..initialized_closure]) |*cv| function.atoms.free(cv.var_name);
            function.memory.free(fb_mod.BytecodeClosureVar, closure_var);
        }
        for (fd.closure_var, 0..) |cv, idx| {
            names[idx] = fd.atoms.dup(cv.var_name);
            closure_var[idx] = cv;
            closure_var[idx].var_name = fd.atoms.dup(cv.var_name);
            initialized += 1;
            initialized_closure += 1;
        }
        function.var_ref_names = names;
        function.closure_var = closure_var;
    }

    fn installChildFunctionBytecodes(
        fd: *function_def_mod.FunctionDef,
        root_module_record: ?*module.Record,
        compile_context: CompileContext,
        disasm_enabled: bool,
    ) FinalizeError!void {
        const rt = compile_context.realm.runtime;
        try validateRuntimeIdentity(fd, rt);
        const Frame = struct {
            function_def: *function_def_mod.FunctionDef,
            next_child: usize = 0,
        };

        var frames: std.ArrayList(Frame) = .empty;
        defer frames.deinit(fd.memory.allocator);
        try prepareCurrentBeforeChildren(fd, root_module_record);
        try frames.append(fd.memory.allocator, .{ .function_def = fd });

        while (frames.items.len != 0) {
            const frame_index = frames.items.len - 1;
            const current = frames.items[frame_index].function_def;
            if (frames.items[frame_index].next_child < current.child_list.len) {
                const child = current.child_list[frames.items[frame_index].next_child];
                frames.items[frame_index].next_child += 1;
                try validateRuntimeIdentity(child, rt);
                const cpool_idx = child.parent_cpool_idx;
                if (cpool_idx < 0 or @as(usize, @intCast(cpool_idx)) >= current.cpool.len) {
                    return error.InvalidBytecode;
                }
                try prepareCurrentBeforeChildren(child, null);
                try frames.append(fd.memory.allocator, .{ .function_def = child });
                continue;
            }

            _ = frames.pop();
            if (frames.items.len == 0) break;

            const parent = frames.items[frames.items.len - 1].function_def;
            const cpool_idx = current.parent_cpool_idx;
            const idx: usize = @intCast(cpool_idx);
            const fb_slice = try createFunctionBytecodeAfterChildren(current, compile_context, disasm_enabled);
            const fb = &fb_slice[0];
            const value = JSValue.functionBytecode(&fb.header);
            var value_owned = true;
            errdefer if (value_owned) value.free(rt);
            const old_value = parent.cpool[idx];
            parent.cpool[idx] = value;
            value_owned = false;
            old_value.free(rt);
        }
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
    const context = @import("core/context.zig");
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

    fn freeOwnedVarDefSlice(atoms: *atom.AtomTable, mem: *memory.MemoryAccount, slot: *[]function_bytecode_mod.BytecodeVarDef) void {
        const items = slot.*;
        slot.* = &.{};
        for (items) |*v| atoms.free(v.var_name);
        if (items.len != 0) mem.free(function_bytecode_mod.BytecodeVarDef, items);
    }

    fn freeOwnedClosureVarSlice(atoms: *atom.AtomTable, mem: *memory.MemoryAccount, slot: *[]function_bytecode_mod.BytecodeClosureVar) void {
        const items = slot.*;
        slot.* = &.{};
        for (items) |*cv| atoms.free(cv.var_name);
        if (items.len != 0) mem.free(function_bytecode_mod.BytecodeClosureVar, items);
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
        is_direct_or_indirect_eval: bool = false,
        /// Compile/finalize fact used to distinguish strict snapshot frames
        /// from strict functions that never create an arguments object.
        materializes_arguments_object: bool = false,
        /// Runtime-created mapped Arguments objects open-alias every supplied
        /// argument slot in addition to the statically captured bindings.
        has_mapped_arguments: bool = false,
        /// Exact-zero-argument sloppy plain-function leaf whose frame cannot
        /// acquire cold state or value-bearing local/capture/open-ref windows.
        /// Published in the previously reserved execution flag bit. The
        /// raw-`this` twin for strict plain functions lives in the
        /// `raw_this_inline_empty_leaf` field, so this established sloppy test
        /// stays single-bit while this packed carrier retains its u16 ABI.
        simple_inline_empty_leaf: bool = false,
        _reserved: u2 = 0,

        comptime {
            std.debug.assert(@sizeOf(@This()) == 2);
        }
    };

    /// Compatibility aliases for finalized runtime function bytecode.
    /// The GC object lives in core; bytecode keeps opcode-aware helpers below.
    /// Fused exact-args-leaf dispatch classification (see
    /// `BytecodeImpl.exact_args_leaf_kind`).
    pub const ExactArgsLeafKind = function_bytecode_mod.ExactArgsLeafKind;

    pub const BytecodeImpl = struct {
        memory: *memory.MemoryAccount,
        atoms: *atom.AtomTable,
        /// Borrowed realm pointer copied into the canonical FB. Mutable legacy
        /// module/test bytecode leaves this null and supplies its realm at the
        /// module/test entry boundary.
        realm: ?*context.RealmContext = null,
        name: atom.Atom,
        filename: atom.Atom,
        /// Stable ScriptOrModule identity used for host referrer resolution.
        /// It is separately owned because eval keeps filename "<eval>".
        script_or_module: atom.Atom,
        line_num: i32 = 1,
        col_num: i32 = 1,
        pc2line_buf: []u8 = &.{},
        owns_pc2line_buf: bool = false,
        source_loc_slots: []pipeline_pc2line.SourceLocSlot = &.{},
        source_loc_capacity: usize = 0,
        flags: Flags = .{},
        entry_contract: EntryContract = .{},
        /// Precomputed bytecode-only half of simple inline-call eligibility.
        /// Call-site predicates remain checked in the exec inline-call path.
        simple_inline_eligible: bool = false,
        /// Strict-mode twin of `simple_inline_eligible`. Kept separate so the
        /// established sloppy hot path does not gain a per-call strict-mode
        /// branch; inline_calls instantiates a dedicated strict setup whose
        /// only semantic difference is preserving an undefined plain `this`.
        strict_simple_inline_eligible: bool = false,
        /// Strict simple-frame variant that also snapshots the incoming args
        /// before mutable parameter slots can change them. Selected only when
        /// finalized bytecode materializes an arguments object.
        strict_simple_snapshot_inline_eligible: bool = false,
        /// Raw-`this` twin of `flags.simple_inline_empty_leaf` (the packed
        /// flags word remains a stable u16): identical empty-leaf frame
        /// geometry, published for strict-mode plain functions whose frame
        /// preserves the caller-supplied raw `this` word instead of
        /// substituting the sloppy realm global.
        /// Plain call sites select the undefined-`this` arm; the method
        /// receiver arm is mode-independent. Kept as a separate byte so
        /// the established sloppy call arms retain their exact single-bit
        /// test.
        raw_this_inline_empty_leaf: bool = false,
        /// Exact-args generalization of the empty-leaf family: same leaf body
        /// geometry (no locals/captures/open refs/arguments/direct eval) with
        /// `arg_count > 0`. A call site that supplies exactly `arg_count`
        /// arguments borrows them in place from the caller's operand region
        /// (qjs `arg_buf = argv`, quickjs.c:17841) and enters the warm leaf
        /// constructor. Published as two separate bytes mirroring the
        /// zero-arg family split (folding modes into one bit measured
        /// +3 insn/call on the established sloppy arm): this byte is the
        /// sloppy plain twin
        /// (`this` = realm global on plain calls).
        simple_inline_exact_args_leaf: bool = false,
        /// Raw-`this` twin of `simple_inline_exact_args_leaf`: strict plain
        /// functions preserving the raw incoming `this` word exactly like
        /// `raw_this_inline_empty_leaf`.
        raw_this_inline_exact_args_leaf: bool = false,
        /// Fused dispatch byte for the two exact-args policy bits above:
        /// one load answers "is this ANY exact-args leaf, and which `this`
        /// policy". The dominant real-world shape at the with-args call arms
        /// is a NON-leaf callee (locals, named-expression self-binding), so
        /// the miss must cost one byte test, not two (measured +1.3% insn on
        /// call-closure-two-arg from the two-byte chain). The bools stay
        /// published for asserts and eligibility tests.
        exact_args_leaf_kind: ExactArgsLeafKind = .none,
        /// Capture-leaf fused dispatch byte (O2): zero-arg callees whose ONLY
        /// frame window is the inherited capture array — `() => this.x`
        /// arrows (lexical `this` is an ordinary closure cell since the
        /// capture conversion) and zero-arg closures over upvalues. Same
        /// `leaf_body_geometry` as the exact-args family (no locals, no cell
        /// CREATION, no arguments/direct eval) with `arg_count == 0` and
        /// `closure_var_count > 0`, so the three leaf families partition cleanly:
        /// empty leaf owns argc==0 without captures, this byte owns argc==0
        /// with captures, exact-args owns argc==arg_count>0. The frame
        /// borrows the closure's cell array (qjs `var_refs =
        /// p->u.func.var_refs`, quickjs.c:17844; rooted by the owned
        /// callable) and publishes the `exact_args_leaf` teardown bit: its
        /// guarded return arm (callee operand window must be empty) is
        /// load-bearing here because inherited-capture bodies may read free
        /// names and leave parser-elided leftovers at `return`, and its args
        /// release loop zero-trips on the empty args window.
        capture_leaf_kind: ExactArgsLeafKind = .none,
        arg_count: u16 = 0,
        var_count: u16 = 0,
        stack_size: u16 = 0,
        open_var_ref_count: u16 = 0,
        /// Exact stack-BFS result published by the normal stack-size pass.
        /// This prevents leaf classification from rerunning an allocating scan
        /// when the FB is attached or first called.
        leaf_returns_balanced: bool = false,
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
        argdefs: []function_bytecode_mod.BytecodeVarDef = &.{},
        // Compact local rows borrowed from the final arguments+locals table (or
        // owned by the mutable root Bytecode path). `has_scope` replaces the
        // compile-only numeric scope level, exactly as in JSBytecodeVarDef.
        vardefs: []function_bytecode_mod.BytecodeVarDef = &.{},
        var_ref_names: []atom.Atom = &.{},
        // Lexical / const / top-level-global-decl (closure_type == .global_decl,
        // qjs JS_CLOSURE_GLOBAL_DECL) status per var-ref is derived on access
        // from `closure_var[idx]` via varRefIs{Lexical,Const,GlobalDecl}At; the
        // former parallel `[]bool` arrays were redundant copies of closure_var.
        closure_var: []function_bytecode_mod.BytecodeClosureVar = &.{},
        constants: constant.Pool,
        module_record: ?module.Record = null,
        /// Exact number of link-time function-declaration init pairs at the
        /// start of module bytecode. The module linker must not infer this
        /// boundary from opcode shape: executable module code can also begin
        /// with `fclosure*; put_var_ref*` (for example a named function
        /// expression initializing a lexical binding).
        debug_table: ?debug.Table = null,
        pub fn init(account: *memory.MemoryAccount, atoms: *atom.AtomTable, name: atom.Atom) BytecodeImpl {
            return .{
                .memory = account,
                .atoms = atoms,
                .name = atoms.dup(name),
                .filename = atoms.dup(name),
                .script_or_module = atoms.dup(name),
                .constants = constant.Pool.init(account, atoms),
            };
        }

        pub fn deinit(self: *BytecodeImpl, rt: anytype) void {
            const name = self.name;
            const filename = self.filename;
            const script_or_module = self.script_or_module;
            self.name = atom.null_atom;
            self.filename = atom.null_atom;
            self.script_or_module = atom.null_atom;
            self.atoms.free(name);
            self.atoms.free(filename);
            self.atoms.free(script_or_module);
            freeGrowableAtomSlice(self.atoms, self.memory, &self.atom_operands, &self.atom_operands_capacity);
            freeOwnedVarDefSlice(self.atoms, self.memory, &self.argdefs);
            freeOwnedVarDefSlice(self.atoms, self.memory, &self.vardefs);
            freeOwnedAtomSlice(self.atoms, self.memory, &self.var_ref_names);
            freeOwnedClosureVarSlice(self.atoms, self.memory, &self.closure_var);
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
            if (owns_pc2line_buf and pc2line_buf.len != 0) self.memory.free(u8, pc2line_buf);
        }

        pub inline fn byteCode(self: *const BytecodeImpl) []const u8 {
            return self.code;
        }
        pub inline fn funcName(self: *const BytecodeImpl) atom.Atom {
            return self.name;
        }
        pub inline fn argVarDefs(self: *const BytecodeImpl) []const function_bytecode_mod.BytecodeVarDef {
            return self.argdefs;
        }
        pub inline fn varDefs(self: *const BytecodeImpl) []const function_bytecode_mod.BytecodeVarDef {
            return self.vardefs;
        }
        pub inline fn closureVar(self: *const BytecodeImpl) []const function_bytecode_mod.BytecodeClosureVar {
            return self.closure_var;
        }
        pub inline fn cpoolSlice(self: *const BytecodeImpl) []const JSValue {
            return self.constants.values;
        }
        pub inline fn constantAt(self: *const BytecodeImpl, index: usize) ?JSValue {
            return self.constants.get(index);
        }
        pub inline fn pc2lineBuf(self: *const BytecodeImpl) []const u8 {
            return self.pc2line_buf;
        }
        pub inline fn lineNum(self: *const BytecodeImpl) i32 {
            return self.line_num;
        }
        pub inline fn colNum(self: *const BytecodeImpl) i32 {
            return self.col_num;
        }
        pub inline fn scriptOrModule(self: *const BytecodeImpl) atom.Atom {
            return self.script_or_module;
        }
        pub inline fn realmContext(self: *const BytecodeImpl) ?*context.RealmContext {
            return self.realm;
        }
        pub inline fn isGlobalVar(self: *const BytecodeImpl) bool {
            return self.flags.is_global_var;
        }
        pub inline fn isModule(self: *const BytecodeImpl) bool {
            return self.flags.is_module;
        }
        pub inline fn functionKind(self: *const BytecodeImpl) function_bytecode_mod.FunctionKind {
            return if (self.flags.is_async and self.flags.is_generator)
                .async_generator
            else if (self.flags.is_async)
                .async
            else if (self.flags.is_generator)
                .generator
            else
                .normal;
        }
        pub inline fn isDerivedClassConstructor(self: *const BytecodeImpl) bool {
            return self.flags.is_derived_class_constructor;
        }
        pub inline fn hasPrototype(self: *const BytecodeImpl) bool {
            return self.flags.has_prototype;
        }
        pub inline fn hasSimpleParameterList(self: *const BytecodeImpl) bool {
            return self.flags.has_simple_parameter_list;
        }
        pub inline fn needHomeObject(self: *const BytecodeImpl) bool {
            return self.flags.need_home_object;
        }
        pub inline fn newTargetAllowed(self: *const BytecodeImpl) bool {
            return self.entry_contract.new_target_allowed;
        }
        pub inline fn superCallAllowed(self: *const BytecodeImpl) bool {
            return self.entry_contract.super_call_allowed;
        }
        pub inline fn superAllowed(self: *const BytecodeImpl) bool {
            return self.entry_contract.super_allowed;
        }
        pub inline fn argumentsAllowed(self: *const BytecodeImpl) bool {
            return self.entry_contract.arguments_allowed;
        }
        pub inline fn isDirectOrIndirectEval(self: *const BytecodeImpl) bool {
            return self.flags.is_direct_or_indirect_eval;
        }
        pub inline fn isAsync(self: *const BytecodeImpl) bool {
            return self.flags.is_async;
        }
        pub inline fn isGenerator(self: *const BytecodeImpl) bool {
            return self.flags.is_generator;
        }
        pub inline fn entryContract(self: *const BytecodeImpl) EntryContract {
            return self.entry_contract;
        }
        pub inline fn isStrictMode(self: *const BytecodeImpl) bool {
            return self.flags.is_strict;
        }
        pub inline fn runtimeStrictMode(self: *const BytecodeImpl) bool {
            return self.flags.runtime_strict;
        }
        pub inline fn hasMappedArguments(self: *const BytecodeImpl) bool {
            return self.flags.has_mapped_arguments;
        }
        pub inline fn simpleInlineEligible(self: *const BytecodeImpl) bool {
            return self.simple_inline_eligible;
        }
        pub inline fn strictSimpleInlineEligible(self: *const BytecodeImpl) bool {
            return self.strict_simple_inline_eligible;
        }
        pub inline fn strictSimpleSnapshotInlineEligible(self: *const BytecodeImpl) bool {
            return self.strict_simple_snapshot_inline_eligible;
        }
        pub inline fn simpleInlineEmptyLeaf(self: *const BytecodeImpl) bool {
            return self.flags.simple_inline_empty_leaf;
        }
        pub inline fn rawThisInlineEmptyLeaf(self: *const BytecodeImpl) bool {
            return self.raw_this_inline_empty_leaf;
        }
        pub inline fn simpleInlineExactArgsLeaf(self: *const BytecodeImpl) bool {
            return self.simple_inline_exact_args_leaf;
        }
        pub inline fn rawThisInlineExactArgsLeaf(self: *const BytecodeImpl) bool {
            return self.raw_this_inline_exact_args_leaf;
        }
        pub inline fn exactArgsLeafKind(self: *const BytecodeImpl) function_bytecode_mod.ExactArgsLeafKind {
            return self.exact_args_leaf_kind;
        }
        pub inline fn captureLeafKind(self: *const BytecodeImpl) function_bytecode_mod.ExactArgsLeafKind {
            return self.capture_leaf_kind;
        }

        // Var-ref lexical/const/global-decl metadata is derived on access from
        // `closure_var[idx]` rather than stored in parallel `[]bool` arrays,
        // mirroring qjs (which keeps only `JSClosureVar`). Synthetic fixture
        // indices past `closure_var.len` retain conservative false defaults.
        pub inline fn varRefIsLexicalAt(self: *const BytecodeImpl, idx: usize) bool {
            if (idx >= self.closure_var.len) return false;
            return self.closure_var[idx].isLexical();
        }
        pub inline fn varRefIsConstAt(self: *const BytecodeImpl, idx: usize) bool {
            if (idx >= self.closure_var.len) return false;
            return self.closure_var[idx].isConst();
        }
        pub inline fn varRefIsGlobalDeclAt(self: *const BytecodeImpl, idx: usize) bool {
            if (idx >= self.closure_var.len) return false;
            return self.closure_var[idx].closureType() == .global_decl;
        }

        // Finalized FunctionBytecode stores names only in `closure_var` and
        // derives them there. Mutable compiler bytecode and synthetic fixtures
        // may still own an explicit mirror, so callers use these accessors for
        // both forms.
        pub inline fn varRefNamesLen(self: *const BytecodeImpl) usize {
            return if (self.var_ref_names.len != 0) self.var_ref_names.len else self.closure_var.len;
        }
        pub inline fn varRefName(self: *const BytecodeImpl, idx: usize) atom.Atom {
            if (self.var_ref_names.len != 0) return self.var_ref_names[idx];
            return self.closure_var[idx].var_name;
        }

        pub fn setCode(self: *BytecodeImpl, bytes: []const u8) !void {
            freeGrowableSlice(u8, self.memory, &self.code, &self.code_capacity);
            if (bytes.len == 0) return;
            const owned = try self.memory.alloc(u8, bytes.len);
            errdefer self.memory.free(u8, owned);
            @memcpy(owned, bytes);
            self.code = owned;
            self.code_capacity = bytes.len;
        }

        /// Append bytes to `code` with geometric growth. The visible slice
        /// length tracks the used count so callers can read `code.len` for
        /// the current size, while reallocations are amortised O(1).
        pub fn appendCode(self: *BytecodeImpl, bytes: []const u8) !void {
            if (bytes.len == 0) return;
            const tail = try growSliceBy(u8, self.memory, &self.code, &self.code_capacity, bytes.len);
            @memcpy(tail, bytes);
        }

        /// Root-bytecode counterpart of FunctionDef.reserveByteCode.
        pub fn reserveCode(self: *BytecodeImpl, additional: usize) !void {
            if (additional == 0) return;
            const used = self.code.len;
            _ = try growSliceBy(u8, self.memory, &self.code, &self.code_capacity, additional);
            self.code = self.code.ptr[0..used];
        }

        pub fn appendCodeAssumeCapacity(self: *BytecodeImpl, bytes: []const u8) void {
            if (bytes.len == 0) return;
            const used = self.code.len;
            std.debug.assert(used + bytes.len <= self.code_capacity);
            self.code = self.code.ptr[0 .. used + bytes.len];
            @memcpy(self.code[used..], bytes);
        }

        pub fn appendSourceLoc(self: *BytecodeImpl, pc: u32, line_num: i32, col_num: i32) !void {
            if (line_num <= 0 or col_num <= 0) return;
            // See FunctionDefImpl.appendSourceLoc: P2-R1T streaming remap
            // requires non-decreasing slot pcs.
            std.debug.assert(self.source_loc_slots.len == 0 or
                self.source_loc_slots[self.source_loc_slots.len - 1].pc <= pc);
            const tail = try growSliceBy(pipeline_pc2line.SourceLocSlot, self.memory, &self.source_loc_slots, &self.source_loc_capacity, 1);
            tail[0] = .{ .pc = pc, .line_num = line_num, .col_num = col_num };
        }

        /// Remap source slots after final layout and discard entries that no
        /// longer precede an emitted opcode. QuickJS only calls
        /// `add_pc2line_info` before live output instructions; line markers in
        /// an unreachable suffix update its scanner state but do not create a
        /// pc2line record at bytecode end. Compact in place so this remains
        /// allocation-free at the resolve_labels commit boundary.
        pub fn remapSourceLocsBeforeEnd(
            self: *BytecodeImpl,
            old_to_new_pc: []const usize,
            new_code_len: usize,
        ) void {
            if (self.source_loc_slots.len == 0) return;
            var write_index: usize = 0;
            for (self.source_loc_slots) |slot| {
                var remapped = slot;
                if (slot.pc < old_to_new_pc.len) {
                    remapped.pc = @intCast(old_to_new_pc[slot.pc]);
                }
                if (@as(usize, remapped.pc) >= new_code_len) continue;
                self.source_loc_slots[write_index] = remapped;
                write_index += 1;
            }
            self.source_loc_slots = self.source_loc_slots.ptr[0..write_index];
        }

        /// Root-bytecode counterpart of FunctionDef.truncateSourceLocs.
        pub fn truncateSourceLocs(self: *BytecodeImpl, target_len: usize) void {
            std.debug.assert(target_len <= self.source_loc_slots.len);
            self.source_loc_slots = self.source_loc_slots.ptr[0..target_len];
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

        /// Transfer variant of `installCode`: take ownership of a backing
        /// allocation of `owned_capacity` elements while exposing only the
        /// used prefix `owned_used`. `deinit`, `setCode`, `installCode`, and
        /// the growable append helpers all free `code.ptr[0..code_capacity]`,
        /// so the full backing is released on every later path — including
        /// `owned_used.len == 0` with `owned_capacity > 0`, where the caller
        /// passes `backing.ptr[0..0]` so the pointer still names the backing.
        pub fn installCodeWithCapacity(self: *BytecodeImpl, owned_used: []u8, owned_capacity: usize) void {
            std.debug.assert(owned_used.len <= owned_capacity);
            std.debug.assert(owned_capacity != 0 or owned_used.len == 0);
            freeGrowableSlice(u8, self.memory, &self.code, &self.code_capacity);
            self.code = owned_used;
            self.code_capacity = owned_capacity;
        }

        pub fn installPc2Line(self: *BytecodeImpl, owned: []u8) void {
            const old = self.pc2line_buf;
            const old_owned = self.owns_pc2line_buf;
            self.pc2line_buf = owned;
            self.owns_pc2line_buf = owned.len != 0;
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

        /// Transfer variant of `installAtomOperands`. As with
        /// `installAtomOperands`, atom refcounts held by the previous
        /// `atom_operands` entries are NOT released here; callers release
        /// them explicitly before installing. When `owned_capacity` is
        /// nonzero, `owned_used.ptr` must name the head of the backing.
        pub fn installAtomOperandsWithCapacity(self: *BytecodeImpl, owned_used: []atom.Atom, owned_capacity: usize) void {
            std.debug.assert(owned_used.len <= owned_capacity);
            std.debug.assert(owned_capacity != 0 or owned_used.len == 0);
            freeGrowableSlice(atom.Atom, self.memory, &self.atom_operands, &self.atom_operands_capacity);
            self.atom_operands = owned_used;
            self.atom_operands_capacity = owned_capacity;
        }

        pub fn addConstant(self: *BytecodeImpl, value: JSValue) !u32 {
            return self.constants.append(value);
        }

        pub fn retainAtomOperand(self: *BytecodeImpl, atom_id: atom.Atom) !void {
            const tail = try growSliceBy(atom.Atom, self.memory, &self.atom_operands, &self.atom_operands_capacity, 1);
            tail[0] = self.atoms.dup(atom_id);
        }

        pub fn reserveAtomOperands(self: *BytecodeImpl, additional: usize) !void {
            if (additional == 0) return;
            const used = self.atom_operands.len;
            _ = try growSliceBy(atom.Atom, self.memory, &self.atom_operands, &self.atom_operands_capacity, additional);
            self.atom_operands = self.atom_operands.ptr[0..used];
        }

        pub fn retainAtomOperandAssumeCapacity(self: *BytecodeImpl, atom_id: atom.Atom) void {
            const used = self.atom_operands.len;
            std.debug.assert(used < self.atom_operands_capacity);
            self.atom_operands = self.atom_operands.ptr[0 .. used + 1];
            self.atom_operands[used] = self.atoms.dup(atom_id);
        }

        /// Root-bytecode counterpart of FunctionDef.appendAtomOperandOwned.
        pub fn retainAtomOperandOwned(self: *BytecodeImpl, atom_id: atom.Atom) !void {
            const tail = try growSliceBy(atom.Atom, self.memory, &self.atom_operands, &self.atom_operands_capacity, 1);
            tail[0] = atom_id;
        }

        pub fn retainAtomOperandOwnedAssumeCapacity(self: *BytecodeImpl, atom_id: atom.Atom) void {
            const used = self.atom_operands.len;
            std.debug.assert(used < self.atom_operands_capacity);
            self.atom_operands = self.atom_operands.ptr[0 .. used + 1];
            self.atom_operands[used] = atom_id;
        }

        /// Root-bytecode counterpart of FunctionDef.takeLastAtomOperand.
        pub fn takeLastAtomOperand(self: *BytecodeImpl) atom.Atom {
            std.debug.assert(self.atom_operands.len != 0);
            const atom_id = self.atom_operands[self.atom_operands.len - 1];
            self.atom_operands = self.atom_operands.ptr[0 .. self.atom_operands.len - 1];
            return atom_id;
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

        pub inline fn localOpenBindingIndex(self: *const BytecodeImpl, idx: usize) ?u16 {
            if (idx >= self.vardefs.len) return null;
            const vd = self.vardefs[idx];
            return if (vd.isCaptured()) vd.var_ref_idx else null;
        }

        pub inline fn argOpenBindingIndex(self: *const BytecodeImpl, idx: usize) ?u16 {
            if (idx >= self.argdefs.len) return null;
            const vd = self.argdefs[idx];
            return if (vd.isCaptured()) vd.var_ref_idx else null;
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

    /// Caller-stack-only bridge for focused mutable-bytecode fixtures and
    /// low-level compatibility helpers. Production script, eval, child, and
    /// module compilation all publish canonical GC-owned FunctionBytecodes.
    /// The wrapper owns nothing, must not escape the source Bytecode lifetime,
    /// and must never be deinitialized as a GC FunctionBytecode. Its accessors
    /// borrow the mutable tables/code through `legacy_bytecode_adapter`.
    pub const LegacyExecutionAdapter = extern struct {
        function: FunctionBytecode,
        hot_extension: function_bytecode_mod.FunctionBytecodeHotExtension,
        legacy_bytecode_adapter: ?*const BytecodeImpl,

        comptime {
            std.debug.assert(@offsetOf(@This(), "hot_extension") == @sizeOf(FunctionBytecode));
            std.debug.assert(@offsetOf(@This(), "legacy_bytecode_adapter") == @sizeOf(FunctionBytecode) + @sizeOf(function_bytecode_mod.FunctionBytecodeHotExtension));
            std.debug.assert(@sizeOf(@This()) == 168);
            std.debug.assert(@alignOf(@This()) == 8);
        }

        pub fn init(self: *@This(), source: *const BytecodeImpl) *const FunctionBytecode {
            const func_kind: function_bytecode_mod.FunctionKind = if (source.flags.is_async and source.flags.is_generator)
                .async_generator
            else if (source.flags.is_async)
                .async
            else if (source.flags.is_generator)
                .generator
            else
                .normal;
            self.* = std.mem.zeroes(@This());
            // Mark this stack-only adapter before enabling the extension bit:
            // applyFlags immediately locates and writes the fixed base+96
            // hot extension; its legacy pointer slot begins at base+104.
            // Canonical records never expose that stack-only slot.
            self.function.byte_code_len = function_bytecode_mod.legacy_byte_code_len_sentinel;
            self.function.flag_byte18 |= FunctionBytecode.byte18_has_extension_mask;
            self.function.applyFlags(.{
                .is_strict_mode = source.flags.is_strict,
                .runtime_strict_mode = source.flags.runtime_strict,
                .has_prototype = source.flags.has_prototype,
                .has_simple_parameter_list = source.flags.has_simple_parameter_list,
                .is_derived_class_constructor = source.flags.is_derived_class_constructor,
                .need_home_object = source.flags.need_home_object,
                .func_kind = func_kind,
                .new_target_allowed = source.entry_contract.new_target_allowed,
                .super_call_allowed = source.entry_contract.super_call_allowed,
                .super_allowed = source.entry_contract.super_allowed,
                .arguments_allowed = source.entry_contract.arguments_allowed,
                .is_direct_or_indirect_eval = source.flags.is_direct_or_indirect_eval,
            });
            self.function.setLegacyBytecodeAdapter(source);
            self.function.func_name = source.name;
            self.function.arg_count = source.arg_count;
            self.function.var_count = source.var_count;
            self.function.defined_arg_count = source.arg_count;
            self.function.stack_size = source.stack_size;
            self.function.var_ref_count = source.open_var_ref_count;
            self.function.closure_var_count = @intCast(if (source.closure_var.len != 0) source.closure_var.len else source.var_ref_names.len);
            self.function.cpool_count = @intCast(source.constants.values.len);
            // Publish the execution snapshot LAST: the simple-field
            // constructor classification reads the adapter code pointer
            // (installed above) plus the var/closure/cpool counts, so this
            // funnel matches publishExecutionFlags' code-bytes-final
            // guarantee. The adapter borrows MUTABLE fixture bytecode, so the
            // canonical-only Debug lockstep assertion in
            // constructSimpleFieldConstructor deliberately excludes it.
            self.function.setExecutionFlags(.{
                .has_mapped_arguments = source.flags.has_mapped_arguments,
                .simple_inline_eligible = source.simple_inline_eligible,
                .strict_simple_inline_eligible = source.strict_simple_inline_eligible,
                .strict_simple_snapshot_inline_eligible = source.strict_simple_snapshot_inline_eligible,
                .simple_inline_empty_leaf = source.flags.simple_inline_empty_leaf,
                .raw_this_inline_empty_leaf = source.raw_this_inline_empty_leaf,
                .simple_inline_exact_args_leaf = source.simple_inline_exact_args_leaf,
                .raw_this_inline_exact_args_leaf = source.raw_this_inline_exact_args_leaf,
                .exact_args_leaf_kind = source.exact_args_leaf_kind,
                .capture_leaf_kind = source.capture_leaf_kind,
                .is_module = source.flags.is_module,
            });
            return &self.function;
        }
    };

    pub fn codeMaterializesArgumentsObject(code: []const u8) bool {
        var pc: usize = 0;
        while (pc < code.len) {
            const op_id = code[pc];
            const size = opcode.sizeOf(op_id);
            if (size == 0 or pc + size > code.len) return true;
            if (op_id == opcode.op.special_object) {
                if (size < 2) return true;
                const subtype = code[pc + 1];
                if (subtype == opcode.special_object_subtype.arguments or
                    subtype == opcode.special_object_subtype.mapped_arguments) return true;
            }
            pc += size;
        }
        return false;
    }

    /// Geometry-only body-expansion gate (OPT-R10 small-function-inlining).
    /// Does not look at function names or field patterns. Forbidden opcodes
    /// that require a real frame (eval / arguments / fclosure / new.target /
    /// apply / generators) reject the candidate.
    pub const small_inline_max_code: usize = 40;
    pub const small_inline_max_slots: usize = 4;
    pub const small_inline_max_stack: usize = 4;

    fn scanSmallInlineEligible(
        fb: *const FunctionBytecode,
        materializes_arguments_object: bool,
        contains_direct_eval: bool,
        class_syntax_excludes_inline: bool,
    ) bool {
        if (fb.functionKind() != .normal) return false;
        if (class_syntax_excludes_inline) return false;
        if (fb.isDerivedClassConstructor()) return false;
        if (!fb.hasSimpleParameterList()) return false;
        if (materializes_arguments_object or contains_direct_eval) return false;
        if (fb.closureVarCount() != 0 or fb.openVarRefCount() != 0) return false;
        const code = fb.byteCode();
        if (code.len == 0 or code.len > small_inline_max_code) return false;
        if (@as(usize, fb.arg_count) + @as(usize, fb.var_count) > small_inline_max_slots) return false;
        if (fb.stack_size > small_inline_max_stack) return false;

        // F0b: the reject set is derived from the declaration, so a form
        // that moves behind a carrier keeps its policy. The hand-written
        // list this replaces matched on opcode identity and therefore could
        // not see a carrier resident at all -- which is how demoting
        // `put_super_value` silently made `super.x = v` bodies inlinable,
        // with no test turning red (5.2 clause 3). A carrier is now asked
        // about its resident instead of being special-cased.
        var pc: u32 = 0;
        while (pc < code.len) {
            const h = opcode.decode.headerAt(.final, code, pc) catch return false;
            if (opcode.logical.traitsOf(h.form).inline_policy == .forbidden) return false;
            if (h.form == .using) {
                const sub = opcode.decode.operandAt(h, code, 0, u8) catch return false;
                const resident = opcode.logical.subForm(sub) orelse return false;
                if (opcode.logical.traitsOf(resident).inline_policy == .forbidden) return false;
            }
            pc = h.next_pc();
        }
        return true;
    }

    /// Publish all zjs-only call classifications once, after the final FB
    /// tables/code and the normal stack-BFS result are complete. These facts
    /// are deliberately kept out of attach and call resolution: both paths
    /// must remain allocation-free and scan-free like qjs JSFunctionBytecode.
    pub fn publishExecutionFlags(
        fb: *FunctionBytecode,
        materializes_arguments_object: bool,
        has_mapped_arguments: bool,
        leaf_returns_balanced: bool,
        contains_direct_eval: bool,
        class_syntax_excludes_inline: bool,
        is_module: bool,
    ) void {
        // Class syntax is a finalizer-only exclusion fact. Runtime rejection is
        // encoded by OP_check_ctor and derived construction keeps its canonical
        // QJS bit; no ordinary class-constructor flag is published in the FB.
        std.debug.assert(!fb.isDerivedClassConstructor() or class_syntax_excludes_inline);
        // All published production and legacy-adapter FBs have one extension.
        // Load its possibly-unaligned hot word once, finish every classification
        // in a local snapshot, then publish it with one store.
        var call_facts = fb.callFacts();
        const strict_mode = fb.isStrictMode() or fb.runtimeStrictMode();
        var has_global_declarations = false;
        for (fb.closureVar()) |cv| {
            if (cv.closureType() == .global_decl) {
                has_global_declarations = true;
                break;
            }
        }
        const simple_inline_base = fb.functionKind() == .normal and
            !class_syntax_excludes_inline and
            fb.hasSimpleParameterList() and
            !has_global_declarations;
        const leaf_body_geometry = fb.var_count == 0 and
            fb.openVarRefCount() == 0 and
            !materializes_arguments_object and
            !contains_direct_eval;
        const empty_leaf_geometry = fb.arg_count == 0 and fb.closureVarCount() == 0 and
            leaf_body_geometry and leaf_returns_balanced;
        const sloppy_exact = simple_inline_base and !strict_mode and fb.arg_count > 0 and leaf_body_geometry;
        const raw_exact = simple_inline_base and strict_mode and fb.arg_count > 0 and leaf_body_geometry;
        const sloppy_capture = simple_inline_base and !strict_mode and fb.arg_count == 0 and
            fb.closureVarCount() > 0 and leaf_body_geometry;
        const raw_capture = simple_inline_base and strict_mode and
            fb.arg_count == 0 and fb.closureVarCount() > 0 and leaf_body_geometry;
        // Publication-time image of the per-call entry probe the inline call
        // resolver used to run (`code[0] == OP_check_ctor`). The code bytes
        // are final here (copied and authoritative above), so this is the
        // same predicate evaluated once.
        const entry_code = fb.byteCode();
        const entry_rejects_plain_call = entry_code.len == 0 or
            entry_code[0] == opcode.op.check_ctor;
        // Leftover operands at return stay on the caller stack after rewrite
        // (`return_undef` → `undefined; goto`). The BFS proof is already
        // computed for empty-leaf publication; AND it here so leftover ctor
        // bodies never enter noteMonomorphic. Not a shape special case.
        const small_inline_eligible = scanSmallInlineEligible(
            fb,
            materializes_arguments_object,
            contains_direct_eval,
            class_syntax_excludes_inline,
        ) and leaf_returns_balanced;
        if (fb.realmContext()) |realm| {
            realm.runtime.small_inline_published_bytes +|= entry_code.len;
        }

        call_facts.execution = .{
            .has_mapped_arguments = has_mapped_arguments,
            .simple_inline_eligible = simple_inline_base and !strict_mode,
            .strict_simple_inline_eligible = simple_inline_base and strict_mode and !materializes_arguments_object,
            .strict_simple_snapshot_inline_eligible = simple_inline_base and strict_mode and materializes_arguments_object,
            .simple_inline_empty_leaf = simple_inline_base and !strict_mode and empty_leaf_geometry,
            .raw_this_inline_empty_leaf = simple_inline_base and strict_mode and empty_leaf_geometry,
            .simple_inline_exact_args_leaf = sloppy_exact,
            .raw_this_inline_exact_args_leaf = raw_exact,
            .exact_args_leaf_kind = if (sloppy_exact) .sloppy else if (raw_exact) .raw_this else .none,
            .capture_leaf_kind = if (sloppy_capture) .sloppy else if (raw_capture) .raw_this else .none,
            .is_module = is_module,
            .entry_rejects_plain_call = entry_rejects_plain_call,
            .small_inline_eligible = small_inline_eligible,
        };
        fb.hotExtensionRequiredMut().call_facts = call_facts;
        // Keep the header-resident hot mirror coherent with the authoritative
        // FAM word (canonicalCallFacts reads the mirror).
        fb.call_facts_mirror = call_facts;
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
    const atom = @import("core/atom.zig");

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
        return dumpArtifact(writer, bc.atoms, bc.name, bc.arg_count, bc.var_count, bc.stack_size, bc.code, bc.constants.values.len, opts);
    }

    /// Dump the canonical finalized execution record directly. The atom table
    /// is supplied by the owning Runtime; FunctionBytecode intentionally does
    /// not retain a parallel allocator/table-bearing Bytecode view.
    pub fn dumpFunctionBytecode(
        writer: *std.Io.Writer,
        fb: *const function_bytecode.FunctionBytecode,
        atoms: *atom.AtomTable,
        opts: Options,
    ) !void {
        return dumpArtifact(writer, atoms, fb.funcName(), fb.arg_count, fb.var_count, fb.stack_size, fb.byteCode(), fb.cpoolSlice().len, opts);
    }

    fn dumpArtifact(
        writer: *std.Io.Writer,
        atoms: *atom.AtomTable,
        name: atom.Atom,
        arg_count: u16,
        var_count: u16,
        stack_size: u16,
        code: []const u8,
        constant_count: usize,
        opts: Options,
    ) !void {
        try writer.print("=== bytecode ===\n", .{});
        try writer.print("name        : {s}\n", .{atoms.name(name) orelse "?"});
        try writer.print("arg_count   : {d}\n", .{arg_count});
        try writer.print("var_count   : {d}\n", .{var_count});
        try writer.print("stack_size  : {d}\n", .{stack_size});
        try writer.print("code_len    : {d}\n", .{code.len});
        try writer.print("constants   : {d}\n", .{constant_count});
        try writer.print("--- instructions ---\n", .{});

        // Decode-first with a raw fallback: a disassembler must render a
        // CORRUPT stream too, so a failed decode falls back to one raw byte
        // and keeps going where the decoder would (correctly) refuse. On the
        // decoded path the operands come from the layout, which prints
        // strictly more than the format switch it replaced could: burned-in
        // operands (`get_loc0`'s slot) have no bytes for a format-driven
        // printer to read, but the declaration knows their values.
        var pc: usize = 0;
        while (pc < code.len) {
            if (opts.show_offsets) {
                try writer.print("{d:>5}: ", .{pc});
            }

            const h = opcode.decode.headerAt(.final, code, @intCast(pc)) catch {
                const op_id = code[pc];
                const op_name = opcode.nameOf(op_id);
                if (op_name.len == 0) {
                    try writer.print("?<{d}>", .{op_id});
                } else {
                    try writer.print("{s}", .{op_name});
                }
                if (opts.show_raw_bytes) {
                    try writer.print("    ; raw={x:0>2} ", .{code[pc]});
                }
                try writer.print("\n", .{});
                pc += 1;
                continue;
            };
            const end: usize = h.next_pc();

            try writer.print("{s}", .{opcode.nameOf(code[pc])});
            try printOperandsFromLayout(writer, atoms, h, code);

            if (opts.show_raw_bytes) {
                try writer.print("    ; raw=", .{});
                for (code[pc..end]) |b| try writer.print("{x:0>2} ", .{b});
            }
            try writer.print("\n", .{});
            pc = end;
        }

        try writer.print("--- end ---\n", .{});
    }

    fn printOperandsFromLayout(
        writer: *std.Io.Writer,
        atoms: *atom.AtomTable,
        h: opcode.decode.Header,
        code: []const u8,
    ) !void {
        const lay = h.layout();
        for (0..lay.len) |i| {
            const slot = lay.slots[i];
            try writer.writeAll(if (i == 0) " " else ", ");
            const value: i64 = if (slot.offset == null)
                @intCast(slot.fixed)
            else
                opcode.decode.operandAt(h, code, i, i64) catch {
                    try writer.print("<trunc>", .{});
                    return;
                };
            switch (slot.kind) {
                .atom => {
                    const a: u32 = @intCast(value);
                    if (atoms.name(a)) |name_str| {
                        try writer.print("\"{s}\"", .{name_str});
                    } else {
                        try writer.print("atom#{d}", .{a});
                    }
                },
                .label => try writer.print("L{d}", .{value}),
                .sub_opcode => {
                    // dyn_env_probe's kind byte decodes to a probe shape;
                    // showing it beats showing the raw flag byte.
                    if (h.form == .dyn_env_probe) {
                        if (opcode.dyn_env.decode(@intCast(value))) |flags| {
                            try writer.print("{s}{s}", .{
                                @tagName(flags.kind),
                                if (flags.is_with) ",with" else "",
                            });
                            continue;
                        }
                    }
                    try writer.print("{d}", .{value});
                },
                else => try writer.print("{d}", .{value}),
            }
        }
    }
};

pub const pipeline = struct {
    pub const pc2line = pipeline_pc2line;
    pub const stack_size = pipeline_stack_size;
    pub const finalize = pipeline_finalize;
};

const bytecode_dump = dump;
pub const Bytecode = function_mod.Bytecode;
pub const FunctionBytecode = function_bytecode.FunctionBytecode;
pub const FunctionLayout = function_bytecode.FunctionLayout;
pub const CallFacts = function_bytecode.CallFacts;
pub const legacy_byte_code_len_sentinel = function_bytecode.legacy_byte_code_len_sentinel;
pub const LegacyExecutionAdapter = function_mod.LegacyExecutionAdapter;
pub const FunctionDef = function_def.FunctionDef;

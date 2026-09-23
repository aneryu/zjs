//! Instruction catalog: physical ids (`op`) and the two views of the
//! 178..196 overlap (temp vs short). Use `sizeOf` / `sizeOfPhase1`;
//! never index `opcode_info` with a raw id.

const std = @import("std");
const bytecode = @import("../bytecode.zig");
const atom = @import("../core/atom.zig");
const memory = @import("../core/memory.zig");
const runtime = @import("../runtime.zig");
const compiler = @import("../compiler/root.zig");
const opcode_logical = @import("../opcode_logical.zig");
const PropSiteCache = bytecode.PropSiteCache;
const opcode = @This();

pub const Format = opcode_logical.Format;

/// Phase-1 scope operand flag: the LHS reference has already selected its
/// environment, so the fallback put must resolve only the static chain.
pub const scope_no_dynamic_env_flag: u16 = 0x8000;

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
    /// C0 end state: LOWERED-ONLY direct byte (see
    /// `logical.lowered_direct`). The final id 112 is reclaimed --
    /// final streams carry `{using, ext0_sub.to_propkey}` -- but the
    /// parser still emits this byte and the phase-1/parser decoders
    /// still resolve it to the form.
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
    /// The neutral cold-plane carrier (G0 rename; was `using`, id and
    /// byte encoding unchanged). Operand is `ext0_sub`: the ERM
    /// residents keep their `using_*` logical names, the demoted colds
    /// and late-encoding residents live alongside them, and
    /// `add_base+hint` is add_resource.
    pub const ext0: u8 = 244;
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
    /// zjs-only object-literal capacity hint. The parser emits this only
    /// when all keys are static and the final unique named-property count
    /// is one or two, allowing a Shape-sized two-entry trailing allocation.
    pub const object_slots2: u8 = 254;

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
    pub const op_count: u16 = 255;
    /// First id of the temp/short overlap range (OP_nop + 1).
    pub const op_temp_start: u8 = 178;
    /// One past the last temp id (exclusive).
    pub const op_temp_end: u8 = 197;
    /// Number of temp opcodes (= short-entry shift in `opcode_info`).
    pub const op_temp_count: u8 = 19;
};

/// Operand of `op.ext0` (244). `add_base + DisposalHint` is add_resource.
pub const ext0_sub = struct {
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
    /// their first-class ids to the typed family. The 2026-08-27 opcode-space
    /// survey is available in Git history.
    pub const check_ctor_return: u8 = 15;
    pub const set_proto: u8 = 16;
    pub const put_super_value: u8 = 17;
    pub const to_object: u8 = 18;

    /// C0 late-encoding pilot (11.7 D7): unlike the residents above,
    /// `to_propkey` keeps its direct id 112 as an executable alias for
    /// the migration window; the parser and every compiler pass still
    /// see the direct form, and only the final writer encodes the
    /// carrier. Registered in `logical.final_carrier_residents`.
    pub const to_propkey: u8 = 19;
    /// C1-1 (closed 2026-08-30): computed-name function naming. Zero
    /// executions in the eight-workload census; the reclaimed final
    /// id 75 survives only as the lowered-direct byte the builder
    /// rewrite emits.
    pub const set_name_computed: u8 = 20;

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
            to_propkey => 1,
            set_name_computed => 2,
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
            to_propkey => 1,
            set_name_computed => 2,
            else => 0,
        };
    }
};

/// Derived, not declared: final ids + the temp block + the
/// lowered-direct rows. A new row class changes this sum, never a
/// hand-updated literal.
pub const op_info_len: usize = @as(usize, op.op_count) + op.op_temp_count + logical.lowered_direct.len;

/// G0: the metadata table is GENERATED from the declaration source --
/// the enum is the slot map (an id below op_count with no <300 enum
/// field is a reclaimed slot and gets the canonical dead row), and
/// `logical.form_decls` carries each form's format and stack
/// constants; size derives from the operand templates. The retired
/// hand-written table was proven equal field for field before its
/// deletion (the pre-squash G0a commit carries the proof; lineage on
/// backup/pre-squash-2026-08-30-opcode).
pub const opcode_info: [op_info_len]Info = blk: {
    @setEvalBranchQuota(400000);
    var t: [op_info_len]Info = undefined;
    // Final ids: claimed slots take their form's generated row at the
    // shifted index; reclaimed slots take the dead row.
    for (0..op.op_count) |raw| {
        const id: u8 = @intCast(raw);
        const idx: usize = if (id >= op.op_temp_start) @as(usize, id) + op.op_temp_count else id;
        t[idx] = if (formForId(id)) |form|
            generatedRow(form)
        else
            .{ .name = std.fmt.comptimePrint("unused_{d}", .{id}), .size = 1, .n_pop = 0, .n_push = 0, .fmt = .none };
    }
    // Temp forms occupy the overlap range at their raw position.
    for (@typeInfo(logical.LogicalOpcode).@"enum".fields) |f| {
        if (f.value < 300 or f.value >= 400) continue;
        t[op.op_temp_start + (f.value - 300)] = generatedRow(@enumFromInt(f.value));
    }
    // Lowered-direct rows append in declaration order.
    for (logical.lowered_direct, 0..) |e, k| {
        t[@as(usize, op.op_count) + op.op_temp_count + k] = generatedRow(e.form);
    }
    break :blk t;
};

/// The <300 form claiming a final id, if any. The enum IS the slot
/// map: this replaces the row-name-prefix classification as the
/// authority (stateOf still reads the generated names, and the ledger
/// assertions prove the two agree).
fn formForId(comptime id: u8) ?logical.LogicalOpcode {
    comptime {
        for (@typeInfo(logical.LogicalOpcode).@"enum".fields) |f| {
            if (f.value < 300 and f.value == id) return @enumFromInt(f.value);
        }
        return null;
    }
}

fn generatedRow(comptime form: logical.LogicalOpcode) Info {
    comptime {
        for (logical.form_decls) |d| {
            if (d.form != form) continue;
            const fmt = d.fmt;
            var size: usize = 1;
            for (logical.operandsOf(form, d.fmt)) |operand| {
                switch (operand.source) {
                    .payload => |pl| size += switch (pl.width) {
                        .u8, .i8 => 1,
                        .u16, .i16 => 2,
                        .u32, .i32 => 4,
                    },
                    .fixed => {},
                }
            }
            return .{ .name = @tagName(form), .size = size, .n_pop = d.pop, .n_push = d.push, .fmt = fmt };
        }
        @compileError("form has no form_decls row: " ++ @tagName(form));
    }
}

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

pub const special_object_subtype = struct {
    pub const arguments: u8 = 0;
    pub const mapped_arguments: u8 = 1;
    pub const current_function: u8 = 2;
    pub const new_target: u8 = 3;
    pub const home_object: u8 = 4;
    pub const var_object: u8 = 5;
    pub const import_meta: u8 = 6;
};

/// Final-view lookup, for bytecode after `resolve_labels`: ids in the
/// temp/short overlap range (op_temp_start..op_temp_end-1) resolve to
/// the SHORT opcode entry, stored `op.op_temp_count` slots past the
/// id. Mirrors QuickJS `short_opcode_info`. Returns
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
/// `opcode_info[op]` indexing. zjs deviation: the
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
    // C0 end state: a lowered-direct id keeps its real row in the
    // phase-1 view while its final view is the reclaimed dead row.
    inline for (logical.lowered_direct, 0..) |entry, k| {
        if (op_id == entry.id)
            return &opcode_info[@as(usize, op.op_count) + op.op_temp_count + k];
    }
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

/// True when the opcode's final form carries a trailing W1
/// property-site `cache_idx` byte (`Format.atom_cache_u8`). The phase-1
/// stream writes a `PropSiteCache.no_cache_idx` placeholder there;
/// `resolve_labels` is the single writer of real indices.
///
/// Derived tables, not `formatOf*` calls: both predicates sit on the
/// per-instruction emit path, and `phase1Info` walks the
/// `lowered_direct` list before it can answer (a 6.5% fixed-work
/// instruction regression on Typescript when this was a call).
const prop_cache_idx_final: [256]bool = blk: {
    @setEvalBranchQuota(60_000);
    var t: [256]bool = @splat(false);
    for (&t, 0..) |*row, i| row.* = formatOf(@intCast(i)) == .atom_cache_u8;
    break :blk t;
};
const prop_cache_idx_phase1: [256]bool = blk: {
    @setEvalBranchQuota(60_000);
    var t: [256]bool = @splat(false);
    for (&t, 0..) |*row, i| row.* = formatOfPhase1(@intCast(i)) == .atom_cache_u8;
    break :blk t;
};

pub inline fn carriesPropCacheIdx(op_id: u8) bool {
    return prop_cache_idx_final[op_id];
}

/// Phase-1-view twin of `carriesPropCacheIdx`. The parser emits the temp
/// `get_field_opt_chain` (an overlap-range id whose FINAL view names a
/// different opcode), so a phase-1 emitter must ask the phase-1 table.
pub inline fn carriesPropCacheIdxPhase1(op_id: u8) bool {
    return prop_cache_idx_phase1[op_id];
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

/// Stack push count in final-form bytecode.
pub fn nPushOf(op_id: u8) u8 {
    return if (finalInfo(op_id)) |info| info.n_push else 0;
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

    /// D11 / 11.0: ids whose logical form has moved to a carrier FINAL
    /// encoding but whose direct encoding stays executable for the
    /// migration window. Decoder, validator and dispatch all still
    /// accept the id; the encoder never selects it (`finalEncodingOf`
    /// answers carrier for the canonical form, and the join below
    /// requires that registration). The id still counts as `claimed`
    /// in the ledger -- the net -1 is only booked when the alias is
    /// deleted, which also changes the decode fingerprint pinned in
    /// the tests.
    ///
    /// This crosses the F0a0 scope boundary documented above by
    /// design: the 10.8 freeze that blocked LogicalOpcode from this
    /// namespace has been closed since 2026-08-27.
    pub const ExecutableAlias = struct {
        id: u8,
        canonical: opcode_logical.LogicalOpcode,
    };

    pub const executable_aliases: []const ExecutableAlias = &.{
        // Empty: C0's window over 112 and C1-1's over 75 both closed
        // on 2026-08-30 after their ledger readings. Every demotion
        // opens its window by adding a row here and closes it by
        // deleting the row.
    };

    /// The table is empty today, so this always answers null.  It is
    /// kept because the comptime join above (`executable_aliases` walks
    /// at the late-encoding and lowered-direct checks) and the decode
    /// fingerprint below both read it; deleting it would change the
    /// pinned fingerprint and drop two invariants.
    pub fn aliasOf(op_id: u8) ?opcode_logical.LogicalOpcode {
        inline for (executable_aliases) |a| {
            if (a.id == op_id) return a.canonical;
        }
        return null;
    }
};

/// F0a1 (§10.8 合同 1 + 5a、不变量 5/6；gate 见 §10.8 末表): the logical
/// half of the declaration source lives in `src/opcode_logical.zig`,
/// which imports nothing from here so the dependency stays
/// exec -> bytecode -> logical (P0-3). This block is the join: it proves
/// the logical declaration and the physical table describe the same
/// instruction set.
pub const logical = opcode_logical;

comptime {
    @setEvalBranchQuota(40000);

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
        // are checked separately -- except the lowered-direct ones,
        // whose phase-1 row must agree with the declaration like any
        // other lowered form's.
        if (f.value >= 400 and decode.loweredDirectIdOf(f.value) == null) continue;
        const id: u8 = if (f.value >= 400)
            decode.loweredDirectIdOf(f.value).?
        else if (f.value >= 300)
            op.op_temp_start + @as(u8, @intCast(f.value - 300))
        else
            @intCast(f.value);
        const info = if (f.value >= 300) phase1Info(id).? else finalInfo(id).?;
        const form: logical.LogicalOpcode = @enumFromInt(f.value);
        const fmt = info.fmt;
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
        const fmt = info.fmt;
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
            _ = ext0_sub.stackPop(sub);
            _ = ext0_sub.stackPush(sub);
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
                if (sub.carrier != .ext0)
                    @compileError("only the `ext0` carrier exists today");
                // The slot must match the `ext0_sub` constant of the
                // form's name: demoted opcodes are `using_<sub>`,
                // late-encoding residents keep their own name.
                const bare = if (std.mem.startsWith(u8, f.name, "using_"))
                    f.name["using_".len..]
                else
                    f.name;
                var matched = false;
                for (@typeInfo(ext0_sub).@"struct".decls) |d| {
                    if (!std.mem.eql(u8, d.name, bare)) continue;
                    if (@field(ext0_sub, d.name) != sub.slot)
                        @compileError("declared cold-plane slot disagrees with ext0_sub");
                    matched = true;
                }
                if (!matched)
                    @compileError("cold-plane form names a sub that ext0_sub does not declare");
            },
            .main => @compileError("a 400+ logical id must be a cold-plane resident"),
        }
    }

    // C0 (D7/D11): late-encoding residents. A resident is in one of two
    // states, and the assertions differ per state:
    //   window   -- form still owns its final id (<256); the id must be
    //               on record as an executable alias, and the direct row
    //               must agree with the sub table on the stack effect.
    //   end      -- form lives on the carrier plane (400+); the alias is
    //               gone, and if the form keeps a lowered-direct byte
    //               that byte's phase-1 row is the agreeing authority
    //               while its final slot must read reclaimed.
    for (logical.final_carrier_residents) |r| {
        if (r.carrier != .ext0)
            @compileError("only the `ext0` carrier exists today");
        if (!@hasDecl(ext0_sub, @tagName(r.form)))
            @compileError("late-encoding resident has no ext0_sub slot constant");
        if (@field(ext0_sub, @tagName(r.form)) != r.slot)
            @compileError("late-encoding resident slot disagrees with ext0_sub");
        if (r.slot >= ext0_sub.add_base)
            @compileError("late-encoding resident slot collides with the add range");
        if (logical.subForm(r.slot) != r.form)
            @compileError("subForm does not round-trip the late-encoding resident");
        var aliased = false;
        for (physical.executable_aliases) |a| {
            if (a.canonical == r.form) aliased = true;
        }
        if (@intFromEnum(r.form) < 256) {
            // Window state.
            const id: u8 = @intCast(@intFromEnum(r.form));
            const info = finalInfo(id).?;
            if (ext0_sub.stackPop(r.slot) != info.n_pop or
                ext0_sub.stackPush(r.slot) != info.n_push)
                @compileError("carrier-resident stack effect disagrees with the direct row");
            if (!aliased)
                @compileError("late-encoding resident has no executable alias for its direct id");
        } else if (@intFromEnum(r.form) >= 400) {
            // End state.
            if (aliased)
                @compileError("closed late-encoding resident still has an executable alias");
            if (decode.loweredDirectIdOf(@intFromEnum(r.form))) |lowered_id| {
                const info = phase1Info(lowered_id).?;
                if (!std.mem.eql(u8, info.name, @tagName(r.form)))
                    @compileError("lowered-direct row and its form disagree on the name");
                if (ext0_sub.stackPop(r.slot) != info.n_pop or
                    ext0_sub.stackPush(r.slot) != info.n_push)
                    @compileError("carrier-resident stack effect disagrees with the lowered row");
                if (physical.stateOf(lowered_id) != .reclaimed)
                    @compileError("lowered-direct byte's final slot must be reclaimed");
            }
        } else {
            @compileError("late-encoding resident in the compiler-only range makes no sense");
        }
    }
    // G0: every emit constant is a proven mirror of the declaration.
    // Final forms carry their id as the enum value; compiler-only
    // forms carry their temp id through the fixed 300+ offset. A
    // constant that drifts -- or a form added without its constant --
    // stops compiling here instead of emitting a neighbouring opcode.
    for (@typeInfo(logical.LogicalOpcode).@"enum".fields) |f| {
        if (f.value >= 400) continue; // lowered-direct asserted below
        if (!@hasDecl(op, f.name))
            @compileError("form has no op emit constant: " ++ f.name);
        const expected: u8 = if (f.value >= 300)
            op.op_temp_start + @as(u8, @intCast(f.value - 300))
        else
            @intCast(f.value);
        if (@field(op, f.name) != expected)
            @compileError("op constant disagrees with the declaration: " ++ f.name);
    }

    // Every lowered-direct entry must belong to a late-encoding
    // resident: a form with a lowered byte but no final encoding would
    // be unwritable by the final writer.
    for (logical.lowered_direct) |e| {
        var registered = false;
        for (logical.final_carrier_residents) |r| {
            if (r.form == e.form) registered = true;
        }
        if (!registered)
            @compileError("lowered-direct form has no final carrier encoding");
        // The parser's emit constant and the declaration are one fact.
        if (!@hasDecl(op, @tagName(e.form)) or @field(op, @tagName(e.form)) != e.id)
            @compileError("op constant disagrees with the lowered-direct declaration");
    }
    for (physical.executable_aliases) |a| {
        if (physical.stateOf(a.id) != .claimed)
            @compileError("executable alias over an unclaimed id");
        if (!std.mem.eql(u8, finalInfo(a.id).?.name, @tagName(a.canonical)))
            @compileError("executable alias and its row disagree on the name");
        var registered = false;
        for (logical.final_carrier_residents) |r| {
            if (r.form == a.canonical) registered = true;
        }
        if (!registered)
            @compileError("executable alias without a carrier encoding: the encoder would still emit it");
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
    /// `lowered` is the phase-1/parser-adjacent view (temp remap plus
    /// the lowered-direct residents); `s3` is the resolve_variables
    /// output that resolve_labels consumes -- final ids, no temps, but
    /// the lowered-direct bytes still present (D10's "lowered form");
    /// `final` is the S4 artifact, where a lowered-direct byte is a
    /// reclaimed id and must be rejected.
    pub const Domain = enum { lowered, s3, final };

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

    pub const layout_table_len = blk: {
        var m: usize = 0;
        for (@typeInfo(logical.LogicalOpcode).@"enum".fields) |f| {
            if (f.value > m) m = f.value;
        }
        break :blk m + 1;
    };

    /// The lowered-direct byte of a carrier-plane form, or null for the
    /// residents whose only home is the carrier (C0 end state).
    pub fn loweredDirectIdOf(comptime value: u16) ?u8 {
        comptime {
            for (logical.lowered_direct) |e| {
                if (@intFromEnum(e.form) == value) return e.id;
            }
            return null;
        }
    }

    /// Sparse but stable: indexed by the logical id so `layoutOf` hands
    /// back a pointer rather than rebuilding a layout per decode.
    pub const layout_table: [layout_table_len]?OperandLayout = blk: {
        @setEvalBranchQuota(60000);
        var table = [_]?OperandLayout{null} ** layout_table_len;
        for (@typeInfo(logical.LogicalOpcode).@"enum".fields) |f| {
            // Carrier residents have no row of their own -- except the
            // lowered-direct ones, whose phase-1 row is theirs.
            if (f.value >= 400 and loweredDirectIdOf(f.value) == null) continue;
            const id: u8 = if (f.value >= 400)
                loweredDirectIdOf(f.value).?
            else if (f.value >= 300)
                op.op_temp_start + @as(u8, @intCast(f.value - 300))
            else
                @intCast(f.value);
            const info = if (f.value >= 300) phase1Info(id).? else finalInfo(id).?;
            const form: logical.LogicalOpcode = @enumFromInt(f.value);
            const fmt = info.fmt;
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
    };

    pub const form_row: [layout_table_len]FormRow = blk: {
        @setEvalBranchQuota(60000);
        var t = [_]FormRow{.{ .size = 0, .pop = 0, .push = 0, .flags = 0 }} ** layout_table_len;
        for (@typeInfo(logical.LogicalOpcode).@"enum".fields) |f| {
            // Same exception as layout_table: a lowered-direct resident
            // keeps a live row (the phase-1 view of its byte).
            if (f.value >= 400 and loweredDirectIdOf(f.value) == null) continue;
            const id: u8 = if (f.value >= 400)
                loweredDirectIdOf(f.value).?
            else if (f.value >= 300)
                op.op_temp_start + @as(u8, @intCast(f.value - 300))
            else
                @intCast(f.value);
            const info = if (f.value >= 300) phase1Info(id).? else finalCompactInfo(id).?;
            var flags: u8 = 0;
            if (f.value >= 300 or physical.stateOf(id) == .claimed)
                flags |= FormRow.claimed_bit;
            if (dynamic_by_form[f.value] != null) flags |= FormRow.dynamic_bit;
            switch (info.fmt) {
                .atom, .atom_u8, .atom_cache_u8, .atom_u16, .atom_label_u8, .atom_label_u16 => {
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
        // C0 end state: a lowered-direct id decodes as its carrier-plane
        // form in this domain, not as its reclaimed final slot.
        for (logical.lowered_direct) |e|
            t[e.id] = domainRowFor(@intFromEnum(e.form), false);
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
        // C0 end state: the parser's mixed stream carries the
        // lowered-direct byte, and this row set is where a non-temp id
        // resolves -- so the byte maps to the carrier-plane form here
        // too, never to the reclaimed final slot.
        for (logical.lowered_direct) |e|
            t[e.id] = domainRowFor(@intFromEnum(e.form), false);
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
        atoms_ledger: []const atom.Atom,
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
                    if (atom.Atom.fromRaw(operand) == atoms_ledger[atom_index])
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
        atoms_ledger: []const atom.Atom,
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
            if (atom.Atom.fromRaw(operand) != atoms_ledger[atom_index]) return error.InvalidOpcode;
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
            // Carrier residents have no layout row and no ladder.
            const wlay = layout_table[@intFromEnum(wide)] orelse return sel;
            for (@typeInfo(logical.LogicalOpcode).@"enum".fields) |f| {
                const form: logical.LogicalOpcode = @enumFromInt(f.value);
                if (form == wide or logical.familyOf(form) != fam) continue;
                if (f.value >= 300) continue; // final forms only
                const lay = layout_table[f.value] orelse continue;
                // The short variant narrows or burns in the LEADING
                // operand only; any trailing operands (the call family's
                // `cache_idx` byte) must be carried unchanged, so a
                // candidate whose tail differs from the wide row is not
                // a rung of this ladder.
                if (lay.len != wlay.len or lay.len == 0) continue;
                var tail_matches = true;
                for (1..lay.len) |i| {
                    const a = lay.slots[i];
                    const b = wlay.slots[i];
                    if (a.kind != b.kind or a.offset == null or b.offset == null or a.width != b.width)
                        tail_matches = false;
                }
                if (!tail_matches) continue;
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

    /// Stage-A selection for jump relaxation: the same jump at a
    /// narrower label width, derived from the family + the label
    /// slot's declared width. goto has both rungs (goto8/goto16);
    /// the conditionals have only the byte rung.
    pub const JumpSelection = struct {
        narrow: ?logical.LogicalOpcode, // 1-byte label
        medium: ?logical.LogicalOpcode, // 2-byte label
    };

    pub const jump_selection_table: [layout_table_len]JumpSelection = blk: {
        @setEvalBranchQuota(400000);
        var t = [_]JumpSelection{.{ .narrow = null, .medium = null }} ** layout_table_len;
        for (@typeInfo(logical.LogicalOpcode).@"enum".fields) |wf| {
            if (wf.value >= 300) continue;
            const wide: logical.LogicalOpcode = @enumFromInt(wf.value);
            const wlay = layout_table[wf.value] orelse continue;
            // The wide rung is the family key: a four-byte label
            // operand. Declared as i32 (the S4 relative offset); an
            // equality test against u32 here was the assertion's first
            // catch -- it left the whole table empty.
            var wide_has_label = false;
            for (0..wlay.len) |i| {
                const w = wlay.slots[i].width orelse continue;
                if (wlay.slots[i].kind == .label and (w == .i32 or w == .u32))
                    wide_has_label = true;
            }
            if (!wide_has_label) continue;
            const fam = logical.familyOf(wide);
            for (@typeInfo(logical.LogicalOpcode).@"enum".fields) |f| {
                if (f.value >= 300 or f.value == wf.value) continue;
                const form: logical.LogicalOpcode = @enumFromInt(f.value);
                if (logical.familyOf(form) != fam) continue;
                const lay = layout_table[f.value] orelse continue;
                for (0..lay.len) |i| {
                    const slot = lay.slots[i];
                    if (slot.kind != .label) continue;
                    switch (slot.width orelse continue) {
                        .i8 => t[wf.value].narrow = form,
                        .i16 => t[wf.value].medium = form,
                        else => {},
                    }
                }
            }
        }
        break :blk t;
    };

    pub inline fn selectJumpForm(
        wide: logical.LogicalOpcode,
        rung: enum { narrow, medium },
    ) ?logical.LogicalOpcode {
        const sel = jump_selection_table[@intFromEnum(wide)];
        return switch (rung) {
            .narrow => sel.narrow,
            .medium => sel.medium,
        };
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

    /// 10.7: one number over every executable final encoding -- the
    /// 256 physical slot states (claimed rows by name, alias records
    /// by canonical form) plus the carrier's accepted tag set and add
    /// range. Deleting an alias, demoting a form or moving a resident
    /// necessarily changes it; the pinned test is the conscious-update
    /// point for every such step of the 11.0 lifecycle.
    pub const fingerprint: u64 = blk: {
        @setEvalBranchQuota(200000);
        var h: u64 = 0x10_7;
        for (0..256) |raw| {
            const id: u8 = @intCast(raw);
            const state: u8 = switch (physical.stateOf(id)) {
                .claimed => 1,
                .reclaimed => 2,
                .no_row => 3,
            };
            h = std.hash.Wyhash.hash(h, &.{ id, state });
            if (state == 1) h = std.hash.Wyhash.hash(h, finalInfo(id).?.name);
            if (physical.aliasOf(id)) |canonical| {
                h = std.hash.Wyhash.hash(h, &.{0xA5});
                h = std.hash.Wyhash.hash(h, @tagName(canonical));
            }
        }
        for (0..256) |raw| {
            const tag: u8 = @intCast(raw);
            if (logical.subForm(tag)) |resident|
                h = std.hash.Wyhash.hash(h, @tagName(resident))
            else
                h = std.hash.Wyhash.hash(h, &.{ 0xFF, tag });
        }
        h = std.hash.Wyhash.hash(h, &.{ext0_sub.add_base});
        break :blk h;
    };

    /// C0 (contract 3, encoding axis): the one place a final writer
    /// learns whether a logical form is written as its direct id or as
    /// a carrier tag. Comptime per form like the shortening selectors,
    /// so a writer's capacity side and emission side cannot consult
    /// different answers. The encoder never selects an executable
    /// alias: a form registered in `final_carrier_residents` answers
    /// carrier here even while its direct id still decodes (D11).
    pub fn finalEncodingOf(comptime form: logical.LogicalOpcode) Encoding {
        comptime {
            for (logical.final_carrier_residents) |r| {
                if (r.form == form)
                    return .{ .carrier = .{
                        .carrier = @intCast(@intFromEnum(r.carrier)),
                        .tag = r.slot,
                    } };
            }
            if (@intFromEnum(form) >= 300)
                @compileError("finalEncodingOf asked about a non-final form");
            return .{ .direct = @intCast(@intFromEnum(form)) };
        }
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

        /// Contract 2 lists `layout` as a header field. It is an
        /// accessor instead, because building it eagerly is what a
        /// decode costs: the layout is a ~50-byte struct, and the
        /// compile path now decodes every instruction about three times
        /// (stack pass, artifact validator, inline scanner). Measured,
        /// not assumed.
        pub inline fn layout(self: Header) *const OperandLayout {
            return layoutOf(self.form);
        }
    };

    pub const Error = error{ InvalidOpcode, BytecodeOverflow };

    // A reclaimed slot keeps a row -- the canonical dead shape, which
    // the ledger asserts -- so "the row table has an entry" does NOT
    // mean "the slot is claimed"; it only means `id < op_count`. Twelve
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

    /// Lowered-domain index per physical byte: identity, except the
    /// temp/short overlap range (300+) and the lowered-direct residents
    /// of the carrier plane (C0 end state). Public because the CFG
    /// ownership audit rebuilds rows from bytes and must share this
    /// mapping rather than re-deriving the temp arithmetic.
    pub const lowered_index_table: [256]u16 = blk: {
        var t: [256]u16 = undefined;
        for (0..256) |i| {
            const id: u8 = @intCast(i);
            t[i] = if (id >= op.op_temp_start and id < op.op_temp_end)
                @as(u16, 300) + (id - op.op_temp_start)
            else
                id;
        }
        for (logical.lowered_direct) |e| t[e.id] = @intFromEnum(e.form);
        break :blk t;
    };

    /// S3-domain index per physical byte: identity -- S3 carries final
    /// ids and no temps -- except the lowered-direct residents.
    const s3_index_table: [256]u16 = blk: {
        var t: [256]u16 = undefined;
        for (0..256) |i| t[i] = @intCast(i);
        for (logical.lowered_direct) |e| t[e.id] = @intFromEnum(e.form);
        break :blk t;
    };

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
            // S3 keeps final ids byte for byte; only the lowered-direct
            // residents remap (their final slot is reclaimed, their S3
            // byte is still the old direct id).
            .s3 => s3_index_table[id],
            // One comptime-baked load: the temp remap and the
            // lowered-direct residents (C0 end state) are both in the
            // table, replacing the old range branch.
            .lowered => lowered_index_table[id],
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
    pub const dynamic_by_form: [512]?logical.DynamicStack.Shape = blk: {
        @setEvalBranchQuota(20000);
        var t = [_]?logical.DynamicStack.Shape{null} ** 512;
        for (logical.dynamic_stack) |d| t[@intFromEnum(d.form)] = d.shape;
        break :blk t;
    };

    pub fn dynamicShape(form: logical.LogicalOpcode) ?logical.DynamicStack.Shape {
        return dynamic_by_form[@intFromEnum(form)];
    }

    /// No domain parameter: the form already carries it, because the
    /// lowered-only opcodes live at 300+ and the row table is keyed by
    /// form. That the parameter became dead is a small confirmation
    /// that form, not the physical id, is the right key.
    pub fn stackEffect(h: Header, code: []const u8) Error!StackEffect {
        const row = form_row[@intFromEnum(h.form)];
        if (!row.isDynamic()) return .{ .pop = row.pop, .push = row.push };
        if (dynamicShape(h.form)) |shape| {
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
                        .ext0 => .{ .pop = ext0_sub.stackPop(raw), .push = ext0_sub.stackPush(raw) },
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
    const resident = logical.subForm(ext0_sub.put_super_value).?;
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
    // 264 forms: 244 final (one per claimed id), 19 compiler-only and
    // 20 carrier-plane residents (19 demoted using_* plus to_propkey,
    // whose final id 112 was reclaimed when the C0 window closed).
    const counts = comptime blk: {
        var final_count: usize = 0;
        var temp_count: usize = 0;
        var sub_count: usize = 0;
        for (@typeInfo(logical.LogicalOpcode).@"enum".fields) |f| {
            if (f.value >= 400) sub_count += 1 else if (f.value >= 300) temp_count += 1 else final_count += 1;
        }
        break :blk .{ .final = final_count, .temp = temp_count, .sub = sub_count };
    };
    // Comptime so `zig build check` (~70s sema) catches a drift; the
    // 2026-08-30 rebase found these pins at the test tier, one full
    // 2.5-minute test cycle later than necessary.
    comptime {
        if (counts.final != 243) @compileError(std.fmt.comptimePrint("final form count drifted: expected 243, found {d}", .{counts.final}));
        if (counts.temp != 19) @compileError(std.fmt.comptimePrint("temp form count drifted: expected 19, found {d}", .{counts.temp}));
    }
    // The `using` carrier's residents: three of its own operations plus
    // the sixteen opcodes demoted into it. Declaring them is what keeps
    // the demoted set inside the single source rather than outside it.
    comptime {
        if (counts.sub != 21) @compileError(std.fmt.comptimePrint("sub form count drifted: expected 21, found {d}", .{counts.sub}));
    }
    try std.testing.expectEqual(logical.SemanticFamily.ext0_sub, logical.familyOf(.using_set_proto));
    try std.testing.expect(logical.planeOf(.using_set_proto) == .sub);
    try std.testing.expect(logical.planeOf(.get_loc0) == .main);
    comptime {
        if (physical.ledger.claimed != 243) @compileError(std.fmt.comptimePrint("ledger.claimed drifted: expected 243, found {d}", .{physical.ledger.claimed}));
    }

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

test "C0 closed: late-encoding end state, reclaimed id and decode fingerprint" {
    // The pilot resident's final encoding is the carrier tag.
    comptime {
        const enc = decode.finalEncodingOf(.to_propkey);
        if (enc.carrier.carrier != @intFromEnum(logical.LogicalOpcode.ext0) or
            enc.carrier.tag != ext0_sub.to_propkey)
            @compileError("C0 pilot final encoding drifted");
        const direct = decode.finalEncodingOf(.to_number);
        if (direct.direct != @intFromEnum(logical.LogicalOpcode.to_number))
            @compileError("direct final encoding drifted");
    }
    // subForm round-trips the residents and stays closed after them:
    // 21 is the first tag of the reopened gap below the add range.
    try std.testing.expectEqual(@as(?logical.LogicalOpcode, .to_propkey), logical.subForm(ext0_sub.to_propkey));
    try std.testing.expectEqual(@as(?logical.LogicalOpcode, .set_name_computed), logical.subForm(ext0_sub.set_name_computed));
    try std.testing.expectEqual(@as(?logical.LogicalOpcode, null), logical.subForm(21));
    // End state (11.0): the alias is gone, the final slot is
    // quarantined (reclaimed in ledger terms), and the net id is
    // booked: 244 claimed / 12 free.
    try std.testing.expectEqual(@as(?logical.LogicalOpcode, null), physical.aliasOf(112));
    try std.testing.expectEqual(physical.SlotState.reclaimed, physical.stateOf(112));
    // The lowered domain still resolves the direct bytes to their
    // forms; the final domain must reject them.
    {
        const stream = [_]u8{112};
        const lowered = try decode.headerAt(.lowered, &stream, 0);
        try std.testing.expectEqual(logical.LogicalOpcode.to_propkey, lowered.form);
        try std.testing.expectError(error.InvalidOpcode, decode.headerAt(.final, &stream, 0));
    }
    {
        const stream = [_]u8{75};
        const lowered = try decode.headerAt(.lowered, &stream, 0);
        try std.testing.expectEqual(logical.LogicalOpcode.set_name_computed, lowered.form);
        try std.testing.expectError(error.InvalidOpcode, decode.headerAt(.final, &stream, 0));
        try std.testing.expectEqual(physical.SlotState.reclaimed, physical.stateOf(75));
        try std.testing.expectEqual(@as(?logical.LogicalOpcode, null), physical.aliasOf(75));
    }
    // Scanner policy rides the form, so the resident stays visible to
    // the small-inline eligibility walk through subForm (5.2 clause 3).
    try std.testing.expectEqual(logical.InlinePolicy.allowed, logical.traitsOf(.to_propkey).inline_policy);
    // 10.7 pin: reassigning the quarantined id, moving a resident or
    // changing any slot state must consciously update this number in
    // the same commit that earns it.
    try std.testing.expectEqual(@as(u64, 0x166cb5a2882d5cd6), decode.fingerprint);
}

test "physical ledger is derived, not asserted by hand" {
    // The three facts the roadmap and the design documents quote. They are
    // pinned here so a reclaim lands as one declaration edit and the
    // budget follows, instead of being restated in prose.
    // Comptime for the same reason as the count pins above: `zig build
    // check` is the cheapest tier that can see a ledger drift.
    comptime {
        if (physical.ledger.claimed != 243) @compileError(std.fmt.comptimePrint("ledger.claimed drifted: expected 243, found {d}", .{physical.ledger.claimed}));
        if (physical.ledger.reclaimed != 12) @compileError(std.fmt.comptimePrint("ledger.reclaimed drifted: expected 12, found {d}", .{physical.ledger.reclaimed}));
        if (physical.ledger.no_row != 1) @compileError(std.fmt.comptimePrint("ledger.no_row drifted: expected 1, found {d}", .{physical.ledger.no_row}));
        if (physical.ledger.free() != 13) @compileError(std.fmt.comptimePrint("ledger.free drifted: expected 13, found {d}", .{physical.ledger.free()}));
        if (physical.ledger.total() != 256) @compileError(std.fmt.comptimePrint("ledger.total drifted: expected 256, found {d}", .{physical.ledger.total()}));
    }

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
    try std.testing.expectEqual(Format.none_npop, formatOf(op.call2));
    try std.testing.expectEqual(@as(u8, 1), sizeOf(op.call2));
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
    try std.testing.expectEqual(@as(u8, 6), sizeOfPhase1(op.get_field_opt_chain));
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

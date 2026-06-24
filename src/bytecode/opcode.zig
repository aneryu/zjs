const std = @import("std");

const generated = @import("opcodes_generated.zig");

/// Operand format tags (generated from the FMT() list in
/// quickjs-opcode.h).
pub const Format = generated.Format;

/// One row of opcode metadata (QuickJS `JSOpCode`).
pub const Info = generated.Info;

/// Merged metadata table in quickjs-opcode.h file order: normal
/// opcodes at their id, temp opcodes at their id (overlap range),
/// short opcodes shifted `op.op_temp_count` slots past their id.
/// Prefer the view functions below over raw indexing.
pub const opcode_info = generated.opcode_info;

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

/// Auto-generated opcode id constants (source: quickjs-opcode.h).
pub const op = generated.op;

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

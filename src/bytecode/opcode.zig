const std = @import("std");

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
    u32x2,
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

/// Import auto-generated opcode constants from quickjs-opcode.h.
pub const op = @import("opcodes_generated.zig").op;

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

/// Baked opcode-size table generated from `quickjs-opcode.h`. Index is
/// the opcode id (u8); value is the total instruction size in bytes
/// (opcode byte + operand bytes). Temp opcodes take priority over
/// short opcodes in the 179..196 overlap range because the pipeline
/// consumes Phase 1 bytecode before `resolve_labels` lowers temps
/// away.
pub const opcode_size: [256]u8 = @import("opcodes_generated.zig").opcode_size;
pub const opcode_n_pop: [256]u8 = @import("opcodes_generated.zig").opcode_n_pop;
pub const opcode_n_push: [256]u8 = @import("opcodes_generated.zig").opcode_n_push;

/// Baked opcode-format table. Maps opcode id → `Format` enum tag,
/// derived from `quickjs-opcode.h`. Callers should use `formatOf`
/// which converts from the generated string form.
pub const opcode_format_table: [256]Format = blk: {
    @setEvalBranchQuota(200000);
    const names = @import("opcodes_generated.zig").opcode_format_name;
    var formats = [_]Format{.none} ** 256;
    for (names, 0..) |name, i| {
        formats[i] = std.meta.stringToEnum(Format, name) orelse .none;
    }
    break :blk formats;
};

/// Returns the total byte length (opcode + operands) for the given
/// opcode id, or 0 if no opcode occupies that id.
pub fn sizeOf(op_id: u8) u8 {
    return opcode_size[op_id];
}

/// Returns the operand format for the given opcode id (temp takes
/// precedence in the 179..196 overlap range).
pub fn formatOf(op_id: u8) Format {
    return opcode_format_table[op_id];
}

/// Baked opcode-name table for tooling. Indexed by opcode id; slots
/// without a `DEF` entry contain the empty string.
pub const opcode_name: [256][]const u8 = @import("opcodes_generated.zig").opcode_name;

/// Returns the QuickJS opcode name for the given id, or "" if no
/// `DEF` entry claims that id.
pub fn nameOf(op_id: u8) []const u8 {
    return opcode_name[op_id];
}

pub fn nPopOf(op_id: u8) u8 {
    return opcode_n_pop[op_id];
}

pub fn nPushOf(op_id: u8) u8 {
    return opcode_n_push[op_id];
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

test "QuickJS opcode table has no host print opcode names" {
    inline for (@typeInfo(op).@"struct".decls) |decl| {
        try std.testing.expect(!std.mem.eql(u8, decl.name, "host_print"));
        try std.testing.expect(!std.mem.eql(u8, decl.name, "host_print_n"));
    }
}


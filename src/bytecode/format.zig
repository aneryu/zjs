const opcode = @import("opcode.zig");

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

pub fn describe(format: opcode.Format) Description {
    return switch (format) {
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

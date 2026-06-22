//! Bytecode dumper.
//!
//! Walks a `Bytecode.code` buffer and prints a human-readable disassembly
//! similar in spirit to `qjs --bytecode-dump`. Shared by tooling and tests
//! that need to inspect emitted bytecode.

const std = @import("std");
const opcode = @import("opcode.zig");
const function = @import("function.zig");

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
    bc: *const function.Bytecode,
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
    bc: *const function.Bytecode,
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
    bc: *const function.Bytecode,
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

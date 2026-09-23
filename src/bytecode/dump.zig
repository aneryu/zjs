//! Bytecode dumper.
//!
//! Walks a `Bytecode.code` buffer and prints a human-readable disassembly
//! similar in spirit to `qjs --bytecode-dump`. Shared by tooling and tests
//! that need to inspect emitted bytecode.

const std = @import("std");
const bytecode = @import("../bytecode.zig");
const atom = @import("../core/atom.zig");
const runtime = @import("../runtime.zig");
const Bytecode = bytecode.Bytecode;
const FunctionBytecode = bytecode.FunctionBytecode;
const opcode = bytecode.opcode;
const function_bytecode = bytecode.function_bytecode;
const dump = @This();

/// Disassembly options.
pub const Options = struct {
    /// When true, prepend the byte offset of each instruction.
    show_offsets: bool = true,
    /// When true, also dump the raw bytes of each instruction.
    show_raw_bytes: bool = false,
};

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
                const a = atom.Atom.fromRaw(@intCast(value));
                if (atoms.name(a)) |name_str| {
                    try writer.print("\"{s}\"", .{name_str});
                } else {
                    try writer.print("atom#{d}", .{a.raw()});
                }
            },
            .label => try writer.print("L{d}", .{value}),
            .flags => {
                // dyn_env_probe's trailing byte is declared `.flags`
                // (`atom_label_u8`'s template) and decodes to a probe
                // shape; showing it beats showing the raw byte.
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

test "dyn_env_probe flags byte disassembles as kind[,with]" {
    const rt = try runtime.JSRuntime.create(.{ .allocator = std.testing.allocator });
    defer rt.destroy();

    const name = try rt.internAtom("probe-dump");
    // dyn_env_probe is `atom_label_u8`: opcode + atom + label + flags.
    var code = [_]u8{0} ** 10;
    code[0] = opcode.op.dyn_env_probe;
    std.mem.writeInt(u32, code[1..5], name.raw(), .little);
    std.mem.writeInt(i32, code[5..9], 0, .little);
    code[9] = (opcode.dyn_env.Flags{ .kind = .read, .is_with = true }).encode();

    var buf: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try dumpArtifact(&writer, &rt.atoms, name, 0, 0, 1, &code, 0, .{});
    const text = writer.buffered();
    // The special case used to sit on the unreachable `.sub_opcode` arm,
    // so the flags byte printed as a bare number.
    try std.testing.expect(std.mem.indexOf(u8, text, "read,with") != null);
}

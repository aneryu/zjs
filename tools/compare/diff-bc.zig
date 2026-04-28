//! Bytecode op-sequence comparison tool.
//!
//! Reads a ZJS dump and a QuickJS dump, extracts instruction mnemonic
//! sequences, and exits non-zero on the first difference. Operands are
//! intentionally ignored for this M1.4 gate because QuickJS atom and label ids
//! are allocation-order dependent; operand-sensitive parity should be layered
//! on after both dumpers share a stable normalized format.
//!
//! With `--metrics`, also prints a single machine-readable summary line with
//! the compared instruction count and total bytecode bytes from included
//! function sections.

const std = @import("std");

const max_dump_size = 16 * 1024 * 1024;

const Instruction = struct {
    op: []const u8,
    line_no: usize,
};

const DumpInfo = struct {
    instructions: std.ArrayList(Instruction),
    code_len: usize,

    fn deinit(self: *DumpInfo, allocator: std.mem.Allocator) void {
        self.instructions.deinit(allocator);
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try argsToSlice(arena, init.minimal.args);

    var metrics = false;
    var paths: [2][]const u8 = undefined;
    var path_count: usize = 0;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--metrics")) {
            metrics = true;
            continue;
        }
        if (path_count >= paths.len) {
            std.debug.print("Usage: {s} [--metrics] <zjs-dump.txt> <quickjs-dump.txt>\n", .{args[0]});
            std.process.exit(2);
        }
        paths[path_count] = arg;
        path_count += 1;
    }
    if (path_count != paths.len) {
        std.debug.print("Usage: {s} [--metrics] <zjs-dump.txt> <quickjs-dump.txt>\n", .{args[0]});
        std.process.exit(2);
    }

    const zjs_dump = try std.Io.Dir.cwd().readFileAlloc(io, paths[0], allocator, .limited(max_dump_size));
    defer allocator.free(zjs_dump);
    const qjs_dump = try std.Io.Dir.cwd().readFileAlloc(io, paths[1], allocator, .limited(max_dump_size));
    defer allocator.free(qjs_dump);

    var zjs_info = try parseDump(allocator, zjs_dump);
    defer zjs_info.deinit(allocator);
    var qjs_info = try parseDump(allocator, qjs_dump);
    defer qjs_info.deinit(allocator);
    const zjs_ops = zjs_info.instructions.items;
    const qjs_ops = qjs_info.instructions.items;

    if (zjs_ops.len == 0) {
        std.debug.print("diff-bc: no ZJS instructions found in {s}\n", .{paths[0]});
        std.process.exit(1);
    }
    if (qjs_ops.len == 0) {
        std.debug.print("diff-bc: no QuickJS instructions found in {s}\n", .{paths[1]});
        std.process.exit(1);
    }

    const common = @min(zjs_ops.len, qjs_ops.len);
    for (0..common) |i| {
        const z = zjs_ops[i];
        const q = qjs_ops[i];
        if (!std.mem.eql(u8, z.op, q.op)) {
            std.debug.print(
                "diff-bc: opcode mismatch at instruction {d}: ZJS {s} (line {d}) != QuickJS {s} (line {d})\n",
                .{ i, z.op, z.line_no, q.op, q.line_no },
            );
            std.process.exit(1);
        }
    }

    if (zjs_ops.len != qjs_ops.len) {
        std.debug.print(
            "diff-bc: opcode count mismatch: ZJS {d} != QuickJS {d}\n",
            .{ zjs_ops.len, qjs_ops.len },
        );
        std.process.exit(1);
    }

    if (metrics) {
        var stdout_buf: [256]u8 = undefined;
        var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
        try stdout_writer.interface.print(
            "METRIC instructions={d} zjs_code_len={d} quickjs_code_len={d}\n",
            .{ zjs_ops.len, zjs_info.code_len, qjs_info.code_len },
        );
        try stdout_writer.interface.flush();
    }
}

fn argsToSlice(arena: std.mem.Allocator, args: std.process.Args) ![]const []const u8 {
    const raw_args = try args.toSlice(arena);
    const result = try arena.alloc([]const u8, raw_args.len);
    for (raw_args, 0..) |arg, i| result[i] = arg;
    return result;
}

fn parseDump(allocator: std.mem.Allocator, dump: []const u8) !DumpInfo {
    var out = std.ArrayList(Instruction).empty;
    var code_len: usize = 0;
    var lines = std.mem.splitScalar(u8, dump, '\n');
    var line_no: usize = 1;
    var in_instructions = false;
    var section_op_index: usize = 0;
    var skip_count: usize = 0;
    var skip_section = false;
    var next_section_is_eval_input = false;
    var pending_code_len: usize = 0;
    while (lines.next()) |line| : (line_no += 1) {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "<input>:") and std.mem.indexOf(u8, trimmed, "function:") != null) {
            next_section_is_eval_input = true;
        }
        if (parseCodeLenLine(trimmed)) |len| pending_code_len = len;
        if (std.mem.eql(u8, trimmed, "--- instructions ---") or std.mem.startsWith(u8, trimmed, "opcodes:")) {
            in_instructions = true;
            skip_section = next_section_is_eval_input;
            next_section_is_eval_input = false;
            if (!skip_section) code_len += pending_code_len;
            pending_code_len = 0;
            section_op_index = 0;
            skip_count = 0;
            continue;
        }
        if (!in_instructions) continue;
        if (std.mem.eql(u8, trimmed, "--- end ---")) {
            in_instructions = false;
            skip_section = false;
            continue;
        }
        if (extractOpcode(line)) |op| {
            if (skip_section) continue;
            const normalized = normalizeOpcode(op);
            if (section_op_index == 0 and std.mem.eql(u8, normalized, "special_object")) {
                skip_count = 3;
                section_op_index += 1;
                continue;
            }
            if (skip_count != 0) {
                skip_count -= 1;
                section_op_index += 1;
                continue;
            }
            try out.append(allocator, .{ .op = normalized, .line_no = line_no });
            section_op_index += 1;
            if (std.mem.eql(u8, normalized, "return_async")) in_instructions = false;
        }
    }
    return .{ .instructions = out, .code_len = code_len };
}

fn parseCodeLenLine(trimmed: []const u8) ?usize {
    if (std.mem.startsWith(u8, trimmed, "code_len") or
        std.mem.startsWith(u8, trimmed, "byte_code_len"))
    {
        const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse return null;
        const raw_value = std.mem.trim(u8, trimmed[colon + 1 ..], " \t\r");
        return std.fmt.parseInt(usize, raw_value, 10) catch null;
    }
    return null;
}

fn normalizeOpcode(op: []const u8) []const u8 {
    if (std.mem.eql(u8, op, "push_const8")) return "push_atom_value";
    if (std.mem.eql(u8, op, "push_const")) return "push_atom_value";
    if (std.mem.eql(u8, op, "push_bigint_i32")) return "push_atom_value";
    if (std.mem.eql(u8, op, "eval")) return "call1";
    if (std.mem.eql(u8, op, "get_loc_check")) return "get_loc";
    if (std.mem.eql(u8, op, "put_loc_check")) return "put_loc";
    if (std.mem.eql(u8, op, "put_loc_check_init")) return "put_loc";
    if (std.mem.eql(u8, op, "set_var_ref")) return "put_var_ref";
    if (std.mem.eql(u8, op, "set_loc")) return "put_loc";
    if (op.len == "set_var_ref".len + 1 and std.mem.startsWith(u8, op, "set_var_ref") and op["set_var_ref".len] >= '0' and op["set_var_ref".len] <= '3') {
        return "put_var_ref";
    }
    if (op.len == "set_loc".len + 1 and std.mem.startsWith(u8, op, "set_loc") and op["set_loc".len] >= '0' and op["set_loc".len] <= '3') {
        return "put_loc";
    }
    inline for (&.{ "get_var_ref", "put_var_ref", "set_var_ref", "get_arg", "put_arg", "get_loc", "put_loc", "set_loc" }) |base| {
        if (op.len == base.len + 1 and std.mem.startsWith(u8, op, base) and op[base.len] >= '0' and op[base.len] <= '3') {
            return base;
        }
    }
    return op;
}

fn extractOpcode(line: []const u8) ?[]const u8 {
    var text = std.mem.trim(u8, line, " \t\r");
    if (text.len == 0) return null;
    if (std.mem.startsWith(u8, text, "//")) return null;
    if (std.mem.startsWith(u8, text, ";;")) return null;
    if (std.mem.startsWith(u8, text, "===")) return null;
    if (std.mem.startsWith(u8, text, "---")) return null;
    if (std.mem.indexOfScalar(u8, text, ':')) |colon| {
        const before = std.mem.trim(u8, text[0..colon], " \t");
        if (isDecimal(before)) {
            text = std.mem.trim(u8, text[colon + 1 ..], " \t");
        } else if (std.mem.indexOfScalar(u8, before, '"') == null and std.mem.indexOfScalar(u8, before, '\'') == null) {
            return null;
        }
    }

    var tokens = std.mem.tokenizeAny(u8, text, " \t,");
    while (tokens.next()) |token| {
        if (isRawByte(token)) continue;
        if (isMetadataToken(token)) return null;
        if (looksLikeOpcode(token)) return token;
    }
    return null;
}

fn isDecimal(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        if (c < '0' or c > '9') return false;
    }
    return true;
}

fn isRawByte(s: []const u8) bool {
    if (s.len != 2) return false;
    return std.ascii.isHex(s[0]) and std.ascii.isHex(s[1]);
}

fn isMetadataToken(s: []const u8) bool {
    return std.mem.eql(u8, s, "name") or
        std.mem.eql(u8, s, "arg_count") or
        std.mem.eql(u8, s, "var_count") or
        std.mem.eql(u8, s, "stack_size") or
        std.mem.eql(u8, s, "code_len") or
        std.mem.eql(u8, s, "atoms") or
        std.mem.eql(u8, s, "constants") or
        std.mem.eql(u8, s, "loc") or
        std.mem.eql(u8, s, "args") or
        std.mem.eql(u8, s, "var") or
        std.mem.eql(u8, s, "const") or
        std.mem.eql(u8, s, "let") or
        std.mem.eql(u8, s, "bytecode") or
        std.mem.eql(u8, s, "function");
}

fn looksLikeOpcode(s: []const u8) bool {
    if (s.len == 0) return false;
    if (s[0] == '"' or s[0] == '\'' or s[0] == '<') return false;
    if (std.mem.indexOfScalar(u8, s, ':') != null) return false;
    if (std.mem.indexOfScalar(u8, s, '=') != null) return false;
    if (isDecimal(s)) return false;
    for (s) |c| {
        if (std.ascii.isAlphabetic(c) or c == '_' or c == '?' or c == '<') return true;
    }
    return false;
}

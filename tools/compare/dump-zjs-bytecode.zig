//! ZJS bytecode disassembler.
//!
//! Reads a JavaScript file, runs it through the qjs_parser → finalize
//! pipeline, and prints a human-readable disassembly of the produced
//! `Bytecode` to stdout. Used by the M1.4 op-sequence parity gate.
//!
//! Usage: dump-zjs-bytecode [--statement] <script.js>

const std = @import("std");
const engine = @import("quickjs_zig_engine");

const QjsLexer = engine.frontend.qjs_lexer.Lexer;
const qjs_parser = engine.frontend.qjs_parser;
const opcode = engine.bytecode.opcode;

const max_source_size = 16 * 1024 * 1024;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const arena = init.arena.allocator();
    const io = init.io;

    const raw_args = try init.minimal.args.toSlice(arena);
    const args = try arena.alloc([]const u8, raw_args.len);
    for (raw_args, 0..) |arg, i| args[i] = arg;

    var stmt_mode = false;
    var path: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--statement")) {
            stmt_mode = true;
        } else if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            try printUsage(io);
            return;
        } else {
            path = a;
        }
    }

    const file_path = path orelse {
        try printUsage(io);
        std.process.exit(2);
    };

    const source = std.Io.Dir.cwd().readFileAlloc(io, file_path, allocator, .limited(max_source_size)) catch |err| {
        try printError(io, "dump-zjs-bytecode: cannot read {s}: {s}\n", .{ file_path, @errorName(err) });
        std.process.exit(1);
    };
    defer allocator.free(source);

    const rt = engine.core.runtime.Runtime.create(allocator) catch |err| {
        try printError(io, "dump-zjs-bytecode: runtime init failed: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer rt.destroy();

    const name = try rt.internAtom("main");
    defer rt.atoms.free(name);
    var function = engine.bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer function.deinit(rt);

    var lex = QjsLexer.init(allocator, &rt.atoms, source);
    var state = try qjs_parser.ParseState.init(&lex, &function);
    defer state.deinit(rt);
    state.top_level_lexical_as_module_ref = !stmt_mode;
    state.top_level_functions_as_children = !stmt_mode;
    state.function_def.use_short_opcodes = true;

    if (stmt_mode) {
        try qjs_parser.parseStatementOrDecl(&state, qjs_parser.DeclMask{
            .func = true,
            .func_with_label = true,
            .other = true,
        });
    } else {
        // Drive the parser like the program top level: drain every
        // top-level statement until EOF.
        while (state.peekKind() != engine.frontend.qjs_token.TOK_EOF) {
            try qjs_parser.parseStatementOrDecl(&state, qjs_parser.DeclMask{
                .func = true,
                .func_with_label = true,
                .other = true,
            });
        }
    }

    try engine.bytecode.pipeline.finalize.runWithFunctionDef(&function, &state.function_def);
    if (!stmt_mode) try wrapProgramBytecodeForQuickJSDump(&function, &state.function_def);

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    if (!stmt_mode) {
        for (state.function_def.child_list) |*child| {
            try dumpFunctionDefChild(rt, &stdout_writer.interface, child);
        }
    }
    try engine.bytecode.dump.dumpBytecode(&stdout_writer.interface, &function, .{
        .show_offsets = true,
        .show_raw_bytes = false,
    });
    try stdout_writer.interface.flush();
}

fn dumpFunctionDefChild(
    rt: *engine.core.runtime.Runtime,
    writer: *std.Io.Writer,
    child: *engine.bytecode.function_def.FunctionDef,
) !void {
    for (child.child_list) |*grandchild| {
        try dumpFunctionDefChild(rt, writer, grandchild);
    }
    var bc = engine.bytecode.Bytecode.init(child.memory, child.atoms, child.func_name);
    defer bc.deinit(rt);
    bc.opcode_format = .qjs;
    try bc.setCode(child.byte_code);
    for (child.atom_operands) |atom_id| try bc.retainAtomOperand(atom_id);
    try engine.bytecode.pipeline.finalize.runWithFunctionDef(&bc, child);
    try engine.bytecode.dump.dumpBytecode(writer, &bc, .{
        .show_offsets = true,
        .show_raw_bytes = false,
    });
}

fn wrapProgramBytecodeForQuickJSDump(
    function: *engine.bytecode.Bytecode,
    fd: *const engine.bytecode.function_def.FunctionDef,
) !void {
    // QuickJS-ng dumps the top-level script through its async/eval wrapper:
    //   push_this; if_false8 4; return_undef; <body>; undefined; return_async
    // The parser emits the body; add the wrapper in the program dump path so
    // the parity gate compares like with like without affecting expression
    // parser unit tests that call `runWithFunctionDef` directly.
    var init_len: usize = 0;
    for (fd.child_list, 0..) |child, child_idx| {
        if (!child.emit_top_level_closure_init) continue;
        _ = child_idx;
        init_len += 2; // fclosure8 <idx>
        init_len += if (child.top_level_closure_var_idx >= 0 and child.top_level_closure_var_idx < 4) 1 else 3;
    }

    const prefix_len: usize = 3 + init_len + 1;
    const suffix = [_]u8{ opcode.op.@"undefined", opcode.op.return_async };
    const new_len = prefix_len + function.code.len + suffix.len;
    const next = try function.memory.alloc(u8, new_len);
    errdefer function.memory.free(u8, next);
    var out: usize = 0;
    next[out] = opcode.op.push_this;
    out += 1;
    next[out] = opcode.op.if_false8;
    out += 1;
    next[out] = @intCast(1 + init_len + 1);
    out += 1;
    for (fd.child_list, 0..) |child, child_idx| {
        if (!child.emit_top_level_closure_init) continue;
        next[out] = opcode.op.fclosure8;
        next[out + 1] = @intCast(child_idx);
        out += 2;
        const ref_idx: u16 = @intCast(child.top_level_closure_var_idx);
        if (ref_idx < 4) {
            next[out] = opcode.op.put_var_ref0 + @as(u8, @intCast(ref_idx));
            out += 1;
        } else {
            next[out] = opcode.op.put_var_ref;
            std.mem.writeInt(u16, next[out + 1 ..][0..2], ref_idx, .little);
            out += 3;
        }
    }
    next[out] = opcode.op.return_undef;
    out += 1;
    @memcpy(next[out..][0..function.code.len], function.code);
    out += function.code.len;
    @memcpy(next[out..], &suffix);
    if (function.code.len != 0) function.memory.free(u8, function.code);
    function.code = next;
}

fn printUsage(io: anytype) !void {
    var buf: [512]u8 = undefined;
    var w = std.Io.File.stderr().writer(io, &buf);
    try w.interface.print("Usage: dump-zjs-bytecode [--statement] <script.js>\n", .{});
    try w.interface.flush();
}

fn printError(io: anytype, comptime fmt: []const u8, args: anytype) !void {
    var buf: [512]u8 = undefined;
    var w = std.Io.File.stderr().writer(io, &buf);
    try w.interface.print(fmt, args);
    try w.interface.flush();
}

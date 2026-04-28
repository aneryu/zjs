//! F10 pipeline tests: pc2line encoding, stack_size BFS, FunctionDef.

const std = @import("std");
const engine = @import("quickjs_zig_engine");

const bytecode = engine.bytecode;
const core = engine.core;
const atom_module = engine.core.atom;
const pipeline = bytecode.pipeline;
const pc2line = pipeline.pc2line;
const stack_size = pipeline.stack_size;
const function_def = bytecode.function_def;

test "pc2line: empty slot list produces empty buffer" {
    var account = core.memory.MemoryAccount.init(std.testing.allocator);
    var encoded = try pc2line.encode(&account, &.{}, 1, 0);
    defer encoded.deinit();
    try std.testing.expectEqual(@as(usize, 0), encoded.bytes.len);
}

test "pc2line: compact encoding for small line/pc deltas" {
    var account = core.memory.MemoryAccount.init(std.testing.allocator);
    // Two slots: same line, small pc delta. Compact form is one byte
    // (line/pc compact) plus a sleb128 col diff.
    const slots = [_]pc2line.SourceLocSlot{
        .{ .pc = 0, .line_num = 1, .col_num = 1 },
        .{ .pc = 5, .line_num = 1, .col_num = 4 },
    };
    var encoded = try pc2line.encode(&account, &slots, 1, 1);
    defer encoded.deinit();

    // First slot has diff_pc=0, diff_line=0, diff_col=0 from start (1,1) → skipped.
    // Second slot has diff_pc=5, diff_line=0, diff_col=3 from previous.
    // Compact byte = (0 - (-1)) + 5*5 + 1 = 1 + 25 + 1 = 27, then sleb128(3) = 0x03.
    try std.testing.expectEqual(@as(usize, 2), encoded.bytes.len);
    try std.testing.expectEqual(@as(u8, 27), encoded.bytes[0]);
    try std.testing.expectEqual(@as(u8, 3), encoded.bytes[1]);
}

test "pc2line: long encoding for large pc delta" {
    var account = core.memory.MemoryAccount.init(std.testing.allocator);
    const slots = [_]pc2line.SourceLocSlot{
        .{ .pc = 100, .line_num = 2, .col_num = 1 },
    };
    var encoded = try pc2line.encode(&account, &slots, 1, 1);
    defer encoded.deinit();

    // diff_pc=100 > MAX(50) → long form: 0, leb128(100), sleb128(1), sleb128(0).
    try std.testing.expectEqual(@as(usize, 4), encoded.bytes.len);
    try std.testing.expectEqual(@as(u8, 0), encoded.bytes[0]);
    try std.testing.expectEqual(@as(u8, 100), encoded.bytes[1]);
    try std.testing.expectEqual(@as(u8, 1), encoded.bytes[2]); // sleb128(1) for diff_line
    try std.testing.expectEqual(@as(u8, 0), encoded.bytes[3]); // sleb128(0) for diff_col
}

test "pc2line: encode/decode round-trip" {
    var account = core.memory.MemoryAccount.init(std.testing.allocator);
    const input_slots = [_]pc2line.SourceLocSlot{
        .{ .pc = 5, .line_num = 1, .col_num = 4 },
        .{ .pc = 10, .line_num = 2, .col_num = 1 },
        .{ .pc = 200, .line_num = 5, .col_num = 12 },
        .{ .pc = 250, .line_num = 5, .col_num = 25 },
    };
    var encoded = try pc2line.encode(&account, &input_slots, 1, 1);
    defer encoded.deinit();

    const decoded = try pc2line.decode(std.testing.allocator, encoded);
    defer std.testing.allocator.free(decoded);

    try std.testing.expectEqual(input_slots.len, decoded.len);
    for (input_slots, decoded) |expected, actual| {
        try std.testing.expectEqual(expected.pc, actual.pc);
        try std.testing.expectEqual(expected.line_num, actual.line_num);
        try std.testing.expectEqual(expected.col_num, actual.col_num);
    }
}

test "pc2line: skips slots with no real change or backward pc" {
    var account = core.memory.MemoryAccount.init(std.testing.allocator);
    const slots = [_]pc2line.SourceLocSlot{
        .{ .pc = 10, .line_num = 1, .col_num = 5 },
        .{ .pc = 10, .line_num = 1, .col_num = 5 }, // duplicate → skipped
        .{ .pc = 5, .line_num = 1, .col_num = 5 },  // backward pc → skipped
        .{ .pc = 15, .line_num = -1, .col_num = 5 }, // line < 0 → skipped
        .{ .pc = 20, .line_num = 1, .col_num = 8 },  // valid
    };
    var encoded = try pc2line.encode(&account, &slots, 1, 1);
    defer encoded.deinit();

    const decoded = try pc2line.decode(std.testing.allocator, encoded);
    defer std.testing.allocator.free(decoded);

    try std.testing.expectEqual(@as(usize, 2), decoded.len);
    try std.testing.expectEqual(@as(u32, 10), decoded[0].pc);
    try std.testing.expectEqual(@as(u32, 20), decoded[1].pc);
}

test "pc2line: negative line delta encoded compactly" {
    var account = core.memory.MemoryAccount.init(std.testing.allocator);
    const slots = [_]pc2line.SourceLocSlot{
        .{ .pc = 5, .line_num = 5, .col_num = 1 },
        .{ .pc = 10, .line_num = 4, .col_num = 1 }, // diff_line = -1, in compact range
    };
    var encoded = try pc2line.encode(&account, &slots, 1, 1);
    defer encoded.deinit();

    const decoded = try pc2line.decode(std.testing.allocator, encoded);
    defer std.testing.allocator.free(decoded);

    try std.testing.expectEqual(@as(usize, 2), decoded.len);
    try std.testing.expectEqual(@as(i32, 5), decoded[0].line_num);
    try std.testing.expectEqual(@as(i32, 4), decoded[1].line_num);
}

test "stack_size: empty bytecode produces zero stack" {
    const result = try stack_size.compute(&.{}, .{ .opcode_table = null });
    try std.testing.expectEqual(@as(u16, 0), result);
}

fn loadOpcodeTable(allocator: std.mem.Allocator) !struct {
    source: []u8,
    table: bytecode.opcode.ParsedTable,
} {
    const source = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        bytecode.opcode.quickjs_opcode_path,
        allocator,
        .limited(1024 * 1024),
    );
    return .{ .source = source, .table = bytecode.opcode.parse(source) };
}

test "stack_size: simple push + return_undef gives stack=1" {
    const parsed = try loadOpcodeTable(std.testing.allocator);
    defer std.testing.allocator.free(parsed.source);
    const op = bytecode.opcode.op;

    // push_i32 <42> ; return_undef
    var bc = [_]u8{0} ** 6;
    bc[0] = op.push_i32;
    std.mem.writeInt(i32, bc[1..5], 42, .little);
    bc[5] = op.return_undef;

    const result = try stack_size.compute(&bc, .{ .opcode_table = &parsed.table });
    try std.testing.expectEqual(@as(u16, 1), result);
}

test "stack_size: push push add return gives stack=2" {
    const parsed = try loadOpcodeTable(std.testing.allocator);
    defer std.testing.allocator.free(parsed.source);
    const op = bytecode.opcode.op;

    // push_i32 1 ; push_i32 2 ; add ; return_undef
    var bc = [_]u8{0} ** 12;
    bc[0] = op.push_i32;
    std.mem.writeInt(i32, bc[1..5], 1, .little);
    bc[5] = op.push_i32;
    std.mem.writeInt(i32, bc[6..10], 2, .little);
    bc[10] = op.add;
    bc[11] = op.return_undef;

    const result = try stack_size.compute(&bc, .{ .opcode_table = &parsed.table });
    try std.testing.expectEqual(@as(u16, 2), result);
}

test "stack_size: stack underflow detected" {
    const parsed = try loadOpcodeTable(std.testing.allocator);
    defer std.testing.allocator.free(parsed.source);
    const op = bytecode.opcode.op;

    // drop without anything on the stack → underflow.
    const bc = [_]u8{ op.drop, op.return_undef };
    const result = stack_size.compute(&bc, .{ .opcode_table = &parsed.table });
    try std.testing.expectError(error.StackUnderflow, result);
}

test "stack_size: relative goto explored" {
    const parsed = try loadOpcodeTable(std.testing.allocator);
    defer std.testing.allocator.free(parsed.source);
    const op = bytecode.opcode.op;

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

    const result = try stack_size.compute(&bc, .{ .opcode_table = &parsed.table });
    // The drop is unreachable, so max stack = 1 (push_i32) and no underflow.
    try std.testing.expectEqual(@as(u16, 1), result);
}

test "FunctionDef: init/deinit" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("test");
    defer rt.atoms.free(name);

    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);

    try std.testing.expectEqual(@as(atom_module.Atom, name), fd.func_name);
    try std.testing.expectEqual(@as(i32, 0), fd.var_count);
    try std.testing.expectEqual(@as(i32, 0), fd.arg_count);
    try std.testing.expectEqual(@as(i32, 0), fd.scope_count);
    try std.testing.expectEqual(@as(i32, 0), fd.label_count);
    try std.testing.expectEqual(@as(i32, 0), fd.closure_var_count);
    try std.testing.expectEqual(@as(i32, 0), fd.jump_count);
    try std.testing.expectEqual(@as(i32, 0), fd.global_var_count);
    try std.testing.expectEqual(@as(i32, 0), fd.source_loc_count);
    try std.testing.expectEqual(@as(i32, 0), fd.child_list.len);
}

test "FunctionDef: add var" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("x");
    const var_name = try rt.internAtom("var_x");
    defer rt.atoms.free(name);
    defer rt.atoms.free(var_name);

    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);

    const next = try rt.memory.alloc(function_def.VarDef, fd.vars.len + 1);
    errdefer rt.memory.free(function_def.VarDef, next);
    @memcpy(next[0..fd.vars.len], fd.vars);
    next[fd.vars.len] = .{
        .var_name = rt.atoms.dup(var_name),
        .scope_level = 0,
        .is_lexical = true,
        .is_const = false,
        .var_kind = .normal,
    };
    if (fd.vars.len != 0) rt.memory.free(function_def.VarDef, fd.vars);
    fd.vars = next;
    fd.var_count = @intCast(fd.vars.len);

    try std.testing.expectEqual(@as(i32, 1), fd.var_count);
    try std.testing.expectEqual(@as(atom_module.Atom, var_name), fd.vars[0].var_name);
    try std.testing.expect(fd.vars[0].is_lexical);
}

test "FunctionDef: add scope" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("test");
    defer rt.atoms.free(name);

    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);

    const next = try rt.memory.alloc(function_def.VarScope, fd.scopes.len + 1);
    errdefer rt.memory.free(function_def.VarScope, next);
    @memcpy(next[0..fd.scopes.len], fd.scopes);
    next[fd.scopes.len] = .{ .parent = -1, .first = 0 };
    if (fd.scopes.len != 0) rt.memory.free(function_def.VarScope, fd.scopes);
    fd.scopes = next;
    fd.scope_count = @intCast(fd.scopes.len);

    try std.testing.expectEqual(@as(i32, 1), fd.scope_count);
    try std.testing.expectEqual(@as(i32, -1), fd.scopes[0].parent);
}

test "FunctionDef: closure_var" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("test");
    const cv_name = try rt.internAtom("captured");
    defer rt.atoms.free(name);
    defer rt.atoms.free(cv_name);

    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);

    const next = try rt.memory.alloc(function_def.ClosureVar, fd.closure_var.len + 1);
    errdefer rt.memory.free(function_def.ClosureVar, next);
    @memcpy(next[0..fd.closure_var.len], fd.closure_var);
    next[fd.closure_var.len] = .{
        .closure_type = .local,
        .is_lexical = true,
        .var_kind = .normal,
        .var_idx = 0,
        .var_name = rt.atoms.dup(cv_name),
    };
    if (fd.closure_var.len != 0) rt.memory.free(function_def.ClosureVar, fd.closure_var);
    fd.closure_var = next;
    fd.closure_var_count = @intCast(fd.closure_var.len);

    try std.testing.expectEqual(@as(i32, 1), fd.closure_var_count);
    try std.testing.expectEqual(function_def.ClosureType.local, fd.closure_var[0].closure_type);
    try std.testing.expectEqual(@as(atom_module.Atom, cv_name), fd.closure_var[0].var_name);
}

test "FunctionDef: LabelSlot and JumpSlot" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("test");
    defer rt.atoms.free(name);

    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);

    // Add a label slot
    const label_next = try rt.memory.alloc(function_def.LabelSlot, fd.label_slots.len + 1);
    errdefer rt.memory.free(function_def.LabelSlot, label_next);
    @memcpy(label_next[0..fd.label_slots.len], fd.label_slots);
    label_next[fd.label_slots.len] = .{ .ref_count = 1, .pos = 10 };
    if (fd.label_slots.len != 0) rt.memory.free(function_def.LabelSlot, fd.label_slots);
    fd.label_slots = label_next;
    fd.label_count = @intCast(fd.label_slots.len);

    try std.testing.expectEqual(@as(i32, 1), fd.label_count);
    try std.testing.expectEqual(@as(i32, 10), fd.label_slots[0].pos);

    // Add a jump slot
    const jump_next = try rt.memory.alloc(function_def.JumpSlot, fd.jump_slots.len + 1);
    errdefer rt.memory.free(function_def.JumpSlot, jump_next);
    @memcpy(jump_next[0..fd.jump_slots.len], fd.jump_slots);
    jump_next[fd.jump_slots.len] = .{ .op = 100, .size = 5, .pos = 0, .label = 0 };
    if (fd.jump_slots.len != 0) rt.memory.free(function_def.JumpSlot, fd.jump_slots);
    fd.jump_slots = jump_next;
    fd.jump_count = @intCast(fd.jump_slots.len);

    try std.testing.expectEqual(@as(i32, 1), fd.jump_count);
    try std.testing.expectEqual(@as(i32, 100), fd.jump_slots[0].op);
}

test "resolve_variables: scope_get_var → get_var" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("test");
    const x_atom = try rt.internAtom("x");
    defer rt.atoms.free(name);
    defer rt.atoms.free(x_atom);

    var bc = bytecode.function.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer bc.deinit(rt);

    const op = bytecode.opcode.op;

    // Build bytecode: scope_get_var <x> <scope_level=0> ; return_undef
    var input = [_]u8{0} ** 8;
    input[0] = op.scope_get_var;
    std.mem.writeInt(u32, input[1..5], x_atom, .little);
    std.mem.writeInt(u16, input[5..7], 0, .little); // scope_level = 0
    input[7] = op.return_undef;

    try bc.setCode(&input);
    try bc.retainAtomOperand(x_atom);

    // Run resolve_variables
    var ctx = pipeline.resolve_variables.Context.init(&bc);
    try pipeline.resolve_variables.run(&ctx);

    // Expected: get_var <x> ; return_undef (5 + 1 = 6 bytes)
    try std.testing.expectEqual(@as(usize, 6), bc.code.len);
    try std.testing.expectEqual(op.get_var, bc.code[0]);
    const resolved_atom = std.mem.readInt(u32, bc.code[1..5], .little);
    try std.testing.expectEqual(x_atom, resolved_atom);
    try std.testing.expectEqual(op.return_undef, bc.code[5]);
    try std.testing.expectEqual(@as(usize, 1), bc.atom_operands.len);
    try std.testing.expectEqual(x_atom, bc.atom_operands[0]);
}

test "resolve_variables: scope_put_var → put_var" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("test");
    const y_atom = try rt.internAtom("y");
    defer rt.atoms.free(name);
    defer rt.atoms.free(y_atom);

    var bc = bytecode.function.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer bc.deinit(rt);

    const op = bytecode.opcode.op;

    // Build bytecode: scope_put_var <y> <scope_level=1> ; return_undef
    var input = [_]u8{0} ** 8;
    input[0] = op.scope_put_var;
    std.mem.writeInt(u32, input[1..5], y_atom, .little);
    std.mem.writeInt(u16, input[5..7], 1, .little); // scope_level = 1
    input[7] = op.return_undef;

    try bc.setCode(&input);
    try bc.retainAtomOperand(y_atom);

    // Run resolve_variables
    var ctx = pipeline.resolve_variables.Context.init(&bc);
    try pipeline.resolve_variables.run(&ctx);

    // Expected: put_var <y> ; return_undef (5 + 1 = 6 bytes)
    try std.testing.expectEqual(@as(usize, 6), bc.code.len);
    try std.testing.expectEqual(op.put_var, bc.code[0]);
    const resolved_atom = std.mem.readInt(u32, bc.code[1..5], .little);
    try std.testing.expectEqual(y_atom, resolved_atom);
    try std.testing.expectEqual(op.return_undef, bc.code[5]);
    try std.testing.expectEqual(@as(usize, 1), bc.atom_operands.len);
    try std.testing.expectEqual(y_atom, bc.atom_operands[0]);
}

test "resolve_variables: drops enter_scope/leave_scope" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("test");
    defer rt.atoms.free(name);

    var bc = bytecode.function.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer bc.deinit(rt);

    const op = bytecode.opcode.op;

    // Build bytecode: enter_scope <idx=0> ; return_undef ; leave_scope <idx=0>
    var input = [_]u8{0} ** 7;
    input[0] = op.enter_scope;
    std.mem.writeInt(u16, input[1..3], 0, .little);
    input[3] = op.return_undef;
    input[4] = op.leave_scope;
    std.mem.writeInt(u16, input[5..7], 0, .little);

    try bc.setCode(&input);

    // Run resolve_variables
    var ctx = pipeline.resolve_variables.Context.init(&bc);
    try pipeline.resolve_variables.run(&ctx);

    // Expected: only return_undef (1 byte)
    try std.testing.expectEqual(@as(usize, 1), bc.code.len);
    try std.testing.expectEqual(op.return_undef, bc.code[0]);
}

test "resolve_variables: scope_get_var_undef → get_var_undef" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("test");
    const z_atom = try rt.internAtom("z");
    defer rt.atoms.free(name);
    defer rt.atoms.free(z_atom);

    var bc = bytecode.function.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer bc.deinit(rt);

    const op = bytecode.opcode.op;

    // Build bytecode: scope_get_var_undef <z> <scope_level=0> ; return_undef
    var input = [_]u8{0} ** 8;
    input[0] = op.scope_get_var_undef;
    std.mem.writeInt(u32, input[1..5], z_atom, .little);
    std.mem.writeInt(u16, input[5..7], 0, .little);
    input[7] = op.return_undef;

    try bc.setCode(&input);
    try bc.retainAtomOperand(z_atom);

    // Run resolve_variables
    var ctx = pipeline.resolve_variables.Context.init(&bc);
    try pipeline.resolve_variables.run(&ctx);

    // Expected: get_var_undef <z> ; return_undef (5 + 1 = 6 bytes)
    try std.testing.expectEqual(@as(usize, 6), bc.code.len);
    try std.testing.expectEqual(op.get_var_undef, bc.code[0]);
    const resolved_atom = std.mem.readInt(u32, bc.code[1..5], .little);
    try std.testing.expectEqual(z_atom, resolved_atom);
    try std.testing.expectEqual(op.return_undef, bc.code[5]);
    try std.testing.expectEqual(@as(usize, 1), bc.atom_operands.len);
    try std.testing.expectEqual(z_atom, bc.atom_operands[0]);
}

test "resolve_labels: drops label opcodes" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("test");
    defer rt.atoms.free(name);

    var bc = bytecode.function.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer bc.deinit(rt);

    const op = bytecode.opcode.op;

    // Build bytecode: push_i32 42 ; label <id=0> ; return_undef
    var input = [_]u8{0} ** 11;
    input[0] = op.push_i32;
    std.mem.writeInt(i32, input[1..5], 42, .little);
    input[5] = op.label;
    std.mem.writeInt(u32, input[6..10], 0, .little); // label id = 0
    input[10] = op.return_undef;

    try bc.setCode(&input);

    // Run resolve_labels
    var ctx = pipeline.resolve_labels.Context.init(&bc);
    try pipeline.resolve_labels.run(&ctx);

    // Expected: push_i32 42 ; return_undef (5 + 1 = 6 bytes, label dropped)
    try std.testing.expectEqual(@as(usize, 6), bc.code.len);
    try std.testing.expectEqual(op.push_i32, bc.code[0]);
    const value = std.mem.readInt(i32, bc.code[1..5], .little);
    try std.testing.expectEqual(@as(i32, 42), value);
    try std.testing.expectEqual(op.return_undef, bc.code[5]);
}

test "resolve_labels: rewrites absolute goto target to relative offset" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("test");
    defer rt.atoms.free(name);

    var bc = bytecode.function.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer bc.deinit(rt);

    const op = bytecode.opcode.op;

    // push_i32 7 ; goto <absolute pc=11> ; drop ; return
    var input = [_]u8{0} ** 12;
    input[0] = op.push_i32;
    std.mem.writeInt(i32, input[1..5], 7, .little);
    input[5] = op.goto;
    std.mem.writeInt(u32, input[6..10], 11, .little);
    input[10] = op.drop;
    input[11] = op.@"return";
    try bc.setCode(&input);

    var ctx = pipeline.resolve_labels.Context.init(&bc);
    try pipeline.resolve_labels.run(&ctx);

    try std.testing.expectEqual(@as(usize, 12), bc.code.len);
    try std.testing.expectEqual(op.goto, bc.code[5]);
    try std.testing.expectEqual(@as(i32, 5), std.mem.readInt(i32, bc.code[6..10], .little));
}

test "F10.2: resolve_labels selects goto8 for near relative target" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const name = try rt.internAtom("test");
    defer rt.atoms.free(name);

    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);
    fd.use_short_opcodes = true;

    var bc = bytecode.function.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer bc.deinit(rt);

    const op = bytecode.opcode.op;
    // goto <absolute pc=6> ; push_i32 1 ; return
    var input = [_]u8{0} ** 11;
    input[0] = op.goto;
    std.mem.writeInt(u32, input[1..5], 10, .little);
    input[5] = op.push_i32;
    std.mem.writeInt(i32, input[6..10], 1, .little);
    input[10] = op.@"return";
    try bc.setCode(&input);

    var ctx = pipeline.resolve_labels.Context.initWithFunctionDef(&bc, &fd);
    try pipeline.resolve_labels.run(&ctx);

    try std.testing.expectEqual(@as(usize, 4), bc.code.len);
    try std.testing.expectEqual(op.goto8, bc.code[0]);
    try std.testing.expectEqual(@as(i8, 2), @as(i8, @bitCast(bc.code[1])));
    try std.testing.expectEqual(op.push_1, bc.code[2]);
    try std.testing.expectEqual(op.@"return", bc.code[3]);
}

test "F10.2: resolve_labels keeps conditional jump wide when target exceeds i8" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const name = try rt.internAtom("test");
    defer rt.atoms.free(name);

    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);
    fd.use_short_opcodes = true;

    var bc = bytecode.function.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer bc.deinit(rt);

    const op = bytecode.opcode.op;
    var input = [_]u8{op.nop} ** 140;
    input[0] = op.if_false;
    std.mem.writeInt(u32, input[1..5], input.len - 1, .little);
    input[input.len - 1] = op.@"return";
    try bc.setCode(&input);

    var ctx = pipeline.resolve_labels.Context.initWithFunctionDef(&bc, &fd);
    try pipeline.resolve_labels.run(&ctx);

    try std.testing.expectEqual(@as(usize, input.len), bc.code.len);
    try std.testing.expectEqual(op.if_false, bc.code[0]);
    try std.testing.expectEqual(@as(i32, 138), std.mem.readInt(i32, bc.code[1..5], .little));
    try std.testing.expectEqual(op.@"return", bc.code[bc.code.len - 1]);
}

test "finalize: runs full pipeline (resolve_variables + resolve_labels)" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("test");
    const x_atom = try rt.internAtom("x");
    defer rt.atoms.free(name);
    defer rt.atoms.free(x_atom);

    var bc = bytecode.function.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer bc.deinit(rt);

    const op = bytecode.opcode.op;

    // Build bytecode with Phase 1 temp opcodes:
    // enter_scope <idx=0> ; scope_get_var <x> <scope_level=0> ; label <id=0> ; return_undef ; leave_scope <idx=0>
    var input = [_]u8{0} ** 19;
    var pos: usize = 0;
    input[pos] = op.enter_scope;
    pos += 1;
    std.mem.writeInt(u16, input[pos..][0..2], 0, .little);
    pos += 2;
    input[pos] = op.scope_get_var;
    pos += 1;
    std.mem.writeInt(u32, input[pos..][0..4], x_atom, .little);
    pos += 4;
    std.mem.writeInt(u16, input[pos..][0..2], 0, .little);
    pos += 2;
    input[pos] = op.label;
    pos += 1;
    std.mem.writeInt(u32, input[pos..][0..4], 0, .little);
    pos += 4;
    input[pos] = op.return_undef;
    pos += 1;
    input[pos] = op.leave_scope;
    pos += 1;
    std.mem.writeInt(u16, input[pos..][0..2], 0, .little);
    pos += 2;

    try bc.setCode(&input);
    try bc.retainAtomOperand(x_atom);

    // Run full pipeline
    try pipeline.finalize.run(&bc);

    // Expected: get_var <x> ; return_undef (5 + 1 = 6 bytes)
    // enter_scope, leave_scope, and label should all be dropped
    try std.testing.expectEqual(@as(usize, 6), bc.code.len);
    try std.testing.expectEqual(op.get_var, bc.code[0]);
    const resolved_atom = std.mem.readInt(u32, bc.code[1..5], .little);
    try std.testing.expectEqual(x_atom, resolved_atom);
    try std.testing.expectEqual(op.return_undef, bc.code[5]);
    try std.testing.expectEqual(@as(usize, 1), bc.atom_operands.len);
    try std.testing.expectEqual(x_atom, bc.atom_operands[0]);
}
// ---- F10.1b: FunctionDef-driven local-slot lowering ----

test "resolve_variables: scope_get_var → get_loc when var is local" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("test");
    const x_atom = try rt.internAtom("x");
    defer rt.atoms.free(name);
    defer rt.atoms.free(x_atom);

    var bc = bytecode.function.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer bc.deinit(rt);

    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);
    _ = try fd.appendScope(-1);
    _ = try fd.addScopeVar(x_atom, .normal, 0, false, false);

    const op = bytecode.opcode.op;

    // Build bytecode: scope_get_var <x> <scope=0> ; return_undef
    var input = [_]u8{0} ** 8;
    input[0] = op.scope_get_var;
    std.mem.writeInt(u32, input[1..5], x_atom, .little);
    std.mem.writeInt(u16, input[5..7], 0, .little);
    input[7] = op.return_undef;

    try bc.setCode(&input);
    try bc.retainAtomOperand(x_atom);

    var ctx = pipeline.resolve_variables.Context.initWithFunctionDef(&bc, &fd);
    try pipeline.resolve_variables.run(&ctx);

    // F10.2 short-form: idx 0 → 1-byte `get_loc0` (no operand).
    // Expected: get_loc0 ; return_undef (1 + 1 = 2 bytes)
    try std.testing.expectEqual(@as(usize, 2), bc.code.len);
    try std.testing.expectEqual(op.get_loc0, bc.code[0]);
    try std.testing.expectEqual(op.return_undef, bc.code[1]);
    try std.testing.expectEqual(@as(usize, 0), bc.atom_operands.len);
}

test "resolve_variables: scope_put_var → put_loc when var is local" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("test");
    const y_atom = try rt.internAtom("y");
    defer rt.atoms.free(name);
    defer rt.atoms.free(y_atom);

    var bc = bytecode.function.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer bc.deinit(rt);

    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);
    _ = try fd.appendScope(-1);
    // Add 2 vars so y is at index 1.
    const a_atom = try rt.internAtom("a");
    defer rt.atoms.free(a_atom);
    _ = try fd.addScopeVar(a_atom, .normal, 0, false, false);
    _ = try fd.addScopeVar(y_atom, .normal, 0, false, false);

    const op = bytecode.opcode.op;

    var input = [_]u8{0} ** 8;
    input[0] = op.scope_put_var;
    std.mem.writeInt(u32, input[1..5], y_atom, .little);
    std.mem.writeInt(u16, input[5..7], 0, .little);
    input[7] = op.return_undef;

    try bc.setCode(&input);
    try bc.retainAtomOperand(y_atom);

    var ctx = pipeline.resolve_variables.Context.initWithFunctionDef(&bc, &fd);
    try pipeline.resolve_variables.run(&ctx);

    // F10.2 short-form: idx 1 → 1-byte `put_loc1` (no operand).
    try std.testing.expectEqual(@as(usize, 2), bc.code.len);
    try std.testing.expectEqual(op.put_loc1, bc.code[0]);
    try std.testing.expectEqual(op.return_undef, bc.code[1]);
}

test "resolve_variables: unknown atom falls back to global get_var" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("test");
    const x_atom = try rt.internAtom("x");
    const z_atom = try rt.internAtom("z");
    defer rt.atoms.free(name);
    defer rt.atoms.free(x_atom);
    defer rt.atoms.free(z_atom);

    var bc = bytecode.function.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer bc.deinit(rt);

    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);
    _ = try fd.appendScope(-1);
    _ = try fd.addScopeVar(x_atom, .normal, 0, false, false);

    const op = bytecode.opcode.op;

    // Reference `z` which is NOT in fd.vars → must fall back to get_var.
    var input = [_]u8{0} ** 8;
    input[0] = op.scope_get_var;
    std.mem.writeInt(u32, input[1..5], z_atom, .little);
    std.mem.writeInt(u16, input[5..7], 0, .little);
    input[7] = op.return_undef;

    try bc.setCode(&input);
    try bc.retainAtomOperand(z_atom);

    var ctx = pipeline.resolve_variables.Context.initWithFunctionDef(&bc, &fd);
    try pipeline.resolve_variables.run(&ctx);

    // Expected: get_var <z> ; return_undef (5 + 1 = 6 bytes)
    try std.testing.expectEqual(@as(usize, 6), bc.code.len);
    try std.testing.expectEqual(op.get_var, bc.code[0]);
    const resolved_atom = std.mem.readInt(u32, bc.code[1..5], .little);
    try std.testing.expectEqual(z_atom, resolved_atom);
    try std.testing.expectEqual(@as(usize, 1), bc.atom_operands.len);
    try std.testing.expectEqual(z_atom, bc.atom_operands[0]);
}

// ---- F10.2: short-form selection (`put_short_code` mirror) ----

test "F10.2: idx<4 selects 1-byte short form (get_loc0..3)" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const name = try rt.internAtom("test");
    defer rt.atoms.free(name);

    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);
    _ = try fd.appendScope(-1);
    // Build 4 vars. Index 0..3 should map to short forms.
    var atoms_arr: [4]u32 = undefined;
    inline for (.{ "v0", "v1", "v2", "v3" }, 0..) |n, i| {
        atoms_arr[i] = try rt.internAtom(n);
        _ = try fd.addScopeVar(atoms_arr[i], .normal, 0, false, false);
    }
    defer for (atoms_arr) |a| rt.atoms.free(a);

    const op = bytecode.opcode.op;
    const expected_ops = [_]u8{ op.get_loc0, op.get_loc1, op.get_loc2, op.get_loc3 };
    inline for (atoms_arr, expected_ops, 0..) |a, expected, i| {
        _ = i;
        var bc = bytecode.function.Bytecode.init(&rt.memory, &rt.atoms, name);
        defer bc.deinit(rt);

        var input = [_]u8{0} ** 8;
        input[0] = op.scope_get_var;
        std.mem.writeInt(u32, input[1..5], a, .little);
        std.mem.writeInt(u16, input[5..7], 0, .little);
        input[7] = op.return_undef;
        try bc.setCode(&input);
        try bc.retainAtomOperand(a);

        var ctx = pipeline.resolve_variables.Context.initWithFunctionDef(&bc, &fd);
        try pipeline.resolve_variables.run(&ctx);

        // Expected: short_form ; return_undef (1 + 1 = 2 bytes).
        try std.testing.expectEqual(@as(usize, 2), bc.code.len);
        try std.testing.expectEqual(expected, bc.code[0]);
    }
}

test "F10.2: idx∈[4,256) selects 2-byte u8 form (get_loc8)" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const name = try rt.internAtom("test");
    defer rt.atoms.free(name);

    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);
    _ = try fd.appendScope(-1);

    // Add 5 vars; the 5th (index 4) should select get_loc8.
    var buf: [8]u8 = undefined;
    var saved_atoms: [5]u32 = undefined;
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        const var_name = try std.fmt.bufPrint(&buf, "v{d}", .{i});
        const a = try rt.internAtom(var_name);
        saved_atoms[i] = a;
        _ = try fd.addScopeVar(a, .normal, 0, false, false);
    }
    defer for (saved_atoms) |a| rt.atoms.free(a);

    const op = bytecode.opcode.op;
    var bc = bytecode.function.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer bc.deinit(rt);

    const target = saved_atoms[4]; // index 4 → get_loc8
    var input = [_]u8{0} ** 8;
    input[0] = op.scope_get_var;
    std.mem.writeInt(u32, input[1..5], target, .little);
    std.mem.writeInt(u16, input[5..7], 0, .little);
    input[7] = op.return_undef;
    try bc.setCode(&input);
    try bc.retainAtomOperand(target);

    var ctx = pipeline.resolve_variables.Context.initWithFunctionDef(&bc, &fd);
    try pipeline.resolve_variables.run(&ctx);

    // Expected: get_loc8 4 ; return_undef (2 + 1 = 3 bytes).
    try std.testing.expectEqual(@as(usize, 3), bc.code.len);
    try std.testing.expectEqual(op.get_loc8, bc.code[0]);
    try std.testing.expectEqual(@as(u8, 4), bc.code[1]);
    try std.testing.expectEqual(op.return_undef, bc.code[2]);
}

test "F10.2: resolve_labels selects push_i8 for signed 8-bit integer literals" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const name = try rt.internAtom("test");
    defer rt.atoms.free(name);

    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);
    fd.use_short_opcodes = true;

    var bc = bytecode.function.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer bc.deinit(rt);

    const op = bytecode.opcode.op;
    var input = [_]u8{0} ** 6;
    input[0] = op.push_i32;
    std.mem.writeInt(i32, input[1..5], -42, .little);
    input[5] = op.@"return";
    try bc.setCode(&input);

    var ctx = pipeline.resolve_labels.Context.initWithFunctionDef(&bc, &fd);
    try pipeline.resolve_labels.run(&ctx);

    try std.testing.expectEqual(@as(usize, 3), bc.code.len);
    try std.testing.expectEqual(op.push_i8, bc.code[0]);
    try std.testing.expectEqual(@as(u8, @bitCast(@as(i8, -42))), bc.code[1]);
    try std.testing.expectEqual(op.@"return", bc.code[2]);
}

test "F10.2: resolve_labels selects push_i16 outside signed 8-bit range" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const name = try rt.internAtom("test");
    defer rt.atoms.free(name);

    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);
    fd.use_short_opcodes = true;

    var bc = bytecode.function.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer bc.deinit(rt);

    const op = bytecode.opcode.op;
    var input = [_]u8{0} ** 6;
    input[0] = op.push_i32;
    std.mem.writeInt(i32, input[1..5], 300, .little);
    input[5] = op.@"return";
    try bc.setCode(&input);

    var ctx = pipeline.resolve_labels.Context.initWithFunctionDef(&bc, &fd);
    try pipeline.resolve_labels.run(&ctx);

    try std.testing.expectEqual(@as(usize, 4), bc.code.len);
    try std.testing.expectEqual(op.push_i16, bc.code[0]);
    try std.testing.expectEqual(@as(i16, 300), std.mem.readInt(i16, bc.code[1..3], .little));
    try std.testing.expectEqual(op.@"return", bc.code[3]);
}

test "F10.2: resolve_labels coalesces get_loc0 get_loc1" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const name = try rt.internAtom("test");
    defer rt.atoms.free(name);

    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);
    fd.use_short_opcodes = true;

    var bc = bytecode.function.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer bc.deinit(rt);

    const op = bytecode.opcode.op;
    const input = [_]u8{ op.get_loc0, op.get_loc1, op.add, op.@"return" };
    try bc.setCode(&input);

    var ctx = pipeline.resolve_labels.Context.initWithFunctionDef(&bc, &fd);
    try pipeline.resolve_labels.run(&ctx);

    try std.testing.expectEqual(@as(usize, 3), bc.code.len);
    try std.testing.expectEqual(op.get_loc0_loc1, bc.code[0]);
    try std.testing.expectEqual(op.add, bc.code[1]);
    try std.testing.expectEqual(op.@"return", bc.code[2]);
}

test "F10.2: resolve_labels coalesces wide get_loc 0 and get_loc 1 after short selection" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const name = try rt.internAtom("test");
    defer rt.atoms.free(name);

    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);
    fd.use_short_opcodes = true;

    var bc = bytecode.function.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer bc.deinit(rt);

    const op = bytecode.opcode.op;
    var input = [_]u8{0} ** 8;
    input[0] = op.get_loc;
    std.mem.writeInt(u16, input[1..3], 0, .little);
    input[3] = op.get_loc;
    std.mem.writeInt(u16, input[4..6], 1, .little);
    input[6] = op.add;
    input[7] = op.@"return";
    try bc.setCode(&input);

    var ctx = pipeline.resolve_labels.Context.initWithFunctionDef(&bc, &fd);
    try pipeline.resolve_labels.run(&ctx);

    try std.testing.expectEqual(@as(usize, 3), bc.code.len);
    try std.testing.expectEqual(op.get_loc0_loc1, bc.code[0]);
    try std.testing.expectEqual(op.add, bc.code[1]);
    try std.testing.expectEqual(op.@"return", bc.code[2]);
}

test "F10.2: resolve_labels shortens direct loc arg and var_ref slot ops" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const name = try rt.internAtom("test");
    defer rt.atoms.free(name);

    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);
    fd.use_short_opcodes = true;

    var bc = bytecode.function.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer bc.deinit(rt);

    const op = bytecode.opcode.op;
    var input = [_]u8{0} ** 22;
    var i: usize = 0;
    input[i] = op.get_loc;
    std.mem.writeInt(u16, input[i + 1 ..][0..2], 4, .little);
    i += 3;
    input[i] = op.set_loc;
    std.mem.writeInt(u16, input[i + 1 ..][0..2], 2, .little);
    i += 3;
    input[i] = op.get_arg;
    std.mem.writeInt(u16, input[i + 1 ..][0..2], 3, .little);
    i += 3;
    input[i] = op.put_arg;
    std.mem.writeInt(u16, input[i + 1 ..][0..2], 4, .little);
    i += 3;
    input[i] = op.set_arg;
    std.mem.writeInt(u16, input[i + 1 ..][0..2], 1, .little);
    i += 3;
    input[i] = op.set_var_ref;
    std.mem.writeInt(u16, input[i + 1 ..][0..2], 3, .little);
    i += 3;
    input[i] = op.get_var_ref;
    std.mem.writeInt(u16, input[i + 1 ..][0..2], 4, .little);
    i += 3;
    input[i] = op.@"return";
    try bc.setCode(&input);

    var ctx = pipeline.resolve_labels.Context.initWithFunctionDef(&bc, &fd);
    try pipeline.resolve_labels.run(&ctx);

    try std.testing.expectEqual(@as(usize, 13), bc.code.len);
    try std.testing.expectEqual(op.get_loc8, bc.code[0]);
    try std.testing.expectEqual(@as(u8, 4), bc.code[1]);
    try std.testing.expectEqual(op.set_loc2, bc.code[2]);
    try std.testing.expectEqual(op.get_arg3, bc.code[3]);
    try std.testing.expectEqual(op.put_arg, bc.code[4]);
    try std.testing.expectEqual(@as(u16, 4), std.mem.readInt(u16, bc.code[5..7], .little));
    try std.testing.expectEqual(op.set_arg1, bc.code[7]);
    try std.testing.expectEqual(op.set_var_ref3, bc.code[8]);
    try std.testing.expectEqual(op.get_var_ref, bc.code[9]);
    try std.testing.expectEqual(@as(u16, 4), std.mem.readInt(u16, bc.code[10..12], .little));
    try std.testing.expectEqual(op.@"return", bc.code[12]);
}

// ---- M1.3 task1: createFunctionBytecode produces a usable structure ----

test "createFunctionBytecode: copies metadata + bytecode + closure_var from FunctionDef" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("inner");
    defer rt.atoms.free(name);

    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);

    fd.is_strict_mode = true;
    fd.has_simple_parameter_list = false;
    fd.func_kind = .normal;

    // Body: push_i32 42 (5 bytes) + return (1 byte) = 6 bytes input;
    // after short-opcode lowering: push_i8 42 (2 bytes) + return (1 byte) = 3 bytes
    const op = bytecode.opcode.op;
    var body = [_]u8{0} ** 6;
    body[0] = op.push_i32;
    std.mem.writeInt(i32, body[1..5], 42, .little);
    body[5] = op.@"return";
    try fd.appendByteCode(&body);

    // Add a single var so we can verify metadata propagation
    _ = try fd.appendVar(.{
        .var_name = name,
        .scope_level = 0,
        .is_lexical = false,
    });

    const fb_slice = try pipeline.finalize.createFunctionBytecode(&fd, rt);
    const fb = &fb_slice[0];
    defer core.Value.functionBytecode(&fb.header).free(rt);

    try std.testing.expect(fb.is_strict_mode);
    try std.testing.expect(!fb.has_simple_parameter_list);
    try std.testing.expectEqual(@as(usize, 3), fb.byte_code.len);
    try std.testing.expectEqual(@as(i32, 3), fb.byte_code_len);
    try std.testing.expectEqual(op.push_i8, fb.byte_code[0]);
    try std.testing.expectEqual(op.@"return", fb.byte_code[2]);
    try std.testing.expectEqual(@as(usize, 1), fb.vardefs.len);
    try std.testing.expectEqual(name, fb.vardefs[0].var_name);
    try std.testing.expectEqual(@as(u16, 1), fb.var_count);
}

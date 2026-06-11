const std = @import("std");
const build_options = @import("build_options");
const zjs = @import("zjs");
const engine = zjs;

const bytecode = zjs.bytecode;
const core = zjs.core;

test "constant pool retains and releases values" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var pool = bytecode.constant.Pool.init(&rt.memory, &rt.atoms);
    defer pool.deinit(rt);

    const text = try core.string.String.createAscii(rt, "constant");
    const value = text.value();
    const index = try pool.append(value);
    try std.testing.expectEqual(@as(u32, 0), index);
    try std.testing.expectEqual(@as(i32, 2), text.header.rc);

    const loaded = pool.get(0).?;
    try std.testing.expectEqual(@as(i32, 3), text.header.rc);
    loaded.free(rt);
    value.free(rt);
}

test "constant pool appendOwned transfers refcounted values" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var pool = bytecode.constant.Pool.init(&rt.memory, &rt.atoms);
    defer pool.deinit(rt);

    const text = try core.string.String.createAscii(rt, "owned-constant");
    const value = text.value();
    _ = try pool.appendOwned(value);

    try std.testing.expectEqual(@as(i32, 1), text.header.rc);
}

test "constant pool retains owned unique symbol atoms until release" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var pool = bytecode.constant.Pool.init(&rt.memory, &rt.atoms);
    var pool_alive = true;
    defer if (pool_alive) pool.deinit(rt);

    const borrowed_symbol = try rt.atoms.newValueSymbol("gc-bytecode-constant-pool-symbol");
    _ = try pool.append(core.JSValue.symbol(borrowed_symbol));

    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(borrowed_symbol) != null);

    pool.deinit(rt);
    pool_alive = false;

    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(borrowed_symbol) == null);
}

test "constant pool appendOwned retains unique symbol atoms until release" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var pool = bytecode.constant.Pool.init(&rt.memory, &rt.atoms);
    var pool_alive = true;
    defer if (pool_alive) pool.deinit(rt);

    const owned_symbol = try rt.atoms.newValueSymbol("gc-bytecode-constant-pool-owned-symbol");
    _ = try pool.appendOwned(core.JSValue.symbol(owned_symbol));

    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(owned_symbol) != null);

    pool.deinit(rt);
    pool_alive = false;

    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(owned_symbol) == null);
}

test "function bytecode owns code constants module and debug metadata" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("compiled");
    const filename = try rt.internAtom("input.js");
    const local = try rt.internAtom("x");
    const dep = try rt.internAtom("dep.mjs");
    defer rt.atoms.free(name);
    defer rt.atoms.free(filename);
    defer rt.atoms.free(local);
    defer rt.atoms.free(dep);

    var function_bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer function_bc.deinit(rt);

    try function_bc.setCode(&.{ 1, 2, 3 });
    try std.testing.expectEqual(@as(usize, 3), function_bc.code.len);
    _ = try function_bc.addConstant(core.JSValue.int32(7));
    try std.testing.expectEqual(@as(usize, 1), function_bc.constants.values.len);

    const mod_record = function_bc.ensureModule();
    const req_index = try mod_record.addRequest(dep);
    const default_atom = core.atom.predefinedId("*default*", .string).?;
    try mod_record.addImport(req_index, default_atom, local);
    try mod_record.addExport(default_atom, local);
    try mod_record.addIndirectExport(req_index, local, default_atom);
    try mod_record.addStarExport(req_index, default_atom);
    try mod_record.addImportAttribute(req_index, local, default_atom);
    mod_record.has_top_level_await = true;
    try std.testing.expectEqual(@as(usize, 1), mod_record.requests.len);
    try std.testing.expectEqual(@as(usize, 1), mod_record.imports.len);
    try std.testing.expectEqual(@as(usize, 1), mod_record.exports.len);
    try std.testing.expectEqual(@as(usize, 1), mod_record.indirect_exports.len);
    try std.testing.expectEqual(@as(usize, 1), mod_record.star_exports.len);
    try std.testing.expectEqual(@as(usize, 1), mod_record.import_attributes.len);
    try std.testing.expect(mod_record.has_top_level_await);

    const dbg = function_bc.ensureDebug(filename);
    try dbg.add(.{ .pc = 0, .line = 1 });
    try dbg.add(.{ .pc = 3, .line = 2 });
    try std.testing.expectEqual(@as(?u32, 2), dbg.lineForPc(4));
}

test "bytecode setCode skips zero-length allocation" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var function_bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, core.atom.ids.empty_string);
    defer function_bc.deinit(rt);

    const base_bytes = rt.memory.allocated_bytes;
    const base_allocations = rt.memory.allocation_count;

    try function_bc.setCode(&.{});
    try std.testing.expectEqual(@as(usize, 0), function_bc.code.len);
    try std.testing.expectEqual(@as(usize, 0), function_bc.code_capacity);
    try std.testing.expectEqual(base_bytes, rt.memory.allocated_bytes);
    try std.testing.expectEqual(base_allocations, rt.memory.allocation_count);

    try function_bc.setCode(&.{ 1, 2 });
    try std.testing.expectEqual(@as(usize, 2), function_bc.code.len);
    try function_bc.setCode(&.{});
    try std.testing.expectEqual(@as(usize, 0), function_bc.code.len);
    try std.testing.expectEqual(@as(usize, 0), function_bc.code_capacity);
    try std.testing.expectEqual(base_bytes, rt.memory.allocated_bytes);
    try std.testing.expectEqual(base_allocations, rt.memory.allocation_count);
}

test "bytecode module record add failure releases duplicated atom references" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var record = bytecode.module.Record.init(&rt.memory, &rt.atoms);
    defer record.deinit();

    const import_name = try rt.internAtom("oom-bytecode-import");
    const local_name = try rt.internAtom("oom-bytecode-local");

    rt.setMemoryLimit(rt.memory.allocated_bytes);
    try std.testing.expectError(error.OutOfMemory, record.addImport(0, import_name, local_name));
    rt.setMemoryLimit(null);

    try std.testing.expectEqual(@as(usize, 0), record.imports.len);

    rt.atoms.free(import_name);
    rt.atoms.free(local_name);

    try std.testing.expect(rt.atoms.name(import_name) == null);
    try std.testing.expect(rt.atoms.name(local_name) == null);
}

const atom_module = engine.core.atom;
const pipeline = bytecode.pipeline;
const pc2line = pipeline.pc2line;
const stack_size = pipeline.stack_size;
const function_def = bytecode.function_def;

test "FunctionDef: init/deinit" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
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

test "FunctionDef: cpool transfers refcounted owned values" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("cpool-owned");
    defer rt.atoms.free(name);

    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);

    const text = try core.string.String.createAscii(rt, "function-def-owned");
    _ = try fd.appendCpoolOwned(text.value());

    try std.testing.expectEqual(@as(i32, 1), text.header.rc);
}

test "FunctionDef: cpool retains unique symbol atoms until release" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("cpool-symbol");
    defer rt.atoms.free(name);

    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    var fd_alive = true;
    defer if (fd_alive) fd.deinit(rt);

    const borrowed_symbol = try rt.atoms.newValueSymbol("gc-function-def-cpool-symbol");
    _ = try fd.appendCpool(core.JSValue.symbol(borrowed_symbol));

    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(borrowed_symbol) != null);

    fd.deinit(rt);
    fd_alive = false;

    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(borrowed_symbol) == null);
}

test "FunctionDef: cpool appendOwned retains unique symbol atoms until release" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("cpool-owned-symbol");
    defer rt.atoms.free(name);

    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    var fd_alive = true;
    defer if (fd_alive) fd.deinit(rt);

    const owned_symbol = try rt.atoms.newValueSymbol("gc-function-def-cpool-owned-symbol");
    _ = try fd.appendCpoolOwned(core.JSValue.symbol(owned_symbol));

    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(owned_symbol) != null);

    fd.deinit(rt);
    fd_alive = false;

    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(owned_symbol) == null);
}

test "FunctionDef: add var" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("x");
    const var_name = try rt.internAtom("var_x");
    defer rt.atoms.free(name);
    defer rt.atoms.free(var_name);

    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);

    _ = try fd.appendVar(.{
        .var_name = var_name,
        .scope_level = 0,
        .is_lexical = true,
        .is_const = false,
        .var_kind = .normal,
    });

    try std.testing.expectEqual(@as(i32, 1), fd.var_count);
    try std.testing.expectEqual(@as(atom_module.Atom, var_name), fd.vars[0].var_name);
    try std.testing.expect(fd.vars[0].is_lexical);
}

test "FunctionDef: add scope" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("test");
    defer rt.atoms.free(name);

    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);

    _ = try fd.appendScope(-1);
    fd.scopes[0].first = 0;

    try std.testing.expectEqual(@as(i32, 1), fd.scope_count);
    try std.testing.expectEqual(@as(i32, -1), fd.scopes[0].parent);
}

test "FunctionDef: closure_var" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("test");
    const cv_name = try rt.internAtom("captured");
    defer rt.atoms.free(name);
    defer rt.atoms.free(cv_name);

    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);

    _ = try fd.addClosureVar(.{
        .closure_type = .local,
        .is_lexical = true,
        .var_kind = .normal,
        .var_idx = 0,
        .var_name = cv_name,
    });

    try std.testing.expectEqual(@as(i32, 1), fd.closure_var_count);
    try std.testing.expectEqual(function_def.ClosureType.local, fd.closure_var[0].closure_type);
    try std.testing.expectEqual(@as(atom_module.Atom, cv_name), fd.closure_var[0].var_name);
}

test "FunctionDef: LabelSlot and JumpSlot" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
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

test "Bytecode IC allocation skips direct eval and with functions" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("ic_bypass");
    const x_atom = try rt.internAtom("x");
    defer rt.atoms.free(name);
    defer rt.atoms.free(x_atom);

    const op = bytecode.opcode.op;

    var cached = bytecode.function.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer cached.deinit(rt);
    var cached_code = [_]u8{0} ** 6;
    cached_code[0] = op.get_var;
    std.mem.writeInt(u32, cached_code[1..5], x_atom, .little);
    cached_code[5] = op.return_undef;
    try cached.setCode(&cached_code);
    try cached.allocateIcSlots();
    const cacheable_ic_slot_count: usize = if (build_options.zjs_enable_ic) 1 else 0;
    try std.testing.expectEqual(cacheable_ic_slot_count, cached.ic_slots.len);
    try std.testing.expectEqual(build_options.zjs_enable_ic, cached.icSlotForPc(0) != null);

    var direct_eval = bytecode.function.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer direct_eval.deinit(rt);
    var direct_eval_code = [_]u8{0} ** 11;
    direct_eval_code[0] = op.get_var;
    std.mem.writeInt(u32, direct_eval_code[1..5], x_atom, .little);
    direct_eval_code[5] = op.eval;
    std.mem.writeInt(u32, direct_eval_code[6..10], 0, .little);
    direct_eval_code[10] = op.return_undef;
    try direct_eval.setCode(&direct_eval_code);
    try direct_eval.allocateIcSlots();
    try std.testing.expectEqual(@as(usize, 0), direct_eval.ic_slots.len);
    try std.testing.expectEqual(@as(usize, 0), direct_eval.ic_site_ids.len);

    var with_function = bytecode.function.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer with_function.deinit(rt);
    var with_code = [_]u8{0} ** 16;
    with_code[0] = op.get_var;
    std.mem.writeInt(u32, with_code[1..5], x_atom, .little);
    with_code[5] = op.with_get_var;
    std.mem.writeInt(u32, with_code[6..10], x_atom, .little);
    std.mem.writeInt(u32, with_code[10..14], 0, .little);
    with_code[14] = 1;
    with_code[15] = op.return_undef;
    try with_function.setCode(&with_code);
    try with_function.allocateIcSlots();
    try std.testing.expectEqual(@as(usize, 0), with_function.ic_slots.len);
    try std.testing.expectEqual(@as(usize, 0), with_function.ic_site_ids.len);
}

test "resolve_variables: scope_get_var → get_var" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
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
    var ctx = pipeline.resolve_variables.JSContext.init(&bc);
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

test "resolve_variables InvalidBytecode releases retained output atoms" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("resolveInvalidAtomOwner");
    const first_atom = try rt.internAtom("resolveInvalidFirst");
    const second_atom = try rt.internAtom("resolveInvalidSecond");

    var bc = bytecode.function.Bytecode.init(&rt.memory, &rt.atoms, name);

    const op = bytecode.opcode.op;
    var input = [_]u8{0} ** 10;
    input[0] = op.get_var;
    std.mem.writeInt(u32, input[1..5], first_atom, .little);
    input[5] = op.get_var;
    std.mem.writeInt(u32, input[6..10], second_atom, .little);

    try bc.setCode(&input);
    try bc.retainAtomOperand(first_atom);

    var ctx = pipeline.resolve_variables.JSContext.init(&bc);
    try std.testing.expectError(error.InvalidBytecode, pipeline.resolve_variables.run(&ctx));

    bc.deinit(rt);
    rt.atoms.free(second_atom);
    rt.atoms.free(first_atom);
    rt.atoms.free(name);

    try std.testing.expect(rt.atoms.name(first_atom) == null);
}

test "resolve_variables: scope_put_var → put_var" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
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
    var ctx = pipeline.resolve_variables.JSContext.init(&bc);
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
    const rt = try core.JSRuntime.create(std.testing.allocator);
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
    var ctx = pipeline.resolve_variables.JSContext.init(&bc);
    try pipeline.resolve_variables.run(&ctx);

    // Expected: only return_undef (1 byte)
    try std.testing.expectEqual(@as(usize, 1), bc.code.len);
    try std.testing.expectEqual(op.return_undef, bc.code[0]);
}

test "resolve_variables: scope_get_var_undef → get_var_undef" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
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
    var ctx = pipeline.resolve_variables.JSContext.init(&bc);
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
    const rt = try core.JSRuntime.create(std.testing.allocator);
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
    var ctx = pipeline.resolve_labels.JSContext.init(&bc);
    try pipeline.resolve_labels.run(&ctx);

    // Expected: push_i32 42 ; return_undef (5 + 1 = 6 bytes, label dropped)
    try std.testing.expectEqual(@as(usize, 6), bc.code.len);
    try std.testing.expectEqual(op.push_i32, bc.code[0]);
    const value = std.mem.readInt(i32, bc.code[1..5], .little);
    try std.testing.expectEqual(@as(i32, 42), value);
    try std.testing.expectEqual(op.return_undef, bc.code[5]);
}

test "resolve_labels: rewrites absolute goto target to relative offset" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
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

    var ctx = pipeline.resolve_labels.JSContext.init(&bc);
    try pipeline.resolve_labels.run(&ctx);

    try std.testing.expectEqual(@as(usize, 12), bc.code.len);
    try std.testing.expectEqual(op.goto, bc.code[5]);
    try std.testing.expectEqual(@as(i32, 5), std.mem.readInt(i32, bc.code[6..10], .little));
}

test "F10.2: resolve_labels selects goto8 for near relative target" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
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

    var ctx = pipeline.resolve_labels.JSContext.initWithFunctionDef(&bc, &fd);
    try pipeline.resolve_labels.run(&ctx);

    try std.testing.expectEqual(@as(usize, 4), bc.code.len);
    try std.testing.expectEqual(op.goto8, bc.code[0]);
    try std.testing.expectEqual(@as(i8, 2), @as(i8, @bitCast(bc.code[1])));
    try std.testing.expectEqual(op.push_1, bc.code[2]);
    try std.testing.expectEqual(op.@"return", bc.code[3]);
}

test "F10.2: resolve_labels keeps conditional jump wide when target exceeds i8" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
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

    var ctx = pipeline.resolve_labels.JSContext.initWithFunctionDef(&bc, &fd);
    try pipeline.resolve_labels.run(&ctx);

    try std.testing.expectEqual(@as(usize, input.len), bc.code.len);
    try std.testing.expectEqual(op.if_false, bc.code[0]);
    try std.testing.expectEqual(@as(i32, 138), std.mem.readInt(i32, bc.code[1..5], .little));
    try std.testing.expectEqual(op.@"return", bc.code[bc.code.len - 1]);
}

test "finalize: runs full pipeline (resolve_variables + resolve_labels)" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
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
    try std.testing.expectEqual(@as(u16, 1), bc.stack_size);
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
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("test");
    const x_atom = try rt.internAtom("x");
    defer rt.atoms.free(name);
    defer rt.atoms.free(x_atom);

    var bc = bytecode.function.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer bc.deinit(rt);

    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);
    fd.use_short_opcodes = true;
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

    var ctx = pipeline.resolve_variables.JSContext.initWithFunctionDef(&bc, &fd);
    try pipeline.resolve_variables.run(&ctx);

    // F10.2 short-form: idx 0 → 1-byte `get_loc0` (no operand).
    // Expected: get_loc0 ; return_undef (1 + 1 = 2 bytes)
    try std.testing.expectEqual(@as(usize, 2), bc.code.len);
    try std.testing.expectEqual(op.get_loc0, bc.code[0]);
    try std.testing.expectEqual(op.return_undef, bc.code[1]);
    try std.testing.expectEqual(@as(usize, 0), bc.atom_operands.len);
}

test "resolve_variables: scope_put_var → put_loc when var is local" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("test");
    const y_atom = try rt.internAtom("y");
    defer rt.atoms.free(name);
    defer rt.atoms.free(y_atom);

    var bc = bytecode.function.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer bc.deinit(rt);

    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);
    fd.use_short_opcodes = true;
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

    var ctx = pipeline.resolve_variables.JSContext.initWithFunctionDef(&bc, &fd);
    try pipeline.resolve_variables.run(&ctx);

    // F10.2 short-form: idx 1 → 1-byte `put_loc1` (no operand).
    try std.testing.expectEqual(@as(usize, 2), bc.code.len);
    try std.testing.expectEqual(op.put_loc1, bc.code[0]);
    try std.testing.expectEqual(op.return_undef, bc.code[1]);
}

test "resolve_variables: unknown atom falls back to global get_var" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
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
    fd.use_short_opcodes = true;
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

    var ctx = pipeline.resolve_variables.JSContext.initWithFunctionDef(&bc, &fd);
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
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const name = try rt.internAtom("test");
    defer rt.atoms.free(name);

    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);
    fd.use_short_opcodes = true;
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

        var ctx = pipeline.resolve_variables.JSContext.initWithFunctionDef(&bc, &fd);
        try pipeline.resolve_variables.run(&ctx);

        // Expected: short_form ; return_undef (1 + 1 = 2 bytes).
        try std.testing.expectEqual(@as(usize, 2), bc.code.len);
        try std.testing.expectEqual(expected, bc.code[0]);
    }
}

test "F10.2: idx∈[4,256) selects 2-byte u8 form (get_loc8)" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const name = try rt.internAtom("test");
    defer rt.atoms.free(name);

    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);
    fd.use_short_opcodes = true;
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

    var ctx = pipeline.resolve_variables.JSContext.initWithFunctionDef(&bc, &fd);
    try pipeline.resolve_variables.run(&ctx);

    // Expected: get_loc8 4 ; return_undef (2 + 1 = 3 bytes).
    try std.testing.expectEqual(@as(usize, 3), bc.code.len);
    try std.testing.expectEqual(op.get_loc8, bc.code[0]);
    try std.testing.expectEqual(@as(u8, 4), bc.code[1]);
    try std.testing.expectEqual(op.return_undef, bc.code[2]);
}

test "F10.2: resolve_labels selects push_i8 for signed 8-bit integer literals" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
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

    var ctx = pipeline.resolve_labels.JSContext.initWithFunctionDef(&bc, &fd);
    try pipeline.resolve_labels.run(&ctx);

    try std.testing.expectEqual(@as(usize, 3), bc.code.len);
    try std.testing.expectEqual(op.push_i8, bc.code[0]);
    try std.testing.expectEqual(@as(u8, @bitCast(@as(i8, -42))), bc.code[1]);
    try std.testing.expectEqual(op.@"return", bc.code[2]);
}

test "F10.2: resolve_labels selects push_i16 outside signed 8-bit range" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
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

    var ctx = pipeline.resolve_labels.JSContext.initWithFunctionDef(&bc, &fd);
    try pipeline.resolve_labels.run(&ctx);

    try std.testing.expectEqual(@as(usize, 4), bc.code.len);
    try std.testing.expectEqual(op.push_i16, bc.code[0]);
    try std.testing.expectEqual(@as(i16, 300), std.mem.readInt(i16, bc.code[1..3], .little));
    try std.testing.expectEqual(op.@"return", bc.code[3]);
}

test "F10.2: resolve_labels selects push_const8 for small constant pool index" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
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
    input[0] = op.push_const;
    std.mem.writeInt(u32, input[1..5], 7, .little);
    input[5] = op.@"return";
    try bc.setCode(&input);

    var ctx = pipeline.resolve_labels.JSContext.initWithFunctionDef(&bc, &fd);
    try pipeline.resolve_labels.run(&ctx);

    try std.testing.expectEqual(@as(usize, 3), bc.code.len);
    try std.testing.expectEqual(op.push_const8, bc.code[0]);
    try std.testing.expectEqual(@as(u8, 7), bc.code[1]);
    try std.testing.expectEqual(op.@"return", bc.code[2]);
}

test "F10.2: resolve_labels coalesces get_loc0 get_loc1" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
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

    var ctx = pipeline.resolve_labels.JSContext.initWithFunctionDef(&bc, &fd);
    try pipeline.resolve_labels.run(&ctx);

    try std.testing.expectEqual(@as(usize, 3), bc.code.len);
    try std.testing.expectEqual(op.get_loc0_loc1, bc.code[0]);
    try std.testing.expectEqual(op.add, bc.code[1]);
    try std.testing.expectEqual(op.@"return", bc.code[2]);
}

test "F10.2: resolve_labels coalesces wide get_loc 0 and get_loc 1 after short selection" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
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

    var ctx = pipeline.resolve_labels.JSContext.initWithFunctionDef(&bc, &fd);
    try pipeline.resolve_labels.run(&ctx);

    try std.testing.expectEqual(@as(usize, 3), bc.code.len);
    try std.testing.expectEqual(op.get_loc0_loc1, bc.code[0]);
    try std.testing.expectEqual(op.add, bc.code[1]);
    try std.testing.expectEqual(op.@"return", bc.code[2]);
}

test "F10.2: resolve_labels shortens direct loc arg and var_ref slot ops" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
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

    var ctx = pipeline.resolve_labels.JSContext.initWithFunctionDef(&bc, &fd);
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

test "M1.1: resolve_variables lowers private-field temp opcodes" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("test");
    const private_atom = try rt.internAtom("#x");
    defer rt.atoms.free(name);
    defer rt.atoms.free(private_atom);

    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);
    fd.use_short_opcodes = true;
    _ = try fd.appendScope(-1);
    _ = try fd.addScopeVar(private_atom, .private_field, 0, true, true);
    fd.vars[0].tdz_emitted_at_decl = true;

    const op = bytecode.opcode.op;
    const cases = [_]struct {
        temp: u8,
        expected: []const u8,
    }{
        .{ .temp = op.scope_get_private_field, .expected = &.{ op.get_loc0, op.get_private_field, op.return_undef } },
        .{ .temp = op.scope_get_private_field2, .expected = &.{ op.dup, op.get_loc0, op.get_private_field, op.return_undef } },
        .{ .temp = op.scope_put_private_field, .expected = &.{ op.get_loc0, op.put_private_field, op.return_undef } },
        .{ .temp = op.scope_in_private_field, .expected = &.{ op.get_loc0, op.private_in, op.return_undef } },
    };

    for (cases) |case| {
        var bc = bytecode.function.Bytecode.init(&rt.memory, &rt.atoms, name);
        defer bc.deinit(rt);

        var input = [_]u8{0} ** 8;
        input[0] = case.temp;
        std.mem.writeInt(u32, input[1..5], private_atom, .little);
        std.mem.writeInt(u16, input[5..7], 0, .little);
        input[7] = op.return_undef;
        try bc.setCode(&input);
        try bc.retainAtomOperand(private_atom);

        var ctx = pipeline.resolve_variables.JSContext.initWithFunctionDef(&bc, &fd);
        try pipeline.resolve_variables.run(&ctx);

        try std.testing.expectEqualSlices(u8, case.expected, bc.code);
        try std.testing.expectEqual(@as(usize, 0), bc.atom_operands.len);
    }
}

test "M1.1: resolve_variables covers every ClosureType classification" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("test");
    defer rt.atoms.free(name);

    const op = bytecode.opcode.op;
    const closure_types = [_]function_def.ClosureType{
        .local,
        .arg,
        .ref,
        .global_ref,
        .global_decl,
        .global,
        .module_decl,
        .module_import,
    };

    for (closure_types, 0..) |closure_type, idx| {
        const atom_name = try std.fmt.allocPrint(std.testing.allocator, "cv{d}", .{idx});
        defer std.testing.allocator.free(atom_name);
        const var_atom = try rt.internAtom(atom_name);
        defer rt.atoms.free(var_atom);

        var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
        defer fd.deinit(rt);
        fd.use_short_opcodes = true;
        _ = try fd.addClosureVar(.{
            .closure_type = closure_type,
            .is_lexical = false,
            .is_const = false,
            .var_kind = .normal,
            .var_idx = 0,
            .var_name = var_atom,
        });

        var bc = bytecode.function.Bytecode.init(&rt.memory, &rt.atoms, name);
        defer bc.deinit(rt);
        var input = [_]u8{0} ** 8;
        input[0] = op.scope_get_var_undef;
        std.mem.writeInt(u32, input[1..5], var_atom, .little);
        std.mem.writeInt(u16, input[5..7], 0, .little);
        input[7] = op.return_undef;
        try bc.setCode(&input);
        try bc.retainAtomOperand(var_atom);

        var ctx = pipeline.resolve_variables.JSContext.initWithFunctionDef(&bc, &fd);
        try pipeline.resolve_variables.run(&ctx);

        try std.testing.expectEqualSlices(u8, &.{ op.get_var_ref0, op.return_undef }, bc.code);
        try std.testing.expectEqual(@as(usize, 0), bc.atom_operands.len);
    }
}

test "M1.2: resolve_labels emits FunctionDef special-object prologue" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const name = try rt.internAtom("test");
    defer rt.atoms.free(name);

    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);
    fd.home_object_var_idx = 0;
    fd.this_active_func_var_idx = 1;
    fd.new_target_var_idx = 2;
    fd.this_var_idx = 3;
    fd.arguments_var_idx = 4;
    fd.arguments_arg_idx = 5;
    fd.func_var_idx = 6;
    fd.var_object_idx = 7;
    fd.arg_var_object_idx = 8;

    var bc = bytecode.function.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer bc.deinit(rt);

    var ctx = pipeline.resolve_labels.JSContext.initWithFunctionDef(&bc, &fd);
    try pipeline.resolve_labels.run(&ctx);

    const op = bytecode.opcode.op;
    const expected = [_]u8{
        op.special_object, 4,          op.put_loc,        0, 0,
        op.special_object, 2,          op.put_loc,        1, 0,
        op.special_object, 3,          op.put_loc,        2, 0,
        op.push_this,      op.put_loc, 3,                 0, op.special_object,
        1,                 op.set_loc, 5,                 0, op.put_loc,
        4,                 0,          op.special_object, 2, op.put_loc,
        6,                 0,          op.special_object, 5, op.put_loc,
        7,                 0,          op.special_object, 5, op.put_loc,
        8,                 0,
    };
    try std.testing.expectEqualSlices(u8, &expected, bc.code);
}

test "resolve_labels: base class constructor prologue does not duplicate class fields init" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const name = try rt.internAtom("C");
    defer rt.atoms.free(name);

    const op = bytecode.opcode.op;

    {
        var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
        defer fd.deinit(rt);
        fd.func_type = .class_constructor;
        fd.this_var_idx = 0;
        fd.class_fields_init_cpool_idx = 0;

        var bc = bytecode.function.Bytecode.init(&rt.memory, &rt.atoms, name);
        defer bc.deinit(rt);
        try bc.setCode(&.{op.return_undef});

        var ctx = pipeline.resolve_labels.JSContext.initWithFunctionDef(&bc, &fd);
        try pipeline.resolve_labels.run(&ctx);

        const expected = [_]u8{
            op.push_this,    op.put_loc, 0, 0,
            op.return_undef,
        };
        try std.testing.expectEqualSlices(u8, &expected, bc.code);
        const computed = try stack_size.compute(bc.code, .{});
        try std.testing.expectEqual(@as(u16, 1), computed);
    }

    {
        var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
        defer fd.deinit(rt);
        fd.func_type = .class_constructor;
        fd.this_var_idx = 0;

        var bc = bytecode.function.Bytecode.init(&rt.memory, &rt.atoms, name);
        defer bc.deinit(rt);
        try bc.setCode(&.{op.return_undef});

        var ctx = pipeline.resolve_labels.JSContext.initWithFunctionDef(&bc, &fd);
        try pipeline.resolve_labels.run(&ctx);

        const expected = [_]u8{
            op.push_this,    op.put_loc, 0, 0,
            op.return_undef,
        };
        try std.testing.expectEqualSlices(u8, &expected, bc.code);
    }
}

// ---- M1.3 task1: createFunctionBytecode produces a usable structure ----

test "createFunctionBytecode: copies metadata + bytecode + closure_var from FunctionDef" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("inner");
    const arg_name = try rt.internAtom("arg");
    const captured_name = try rt.internAtom("captured");
    const private_name = try rt.internAtom("#p");
    defer rt.atoms.free(name);
    defer rt.atoms.free(arg_name);
    defer rt.atoms.free(captured_name);
    defer rt.atoms.free(private_name);

    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);

    fd.is_strict_mode = true;
    fd.has_prototype = true;
    fd.has_simple_parameter_list = false;
    fd.is_derived_class_constructor = true;
    fd.is_indirect_eval = true;
    fd.func_kind = .async_generator;
    fd.line_num = 7;
    fd.col_num = 3;
    const source = try rt.memory.alloc(u8, "async function* inner(arg) {}".len);
    @memcpy(source, "async function* inner(arg) {}");
    fd.source_text = source;

    // Body: get_var <inner> ; drop ; return_undef. This keeps an atom operand
    // alive through finalization so the VM execution view can be checked too.
    const op = bytecode.opcode.op;
    var body = [_]u8{0} ** 7;
    body[0] = op.get_var;
    std.mem.writeInt(u32, body[1..5], name, .little);
    body[5] = op.drop;
    body[6] = op.return_undef;
    try fd.appendByteCode(&body);
    try fd.appendSourceLoc(2, 8, 5);
    try fd.appendAtomOperand(name);
    _ = try fd.appendCpool(core.JSValue.int32(99));
    _ = try fd.appendArg(.{
        .var_name = arg_name,
        .scope_level = 0,
        .is_lexical = false,
    });

    // Add a single var so we can verify metadata propagation
    _ = try fd.appendVar(.{
        .var_name = name,
        .scope_level = 0,
        .is_lexical = false,
        .is_const = true,
    });
    _ = try fd.addClosureVar(.{
        .closure_type = .local,
        .is_lexical = true,
        .is_const = true,
        .var_idx = 0,
        .var_name = captured_name,
    });
    try fd.appendPrivateBoundName(private_name);

    const fb_slice = try pipeline.finalize.createFunctionBytecode(&fd, rt);
    const fb = &fb_slice[0];
    defer core.JSValue.functionBytecode(&fb.header).free(rt);

    try std.testing.expect(fb.is_strict_mode);
    try std.testing.expect(fb.has_prototype);
    try std.testing.expect(!fb.has_simple_parameter_list);
    try std.testing.expect(fb.is_derived_class_constructor);
    try std.testing.expect(fb.is_indirect_eval);
    try std.testing.expectEqual(function_def.FunctionKind.async_generator, fb.func_kind);
    try std.testing.expectEqual(@as(usize, 7), fb.byte_code.len);
    try std.testing.expectEqual(@as(i32, 7), fb.byte_code_len);
    const cacheable_ic_slot_count: usize = if (build_options.zjs_enable_ic) 1 else 0;
    try std.testing.expectEqual(cacheable_ic_slot_count, fb.ic_slots.len);
    if (build_options.zjs_enable_ic) {
        if (fb.ic_site_ids.len != 0) {
            try std.testing.expectEqual(fb.byte_code.len, fb.ic_site_ids.len);
            try std.testing.expectEqual(@as(usize, 0), fb.ic_site_ids[0]);
        } else {
            try std.testing.expectEqual(@as(usize, 1), fb.ic_sites.len);
            try std.testing.expectEqual(@as(usize, 0), fb.ic_sites[0].pc);
            try std.testing.expectEqual(@as(usize, 0), fb.ic_sites[0].slot_index);
        }
    } else {
        try std.testing.expectEqual(@as(usize, 0), fb.ic_site_ids.len);
        try std.testing.expectEqual(@as(usize, 0), fb.ic_sites.len);
    }
    const bc_view = bytecode.function.asBytecodeView(fb, rt);
    try std.testing.expectEqual(build_options.zjs_enable_ic, bc_view.icSlotForPc(0) != null);
    try std.testing.expect(bc_view.icSlotForPc(5) == null);
    try std.testing.expectEqual(op.get_var, fb.byte_code[0]);
    try std.testing.expectEqual(op.drop, fb.byte_code[5]);
    try std.testing.expectEqual(op.return_undef, fb.byte_code[6]);
    try std.testing.expectEqual(@as(usize, 1), fb.arg_names.len);
    try std.testing.expectEqual(arg_name, fb.arg_names[0]);
    try std.testing.expectEqual(@as(usize, 1), fb.vardefs.len);
    try std.testing.expectEqual(name, fb.vardefs[0].var_name);
    try std.testing.expectEqual(@as(usize, 1), fb.var_names.len);
    try std.testing.expectEqual(name, fb.var_names[0]);
    try std.testing.expect(fb.var_is_const[0]);
    try std.testing.expectEqual(@as(usize, 1), fb.var_ref_names.len);
    try std.testing.expectEqual(captured_name, fb.var_ref_names[0]);
    try std.testing.expect(fb.var_ref_is_lexical[0]);
    try std.testing.expect(fb.var_ref_is_const[0]);
    try std.testing.expectEqual(@as(usize, 1), fb.private_bound_names.len);
    try std.testing.expectEqual(private_name, fb.private_bound_names[0]);
    try std.testing.expectEqual(@as(u16, 1), fb.var_count);
    try std.testing.expectEqual(@as(u16, 1), fb.arg_count);
    try std.testing.expectEqual(@as(u16, 1), fb.defined_arg_count);
    try std.testing.expectEqual(@as(u16, 1), fb.closure_var_count);
    try std.testing.expectEqual(@as(usize, 1), fb.atom_operands.len);
    try std.testing.expectEqual(name, fb.atom_operands[0]);
    try std.testing.expectEqual(@as(i32, 1), fb.cpool_count);
    try std.testing.expectEqual(@as(i32, 99), fb.cpool[0].asInt32().?);
    try std.testing.expectEqual(@as(i32, 7), fb.line_num);
    try std.testing.expectEqual(@as(i32, 3), fb.col_num);
    try std.testing.expect(fb.pc2line_len > 0);
    try std.testing.expectEqualStrings("async function* inner(arg) {}", fb.source.?);

    const view = bytecode.function.asBytecodeView(fb, rt);
    try std.testing.expectEqualSlices(engine.bytecode.ic.Slot, fb.ic_slots, view.ic_slots);
    try std.testing.expectEqualSlices(usize, fb.ic_site_ids, view.ic_site_ids);
    try std.testing.expect(view.flags.is_strict);
    try std.testing.expect(view.flags.is_async);
    try std.testing.expect(view.flags.is_generator);
    try std.testing.expect(view.flags.is_derived_class_constructor);
    try std.testing.expect(view.flags.is_indirect_eval);
    try std.testing.expectEqualSlices(u8, fb.byte_code, view.code);
    try std.testing.expectEqualSlices(atom_module.Atom, fb.atom_operands, view.atom_operands);
    try std.testing.expectEqualSlices(atom_module.Atom, fb.arg_names, view.arg_names);
    try std.testing.expectEqualSlices(atom_module.Atom, fb.var_names, view.var_names);
    try std.testing.expectEqualSlices(bool, fb.var_is_const, view.var_is_const);
    try std.testing.expectEqualSlices(atom_module.Atom, fb.var_ref_names, view.var_ref_names);
    try std.testing.expectEqualSlices(bool, fb.var_ref_is_const, view.var_ref_is_const);
    try std.testing.expectEqualSlices(atom_module.Atom, fb.private_bound_names, view.private_bound_names);
    try std.testing.expectEqualSlices(core.JSValue, fb.cpool, view.constants.values);
    try std.testing.expectEqual(fb.stack_size, view.stack_size);
}

test "createFunctionBytecode accounts large finalized payload in large space" {
    const large_threshold = @sizeOf(bytecode.FunctionBytecode) + 64;
    const large_weight = 7;
    const rt = try core.JSRuntime.createWithOptions(std.testing.allocator, .{
        .gc_policy = .{
            .large_object_threshold = large_threshold,
            .large_weight = large_weight,
            .old_weight = 3,
            .major_debt_threshold = std.math.maxInt(usize),
        },
    });
    defer rt.destroy();

    const name = try rt.internAtom("large_payload_function");
    defer rt.atoms.free(name);

    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);

    const body = [_]u8{bytecode.opcode.op.return_undef};
    try fd.appendByteCode(&body);

    const source = try rt.memory.alloc(u8, large_threshold);
    @memset(source, 'x');
    fd.source_text = source;

    const fb_slice = try pipeline.finalize.createFunctionBytecode(&fd, rt);
    const fb = &fb_slice[0];

    const heap_bytes = fb.heapByteSize();
    try std.testing.expect(heap_bytes >= large_threshold);
    try std.testing.expectEqual(core.gc.Generation.large, fb.header.generation());
    try std.testing.expectEqual(@as(u16, @intCast(@min(heap_bytes, std.math.maxInt(u16)))), fb.header.size_class);

    const stats = rt.gcStats();
    try std.testing.expectEqual(@as(usize, 1), stats.large_alloc_count);
    try std.testing.expectEqual(heap_bytes, stats.large_allocated_bytes);
    try std.testing.expectEqual(heap_bytes, stats.heap_live_bytes);
    try std.testing.expectEqual(heap_bytes, stats.large_object_bytes);
    try std.testing.expect(stats.large_committed_bytes >= heap_bytes);
    try std.testing.expectEqual(stats.large_committed_bytes, stats.heap_committed_bytes);
    try std.testing.expectEqual(@as(usize, 0), stats.old_alloc_count);
    try std.testing.expectEqual(heap_bytes * large_weight, stats.allocation_debt);

    core.JSValue.functionBytecode(&fb.header).free(rt);
    const after_free = rt.gcStats();
    try std.testing.expectEqual(heap_bytes, after_free.total_allocated_bytes);
    try std.testing.expectEqual(heap_bytes, after_free.large_allocated_bytes);
    try std.testing.expectEqual(@as(usize, 0), after_free.heap_live_bytes);
    try std.testing.expectEqual(@as(usize, 0), after_free.large_object_bytes);
    try std.testing.expectEqual(@as(usize, 0), after_free.large_committed_bytes);
    try std.testing.expect(after_free.decommitted_bytes >= heap_bytes);
}

fn observedGcCapacityBytes(before_capacity: usize, after_capacity: usize) usize {
    if (after_capacity <= before_capacity) return 0;
    return (after_capacity - before_capacity) * @sizeOf(*core.gc.ObjectHeader);
}

fn populateFunctionDefForFinalizeFailure(
    rt: *core.JSRuntime,
    fd: *function_def.FunctionDef,
    name: atom_module.Atom,
    arg_name: atom_module.Atom,
    captured_name: atom_module.Atom,
    private_name: atom_module.Atom,
) !void {
    const op = bytecode.opcode.op;
    var body = [_]u8{0} ** 7;
    body[0] = op.get_var;
    std.mem.writeInt(u32, body[1..5], name, .little);
    body[5] = op.drop;
    body[6] = op.return_undef;
    try fd.appendByteCode(&body);
    try fd.appendSourceLoc(2, 8, 5);
    try fd.appendAtomOperand(name);
    _ = try fd.appendCpool(core.JSValue.int32(99));
    _ = try fd.appendArg(.{ .var_name = arg_name, .scope_level = 0, .is_lexical = false });
    _ = try fd.appendVar(.{ .var_name = name, .scope_level = 0, .is_lexical = false, .is_const = true });
    _ = try fd.addClosureVar(.{
        .closure_type = .local,
        .is_lexical = true,
        .is_const = true,
        .var_idx = 0,
        .var_name = captured_name,
    });
    try fd.appendPrivateBoundName(private_name);
    const source_text = "function oom_inner(oom_arg) {}";
    const source = try rt.memory.alloc(u8, source_text.len);
    @memcpy(source, source_text);
    fd.source_text = source;
}

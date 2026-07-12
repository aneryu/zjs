const std = @import("std");
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
    try std.testing.expectEqual(@as(i32, 2), text.header().rc);

    const loaded = pool.get(0).?;
    try std.testing.expectEqual(@as(i32, 3), text.header().rc);
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

    try std.testing.expectEqual(@as(i32, 1), text.header().rc);
}

test "constant pool retains owned unique symbol atoms until release" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var pool = bytecode.constant.Pool.init(&rt.memory, &rt.atoms);
    var pool_alive = true;
    defer if (pool_alive) pool.deinit(rt);

    const borrowed_symbol = try rt.atoms.newValueSymbol("gc-bytecode-constant-pool-symbol");
    const borrowed_value = try rt.symbolValue(borrowed_symbol);
    _ = try pool.append(borrowed_value);
    borrowed_value.free(rt);

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
    _ = try pool.appendOwned(try rt.symbolValue(owned_symbol));

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

test "script or module metadata owns each bytecode transfer" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const display_filename = try rt.internAtom("<eval>");
    const referrer = try rt.internAtom("/fixture/scripts/main.mjs");
    defer rt.atoms.free(display_filename);
    defer rt.atoms.free(referrer);
    const base_ref_count = rt.atoms.refCount(referrer).?;

    var function = bytecode.Bytecode.init(&rt.memory, &rt.atoms, display_filename);
    var function_alive = true;
    defer if (function_alive) function.deinit(rt);
    function.atoms.replace(&function.script_or_module, referrer);
    try std.testing.expectEqual(base_ref_count + 1, rt.atoms.refCount(referrer).?);

    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, display_filename);
    var fd_alive = true;
    defer if (fd_alive) fd.deinit(rt);
    fd.atoms.replace(&fd.script_or_module, referrer);
    try fd.appendByteCode(&.{bytecode.opcode.op.return_undef});
    try std.testing.expectEqual(base_ref_count + 2, rt.atoms.refCount(referrer).?);

    const fb_slice = try pipeline.finalize.createFunctionBytecode(&fd, rt);
    const fb = &fb_slice[0];
    var fb_alive = true;
    defer if (fb_alive) core.JSValue.functionBytecode(&fb.header).free(rt);
    try std.testing.expectEqual(display_filename, fb.filename);
    try std.testing.expectEqual(referrer, fb.scriptOrModule());
    try std.testing.expectEqual(base_ref_count + 3, rt.atoms.refCount(referrer).?);

    const view = bytecode.asBytecodeView(fb, rt);
    try std.testing.expectEqual(display_filename, view.filename);
    try std.testing.expectEqual(referrer, view.script_or_module);

    core.JSValue.functionBytecode(&fb.header).free(rt);
    fb_alive = false;
    try std.testing.expectEqual(base_ref_count + 2, rt.atoms.refCount(referrer).?);

    fd.deinit(rt);
    fd_alive = false;
    try std.testing.expectEqual(base_ref_count + 1, rt.atoms.refCount(referrer).?);

    function.deinit(rt);
    function_alive = false;
    try std.testing.expectEqual(base_ref_count, rt.atoms.refCount(referrer).?);
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

test "bytecode appendCode does not infer direct eval from atom operand bytes" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var function_bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, core.atom.ids.empty_string);
    defer function_bc.deinit(rt);

    const op = bytecode.opcode.op;
    var instruction = [_]u8{ op.push_atom_value, 0, 0, 0, 0 };
    const synthetic_atom = @as(u32, op.eval) | (@as(u32, op.apply_eval) << 8);
    std.mem.writeInt(u32, instruction[1..5], synthetic_atom, .little);

    try std.testing.expectEqual(op.eval, instruction[1]);
    try std.testing.expectEqual(op.apply_eval, instruction[2]);
    try function_bc.appendCode(&instruction);
    try std.testing.expect(!function_bc.flags.has_eval_call);
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

fn resolveEvalDeclarationTarget(
    rt: *core.JSRuntime,
    name: core.Atom,
    declaration_name: core.Atom,
    is_eval: bool,
    closure_vars: []const function_def.ClosureVar,
) !function_def.EvalBindingTarget {
    var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer bc.deinit(rt);
    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);
    fd.is_eval = is_eval;
    _ = try fd.appendScope(-1);
    for (closure_vars) |cv| _ = try fd.addClosureVar(cv);
    try fd.appendGlobalVar(.{
        .cpool_idx = -1,
        .scope_level = 0,
        .var_name = declaration_name,
    });

    const input = [_]u8{bytecode.opcode.op.return_undef};
    try bc.setCode(&input);
    var ctx = pipeline.resolve_variables.JSContext.initWithFunctionDef(&bc, &fd);
    try pipeline.resolve_variables.run(&ctx);
    return fd.global_vars[0].eval_target;
}

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

test "FunctionDef appendByteCode does not infer direct eval from atom operand bytes" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("operand-bytes");
    defer rt.atoms.free(name);

    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);

    const op = bytecode.opcode.op;
    var instruction = [_]u8{ op.push_atom_value, 0, 0, 0, 0 };
    const synthetic_atom = @as(u32, op.eval) | (@as(u32, op.apply_eval) << 8);
    std.mem.writeInt(u32, instruction[1..5], synthetic_atom, .little);

    try std.testing.expectEqual(op.eval, instruction[1]);
    try std.testing.expectEqual(op.apply_eval, instruction[2]);
    try fd.appendByteCode(&instruction);
    try std.testing.expect(!fd.has_eval_call);
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

    try std.testing.expectEqual(@as(i32, 1), text.header().rc);
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
    const borrowed_value = try rt.symbolValue(borrowed_symbol);
    _ = try fd.appendCpool(borrowed_value);
    borrowed_value.free(rt);

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
    _ = try fd.appendCpoolOwned(try rt.symbolValue(owned_symbol));

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

test "resolve_variables: scope_get_var → get_var" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("test");
    const x_atom = try rt.internAtom("x");
    defer rt.atoms.free(name);
    defer rt.atoms.free(x_atom);

    var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer bc.deinit(rt);
    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);
    _ = try fd.appendScope(-1);

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
    var ctx = pipeline.resolve_variables.JSContext.initWithFunctionDef(&bc, &fd);
    try pipeline.resolve_variables.run(&ctx);

    // Expected: get_var <var_ref x> ; return_undef (3 + 1 = 4 bytes)
    try std.testing.expectEqual(@as(usize, 4), bc.code.len);
    try std.testing.expectEqual(op.get_var, bc.code[0]);
    try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, bc.code[1..3], .little));
    try std.testing.expectEqual(op.return_undef, bc.code[3]);
    try std.testing.expectEqual(@as(usize, 0), bc.atom_operands.len);
    try std.testing.expectEqual(@as(usize, 1), fd.closure_var.len);
    try std.testing.expectEqual(x_atom, fd.closure_var[0].var_name);
    try std.testing.expectEqual(function_def.ClosureType.global, fd.closure_var[0].closure_type);
}

test "resolve_variables preserves three-byte apply_eval with nonzero scope high byte" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("apply-eval-size");
    defer rt.atoms.free(name);

    var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer bc.deinit(rt);
    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);

    const op = bytecode.opcode.op;
    const raw_scope_idx = @as(u16, op.eval) << 8;
    var input = [_]u8{ op.apply_eval, 0, 0, op.return_undef };
    std.mem.writeInt(u16, input[1..3], raw_scope_idx, .little);

    try bc.setCode(&input);
    var ctx = pipeline.resolve_variables.JSContext.initWithFunctionDef(&bc, &fd);
    try pipeline.resolve_variables.run(&ctx);

    try std.testing.expectEqualSlices(u8, &input, bc.code);
    try std.testing.expectEqual(raw_scope_idx, std.mem.readInt(u16, bc.code[1..3], .little));
}

test "resolve_variables: eval declarations resolve ordered binding targets" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("eval-target-order");
    const x_atom = try rt.internAtom("x");
    defer rt.atoms.free(name);
    defer rt.atoms.free(x_atom);

    const exact_then_var = [_]function_def.ClosureVar{
        .{ .closure_type = .ref, .var_idx = 0, .var_name = x_atom },
        .{ .closure_type = .ref, .var_idx = 1, .var_name = core.atom.ids.var_object },
    };
    switch (try resolveEvalDeclarationTarget(rt, name, x_atom, true, &exact_then_var)) {
        .closure => |idx| try std.testing.expectEqual(@as(u16, 0), idx),
        else => try std.testing.expect(false),
    }

    const global_then_var = [_]function_def.ClosureVar{
        .{ .closure_type = .global, .var_idx = 0, .var_name = x_atom },
        .{ .closure_type = .ref, .var_idx = 1, .var_name = core.atom.ids.var_object },
    };
    switch (try resolveEvalDeclarationTarget(rt, name, x_atom, true, &global_then_var)) {
        .var_object => |idx| try std.testing.expectEqual(@as(u16, 1), idx),
        else => try std.testing.expect(false),
    }

    const with_then_var = [_]function_def.ClosureVar{
        .{ .closure_type = .ref, .var_idx = 0, .var_name = core.atom.ids.with_object },
        .{ .closure_type = .ref, .var_idx = 1, .var_name = core.atom.ids.var_object },
    };
    switch (try resolveEvalDeclarationTarget(rt, name, x_atom, true, &with_then_var)) {
        .var_object => |idx| try std.testing.expectEqual(@as(u16, 1), idx),
        else => try std.testing.expect(false),
    }
    const with_only = [_]function_def.ClosureVar{
        .{ .closure_type = .ref, .var_idx = 0, .var_name = core.atom.ids.with_object },
    };
    switch (try resolveEvalDeclarationTarget(rt, name, x_atom, true, &with_only)) {
        .global => {},
        else => try std.testing.expect(false),
    }

    const arg_then_body = [_]function_def.ClosureVar{
        .{ .closure_type = .ref, .var_idx = 0, .var_name = core.atom.ids.arg_var_object },
        .{ .closure_type = .ref, .var_idx = 1, .var_name = core.atom.ids.var_object },
    };
    switch (try resolveEvalDeclarationTarget(rt, name, x_atom, true, &arg_then_body)) {
        .var_object => |idx| try std.testing.expectEqual(@as(u16, 0), idx),
        else => try std.testing.expect(false),
    }
    const body_then_arg = [_]function_def.ClosureVar{
        .{ .closure_type = .ref, .var_idx = 0, .var_name = core.atom.ids.var_object },
        .{ .closure_type = .ref, .var_idx = 1, .var_name = core.atom.ids.arg_var_object },
    };
    switch (try resolveEvalDeclarationTarget(rt, name, x_atom, true, &body_then_arg)) {
        .var_object => |idx| try std.testing.expectEqual(@as(u16, 0), idx),
        else => try std.testing.expect(false),
    }

    switch (try resolveEvalDeclarationTarget(rt, name, x_atom, false, &exact_then_var)) {
        .global => {},
        else => try std.testing.expect(false),
    }
}

test "resolve_variables: direct eval var object probes unresolved reads" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("test");
    const x_atom = try rt.internAtom("x");
    defer rt.atoms.free(name);
    defer rt.atoms.free(x_atom);

    var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer bc.deinit(rt);
    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);
    _ = try fd.appendScope(-1);
    fd.var_object_idx = try fd.addScopeVar(core.atom.ids.var_object, .normal, 0, false, false);

    const op = bytecode.opcode.op;

    var input = [_]u8{0} ** 8;
    input[0] = op.scope_get_var;
    std.mem.writeInt(u32, input[1..5], x_atom, .little);
    std.mem.writeInt(u16, input[5..7], 0, .little);
    input[7] = op.return_undef;

    try bc.setCode(&input);
    try bc.retainAtomOperand(x_atom);

    var ctx = pipeline.resolve_variables.JSContext.initWithFunctionDef(&bc, &fd);
    try pipeline.resolve_variables.run(&ctx);

    try std.testing.expectEqual(@as(usize, 17), bc.code.len);
    try std.testing.expectEqual(op.get_loc, bc.code[0]);
    try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, bc.code[1..3], .little));
    try std.testing.expectEqual(op.with_get_var, bc.code[3]);
    try std.testing.expectEqual(x_atom, std.mem.readInt(u32, bc.code[4..8], .little));
    try std.testing.expectEqual(@as(u32, 16), std.mem.readInt(u32, bc.code[8..12], .little));
    try std.testing.expectEqual(@as(u8, 0), bc.code[12]);
    try std.testing.expectEqual(op.get_var, bc.code[13]);
    try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, bc.code[14..16], .little));
    try std.testing.expectEqual(op.return_undef, bc.code[16]);
    try std.testing.expectEqual(@as(usize, 1), bc.atom_operands.len);
    try std.testing.expectEqual(x_atom, bc.atom_operands[0]);
    try std.testing.expectEqual(@as(usize, 1), fd.closure_var.len);
    try std.testing.expectEqual(x_atom, fd.closure_var[0].var_name);
    try std.testing.expectEqual(function_def.ClosureType.global, fd.closure_var[0].closure_type);
}

test "resolve_variables: direct eval var object probes before arg var object" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("test");
    const x_atom = try rt.internAtom("x");
    defer rt.atoms.free(name);
    defer rt.atoms.free(x_atom);

    var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer bc.deinit(rt);
    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);
    _ = try fd.appendScope(-1);
    fd.arg_var_object_idx = try fd.addScopeVar(core.atom.ids.arg_var_object, .normal, 0, false, false);
    fd.var_object_idx = try fd.addScopeVar(core.atom.ids.var_object, .normal, 0, false, false);

    const op = bytecode.opcode.op;

    var input = [_]u8{0} ** 8;
    input[0] = op.scope_get_var;
    std.mem.writeInt(u32, input[1..5], x_atom, .little);
    std.mem.writeInt(u16, input[5..7], 0, .little);
    input[7] = op.return_undef;

    try bc.setCode(&input);
    try bc.retainAtomOperand(x_atom);

    var ctx = pipeline.resolve_variables.JSContext.initWithFunctionDef(&bc, &fd);
    try pipeline.resolve_variables.run(&ctx);

    try std.testing.expectEqual(@as(usize, 30), bc.code.len);
    try std.testing.expectEqual(op.get_loc, bc.code[0]);
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, bc.code[1..3], .little));
    try std.testing.expectEqual(op.with_get_var, bc.code[3]);
    try std.testing.expectEqual(x_atom, std.mem.readInt(u32, bc.code[4..8], .little));
    try std.testing.expectEqual(@as(u32, 29), std.mem.readInt(u32, bc.code[8..12], .little));
    try std.testing.expectEqual(@as(u8, 0), bc.code[12]);
    try std.testing.expectEqual(op.get_loc, bc.code[13]);
    try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, bc.code[14..16], .little));
    try std.testing.expectEqual(op.with_get_var, bc.code[16]);
    try std.testing.expectEqual(x_atom, std.mem.readInt(u32, bc.code[17..21], .little));
    try std.testing.expectEqual(@as(u32, 29), std.mem.readInt(u32, bc.code[21..25], .little));
    try std.testing.expectEqual(@as(u8, 0), bc.code[25]);
    try std.testing.expectEqual(op.get_var, bc.code[26]);
    try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, bc.code[27..29], .little));
    try std.testing.expectEqual(op.return_undef, bc.code[29]);
    try std.testing.expectEqual(@as(usize, 2), bc.atom_operands.len);
    try std.testing.expectEqual(x_atom, bc.atom_operands[0]);
    try std.testing.expectEqual(x_atom, bc.atom_operands[1]);
}

test "resolve_variables: direct eval var object probes closure reads" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("test");
    const x_atom = try rt.internAtom("x");
    defer rt.atoms.free(name);
    defer rt.atoms.free(x_atom);

    var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer bc.deinit(rt);
    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);
    _ = try fd.appendScope(-1);
    fd.var_object_idx = try fd.addScopeVar(core.atom.ids.var_object, .normal, 0, false, false);
    _ = try fd.addClosureVar(.{
        .closure_type = .ref,
        .is_lexical = false,
        .is_const = false,
        .var_kind = .normal,
        .var_idx = 0,
        .var_name = x_atom,
    });

    const op = bytecode.opcode.op;
    var input = [_]u8{0} ** 8;
    input[0] = op.scope_get_var;
    std.mem.writeInt(u32, input[1..5], x_atom, .little);
    std.mem.writeInt(u16, input[5..7], 0, .little);
    input[7] = op.return_undef;

    try bc.setCode(&input);
    try bc.retainAtomOperand(x_atom);

    var ctx = pipeline.resolve_variables.JSContext.initWithFunctionDef(&bc, &fd);
    try pipeline.resolve_variables.run(&ctx);

    try std.testing.expectEqual(@as(usize, 17), bc.code.len);
    try std.testing.expectEqual(op.get_loc, bc.code[0]);
    try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, bc.code[1..3], .little));
    try std.testing.expectEqual(op.with_get_var, bc.code[3]);
    try std.testing.expectEqual(x_atom, std.mem.readInt(u32, bc.code[4..8], .little));
    try std.testing.expectEqual(@as(u32, 16), std.mem.readInt(u32, bc.code[8..12], .little));
    try std.testing.expectEqual(@as(u8, 0), bc.code[12]);
    try std.testing.expectEqual(op.get_var_ref, bc.code[13]);
    try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, bc.code[14..16], .little));
    try std.testing.expectEqual(op.return_undef, bc.code[16]);
    try std.testing.expectEqual(@as(usize, 1), bc.atom_operands.len);
    try std.testing.expectEqual(x_atom, bc.atom_operands[0]);
    try std.testing.expectEqual(@as(usize, 1), fd.closure_var.len);
    try std.testing.expectEqual(x_atom, fd.closure_var[0].var_name);
}

test "resolve_variables: nearer closure binding stops later eval var object probe" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("test");
    const x_atom = try rt.internAtom("x");
    defer rt.atoms.free(name);
    defer rt.atoms.free(x_atom);

    var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer bc.deinit(rt);
    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);
    _ = try fd.appendScope(-1);
    _ = try fd.addClosureVar(.{
        .closure_type = .ref,
        .is_lexical = true,
        .is_const = false,
        .var_kind = .normal,
        .var_idx = 0,
        .var_name = x_atom,
    });
    _ = try fd.addClosureVar(.{
        .closure_type = .ref,
        .is_lexical = false,
        .is_const = false,
        .var_kind = .normal,
        .var_idx = 1,
        .var_name = core.atom.ids.var_object,
    });

    const op = bytecode.opcode.op;
    var input = [_]u8{0} ** 8;
    input[0] = op.scope_get_var;
    std.mem.writeInt(u32, input[1..5], x_atom, .little);
    std.mem.writeInt(u16, input[5..7], 0, .little);
    input[7] = op.return_undef;

    try bc.setCode(&input);
    try bc.retainAtomOperand(x_atom);

    var ctx = pipeline.resolve_variables.JSContext.initWithFunctionDef(&bc, &fd);
    try pipeline.resolve_variables.run(&ctx);

    try std.testing.expectEqual(@as(usize, 4), bc.code.len);
    try std.testing.expectEqual(op.get_var_ref_check, bc.code[0]);
    try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, bc.code[1..3], .little));
    try std.testing.expectEqual(op.return_undef, bc.code[3]);
    try std.testing.expectEqual(@as(usize, 0), bc.atom_operands.len);
}

test "resolve_variables: direct eval var object probes unresolved deletes" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("test");
    const x_atom = try rt.internAtom("x");
    defer rt.atoms.free(name);
    defer rt.atoms.free(x_atom);

    var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer bc.deinit(rt);
    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);
    _ = try fd.appendScope(-1);
    fd.var_object_idx = try fd.addScopeVar(core.atom.ids.var_object, .normal, 0, false, false);

    const op = bytecode.opcode.op;

    var input = [_]u8{0} ** 8;
    input[0] = op.scope_delete_var;
    std.mem.writeInt(u32, input[1..5], x_atom, .little);
    std.mem.writeInt(u16, input[5..7], 0, .little);
    input[7] = op.return_undef;

    try bc.setCode(&input);
    try bc.retainAtomOperand(x_atom);

    var ctx = pipeline.resolve_variables.JSContext.initWithFunctionDef(&bc, &fd);
    try pipeline.resolve_variables.run(&ctx);

    try std.testing.expectEqual(@as(usize, 19), bc.code.len);
    try std.testing.expectEqual(op.get_loc, bc.code[0]);
    try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, bc.code[1..3], .little));
    try std.testing.expectEqual(op.with_delete_var, bc.code[3]);
    try std.testing.expectEqual(x_atom, std.mem.readInt(u32, bc.code[4..8], .little));
    try std.testing.expectEqual(@as(u32, 18), std.mem.readInt(u32, bc.code[8..12], .little));
    try std.testing.expectEqual(@as(u8, 0), bc.code[12]);
    try std.testing.expectEqual(op.delete_var, bc.code[13]);
    try std.testing.expectEqual(x_atom, std.mem.readInt(u32, bc.code[14..18], .little));
    try std.testing.expectEqual(op.return_undef, bc.code[18]);
    try std.testing.expectEqual(@as(usize, 2), bc.atom_operands.len);
    try std.testing.expectEqual(x_atom, bc.atom_operands[0]);
    try std.testing.expectEqual(x_atom, bc.atom_operands[1]);
}

test "resolve_variables: direct eval var object probes unresolved writes" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("test");
    const x_atom = try rt.internAtom("x");
    defer rt.atoms.free(name);
    defer rt.atoms.free(x_atom);

    var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer bc.deinit(rt);
    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);
    _ = try fd.appendScope(-1);
    fd.var_object_idx = try fd.addScopeVar(core.atom.ids.var_object, .normal, 0, false, false);

    const op = bytecode.opcode.op;

    var input = [_]u8{0} ** 8;
    input[0] = op.scope_put_var;
    std.mem.writeInt(u32, input[1..5], x_atom, .little);
    std.mem.writeInt(u16, input[5..7], 0, .little);
    input[7] = op.return_undef;

    try bc.setCode(&input);
    try bc.retainAtomOperand(x_atom);

    var ctx = pipeline.resolve_variables.JSContext.initWithFunctionDef(&bc, &fd);
    try pipeline.resolve_variables.run(&ctx);

    try std.testing.expectEqual(@as(usize, 17), bc.code.len);
    try std.testing.expectEqual(op.get_loc, bc.code[0]);
    try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, bc.code[1..3], .little));
    try std.testing.expectEqual(op.with_put_var, bc.code[3]);
    try std.testing.expectEqual(x_atom, std.mem.readInt(u32, bc.code[4..8], .little));
    try std.testing.expectEqual(@as(u32, 16), std.mem.readInt(u32, bc.code[8..12], .little));
    try std.testing.expectEqual(
        @intFromEnum(bytecode.opcode.WithPutMode.var_object_probe),
        bc.code[12],
    );
    try std.testing.expectEqual(op.put_var, bc.code[13]);
    try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, bc.code[14..16], .little));
    try std.testing.expectEqual(op.return_undef, bc.code[16]);
    try std.testing.expectEqual(@as(usize, 1), bc.atom_operands.len);
    try std.testing.expectEqual(x_atom, bc.atom_operands[0]);
    try std.testing.expectEqual(@as(usize, 1), fd.closure_var.len);
    try std.testing.expectEqual(x_atom, fd.closure_var[0].var_name);
    try std.testing.expectEqual(function_def.ClosureType.global, fd.closure_var[0].closure_type);
}

test "resolve_variables: scope put operand preserves global sentinel and no-dynamic flag" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("scope-put-operands");
    const x_atom = try rt.internAtom("x");
    defer rt.atoms.free(name);
    defer rt.atoms.free(x_atom);

    const op = bytecode.opcode.op;
    const operands = [_]u16{
        std.math.maxInt(u16),
        bytecode.opcode.scope_no_dynamic_env_flag,
    };
    for (operands) |scope_operand| {
        var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
        defer bc.deinit(rt);
        var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
        defer fd.deinit(rt);
        _ = try fd.appendScope(-1);
        fd.var_object_idx = try fd.addScopeVar(core.atom.ids.var_object, .normal, 0, false, false);

        var input = [_]u8{0} ** 8;
        input[0] = op.scope_put_var;
        std.mem.writeInt(u32, input[1..5], x_atom, .little);
        std.mem.writeInt(u16, input[5..7], scope_operand, .little);
        input[7] = op.return_undef;
        try bc.setCode(&input);
        try bc.retainAtomOperand(x_atom);

        var ctx = pipeline.resolve_variables.JSContext.initWithFunctionDef(&bc, &fd);
        try pipeline.resolve_variables.run(&ctx);

        try std.testing.expectEqual(@as(usize, 4), bc.code.len);
        try std.testing.expectEqual(op.put_var, bc.code[0]);
        try std.testing.expectEqual(op.return_undef, bc.code[3]);
        try std.testing.expectEqual(@as(usize, 0), bc.atom_operands.len);
    }
}

test "resolve_variables: with put probes carry with mode" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("with-put-mode");
    const x_atom = try rt.internAtom("x");
    defer rt.atoms.free(name);
    defer rt.atoms.free(x_atom);

    var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer bc.deinit(rt);
    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);
    _ = try fd.appendScope(-1);
    _ = try fd.addScopeVar(core.atom.ids.with_object, .normal, 0, false, false);

    const op = bytecode.opcode.op;
    var input = [_]u8{0} ** 8;
    input[0] = op.scope_put_var;
    std.mem.writeInt(u32, input[1..5], x_atom, .little);
    std.mem.writeInt(u16, input[5..7], 0, .little);
    input[7] = op.return_undef;
    try bc.setCode(&input);
    try bc.retainAtomOperand(x_atom);

    var ctx = pipeline.resolve_variables.JSContext.initWithFunctionDef(&bc, &fd);
    try pipeline.resolve_variables.run(&ctx);

    try std.testing.expectEqual(op.with_put_var, bc.code[3]);
    try std.testing.expectEqual(
        @intFromEnum(bytecode.opcode.WithPutMode.with_probe),
        bc.code[12],
    );
}

test "resolve_variables: direct eval var object probes unresolved get refs" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("test");
    const x_atom = try rt.internAtom("x");
    defer rt.atoms.free(name);
    defer rt.atoms.free(x_atom);

    var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer bc.deinit(rt);
    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);
    _ = try fd.appendScope(-1);
    fd.var_object_idx = try fd.addScopeVar(core.atom.ids.var_object, .normal, 0, false, false);

    const op = bytecode.opcode.op;

    var input = [_]u8{0} ** 8;
    input[0] = op.scope_get_ref;
    std.mem.writeInt(u32, input[1..5], x_atom, .little);
    std.mem.writeInt(u16, input[5..7], 0, .little);
    input[7] = op.return_undef;

    try bc.setCode(&input);
    try bc.retainAtomOperand(x_atom);

    var ctx = pipeline.resolve_variables.JSContext.initWithFunctionDef(&bc, &fd);
    try pipeline.resolve_variables.run(&ctx);

    try std.testing.expectEqual(@as(usize, 18), bc.code.len);
    try std.testing.expectEqual(op.get_loc, bc.code[0]);
    try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, bc.code[1..3], .little));
    try std.testing.expectEqual(op.with_get_ref, bc.code[3]);
    try std.testing.expectEqual(x_atom, std.mem.readInt(u32, bc.code[4..8], .little));
    try std.testing.expectEqual(@as(u32, 17), std.mem.readInt(u32, bc.code[8..12], .little));
    try std.testing.expectEqual(@as(u8, 0), bc.code[12]);
    try std.testing.expectEqual(op.undefined, bc.code[13]);
    try std.testing.expectEqual(op.get_var, bc.code[14]);
    try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, bc.code[15..17], .little));
    try std.testing.expectEqual(op.return_undef, bc.code[17]);
    try std.testing.expectEqual(@as(usize, 1), bc.atom_operands.len);
    try std.testing.expectEqual(x_atom, bc.atom_operands[0]);
    try std.testing.expectEqual(@as(usize, 1), fd.closure_var.len);
    try std.testing.expectEqual(x_atom, fd.closure_var[0].var_name);
    try std.testing.expectEqual(function_def.ClosureType.global, fd.closure_var[0].closure_type);
}

test "resolve_variables: direct eval var object probes unresolved make refs" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("test");
    const x_atom = try rt.internAtom("x");
    defer rt.atoms.free(name);
    defer rt.atoms.free(x_atom);

    var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer bc.deinit(rt);
    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);
    _ = try fd.appendScope(-1);
    fd.var_object_idx = try fd.addScopeVar(core.atom.ids.var_object, .normal, 0, false, false);

    const op = bytecode.opcode.op;

    var input = [_]u8{0} ** 18;
    input[0] = op.scope_make_ref;
    std.mem.writeInt(u32, input[1..5], x_atom, .little);
    std.mem.writeInt(u32, input[5..9], 0, .little);
    std.mem.writeInt(u16, input[9..11], 0, .little);
    input[11] = op.push_i32;
    std.mem.writeInt(i32, input[12..16], 1, .little);
    input[16] = op.put_ref_value;
    input[17] = op.return_undef;

    try bc.setCode(&input);
    try bc.retainAtomOperand(x_atom);

    var ctx = pipeline.resolve_variables.JSContext.initWithFunctionDef(&bc, &fd);
    try pipeline.resolve_variables.run(&ctx);

    try std.testing.expectEqual(@as(usize, 25), bc.code.len);
    try std.testing.expectEqual(op.get_loc, bc.code[0]);
    try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, bc.code[1..3], .little));
    try std.testing.expectEqual(op.with_make_ref, bc.code[3]);
    try std.testing.expectEqual(x_atom, std.mem.readInt(u32, bc.code[4..8], .little));
    try std.testing.expectEqual(@as(u32, 18), std.mem.readInt(u32, bc.code[8..12], .little));
    try std.testing.expectEqual(@as(u8, 0), bc.code[12]);
    try std.testing.expectEqual(op.make_var_ref, bc.code[13]);
    try std.testing.expectEqual(x_atom, std.mem.readInt(u32, bc.code[14..18], .little));
    try std.testing.expectEqual(op.push_i32, bc.code[18]);
    try std.testing.expectEqual(@as(i32, 1), std.mem.readInt(i32, bc.code[19..23], .little));
    try std.testing.expectEqual(op.put_ref_value, bc.code[23]);
    try std.testing.expectEqual(op.return_undef, bc.code[24]);
    try std.testing.expectEqual(@as(usize, 2), bc.atom_operands.len);
    try std.testing.expectEqual(x_atom, bc.atom_operands[0]);
    try std.testing.expectEqual(x_atom, bc.atom_operands[1]);
}

test "resolve_variables: all dynamic reference forms probe var before arg var object" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("dynamic-reference-order");
    const x_atom = try rt.internAtom("x");
    defer rt.atoms.free(name);
    defer rt.atoms.free(x_atom);

    const op = bytecode.opcode.op;
    const cases = [_]struct {
        scope_op: u8,
        probe_op: u8,
        input_len: usize,
    }{
        .{ .scope_op = op.scope_put_var, .probe_op = op.with_put_var, .input_len = 8 },
        .{ .scope_op = op.scope_delete_var, .probe_op = op.with_delete_var, .input_len = 8 },
        .{ .scope_op = op.scope_get_ref, .probe_op = op.with_get_ref, .input_len = 8 },
        .{ .scope_op = op.scope_make_ref, .probe_op = op.with_make_ref, .input_len = 18 },
    };

    for (cases) |case| {
        var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
        defer bc.deinit(rt);
        var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
        defer fd.deinit(rt);
        _ = try fd.appendScope(-1);
        fd.arg_var_object_idx = try fd.addScopeVar(core.atom.ids.arg_var_object, .normal, 0, false, false);
        fd.var_object_idx = try fd.addScopeVar(core.atom.ids.var_object, .normal, 0, false, false);

        var input = [_]u8{0} ** 18;
        input[0] = case.scope_op;
        std.mem.writeInt(u32, input[1..5], x_atom, .little);
        if (case.scope_op == op.scope_make_ref) {
            std.mem.writeInt(u32, input[5..9], 0, .little);
            std.mem.writeInt(u16, input[9..11], 0, .little);
            input[11] = op.push_i32;
            std.mem.writeInt(i32, input[12..16], 1, .little);
            input[16] = op.put_ref_value;
            input[17] = op.return_undef;
        } else {
            std.mem.writeInt(u16, input[5..7], 0, .little);
            input[7] = op.return_undef;
        }

        try bc.setCode(input[0..case.input_len]);
        try bc.retainAtomOperand(x_atom);

        var ctx = pipeline.resolve_variables.JSContext.initWithFunctionDef(&bc, &fd);
        try pipeline.resolve_variables.run(&ctx);

        try std.testing.expectEqual(op.get_loc, bc.code[0]);
        try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, bc.code[1..3], .little));
        try std.testing.expectEqual(case.probe_op, bc.code[3]);
        try std.testing.expectEqual(op.get_loc, bc.code[13]);
        try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, bc.code[14..16], .little));
        try std.testing.expectEqual(case.probe_op, bc.code[16]);
    }
}

test "resolve_variables: typeof probes dynamic environment before undef fallback" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("dynamic-typeof-order");
    const x_atom = try rt.internAtom("x");
    defer rt.atoms.free(name);
    defer rt.atoms.free(x_atom);

    var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer bc.deinit(rt);
    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);
    _ = try fd.appendScope(-1);
    fd.var_object_idx = try fd.addScopeVar(core.atom.ids.var_object, .normal, 0, false, false);

    const op = bytecode.opcode.op;
    var input = [_]u8{0} ** 8;
    input[0] = op.scope_get_var_undef;
    std.mem.writeInt(u32, input[1..5], x_atom, .little);
    std.mem.writeInt(u16, input[5..7], 0, .little);
    input[7] = op.return_undef;

    try bc.setCode(&input);
    try bc.retainAtomOperand(x_atom);

    var ctx = pipeline.resolve_variables.JSContext.initWithFunctionDef(&bc, &fd);
    try pipeline.resolve_variables.run(&ctx);

    try std.testing.expectEqual(@as(usize, 17), bc.code.len);
    try std.testing.expectEqual(op.get_loc, bc.code[0]);
    try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, bc.code[1..3], .little));
    try std.testing.expectEqual(op.with_get_var, bc.code[3]);
    try std.testing.expectEqual(@as(u8, 0), bc.code[12]);
    try std.testing.expectEqual(op.get_var_undef, bc.code[13]);
    try std.testing.expectEqual(op.return_undef, bc.code[16]);
}

test "resolve_variables: declaration init bypasses dynamic environment probes" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("declaration-init-order");
    const x_atom = try rt.internAtom("x");
    defer rt.atoms.free(name);
    defer rt.atoms.free(x_atom);

    var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer bc.deinit(rt);
    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);
    _ = try fd.appendScope(-1);
    fd.arg_var_object_idx = try fd.addScopeVar(core.atom.ids.arg_var_object, .normal, 0, false, false);
    fd.var_object_idx = try fd.addScopeVar(core.atom.ids.var_object, .normal, 0, false, false);

    const op = bytecode.opcode.op;
    var input = [_]u8{0} ** 8;
    input[0] = op.scope_put_var_init;
    std.mem.writeInt(u32, input[1..5], x_atom, .little);
    std.mem.writeInt(u16, input[5..7], 0, .little);
    input[7] = op.return_undef;

    try bc.setCode(&input);
    try bc.retainAtomOperand(x_atom);

    var ctx = pipeline.resolve_variables.JSContext.initWithFunctionDef(&bc, &fd);
    try pipeline.resolve_variables.run(&ctx);

    try std.testing.expectEqual(@as(usize, 4), bc.code.len);
    try std.testing.expectEqual(op.put_var_init, bc.code[0]);
    try std.testing.expectEqual(op.return_undef, bc.code[3]);
    try std.testing.expectEqual(@as(usize, 0), bc.atom_operands.len);
}

test "resolve_variables InvalidBytecode releases retained output atoms" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("resolveInvalidAtomOwner");
    const first_atom = try rt.internAtom("resolveInvalidFirst");

    var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);

    const op = bytecode.opcode.op;
    var input = [_]u8{0} ** 6;
    input[0] = op.scope_get_var;
    std.mem.writeInt(u32, input[1..5], first_atom, .little);
    input[5] = 0;

    try bc.setCode(&input);
    try bc.retainAtomOperand(first_atom);

    var ctx = pipeline.resolve_variables.JSContext.init(&bc);
    try std.testing.expectError(error.InvalidBytecode, pipeline.resolve_variables.run(&ctx));

    bc.deinit(rt);
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

    var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer bc.deinit(rt);
    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);
    _ = try fd.appendScope(-1);

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
    var ctx = pipeline.resolve_variables.JSContext.initWithFunctionDef(&bc, &fd);
    try pipeline.resolve_variables.run(&ctx);

    // Expected: put_var <var_ref y> ; return_undef (3 + 1 = 4 bytes)
    try std.testing.expectEqual(@as(usize, 4), bc.code.len);
    try std.testing.expectEqual(op.put_var, bc.code[0]);
    try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, bc.code[1..3], .little));
    try std.testing.expectEqual(op.return_undef, bc.code[3]);
    try std.testing.expectEqual(@as(usize, 0), bc.atom_operands.len);
    try std.testing.expectEqual(@as(usize, 1), fd.closure_var.len);
    try std.testing.expectEqual(y_atom, fd.closure_var[0].var_name);
}

test "resolve_variables: global scope_make_ref assignment lowers to put_var" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("test");
    const global_atom = try rt.internAtom("g");
    const local_atom = try rt.internAtom("i");
    defer rt.atoms.free(name);
    defer rt.atoms.free(global_atom);
    defer rt.atoms.free(local_atom);

    var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer bc.deinit(rt);

    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);
    fd.use_short_opcodes = true;
    _ = try fd.appendScope(-1);
    _ = try fd.addScopeVar(local_atom, .normal, 0, false, false);

    const op = bytecode.opcode.op;
    var input = [_]u8{0} ** 21;
    input[0] = op.scope_make_ref;
    std.mem.writeInt(u32, input[1..5], global_atom, .little);
    std.mem.writeInt(u32, input[5..9], 0, .little);
    std.mem.writeInt(u16, input[9..11], 0, .little);
    input[11] = op.scope_get_var;
    std.mem.writeInt(u32, input[12..16], local_atom, .little);
    std.mem.writeInt(u16, input[16..18], 0, .little);
    input[18] = op.insert3;
    input[19] = op.put_ref_value;
    input[20] = op.return_undef;

    try bc.setCode(&input);
    try bc.retainAtomOperand(global_atom);
    try bc.retainAtomOperand(local_atom);

    var ctx = pipeline.resolve_variables.JSContext.initWithFunctionDef(&bc, &fd);
    try pipeline.resolve_variables.run(&ctx);

    try std.testing.expectEqual(@as(usize, 6), bc.code.len);
    try std.testing.expectEqual(op.get_loc0, bc.code[0]);
    try std.testing.expectEqual(op.dup, bc.code[1]);
    try std.testing.expectEqual(op.put_var, bc.code[2]);
    try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, bc.code[3..5], .little));
    try std.testing.expectEqual(op.return_undef, bc.code[5]);
    try std.testing.expectEqual(@as(usize, 0), bc.atom_operands.len);
    try std.testing.expectEqual(@as(usize, 1), fd.closure_var.len);
    try std.testing.expectEqual(global_atom, fd.closure_var[0].var_name);
}

test "resolve_variables: strict global scope_make_ref keeps original reference" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("test");
    const global_atom = try rt.internAtom("g");
    defer rt.atoms.free(name);
    defer rt.atoms.free(global_atom);

    var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer bc.deinit(rt);

    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);
    fd.is_strict_mode = true;
    _ = try fd.appendScope(-1);

    const op = bytecode.opcode.op;
    var input = [_]u8{0} ** 18;
    input[0] = op.scope_make_ref;
    std.mem.writeInt(u32, input[1..5], global_atom, .little);
    std.mem.writeInt(u32, input[5..9], 0, .little);
    std.mem.writeInt(u16, input[9..11], 0, .little);
    input[11] = op.push_i32;
    std.mem.writeInt(i32, input[12..16], 1, .little);
    input[16] = op.put_ref_value;
    input[17] = op.return_undef;

    try bc.setCode(&input);
    try bc.retainAtomOperand(global_atom);

    var ctx = pipeline.resolve_variables.JSContext.initWithFunctionDef(&bc, &fd);
    try pipeline.resolve_variables.run(&ctx);

    try std.testing.expectEqual(@as(usize, 12), bc.code.len);
    try std.testing.expectEqual(op.make_var_ref, bc.code[0]);
    try std.testing.expectEqual(global_atom, std.mem.readInt(u32, bc.code[1..5], .little));
    try std.testing.expectEqual(op.push_i32, bc.code[5]);
    try std.testing.expectEqual(@as(i32, 1), std.mem.readInt(i32, bc.code[6..10], .little));
    try std.testing.expectEqual(op.put_ref_value, bc.code[10]);
    try std.testing.expectEqual(op.return_undef, bc.code[11]);
    try std.testing.expectEqual(@as(usize, 1), bc.atom_operands.len);
    try std.testing.expectEqual(global_atom, bc.atom_operands[0]);
}

test "resolve_variables: local scope_make_ref assignment lowers safe reference tail" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("test");
    const local_target = try rt.internAtom("x");
    const local_value = try rt.internAtom("i");
    defer rt.atoms.free(name);
    defer rt.atoms.free(local_target);
    defer rt.atoms.free(local_value);

    var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer bc.deinit(rt);

    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);
    fd.use_short_opcodes = true;
    _ = try fd.appendScope(-1);
    _ = try fd.addScopeVar(local_target, .normal, 0, false, false);
    _ = try fd.addScopeVar(local_value, .normal, 0, false, false);

    const op = bytecode.opcode.op;
    var input = [_]u8{0} ** 21;
    input[0] = op.scope_make_ref;
    std.mem.writeInt(u32, input[1..5], local_target, .little);
    std.mem.writeInt(u32, input[5..9], 0, .little);
    std.mem.writeInt(u16, input[9..11], 0, .little);
    input[11] = op.scope_get_var;
    std.mem.writeInt(u32, input[12..16], local_value, .little);
    std.mem.writeInt(u16, input[16..18], 0, .little);
    input[18] = op.insert3;
    input[19] = op.put_ref_value;
    input[20] = op.return_undef;

    try bc.setCode(&input);
    try bc.retainAtomOperand(local_target);
    try bc.retainAtomOperand(local_value);

    var ctx = pipeline.resolve_variables.JSContext.initWithFunctionDef(&bc, &fd);
    try pipeline.resolve_variables.run(&ctx);

    try std.testing.expectEqualSlices(u8, &.{
        op.get_loc1,
        op.dup,
        op.put_loc0,
        op.return_undef,
    }, bc.code);
    try std.testing.expectEqual(@as(usize, 0), bc.atom_operands.len);
}

test "resolve_variables: drops enter_scope/leave_scope" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("test");
    defer rt.atoms.free(name);

    var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
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

    var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer bc.deinit(rt);
    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);
    _ = try fd.appendScope(-1);

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
    var ctx = pipeline.resolve_variables.JSContext.initWithFunctionDef(&bc, &fd);
    try pipeline.resolve_variables.run(&ctx);

    // Expected: get_var_undef <var_ref z> ; return_undef (3 + 1 = 4 bytes)
    try std.testing.expectEqual(@as(usize, 4), bc.code.len);
    try std.testing.expectEqual(op.get_var_undef, bc.code[0]);
    try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, bc.code[1..3], .little));
    try std.testing.expectEqual(op.return_undef, bc.code[3]);
    try std.testing.expectEqual(@as(usize, 0), bc.atom_operands.len);
    try std.testing.expectEqual(@as(usize, 1), fd.closure_var.len);
    try std.testing.expectEqual(z_atom, fd.closure_var[0].var_name);
}

test "resolve_labels: drops label opcodes" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("test");
    defer rt.atoms.free(name);

    var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer bc.deinit(rt);
    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);
    _ = try fd.appendScope(-1);

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

    var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
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

    try std.testing.expectEqual(@as(usize, 11), bc.code.len);
    try std.testing.expectEqual(op.goto, bc.code[5]);
    try std.testing.expectEqual(@as(i32, 4), std.mem.readInt(i32, bc.code[6..10], .little));
    try std.testing.expectEqual(op.@"return", bc.code[10]);
}

test "resolve_labels: threads jumps through unconditional goto targets" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("test");
    defer rt.atoms.free(name);

    var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer bc.deinit(rt);

    const op = bytecode.opcode.op;

    // goto pc=5 ; goto pc=10 ; return
    var input = [_]u8{0} ** 11;
    input[0] = op.goto;
    std.mem.writeInt(u32, input[1..5], 5, .little);
    input[5] = op.goto;
    std.mem.writeInt(u32, input[6..10], 10, .little);
    input[10] = op.@"return";
    try bc.setCode(&input);

    var ctx = pipeline.resolve_labels.JSContext.init(&bc);
    try pipeline.resolve_labels.run(&ctx);

    try std.testing.expectEqual(@as(usize, 11), bc.code.len);
    try std.testing.expectEqual(op.goto, bc.code[0]);
    try std.testing.expectEqual(@as(i32, 9), std.mem.readInt(i32, bc.code[1..5], .little));
}

test "resolve_labels: folds constant push_i32 conditional tests" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("test");
    defer rt.atoms.free(name);

    const op = bytecode.opcode.op;

    {
        var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
        defer bc.deinit(rt);

        // push_i32 1 ; if_false pc=10 ; return_undef
        var input = [_]u8{0} ** 11;
        input[0] = op.push_i32;
        std.mem.writeInt(i32, input[1..5], 1, .little);
        input[5] = op.if_false;
        std.mem.writeInt(u32, input[6..10], 10, .little);
        input[10] = op.return_undef;
        try bc.setCode(&input);

        var ctx = pipeline.resolve_labels.JSContext.init(&bc);
        try pipeline.resolve_labels.run(&ctx);

        try std.testing.expectEqual(@as(usize, 1), bc.code.len);
        try std.testing.expectEqual(op.return_undef, bc.code[0]);
    }

    {
        var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
        defer bc.deinit(rt);

        // push_i32 0 ; if_false pc=11 ; drop ; return_undef
        var input = [_]u8{0} ** 12;
        input[0] = op.push_i32;
        std.mem.writeInt(i32, input[1..5], 0, .little);
        input[5] = op.if_false;
        std.mem.writeInt(u32, input[6..10], 11, .little);
        input[10] = op.drop;
        input[11] = op.return_undef;
        try bc.setCode(&input);

        var ctx = pipeline.resolve_labels.JSContext.init(&bc);
        try pipeline.resolve_labels.run(&ctx);

        try std.testing.expectEqual(@as(usize, 7), bc.code.len);
        try std.testing.expectEqual(op.goto, bc.code[0]);
        try std.testing.expectEqual(@as(i32, 5), std.mem.readInt(i32, bc.code[1..5], .little));
        try std.testing.expectEqual(op.drop, bc.code[5]);
        try std.testing.expectEqual(op.return_undef, bc.code[6]);
    }
}

test "resolve_labels: folds push_i32 neg" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("test");
    defer rt.atoms.free(name);

    var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer bc.deinit(rt);

    const op = bytecode.opcode.op;

    // push_i32 42 ; neg ; return
    var input = [_]u8{0} ** 7;
    input[0] = op.push_i32;
    std.mem.writeInt(i32, input[1..5], 42, .little);
    input[5] = op.neg;
    input[6] = op.@"return";
    try bc.setCode(&input);

    var ctx = pipeline.resolve_labels.JSContext.init(&bc);
    try pipeline.resolve_labels.run(&ctx);

    try std.testing.expectEqual(@as(usize, 6), bc.code.len);
    try std.testing.expectEqual(op.push_i32, bc.code[0]);
    try std.testing.expectEqual(@as(i32, -42), std.mem.readInt(i32, bc.code[1..5], .little));
    try std.testing.expectEqual(op.@"return", bc.code[5]);
}

test "resolve_labels: skips dead code after unconditional goto" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("test");
    defer rt.atoms.free(name);

    var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer bc.deinit(rt);

    const op = bytecode.opcode.op;

    // goto pc=10 ; push_i32 123 ; return
    var input = [_]u8{0} ** 11;
    input[0] = op.goto;
    std.mem.writeInt(u32, input[1..5], 10, .little);
    input[5] = op.push_i32;
    std.mem.writeInt(i32, input[6..10], 123, .little);
    input[10] = op.@"return";
    try bc.setCode(&input);

    var ctx = pipeline.resolve_labels.JSContext.init(&bc);
    try pipeline.resolve_labels.run(&ctx);

    try std.testing.expectEqual(@as(usize, 6), bc.code.len);
    try std.testing.expectEqual(op.goto, bc.code[0]);
    try std.testing.expectEqual(@as(i32, 4), std.mem.readInt(i32, bc.code[1..5], .little));
    try std.testing.expectEqual(op.@"return", bc.code[5]);
}

test "F10.2: resolve_labels selects goto8 for near relative target" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const name = try rt.internAtom("test");
    defer rt.atoms.free(name);

    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);
    fd.use_short_opcodes = true;

    var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
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

    try std.testing.expectEqual(@as(usize, 3), bc.code.len);
    try std.testing.expectEqual(op.goto8, bc.code[0]);
    try std.testing.expectEqual(@as(i8, 1), @as(i8, @bitCast(bc.code[1])));
    try std.testing.expectEqual(op.@"return", bc.code[2]);
}

test "F10.2: resolve_labels keeps conditional jump wide when target exceeds i8" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const name = try rt.internAtom("test");
    defer rt.atoms.free(name);

    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);
    fd.use_short_opcodes = true;

    var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
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

    var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer bc.deinit(rt);
    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);
    _ = try fd.appendScope(-1);

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
    try pipeline.finalize.runWithFunctionDefRuntime(&bc, &fd, rt);

    // Expected: get_var <var_ref x> ; return_undef (3 + 1 = 4 bytes)
    // enter_scope, leave_scope, and label should all be dropped
    try std.testing.expectEqual(@as(u16, 1), bc.stack_size);
    try std.testing.expectEqual(@as(usize, 4), bc.code.len);
    try std.testing.expectEqual(op.get_var, bc.code[0]);
    try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, bc.code[1..3], .little));
    try std.testing.expectEqual(op.return_undef, bc.code[3]);
    try std.testing.expectEqual(@as(usize, 1), bc.var_ref_names.len);
    try std.testing.expectEqual(x_atom, bc.var_ref_names[0]);
    try std.testing.expectEqual(@as(usize, 0), bc.atom_operands.len);
}
// ---- F10.1b: FunctionDef-driven local-slot lowering ----

test "resolve_variables: scope_get_var → get_loc when var is local" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("test");
    const x_atom = try rt.internAtom("x");
    defer rt.atoms.free(name);
    defer rt.atoms.free(x_atom);

    var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
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

    var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
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

test "resolve_variables: const local write lowers to throw_error" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("test");
    const x_atom = try rt.internAtom("x");
    defer rt.atoms.free(name);
    defer rt.atoms.free(x_atom);

    var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer bc.deinit(rt);

    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);
    _ = try fd.appendScope(-1);
    _ = try fd.addScopeVar(x_atom, .normal, 0, true, true);

    const op = bytecode.opcode.op;
    var input = [_]u8{0} ** 8;
    input[0] = op.scope_put_var;
    std.mem.writeInt(u32, input[1..5], x_atom, .little);
    std.mem.writeInt(u16, input[5..7], 0, .little);
    input[7] = op.return_undef;

    try bc.setCode(&input);
    try bc.retainAtomOperand(x_atom);

    var ctx = pipeline.resolve_variables.JSContext.initWithFunctionDef(&bc, &fd);
    try pipeline.resolve_variables.run(&ctx);

    // Lexical prologue arms TDZ, then the write itself is a compile-time
    // read-only throw (old behavior emitted put_loc_check here).
    try std.testing.expectEqual(@as(usize, 10), bc.code.len);
    try std.testing.expectEqual(op.set_loc_uninitialized, bc.code[0]);
    try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, bc.code[1..3], .little));
    try std.testing.expectEqual(op.throw_error, bc.code[3]);
    try std.testing.expectEqual(x_atom, std.mem.readInt(u32, bc.code[4..8], .little));
    try std.testing.expectEqual(op.return_undef, bc.code[9]);
    try std.testing.expectEqualSlices(core.Atom, &.{x_atom}, bc.atom_operands);
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

    var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
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

    // Expected: get_var <var_ref z> ; return_undef (3 + 1 = 4 bytes)
    try std.testing.expectEqual(@as(usize, 4), bc.code.len);
    try std.testing.expectEqual(op.get_var, bc.code[0]);
    try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, bc.code[1..3], .little));
    try std.testing.expectEqual(op.return_undef, bc.code[3]);
    try std.testing.expectEqual(@as(usize, 0), bc.atom_operands.len);
    try std.testing.expectEqual(@as(usize, 1), fd.closure_var.len);
    try std.testing.expectEqual(z_atom, fd.closure_var[0].var_name);
}

test "resolve_variables: module class binding consumes one input atom before property atom" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("test");
    const class_atom = try rt.internAtom("A");
    const field_atom = try rt.internAtom("x");
    defer rt.atoms.free(name);
    defer rt.atoms.free(class_atom);
    defer rt.atoms.free(field_atom);

    var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer bc.deinit(rt);

    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);
    fd.use_short_opcodes = true;
    _ = try fd.appendScope(-1);
    _ = try fd.appendScope(0);
    _ = try fd.addScopeVar(class_atom, .normal, 0, true, true);
    _ = try fd.addClosureVar(.{
        .closure_type = .module_decl,
        .is_lexical = true,
        .is_const = false,
        .var_idx = 0,
        .var_name = class_atom,
    });

    const op = bytecode.opcode.op;
    var input = [_]u8{0} ** 14;
    input[0] = op.scope_get_var;
    std.mem.writeInt(u32, input[1..5], class_atom, .little);
    std.mem.writeInt(u16, input[5..7], 1, .little);
    input[7] = op.get_field;
    std.mem.writeInt(u32, input[8..12], field_atom, .little);
    input[12] = op.drop;
    input[13] = op.return_undef;

    try bc.setCode(&input);
    try bc.retainAtomOperand(class_atom);
    try bc.retainAtomOperand(field_atom);

    var ctx = pipeline.resolve_variables.JSContext.initWithFunctionDef(&bc, &fd);
    try pipeline.resolve_variables.run(&ctx);

    try std.testing.expectEqual(@as(usize, 1), bc.atom_operands.len);
    try std.testing.expectEqual(field_atom, bc.atom_operands[0]);
    var saw_field = false;
    var pc: usize = 0;
    while (pc < bc.code.len) {
        const size = bytecode.opcode.sizeOf(bc.code[pc]);
        try std.testing.expect(size != 0);
        if (bc.code[pc] == op.get_field) {
            const resolved_field = std.mem.readInt(u32, bc.code[pc + 1 ..][0..4], .little);
            try std.testing.expectEqual(field_atom, resolved_field);
            saw_field = true;
            break;
        }
        pc += size;
    }
    try std.testing.expect(saw_field);
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
        var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
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
    var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
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

    var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
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

    var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
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

    var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
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

test "F10.2: resolve_labels keeps QuickJS get_loc0 get_loc1 shape" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const name = try rt.internAtom("test");
    defer rt.atoms.free(name);

    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);
    fd.use_short_opcodes = true;

    var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer bc.deinit(rt);

    const op = bytecode.opcode.op;
    const input = [_]u8{ op.get_loc0, op.get_loc1, op.add, op.@"return" };
    try bc.setCode(&input);

    var ctx = pipeline.resolve_labels.JSContext.initWithFunctionDef(&bc, &fd);
    try pipeline.resolve_labels.run(&ctx);

    try std.testing.expectEqual(@as(usize, 4), bc.code.len);
    try std.testing.expectEqual(op.get_loc0, bc.code[0]);
    try std.testing.expectEqual(op.get_loc1, bc.code[1]);
    try std.testing.expectEqual(op.add, bc.code[2]);
    try std.testing.expectEqual(op.@"return", bc.code[3]);
}

test "F10.2: resolve_labels shortens wide get_loc 0 and get_loc 1 without coalescing" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const name = try rt.internAtom("test");
    defer rt.atoms.free(name);

    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);
    fd.use_short_opcodes = true;

    var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
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

    try std.testing.expectEqual(@as(usize, 4), bc.code.len);
    try std.testing.expectEqual(op.get_loc0, bc.code[0]);
    try std.testing.expectEqual(op.get_loc1, bc.code[1]);
    try std.testing.expectEqual(op.add, bc.code[2]);
    try std.testing.expectEqual(op.@"return", bc.code[3]);
}

test "F10.2: resolve_labels shortens direct loc arg and var_ref slot ops" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const name = try rt.internAtom("test");
    defer rt.atoms.free(name);

    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);
    fd.use_short_opcodes = true;

    var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
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

test "resolve_labels folds dup put slot families to set" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const name = try rt.internAtom("test");
    defer rt.atoms.free(name);

    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);
    fd.use_short_opcodes = true;

    var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer bc.deinit(rt);

    const op = bytecode.opcode.op;
    var input = [_]u8{0} ** 17;
    var i: usize = 0;
    inline for (.{
        .{ op.put_loc, @as(u16, 0) },
        .{ op.put_arg, @as(u16, 1) },
        .{ op.put_var_ref, @as(u16, 2) },
        .{ op.put_loc_check, @as(u16, 3) },
    }) |put| {
        input[i] = op.dup;
        input[i + 1] = put[0];
        std.mem.writeInt(u16, input[i + 2 ..][0..2], put[1], .little);
        i += 4;
    }
    input[i] = op.@"return";
    try bc.setCode(&input);

    var ctx = pipeline.resolve_labels.JSContext.initWithFunctionDef(&bc, &fd);
    try pipeline.resolve_labels.run(&ctx);

    try std.testing.expectEqualSlices(u8, &.{
        op.set_loc0,
        op.set_arg1,
        op.set_var_ref2,
        op.set_loc_check,
        3,
        0,
        op.@"return",
    }, bc.code);
}

test "resolve_labels collapses chained logical branch prefix" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const name = try rt.internAtom("test");
    defer rt.atoms.free(name);

    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);
    fd.use_short_opcodes = true;

    var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer bc.deinit(rt);

    const op = bytecode.opcode.op;
    var input = [_]u8{0} ** 14;
    input[0] = op.dup;
    input[1] = op.if_false;
    std.mem.writeInt(u32, input[2..6], 8, .little);
    input[6] = op.drop;
    input[7] = op.get_loc0;
    input[8] = op.if_false;
    std.mem.writeInt(u32, input[9..13], 13, .little);
    input[13] = op.return_undef;
    try bc.setCode(&input);

    var ctx = pipeline.resolve_labels.JSContext.initWithFunctionDef(&bc, &fd);
    try pipeline.resolve_labels.run(&ctx);

    try std.testing.expectEqualSlices(u8, &.{
        op.if_false8,
        4,
        op.get_loc0,
        op.if_false8,
        1,
        op.return_undef,
    }, bc.code);
}

test "resolve_labels preserves logical prefix with an interior jump target" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const name = try rt.internAtom("test");
    defer rt.atoms.free(name);

    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);
    fd.use_short_opcodes = true;

    var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer bc.deinit(rt);

    const op = bytecode.opcode.op;
    var input = [_]u8{0} ** 19;
    input[0] = op.if_true;
    std.mem.writeInt(u32, input[1..5], 6, .little);
    input[5] = op.dup;
    input[6] = op.if_false;
    std.mem.writeInt(u32, input[7..11], 13, .little);
    input[11] = op.drop;
    input[12] = op.get_loc0;
    input[13] = op.if_false;
    std.mem.writeInt(u32, input[14..18], 18, .little);
    input[18] = op.return_undef;
    try bc.setCode(&input);

    var ctx = pipeline.resolve_labels.JSContext.initWithFunctionDef(&bc, &fd);
    try pipeline.resolve_labels.run(&ctx);

    try std.testing.expectEqual(@as(usize, 10), bc.code.len);
    try std.testing.expectEqual(op.dup, bc.code[2]);
}

test "resolve_labels folds null and undefined comparison families" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const name = try rt.internAtom("test");
    defer rt.atoms.free(name);

    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);
    fd.use_short_opcodes = true;

    const op = bytecode.opcode.op;
    const cases = [_]struct {
        input: []const u8,
        expected: []const u8,
    }{
        .{
            .input = &.{ op.get_loc0, op.null, op.strict_eq, op.@"return" },
            .expected = &.{ op.get_loc0, op.is_null, op.@"return" },
        },
        .{
            .input = &.{ op.get_loc0, op.undefined, op.strict_eq, op.@"return" },
            .expected = &.{ op.get_loc0, op.is_undefined, op.@"return" },
        },
        .{
            .input = &.{ op.undefined, op.@"return" },
            .expected = &.{op.return_undef},
        },
    };

    for (cases) |case| {
        var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
        defer bc.deinit(rt);
        try bc.setCode(case.input);

        var ctx = pipeline.resolve_labels.JSContext.initWithFunctionDef(&bc, &fd);
        try pipeline.resolve_labels.run(&ctx);
        try std.testing.expectEqualSlices(u8, case.expected, bc.code);
    }
}

test "resolve_labels folds nullish strict_neq branches by inverting the jump" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const name = try rt.internAtom("test");
    defer rt.atoms.free(name);

    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);
    fd.use_short_opcodes = true;

    const op = bytecode.opcode.op;
    const nullish_ops = [_]struct { push: u8, test_op: u8 }{
        .{ .push = op.null, .test_op = op.is_null },
        .{ .push = op.undefined, .test_op = op.is_undefined },
    };
    for (nullish_ops) |nullish| {
        var input = [_]u8{0} ** 9;
        input[0] = op.get_loc0;
        input[1] = nullish.push;
        input[2] = op.strict_neq;
        input[3] = op.if_false;
        std.mem.writeInt(u32, input[4..8], 8, .little);
        input[8] = op.return_undef;

        var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
        defer bc.deinit(rt);
        try bc.setCode(&input);

        var ctx = pipeline.resolve_labels.JSContext.initWithFunctionDef(&bc, &fd);
        try pipeline.resolve_labels.run(&ctx);
        try std.testing.expectEqualSlices(u8, &.{
            op.get_loc0,
            nullish.test_op,
            op.if_true8,
            1,
            op.return_undef,
        }, bc.code);
    }
}

test "resolve_labels folds typeof tests and remaps retained atom operands" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const name = try rt.internAtom("test");
    defer rt.atoms.free(name);
    const keep_atom = try rt.internAtom("keep-operand");
    defer rt.atoms.free(keep_atom);
    const type_atom = try rt.internAtom("undefined");
    defer rt.atoms.free(type_atom);
    const keep_base = rt.atoms.refCount(keep_atom).?;

    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);
    fd.use_short_opcodes = true;

    const op = bytecode.opcode.op;
    var input = [_]u8{0} ** 15;
    input[0] = op.push_atom_value;
    std.mem.writeInt(u32, input[1..5], keep_atom, .little);
    input[5] = op.drop;
    input[6] = op.get_loc0;
    input[7] = op.typeof;
    input[8] = op.push_atom_value;
    std.mem.writeInt(u32, input[9..13], type_atom, .little);
    input[13] = op.strict_eq;
    input[14] = op.@"return";

    var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer bc.deinit(rt);
    try bc.setCode(&input);
    try bc.retainAtomOperand(keep_atom);
    try bc.retainAtomOperand(type_atom);

    var ctx = pipeline.resolve_labels.JSContext.initWithFunctionDef(&bc, &fd);
    try pipeline.resolve_labels.run(&ctx);

    var expected = [_]u8{0} ** 9;
    expected[0] = op.push_atom_value;
    std.mem.writeInt(u32, expected[1..5], keep_atom, .little);
    expected[5] = op.drop;
    expected[6] = op.get_loc0;
    expected[7] = op.typeof_is_undefined;
    expected[8] = op.@"return";
    try std.testing.expectEqualSlices(u8, &expected, bc.code);
    try std.testing.expectEqualSlices(core.Atom, &.{keep_atom}, bc.atom_operands);
    try std.testing.expectEqual(keep_base + 1, rt.atoms.refCount(keep_atom).?);
}

test "resolve_labels removes atom-bearing dead code after a terminal opcode" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const name = try rt.internAtom("test");
    defer rt.atoms.free(name);
    const dead_atom = try rt.internAtom("dead-operand");
    defer rt.atoms.free(dead_atom);
    const base_ref_count = rt.atoms.refCount(dead_atom).?;

    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);
    fd.use_short_opcodes = true;

    const op = bytecode.opcode.op;
    var input = [_]u8{0} ** 9;
    input[0] = op.get_loc0;
    input[1] = op.@"return";
    input[2] = op.push_atom_value;
    std.mem.writeInt(u32, input[3..7], dead_atom, .little);
    input[7] = op.drop;
    input[8] = op.return_undef;

    var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer bc.deinit(rt);
    try bc.setCode(&input);
    try bc.retainAtomOperand(dead_atom);

    var ctx = pipeline.resolve_labels.JSContext.initWithFunctionDef(&bc, &fd);
    try pipeline.resolve_labels.run(&ctx);

    try std.testing.expectEqualSlices(u8, &.{ op.get_loc0, op.@"return" }, bc.code);
    try std.testing.expectEqual(@as(usize, 0), bc.atom_operands.len);
    try std.testing.expectEqual(base_ref_count, rt.atoms.refCount(dead_atom).?);
}

test "resolve_labels folds typeof function inequality branches" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const name = try rt.internAtom("test");
    defer rt.atoms.free(name);
    const function_atom = try rt.internAtom("function");
    defer rt.atoms.free(function_atom);

    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);
    fd.use_short_opcodes = true;

    const op = bytecode.opcode.op;
    var input = [_]u8{0} ** 14;
    input[0] = op.get_loc0;
    input[1] = op.typeof;
    input[2] = op.push_atom_value;
    std.mem.writeInt(u32, input[3..7], function_atom, .little);
    input[7] = op.neq;
    input[8] = op.if_false;
    std.mem.writeInt(u32, input[9..13], 13, .little);
    input[13] = op.return_undef;

    var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer bc.deinit(rt);
    try bc.setCode(&input);
    try bc.retainAtomOperand(function_atom);

    var ctx = pipeline.resolve_labels.JSContext.initWithFunctionDef(&bc, &fd);
    try pipeline.resolve_labels.run(&ctx);

    try std.testing.expectEqualSlices(u8, &.{
        op.get_loc0,
        op.typeof_is_function,
        op.if_true8,
        1,
        op.return_undef,
    }, bc.code);
    try std.testing.expectEqual(@as(usize, 0), bc.atom_operands.len);
}

test "resolve_labels keeps short-only comparison folds disabled" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const name = try rt.internAtom("test");
    defer rt.atoms.free(name);
    const type_atom = try rt.internAtom("undefined");
    defer rt.atoms.free(type_atom);

    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);
    fd.use_short_opcodes = false;

    const op = bytecode.opcode.op;
    var input = [_]u8{0} ** 12;
    input[0] = op.get_loc;
    std.mem.writeInt(u16, input[1..3], 0, .little);
    input[3] = op.null;
    input[4] = op.strict_eq;
    input[5] = op.typeof;
    input[6] = op.push_atom_value;
    std.mem.writeInt(u32, input[7..11], type_atom, .little);
    input[11] = op.strict_eq;

    var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer bc.deinit(rt);
    try bc.setCode(&input);
    try bc.retainAtomOperand(type_atom);

    var ctx = pipeline.resolve_labels.JSContext.initWithFunctionDef(&bc, &fd);
    try pipeline.resolve_labels.run(&ctx);

    try std.testing.expectEqualSlices(u8, &input, bc.code);
    try std.testing.expectEqualSlices(core.Atom, &.{type_atom}, bc.atom_operands);
}

test "resolve_labels preserves dead code reached by an external jump" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const name = try rt.internAtom("test");
    defer rt.atoms.free(name);
    const live_atom = try rt.internAtom("jump-target-operand");
    defer rt.atoms.free(live_atom);

    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);
    fd.use_short_opcodes = true;

    const op = bytecode.opcode.op;
    var input = [_]u8{0} ** 15;
    input[0] = op.get_loc0;
    input[1] = op.if_true;
    std.mem.writeInt(u32, input[2..6], 8, .little);
    input[6] = op.get_loc0;
    input[7] = op.@"return";
    input[8] = op.push_atom_value;
    std.mem.writeInt(u32, input[9..13], live_atom, .little);
    input[13] = op.drop;
    input[14] = op.return_undef;

    var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer bc.deinit(rt);
    try bc.setCode(&input);
    try bc.retainAtomOperand(live_atom);

    var ctx = pipeline.resolve_labels.JSContext.initWithFunctionDef(&bc, &fd);
    try pipeline.resolve_labels.run(&ctx);

    try std.testing.expectEqual(@as(usize, 12), bc.code.len);
    try std.testing.expectEqual(op.push_atom_value, bc.code[5]);
    try std.testing.expectEqualSlices(core.Atom, &.{live_atom}, bc.atom_operands);
}

test "resolve_labels preserves implicit generator rethrow markers" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const name = try rt.internAtom("test");
    defer rt.atoms.free(name);

    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);
    fd.use_short_opcodes = true;

    const op = bytecode.opcode.op;
    const input = [_]u8{ op.get_loc0, op.@"return", op.throw };
    var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer bc.deinit(rt);
    try bc.setCode(&input);

    var ctx = pipeline.resolve_labels.JSContext.initWithFunctionDef(&bc, &fd);
    try pipeline.resolve_labels.run(&ctx);
    try std.testing.expectEqualSlices(u8, &input, bc.code);
}

test "resolve_labels preserves a try-finally normal jump after a terminal" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const name = try rt.internAtom("test");
    defer rt.atoms.free(name);

    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);
    fd.use_short_opcodes = true;

    const op = bytecode.opcode.op;
    var input = [_]u8{0} ** 14;
    input[0] = op.@"catch";
    std.mem.writeInt(u32, input[1..5], 12, .little);
    input[5] = op.throw;
    input[6] = op.drop;
    input[7] = op.goto;
    std.mem.writeInt(u32, input[8..12], 13, .little);
    input[12] = op.throw;
    input[13] = op.return_undef;

    var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer bc.deinit(rt);
    try bc.setCode(&input);

    var ctx = pipeline.resolve_labels.JSContext.initWithFunctionDef(&bc, &fd);
    try pipeline.resolve_labels.run(&ctx);

    try std.testing.expectEqual(@as(usize, 10), bc.code.len);
    try std.testing.expectEqual(op.throw, bc.code[5]);
    try std.testing.expectEqual(op.goto8, bc.code[6]);
    try std.testing.expectEqual(op.throw, bc.code[8]);
    try std.testing.expectEqual(op.return_undef, bc.code[9]);
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
        var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
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

        var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
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

        switch (closure_type) {
            // `.global` / `.global_ref` are codex's index-based global atom
            // carriers (no runtime cell) → get_var_undef. `.global_decl` is the
            // cell-backed top-level let/const VarRef (ours' single-cell model:
            // frame.var_refs[idx] aliases the ctx.lexicals cell), so it resolves
            // as a runtime var-ref (get_var_ref0) — matching the make_var_ref_ref
            // write path and ours' 322af2f classification.
            .global_ref, .global => {
                try std.testing.expectEqual(@as(usize, 4), bc.code.len);
                try std.testing.expectEqual(op.get_var_undef, bc.code[0]);
                try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, bc.code[1..3], .little));
                try std.testing.expectEqual(op.return_undef, bc.code[3]);
            },
            else => try std.testing.expectEqualSlices(u8, &.{ op.get_var_ref0, op.return_undef }, bc.code),
        }
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

    var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
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

test "resolve_labels shortens FunctionDef special-object prologue slots" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const name = try rt.internAtom("short-prologue");
    defer rt.atoms.free(name);

    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);
    fd.use_short_opcodes = true;
    fd.home_object_var_idx = 0;
    fd.this_active_func_var_idx = 1;
    fd.new_target_var_idx = 2;
    fd.this_var_idx = 3;
    fd.arguments_var_idx = 4;
    fd.arguments_arg_idx = 5;
    fd.func_var_idx = 6;
    fd.var_object_idx = 7;
    fd.arg_var_object_idx = 8;

    var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer bc.deinit(rt);

    var ctx = pipeline.resolve_labels.JSContext.initWithFunctionDef(&bc, &fd);
    try pipeline.resolve_labels.run(&ctx);

    const op = bytecode.opcode.op;
    const expected = [_]u8{
        op.special_object, 4,                 op.put_loc0,
        op.special_object, 2,                 op.put_loc1,
        op.special_object, 3,                 op.put_loc2,
        op.push_this,      op.put_loc3,       op.special_object,
        1,                 op.set_loc8,       5,
        op.put_loc8,       4,                 op.special_object,
        2,                 op.put_loc8,       6,
        op.special_object, 5,                 op.put_loc8,
        7,                 op.special_object, 5,
        op.put_loc8,       8,
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

        var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
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

        var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
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

    // Body: push_atom_value <inner> ; drop ; get_var <var_ref 0> ;
    // drop ; return_undef. This covers atom operand copying and IC
    // metadata for var_ref-based global access.
    const op = bytecode.opcode.op;
    var body = [_]u8{0} ** 11;
    body[0] = op.push_atom_value;
    std.mem.writeInt(u32, body[1..5], name, .little);
    body[5] = op.drop;
    body[6] = op.get_var;
    std.mem.writeInt(u16, body[7..9], 0, .little);
    body[9] = op.drop;
    body[10] = op.return_undef;
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

    try std.testing.expect(fb.flags.is_strict_mode);
    try std.testing.expect(fb.flags.has_prototype);
    try std.testing.expect(!fb.flags.has_simple_parameter_list);
    try std.testing.expect(fb.flags.is_derived_class_constructor);
    try std.testing.expect(fb.flags.is_indirect_eval);
    try std.testing.expectEqual(function_def.FunctionKind.async_generator, fb.flags.func_kind);
    try std.testing.expectEqual(@as(usize, 11), fb.byteCode().len);
    try std.testing.expectEqual(@as(i32, 11), fb.byte_code_len);
    try std.testing.expectEqual(op.push_atom_value, fb.byteCode()[0]);
    try std.testing.expectEqual(op.drop, fb.byteCode()[5]);
    try std.testing.expectEqual(op.get_var, fb.byteCode()[6]);
    try std.testing.expectEqual(op.drop, fb.byteCode()[9]);
    try std.testing.expectEqual(op.return_undef, fb.byteCode()[10]);
    try std.testing.expectEqual(@as(usize, 1), fb.argNames().len);
    try std.testing.expectEqual(arg_name, fb.argNames()[0]);
    try std.testing.expectEqual(@as(usize, 1), fb.varDefs().len);
    try std.testing.expectEqual(name, fb.varDefs()[0].var_name);
    try std.testing.expect(fb.varDefs()[0].is_const);
    // Var-ref names are derived from `closure_var[i].var_name` (the former
    // parallel `var_ref_names` atom array was removed to shrink the FB struct).
    try std.testing.expectEqual(@as(usize, 1), fb.closureVar().len);
    try std.testing.expectEqual(captured_name, fb.closureVar()[0].var_name);
    // is_lexical / is_const now derived from closure_var[i] (parallel `[]bool`
    // arrays removed to match qjs JSClosureVar).
    try std.testing.expect(fb.closureVar()[0].is_lexical);
    try std.testing.expect(fb.closureVar()[0].is_const);
    try std.testing.expectEqual(@as(usize, 1), fb.privateBoundNames().len);
    try std.testing.expectEqual(private_name, fb.privateBoundNames()[0]);
    try std.testing.expectEqual(@as(u16, 1), fb.var_count);
    try std.testing.expectEqual(@as(u16, 1), fb.arg_count);
    try std.testing.expectEqual(@as(u16, 1), fb.defined_arg_count);
    try std.testing.expectEqual(@as(u32, 1), fb.var_refs_len);
    {
        // Atom operands are retained inline in the bytecode (no side array);
        // iterate them to confirm the single `name` operand survived finalize.
        var it = fb.atomOperandIterator();
        const first = it.next();
        try std.testing.expectEqual(name, first.?);
        try std.testing.expectEqual(@as(?atom_module.Atom, null), it.next());
    }
    try std.testing.expectEqual(@as(i32, 1), fb.cpool_count);
    try std.testing.expectEqual(@as(i32, 99), fb.cpoolSlice()[0].asInt32().?);
    try std.testing.expectEqual(@as(i32, 7), fb.lineNum());
    try std.testing.expectEqual(@as(i32, 3), fb.colNum());
    try std.testing.expect(fb.pc2lineLen() > 0);
    try std.testing.expectEqualStrings("async function* inner(arg) {}", fb.sourceText().?);

    const view = bytecode.asBytecodeView(fb, rt);
    try std.testing.expect(view.flags.is_strict);
    try std.testing.expect(view.flags.is_async);
    try std.testing.expect(view.flags.is_generator);
    try std.testing.expect(view.flags.is_derived_class_constructor);
    try std.testing.expect(view.flags.is_indirect_eval);
    try std.testing.expectEqualSlices(u8, fb.byteCode(), view.code);
    // The finalized FB no longer exposes a standalone atom-operand array; the
    // view's `atom_operands` is empty and its atoms are read inline from `code`.
    try std.testing.expectEqual(@as(usize, 0), view.atom_operands.len);
    try std.testing.expectEqualSlices(atom_module.Atom, fb.argNames(), view.arg_names);
    try std.testing.expectEqualSlices(bytecode.function_def.VarDef, fb.varDefs(), view.vardefs);
    // The finalized FB no longer keeps a standalone `var_ref_names` array; the
    // view leaves `var_ref_names` empty for normal (non-eval) functions and
    // derives names from `closure_var[i].var_name` via `varRefName`.
    try std.testing.expectEqual(@as(usize, 0), view.var_ref_names.len);
    try std.testing.expectEqual(fb.closureVar().len, view.varRefNamesLen());
    try std.testing.expectEqual(fb.closureVar()[0].var_name, view.varRefName(0));
    try std.testing.expectEqual(fb.closureVar()[0].is_const, view.varRefIsConstAt(0));
    try std.testing.expectEqual(fb.closureVar()[0].is_lexical, view.varRefIsLexicalAt(0));
    try std.testing.expectEqualSlices(atom_module.Atom, fb.privateBoundNames(), view.private_bound_names);
    try std.testing.expectEqualSlices(core.JSValue, fb.cpoolSlice(), view.constants.values);
    try std.testing.expectEqual(fb.stack_size, view.stack_size);
}

test "createFunctionBytecode: copies global var records from FunctionDef" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("global-var-records");
    const global_name = try rt.internAtom("globalDecl");
    defer rt.atoms.free(name);
    defer rt.atoms.free(global_name);

    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);

    try fd.appendByteCode(&.{bytecode.opcode.op.return_undef});
    try fd.appendGlobalVar(.{
        .cpool_idx = -1,
        .force_init = true,
        .is_configurable = true,
        .is_lexical = true,
        .is_const = true,
        .scope_level = 0,
        .var_name = global_name,
    });

    const fb_slice = try pipeline.finalize.createFunctionBytecode(&fd, rt);
    const fb = &fb_slice[0];
    defer core.JSValue.functionBytecode(&fb.header).free(rt);

    try std.testing.expectEqual(@as(usize, 1), fb.globalVars().len);
    try std.testing.expectEqual(global_name, fb.globalVars()[0].var_name);
    try std.testing.expect(fb.globalVars()[0].force_init);
    try std.testing.expect(fb.globalVars()[0].is_configurable);
    try std.testing.expect(fb.globalVars()[0].is_lexical);
    try std.testing.expect(fb.globalVars()[0].is_const);
    try std.testing.expectEqual(@as(i32, 0), fb.globalVars()[0].scope_level);

    const view = bytecode.asBytecodeView(fb, rt);
    try std.testing.expectEqual(@as(usize, 1), view.global_vars.len);
    try std.testing.expectEqual(global_name, view.global_vars[0].var_name);
    try std.testing.expect(view.global_vars[0].force_init);
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
    try std.testing.expectEqual(@as(u16, @intCast(@min(heap_bytes, std.math.maxInt(u16)))), fb.header.meta().size_class);

    const stats = rt.gcStats();
    try std.testing.expectEqual(@as(usize, 1), stats.large_alloc_count);
    try std.testing.expectEqual(heap_bytes, stats.large_allocated_bytes);
    try std.testing.expectEqual(heap_bytes, stats.heap_live_bytes);
    try std.testing.expectEqual(heap_bytes, stats.large_object_bytes);
    try std.testing.expect(stats.large_committed_bytes >= heap_bytes);
    try std.testing.expectEqual(stats.large_committed_bytes, stats.heap_committed_bytes);
    try std.testing.expectEqual(@as(usize, 0), stats.old_alloc_count);
    // Heap object allocations no longer feed the weighted allocation_debt:
    // js_trigger_gc pacing rides on memory.allocated_bytes vs malloc_gc_threshold
    // (runtime.zig), and allocation_debt is reserved for the off-heap external
    // memory trigger (reportExternalAlloc). A large heap payload therefore leaves
    // the debt untouched.
    try std.testing.expectEqual(@as(usize, 0), stats.allocation_debt);

    core.JSValue.functionBytecode(&fb.header).free(rt);
    const after_free = rt.gcStats();
    try std.testing.expectEqual(heap_bytes, after_free.total_allocated_bytes);
    try std.testing.expectEqual(heap_bytes, after_free.large_allocated_bytes);
    try std.testing.expectEqual(@as(usize, 0), after_free.heap_live_bytes);
    try std.testing.expectEqual(@as(usize, 0), after_free.large_object_bytes);
    // Large-space committed follows live_bytes to zero the moment the payload is
    // freed (derived on demand); the freed bytes are returned to the backing
    // allocator directly, so there is no separately-tracked decommit hysteresis.
    try std.testing.expectEqual(@as(usize, 0), after_free.large_committed_bytes);
    try std.testing.expectEqual(@as(usize, 0), after_free.decommitted_bytes);
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
    var body = [_]u8{0} ** 11;
    body[0] = op.push_atom_value;
    std.mem.writeInt(u32, body[1..5], name, .little);
    body[5] = op.drop;
    body[6] = op.get_var;
    std.mem.writeInt(u16, body[7..9], 0, .little);
    body[9] = op.drop;
    body[10] = op.return_undef;
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

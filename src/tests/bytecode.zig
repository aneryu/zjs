const std = @import("std");
const zjs = @import("zjs");
const engine = zjs;

const bytecode = zjs.bytecode;
const core = zjs.core;
const frame_mod = zjs.exec.frame;

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
    try mod_record.addImport(req_index, default_atom, local, 0, false);
    try mod_record.addExport(default_atom, local);
    try mod_record.addIndirectExport(req_index, local, default_atom, false);
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
    _ = try fd.appendScope(-1);
    fd.atoms.replace(&fd.script_or_module, referrer);
    try fd.appendByteCode(&.{bytecode.opcode.op.return_undef});
    try std.testing.expectEqual(base_ref_count + 2, rt.atoms.refCount(referrer).?);

    const fb_slice = try createTestFunctionBytecode(&fd, rt);
    const fb = &fb_slice[0];
    var fb_alive = true;
    defer if (fb_alive) core.JSValue.functionBytecode(&fb.header).free(rt);
    try std.testing.expectEqual(display_filename, fb.filenameAtom());
    try std.testing.expectEqual(referrer, fb.scriptOrModule());
    try std.testing.expectEqual(atom_module.null_atom, fd.script_or_module);
    try std.testing.expectEqual(base_ref_count + 2, rt.atoms.refCount(referrer).?);

    core.JSValue.functionBytecode(&fb.header).free(rt);
    fb_alive = false;
    try std.testing.expectEqual(base_ref_count + 1, rt.atoms.refCount(referrer).?);

    fd.deinit(rt);
    fd_alive = false;
    try std.testing.expectEqual(base_ref_count + 1, rt.atoms.refCount(referrer).?);

    function.deinit(rt);
    function_alive = false;
    try std.testing.expectEqual(base_ref_count, rt.atoms.refCount(referrer).?);
}

test "bytecode setCode owns exactly the visible code bytes" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var function_bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, core.atom.ids.empty_string);
    defer function_bc.deinit(rt);

    try function_bc.setCode(&.{});
    try std.testing.expectEqual(@as(usize, 0), function_bc.code.len);
    try std.testing.expectEqual(@as(usize, 0), function_bc.code_capacity);

    try function_bc.setCode(&.{ 1, 2 });
    try std.testing.expectEqual(@as(usize, 2), function_bc.code.len);
    try std.testing.expectEqual(@as(usize, 2), function_bc.code_capacity);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, function_bc.code);
    try function_bc.setCode(&.{});
    try std.testing.expectEqual(@as(usize, 0), function_bc.code.len);
    try std.testing.expectEqual(@as(usize, 0), function_bc.code_capacity);
}

test "bytecode appendCode preserves eval-looking atom operand bytes as data" {
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
    try std.testing.expectEqualSlices(u8, &instruction, function_bc.code);
}

test "bytecode module record add failure releases duplicated atom references" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var record = bytecode.module.Record.init(&rt.memory, &rt.atoms);
    defer record.deinit();

    const import_name = try rt.internAtom("oom-bytecode-import");
    const local_name = try rt.internAtom("oom-bytecode-local");

    rt.setMemoryLimit(rt.memory.allocated_bytes);
    try std.testing.expectError(error.OutOfMemory, record.addImport(0, import_name, local_name, 0, false));
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

/// Hand-built FunctionDefs in this suite bypass Parser.State, which normally
/// creates scope zero. Give those fixtures the same mandatory root scope
/// before exercising the production finalizer.
fn createTestFunctionBytecode(
    fd: *function_def.FunctionDef,
    rt: *core.JSRuntime,
) ![]bytecode.FunctionBytecode {
    if (fd.scopes.len == 0) {
        const root_scope = try fd.appendScope(-1);
        if (root_scope != 0) return error.TestUnexpectedResult;
    }
    const realm = try core.RealmContext.create(rt);
    defer realm.destroy();
    return pipeline.finalize.createFunctionBytecode(fd, .{ .realm = realm });
}

test "createFunctionBytecode rejects a cross-runtime compile context before moving owners" {
    const owner_rt = try core.JSRuntime.create(std.testing.allocator);
    defer owner_rt.destroy();
    const foreign_rt = try core.JSRuntime.create(std.testing.allocator);
    defer foreign_rt.destroy();
    const foreign_realm = try core.RealmContext.create(foreign_rt);
    defer foreign_realm.destroy();

    const name = try owner_rt.internAtom("cross-runtime-function-bytecode");
    defer owner_rt.atoms.free(name);
    var fd = function_def.FunctionDef.init(&owner_rt.memory, &owner_rt.atoms, name);
    defer fd.deinit(owner_rt);
    _ = try fd.appendScope(-1);
    try fd.appendByteCode(&.{bytecode.opcode.op.return_undef});

    const code_ptr = fd.byte_code.ptr;
    const owner_bytes = owner_rt.memory.allocated_bytes;
    const foreign_bytes = foreign_rt.memory.allocated_bytes;
    try std.testing.expectError(
        error.InvalidBytecode,
        pipeline.finalize.createFunctionBytecode(&fd, .{ .realm = foreign_realm }),
    );
    try std.testing.expectEqual(@intFromPtr(code_ptr), @intFromPtr(fd.byte_code.ptr));
    try std.testing.expectEqualSlices(u8, &.{bytecode.opcode.op.return_undef}, fd.byte_code);
    try std.testing.expectEqual(name, fd.func_name);
    try std.testing.expectEqual(owner_bytes, owner_rt.memory.allocated_bytes);
    try std.testing.expectEqual(foreign_bytes, foreign_rt.memory.allocated_bytes);
}

test "FunctionBytecode uses the exact QJS base and optional inline tails" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const extension_bytes = @sizeOf(bytecode.function_bytecode.FunctionBytecodeHotExtension);
    const Case = struct { debug: bool, extension: bool, fam_bytes: usize };
    const cases = [_]Case{
        .{ .debug = false, .extension = false, .fam_bytes = 0 },
        .{ .debug = true, .extension = false, .fam_bytes = @sizeOf(bytecode.function_bytecode.DebugInfo) },
        .{ .debug = false, .extension = true, .fam_bytes = extension_bytes },
        .{
            .debug = true,
            .extension = true,
            .fam_bytes = @sizeOf(bytecode.function_bytecode.DebugInfo) + extension_bytes,
        },
    };

    for (cases) |case| {
        const before_bytes = rt.memory.allocated_bytes;
        const fb = try bytecode.FunctionBytecode.createFixture(rt, .{
            .has_debug = case.debug,
            .has_extension = case.extension,
        });
        try std.testing.expectEqual(@as(usize, 96), @sizeOf(bytecode.FunctionBytecode));
        try std.testing.expectEqual(@as(usize, 8), @alignOf(bytecode.FunctionBytecode));
        try std.testing.expectEqual(case.fam_bytes, fb.famBytes());
        try std.testing.expectEqual(@sizeOf(bytecode.FunctionBytecode) + case.fam_bytes, fb.layout().mainPayloadBytes());
        try std.testing.expectEqual(fb.layout().mainPayloadBytes(), fb.heapByteSize());
        try std.testing.expectEqual(case.debug, fb.hasDebug());
        try std.testing.expectEqual(case.extension, fb.hasExtension());
        try std.testing.expect(fb.legacyBytecodeAdapter() == null);
        try std.testing.expectEqual(@as(usize, 0), @intFromPtr(fb) % 8);
        try std.testing.expectEqual(@as(usize, 8), @intFromPtr(fb) - @intFromPtr(fb.header.meta()));
        try std.testing.expectEqual(core.gc.GcKind.function_bytecode, fb.header.meta().kind);
        try std.testing.expectEqual(@as(i32, 1), fb.header.meta().rc);
        try std.testing.expect(fb.header.meta().flags.metadata_in_slab);

        try std.testing.expect(fb.byte_code == null);
        try std.testing.expect(fb.vardefs == null);
        try std.testing.expect(fb.closure_var == null);
        try std.testing.expect(fb.cpool == null);
        try std.testing.expectEqual(@as(i32, 0), fb.byte_code_len);
        try std.testing.expectEqual(@as(i32, 0), fb.cpool_count);
        try std.testing.expectEqual(@as(i32, 0), fb.closure_var_count);
        try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0 }, &fb._flag_padding);
        try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0, 0 }, &fb._realm_padding);
        try std.testing.expectEqual(@as(u8, 0), fb.flag_byte18 & bytecode.FunctionBytecode.byte18_rom_mask);
        try std.testing.expectEqual(@as(u8, 0), fb.flag_byte18 & 0x80);

        if (fb.debugInfo()) |dbg| {
            try std.testing.expectEqual(@intFromPtr(fb) + 0x60, @intFromPtr(dbg));
            try std.testing.expectEqual(@as(u32, 0), dbg._padding);
            try std.testing.expect(dbg.pc2line_buf == null);
            try std.testing.expect(dbg.source_ptr == null);
        }
        if (fb.hotExtension()) |hot| {
            const expected = @intFromPtr(fb) + fb.layout().hot_off.?;
            try std.testing.expectEqual(expected, @intFromPtr(hot));
        }
        try std.testing.expectEqual(case.extension, fb.hotExtension() != null);

        fb.destroyUnpublishedFixture(rt);
        try std.testing.expectEqual(before_bytes, rt.memory.allocated_bytes);
    }

    try std.testing.expectEqual(
        @as(usize, 8),
        @sizeOf(bytecode.function_bytecode.FunctionBytecodeHotExtension),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        @offsetOf(bytecode.function_bytecode.FunctionBytecodeHotExtension, "call_facts"),
    );
    try std.testing.expectEqual(
        @as(usize, 4),
        @offsetOf(bytecode.function_bytecode.FunctionBytecodeHotExtension, "script_or_module"),
    );
}

test "FunctionLayout matches the QJS-order core pack for both JSValue representations" {
    const layout = try bytecode.FunctionLayout.init(
        true,
        true,
        2,
        1,
        2,
        2,
        3,
    );
    const value_size = @sizeOf(core.JSValue);
    const expected_cpool_off: usize = 0x80;
    const expected_vardefs_off = expected_cpool_off + 2 * value_size;
    const expected_closure_var_off = expected_vardefs_off + 3 * @sizeOf(bytecode.function_bytecode.BytecodeVarDef);
    const expected_byte_code_off = expected_closure_var_off + 2 * @sizeOf(bytecode.function_bytecode.BytecodeClosureVar);
    const expected_byte_code_end = expected_byte_code_off + 3;
    const expected_hot_extension_off = expected_byte_code_end;
    const expected_total_size =
        expected_hot_extension_off +
        @sizeOf(bytecode.function_bytecode.FunctionBytecodeHotExtension);

    try std.testing.expectEqual(expected_cpool_off, layout.cpool_off);
    try std.testing.expectEqual(expected_vardefs_off, layout.vardefs_off);
    try std.testing.expectEqual(expected_closure_var_off, layout.closure_var_off);
    try std.testing.expectEqual(expected_byte_code_off, layout.byte_code_off);
    try std.testing.expectEqual(expected_byte_code_end, layout.byte_code_end);
    try std.testing.expectEqual(@as(?usize, expected_hot_extension_off), layout.hot_off);
    try std.testing.expectEqual(expected_total_size, layout.total_size);
    try std.testing.expectEqual(expected_total_size, layout.mainPayloadBytes());
    try std.testing.expectEqual(expected_total_size - @sizeOf(bytecode.FunctionBytecode), layout.famBytes());

    switch (value_size) {
        16 => {
            try std.testing.expectEqual(@as(usize, 0x80), layout.cpool_off);
            try std.testing.expectEqual(@as(usize, 0xa0), layout.vardefs_off);
            try std.testing.expectEqual(@as(usize, 0xc4), layout.closure_var_off);
            try std.testing.expectEqual(@as(usize, 0xd4), layout.byte_code_off);
            try std.testing.expectEqual(@as(usize, 0xd7), layout.byte_code_end);
            try std.testing.expectEqual(@as(?usize, 0xd7), layout.hot_off);
            try std.testing.expectEqual(@as(usize, 0xdf), layout.total_size);
            try std.testing.expectEqual(@as(usize, 0x7f), layout.famBytes());
        },
        8 => {
            try std.testing.expectEqual(@as(usize, 0x80), layout.cpool_off);
            try std.testing.expectEqual(@as(usize, 0x90), layout.vardefs_off);
            try std.testing.expectEqual(@as(usize, 0xb4), layout.closure_var_off);
            try std.testing.expectEqual(@as(usize, 0xc4), layout.byte_code_off);
            try std.testing.expectEqual(@as(usize, 0xc7), layout.byte_code_end);
            try std.testing.expectEqual(@as(?usize, 0xc7), layout.hot_off);
            try std.testing.expectEqual(@as(usize, 0xcf), layout.total_size);
            try std.testing.expectEqual(@as(usize, 0x6f), layout.famBytes());
        },
        else => return error.TestUnexpectedResult,
    }
}

test "FunctionLayout has no padding between QJS core segments or after extension-free code" {
    const Case = struct {
        has_debug: bool,
        cpool_count: usize,
        arg_count: usize,
        var_count: usize,
        closure_count: usize,
        code_len: usize,
    };
    const cases = [_]Case{
        .{
            .has_debug = false,
            .cpool_count = 0,
            .arg_count = 0,
            .var_count = 0,
            .closure_count = 0,
            .code_len = 0,
        },
        .{
            .has_debug = true,
            .cpool_count = 3,
            .arg_count = 2,
            .var_count = 1,
            .closure_count = 2,
            .code_len = 5,
        },
    };

    for (cases) |case| {
        const layout = try bytecode.FunctionLayout.init(
            case.has_debug,
            false,
            case.cpool_count,
            case.arg_count,
            case.var_count,
            case.closure_count,
            case.code_len,
        );
        const core_end: usize = @sizeOf(bytecode.FunctionBytecode) +
            (if (case.has_debug) @as(usize, @sizeOf(bytecode.function_bytecode.DebugInfo)) else 0);
        try std.testing.expectEqual(core_end, layout.cpool_off);
        try std.testing.expectEqual(
            layout.cpool_off + case.cpool_count * @sizeOf(core.JSValue),
            layout.vardefs_off,
        );
        try std.testing.expectEqual(
            layout.vardefs_off +
                (case.arg_count + case.var_count) * @sizeOf(bytecode.function_bytecode.BytecodeVarDef),
            layout.closure_var_off,
        );
        try std.testing.expectEqual(
            layout.closure_var_off +
                case.closure_count * @sizeOf(bytecode.function_bytecode.BytecodeClosureVar),
            layout.byte_code_off,
        );
        try std.testing.expectEqual(layout.byte_code_off + case.code_len, layout.byte_code_end);
        try std.testing.expect(layout.hot_off == null);
        try std.testing.expectEqual(layout.byte_code_end, layout.total_size);
        try std.testing.expectEqual(layout.total_size, layout.mainPayloadBytes());
    }
}

test "FunctionLayout places the exact hot tail at every code-end residue" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const code = [_]u8{
        bytecode.opcode.op.return_undef,
        bytecode.opcode.op.return_undef,
        bytecode.opcode.op.return_undef,
        bytecode.opcode.op.return_undef,
        bytecode.opcode.op.return_undef,
        bytecode.opcode.op.return_undef,
        bytecode.opcode.op.return_undef,
    };

    for (0..8) |code_len| {
        const fb = try bytecode.FunctionBytecode.createFixture(rt, .{
            .byte_code = code[0..code_len],
            .has_debug = false,
            .has_extension = true,
        });
        defer fb.destroyUnpublishedFixture(rt);

        const expected = try bytecode.FunctionLayout.init(false, true, 0, 0, 0, 0, code_len);
        const actual = fb.layout();
        const expected_hot_extension_off = actual.byte_code_end;
        const expected_total_size =
            expected_hot_extension_off +
            @sizeOf(bytecode.function_bytecode.FunctionBytecodeHotExtension);

        try std.testing.expect(std.meta.eql(expected, actual));
        try std.testing.expectEqual(@as(usize, 0x60), actual.byte_code_off);
        try std.testing.expectEqual(@as(usize, 0x60) + code_len, actual.byte_code_end);
        try std.testing.expectEqual(code_len, actual.byte_code_end % 8);
        try std.testing.expectEqual(@as(?usize, expected_hot_extension_off), actual.hot_off);
        try std.testing.expectEqual(expected_total_size, actual.total_size);
        try std.testing.expectEqual(
            @intFromPtr(fb) + expected_hot_extension_off,
            @intFromPtr(fb.hotExtension().?),
        );
        if (code_len == 0) {
            try std.testing.expect(fb.byte_code == null);
        } else {
            try std.testing.expectEqual(
                @intFromPtr(fb) + actual.byte_code_off,
                @intFromPtr(fb.byte_code.?),
            );
        }
        try std.testing.expectEqualSlices(u8, code[0..code_len], fb.byteCode());
        try std.testing.expectEqual(std.mem.zeroes(bytecode.CallFacts), fb.callFacts());

        if (code_len == 3) {
            try std.testing.expectEqual(@as(usize, 0x63), actual.byte_code_end);
            try std.testing.expectEqual(@as(?usize, 0x63), actual.hot_off);
            try std.testing.expectEqual(@as(usize, 0x6b), actual.total_size);
        }
    }
}

test "FunctionLayout rejects every checked size overflow class" {
    const max = std.math.maxInt(usize);
    try std.testing.expectError(
        error.BytecodeOverflow,
        bytecode.FunctionLayout.init(false, false, max, 0, 0, 0, 0),
    );
    try std.testing.expectError(
        error.BytecodeOverflow,
        bytecode.FunctionLayout.init(false, false, 0, max, 1, 0, 0),
    );
    try std.testing.expectError(
        error.BytecodeOverflow,
        bytecode.FunctionLayout.init(false, false, 0, 0, 0, max, 0),
    );
    try std.testing.expectError(
        error.BytecodeOverflow,
        bytecode.FunctionLayout.init(true, true, 0, 0, 0, 0, max),
    );
}

test "CallFacts is one 16-bit execution snapshot" {
    try std.testing.expectEqual(@as(usize, 2), @sizeOf(bytecode.CallFacts));
    try std.testing.expectEqual(@as(usize, 0), @bitOffsetOf(bytecode.CallFacts, "execution"));
    try std.testing.expectEqual(
        @as(usize, 8),
        @sizeOf(bytecode.function_bytecode.FunctionBytecodeHotExtension),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        @offsetOf(bytecode.function_bytecode.FunctionBytecodeHotExtension, "call_facts"),
    );
    try std.testing.expectEqual(
        @as(usize, 2),
        @offsetOf(bytecode.function_bytecode.FunctionBytecodeHotExtension, "_call_facts_padding"),
    );
    try std.testing.expectEqual(
        @as(usize, 4),
        @offsetOf(bytecode.function_bytecode.FunctionBytecodeHotExtension, "script_or_module"),
    );
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const fb = try bytecode.FunctionBytecode.createFixture(rt, .{
        .has_debug = false,
        .has_extension = true,
    });
    defer fb.destroyUnpublishedFixture(rt);

    const first_execution: bytecode.function_bytecode.ExecutionFlags = .{
        .has_mapped_arguments = true,
        .strict_simple_inline_eligible = true,
        .raw_this_inline_exact_args_leaf = true,
        .exact_args_leaf_kind = .raw_this,
    };
    fb.setExecutionFlags(first_execution);

    const first_snapshot = fb.callFacts();
    try std.testing.expectEqual(first_execution, first_snapshot.execution);

    const second_execution: bytecode.function_bytecode.ExecutionFlags = .{
        .simple_inline_eligible = true,
        .simple_inline_empty_leaf = true,
        .capture_leaf_kind = .sloppy,
    };
    fb.setExecutionFlags(second_execution);
    const second_snapshot = fb.callFacts();
    try std.testing.expectEqual(second_execution, second_snapshot.execution);

    // A caller-owned snapshot is immutable even if an unpublished fixture is
    // subsequently changed through the construction-only mutators.
    try std.testing.expectEqual(first_execution, first_snapshot.execution);
}

test "FunctionBytecode raw flag bytes and packed nullable pointers are canonical" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const code = [_]u8{bytecode.opcode.op.return_undef};
    const fb = try bytecode.FunctionBytecode.createFixture(rt, .{
        .flags = .{
            .is_strict_mode = true,
            .runtime_strict_mode = true,
            .has_prototype = true,
            .has_simple_parameter_list = true,
            .is_derived_class_constructor = true,
            .need_home_object = true,
            .func_kind = .async_generator,
            .new_target_allowed = true,
            .super_call_allowed = true,
            .super_allowed = true,
            .arguments_allowed = true,
            .is_direct_or_indirect_eval = true,
        },
        .arg_count = 1,
        .var_count = 1,
        .var_ref_count = 1,
        .closure_var_count = 1,
        .cpool_count = 1,
        .byte_code = &code,
        .has_debug = true,
    });
    defer fb.destroyUnpublishedFixture(rt);

    try std.testing.expectEqual(@as(u8, 0x01), fb.js_mode);
    try std.testing.expectEqual(@as(u8, 0xff), fb.flag_byte17);
    try std.testing.expectEqual(@as(u8, 0x77), fb.flag_byte18);
    try std.testing.expectEqual(@as(u8, 0), fb.flag_byte18 & bytecode.FunctionBytecode.byte18_rom_mask);
    try std.testing.expectEqual(@as(u8, 0), fb.flag_byte18 & 0x80);
    try std.testing.expectEqual(@as(i32, 1), fb.byte_code_len);
    try std.testing.expectEqual(@as(i32, 1), fb.cpool_count);
    try std.testing.expectEqual(@as(i32, 1), fb.closure_var_count);
    try std.testing.expectEqual(@as(u16, 1), fb.var_ref_count);
    try std.testing.expect(fb.byte_code != null);
    try std.testing.expect(fb.vardefs != null);
    try std.testing.expect(fb.closure_var != null);
    try std.testing.expect(fb.cpool != null);
    try std.testing.expect(fb.cpoolSlice()[0].isUndefined());

    const expected_layout = try bytecode.FunctionLayout.init(true, true, 1, 1, 1, 1, 1);
    const layout = fb.layout();
    try std.testing.expect(std.meta.eql(expected_layout, layout));
    try std.testing.expectEqual(@intFromPtr(fb) + layout.cpool_off, @intFromPtr(fb.cpool.?));
    try std.testing.expectEqual(@intFromPtr(fb) + layout.vardefs_off, @intFromPtr(fb.vardefs.?));
    try std.testing.expectEqual(@intFromPtr(fb) + layout.closure_var_off, @intFromPtr(fb.closure_var.?));
    try std.testing.expectEqual(@intFromPtr(fb) + layout.byte_code_off, @intFromPtr(fb.byte_code.?));
    try std.testing.expectEqual(
        @intFromPtr(fb) + layout.hot_off.?,
        @intFromPtr(fb.hotExtension().?),
    );
    try std.testing.expectEqual(fb.callFacts(), fb.canonicalCallFacts());
}

test "packed FunctionBytecode zero-count pointers stay null beside non-empty segments" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const fb = try bytecode.FunctionBytecode.createFixture(rt, .{
        .var_count = 1,
        .cpool_count = 1,
        .has_debug = false,
        .has_extension = true,
    });
    defer fb.destroyUnpublishedFixture(rt);

    const expected_layout = try bytecode.FunctionLayout.init(false, true, 1, 0, 1, 0, 0);
    const layout = fb.layout();
    try std.testing.expect(std.meta.eql(expected_layout, layout));
    try std.testing.expect(fb.cpool != null);
    try std.testing.expect(fb.vardefs != null);
    try std.testing.expect(fb.closure_var == null);
    try std.testing.expect(fb.byte_code == null);
    try std.testing.expectEqual(@intFromPtr(fb) + layout.cpool_off, @intFromPtr(fb.cpool.?));
    try std.testing.expectEqual(@intFromPtr(fb) + layout.vardefs_off, @intFromPtr(fb.vardefs.?));
    try std.testing.expectEqual(
        @intFromPtr(fb) + layout.hot_off.?,
        @intFromPtr(fb.hotExtension().?),
    );
    try std.testing.expectEqual(std.mem.zeroes(bytecode.CallFacts), fb.callFacts());
    switch (@sizeOf(core.JSValue)) {
        16 => {
            try std.testing.expectEqual(@as(usize, 0x7c), layout.byte_code_end);
            try std.testing.expectEqual(@as(?usize, 0x7c), layout.hot_off);
            try std.testing.expectEqual(@as(usize, 0x84), layout.total_size);
        },
        8 => {
            try std.testing.expectEqual(@as(usize, 0x74), layout.byte_code_end);
            try std.testing.expectEqual(@as(?usize, 0x74), layout.hot_off);
            try std.testing.expectEqual(@as(usize, 0x7c), layout.total_size);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "non-empty W1c5 fixture does not force the optional extension" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const before_bytes = rt.memory.allocated_bytes;
    const code = [_]u8{bytecode.opcode.op.return_undef};
    const fb = try bytecode.FunctionBytecode.createFixture(rt, .{
        .byte_code = &code,
        .has_debug = false,
        .has_extension = false,
    });

    const expected_layout = try bytecode.FunctionLayout.init(false, false, 0, 0, 0, 0, code.len);
    const layout = fb.layout();
    try std.testing.expect(std.meta.eql(expected_layout, layout));
    try std.testing.expect(!fb.hasDebug());
    try std.testing.expect(!fb.hasExtension());
    try std.testing.expect(fb.hotExtension() == null);
    try std.testing.expect(layout.hot_off == null);
    try std.testing.expectEqual(layout.byte_code_end, layout.total_size);
    try std.testing.expectEqual(code.len, fb.famBytes());
    try std.testing.expect(fb.byte_code != null);
    try std.testing.expectEqual(@intFromPtr(fb) + layout.byte_code_off, @intFromPtr(fb.byte_code.?));
    try std.testing.expectEqualSlices(u8, &code, fb.byteCode());

    fb.destroyUnpublishedFixture(rt);
    try std.testing.expectEqual(before_bytes, rt.memory.allocated_bytes);
}

test "FunctionBytecode FAM builder zeroes a reused slab payload without touching metadata" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const code = [_]u8{
        bytecode.opcode.op.undefined,
        bytecode.opcode.op.drop,
        bytecode.opcode.op.return_undef,
    };
    // Keep a sibling block live so freeing `first` does not return the whole
    // slab arena; the next allocation must consume the just-freed slot.
    const guard = try bytecode.FunctionBytecode.createFixture(rt, .{
        .arg_count = 1,
        .closure_var_count = 1,
        .cpool_count = 1,
        .byte_code = &code,
        .has_debug = true,
        .has_extension = true,
    });
    defer guard.destroyUnpublishedFixture(rt);
    const first = try bytecode.FunctionBytecode.createFixture(rt, .{
        .arg_count = 1,
        .closure_var_count = 1,
        .cpool_count = 1,
        .byte_code = &code,
        .has_debug = true,
        .has_extension = true,
    });
    const first_address = @intFromPtr(first);
    @memset(&first._flag_padding, 0xaa);
    @memset(&first._realm_padding, 0xbb);
    first.debugInfoMut().?._padding = 0xcccccccc;
    first.cpoolSlice()[0] = core.JSValue.int32(99);
    first.allVarDefs()[0].scope_next = 0x12345678;
    first.allVarDefs()[0].flags = 0xff;
    first.allVarDefs()[0].reserved = 0xff;
    first.allVarDefs()[0].var_ref_idx = 0xffff;
    first.closureVar()[0].flags = 0xff;
    first.closureVar()[0].kind_flags = 0xff;
    first.closureVar()[0].var_idx = 0xffff;
    first.hotExtensionMut().?.call_facts = @bitCast(@as(u16, 0xffff));
    first.hotExtensionMut().?._call_facts_padding = 0xffff;
    first.destroyUnpublishedFixture(rt);

    const second = try bytecode.FunctionBytecode.createFixture(rt, .{
        .arg_count = 1,
        .closure_var_count = 1,
        .cpool_count = 1,
        .byte_code = &code,
        .has_debug = true,
        .has_extension = true,
    });
    defer second.destroyUnpublishedFixture(rt);
    try std.testing.expectEqual(first_address, @intFromPtr(second));
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0 }, &second._flag_padding);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0, 0 }, &second._realm_padding);
    try std.testing.expectEqual(@as(u32, 0), second.debugInfo().?._padding);
    try std.testing.expect(second.cpoolSlice()[0].isUndefined());
    try std.testing.expectEqual(atom_module.null_atom, second.allVarDefs()[0].var_name);
    try std.testing.expectEqual(@as(i32, 0), second.allVarDefs()[0].scope_next);
    try std.testing.expectEqual(@as(u8, 0), second.allVarDefs()[0].flags);
    try std.testing.expectEqual(@as(u8, 0), second.allVarDefs()[0].reserved);
    try std.testing.expectEqual(@as(u16, 0), second.allVarDefs()[0].var_ref_idx);
    try std.testing.expectEqual(@as(u8, 0), second.closureVar()[0].flags);
    try std.testing.expectEqual(@as(u8, 0), second.closureVar()[0].kind_flags);
    try std.testing.expectEqual(@as(u16, 0), second.closureVar()[0].var_idx);
    try std.testing.expectEqual(atom_module.null_atom, second.closureVar()[0].var_name);
    try std.testing.expectEqual(std.mem.zeroes(bytecode.CallFacts), second.hotExtension().?.call_facts);
    try std.testing.expectEqual(@as(u16, 0), second.hotExtension().?._call_facts_padding);
    try std.testing.expectEqual(atom_module.null_atom, second.hotExtension().?.script_or_module);
    try std.testing.expectEqual(core.gc.GcKind.function_bytecode, second.header.meta().kind);
    try std.testing.expectEqual(@as(i32, 1), second.header.meta().rc);
}

test "published no-debug no-extension FunctionBytecode uses the deferred zero-FAM free path" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    errdefer rt.destroy();

    const fb = try bytecode.FunctionBytecode.createFixture(rt, .{
        .has_debug = false,
        .has_extension = false,
    });
    try std.testing.expect(!fb.hasDebug());
    try std.testing.expect(!fb.hasExtension());
    try std.testing.expectEqual(@as(usize, 0), fb.famBytes());
    fb.publishFixtureNoFail(rt);

    // Runtime teardown deinitializes FB resources in Pass A and releases the
    // raw struct in the deferred Pass B. The physical-tail bits must therefore
    // survive deinit so destroyWithFam receives the original zero length.
    rt.destroy();
}

test "published packed FunctionBytecode preserves its exact FAM size through deferred free" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    errdefer rt.destroy();

    const code = [_]u8{
        bytecode.opcode.op.undefined,
        bytecode.opcode.op.drop,
        bytecode.opcode.op.return_undef,
    };
    const fb = try bytecode.FunctionBytecode.createFixture(rt, .{
        .arg_count = 1,
        .var_count = 1,
        .closure_var_count = 1,
        .cpool_count = 1,
        .byte_code = &code,
        .has_debug = true,
        .has_extension = true,
    });
    const expected_layout = try bytecode.FunctionLayout.init(true, true, 1, 1, 1, 1, code.len);
    try std.testing.expect(std.meta.eql(expected_layout, fb.layout()));
    try std.testing.expect(fb.famBytes() > @sizeOf(bytecode.function_bytecode.DebugInfo));
    fb.publishFixtureNoFail(rt);

    // Pass A clears the live count/pointer owners. Pass B must still hand the
    // exact original packed-FAM length to destroyWithFam, rather than
    // reconstructing a zero or extension-only tail from cleared fields.
    rt.destroy();
}

fn finalizeMutableWithTestRealm(
    function: *bytecode.Bytecode,
    fd: ?*function_def.FunctionDef,
    rt: *core.JSRuntime,
) !void {
    const realm = try core.RealmContext.create(rt);
    defer realm.destroy();
    return pipeline.finalize.runWithFunctionDefRuntime(function, fd, .{ .realm = realm });
}

fn resolveEvalDeclarationPlan(
    rt: *core.JSRuntime,
    name: core.Atom,
    declaration_name: core.Atom,
    is_eval: bool,
    cpool_idx: i32,
    closure_vars: []const function_def.ClosureVar.Init,
) !function_def.GlobalVar {
    var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer bc.deinit(rt);
    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);
    fd.is_eval = is_eval;
    _ = try fd.appendScope(-1);
    for (closure_vars) |cv| _ = try fd.addClosureVar(cv);
    try fd.appendGlobalVar(.{
        .cpool_idx = cpool_idx,
        .scope_level = 0,
        .var_name = declaration_name,
    });

    const input = [_]u8{bytecode.opcode.op.return_undef};
    try bc.setCode(&input);
    var ctx = pipeline.resolve_variables.JSContext.initWithFunctionDef(&bc, &fd);
    try pipeline.resolve_variables.run(&ctx);
    return fd.global_vars[0];
}

fn resolveEvalDeclarationTarget(
    rt: *core.JSRuntime,
    name: core.Atom,
    declaration_name: core.Atom,
    is_eval: bool,
    closure_vars: []const function_def.ClosureVar.Init,
) !function_def.EvalBindingTarget {
    return (try resolveEvalDeclarationPlan(rt, name, declaration_name, is_eval, -1, closure_vars)).eval_target;
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
    try std.testing.expectEqual(function_def.ClosureType.local, fd.closure_var[0].closureType());
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
    try std.testing.expectEqual(function_def.ClosureType.global, fd.closure_var[0].closureType());
}

test "resolve_variables preserves three-byte apply_eval with nonzero scope high byte" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("apply-eval-size");
    defer rt.atoms.free(name);

    var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer bc.deinit(rt);

    const op = bytecode.opcode.op;
    const raw_scope_idx = @as(u16, op.eval) << 8;
    var input = [_]u8{ op.apply_eval, 0, 0, op.return_undef };
    std.mem.writeInt(u16, input[1..3], raw_scope_idx, .little);

    try bc.setCode(&input);
    var ctx = pipeline.resolve_variables.JSContext.init(&bc);
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

    const exact_then_var = [_]function_def.ClosureVar.Init{
        .{ .closure_type = .ref, .var_idx = 0, .var_name = x_atom },
        .{ .closure_type = .ref, .var_idx = 1, .var_name = core.atom.ids.var_object },
    };
    switch (try resolveEvalDeclarationTarget(rt, name, x_atom, true, &exact_then_var)) {
        .closure => |idx| try std.testing.expectEqual(@as(u16, 0), idx),
        else => try std.testing.expect(false),
    }

    const global_then_var = [_]function_def.ClosureVar.Init{
        .{ .closure_type = .global, .var_idx = 0, .var_name = x_atom },
        .{ .closure_type = .ref, .var_idx = 1, .var_name = core.atom.ids.var_object },
    };
    switch (try resolveEvalDeclarationTarget(rt, name, x_atom, true, &global_then_var)) {
        // QuickJS instantiate_hoisted_definitions stops at the first
        // same-name closure, including GLOBAL, before considering _var_.
        .closure => |idx| try std.testing.expectEqual(@as(u16, 0), idx),
        else => try std.testing.expect(false),
    }

    const with_then_var = [_]function_def.ClosureVar.Init{
        .{ .closure_type = .ref, .var_idx = 0, .var_name = core.atom.ids.with_object },
        .{ .closure_type = .ref, .var_idx = 1, .var_name = core.atom.ids.var_object },
    };
    switch (try resolveEvalDeclarationTarget(rt, name, x_atom, true, &with_then_var)) {
        .var_object => |idx| try std.testing.expectEqual(@as(u16, 1), idx),
        else => try std.testing.expect(false),
    }
    const with_only = [_]function_def.ClosureVar.Init{
        .{ .closure_type = .ref, .var_idx = 0, .var_name = core.atom.ids.with_object },
    };
    switch (try resolveEvalDeclarationTarget(rt, name, x_atom, true, &with_only)) {
        .global => {},
        else => try std.testing.expect(false),
    }

    const arg_then_body = [_]function_def.ClosureVar.Init{
        .{ .closure_type = .ref, .var_idx = 0, .var_name = core.atom.ids.arg_var_object },
        .{ .closure_type = .ref, .var_idx = 1, .var_name = core.atom.ids.var_object },
    };
    switch (try resolveEvalDeclarationTarget(rt, name, x_atom, true, &arg_then_body)) {
        .var_object => |idx| try std.testing.expectEqual(@as(u16, 0), idx),
        else => try std.testing.expect(false),
    }
    const body_then_arg = [_]function_def.ClosureVar.Init{
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

test "resolve_variables: catch var is the sole first-match eval declaration target" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("eval-catch-var-plan");
    const x_atom = try rt.internAtom("x");
    defer rt.atoms.free(name);
    defer rt.atoms.free(x_atom);

    const catch_then_var_object = [_]function_def.ClosureVar.Init{
        .{ .closure_type = .ref, .var_kind = .catch_, .var_idx = 0, .var_name = x_atom },
        .{ .closure_type = .ref, .var_idx = 1, .var_name = core.atom.ids.var_object },
    };
    const var_plan = try resolveEvalDeclarationPlan(rt, name, x_atom, true, -1, &catch_then_var_object);
    switch (var_plan.eval_target) {
        .closure => |idx| try std.testing.expectEqual(@as(u16, 0), idx),
        else => try std.testing.expect(false),
    }

    // Function declarations use the same pinned-QuickJS first-match walk.
    const function_plan = try resolveEvalDeclarationPlan(rt, name, x_atom, true, 0, &catch_then_var_object);
    switch (function_plan.eval_target) {
        .closure => |idx| try std.testing.expectEqual(@as(u16, 0), idx),
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
    try std.testing.expectEqual(function_def.ClosureType.global, fd.closure_var[0].closureType());
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
    try std.testing.expectEqual(function_def.ClosureType.global, fd.closure_var[0].closureType());
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
    try std.testing.expectEqual(function_def.ClosureType.global, fd.closure_var[0].closureType());
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
    std.mem.writeInt(u32, input[5..9], 16, .little);
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
            std.mem.writeInt(u32, input[5..9], 16, .little);
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

test "resolve_variables skips dead binding events through a referenced merge" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("dead-binding-merge");
    const x_atom = try rt.internAtom("x");
    defer rt.atoms.free(name);
    defer rt.atoms.free(x_atom);

    var owner = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer owner.deinit(rt);
    _ = try owner.appendScope(-1);
    _ = try owner.addScopeVar(x_atom, .normal, 0, true, false);
    const owner_ref_count = rt.atoms.refCount(x_atom).?;

    var child = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer child.deinit(rt);
    child.parent = &owner;
    child.parent_scope_level = 0;
    _ = try child.appendScope(-1);

    var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer bc.deinit(rt);

    const op = bytecode.opcode.op;
    var input = [_]u8{0} ** 26;
    input[0] = op.push_true;
    input[1] = op.if_false;
    std.mem.writeInt(u32, input[2..6], 20, .little);
    input[6] = op.return_undef;
    input[7] = op.line_num;
    std.mem.writeInt(u32, input[8..12], 30, .little);
    input[12] = op.scope_get_var;
    std.mem.writeInt(u32, input[13..17], x_atom, .little);
    std.mem.writeInt(u16, input[17..19], 0, .little);
    input[19] = op.drop;
    input[20] = op.label;
    input[25] = op.return_undef;
    try bc.setCode(&input);
    try bc.retainAtomOperand(x_atom);
    try bc.appendSourceLoc(0, 10, 1);
    try bc.appendSourceLoc(6, 20, 1);
    try bc.appendSourceLoc(7, 30, 1);
    try bc.appendSourceLoc(12, 31, 1);
    try bc.appendSourceLoc(20, 40, 1);
    try bc.appendSourceLoc(25, 50, 1);

    var ctx = pipeline.resolve_variables.JSContext.initWithFunctionDef(&bc, &child);
    try pipeline.resolve_variables.run(&ctx);

    var expected = [_]u8{0} ** 13;
    expected[0] = op.push_true;
    expected[1] = op.if_false;
    std.mem.writeInt(u32, expected[2..6], 7, .little);
    expected[6] = op.return_undef;
    expected[7] = op.label;
    expected[12] = op.return_undef;
    try std.testing.expectEqualSlices(u8, &expected, bc.code);
    try std.testing.expectEqual(@as(usize, 0), bc.atom_operands.len);
    try std.testing.expectEqual(owner_ref_count, rt.atoms.refCount(x_atom).?);
    try std.testing.expectEqual(@as(usize, 0), child.closure_var.len);
    try std.testing.expectEqual(@as(i32, 0), owner.var_ref_count);
    try std.testing.expect(!owner.vars[0].is_captured);

    const expected_source_pcs = [_]u32{ 0, 6, 7, 7, 7, 12 };
    try std.testing.expectEqual(expected_source_pcs.len, bc.source_loc_slots.len);
    for (expected_source_pcs, bc.source_loc_slots) |expected_pc, slot| {
        try std.testing.expectEqual(expected_pc, slot.pc);
    }
}

test "resolve_variables does not revive a dead-only jump cycle" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("dead-binding-cycle");
    const x_atom = try rt.internAtom("x");
    defer rt.atoms.free(name);
    defer rt.atoms.free(x_atom);

    var owner = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer owner.deinit(rt);
    _ = try owner.appendScope(-1);
    _ = try owner.addScopeVar(x_atom, .normal, 0, true, false);
    const owner_ref_count = rt.atoms.refCount(x_atom).?;

    var child = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer child.deinit(rt);
    child.parent = &owner;
    child.parent_scope_level = 0;
    _ = try child.appendScope(-1);

    var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer bc.deinit(rt);

    const op = bytecode.opcode.op;
    var input = [_]u8{0} ** 19;
    input[0] = op.return_undef;
    input[1] = op.label;
    input[6] = op.scope_get_var;
    std.mem.writeInt(u32, input[7..11], x_atom, .little);
    std.mem.writeInt(u16, input[11..13], 0, .little);
    input[13] = op.drop;
    input[14] = op.goto;
    std.mem.writeInt(u32, input[15..19], 1, .little);
    try bc.setCode(&input);
    try bc.retainAtomOperand(x_atom);
    try bc.appendSourceLoc(0, 10, 1);
    try bc.appendSourceLoc(1, 20, 1);
    try bc.appendSourceLoc(6, 30, 1);
    try bc.appendSourceLoc(14, 40, 1);

    var variables_ctx = pipeline.resolve_variables.JSContext.initWithFunctionDef(&bc, &child);
    try pipeline.resolve_variables.run(&variables_ctx);

    try std.testing.expectEqualSlices(u8, &.{op.return_undef}, bc.code);
    try std.testing.expectEqual(@as(usize, 0), bc.atom_operands.len);
    try std.testing.expectEqual(owner_ref_count, rt.atoms.refCount(x_atom).?);
    try std.testing.expectEqual(@as(usize, 0), child.closure_var.len);
    try std.testing.expectEqual(@as(i32, 0), owner.var_ref_count);
    try std.testing.expect(!owner.vars[0].is_captured);
    try std.testing.expectEqualSlices(
        u32,
        &.{ 0, 1, 1, 1 },
        &.{
            bc.source_loc_slots[0].pc,
            bc.source_loc_slots[1].pc,
            bc.source_loc_slots[2].pc,
            bc.source_loc_slots[3].pc,
        },
    );

    var labels_ctx = pipeline.resolve_labels.JSContext.initWithFunctionDef(&bc, &child);
    try pipeline.resolve_labels.run(&labels_ctx);
    try std.testing.expectEqualSlices(u8, &.{op.return_undef}, bc.code);
    try std.testing.expectEqual(@as(usize, 1), bc.source_loc_slots.len);
    try std.testing.expectEqual(@as(u32, 0), bc.source_loc_slots[0].pc);
}

test "resolve_variables uses the exact QuickJS phase2 terminal set" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("phase2-terminals");
    const terminal_atom = try rt.internAtom("terminal");
    const dead_atom = try rt.internAtom("dead");
    defer rt.atoms.free(name);
    defer rt.atoms.free(terminal_atom);
    defer rt.atoms.free(dead_atom);

    const op = bytecode.opcode.op;
    const cases = [_]struct {
        op_id: u8,
        size: usize,
    }{
        .{ .op_id = op.goto, .size = 5 },
        .{ .op_id = op.tail_call, .size = 3 },
        .{ .op_id = op.tail_call_method, .size = 3 },
        .{ .op_id = op.@"return", .size = 1 },
        .{ .op_id = op.return_undef, .size = 1 },
        .{ .op_id = op.throw, .size = 1 },
        .{ .op_id = op.throw_error, .size = 6 },
        .{ .op_id = op.ret, .size = 1 },
    };

    for (cases) |case| {
        var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
        defer bc.deinit(rt);

        var input = [_]u8{0} ** 12;
        input[0] = case.op_id;
        if (case.op_id == op.goto) {
            std.mem.writeInt(u32, input[1..5], 10, .little);
        } else if (case.op_id == op.throw_error) {
            std.mem.writeInt(u32, input[1..5], terminal_atom, .little);
            try bc.retainAtomOperand(terminal_atom);
        }
        input[case.size] = op.push_atom_value;
        std.mem.writeInt(u32, input[case.size + 1 ..][0..4], dead_atom, .little);
        input[case.size + 5] = op.return_undef;
        try bc.setCode(input[0 .. case.size + 6]);
        try bc.retainAtomOperand(dead_atom);

        const dead_base_ref_count = rt.atoms.refCount(dead_atom).? - 1;
        var ctx = pipeline.resolve_variables.JSContext.init(&bc);
        try pipeline.resolve_variables.run(&ctx);

        if (case.op_id == op.goto) {
            var expected = [_]u8{0} ** 6;
            expected[0] = op.goto;
            std.mem.writeInt(u32, expected[1..5], 5, .little);
            expected[5] = op.return_undef;
            try std.testing.expectEqualSlices(u8, &expected, bc.code);
        } else {
            try std.testing.expectEqualSlices(u8, input[0..case.size], bc.code);
        }
        try std.testing.expectEqual(dead_base_ref_count, rt.atoms.refCount(dead_atom).?);
        if (case.op_id == op.throw_error) {
            try std.testing.expectEqualSlices(core.Atom, &.{terminal_atom}, bc.atom_operands);
        } else {
            try std.testing.expectEqual(@as(usize, 0), bc.atom_operands.len);
        }
    }
}

test "resolve_variables keeps return_async fallthrough for phase3" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("phase2-return-async");
    const retained_atom = try rt.internAtom("after-return-async");
    defer rt.atoms.free(name);
    defer rt.atoms.free(retained_atom);

    var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer bc.deinit(rt);

    const op = bytecode.opcode.op;
    var input = [_]u8{0} ** 8;
    input[0] = op.return_async;
    input[1] = op.push_atom_value;
    std.mem.writeInt(u32, input[2..6], retained_atom, .little);
    input[6] = op.drop;
    input[7] = op.return_undef;
    try bc.setCode(&input);
    try bc.retainAtomOperand(retained_atom);

    var ctx = pipeline.resolve_variables.JSContext.init(&bc);
    try pipeline.resolve_variables.run(&ctx);

    try std.testing.expectEqualSlices(u8, &input, bc.code);
    try std.testing.expectEqualSlices(core.Atom, &.{retained_atom}, bc.atom_operands);
}

test "resolve_variables owns empty finalizer removal and enables the phase3 cascade" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("phase2-empty-finalizer");
    const retained_atom = try rt.internAtom("phase2-empty-owner");
    defer rt.atoms.free(name);
    defer rt.atoms.free(retained_atom);
    const base_ref_count = rt.atoms.refCount(retained_atom).?;

    var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer bc.deinit(rt);

    const op = bytecode.opcode.op;
    var input = [_]u8{0} ** 30;
    input[0] = op.push_atom_value;
    std.mem.writeInt(u32, input[1..5], retained_atom, .little);
    input[5] = op.drop;
    input[6] = op.undefined;
    input[7] = op.gosub;
    std.mem.writeInt(u32, input[8..12], 18, .little);
    input[12] = op.drop;
    input[13] = op.goto;
    std.mem.writeInt(u32, input[14..18], 24, .little);
    input[18] = op.label;
    std.mem.writeInt(u32, input[19..23], 1, .little);
    input[23] = op.ret;
    input[24] = op.label;
    std.mem.writeInt(u32, input[25..29], 2, .little);
    input[29] = op.return_undef;
    try bc.setCode(&input);
    try bc.retainAtomOperand(retained_atom);
    for ([_]u32{ 0, 5, 6, 7, 12, 13, 18, 23, 24, 29 }, 0..) |pc, idx| {
        try bc.appendSourceLoc(pc, @intCast(10 + idx), 1);
    }

    var variables_ctx = pipeline.resolve_variables.JSContext.init(&bc);
    try pipeline.resolve_variables.run(&variables_ctx);

    var phase2_expected = [_]u8{0} ** 19;
    phase2_expected[0] = op.push_atom_value;
    std.mem.writeInt(u32, phase2_expected[1..5], retained_atom, .little);
    phase2_expected[5] = op.drop;
    phase2_expected[6] = op.undefined;
    phase2_expected[7] = op.drop;
    phase2_expected[8] = op.goto;
    std.mem.writeInt(u32, phase2_expected[9..13], 13, .little);
    phase2_expected[13] = op.label;
    std.mem.writeInt(u32, phase2_expected[14..18], 2, .little);
    phase2_expected[18] = op.return_undef;
    try std.testing.expectEqualSlices(u8, &phase2_expected, bc.code);
    try std.testing.expectEqualSlices(core.Atom, &.{retained_atom}, bc.atom_operands);
    try std.testing.expectEqual(base_ref_count + 1, rt.atoms.refCount(retained_atom).?);
    const phase2_source_pcs = [_]u32{ 0, 5, 6, 7, 7, 8, 13, 13, 13, 18 };
    try std.testing.expectEqual(phase2_source_pcs.len, bc.source_loc_slots.len);
    for (phase2_source_pcs, bc.source_loc_slots) |expected_pc, slot| {
        try std.testing.expectEqual(expected_pc, slot.pc);
    }

    var labels_ctx = pipeline.resolve_labels.JSContext.init(&bc);
    try pipeline.resolve_labels.run(&labels_ctx);
    try std.testing.expectEqualSlices(u8, &.{op.return_undef}, bc.code);
    try std.testing.expectEqual(@as(usize, 0), bc.atom_operands.len);
    try std.testing.expectEqual(base_ref_count, rt.atoms.refCount(retained_atom).?);
    for (bc.source_loc_slots) |slot| try std.testing.expectEqual(@as(u32, 0), slot.pc);
}

test "resolve_variables only removes a direct ret finalizer" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("phase2-nonempty-finalizer");
    defer rt.atoms.free(name);
    const op = bytecode.opcode.op;

    {
        var input = [_]u8{0} ** 14;
        input[0] = op.undefined;
        input[1] = op.gosub;
        std.mem.writeInt(u32, input[2..6], 7, .little);
        input[6] = op.drop;
        input[7] = op.label;
        std.mem.writeInt(u32, input[8..12], 1, .little);
        input[12] = op.nop;
        input[13] = op.ret;

        var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
        defer bc.deinit(rt);
        try bc.setCode(&input);
        var ctx = pipeline.resolve_variables.JSContext.init(&bc);
        try pipeline.resolve_variables.run(&ctx);
        try std.testing.expectEqualSlices(u8, &input, bc.code);
    }

    {
        var input = [_]u8{0} ** 18;
        input[0] = op.undefined;
        input[1] = op.gosub;
        std.mem.writeInt(u32, input[2..6], 7, .little);
        input[6] = op.drop;
        input[7] = op.label;
        std.mem.writeInt(u32, input[8..12], 1, .little);
        input[12] = op.goto;
        std.mem.writeInt(u32, input[13..17], 17, .little);
        input[17] = op.ret;

        var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
        defer bc.deinit(rt);
        try bc.setCode(&input);
        var ctx = pipeline.resolve_variables.JSContext.init(&bc);
        try pipeline.resolve_variables.run(&ctx);
        try std.testing.expectEqualSlices(u8, &input, bc.code);
    }
}

fn runEmptyFinalizerPhase2AllocationFailure(
    cleanup_rt: *core.JSRuntime,
    fail_offset: usize,
) !bool {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var account = core.memory.MemoryAccount.init(failing.allocator());
    var atoms = core.atom.AtomTable.init(&account);
    defer atoms.deinit();

    const retained_atom = try atoms.internString("phase2-empty-finalizer-oom");
    defer atoms.free(retained_atom);
    const base_ref_count = atoms.refCount(retained_atom).?;

    var bc = bytecode.Bytecode.init(&account, &atoms, core.atom.ids.empty_string);
    defer bc.deinit(cleanup_rt);

    const op = bytecode.opcode.op;
    var input = [_]u8{0} ** 30;
    input[0] = op.push_atom_value;
    std.mem.writeInt(u32, input[1..5], retained_atom, .little);
    input[5] = op.drop;
    input[6] = op.undefined;
    input[7] = op.gosub;
    std.mem.writeInt(u32, input[8..12], 18, .little);
    input[12] = op.drop;
    input[13] = op.goto;
    std.mem.writeInt(u32, input[14..18], 24, .little);
    input[18] = op.label;
    std.mem.writeInt(u32, input[19..23], 1, .little);
    input[23] = op.ret;
    input[24] = op.label;
    std.mem.writeInt(u32, input[25..29], 2, .little);
    input[29] = op.return_undef;
    try bc.setCode(&input);
    try bc.retainAtomOperand(retained_atom);
    try bc.appendSourceLoc(7, 10, 1);

    const original_code_ptr = bc.code.ptr;
    const original_code_capacity = bc.code_capacity;
    const original_atom_ptr = bc.atom_operands.ptr;
    const original_atom_capacity = bc.atom_operands_capacity;
    const original_source_ptr = bc.source_loc_slots.ptr;
    const original_source_capacity = bc.source_loc_capacity;
    const original_atom_refs = atoms.refCount(retained_atom).?;

    failing.fail_index = failing.alloc_index + fail_offset;
    var ctx = pipeline.resolve_variables.JSContext.init(&bc);
    const first_result = pipeline.resolve_variables.run(&ctx);
    const failed = if (first_result) |_| false else |err| switch (err) {
        error.OutOfMemory => true,
        else => return err,
    };
    failing.fail_index = std.math.maxInt(usize);

    if (failed) {
        try std.testing.expect(failing.has_induced_failure);
        try std.testing.expectEqual(@intFromPtr(original_code_ptr), @intFromPtr(bc.code.ptr));
        try std.testing.expectEqual(original_code_capacity, bc.code_capacity);
        try std.testing.expectEqualSlices(u8, &input, bc.code);
        try std.testing.expectEqual(@intFromPtr(original_atom_ptr), @intFromPtr(bc.atom_operands.ptr));
        try std.testing.expectEqual(original_atom_capacity, bc.atom_operands_capacity);
        try std.testing.expectEqualSlices(core.Atom, &.{retained_atom}, bc.atom_operands);
        try std.testing.expectEqual(@intFromPtr(original_source_ptr), @intFromPtr(bc.source_loc_slots.ptr));
        try std.testing.expectEqual(original_source_capacity, bc.source_loc_capacity);
        try std.testing.expectEqual(@as(usize, 1), bc.source_loc_slots.len);
        try std.testing.expectEqual(@as(u32, 7), bc.source_loc_slots[0].pc);
        try std.testing.expectEqual(original_atom_refs, atoms.refCount(retained_atom).?);
        try pipeline.resolve_variables.run(&ctx);
    } else {
        try std.testing.expect(!failing.has_induced_failure);
    }

    var expected = [_]u8{0} ** 19;
    expected[0] = op.push_atom_value;
    std.mem.writeInt(u32, expected[1..5], retained_atom, .little);
    expected[5] = op.drop;
    expected[6] = op.undefined;
    expected[7] = op.drop;
    expected[8] = op.goto;
    std.mem.writeInt(u32, expected[9..13], 13, .little);
    expected[13] = op.label;
    std.mem.writeInt(u32, expected[14..18], 2, .little);
    expected[18] = op.return_undef;
    try std.testing.expectEqualSlices(u8, &expected, bc.code);
    try std.testing.expectEqualSlices(core.Atom, &.{retained_atom}, bc.atom_operands);
    try std.testing.expectEqual(base_ref_count + 1, atoms.refCount(retained_atom).?);
    try std.testing.expectEqual(@as(usize, 1), bc.source_loc_slots.len);
    try std.testing.expectEqual(@as(u32, 7), bc.source_loc_slots[0].pc);
    return failed;
}

test "resolve_variables empty finalizer removal is transactional across every allocation failure" {
    const cleanup_rt = try core.JSRuntime.create(std.testing.allocator);
    defer cleanup_rt.destroy();

    var fail_offset: usize = 0;
    while (try runEmptyFinalizerPhase2AllocationFailure(cleanup_rt, fail_offset)) {
        fail_offset += 1;
    }
    try std.testing.expect(fail_offset >= 8);
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
    std.mem.writeInt(u32, input[5..9], 18, .little);
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

test "resolve_variables: patched make-ref label folds a tail beyond the former scan bound" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("long-reference-tail");
    const global_atom = try rt.internAtom("g");
    const local_atom = try rt.internAtom("value");
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
    var input = [_]u8{0} ** 39;
    input[0] = op.scope_make_ref;
    std.mem.writeInt(u32, input[1..5], global_atom, .little);
    std.mem.writeInt(u32, input[5..9], 36, .little);
    std.mem.writeInt(u16, input[9..11], 0, .little);
    var pc: usize = 11;
    for (0..9) |_| {
        input[pc] = op.undefined;
        input[pc + 1] = op.drop;
        pc += 2;
    }
    try std.testing.expectEqual(@as(usize, 29), pc);
    input[pc] = op.scope_get_var;
    std.mem.writeInt(u32, input[pc + 1 ..][0..4], local_atom, .little);
    std.mem.writeInt(u16, input[pc + 5 ..][0..2], 0, .little);
    pc += 7;
    try std.testing.expectEqual(@as(usize, 36), pc);
    input[pc] = op.insert3;
    input[pc + 1] = op.put_ref_value;
    input[pc + 2] = op.return_undef;

    try bc.setCode(&input);
    try bc.retainAtomOperand(global_atom);
    try bc.retainAtomOperand(local_atom);

    var ctx = pipeline.resolve_variables.JSContext.initWithFunctionDef(&bc, &fd);
    try pipeline.resolve_variables.run(&ctx);

    try std.testing.expectEqual(@as(usize, 24), bc.code.len);
    for (0..9) |index| {
        try std.testing.expectEqual(op.undefined, bc.code[index * 2]);
        try std.testing.expectEqual(op.drop, bc.code[index * 2 + 1]);
    }
    try std.testing.expectEqual(op.get_loc0, bc.code[18]);
    try std.testing.expectEqual(op.dup, bc.code[19]);
    try std.testing.expectEqual(op.put_var, bc.code[20]);
    try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, bc.code[21..23], .little));
    try std.testing.expectEqual(op.return_undef, bc.code[23]);
    try std.testing.expectEqual(@as(usize, 0), bc.atom_operands.len);
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
    std.mem.writeInt(u32, input[5..9], 16, .little);
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
    std.mem.writeInt(u32, input[5..9], 18, .little);
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

test "resolve_variables: unpatched scope_make_ref never scans for a nearby put tail" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("unpatched-make-ref");
    const global_atom = try rt.internAtom("g");
    defer rt.atoms.free(name);
    defer rt.atoms.free(global_atom);

    var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer bc.deinit(rt);

    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);
    _ = try fd.appendScope(-1);

    const op = bytecode.opcode.op;
    var input = [_]u8{0} ** 14;
    input[0] = op.scope_make_ref;
    std.mem.writeInt(u32, input[1..5], global_atom, .little);
    // A zero label cannot associate the reference with the adjacent put.
    // Parser-produced make refs always publish an exact forward target.
    std.mem.writeInt(u32, input[5..9], 0, .little);
    std.mem.writeInt(u16, input[9..11], 0, .little);
    input[11] = op.undefined;
    input[12] = op.put_ref_value;
    input[13] = op.return_undef;

    try bc.setCode(&input);
    try bc.retainAtomOperand(global_atom);

    var ctx = pipeline.resolve_variables.JSContext.initWithFunctionDef(&bc, &fd);
    try pipeline.resolve_variables.run(&ctx);

    try std.testing.expectEqualSlices(u8, &.{
        op.make_var_ref,
        @as(u8, @truncate(global_atom)),
        @as(u8, @truncate(global_atom >> 8)),
        @as(u8, @truncate(global_atom >> 16)),
        @as(u8, @truncate(global_atom >> 24)),
        op.undefined,
        op.put_ref_value,
        op.return_undef,
    }, bc.code);
    try std.testing.expectEqualSlices(core.Atom, &.{global_atom}, bc.atom_operands);
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

test "resolve_labels: preserves the generator initial_yield boundary" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("initial-yield");
    defer rt.atoms.free(name);

    var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer bc.deinit(rt);

    const op = bytecode.opcode.op;
    var input = [_]u8{0} ** 8;
    input[0] = op.initial_yield;
    input[1] = op.push_i32;
    std.mem.writeInt(i32, input[2..6], 1, .little);
    input[6] = op.yield;
    input[7] = op.return_async;
    try bc.setCode(&input);

    var ctx = pipeline.resolve_labels.JSContext.init(&bc);
    try pipeline.resolve_labels.run(&ctx);

    try std.testing.expectEqualSlices(u8, &input, bc.code);
}

test "resolve_labels: rewrites absolute goto target to relative offset" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("test");
    defer rt.atoms.free(name);

    var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer bc.deinit(rt);

    const op = bytecode.opcode.op;

    // push_i32 7 ; goto <absolute pc=11> ; drop ; nop ; return
    // The nop keeps this as a relocation test instead of the independent
    // goto-to-terminal fold.
    var input = [_]u8{0} ** 13;
    input[0] = op.push_i32;
    std.mem.writeInt(i32, input[1..5], 7, .little);
    input[5] = op.goto;
    std.mem.writeInt(u32, input[6..10], 11, .little);
    input[10] = op.drop;
    input[11] = op.nop;
    input[12] = op.@"return";
    try bc.setCode(&input);

    var ctx = pipeline.resolve_labels.JSContext.init(&bc);
    try pipeline.resolve_labels.run(&ctx);

    try std.testing.expectEqual(@as(usize, 12), bc.code.len);
    try std.testing.expectEqual(op.goto, bc.code[5]);
    try std.testing.expectEqual(@as(i32, 4), std.mem.readInt(i32, bc.code[6..10], .little));
    try std.testing.expectEqual(op.nop, bc.code[10]);
    try std.testing.expectEqual(op.@"return", bc.code[11]);
}

test "resolve_labels: threads jumps through unconditional goto targets" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("test");
    defer rt.atoms.free(name);

    var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer bc.deinit(rt);

    const op = bytecode.opcode.op;

    // goto pc=6 ; dead nop ; goto pc=12 ; dead nop ; nop ; return.
    // The first jump is threaded through the unreachable second jump, but
    // does not itself target the following instruction.
    var input = [_]u8{0} ** 14;
    input[0] = op.goto;
    std.mem.writeInt(u32, input[1..5], 6, .little);
    input[5] = op.nop;
    input[6] = op.goto;
    std.mem.writeInt(u32, input[7..11], 12, .little);
    input[11] = op.nop;
    input[12] = op.nop;
    input[13] = op.@"return";
    try bc.setCode(&input);

    var ctx = pipeline.resolve_labels.JSContext.init(&bc);
    try pipeline.resolve_labels.run(&ctx);

    try std.testing.expectEqual(@as(usize, 7), bc.code.len);
    try std.testing.expectEqual(op.goto, bc.code[0]);
    try std.testing.expectEqual(@as(i32, 4), std.mem.readInt(i32, bc.code[1..5], .little));
    try std.testing.expectEqual(op.nop, bc.code[5]);
    try std.testing.expectEqual(op.@"return", bc.code[6]);
}

test "resolve_labels threads all five with atom-label targets through goto chains" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("with-target-threading");
    const probe_atom = try rt.internAtom("dynamicName");
    const dead_atom = try rt.internAtom("dead-chain-operand");
    defer rt.atoms.free(name);
    defer rt.atoms.free(probe_atom);
    defer rt.atoms.free(dead_atom);
    const probe_base_refs = rt.atoms.refCount(probe_atom).?;
    const dead_base_refs = rt.atoms.refCount(dead_atom).?;

    const op = bytecode.opcode.op;
    const probe_ops = [_]u8{
        op.with_get_var,
        op.with_put_var,
        op.with_delete_var,
        op.with_make_ref,
        op.with_get_ref,
    };
    for (probe_ops) |probe_op| {
        // probe -> A: goto B; dead atom/drop/return; B: return_undef.
        // The dynamic taken edge must target B directly. Its ordinary
        // fallthrough return and B's terminal both remain distinct.
        var input = [_]u8{0} ** 34;
        input[0] = probe_op;
        std.mem.writeInt(u32, input[1..5], probe_atom, .little);
        std.mem.writeInt(u32, input[5..9], 11, .little);
        input[9] = 1;
        input[10] = op.return_undef;
        input[11] = op.label;
        std.mem.writeInt(u32, input[12..16], 1, .little);
        input[16] = op.goto;
        std.mem.writeInt(u32, input[17..21], 28, .little);
        input[21] = op.push_atom_value;
        std.mem.writeInt(u32, input[22..26], dead_atom, .little);
        input[26] = op.drop;
        input[27] = op.return_undef;
        input[28] = op.label;
        std.mem.writeInt(u32, input[29..33], 2, .little);
        input[33] = op.return_undef;

        var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
        defer bc.deinit(rt);
        try bc.setCode(&input);
        try bc.retainAtomOperand(probe_atom);
        try bc.retainAtomOperand(dead_atom);
        try bc.appendSourceLoc(0, 10, 2);
        try bc.appendSourceLoc(16, 11, 3);
        try bc.appendSourceLoc(21, 12, 4);
        try bc.appendSourceLoc(33, 13, 5);

        var ctx = pipeline.resolve_labels.JSContext.init(&bc);
        try pipeline.resolve_labels.run(&ctx);

        try std.testing.expectEqual(@as(usize, 12), bc.code.len);
        try std.testing.expectEqual(probe_op, bc.code[0]);
        try std.testing.expectEqual(probe_atom, std.mem.readInt(u32, bc.code[1..5], .little));
        try std.testing.expectEqual(@as(i32, 6), std.mem.readInt(i32, bc.code[5..9], .little));
        try std.testing.expectEqual(@as(u8, 1), bc.code[9]);
        try std.testing.expectEqual(op.return_undef, bc.code[10]);
        try std.testing.expectEqual(op.return_undef, bc.code[11]);

        try std.testing.expectEqualSlices(core.Atom, &.{probe_atom}, bc.atom_operands);
        try std.testing.expectEqual(probe_base_refs + 1, rt.atoms.refCount(probe_atom).?);
        try std.testing.expectEqual(dead_base_refs, rt.atoms.refCount(dead_atom).?);
        try std.testing.expectEqual(@as(usize, 4), bc.source_loc_slots.len);
        try std.testing.expectEqual(@as(u32, 0), bc.source_loc_slots[0].pc);
        try std.testing.expectEqual(@as(u32, 11), bc.source_loc_slots[1].pc);
        try std.testing.expectEqual(@as(u32, 11), bc.source_loc_slots[2].pc);
        try std.testing.expectEqual(@as(u32, 11), bc.source_loc_slots[3].pc);
    }
    try std.testing.expectEqual(probe_base_refs, rt.atoms.refCount(probe_atom).?);
    try std.testing.expectEqual(dead_base_refs, rt.atoms.refCount(dead_atom).?);
}

test "resolve_labels keeps with atom-label probes at adjacent terminal targets" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("with-adjacent-target");
    const probe_atom = try rt.internAtom("dynamicName");
    defer rt.atoms.free(name);
    defer rt.atoms.free(probe_atom);

    const op = bytecode.opcode.op;
    var input = [_]u8{0} ** 11;
    input[0] = op.with_get_var;
    std.mem.writeInt(u32, input[1..5], probe_atom, .little);
    std.mem.writeInt(u32, input[5..9], 10, .little);
    input[9] = 1;
    input[10] = op.return_undef;

    var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer bc.deinit(rt);
    try bc.setCode(&input);
    try bc.retainAtomOperand(probe_atom);

    var ctx = pipeline.resolve_labels.JSContext.init(&bc);
    try pipeline.resolve_labels.run(&ctx);

    try std.testing.expectEqual(@as(usize, 11), bc.code.len);
    try std.testing.expectEqual(op.with_get_var, bc.code[0]);
    try std.testing.expectEqual(@as(i32, 5), std.mem.readInt(i32, bc.code[5..9], .little));
    try std.testing.expectEqual(op.return_undef, bc.code[10]);
    try std.testing.expectEqualSlices(core.Atom, &.{probe_atom}, bc.atom_operands);
}

test "resolve_labels with atom-label threading preserves independent entries and bounded cycles" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("with-target-boundaries");
    const probe_atom = try rt.internAtom("dynamicName");
    defer rt.atoms.free(name);
    defer rt.atoms.free(probe_atom);

    const op = bytecode.opcode.op;
    {
        // catch enters A independently, so A's goto must survive even though
        // the with probe is retargeted directly to B.
        var input = [_]u8{0} ** 35;
        input[0] = op.@"catch";
        std.mem.writeInt(u32, input[1..5], 16, .little);
        input[5] = op.with_get_ref;
        std.mem.writeInt(u32, input[6..10], probe_atom, .little);
        std.mem.writeInt(u32, input[10..14], 16, .little);
        input[14] = 1;
        input[15] = op.return_undef;
        input[16] = op.label;
        std.mem.writeInt(u32, input[17..21], 1, .little);
        input[21] = op.goto;
        std.mem.writeInt(u32, input[22..26], 28, .little);
        input[26] = op.nop;
        input[27] = op.return_undef;
        input[28] = op.label;
        std.mem.writeInt(u32, input[29..33], 2, .little);
        input[33] = op.nop;
        input[34] = op.@"return";

        var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
        defer bc.deinit(rt);
        try bc.setCode(&input);
        try bc.retainAtomOperand(probe_atom);

        var ctx = pipeline.resolve_labels.JSContext.init(&bc);
        try pipeline.resolve_labels.run(&ctx);

        try std.testing.expectEqual(@as(usize, 23), bc.code.len);
        try std.testing.expectEqual(op.@"catch", bc.code[0]);
        try std.testing.expectEqual(@as(i32, 15), std.mem.readInt(i32, bc.code[1..5], .little));
        try std.testing.expectEqual(op.with_get_ref, bc.code[5]);
        try std.testing.expectEqual(@as(i32, 11), std.mem.readInt(i32, bc.code[10..14], .little));
        try std.testing.expectEqual(op.return_undef, bc.code[15]);
        try std.testing.expectEqual(op.goto, bc.code[16]);
        try std.testing.expectEqual(@as(i32, 4), std.mem.readInt(i32, bc.code[17..21], .little));
        try std.testing.expectEqual(op.nop, bc.code[21]);
        try std.testing.expectEqual(op.@"return", bc.code[22]);
    }

    {
        // A -> B -> A exceeds the ten-hop bound. Pinned QuickJS falls back
        // to the probe's original A target instead of choosing a cycle phase.
        var input = [_]u8{0} ** 33;
        input[0] = op.with_delete_var;
        std.mem.writeInt(u32, input[1..5], probe_atom, .little);
        std.mem.writeInt(u32, input[5..9], 11, .little);
        input[9] = 1;
        input[10] = op.return_undef;
        input[11] = op.label;
        std.mem.writeInt(u32, input[12..16], 1, .little);
        input[16] = op.goto;
        std.mem.writeInt(u32, input[17..21], 23, .little);
        input[21] = op.nop;
        input[22] = op.return_undef;
        input[23] = op.label;
        std.mem.writeInt(u32, input[24..28], 2, .little);
        input[28] = op.goto;
        std.mem.writeInt(u32, input[29..33], 11, .little);

        var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
        defer bc.deinit(rt);
        try bc.setCode(&input);
        try bc.retainAtomOperand(probe_atom);

        var ctx = pipeline.resolve_labels.JSContext.init(&bc);
        try pipeline.resolve_labels.run(&ctx);

        try std.testing.expectEqual(@as(usize, 21), bc.code.len);
        try std.testing.expectEqual(op.with_delete_var, bc.code[0]);
        try std.testing.expectEqual(@as(i32, 6), std.mem.readInt(i32, bc.code[5..9], .little));
        try std.testing.expectEqual(op.return_undef, bc.code[10]);
        try std.testing.expectEqual(op.goto, bc.code[11]);
        try std.testing.expectEqual(@as(i32, 4), std.mem.readInt(i32, bc.code[12..16], .little));
        try std.testing.expectEqual(op.goto, bc.code[16]);
        try std.testing.expectEqual(@as(i32, -6), std.mem.readInt(i32, bc.code[17..21], .little));
    }
}

test "resolve_labels rejects invalid with atom-label threaded targets transactionally" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("with-invalid-target");
    const probe_atom = try rt.internAtom("dynamicName");
    defer rt.atoms.free(name);
    defer rt.atoms.free(probe_atom);

    const op = bytecode.opcode.op;
    var input = [_]u8{0} ** 17;
    input[0] = op.with_make_ref;
    std.mem.writeInt(u32, input[1..5], probe_atom, .little);
    std.mem.writeInt(u32, input[5..9], 11, .little);
    input[9] = 1;
    input[10] = op.return_undef;
    input[11] = op.goto;
    std.mem.writeInt(u32, input[12..16], 18, .little);
    input[16] = op.return_undef;

    var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer bc.deinit(rt);
    try bc.setCode(&input);
    try bc.retainAtomOperand(probe_atom);
    try bc.appendSourceLoc(0, 10, 2);

    var ctx = pipeline.resolve_labels.JSContext.init(&bc);
    try std.testing.expectError(error.InvalidBytecode, pipeline.resolve_labels.run(&ctx));

    try std.testing.expectEqualSlices(u8, &input, bc.code);
    try std.testing.expectEqualSlices(core.Atom, &.{probe_atom}, bc.atom_operands);
    try std.testing.expectEqual(@as(usize, 1), bc.source_loc_slots.len);
    try std.testing.expectEqual(@as(u32, 0), bc.source_loc_slots[0].pc);
}

test "resolve_labels normalizes branches at the following instruction boundary" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("branch-boundary");
    defer rt.atoms.free(name);
    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);
    fd.use_short_opcodes = true;
    const op = bytecode.opcode.op;

    {
        var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
        defer bc.deinit(rt);

        // goto L ; L: nop ; return
        var input = [_]u8{0} ** 12;
        input[0] = op.goto;
        std.mem.writeInt(u32, input[1..5], 5, .little);
        input[5] = op.label;
        input[10] = op.nop;
        input[11] = op.@"return";
        try bc.setCode(&input);
        try bc.appendSourceLoc(0, 2, 1);
        try bc.appendSourceLoc(10, 3, 1);

        var ctx = pipeline.resolve_labels.JSContext.initWithFunctionDef(&bc, &fd);
        try pipeline.resolve_labels.run(&ctx);

        try std.testing.expectEqualSlices(u8, &.{ op.nop, op.@"return" }, bc.code);
        try std.testing.expectEqual(@as(u32, 0), bc.source_loc_slots[0].pc);
        try std.testing.expectEqual(@as(u32, 0), bc.source_loc_slots[1].pc);
    }

    {
        var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
        defer bc.deinit(rt);

        // get_arg 0 ; if_false L ; L: nop ; return
        var input = [_]u8{0} ** 15;
        input[0] = op.get_arg;
        std.mem.writeInt(u16, input[1..3], 0, .little);
        input[3] = op.if_false;
        std.mem.writeInt(u32, input[4..8], 8, .little);
        input[8] = op.label;
        input[13] = op.nop;
        input[14] = op.@"return";
        try bc.setCode(&input);
        try bc.appendSourceLoc(3, 2, 1);
        try bc.appendSourceLoc(13, 3, 1);

        var ctx = pipeline.resolve_labels.JSContext.initWithFunctionDef(&bc, &fd);
        try pipeline.resolve_labels.run(&ctx);

        try std.testing.expectEqualSlices(u8, &.{ op.get_arg0, op.drop, op.nop, op.@"return" }, bc.code);
        try std.testing.expectEqual(@as(u32, 1), bc.source_loc_slots[0].pc);
        try std.testing.expectEqual(@as(u32, 2), bc.source_loc_slots[1].pc);
    }

    {
        var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
        defer bc.deinit(rt);

        // get_arg 0 ; if_false L1 ; goto L2 ; L1: nop ; L2: return_undef
        var input = [_]u8{0} ** 20;
        input[0] = op.get_arg;
        std.mem.writeInt(u16, input[1..3], 0, .little);
        input[3] = op.if_false;
        std.mem.writeInt(u32, input[4..8], 13, .little);
        input[8] = op.goto;
        std.mem.writeInt(u32, input[9..13], 19, .little);
        input[13] = op.label;
        input[18] = op.nop;
        input[19] = op.return_undef;
        try bc.setCode(&input);
        try bc.appendSourceLoc(3, 2, 1);
        try bc.appendSourceLoc(8, 3, 1);
        try bc.appendSourceLoc(18, 4, 1);
        try bc.appendSourceLoc(19, 5, 1);

        var ctx = pipeline.resolve_labels.JSContext.initWithFunctionDef(&bc, &fd);
        try pipeline.resolve_labels.run(&ctx);

        try std.testing.expectEqualSlices(
            u8,
            &.{ op.get_arg0, op.if_true8, 2, op.nop, op.return_undef },
            bc.code,
        );
        try std.testing.expectEqual(@as(u32, 1), bc.source_loc_slots[0].pc);
        try std.testing.expectEqual(@as(u32, 1), bc.source_loc_slots[1].pc);
        try std.testing.expectEqual(@as(u32, 3), bc.source_loc_slots[2].pc);
        try std.testing.expectEqual(@as(u32, 4), bc.source_loc_slots[3].pc);
    }

    {
        var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
        defer bc.deinit(rt);

        // The otherwise matching goto is also an independent entry. QuickJS
        // represents that entry with a label which blocks the adjacency
        // matcher; the absolute-target phase representation needs the same
        // explicit guard.
        var input = [_]u8{0} ** 25;
        input[0] = op.get_arg;
        std.mem.writeInt(u16, input[1..3], 0, .little);
        input[3] = op.if_false;
        std.mem.writeInt(u32, input[4..8], 13, .little);
        input[8] = op.goto;
        std.mem.writeInt(u32, input[9..13], 19, .little);
        input[13] = op.label;
        input[18] = op.nop;
        input[19] = op.return_undef;
        input[20] = op.goto;
        std.mem.writeInt(u32, input[21..25], 8, .little);
        try bc.setCode(&input);

        var ctx = pipeline.resolve_labels.JSContext.initWithFunctionDef(&bc, &fd);
        try pipeline.resolve_labels.run(&ctx);

        try std.testing.expectEqualSlices(
            u8,
            &.{ op.get_arg0, op.if_false8, 2, op.return_undef, op.nop, op.return_undef },
            bc.code,
        );
    }
}

test "resolve_labels reachability follows normalized conditional goto successors" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("conditional-goto-cfg");
    defer rt.atoms.free(name);
    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);
    fd.use_short_opcodes = true;

    // get_arg 0
    // if_false Lcontinue
    // goto Lexit
    // Lcontinue: goto 0
    // Lexit: return_undef
    //
    // Branch normalization emits `if_true Lexit; goto 0`. Reachability must
    // therefore retain both the normalized branch target and its fallthrough
    // trampoline, even though jump threading bypasses that trampoline in the
    // original graph and the original goto can fold directly to return_undef.
    const op = bytecode.opcode.op;
    var input = [_]u8{0} ** 29;
    input[0] = op.get_arg;
    std.mem.writeInt(u16, input[1..3], 0, .little);
    input[3] = op.if_false;
    std.mem.writeInt(u32, input[4..8], 13, .little);
    input[8] = op.goto;
    std.mem.writeInt(u32, input[9..13], 23, .little);
    input[13] = op.label;
    input[18] = op.goto;
    std.mem.writeInt(u32, input[19..23], 0, .little);
    input[23] = op.label;
    input[28] = op.return_undef;

    var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer bc.deinit(rt);
    try bc.setCode(&input);

    var ctx = pipeline.resolve_labels.JSContext.initWithFunctionDef(&bc, &fd);
    try pipeline.resolve_labels.run(&ctx);

    try std.testing.expectEqualSlices(
        u8,
        &.{ op.get_arg0, op.if_true8, 3, op.goto8, @bitCast(@as(i8, -4)), op.return_undef },
        bc.code,
    );
}

test "resolve_labels constant tests fold every QuickJS producer and preserve source mapping" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("test");
    defer rt.atoms.free(name);

    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);
    fd.use_short_opcodes = true;

    const op = bytecode.opcode.op;
    const producers = [_]struct {
        op_id: u8,
        size: usize,
        value: i32 = 0,
        truthy: bool,
    }{
        .{ .op_id = op.push_false, .size = 1, .truthy = false },
        .{ .op_id = op.push_true, .size = 1, .truthy = true },
        .{ .op_id = op.null, .size = 1, .truthy = false },
        .{ .op_id = op.undefined, .size = 1, .truthy = false },
        .{ .op_id = op.push_i32, .size = 5, .value = -1, .truthy = true },
    };
    const branches = [_]u8{ op.if_false, op.if_true };

    for (producers) |producer| {
        for (branches) |branch_op| {
            var input = [_]u8{0} ** 11;
            input[0] = producer.op_id;
            if (producer.op_id == op.push_i32) {
                std.mem.writeInt(i32, input[1..5], producer.value, .little);
            }
            const jump_pc = producer.size;
            const target_pc = jump_pc + 5;
            input[jump_pc] = branch_op;
            std.mem.writeInt(u32, input[jump_pc + 1 ..][0..4], @intCast(target_pc), .little);
            input[target_pc] = op.return_undef;

            var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
            defer bc.deinit(rt);
            try bc.setCode(input[0 .. target_pc + 1]);
            try bc.appendSourceLoc(0, 10, 2);
            try bc.appendSourceLoc(@intCast(jump_pc), 11, 3);
            try bc.appendSourceLoc(@intCast(target_pc), 12, 4);

            var ctx = pipeline.resolve_labels.JSContext.initWithFunctionDef(&bc, &fd);
            try pipeline.resolve_labels.run(&ctx);

            const taken = if (branch_op == op.if_true) producer.truthy else !producer.truthy;
            if (taken) {
                try std.testing.expectEqualSlices(u8, &.{op.return_undef}, bc.code);
                for (bc.source_loc_slots) |slot| try std.testing.expectEqual(@as(u32, 0), slot.pc);
            } else {
                try std.testing.expectEqualSlices(u8, &.{op.return_undef}, bc.code);
                for (bc.source_loc_slots) |slot| try std.testing.expectEqual(@as(u32, 0), slot.pc);
            }
        }
    }
}

test "resolve_labels constant tests prune dead consumers without a second jump pass" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const name = try rt.internAtom("constant-test-cfg");
    defer rt.atoms.free(name);

    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);
    fd.use_short_opcodes = true;

    const op = bytecode.opcode.op;
    {
        var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
        defer bc.deinit(rt);
        var input = [_]u8{
            op.push_false,
            op.if_false,
            0,
            0,
            0,
            0,
            op.nop,
            op.return_undef,
        };
        std.mem.writeInt(u32, input[2..6], 7, .little);
        try bc.setCode(&input);

        var ctx = pipeline.resolve_labels.JSContext.initWithFunctionDef(&bc, &fd);
        try pipeline.resolve_labels.run(&ctx);

        try std.testing.expectEqualSlices(u8, &.{op.return_undef}, bc.code);
    }

    {
        var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
        defer bc.deinit(rt);
        var input = [_]u8{
            op.push_false,
            op.if_false,
            0,
            0,
            0,
            0,
            op.nop,
            op.nop,
            op.return_undef,
        };
        std.mem.writeInt(u32, input[2..6], 7, .little);
        try bc.setCode(&input);

        var ctx = pipeline.resolve_labels.JSContext.initWithFunctionDef(&bc, &fd);
        try pipeline.resolve_labels.run(&ctx);

        // QuickJS emits this synthetic goto before pruning the dead consumer.
        // It deliberately does not run a second adjacency pass afterwards.
        try std.testing.expectEqualSlices(
            u8,
            &.{ op.goto8, 1, op.nop, op.return_undef },
            bc.code,
        );
    }
}

test "resolve_labels constant test preserves an interior target before branch normalization" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const name = try rt.internAtom("constant-test-interior");
    defer rt.atoms.free(name);

    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);
    fd.use_short_opcodes = true;

    var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer bc.deinit(rt);
    const op = bytecode.opcode.op;
    var input = [_]u8{0} ** 15;
    input[0] = op.get_arg;
    std.mem.writeInt(u16, input[1..3], 0, .little);
    input[3] = op.if_false;
    std.mem.writeInt(u32, input[4..8], 9, .little);
    input[8] = op.push_true;
    input[9] = op.if_true;
    std.mem.writeInt(u32, input[10..14], 14, .little);
    input[14] = op.return_undef;
    try bc.setCode(&input);

    var ctx = pipeline.resolve_labels.JSContext.initWithFunctionDef(&bc, &fd);
    try pipeline.resolve_labels.run(&ctx);

    try std.testing.expectEqualSlices(u8, &.{
        op.get_arg0,
        op.if_false8,
        2,
        op.push_true,
        op.drop,
        op.return_undef,
    }, bc.code);
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

test "resolve_labels: folds signed push_bigint_i32 neg without crossing its boundary" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("test");
    defer rt.atoms.free(name);

    const op = bytecode.opcode.op;
    const cases = [_]struct {
        input: i32,
        expected: i32,
        folds: bool,
    }{
        .{ .input = 0, .expected = 0, .folds = true },
        .{ .input = 1, .expected = -1, .folds = true },
        .{ .input = std.math.maxInt(i32), .expected = -std.math.maxInt(i32), .folds = true },
        .{ .input = std.math.minInt(i32), .expected = std.math.minInt(i32), .folds = false },
    };

    for (cases) |case| {
        var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
        defer bc.deinit(rt);

        // push_bigint_i32 <input> ; neg ; return
        var input = [_]u8{0} ** 7;
        input[0] = op.push_bigint_i32;
        std.mem.writeInt(i32, input[1..5], case.input, .little);
        input[5] = op.neg;
        input[6] = op.@"return";
        try bc.setCode(&input);
        try bc.appendSourceLoc(0, 3, 5);
        try bc.appendSourceLoc(5, 2, 10);

        var ctx = pipeline.resolve_labels.JSContext.init(&bc);
        try pipeline.resolve_labels.run(&ctx);

        try std.testing.expectEqual(op.push_bigint_i32, bc.code[0]);
        try std.testing.expectEqual(case.expected, std.mem.readInt(i32, bc.code[1..5], .little));
        if (case.folds) {
            try std.testing.expectEqual(@as(usize, 6), bc.code.len);
            try std.testing.expectEqual(op.@"return", bc.code[5]);
            try std.testing.expectEqual(@as(u32, 0), bc.source_loc_slots[1].pc);
        } else {
            try std.testing.expectEqual(@as(usize, 7), bc.code.len);
            try std.testing.expectEqual(op.neg, bc.code[5]);
            try std.testing.expectEqual(op.@"return", bc.code[6]);
            try std.testing.expectEqual(@as(u32, 5), bc.source_loc_slots[1].pc);
        }
    }
}

test "resolve_labels: discards signed push_bigint_i32 expressions without crossing targets" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("bigint-discard");
    defer rt.atoms.free(name);
    const op = bytecode.opcode.op;

    for ([_]i32{ 0, 1, std.math.maxInt(i32) }) |value| {
        var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
        defer bc.deinit(rt);

        var input = [_]u8{0} ** 8;
        input[0] = op.push_bigint_i32;
        std.mem.writeInt(i32, input[1..5], value, .little);
        input[5] = op.neg;
        input[6] = op.drop;
        input[7] = op.return_undef;
        try bc.setCode(&input);
        try bc.appendSourceLoc(0, 2, 1);
        try bc.appendSourceLoc(5, 2, 2);
        try bc.appendSourceLoc(6, 2, 3);
        try bc.appendSourceLoc(7, 3, 1);

        var ctx = pipeline.resolve_labels.JSContext.init(&bc);
        try pipeline.resolve_labels.run(&ctx);

        try std.testing.expectEqualSlices(u8, &.{op.return_undef}, bc.code);
        for (bc.source_loc_slots) |slot| try std.testing.expectEqual(@as(u32, 0), slot.pc);
    }

    // qjs guards the whole neg fold — including the drop discard — behind
    // `val != INT32_MIN`, so the INT32_MIN push/neg pair survives; only the
    // separate useless-drop-before-return rule still removes the drop.
    {
        var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
        defer bc.deinit(rt);

        var input = [_]u8{0} ** 8;
        input[0] = op.push_bigint_i32;
        std.mem.writeInt(i32, input[1..5], std.math.minInt(i32), .little);
        input[5] = op.neg;
        input[6] = op.drop;
        input[7] = op.return_undef;
        try bc.setCode(&input);

        var ctx = pipeline.resolve_labels.JSContext.init(&bc);
        try pipeline.resolve_labels.run(&ctx);

        try std.testing.expectEqual(@as(usize, 7), bc.code.len);
        try std.testing.expectEqual(op.push_bigint_i32, bc.code[0]);
        try std.testing.expectEqual(std.math.minInt(i32), std.mem.readInt(i32, bc.code[1..5], .little));
        try std.testing.expectEqual(op.neg, bc.code[5]);
        try std.testing.expectEqual(op.return_undef, bc.code[6]);
    }

    var targeted = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer targeted.deinit(rt);
    var targeted_input = [_]u8{0} ** 13;
    targeted_input[0] = op.push_bigint_i32;
    std.mem.writeInt(i32, targeted_input[1..5], 1, .little);
    targeted_input[5] = op.neg;
    targeted_input[6] = op.drop;
    targeted_input[7] = op.return_undef;
    targeted_input[8] = op.goto;
    std.mem.writeInt(u32, targeted_input[9..13], 5, .little);
    try targeted.setCode(&targeted_input);

    var targeted_ctx = pipeline.resolve_labels.JSContext.init(&targeted);
    try pipeline.resolve_labels.run(&targeted_ctx);

    try std.testing.expectEqual(@as(usize, 7), targeted.code.len);
    try std.testing.expectEqual(op.push_bigint_i32, targeted.code[0]);
    try std.testing.expectEqual(@as(i32, 1), std.mem.readInt(i32, targeted.code[1..5], .little));
    try std.testing.expectEqual(op.neg, targeted.code[5]);
    try std.testing.expectEqual(op.return_undef, targeted.code[6]);
}

test "resolve_labels: numeric discard removes push_i32 immediates but not BigInt" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("numeric-discard");
    defer rt.atoms.free(name);

    const op = bytecode.opcode.op;
    const values = [_]i32{
        std.math.minInt(i32),
        -1,
        0,
        1,
        7,
        8,
        127,
        128,
        32767,
        32768,
        std.math.maxInt(i32),
    };
    for (values) |value| {
        var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
        defer bc.deinit(rt);

        var input = [_]u8{0} ** 7;
        input[0] = op.push_i32;
        std.mem.writeInt(i32, input[1..5], value, .little);
        input[5] = op.drop;
        input[6] = op.return_undef;
        try bc.setCode(&input);
        try bc.appendSourceLoc(0, 2, 3);
        try bc.appendSourceLoc(6, 3, 1);

        var ctx = pipeline.resolve_labels.JSContext.init(&bc);
        try pipeline.resolve_labels.run(&ctx);

        try std.testing.expectEqualSlices(u8, &.{op.return_undef}, bc.code);
        try std.testing.expectEqual(@as(u32, 0), bc.source_loc_slots[0].pc);
        try std.testing.expectEqual(@as(u32, 0), bc.source_loc_slots[1].pc);
    }

    var bigint = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer bigint.deinit(rt);
    var bigint_input = [_]u8{0} ** 7;
    bigint_input[0] = op.push_bigint_i32;
    std.mem.writeInt(i32, bigint_input[1..5], 1, .little);
    bigint_input[5] = op.drop;
    bigint_input[6] = op.return_undef;
    try bigint.setCode(&bigint_input);

    var bigint_ctx = pipeline.resolve_labels.JSContext.init(&bigint);
    try pipeline.resolve_labels.run(&bigint_ctx);
    try std.testing.expectEqual(@as(usize, 6), bigint.code.len);
    try std.testing.expectEqual(op.push_bigint_i32, bigint.code[0]);
    try std.testing.expectEqual(@as(i32, 1), std.mem.readInt(i32, bigint.code[1..5], .little));
    try std.testing.expectEqual(op.return_undef, bigint.code[5]);
}

test "resolve_labels: numeric discard follows QuickJS unary sign boundaries" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("numeric-discard-sign");
    defer rt.atoms.free(name);
    const op = bytecode.opcode.op;

    const cases = [_]struct {
        value: i32,
        discarded: bool,
    }{
        .{ .value = 1, .discarded = true },
        .{ .value = std.math.maxInt(i32), .discarded = true },
        .{ .value = 0, .discarded = false },
        .{ .value = std.math.minInt(i32), .discarded = false },
    };
    for (cases) |case| {
        var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
        defer bc.deinit(rt);

        var input = [_]u8{0} ** 8;
        input[0] = op.push_i32;
        std.mem.writeInt(i32, input[1..5], case.value, .little);
        input[5] = op.neg;
        input[6] = op.drop;
        input[7] = op.return_undef;
        try bc.setCode(&input);
        try bc.appendSourceLoc(5, 2, 1);
        try bc.appendSourceLoc(6, 2, 2);
        try bc.appendSourceLoc(7, 3, 1);

        var ctx = pipeline.resolve_labels.JSContext.init(&bc);
        try pipeline.resolve_labels.run(&ctx);

        if (case.discarded) {
            try std.testing.expectEqualSlices(u8, &.{op.return_undef}, bc.code);
            for (bc.source_loc_slots) |slot| try std.testing.expectEqual(@as(u32, 0), slot.pc);
        } else {
            try std.testing.expectEqual(@as(usize, 7), bc.code.len);
            try std.testing.expectEqual(op.push_i32, bc.code[0]);
            try std.testing.expectEqual(case.value, std.mem.readInt(i32, bc.code[1..5], .little));
            try std.testing.expectEqual(op.neg, bc.code[5]);
            try std.testing.expectEqual(op.return_undef, bc.code[6]);
            try std.testing.expectEqual(@as(u32, 5), bc.source_loc_slots[0].pc);
            try std.testing.expectEqual(@as(u32, 6), bc.source_loc_slots[1].pc);
            try std.testing.expectEqual(@as(u32, 6), bc.source_loc_slots[2].pc);
        }
    }

    var folded = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer folded.deinit(rt);
    var folded_input = [_]u8{0} ** 7;
    folded_input[0] = op.push_i32;
    std.mem.writeInt(i32, folded_input[1..5], 42, .little);
    folded_input[5] = op.neg;
    folded_input[6] = op.return_undef;
    try folded.setCode(&folded_input);
    try folded.appendSourceLoc(5, 2, 1);
    try folded.appendSourceLoc(6, 3, 1);

    var folded_ctx = pipeline.resolve_labels.JSContext.init(&folded);
    try pipeline.resolve_labels.run(&folded_ctx);
    try std.testing.expectEqual(@as(usize, 6), folded.code.len);
    try std.testing.expectEqual(op.push_i32, folded.code[0]);
    try std.testing.expectEqual(@as(i32, -42), std.mem.readInt(i32, folded.code[1..5], .little));
    try std.testing.expectEqual(op.return_undef, folded.code[5]);
    try std.testing.expectEqual(@as(u32, 0), folded.source_loc_slots[0].pc);
    try std.testing.expectEqual(@as(u32, 5), folded.source_loc_slots[1].pc);

    var unary_plus = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer unary_plus.deinit(rt);
    var plus_input = [_]u8{0} ** 8;
    plus_input[0] = op.push_i32;
    std.mem.writeInt(i32, plus_input[1..5], 1, .little);
    plus_input[5] = op.plus;
    plus_input[6] = op.drop;
    plus_input[7] = op.return_undef;
    try unary_plus.setCode(&plus_input);

    var plus_ctx = pipeline.resolve_labels.JSContext.init(&unary_plus);
    try pipeline.resolve_labels.run(&plus_ctx);
    try std.testing.expectEqual(@as(usize, 7), unary_plus.code.len);
    try std.testing.expectEqual(op.push_i32, unary_plus.code[0]);
    try std.testing.expectEqual(@as(i32, 1), std.mem.readInt(i32, unary_plus.code[1..5], .little));
    try std.testing.expectEqual(op.plus, unary_plus.code[5]);
    try std.testing.expectEqual(op.return_undef, unary_plus.code[6]);
}

test "resolve_labels: numeric discard preserves control-flow boundaries and source locations" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("numeric-discard-boundary");
    defer rt.atoms.free(name);
    const op = bytecode.opcode.op;

    {
        var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
        defer bc.deinit(rt);

        // The unreachable goto makes the drop an entry boundary, so the
        // numeric push itself cannot be discarded. The independent
        // drop; return_undef rule may still replace that targeted drop.
        var input = [_]u8{0} ** 12;
        input[0] = op.push_i32;
        std.mem.writeInt(i32, input[1..5], 1, .little);
        input[5] = op.drop;
        input[6] = op.return_undef;
        input[7] = op.goto;
        std.mem.writeInt(u32, input[8..12], 5, .little);
        try bc.setCode(&input);

        var ctx = pipeline.resolve_labels.JSContext.init(&bc);
        try pipeline.resolve_labels.run(&ctx);

        try std.testing.expectEqual(@as(usize, 6), bc.code.len);
        try std.testing.expectEqual(op.push_i32, bc.code[0]);
        try std.testing.expectEqual(@as(i32, 1), std.mem.readInt(i32, bc.code[1..5], .little));
        try std.testing.expectEqual(op.return_undef, bc.code[5]);
    }

    {
        var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
        defer bc.deinit(rt);

        // QuickJS applies drop; return_undef even before removable dead code.
        try bc.setCode(&.{ op.push_true, op.drop, op.return_undef, op.push_false, op.return_undef });

        var ctx = pipeline.resolve_labels.JSContext.init(&bc);
        try pipeline.resolve_labels.run(&ctx);

        try std.testing.expectEqualSlices(u8, &.{ op.push_true, op.return_undef }, bc.code);
    }

    {
        var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
        defer bc.deinit(rt);

        // The final return is a branch target, so its preceding drop remains.
        var input = [_]u8{0} ** 9;
        input[0] = op.push_true;
        input[1] = op.dup;
        input[2] = op.if_false;
        std.mem.writeInt(u32, input[3..7], 8, .little);
        input[7] = op.drop;
        input[8] = op.return_undef;
        try bc.setCode(&input);

        var ctx = pipeline.resolve_labels.JSContext.init(&bc);
        try pipeline.resolve_labels.run(&ctx);

        try std.testing.expectEqual(op.drop, bc.code[bc.code.len - 2]);
        try std.testing.expectEqual(op.return_undef, bc.code[bc.code.len - 1]);
    }

    {
        var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
        defer bc.deinit(rt);

        try bc.setCode(&.{ op.push_true, op.drop, op.return_undef });
        try bc.appendSourceLoc(1, 2, 3);
        try bc.appendSourceLoc(2, 3, 1);

        var ctx = pipeline.resolve_labels.JSContext.init(&bc);
        try pipeline.resolve_labels.run(&ctx);

        try std.testing.expectEqualSlices(u8, &.{ op.push_true, op.return_undef }, bc.code);
        try std.testing.expectEqual(@as(u32, 1), bc.source_loc_slots[0].pc);
        try std.testing.expectEqual(@as(u32, 1), bc.source_loc_slots[1].pc);
    }
}

test "resolve_labels: string discard follows atom cpool ownership source and jump boundaries" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("string-discard");
    defer rt.atoms.free(name);
    const discarded_atom = try rt.internAtom("discarded-string");
    defer rt.atoms.free(discarded_atom);
    const retained_atom = try rt.internAtom("retained-string");
    defer rt.atoms.free(retained_atom);
    const discarded_base = rt.atoms.refCount(discarded_atom).?;
    const retained_base = rt.atoms.refCount(retained_atom).?;

    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);
    fd.use_short_opcodes = true;
    const op = bytecode.opcode.op;

    {
        var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
        defer bc.deinit(rt);

        var input = [_]u8{0} ** 12;
        input[0] = op.push_atom_value;
        std.mem.writeInt(u32, input[1..5], discarded_atom, .little);
        input[5] = op.drop;
        input[6] = op.push_atom_value;
        std.mem.writeInt(u32, input[7..11], retained_atom, .little);
        input[11] = op.@"return";
        try bc.setCode(&input);
        try bc.retainAtomOperand(discarded_atom);
        try bc.retainAtomOperand(retained_atom);
        try bc.appendSourceLoc(0, 2, 1);
        try bc.appendSourceLoc(5, 2, 20);
        try bc.appendSourceLoc(6, 3, 1);
        try bc.appendSourceLoc(11, 3, 20);

        var ctx = pipeline.resolve_labels.JSContext.initWithFunctionDef(&bc, &fd);
        try pipeline.resolve_labels.run(&ctx);

        var expected = [_]u8{0} ** 6;
        expected[0] = op.push_atom_value;
        std.mem.writeInt(u32, expected[1..5], retained_atom, .little);
        expected[5] = op.@"return";
        try std.testing.expectEqualSlices(u8, &expected, bc.code);
        try std.testing.expectEqualSlices(core.Atom, &.{retained_atom}, bc.atom_operands);
        try std.testing.expectEqual(discarded_base, rt.atoms.refCount(discarded_atom).?);
        try std.testing.expectEqual(retained_base + 1, rt.atoms.refCount(retained_atom).?);
        try std.testing.expectEqual(@as(u32, 0), bc.source_loc_slots[0].pc);
        try std.testing.expectEqual(@as(u32, 0), bc.source_loc_slots[1].pc);
        try std.testing.expectEqual(@as(u32, 0), bc.source_loc_slots[2].pc);
        try std.testing.expectEqual(@as(u32, 5), bc.source_loc_slots[3].pc);
    }

    {
        var discarded_empty = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
        defer discarded_empty.deinit(rt);
        var input = [_]u8{0} ** 7;
        input[0] = op.push_atom_value;
        std.mem.writeInt(u32, input[1..5], core.atom.ids.empty_string, .little);
        input[5] = op.drop;
        input[6] = op.return_undef;
        try discarded_empty.setCode(&input);
        try discarded_empty.retainAtomOperand(core.atom.ids.empty_string);

        var ctx = pipeline.resolve_labels.JSContext.initWithFunctionDef(&discarded_empty, &fd);
        try pipeline.resolve_labels.run(&ctx);
        try std.testing.expectEqualSlices(u8, &.{op.return_undef}, discarded_empty.code);
        try std.testing.expectEqual(@as(usize, 0), discarded_empty.atom_operands.len);
    }

    {
        var retained_empty = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
        defer retained_empty.deinit(rt);
        var input = [_]u8{0} ** 6;
        input[0] = op.push_atom_value;
        std.mem.writeInt(u32, input[1..5], core.atom.ids.empty_string, .little);
        input[5] = op.@"return";
        try retained_empty.setCode(&input);
        try retained_empty.retainAtomOperand(core.atom.ids.empty_string);
        try retained_empty.appendSourceLoc(0, 2, 1);
        try retained_empty.appendSourceLoc(5, 2, 3);

        var ctx = pipeline.resolve_labels.JSContext.initWithFunctionDef(&retained_empty, &fd);
        try pipeline.resolve_labels.run(&ctx);
        try std.testing.expectEqualSlices(u8, &.{ op.push_empty_string, op.@"return" }, retained_empty.code);
        try std.testing.expectEqual(@as(usize, 0), retained_empty.atom_operands.len);
        try std.testing.expectEqual(@as(u32, 0), retained_empty.source_loc_slots[0].pc);
        try std.testing.expectEqual(@as(u32, 1), retained_empty.source_loc_slots[1].pc);
    }

    {
        const tagged_atom = core.atom.atomFromUInt32(123);
        var tagged = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
        defer tagged.deinit(rt);
        var input = [_]u8{0} ** 8;
        input[0] = op.push_atom_value;
        std.mem.writeInt(u32, input[1..5], tagged_atom, .little);
        input[5] = op.drop;
        input[6] = op.push_true;
        input[7] = op.@"return";
        try tagged.setCode(&input);
        try tagged.retainAtomOperand(tagged_atom);

        var ctx = pipeline.resolve_labels.JSContext.initWithFunctionDef(&tagged, &fd);
        try pipeline.resolve_labels.run(&ctx);
        try std.testing.expectEqualSlices(u8, &input, tagged.code);
        try std.testing.expectEqualSlices(core.Atom, &.{tagged_atom}, tagged.atom_operands);
    }

    {
        var cpool = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
        defer cpool.deinit(rt);
        const string = try core.string.String.createAscii(rt, "123");
        const string_value = string.value();
        defer string_value.free(rt);
        _ = try cpool.addConstant(string_value);

        var input = [_]u8{0} ** 8;
        input[0] = op.push_const;
        std.mem.writeInt(u32, input[1..5], 0, .little);
        input[5] = op.drop;
        input[6] = op.push_true;
        input[7] = op.@"return";
        try cpool.setCode(&input);

        var ctx = pipeline.resolve_labels.JSContext.initWithFunctionDef(&cpool, &fd);
        try pipeline.resolve_labels.run(&ctx);
        try std.testing.expectEqualSlices(u8, &.{
            op.push_const8,
            0,
            op.drop,
            op.push_true,
            op.@"return",
        }, cpool.code);
    }

    {
        var targeted = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
        defer targeted.deinit(rt);
        var input = [_]u8{0} ** 13;
        input[0] = op.push_atom_value;
        std.mem.writeInt(u32, input[1..5], retained_atom, .little);
        input[5] = op.drop;
        input[6] = op.push_true;
        input[7] = op.@"return";
        input[8] = op.goto;
        std.mem.writeInt(u32, input[9..13], 5, .little);
        try targeted.setCode(&input);
        try targeted.retainAtomOperand(retained_atom);

        var ctx = pipeline.resolve_labels.JSContext.initWithFunctionDef(&targeted, &fd);
        try pipeline.resolve_labels.run(&ctx);
        try std.testing.expectEqual(@as(usize, 8), targeted.code.len);
        try std.testing.expectEqual(op.push_atom_value, targeted.code[0]);
        try std.testing.expectEqual(op.drop, targeted.code[5]);
        try std.testing.expectEqual(op.push_true, targeted.code[6]);
        try std.testing.expectEqual(op.@"return", targeted.code[7]);
        try std.testing.expectEqualSlices(core.Atom, &.{retained_atom}, targeted.atom_operands);
    }
}

fn runStringDiscardResolveLabelsOomLifecycle(allocator: std.mem.Allocator) !void {
    const rt = try core.JSRuntime.create(allocator);
    defer rt.destroy();
    const name = try rt.internAtom("string-discard-oom");
    defer rt.atoms.free(name);
    const discarded_atom = try rt.internAtom("string-discard-oom-dead");
    defer rt.atoms.free(discarded_atom);
    const retained_atom = try rt.internAtom("string-discard-oom-live");
    defer rt.atoms.free(retained_atom);

    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);
    fd.use_short_opcodes = true;

    const op = bytecode.opcode.op;
    var input = [_]u8{0} ** 12;
    input[0] = op.push_atom_value;
    std.mem.writeInt(u32, input[1..5], discarded_atom, .little);
    input[5] = op.drop;
    input[6] = op.push_atom_value;
    std.mem.writeInt(u32, input[7..11], retained_atom, .little);
    input[11] = op.@"return";

    var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer bc.deinit(rt);
    try bc.setCode(&input);
    try bc.retainAtomOperand(discarded_atom);
    try bc.retainAtomOperand(retained_atom);

    var ctx = pipeline.resolve_labels.JSContext.initWithFunctionDef(&bc, &fd);
    try pipeline.resolve_labels.run(&ctx);
    try std.testing.expectEqual(@as(usize, 6), bc.code.len);
    try std.testing.expectEqualSlices(core.Atom, &.{retained_atom}, bc.atom_operands);
}

test "resolve_labels: string discard is leak-free at every allocation failure" {
    try runStringDiscardResolveLabelsOomLifecycle(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        runStringDiscardResolveLabelsOomLifecycle,
        .{},
    );
}

test "resolve_labels: string discard OOM leaves the same bytecode reusable" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const name = try rt.internAtom("string-discard-recovery");
    defer rt.atoms.free(name);
    const literal_atom = try rt.internAtom("string-discard-recovery-literal");
    defer rt.atoms.free(literal_atom);
    const base_ref_count = rt.atoms.refCount(literal_atom).?;

    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);
    fd.use_short_opcodes = true;

    const op = bytecode.opcode.op;
    var input = [_]u8{0} ** 7;
    input[0] = op.push_atom_value;
    std.mem.writeInt(u32, input[1..5], literal_atom, .little);
    input[5] = op.drop;
    input[6] = op.return_undef;

    var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer bc.deinit(rt);
    try bc.setCode(&input);
    try bc.retainAtomOperand(literal_atom);

    rt.setMemoryLimit(rt.memory.allocated_bytes);
    defer rt.setMemoryLimit(null);
    var failed_ctx = pipeline.resolve_labels.JSContext.initWithFunctionDef(&bc, &fd);
    try std.testing.expectError(error.OutOfMemory, pipeline.resolve_labels.run(&failed_ctx));
    rt.setMemoryLimit(null);

    try std.testing.expectEqualSlices(u8, &input, bc.code);
    try std.testing.expectEqualSlices(core.Atom, &.{literal_atom}, bc.atom_operands);
    try std.testing.expectEqual(base_ref_count + 1, rt.atoms.refCount(literal_atom).?);

    var retry_ctx = pipeline.resolve_labels.JSContext.initWithFunctionDef(&bc, &fd);
    try pipeline.resolve_labels.run(&retry_ctx);
    try std.testing.expectEqualSlices(u8, &.{op.return_undef}, bc.code);
    try std.testing.expectEqual(@as(usize, 0), bc.atom_operands.len);
    try std.testing.expectEqual(base_ref_count, rt.atoms.refCount(literal_atom).?);
}

test "resolve_labels: skips dead code after unconditional goto" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("test");
    defer rt.atoms.free(name);

    var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer bc.deinit(rt);

    const op = bytecode.opcode.op;

    // goto pc=10 ; push_i32 123 ; nop ; return. The nop keeps the jump
    // non-terminal while the unreachable push is removed.
    var input = [_]u8{0} ** 12;
    input[0] = op.goto;
    std.mem.writeInt(u32, input[1..5], 10, .little);
    input[5] = op.push_i32;
    std.mem.writeInt(i32, input[6..10], 123, .little);
    input[10] = op.nop;
    input[11] = op.@"return";
    try bc.setCode(&input);

    var ctx = pipeline.resolve_labels.JSContext.init(&bc);
    try pipeline.resolve_labels.run(&ctx);

    try std.testing.expectEqual(@as(usize, 7), bc.code.len);
    try std.testing.expectEqual(op.goto, bc.code[0]);
    try std.testing.expectEqual(@as(i32, 4), std.mem.readInt(i32, bc.code[1..5], .little));
    try std.testing.expectEqual(op.nop, bc.code[5]);
    try std.testing.expectEqual(op.@"return", bc.code[6]);
}

test "resolve_labels folds gotos to terminal opcodes" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const name = try rt.internAtom("goto-terminal");
    defer rt.atoms.free(name);

    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);
    fd.use_short_opcodes = true;

    const op = bytecode.opcode.op;
    const cases = [_]struct {
        input: []const u8,
        expected: []const u8,
        expected_source_pc: u32,
    }{
        .{
            .input = &.{ op.push_i32, 1, 0, 0, 0, op.goto, 10, 0, 0, 0, op.@"return" },
            .expected = &.{ op.push_1, op.@"return" },
            .expected_source_pc = 1,
        },
        .{
            .input = &.{ op.goto, 5, 0, 0, 0, op.return_undef },
            .expected = &.{op.return_undef},
            .expected_source_pc = 0,
        },
        .{
            .input = &.{ op.push_i32, 1, 0, 0, 0, op.goto, 10, 0, 0, 0, op.throw },
            .expected = &.{ op.push_1, op.throw },
            .expected_source_pc = 1,
        },
        .{
            .input = &.{
                op.push_i32, 1,       0,               0, 0,
                op.push_i32, 2,       0,               0, 0,
                op.goto,     15,      0,               0, 0,
                op.drop,     op.drop, op.return_undef,
            },
            .expected = &.{ op.push_1, op.push_2, op.drop, op.return_undef },
            .expected_source_pc = 2,
        },
    };

    for (cases, 0..) |case, case_index| {
        var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
        defer bc.deinit(rt);
        try bc.setCode(case.input);
        const goto_pc: u32 = if (case_index == 1) 0 else if (case_index == 3) 10 else 5;
        const target_pc: u32 = std.mem.readInt(u32, case.input[goto_pc + 1 ..][0..4], .little);
        try bc.appendSourceLoc(goto_pc, 10, 2);
        try bc.appendSourceLoc(target_pc, 20, 3);

        var ctx = pipeline.resolve_labels.JSContext.initWithFunctionDef(&bc, &fd);
        try pipeline.resolve_labels.run(&ctx);

        try std.testing.expectEqualSlices(u8, case.expected, bc.code);
        try std.testing.expectEqual(@as(usize, 2), bc.source_loc_slots.len);
        for (bc.source_loc_slots) |slot| {
            try std.testing.expectEqual(case.expected_source_pc, slot.pc);
        }
    }
}

test "resolve_labels preserves goto across source-marked drop return" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const name = try rt.internAtom("goto-source-boundary");
    defer rt.atoms.free(name);

    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);
    fd.use_short_opcodes = true;

    const op = bytecode.opcode.op;
    // push_i32 1 ; goto L ; nop ; L: drop ; <source> return_undef
    //
    // QuickJS find_jump_target scans the raw phase-2 stream bytewise after
    // seeing drop. The source marker before return_undef therefore prevents
    // goto-to-terminal folding, even though the later drop peephole removes
    // the drop itself.
    var input = [_]u8{0} ** 18;
    input[0] = op.push_i32;
    std.mem.writeInt(i32, input[1..5], 1, .little);
    input[5] = op.goto;
    std.mem.writeInt(u32, input[6..10], 11, .little);
    input[10] = op.nop;
    input[11] = op.label;
    input[16] = op.drop;
    input[17] = op.return_undef;

    var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer bc.deinit(rt);
    try bc.setCode(&input);
    try bc.appendSourceLoc(17, 20, 3);

    var ctx = pipeline.resolve_labels.JSContext.initWithFunctionDef(&bc, &fd);
    try pipeline.resolve_labels.run(&ctx);

    try std.testing.expectEqualSlices(
        u8,
        &.{ op.push_1, op.goto8, 1, op.return_undef },
        bc.code,
    );
    try std.testing.expectEqual(@as(usize, 1), bc.source_loc_slots.len);
    try std.testing.expectEqual(@as(u32, 3), bc.source_loc_slots[0].pc);
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
    // goto <absolute pc=10> ; push_i32 1 ; nop ; return. The nop keeps the
    // target non-terminal so this fixture continues to cover goto8 encoding.
    var input = [_]u8{0} ** 12;
    input[0] = op.goto;
    std.mem.writeInt(u32, input[1..5], 10, .little);
    input[5] = op.push_i32;
    std.mem.writeInt(i32, input[6..10], 1, .little);
    input[10] = op.nop;
    input[11] = op.@"return";
    try bc.setCode(&input);

    var ctx = pipeline.resolve_labels.JSContext.initWithFunctionDef(&bc, &fd);
    try pipeline.resolve_labels.run(&ctx);

    try std.testing.expectEqual(@as(usize, 4), bc.code.len);
    try std.testing.expectEqual(op.goto8, bc.code[0]);
    try std.testing.expectEqual(@as(i8, 1), @as(i8, @bitCast(bc.code[1])));
    try std.testing.expectEqual(op.nop, bc.code[2]);
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
    try finalizeMutableWithTestRealm(&bc, &fd, rt);

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

test "parent finalization failure releases its published child realm owner" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const realm = try core.RealmContext.create(rt);
    defer realm.destroy();

    const name = try rt.internAtom("parent-finalize-failure");
    defer rt.atoms.free(name);
    var parent = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    var parent_alive = true;
    defer if (parent_alive) parent.deinit(rt);
    _ = try parent.appendScope(-1);

    const child = try rt.memory.create(function_def.FunctionDef);
    var child_owned = true;
    errdefer if (child_owned) {
        child.deinit(rt);
        rt.memory.destroy(function_def.FunctionDef, child);
    };
    child.* = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    _ = try child.appendScope(-1);
    try child.appendByteCode(&.{bytecode.opcode.op.return_undef});
    child.parent_cpool_idx = @intCast(try parent.appendCpool(core.JSValue.undefinedValue()));
    try parent.addChild(child);
    child_owned = false;

    // The post-order walk publishes the valid child first. The parent's
    // reachable falloff is rejected only when its own lowering runs.
    try parent.appendByteCode(&.{bytecode.opcode.op.nop});
    try std.testing.expectError(
        error.InvalidBytecode,
        pipeline.finalize.createFunctionBytecode(&parent, .{ .realm = realm }),
    );

    try std.testing.expect(parent.cpool[0].isFunctionBytecode());
    const child_header = parent.cpool[0].objectHeader() orelse return error.TestExpectedEqual;
    const child_fb: *bytecode.FunctionBytecode = @alignCast(@fieldParentPtr("header", child_header));
    try std.testing.expectEqual(realm, child_fb.realmContext());
    try std.testing.expectEqual(@as(i32, 2), realm.header.meta().rc);

    // The failed parent FunctionDef still owns the installed cpool value.
    // Releasing that owner must drop the child's independent RealmRef exactly
    // once; no partially-created parent FB may retain another reference.
    parent.deinit(rt);
    parent_alive = false;
    try std.testing.expectEqual(@as(i32, 1), realm.header.meta().rc);
}

test "parent finalization moves an existing child FunctionBytecode cpool owner without rc churn" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const realm = try core.RealmContext.create(rt);
    defer realm.destroy();

    const name = try rt.internAtom("cpool-owner-transfer");
    defer rt.atoms.free(name);

    const child_fb = try bytecode.FunctionBytecode.createFixture(rt, .{ .name = name, .realm = realm });
    child_fb.publishFixtureNoFail(rt);
    var child_value = core.JSValue.functionBytecode(&child_fb.header);
    var child_value_alive = true;
    defer if (child_value_alive) child_value.free(rt);

    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    var fd_alive = true;
    defer if (fd_alive) fd.deinit(rt);
    _ = try fd.appendScope(-1);
    try fd.appendByteCode(&.{bytecode.opcode.op.return_undef});
    _ = try fd.appendCpool(child_value);
    child_value.free(rt);
    child_value_alive = false;
    const child_rc_before = child_fb.header.meta().rc;
    try std.testing.expectEqual(@as(i32, 1), child_rc_before);

    const parent_slice = try pipeline.finalize.createFunctionBytecode(&fd, .{ .realm = realm });
    const parent_fb = &parent_slice[0];
    var parent_alive = true;
    defer if (parent_alive) core.JSValue.functionBytecode(&parent_fb.header).free(rt);

    try std.testing.expect(fd.cpool[0].isUndefined());
    try std.testing.expectEqual(child_rc_before, child_fb.header.meta().rc);
    try std.testing.expectEqual(&child_fb.header, parent_fb.cpoolSlice()[0].objectHeader().?);

    fd.deinit(rt);
    fd_alive = false;
    try std.testing.expectEqual(child_rc_before, child_fb.header.meta().rc);
    try std.testing.expectEqual(name, child_fb.funcName());
    try std.testing.expectEqual(&child_fb.header, parent_fb.cpoolSlice()[0].objectHeader().?);

    const held_child = parent_fb.cpoolSlice()[0].dup();
    var held_child_alive = true;
    defer if (held_child_alive) held_child.free(rt);
    const realm_refs_before_parent_free = realm.header.meta().rc;
    core.JSValue.functionBytecode(&parent_fb.header).free(rt);
    parent_alive = false;
    try std.testing.expectEqual(child_rc_before, child_fb.header.meta().rc);
    try std.testing.expectEqual(realm_refs_before_parent_free - 1, realm.header.meta().rc);
    held_child.free(rt);
    held_child_alive = false;
    try std.testing.expectEqual(@as(i32, 1), realm.header.meta().rc);
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
    const body_scope = try fd.appendScope(0);
    fd.body_scope = body_scope;
    fd.scope_level = body_scope;
    _ = try fd.addScopeVar(x_atom, .normal, body_scope, true, true);

    const op = bytecode.opcode.op;
    var input = [_]u8{0} ** 11;
    input[0] = op.enter_scope;
    std.mem.writeInt(u16, input[1..3], @intCast(body_scope), .little);
    input[3] = op.scope_put_var;
    std.mem.writeInt(u32, input[4..8], x_atom, .little);
    std.mem.writeInt(u16, input[8..10], @intCast(body_scope), .little);
    input[10] = op.return_undef;

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

test "resolve_variables folds discarded indexed and reference stores" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const name = try rt.internAtom("test");
    defer rt.atoms.free(name);

    var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer bc.deinit(rt);

    const op = bytecode.opcode.op;
    const input = [_]u8{
        op.insert3,      op.put_array_el,  op.drop,
        op.insert3,      op.put_ref_value, op.drop,
        op.return_undef,
    };
    try bc.setCode(&input);

    var ctx = pipeline.resolve_variables.JSContext.init(&bc);
    try pipeline.resolve_variables.run(&ctx);

    try std.testing.expectEqualSlices(u8, &.{
        op.put_array_el,
        op.put_ref_value,
        op.return_undef,
    }, bc.code);
}

test "resolve_variables removes dead prefix before a live indexed-store target" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const name = try rt.internAtom("test");
    defer rt.atoms.free(name);

    var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer bc.deinit(rt);

    const op = bytecode.opcode.op;
    var input = [_]u8{0} ** 9;
    input[0] = op.goto;
    std.mem.writeInt(u32, input[1..5], 6, .little);
    input[5] = op.insert3;
    input[6] = op.put_array_el;
    input[7] = op.drop;
    input[8] = op.return_undef;
    try bc.setCode(&input);

    var ctx = pipeline.resolve_variables.JSContext.init(&bc);
    try pipeline.resolve_variables.run(&ctx);

    var expected = [_]u8{0} ** 8;
    expected[0] = op.goto;
    std.mem.writeInt(u32, expected[1..5], 5, .little);
    expected[5] = op.put_array_el;
    expected[6] = op.drop;
    expected[7] = op.return_undef;
    try std.testing.expectEqualSlices(u8, &expected, bc.code);
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

test "resolve_labels dup put folds preserve QuickJS source mapping" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const name = try rt.internAtom("dup-put-source");
    defer rt.atoms.free(name);

    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);
    fd.use_short_opcodes = true;

    const op = bytecode.opcode.op;
    {
        var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
        defer bc.deinit(rt);
        const input = [_]u8{ op.dup, op.put_loc, 0, 0, op.@"return" };
        try bc.setCode(&input);
        try bc.appendSourceLoc(0, 10, 2);
        try bc.appendSourceLoc(1, 11, 3);
        try bc.appendSourceLoc(4, 12, 4);

        var ctx = pipeline.resolve_labels.JSContext.initWithFunctionDef(&bc, &fd);
        try pipeline.resolve_labels.run(&ctx);

        try std.testing.expectEqualSlices(u8, &.{ op.set_loc0, op.@"return" }, bc.code);
        try std.testing.expectEqual(@as(u32, 0), bc.source_loc_slots[0].pc);
        try std.testing.expectEqual(@as(u32, 0), bc.source_loc_slots[1].pc);
        try std.testing.expectEqual(@as(u32, 1), bc.source_loc_slots[2].pc);
    }

    {
        var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
        defer bc.deinit(rt);
        const input = [_]u8{ op.dup, op.put_loc, 0, 0, op.drop, op.@"return" };
        try bc.setCode(&input);
        try bc.appendSourceLoc(0, 20, 2);
        try bc.appendSourceLoc(1, 21, 3);
        try bc.appendSourceLoc(4, 22, 4);
        try bc.appendSourceLoc(5, 23, 5);

        var ctx = pipeline.resolve_labels.JSContext.initWithFunctionDef(&bc, &fd);
        try pipeline.resolve_labels.run(&ctx);

        try std.testing.expectEqualSlices(u8, &.{ op.put_loc0, op.@"return" }, bc.code);
        try std.testing.expectEqual(@as(u32, 0), bc.source_loc_slots[0].pc);
        try std.testing.expectEqual(@as(u32, 0), bc.source_loc_slots[1].pc);
        try std.testing.expectEqual(@as(u32, 0), bc.source_loc_slots[2].pc);
        try std.testing.expectEqual(@as(u32, 1), bc.source_loc_slots[3].pc);
    }

    {
        var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
        defer bc.deinit(rt);
        const input = [_]u8{
            op.dup,
            op.put_loc,
            0,
            0,
            op.drop,
            op.get_loc,
            0,
            0,
            op.@"return",
        };
        try bc.setCode(&input);
        try bc.appendSourceLoc(0, 30, 2);
        try bc.appendSourceLoc(1, 31, 3);
        try bc.appendSourceLoc(4, 32, 4);
        try bc.appendSourceLoc(5, 33, 5);
        try bc.appendSourceLoc(8, 34, 6);

        var ctx = pipeline.resolve_labels.JSContext.initWithFunctionDef(&bc, &fd);
        try pipeline.resolve_labels.run(&ctx);

        try std.testing.expectEqualSlices(u8, &.{ op.set_loc0, op.@"return" }, bc.code);
        try std.testing.expectEqual(@as(u32, 0), bc.source_loc_slots[0].pc);
        try std.testing.expectEqual(@as(u32, 0), bc.source_loc_slots[1].pc);
        try std.testing.expectEqual(@as(u32, 0), bc.source_loc_slots[2].pc);
        try std.testing.expectEqual(@as(u32, 1), bc.source_loc_slots[3].pc);
        try std.testing.expectEqual(@as(u32, 1), bc.source_loc_slots[4].pc);
    }
}

test "resolve_labels dup put folds respect indices and jump entry boundaries" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const name = try rt.internAtom("dup-put-boundaries");
    defer rt.atoms.free(name);

    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);
    fd.use_short_opcodes = true;

    const op = bytecode.opcode.op;
    {
        var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
        defer bc.deinit(rt);
        const input = [_]u8{
            op.dup,
            op.put_loc,
            0,
            0,
            op.drop,
            op.get_loc,
            1,
            0,
            op.@"return",
        };
        try bc.setCode(&input);

        var ctx = pipeline.resolve_labels.JSContext.initWithFunctionDef(&bc, &fd);
        try pipeline.resolve_labels.run(&ctx);

        try std.testing.expectEqualSlices(u8, &.{
            op.put_loc0,
            op.get_loc1,
            op.@"return",
        }, bc.code);
    }

    const cases = [_]struct {
        target: u32,
        expected: []const u8,
    }{
        .{
            .target = 9,
            .expected = &.{
                op.get_arg0,
                op.if_true8,
                2,
                op.dup,
                op.put_loc0,
                op.drop,
                op.get_loc0,
                op.return_undef,
            },
        },
        .{
            .target = 12,
            .expected = &.{
                op.get_arg0,
                op.if_true8,
                2,
                op.set_loc0,
                op.drop,
                op.get_loc0,
                op.return_undef,
            },
        },
        .{
            .target = 13,
            .expected = &.{
                op.get_arg0,
                op.if_true8,
                2,
                op.put_loc0,
                op.get_loc0,
                op.return_undef,
            },
        },
    };
    for (cases) |case| {
        var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
        defer bc.deinit(rt);
        var input = [_]u8{0} ** 17;
        input[0] = op.get_arg;
        std.mem.writeInt(u16, input[1..3], 0, .little);
        input[3] = op.if_true;
        std.mem.writeInt(u32, input[4..8], case.target, .little);
        input[8] = op.dup;
        input[9] = op.put_loc;
        std.mem.writeInt(u16, input[10..12], 0, .little);
        input[12] = op.drop;
        input[13] = op.get_loc;
        std.mem.writeInt(u16, input[14..16], 0, .little);
        input[16] = op.return_undef;
        try bc.setCode(&input);

        var ctx = pipeline.resolve_labels.JSContext.initWithFunctionDef(&bc, &fd);
        try pipeline.resolve_labels.run(&ctx);

        try std.testing.expectEqualSlices(u8, case.expected, bc.code);
    }
}

test "resolve_labels put/get folds wide slot families with QuickJS source mapping" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const name = try rt.internAtom("put-get-matrix");
    defer rt.atoms.free(name);

    const op = bytecode.opcode.op;
    const cases = [_]struct {
        put_op: u8,
        get_op: u8,
        idx: u16,
        expected: []const u8,
    }{
        .{ .put_op = op.put_loc, .get_op = op.get_loc, .idx = 0, .expected = &.{ op.set_loc0, op.@"return" } },
        .{ .put_op = op.put_loc_check, .get_op = op.get_loc_check, .idx = 4, .expected = &.{ op.set_loc_check, 4, 0, op.@"return" } },
        .{ .put_op = op.put_arg, .get_op = op.get_arg, .idx = 1, .expected = &.{ op.set_arg1, op.@"return" } },
        .{ .put_op = op.put_var_ref, .get_op = op.get_var_ref, .idx = 2, .expected = &.{ op.set_var_ref2, op.@"return" } },
    };

    for (cases) |case| {
        var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
        defer fd.deinit(rt);
        fd.use_short_opcodes = true;

        var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
        defer bc.deinit(rt);

        var input = [_]u8{0} ** 7;
        input[0] = case.put_op;
        std.mem.writeInt(u16, input[1..3], case.idx, .little);
        input[3] = case.get_op;
        std.mem.writeInt(u16, input[4..6], case.idx, .little);
        input[6] = op.@"return";
        try bc.setCode(&input);
        try bc.appendSourceLoc(0, 10, 2);
        try bc.appendSourceLoc(3, 11, 3);
        try bc.appendSourceLoc(6, 12, 4);

        var ctx = pipeline.resolve_labels.JSContext.initWithFunctionDef(&bc, &fd);
        try pipeline.resolve_labels.run(&ctx);

        try std.testing.expectEqualSlices(u8, case.expected, bc.code);
        try std.testing.expectEqual(@as(u32, 0), bc.source_loc_slots[0].pc);
        try std.testing.expectEqual(@as(u32, 0), bc.source_loc_slots[1].pc);
        try std.testing.expectEqual(@as(u32, @intCast(case.expected.len - 1)), bc.source_loc_slots[2].pc);
    }
}

test "resolve_labels put/get requires matching indices" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const name = try rt.internAtom("put-get-index");
    defer rt.atoms.free(name);

    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);
    fd.use_short_opcodes = true;

    var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer bc.deinit(rt);

    const op = bytecode.opcode.op;
    var input = [_]u8{0} ** 7;
    input[0] = op.put_loc;
    std.mem.writeInt(u16, input[1..3], 4, .little);
    input[3] = op.get_loc;
    std.mem.writeInt(u16, input[4..6], 5, .little);
    input[6] = op.@"return";
    try bc.setCode(&input);

    var ctx = pipeline.resolve_labels.JSContext.initWithFunctionDef(&bc, &fd);
    try pipeline.resolve_labels.run(&ctx);

    try std.testing.expectEqualSlices(u8, &.{
        op.put_loc8,  4,
        op.get_loc8,  5,
        op.@"return",
    }, bc.code);
}

test "resolve_labels put/get respects entry boundaries" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const name = try rt.internAtom("put-get-jump");
    defer rt.atoms.free(name);

    const op = bytecode.opcode.op;
    const cases = [_]struct {
        target: u32,
        expected: []const u8,
    }{
        .{
            .target = 11,
            .expected = &.{ op.get_arg0, op.if_false8, 2, op.put_loc0, op.get_loc0, op.@"return" },
        },
        .{
            .target = 8,
            .expected = &.{ op.get_arg0, op.drop, op.set_loc0, op.@"return" },
        },
    };

    for (cases) |case| {
        var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
        defer fd.deinit(rt);
        fd.use_short_opcodes = true;

        var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
        defer bc.deinit(rt);

        var input = [_]u8{0} ** 15;
        input[0] = op.get_arg;
        std.mem.writeInt(u16, input[1..3], 0, .little);
        input[3] = op.if_false;
        std.mem.writeInt(u32, input[4..8], case.target, .little);
        input[8] = op.put_loc;
        std.mem.writeInt(u16, input[9..11], 0, .little);
        input[11] = op.get_loc;
        std.mem.writeInt(u16, input[12..14], 0, .little);
        input[14] = op.@"return";
        try bc.setCode(&input);

        var ctx = pipeline.resolve_labels.JSContext.initWithFunctionDef(&bc, &fd);
        try pipeline.resolve_labels.run(&ctx);

        try std.testing.expectEqualSlices(u8, case.expected, bc.code);
    }
}

test "resolve_labels get_length fold remaps source locations and atom ownership" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const name = try rt.internAtom("test");
    const keep_atom = try rt.internAtom("keep");
    defer rt.atoms.free(name);
    defer rt.atoms.free(keep_atom);
    const keep_base = rt.atoms.refCount(keep_atom).?;

    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);
    fd.use_short_opcodes = true;

    var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer bc.deinit(rt);

    const op = bytecode.opcode.op;
    var input = [_]u8{0} ** 14;
    input[0] = op.get_loc0;
    input[1] = op.get_field;
    std.mem.writeInt(u32, input[2..6], keep_atom, .little);
    input[6] = op.drop;
    input[7] = op.get_loc0;
    input[8] = op.get_field;
    std.mem.writeInt(u32, input[9..13], core.atom.ids.length, .little);
    input[13] = op.drop;
    try bc.setCode(&input);
    try bc.retainAtomOperand(keep_atom);
    try bc.retainAtomOperand(core.atom.ids.length);
    try bc.appendSourceLoc(1, 10, 2);
    try bc.appendSourceLoc(8, 11, 3);
    try bc.appendSourceLoc(13, 12, 4);

    var ctx = pipeline.resolve_labels.JSContext.initWithFunctionDef(&bc, &fd);
    try pipeline.resolve_labels.run(&ctx);

    var expected = [_]u8{0} ** 10;
    expected[0] = op.get_loc0;
    expected[1] = op.get_field;
    std.mem.writeInt(u32, expected[2..6], keep_atom, .little);
    expected[6] = op.drop;
    expected[7] = op.get_loc0;
    expected[8] = op.get_length;
    expected[9] = op.drop;
    try std.testing.expectEqualSlices(u8, &expected, bc.code);
    try std.testing.expectEqualSlices(core.Atom, &.{keep_atom}, bc.atom_operands);
    try std.testing.expectEqual(keep_base + 1, rt.atoms.refCount(keep_atom).?);
    try std.testing.expectEqual(@as(usize, 3), bc.source_loc_slots.len);
    try std.testing.expectEqual(@as(u32, 1), bc.source_loc_slots[0].pc);
    try std.testing.expectEqual(@as(i32, 10), bc.source_loc_slots[0].line_num);
    try std.testing.expectEqual(@as(i32, 2), bc.source_loc_slots[0].col_num);
    try std.testing.expectEqual(@as(u32, 8), bc.source_loc_slots[1].pc);
    try std.testing.expectEqual(@as(i32, 11), bc.source_loc_slots[1].line_num);
    try std.testing.expectEqual(@as(i32, 3), bc.source_loc_slots[1].col_num);
    try std.testing.expectEqual(@as(u32, 9), bc.source_loc_slots[2].pc);
    try std.testing.expectEqual(@as(i32, 12), bc.source_loc_slots[2].line_num);
    try std.testing.expectEqual(@as(i32, 4), bc.source_loc_slots[2].col_num);
}

fn runGetLengthFoldAllocationFailure(
    cleanup_rt: *core.JSRuntime,
    fail_offset: usize,
) !bool {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var account = core.memory.MemoryAccount.init(failing.allocator());
    var atoms = core.atom.AtomTable.init(&account);
    defer atoms.deinit();

    const keep_atom = try atoms.internString("get-length-oom-keep");
    defer atoms.free(keep_atom);
    const keep_base = atoms.refCount(keep_atom).?;

    var fd = function_def.FunctionDef.init(&account, &atoms, core.atom.ids.empty_string);
    defer fd.deinit(cleanup_rt);
    fd.use_short_opcodes = true;

    var bc = bytecode.Bytecode.init(&account, &atoms, core.atom.ids.empty_string);
    defer bc.deinit(cleanup_rt);

    const op = bytecode.opcode.op;
    var input = [_]u8{0} ** 14;
    input[0] = op.get_loc0;
    input[1] = op.get_field;
    std.mem.writeInt(u32, input[2..6], keep_atom, .little);
    input[6] = op.drop;
    input[7] = op.get_loc0;
    input[8] = op.get_field;
    std.mem.writeInt(u32, input[9..13], core.atom.ids.length, .little);
    input[13] = op.drop;
    try bc.setCode(&input);
    try bc.retainAtomOperand(keep_atom);
    try bc.retainAtomOperand(core.atom.ids.length);
    try bc.appendSourceLoc(1, 10, 2);
    try bc.appendSourceLoc(8, 11, 3);
    try bc.appendSourceLoc(13, 12, 4);

    const original_code_ptr = bc.code.ptr;
    const original_code_capacity = bc.code_capacity;
    const original_atom_ptr = bc.atom_operands.ptr;
    const original_atom_capacity = bc.atom_operands_capacity;
    const original_source_ptr = bc.source_loc_slots.ptr;
    const original_source_capacity = bc.source_loc_capacity;
    const original_keep_refs = atoms.refCount(keep_atom).?;

    failing.fail_index = failing.alloc_index + fail_offset;
    var ctx = pipeline.resolve_labels.JSContext.initWithFunctionDef(&bc, &fd);
    const first_result = pipeline.resolve_labels.run(&ctx);
    const failed = if (first_result) |_| false else |err| switch (err) {
        error.OutOfMemory => true,
        else => return err,
    };
    failing.fail_index = std.math.maxInt(usize);

    if (failed) {
        try std.testing.expect(failing.has_induced_failure);
        try std.testing.expectEqual(@intFromPtr(original_code_ptr), @intFromPtr(bc.code.ptr));
        try std.testing.expectEqual(original_code_capacity, bc.code_capacity);
        try std.testing.expectEqualSlices(u8, &input, bc.code);
        try std.testing.expectEqual(@intFromPtr(original_atom_ptr), @intFromPtr(bc.atom_operands.ptr));
        try std.testing.expectEqual(original_atom_capacity, bc.atom_operands_capacity);
        try std.testing.expectEqualSlices(core.Atom, &.{ keep_atom, core.atom.ids.length }, bc.atom_operands);
        try std.testing.expectEqual(@intFromPtr(original_source_ptr), @intFromPtr(bc.source_loc_slots.ptr));
        try std.testing.expectEqual(original_source_capacity, bc.source_loc_capacity);
        try std.testing.expectEqual(@as(usize, 3), bc.source_loc_slots.len);
        try std.testing.expectEqual(@as(u32, 1), bc.source_loc_slots[0].pc);
        try std.testing.expectEqual(@as(u32, 8), bc.source_loc_slots[1].pc);
        try std.testing.expectEqual(@as(u32, 13), bc.source_loc_slots[2].pc);
        try std.testing.expectEqual(original_keep_refs, atoms.refCount(keep_atom).?);

        try pipeline.resolve_labels.run(&ctx);
    } else {
        try std.testing.expect(!failing.has_induced_failure);
    }

    var expected = [_]u8{0} ** 10;
    expected[0] = op.get_loc0;
    expected[1] = op.get_field;
    std.mem.writeInt(u32, expected[2..6], keep_atom, .little);
    expected[6] = op.drop;
    expected[7] = op.get_loc0;
    expected[8] = op.get_length;
    expected[9] = op.drop;
    try std.testing.expectEqualSlices(u8, &expected, bc.code);
    try std.testing.expectEqualSlices(core.Atom, &.{keep_atom}, bc.atom_operands);
    try std.testing.expectEqual(keep_base + 1, atoms.refCount(keep_atom).?);
    try std.testing.expectEqual(@as(usize, 3), bc.source_loc_slots.len);
    try std.testing.expectEqual(@as(u32, 1), bc.source_loc_slots[0].pc);
    try std.testing.expectEqual(@as(i32, 10), bc.source_loc_slots[0].line_num);
    try std.testing.expectEqual(@as(i32, 2), bc.source_loc_slots[0].col_num);
    try std.testing.expectEqual(@as(u32, 8), bc.source_loc_slots[1].pc);
    try std.testing.expectEqual(@as(i32, 11), bc.source_loc_slots[1].line_num);
    try std.testing.expectEqual(@as(i32, 3), bc.source_loc_slots[1].col_num);
    try std.testing.expectEqual(@as(u32, 9), bc.source_loc_slots[2].pc);
    try std.testing.expectEqual(@as(i32, 12), bc.source_loc_slots[2].line_num);
    try std.testing.expectEqual(@as(i32, 4), bc.source_loc_slots[2].col_num);
    return failed;
}

test "resolve_labels get_length fold is transactional across every allocation failure" {
    const cleanup_rt = try core.JSRuntime.create(std.testing.allocator);
    defer cleanup_rt.destroy();

    var fail_offset: usize = 0;
    while (try runGetLengthFoldAllocationFailure(cleanup_rt, fail_offset)) {
        fail_offset += 1;
    }
    // positions, sizes, CFG state/worklist, final code, and the rebuilt
    // atom-owner ledger.
    try std.testing.expectEqual(@as(usize, 6), fail_offset);
}

test "resolve_labels folds discarded slot and field stores" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const name = try rt.internAtom("test");
    const field_atom = try rt.internAtom("field");
    defer rt.atoms.free(name);
    defer rt.atoms.free(field_atom);

    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);
    fd.use_short_opcodes = true;

    var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer bc.deinit(rt);

    const op = bytecode.opcode.op;
    var input = [_]u8{0} ** 35;
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
        input[i + 4] = op.drop;
        i += 5;
    }
    input[i] = op.dup;
    input[i + 1] = op.put_loc;
    std.mem.writeInt(u16, input[i + 2 ..][0..2], 4, .little);
    input[i + 4] = op.drop;
    input[i + 5] = op.get_loc;
    std.mem.writeInt(u16, input[i + 6 ..][0..2], 4, .little);
    i += 8;
    input[i] = op.insert2;
    input[i + 1] = op.put_field;
    std.mem.writeInt(u32, input[i + 2 ..][0..4], field_atom, .little);
    input[i + 6] = op.drop;
    try bc.setCode(&input);
    try bc.retainAtomOperand(field_atom);

    var ctx = pipeline.resolve_labels.JSContext.initWithFunctionDef(&bc, &fd);
    try pipeline.resolve_labels.run(&ctx);

    var expected = [_]u8{0} ** 13;
    expected[0] = op.put_loc0;
    expected[1] = op.put_arg1;
    expected[2] = op.put_var_ref2;
    expected[3] = op.put_loc_check;
    std.mem.writeInt(u16, expected[4..6], 3, .little);
    expected[6] = op.set_loc8;
    expected[7] = 4;
    expected[8] = op.put_field;
    std.mem.writeInt(u32, expected[9..13], field_atom, .little);
    try std.testing.expectEqualSlices(u8, &expected, bc.code);
    try std.testing.expectEqualSlices(core.Atom, &.{field_atom}, bc.atom_operands);
}

test "resolve_labels preserves targeted slot store while folding its trailing discard" {
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
    var input = [_]u8{0} ** 11;
    input[0] = op.goto;
    std.mem.writeInt(u32, input[1..5], 6, .little);
    input[5] = op.dup;
    input[6] = op.put_loc;
    std.mem.writeInt(u16, input[7..9], 0, .little);
    input[9] = op.drop;
    input[10] = op.return_undef;
    try bc.setCode(&input);

    var ctx = pipeline.resolve_labels.JSContext.initWithFunctionDef(&bc, &fd);
    try pipeline.resolve_labels.run(&ctx);

    try std.testing.expectEqualSlices(u8, &.{
        op.goto8,    1,
        op.put_loc0, op.return_undef,
    }, bc.code);
}

test "resolve_labels folds the QuickJS add_loc RHS family" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const name = try rt.internAtom("add-loc-positive");
    const rhs_atom = try rt.internAtom("rhs");
    defer rt.atoms.free(name);
    defer rt.atoms.free(rhs_atom);

    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);
    fd.use_short_opcodes = true;

    var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer bc.deinit(rt);

    const op = bytecode.opcode.op;
    var input = [_]u8{0} ** 40;
    input[0] = op.get_loc;
    std.mem.writeInt(u16, input[1..3], 4, .little);
    input[3] = op.push_atom_value;
    std.mem.writeInt(u32, input[4..8], rhs_atom, .little);
    input[8] = op.add;
    input[9] = op.dup;
    input[10] = op.put_loc;
    std.mem.writeInt(u16, input[11..13], 4, .little);
    input[13] = op.drop;

    input[14] = op.get_loc;
    std.mem.writeInt(u16, input[15..17], 5, .little);
    input[17] = op.push_i32;
    std.mem.writeInt(i32, input[18..22], 42, .little);
    input[22] = op.add;
    input[23] = op.dup;
    input[24] = op.put_loc;
    std.mem.writeInt(u16, input[25..27], 5, .little);
    input[27] = op.drop;

    input[28] = op.get_loc;
    std.mem.writeInt(u16, input[29..31], 6, .little);
    input[31] = op.get_arg;
    std.mem.writeInt(u16, input[32..34], 1, .little);
    input[34] = op.add;
    input[35] = op.dup;
    input[36] = op.put_loc;
    std.mem.writeInt(u16, input[37..39], 6, .little);
    input[39] = op.drop;
    try bc.setCode(&input);
    try bc.retainAtomOperand(rhs_atom);

    var ctx = pipeline.resolve_labels.JSContext.initWithFunctionDef(&bc, &fd);
    try pipeline.resolve_labels.run(&ctx);

    var expected = [_]u8{0} ** 14;
    expected[0] = op.push_atom_value;
    std.mem.writeInt(u32, expected[1..5], rhs_atom, .little);
    expected[5] = op.add_loc;
    expected[6] = 4;
    expected[7] = op.push_i8;
    expected[8] = 42;
    expected[9] = op.add_loc;
    expected[10] = 5;
    expected[11] = op.get_arg1;
    expected[12] = op.add_loc;
    expected[13] = 6;
    try std.testing.expectEqualSlices(u8, &expected, bc.code);
    try std.testing.expectEqualSlices(core.Atom, &.{rhs_atom}, bc.atom_operands);
}

test "resolve_labels add_loc gives an empty atom RHS its short form" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const name = try rt.internAtom("add-loc-empty");
    const nonempty_atom = try rt.internAtom("nonempty");
    defer rt.atoms.free(name);
    defer rt.atoms.free(nonempty_atom);
    const nonempty_base = rt.atoms.refCount(nonempty_atom).?;

    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);
    fd.use_short_opcodes = true;

    var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer bc.deinit(rt);

    const op = bytecode.opcode.op;
    var input = [_]u8{0} ** 29;
    input[0] = op.get_loc;
    std.mem.writeInt(u16, input[1..3], 4, .little);
    input[3] = op.push_atom_value;
    std.mem.writeInt(u32, input[4..8], core.atom.ids.empty_string, .little);
    input[8] = op.add;
    input[9] = op.dup;
    input[10] = op.put_loc;
    std.mem.writeInt(u16, input[11..13], 4, .little);
    input[13] = op.drop;

    input[14] = op.get_loc;
    std.mem.writeInt(u16, input[15..17], 5, .little);
    input[17] = op.push_atom_value;
    std.mem.writeInt(u32, input[18..22], nonempty_atom, .little);
    input[22] = op.add;
    input[23] = op.dup;
    input[24] = op.put_loc;
    std.mem.writeInt(u16, input[25..27], 5, .little);
    input[27] = op.drop;
    input[28] = op.return_undef;
    try bc.setCode(&input);
    try bc.retainAtomOperand(core.atom.ids.empty_string);
    try bc.retainAtomOperand(nonempty_atom);

    for ([_]u32{ 0, 3, 8, 9, 10, 13, 14, 17, 22, 23, 24, 27, 28 }, 0..) |pc, source_idx| {
        try bc.appendSourceLoc(pc, @intCast(10 + source_idx), 2);
    }

    var ctx = pipeline.resolve_labels.JSContext.initWithFunctionDef(&bc, &fd);
    try pipeline.resolve_labels.run(&ctx);

    var expected = [_]u8{0} ** 11;
    expected[0] = op.push_empty_string;
    expected[1] = op.add_loc;
    expected[2] = 4;
    expected[3] = op.push_atom_value;
    std.mem.writeInt(u32, expected[4..8], nonempty_atom, .little);
    expected[8] = op.add_loc;
    expected[9] = 5;
    expected[10] = op.return_undef;
    try std.testing.expectEqualSlices(u8, &expected, bc.code);
    try std.testing.expectEqualSlices(core.Atom, &.{nonempty_atom}, bc.atom_operands);
    try std.testing.expectEqual(nonempty_base + 1, rt.atoms.refCount(nonempty_atom).?);
    try std.testing.expectEqual(@as(usize, 13), bc.source_loc_slots.len);
    for (bc.source_loc_slots[0..6]) |slot| {
        try std.testing.expectEqual(@as(u32, 0), slot.pc);
    }
    for (bc.source_loc_slots[6..12]) |slot| {
        try std.testing.expectEqual(@as(u32, 3), slot.pc);
    }
    try std.testing.expectEqual(@as(u32, 10), bc.source_loc_slots[12].pc);
}

test "resolve_labels add_loc does not consume a targeted empty RHS" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const name = try rt.internAtom("add-loc-empty-target");
    defer rt.atoms.free(name);

    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);
    fd.use_short_opcodes = true;

    var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer bc.deinit(rt);

    const op = bytecode.opcode.op;
    var input = [_]u8{0} ** 21;
    input[0] = op.get_arg0;
    input[1] = op.if_false;
    std.mem.writeInt(u32, input[2..6], 9, .little);
    input[6] = op.get_loc;
    std.mem.writeInt(u16, input[7..9], 0, .little);
    input[9] = op.push_atom_value;
    std.mem.writeInt(u32, input[10..14], core.atom.ids.empty_string, .little);
    input[14] = op.add;
    input[15] = op.dup;
    input[16] = op.put_loc;
    std.mem.writeInt(u16, input[17..19], 0, .little);
    input[19] = op.drop;
    input[20] = op.return_undef;
    try bc.setCode(&input);
    try bc.retainAtomOperand(core.atom.ids.empty_string);

    var ctx = pipeline.resolve_labels.JSContext.initWithFunctionDef(&bc, &fd);
    try pipeline.resolve_labels.run(&ctx);

    try std.testing.expectEqualSlices(u8, &.{
        op.get_arg0,
        op.if_false8,
        2,
        op.get_loc0,
        op.push_empty_string,
        op.add,
        op.put_loc0,
        op.return_undef,
    }, bc.code);
    try std.testing.expectEqual(@as(usize, 0), bc.atom_operands.len);
}

fn runEmptyAddLocResolveLabelsAllocationFailure(
    cleanup_rt: *core.JSRuntime,
    fail_offset: usize,
) !bool {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var account = core.memory.MemoryAccount.init(failing.allocator());
    var atoms = core.atom.AtomTable.init(&account);
    defer atoms.deinit();
    const name = try atoms.internString("add-loc-empty-oom");
    defer atoms.free(name);

    var fd = function_def.FunctionDef.init(&account, &atoms, name);
    defer fd.deinit(cleanup_rt);
    fd.use_short_opcodes = true;

    var bc = bytecode.Bytecode.init(&account, &atoms, name);
    defer bc.deinit(cleanup_rt);

    const op = bytecode.opcode.op;
    var input = [_]u8{0} ** 15;
    input[0] = op.get_loc;
    std.mem.writeInt(u16, input[1..3], 4, .little);
    input[3] = op.push_atom_value;
    std.mem.writeInt(u32, input[4..8], core.atom.ids.empty_string, .little);
    input[8] = op.add;
    input[9] = op.dup;
    input[10] = op.put_loc;
    std.mem.writeInt(u16, input[11..13], 4, .little);
    input[13] = op.drop;
    input[14] = op.return_undef;
    try bc.setCode(&input);
    try bc.retainAtomOperand(core.atom.ids.empty_string);
    for ([_]u32{ 0, 3, 8, 9, 10, 13, 14 }, 0..) |pc, source_idx| {
        try bc.appendSourceLoc(pc, @intCast(10 + source_idx), 2);
    }

    const original_code_ptr = bc.code.ptr;
    const original_code_capacity = bc.code_capacity;
    const original_atom_ptr = bc.atom_operands.ptr;
    const original_atom_capacity = bc.atom_operands_capacity;
    const original_source_ptr = bc.source_loc_slots.ptr;
    const original_source_capacity = bc.source_loc_capacity;

    failing.fail_index = failing.alloc_index + fail_offset;
    var ctx = pipeline.resolve_labels.JSContext.initWithFunctionDef(&bc, &fd);
    const first_result = pipeline.resolve_labels.run(&ctx);
    const failed = if (first_result) |_| false else |err| switch (err) {
        error.OutOfMemory => true,
        else => return err,
    };
    failing.fail_index = std.math.maxInt(usize);

    if (failed) {
        try std.testing.expect(failing.has_induced_failure);
        try std.testing.expectEqual(@intFromPtr(original_code_ptr), @intFromPtr(bc.code.ptr));
        try std.testing.expectEqual(original_code_capacity, bc.code_capacity);
        try std.testing.expectEqualSlices(u8, &input, bc.code);
        try std.testing.expectEqual(@intFromPtr(original_atom_ptr), @intFromPtr(bc.atom_operands.ptr));
        try std.testing.expectEqual(original_atom_capacity, bc.atom_operands_capacity);
        try std.testing.expectEqualSlices(core.Atom, &.{core.atom.ids.empty_string}, bc.atom_operands);
        try std.testing.expectEqual(@intFromPtr(original_source_ptr), @intFromPtr(bc.source_loc_slots.ptr));
        try std.testing.expectEqual(original_source_capacity, bc.source_loc_capacity);
        try std.testing.expectEqual(@as(usize, 7), bc.source_loc_slots.len);
        for (bc.source_loc_slots, [_]u32{ 0, 3, 8, 9, 10, 13, 14 }) |slot, pc| {
            try std.testing.expectEqual(pc, slot.pc);
        }

        try pipeline.resolve_labels.run(&ctx);
    } else {
        try std.testing.expect(!failing.has_induced_failure);
    }

    try std.testing.expectEqualSlices(u8, &.{
        op.push_empty_string,
        op.add_loc,
        4,
        op.return_undef,
    }, bc.code);
    try std.testing.expectEqual(@as(usize, 0), bc.atom_operands.len);
    for (bc.source_loc_slots[0..6]) |slot| {
        try std.testing.expectEqual(@as(u32, 0), slot.pc);
    }
    try std.testing.expectEqual(@as(u32, 3), bc.source_loc_slots[6].pc);
    return failed;
}

test "resolve_labels add_loc empty RHS is transactional at every allocation failure" {
    const cleanup_rt = try core.JSRuntime.create(std.testing.allocator);
    defer cleanup_rt.destroy();

    var fail_offset: usize = 0;
    while (try runEmptyAddLocResolveLabelsAllocationFailure(cleanup_rt, fail_offset)) {
        fail_offset += 1;
    }
    // positions, sizes, reachability state/worklist, and exact final code.
    // Removing the only atom operand needs no replacement-ledger allocation.
    try std.testing.expectEqual(@as(usize, 5), fail_offset);
}

test "resolve_labels add_loc fold preserves QuickJS source mapping" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const name = try rt.internAtom("add-loc-source");
    defer rt.atoms.free(name);

    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);
    fd.use_short_opcodes = true;

    var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer bc.deinit(rt);

    const op = bytecode.opcode.op;
    var input = [_]u8{0} ** 15;
    input[0] = op.get_loc;
    std.mem.writeInt(u16, input[1..3], 4, .little);
    input[3] = op.push_i32;
    std.mem.writeInt(i32, input[4..8], 1, .little);
    input[8] = op.add;
    input[9] = op.dup;
    input[10] = op.put_loc;
    std.mem.writeInt(u16, input[11..13], 4, .little);
    input[13] = op.drop;
    input[14] = op.return_undef;
    try bc.setCode(&input);

    try bc.appendSourceLoc(0, 10, 2);
    try bc.appendSourceLoc(3, 11, 3);
    try bc.appendSourceLoc(8, 12, 4);
    try bc.appendSourceLoc(9, 13, 5);
    try bc.appendSourceLoc(10, 14, 6);
    try bc.appendSourceLoc(13, 15, 7);
    try bc.appendSourceLoc(14, 16, 8);

    var ctx = pipeline.resolve_labels.JSContext.initWithFunctionDef(&bc, &fd);
    try pipeline.resolve_labels.run(&ctx);

    try std.testing.expectEqualSlices(u8, &.{
        op.push_1,
        op.add_loc,
        4,
        op.return_undef,
    }, bc.code);
    try std.testing.expectEqual(@as(usize, 7), bc.source_loc_slots.len);
    for (bc.source_loc_slots[0..6]) |slot| {
        try std.testing.expectEqual(@as(u32, 0), slot.pc);
    }
    try std.testing.expectEqual(@as(u32, 3), bc.source_loc_slots[6].pc);
}

test "resolve_labels rejects non-QuickJS add_loc RHS and slot boundaries" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const name = try rt.internAtom("add-loc-negative");
    defer rt.atoms.free(name);
    const tagged_atom = core.atom.atomFromUInt32(123);

    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);
    fd.use_short_opcodes = true;

    var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer bc.deinit(rt);
    _ = try bc.addConstant(core.JSValue.float64(1.5));

    const op = bytecode.opcode.op;
    var input = [_]u8{0} ** 56;
    input[0] = op.get_loc;
    std.mem.writeInt(u16, input[1..3], 4, .little);
    input[3] = op.push_const;
    std.mem.writeInt(u32, input[4..8], 0, .little);
    input[8] = op.add;
    input[9] = op.dup;
    input[10] = op.put_loc;
    std.mem.writeInt(u16, input[11..13], 4, .little);
    input[13] = op.drop;

    input[14] = op.get_loc;
    std.mem.writeInt(u16, input[15..17], 5, .little);
    input[17] = op.push_atom_value;
    std.mem.writeInt(u32, input[18..22], tagged_atom, .little);
    input[22] = op.add;
    input[23] = op.dup;
    input[24] = op.put_loc;
    std.mem.writeInt(u16, input[25..27], 5, .little);
    input[27] = op.drop;

    input[28] = op.get_loc;
    std.mem.writeInt(u16, input[29..31], 256, .little);
    input[31] = op.push_i32;
    std.mem.writeInt(i32, input[32..36], 1, .little);
    input[36] = op.add;
    input[37] = op.dup;
    input[38] = op.put_loc;
    std.mem.writeInt(u16, input[39..41], 256, .little);
    input[41] = op.drop;

    input[42] = op.get_loc;
    std.mem.writeInt(u16, input[43..45], 6, .little);
    input[45] = op.push_i32;
    std.mem.writeInt(i32, input[46..50], 1, .little);
    input[50] = op.add;
    input[51] = op.dup;
    input[52] = op.put_loc;
    std.mem.writeInt(u16, input[53..55], 7, .little);
    input[55] = op.drop;
    try bc.setCode(&input);
    try bc.retainAtomOperand(tagged_atom);

    var ctx = pipeline.resolve_labels.JSContext.initWithFunctionDef(&bc, &fd);
    try pipeline.resolve_labels.run(&ctx);

    var expected = [_]u8{0} ** 31;
    expected[0] = op.get_loc8;
    expected[1] = 4;
    expected[2] = op.push_const8;
    expected[3] = 0;
    expected[4] = op.add;
    expected[5] = op.put_loc8;
    expected[6] = 4;
    expected[7] = op.get_loc8;
    expected[8] = 5;
    expected[9] = op.push_atom_value;
    std.mem.writeInt(u32, expected[10..14], tagged_atom, .little);
    expected[14] = op.add;
    expected[15] = op.put_loc8;
    expected[16] = 5;
    expected[17] = op.get_loc;
    std.mem.writeInt(u16, expected[18..20], 256, .little);
    expected[20] = op.push_1;
    expected[21] = op.add;
    expected[22] = op.put_loc;
    std.mem.writeInt(u16, expected[23..25], 256, .little);
    expected[25] = op.get_loc8;
    expected[26] = 6;
    expected[27] = op.push_1;
    expected[28] = op.add;
    expected[29] = op.put_loc8;
    expected[30] = 7;
    try std.testing.expectEqualSlices(u8, &expected, bc.code);
    try std.testing.expectEqualSlices(core.Atom, &.{tagged_atom}, bc.atom_operands);
}

test "resolve_labels inc_loc folds all canonical local updates and preserves source mapping" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const name = try rt.internAtom("inc-loc-canonical");
    defer rt.atoms.free(name);

    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);
    fd.use_short_opcodes = true;

    const op = bytecode.opcode.op;
    const cases = [_]struct {
        input: []const u8,
        expected_op: u8,
        idx: u8,
        source_pcs: []const u8,
    }{
        .{
            .input = &.{ op.get_loc, 4, 0, op.post_inc, op.put_loc, 4, 0, op.drop, op.return_undef },
            .expected_op = op.inc_loc,
            .idx = 4,
            .source_pcs = &.{ 0, 3, 4, 7, 8 },
        },
        .{
            .input = &.{ op.get_loc, 5, 0, op.post_dec, op.put_loc, 5, 0, op.drop, op.return_undef },
            .expected_op = op.dec_loc,
            .idx = 5,
            .source_pcs = &.{ 0, 3, 4, 7, 8 },
        },
        .{
            .input = &.{ op.get_loc, 6, 0, op.inc, op.dup, op.put_loc, 6, 0, op.drop, op.return_undef },
            .expected_op = op.inc_loc,
            .idx = 6,
            .source_pcs = &.{ 0, 3, 4, 5, 8, 9 },
        },
        .{
            .input = &.{ op.get_loc, 7, 0, op.dec, op.dup, op.put_loc, 7, 0, op.drop, op.return_undef },
            .expected_op = op.dec_loc,
            .idx = 7,
            .source_pcs = &.{ 0, 3, 4, 5, 8, 9 },
        },
    };

    for (cases) |case| {
        var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
        defer bc.deinit(rt);
        try bc.setCode(case.input);
        for (case.source_pcs, 0..) |pc, source_idx| {
            try bc.appendSourceLoc(pc, @intCast(10 + source_idx), 2);
        }

        var ctx = pipeline.resolve_labels.JSContext.initWithFunctionDef(&bc, &fd);
        try pipeline.resolve_labels.run(&ctx);

        try std.testing.expectEqualSlices(u8, &.{ case.expected_op, case.idx, op.return_undef }, bc.code);
        for (bc.source_loc_slots[0 .. bc.source_loc_slots.len - 1]) |slot| {
            try std.testing.expectEqual(@as(u32, 0), slot.pc);
        }
        try std.testing.expectEqual(@as(u32, 2), bc.source_loc_slots[bc.source_loc_slots.len - 1].pc);
    }
}

test "resolve_labels inc_loc keeps non-canonical and guarded boundaries" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const name = try rt.internAtom("inc-loc-boundaries");
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
            // The removed pre-resolve_labels pass used to fold this simplified
            // non-QJS shape.
            .input = &.{ op.get_loc, 4, 0, op.inc, op.put_loc, 4, 0, op.return_undef },
            .expected = &.{ op.get_loc8, 4, op.inc, op.put_loc8, 4, op.return_undef },
        },
        .{
            .input = &.{ op.get_loc, 0, 1, op.post_inc, op.put_loc, 0, 1, op.drop, op.return_undef },
            .expected = &.{ op.get_loc, 0, 1, op.inc, op.put_loc, 0, 1, op.return_undef },
        },
        .{
            .input = &.{ op.get_arg0, op.if_false, 10, 0, 0, 0, op.get_loc, 4, 0, op.post_inc, op.put_loc, 4, 0, op.drop, op.return_undef },
            .expected = &.{ op.get_arg0, op.if_false8, 4, op.get_loc8, 4, op.post_inc, op.put_loc8, 4, op.return_undef },
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

test "resolve_labels folds discarded post update stores" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const name = try rt.internAtom("test");
    const field_atom = try rt.internAtom("field");
    defer rt.atoms.free(name);
    defer rt.atoms.free(field_atom);

    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);
    fd.use_short_opcodes = true;

    var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer bc.deinit(rt);

    const op = bytecode.opcode.op;
    var input = [_]u8{0} ** 25;
    input[0] = op.post_inc;
    input[1] = op.put_arg;
    std.mem.writeInt(u16, input[2..4], 1, .little);
    input[4] = op.drop;
    input[5] = op.post_dec;
    input[6] = op.put_var_ref;
    std.mem.writeInt(u16, input[7..9], 2, .little);
    input[9] = op.drop;
    input[10] = op.get_var_ref;
    std.mem.writeInt(u16, input[11..13], 2, .little);
    input[13] = op.post_inc;
    input[14] = op.perm3;
    input[15] = op.put_field;
    std.mem.writeInt(u32, input[16..20], field_atom, .little);
    input[20] = op.drop;
    input[21] = op.post_dec;
    input[22] = op.perm4;
    input[23] = op.put_array_el;
    input[24] = op.drop;
    try bc.setCode(&input);
    try bc.retainAtomOperand(field_atom);

    var ctx = pipeline.resolve_labels.JSContext.initWithFunctionDef(&bc, &fd);
    try pipeline.resolve_labels.run(&ctx);

    var expected = [_]u8{0} ** 12;
    expected[0] = op.inc;
    expected[1] = op.put_arg1;
    expected[2] = op.dec;
    expected[3] = op.set_var_ref2;
    expected[4] = op.inc;
    expected[5] = op.put_field;
    std.mem.writeInt(u32, expected[6..10], field_atom, .little);
    expected[10] = op.dec;
    expected[11] = op.put_array_el;
    try std.testing.expectEqualSlices(u8, &expected, bc.code);
    try std.testing.expectEqualSlices(core.Atom, &.{field_atom}, bc.atom_operands);
}

test "resolve_variables logical fold skips line markers and preserves adjacent atom ownership" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const name = try rt.internAtom("logical-phase-owner");
    const retained_atom = try rt.internAtom("logical-adjacent-atom");
    defer rt.atoms.free(name);
    defer rt.atoms.free(retained_atom);
    const base_ref_count = rt.atoms.refCount(retained_atom).?;

    var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer bc.deinit(rt);

    const op = bytecode.opcode.op;
    var input = [_]u8{0} ** 33;
    input[0] = op.dup;
    input[1] = op.line_num;
    std.mem.writeInt(u32, input[2..6], 10, .little);
    input[6] = op.if_false;
    std.mem.writeInt(u32, input[7..11], 22, .little);
    input[11] = op.line_num;
    std.mem.writeInt(u32, input[12..16], 11, .little);
    input[16] = op.drop;
    input[17] = op.push_atom_value;
    std.mem.writeInt(u32, input[18..22], retained_atom, .little);
    input[22] = op.label;
    input[27] = op.if_false;
    std.mem.writeInt(u32, input[28..32], 32, .little);
    input[32] = op.return_undef;
    try bc.setCode(&input);
    try bc.retainAtomOperand(retained_atom);
    try bc.appendSourceLoc(0, 10, 1);
    try bc.appendSourceLoc(6, 11, 2);
    try bc.appendSourceLoc(16, 12, 3);
    try bc.appendSourceLoc(17, 13, 4);
    try bc.appendSourceLoc(27, 14, 5);
    try bc.appendSourceLoc(32, 15, 6);

    var ctx = pipeline.resolve_variables.JSContext.init(&bc);
    try pipeline.resolve_variables.run(&ctx);

    var expected = [_]u8{0} ** 21;
    expected[0] = op.if_false;
    std.mem.writeInt(u32, expected[1..5], 20, .little);
    expected[5] = op.push_atom_value;
    std.mem.writeInt(u32, expected[6..10], retained_atom, .little);
    expected[10] = op.label;
    expected[15] = op.if_false;
    std.mem.writeInt(u32, expected[16..20], 20, .little);
    expected[20] = op.return_undef;
    try std.testing.expectEqualSlices(u8, &expected, bc.code);
    try std.testing.expectEqualSlices(core.Atom, &.{retained_atom}, bc.atom_operands);
    try std.testing.expectEqual(base_ref_count + 1, rt.atoms.refCount(retained_atom).?);

    const expected_source_pcs = [_]u32{ 0, 5, 5, 5, 15, 20 };
    try std.testing.expectEqual(expected_source_pcs.len, bc.source_loc_slots.len);
    for (expected_source_pcs, bc.source_loc_slots) |expected_pc, slot| {
        try std.testing.expectEqual(expected_pc, slot.pc);
    }
}

test "resolve_variables logical target follows labels and goto" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const name = try rt.internAtom("logical-label-goto");
    defer rt.atoms.free(name);

    var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer bc.deinit(rt);

    const op = bytecode.opcode.op;
    var input = [_]u8{0} ** 31;
    input[0] = op.dup;
    input[1] = op.if_false;
    std.mem.writeInt(u32, input[2..6], 10, .little);
    input[6] = op.drop;
    input[7] = op.get_loc;
    input[10] = op.label;
    input[15] = op.goto;
    std.mem.writeInt(u32, input[16..20], 20, .little);
    input[20] = op.label;
    input[25] = op.if_false;
    std.mem.writeInt(u32, input[26..30], 30, .little);
    input[30] = op.return_undef;
    try bc.setCode(&input);

    var ctx = pipeline.resolve_variables.JSContext.init(&bc);
    try pipeline.resolve_variables.run(&ctx);

    try std.testing.expectEqual(op.if_false, bc.code[0]);
    const target = std.mem.readInt(u32, bc.code[1..5], .little);
    try std.testing.expect(target < bc.code.len);
    try std.testing.expectEqual(op.return_undef, bc.code[target]);
}

test "resolve_labels no longer owns logical-chain folding" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const name = try rt.internAtom("logical-phase3-negative");
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

    try std.testing.expectEqual(op.dup, bc.code[0]);
    try std.testing.expectEqual(op.drop, bc.code[3]);
}

test "resolve_variables owns logical-chain folding with final source mapping" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const name = try rt.internAtom("test");
    defer rt.atoms.free(name);

    const op = bytecode.opcode.op;
    for ([_]u8{ op.if_false, op.if_true }) |branch_op| {
        var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
        defer fd.deinit(rt);
        fd.use_short_opcodes = true;

        var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
        defer bc.deinit(rt);

        // dup branch L1 drop; value; L1: dup branch L2 drop; value;
        // L2: branch END; END: return_undef
        var input = [_]u8{0} ** 26;
        input[0] = op.dup;
        input[1] = branch_op;
        std.mem.writeInt(u32, input[2..6], 10, .little);
        input[6] = op.drop;
        input[7] = op.get_loc;
        std.mem.writeInt(u16, input[8..10], 0, .little);
        input[10] = op.dup;
        input[11] = branch_op;
        std.mem.writeInt(u32, input[12..16], 20, .little);
        input[16] = op.drop;
        input[17] = op.get_loc;
        std.mem.writeInt(u16, input[18..20], 1, .little);
        input[20] = branch_op;
        std.mem.writeInt(u32, input[21..25], 25, .little);
        input[25] = op.return_undef;
        try bc.setCode(&input);
        try bc.appendSourceLoc(0, 10, 2);
        try bc.appendSourceLoc(7, 11, 3);
        try bc.appendSourceLoc(25, 12, 4);

        var variables_ctx = pipeline.resolve_variables.JSContext.initWithFunctionDef(&bc, &fd);
        try pipeline.resolve_variables.run(&variables_ctx);

        var phase2_expected = [_]u8{0} ** 22;
        phase2_expected[0] = branch_op;
        std.mem.writeInt(u32, phase2_expected[1..5], 21, .little);
        phase2_expected[5] = op.get_loc;
        std.mem.writeInt(u16, phase2_expected[6..8], 0, .little);
        phase2_expected[8] = branch_op;
        std.mem.writeInt(u32, phase2_expected[9..13], 21, .little);
        phase2_expected[13] = op.get_loc;
        std.mem.writeInt(u16, phase2_expected[14..16], 1, .little);
        phase2_expected[16] = branch_op;
        std.mem.writeInt(u32, phase2_expected[17..21], 21, .little);
        phase2_expected[21] = op.return_undef;
        try std.testing.expectEqualSlices(u8, &phase2_expected, bc.code);
        try std.testing.expectEqual(@as(u32, 0), bc.source_loc_slots[0].pc);
        try std.testing.expectEqual(@as(u32, 5), bc.source_loc_slots[1].pc);
        try std.testing.expectEqual(@as(u32, 21), bc.source_loc_slots[2].pc);

        var labels_ctx = pipeline.resolve_labels.JSContext.initWithFunctionDef(&bc, &fd);
        try pipeline.resolve_labels.run(&labels_ctx);

        const short_branch = if (branch_op == op.if_false) op.if_false8 else op.if_true8;
        try std.testing.expectEqualSlices(u8, &.{
            short_branch,
            6,
            op.get_loc0,
            short_branch,
            3,
            op.get_loc1,
            op.drop,
            op.return_undef,
        }, bc.code);
        try std.testing.expectEqual(@as(u32, 0), bc.source_loc_slots[0].pc);
        try std.testing.expectEqual(@as(u32, 2), bc.source_loc_slots[1].pc);
        try std.testing.expectEqual(@as(u32, 7), bc.source_loc_slots[2].pc);
    }
}

test "resolve_variables collapses logical chains deeper than the old fixed limit" {
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
    const prefix_count = 33;
    const final_branch_pc = prefix_count * 10;
    var input = [_]u8{0} ** (final_branch_pc + 6);
    for (0..prefix_count) |index| {
        const pc = index * 10;
        input[pc] = op.dup;
        input[pc + 1] = op.if_false;
        std.mem.writeInt(u32, input[pc + 2 ..][0..4], @intCast(pc + 10), .little);
        input[pc + 6] = op.drop;
        input[pc + 7] = op.get_loc;
    }
    input[final_branch_pc] = op.if_false;
    std.mem.writeInt(u32, input[final_branch_pc + 1 ..][0..4], @intCast(final_branch_pc + 5), .little);
    input[final_branch_pc + 5] = op.return_undef;
    try bc.setCode(&input);

    var variables_ctx = pipeline.resolve_variables.JSContext.initWithFunctionDef(&bc, &fd);
    try pipeline.resolve_variables.run(&variables_ctx);

    var phase2_pc: usize = 0;
    while (phase2_pc < bc.code.len) {
        try std.testing.expect(bc.code[phase2_pc] != op.dup and bc.code[phase2_pc] != op.drop);
        const size = bytecode.opcode.sizeOf(bc.code[phase2_pc]);
        try std.testing.expect(size != 0);
        phase2_pc += size;
    }

    var labels_ctx = pipeline.resolve_labels.JSContext.initWithFunctionDef(&bc, &fd);
    try pipeline.resolve_labels.run(&labels_ctx);

    const final_output_branch_pc = prefix_count * 3;
    const return_pc = final_output_branch_pc + 1;
    try std.testing.expectEqual(return_pc + 1, bc.code.len);
    for (0..prefix_count) |index| {
        const pc = index * 3;
        try std.testing.expectEqual(op.if_false8, bc.code[pc]);
        try std.testing.expectEqual(
            @as(i8, @intCast(return_pc - (pc + 1))),
            @as(i8, @bitCast(bc.code[pc + 1])),
        );
        try std.testing.expectEqual(op.get_loc0, bc.code[pc + 2]);
    }
    try std.testing.expectEqual(op.drop, bc.code[final_output_branch_pc]);
    try std.testing.expectEqual(op.return_undef, bc.code[return_pc]);
}

test "resolve_variables preserves logical prefix with an interior jump target" {
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
    var input = [_]u8{0} ** 21;
    input[0] = op.if_true;
    std.mem.writeInt(u32, input[1..5], 6, .little);
    input[5] = op.dup;
    input[6] = op.if_false;
    std.mem.writeInt(u32, input[7..11], 15, .little);
    input[11] = op.drop;
    input[12] = op.get_loc;
    input[15] = op.if_false;
    std.mem.writeInt(u32, input[16..20], 20, .little);
    input[20] = op.return_undef;
    try bc.setCode(&input);

    var variables_ctx = pipeline.resolve_variables.JSContext.initWithFunctionDef(&bc, &fd);
    try pipeline.resolve_variables.run(&variables_ctx);
    try std.testing.expectEqualSlices(u8, &input, bc.code);

    var labels_ctx = pipeline.resolve_labels.JSContext.initWithFunctionDef(&bc, &fd);
    try pipeline.resolve_labels.run(&labels_ctx);

    try std.testing.expectEqual(@as(usize, 9), bc.code.len);
    try std.testing.expectEqual(op.dup, bc.code[2]);
    try std.testing.expectEqual(op.drop, bc.code[7]);
    try std.testing.expectEqual(op.return_undef, bc.code[8]);
}

fn runLogicalPhaseOwnerAllocationFailure(
    cleanup_rt: *core.JSRuntime,
    fail_offset: usize,
) !bool {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var account = core.memory.MemoryAccount.init(failing.allocator());
    var atoms = core.atom.AtomTable.init(&account);
    defer atoms.deinit();

    const retained_atom = try atoms.internString("logical-phase-owner-oom");
    defer atoms.free(retained_atom);
    const base_ref_count = atoms.refCount(retained_atom).?;

    var bc = bytecode.Bytecode.init(&account, &atoms, core.atom.ids.empty_string);
    defer bc.deinit(cleanup_rt);

    const op = bytecode.opcode.op;
    var input = [_]u8{0} ** 18;
    input[0] = op.dup;
    input[1] = op.if_false;
    std.mem.writeInt(u32, input[2..6], 12, .little);
    input[6] = op.drop;
    input[7] = op.push_atom_value;
    std.mem.writeInt(u32, input[8..12], retained_atom, .little);
    input[12] = op.if_false;
    std.mem.writeInt(u32, input[13..17], 17, .little);
    input[17] = op.return_undef;
    try bc.setCode(&input);
    try bc.retainAtomOperand(retained_atom);
    try bc.appendSourceLoc(0, 10, 1);
    try bc.appendSourceLoc(1, 11, 2);
    try bc.appendSourceLoc(6, 12, 3);
    try bc.appendSourceLoc(7, 13, 4);
    try bc.appendSourceLoc(12, 14, 5);
    try bc.appendSourceLoc(17, 15, 6);

    const original_code_ptr = bc.code.ptr;
    const original_code_capacity = bc.code_capacity;
    const original_atom_ptr = bc.atom_operands.ptr;
    const original_atom_capacity = bc.atom_operands_capacity;
    const original_source_ptr = bc.source_loc_slots.ptr;
    const original_source_capacity = bc.source_loc_capacity;
    const original_atom_refs = atoms.refCount(retained_atom).?;

    failing.fail_index = failing.alloc_index + fail_offset;
    var ctx = pipeline.resolve_variables.JSContext.init(&bc);
    const first_result = pipeline.resolve_variables.run(&ctx);
    const failed = if (first_result) |_| false else |err| switch (err) {
        error.OutOfMemory => true,
        else => return err,
    };
    failing.fail_index = std.math.maxInt(usize);

    if (failed) {
        try std.testing.expect(failing.has_induced_failure);
        try std.testing.expectEqual(@intFromPtr(original_code_ptr), @intFromPtr(bc.code.ptr));
        try std.testing.expectEqual(original_code_capacity, bc.code_capacity);
        try std.testing.expectEqualSlices(u8, &input, bc.code);
        try std.testing.expectEqual(@intFromPtr(original_atom_ptr), @intFromPtr(bc.atom_operands.ptr));
        try std.testing.expectEqual(original_atom_capacity, bc.atom_operands_capacity);
        try std.testing.expectEqualSlices(core.Atom, &.{retained_atom}, bc.atom_operands);
        try std.testing.expectEqual(@intFromPtr(original_source_ptr), @intFromPtr(bc.source_loc_slots.ptr));
        try std.testing.expectEqual(original_source_capacity, bc.source_loc_capacity);
        try std.testing.expectEqual(original_atom_refs, atoms.refCount(retained_atom).?);
        try pipeline.resolve_variables.run(&ctx);
    } else {
        try std.testing.expect(!failing.has_induced_failure);
    }

    var expected = [_]u8{0} ** 16;
    expected[0] = op.if_false;
    std.mem.writeInt(u32, expected[1..5], 15, .little);
    expected[5] = op.push_atom_value;
    std.mem.writeInt(u32, expected[6..10], retained_atom, .little);
    expected[10] = op.if_false;
    std.mem.writeInt(u32, expected[11..15], 15, .little);
    expected[15] = op.return_undef;
    try std.testing.expectEqualSlices(u8, &expected, bc.code);
    try std.testing.expectEqualSlices(core.Atom, &.{retained_atom}, bc.atom_operands);
    try std.testing.expectEqual(base_ref_count + 1, atoms.refCount(retained_atom).?);
    const expected_source_pcs = [_]u32{ 0, 5, 5, 5, 10, 15 };
    for (expected_source_pcs, bc.source_loc_slots) |expected_pc, slot| {
        try std.testing.expectEqual(expected_pc, slot.pc);
    }
    return failed;
}

test "resolve_variables logical fold is transactional across every post-bind allocation failure" {
    const cleanup_rt = try core.JSRuntime.create(std.testing.allocator);
    defer cleanup_rt.destroy();

    var fail_offset: usize = 0;
    while (try runLogicalPhaseOwnerAllocationFailure(cleanup_rt, fail_offset)) {
        fail_offset += 1;
    }
    try std.testing.expect(fail_offset >= 8);
}

fn runTaggedLogicalPhaseOwnerAllocationFailure(
    cleanup_rt: *core.JSRuntime,
    fail_offset: usize,
) !bool {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var account = core.memory.MemoryAccount.init(failing.allocator());
    var atoms = core.atom.AtomTable.init(&account);
    defer atoms.deinit();

    const retained_atom = try atoms.internString("logical-tagged-label-oom");
    defer atoms.free(retained_atom);
    const base_ref_count = atoms.refCount(retained_atom).?;

    var bc = bytecode.Bytecode.init(&account, &atoms, core.atom.ids.empty_string);
    defer bc.deinit(cleanup_rt);

    const op = bytecode.opcode.op;
    const tagged_target = op.parser_label_tag | 1;
    var input = [_]u8{0} ** 23;
    input[0] = op.dup;
    input[1] = op.if_false;
    std.mem.writeInt(u32, input[2..6], tagged_target, .little);
    input[6] = op.drop;
    input[7] = op.push_atom_value;
    std.mem.writeInt(u32, input[8..12], retained_atom, .little);
    input[12] = op.label;
    std.mem.writeInt(u32, input[13..17], 1, .little);
    input[17] = op.if_false;
    std.mem.writeInt(u32, input[18..22], 22, .little);
    input[22] = op.return_undef;
    try bc.setCode(&input);
    try bc.retainAtomOperand(retained_atom);
    try bc.appendSourceLoc(0, 10, 1);
    try bc.appendSourceLoc(1, 11, 2);
    try bc.appendSourceLoc(6, 12, 3);
    try bc.appendSourceLoc(7, 13, 4);
    try bc.appendSourceLoc(17, 14, 5);
    try bc.appendSourceLoc(22, 15, 6);

    const original_code_ptr = bc.code.ptr;
    const original_code_capacity = bc.code_capacity;
    const original_atom_ptr = bc.atom_operands.ptr;
    const original_atom_capacity = bc.atom_operands_capacity;
    const original_source_ptr = bc.source_loc_slots.ptr;
    const original_source_capacity = bc.source_loc_capacity;
    const original_atom_refs = atoms.refCount(retained_atom).?;

    failing.fail_index = failing.alloc_index + fail_offset;
    var ctx = pipeline.resolve_variables.JSContext.init(&bc);
    const first_result = pipeline.resolve_variables.run(&ctx);
    const failed = if (first_result) |_| false else |err| switch (err) {
        error.OutOfMemory => true,
        else => return err,
    };
    failing.fail_index = std.math.maxInt(usize);

    if (failed) {
        try std.testing.expect(failing.has_induced_failure);
        try std.testing.expectEqual(@intFromPtr(original_code_ptr), @intFromPtr(bc.code.ptr));
        try std.testing.expectEqual(original_code_capacity, bc.code_capacity);
        const target_after_failure = std.mem.readInt(u32, bc.code[2..6], .little);
        try std.testing.expect(target_after_failure == tagged_target or target_after_failure == 12);
        try std.testing.expectEqual(@intFromPtr(original_atom_ptr), @intFromPtr(bc.atom_operands.ptr));
        try std.testing.expectEqual(original_atom_capacity, bc.atom_operands_capacity);
        try std.testing.expectEqualSlices(core.Atom, &.{retained_atom}, bc.atom_operands);
        try std.testing.expectEqual(@intFromPtr(original_source_ptr), @intFromPtr(bc.source_loc_slots.ptr));
        try std.testing.expectEqual(original_source_capacity, bc.source_loc_capacity);
        try std.testing.expectEqual(original_atom_refs, atoms.refCount(retained_atom).?);
        try pipeline.resolve_variables.run(&ctx);
    } else {
        try std.testing.expect(!failing.has_induced_failure);
    }

    var expected = [_]u8{0} ** 21;
    expected[0] = op.if_false;
    std.mem.writeInt(u32, expected[1..5], 20, .little);
    expected[5] = op.push_atom_value;
    std.mem.writeInt(u32, expected[6..10], retained_atom, .little);
    expected[10] = op.label;
    std.mem.writeInt(u32, expected[11..15], 1, .little);
    expected[15] = op.if_false;
    std.mem.writeInt(u32, expected[16..20], 20, .little);
    expected[20] = op.return_undef;
    try std.testing.expectEqualSlices(u8, &expected, bc.code);
    try std.testing.expectEqualSlices(core.Atom, &.{retained_atom}, bc.atom_operands);
    try std.testing.expectEqual(base_ref_count + 1, atoms.refCount(retained_atom).?);
    const expected_source_pcs = [_]u32{ 0, 5, 5, 5, 15, 20 };
    for (expected_source_pcs, bc.source_loc_slots) |expected_pc, slot| {
        try std.testing.expectEqual(expected_pc, slot.pc);
    }
    return failed;
}

test "resolve_variables tagged logical labels are leak-free and retryable across every allocation failure" {
    const cleanup_rt = try core.JSRuntime.create(std.testing.allocator);
    defer cleanup_rt.destroy();

    var fail_offset: usize = 0;
    while (try runTaggedLogicalPhaseOwnerAllocationFailure(cleanup_rt, fail_offset)) {
        fail_offset += 1;
    }
    try std.testing.expect(fail_offset >= 9);
}

test "resolve_labels null comparison strict_eq folds both constants with QuickJS source mapping" {
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
    };

    for (cases) |case| {
        var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
        defer bc.deinit(rt);
        try bc.setCode(case.input);
        try bc.appendSourceLoc(1, 10, 2);
        try bc.appendSourceLoc(2, 11, 3);
        try bc.appendSourceLoc(3, 12, 4);

        var ctx = pipeline.resolve_labels.JSContext.initWithFunctionDef(&bc, &fd);
        try pipeline.resolve_labels.run(&ctx);
        try std.testing.expectEqualSlices(u8, case.expected, bc.code);
        try std.testing.expectEqual(@as(u32, 1), bc.source_loc_slots[0].pc);
        try std.testing.expectEqual(@as(u32, 1), bc.source_loc_slots[1].pc);
        try std.testing.expectEqual(@as(u32, 2), bc.source_loc_slots[2].pc);
    }
}

test "resolve_labels folds undefined return" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const name = try rt.internAtom("test");
    defer rt.atoms.free(name);

    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);
    fd.use_short_opcodes = true;

    const op = bytecode.opcode.op;
    {
        var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
        defer bc.deinit(rt);
        try bc.setCode(&.{ op.undefined, op.@"return" });
        try bc.appendSourceLoc(0, 10, 2);
        try bc.appendSourceLoc(1, 11, 3);

        var ctx = pipeline.resolve_labels.JSContext.initWithFunctionDef(&bc, &fd);
        try pipeline.resolve_labels.run(&ctx);
        try std.testing.expectEqualSlices(u8, &.{op.return_undef}, bc.code);
        try std.testing.expectEqual(@as(u32, 0), bc.source_loc_slots[0].pc);
        try std.testing.expectEqual(@as(u32, 0), bc.source_loc_slots[1].pc);
    }

    {
        var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
        defer bc.deinit(rt);
        const input = [_]u8{ op.get_arg0, op.if_false, 7, 0, 0, 0, op.undefined, op.@"return" };
        try bc.setCode(&input);
        try bc.appendSourceLoc(6, 20, 2);
        try bc.appendSourceLoc(7, 21, 3);

        var ctx = pipeline.resolve_labels.JSContext.initWithFunctionDef(&bc, &fd);
        try pipeline.resolve_labels.run(&ctx);
        try std.testing.expectEqualSlices(u8, &.{ op.get_arg0, op.if_false8, 2, op.undefined, op.@"return" }, bc.code);
        try std.testing.expectEqual(@as(u32, 3), bc.source_loc_slots[0].pc);
        try std.testing.expectEqual(@as(u32, 4), bc.source_loc_slots[1].pc);
    }
}

test "resolve_labels undefined discard preserves QuickJS source and entry boundaries" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const name = try rt.internAtom("undefined-discard");
    defer rt.atoms.free(name);

    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);
    fd.use_short_opcodes = true;

    const op = bytecode.opcode.op;
    {
        var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
        defer bc.deinit(rt);
        try bc.setCode(&.{ op.undefined, op.drop, op.nop, op.return_undef });
        try bc.appendSourceLoc(0, 10, 2);
        try bc.appendSourceLoc(1, 11, 3);
        try bc.appendSourceLoc(2, 12, 4);
        try bc.appendSourceLoc(4, 13, 5);

        var ctx = pipeline.resolve_labels.JSContext.initWithFunctionDef(&bc, &fd);
        try pipeline.resolve_labels.run(&ctx);

        try std.testing.expectEqualSlices(u8, &.{ op.nop, op.return_undef }, bc.code);
        try std.testing.expectEqual(@as(usize, 3), bc.source_loc_slots.len);
        for (bc.source_loc_slots) |slot| {
            try std.testing.expectEqual(@as(u32, 0), slot.pc);
        }
    }

    {
        var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
        defer bc.deinit(rt);
        var input = [_]u8{
            op.get_arg0,
            op.if_false,
            0,
            0,
            0,
            0,
            op.undefined,
            op.drop,
            op.return_undef,
        };
        std.mem.writeInt(u32, input[2..6], 7, .little);
        try bc.setCode(&input);
        try bc.appendSourceLoc(6, 20, 2);
        try bc.appendSourceLoc(7, 21, 3);

        var ctx = pipeline.resolve_labels.JSContext.initWithFunctionDef(&bc, &fd);
        try pipeline.resolve_labels.run(&ctx);

        try std.testing.expectEqualSlices(
            u8,
            &.{ op.get_arg0, op.if_false8, 2, op.undefined, op.return_undef },
            bc.code,
        );
        try std.testing.expectEqual(@as(u32, 3), bc.source_loc_slots[0].pc);
        try std.testing.expectEqual(@as(u32, 4), bc.source_loc_slots[1].pc);
    }
}

test "resolve_labels null comparison strict_neq branches invert both directions with QuickJS source mapping" {
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
    const branches = [_]struct { input: u8, expected: u8 }{
        .{ .input = op.if_false, .expected = op.if_true8 },
        .{ .input = op.if_true, .expected = op.if_false8 },
    };
    for (nullish_ops) |nullish| {
        for (branches) |branch| {
            var input = [_]u8{0} ** 9;
            input[0] = op.get_loc0;
            input[1] = nullish.push;
            input[2] = op.strict_neq;
            input[3] = branch.input;
            std.mem.writeInt(u32, input[4..8], 8, .little);
            input[8] = op.return_undef;

            var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
            defer bc.deinit(rt);
            try bc.setCode(&input);
            try bc.appendSourceLoc(1, 10, 2);
            try bc.appendSourceLoc(2, 11, 3);
            try bc.appendSourceLoc(3, 12, 4);
            try bc.appendSourceLoc(8, 13, 5);

            var ctx = pipeline.resolve_labels.JSContext.initWithFunctionDef(&bc, &fd);
            try pipeline.resolve_labels.run(&ctx);
            try std.testing.expectEqualSlices(u8, &.{
                op.get_loc0,
                nullish.test_op,
                branch.expected,
                1,
                op.return_undef,
            }, bc.code);
            try std.testing.expectEqual(@as(u32, 1), bc.source_loc_slots[0].pc);
            try std.testing.expectEqual(@as(u32, 1), bc.source_loc_slots[1].pc);
            try std.testing.expectEqual(@as(u32, 1), bc.source_loc_slots[2].pc);
            try std.testing.expectEqual(@as(u32, 4), bc.source_loc_slots[3].pc);
        }
    }
}

test "resolve_labels null comparison does not fold loose equality" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const name = try rt.internAtom("test");
    defer rt.atoms.free(name);

    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);
    fd.use_short_opcodes = true;

    const op = bytecode.opcode.op;
    const cases = [_][]const u8{
        &.{ op.get_loc0, op.null, op.eq, op.@"return" },
        &.{ op.get_loc0, op.undefined, op.neq, op.@"return" },
    };
    for (cases) |input| {
        var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
        defer bc.deinit(rt);
        try bc.setCode(input);

        var ctx = pipeline.resolve_labels.JSContext.initWithFunctionDef(&bc, &fd);
        try pipeline.resolve_labels.run(&ctx);
        try std.testing.expectEqualSlices(u8, input, bc.code);
    }
}

test "resolve_labels null comparison respects the minimal jump-entry boundary" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const name = try rt.internAtom("test");
    defer rt.atoms.free(name);

    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);
    fd.use_short_opcodes = true;

    const op = bytecode.opcode.op;
    const cases = [_]struct {
        target: u32,
        expected: []const u8,
    }{
        .{
            .target = 10,
            .expected = &.{ op.get_arg0, op.if_false8, 3, op.get_loc0, op.null, op.strict_eq, op.@"return" },
        },
        .{
            .target = 9,
            .expected = &.{ op.get_arg0, op.if_false8, 2, op.get_loc0, op.is_null, op.@"return" },
        },
    };
    for (cases) |case| {
        var input = [_]u8{0} ** 12;
        input[0] = op.get_arg;
        std.mem.writeInt(u16, input[1..3], 0, .little);
        input[3] = op.if_false;
        std.mem.writeInt(u32, input[4..8], case.target, .little);
        input[8] = op.get_loc0;
        input[9] = op.null;
        input[10] = op.strict_eq;
        input[11] = op.@"return";

        var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
        defer bc.deinit(rt);
        try bc.setCode(&input);

        var ctx = pipeline.resolve_labels.JSContext.initWithFunctionDef(&bc, &fd);
        try pipeline.resolve_labels.run(&ctx);
        try std.testing.expectEqualSlices(u8, case.expected, bc.code);
    }
}

test "resolve_labels typeof equality source follows the consumed compare" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const name = try rt.internAtom("test");
    defer rt.atoms.free(name);

    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);
    fd.use_short_opcodes = true;

    const op = bytecode.opcode.op;
    const cases = [_]struct {
        atom_name: []const u8,
        compare_op: u8,
        test_op: u8,
    }{
        .{ .atom_name = "undefined", .compare_op = op.strict_eq, .test_op = op.typeof_is_undefined },
        .{ .atom_name = "function", .compare_op = op.eq, .test_op = op.typeof_is_function },
    };
    for (cases) |case| {
        const type_atom = try rt.internAtom(case.atom_name);
        defer rt.atoms.free(type_atom);

        var input = [_]u8{0} ** 8;
        input[0] = op.typeof;
        input[1] = op.push_atom_value;
        std.mem.writeInt(u32, input[2..6], type_atom, .little);
        input[6] = case.compare_op;
        input[7] = op.@"return";

        var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
        defer bc.deinit(rt);
        try bc.setCode(&input);
        try bc.retainAtomOperand(type_atom);
        try bc.appendSourceLoc(0, 10, 1);
        try bc.appendSourceLoc(6, 11, 2);
        try bc.appendSourceLoc(7, 12, 3);

        var ctx = pipeline.resolve_labels.JSContext.initWithFunctionDef(&bc, &fd);
        try pipeline.resolve_labels.run(&ctx);

        try std.testing.expectEqualSlices(u8, &.{ case.test_op, op.@"return" }, bc.code);
        try std.testing.expectEqual(@as(usize, 0), bc.atom_operands.len);
        try std.testing.expectEqual(@as(u32, 0), bc.source_loc_slots[0].pc);
        try std.testing.expectEqual(@as(u32, 0), bc.source_loc_slots[1].pc);
        try std.testing.expectEqual(@as(u32, 1), bc.source_loc_slots[2].pc);
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
    var input = [_]u8{0} ** 16;
    input[0] = op.push_atom_value;
    std.mem.writeInt(u32, input[1..5], keep_atom, .little);
    input[5] = op.plus;
    input[6] = op.drop;
    input[7] = op.get_loc0;
    input[8] = op.typeof;
    input[9] = op.push_atom_value;
    std.mem.writeInt(u32, input[10..14], type_atom, .little);
    input[14] = op.strict_eq;
    input[15] = op.@"return";

    var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer bc.deinit(rt);
    try bc.setCode(&input);
    try bc.retainAtomOperand(keep_atom);
    try bc.retainAtomOperand(type_atom);

    var ctx = pipeline.resolve_labels.JSContext.initWithFunctionDef(&bc, &fd);
    try pipeline.resolve_labels.run(&ctx);

    var expected = [_]u8{0} ** 10;
    expected[0] = op.push_atom_value;
    std.mem.writeInt(u32, expected[1..5], keep_atom, .little);
    expected[5] = op.plus;
    expected[6] = op.drop;
    expected[7] = op.get_loc0;
    expected[8] = op.typeof_is_undefined;
    expected[9] = op.@"return";
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

test "resolve_labels removes atom-bearing dead code after return_async" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const name = try rt.internAtom("async-dead-tail");
    defer rt.atoms.free(name);
    const dead_atom = try rt.internAtom("async-dead-operand");
    defer rt.atoms.free(dead_atom);
    const base_ref_count = rt.atoms.refCount(dead_atom).?;

    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);
    fd.use_short_opcodes = true;

    const op = bytecode.opcode.op;
    var input = [_]u8{0} ** 9;
    input[0] = op.get_loc0;
    input[1] = op.return_async;
    input[2] = op.push_atom_value;
    std.mem.writeInt(u32, input[3..7], dead_atom, .little);
    input[7] = op.drop;
    input[8] = op.return_undef;

    var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer bc.deinit(rt);
    try bc.setCode(&input);
    try bc.retainAtomOperand(dead_atom);
    try bc.appendSourceLoc(1, 10, 2);
    try bc.appendSourceLoc(2, 11, 3);
    try bc.appendSourceLoc(8, 12, 4);

    var ctx = pipeline.resolve_labels.JSContext.initWithFunctionDef(&bc, &fd);
    try pipeline.resolve_labels.run(&ctx);

    try std.testing.expectEqualSlices(u8, &.{ op.get_loc0, op.return_async }, bc.code);
    try std.testing.expectEqual(@as(usize, 0), bc.atom_operands.len);
    try std.testing.expectEqual(base_ref_count, rt.atoms.refCount(dead_atom).?);
    try std.testing.expectEqual(@as(usize, 1), bc.source_loc_slots.len);
    try std.testing.expectEqual(@as(u32, 1), bc.source_loc_slots[0].pc);
}

test "resolve_labels folds typeof inequality branches with branch source and target" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const name = try rt.internAtom("test");
    defer rt.atoms.free(name);

    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);
    fd.use_short_opcodes = true;

    const op = bytecode.opcode.op;
    const cases = [_]struct {
        atom_name: []const u8,
        compare_op: u8,
        test_op: u8,
    }{
        .{ .atom_name = "function", .compare_op = op.neq, .test_op = op.typeof_is_function },
        .{ .atom_name = "undefined", .compare_op = op.strict_neq, .test_op = op.typeof_is_undefined },
    };
    for (cases) |case| {
        const type_atom = try rt.internAtom(case.atom_name);
        defer rt.atoms.free(type_atom);

        var input = [_]u8{0} ** 14;
        input[0] = op.get_loc0;
        input[1] = op.typeof;
        input[2] = op.push_atom_value;
        std.mem.writeInt(u32, input[3..7], type_atom, .little);
        input[7] = case.compare_op;
        input[8] = op.if_false;
        std.mem.writeInt(u32, input[9..13], 13, .little);
        input[13] = op.return_undef;

        var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
        defer bc.deinit(rt);
        try bc.setCode(&input);
        try bc.retainAtomOperand(type_atom);
        try bc.appendSourceLoc(1, 10, 1);
        try bc.appendSourceLoc(7, 11, 2);
        try bc.appendSourceLoc(8, 12, 3);
        try bc.appendSourceLoc(13, 13, 4);

        var ctx = pipeline.resolve_labels.JSContext.initWithFunctionDef(&bc, &fd);
        try pipeline.resolve_labels.run(&ctx);

        try std.testing.expectEqualSlices(u8, &.{
            op.get_loc0,
            case.test_op,
            op.if_true8,
            1,
            op.return_undef,
        }, bc.code);
        try std.testing.expectEqual(@as(usize, 0), bc.atom_operands.len);
        try std.testing.expectEqual(@as(u32, 1), bc.source_loc_slots[0].pc);
        try std.testing.expectEqual(@as(u32, 1), bc.source_loc_slots[1].pc);
        try std.testing.expectEqual(@as(u32, 1), bc.source_loc_slots[2].pc);
        try std.testing.expectEqual(@as(u32, 4), bc.source_loc_slots[3].pc);
    }
}

test "resolve_labels keeps typeof neq unfused before branch-to-next normalization" {
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
    var input = [_]u8{0} ** 13;
    input[0] = op.typeof;
    input[1] = op.push_atom_value;
    std.mem.writeInt(u32, input[2..6], function_atom, .little);
    input[6] = op.neq;
    input[7] = op.if_true;
    std.mem.writeInt(u32, input[8..12], 12, .little);
    input[12] = op.return_undef;

    var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer bc.deinit(rt);
    try bc.setCode(&input);
    try bc.retainAtomOperand(function_atom);

    var ctx = pipeline.resolve_labels.JSContext.initWithFunctionDef(&bc, &fd);
    try pipeline.resolve_labels.run(&ctx);

    var expected = [_]u8{0} ** 9;
    expected[0] = op.typeof;
    expected[1] = op.push_atom_value;
    std.mem.writeInt(u32, expected[2..6], function_atom, .little);
    expected[6] = op.neq;
    expected[7] = op.drop;
    expected[8] = op.return_undef;
    try std.testing.expectEqualSlices(u8, &expected, bc.code);
    try std.testing.expectEqualSlices(core.Atom, &.{function_atom}, bc.atom_operands);
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
    var input = [_]u8{0} ** 20;
    input[0] = op.get_loc0;
    input[1] = op.if_true;
    std.mem.writeInt(u32, input[2..6], 8, .little);
    input[6] = op.get_loc0;
    input[7] = op.@"return";
    input[8] = op.push_atom_value;
    std.mem.writeInt(u32, input[9..13], live_atom, .little);
    input[13] = op.drop;
    input[14] = op.return_undef;
    input[15] = op.goto;
    std.mem.writeInt(u32, input[16..20], 13, .little);

    var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer bc.deinit(rt);
    try bc.setCode(&input);
    try bc.retainAtomOperand(live_atom);

    var ctx = pipeline.resolve_labels.JSContext.initWithFunctionDef(&bc, &fd);
    try pipeline.resolve_labels.run(&ctx);

    // The externally reached atom load survives, while its adjacent
    // drop; return_undef tail still takes the independent QuickJS fold.
    try std.testing.expectEqual(@as(usize, 11), bc.code.len);
    try std.testing.expectEqual(op.push_atom_value, bc.code[5]);
    try std.testing.expectEqual(op.return_undef, bc.code[10]);
    try std.testing.expectEqualSlices(core.Atom, &.{live_atom}, bc.atom_operands);
}

test "resolve_labels removes targets referenced only by unreachable jumps" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const name = try rt.internAtom("unreachable-jump-graph");
    defer rt.atoms.free(name);
    const dead_atom = try rt.internAtom("unreachable-target-operand");
    defer rt.atoms.free(dead_atom);
    const base_ref_count = rt.atoms.refCount(dead_atom).?;

    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);
    fd.use_short_opcodes = true;

    const op = bytecode.opcode.op;
    {
        var input = [_]u8{0} ** 13;
        input[0] = op.get_loc0;
        input[1] = op.@"return";
        input[2] = op.goto;
        std.mem.writeInt(u32, input[3..7], 7, .little);
        input[7] = op.push_atom_value;
        std.mem.writeInt(u32, input[8..12], dead_atom, .little);
        input[12] = op.@"return";

        var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
        defer bc.deinit(rt);
        try bc.setCode(&input);
        try bc.retainAtomOperand(dead_atom);
        try bc.appendSourceLoc(1, 10, 2);
        try bc.appendSourceLoc(2, 11, 3);
        try bc.appendSourceLoc(7, 12, 4);
        try bc.appendSourceLoc(12, 13, 5);

        var ctx = pipeline.resolve_labels.JSContext.initWithFunctionDef(&bc, &fd);
        try pipeline.resolve_labels.run(&ctx);

        try std.testing.expectEqualSlices(u8, &.{ op.get_loc0, op.@"return" }, bc.code);
        try std.testing.expectEqual(@as(usize, 0), bc.atom_operands.len);
        try std.testing.expectEqual(base_ref_count, rt.atoms.refCount(dead_atom).?);
        try std.testing.expectEqual(@as(usize, 1), bc.source_loc_slots.len);
        try std.testing.expectEqual(@as(u32, 1), bc.source_loc_slots[0].pc);
    }

    {
        var input = [_]u8{0} ** 11;
        input[0] = op.return_undef;
        input[1] = op.goto;
        std.mem.writeInt(u32, input[2..6], 6, .little);
        input[6] = op.goto;
        std.mem.writeInt(u32, input[7..11], 1, .little);

        var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
        defer bc.deinit(rt);
        try bc.setCode(&input);
        try bc.appendSourceLoc(1, 20, 2);
        try bc.appendSourceLoc(6, 21, 3);

        var ctx = pipeline.resolve_labels.JSContext.initWithFunctionDef(&bc, &fd);
        try pipeline.resolve_labels.run(&ctx);

        try std.testing.expectEqualSlices(u8, &.{op.return_undef}, bc.code);
        try std.testing.expectEqual(@as(usize, 0), bc.source_loc_slots.len);
    }
}

test "resolve_labels retains return after jump-entered trailing cleanup" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const name = try rt.internAtom("jump-entered-cleanup-return");
    defer rt.atoms.free(name);

    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);
    fd.use_short_opcodes = true;

    const op = bytecode.opcode.op;
    var input = [_]u8{0} ** 15;
    input[0] = op.get_loc0;
    input[1] = op.if_false;
    std.mem.writeInt(u32, input[2..6], 11, .little);
    input[6] = op.goto;
    std.mem.writeInt(u32, input[7..11], 0, .little);
    input[11] = op.close_loc;
    std.mem.writeInt(u16, input[12..14], 0, .little);
    input[14] = op.return_undef;

    var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer bc.deinit(rt);
    try bc.setCode(&input);

    var ctx = pipeline.resolve_labels.JSContext.initWithFunctionDef(&bc, &fd);
    try pipeline.resolve_labels.run(&ctx);

    try std.testing.expectEqual(op.return_undef, bc.code[bc.code.len - 1]);
    _ = try stack_size.compute(bc.code, .{});
}

test "resolve_labels relocates gosub directly to its finalizer" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const name = try rt.internAtom("test");
    defer rt.atoms.free(name);

    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);
    fd.use_short_opcodes = true;

    const op = bytecode.opcode.op;
    var input = [_]u8{0} ** 20;
    input[0] = op.undefined;
    input[1] = op.gosub;
    std.mem.writeInt(u32, input[2..6], 12, .little);
    input[6] = op.drop;
    input[7] = op.goto;
    std.mem.writeInt(u32, input[8..12], 19, .little);
    input[12] = op.label;
    std.mem.writeInt(u32, input[13..17], 1, .little);
    input[17] = op.nop;
    input[18] = op.ret;
    input[19] = op.return_undef;

    var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer bc.deinit(rt);
    try bc.setCode(&input);

    var ctx = pipeline.resolve_labels.JSContext.initWithFunctionDef(&bc, &fd);
    try pipeline.resolve_labels.run(&ctx);

    try std.testing.expectEqual(op.gosub, bc.code[1]);
    try std.testing.expectEqual(@as(i32, 6), std.mem.readInt(i32, bc.code[2..6], .little));
    try std.testing.expectEqual(op.nop, bc.code[8]);
    try std.testing.expectEqual(op.ret, bc.code[9]);
}

test "resolve_labels preserves empty gosub because phase2 owns its removal" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const name = try rt.internAtom("test");
    defer rt.atoms.free(name);

    const op = bytecode.opcode.op;
    var input = [_]u8{0} ** 13;
    input[0] = op.undefined;
    input[1] = op.gosub;
    std.mem.writeInt(u32, input[2..6], 7, .little);
    input[6] = op.drop;
    input[7] = op.label;
    std.mem.writeInt(u32, input[8..12], 1, .little);
    input[12] = op.ret;

    var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer bc.deinit(rt);
    try bc.setCode(&input);

    var ctx = pipeline.resolve_labels.JSContext.init(&bc);
    try pipeline.resolve_labels.run(&ctx);
    try std.testing.expectEqualSlices(
        u8,
        &.{ op.undefined, op.gosub, 5, 0, 0, 0, op.drop, op.ret },
        bc.code,
    );
}

test "stack_size accepts nested gosub return PCs" {
    const op = bytecode.opcode.op;
    var code = [_]u8{0} ** 16;
    code[0] = op.undefined;
    code[1] = op.gosub;
    std.mem.writeInt(i32, code[2..6], 6, .little); // target pc 8
    code[6] = op.drop;
    code[7] = op.return_undef;
    code[8] = op.gosub;
    std.mem.writeInt(i32, code[9..13], 5, .little); // target pc 14
    code[13] = op.ret;
    code[14] = op.nop;
    code[15] = op.ret;

    try std.testing.expectEqual(@as(u16, 3), try stack_size.compute(&code, .{}));
}

test "stack_size rejects ret without a gosub return PC" {
    const op = bytecode.opcode.op;
    try std.testing.expectError(error.StackUnderflow, stack_size.compute(&.{op.ret}, .{}));
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

test "W1d: resolve_variables lowers private method and accessor VarKinds" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("private-kinds");
    const private_atom = try rt.internAtom("#x");
    const setter_atom = try rt.internAtom("#x<set>");
    defer rt.atoms.free(name);
    defer rt.atoms.free(private_atom);
    defer rt.atoms.free(setter_atom);

    const op = bytecode.opcode.op;
    const cases = [_]struct {
        kind: function_def.VarKind,
        temp: u8,
        with_setter: bool = false,
        expected: []const u8,
        expected_atoms: usize = 0,
    }{
        .{ .kind = .private_method, .temp = op.scope_get_private_field, .expected = &.{ op.get_loc0, op.check_brand, op.nip, op.return_undef } },
        .{ .kind = .private_method, .temp = op.scope_get_private_field2, .expected = &.{ op.get_loc0, op.check_brand, op.return_undef } },
        .{ .kind = .private_getter, .temp = op.scope_get_private_field, .expected = &.{ op.get_loc0, op.check_brand, op.call_method, 0, 0, op.return_undef } },
        .{ .kind = .private_getter, .temp = op.scope_get_private_field2, .expected = &.{ op.dup, op.get_loc0, op.check_brand, op.call_method, 0, 0, op.return_undef } },
        .{ .kind = .private_setter, .temp = op.scope_get_private_field, .expected = &.{ op.throw_error, 0, 0, 0, 0, 0, op.return_undef }, .expected_atoms = 1 },
        .{ .kind = .private_method, .temp = op.scope_put_private_field, .expected = &.{ op.throw_error, 0, 0, 0, 0, 0, op.return_undef }, .expected_atoms = 1 },
        .{ .kind = .private_getter_setter, .temp = op.scope_put_private_field, .with_setter = true, .expected = &.{ op.get_loc1, op.swap, op.rot3r, op.check_brand, op.rot3l, op.call_method, 1, 0, op.drop, op.return_undef } },
        .{ .kind = .private_method, .temp = op.scope_in_private_field, .expected = &.{ op.get_loc0, op.private_in, op.return_undef } },
    };

    for (cases) |case| {
        var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
        defer fd.deinit(rt);
        fd.use_short_opcodes = true;
        _ = try fd.appendScope(-1);
        _ = try fd.addScopeVar(private_atom, case.kind, 0, true, true);
        if (case.with_setter) _ = try fd.addScopeVar(setter_atom, .private_setter, 0, true, true);

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

        const expected = try rt.memory.alloc(u8, case.expected.len);
        defer rt.memory.free(u8, expected);
        @memcpy(expected, case.expected);
        if (case.expected_atoms == 1) std.mem.writeInt(u32, expected[1..5], private_atom, .little);
        try std.testing.expectEqualSlices(u8, expected, bc.code);
        try std.testing.expectEqual(case.expected_atoms, bc.atom_operands.len);
    }
}

test "W1d: private-in has no atom-only binding fallback" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("private-side-metadata");
    const private_atom = try rt.internAtom("#x");
    defer rt.atoms.free(name);
    defer rt.atoms.free(private_atom);

    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);
    fd.use_short_opcodes = true;
    _ = try fd.appendScope(-1);

    const op = bytecode.opcode.op;
    var input = [_]u8{0} ** 8;
    input[0] = op.scope_in_private_field;
    std.mem.writeInt(u32, input[1..5], private_atom, .little);
    std.mem.writeInt(u16, input[5..7], 0, .little);
    input[7] = op.return_undef;

    var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer bc.deinit(rt);
    try bc.setCode(&input);
    try bc.retainAtomOperand(private_atom);

    var ctx = pipeline.resolve_variables.JSContext.initWithFunctionDef(&bc, &fd);
    try std.testing.expectError(error.ClosureVarNotFound, pipeline.resolve_variables.run(&ctx));
}

test "W1d: private binding topology threads LOCAL then REF without atom fallback" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("private-topology");
    const private_atom = try rt.internAtom("#x");
    defer rt.atoms.free(name);
    defer rt.atoms.free(private_atom);

    var owner = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer owner.deinit(rt);
    owner.use_short_opcodes = true;
    _ = try owner.appendScope(-1);
    _ = try owner.addScopeVar(private_atom, .private_field, 0, true, true);

    var middle = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer middle.deinit(rt);
    middle.use_short_opcodes = true;
    middle.parent = &owner;
    middle.parent_scope_level = 0;
    _ = try middle.appendScope(-1);

    var leaf = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer leaf.deinit(rt);
    leaf.use_short_opcodes = true;
    leaf.parent = &middle;
    leaf.parent_scope_level = 0;
    _ = try leaf.appendScope(-1);

    const op = bytecode.opcode.op;
    var input = [_]u8{0} ** 8;
    input[0] = op.scope_get_private_field;
    std.mem.writeInt(u32, input[1..5], private_atom, .little);
    std.mem.writeInt(u16, input[5..7], 0, .little);
    input[7] = op.return_undef;

    var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer bc.deinit(rt);
    try bc.setCode(&input);
    try bc.retainAtomOperand(private_atom);

    var ctx = pipeline.resolve_variables.JSContext.initWithFunctionDef(&bc, &leaf);
    try pipeline.resolve_variables.run(&ctx);

    try std.testing.expect(owner.vars[0].is_captured);
    try std.testing.expectEqual(@as(usize, 1), middle.closure_var.len);
    try std.testing.expectEqual(function_def.ClosureType.local, middle.closure_var[0].closureType());
    try std.testing.expectEqual(@as(usize, 1), leaf.closure_var.len);
    try std.testing.expectEqual(function_def.ClosureType.ref, leaf.closure_var[0].closureType());
    try std.testing.expectEqual(function_def.VarKind.private_field, leaf.closure_var[0].varKind());
    try std.testing.expectEqualSlices(u8, &.{ op.get_var_ref0, op.get_private_field, op.return_undef }, bc.code);
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
            // QuickJS routes every global-family carrier through get_var_undef:
            // the referenced cell is consulted first and non-lexical
            // uninitialized cells fall back to the global object. Module and
            // ordinary closure carriers use get_var_ref.
            .global_ref, .global_decl, .global => {
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

test "resolve_labels: base class constructor prologue initializes this once" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const name = try rt.internAtom("C");
    defer rt.atoms.free(name);

    const op = bytecode.opcode.op;

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
    const computed = try stack_size.compute(bc.code, .{});
    try std.testing.expectEqual(@as(u16, 1), computed);
}

// ---- M1.3 task1: createFunctionBytecode produces a usable structure ----

test "createFunctionBytecode: moves final owners from FunctionDef without refcount churn" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("inner");
    const arg_name = try rt.internAtom("arg");
    const captured_name = try rt.internAtom("captured");
    defer rt.atoms.free(name);
    defer rt.atoms.free(arg_name);
    defer rt.atoms.free(captured_name);

    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    var fd_alive = true;
    defer if (fd_alive) fd.deinit(rt);

    fd.is_strict_mode = true;
    fd.has_prototype = true;
    fd.has_simple_parameter_list = false;
    fd.is_derived_class_constructor = true;
    fd.is_indirect_eval = true;
    fd.func_kind = .async_generator;
    fd.line_num = 7;
    fd.col_num = 3;
    try fd.replaceSourceText("async function* inner(arg) {}");

    // Body: push_atom_value <inner> ; plus ; drop ;
    // get_var <var_ref 0> ; drop ; return_undef. The unary plus keeps the
    // synthetic atom operand live while finalization folds the tail
    // drop; return_undef pair. This covers atom operand copying and IC
    // metadata for var_ref-based global access.
    const op = bytecode.opcode.op;
    var body = [_]u8{0} ** 12;
    body[0] = op.push_atom_value;
    std.mem.writeInt(u32, body[1..5], name, .little);
    body[5] = op.plus;
    body[6] = op.drop;
    body[7] = op.get_var;
    std.mem.writeInt(u16, body[8..10], 0, .little);
    body[10] = op.drop;
    body[11] = op.return_undef;
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
    const source_owner_ptr = fd.source_text.?.ptr;
    const name_refs_before = rt.atoms.refCount(name).?;
    const arg_refs_before = rt.atoms.refCount(arg_name).?;
    const captured_refs_before = rt.atoms.refCount(captured_name).?;

    const fb_slice = try createTestFunctionBytecode(&fd, rt);
    const fb = &fb_slice[0];
    defer core.JSValue.functionBytecode(&fb.header).free(rt);

    try std.testing.expectEqual(atom_module.null_atom, fd.func_name);
    try std.testing.expectEqual(atom_module.null_atom, fd.filename);
    try std.testing.expectEqual(atom_module.null_atom, fd.script_or_module);
    try std.testing.expectEqual(atom_module.null_atom, fd.args[0].var_name);
    try std.testing.expectEqual(atom_module.null_atom, fd.vars[0].var_name);
    try std.testing.expectEqual(atom_module.null_atom, fd.closure_var[0].var_name);
    try std.testing.expect(fd.cpool[0].isUndefined());
    try std.testing.expect(fd.source_text == null);
    try std.testing.expectEqual(name_refs_before, rt.atoms.refCount(name).?);
    try std.testing.expectEqual(arg_refs_before, rt.atoms.refCount(arg_name).?);
    try std.testing.expectEqual(captured_refs_before, rt.atoms.refCount(captured_name).?);
    try std.testing.expect(fb.hasDebug());
    try std.testing.expect(fb.hasExtension());
    try std.testing.expectEqual(@intFromPtr(fb) + 0x60, @intFromPtr(fb.debugInfo().?));
    try std.testing.expectEqual(
        @intFromPtr(fb) + fb.layout().hot_off.?,
        @intFromPtr(fb.hotExtension().?),
    );
    try std.testing.expectEqual(@intFromPtr(source_owner_ptr), @intFromPtr(fb.debugInfo().?.source_ptr.?));
    try std.testing.expectEqual(@as(u8, 0), fb.debugInfo().?.source_ptr.?[@intCast(fb.debugInfo().?.source_len)]);

    // FunctionDef is now only a raw compile-storage shell. Destroy it before
    // consuming the FB to prove every moved owner survives independently.
    fd.deinit(rt);
    fd_alive = false;
    try std.testing.expectEqual(name_refs_before, rt.atoms.refCount(name).?);
    try std.testing.expectEqualStrings("async function* inner(arg) {}", fb.sourceText().?);
    try std.testing.expectEqual(arg_name, fb.argVarDefs()[0].var_name);
    try std.testing.expectEqual(captured_name, fb.closureVar()[0].var_name);

    try std.testing.expect(fb.isStrictMode());
    try std.testing.expect(fb.hasPrototype());
    try std.testing.expect(!fb.hasSimpleParameterList());
    try std.testing.expect(fb.isDerivedClassConstructor());
    try std.testing.expect(fb.isDirectOrIndirectEval());
    try std.testing.expectEqual(function_def.FunctionKind.async_generator, fb.functionKind());
    try std.testing.expectEqual(@as(usize, 11), fb.byteCode().len);
    try std.testing.expectEqual(@as(i32, 11), fb.byte_code_len);
    try std.testing.expectEqual(op.push_atom_value, fb.byteCode()[0]);
    try std.testing.expectEqual(op.plus, fb.byteCode()[5]);
    try std.testing.expectEqual(op.drop, fb.byteCode()[6]);
    try std.testing.expectEqual(op.get_var, fb.byteCode()[7]);
    try std.testing.expectEqual(op.return_undef, fb.byteCode()[10]);
    try std.testing.expect(fb.pc2lineBuf().len > 0);
    try std.testing.expect(@intFromPtr(fb.byteCode().ptr) != @intFromPtr(fb.pc2lineBuf().ptr));
    try std.testing.expectEqual(@as(usize, 1), fb.argVarDefs().len);
    try std.testing.expectEqual(arg_name, fb.argVarDefs()[0].var_name);
    try std.testing.expectEqual(@as(usize, 1), fb.varDefs().len);
    try std.testing.expectEqual(name, fb.varDefs()[0].var_name);
    try std.testing.expect(fb.varDefs()[0].isConst());
    // Var-ref names are derived from `closure_var[i].var_name` (the former
    // parallel `var_ref_names` atom array was removed to shrink the FB struct).
    try std.testing.expectEqual(@as(usize, 1), fb.closureVar().len);
    try std.testing.expectEqual(captured_name, fb.closureVar()[0].var_name);
    // is_lexical / is_const now derived from closure_var[i] (parallel `[]bool`
    // arrays removed to match qjs JSClosureVar).
    try std.testing.expect(fb.closureVar()[0].isLexical());
    try std.testing.expect(fb.closureVar()[0].isConst());
    try std.testing.expectEqual(@as(u16, 1), fb.var_count);
    try std.testing.expectEqual(@as(u16, 1), fb.arg_count);
    try std.testing.expectEqual(@as(u16, 1), fb.defined_arg_count);
    try std.testing.expectEqual(@as(i32, 1), fb.closure_var_count);
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
    try std.testing.expect(fb.pc2lineBuf().len >= 2);
    try std.testing.expectEqualSlices(u8, &.{ 6, 2 }, fb.pc2lineBuf()[0..2]);
    try std.testing.expect(!@hasField(bytecode.function_bytecode.DebugInfo, "line_num"));
    try std.testing.expect(!@hasField(bytecode.function_bytecode.DebugInfo, "col_num"));
    try std.testing.expectEqualStrings("async function* inner(arg) {}", fb.sourceText().?);

    try std.testing.expect(fb.isStrictMode());
    try std.testing.expect(fb.isAsync());
    try std.testing.expect(fb.isGenerator());
    // The finalized FB no longer exposes a standalone atom-operand array; the
    // iterator above reads the retained atoms directly from final bytecode.
    try std.testing.expect(!@hasField(bytecode.FunctionBytecode, "atom_operands"));
    // The finalized FB derives var-ref names and flags from `closure_var`
    // instead of retaining parallel arrays.
    try std.testing.expect(!@hasField(bytecode.FunctionBytecode, "var_ref_names"));
    try std.testing.expectEqual(fb.closureVar().len, fb.varRefNamesLen());
    try std.testing.expectEqual(fb.closureVar()[0].var_name, fb.varRefName(0));
    try std.testing.expectEqual(fb.closureVar()[0].isConst(), fb.varRefIsConstAt(0));
    try std.testing.expectEqual(fb.closureVar()[0].isLexical(), fb.varRefIsLexicalAt(0));
}

test "createFunctionBytecode rejects a same-count mismatched inline atom owner before transfer" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const function_name = try rt.internAtom("mismatched_owner_function");
    const encoded_atom = try rt.internAtom("encoded_owner");
    const ledger_atom = try rt.internAtom("ledger_owner");
    defer rt.atoms.free(function_name);
    defer rt.atoms.free(encoded_atom);
    defer rt.atoms.free(ledger_atom);

    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, function_name);
    defer fd.deinit(rt);

    const op = bytecode.opcode.op;
    var body = [_]u8{0} ** 7;
    body[0] = op.push_atom_value;
    std.mem.writeInt(u32, body[1..5], encoded_atom, .little);
    body[5] = op.drop;
    body[6] = op.return_undef;
    try fd.appendByteCode(&body);
    try fd.appendAtomOperand(ledger_atom);

    const encoded_refs = rt.atoms.refCount(encoded_atom).?;
    const ledger_refs = rt.atoms.refCount(ledger_atom).?;
    try std.testing.expectError(error.InvalidBytecode, createTestFunctionBytecode(&fd, rt));

    try std.testing.expectEqual(encoded_refs, rt.atoms.refCount(encoded_atom).?);
    try std.testing.expectEqual(ledger_refs, rt.atoms.refCount(ledger_atom).?);
    try std.testing.expectEqual(@as(usize, 1), fd.atom_operands.len);
    try std.testing.expectEqual(ledger_atom, fd.atom_operands[0]);
}

test "FunctionDef source replacement preserves the prior NUL owner across OOM and retry" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const name = try rt.internAtom("source-owner-retry");
    defer rt.atoms.free(name);

    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);
    try fd.replaceSourceText("old source");
    const old_ptr = fd.source_text.?.ptr;

    rt.setMemoryLimit(rt.memory.allocated_bytes);
    defer rt.setMemoryLimit(null);
    try std.testing.expectError(error.OutOfMemory, fd.replaceSourceText("replacement source"));
    rt.setMemoryLimit(null);

    try std.testing.expectEqual(@intFromPtr(old_ptr), @intFromPtr(fd.source_text.?.ptr));
    try std.testing.expectEqualStrings("old source", fd.source_text.?);
    try std.testing.expectEqual(@as(u8, 0), fd.source_text.?.ptr[fd.source_text.?.len]);

    try fd.replaceSourceText("replacement source");
    try std.testing.expectEqualStrings("replacement source", fd.source_text.?);
    try std.testing.expectEqual(@as(u8, 0), fd.source_text.?.ptr[fd.source_text.?.len]);
}

test "abrupt FunctionBytecode finalization leaves the same runtime reusable" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const realm = try core.RealmContext.create(rt);
    defer realm.destroy();
    const name = try rt.internAtom("finalize-recovery");
    defer rt.atoms.free(name);

    var failed_fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    var failed_fd_alive = true;
    defer if (failed_fd_alive) failed_fd.deinit(rt);
    _ = try failed_fd.appendScope(-1);
    try failed_fd.appendByteCode(&.{bytecode.opcode.op.return_undef});
    try failed_fd.replaceSourceText("failed attempt");

    rt.setMemoryLimit(rt.memory.allocated_bytes);
    defer rt.setMemoryLimit(null);
    const failed_result = pipeline.finalize.createFunctionBytecode(&failed_fd, .{ .realm = realm });
    rt.setMemoryLimit(null);
    if (failed_result) |unexpected| {
        core.JSValue.functionBytecode(&unexpected[0].header).free(rt);
        return error.TestUnexpectedResult;
    } else |err| {
        if (err != error.OutOfMemory) return err;
    }
    failed_fd.deinit(rt);
    failed_fd_alive = false;

    var recovery_fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer recovery_fd.deinit(rt);
    _ = try recovery_fd.appendScope(-1);
    try recovery_fd.appendByteCode(&.{bytecode.opcode.op.return_undef});
    try recovery_fd.replaceSourceText("recovered attempt");

    const recovered_slice = try pipeline.finalize.createFunctionBytecode(&recovery_fd, .{ .realm = realm });
    const recovered = &recovered_slice[0];
    defer core.JSValue.functionBytecode(&recovered.header).free(rt);
    try std.testing.expectEqualStrings("recovered attempt", recovered.sourceText().?);
    try std.testing.expectEqual(bytecode.opcode.op.return_undef, recovered.byteCode()[0]);
}

test "final bytecode vardefs are compact arguments plus locals" {
    const FinalVarDef = bytecode.function_bytecode.BytecodeVarDef;
    const FinalClosureVar = bytecode.function_bytecode.BytecodeClosureVar;
    const CompileClosureVar = bytecode.function_def.ClosureVar;
    try std.testing.expect(!@hasField(FinalVarDef, "scope_level"));
    try std.testing.expect(!@hasField(FinalVarDef, "func_pool_idx"));
    try std.testing.expect(!@hasField(FinalVarDef, "tdz_emitted_at_decl"));
    try std.testing.expect(@hasField(FinalVarDef, "flags"));
    try std.testing.expect(!@hasField(FinalVarDef, "has_scope"));
    try std.testing.expect(!@hasField(FinalVarDef, "is_captured"));
    try std.testing.expect(@hasField(FinalVarDef, "var_ref_idx"));
    try std.testing.expect(!@hasField(FinalClosureVar, "source_depth"));
    try std.testing.expect(!@hasField(CompileClosureVar, "source_depth"));

    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const function_name = try rt.internAtom("compact-vardefs");
    defer rt.atoms.free(function_name);
    const arg_name = try rt.internAtom("arg");
    defer rt.atoms.free(arg_name);
    const local_name = try rt.internAtom("local");
    defer rt.atoms.free(local_name);

    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, function_name);
    defer fd.deinit(rt);
    _ = try fd.appendScope(-1);
    _ = try fd.appendArg(.{ .var_name = arg_name, .scope_level = 0 });
    _ = try fd.appendVar(.{ .var_name = local_name, .scope_level = 0 });
    try fd.appendByteCode(&.{bytecode.opcode.op.return_undef});

    const fb_slice = try createTestFunctionBytecode(&fd, rt);
    const fb = &fb_slice[0];
    defer core.JSValue.functionBytecode(&fb.header).free(rt);

    try std.testing.expectEqual(@as(usize, 2), fb.allVarDefs().len);
    try std.testing.expectEqual(arg_name, fb.argVarDefs()[0].var_name);
    try std.testing.expectEqual(local_name, fb.localVarDefs()[0].var_name);
}

test "final variable metadata matches pinned QuickJS physical ABI" {
    const VarKind = bytecode.function_bytecode.VarKind;
    const CompileClosureVar = bytecode.function_def.ClosureVar;
    const FinalClosureVar = bytecode.function_bytecode.BytecodeClosureVar;
    const FinalVarDef = bytecode.function_bytecode.BytecodeVarDef;

    // Keep the upstream values stable because both final row types store 4
    // bits.
    try std.testing.expectEqual(@as(u4, 5), @intFromEnum(VarKind.private_field));
    try std.testing.expectEqual(@as(u4, 10), @intFromEnum(VarKind.global_function_decl));

    // LP64 QuickJS: sizeof/alignof(JSClosureVar) == 8/4 and
    // sizeof/alignof(JSBytecodeVarDef) == 12/4.
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(CompileClosureVar));
    try std.testing.expectEqual(@as(usize, 4), @alignOf(CompileClosureVar));
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(FinalClosureVar));
    try std.testing.expectEqual(@as(usize, 4), @alignOf(FinalClosureVar));
    try std.testing.expectEqual(@as(usize, 12), @sizeOf(FinalVarDef));
    try std.testing.expectEqual(@as(usize, 4), @alignOf(FinalVarDef));

    var closure = CompileClosureVar.init(.{
        .closure_type = .ref,
        .is_lexical = true,
        .is_const = true,
        .var_kind = .private_setter,
        .var_idx = 0x1234,
        .var_name = 0x55667788,
    });
    const expected_closure = [_]u8{ 0x1a, 0x08, 0x34, 0x12, 0x88, 0x77, 0x66, 0x55 };
    try std.testing.expectEqualSlices(u8, &expected_closure, std.mem.asBytes(&closure));

    const compile_vd = function_def.VarDef{
        .var_name = 0x11223344,
        .scope_level = 2,
        .is_const = true,
        .is_lexical = true,
        .is_captured = true,
        .var_kind = .private_setter,
        .open_binding_idx = 0x1234,
    };
    var final_vd = FinalVarDef.fromCompile(compile_vd, 0x01020304);
    const expected_vardef = [_]u8{ 0x44, 0x33, 0x22, 0x11, 0x04, 0x03, 0x02, 0x01, 0x8f, 0x00, 0x34, 0x12 };
    try std.testing.expectEqualSlices(u8, &expected_vardef, std.mem.asBytes(&final_vd));

    var uncaptured = FinalVarDef.fromCompile(.{
        .var_name = 0x10203040,
        .scope_level = 0,
    }, -1);
    try std.testing.expect(!uncaptured.isCaptured());
    try std.testing.expectEqual(@as(u16, 0), uncaptured.var_ref_idx);
    try std.testing.expectEqual(@as(u8, 0), std.mem.asBytes(&uncaptured)[9]);
}

test "legacy execution adapter delegates synthetic var-ref name mirrors" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const realm = try core.RealmContext.create(rt);
    defer realm.destroy();

    try std.testing.expect(!@hasField(bytecode.FunctionBytecode.Flags, "backtrace_barrier"));
    try std.testing.expect(!@hasField(bytecode.FunctionDef, "backtrace_barrier"));

    const name = try rt.internAtom("legacy-var-ref-name");
    defer rt.atoms.free(name);
    var function = bytecode.Bytecode.init(&rt.memory, &rt.atoms, core.atom.ids.empty_string);
    defer function.deinit(rt);
    try std.testing.expect(!@hasField(@TypeOf(function.flags), "backtrace_barrier"));
    function.flags.is_strict = true;
    function.flags.runtime_strict = true;
    function.flags.has_mapped_arguments = true;
    function.realm = realm;
    function.arg_count = 2;
    function.var_count = 3;
    function.stack_size = 4;
    function.open_var_ref_count = 1;
    try function.setCode(&.{bytecode.opcode.op.return_undef});
    function.var_ref_names = try rt.memory.alloc(atom_module.Atom, 1);
    function.var_ref_names[0] = rt.atoms.dup(name);

    var adapter: bytecode.LegacyExecutionAdapter = undefined;
    const execution_function = adapter.init(&function);
    try std.testing.expectEqual(@as(usize, 1), execution_function.varRefNamesLen());
    try std.testing.expectEqual(name, execution_function.varRefName(0));
    try std.testing.expect(!execution_function.varRefIsLexicalAt(0));
    try std.testing.expect(!execution_function.varRefIsConstAt(0));
    try std.testing.expect(!execution_function.varRefIsGlobalDeclAt(0));
    try std.testing.expectEqualSlices(u8, function.code, execution_function.byteCode());
    try std.testing.expect(execution_function.byte_code == null);
    try std.testing.expectEqual(bytecode.legacy_byte_code_len_sentinel, execution_function.byte_code_len);
    try std.testing.expect(execution_function.realm.borrow() == null);
    try std.testing.expectEqual(realm, execution_function.realmContext());
    try std.testing.expect(execution_function.isStrictMode());
    try std.testing.expect(execution_function.runtimeStrictMode());
    try std.testing.expectEqual(@as(u16, 2), execution_function.arg_count);
    try std.testing.expectEqual(@as(u16, 3), execution_function.var_count);
    try std.testing.expectEqual(@as(u16, 4), execution_function.stack_size);
    try std.testing.expectEqual(@as(u16, 1), execution_function.openVarRefCount());
    try std.testing.expect(execution_function.callFacts().execution.has_mapped_arguments);
    try std.testing.expectEqual(
        @as(usize, 112),
        @sizeOf(bytecode.LegacyExecutionAdapter),
    );
    // The negative sentinel deliberately keeps this borrowed stack bridge out
    // of canonical count-based FunctionLayout reconstruction. Its hot tail and
    // borrowed pointer occupy fixed base+96/base+104 slots even though the
    // mirrored table counts and borrowed code are all non-empty.
    try std.testing.expectEqual(
        @as(usize, 0x68),
        @offsetOf(bytecode.LegacyExecutionAdapter, "legacy_bytecode_adapter"),
    );
    try std.testing.expectEqual(
        @intFromPtr(execution_function) + @sizeOf(bytecode.FunctionBytecode),
        @intFromPtr(execution_function.hotExtension().?),
    );
    try std.testing.expectEqual(
        @intFromPtr(execution_function) +
            @sizeOf(bytecode.FunctionBytecode) +
            @sizeOf(bytecode.function_bytecode.FunctionBytecodeHotExtension),
        @intFromPtr(&adapter.legacy_bytecode_adapter),
    );
    try std.testing.expect(execution_function.legacyBytecodeAdapter().? == &function);
}

test "function bytecode separates strict and sloppy simple inline eligibility" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("simple-inline");
    defer rt.atoms.free(name);

    {
        var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
        defer fd.deinit(rt);
        fd.func_kind = .normal;
        fd.has_simple_parameter_list = true;
        try fd.appendByteCode(&.{bytecode.opcode.op.return_undef});

        const fb_slice = try createTestFunctionBytecode(&fd, rt);
        const fb = &fb_slice[0];
        defer core.JSValue.functionBytecode(&fb.header).free(rt);
        try std.testing.expect(fb.simpleInlineEligible());
        try std.testing.expect(!fb.strictSimpleInlineEligible());
        try std.testing.expect(!fb.strictSimpleSnapshotInlineEligible());
        try std.testing.expect(fb.simpleInlineEmptyLeaf());
        try std.testing.expect(!fb.rawThisInlineEmptyLeaf());
    }

    {
        var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
        defer fd.deinit(rt);
        fd.func_kind = .normal;
        fd.has_simple_parameter_list = true;
        fd.is_strict_mode = true;
        try fd.appendByteCode(&.{bytecode.opcode.op.return_undef});

        const fb_slice = try createTestFunctionBytecode(&fd, rt);
        const fb = &fb_slice[0];
        defer core.JSValue.functionBytecode(&fb.header).free(rt);
        try std.testing.expect(!fb.simpleInlineEligible());
        try std.testing.expect(fb.strictSimpleInlineEligible());
        try std.testing.expect(!fb.strictSimpleSnapshotInlineEligible());
        // The raw-this leaf publishes its own eligibility byte; the packed
        // sloppy bit stays clear so the established sloppy call arms keep
        // their single-bit test.
        try std.testing.expect(!fb.simpleInlineEmptyLeaf());
        try std.testing.expect(fb.rawThisInlineEmptyLeaf());
        try std.testing.expect(fb.isStrictMode());
    }

    {
        // A sloppy arrow shares the ordinary sloppy eligibility bytes. Its
        // frame receives the realm-global substitution, but lexical
        // this/new.target are ordinary closure cells, so that slot is
        // unobservable to arrow bytecode.
        var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
        defer fd.deinit(rt);
        fd.func_kind = .normal;
        fd.func_type = .arrow;
        fd.has_simple_parameter_list = true;
        try fd.appendByteCode(&.{bytecode.opcode.op.return_undef});

        const fb_slice = try createTestFunctionBytecode(&fd, rt);
        const fb = &fb_slice[0];
        defer core.JSValue.functionBytecode(&fb.header).free(rt);
        try std.testing.expect(fb.simpleInlineEligible());
        try std.testing.expect(!fb.strictSimpleInlineEligible());
        try std.testing.expect(!fb.strictSimpleSnapshotInlineEligible());
        try std.testing.expect(fb.simpleInlineEmptyLeaf());
        try std.testing.expect(!fb.rawThisInlineEmptyLeaf());
        try std.testing.expectEqual(function_def.FunctionKind.normal, fb.functionKind());
        try std.testing.expect(!fb.hasPrototype());
        try std.testing.expectEqual(@as(usize, 0), fb.closureVarCount());
        try std.testing.expectEqualSlices(
            u8,
            &.{bytecode.opcode.op.return_undef},
            fb.byteCode(),
        );
    }

    {
        // A strict arrow shares the ordinary strict/raw eligibility bytes.
        // Its lexical this capture remains independent of the raw undefined
        // frame slot.
        var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
        defer fd.deinit(rt);
        fd.func_kind = .normal;
        fd.func_type = .arrow;
        fd.has_simple_parameter_list = true;
        fd.is_strict_mode = true;
        try fd.appendByteCode(&.{bytecode.opcode.op.return_undef});

        const fb_slice = try createTestFunctionBytecode(&fd, rt);
        const fb = &fb_slice[0];
        defer core.JSValue.functionBytecode(&fb.header).free(rt);
        try std.testing.expect(!fb.simpleInlineEligible());
        try std.testing.expect(fb.strictSimpleInlineEligible());
        try std.testing.expect(!fb.strictSimpleSnapshotInlineEligible());
        try std.testing.expect(!fb.simpleInlineEmptyLeaf());
        try std.testing.expect(fb.rawThisInlineEmptyLeaf());
        try std.testing.expect(fb.isStrictMode());
        try std.testing.expectEqual(function_def.FunctionKind.normal, fb.functionKind());
        try std.testing.expect(!fb.hasPrototype());
        try std.testing.expectEqual(@as(usize, 0), fb.closureVarCount());
        try std.testing.expectEqualSlices(
            u8,
            &.{bytecode.opcode.op.return_undef},
            fb.byteCode(),
        );
    }

    {
        var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
        defer fd.deinit(rt);
        fd.func_kind = .normal;
        fd.has_simple_parameter_list = true;
        fd.is_strict_mode = true;
        try fd.appendByteCode(&.{
            bytecode.opcode.op.special_object,
            bytecode.opcode.special_object_subtype.arguments,
            bytecode.opcode.op.drop,
            bytecode.opcode.op.return_undef,
        });

        const fb_slice = try createTestFunctionBytecode(&fd, rt);
        const fb = &fb_slice[0];
        defer core.JSValue.functionBytecode(&fb.header).free(rt);
        try std.testing.expect(!fb.simpleInlineEligible());
        try std.testing.expect(!fb.strictSimpleInlineEligible());
        try std.testing.expect(fb.strictSimpleSnapshotInlineEligible());
        try std.testing.expect(!fb.simpleInlineEmptyLeaf());
        // Arguments materialization is excluded from the leaf geometry in
        // both modes.
        try std.testing.expect(!fb.rawThisInlineEmptyLeaf());
    }
}

test "function bytecode publishes exact-args leaf bytes by mode and geometry" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("exact-args-leaf");
    const arg_name = try rt.internAtom("value");
    defer rt.atoms.free(name);
    defer rt.atoms.free(arg_name);

    const Mode = struct { strict: bool, arrow: bool, captured_arg: bool };
    const modes = [_]Mode{
        .{ .strict = false, .arrow = false, .captured_arg = false },
        .{ .strict = true, .arrow = false, .captured_arg = false },
        .{ .strict = false, .arrow = true, .captured_arg = false },
        .{ .strict = true, .arrow = true, .captured_arg = false },
        .{ .strict = false, .arrow = false, .captured_arg = true },
    };
    for (modes) |mode| {
        var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
        defer fd.deinit(rt);
        fd.func_kind = .normal;
        fd.has_simple_parameter_list = true;
        fd.is_strict_mode = mode.strict;
        if (mode.arrow) fd.func_type = .arrow;
        _ = try fd.appendScope(-1);
        _ = try fd.appendArg(.{
            .var_name = rt.atoms.dup(arg_name),
            .scope_level = 0,
            .is_lexical = false,
        });
        // A captured PARAMETER opens a cell window at frame setup, which the
        // leaf constructor cannot build — publication must reject it. Let a
        // real child lookup deliver that capture during the production DFS;
        // parser-era boolean hints are deliberately not an allocation source.
        if (mode.captured_arg) {
            const child = try rt.memory.create(function_def.FunctionDef);
            var child_owned = true;
            errdefer if (child_owned) {
                child.deinit(rt);
                rt.memory.destroy(function_def.FunctionDef, child);
            };
            child.* = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
            _ = try child.appendScope(-1);
            var child_code = [_]u8{0} ** 9;
            child_code[0] = bytecode.opcode.op.scope_get_var;
            std.mem.writeInt(u32, child_code[1..5], arg_name, .little);
            std.mem.writeInt(u16, child_code[5..7], 0, .little);
            child_code[7] = bytecode.opcode.op.drop;
            child_code[8] = bytecode.opcode.op.return_undef;
            try child.appendByteCode(&child_code);
            try child.appendAtomOperand(arg_name);
            child.parent_scope_level = 0;
            child.parent_cpool_idx = @intCast(try fd.appendCpool(core.JSValue.undefinedValue()));
            try fd.addChild(child);
            child_owned = false;
        }
        try fd.appendByteCode(&.{bytecode.opcode.op.return_undef});

        const fb_slice = try createTestFunctionBytecode(&fd, rt);
        const fb = &fb_slice[0];
        defer core.JSValue.functionBytecode(&fb.header).free(rt);
        const expect_sloppy = !mode.strict and !mode.captured_arg;
        const expect_raw = mode.strict and !mode.captured_arg;
        try std.testing.expectEqual(expect_sloppy, fb.simpleInlineExactArgsLeaf());
        try std.testing.expectEqual(expect_raw, fb.rawThisInlineExactArgsLeaf());
        // The zero-arg family never overlaps the exact-args family.
        try std.testing.expect(!fb.simpleInlineEmptyLeaf());
        try std.testing.expect(!fb.rawThisInlineEmptyLeaf());
    }

    {
        // Zero-arg functions stay exclusively on the empty-leaf bytes.
        var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
        defer fd.deinit(rt);
        fd.func_kind = .normal;
        fd.has_simple_parameter_list = true;
        try fd.appendByteCode(&.{bytecode.opcode.op.return_undef});
        const fb_slice = try createTestFunctionBytecode(&fd, rt);
        const fb = &fb_slice[0];
        defer core.JSValue.functionBytecode(&fb.header).free(rt);
        try std.testing.expect(!fb.simpleInlineExactArgsLeaf());
        try std.testing.expect(!fb.rawThisInlineExactArgsLeaf());
        try std.testing.expect(fb.simpleInlineEmptyLeaf());
    }
}

test "function bytecode publishes capture leaf kind by mode and geometry" {
    const LeafKind = bytecode.function_bytecode.ExactArgsLeafKind;
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("capture-leaf");
    const capture_name = try rt.internAtom("held");
    const arg_name = try rt.internAtom("value");
    defer rt.atoms.free(name);
    defer rt.atoms.free(capture_name);
    defer rt.atoms.free(arg_name);

    const Mode = struct { strict: bool, arrow: bool };
    const modes = [_]Mode{
        .{ .strict = false, .arrow = false },
        .{ .strict = true, .arrow = false },
        .{ .strict = false, .arrow = true },
        .{ .strict = true, .arrow = true },
    };
    for (modes) |mode| {
        // Zero args + one inherited capture: the O2 capture-leaf shape.
        var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
        defer fd.deinit(rt);
        fd.func_kind = .normal;
        fd.has_simple_parameter_list = true;
        fd.is_strict_mode = mode.strict;
        if (mode.arrow) fd.func_type = .arrow;
        _ = try fd.addClosureVar(.{
            .closure_type = .local,
            .var_idx = 0,
            .var_name = capture_name,
        });
        try fd.appendByteCode(&.{bytecode.opcode.op.return_undef});

        const fb_slice = try createTestFunctionBytecode(&fd, rt);
        const fb = &fb_slice[0];
        defer core.JSValue.functionBytecode(&fb.header).free(rt);
        const expect_kind: LeafKind = if (mode.strict) .raw_this else .sloppy;
        try std.testing.expectEqual(expect_kind, fb.captureLeafKind());
        // Captured callees never overlap the established zero-arg empty-leaf
        // bytes or the with-args exact-args family.
        try std.testing.expect(!fb.simpleInlineEmptyLeaf());
        try std.testing.expect(!fb.rawThisInlineEmptyLeaf());
        try std.testing.expectEqual(LeafKind.none, fb.exactArgsLeafKind());
    }

    {
        // No captures: the empty-leaf family keeps sole ownership and the
        // capture kind stays .none.
        var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
        defer fd.deinit(rt);
        fd.func_kind = .normal;
        fd.has_simple_parameter_list = true;
        try fd.appendByteCode(&.{bytecode.opcode.op.return_undef});
        const fb_slice = try createTestFunctionBytecode(&fd, rt);
        const fb = &fb_slice[0];
        defer core.JSValue.functionBytecode(&fb.header).free(rt);
        try std.testing.expectEqual(LeafKind.none, fb.captureLeafKind());
        try std.testing.expect(fb.simpleInlineEmptyLeaf());
    }

    {
        // Captures + a parameter: the exact-args family owns it; the capture
        // kind stays .none (argc==0 is load-bearing for its constructors).
        var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
        defer fd.deinit(rt);
        fd.func_kind = .normal;
        fd.has_simple_parameter_list = true;
        _ = try fd.appendArg(.{
            .var_name = rt.atoms.dup(arg_name),
            .scope_level = 0,
            .is_lexical = false,
        });
        _ = try fd.addClosureVar(.{
            .closure_type = .local,
            .var_idx = 0,
            .var_name = capture_name,
        });
        try fd.appendByteCode(&.{bytecode.opcode.op.return_undef});
        const fb_slice = try createTestFunctionBytecode(&fd, rt);
        const fb = &fb_slice[0];
        defer core.JSValue.functionBytecode(&fb.header).free(rt);
        try std.testing.expectEqual(LeafKind.none, fb.captureLeafKind());
        try std.testing.expectEqual(LeafKind.sloppy, fb.exactArgsLeafKind());
    }

    {
        // Captures + a local: leaf body geometry fails, every family rejects.
        var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
        defer fd.deinit(rt);
        fd.func_kind = .normal;
        fd.has_simple_parameter_list = true;
        _ = try fd.appendVar(.{
            .var_name = arg_name,
            .scope_level = 0,
            .is_lexical = false,
        });
        _ = try fd.addClosureVar(.{
            .closure_type = .local,
            .var_idx = 0,
            .var_name = capture_name,
        });
        try fd.appendByteCode(&.{bytecode.opcode.op.return_undef});
        const fb_slice = try createTestFunctionBytecode(&fd, rt);
        const fb = &fb_slice[0];
        defer core.JSValue.functionBytecode(&fb.header).free(rt);
        try std.testing.expectEqual(LeafKind.none, fb.captureLeafKind());
        try std.testing.expectEqual(LeafKind.none, fb.exactArgsLeafKind());
        try std.testing.expect(!fb.simpleInlineEmptyLeaf());
        try std.testing.expect(!fb.rawThisInlineEmptyLeaf());
    }
}

test "stack_size compute reports the return-balance proof" {
    const op = bytecode.opcode.op;

    {
        // The pivot shape (`function one(){ return 1; }`): the return pops
        // its value to an empty window.
        const bc = [_]u8{ op.push_1, op.@"return" };
        var balanced = false;
        _ = try stack_size.compute(&bc, .{ .returns_balanced_out = &balanced });
        try std.testing.expect(balanced);
    }
    {
        // Parser-elided trailing-drop shape (`function k(){ 1; }`): the
        // pushed value is live across `return_undef`.
        const bc = [_]u8{ op.push_1, op.return_undef };
        var balanced = true;
        _ = try stack_size.compute(&bc, .{ .returns_balanced_out = &balanced });
        try std.testing.expect(!balanced);
    }
    {
        // Switch-discriminant shape (`function sw(){ switch(1){ case 1:
        // return 2; } }`, exact parser output): the discriminant is live
        // across BOTH return sites.
        const bc = [_]u8{
            op.push_1,       op.dup, op.push_1, op.strict_eq,
            op.if_false8,    3,      op.push_2, op.@"return",
            op.return_undef,
        };
        var balanced = true;
        _ = try stack_size.compute(&bc, .{ .returns_balanced_out = &balanced });
        try std.testing.expect(!balanced);
    }
    {
        // Branchy but BALANCED: both return sites pop to an empty window.
        // The per-pc BFS levels are exact, so branches do not refuse the
        // proof (a conservative linear scan would).
        const bc = [_]u8{
            op.push_1,    op.if_false8, 3,            op.push_1,
            op.@"return", op.push_2,    op.@"return",
        };
        var balanced = false;
        _ = try stack_size.compute(&bc, .{ .returns_balanced_out = &balanced });
        try std.testing.expect(balanced);
    }
    {
        const bc = [_]u8{op.push_1};
        var balanced = true;
        try std.testing.expectError(error.ReachableFalloff, stack_size.compute(&bc, .{ .returns_balanced_out = &balanced }));
    }
    {
        const bc = [_]u8{op.nop};
        var balanced = true;
        try std.testing.expectError(error.ReachableFalloff, stack_size.compute(&bc, .{ .returns_balanced_out = &balanced }));
    }
    {
        // Terminated-by-throw code carries no balance fact (abrupt paths
        // route through general teardown, never the leaf epilogue).
        const bc = [_]u8{ op.push_1, op.throw };
        var balanced = false;
        _ = try stack_size.compute(&bc, .{ .returns_balanced_out = &balanced });
        try std.testing.expect(balanced);
    }
}

test "stack verifier and finalize reject reachable end edges" {
    const op = bytecode.opcode.op;

    var jump_to_end = [_]u8{0} ** 5;
    jump_to_end[0] = op.goto;
    std.mem.writeInt(i32, jump_to_end[1..5], 4, .little);
    try std.testing.expectError(error.ReachableFalloff, stack_size.compute(&jump_to_end, .{}));

    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    var function = bytecode.Bytecode.init(&rt.memory, &rt.atoms, core.atom.ids.empty_string);
    defer function.deinit(rt);
    try function.setCode(&.{op.nop});
    try std.testing.expectError(error.InvalidBytecode, pipeline.finalize.run(&function));
}

test "zero-arg empty leaf publication requires the return-balance proof" {
    const LeafKind = bytecode.function_bytecode.ExactArgsLeafKind;
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("leaf-balance");
    const capture_name = try rt.internAtom("held");
    const arg_name = try rt.internAtom("value");
    defer rt.atoms.free(name);
    defer rt.atoms.free(capture_name);
    defer rt.atoms.free(arg_name);

    const op = bytecode.opcode.op;
    // The `function k(){ 1; }` body: parser-elided trailing drop leaves the
    // value live across return_undef (push_i32 is the wide phase-1 form of
    // the disassembled push_1).
    const unbalanced_body = [_]u8{ op.push_i32, 1, 0, 0, 0, op.return_undef };
    const balanced_body = [_]u8{ op.push_i32, 1, 0, 0, 0, op.@"return" };

    const Mode = struct { strict: bool, arrow: bool };
    const modes = [_]Mode{
        .{ .strict = false, .arrow = false },
        .{ .strict = true, .arrow = false },
        .{ .strict = false, .arrow = true },
        .{ .strict = true, .arrow = true },
    };
    for (modes) |mode| {
        // Unbalanced zero-arg bodies must be refused BOTH zero-arg leaf
        // bits: the empty-leaf return arm is the one leaf epilogue without
        // an operand-window guard (HEAD ec058eed published these — Debug
        // asserts in deinitEmptyLeafInline, ReleaseFast leaks the leftover
        // per call). Refused bodies keep their established generic
        // simple-inline eligibility (no semantic downgrade).
        var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
        defer fd.deinit(rt);
        fd.func_kind = .normal;
        fd.has_simple_parameter_list = true;
        fd.is_strict_mode = mode.strict;
        if (mode.arrow) fd.func_type = .arrow;
        try fd.appendByteCode(&unbalanced_body);
        const fb_slice = try createTestFunctionBytecode(&fd, rt);
        const fb = &fb_slice[0];
        defer core.JSValue.functionBytecode(&fb.header).free(rt);
        try std.testing.expect(!fb.simpleInlineEmptyLeaf());
        try std.testing.expect(!fb.rawThisInlineEmptyLeaf());
        try std.testing.expectEqual(!mode.strict, fb.simpleInlineEligible());
        try std.testing.expectEqual(mode.strict, fb.strictSimpleInlineEligible());
    }

    {
        // The balanced twin keeps its zero-arg leaf publication.
        var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
        defer fd.deinit(rt);
        fd.func_kind = .normal;
        fd.has_simple_parameter_list = true;
        try fd.appendByteCode(&balanced_body);
        const fb_slice = try createTestFunctionBytecode(&fd, rt);
        const fb = &fb_slice[0];
        defer core.JSValue.functionBytecode(&fb.header).free(rt);
        try std.testing.expect(fb.simpleInlineEmptyLeaf());
    }

    {
        // The proof gates ONLY the zero-arg empty-leaf family. The
        // exact-args family (O1) keeps publication over unbalanced bodies —
        // its return arm carries the runtime len==0 guard, and shapes like
        // fib must stay eligible with arbitrary bodies.
        var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
        defer fd.deinit(rt);
        fd.func_kind = .normal;
        fd.has_simple_parameter_list = true;
        _ = try fd.appendArg(.{
            .var_name = rt.atoms.dup(arg_name),
            .scope_level = 0,
            .is_lexical = false,
        });
        try fd.appendByteCode(&unbalanced_body);
        const fb_slice = try createTestFunctionBytecode(&fd, rt);
        const fb = &fb_slice[0];
        defer core.JSValue.functionBytecode(&fb.header).free(rt);
        try std.testing.expectEqual(LeafKind.sloppy, fb.exactArgsLeafKind());
    }

    {
        // Capture-leaf twin (O2): also NOT proof-gated — it publishes the
        // exact_args_leaf teardown bit whose return arm is guarded.
        var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
        defer fd.deinit(rt);
        fd.func_kind = .normal;
        fd.has_simple_parameter_list = true;
        _ = try fd.addClosureVar(.{
            .closure_type = .local,
            .var_idx = 0,
            .var_name = capture_name,
        });
        try fd.appendByteCode(&unbalanced_body);
        const fb_slice = try createTestFunctionBytecode(&fd, rt);
        const fb = &fb_slice[0];
        defer core.JSValue.functionBytecode(&fb.header).free(rt);
        try std.testing.expectEqual(LeafKind.sloppy, fb.captureLeafKind());
    }
}

test "direct eval reserves identity for visible function-scope locals and arguments" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const function_name = try rt.internAtom("direct-eval-open-bindings");
    const local_name = try rt.internAtom("local");
    const arg_name = try rt.internAtom("arg");
    defer rt.atoms.free(function_name);
    defer rt.atoms.free(local_name);
    defer rt.atoms.free(arg_name);

    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, function_name);
    defer fd.deinit(rt);
    _ = try fd.appendScope(-1);
    _ = try fd.addScopeVar(local_name, .normal, 0, false, false);
    _ = try fd.appendArg(.{
        .var_name = arg_name,
        .scope_level = 0,
        .is_lexical = false,
    });

    var code = [_]u8{ bytecode.opcode.op.undefined, bytecode.opcode.op.eval, 0, 0, 0, 0, bytecode.opcode.op.drop, bytecode.opcode.op.return_undef };
    std.mem.writeInt(u16, code[2..4], 0, .little);
    std.mem.writeInt(u16, code[4..6], 0, .little);
    try fd.appendByteCode(&code);
    // The parser sets this whenever it emits eval/apply_eval (markDirectEvalCall);
    // finalize gates the direct-eval binding walk on it.
    fd.has_eval_call = true;

    const fb_slice = try createTestFunctionBytecode(&fd, rt);
    const fb = &fb_slice[0];
    defer core.JSValue.functionBytecode(&fb.header).free(rt);

    // add_eval_variables captures the argument first, then every scope-zero
    // local in index order, including its newly appended `<var>` object.
    try std.testing.expectEqual(@as(u16, 3), fb.openVarRefCount());
    try std.testing.expect(fb.varDefs()[0].isCaptured());
    // qjs add_eval_variables calls capture_var for own arguments before
    // scope-zero locals. The open-cell index records that event order; it is
    // not a grouped locals-then-arguments frame layout.
    try std.testing.expectEqual(@as(u16, 1), fb.varDefs()[0].var_ref_idx);
    try std.testing.expect(fd.args[0].is_captured);
    try std.testing.expectEqual(@as(u16, 0), fd.args[0].open_binding_idx);
    try std.testing.expectEqual(@as(u16, 0), fb.argVarDefs()[0].var_ref_idx);
}

test "surviving local references reserve compact open VarRef storage" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const function_name = try rt.internAtom("open-ref-frame-sizing");
    const local_name = try rt.internAtom("value");
    defer rt.atoms.free(function_name);
    defer rt.atoms.free(local_name);

    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, function_name);
    defer fd.deinit(rt);
    _ = try fd.appendScope(-1);
    _ = try fd.addScopeVar(local_name, .normal, 0, false, false);

    var code = [_]u8{0} ** 14;
    code[0] = bytecode.opcode.op.scope_make_ref;
    std.mem.writeInt(u32, code[1..5], local_name, .little);
    std.mem.writeInt(u32, code[5..9], 0, .little);
    std.mem.writeInt(u16, code[9..11], 0, .little);
    code[11] = bytecode.opcode.op.get_ref_value;
    code[12] = bytecode.opcode.op.drop;
    code[13] = bytecode.opcode.op.return_undef;
    try fd.appendByteCode(&code);
    try fd.appendAtomOperand(local_name);

    const fb_slice = try createTestFunctionBytecode(&fd, rt);
    const fb = &fb_slice[0];
    defer core.JSValue.functionBytecode(&fb.header).free(rt);

    try std.testing.expectEqual(@as(u16, 1), fb.openVarRefCount());
    try std.testing.expect(fb.varDefs()[0].isCaptured());
    try std.testing.expectEqual(@as(u16, 0), fb.varDefs()[0].var_ref_idx);
    try std.testing.expectEqual(bytecode.opcode.op.make_loc_ref, fb.byteCode()[0]);
    try std.testing.expectEqual(@as(u16, 1), fb.openVarRefCount());
    try std.testing.expectEqual(@as(?u16, 0), fb.localOpenBindingIndex(0));
}

test "sloppy function-name references lower to an uncaptured dummy object property" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const function_name = try rt.internAtom("function-name-dummy-ref");
    defer rt.atoms.free(function_name);

    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, function_name);
    defer fd.deinit(rt);
    fd.use_short_opcodes = true;
    _ = try fd.appendScope(-1);
    fd.is_named_func_expr = true;
    try std.testing.expectEqual(@as(i32, 0), try fd.ensureFuncExprSelfBinding());
    // qjs add_func_var uses add_var: the special fallback is not linked into
    // the ordinary lexical scope list.
    try std.testing.expectEqual(@as(i32, -1), fd.scopes[0].first);

    var code = [_]u8{0} ** 14;
    code[0] = bytecode.opcode.op.scope_make_ref;
    std.mem.writeInt(u32, code[1..5], function_name, .little);
    std.mem.writeInt(u32, code[5..9], 0, .little);
    std.mem.writeInt(u16, code[9..11], 0, .little);
    code[11] = bytecode.opcode.op.get_ref_value;
    code[12] = bytecode.opcode.op.drop;
    code[13] = bytecode.opcode.op.return_undef;
    try fd.appendByteCode(&code);
    try fd.appendAtomOperand(function_name);

    const fb_slice = try createTestFunctionBytecode(&fd, rt);
    const fb = &fb_slice[0];
    defer core.JSValue.functionBytecode(&fb.header).free(rt);

    var expected = [_]u8{0} ** 17;
    expected[0] = bytecode.opcode.op.special_object;
    expected[1] = 2; // SPECIAL_OBJECT_THIS_FUNC
    expected[2] = bytecode.opcode.op.put_loc0;
    expected[3] = bytecode.opcode.op.object;
    expected[4] = bytecode.opcode.op.get_loc0;
    expected[5] = bytecode.opcode.op.define_field;
    std.mem.writeInt(u32, expected[6..10], function_name, .little);
    expected[10] = bytecode.opcode.op.push_atom_value;
    std.mem.writeInt(u32, expected[11..15], function_name, .little);
    expected[15] = bytecode.opcode.op.get_ref_value;
    expected[16] = bytecode.opcode.op.return_undef;

    try std.testing.expectEqualSlices(u8, &expected, fb.byteCode());
    try std.testing.expectEqual(@as(u16, 0), fb.openVarRefCount());
    try std.testing.expect(!fb.varDefs()[0].isCaptured());
    try std.testing.expect(!fd.vars[0].is_captured);
}

test "surviving argument references lower to make_arg_ref and reserve storage" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const function_name = try rt.internAtom("arg-open-ref-frame-sizing");
    const arg_name = try rt.internAtom("value");
    defer rt.atoms.free(function_name);
    defer rt.atoms.free(arg_name);

    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, function_name);
    defer fd.deinit(rt);
    _ = try fd.appendScope(-1);
    _ = try fd.appendArg(.{
        .var_name = arg_name,
        .scope_level = 0,
        .is_lexical = false,
    });

    var code = [_]u8{0} ** 14;
    code[0] = bytecode.opcode.op.scope_make_ref;
    std.mem.writeInt(u32, code[1..5], arg_name, .little);
    std.mem.writeInt(u32, code[5..9], 0, .little);
    std.mem.writeInt(u16, code[9..11], 0, .little);
    code[11] = bytecode.opcode.op.get_ref_value;
    code[12] = bytecode.opcode.op.drop;
    code[13] = bytecode.opcode.op.return_undef;
    try fd.appendByteCode(&code);
    try fd.appendAtomOperand(arg_name);

    const fb_slice = try createTestFunctionBytecode(&fd, rt);
    const fb = &fb_slice[0];
    defer core.JSValue.functionBytecode(&fb.header).free(rt);

    try std.testing.expectEqual(@as(u16, 1), fb.openVarRefCount());
    try std.testing.expect(fd.args[0].is_captured);
    try std.testing.expectEqual(@as(u16, 0), fd.args[0].open_binding_idx);
    try std.testing.expectEqual(@as(u16, 0), fb.argVarDefs()[0].var_ref_idx);
    try std.testing.expectEqual(bytecode.opcode.op.make_arg_ref, fb.byteCode()[0]);
    try std.testing.expectEqual(arg_name, std.mem.readInt(u32, fb.byteCode()[1..5], .little));
    try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, fb.byteCode()[5..7], .little));
    try std.testing.expectEqual(@as(?u16, 0), fb.argOpenBindingIndex(0));
}

test "direct Bytecode retains compact open VarRef frame sizing" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const function_name = try rt.internAtom("direct-open-ref-frame-sizing");
    const local_name = try rt.internAtom("value");
    defer rt.atoms.free(function_name);
    defer rt.atoms.free(local_name);

    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, function_name);
    defer fd.deinit(rt);
    _ = try fd.appendScope(-1);
    _ = try fd.addScopeVar(local_name, .normal, 0, false, false);

    var function = bytecode.Bytecode.init(&rt.memory, &rt.atoms, function_name);
    defer function.deinit(rt);
    var code = [_]u8{0} ** 14;
    code[0] = bytecode.opcode.op.scope_make_ref;
    std.mem.writeInt(u32, code[1..5], local_name, .little);
    std.mem.writeInt(u32, code[5..9], 0, .little);
    std.mem.writeInt(u16, code[9..11], 0, .little);
    code[11] = bytecode.opcode.op.get_ref_value;
    code[12] = bytecode.opcode.op.drop;
    code[13] = bytecode.opcode.op.return_undef;
    try function.setCode(&code);
    try function.retainAtomOperand(local_name);

    try finalizeMutableWithTestRealm(&function, &fd, rt);

    try std.testing.expectEqual(@as(u16, 1), function.open_var_ref_count);
    try std.testing.expect(fd.vars[0].is_captured);
    try std.testing.expectEqual(bytecode.opcode.op.make_loc_ref, function.code[0]);
}

test "mapped frames use the exact compile-time open-binding count for every frame kind" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const function_name = try rt.internAtom("mapped-arg-open-ref-frame-sizing");
    defer rt.atoms.free(function_name);
    var function = bytecode.Bytecode.init(&rt.memory, &rt.atoms, function_name);
    defer function.deinit(rt);
    function.open_var_ref_count = 2;
    function.flags.has_mapped_arguments = true;
    var execution_adapter: bytecode.LegacyExecutionAdapter = undefined;

    try std.testing.expectEqual(@as(usize, 2), frame_mod.frameOpenVarRefStorageCount(execution_adapter.init(&function)));
    function.flags.is_generator = true;
    try std.testing.expectEqual(@as(usize, 2), frame_mod.frameOpenVarRefStorageCount(execution_adapter.init(&function)));
    function.flags.is_generator = false;
    function.flags.is_async = true;
    try std.testing.expectEqual(@as(usize, 2), frame_mod.frameOpenVarRefStorageCount(execution_adapter.init(&function)));
    function.flags.is_async = false;
    function.flags.has_mapped_arguments = false;
    try std.testing.expectEqual(@as(usize, 2), frame_mod.frameOpenVarRefStorageCount(execution_adapter.init(&function)));

    const open_count: usize = 2;
    const storage_len = try frame_mod.FrameSlab.requiredStorageSlots(5, 0, 2, 3, 3, open_count);
    const storage = try rt.memory.alloc(core.JSValue, storage_len);
    defer rt.memory.free(core.JSValue, storage);
    const slab = frame_mod.FrameSlab.partitionStorage(storage, 5, 0, 2, 3, 3, open_count);
    try std.testing.expectEqual(@as(usize, 5), slab.args.len);
    try std.testing.expectEqual(@as(usize, 3), slab.var_refs.len);
    try std.testing.expectEqual(open_count, slab.open_var_refs.len);
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(slab.open_var_refs.ptr) % @alignOf(?*core.VarRef));
    for (slab.open_var_refs) |entry| try std.testing.expect(entry == null);
}

test "createFunctionBytecode: final declaration metadata lives only in ClosureVar" {
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
    _ = try fd.addClosureVar(.{
        .closure_type = .global_decl,
        .is_lexical = true,
        .is_const = true,
        .var_idx = 0,
        .var_name = global_name,
    });

    const fb_slice = try createTestFunctionBytecode(&fd, rt);
    const fb = &fb_slice[0];
    defer core.JSValue.functionBytecode(&fb.header).free(rt);

    try std.testing.expectEqual(@as(usize, 1), fb.closureVar().len);
    try std.testing.expectEqual(global_name, fb.closureVar()[0].var_name);
    try std.testing.expectEqual(function_def.ClosureType.global_decl, fb.closureVar()[0].closureType());
    try std.testing.expect(fb.closureVar()[0].isLexical());
    try std.testing.expect(fb.closureVar()[0].isConst());

    try std.testing.expectEqual(@as(usize, 1), fb.closureVar().len);
    try std.testing.expectEqual(global_name, fb.closureVar()[0].var_name);
    try std.testing.expectEqual(function_def.ClosureType.global_decl, fb.closureVar()[0].closureType());
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
    _ = try fd.appendScope(-1);

    const body = [_]u8{bytecode.opcode.op.return_undef};
    try fd.appendByteCode(&body);

    const source = try std.testing.allocator.alloc(u8, large_threshold);
    defer std.testing.allocator.free(source);
    @memset(source, 'x');
    try fd.replaceSourceText(source);

    const realm = try core.RealmContext.create(rt);
    var realm_alive = true;
    defer if (realm_alive) realm.destroy();
    const before_fb = rt.gcStats();
    const fb_slice = try pipeline.finalize.createFunctionBytecode(&fd, .{ .realm = realm });
    const fb = &fb_slice[0];
    var fb_alive = true;
    defer if (fb_alive) core.JSValue.functionBytecode(&fb.header).free(rt);
    realm.destroy();
    realm_alive = false;

    const heap_bytes = fb.heapByteSize();
    try std.testing.expect(heap_bytes >= large_threshold);
    // This function's base+debug+tables+exact-code+extension FAM is slab-backed;
    // its metadata size_class is the allocator's slab index, while GC heap
    // accounting asks the live FB for the main payload plus independent source.
    try std.testing.expect(fb.header.meta().flags.metadata_in_slab);

    const stats = rt.gcStats();
    try std.testing.expectEqual(before_fb.large_alloc_count + 1, stats.large_alloc_count);
    try std.testing.expectEqual(before_fb.large_allocated_bytes + heap_bytes, stats.large_allocated_bytes);
    try std.testing.expectEqual(before_fb.heap_live_bytes + heap_bytes, stats.heap_live_bytes);
    try std.testing.expectEqual(before_fb.large_object_bytes + heap_bytes, stats.large_object_bytes);
    try std.testing.expect(stats.large_committed_bytes >= heap_bytes);
    try std.testing.expectEqual(stats.large_committed_bytes, stats.heap_committed_bytes);
    try std.testing.expectEqual(before_fb.old_alloc_count, stats.old_alloc_count);
    // Heap object allocations no longer feed the weighted allocation_debt:
    // js_trigger_gc pacing rides on memory.allocated_bytes vs malloc_gc_threshold
    // (runtime.zig), and allocation_debt is reserved for the off-heap external
    // memory trigger (reportExternalAlloc). A large heap payload therefore leaves
    // the debt untouched.
    try std.testing.expectEqual(@as(usize, 0), stats.allocation_debt);

    core.JSValue.functionBytecode(&fb.header).free(rt);
    fb_alive = false;
    const after_free = rt.gcStats();
    try std.testing.expectEqual(@as(usize, 0), after_free.total_allocated_bytes);
    try std.testing.expectEqual(@as(usize, 0), after_free.peak_allocated_bytes);
    try std.testing.expectEqual(@as(usize, 0), after_free.large_allocated_bytes);
    try std.testing.expectEqual(@as(usize, 0), after_free.large_alloc_count);
    try std.testing.expectEqual(@as(usize, 0), after_free.heap_live_bytes);
    try std.testing.expectEqual(@as(usize, 0), after_free.large_object_bytes);
    // Large-space committed follows live_bytes to zero the moment the payload is
    // freed (derived on demand); the freed bytes are returned to the backing
    // allocator directly, so there is no separately-tracked decommit hysteresis.
    try std.testing.expectEqual(@as(usize, 0), after_free.large_committed_bytes);
    try std.testing.expectEqual(@as(usize, 0), after_free.decommitted_bytes);
}

fn populateFunctionDefForFinalizeFailure(
    fd: *function_def.FunctionDef,
    name: atom_module.Atom,
    arg_name: atom_module.Atom,
    captured_name: atom_module.Atom,
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
    const source_text = "function oom_inner(oom_arg) {}";
    try fd.replaceSourceText(source_text);
}

fn runFunctionBytecodeFinalizeOomLifecycle(allocator: std.mem.Allocator) !void {
    const rt = try core.JSRuntime.create(allocator);
    var rt_owned = true;
    errdefer if (rt_owned) rt.destroy();

    const realm = try core.RealmContext.create(rt);
    var realm_owned = true;
    errdefer if (realm_owned) realm.destroy();

    const name = try rt.internAtom("oom-finalize-function");
    var name_owned = true;
    errdefer if (name_owned) rt.atoms.free(name);
    const arg_name = try rt.internAtom("oom-finalize-arg");
    var arg_name_owned = true;
    errdefer if (arg_name_owned) rt.atoms.free(arg_name);
    const captured_name = try rt.internAtom("oom-finalize-captured");
    var captured_name_owned = true;
    errdefer if (captured_name_owned) rt.atoms.free(captured_name);
    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    var fd_owned = true;
    errdefer if (fd_owned) fd.deinit(rt);
    _ = try fd.appendScope(-1);
    try populateFunctionDefForFinalizeFailure(&fd, name, arg_name, captured_name);

    const fb_slice = try pipeline.finalize.createFunctionBytecode(&fd, .{ .realm = realm });
    const fb = &fb_slice[0];
    var fb_owned = true;
    errdefer if (fb_owned) core.JSValue.functionBytecode(&fb.header).free(rt);
    if (fb.sourceText() == null) {
        return error.TestUnexpectedResult;
    }

    core.JSValue.functionBytecode(&fb.header).free(rt);
    fb_owned = false;
    fd.deinit(rt);
    fd_owned = false;
    rt.atoms.free(captured_name);
    captured_name_owned = false;
    rt.atoms.free(arg_name);
    arg_name_owned = false;
    rt.atoms.free(name);
    name_owned = false;
    realm.destroy();
    realm_owned = false;
    rt.destroy();
    rt_owned = false;
}

test "private class identity has no bytecode side metadata carrier" {
    try std.testing.expect(!@hasDecl(bytecode.function_bytecode, "ClassMeta"));
    try std.testing.expect(!@hasDecl(bytecode.function_bytecode, "FunctionBytecodeSideExtension"));
    try std.testing.expect(!@hasField(bytecode.function_def.FunctionDef, "private_bound_names"));
    try std.testing.expect(!@hasField(bytecode.function_def.FunctionDef, "class_private_names"));
    try std.testing.expect(!@hasField(bytecode.Bytecode, "private_bound_names"));
    try std.testing.expect(!@hasField(bytecode.Bytecode, "class_private_names"));
    try std.testing.expect(!@hasField(bytecode.FunctionLayout, "side_off"));
    try std.testing.expect(!@hasField(bytecode.LegacyExecutionAdapter, "side_extension"));
    try std.testing.expect(@hasField(bytecode.LegacyExecutionAdapter, "legacy_bytecode_adapter"));
}

test "createFunctionBytecode exhaustively rolls back every precommit allocation failure" {
    try runFunctionBytecodeFinalizeOomLifecycle(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        runFunctionBytecodeFinalizeOomLifecycle,
        .{},
    );
}

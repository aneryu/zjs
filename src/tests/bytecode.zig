//! Exercises bytecode carriers, label resolution, and constant-pool ownership.
const std = @import("std");
const zjs = @import("zjs");
const engine = zjs;
const bytecode = zjs.bytecode;
const core = zjs.core;
const compiler = zjs.compiler;
const frame_mod = zjs.exec.frame;
const parser = zjs.parser;
const parser_tests = @import("parser.zig");
const helpers = @import("helpers.zig");

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
    try emitTestBody(&fd, &.{bytecode.opcode.op.return_undef}, &.{});
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
    // The published FB is the referrer atom's second owner, and the atom table
    // only balances when the FB is torn down -- which the tracer defers to a
    // collection. Nothing names the FB from here on, so the collection reaches
    // it; `function` and `fd` are native-stack carriers the sweep never visits.
    helpers.reclaimNow(rt);
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

/// Give a hand-built FunctionDef the compact producer finalization requires.
/// There is one compiler and one lowering input: a FunctionDef with no
/// attached Builder is rejected by `prepareCurrentBeforeChildren`, so every
/// fixture that reaches the finalizer must emit through this.
/// The Builder is owned by the FunctionDef and released by `fd.deinit`.
fn attachV2Builder(fd: *function_def.FunctionDef) !*compiler.Builder {
    if (fd.v2_builder) |existing| return existing;
    const b = try fd.memory.create(compiler.Builder);
    b.* = compiler.Builder.init(fd.memory, fd.atoms);
    fd.v2_builder = b;
    return b;
}

/// Replay a literal instruction sequence into `fd`'s v2 Builder. This is the
/// V2-equivalent of the `fd.appendByteCode` fixtures the deleted legacy
/// pipeline accepted: the same instructions, delivered through the only
/// producer the compiler reads. Atom operands are taken from `atoms` in
/// stream order and retained by the builder.
///
/// Label-bearing operands are deliberately unsupported: in the producer they
/// are LabelId identities, not addresses, so a fixture that needs one emits it
/// directly with `emitJump` / `emitScopeRefOpOwned`.
fn emitTestBody(
    fd: *function_def.FunctionDef,
    code: []const u8,
    atoms: []const core.Atom,
) !void {
    const b = try attachV2Builder(fd);
    const opcode = bytecode.opcode;
    var pc: usize = 0;
    var atom_index: usize = 0;
    while (pc < code.len) {
        const op_id = code[pc];
        const size: usize = opcode.sizeOfPhase1(op_id);
        if (size == 0 or pc + size > code.len) return error.InvalidBytecode;
        const operands = code[pc + 1 ..][0 .. size - 1];
        switch (opcode.formatOfPhase1(op_id)) {
            // Non-atom operands are replayed by width, so a multi-field form
            // (`npop_u16` is u16 npop + u16 value) produces the same bytes as
            // the literal it was written from instead of silently losing a
            // field to a name-based mapping.
            .none,
            .none_int,
            .none_loc,
            .none_arg,
            .none_var_ref,
            .u8,
            .i8,
            .loc8,
            .const8,
            .npop,
            .npopx,
            .u16,
            .i16,
            .npop_u16,
            .loc,
            .arg,
            .var_ref,
            .u32,
            .@"const",
            .i32,
            => switch (operands.len) {
                0 => try b.emitOp(op_id),
                1 => try b.emitOpU8(op_id, operands[0]),
                2 => try b.emitOpU16(op_id, std.mem.readInt(u16, operands[0..2], .little)),
                4 => try b.emitOpU32(op_id, std.mem.readInt(u32, operands[0..4], .little)),
                else => return error.InvalidBytecode,
            },
            .atom => {
                const a = atoms[atom_index];
                atom_index += 1;
                try b.emitAtomOpOwned(op_id, fd.atoms.dup(a));
            },
            .atom_u8 => {
                const a = atoms[atom_index];
                atom_index += 1;
                try b.emitAtomOpU8Owned(op_id, fd.atoms.dup(a), operands[4]);
            },
            .atom_u16 => {
                const a = atoms[atom_index];
                atom_index += 1;
                try b.emitAtomOpU16Owned(
                    op_id,
                    fd.atoms.dup(a),
                    std.mem.readInt(u16, operands[4..6], .little),
                );
            },
            else => return error.InvalidBytecode,
        }
        pc += size;
    }
    if (atom_index != atoms.len) return error.InvalidBytecode;
}

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
        try std.testing.expectEqual(
            @as(usize, 88),
            @sizeOf(bytecode.FunctionBytecode),
        );
        try std.testing.expectEqual(@as(usize, 8), @alignOf(bytecode.FunctionBytecode));
        try std.testing.expectEqual(case.fam_bytes, fb.famBytes());
        try std.testing.expectEqual(@sizeOf(bytecode.FunctionBytecode) + case.fam_bytes, fb.layout().mainPayloadBytes());
        try std.testing.expectEqual(fb.layout().mainPayloadBytes(), fb.heapByteSize());
        try std.testing.expectEqual(case.debug, fb.hasDebug());
        try std.testing.expectEqual(case.extension, fb.hasExtension());
        try std.testing.expect(fb.legacyBytecodeAdapter() == null);
        try std.testing.expectEqual(@as(usize, 0), @intFromPtr(fb) % 8);
        try std.testing.expectEqual(@as(usize, 8), @intFromPtr(fb) - @intFromPtr(fb.header.meta()));
        try std.testing.expectEqual(core.gc.GcKind.function_bytecode, fb.header.meta().flags.kind);
        try helpers.expectRefCount(1, &fb.header);
        try std.testing.expect(!fb.header.meta().alloc_info.standalone);

        try std.testing.expect(fb.byte_code == null);
        try std.testing.expect(fb.vardefs == null);
        try std.testing.expect(fb.closure_var == null);
        try std.testing.expect(fb.cpool == null);
        try std.testing.expectEqual(@as(i32, 0), fb.byte_code_len);
        try std.testing.expectEqual(@as(i32, 0), fb.cpool_count);
        try std.testing.expectEqual(@as(i32, 0), fb.closure_var_count);
        try std.testing.expectEqual(@as(u8, 0), fb._flag_padding0);
        try std.testing.expectEqual(@as(u16, 0), @as(u16, @bitCast(fb.call_facts_mirror)));
        try std.testing.expectEqualSlices(u8, &.{ 0, 0 }, &fb._flag_padding);
        try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0, 0 }, &fb._realm_padding);
        try std.testing.expectEqual(@as(u8, 0), fb.flag_byte18 & bytecode.FunctionBytecode.byte18_rom_mask);
        try std.testing.expectEqual(@as(u8, 0), fb.flag_byte18 & 0x80);

        if (fb.debugInfo()) |dbg| {
            try std.testing.expectEqual(
                @intFromPtr(fb) + @sizeOf(bytecode.FunctionBytecode),
                @intFromPtr(dbg),
            );
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
        @as(usize, 64),
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
    try std.testing.expectEqual(
        @as(usize, 8),
        @offsetOf(bytecode.function_bytecode.FunctionBytecodeHotExtension, "ctor_alloc"),
    );
}

test "FunctionLayout matches the QJS-order core pack" {
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
    const expected_cpool_off = @sizeOf(bytecode.FunctionBytecode) +
        @sizeOf(bytecode.function_bytecode.DebugInfo);
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

    // Only the QJS core pack carries fidelity: the zjs hot tail is appended at
    // code end, so the totals are pinned relative to `byte_code_end` instead of
    // re-hardcoding the extension's own (zjs-owned) width.
    const hot_bytes = @sizeOf(bytecode.function_bytecode.FunctionBytecodeHotExtension);
    const trace_layout_delta: usize = 8;
    switch (value_size) {
        16 => {
            try std.testing.expectEqual(@as(usize, 0x80) - trace_layout_delta, layout.cpool_off);
            try std.testing.expectEqual(@as(usize, 0xa0) - trace_layout_delta, layout.vardefs_off);
            try std.testing.expectEqual(@as(usize, 0xc4) - trace_layout_delta, layout.closure_var_off);
            try std.testing.expectEqual(@as(usize, 0xd4) - trace_layout_delta, layout.byte_code_off);
            try std.testing.expectEqual(@as(usize, 0xd7) - trace_layout_delta, layout.byte_code_end);
            try std.testing.expectEqual(@as(?usize, 0xd7 - trace_layout_delta), layout.hot_off);
            try std.testing.expectEqual(@as(usize, 0xd7) - trace_layout_delta + hot_bytes, layout.total_size);
            try std.testing.expectEqual(@as(usize, 0x77) + hot_bytes, layout.famBytes());
        },
        8 => {
            try std.testing.expectEqual(@as(usize, 0x80) - trace_layout_delta, layout.cpool_off);
            try std.testing.expectEqual(@as(usize, 0x90) - trace_layout_delta, layout.vardefs_off);
            try std.testing.expectEqual(@as(usize, 0xb4) - trace_layout_delta, layout.closure_var_off);
            try std.testing.expectEqual(@as(usize, 0xc4) - trace_layout_delta, layout.byte_code_off);
            try std.testing.expectEqual(@as(usize, 0xc7) - trace_layout_delta, layout.byte_code_end);
            try std.testing.expectEqual(@as(?usize, 0xc7 - trace_layout_delta), layout.hot_off);
            try std.testing.expectEqual(@as(usize, 0xc7) - trace_layout_delta + hot_bytes, layout.total_size);
            try std.testing.expectEqual(@as(usize, 0x67) + hot_bytes, layout.famBytes());
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
        try std.testing.expectEqual(@sizeOf(bytecode.FunctionBytecode), actual.byte_code_off);
        try std.testing.expectEqual(@sizeOf(bytecode.FunctionBytecode) + code_len, actual.byte_code_end);
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
            const exact_code_end = @sizeOf(bytecode.FunctionBytecode) + 3;
            try std.testing.expectEqual(exact_code_end, actual.byte_code_end);
            try std.testing.expectEqual(@as(?usize, exact_code_end), actual.hot_off);
            try std.testing.expectEqual(
                exact_code_end + @sizeOf(bytecode.function_bytecode.FunctionBytecodeHotExtension),
                actual.total_size,
            );
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
        @as(usize, 64),
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
    const hot_bytes = @sizeOf(bytecode.function_bytecode.FunctionBytecodeHotExtension);
    const expected_code_end: usize = 0x74;
    try std.testing.expectEqual(expected_code_end, layout.byte_code_end);
    try std.testing.expectEqual(@as(?usize, expected_code_end), layout.hot_off);
    try std.testing.expectEqual(expected_code_end + hot_bytes, layout.total_size);
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
    first._flag_padding0 = 0xaa;
    first.call_facts_mirror = @bitCast(@as(u16, 0xaaaa));
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
    first.hotExtensionMut().?.ctor_alloc = .{ .capacity = 0xffff, .state = .live };
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
    try std.testing.expectEqual(@as(u8, 0), second._flag_padding0);
    try std.testing.expectEqual(@as(u16, 0), @as(u16, @bitCast(second.call_facts_mirror)));
    try std.testing.expectEqualSlices(u8, &.{ 0, 0 }, &second._flag_padding);
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
    try std.testing.expectEqual(
        bytecode.function_bytecode.CtorAllocState.empty,
        second.hotExtension().?.ctor_alloc.state,
    );
    try std.testing.expectEqual(@as(u16, 0), second.hotExtension().?.ctor_alloc.capacity);
    try std.testing.expectEqual(core.gc.GcKind.function_bytecode, second.header.meta().flags.kind);
    try helpers.expectRefCount(1, &second.header);
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
    fd: *function_def.FunctionDef,
    rt: *core.JSRuntime,
) !void {
    const realm = try core.RealmContext.create(rt);
    defer realm.destroy();
    return pipeline.finalize.runWithFunctionDefRuntime(function, fd, .{ .realm = realm });
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

test "FunctionDef final scope proof reseals late arguments links and rejects cycles" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("scope-proof-arguments");
    const parameter = try rt.internAtom("parameter");
    defer rt.atoms.free(name);
    defer rt.atoms.free(parameter);

    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);
    _ = try fd.appendScope(-1);
    _ = try fd.appendScope(-1);
    fd.has_parameter_expressions = true;
    const parameter_idx = try fd.addScopeVar(parameter, .normal, 1, true, false);
    try fd.rebuildFinalScopeLinks();
    try fd.validateFinalScopeLinks();

    // This is the same late mutation a parameter-initializer descendant can
    // trigger after its parent has been prepared.  The helper must return with
    // a complete proof boundary restored for later sibling/parent resolution.
    try fd.ensureArgumentsArgumentBinding();
    try fd.validateFinalScopeLinks();
    try std.testing.expect(fd.arguments_arg_idx > parameter_idx);
    try std.testing.expectEqual(fd.arguments_arg_idx, fd.scopes[1].first);
    try std.testing.expectEqual(
        parameter_idx,
        fd.vars[@intCast(fd.arguments_arg_idx)].scope_next,
    );
    try std.testing.expectEqual(
        bytecode.function_bytecode.arg_scope_end,
        fd.vars[@intCast(parameter_idx)].scope_next,
    );

    // Even the idempotent early-return arm validates first; a synthetic caller
    // cannot smuggle a cyclic chain into the trusted production specialization.
    fd.vars[@intCast(fd.arguments_arg_idx)].scope_next = fd.arguments_arg_idx;
    try std.testing.expectError(error.InvalidScope, fd.validateFinalScopeLinks());
    try std.testing.expectError(error.InvalidScope, fd.ensureArgumentsArgumentBinding());
}

test "compiler-v2 run rejects cyclic scope links before trusted lookup" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("scope-proof-run");
    const local = try rt.internAtom("local");
    defer rt.atoms.free(name);
    defer rt.atoms.free(local);

    var function = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer function.deinit(rt);
    var fd = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer fd.deinit(rt);
    _ = try fd.appendScope(-1);
    const local_idx = try fd.addScopeVar(local, .normal, 0, false, false);
    try fd.rebuildFinalScopeLinks();

    const input = try attachV2Builder(&fd);
    try input.emitAtomOpU16Owned(
        bytecode.opcode.op.scope_get_var,
        rt.atoms.dup(local),
        0,
    );
    try input.emitOp(bytecode.opcode.op.return_undef);

    fd.vars[@intCast(local_idx)].scope_next = local_idx;
    try std.testing.expectError(
        error.InvalidBytecode,
        compiler.resolve_variables.run(&function, &fd),
    );
}

test "compiler-v2 parent miss proves corrupt and cyclic synthetic ancestors" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("scope-proof-parent-run");
    const requested = try rt.internAtom("requested");
    const parent_local = try rt.internAtom("parent-local");
    defer rt.atoms.free(name);
    defer rt.atoms.free(requested);
    defer rt.atoms.free(parent_local);

    var function = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer function.deinit(rt);
    var parent = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer parent.deinit(rt);
    _ = try parent.appendScope(-1);
    const parent_local_idx = try parent.addScopeVar(parent_local, .normal, 0, false, false);
    try parent.rebuildFinalScopeLinks();

    var child = function_def.FunctionDef.init(&rt.memory, &rt.atoms, name);
    defer child.deinit(rt);
    _ = try child.appendScope(-1);
    try child.rebuildFinalScopeLinks();
    child.parent = &parent;
    child.parent_scope_level = 0;

    const input = try attachV2Builder(&child);
    try input.emitAtomOpU16Owned(
        bytecode.opcode.op.scope_get_var,
        rt.atoms.dup(requested),
        0,
    );
    try input.emitOp(bytecode.opcode.op.return_undef);

    // A forged lifecycle state must not act as a proof capability.
    child.finalization_state = .prepared;
    parent.finalization_state = .prepared;
    parent.vars[@intCast(parent_local_idx)].scope_next = parent_local_idx;
    try std.testing.expectError(
        error.InvalidBytecode,
        compiler.resolve_variables.run(&function, &child),
    );

    parent.vars[@intCast(parent_local_idx)].scope_next = -1;
    parent.parent = &parent;
    try std.testing.expectError(
        error.InvalidBytecode,
        compiler.resolve_variables.run(&function, &child),
    );
    parent.parent = null;
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

test "resolve_labels converges for a large branch topology" {
    const branch_count = 2048;
    const branch_source = "if (input) { value += 1; } else { value -= 1; }";

    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(std.testing.allocator);
    try source.ensureTotalCapacity(
        std.testing.allocator,
        "function targetTopologyProbe(input) { let value = 0; ".len +
            branch_count * branch_source.len +
            "return value; }".len,
    );
    try source.appendSlice(
        std.testing.allocator,
        "function targetTopologyProbe(input) { let value = 0; ",
    );
    for (0..branch_count) |_| {
        try source.appendSlice(std.testing.allocator, branch_source);
    }
    try source.appendSlice(std.testing.allocator, "return value; }");

    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    rt.updateNativeStackTop();
    const realm = try core.RealmContext.create(rt);
    defer realm.destroy();

    var parsed = try parser.compile(
        .{ .realm = realm },
        source.items,
        .{ .mode = .script, .filename = "large-branch-topology.js" },
    );
    defer parsed.deinit();
    try std.testing.expect(parsed.syntax_error == null);
}

test "finalize: runs the full v2 lowering pipeline" {
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

    // The same instruction sequence the legacy phase-1 fixture used, emitted
    // through the only producer the compiler reads:
    // enter_scope <idx=0> ; scope_get_var <x> <scope_level=0> ; label ;
    // return_undef ; leave_scope <idx=0>
    const b = try attachV2Builder(&fd);
    try b.emitOpU16(op.enter_scope, 0);
    try b.emitAtomOpU16Owned(op.scope_get_var, rt.atoms.dup(x_atom), 0);
    const tail = try b.newLabel();
    try b.bindLabel(tail);
    try b.emitOp(op.return_undef);
    try b.emitOpU16(op.leave_scope, 0);

    try finalizeMutableWithTestRealm(&bc, &fd, rt);

    // Expected: get_var <var_ref x> ; return_undef (3 + 1 = 4 bytes)
    // enter_scope, leave_scope, and the label should all be dropped
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
    try emitTestBody(child, &.{bytecode.opcode.op.return_undef}, &.{});
    child.parent_cpool_idx = @intCast(try parent.appendCpool(core.JSValue.undefinedValue()));
    try parent.addChild(child);
    child_owned = false;

    // The post-order walk publishes the valid child first. The parent's
    // reachable falloff is rejected only when its own lowering runs.
    try emitTestBody(&parent, &.{bytecode.opcode.op.nop}, &.{});
    try std.testing.expectError(
        error.InvalidBytecode,
        pipeline.finalize.createFunctionBytecode(&parent, .{ .realm = realm }),
    );

    try std.testing.expect(parent.cpool[0].isFunctionBytecode());
    const child_header = parent.cpool[0].objectHeader() orelse return error.TestExpectedEqual;
    const child_fb: *bytecode.FunctionBytecode = @alignCast(@fieldParentPtr("header", child_header));
    try std.testing.expectEqual(realm, child_fb.realmContext());
    try helpers.expectRefCount(2, &realm.header);

    // The failed parent FunctionDef still owns the installed cpool value.
    // Releasing that owner must drop the child's independent RealmRef exactly
    // once; no partially-created parent FB may retain another reference.
    parent.deinit(rt);
    parent_alive = false;
    // The child's RealmRef is dropped by the child's own teardown, not by the
    // cpool release that orphans it, so under the tracer the drop lands in the
    // collection. The realm survives it as a live host handle on the runtime's
    // context list; the orphaned child is named by nothing and is reclaimed.
    helpers.reclaimNow(rt);
    try helpers.expectRefCount(1, &realm.header);
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
    try emitTestBody(&fd, &.{bytecode.opcode.op.return_undef}, &.{});
    _ = try fd.appendCpool(child_value);
    child_value.free(rt);
    child_value_alive = false;
    const child_rc_before = helpers.refCountSnapshot(&child_fb.header);
    if (comptime !core.gc.refCountRemoved(.function_bytecode))
        try std.testing.expectEqual(@as(i32, 1), child_rc_before);

    const parent_slice = try pipeline.finalize.createFunctionBytecode(&fd, .{ .realm = realm });
    const parent_fb = &parent_slice[0];
    var parent_alive = true;
    defer if (parent_alive) core.JSValue.functionBytecode(&parent_fb.header).free(rt);

    try std.testing.expect(fd.cpool[0].isUndefined());
    try helpers.expectRefCount(child_rc_before, &child_fb.header);
    try std.testing.expectEqual(child_fb.header.asHeader(), parent_fb.cpoolSlice()[0].objectHeader().?);

    fd.deinit(rt);
    fd_alive = false;
    try helpers.expectRefCount(child_rc_before, &child_fb.header);
    try std.testing.expectEqual(name, child_fb.funcName());
    try std.testing.expectEqual(child_fb.header.asHeader(), parent_fb.cpoolSlice()[0].objectHeader().?);

    const held_child = parent_fb.cpoolSlice()[0].dup();
    var held_child_alive = true;
    defer if (held_child_alive) held_child.free(rt);
    const realm_refs_before_parent_free = helpers.refCountSnapshot(&realm.header);
    {
        // `held_child` is the child's only remaining owner once the parent is
        // gone, and it is a Zig local the declared_only scan cannot see.
        // Without this frame the collection that stands in for the parent's
        // teardown would take the child with it, and both realm references
        // would come off at once instead of one per owner.
        var child_roots = [_]core.runtime.HeaderRootValue{.{ .header = &child_fb.header }};
        var child_frame = core.runtime.ValueRootFrame{ .headers = &child_roots };
        child_frame.activate(rt);
        defer child_frame.deactivate(rt);

        core.JSValue.functionBytecode(&parent_fb.header).free(rt);
        parent_alive = false;
        helpers.reclaimNow(rt);
        try helpers.expectRefCount(child_rc_before, &child_fb.header);
        try helpers.expectRefCount(realm_refs_before_parent_free - 1, &realm.header);
    }
    held_child.free(rt);
    held_child_alive = false;
    helpers.reclaimNow(rt);
    try helpers.expectRefCount(1, &realm.header);
}

// ---- F10.1b: FunctionDef-driven local-slot lowering ----

// ---- F10.2: short-form selection (`put_short_code` mirror) ----

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
    const b = try attachV2Builder(&fd);
    try b.emitAtomOpOwned(op.push_atom_value, rt.atoms.dup(name));
    // The marker lands on the instruction boundary just past the 5-byte
    // push_atom_value; the source-loc entry contract rejects mid-instruction pcs.
    try b.addSourceMarker(8, 5);
    try b.emitOp(op.to_number);
    try b.emitOp(op.drop);
    try b.emitOpU16(op.get_var, 0);
    try b.emitOp(op.drop);
    try b.emitOp(op.return_undef);
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
    try std.testing.expectEqual(
        @intFromPtr(fb) + @sizeOf(bytecode.FunctionBytecode),
        @intFromPtr(fb.debugInfo().?),
    );
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
    try std.testing.expectEqual(op.to_number, fb.byteCode()[5]);
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

test "finalize rejects a same-count mismatched inline atom owner before transfer" {
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
    const b = try attachV2Builder(&fd);
    try b.emitAtomOpOwned(op.push_atom_value, rt.atoms.dup(encoded_atom));
    try b.emitOp(op.drop);
    try b.emitOp(op.return_undef);
    // Desynchronise the ledger from the inline operand bytes. The producer
    // writes both from one owned value, so this state is only reachable by
    // corrupting the stream after emission -- which is precisely the
    // invariant the finalizer's owner check exists to catch.
    rt.atoms.free(b.atom_operands[0]);
    b.atom_operands[0] = rt.atoms.dup(ledger_atom);

    const encoded_refs = rt.atoms.refCount(encoded_atom).?;
    const ledger_refs = rt.atoms.refCount(ledger_atom).?;
    try std.testing.expectError(error.InvalidBytecode, createTestFunctionBytecode(&fd, rt));

    // Rejection transfers nothing and releases nothing: both owners are still
    // exactly where they were before the call, for `fd.deinit` to reclaim.
    try std.testing.expectEqual(encoded_refs, rt.atoms.refCount(encoded_atom).?);
    try std.testing.expectEqual(ledger_refs, rt.atoms.refCount(ledger_atom).?);
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
    try emitTestBody(&failed_fd, &.{bytecode.opcode.op.return_undef}, &.{});
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
    try emitTestBody(&recovery_fd, &.{bytecode.opcode.op.return_undef}, &.{});
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
    try emitTestBody(&fd, &.{bytecode.opcode.op.return_undef}, &.{});

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
        @as(usize, 160),
        @sizeOf(bytecode.LegacyExecutionAdapter),
    );
    // The negative sentinel deliberately keeps this borrowed stack bridge out
    // of canonical count-based FunctionLayout reconstruction. Its hot tail and
    // borrowed pointer follow the active FunctionBytecode body even though the
    // mirrored table counts and borrowed code are all non-empty. The body size
    // is the offset authority in both representations.
    try std.testing.expectEqual(
        @sizeOf(bytecode.FunctionBytecode) +
            @sizeOf(bytecode.function_bytecode.FunctionBytecodeHotExtension),
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
        try emitTestBody(&fd, &.{bytecode.opcode.op.return_undef}, &.{});

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
        try emitTestBody(&fd, &.{bytecode.opcode.op.return_undef}, &.{});

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
        try emitTestBody(&fd, &.{bytecode.opcode.op.return_undef}, &.{});

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
        try emitTestBody(&fd, &.{bytecode.opcode.op.return_undef}, &.{});

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
        // V2 materializes the arguments object from FunctionDef identity in
        // its S4 prologue. Model the parser-owned binding instead of injecting
        // the retired phase-1 prologue bytes into the compact producer.
        _ = try fd.ensureArgumentsBinding();
        try emitTestBody(&fd, &.{bytecode.opcode.op.return_undef}, &.{});

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
            try emitTestBody(child, &child_code, &.{arg_name});
            child.parent_scope_level = 0;
            child.parent_cpool_idx = @intCast(try fd.appendCpool(core.JSValue.undefinedValue()));
            try fd.addChild(child);
            child_owned = false;
        }
        try emitTestBody(&fd, &.{bytecode.opcode.op.return_undef}, &.{});

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
        try emitTestBody(&fd, &.{bytecode.opcode.op.return_undef}, &.{});
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
        try emitTestBody(&fd, &.{bytecode.opcode.op.return_undef}, &.{});

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
        try emitTestBody(&fd, &.{bytecode.opcode.op.return_undef}, &.{});
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
        try emitTestBody(&fd, &.{bytecode.opcode.op.return_undef}, &.{});
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
        try emitTestBody(&fd, &.{bytecode.opcode.op.return_undef}, &.{});
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

test "stack_size scratch stays on stack through 256 positions and falls back at 257" {
    const op = bytecode.opcode.op;

    var inline_code = [_]u8{op.nop} ** 256;
    inline_code[inline_code.len - 1] = op.return_undef;
    var fail_inline = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectEqual(
        @as(u16, 0),
        try stack_size.compute(&inline_code, .{ .scratch_allocator = fail_inline.allocator() }),
    );
    try std.testing.expect(!fail_inline.has_induced_failure);

    var fallback_code = [_]u8{op.nop} ** 257;
    fallback_code[fallback_code.len - 1] = op.return_undef;
    var fail_fallback = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.OutOfMemory,
        stack_size.compute(&fallback_code, .{ .scratch_allocator = fail_fallback.allocator() }),
    );
    try std.testing.expect(fail_fallback.has_induced_failure);

    try std.testing.expectEqual(
        @as(u16, 0),
        try stack_size.compute(&fallback_code, .{ .scratch_allocator = std.testing.allocator }),
    );
}

test "stack_size allocation-free LIFO handles multiple pending successors" {
    const op = bytecode.opcode.op;

    // Each conditional seeds a distinct return target while fall-through
    // reaches the next conditional. Four target PCs are therefore pending
    // simultaneously before the LIFO starts draining them.
    const code = [_]u8{
        op.push_1,       op.if_false8,    10,
        op.push_1,       op.if_false8,    8,
        op.push_1,       op.if_false8,    6,
        op.push_1,       op.if_false8,    4,
        op.return_undef, op.return_undef, op.return_undef,
        op.return_undef,
    };
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectEqual(
        @as(u16, 1),
        try stack_size.compute(&code, .{ .scratch_allocator = failing.allocator() }),
    );
    try std.testing.expect(!failing.has_induced_failure);
}

test "stack verifier rejects reachable end edges" {
    const op = bytecode.opcode.op;

    var jump_to_end = [_]u8{0} ** 5;
    jump_to_end[0] = op.goto;
    std.mem.writeInt(i32, jump_to_end[1..5], 4, .little);
    try std.testing.expectError(error.ReachableFalloff, stack_size.compute(&jump_to_end, .{}));
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
        try emitTestBody(&fd, &unbalanced_body, &.{});
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
        try emitTestBody(&fd, &balanced_body, &.{});
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
        try emitTestBody(&fd, &unbalanced_body, &.{});
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
        try emitTestBody(&fd, &unbalanced_body, &.{});
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
    try emitTestBody(&fd, &code, &.{});
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

    // `scope_make_ref` carries a LabelId in the producer, not an address, so
    // the reference tail is a real label identity bound after the read.
    const b = try attachV2Builder(&fd);
    const ref_tail = try b.newLabel();
    try b.emitScopeRefOpOwned(
        bytecode.opcode.op.scope_make_ref,
        rt.atoms.dup(local_name),
        ref_tail,
        0,
    );
    try b.emitOp(bytecode.opcode.op.get_ref_value);
    try b.bindLabel(ref_tail);
    try b.emitOp(bytecode.opcode.op.drop);
    try b.emitOp(bytecode.opcode.op.return_undef);

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

    // `scope_make_ref` carries a LabelId in the producer, not an address, so
    // the reference tail is a real label identity bound after the read.
    const b = try attachV2Builder(&fd);
    const ref_tail = try b.newLabel();
    try b.emitScopeRefOpOwned(
        bytecode.opcode.op.scope_make_ref,
        rt.atoms.dup(function_name),
        ref_tail,
        0,
    );
    try b.emitOp(bytecode.opcode.op.get_ref_value);
    try b.bindLabel(ref_tail);
    try b.emitOp(bytecode.opcode.op.drop);
    try b.emitOp(bytecode.opcode.op.return_undef);

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

    // `scope_make_ref` carries a LabelId in the producer, not an address, so
    // the reference tail is a real label identity bound after the read.
    const b = try attachV2Builder(&fd);
    const ref_tail = try b.newLabel();
    try b.emitScopeRefOpOwned(
        bytecode.opcode.op.scope_make_ref,
        rt.atoms.dup(arg_name),
        ref_tail,
        0,
    );
    try b.emitOp(bytecode.opcode.op.get_ref_value);
    try b.bindLabel(ref_tail);
    try b.emitOp(bytecode.opcode.op.drop);
    try b.emitOp(bytecode.opcode.op.return_undef);

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
    // `scope_make_ref` carries a LabelId in the producer, not an address, so
    // the reference tail is a real label identity bound after the read.
    const b = try attachV2Builder(&fd);
    const ref_tail = try b.newLabel();
    try b.emitScopeRefOpOwned(
        bytecode.opcode.op.scope_make_ref,
        rt.atoms.dup(local_name),
        ref_tail,
        0,
    );
    try b.emitOp(bytecode.opcode.op.get_ref_value);
    try b.bindLabel(ref_tail);
    try b.emitOp(bytecode.opcode.op.drop);
    try b.emitOp(bytecode.opcode.op.return_undef);

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

    try emitTestBody(&fd, &.{bytecode.opcode.op.return_undef}, &.{});
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
    const rt = try core.JSRuntime.createWithOptions(std.testing.allocator, .{
        .gc_policy = .{
            .large_object_threshold = large_threshold,
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
    try emitTestBody(&fd, &body, &.{});

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
    try std.testing.expect(!fb.header.meta().alloc_info.standalone);

    const stats = rt.gcStats();
    try std.testing.expectEqual(before_fb.large_alloc_count + 1, stats.large_alloc_count);
    try std.testing.expectEqual(before_fb.large_allocated_bytes + heap_bytes, stats.large_allocated_bytes);
    try std.testing.expectEqual(before_fb.heap_live_bytes + heap_bytes, stats.heap_live_bytes);
    try std.testing.expectEqual(before_fb.large_object_bytes + heap_bytes, stats.large_object_bytes);
    try std.testing.expectEqual(before_fb.old_alloc_count, stats.old_alloc_count);
    // Heap object allocations no longer feed the weighted allocation_debt:
    // js_trigger_gc pacing rides on memory.allocated_bytes vs malloc_gc_threshold
    // (runtime.zig), and allocation_debt is reserved for the off-heap external
    // memory trigger (reportExternalAlloc). A large heap payload therefore leaves
    // the debt untouched.
    try std.testing.expectEqual(@as(usize, 0), stats.allocation_debt);

    core.JSValue.functionBytecode(&fb.header).free(rt);
    fb_alive = false;
    // Large-space accounting is unwound by the FB's teardown, which the tracer
    // defers to a collection. `fd` handed its owners to the FB and holds no
    // heap bytes of its own, so the ledger is expected to reach zero here.
    helpers.reclaimNow(rt);
    const after_free = rt.gcStats();
    try std.testing.expectEqual(@as(usize, 0), after_free.total_allocated_bytes);
    // High-water: survives the free rather than echoing live-now.
    try std.testing.expect(after_free.peak_allocated_bytes > 0);
    try std.testing.expectEqual(@as(usize, 0), after_free.large_allocated_bytes);
    try std.testing.expectEqual(@as(usize, 0), after_free.large_alloc_count);
    try std.testing.expectEqual(@as(usize, 0), after_free.heap_live_bytes);
    try std.testing.expectEqual(@as(usize, 0), after_free.large_object_bytes);
}

fn populateFunctionDefForFinalizeFailure(
    fd: *function_def.FunctionDef,
    name: atom_module.Atom,
    arg_name: atom_module.Atom,
    captured_name: atom_module.Atom,
) !void {
    const op = bytecode.opcode.op;
    const b = try attachV2Builder(fd);
    try b.emitAtomOpOwned(op.push_atom_value, fd.atoms.dup(name));
    // The marker lands on the instruction boundary just past the 5-byte
    // push_atom_value; the source-loc entry contract rejects mid-instruction pcs.
    try b.addSourceMarker(8, 5);
    try b.emitOp(op.drop);
    try b.emitOpU16(op.get_var, 0);
    try b.emitOp(op.drop);
    try b.emitOp(op.return_undef);
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

test "installCodeWithCapacity/installAtomOperandsWithCapacity account the full backing across replacement and deinit" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("capacity-carry-replacement");
    defer rt.atoms.free(name);
    const base_bytes = rt.memory.allocated_bytes;
    const base_count = rt.memory.allocation_count;
    const base_refs = rt.atoms.refCount(name).?;

    var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    var bc_live = true;
    defer if (bc_live) bc.deinit(rt);
    const pre_install_refs = rt.atoms.refCount(name).?;

    const first_code = [_]u8{ 1, 2, 3, 4, 5 };
    const first_code_backing = try rt.memory.alloc(u8, 16);
    @memcpy(first_code_backing[0..first_code.len], &first_code);
    bc.installCodeWithCapacity(first_code_backing[0..first_code.len], first_code_backing.len);
    try std.testing.expectEqual(@as(usize, 5), bc.code.len);
    try std.testing.expectEqual(@as(usize, 16), bc.code_capacity);
    try std.testing.expectEqualSlices(u8, &first_code, bc.code);

    const first_atom_backing = try rt.memory.alloc(core.atom.Atom, 8);
    for (first_atom_backing[0..3]) |*slot| slot.* = rt.atoms.dup(name);
    bc.installAtomOperandsWithCapacity(first_atom_backing[0..3], first_atom_backing.len);
    try std.testing.expectEqual(@as(usize, 3), bc.atom_operands.len);
    try std.testing.expectEqual(@as(usize, 8), bc.atom_operands_capacity);
    try std.testing.expectEqual(pre_install_refs + 3, rt.atoms.refCount(name).?);

    const second_code = [_]u8{ 9, 8 };
    const second_code_backing = try rt.memory.alloc(u8, 6);
    @memcpy(second_code_backing[0..second_code.len], &second_code);
    const second_atom_backing = try rt.memory.alloc(core.atom.Atom, 6);
    for (second_atom_backing[0..2]) |*slot| slot.* = rt.atoms.dup(name);

    for (bc.atom_operands) |old| rt.atoms.free(old);
    bc.installAtomOperandsWithCapacity(second_atom_backing[0..2], second_atom_backing.len);
    bc.installCodeWithCapacity(second_code_backing[0..second_code.len], second_code_backing.len);

    try std.testing.expectEqual(@as(usize, 2), bc.code.len);
    try std.testing.expectEqual(@as(usize, 6), bc.code_capacity);
    try std.testing.expectEqualSlices(u8, &second_code, bc.code);
    try std.testing.expectEqual(@as(usize, 2), bc.atom_operands.len);
    try std.testing.expectEqual(@as(usize, 6), bc.atom_operands_capacity);
    try std.testing.expectEqual(pre_install_refs + 2, rt.atoms.refCount(name).?);

    bc.deinit(rt);
    bc_live = false;
    try std.testing.expectEqual(base_bytes, rt.memory.allocated_bytes);
    try std.testing.expectEqual(base_count, rt.memory.allocation_count);
    try std.testing.expectEqual(base_refs, rt.atoms.refCount(name).?);
}

test "capacity-carry install with zero used length still owns and frees the backing" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("capacity-carry-zero-used");
    defer rt.atoms.free(name);
    const base_bytes = rt.memory.allocated_bytes;
    const base_count = rt.memory.allocation_count;
    const base_refs = rt.atoms.refCount(name).?;

    var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    var bc_live = true;
    defer if (bc_live) bc.deinit(rt);

    const code_backing = try rt.memory.alloc(u8, 12);
    bc.installCodeWithCapacity(code_backing.ptr[0..0], code_backing.len);
    const atom_backing = try rt.memory.alloc(core.atom.Atom, 4);
    bc.installAtomOperandsWithCapacity(atom_backing.ptr[0..0], atom_backing.len);

    try std.testing.expectEqual(@as(usize, 0), bc.code.len);
    try std.testing.expectEqual(@as(usize, 12), bc.code_capacity);
    try std.testing.expectEqual(@as(usize, 0), bc.atom_operands.len);
    try std.testing.expectEqual(@as(usize, 4), bc.atom_operands_capacity);

    bc.deinit(rt);
    bc_live = false;
    try std.testing.expectEqual(base_bytes, rt.memory.allocated_bytes);
    try std.testing.expectEqual(base_count, rt.memory.allocation_count);
    try std.testing.expectEqual(base_refs, rt.atoms.refCount(name).?);
}

test "phase-3 exact-fit replacement frees the carried capacity once and releases atom refs once" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("capacity-carry-phase-3-replacement");
    defer rt.atoms.free(name);
    const base_bytes = rt.memory.allocated_bytes;
    const base_count = rt.memory.allocation_count;
    const base_refs = rt.atoms.refCount(name).?;

    var bc = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    var bc_live = true;
    defer if (bc_live) bc.deinit(rt);

    const carried_code = [_]u8{ 1, 3, 5, 7, 9 };
    const carried_code_backing = try rt.memory.alloc(u8, 16);
    @memcpy(carried_code_backing[0..carried_code.len], &carried_code);
    bc.installCodeWithCapacity(carried_code_backing[0..carried_code.len], carried_code_backing.len);

    const carried_atom_backing = try rt.memory.alloc(core.atom.Atom, 8);
    for (carried_atom_backing[0..3]) |*slot| slot.* = rt.atoms.dup(name);
    bc.installAtomOperandsWithCapacity(carried_atom_backing[0..3], carried_atom_backing.len);
    const carried_refs = rt.atoms.refCount(name).?;

    const fresh_code = try rt.memory.alloc(u8, bc.code.len);
    @memcpy(fresh_code, bc.code);
    const fresh_atoms = try rt.memory.alloc(core.atom.Atom, bc.atom_operands.len);
    for (fresh_atoms) |*slot| slot.* = rt.atoms.dup(name);
    const bytes_with_both_generations = rt.memory.allocated_bytes;
    const count_with_both_generations = rt.memory.allocation_count;

    for (bc.atom_operands) |old| rt.atoms.free(old);
    bc.installCode(fresh_code);
    bc.installAtomOperands(fresh_atoms);

    try std.testing.expectEqual(carried_refs, rt.atoms.refCount(name).?);
    const carried_code_charge = core.memory.MemoryAccount.accountedSizeForRequest(16 * @sizeOf(u8), .@"1");
    const carried_atom_charge = core.memory.MemoryAccount.accountedSizeForRequest(8 * @sizeOf(core.atom.Atom), std.mem.Alignment.of(core.atom.Atom));
    const fresh_code_charge = core.memory.MemoryAccount.accountedSizeForRequest(fresh_code.len * @sizeOf(u8), .@"1");
    const fresh_atom_charge = core.memory.MemoryAccount.accountedSizeForRequest(fresh_atoms.len * @sizeOf(core.atom.Atom), std.mem.Alignment.of(core.atom.Atom));
    try std.testing.expectEqual(
        bytes_with_both_generations - carried_code_charge - carried_atom_charge,
        rt.memory.allocated_bytes,
    );
    try std.testing.expectEqual(count_with_both_generations - 2, rt.memory.allocation_count);
    try std.testing.expectEqual(
        base_bytes + fresh_code_charge + fresh_atom_charge,
        rt.memory.allocated_bytes,
    );
    try std.testing.expectEqual(base_count + 2, rt.memory.allocation_count);

    bc.deinit(rt);
    bc_live = false;
    try std.testing.expectEqual(base_bytes, rt.memory.allocated_bytes);
    try std.testing.expectEqual(base_count, rt.memory.allocation_count);
    try std.testing.expectEqual(base_refs, rt.atoms.refCount(name).?);
}

test "four-ledger phase-boundary ownership accounting compile-only" {
    const ownership = parser_tests.phase_ownership;

    for (&ownership.shapes) |*shape| {
        const rt = try core.JSRuntime.create(std.testing.allocator);
        defer rt.destroy();

        try ownership.warmRuntime(rt, shape);

        // A realm is only needed to materialise child FunctionBytecodes. Create
        // it before the window so its own allocations and atoms sit outside the
        // measured baseline.
        const realm = try core.RealmContext.create(rt);
        defer realm.destroy();

        var window: ownership.Window = undefined;
        try window.init(rt, shape);
        defer window.deinit();

        var b1 = try window.sampleB1();
        // Parsing never publishes a FunctionBytecode; finalization is the only
        // producer. Tier 2 therefore still starts at an exact census.
        try std.testing.expectEqual(
            @as(usize, 0),
            ownership.publishedFunctionBytecodeCount(&window.function),
        );
        try std.testing.expectEqual(@as(usize, 0), try ownership.atomResidual(b1));

        // The resolver consumes the compact Builder and publishes the final
        // artifact in one step, so the intermediate resolve_variables product
        // is never observable from outside: B2 collapses into the composite
        // emit for BOTH tiers. What each tier still measures separately is the
        // residual — tier 1 publishes no FunctionBytecode and must stay at an
        // exact census; tier 2 moves ownership under published FBs.
        if (shape.tier == .nested_function_bytecode) {
            try std.testing.expect(window.state.function_def.child_list.len > 0);
        } else {
            try std.testing.expectEqual(@as(usize, 0), window.state.function_def.child_list.len);
        }
        try pipeline.finalize.runWithFunctionDefRuntime(
            &window.function,
            &window.state.function_def,
            .{ .realm = realm },
        );
        var b3 = try window.sampleNext(.final, &b1);
        // Finalization moved ownership under published FunctionBytecodes,
        // which the census does not descend into. That residual is what the
        // remaining boundaries must carry unchanged.
        const emit_residual = try ownership.atomResidual(b3);
        if (shape.tier == .nested_function_bytecode) {
            try std.testing.expect(ownership.publishedFunctionBytecodeCount(&window.function) > 0);
            try std.testing.expect(emit_residual > 0);
        } else {
            try std.testing.expectEqual(
                @as(usize, 0),
                ownership.publishedFunctionBytecodeCount(&window.function),
            );
            try std.testing.expectEqual(@as(usize, 0), emit_residual);
        }

        window.discardTemporaries();
        var b4 = try window.sampleNext(.final, &b3);
        const committed = b4.builder.owned;
        ownership.setBuilderCommitted(&b1, committed);
        ownership.setBuilderCommitted(&b3, committed);
        ownership.setBuilderCommitted(&b4, committed);

        try ownership.expectAtomAccount(b1, 0);
        try ownership.expectAtomAccount(b3, emit_residual);
        // The published-FB residual is a constant of the compile: it appears at
        // the emit boundary and must survive the temporaries discard untouched.
        try ownership.expectAtomAccount(b4, emit_residual);
        try ownership.expectAtomTransition(b1, b3, true);
        try ownership.expectAtomTransition(b3, b4, false);
        try ownership.expectB1(b1);
        try ownership.expectB3(b1, b3);
        try ownership.expectB4(b1, b3, b4);

        ownership.dump(shape.*, "compile-only", "B1-after-parse", b1);
        ownership.dump(shape.*, "compile-only", "B3-after-final-emit", b3);
        ownership.dump(shape.*, "compile-only", "B4-artifact-only", b4);

        window.releaseArtifact();
        // The emit residual lives inside the published child FunctionBytecodes,
        // whose atom owners are released by their teardown rather than by the
        // artifact release that orphans them. Under the tracer that teardown is
        // this collection, and only after it does the atom table balance.
        helpers.reclaimNow(rt);
        var terminal = try window.sampleNext(.final, &b4);
        ownership.setBuilderCommitted(&terminal, 0);
        try ownership.expectTerminal(terminal);
        ownership.dump(shape.*, "compile-only", "terminal", terminal);
    }
}

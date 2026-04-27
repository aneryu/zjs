const std = @import("std");
const engine = @import("quickjs_zig_engine");

const bytecode = engine.bytecode;
const core = engine.core;

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
    return .{
        .source = source,
        .table = bytecode.opcode.parse(source),
    };
}

test "opcode table parses QuickJS opcode file in order" {
    const parsed = try loadOpcodeTable(std.testing.allocator);
    defer std.testing.allocator.free(parsed.source);
    const table = parsed.table;

    try std.testing.expectEqual(@as(usize, 30), table.format_count);
    try std.testing.expectEqual(@as(usize, 264), table.count);
    try std.testing.expectEqual(@as(usize, 179), table.op_count);
    try std.testing.expectEqual(@as(usize, 179), table.temp_start);
    try std.testing.expectEqual(@as(usize, 197), table.short_start);

    try std.testing.expectEqual(@as(usize, 0), table.indexOf("invalid").?);
    try std.testing.expectEqual(@as(usize, 1), table.indexOf("push_i32").?);
    try std.testing.expectEqual(@as(usize, 178), table.indexOf("nop").?);
    try std.testing.expectEqual(@as(usize, 179), table.indexOf("enter_scope").?);
    try std.testing.expectEqual(@as(usize, 196), table.indexOf("source_loc").?);
    try std.testing.expectEqual(@as(usize, 197), table.indexOf("push_minus1").?);
    try std.testing.expectEqual(@as(usize, 263), table.indexOf("typeof_is_function").?);
}

test "opcode metadata exposes size format and stack effects" {
    const parsed = try loadOpcodeTable(std.testing.allocator);
    defer std.testing.allocator.free(parsed.source);
    const table = parsed.table;

    const push_i32 = table.find("push_i32").?;
    try std.testing.expectEqual(@as(u8, 5), push_i32.size);
    try std.testing.expectEqual(bytecode.opcode.Format.i32, push_i32.format);
    try std.testing.expectEqual(@as(i16, 1), push_i32.stackDelta());
    try std.testing.expectEqual(bytecode.opcode.Kind.normal, push_i32.kind);

    const call = table.find("call").?;
    try std.testing.expectEqual(bytecode.opcode.Format.npop, call.format);
    try std.testing.expectEqual(@as(u8, 3), call.size);
    try std.testing.expectEqual(@as(i16, 0), call.stackDelta());

    const source_loc = table.find("source_loc").?;
    try std.testing.expectEqual(bytecode.opcode.Kind.temp, source_loc.kind);
    try std.testing.expectEqual(bytecode.opcode.Format.u32x2, source_loc.format);

    const push_0 = table.find("push_0").?;
    try std.testing.expectEqual(bytecode.opcode.Kind.short, push_0.kind);
    try std.testing.expectEqual(bytecode.opcode.Format.none_int, push_0.format);
}

test "format metadata computes immediate operand widths" {
    try std.testing.expectEqual(@as(usize, 0), bytecode.format.describe(.none).immediateSize());
    try std.testing.expectEqual(@as(usize, 4), bytecode.format.describe(.i32).immediateSize());
    try std.testing.expectEqual(@as(usize, 5), bytecode.format.describe(.atom_u8).immediateSize());
    try std.testing.expectEqual(@as(usize, 10), bytecode.format.describe(.atom_label_u16).immediateSize());
    try std.testing.expectEqual(@as(usize, 8), bytecode.format.describe(.u32x2).immediateSize());
}

test "emitter known opcode table has no host print opcode names" {
    inline for (@typeInfo(bytecode.emitter.known).@"struct".decls) |decl| {
        try std.testing.expect(!std.mem.eql(u8, decl.name, "host_print"));
        try std.testing.expect(!std.mem.eql(u8, decl.name, "host_print_n"));
    }
}

test "constant pool retains and releases values" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    var pool = bytecode.constant.Pool.init(&rt.memory);
    defer pool.deinit(rt);

    const text = try core.string.String.createAscii(rt, "constant");
    const value = text.value();
    const index = try pool.append(value);
    try std.testing.expectEqual(@as(u32, 0), index);
    try std.testing.expectEqual(@as(usize, 2), text.header.ref_count);

    const loaded = pool.get(0).?;
    try std.testing.expectEqual(@as(usize, 3), text.header.ref_count);
    loaded.free(rt);
    value.free(rt);
}

test "function bytecode owns code constants scopes module and debug metadata" {
    const rt = try core.Runtime.create(std.testing.allocator);
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
    _ = try function_bc.addConstant(core.Value.int32(7));
    try std.testing.expectEqual(@as(usize, 1), function_bc.constants.values.len);

    const scope_record = try function_bc.addScope(null);
    _ = try scope_record.addBinding(local, .let_, true);
    _ = try scope_record.addClosureVar(local, 0, 0, false);
    try std.testing.expectEqual(@as(usize, 1), scope_record.bindings.len);
    try std.testing.expect(scope_record.bindings[0].is_lexical);
    try std.testing.expectEqual(@as(usize, 1), scope_record.closure_vars.len);

    const mod_record = function_bc.ensureModule();
    const req_index = try mod_record.addRequest(dep);
    const default_atom = core.atom.predefinedId("*default*", .string).?;
    try mod_record.addImport(req_index, default_atom, local);
    try mod_record.addExport(default_atom, local);
    try std.testing.expectEqual(@as(usize, 1), mod_record.requests.len);
    try std.testing.expectEqual(@as(usize, 1), mod_record.imports.len);
    try std.testing.expectEqual(@as(usize, 1), mod_record.exports.len);

    const dbg = function_bc.ensureDebug(filename);
    try dbg.add(.{ .pc = 0, .line = 1 });
    try dbg.add(.{ .pc = 3, .line = 2 });
    try std.testing.expectEqual(@as(?u32, 2), dbg.lineForPc(4));
}

comptime {
    _ = @import("opcode_alignment_test.zig");
}

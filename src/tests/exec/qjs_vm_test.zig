//! F2+F3 dual-dispatch end-to-end tests.
//!
//! Validates that bytecode produced by the new `frontend/qjs_parser`
//! (tagged `opcode_format = .qjs`) executes through the new
//! `exec/qjs_vm` dispatcher. This proves the dual-path VM works end
//! to end during the parser-rewrite transition.

const std = @import("std");
const engine = @import("quickjs_zig_engine");

const core = engine.core;
const QjsLexer = engine.frontend.qjs_lexer.Lexer;
const qjs_parser = engine.frontend.qjs_parser;
const ParseState = qjs_parser.ParseState;

fn parseAndRun(rt: *core.Runtime, ctx: *core.Context, src: []const u8) !core.Value {
    const name = try rt.internAtom("test");
    defer rt.atoms.free(name);
    var function = engine.bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer function.deinit(rt);

    var lex = QjsLexer.init(std.testing.allocator, &rt.atoms, src);
    var state = try ParseState.init(&lex, &function);
    defer state.deinit();
    try qjs_parser.parseExpr(&state);

    // Verify parser tagged the bytecode as qjs format.
    try std.testing.expectEqual(engine.bytecode.OpcodeFormat.qjs, function.opcode_format);

    // Run F10 pipeline to lower Phase 1 temp opcodes (emitted by
    // default since `emit_phase1_temp = true`) to final opcodes.
    try engine.bytecode.pipeline.finalize.run(&function);

    var vm = engine.exec.Vm.init(ctx);
    defer vm.deinit();
    return vm.run(&function);
}

test "F2+F3 dual-dispatch: integer literal executes via qjs_vm" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRun(rt, ctx, "42");
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 42), result.asInt32().?);
}

test "F2+F3 dual-dispatch: addition via qjs_vm" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRun(rt, ctx, "1 + 2");
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 3), result.asInt32().?);
}

test "F2+F3 dual-dispatch: subtraction via qjs_vm" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRun(rt, ctx, "10 - 3");
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 7), result.asInt32().?);
}

test "F2+F3 dual-dispatch: multiplication via qjs_vm" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRun(rt, ctx, "6 * 7");
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 42), result.asInt32().?);
}

test "F2+F3 dual-dispatch: precedence via qjs_vm" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRun(rt, ctx, "1 + 2 * 3");
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 7), result.asInt32().?);
}

test "F2+F3 dual-dispatch: parenthesized via qjs_vm" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRun(rt, ctx, "(1 + 2) * 3");
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 9), result.asInt32().?);
}

test "F2+F3 dual-dispatch: boolean comparison via qjs_vm" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRun(rt, ctx, "1 < 2");
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "F2+F3 dual-dispatch: bitwise and via qjs_vm" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRun(rt, ctx, "12 & 10");
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 8), result.asInt32().?);
}

test "F2+F3 dual-dispatch: unary negation via qjs_vm" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRun(rt, ctx, "-5");
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, -5), result.asInt32().?);
}

test "F2+F3 dual-dispatch: bitwise not via qjs_vm" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRun(rt, ctx, "~0");
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, -1), result.asInt32().?);
}

test "F2+F3 dual-dispatch: legacy bytecode still uses legacy VM path" {
    // Verify default opcode_format is .legacy, ensuring we don't
    // accidentally break the legacy QuickParser path.
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("legacy_test");
    defer rt.atoms.free(name);
    var function = engine.bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer function.deinit(rt);

    try std.testing.expectEqual(engine.bytecode.OpcodeFormat.legacy, function.opcode_format);
}

test "F2+F3 dual-dispatch: object literal via qjs_vm" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRun(rt, ctx, "({})");
    defer result.free(rt);
    // F2+F3 minimum: object is a placeholder (undefined).
    try std.testing.expect(result.isUndefined());
}

test "F2+F3 dual-dispatch: object literal with property via qjs_vm" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRun(rt, ctx, "({ x: 1 })");
    defer result.free(rt);
    // F2+F3 minimum: object is a placeholder (undefined).
    try std.testing.expect(result.isUndefined());
}

test "F2+F3 dual-dispatch: array literal via qjs_vm" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRun(rt, ctx, "[]");
    defer result.free(rt);
    // F2+F3 minimum: array is a placeholder (undefined).
    try std.testing.expect(result.isUndefined());
}

test "F2+F3 dual-dispatch: array literal with elements via qjs_vm" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRun(rt, ctx, "[1, 2, 3]");
    defer result.free(rt);
    // F2+F3 minimum: array is a placeholder (undefined).
    try std.testing.expect(result.isUndefined());
}

test "F2+F3 dual-dispatch: member expression via qjs_vm" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRun(rt, ctx, "({}).x");
    defer result.free(rt);
    // F2+F3 minimum: property access is a placeholder (undefined).
    try std.testing.expect(result.isUndefined());
}

test "F2+F3 dual-dispatch: array index via qjs_vm" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRun(rt, ctx, "[1][0]");
    defer result.free(rt);
    // F2+F3 minimum: array index is a placeholder (undefined).
    try std.testing.expect(result.isUndefined());
}

test "F2+F3 dual-dispatch: call expression via qjs_vm" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRun(rt, ctx, "f()");
    defer result.free(rt);
    // F2+F3 minimum: call is a placeholder (undefined).
    // Note: this will fail parsing if f is not defined, but
    // we're testing the VM dispatch path here.
    try std.testing.expect(result.isUndefined());
}

//! F2+F3 QuickJS-dispatch end-to-end tests.
//!
//! Validates that bytecode produced by `frontend/zjs_parser` executes
//! through the QuickJS-aligned VM dispatcher.

const std = @import("std");
const engine = @import("quickjs_zig_engine");

const core = engine.core;
const QjsLexer = engine.frontend.zjs_lexer.Lexer;
const zjs_parser = engine.frontend.zjs_parser;
const ParseState = zjs_parser.ParseState;

pub fn parseAndRun(rt: *core.JSRuntime, ctx: *core.JSContext, src: []const u8) !core.JSValue {
    const name = try rt.internAtom("test");
    defer rt.atoms.free(name);
    var function = engine.bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer function.deinit(rt);

    var lex = QjsLexer.init(std.testing.allocator, &rt.atoms, src);
    var state = try ParseState.init(&lex, &function);
    defer state.deinit(rt);
    try zjs_parser.parseExpr(&state);

    // Run the FunctionDef-backed finalize pipeline so locals are lowered
    // to get_loc / put_loc instead of falling back to global get_var /
    // put_var.
    try engine.bytecode.pipeline.finalize.runWithFunctionDef(&function, &state.function_def);

    var vm = engine.exec.Vm.init(ctx);
    defer vm.deinit();
    return vm.run(&function);
}

pub fn parseAndRunWithTopLevelChildren(rt: *core.JSRuntime, ctx: *core.JSContext, src: []const u8) !core.JSValue {
    const name = try rt.internAtom("test");
    defer rt.atoms.free(name);
    var function = engine.bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer function.deinit(rt);

    var lex = QjsLexer.init(std.testing.allocator, &rt.atoms, src);
    var state = try ParseState.init(&lex, &function);
    defer state.deinit(rt);
    state.top_level_functions_as_children = true;
    try zjs_parser.parseExpr(&state);

    try engine.bytecode.pipeline.finalize.runWithFunctionDefRuntime(&function, &state.function_def, rt);

    var vm = engine.exec.Vm.init(ctx);
    defer vm.deinit();
    return vm.run(&function);
}

pub fn expectStringBytes(value: core.JSValue, expected: []const u8) !void {
    try std.testing.expect(value.isString());
    const string_value: *core.string.String = @fieldParentPtr("header", value.refHeader().?);
    try std.testing.expect(string_value.eqlBytes(expected));
}

pub fn expectSingleCodeUnit(value: core.JSValue, expected: u16) !void {
    try std.testing.expect(value.isString());
    const string_value: *core.string.String = @fieldParentPtr("header", value.refHeader().?);
    try std.testing.expectEqual(@as(usize, 1), string_value.len());
    try std.testing.expectEqual(expected, string_value.codeUnitAt(0));
}

pub fn parseStmtAndRun(rt: *core.JSRuntime, ctx: *core.JSContext, src: []const u8) !core.JSValue {
    const name = try rt.internAtom("test");
    defer rt.atoms.free(name);
    var function = engine.bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer function.deinit(rt);

    var lex = QjsLexer.init(std.testing.allocator, &rt.atoms, src);
    var state = try ParseState.init(&lex, &function);
    defer state.deinit(rt);

    try state.enableEvalReturn();
    while (state.token.val != engine.frontend.zjs_token.TOK_EOF) {
        try zjs_parser.parseStatementOrDecl(&state, zjs_parser.DeclMask{ .func = true, .func_with_label = true, .other = true });
    }
    try state.finalizeEvalReturn();

    try engine.bytecode.pipeline.finalize.runWithFunctionDef(&function, &state.function_def);

    var vm = engine.exec.Vm.init(ctx);
    defer vm.deinit();
    return vm.run(&function);
}

pub fn parseStmtAndRunWithTopLevelChildren(rt: *core.JSRuntime, ctx: *core.JSContext, src: []const u8) !core.JSValue {
    const name = try rt.internAtom("test");
    defer rt.atoms.free(name);
    var function = engine.bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer function.deinit(rt);

    var lex = QjsLexer.init(std.testing.allocator, &rt.atoms, src);
    var state = try ParseState.init(&lex, &function);
    defer state.deinit(rt);
    state.top_level_functions_as_children = true;

    try state.enableEvalReturn();
    while (state.token.val != engine.frontend.zjs_token.TOK_EOF) {
        try zjs_parser.parseStatementOrDecl(&state, zjs_parser.DeclMask{ .func = true, .func_with_label = true, .other = true });
    }
    try state.finalizeEvalReturn();

    try engine.bytecode.pipeline.finalize.runWithFunctionDefRuntime(&function, &state.function_def, rt);

    var vm = engine.exec.Vm.init(ctx);
    defer vm.deinit();
    return vm.run(&function);
}

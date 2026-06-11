const std = @import("std");
const engine = @import("quickjs_zig_engine");

const core = engine.core;
const QjsLexer = engine.frontend.qjs_lexer.Lexer;
const qjs_parser = engine.frontend.qjs_parser;
const ParseState = qjs_parser.ParseState;

const helpers = @import("qjs_vm_helpers.zig");
const parseAndRun = helpers.parseAndRun;
const parseAndRunWithTopLevelChildren = helpers.parseAndRunWithTopLevelChildren;
const parseStmtAndRun = helpers.parseStmtAndRun;
const parseStmtAndRunWithTopLevelChildren = helpers.parseStmtAndRunWithTopLevelChildren;
const expectStringBytes = helpers.expectStringBytes;
const expectSingleCodeUnit = helpers.expectSingleCodeUnit;
test "F2+F3 qjs dispatcher: object literal with property via qjs_vm" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRun(rt, ctx, "({ x: 1 })");
    defer result.free(rt);
    const object: *core.Object = @fieldParentPtr("header", result.refHeader().?);
    const key = try rt.internAtom("x");
    defer rt.atoms.free(key);
    const value = object.getProperty(key);
    defer value.free(rt);
    try std.testing.expectEqual(@as(i32, 1), value.asInt32().?);
}

test "F2+F3 qjs dispatcher: array literal via qjs_vm" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRun(rt, ctx, "[]");
    defer result.free(rt);
    const object: *core.Object = @fieldParentPtr("header", result.refHeader().?);
    try std.testing.expect(object.flags.is_array);
    try std.testing.expectEqual(@as(u32, 0), object.length);
}

test "F2+F3 qjs dispatcher: array literal with elements via qjs_vm" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRun(rt, ctx, "[1, 2, 3]");
    defer result.free(rt);
    const object: *core.Object = @fieldParentPtr("header", result.refHeader().?);
    try std.testing.expect(object.flags.is_array);
    try std.testing.expectEqual(@as(u32, 3), object.length);
}

test "F2+F3 qjs dispatcher: member expression via qjs_vm" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRun(rt, ctx, "({}).x");
    defer result.free(rt);
    // F2+F3 minimum: property access is a placeholder (undefined).
    try std.testing.expect(result.isUndefined());
}

test "F2+F3 qjs dispatcher: array index via qjs_vm" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRun(rt, ctx, "[1][0]");
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 1), result.asInt32().?);
}

test "M2.3: qjs_vm reads primitive string index properties" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRun(rt, ctx, "\"abc\"[1]");
    defer result.free(rt);
    try expectStringBytes(result, "b");
}

test "M2.3: qjs_vm preserves UTF-16 code units for string index properties" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRun(rt, ctx, "String.fromCharCode(256)[0]");
    defer result.free(rt);
    try expectSingleCodeUnit(result, 0x100);
}

test "M2.3: qjs_parser records function-local while back edge against child bytecode" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx, "(function f(){ var s = \"\"; var i = 0; while (i < 4) { s = \"0\" + s; i++; } return s; })()");
    defer result.free(rt);
    try expectStringBytes(result, "0000");
}

test "M2.3: qjs_parser records function-local do while back edge against child bytecode" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx, "(function f(){ var s = \"\"; var i = 0; do { s = \"0\" + s; i++; } while (i < 4); return s; })()");
    defer result.free(rt);
    try expectStringBytes(result, "0000");
}

test "M2.3: sloppy yield identifier before division is not parsed as regexp" {
    var js = try engine.Engine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [32]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var yield = 12, a = 3, b = 6, g = 2;
        \\var yieldParsedAsIdentifier = false;
        \\yield /a;
        \\yieldParsedAsIdentifier = true;
        \\b/g;
        \\print(yieldParsedAsIdentifier);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("true\n", stream.buffered());
}

test "F2+F3 qjs dispatcher: unresolved call expression fails through qjs_vm" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    try std.testing.expectError(error.ReferenceError, parseAndRun(rt, ctx, "f()"));
}

test "M1.3: nested FunctionDef child runs through fclosure and call" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx, "(function outer(){ function inner(){ return 42; } return inner(); })()");
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 42), result.asInt32().?);
}

test "M1.3: nested FunctionDef function expression captures parent var" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx, "(function outer(){ var a = 41; return (function inner(){ return a + 1; })(); })()");
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 42), result.asInt32().?);
}

test "M1.3: nested FunctionDef capture observes parent write after closure creation" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx, "(function outer(){ var a; var f = function inner(){ return a + 1; }; a = 41; return f(); })()");
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 42), result.asInt32().?);
}

test "M1.3: nested FunctionDef captured parent var survives returned closure" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx, "(function outer(){ var a = 41; return function inner(){ return a + 1; }; })()()");
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 42), result.asInt32().?);
}

test "M1.3: returned closure can update and return captured counter" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx,
        \\(function(){
        \\  function counter() {
        \\    let n = 0;
        \\    return function next() { n++; return n; };
        \\  }
        \\  var next = counter();
        \\  return next() * 100 + next() * 10 + next();
        \\})()
    );
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 123), result.asInt32().?);
}

test "M1.3: nested FunctionDef declaration captures var declared later" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx, "(function outer(){ function inner(){ return a + 1; } var a = 41; return inner(); })()");
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 42), result.asInt32().?);
}

test "M1.3: function-body var predeclare skips nested function bodies" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx, "(function outer(){ function ignored(){ var a = 1; } function inner(){ return a + 1; } var a = 41; return inner(); })()");
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 42), result.asInt32().?);
}

test "M1.3: nested FunctionDef captures parent argument" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx, "(function outer(a){ return function inner(){ return a + 1; }; })(41)()");
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 42), result.asInt32().?);
}

test "M1.3: nested FunctionDef captured argument observes parent write" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx, "(function outer(a){ var f = function inner(){ return a + 1; }; a = 41; return f(); })(1)");
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 42), result.asInt32().?);
}

test "M1.3: nested FunctionDef captures grandparent var through ref chain" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx, "(function outer(){ var a = 41; return (function middle(){ return function inner(){ return a + 1; }; })()(); })()");
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 42), result.asInt32().?);
}

test "M1.3: nested FunctionDef grandparent ref observes outer write" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx, "(function outer(){ var a = 1; var f = (function middle(){ return function inner(){ return a + 1; }; })(); a = 41; return f(); })()");
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 42), result.asInt32().?);
}

test "M1.3: nested FunctionDef writes captured parent var" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx, "(function outer(){ var a = 1; function inner(){ a = 41; } inner(); return a + 1; })()");
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 42), result.asInt32().?);
}

test "M1.3: nested FunctionDef writes captured parent argument" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx, "(function outer(a){ function inner(){ a = 41; } inner(); return a + 1; })(1)");
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 42), result.asInt32().?);
}

test "M1.3: nested FunctionDef writes captured grandparent var through ref chain" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx, "(function outer(){ var a = 1; var f = (function middle(){ return function inner(){ a = 41; }; })(); f(); return a + 1; })()");
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 42), result.asInt32().?);
}

test "M1.3: nested FunctionDef declaration is callable before declaration" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx, "(function outer(){ return inner(); function inner(){ return 42; } })()");
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 42), result.asInt32().?);
}

test "M2: function-body var predeclare skips template substitutions" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx, "(function f(actual){ var x = `${actual}`; return 42; })(1)");
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 42), result.asInt32().?);
}

test "M2: FunctionDef child reparent keeps nested sibling closure valid" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx, "(function outer(){ function first(){ return function inner(){ return a + 1; }; } function second(){ return 0; } var a = 41; return first()(); })()");
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 42), result.asInt32().?);
}

// =====================================================================
// F10.1b — local variable lowering (scope_get_var → get_loc) end-to-end
// =====================================================================

test "F10.1b: var x; x returns undefined (locals init to undefined)" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseStmtAndRun(rt, ctx, "var x; x");
    defer result.free(rt);
    try std.testing.expect(result.isUndefined());
}

test "F10.1b: top-level var_count populated from global vars" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const name = try rt.internAtom("test");
    defer rt.atoms.free(name);
    var function = engine.bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer function.deinit(rt);

    var lex = QjsLexer.init(std.testing.allocator, &rt.atoms, "var a; var b; var c;");
    var state = try ParseState.init(&lex, &function);
    defer state.deinit(rt);
    while (state.token.val != engine.frontend.qjs_token.TOK_EOF) {
        try qjs_parser.parseStatementOrDecl(&state, qjs_parser.DeclMask{ .func = true, .func_with_label = true, .other = true });
    }
    try engine.bytecode.pipeline.finalize.runWithFunctionDef(&function, &state.function_def);

    // Top-level `var` declarations are global bindings, not local slots.
    try std.testing.expectEqual(@as(u16, 0), function.var_count);
    try std.testing.expectEqual(@as(i32, 3), state.function_def.global_var_count);
}

test "F10.1b: top-level scope_get_var lowers to get_var for global var" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const name = try rt.internAtom("test");
    defer rt.atoms.free(name);
    var function = engine.bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer function.deinit(rt);

    var lex = QjsLexer.init(std.testing.allocator, &rt.atoms, "var x; x");
    var state = try ParseState.init(&lex, &function);
    defer state.deinit(rt);
    while (state.token.val != engine.frontend.qjs_token.TOK_EOF) {
        try qjs_parser.parseStatementOrDecl(&state, qjs_parser.DeclMask{ .func = true, .func_with_label = true, .other = true });
    }
    try engine.bytecode.pipeline.finalize.runWithFunctionDef(&function, &state.function_def);

    // Top-level `var` is a global object binding, so reads stay get_var.
    const op = engine.bytecode.opcode.op;
    var found_get_loc_short = false;
    var found_get_var = false;
    var i: usize = 0;
    while (i < function.code.len) : (i += 1) {
        const opc = function.code[i];
        if (opc == op.get_loc0 or opc == op.get_loc1 or opc == op.get_loc2 or
            opc == op.get_loc3 or opc == op.get_loc8 or opc == op.get_loc)
        {
            found_get_loc_short = true;
        }
        if (opc == op.get_var) found_get_var = true;
    }
    try std.testing.expect(!found_get_loc_short);
    try std.testing.expect(found_get_var);
}

test "F10.1b: scope_get_var stays get_var for unknown identifiers" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const name = try rt.internAtom("test");
    defer rt.atoms.free(name);
    var function = engine.bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer function.deinit(rt);

    // `globalUndefined` is not declared anywhere → must fall back to
    // global get_var (5-byte atom form), not get_loc.
    var lex = QjsLexer.init(std.testing.allocator, &rt.atoms, "globalUndefined");
    var state = try ParseState.init(&lex, &function);
    defer state.deinit(rt);
    try qjs_parser.parseExpr(&state);
    try engine.bytecode.pipeline.finalize.runWithFunctionDef(&function, &state.function_def);

    const op = engine.bytecode.opcode.op;
    // First opcode should be get_var (5-byte atom form).
    try std.testing.expectEqual(op.get_var, function.code[0]);
    try std.testing.expectEqual(@as(u16, 0), function.var_count);
}

// =====================================================================
// F10.1c — let/const/var initialisers actually store to local slots
// =====================================================================

test "F10.1c: var x = 1; x returns 1" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseStmtAndRun(rt, ctx, "var x = 1; x");
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 1), result.asInt32().?);
}

test "F10.1c: let x = 42; x returns 42" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseStmtAndRun(rt, ctx, "let x = 42; x");
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 42), result.asInt32().?);
}

test "F10.1c: const k = 7; k returns 7" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseStmtAndRun(rt, ctx, "const k = 7; k");
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 7), result.asInt32().?);
}

test "F10.1c: arithmetic with locals: var a=2; var b=3; a+b returns 5" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseStmtAndRun(rt, ctx, "var a = 2; var b = 3; a + b");
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 5), result.asInt32().?);
}

test "F10.1c: reassignment: var x = 1; x = 2; x returns 2" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseStmtAndRun(rt, ctx, "var x = 1; x = 2; x");
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 2), result.asInt32().?);
}

// =====================================================================
// TDZ — Temporal Dead Zone for let/const
// =====================================================================

test "TDZ: let x; x returns undefined (initialised by declaration)" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    // `let x;` runs `set_loc_uninitialized` then `put_loc_check_init`
    // with undefined, so by the time `x` is read the slot is
    // initialised — should return undefined, not throw.
    const result = try parseStmtAndRun(rt, ctx, "let x; x");
    defer result.free(rt);
    try std.testing.expect(result.isUndefined());
}

test "TDZ: let x = 99; x returns 99 (init clears TDZ)" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseStmtAndRun(rt, ctx, "let x = 99; x");
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 99), result.asInt32().?);
}

test "TDZ: const k = 11; k = 22 throws on TDZ-checked write to const after init" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    try std.testing.expectError(error.TypeError, parseStmtAndRun(rt, ctx, "const k = 11; k = 22;"));
}

test "TDZ: compound and update writes to const throw TypeError" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    try std.testing.expectError(error.TypeError, parseStmtAndRun(rt, ctx, "const k = 11; k += 1;"));
    try std.testing.expectError(error.TypeError, parseStmtAndRun(rt, ctx, "const k = 11; k **= 2;"));
    try std.testing.expectError(error.TypeError, parseStmtAndRun(rt, ctx, "const k = 11; ++k;"));
    try std.testing.expectError(error.TypeError, parseStmtAndRun(rt, ctx, "const k = 11; k++;"));
}

test "TDZ: closure write to captured const throws TypeError" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    try std.testing.expectError(error.TypeError, parseStmtAndRunWithTopLevelChildren(rt, ctx,
        \\const k = 11;
        \\function f() { k = 22; }
        \\f();
    ));
}

test "TDZ: closure update and return of captured const throws TypeError" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    try std.testing.expectError(error.TypeError, parseStmtAndRunWithTopLevelChildren(rt, ctx,
        \\const k = 11;
        \\function f() { k++; return k; }
        \\f();
    ));
}

test "TDZ: destructured const write after init throws TypeError" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    try std.testing.expectError(error.TypeError, parseStmtAndRun(rt, ctx, "const [k] = [11]; k = 22;"));
}

test "TDZ: for-of const head write in body throws TypeError" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    try std.testing.expectError(error.TypeError, parseStmtAndRun(rt, ctx, "for (const k of [11]) { k = 22; }"));
}

test "TDZ: var x = 1; x reads via plain get_loc (no TDZ check)" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    // `var` slots are NOT lexical, so the pipeline emits short-form
    // get_loc0 (not get_loc_check). Verify by inspecting bytecode.
    const name = try rt.internAtom("test");
    defer rt.atoms.free(name);
    var function = engine.bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer function.deinit(rt);

    var lex = QjsLexer.init(std.testing.allocator, &rt.atoms, "var x = 1; x");
    var state = try ParseState.init(&lex, &function);
    defer state.deinit(rt);
    while (state.token.val != engine.frontend.qjs_token.TOK_EOF) {
        try qjs_parser.parseStatementOrDecl(&state, qjs_parser.DeclMask{ .func = true, .func_with_label = true, .other = true });
    }
    try engine.bytecode.pipeline.finalize.runWithFunctionDef(&function, &state.function_def);

    // Search for any TDZ ops — should NOT find any for var.
    const op = engine.bytecode.opcode.op;
    var i: usize = 0;
    while (i < function.code.len) : (i += 1) {
        const opc = function.code[i];
        try std.testing.expect(opc != op.set_loc_uninitialized);
        try std.testing.expect(opc != op.get_loc_check);
        try std.testing.expect(opc != op.put_loc_check);
        try std.testing.expect(opc != op.put_loc_check_init);
    }
}

test "TDZ: lexical prologue emits set_loc_uninitialized for let only" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const name = try rt.internAtom("test");
    defer rt.atoms.free(name);
    var function = engine.bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer function.deinit(rt);

    // 1 var + 2 let → expect 2 set_loc_uninitialized (for the lets).
    var lex = QjsLexer.init(std.testing.allocator, &rt.atoms, "var v; let a; let b;");
    var state = try ParseState.init(&lex, &function);
    defer state.deinit(rt);
    while (state.token.val != engine.frontend.qjs_token.TOK_EOF) {
        try qjs_parser.parseStatementOrDecl(&state, qjs_parser.DeclMask{ .func = true, .func_with_label = true, .other = true });
    }
    try engine.bytecode.pipeline.finalize.runWithFunctionDef(&function, &state.function_def);

    const op = engine.bytecode.opcode.op;
    var count: u32 = 0;
    var i: usize = 0;
    while (i < function.code.len) : (i += 1) {
        if (function.code[i] == op.set_loc_uninitialized) count += 1;
    }
    try std.testing.expectEqual(@as(u32, 2), count);
}

// =====================================================================
// eval_ret_idx — production eval-mode return-value plumbing
// =====================================================================
//
// Validates that `enableEvalReturn` / `finalizeEvalReturn` (mirroring
// `set_eval_ret_undefined` `quickjs.c:28219` and the OP_put_loc
// pattern at `quickjs.c:28966`) correctly route every expression
// statement's value through the synthetic `<ret>` slot, replacing
// the prior test-only "strip trailing drop" hack.

test "eval_ret: 1 + 2 * 3 returns 7 (single expression)" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseStmtAndRun(rt, ctx, "1 + 2 * 3");
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 7), result.asInt32().?);
}

test "eval_ret: 1; 2; 3 returns 3 (last expression wins)" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    // QuickJS eval semantics: each expression statement updates
    // <ret>, so the last one wins.
    const result = try parseStmtAndRun(rt, ctx, "1; 2; 3");
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 3), result.asInt32().?);
}

test "eval_ret: empty script returns undefined" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    // <ret> is initialised to undefined by enableEvalReturn so an
    // empty script (no expressions) still returns a sensible value.
    const result = try parseStmtAndRun(rt, ctx, "");
    defer result.free(rt);
    try std.testing.expect(result.isUndefined());
}

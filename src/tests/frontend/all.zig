const std = @import("std");
const engine = @import("quickjs_zig_engine");

const core = engine.core;
const frontend = engine.frontend;

test "lexer tokenizes keywords private names literals templates and regexp" {
    var lex = frontend.lexer.Lexer.init("class C { #x = 0b1010n; s = 'a\\n'; t = `hi`; r = /a[b]/gi; }");

    var saw_class = false;
    var saw_private = false;
    var saw_bigint = false;
    var saw_string = false;
    var saw_template = false;
    var saw_regexp = false;

    while (true) {
        const tok = try lex.next();
        if (tok.kind == .eof) break;
        if (tok.isKeyword(.class)) saw_class = true;
        if (tok.kind == .private_identifier and std.mem.eql(u8, tok.lexeme, "#x")) saw_private = true;
        if (tok.kind == .bigint and std.mem.eql(u8, tok.lexeme, "0b1010n")) saw_bigint = true;
        if (tok.kind == .string) saw_string = true;
        if (tok.kind == .template_no_substitution) saw_template = true;
        if (tok.kind == .regexp and std.mem.eql(u8, tok.lexeme, "/a[b]/gi")) saw_regexp = true;
    }

    try std.testing.expect(saw_class);
    try std.testing.expect(saw_private);
    try std.testing.expect(saw_bigint);
    try std.testing.expect(saw_string);
    try std.testing.expect(saw_template);
    try std.testing.expect(saw_regexp);
}

test "source positions and syntax errors carry filename line and column" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try frontend.parser.parse(rt, "let x = (\n1", .{ .mode = .script, .filename = "bad.js" });
    defer parsed.deinit();

    try std.testing.expect(parsed.syntax_error != null);
    try std.testing.expectEqual(@as(u32, 2), parsed.syntax_error.?.position.line);
    try std.testing.expectEqualStrings("Unexpected end of input", parsed.syntax_error.?.message);
    try std.testing.expectEqualStrings("bad.js", rt.atoms.name(parsed.syntax_error.?.filename).?);
}

test "script parse mode emits bytecode metadata without AST execution" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try frontend.parser.parse(rt, "var x = 1; x + 2;", .{ .mode = .script, .filename = "script.js" });
    defer parsed.deinit();

    try std.testing.expect(parsed.syntax_error == null);
    try std.testing.expect(!parsed.function.flags.is_strict);
    try std.testing.expect(parsed.hasFeature(.statement));
    try std.testing.expect(parsed.hasFeature(.expression));
    try std.testing.expect(parsed.function.code.len > 0);
    try std.testing.expect(parsed.function.scopes.len == 1);
    try std.testing.expect(parsed.function.constants.values.len == 0);
}

test "module parse mode records import export metadata and strict flag" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try frontend.parser.parse(rt, "import x from 'm'; export { x };", .{ .mode = .module, .filename = "mod.js" });
    defer parsed.deinit();

    try std.testing.expect(parsed.syntax_error == null);
    try std.testing.expect(parsed.function.flags.is_strict);
    try std.testing.expect(parsed.function.module_record != null);
    try std.testing.expect(parsed.function.module_record.?.requests.len >= 1);
    try std.testing.expect(parsed.function.module_record.?.imports.len >= 1);
    try std.testing.expect(parsed.function.module_record.?.exports.len >= 1);
}

test "eval function class private destructuring spread async generator features are recorded" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try frontend.parser.parse(
        rt,
        "async function *f(...args) { class C { #x; method(){ return args[0]; } } let {x} = args[0]; yield x; await x; import('m'); }",
        .{ .mode = .eval_direct, .filename = "eval.js" },
    );
    defer parsed.deinit();

    try std.testing.expect(parsed.direct_eval);
    try std.testing.expect(parsed.hasFeature(.async_function));
    try std.testing.expect(parsed.hasFeature(.function_));
    try std.testing.expect(parsed.hasFeature(.generator));
    try std.testing.expect(parsed.hasFeature(.class_));
    try std.testing.expect(parsed.hasFeature(.private_name));
    try std.testing.expect(parsed.hasFeature(.destructuring));
    try std.testing.expect(parsed.hasFeature(.spread_rest));
    try std.testing.expect(parsed.hasFeature(.dynamic_import));
}

test "emitter writes opcode metadata and constants through Phase 4 structures" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("emit");
    defer rt.atoms.free(name);

    var function_bc = engine.bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer function_bc.deinit(rt);
    var emit = engine.bytecode.emitter.Emitter.init(&function_bc);

    const text = try core.string.String.createAscii(rt, "hello");
    const value = text.value();
    const const_index = try emit.emitPushConst(value);
    value.free(rt);
    try emit.emitReturnUndefined();

    try std.testing.expectEqual(@as(u32, 0), const_index);
    try std.testing.expectEqual(engine.bytecode.emitter.known.push_const, function_bc.code[0]);
    try std.testing.expectEqual(engine.bytecode.emitter.known.return_undef, function_bc.code[5]);
    try std.testing.expectEqual(@as(usize, 1), function_bc.constants.values.len);
}

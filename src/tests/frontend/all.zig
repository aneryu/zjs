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

test "lexer tokenizes unicode escaped identifiers and private names" {
    var lex = frontend.lexer.Lexer.init("class C { #\\u{6F}_; #ZW_\\u200D_J; \\u0061sync; }");

    var saw_private_escape = false;
    var saw_private_joiner = false;
    var saw_identifier_escape = false;

    while (true) {
        const tok = try lex.next();
        if (tok.kind == .eof) break;
        if (tok.kind == .private_identifier and std.mem.eql(u8, tok.lexeme, "#\\u{6F}_")) saw_private_escape = true;
        if (tok.kind == .private_identifier and std.mem.eql(u8, tok.lexeme, "#ZW_\\u200D_J")) saw_private_joiner = true;
        if (tok.kind == .identifier and std.mem.eql(u8, tok.lexeme, "\\u0061sync")) saw_identifier_escape = true;
    }

    try std.testing.expect(saw_private_escape);
    try std.testing.expect(saw_private_joiner);
    try std.testing.expect(saw_identifier_escape);
}

test "lexer tokenizes logical and nullish punctuators as pairs" {
    var lex = frontend.lexer.Lexer.init("a && b || c ?? d");
    var seen: [3][]const u8 = undefined;
    var seen_len: usize = 0;

    while (true) {
        const tok = try lex.next();
        if (tok.kind == .eof) break;
        if (tok.kind == .punctuator) {
            seen[seen_len] = tok.lexeme;
            seen_len += 1;
        }
    }

    try std.testing.expectEqual(@as(usize, 3), seen_len);
    try std.testing.expectEqualStrings("&&", seen[0]);
    try std.testing.expectEqualStrings("||", seen[1]);
    try std.testing.expectEqualStrings("??", seen[2]);
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

test "print calls emit transitional host print opcode" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try frontend.parser.parse(rt, "print(1 + 2 * 3); console.log(\"ok\");", .{ .mode = .script, .filename = "print.js" });
    defer parsed.deinit();

    var host_print_count: usize = 0;
    var mul_index: ?usize = null;
    var add_index: ?usize = null;
    var host_print_index: ?usize = null;
    for (parsed.function.code, 0..) |op, index| {
        if (op == engine.bytecode.emitter.known.mul) mul_index = mul_index orelse index;
        if (op == engine.bytecode.emitter.known.add) add_index = add_index orelse index;
        if (op == engine.bytecode.emitter.known.host_print) {
            host_print_count += 1;
            host_print_index = host_print_index orelse index;
        }
    }
    try std.testing.expectEqual(@as(usize, 2), host_print_count);
    try std.testing.expect(mul_index != null);
    try std.testing.expect(add_index != null);
    try std.testing.expect(host_print_index != null);
    try std.testing.expect(mul_index.? < add_index.?);
    try std.testing.expect(add_index.? < host_print_index.?);
}

test "simple variable assignments emit var bytecode" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try frontend.parser.parse(rt, "let value = 5; value = value + 7; print(value);", .{ .mode = .script, .filename = "vars.js" });
    defer parsed.deinit();

    var get_var_count: usize = 0;
    var define_var_count: usize = 0;
    for (parsed.function.code) |op| {
        if (op == engine.bytecode.emitter.known.get_var) get_var_count += 1;
        if (op == engine.bytecode.emitter.known.define_var) define_var_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), get_var_count);
    try std.testing.expectEqual(@as(usize, 2), define_var_count);
}

test "template interpolation emits string concatenation" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try frontend.parser.parse(rt, "const x = 10; const y = 20; print(`${x} + ${y} = ${x + y}`);", .{ .mode = .script, .filename = "template.js" });
    defer parsed.deinit();

    var add_count: usize = 0;
    for (parsed.function.code) |op| {
        if (op == engine.bytecode.emitter.known.add) add_count += 1;
    }
    try std.testing.expect(add_count >= 3);
}

test "simple arrays emit array helper bytecode" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try frontend.parser.parse(rt, "const arr = [1, 2, 3]; print(arr); print(arr.length); print(arr[0]); print(arr.map(x => x * 2));", .{ .mode = .script, .filename = "array.js" });
    defer parsed.deinit();

    var new_array_count: usize = 0;
    var get_index_count: usize = 0;
    var map_count: usize = 0;
    for (parsed.function.code) |op| {
        if (op == engine.bytecode.emitter.known.new_array) new_array_count += 1;
        if (op == engine.bytecode.emitter.known.get_index) get_index_count += 1;
        if (op == engine.bytecode.emitter.known.array_map_mul) map_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), new_array_count);
    try std.testing.expectEqual(@as(usize, 1), get_index_count);
    try std.testing.expectEqual(@as(usize, 1), map_count);
}

test "simple functions and arrows emit inline helper bytecode" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try frontend.parser.parse(rt, "function add(a, b) { return a + b; } print(add(2, 3)); const double = x => x * 2; print(double(21)); function fact(n) { return n <= 1 ? 1 : n * fact(n - 1); } print(fact(6));", .{ .mode = .script, .filename = "functions.js" });
    defer parsed.deinit();

    var add_count: usize = 0;
    var mul_count: usize = 0;
    var factorial_count: usize = 0;
    for (parsed.function.code) |op| {
        if (op == engine.bytecode.emitter.known.add) add_count += 1;
        if (op == engine.bytecode.emitter.known.mul) mul_count += 1;
        if (op == engine.bytecode.emitter.known.factorial) factorial_count += 1;
    }
    try std.testing.expect(add_count >= 1);
    try std.testing.expect(mul_count >= 1);
    try std.testing.expectEqual(@as(usize, 1), factorial_count);
}

test "unsupported simple candidate falls back to transitional scanner" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try frontend.parser.parse(rt, "const arr = [1, 2, 3]; print(arr.length); print(typeof arr.map);", .{ .mode = .script, .filename = "fallback.js" });
    defer parsed.deinit();

    try std.testing.expect(parsed.syntax_error == null);
}

test "arrow early errors reject non-simple strict and invalid rest parameters" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    const cases = [_][]const u8{
        "0, ([element]) => { \"use strict\"; };",
        "0, (x = 0, x) => {};",
        "0, (...x = []) => {};",
        "var f; f = ([...{ x } = []]) => {};",
        "var f; f = ([...x, y]) => {};",
        "var x = ({ def\\u{61}ult }) => {};",
    };

    for (cases) |source| {
        var parsed = try frontend.parser.parse(rt, source, .{ .mode = .script, .filename = "arrow-early-error.js" });
        defer parsed.deinit();
        try std.testing.expect(parsed.syntax_error != null);
        try std.testing.expectEqualStrings("SyntaxError", parsed.syntax_error.?.message);
    }
}

test "arrow early error checks do not reject valid nested rest destructuring" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try frontend.parser.parse(rt, "var f; f = ([...[...x]]) => {};", .{ .mode = .script, .filename = "arrow-valid-rest.js" });
    defer parsed.deinit();

    try std.testing.expect(parsed.syntax_error == null);
}

test "assignment destructuring early errors reject invalid rest forms" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    const cases = [_][]const u8{
        "0, [...x, y] = [];",
        "0, [...x = 1] = [];",
        "0, [...[(x, y)]] = [[]];",
        "0, [...{ get x() {} }] = [[]];",
        "0, {...rest, b} = {};",
        "0, [[(x, y)]] = [[]];",
        "0, [{ get x() {} }] = [{}];",
        "0, { x: [(x, y)] } = { x: [] };",
        "0, { x: { get x() {} } } = { x: {} };",
        "/*---\nfeatures: [optional-chaining, destructuring-binding]\nnegative:\n  phase: parse\n  type: SyntaxError\n---*/\n0, [x?.y = 42] = [23];",
        "0, { default } = {};",
        "0, { bre\\u0061k } = {};",
        "0, { def\\u{61}ult } = {};",
        "(function*() { 0, { yield } = {}; });",
        "/*---\nflags: [generated, onlyStrict]\n---*/\n0, { eval } = {};",
        "/*---\nflags: [generated, onlyStrict]\n---*/\n0, [arguments] = [];",
        "/*---\nflags: [generated, onlyStrict]\n---*/\n(eval) = 20;",
        "/*---\nflags: [generated, onlyStrict]\n---*/\n(arguments) = 20;",
        "/*---\nflags: [generated, onlyStrict]\n---*/\n0, [ x = yield ] = [];",
        "/*---\nflags: [generated, onlyStrict]\n---*/\n0, { x: x[yield] } = {};",
    };

    for (cases) |source| {
        var parsed = try frontend.parser.parse(rt, source, .{ .mode = .script, .filename = "assignment-early-error.js" });
        defer parsed.deinit();
        try std.testing.expect(parsed.syntax_error != null);
        try std.testing.expectEqualStrings("SyntaxError", parsed.syntax_error.?.message);
    }
}

test "assignment destructuring early errors allow reserved property names" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    const cases = [_][]const u8{
        "var y = { default: x } = { default: 42 };",
        "var y = { bre\\u0061k: x } = { break: 42 };",
        "var yield; var result; var vals = { yield: 3 }; result = { yield } = vals;",
    };

    for (cases) |source| {
        var parsed = try frontend.parser.parse(rt, source, .{ .mode = .script, .filename = "assignment-valid-property-name.js" });
        defer parsed.deinit();
        try std.testing.expect(parsed.syntax_error == null);
    }
}

test "assignment early errors reject invalid assignment target types" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    const cases = [_][]const u8{
        "/*---\nnegative:\n  phase: parse\n  type: SyntaxError\ninfo: |\n  Static Semantics AssignmentTargetType, Return invalid.\n---*/\nx + y = 1;",
        "/*---\nnegative:\n  phase: parse\n  type: SyntaxError\ninfo: |\n  It is an early Syntax Error if LeftHandSideExpression is neither an ObjectLiteral nor an ArrayLiteral and AssignmentTargetType of LeftHandSideExpression is invalid or strict.\n---*/\ntrue = 42;",
        "/*---\nnegative:\n  phase: parse\n  type: SyntaxError\ninfo: |\n  Static Semantics AssignmentTargetType, Return invalid.\n---*/\n(() => {}) = 1;",
    };

    for (cases) |source| {
        var parsed = try frontend.parser.parse(rt, source, .{ .mode = .script, .filename = "assignment-target-type.js" });
        defer parsed.deinit();
        try std.testing.expect(parsed.syntax_error != null);
        try std.testing.expectEqualStrings("SyntaxError", parsed.syntax_error.?.message);
    }
}

test "async arrow early errors reject await-context parse negatives" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    const cases = [_][]const u8{
        "/*---\nfeatures: [async-functions]\nnegative:\n  phase: parse\n  type: SyntaxError\n---*/\nasync(await) => { }",
        "/*---\nfeatures: [async-functions]\nnegative:\n  phase: parse\n  type: SyntaxError\n---*/\n\\u0061sync () => {}",
    };

    for (cases) |source| {
        var parsed = try frontend.parser.parse(rt, source, .{ .mode = .script, .filename = "async-arrow-early-error.js" });
        defer parsed.deinit();
        try std.testing.expect(parsed.syntax_error != null);
        try std.testing.expectEqualStrings("SyntaxError", parsed.syntax_error.?.message);
    }
}

test "class early errors reject class parse negatives" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    const source =
        "/*---\n" ++
        "features: [class]\n" ++
        "negative:\n" ++
        "  phase: parse\n" ++
        "  type: SyntaxError\n" ++
        "info: |\n" ++
        "  ClassExpression\n" ++
        "---*/\n" ++
        "class static {}";

    var parsed = try frontend.parser.parse(rt, source, .{ .mode = .script, .filename = "class-early-error.js" });
    defer parsed.deinit();
    try std.testing.expect(parsed.syntax_error != null);
    try std.testing.expectEqualStrings("SyntaxError", parsed.syntax_error.?.message);
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

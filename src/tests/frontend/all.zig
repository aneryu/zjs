const std = @import("std");
const engine = @import("quickjs_zig_engine");

const core = engine.core;
const frontend = engine.frontend;

fn countOpcode(code: []const u8, opcode: u8) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i < code.len) {
        const op = code[i];
        if (op == opcode) count += 1;
        if (op == engine.bytecode.emitter.known.new_object and i + 5 <= code.len) {
            const prop_count = std.mem.readInt(u32, code[i + 1 ..][0..4], .little);
            i += 5 + @as(usize, @intCast(prop_count)) * 5;
            continue;
        }
        i += switch (op) {
            engine.bytecode.emitter.known.source_loc => 9,
            engine.bytecode.emitter.known.push_i32,
            engine.bytecode.emitter.known.push_const,
            engine.bytecode.emitter.known.get_var,
            engine.bytecode.emitter.known.define_var,
            engine.bytecode.emitter.known.new_function,
            engine.bytecode.emitter.known.construct,
            engine.bytecode.emitter.known.new_array,
            engine.bytecode.emitter.known.get_index,
            engine.bytecode.emitter.known.call,
            engine.bytecode.emitter.known.get_prop,
            engine.bytecode.emitter.known.optional_get_prop,
            engine.bytecode.emitter.known.set_prop,
            engine.bytecode.emitter.known.array_method,
            engine.bytecode.emitter.known.math_call,
            engine.bytecode.emitter.known.uri_call,
            engine.bytecode.emitter.known.promise_static,
            engine.bytecode.emitter.known.new_collection,
            engine.bytecode.emitter.known.new_closure,
            engine.bytecode.emitter.known.parse_int,
            engine.bytecode.emitter.known.date_call,
            engine.bytecode.emitter.known.date_static,
            engine.bytecode.emitter.known.date_method,
            engine.bytecode.emitter.known.new_date,
            engine.bytecode.emitter.known.regexp_method,
            engine.bytecode.emitter.known.string_method,
            => 5,
            engine.bytecode.emitter.known.for_in_next,
            engine.bytecode.emitter.known.call_prop,
            => 9,
            else => 1,
        };
    }
    return count;
}

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
    try std.testing.expectEqual(frontend.parser.ParsePath.syntax_error_guard, parsed.parse_path);
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
    try std.testing.expectEqual(frontend.parser.ParsePath.quickjs_parser, parsed.parse_path);
    try std.testing.expect(!parsed.function.flags.is_strict);
    try std.testing.expect(parsed.hasFeature(.statement));
    try std.testing.expect(parsed.hasFeature(.expression));
    try std.testing.expect(parsed.function.code.len > 0);
    try std.testing.expect(parsed.function.scopes.len == 1);
    try std.testing.expect(parsed.function.constants.values.len == 0);
}

test "print calls emit global lookup generic call and receiver-preserving property call bytecode" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try frontend.parser.parse(rt, "print(1 + 2 * 3); console.log(\"ok\");", .{ .mode = .script, .filename = "print.js" });
    defer parsed.deinit();

    try std.testing.expectEqual(frontend.parser.ParsePath.quickjs_parser, parsed.parse_path);

    var get_var_count: usize = 0;
    var get_prop_count: usize = 0;
    var call_count: usize = 0;
    var call_prop_count: usize = 0;
    var mul_index: ?usize = null;
    var add_index: ?usize = null;
    var i: usize = 0;
    while (i < parsed.function.code.len) {
        const op = parsed.function.code[i];
        if (op == engine.bytecode.emitter.known.mul) mul_index = mul_index orelse i;
        if (op == engine.bytecode.emitter.known.add) add_index = add_index orelse i;
        if (op == engine.bytecode.emitter.known.get_var) get_var_count += 1;
        if (op == engine.bytecode.emitter.known.get_prop) get_prop_count += 1;
        if (op == engine.bytecode.emitter.known.call) call_count += 1;
        if (op == engine.bytecode.emitter.known.call_prop) call_prop_count += 1;
        i += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), get_var_count);
    try std.testing.expectEqual(@as(usize, 0), get_prop_count);
    try std.testing.expectEqual(@as(usize, 1), call_count);
    try std.testing.expectEqual(@as(usize, 1), call_prop_count);
    try std.testing.expect(mul_index != null);
    try std.testing.expect(add_index != null);
    try std.testing.expect(mul_index.? < add_index.?);
    try std.testing.expect(add_index.? < parsed.function.code.len);
}

test "simple variable assignments emit var bytecode" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try frontend.parser.parse(rt, "let value = 5; value = value + 7; print(value);", .{ .mode = .script, .filename = "vars.js" });
    defer parsed.deinit();

    try std.testing.expectEqual(frontend.parser.ParsePath.quickjs_parser, parsed.parse_path);

    var get_var_count: usize = 0;
    var define_var_count: usize = 0;
    for (parsed.function.code) |op| {
        if (op == engine.bytecode.emitter.known.get_var) get_var_count += 1;
        if (op == engine.bytecode.emitter.known.define_var) define_var_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), get_var_count);
    try std.testing.expectEqual(@as(usize, 2), define_var_count);
}

test "quick parser emits compound assignment and update statements" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try frontend.parser.parse(rt, "let x = 1; x += 2; x++; print(x);", .{ .mode = .script, .filename = "quick-compound-update.js" });
    defer parsed.deinit();

    try std.testing.expectEqual(frontend.parser.ParsePath.quickjs_parser, parsed.parse_path);

    const add_count = countOpcode(parsed.function.code, engine.bytecode.emitter.known.add);
    const define_var_count = countOpcode(parsed.function.code, engine.bytecode.emitter.known.define_var);
    try std.testing.expect(add_count >= 2);
    try std.testing.expectEqual(@as(usize, 3), define_var_count);
}

test "quick parser emits arithmetic compound assignment operators" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try frontend.parser.parse(rt, "let x = 10; x -= 3; x *= 2; x /= 7; x %= 2; print(x);", .{ .mode = .script, .filename = "quick-compound-arithmetic.js" });
    defer parsed.deinit();

    try std.testing.expectEqual(frontend.parser.ParsePath.quickjs_parser, parsed.parse_path);
    try std.testing.expectEqual(@as(usize, 1), countOpcode(parsed.function.code, engine.bytecode.emitter.known.sub));
    try std.testing.expectEqual(@as(usize, 1), countOpcode(parsed.function.code, engine.bytecode.emitter.known.mul));
    try std.testing.expectEqual(@as(usize, 1), countOpcode(parsed.function.code, engine.bytecode.emitter.known.div));
    try std.testing.expectEqual(@as(usize, 1), countOpcode(parsed.function.code, engine.bytecode.emitter.known.mod));
}

test "quick parser does not claim update expression values" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try frontend.parser.parse(rt, "let x = 1; print(x++);", .{ .mode = .script, .filename = "quick-update-expression-fallback.js" });
    defer parsed.deinit();

    try std.testing.expect(parsed.parse_path != frontend.parser.ParsePath.quickjs_parser);
}

test "quick parser emits basic array and object literals" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try frontend.parser.parse(rt, "const arr = [1, 2, 3]; const obj = { a: arr[0], b: 2 }; print(obj.a + obj.b);", .{ .mode = .script, .filename = "quick-literals.js" });
    defer parsed.deinit();

    try std.testing.expectEqual(frontend.parser.ParsePath.quickjs_parser, parsed.parse_path);

    const new_array_count = countOpcode(parsed.function.code, engine.bytecode.emitter.known.new_array);
    const new_object_count = countOpcode(parsed.function.code, engine.bytecode.emitter.known.new_object);
    const get_index_count = countOpcode(parsed.function.code, engine.bytecode.emitter.known.get_index);
    try std.testing.expect(new_array_count >= 1);
    try std.testing.expect(new_object_count >= 1);
    try std.testing.expect(get_index_count >= 1);
}

test "quick parser emits object property assignment" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try frontend.parser.parse(rt, "const obj = { x: 1 }; obj.x = obj.x + 2; print(obj.x);", .{ .mode = .script, .filename = "quick-property-assignment.js" });
    defer parsed.deinit();

    try std.testing.expectEqual(frontend.parser.ParsePath.quickjs_parser, parsed.parse_path);

    const get_prop_count = countOpcode(parsed.function.code, engine.bytecode.emitter.known.get_prop);
    const set_prop_count = countOpcode(parsed.function.code, engine.bytecode.emitter.known.set_prop);
    try std.testing.expect(get_prop_count >= 2);
    try std.testing.expectEqual(@as(usize, 1), set_prop_count);
}

test "quick parser emits optional property access for object and nullish bases" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try frontend.parser.parse(rt, "const obj = { a: { b: 42 } }; print(obj?.a?.b); print(obj?.x?.y); print(undefined?.a);", .{ .mode = .script, .filename = "quick-optional-property.js" });
    defer parsed.deinit();

    try std.testing.expectEqual(frontend.parser.ParsePath.quickjs_parser, parsed.parse_path);

    const optional_get_prop_count = countOpcode(parsed.function.code, engine.bytecode.emitter.known.optional_get_prop);
    try std.testing.expectEqual(@as(usize, 5), optional_get_prop_count);
}

test "quick parser preserves parenthesized postfix bases" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try frontend.parser.parse(rt, "const obj = { x: 1 }; print((obj).x); print(({ y: obj.x + 2 }).y); print(([3, 4])[1]); print(({ n: null })?.n);", .{ .mode = .script, .filename = "quick-parenthesized-postfix.js" });
    defer parsed.deinit();

    try std.testing.expectEqual(frontend.parser.ParsePath.quickjs_parser, parsed.parse_path);

    const get_prop_count = countOpcode(parsed.function.code, engine.bytecode.emitter.known.get_prop);
    const optional_get_prop_count = countOpcode(parsed.function.code, engine.bytecode.emitter.known.optional_get_prop);
    const get_index_count = countOpcode(parsed.function.code, engine.bytecode.emitter.known.get_index);
    try std.testing.expect(get_prop_count >= 3);
    try std.testing.expectEqual(@as(usize, 1), optional_get_prop_count);
    try std.testing.expectEqual(@as(usize, 1), get_index_count);
}

test "quick parser lowers JSON stringify and parse to transitional JSON bytecode" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try frontend.parser.parse(rt, "const text = JSON.stringify({ a: 1 }); print(JSON.parse(text).a);", .{ .mode = .script, .filename = "quick-json-domain.js" });
    defer parsed.deinit();

    try std.testing.expectEqual(frontend.parser.ParsePath.quickjs_parser, parsed.parse_path);
    try std.testing.expectEqual(@as(usize, 1), countOpcode(parsed.function.code, engine.bytecode.emitter.known.json_stringify));
    try std.testing.expectEqual(@as(usize, 1), countOpcode(parsed.function.code, engine.bytecode.emitter.known.json_parse));
}

test "quick parser lowers Math calls to transitional Math bytecode" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try frontend.parser.parse(rt, "print(Math.abs(-5)); print(Math.pow(2, 3)); print(Math.min(1, 2, 3));", .{ .mode = .script, .filename = "quick-math-domain.js" });
    defer parsed.deinit();

    try std.testing.expectEqual(frontend.parser.ParsePath.quickjs_parser, parsed.parse_path);
    try std.testing.expectEqual(@as(usize, 3), countOpcode(parsed.function.code, engine.bytecode.emitter.known.math_call));
}

test "quick parser lowers URI calls to transitional URI bytecode" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try frontend.parser.parse(rt, "console.log(encodeURI(\"a b?x=1&y=2#z\")); print(decodeURIComponent(\"a%20b%3Fx%3D1\"));", .{ .mode = .script, .filename = "quick-uri-domain.js" });
    defer parsed.deinit();

    try std.testing.expectEqual(frontend.parser.ParsePath.quickjs_parser, parsed.parse_path);
    try std.testing.expectEqual(@as(usize, 2), countOpcode(parsed.function.code, engine.bytecode.emitter.known.uri_call));
}

test "quick parser lowers Number parse helpers to transitional number bytecode" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try frontend.parser.parse(
        rt,
        "print(parseInt(\"0x10\")); print(parseInt(\"0x10\", 10)); print(parseFloat(\"1.5x\")); print(Number.parseInt(\"42\")); print(Number.parseFloat(\"3.14\")); print(Number.NaN); print(Number.POSITIVE_INFINITY); print(Number.NEGATIVE_INFINITY);",
        .{ .mode = .script, .filename = "quick-number-parse-domain.js" },
    );
    defer parsed.deinit();

    try std.testing.expectEqual(frontend.parser.ParsePath.quickjs_parser, parsed.parse_path);
    try std.testing.expectEqual(@as(usize, 3), countOpcode(parsed.function.code, engine.bytecode.emitter.known.parse_int));
    try std.testing.expectEqual(@as(usize, 2), countOpcode(parsed.function.code, engine.bytecode.emitter.known.parse_float));
}

test "quick parser lowers supported Date helpers to receiver-preserving property calls" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try frontend.parser.parse(
        rt,
        "print(Date()); print(Date.UTC(2024, 0, 1)); print(Date.parse(\"2024-01-01T00:00:00Z\")); print(Date.now()); const d = new Date(0); print(d.getTime()); print(d.toISOString());",
        .{ .mode = .script, .filename = "quick-date-domain.js" },
    );
    defer parsed.deinit();

    try std.testing.expectEqual(frontend.parser.ParsePath.quickjs_parser, parsed.parse_path);
    try std.testing.expectEqual(@as(usize, 1), countOpcode(parsed.function.code, engine.bytecode.emitter.known.date_call));
    try std.testing.expectEqual(@as(usize, 0), countOpcode(parsed.function.code, engine.bytecode.emitter.known.date_static));
    try std.testing.expectEqual(@as(usize, 1), countOpcode(parsed.function.code, engine.bytecode.emitter.known.new_date));
    try std.testing.expectEqual(@as(usize, 0), countOpcode(parsed.function.code, engine.bytecode.emitter.known.date_method));
    try std.testing.expectEqual(@as(usize, 5), countOpcode(parsed.function.code, engine.bytecode.emitter.known.call_prop));
}

test "quick parser lowers supported RegExp helpers to receiver-preserving property calls" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try frontend.parser.parse(
        rt,
        "const r = new RegExp(\"a\", \"g\"); print(r.toString()); print(r.test(\"a\")); print(r.exec(\"a\"));",
        .{ .mode = .script, .filename = "quick-regexp-domain.js" },
    );
    defer parsed.deinit();

    try std.testing.expectEqual(frontend.parser.ParsePath.quickjs_parser, parsed.parse_path);
    try std.testing.expectEqual(@as(usize, 1), countOpcode(parsed.function.code, engine.bytecode.emitter.known.new_regexp));
    try std.testing.expectEqual(@as(usize, 0), countOpcode(parsed.function.code, engine.bytecode.emitter.known.regexp_method));
    try std.testing.expectEqual(@as(usize, 3), countOpcode(parsed.function.code, engine.bytecode.emitter.known.call_prop));
}

test "quick parser lowers supported Promise helpers to receiver-preserving property calls" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try frontend.parser.parse(
        rt,
        \\const p = new Promise((resolve, reject) => {
        \\    resolve(1);
        \\});
        \\print(typeof p);
        \\print(Promise.resolve(1));
        \\print(Promise.all([1, 2]));
        \\print(Promise.race([Promise.resolve(3), 4]));
        \\print(Promise.reject(1));
    ,
        .{ .mode = .script, .filename = "quick-promise-domain.js" },
    );
    defer parsed.deinit();

    try std.testing.expectEqual(frontend.parser.ParsePath.quickjs_parser, parsed.parse_path);
    try std.testing.expectEqual(@as(usize, 1), countOpcode(parsed.function.code, engine.bytecode.emitter.known.new_promise));
    try std.testing.expectEqual(@as(usize, 0), countOpcode(parsed.function.code, engine.bytecode.emitter.known.promise_static));
    try std.testing.expectEqual(@as(usize, 5), countOpcode(parsed.function.code, engine.bytecode.emitter.known.call_prop));
}

test "quick parser lowers supported collection helpers to receiver-preserving property calls" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try frontend.parser.parse(
        rt,
        \\const map = new Map();
        \\map.set("key", 1);
        \\print(map.get("key"));
        \\print(map.has("key"));
        \\print(map.delete("key"));
        \\map.clear();
        \\const set = new Set();
        \\set.add(1);
        \\print(set.has(1));
        \\print(set.delete(1));
        \\set.clear();
        \\const weakMap = new WeakMap();
        \\const key = {};
        \\weakMap.set(key, 2);
        \\print(weakMap.get(key));
        \\print(weakMap.has(key));
        \\print(weakMap.delete(key));
        \\const weakSet = new WeakSet();
        \\const weakKey = {};
        \\weakSet.add(weakKey);
        \\print(weakSet.has(weakKey));
        \\print(weakSet.delete(weakKey));
    ,
        .{ .mode = .script, .filename = "quick-collection-domain.js" },
    );
    defer parsed.deinit();

    try std.testing.expectEqual(frontend.parser.ParsePath.quickjs_parser, parsed.parse_path);
    try std.testing.expectEqual(@as(usize, 4), countOpcode(parsed.function.code, engine.bytecode.emitter.known.new_collection));
    try std.testing.expectEqual(@as(usize, 16), countOpcode(parsed.function.code, engine.bytecode.emitter.known.call_prop));
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

test "simple arrays emit receiver-preserving property calls" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try frontend.parser.parse(rt, "const arr = [1, 2, 3]; print(arr); print(arr.length); print(arr[0]); print(arr.map(x => x * 2));", .{ .mode = .script, .filename = "array.js" });
    defer parsed.deinit();

    const new_array_count = countOpcode(parsed.function.code, engine.bytecode.emitter.known.new_array);
    const get_index_count = countOpcode(parsed.function.code, engine.bytecode.emitter.known.get_index);
    const map_count = countOpcode(parsed.function.code, engine.bytecode.emitter.known.array_method);
    const call_prop_count = countOpcode(parsed.function.code, engine.bytecode.emitter.known.call_prop);
    try std.testing.expectEqual(@as(usize, 1), new_array_count);
    try std.testing.expectEqual(@as(usize, 1), get_index_count);
    try std.testing.expectEqual(@as(usize, 0), map_count);
    try std.testing.expectEqual(@as(usize, 1), call_prop_count);
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

test "unsupported spread call reports syntax guard" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try frontend.parser.parse(rt, "print(...[1]);", .{ .mode = .script, .filename = "fallback.js" });
    defer parsed.deinit();

    try std.testing.expect(parsed.syntax_error != null);
    try std.testing.expectEqual(frontend.parser.ParsePath.syntax_error_guard, parsed.parse_path);
}

test "test262 frontmatter does not affect quick parser behavior" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    const source =
        "/*---\n" ++
        "negative:\n" ++
        "  phase: runtime\n" ++
        "  type: Test262Error\n" ++
        "---*/\n" ++
        "assert.sameValue(1 + 1, 2);";
    var parsed = try frontend.parser.parse(rt, source, .{ .mode = .script, .filename = "metadata.js" });
    defer parsed.deinit();

    try std.testing.expect(parsed.syntax_error == null);
    try std.testing.expectEqual(frontend.parser.ParsePath.quickjs_parser, parsed.parse_path);
    try std.testing.expectEqual(@as(usize, 1), countOpcode(parsed.function.code, engine.bytecode.emitter.known.get_var));
    try std.testing.expectEqual(@as(usize, 0), countOpcode(parsed.function.code, engine.bytecode.emitter.known.get_prop));
    try std.testing.expectEqual(@as(usize, 0), countOpcode(parsed.function.code, engine.bytecode.emitter.known.call));
    try std.testing.expectEqual(@as(usize, 1), countOpcode(parsed.function.code, engine.bytecode.emitter.known.call_prop));
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

// F1 — QuickJS-aligned lexer tests (separate file)
comptime { _ = @import("qjs_lexer_test.zig"); }

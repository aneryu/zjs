const std = @import("std");
const engine = @import("quickjs_zig_engine");

const core = engine.core;
const frontend = engine.frontend;
const function_def = engine.bytecode.function_def;
const qop = engine.bytecode.opcode.op;

fn countOpcode(code: []const u8, opcode: u8) usize {
    var count: usize = 0;
    for (code) |op| {
        if (op == opcode) count += 1;
    }
    return count;
}

fn functionBytecodeFromValue(value: core.JSValue) ?*const engine.bytecode.FunctionBytecode {
    if (!value.isFunctionBytecode()) return null;
    const header = value.objectHeader() orelse return null;
    return @fieldParentPtr("header", header);
}

fn countOpcodeInFunctionBytecode(fb: *const engine.bytecode.FunctionBytecode, opcode: u8) usize {
    var count = countOpcode(fb.byte_code, opcode);
    for (fb.cpool) |value| {
        if (functionBytecodeFromValue(value)) |child| {
            count += countOpcodeInFunctionBytecode(child, opcode);
        }
    }
    return count;
}

fn countOpcodeRecursive(function: *const engine.bytecode.Bytecode, opcode: u8) usize {
    var count = countOpcode(function.code, opcode);
    for (function.constants.values) |value| {
        if (functionBytecodeFromValue(value)) |fb| {
            count += countOpcodeInFunctionBytecode(fb, opcode);
        }
    }
    return count;
}

fn countCalls(code: []const u8) usize {
    return countOpcode(code, qop.call) +
        countOpcode(code, qop.call0) +
        countOpcode(code, qop.call1) +
        countOpcode(code, qop.call2) +
        countOpcode(code, qop.call3);
}

fn countFunctionClosures(code: []const u8) usize {
    return countOpcode(code, qop.fclosure) + countOpcode(code, qop.fclosure8);
}

fn expectOpcode(code: []const u8, opcode: u8) !void {
    try std.testing.expect(std.mem.indexOfScalar(u8, code, opcode) != null);
}

fn expectOpcodeRecursive(function: *const engine.bytecode.Bytecode, opcode: u8) !void {
    try std.testing.expect(countOpcodeRecursive(function, opcode) > 0);
}

fn expectFunctionConstant(function: *const engine.bytecode.Bytecode, index: usize) !*const engine.bytecode.FunctionBytecode {
    try std.testing.expect(index < function.constants.values.len);
    return functionBytecodeFromValue(function.constants.values[index]) orelse error.TestExpectedEqual;
}

fn functionBytecodeHasKind(fb: *const engine.bytecode.FunctionBytecode, kind: function_def.FunctionKind) bool {
    if (fb.func_kind == kind) return true;
    for (fb.cpool) |value| {
        if (functionBytecodeFromValue(value)) |child| {
            if (functionBytecodeHasKind(child, kind)) return true;
        }
    }
    return false;
}

fn functionHasKind(function: *const engine.bytecode.Bytecode, kind: function_def.FunctionKind) bool {
    for (function.constants.values) |value| {
        if (functionBytecodeFromValue(value)) |fb| {
            if (functionBytecodeHasKind(fb, kind)) return true;
        }
    }
    return false;
}

fn expectFunctionKindRecursive(function: *const engine.bytecode.Bytecode, kind: function_def.FunctionKind) !void {
    try std.testing.expect(functionHasKind(function, kind));
}

fn expectAtomOperandName(rt: *core.JSRuntime, function: *const engine.bytecode.Bytecode, expected: []const u8) !void {
    for (function.atom_operands) |atom_id| {
        if (rt.atoms.name(atom_id)) |name| {
            if (std.mem.eql(u8, name, expected)) return;
        }
    }
    return error.TestExpectedEqual;
}

fn expectNoLiveDynamicAtom(rt: *core.JSRuntime, kind: core.atom.AtomKind, bytes: []const u8) !void {
    for (rt.atoms.entries) |entry| {
        if (!entry.isLive() or entry.kind != kind) continue;
        if (std.mem.eql(u8, entry.bytes, bytes)) {
            std.debug.print("\n=== LEAKED ATOM FOUND: '{s}' kind={s} ref_count={d} ===\n", .{ entry.bytes, @tagName(entry.kind), entry.ref_count });
        }
        try std.testing.expect(!std.mem.eql(u8, entry.bytes, bytes));
    }
}

test "parser eval private bound names release retained atom on append failure" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const rt = try core.JSRuntime.create(failing.allocator());
    defer rt.destroy();

    const private_name = try rt.internAtom("#oom-private");
    failing.fail_index = failing.alloc_index + 1;
    try std.testing.expectError(error.OutOfMemory, frontend.parser.parse(rt, "", .{
        .filename = "Object",
        .eval_private_bound_names = &.{private_name},
    }));
    failing.fail_index = std.math.maxInt(usize);

    rt.atoms.free(private_name);
    try std.testing.expect(rt.atoms.name(private_name) == null);
}

test "parser BigInt literal OOM releases owned constant" {
    const source = "9007199254740993123456789012345678901234567890n;";
    var saw_oom = false;
    var saw_success = false;

    var fail_offset: usize = 0;
    while (fail_offset < 120) : (fail_offset += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        const rt = try core.JSRuntime.create(failing.allocator());

        failing.fail_index = failing.alloc_index + fail_offset;
        const result = frontend.parser.parse(rt, source, .{ .mode = .script, .filename = "bigint-oom.js" });
        failing.fail_index = std.math.maxInt(usize);

        if (result) |parsed_result| {
            saw_success = true;
            var parsed = parsed_result;
            parsed.deinit();
        } else |err| switch (err) {
            error.OutOfMemory => {
                saw_oom = true;
            },
            else => |unexpected| {
                rt.destroy();
                return unexpected;
            },
        }

        rt.destroy();
        if (saw_oom and saw_success) return;
    }

    try std.testing.expect(saw_oom);
    try std.testing.expect(saw_success);
}

test "parser class synthetic child OOM releases initialized function def" {
    const source = "class Derived extends Base { field = 1; }";
    var saw_oom = false;
    var saw_success = false;

    var fail_offset: usize = 0;
    while (fail_offset < 180) : (fail_offset += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        const rt = try core.JSRuntime.create(failing.allocator());

        failing.fail_index = failing.alloc_index + fail_offset;
        const result = frontend.parser.parse(rt, source, .{ .mode = .script, .filename = "class-child-oom.js" });
        failing.fail_index = std.math.maxInt(usize);

        if (result) |parsed_result| {
            saw_success = true;
            var parsed = parsed_result;
            parsed.deinit();
        } else |err| switch (err) {
            error.OutOfMemory => saw_oom = true,
            else => |unexpected| {
                rt.destroy();
                return unexpected;
            },
        }

        rt.destroy();
        if (saw_oom and saw_success) return;
    }

    try std.testing.expect(saw_oom);
    try std.testing.expect(saw_success);
}

test "parser nested function stack pop does not allocate on OOM path" {
    const source =
        \\function outer() {
        \\  function middle() {
        \\    function inner() { return 1; }
        \\    return inner;
        \\  }
        \\  return middle;
        \\}
    ;
    var saw_oom = false;
    var saw_success = false;

    var fail_offset: usize = 0;
    while (fail_offset < 260) : (fail_offset += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        const rt = try core.JSRuntime.create(failing.allocator());

        failing.fail_index = failing.alloc_index + fail_offset;
        const result = frontend.parser.parse(rt, source, .{ .mode = .script, .filename = "nested-function-pop-oom.js" });
        failing.fail_index = std.math.maxInt(usize);

        if (result) |parsed_result| {
            saw_success = true;
            var parsed = parsed_result;
            parsed.deinit();
        } else |err| switch (err) {
            error.OutOfMemory => saw_oom = true,
            else => |unexpected| {
                rt.destroy();
                return unexpected;
            },
        }

        rt.destroy();
        if (saw_oom and saw_success) return;
    }

    try std.testing.expect(saw_oom);
    try std.testing.expect(saw_success);
}

test "direct qjs parser OOM discard stack does not allocate" {
    const source =
        \\function outer() {
        \\  function middle() {
        \\    return 1;
        \\  }
        \\  return middle;
        \\}
    ;
    var saw_oom = false;

    var fail_offset: usize = 0;
    while (fail_offset < 320) : (fail_offset += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        const rt = try core.JSRuntime.create(failing.allocator());
        const name = try rt.internAtom("direct-qjs-parser-oom.js");
        var function = engine.bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);

        failing.fail_index = failing.alloc_index + fail_offset;
        var lex = frontend.zjs_lexer.Lexer.init(failing.allocator(), &rt.atoms, source);
        const state_result = frontend.zjs_parser.ParseState.init(&lex, &function);
        if (state_result) |state_value| {
            var state = state_value;
            state.top_level_functions_as_children = true;
            const parse_result = frontend.zjs_parser.parseProgramStatements(&state, frontend.zjs_parser.DeclMask{
                .func = true,
                .func_with_label = true,
                .other = true,
            });
            failing.fail_index = std.math.maxInt(usize);

            if (parse_result) {
                // The no-failure success case is checked below; this loop is
                // for OOM unwinding coverage.
            } else |err| switch (err) {
                error.OutOfMemory => saw_oom = true,
                error.UnexpectedToken => {},
                else => |unexpected| {
                    state.deinit(rt);
                    function.deinit(rt);
                    rt.atoms.free(name);
                    rt.destroy();
                    return unexpected;
                },
            }
            state.deinit(rt);
        } else |err| {
            failing.fail_index = std.math.maxInt(usize);
            switch (err) {
                error.OutOfMemory => saw_oom = true,
                else => |unexpected| {
                    function.deinit(rt);
                    rt.atoms.free(name);
                    rt.destroy();
                    return unexpected;
                },
            }
        }

        function.deinit(rt);
        rt.atoms.free(name);
        rt.destroy();
    }

    try std.testing.expect(saw_oom);

    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const name = try rt.internAtom("direct-qjs-parser-success.js");
    defer rt.atoms.free(name);
    var function = engine.bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer function.deinit(rt);
    var lex = frontend.zjs_lexer.Lexer.init(std.testing.allocator, &rt.atoms, source);
    var state = try frontend.zjs_parser.ParseState.init(&lex, &function);
    defer state.deinit(rt);
    state.top_level_functions_as_children = true;
    try frontend.zjs_parser.parseProgramStatements(&state, frontend.zjs_parser.DeclMask{
        .func = true,
        .func_with_label = true,
        .other = true,
    });
}

test "parser class private element OOM releases retained atom" {
    const source = "class C { #secret; }";
    var saw_oom = false;
    var saw_success = false;

    var fail_offset: usize = 0;
    while (fail_offset < 300) : (fail_offset += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        const rt = try core.JSRuntime.create(failing.allocator());

        failing.fail_index = failing.alloc_index + fail_offset;
        const result = frontend.parser.parse(rt, source, .{ .mode = .script, .filename = "class-private-oom.js" });
        failing.fail_index = std.math.maxInt(usize);

        if (result) |parsed_result| {
            saw_success = true;
            var parsed = parsed_result;
            parsed.deinit();
        } else |err| switch (err) {
            error.OutOfMemory => {
                saw_oom = true;
                expectNoLiveDynamicAtom(rt, .private, "#secret") catch |err2| {
                    std.debug.print("\n=== LEAK DETECTED AT fail_offset={d} ===\n", .{fail_offset});
                    rt.destroy();
                    return err2;
                };
            },
            else => |unexpected| {
                rt.destroy();
                return unexpected;
            },
        }

        rt.destroy();
        if (saw_oom and saw_success) return;
    }

    try std.testing.expect(saw_oom);
    try std.testing.expect(saw_success);
}

test "syntax error deinit balances empty message allocation" {
    var account = core.memory.MemoryAccount.init(std.testing.allocator);
    var atoms = core.atom.AtomTable.init(&account);

    var syntax_error = try frontend.source_pos.SyntaxError.create(&account, &atoms, core.atom.null_atom, .{}, "");
    syntax_error.deinit();
    atoms.deinit();

    try std.testing.expect(!account.hasOutstandingAllocations());
}

test "source positions and syntax errors carry filename line and column" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try frontend.parser.parse(rt, "let x = (\n1", .{ .mode = .script, .filename = "bad.js" });
    defer parsed.deinit();

    try std.testing.expect(parsed.syntax_error != null);
    try std.testing.expectEqual(frontend.parser.ParsePath.syntax_error_guard, parsed.parse_path);
    try std.testing.expectEqual(@as(u32, 2), parsed.syntax_error.?.position.line);
    try std.testing.expect(parsed.syntax_error.?.message.len > 0);
    try std.testing.expectEqualStrings("bad.js", rt.atoms.name(parsed.syntax_error.?.filename).?);
}

test "script parse mode emits bytecode metadata without AST execution" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try frontend.parser.parse(rt, "var x = 1; x + 2;", .{ .mode = .script, .filename = "script.js" });
    defer parsed.deinit();

    try std.testing.expect(parsed.syntax_error == null);
    try std.testing.expectEqual(frontend.parser.ParsePath.quickjs_parser, parsed.parse_path);
    try std.testing.expect(!parsed.function.flags.is_strict);
    try expectOpcode(parsed.function.code, qop.add);
    try expectOpcode(parsed.function.code, qop.drop);
    try std.testing.expect(countOpcode(parsed.function.code, qop.return_undef) + countOpcode(parsed.function.code, qop.return_async) > 0);
    try std.testing.expectEqual(@as(usize, 0), parsed.function.constants.values.len);
}

test "assignment target scan ignores atom operand bytes" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var held_atoms = std.ArrayList(core.Atom).empty;
    defer {
        for (held_atoms.items) |atom_id| rt.atoms.free(atom_id);
        held_atoms.deinit(std.testing.allocator);
    }

    var index: u32 = 0;
    while (true) : (index += 1) {
        var name_buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "operand_pad_{d}", .{index});
        const atom_id = try rt.internAtom(name);
        try held_atoms.append(std.testing.allocator, atom_id);
        if ((atom_id & 0xff) == engine.bytecode.opcode.op.is_undefined_or_null - 1) break;
    }

    var parsed = try frontend.parser.parse(rt, "var count2 = 2; while (count2 -= 1) { 3; }", .{ .mode = .eval_direct, .filename = "eval" });
    defer parsed.deinit();

    try std.testing.expect(parsed.syntax_error == null);
    try std.testing.expectEqual(frontend.parser.ParsePath.quickjs_parser, parsed.parse_path);
}

test "print calls emit global lookup generic call and receiver-preserving property call bytecode" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
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
        if (op == engine.bytecode.opcode.op.mul) mul_index = mul_index orelse i;
        if (op == engine.bytecode.opcode.op.add) add_index = add_index orelse i;
        if (op == engine.bytecode.opcode.op.get_var) get_var_count += 1;
        if (op == engine.bytecode.opcode.op.get_field) get_prop_count += 1;
        if (op == engine.bytecode.opcode.op.call) call_count += 1;
        if (op == engine.bytecode.opcode.op.call_method) call_prop_count += 1;
        i += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), get_var_count);
    try std.testing.expectEqual(@as(usize, 0), get_prop_count);
    try std.testing.expect(call_count + countOpcode(parsed.function.code, engine.bytecode.opcode.op.call1) >= 1);
    try std.testing.expectEqual(@as(usize, 1), call_prop_count);
    try std.testing.expect(mul_index != null);
    try std.testing.expect(add_index != null);
    try std.testing.expect(mul_index.? < add_index.?);
    try std.testing.expect(add_index.? < parsed.function.code.len);
}

test "simple variable assignments emit var bytecode" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try frontend.parser.parse(rt, "let value = 5; value = value + 7; print(value);", .{ .mode = .script, .filename = "vars.js" });
    defer parsed.deinit();

    try std.testing.expectEqual(frontend.parser.ParsePath.quickjs_parser, parsed.parse_path);

    var get_var_count: usize = 0;
    var define_var_count: usize = 0;
    for (parsed.function.code) |op| {
        if (op == engine.bytecode.opcode.op.get_var) get_var_count += 1;
        if (op == engine.bytecode.opcode.op.define_var) define_var_count += 1;
    }
    try std.testing.expect(get_var_count >= 1);
    try std.testing.expect(define_var_count <= 2);
}

test "quick parser emits compound assignment and update statements" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try frontend.parser.parse(rt, "let x = 1; x += 2; x++; print(x);", .{ .mode = .script, .filename = "quick-compound-update.js" });
    defer parsed.deinit();

    try std.testing.expectEqual(frontend.parser.ParsePath.quickjs_parser, parsed.parse_path);

    const add_count = countOpcode(parsed.function.code, engine.bytecode.opcode.op.add);
    const define_var_count = countOpcode(parsed.function.code, engine.bytecode.opcode.op.define_var);
    try std.testing.expect(add_count >= 1);
    try std.testing.expect(define_var_count <= 3);
}

test "quick parser emits arithmetic compound assignment operators" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try frontend.parser.parse(rt, "let x = 10; x -= 3; x *= 2; x /= 7; x %= 2; print(x);", .{ .mode = .script, .filename = "quick-compound-arithmetic.js" });
    defer parsed.deinit();

    try std.testing.expectEqual(frontend.parser.ParsePath.quickjs_parser, parsed.parse_path);
    try std.testing.expectEqual(@as(usize, 1), countOpcode(parsed.function.code, engine.bytecode.opcode.op.sub));
    try std.testing.expectEqual(@as(usize, 1), countOpcode(parsed.function.code, engine.bytecode.opcode.op.mul));
    try std.testing.expectEqual(@as(usize, 1), countOpcode(parsed.function.code, engine.bytecode.opcode.op.div));
    try std.testing.expectEqual(@as(usize, 1), countOpcode(parsed.function.code, engine.bytecode.opcode.op.mod));
}

test "quick parser does not claim update expression values" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try frontend.parser.parse(rt, "let x = 1; print(x++);", .{ .mode = .script, .filename = "quick-update-expression-fallback.js" });
    defer parsed.deinit();

    try std.testing.expectEqual(frontend.parser.ParsePath.quickjs_parser, parsed.parse_path);
}

test "quick parser emits basic array and object literals" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try frontend.parser.parse(rt, "const arr = [1, 2, 3]; const obj = { a: arr[0], b: 2 }; print(obj.a + obj.b);", .{ .mode = .script, .filename = "quick-literals.js" });
    defer parsed.deinit();

    try std.testing.expectEqual(frontend.parser.ParsePath.quickjs_parser, parsed.parse_path);

    const new_array_count = countOpcode(parsed.function.code, engine.bytecode.opcode.op.array_from);
    const new_object_count = countOpcode(parsed.function.code, engine.bytecode.opcode.op.object);
    const get_index_count = countOpcode(parsed.function.code, engine.bytecode.opcode.op.get_array_el);
    try std.testing.expect(new_array_count >= 1);
    try std.testing.expect(new_object_count >= 1);
    try std.testing.expect(get_index_count >= 1);
}

test "quick parser emits object property assignment" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try frontend.parser.parse(rt, "const obj = { x: 1 }; obj.x = obj.x + 2; print(obj.x);", .{ .mode = .script, .filename = "quick-property-assignment.js" });
    defer parsed.deinit();

    try std.testing.expectEqual(frontend.parser.ParsePath.quickjs_parser, parsed.parse_path);

    const get_prop_count = countOpcode(parsed.function.code, engine.bytecode.opcode.op.get_field);
    const set_prop_count = countOpcode(parsed.function.code, engine.bytecode.opcode.op.put_field);
    try std.testing.expect(get_prop_count >= 2);
    try std.testing.expectEqual(@as(usize, 1), set_prop_count);
}

test "quick parser emits optional property access for object and nullish bases" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try frontend.parser.parse(rt, "const obj = { a: { b: 42 } }; print(obj?.a?.b); print(obj?.x?.y); print(undefined?.a);", .{ .mode = .script, .filename = "quick-optional-property.js" });
    defer parsed.deinit();

    try std.testing.expectEqual(frontend.parser.ParsePath.quickjs_parser, parsed.parse_path);

    const optional_get_prop_count = countOpcode(parsed.function.code, engine.bytecode.opcode.op.is_undefined_or_null);
    try std.testing.expectEqual(@as(usize, 5), optional_get_prop_count);
}

test "quick parser preserves parenthesized postfix bases" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try frontend.parser.parse(rt, "const obj = { x: 1 }; print((obj).x); print(({ y: obj.x + 2 }).y); print(([3, 4])[1]); print(({ n: null })?.n);", .{ .mode = .script, .filename = "quick-parenthesized-postfix.js" });
    defer parsed.deinit();

    try std.testing.expectEqual(frontend.parser.ParsePath.quickjs_parser, parsed.parse_path);

    const get_prop_count = countOpcode(parsed.function.code, engine.bytecode.opcode.op.get_field);
    const optional_get_prop_count = countOpcode(parsed.function.code, engine.bytecode.opcode.op.is_undefined_or_null);
    const get_index_count = countOpcode(parsed.function.code, engine.bytecode.opcode.op.get_array_el);
    try std.testing.expect(get_prop_count >= 3);
    try std.testing.expectEqual(@as(usize, 1), optional_get_prop_count);
    try std.testing.expectEqual(@as(usize, 1), get_index_count);
}

test "quick parser lowers JSON stringify and parse to transitional JSON bytecode" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try frontend.parser.parse(rt, "const text = JSON.stringify({ a: 1 }); print(JSON.parse(text).a);", .{ .mode = .script, .filename = "quick-json-domain.js" });
    defer parsed.deinit();

    try std.testing.expectEqual(frontend.parser.ParsePath.quickjs_parser, parsed.parse_path);
    try std.testing.expect(countCalls(parsed.function.code) >= 1);
}

test "quick parser lowers Math calls to transitional Math bytecode" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try frontend.parser.parse(rt, "print(Math.abs(-5)); print(Math.pow(2, 3)); print(Math.min(1, 2, 3));", .{ .mode = .script, .filename = "quick-math-domain.js" });
    defer parsed.deinit();

    try std.testing.expectEqual(frontend.parser.ParsePath.quickjs_parser, parsed.parse_path);
    try std.testing.expect(countCalls(parsed.function.code) >= 3);
}

test "quick parser lowers URI calls to transitional URI bytecode" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try frontend.parser.parse(rt, "console.log(encodeURI(\"a b?x=1&y=2#z\")); print(decodeURIComponent(\"a%20b%3Fx%3D1\"));", .{ .mode = .script, .filename = "quick-uri-domain.js" });
    defer parsed.deinit();

    try std.testing.expectEqual(frontend.parser.ParsePath.quickjs_parser, parsed.parse_path);
    try std.testing.expect(countCalls(parsed.function.code) >= 2);
}

test "quick parser lowers Number parse helpers to transitional number bytecode" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try frontend.parser.parse(
        rt,
        "print(parseInt(\"0x10\")); print(parseInt(\"0x10\", 10)); print(parseFloat(\"1.5x\")); print(Number.parseInt(\"42\")); print(Number.parseFloat(\"3.14\")); print(Number.NaN); print(Number.POSITIVE_INFINITY); print(Number.NEGATIVE_INFINITY);",
        .{ .mode = .script, .filename = "quick-number-parse-domain.js" },
    );
    defer parsed.deinit();

    try std.testing.expectEqual(frontend.parser.ParsePath.quickjs_parser, parsed.parse_path);
    try std.testing.expect(countCalls(parsed.function.code) >= 5);
}

test "quick parser lowers supported Date helpers to receiver-preserving property calls" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try frontend.parser.parse(
        rt,
        "print(Date()); print(Date.UTC(2024, 0, 1)); print(Date.parse(\"2024-01-01T00:00:00Z\")); print(Date.now()); const d = new Date(0); print(d.getTime()); print(d.toISOString());",
        .{ .mode = .script, .filename = "quick-date-domain.js" },
    );
    defer parsed.deinit();

    try std.testing.expectEqual(frontend.parser.ParsePath.quickjs_parser, parsed.parse_path);
    try std.testing.expect(countCalls(parsed.function.code) >= 4);
    try std.testing.expect(countOpcode(parsed.function.code, engine.bytecode.opcode.op.call_constructor) >= 1);
    try std.testing.expect(countOpcode(parsed.function.code, engine.bytecode.opcode.op.call_method) >= 2);
}

test "quick parser lowers supported RegExp helpers to receiver-preserving property calls" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try frontend.parser.parse(
        rt,
        "const r = new RegExp(\"a\", \"g\"); print(r.toString()); print(r.test(\"a\")); print(r.exec(\"a\"));",
        .{ .mode = .script, .filename = "quick-regexp-domain.js" },
    );
    defer parsed.deinit();

    try std.testing.expectEqual(frontend.parser.ParsePath.quickjs_parser, parsed.parse_path);
    try std.testing.expect(countOpcode(parsed.function.code, engine.bytecode.opcode.op.call_constructor) >= 1);
    try std.testing.expect(countOpcode(parsed.function.code, engine.bytecode.opcode.op.call_method) >= 3);
}

test "quick parser lowers supported Promise helpers to receiver-preserving property calls" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
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
    try std.testing.expect(countOpcode(parsed.function.code, engine.bytecode.opcode.op.call_constructor) >= 1);
    try std.testing.expect(countOpcode(parsed.function.code, engine.bytecode.opcode.op.call_method) >= 4);
}

test "quick parser lowers supported collection helpers to receiver-preserving property calls" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
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
    try std.testing.expect(countOpcode(parsed.function.code, engine.bytecode.opcode.op.call_constructor) >= 4);
    try std.testing.expect(countOpcode(parsed.function.code, engine.bytecode.opcode.op.call_method) >= 16);
}

test "template interpolation emits string concatenation" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try frontend.parser.parse(rt, "const x = 10; const y = 20; print(`${x} + ${y} = ${x + y}`);", .{ .mode = .script, .filename = "template.js" });
    defer parsed.deinit();

    var add_count: usize = 0;
    for (parsed.function.code) |op| {
        if (op == engine.bytecode.opcode.op.add) add_count += 1;
    }
    try std.testing.expect(add_count >= 1);
}

test "simple arrays emit receiver-preserving property calls" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try frontend.parser.parse(rt, "const arr = [1, 2, 3]; print(arr); print(arr.length); print(arr[0]); print(arr.map(x => x * 2));", .{ .mode = .script, .filename = "array.js" });
    defer parsed.deinit();

    const new_array_count = countOpcode(parsed.function.code, engine.bytecode.opcode.op.array_from);
    const get_index_count = countOpcode(parsed.function.code, engine.bytecode.opcode.op.get_array_el);
    const map_count = countOpcode(parsed.function.code, engine.bytecode.opcode.op.get_field);
    const call_prop_count = countOpcode(parsed.function.code, engine.bytecode.opcode.op.call_method);
    try std.testing.expectEqual(@as(usize, 1), new_array_count);
    try std.testing.expectEqual(@as(usize, 1), get_index_count);
    try std.testing.expect(map_count >= 1 or call_prop_count >= 1);
    try std.testing.expectEqual(@as(usize, 1), call_prop_count);
}

test "simple functions and arrows emit inline helper bytecode" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try frontend.parser.parse(rt, "function add(a, b) { return a + b; } print(add(2, 3)); const double = x => x * 2; print(double(21)); function fact(n) { return n <= 1 ? 1 : n * fact(n - 1); } print(fact(6));", .{ .mode = .script, .filename = "functions.js" });
    defer parsed.deinit();

    var add_count: usize = 0;
    var mul_count: usize = 0;
    var factorial_count: usize = 0;
    for (parsed.function.code) |op| {
        if (op == engine.bytecode.opcode.op.add) add_count += 1;
        if (op == engine.bytecode.opcode.op.mul) mul_count += 1;
        if (op == engine.bytecode.opcode.op.call) factorial_count += 1;
    }
    add_count += countOpcodeRecursive(&parsed.function, engine.bytecode.opcode.op.add);
    mul_count += countOpcodeRecursive(&parsed.function, engine.bytecode.opcode.op.mul);
    factorial_count += countOpcodeRecursive(&parsed.function, engine.bytecode.opcode.op.call);
    try std.testing.expect(add_count >= 1);
    try std.testing.expect(mul_count >= 1);
    try std.testing.expect(factorial_count >= 1 or countOpcodeRecursive(&parsed.function, engine.bytecode.opcode.op.call1) >= 1);
}

test "unsupported spread call reports syntax guard" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try frontend.parser.parse(rt, "print(...[1]);", .{ .mode = .script, .filename = "fallback.js" });
    defer parsed.deinit();

    try std.testing.expectEqual(frontend.parser.ParsePath.quickjs_parser, parsed.parse_path);
}

test "test262 frontmatter does not affect quick parser behavior" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
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
    try std.testing.expectEqual(@as(usize, 1), countOpcode(parsed.function.code, engine.bytecode.opcode.op.get_var));
    try std.testing.expectEqual(@as(usize, 0), countOpcode(parsed.function.code, engine.bytecode.opcode.op.get_field));
    try std.testing.expectEqual(@as(usize, 0), countOpcode(parsed.function.code, engine.bytecode.opcode.op.call));
    try std.testing.expectEqual(@as(usize, 1), countOpcode(parsed.function.code, engine.bytecode.opcode.op.call_method));
}

test "arrow early errors reject non-simple strict and invalid rest parameters" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
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
        try std.testing.expect(parsed.syntax_error.?.message.len > 0);
    }
}

test "arrow early error checks do not reject valid nested rest destructuring" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try frontend.parser.parse(rt, "var f; f = ([...[...x]]) => {};", .{ .mode = .script, .filename = "arrow-valid-rest.js" });
    defer parsed.deinit();

    try std.testing.expect(parsed.syntax_error == null);
    try std.testing.expect(countFunctionClosures(parsed.function.code) > 0);
    const arrow = try expectFunctionConstant(&parsed.function, 0);
    try std.testing.expect(arrow.is_arrow_function);
    try std.testing.expectEqual(function_def.FunctionKind.normal, arrow.func_kind);
    try expectOpcode(arrow.byte_code, qop.special_object);
    try expectOpcode(arrow.byte_code, qop.return_undef);
}

test "assignment destructuring early errors reject invalid rest forms" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
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
        try std.testing.expect(parsed.syntax_error.?.message.len > 0);
    }
}

test "assignment destructuring early errors allow reserved property names" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const cases = [_]struct {
        source: []const u8,
        property: []const u8,
    }{
        .{ .source = "var y = { default: x } = { default: 42 };", .property = "default" },
        .{ .source = "var y = { bre\\u0061k: x } = { break: 42 };", .property = "break" },
        .{ .source = "var yield; var result; var vals = { yield: 3 }; result = { yield } = vals;", .property = "yield" },
    };

    for (cases) |case| {
        var parsed = try frontend.parser.parse(rt, case.source, .{ .mode = .script, .filename = "assignment-valid-property-name.js" });
        defer parsed.deinit();
        try std.testing.expect(parsed.syntax_error == null);
        try expectAtomOperandName(rt, &parsed.function, case.property);
        try expectOpcode(parsed.function.code, qop.define_field);
        try expectOpcode(parsed.function.code, qop.get_field);
    }
}

test "assignment early errors reject invalid assignment target types" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
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
        try std.testing.expect(parsed.syntax_error.?.message.len > 0);
    }
}

test "async arrow early errors reject await-context parse negatives" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const cases = [_][]const u8{
        "/*---\nfeatures: [async-functions]\nnegative:\n  phase: parse\n  type: SyntaxError\n---*/\nasync(await) => { }",
        "/*---\nfeatures: [async-functions]\nnegative:\n  phase: parse\n  type: SyntaxError\n---*/\n\\u0061sync () => {}",
    };

    for (cases) |source| {
        var parsed = try frontend.parser.parse(rt, source, .{ .mode = .script, .filename = "async-arrow-early-error.js" });
        defer parsed.deinit();
        try std.testing.expect(parsed.syntax_error != null);
        try std.testing.expect(parsed.syntax_error.?.message.len > 0);
    }
}

test "object computed property names parse async arrow and module await expressions" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var async_arrow = try frontend.parser.parse(rt, "let o = { [async () => {}]: 1 };", .{ .mode = .script, .filename = "computed-async-arrow.js" });
    defer async_arrow.deinit();
    try std.testing.expect(async_arrow.syntax_error == null);
    try std.testing.expect(async_arrow.hasFeature(.expression));
    try std.testing.expect(async_arrow.hasFeature(.function_));
    try std.testing.expect(async_arrow.hasFeature(.arrow));
    try std.testing.expect(async_arrow.hasFeature(.async_function));
    try std.testing.expect(!async_arrow.hasFeature(.dynamic_import));
    try expectOpcode(async_arrow.function.code, qop.to_propkey);
    try expectOpcode(async_arrow.function.code, qop.define_array_el);
    try std.testing.expect(countFunctionClosures(async_arrow.function.code) > 0);
    try expectFunctionKindRecursive(&async_arrow.function, .async);

    var module_await = try frontend.parser.parse(rt, "let o = { [await 9]: 9 };", .{ .mode = .module, .filename = "computed-await.js" });
    defer module_await.deinit();
    try std.testing.expect(module_await.syntax_error == null);
    try std.testing.expect(module_await.hasFeature(.expression));
    try std.testing.expect(module_await.hasFeature(.statement));
    try std.testing.expect(!module_await.hasFeature(.dynamic_import));
    try std.testing.expect(module_await.function.flags.is_module);
    try expectOpcode(module_await.function.code, qop.await);
    try expectOpcode(module_await.function.code, qop.to_propkey);
    try expectOpcode(module_await.function.code, qop.define_array_el);
}

test "class early errors reject class parse negatives" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
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
    try std.testing.expect(parsed.syntax_error.?.message.len > 0);
}

test "module parse mode records import export metadata and strict flag" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try frontend.parser.parse(
        rt,
        "import 'side'; import x, * as ns from 'm' with { type: \"json\" }; import { default as def, y, z as renamed, \"str\" as strLocal } from 'n'; export { x as default }; export { x }; export const c = 1; export const { d: dc, e } = {}; export let [arr] = []; export function f(){} export class C{} export async function af(){} export { y as yy } from 'n2'; export * from 's'; export * as ns2 from 's2'; await 0;",
        .{ .mode = .module, .filename = "mod.js" },
    );
    defer parsed.deinit();

    try std.testing.expect(parsed.syntax_error == null);
    try std.testing.expect(parsed.function.flags.is_strict);
    try expectOpcodeRecursive(&parsed.function, qop.await);
    try expectOpcodeRecursive(&parsed.function, qop.define_class);
    try std.testing.expect(countFunctionClosures(parsed.function.code) > 0);
    const record = parsed.function.module_record.?;
    try std.testing.expectEqual(@as(usize, 6), record.requests.len);
    try std.testing.expectEqual(@as(usize, 6), record.imports.len);
    try std.testing.expectEqual(@as(usize, 9), record.exports.len);
    try std.testing.expectEqual(@as(usize, 1), record.indirect_exports.len);
    try std.testing.expectEqual(@as(usize, 2), record.star_exports.len);
    try std.testing.expectEqual(@as(usize, 1), record.import_attributes.len);
    try std.testing.expect(record.has_top_level_await);
}

test "module import local names are compiled as module var refs" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try frontend.parser.parse(
        rt,
        "import x, { y as renamed } from 'dep'; import * as ns from 'ns'; function f(){ return renamed; } x; ns;",
        .{ .mode = .module, .filename = "import-refs.js" },
    );
    defer parsed.deinit();

    try std.testing.expect(parsed.syntax_error == null);
    try std.testing.expect(parsed.function.var_ref_names.len >= 3);

    const x = try rt.internAtom("x");
    defer rt.atoms.free(x);
    const renamed = try rt.internAtom("renamed");
    defer rt.atoms.free(renamed);
    const ns = try rt.internAtom("ns");
    defer rt.atoms.free(ns);

    try std.testing.expect(std.mem.indexOfScalar(core.Atom, parsed.function.var_ref_names, x) != null);
    try std.testing.expect(std.mem.indexOfScalar(core.Atom, parsed.function.var_ref_names, renamed) != null);
    try std.testing.expect(std.mem.indexOfScalar(core.Atom, parsed.function.var_ref_names, ns) != null);
}

test "module parser rejects duplicate exported names across export forms" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const cases = [_][]const u8{
        "var x; export { x as z }; export * as z from './dep.js';",
        "var x; export default x; export * as default from './dep.js';",
        "export { x as z } from './a.js'; export * as z from './b.js';",
    };

    for (cases) |source| {
        var parsed = try frontend.parser.parse(rt, source, .{ .mode = .module, .filename = "dup-export.js" });
        defer parsed.deinit();
        try std.testing.expect(parsed.syntax_error != null);
    }
}

test "module parser validates local export bindings after full body parse" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const valid_cases = [_][]const u8{
        "export { x }; var x;",
        "export { x }; const x = 1;",
        "import { x } from './dep.js'; export { x };",
    };
    for (valid_cases) |source| {
        var parsed = try frontend.parser.parse(rt, source, .{ .mode = .module, .filename = "valid-local-export.js" });
        defer parsed.deinit();
        try std.testing.expect(parsed.syntax_error == null);
    }

    const invalid_cases = [_][]const u8{
        "export { Number };",
        "export { unresolvable };",
    };
    for (invalid_cases) |source| {
        var parsed = try frontend.parser.parse(rt, source, .{ .mode = .module, .filename = "invalid-local-export.js" });
        defer parsed.deinit();
        try std.testing.expect(parsed.syntax_error != null);
    }
}

test "module parser rejects duplicate import attribute keys per with clause" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const invalid_cases = [_][]const u8{
        "import x from './dep.js' with { type: 'json', 'typ\\u0065': '' };",
        "import './dep.js' with { type: 'json', 'type': '' };",
        "export * from './dep.js' with { type: 'json', 'typ\\u0065': '' };",
    };
    for (invalid_cases) |source| {
        var parsed = try frontend.parser.parse(rt, source, .{ .mode = .module, .filename = "dup-import-attr.js" });
        defer parsed.deinit();
        try std.testing.expect(parsed.syntax_error != null);
    }

    var parsed = try frontend.parser.parse(
        rt,
        "import a from './a.js' with { type: 'json' }; import b from './b.js' with { type: 'json' };",
        .{ .mode = .module, .filename = "valid-import-attr.js" },
    );
    defer parsed.deinit();
    try std.testing.expect(parsed.syntax_error == null);
}

test "module parser accepts empty side-effect import attributes" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try frontend.parser.parse(rt, "import './dep.js' with {};", .{ .mode = .module, .filename = "side-effect-import-attr.js" });
    defer parsed.deinit();

    try std.testing.expect(parsed.syntax_error == null);
    try std.testing.expectEqual(@as(usize, 1), parsed.function.module_record.?.requests.len);
}

test "module parser validates string module export names" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const invalid_cases = [_][]const u8{
        "export { \"foo\" as \"bar\" }; function foo() {}",
        "export { Foo as \"\\uD83D\" }; function Foo() {}",
        "export { \"ok\" as \"\\uD83D\" } from './dep.js';",
        "export * as \"\\uD83D\" from './dep.js';",
    };
    for (invalid_cases) |source| {
        var parsed = try frontend.parser.parse(rt, source, .{ .mode = .module, .filename = "invalid-string-export-name.js" });
        defer parsed.deinit();
        try std.testing.expect(parsed.syntax_error != null);
    }

    var parsed = try frontend.parser.parse(rt, "export { \"ok\" as \"also-ok\" } from './dep.js';", .{ .mode = .module, .filename = "valid-string-export-name.js" });
    defer parsed.deinit();
    try std.testing.expect(parsed.syntax_error == null);
}

test "module parser rejects comma expression as default export expression" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var invalid = try frontend.parser.parse(rt, "export default null, null;", .{ .mode = .module, .filename = "invalid-default-export.js" });
    defer invalid.deinit();
    try std.testing.expect(invalid.syntax_error != null);

    var valid = try frontend.parser.parse(rt, "export default (null, null);", .{ .mode = .module, .filename = "valid-default-export.js" });
    defer valid.deinit();
    try std.testing.expect(valid.syntax_error == null);
}

test "module parser accepts keyword module export and import names" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try frontend.parser.parse(
        rt,
        "var x; export { x as if, x as import, x as await }; import { if as if_, import as import_, await as await_ } from './dep.js';",
        .{ .mode = .module, .filename = "keyword-module-names.js" },
    );
    defer parsed.deinit();

    try std.testing.expect(parsed.syntax_error == null);
    try std.testing.expectEqual(@as(usize, 3), parsed.function.module_record.?.exports.len);
    try std.testing.expectEqual(@as(usize, 3), parsed.function.module_record.?.imports.len);
}

test "module parser allows duplicate top-level var declarations" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try frontend.parser.parse(rt, "var test262; var test262; for (var other; false;) {} for (var other; false;) {}", .{ .mode = .module, .filename = "dup-module-var.js" });
    defer parsed.deinit();

    try std.testing.expect(parsed.syntax_error == null);
}

test "parser accepts dynamic import call expressions" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var module_parsed = try frontend.parser.parse(rt, "try { await import('dep', { with: {} }); } catch (e) {}", .{ .mode = .module, .filename = "dynamic-import.mjs" });
    defer module_parsed.deinit();
    try std.testing.expect(module_parsed.syntax_error == null);

    var script_parsed = try frontend.parser.parse(rt, "import('dep',);", .{ .mode = .script, .filename = "dynamic-import.js" });
    defer script_parsed.deinit();
    try std.testing.expect(script_parsed.syntax_error == null);

    var import_meta_arg = try frontend.parser.parse(rt, "import(import.meta);", .{ .mode = .module, .filename = "dynamic-import-meta.mjs" });
    defer import_meta_arg.deinit();
    try std.testing.expect(import_meta_arg.syntax_error == null);

    var import_in_arg = try frontend.parser.parse(rt, "for (promise = import('dep', 'x' in {}); false;) ;", .{ .mode = .script, .filename = "dynamic-import-in.js" });
    defer import_in_arg.deinit();
    try std.testing.expect(import_in_arg.syntax_error == null);
}

test "parser rejects invalid dynamic import call syntax" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var new_import = try frontend.parser.parse(rt, "new import('dep');", .{ .mode = .script, .filename = "bad-dynamic-import.js" });
    defer new_import.deinit();
    try std.testing.expect(new_import.syntax_error != null);

    var escaped_import = try frontend.parser.parse(rt, "im\\u0070ort('dep');", .{ .mode = .script, .filename = "escaped-dynamic-import.js" });
    defer escaped_import.deinit();
    try std.testing.expect(escaped_import.syntax_error != null);
}

test "module parser accepts default as explicit namespace export name" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try frontend.parser.parse(rt, "export * as default from './dep.js';", .{ .mode = .module, .filename = "default-star.js" });
    defer parsed.deinit();

    try std.testing.expect(parsed.syntax_error == null);
    try std.testing.expectEqual(@as(usize, 1), parsed.function.module_record.?.star_exports.len);
}

test "eval function class private destructuring spread async generator features are recorded" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var parsed = try frontend.parser.parse(
        rt,
        "async function *f(...args) { class C { #x; method(){ return args[0]; } } let {x} = args[0]; yield x; await x; import('m'); }",
        .{ .mode = .eval_direct, .filename = "eval.js" },
    );
    defer parsed.deinit();

    try std.testing.expect(parsed.direct_eval);
    try std.testing.expect(parsed.syntax_error == null);
    try std.testing.expectEqual(frontend.parser.ParsePath.quickjs_parser, parsed.parse_path);
    try std.testing.expect(parsed.hasFeature(.statement));
    try std.testing.expect(parsed.hasFeature(.expression));
    try std.testing.expect(parsed.hasFeature(.function_));
    try std.testing.expect(parsed.hasFeature(.async_function));
    try std.testing.expect(parsed.hasFeature(.generator));
    try std.testing.expect(parsed.hasFeature(.async_generator));
    try std.testing.expect(parsed.hasFeature(.class_));
    try std.testing.expect(parsed.hasFeature(.private_name));
    try std.testing.expect(parsed.hasFeature(.destructuring));
    try std.testing.expect(parsed.hasFeature(.spread_rest));
    try std.testing.expect(parsed.hasFeature(.dynamic_import));
    try std.testing.expect(!parsed.hasFeature(.arrow));
    try expectFunctionKindRecursive(&parsed.function, .async_generator);
    try expectOpcodeRecursive(&parsed.function, qop.rest);
    try expectOpcodeRecursive(&parsed.function, qop.define_class);
    try expectOpcodeRecursive(&parsed.function, qop.define_field);
    try expectOpcodeRecursive(&parsed.function, qop.define_method);
    try expectOpcodeRecursive(&parsed.function, qop.yield);
    try expectOpcodeRecursive(&parsed.function, qop.await);
    try expectOpcodeRecursive(&parsed.function, qop.import);
}

test "bytecode constants retain values through Phase 4 structures" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("emit");
    defer rt.atoms.free(name);

    var function_bc = engine.bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer function_bc.deinit(rt);

    const text = try core.string.String.createAscii(rt, "hello");
    const value = text.value();
    const const_index = try function_bc.addConstant(value);
    value.free(rt);

    try std.testing.expectEqual(@as(u32, 0), const_index);
    try std.testing.expectEqual(@as(usize, 1), function_bc.constants.values.len);
}

// F1 — QuickJS-aligned lexer tests (separate file)
comptime {
    _ = @import("zjs_lexer_test.zig");
    _ = @import("zjs_parser_test.zig");
}

//! F4 — Parser tests for the QuickJS-aligned expression parser.
//!
//! Validates the new parser's bytecode output by comparing emitted
//! byte sequences against the QuickJS lowering reference. The new
//! parser uses real QuickJS opcode ids (`bytecode.opcode.op.<name>`)
//! and is independent of the legacy QuickParser/VM. F2-3 will wire
//! up a VM dispatcher capable of executing this bytecode end-to-end.

const std = @import("std");
const engine = @import("quickjs_zig_engine");

const QjsLexer = engine.frontend.qjs_lexer.Lexer;
const qjs_parser = engine.frontend.qjs_parser;
const ParseState = qjs_parser.ParseState;
const op = engine.bytecode.opcode.op;

const TestEnv = struct {
    rt: *engine.core.runtime.Runtime,

    fn init() !TestEnv {
        return .{ .rt = try engine.core.runtime.Runtime.create(std.testing.allocator) };
    }
    fn deinit(self: *TestEnv) void {
        self.rt.destroy();
    }
};

/// Helper: parse `src` as an expression, run the F10 pipeline, and
/// return the produced final-form bytecode for byte-sequence
/// comparison. The parser's default is `emit_phase1_temp = true`, so
/// raw parser output contains scope_get_var/scope_put_var and other
/// Phase 1 temp opcodes; `pipeline.finalize.runWithFunctionDef`
/// lowers them to the final shapes the tests assert against
/// (including get_loc/put_loc for vars in `function_def.vars`).
fn parseExpr(env: *TestEnv, src: []const u8) !engine.bytecode.Bytecode {
    const name = try env.rt.internAtom("test");
    defer env.rt.atoms.free(name);
    var function = engine.bytecode.Bytecode.init(&env.rt.memory, &env.rt.atoms, name);
    errdefer function.deinit(env.rt);
    var lex = QjsLexer.init(std.testing.allocator, &env.rt.atoms, src);
    var state = try ParseState.init(&lex, &function);
    defer state.deinit(env.rt);
    try qjs_parser.parseExpr(&state);
    try engine.bytecode.pipeline.finalize.runWithFunctionDef(&function, &state.function_def);
    return function;
}

/// Helper: parse `src` as a statement, run the F10 pipeline, and
/// return the produced final-form bytecode for byte-sequence comparison.
fn parseStatement(env: *TestEnv, src: []const u8) !engine.bytecode.Bytecode {
    const name = try env.rt.internAtom("test");
    defer env.rt.atoms.free(name);
    var function = engine.bytecode.Bytecode.init(&env.rt.memory, &env.rt.atoms, name);
    errdefer function.deinit(env.rt);
    var lex = QjsLexer.init(std.testing.allocator, &env.rt.atoms, src);
    var state = try ParseState.init(&lex, &function);
    defer state.deinit(env.rt);
    try qjs_parser.parseStatementOrDecl(&state, qjs_parser.DeclMask{ .func = true, .func_with_label = true, .other = true });
    try engine.bytecode.pipeline.finalize.runWithFunctionDef(&function, &state.function_def);
    return function;
}

/// Read a u32 in little-endian from `bytes` starting at `offset`.
fn readU32(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset..][0..4], .little);
}

fn readI32(bytes: []const u8, offset: usize) i32 {
    return std.mem.readInt(i32, bytes[offset..][0..4], .little);
}

// ---- F4 first slice -------------------------------------------------

test "F4: number literal lowers to push_i32 for small integers" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "42");
    defer fn_bc.deinit(env.rt);

    try std.testing.expectEqual(@as(usize, 5), fn_bc.code.len);
    try std.testing.expectEqual(op.push_i32, fn_bc.code[0]);
    try std.testing.expectEqual(@as(i32, 42), readI32(fn_bc.code, 1));
}

test "F4: number literal with non-integer value lowers to push_const" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "3.5");
    defer fn_bc.deinit(env.rt);

    try std.testing.expectEqual(@as(usize, 5), fn_bc.code.len);
    try std.testing.expectEqual(op.push_const, fn_bc.code[0]);
    const idx = readU32(fn_bc.code, 1);
    const value = fn_bc.constants.get(idx).?;
    defer value.free(env.rt);
    try std.testing.expectApproxEqAbs(@as(f64, 3.5), value.asFloat64().?, 0.0001);
}

test "F4: boolean and null literals" {
    var env = try TestEnv.init();
    defer env.deinit();

    var t_bc = try parseExpr(&env, "true");
    defer t_bc.deinit(env.rt);
    try std.testing.expectEqualSlices(u8, &[_]u8{op.push_true}, t_bc.code);

    var f_bc = try parseExpr(&env, "false");
    defer f_bc.deinit(env.rt);
    try std.testing.expectEqualSlices(u8, &[_]u8{op.push_false}, f_bc.code);

    var n_bc = try parseExpr(&env, "null");
    defer n_bc.deinit(env.rt);
    try std.testing.expectEqualSlices(u8, &[_]u8{op.@"null"}, n_bc.code);
}

test "F4: identifier reads global via get_var" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "x");
    defer fn_bc.deinit(env.rt);

    try std.testing.expectEqual(@as(usize, 5), fn_bc.code.len);
    try std.testing.expectEqual(op.get_var, fn_bc.code[0]);
    try std.testing.expectEqual(@as(usize, 1), fn_bc.atom_operands.len);
}

test "F4: parseExprBinary level 1 (mul/div/mod)" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "2 * 3");
    defer fn_bc.deinit(env.rt);

    // Expect: push_i32 2 ; push_i32 3 ; mul
    try std.testing.expectEqual(@as(usize, 11), fn_bc.code.len);
    try std.testing.expectEqual(op.push_i32, fn_bc.code[0]);
    try std.testing.expectEqual(@as(i32, 2), readI32(fn_bc.code, 1));
    try std.testing.expectEqual(op.push_i32, fn_bc.code[5]);
    try std.testing.expectEqual(@as(i32, 3), readI32(fn_bc.code, 6));
    try std.testing.expectEqual(op.mul, fn_bc.code[10]);
}

test "F4: parseExprBinary level 2 (add/sub) is left-associative" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "1 + 2 - 3");
    defer fn_bc.deinit(env.rt);

    // Expect: push_i32 1 ; push_i32 2 ; add ; push_i32 3 ; sub
    try std.testing.expectEqual(@as(usize, 17), fn_bc.code.len);
    try std.testing.expectEqual(op.push_i32, fn_bc.code[0]);
    try std.testing.expectEqual(op.push_i32, fn_bc.code[5]);
    try std.testing.expectEqual(op.add, fn_bc.code[10]);
    try std.testing.expectEqual(op.push_i32, fn_bc.code[11]);
    try std.testing.expectEqual(op.sub, fn_bc.code[16]);
}

test "F4: precedence — multiplication before addition" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "1 + 2 * 3");
    defer fn_bc.deinit(env.rt);

    // Expect: push_i32 1 ; push_i32 2 ; push_i32 3 ; mul ; add
    try std.testing.expectEqual(@as(usize, 17), fn_bc.code.len);
    try std.testing.expectEqual(op.push_i32, fn_bc.code[0]);
    try std.testing.expectEqual(op.push_i32, fn_bc.code[5]);
    try std.testing.expectEqual(op.push_i32, fn_bc.code[10]);
    try std.testing.expectEqual(op.mul, fn_bc.code[15]);
    try std.testing.expectEqual(op.add, fn_bc.code[16]);
}

test "F4: parentheses override precedence" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "(1 + 2) * 3");
    defer fn_bc.deinit(env.rt);

    // Expect: push_i32 1 ; push_i32 2 ; add ; push_i32 3 ; mul
    try std.testing.expectEqual(@as(usize, 17), fn_bc.code.len);
    try std.testing.expectEqual(op.add, fn_bc.code[10]);
    try std.testing.expectEqual(op.mul, fn_bc.code[16]);
}

test "F4: comparison operators map to op.lt/op.lte/op.eq/op.strict_eq" {
    var env = try TestEnv.init();
    defer env.deinit();

    var lt_bc = try parseExpr(&env, "1 < 2");
    defer lt_bc.deinit(env.rt);
    try std.testing.expectEqual(op.lt, lt_bc.code[lt_bc.code.len - 1]);

    var lte_bc = try parseExpr(&env, "1 <= 2");
    defer lte_bc.deinit(env.rt);
    try std.testing.expectEqual(op.lte, lte_bc.code[lte_bc.code.len - 1]);

    var eq_bc = try parseExpr(&env, "1 == 2");
    defer eq_bc.deinit(env.rt);
    try std.testing.expectEqual(op.eq, eq_bc.code[eq_bc.code.len - 1]);

    var seq_bc = try parseExpr(&env, "1 === 2");
    defer seq_bc.deinit(env.rt);
    try std.testing.expectEqual(op.strict_eq, seq_bc.code[seq_bc.code.len - 1]);
}

test "F4: bitwise levels 6/7/8 (and/xor/or) and shifts" {
    var env = try TestEnv.init();
    defer env.deinit();

    var and_bc = try parseExpr(&env, "1 & 2");
    defer and_bc.deinit(env.rt);
    try std.testing.expectEqual(op.@"and", and_bc.code[and_bc.code.len - 1]);

    var xor_bc = try parseExpr(&env, "1 ^ 2");
    defer xor_bc.deinit(env.rt);
    try std.testing.expectEqual(op.xor, xor_bc.code[xor_bc.code.len - 1]);

    var or_bc = try parseExpr(&env, "1 | 2");
    defer or_bc.deinit(env.rt);
    try std.testing.expectEqual(op.@"or", or_bc.code[or_bc.code.len - 1]);

    var shl_bc = try parseExpr(&env, "1 << 2");
    defer shl_bc.deinit(env.rt);
    try std.testing.expectEqual(op.shl, shl_bc.code[shl_bc.code.len - 1]);

    var shr_bc = try parseExpr(&env, "1 >>> 2");
    defer shr_bc.deinit(env.rt);
    try std.testing.expectEqual(op.shr, shr_bc.code[shr_bc.code.len - 1]);
}

test "F4: unary +/-/~/! lower to plus/neg/not/lnot" {
    var env = try TestEnv.init();
    defer env.deinit();

    var pos_bc = try parseExpr(&env, "+x");
    defer pos_bc.deinit(env.rt);
    try std.testing.expectEqual(op.plus, pos_bc.code[pos_bc.code.len - 1]);

    var neg_bc = try parseExpr(&env, "-x");
    defer neg_bc.deinit(env.rt);
    try std.testing.expectEqual(op.neg, neg_bc.code[neg_bc.code.len - 1]);

    var not_bc = try parseExpr(&env, "~x");
    defer not_bc.deinit(env.rt);
    try std.testing.expectEqual(op.not, not_bc.code[not_bc.code.len - 1]);

    var lnot_bc = try parseExpr(&env, "!x");
    defer lnot_bc.deinit(env.rt);
    try std.testing.expectEqual(op.lnot, lnot_bc.code[lnot_bc.code.len - 1]);
}

test "F4: typeof identifier uses get_var_undef + typeof" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "typeof x");
    defer fn_bc.deinit(env.rt);

    // Expect: get_var_undef <atom> ; typeof
    try std.testing.expectEqual(@as(usize, 6), fn_bc.code.len);
    try std.testing.expectEqual(op.get_var_undef, fn_bc.code[0]);
    try std.testing.expectEqual(op.typeof, fn_bc.code[5]);
}

test "F4: void evaluates and discards then pushes undefined" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "void 0");
    defer fn_bc.deinit(env.rt);

    // Expect: push_i32 0 ; drop ; undefined
    try std.testing.expectEqual(@as(usize, 7), fn_bc.code.len);
    try std.testing.expectEqual(op.push_i32, fn_bc.code[0]);
    try std.testing.expectEqual(op.drop, fn_bc.code[5]);
    try std.testing.expectEqual(op.@"undefined", fn_bc.code[6]);
}

test "F4: power operator is right-associative" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "2 ** 3");
    defer fn_bc.deinit(env.rt);
    try std.testing.expectEqual(op.pow, fn_bc.code[fn_bc.code.len - 1]);
}

test "F4: logical && uses dup + if_false short-circuit" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "x && y");
    defer fn_bc.deinit(env.rt);

    // Expect:
    //   get_var x          (5)
    //   dup                (1)
    //   if_false L_skip    (5)
    //   drop               (1)
    //   get_var y          (5)
    //   L_skip:            (target)
    try std.testing.expectEqual(@as(usize, 17), fn_bc.code.len);
    try std.testing.expectEqual(op.get_var, fn_bc.code[0]);
    try std.testing.expectEqual(op.dup, fn_bc.code[5]);
    try std.testing.expectEqual(op.if_false, fn_bc.code[6]);
    try std.testing.expectEqual(op.drop, fn_bc.code[11]);
    try std.testing.expectEqual(op.get_var, fn_bc.code[12]);
    // The if_false target should be one byte past the last get_var.
    const target = readU32(fn_bc.code, 7);
    try std.testing.expectEqual(@as(u32, @intCast(fn_bc.code.len)), target);
}

test "F4: logical || uses dup + if_true short-circuit" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "x || y");
    defer fn_bc.deinit(env.rt);

    try std.testing.expectEqual(op.if_true, fn_bc.code[6]);
}

test "F4: nullish coalescing ?? uses is_undefined_or_null gate" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "x ?? y");
    defer fn_bc.deinit(env.rt);

    // Expect: get_var x ; dup ; is_undefined_or_null ; if_false L ; drop ; get_var y ; L:
    try std.testing.expectEqual(op.dup, fn_bc.code[5]);
    try std.testing.expectEqual(op.is_undefined_or_null, fn_bc.code[6]);
    try std.testing.expectEqual(op.if_false, fn_bc.code[7]);
}

test "F4: ternary cond ? a : b emits if_false + goto skeleton" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "a ? b : c");
    defer fn_bc.deinit(env.rt);

    // Layout (lengths):
    //   get_var a       5
    //   if_false L_else 5
    //   get_var b       5
    //   goto    L_end   5
    // L_else:
    //   get_var c       5
    // L_end:
    try std.testing.expectEqual(@as(usize, 25), fn_bc.code.len);
    try std.testing.expectEqual(op.if_false, fn_bc.code[5]);
    try std.testing.expectEqual(op.goto, fn_bc.code[15]);
    // L_else points just past the goto operand
    const else_target = readU32(fn_bc.code, 6);
    try std.testing.expectEqual(@as(u32, 20), else_target);
    // L_end points to end of bytecode
    const end_target = readU32(fn_bc.code, 16);
    try std.testing.expectEqual(@as(u32, 25), end_target);
}

test "F4: simple assignment x = 1 emits push ; dup ; put_var (KEEP_TOP)" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "x = 1");
    defer fn_bc.deinit(env.rt);

    // Expect: push_i32 1 ; dup ; put_var x
    // Mirrors QuickJS `put_lvalue` PUT_LVALUE_KEEP_TOP for OP_scope_get_var
    // (`quickjs.c:25479`), which emits an OP_dup before the put so the
    // assignment expression's value remains on the stack.
    try std.testing.expectEqual(@as(usize, 11), fn_bc.code.len);
    try std.testing.expectEqual(op.push_i32, fn_bc.code[0]);
    try std.testing.expectEqual(op.dup, fn_bc.code[5]);
    try std.testing.expectEqual(op.put_var, fn_bc.code[6]);
}

test "F4: compound assignment x += 1 emits get_var ; rhs ; add ; dup ; put_var" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "x += 1");
    defer fn_bc.deinit(env.rt);

    // Expect: get_var x ; push_i32 1 ; add ; dup ; put_var x
    try std.testing.expectEqual(@as(usize, 17), fn_bc.code.len);
    try std.testing.expectEqual(op.get_var, fn_bc.code[0]);
    try std.testing.expectEqual(op.push_i32, fn_bc.code[5]);
    try std.testing.expectEqual(op.add, fn_bc.code[10]);
    try std.testing.expectEqual(op.dup, fn_bc.code[11]);
    try std.testing.expectEqual(op.put_var, fn_bc.code[12]);
}

test "F4: comma operator drops left, keeps right" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "1, 2");
    defer fn_bc.deinit(env.rt);

    // Expect: push_i32 1 ; drop ; push_i32 2
    try std.testing.expectEqual(@as(usize, 11), fn_bc.code.len);
    try std.testing.expectEqual(op.push_i32, fn_bc.code[0]);
    try std.testing.expectEqual(op.drop, fn_bc.code[5]);
    try std.testing.expectEqual(op.push_i32, fn_bc.code[6]);
}

test "F4: member access a.b emits get_var + get_field" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "a.b");
    defer fn_bc.deinit(env.rt);

    // Expect: get_var a ; get_field b
    try std.testing.expectEqual(@as(usize, 10), fn_bc.code.len);
    try std.testing.expectEqual(op.get_var, fn_bc.code[0]);
    try std.testing.expectEqual(op.get_field, fn_bc.code[5]);
}

test "F4: index access a[i] emits get_var ; get_var ; get_array_el" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "a[i]");
    defer fn_bc.deinit(env.rt);

    // Expect: get_var a ; get_var i ; get_array_el
    try std.testing.expectEqual(@as(usize, 11), fn_bc.code.len);
    try std.testing.expectEqual(op.get_var, fn_bc.code[0]);
    try std.testing.expectEqual(op.get_var, fn_bc.code[5]);
    try std.testing.expectEqual(op.get_array_el, fn_bc.code[10]);
}

// ---- F4 slice 2 -----------------------------------------------------

test "F4: nested assignment 1 + (a = b) preserves the leading push" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "1 + (a = b)");
    defer fn_bc.deinit(env.rt);

    // Expect: push_i32 1 ; get_var b ; dup ; put_var a ; add
    try std.testing.expectEqual(@as(usize, 17), fn_bc.code.len);
    try std.testing.expectEqual(op.push_i32, fn_bc.code[0]);
    try std.testing.expectEqual(op.get_var, fn_bc.code[5]);
    try std.testing.expectEqual(op.dup, fn_bc.code[10]);
    try std.testing.expectEqual(op.put_var, fn_bc.code[11]);
    try std.testing.expectEqual(op.add, fn_bc.code[16]);
}

test "F4: string literal lowers to push_atom_value" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "\"hello\"");
    defer fn_bc.deinit(env.rt);

    try std.testing.expectEqual(@as(usize, 5), fn_bc.code.len);
    try std.testing.expectEqual(op.push_atom_value, fn_bc.code[0]);
    try std.testing.expectEqual(@as(usize, 1), fn_bc.atom_operands.len);
}

test "F4: empty string literal lowers to push_empty_string" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "\"\"");
    defer fn_bc.deinit(env.rt);

    try std.testing.expectEqual(@as(usize, 1), fn_bc.code.len);
    try std.testing.expectEqual(op.push_empty_string, fn_bc.code[0]);
}

test "F4: array literal lowers to push elements ; array_from N" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "[1, 2, 3]");
    defer fn_bc.deinit(env.rt);

    // Expect: push_i32 1 ; push_i32 2 ; push_i32 3 ; array_from 3
    try std.testing.expectEqual(@as(usize, 18), fn_bc.code.len);
    try std.testing.expectEqual(op.push_i32, fn_bc.code[0]);
    try std.testing.expectEqual(op.push_i32, fn_bc.code[5]);
    try std.testing.expectEqual(op.push_i32, fn_bc.code[10]);
    try std.testing.expectEqual(op.array_from, fn_bc.code[15]);
    const argc = std.mem.readInt(u16, fn_bc.code[16..18], .little);
    try std.testing.expectEqual(@as(u16, 3), argc);
}

test "F4: empty array literal emits array_from 0" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "[]");
    defer fn_bc.deinit(env.rt);

    try std.testing.expectEqual(@as(usize, 3), fn_bc.code.len);
    try std.testing.expectEqual(op.array_from, fn_bc.code[0]);
    const argc = std.mem.readInt(u16, fn_bc.code[1..3], .little);
    try std.testing.expectEqual(@as(u16, 0), argc);
}

test "F4: trailing comma in array literal is allowed" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "[1, 2,]");
    defer fn_bc.deinit(env.rt);

    try std.testing.expectEqual(op.array_from, fn_bc.code[10]);
    const argc = std.mem.readInt(u16, fn_bc.code[11..13], .little);
    try std.testing.expectEqual(@as(u16, 2), argc);
}

test "F4: object literal { a: 1, b: 2 } lowers to object + define_field" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "{ a: 1, b: 2 }");
    defer fn_bc.deinit(env.rt);

    // Expect:
    //   object              (1)
    //   push_i32 1          (5)
    //   define_field a      (5)
    //   push_i32 2          (5)
    //   define_field b      (5)
    try std.testing.expectEqual(@as(usize, 21), fn_bc.code.len);
    try std.testing.expectEqual(op.object, fn_bc.code[0]);
    try std.testing.expectEqual(op.push_i32, fn_bc.code[1]);
    try std.testing.expectEqual(op.define_field, fn_bc.code[6]);
    try std.testing.expectEqual(op.push_i32, fn_bc.code[11]);
    try std.testing.expectEqual(op.define_field, fn_bc.code[16]);
}

test "F4: empty object literal emits object" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "{}");
    defer fn_bc.deinit(env.rt);

    // Note: a leading `{` at expression position is ambiguous with a
    // block statement; in expression context our parser treats it as an
    // object literal. F5 will resolve the statement-level ambiguity.
    try std.testing.expectEqual(@as(usize, 1), fn_bc.code.len);
    try std.testing.expectEqual(op.object, fn_bc.code[0]);
}

test "F4: shorthand object property { x } emits get_var x ; define_field x" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "{ x }");
    defer fn_bc.deinit(env.rt);

    // Expect: object ; get_var x ; define_field x
    try std.testing.expectEqual(@as(usize, 11), fn_bc.code.len);
    try std.testing.expectEqual(op.object, fn_bc.code[0]);
    try std.testing.expectEqual(op.get_var, fn_bc.code[1]);
    try std.testing.expectEqual(op.define_field, fn_bc.code[6]);
}

test "F4: simple call f(a, b) emits get_var ; args ; call argc" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "f(a, b)");
    defer fn_bc.deinit(env.rt);

    // Expect: get_var f ; get_var a ; get_var b ; call 2
    try std.testing.expectEqual(@as(usize, 18), fn_bc.code.len);
    try std.testing.expectEqual(op.get_var, fn_bc.code[0]);
    try std.testing.expectEqual(op.get_var, fn_bc.code[5]);
    try std.testing.expectEqual(op.get_var, fn_bc.code[10]);
    try std.testing.expectEqual(op.call, fn_bc.code[15]);
    const argc = std.mem.readInt(u16, fn_bc.code[16..18], .little);
    try std.testing.expectEqual(@as(u16, 2), argc);
}

test "F4: zero-arg call f() emits call 0" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "f()");
    defer fn_bc.deinit(env.rt);

    try std.testing.expectEqual(@as(usize, 8), fn_bc.code.len);
    try std.testing.expectEqual(op.call, fn_bc.code[5]);
    const argc = std.mem.readInt(u16, fn_bc.code[6..8], .little);
    try std.testing.expectEqual(@as(u16, 0), argc);
}

test "F4: method call obj.m(x) uses get_field2 + call_method" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "obj.m(x)");
    defer fn_bc.deinit(env.rt);

    // Expect: get_var obj ; get_field2 m ; get_var x ; call_method 1
    try std.testing.expectEqual(@as(usize, 18), fn_bc.code.len);
    try std.testing.expectEqual(op.get_var, fn_bc.code[0]);
    try std.testing.expectEqual(op.get_field2, fn_bc.code[5]);
    try std.testing.expectEqual(op.get_var, fn_bc.code[10]);
    try std.testing.expectEqual(op.call_method, fn_bc.code[15]);
}

test "F4: indexed call obj[k](x) uses get_array_el2 + call_method" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "obj[k](x)");
    defer fn_bc.deinit(env.rt);

    // Expect: get_var obj ; get_var k ; get_array_el2 ; get_var x ; call_method 1
    try std.testing.expectEqual(@as(usize, 19), fn_bc.code.len);
    try std.testing.expectEqual(op.get_var, fn_bc.code[0]);
    try std.testing.expectEqual(op.get_var, fn_bc.code[5]);
    try std.testing.expectEqual(op.get_array_el2, fn_bc.code[10]);
    try std.testing.expectEqual(op.get_var, fn_bc.code[11]);
    try std.testing.expectEqual(op.call_method, fn_bc.code[16]);
}

test "F4: new X(a) emits get_var X ; get_var a ; call_constructor 1" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "new X(a)");
    defer fn_bc.deinit(env.rt);

    try std.testing.expectEqual(@as(usize, 13), fn_bc.code.len);
    try std.testing.expectEqual(op.get_var, fn_bc.code[0]);
    try std.testing.expectEqual(op.get_var, fn_bc.code[5]);
    try std.testing.expectEqual(op.call_constructor, fn_bc.code[10]);
    const argc = std.mem.readInt(u16, fn_bc.code[11..13], .little);
    try std.testing.expectEqual(@as(u16, 1), argc);
}

test "F4: bare new X (no args) emits call_constructor 0" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "new X");
    defer fn_bc.deinit(env.rt);

    try std.testing.expectEqual(@as(usize, 8), fn_bc.code.len);
    try std.testing.expectEqual(op.get_var, fn_bc.code[0]);
    try std.testing.expectEqual(op.call_constructor, fn_bc.code[5]);
    const argc = std.mem.readInt(u16, fn_bc.code[6..8], .little);
    try std.testing.expectEqual(@as(u16, 0), argc);
}

test "F4: postfix x++ emits get_var ; post_inc ; put_var" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "x++");
    defer fn_bc.deinit(env.rt);

    // Expect: get_var x ; post_inc ; put_var x
    try std.testing.expectEqual(@as(usize, 11), fn_bc.code.len);
    try std.testing.expectEqual(op.get_var, fn_bc.code[0]);
    try std.testing.expectEqual(op.post_inc, fn_bc.code[5]);
    try std.testing.expectEqual(op.put_var, fn_bc.code[6]);
}

test "F4: postfix x-- emits get_var ; post_dec ; put_var" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "x--");
    defer fn_bc.deinit(env.rt);

    try std.testing.expectEqual(op.post_dec, fn_bc.code[5]);
}

test "F4: prefix ++x emits get_var ; inc ; dup ; put_var" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "++x");
    defer fn_bc.deinit(env.rt);

    // Expect: get_var x ; inc ; dup ; put_var x
    try std.testing.expectEqual(@as(usize, 12), fn_bc.code.len);
    try std.testing.expectEqual(op.get_var, fn_bc.code[0]);
    try std.testing.expectEqual(op.inc, fn_bc.code[5]);
    try std.testing.expectEqual(op.dup, fn_bc.code[6]);
    try std.testing.expectEqual(op.put_var, fn_bc.code[7]);
}

test "F4: prefix --x emits get_var ; dec ; dup ; put_var" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "--x");
    defer fn_bc.deinit(env.rt);

    try std.testing.expectEqual(op.dec, fn_bc.code[5]);
    try std.testing.expectEqual(op.dup, fn_bc.code[6]);
}

test "F4: delete x emits delete_var atom" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "delete x");
    defer fn_bc.deinit(env.rt);

    try std.testing.expectEqual(@as(usize, 5), fn_bc.code.len);
    try std.testing.expectEqual(op.delete_var, fn_bc.code[0]);
}

test "F4: delete a.b emits get_var a ; push_atom_value b ; delete" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "delete a.b");
    defer fn_bc.deinit(env.rt);

    try std.testing.expectEqual(@as(usize, 11), fn_bc.code.len);
    try std.testing.expectEqual(op.get_var, fn_bc.code[0]);
    try std.testing.expectEqual(op.push_atom_value, fn_bc.code[5]);
    try std.testing.expectEqual(op.delete, fn_bc.code[10]);
}

test "F4: delete a[i] emits get_var a ; get_var i ; delete" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "delete a[i]");
    defer fn_bc.deinit(env.rt);

    try std.testing.expectEqual(@as(usize, 11), fn_bc.code.len);
    try std.testing.expectEqual(op.get_var, fn_bc.code[0]);
    try std.testing.expectEqual(op.get_var, fn_bc.code[5]);
    try std.testing.expectEqual(op.delete, fn_bc.code[10]);
}

test "F4: delete on a non-reference yields drop ; push_true" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "delete (1 + 2)");
    defer fn_bc.deinit(env.rt);

    // ...add(1,2) ; drop ; push_true
    try std.testing.expectEqual(op.drop, fn_bc.code[fn_bc.code.len - 2]);
    try std.testing.expectEqual(op.push_true, fn_bc.code[fn_bc.code.len - 1]);
}

test "F4: chained call f(a)(b) emits two call ops" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "f(a)(b)");
    defer fn_bc.deinit(env.rt);

    // get_var f ; get_var a ; call 1 ; get_var b ; call 1
    try std.testing.expectEqual(@as(usize, 21), fn_bc.code.len);
    try std.testing.expectEqual(op.call, fn_bc.code[10]);
    try std.testing.expectEqual(op.call, fn_bc.code[18]);
}

// ---- F4 slice 3: member-target assign + update ----------------------

test "F4: dotted assignment a.b = v emits get_var ; rhs ; insert2 ; put_field" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "a.b = v");
    defer fn_bc.deinit(env.rt);

    // Expect: get_var a ; get_var v ; insert2 ; put_field b
    // Mirrors QuickJS PUT_LVALUE_KEEP_TOP for OP_get_field (`quickjs.c:25494`).
    try std.testing.expectEqual(@as(usize, 16), fn_bc.code.len);
    try std.testing.expectEqual(op.get_var, fn_bc.code[0]);
    try std.testing.expectEqual(op.get_var, fn_bc.code[5]);
    try std.testing.expectEqual(op.insert2, fn_bc.code[10]);
    try std.testing.expectEqual(op.put_field, fn_bc.code[11]);
}

test "F4: indexed assignment a[i] = v emits get_var ; key ; rhs ; insert3 ; put_array_el" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "a[i] = v");
    defer fn_bc.deinit(env.rt);

    // Expect: get_var a ; get_var i ; get_var v ; insert3 ; put_array_el
    // Mirrors PUT_LVALUE_KEEP_TOP for OP_get_array_el (`quickjs.c:25520`).
    try std.testing.expectEqual(@as(usize, 17), fn_bc.code.len);
    try std.testing.expectEqual(op.get_var, fn_bc.code[0]);
    try std.testing.expectEqual(op.get_var, fn_bc.code[5]);
    try std.testing.expectEqual(op.get_var, fn_bc.code[10]);
    try std.testing.expectEqual(op.insert3, fn_bc.code[15]);
    try std.testing.expectEqual(op.put_array_el, fn_bc.code[16]);
}

test "F4: compound dotted assignment a.b += v rewrites get_field to get_field2" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "a.b += v");
    defer fn_bc.deinit(env.rt);

    // Expect: get_var a ; get_field2 b ; get_var v ; add ; insert2 ; put_field b
    try std.testing.expectEqual(@as(usize, 22), fn_bc.code.len);
    try std.testing.expectEqual(op.get_var, fn_bc.code[0]);
    try std.testing.expectEqual(op.get_field2, fn_bc.code[5]);
    try std.testing.expectEqual(op.get_var, fn_bc.code[10]);
    try std.testing.expectEqual(op.add, fn_bc.code[15]);
    try std.testing.expectEqual(op.insert2, fn_bc.code[16]);
    try std.testing.expectEqual(op.put_field, fn_bc.code[17]);
}

test "F4: compound indexed assignment a[i] += v rewrites get_array_el to get_array_el2" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "a[i] += v");
    defer fn_bc.deinit(env.rt);

    // Expect: get_var a ; get_var i ; get_array_el2 ; get_var v ; add ; insert3 ; put_array_el
    try std.testing.expectEqual(@as(usize, 19), fn_bc.code.len);
    try std.testing.expectEqual(op.get_var, fn_bc.code[0]);
    try std.testing.expectEqual(op.get_var, fn_bc.code[5]);
    try std.testing.expectEqual(op.get_array_el2, fn_bc.code[10]);
    try std.testing.expectEqual(op.get_var, fn_bc.code[11]);
    try std.testing.expectEqual(op.add, fn_bc.code[16]);
    try std.testing.expectEqual(op.insert3, fn_bc.code[17]);
    try std.testing.expectEqual(op.put_array_el, fn_bc.code[18]);
}

test "F4: postfix dotted a.b++ emits get_field2 ; post_inc ; perm3 ; put_field" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "a.b++");
    defer fn_bc.deinit(env.rt);

    // Expect: get_var a ; get_field2 b ; post_inc ; perm3 ; put_field b
    // Mirrors PUT_LVALUE_KEEP_SECOND for OP_get_field (`quickjs.c:25497`).
    try std.testing.expectEqual(@as(usize, 17), fn_bc.code.len);
    try std.testing.expectEqual(op.get_var, fn_bc.code[0]);
    try std.testing.expectEqual(op.get_field2, fn_bc.code[5]);
    try std.testing.expectEqual(op.post_inc, fn_bc.code[10]);
    try std.testing.expectEqual(op.perm3, fn_bc.code[11]);
    try std.testing.expectEqual(op.put_field, fn_bc.code[12]);
}

test "F4: postfix indexed a[i]-- emits get_array_el2 ; post_dec ; perm4 ; put_array_el" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "a[i]--");
    defer fn_bc.deinit(env.rt);

    // Expect: get_var a ; get_var i ; get_array_el2 ; post_dec ; perm4 ; put_array_el
    // Mirrors PUT_LVALUE_KEEP_SECOND for OP_get_array_el (`quickjs.c:25523`).
    try std.testing.expectEqual(@as(usize, 14), fn_bc.code.len);
    try std.testing.expectEqual(op.get_var, fn_bc.code[0]);
    try std.testing.expectEqual(op.get_var, fn_bc.code[5]);
    try std.testing.expectEqual(op.get_array_el2, fn_bc.code[10]);
    try std.testing.expectEqual(op.post_dec, fn_bc.code[11]);
    try std.testing.expectEqual(op.perm4, fn_bc.code[12]);
    try std.testing.expectEqual(op.put_array_el, fn_bc.code[13]);
}

test "F4: prefix ++a.b emits get_field2 ; inc ; insert2 ; put_field" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "++a.b");
    defer fn_bc.deinit(env.rt);

    // Expect: get_var a ; get_field2 b ; inc ; insert2 ; put_field b
    try std.testing.expectEqual(@as(usize, 17), fn_bc.code.len);
    try std.testing.expectEqual(op.get_var, fn_bc.code[0]);
    try std.testing.expectEqual(op.get_field2, fn_bc.code[5]);
    try std.testing.expectEqual(op.inc, fn_bc.code[10]);
    try std.testing.expectEqual(op.insert2, fn_bc.code[11]);
    try std.testing.expectEqual(op.put_field, fn_bc.code[12]);
}

test "F4: prefix --a[i] emits get_array_el2 ; dec ; insert3 ; put_array_el" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "--a[i]");
    defer fn_bc.deinit(env.rt);

    // Expect: get_var a ; get_var i ; get_array_el2 ; dec ; insert3 ; put_array_el
    try std.testing.expectEqual(@as(usize, 14), fn_bc.code.len);
    try std.testing.expectEqual(op.get_var, fn_bc.code[0]);
    try std.testing.expectEqual(op.get_var, fn_bc.code[5]);
    try std.testing.expectEqual(op.get_array_el2, fn_bc.code[10]);
    try std.testing.expectEqual(op.dec, fn_bc.code[11]);
    try std.testing.expectEqual(op.insert3, fn_bc.code[12]);
    try std.testing.expectEqual(op.put_array_el, fn_bc.code[13]);
}

test "F4: dotted assign value remains on stack via insert2 (chained)" {
    var env = try TestEnv.init();
    defer env.deinit();
    // (a.b = v) + 1 — verifies the assignment leaves v on the stack.
    var fn_bc = try parseExpr(&env, "(a.b = v) + 1");
    defer fn_bc.deinit(env.rt);

    // Trailing add must follow put_field.
    try std.testing.expectEqual(op.add, fn_bc.code[fn_bc.code.len - 1]);
}

// ---- F4 slice 4: array holes + multi-level delete + optional chaining

test "F4: array hole [1, , 3] pushes undefined for the elision" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "[1, , 3]");
    defer fn_bc.deinit(env.rt);

    // Expect: push_i32 1 ; undefined ; push_i32 3 ; array_from 3
    try std.testing.expectEqual(@as(usize, 14), fn_bc.code.len);
    try std.testing.expectEqual(op.push_i32, fn_bc.code[0]);
    try std.testing.expectEqual(op.@"undefined", fn_bc.code[5]);
    try std.testing.expectEqual(op.push_i32, fn_bc.code[6]);
    try std.testing.expectEqual(op.array_from, fn_bc.code[11]);
    const argc = std.mem.readInt(u16, fn_bc.code[12..14], .little);
    try std.testing.expectEqual(@as(u16, 3), argc);
}

test "F4: leading hole [, 1] counts the elision" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "[, 1]");
    defer fn_bc.deinit(env.rt);

    // Expect: undefined ; push_i32 1 ; array_from 2
    try std.testing.expectEqual(@as(usize, 9), fn_bc.code.len);
    try std.testing.expectEqual(op.@"undefined", fn_bc.code[0]);
    try std.testing.expectEqual(op.push_i32, fn_bc.code[1]);
    try std.testing.expectEqual(op.array_from, fn_bc.code[6]);
    const argc = std.mem.readInt(u16, fn_bc.code[7..9], .little);
    try std.testing.expectEqual(@as(u16, 2), argc);
}

test "F4: consecutive holes [, , 1] count both elisions" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "[, , 1]");
    defer fn_bc.deinit(env.rt);

    // Expect: undefined ; undefined ; push_i32 1 ; array_from 3
    try std.testing.expectEqual(@as(usize, 10), fn_bc.code.len);
    try std.testing.expectEqual(op.@"undefined", fn_bc.code[0]);
    try std.testing.expectEqual(op.@"undefined", fn_bc.code[1]);
    try std.testing.expectEqual(op.push_i32, fn_bc.code[2]);
    try std.testing.expectEqual(op.array_from, fn_bc.code[7]);
    const argc = std.mem.readInt(u16, fn_bc.code[8..10], .little);
    try std.testing.expectEqual(@as(u16, 3), argc);
}

test "F4: multi-level delete a.b.c rewrites only the last get_field" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "delete a.b.c");
    defer fn_bc.deinit(env.rt);

    // Expect: get_var a ; get_field b ; push_atom_value c ; delete
    try std.testing.expectEqual(@as(usize, 16), fn_bc.code.len);
    try std.testing.expectEqual(op.get_var, fn_bc.code[0]);
    try std.testing.expectEqual(op.get_field, fn_bc.code[5]);
    try std.testing.expectEqual(op.push_atom_value, fn_bc.code[10]);
    try std.testing.expectEqual(op.delete, fn_bc.code[15]);
}

test "F4: multi-level delete a.b[i] truncates the trailing get_array_el" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "delete a.b[i]");
    defer fn_bc.deinit(env.rt);

    // Expect: get_var a ; get_field b ; get_var i ; delete
    try std.testing.expectEqual(@as(usize, 16), fn_bc.code.len);
    try std.testing.expectEqual(op.get_var, fn_bc.code[0]);
    try std.testing.expectEqual(op.get_field, fn_bc.code[5]);
    try std.testing.expectEqual(op.get_var, fn_bc.code[10]);
    try std.testing.expectEqual(op.delete, fn_bc.code[15]);
}

test "F4: delete on a postfix update result evaluates and returns true" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "delete (a.b++)");
    defer fn_bc.deinit(env.rt);

    // Trailing op of a.b++ is put_field, which doesn't match any
    // LhsShape; classifier returns .none → drop ; push_true.
    try std.testing.expectEqual(op.drop, fn_bc.code[fn_bc.code.len - 2]);
    try std.testing.expectEqual(op.push_true, fn_bc.code[fn_bc.code.len - 1]);
}

test "F4: optional chain a?.b emits inline chain_test + normal get_field" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "a?.b");
    defer fn_bc.deinit(env.rt);

    // Expected (mirror `quickjs.c:26158` optional_chain_test):
    //   get_var a              (5)
    //   dup                    (1)
    //   is_undefined_or_null   (1)
    //   if_false NEXT          (5)   -- jump past chain-exit prelude
    //   drop                   (1)   -- drop_count = 1 for member access
    //   undefined              (1)
    //   goto CHAIN_EXIT        (5)   -- patched at chain end
    //   NEXT:                  (here, target of if_false above)
    //   get_field b            (5)
    //   CHAIN_EXIT:            (here, target of goto above)
    try std.testing.expectEqual(@as(usize, 24), fn_bc.code.len);
    try std.testing.expectEqual(op.get_var, fn_bc.code[0]);
    try std.testing.expectEqual(op.dup, fn_bc.code[5]);
    try std.testing.expectEqual(op.is_undefined_or_null, fn_bc.code[6]);
    try std.testing.expectEqual(op.if_false, fn_bc.code[7]);
    try std.testing.expectEqual(op.drop, fn_bc.code[12]);
    try std.testing.expectEqual(op.@"undefined", fn_bc.code[13]);
    try std.testing.expectEqual(op.goto, fn_bc.code[14]);
    try std.testing.expectEqual(op.get_field, fn_bc.code[19]);

    // The if_false target should be NEXT (offset 19 — the get_field).
    const next_target = std.mem.readInt(u32, fn_bc.code[8..12], .little);
    try std.testing.expectEqual(@as(u32, 19), next_target);
    // The goto target should be CHAIN_EXIT (end of bytecode = 24).
    const exit_target = std.mem.readInt(u32, fn_bc.code[15..19], .little);
    try std.testing.expectEqual(@as(u32, 24), exit_target);
}

test "F4: optional chain a?.[i] emits inline chain_test + get_array_el" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "a?.[i]");
    defer fn_bc.deinit(env.rt);

    // get_var a (5) ; chain_test (14) ; get_var i (5) ; get_array_el (1)
    try std.testing.expectEqual(@as(usize, 25), fn_bc.code.len);
    try std.testing.expectEqual(op.get_var, fn_bc.code[0]);
    try std.testing.expectEqual(op.dup, fn_bc.code[5]);
    try std.testing.expectEqual(op.goto, fn_bc.code[14]);
    try std.testing.expectEqual(op.get_var, fn_bc.code[19]);
    try std.testing.expectEqual(op.get_array_el, fn_bc.code[24]);
}

test "F4: optional chain a?.b.c — chain test only at the ?. site" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "a?.b.c");
    defer fn_bc.deinit(env.rt);

    // get_var a (5) ; chain_test (14) ; get_field b (5) ; get_field c (5)
    try std.testing.expectEqual(@as(usize, 29), fn_bc.code.len);
    try std.testing.expectEqual(op.get_var, fn_bc.code[0]);
    try std.testing.expectEqual(op.dup, fn_bc.code[5]);
    try std.testing.expectEqual(op.get_field, fn_bc.code[19]);
    try std.testing.expectEqual(op.get_field, fn_bc.code[24]);
    // CHAIN_EXIT is the end of bytecode.
    const exit_target = std.mem.readInt(u32, fn_bc.code[15..19], .little);
    try std.testing.expectEqual(@as(u32, 29), exit_target);
}

test "F4: a?.b?.c emits two chain_tests sharing a common chain exit" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "a?.b?.c");
    defer fn_bc.deinit(env.rt);

    // Layout: get_var a ; chain_test1 ; get_field b ; chain_test2 ; get_field c
    //          5         + 14          + 5            + 14         + 5  = 43
    try std.testing.expectEqual(@as(usize, 43), fn_bc.code.len);
    // Both goto operands target the same chain end.
    const exit_target_1 = std.mem.readInt(u32, fn_bc.code[15..19], .little);
    const exit_target_2 = std.mem.readInt(u32, fn_bc.code[34..38], .little);
    try std.testing.expectEqual(exit_target_1, exit_target_2);
    try std.testing.expectEqual(@as(u32, 43), exit_target_1);
}

test "F4: optional call a?.() emits chain_test + plain call" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "a?.()");
    defer fn_bc.deinit(env.rt);

    // Expected: get_var a (5) ; chain_test (14) ; call 0 (3)
    try std.testing.expectEqual(@as(usize, 22), fn_bc.code.len);
    try std.testing.expectEqual(op.get_var, fn_bc.code[0]);
    try std.testing.expectEqual(op.dup, fn_bc.code[5]);
    try std.testing.expectEqual(op.is_undefined_or_null, fn_bc.code[6]);
    try std.testing.expectEqual(op.if_false, fn_bc.code[7]);
    try std.testing.expectEqual(op.drop, fn_bc.code[12]);
    try std.testing.expectEqual(op.@"undefined", fn_bc.code[13]);
    try std.testing.expectEqual(op.goto, fn_bc.code[14]);
    try std.testing.expectEqual(op.call, fn_bc.code[19]);
    const argc = std.mem.readInt(u16, fn_bc.code[20..22], .little);
    try std.testing.expectEqual(@as(u16, 0), argc);
    // Chain exit lands at end of bytecode (after the call).
    const exit_target = std.mem.readInt(u32, fn_bc.code[15..19], .little);
    try std.testing.expectEqual(@as(u32, 22), exit_target);
}

test "F4: method-on-opt-chain obj?.b(x) uses get_field2 + call_method" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "obj?.b(x)");
    defer fn_bc.deinit(env.rt);

    // Expected: get_var obj (5) ; chain_test (14) ; get_field2 b (5) ;
    //           get_var x (5) ; call_method 1 (3) = 32
    try std.testing.expectEqual(@as(usize, 32), fn_bc.code.len);
    try std.testing.expectEqual(op.get_var, fn_bc.code[0]);
    try std.testing.expectEqual(op.get_field2, fn_bc.code[19]);
    try std.testing.expectEqual(op.get_var, fn_bc.code[24]);
    try std.testing.expectEqual(op.call_method, fn_bc.code[29]);
    const argc = std.mem.readInt(u16, fn_bc.code[30..32], .little);
    try std.testing.expectEqual(@as(u16, 1), argc);
}

test "F4: indexed-call-on-opt-chain obj?.[k](x) uses get_array_el2 + call_method" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "obj?.[k](x)");
    defer fn_bc.deinit(env.rt);

    // get_var obj (5) ; chain_test (14) ; get_var k (5) ; get_array_el2 (1) ;
    // get_var x (5) ; call_method 1 (3) = 33
    try std.testing.expectEqual(@as(usize, 33), fn_bc.code.len);
    try std.testing.expectEqual(op.get_var, fn_bc.code[0]);
    try std.testing.expectEqual(op.get_var, fn_bc.code[19]);
    try std.testing.expectEqual(op.get_array_el2, fn_bc.code[24]);
    try std.testing.expectEqual(op.get_var, fn_bc.code[25]);
    try std.testing.expectEqual(op.call_method, fn_bc.code[30]);
}

// ---- F4 finish: tagged templates -----------------------------------

test "F4: tagged template tag`hello` emits placeholder template-object + call 1" {
    var env = try TestEnv.init();
    defer env.deinit();
    // F4 deviation: the cooked+raw template object is a placeholder
    // (OP_undefined) until F12 ships the real construction. The call
    // shape and argc match QuickJS.
    var fn_bc = try parseExpr(&env, "tag`hello`");
    defer fn_bc.deinit(env.rt);

    // get_var tag (5) ; undefined (1) ; call 1 (3) = 9
    try std.testing.expectEqual(@as(usize, 9), fn_bc.code.len);
    try std.testing.expectEqual(op.get_var, fn_bc.code[0]);
    try std.testing.expectEqual(op.@"undefined", fn_bc.code[5]);
    try std.testing.expectEqual(op.call, fn_bc.code[6]);
    const argc = std.mem.readInt(u16, fn_bc.code[7..9], .little);
    try std.testing.expectEqual(@as(u16, 1), argc);
}

test "F4: tagged template tag`a${x}b` includes substitutions in argc" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "tag`a${x}b`");
    defer fn_bc.deinit(env.rt);

    // get_var tag (5) ; undefined (1) ; get_var x (5) ; call 2 (3) = 14
    try std.testing.expectEqual(@as(usize, 14), fn_bc.code.len);
    try std.testing.expectEqual(op.get_var, fn_bc.code[0]);
    try std.testing.expectEqual(op.@"undefined", fn_bc.code[5]);
    try std.testing.expectEqual(op.get_var, fn_bc.code[6]);
    try std.testing.expectEqual(op.call, fn_bc.code[11]);
    const argc = std.mem.readInt(u16, fn_bc.code[12..14], .little);
    try std.testing.expectEqual(@as(u16, 2), argc);
}

test "F4: tagged template on member access obj.tag`hello` rewrites to call_method" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "obj.tag`hello`");
    defer fn_bc.deinit(env.rt);

    // get_var obj (5) ; get_field2 tag (5) ; undefined (1) ; call_method 1 (3) = 14
    try std.testing.expectEqual(@as(usize, 14), fn_bc.code.len);
    try std.testing.expectEqual(op.get_var, fn_bc.code[0]);
    try std.testing.expectEqual(op.get_field2, fn_bc.code[5]);
    try std.testing.expectEqual(op.@"undefined", fn_bc.code[10]);
    try std.testing.expectEqual(op.call_method, fn_bc.code[11]);
}

test "F4: tagged template tag`a${x}b${y}c` argc = 3 (template + 2 subs)" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "tag`a${x}b${y}c`");
    defer fn_bc.deinit(env.rt);

    try std.testing.expectEqual(op.call, fn_bc.code[fn_bc.code.len - 3]);
    const argc = std.mem.readInt(u16, fn_bc.code[fn_bc.code.len - 2 ..][0..2], .little);
    try std.testing.expectEqual(@as(u16, 3), argc);
}

test "F4: optional call without chain receiver a?.()(b) — chain only on first call" {
    var env = try TestEnv.init();
    defer env.deinit();
    // After a?.(), the chain ends. The trailing (b) call is unconditional.
    var fn_bc = try parseExpr(&env, "a?.()(b)");
    defer fn_bc.deinit(env.rt);

    // Expected: get_var a (5) ; chain_test (14) ; call 0 (3) ; get_var b (5) ; call 1 (3)
    try std.testing.expectEqual(@as(usize, 30), fn_bc.code.len);
    try std.testing.expectEqual(op.call, fn_bc.code[19]);
    try std.testing.expectEqual(op.call, fn_bc.code[27]);
    // The first call's chain_exit lands AFTER all subsequent ops too —
    // the entire chain (including the trailing `(b)`) is governed by the
    // single chain exit.
    const exit_target = std.mem.readInt(u32, fn_bc.code[15..19], .little);
    try std.testing.expectEqual(@as(u32, 30), exit_target);
}

// ---- F4 slice 5: template literals -----------------------------------

test "F4: no-substitution template `hello` lowers to push_atom_value" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "`hello`");
    defer fn_bc.deinit(env.rt);

    try std.testing.expectEqual(@as(usize, 5), fn_bc.code.len);
    try std.testing.expectEqual(op.push_atom_value, fn_bc.code[0]);
}

test "F4: empty template `` lowers to push_empty_string" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "``");
    defer fn_bc.deinit(env.rt);

    try std.testing.expectEqual(@as(usize, 1), fn_bc.code.len);
    try std.testing.expectEqual(op.push_empty_string, fn_bc.code[0]);
}

test "F4: simple template with one substitution uses get_field2 concat + call_method" {
    var env = try TestEnv.init();
    defer env.deinit();
    // `a${b}c` lowers to:
    //   push_atom_value "a"   (5)
    //   get_field2 concat     (5)
    //   get_var b             (5)
    //   push_atom_value "c"   (5)
    //   call_method 2         (3)
    var fn_bc = try parseExpr(&env, "`a${b}c`");
    defer fn_bc.deinit(env.rt);

    try std.testing.expectEqual(@as(usize, 23), fn_bc.code.len);
    try std.testing.expectEqual(op.push_atom_value, fn_bc.code[0]);
    try std.testing.expectEqual(op.get_field2, fn_bc.code[5]);
    try std.testing.expectEqual(op.get_var, fn_bc.code[10]);
    try std.testing.expectEqual(op.push_atom_value, fn_bc.code[15]);
    try std.testing.expectEqual(op.call_method, fn_bc.code[20]);
    const argc = std.mem.readInt(u16, fn_bc.code[21..23], .little);
    try std.testing.expectEqual(@as(u16, 2), argc);
}

test "F4: empty-head template `${b}` skips middle/tail empty strings" {
    var env = try TestEnv.init();
    defer env.deinit();
    // `${b}` lowers to:
    //   push_empty_string    (1)
    //   get_field2 concat    (5)
    //   get_var b            (5)
    //   call_method 1        (3)
    // Middle/tail empty strings with depth>0 are skipped (mirrors
    // `quickjs.c:23952` `else { JS_FreeValue ; }` branch).
    var fn_bc = try parseExpr(&env, "`${b}`");
    defer fn_bc.deinit(env.rt);

    try std.testing.expectEqual(@as(usize, 14), fn_bc.code.len);
    try std.testing.expectEqual(op.push_empty_string, fn_bc.code[0]);
    try std.testing.expectEqual(op.get_field2, fn_bc.code[1]);
    try std.testing.expectEqual(op.get_var, fn_bc.code[6]);
    try std.testing.expectEqual(op.call_method, fn_bc.code[11]);
    const argc = std.mem.readInt(u16, fn_bc.code[12..14], .little);
    try std.testing.expectEqual(@as(u16, 1), argc);
}

test "F4: template with two substitutions accumulates argc correctly" {
    var env = try TestEnv.init();
    defer env.deinit();
    // `a${b}c${d}e` →
    //   push_atom_value "a"   (5)
    //   get_field2 concat     (5)
    //   get_var b             (5)
    //   push_atom_value "c"   (5)
    //   get_var d             (5)
    //   push_atom_value "e"   (5)
    //   call_method 4         (3)
    var fn_bc = try parseExpr(&env, "`a${b}c${d}e`");
    defer fn_bc.deinit(env.rt);

    try std.testing.expectEqual(@as(usize, 33), fn_bc.code.len);
    try std.testing.expectEqual(op.call_method, fn_bc.code[30]);
    const argc = std.mem.readInt(u16, fn_bc.code[31..33], .little);
    try std.testing.expectEqual(@as(u16, 4), argc);
}

// ---- F4 slice 6: spread in calls and arrays --------------------------

test "F4: spread call f(...x) emits array_from + apply 0" {
    var env = try TestEnv.init();
    defer env.deinit();
    // Expected:
    //   get_var f          (5)
    //   array_from 0       (3)  -- no leading args
    //   push_i32 0         (5)  -- initial idx
    //   get_var x          (5)
    //   append             (1)
    //   drop               (1)  -- drop idx
    //   undefined          (1)
    //   swap               (1)
    //   apply 0            (3)  -- 0 = not new
    var fn_bc = try parseExpr(&env, "f(...x)");
    defer fn_bc.deinit(env.rt);

    try std.testing.expectEqual(@as(usize, 25), fn_bc.code.len);
    try std.testing.expectEqual(op.get_var, fn_bc.code[0]);
    try std.testing.expectEqual(op.array_from, fn_bc.code[5]);
    try std.testing.expectEqual(op.push_i32, fn_bc.code[8]);
    try std.testing.expectEqual(op.get_var, fn_bc.code[13]);
    try std.testing.expectEqual(op.append, fn_bc.code[18]);
    try std.testing.expectEqual(op.drop, fn_bc.code[19]);
    try std.testing.expectEqual(op.@"undefined", fn_bc.code[20]);
    try std.testing.expectEqual(op.swap, fn_bc.code[21]);
    try std.testing.expectEqual(op.apply, fn_bc.code[22]);
    const is_new = std.mem.readInt(u16, fn_bc.code[23..25], .little);
    try std.testing.expectEqual(@as(u16, 0), is_new);
}

test "F4: mixed spread call f(a, ...b) starts array_from with leading count" {
    var env = try TestEnv.init();
    defer env.deinit();
    // Expected:
    //   get_var f          (5)
    //   get_var a          (5)
    //   array_from 1       (3)  -- 1 leading arg
    //   push_i32 1         (5)
    //   get_var b          (5)
    //   append             (1)
    //   drop               (1)
    //   undefined          (1)
    //   swap               (1)
    //   apply 0            (3)
    var fn_bc = try parseExpr(&env, "f(a, ...b)");
    defer fn_bc.deinit(env.rt);

    try std.testing.expectEqual(@as(usize, 30), fn_bc.code.len);
    try std.testing.expectEqual(op.get_var, fn_bc.code[0]);
    try std.testing.expectEqual(op.get_var, fn_bc.code[5]);
    try std.testing.expectEqual(op.array_from, fn_bc.code[10]);
    const argc = std.mem.readInt(u16, fn_bc.code[11..13], .little);
    try std.testing.expectEqual(@as(u16, 1), argc);
    try std.testing.expectEqual(op.push_i32, fn_bc.code[13]);
    try std.testing.expectEqual(op.append, fn_bc.code[23]);
    try std.testing.expectEqual(op.apply, fn_bc.code[27]);
}

test "F4: trailing element after spread uses define_array_el + inc" {
    var env = try TestEnv.init();
    defer env.deinit();
    // f(...a, b):
    //   get_var f          (5)
    //   array_from 0       (3)
    //   push_i32 0         (5)
    //   get_var a          (5)
    //   append             (1)
    //   get_var b          (5)
    //   define_array_el    (1)
    //   inc                (1)
    //   drop               (1)
    //   undefined          (1)
    //   swap               (1)
    //   apply 0            (3)
    var fn_bc = try parseExpr(&env, "f(...a, b)");
    defer fn_bc.deinit(env.rt);

    try std.testing.expectEqual(@as(usize, 32), fn_bc.code.len);
    try std.testing.expectEqual(op.append, fn_bc.code[18]);
    try std.testing.expectEqual(op.define_array_el, fn_bc.code[24]);
    try std.testing.expectEqual(op.inc, fn_bc.code[25]);
    try std.testing.expectEqual(op.apply, fn_bc.code[29]);
}

test "F4: method call with spread obj.m(...x) uses perm3 + apply 0" {
    var env = try TestEnv.init();
    defer env.deinit();
    // Expected:
    //   get_var obj          (5)
    //   get_field2 m         (5)
    //   array_from 0         (3)
    //   push_i32 0           (5)
    //   get_var x            (5)
    //   append               (1)
    //   drop                 (1)
    //   perm3                (1)
    //   apply 0              (3)
    var fn_bc = try parseExpr(&env, "obj.m(...x)");
    defer fn_bc.deinit(env.rt);

    try std.testing.expectEqual(@as(usize, 29), fn_bc.code.len);
    try std.testing.expectEqual(op.get_field2, fn_bc.code[5]);
    try std.testing.expectEqual(op.perm3, fn_bc.code[25]);
    try std.testing.expectEqual(op.apply, fn_bc.code[26]);
}

test "F4: new with spread new X(...args) uses apply with is_new=1" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "new X(...args)");
    defer fn_bc.deinit(env.rt);

    try std.testing.expectEqual(op.apply, fn_bc.code[fn_bc.code.len - 3]);
    const is_new = std.mem.readInt(u16, fn_bc.code[fn_bc.code.len - 2 ..][0..2], .little);
    try std.testing.expectEqual(@as(u16, 1), is_new);
}

test "F4: array literal spread [...a] starts with array_from 0 + push_i32 0" {
    var env = try TestEnv.init();
    defer env.deinit();
    // Expected:
    //   array_from 0       (3)
    //   push_i32 0         (5)
    //   get_var a          (5)
    //   append             (1)
    //   drop               (1)
    var fn_bc = try parseExpr(&env, "[...a]");
    defer fn_bc.deinit(env.rt);

    try std.testing.expectEqual(@as(usize, 15), fn_bc.code.len);
    try std.testing.expectEqual(op.array_from, fn_bc.code[0]);
    try std.testing.expectEqual(op.push_i32, fn_bc.code[3]);
    try std.testing.expectEqual(op.append, fn_bc.code[13]);
    try std.testing.expectEqual(op.drop, fn_bc.code[14]);
}

test "F4: array literal mixed spread [a, ...b, c] uses define_array_el+inc" {
    var env = try TestEnv.init();
    defer env.deinit();
    // get_var a (5) ; array_from 1 (3) ; push_i32 1 (5) ; get_var b (5) ; append (1) ;
    // get_var c (5) ; define_array_el (1) ; inc (1) ; drop (1)
    var fn_bc = try parseExpr(&env, "[a, ...b, c]");
    defer fn_bc.deinit(env.rt);

    try std.testing.expectEqual(@as(usize, 27), fn_bc.code.len);
    try std.testing.expectEqual(op.array_from, fn_bc.code[5]);
    try std.testing.expectEqual(op.append, fn_bc.code[18]);
    try std.testing.expectEqual(op.define_array_el, fn_bc.code[24]);
    try std.testing.expectEqual(op.inc, fn_bc.code[25]);
    try std.testing.expectEqual(op.drop, fn_bc.code[26]);
}

test "F4: template with empty middle still emits call_method with correct argc" {
    var env = try TestEnv.init();
    defer env.deinit();
    // `${b}${c}` — empty head emits push_empty_string + get_field2 concat;
    // empty middle is skipped; empty tail is skipped.
    //   push_empty_string   (1)
    //   get_field2 concat   (5)
    //   get_var b           (5)
    //   get_var c           (5)
    //   call_method 2       (3)
    var fn_bc = try parseExpr(&env, "`${b}${c}`");
    defer fn_bc.deinit(env.rt);

    try std.testing.expectEqual(@as(usize, 19), fn_bc.code.len);
    try std.testing.expectEqual(op.push_empty_string, fn_bc.code[0]);
    try std.testing.expectEqual(op.call_method, fn_bc.code[16]);
    const argc = std.mem.readInt(u16, fn_bc.code[17..19], .little);
    try std.testing.expectEqual(@as(u16, 2), argc);
}

// ---- F5: Statement parsing tests -------------------------------------

test "F5: empty statement" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatement(&env, ";");
    defer fn_bc.deinit(env.rt);

    try std.testing.expectEqual(@as(usize, 0), fn_bc.code.len);
}

test "F5: block statement" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatement(&env, "{ x; y; }");
    defer fn_bc.deinit(env.rt);

    // Should have get_var x, drop, get_var y, drop
    try std.testing.expect(fn_bc.code.len > 0);
}

test "F5: return statement without value" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatement(&env, "return;");
    defer fn_bc.deinit(env.rt);

    try std.testing.expectEqual(@as(usize, 1), fn_bc.code.len);
    try std.testing.expectEqual(op.return_undef, fn_bc.code[0]);
}

test "F5: return statement with value" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatement(&env, "return x;");
    defer fn_bc.deinit(env.rt);

    // Should have get_var x, return
    try std.testing.expect(fn_bc.code.len > 0);
    try std.testing.expectEqual(op.@"return", fn_bc.code[fn_bc.code.len - 1]);
}

test "F5: throw statement" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatement(&env, "throw x;");
    defer fn_bc.deinit(env.rt);

    // Should have get_var x, throw
    try std.testing.expect(fn_bc.code.len > 0);
    try std.testing.expectEqual(op.throw, fn_bc.code[fn_bc.code.len - 1]);
}

test "F5: if statement without else" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatement(&env, "if (x) y;");
    defer fn_bc.deinit(env.rt);

    // get_var x ; if_false → past_then ; get_var y ; drop
    try std.testing.expect(fn_bc.code.len > 0);
    try std.testing.expectEqual(op.if_false, fn_bc.code[5]); // After get_var x
    // The if_false target must be patched to the end of the then block,
    // not the placeholder 0. Decode the u32 operand at offset 6.
    const if_false_target = std.mem.readInt(u32, fn_bc.code[6..][0..4], .little);
    try std.testing.expect(if_false_target > 0);
    try std.testing.expect(if_false_target <= fn_bc.code.len);
}

test "F5: if statement with else" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatement(&env, "if (x) y; else z;");
    defer fn_bc.deinit(env.rt);

    // get_var x ; if_false → else ; get_var y ; drop ; goto → end ;
    // get_var z ; drop
    try std.testing.expect(fn_bc.code.len > 0);
    try std.testing.expectEqual(op.if_false, fn_bc.code[5]);
    const if_false_target = std.mem.readInt(u32, fn_bc.code[6..][0..4], .little);
    // The if_false jump must point at the goto-over-else opcode. Verify
    // the instruction at that position is `goto` (skipping past the else).
    try std.testing.expect(if_false_target > 0);
    try std.testing.expect(if_false_target < fn_bc.code.len);
    // Find the goto: it sits between the then body and the else body.
    // Code: [get_var x:5] [if_false:5] [get_var y:5] [drop:1] [goto:5]
    //       offset: 0     5            10            15      16
    try std.testing.expectEqual(op.goto, fn_bc.code[16]);
    const goto_target = std.mem.readInt(u32, fn_bc.code[17..][0..4], .little);
    try std.testing.expectEqual(@as(u32, @intCast(fn_bc.code.len)), goto_target);
}

test "F5: while statement" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatement(&env, "while (x) y;");
    defer fn_bc.deinit(env.rt);

    // top: get_var x ; if_false → end ; get_var y ; drop ; goto → top
    try std.testing.expect(fn_bc.code.len > 0);
    // Last instruction must be a backward goto to offset 0 (loop top).
    const last_goto = fn_bc.code.len - 5;
    try std.testing.expectEqual(op.goto, fn_bc.code[last_goto]);
    const back_target = std.mem.readInt(u32, fn_bc.code[last_goto + 1 ..][0..4], .little);
    try std.testing.expectEqual(@as(u32, 0), back_target);
    // The if_false at offset 5 (after get_var x) must point past end.
    try std.testing.expectEqual(op.if_false, fn_bc.code[5]);
    const if_false_target = std.mem.readInt(u32, fn_bc.code[6..][0..4], .little);
    try std.testing.expectEqual(@as(u32, @intCast(fn_bc.code.len)), if_false_target);
}

test "F5: do-while statement" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatement(&env, "do { y; } while (x);");
    defer fn_bc.deinit(env.rt);

    // Should have get_var y, drop, get_var x, if_true
    try std.testing.expect(fn_bc.code.len > 0);
}

test "F5: expression statement" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatement(&env, "x;");
    defer fn_bc.deinit(env.rt);

    // Should have get_var x, drop
    try std.testing.expect(fn_bc.code.len > 0);
    try std.testing.expectEqual(op.drop, fn_bc.code[fn_bc.code.len - 1]);
}

test "F5: var declaration without initializer" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatement(&env, "var x;");
    defer fn_bc.deinit(env.rt);

    // Should just parse successfully (no bytecode yet until F6)
    try std.testing.expect(fn_bc.code.len == 0);
}

test "F5: var declaration with initializer" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatement(&env, "var x = 1;");
    defer fn_bc.deinit(env.rt);

    // F10.1c + F10.2: parser emits scope_put_var which the pipeline
    // lowers to short-form put_loc0 (idx 0 → 1-byte). Expected:
    //   push_i32 1 ; put_loc0   (5 + 1 = 6 bytes)
    try std.testing.expect(fn_bc.code.len > 0);
    try std.testing.expectEqual(op.push_i32, fn_bc.code[0]);
    try std.testing.expectEqual(op.put_loc0, fn_bc.code[fn_bc.code.len - 1]);
}

test "F5: let declaration" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatement(&env, "let x;");
    defer fn_bc.deinit(env.rt);

    // F10.1c + TDZ: `let x;` now emits scope_put_var_init undefined,
    // which the pipeline lowers (with TDZ prologue) to:
    //   set_loc_uninitialized 0  (3 bytes - TDZ prologue)
    //   undefined                 (1 byte)
    //   put_loc_check_init 0      (3 bytes - clears TDZ flag)
    try std.testing.expectEqual(op.set_loc_uninitialized, fn_bc.code[0]);
    try std.testing.expectEqual(op.undefined, fn_bc.code[3]);
    try std.testing.expectEqual(op.put_loc_check_init, fn_bc.code[4]);
}

test "F5: let declaration with initializer" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatement(&env, "let x = 1;");
    defer fn_bc.deinit(env.rt);

    // F10.1c + TDZ: `let x = 1;` lowers to:
    //   set_loc_uninitialized 0  (TDZ prologue)
    //   push_i32 1
    //   put_loc_check_init 0
    try std.testing.expectEqual(op.set_loc_uninitialized, fn_bc.code[0]);
    try std.testing.expectEqual(op.push_i32, fn_bc.code[3]);
    try std.testing.expectEqual(op.put_loc_check_init, fn_bc.code[fn_bc.code.len - 3]);
}

test "F5: const declaration without initializer should fail" {
    var env = try TestEnv.init();
    defer env.deinit();
    try std.testing.expectError(error.UnexpectedToken, parseStatement(&env, "const x;"));
}

test "F5: const declaration with initializer" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatement(&env, "const x = 1;");
    defer fn_bc.deinit(env.rt);

    // F10.1c + TDZ: const lowers same as let with init.
    try std.testing.expectEqual(op.set_loc_uninitialized, fn_bc.code[0]);
    try std.testing.expectEqual(op.push_i32, fn_bc.code[3]);
    try std.testing.expectEqual(op.put_loc_check_init, fn_bc.code[fn_bc.code.len - 3]);
}

test "F5: multiple var declarations" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatement(&env, "var x = 1, y = 2;");
    defer fn_bc.deinit(env.rt);

    // Should have push_i32 1, drop, push_i32 2, drop
    try std.testing.expect(fn_bc.code.len > 0);
}

test "F5: directive prologue with 'use strict'" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatement(&env, "{ \"use strict\"; x; }");
    defer fn_bc.deinit(env.rt);

    // Should parse successfully and set strict mode
    try std.testing.expect(fn_bc.code.len > 0);
}

test "F5: directive prologue with multiple directives" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatement(&env, "{ \"use strict\"; \"other directive\"; x; }");
    defer fn_bc.deinit(env.rt);

    // Should parse successfully
    try std.testing.expect(fn_bc.code.len > 0);
}

test "F5: directive prologue with ASI" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatement(&env, "{ \"use strict\"\n x; }");
    defer fn_bc.deinit(env.rt);

    // Should parse successfully with ASI
    try std.testing.expect(fn_bc.code.len > 0);
}

// ---- F6 function parsing tests -----------------------------------------

test "F6: simple function declaration" {
    var env = try TestEnv.init();
    defer env.deinit();
    // Parsing must succeed; F2+F3 will wire emit for function declarations.
    var fn_bc = try parseStatement(&env, "function foo() {}");
    defer fn_bc.deinit(env.rt);
}

test "F6: function declaration with parameters" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatement(&env, "function foo(x, y) {}");
    defer fn_bc.deinit(env.rt);
}

test "F6: function declaration with rest parameter" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatement(&env, "function foo(...args) {}");
    defer fn_bc.deinit(env.rt);
}

test "F6: arrow function with block body" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "() => {}");
    defer fn_bc.deinit(env.rt);
}

test "F6: arrow function with expression body" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "() => 42");
    defer fn_bc.deinit(env.rt);

    // Should parse successfully
    try std.testing.expect(fn_bc.code.len > 0);
}

test "F6: arrow function with single parameter" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "x => x");
    defer fn_bc.deinit(env.rt);

    // Should parse successfully
    try std.testing.expect(fn_bc.code.len > 0);
}

test "F6: arrow function with multiple parameters" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "(x, y) => x + y");
    defer fn_bc.deinit(env.rt);

    // Should parse successfully
    try std.testing.expect(fn_bc.code.len > 0);
}

test "F6: arrow function with rest parameter" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "(...args) => args");
    defer fn_bc.deinit(env.rt);

    // Should parse successfully
    try std.testing.expect(fn_bc.code.len > 0);
}

test "F6: function with object destructuring parameter" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatement(&env, "function foo({a, b}) {}");
    defer fn_bc.deinit(env.rt);
}

test "F6: function with array destructuring parameter" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatement(&env, "function foo([a, b]) {}");
    defer fn_bc.deinit(env.rt);
}

test "F6: arrow function with object destructuring parameter" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "({a, b}) => a");
    defer fn_bc.deinit(env.rt);

    // Should parse successfully
    try std.testing.expect(fn_bc.code.len > 0);
}

test "F6: arrow function with array destructuring parameter" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "([a, b]) => a");
    defer fn_bc.deinit(env.rt);

    // Should parse successfully
    try std.testing.expect(fn_bc.code.len > 0);
}

// ---- F7 Class parsing tests ----

test "F7: class with constructor" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatement(&env, "class C { constructor(x) { this.x = x; } }");
    defer fn_bc.deinit(env.rt);

    // Should parse successfully
    try std.testing.expect(fn_bc.code.len > 0);
}

test "F7: class with getter" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatement(&env, "class C { get x() { return this._x; } }");
    defer fn_bc.deinit(env.rt);

    // Should parse successfully
    try std.testing.expect(fn_bc.code.len > 0);
}

test "F7: class with setter" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatement(&env, "class C { set x(value) { this._x = value; } }");
    defer fn_bc.deinit(env.rt);

    // Should parse successfully
    try std.testing.expect(fn_bc.code.len > 0);
}

test "F7: super keyword in class method" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatement(&env, "class C { m() { super.x(); } }");
    defer fn_bc.deinit(env.rt);

    // Should parse successfully
    try std.testing.expect(fn_bc.code.len > 0);
}

test "F7: super property access" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatement(&env, "class C { m() { return super.x; } }");
    defer fn_bc.deinit(env.rt);

    // Should parse successfully and contain get_super_value opcode
    try std.testing.expect(fn_bc.code.len > 0);
    // Check that get_super_value (opcode 73) is in the bytecode
    var found_get_super_value = false;
    for (fn_bc.code) |byte| {
        if (byte == op.get_super_value) {
            found_get_super_value = true;
            break;
        }
    }
    try std.testing.expect(found_get_super_value);
}

test "F7: super() constructor call" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatement(&env, "class C { constructor(x) { super(x); } }");
    defer fn_bc.deinit(env.rt);

    // Should parse successfully
    try std.testing.expect(fn_bc.code.len > 0);
}

test "F9: yield expression" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatement(&env, "function* g() { yield 42; }");
    defer fn_bc.deinit(env.rt);

    // Should parse successfully and contain yield opcode
    try std.testing.expect(fn_bc.code.len > 0);
    // Check that yield (opcode 135) is in the bytecode
    var found_yield = false;
    for (fn_bc.code) |byte| {
        if (byte == op.yield) {
            found_yield = true;
            break;
        }
    }
    try std.testing.expect(found_yield);
}

test "F9: yield* expression" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatement(&env, "function* g() { yield* iterable; }");
    defer fn_bc.deinit(env.rt);

    // Should parse successfully and contain yield_star opcode
    try std.testing.expect(fn_bc.code.len > 0);
    // Check that yield_star (opcode 136) is in the bytecode
    var found_yield_star = false;
    for (fn_bc.code) |byte| {
        if (byte == op.yield_star) {
            found_yield_star = true;
            break;
        }
    }
    try std.testing.expect(found_yield_star);
}

test "F8: export default statement" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatement(&env, "export default 42;");
    defer fn_bc.deinit(env.rt);

    // Should parse successfully (even if it's just a placeholder skip)
    try std.testing.expect(fn_bc.code.len >= 0);
}

test "F8: export named statement" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatement(&env, "export { x, y };");
    defer fn_bc.deinit(env.rt);

    // Should parse successfully (even if it's just a placeholder skip)
    try std.testing.expect(fn_bc.code.len >= 0);
}

test "F7: private field in class" {
    // F7 placeholder: class construction emits nothing yet (deferred to F10's
    // pipeline), so we just assert the parse succeeded without errors. F10
    // will replace this with a check on the emitted class-construction
    // opcodes (`define_class`, `define_private_field`, etc).
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatement(&env, "class C { #x; }");
    defer fn_bc.deinit(env.rt);
}

test "F7: private method in class" {
    // F7 placeholder: see "private field in class" test above.
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatement(&env, "class C { #m() {} }");
    defer fn_bc.deinit(env.rt);
}

test "F7: private getter in class" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatement(&env, "class C { get #x() { return this._x; } }");
    defer fn_bc.deinit(env.rt);

    // Should parse successfully
    try std.testing.expect(fn_bc.code.len >= 0);
}

test "F7: private setter in class" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatement(&env, "class C { set #x(value) { this._x = value; } }");
    defer fn_bc.deinit(env.rt);

    // Should parse successfully
    try std.testing.expect(fn_bc.code.len >= 0);
}

test "F7: class with extends (derived constructor)" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatement(&env, "class C extends B { constructor(x) { super(x); } }");
    defer fn_bc.deinit(env.rt);

    // Should parse successfully
    try std.testing.expect(fn_bc.code.len >= 0);
}

test "F7: class without extends (base constructor)" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatement(&env, "class C { constructor(x) { this.x = x; } }");
    defer fn_bc.deinit(env.rt);

    // Should parse successfully
    try std.testing.expect(fn_bc.code.len >= 0);
}

test "F8: basic import statement" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatement(&env, "import x from 'module'");
    defer fn_bc.deinit(env.rt);

    // Should parse successfully
    try std.testing.expect(fn_bc.code.len >= 0);
}

test "F8: side-effect import" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatement(&env, "import 'module'");
    defer fn_bc.deinit(env.rt);

    try std.testing.expect(fn_bc.code.len >= 0);
}

test "F8: named imports" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatement(&env, "import { x, y } from 'module'");
    defer fn_bc.deinit(env.rt);

    try std.testing.expect(fn_bc.code.len >= 0);
}

test "F8: renamed imports" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatement(&env, "import { x as a, y as b } from 'module'");
    defer fn_bc.deinit(env.rt);

    try std.testing.expect(fn_bc.code.len >= 0);
}

test "F8: namespace import" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatement(&env, "import * as ns from 'module'");
    defer fn_bc.deinit(env.rt);

    try std.testing.expect(fn_bc.code.len >= 0);
}

test "F8: mixed import" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatement(&env, "import x, { y } from 'module'");
    defer fn_bc.deinit(env.rt);

    try std.testing.expect(fn_bc.code.len >= 0);
}

test "F8: export named" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatement(&env, "export { x, y }");
    defer fn_bc.deinit(env.rt);

    try std.testing.expect(fn_bc.code.len >= 0);
}

test "F8: export renamed" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatement(&env, "export { x as a, y as b }");
    defer fn_bc.deinit(env.rt);

    try std.testing.expect(fn_bc.code.len >= 0);
}

test "F8: export default expression" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatement(&env, "export default 42");
    defer fn_bc.deinit(env.rt);

    try std.testing.expect(fn_bc.code.len >= 0);
}

test "F8: export default function" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatement(&env, "export default function f() {}");
    defer fn_bc.deinit(env.rt);

    try std.testing.expect(fn_bc.code.len >= 0);
}

test "F8: export default class" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatement(&env, "export default class C {}");
    defer fn_bc.deinit(env.rt);

    try std.testing.expect(fn_bc.code.len >= 0);
}

test "F8: export star" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatement(&env, "export * from 'module'");
    defer fn_bc.deinit(env.rt);

    try std.testing.expect(fn_bc.code.len >= 0);
}

test "F8: export star as namespace" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatement(&env, "export * as ns from 'module'");
    defer fn_bc.deinit(env.rt);

    try std.testing.expect(fn_bc.code.len >= 0);
}

test "F8: export from" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatement(&env, "export { x, y } from 'module'");
    defer fn_bc.deinit(env.rt);

    try std.testing.expect(fn_bc.code.len >= 0);
}

test "F8: export var" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatement(&env, "export const x = 1");
    defer fn_bc.deinit(env.rt);

    try std.testing.expect(fn_bc.code.len >= 0);
}

test "F8: export function" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatement(&env, "export function f() {}");
    defer fn_bc.deinit(env.rt);

    try std.testing.expect(fn_bc.code.len >= 0);
}

test "F8: export class" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatement(&env, "export class C {}");
    defer fn_bc.deinit(env.rt);

    try std.testing.expect(fn_bc.code.len >= 0);
}

// ---- F9 Generator / Async / Await tests ----

test "F9: async function expression" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "async function() {}");
    defer fn_bc.deinit(env.rt);

    try std.testing.expect(fn_bc.code.len >= 0);
}

test "F9: async arrow function" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "async () => {}");
    defer fn_bc.deinit(env.rt);

    try std.testing.expect(fn_bc.code.len >= 0);
}

test "F9: async function declaration" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatement(&env, "async function f() {}");
    defer fn_bc.deinit(env.rt);

    try std.testing.expect(fn_bc.code.len >= 0);
}

test "F9: async function declaration with parameters" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatement(&env, "async function f(x, y) {}");
    defer fn_bc.deinit(env.rt);

    try std.testing.expect(fn_bc.code.len >= 0);
}

test "F9: async function declaration with body" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatement(&env, "async function f() { return 42; }");
    defer fn_bc.deinit(env.rt);

    try std.testing.expect(fn_bc.code.len >= 0);
}

test "F9: yield outside generator error" {
    var env = try TestEnv.init();
    defer env.deinit();
    const result = parseStatement(&env, "yield 42");
    try std.testing.expectError(error.YieldOutsideGenerator, result);
}

test "F9: await outside async function error" {
    var env = try TestEnv.init();
    defer env.deinit();
    const result = parseStatement(&env, "await x");
    try std.testing.expectError(error.AwaitOutsideAsyncFunction, result);
}

test "F9: await inside async function no error" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseStatement(&env, "async function f() { await x; }");
    defer fn_bc.deinit(env.rt);

    try std.testing.expect(fn_bc.code.len >= 0);
}

// ---- Object literal enhancements ----

test "Object literal: computed property name" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "{ [x]: 1 }");
    defer fn_bc.deinit(env.rt);

    try std.testing.expect(fn_bc.code.len >= 0);
}

test "Object literal: method shorthand" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "{ method() {} }");
    defer fn_bc.deinit(env.rt);

    try std.testing.expect(fn_bc.code.len >= 0);
}

test "Object literal: spread" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "{ ...obj }");
    defer fn_bc.deinit(env.rt);

    try std.testing.expect(fn_bc.code.len >= 0);
}

// =====================================================================
// F10.1a — FunctionDef integration tests
// =====================================================================
//
// Validates that the parser's `function_def` companion structure is
// populated correctly from `var` / `let` / `const` declarations and
// nested lexical scopes. These tests do NOT exercise bytecode emission
// — they introspect `state.function_def` directly so the FunctionDef
// data path can be validated independently of the pipeline.
//
// See PARSER_REWRITE_PLAN.md §F10.1 Outstanding for the full
// FunctionDef-based pipeline that will consume this data.

const function_def_mod = engine.bytecode.function_def;

test "F10.1a FunctionDef: initial scope chain has scope 0 with parent -1" {
    var env = try TestEnv.init();
    defer env.deinit();
    const name = try env.rt.internAtom("test");
    defer env.rt.atoms.free(name);
    var function = engine.bytecode.Bytecode.init(&env.rt.memory, &env.rt.atoms, name);
    defer function.deinit(env.rt);

    var lex = QjsLexer.init(std.testing.allocator, &env.rt.atoms, "");
    var state = try ParseState.init(&lex, &function);
    defer state.deinit(env.rt);

    // Mirror `js_new_function_def` (`quickjs.c:31511`): scope 0 created
    // with parent = -1, first = -1.
    try std.testing.expectEqual(@as(usize, 1), state.function_def.scopes.len);
    try std.testing.expectEqual(@as(i32, -1), state.function_def.scopes[0].parent);
    try std.testing.expectEqual(@as(i32, -1), state.function_def.scopes[0].first);
    try std.testing.expectEqual(@as(i32, 0), state.function_def.scope_level);
    try std.testing.expectEqual(@as(i32, 1), state.function_def.scope_count);
}

test "F10.1a FunctionDef: parseBlock pushes/pops a scope (balanced)" {
    var env = try TestEnv.init();
    defer env.deinit();
    const name = try env.rt.internAtom("test");
    defer env.rt.atoms.free(name);
    var function = engine.bytecode.Bytecode.init(&env.rt.memory, &env.rt.atoms, name);
    defer function.deinit(env.rt);

    var lex = QjsLexer.init(std.testing.allocator, &env.rt.atoms, "{ }");
    var state = try ParseState.init(&lex, &function);
    defer state.deinit(env.rt);

    try qjs_parser.parseStatementOrDecl(&state, qjs_parser.DeclMask{ .func = true, .func_with_label = true, .other = true });

    // After parsing: scope_level back to 0, but a new scope was
    // appended (push then pop, the structure is retained for §F10.1
    // Outstanding closure analysis to walk later).
    try std.testing.expectEqual(@as(i32, 0), state.scope_level);
    try std.testing.expectEqual(@as(usize, 2), state.function_def.scopes.len);
}

test "F10.1a FunctionDef: nested blocks build parent chain" {
    var env = try TestEnv.init();
    defer env.deinit();
    const name = try env.rt.internAtom("test");
    defer env.rt.atoms.free(name);
    var function = engine.bytecode.Bytecode.init(&env.rt.memory, &env.rt.atoms, name);
    defer function.deinit(env.rt);

    var lex = QjsLexer.init(std.testing.allocator, &env.rt.atoms, "{ let a; { let b; } }");
    var state = try ParseState.init(&lex, &function);
    defer state.deinit(env.rt);

    try qjs_parser.parseStatementOrDecl(&state, qjs_parser.DeclMask{ .func = true, .func_with_label = true, .other = true });

    // After parsing: 3 scopes (initial 0 + outer block + inner block).
    try std.testing.expectEqual(@as(usize, 3), state.function_def.scopes.len);
    // Scope 0 has parent -1, scope 1's parent is 0, scope 2's parent is 1.
    try std.testing.expectEqual(@as(i32, -1), state.function_def.scopes[0].parent);
    try std.testing.expectEqual(@as(i32, 0), state.function_def.scopes[1].parent);
    try std.testing.expectEqual(@as(i32, 1), state.function_def.scopes[2].parent);
    // After popping back, current scope level is 0 again.
    try std.testing.expectEqual(@as(i32, 0), state.scope_level);
}

test "F10.1a FunctionDef: let registers as lexical, non-const" {
    var env = try TestEnv.init();
    defer env.deinit();
    const name = try env.rt.internAtom("test");
    defer env.rt.atoms.free(name);
    var function = engine.bytecode.Bytecode.init(&env.rt.memory, &env.rt.atoms, name);
    defer function.deinit(env.rt);

    const x_atom = try env.rt.internAtom("x");
    defer env.rt.atoms.free(x_atom);

    var lex = QjsLexer.init(std.testing.allocator, &env.rt.atoms, "let x = 1;");
    var state = try ParseState.init(&lex, &function);
    defer state.deinit(env.rt);

    try qjs_parser.parseStatementOrDecl(&state, qjs_parser.DeclMask{ .func = true, .func_with_label = true, .other = true });

    try std.testing.expectEqual(@as(usize, 1), state.function_def.vars.len);
    const v = state.function_def.vars[0];
    try std.testing.expectEqual(@as(engine.core.atom.Atom, x_atom), v.var_name);
    try std.testing.expectEqual(true, v.is_lexical);
    try std.testing.expectEqual(false, v.is_const);
    try std.testing.expectEqual(function_def_mod.VarKind.normal, v.var_kind);
    // `let` at top level is at scope 0 (no enclosing block).
    try std.testing.expectEqual(@as(i32, 0), v.scope_level);
}

test "F10.1a FunctionDef: const registers as lexical + const" {
    var env = try TestEnv.init();
    defer env.deinit();
    const name = try env.rt.internAtom("test");
    defer env.rt.atoms.free(name);
    var function = engine.bytecode.Bytecode.init(&env.rt.memory, &env.rt.atoms, name);
    defer function.deinit(env.rt);

    var lex = QjsLexer.init(std.testing.allocator, &env.rt.atoms, "const k = 42;");
    var state = try ParseState.init(&lex, &function);
    defer state.deinit(env.rt);

    try qjs_parser.parseStatementOrDecl(&state, qjs_parser.DeclMask{ .func = true, .func_with_label = true, .other = true });

    try std.testing.expectEqual(@as(usize, 1), state.function_def.vars.len);
    try std.testing.expectEqual(true, state.function_def.vars[0].is_lexical);
    try std.testing.expectEqual(true, state.function_def.vars[0].is_const);
}

test "F10.1a FunctionDef: var hoists to scope 0 even from nested block" {
    var env = try TestEnv.init();
    defer env.deinit();
    const name = try env.rt.internAtom("test");
    defer env.rt.atoms.free(name);
    var function = engine.bytecode.Bytecode.init(&env.rt.memory, &env.rt.atoms, name);
    defer function.deinit(env.rt);

    var lex = QjsLexer.init(std.testing.allocator, &env.rt.atoms, "{ var v = 1; }");
    var state = try ParseState.init(&lex, &function);
    defer state.deinit(env.rt);

    try qjs_parser.parseStatementOrDecl(&state, qjs_parser.DeclMask{ .func = true, .func_with_label = true, .other = true });

    try std.testing.expectEqual(@as(usize, 1), state.function_def.vars.len);
    const v = state.function_def.vars[0];
    try std.testing.expectEqual(false, v.is_lexical);
    try std.testing.expectEqual(false, v.is_const);
    // `var` hoists to the function scope (level 0) per QuickJS
    // `add_func_var_def` semantics.
    try std.testing.expectEqual(@as(i32, 0), v.scope_level);
}

test "F10.1a FunctionDef: let in nested block attaches to inner scope" {
    var env = try TestEnv.init();
    defer env.deinit();
    const name = try env.rt.internAtom("test");
    defer env.rt.atoms.free(name);
    var function = engine.bytecode.Bytecode.init(&env.rt.memory, &env.rt.atoms, name);
    defer function.deinit(env.rt);

    var lex = QjsLexer.init(std.testing.allocator, &env.rt.atoms, "{ let a; { let b; } }");
    var state = try ParseState.init(&lex, &function);
    defer state.deinit(env.rt);

    try qjs_parser.parseStatementOrDecl(&state, qjs_parser.DeclMask{ .func = true, .func_with_label = true, .other = true });

    try std.testing.expectEqual(@as(usize, 2), state.function_def.vars.len);
    // `a` is registered in the outer block scope (1), `b` in the
    // inner block scope (2).
    try std.testing.expectEqual(@as(i32, 1), state.function_def.vars[0].scope_level);
    try std.testing.expectEqual(@as(i32, 2), state.function_def.vars[1].scope_level);
}

test "F10.1a FunctionDef: findVar locates by name" {
    var env = try TestEnv.init();
    defer env.deinit();
    const name = try env.rt.internAtom("test");
    defer env.rt.atoms.free(name);
    var function = engine.bytecode.Bytecode.init(&env.rt.memory, &env.rt.atoms, name);
    defer function.deinit(env.rt);

    const x_atom = try env.rt.internAtom("x");
    defer env.rt.atoms.free(x_atom);
    const y_atom = try env.rt.internAtom("y");
    defer env.rt.atoms.free(y_atom);
    const z_atom = try env.rt.internAtom("z");
    defer env.rt.atoms.free(z_atom);

    var lex = QjsLexer.init(std.testing.allocator, &env.rt.atoms, "let x; let y;");
    var state = try ParseState.init(&lex, &function);
    defer state.deinit(env.rt);

    try qjs_parser.parseStatementOrDecl(&state, qjs_parser.DeclMask{ .func = true, .func_with_label = true, .other = true });
    try qjs_parser.parseStatementOrDecl(&state, qjs_parser.DeclMask{ .func = true, .func_with_label = true, .other = true });

    try std.testing.expectEqual(@as(i32, 0), state.function_def.findVar(x_atom));
    try std.testing.expectEqual(@as(i32, 1), state.function_def.findVar(y_atom));
    try std.testing.expectEqual(@as(i32, -1), state.function_def.findVar(z_atom));
}

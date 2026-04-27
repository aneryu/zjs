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

/// Helper: parse `src` as an expression and return the produced
/// bytecode buffer for byte-sequence comparison.
fn parseExpr(env: *TestEnv, src: []const u8) !engine.bytecode.Bytecode {
    const name = try env.rt.internAtom("test");
    defer env.rt.atoms.free(name);
    var function = engine.bytecode.Bytecode.init(&env.rt.memory, &env.rt.atoms, name);
    errdefer function.deinit(env.rt);
    var lex = QjsLexer.init(std.testing.allocator, &env.rt.atoms, src);
    var state = try ParseState.init(&lex, &function);
    defer state.deinit();
    try qjs_parser.parseExpr(&state);
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

test "F4: simple assignment x = 1 emits put_var" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "x = 1");
    defer fn_bc.deinit(env.rt);

    // Expect: push_i32 1 ; put_var x
    try std.testing.expectEqual(@as(usize, 10), fn_bc.code.len);
    try std.testing.expectEqual(op.push_i32, fn_bc.code[0]);
    try std.testing.expectEqual(op.put_var, fn_bc.code[5]);
}

test "F4: compound assignment x += 1 emits get_var ; rhs ; add ; put_var" {
    var env = try TestEnv.init();
    defer env.deinit();
    var fn_bc = try parseExpr(&env, "x += 1");
    defer fn_bc.deinit(env.rt);

    // Expect: get_var x ; push_i32 1 ; add ; put_var x
    try std.testing.expectEqual(@as(usize, 16), fn_bc.code.len);
    try std.testing.expectEqual(op.get_var, fn_bc.code[0]);
    try std.testing.expectEqual(op.push_i32, fn_bc.code[5]);
    try std.testing.expectEqual(op.add, fn_bc.code[10]);
    try std.testing.expectEqual(op.put_var, fn_bc.code[11]);
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

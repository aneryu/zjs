const std = @import("std");
const engine = @import("quickjs_zig_engine");

const core = engine.core;
const QjsLexer = engine.frontend.zjs_lexer.Lexer;
const zjs_parser = engine.frontend.zjs_parser;
const ParseState = zjs_parser.ParseState;

const helpers = @import("zjs_vm_helpers.zig");
const parseAndRun = helpers.parseAndRun;
const parseAndRunWithTopLevelChildren = helpers.parseAndRunWithTopLevelChildren;
const parseStmtAndRun = helpers.parseStmtAndRun;
const parseStmtAndRunWithTopLevelChildren = helpers.parseStmtAndRunWithTopLevelChildren;
const expectStringBytes = helpers.expectStringBytes;
const expectSingleCodeUnit = helpers.expectSingleCodeUnit;

test "F2+F3 qjs dispatcher: integer literal executes via qjs_vm" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const result = try parseAndRun(rt, ctx, "42");
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 42), result.asInt32().?);
}

test "F10.1: qjs_vm executes push_bigint_i32 literal" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const result = try parseAndRun(rt, ctx, "1n");
    defer result.free(rt);
    try std.testing.expectEqual(@as(i64, 1), result.asShortBigInt().?);
}

test "F10.2: qjs_vm executes push_i8 short integer" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const name = try rt.internAtom("test");
    defer rt.atoms.free(name);
    var function = engine.bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer function.deinit(rt);
    const op = engine.bytecode.opcode.op;
    var code = [_]u8{ op.push_i8, @bitCast(@as(i8, -42)), op.@"return" };
    try function.setCode(&code);

    var vm = engine.exec.Vm.init(ctx);
    defer vm.deinit();
    const result = try vm.run(&function);
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, -42), result.asInt32().?);
}

test "F10.2: qjs_vm executes push_i16 short integer" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const name = try rt.internAtom("test");
    defer rt.atoms.free(name);
    var function = engine.bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer function.deinit(rt);
    const op = engine.bytecode.opcode.op;
    var code = [_]u8{0} ** 4;
    code[0] = op.push_i16;
    std.mem.writeInt(i16, code[1..3], 300, .little);
    code[3] = op.@"return";
    try function.setCode(&code);

    var vm = engine.exec.Vm.init(ctx);
    defer vm.deinit();
    const result = try vm.run(&function);
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 300), result.asInt32().?);
}

test "M1.2: qjs_vm consumes every special_object subtype" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const name = try rt.internAtom("test");
    defer rt.atoms.free(name);

    const op = engine.bytecode.opcode.op;
    var subtype: u8 = 0;
    while (subtype <= 7) : (subtype += 1) {
        var function = engine.bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
        defer function.deinit(rt);
        if (subtype == 4) {
            function.flags.is_module = true;
            _ = try rt.modules.createFresh(rt, name);
        }
        const code = [_]u8{ op.special_object, subtype, op.@"return" };
        try function.setCode(&code);

        var vm = engine.exec.Vm.init(ctx);
        defer vm.deinit();
        const result = try vm.run(&function);
        defer result.free(rt);
        if (subtype <= 1 or subtype == 4) {
            try std.testing.expect(result.isObject());
        } else {
            try std.testing.expect(result.isUndefined());
        }
    }
}

test "F10.2: qjs_vm executes get_loc0_loc1 coalesced local reads" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const name = try rt.internAtom("test");
    defer rt.atoms.free(name);
    var function = engine.bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer function.deinit(rt);
    function.var_count = 2;

    const op = engine.bytecode.opcode.op;
    var code = [_]u8{0} ** 14;
    code[0] = op.push_i32;
    std.mem.writeInt(i32, code[1..5], 41, .little);
    code[5] = op.put_loc0;
    code[6] = op.push_1;
    code[7] = op.put_loc1;
    code[8] = op.get_loc0_loc1;
    code[9] = op.add;
    code[10] = op.@"return";
    try function.setCode(code[0..11]);

    var vm = engine.exec.Vm.init(ctx);
    defer vm.deinit();
    const result = try vm.run(&function);
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 42), result.asInt32().?);
}

test "F10.2: qjs_vm executes relative goto" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const name = try rt.internAtom("test");
    defer rt.atoms.free(name);
    var function = engine.bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer function.deinit(rt);
    const op = engine.bytecode.opcode.op;
    var code = [_]u8{0} ** 13;
    code[0] = op.goto;
    std.mem.writeInt(i32, code[1..5], 10, .little);
    code[5] = op.push_i32;
    std.mem.writeInt(i32, code[6..10], 1, .little);
    code[10] = op.drop;
    code[11] = op.push_2;
    code[12] = op.@"return";
    try function.setCode(&code);

    var vm = engine.exec.Vm.init(ctx);
    defer vm.deinit();
    const result = try vm.run(&function);
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 2), result.asInt32().?);
}

test "F10.2: qjs_vm executes if_false8 relative branch" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const name = try rt.internAtom("test");
    defer rt.atoms.free(name);
    var function = engine.bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer function.deinit(rt);
    const op = engine.bytecode.opcode.op;
    const code = [_]u8{
        op.push_0,
        op.if_false8,
        3,
        op.push_1,
        op.@"return",
        op.push_i8,
        42,
        op.@"return",
    };
    try function.setCode(&code);

    var vm = engine.exec.Vm.init(ctx);
    defer vm.deinit();
    const result = try vm.run(&function);
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 42), result.asInt32().?);
}

test "F2+F3 qjs dispatcher: addition via qjs_vm" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const result = try parseAndRun(rt, ctx, "1 + 2");
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 3), result.asInt32().?);
}

test "F2+F3 qjs dispatcher: subtraction via qjs_vm" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const result = try parseAndRun(rt, ctx, "10 - 3");
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 7), result.asInt32().?);
}

test "F2+F3 qjs dispatcher: multiplication via qjs_vm" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const result = try parseAndRun(rt, ctx, "6 * 7");
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 42), result.asInt32().?);
}

test "F2+F3 qjs dispatcher: precedence via qjs_vm" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const result = try parseAndRun(rt, ctx, "1 + 2 * 3");
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 7), result.asInt32().?);
}

test "F2+F3 qjs dispatcher: parenthesized via qjs_vm" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const result = try parseAndRun(rt, ctx, "(1 + 2) * 3");
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 9), result.asInt32().?);
}

test "F2+F3 qjs dispatcher: boolean comparison via qjs_vm" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const result = try parseAndRun(rt, ctx, "1 < 2");
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "F2+F3 qjs dispatcher: bitwise and via qjs_vm" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const result = try parseAndRun(rt, ctx, "12 & 10");
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 8), result.asInt32().?);
}

test "F2+F3 qjs dispatcher: unary negation via qjs_vm" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const result = try parseAndRun(rt, ctx, "-5");
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, -5), result.asInt32().?);
}

test "M3.1 F4: unary numeric operators use QuickJS ToNumber semantics" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx,
        \\(function(){
        \\  var trace = "";
        \\  var boxed = { valueOf: function(){ trace += "v"; return "2"; } };
        \\  var plusBigIntThrows = false;
        \\  try { +1n; } catch (e) { plusBigIntThrows = e instanceof TypeError; }
        \\  return +"" === 0 &&
        \\    1 / -"" === -Infinity &&
        \\    +boxed === 2 &&
        \\    trace === "v" &&
        \\    +"Infinity" === Infinity &&
        \\    isNaN(+"INFINITY") &&
        \\    plusBigIntThrows &&
        \\    -1n === -1n;
        \\})()
    );
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "M3.1 F4: typeof uses QuickJS value classification" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx,
        \\(function(){
        \\  var count = 0;
        \\  Object.defineProperties(this, {
        \\    x: { value: 1 },
        \\    y: { get(){ count++; return 1; } }
        \\  });
        \\  var target = {};
        \\  var proxy = new Proxy(target, {});
        \\  var callableProxy = new Proxy(function(){}, {});
        \\  var revoked = Proxy.revocable(function(){}, {});
        \\  revoked.revoke();
        \\  return typeof x === "number" &&
        \\    typeof y === "number" &&
        \\    count === 1 &&
        \\    typeof 0n === "bigint" &&
        \\    typeof BigInt(0) === "bigint" &&
        \\    typeof Object(0n) === "object" &&
        \\    typeof Math.exp === "function" &&
        \\    typeof Math.PI === "number" &&
        \\    typeof RegExp("0").exec("1") === "object" &&
        \\    proxy !== target &&
        \\    typeof proxy === "object" &&
        \\    typeof callableProxy === "function" &&
        \\    typeof revoked.proxy === "function";
        \\})()
    );
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "M3.1 F4: loose equality does not numerically coerce same-type strings" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx,
        \\(function(){
        \\  return ("" == "") === true &&
        \\    (" " == "") === false &&
        \\    ("0xff" == "255") === false &&
        \\    ("1" == 1) === true &&
        \\    (null == undefined) === true;
        \\})()
    );
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "M3.1 F4: loose equality supports ToPrimitive and mixed BigInt" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx,
        \\(function(){
        \\  var hints = "";
        \\  var objectNumber = {
        \\    [Symbol.toPrimitive]: function(hint) { hints += hint; return "1"; }
        \\  };
        \\  var objectBigInt = { valueOf: function(){ return 0n; } };
        \\  return (1 == "1") &&
        \\    (255 == "0xff") &&
        \\    (0 == "") &&
        \\    (true == objectNumber) &&
        \\    hints === "default" &&
        \\    (1n == 1) &&
        \\    (0n == "0") &&
        \\    (0n == objectBigInt) &&
        \\    !("0n" == 1n) &&
        \\    !(1n == 1.5) &&
        \\    !(1n == NaN) &&
        \\    !(1n == Infinity);
        \\})()
    );
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "M3.1 F4: relational comparison supports ToPrimitive and mixed BigInt" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx,
        \\(function(){
        \\  var objectCount = 0;
        \\  var objectOk = ({ valueOf() { objectCount++; return 2; } }) < 3 && objectCount === 1;
        \\  return objectOk &&
        \\    (0n < 0.000000000001) === true &&
        \\    (0.000000000001 < 0n) === false &&
        \\    ("0x10" < 17n) === true &&
        \\    ("0o10" < 9n) === true &&
        \\    ("0b10" < 3n) === true &&
        \\    ("0n" < 1n) === false &&
        \\    (1n < Infinity) === true &&
        \\    (NaN < 0n) === false;
        \\})()
    );
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "M3.1 F4: logical assignment names anonymous RHS for identifier targets" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx,
        \\(function(){
        \\  var andValue = 1;
        \\  var orValue = 0;
        \\  var nullishValue = undefined;
        \\  andValue &&= function(){};
        \\  orValue ||= () => {};
        \\  nullishValue ??= class {};
        \\  return andValue.name === "andValue" &&
        \\    orValue.name === "orValue" &&
        \\    nullishValue.name === "nullishValue";
        \\})()
    );
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "M3.1 F4: update expressions use ToNumeric and preserve postfix result" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx,
        \\(function(){
        \\  var boxed = new Boolean(true);
        \\  var prefixBoxed = ++boxed;
        \\  var big = 0n;
        \\  var oldBig = big++;
        \\  var objectCount = 0;
        \\  var objectValue = { valueOf: function(){ objectCount++; return "2"; } };
        \\  var oldObject = objectValue++;
        \\  var obj = { value: 0n };
        \\  return prefixBoxed === 2 &&
        \\    boxed === 2 &&
        \\    oldBig === 0n &&
        \\    big === 1n &&
        \\    oldObject === 2 &&
        \\    objectValue === 3 &&
        \\    objectCount === 1 &&
        \\    ++obj.value === 1n &&
        \\    obj.value === 1n;
        \\})()
    );
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "M3.1 F4: prefix update in with uses the initial object reference" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx,
        \\(function(){
        \\  var x = 0;
        \\  var scope = {
        \\    get x() {
        \\      delete this.x;
        \\      return 2;
        \\    }
        \\  };
        \\  with (scope) {
        \\    ++x;
        \\  }
        \\  return scope.x === 3 && x === 0;
        \\})()
    );
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "M3.1 F4: strict update in with throws when the initial binding disappears" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx,
        \\(function(){
        \\  var count = 0;
        \\  var scope = {
        \\    get x() {
        \\      delete this.x;
        \\      return 2;
        \\    }
        \\  };
        \\  with (scope) {
        \\    (function() {
        \\      "use strict";
        \\      try {
        \\        count++;
        \\        x++;
        \\        count++;
        \\      } catch (e) {
        \\        count += e instanceof ReferenceError ? 10 : 100;
        \\      }
        \\      count++;
        \\    })();
        \\  }
        \\  return count === 12 && scope.x === undefined;
        \\})()
    );
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

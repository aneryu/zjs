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

test "eval_ret: var-only script returns undefined" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    // `var x = 5;` is a statement (not an expression) so <ret>
    // remains the prologue-set undefined.
    const result = try parseStmtAndRun(rt, ctx, "var x = 5;");
    defer result.free(rt);
    try std.testing.expect(result.isUndefined());
}

test "eval_ret: <ret> is allocated at slot 0 (first var)" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const name = try rt.internAtom("test");
    defer rt.atoms.free(name);
    var function = engine.bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer function.deinit(rt);

    var lex = QjsLexer.init(std.testing.allocator, &rt.atoms, "var x;");
    var state = try ParseState.init(&lex, &function);
    defer state.deinit(rt);

    try state.enableEvalReturn();
    // <ret> must be slot 0 since we allocate it before any user var.
    try std.testing.expectEqual(@as(i32, 0), state.eval_ret_idx);
    // The synthetic var uses atom 82 (`<ret>`).
    try std.testing.expectEqual(@as(@TypeOf(state.function_def.vars[0].var_name), 82), state.function_def.vars[0].var_name);

    while (state.token.val != engine.frontend.qjs_token.TOK_EOF) {
        try qjs_parser.parseStatementOrDecl(&state, qjs_parser.DeclMask{ .func = true, .func_with_label = true, .other = true });
    }
    // In non-global eval, `var x;` is allocated in the eval variable
    // environment after the synthetic <ret> slot.
    try std.testing.expectEqual(@as(usize, 2), state.function_def.vars.len);
    try std.testing.expectEqual(@as(i32, 0), state.function_def.global_var_count);
}

test "TDZ: get_loc_check throws ReferenceError on uninitialised slot" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    // Construct bytecode by hand: set_loc_uninitialized 0 ;
    // get_loc_check 0. Without an intervening put_loc_check_init,
    // the get_loc_check must throw `error.ReferenceError`.
    const name = try rt.internAtom("test");
    defer rt.atoms.free(name);
    var function = engine.bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer function.deinit(rt);
    function.var_count = 1;

    const op = engine.bytecode.opcode.op;
    var code = [_]u8{0} ** 6;
    code[0] = op.set_loc_uninitialized;
    std.mem.writeInt(u16, code[1..3], 0, .little);
    code[3] = op.get_loc_check;
    std.mem.writeInt(u16, code[4..6], 0, .little);
    try function.setCode(&code);

    var vm = engine.exec.Vm.init(ctx);
    defer vm.deinit();
    try std.testing.expectError(error.ReferenceError, vm.run(&function));
}

test "TDZ: put_loc_check_init clears flag, subsequent get_loc_check OK" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    // set_loc_uninitialized 0 ; push 42 ; put_loc_check_init 0 ;
    // get_loc_check 0  → returns 42 (no throw).
    const name = try rt.internAtom("test");
    defer rt.atoms.free(name);
    var function = engine.bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer function.deinit(rt);
    function.var_count = 1;

    const op = engine.bytecode.opcode.op;
    var code = [_]u8{0} ** 14;
    code[0] = op.set_loc_uninitialized;
    std.mem.writeInt(u16, code[1..3], 0, .little);
    code[3] = op.push_i32;
    std.mem.writeInt(i32, code[4..8], 42, .little);
    code[8] = op.put_loc_check_init;
    std.mem.writeInt(u16, code[9..11], 0, .little);
    code[11] = op.get_loc_check;
    std.mem.writeInt(u16, code[12..14], 0, .little);
    try function.setCode(&code);

    var vm = engine.exec.Vm.init(ctx);
    defer vm.deinit();
    const result = try vm.run(&function);
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 42), result.asInt32().?);
}

test "M3.1 F4: qjs_vm executes computed object property literal" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRun(rt, ctx, "({[\"x\"]: 7}).x");
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 7), result.asInt32().?);
}

test "M3.1 F4: qjs_vm executes object spread literal" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRun(rt, ctx, "({a: 1, ...{b: 2}, a: 3}).b");
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 2), result.asInt32().?);
}

test "M3.1 F4: qjs_vm executes keyword object property literal" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRun(rt, ctx, "({default: 1, while: 2}).default");
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 1), result.asInt32().?);
}

test "M3.1 F4: qjs_vm executes object method shorthand" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx, "({m() { return 7; }}).m()");
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 7), result.asInt32().?);
}

test "M3.1 F4: qjs_vm executes computed object method shorthand" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx, "({[\"m\"]() { return 3; }}).m()");
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 3), result.asInt32().?);
}

test "M3.1 F4: qjs_vm executes computed object getter" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx, "({get [\"default\"]() { return 11; }}).default");
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 11), result.asInt32().?);
}

test "M3.1 F4: qjs_vm executes computed object setter" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx, "(function(){ var out; var obj = {set [\"default\"](v) { out = v; }}; obj.default = 13; return out; })()");
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 13), result.asInt32().?);
}

test "M3.1 F4: qjs_vm exposes object accessor descriptor" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx, "Object.getOwnPropertyDescriptor({get x() { return 1; }}, \"x\").enumerable");
    defer result.free(rt);
    try std.testing.expect(result.isBool());
    try std.testing.expect(result.asBool().?);
}

test "M3.1 F4: qjs_vm converts computed property key before value" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx, "(function(){ var value = 1; var key = { toString() { value = 2; return \"p\"; } }; return ({ [key]: value }).p; })()");
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 2), result.asInt32().?);
}

test "M3.1 F4: qjs_vm allows in expression in computed accessor name" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx, "(function(){ var empty = {}; return ({ get [\"x\" in empty]() { return 5; } }).false; })()");
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 5), result.asInt32().?);
}

test "M3.1 F4: object accessors receive prefixed function names" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx,
        \\(function(){
        \\  var named = Symbol("test262");
        \\  var anon = Symbol();
        \\  var o = {
        \\    get id() {},
        \\    set id(v) {},
        \\    get [anon]() {},
        \\    set [named](v) {}
        \\  };
        \\  var getId = Object.getOwnPropertyDescriptor(o, "id").get;
        \\  var setId = Object.getOwnPropertyDescriptor(o, "id").set;
        \\  var getAnon = Object.getOwnPropertyDescriptor(o, anon).get;
        \\  var setNamed = Object.getOwnPropertyDescriptor(o, named).set;
        \\  var desc = Object.getOwnPropertyDescriptor(getId, "name");
        \\  return getId.name === "get id" &&
        \\    setId.name === "set id" &&
        \\    getAnon.name === "get " &&
        \\    setNamed.name === "set [test262]" &&
        \\    desc.writable === false &&
        \\    desc.enumerable === false &&
        \\    desc.configurable === true;
        \\})()
    );
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "M3.1 F4: object methods do not create function-expression name bindings" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx,
        \\(function(){
        \\  var o = {
        \\    m() { return typeof m; },
        \\    *g() { return typeof g; }
        \\  };
        \\  return o.m() === "undefined" &&
        \\    o.g().next().value === "undefined" &&
        \\    o.m.name === "m" &&
        \\    o.g.name === "g";
        \\})()
    );
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "M3.1 F4: qjs_vm treats computed __proto__ as data property" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx, "(function(){ var proto = {}; var obj = { [\"__proto__\"]: proto }; return obj.__proto__ === proto; })()");
    defer result.free(rt);
    try std.testing.expect(result.isBool());
    try std.testing.expect(result.asBool().?);
}

test "M3.1 F4: qjs_vm supports Object.prototype.hasOwnProperty for object literals" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx, "(function(){ var obj = { [\"__proto__\"]: 1 }; return obj.hasOwnProperty(\"__proto__\") && Object.prototype.hasOwnProperty.call(obj, \"__proto__\"); })()");
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "M2.4: qjs_vm dispatches Object.prototype methods on native constructors" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx, "(function(){ return WeakMap.hasOwnProperty(\"length\") && Object.prototype.hasOwnProperty.call(WeakMap, \"length\") && !Object.prototype.propertyIsEnumerable.call(WeakMap, \"length\"); })()");
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "M2.4: qjs_vm deletes ordinary prototype constructor property" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx, "(function(){ var before = WeakMap.prototype.constructor === WeakMap; delete WeakMap.prototype.constructor; return before && !Object.prototype.hasOwnProperty.call(WeakMap.prototype, \"constructor\"); })()");
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "F7: class prototype exposes ordinary constructor property" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseStmtAndRunWithTopLevelChildren(rt, ctx,
        \\(function(){
        \\  class C {
        \\    static constructor() {}
        \\    constructor() {}
        \\  }
        \\  var desc = Object.getOwnPropertyDescriptor(C.prototype, "constructor");
        \\  var protoDesc = Object.getOwnPropertyDescriptor(C, "prototype");
        \\  return C.hasOwnProperty("constructor") &&
        \\    C.prototype.hasOwnProperty("constructor") &&
        \\    C.prototype.constructor === C &&
        \\    C.prototype.constructor !== C.constructor &&
        \\    desc.value === C &&
        \\    desc.writable === true &&
        \\    desc.enumerable === false &&
        \\    desc.configurable === true &&
        \\    protoDesc.writable === false &&
        \\    protoDesc.enumerable === false &&
        \\    protoDesc.configurable === false &&
        \\    Object.getOwnPropertyNames(C.prototype).indexOf("constructor") >= 0;
        \\})()
    );
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "F7: public class fields without initializers are installed" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseStmtAndRunWithTopLevelChildren(rt, ctx,
        \\class A {
        \\  get
        \\  *a() {}
        \\}
        \\class B {
        \\  static get
        \\  *a() {}
        \\}
        \\class C {
        \\  x;
        \\  constructor() { this.x = 1; }
        \\}
        \\var a = new A();
        \\A.prototype.hasOwnProperty("a") &&
        \\  a.hasOwnProperty("get") &&
        \\  a.get === undefined &&
        \\  B.prototype.hasOwnProperty("a") &&
        \\  B.hasOwnProperty("get") &&
        \\  B.get === undefined &&
        \\  new C().x === 1;
    );
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "F7: class constructor captures class binding" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseStmtAndRunWithTopLevelChildren(rt, ctx,
        \\class C {
        \\  constructor() {
        \\    this.same = Object.getPrototypeOf(this) === C.prototype;
        \\  }
        \\}
        \\new C().same && C === C.prototype.constructor;
    );
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "F7: top-level class declaration writes module binding, not class-name local" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseStmtAndRunWithTopLevelChildren(rt, ctx,
        \\class C {}
        \\C = 1;
        \\{
        \\  let C = 2;
        \\  if (C !== 2) throw new Error("bad shadow");
        \\}
        \\C === 1;
    );
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "F7: default derived constructor forwards arguments" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseStmtAndRunWithTopLevelChildren(rt, ctx,
        \\(function(){
        \\  class Base {
        \\    constructor() {
        \\      this.argCount = arguments.length;
        \\    }
        \\  }
        \\  class Derived extends Base {}
        \\  var d = new Derived(1, 2, 3);
        \\  return d.argCount === 3;
        \\})()
    );
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "F7: derived constructor super spread preserves new.target and initializes this once" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseStmtAndRunWithTopLevelChildren(rt, ctx,
        \\class A {
        \\  constructor() {
        \\    this.argc = arguments.length;
        \\  }
        \\}
        \\class B extends A {
        \\  constructor() {
        \\    super(1, ...[2, 3]);
        \\  }
        \\}
        \\const b = new B();
        \\b instanceof B && b.argc === 3;
    );
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "F7: native subclass super spread uses derived new.target" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseStmtAndRunWithTopLevelChildren(rt, ctx,
        \\class B extends Array {
        \\  constructor() {
        \\    super(...[1, 2]);
        \\  }
        \\}
        \\const b = new B();
        \\b instanceof B && b.length === 2 && b[0] === 1 && b[1] === 2;
    );
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "F7: Object subclass constructor ignores object argument when new.target differs" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseStmtAndRunWithTopLevelChildren(rt, ctx,
        \\class O extends Object {}
        \\var o1 = new O({ a: 1 });
        \\var o2 = Reflect.construct(Object, [{ b: 2 }], O);
        \\o1.a === undefined &&
        \\  o2.b === undefined &&
        \\  Object.getPrototypeOf(o1) === O.prototype &&
        \\  Object.getPrototypeOf(o2) === O.prototype;
    );
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "Reflect.construct invokes ordinary constructors with array-like arguments" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseStmtAndRunWithTopLevelChildren(rt, ctx,
        \\var observed = [];
        \\function C() {
        \\  this.count = arguments.length;
        \\  this.first = arguments[0];
        \\  observed.push(Object.getPrototypeOf(this) === Array.prototype);
        \\}
        \\var args = {
        \\  0: 42,
        \\  1: "ok",
        \\  get length() {
        \\    observed.push("length");
        \\    return 2;
        \\  }
        \\};
        \\var value = Reflect.construct(C, args, Array);
        \\var abrupt = {};
        \\Object.defineProperty(abrupt, "length", {
        \\  get: function() {
        \\    throw "abrupt";
        \\  }
        \\});
        \\var caught = false;
        \\try {
        \\  Reflect.construct(C, abrupt);
        \\} catch (e) {
        \\  caught = e === "abrupt";
        \\}
        \\var missingArgsThrows = false;
        \\try {
        \\  Reflect.construct(C);
        \\} catch (e) {
        \\  missingArgsThrows = e instanceof TypeError;
        \\}
        \\value.count === 2 &&
        \\  value.first === 42 &&
        \\  Object.getPrototypeOf(value) === Array.prototype &&
        \\  observed.join(",") === "length,true" &&
        \\  caught &&
        \\  missingArgsThrows;
    );
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "Reflect.construct keeps escaped this alive when constructor throws" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseStmtAndRunWithTopLevelChildren(rt, ctx,
        \\(function(){
        \\  var leaked;
        \\  function C() {
        \\    leaked = this;
        \\    throw new Test262Error();
        \\  }
        \\  assert.throws(Test262Error, function() {
        \\    Reflect.construct(C, []);
        \\  });
        \\  leaked.mark = 42;
        \\  return leaked.mark;
        \\})()
    );
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 42), result.asInt32().?);
}

test "Reflect.construct observes revoked proxy newTarget after prototype lookup" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseStmtAndRunWithTopLevelChildren(rt, ctx,
        \\(function(){
        \\  function assertRevokedNewTarget(constructor) {
        \\    var calls = 0;
        \\    var pair = Proxy.revocable(function(){}, {
        \\      get: function(target, key, receiver) {
        \\        if (key === "prototype") {
        \\          calls++;
        \\          pair.revoke();
        \\          return undefined;
        \\        }
        \\        return Reflect.get(target, key, receiver);
        \\      }
        \\    });
        \\    assert.throws(TypeError, function() {
        \\      Reflect.construct(constructor, [], pair.proxy);
        \\    });
        \\    assert.sameValue(calls, 1);
        \\  }
        \\  assertRevokedNewTarget(function(){});
        \\  assertRevokedNewTarget(Function);
        \\  return 1;
        \\})()
    );
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, 1), result.asInt32().?);
}

test "constructor results do not install proto keepalive reserved property" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx,
        \\(function() {
        \\  function C() {
        \\    this.x = 1;
        \\  }
        \\  return new C();
        \\})()
    );
    defer result.free(rt);

    const object: *core.Object = @fieldParentPtr("header", result.refHeader().?);
    try std.testing.expect(object.getPrototype() != null);
    for (object.properties) |entry| {
        try std.testing.expect(entry.atom_id != core.atom.ids.zjs_proto_keepalive);
    }
}

test "F7: function fallthrough after switch no match returns undefined" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseStmtAndRunWithTopLevelChildren(rt, ctx,
        \\function f(key) {
        \\  switch (key) {
        \\    case "foo":
        \\      return 3;
        \\  }
        \\}
        \\f("bar") === undefined && f("foo") === 3;
    );
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "F7: optional method call preserves receiver and nullish exit stack" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseStmtAndRunWithTopLevelChildren(rt, ctx,
        \\const a = {
        \\  b() { return this._b; },
        \\  _b: { c: 42 },
        \\};
        \\var nil = null;
        \\a.b?.().c === 42 &&
        \\  a?.b?.().c === 42 &&
        \\  (a?.b)().c === 42 &&
        \\  (a?.b)?.().c === 42 &&
        \\  nil?.b?.() === undefined;
    );
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "F7: yield star preserves catch target and return-through-finally" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseStmtAndRunWithTopLevelChildren(rt, ctx,
        \\var caughtTypeError = false;
        \\var badIter = {};
        \\badIter[Symbol.iterator] = function() {
        \\  return {
        \\    next: function() {
        \\      return 8;
        \\    }
        \\  };
        \\};
        \\function* catchesIteratorProtocolError() {
        \\  try {
        \\    yield * badIter;
        \\  } catch (err) {
        \\    caughtTypeError = err.constructor === TypeError;
        \\  }
        \\}
        \\var first = catchesIteratorProtocolError().next();
        \\
        \\var returnReceived;
        \\var ranFinally = false;
        \\var ranNormalTail = false;
        \\var quickIter = {};
        \\quickIter[Symbol.iterator] = function() {
        \\  return {
        \\    next: function() {
        \\      return { done: false };
        \\    },
        \\    return: function(value) {
        \\      returnReceived = value;
        \\      return { done: true, value: 3333 };
        \\    }
        \\  };
        \\};
        \\function* returnsThroughFinally() {
        \\  try {
        \\    yield * quickIter;
        \\    ranNormalTail = true;
        \\  } finally {
        \\    ranFinally = true;
        \\  }
        \\}
        \\var iter = returnsThroughFinally();
        \\var yielded = iter.next();
        \\var returned = iter.return(2222);
        \\
        \\first.value === undefined &&
        \\  first.done === true &&
        \\  caughtTypeError &&
        \\  yielded.value === undefined &&
        \\  yielded.done === false &&
        \\  returned.value === 3333 &&
        \\  returned.done === true &&
        \\  returnReceived === 2222 &&
        \\  ranFinally === true &&
        \\  ranNormalTail === false;
    );
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "F7: super property update uses depth-three lvalue stack shape" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseStmtAndRunWithTopLevelChildren(rt, ctx,
        \\var proto = { p: 1 };
        \\var obj = {
        \\  __proto__: proto,
        \\  m() { return super.p++; }
        \\};
        \\obj.m() === 1 && obj.p === 2 && proto.p === 1;
    );
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "F7: super computed compound assignment uses depth-three lvalue stack shape" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseStmtAndRunWithTopLevelChildren(rt, ctx,
        \\var proto = { p: 1 };
        \\var obj = {
        \\  __proto__: proto,
        \\  m() { return super["p"] += 1; }
        \\};
        \\obj.m() === 2 && obj.p === 2 && proto.p === 1;
    );
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "F7: super computed update checks derived this before evaluating key" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseStmtAndRunWithTopLevelChildren(rt, ctx,
        \\class Base {
        \\  constructor() {
        \\    throw new Error("base");
        \\  }
        \\}
        \\class Derived extends Base {
        \\  constructor() {
        \\    super[super()]++;
        \\  }
        \\}
        \\var ok = false;
        \\try {
        \\  new Derived();
        \\} catch (e) {
        \\  ok = e.constructor === ReferenceError;
        \\}
        \\ok;
    );
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "F7: static super assignment observes null constructor prototype after RHS" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseStmtAndRunWithTopLevelChildren(rt, ctx,
        \\var count = 0;
        \\class C {
        \\  static m() {
        \\    super.x = count += 1;
        \\  }
        \\}
        \\Object.setPrototypeOf(C, null);
        \\var ok = false;
        \\try {
        \\  C.m();
        \\} catch (e) {
        \\  ok = e.constructor === TypeError;
        \\}
        \\ok && count === 1 && C.x === undefined;
    );
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "F7: derived class fields initialize from captured class fields init binding" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseStmtAndRunWithTopLevelChildren(rt, ctx,
        \\(function(){
        \\  function earlier() { throw "wrong initializer"; }
        \\  var count = 0;
        \\  class Base {}
        \\  var C = class extends Base {
        \\    field = ++count;
        \\    constructor() {
        \\      super();
        \\    }
        \\  };
        \\  var instance = new C();
        \\  return instance.field === 1 && count === 1;
        \\})()
    );
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "F7: derived class fields run once when arrow calls super twice" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseStmtAndRunWithTopLevelChildren(rt, ctx,
        \\(function(){
        \\  var baseCtorCalled = 0;
        \\  var fieldInitCalled = 0;
        \\  var passed = false;
        \\  class Base {
        \\    constructor() {
        \\      ++baseCtorCalled;
        \\    }
        \\  }
        \\  class C extends Base {
        \\    field = ++fieldInitCalled;
        \\    constructor() {
        \\      super();
        \\      try {
        \\        (() => super())();
        \\      } catch (e) {
        \\        passed = e.constructor === ReferenceError &&
        \\          baseCtorCalled === 2 &&
        \\          fieldInitCalled === 1;
        \\        return;
        \\      }
        \\    }
        \\  }
        \\  new C();
        \\  return passed;
        \\})()
    );
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "F7: class constructor names and property order follow QuickJS" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseStmtAndRunWithTopLevelChildren(rt, ctx,
        \\class D2 { constructor() {} }
        \\class A {
        \\  static method() {}
        \\  static name() {}
        \\}
        \\class L {
        \\  static method() {}
        \\  static length() {}
        \\}
        \\var aNames = Object.getOwnPropertyNames(A);
        \\var lNames = Object.getOwnPropertyNames(L);
        \\D2.name === "D2" &&
        \\  aNames[0] === "length" &&
        \\  aNames[1] === "name" &&
        \\  aNames[2] === "prototype" &&
        \\  aNames[3] === "method" &&
        \\  lNames[0] === "length" &&
        \\  lNames[1] === "name" &&
        \\  lNames[2] === "prototype" &&
        \\  lNames[3] === "method";
    );
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "F7: class methods are strict and method descriptor failures throw TypeError" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseStmtAndRunWithTopLevelChildren(rt, ctx,
        \\var strictCaught = false;
        \\class StrictCtor {
        \\  constructor() {
        \\    try {
        \\      missingClassStrictBinding = 1;
        \\    } catch (e) {
        \\      strictCaught = e instanceof ReferenceError;
        \\    }
        \\  }
        \\}
        \\new StrictCtor();
        \\var getterThrew = false;
        \\try {
        \\  class C { static get ["prototype"]() {} }
        \\} catch (e) {
        \\  getterThrew = e instanceof TypeError;
        \\}
        \\var setterValue = 0;
        \\class SetterNames {
        \\  static set arguments(v) { setterValue = v; }
        \\}
        \\SetterNames.arguments = 42;
        \\class AsyncBase {
        \\  async method() { return 1; }
        \\}
        \\class AsyncDerived extends AsyncBase {
        \\  async method(x = super.method()) {
        \\    return await super.method();
        \\  }
        \\}
        \\strictCaught && getterThrew && setterValue === 42 && typeof AsyncDerived === "function";
    );
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "F7: derived class observes superclass prototype getter" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseStmtAndRunWithTopLevelChildren(rt, ctx,
        \\var calls = 0;
        \\var Base = function() {}.bind();
        \\Object.defineProperty(Base, "prototype", {
        \\  get: function() {
        \\    calls = calls + 1;
        \\    return null;
        \\  },
        \\  configurable: true
        \\});
        \\class C extends Base {}
        \\var nullProtoCalls = calls;
        \\calls = 0;
        \\var badProtoThrew = false;
        \\Object.defineProperty(Base, "prototype", {
        \\  get: function() {
        \\    calls = calls + 1;
        \\    return 42;
        \\  },
        \\  configurable: true
        \\});
        \\try {
        \\  class D extends Base {}
        \\} catch (e) {
        \\  badProtoThrew = e instanceof TypeError;
        \\}
        \\nullProtoCalls === 1 && calls === 1 && badProtoThrew;
    );
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "M2.4: qjs_vm enforces collection prototype internal slots" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx, "(function(){ var key = {}; assert.throws(TypeError, function(){ WeakMap.prototype.get.call(new Map(), key); }); assert.throws(TypeError, function(){ WeakMap.prototype.delete.call(new Set(), key); }); assert.throws(TypeError, function(){ WeakSet.prototype.add.call(new Set(), key); }); assert.throws(TypeError, function(){ Map.prototype.get.call(new WeakMap(), key); }); return true; })()");
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

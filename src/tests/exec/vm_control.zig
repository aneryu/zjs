const std = @import("std");
const engine = @import("quickjs_zig_engine");

const builtins = engine.builtins;
const core = engine.core;
const QjsLexer = engine.frontend.zjs_lexer.Lexer;
const zjs_parser = engine.frontend.zjs_parser;
const ParseState = zjs_parser.ParseState;

const helpers = @import("zjs_vm_helpers.zig");
const oom_helpers = @import("oom_helpers.zig");
const parseAndRun = helpers.parseAndRun;
const parseAndRunWithTopLevelChildren = helpers.parseAndRunWithTopLevelChildren;
const parseStmtAndRun = helpers.parseStmtAndRun;
const parseStmtAndRunWithTopLevelChildren = helpers.parseStmtAndRunWithTopLevelChildren;
const expectStringBytes = helpers.expectStringBytes;
const expectSingleCodeUnit = helpers.expectSingleCodeUnit;

test "M3.1 F4: sloppy function assignment creates global property" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx,
        \\(function(){
        \\  function foo() { __zjs_unresolved_assignment_probe__ = 42; }
        \\  foo();
        \\  var desc = Object.getOwnPropertyDescriptor(globalThis, "__zjs_unresolved_assignment_probe__");
        \\  return desc.value === 42 && desc.writable === true && desc.enumerable === true && desc.configurable === true;
        \\})()
    );
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "M3.1 F4: standard numeric constants reject strict assignment" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx,
        \\(function(){
        \\  assert.throws(TypeError, function(){ "use strict"; globalThis.Infinity = 42; });
        \\  assert.throws(TypeError, function(){ "use strict"; globalThis.undefined = 42; });
        \\  assert.throws(TypeError, function(){ "use strict"; Number.MAX_VALUE = 42; });
        \\  var inf = Object.getOwnPropertyDescriptor(globalThis, "Infinity");
        \\  var undef = Object.getOwnPropertyDescriptor(globalThis, "undefined");
        \\  var max = Object.getOwnPropertyDescriptor(Number, "MAX_VALUE");
        \\  return inf.writable === false && inf.enumerable === false && inf.configurable === false &&
        \\    undef.writable === false && undef.enumerable === false && undef.configurable === false &&
        \\    max.writable === false && max.enumerable === false && max.configurable === false;
        \\})()
    );
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "M3.1 F4: strict unresolved assignment snapshots lhs before rhs" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx,
        \\(function(){
        \\  delete globalThis.strict_lhs_reference_snapshot_probe;
        \\  var threw = false;
        \\  try {
        \\    (function(){
        \\      "use strict";
        \\      strict_lhs_reference_snapshot_probe = (globalThis.strict_lhs_reference_snapshot_probe = 5);
        \\    }).call(globalThis);
        \\  } catch (e) {
        \\    threw = e instanceof ReferenceError;
        \\  }
        \\  var rhsCreated = globalThis.strict_lhs_reference_snapshot_probe === 5;
        \\  delete globalThis.strict_lhs_reference_snapshot_probe;
        \\  globalThis.strict_lhs_existing_probe = 1;
        \\  (function(){
        \\    "use strict";
        \\    strict_lhs_existing_probe = (globalThis.strict_lhs_existing_probe = 2);
        \\  }).call(globalThis);
        \\  var existingUpdated = globalThis.strict_lhs_existing_probe === 2;
        \\  delete globalThis.strict_lhs_existing_probe;
        \\  globalThis.strict_lhs_result_probe = 3;
        \\  var result = (strict_lhs_result_probe = (globalThis.strict_lhs_result_probe = 4));
        \\  var resultKept = result === 4 && globalThis.strict_lhs_result_probe === 4;
        \\  delete globalThis.strict_lhs_result_probe;
        \\  globalThis.strict_lhs_deleted_probe = 1;
        \\  var deletedThrew = false;
        \\  try {
        \\    (function(){
        \\      "use strict";
        \\      strict_lhs_deleted_probe = (delete globalThis.strict_lhs_deleted_probe, 2);
        \\    }).call(globalThis);
        \\  } catch (e) {
        \\    deletedThrew = e instanceof ReferenceError;
        \\  }
        \\  var deletedStayedMissing = !("strict_lhs_deleted_probe" in globalThis);
        \\  delete globalThis.strict_lhs_deleted_probe;
        \\  return threw && rhsCreated && existingUpdated && resultKept && deletedThrew && deletedStayedMissing;
        \\})()
    );
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "M3.1 F4: global identifier binding checks proxy prototype" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx,
        \\(function(){
        \\  var global = globalThis;
        \\  var proto = Object.getPrototypeOf(global);
        \\  var gets = 0;
        \\  var sets = 0;
        \\  try {
        \\    Object.setPrototypeOf(global, new Proxy(proto, {
        \\      has: function(t, id) {
        \\        return id === "global_proxy_receiver_probe" || Reflect.has(t, id);
        \\      },
        \\      get: function(t, id, r) {
        \\        if (id === "global_proxy_receiver_probe") {
        \\          gets++;
        \\          if (r !== global) return 1;
        \\        }
        \\        return Reflect.get(t, id, r);
        \\      },
        \\      set: function(t, id, v, r) {
        \\        if (id === "global_proxy_receiver_probe") {
        \\          sets++;
        \\          if (r !== global) return false;
        \\        }
        \\        return Reflect.set(t, id, v, r);
        \\      }
        \\    }));
        \\    var readOk = global_proxy_receiver_probe === undefined;
        \\    (function(){ "use strict"; global_proxy_receiver_probe = 12; })();
        \\    return readOk &&
        \\      global.global_proxy_receiver_probe === 12 &&
        \\      gets === 1 &&
        \\      sets === 1;
        \\  } finally {
        \\    Object.setPrototypeOf(global, proto);
        \\    delete global.global_proxy_receiver_probe;
        \\  }
        \\})()
    );
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "G1/P0: with proxy binding uses has and get traps" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx,
        \\(function(){
        \\  var log = [];
        \\  var env = { Object: 1 };
        \\  var proxy = new Proxy(env, {
        \\    has: function(t, pk) {
        \\      log.push("has:" + String(pk));
        \\      return Reflect.has(t, pk);
        \\    },
        \\    get: function(t, pk, r) {
        \\      log.push("get:" + String(pk));
        \\      return Reflect.get(t, pk, r);
        \\    }
        \\  });
        \\  with (proxy) { Object; }
        \\  return log.join(",");
        \\})()
    );
    defer result.free(rt);
    try expectStringBytes(result, "has:Object,get:Symbol(Symbol.unscopables),has:Object,get:Object");
}

test "G1/P0: with unscopables fallback preserves label boundary before local pair" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx,
        \\(function(){
        \\  var sameValueSeen = "";
        \\  var assert = {
        \\    sameValue: function(actual, expected) {
        \\      sameValueSeen = String(actual) + ":" + String(expected);
        \\    }
        \\  };
        \\  var env = { assert: assert, globalV: 1 };
        \\  env[Symbol.unscopables] = { globalV: true };
        \\  var ref = function(x) {
        \\    with (env) {
        \\      assert.sameValue(globalV, undefined);
        \\    }
        \\    var globalV = x;
        \\    return globalV;
        \\  };
        \\  return ref(10) === 10 && sameValueSeen === "undefined:undefined";
        \\})()
    );
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "M3.1 F4: sloppy let labels and strict rejection" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx,
        \\(function(){
        \\  var log = [];
        \\  let: { log.push("literal"); break let; log.push("bad"); }
        \\  l\u0065t: { log.push("escaped"); break l\u0065t; log.push("bad"); }
        \\  let: for (var i = 0; i < 1; i++) { log.push("continue"); continue let; log.push("bad"); }
        \\
        \\  Function("let: 42");
        \\  Function("l\\u0065t: 42");
        \\
        \\  var functionStrictLiteral = false;
        \\  try { Function("'use strict'; let: 42"); } catch (e) { functionStrictLiteral = e instanceof SyntaxError; }
        \\  var functionStrictEscaped = false;
        \\  try { Function("'use strict'; l\\u0065t: 42"); } catch (e) { functionStrictEscaped = e instanceof SyntaxError; }
        \\
        \\  eval("let: 42");
        \\  eval("l\\u0065t: 42");
        \\
        \\  var evalStrictLiteral = false;
        \\  try { eval("'use strict'; let: 42"); } catch (e) { evalStrictLiteral = e instanceof SyntaxError; }
        \\  var evalStrictEscaped = false;
        \\  try { eval("'use strict'; l\\u0065t: 42"); } catch (e) { evalStrictEscaped = e instanceof SyntaxError; }
        \\
        \\  return log.join(",") === "literal,escaped,continue" &&
        \\    functionStrictLiteral && functionStrictEscaped &&
        \\    evalStrictLiteral && evalStrictEscaped;
        \\})()
    );
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "G1/P0: String and Reflect helpers support proxy traps" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx,
        \\(function(){
        \\  var object = { x: 2 };
        \\  return String(12) === "12" &&
        \\    String(true) === "true" &&
        \\    String() === "" &&
        \\    Reflect.has(object, "x") &&
        \\    Reflect.get(object, "x") === 2;
        \\})()
    );
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "G1/P0: typed array constructor accepts element length" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx,
        \\(function(){
        \\  var typedArray = new Int32Array(10);
        \\  return typedArray.length === 10 && typedArray.byteLength === 40;
        \\})()
    );
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "G1/P0: strict with assignment rechecks deleted typed-array inherited binding" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx,
        \\(function(){
        \\  var typedArray = new Int32Array(10);
        \\  var env = Object.create(typedArray);
        \\  Object.defineProperty(env, "NaN", { configurable: true, value: 100 });
        \\  var caught = false;
        \\  with (env) {
        \\    try {
        \\      (function(){ "use strict"; NaN = (delete env.NaN, 0); })();
        \\    } catch (e) {
        \\      caught = e instanceof ReferenceError;
        \\    }
        \\  }
        \\  return caught && Object.getOwnPropertyDescriptor(env, "NaN") === undefined;
        \\})()
    );
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "M3.1 F4: delete follows identifier, property, and with semantics" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx,
        \\(function(){
        \\  var declared = 1;
        \\  __zjs_delete_global_probe__ = 1;
        \\  var globalDeleted = delete __zjs_delete_global_probe__;
        \\  var globalGone = typeof __zjs_delete_global_probe__ === "undefined";
        \\  var array = [1, 2, 3];
        \\  var lengthDeleted = delete array.length;
        \\  var scope = { x: 1 };
        \\  var withPropertyDeleted;
        \\  var withDeclaredDeleted;
        \\  with (scope) {
        \\    withPropertyDeleted = delete x;
        \\    withDeclaredDeleted = delete declared;
        \\  }
        \\  return delete missingDeleteProbe &&
        \\    globalDeleted && globalGone &&
        \\    delete declared === false &&
        \\    lengthDeleted === false && array.length === 3 &&
        \\    withPropertyDeleted === true && scope.x === undefined &&
        \\    withDeclaredDeleted === false;
        \\})()
    );
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "P5 Array: delete indexed own property reveals prototype value" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx,
        \\(function(){
        \\  Array.prototype[0] = 1;
        \\  var array = [];
        \\  array.length = 1;
        \\  array.unshift(0);
        \\  var before = array[0] === 0 && array[1] === 1 && array.hasOwnProperty(0);
        \\  var deleted = delete array[0];
        \\  var after = !array.hasOwnProperty(0) && array[0] === 1;
        \\  delete Array.prototype[0];
        \\  return before && deleted && after;
        \\})()
    );
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "P5 Array: method fast-path TypeError is catchable" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx,
        \\(function(){
        \\  var obj = {};
        \\  obj.unshift = Array.prototype.unshift;
        \\  obj.length = {
        \\    valueOf: function(){ return {}; },
        \\    toString: function(){ return {}; }
        \\  };
        \\  try {
        \\    obj.unshift();
        \\  } catch (e) {
        \\    return e instanceof TypeError;
        \\  }
        \\  return false;
        \\})()
    );
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "P5 Array: copyWithin observes generic receiver operations" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx,
        \\(function(){
        \\  var primitive = Array.prototype.copyWithin.call(true) instanceof Boolean;
        \\  var got = 0;
        \\  var obj = { length: 1 };
        \\  Object.defineProperty(obj, "0", {
        \\    get: function(){ got = 1; return 7; },
        \\    configurable: true
        \\  });
        \\  Array.prototype.copyWithin.call(obj, 0, 0);
        \\  var deleted = "";
        \\  var proxy = new Proxy({ length: 2, 1: 1 }, {
        \\    has: function(target, key) { return key in target; },
        \\    deleteProperty: function(target, key) { deleted = key; return delete target[key]; }
        \\  });
        \\  Array.prototype.copyWithin.call(proxy, 1, 0, 1);
        \\  return primitive && got === 1 && deleted === "1";
        \\})()
    );
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "P5 Array: change-by-copy methods return copied arrays" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx,
        \\(function(){
        \\  var source = [3, , 1];
        \\  var reversed = source.toReversed();
        \\  return source.length === 3 && source[0] === 3 && !(1 in source) && source[2] === 1 &&
        \\    reversed.length === 3 && reversed[0] === 1 && reversed[1] === undefined && reversed[2] === 3 && (1 in reversed) &&
        \\    source.toSorted()[0] === 1 &&
        \\    source.toSpliced(1, 1, 2)[1] === 2 &&
        \\    source.with(2, 4)[2] === 4;
        \\})()
    );
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "P5 Array sort setter writeback updates successor element" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx,
        \\(function(){
        \\  const array = [undefined, "c", , "b", undefined, , "a", "d"];
        \\  Object.defineProperty(array, "2", {
        \\    get() {
        \\      return this.foo;
        \\    },
        \\    set(v) {
        \\      array[3] = "foobar";
        \\      this.foo = v;
        \\    }
        \\  });
        \\  array.sort();
        \\  return array[0] === "a" &&
        \\    array[1] === "b" &&
        \\    array[2] === "c" &&
        \\    array[3] === "d" &&
        \\    array[4] === undefined &&
        \\    array[5] === undefined &&
        \\    array[6] === undefined &&
        \\    !("7" in array) &&
        \\    !array.hasOwnProperty("7") &&
        \\    array.length === 8 &&
        \\    array.foo === "c";
        \\})()
    );
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "P5 Array sort entry OOM releases pending values" {
    try expectSortEntryOOMCleanup(.sort);
    try expectSortEntryOOMCleanup(.to_sorted);
    try expectSortEntryOOMCleanup(.typed_to_sorted);
}

const SortEntryOOMMode = enum { sort, to_sorted, typed_to_sorted };

fn expectSortEntryOOMCleanup(mode: SortEntryOOMMode) !void {
    var saw_oom = false;
    var saw_success = false;

    const samples = oom_helpers.defaultSampleSet(80);
    var fail_offset: usize = 0;
    while (fail_offset < samples.limit) : (fail_offset += 1) {
        if (!oom_helpers.shouldRunOffset(samples, fail_offset)) continue;
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        const rt = try core.Runtime.create(failing.allocator());
        const ctx = try core.Context.create(rt);
        const global = try engine.exec.zjs_vm.ensureContextGlobal(ctx);

        const receiver = try createSortEntryOOMReceiver(rt, mode);
        const method = try sortEntryOOMMethod(rt, global, mode);

        failing.fail_index = failing.alloc_index + fail_offset;
        const result = switch (mode) {
            .sort => engine.exec.zjs_vm.qjsArraySortCall(ctx, null, global, receiver, method, &.{}, null, null),
            .to_sorted, .typed_to_sorted => engine.exec.zjs_vm.qjsArrayByCopyCall(ctx, null, global, receiver, method, &.{}, null, null),
        };
        failing.fail_index = std.math.maxInt(usize);

        if (result) |maybe_value| {
            const value = maybe_value orelse {
                cleanupSortEntryOOMIteration(rt, ctx, receiver, method);
                return error.TestUnexpectedResult;
            };
            saw_success = true;
            value.free(rt);
        } else |err| switch (err) {
            error.OutOfMemory => saw_oom = true,
            else => |unexpected| {
                cleanupSortEntryOOMIteration(rt, ctx, receiver, method);
                return unexpected;
            },
        }

        cleanupSortEntryOOMIteration(rt, ctx, receiver, method);
        if (oom_helpers.shouldStopAfterCoverage(saw_oom, saw_success)) return;
    }

    try std.testing.expect(saw_oom);
    try std.testing.expect(saw_success);
}

fn createSortEntryOOMReceiver(rt: *core.Runtime, mode: SortEntryOOMMode) !core.Value {
    switch (mode) {
        .sort, .to_sorted => {
            const array = try core.Object.createArray(rt, null);
            errdefer core.Object.destroyFromHeader(rt, &array.header);
            const retained = try core.Object.create(rt, core.class.ids.object, null);
            defer retained.value().free(rt);
            try array.defineOwnProperty(rt, core.atom.atomFromUInt32(0), core.Descriptor.data(retained.value(), true, true, true));
            array.length = 1;
            return array.value();
        },
        .typed_to_sorted => {
            const buffer = try builtins.buffer.arrayBufferConstruct(rt, core.Value.int32(16));
            defer buffer.free(rt);
            const typed = try builtins.buffer.typedArrayConstructWithOptions(rt, 8, 11, buffer, &.{buffer}, null);
            const object = try engine.exec.property_ops.expectObject(typed);
            _ = try builtins.buffer.typedArraySetIndex(rt, object, 0, core.Value.shortBigInt(2));
            _ = try builtins.buffer.typedArraySetIndex(rt, object, 1, core.Value.shortBigInt(1));
            return typed;
        },
    }
}

fn sortEntryOOMMethod(rt: *core.Runtime, global: *core.Object, mode: SortEntryOOMMode) !core.Value {
    const ctor_name = switch (mode) {
        .sort, .to_sorted => "Array",
        .typed_to_sorted => "BigInt64Array",
    };
    const method_name = switch (mode) {
        .sort => "sort",
        .to_sorted, .typed_to_sorted => "toSorted",
    };
    const ctor_atom = try rt.internAtom(ctor_name);
    defer rt.atoms.free(ctor_atom);
    const ctor_value = global.getProperty(ctor_atom);
    defer ctor_value.free(rt);
    const ctor = try engine.exec.property_ops.expectObject(ctor_value);
    const prototype_value = ctor.getProperty(core.atom.ids.prototype);
    defer prototype_value.free(rt);
    const prototype = try engine.exec.property_ops.expectObject(prototype_value);
    const method_atom = try rt.internAtom(method_name);
    defer rt.atoms.free(method_atom);
    return prototype.getProperty(method_atom);
}

fn cleanupSortEntryOOMIteration(rt: *core.Runtime, ctx: *core.Context, receiver: core.Value, method: core.Value) void {
    if (ctx.hasException()) {
        const exception = ctx.takeException();
        exception.free(rt);
    }
    if (ctx.hasUnhandledRejection()) {
        const rejection = ctx.takeUnhandledRejection();
        rejection.free(rt);
    }
    method.free(rt);
    receiver.free(rt);
    ctx.destroy();
    rt.destroy();
}

test "P5 Array: length coercion and descriptor errors" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx,
        \\(function(){
        \\  var overflowRange = false;
        \\  try {
        \\    [].length = 4294967296;
        \\  } catch (e) {
        \\    overflowRange = e instanceof RangeError;
        \\  }
        \\  var boolLength = [];
        \\  boolLength.length = true;
        \\  var nullLength = [0];
        \\  nullLength.length = null;
        \\  var numberWrapperLength = [];
        \\  numberWrapperLength.length = new Number(1);
        \\  var objectLength = [];
        \\  objectLength.length = { valueOf: function(){ return 2; } };
        \\  var locked = [1];
        \\  Object.defineProperty(locked, "length", { writable: false });
        \\  Array.prototype.toString = Object.prototype.toString;
        \\  var objectTag = (new Array(0)).toString() === "[object Array]" &&
        \\    Object.prototype.toString.call([]) === "[object Array]";
        \\  var orderArray = [1, 2];
        \\  var valueOfCalls = 0;
        \\  var orderLength = {
        \\    valueOf: function() {
        \\      valueOfCalls += 1;
        \\      if (valueOfCalls !== 1) Object.defineProperty(orderArray, "length", { writable: false });
        \\      return orderArray.length;
        \\    }
        \\  };
        \\  var defineThrew = false;
        \\  try {
        \\    Object.defineProperty(orderArray, "length", { value: orderLength, writable: true });
        \\  } catch (e) {
        \\    defineThrew = e instanceof TypeError;
        \\  }
        \\  orderArray = [1, 2];
        \\  valueOfCalls = 0;
        \\  var reflectDefined = Reflect.defineProperty(orderArray, "length", { value: orderLength, writable: true });
        \\  return overflowRange &&
        \\    boolLength.length === 1 &&
        \\    nullLength.length === 0 &&
        \\    numberWrapperLength.length === 1 &&
        \\    objectLength.length === 2 &&
        \\    Reflect.defineProperty(locked, "length", { writable: true }) === false &&
        \\    objectTag &&
        \\    defineThrew &&
        \\    valueOfCalls === 2 &&
        \\    reflectDefined === false;
        \\})()
    );
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "P5 Array: toString uses join and intrinsic object tag fallback" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx,
        \\(function(){
        \\  var object = {
        \\    valueOf: function(){ return "+"; },
        \\    toString: function(){ return "*"; }
        \\  };
        \\  var joined = [object].toString() === "*";
        \\  var generic = Array.prototype.toString.call({ join: null }) === "[object Object]";
        \\  var proxyTarget = [];
        \\  var revokeOnGet = false;
        \\  var revocable = Proxy.revocable(proxyTarget, {
        \\    get: function(target, key, receiver) {
        \\      if (revokeOnGet) revocable.revoke();
        \\      return Reflect.get(target, key, receiver);
        \\    }
        \\  });
        \\  proxyTarget.join = undefined;
        \\  var proxyTag = Array.prototype.toString.call(revocable.proxy) === "[object Array]";
        \\  revokeOnGet = true;
        \\  var revokedThrows = false;
        \\  try {
        \\    Array.prototype.toString.call(revocable.proxy);
        \\  } catch (e) {
        \\    revokedThrows = e instanceof TypeError;
        \\  }
        \\  return joined && generic && proxyTag && revokedThrows;
        \\})()
    );
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "P5 Array: toLocaleString invokes element methods with original receiver" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx,
        \\(function(){
        \\  "use strict";
        \\  var calls = 0;
        \\  var item = {
        \\    toLocaleString: function() {
        \\      calls++;
        \\      return "ok";
        \\    }
        \\  };
        \\  Array.prototype[1] = item;
        \\  var inherited = [item, , null, undefined].toLocaleString() === "ok,ok,,";
        \\  delete Array.prototype[1];
        \\  var getterThis;
        \\  Object.defineProperty(Boolean.prototype, "toString", {
        \\    configurable: true,
        \\    get: function() {
        \\      getterThis = typeof this;
        \\      return function() { return getterThis; };
        \\    }
        \\  });
        \\  var primitive = [true].toLocaleString() === "boolean" && getterThis === "boolean";
        \\  var custom = Object.prototype.toLocaleString.call({
        \\    toString: function() { return "object-locale"; }
        \\  }) === "object-locale";
        \\  return inherited && calls === 2 && primitive && custom;
        \\})()
    );
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "M3.1 F4: delete super reference throws before ToPropertyKey" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx,
        \\(function(){
        \\  var key = { toString: function(){ throw new Test262Error("ToPropertyKey"); } };
        \\  var obj = { m: function(){ delete super[key]; } };
        \\  assert.throws(ReferenceError, function(){ delete super.x; });
        \\  assert.throws(ReferenceError, function(){ obj.m(); });
        \\  return true;
        \\})()
    );
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "M3.1 F4: arrow method tail call propagates thrown error" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx,
        \\(function(){
        \\  var obj = { m: function(){ throw new ReferenceError("tail"); } };
        \\  assert.throws(ReferenceError, () => obj.m());
        \\  return true;
        \\})()
    );
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "M3.1 F4: new non-constructors throw catchable TypeError" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx,
        \\(function(){
        \\  assert.throws(TypeError, function(){ new true; });
        \\  assert.throws(TypeError, function(){ var x = 1; new x(); });
        \\  assert.throws(TypeError, function(){ new new Boolean(true); });
        \\  assert.throws(TypeError, function(){ new this(); });
        \\  return true;
        \\})()
    );
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "M3.1 F4: instanceof uses Symbol.hasInstance and RHS TypeError rules" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx,
        \\(function(){
        \\  var F = {};
        \\  F[Symbol.hasInstance] = function() { return "yes"; };
        \\  var caughtPrimitive = 0;
        \\  try { true instanceof true; } catch (e) { caughtPrimitive = e instanceof TypeError ? 1 : 0; }
        \\  var caughtNonCallable = 0;
        \\  try { 1 instanceof Math; } catch (e) { caughtNonCallable = e instanceof TypeError ? 1 : 0; }
        \\  return (17 instanceof F) && caughtPrimitive === 1 && caughtNonCallable === 1;
        \\})()
    );
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "M3.1 F4: instanceof treats Function.prototype as callable" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx,
        \\(function(){
        \\  Function.prototype.prototype = Array.prototype;
        \\  return ([] instanceof Function.prototype) && (0 instanceof Function.prototype) === false;
        \\})()
    );
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "M3.1 F4: instanceof follows standard constructor prototype graph" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx,
        \\(function(){
        \\  function F(){}
        \\  var g = new Function("");
        \\  var e = TypeError("x");
        \\  return e instanceof Error &&
        \\    e instanceof TypeError &&
        \\    F instanceof Function &&
        \\    F instanceof Object &&
        \\    g instanceof Function &&
        \\    ({}).constructor === Object &&
        \\    [].constructor === Array;
        \\})()
    );
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "M3.1 F4: update expressions accept covered identifier references" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx,
        \\(function(){
        \\  var y = 1;
        \\  ++(y);
        \\  (y)++;
        \\  ((y))++;
        \\  return y === 4;
        \\})()
    );
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "M3.1 F4: in operator uses Object.prototype and primitive RHS TypeError" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRunWithTopLevelChildren(rt, ctx,
        \\(function(){
        \\  var proto = { phylum: "avis" };
        \\  function Robin(){ this.name = "robin"; }
        \\  Robin.prototype = proto;
        \\  var robin = new Robin();
        \\  var threw = false;
        \\  try { "toString" in true; } catch (e) { threw = e instanceof TypeError; }
        \\  return ("valueOf" in {}) &&
        \\    ("phylum" in robin) &&
        \\    !robin.hasOwnProperty("phylum") &&
        \\    threw;
        \\})()
    );
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "F2+F3 qjs dispatcher: bitwise not via qjs_vm" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRun(rt, ctx, "~0");
    defer result.free(rt);
    try std.testing.expectEqual(@as(i32, -1), result.asInt32().?);
}

test "F2+F3 QuickJS dispatch: new bytecode starts empty" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("qjs_test");
    defer rt.atoms.free(name);
    var function = engine.bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer function.deinit(rt);

    try std.testing.expectEqual(@as(usize, 0), function.code.len);
}

test "F2+F3 qjs dispatcher: object literal via qjs_vm" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const result = try parseAndRun(rt, ctx, "({})");
    defer result.free(rt);
    try std.testing.expect(result.isObject());
}

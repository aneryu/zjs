//! Exec integration tests: vm_branches_inlining.
const std = @import("std");
const zjs = @import("zjs");
const engine = zjs;
const core = zjs.core;
const helpers = @import("../harness.zig");
const BareRuntime = @import("../harness/bare_runtime.zig").BareRuntime;
const frame_mod = zjs.exec.frame;
const inline_calls = zjs.exec.inline_calls;

// Bootstrap-integration tests relocated from src/exec/{call,zjs_vm}.zig during
// Phase 6b-3 STEP 7B. They build a bare `core.JSRuntime` and install the
// standard globals through `rt.installStandardGlobals`; the helper wires the
// exec-owned bootstrap seam before installation.

test "host global bootstrap installs and tears down builtin plus host domains" {
    var host = try BareRuntime.init(.{ .ensure_realm_payload = true });
    defer host.deinit();
}

test "engine eval host globals and throw intrinsic tear down cleanly" {
    var host = try BareRuntime.init(.{ .ensure_realm_payload = true });
    defer host.deinit();
    const ctx = host.ctx;

    var output_buffer: [64]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);

    const value = try engine.exec.eval_entry.eval(ctx, "print(1);", .{ .output = &output });

    try std.testing.expect(value.is(.undefined_value));
    try std.testing.expectEqualStrings("1\n", output.buffered());
}

const ReflectActiveRootSymbolProbe = struct {
    rt: *core.JSRuntime,
    atom_id: core.Atom,
    saw_symbol: bool = false,
    trace_failed: bool = false,

    fn trigger(context: ?*anyopaque, size: usize) void {
        _ = size;
        const self: *@This() = @ptrCast(@alignCast(context.?));
        // The trigger models an allocation-point collection, which is an
        // engine-frames-active trigger: scan conservative so natively held
        // in-flight construction state survives, exactly as the production
        // pollGC(.normal) path behaves.
        _ = self.rt.collectFull() catch {};
        self.saw_symbol = self.rt.atoms.name(self.atom_id) != null;
    }
};

fn reflectTestSetArrayIndex(rt: *core.JSRuntime, array: *core.Object, index: u32, value: core.JSValue) !void {
    try array.defineOwnProperty(rt, core.Atom.taggedInt(index), core.Descriptor.data(value, .all));
    if (array.arrayLength() <= index) array.setArrayLength(index + 1);
}

test "reflect construct roots argument list while resolving prototype" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();

    // `reflectConstructCall` routes builtin construction (Array, like Date/RegExp/
    // String) through the VM construct dispatcher. Install the Realm globals
    // needed by construction; internal builtin records already have static
    // lifetime independently of Realm bootstrap.
    const realm_global = try core.Object.create(rt, core.class.ids.object, null);
    _ = try realm_global.ensureRealmPayload(rt);
    // The installed realm graph hangs off this Zig local; the probe below
    // runs whole-heap cycle removal on every allocation, so the tracing
    // sweep needs the global named as a root or the intrinsics vanish and
    // prototype resolution throws InvalidBuiltinRegistry. The behavior under
    // test — engine-side rooting of the argument list — is unaffected.
    var realm_global_slot: ?*core.Object = realm_global;
    var realm_roots = core.runtime.rootObjects(.{&realm_global_slot});
    realm_roots.activate(rt);
    defer realm_roots.deactivate(rt);

    try ctx.installStandardGlobals(realm_global);

    const target = try core.function.nativeFunction(ctx, "Array", 1);
    const target_object = try core.Object.expect(target);
    target_object.setNativeConstructorKind(.array);
    const new_target = try core.function.nativeFunction(ctx, "Array", 1);
    const new_target_object = engine.exec.call.thisObject(new_target) orelse return error.TypeError;
    new_target_object.setNativeConstructorKind(.array);
    try new_target_object.defineOwnProperty(rt, core.atom.ids.prototype, core.Descriptor.data(core.JSValue.int32(1), .method));

    const args_object = try core.Object.createArray(rt, null);
    var args_alive = true;
    const symbol_atom = try rt.atoms.newValueSymbol("gc-reflect-construct-argument-root");
    const symbol_value = try rt.symbolValue(symbol_atom);
    try reflectTestSetArrayIndex(rt, args_object, 0, symbol_value);

    var probe = ReflectActiveRootSymbolProbe{
        .rt = rt,
        .atom_id = symbol_atom,
    };
    const saved_trigger_fn = rt.gc.heap_budget.installProbe(.{ .run = ReflectActiveRootSymbolProbe.trigger, .context = &probe });
    defer rt.gc.heap_budget.restoreProbe(saved_trigger_fn);

    const reflect_args = [_]core.JSValue{ target, args_object.value(), new_target };
    _ = try engine.exec.reflect_ops.reflectConstructCall(ctx, null, realm_global, &reflect_args, null, null);
    var result_alive = true;

    try std.testing.expect(!probe.trace_failed);
    try std.testing.expect(probe.saw_symbol);

    args_alive = false;
    result_alive = false;
    _ = try rt.collectForTest();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

// ===========================================================================
// Branch-to-end forms. The register-resident dispatch carries no hot falloff
// check (qjs-aligned), so every parser epilogue must terminate branch-to-end
// paths with a real return op and the verifier must reject reachable falloff.
// Each test pins the observable completion value.
// ===========================================================================

test "short conditional branches preserve immediate and full ToBoolean semantics" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\function choose(value) { if (value) return 1; return 0; }
        \\function orValue(value) { return value || 9; }
        \\function andValue(value) { return value && 9; }
        \\assert.sameValue(choose(-1), 1);
        \\assert.sameValue(choose(0), 0);
        \\assert.sameValue(choose(1), 1);
        \\assert.sameValue(choose(false), 0);
        \\assert.sameValue(choose(true), 1);
        \\assert.sameValue(choose(null), 0);
        \\assert.sameValue(choose(undefined), 0);
        \\assert.sameValue(choose(-0), 0);
        \\assert.sameValue(choose(0.5), 1);
        \\assert.sameValue(choose(""), 0);
        \\assert.sameValue(choose("x"), 1);
        \\assert.sameValue(choose({}), 1);
        \\assert.sameValue(orValue(0), 9);
        \\assert.sameValue(orValue(4), 4);
        \\assert.sameValue(andValue(0), 0);
        \\assert.sameValue(andValue(4), 9);
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "if-throw fall-off form returns undefined (if_false8 branch-to-end)" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\function fallOffIfThrow(x) { if (x) throw 1; }
        \\assert.sameValue(fallOffIfThrow(false), undefined);
        \\var threw = false;
        \\try { fallOffIfThrow(true); } catch (e) { threw = (e === 1); }
        \\assert.sameValue(threw, true);
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "if-return fall-off form returns undefined on the fall-through leg" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\function fallOffIfReturn(x) { if (x) return 1; }
        \\assert.sameValue(fallOffIfReturn(true), 1);
        \\assert.sameValue(fallOffIfReturn(false), undefined);
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "else-return goto-to-end form returns undefined on the taken if leg" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\function fallOffElseReturn(x) { if (x) { 1; } else return 2; }
        \\assert.sameValue(fallOffElseReturn(true), undefined);
        \\assert.sameValue(fallOffElseReturn(false), 2);
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "nested-block branch-to-end survives trailing scope cleanup lowering" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    // Parser-phase target points at the block's leave_scope/close_loc run;
    // lowering removes it, leaving the resolved target == code_end. The
    // epilogue's jump-to-end scan must treat the trailing cleanup run as an
    // end target and still append the terminator.
    const result = try js.eval(
        \\function fallOffNestedBlock(c) { { let x; if (c) throw 1; } }
        \\assert.sameValue(fallOffNestedBlock(false), undefined);
        \\function fallOffCaptured(c) { { let x = 1; if (c) throw 2; var probe = function () { return x; }; } return probe(); }
        \\assert.sameValue(fallOffCaptured(false), 1);
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "arrow block body branch-to-end returns undefined" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var fallOffArrow = (x) => { if (x) throw 3; };
        \\assert.sameValue(fallOffArrow(false), undefined);
        \\var fallOffArrowReturn = (x) => { if (x) return 4; };
        \\assert.sameValue(fallOffArrowReturn(true), 4);
        \\assert.sameValue(fallOffArrowReturn(false), undefined);
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "generator branch-to-end completes with undefined value" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\function* fallOffGen(x) { if (x) throw 4; yield 1; }
        \\var it = fallOffGen(false);
        \\assert.sameValue(it.next().value, 1);
        \\var r = it.next();
        \\assert.sameValue(r.done, true);
        \\assert.sameValue(r.value, undefined);
        \\function* fallOffGenNoYield(x) { if (x) throw 5; }
        \\var r2 = fallOffGenNoYield(false).next();
        \\assert.sameValue(r2.done, true);
        \\assert.sameValue(r2.value, undefined);
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "eval and script completion end in an explicit value return" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    // Direct/indirect eval bodies end with `get_loc <ret>; return`.
    const result = try js.eval(
        \\assert.sameValue(eval("if (false) throw 5;"), undefined);
        \\assert.sameValue(eval("1 + 2"), 3);
        \\assert.sameValue(eval("{ let x; if (false) throw 6; }"), undefined);
    );
    try std.testing.expect(result.is(.undefined_value));

    // Script completion (<repl> return_completion form) uses the same explicit
    // value-return epilogue at the top level.
    const repl_undef = try js.evalWithOptions("if (false) throw 7;", .{ .filename = "<repl>" });
    try std.testing.expect(repl_undef.is(.undefined_value));

    const repl_value = try js.evalWithOptions("40 + 2", .{ .filename = "<repl>" });
    try std.testing.expectEqual(@as(?i32, 42), repl_value.as(.int));
}

test "eval preserves completion through nested shared finalizers" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\assert.sameValue(eval("1; try { 2; } finally { 3; }"), 2);
        \\assert.sameValue(eval("1; try { try { 2; } finally { 3; } } finally { 4; }"), 2);
        \\assert.sameValue(eval("1; try { throw 5; } catch (error) { error + 1; } finally { 7; }"), 6);
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "module top-level branch-to-end gets a terminator (no fall-off)" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    _ = try js.evalModule(
        \\if (false) throw 9;
    );
}

test "W1d: module import.meta identity survives methods and nested closures" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    _ = try js.evalModule(
        \\const rootMeta = import.meta;
        \\class Holder {
        \\  read() { return import.meta; }
        \\}
        \\function nested() {
        \\  const arrow = () => import.meta;
        \\  return [import.meta, arrow()];
        \\}
        \\const [nestedMeta, arrowMeta] = nested();
        \\if (new Holder().read() !== rootMeta ||
        \\    nestedMeta !== rootMeta ||
        \\    arrowMeta !== rootMeta) {
        \\  throw new Error("import.meta identity escaped its module");
        \\}
    );
}

test "module function declaration cells do not leak onto the global object" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    _ = try js.evalModule(
        \\function __moduleLocalHoist() {}
        \\export function __moduleExportHoist() {}
        \\export default function __moduleDefaultHoist() {}
    );

    _ = try js.eval(
        \\assert.sameValue(Object.prototype.hasOwnProperty.call(globalThis, "__moduleLocalHoist"), false);
        \\assert.sameValue(Object.prototype.hasOwnProperty.call(globalThis, "__moduleExportHoist"), false);
        \\assert.sameValue(Object.prototype.hasOwnProperty.call(globalThis, "__moduleDefaultHoist"), false);
    );
}

test "call consumers derive receiver and direct-eval provenance from the final opcode" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\(function () {
        \\  const __call_consumer_local = 17;
        \\  const holder = { get() { return eval; } };
        \\  assert.sameValue(holder.get()("typeof __call_consumer_local"), "undefined");
        \\  assert.sameValue((eval)("__call_consumer_local"), 17);
        \\  assert.sameValue((0, eval)("typeof __call_consumer_local"), "undefined");
        \\  assert.sameValue(eval?.("typeof __call_consumer_local"), "undefined");
        \\  const withScope = {
        \\  value: 23,
        \\  method() { return this.value; },
        \\  tag(parts) { return this.value + parts[0]; },
        \\  };
        \\  with (withScope) {
        \\  assert.sameValue((method)(), 23);
        \\  assert.sameValue(tag`!`, "23!");
        \\  assert.sameValue(({ value }).value, 23);
        \\  }
        \\  assert.sameValue(withScope.method?.(), 23);
        \\  class CallBase {
        \\  method() { return this.value; }
        \\  tag(parts) { return this.value + parts[0]; }
        \\  }
        \\  class CallDerived extends CallBase {
        \\  constructor() { super(); this.value = 31; }
        \\  probe() { return [(super.method)(), (super.tag)`?`]; }
        \\  }
        \\  const superResults = new CallDerived().probe();
        \\  assert.sameValue(superResults[0], 31);
        \\  assert.sameValue(superResults[1], "31?");
        \\  const commaReceiver = {
        \\  tag(parts) { "use strict"; void parts; return this; },
        \\  };
        \\  assert.sameValue((0, commaReceiver.tag)`x`, undefined);
        \\})();
    );
    try std.testing.expect(result.is(.undefined_value));

    // Pinned QuickJS rejects this optional call on a with-scope reference
    // during stack verification (`InternalError: inconsistent stack size`);
    // the spec calls it with the with object as the receiver.
    _ = try js.eval(
        \\const optionalWithScope = { method() { return this; } };
        \\with (optionalWithScope) assert.sameValue(method?.(), optionalWithScope);
    );
}

test "optional chains use one unbounded shared label and preserve closed-chain calls" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(std.testing.allocator);

    try source.appendSlice(std.testing.allocator, "const nil = null;\nassert.sameValue(");
    try source.appendSlice(std.testing.allocator, "nil");
    for (0..257) |_| try source.appendSlice(std.testing.allocator, "?.x");
    try source.appendSlice(std.testing.allocator, ", undefined);\nassert.sameValue(delete nil");
    for (0..257) |_| try source.appendSlice(std.testing.allocator, "?.x");
    try source.appendSlice(std.testing.allocator, ", true);\nlet closedThrew = false;\ntry { (nil");
    for (0..32) |_| try source.appendSlice(std.testing.allocator, "?.x");
    try source.appendSlice(std.testing.allocator, "?.method)(); } catch (error) { closedThrew = error instanceof TypeError; }\nassert.sameValue(closedThrew, true);\nassert.sameValue((nil");
    for (0..32) |_| try source.appendSlice(std.testing.allocator, "?.x");
    try source.appendSlice(std.testing.allocator, "?.method)?.(), undefined);\nconst live = {};\nlive.x = live;\nlive.method = function () { \"use strict\"; return this === live; };\nassert.sameValue((live");
    for (0..32) |_| try source.appendSlice(std.testing.allocator, "?.x");
    try source.appendSlice(std.testing.allocator, "?.method)(), true);\n");

    const result = try js.eval(source.items);
    try std.testing.expect(result.is(.undefined_value));
}

test "direct eval inside a module function forwards module live bindings" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    _ = try js.evalModule(
        \\export let moduleDirectEvalBinding = 37;
        \\export function readModuleBindingByEval() {
        \\  return eval("moduleDirectEvalBinding");
        \\}
        \\assert.sameValue(readModuleBindingByEval(), 37);
    );
}

test "dynamic global put keeps cell and global-object legs semantically separate" {
    const cases = [_]struct {
        name: []const u8,
        source: []const u8,
        expected: []const u8,
    }{
        .{
            .name = "initialized-cell-hit",
            .source =
            \\var cell = 1;
            \\function writeCell() { cell = 2; return cell; }
            \\print(writeCell(), cell);
            ,
            .expected = "2 2\n",
        },
        .{
            .name = "uninitialized-global-object-hit",
            .source =
            \\globalThis.dynamicHit = 1;
            \\function writeDynamicHit() { dynamicHit = 2; return dynamicHit; }
            \\print(writeDynamicHit(), globalThis.dynamicHit);
            ,
            .expected = "2 2\n",
        },
        .{
            .name = "uninitialized-global-object-miss",
            .source =
            \\delete globalThis.dynamicMiss;
            \\function writeDynamicMiss() { dynamicMiss = 3; return dynamicMiss; }
            \\print(writeDynamicMiss(), globalThis.dynamicMiss);
            ,
            .expected = "3 3\n",
        },
        .{
            .name = "strict-miss",
            .source =
            \\delete globalThis.strictMissing;
            \\function writeStrictMissing() { "use strict"; strictMissing = 3; }
            \\try { writeStrictMissing(); print("no throw"); }
            \\catch (error) { print(error.name, typeof strictMissing); }
            ,
            .expected = "ReferenceError undefined\n",
        },
        .{
            .name = "lexical-tdz",
            .source =
            \\function writeTdz() { lexicalTdz = 3; }
            \\try { writeTdz(); print("no throw"); }
            \\catch (error) { print(error.name); }
            \\let lexicalTdz;
            \\print(lexicalTdz);
            ,
            .expected = "ReferenceError\nundefined\n",
        },
        .{
            .name = "lexical-const",
            .source =
            \\const fixedCell = 1;
            \\function writeConst() { fixedCell = 2; }
            \\try { writeConst(); print("no throw"); }
            \\catch (error) { print(error.name, fixedCell); }
            ,
            .expected = "TypeError 1\n",
        },
        .{
            .name = "proxy-global-prototype",
            .source =
            \\(function () {
            \\  var emit = print;
            \\  var global = globalThis;
            \\  var ObjectCtor = Object;
            \\  var oldPrototype = ObjectCtor.getPrototypeOf(global);
            \\  var log = [];
            \\  var proxy = new Proxy({}, {
            \\    has: function (_, key) {
            \\      log.push("has:" + key);
            \\      return key === "proxiedDynamic";
            \\    },
            \\    set: function (_, key, value, receiver) {
            \\      log.push("set:" + key + ":" + value + ":" + (receiver === global));
            \\      return true;
            \\    },
            \\  });
            \\  function writeProxy() { proxiedDynamic = 9; }
            \\  ObjectCtor.setPrototypeOf(global, proxy);
            \\  writeProxy();
            \\  ObjectCtor.setPrototypeOf(global, oldPrototype);
            \\  emit(
            \\    log.join("|"),
            \\    ObjectCtor.prototype.hasOwnProperty.call(global, "proxiedDynamic"),
            \\  );
            \\})();
            ,
            .expected = "has:proxiedDynamic|set:proxiedDynamic:9:true false\n",
        },
    };

    for (cases) |case| {
        var js = try helpers.TestEngine.init(std.testing.allocator);
        defer js.deinit();

        var output_buffer: [256]u8 = undefined;
        var output = std.Io.Writer.fixed(&output_buffer);
        const result = try js.evalWithOutput(case.source, &output);

        try std.testing.expect(result.is(.undefined_value));
        try std.testing.expectEqualStrings(case.expected, output.buffered());
    }
}

test "get_var uninitialized-cell inline global-object leg preserves the cold waterfall semantics" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();
    const rt = js.runtime;

    // Q1 red lights: op_get_var's inline uninit leg (qjs OP_get_var
    // quickjs.c mirror) must stay outcome-identical to the cold
    // waterfall (vm_property_globals.getVar) it short-circuits.
    //
    // JS level, exercised through function-hot reads of parked cells:
    //   * frozen `undefined` own-data hit (the pivot shape), including under
    //     "use strict" (runtime_strict gate falls back cold, same value);
    //   * static shadows (var/param/catch) and direct-eval var injection
    //     never reach the leg (locals / checked sequences);
    //   * accessor globals miss the own-DATA test and keep protocol reads;
    //   * deleted dynamic globals park back at UNINITIALIZED and throw
    //     ReferenceError through the cold arm;
    //   * store visibility: no caching, every read sees the live property;
    //   * global lexical TDZ (lexical closure var) still throws cold.
    _ = try js.eval(
        \\globalThis.__q1 = (function () {
        \\  var out = [];
        \\  function readUndef() { return undefined; }
        \\  var hot = 0;
        \\  for (var i = 0; i < 3000; i++) { if (readUndef() === void 0) hot++; }
        \\  out.push(hot);                                            // [0] 3000
        \\  out.push((function(){var undefined = 5; return undefined})()); // [1] 5
        \\  out.push((function(undefined){return undefined})(7));     // [2] 7
        \\  out.push((function(){try{throw 3}catch(undefined){return undefined}})()); // [3] 3
        \\  out.push((function(){eval("var undefined=9"); return undefined})()); // [4] 9
        \\  out.push((function(){"use strict"; return undefined === void 0})()); // [5] true
        \\  Object.defineProperty(globalThis, "__q1acc", { get: function(){ return 42; }, configurable: true });
        \\  var acc = 0;
        \\  function readAcc() { return __q1acc; }
        \\  for (var j = 0; j < 1000; j++) { acc += readAcc(); }
        \\  out.push(acc);                                            // [6] 42000
        \\  globalThis.__q1dyn = 3;
        \\  function readDyn() { return __q1dyn; }
        \\  var dyn = 0;
        \\  for (var k = 0; k < 1000; k++) { dyn += readDyn(); }
        \\  out.push(dyn);                                            // [7] 3000
        \\  globalThis.__q1dyn = 4;
        \\  out.push(readDyn());                                      // [8] 4 (no caching)
        \\  delete globalThis.__q1dyn;
        \\  var threw = 0;
        \\  try { readDyn(); } catch (e) { threw = e instanceof ReferenceError ? 1 : 2; }
        \\  out.push(threw);                                          // [9] 1
        \\  function readTdz() { return __q1lex; }
        \\  var tdz = 0;
        \\  try { readTdz(); } catch (e) { tdz = e instanceof ReferenceError ? 1 : 2; }
        \\  out.push(tdz);                                            // [10] 1
        \\  return out.length * 100 +
        \\    ((out[0] === 3000 && out[1] === 5 && out[2] === 7 && out[3] === 3 &&
        \\      out[4] === 9 && out[5] === true && out[6] === 42000 && out[7] === 3000 &&
        \\      out[8] === 4 && out[9] === 1 && out[10] === 1) ? 1 : 0);
        \\})();
        \\let __q1lex = 1;
    );
    try std.testing.expect(!js.context.hasException());

    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const q1_name = try rt.internAtom("__q1");
    const verdict = try global.getProperty(q1_name);
    // 11 probes, all green.
    try std.testing.expectEqual(@as(?i32, 1101), verdict.as(.int));
}

test "named function expression self-binding materializes lazily with pinned QuickJS semantics" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();
    const rt = js.runtime;

    // Q2 red lights: the self-binding var (kind `.function_name`) and its
    // `special_object THIS_FUNC ; put_loc` prologue materialize lazily now
    // (qjs add_func_var call sites: resolve_scope_var quickjs.c,
    // add_eval_variables quickjs.c) instead of unconditionally at
    // function entry. Every observable of the eager model must hold:
    //   * self-reference returns/recurses the binding, incl. nested
    //     functions, arrows, and generators;
    //   * direct eval materializes conservatively (own body and nested,
    //     including through an invisible block shadow);
    //   * `delete name` stays false (own body and nested arrow);
    //   * strict assignment throws TypeError, sloppy write is ignored;
    //   * `.name` stays intact and non-referencing bodies stay correct;
    //   * shadows win: param, whole-body var, let TDZ, with-object;
    //   * `function arguments(){...}` resolves the arguments object (qjs
    //     parity: the retired eager var used to shadow it -> "function");
    //   * eval under a whole-body var shadow reads the var: the name's
    //     environment is outside the vars (§10.2.11), unlike QuickJS, whose
    //     lazily appended function-name row wins find_var's scan.
    _ = try js.eval(
        \\globalThis.__q2 = (function () {
        \\  var out = [];
        \\  var f = function rec(){ return rec; };
        \\  out.push(f() === f);                                        // [0] true
        \\  var fact = function frec(n){ return n <= 1 ? 1 : n * frec(n - 1); };
        \\  out.push(fact(6));                                          // [1] 720
        \\  var e1 = function rec(){ return eval('rec'); };
        \\  out.push(e1() === e1);                                      // [2] true
        \\  var e2 = function rec(){ return (function inner(){ return eval('rec'); })(); };
        \\  out.push(e2() === e2);                                      // [3] true
        \\  var e3 = function rec(){ { let rec = 0; } return eval('typeof rec'); };
        \\  out.push(e3());                                             // [4] "function"
        \\  out.push(f.name);                                           // [5] "rec"
        \\  var a1 = function rec(){ return () => rec; };
        \\  out.push(a1()() === a1);                                    // [6] true
        \\  var d1 = function rec(){ return function m1(){ return function m2(){ return rec; }; }; };
        \\  out.push(d1()()() === d1);                                  // [7] true
        \\  out.push((function rec(){ return delete rec; })());         // [8] false
        \\  out.push((function rec(){ return (() => delete rec)(); })()); // [9] false
        \\  var threw = 0;
        \\  try { (function rec(){ "use strict"; rec = 1; })(); } catch (e) { threw = e instanceof TypeError ? 1 : 2; }
        \\  out.push(threw);                                            // [10] 1
        \\  out.push((function rec(){ rec = 1; return rec; })() instanceof Function); // [11] true
        \\  var g1 = function* grec(){ yield grec; };
        \\  out.push(g1().next().value === g1);                         // [12] true
        \\  var noref = function nr(a, b){ return a + b; };
        \\  out.push(noref(1, 2) === 3 && noref.name === "nr");         // [13] true
        \\  out.push((function rec(rec){ return rec; })(7));            // [14] 7
        \\  out.push((function rec(){ var rec = 3; return rec; })());   // [15] 3
        \\  var tdz = 0;
        \\  try { (function rec(){ rec; let rec = 1; })(); } catch (e) { tdz = e instanceof ReferenceError ? 1 : 2; }
        \\  out.push(tdz);                                              // [16] 1
        \\  out.push((function arguments(){ return typeof arguments; })()); // [17] "object"
        \\  out.push((function rec(){ with ({ rec: 9 }) { return rec; } })()); // [18] 9
        \\  var w1 = function rec(){ with ({}) { return rec; } };
        \\  out.push(w1() === w1);                                      // [19] true
        \\  out.push((function rec(){ var rec = 11; return eval('rec'); })()); // [20] 11
        \\  out.push(typeof (function rec(){ { let rec; } return rec; })()); // [21] "function"
        \\  return out.length * 1000 +
        \\    ((out[0] === true && out[1] === 720 && out[2] === true && out[3] === true &&
        \\      out[4] === "function" && out[5] === "rec" && out[6] === true && out[7] === true &&
        \\      out[8] === false && out[9] === false && out[10] === 1 && out[11] === true &&
        \\      out[12] === true && out[13] === true && out[14] === 7 && out[15] === 3 &&
        \\      out[16] === 1 && out[17] === "object" && out[18] === 9 && out[19] === true &&
        \\      out[20] === 11 && out[21] === "function") ? 1 : 0);
        \\})();
    );
    try std.testing.expect(!js.context.hasException());

    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const q2_name = try rt.internAtom("__q2");
    const verdict = try global.getProperty(q2_name);
    // 22 probes, all green.
    try std.testing.expectEqual(@as(?i32, 22001), verdict.as(.int));
}

test "K2 warm leaf miss retreat keeps call accounting balanced across chunk and carve misses" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    // The budget check compares native SP minus the accumulated bytecode
    // budget against the native limit; this test intentionally accumulates
    // ~0.8MB of planned frame bytes to cross the 32K-slot arena chunk, so
    // widen the native window (the miss-retreat mechanism under test never
    // depends on it — an admission failure commits nothing).
    js.runtime.setNativeStackSize(8 * 1024 * 1024);

    const baseline_call_depth = js.runtime.stack.call_depth;
    const baseline_native_depth = js.runtime.stack.native_call_depth;
    const baseline_stack_bytes = js.runtime.stack.bytecode_bytes;
    const baseline_arena_mark = js.runtime.vm_stack.mark();

    // A right-nested addition gives the leaf bodies a ~97-slot operand stack
    // window, an order of magnitude above the driver's ~20 slots/frame, so
    // the level at which arena chunk 0 first lacks leaf capacity is reached
    // while the driver itself still fits: the warm leaf constructors take the
    // carve-miss retreat there (and the entries-chunk 16-boundary miss ~150
    // times on the way down). bigleaf covers the empty-leaf family, bigleaf1
    // the exact-args family, cap the capture family.
    const deep_expr = ("1+(" ** 96) ++ "1" ++ (")" ** 96);
    const source =
        "function bigleaf(){ return " ++ deep_expr ++ "; }\n" ++
        "function bigleaf1(x){ return " ++ deep_expr ++ "; }\n" ++
        "function mkcap(){ var q = 3; return function(){ return q + q; }; }\n" ++
        "var cap = mkcap();\n" ++
        "function f(n){\n" ++
        "  bigleaf(); bigleaf1(n); cap();\n" ++
        "  var a=n+1, b=a+1, c=b+1, d=c+1, e=d+1, g=e+1, h=g+1, k=h+1, m=k+1, p=m+1, r=p+1, s=r+1;\n" ++
        "  if (n === 0) return a+b+c+d+e+g+h+k+m+p+r+s;\n" ++
        "  return f(n-1) + 1;\n" ++
        "}\n" ++
        "var __k2_deep = f(2400);\n";

    _ = try js.eval(source);
    try std.testing.expect(!js.context.hasException());

    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const key = try js.runtime.internAtom("__k2_deep");
    const deep_value = try global.getProperty(key);
    // n=0 level: locals sum 1+2+...+12 = 78, plus one per recursion level.
    try std.testing.expectEqual(@as(?i32, 78 + 2400), deep_value.as(.int));

    // The arena must actually have crossed into a second chunk — otherwise
    // this test lost its carve-miss coverage (e.g. geometry drift).
    try std.testing.expect(js.runtime.vm_stack.chunk_count >= 2);

    // Every warm miss committed and then retreated its budget charge; any
    // imbalance (missing or doubled retreat) leaves a residue here.
    try std.testing.expectEqual(baseline_call_depth, js.runtime.stack.call_depth);
    try std.testing.expectEqual(baseline_native_depth, js.runtime.stack.native_call_depth);
    try std.testing.expectEqual(baseline_stack_bytes, js.runtime.stack.bytecode_bytes);
    try std.testing.expectEqual(baseline_arena_mark, js.runtime.vm_stack.mark());
}

test "latin1 high bytes survive raw-string byte bridges (qjs JS_ToCStringLen2 mirror)" {
    // Regression: value_ops.appendRawString used to append latin1 payload
    // bytes raw into UTF-8 byte buffers; any 0x80-0xFF code point then broke
    // the createStringValue re-decode ("URIError: expecting hex digit").
    // Each leg below reproduced against qjs before the width-aware fix.
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.evalWithOptions(
        \\(function () {
        \\    var out = [];
        \\    var f = function () {};
        \\    Object.defineProperty(f, "name", { value: "é" });
        \\    out.push(f.bind(null).name === "bound é");
        \\    var tagged = {};
        \\    tagged[Symbol.toStringTag] = "étag";
        \\    out.push(Object.prototype.toString.call(tagged) === "[object étag]");
        \\    out.push(Symbol("é").toString() === "Symbol(é)");
        \\    out.push(Symbol("é").description === "é");
        \\    out.push(new Error("mé").toString() === "Error: mé");
        \\    out.push(["a", "b"].join("é") === "aéb");
        \\    out.push(new Int8Array([1, 2]).join("é") === "1é2");
        \\    out.push(new RegExp("éx").toString() === "/éx/");
        \\    out.push(["é"].toLocaleString() === "é");
        \\    try {
        \\        var C = class éc {};
        \\        C();
        \\        out.push("no-throw");
        \\    } catch (e) {
        \\        out.push(e instanceof TypeError);
        \\    }
        \\    var stack_ok = false;
        \\    try {
        \\        (function éfn() { throw new Error("boom"); })();
        \\    } catch (e) {
        \\        stack_ok = typeof e.stack === "string" && e.stack.indexOf("éfn") >= 0;
        \\    }
        \\    out.push(stack_ok);
        \\    return out.join(",");
        \\})()
    , .{ .filename = "<repl>" });
    try helpers.expectStringValueBytes(
        result,
        "true,true,true,true,true,true,true,true,true,true,true",
    );
}

test "ToNumber latin1 high bytes are code points not UTF-8 whitespace" {
    // X-38: latin1 0x80-0xFF are single code points. Feeding the raw bytes to
    // a UTF-8 whitespace decoder made Number("\xe2\x80\x801") == 1 while
    // qjs skip_spaces (qjs:11230) / lre_is_space classify by code point.

    try helpers.expectPrints(
        \\var s = String.fromCharCode(0xE2,0x80,0x80) + "1";
        \\print("len="+s.length+" cc="+s.charCodeAt(0)+","+s.charCodeAt(1)+","+s.charCodeAt(2)+","+s.charCodeAt(3));
        \\print("Number(s)="+Number(s));  print("+s="+(+s));  print("-s="+(-s));
        \\print("parseFloat="+parseFloat(s));  print("parseInt="+parseInt(s));  print("Math.abs="+Math.abs(s));
        \\print("eqloose="+(s==1));  print("at="+[7,8].at(s));
        \\print("Math.max="+Math.max(s,0));  print("slice="+[1,2,3].slice(s).length);
        \\print("s*2="+(s*2));  print("s|0="+(s|0));
        \\var seqs = [
        \\  [0xC2,0xA0],
        \\  [0xE1,0x9A,0x80],
        \\  [0xE2,0x81,0x9F],
        \\  [0xE3,0x80,0x80],
        \\  [0xEF,0xBB,0xBF],
        \\  [0xE2,0x80,0x8A],
        \\  [0xE2,0x80,0xA8]
        \\];
        \\seqs.forEach(function(seq, i){
        \\  var prefix = String.fromCharCode.apply(null, seq) + "1";
        \\  var suffix = "1" + String.fromCharCode.apply(null, seq);
        \\  print("p"+i+" Number="+Number(prefix)+" parseFloat="+parseFloat(prefix)+" parseInt="+parseInt(prefix));
        \\  print("s"+i+" Number="+Number(suffix)+" parseFloat="+parseFloat(suffix)+" parseInt="+parseInt(suffix));
        \\});
        \\var a0 = String.fromCharCode(0xA0) + "1";
        \\print("bareA0 Number="+Number(a0)+" parseFloat="+parseFloat(a0));
        \\print("U00A0 Number="+Number("\u00A0"+"1")+" parseFloat="+parseFloat("\u00A0"+"1"));
        \\print("U2000 Number="+Number("\u2000"+"1")+" parseFloat="+parseFloat("\u2000"+"1"));
        \\print("UFEFF Number="+Number("\uFEFF"+"1")+" parseFloat="+parseFloat("\uFEFF"+"1"));
    , "len=4 cc=226,128,128,49\n" ++
        "Number(s)=NaN\n" ++
        "+s=NaN\n" ++
        "-s=NaN\n" ++
        "parseFloat=NaN\n" ++
        "parseInt=NaN\n" ++
        "Math.abs=NaN\n" ++
        "eqloose=false\n" ++
        "at=7\n" ++
        "Math.max=NaN\n" ++
        "slice=3\n" ++
        "s*2=NaN\n" ++
        "s|0=0\n" ++
        "p0 Number=NaN parseFloat=NaN parseInt=NaN\n" ++
        "s0 Number=NaN parseFloat=1 parseInt=1\n" ++
        "p1 Number=NaN parseFloat=NaN parseInt=NaN\n" ++
        "s1 Number=NaN parseFloat=1 parseInt=1\n" ++
        "p2 Number=NaN parseFloat=NaN parseInt=NaN\n" ++
        "s2 Number=NaN parseFloat=1 parseInt=1\n" ++
        "p3 Number=NaN parseFloat=NaN parseInt=NaN\n" ++
        "s3 Number=NaN parseFloat=1 parseInt=1\n" ++
        "p4 Number=NaN parseFloat=NaN parseInt=NaN\n" ++
        "s4 Number=NaN parseFloat=1 parseInt=1\n" ++
        "p5 Number=NaN parseFloat=NaN parseInt=NaN\n" ++
        "s5 Number=NaN parseFloat=1 parseInt=1\n" ++
        "p6 Number=NaN parseFloat=NaN parseInt=NaN\n" ++
        "s6 Number=NaN parseFloat=1 parseInt=1\n" ++
        "bareA0 Number=1 parseFloat=1\n" ++
        "U00A0 Number=1 parseFloat=1\n" ++
        "U2000 Number=1 parseFloat=1\n" ++
        "UFEFF Number=1 parseFloat=1\n");
}

test "JSON.rawJSON latin1 payload survives the simple stringify byte buffer" {
    // Regression: json_ops' local appendRawString clone appended raw latin1
    // bytes into the stringify buffer, breaking the final UTF-8 re-decode.
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.evalWithOptions(
        \\[
        \\    JSON.stringify(JSON.rawJSON('"é"')) === '"é"',
        \\    JSON.stringify({ x: JSON.rawJSON('"é"') }, null, 1) === '{\n "x": "é"\n}',
        \\].join(",")
    , .{ .filename = "<repl>" });
    try helpers.expectStringValueBytes(result, "true,true");
}

test "native function toString keeps non-ASCII identifier names (qjs js_function_toString)" {
    // Regression: the native-source name filter only accepted ASCII
    // identifiers, silently dropping latin1/unicode identifier names that
    // qjs js_function_toString emits verbatim.
    // The name printed is [[InitialName]], so a later rename does not show.
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const Host = struct {
        fn call(c: *zjs.Call) !zjs.Value {
            _ = c;
            return core.JSValue.undefinedValue();
        }
    };
    var facade = zjs.borrowContext(js.context);
    _ = try facade.defineFunction("ém", zjs.native.managed(Host.call), .{});

    const result = try js.evalWithOptions(
        \\(function () {
        \\    Object.defineProperty(Math.max, "name", { value: "renamed", configurable: true });
        \\    return globalThis["ém"].toString() === "function ém() {\n    [native code]\n}" &&
        \\        Math.max.toString() === "function max() {\n    [native code]\n}";
        \\})()
    , .{ .filename = "<repl>" });
    try std.testing.expectEqual(true, result.as(.boolean).?);
}

test "switch dispatch trampoline shapes keep their identity and semantics" {
    // Switch-dispatch regression corpus. Each source below pins the
    // observable clause-fallthrough semantics of the shapes that exercise
    // the resolver's dispatch folding.
    //
    // The epilogue dispatch bridge several of these shapes were written
    // against no longer exists: the unmatched-dispatch references now move onto
    // the default identity (`Builder.retargetLabelRefs`), which is what legacy
    // `patchJumpTarget` does. The shapes stay as the corpus that proves it.
    //
    // Each shape reproduced a distinct lowering divergence:
    //   [0] `case a: b(); case c: default: e();` — the branch whose target
    //       resolves to its own fallthrough only after the bridge folds away.
    //   [1] `case a: default: e();` — the empty case falling into a trailing
    //       default (first found through the atom-balance corpus).
    //   [2]/[5]/[6] empty `default` clause followed by a `case`: the clause
    //       tail flow predicate has to read the code emitted BEFORE the empty
    //       body, exactly like `caseCanFallthrough`'s whole-stream summary.
    //   [3]/[7] a default label bound at the switch epilogue: the dispatch
    //       bridge must not be emitted at all.
    //   [4] leading empty `default`.
    //   [8] nested loops whose inner backedge dies: the for-loop top label is
    //       a physical `OP_label` in the legacy stream and keeps its
    //       sequential-match barrier, so `put_loc; get_loc` never fuses.
    //   [9]/[10] a leading `default` whose switch ends in a break-only clause:
    //       the dispatch bridge must stay invisible to the branch-inversion
    //       peephole (pdfjs `CanvasGraphics_showText`).
    //   [11] `while (..) { if (..) return; }`: the `undefined; return` fold has
    //       to drop its dead tail or the loop backedge survives.
    //   [12]-[15] a clause body ending in an if/else whose test folds falsy and
    //       whose taken arm is empty. Its two converging labels bind exactly
    //       where the epilogue starts, so while the dispatch bridge existed
    //       they bound on the bridge's skip goto instead of the epilogue:
    //       `findJumpTarget` threaded one hop further than legacy and the
    //       jump-to-own-fallthrough legacy folds survived in v2 (test262
    //       annexB `*if-stmt-else-decl-*-skip-early-err-switch`, 5 files).
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.evalWithOptions(
        \\(function () {
        \\    function run(f) {
        \\        var parts = [];
        \\        var inputs = [1, 2, 3, 9];
        \\        for (var i = 0; i < inputs.length; i++) parts.push(f(inputs[i]));
        \\        return parts.join(",");
        \\    }
        \\    var out = [];
        \\    out.push(run(function (d) { var s = ""; switch (d) { case 1: s += "a"; case 2: default: s += "b"; } return s; }));
        \\    out.push(run(function (d) { var s = ""; switch (d) { case 1: default: s += "b"; } return s; }));
        \\    out.push(run(function (d) { var s = ""; switch (d) { case 1: s += "a"; default: case 2: s += "b"; } return s; }));
        \\    out.push(run(function (d) { var s = "x"; switch (d) { case 1: case 2: default: } return s; }));
        \\    out.push(run(function (d) { var s = ""; switch (d) { default: case 1: s += "b"; } return s; }));
        \\    out.push(run(function (d) { var s = ""; switch (d) { case 1: s += "a"; default: case 2: s += "b"; case 3: s += "c"; } return s; }));
        \\    out.push(run(function (d) { var s = ""; switch (d) { case 1: case 2: default: case 3: case 9: s += "z"; } return s; }));
        \\    out.push(run(function (d) { var s = "y"; switch (d) { case 1: s += "a"; break; default: } return s; }));
        \\    out.push((function () {
        \\        var n = 0;
        \\        outer: for (var i = 0; i < 3; i++) { for (var j = 0; j < 3; j++) { n += 1; continue outer; } }
        \\        return "" + n;
        \\    })());
        \\    out.push(run(function (d) { var s = "q"; switch (d) { default: s += "d"; break; case 3: break; } return s; }));
        \\    out.push(run(function (d) { var s = ""; switch (d) { default: case 1: s += "a"; break; case 2: case 9: s += "b"; break; case 3: break; } return s; }));
        \\    out.push((function () {
        \\        var n = 0;
        \\        function loopReturn(a, c) { while (a) { n += 1; if (c) return "r"; } return "w"; }
        \\        return loopReturn(1, 1) + loopReturn(0, 0);
        \\    })());
        \\    out.push(run(function (d) { var s = "e"; switch (d) { default: if (false) ; else ; } return s; }));
        \\    out.push(run(function (d) { var s = ""; switch (d) { case 1: s += "a"; default: if (false) { } else { } } return s; }));
        \\    out.push(run(function (d) { var s = ""; switch (d) { default: let f = "L"; s += f; if (false) ; else ; } return s; }));
        \\    out.push(run(function (d) { var s = "n"; switch (d) { case 1: s += "a"; break; default: switch (d) { default: if (false) ; else ; } } return s; }));
        \\    return out.join("|");
        \\})()
    , .{ .filename = "<repl>" });
    try helpers.expectStringValueBytes(
        result,
        "ab,b,b,b|b,b,b,b|ab,b,b,b|x,x,x,x|b,b,b,b|abc,bc,c,bc|z,z,z,z|ya,y,y,y|3" ++
            "|qd,qd,q,qd|a,b,,b|rw" ++
            "|e,e,e,e|a,,,|L,L,L,L|na,n,n,n",
    );
}

test "top-level direct eval does not break private-name eval resolution" {
    try helpers.expectPrints(
        \\class C {
        \\  #f = 1;
        \\  get #g(){ return 2; }
        \\  #p(){ return 3; }
        \\  read(){ return eval("this.#f"); }
        \\  getg(){ return eval("this.#g"); }
        \\  callp(){ return eval("this.#p()"); }
        \\  brand(){ return eval("#f in this"); }
        \\  write(){ return eval("this.#f = 50, this.#f"); }
        \\  noneval(){ return this.#f + this.#g + this.#p(); }
        \\}
        \\var o = new C();
        \\function show(label, fn){
        \\  try { print(label + ": " + fn()); }
        \\  catch(e){ print(label + " threw: " + e.name + " | " + e.message); }
        \\}
        \\show("field", function(){ return o.read(); });
        \\show("getter", function(){ return o.getg(); });
        \\show("method", function(){ return o.callp(); });
        \\show("brand", function(){ return o.brand(); });
        \\show("write", function(){ return o.write(); });
        \\show("noneval", function(){ return o.noneval(); });
        \\eval("1");
    , "field: 1\ngetter: 2\nmethod: 3\nbrand: true\nwrite: 50\nnoneval: 55\n");
}

test "switch fallthrough after while-family tails reaches the next case" {
    try helpers.expectPrints(
        \\function run(body){
        \\  var r=[];
        \\  switch(0){
        \\    case 0: body();
        \\    case 1: r.push("b"); break;
        \\    default: r.push("d");
        \\  }
        \\  return r.join(",");
        \\}
        \\print(run(function(){ while(true){break;} }));
        \\print(run(function(){ while(1)break; }));
        \\print(run(function(){ lbl:while(true){break lbl;} }));
        \\print(run(function(){ for(;;){break;} }));
        \\print(run(function(){ for(;;)break; }));
        \\print(run(function(){ do{break;}while(0); }));
        \\print(run(function(){ { } }));
        \\print(run(function(){ if(1){}else{} }));
        \\print(run(function(){ for(var i of []){} }));
        \\print(run(function(){ for(var k in {}){} }));
        \\print(run(function(){ try{}catch(e){} }));
        \\print(run(function(){ for(var q=0;q<1;q++){continue;} }));
        \\function t(x){ var r=[]; switch(x){ case 0: while(true){ r.push("a"); break; } case 1: r.push("b"); break; default: r.push("d"); } return r.join(","); }
        \\print(t(0));
        \\switch(0){ case 0: if(false) break; print("y"); case 1: print("z"); }
    , "b\nb\nb\nb\nb\nb\nb\nb\nb\nb\nb\nb\na,b\ny\nz\n");
}

test "small-function-inlining: sc_Pair constructor is eligible and arguments ctor is not" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    _ = try js.eval(
        \\function sc_Pair(car, cdr) { this.car = car; this.cdr = cdr; }
        \\function usesArgs() { return arguments[0]; }
        \\function big(a,b,c,d,e) { this.a=a; this.b=b; this.c=c; this.d=d; this.e=e; }
        \\globalThis.__p = sc_Pair;
        \\globalThis.__a = usesArgs;
        \\globalThis.__b = big;
    );

    const global = try js.context.globalObject();
    const pair_fn = try global.getProperty(try js.runtime.internAtom("__p"));
    const args_fn = try global.getProperty(try js.runtime.internAtom("__a"));
    const big_fn = try global.getProperty(try js.runtime.internAtom("__b"));

    const pair_obj = zjs.exec.object_ops.plainBytecodeFunctionObjectFromValue(pair_fn).?;
    const args_obj = zjs.exec.object_ops.plainBytecodeFunctionObjectFromValue(args_fn).?;
    const big_obj = zjs.exec.object_ops.plainBytecodeFunctionObjectFromValue(big_fn).?;
    const pair_fb = pair_obj.bytecodeArm().*.function_bytecode.?;
    try std.testing.expect(pair_fb.smallInlineEligible());
    try std.testing.expect(!args_obj.bytecodeArm().*.function_bytecode.?.smallInlineEligible());
    try std.testing.expect(!big_obj.bytecodeArm().*.function_bytecode.?.smallInlineEligible());
}

test "small-function-inlining: setter throw stack is setter, ctor, caller" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    var output_buffer: [512]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    _ = try js.evalWithOutput(
        \\function C(v) { this.x = v; }
        \\function outer(v) { return new C(v); }
        \\var i;
        \\for (i = 0; i < 16; i++) outer(i);
        \\Object.defineProperty(C.prototype, "x", {
        \\  set: function setX(v) { throw new Error("boom"); }
        \\});
        \\try {
        \\  outer(99);
        \\} catch (e) {
        \\  var s = String(e.stack);
        \\  print(s.indexOf("setX") >= 0 ? "setX" : "no-setX");
        \\  print(s.indexOf("C") >= 0 ? "C" : "no-C");
        \\  print(s.indexOf("outer") >= 0 ? "outer" : "no-outer");
        \\}
    , &output);
    try std.testing.expectEqualStrings("setX\nC\nouter\n", output.buffered());
}

test "small-function-inlining: redefinition takes the new function" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const result = try js.eval(
        \\function m1() { return 1; }
        \\function m2() { return 2; }
        \\var o = { m: m1 };
        \\function outer(obj) { return obj.m(); }
        \\var i, last;
        \\for (i = 0; i < 16; i++) last = outer(o);
        \\o.m = m2;
        \\assert.sameValue(outer(o), 2);
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "small-function-inlining: new C field write is visible" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const result = try js.eval(
        \\function C() { this.x = 1; }
        \\function outer() { return new C(); }
        \\var i, o;
        \\for (i = 0; i < 16; i++) o = outer();
        \\assert.sameValue(o.x, 1);
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "small-function-inlining: polymorphic site is not specialized" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const result = try js.eval(
        \\function A(v) { this.v = v; }
        \\function B(v) { this.v = v + 1; }
        \\function outer(C, v) { return new C(v); }
        \\var i, last;
        \\for (i = 0; i < 20; i++) last = outer(i & 1 ? A : B, i);
        \\assert.sameValue(typeof last.v, "number");
        \\assert.sameValue(outer(A, 10).v, 10);
        \\assert.sameValue(outer(B, 10).v, 11);
        \\globalThis.__outer = outer;
    );
    try std.testing.expect(result.is(.undefined_value));

    const global = try js.context.globalObject();
    const outer_fn = try global.getProperty(try js.runtime.internAtom("__outer"));
    const outer_obj = zjs.exec.object_ops.plainBytecodeFunctionObjectFromValue(outer_fn).?;
    const outer_fb = outer_obj.bytecodeArm().*.function_bytecode.?;
    if (zjs.exec.small_inline.callerState(outer_fb)) |state| {
        try std.testing.expectEqual(@as(u8, 0), state.inlined_len);
        var i: u8 = 0;
        var saw_never = false;
        while (i < state.site_len) : (i += 1) {
            if (state.sites[i].never) saw_never = true;
        }
        try std.testing.expect(saw_never);
    }
}

test "small-function-inlining: R-2 getter on callee is invoked once per new" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const result = try js.eval(
        \\var n = 0;
        \\function RealC(v) { this.x = v; }
        \\Object.defineProperty(globalThis, "C", {
        \\  get: function () { n += 1; return RealC; },
        \\  configurable: true
        \\});
        \\function outer(v) { return new C(v); }
        \\var i;
        \\for (i = 0; i < 16; i++) outer(i);
        \\assert.sameValue(n, 16);
        \\assert.sameValue(outer(7).x, 7);
        \\assert.sameValue(n, 17);
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "small-function-inlining: inner throw stack and caller catch" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    var output_buffer: [512]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    _ = try js.evalWithOutput(
        \\function inner() { throw new Error("x"); }
        \\function outer() { return inner(); }
        \\var i;
        \\for (i = 0; i < 16; i++) { try { outer(); } catch (e) {} }
        \\try { outer(); } catch (e) {
        \\  var s = String(e.stack);
        \\  print(s.indexOf("inner") >= 0 ? "inner" : "no-inner");
        \\  print(s.indexOf("outer") >= 0 ? "outer" : "no-outer");
        \\}
    , &output);
    try std.testing.expectEqualStrings("inner\nouter\n", output.buffered());
}

test "small-function-inlining: primitive ctor return keeps instance" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const result = try js.eval(
        \\function C() { this.x = 1; return 0; }
        \\function outer() { return new C(); }
        \\var i, o;
        \\for (i = 0; i < 16; i++) o = outer();
        \\assert.sameValue(typeof o, "object");
        \\assert.sameValue(o.x, 1);
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "small-function-inlining: Reflect.construct with foreign NewTarget is not expanded" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const result = try js.eval(
        \\function C(v) { this.x = v; }
        \\function NT() {}
        \\NT.prototype = { mark: 1 };
        \\function outer(v) { return Reflect.construct(C, [v], NT); }
        \\var i, o;
        \\for (i = 0; i < 16; i++) o = outer(i);
        \\assert.sameValue(o.x, 15);
        \\assert.sameValue(o.mark, 1);
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "small-function-inlining: derived class constructor is not eligible" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    _ = try js.eval(
        \\class B {}
        \\class D extends B { constructor(v) { super(); this.x = v; } }
        \\globalThis.__d = D;
    );
    const global = try js.context.globalObject();
    const d_fn = try global.getProperty(try js.runtime.internAtom("__d"));
    const d_obj = zjs.exec.object_ops.plainBytecodeFunctionObjectFromValue(d_fn).?;
    try std.testing.expect(!d_obj.bytecodeArm().*.function_bytecode.?.smallInlineEligible());
}

test "small-function-inlining: next-entry specialize is installed on the caller" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const result = try js.eval(
        \\function Three(a, b, c) { this.x = a; this.y = b; this.z = c; }
        \\function batch(n) {
        \\  var i, s = 0, p;
        \\  for (i = 0; i < n; i++) { p = new Three(1, 2, 3); s = s + p.x; }
        \\  return s;
        \\}
        \\globalThis.__batch = batch;
        \\assert.sameValue(batch(16), 16);
        \\assert.sameValue(batch(16), 16);
    );
    try std.testing.expect(result.is(.undefined_value));
    const global = try js.context.globalObject();
    const batch_fn = try global.getProperty(try js.runtime.internAtom("__batch"));
    const batch_obj = zjs.exec.object_ops.plainBytecodeFunctionObjectFromValue(batch_fn).?;
    const batch_fb = batch_obj.bytecodeArm().*.function_bytecode.?;
    const state = zjs.exec.small_inline.callerState(batch_fb);
    try std.testing.expect(state != null);
    try std.testing.expect(state.?.inlined_len >= 1);
    try std.testing.expect(state.?.specialized);
}

test "small-function-inlining: CallerState atoms reach the tracer without a runtime hook" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    _ = try js.eval(
        \\function Three(a, b, c) { this.x = a; this.y = b; this.z = c; }
        \\function batch(n) {
        \\  var i, s = 0, p;
        \\  for (i = 0; i < n; i++) { p = new Three(1, 2, 3); s = s + p.x; }
        \\  return s;
        \\}
        \\globalThis.__batch = batch;
        \\batch(16);
        \\batch(16);
    );
    const global = try js.context.globalObject();
    const batch_fn = try global.getProperty(try js.runtime.internAtom("__batch"));
    const batch_fb = zjs.exec.object_ops.plainBytecodeFunctionObjectFromValue(batch_fn).?.bytecodeArm().*.function_bytecode.?;
    const state = zjs.exec.small_inline.callerState(batch_fb).?;
    try std.testing.expect(state.inlined_len >= 1);
    const Recorder = struct {
        pub const gc_visit_policy: zjs.core.gc_visit.Policy = .partial;
        want: zjs.core.Atom,
        seen: bool = false,
        pub fn visitAtom(self: *@This(), id: zjs.core.Atom) void {
            if (id == self.want) self.seen = true;
        }
    };
    var recorder = Recorder{ .want = state.inlined[0].callee_name };
    try zjs.exec.small_inline.traceCallerStateAtoms(batch_fb, &recorder);
    try std.testing.expect(recorder.seen);
}

test "small-function-inlining: spec copy keeps simple_inline bits after extra TAKE locals" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const result = try js.eval(
        \\function C(v) { this.x = v; }
        \\function outer(v) { return new C(v); }
        \\globalThis.__outer = outer;
        \\var i, last;
        \\for (i = 0; i < 16; i++) last = outer(i);
        \\assert.sameValue(last.x, 15);
        \\assert.sameValue(outer(7).x, 7);
    );
    try std.testing.expect(result.is(.undefined_value));
    const global = try js.context.globalObject();
    const outer_fn = try global.getProperty(try js.runtime.internAtom("__outer"));
    const outer_obj = zjs.exec.object_ops.plainBytecodeFunctionObjectFromValue(outer_fn).?;
    const outer_fb = outer_obj.bytecodeArm().*.function_bytecode.?;
    const state = zjs.exec.small_inline.callerState(outer_fb);
    try std.testing.expect(state != null);
    try std.testing.expect(state.?.inlined_len >= 1);
    // Extra TAKE window: not a Fast leaf (var_count==0), but still the
    // qjs:17828 simple-inline shape (simple_inline_base holds).
    try std.testing.expect(outer_fb.var_count > 0);
    try std.testing.expect(outer_fb.simpleInlineEligible());
    try std.testing.expect(!outer_fb.strictSimpleInlineEligible());
    try std.testing.expect(!outer_fb.strictSimpleSnapshotInlineEligible());
    try std.testing.expect(!outer_fb.simpleInlineEmptyLeaf());
    try std.testing.expect(!outer_fb.rawThisInlineEmptyLeaf());
    try std.testing.expect(!outer_fb.simpleInlineExactArgsLeaf());
    try std.testing.expect(!outer_fb.rawThisInlineExactArgsLeaf());
    try std.testing.expectEqual(.none, outer_fb.exactArgsLeafKind());
    try std.testing.expectEqual(.none, outer_fb.captureLeafKind());
}

test "small-function-inlining: sibling constructor sites both specialize" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const result = try js.eval(
        \\function Pair(a, b) { this.x = a; this.y = b; }
        \\function both(a, b) {
        \\  var p = new Pair(a, b);
        \\  var q = new Pair(b, a);
        \\  return p.x + q.x;
        \\}
        \\globalThis.__both = both;
        \\var i, last;
        \\for (i = 0; i < 16; i++) last = both(1, 2);
        \\assert.sameValue(last, 3);
        \\assert.sameValue(both(4, 5), 9);
    );
    try std.testing.expect(result.is(.undefined_value));
    const global = try js.context.globalObject();
    const both_fn = try global.getProperty(try js.runtime.internAtom("__both"));
    const both_obj = zjs.exec.object_ops.plainBytecodeFunctionObjectFromValue(both_fn).?;
    const both_fb = both_obj.bytecodeArm().*.function_bytecode.?;
    const state = zjs.exec.small_inline.callerState(both_fb);
    try std.testing.expect(state != null);
    try std.testing.expect(state.?.inlined_len >= 2);
}

test "small-function-inlining: proto replacement after specialize is observed" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const result = try js.eval(
        \\function C(v) { this.x = v; }
        \\function outer(v) { return new C(v); }
        \\var i, o;
        \\for (i = 0; i < 16; i++) o = outer(i);
        \\C.prototype = { mark: 1 };
        \\o = outer(99);
        \\assert.sameValue(o.x, 99);
        \\assert.sameValue(o.mark, 1);
        \\C.foo = 1;
        \\o = outer(7);
        \\assert.sameValue(o.x, 7);
        \\assert.sameValue(o.mark, 1);
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "small-function-inlining: call_constructor callers keep published frame geometry" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const result = try js.eval(
        \\function C(v) { this.x = v; }
        \\function outer(v) { return new C(v); }
        \\globalThis.__outer = outer;
    );
    try std.testing.expect(result.is(.undefined_value));
    const global = try js.context.globalObject();
    const outer_fn = try global.getProperty(try js.runtime.internAtom("__outer"));
    const outer_obj = zjs.exec.object_ops.plainBytecodeFunctionObjectFromValue(outer_fn).?;
    const outer_fb = outer_obj.bytecodeArm().*.function_bytecode.?;
    // Deleted OSR spare was +9 locals / +4 stack on every call_constructor
    // caller. Published geometry must match the compiler's real slots.
    try std.testing.expectEqual(@as(u16, 0), outer_fb.var_count);
}

test "small-function-inlining: leftover-operand bodies are not small-inline eligible" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    _ = try js.eval(
        \\function leftoverDrop() { ({ z: 1 }); }
        \\function leftoverSwitch() { switch ({ x: 7 }) { default: return 5; } }
        \\function leftoverCtor() { ({ z: 1 }); }
        \\function balancedInc() { return this.v + 1; }
        \\globalThis.__drop = leftoverDrop;
        \\globalThis.__sw = leftoverSwitch;
        \\globalThis.__ctor = leftoverCtor;
        \\globalThis.__inc = balancedInc;
    );
    const global = try js.context.globalObject();
    const drop_fn = try global.getProperty(try js.runtime.internAtom("__drop"));
    const sw_fn = try global.getProperty(try js.runtime.internAtom("__sw"));
    const ctor_fn = try global.getProperty(try js.runtime.internAtom("__ctor"));
    const inc_fn = try global.getProperty(try js.runtime.internAtom("__inc"));
    try std.testing.expect(!zjs.exec.object_ops.plainBytecodeFunctionObjectFromValue(drop_fn).?.bytecodeArm().*.function_bytecode.?.smallInlineEligible());
    try std.testing.expect(!zjs.exec.object_ops.plainBytecodeFunctionObjectFromValue(sw_fn).?.bytecodeArm().*.function_bytecode.?.smallInlineEligible());
    try std.testing.expect(!zjs.exec.object_ops.plainBytecodeFunctionObjectFromValue(ctor_fn).?.bytecodeArm().*.function_bytecode.?.smallInlineEligible());
    try std.testing.expect(zjs.exec.object_ops.plainBytecodeFunctionObjectFromValue(inc_fn).?.bytecodeArm().*.function_bytecode.?.smallInlineEligible());
}

test "small-function-inlining: leftover ctor is not specialized and does not overflow" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const result = try js.eval(
        \\function C() { ({ z: 1 }); }
        \\function outer() { return new C(); }
        \\var i, last;
        \\for (i = 0; i < 256; i++) last = outer();
        \\assert.sameValue(typeof last, "object");
        \\globalThis.__C = C;
        \\globalThis.__outer = outer;
    );
    try std.testing.expect(result.is(.undefined_value));
    const global = try js.context.globalObject();
    const c_fn = try global.getProperty(try js.runtime.internAtom("__C"));
    try std.testing.expect(!zjs.exec.object_ops.plainBytecodeFunctionObjectFromValue(c_fn).?.bytecodeArm().*.function_bytecode.?.smallInlineEligible());
    const outer_fn = try global.getProperty(try js.runtime.internAtom("__outer"));
    const outer_obj = zjs.exec.object_ops.plainBytecodeFunctionObjectFromValue(outer_fn).?;
    const outer_fb = outer_obj.bytecodeArm().*.function_bytecode.?;
    if (zjs.exec.small_inline.callerState(outer_fb)) |state| {
        try std.testing.expectEqual(@as(u8, 0), state.inlined_len);
    }
}

test "small-function-inlining: extra ctor args do not overwrite callee fields" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const result = try js.eval(
        \\function Pair(a, b) { this.x = a; this.y = b; }
        \\function outer() { return new Pair(1, 2, { leak: 1 }); }
        \\var i, last;
        \\for (i = 0; i < 16; i++) last = outer();
        \\assert.sameValue(last.x, 1);
        \\assert.sameValue(last.y, 2);
        \\assert.sameValue(last.leak, undefined);
        \\globalThis.__outer = outer;
    );
    try std.testing.expect(result.is(.undefined_value));
    const global = try js.context.globalObject();
    const outer_fn = try global.getProperty(try js.runtime.internAtom("__outer"));
    const outer_obj = zjs.exec.object_ops.plainBytecodeFunctionObjectFromValue(outer_fn).?;
    const outer_fb = outer_obj.bytecodeArm().*.function_bytecode.?;
    const state = zjs.exec.small_inline.callerState(outer_fb);
    try std.testing.expect(state != null);
    try std.testing.expect(state.?.inlined_len >= 1);
}

test "small-function-inlining: monomorphic method is expanded" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const result = try js.eval(
        \\function Box(v) { this.v = v; }
        \\Box.prototype.inc = function () { return this.v + 1; };
        \\function outer(b) { return b.inc(); }
        \\var i, last, box = new Box(3);
        \\for (i = 0; i < 16; i++) last = outer(box);
        \\assert.sameValue(last, 4);
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "small-function-inlining L1: apply-arguments ctor specializes" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const result = try js.eval(
        \\function K() { this.initialize.apply(this, arguments); }
        \\K.prototype.initialize = function (a, b) { this.a = a; this.b = b; };
        \\function outer(a, b) { return new K(a, b); }
        \\globalThis.__outer = outer;
        \\var i, o;
        \\for (i = 0; i < 16; i++) o = outer(1, 2);
        \\assert.sameValue(o.a, 1);
        \\assert.sameValue(o.b, 2);
        \\assert.sameValue(outer(7, 8).a, 7);
    );
    try std.testing.expect(result.is(.undefined_value));
    const global = try js.context.globalObject();
    const outer_fn = try global.getProperty(try js.runtime.internAtom("__outer"));
    const outer_obj = zjs.exec.object_ops.plainBytecodeFunctionObjectFromValue(outer_fn).?;
    const outer_fb = outer_obj.bytecodeArm().*.function_bytecode.?;
    const state = zjs.exec.small_inline.callerState(outer_fb);
    try std.testing.expect(state != null);
    try std.testing.expect(state.?.inlined_len >= 1);
    try std.testing.expect(state.?.apply_forward[0].call_pc != std.math.maxInt(u32));
    try std.testing.expect(outer_fb.applyForwardInlined());
}

test "small-function-inlining L1: next-entry take does not leak initialize return" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const result = try js.eval(
        \\function K() { this.initialize.apply(this, arguments); }
        \\K.prototype.initialize = function (a, b) { this.a = a; this.b = b; };
        \\function batch(n) {
        \\  var i, s = 0, p;
        \\  for (i = 0; i < n; i++) { p = new K(1, 2); s = s + p.a; }
        \\  return s;
        \\}
        \\assert.sameValue(batch(16), 16);
        \\assert.sameValue(batch(64), 64);
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "small-function-inlining L1: forwarded argc is the site argc" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const result = try js.eval(
        \\function K() { this.initialize.apply(this, arguments); }
        \\K.prototype.initialize = function () { this.n = arguments.length; };
        \\function outer() { return new K(1, 2, 3); }
        \\var i, o;
        \\for (i = 0; i < 16; i++) o = outer();
        \\assert.sameValue(o.n, 3);
        \\assert.sameValue(outer().n, 3);
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "small-function-inlining L1: Error.stack is initialize, apply native, ctor" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    var output_buffer: [1024]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    _ = try js.evalWithOutput(
        \\function C() { this.initialize.apply(this, arguments); }
        \\C.prototype.initialize = function init(a) { this.a = a; throw new Error("boom"); };
        \\function outer(v) { return new C(v); }
        \\var i;
        \\for (i = 0; i < 16; i++) { try { outer(i); } catch (e) {} }
        \\try { outer(99); } catch (e) {
        \\  var s = String(e.stack);
        \\  var iInit = s.indexOf("init");
        \\  var iApply = s.indexOf("apply (native)");
        \\  var iC = s.indexOf("\n    at C");
        \\  print(iInit >= 0 && iApply > iInit && iC > iApply ? "order" : "bad");
        \\  print(s.indexOf("apply (native)", iApply + 1) == -1 ? "once" : "dup");
        \\}
    , &output);
    try std.testing.expectEqualStrings("order\nonce\n", output.buffered());
}

test "small-function-inlining L1: own apply misses take" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const result = try js.eval(
        \\function C() { this.initialize.apply(this, arguments); }
        \\C.prototype.initialize = function (a) { this.a = a; this.via = "init"; };
        \\function outer(v) { return new C(v); }
        \\var i;
        \\for (i = 0; i < 16; i++) outer(i);
        \\C.prototype.initialize.apply = function (thisArg, args) {
        \\  thisArg.a = args[0];
        \\  thisArg.via = "own";
        \\};
        \\assert.sameValue(outer(99).via, "own");
        \\assert.sameValue(outer(99).a, 99);
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "small-function-inlining L1: replaced Function.prototype.apply misses take" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const result = try js.eval(
        \\function C() { this.initialize.apply(this, arguments); }
        \\C.prototype.initialize = function (a) { this.a = a; };
        \\function outer(v) { return new C(v); }
        \\var i;
        \\for (i = 0; i < 16; i++) outer(i);
        \\var saved = Function.prototype.apply;
        \\var seen = 0;
        \\Function.prototype.apply = function (thisArg, args) {
        \\  seen += 1;
        \\  return saved.call(this, thisArg, args);
        \\};
        \\try {
        \\  assert.sameValue(outer(7).a, 7);
        \\  assert.sameValue(seen, 1);
        \\} finally {
        \\  Function.prototype.apply = saved;
        \\}
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "flat string strict-eq matches content across distinct objects" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const result = try js.eval(
        \\function check(cond) { if (!cond) throw new Error("streq"); }
        \\var lit = "k0";
        \\var made = "k" + 0;
        \\var other = "k32";
        \\var empty_a = "";
        \\var empty_b = "" + "";
        \\check(lit === made);
        \\check(made === "k0");
        \\check(!(lit === other));
        \\check(lit !== other);
        \\check(empty_a === empty_b);
        \\check(!("" === "k0"));
        \\check(("α" + "") === "α");
        \\var acc = 0;
        \\var i = 0;
        \\while (i < 64) {
        \\    if (("k" + i) === "k32") acc = acc + 1;
        \\    i = i + 1;
        \\}
        \\check(acc === 1);
    );
    try std.testing.expect(result.is(.undefined_value));
}

const ActiveInvocationRootProbe = struct {
    allocator: std.mem.Allocator,
    saw_live_local: bool = false,
    unused_capacity_checked: bool = false,
    unused_capacity_leaked: bool = false,

    fn call(ptr: *anyopaque, invocation: core.host_function.ExternalCall) anyerror!core.JSValue {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        const rt = invocation.realm.runtime;
        try std.testing.expect(rt.execution.active_invocation != null);

        const active = inline_calls.activeInvocation(rt) orelse return error.TestUnexpectedResult;
        var seen = std.AutoHashMap(usize, void).init(self.allocator);
        defer seen.deinit();

        const Recorder = struct {
            seen: *std.AutoHashMap(usize, void),

            fn visitValue(context: *anyopaque, slot: *core.JSValue) core.runtime.RootTraceError!void {
                const recorder: *@This() = @ptrCast(@alignCast(context));
                if (slot.cycleMarkHeader()) |header| {
                    const addr = @intFromPtr(header);
                    if (addr < 4096 or addr % @alignOf(core.gc.Header) != 0) return error.OutOfMemory;
                    try recorder.seen.put(addr, {});
                }
            }

            fn visitObject(context: *anyopaque, slot: *?*core.Object) core.runtime.RootTraceError!void {
                const recorder: *@This() = @ptrCast(@alignCast(context));
                const object = slot.* orelse return;
                try recorder.seen.put(@intFromPtr(object.gcHeader()), {});
            }
        };
        var recorder = Recorder{ .seen = &seen };
        var visitor = core.runtime.RootVisitor{
            .readonly = .observe,
            .context = @ptrCast(&recorder),
            .visit_value = Recorder.visitValue,
            .visit_object = Recorder.visitObject,
        };
        try rt.traceActiveRoots(&visitor);

        var live_local: ?*core.gc.Header = null;
        try assertLiveWindowsVisited(active, &seen, &live_local);
        self.saw_live_local = live_local != null;

        const stack = active.machine.currentLevel().stack;
        const unused = stack.backingValues()[stack.len()..];
        if (unused.len != 0) {
            self.unused_capacity_checked = true;
            const orphan = try core.Object.create(rt, core.class.ids.object, null);
            const saved = unused[0];
            unused[0] = orphan.value();
            defer unused[0] = saved;

            seen.clearRetainingCapacity();
            try rt.traceActiveRoots(&visitor);
            if (seen.contains(@intFromPtr(orphan.gcHeader()))) {
                self.unused_capacity_leaked = true;
            }
        }

        // Heap-wide shadow tracing is a post-quiesce observer. A live native
        // callback is not a quiesced heap (in-flight payloads can still hold
        // uninit child slots). Live-window coverage is the visitor lockstep.

        return core.JSValue.boolean(self.saw_live_local and !self.unused_capacity_leaked);
    }
};

fn assertLiveWindowsVisited(
    active: *inline_calls.ActiveInvocation,
    seen: *std.AutoHashMap(usize, void),
    live_local: *?*core.gc.Header,
) !void {
    var current: ?*inline_calls.ActiveInvocation = active;
    while (current) |invocation| {
        try expectFrameVisited(invocation.machine.l0.level.frame, seen, live_local);
        try expectValueVisitedSlice(invocation.machine.l0.level.stack.liveValues(), seen);
        var entry = invocation.machine.top;
        while (entry) |current_entry| {
            try expectFrameVisited(&current_entry.frame, seen, live_local);
            try expectValueVisitedSlice(current_entry.stack.liveValues(), seen);
            if (current_entry.teardown.has_native_caller or current_entry.teardown.constructor_completion) {
                try expectValueVisited(&current_entry.native_caller, seen);
            }
            entry = current_entry.prev;
        }
        current = invocation.previous;
    }
}

fn expectFrameVisited(
    frame: *frame_mod.Frame,
    seen: *std.AutoHashMap(usize, void),
    live_local: *?*core.gc.Header,
) !void {
    try expectValueVisited(&frame.this_value, seen);
    try expectValueVisited(&frame.current_function, seen);
    try expectValueVisitedSlice(frame.args, seen);
    try expectValueVisitedSlice(frame.locals, seen);
    if (live_local.* == null) {
        for (frame.locals) |*local| {
            if (local.cycleMarkHeader()) |header| {
                live_local.* = header;
                break;
            }
        }
    }
    if (frame.cold) |cold| {
        if (frame.ownership.new_target != .aliases_function) {
            try expectValueVisited(&cold.new_target, seen);
        }
        try expectValueVisitedSlice(cold.original_args, seen);
    }
    for (frame.var_refs) |cell| {
        var cell_value = cell.valueRef();
        try expectValueVisited(&cell_value, seen);
    }
    for (frame.open_var_refs) |maybe_cell| {
        const cell = maybe_cell orelse continue;
        var cell_value = cell.valueRef();
        try expectValueVisited(&cell_value, seen);
    }
}

fn expectValueVisitedSlice(values: []core.JSValue, seen: *std.AutoHashMap(usize, void)) !void {
    for (values) |*value| try expectValueVisited(value, seen);
}

fn expectValueVisited(value: *core.JSValue, seen: *std.AutoHashMap(usize, void)) !void {
    const header = value.cycleMarkHeader() orelse return;
    try std.testing.expect(seen.contains(@intFromPtr(header)));
}

test "active invocation Adapter traces live VM windows and not unused stack capacity" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var probe = ActiveInvocationRootProbe{ .allocator = std.testing.allocator };
    try js.defineGlobalExternalHostFunction(
        "activeInvocationProbe",
        0,
        &probe,
        ActiveInvocationRootProbe.call,
        null,
    );

    _ = try js.eval(
        \\function holdHidden() {
        \\    const hidden = { marker: 1 };
        \\    const ok = activeInvocationProbe();
        \\    return [ok, hidden];
        \\}
        \\holdHidden();
    );

    try std.testing.expect(probe.saw_live_local);
    try std.testing.expect(probe.unused_capacity_checked);
    try std.testing.expect(!probe.unused_capacity_leaked);
}

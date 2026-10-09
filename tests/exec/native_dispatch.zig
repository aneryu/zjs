//! Exec integration tests: native_dispatch.
const std = @import("std");
const zjs = @import("zjs");
const engine = zjs;
const core = zjs.core;
const helpers = @import("../harness.zig");
const BareRuntime = @import("../harness/bare_runtime.zig").BareRuntime;
const vm_helpers = helpers.vm_helpers;
const bytecode = zjs.bytecode;
const function_def = zjs.bytecode.function_def;
const op = zjs.bytecode.opcode.op;
const property_ops = zjs.exec.property_ops;
const object_ops = zjs.exec.object_ops;
const frame_mod = zjs.exec.frame;
const inline_calls = zjs.exec.inline_calls;
const common = @import("common.zig");
const getGlobalObject = common.getGlobalObject;
const makeFixture = common.makeFixture;
const runFixture = common.runFixture;
const CrossRealmNativeProbe = common.CrossRealmNativeProbe;
const crossRealmNativeProbe = common.crossRealmNativeProbe;
const derivedThisLocalIndex = common.derivedThisLocalIndex;
const globalFunctionBytecode = common.globalFunctionBytecode;
const finalOpcodeCount = common.finalOpcodeCount;
const testNativeCallback = common.testNativeCallback;

const HostBacktraceErrorProbe = struct {
    fn call(_: *anyopaque, _: core.host_function.ExternalCall) anyerror!core.JSValue {
        return error.TypeError;
    }
};

const NativeRecordStackProbe = struct {
    var callable: core.JSValue = core.JSValue.undefinedValue();
    var calls: usize = 0;
    var recurse: bool = true;

    const record: core.NativeEntry = engine.exec.native_legacy.genericEntry(&call, 0);

    fn call(ctx: *core.JSContext, _: core.JSValue, _: []const core.JSValue) core.errors.HostError!core.JSValue {
        calls += 1;
        if (!recurse or calls >= 256) return core.JSValue.int32(7);
        const global = ctx.global orelse return error.InvalidBuiltinRegistry;
        return engine.exec.call_runtime.callValueOrBytecodeRoot(ctx, null, global, core.JSValue.undefinedValue(), callable, &.{}, null, null);
    }
};

fn localIndexNamed(rt: *core.JSRuntime, function: *const bytecode.FunctionBytecode, name: []const u8) ?usize {
    for (function.varDefs(), 0..) |vd, idx| {
        const bytes = rt.atoms.name(vd.var_name) orelse continue;
        if (std.mem.eql(u8, bytes, name)) return idx;
    }
    return null;
}

const SetVarRefStats = struct {
    count: usize = 0,
    first_idx: ?u16 = null,
};

fn finalSetVarRefStats(code: []const u8) !SetVarRefStats {
    var stats: SetVarRefStats = .{};
    var pc: usize = 0;
    while (pc < code.len) {
        const op_id = code[pc];
        const size = bytecode.opcode.sizeOf(op_id);
        if (size == 0 or pc + size > code.len) return error.InvalidFunctionBytecode;
        const idx: ?u16 = if (op_id == op.set_var_ref)
            std.mem.readInt(u16, code[pc + 1 ..][0..2], .little)
        else if (op_id >= op.set_var_ref0 and op_id <= op.set_var_ref3)
            op_id - op.set_var_ref0
        else
            null;
        if (idx) |ref_idx| {
            stats.count += 1;
            if (stats.first_idx == null) stats.first_idx = ref_idx;
        }
        pc += size;
    }
    return stats;
}

fn expectSingleDerivedThisClosureCapture(function: *const bytecode.FunctionBytecode) !void {
    const this_idx = derivedThisLocalIndex(function) orelse return error.InvalidFunctionBytecode;
    const this_vardef = function.varDefs()[this_idx];
    try std.testing.expect(this_vardef.isCaptured());
    try std.testing.expectEqual(@as(u16, 1), function.openVarRefCount());
    try std.testing.expectEqual(@as(u16, 0), this_vardef.var_ref_idx);
    try std.testing.expectEqual(@as(usize, 0), try finalOpcodeCount(function.byteCode(), op.close_loc));

    var capturing_function: ?*const bytecode.FunctionBytecode = null;
    var capturing_function_count: usize = 0;
    for (function.cpoolSlice()) |constant| {
        const child = engine.exec.call_runtime.functionBytecodeFromValue(constant) orelse continue;
        var captures_derived_this = false;
        for (child.closureVar()) |capture| {
            captures_derived_this = captures_derived_this or
                (capture.var_name == core.atom.ids.this_ and
                    capture.closureType() == .local and
                    capture.var_idx == @as(u16, @intCast(this_idx)));
        }
        if (!captures_derived_this) continue;
        capturing_function = child;
        capturing_function_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), capturing_function_count);

    const closure = capturing_function.?;
    try std.testing.expectEqual(function_def.FunctionKind.normal, closure.functionKind());
    try std.testing.expect(!closure.hasPrototype());

    var this_capture_count: usize = 0;
    for (closure.closureVar()) |capture| {
        if (capture.var_name != core.atom.ids.this_) continue;
        this_capture_count += 1;
        try std.testing.expectEqual(function_def.ClosureType.local, capture.closureType());
        try std.testing.expectEqual(@as(u16, @intCast(this_idx)), capture.var_idx);
    }
    try std.testing.expectEqual(@as(usize, 1), this_capture_count);
}

// ================== core_native.zig ==================

test "a dynamic function outlives its teardown when its object held the last bytecode reference" {
    // Frame teardown reads `frame.function` (the FunctionBytecode) to decide
    // whether open var refs need closing. A dynamic `Function(...)` call is the
    // reachable shape where the frame's function object holds that bytecode's
    // last reference, so releasing it first destroyed what the read needs.
    // A Debug witness in `inline_calls` asserts the ordering; this exercises it.
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    _ = try js.evalWithOutput(
        \\let total = 0;
        \\for (let i = 0; i < 8; i += 1) {
        \\    total += Function("var a = 2; var g = function () { return a; }; return g();")();
        \\}
        \\print(total);
    , &stream);

    try std.testing.expectEqualStrings("16\n", stream.buffered());
}

test "string leftover ToIntegerOrInfinity matches value_ops including bigint TypeError" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    _ = try js.evalWithOutput(
        \\print("ab".repeat(2));
        \\print("hello".slice(1.9, 4));
        \\print("hello".indexOf("l", true));
        \\try { "ab".repeat(1n); print("no throw"); } catch (e) { print(e.name); }
        \\try { String.fromCodePoint(1n); print("from-no"); } catch (e) { print(e.name); }
    , &stream);
    try std.testing.expectEqualStrings("abab\nell\n2\nTypeError\nTypeError\n", stream.buffered());
}

test "vm executes push constants arithmetic comparisons and return" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();

    const function = try makeFixture(rt, ctx, .{ .code = &.{
        op.push_i32, 2,           0,            0, 0,
        op.push_i32, 3,           0,            0, 0,
        op.add,      op.push_i32, 6,            0, 0,
        0,           op.lt,       op.@"return",
    } });
    defer function.release(rt);

    const result = try runFixture(rt, ctx, function.fb);
    try std.testing.expectEqual(true, result.as(.boolean).?);
}

test "Engine executes both paths of a threaded with atom-label destructuring probe" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\function withThread(obj, y) {
        \\  with (obj) { [x] = y; }
        \\  return obj.x;
        \\}
        \\var threadedTotal = withThread({ x: 0, y: [4] }, [9]) * 10 +
        \\  withThread({ x: 0 }, [2]);
        \\assert.sameValue(threadedTotal, 42);
    );

    try std.testing.expect(result.is(.undefined_value));
}

test "signed bigint-i32 neg preserves inline and generic BigInt semantics" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\assert.sameValue(-(0n), 0n);
        \\assert.sameValue(-1n, -1n);
        \\assert.sameValue(-(1n), -1n);
        \\assert.sameValue(-(2147483647n), -2147483647n);
        \\assert.sameValue(-(2147483648n), -2147483648n);
        \\assert.sameValue(-(2147483649n), -2147483649n);
        \\assert.sameValue(1n, 1n);
        \\assert.sameValue(-(1), -1);
        \\assert.sameValue(Object.is(-(0), -0), true);
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "heap bigint multiplication still compacts a short-representable product" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    // Heap representation does not imply a magnitude above the short-BigInt
    // range: the parser only folds literals inside the i32 range while short
    // BigInts cover all of i64, so both operands below are one-limb heap
    // BigInts whose product still fits a short. qjs compacts every
    // multiplication result (JS_CompactBigInt, quickjs.c), so the
    // single-allocation FAM path -- which does not collapse -- must decline
    // this shape. This is the regression guard for that gate: if a future
    // parser or literal-folding change makes the eligibility predicate
    // unsound, the representation silently diverges from qjs, and only a
    // direct check like this one catches it.
    const result = try js.eval(
        \\assert.sameValue(3000000000n * 3000000000n, 9000000000000000000n);
        \\assert.sameValue(String(3000000000n * 3000000000n), "9000000000000000000");
        \\assert.sameValue(typeof (3000000000n * 3000000000n), "bigint");
        \\assert.sameValue((3000000000n * 3000000000n) === 9000000000000000000n, true);
        \\// One limb short of the boundary on either side is still excluded.
        \\assert.sameValue(2147483648n * 2147483648n, 4611686018427387904n);
        \\assert.sameValue(-3000000000n * 3000000000n, -9000000000000000000n);
        \\// Just past it the FAM path takes over and must agree.
        \\assert.sameValue(4000000000n * 4000000000n, 16000000000000000000n);
        \\assert.sameValue(String(4000000000n * 4000000000n), "16000000000000000000");
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "numeric discarded immediates preserve comma control and completion semantics" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\function numericDiscardTail() { (1); }
        \\function numericDiscardComma(value) { return (1, value); }
        \\function numericDiscardControl(flag) { if (flag) (1); return flag ? 2 : 3; }
        \\function numericDiscardUpdate() {
        \\  let count = 0;
        \\  for (; count < 2; (1), count++) {}
        \\  return count;
        \\}
        \\assert.sameValue(numericDiscardTail(), undefined);
        \\assert.sameValue(numericDiscardComma(42), 42);
        \\assert.sameValue(numericDiscardControl(true), 2);
        \\assert.sameValue(numericDiscardControl(false), 3);
        \\assert.sameValue(numericDiscardUpdate(), 2);
        \\assert.sameValue(void 0, undefined);
        \\assert.sameValue(eval("1"), 1);
        \\assert.sameValue(eval("-1"), -1);
        \\assert.sameValue(Object.is(eval("-0"), -0), true);
        \\assert.sameValue(eval("+1"), 1);
        \\assert.sameValue(eval("-2147483648"), -2147483648);
    );
    try std.testing.expect(result.is(.undefined_value));

    const repl = try js.evalWithOptions("1", .{ .filename = "<repl>" });
    try std.testing.expectEqual(@as(?i32, 1), repl.as(.int));

    const module = try js.evalModule("1; export const numericDiscardModule = 1;");
    try std.testing.expect(module.is(.undefined_value));
}

test "vm executes stack constants source locations and return_undef" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();

    const function = try makeFixture(rt, ctx, .{ .code = &.{
        op.undefined, op.null, op.push_true, op.push_false, op.drop, op.return_undef,
    } });
    defer function.release(rt);

    const result = try runFixture(rt, ctx, function.fb);
    try std.testing.expect(result.is(.undefined_value));
    try std.testing.expect(result.is(.undefined_value));
}

test "frame setLocal handles self-assignment without dropping object" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const execution_function = try bytecode.FunctionBytecode.createFixture(rt, .{});
    defer execution_function.destroyUnpublishedFixture(rt);
    var frame = frame_mod.Frame.init(execution_function);
    defer frame.deinit(rt.nativeAllocator(), rt);

    const object = try core.Object.create(rt, core.class.ids.object, null);
    try frame.setLocal(rt.nativeAllocator(), 0, object.value());

    const current = frame.locals[0];
    try frame.setLocal(rt.nativeAllocator(), 0, current);

    try std.testing.expectEqual(object.gcHeader(), frame.locals[0].refHeader().?);
}

test "derived constructor without nested this references has no owner cell" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    _ = try js.eval(
        \\globalThis.__derivedNoCapture = class DerivedNoCapture extends Object {
        \\  constructor() { super(); }
        \\};
        \\new globalThis.__derivedNoCapture();
    );

    const constructor = try globalFunctionBytecode(&js, "__derivedNoCapture");
    try std.testing.expect(constructor.isDerivedClassConstructor());
    try std.testing.expectEqual(@as(u16, 0), constructor.openVarRefCount());
    const this_idx = derivedThisLocalIndex(constructor) orelse return error.InvalidFunctionBytecode;
    try std.testing.expect(!constructor.varDefs()[this_idx].isCaptured());
    try std.testing.expectEqual(@as(usize, 0), try finalOpcodeCount(constructor.byteCode(), op.close_loc));
}

test "derived constructor arrow creates exactly one owner this cell" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    _ = try js.eval(
        \\globalThis.__derivedArrowCapture = class DerivedArrowCapture extends Object {
        \\  constructor() { const read = () => this; super(); if (read() !== this) throw new Error("this mismatch"); }
        \\};
        \\new globalThis.__derivedArrowCapture();
    );

    try expectSingleDerivedThisClosureCapture(try globalFunctionBytecode(&js, "__derivedArrowCapture"));
}

test "derived constructor parameter default arrow captures this by binding identity" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    _ = try js.eval(
        \\globalThis.__derivedParameterArrow = class DerivedParameterArrow extends Object {
        \\  constructor({ read = () => this } = {}) { super(); if (read() !== this) throw new Error("this mismatch"); }
        \\};
        \\new globalThis.__derivedParameterArrow();
    );

    try expectSingleDerivedThisClosureCapture(try globalFunctionBytecode(&js, "__derivedParameterArrow"));
}

test "direct eval captures derived this while indirect eval does not" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    _ = try js.eval(
        \\globalThis.__derivedDirectEval = class DerivedDirectEval extends Object {
        \\  constructor() { super(); if (eval("this") !== this) throw new Error("this mismatch"); }
        \\};
        \\globalThis.__derivedIndirectEval = class DerivedIndirectEval extends Object {
        \\  constructor() { (0, eval)("this"); super(); }
        \\};
        \\new globalThis.__derivedDirectEval();
        \\new globalThis.__derivedIndirectEval();
    );

    const direct = try globalFunctionBytecode(&js, "__derivedDirectEval");
    const direct_this_idx = derivedThisLocalIndex(direct) orelse return error.InvalidFunctionBytecode;
    const direct_this = direct.varDefs()[direct_this_idx];
    try std.testing.expect(direct_this.isCaptured());
    try std.testing.expect(direct_this.var_ref_idx < direct.openVarRefCount());
    try std.testing.expectEqual(@as(usize, 0), try finalOpcodeCount(direct.byteCode(), op.close_loc));

    const indirect = try globalFunctionBytecode(&js, "__derivedIndirectEval");
    const indirect_this_idx = derivedThisLocalIndex(indirect) orelse return error.InvalidFunctionBytecode;
    try std.testing.expect(!indirect.varDefs()[indirect_this_idx].isCaptured());
    try std.testing.expectEqual(@as(u16, 0), indirect.openVarRefCount());
    try std.testing.expectEqual(@as(usize, 0), try finalOpcodeCount(indirect.byteCode(), op.close_loc));
}

test "class entry and construction use bytecode gates without a class behavior flag" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.eval(
        \\let ordinaryNewTarget = null;
        \\function Ordinary(value) {
        \\  ordinaryNewTarget = new.target;
        \\  this.value = value;
        \\  return 7;
        \\}
        \\const receiver = {};
        \\assert.sameValue(Ordinary.call(receiver, 1), 7);
        \\assert.sameValue(receiver.value, 1);
        \\assert.sameValue(ordinaryNewTarget, undefined);
        \\
        \\let baseNewTarget;
        \\let derivedNewTarget;
        \\class Base {
        \\  constructor(value) {
        \\    baseNewTarget = new.target;
        \\    this.value = value;
        \\    return 7;
        \\  }
        \\}
        \\class Derived extends Base {
        \\  constructor(value) {
        \\    derivedNewTarget = new.target;
        \\    super(value);
        \\  }
        \\}
        \\assert.throws(TypeError, function () { Base(2); });
        \\assert.throws(TypeError, function () { Derived(2); });
        \\
        \\function Replacement() {}
        \\const ordinary = Reflect.construct(Ordinary, [3], Replacement);
        \\assert.sameValue(ordinaryNewTarget, Replacement);
        \\assert.sameValue(ordinary.value, 3);
        \\assert.sameValue(Object.getPrototypeOf(ordinary), Replacement.prototype);
        \\
        \\const base = Reflect.construct(Base, [4], Replacement);
        \\assert.sameValue(baseNewTarget, Replacement);
        \\assert.sameValue(base.value, 4);
        \\assert.sameValue(Object.getPrototypeOf(base), Replacement.prototype);
        \\
        \\const derived = Reflect.construct(Derived, [5], Replacement);
        \\assert.sameValue(derivedNewTarget, Replacement);
        \\assert.sameValue(baseNewTarget, Replacement);
        \\assert.sameValue(derived.value, 5);
        \\assert.sameValue(Object.getPrototypeOf(derived), Replacement.prototype);
        \\
        \\const key = "ComputedClass";
        \\let computedNewTarget;
        \\const holder = {
        \\  [key]: class {
        \\    constructor() { computedNewTarget = new.target; }
        \\  },
        \\};
        \\assert.sameValue(holder[key].name, key);
        \\assert.throws(TypeError, function () { holder[key](); });
        \\const computed = Reflect.construct(holder[key], [], Replacement);
        \\assert.sameValue(computedNewTarget, Replacement);
        \\assert.sameValue(Object.getPrototypeOf(computed), Replacement.prototype);
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "ordinary constructor Machine completion preserves bindings eval recursion and abrupt teardown" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const baseline_call_depth = js.runtime.stack.call_depth;
    const baseline_stack_bytes = js.runtime.stack.bytecode_bytes;
    const baseline_arena_mark = js.runtime.vm_stack.mark();
    const result = try js.eval(
        \\let observed;
        \\let evalThis;
        \\let evalNewTarget;
        \\function Ordinary(value, mode) {
        \\  const arrow = () => [this, new.target, arguments[0]];
        \\  observed = arrow();
        \\  eval("evalThis = this; evalNewTarget = new.target");
        \\  this.value = value;
        \\  if (mode === "object") return { replacement: value + 1 };
        \\  if (mode === "throw") throw value;
        \\  return 17;
        \\}
        \\const primitive = new Ordinary(3, "primitive");
        \\assert.sameValue(primitive.value, 3);
        \\assert.sameValue(observed[0], primitive);
        \\assert.sameValue(observed[1], Ordinary);
        \\assert.sameValue(observed[2], 3);
        \\assert.sameValue(evalThis, primitive);
        \\assert.sameValue(evalNewTarget, Ordinary);
        \\const replacement = new Ordinary(4, "object");
        \\assert.sameValue(replacement.replacement, 5);
        \\assert.sameValue(replacement.value, undefined);
        \\let caught;
        \\try { new Ordinary(6, "throw"); } catch (error) { caught = error; }
        \\assert.sameValue(caught, 6);
        \\
        \\function Recursive(depth) {
        \\  this.depth = depth;
        \\  if (depth !== 0) this.child = new Recursive(depth - 1);
        \\}
        \\const recursive = new Recursive(32);
        \\let count = 0;
        \\for (let cursor = recursive; cursor; cursor = cursor.child) count++;
        \\assert.sameValue(count, 33);
        \\
        \\function EvalTail(value) {
        \\  eval("this.value = value");
        \\}
        \\const evalTail = new EvalTail(9);
        \\assert.sameValue(evalTail.value, 9);
        \\
        \\function GcConstructor(value) {
        \\  this.value = value;
        \\  $262.gc();
        \\  return null;
        \\}
        \\const gcValue = new GcConstructor(11);
        \\assert.sameValue(gcValue.value, 11);
    );
    try std.testing.expect(result.is(.undefined_value));
    try std.testing.expectEqual(baseline_call_depth, js.runtime.stack.call_depth);
    try std.testing.expectEqual(baseline_stack_bytes, js.runtime.stack.bytecode_bytes);
    try std.testing.expectEqual(baseline_arena_mark, js.runtime.vm_stack.mark());
}

test "derived constructor Machine completion preserves inherited new target and teardown" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const baseline_call_depth = js.runtime.stack.call_depth;
    const baseline_stack_bytes = js.runtime.stack.bytecode_bytes;
    const baseline_arena_mark = js.runtime.vm_stack.mark();
    const result = try js.eval(
        \\let baseNewTarget;
        \\function OrdinaryBase(value) { this.value = value; }
        \\class Base {
        \\  constructor(value, mode) {
        \\    baseNewTarget = new.target;
        \\    this.value = value;
        \\    if (mode === "object") return { replacement: value + 1 };
        \\    if (mode === "throw") throw value;
        \\  }
        \\}
        \\class Derived extends Base {
        \\  constructor(value, mode) {
        \\    super(value, mode);
        \\    this.derived = true;
        \\  }
        \\}
        \\class FromOrdinary extends OrdinaryBase {
        \\  constructor(value) { super(value); }
        \\}
        \\
        \\const direct = new Derived(3);
        \\assert.sameValue(direct.value, 3);
        \\assert.sameValue(direct.derived, true);
        \\assert.sameValue(baseNewTarget, Derived);
        \\assert.sameValue(Object.getPrototypeOf(direct), Derived.prototype);
        \\const fromOrdinary = new FromOrdinary(5);
        \\assert.sameValue(fromOrdinary.value, 5);
        \\assert.sameValue(Object.getPrototypeOf(fromOrdinary), FromOrdinary.prototype);
        \\
        \\function Replacement() {}
        \\Replacement.prototype = { marker: 7 };
        \\const reflected = Reflect.construct(Derived, [11], Replacement);
        \\assert.sameValue(reflected.value, 11);
        \\assert.sameValue(reflected.derived, true);
        \\assert.sameValue(baseNewTarget, Replacement);
        \\assert.sameValue(Object.getPrototypeOf(reflected), Replacement.prototype);
        \\const reflectedOrdinary = Reflect.construct(FromOrdinary, [13], Replacement);
        \\assert.sameValue(reflectedOrdinary.value, 13);
        \\assert.sameValue(Object.getPrototypeOf(reflectedOrdinary), Replacement.prototype);
        \\
        \\const replacement = new Derived(17, "object");
        \\assert.sameValue(replacement.replacement, 18);
        \\assert.sameValue(replacement.derived, true);
        \\let caught;
        \\try { new Derived(19, "throw"); } catch (error) { caught = error; }
        \\assert.sameValue(caught, 19);
        \\
        \\class ReturnsObject extends Base {
        \\  constructor() { return { selected: 23 }; }
        \\}
        \\class ReturnsPrimitive extends Base {
        \\  constructor() { return 29; }
        \\}
        \\assert.sameValue(new ReturnsObject().selected, 23);
        \\assert.throws(TypeError, function () { new ReturnsPrimitive(); });
        \\
        \\class Recursive extends Base {
        \\  constructor(depth) {
        \\    super(depth);
        \\    if (depth !== 0) this.child = new Recursive(depth - 1);
        \\  }
        \\}
        \\const recursive = new Recursive(24);
        \\let count = 0;
        \\for (let cursor = recursive; cursor; cursor = cursor.child) count++;
        \\assert.sameValue(count, 25);
        \\$262.gc();
    );
    try std.testing.expect(result.is(.undefined_value));
    try std.testing.expectEqual(baseline_call_depth, js.runtime.stack.call_depth);
    try std.testing.expectEqual(baseline_stack_bytes, js.runtime.stack.bytecode_bytes);
    try std.testing.expectEqual(baseline_arena_mark, js.runtime.vm_stack.mark());
}

test "Reflect.construct keeps a fresh prototype getter result alive through instance allocation" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.eval(
        \\let prototypeGets = 0;
        \\let receiverIsNewTarget = true;
        \\function Target() {}
        \\let NewTarget;
        \\NewTarget = new Proxy(function () {}, {
        \\  get(target, key, receiver) {
        \\    if (key === "prototype") {
        \\      receiverIsNewTarget = receiverIsNewTarget && receiver === NewTarget;
        \\      return { marker: ++prototypeGets };
        \\    }
        \\    return Reflect.get(target, key, receiver);
        \\  },
        \\});
        \\for (let expected = 1; expected <= 256; expected++) {
        \\  const instance = Reflect.construct(Target, [], NewTarget);
        \\  if ((expected & 15) === 0) $262.gc();
        \\  assert.sameValue(Object.getPrototypeOf(instance).marker, expected);
        \\}
        \\assert.sameValue(prototypeGets, 256);
        \\assert.sameValue(receiverIsNewTarget, true);
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "Proxy wrapping a class named Array never enters the native Array construct record" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.eval(
        \\let caught;
        \\try {
        \\  new (new Proxy(class Array {
        \\    constructor() { throw 1; }
        \\  }, {}))();
        \\} catch (error) {
        \\  caught = error;
        \\}
        \\assert.sameValue(caught, 1);
        \\
        \\const ProxyArray = new Proxy(Array, {});
        \\class DerivedArray extends ProxyArray {}
        \\const array = new DerivedArray(1, 2);
        \\assert.sameValue(Array.isArray(array), true);
        \\assert.sameValue(array instanceof DerivedArray, true);
        \\assert.sameValue(Object.getPrototypeOf(array), DerivedArray.prototype);
        \\assert.sameValue(array.length, 2);
        \\assert.sameValue(array[0], 1);
        \\assert.sameValue(array[1], 2);
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "Proxy native constructor forwarding resolves new target prototype before coercion" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.eval(
        \\let order = 0;
        \\let prototypeGets = 0;
        \\let forwardedPrototype;
        \\const ErrorProxy = new Proxy(Error, {
        \\  get(target, key, receiver) {
        \\    assert.sameValue(key, "prototype");
        \\    assert.sameValue(receiver, ErrorProxy);
        \\    assert.sameValue(order++, 0);
        \\    prototypeGets++;
        \\    forwardedPrototype = Reflect.get(target, key, receiver);
        \\    return forwardedPrototype;
        \\  },
        \\});
        \\const message = {
        \\  toString() {
        \\    assert.sameValue(order++, 1);
        \\    return "message";
        \\  },
        \\};
        \\const error = new ErrorProxy(message);
        \\assert.sameValue(order, 2);
        \\assert.sameValue(prototypeGets, 1);
        \\assert.sameValue(Object.getPrototypeOf(error), forwardedPrototype);
        \\assert.sameValue(error.message, "message");
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "default derived constructor follows the live constructor prototype" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.eval(
        \\let oldBaseCalls = 0;
        \\let seenNewTarget;
        \\class OldBase {
        \\  constructor() {
        \\    oldBaseCalls++;
        \\    this.kind = "old";
        \\  }
        \\}
        \\class NewBase {
        \\  constructor() {
        \\    seenNewTarget = new.target;
        \\    this.kind = "new";
        \\  }
        \\}
        \\class DefaultDerived extends OldBase {}
        \\Object.setPrototypeOf(DefaultDerived, NewBase);
        \\const derived = new DefaultDerived();
        \\assert.sameValue(oldBaseCalls, 0);
        \\assert.sameValue(seenNewTarget, DefaultDerived);
        \\assert.sameValue(derived.kind, "new");
        \\assert.sameValue(Object.getPrototypeOf(derived), DefaultDerived.prototype);
        \\
        \\Object.setPrototypeOf(DefaultDerived, null);
        \\let nullSuperError;
        \\try { new DefaultDerived(); } catch (error) { nullSuperError = error; }
        \\assert.sameValue(nullSuperError.constructor, TypeError);
        \\assert.sameValue(nullSuperError.message, "not a function");
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "class constructor opcode errors preserve QuickJS messages and realms" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.eval(
        \\const other = $262.createRealm().global;
        \\other.eval("globalThis.ForeignBase = class ForeignBase {}; globalThis.ForeignDerived = class ForeignDerived extends ForeignBase {}; globalThis.ForeignBadReturn = class ForeignBadReturn extends Object { constructor() { return 1; } }; globalThis.ForeignNoSuper = class ForeignNoSuper extends Object { constructor() { return undefined; } }; globalThis.ForeignCaughtThis = class ForeignCaughtThis extends Object { constructor() { try { this; } catch (error) { globalThis.directThisError = error; } try { (() => this)(); } catch (error) { globalThis.capturedThisError = error; } return {}; } };");
        \\function capture(thunk) {
        \\  try { thunk(); } catch (error) { return error; }
        \\  throw new Error("expected constructor TypeError");
        \\}
        \\
        \\const baseCallError = capture(function () { other.ForeignBase(); });
        \\assert.sameValue(baseCallError.constructor, other.TypeError);
        \\assert.sameValue(baseCallError.message, "class constructors must be invoked with 'new'");
        \\
        \\const derivedCallError = capture(function () { other.ForeignDerived(); });
        \\assert.sameValue(derivedCallError.constructor, other.TypeError);
        \\assert.sameValue(derivedCallError.message, "class constructors must be invoked with 'new'");
        \\
        \\const returnError = capture(function () { new other.ForeignBadReturn(); });
        \\assert.sameValue(returnError.constructor, TypeError);
        \\assert.sameValue(returnError.message, "derived class constructor must return an object or undefined");
        \\
        \\const noSuperError = capture(function () { new other.ForeignNoSuper(); });
        \\assert.sameValue(noSuperError.constructor, ReferenceError);
        \\assert.sameValue(noSuperError.message, "this is not initialized");
        \\
        \\new other.ForeignCaughtThis();
        \\assert.sameValue(other.directThisError.constructor, other.ReferenceError);
        \\assert.sameValue(other.directThisError.message, "this is not initialized");
        \\assert.sameValue(other.capturedThisError.constructor, other.ReferenceError);
        \\assert.sameValue(other.capturedThisError.message, "this is not initialized");
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "direct spread and arrow super follow the live derived constructor prototype" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    _ = try js.eval(
        \\let directNewTarget;
        \\let spreadNewTarget;
        \\let arrowDirectNewTarget;
        \\let arrowSpreadNewTarget;
        \\class OldBase {}
        \\class NewBase {
        \\  constructor(kind) {
        \\    if (kind === "direct") directNewTarget = new.target;
        \\    else if (kind === "spread") spreadNewTarget = new.target;
        \\    else if (kind === "arrow-direct") arrowDirectNewTarget = new.target;
        \\    else arrowSpreadNewTarget = new.target;
        \\  }
        \\}
        \\class DirectDerived extends OldBase {
        \\  constructor() { super("direct"); }
        \\}
        \\class SpreadDerived extends OldBase {
        \\  constructor() { super(...["spread"]); }
        \\}
        \\class ArrowDirectDerived extends OldBase {
        \\  constructor() { (() => super("arrow-direct"))(); }
        \\}
        \\class ArrowSpreadDerived extends OldBase {
        \\  constructor() { (() => super(...["arrow-spread"]))(); }
        \\}
        \\Object.setPrototypeOf(DirectDerived, NewBase);
        \\Object.setPrototypeOf(SpreadDerived, NewBase);
        \\Object.setPrototypeOf(ArrowDirectDerived, NewBase);
        \\Object.setPrototypeOf(ArrowSpreadDerived, NewBase);
        \\const direct = new DirectDerived();
        \\const spread = new SpreadDerived();
        \\const arrowDirect = new ArrowDirectDerived();
        \\const arrowSpread = new ArrowSpreadDerived();
        \\assert.sameValue(directNewTarget, DirectDerived);
        \\assert.sameValue(spreadNewTarget, SpreadDerived);
        \\assert.sameValue(arrowDirectNewTarget, ArrowDirectDerived);
        \\assert.sameValue(arrowSpreadNewTarget, ArrowSpreadDerived);
        \\assert.sameValue(Object.getPrototypeOf(direct), DirectDerived.prototype);
        \\assert.sameValue(Object.getPrototypeOf(spread), SpreadDerived.prototype);
        \\assert.sameValue(Object.getPrototypeOf(arrowDirect), ArrowDirectDerived.prototype);
        \\assert.sameValue(Object.getPrototypeOf(arrowSpread), ArrowSpreadDerived.prototype);
    );
}

test "super call paths reject null live parents and do not authorize ordinary class calls" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    _ = try js.eval(
        \\function capture(thunk) {
        \\  try { thunk(); } catch (error) { return error; }
        \\  throw new Error("expected constructor error");
        \\}
        \\function expectNotFunction(thunk) {
        \\  const error = capture(thunk);
        \\  assert.sameValue(error.constructor, TypeError);
        \\  assert.sameValue(error.message, "not a function");
        \\}
        \\function expectClassCallError(error) {
        \\  assert.sameValue(error.constructor, TypeError);
        \\  assert.sameValue(error.message, "class constructors must be invoked with 'new'");
        \\}
        \\class Base {}
        \\
        \\class ExternalDirect extends Base {
        \\  constructor() { super(); }
        \\}
        \\class ExternalSpread extends Base {
        \\  constructor() { super(...[]); }
        \\}
        \\class ExternalArrow extends Base {
        \\  constructor() { (() => super("direct"))(); }
        \\}
        \\Object.setPrototypeOf(ExternalDirect, null);
        \\Object.setPrototypeOf(ExternalSpread, null);
        \\Object.setPrototypeOf(ExternalArrow, null);
        \\expectNotFunction(() => new ExternalDirect());
        \\expectNotFunction(() => new ExternalSpread());
        \\expectNotFunction(() => new ExternalArrow());
        \\
        \\class InternalDirect extends Base {
        \\  constructor() {
        \\    Object.setPrototypeOf(InternalDirect, null);
        \\    super();
        \\  }
        \\}
        \\class InternalSpread extends Base {
        \\  constructor() {
        \\    Object.setPrototypeOf(InternalSpread, null);
        \\    super(...[]);
        \\  }
        \\}
        \\class InternalArrow extends Base {
        \\  constructor() {
        \\    Object.setPrototypeOf(InternalArrow, null);
        \\    (() => super())();
        \\  }
        \\}
        \\expectNotFunction(() => new InternalDirect());
        \\expectNotFunction(() => new InternalSpread());
        \\expectNotFunction(() => new InternalArrow());
        \\
        \\class OrdinaryDirect extends Base {
        \\  constructor() {
        \\    const parent = Object.getPrototypeOf(OrdinaryDirect);
        \\    expectClassCallError(capture(() => parent()));
        \\    super();
        \\  }
        \\}
        \\class OrdinarySpread extends Base {
        \\  constructor() {
        \\    const parent = Object.getPrototypeOf(OrdinarySpread);
        \\    expectClassCallError(capture(() => parent(...[])));
        \\    super(...[]);
        \\  }
        \\}
        \\assert.sameValue(new OrdinaryDirect() instanceof OrdinaryDirect, true);
        \\assert.sameValue(new OrdinarySpread() instanceof OrdinarySpread, true);
    );
}

test "retired c_closure class is not a live callable" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();

    const leftover = (try core.Object.create(rt, core.class.ids.c_closure, null)).value();
    try std.testing.expect(engine.exec.call.expectCallableObject(leftover) == null);
    try std.testing.expect(!engine.exec.call_runtime.isCallableValue(leftover));
    try std.testing.expect(!core.class.isFunctionClass(core.class.ids.c_closure));
    try std.testing.expect(!engine.exec.call_runtime.isCallableValue(leftover));
    try std.testing.expect(!engine.exec.call_runtime.isConstructorLike(leftover));
    try std.testing.expect(!engine.exec.value_ops.isFunctionObject(leftover));

    const global = try engine.exec.zjs_vm.contextGlobal(ctx);
    try std.testing.expectError(
        error.TypeError,
        engine.exec.call_runtime.callValueOrBytecodeRoot(ctx, null, global, core.JSValue.undefinedValue(), leftover, &.{}, null, null),
    );
}

test "four-class function-like predicates exclude retired c_closure" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const class_ids = [_]core.ClassId{
        core.class.ids.bytecode_function,
        core.class.ids.generator_function,
        core.class.ids.async_function,
        core.class.ids.async_generator_function,
    };
    for (class_ids) |class_id| {
        const function_object = try core.Object.create(rt, class_id, null);
        const function_value = function_object.value();
        try std.testing.expect(engine.exec.call.expectCallableObject(function_value) != null);
        try std.testing.expect(engine.exec.call_runtime.isCallableValue(function_value));
        try std.testing.expect(core.class.isFunctionClass(class_id));
        try std.testing.expect(engine.exec.value_ops.isFunctionObject(function_value));
    }

    try std.testing.expect(!core.class.isFunctionClass(core.class.ids.c_closure));
    try std.testing.expect(!core.class.isFunctionClass(core.class.ids.object));
}

test "bound function call skips zero-length combined args allocation" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();

    const global = try engine.exec.zjs_vm.contextGlobal(ctx);

    const target = try testNativeCallback(ctx, "returnsUndefined", nativeReturnsUndefined);
    const bound = try core.Object.create(rt, core.class.ids.bound_function, null);
    bound.boundTargetSlot().* = target;
    bound.boundThisSlot().* = core.JSValue.undefinedValue();

    // Exclude bootstrap garbage from the allocation-free call baseline. A
    // stress safepoint may collect it during the call even without allocating.
    var rooted_bound = bound.value();
    var root_values = [_]*core.JSValue{&rooted_bound};
    var root_frame = core.runtime.ValueRootFrame{ .values = &root_values };
    root_frame.activate(rt);
    defer root_frame.deactivate(rt);
    _ = try rt.forceGC(null);

    const base_bytes = rt.allocation_diagnostics.allocated_bytes;
    const base_allocations = rt.allocation_diagnostics.allocation_count;

    const result = try engine.exec.call_runtime.callValueOrBytecodeRoot(ctx, null, global, core.JSValue.undefinedValue(), bound.value(), &.{}, null, null);
    try std.testing.expect(result.is(.undefined_value));
    try std.testing.expectEqual(base_bytes, rt.allocation_diagnostics.allocated_bytes);
    try std.testing.expectEqual(base_allocations, rt.allocation_diagnostics.allocation_count);
}

test "constant pool execution retains returned constants" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();

    const str = try core.string.String.createAscii(rt, "hello");
    const value = str.value();
    const function = try makeFixture(rt, ctx, .{
        .name = "const-return",
        .code = &.{ op.push_const, 0, 0, 0, 0, op.@"return" },
        .cpool = &.{value},
    });
    defer function.release(rt);

    const result = try runFixture(rt, ctx, function.fb);
    try std.testing.expect(result.isString());
}

test "property ops use shared object semantics" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const obj = try core.Object.create(rt, core.class.ids.object, null);
    const key = try rt.internAtom("x");

    try engine.exec.property_ops.defineDataProperty(rt, obj, key, core.JSValue.int32(9));
    try obj.setProperty(rt, key, core.JSValue.int32(10));
    const value = try obj.getProperty(key);
    try std.testing.expectEqual(@as(?i32, 10), value.as(.int));

    const direct_value = try engine.exec.property_ops.getPropertyValue(obj.value(), key);
    try std.testing.expectEqual(@as(?i32, 10), direct_value.as(.int));

    const key_string_obj = try core.string.String.createUtf8(rt, "x");
    const key_string = key_string_obj.value();
    const in_result = try engine.exec.property_ops.propertyIn(rt, obj.value(), key_string);
    try std.testing.expectEqual(true, in_result.as(.boolean).?);

    const null_receiver = core.JSValue.nullValue();
    const optional_result = if (null_receiver.is(.null_value) or null_receiver.is(.undefined_value))
        core.JSValue.undefinedValue()
    else
        try engine.exec.property_ops.getPropertyValue(null_receiver, key);
    try std.testing.expect(optional_result.is(.undefined_value));

    try std.testing.expect(try obj.deleteProperty(rt, key));
}

test "value ops own primitive VM semantics" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();

    const sum = try engine.exec.value_ops.binary(rt, op.add, core.JSValue.int32(2), core.JSValue.int32(3));
    try std.testing.expectEqual(@as(?i32, 5), sum.as(.int));

    const suffix_obj = try core.string.String.createUtf8(rt, "px");
    const suffix = suffix_obj.value();
    const joined = try engine.exec.value_ops.binary(rt, op.add, core.JSValue.int32(2), suffix);

    var joined_text = std.ArrayList(u8).empty;
    defer joined_text.deinit(rt.nativeAllocator());
    try engine.exec.value_ops.appendRawString(rt, &joined_text, joined);
    try std.testing.expectEqualStrings("2px", joined_text.items);

    const int_string = try engine.exec.value_ops.toStringValue(rt, core.JSValue.int32(7));
    var int_string_text = std.ArrayList(u8).empty;
    defer int_string_text.deinit(rt.nativeAllocator());
    try engine.exec.value_ops.appendRawString(rt, &int_string_text, int_string);
    try std.testing.expectEqualStrings("7", int_string_text.items);

    const empty_obj = try core.string.String.createUtf8(rt, "");
    const empty = empty_obj.value();

    const empty_suffix = try engine.exec.value_ops.binary(rt, op.add, empty, core.JSValue.int32(7));
    var empty_suffix_text = std.ArrayList(u8).empty;
    defer empty_suffix_text.deinit(rt.nativeAllocator());
    try engine.exec.value_ops.appendRawString(rt, &empty_suffix_text, empty_suffix);
    try std.testing.expectEqualStrings("7", empty_suffix_text.items);

    const empty_prefix = try engine.exec.value_ops.binary(rt, op.add, core.JSValue.int32(7), empty);
    var empty_prefix_text = std.ArrayList(u8).empty;
    defer empty_prefix_text.deinit(rt.nativeAllocator());
    try engine.exec.value_ops.appendRawString(rt, &empty_prefix_text, empty_prefix);
    try std.testing.expectEqualStrings("7", empty_prefix_text.items);

    const one_obj = try core.string.String.createUtf8(rt, "1");
    const one_string = one_obj.value();

    const same_string = try engine.exec.value_ops.toStringValue(rt, one_string);
    try std.testing.expect(same_string.same(one_string));

    const boxed_one = try engine.exec.string_builtin_ops.constructWithPrototype(rt, &.{one_string}, null);
    const boxed_one_object = core.Object.fromHeader(boxed_one.refHeader().?);
    const boxed_one_data = boxed_one_object.objectData() orelse return error.TypeError;
    try std.testing.expect(boxed_one_data.same(one_string));

    const symbol_atom = try rt.atoms.newSymbol("boxed", .symbol);
    try std.testing.expectError(error.SymbolToString, engine.exec.string_builtin_ops.constructWithPrototype(rt, &.{try rt.symbolValue(symbol_atom)}, null));

    const function = try makeFixture(rt, ctx, .{
        .name = "loose-eq",
        .code = &.{
            op.push_i32,   1,            0, 0, 0,
            op.push_const, 0,            0, 0, 0,
            op.eq,         op.@"return",
        },
        .cpool = &.{one_string},
    });
    defer function.release(rt);
    const eq_result = try runFixture(rt, ctx, function.fb);
    try std.testing.expectEqual(true, eq_result.as(.boolean).?);

    try std.testing.expect(!engine.exec.value_ops.isTruthy(core.JSValue.int32(0)));
}

test "resident set_var_ref preserves assignment results and refcounted self-assignment" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.eval(
        \\function __buildResidentSetVarRefProbes() {
        \\  var shortTarget = 0;
        \\  globalThis.__residentSetVarRefShort = function (next) {
        \\    return shortTarget = next;
        \\  };
        \\  globalThis.__residentSetVarRefSelf = function () {
        \\    return shortTarget = shortTarget;
        \\  };
        \\
        \\  var capture0 = 0;
        \\  var capture1 = 1;
        \\  var capture2 = 2;
        \\  var capture3 = 3;
        \\  var genericTarget = 4;
        \\  globalThis.__residentSetVarRefGeneric = function (next) {
        \\    if (capture0 + capture1 + capture2 + capture3 !== 6) throw new Error("capture mismatch");
        \\    return genericTarget = next;
        \\  };
        \\}
        \\__buildResidentSetVarRefProbes();
        \\
        \\assert.sameValue(__residentSetVarRefShort(42), 42);
        \\const shortObject = { marker: 1 };
        \\assert.sameValue(__residentSetVarRefShort(shortObject), shortObject);
        \\assert.sameValue(__residentSetVarRefSelf(), shortObject);
        \\assert.sameValue(__residentSetVarRefSelf().marker, 1);
        \\
        \\const genericObject = { marker: 2 };
        \\assert.sameValue(__residentSetVarRefGeneric(genericObject), genericObject);
        \\assert.sameValue(__residentSetVarRefGeneric(43), 43);
    );
    try std.testing.expect(result.is(.undefined_value));

    const short = try globalFunctionBytecode(&js, "__residentSetVarRefShort");
    const short_set = try finalSetVarRefStats(short.byteCode());
    try std.testing.expectEqual(@as(usize, 1), short_set.count);
    try std.testing.expectEqual(@as(?u16, 0), short_set.first_idx);

    const self_assign = try globalFunctionBytecode(&js, "__residentSetVarRefSelf");
    const self_set = try finalSetVarRefStats(self_assign.byteCode());
    try std.testing.expectEqual(@as(usize, 1), self_set.count);
    try std.testing.expectEqual(@as(?u16, 0), self_set.first_idx);

    const generic = try globalFunctionBytecode(&js, "__residentSetVarRefGeneric");
    var generic_set_idx: ?u16 = null;
    var pc: usize = 0;
    while (pc < generic.byteCode().len) {
        const opcode_id = generic.byteCode()[pc];
        const size = bytecode.opcode.sizeOf(opcode_id);
        if (size == 0 or pc + size > generic.byteCode().len) return error.InvalidFunctionBytecode;
        if (opcode_id == op.set_var_ref) {
            generic_set_idx = std.mem.readInt(u16, generic.byteCode()[pc + 1 ..][0..2], .little);
            break;
        }
        pc += size;
    }
    try std.testing.expect(generic_set_idx != null);
    try std.testing.expect(generic_set_idx.? >= 4);
}

test "resident stack permutations preserve assignment values and ownership" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.eval(
        \\globalThis.__residentInsert2 = function (object, value) {
        \\  return object.field = value;
        \\};
        \\globalThis.__residentInsert3 = function (object, key, value) {
        \\  return object[key] = value;
        \\};
        \\globalThis.__residentPerm3 = function (object) {
        \\  return object.count++;
        \\};
        \\const marker = { alive: true };
        \\const target = { count: 4 };
        \\assert.sameValue(__residentInsert2(target, marker), marker);
        \\assert.sameValue(target.field, marker);
        \\assert.sameValue(__residentInsert3(target, "indexed", marker), marker);
        \\assert.sameValue(target.indexed, marker);
        \\target.count = 12345678901234567890n;
        \\assert.sameValue(__residentPerm3(target), 12345678901234567890n);
        \\assert.sameValue(target.count, 12345678901234567891n);
        \\assert.sameValue(marker.alive, true);
    );
    try std.testing.expect(result.is(.undefined_value));

    const insert2 = try globalFunctionBytecode(&js, "__residentInsert2");
    try std.testing.expectEqual(@as(usize, 1), try finalOpcodeCount(insert2.byteCode(), op.insert2));
    const insert3 = try globalFunctionBytecode(&js, "__residentInsert3");
    try std.testing.expectEqual(@as(usize, 1), try finalOpcodeCount(insert3.byteCode(), op.insert3));
    const perm3 = try globalFunctionBytecode(&js, "__residentPerm3");
    try std.testing.expectEqual(@as(usize, 1), try finalOpcodeCount(perm3.byteCode(), op.perm3));
}

test "mapped arguments named field skips binding alias; computed index stays aliased" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.eval(
        \\function f(a) {
        \\  assert.sameValue(arguments[0], 7);
        \\  assert.sameValue(arguments.foo, undefined);
        \\  arguments.foo = 1;
        \\  assert.sameValue(arguments.foo, 1);
        \\  assert.sameValue(a, 7);
        \\  arguments[0] = 8;
        \\  assert.sameValue(a, 8);
        \\  assert.sameValue(arguments[0], 8);
        \\}
        \\f(7);
    );
    _ = result;
}

test "mapped arguments rest-style 0-formal length and index (sc_list)" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.eval(
        \\function sc_list() {
        \\  var a = arguments;
        \\  assert.sameValue(a.length, 2);
        \\  assert.sameValue(a[0], "x");
        \\  assert.sameValue(a[1], 9);
        \\  a[0] = "y";
        \\  assert.sameValue(a[0], "y");
        \\  assert.sameValue(a[2], undefined);
        \\  return a.length + a[1];
        \\}
        \\assert.sameValue(sc_list("x", 9), 11);
        \\function g(a, b) {
        \\  assert.sameValue(arguments[0], 1);
        \\  assert.sameValue(arguments[1], 2);
        \\  arguments[0] = 3;
        \\  assert.sameValue(a, 3);
        \\  a = 4;
        \\  assert.sameValue(arguments[0], 4);
        \\  delete arguments[1];
        \\  assert.sameValue(arguments[1], undefined);
        \\  assert.sameValue(b, 2);
        \\}
        \\g(1, 2);
    );
    _ = result;
}

test "typed array integer get uses class-id arm and qjs tag shape" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.eval(
        \\const u8 = new Uint8Array([255, 1]);
        \\assert.sameValue(u8[0], 255);
        \\assert.sameValue(u8[1], 1);
        \\assert.sameValue(u8[2], undefined);
        \\assert.sameValue(u8[-1], undefined);
        \\const i32 = new Int32Array([-1, 2147483647]);
        \\assert.sameValue(i32[0], -1);
        \\assert.sameValue(i32[1], 2147483647);
        \\const u32 = new Uint32Array([2147483648, 1]);
        \\assert.sameValue(u32[0], 2147483648);
        \\assert.sameValue(u32[1], 1);
        \\const f64 = new Float64Array([1, -0]);
        \\assert.sameValue(f64[0], 1);
        \\assert.sameValue(Object.is(f64[1], -0), true);
        \\const dense = [9, 8, 7];
        \\assert.sameValue(dense[1], 8);
        \\const buf = new ArrayBuffer(4);
        \\const view = new Uint8Array(buf);
        \\view[0] = 3;
        \\assert.sameValue(view[0], 3);
        \\const detached = new Uint8Array(new ArrayBuffer(2));
        \\detached[0] = 9;
        \\detached.buffer.transfer();
        \\assert.sameValue(detached[0], undefined);
    );
    _ = result;
}

test "typed array prototype chain get reads canonical numeric indices" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    // S1: TA-as-proto [[Get]] (PROTO-WALK-EXOTIC-AUDIT). qjs
    // JS_GetPropertyInternal consults is_exotic+fast_array
    // at every proto link, not only when the receiver is the TypedArray.
    const result = try js.eval(
        \\const ta = new Uint8Array([7, 8]);
        \\const o = Object.create(ta);
        \\assert.sameValue(o[0], 7);
        \\assert.sameValue(o["0"], 7);
        \\assert.sameValue(o[1], 8);
        \\assert.sameValue(o[2], undefined);
        \\assert.sameValue(0 in o, true);
        \\assert.sameValue(Object.prototype.hasOwnProperty.call(o, "0"), false);
        \\assert.sameValue([7, 8][0], 7);
        \\const fromArray = Object.create([7, 8]);
        \\assert.sameValue(fromArray[0], 7);
    );
    _ = result;
}

test "typed array integer put uses class-id arm" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.eval(
        \\const u8 = new Uint8Array(3);
        \\assert.sameValue(u8[0] = 255, 255);
        \\assert.sameValue(u8[0], 255);
        \\assert.sameValue(u8[1] = -1, -1);
        \\assert.sameValue(u8[1], 255);
        \\assert.sameValue(u8[2] = 300, 300);
        \\assert.sameValue(u8[2], 44);
        \\assert.sameValue(u8[3] = 7, 7);
        \\assert.sameValue(u8[3], undefined);
        \\const i32 = new Int32Array(1);
        \\assert.sameValue(i32[0] = -2147483648, -2147483648);
        \\assert.sameValue(i32[0], -2147483648);
        \\const f64 = new Float64Array(1);
        \\assert.sameValue(f64[0] = 42, 42);
        \\assert.sameValue(f64[0], 42);
        \\const dense = [0, 0];
        \\assert.sameValue(dense[1] = 8, 8);
        \\assert.sameValue(dense[1], 8);
        \\const detached = new Uint8Array(new ArrayBuffer(2));
        \\detached[0] = 9;
        \\detached.buffer.transfer();
        \\assert.sameValue(detached[0] = 1, 1);
        \\assert.sameValue(detached[0], undefined);
    );
    _ = result;
}

test "typed array int32 store fast arm preserves conversion and assignment semantics" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.eval(
        \\globalThis.__typedIntStore = function (array, index, value) {
        \\  return array[index] = value;
        \\};
        \\const i8 = new Int8Array(1);
        \\assert.sameValue(__typedIntStore(i8, 0, 255), 255);
        \\assert.sameValue(i8[0], -1);
        \\const u8 = new Uint8Array(1);
        \\assert.sameValue(__typedIntStore(u8, 0, -1), -1);
        \\assert.sameValue(u8[0], 255);
        \\const u8c = new Uint8ClampedArray(2);
        \\__typedIntStore(u8c, 0, -1);
        \\__typedIntStore(u8c, 1, 300);
        \\assert.sameValue(u8c[0], 0);
        \\assert.sameValue(u8c[1], 255);
        \\const i16 = new Int16Array(1);
        \\__typedIntStore(i16, 0, 65535);
        \\assert.sameValue(i16[0], -1);
        \\const u16 = new Uint16Array(1);
        \\__typedIntStore(u16, 0, -1);
        \\assert.sameValue(u16[0], 65535);
        \\const i32 = new Int32Array(1);
        \\__typedIntStore(i32, 0, -2147483648);
        \\assert.sameValue(i32[0], -2147483648);
        \\const u32 = new Uint32Array(1);
        \\__typedIntStore(u32, 0, -1);
        \\assert.sameValue(u32[0], 4294967295);
        \\const empty = new Uint8Array(0);
        \\assert.sameValue(__typedIntStore(empty, 0, 7), 7);
        \\assert.sameValue(empty[0], undefined);
        \\const f64 = new Float64Array(1);
        \\__typedIntStore(f64, 0, 42);
        \\assert.sameValue(f64[0], 42);
        \\let coercions = 0;
        \\__typedIntStore(u8, 0, { valueOf() { coercions++; return 258; } });
        \\assert.sameValue(u8[0], 2);
        \\assert.sameValue(coercions, 1);
    );
    try std.testing.expect(result.is(.undefined_value));

    const store = try globalFunctionBytecode(&js, "__typedIntStore");
    try std.testing.expectEqual(@as(usize, 1), try finalOpcodeCount(store.byteCode(), op.put_array_el));
}

test "checked local replacement preserves int fast moves and refcounted fallbacks" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();

    const result = try vm_helpers.parseAndRunWithTopLevelChildren(rt, ctx,
        \\(function () {
        \\  let value = 1;
        \\  value = 2;
        \\  value = "left";
        \\  value = "right";
        \\  value = 3;
        \\  return value;
        \\})()
    );
    try std.testing.expectEqual(@as(?i32, 3), result.as(.int));
}

test "an expression helper emits an explicit return after a bytecode call" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();

    const result = try vm_helpers.parseAndRunWithTopLevelChildren(rt, ctx,
        \\(function identity(value) { return value; })(42)
    );
    try std.testing.expectEqual(@as(?i32, 42), result.as(.int));
}

test "top-level function declarations use wide closure operands past 255 constants" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();

    var source = std.ArrayList(u8).empty;
    defer source.deinit(std.testing.allocator);
    for (0..260) |index| {
        var line_buf: [64]u8 = undefined;
        const line = try std.fmt.bufPrint(&line_buf, "function f{d}() {{ return {d}; }}\n", .{ index, index });
        try source.appendSlice(std.testing.allocator, line);
    }
    try source.appendSlice(std.testing.allocator, "f259();");

    const result = try vm_helpers.parseStmtAndRunWithTopLevelChildren(rt, ctx, source.items);
    try std.testing.expectEqual(@as(i32, 259), result.as(.int).?);
}

test "function expressions execute wide closure operands past 255 constants" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();

    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(std.testing.allocator);
    try source.appendSlice(std.testing.allocator, "const functions = [");
    for (0..257) |index| {
        if (index != 0) try source.append(std.testing.allocator, ',');
        var expression_buffer: [32]u8 = undefined;
        const expression = try std.fmt.bufPrint(&expression_buffer, "() => {d}", .{index});
        try source.appendSlice(std.testing.allocator, expression);
    }
    try source.appendSlice(std.testing.allocator, "]; functions[256]();");

    const result = try vm_helpers.parseStmtAndRunWithTopLevelChildren(rt, ctx, source.items);
    try std.testing.expectEqual(@as(i32, 256), result.as(.int).?);
}

test "call subsystem installs and invokes host globals" {
    var host = try BareRuntime.init(.{});
    defer host.deinit();
    const rt = host.rt;
    const ctx = host.ctx;
    const global = host.global;
    var wrapper = zjs.borrowContext(ctx);
    try zjs.test262_host.installTest262Globals(rt, &wrapper, global);

    const print_key = try rt.internAtom("print");
    const print = try global.getProperty(print_key);
    const print_object = core.Object.fromHeader(print.refHeader().?);
    const host_function_key = try rt.internAtom("__host_function");
    try std.testing.expect((try print_object.getOwnProperty(rt, host_function_key)) == null);
    try std.testing.expectEqual(core.host_function.ids.output, print_object.hostFunctionKindSlot().*);
    try std.testing.expect(print_object.nativeEntry() == &@import("zjs_host").output.output_host_entry);

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const args = [_]core.JSValue{ core.JSValue.int32(1), core.JSValue.boolean(true) };
    const result = try engine.exec.call_runtime.callValueOrBytecodeRoot(ctx, &stream, global, core.JSValue.undefinedValue(), print, &args, null, null);

    try std.testing.expect(result.is(.undefined_value));
    try std.testing.expectEqualStrings("1 true\n", stream.buffered());

    const log_key = try rt.internAtom("log");
    const console_object = try getGlobalObject(rt, global, "console");
    const log = try console_object.getProperty(log_key);
    const log_object = core.Object.fromHeader(log.refHeader().?);
    try std.testing.expectEqual(core.host_function.ids.output, log_object.hostFunctionKindSlot().*);
    try std.testing.expect(log_object.nativeEntry() == print_object.nativeEntry());

    const log_args = [_]core.JSValue{ core.JSValue.int32(2), core.JSValue.boolean(false) };
    const log_result = try engine.exec.call_runtime.callValueOrBytecodeRoot(ctx, &stream, global, core.JSValue.undefinedValue(), log, &log_args, null, null);
    try std.testing.expect(log_result.is(.undefined_value));
    try std.testing.expectEqualStrings("1 true\n2 false\n", stream.buffered());

    const assert_key = try rt.internAtom("assert");
    const same_value_key = try rt.internAtom("sameValue");
    const assert_object_value = try global.getProperty(assert_key);
    const assert_object_header = assert_object_value.refHeader().?;
    const assert_object = core.Object.fromHeader(assert_object_header);
    const same_value = try assert_object.getProperty(same_value_key);

    const same_args = [_]core.JSValue{ core.JSValue.float64(std.math.nan(f64)), core.JSValue.float64(std.math.nan(f64)) };
    const same_result = try engine.exec.call_runtime.callValueOrBytecodeRoot(ctx, null, global, core.JSValue.undefinedValue(), same_value, &same_args, null, null);
    try std.testing.expect(same_result.is(.undefined_value));
    const mismatch_args = [_]core.JSValue{ core.JSValue.int32(1), core.JSValue.int32(2) };
    try std.testing.expectError(error.JSException, engine.exec.call_runtime.callValueOrBytecodeRoot(ctx, null, global, core.JSValue.undefinedValue(), same_value, &mismatch_args, null, null));

    const test262_key = try rt.internAtom("Test262Error");
    const test262_ctor = try global.getProperty(test262_key);
    const test262_error = try engine.exec.call_runtime.callValueOrBytecodeRoot(ctx, null, global, core.JSValue.undefinedValue(), test262_ctor, &.{}, null, null);
    try std.testing.expect(test262_error.is(.object));

    const map_value = try engine.exec.collection_ops.construct(ctx, 1);
    const map_object = core.Object.fromHeader(map_value.refHeader().?);
    const set_key = try rt.internAtom("set");
    const get_key = try rt.internAtom("get");
    const map_set = try map_object.getProperty(set_key);
    const map_get = try map_object.getProperty(get_key);
    const stored_key_obj = try core.string.String.createUtf8(rt, "key");
    const stored_key = stored_key_obj.value();
    const stored_value_obj = try core.string.String.createUtf8(rt, "value");
    const stored_value = stored_value_obj.value();
    const set_args = [_]core.JSValue{ stored_key, stored_value };
    const set_result = try engine.exec.call_runtime.callValueOrBytecodeRoot(ctx, null, global, map_value, map_set, &set_args, null, null);
    try std.testing.expect(set_result.same(map_value));
    // NB2 (design §7 C3): the Zig error identity across the native seam is
    // `JSException`; the class lives on the pending exception.
    try std.testing.expectError(error.JSException, engine.exec.call_runtime.callValueOrBytecodeRoot(ctx, null, global, core.JSValue.undefinedValue(), map_set, &set_args, null, null));
    try std.testing.expect(ctx.hasException());
    ctx.clearException();
    const get_result = try engine.exec.call_runtime.callValueOrBytecodeRoot(ctx, null, global, map_value, map_get, &.{stored_key}, null, null);
    var get_text = std.ArrayList(u8).empty;
    defer get_text.deinit(rt.nativeAllocator());
    try engine.exec.value_ops.appendRawString(rt, &get_text, get_result);
    try std.testing.expectEqualStrings("value", get_text.items);
}

test "native builtin record dispatch is independent from dispatch-name strings" {
    var host = try BareRuntime.init(.{});
    defer host.deinit();
    const rt = host.rt;
    const ctx = host.ctx;
    const global = host.global;

    const math_object = try getGlobalObject(rt, global, "Math");
    const abs_object = try getGlobalObject(rt, math_object, "abs");
    try std.testing.expect(abs_object.nativeFunctionIdSlot().* != 0);
    const abs_record = abs_object.nativeEntry() orelse return error.InvalidBuiltinRegistry;
    try std.testing.expectEqual(core.native_entry.Kind.leaf, abs_record.kind);
    try std.testing.expectEqual(engine.exec.native_legacy.sig_f64_to_f64, abs_record.sig);

    const atan2_object = try getGlobalObject(rt, math_object, "atan2");
    const atan2_record = atan2_object.nativeEntry() orelse return error.InvalidBuiltinRegistry;
    try std.testing.expectEqual(core.native_entry.Kind.leaf, atan2_record.kind);
    try std.testing.expectEqual(engine.exec.native_legacy.sig_f64_f64_to_f64, atan2_record.sig);

    const fake = try engine.core.function.nativeFunction(ctx, "notMathAbs", 1);
    const fake_object = core.Object.fromHeader(fake.refHeader().?);
    fake_object.nativeFunctionIdSlot().* = abs_object.nativeFunctionIdSlot().*;

    const dispatch_name = try engine.exec.call.nativeFunctionNameForVm(rt, fake_object);
    defer rt.nativeAllocator().free(dispatch_name);
    try std.testing.expectEqualStrings("notMathAbs", dispatch_name);

    const args = [_]core.JSValue{core.JSValue.int32(-8)};
    const result = try engine.exec.call_runtime.callValueOrBytecodeRoot(ctx, null, global, core.JSValue.undefinedValue(), fake, &args, null, null);
    try std.testing.expectEqual(@as(f64, 8.0), engine.exec.value_ops.numberValue(result).?);

    // Plain op_call must prefer the resolved record memo. The encoded id is a
    // bootstrap key, not work to repeat after the function object is bound.
    fake_object.nativeEntrySlot().* = abs_record;
    fake_object.nativeFunctionIdSlot().* = 0;
    const memo_result = try engine.exec.call_runtime.callValueOrBytecodeRoot(ctx, null, global, core.JSValue.undefinedValue(), fake, &args, null, null);
    try std.testing.expectEqual(@as(f64, 8.0), engine.exec.value_ops.numberValue(memo_result).?);

    const fake_key = try rt.internAtom("fake");
    try global.defineOwnProperty(rt, fake_key, core.Descriptor.data(fake, .method));

    var parsed = try engine.parser.compile(.{ .realm = ctx }, "print(fake(-8));", .{ .mode = .script, .filename = "native-record-dispatch.js" });
    defer parsed.deinit();
    var output_buffer: [16]u8 = undefined;
    const function = parsed.functionBytecode() orelse return error.TestExpectedEqual;
    const vm_result = try host.run(function, &output_buffer);
    try std.testing.expect(vm_result.value.is(.undefined_value));
    try std.testing.expectEqualStrings("8\n", vm_result.output);
}

test "bytecode calls execute directly from the shared function bytecode" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const definition = try js.eval(
        \\function directFunctionBytecode(value) {
        \\    return value + 1;
        \\}
        \\undefined;
    );
    try std.testing.expect(definition.is(.undefined_value));

    const global = js.context.global.?;
    const name = try js.runtime.internAtom("directFunctionBytecode");
    const function_value = try global.getProperty(name);
    const function_object = engine.exec.object_ops.functionObjectFromValue(function_value) orelse
        return error.InvalidFunctionBytecode;
    const fb = function_object.bytecodeFunctionStoragePtr().function_bytecode orelse
        return error.InvalidFunctionBytecode;
    try std.testing.expect(!@hasField(bytecode.FunctionBytecode, "cached_view"));
    try std.testing.expect(fb.byteCode().len != 0);

    const first_args = [_]core.JSValue{core.JSValue.int32(1)};
    const first = try engine.exec.call_runtime.callValueOrBytecodeRoot(
        js.context,
        null,
        global,
        core.JSValue.undefinedValue(),
        function_value,
        &first_args,
        null,
        null,
    );
    try std.testing.expectEqual(@as(?i32, 2), first.as(.int));

    const second_args = [_]core.JSValue{core.JSValue.int32(2)};
    const second = try engine.exec.call_runtime.callValueOrBytecodeRoot(
        js.context,
        null,
        global,
        core.JSValue.undefinedValue(),
        function_value,
        &second_args,
        null,
        null,
    );
    try std.testing.expectEqual(@as(?i32, 3), second.as(.int));

    const rerun = try js.eval(
        \\assert.sameValue(directFunctionBytecode(3), 4);
        \\Promise.resolve(4)
        \\    .then(function(value) {
        \\        var holder = { method: directFunctionBytecode };
        \\        return holder.method(value);
        \\    })
        \\    .then(function(value) {
        \\        assert.sameValue(value, 5);
        \\    });
        \\undefined;
    );
    try std.testing.expect(rerun.is(.undefined_value));
}

test "Math cproto dispatch preserves observable ToNumber semantics" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    _ = try js.evalWithOutput(
        \\var log = "";
        \\var lhs = { valueOf() { log += "l"; return -3; } };
        \\var rhs = { valueOf() { log += "r"; return 4; } };
        \\print(Math.abs(lhs));
        \\print(Math.atan2(lhs, rhs) === Math.atan2(-3, 4));
        \\print(log);
        \\print(Number.isNaN(Math.abs()));
    , &stream);

    try std.testing.expectEqualStrings("3\ntrue\nllr\ntrue\n", stream.buffered());
}

test "primitiveToNumber is ToNumber of a primitive: untruncated, and BigInt or Symbol throws" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const rt = js.runtime;

    const to_number = core.typed_array.primitiveToNumber;
    try std.testing.expectEqual(@as(f64, 1.5), try to_number(rt, core.JSValue.float64(1.5)));
    try std.testing.expect(std.math.isNan(try to_number(rt, core.JSValue.undefinedValue())));
    try std.testing.expectEqual(@as(f64, 0), try to_number(rt, core.JSValue.nullValue()));
    const big = try engine.exec.value_ops.createBigIntI128(rt, 10);
    try std.testing.expectError(error.BigIntToNumber, to_number(rt, big));
    try std.testing.expectError(error.BigIntToNumber, core.typed_array.toIndexUsize(rt, big));
}

test "fused local/constant superinstructions keep generic semantics on edge values" {
    // l4..l8 sit past the short get_loc0..3 forms, so resolve_labels emits
    // get_loc8_push_{1,2,i8} (push_0 re-fuses into get_loc8_push_2),
    // push_0_or, push_0_shr, push_2_sar, sar_get_array_el, put_loc8_get_loc8
    // and get_loc2_field2. Expected output is node's.
    try helpers.expectPrints(
        \\function S(y) { return Object.is(y, -0) ? '-0' : String(y); }
        \\function f(v) {
        \\  var a0 = 0, a1 = 1, a2 = 2, a3 = 3, l4 = v, l5, l6, l7, l8;
        \\  l5 = l4; l6 = l5 + 1; l7 = l6; l8 = l7 - l4;
        \\  return [l4 + 2, l4 + 1, l4 + 100, l4 + 0, l4 | 0, l4 >>> 0, l4 >> 2, [10, 20, 30][l4 >> 1], l6, l8].map(S).join();
        \\}
        \\function g(o) { var a = 0, b = 1, c = o; return c.k + ':' + c.m(); }
        \\for (var v of [-0, -1, 2147483647, 4294967295, NaN, '3', { valueOf() { return 9; } }]) print(f(v));
        \\print(g({ k: 1, m() { return this.k + 1; } }));
    ,
        \\2,1,100,0,0,0,0,10,1,1
        \\1,0,99,-1,-1,4294967295,-1,undefined,0,1
        \\2147483649,2147483648,2147483747,2147483647,2147483647,2147483647,536870911,undefined,2147483648,1
        \\4294967297,4294967296,4294967395,4294967295,-1,4294967295,-1,undefined,4294967296,1
        \\NaN,NaN,NaN,NaN,0,0,0,10,NaN,NaN
        \\32,31,3100,30,3,3,0,20,31,28
        \\11,10,109,9,9,9,2,undefined,10,1
        \\1:2
        \\
    );
}

test "a class body scan treats function as a property name inside template substitutions" {
    // The class private-name pre-scan skips template substitutions token by
    // token; `function` after `.`/`?.` or before `:` is a property name, not
    // the head of a function to skip (prettier's postcss plugin failed to
    // parse with "invalid identifier").
    try helpers.expectPrints(
        \\var e = { function: 'F' }, o = { function: 'G' };
        \\class C {
        \\  a() { return `${e.function}`; }
        \\  b() { return `${o?.function}|${{ function: 1 }.function}`; }
        \\  c() { return `${function () { return '}'; }()}`; }
        \\  d() { return `${{ function() { return 'm'; } }.function()}`; }
        \\  e() { var x; x = o.function + `${e.function}`; return x; }
        \\}
        \\var c = new C();
        \\print([c.a(), c.b(), c.c(), c.d(), c.e()].join(' '));
    , "F G|1 } m GF\n");
}

test "Number.isNaN/isFinite never coerce and the globals always do, whatever the receiver" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    _ = try js.evalWithOutput(
        \\print(['abc'].map(Number.isNaN)[0], ['1'].filter(Number.isFinite).length);
        \\print(Number.isNaN.call(undefined, Symbol()), Number.isFinite.call(undefined, '1'));
        \\print(isNaN.call(Number, 'abc'), isFinite.call(Number, '1'), isNaN === Number.isNaN);
    , &stream);

    try std.testing.expectEqualStrings("false 0\nfalse false\ntrue true false\n", stream.buffered());
}

test "TypedArray methods on a primitive and argumentless Set methods throw with a message" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    _ = try js.evalWithOutput(
        \\const TA = Object.getPrototypeOf(Int8Array).prototype;
        \\for (const f of [() => TA.indexOf.call(1, 0), () => Object.getOwnPropertyDescriptor(TA, 'buffer').get.call(1), () => new Set().union()])
        \\  try { f(); print('no throw'); } catch (e) { print(e instanceof TypeError, e.message.length > 0); }
    , &stream);

    try std.testing.expectEqualStrings("true true\ntrue true\ntrue true\n", stream.buffered());
}

test "Iterator.prototype constructor and @@toStringTag setters use the receiver's internal methods" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    _ = try js.evalWithOutput(
        \\const set = Object.getOwnPropertyDescriptor(Iterator.prototype, Symbol.toStringTag).set;
        \\const log = [];
        \\const px = new Proxy({}, {
        \\  getOwnPropertyDescriptor(t, k) { log.push('gopd'); return Reflect.getOwnPropertyDescriptor(t, k); },
        \\  defineProperty(t, k, d) { log.push('def'); return Reflect.defineProperty(t, k, d); },
        \\  set(t, k, v, r) { log.push('set'); return Reflect.set(t, k, v, r); },
        \\});
        \\set.call(px, 'a'); set.call(px, 'b');
        \\print(log.join());
        \\let hit = 0;
        \\set.call({ get [Symbol.toStringTag]() { return 'x'; }, set [Symbol.toStringTag](v) { hit = v; } }, 'z');
        \\print(hit);
    , &stream);

    try std.testing.expectEqualStrings("gopd,def,gopd,set,gopd,def\nz\n", stream.buffered());
}

test "isPrototypeOf with a primitive receiver still walks the argument's prototype chain" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    _ = try js.evalWithOutput(
        \\let n = 0;
        \\const px = new Proxy({}, { getPrototypeOf() { n++; return null; } });
        \\print(Object.prototype.isPrototypeOf.call(1, px), n);
        \\const bad = new Proxy({}, { getPrototypeOf() { throw new SyntaxError('boom'); } });
        \\try { Object.prototype.isPrototypeOf.call('s', bad); print('no throw'); } catch (e) { print(e.constructor.name); }
    , &stream);

    try std.testing.expectEqualStrings("false 1\nSyntaxError\n", stream.buffered());
}

test "local add_loc retains string snapshots after accumulator tail removal" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.eval(
        \\function build() {
        \\  var text = "";
        \\  for (var i = 0; i < 4096; i++) text += "ab";
        \\  return text;
        \\}
        \\function verifySnapshot() {
        \\  var text = "";
        \\  var snapshot;
        \\  for (var i = 0; i < 4096; i++) {
        \\    if (i === 2048) snapshot = text;
        \\    text += "ab";
        \\  }
        \\  return snapshot.length;
        \\}
        \\if (verifySnapshot() !== 4096) throw new Error("snapshot mutated");
        \\globalThis.__rope_tail_probe = build();
    );
    try std.testing.expect(result.is(.undefined_value));

    const global = js.context.global orelse return error.TypeError;
    const probe_atom = try js.runtime.internAtom("__rope_tail_probe");
    const text = try global.getProperty(probe_atom);
    try std.testing.expectEqual(@as(usize, 8192), core.string.stringValueLen(text));
    if (text.ropeBody()) |rope| {
        var chain_depth: usize = 1;
        var cursor = rope;
        while (cursor.left.ropeBody()) |left| {
            chain_depth += 1;
            if (chain_depth > 8) break;
            cursor = left;
        }
        try std.testing.expect(chain_depth <= 4);
    }
}

test "add_loc string+object goes through slow add after toPrimitive (qjs OP_add_loc)" {
    // X-03: qjs:19766-19767 requires both operands already JS_TAG_STRING
    // before in-place concat. An object RHS must take js_add_slow so a
    // toString that reassigns the accumulator cannot mutate a stale rope.

    try helpers.expectPrints(
        \\function f(){
        \\  var s = "abc";
        \\  var stash = null;
        \\  s = s + "d";
        \\  var o = { toString: function(){ stash = s; s = "ZZZ"; return "Q"; } };
        \\  s = s + o;
        \\  return "s=" + s + " stash=" + stash;
        \\}
        \\print(f());
        \\function plusEq(){
        \\  var s = "abc";
        \\  var stash = null;
        \\  s = s + "d";
        \\  var o = { toString: function(){ stash = s; s = "ZZZ"; return "Q"; } };
        \\  s += o;
        \\  return "s=" + s + " stash=" + stash;
        \\}
        \\print(plusEq());
        \\function viaValueOf(){
        \\  var s = "abc";
        \\  var stash = null;
        \\  s = s + "d";
        \\  var o = { valueOf: function(){ stash = s; s = "ZZZ"; return "Q"; } };
        \\  s = s + o;
        \\  return "s=" + s + " stash=" + stash;
        \\}
        \\print(viaValueOf());
        \\function viaToPrim(){
        \\  var s = "abc";
        \\  var stash = null;
        \\  s = s + "d";
        \\  var o = { [Symbol.toPrimitive]: function(){ stash = s; s = "ZZZ"; return "Q"; } };
        \\  s = s + o;
        \\  return "s=" + s + " stash=" + stash;
        \\}
        \\print(viaToPrim());
        \\function viaClosure(){
        \\  var s = "abc";
        \\  var stash = null;
        \\  s = s + "d";
        \\  function cap(){ return s; }
        \\  var o = { toString: function(){ stash = s; s = "ZZZ"; return "Q"; } };
        \\  s = s + o;
        \\  return "s=" + s + " stash=" + stash + " cap=" + cap();
        \\}
        \\print(viaClosure());
        \\function longRope(){
        \\  var s = "";
        \\  for (var i = 0; i < 9000; i++) s += "a";
        \\  var stash = null;
        \\  s = s + "d";
        \\  var o = { toString: function(){ stash = s; s = "ZZZ"; return "Q"; } };
        \\  s = s + o;
        \\  return "s_len=" + s.length + " s_is_ZZZ=" + (s === "ZZZ") + " stash_len=" + stash.length;
        \\}
        \\print(longRope());
        \\function noTailSidecar(){
        \\  var base = "abc";
        \\  var t = base + "y";
        \\  var stash = null;
        \\  var o = { toString: function(){ stash = t; t = "ZZZ"; return "Q"; } };
        \\  t = t + o;
        \\  return "t=" + t + " stash=" + stash;
        \\}
        \\print(noTailSidecar());
        \\function toStringNumber(){
        \\  var s = "abc";
        \\  var stash = null;
        \\  s = s + "d";
        \\  var o = { toString: function(){ stash = s; s = "ZZZ"; return 1; } };
        \\  s = s + o;
        \\  return "s=" + s + " stash=" + stash;
        \\}
        \\print(toStringNumber());
        \\function notAddLoc(){
        \\  var s = "abc";
        \\  var stash = null;
        \\  s = s + "d";
        \\  var o = { toString: function(){ stash = s; s = "ZZZ"; return "Q"; } };
        \\  var r = s + o;
        \\  return "s=" + s + " r=" + r + " stash=" + stash;
        \\}
        \\print(notAddLoc());
    , "s=abcdQ stash=abcd\n" ++
        "s=abcdQ stash=abcd\n" ++
        "s=abcdQ stash=abcd\n" ++
        "s=abcdQ stash=abcd\n" ++
        "s=abcdQ stash=abcd cap=abcdQ\n" ++
        "s_len=9002 s_is_ZZZ=false stash_len=9001\n" ++
        "t=abcyQ stash=abcy\n" ++
        "s=abcd1 stash=abcd\n" ++
        "s=ZZZ r=abcdQ stash=abcd\n");
}

test "checked lexical string accumulation keeps rope depth bounded" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.eval(
        \\function build() {
        \\  let text = "";
        \\  let snapshot;
        \\  for (var i = 0; i < 8192; i++) {
        \\    if (i === 4096) snapshot = text;
        \\    text += "ab";
        \\  }
        \\  if (snapshot.length !== 8192) throw new Error("snapshot mutated");
        \\  return text;
        \\}
        \\globalThis.__checked_lexical_rope_probe = build();
    );
    try std.testing.expect(result.is(.undefined_value));

    const global = js.context.global orelse return error.TypeError;
    const probe_atom = try js.runtime.internAtom("__checked_lexical_rope_probe");
    const text = try global.getProperty(probe_atom);
    const rope = text.ropeBody() orelse return error.TypeError;
    try std.testing.expectEqual(@as(usize, 16384), rope.len_());

    // QJS caps rope depth and rebalances; zjs may use its private growable tail,
    // but must likewise avoid retaining one wrapper node per `+=` iteration.
    var left_depth: usize = 1;
    var cursor = rope;
    while (cursor.left.ropeBody()) |left| {
        left_depth += 1;
        if (left_depth > 64) break;
        cursor = left;
    }
    try std.testing.expect(left_depth <= 64);
}

test "computed reads with cached string atoms preserve exotic and prototype semantics" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\const proto = { get hot() { return 7; } };
        \\const object = Object.create(proto);
        \\assert.sameValue(object["hot"], 7);
        \\let trapCalls = 0;
        \\const proxy = new Proxy(object, {
        \\  get(target, key, receiver) {
        \\    trapCalls++;
        \\    return Reflect.get(target, key, receiver);
        \\  }
        \\});
        \\assert.sameValue(proxy["hot"], 7);
        \\assert.sameValue(trapCalls, 1);
        \\assert.sameValue([11]["0"], 11);
        \\assert.sameValue("ab"["1"], "b");
        \\assert.sameValue(new Uint8Array([9])["0"], 9);
        \\const dynamic = "dynamic" + "Key";
        \\const keyed = { dynamicKey: 13 };
        \\assert.sameValue(keyed[dynamic], 13);
        \\assert.sameValue(keyed[dynamic], 13);
        \\let holder;
        \\const recycledKey = "recycled_key_" + 12345;
        \\holder = {};
        \\holder[recycledKey] = 1;
        \\const invariantTarget = {};
        \\const recyclingProxy = new Proxy(invariantTarget, {
        \\  get(target, key) {
        \\    delete holder[recycledKey];
        \\    holder = null;
        \\    const replacementKey = "replacement_key_" + 67890;
        \\    Object.defineProperty(target, replacementKey, {
        \\      value: 123,
        \\      configurable: false,
        \\      writable: false
        \\    });
        \\    return 456;
        \\  }
        \\});
        \\assert.sameValue(recyclingProxy[recycledKey], 456);
    );

    try std.testing.expect(result.is(.undefined_value));
}

test "native dispatch metadata is internal and ignores user properties" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var f = Object.prototype.isPrototypeOf;
        \\print("__zjs_native_name" in f);
        \\print(Object.getOwnPropertyDescriptor(f, "__zjs_native_name") === undefined);
        \\f.__zjs_native_name = "notIsPrototypeOf";
        \\print(f.call(Object.prototype, {}));
        \\print(delete f.__zjs_native_name);
        \\print(f.call(Object.prototype, {}));
        \\var a = [];
        \\Array.prototype.push.__zjs_native_name = "notPush";
        \\print(Array.prototype.push.call(a, 1));
        \\print(delete Array.prototype.push.__zjs_native_name);
        \\print(Array.prototype.push.call(a, 2));
        \\print(a.length);
    , &stream);

    try std.testing.expect(result.is(.undefined_value));
    try std.testing.expectEqualStrings("false\ntrue\ntrue\ntrue\ntrue\n1\ntrue\n2\n2\n", stream.buffered());
}

test "scope resolver skips popped lexical shadow for destructured parameter" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.eval(
        \\function f({ comment, items }) {
        \\  { let comment = null; }
        \\  for (let i = 0; i < items.length; ++i) {
        \\    let comment = "inner";
        \\  }
        \\  return comment;
        \\}
        \\assert.sameValue(f({ comment: "ok", items: [1] }), "ok");
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "__zjs-prefixed user properties are ordinary own properties" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [512]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var o = {};
        \\o.__zjs_user = 1;
        \\Object.defineProperty(o, "__zjs_non_enum", { value: 2, enumerable: false, configurable: true });
        \\print(Object.getOwnPropertyNames(o).join("|"));
        \\print(Object.getOwnPropertyDescriptors(o).__zjs_user.value);
        \\print(Object.getOwnPropertyDescriptor(o, "__zjs_non_enum").value);
        \\print(Reflect.ownKeys(o).join("|"));
        \\print(Object.keys(o).join("|"));
        \\print("__zjs_user" in o);
    , &stream);

    try std.testing.expect(result.is(.undefined_value));
    try std.testing.expectEqualStrings("__zjs_user|__zjs_non_enum\n1\n2\n__zjs_user|__zjs_non_enum\n__zjs_user\ntrue\n", stream.buffered());
}

test "array species fast path markers are internal" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var getter = Object.getOwnPropertyDescriptor(Array, Symbol.species).get;
        \\print("__zjs_array_constructor" in Array);
        \\print(Object.getOwnPropertyDescriptor(Array, "__zjs_array_constructor") === undefined);
        \\print("__zjs_array_species_getter" in getter);
        \\print(Object.getOwnPropertyDescriptor(getter, "__zjs_array_species_getter") === undefined);
        \\Array.__zjs_array_constructor = 0;
        \\getter.__zjs_array_species_getter = 0;
        \\var mapped = [1, 2].map(function(value) { return value + 1; });
        \\print(mapped instanceof Array);
        \\print(mapped.join(","));
        \\print(delete Array.__zjs_array_constructor);
        \\print(delete getter.__zjs_array_species_getter);
        \\print([3].filter(function() { return true; }).join(","));
    , &stream);

    try std.testing.expect(result.is(.undefined_value));
    try std.testing.expectEqualStrings("false\ntrue\nfalse\ntrue\ntrue\n2,3\ntrue\ntrue\n3\n", stream.buffered());
}

test "auto-init builtin markers are internal and ignore user properties" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [512]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function check(fn, marker, run) {
        \\  print(marker in fn);
        \\  print(Object.getOwnPropertyDescriptor(fn, marker) === undefined);
        \\  fn[marker] = 0;
        \\  print(run());
        \\  print(delete fn[marker]);
        \\  print(run());
        \\}
        \\check(Object.assign, "__zjs_object_static", function() {
        \\  var target = {};
        \\  Object.assign(target, { x: 1 });
        \\  return target.x;
        \\});
        \\check(Object.defineProperty, "__zjs_define_property_kind", function() {
        \\  var object = {};
        \\  Object.defineProperty(object, "x", { value: 1 });
        \\  return object.x;
        \\});
        \\check(Object.prototype.hasOwnProperty, "__zjs_object_method", function() {
        \\  return Object.prototype.hasOwnProperty.call({ x: 1 }, "x");
        \\});
        \\check(String.prototype.includes, "__zjs_string_method", function() {
        \\  return "abc".includes("b");
        \\});
        \\check(Number.prototype.toFixed, "__zjs_number_method", function() {
        \\  return (7).toFixed(0);
        \\});
        \\check(RegExp.prototype.test, "__zjs_regexp_method", function() {
        \\  return /a/.test("a");
        \\});
        \\check(RegExp.escape, "__zjs_regexp_escape", function() {
        \\  return RegExp.escape("a+b") === "\\x61\\+b";
        \\});
        \\check(JSON.parse, "__zjs_json_static", function() {
        \\  return JSON.parse("{\"x\":1}").x;
        \\});
        \\check(JSON.stringify, "__zjs_json_static", function() {
        \\  return JSON.stringify({ x: 1 });
        \\});
        \\check(Reflect.apply, "__zjs_reflect_static", function() {
        \\  return Reflect.apply(function(x) { return x + 1; }, null, [2]);
        \\});
        \\check(Reflect.setPrototypeOf, "__zjs_reflect_set_prototype_of", function() {
        \\  var proto = { x: 1 };
        \\  var object = {};
        \\  return Reflect.setPrototypeOf(object, proto) && object.x;
        \\});
        \\check(Reflect.defineProperty, "__zjs_define_property_kind", function() {
        \\  var object = {};
        \\  return Reflect.defineProperty(object, "x", { value: 1 }) && object.x;
        \\});
        \\check(Atomics.isLockFree, "__zjs_atomics_static", function() {
        \\  return Atomics.isLockFree(4);
        \\});
        \\check(Array.prototype.concat, "__zjs_array_concat", function() {
        \\  return [1].concat([2]).join(",");
        \\});
        \\check(ArrayBuffer.prototype.slice, "__zjs_buffer_method_kind", function() {
        \\  return new ArrayBuffer(4).slice(1).byteLength;
        \\});
        \\check(SharedArrayBuffer.prototype.slice, "__zjs_buffer_method_kind", function() {
        \\  return new SharedArrayBuffer(4).slice(1).byteLength;
        \\});
        \\check(Object.getOwnPropertyDescriptor(ArrayBuffer.prototype, "byteLength").get, "__zjs_buffer_accessor_kind", function() {
        \\  return new ArrayBuffer(4).byteLength;
        \\});
        \\check(Object.getOwnPropertyDescriptor(SharedArrayBuffer.prototype, "byteLength").get, "__zjs_buffer_accessor_kind", function() {
        \\  return new SharedArrayBuffer(4).byteLength;
        \\});
        \\check(Object.getOwnPropertyDescriptor(DataView.prototype, "byteLength").get, "__zjs_dataview_accessor", function() {
        \\  return new DataView(new ArrayBuffer(6), 1, 3).byteLength;
        \\});
        \\check(Object.getOwnPropertyDescriptor(Object.getPrototypeOf(Uint8Array.prototype), "length").get, "__zjs_typedarray_accessor", function() {
        \\  return new Uint8Array(5).length;
        \\});
        \\check(Uint8Array.prototype.slice, "__zjs_typedarray_method", function() {
        \\  return new Uint8Array([1, 2]).slice(1)[0];
        \\});
    , &stream);

    try std.testing.expect(result.is(.undefined_value));
    try std.testing.expectEqualStrings(
        "false\ntrue\n1\ntrue\n1\n" ++
            "false\ntrue\n1\ntrue\n1\n" ++
            "false\ntrue\ntrue\ntrue\ntrue\n" ++
            "false\ntrue\ntrue\ntrue\ntrue\n" ++
            "false\ntrue\n7\ntrue\n7\n" ++
            "false\ntrue\ntrue\ntrue\ntrue\n" ++
            "false\ntrue\ntrue\ntrue\ntrue\n" ++
            "false\ntrue\n1\ntrue\n1\n" ++
            "false\ntrue\n{\"x\":1}\ntrue\n{\"x\":1}\n" ++
            "false\ntrue\n3\ntrue\n3\n" ++
            "false\ntrue\n1\ntrue\n1\n" ++
            "false\ntrue\n1\ntrue\n1\n" ++
            "false\ntrue\ntrue\ntrue\ntrue\n" ++
            "false\ntrue\n1,2\ntrue\n1,2\n" ++
            "false\ntrue\n3\ntrue\n3\n" ++
            "false\ntrue\n3\ntrue\n3\n" ++
            "false\ntrue\n4\ntrue\n4\n" ++
            "false\ntrue\n4\ntrue\n4\n" ++
            "false\ntrue\n3\ntrue\n3\n" ++
            "false\ntrue\n5\ntrue\n5\n" ++
            "false\ntrue\n2\ntrue\n2\n",
        stream.buffered(),
    );
}

test "immutable prototype marker is internal" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\print("__zjs_immutable_prototype" in Object.prototype);
        \\print(Object.getOwnPropertyDescriptor(Object.prototype, "__zjs_immutable_prototype") === undefined);
        \\Object.prototype.__zjs_immutable_prototype = false;
        \\print(Reflect.setPrototypeOf(Object.prototype, {}));
        \\try { Object.setPrototypeOf(Object.prototype, {}); print("no throw"); } catch (e) { print(e.name); }
        \\print(delete Object.prototype.__zjs_immutable_prototype);
        \\print(Reflect.setPrototypeOf(Object.prototype, null));
    , &stream);

    try std.testing.expect(result.is(.undefined_value));
    try std.testing.expectEqualStrings("false\ntrue\nfalse\nTypeError\ntrue\ntrue\n", stream.buffered());
}

test "builtin dispatch function markers are internal" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [512]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function check(fn, marker, run) {
        \\  print(marker in fn);
        \\  print(Object.getOwnPropertyDescriptor(fn, marker) === undefined);
        \\  fn[marker] = 0;
        \\  print(run());
        \\  print(delete fn[marker]);
        \\  print(run());
        \\}
        \\check(Function.prototype.toString, "__zjs_function_to_string", function() {
        \\  return typeof Function.prototype.toString.call(Array.prototype.push);
        \\});
        \\check(Error.prototype.toString, "__zjs_error_to_string", function() {
        \\  return Error.prototype.toString.call({ name: "E", message: "m" });
        \\});
        \\var constructorDesc = Object.getOwnPropertyDescriptor(Iterator.prototype, "constructor");
        \\var tagDesc = Object.getOwnPropertyDescriptor(Iterator.prototype, Symbol.toStringTag);
        \\check(constructorDesc.get, "__zjs_iterator_accessor", function() {
        \\  return constructorDesc.get.call(Iterator.prototype) === Iterator;
        \\});
        \\check(tagDesc.get, "__zjs_iterator_accessor", function() {
        \\  return tagDesc.get.call(Iterator.prototype);
        \\});
    , &stream);

    try std.testing.expect(result.is(.undefined_value));
    try std.testing.expectEqualStrings(
        "false\ntrue\nstring\ntrue\nstring\n" ++
            "false\ntrue\nE: m\ntrue\nE: m\n" ++
            "false\ntrue\ntrue\ntrue\ntrue\n" ++
            "false\ntrue\nIterator\ntrue\nIterator\n",
        stream.buffered(),
    );
}

test "proxy revocation target is internal" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var r = Proxy.revocable({ x: 1 }, {});
        \\var revoke = r.revoke;
        \\print("__zjs_revoke_proxy" in revoke);
        \\print(Object.getOwnPropertyDescriptor(revoke, "__zjs_revoke_proxy") === undefined);
        \\revoke.__zjs_revoke_proxy = null;
        \\print(revoke.__zjs_revoke_proxy === null);
        \\revoke();
        \\var threw = false;
        \\try {
        \\  r.proxy.x;
        \\} catch (e) {
        \\  threw = e instanceof TypeError;
        \\}
        \\print(threw);
        \\print(delete revoke.__zjs_revoke_proxy);
        \\print("__zjs_revoke_proxy" in revoke);
        \\var r2 = Proxy.revocable({ y: 2 }, {});
        \\print(delete r2.revoke.__zjs_revoke_proxy);
        \\r2.revoke();
        \\var threw2 = false;
        \\try {
        \\  r2.proxy.y;
        \\} catch (e) {
        \\  threw2 = e instanceof TypeError;
        \\}
        \\print(threw2);
        \\r2.revoke();
        \\print("done");
    , &stream);

    try std.testing.expect(result.is(.undefined_value));
    try std.testing.expectEqualStrings("false\ntrue\ntrue\ntrue\ntrue\nfalse\ntrue\ntrue\ndone\n", stream.buffered());
}

test "regexp accessor realm TypeError constructor is internal" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var getter = Object.getOwnPropertyDescriptor(RegExp.prototype, "source").get;
        \\print("__zjs_realm_TypeError" in getter);
        \\print(Object.getOwnPropertyDescriptor(getter, "__zjs_realm_TypeError") === undefined);
        \\function Fake(message) {
        \\  this.message = message;
        \\}
        \\Fake.prototype = Object.create(Error.prototype);
        \\Fake.prototype.constructor = Fake;
        \\getter.__zjs_realm_TypeError = Fake;
        \\try {
        \\  getter.call({});
        \\} catch (e) {
        \\  print(e.constructor === Fake);
        \\  print(e instanceof TypeError);
        \\}
        \\print(delete getter.__zjs_realm_TypeError);
        \\try {
        \\  getter.call({});
        \\} catch (e) {
        \\  print(e instanceof TypeError);
        \\}
    , &stream);

    try std.testing.expect(result.is(.undefined_value));
    try std.testing.expectEqualStrings("false\ntrue\nfalse\ntrue\ntrue\ntrue\n", stream.buffered());
}

test "throw type error intrinsic marker is internal" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\"use strict";
        \\print("__zjs_throw_type_error_intrinsic" in globalThis);
        \\print(Object.getOwnPropertyDescriptor(globalThis, "__zjs_throw_type_error_intrinsic") === undefined);
        \\globalThis.__zjs_throw_type_error_intrinsic = function() { return 1; };
        \\print("__zjs_throw_type_error_intrinsic" in globalThis);
        \\print(delete globalThis.__zjs_throw_type_error_intrinsic);
        \\print("__zjs_throw_type_error_intrinsic" in globalThis);
        \\var thrower = Object.getOwnPropertyDescriptor(Function.prototype, "arguments").get;
        \\print(typeof thrower);
        \\print("__zjs_throw_type_error_function_proto" in thrower);
        \\print(Object.getOwnPropertyDescriptor(thrower, "__zjs_throw_type_error_function_proto") === undefined);
        \\var assignType = "none";
        \\try {
        \\  thrower.__zjs_throw_type_error_function_proto = false;
        \\} catch (e) {
        \\  assignType = e.name;
        \\}
        \\print(assignType);
        \\print("__zjs_throw_type_error_function_proto" in thrower);
        \\print(delete thrower.__zjs_throw_type_error_function_proto);
        \\var threw = false;
        \\try {
        \\  thrower();
        \\} catch (e) {
        \\  threw = e instanceof TypeError;
        \\}
        \\print(threw);
    , &stream);

    try std.testing.expect(result.is(.undefined_value));
    try std.testing.expectEqualStrings("false\ntrue\ntrue\ntrue\nfalse\nfunction\nfalse\ntrue\nTypeError\nfalse\ntrue\ntrue\n", stream.buffered());

    _ = try js.eval("globalThis.__thrower_probe = Object.getOwnPropertyDescriptor(Function.prototype, \"arguments\").get;");
    try std.testing.expect(js.context.global != null);
    const global = js.context.global.?;
    const probe_key = try js.runtime.internAtom("__thrower_probe");
    const thrower_value = try global.getProperty(probe_key);
    const thrower_object = try property_ops.expectObject(thrower_value);
    const dispatch_atom = thrower_object.nativeDispatchName();
    try std.testing.expect(dispatch_atom != core.atom.null_atom);
    const dispatch_name = js.runtime.atoms.name(dispatch_atom);
    try std.testing.expect(dispatch_name != null);
    try std.testing.expectEqualStrings("", dispatch_name.?);
}

test "async generator prototype method marker is internal" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\async function* g() {}
        \\var AsyncGeneratorPrototype = Object.getPrototypeOf(g.prototype);
        \\var next = AsyncGeneratorPrototype.next;
        \\print("__zjs_async_generator_method" in next);
        \\print(Object.getOwnPropertyDescriptor(next, "__zjs_async_generator_method") === undefined);
        \\next.__zjs_async_generator_method = 0;
        \\print("__zjs_async_generator_method" in next);
        \\print(delete next.__zjs_async_generator_method);
        \\print("__zjs_async_generator_method" in next);
    , &stream);

    try std.testing.expect(result.is(.undefined_value));
    try std.testing.expectEqualStrings("false\ntrue\ntrue\ntrue\nfalse\n", stream.buffered());
}

test "generator instances inherit shared prototype methods" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [512]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function* syncGenerator() { yield 1; }
        \\var syncA = syncGenerator();
        \\var syncB = syncGenerator();
        \\var GeneratorPrototype = Object.getPrototypeOf(syncGenerator.prototype);
        \\var arrayIteratorForNativeRecord = [][Symbol.iterator]();
        \\print(Object.getOwnPropertyNames(syncA).length);
        \\print(syncA.next === GeneratorPrototype.next);
        \\print(syncA.return === GeneratorPrototype.return);
        \\print(syncA.throw === GeneratorPrototype.throw);
        \\print(syncA.next === syncB.next);
        \\print(syncA.next.length);
        \\print(typeof syncA.slice);
        \\var calls = 0;
        \\var overridden = syncGenerator();
        \\var builtinNext = overridden.next;
        \\overridden.next = function() {
        \\  calls++;
        \\  return builtinNext.call(this);
        \\};
        \\var values = [];
        \\for (var value of overridden) values.push(value);
        \\print(calls + ":" + values.join(","));
        \\var customGeneratorPrototype = Object.create(GeneratorPrototype);
        \\syncGenerator.prototype = customGeneratorPrototype;
        \\var customSync = syncGenerator();
        \\print(Object.getPrototypeOf(customSync) === customGeneratorPrototype);
        \\print(customSync.next === GeneratorPrototype.next);
        \\syncGenerator.prototype = 1;
        \\print(Object.getPrototypeOf(syncGenerator()) === GeneratorPrototype);
        \\async function* asyncGenerator() { yield 1; }
        \\var asyncA = asyncGenerator();
        \\var asyncB = asyncGenerator();
        \\var AsyncGeneratorPrototype = Object.getPrototypeOf(asyncGenerator.prototype);
        \\print(Object.getOwnPropertyNames(asyncA).length);
        \\print(asyncA.next === AsyncGeneratorPrototype.next);
        \\print(asyncA.return === AsyncGeneratorPrototype.return);
        \\print(asyncA.throw === AsyncGeneratorPrototype.throw);
        \\print(asyncA.next === asyncB.next);
        \\print(asyncA.next.length);
        \\print(typeof asyncA.slice);
        \\var customAsyncGeneratorPrototype = Object.create(AsyncGeneratorPrototype);
        \\asyncGenerator.prototype = customAsyncGeneratorPrototype;
        \\print(Object.getPrototypeOf(asyncGenerator()) === customAsyncGeneratorPrototype);
        \\asyncGenerator.prototype = null;
        \\print(Object.getPrototypeOf(asyncGenerator()) === AsyncGeneratorPrototype);
    , &stream);

    try std.testing.expect(result.is(.undefined_value));
    try std.testing.expectEqualStrings(
        "0\ntrue\ntrue\ntrue\ntrue\n1\nundefined\n2:1\ntrue\ntrue\ntrue\n0\ntrue\ntrue\ntrue\ntrue\n1\nundefined\ntrue\ntrue\n",
        stream.buffered(),
    );

    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const sync_key = try js.runtime.internAtom("syncA");
    const sync_value = try global.getProperty(sync_key);
    const sync_object = try property_ops.expectObject(sync_value);
    try std.testing.expect(!sync_object.isBorrowedReferenceHolder());
    try std.testing.expectEqual(global, engine.exec.object_ops.objectRealmGlobal(sync_object).?);

    const generator_prototype_key = try js.runtime.internAtom("GeneratorPrototype");
    const generator_prototype_value = try global.getProperty(generator_prototype_key);
    const generator_prototype = try property_ops.expectObject(generator_prototype_value);
    const IntrinsicMethod = core.host_function.builtin_method_ids.iterator.IntrinsicMethod;
    const generator_methods = [_]struct { name: []const u8, id: u32 }{
        .{ .name = "next", .id = @intFromEnum(IntrinsicMethod.generator_next) },
        .{ .name = "return", .id = @intFromEnum(IntrinsicMethod.generator_return) },
        .{ .name = "throw", .id = @intFromEnum(IntrinsicMethod.generator_throw) },
    };
    for (generator_methods) |method| {
        const key = try js.runtime.internAtom(method.name);
        const value = try generator_prototype.getProperty(key);
        const function_object = try property_ops.expectObject(value);
        const native_ref = core.function.decodeNativeBuiltinId(function_object.nativeFunctionIdSlot().*) orelse return error.InvalidBuiltinRegistry;
        try std.testing.expectEqual(core.function.NativeBuiltinDomain.iterator, native_ref.domain);
        try std.testing.expectEqual(method.id, native_ref.id);
        try std.testing.expect(function_object.nativeEntry() != null);
    }

    const array_iterator_key = try js.runtime.internAtom("arrayIteratorForNativeRecord");
    const array_iterator_value = try global.getProperty(array_iterator_key);
    const array_iterator = try property_ops.expectObject(array_iterator_value);
    const next_key = try js.runtime.internAtom("next");
    const next_value = try array_iterator.getProperty(next_key);
    const next_function = try property_ops.expectObject(next_value);
    const next_ref = core.function.decodeNativeBuiltinId(next_function.nativeFunctionIdSlot().*) orelse return error.InvalidBuiltinRegistry;
    try std.testing.expectEqual(core.function.NativeBuiltinDomain.iterator, next_ref.domain);
    try std.testing.expectEqual(@intFromEnum(IntrinsicMethod.array_iterator_next), next_ref.id);
    try std.testing.expect(next_function.nativeEntry() != null);
}

test "generator object uses the prototype selected after parameter initialization" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.eval(
        \\var GeneratorPrototype = Object.getPrototypeOf(function* () {}.prototype);
        \\var syncPrototype = Object.create(GeneratorPrototype);
        \\function* syncGenerator(value = (syncGenerator.prototype = syncPrototype)) {}
        \\if (Object.getPrototypeOf(syncGenerator()) !== syncPrototype) throw new Error("sync prototype order");
        \\var AsyncGeneratorPrototype = Object.getPrototypeOf(async function* () {}.prototype);
        \\var asyncPrototype = Object.create(AsyncGeneratorPrototype);
        \\async function* asyncGenerator(value = (asyncGenerator.prototype = asyncPrototype)) {}
        \\if (Object.getPrototypeOf(asyncGenerator()) !== asyncPrototype) throw new Error("async prototype order");
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "closure-env var_ref hitting rc zero during remove_cycles stays a batch no-op" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const body =
        \\(function () {
        \\  let cycleSelf = null;
        \\  function cycleInner() { return cycleSelf; }
        \\  cycleSelf = { fn: cycleInner };
        \\  if (cycleSelf.fn() !== cycleSelf) throw new Error("capture wiring");
        \\})();
        \\"collected";
    ;

    // First round reaches the engine's steady state (repl bootstrap pins a
    // few permanent cells). forceGC must run from outside any active frame:
    // an in-eval $262.gc() still sees stale VM-stack slots of the running
    // script as conservative roots and would keep the dead ring alive.
    _ = try js.evalWithOptions(body, .{ .filename = "<repl>" });
    _ = try js.runtime.forceGC(null);
    const cell_steady = js.runtime.gc.liveCountKind(.var_ref);
    const object_steady = js.runtime.gc.liveCountKind(.object);

    // Each round strands one {closure -> cell -> object -> closure} ring that
    // only the cycle batch can reclaim. destroyZeroRef's remove_cycles gate
    // must keep the cell's mid-batch rc==0 a pure no-op (never the synchronous
    // free_var_ref tail), so the garbage_var_refs loop frees it exactly once
    // and the live census cannot grow across rounds.
    var round: usize = 0;
    while (round < 4) : (round += 1) {
        const result = try js.evalWithOptions(body, .{ .filename = "<repl>" });
        try helpers.expectStringValueBytes(result, "collected");
        _ = try js.runtime.forceGC(null);
        try std.testing.expectEqual(cell_steady, js.runtime.gc.liveCountKind(.var_ref));
        try std.testing.expectEqual(object_steady, js.runtime.gc.liveCountKind(.object));
    }
}

test "parked generator open cell death path reclaims cell and generator together" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const body =
        \\var parkedProbe = (function () {
        \\  function* parkedGen() {
        \\    let captured = 1;
        \\    const bump = () => ++captured;
        \\    yield bump;
        \\    yield captured;
        \\  }
        \\  const it = parkedGen();
        \\  const bump = it.next().value;
        \\  // Frame now parked: `captured`'s open cell owns the generator
        \\  // (attachOpenOwner) while the parked frame owns the cell.
        \\  return "" + bump() + bump();
        \\})();
        \\parkedProbe;
    ;

    // First round reaches steady state (repl bootstrap + lazy generator
    // machinery pin some permanent nodes); later rounds must not grow the
    // live census. See the remove_cycles no-op test above for why forceGC
    // runs from Zig instead of an in-eval $262.gc().
    _ = try js.evalWithOptions(body, .{ .filename = "<repl>" });
    _ = try js.runtime.forceGC(null);
    const cell_steady = js.runtime.gc.liveCountKind(.var_ref);
    const object_steady = js.runtime.gc.liveCountKind(.object);

    // Each round strands a {parked frame -> open cell -> generator owner}
    // ring that dies only via cycle collection: teardown close()s the cell
    // mid-batch and its rc==0 must stay gated (no synchronous destroy of a
    // cycle-owned cell), then the batch frees cell + generator exactly once.
    var round: usize = 0;
    while (round < 4) : (round += 1) {
        const result = try js.evalWithOptions(body, .{ .filename = "<repl>" });
        // Writes through the escaped closure stay visible through the open alias.
        try helpers.expectStringValueBytes(result, "23");
        _ = try js.runtime.forceGC(null);
        try std.testing.expectEqual(cell_steady, js.runtime.gc.liveCountKind(.var_ref));
        try std.testing.expectEqual(object_steady, js.runtime.gc.liveCountKind(.object));
    }
}

test "cycle drain frees leftover-rc rings under repeated forceGC" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const body =
        \\(function () {
        \\  const rings = [];
        \\  for (let i = 0; i < 32; i++) {
        \\    let a = { n: i };
        \\    let b = { peer: a };
        \\    a.peer = b;
        \\    a.self = function () { return a; };
        \\    rings.push(a.self());
        \\  }
        \\  return rings.length;
        \\})();
    ;

    _ = try js.evalWithOptions(body, .{ .filename = "<repl>" });
    _ = try js.runtime.forceGC(null);
    const cell_steady = js.runtime.gc.liveCountKind(.var_ref);
    const object_steady = js.runtime.gc.liveCountKind(.object);
    const fb_steady = js.runtime.gc.liveCountKind(.function_bytecode);

    var round: usize = 0;
    while (round < 8) : (round += 1) {
        const result = try js.evalWithOptions(body, .{ .filename = "<repl>" });
        try std.testing.expectEqual(@as(?i32, 32), result.as(.int));
        _ = try js.runtime.forceGC(null);
        try std.testing.expectEqual(cell_steady, js.runtime.gc.liveCountKind(.var_ref));
        try std.testing.expectEqual(object_steady, js.runtime.gc.liveCountKind(.object));
        try std.testing.expectEqual(fb_steady, js.runtime.gc.liveCountKind(.function_bytecode));
    }
}

test "major tracing keeps a heap BigInt reachable through an object" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    const result = try js.eval(
        \\var live = { x: 0x10000000000000000n };
        \\$262.gc();
        \\assert.sameValue(live.x === 0x10000000000000000n, true);
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "generator continuation keeps its FunctionBytecode alive after every source binding is dropped" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.evalWithOptions(
        \\function* escapeAuditGen() { var a = 10; yield a; yield a + 1; }
        \\async function escapeAuditAsync(x) { return (await x) + 5; }
        \\var it = escapeAuditGen();
        \\var first = it.next().value;
        \\var p = escapeAuditAsync(100);
        \\var escapeAuditAsyncResult;
        \\p.then(function (value) { escapeAuditAsyncResult = value; });
        \\escapeAuditGen = undefined;
        \\escapeAuditAsync = undefined;
        \\$262.gc();
        \\var second = it.next().value;
        \\first * 100 + second;
    , .{ .filename = "<repl>" });
    try std.testing.expectEqual(@as(?i32, 1011), result.as(.int));

    // The async frame was also suspended across the forced collection after
    // its only source-level function binding was cleared. Drain through the
    // existing harness API, then verify its continuation in a second eval.
    try js.runJobs();
    const async_check = try js.eval(
        \\assert.sameValue(escapeAuditAsyncResult, 105);
    );
    try std.testing.expect(async_check.is(.undefined_value));
}

test "initial_yield keeps sync generators in suspended-start after parameter initialization" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\const initialYieldEvents = [];
        \\function* initialYieldGenerator(
        \\  factory = (initialYieldEvents.push("param"), function* () { yield 1; })
        \\) {
        \\  initialYieldEvents.push("body");
        \\  yield factory().next().value;
        \\}
        \\const first = initialYieldGenerator();
        \\assert.sameValue(initialYieldEvents.join(","), "param");
        \\let step = first.next(99);
        \\assert.sameValue(step.value, 1);
        \\assert.sameValue(step.done, false);
        \\assert.sameValue(initialYieldEvents.join(","), "param,body");
        \\assert.sameValue(first.next().done, true);
        \\const returned = initialYieldGenerator();
        \\step = returned.return(9);
        \\assert.sameValue(step.value, 9);
        \\assert.sameValue(step.done, true);
        \\const thrown = initialYieldGenerator();
        \\let caught;
        \\try { thrown.throw(11); } catch (error) { caught = error; }
        \\assert.sameValue(caught, 11);
        \\assert.sameValue(initialYieldEvents.join(","), "param,body,param,param");
    );

    try std.testing.expect(result.is(.undefined_value));
}

test "initial_yield keeps async generators in suspended-start" {
    try helpers.expectPrints(
        \\const asyncInitialYieldEvents = [];
        \\async function* asyncInitialYieldGenerator(
        \\  value = (asyncInitialYieldEvents.push("param"), 3)
        \\) {
        \\  asyncInitialYieldEvents.push("body");
        \\  yield value;
        \\}
        \\const first = asyncInitialYieldGenerator();
        \\print("create", asyncInitialYieldEvents.join(","));
        \\first.next(99).then(function(step) {
        \\  print("next", step.value, step.done, asyncInitialYieldEvents.join(","));
        \\  const returned = asyncInitialYieldGenerator();
        \\  return returned.return(9);
        \\}).then(function(step) {
        \\  print("return", step.value, step.done, asyncInitialYieldEvents.join(","));
        \\  const thrown = asyncInitialYieldGenerator();
        \\  return thrown.throw(11).then(function() {
        \\    print("throw resolved");
        \\  }, function(reason) {
        \\    print("throw", reason, asyncInitialYieldEvents.join(","));
        \\  });
        \\});
    , "create param\n" ++
        "next 3 false param,body\n" ++
        "return 9 true param,body,param\n" ++
        "throw 11 param,body,param,param\n");
}

test "initial_yield executes exported generator bytecode in module mode" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.evalModule(
        \\const moduleInitialYieldEvents = [];
        \\export function* moduleInitialYieldGenerator(
        \\  value = (moduleInitialYieldEvents.push("param"), 4)
        \\) {
        \\  moduleInitialYieldEvents.push("body");
        \\  yield value;
        \\}
        \\const iterator = moduleInitialYieldGenerator();
        \\assert.sameValue(moduleInitialYieldEvents.join(","), "param");
        \\const step = iterator.next();
        \\assert.sameValue(step.value, 4);
        \\assert.sameValue(step.done, false);
        \\assert.sameValue(moduleInitialYieldEvents.join(","), "param,body");
    );

    try std.testing.expect(result.is(.undefined_value));
}

test "generator completion resumes keep the original function home object" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\class Base {
        \\  get marker() { return 41; }
        \\}
        \\class Derived extends Base {
        \\  *viaReturn() {
        \\    try { yield 0; }
        \\    finally { yield super.marker; }
        \\  }
        \\  *viaThrow() {
        \\    try { yield 0; }
        \\    catch (value) { yield super.marker + value; }
        \\  }
        \\  *viaYieldStar() {
        \\    yield* [0];
        \\    return super.marker;
        \\  }
        \\}
        \\const instance = new Derived();
        \\const returned = instance.viaReturn();
        \\assert.sameValue(returned.next().value, 0);
        \\let step = returned.return(99);
        \\assert.sameValue(step.value, 41);
        \\assert.sameValue(step.done, false);
        \\step = returned.next();
        \\assert.sameValue(step.value, 99);
        \\assert.sameValue(step.done, true);
        \\const thrown = instance.viaThrow();
        \\assert.sameValue(thrown.next().value, 0);
        \\step = thrown.throw(1);
        \\assert.sameValue(step.value, 42);
        \\assert.sameValue(step.done, false);
        \\assert.sameValue(thrown.next().done, true);
        \\const delegated = instance.viaYieldStar();
        \\assert.sameValue(delegated.next().value, 0);
        \\step = delegated.next();
        \\assert.sameValue(step.value, 41);
        \\assert.sameValue(step.done, true);
    );

    try std.testing.expect(result.is(.undefined_value));
}

test "resident generator resumes preserve nested catch and finally targets" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\function* afterNested() {
        \\  try {
        \\    yield 1;
        \\    try { yield 2; throw 3; } catch (error) { yield error; }
        \\    yield 4;
        \\  } finally { yield 5; }
        \\}
        \\let iterator = afterNested();
        \\assert.sameValue(iterator.next().value, 1);
        \\assert.sameValue(iterator.next().value, 2);
        \\assert.sameValue(iterator.next().value, 3);
        \\assert.sameValue(iterator.next().value, 4);
        \\assert.sameValue(iterator.throw(6).value, 5);
        \\let caught;
        \\try { iterator.next(); } catch (error) { caught = error; }
        \\assert.sameValue(caught, 6);
        \\function* beforeNested() {
        \\  try {
        \\    yield 1;
        \\    try { yield 2; } catch (error) { yield error; }
        \\  } finally { yield 3; }
        \\}
        \\iterator = beforeNested();
        \\assert.sameValue(iterator.next().value, 1);
        \\assert.sameValue(iterator.throw(7).value, 3);
        \\try { iterator.next(); } catch (error) { caught = error; }
        \\assert.sameValue(caught, 7);
        \\function* plainFinally() {
        \\  try { yield 1; } finally { yield 2; }
        \\}
        \\iterator = plainFinally();
        \\assert.sameValue(iterator.next().value, 1);
        \\assert.sameValue(iterator.throw(8).value, 2);
        \\try { iterator.next(); } catch (error) { caught = error; }
        \\assert.sameValue(caught, 8);
        \\function* inner() { return yield 1; }
        \\function* delegate(iterable) { return yield* iterable; }
        \\iterator = delegate(inner());
        \\assert.sameValue(iterator.next().value, 1);
        \\try { iterator.throw(9); } catch (error) { caught = error; }
        \\assert.sameValue(caught, 9);
        \\let delegateReturnCount = 0;
        \\const missingThrow = {
        \\  [Symbol.iterator]() { return this; },
        \\  next() { return { value: 10, done: false }; },
        \\  return() { delegateReturnCount++; return { done: true }; },
        \\};
        \\function* catchYieldStarHostError() {
        \\  try { yield* missingThrow; }
        \\  catch (error) { yield error instanceof TypeError; }
        \\}
        \\iterator = catchYieldStarHostError();
        \\assert.sameValue(iterator.next().value, 10);
        \\assert.sameValue(iterator.throw(11).value, true);
        \\assert.sameValue(delegateReturnCount, 1);
        \\assert.sameValue(iterator.next().done, true);
    );

    try std.testing.expect(result.is(.undefined_value));
}

test "surviving var references keep resident local slots bare" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    _ = try js.eval(
        \\function* referenceStorage(scope) {
        \\  var target;
        \\  with (scope) { target = 41; }
        \\  yield target;
        \\  target += 1;
        \\  return target;
        \\}
        \\globalThis.__referenceStorage = referenceStorage({});
        \\__referenceStorage.next();
    );

    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const key = try js.runtime.internAtom("__referenceStorage");
    const value = try global.getProperty(key);
    const generator = try property_ops.expectObject(value);
    const function_value = generator.generatorFunctionBytecode() orelse return error.TypeError;
    const function = engine.exec.call_runtime.functionBytecodeFromValue(function_value) orelse return error.TypeError;
    const target_idx = localIndexNamed(js.runtime, function, "target") orelse return error.TypeError;
    const state = generator.generatorExecutionState();

    try std.testing.expect(function.openVarRefCount() > 0);
    try std.testing.expect(function.varDefs()[target_idx].isCaptured());
    try std.testing.expect(!function.varDefs()[target_idx].isLexical());
    try std.testing.expectEqual(@as(?i32, 41), state.storage.frame.locals[target_idx].as(.int));
    try std.testing.expect(core.VarRef.fromValue(state.storage.frame.locals[target_idx]) == null);
    var found_open_alias = false;
    for (state.storage.frame.open_var_refs) |maybe_ref| {
        const ref = maybe_ref orelse continue;
        if (ref.is_open and ref.pvalue == &state.storage.frame.locals[target_idx]) found_open_alias = true;
    }
    try std.testing.expect(found_open_alias);

    const completion = try js.eval(
        \\const step = __referenceStorage.next();
        \\assert.sameValue(step.value, 42);
        \\assert.sameValue(step.done, true);
    );
    try std.testing.expect(completion.is(.undefined_value));
}

test "direct eval captures only bindings visible at its call scope" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    _ = try js.eval(
        \\function* scopedEvalStorage() {
        \\  { let sibling = 10; globalThis.__siblingValue = sibling; }
        \\  var visible = 1;
        \\  { let active = 2; eval("visible = active"); yield visible; }
        \\}
        \\globalThis.__scopedEvalStorage = scopedEvalStorage();
    );

    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const key = try js.runtime.internAtom("__scopedEvalStorage");
    const value = try global.getProperty(key);
    const generator = try property_ops.expectObject(value);
    const function_value = generator.generatorFunctionBytecode() orelse return error.TypeError;
    const function = engine.exec.call_runtime.functionBytecodeFromValue(function_value) orelse return error.TypeError;
    const sibling_idx = localIndexNamed(js.runtime, function, "sibling") orelse return error.TypeError;
    const visible_idx = localIndexNamed(js.runtime, function, "visible") orelse return error.TypeError;
    const active_idx = localIndexNamed(js.runtime, function, "active") orelse return error.TypeError;

    try std.testing.expect(!function.varDefs()[sibling_idx].isCaptured());
    try std.testing.expect(function.varDefs()[visible_idx].isCaptured());
    try std.testing.expect(function.varDefs()[active_idx].isCaptured());
    try std.testing.expect(function.localOpenBindingIndex(sibling_idx) == null);
    try std.testing.expect(function.localOpenBindingIndex(visible_idx) != null);
    try std.testing.expect(function.localOpenBindingIndex(active_idx) != null);
}

test "suspended generators retain one resident execution owner across resumes" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.eval(
        \\function* residentGenerator(argument) {
        \\  let local = { local: true };
        \\  try {
        \\    yield local;
        \\    yield argument;
        \\  } catch (error) {
        \\    yield error;
        \\  }
        \\}
        \\globalThis.__residentGenerator = residentGenerator({ argument: true });
        \\let first = __residentGenerator.next();
        \\assert.sameValue(first.value.local, true);
        \\assert.sameValue(first.done, false);
        \\let second = __residentGenerator.next();
        \\assert.sameValue(second.value.argument, true);
        \\assert.sameValue(second.done, false);
    );
    try std.testing.expect(result.is(.undefined_value));

    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const key = try js.runtime.internAtom("__residentGenerator");
    const value = try global.getProperty(key);
    const generator = try property_ops.expectObject(value);
    const generator_function = generator.generatorFunctionBytecode() orelse return error.TypeError;
    try std.testing.expect(inline_calls.resolveInlineTarget(
        global,
        core.JSValue.undefinedValue(),
        generator_function,
    ) == null);
    const state = generator.generatorExecutionState();
    try std.testing.expect(!generator.generatorDone());
    try std.testing.expect(state.has_frame);
    try std.testing.expect(!state.running_aliases);
    try std.testing.expect(state.resident_storage_owner);
    try std.testing.expect(state.catchTarget() != null);
    try std.testing.expect(generator.generatorStackUsesCombinedStorage());
    try std.testing.expect(generator.generatorFrameUsesCombinedStorage());
    try std.testing.expect(state.storage.frame.args.len != 0);
    try std.testing.expect(state.storage.frame.locals.len != 0);
    const completion = try js.eval(
        \\let finalStep = __residentGenerator.next();
        \\assert.sameValue(finalStep.value, undefined);
        \\assert.sameValue(finalStep.done, true);
    );
    try std.testing.expect(completion.is(.undefined_value));
    try std.testing.expect(generator.generatorDone());
    try std.testing.expect(!generator.generatorExecutionState().has_frame);
    try std.testing.expect(generator.generatorExecutionState().storage.isEmpty());
}

test "completed generators eagerly release their resident execution state" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    _ = try js.eval(
        \\function make(captured) {
        \\  return function* generator(argument) { yield captured; return argument; };
        \\}
        \\const generator = make({ captured: true });
        \\globalThis.__returnedGenerator = generator.call({ receiver: true }, { argument: true });
        \\let step = __returnedGenerator.return(7);
        \\assert.sameValue(step.value, 7);
        \\assert.sameValue(step.done, true);
        \\step = __returnedGenerator.next();
        \\assert.sameValue(step.value, undefined);
        \\assert.sameValue(step.done, true);
        \\step = __returnedGenerator.return(8);
        \\assert.sameValue(step.value, 8);
        \\assert.sameValue(step.done, true);
        \\let thrown;
        \\try { __returnedGenerator.throw(9); } catch (value) { thrown = value; }
        \\assert.sameValue(thrown, 9);
        \\globalThis.__normallyCompletedGenerator = generator({ argument: true });
        \\__normallyCompletedGenerator.next();
        \\step = __normallyCompletedGenerator.next();
        \\assert.sameValue(step.done, true);
        \\globalThis.__thrownGenerator = generator({ argument: true });
        \\try { __thrownGenerator.throw(10); } catch (value) { thrown = value; }
        \\assert.sameValue(thrown, 10);
    );

    const global = try engine.exec.zjs_vm.contextGlobal(js.context);
    const names = [_][]const u8{
        "__returnedGenerator",
        "__normallyCompletedGenerator",
        "__thrownGenerator",
    };
    for (names) |name| {
        const key = try js.runtime.internAtom(name);
        const value = try global.getProperty(key);
        const generator_object = try property_ops.expectObject(value);
        try std.testing.expect(generator_object.generatorDone());
        try std.testing.expect(!generator_object.generatorExecutionState().has_frame);
        try std.testing.expect(generator_object.generatorExecutionState().storage.isEmpty());
        try std.testing.expectEqual(@as(usize, 0), generator_object.generatorPc());
        try std.testing.expectEqual(@as(usize, 0), generator_object.generatorArgs().len);
        try std.testing.expectEqual(@as(usize, 0), generator_object.generatorCaptures().len);
        try std.testing.expect(generator_object.generatorThis() == null);
        try std.testing.expect(generator_object.generatorCurrentFunction() == null);
    }
}

test "iterator helper method marker is internal" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [1024]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function printLayout(label, helper) {
        \\  var proto = Object.getPrototypeOf(helper);
        \\  print(label);
        \\  print(Object.prototype.toString.call(helper));
        \\  print("own:" + Object.getOwnPropertyNames(helper).join(","));
        \\  print("proto:" + Object.getOwnPropertyNames(proto).join(","));
        \\  print(helper.hasOwnProperty("next"));
        \\  print(typeof proto.next);
        \\  print(helper.next === proto.next);
        \\}
        \\function check(fn, marker, run) {
        \\  print(marker in fn);
        \\  print(Object.getOwnPropertyDescriptor(fn, marker) === undefined);
        \\  fn[marker] = 0;
        \\  print(marker in fn);
        \\  print(run());
        \\  print(delete fn[marker]);
        \\  print(marker in fn);
        \\  print(run());
        \\}
        \\var helper = Iterator.from([1]).map(function(x) { return x + 1; });
        \\printLayout("map", helper);
        \\printLayout("concat", Iterator.concat([1]));
        \\printLayout("zip", Iterator.zip([[1], [2]]));
        \\var next = helper.next;
        \\check(next, "__zjs_iterator_helper_method", function() {
        \\  var h = Iterator.from([1]).map(function(x) { return x + 1; });
        \\  return next.call(h).value;
        \\});
    , &stream);

    try std.testing.expect(result.is(.undefined_value));
    try std.testing.expectEqualStrings(
        "map\n[object Iterator Helper]\nown:\nproto:next,return\nfalse\nfunction\ntrue\n" ++
            "concat\n[object Iterator Helper]\nown:\nproto:next,return\nfalse\nfunction\ntrue\n" ++
            "zip\n[object Iterator Helper]\nown:\nproto:next,return\nfalse\nfunction\ntrue\n" ++
            "false\ntrue\ntrue\n2\ntrue\nfalse\n2\n",
        stream.buffered(),
    );
}

test "Iterator.from follows QuickJS wrapper selection" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\var count = 0;
        \\var iterable = {
        \\  [Symbol.iterator]: function() { return this; },
        \\  get next() {
        \\    count++;
        \\    return function() { return { done: true, value: 1 }; };
        \\  },
        \\};
        \\var fromIterable = Iterator.from(iterable);
        \\print(fromIterable === iterable);
        \\print(count);
        \\fromIterable.next();
        \\print(count);
        \\print(typeof fromIterable.map);
        \\var sealed = Object.preventExtensions({
        \\  next: function() { return { done: true }; },
        \\});
        \\var wrapped = Iterator.from(sealed);
        \\print(wrapped === sealed);
        \\var wrapProto = Object.getPrototypeOf(wrapped);
        \\print("__zjs_iterator_wrap_method" in wrapProto.next);
        \\print(Object.getOwnPropertyDescriptor(wrapProto.next, "__zjs_iterator_wrap_method") === undefined);
        \\print("__zjs_iterator_wrap_method" in wrapProto.return);
        \\print(Object.getOwnPropertyDescriptor(wrapProto.return, "__zjs_iterator_wrap_method") === undefined);
        \\wrapProto.next.__zjs_iterator_wrap_method = 2;
        \\print(wrapped.next().done);
        \\print(wrapped.next().value);
        \\print(delete wrapProto.next.__zjs_iterator_wrap_method);
        \\print(wrapped.next().value);
        \\wrapProto.return.__zjs_iterator_wrap_method = 1;
        \\print(wrapped.return().done);
        \\print(delete wrapProto.return.__zjs_iterator_wrap_method);
        \\print(wrapped.return().done);
        \\print("__zjs_iterator_next" in wrapped);
        \\print(Object.getOwnPropertyDescriptor(wrapped, "__zjs_iterator_next") === undefined);
        \\wrapped.__zjs_iterator_next = function() { return { done: false, value: 99 }; };
        \\print(wrapped.next().value);
        \\print(delete wrapped.__zjs_iterator_next);
        \\print("__zjs_iterator_next" in wrapped);
        \\var bad = Iterator.from({ next: 1 });
        \\print(typeof bad);
        \\try {
        \\  bad.next();
        \\} catch (e) {
        \\  print(e.name);
        \\}
    , &stream);

    try std.testing.expect(result.is(.undefined_value));
    // The first four values changed on 2026-08-21. They used to read
    // "true, 0, undefined" — the source returned unwrapped, its `next` getter
    // never read, and no iterator helpers on the result — and this test pinned
    // that as QuickJS parity. It was not: the pinned QuickJS prints
    // "false, 1, 1, function" for this exact snippet, and so does the spec.
    // Iterator.from must test %Iterator%-instance-hood on the RESOLVED
    // iterator, which this shape fails, so it gets a wrapper.
    try std.testing.expectEqualStrings("false\n1\n1\nfunction\nfalse\nfalse\ntrue\nfalse\ntrue\ntrue\nundefined\ntrue\nundefined\ntrue\ntrue\ntrue\nfalse\ntrue\nundefined\ntrue\nfalse\nobject\nTypeError\n", stream.buffered());
}

test "number native builtin records cover static and prototype dispatch" {
    var host = try BareRuntime.init(.{});
    defer host.deinit();
    const rt = host.rt;
    const ctx = host.ctx;
    const global = host.global;

    const prototype_key = core.atom.ids.prototype;

    const number_object = try getGlobalObject(rt, global, "Number");

    const is_integer_object = try getGlobalObject(rt, number_object, "isInteger");
    try std.testing.expect(is_integer_object.nativeFunctionIdSlot().* != 0);

    const fake_static = try engine.core.function.nativeFunction(ctx, "notNumberIsInteger", 1);
    const fake_static_object = core.Object.fromHeader(fake_static.refHeader().?);
    fake_static_object.nativeFunctionIdSlot().* = is_integer_object.nativeFunctionIdSlot().*;
    const static_dispatch_name = try engine.exec.call.nativeFunctionNameForVm(rt, fake_static_object);
    defer rt.nativeAllocator().free(static_dispatch_name);
    try std.testing.expectEqualStrings("notNumberIsInteger", static_dispatch_name);
    const static_args = [_]core.JSValue{core.JSValue.float64(3.5)};
    const static_result = try engine.exec.call_runtime.callValueOrBytecodeRoot(ctx, null, global, core.JSValue.undefinedValue(), fake_static, &static_args, null, null);
    try std.testing.expectEqual(false, static_result.as(.boolean).?);

    const prototype_value = try number_object.getProperty(prototype_key);
    const prototype_object = core.Object.fromHeader(prototype_value.refHeader().?);
    const to_fixed_object = try getGlobalObject(rt, prototype_object, "toFixed");
    try std.testing.expect(to_fixed_object.nativeFunctionIdSlot().* != 0);

    const fake_proto = try engine.core.function.nativeFunction(ctx, "notNumberToFixed", 1);
    const fake_proto_object = core.Object.fromHeader(fake_proto.refHeader().?);
    fake_proto_object.nativeFunctionIdSlot().* = to_fixed_object.nativeFunctionIdSlot().*;
    const proto_dispatch_name = try engine.exec.call.nativeFunctionNameForVm(rt, fake_proto_object);
    defer rt.nativeAllocator().free(proto_dispatch_name);
    try std.testing.expectEqualStrings("notNumberToFixed", proto_dispatch_name);
    const fixed_args = [_]core.JSValue{core.JSValue.int32(2)};
    const proto_result = try engine.exec.call_runtime.callValueOrBytecodeRoot(ctx, null, global, core.JSValue.float64(1.25), fake_proto, &fixed_args, null, null);
    const proto_string = proto_result.asStringBody().?;
    try std.testing.expect(proto_string.eqlBytes("1.25"));

    const fake_static_key = try rt.internAtom("fakeStatic");
    try global.defineOwnProperty(rt, fake_static_key, core.Descriptor.data(fake_static, .method));
    const fake_proto_key = try rt.internAtom("fakeProto");
    try global.defineOwnProperty(rt, fake_proto_key, core.Descriptor.data(fake_proto, .method));

    var parsed = try engine.parser.compile(.{ .realm = ctx }, "print(fakeStatic(3.5)); print(fakeProto.call(1.25, 2));", .{ .mode = .script, .filename = "number-native-record-dispatch.js" });
    defer parsed.deinit();
    var output_buffer: [32]u8 = undefined;
    const function = parsed.functionBytecode() orelse return error.TestExpectedEqual;
    const vm_result = try host.run(function, &output_buffer);
    try std.testing.expect(vm_result.value.is(.undefined_value));
    try std.testing.expectEqualStrings("false\n1.25\n", vm_result.output);
}

test "string static native builtin records ignore dispatch names" {
    var host = try BareRuntime.init(.{});
    defer host.deinit();
    const rt = host.rt;
    const ctx = host.ctx;
    const global = host.global;

    const string_key = try rt.internAtom("String");
    const string_value = try global.getProperty(string_key);
    const string_object = core.Object.fromHeader(string_value.refHeader().?);
    const from_code_point_object = try getGlobalObject(rt, string_object, "fromCodePoint");
    try std.testing.expect(from_code_point_object.nativeFunctionIdSlot().* != 0);

    const fake = try engine.core.function.nativeFunction(ctx, "notStringFromCodePoint", 1);
    const fake_object = core.Object.fromHeader(fake.refHeader().?);
    fake_object.nativeFunctionIdSlot().* = from_code_point_object.nativeFunctionIdSlot().*;
    const dispatch_name = try engine.exec.call.nativeFunctionNameForVm(rt, fake_object);
    defer rt.nativeAllocator().free(dispatch_name);
    try std.testing.expectEqualStrings("notStringFromCodePoint", dispatch_name);

    const args = [_]core.JSValue{core.JSValue.int32(0x41)};
    const result = try engine.exec.call_runtime.callValueOrBytecodeRoot(ctx, null, global, core.JSValue.undefinedValue(), fake, &args, null, null);
    const result_string = result.asStringBody().?;
    try std.testing.expect(result_string.eqlBytes("A"));

    const fake_key = try rt.internAtom("fakeStringStatic");
    try global.defineOwnProperty(rt, fake_key, core.Descriptor.data(fake, .method));

    var parsed = try engine.parser.compile(.{ .realm = ctx }, "print(fakeStringStatic({ valueOf: function(){ return 0x42; } }));", .{ .mode = .script, .filename = "string-static-native-record-dispatch.js" });
    defer parsed.deinit();
    var output_buffer: [8]u8 = undefined;
    const function = parsed.functionBytecode() orelse return error.TestExpectedEqual;
    const vm_result = try host.run(function, &output_buffer);
    try std.testing.expect(vm_result.value.is(.undefined_value));
    try std.testing.expectEqualStrings("B\n", vm_result.output);
}

test "string prototype native builtin records ignore dispatch names" {
    var host = try BareRuntime.init(.{});
    defer host.deinit();
    const rt = host.rt;
    const ctx = host.ctx;
    const global = host.global;

    const string_key = try rt.internAtom("String");
    const string_value = try global.getProperty(string_key);
    const string_object = core.Object.fromHeader(string_value.refHeader().?);
    const prototype_value = try string_object.getProperty(core.atom.ids.prototype);
    const prototype_object = core.Object.fromHeader(prototype_value.refHeader().?);
    const index_of_object = try getGlobalObject(rt, prototype_object, "indexOf");
    try std.testing.expect(index_of_object.nativeFunctionIdSlot().* != 0);

    const fake = try engine.core.function.nativeFunction(ctx, "notStringIndexOf", 1);
    const fake_object = core.Object.fromHeader(fake.refHeader().?);
    fake_object.nativeFunctionIdSlot().* = index_of_object.nativeFunctionIdSlot().*;
    const dispatch_name = try engine.exec.call.nativeFunctionNameForVm(rt, fake_object);
    defer rt.nativeAllocator().free(dispatch_name);
    try std.testing.expectEqualStrings("notStringIndexOf", dispatch_name);

    const needle_string = try core.string.String.createUtf8(rt, "n");
    const receiver_string = try core.string.String.createUtf8(rt, "banana");
    const direct_args = [_]core.JSValue{ needle_string.value(), core.JSValue.int32(3) };
    const direct_result = try engine.exec.call_runtime.callValueOrBytecodeRoot(ctx, null, global, receiver_string.value(), fake, &direct_args, null, null);
    try std.testing.expectEqual(@as(i32, 4), direct_result.as(.int).?);

    const fake_key = try rt.internAtom("fakeStringIndexOf");
    try global.defineOwnProperty(rt, fake_key, core.Descriptor.data(fake, .method));

    var parsed = try engine.parser.compile(.{ .realm = ctx }, "print(fakeStringIndexOf.call('banana', 'n', { valueOf: function(){ return 3; } }));", .{ .mode = .script, .filename = "string-prototype-native-record-dispatch.js" });
    defer parsed.deinit();
    var output_buffer: [8]u8 = undefined;
    const function = parsed.functionBytecode() orelse return error.TestExpectedEqual;
    const vm_result = try host.run(function, &output_buffer);
    try std.testing.expect(vm_result.value.is(.undefined_value));
    try std.testing.expectEqualStrings("4\n", vm_result.output);
}

test "String case conversion records preserve coercion and Unicode semantics" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var hints = [];
        \\var receiver = {};
        \\receiver[Symbol.toPrimitive] = function(hint) {
        \\    hints.push(hint);
        \\    return "aßΣ";
        \\};
        \\assert.sameValue(String.prototype.toUpperCase.call(receiver), "ASSΣ");
        \\assert.sameValue(hints.join(","), "string");
        \\assert.sameValue("AΣ".toLowerCase(), "aς");
        \\assert.sameValue("AΣA".toLowerCase(), "aσa");
        \\assert.sameValue("\uD801\uDC28".toUpperCase(), "\uD801\uDC00");
        \\assert.sameValue(String.prototype.toLowerCase.call(new String("ABC")), "abc");
        \\var upper = String.prototype.toUpperCase;
        \\Object.defineProperty(upper, "name", { value: "renamed" });
        \\assert.sameValue(upper.call("ab"), "AB");
        \\assert.throws(TypeError, function() {
        \\    String.prototype.toUpperCase.call(Symbol("x"));
        \\});
        \\var other = $262.createRealm().global;
        \\assert.throws(other.TypeError, function() {
        \\    other.String.prototype.toUpperCase.call(Symbol("x"));
        \\});
    );

    const pure_source = try core.string.String.createUtf8(js.runtime, "ABC");
    const pure_result = try engine.exec.string_ops.unicodeCaseString(js.runtime, pure_source.value(), true);
    try std.testing.expect((pure_result.asStringBody() orelse return error.TestUnexpectedResult).eqlBytes("abc"));

    try std.testing.expect(result.is(.undefined_value));
}

test "date static native builtin records ignore dispatch names" {
    var host = try BareRuntime.init(.{});
    defer host.deinit();
    const rt = host.rt;
    const ctx = host.ctx;
    const global = host.global;

    const date_key = try rt.internAtom("Date");
    const date_value = try global.getProperty(date_key);
    const date_object = core.Object.fromHeader(date_value.refHeader().?);
    const utc_object = try getGlobalObject(rt, date_object, "UTC");
    try std.testing.expect(utc_object.nativeFunctionIdSlot().* != 0);

    const fake = try engine.core.function.nativeFunction(ctx, "notDateUTC", 7);
    const fake_object = core.Object.fromHeader(fake.refHeader().?);
    fake_object.nativeFunctionIdSlot().* = utc_object.nativeFunctionIdSlot().*;
    const dispatch_name = try engine.exec.call.nativeFunctionNameForVm(rt, fake_object);
    defer rt.nativeAllocator().free(dispatch_name);
    try std.testing.expectEqualStrings("notDateUTC", dispatch_name);

    const args = [_]core.JSValue{ core.JSValue.int32(2024), core.JSValue.int32(0), core.JSValue.int32(1) };
    const result = try engine.exec.call_runtime.callValueOrBytecodeRoot(ctx, null, global, core.JSValue.undefinedValue(), fake, &args, null, null);
    try std.testing.expectEqual(@as(f64, 1704067200000), engine.exec.value_ops.numberValue(result).?);

    const fake_key = try rt.internAtom("fakeDateUTC");
    try global.defineOwnProperty(rt, fake_key, core.Descriptor.data(fake, .method));

    var parsed = try engine.parser.compile(.{ .realm = ctx }, "print(fakeDateUTC({ valueOf: function(){ return 2024; } }, 0, 1));", .{ .mode = .script, .filename = "date-static-native-record-dispatch.js" });
    defer parsed.deinit();
    var output_buffer: [24]u8 = undefined;
    const function = parsed.functionBytecode() orelse return error.TestExpectedEqual;
    const vm_result = try host.run(function, &output_buffer);
    try std.testing.expect(vm_result.value.is(.undefined_value));
    try std.testing.expectEqualStrings("1704067200000\n", vm_result.output);
}

test "date constructor native builtin records ignore dispatch names" {
    var host = try BareRuntime.init(.{});
    defer host.deinit();
    const rt = host.rt;
    const ctx = host.ctx;
    const global = host.global;
    ctx.global = global;

    const date_key = try rt.internAtom("Date");
    const date_value = try global.getProperty(date_key);
    const date_object = core.Object.fromHeader(date_value.refHeader().?);
    try std.testing.expect(date_object.nativeFunctionIdSlot().* != 0);

    const fake = try engine.core.function.nativeFunction(ctx, "notDateConstructor", 7);
    const fake_object = core.Object.fromHeader(fake.refHeader().?);
    fake_object.nativeFunctionIdSlot().* = date_object.nativeFunctionIdSlot().*;
    // [[Construct]] dispatches on the constructor kind installed with the id.
    fake_object.setNativeConstructorKind(date_object.nativeConstructorKind());
    const dispatch_name = try engine.exec.call.nativeFunctionNameForVm(rt, fake_object);
    defer rt.nativeAllocator().free(dispatch_name);
    try std.testing.expectEqualStrings("notDateConstructor", dispatch_name);

    const prototype_value = try date_object.getProperty(core.atom.ids.prototype);
    try fake_object.defineOwnProperty(rt, core.atom.ids.prototype, core.Descriptor.data(prototype_value, .method));

    const call_result = try engine.exec.call_runtime.callValueOrBytecodeRoot(ctx, null, global, core.JSValue.undefinedValue(), fake, &.{}, null, null);
    var call_buffer = std.ArrayList(u8).empty;
    defer call_buffer.deinit(rt.nativeAllocator());
    try engine.exec.value_ops.appendRawString(rt, &call_buffer, call_result);
    // Local-time toString shape (offset varies with the host timezone).
    try std.testing.expect(std.mem.indexOf(u8, call_buffer.items, "GMT+") != null or
        std.mem.indexOf(u8, call_buffer.items, "GMT-") != null);

    const construct_result = try engine.exec.call_runtime.constructValueOrBytecode(
        ctx,
        null,
        global,
        fake,
        &.{core.JSValue.int32(1)},
        null,
        null,
    );
    const construct_ms = try engine.exec.date_ops.methodCall(rt, construct_result, .get_time);
    try std.testing.expectEqual(@as(f64, 1), engine.exec.value_ops.numberValue(construct_ms).?);

    const fake_key = try rt.internAtom("fakeDateConstructor");
    try global.defineOwnProperty(rt, fake_key, core.Descriptor.data(fake, .method));

    var parsed = try engine.parser.compile(.{ .realm = ctx },
        \\const d = new fakeDateConstructor({ valueOf: function(){ return 2; } });
        \\print(d instanceof Date);
        \\print(d.getTime());
        \\print(fakeDateConstructor().indexOf('GMT') >= 0);
        \\print(Reflect.construct(fakeDateConstructor, [3], Date).getTime());
    , .{ .mode = .script, .filename = "date-constructor-native-record-dispatch.js" });
    defer parsed.deinit();
    var output_buffer: [64]u8 = undefined;
    const function = parsed.functionBytecode() orelse return error.TestExpectedEqual;
    const vm_result = try host.run(function, &output_buffer);
    try std.testing.expect(vm_result.value.is(.undefined_value));
    try std.testing.expectEqualStrings("true\n2\ntrue\n3\n", vm_result.output);
}

test "AggregateError construct releases copied errors array owner" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();
    const global = try core.Object.create(rt, core.class.ids.object, null);
    _ = try global.ensureRealmPayload(rt);
    var realm_global_slot: ?*core.Object = global;
    var realm_roots = core.runtime.rootObjects(.{&realm_global_slot});
    realm_roots.activate(rt);
    defer realm_roots.deactivate(rt);

    try ctx.installStandardGlobals(global);
    ctx.global = global;

    const constructor = try global.getProperty(try rt.internAtom("AggregateError"));

    const source = try core.Object.createArray(rt, null);
    const array_ctor = helpers.objectFromValue(try global.getProperty(try rt.internAtom("Array")));
    try source.setPrototype(rt, helpers.objectFromValue(try array_ctor.getProperty(core.atom.ids.prototype)));
    try source.defineOwnProperty(rt, core.Atom.taggedInt(0), core.Descriptor.data(core.JSValue.int32(1), .all));
    try source.defineOwnProperty(rt, core.Atom.taggedInt(1), core.Descriptor.data(core.JSValue.int32(2), .all));
    source.setArrayLength(2);
    try source.defineOwnProperty(rt, core.atom.ids.length, core.Descriptor.data(core.JSValue.int32(2), .{ .writable = true }));

    // `constructor` and `source` are held only by Zig locals (no heap edge).
    // RC's cycle removal never touched rc-held stack objects, but the tracing
    // collector treats the same call as a whole-heap mark-sweep with declared
    // roots only — name them, or the sweep reclaims live test state.
    var constructor_slot: ?*core.Object = helpers.objectFromValue(constructor);
    var source_slot: ?*core.Object = source;
    var live_roots = core.runtime.rootObjects(.{ &constructor_slot, &source_slot });
    live_roots.activate(rt);
    defer live_roots.deactivate(rt);

    const ConstructOnce = struct {
        noinline fn run(c: *core.JSContext, g: *core.Object, ctor: core.JSValue, src: core.JSValue) !void {
            var constructed = try engine.exec.call_runtime.constructValueOrBytecode(c, null, g, ctor, &.{src}, null, null);
            constructed = core.JSValue.undefinedValue();
        }
    };

    // Warm interned stack / shape objects from the first formal construct.
    try ConstructOnce.run(ctx, global, constructor, source.value());
    _ = try rt.collectForTest();
    const baseline_objects = rt.gc.liveCountKind(.object);
    try ConstructOnce.run(ctx, global, constructor, source.value());
    _ = try rt.collectForTest();

    try std.testing.expectEqual(baseline_objects, rt.gc.liveCountKind(.object));
}

test "construct prefix runs before prototype Get for Number WeakRef FinalizationRegistry Iterator" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();
    _ = try js.eval(
        \\function probe(ctor, args) {
        \\  let got = false;
        \\  const P = new Proxy(ctor, {
        \\    get(t, k, r) {
        \\      if (k === "prototype") got = true;
        \\      return Reflect.get(t, k, r);
        \\    }
        \\  });
        \\  try { new P(...args); } catch (e) {}
        \\  return got;
        \\}
        \\assert.sameValue(probe(Number, [Symbol()]), false);
        \\assert.sameValue(probe(Number, [3]), true);
        \\assert.sameValue(probe(WeakRef, [1]), false);
        \\assert.sameValue(probe(WeakRef, [{}]), true);
        \\assert.sameValue(probe(FinalizationRegistry, [1]), false);
        \\assert.sameValue(probe(FinalizationRegistry, [function() {}]), true);
        \\try { new Iterator(); throw new Error("unreachable"); } catch (e) {
        \\  assert.sameValue(e instanceof TypeError, true);
        \\}
        \\class SubIterator extends Iterator { constructor() { super(); } }
        \\const it = new SubIterator();
        \\assert.sameValue(Object.getPrototypeOf(it), SubIterator.prototype);
        \\const a = new Uint8Array([1, 2, 3]);
        \\const b = new Uint8Array(a);
        \\assert.sameValue(a.buffer === b.buffer, false);
        \\assert.sameValue(Array.prototype.join.call(b, ","), "1,2,3");
        \\const c = new Uint8Array(new Uint16Array([256, 1]));
        \\assert.sameValue(Array.prototype.join.call(c, ","), "0,1");
    );
}

test "Proxy construct does not Get prototype for foreign newTarget or illegal args" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();
    _ = try js.eval(
        \\function probe(ctor, args) {
        \\  let got = false;
        \\  const P = new Proxy(ctor, {
        \\    get(t, k, r) {
        \\      if (k === "prototype") got = true;
        \\      return Reflect.get(t, k, r);
        \\    }
        \\  });
        \\  try { new P(...args); } catch (e) {}
        \\  return got;
        \\}
        \\assert.sameValue(probe(Proxy, [{}, {}]), false);
        \\assert.sameValue(probe(Proxy, [1, {}]), false);
        \\assert.sameValue(probe(Proxy, []), false);
        \\function NT() {}
        \\const legal = Reflect.construct(Proxy, [{}, {}], NT);
        \\assert.sameValue(typeof legal, "object");
        \\try { Reflect.construct(Proxy, [1, {}], NT); throw new Error("unreachable"); } catch (e) {
        \\  assert.sameValue(e instanceof TypeError, true);
        \\}
        \\let got = false;
        \\function NTget() {}
        \\const nt = new Proxy(NTget, {
        \\  get(t, k, r) {
        \\    if (k === "prototype") got = true;
        \\    return Reflect.get(t, k, r);
        \\  }
        \\});
        \\try { Reflect.construct(Proxy, [1, {}], nt); } catch (e) {}
        \\assert.sameValue(got, false);
        \\got = false;
        \\try { Reflect.construct(Proxy, [{}, {}], nt); } catch (e) {}
        \\assert.sameValue(got, false);
    );
}

test "date prototype native builtin records ignore dispatch names" {
    var host = try BareRuntime.init(.{});
    defer host.deinit();
    const rt = host.rt;
    const ctx = host.ctx;
    const global = host.global;

    const date_key = try rt.internAtom("Date");
    const date_value = try global.getProperty(date_key);
    const date_object = core.Object.fromHeader(date_value.refHeader().?);
    const prototype_value = try date_object.getProperty(core.atom.ids.prototype);
    const prototype_object = core.Object.fromHeader(prototype_value.refHeader().?);
    const set_time_object = try getGlobalObject(rt, prototype_object, "setTime");
    try std.testing.expect(set_time_object.nativeFunctionIdSlot().* != 0);

    const fake = try engine.core.function.nativeFunction(ctx, "notDateSetTime", 1);
    const fake_object = core.Object.fromHeader(fake.refHeader().?);
    fake_object.nativeFunctionIdSlot().* = set_time_object.nativeFunctionIdSlot().*;
    const dispatch_name = try engine.exec.call.nativeFunctionNameForVm(rt, fake_object);
    defer rt.nativeAllocator().free(dispatch_name);
    try std.testing.expectEqualStrings("notDateSetTime", dispatch_name);

    const direct_receiver = try engine.exec.date_ops.construct(rt, &.{core.JSValue.int32(0)});
    const direct_args = [_]core.JSValue{core.JSValue.int32(1)};
    const direct_result = try engine.exec.call_runtime.callValueOrBytecodeRoot(ctx, null, global, direct_receiver, fake, &direct_args, null, null);
    try std.testing.expectEqual(@as(f64, 1), engine.exec.value_ops.numberValue(direct_result).?);

    const fake_key = try rt.internAtom("fakeDateSetTime");
    try global.defineOwnProperty(rt, fake_key, core.Descriptor.data(fake, .method));

    var parsed = try engine.parser.compile(.{ .realm = ctx }, "const d = new Date(0); print(fakeDateSetTime.call(d, { valueOf: function(){ return 1704067200000; } })); print(d.getTime());", .{ .mode = .script, .filename = "date-prototype-native-record-dispatch.js" });
    defer parsed.deinit();
    var output_buffer: [48]u8 = undefined;
    const function = parsed.functionBytecode() orelse return error.TestExpectedEqual;
    const vm_result = try host.run(function, &output_buffer);
    try std.testing.expect(vm_result.value.is(.undefined_value));
    try std.testing.expectEqualStrings("1704067200000\n1704067200000\n", vm_result.output);
}

test "array static native builtin records ignore dispatch names" {
    var host = try BareRuntime.init(.{});
    defer host.deinit();
    const rt = host.rt;
    const ctx = host.ctx;
    const global = host.global;

    const array_key = try rt.internAtom("Array");
    const array_value = try global.getProperty(array_key);
    const array_object = core.Object.fromHeader(array_value.refHeader().?);
    const is_array_object = try getGlobalObject(rt, array_object, "isArray");
    try std.testing.expect(is_array_object.nativeFunctionIdSlot().* != 0);
    const from_object = try getGlobalObject(rt, array_object, "from");
    try std.testing.expect(from_object.nativeFunctionIdSlot().* != 0);

    const fake_is_array = try engine.core.function.nativeFunction(ctx, "notArrayIsArray", 1);
    const fake_is_array_object = core.Object.fromHeader(fake_is_array.refHeader().?);
    fake_is_array_object.nativeFunctionIdSlot().* = is_array_object.nativeFunctionIdSlot().*;
    const is_array_dispatch_name = try engine.exec.call.nativeFunctionNameForVm(rt, fake_is_array_object);
    defer rt.nativeAllocator().free(is_array_dispatch_name);
    try std.testing.expectEqualStrings("notArrayIsArray", is_array_dispatch_name);

    const direct_array = try engine.exec.array_builtin_ops.construct(rt, &.{core.JSValue.int32(1)});
    const direct_is_array_args = [_]core.JSValue{direct_array};
    const is_array_result = try engine.exec.call_runtime.callValueOrBytecodeRoot(ctx, null, global, core.JSValue.undefinedValue(), fake_is_array, &direct_is_array_args, null, null);
    try std.testing.expectEqual(true, is_array_result.as(.boolean).?);

    const fake_from = try engine.core.function.nativeFunction(ctx, "notArrayFrom", 1);
    const fake_from_object = core.Object.fromHeader(fake_from.refHeader().?);
    fake_from_object.nativeFunctionIdSlot().* = from_object.nativeFunctionIdSlot().*;
    const from_dispatch_name = try engine.exec.call.nativeFunctionNameForVm(rt, fake_from_object);
    defer rt.nativeAllocator().free(from_dispatch_name);
    try std.testing.expectEqualStrings("notArrayFrom", from_dispatch_name);

    const direct_from_result = try engine.exec.call_runtime.callValueOrBytecodeRoot(ctx, null, global, array_value, fake_from, &direct_is_array_args, null, null);
    const direct_from_array = core.Object.fromHeader(direct_from_result.refHeader().?);
    try std.testing.expect(direct_from_array.isArray());
    try std.testing.expectEqual(@as(u32, 1), direct_from_array.arrayLength());

    const fake_is_array_key = try rt.internAtom("fakeArrayIsArray");
    try global.defineOwnProperty(rt, fake_is_array_key, core.Descriptor.data(fake_is_array, .method));
    const fake_from_key = try rt.internAtom("fakeArrayFrom");
    try global.defineOwnProperty(rt, fake_from_key, core.Descriptor.data(fake_from, .method));

    var parsed = try engine.parser.compile(.{ .realm = ctx }, "print(fakeArrayIsArray([])); print(fakeArrayFrom.call(Array, [7, 8]).join(','));", .{ .mode = .script, .filename = "array-static-native-record-dispatch.js" });
    defer parsed.deinit();
    var output_buffer: [24]u8 = undefined;
    const function = parsed.functionBytecode() orelse return error.TestExpectedEqual;
    const vm_result = try host.run(function, &output_buffer);
    try std.testing.expect(vm_result.value.is(.undefined_value));
    try std.testing.expectEqualStrings("true\n7,8\n", vm_result.output);
}

test "array prototype native builtin records ignore dispatch names" {
    var host = try BareRuntime.init(.{});
    defer host.deinit();
    const rt = host.rt;
    const ctx = host.ctx;
    const global = host.global;

    const array_key = try rt.internAtom("Array");
    const prototype_key = try rt.internAtom("prototype");
    const to_string_key = try rt.internAtom("toString");
    const map_key = try rt.internAtom("map");
    const array_value = try global.getProperty(array_key);
    const array_object = core.Object.fromHeader(array_value.refHeader().?);
    const prototype_value = try array_object.getProperty(prototype_key);
    const prototype_object = core.Object.fromHeader(prototype_value.refHeader().?);

    const to_string_value = try prototype_object.getProperty(to_string_key);
    const to_string_object = core.Object.fromHeader(to_string_value.refHeader().?);
    try std.testing.expect(to_string_object.nativeFunctionIdSlot().* != 0);
    const join_object = try getGlobalObject(rt, prototype_object, "join");
    try std.testing.expect(join_object.nativeFunctionIdSlot().* != 0);
    const map_value = try prototype_object.getProperty(map_key);
    const map_object = core.Object.fromHeader(map_value.refHeader().?);
    try std.testing.expect(map_object.nativeFunctionIdSlot().* != 0);
    const values_object = try getGlobalObject(rt, prototype_object, "values");
    try std.testing.expect(values_object.nativeFunctionIdSlot().* != 0);

    const fake_join = try engine.core.function.nativeFunction(ctx, "notArrayJoin", 1);
    const fake_join_object = core.Object.fromHeader(fake_join.refHeader().?);
    fake_join_object.nativeFunctionIdSlot().* = join_object.nativeFunctionIdSlot().*;
    const join_dispatch_name = try engine.exec.call.nativeFunctionNameForVm(rt, fake_join_object);
    defer rt.nativeAllocator().free(join_dispatch_name);
    try std.testing.expectEqualStrings("notArrayJoin", join_dispatch_name);

    const direct_array = try engine.exec.array_builtin_ops.constructWithPrototype(rt, &.{ core.JSValue.int32(1), core.JSValue.int32(2) }, prototype_object);
    const separator = (try core.string.String.createUtf8(rt, ":")).value();
    const join_result = try engine.exec.call_runtime.callValueOrBytecodeRoot(ctx, null, global, direct_array, fake_join, &.{separator}, null, null);
    var join_text = std.ArrayList(u8).empty;
    defer join_text.deinit(rt.nativeAllocator());
    try engine.exec.value_ops.appendRawString(rt, &join_text, join_result);
    try std.testing.expectEqualStrings("1:2", join_text.items);

    const fake_to_string = try engine.core.function.nativeFunction(ctx, "notArrayToString", 0);
    const fake_to_string_object = core.Object.fromHeader(fake_to_string.refHeader().?);
    fake_to_string_object.nativeFunctionIdSlot().* = to_string_object.nativeFunctionIdSlot().*;
    const to_string_result = try engine.exec.call_runtime.callValueOrBytecodeRoot(ctx, null, global, direct_array, fake_to_string, &.{}, null, null);
    var to_string_text = std.ArrayList(u8).empty;
    defer to_string_text.deinit(rt.nativeAllocator());
    try engine.exec.value_ops.appendRawString(rt, &to_string_text, to_string_result);
    try std.testing.expectEqualStrings("1,2", to_string_text.items);

    const fake_map = try engine.core.function.nativeFunction(ctx, "notArrayMap", 1);
    const fake_map_object = core.Object.fromHeader(fake_map.refHeader().?);
    fake_map_object.nativeFunctionIdSlot().* = map_object.nativeFunctionIdSlot().*;
    const fake_values = try engine.core.function.nativeFunction(ctx, "notArrayValues", 0);
    const fake_values_object = core.Object.fromHeader(fake_values.refHeader().?);
    fake_values_object.nativeFunctionIdSlot().* = values_object.nativeFunctionIdSlot().*;

    const fake_map_key = try rt.internAtom("fakeArrayMap");
    try global.defineOwnProperty(rt, fake_map_key, core.Descriptor.data(fake_map, .method));
    const fake_values_key = try rt.internAtom("fakeArrayValues");
    try global.defineOwnProperty(rt, fake_values_key, core.Descriptor.data(fake_values, .method));

    var parsed = try engine.parser.compile(.{ .realm = ctx }, "print(fakeArrayMap.call([1,2], function(v){ return v + 1; }).join(',')); const it = fakeArrayValues.call([9]); print(it.next().value);", .{ .mode = .script, .filename = "array-prototype-native-record-dispatch.js" });
    defer parsed.deinit();
    var output_buffer: [24]u8 = undefined;
    const function = parsed.functionBytecode() orelse return error.TestExpectedEqual;
    const vm_result = try host.run(function, &output_buffer);
    try std.testing.expect(vm_result.value.is(.undefined_value));
    try std.testing.expectEqualStrings("2,3\n9\n", vm_result.output);
}

test "collection native builtin records ignore dispatch names" {
    var host = try BareRuntime.init(.{});
    defer host.deinit();
    const rt = host.rt;
    const ctx = host.ctx;
    const global = host.global;

    const map_key = try rt.internAtom("Map");
    const set_key = try rt.internAtom("Set");
    const prototype_key = try rt.internAtom("prototype");

    const map_value = try global.getProperty(map_key);
    const map_object = core.Object.fromHeader(map_value.refHeader().?);
    const group_by_object = try getGlobalObject(rt, map_object, "groupBy");
    try std.testing.expect(group_by_object.nativeFunctionIdSlot().* != 0);
    const map_prototype_value = try map_object.getProperty(prototype_key);
    const map_prototype_object = core.Object.fromHeader(map_prototype_value.refHeader().?);
    const map_set_object = try getGlobalObject(rt, map_prototype_object, "set");
    try std.testing.expect(map_set_object.nativeFunctionIdSlot().* != 0);
    const map_for_each_object = try getGlobalObject(rt, map_prototype_object, "forEach");
    try std.testing.expect(map_for_each_object.nativeFunctionIdSlot().* != 0);

    const set_value = try global.getProperty(set_key);
    const set_object = core.Object.fromHeader(set_value.refHeader().?);
    const set_prototype_value = try set_object.getProperty(prototype_key);
    const set_prototype_object = core.Object.fromHeader(set_prototype_value.refHeader().?);
    const set_union_object = try getGlobalObject(rt, set_prototype_object, "union");
    try std.testing.expect(set_union_object.nativeFunctionIdSlot().* != 0);
    const set_values_object = try getGlobalObject(rt, set_prototype_object, "values");
    try std.testing.expect(set_values_object.nativeFunctionIdSlot().* != 0);

    const fake_map_set = try engine.core.function.nativeFunction(ctx, "notMapSet", 2);
    const fake_map_set_object = core.Object.fromHeader(fake_map_set.refHeader().?);
    fake_map_set_object.nativeFunctionIdSlot().* = map_set_object.nativeFunctionIdSlot().*;
    const dispatch_name = try engine.exec.call.nativeFunctionNameForVm(rt, fake_map_set_object);
    defer rt.nativeAllocator().free(dispatch_name);
    try std.testing.expectEqualStrings("notMapSet", dispatch_name);

    const direct_map = try engine.exec.collection_ops.constructWithPrototype(rt, 1, map_prototype_object);
    const direct_key = (try core.string.String.createUtf8(rt, "direct")).value();
    const direct_args = [_]core.JSValue{ direct_key, core.JSValue.int32(7) };
    const direct_result = try engine.exec.call_runtime.callValueOrBytecodeRoot(ctx, null, global, direct_map, fake_map_set, &direct_args, null, null);
    try std.testing.expect(direct_result.same(direct_map));
    const direct_get_result = try engine.exec.collection_ops.methodCall(rt, direct_map, 2, &.{direct_key});
    try std.testing.expectEqual(@as(?i32, 7), direct_get_result.as(.int));

    const fake_group_by = try engine.core.function.nativeFunction(ctx, "notMapGroupBy", 2);
    const fake_group_by_object = core.Object.fromHeader(fake_group_by.refHeader().?);
    fake_group_by_object.nativeFunctionIdSlot().* = group_by_object.nativeFunctionIdSlot().*;
    const fake_map_for_each = try engine.core.function.nativeFunction(ctx, "notMapForEach", 1);
    const fake_map_for_each_object = core.Object.fromHeader(fake_map_for_each.refHeader().?);
    fake_map_for_each_object.nativeFunctionIdSlot().* = map_for_each_object.nativeFunctionIdSlot().*;
    const fake_set_union = try engine.core.function.nativeFunction(ctx, "notSetUnion", 1);
    const fake_set_union_object = core.Object.fromHeader(fake_set_union.refHeader().?);
    fake_set_union_object.nativeFunctionIdSlot().* = set_union_object.nativeFunctionIdSlot().*;
    const fake_set_values = try engine.core.function.nativeFunction(ctx, "notSetValues", 0);
    const fake_set_values_object = core.Object.fromHeader(fake_set_values.refHeader().?);
    fake_set_values_object.nativeFunctionIdSlot().* = set_values_object.nativeFunctionIdSlot().*;

    const fake_map_set_key = try rt.internAtom("fakeMapSet");
    try global.defineOwnProperty(rt, fake_map_set_key, core.Descriptor.data(fake_map_set, .method));
    const fake_group_by_key = try rt.internAtom("fakeMapGroupBy");
    try global.defineOwnProperty(rt, fake_group_by_key, core.Descriptor.data(fake_group_by, .method));
    const fake_map_for_each_key = try rt.internAtom("fakeMapForEach");
    try global.defineOwnProperty(rt, fake_map_for_each_key, core.Descriptor.data(fake_map_for_each, .method));
    const fake_set_union_key = try rt.internAtom("fakeSetUnion");
    try global.defineOwnProperty(rt, fake_set_union_key, core.Descriptor.data(fake_set_union, .method));
    const fake_set_values_key = try rt.internAtom("fakeSetValues");
    try global.defineOwnProperty(rt, fake_set_values_key, core.Descriptor.data(fake_set_values, .method));

    var parsed = try engine.parser.compile(.{ .realm = ctx }, "const grouped = fakeMapGroupBy.call(Map, ['aa', 'b'], function(v) { return v.length; }); print(grouped.get(2)[0]); const m = new Map(); fakeMapSet.call(m, 'a', 1); print(m.get('a')); fakeMapForEach.call(m, function(value, key) { print(key + ':' + value); }); const left = new Set(); left.add(1); const right = new Set(); right.add(2); const union = fakeSetUnion.call(left, right); print(Array.from(fakeSetValues.call(union)).join(','));", .{ .mode = .script, .filename = "collection-native-record-dispatch.js" });
    defer parsed.deinit();
    var output_buffer: [32]u8 = undefined;
    const function = parsed.functionBytecode() orelse return error.TestExpectedEqual;
    const vm_result = try host.run(function, &output_buffer);
    try std.testing.expect(vm_result.value.is(.undefined_value));
    try std.testing.expectEqualStrings("aa\n1\na:1\n1,2\n", vm_result.output);
}

test "buffer native builtin records ignore dispatch names" {
    var host = try BareRuntime.init(.{});
    defer host.deinit();
    const rt = host.rt;
    const ctx = host.ctx;
    const global = host.global;

    const prototype_key = try rt.internAtom("prototype");
    const slice_key = try rt.internAtom("slice");
    const byte_length_key = try rt.internAtom("byteLength");

    const array_buffer_object = try getGlobalObject(rt, global, "ArrayBuffer");
    const is_view_object = try getGlobalObject(rt, array_buffer_object, "isView");
    try std.testing.expect(is_view_object.nativeFunctionIdSlot().* != 0);
    const array_buffer_prototype_value = try array_buffer_object.getProperty(prototype_key);
    const array_buffer_prototype_object = core.Object.fromHeader(array_buffer_prototype_value.refHeader().?);
    const array_buffer_slice_value = try array_buffer_prototype_object.getProperty(slice_key);
    const array_buffer_slice_object = core.Object.fromHeader(array_buffer_slice_value.refHeader().?);
    try std.testing.expect(array_buffer_slice_object.nativeFunctionIdSlot().* != 0);
    const array_buffer_byte_length_desc = (try array_buffer_prototype_object.getOwnProperty(rt, byte_length_key)).?;
    const array_buffer_byte_length_getter = core.Object.fromHeader(array_buffer_byte_length_desc.getter.refHeader().?);
    try std.testing.expect(array_buffer_byte_length_getter.nativeFunctionIdSlot().* != 0);

    const shared_array_buffer_object = try getGlobalObject(rt, global, "SharedArrayBuffer");
    const shared_array_buffer_prototype_value = try shared_array_buffer_object.getProperty(prototype_key);
    const shared_array_buffer_prototype_object = core.Object.fromHeader(shared_array_buffer_prototype_value.refHeader().?);
    const shared_array_buffer_slice_value = try shared_array_buffer_prototype_object.getProperty(slice_key);
    const shared_array_buffer_slice_object = core.Object.fromHeader(shared_array_buffer_slice_value.refHeader().?);
    try std.testing.expect(shared_array_buffer_slice_object.nativeFunctionIdSlot().* != 0);

    const data_view_object = try getGlobalObject(rt, global, "DataView");
    const data_view_prototype_value = try data_view_object.getProperty(prototype_key);
    const data_view_prototype_object = core.Object.fromHeader(data_view_prototype_value.refHeader().?);
    const get_uint8_object = try getGlobalObject(rt, data_view_prototype_object, "getUint8");
    try std.testing.expect(get_uint8_object.nativeFunctionIdSlot().* != 0);
    const set_uint8_object = try getGlobalObject(rt, data_view_prototype_object, "setUint8");
    try std.testing.expect(set_uint8_object.nativeFunctionIdSlot().* != 0);
    const data_view_byte_length_desc = (try data_view_prototype_object.getOwnProperty(rt, byte_length_key)).?;
    const data_view_byte_length_getter = core.Object.fromHeader(data_view_byte_length_desc.getter.refHeader().?);
    try std.testing.expect(data_view_byte_length_getter.nativeFunctionIdSlot().* != 0);

    const fake_is_view = try engine.core.function.nativeFunction(ctx, "notArrayBufferIsView", 1);
    const fake_is_view_object = core.Object.fromHeader(fake_is_view.refHeader().?);
    fake_is_view_object.nativeFunctionIdSlot().* = is_view_object.nativeFunctionIdSlot().*;
    const fake_array_buffer_slice = try engine.core.function.nativeFunction(ctx, "notArrayBufferSlice", 2);
    const fake_array_buffer_slice_object = core.Object.fromHeader(fake_array_buffer_slice.refHeader().?);
    fake_array_buffer_slice_object.nativeFunctionIdSlot().* = array_buffer_slice_object.nativeFunctionIdSlot().*;
    const fake_array_buffer_byte_length = try engine.core.function.nativeFunction(ctx, "notArrayBufferByteLength", 0);
    const fake_array_buffer_byte_length_object = core.Object.fromHeader(fake_array_buffer_byte_length.refHeader().?);
    fake_array_buffer_byte_length_object.nativeFunctionIdSlot().* = array_buffer_byte_length_getter.nativeFunctionIdSlot().*;
    const fake_shared_array_buffer_slice = try engine.core.function.nativeFunction(ctx, "notSharedArrayBufferSlice", 2);
    const fake_shared_array_buffer_slice_object = core.Object.fromHeader(fake_shared_array_buffer_slice.refHeader().?);
    fake_shared_array_buffer_slice_object.nativeFunctionIdSlot().* = shared_array_buffer_slice_object.nativeFunctionIdSlot().*;
    const fake_data_view_get_uint8 = try engine.core.function.nativeFunction(ctx, "notDataViewGetUint8", 1);
    const fake_data_view_get_uint8_object = core.Object.fromHeader(fake_data_view_get_uint8.refHeader().?);
    fake_data_view_get_uint8_object.nativeFunctionIdSlot().* = get_uint8_object.nativeFunctionIdSlot().*;
    const fake_data_view_set_uint8 = try engine.core.function.nativeFunction(ctx, "notDataViewSetUint8", 2);
    const fake_data_view_set_uint8_object = core.Object.fromHeader(fake_data_view_set_uint8.refHeader().?);
    fake_data_view_set_uint8_object.nativeFunctionIdSlot().* = set_uint8_object.nativeFunctionIdSlot().*;
    const fake_data_view_byte_length = try engine.core.function.nativeFunction(ctx, "notDataViewByteLength", 0);
    const fake_data_view_byte_length_object = core.Object.fromHeader(fake_data_view_byte_length.refHeader().?);
    fake_data_view_byte_length_object.nativeFunctionIdSlot().* = data_view_byte_length_getter.nativeFunctionIdSlot().*;

    const dispatch_name = try engine.exec.call.nativeFunctionNameForVm(rt, fake_array_buffer_slice_object);
    defer rt.nativeAllocator().free(dispatch_name);
    try std.testing.expectEqualStrings("notArrayBufferSlice", dispatch_name);

    const direct_buffer = try core.typed_array.createArrayBufferWithPrototype(rt, 6, null, array_buffer_prototype_object);
    const direct_slice_result = try engine.exec.call_runtime.callValueOrBytecodeRoot(ctx, null, global, direct_buffer, fake_array_buffer_slice, &.{ core.JSValue.int32(1), core.JSValue.int32(4) }, null, null);
    const direct_slice_object = core.Object.fromHeader(direct_slice_result.refHeader().?);
    try std.testing.expectEqual(@as(usize, 3), direct_slice_object.byteStorage().len);
    const direct_length_result = try engine.exec.call_runtime.callValueOrBytecodeRoot(ctx, null, global, direct_buffer, fake_array_buffer_byte_length, &.{}, null, null);
    try std.testing.expectEqual(@as(?i32, 6), direct_length_result.as(.int));

    const fake_is_view_key = try rt.internAtom("fakeArrayBufferIsView");
    try global.defineOwnProperty(rt, fake_is_view_key, core.Descriptor.data(fake_is_view, .method));
    const fake_array_buffer_slice_key = try rt.internAtom("fakeArrayBufferSlice");
    try global.defineOwnProperty(rt, fake_array_buffer_slice_key, core.Descriptor.data(fake_array_buffer_slice, .method));
    const fake_array_buffer_byte_length_key = try rt.internAtom("fakeArrayBufferByteLength");
    try global.defineOwnProperty(rt, fake_array_buffer_byte_length_key, core.Descriptor.data(fake_array_buffer_byte_length, .method));
    const fake_shared_array_buffer_slice_key = try rt.internAtom("fakeSharedArrayBufferSlice");
    try global.defineOwnProperty(rt, fake_shared_array_buffer_slice_key, core.Descriptor.data(fake_shared_array_buffer_slice, .method));
    const fake_data_view_get_uint8_key = try rt.internAtom("fakeDataViewGetUint8");
    try global.defineOwnProperty(rt, fake_data_view_get_uint8_key, core.Descriptor.data(fake_data_view_get_uint8, .method));
    const fake_data_view_set_uint8_key = try rt.internAtom("fakeDataViewSetUint8");
    try global.defineOwnProperty(rt, fake_data_view_set_uint8_key, core.Descriptor.data(fake_data_view_set_uint8, .method));
    const fake_data_view_byte_length_key = try rt.internAtom("fakeDataViewByteLength");
    try global.defineOwnProperty(rt, fake_data_view_byte_length_key, core.Descriptor.data(fake_data_view_byte_length, .method));

    var parsed = try engine.parser.compile(.{ .realm = ctx },
        \\const b = new ArrayBuffer(6);
        \\print(fakeArrayBufferIsView(new DataView(b)));
        \\print(fakeArrayBufferSlice.call(b, 1, 4).byteLength);
        \\print(fakeArrayBufferByteLength.call(b));
        \\const s = new SharedArrayBuffer(5);
        \\print(fakeSharedArrayBufferSlice.call(s, 1, 3).byteLength);
        \\const v = new DataView(b);
        \\fakeDataViewSetUint8.call(v, 0, 77);
        \\print(fakeDataViewGetUint8.call(v, 0));
        \\print(fakeDataViewByteLength.call(v));
    , .{ .mode = .script, .filename = "buffer-native-record-dispatch.js" });
    defer parsed.deinit();
    var output_buffer: [40]u8 = undefined;
    const function = parsed.functionBytecode() orelse return error.TestExpectedEqual;
    const vm_result = try host.run(function, &output_buffer);
    try std.testing.expect(vm_result.value.is(.undefined_value));
    try std.testing.expectEqualStrings("true\n3\n6\n2\n77\n6\n", vm_result.output);
}

test "typed array accessor native builtin records ignore dispatch names" {
    var host = try BareRuntime.init(.{});
    defer host.deinit();
    const rt = host.rt;
    const ctx = host.ctx;
    const global = host.global;

    const prototype_key = try rt.internAtom("prototype");
    const byte_length_key = try rt.internAtom("byteLength");
    const length_key = try rt.internAtom("length");

    const typed_array_object = try getGlobalObject(rt, global, "TypedArray");
    const prototype_value = try typed_array_object.getProperty(prototype_key);
    const prototype_object = core.Object.fromHeader(prototype_value.refHeader().?);

    const byte_length_desc = (try prototype_object.getOwnProperty(rt, byte_length_key)).?;
    const byte_length_getter = core.Object.fromHeader(byte_length_desc.getter.refHeader().?);
    try std.testing.expect(byte_length_getter.nativeFunctionIdSlot().* != 0);
    const length_desc = (try prototype_object.getOwnProperty(rt, length_key)).?;
    const length_getter = core.Object.fromHeader(length_desc.getter.refHeader().?);
    try std.testing.expect(length_getter.nativeFunctionIdSlot().* != 0);
    const tag_desc = (try prototype_object.getOwnProperty(rt, core.atom.predefinedId("Symbol.toStringTag", .symbol).?)).?;
    const tag_getter = core.Object.fromHeader(tag_desc.getter.refHeader().?);
    try std.testing.expect(tag_getter.nativeFunctionIdSlot().* != 0);

    const fake_byte_length = try engine.core.function.nativeFunction(ctx, "notTypedArrayByteLength", 0);
    const fake_byte_length_object = core.Object.fromHeader(fake_byte_length.refHeader().?);
    fake_byte_length_object.nativeFunctionIdSlot().* = byte_length_getter.nativeFunctionIdSlot().*;
    const fake_length = try engine.core.function.nativeFunction(ctx, "notTypedArrayLength", 0);
    const fake_length_object = core.Object.fromHeader(fake_length.refHeader().?);
    fake_length_object.nativeFunctionIdSlot().* = length_getter.nativeFunctionIdSlot().*;
    const fake_tag = try engine.core.function.nativeFunction(ctx, "notTypedArrayTag", 0);
    const fake_tag_object = core.Object.fromHeader(fake_tag.refHeader().?);
    fake_tag_object.nativeFunctionIdSlot().* = tag_getter.nativeFunctionIdSlot().*;

    const dispatch_name = try engine.exec.call.nativeFunctionNameForVm(rt, fake_byte_length_object);
    defer rt.nativeAllocator().free(dispatch_name);
    try std.testing.expectEqualStrings("notTypedArrayByteLength", dispatch_name);

    const direct_buffer = try core.typed_array.createArrayBufferWithPrototype(rt, 8, null, null);
    const direct_typed_array = try engine.exec.buffer_ops.typedArrayConstructWithOptions(rt, 1, .uint8, direct_buffer, &.{direct_buffer}, prototype_object);
    const direct_byte_length = try engine.exec.call_runtime.callValueOrBytecodeRoot(ctx, null, global, direct_typed_array, fake_byte_length, &.{}, null, null);
    try std.testing.expectEqual(@as(?i32, 8), direct_byte_length.as(.int));
    const direct_length = try engine.exec.call_runtime.callValueOrBytecodeRoot(ctx, null, global, direct_typed_array, fake_length, &.{}, null, null);
    try std.testing.expectEqual(@as(?i32, 8), direct_length.as(.int));

    const fake_byte_length_key = try rt.internAtom("fakeTypedArrayByteLength");
    try global.defineOwnProperty(rt, fake_byte_length_key, core.Descriptor.data(fake_byte_length, .method));
    const fake_length_key = try rt.internAtom("fakeTypedArrayLength");
    try global.defineOwnProperty(rt, fake_length_key, core.Descriptor.data(fake_length, .method));
    const fake_tag_key = try rt.internAtom("fakeTypedArrayTag");
    try global.defineOwnProperty(rt, fake_tag_key, core.Descriptor.data(fake_tag, .method));

    var parsed = try engine.parser.compile(.{ .realm = ctx },
        \\const ta = new Uint8Array([1, 2, 3, 4]);
        \\print(fakeTypedArrayByteLength.call(ta));
        \\print(fakeTypedArrayLength.call(ta));
        \\print(fakeTypedArrayTag.call(ta));
        \\print(fakeTypedArrayTag.call({}));
    , .{ .mode = .script, .filename = "typed-array-accessor-native-record-dispatch.js" });
    defer parsed.deinit();
    var output_buffer: [32]u8 = undefined;
    const function = parsed.functionBytecode() orelse return error.TestExpectedEqual;
    const vm_result = try host.run(function, &output_buffer);
    try std.testing.expect(vm_result.value.is(.undefined_value));
    try std.testing.expectEqualStrings("4\n4\nUint8Array\nundefined\n", vm_result.output);
}

test "regexp static native builtin records ignore dispatch names" {
    var host = try BareRuntime.init(.{});
    defer host.deinit();
    const rt = host.rt;
    const ctx = host.ctx;
    const global = host.global;

    const regexp_key = try rt.internAtom("RegExp");
    const regexp_value = try global.getProperty(regexp_key);
    const regexp_object = core.Object.fromHeader(regexp_value.refHeader().?);
    const escape_object = try getGlobalObject(rt, regexp_object, "escape");
    try std.testing.expect(escape_object.nativeFunctionIdSlot().* != 0);

    const fake = try engine.core.function.nativeFunction(ctx, "notRegExpEscape", 1);
    const fake_object = core.Object.fromHeader(fake.refHeader().?);
    fake_object.nativeFunctionIdSlot().* = escape_object.nativeFunctionIdSlot().*;
    const dispatch_name = try engine.exec.call.nativeFunctionNameForVm(rt, fake_object);
    defer rt.nativeAllocator().free(dispatch_name);
    try std.testing.expectEqualStrings("notRegExpEscape", dispatch_name);

    const dot = try core.string.String.createUtf8(rt, ".");
    const direct_args = [_]core.JSValue{dot.value()};
    const direct_result = try engine.exec.call_runtime.callValueOrBytecodeRoot(ctx, null, global, core.JSValue.undefinedValue(), fake, &direct_args, null, null);
    try std.testing.expect(direct_result.isString());
    const direct_result_string = direct_result.asStringBody().?;
    try std.testing.expect(direct_result_string.eqlBytes("\\."));

    const fake_key = try rt.internAtom("fakeRegExpEscape");
    try global.defineOwnProperty(rt, fake_key, core.Descriptor.data(fake, .method));

    var parsed = try engine.parser.compile(.{ .realm = ctx }, "print(fakeRegExpEscape('.')); print(fakeRegExpEscape('a+b'));", .{ .mode = .script, .filename = "regexp-static-native-record-dispatch.js" });
    defer parsed.deinit();
    var output_buffer: [24]u8 = undefined;
    const function = parsed.functionBytecode() orelse return error.TestExpectedEqual;
    const vm_result = try host.run(function, &output_buffer);
    try std.testing.expect(vm_result.value.is(.undefined_value));
    try std.testing.expectEqualStrings("\\.\n\\x61\\+b\n", vm_result.output);
}

test "regexp prototype native builtin records ignore dispatch names" {
    var host = try BareRuntime.init(.{});
    defer host.deinit();
    const rt = host.rt;
    const ctx = host.ctx;
    const global = host.global;

    const regexp_key = try rt.internAtom("RegExp");
    const to_string_key = try rt.internAtom("toString");
    const regexp_value = try global.getProperty(regexp_key);
    const regexp_object = core.Object.fromHeader(regexp_value.refHeader().?);
    const prototype_value = try regexp_object.getProperty(core.atom.ids.prototype);
    const prototype_object = core.Object.fromHeader(prototype_value.refHeader().?);
    const exec_object = try getGlobalObject(rt, prototype_object, "exec");
    try std.testing.expect(exec_object.nativeFunctionIdSlot().* != 0);
    const test_object = try getGlobalObject(rt, prototype_object, "test");
    try std.testing.expect(test_object.nativeFunctionIdSlot().* != 0);
    const to_string_value = try prototype_object.getProperty(to_string_key);
    const to_string_object = core.Object.fromHeader(to_string_value.refHeader().?);
    try std.testing.expect(to_string_object.nativeFunctionIdSlot().* != 0);

    const fake_exec = try engine.core.function.nativeFunction(ctx, "notRegExpExec", 1);
    const fake_exec_object = core.Object.fromHeader(fake_exec.refHeader().?);
    fake_exec_object.nativeFunctionIdSlot().* = exec_object.nativeFunctionIdSlot().*;
    const exec_dispatch_name = try engine.exec.call.nativeFunctionNameForVm(rt, fake_exec_object);
    defer rt.nativeAllocator().free(exec_dispatch_name);
    try std.testing.expectEqualStrings("notRegExpExec", exec_dispatch_name);

    const fake_test = try engine.core.function.nativeFunction(ctx, "notRegExpTest", 1);
    const fake_test_object = core.Object.fromHeader(fake_test.refHeader().?);
    fake_test_object.nativeFunctionIdSlot().* = test_object.nativeFunctionIdSlot().*;
    const test_dispatch_name = try engine.exec.call.nativeFunctionNameForVm(rt, fake_test_object);
    defer rt.nativeAllocator().free(test_dispatch_name);
    try std.testing.expectEqualStrings("notRegExpTest", test_dispatch_name);

    const fake_to_string = try engine.core.function.nativeFunction(ctx, "notRegExpToString", 0);
    const fake_to_string_object = core.Object.fromHeader(fake_to_string.refHeader().?);
    fake_to_string_object.nativeFunctionIdSlot().* = to_string_object.nativeFunctionIdSlot().*;
    const to_string_dispatch_name = try engine.exec.call.nativeFunctionNameForVm(rt, fake_to_string_object);
    defer rt.nativeAllocator().free(to_string_dispatch_name);
    try std.testing.expectEqualStrings("notRegExpToString", to_string_dispatch_name);

    const pattern_string = try core.string.String.createUtf8(rt, "a");
    const flags_string = try core.string.String.createUtf8(rt, "");
    const receiver = try engine.exec.regexp_ops.constructWithPrototype(rt, pattern_string.value(), flags_string.value(), prototype_object);
    const input_string = try core.string.String.createUtf8(rt, "cat");
    const direct_args = [_]core.JSValue{input_string.value()};
    const exec_result = try engine.exec.call_runtime.callValueOrBytecodeRoot(ctx, null, global, receiver, fake_exec, &direct_args, null, null);
    const exec_array = core.Object.fromHeader(exec_result.refHeader().?);
    try std.testing.expect(exec_array.isArray());
    const first_match = try exec_array.getProperty(core.Atom.taggedInt(0));
    try std.testing.expect(first_match.isString());
    const first_match_string = first_match.asStringBody().?;
    try std.testing.expect(first_match_string.eqlBytes("a"));
    const index_key = try rt.internAtom("index");
    const index_value = try exec_array.getProperty(index_key);
    try std.testing.expectEqual(@as(i32, 1), index_value.as(.int).?);

    const test_result = try engine.exec.call_runtime.callValueOrBytecodeRoot(ctx, null, global, receiver, fake_test, &direct_args, null, null);
    try std.testing.expectEqual(true, test_result.as(.boolean).?);

    const to_string_result = try engine.exec.call_runtime.callValueOrBytecodeRoot(ctx, null, global, receiver, fake_to_string, &.{}, null, null);
    try std.testing.expect(to_string_result.isString());
    const to_string_result_string = to_string_result.asStringBody().?;
    try std.testing.expect(to_string_result_string.eqlBytes("/a/"));

    const fake_exec_key = try rt.internAtom("fakeRegExpExec");
    try global.defineOwnProperty(rt, fake_exec_key, core.Descriptor.data(fake_exec, .method));
    const fake_test_key = try rt.internAtom("fakeRegExpTest");
    try global.defineOwnProperty(rt, fake_test_key, core.Descriptor.data(fake_test, .method));
    const fake_to_string_key = try rt.internAtom("fakeRegExpToString");
    try global.defineOwnProperty(rt, fake_to_string_key, core.Descriptor.data(fake_to_string, .method));

    var parsed = try engine.parser.compile(.{ .realm = ctx }, "const r = /a/; const m = fakeRegExpExec.call(r, 'cat'); print(m[0] + ':' + m.index); print(fakeRegExpTest.call(r, 'cat')); print(fakeRegExpToString.call(r));", .{ .mode = .script, .filename = "regexp-prototype-native-record-dispatch.js" });
    defer parsed.deinit();
    var output_buffer: [32]u8 = undefined;
    const function = parsed.functionBytecode() orelse return error.TestExpectedEqual;
    const vm_result = try host.run(function, &output_buffer);
    try std.testing.expect(vm_result.value.is(.undefined_value));
    try std.testing.expectEqualStrings("a:1\ntrue\n/a/\n", vm_result.output);
}

test "regexp symbol native builtin records ignore dispatch names" {
    var host = try BareRuntime.init(.{});
    defer host.deinit();
    const rt = host.rt;
    const ctx = host.ctx;
    const global = host.global;

    const regexp_key = try rt.internAtom("RegExp");
    const regexp_value = try global.getProperty(regexp_key);
    const regexp_object = core.Object.fromHeader(regexp_value.refHeader().?);
    const prototype_value = try regexp_object.getProperty(core.atom.ids.prototype);
    const prototype_object = core.Object.fromHeader(prototype_value.refHeader().?);

    const search_value = try prototype_object.getProperty(core.atom.predefinedId("Symbol.search", .symbol).?);
    const search_object = core.Object.fromHeader(search_value.refHeader().?);
    try std.testing.expect(search_object.nativeFunctionIdSlot().* != 0);
    const match_value = try prototype_object.getProperty(core.atom.predefinedId("Symbol.match", .symbol).?);
    const match_object = core.Object.fromHeader(match_value.refHeader().?);
    try std.testing.expect(match_object.nativeFunctionIdSlot().* != 0);
    const match_all_value = try prototype_object.getProperty(core.atom.predefinedId("Symbol.matchAll", .symbol).?);
    const match_all_object = core.Object.fromHeader(match_all_value.refHeader().?);
    try std.testing.expect(match_all_object.nativeFunctionIdSlot().* != 0);
    const replace_value = try prototype_object.getProperty(core.atom.predefinedId("Symbol.replace", .symbol).?);
    const replace_object = core.Object.fromHeader(replace_value.refHeader().?);
    try std.testing.expect(replace_object.nativeFunctionIdSlot().* != 0);
    const split_value = try prototype_object.getProperty(core.atom.predefinedId("Symbol.split", .symbol).?);
    const split_object = core.Object.fromHeader(split_value.refHeader().?);
    try std.testing.expect(split_object.nativeFunctionIdSlot().* != 0);

    const fake_search = try engine.core.function.nativeFunction(ctx, "notRegExpSearch", 1);
    const fake_search_object = core.Object.fromHeader(fake_search.refHeader().?);
    fake_search_object.nativeFunctionIdSlot().* = search_object.nativeFunctionIdSlot().*;
    const search_dispatch_name = try engine.exec.call.nativeFunctionNameForVm(rt, fake_search_object);
    defer rt.nativeAllocator().free(search_dispatch_name);
    try std.testing.expectEqualStrings("notRegExpSearch", search_dispatch_name);

    const fake_match = try engine.core.function.nativeFunction(ctx, "notRegExpMatch", 1);
    const fake_match_object = core.Object.fromHeader(fake_match.refHeader().?);
    fake_match_object.nativeFunctionIdSlot().* = match_object.nativeFunctionIdSlot().*;
    const fake_match_all = try engine.core.function.nativeFunction(ctx, "notRegExpMatchAll", 1);
    const fake_match_all_object = core.Object.fromHeader(fake_match_all.refHeader().?);
    fake_match_all_object.nativeFunctionIdSlot().* = match_all_object.nativeFunctionIdSlot().*;
    const fake_replace = try engine.core.function.nativeFunction(ctx, "notRegExpReplace", 2);
    const fake_replace_object = core.Object.fromHeader(fake_replace.refHeader().?);
    fake_replace_object.nativeFunctionIdSlot().* = replace_object.nativeFunctionIdSlot().*;
    const fake_split = try engine.core.function.nativeFunction(ctx, "notRegExpSplit", 2);
    const fake_split_object = core.Object.fromHeader(fake_split.refHeader().?);
    fake_split_object.nativeFunctionIdSlot().* = split_object.nativeFunctionIdSlot().*;

    const pattern_string = try core.string.String.createUtf8(rt, "a");
    const flags_string = try core.string.String.createUtf8(rt, "");
    const receiver = try engine.exec.regexp_ops.constructWithPrototype(rt, pattern_string.value(), flags_string.value(), prototype_object);
    const input_string = try core.string.String.createUtf8(rt, "cat");
    const replacement_string = try core.string.String.createUtf8(rt, "o");

    const one_arg = [_]core.JSValue{input_string.value()};
    const search_result = try engine.exec.call_runtime.callValueOrBytecodeRoot(ctx, null, global, receiver, fake_search, &one_arg, null, null);
    try std.testing.expectEqual(@as(i32, 1), search_result.as(.int).?);

    const match_result = try engine.exec.call_runtime.callValueOrBytecodeRoot(ctx, null, global, receiver, fake_match, &one_arg, null, null);
    const match_array = core.Object.fromHeader(match_result.refHeader().?);
    const match_zero = try match_array.getProperty(core.Atom.taggedInt(0));
    try std.testing.expect(match_zero.isString());
    const match_zero_string = match_zero.asStringBody().?;
    try std.testing.expect(match_zero_string.eqlBytes("a"));

    const match_all_result = try engine.exec.call_runtime.callValueOrBytecodeRoot(ctx, null, global, receiver, fake_match_all, &one_arg, null, null);
    const match_all_iterator = core.Object.fromHeader(match_all_result.refHeader().?);
    try std.testing.expectEqual(core.class.ids.regexp_string_iterator, match_all_iterator.class_id);

    const replace_args = [_]core.JSValue{ input_string.value(), replacement_string.value() };
    const replace_result = try engine.exec.call_runtime.callValueOrBytecodeRoot(ctx, null, global, receiver, fake_replace, &replace_args, null, null);
    try std.testing.expect(replace_result.isString());
    const replace_result_string = replace_result.asStringBody().?;
    try std.testing.expect(replace_result_string.eqlBytes("cot"));

    const split_result = try engine.exec.call_runtime.callValueOrBytecodeRoot(ctx, null, global, receiver, fake_split, &one_arg, null, null);
    const split_array = core.Object.fromHeader(split_result.refHeader().?);
    try std.testing.expect(split_array.isArray());
    try std.testing.expectEqual(@as(u32, 2), split_array.arrayLength());

    const fake_search_key = try rt.internAtom("fakeRegExpSearch");
    try global.defineOwnProperty(rt, fake_search_key, core.Descriptor.data(fake_search, .method));
    const fake_match_key = try rt.internAtom("fakeRegExpMatch");
    try global.defineOwnProperty(rt, fake_match_key, core.Descriptor.data(fake_match, .method));
    const fake_match_all_key = try rt.internAtom("fakeRegExpMatchAll");
    try global.defineOwnProperty(rt, fake_match_all_key, core.Descriptor.data(fake_match_all, .method));
    const fake_replace_key = try rt.internAtom("fakeRegExpReplace");
    try global.defineOwnProperty(rt, fake_replace_key, core.Descriptor.data(fake_replace, .method));
    const fake_split_key = try rt.internAtom("fakeRegExpSplit");
    try global.defineOwnProperty(rt, fake_split_key, core.Descriptor.data(fake_split, .method));

    var parsed = try engine.parser.compile(.{ .realm = ctx },
        \\const r = /a/;
        \\print(fakeRegExpSearch.call(r, 'cat'));
        \\print(fakeRegExpMatch.call(r, 'cat')[0]);
        \\print(fakeRegExpMatchAll.call(r, 'cat').next().value[0]);
        \\print(fakeRegExpReplace.call(r, 'cat', 'o'));
        \\print(fakeRegExpSplit.call(r, 'cat').join('|'));
    , .{ .mode = .script, .filename = "regexp-symbol-native-record-dispatch.js" });
    defer parsed.deinit();
    var output_buffer: [48]u8 = undefined;
    const function = parsed.functionBytecode() orelse return error.TestExpectedEqual;
    const vm_result = try host.run(function, &output_buffer);
    try std.testing.expect(vm_result.value.is(.undefined_value));
    try std.testing.expectEqualStrings("1\na\na\ncot\nc|t\n", vm_result.output);
}

test "regexp accessor native builtin records ignore dispatch names" {
    var host = try BareRuntime.init(.{});
    defer host.deinit();
    const rt = host.rt;
    const ctx = host.ctx;
    const global = host.global;

    const regexp_key = try rt.internAtom("RegExp");
    const regexp_value = try global.getProperty(regexp_key);
    const regexp_object = core.Object.fromHeader(regexp_value.refHeader().?);
    const prototype_value = try regexp_object.getProperty(core.atom.ids.prototype);
    const prototype_object = core.Object.fromHeader(prototype_value.refHeader().?);

    const source_key = try rt.internAtom("source");
    const source_desc = (try prototype_object.getOwnProperty(rt, source_key)).?;
    const source_getter = core.Object.fromHeader(source_desc.getter.refHeader().?);
    try std.testing.expect(source_getter.nativeFunctionIdSlot().* != 0);
    const global_key = try rt.internAtom("global");
    const global_desc = (try prototype_object.getOwnProperty(rt, global_key)).?;
    const global_getter = core.Object.fromHeader(global_desc.getter.refHeader().?);
    try std.testing.expect(global_getter.nativeFunctionIdSlot().* != 0);

    const fake_source = try engine.core.function.nativeFunction(ctx, "notRegExpSourceGetter", 0);
    const fake_source_object = core.Object.fromHeader(fake_source.refHeader().?);
    fake_source_object.nativeFunctionIdSlot().* = source_getter.nativeFunctionIdSlot().*;
    const source_dispatch_name = try engine.exec.call.nativeFunctionNameForVm(rt, fake_source_object);
    defer rt.nativeAllocator().free(source_dispatch_name);
    try std.testing.expectEqualStrings("notRegExpSourceGetter", source_dispatch_name);

    const fake_global = try engine.core.function.nativeFunction(ctx, "notRegExpGlobalGetter", 0);
    const fake_global_object = core.Object.fromHeader(fake_global.refHeader().?);
    fake_global_object.nativeFunctionIdSlot().* = global_getter.nativeFunctionIdSlot().*;

    const pattern_string = try core.string.String.createUtf8(rt, "a/b");
    const flags_string = try core.string.String.createUtf8(rt, "g");
    const receiver = try engine.exec.regexp_ops.constructWithPrototype(rt, pattern_string.value(), flags_string.value(), prototype_object);

    const source_result = try engine.exec.call_runtime.callValueOrBytecodeRoot(ctx, null, global, receiver, fake_source, &.{}, null, null);
    try std.testing.expect(source_result.isString());
    const source_string = source_result.asStringBody().?;
    try std.testing.expect(source_string.eqlBytes("a\\/b"));

    const global_result = try engine.exec.call_runtime.callValueOrBytecodeRoot(ctx, null, global, receiver, fake_global, &.{}, null, null);
    try std.testing.expectEqual(true, global_result.as(.boolean).?);

    const fake_source_key = try rt.internAtom("fakeRegExpSourceGetter");
    try global.defineOwnProperty(rt, fake_source_key, core.Descriptor.data(fake_source, .method));
    const fake_global_key = try rt.internAtom("fakeRegExpGlobalGetter");
    try global.defineOwnProperty(rt, fake_global_key, core.Descriptor.data(fake_global, .method));

    var parsed = try engine.parser.compile(.{ .realm = ctx },
        \\const r = /a\/b/g;
        \\print(fakeRegExpSourceGetter.call(r));
        \\print(fakeRegExpGlobalGetter.call(r));
    , .{ .mode = .script, .filename = "regexp-accessor-native-record-dispatch.js" });
    defer parsed.deinit();
    var output_buffer: [24]u8 = undefined;
    const function = parsed.functionBytecode() orelse return error.TestExpectedEqual;
    const vm_result = try host.run(function, &output_buffer);
    try std.testing.expect(vm_result.value.is(.undefined_value));
    try std.testing.expectEqualStrings("a\\/b\ntrue\n", vm_result.output);
}

test "vm host native builtin records dispatch by id before name fallback" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();
    const global = try core.Object.create(rt, core.class.ids.global_object, null);
    _ = try global.ensureGlobalPayload(rt);
    ctx.global = global;

    // This focused dispatch fixture intentionally has no intrinsic bootstrap,
    // but a callable RealmContext still owns an exact global. Its detached
    // native record declares a null final prototype explicitly instead of
    // using the post-bootstrap realm convenience API.
    const fake_species = try engine.core.function.nativeFunctionWithPrototypeAndCapacity(ctx, null, "notSpeciesGetter", 0, 2);
    const fake_species_object = core.Object.fromHeader(fake_species.refHeader().?);
    fake_species_object.setNativeBuiltinIdAndRecord(
        core.function.nativeBuiltinId(.engine_helper, @intFromEnum(core.function.EngineHelperMethod.species_getter)),
    );
    const native_ref = core.function.decodeNativeBuiltinId(fake_species_object.nativeFunctionId()).?;

    const receiver = try core.Object.create(rt, core.class.ids.object, null);
    const dispatched = try engine.exec.call_runtime.callNativeBuiltinRecordForVm(
        ctx,
        null,
        global,
        receiver.value(),
        fake_species_object,
        native_ref,
        &.{},
        null,
        null,
    );
    try std.testing.expect(dispatched != null);
    const result = dispatched.?;
    try std.testing.expect(result.same(receiver.value()));
}

test "vm collection constructors use registered prototype methods" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();

    const map_atom = try rt.internAtom("Map");
    var bytes: [8]u8 = undefined;
    bytes[0] = op.get_var;
    std.mem.writeInt(u16, bytes[1..3], 0, .little);
    bytes[3] = op.dup;
    bytes[4] = op.call_constructor;
    std.mem.writeInt(u16, bytes[5..7], 0, .little);
    bytes[7] = op.@"return";
    const function = try makeFixture(rt, ctx, .{
        .name = "collection-prototype",
        .code = &bytes,
        .globals = &.{map_atom},
    });
    defer function.release(rt);

    var vm_instance = engine.exec.Vm.init(ctx);
    defer vm_instance.deinit();
    const result = try vm_instance.run(function.fb);

    const object = core.Object.fromHeader(result.refHeader().?);
    const set_key = try rt.internAtom("set");
    try std.testing.expect(object.getPrototype() != null);
    try std.testing.expect(!object.hasOwnProperty(set_key));
    try std.testing.expect(object.hasProperty(set_key));
    try std.testing.expect(object.getPrototype().?.hasOwnProperty(set_key));
}

test "qjs alignment X-08 eval var writable false syncs VARREF is_const" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [512]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    _ = try js.evalWithOutput(
        \\(0,eval)("var ev = 1;");
        \\Object.defineProperty(globalThis, "ev", {writable:false});
        \\print("desc.writable = " + Object.getOwnPropertyDescriptor(globalThis,"ev").writable);
        \\try { ev = 7; } catch(e){ print("assign threw " + e.name); }
        \\print("ev = " + ev);
        \\globalThis.gp = 5; Object.defineProperty(globalThis, "gp", {writable:false});
        \\print("gp desc.writable = " + Object.getOwnPropertyDescriptor(globalThis,"gp").writable);
        \\gp = 9; print("gp = " + gp);
        \\(0,eval)("var ev2 = 1;"); Object.defineProperty(globalThis, "ev2", {enumerable:false});
        \\print("ev2 desc.enumerable = " + Object.getOwnPropertyDescriptor(globalThis,"ev2").enumerable);
    , &stream);

    try std.testing.expectEqualStrings(
        \\desc.writable = false
        \\ev = 1
        \\gp desc.writable = false
        \\gp = 5
        \\ev2 desc.enumerable = false
        \\
    , stream.buffered());
}

test "qjs alignment X-09 VARREF to GETSET detaches the stale cell" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    _ = try js.evalWithOutput(
        \\(0,eval)("var ev = 1;");
        \\ev = 7;
        \\Object.defineProperty(globalThis, "ev", {get:function(){return 42;}, configurable:true});
        \\print("bare ev = " + ev);
        \\print("globalThis.ev = " + globalThis.ev);
    , &stream);

    try std.testing.expectEqualStrings(
        \\bare ev = 42
        \\globalThis.ev = 42
        \\
    , stream.buffered());
}

test "instanceof resident dispatch preserves GetMethod and result coercion semantics" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.eval(
        \\const candidate = { marker: 7 };
        \\function Truthy() {}
        \\Object.defineProperty(Truthy, Symbol.hasInstance, {
        \\  value: function(value) { return value.marker; },
        \\  configurable: true
        \\});
        \\assert.sameValue(candidate instanceof Truthy, true);
        \\function Falsy() {}
        \\Object.defineProperty(Falsy, Symbol.hasInstance, {
        \\  value: function() { return 0; },
        \\  configurable: true
        \\});
        \\assert.sameValue(candidate instanceof Falsy, false);
        \\function UndefinedResult() {}
        \\Object.defineProperty(UndefinedResult, Symbol.hasInstance, {
        \\  value: function() { return undefined; },
        \\  configurable: true
        \\});
        \\assert.sameValue(candidate instanceof UndefinedResult, false);
        \\function ObjectResult() {}
        \\Object.defineProperty(ObjectResult, Symbol.hasInstance, {
        \\  value: function() { return {}; },
        \\  configurable: true
        \\});
        \\assert.sameValue(candidate instanceof ObjectResult, true);
        \\
        \\let seenThis;
        \\let seenValue;
        \\function Observed() {}
        \\Object.defineProperty(Observed, Symbol.hasInstance, {
        \\  value: function(value) {
        \\    seenThis = this;
        \\    seenValue = value;
        \\    return "yes";
        \\  },
        \\  configurable: true
        \\});
        \\assert.sameValue(candidate instanceof Observed, true);
        \\assert.sameValue(seenThis, Observed);
        \\assert.sameValue(seenValue, candidate);
        \\
        \\function StrictObserved() {}
        \\Object.defineProperty(StrictObserved, Symbol.hasInstance, {
        \\  value: function(value) {
        \\    "use strict";
        \\    return this === StrictObserved && value === candidate;
        \\  },
        \\  configurable: true
        \\});
        \\assert.sameValue(candidate instanceof StrictObserved, true);
        \\
        \\function makeCapturedHasInstance(expected) {
        \\  return value => value === expected;
        \\}
        \\function ArrowBacked() {}
        \\Object.defineProperty(ArrowBacked, Symbol.hasInstance, {
        \\  value: makeCapturedHasInstance(candidate),
        \\  configurable: true
        \\});
        \\assert.sameValue(candidate instanceof ArrowBacked, true);
        \\
        \\let getterCalls = 0;
        \\function GetterBacked() {}
        \\Object.defineProperty(GetterBacked, Symbol.hasInstance, {
        \\  get: function() {
        \\    getterCalls++;
        \\    return function(value) { return value.marker === 7; };
        \\  },
        \\  configurable: true
        \\});
        \\assert.sameValue(candidate instanceof GetterBacked, true);
        \\assert.sameValue(getterCalls, 1);
        \\
        \\function Throwing() {}
        \\Object.defineProperty(Throwing, Symbol.hasInstance, {
        \\  value: function() { throw new RangeError("instanceof sentinel"); },
        \\  configurable: true
        \\});
        \\let caught = false;
        \\try {
        \\  candidate instanceof Throwing;
        \\} catch (error) {
        \\  caught = error instanceof RangeError && error.message === "instanceof sentinel";
        \\}
        \\assert.sameValue(caught, true);
        \\
        \\let primitiveGetterCalls = 0;
        \\Object.defineProperty(Number.prototype, Symbol.hasInstance, {
        \\  get: function() {
        \\    primitiveGetterCalls++;
        \\    return function() { return true; };
        \\  },
        \\  configurable: true
        \\});
        \\try {
        \\  let primitiveCaught = false;
        \\  try {
        \\    candidate instanceof 1;
        \\  } catch (error) {
        \\    primitiveCaught = error instanceof TypeError;
        \\  }
        \\  assert.sameValue(primitiveCaught, true);
        \\  assert.sameValue(primitiveGetterCalls, 0);
        \\} finally {
        \\  delete Number.prototype[Symbol.hasInstance];
        \\}
    );

    try std.testing.expect(result.is(.undefined_value));
}

test "default Function hasInstance uses Ordinary; other native records still Call" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\function C() {}
        \\const instance = new C();
        \\assert.sameValue(instance instanceof C, true);
        \\assert.sameValue(1 instanceof C, false);
        \\assert.sameValue(({}) instanceof C, false);
        \\const Bound = C.bind(null);
        \\assert.sameValue(instance instanceof Bound, true);
        \\
        \\const original = Function.prototype[Symbol.hasInstance];
        \\Object.defineProperty(C, Symbol.hasInstance, {
        \\  value: Function.prototype.call,
        \\  configurable: true
        \\});
        \\assert.sameValue(instance instanceof C, false);
        \\delete C[Symbol.hasInstance];
        \\assert.sameValue(instance instanceof C, true);
        \\
        \\let calls = 0;
        \\Object.defineProperty(C, Symbol.hasInstance, {
        \\  value: function(value) {
        \\    calls++;
        \\    return original.call(this, value);
        \\  },
        \\  configurable: true
        \\});
        \\assert.sameValue(instance instanceof C, true);
        \\assert.sameValue(calls, 1);
        \\delete C[Symbol.hasInstance];
        \\assert.sameValue(instance instanceof C, true);
    );

    try std.testing.expect(result.is(.undefined_value));
}

test "local reference-tail lowering preserves binding semantics" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\function compoundAssignment() {
        \\  var x = 1;
        \\  function rhs() { x = 10; return 2; }
        \\  x += rhs();
        \\  return x;
        \\}
        \\assert.sameValue(compoundAssignment(), 3);
        \\function declarationAssignment() {
        \\  var x = 1;
        \\  function rhs() { x = 10; return 2; }
        \\  var x = rhs();
        \\  return x;
        \\}
        \\assert.sameValue(declarationAssignment(), 2);
        \\function capturedLocal() {
        \\  var x = 0;
        \\  const read = () => x;
        \\  var x = 3;
        \\  return read();
        \\}
        \\assert.sameValue(capturedLocal(), 3);
        \\function dynamicWith() {
        \\  var x = 1;
        \\  const scope = { x: 2 };
        \\  with (scope) { x = 3; }
        \\  return x + ":" + scope.x;
        \\}
        \\assert.sameValue(dynamicWith(), "1:3");
        \\function directEval() {
        \\  var x = 1;
        \\  var x = eval("x = 5; 2");
        \\  return x;
        \\}
        \\assert.sameValue(directEval(), 2);
    );

    try std.testing.expect(result.is(.undefined_value));
}

test "qjs alignment const local writes throw from resolved bytecode" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\function beforeDeclaration() { x = 1; const x = 2; }
        \\let beforeCaught = false;
        \\let beforeMessage = "";
        \\try { beforeDeclaration(); } catch (error) {
        \\  // SetMutableBinding: an uninitialized const is a ReferenceError.
        \\  beforeCaught = error instanceof TypeError;
        \\  beforeMessage = error.message;
        \\}
        \\assert.sameValue(beforeCaught, false);
        \\assert.sameValue(beforeMessage, "Cannot access 'x' before initialization");
        \\let rhsCalls = 0;
        \\let compoundCaught = false;
        \\let compoundMessage = "";
        \\function compoundConst() {
        \\  const fixed = 1;
        \\  try { fixed += (rhsCalls = 1); } catch (error) {
        \\    compoundCaught = error instanceof TypeError;
        \\    compoundMessage = error.message;
        \\  }
        \\}
        \\compoundConst();
        \\assert.sameValue(compoundCaught, true);
        \\assert.sameValue(compoundMessage, "'fixed' is read-only");
        \\assert.sameValue(rhsCalls, 1);
        \\function sloppyName() {
        \\  return (function named() { named = 0; return typeof named; })();
        \\}
        \\assert.sameValue(sloppyName(), "function");
        \\let strictNameCaught = false;
        \\try {
        \\  (function named() { "use strict"; named = 0; })();
        \\} catch (error) {
        \\  strictNameCaught = error instanceof TypeError;
        \\}
        \\assert.sameValue(strictNameCaught, true);
    );

    try std.testing.expect(result.is(.undefined_value));
}

test "named function self-binding ignores sloppy writes and rejects strict writers" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\let direct = (function named() {
        \\  let original = named;
        \\  named += 1;
        \\  named++;
        \\  ++named;
        \\  [named] = [0];
        \\  ({ value: named } = { value: 0 });
        \\  return named === original;
        \\})();
        \\assert.sameValue(direct, true);
        \\let nested = (function named() {
        \\  let original = named;
        \\  return function inner() {
        \\    named = 0;
        \\    named += 1;
        \\    named++;
        \\    ++named;
        \\    [named] = [0];
        \\    ({ value: named } = { value: 0 });
        \\    return named === original;
        \\  };
        \\})()();
        \\assert.sameValue(nested, true);
        \\// A direct eval in a nested function threads the name through an eval
        \\// closure row, which must stay immutable.
        \\let throughEval = (function named() {
        \\  let original = named;
        \\  return (function () { eval(""); named = 0; return eval("named = 1; named") === original; })();
        \\})();
        \\assert.sameValue(throughEval, true);
        \\let strictThroughEval = (function named() {
        \\  "use strict";
        \\  return (() => { eval(""); try { named = 0; } catch (e) { return e instanceof TypeError; } return false; })();
        \\})();
        \\assert.sameValue(strictThroughEval, true);
        \\let strictOuterCaught = false;
        \\try {
        \\  (function named() { "use strict"; return function inner() { named = 0; }; })()();
        \\} catch (error) {
        \\  strictOuterCaught = error instanceof TypeError;
        \\}
        \\assert.sameValue(strictOuterCaught, true);
        \\let strictInnerCaught = false;
        \\try {
        \\  (function named() { return function inner() { "use strict"; named = 0; }; })()();
        \\} catch (error) {
        \\  strictInnerCaught = error instanceof TypeError;
        \\}
        \\// SetMutableBinding throws when the assigning code is strict (§9.1.1.1.5).
        \\assert.sameValue(strictInnerCaught, true);
        \\let emptyWith = {};
        \\let emptyWithBinding = (function named() {
        \\  with (emptyWith) { named += 1; }
        \\  return typeof named;
        \\})();
        \\assert.sameValue(emptyWithBinding, "function");
        \\assert.sameValue(Object.prototype.hasOwnProperty.call(emptyWith, "named"), false);
        \\let hitWith = { named: 1 };
        \\let hitWithBinding = (function named() {
        \\  with (hitWith) { named += 1; }
        \\  return typeof named;
        \\})();
        \\assert.sameValue(hitWithBinding, "function");
        \\assert.sameValue(hitWith.named, 2);
        \\let lateWith = {};
        \\(function named() {
        \\  with (lateWith) { named += (lateWith.named = 10, 1); }
        \\})();
        \\assert.sameValue(lateWith.named, 10);
        \\let deletedWith = { named: 1 };
        \\(function named() {
        \\  with (deletedWith) { named += (delete deletedWith.named, 2); }
        \\})();
        \\assert.sameValue(deletedWith.named, 3);
        \\let sloppyEvalBinding = (function named() {
        \\  eval("named = 0; named += 1; named++; ++named;");
        \\  return typeof named;
        \\})();
        \\assert.sameValue(sloppyEvalBinding, "function");
        \\let strictEvalInSloppyCaught = false;
        \\try {
        \\  (function named() { eval('"use strict"; named = 0;'); })();
        \\} catch (error) {
        \\  strictEvalInSloppyCaught = error instanceof TypeError;
        \\}
        \\assert.sameValue(strictEvalInSloppyCaught, true);
        \\let strictEvalCaught = false;
        \\try {
        \\  (function named() { "use strict"; eval("named = 0;"); })();
        \\} catch (error) {
        \\  strictEvalCaught = error instanceof TypeError;
        \\}
        \\assert.sameValue(strictEvalCaught, true);
        \\let defaultRead = function named(value = named) { return value; };
        \\assert.sameValue(defaultRead(), defaultRead);
        \\let defaultWrites = function named(
        \\  direct = (named = 0),
        \\  compound = (named += 1),
        \\  post = named++,
        \\  pre = ++named,
        \\  array = ([named] = [0]),
        \\  object = ({ value: named } = { value: 0 }),
        \\  deleted = delete named
        \\) { return named === defaultWrites && deleted === false; };
        \\assert.sameValue(defaultWrites(), true);
        \\let strictDefaultCaught = false;
        \\try {
        \\  let strictDefault = (function() {
        \\    "use strict";
        \\    return function named(value = (named = 0)) {};
        \\  })();
        \\  strictDefault();
        \\} catch (error) {
        \\  strictDefaultCaught = error instanceof TypeError;
        \\}
        \\assert.sameValue(strictDefaultCaught, true);
        \\let sameParameterTdz = false;
        \\try { (function named(named = named) {})(); } catch (error) {
        \\  sameParameterTdz = error instanceof ReferenceError;
        \\}
        \\assert.sameValue(sameParameterTdz, true);
        \\let nestedDefault = function named() {
        \\  return ((value = named) => value)();
        \\};
        \\assert.sameValue(nestedDefault(), nestedDefault);
        \\let generatorDefault = function* named(value = named) { yield value; };
        \\assert.sameValue(generatorDefault().next().value, generatorDefault);
    );

    try std.testing.expect(result.is(.undefined_value));
}

test "shared test engine reset rebuilds global shape hash buckets" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    _ = try js.eval("assert.sameValue(1 + 1, 2, 'sum');");
    try std.testing.expectError(error.JSException, js.eval("assert.sameValue(1, 2);"));
    try std.testing.expectError(error.JSException, js.eval("throw new Test262Error('boom');"));
    helpers.endSharedTest();

    const clean = helpers.sharedTestEngine();
    var output_buffer: [16]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const clean_result = try clean.evalWithOutput(
        \\"use strict";
        \\print(this === globalThis);
    , &stream);

    try std.testing.expect(clean_result.is(.undefined_value));
    try std.testing.expectEqualStrings("true\n", stream.buffered());
}

test "Engine eval strips TypeScript source kind before execution" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try helpers.evalTypeScriptChecked(js,
        \\type Label = string;
        \\interface Box { value: number }
        \\const value: number = 41;
        \\function add(input: number): number { return input + 1; }
        \\assert.sameValue(add(value), 42 as number);
    , .{});
    try std.testing.expect(result.is(.undefined_value));
}

test "Engine eval strips TypeScript method annotations" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try helpers.evalTypeScriptChecked(js,
        \\class C { m(x: number): number { return x; } }
        \\const object = { m(x: number): number { return x + 1; } };
        \\assert.sameValue(new C().m(41), 41);
        \\assert.sameValue(object.m(41), 42);
    , .{});
    try std.testing.expect(result.is(.undefined_value));
}

test "Engine eval preserves as and satisfies runtime property names in TypeScript files" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try helpers.evalTypeScriptChecked(js,
        \\const obj = { as: 1, satisfies: 2 };
        \\assert.sameValue(obj.as + obj.satisfies, 3);
    , .{});
    try std.testing.expect(result.is(.undefined_value));
}

test "Engine eval supports TypeScript parameter properties" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var result = try helpers.evalTypeScriptChecked(js,
        \\class Box {
        \\    constructor(public value: number) {}
        \\}
        \\const b = new Box(42);
        \\b.value === 42 ? 42 : 0
    , .{ .mode = .eval_indirect });
    try std.testing.expectEqual(@as(i32, 42), result.as(.int));
}

test "Engine eval strips TypeScript automatically for ts filenames" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try helpers.evalTypeScriptChecked(js,
        \\const value: number = 42;
        \\assert.sameValue(value, 42);
    , .{ .filename = "sample.ts" });
    try std.testing.expect(result.is(.undefined_value));
}

test "CallSite metadata is internal" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\Error.prepareStackTrace = function(err, sites) {
        \\    var site = sites[0];
        \\    assert.sameValue("__zjs_callsite" in site, false);
        \\    assert.sameValue("__zjs_callsite_line" in site, false);
        \\    assert.sameValue(typeof site.getFunction, "function");
        \\    assert.sameValue(typeof site.getThis, "undefined");
        \\    assert.sameValue(site.hasOwnProperty("getFunction"), false);
        \\    assert.sameValue(site.toString(), "[object CallSite]");
        \\    assert.sameValue(Object.prototype.toString.call(site), "[object CallSite]");
        \\    assert.sameValue(site[Symbol.toStringTag], "CallSite");
        \\    var name = site.getFunctionName();
        \\    var file = site.getFileName();
        \\    var line = site.getLineNumber();
        \\    var column = site.getColumnNumber();
        \\    site.__zjs_callsite_function = "fakeFn";
        \\    site.__zjs_callsite_file = "fake.js";
        \\    site.__zjs_callsite_line = 999;
        \\    site.__zjs_callsite_column = 777;
        \\    assert.sameValue(site.getFunctionName(), name);
        \\    assert.sameValue(site.getFileName(), file);
        \\    assert.sameValue(site.getLineNumber(), line);
        \\    assert.sameValue(site.getColumnNumber(), column);
        \\    assert.sameValue(site.toString().indexOf("fake"), -1);
        \\    return "ok";
        \\};
        \\function inner() {
        \\    return new Error("x").stack;
        \\}
        \\assert.sameValue(inner(), "ok");
        \\Error.prepareStackTrace = undefined;
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "pc2line stack locations match QuickJS return and throw matrix" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.evalWithOptions(
        \\function outer() {
        \\  return inner();
        \\}
        \\function inner() {
        \\  throw new Error("x");
        \\}
        \\var captured;
        \\try { outer(); } catch (error) { captured = error.stack; }
        \\assert.sameValue(captured.indexOf("at inner (pc2line.js:5:18)") >= 0, true);
        \\assert.sameValue(captured.indexOf("at outer (pc2line.js:2:3)") >= 0, true);
        \\assert.sameValue(captured.indexOf("at <eval> (pc2line.js:8:12)") >= 0, true);
    , .{ .filename = "pc2line.js" });
    try std.testing.expect(result.is(.undefined_value));
}

test "X-89 sloppy and method tails keep the caller like QuickJS; strict tail_call reuses" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.evalWithOptions(
        \\function outer() { return inner(); }
        \\function inner() { throw new Error("x"); }
        \\var captured;
        \\try { outer(); } catch (error) { captured = error.stack; }
        \\assert.sameValue(captured.indexOf("at inner") >= 0, true);
        \\assert.sameValue(captured.indexOf("at outer") >= 0, true);
        \\function strictOuter() { "use strict"; return strictInner(); }
        \\function strictInner() { throw new Error("s"); }
        \\try { strictOuter(); } catch (error) { captured = error.stack; }
        \\assert.sameValue(captured.indexOf("at strictInner") >= 0, true);
        \\assert.sameValue(captured.indexOf("at strictOuter") < 0, true);
        \\function methOuter() { "use strict"; return o.m(); }
        \\var o = { m: function m() { throw new Error("m"); } };
        \\try { methOuter(); } catch (error) { captured = error.stack; }
        \\assert.sameValue(captured.indexOf("at m") >= 0, true);
        \\assert.sameValue(captured.indexOf("at methOuter") >= 0, true);
    , .{ .filename = "x89-stack.js" });
    try std.testing.expect(result.is(.undefined_value));
}

test "strict plain tail_call recursion stays in constant stack" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\"use strict";
        \\function f(n) { if (n <= 0) return "foo"; return f(n - 1); }
        \\assert.sameValue(f(20000), "foo");
        \\function even(n) { return n <= 0 ? "foo" : odd(n - 1); }
        \\function odd(n) { return n <= 0 ? "bar" : even(n - 1); }
        \\assert.sameValue(even(20000), "foo");
        \\assert.sameValue(even(20001), "bar");
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "X-89 frame disasm: return call and method emit tail opcodes" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    _ = try js.eval(
        \\function tailPlain(x) { "use strict"; return g(x); }
        \\function sloppyPlain(x) { return g(x); }
        \\function tailMethod(o, x) { return o.m(x); }
        \\function strictCond(p) { "use strict"; return p ? f() : g(); }
        \\function sloppyCond(p) { return p ? f() : g(); }
    );

    var buf: [2048]u8 = undefined;

    const plain = try globalFunctionBytecode(js, "tailPlain");
    var plain_w = std.Io.Writer.fixed(&buf);
    try bytecode.dump.dumpFunctionBytecode(&plain_w, plain, js.runtime.atoms, .{});
    const plain_dump = plain_w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, plain_dump, ": tail_call ") != null);
    try std.testing.expect(std.mem.indexOf(u8, plain_dump, "tail_call_method") == null);
    try std.testing.expect(std.mem.indexOf(u8, plain_dump, ": return\n") != null);

    // Strict-only PTC: a sloppy plain tail stays an ordinary call so its
    // observable stack semantics keep matching QuickJS.
    const sloppy = try globalFunctionBytecode(js, "sloppyPlain");
    var sloppy_w = std.Io.Writer.fixed(&buf);
    try bytecode.dump.dumpFunctionBytecode(&sloppy_w, sloppy, js.runtime.atoms, .{});
    const sloppy_dump = sloppy_w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, sloppy_dump, "tail_call") == null);

    // Method folding is mode-independent: tail_call_method aliases
    // call_method at runtime, so the fold is unobservable.
    const method = try globalFunctionBytecode(js, "tailMethod");
    var method_w = std.Io.Writer.fixed(&buf);
    try bytecode.dump.dumpFunctionBytecode(&method_w, method, js.runtime.atoms, .{});
    const method_dump = method_w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, method_dump, ": tail_call_method ") != null);
    try std.testing.expect(std.mem.indexOf(u8, method_dump, ": return\n") != null);

    // Conditional-expression arms are tail positions in a strict function
    // (both arms converge on the shared return), but never fold in sloppy.
    const strict_cond = try globalFunctionBytecode(js, "strictCond");
    var strict_cond_w = std.Io.Writer.fixed(&buf);
    try bytecode.dump.dumpFunctionBytecode(&strict_cond_w, strict_cond, js.runtime.atoms, .{});
    const strict_cond_dump = strict_cond_w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, strict_cond_dump, ": tail_call ") != null);

    const sloppy_cond = try globalFunctionBytecode(js, "sloppyCond");
    var sloppy_cond_w = std.Io.Writer.fixed(&buf);
    try bytecode.dump.dumpFunctionBytecode(&sloppy_cond_w, sloppy_cond, js.runtime.atoms, .{});
    const sloppy_cond_dump = sloppy_cond_w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, sloppy_cond_dump, "tail_call") == null);

    // Concise-body arrows inherit the script's strictness, then the same
    // `call`→`tail_call` fold as `return g(x)` in a strict function.
    _ = try js.eval(
        \\"use strict";
        \\var arrowTail = (x) => g(x);
    );
    const arrow = try globalFunctionBytecode(js, "arrowTail");
    var arrow_w = std.Io.Writer.fixed(&buf);
    try bytecode.dump.dumpFunctionBytecode(&arrow_w, arrow, js.runtime.atoms, .{});
    const arrow_dump = arrow_w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, arrow_dump, ": tail_call ") != null);
    try std.testing.expect(std.mem.indexOf(u8, arrow_dump, "tail_call_method") == null);
}

test "pc2line malformed transition reports zero location instead of header fallback" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    _ = try js.eval(
        \\function malformedLocationTarget(value) {
        \\    return value + 1;
        \\}
    );

    const function = try globalFunctionBytecode(js, "malformedLocationTarget");
    const bytes = function.pc2lineBuf();
    try std.testing.expect(bytes.len > 2);
    const saved = try std.testing.allocator.dupe(u8, bytes);
    defer std.testing.allocator.free(saved);
    defer @memcpy(bytes, saved);

    // Keep a valid 1:1 header, then make the first compact transition's
    // zig-zag column ULEB run off the end of the authoritative buffer.
    bytes[0] = 0;
    bytes[1] = 0;
    @memset(bytes[2..], 0x80);
    const location = engine.exec.exception_ops.resolveBacktraceLocation(function, 0);
    try std.testing.expectEqual(@as(i32, 0), location.line_num);
    try std.testing.expectEqual(@as(i32, 0), location.col_num);
}

test "Error stack uses object method runtime names" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var object = {
        \\    return() {
        \\        return new Error("x").stack;
        \\    }
        \\};
        \\var stack = object.return();
        \\assert.sameValue(stack.indexOf("at return") >= 0, true);
        \\assert.sameValue(stack.indexOf("    at return"), 0);
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "native builtin errors capture a native callsite" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var defaultStack;
        \\try {
        \\    [].map(null);
        \\} catch (error) {
        \\    defaultStack = error.stack;
        \\}
        \\assert.sameValue(defaultStack.indexOf("    at map (native)"), 0);
        \\var callStack;
        \\try {
        \\    Array.prototype.map.call([], null);
        \\} catch (error) {
        \\    callStack = error.stack;
        \\}
        \\assert.sameValue(callStack.indexOf("    at map (native)\n    at call (native)"), 0);
        \\function forwardedCallTarget() { return new Error("forwarded").stack; }
        \\var forwardedCallStack = forwardedCallTarget.call(undefined);
        \\var forwardedFirstNewline = forwardedCallStack.indexOf("\n");
        \\assert.sameValue(forwardedCallStack.indexOf("    at forwardedCallTarget"), 0);
        \\assert.sameValue(forwardedCallStack.slice(forwardedFirstNewline + 1).indexOf("    at call (native)"), 0);
        \\function forwardedCallCaller() {
        \\    var stack = forwardedCallTarget.call(undefined);
        \\    return stack + "";
        \\}
        \\var forwardedNestedStack = forwardedCallCaller();
        \\var forwardedNestedFirst = forwardedNestedStack.indexOf("\n");
        \\var forwardedNestedSecond = forwardedNestedStack.indexOf("\n", forwardedNestedFirst + 1);
        \\assert.sameValue(forwardedNestedStack.indexOf("    at forwardedCallTarget"), 0);
        \\assert.sameValue(forwardedNestedStack.slice(forwardedNestedFirst + 1).indexOf("    at call (native)"), 0);
        \\assert.sameValue(forwardedNestedStack.slice(forwardedNestedSecond + 1).indexOf("    at forwardedCallCaller"), 0);
        \\// Exact-args forwarding (the O1 forwarded leaf, WP7): the frame
        \\// carries an argument window AND the skipped native record, so the
        \\// `target -> call/apply (native) -> caller` order must survive the
        \\// leaf construction and its narrow return epilogue.
        \\function forwardedArgTarget(x) { return new Error("forwarded " + x).stack; }
        \\var forwardedArgStack = forwardedArgTarget.call(undefined, 7);
        \\var forwardedArgNewline = forwardedArgStack.indexOf("\n");
        \\assert.sameValue(forwardedArgStack.indexOf("    at forwardedArgTarget"), 0);
        \\assert.sameValue(forwardedArgStack.slice(forwardedArgNewline + 1).indexOf("    at call (native)"), 0);
        \\var forwardedApplyStack = forwardedArgTarget.apply(undefined, [8]);
        \\var forwardedApplyNewline = forwardedApplyStack.indexOf("\n");
        \\assert.sameValue(forwardedApplyStack.indexOf("    at forwardedArgTarget"), 0);
        \\assert.sameValue(forwardedApplyStack.slice(forwardedApplyNewline + 1).indexOf("    at apply (native)"), 0);
        \\function forwardedArgThrower(x) { throw new Error("boom " + x); }
        \\var forwardedThrowStack;
        \\try { forwardedArgThrower.call(undefined, 9); } catch (error) { forwardedThrowStack = error.stack; }
        \\assert.sameValue(forwardedThrowStack.indexOf("    at forwardedArgThrower"), 0);
        \\assert.sameValue(forwardedThrowStack.slice(forwardedThrowStack.indexOf("\n") + 1).indexOf("    at call (native)"), 0);
        \\var applyStack;
        \\try {
        \\    Array.prototype.map.apply([], [null]);
        \\} catch (error) {
        \\    applyStack = error.stack;
        \\}
        \\assert.sameValue(applyStack.indexOf("    at map (native)\n    at apply (native)"), 0);
        \\var rawErrorStack;
        \\try {
        \\    String.fromCharCode(Symbol());
        \\} catch (error) {
        \\    rawErrorStack = error.stack;
        \\}
        \\assert.sameValue(rawErrorStack.indexOf("    at fromCharCode (native)"), 0);
        \\var nestedRawErrorStack;
        \\try {
        \\    [][Symbol.iterator]().next.call({});
        \\} catch (error) {
        \\    nestedRawErrorStack = error.stack;
        \\}
        \\assert.sameValue(nestedRawErrorStack.indexOf("    at next (native)\n    at call (native)"), 0);
        \\var arrayConstructStack;
        \\try { new Array(-1); } catch (error) { arrayConstructStack = error.stack; }
        \\assert.sameValue(arrayConstructStack.indexOf("    at Array (native)"), 0);
        \\var regexpConstructStack;
        \\try { new RegExp("["); } catch (error) { regexpConstructStack = error.stack; }
        \\assert.sameValue(regexpConstructStack.indexOf("    at RegExp (native)"), 0);
        \\var regexpCallStack;
        \\try { RegExp("["); } catch (error) { regexpCallStack = error.stack; }
        \\assert.sameValue(regexpCallStack.indexOf("    at RegExp (native)"), 0);
        \\assert.sameValue(regexpCallStack.indexOf("    at <anonymous> (native)"), -1);
        \\var stringConstructStack;
        \\try { new String(Symbol()); } catch (error) { stringConstructStack = error.stack; }
        \\assert.sameValue(stringConstructStack.indexOf("    at String (native)"), 0);
        \\var dateConstructStack;
        \\try { new Date(Symbol()); } catch (error) { dateConstructStack = error.stack; }
        \\assert.sameValue(dateConstructStack.indexOf("    at Date (native)"), 0);
        \\Error.prepareStackTrace = function(_, sites) {
        \\    return sites.map(function(site) {
        \\        return [site.getFunctionName(), site.isNative()];
        \\    });
        \\};
        \\function outerMapBacktrace() {
        \\    return [1].map(function callback() {
        \\        return new Error("cross-machine").stack;
        \\    })[0];
        \\}
        \\var crossMachineSites = outerMapBacktrace();
        \\assert.sameValue(crossMachineSites[0][0], "callback");
        \\assert.sameValue(crossMachineSites[0][1], false);
        \\assert.sameValue(crossMachineSites[1][0], "map");
        \\assert.sameValue(crossMachineSites[1][1], true);
        \\assert.sameValue(crossMachineSites[2][0], "outerMapBacktrace");
        \\assert.sameValue(crossMachineSites[2][1], false);
        \\function nativeFenceHelper() {
        \\    return new Error("same-machine").stack;
        \\}
        \\function nativeFenceCallback() {
        \\    return nativeFenceHelper();
        \\}
        \\function nativeFenceOuter() {
        \\    return nativeFenceCallback.apply(null, []);
        \\}
        \\var sameMachineSites = nativeFenceOuter();
        \\assert.sameValue(sameMachineSites[0][0], "nativeFenceHelper");
        \\assert.sameValue(sameMachineSites[0][1], false);
        \\assert.sameValue(sameMachineSites[1][0], "nativeFenceCallback");
        \\assert.sameValue(sameMachineSites[1][1], false);
        \\assert.sameValue(sameMachineSites[2][0], "apply");
        \\assert.sameValue(sameMachineSites[2][1], true);
        \\assert.sameValue(sameMachineSites[3][0], "nativeFenceOuter");
        \\assert.sameValue(sameMachineSites[3][1], false);
        \\Error.prepareStackTrace = undefined;
        \\Error.prepareStackTrace = function(error, sites) {
        \\    assert.sameValue(sites[0].getFunctionName(), "map");
        \\    assert.sameValue(sites[0].getFileName(), null);
        \\    assert.sameValue(sites[0].getLineNumber(), null);
        \\    assert.sameValue(sites[0].getColumnNumber(), null);
        \\    assert.sameValue(sites[0].isNative(), true);
        \\    assert.sameValue(sites[1].getFunctionName(), "call");
        \\    assert.sameValue(sites[1].isNative(), true);
        \\    assert.sameValue(sites[2].isNative(), false);
        \\    return "native:map:call";
        \\};
        \\try {
        \\    Array.prototype.map.call([], null);
        \\} catch (error) {
        \\    assert.sameValue(error.stack, "native:map:call");
        \\}
        \\Error.prepareStackTrace = function(_, sites) { return sites; };
        \\var callSiteProto = Object.getPrototypeOf(new Error().stack[0]);
        \\[{}, 1, undefined].forEach(function(receiver) {
        \\    try { callSiteProto.getFileName.call(receiver); throw 0; }
        \\    catch (error) { assert.sameValue(error.message, "CallSite method expects CallSite as receiver"); }
        \\});
        \\Error.prepareStackTrace = undefined;
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "external host errors capture the native host callsite" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var probe: u8 = 0;
    try js.defineGlobalExternalHostFunction(
        "hostBacktraceProbe",
        0,
        &probe,
        HostBacktraceErrorProbe.call,
        null,
    );

    var output_buffer: [4096]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    _ = try js.evalWithOptions(
        \\function captureHostBacktrace() {
        \\    try {
        \\        hostBacktraceProbe();
        \\    } catch (error) {
        \\        return String(error.stack);
        \\    }
        \\}
        \\function captureInternalBacktrace() {
        \\    try {
        \\        [].map(null);
        \\    } catch (error) {
        \\        return String(error.stack);
        \\    }
        \\}
        \\const hostStack = captureHostBacktrace();
        \\const internalStack = captureInternalBacktrace();
        \\print(hostStack.indexOf(
        \\    "    at hostBacktraceProbe (native)\n    at captureHostBacktrace "
        \\) === 0);
        \\print(internalStack.indexOf(
        \\    "    at map (native)\n    at captureInternalBacktrace "
        \\) === 0);
    , .{ .filename = "host-backtrace.js", .output = &stream });

    try std.testing.expectEqualStrings("true\ntrue\n", stream.buffered());
}

test "native record calls preflight the native stack and recover" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    js.runtime.setNativeStackSize(64 * 1024);
    try js.ensureTest262GlobalsInstalled();

    const function_value = try core.function.nativeFunction(js.context, "nativeEntryRecurse", 0);
    const function_object = core.Object.fromHeader(function_value.refHeader().?);
    function_object.nativeEntrySlot().* = &NativeRecordStackProbe.record;

    const global = try js.context.globalObject();
    const name = try js.runtime.internAtom("nativeEntryRecurse");
    try global.defineOwnProperty(
        js.runtime,
        name,
        core.Descriptor.data(function_value, .method),
    );

    NativeRecordStackProbe.callable = function_value;
    NativeRecordStackProbe.calls = 0;
    NativeRecordStackProbe.recurse = true;
    defer NativeRecordStackProbe.callable = core.JSValue.undefinedValue();

    _ = try js.eval(
        \\let nativeStackResult = "missing";
        \\try {
        \\    nativeEntryRecurse();
        \\} catch (error) {
        \\    nativeStackResult = error.name + ":" + error.message;
        \\}
        \\assert.sameValue(nativeStackResult, "InternalError:stack overflow");
    );

    NativeRecordStackProbe.recurse = false;
    const recovery = try js.eval("assert.sameValue(nativeEntryRecurse(), 7);");
    try std.testing.expect(recovery.is(.undefined_value));
}

test "external C function preflight uses caller realm and callback errors use callee realm" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var caller_facade = zjs.borrowContext(js.context);
    const caller_global = try zjs.globalObjectPtr(&caller_facade);
    const callee_holder = try engine.exec.call.createRealmObject(js.context);
    const callee_record = try core.Object.expect(callee_holder);
    const callee = callee_record.realmContext() orelse return error.TestUnexpectedResult;
    const callee_global = try engine.exec.zjs_vm.contextGlobal(callee);

    var probe: CrossRealmNativeProbe = .{};
    const native_value = try core.function.nativeFunction(callee, "realmProbe", 0);
    const native_object = try core.Object.expect(native_value);
    try helpers.TestEngine.installLegacyProbeEntry(js.runtime, native_object, &probe, crossRealmNativeProbe);

    js.runtime.setNativeStackSize(1);
    defer js.runtime.setNativeStackSize(0);
    try std.testing.expectError(
        error.StackOverflow,
        engine.exec.call_runtime.callValueOrBytecodeRoot(
            js.context,
            null,
            caller_global,
            core.JSValue.undefinedValue(),
            native_value,
            &.{},
            null,
            null,
        ),
    );
    try std.testing.expect(probe.seen_realm == null);
    try std.testing.expect(js.context.hasException());

    const overflow_value = js.context.takeException();
    const overflow_error = try core.Object.expect(overflow_value);
    const caller_internal_error = object_ops.constructorPrototypeFromGlobal(
        js.runtime,
        caller_global,
        "InternalError",
    ) orelse return error.TestUnexpectedResult;
    const callee_internal_error = object_ops.constructorPrototypeFromGlobal(
        js.runtime,
        callee_global,
        "InternalError",
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(caller_internal_error, overflow_error.getPrototype().?);
    try std.testing.expect(caller_internal_error != callee_internal_error);

    js.runtime.setNativeStackSize(0);
    try std.testing.expectError(
        error.JSException,
        engine.exec.call_runtime.callValueOrBytecodeRoot(
            js.context,
            null,
            caller_global,
            core.JSValue.undefinedValue(),
            native_value,
            &.{},
            null,
            null,
        ),
    );
    try std.testing.expectEqual(callee, probe.seen_realm.?);
    try std.testing.expectEqual(callee_global, probe.seen_global.?);
    // Pending exceptions are runtime-wide; the Error prototype below is the
    // realm discriminator.
    try std.testing.expect(js.context.hasException());

    const callback_error_value = callee.takeException();
    const callback_error = try core.Object.expect(callback_error_value);
    const caller_type_error = object_ops.constructorPrototypeFromGlobal(
        js.runtime,
        caller_global,
        "TypeError",
    ) orelse return error.TestUnexpectedResult;
    const callee_type_error = object_ops.constructorPrototypeFromGlobal(
        js.runtime,
        callee_global,
        "TypeError",
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(callee_type_error, callback_error.getPrototype().?);
    try std.testing.expect(caller_type_error != callee_type_error);
}

test "Error stack preserves construction frames across delayed access" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\function makeError() {
        \\    return new Error("x");
        \\}
        \\var err = makeError();
        \\assert.sameValue(Object.prototype.hasOwnProperty.call(err, "stack"), false);
        \\function readStack(error) {
        \\    return error.stack;
        \\}
        \\var stack = readStack(err);
        \\assert.sameValue(typeof stack, "string");
        \\assert.sameValue(stack.indexOf("at makeError") >= 0, true);
        \\assert.sameValue(stack.indexOf("at readStack") < 0, true);
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "eval SyntaxError carries construction stack" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    // Pins the createNamedError stack capture: the SyntaxError materialized
    // for a failed `eval` parse used to carry no call sites, so a delayed
    // `.stack` read fell back to the reader's frames and lost the
    // construction frame ("at evalThrower" was absent before the fix).
    const result = try js.eval(
        \\function evalThrower() {
        \\    try { eval("]"); } catch (e) { return e; }
        \\    return null;
        \\}
        \\var evalErr = evalThrower();
        \\assert.sameValue(evalErr instanceof SyntaxError, true);
        \\var evalStack = evalErr.stack;
        \\assert.sameValue(typeof evalStack, "string");
        \\assert.sameValue(evalStack.length > 0, true);
        \\assert.sameValue(evalStack.indexOf("at evalThrower") >= 0, true);
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "TypeError thrown via message helper carries stack exactly once" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    // Pins the throw*Message relocation: the TypeError thrown for calling a
    // non-callable keeps its construction stack ("at typeThrower"), and the
    // frame appears exactly once (no double attach from the former
    // shell-level capture plus the primitive-level capture).
    const result = try js.eval(
        \\function typeThrower() {
        \\    try { (0)(); } catch (e) { return e; }
        \\    return null;
        \\}
        \\var typeErr = typeThrower();
        \\assert.sameValue(typeErr instanceof TypeError, true);
        \\var typeStack = typeErr.stack;
        \\assert.sameValue(typeof typeStack, "string");
        \\assert.sameValue(typeStack.length > 0, true);
        \\assert.sameValue(typeStack.indexOf("at typeThrower") >= 0, true);
        \\assert.sameValue(typeStack.indexOf("at typeThrower"), typeStack.lastIndexOf("at typeThrower"));
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "Error prepareStackTrace formats captured frames lazily" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var calls = 0;
        \\Error.prepareStackTrace = function() {
        \\    calls++;
        \\    return "early";
        \\};
        \\function makeError() {
        \\    return new Error("x");
        \\}
        \\var err = makeError();
        \\assert.sameValue(calls, 0);
        \\Error.prepareStackTrace = function(error, sites) {
        \\    calls++;
        \\    assert.sameValue(error, err);
        \\    assert.sameValue(sites[0].getFunctionName(), "makeError");
        \\    return "late:" + sites[0].getFunctionName();
        \\};
        \\assert.sameValue(err.stack, "late:makeError");
        \\assert.sameValue(calls, 1);
        \\assert.sameValue(err.stack, "late:makeError");
        \\assert.sameValue(calls, 1);
        \\Error.prepareStackTrace = undefined;
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "Error stack setter rejects non-string stack values" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var err = new Error("x");
        \\assert.throws(TypeError, function() {
        \\    err.stack = 123;
        \\});
        \\assert.throws(TypeError, function() {
        \\    Object.getOwnPropertyDescriptor(Error.prototype, "stack").set.call(err);
        \\});
        \\assert.sameValue(Object.prototype.hasOwnProperty.call(err, "stack"), false);
        \\assert.sameValue(typeof err.stack, "string");
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "Error stack copied accessor setter writes without recursion" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var err = new Error("x");
        \\Object.defineProperty(err, "stack", Object.getOwnPropertyDescriptor(Error.prototype, "stack"));
        \\assert.throws(TypeError, function() {
        \\    err.stack = 123;
        \\});
        \\err.stack = "updated";
        \\var desc = Object.getOwnPropertyDescriptor(err, "stack");
        \\assert.sameValue(desc.value, "updated");
        \\assert.sameValue(desc.writable, true);
        \\assert.sameValue(err.stack, "updated");
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "Error stack copied accessor setter writes through proxy without recursion" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var proxy = new Proxy(new Error("x"), {});
        \\Object.defineProperty(proxy, "stack", Object.getOwnPropertyDescriptor(Error.prototype, "stack"));
        \\proxy.stack = "updated";
        \\var desc = Object.getOwnPropertyDescriptor(proxy, "stack");
        \\assert.sameValue(desc.value, "updated");
        \\assert.sameValue(desc.writable, true);
        \\assert.sameValue(proxy.stack, "updated");
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "Error stack reentrant formatting is capped to captured frames" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var previousLimit = Error.stackTraceLimit;
        \\Error.stackTraceLimit = 1;
        \\var calls = 0;
        \\Error.prepareStackTrace = function(error, sites) {
        \\    calls++;
        \\    sites.length = 3;
        \\    sites[2] = sites[0];
        \\    return error.stack;
        \\};
        \\var stack = new Error("x").stack;
        \\Error.prepareStackTrace = undefined;
        \\Error.stackTraceLimit = previousLimit;
        \\var frames = String(stack).split("\n").filter(function(line) {
        \\    return line.indexOf("    at ") === 0;
        \\});
        \\assert.sameValue(calls, 1);
        \\assert.sameValue(frames.length, 1);
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "Array fill respects proxy prototypes" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\var calls = [];
        \\var array = new Array(3);
        \\Object.setPrototypeOf(array, new Proxy(Array.prototype, {
        \\    set: function(target, key, value, receiver) {
        \\        calls.push(String(key) + ":" + value);
        \\        return Reflect.set(target, key, value, receiver);
        \\    }
        \\}));
        \\Array.prototype.fill.call(array, 7);
        \\assert.sameValue(calls.join(","), "0:7,1:7,2:7");
        \\assert.sameValue(array.join(","), "7,7,7");
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "Error.prepareStackTrace exceptions produce null stack" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    const result = try js.eval(
        \\Error.prepareStackTrace = function() {
        \\    throw new TypeError("prep");
        \\};
        \\assert.sameValue(new Error("x").stack, null);
        \\Error.prepareStackTrace = undefined;
    );
    try std.testing.expect(result.is(.undefined_value));
}

test "Engine runtime-strict file eval matches QuickJS CLI script surface" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOptions(
        \\function strictThis() { return this === undefined; }
        \\function cliLocalFunction() {}
        \\print(this === undefined);
        \\print(strictThis());
        \\var desc = Object.getOwnPropertyDescriptor(globalThis, "cliLocalFunction");
        \\print(desc !== undefined);
        \\print(cliLocalFunction.name);
        \\var roProto = {};
        \\Object.defineProperty(roProto, "locked", { value: 1, writable: false, configurable: true });
        \\var roObj = Object.create(roProto);
        \\try { roObj.locked = 2; print(false); } catch (e) { print(e instanceof TypeError); }
        \\try { missingQuickJsCliStrict = 1; print(false); } catch (e) { print(e instanceof ReferenceError); }
        \\var capture;
        \\eval("var evalCreated = 5; capture = function(){ return evalCreated; };");
        \\print(evalCreated);
        \\print(delete evalCreated);
        \\try { print(capture()); } catch (e) { print(e instanceof ReferenceError); }
    , .{ .output = &stream, .mode = .script, .filename = "runtime-strict-file.js", .runtime_strict = true });

    try std.testing.expect(result.is(.undefined_value));
    try std.testing.expectEqualStrings("true\ntrue\ntrue\ncliLocalFunction\ntrue\ntrue\n5\ntrue\ntrue\n", stream.buffered());
}

test "runtime-strict eval overrides parse-time mapped arguments subtype" {
    var js = try helpers.TestEngine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [96]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOptions(
        \\function forcedArguments(value) {
        \\  const before = arguments[0];
        \\  value = 7;
        \\  arguments[0] = 9;
        \\  let callee = "no-throw";
        \\  try { arguments.callee; } catch (error) { callee = error.name; }
        \\  print(before, value, arguments[0], callee);
        \\}
        \\forcedArguments(5);
    , .{ .output = &output, .mode = .script, .filename = "runtime-strict-arguments.js", .runtime_strict = true });

    try std.testing.expect(result.is(.undefined_value));
    try std.testing.expectEqualStrings("5 7 9 TypeError\n", output.buffered());
}

fn nativeReturnsUndefined(_: *core.JSContext, _: core.JSValue, _: []const core.JSValue) core.errors.HostError!core.JSValue {
    return core.JSValue.undefinedValue();
}

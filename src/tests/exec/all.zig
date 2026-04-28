const std = @import("std");
const engine = @import("quickjs_zig_engine");

const core = engine.core;

comptime {
    _ = @import("qjs_vm_test.zig");
}

fn makeFunction(rt: *core.Runtime, code: []const u8) !engine.bytecode.Bytecode {
    const name = try rt.internAtom("exec");
    defer rt.atoms.free(name);
    var function = engine.bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    errdefer function.deinit(rt);
    try function.setCode(code);
    return function;
}

fn runFunction(rt: *core.Runtime, ctx: *core.Context, function: *const engine.bytecode.Bytecode) !core.Value {
    _ = rt;
    var vm_instance = engine.exec.Vm.init(ctx);
    defer vm_instance.deinit();
    return vm_instance.run(function);
}

test "vm executes push constants arithmetic comparisons and return" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    var function = try makeFunction(rt, &.{
        engine.bytecode.emitter.known.push_i32, 2,                                      0, 0, 0,
        engine.bytecode.emitter.known.push_i32, 3,                                      0, 0, 0,
        243,                                    engine.bytecode.emitter.known.push_i32, 6, 0, 0,
        0,                                      253,
    });
    defer function.deinit(rt);

    const result = try runFunction(rt, ctx, &function);
    defer result.free(rt);
    try std.testing.expectEqual(true, result.asBool().?);
}

test "vm executes stack constants source locations and return_undef" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    var function = try makeFunction(rt, &.{
        engine.bytecode.emitter.known.source_loc,      0,                                        0,                                       0,                                        0,   7,                                          0, 0, 0,
        engine.bytecode.emitter.known.undefined_value, engine.bytecode.emitter.known.null_value, engine.bytecode.emitter.known.push_true, engine.bytecode.emitter.known.push_false, 178, engine.bytecode.emitter.known.return_undef,
    });
    defer function.deinit(rt);

    var vm_instance = engine.exec.Vm.init(ctx);
    defer vm_instance.deinit();
    const result = try vm_instance.run(&function);
    defer result.free(rt);
    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqual(@as(u32, 7), vm_instance.last_source_line);
}

test "constant pool execution retains returned constants" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const name = try rt.internAtom("const-return");
    defer rt.atoms.free(name);
    var function = engine.bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer function.deinit(rt);
    var emit = engine.bytecode.emitter.Emitter.init(&function);

    const str = try core.string.String.createAscii(rt, "hello");
    const value = str.value();
    _ = try emit.emitPushConst(value);
    value.free(rt);

    const result = try runFunction(rt, ctx, &function);
    defer result.free(rt);
    try std.testing.expect(result.isString());
}

test "property ops use shared object semantics" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const obj = try core.Object.create(rt, core.class.ids.object, null);
    defer obj.value().free(rt);
    const key = try rt.internAtom("x");
    defer rt.atoms.free(key);

    try engine.exec.property_ops.defineDataProperty(rt, obj, key, core.Value.int32(9));
    try engine.exec.property_ops.setProperty(rt, obj, key, core.Value.int32(10));
    const value = engine.exec.property_ops.getProperty(obj, key);
    try std.testing.expectEqual(@as(?i32, 10), value.asInt32());

    const direct_value = try engine.exec.property_ops.getPropertyValue(rt, obj.value(), key);
    defer direct_value.free(rt);
    try std.testing.expectEqual(@as(?i32, 10), direct_value.asInt32());

    const key_string_obj = try core.string.String.createUtf8(rt, "x");
    const key_string = key_string_obj.value();
    defer key_string.free(rt);
    const in_result = try engine.exec.property_ops.propertyIn(rt, obj.value(), key_string);
    try std.testing.expectEqual(true, in_result.asBool().?);

    const optional_result = try engine.exec.property_ops.optionalGetPropertyValue(rt, core.Value.nullValue(), key);
    try std.testing.expect(optional_result.isUndefined());

    try std.testing.expect(engine.exec.property_ops.deleteProperty(rt, obj, key));
}

test "value ops own primitive VM semantics" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    const sum = try engine.exec.value_ops.binary(rt, engine.bytecode.emitter.known.add, core.Value.int32(2), core.Value.int32(3));
    defer sum.free(rt);
    try std.testing.expectEqual(@as(?i32, 5), sum.asInt32());

    const suffix_obj = try core.string.String.createUtf8(rt, "px");
    const suffix = suffix_obj.value();
    defer suffix.free(rt);
    const joined = try engine.exec.value_ops.binary(rt, engine.bytecode.emitter.known.add, core.Value.int32(2), suffix);
    defer joined.free(rt);

    var joined_text = std.ArrayList(u8).empty;
    defer joined_text.deinit(rt.memory.allocator);
    try engine.exec.value_ops.appendRawString(rt, &joined_text, joined);
    try std.testing.expectEqualStrings("2px", joined_text.items);

    const one_obj = try core.string.String.createUtf8(rt, "1");
    const one_string = one_obj.value();
    defer one_string.free(rt);
    try std.testing.expectEqual(true, engine.exec.value_ops.looseEqual(core.Value.int32(1), one_string).asBool().?);
    try std.testing.expectEqual(false, engine.exec.value_ops.toBooleanValue(core.Value.int32(0)).asBool().?);
}

test "closure helper stores closure state outside the VM" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    const closure_value = try engine.exec.closure.create(rt, 2, 0, 0, 0);
    defer closure_value.free(rt);
    const first = try engine.exec.closure.call(rt, closure_value, &.{}, &.{});
    defer first.free(rt);
    const second = try engine.exec.closure.call(rt, closure_value, &.{}, &.{});
    defer second.free(rt);

    try std.testing.expectEqual(@as(?i32, 1), first.asInt32());
    try std.testing.expectEqual(@as(?i32, 2), second.asInt32());
}

test "test262 helpers own SameValue assertions" {
    const same_nan = try engine.exec.test262_helpers.assertSameValue(core.Value.float64(std.math.nan(f64)), core.Value.float64(std.math.nan(f64)));
    try std.testing.expect(same_nan.isUndefined());
    try std.testing.expectError(error.Test262Error, engine.exec.test262_helpers.assertSameValue(core.Value.int32(1), core.Value.int32(2)));
}

test "call subsystem installs and invokes host globals" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const global = try core.Object.create(rt, core.class.ids.object, null);
    defer global.value().free(rt);
    try engine.exec.call.installHostGlobals(rt, global);

    const print_key = try rt.internAtom("print");
    defer rt.atoms.free(print_key);
    const print = global.getProperty(print_key);
    defer print.free(rt);

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const args = [_]core.Value{ core.Value.int32(1), core.Value.boolean(true) };
    const result = try engine.exec.call.callValue(ctx, &stream, print, &args);
    defer result.free(rt);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("1 true\n", stream.buffered());

    const assert_key = try rt.internAtom("assert");
    defer rt.atoms.free(assert_key);
    const same_value_key = try rt.internAtom("sameValue");
    defer rt.atoms.free(same_value_key);
    const assert_object_value = global.getProperty(assert_key);
    defer assert_object_value.free(rt);
    const assert_object_header = assert_object_value.refHeader().?;
    const assert_object: *core.Object = @fieldParentPtr("header", assert_object_header);
    const same_value = assert_object.getProperty(same_value_key);
    defer same_value.free(rt);

    const same_args = [_]core.Value{ core.Value.float64(std.math.nan(f64)), core.Value.float64(std.math.nan(f64)) };
    const same_result = try engine.exec.call.callValue(ctx, null, same_value, &same_args);
    defer same_result.free(rt);
    try std.testing.expect(same_result.isUndefined());
    const mismatch_args = [_]core.Value{ core.Value.int32(1), core.Value.int32(2) };
    try std.testing.expectError(error.Test262Error, engine.exec.call.callValue(ctx, null, same_value, &mismatch_args));

    const test262_key = try rt.internAtom("Test262Error");
    defer rt.atoms.free(test262_key);
    const test262_ctor = global.getProperty(test262_key);
    defer test262_ctor.free(rt);
    try std.testing.expectError(error.Test262Error, engine.exec.call.callValue(ctx, null, test262_ctor, &.{}));

    const map_value = try engine.builtins.collection.construct(rt, 1);
    defer map_value.free(rt);
    const map_object: *core.Object = @fieldParentPtr("header", map_value.refHeader().?);
    const set_key = try rt.internAtom("set");
    defer rt.atoms.free(set_key);
    const get_key = try rt.internAtom("get");
    defer rt.atoms.free(get_key);
    const map_set = map_object.getProperty(set_key);
    defer map_set.free(rt);
    const map_get = map_object.getProperty(get_key);
    defer map_get.free(rt);
    const stored_key_obj = try core.string.String.createUtf8(rt, "key");
    const stored_key = stored_key_obj.value();
    defer stored_key.free(rt);
    const stored_value_obj = try core.string.String.createUtf8(rt, "value");
    const stored_value = stored_value_obj.value();
    defer stored_value.free(rt);
    const set_args = [_]core.Value{ stored_key, stored_value };
    const set_result = try engine.exec.call.callValueWithThis(ctx, null, map_value, map_set, &set_args);
    defer set_result.free(rt);
    try std.testing.expect(set_result.same(map_value));
    try std.testing.expectError(error.TypeError, engine.exec.call.callValue(ctx, null, map_set, &set_args));
    const get_result = try engine.exec.call.callValueWithThis(ctx, null, map_value, map_get, &.{stored_key});
    defer get_result.free(rt);
    var get_text = std.ArrayList(u8).empty;
    defer get_text.deinit(std.testing.allocator);
    try engine.exec.value_ops.appendRawString(rt, &get_text, get_result);
    try std.testing.expectEqualStrings("value", get_text.items);
}

test "vm collection constructors use registered prototype methods" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const name = try rt.internAtom("collection-prototype");
    defer rt.atoms.free(name);
    var function = engine.bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer function.deinit(rt);
    var emit = engine.bytecode.emitter.Emitter.init(&function);
    try emit.emitNewCollection(1);

    var vm_instance = engine.exec.Vm.init(ctx);
    defer vm_instance.deinit();
    const result = try vm_instance.run(&function);
    defer result.free(rt);

    const object: *core.Object = @fieldParentPtr("header", result.refHeader().?);
    const set_key = try rt.internAtom("set");
    defer rt.atoms.free(set_key);
    try std.testing.expect(object.getPrototype() != null);
    try std.testing.expect(!object.hasOwnProperty(set_key));
    try std.testing.expect(object.hasProperty(set_key));
    try std.testing.expect(object.getPrototype().?.hasOwnProperty(set_key));
}

test "Engine eval executes test262 helpers through generic call paths" {
    var js = try engine.Engine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.eval("assert.sameValue(1 + 1, 2, 'sum');");
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());
    try std.testing.expectError(error.Test262Error, js.eval("assert.sameValue(1, 2);"));
    try std.testing.expectError(error.Test262Error, js.eval("throw new Test262Error('boom');"));
}

test "Engine eval TypeError with evaluated arguments does not double free constants" {
    {
        var js = try engine.Engine.init(std.testing.allocator);
        defer js.deinit();
        try std.testing.expectError(error.TypeError, js.eval("const obj = {}; obj.missing(\"a\", \"a\");"));
    }
    {
        var js = try engine.Engine.init(std.testing.allocator);
        defer js.deinit();
        try std.testing.expectError(error.TypeError, js.eval("RegExp.test(\"a\", \"a\");"));
    }
}

test "vm call handler accepts allocator-backed argument lists" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const name = try rt.internAtom("wide-call");
    defer rt.atoms.free(name);
    var function = engine.bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer function.deinit(rt);
    var emit = engine.bytecode.emitter.Emitter.init(&function);

    const print_key = try rt.internAtom("print");
    defer rt.atoms.free(print_key);
    try emit.emitGetVar(print_key);

    var arg: i32 = 1;
    while (arg <= 40) : (arg += 1) try emit.emitPushInt32(arg);
    try emit.emitCall(40);

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    var vm_instance = engine.exec.Vm.initWithOutput(ctx, &stream);
    defer vm_instance.deinit();
    const result = try vm_instance.run(&function);
    defer result.free(rt);

    var expected = std.ArrayList(u8).empty;
    defer expected.deinit(std.testing.allocator);
    var expected_arg: i32 = 1;
    while (expected_arg <= 40) : (expected_arg += 1) {
        if (expected_arg != 1) try expected.append(std.testing.allocator, ' ');
        var int_buf: [16]u8 = undefined;
        const printed = try std.fmt.bufPrint(&int_buf, "{d}", .{expected_arg});
        try expected.appendSlice(std.testing.allocator, printed);
    }
    try expected.append(std.testing.allocator, '\n');

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings(expected.items, stream.buffered());
}

var job_counter: usize = 0;

fn countJob() void {
    job_counter += 1;
}

test "Engine API eval and job queue are wired" {
    var js = try engine.Engine.init(std.testing.allocator);
    defer js.deinit();

    const result = try js.eval("1 2");
    defer result.free(js.runtime);
    try std.testing.expect(result.isUndefined());

    job_counter = 0;
    try js.job_queue.enqueue(countJob);
    try js.job_queue.enqueue(countJob);
    js.runJobs();
    try std.testing.expectEqual(@as(usize, 2), job_counter);

    job_counter = 0;
    var i: usize = 0;
    while (i < 16) : (i += 1) try js.job_queue.enqueue(countJob);
    js.runJobs();
    try std.testing.expectEqual(@as(usize, 16), job_counter);
}

test "job queue enqueue propagates allocator failure" {
    var buffer: [0]u8 = .{};
    var fixed = std.heap.FixedBufferAllocator.init(&buffer);
    var account = core.memory.MemoryAccount.init(fixed.allocator());
    var queue = engine.exec.jobs.Queue.init(&account);
    defer queue.deinit();

    try std.testing.expectError(error.OutOfMemory, queue.enqueue(countJob));
    try std.testing.expectEqual(@as(usize, 0), queue.jobs.len);
}

test "Engine eval executes simple variable assignment and print" {
    var js = try engine.Engine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput("let value = 5; value = value + 7; print(value);", &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("12\n", stream.buffered());
}

test "Engine eval executes object property assignment through quick parser" {
    var js = try engine.Engine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput("const obj = { x: 1 }; obj.x = obj.x + 2; print(obj.x);", &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("3\n", stream.buffered());
}

test "Engine eval executes parenthesized literal postfix through quick parser" {
    var js = try engine.Engine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput("const obj = { x: 1 }; print(({ y: obj.x + 2 }).y); print(([3, 4])[1]);", &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("3\n4\n", stream.buffered());
}

test "Engine eval executes compound assignment and update statements through quick parser" {
    var js = try engine.Engine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput("let x = 10; x += 5; x -= 3; x *= 2; x /= 4; x %= 5; x++; x--; print(x);", &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("1\n", stream.buffered());
}

test "Engine eval executes console.log with many arguments" {
    var js = try engine.Engine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [1024]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput("console.log(1,2,3,4,5,6,7,8,9,10);", &stream);
    defer result.free(js.runtime);
    const output = stream.buffered();
    try std.testing.expectEqualStrings("1 2 3 4 5 6 7 8 9 10\n", output);
}

test "Engine eval routes host output through global function calls" {
    var js = try engine.Engine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [512]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\print(1);
        \\console.log("x");
        \\const out = print;
        \\out(2 + 3, typeof out);
        \\const logger = console.log;
        \\logger("ok");
        \\const c = console;
        \\c.log("alias");
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("1\nx\n5 function\nok\nalias\n", stream.buffered());
}

test "Engine eval executes simple template interpolation" {
    var js = try engine.Engine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput("const x = 10; const y = 20; print(`${x} + ${y} = ${x + y}`);", &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("10 + 20 = 30\n", stream.buffered());
}

test "Engine eval executes simple arrays and map" {
    var js = try engine.Engine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput("const arr = [1, 2, 3]; print(arr); print(arr.length); print(arr[0]); print(arr.map(x => x * 2));", &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("1,2,3\n3\n1\n2,4,6\n", stream.buffered());
}

test "Engine eval executes simple functions and arrows" {
    var js = try engine.Engine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function add(a, b) { return a + b; }
        \\print(add(2, 3));
        \\const double = x => x * 2;
        \\print(double(21));
        \\function fact(n) { return n <= 1 ? 1 : n * fact(n - 1); }
        \\print(fact(6));
        \\const mul = (a, b) => { return a * b; };
        \\print(mul(3, 4));
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("5\n42\n720\n12\n", stream.buffered());
}

test "Engine eval executes JSON smoke subset" {
    var js = try engine.Engine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [512]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\const obj = { a: 1, b: 2 };
        \\const str = JSON.stringify(obj);
        \\console.log(str);
        \\const parsed = JSON.parse(str);
        \\console.log(parsed.a);
        \\console.log(parsed.b);
        \\console.log(JSON.stringify({ a: undefined, b: null, c: 1 }));
        \\console.log(JSON.stringify([undefined, null, 1]));
        \\console.log(JSON.stringify(undefined));
        \\console.log(JSON.stringify(NaN));
        \\console.log(JSON.stringify(Infinity));
        \\console.log(JSON.stringify(-Infinity));
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("{\"a\":1,\"b\":2}\n1\n2\n{\"b\":null,\"c\":1}\n[null,null,1]\nundefined\nnull\nnull\nnull\n", stream.buffered());
}

test "Engine eval executes Math smoke subset" {
    var js = try engine.Engine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [512]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\print(Math.abs(-5));
        \\print(Math.floor(3.7));
        \\print(Math.sqrt(2));
        \\print(Math.pow(4, 0.5));
        \\print(Math.min(1, 2, 3));
        \\const randomValue = Math.random();
        \\print(typeof randomValue);
        \\print(randomValue >= 0);
        \\print(randomValue < 1);
        \\print(1 / -0);
        \\print(Object.is(-0, -0));
        \\print(Object.is(0, -0));
        \\print(typeof Math.acosh);
        \\print(Math.acosh(0));
        \\print(Math.atanh(2));
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("5\n3\n1.4142135623730951\n2\n1\nnumber\ntrue\ntrue\n-Infinity\ntrue\nfalse\nfunction\nNaN\nNaN\n", stream.buffered());
}

test "Engine eval executes allocator-backed wide Math min max calls" {
    var js = try engine.Engine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [96]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\print(Math.min(9, 8, 7, 6, 5, 4));
        \\print(Math.max(4, 5, 6, 7, 8, 9));
        \\print(Math.abs());
        \\print(Math.abs(undefined));
        \\print(Math.abs(null));
        \\print(Math.abs(true));
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("4\n9\nNaN\nNaN\n0\n1\n", stream.buffered());
}

test "Engine eval executes Date smoke fixture subset" {
    var js = try engine.Engine.init(std.testing.allocator);
    defer js.deinit();

    var quick_output_buffer: [512]u8 = undefined;
    var quick_stream = std.Io.Writer.fixed(&quick_output_buffer);
    const quick_result = try js.evalWithOutput(
        \\print(typeof Date());
        \\print(typeof new Date());
        \\print(Date.UTC(2024, 0, 1));
        \\print(Date.parse("2024-01-01T00:00:00Z"));
        \\const epoch = new Date(0);
        \\print(epoch.getTime());
        \\print(epoch.toISOString());
        \\print(epoch.getUTCFullYear());
        \\const local = new Date(2024, 0, 2, 3, 4, 5, 6);
        \\print(local.getFullYear());
        \\print(local.getMonth());
        \\print(local.getDate());
        \\print(local.getHours());
        \\print(local.getMinutes());
        \\print(local.getSeconds());
        \\print(local.getMilliseconds());
    , &quick_stream);
    defer quick_result.free(js.runtime);

    try std.testing.expect(quick_result.isUndefined());
    try std.testing.expectEqualStrings("string\nobject\n1704067200000\n1704067200000\n0\n1970-01-01T00:00:00.000Z\n1970\n2024\n0\n2\n3\n4\n5\n6\n", quick_stream.buffered());

    var output_buffer: [1024]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\// Date object smoke tests
        \\console.log(typeof Date());
        \\console.log(typeof new Date());
        \\console.log(Date.UTC(2024, 0, 1));
        \\console.log(new Date(NaN).toJSON());
        \\const now = Date.now();
        \\console.log(typeof now);
        \\console.log(now > 0);
        \\console.log(Date.parse("2024-01-01T00:00:00Z"));
        \\console.log(Date.parse("2024-01-01T12:34:56.789Z"));
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expect(std.mem.startsWith(u8, stream.buffered(), "string\nobject\n1704067200000\n"));
    try std.testing.expect(std.mem.endsWith(u8, stream.buffered(), "number\ntrue\n1704067200000\n1704112496789\n"));
}

test "Engine eval executes RegExp smoke fixture subset" {
    var js = try engine.Engine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\const r = new RegExp("a", "g");
        \\print(typeof r);
        \\print(r.toString());
        \\print(r.test("a"));
        \\print(r.exec("a"));
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("object\n/a/g\ntrue\nnull\n", stream.buffered());
}

test "Engine eval executes typeof smoke subset" {
    var js = try engine.Engine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\print(typeof 1);
        \\print(typeof 'x');
        \\print(typeof null);
        \\print(typeof undefined);
        \\print(typeof true);
        \\print(typeof 3.14);
        \\print(typeof function () {});
        \\print(typeof {});
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("number\nstring\nobject\nundefined\nboolean\nnumber\nfunction\nobject\n", stream.buffered());
}

test "Engine eval executes simple direct eval strings" {
    var js = try engine.Engine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\const x = 1;
        \\console.log(eval("x + 1"));
        \\console.log(eval("2 + 2"));
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("2\n4\n", stream.buffered());
}

test "Engine eval executes control-flow smoke fixtures" {
    var js = try engine.Engine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\let sum = 0;
        \\for (let i = 0; i < 5; i++) sum += i;
        \\print(sum);
        \\let i = 0;
        \\while (i < 3) { i++; }
        \\print(i);
        \\function classify(n) {
        \\  if (n < 0) return 'neg';
        \\  if (n === 0) return 'zero';
        \\  return 'pos';
        \\}
        \\print(classify(-1), classify(0), classify(1));
        \\let out = '';
        \\switch (2) {
        \\  case 1: out = 'one'; break;
        \\  case 2: out = 'two'; break;
        \\  default: out = 'other';
        \\}
        \\print(out);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("10\n3\nneg zero pos\ntwo\n", stream.buffered());
}

test "Engine eval executes microbench-compatible loop fixtures" {
    var js = try engine.Engine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\let empty = 0;
        \\for (let i = 0; i < 10; i++) {
        \\}
        \\print(empty);
        \\let obj = { a: 1, b: 2 };
        \\let propSum = 0;
        \\for (let i = 0; i < 10; i++) propSum += obj.a;
        \\print(propSum);
        \\let tab = [3];
        \\let arraySum = 0;
        \\for (let i = 0; i < 10; i++) arraySum += tab[0];
        \\print(arraySum);
        \\function f(x) { return x + 1; }
        \\let callSum = 0;
        \\for (let i = 0; i < 10; i++) callSum += f(i);
        \\print(callSum);
        \\let minSum = 0;
        \\for (let i = 0; i < 10; i++) minSum += Math.min(i, 5);
        \\print(minSum);
        \\let s = "";
        \\for (let i = 0; i < 10; i++) s += "x";
        \\print(s.length);
        \\let typed = new Int32Array(new ArrayBuffer(16));
        \\print(typed.length);
        \\let map = new Map();
        \\map.set("a", 1);
        \\print(map.delete("a"));
        \\print(map.has("a"));
        \\let weak = new WeakMap();
        \\let key = {};
        \\weak.set(key, 2);
        \\print(weak.delete(key));
        \\print(weak.has(key));
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("0\n10\n30\n55\n35\n10\n4\ntrue\nfalse\ntrue\nfalse\n", stream.buffered());
}

test "Engine eval executes primitive property smoke subset" {
    var js = try engine.Engine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\const arr = [1, 2, 3];
        \\print(arr.length);
        \\print(typeof arr.map);
        \\print(typeof arr.toString);
        \\print("abc".length);
        \\print("abc".charAt(1));
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("3\nfunction\nfunction\n3\nb\n", stream.buffered());
}

test "Engine eval distinguishes loose and strict equality" {
    var js = try engine.Engine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput("print(1 == \"1\"); print(1 === \"1\");", &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("true\nfalse\n", stream.buffered());
}

test "Engine eval executes logical and nullish smoke subset" {
    var js = try engine.Engine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\print(true && false);
        \\print(true || false);
        \\print(null ?? "default");
        \\print(undefined ?? "default");
        \\print(0 ?? "default");
        \\print("" ?? "default");
        \\print(false ?? "default");
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("false\ntrue\ndefault\ndefault\n0\n\nfalse\n", stream.buffered());
}

test "Engine eval executes in and instanceof Object smoke subset" {
    var js = try engine.Engine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\const obj = { x: 1 };
        \\print("x" in obj);
        \\print("missing" in obj);
        \\print("toString" in obj);
        \\print(obj instanceof Object);
        \\print([] instanceof Object);
        \\print("string" instanceof Object);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("true\nfalse\ntrue\ntrue\ntrue\nfalse\n", stream.buffered());
}

test "Engine eval executes String.fromCharCode smoke subset" {
    var js = try engine.Engine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\print(String.fromCharCode(65));
        \\print(String.fromCharCode(72, 101, 108, 108, 111));
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("A\nHello\n", stream.buffered());
}

test "Engine eval executes string method smoke subset" {
    var js = try engine.Engine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [512]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\const str = "Hello World";
        \\print(str.charAt(0));
        \\print(str.charAt(6));
        \\print(str.substring(0, 5));
        \\print(str.toUpperCase());
        \\print(str.toLowerCase());
        \\print(str.indexOf("World"));
        \\print(str.includes("Hello"));
        \\print(str.startsWith("Hello"));
        \\print(str.endsWith("World"));
        \\print(str.trim());
        \\print("  abc  ".trim());
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("H\nW\nHello\nHELLO WORLD\nhello world\n6\ntrue\ntrue\ntrue\nHello World\nabc\n", stream.buffered());
}

test "Engine eval executes narrow new String method subset" {
    var js = try engine.Engine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\const str = new String("Hello World");
        \\print(str.charAt(0));
        \\print(str.charAt(6));
        \\print(str.substring(0, 5));
        \\print(str.toUpperCase());
        \\print(str.toLowerCase());
        \\print(str.indexOf("World"));
        \\print(str.includes("Hello"));
        \\print(str.startsWith("Hello"));
        \\print(str.endsWith("World"));
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("H\nW\nHello\nHELLO WORLD\nhello world\n6\ntrue\ntrue\ntrue\n", stream.buffered());
}

test "Engine eval executes String constructor conversion smoke subset" {
    var js = try engine.Engine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\const s = new String("Hello");
        \\print(s.charAt(0));
        \\print(s.substring(0, 3));
        \\print(s.toUpperCase());
        \\print(typeof String([1, 2]));
        \\print(String([1, 2]));
        \\print(String(null));
        \\print(String(undefined));
        \\print(new String(null).toString());
        \\print(String.fromCharCode(72, 101, 108, 108, 111));
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("H\nHel\nHELLO\nstring\n1,2\nnull\nundefined\nnull\nHello\n", stream.buffered());
}

test "Engine eval executes String wrapper coercion regression subset" {
    var js = try engine.Engine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\const boxed = new String(123);
        \\print(typeof boxed);
        \\print(boxed.toString());
        \\print(boxed.substring(1, 3));
        \\print(new String("abc").includes("b"));
        \\print(new String().toString());
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("object\n123\n23\ntrue\n\n", stream.buffered());
}

test "Engine eval executes BigInt asN coercion regression subset" {
    var js = try engine.Engine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [512]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\print(BigInt.asIntN(4, "15"));
        \\print(BigInt.asUintN(4, true));
        \\print(BigInt.asIntN("4", 7));
        \\print(123456789012345678901234567890n);
        \\print(BigInt.asUintN(80, 1208925819614629174706175n));
        \\print(BigInt.asIntN(80, 1208925819614629174706175n));
        \\print(12345678901234567890123456789012345678901234567890n);
        \\print(BigInt.asUintN(256, 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffn));
        \\print(123456789012345678901234567890n / 97n);
        \\print(123456789012345678901234567890n % 97n);
        \\print(2n ** 20n);
        \\print(1n << 130n);
        \\print(-1n >> 100n);
        \\print(0xffffffffffffffffffffn & 0xffn);
        \\print(~0n);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("-1\n1\n7\n123456789012345678901234567890\n1208925819614629174706175\n-1\n12345678901234567890123456789012345678901234567890\n115792089237316195423570985008687907853269984665640564039457584007913129639935\n1272750402189130710322005854\n52\n1048576\n1361129467683753853853498429727072845824\n-1\n255\n-1\n", stream.buffered());
}

test "Engine eval executes typeof standard globals and new Object smoke subset" {
    var js = try engine.Engine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\print(typeof Math);
        \\print(typeof JSON);
        \\print(typeof Promise);
        \\print(typeof Map);
        \\print(typeof Set);
        \\print(typeof ArrayBuffer);
        \\print(typeof DataView);
        \\print(typeof Symbol);
        \\print(typeof new Object());
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("object\nobject\nfunction\nfunction\nfunction\nfunction\nfunction\nfunction\nobject\n", stream.buffered());
}

test "Engine eval executes primitive constructor smoke subset" {
    var js = try engine.Engine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\console.log(typeof Number("42"));
        \\console.log(Number("42"));
        \\console.log(typeof new Number("42"));
        \\console.log(new Number("42").valueOf());
        \\console.log(typeof Boolean(0));
        \\console.log(Boolean(0));
        \\console.log(typeof new Boolean(1));
        \\console.log(new Boolean(1).valueOf());
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("number\n42\nobject\n42\nboolean\nfalse\nobject\ntrue\n", stream.buffered());
}

test "Engine eval executes optional property access smoke subset" {
    var js = try engine.Engine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\const obj = { a: { b: 42 } };
        \\print(obj?.a?.b);
        \\print(obj?.x?.y);
        \\const nullObj = null;
        \\print(nullObj?.a);
        \\print(undefined?.a);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("42\nundefined\nundefined\nundefined\n", stream.buffered());
}

test "Engine eval executes basic class construction smoke subset" {
    var js = try engine.Engine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [32]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\class MyClass {
        \\    constructor(x) {
        \\    }
        \\}
        \\const obj = new MyClass(42);
        \\console.log(obj !== undefined);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("true\n", stream.buffered());
}

test "Engine eval executes async object smoke subset" {
    var js = try engine.Engine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [32]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\async function testAsync() {
        \\    return 42;
        \\}
        \\async function testAwait() {
        \\    const result = await Promise.resolve(100);
        \\    return result;
        \\}
        \\const p = testAsync();
        \\console.log(typeof p);
        \\const promise = new Promise((resolve, reject) => {
        \\    resolve(123);
        \\});
        \\console.log(typeof promise);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("object\nobject\n", stream.buffered());
}

test "Engine eval executes Promise smoke fixture subset through quick parser" {
    var js = try engine.Engine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\const p = new Promise((resolve, reject) => {
        \\    resolve(1);
        \\});
        \\print(typeof p);
        \\print(Promise.resolve(1));
        \\print(Promise.all([1, 2]));
        \\print(Promise.race([Promise.resolve(3), 4]));
        \\print(Promise.reject(1));
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("object\n[object Promise]\n[object Promise]\n[object Promise]\n[object Promise]\n", stream.buffered());
    try std.testing.expect(js.context.hasException());
    const reason = js.takeException();
    defer reason.free(js.runtime);
    try std.testing.expectEqual(@as(?i32, 1), reason.asInt32());
}

test "Engine eval executes named instanceof smoke subset" {
    var js = try engine.Engine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [64]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\function Foo() {}
        \\const foo = new Foo();
        \\print(foo instanceof Foo);
        \\print({} instanceof Object);
        \\print([] instanceof Array);
        \\print([] instanceof Object);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("true\ntrue\ntrue\ntrue\n", stream.buffered());
}

test "Engine eval executes Number parse smoke subset" {
    var js = try engine.Engine.init(std.testing.allocator);
    defer js.deinit();

    var quick_output_buffer: [256]u8 = undefined;
    var quick_stream = std.Io.Writer.fixed(&quick_output_buffer);
    const quick_result = try js.evalWithOutput(
        \\print(parseInt("0x10"));
        \\print(parseInt("0x10", 10));
        \\print(parseInt("11", "2"));
        \\print(parseInt("11", true));
        \\print(parseFloat("1.5x"));
        \\print(Number.parseInt("42"));
        \\print(Number.parseFloat("3.14"));
        \\print(Number.POSITIVE_INFINITY);
    , &quick_stream);
    defer quick_result.free(js.runtime);

    try std.testing.expect(quick_result.isUndefined());
    try std.testing.expectEqualStrings("16\n0\n3\nNaN\n1.5\n42\n3.14\nInfinity\n", quick_stream.buffered());

    var output_buffer: [512]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\print(Number.parseInt("42"));
        \\print(Number.parseFloat("3.14"));
        \\print(Number.NaN);
        \\print(Number.POSITIVE_INFINITY);
        \\print(Number.NEGATIVE_INFINITY);
        \\print(typeof globalThis);
        \\print(globalThis.globalThis === globalThis);
        \\print(globalThis.Math === Math);
        \\print(parseInt("0x10"));
        \\print(parseInt("0x10", 16));
        \\print(parseInt("0x10", 10));
        \\print(parseInt("-0xF"));
        \\print(parseInt("+0xF"));
        \\print(parseInt("10", 1));
        \\print(parseInt("10", 37));
        \\print(parseInt("12px"));
        \\print(1 / parseInt("-0"));
        \\print(parseFloat("1.5x"));
        \\print(parseFloat("+.5x"));
        \\print(parseFloat("Infinityx"));
        \\print(parseFloat("-Infinityx"));
        \\print(parseFloat("x1"));
        \\print(1 / parseFloat("-0"));
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("42\n3.14\nNaN\nInfinity\n-Infinity\nobject\ntrue\ntrue\n16\n16\n0\n-15\n15\nNaN\nNaN\n12\n-Infinity\n1.5\n0.5\nInfinity\n-Infinity\nNaN\n-Infinity\n", stream.buffered());
}

test "Engine eval executes object helper smoke subset" {
    var js = try engine.Engine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\const o = { a: 1, b: 2 };
        \\print(o.a, o.b);
        \\o.c = 3;
        \\print(o.c);
        \\print(Object.keys(o).join(","));
        \\print(Object.values(o).join(","));
        \\print(JSON.stringify(Object.entries(o)));
        \\var keyOrder = "";
        \\for (var k in o) keyOrder += k;
        \\print(keyOrder);
        \\const arr = [10, 20, 30];
        \\print(arr[0], arr[1], arr[2]);
        \\print(arr.length);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("1 2\n3\na,b,c\n1,2,3\n[[\"a\",1],[\"b\",2],[\"c\",3]]\nabc\n10 20 30\n3\n", stream.buffered());
}

test "Object.defineProperty returns retained target object" {
    var js = try engine.Engine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [128]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\const proto = Map.prototype;
        \\const returned = Object.defineProperty(proto, "sentinel", { value: 7, writable: true, configurable: true });
        \\print(returned === proto);
        \\print(Map.prototype.sentinel);
        \\const map = new Map();
        \\map.set("key", "value");
        \\print(map.get("key"));
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("true\n7\nvalue\n", stream.buffered());
}

test "Engine eval executes Map groupBy and iterable construction" {
    var js = try engine.Engine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\new Map();
        \\const grouped = Map.groupBy([1, 2, 3], function (i) {
        \\  return i % 2 === 0 ? "even" : "odd";
        \\});
        \\print(grouped.size);
        \\print(Array.from(grouped.keys()).join(","));
        \\print(grouped.get("odd").join(","));
        \\const constructed = new Map([["a", 1], ["b", 2]]);
        \\print(constructed.size);
        \\print(constructed.get("b"));
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("2\nodd,even\n1,3\n2\n2\n", stream.buffered());
}

test "Engine eval executes typed array smoke subset" {
    var js = try engine.Engine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [512]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\const ab = new ArrayBuffer(16);
        \\console.log(ab.byteLength);
        \\console.log(ab.slice(0, 8));
        \\const int8 = new Int8Array(ab);
        \\console.log(int8.length);
        \\console.log(int8.byteLength);
        \\console.log(int8.byteOffset);
        \\const uint8 = new Uint8Array(ab);
        \\console.log(uint8.length);
        \\const int16 = new Int16Array(ab);
        \\console.log(int16.length);
        \\const uint16 = new Uint16Array(ab);
        \\console.log(uint16.length);
        \\const int32 = new Int32Array(ab);
        \\console.log(int32.length);
        \\const uint32 = new Uint32Array(ab);
        \\console.log(uint32.length);
        \\const float32 = new Float32Array(ab);
        \\console.log(float32.length);
        \\const float64 = new Float64Array(ab);
        \\console.log(float64.length);
        \\const dv = new DataView(ab);
        \\console.log(dv.buffer);
        \\console.log(dv.byteLength);
        \\console.log(dv.byteOffset);
        \\console.log(dv.getInt8(0));
        \\console.log(dv.getUint8(0));
        \\console.log(dv.getInt16(0));
        \\console.log(dv.getUint16(0));
        \\console.log(dv.getInt32(0));
        \\console.log(dv.getUint32(0));
        \\console.log(dv.getFloat32(0));
        \\console.log(dv.getFloat64(0));
        \\dv.setInt8(0, 1);
        \\dv.setUint8(0, 1);
        \\dv.setInt16(0, 1);
        \\dv.setUint16(0, 1);
        \\dv.setInt32(0, 1);
        \\dv.setUint32(0, 1);
        \\dv.setUint32(0, 4294967295);
        \\console.log(dv.getUint32(0));
        \\dv.setUint32(0, -1);
        \\console.log(dv.getUint32(0));
        \\dv.setFloat32(0, 1.0);
        \\dv.setFloat64(0, 1.0);
        \\const dv2 = new DataView(ab, 1, 2);
        \\console.log(dv2.byteOffset);
        \\console.log(dv2.byteLength);
        \\dv2.setInt16(0, 4660, true);
        \\console.log(dv2.getUint8(0));
        \\console.log(dv2.getUint8(1));
        \\console.log(dv2.getInt16(0, true));
        \\const dv4 = new DataView(ab);
        \\console.log(dv4.getUint8(1));
        \\console.log(dv4.getUint8(2));
        \\const sliced = ab.slice(1, 3);
        \\const sdv = new DataView(sliced);
        \\console.log(sliced.byteLength);
        \\console.log(sdv.getUint8(0));
        \\console.log(sdv.getUint8(1));
        \\const big = new DataView(new ArrayBuffer(8));
        \\big.setBigInt64(0, -1n);
        \\console.log(big.getBigInt64(0));
        \\big.setBigUint64(0, 18446744073709551615n);
        \\console.log(big.getBigUint64(0));
        \\const dv3 = new DataView(ab, undefined, undefined);
        \\console.log(dv3.byteOffset);
        \\console.log(dv3.byteLength);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("16\n[object ArrayBuffer]\n16\n16\n0\n16\n8\n8\n4\n4\n4\n2\n[object ArrayBuffer]\n16\n0\n0\n0\n0\n0\n0\n0\n0\n0\n4294967295\n4294967295\n1\n2\n52\n18\n4660\n52\n18\n2\n52\n18\n-1\n18446744073709551615\n0\n16\n", stream.buffered());
}

test "Engine eval executes Map Set smoke subset" {
    var js = try engine.Engine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [1024]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\const map = new Map();
        \\map.set("key", "value");
        \\console.log(map.get("key"));
        \\console.log(map.has("key"));
        \\console.log(map.size);
        \\map.delete("key");
        \\map.clear();
        \\const set = new Set();
        \\set.add(1);
        \\console.log(set.has(1));
        \\console.log(set.size);
        \\set.delete(1);
        \\set.clear();
        \\const weakMap = new WeakMap();
        \\console.log(typeof weakMap);
        \\console.log(weakMap.set);
        \\console.log(weakMap.get);
        \\console.log(weakMap.has);
        \\console.log(weakMap.delete);
        \\const weakSet = new WeakSet();
        \\console.log(typeof weakSet);
        \\console.log(weakSet.add);
        \\console.log(weakSet.has);
        \\console.log(weakSet.delete);
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("value\ntrue\n1\ntrue\n1\nobject\nfunction set() {\n    [native code]\n}\nfunction get() {\n    [native code]\n}\nfunction has() {\n    [native code]\n}\nfunction delete() {\n    [native code]\n}\nobject\nfunction add() {\n    [native code]\n}\nfunction has() {\n    [native code]\n}\nfunction delete() {\n    [native code]\n}\n", stream.buffered());
}

test "Engine eval executes collection smoke fixture subset through quick parser" {
    var js = try engine.Engine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [1024]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\const map = new Map();
        \\map.set("key", "value");
        \\print(map.get("key"));
        \\print(map.has("key"));
        \\print(map.size);
        \\print(map.delete("key"));
        \\const set = new Set();
        \\set.add(1);
        \\print(set.has(1));
        \\print(set.size);
        \\print(set.delete(1));
        \\const weakMap = new WeakMap();
        \\const weakKey = {};
        \\weakMap.set(weakKey, "weak");
        \\print(weakMap.get(weakKey));
        \\print(weakMap.has(weakKey));
        \\print(weakMap.delete(weakKey));
        \\const weakSet = new WeakSet();
        \\const weakSetKey = {};
        \\weakSet.add(weakSetKey);
        \\print(weakSet.has(weakSetKey));
        \\print(weakSet.delete(weakSetKey));
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("value\ntrue\n1\ntrue\ntrue\n1\ntrue\nweak\ntrue\ntrue\ntrue\ntrue\n", stream.buffered());
}

test "Engine eval executes URI smoke subset" {
    var js = try engine.Engine.init(std.testing.allocator);
    defer js.deinit();

    var quick_output_buffer: [256]u8 = undefined;
    var quick_stream = std.Io.Writer.fixed(&quick_output_buffer);
    const quick_result = try js.evalWithOutput(
        \\console.log(encodeURI("a b?x=1&y=2#z"));
        \\console.log(encodeURIComponent("a b?x=1&y=2#z"));
        \\console.log(decodeURI("a%20b?x=1&y=2#z"));
        \\console.log(decodeURI("%3F"));
        \\console.log(decodeURIComponent("a%20b%3Fx%3D1%26y%3D2%23z"));
    , &quick_stream);
    defer quick_result.free(js.runtime);

    try std.testing.expect(quick_result.isUndefined());
    try std.testing.expectEqualStrings("a%20b?x=1&y=2#z\na%20b%3Fx%3D1%26y%3D2%23z\na b?x=1&y=2#z\n%3F\na b?x=1&y=2#z\n", quick_stream.buffered());

    var output_buffer: [512]u8 = undefined;
    var stream = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(
        \\console.log(encodeURI("a b?x=1&y=2#z"));
        \\console.log(encodeURIComponent("a b?x=1&y=2#z"));
        \\console.log(decodeURI("a%20b?x=1&y=2#z"));
        \\console.log(decodeURI("%3F"));
        \\console.log(decodeURIComponent("a%20b%3Fx%3D1%26y%3D2%23z"));
        \\try {
        \\  decodeURIComponent("%E0%A4%A");
        \\} catch (e) {
        \\  console.log(e.name + ": " + e.message);
        \\}
        \\try {
        \\  decodeURI("%GG");
        \\} catch (e) {
        \\  console.log(e.name + ": " + e.message);
        \\}
    , &stream);
    defer result.free(js.runtime);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("a%20b?x=1&y=2#z\na%20b%3Fx%3D1%26y%3D2%23z\na b?x=1&y=2#z\n%3F\na b?x=1&y=2#z\nURIError: expecting hex digit\nURIError: expecting hex digit\n", stream.buffered());
}

test "unsupported opcode sets context exception" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    var function = try makeFunction(rt, &.{ 250, 255 });
    defer function.deinit(rt);
    try std.testing.expectError(error.StackUnderflow, runFunction(rt, ctx, &function));

    var unsupported = try makeFunction(rt, &.{100});
    defer unsupported.deinit(rt);
    try std.testing.expectError(error.UnsupportedOpcode, runFunction(rt, ctx, &unsupported));
    try std.testing.expect(ctx.hasException());
    const ex = ctx.takeException();
    defer ex.free(rt);
    try std.testing.expectEqual(@as(?i32, 100), ex.asInt32());
}

test "VM domain helper failures surface as TypeError not UnsupportedOpcode" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const name = try rt.internAtom("domain-errors");
    defer rt.atoms.free(name);
    const prop = try rt.internAtom("x");
    defer rt.atoms.free(prop);

    var get_prop_function = engine.bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer get_prop_function.deinit(rt);
    var get_prop_emit = engine.bytecode.emitter.Emitter.init(&get_prop_function);
    try get_prop_emit.emitPushInt32(1);
    try get_prop_emit.emitGetProp(prop);
    try std.testing.expectError(error.TypeError, runFunction(rt, ctx, &get_prop_function));
    try std.testing.expect(!ctx.hasException());

    var array_method_function = engine.bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer array_method_function.deinit(rt);
    var array_method_emit = engine.bytecode.emitter.Emitter.init(&array_method_function);
    try array_method_emit.emitNewArray(0);
    try array_method_emit.emitArrayMethod(99);
    try std.testing.expectError(error.TypeError, runFunction(rt, ctx, &array_method_function));
    try std.testing.expect(!ctx.hasException());
}

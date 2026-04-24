const std = @import("std");
const engine = @import("quickjs_zig_engine");

const core = engine.core;

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
    try std.testing.expect(engine.exec.property_ops.deleteProperty(rt, obj, key));
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

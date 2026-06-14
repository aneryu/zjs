const std = @import("std");
const build_options = @import("build_options");
const zjs = @import("../root.zig");

const HostState = struct {
    value: i32,

    fn call(ptr: *anyopaque, call_info: zjs.host.Call) anyerror!zjs.JSValue {
        _ = call_info;
        const self: *@This() = @ptrCast(@alignCast(ptr));
        return zjs.JSValue.int32(self.value);
    }
};

const BytesState = struct {
    allocator: std.mem.Allocator,
    calls: usize = 0,

    fn deinit(context: ?*anyopaque, bytes: []u8) void {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        self.calls += 1;
        self.allocator.free(bytes);
    }
};

const InterruptBudget = struct {
    budget: usize,

    fn stop(_: *zjs.JSRuntime, ctx: ?*anyopaque) bool {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        if (self.budget == 0) return true;
        self.budget -= 1;
        return false;
    }
};

fn testFixturePath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return allocator.dupe(u8, path);
    const io = std.Io.Threaded.global_single_threaded.io();
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return std.fs.path.resolve(allocator, &.{ "../..", path }),
        else => return err,
    };
    file.close(io);
    return allocator.dupe(u8, path);
}

test "embedding cookbook basic script eval example compiles and runs" {
    const allocator = std.testing.allocator;
    const rt = try zjs.JSRuntime.create(allocator);
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt);
    defer ctx.destroy();

    const result = try ctx.eval("let x = 1 + 2; x;", .{});
    defer result.free(rt);

    try std.testing.expectEqual(@as(?i32, 3), result.asInt32());
}

test "embedding cookbook eval with output example compiles and runs" {
    const allocator = std.testing.allocator;
    const rt = try zjs.JSRuntime.create(allocator);
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt);
    defer ctx.destroy();

    var buffer: [128]u8 = undefined;
    var output = std.Io.Writer.fixed(&buffer);

    const result = try ctx.eval("print('ok');", .{
        .output = &output,
    });
    defer result.free(rt);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("ok\n", output.buffered());
}

test "embedding cookbook host-held values example compiles and roots correctly" {
    const allocator = std.testing.allocator;
    const rt = try zjs.JSRuntime.create(allocator);
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt);
    defer ctx.destroy();

    const object = try ctx.eval("({ answer: 42 })", .{});

    var scope: zjs.JSValue.Scope = rt.enterHandleScope();
    defer scope.deinit();

    const local: zjs.JSValue.Local = try scope.localDup(object);
    object.free(rt);

    var persistent: zjs.JSValue.Persistent = try rt.createPersistentValue(local.get());
    defer persistent.deinit();

    scope.exit();

    const answer = try ctx.getProperty(persistent.get(), "answer");
    defer answer.free(rt);
    try std.testing.expectEqual(@as(?i32, 42), answer.asInt32());
}

test "embedding cookbook host function example compiles and runs" {
    const allocator = std.testing.allocator;
    const rt = try zjs.JSRuntime.create(allocator);
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt);
    defer ctx.destroy();

    var state = HostState{ .value = 42 };
    try ctx.defineGlobalFunction("hostValue", 0, &state, HostState.call, null);

    const result = try ctx.eval("hostValue()", .{});
    defer result.free(rt);
    try std.testing.expectEqual(@as(?i32, 42), result.asInt32());
}

// Contract pin for the high-performance host hookup path: native functions
// register through `zjs.host.Function`/`zjs.host.Call` (ExternalHostCallFn /
// ExternalHostCall) into the per-runtime external-record registry and dispatch
// by id, with no string lookup on the call path. This is the only supported
// route for host/runtime capability hookup; the legacy qjs:std/qjs:os host
// cluster was deleted (git history has it).
const ContractHost = struct {
    factor: i32,
    calls: usize = 0,
    saw_object_this: bool = false,
    finalized: *bool,

    fn call(ptr: *anyopaque, call_info: zjs.host.Call) anyerror!zjs.JSValue {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.calls += 1;
        if (call_info.this_value.isObject()) self.saw_object_this = true;
        if (call_info.args.len < 2) return error.TypeError;
        const a = call_info.args[0].asInt32() orelse return error.TypeError;
        const b = call_info.args[1].asInt32() orelse return error.TypeError;
        if (a < 0) return error.RangeError;
        return zjs.JSValue.int32(self.factor * (a + b));
    }

    fn finalize(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.finalized.* = true;
    }
};

test "embedding external host function contract covers args, this, errors, and finalizer" {
    const allocator = std.testing.allocator;
    var finalized = false;
    var state = ContractHost{ .factor = 2, .finalized = &finalized };

    const rt = try zjs.JSRuntime.create(allocator);
    var rt_alive = true;
    defer if (rt_alive) rt.destroy();
    const ctx = try zjs.JSContext.create(rt);
    var ctx_alive = true;
    defer if (ctx_alive) ctx.destroy();

    try ctx.defineGlobalFunction("hostCombine", 2, &state, ContractHost.call, ContractHost.finalize);

    // Scoped so every eval result is released before the teardown choreography
    // below asserts on runtime/context destruction order.
    {
        // Identity installed from registration metadata, not from the call path.
        const shape = try ctx.eval(
            "typeof hostCombine === 'function' && hostCombine.name === 'hostCombine' && hostCombine.length === 2",
            .{},
        );
        defer shape.free(rt);
        try std.testing.expectEqual(true, shape.asBool().?);

        // Arguments flow host-ward; the return value flows back into JS expressions.
        const sum = try ctx.eval("hostCombine(19, 23) + 16", .{});
        defer sum.free(rt);
        try std.testing.expectEqual(@as(?i32, 100), sum.asInt32());

        // Method-style invocation hands the receiver to the host as `this_value`.
        const method_sum = try ctx.eval("({ combine: hostCombine }).combine(1, 2)", .{});
        defer method_sum.free(rt);
        try std.testing.expectEqual(@as(?i32, 6), method_sum.asInt32());
        try std.testing.expect(state.saw_object_this);

        // Host Zig errors surface as catchable JS exceptions with mapped names.
        const caught = try ctx.eval(
            \\var caught = "none";
            \\try { hostCombine(-1, 0); } catch (e) {
            \\  caught = (e instanceof RangeError) ? e.name : "wrong-class";
            \\}
            \\caught;
        , .{});
        defer caught.free(rt);
        const caught_text = try ctx.toOwnedUtf8(caught, allocator);
        defer allocator.free(caught_text);
        try std.testing.expectEqualStrings("RangeError", caught_text);

        try std.testing.expectEqual(@as(usize, 3), state.calls);
    }

    // The record (and its finalizer) is owned by the runtime, not the context.
    ctx.destroy();
    ctx_alive = false;
    try std.testing.expect(!finalized);

    rt.destroy();
    rt_alive = false;
    try std.testing.expect(finalized);
}

test "embedding cookbook strings and bytes examples compile and run" {
    const allocator = std.testing.allocator;
    const rt = try zjs.JSRuntime.create(allocator);
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt);
    defer ctx.destroy();

    const value = try ctx.eval("({ toString() { return 'path'; } })", .{});
    defer value.free(rt);

    const text = try ctx.toOwnedUtf8(value, allocator);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("path", text);

    var bytes_state = BytesState{ .allocator = allocator };
    const backing = try allocator.alloc(u8, 4);
    @memcpy(backing, &[_]u8{ 1, 2, 3, 4 });

    var store = zjs.value.Bytes.Store.owned(backing, .{
        .context = &bytes_state,
        .deinit = BytesState.deinit,
    });
    errdefer store.release();

    const array_buffer = try ctx.arrayBuffer(&store);
    var array_buffer_live = true;
    defer if (array_buffer_live) array_buffer.free(rt);

    const bytes = try array_buffer.asBytes(ctx);
    const writable = try bytes.sliceMut();
    writable[0] = 9;
    try std.testing.expectEqualSlices(u8, &.{ 9, 2, 3, 4 }, bytes.slice());
    try std.testing.expectEqual(@as(usize, 0), bytes_state.calls);

    array_buffer.free(rt);
    array_buffer_live = false;
    try std.testing.expectEqual(@as(usize, 1), bytes_state.calls);
}

test "embedding cookbook construction with limits example compiles and runs" {
    const allocator = std.testing.allocator;
    const rt = try zjs.JSRuntime.createWithOptions(allocator, .{
        .stack_size = 512 * 1024,
        .gc_threshold = 2 * 1024 * 1024,
    });
    defer rt.destroy();

    rt.setMemoryLimit(64 * 1024 * 1024);
    try std.testing.expectEqual(@as(usize, 512 * 1024), rt.stackSize());
    try std.testing.expectEqual(@as(usize, 2 * 1024 * 1024), rt.gcThreshold());
    try std.testing.expectEqual(@as(?usize, 64 * 1024 * 1024), rt.memoryUsage().memory_limit);
}

test "embedding cookbook interrupts example compiles and aborts runaway code" {
    const allocator = std.testing.allocator;
    const rt = try zjs.JSRuntime.create(allocator);
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt);
    defer ctx.destroy();

    var state = InterruptBudget{ .budget = 0 };
    rt.setInterruptHandler(InterruptBudget.stop, &state);
    defer rt.setInterruptHandler(null, null);

    try std.testing.expectError(error.Interrupted, ctx.eval("while (true) {}", .{}));
}

test "embedding cookbook module eval example compiles and runs" {
    const allocator = std.testing.allocator;
    const rt = try zjs.JSRuntime.create(allocator);
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt);
    defer ctx.destroy();

    const result = try ctx.eval(
        \\const value = await Promise.resolve(42);
        \\export { value };
    , .{ .mode = .module });
    defer result.free(rt);
}

test "embedding public NativeBinding failed realm install leaves binding absent" {
    const Binding = zjs.host.NativeBinding;
    const Payload = struct {
        value: i32,

        fn read(self: *@This()) i32 {
            return self.value;
        }
    };
    const ObjectType = Binding.JSObject(Payload, .{
        .name = "EmbeddingInstallFailurePayload",
        .storage = Binding.Storage.inlineValue,
        .properties = Binding.Properties.static(.{
            Binding.method("read", Payload.read),
        }),
    });

    const allocator = std.testing.allocator;
    const rt = try zjs.JSRuntime.create(allocator);
    defer rt.destroy();

    const ctx_a = try zjs.JSContext.create(rt);
    defer ctx_a.destroy();
    const ctx_b = try zjs.JSContext.create(rt);
    defer ctx_b.destroy();

    try ObjectType.install(&ctx_a.core);
    const binding_a = try ObjectType.binding(&ctx_a.core);

    rt.setMemoryLimit(rt.memory.allocated_bytes);
    if (ObjectType.install(&ctx_b.core)) {
        rt.setMemoryLimit(null);
        return error.TestExpectedError;
    } else |err| {
        rt.setMemoryLimit(null);
        try std.testing.expectEqual(error.OutOfMemory, err);
    }

    try std.testing.expectError(error.NotInstalled, ObjectType.binding(&ctx_b.core));

    const value_a = try binding_a.new(.{ .value = 7 });
    defer value_a.free(rt);
    try std.testing.expectEqual(@as(i32, 7), binding_a.payload(value_a).?.value);

    try ObjectType.install(&ctx_b.core);
    const binding_b = try ObjectType.binding(&ctx_b.core);
    const value_b = try binding_b.new(.{ .value = 11 });
    defer value_b.free(rt);
    try std.testing.expectEqual(@as(i32, 11), binding_b.payload(value_b).?.value);
    try std.testing.expect(binding_a.payload(value_b) == null);
}

test "embedding public runtime Plugin failed install preserves target properties" {
    const allocator = std.testing.allocator;
    const fixture_path = try testFixturePath(allocator, build_options.runtime_plugin_fixture_path);
    defer allocator.free(fixture_path);

    var plugin = try zjs.runtime.Plugin.load(allocator, fixture_path);
    defer plugin.deinit();

    const rt = try zjs.JSRuntime.create(allocator);
    defer rt.destroy();
    const ctx = try zjs.JSContext.create(rt);
    defer ctx.destroy();

    const target = try ctx.createObject();
    defer target.free(rt);
    try ctx.defineDataProperty(target, "add", zjs.JSValue.int32(1), .{});

    try std.testing.expectError(error.PropertyAlreadyExists, plugin.install(&ctx.core, target, .{}));
    try std.testing.expect(plugin.consumed);
    try std.testing.expect(plugin.loaded != null);
    try std.testing.expectError(error.PluginAlreadyConsumed, plugin.install(&ctx.core, target, .{ .overwrite = true }));

    const add = try ctx.getProperty(target, "add");
    defer add.free(rt);
    try std.testing.expectEqual(@as(?i32, 1), add.asInt32());
}

test "embedding public API core signatures stay source-compatible" {
    const create_runtime: fn (std.mem.Allocator) anyerror!*zjs.JSRuntime = zjs.JSRuntime.create;
    const create_runtime_with_options: fn (std.mem.Allocator, zjs.RuntimeOptions) anyerror!*zjs.JSRuntime = zjs.JSRuntime.createWithOptions;
    const create_context: fn (*zjs.JSRuntime) anyerror!*zjs.JSContext = zjs.JSContext.create;
    const create_context_with_options: fn (*zjs.JSRuntime, zjs.context.Options) anyerror!*zjs.JSContext = zjs.JSContext.createWithOptions;
    const define_global_function: fn (*zjs.JSContext, []const u8, i32, *anyopaque, zjs.host.Function, ?zjs.host.Finalizer) anyerror!void = zjs.JSContext.defineGlobalFunction;
    const create_external_function: fn (*zjs.JSContext, []const u8, i32, *anyopaque, zjs.host.Function, ?zjs.host.Finalizer, zjs.host.FunctionOptions) anyerror!zjs.JSValue = zjs.JSContext.createExternalFunction;
    const eval_script: fn (*zjs.JSContext, []const u8, zjs.context.EvalOptions) anyerror!zjs.JSValue = zjs.JSContext.eval;
    const array_buffer: fn (*zjs.JSContext, *zjs.value.Bytes.Store) anyerror!zjs.JSValue = zjs.JSContext.arrayBuffer;
    const to_owned_utf8: fn (*zjs.JSContext, zjs.JSValue, std.mem.Allocator) anyerror![]u8 = zjs.JSContext.toOwnedUtf8;

    _ = create_runtime;
    _ = create_runtime_with_options;
    _ = create_context;
    _ = create_context_with_options;
    _ = define_global_function;
    _ = create_external_function;
    _ = eval_script;
    _ = array_buffer;
    _ = to_owned_utf8;

    try std.testing.expect(zjs.host.Call == @typeInfo(@typeInfo(zjs.host.Function).pointer.child).@"fn".params[1].type.?);
    try std.testing.expect(zjs.value.Bytes.Store == zjs.JSValue.Bytes.Store);
    try std.testing.expect(@typeInfo(zjs.object.Object) == .@"opaque");
    try std.testing.expect(!@hasDecl(zjs, "JSBytes"));
    try std.testing.expect(!@hasDecl(zjs, "JSString"));
    try std.testing.expect(!@hasDecl(zjs, "PropNameID"));
    try std.testing.expect(!@hasDecl(zjs, "binding"));
}

//! Validates public embedding examples against the shipped API.
const std = @import("std");
const build_options = @import("build_options");
const zjs = @import("zjs");
const HostState = struct {
    value: i32,

    fn call(c: *zjs.native.Call) zjs.JSValue {
        return zjs.JSValue.int32(c.state(HostState).value);
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

    var persistent: zjs.JSValue.Persistent = try rt.createPersistentValue(local.get());
    defer persistent.deinit();

    scope.deinit();

    const answer = try ctx.getProperty(persistent.get(), "answer");
    try std.testing.expectEqual(@as(?i32, 42), answer.asInt32());
}

test "embedding cookbook host function example compiles and runs" {
    const allocator = std.testing.allocator;
    const rt = try zjs.JSRuntime.create(allocator);
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt);
    defer ctx.destroy();

    var state = HostState{ .value = 42 };
    _ = try ctx.defineFunction("hostValue", zjs.native.managed(HostState.call), .{ .state = @ptrCast(&state) });

    const result = try ctx.eval("hostValue()", .{});
    try std.testing.expectEqual(@as(?i32, 42), result.asInt32());
}

// Cookbook: typed leaf functions. The VM marshals the primitives (exact
// int32 / f64 tag checks, no ToObject, no coercion of objects) and the target
// never sees a JSValue, never allocates and cannot throw; a tag miss throws a
// TypeError at the call site before the target runs.
const LeafExample = struct {
    fn add(a: i32, b: i32) i32 {
        return a +% b;
    }

    fn half(x: f64) f64 {
        return x / 2;
    }
};

const TickState = struct {
    ticks: i64 = 0,
    step: i32 = 1,

    fn tick(self: *TickState, i: i32) i32 {
        self.ticks += 1;
        return i +% self.step;
    }
};

test "embedding cookbook typed leaf example compiles and runs" {
    const allocator = std.testing.allocator;
    const rt = try zjs.JSRuntime.create(allocator);
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt);
    defer ctx.destroy();

    _ = try ctx.defineFunction("add", zjs.native.leaf(LeafExample.add), .{});
    _ = try ctx.defineFunction("half", zjs.native.leaf(LeafExample.half), .{});
    var counter = TickState{ .step = 10 };
    _ = try ctx.defineFunction("tick", zjs.native.leafWithState(TickState.tick), .{ .state = @ptrCast(&counter) });

    const sum = try ctx.eval("add(40, 2)", .{});
    try std.testing.expectEqual(@as(?i32, 42), sum.asInt32());
    const arity = try ctx.eval("add.length", .{});
    try std.testing.expectEqual(@as(?i32, 2), arity.asInt32());
    const halved = try ctx.eval("half(5)", .{});
    try std.testing.expectEqual(@as(?f64, 2.5), halved.asNumber());
    const ticked = try ctx.eval("tick(1) + tick(2)", .{});
    try std.testing.expectEqual(@as(?i32, 23), ticked.asInt32());
    try std.testing.expectEqual(@as(i64, 2), counter.ticks);

    // A non-int32 argument to an int32 leaf is a TypeError at the call site.
    const miss = try ctx.eval(
        \\var name = "none";
        \\try { add("1", 2); } catch (e) { name = e.name; }
        \\name;
    , .{});
    const miss_text = try ctx.toOwnedUtf8(miss, allocator);
    defer allocator.free(miss_text);
    try std.testing.expectEqualStrings("TypeError", miss_text);
}

// Contract pin for the high-performance host hookup path (NB2, design §9):
// a native function is a `zjs.native.managed` thunk bound to one immutable
// `NativeEntry`; the VM dispatches it exactly like a builtin, with no
// registry, no string lookup and no per-call environment on the call path.
// This is the only supported route for host/runtime capability hookup.
const ContractHost = struct {
    factor: i32,
    calls: usize = 0,
    saw_object_this: bool = false,
    finalized: *bool,

    fn call(c: *zjs.native.Call) anyerror!zjs.JSValue {
        const self = c.state(ContractHost);
        self.calls += 1;
        if (c.this.isObject()) self.saw_object_this = true;
        if (c.argc < 2) return error.TypeError;
        const a = c.arg(0).asInt32() orelse return error.TypeError;
        const b = c.arg(1).asInt32() orelse return error.TypeError;
        if (a < 0) return error.RangeError;
        return zjs.JSValue.int32(self.factor * (a + b));
    }

    fn finalize(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.finalized.* = true;
    }
};

// Cookbook: a host that calls one JS function many times keeps a CallSite.
// The target is resolved (and pinned) once; each call pays only the interrupt
// poll, the frame push and the dispatch loop. Nested use from inside a host
// function that JS called, a receiver override, a thrown exception and a
// non-bytecode callee (bound function) all go through the same object.
const CallSiteHost = struct {
    site: *zjs.CallSite,
    sum: i32 = 0,

    fn call(c: *zjs.native.Call) anyerror!zjs.JSValue {
        const self = c.state(CallSiteHost);
        const result = try self.site.call1(c.arg(0));
        self.sum += result.asInt32() orelse return error.TypeError;
        return result;
    }
};

test "embedding cookbook CallSite example resolves once and calls repeatedly" {
    const allocator = std.testing.allocator;
    const rt = try zjs.JSRuntime.create(allocator);
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt);
    defer ctx.destroy();

    const add_one = try ctx.eval("(function (x) { return x + 1; })", .{});
    var site = try zjs.CallSite.init(ctx, add_one, .{});
    defer site.deinit();

    var total: i32 = 0;
    var i: i32 = 0;
    while (i < 1000) : (i += 1) {
        const result = try site.call1(zjs.JSValue.int32(i));
        total += result.asInt32() orelse return error.TestUnexpectedResult;
    }
    try std.testing.expectEqual(@as(i32, 500500), total);
    const zero = try site.call0();
    try std.testing.expect(std.math.isNan(zero.asNumber() orelse return error.TestUnexpectedResult));

    // Nested: JS -> host function -> the same site -> JS.
    var host = CallSiteHost{ .site = &site };
    _ = try ctx.defineFunction("viaSite", zjs.native.managed(CallSiteHost.call), .{ .length = 1, .state = @ptrCast(&host) });
    const nested = try ctx.eval("var s = 0; for (var k = 0; k < 10; k++) s += viaSite(k); s", .{});
    try std.testing.expectEqual(@as(?i32, 55), nested.asInt32());
    try std.testing.expectEqual(@as(i32, 55), host.sum);

    // Receiver override and a JS exception surfacing as error.JSException.
    const get_v = try ctx.eval("(function () { return this.v; })", .{});
    var method_site = try zjs.CallSite.init(ctx, get_v, .{});
    defer method_site.deinit();
    const holder = try ctx.eval("({ v: 7 })", .{});
    const seven = try method_site.callWithThis(holder, &.{});
    try std.testing.expectEqual(@as(?i32, 7), seven.asInt32());
    const thrower = try ctx.eval("(function () { throw new RangeError('boom'); })", .{});
    var throw_site = try zjs.CallSite.init(ctx, thrower, .{});
    defer throw_site.deinit();
    try std.testing.expectError(error.JSException, throw_site.call0());
    try std.testing.expect(try ctx.pendingExceptionMatchesErrorName("RangeError"));
    _ = ctx.takePendingException();

    // A non-bytecode callee takes the root path through the same API.
    const bound = try ctx.eval("(function (a, b) { return a * b; }).bind(null, 6)", .{});
    var bound_site = try zjs.CallSite.init(ctx, bound, .{});
    defer bound_site.deinit();
    const product = try bound_site.call1(zjs.JSValue.int32(7));
    try std.testing.expectEqual(@as(?i32, 42), product.asInt32());
}

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

    _ = try ctx.defineFunction("hostCombine", zjs.native.managed(ContractHost.call), .{ .length = 2, .state = @ptrCast(&state), .finalize = ContractHost.finalize });

    // Scoped so every eval result is released before the teardown choreography
    // below asserts on runtime/context destruction order.
    {
        // Identity installed from registration metadata, not from the call path.
        const shape = try ctx.eval(
            "typeof hostCombine === 'function' && hostCombine.name === 'hostCombine' && hostCombine.length === 2",
            .{},
        );
        try std.testing.expectEqual(true, shape.asBool().?);

        // Arguments flow host-ward; the return value flows back into JS expressions.
        const sum = try ctx.eval("hostCombine(19, 23) + 16", .{});
        try std.testing.expectEqual(@as(?i32, 100), sum.asInt32());

        // Method-style invocation hands the receiver to the host as `this_value`.
        const method_sum = try ctx.eval("({ combine: hostCombine }).combine(1, 2)", .{});
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

    const bytes = try array_buffer.asBytes(ctx);
    const writable = try bytes.sliceMut();
    writable[0] = 9;
    try std.testing.expectEqualSlices(u8, &.{ 9, 2, 3, 4 }, bytes.slice());
    try std.testing.expectEqual(@as(usize, 0), bytes_state.calls);

    // This is a public-embedding compile target: exercise the public explicit
    // collection seam instead of importing test helpers whose `zjs.core`
    // dependency is intentionally absent from `src/root.zig`.
    _ = rt.runObjectCycleRemoval();
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

    _ = try ctx.eval(
        \\const value = await Promise.resolve(42);
        \\export { value };
    , .{ .mode = .module });
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
        .storage = .inline_value,
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

    try ObjectType.install(ctx_a.core);
    const binding_a = try ObjectType.binding(ctx_a.core);

    // TGC S4-b: sweep first so the limit is the live size (the limit-triggered
    // retry collection can now reclaim property/array storage cells).
    _ = rt.tryRunObjectCycleRemovalWithValueRoots(null, .engine_active) catch {};
    rt.setMemoryLimit(rt.memory.allocated_bytes);
    if (ObjectType.install(ctx_b.core)) {
        rt.setMemoryLimit(null);
        return error.TestExpectedError;
    } else |err| {
        rt.setMemoryLimit(null);
        try std.testing.expectEqual(error.OutOfMemory, err);
    }

    try std.testing.expectError(error.NotInstalled, ObjectType.binding(ctx_b.core));

    const value_a = try binding_a.new(.{ .value = 7 });
    try std.testing.expectEqual(@as(i32, 7), binding_a.payload(value_a).?.value);

    try ObjectType.install(ctx_b.core);
    const binding_b = try ObjectType.binding(ctx_b.core);
    const value_b = try binding_b.new(.{ .value = 11 });
    try std.testing.expectEqual(@as(i32, 11), binding_b.payload(value_b).?.value);
    try std.testing.expect(binding_a.payload(value_b) == null);
}

test "embedding public API core signatures stay source-compatible" {
    const create_runtime: fn (std.mem.Allocator) anyerror!*zjs.JSRuntime = zjs.JSRuntime.create;
    const create_runtime_with_options: fn (std.mem.Allocator, zjs.RuntimeOptions) anyerror!*zjs.JSRuntime = zjs.JSRuntime.createWithOptions;
    const create_context: fn (*zjs.JSRuntime) anyerror!*zjs.JSContext = zjs.JSContext.create;
    const create_context_with_options: fn (*zjs.JSRuntime, zjs.context.Options) anyerror!*zjs.JSContext = zjs.JSContext.createWithOptions;
    const define_function: fn (*zjs.JSContext, []const u8, zjs.native.Spec, zjs.native.Options) anyerror!zjs.JSValue = zjs.JSContext.defineFunction;
    const create_function: fn (*zjs.JSContext, []const u8, zjs.native.Spec, zjs.native.Options) anyerror!zjs.JSValue = zjs.JSContext.createFunction;
    const eval_script: fn (*zjs.JSContext, []const u8, zjs.context.EvalOptions) anyerror!zjs.JSValue = zjs.JSContext.eval;
    const array_buffer: fn (*zjs.JSContext, *zjs.value.Bytes.Store) anyerror!zjs.JSValue = zjs.JSContext.arrayBuffer;
    const to_owned_utf8: fn (*zjs.JSContext, zjs.JSValue, std.mem.Allocator) anyerror![]u8 = zjs.JSContext.toOwnedUtf8;

    _ = create_runtime;
    _ = create_runtime_with_options;
    _ = create_context;
    _ = create_context_with_options;
    _ = define_function;
    _ = create_function;
    _ = eval_script;
    _ = array_buffer;
    _ = to_owned_utf8;

    try std.testing.expect(zjs.value.Bytes.Store == zjs.JSValue.Bytes.Store);
    try std.testing.expect(@typeInfo(zjs.object.Object) == .@"opaque");
    // Public-module absences. Unified `zjs` is all_tests (which lifts these
    // names); the public facade is checked by `test-embedding`, whose `zjs`
    // is `src/root.zig` and does not export config_signature.
    if (!@hasDecl(zjs, "config_signature")) {
        try std.testing.expect(!@hasDecl(zjs, "JSBytes"));
        try std.testing.expect(!@hasDecl(zjs, "JSString"));
        try std.testing.expect(!@hasDecl(zjs, "PropNameID"));
        try std.testing.expect(!@hasDecl(zjs, "binding"));
    }
}

fn liveRealmCount(rt: *zjs.JSRuntime) usize {
    var count: usize = 0;
    var current = rt.firstContext();
    while (current) |ctx| : (current = ctx.runtime_next) count += 1;
    return count;
}

fn stealArrayPrototype(ctx_from: *zjs.JSContext, ctx_into: *zjs.JSContext) !zjs.JSValue {
    const proto = try ctx_from.eval("Array.prototype", .{});
    const global = try ctx_into.eval("globalThis", .{});
    try ctx_into.defineDataProperty(global, "stolenProto", proto, .{});
    return proto;
}

test "embedding destroy of one context keeps auto_init-bearing objects from that realm alive" {
    const allocator = std.testing.allocator;
    const rt = try zjs.JSRuntime.create(allocator);
    defer rt.destroy();
    const ctx_a = try zjs.JSContext.create(rt);
    defer ctx_a.destroy();
    const ctx_b = try zjs.JSContext.create(rt);

    _ = try stealArrayPrototype(ctx_b, ctx_a);
    const b_global = try ctx_b.globalObject();

    try std.testing.expectEqual(@as(usize, 2), liveRealmCount(rt));
    ctx_b.destroy();
    try std.testing.expectEqual(@as(usize, 2), liveRealmCount(rt));
    _ = rt.runObjectCycleRemoval();
    try std.testing.expectEqual(@as(usize, 2), liveRealmCount(rt));
    try std.testing.expect(rt.contextForGlobal(b_global) != null);
}

test "embedding newest-first context destroy with cross-realm Array.prototype still tears down" {
    const allocator = std.testing.allocator;
    const rt = try zjs.JSRuntime.create(allocator);
    errdefer rt.destroy();
    const ctx_a = try zjs.JSContext.create(rt);
    errdefer ctx_a.destroy();
    const ctx_b = try zjs.JSContext.create(rt);
    errdefer ctx_b.destroy();

    _ = try stealArrayPrototype(ctx_b, ctx_a);

    ctx_b.destroy();
    ctx_a.destroy();
    rt.destroy();
}

test "embedding oldest-first context destroy with cross-realm Array.prototype still tears down" {
    const allocator = std.testing.allocator;
    const rt = try zjs.JSRuntime.create(allocator);
    errdefer rt.destroy();
    const ctx_a = try zjs.JSContext.create(rt);
    errdefer ctx_a.destroy();
    const ctx_b = try zjs.JSContext.create(rt);
    errdefer ctx_b.destroy();

    _ = try stealArrayPrototype(ctx_b, ctx_a);

    ctx_a.destroy();
    ctx_b.destroy();
    rt.destroy();
}

test "embedding createRealm leftover is collected without JSContext.destroy on the child" {
    const allocator = std.testing.allocator;
    const rt = try zjs.JSRuntime.create(allocator);
    errdefer rt.destroy();
    const ctx = try zjs.JSContext.create(rt);
    errdefer ctx.destroy();

    const realm = try ctx.createRealm();
    const realm_global = try ctx.realmGlobal(realm);
    const array = try ctx.getProperty(realm_global, "Array");
    const proto = try ctx.getProperty(array, "prototype");
    const global = try ctx.eval("globalThis", .{});
    try ctx.defineDataProperty(global, "stolenProto", proto, .{});

    try std.testing.expectEqual(@as(usize, 2), liveRealmCount(rt));
    _ = rt.runObjectCycleRemoval();
    try std.testing.expectEqual(@as(usize, 2), liveRealmCount(rt));

    ctx.destroy();
    rt.destroy();
}

// Cookbook: a native class (design §9.2). `WorldState` is the host struct;
// typed members (`step`, `time`, `gravity`) never see a JSValue, managed
// members (`query`, `create`) get a `Call`. JS-created instances (`new
// World(stride)`) and host-created ones (`world.create`) share one class id,
// one prototype per realm and one finalizer.
const WorldState = struct {
    steps: i32 = 0,
    stride: i32 = 1,
    time_ms: f64 = 1.5,
    gravity: f64 = 9.8,

    var finalized: usize = 0;

    fn create(call: *zjs.native.Call) error{ OutOfMemory, TypeError }!*WorldState {
        const state = try std.testing.allocator.create(WorldState);
        state.* = .{};
        if (call.argc > 0) state.stride = call.arg(0).asInt32() orelse {
            std.testing.allocator.destroy(state);
            return error.TypeError;
        };
        return state;
    }

    fn destroy(self: *WorldState) void {
        finalized += 1;
        std.testing.allocator.destroy(self);
    }

    fn step(self: *WorldState, dt: i32) i32 {
        self.steps += 1;
        return dt + self.stride;
    }

    fn query(self: *WorldState, call: *zjs.native.Call) error{TypeError}!zjs.JSValue {
        if (call.argc == 0) return error.TypeError;
        self.steps += 1;
        return call.arg(0);
    }

    fn time(self: *WorldState) f64 {
        return self.time_ms;
    }

    fn getGravity(self: *WorldState) f64 {
        return self.gravity;
    }

    fn setGravity(self: *WorldState, g: f64) void {
        self.gravity = g;
    }

    fn label(self: *WorldState, call: *zjs.native.Call) !zjs.JSValue {
        _ = self;
        return try call.ctx.createString("world");
    }
};

const World = zjs.native.Class(.{
    .name = "World",
    .Self = WorldState,
    .constructor = WorldState.create,
    .constructor_length = 1,
    .finalize = WorldState.destroy,
    .methods = .{ .step = WorldState.step, .query = WorldState.query },
    .getters = .{ .time = WorldState.time, .gravity = WorldState.getGravity, .label = WorldState.label },
    .setters = .{ .gravity = WorldState.setGravity },
});

fn evalBool(ctx: *zjs.JSContext, source: []const u8) !bool {
    const result = try ctx.eval(source, .{});
    if (result.isException()) return error.JSException;
    return result.asBool() orelse error.NotABoolean;
}

test "embedding cookbook native class covers create, unwrap, methods, accessors, constructor, dispose and finalizer" {
    const allocator = std.testing.allocator;
    WorldState.finalized = 0;
    const rt = try zjs.JSRuntime.create(allocator);
    var rt_alive = true;
    defer if (rt_alive) rt.destroy();
    const ctx = try zjs.JSContext.create(rt);
    var ctx_alive = true;
    defer if (ctx_alive) ctx.destroy();

    const world = try ctx.defineClass(World, .{ .global_name = "World" });
    // Idempotent per runtime / realm: the same handle comes back.
    const again = try ctx.defineClass(World, .{});
    try std.testing.expectEqual(world.classId(), again.classId());

    // Host-created instance around a host-owned pointer.
    const state = try allocator.create(WorldState);
    state.* = .{ .stride = 10 };
    const obj = try world.create(ctx, state);
    const global = try ctx.globalObject();
    try ctx.defineDataProperty(global.value(), "w", obj, .{});
    try std.testing.expect(World.unwrap(obj) == state);
    try std.testing.expect(world.unwrap(obj) == state);
    try std.testing.expect(World.unwrap(try ctx.createObject()) == null);
    try std.testing.expect(World.unwrap(zjs.JSValue.int32(1)) == null);

    // K2 typed method: int in / int out through the leaf arm; state touched.
    try std.testing.expect(try evalBool(ctx, "w.step(32) === 42"));
    try std.testing.expectEqual(@as(i32, 1), state.steps);
    // Canonical marshal: a double-represented int32 is fine, a fraction is not.
    try std.testing.expect(try evalBool(ctx, "w.step(2.0) === 12"));
    try std.testing.expect(try evalBool(ctx, "(function () { try { w.step(1.5); return false; } catch (e) { return e instanceof TypeError; } })()"));
    // K2 managed method: the Call view, a mapped Zig error.
    try std.testing.expect(try evalBool(ctx, "w.query('q') === 'q'"));
    try std.testing.expect(try evalBool(ctx, "(function () { try { w.query(); return false; } catch (e) { return e instanceof TypeError; } })()"));
    // K3 typed getter / setter and a managed getter.
    try std.testing.expect(try evalBool(ctx, "w.time === 1.5"));
    try std.testing.expect(try evalBool(ctx, "w.gravity === 9.8"));
    try std.testing.expect(try evalBool(ctx, "(w.gravity = 2.5, w.gravity === 2.5)"));
    try std.testing.expectEqual(@as(f64, 2.5), state.gravity);
    try std.testing.expect(try evalBool(ctx, "w.label === 'world'"));
    try std.testing.expect(try evalBool(ctx, "(function () { try { w.gravity = 'x'; return false; } catch (e) { return e instanceof TypeError; } })()"));
    // Members are ordinary prototype properties.
    try std.testing.expect(try evalBool(ctx, "w instanceof World && Object.getPrototypeOf(w) === World.prototype && World.prototype.constructor === World"));
    try std.testing.expect(try evalBool(ctx, "typeof World.prototype.step === 'function' && World.prototype.step.length === 1 && World.prototype.step.name === 'step'"));
    try std.testing.expect(try evalBool(ctx, "!World.prototype.propertyIsEnumerable('step') && Object.keys(World.prototype).length === 0"));
    try std.testing.expect(try evalBool(ctx, "World.length === 1 && World.name === 'World'"));
    // Receiver class check: a foreign receiver throws, for methods and accessors.
    try std.testing.expect(try evalBool(ctx, "(function () { try { World.prototype.step.call({}, 1); return false; } catch (e) { return e instanceof TypeError; } })()"));
    try std.testing.expect(try evalBool(ctx, "(function () { try { World.prototype.query.call(1, 1); return false; } catch (e) { return e instanceof TypeError; } })()"));
    try std.testing.expect(try evalBool(ctx, "(function () { try { Object.getOwnPropertyDescriptor(World.prototype, 'time').get.call({}); return false; } catch (e) { return e instanceof TypeError && /World object expected/.test(e.message); } })()"));

    // JS-created instances: the constructor allocates the host state; a
    // call without `new` throws.
    try std.testing.expect(try evalBool(ctx, "var w2 = new World(3); w2.step(1) === 4 && w2 instanceof World"));
    try std.testing.expect(try evalBool(ctx, "(function () { try { World(); return false; } catch (e) { return e instanceof TypeError; } })()"));
    try std.testing.expect(try evalBool(ctx, "(function () { try { new World('x'); return false; } catch (e) { return e instanceof TypeError; } })()"));
    // Subclassing keeps new.target's prototype and the native payload.
    try std.testing.expect(try evalBool(ctx, "class Sub extends World { twice(x) { return this.step(x) * 2; } } var s = new Sub(5); s.twice(1) === 12 && s instanceof Sub && s instanceof World"));
    // An unreachable instance is finalized by the collector, not only at teardown.
    try std.testing.expect(try evalBool(ctx, "(function () { new World(); return true; })()"));
    try std.testing.expect(WorldState.finalized <= 1);
    _ = rt.runObjectCycleRemoval();
    try std.testing.expectEqual(@as(usize, 1), WorldState.finalized);

    // Dispose: detach the host pointer; later calls throw, the finalizer
    // never sees it, and the host frees it.
    try std.testing.expect(world.dispose(obj) == state);
    try std.testing.expect(World.unwrap(obj) == null);
    try std.testing.expect(try evalBool(ctx, "(function () { try { w.step(1); return false; } catch (e) { return e instanceof TypeError; } })()"));
    try std.testing.expect(try evalBool(ctx, "(function () { try { return w.time; } catch (e) { return e instanceof TypeError; } })()"));
    allocator.destroy(state);

    // Teardown finalizes the remaining JS-created instances (w2, s): the
    // class, its type record and the finalizer belong to the runtime.
    ctx.destroy();
    ctx_alive = false;
    rt.destroy();
    rt_alive = false;
    try std.testing.expectEqual(@as(usize, 3), WorldState.finalized);
}

test "embedding native class accessor descriptors keep identity across reads" {
    const allocator = std.testing.allocator;
    WorldState.finalized = 0;
    const rt = try zjs.JSRuntime.create(allocator);
    defer rt.destroy();
    const ctx = try zjs.JSContext.create(rt);
    defer ctx.destroy();
    _ = try ctx.defineClass(World, .{ .global_name = "World" });

    // The prototype accessor is a real K3 function object pair: the same
    // objects come back from every descriptor read, with accessor names and
    // attributes as qjs JS_CGETSET_DEF publishes them.
    try std.testing.expect(try evalBool(ctx,
        \\var d1 = Object.getOwnPropertyDescriptor(World.prototype, 'gravity');
        \\var d2 = Object.getOwnPropertyDescriptor(World.prototype, 'gravity');
        \\typeof d1.get === 'function' && typeof d1.set === 'function' &&
        \\d1.get === d2.get && d1.set === d2.set && d1.get !== d1.set &&
        \\d1.get.name === 'get gravity' && d1.set.name === 'set gravity' &&
        \\d1.get.length === 0 && d1.set.length === 1 &&
        \\d1.configurable === true && d1.enumerable === false
    ));
    try std.testing.expect(try evalBool(ctx,
        \\var t = Object.getOwnPropertyDescriptor(World.prototype, 'time');
        \\t.set === undefined && t.get === Object.getOwnPropertyDescriptor(World.prototype, 'time').get
    ));
    // Reflect / class-field style consumers see the same function object.
    try std.testing.expect(try evalBool(ctx,
        \\var g = Object.getOwnPropertyDescriptor(World.prototype, 'time').get;
        \\Reflect.getOwnPropertyDescriptor(World.prototype, 'time').get === g &&
        \\Object.getOwnPropertyDescriptors(World.prototype).time.get === g
    ));
    // The materialized getter behaves as the property read does.
    try std.testing.expect(try evalBool(ctx, "var w = new World(); g.call(w) === 1.5 && w.time === 1.5"));
}

fn NamespaceType(comptime namespace: anytype) type {
    return switch (@typeInfo(@TypeOf(namespace))) {
        .type => namespace,
        else => @TypeOf(namespace),
    };
}

fn expectPublicDeclSnapshot(
    comptime label: []const u8,
    comptime namespace: anytype,
    comptime expected: []const []const u8,
) !void {
    @setEvalBranchQuota(20000);
    const decls = @typeInfo(NamespaceType(namespace)).@"struct".decls;
    var missing: usize = 0;
    var extra: usize = 0;
    inline for (expected) |name| {
        if (!@hasDecl(NamespaceType(namespace), name)) {
            std.debug.print("{s}: missing public name {s}\n", .{ label, name });
            missing += 1;
        }
    }
    inline for (decls) |decl| {
        var found = false;
        inline for (expected) |name| {
            if (std.mem.eql(u8, decl.name, name)) found = true;
        }
        if (!found) {
            std.debug.print("{s}: unexpected public name {s}\n", .{ label, decl.name });
            extra += 1;
        }
    }
    if (missing != 0 or extra != 0) {
        std.debug.print("{s}: actual names ({d}):\n", .{ label, decls.len });
        inline for (decls) |decl| std.debug.print("    \"{s}\",\n", .{decl.name});
        return error.TestExpectedEqual;
    }
    try std.testing.expectEqual(expected.len, decls.len);
}

// Checked-in public-surface names. This is not a frozen API snapshot (the
// historical check_public_api.zig / architecture-update-api-snapshot step
// was removed because the surface was not frozen). Adding or removing a
// public name must update this list in the same commit.
const public_root_decls = [_][]const u8{
    "runtime",
    "JSRuntime",
    "JSContext",
    "CallSite",
    "JSValue",
    "RuntimeOptions",
    "RuntimeMemoryUsage",
    "GCStats",
    "GCPauseDistribution",
    "OpcodeProfile",
    "default_stack_size",
    "default_gc_threshold",
    "opcode_profile_build_enabled",
    "activateOpcodeProfile",
    "value",
    "native",
    "host",
    "object",
    "context",
    "module",
    "job",
};
const public_value_decls = [_][]const u8{
    "Value",
    "Scope",
    "Local",
    "Persistent",
    "Weak",
    "String",
    "Bytes",
    "undefinedValue",
    "nullValue",
    "boolean",
    "int32",
    "float64",
    "numberFromU64",
    "numberFromI64",
    "bigIntFromI64",
    "bigIntFromU64",
    "createString",
    "appendRawString",
    "appendString",
    "toOwnedString",
    "toIntegerOrInfinity",
    "isTruthy",
};
const public_host_decls = [_][]const u8{
    "NativeBinding",
    "NativeObject",
    "PropName",
    "defineScriptArgs",
    "defineArgvGlobals",
    "evalGlobalScriptSource",
    "evalGlobalScriptValue",
};
const public_object_decls = [_][]const u8{
    "Object",
    "MemoryAccount",
    "SharedArrayBufferRef",
    "String",
    "toValue",
    "arrayLength",
    "promiseResult",
    "promiseIsRejected",
    "OwnDataProperty",
    "forEachOwnDataProperty",
    "Buffer",
    "createPlain",
    "createError",
    "createArray",
    "createArrayValue",
    "createArrayBuffer",
    "fromValue",
    "isCallableValue",
    "isPromiseObject",
    "isPromiseValue",
    "isArray",
    "isArrayBufferObject",
    "isTypedArrayObject",
    "typedArrayByteLength",
    "arrayBufferConstructLength",
    "typedArrayConstructFullBufferOwned",
    "getProperty",
    "getOwnIndexPropertyValue",
    "defineValueProperty",
    "defineHiddenValueProperty",
    "defineAccessorProperty",
    "defineStringProperty",
    "defineHiddenStringProperty",
    "defineIntProperty",
    "defineHiddenIntProperty",
    "defineStringArrayGlobal",
    "constructorPrototypeObject",
    "appendArrayValue",
};
const public_context_decls = [_][]const u8{
    "Options",
    "EvalMode",
    "EvalOptions",
    "EvalTiming",
    "DataPropertyOptions",
    "PropertyAccessOptions",
    "PropertyDescriptor",
    "ErrorOptions",
    "ScriptEvalOptions",
    "FunctionCallOptions",
    "globalObject",
    "callFunction",
};
const public_module_decls = [_][]const u8{
    "Key",
    "Source",
    "Host",
    "ResolveResult",
    "LoadResult",
    "evalFileGraphWithHost",
};
const public_job_decls = [_][]const u8{
    "DrainOptions",
    "DrainResult",
    "drain",
};
const public_runtime_decls = [_][]const u8{
    "EventLoop",
    "EventLoopOptions",
    "EventLoopRunResult",
    "runUntilIdle",
    "cleanupAtomicsWaitersForContext",
    "wakeAtomicsWaitersForRuntimes",
    "detachArrayBuffer",
    "evalFileModuleGraphWithOutput",
    "resolveModuleSpecifier",
};

test "public API surface snapshot matches the checked-in name lists" {
    if (@hasDecl(zjs, "config_signature")) return;

    var failed = false;
    expectPublicDeclSnapshot("zjs", zjs, &public_root_decls) catch {
        failed = true;
    };
    expectPublicDeclSnapshot("zjs.value", zjs.value, &public_value_decls) catch {
        failed = true;
    };
    expectPublicDeclSnapshot("zjs.host", zjs.host, &public_host_decls) catch {
        failed = true;
    };
    expectPublicDeclSnapshot("zjs.object", zjs.object, &public_object_decls) catch {
        failed = true;
    };
    expectPublicDeclSnapshot("zjs.context", zjs.context, &public_context_decls) catch {
        failed = true;
    };
    expectPublicDeclSnapshot("zjs.module", zjs.module, &public_module_decls) catch {
        failed = true;
    };
    expectPublicDeclSnapshot("zjs.job", zjs.job, &public_job_decls) catch {
        failed = true;
    };
    expectPublicDeclSnapshot("zjs.runtime", zjs.runtime, &public_runtime_decls) catch {
        failed = true;
    };
    if (failed) return error.TestExpectedEqual;

    // Known debt (backlog H9): JSValue is the public value type and still
    // publishes internal helpers. The count is pinned so a leak expansion
    // is visible.
    // 89 -> 88 on 2026-08-19: `has_fast_int32_slot_move` went away with the
    // NaN-boxed representation it existed to discriminate.
    // 88 -> 89 on 2026-08-20: `catchTarget`, the decoder for the catch-marker
    // offset `asCatchOffset` (already public) encodes. Three dispatch files
    // had hand-written that decode; it belongs next to the encoding. The
    // surface grew by one on purpose — which is what this pin is for.
    // 89 -> 90 on 2026-08-27: `isTracerOwned` centralizes the exact tag range
    // whose retain/release operations tracing erases. It remains an internal
    // helper exposed through the known broad JSValue surface; pin the leak
    // rather than pretending the declaration did not land.
    // 90 -> 80 across the tracing-GC completion (2026-09-05): the refcount
    // surface left with the collector it served -- `dup`, `free`,
    // `freeFromPlainObjectDestroy`, `releaseRefCountedNeedsDestroy` and the
    // six compatibility shells (`freeDuringActiveBytecode`,
    // `freeObjectAssumeObject*`, `releaseObjectAssumeObjectNeedsDestroy*`,
    // `releaseRefCountedNeedsDestroyDuringActiveBytecode`), which had already
    // decayed to assertion-only bodies with a constant `false` predicate.
    // The pin was written as 84 before the last four went; this test is not
    // part of `zig build test`, so it went unnoticed until checkpoint-gate.
    const jsvalue_decl_count = @typeInfo(zjs.JSValue).@"struct".decls.len;
    try std.testing.expectEqual(@as(usize, 80), jsvalue_decl_count);

    // JSRuntime is likewise a public type with a deliberately broad internal
    // surface. Pin its declaration count so additions and removals require an
    // explicit contract update instead of passing silently.
    // 168 -> 174 during the tracing-GC tranche: `traceValueRootFrameChain`,
    // WeakRef's `keepAliveWeakRefTarget` / `clearWeakRefKeptAlive`, the two
    // test-only pacing controls, and `enqueueFinalizationJobReserved`. These
    // are six named internal seams on the already-broad type, not an unnoticed
    // embedding API promise.
    // 174 -> 178 with the deferred class-payload root machinery (rc
    // retirement tranche): `verifyDeferredClassPayloadRootLiveness`,
    // `registerReservedDeferredClassPayloadRoot`,
    // `unregisterDeferredClassPayloadRoot`, and
    // `isActiveDeferredClassPayloadFinalizerCallback` -- one named family of
    // internal GC seams, same class as the tranche above. Booked 2026-08-30
    // when this pin was found red on main since the tranche landed.
    const jsruntime_decl_count = @typeInfo(zjs.JSRuntime).@"struct".decls.len;
    // 178 -> 177 on 2026-09-03 (GC code-volume ablation, batch 1):
    // `createWithTrace` removed: a zero-caller wrapper over
    // `createWithOptions(.{ .trace_writer = w })`, which stays public and is
    // what the `--trace-memory` CLI path uses. No example or doc named it.
    // The tracing-only cleanup removed the deferred-value queue, then seven
    // write-only borrowed-cleanup state methods. The prior pin was already one
    // below reflection's actual count; the measured surface is now 164.
    // 164 -> 162 across the tracing-GC completion (2026-09-05): `dupValue`
    // and `freeValue` went with the refcount surface; the test-only
    // `restoreDefaultRootScanForTest` (R1-a precise-root probes) arrived.
    try std.testing.expectEqual(@as(usize, 162), jsruntime_decl_count);
}

//! Validates host eval, managed functions, handles, and realm teardown
//! against `src/root.zig`.
const std = @import("std");
const zjs = @import("zjs");
const HostState = struct {
    value: i32,

    fn call(c: *zjs.Call) zjs.Value {
        return zjs.Value.int32(c.state(HostState).value);
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

    fn stop(_: *zjs.Runtime, ctx: ?*anyopaque) bool {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        if (self.budget == 0) return true;
        self.budget -= 1;
        return false;
    }
};

test "embedding cookbook basic script eval example compiles and runs" {
    const allocator = std.testing.allocator;
    const rt = try zjs.Runtime.create(allocator, .{});
    defer rt.destroy();

    const ctx = try zjs.Context.create(rt, .{});
    defer ctx.destroy();

    const result = try ctx.eval("let x = 1 + 2; x;", .{});

    try std.testing.expectEqual(@as(?i32, 3), result.as(.int));
}

test "embedding cookbook eval with output example compiles and runs" {
    const allocator = std.testing.allocator;
    const rt = try zjs.Runtime.create(allocator, .{});
    defer rt.destroy();

    const ctx = try zjs.Context.create(rt, .{});
    defer ctx.destroy();

    var buffer: [128]u8 = undefined;
    var output = std.Io.Writer.fixed(&buffer);

    const result = try ctx.eval("print('ok');", .{
        .output = &output,
    });

    try std.testing.expect(result.is(.undefined_value));
    try std.testing.expectEqualStrings("ok\n", output.buffered());
}

test "embedding cookbook host-held values example compiles and roots correctly" {
    const allocator = std.testing.allocator;
    const rt = try zjs.Runtime.create(allocator, .{});
    defer rt.destroy();

    const ctx = try zjs.Context.create(rt, .{});
    defer ctx.destroy();

    const object = try ctx.eval("({ answer: 42 })", .{});

    var scope = rt.enterHandleScope();
    defer scope.deinit();

    const local = try scope.localDup(object);

    var persistent = try rt.createPersistentValue(local.get());
    defer persistent.deinit();

    scope.deinit();

    const answer = try ctx.getProperty(persistent.get(), "answer");
    try std.testing.expectEqual(@as(?i32, 42), answer.as(.int));
}

test "embedding cookbook host function example compiles and runs" {
    const allocator = std.testing.allocator;
    const rt = try zjs.Runtime.create(allocator, .{});
    defer rt.destroy();

    const ctx = try zjs.Context.create(rt, .{});
    defer ctx.destroy();

    var state = HostState{ .value = 42 };
    _ = try ctx.defineFunction("hostValue", HostState.call, .{ .state = @ptrCast(&state) });

    const result = try ctx.eval("hostValue()", .{});
    try std.testing.expectEqual(@as(?i32, 42), result.as(.int));
}

// Contract pin for the host hookup path: a host function is a
// `Call` thunk bound to one immutable `NativeEntry`; the VM
// dispatches it exactly like a builtin.
const ContractHost = struct {
    factor: i32,
    calls: usize = 0,
    saw_object_this: bool = false,
    finalized: *bool,

    fn call(c: *zjs.Call) anyerror!zjs.Value {
        const self = c.state(ContractHost);
        self.calls += 1;
        if (c.this.is(.object)) self.saw_object_this = true;
        if (c.argc < 2) return error.TypeError;
        const a = c.arg(0).as(.int) orelse return error.TypeError;
        const b = c.arg(1).as(.int) orelse return error.TypeError;
        if (a < 0) return error.RangeError;
        return zjs.Value.int32(self.factor * (a + b));
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

    const rt = try zjs.Runtime.create(allocator, .{});
    var rt_alive = true;
    defer if (rt_alive) rt.destroy();
    const ctx = try zjs.Context.create(rt, .{});
    var ctx_alive = true;
    defer if (ctx_alive) ctx.destroy();

    _ = try ctx.defineFunction("hostCombine", ContractHost.call, .{ .length = 2, .state = @ptrCast(&state), .finalize = ContractHost.finalize });

    // Scoped so every eval result is released before the teardown choreography
    // below asserts on runtime/context destruction order.
    {
        const shape = try ctx.eval(
            "typeof hostCombine === 'function' && hostCombine.name === 'hostCombine' && hostCombine.length === 2",
            .{},
        );
        try std.testing.expectEqual(true, shape.as(.boolean).?);

        const sum = try ctx.eval("hostCombine(19, 23) + 16", .{});
        try std.testing.expectEqual(@as(?i32, 100), sum.as(.int));

        const method_sum = try ctx.eval("({ combine: hostCombine }).combine(1, 2)", .{});
        try std.testing.expectEqual(@as(?i32, 6), method_sum.as(.int));
        try std.testing.expect(state.saw_object_this);

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

    ctx.destroy();
    ctx_alive = false;
    try std.testing.expect(!finalized);

    rt.destroy();
    rt_alive = false;
    try std.testing.expect(finalized);
}

test "embedding cookbook strings and bytes examples compile and run" {
    const allocator = std.testing.allocator;
    const rt = try zjs.Runtime.create(allocator, .{});
    defer rt.destroy();

    const ctx = try zjs.Context.create(rt, .{});
    defer ctx.destroy();

    const value = try ctx.eval("({ toString() { return 'path'; } })", .{});

    const text = try ctx.toOwnedUtf8(value, allocator);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("path", text);

    var bytes_state = BytesState{ .allocator = allocator };
    const backing = try allocator.alloc(u8, 4);
    @memcpy(backing, &[_]u8{ 1, 2, 3, 4 });

    var store = zjs.Value.Bytes.Store.owned(backing, .{
        .context = &bytes_state,
        .deinit = BytesState.deinit,
    });
    errdefer store.release();

    const array_buffer = try ctx.arrayBuffer(&store);

    const bytes = try array_buffer.asBytes();
    const writable = try bytes.sliceMut();
    writable[0] = 9;
    try std.testing.expectEqualSlices(u8, &.{ 9, 2, 3, 4 }, bytes.slice());
    try std.testing.expectEqual(@as(usize, 0), bytes_state.calls);

    _ = rt.runObjectCycleRemoval();
    try std.testing.expectEqual(@as(usize, 1), bytes_state.calls);
}

test "embedding cookbook construction with limits example compiles and runs" {
    const allocator = std.testing.allocator;
    const rt = try zjs.Runtime.create(allocator, .{
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
    const rt = try zjs.Runtime.create(allocator, .{});
    defer rt.destroy();

    const ctx = try zjs.Context.create(rt, .{});
    defer ctx.destroy();

    var state = InterruptBudget{ .budget = 0 };
    rt.setInterruptHandler(InterruptBudget.stop, &state);
    defer rt.setInterruptHandler(null, null);

    try std.testing.expectError(error.Interrupted, ctx.eval("while (true) {}", .{}));
}

test "embedding cookbook module eval example compiles and runs" {
    const allocator = std.testing.allocator;
    const rt = try zjs.Runtime.create(allocator, .{});
    defer rt.destroy();

    const ctx = try zjs.Context.create(rt, .{});
    defer ctx.destroy();

    _ = try ctx.eval(
        \\const value = await Promise.resolve(42);
        \\export { value };
    , .{ .mode = .module });
}

test "embedding public API core signatures stay source-compatible" {
    const create_runtime: fn (std.mem.Allocator, zjs.Runtime.Options) anyerror!*zjs.Runtime = zjs.Runtime.create;
    const create_context: fn (*zjs.Runtime, zjs.Context.Options) anyerror!*zjs.Context = zjs.Context.create;
    const eval_script: fn (*zjs.Context, []const u8, zjs.Context.EvalOptions) anyerror!zjs.Value = zjs.Context.eval;
    const array_buffer: fn (*zjs.Context, *zjs.Value.Bytes.Store) anyerror!zjs.Value = zjs.Context.arrayBuffer;
    const to_owned_utf8: fn (*zjs.Context, zjs.Value, std.mem.Allocator) anyerror![]u8 = zjs.Context.toOwnedUtf8;

    _ = create_runtime;
    _ = create_context;
    _ = eval_script;
    _ = array_buffer;
    _ = to_owned_utf8;

    try std.testing.expect(@hasDecl(zjs.Context, "defineFunction"));
    try std.testing.expect(@hasDecl(zjs.Context, "createFunction"));
    try std.testing.expect(@hasDecl(zjs.Context, "defineScriptArgs"));
    try std.testing.expect(@hasDecl(zjs, "Call"));
    try std.testing.expect(@hasDecl(zjs, "EventLoop"));
    try std.testing.expect(zjs.Runtime == zjs.JSRuntime);
    try std.testing.expect(zjs.Context == zjs.JSContext);
    try std.testing.expect(zjs.Value == zjs.JSValue);
    try std.testing.expect(!@hasDecl(zjs, "value"));
    try std.testing.expect(!@hasDecl(zjs, "object"));
    try std.testing.expect(!@hasDecl(zjs, "module"));
    try std.testing.expect(!@hasDecl(zjs, "job"));
    try std.testing.expect(!@hasDecl(zjs, "host"));
    try std.testing.expect(!@hasDecl(zjs, "context"));
    try std.testing.expect(!@hasDecl(zjs, "public_api"));
    try std.testing.expect(!@hasDecl(zjs, "CallSite"));
    try std.testing.expect(!@hasDecl(zjs, "PropertySite"));
    try std.testing.expect(!@hasDecl(zjs, "binding"));
}

fn liveRealmCount(rt: *zjs.Runtime) usize {
    var count: usize = 0;
    var current = rt.firstContext();
    while (current) |ctx| : (current = ctx.runtime_next) count += 1;
    return count;
}

fn stealArrayPrototype(ctx_from: *zjs.Context, ctx_into: *zjs.Context) !zjs.Value {
    const proto = try ctx_from.eval("Array.prototype", .{});
    const global = try ctx_into.eval("globalThis", .{});
    try ctx_into.defineDataProperty(global, "stolenProto", proto, .{});
    return proto;
}

test "embedding destroy of one context keeps auto_init-bearing objects from that realm alive" {
    const allocator = std.testing.allocator;
    const rt = try zjs.Runtime.create(allocator, .{});
    defer rt.destroy();
    const ctx_a = try zjs.Context.create(rt, .{});
    defer ctx_a.destroy();
    const ctx_b = try zjs.Context.create(rt, .{});

    _ = try stealArrayPrototype(ctx_b, ctx_a);
    _ = try ctx_b.globalObject();

    try std.testing.expectEqual(@as(usize, 2), liveRealmCount(rt));
    ctx_b.destroy();
    try std.testing.expectEqual(@as(usize, 2), liveRealmCount(rt));
    _ = rt.runObjectCycleRemoval();
    try std.testing.expectEqual(@as(usize, 2), liveRealmCount(rt));
}

test "embedding newest-first context destroy with cross-realm Array.prototype still tears down" {
    const allocator = std.testing.allocator;
    const rt = try zjs.Runtime.create(allocator, .{});
    errdefer rt.destroy();
    const ctx_a = try zjs.Context.create(rt, .{});
    errdefer ctx_a.destroy();
    const ctx_b = try zjs.Context.create(rt, .{});
    errdefer ctx_b.destroy();

    _ = try stealArrayPrototype(ctx_b, ctx_a);

    ctx_b.destroy();
    ctx_a.destroy();
    rt.destroy();
}

test "embedding oldest-first context destroy with cross-realm Array.prototype still tears down" {
    const allocator = std.testing.allocator;
    const rt = try zjs.Runtime.create(allocator, .{});
    errdefer rt.destroy();
    const ctx_a = try zjs.Context.create(rt, .{});
    errdefer ctx_a.destroy();
    const ctx_b = try zjs.Context.create(rt, .{});
    errdefer ctx_b.destroy();

    _ = try stealArrayPrototype(ctx_b, ctx_a);

    ctx_a.destroy();
    ctx_b.destroy();
    rt.destroy();
}

test "embedding createRealm leftover is collected without JSContext.destroy on the child" {
    const allocator = std.testing.allocator;
    const rt = try zjs.Runtime.create(allocator, .{});
    errdefer rt.destroy();
    const ctx = try zjs.Context.create(rt, .{});
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

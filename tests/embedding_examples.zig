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

    const Output = struct {
        fn write(call: *zjs.Call) !zjs.Value {
            const bytes = try call.ctx.toOwnedUtf8(call.arg(0), allocatorFor(call));
            defer allocatorFor(call).free(bytes);
            if (call.output()) |writer| try writer.print("{s}\n", .{bytes});
            return zjs.Value.undefinedValue();
        }

        fn allocatorFor(call: *zjs.Call) std.mem.Allocator {
            return call.runtime().nativeAllocator();
        }
    };
    _ = try ctx.defineFunction("write", Output.write, .{ .length = 1 });

    var buffer: [128]u8 = undefined;
    var output = std.Io.Writer.fixed(&buffer);

    const result = try ctx.eval("write('ok');", .{
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

    const local = try scope.local(object);

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

    _ = rt.collectForTest();
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
    try std.testing.expect(!@hasDecl(zjs, "EventLoop"));
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
    _ = rt.collectForTest();
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
    _ = rt.collectForTest();
    try std.testing.expectEqual(@as(usize, 2), liveRealmCount(rt));

    ctx.destroy();
    rt.destroy();
}

test "engine-only realm has no bundled web globals" {
    const rt = try zjs.Runtime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try zjs.Context.create(rt, .{});
    defer ctx.destroy();

    const result = try ctx.eval(
        \\["DOMException", "performance", "navigator", "print", "console"]
        \\    .filter((name) => name in globalThis).join(",")
    , .{});
    const names = try ctx.toOwnedUtf8(result, std.testing.allocator);
    defer std.testing.allocator.free(names);
    try std.testing.expectEqualStrings("", names);
}

const HostConstructor = struct {
    /// Returns `new.target`, which replaces the constructed instance.
    fn construct(c: *zjs.Call) zjs.Value {
        return c.newTarget();
    }
};

test "host constructor functions see new.target and reject plain calls" {
    const rt = try zjs.Runtime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try zjs.Context.create(rt, .{});
    defer ctx.destroy();

    _ = try ctx.defineFunction("HostCtor", HostConstructor.construct, .{ .length = 0, .constructor = true, .with_prototype = true });
    const result = try ctx.eval(
        \\class Derived extends HostCtor {}
        \\let plain = "no error";
        \\try { HostCtor(); } catch (error) { plain = error.constructor.name; }
        \\[new HostCtor() === HostCtor, new Derived() === Derived, plain].join(",")
    , .{});
    const text = try ctx.toOwnedUtf8(result, std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("true,true,TypeError", text);
}

test "embedding defineDataProperty honours Proxy and TypedArray [[DefineOwnProperty]]" {
    const rt = try zjs.Runtime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try zjs.Context.create(rt, .{});
    defer ctx.destroy();

    const proxy = try ctx.eval(
        \\globalThis.log = []; globalThis.target = {};
        \\new Proxy(target, { defineProperty(t, k, d) { log.push(k); return Reflect.defineProperty(t, k, d); } })
    , .{});
    try ctx.defineDataProperty(proxy, "x", zjs.Value.int32(1), .{});
    const typed = try ctx.eval("globalThis.ta = new Uint8Array(2)", .{});
    try ctx.defineDataProperty(typed, "0", zjs.Value.int32(7), .{ .writable = true, .enumerable = true, .configurable = true });
    // A failed DefinePropertyOrThrow is a pending TypeError, like any throw.
    try std.testing.expectError(error.JSException, ctx.defineDataProperty(typed, "5", zjs.Value.int32(1), .{}));
    try std.testing.expect(try ctx.consumePendingExceptionIfErrorName("TypeError"));

    const result = try ctx.eval("[log.join(), target.x, Object.keys(ta).length, ta[0]].join()", .{});
    const text = try ctx.toOwnedUtf8(result, std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("x,1,2,7", text);
}

test "a stale pending exception does not break the next host entry" {
    const rt = try zjs.Runtime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try zjs.Context.create(rt, .{});
    defer ctx.destroy();

    // The embedder ignores the first failure and never takes the exception.
    try std.testing.expectError(error.JSException, ctx.eval("throw new Error('first')", .{}));
    try std.testing.expect(ctx.hasException());
    const joined = try ctx.eval("[1, 2].join()", .{});
    const text = try ctx.toOwnedUtf8(joined, std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("1,2", text);
    try std.testing.expect(!ctx.hasException());
}

test "an installed in-memory loader serves eval(.module) static imports and import()" {
    const Memory = struct {
        fn resolve(_: ?*anyopaque, allocator: std.mem.Allocator, _: ?[]const u8, specifier: []const u8, _: zjs.ModuleSourceLoader.Resolution) error{ OutOfMemory, ModuleNotFound }![]u8 {
            if (std.mem.eql(u8, specifier, "unresolvable")) return error.ModuleNotFound;
            return allocator.dupe(u8, specifier);
        }
        fn read(_: ?*anyopaque, _: std.Io, allocator: std.mem.Allocator, path: []const u8, _: usize) std.Io.Dir.ReadFileAllocError![]u8 {
            if (std.mem.eql(u8, path, "dep")) return allocator.dupe(u8, "export const answer = 42;");
            if (std.mem.eql(u8, path, "lazy")) return allocator.dupe(u8, "export default 'later';");
            return error.FileNotFound;
        }
        fn metadataUrl(_: ?*anyopaque, allocator: std.mem.Allocator, name: []const u8) error{OutOfMemory}![]u8 {
            return allocator.dupe(u8, name);
        }
        fn syntheticKind(_: ?*anyopaque, _: []const u8, _: ?[]const u8) ?zjs.core.module.SyntheticKind {
            return null;
        }
    };
    const loader: zjs.ModuleSourceLoader = .{
        .resolve = Memory.resolve,
        .read = Memory.read,
        .metadataUrl = Memory.metadataUrl,
        .syntheticKind = Memory.syntheticKind,
    };

    const rt = try zjs.Runtime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try zjs.Context.create(rt, .{});
    defer ctx.destroy();
    ctx.setModuleSourceLoader(&loader);

    _ = try ctx.eval(
        \\import { answer } from "dep";
        \\globalThis.result = answer + ":" + (await import("lazy")).default;
    , .{ .mode = .module, .filename = "main" });
    const result = try ctx.getProperty(try ctx.globalObject(), "result");
    const text = try ctx.toOwnedUtf8(result, std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("42:later", text);

    try std.testing.expectError(error.JSException, ctx.eval("import 'missing';", .{ .mode = .module, .filename = "bad" }));
    _ = ctx.takeException();

    // A resolve failure names the specifier like a read failure does.
    try std.testing.expectError(error.JSException, ctx.eval("import 'unresolvable';", .{ .mode = .module, .filename = "bad2" }));
    const message = try ctx.toOwnedUtf8(ctx.takeException(), std.testing.allocator);
    defer std.testing.allocator.free(message);
    try std.testing.expect(std.mem.indexOf(u8, message, "unresolvable") != null);
}

fn requireOneArgument(c: *zjs.Call) anyerror!zjs.Value {
    if (c.argc == 0) return c.throwRangeError("needs one argument");
    return c.arg(0);
}

test "Call.throwRangeError surfaces a catchable RangeError with its message" {
    const rt = try zjs.Runtime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try zjs.Context.create(rt, .{});
    defer ctx.destroy();

    _ = try ctx.defineFunction("requireOne", requireOneArgument, .{ .length = 1 });
    const result = try ctx.eval(
        \\let r = 0;
        \\try { requireOne(); } catch (e) { if (e instanceof RangeError && e.message === "needs one argument") r = 1; }
        \\r + requireOne(2);
    , .{});
    try std.testing.expectEqual(@as(?i32, 3), result.as(.int));
}

test "Context.deletePropertyKey converts the key and reports non-configurable properties" {
    const rt = try zjs.Runtime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try zjs.Context.create(rt, .{});
    defer ctx.destroy();

    const object = try ctx.eval("globalThis.o = { [Symbol.for('k')]: 1, 2: 'two', a: 1 }; Object.defineProperty(o, 'fixed', { value: 1 }); o", .{});
    try std.testing.expect(try ctx.deletePropertyKey(object, try ctx.eval("Symbol.for('k')", .{}), .{}));
    try std.testing.expect(try ctx.deletePropertyKey(object, zjs.Value.int32(2), .{}));
    try std.testing.expect(!try ctx.deletePropertyKey(object, try ctx.eval("'fixed'", .{}), .{}));
    try std.testing.expect(!ctx.hasException());
    const remaining = try ctx.eval("Reflect.ownKeys(o).join()", .{});
    const text = try ctx.toOwnedUtf8(remaining, std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("a,fixed", text);

    try std.testing.expectError(error.JSException, ctx.deletePropertyKey(object, try ctx.eval("({ toString() { throw new SyntaxError('key'); } })", .{}), .{}));
    try std.testing.expect(try ctx.consumePendingExceptionIfErrorName("SyntaxError"));
}

test "every Context failure is error.JSException with the exception pending" {
    const rt = try zjs.Runtime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try zjs.Context.create(rt, .{});
    defer ctx.destroy();

    const big = try ctx.eval("10n", .{});
    try std.testing.expectError(error.JSException, ctx.toNumber(big));
    try std.testing.expect(try ctx.consumePendingExceptionIfErrorName("TypeError"));

    const symbol = try ctx.eval("Symbol()", .{});
    try std.testing.expectError(error.JSException, ctx.toNumber(symbol));
    try std.testing.expect(try ctx.consumePendingExceptionIfErrorName("TypeError"));

    try std.testing.expectError(error.JSException, ctx.deleteProperty(zjs.Value.int32(1), "x"));
    try std.testing.expect(ctx.hasException());
    _ = ctx.takeException();

    try std.testing.expectError(error.JSException, ctx.callFunction(zjs.Value.int32(1), &.{}, .{}));
    try std.testing.expect(try ctx.consumePendingExceptionIfErrorName("TypeError"));

    try std.testing.expectError(error.JSException, ctx.eval("let let = ;", .{}));
    try std.testing.expect(try ctx.consumePendingExceptionIfErrorName("SyntaxError"));
    try std.testing.expect(!ctx.hasException());

    try std.testing.expectError(error.JSException, ctx.realmGlobalObject(try ctx.eval("({ global: 1 })", .{})));
    try std.testing.expect(try ctx.consumePendingExceptionIfErrorName("TypeError"));

    _ = try ctx.eval("Object.freeze(globalThis)", .{});
    try std.testing.expectError(error.JSException, ctx.defineScriptArgs(&.{"a"}));
    try std.testing.expect(try ctx.consumePendingExceptionIfErrorName("TypeError"));
}

test "weak handle callbacks may release handles and re-enter the engine" {
    const rt = try zjs.Runtime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try zjs.Context.create(rt, .{});
    defer ctx.destroy();
    const H = struct {
        var handles: [2]zjs.WeakPersistentValue = undefined;
        var released = false;
        var context: ?*zjs.Context = null;
        var evals: usize = 0;
        fn release(_: *zjs.Runtime, _: ?*anyopaque) void {
            if (released) return;
            released = true;
            // A host tearing down a group of weak handles when one member dies.
            handles[0].deinit();
            handles[1].deinit();
        }
        fn reenter(_: *zjs.Runtime, _: ?*anyopaque) void {
            const c = context orelse return;
            _ = c.eval("globalThis.fromWeak = [1, 2, 3].map((x) => ({ x }))", .{}) catch {
                c.clearException();
                return;
            };
            evals += 1;
        }
    };
    H.released = false;
    H.handles[0] = try rt.createWeakPersistentValue(try ctx.eval("({ a: 1 })", .{}), H.release, null);
    H.handles[1] = try rt.createWeakPersistentValue(try ctx.eval("({ b: 1 })", .{}), H.release, null);
    H.context = ctx;
    H.evals = 0;
    var reentrant = try rt.createWeakPersistentValue(try ctx.eval("({ c: 1 })", .{}), H.reenter, null);
    defer reentrant.deinit();
    _ = try rt.forceGC(null);
    _ = try rt.forceGC(null);
    try std.testing.expect(H.released);
    try std.testing.expectEqual(@as(usize, 1), H.evals);
    try std.testing.expectEqual(@as(f64, 3), (try ctx.eval("fromWeak.length", .{})).asNumber().?);
}

test "a host callback re-entering the running Machine keeps the outer call's argument window" {
    // A call site retreats the operand top past `[f, o]` and polls before the
    // callee frame takes them; until then only the Machine's pending window
    // keeps them traced. A host callback that re-enters the SAME Machine
    // there (`callFunction` from a weak-handle callback after a collection,
    // or from the interrupt handler that poll runs) used to end that window
    // when its own callee retired, so a later collection before the outer
    // push missed `o`. The interrupt handler is the deterministic trigger.
    const rt = try zjs.Runtime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try zjs.Context.create(rt, .{});
    defer ctx.destroy();
    const nursery_enabled = rt.gc.nursery.enabled;
    defer rt.gc.nursery.enabled = nursery_enabled;
    rt.gc.nursery.enabled = true;
    const stress = zjs.core.gc.forensics.stress_cadence;
    defer zjs.core.gc.forensics.stress_cadence = stress;
    zjs.core.gc.forensics.stress_cadence = 2;

    const H = struct {
        var context: *zjs.Context = undefined;
        var callee: zjs.JSValueHandle = undefined;
        var reentries: usize = 0;
        fn interrupt(rt_: *zjs.Runtime, _: ?*anyopaque) bool {
            _ = context.callFunction(callee.get(), &.{}, .{}) catch context.clearException();
            _ = rt_.forceGC(null) catch {};
            reentries += 1;
            return false;
        }
    };
    H.context = ctx;
    H.reentries = 0;
    H.callee = try rt.createPersistentValue(try ctx.eval("(function g() { return [1, 2]; })", .{}));
    defer H.callee.deinit();
    rt.setInterruptHandler(H.interrupt, null);
    defer rt.setInterruptHandler(null, null);

    _ = try ctx.eval(
        \\function f(o) { if (o.x !== o.y) throw new Error("argument"); return o.x; }
        \\let sum = 0;
        \\for (let i = 0; i < 300; i++) sum += f({ x: i, y: i });
        \\if (sum !== 44850) throw new Error("sum");
    , .{});
    try std.testing.expect(H.reentries > 0);
}

test "Context isArray walks a deep proxy chain without recursing" {
    const rt = try zjs.Runtime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try zjs.Context.create(rt, .{});
    defer ctx.destroy();
    const shallow = try ctx.eval("new Proxy(new Proxy([1, 2], {}), {})", .{});
    try std.testing.expect(try ctx.isArray(shallow));
    try std.testing.expectEqual(@as(u32, 2), try ctx.arrayLength(shallow));
    // Deeper than the cap: a clean error rather than one native frame per proxy.
    const deep = try ctx.eval("let p = []; for (let i = 0; i < 200000; i++) p = new Proxy(p, {}); p", .{});
    try std.testing.expectError(error.JSException, ctx.isArray(deep));
    ctx.clearException();
}

test "a host function that swallows a nested API failure still succeeds" {
    const rt = try zjs.Runtime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try zjs.Context.create(rt, .{});
    defer ctx.destroy();
    const Host = struct {
        fn swallow(call: *zjs.Call) anyerror!zjs.Value {
            _ = call.ctx.eval("throw new SyntaxError('stale')", .{}) catch {};
            return zjs.Value.int32(5);
        }
        fn fail(_: *zjs.Call) anyerror!zjs.Value {
            return error.RangeError;
        }
    };
    _ = try ctx.defineFunction("swallow", Host.swallow, .{});
    _ = try ctx.defineFunction("fail", Host.fail, .{});
    // The swallowed exception must neither trip the call-boundary invariant
    // nor replace the later host function's own error.
    const result = try ctx.eval("const r = swallow(); let e; try { fail(); } catch (x) { e = x.name; } r + ':' + e", .{});
    const text = try ctx.toOwnedUtf8(result, std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("5:RangeError", text);
}

test "Context.getIndex reads indices past the tagged-int range" {
    const rt = try zjs.Runtime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try zjs.Context.create(rt, .{});
    defer ctx.destroy();
    const array = try ctx.eval("var o = ['zero']; o[2147483648] = 'big'; o[4294967295] = 'max'; o", .{});
    for ([_]u32{ 2147483648, 4294967295 }, [_][]const u8{ "big", "max" }) |index, expected| {
        const text = try ctx.toOwnedUtf8(try ctx.getIndex(array, index), std.testing.allocator);
        defer std.testing.allocator.free(text);
        try std.testing.expectEqualStrings(expected, text);
    }
}

test "weak callbacks that register finalizers keep an outer reservation" {
    // createFunction(finalize) reserves its registration, then allocates; a
    // limit collection there runs a weak callback that registers enough
    // finalized functions to use up the spare capacity.
    const rt = try zjs.Runtime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try zjs.Context.create(rt, .{});
    defer ctx.destroy();
    const Host = struct {
        var context: ?*zjs.Context = null;
        var armed = false;
        var fired: usize = 0;
        var dummy: u8 = 0;
        fn finalize(_: *anyopaque) void {}
        fn call(_: *zjs.Call) zjs.Value {
            return zjs.Value.int32(1);
        }
        fn weak(runtime: *zjs.Runtime, _: ?*anyopaque) void {
            const c = context orelse return;
            if (!armed) return;
            armed = false;
            fired += 1;
            const saved = runtime.memoryLimit();
            runtime.setMemoryLimit(null);
            defer runtime.setMemoryLimit(saved);
            const finalizers = &runtime.native_bindings.finalizers;
            var spare = @max(@min(finalizers.capacity - finalizers.items.len, 64), 1);
            while (spare > 0) : (spare -= 1) {
                _ = c.createFunction("inner", call, .{ .state = @ptrCast(&dummy), .finalize = finalize }) catch {
                    c.clearException();
                    return;
                };
            }
        }
    };
    Host.context = ctx;
    defer Host.context = null;
    var weaks: [64]zjs.WeakPersistentValue = undefined;
    var made: usize = 0;
    defer for (weaks[0..made]) |*w| w.deinit();
    while (made < weaks.len) : (made += 1) {
        weaks[made] = try rt.createWeakPersistentValue(try ctx.eval("({ tmp: new Array(256).fill(0) })", .{}), Host.weak, null);
        rt.setMemoryLimit(rt.memoryUsage().heap_bytes + 1);
        Host.armed = true;
        const created = ctx.createFunction("outer", Host.call, .{ .state = @ptrCast(&Host.dummy), .finalize = Host.finalize, .with_prototype = true });
        Host.armed = false;
        rt.setMemoryLimit(null);
        _ = created catch ctx.clearException();
    }
    try std.testing.expect(Host.fired > 0);
    try std.testing.expectEqual(@as(usize, 0), rt.native_bindings.reserved_finalizers);
}

test "Context type errors carry a message" {
    const rt = try zjs.Runtime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try zjs.Context.create(rt, .{});
    defer ctx.destroy();
    const revoked = try ctx.eval("var r = Proxy.revocable([], {}); r.revoke(); r.proxy", .{});
    const plain = try ctx.eval("({})", .{});
    const H = struct {
        fn expectMessage(c: *zjs.Context, result: zjs.Context.Error!void, message: []const u8) !void {
            try std.testing.expectError(error.JSException, result);
            const text = try c.toOwnedUtf8(c.takeException(), std.testing.allocator);
            defer std.testing.allocator.free(text);
            try std.testing.expectEqualStrings(message, text);
        }
    };
    try H.expectMessage(ctx, if (ctx.isArray(revoked)) |_| {} else |err| err, "TypeError: revoked proxy");
    try H.expectMessage(ctx, if (ctx.arrayLength(plain)) |_| {} else |err| err, "TypeError: not an array");
    try H.expectMessage(ctx, if (ctx.functionName(plain, std.testing.allocator)) |name| std.testing.allocator.free(name) else |err| err, "TypeError: not a function");
}

test "createError with a custom name is an ordinary Error" {
    const rt = try zjs.Runtime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try zjs.Context.create(rt, .{});
    defer ctx.destroy();
    // A name with no global constructor used to get a null prototype, so
    // `String(e)` threw in the script that caught it.
    const err = try ctx.createError("NotFoundError", "no such key", .{});
    try ctx.defineDataProperty(try ctx.globalObject(), "hostError", err, .{});
    const text = try ctx.toOwnedUtf8(try ctx.eval(
        \\(hostError instanceof Error) + " " + String(hostError) + " " + hostError.name
    , .{}), std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("true NotFoundError: no such key NotFoundError", text);
}

test "host function constructibility is fixed when the function is created" {
    const rt = try zjs.Runtime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try zjs.Context.create(rt, .{});
    defer ctx.destroy();
    const Fns = struct {
        fn plain(_: *zjs.Call) zjs.Value {
            return zjs.Value.undefinedValue();
        }
    };
    _ = try ctx.defineFunction("plainHost", Fns.plain, .{});
    _ = try ctx.defineFunction("ctorHost", Fns.plain, .{ .with_prototype = true });
    const result = try ctx.eval(
        \\var r = [];
        \\plainHost.prototype = {};
        \\try { new plainHost(); r.push("constructed"); } catch (e) { r.push(e.name); }
        \\try { Reflect.construct(function () {}, [], plainHost); r.push("constructed"); } catch (e) { r.push(e.name); }
        \\r.push(Object.getPrototypeOf(new ctorHost()) === ctorHost.prototype);
        \\ctorHost.prototype = 1;
        \\r.push(Object.getPrototypeOf(new ctorHost()) === Object.prototype);
        \\r.join(" ");
    , .{});
    const text = try ctx.toOwnedUtf8(result, std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("TypeError TypeError true true", text);
}

test "callFunction drops the cached lean frame when its callee is unpinned" {
    // The one-shot lean frame is keyed on bare addresses (callee, bytecode,
    // captures). Once a different callee replaced the pinned one, the old
    // callee may be collected and a new function allocated at the same
    // addresses would reuse a carve sized for the old frame.
    const rt = try zjs.Runtime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try zjs.Context.create(rt, .{});
    defer ctx.destroy();

    var f = try rt.createPersistentValue(try ctx.eval("(function (a) { return a; })", .{}));
    _ = try ctx.callFunction(f.get(), &.{zjs.Value.int32(7)}, .{});
    const abs = try ctx.eval("Math.abs", .{});
    _ = try ctx.callFunction(abs, &.{zjs.Value.int32(-1)}, .{});
    const invocation: *zjs.exec.call_site.HostInvocation = @ptrCast(@alignCast(rt.host_invocation.?.ptr));
    try std.testing.expect(!invocation.lean_valid);
    f.deinit();
    _ = rt.collectForTest();
    _ = rt.collectForTest();

    const g = try ctx.eval("(function (a) { return a * (a + (a * (a + 1))); })", .{});
    const result = try ctx.callFunction(g, &.{ zjs.Value.int32(2), zjs.Value.int32(5), zjs.Value.int32(9) }, .{});
    try std.testing.expectEqual(@as(?i32, 2 * (2 + (2 * 3))), result.as(.int));
}

test "API conversions called from a host function keep the invocation's output" {
    // User code run by ctx.toString / getProperty / toNumber inside a host
    // function prints through the writer the host invocation was given.
    const rt = try zjs.Runtime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try zjs.Context.create(rt, .{});
    defer ctx.destroy();

    const Host = struct {
        fn write(call: *zjs.Call) !zjs.Value {
            const bytes = try call.ctx.toOwnedUtf8(call.arg(0), call.runtime().nativeAllocator());
            defer call.runtime().nativeAllocator().free(bytes);
            if (call.output()) |writer| try writer.print("{s}\n", .{bytes});
            return zjs.Value.undefinedValue();
        }
        fn probe(call: *zjs.Call) !zjs.Value {
            _ = try call.ctx.getProperty(call.arg(0), "p");
            _ = try call.ctx.toNumber(call.arg(0));
            return zjs.Value.undefinedValue();
        }
    };
    _ = try ctx.defineFunction("write", Host.write, .{ .length = 1 });
    _ = try ctx.defineFunction("probe", Host.probe, .{ .length = 1 });

    var buffer: [128]u8 = undefined;
    var output = std.Io.Writer.fixed(&buffer);
    _ = try ctx.eval(
        \\write({ toString() { write("in-toString"); return "x"; } });
        \\probe({ get p() { write("in-get"); return 1; }, valueOf() { write("in-valueOf"); return 2; } });
    , .{ .output = &output });
    try std.testing.expectEqualStrings("in-toString\nx\nin-get\nin-valueOf\n", output.buffered());
}

test "API validation errors are not masked by a stale exception and carry messages" {
    const rt = try zjs.Runtime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try zjs.Context.create(rt, .{});
    defer ctx.destroy();

    // A leftover uncaught exception from an earlier eval.
    try std.testing.expectError(error.JSException, ctx.eval("throw new SyntaxError('stale')", .{}));
    try std.testing.expectError(error.JSException, ctx.functionName(try ctx.eval("({})", .{}), std.testing.allocator));
    const name = try ctx.formatException(ctx.takeException(), std.testing.allocator);
    defer std.testing.allocator.free(name);
    try std.testing.expect(std.mem.startsWith(u8, name, "TypeError"));

    try std.testing.expectError(error.JSException, ctx.toNumber(try ctx.eval("10n", .{})));
    const message = try ctx.formatException(ctx.takeException(), std.testing.allocator);
    defer std.testing.allocator.free(message);
    try std.testing.expectEqualStrings("TypeError: cannot convert bigint to number", message);
}

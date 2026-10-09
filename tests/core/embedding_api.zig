//! Core integration tests: embedding_api.
const std = @import("std");
const zjs = @import("zjs");
const engine = zjs;
const core = zjs.core;
const helpers = @import("../harness.zig");
const common = @import("common.zig");
const BytesStoreState = common.BytesStoreState;

// --- engine production ---

const public_zjs = zjs;

const HostFunctionState = struct {
    value: i32,

    fn call(c: *zjs.native.Call) zjs.JSValue {
        return zjs.JSValue.int32(c.state(HostFunctionState).value);
    }
};

test "production public API contract exposes Zig-native embedding spellings" {
    try std.testing.expect(@hasDecl(public_zjs, "Runtime"));
    try std.testing.expect(@hasDecl(public_zjs, "Context"));
    try std.testing.expect(@hasDecl(public_zjs, "Value"));
    try std.testing.expect(@hasDecl(public_zjs, "Call"));
    try std.testing.expect(!@hasDecl(public_zjs, "EventLoop"));
    try std.testing.expect(@hasDecl(public_zjs.Context, "defineScriptArgs"));
    try std.testing.expect(public_zjs.Runtime == public_zjs.JSRuntime);
    try std.testing.expect(public_zjs.Context == public_zjs.JSContext);
    try std.testing.expect(public_zjs.Value == public_zjs.JSValue);
    try std.testing.expect(!@hasDecl(public_zjs.Value, "Scope"));
    try std.testing.expect(!@hasDecl(public_zjs.Value, "Local"));
    try std.testing.expect(!@hasDecl(public_zjs.Value, "Persistent"));
    try std.testing.expect(!@hasDecl(public_zjs.Value, "Weak"));
    try std.testing.expect(!@hasDecl(public_zjs, "host"));
    try std.testing.expect(!@hasDecl(public_zjs, "context"));
    try std.testing.expect(!@hasDecl(public_zjs, "value"));
    try std.testing.expect(!@hasDecl(public_zjs, "object"));
    try std.testing.expect(!@hasDecl(public_zjs, "module"));
    try std.testing.expect(!@hasDecl(public_zjs, "job"));
    try std.testing.expect(!@hasDecl(public_zjs, "internal"));
    try std.testing.expect(!@hasDecl(public_zjs, "kernel"));
    try std.testing.expect(!@hasDecl(public_zjs, "public_api"));
    try std.testing.expect(!@hasDecl(public_zjs, "CallSite"));
    try std.testing.expect(!@hasDecl(public_zjs, "PropertySite"));
    try std.testing.expect(!@hasDecl(public_zjs, "PropNameID"));
    try std.testing.expect(!@hasDecl(public_zjs, "binding"));
    try std.testing.expect(!@hasDecl(public_zjs, "binding_root"));
    try std.testing.expect(!@hasDecl(public_zjs, "js_context"));
}

test "production embedding can own JSRuntime and JSContext directly" {
    const rt = try zjs.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    var ctx: zjs.JSContext = undefined;
    try ctx.init(rt, .{});
    defer ctx.deinit();

    const value = try ctx.eval("1 + 1", .{});
    try std.testing.expectEqual(@as(?i32, 2), value.as(.int));

    const object = try ctx.eval("({ answer: 42 })", .{});
    try std.testing.expect(object.is(.object));

    const global = try zjs.globalObjectPtr(&ctx);
    try std.testing.expect(global.isGlobal());
}

test "production embedding API applies limits and releases eval handles" {
    const rt = try zjs.JSRuntime.create(std.testing.allocator, .{
        .stack_size = 128 * 1024,
        .gc_threshold = 32 * 1024,
    });
    defer rt.destroy();

    try std.testing.expectEqual(@as(usize, 32 * 1024), rt.gcThreshold());
    const ctx = try zjs.JSContext.create(rt, .{});
    defer ctx.destroy();

    try std.testing.expectEqual(@as(usize, 128 * 1024), rt.stackSize());
    // Bootstrap keeps the collector-adjusted dynamic threshold.
    try std.testing.expect(rt.gcThreshold() > 32 * 1024);
    try std.testing.expect(rt.gcThreshold() >= rt.gc.heap_budget.bytes);

    const result = try ctx.eval("1 + 2;", .{});
    try std.testing.expectEqual(@as(?i32, 3), result.as(.int));
}

test "production embedding can configure context policy through public methods" {
    const rt = try zjs.JSRuntime.create(std.testing.allocator, .{
        .stack_size = 96 * 1024,
    });
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt, .{
        .track_unhandled_rejections = false,
    });
    defer ctx.destroy();

    try std.testing.expectEqual(@as(usize, 96 * 1024), ctx.stackLimit());
    ctx.setStackLimit(64 * 1024);
    try std.testing.expectEqual(@as(usize, 64 * 1024), ctx.stackLimit());

    try std.testing.expect(!ctx.tracksUnhandledRejections());
    ctx.setTrackUnhandledRejections(true);
    try std.testing.expect(ctx.tracksUnhandledRejections());

    try std.testing.expect(!ctx.preservesUncaughtException());
    ctx.setPreserveUncaughtException(true);
    try std.testing.expect(ctx.preservesUncaughtException());
}

test "production engine does not install bundled output or OS capabilities" {
    const rt = try zjs.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt, .{});
    defer ctx.destroy();

    const result = try ctx.eval(
        \\typeof print === 'undefined' && typeof console === 'undefined' &&
        \\typeof std === 'undefined' && typeof os === 'undefined' &&
        \\typeof setTimeout === 'undefined' && typeof btoa === 'undefined' &&
        \\typeof atob === 'undefined' && typeof queueMicrotask === 'undefined' &&
        \\typeof gc === 'undefined'
    , .{});
    try std.testing.expectEqual(@as(?bool, true), result.as(.boolean));
    try std.testing.expect(ctx.core.hostScheduler() == null);
    try std.testing.expect(ctx.core.module_source_loader == null);
    _ = try ctx.eval(
        \\if ('url' in import.meta || 'main' in import.meta) throw new Error('host metadata leaked');
    , .{ .mode = .module, .filename = "memory:engine-only" });
    _ = try ctx.eval("Promise.resolve().then(() => { globalThis.engineJobRan = true; });", .{});
    try ctx.runJobs(null);
    try std.testing.expectEqual(@as(?bool, true), (try ctx.eval("engineJobRan", .{})).as(.boolean));
}

test "installed event loop keeps a released realm and its timer callbacks alive" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt, .{});
    var loop = @import("zjs_host").EventLoop.initCore(ctx, .{});
    loop.install();
    const callback = callback: {
        var roots = core.runtime.ExactValueRoots(1){};
        try roots.activate(rt);
        defer roots.deactivate();
        const root = try roots.ref(0);
        _ = try engine.exec.zjs_vm.contextGlobal(ctx);
        try root.set(rt, try core.function.nativeFunction(ctx, "timerCallback", 0));
        break :callback try root.get(rt);
    };
    try loop.enqueueTimer(ctx, 1, callback, 0);
    const callback_header = callback.cycleMarkHeader().?;
    // The host drops its context reference while the loop is installed.
    ctx.destroy();
    _ = try rt.collectForTest();
    try std.testing.expect(rt.gc.containsHeader(&ctx.header));
    try std.testing.expect(rt.gc.containsHeader(callback_header));
    // Clearing the scheduler releases both.
    loop.deinit();
    _ = try rt.collectForTest();
    try std.testing.expect(!rt.gc.containsHeader(callback_header));
}

test "production event loop does not add product runtime globals" {
    const rt = try zjs.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt, .{});
    defer ctx.destroy();

    var output_buffer: [160]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    var event_loop = @import("zjs_host").EventLoop.init(ctx, .{ .output = &output });
    event_loop.install();
    defer event_loop.deinit();
    try @import("zjs_host").output.install(ctx.core, try zjs.globalObjectPtr(ctx));

    const result = try ctx.eval(
        \\print(1);
        \\console.log(2);
        \\print(typeof std, typeof os, typeof setTimeout, typeof setInterval, typeof clearTimeout, typeof clearInterval);
    , .{ .output = &output });

    try std.testing.expect(result.is(.undefined_value));
    try std.testing.expectEqualStrings(
        "1\n2\nundefined undefined undefined undefined undefined undefined\n",
        output.buffered(),
    );
}

test "host print quotes property names longer than its stack buffer" {
    const rt = try zjs.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt, .{});
    defer ctx.destroy();

    var output_buffer: [2048]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    try @import("zjs_host").output.install(ctx.core, try zjs.globalObjectPtr(ctx));

    _ = try ctx.eval(
        \\print({ ['-'.repeat(300)]: 1 });
        \\print({ ['é'.repeat(300)]: 2 });
    , .{ .output = &output });

    const expected = "{ \"" ++ "-" ** 300 ++ "\": 1 }\n" ++ "{ \"" ++ "\u{e9}" ** 300 ++ "\": 2 }\n";
    try std.testing.expectEqualStrings(expected, output.buffered());
}

test "production embedding can install external host functions" {
    const rt = try zjs.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt, .{});
    defer ctx.destroy();

    var state = HostFunctionState{ .value = 42 };
    _ = try ctx.defineFunction("hostValue", zjs.native.managed(HostFunctionState.call), .{ .state = @ptrCast(&state) });

    const result = try ctx.eval("hostValue()", .{});
    try std.testing.expectEqual(@as(?i32, 42), result.as(.int));
}

test "production embedding can create external host function values" {
    const rt = try zjs.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt, .{});
    defer ctx.destroy();

    var state = HostFunctionState{ .value = 7 };
    const function = try ctx.createFunction("HostCtor", zjs.native.managed(HostFunctionState.call), .{ .state = @ptrCast(&state), .with_prototype = true });
    try std.testing.expect(function.is(.object));
    try std.testing.expect(ctx.isCallable(function));
    try std.testing.expect(ctx.isConstructor(function));

    const name = try ctx.functionName(function, std.testing.allocator);
    defer std.testing.allocator.free(name);
    try std.testing.expectEqualStrings("HostCtor", name);

    const prototype = try ctx.getProperty(function, "prototype");
    try std.testing.expect(prototype.is(.object));

    const global = try ctx.globalObject();
    try ctx.defineDataProperty(global, "HostCtor", function, .{});
    const surface = try ctx.eval(
        \\var prototypeDescriptor = Object.getOwnPropertyDescriptor(HostCtor, "prototype");
        \\var constructorDescriptor = Object.getOwnPropertyDescriptor(HostCtor.prototype, "constructor");
        \\if (Object.getPrototypeOf(HostCtor) !== Function.prototype ||
        \\    Object.getPrototypeOf(HostCtor.prototype) !== Object.prototype ||
        \\    prototypeDescriptor.writable !== true ||
        \\    prototypeDescriptor.enumerable !== false ||
        \\    prototypeDescriptor.configurable !== false ||
        \\    constructorDescriptor.value !== HostCtor ||
        \\    constructorDescriptor.writable !== true ||
        \\    constructorDescriptor.enumerable !== false ||
        \\    constructorDescriptor.configurable !== true) {
        \\    throw new Error("invalid external constructor surface");
        \\}
    , .{});
    try std.testing.expect(surface.is(.undefined_value));
}

test "production embedding can create objects and define data properties" {
    const rt = try zjs.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt, .{});
    defer ctx.destroy();

    const object = try ctx.createObject();
    try ctx.defineDataProperty(object, "answer", zjs.JSValue.int32(42), .{});

    const answer = try ctx.getProperty(object, "answer");
    try std.testing.expectEqual(@as(?i32, 42), answer.as(.int));
}

test "production embedding objects and buffers get their realm prototypes" {
    const rt = try zjs.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt, .{});
    defer ctx.destroy();

    var state = BytesStoreState{ .allocator = std.testing.allocator };
    const owned_backing = try std.testing.allocator.alloc(u8, 2);
    var owned_store = zjs.JSBytes.Store.owned(owned_backing, .{ .deinit = BytesStoreState.deinit, .context = &state });
    errdefer owned_store.release();
    const shared_backing = try std.testing.allocator.alloc(u8, 2);
    var shared_store = zjs.JSBytes.Store.shared(shared_backing, .{ .deinit = BytesStoreState.deinit, .context = &state });
    errdefer shared_store.release();

    const global = try ctx.globalObject();
    try ctx.defineDataProperty(global, "hostObject", try ctx.createObject(), .{});
    try ctx.defineDataProperty(global, "hostBuffer", try ctx.arrayBuffer(&owned_store), .{});
    const shared = try ctx.arrayBuffer(&shared_store);
    try ctx.defineDataProperty(global, "hostShared", shared, .{});
    var shared_ref = try ctx.retainSharedArrayBuffer(shared);
    defer shared_ref.release();
    try ctx.defineDataProperty(global, "hostRewrapped", try ctx.sharedArrayBufferFromRef(shared_ref), .{});

    const result = try ctx.eval(
        \\Object.getPrototypeOf(hostObject) === Object.prototype &&
        \\  String(hostObject) === "[object Object]" &&
        \\  hostBuffer instanceof ArrayBuffer && hostBuffer.byteLength === 2 &&
        \\  hostShared instanceof SharedArrayBuffer &&
        \\  hostRewrapped instanceof SharedArrayBuffer && hostRewrapped.byteLength === 2
    , .{});
    try std.testing.expectEqual(@as(?bool, true), result.as(.boolean));
}

test "production embedding can inspect own property descriptors by JS key" {
    const rt = try zjs.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt, .{});
    defer ctx.destroy();

    const envelope = try ctx.eval(
        \\(() => {
        \\  const key = Symbol("embedded");
        \\  const object = {};
        \\  Object.defineProperty(object, key, {
        \\    value: 17,
        \\    writable: false,
        \\    enumerable: false,
        \\    configurable: true,
        \\  });
        \\  return { object, key };
        \\})()
    , .{});

    const object = try ctx.getProperty(envelope, "object");
    const key = try ctx.getProperty(envelope, "key");

    try std.testing.expect(try ctx.hasOwnPropertyKey(object, key, .{}));
    var desc = (try ctx.ownPropertyDescriptor(object, key, .{})) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(core.PropertyDescriptor.data(zjs.JSValue.int32(17), .{ .configurable = true }).kind, desc.kind);
    try std.testing.expectEqual(@as(?i32, 17), desc.value.as(.int));
    try std.testing.expectEqual(false, desc.writable.?);
    try std.testing.expectEqual(false, desc.enumerable.?);
    try std.testing.expectEqual(true, desc.configurable.?);

    const read_value = try ctx.getPropertyKey(object, key, .{});
    try std.testing.expectEqual(@as(?i32, 17), read_value.as(.int));

    const inherited = try ctx.eval("Object.create({ inherited: 1 })", .{});
    try std.testing.expect(!try ctx.hasOwnProperty(inherited, "inherited"));
    try ctx.defineDataProperty(inherited, "owned", zjs.JSValue.int32(1), .{});
    try std.testing.expect(try ctx.hasOwnProperty(inherited, "owned"));
    try std.testing.expect(try ctx.deleteProperty(inherited, "owned"));
    try std.testing.expect(!try ctx.hasOwnProperty(inherited, "owned"));

    const proxy = try ctx.eval("new Proxy({ visible: 99 }, {})", .{});
    const visible_key = try ctx.createString("visible");
    var proxy_desc = (try ctx.ownPropertyDescriptor(proxy, visible_key, .{})) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(?i32, 99), proxy_desc.value.as(.int));

    const revoked = try ctx.eval("const r = Proxy.revocable({ visible: 1 }, {}); r.revoke(); r.proxy", .{});
    try std.testing.expectError(error.JSException, ctx.ownPropertyDescriptor(revoked, visible_key, .{}));
    try std.testing.expect(try ctx.consumePendingExceptionIfErrorName("TypeError"));
}

test "production embedding can create strings and convert values to owned utf8" {
    const rt = try zjs.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt, .{});
    defer ctx.destroy();

    const direct = try ctx.createString("caf\xc3\xa9");
    const direct_text = try direct.asString().?.toOwnedUtf8(std.testing.allocator);
    defer std.testing.allocator.free(direct_text);
    try std.testing.expectEqualStrings("caf\xc3\xa9", direct_text);

    const object = try ctx.eval("({ toString() { return 'semantic-\\u00e9'; } })", .{});
    const semantic_text = try ctx.toOwnedUtf8(object, std.testing.allocator);
    defer std.testing.allocator.free(semantic_text);
    try std.testing.expectEqualStrings("semantic-\xc3\xa9", semantic_text);
}

test "production embedding can convert values to numbers" {
    const rt = try zjs.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt, .{});
    defer ctx.destroy();

    try std.testing.expectEqual(@as(?f64, 42), zjs.JSValue.number(42.0).asNumber());
    try std.testing.expect(zjs.JSValue.number(-0.0).as(.float64).? == 0);

    const numeric_object = try ctx.eval("({ valueOf() { return 12.75; } })", .{});
    try std.testing.expectEqual(@as(f64, 12.75), try ctx.toNumber(numeric_object));
    try std.testing.expectEqual(@as(f64, 12), try ctx.toIntegerOrInfinity(numeric_object));

    const non_numeric = try ctx.eval("({ toString() { return 'not-a-number'; } })", .{});
    try std.testing.expect(std.math.isNan(try ctx.toNumber(non_numeric)));
}

test "production embedding can inspect callable and constructor values" {
    const rt = try zjs.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt, .{});
    defer ctx.destroy();

    const function = try ctx.eval("(function NamedForEmbedding() {})", .{});
    try std.testing.expect(ctx.isCallable(function));
    try std.testing.expect(ctx.isConstructor(function));

    const name = try ctx.functionName(function, std.testing.allocator);
    defer std.testing.allocator.free(name);
    try std.testing.expectEqualStrings("NamedForEmbedding", name);

    const arrow = try ctx.eval("(() => {})", .{});
    try std.testing.expect(ctx.isCallable(arrow));
    try std.testing.expect(!ctx.isConstructor(arrow));

    try std.testing.expect(!ctx.isCallable(zjs.JSValue.int32(1)));
    try std.testing.expect(!ctx.isConstructor(zjs.JSValue.int32(1)));
}

test "production embedding can call JavaScript functions" {
    const rt = try zjs.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt, .{});
    defer ctx.destroy();

    const function = try ctx.eval("(function addToBase(a, b) { return this.base + a + b; })", .{});

    const receiver = try ctx.createObject();
    try ctx.defineDataProperty(receiver, "base", zjs.JSValue.int32(10), .{});

    const result = try ctx.callFunction(function, &.{ zjs.JSValue.int32(2), zjs.JSValue.int32(3) }, .{
        .this_value = receiver,
    });
    try std.testing.expectEqual(@as(?i32, 15), result.as(.int));

    const throwing = try ctx.eval("(function fail() { throw new TypeError('call failed'); })", .{});
    try std.testing.expectError(error.JSException, ctx.callFunction(throwing, &.{}, .{}));
    try std.testing.expect(ctx.hasException());
    const exception = ctx.takePendingException();
    try std.testing.expect(exception.is(.object));
}

test "production embedding can compare values with SameValue semantics" {
    const rt = try zjs.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt, .{});
    defer ctx.destroy();

    try std.testing.expect(zjs.JSValue.float64(std.math.nan(f64)).sameValue(zjs.JSValue.float64(std.math.nan(f64))));
    try std.testing.expect(!zjs.JSValue.float64(0.0).sameValue(zjs.JSValue.float64(-0.0)));
    try std.testing.expect(zjs.JSValue.shortBigInt(7).sameValue(zjs.JSValue.shortBigInt(7)));

    const lhs = try ctx.eval("'same-value-string'", .{});
    const rhs = try ctx.eval("'same-' + 'value-string'", .{});
    try std.testing.expect(lhs.sameValue(rhs));
}

test "production embedding can inspect arrays and indexed values" {
    const rt = try zjs.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt, .{});
    defer ctx.destroy();

    const array = try ctx.eval("[1, 2, 3]", .{});
    try std.testing.expect(try ctx.isArray(array));
    try std.testing.expectEqual(@as(u32, 3), try ctx.arrayLength(array));

    const second = try ctx.getIndex(array, 1);
    try std.testing.expectEqual(@as(?i32, 2), second.as(.int));

    const proxy = try ctx.eval("new Proxy([4], {})", .{});
    try std.testing.expect(try ctx.isArray(proxy));
    try std.testing.expectEqual(@as(u32, 1), try ctx.arrayLength(proxy));

    const object = try ctx.eval("({ length: 1, 0: 9 })", .{});
    try std.testing.expect(!try ctx.isArray(object));
    try std.testing.expectError(error.JSException, ctx.arrayLength(object));
    try std.testing.expect(try ctx.consumePendingExceptionIfErrorName("TypeError"));

    const revoked = try ctx.eval("const r = Proxy.revocable([], {}); r.revoke(); r.proxy", .{});
    try std.testing.expectError(error.JSException, ctx.isArray(revoked));
    try std.testing.expect(try ctx.consumePendingExceptionIfErrorName("TypeError"));
}

test "ordinary runtime stats do not walk the heap" {
    const rt = try zjs.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try zjs.JSContext.create(rt, .{});
    defer ctx.destroy();
    const object = try ctx.eval("({})", .{});
    try std.testing.expect(object.is(.object));
    const walks_before = core.gc.heap_walks_for_test;
    const usage = rt.memoryUsage();
    const stats = rt.gcStats();
    try std.testing.expectEqual(walks_before, core.gc.heap_walks_for_test);
    try std.testing.expect(usage.allocated_bytes > 0);
    try std.testing.expectEqual(usage.peak_allocated_bytes, stats.peak_allocated_bytes);
    try std.testing.expectEqual(@as(usize, 0), stats.external_bytes);
    const detailed = rt.gcDetailedStats();
    try std.testing.expect(core.gc.heap_walks_for_test > walks_before);
    try std.testing.expect(detailed.heap_live_bytes > 0);
    try std.testing.expectEqual(stats.external_bytes, detailed.counters.external_bytes);
    try std.testing.expectEqual(stats.peak_allocated_bytes, detailed.counters.peak_allocated_bytes);
}

test "runtime allocation profiling survives profile replacement and detach" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    var first: core.OpcodeProfile = .{};
    var second: core.OpcodeProfile = .{};
    rt.opcode_profile = &first;
    const mem = try rt.allocNative(u8, 24);
    rt.freeNative(u8, mem);
    try std.testing.expectEqual(@as(u64, 1), first.alloc_count);

    rt.opcode_profile = &second;
    const next = try rt.allocNative(u8, 32);
    rt.freeNative(u8, next);
    try std.testing.expectEqual(@as(u64, 1), first.alloc_count);
    try std.testing.expectEqual(@as(u64, 1), second.alloc_count);

    rt.opcode_profile = null;
    const detached = try rt.allocNative(u8, 8);
    rt.freeNative(u8, detached);
    try std.testing.expectEqual(@as(u64, 1), second.alloc_count);
}

test "production embedding can inspect runtime memory usage without internal modules" {
    const rt = try zjs.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const usage: zjs.RuntimeMemoryUsage = rt.memoryUsage();
    try std.testing.expect(usage.allocated_bytes > 0);
    try std.testing.expect(usage.allocation_count > 0);
    try std.testing.expect(usage.atom_count > 0);
}

test "production embedding roots host-held values with public handles" {
    const rt = try zjs.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt, .{});
    defer ctx.destroy();

    const object = try ctx.eval("({ answer: 42 })", .{});

    var scope = rt.enterHandleScope();
    const local = try scope.local(object);

    try std.testing.expectEqual(@as(usize, 1), rt.roots.local_root_slots.items.len);
    try std.testing.expectEqual(@as(usize, 0), rt.roots.persistent_root_slots.items.len);
    try std.testing.expect(local.get().is(.object));

    var persistent = try rt.createPersistentValue(local.get());
    defer persistent.deinit();

    scope.deinit();
    try std.testing.expectEqual(@as(usize, 0), rt.roots.local_root_slots.items.len);
    try std.testing.expectEqual(@as(usize, 1), rt.roots.persistent_root_slots.items.len);

    const answer = try ctx.getProperty(persistent.get(), "answer");
    try std.testing.expectEqual(@as(?i32, 42), answer.as(.int));

    persistent.deinit();
    try std.testing.expectEqual(@as(usize, 0), rt.roots.persistent_root_slots.items.len);
}

test "production embedding can expose owned and shared byte stores" {
    const rt = try zjs.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt, .{});
    defer ctx.destroy();

    var owned_state = BytesStoreState{ .allocator = std.testing.allocator };
    const owned_backing = try std.testing.allocator.alloc(u8, 4);
    @memcpy(owned_backing, &[_]u8{ 1, 2, 3, 4 });
    var owned_store = zjs.JSBytes.Store.owned(owned_backing, .{
        .deinit = BytesStoreState.deinit,
        .context = &owned_state,
    });
    errdefer owned_store.release();

    const owned_value = try ctx.arrayBuffer(&owned_store);
    try std.testing.expectEqual(@as(usize, 0), owned_store.bytes.len);
    try std.testing.expectEqual(@as(usize, 4), rt.gcStats().external_bytes);
    try std.testing.expectEqual(@as(usize, 4), rt.gcStats().external_token_bytes);
    try std.testing.expectEqual(@as(usize, 1), rt.gcStats().external_token_count);

    const owned_view: zjs.JSBytes = try owned_value.asBytes();
    try std.testing.expect(!owned_view.isShared());
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, owned_view.slice());
    const owned_mut = try owned_view.sliceMut();
    owned_mut[1] = 9;
    try std.testing.expectEqualSlices(u8, &.{ 1, 9, 3, 4 }, owned_view.slice());
    try std.testing.expectEqual(@as(usize, 0), owned_state.calls);

    // Dropping the embedder's last reference is what ends the buffer's life
    // under refcounting; under the tracer it is what makes it collectable, and
    // the store's `deinit` runs when the collection reaches it. This is an
    // API-visible timing change for embedders that attach OS resources to a
    // byte store.
    helpers.reclaimNow(rt);
    try std.testing.expectEqual(@as(usize, 1), owned_state.calls);
    try std.testing.expectEqual(@as(usize, 0), rt.gcStats().external_bytes);
    try std.testing.expectEqual(@as(usize, 0), rt.gcStats().external_token_count);

    var shared_state = BytesStoreState{ .allocator = std.testing.allocator };
    const shared_backing = try std.testing.allocator.alloc(u8, 3);
    @memcpy(shared_backing, &[_]u8{ 8, 9, 10 });
    var shared_store = zjs.JSBytes.Store.shared(shared_backing, .{
        .deinit = BytesStoreState.deinit,
        .context = &shared_state,
    });
    errdefer shared_store.release();

    const shared_value = try ctx.arrayBuffer(&shared_store);
    try std.testing.expectEqual(@as(usize, 0), shared_store.bytes.len);
    try std.testing.expectEqual(@as(usize, 3), rt.gcStats().external_bytes);
    try std.testing.expectEqual(@as(usize, 3), rt.gcStats().external_token_bytes);
    try std.testing.expectEqual(@as(usize, 1), rt.gcStats().external_token_count);

    const shared_view: zjs.JSBytes = try shared_value.asBytes();
    try std.testing.expect(shared_view.isShared());
    try std.testing.expectEqualSlices(u8, &.{ 8, 9, 10 }, shared_view.slice());
    const shared_mut = try shared_view.sliceMut();
    shared_mut[0] = 12;
    try std.testing.expectEqualSlices(u8, &.{ 12, 9, 10 }, shared_view.slice());
    try std.testing.expectEqual(@as(usize, 0), shared_state.calls);

    helpers.reclaimNow(rt);
    try std.testing.expectEqual(@as(usize, 1), shared_state.calls);
    try std.testing.expectEqual(@as(usize, 0), rt.gcStats().external_bytes);
    try std.testing.expectEqual(@as(usize, 0), rt.gcStats().external_token_count);
}

test "production runtime can detach array buffers" {
    const rt = try zjs.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt, .{});
    defer ctx.destroy();

    var owned_state = BytesStoreState{ .allocator = std.testing.allocator };
    const owned_backing = try std.testing.allocator.alloc(u8, 2);
    @memcpy(owned_backing, &[_]u8{ 3, 4 });
    var owned_store = zjs.JSBytes.Store.owned(owned_backing, .{
        .deinit = BytesStoreState.deinit,
        .context = &owned_state,
    });
    errdefer owned_store.release();

    const owned_value = try ctx.arrayBuffer(&owned_store);
    try std.testing.expectEqual(@as(usize, 0), owned_state.calls);

    const detached = try zjs.exec.buffer_ops.detachArrayBuffer(rt, owned_value);
    try std.testing.expect(detached.is(.undefined_value));
    try std.testing.expectEqual(@as(usize, 1), owned_state.calls);
    try std.testing.expectError(error.Detached, owned_value.asBytes());

    var shared_state = BytesStoreState{ .allocator = std.testing.allocator };
    const shared_backing = try std.testing.allocator.alloc(u8, 1);
    @memcpy(shared_backing, &[_]u8{5});
    var shared_store = zjs.JSBytes.Store.shared(shared_backing, .{
        .deinit = BytesStoreState.deinit,
        .context = &shared_state,
    });
    errdefer shared_store.release();

    const shared_value = try ctx.arrayBuffer(&shared_store);
    try std.testing.expectError(error.NotAnArrayBuffer, zjs.exec.buffer_ops.detachArrayBuffer(rt, shared_value));
    try std.testing.expectEqual(@as(usize, 0), shared_state.calls);
}

test "production embedding can retain and rewrap shared array buffers" {
    const rt = try zjs.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt, .{});
    defer ctx.destroy();

    var shared_state = BytesStoreState{ .allocator = std.testing.allocator };
    const shared_backing = try std.testing.allocator.alloc(u8, 3);
    @memcpy(shared_backing, &[_]u8{ 1, 2, 3 });
    var store = zjs.JSBytes.Store.shared(shared_backing, .{
        .deinit = BytesStoreState.deinit,
        .context = &shared_state,
    });
    errdefer store.release();

    const original = try ctx.arrayBuffer(&store);
    var shared_ref = try ctx.retainSharedArrayBuffer(original);
    defer shared_ref.release();

    const other_rt = try zjs.JSRuntime.create(std.testing.allocator, .{});
    defer other_rt.destroy();
    const other_ctx = try zjs.JSContext.create(other_rt, .{});
    defer other_ctx.destroy();

    const rewrapped = try other_ctx.sharedArrayBufferFromRef(shared_ref);
    const rewrapped_view = try rewrapped.asBytes();
    const rewrapped_mut = try rewrapped_view.sliceMut();
    rewrapped_mut[1] = 9;

    const original_view = try original.asBytes();
    try std.testing.expect(original_view.isShared());
    try std.testing.expectEqualSlices(u8, &.{ 1, 9, 3 }, original_view.slice());
    try std.testing.expectEqual(@as(usize, 0), shared_state.calls);

    try std.testing.expectError(error.JSException, ctx.retainSharedArrayBuffer(zjs.JSValue.int32(1)));
    try std.testing.expect(try ctx.consumePendingExceptionIfErrorName("TypeError"));
}

test "production embedding lifecycle deinitializes repeated script and module evals" {
    var index: usize = 0;
    while (index < 4) : (index += 1) {
        const rt = try zjs.JSRuntime.create(std.testing.allocator, .{});
        defer rt.destroy();

        const ctx = try zjs.JSContext.create(rt, .{});
        defer ctx.destroy();

        const script_result = try ctx.eval(
            \\let values = [];
            \\for (let i = 0; i < 8; i++) values.push({ i });
            \\values.map(v => v.i).join(",");
        , .{ .discard_script_result = true });
        try std.testing.expect(script_result.is(.undefined_value));

        _ = try ctx.eval(
            \\const value = await Promise.resolve(42);
            \\export { value };
        , .{ .mode = .module });
    }
}

test "production module import.meta identity survives methods and nested closures" {
    const rt = try zjs.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt, .{});
    defer ctx.destroy();

    _ = try ctx.eval(
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
    , .{ .mode = .module });
}

test "production embedding takeException captures exception snapshot without leaking" {
    const rt = try zjs.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt, .{});
    defer ctx.destroy();

    _ = ctx.eval("throw new Error('test exception snapshot');", .{}) catch |err| {
        try std.testing.expectEqual(error.JSException, err);
        const thrown = ctx.takePendingException();
        try std.testing.expect(thrown.is(.object));
    };
}

test "production embedding can create and throw named errors" {
    const rt = try zjs.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt, .{});
    defer ctx.destroy();

    const created = try ctx.createError("TypeError", "host-created", .{});
    const created_text = try ctx.formatException(created, std.testing.allocator);
    defer std.testing.allocator.free(created_text);
    try std.testing.expectEqualStrings("TypeError: host-created", created_text);

    const created_stack = try ctx.formatExceptionStack(created, std.testing.allocator);
    defer if (created_stack) |stack| std.testing.allocator.free(stack);
    try std.testing.expect(created_stack != null);

    try std.testing.expectError(error.JSException, ctx.throwError("RangeError", "host-thrown", .{}));
    try std.testing.expect(ctx.hasException());
    const thrown = ctx.takePendingException();

    const thrown_text = try ctx.formatException(thrown, std.testing.allocator);
    defer std.testing.allocator.free(thrown_text);
    try std.testing.expectEqualStrings("RangeError: host-thrown", thrown_text);
}

test "production embedding can match pending exceptions by error name" {
    const rt = try zjs.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt, .{});
    defer ctx.destroy();

    try std.testing.expect(!try ctx.pendingExceptionMatchesErrorName("TypeError"));
    try std.testing.expect(!try ctx.consumePendingExceptionIfErrorName("TypeError"));

    _ = ctx.eval("throw new TypeError('expected type');", .{}) catch |err| {
        try std.testing.expectEqual(error.JSException, err);
        try std.testing.expect(try ctx.pendingExceptionMatchesErrorName("TypeError"));
        try std.testing.expect(!try ctx.pendingExceptionMatchesErrorName("RangeError"));
        try std.testing.expect(try ctx.consumePendingExceptionIfErrorName("TypeError"));
        try std.testing.expect(!ctx.hasException());
    };

    try std.testing.expect(ctx.runtimeErrorMatchesErrorName(error.TypeError, "TypeError"));
    try std.testing.expect(ctx.runtimeErrorMatchesErrorName(error.NotExtensible, "TypeError"));
    try std.testing.expect(ctx.runtimeErrorMatchesErrorName(error.InvalidUtf8, "URIError"));
    try std.testing.expect(!ctx.runtimeErrorMatchesErrorName(error.RangeError, "TypeError"));
}

test "production embedding can create independent realms" {
    const rt = try zjs.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt, .{});
    defer ctx.destroy();

    const retained = blk: {
        const realm = try ctx.createRealm();

        const realm_global = try ctx.realmGlobal(realm);
        try std.testing.expect(realm_global.is(.object));

        const realm_global_object = try ctx.realmGlobalObject(realm);
        try std.testing.expect(realm_global_object.isGlobal());

        const realm_global_this = try ctx.getProperty(realm_global, "globalThis");
        try std.testing.expect(realm_global_this.sameValue(realm_global));

        const current_array = try ctx.eval("Array", .{});
        const realm_array = try ctx.getProperty(realm_global, "Array");
        try std.testing.expect(!realm_array.sameValue(current_array));

        break :blk .{ try ctx.runtimePtr().createPersistentValue(realm_global), realm_global_object };
    };

    var realm_global_handle = retained[0];
    defer realm_global_handle.deinit();
    const realm_global_object = retained[1];
    try std.testing.expect(rt.contextForGlobal(realm_global_object) != null);
    {
        const retained_global_this = try ctx.getProperty(realm_global_handle.get(), "globalThis");
        try std.testing.expect(retained_global_this.sameValue(realm_global_handle.get()));
    }

    realm_global_handle.deinit();
    _ = try rt.collectForTest();
    try std.testing.expect(rt.contextForGlobal(realm_global_object) == null);
}

test "production embedding can eval script source in explicit function realms" {
    const rt = try zjs.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt, .{});
    defer ctx.destroy();

    const realm = try ctx.createRealm();
    const realm_global = try ctx.realmGlobal(realm);
    const realm_global_object = try ctx.realmGlobalObject(realm);

    try ctx.defineDataProperty(realm_global, "realmMarker", zjs.JSValue.int32(40), .{});

    const source_result = try ctx.evalScriptSource("realmMarker + 2", .{
        .realm_global = realm_global_object,
        .filename = "embedding-realm-source.js",
    });
    try std.testing.expectEqual(@as(?i32, 42), source_result.as(.int));

    const source_value = try ctx.createString("realmMarker + 3");
    const value_result = try ctx.evalScriptValue(source_value, .{
        .realm_global = realm_global_object,
        .filename = "embedding-realm-value.js",
    });
    try std.testing.expectEqual(@as(?i32, 43), value_result.as(.int));

    var state = HostFunctionState{ .value = 1 };
    const function = try ctx.createFunction("RealmTaggedHost", zjs.native.managed(HostFunctionState.call), .{
        .state = @ptrCast(&state),
        .realm_global = realm_global,
    });
    const function_global = (try ctx.functionRealmGlobal(function)) orelse return error.TestExpectedEqual;
    try std.testing.expect(function_global == realm_global_object);

    try std.testing.expectError(error.JSException, ctx.evalScriptValue(zjs.JSValue.int32(1), .{}));
    try std.testing.expect(try ctx.consumePendingExceptionIfErrorName("TypeError"));
}

test "production embedding getProperty follows JavaScript accessors" {
    const rt = try zjs.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt, .{});
    defer ctx.destroy();

    const object = try ctx.eval(
        \\let hits = 0;
        \\({
        \\  get stack() {
        \\    hits += 1;
        \\    return "semantic stack";
        \\  },
        \\  get hits() {
        \\    return hits;
        \\  }
        \\})
    , .{});

    const stack = try ctx.getProperty(object, "stack");
    var stack_text = try stack.asString().?.toUtf8(std.testing.allocator);
    defer stack_text.deinit();
    try std.testing.expectEqualStrings("semantic stack", stack_text.slice());

    const hits = try ctx.getProperty(object, "hits");
    try std.testing.expectEqual(@as(?i32, 1), hits.as(.int));
}

test "production embedding getProperty reports accessor exceptions" {
    const rt = try zjs.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt, .{});
    defer ctx.destroy();

    const object = try ctx.eval(
        \\({
        \\  get stack() {
        \\    throw new Error("stack getter failed");
        \\  }
        \\})
    , .{});

    try std.testing.expectError(error.JSException, ctx.getProperty(object, "stack"));
    try std.testing.expect(ctx.hasException());
    const thrown = ctx.takePendingException();
    try std.testing.expect(thrown.is(.object));
}

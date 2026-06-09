const std = @import("std");
const zjs = @import("zjs");
const public_zjs = @import("../root.zig");

const InterruptState = struct {
    hits: usize = 0,

    fn stop(_: *zjs.JSRuntime, ctx: ?*anyopaque) bool {
        const self: *InterruptState = @ptrCast(@alignCast(ctx.?));
        self.hits += 1;
        return true;
    }
};

const HostFunctionState = struct {
    value: i32,

    fn call(ptr: *anyopaque, call_info: zjs.ExternalHostCall) anyerror!zjs.JSValue {
        _ = call_info;
        const self: *HostFunctionState = @ptrCast(@alignCast(ptr));
        return zjs.JSValue.int32(self.value);
    }
};

const HostFinalizerState = struct {
    calls: usize = 0,

    fn call(ptr: *anyopaque, call_info: zjs.ExternalHostCall) anyerror!zjs.JSValue {
        _ = ptr;
        _ = call_info;
        return zjs.JSValue.undefinedValue();
    }

    fn finalize(ptr: *anyopaque) void {
        const self: *HostFinalizerState = @ptrCast(@alignCast(ptr));
        self.calls += 1;
    }
};

const BytesStoreState = struct {
    allocator: std.mem.Allocator,
    calls: usize = 0,

    fn deinit(context: ?*anyopaque, bytes: []u8) void {
        const self: *BytesStoreState = @ptrCast(@alignCast(context.?));
        self.calls += 1;
        self.allocator.free(bytes);
    }
};

test "production public API contract exposes Zig-native embedding spellings" {
    try std.testing.expect(public_zjs.JSValue.Scope == public_zjs.value.Scope);
    try std.testing.expect(public_zjs.JSValue.Local == public_zjs.value.Local);
    try std.testing.expect(public_zjs.JSValue.Persistent == public_zjs.value.Persistent);
    try std.testing.expect(public_zjs.JSValue.Weak == public_zjs.value.Weak);
    try std.testing.expect(public_zjs.value.String == public_zjs.JSValue.String);
    try std.testing.expect(public_zjs.value.Bytes == public_zjs.JSValue.Bytes);
    try std.testing.expect(@hasDecl(public_zjs.host, "PropName"));
    try std.testing.expect(@hasDecl(public_zjs.host, "NativeBinding"));
    try std.testing.expect(@hasDecl(public_zjs.host.NativeBinding, "JSObject"));
    try std.testing.expect(@hasDecl(public_zjs.host.NativeBinding, "Storage"));
    try std.testing.expect(@hasDecl(public_zjs.host.NativeBinding, "Properties"));
    try std.testing.expect(@hasDecl(public_zjs.host.NativeBinding, "method"));
    try std.testing.expect(@typeInfo(public_zjs.object.Object) == .@"opaque");
    try std.testing.expect(!@hasDecl(public_zjs, "internal"));
    try std.testing.expect(!@hasDecl(public_zjs, "kernel"));
    try std.testing.expect(!@hasDecl(public_zjs, "PropNameID"));
    try std.testing.expect(!@hasDecl(public_zjs, "JSString"));
    try std.testing.expect(!@hasDecl(public_zjs, "JSBytes"));
    try std.testing.expect(!@hasDecl(public_zjs, "binding"));
}

test "production embedding can own JSRuntime and JSContext directly" {
    var rt: zjs.JSRuntime = undefined;
    try rt.init(std.testing.allocator, .{});
    defer rt.deinit();

    var ctx: zjs.JSContext = undefined;
    try ctx.init(&rt, .{});
    defer ctx.deinit();

    const value = try ctx.eval("1 + 1", .{});
    defer value.free(&rt);
    try std.testing.expectEqual(@as(?i32, 2), value.asInt32());

    const object = try ctx.eval("({ answer: 42 })", .{});
    defer object.free(&rt);
    try std.testing.expect(object.isObject());

    const global = try ctx.globalObject();
    try std.testing.expect(global.is_global);
}

test "production embedding API applies limits and releases eval handles" {
    const rt = try zjs.JSRuntime.createWithOptions(std.testing.allocator, .{
        .stack_size = 128 * 1024,
        .gc_threshold = 32 * 1024,
    });
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt);
    defer ctx.destroy();

    try std.testing.expectEqual(@as(usize, 128 * 1024), rt.stackSize());
    try std.testing.expectEqual(@as(usize, 32 * 1024), rt.gcThreshold());

    var output_buffer: [64]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const result = try ctx.eval("print(1 + 2);", .{ .output = &output });
    defer result.free(rt);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings("3\n", output.buffered());
}

test "production embedding can configure context policy through public methods" {
    const rt = try zjs.JSRuntime.createWithOptions(std.testing.allocator, .{
        .stack_size = 96 * 1024,
    });
    defer rt.destroy();

    const ctx = try zjs.JSContext.createWithOptions(rt, .{
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

test "production default host surface stays minimal" {
    const rt = try zjs.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt);
    defer ctx.destroy();

    var output_buffer: [160]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const result = try ctx.eval(
        \\print(1);
        \\console.log(2);
        \\print(typeof std, typeof os, typeof setTimeout);
        \\try { std; } catch (e) { print(e.name); }
        \\try { os; } catch (e) { print(e.name); }
    , .{ .output = &output });
    defer result.free(rt);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings(
        "1\n2\nundefined undefined undefined\nReferenceError\nReferenceError\n",
        output.buffered(),
    );
}

test "production event loop does not add product runtime globals" {
    const rt = try zjs.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt);
    defer ctx.destroy();

    var output_buffer: [160]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    var event_loop = zjs.runtime.EventLoop.init(ctx, .{ .output = &output });
    event_loop.install();
    defer event_loop.deinit();

    const result = try ctx.eval(
        \\print(1);
        \\console.log(2);
        \\print(typeof std, typeof os, typeof setTimeout, typeof setInterval, typeof clearTimeout, typeof clearInterval);
    , .{ .output = &output });
    defer result.free(rt);

    try std.testing.expect(result.isUndefined());
    try std.testing.expectEqualStrings(
        "1\n2\nundefined undefined undefined undefined undefined undefined\n",
        output.buffered(),
    );
}

test "production embedding can install external host functions" {
    const rt = try zjs.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt);
    defer ctx.destroy();

    var state = HostFunctionState{ .value = 42 };
    try ctx.defineGlobalFunction("hostValue", 0, &state, HostFunctionState.call, null);

    const result = try ctx.eval("hostValue()", .{});
    defer result.free(rt);
    try std.testing.expectEqual(@as(?i32, 42), result.asInt32());
}

test "production embedding can create external host function values" {
    const rt = try zjs.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt);
    defer ctx.destroy();

    var state = HostFunctionState{ .value = 7 };
    const function = try ctx.createExternalFunction("HostCtor", 0, &state, HostFunctionState.call, null, .{ .with_prototype = true });
    defer function.free(rt);
    try std.testing.expect(function.isObject());
    try std.testing.expect(ctx.isCallable(function));
    try std.testing.expect(ctx.isConstructor(function));

    const name = try ctx.functionName(function, std.testing.allocator);
    defer std.testing.allocator.free(name);
    try std.testing.expectEqualStrings("HostCtor", name);

    const prototype = try ctx.getProperty(function, "prototype");
    defer prototype.free(rt);
    try std.testing.expect(prototype.isObject());
}

test "production embedding can create objects and define data properties" {
    const rt = try zjs.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt);
    defer ctx.destroy();

    const object = try ctx.createObject();
    defer object.free(rt);
    try ctx.defineDataProperty(object, "answer", zjs.JSValue.int32(42), .{});

    const answer = try ctx.getProperty(object, "answer");
    defer answer.free(rt);
    try std.testing.expectEqual(@as(?i32, 42), answer.asInt32());
}

test "production embedding can inspect own property descriptors by JS key" {
    const rt = try zjs.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt);
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
    defer envelope.free(rt);

    const object = try ctx.getProperty(envelope, "object");
    defer object.free(rt);
    const key = try ctx.getProperty(envelope, "key");
    defer key.free(rt);

    try std.testing.expect(try ctx.hasOwnPropertyKey(object, key, .{}));
    var desc = (try ctx.ownPropertyDescriptor(object, key, .{})) orelse return error.TestExpectedEqual;
    defer desc.destroy(rt);
    try std.testing.expectEqual(zjs.PropertyDescriptor.data(zjs.JSValue.int32(17), false, false, true).kind, desc.kind);
    try std.testing.expectEqual(@as(?i32, 17), desc.value.asInt32());
    try std.testing.expectEqual(false, desc.writable.?);
    try std.testing.expectEqual(false, desc.enumerable.?);
    try std.testing.expectEqual(true, desc.configurable.?);

    const read_value = try ctx.getPropertyKey(object, key, .{});
    defer read_value.free(rt);
    try std.testing.expectEqual(@as(?i32, 17), read_value.asInt32());

    const inherited = try ctx.eval("Object.create({ inherited: 1 })", .{});
    defer inherited.free(rt);
    try std.testing.expect(!try ctx.hasOwnProperty(inherited, "inherited"));
    try ctx.defineDataProperty(inherited, "owned", zjs.JSValue.int32(1), .{});
    try std.testing.expect(try ctx.hasOwnProperty(inherited, "owned"));
    try std.testing.expect(try ctx.deleteProperty(inherited, "owned"));
    try std.testing.expect(!try ctx.hasOwnProperty(inherited, "owned"));

    const proxy = try ctx.eval("new Proxy({ visible: 99 }, {})", .{});
    defer proxy.free(rt);
    const visible_key = try ctx.createString("visible");
    defer visible_key.free(rt);
    var proxy_desc = (try ctx.ownPropertyDescriptor(proxy, visible_key, .{})) orelse return error.TestExpectedEqual;
    defer proxy_desc.destroy(rt);
    try std.testing.expectEqual(@as(?i32, 99), proxy_desc.value.asInt32());

    const revoked = try ctx.eval("const r = Proxy.revocable({ visible: 1 }, {}); r.revoke(); r.proxy", .{});
    defer revoked.free(rt);
    try std.testing.expectError(error.TypeError, ctx.ownPropertyDescriptor(revoked, visible_key, .{}));
}

test "production embedding can create strings and convert values to owned utf8" {
    const rt = try zjs.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt);
    defer ctx.destroy();

    const direct = try ctx.createString("caf\xc3\xa9");
    defer direct.free(rt);
    const direct_text = try direct.asString().?.toOwnedUtf8(std.testing.allocator);
    defer std.testing.allocator.free(direct_text);
    try std.testing.expectEqualStrings("caf\xc3\xa9", direct_text);

    const object = try ctx.eval("({ toString() { return 'semantic-\\u00e9'; } })", .{});
    defer object.free(rt);
    const semantic_text = try ctx.toOwnedUtf8(object, std.testing.allocator);
    defer std.testing.allocator.free(semantic_text);
    try std.testing.expectEqualStrings("semantic-\xc3\xa9", semantic_text);
}

test "production embedding can convert values to numbers" {
    const rt = try zjs.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt);
    defer ctx.destroy();

    try std.testing.expectEqual(@as(?f64, 42), zjs.JSValue.number(42.0).asNumber());
    try std.testing.expect(zjs.JSValue.number(-0.0).asFloat64().? == 0);

    const numeric_object = try ctx.eval("({ valueOf() { return 12.75; } })", .{});
    defer numeric_object.free(rt);
    try std.testing.expectEqual(@as(f64, 12.75), try ctx.toNumber(numeric_object));
    try std.testing.expectEqual(@as(f64, 12), try ctx.toIntegerOrInfinity(numeric_object));

    const non_numeric = try ctx.eval("({ toString() { return 'not-a-number'; } })", .{});
    defer non_numeric.free(rt);
    try std.testing.expect(std.math.isNan(try ctx.toNumber(non_numeric)));
}

test "production embedding can inspect callable and constructor values" {
    const rt = try zjs.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt);
    defer ctx.destroy();

    const function = try ctx.eval("(function NamedForEmbedding() {})", .{});
    defer function.free(rt);
    try std.testing.expect(ctx.isCallable(function));
    try std.testing.expect(ctx.isConstructor(function));

    const name = try ctx.functionName(function, std.testing.allocator);
    defer std.testing.allocator.free(name);
    try std.testing.expectEqualStrings("NamedForEmbedding", name);

    const arrow = try ctx.eval("(() => {})", .{});
    defer arrow.free(rt);
    try std.testing.expect(ctx.isCallable(arrow));
    try std.testing.expect(!ctx.isConstructor(arrow));

    try std.testing.expect(!ctx.isCallable(zjs.JSValue.int32(1)));
    try std.testing.expect(!ctx.isConstructor(zjs.JSValue.int32(1)));
}

test "production embedding can call JavaScript functions" {
    const rt = try zjs.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt);
    defer ctx.destroy();

    const function = try ctx.eval("(function addToBase(a, b) { return this.base + a + b; })", .{});
    defer function.free(rt);

    const receiver = try ctx.createObject();
    defer receiver.free(rt);
    try ctx.defineDataProperty(receiver, "base", zjs.JSValue.int32(10), .{});

    const result = try ctx.callFunction(function, &.{ zjs.JSValue.int32(2), zjs.JSValue.int32(3) }, .{
        .this_value = receiver,
    });
    defer result.free(rt);
    try std.testing.expectEqual(@as(?i32, 15), result.asInt32());

    const throwing = try ctx.eval("(function fail() { throw new TypeError('call failed'); })", .{});
    defer throwing.free(rt);
    try std.testing.expectError(error.JSException, ctx.callFunction(throwing, &.{}, .{}));
    try std.testing.expect(ctx.hasException());
    const exception = ctx.takePendingException();
    defer exception.free(rt);
    try std.testing.expect(exception.isObject());
}

test "production embedding can compare values with SameValue semantics" {
    const rt = try zjs.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt);
    defer ctx.destroy();

    try std.testing.expect(zjs.JSValue.float64(std.math.nan(f64)).sameValue(zjs.JSValue.float64(std.math.nan(f64))));
    try std.testing.expect(!zjs.JSValue.float64(0.0).sameValue(zjs.JSValue.float64(-0.0)));
    try std.testing.expect(zjs.JSValue.shortBigInt(7).sameValue(zjs.JSValue.shortBigInt(7)));

    const lhs = try ctx.eval("'same-value-string'", .{});
    defer lhs.free(rt);
    const rhs = try ctx.eval("'same-' + 'value-string'", .{});
    defer rhs.free(rt);
    try std.testing.expect(lhs.sameValue(rhs));
}

test "production embedding can inspect arrays and indexed values" {
    const rt = try zjs.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt);
    defer ctx.destroy();

    const array = try ctx.eval("[1, 2, 3]", .{});
    defer array.free(rt);
    try std.testing.expect(try ctx.isArray(array));
    try std.testing.expectEqual(@as(u32, 3), try ctx.arrayLength(array));

    const second = try ctx.getIndex(array, 1);
    defer second.free(rt);
    try std.testing.expectEqual(@as(?i32, 2), second.asInt32());

    const proxy = try ctx.eval("new Proxy([4], {})", .{});
    defer proxy.free(rt);
    try std.testing.expect(try ctx.isArray(proxy));
    try std.testing.expectEqual(@as(u32, 1), try ctx.arrayLength(proxy));

    const object = try ctx.eval("({ length: 1, 0: 9 })", .{});
    defer object.free(rt);
    try std.testing.expect(!try ctx.isArray(object));
    try std.testing.expectError(error.TypeError, ctx.arrayLength(object));

    const revoked = try ctx.eval("const r = Proxy.revocable([], {}); r.revoke(); r.proxy", .{});
    defer revoked.free(rt);
    try std.testing.expectError(error.TypeError, ctx.isArray(revoked));
}

test "production embedding can inspect runtime memory usage without internal modules" {
    const rt = try zjs.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const usage: zjs.RuntimeMemoryUsage = rt.memoryUsage();
    try std.testing.expect(usage.allocated_bytes > 0);
    try std.testing.expect(usage.allocation_count > 0);
    try std.testing.expect(usage.atom_count > 0);
}

test "production embedding roots host-held values with public handles" {
    const rt = try zjs.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt);
    defer ctx.destroy();

    const object = try ctx.eval("({ answer: 42 })", .{});

    var scope: zjs.JSValue.Scope = rt.enterHandleScope();
    const local: zjs.JSValue.Local = try scope.localDup(object);
    object.free(rt);

    try std.testing.expectEqual(@as(usize, 1), rt.localRootCountForTest());
    try std.testing.expectEqual(@as(usize, 0), rt.persistentRootCountForTest());
    try std.testing.expect(local.get().isObject());

    var persistent: zjs.JSValue.Persistent = try rt.createPersistentValue(local.get());
    defer persistent.deinit();

    scope.exit();
    try std.testing.expectEqual(@as(usize, 0), rt.localRootCountForTest());
    try std.testing.expectEqual(@as(usize, 1), rt.persistentRootCountForTest());

    const answer = try ctx.getProperty(persistent.get(), "answer");
    defer answer.free(rt);
    try std.testing.expectEqual(@as(?i32, 42), answer.asInt32());

    persistent.deinit();
    try std.testing.expectEqual(@as(usize, 0), rt.persistentRootCountForTest());
}

test "production embedding can expose owned and shared byte stores" {
    const rt = try zjs.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt);
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
    var owned_live = true;
    defer if (owned_live) owned_value.free(rt);
    try std.testing.expectEqual(@as(usize, 0), owned_store.bytes.len);

    const owned_view: zjs.JSBytes = try owned_value.asBytes(ctx);
    try std.testing.expect(!owned_view.isShared());
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, owned_view.slice());
    const owned_mut = try owned_view.sliceMut();
    owned_mut[1] = 9;
    try std.testing.expectEqualSlices(u8, &.{ 1, 9, 3, 4 }, owned_view.slice());
    try std.testing.expectEqual(@as(usize, 0), owned_state.calls);

    owned_value.free(rt);
    owned_live = false;
    try std.testing.expectEqual(@as(usize, 1), owned_state.calls);

    var shared_state = BytesStoreState{ .allocator = std.testing.allocator };
    const shared_backing = try std.testing.allocator.alloc(u8, 3);
    @memcpy(shared_backing, &[_]u8{ 8, 9, 10 });
    var shared_store = zjs.JSBytes.Store.shared(shared_backing, .{
        .deinit = BytesStoreState.deinit,
        .context = &shared_state,
    });
    errdefer shared_store.release();

    const shared_value = try ctx.arrayBuffer(&shared_store);
    var shared_live = true;
    defer if (shared_live) shared_value.free(rt);
    try std.testing.expectEqual(@as(usize, 0), shared_store.bytes.len);

    const shared_view: zjs.JSBytes = try shared_value.asBytes(ctx);
    try std.testing.expect(shared_view.isShared());
    try std.testing.expectEqualSlices(u8, &.{ 8, 9, 10 }, shared_view.slice());
    const shared_mut = try shared_view.sliceMut();
    shared_mut[0] = 12;
    try std.testing.expectEqualSlices(u8, &.{ 12, 9, 10 }, shared_view.slice());
    try std.testing.expectEqual(@as(usize, 0), shared_state.calls);

    shared_value.free(rt);
    shared_live = false;
    try std.testing.expectEqual(@as(usize, 1), shared_state.calls);
}

test "production runtime can detach array buffers through public runtime API" {
    const rt = try zjs.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt);
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
    defer owned_value.free(rt);
    try std.testing.expectEqual(@as(usize, 0), owned_state.calls);

    const detached = try zjs.runtime.detachArrayBuffer(&ctx.core, owned_value);
    defer detached.free(rt);
    try std.testing.expect(detached.isUndefined());
    try std.testing.expectEqual(@as(usize, 1), owned_state.calls);
    try std.testing.expectError(error.Detached, owned_value.asBytes(ctx));

    var shared_state = BytesStoreState{ .allocator = std.testing.allocator };
    const shared_backing = try std.testing.allocator.alloc(u8, 1);
    @memcpy(shared_backing, &[_]u8{5});
    var shared_store = zjs.JSBytes.Store.shared(shared_backing, .{
        .deinit = BytesStoreState.deinit,
        .context = &shared_state,
    });
    errdefer shared_store.release();

    const shared_value = try ctx.arrayBuffer(&shared_store);
    defer shared_value.free(rt);
    try std.testing.expectError(error.TypeError, zjs.runtime.detachArrayBuffer(&ctx.core, shared_value));
    try std.testing.expectEqual(@as(usize, 0), shared_state.calls);
}

test "production embedding can retain and rewrap shared array buffers" {
    const rt = try zjs.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt);
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
    defer original.free(rt);
    var shared_ref = try ctx.retainSharedArrayBuffer(original);
    defer shared_ref.release();

    const other_rt = try zjs.JSRuntime.create(std.testing.allocator);
    defer other_rt.destroy();
    const other_ctx = try zjs.JSContext.create(other_rt);
    defer other_ctx.destroy();

    const rewrapped = try other_ctx.sharedArrayBufferFromRef(shared_ref);
    defer rewrapped.free(other_rt);
    const rewrapped_view = try rewrapped.asBytes(other_ctx);
    const rewrapped_mut = try rewrapped_view.sliceMut();
    rewrapped_mut[1] = 9;

    const original_view = try original.asBytes(ctx);
    try std.testing.expect(original_view.isShared());
    try std.testing.expectEqualSlices(u8, &.{ 1, 9, 3 }, original_view.slice());
    try std.testing.expectEqual(@as(usize, 0), shared_state.calls);

    try std.testing.expectError(error.TypeError, ctx.retainSharedArrayBuffer(zjs.JSValue.int32(1)));
}

test "production embedding lifecycle deinitializes repeated script and module evals" {
    var index: usize = 0;
    while (index < 4) : (index += 1) {
        const rt = try zjs.JSRuntime.create(std.testing.allocator);
        defer rt.destroy();

        const ctx = try zjs.JSContext.create(rt);
        defer ctx.destroy();

        const script_result = try ctx.eval(
            \\let values = [];
            \\for (let i = 0; i < 8; i++) values.push({ i });
            \\values.map(v => v.i).join(",");
        , .{ .discard_script_result = true });
        defer script_result.free(rt);
        try std.testing.expect(script_result.isUndefined());

        const module_result = try ctx.eval(
            \\const value = await Promise.resolve(42);
            \\export { value };
        , .{ .mode = .module });
        defer module_result.free(rt);
    }
}

test "production embedding memory limit reports allocation failure without leaking" {
    const rt = try zjs.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt);
    defer ctx.destroy();

    rt.setMemoryLimit(rt.memory.allocated_bytes);
    defer rt.setMemoryLimit(null);

    try std.testing.expectError(error.OutOfMemory, ctx.eval("({ payload: new Array(32).fill('x') });", .{}));
}

test "production embedding public API allocation failures keep host ownership intact" {
    const rt = try zjs.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt);
    defer ctx.destroy();

    const object = try ctx.eval("({ answer: 42 })", .{});
    defer object.free(rt);

    const persistent_before = rt.persistentRootCountForTest();
    const local_before = rt.localRootCountForTest();

    rt.setMemoryLimit(rt.memory.allocated_bytes);
    defer rt.setMemoryLimit(null);

    if (rt.createPersistentValue(object)) |handle| {
        var owned = handle;
        owned.deinit();
        return error.TestExpectedError;
    } else |err| {
        try std.testing.expectEqual(error.OutOfMemory, err);
    }
    try std.testing.expectEqual(persistent_before, rt.persistentRootCountForTest());
    try std.testing.expectEqual(local_before, rt.localRootCountForTest());

    if (ctx.createString("must allocate")) |value| {
        value.free(rt);
        return error.TestExpectedError;
    } else |err| {
        try std.testing.expectEqual(error.OutOfMemory, err);
    }
    try std.testing.expectEqual(persistent_before, rt.persistentRootCountForTest());
    try std.testing.expectEqual(local_before, rt.localRootCountForTest());

    var finalizer_state = HostFinalizerState{};
    if (ctx.createExternalFunction(
        "AllocationBlockedHostFn",
        0,
        &finalizer_state,
        HostFinalizerState.call,
        HostFinalizerState.finalize,
        .{},
    )) |value| {
        value.free(rt);
        return error.TestExpectedError;
    } else |err| {
        try std.testing.expectEqual(error.OutOfMemory, err);
    }
    try std.testing.expectEqual(@as(usize, 0), finalizer_state.calls);

    var bytes_state = BytesStoreState{ .allocator = std.testing.allocator };
    const backing = try std.testing.allocator.alloc(u8, 2);
    @memcpy(backing, &[_]u8{ 1, 2 });
    var store = zjs.JSValue.Bytes.Store.owned(backing, .{
        .deinit = BytesStoreState.deinit,
        .context = &bytes_state,
    });
    defer store.release();

    if (ctx.arrayBuffer(&store)) |value| {
        value.free(rt);
        return error.TestExpectedError;
    } else |err| {
        try std.testing.expectEqual(error.OutOfMemory, err);
    }
    try std.testing.expectEqual(@as(usize, 0), bytes_state.calls);
    try std.testing.expectEqual(@as(usize, 2), store.bytes.len);
}

test "production embedding interrupt handler aborts unbounded execution" {
    const rt = try zjs.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt);
    defer ctx.destroy();

    var state = InterruptState{};
    rt.setInterruptHandler(InterruptState.stop, &state);
    defer rt.setInterruptHandler(null, null);

    try std.testing.expectError(error.Interrupted, ctx.eval("while (true) {}", .{}));
    try std.testing.expect(state.hits > 0);
}

test "production embedding takeException captures exception snapshot without leaking" {
    const rt = try zjs.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt);
    defer ctx.destroy();

    _ = ctx.eval("throw new Error('test exception snapshot');", .{}) catch |err| {
        try std.testing.expectEqual(error.JSException, err);
        const thrown = ctx.takePendingException();
        defer thrown.free(rt);
        try std.testing.expect(thrown.isObject());
    };
}

test "production embedding can create and throw named errors" {
    const rt = try zjs.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt);
    defer ctx.destroy();

    const created = try ctx.createError("TypeError", "host-created", .{});
    defer created.free(rt);
    const created_text = try ctx.formatException(created, std.testing.allocator);
    defer std.testing.allocator.free(created_text);
    try std.testing.expectEqualStrings("TypeError: host-created", created_text);

    const created_stack = try ctx.formatExceptionStack(created, std.testing.allocator);
    defer if (created_stack) |stack| std.testing.allocator.free(stack);
    try std.testing.expect(created_stack != null);

    try std.testing.expectError(error.JSException, ctx.throwError("RangeError", "host-thrown", .{}));
    try std.testing.expect(ctx.hasException());
    const thrown = ctx.takePendingException();
    defer thrown.free(rt);

    const thrown_text = try ctx.formatException(thrown, std.testing.allocator);
    defer std.testing.allocator.free(thrown_text);
    try std.testing.expectEqualStrings("RangeError: host-thrown", thrown_text);
}

test "production embedding can match pending exceptions by error name" {
    const rt = try zjs.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt);
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
    const rt = try zjs.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt);
    defer ctx.destroy();

    const realm = try ctx.createRealm();
    defer realm.free(rt);

    const realm_global = try ctx.realmGlobal(realm);
    defer realm_global.free(rt);
    try std.testing.expect(realm_global.isObject());

    const realm_global_object = try ctx.realmGlobalObject(realm);
    try std.testing.expect(realm_global_object.is_global);

    const realm_global_this = try ctx.getProperty(realm_global, "globalThis");
    defer realm_global_this.free(rt);
    try std.testing.expect(realm_global_this.sameValue(realm_global));

    const current_array = try ctx.eval("Array", .{});
    defer current_array.free(rt);
    const realm_array = try ctx.getProperty(realm_global, "Array");
    defer realm_array.free(rt);
    try std.testing.expect(!realm_array.sameValue(current_array));
}

test "production embedding can eval script source in explicit function realms" {
    const rt = try zjs.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt);
    defer ctx.destroy();

    const realm = try ctx.createRealm();
    defer realm.free(rt);
    const realm_global = try ctx.realmGlobal(realm);
    defer realm_global.free(rt);
    const realm_global_object = try ctx.realmGlobalObject(realm);

    try ctx.defineDataProperty(realm_global, "realmMarker", zjs.JSValue.int32(40), .{});

    const source_result = try ctx.evalScriptSource("realmMarker + 2", .{
        .realm_global = realm_global_object,
        .filename = "embedding-realm-source.js",
    });
    defer source_result.free(rt);
    try std.testing.expectEqual(@as(?i32, 42), source_result.asInt32());

    const source_value = try ctx.createString("realmMarker + 3");
    defer source_value.free(rt);
    const value_result = try ctx.evalScriptValue(source_value, .{
        .realm_global = realm_global_object,
        .filename = "embedding-realm-value.js",
    });
    defer value_result.free(rt);
    try std.testing.expectEqual(@as(?i32, 43), value_result.asInt32());

    var state = HostFunctionState{ .value = 1 };
    const function = try ctx.createExternalFunction("RealmTaggedHost", 0, &state, HostFunctionState.call, null, .{
        .realm_global = realm_global_object,
    });
    defer function.free(rt);
    const function_global = (try ctx.functionRealmGlobal(function)) orelse return error.TestExpectedEqual;
    try std.testing.expect(function_global == realm_global_object);

    try std.testing.expectError(error.TypeError, ctx.evalScriptValue(zjs.JSValue.int32(1), .{}));
}

test "production embedding getProperty follows JavaScript accessors" {
    const rt = try zjs.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt);
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
    defer object.free(rt);

    const stack = try ctx.getProperty(object, "stack");
    defer stack.free(rt);
    var stack_text = try stack.asString().?.toUtf8(std.testing.allocator);
    defer stack_text.deinit();
    try std.testing.expectEqualStrings("semantic stack", stack_text.slice());

    const hits = try ctx.getProperty(object, "hits");
    defer hits.free(rt);
    try std.testing.expectEqual(@as(?i32, 1), hits.asInt32());
}

test "production embedding getProperty reports accessor exceptions" {
    const rt = try zjs.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt);
    defer ctx.destroy();

    const object = try ctx.eval(
        \\({
        \\  get stack() {
        \\    throw new Error("stack getter failed");
        \\  }
        \\})
    , .{});
    defer object.free(rt);

    try std.testing.expectError(error.JSException, ctx.getProperty(object, "stack"));
    try std.testing.expect(ctx.hasException());
    const thrown = ctx.takePendingException();
    defer thrown.free(rt);
    try std.testing.expect(thrown.isObject());
}

test "core source does not import runtime policy layers" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const root = "src/core";
    const forbidden = [_][]const u8{
        "@import(\"../runtime",
        "@import(\"../../runtime",
        "@import(\"../cli",
        "@import(\"../../cli",
        "@import(\"../kernel",
        "@import(\"../../kernel",
        "runtime/public",
        "runtime/root",
        "plugin.zig",
        "run_test262",
        "test262",
    };

    var dir = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;

        const path = try std.fs.path.join(allocator, &.{ root, entry.path });
        defer allocator.free(path);

        const source = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(4 * 1024 * 1024));
        defer allocator.free(source);

        for (forbidden) |needle| {
            if (std.mem.indexOf(u8, source, needle) != null) {
                std.debug.print("forbidden core dependency marker \"{s}\" in {s}\n", .{ needle, path });
                return error.ForbiddenCoreRuntimeDependency;
            }
        }
    }
}

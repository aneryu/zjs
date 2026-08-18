const std = @import("std");
const build_options = @import("build_options");
const zjs = @import("zjs");

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

    scope.deinit();

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

    try ObjectType.install(ctx_a.core);
    const binding_a = try ObjectType.binding(ctx_a.core);

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
    defer value_a.free(rt);
    try std.testing.expectEqual(@as(i32, 7), binding_a.payload(value_a).?.value);

    try ObjectType.install(ctx_b.core);
    const binding_b = try ObjectType.binding(ctx_b.core);
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

    try std.testing.expectError(error.PropertyAlreadyExists, plugin.install(ctx.core, target, .{}));
    try std.testing.expect(plugin.consumed);
    try std.testing.expect(plugin.loaded != null);
    try std.testing.expectError(error.PluginAlreadyConsumed, plugin.install(ctx.core, target, .{ .overwrite = true }));

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
    "ffi",
    "JSValue",
    "RuntimeOptions",
    "RuntimeMemoryUsage",
    "OpcodeProfile",
    "default_stack_size",
    "default_gc_threshold",
    "opcode_profile_build_enabled",
    "activateOpcodeProfile",
    "value",
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
    "Call",
    "Function",
    "Finalizer",
    "FunctionOptions",
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
    "Plugin",
    "PluginInstallOptions",
};
const public_ffi_decls = [_][]const u8{
    "PropNameID",
    "abi_version",
    "magic",
    "supported_features",
    "Feature",
    "featureBit",
    "Endian",
    "Target",
    "DescriptorHeader",
    "ValidationError",
    "validateHeader",
    "BorrowedBytes",
    "MutableBytes",
    "JSValueSlice",
    "StringPolicy",
    "StringLifetime",
    "StringDescriptor",
    "stringUtf8",
    "cString",
    "BytesPolicy",
    "BytesDeinitFn",
    "OwnedBytesOptions",
    "BytesLifetime",
    "Bytes",
    "BytesDescriptor",
    "bytes",
    "HostTypeId",
    "OpaqueHostObject",
    "HostTraceVisitor",
    "HostObjectFinalizer",
    "HostObjectTracer",
    "HostObjectOwner",
    "HostObjectOptions",
    "HostObjectDescriptor",
    "hostObject",
    "PropNameDescriptor",
    "propName",
    "ResolvedPropNames",
    "resolvePropNames",
    "Status",
    "CreateOpaqueObjectFn",
    "UnwrapOpaqueObjectFn",
    "GetPropNameFn",
    "OpaqueObjectServices",
    "PropNameServices",
    "HostServices",
    "CallFrame",
    "Trampoline",
    "DescriptorExport",
    "descriptor_symbol",
    "ZigCall",
    "trampoline",
    "BindingOptions",
    "binding",
    "bindingWithOptions",
    "BindingDescriptor",
    "PluginDescriptor",
    "Plugin",
    "validatePlugin",
    "validateHostObject",
    "validatePropName",
    "LoadError",
    "LoadedPlugin",
    "descriptorFromExport",
    "statusFromError",
    "js_value_layout_hash",
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
    expectPublicDeclSnapshot("zjs.ffi", zjs.ffi, &public_ffi_decls) catch {
        failed = true;
    };
    if (failed) return error.TestExpectedEqual;

    // Known debt (backlog H9): JSValue is the public value type and still
    // publishes internal helpers. The count is pinned so a leak expansion
    // is visible; do not call names such as freeObjectAssumeObject*.
    const jsvalue_decl_count = @typeInfo(zjs.JSValue).@"struct".decls.len;
    try std.testing.expectEqual(@as(usize, 89), jsvalue_decl_count);
    try std.testing.expect(@hasDecl(zjs.JSValue, "freeObjectAssumeObjectDuringActiveBytecode"));
}

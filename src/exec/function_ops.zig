const std = @import("std");

const core = @import("../core/root.zig");
const builtin_dispatch = @import("builtin_dispatch.zig");
const call = @import("call.zig");
const call_runtime = @import("call_runtime.zig");
const exceptions = @import("exceptions.zig");

const HostError = exceptions.HostError;

pub const PrototypeMethod = enum(u32) {
    to_string = 1,
    bind = 2,
    call = 3,
    apply = 4,
    has_instance = 5,
};

/// Identity of the realm-installed default `Function.prototype[@@hasInstance]`
/// record (qjs:41395 `JS_CFUNC_DEF("[Symbol.hasInstance]", 1, js_function_hasInstance)`).
/// Pointer compare against the densified table slot — not a name or shape cache.
pub fn isDefaultHasInstanceRecord(rt: *core.JSRuntime, record: *const core.host_function.InternalRecord) bool {
    const expected = rt.internalBuiltinRecord(
        @intCast(@intFromEnum(core.function.NativeBuiltinDomain.function)),
        @intFromEnum(PrototypeMethod.has_instance),
    );
    return if (expected) |slot| record == slot else false;
}

/// Declaration + dispatch table for the `.function` native-builtin domain
/// (QuickJS `js_function_proto_funcs` analogue, quickjs.c:41390).
pub const internal_entries = [_]core.host_function.InternalEntry{
    functionCallEntry(),
    functionApplyEntry(),
    functionEntry("toString", 0, @intFromEnum(PrototypeMethod.to_string)),
    functionEntry("bind", 1, @intFromEnum(PrototypeMethod.bind)),
    // qjs:41395 `JS_CFUNC_DEF("[Symbol.hasInstance]", 1, js_function_hasInstance)`.
    // Every `instanceof` whose RHS does not override `Symbol.hasInstance` lands
    // here, so it must resolve by record id rather than by name cascade.
    //
    // `JS_CFUNC_DEF` is `JS_CFUNC_generic`, not `JS_CFUNC_MAGIC_DEF`: qjs gives
    // this method its own C function rather than a magic selector into a shared
    // body. Mirror that -- a dedicated `.generic` entry keeps the 24M-call
    // `instanceof` path out of `functionCall`'s magic switch, which the hot
    // `apply`/`bind`/`toString` trio shares.
    functionHasInstanceEntry(),
};

fn functionHasInstanceEntry() core.host_function.InternalEntry {
    return .{
        .name = "[Symbol.hasInstance]",
        .length = 1,
        .id = @intFromEnum(PrototypeMethod.has_instance),
        .magic = 0,
        .cproto = .generic,
        .native_function = .{ .generic = &functionHasInstance },
        .exec_direct = builtin_dispatch.execDirectFunction(&functionHasInstanceDirect),
    };
}

/// Exec-direct ABI twin of `functionHasInstance` (NB2-B): identical body
/// routing, but the realm pair, output, and VM caller pair arrive by
/// parameter, so no NativeCallEnvironment recovery is needed. Declared
/// separately because `qjsFunctionHasInstanceCall` carries an inferred error
/// set and the direct ABI requires the exact `HostError` surface.
fn functionHasInstanceDirect(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const builtin_dispatch.Bytecode,
    caller_frame: ?*builtin_dispatch.Frame,
) HostError!core.JSValue {
    return call_runtime.qjsFunctionHasInstanceCall(ctx, output, global, this_value, args, caller_function, caller_frame);
}

/// qjs:41379 `js_function_hasInstance` -> `JS_OrdinaryIsInstanceOf(ctx,
/// argv[0], this_val)`. The receiver is the constructor, the first argument the
/// probed value.
fn functionHasInstance(
    native_ctx: *core.JSContext,
    native_this: core.JSValue,
    native_args: []const core.JSValue,
) HostError!core.JSValue {
    const host_call = builtin_dispatch.nativeCall(native_ctx, native_this, native_args, 0) orelse return error.TypeError;
    const realm = try builtin_dispatch.callableRealm(host_call);
    std.debug.assert(realm.realm == host_call.ctx);
    return call_runtime.qjsFunctionHasInstanceCall(
        host_call.ctx,
        host_call.output,
        realm.global,
        host_call.this_value,
        host_call.args,
        builtin_dispatch.callerBytecode(host_call),
        builtin_dispatch.callerFrame(host_call),
    );
}

fn functionEntry(comptime name: []const u8, comptime length: u8, comptime id: u32) core.host_function.InternalEntry {
    return .{
        .name = name,
        .length = length,
        .id = id,
        .magic = @intCast(id),
        .cproto = .generic_magic,
        .native_function = builtin_dispatch.genericMagicFunction(&functionCall),
    };
}

fn functionCallEntry() core.host_function.InternalEntry {
    const id = @intFromEnum(PrototypeMethod.call);
    return .{
        .name = "call",
        .length = 1,
        .id = id,
        .magic = @intCast(id),
        .forwards_call = true,
        .cproto = .generic_magic,
        .native_function = builtin_dispatch.genericMagicFunction(&functionCallRecord),
        // NB2-B: same shape as apply — the body consumes only the direct-ABI
        // parameter set, so the non-forwarding dispatch paths (e.g.
        // `fastNativeMethodCall`) skip the environment round-trip too.
        .exec_direct = builtin_dispatch.execDirectFunction(&call_runtime.qjsFunctionCallCall),
    };
}

/// qjs:41392 `JS_CFUNC_MAGIC_DEF("apply", 2, js_function_apply, 0)`: apply is
/// a dedicated C function in qjs, not a selector into a shared body. Mirror
/// that with its own record handler so the hot apply path skips the
/// `functionCall` magic switch. `forwards_call` stays false: apply
/// materializes its own argument list, and `op_call_method`'s fused-frame
/// forwarding arm (vm_call.zig `nativeMethodFastDispatch` miss gate) is built
/// only for Function.prototype.call's argv+1 forwarding.
fn functionApplyEntry() core.host_function.InternalEntry {
    const id = @intFromEnum(PrototypeMethod.apply);
    return .{
        .name = "apply",
        .length = 2,
        .id = id,
        .magic = @intCast(id),
        .cproto = .generic_magic,
        .native_function = builtin_dispatch.genericMagicFunction(&functionApplyRecord),
        // NB2-B (qjs:17563 `js_call_c_function` has no env side-channel):
        // the flat apply body takes the whole call state by parameter, so the
        // hot record dispatch skips the NativeCallEnvironment stores and the
        // `active_native_call` save/set/restore. `functionApplyRecord` stays
        // as the env-path shim for any dispatcher that still owns one.
        .exec_direct = builtin_dispatch.execDirectFunction(&call_runtime.qjsFunctionApplyCall),
    };
}

test "Function.call has a dedicated native record handler" {
    var call_handler: ?core.host_function.NativeGenericMagicFn = null;
    for (internal_entries) |entry| {
        if (entry.id == @intFromEnum(PrototypeMethod.call)) {
            const native = entry.native_function orelse continue;
            call_handler = switch (native) {
                .generic_magic => |handler| handler,
                else => null,
            };
        }
    }
    try std.testing.expect(call_handler != null);
    try std.testing.expect(call_handler.? == &functionCallRecord);
    for (internal_entries) |entry| {
        if (entry.id == @intFromEnum(PrototypeMethod.call)) {
            try std.testing.expect(entry.forwards_call);
            return;
        }
    }
    return error.TestUnexpectedResult;
}

test "Function.apply has a dedicated non-forwarding native record handler" {
    var apply_handler: ?core.host_function.NativeGenericMagicFn = null;
    for (internal_entries) |entry| {
        if (entry.id == @intFromEnum(PrototypeMethod.apply)) {
            const native = entry.native_function orelse continue;
            apply_handler = switch (native) {
                .generic_magic => |handler| handler,
                else => null,
            };
        }
    }
    try std.testing.expect(apply_handler != null);
    try std.testing.expect(apply_handler.? == &functionApplyRecord);
    for (internal_entries) |entry| {
        if (entry.id == @intFromEnum(PrototypeMethod.apply)) {
            // apply must NOT route into op_call_method's fused-frame
            // forwarding arm, which only implements Function.prototype.call.
            try std.testing.expect(!entry.forwards_call);
            // NB2-B: the hot record dispatch must take the exec-direct ABI
            // (no NativeCallEnvironment round-trip) straight into the flat
            // apply body.
            try std.testing.expect(entry.exec_direct != null);
            try std.testing.expect(entry.exec_direct.? ==
                builtin_dispatch.execDirectFunction(&call_runtime.qjsFunctionApplyCall));
            return;
        }
    }
    return error.TestUnexpectedResult;
}

/// Shared record handler for the remaining `.function` methods. Function.call
/// uses its own qjs-style function-list entry because it is a hot forwarding
/// primitive; the bodies stay in exec because they read engine call/frame
/// internals.
fn functionCall(
    native_ctx: *core.JSContext,
    native_this: core.JSValue,
    native_args: []const core.JSValue,
    native_magic: i32,
) HostError!core.JSValue {
    const host_call = builtin_dispatch.nativeCall(native_ctx, native_this, native_args, native_magic) orelse return error.TypeError;
    const ctx = host_call.ctx;
    const id: u32 = host_call.magic;
    return switch (id) {
        @intFromEnum(PrototypeMethod.to_string) => call.functionToStringValue(ctx.runtime, host_call.this_value),
        @intFromEnum(PrototypeMethod.bind) => {
            const realm = try builtin_dispatch.callableRealm(host_call);
            std.debug.assert(realm.realm == ctx);
            return call.qjsFunctionBindCall(ctx, host_call.output, realm.global, &.{}, host_call.this_value, host_call.args);
        },
        else => error.TypeError,
    };
}

/// Dedicated apply record handler (qjs:41213 `js_function_apply`, magic 0).
/// Same shape as `functionCallRecord`: recover the exec environment, resolve
/// the callable realm once, then run the flat apply body.
fn functionApplyRecord(
    native_ctx: *core.JSContext,
    native_this: core.JSValue,
    native_args: []const core.JSValue,
    native_magic: i32,
) HostError!core.JSValue {
    const host_call = builtin_dispatch.nativeCall(native_ctx, native_this, native_args, native_magic) orelse return error.TypeError;
    const realm = try builtin_dispatch.callableRealm(host_call);
    std.debug.assert(realm.realm == host_call.ctx);
    return call_runtime.qjsFunctionApplyCall(
        host_call.ctx,
        host_call.output,
        realm.global,
        host_call.this_value,
        host_call.args,
        builtin_dispatch.callerBytecode(host_call),
        builtin_dispatch.callerFrame(host_call),
    );
}

fn functionCallRecord(
    native_ctx: *core.JSContext,
    native_this: core.JSValue,
    native_args: []const core.JSValue,
    native_magic: i32,
) HostError!core.JSValue {
    const host_call = builtin_dispatch.nativeCall(native_ctx, native_this, native_args, native_magic) orelse return error.TypeError;
    const realm = try builtin_dispatch.callableRealm(host_call);
    std.debug.assert(realm.realm == host_call.ctx);
    return call_runtime.qjsFunctionCallCall(
        host_call.ctx,
        host_call.output,
        realm.global,
        host_call.this_value,
        host_call.args,
        builtin_dispatch.callerBytecode(host_call),
        builtin_dispatch.callerFrame(host_call),
    );
}

/// Create a native function object carrying source text for
/// `Function.prototype.toString`-style inspection.
pub fn sourceFunction(realm: *core.RealmContext, name: []const u8, source: []const u8) !core.JSValue {
    const rt = realm.runtimePtr();
    const function_proto = realm.cached_function_proto orelse return error.InvalidBuiltinRegistry;
    var function_value = try core.function.nativeFunctionWithPrototypeAndCapacity(realm, function_proto, name, 0, 2);
    const function_object = try core.Object.expect(function_value);
    var source_value = core.JSValue.undefinedValue();
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &function_value },
        .{ .value = &source_value },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    errdefer {
        const failed_function = function_value;
        function_value = core.JSValue.undefinedValue();
        failed_function.free(rt);
    }

    const source_string = try core.string.String.createUtf8(rt, source);
    source_value = source_string.value();
    try function_object.setOptionalValueSlot(rt, try function_object.functionSourceSlot(rt), source_value.dup());
    source_value.free(rt);
    source_value = core.JSValue.undefinedValue();

    return function_value;
}

test "sourceFunction roots function and source while attaching source text" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.RealmContext.create(rt);
    defer ctx.destroy();
    const function_proto = try core.Object.create(rt, core.class.ids.object, null);
    ctx.cached_function_proto = function_proto;

    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const function_value = try sourceFunction(ctx, "namedSource", "function namedSource() { return 1; }");
    defer function_value.free(rt);
    const function_object = objectFromFunctionValue(function_value) orelse return error.TypeError;
    const source_value = function_object.functionSource() orelse return error.TypeError;
    const source_string = source_value.asStringBody() orelse return error.TypeError;
    try std.testing.expect(source_string.eqlBytes("function namedSource() { return 1; }"));
}

fn objectFromFunctionValue(value: core.JSValue) ?*core.Object {
    if (!value.isObject()) return null;
    const header = value.refHeader() orelse return null;
    return @fieldParentPtr("header", header);
}

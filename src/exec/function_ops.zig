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
};

/// Declaration + dispatch table for the `.function` native-builtin domain
/// (QuickJS `js_function_proto_funcs` analogue).
pub const internal_entries = [_]core.host_function.InternalEntry{
    functionCallEntry(),
    functionEntry("apply", 2, @intFromEnum(PrototypeMethod.apply)),
    functionEntry("toString", 0, @intFromEnum(PrototypeMethod.to_string)),
    functionEntry("bind", 1, @intFromEnum(PrototypeMethod.bind)),
};

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
        @intFromEnum(PrototypeMethod.bind) => call.qjsFunctionBindCall(ctx, host_call.output, host_call.global, host_call.globals, host_call.this_value, host_call.args),
        @intFromEnum(PrototypeMethod.apply) => call_runtime.qjsFunctionApplyCall(
            ctx,
            host_call.output,
            host_call.global orelse return error.TypeError,
            host_call.this_value,
            host_call.func_obj orelse return error.TypeError,
            host_call.args,
            builtin_dispatch.callerBytecode(host_call),
            builtin_dispatch.callerFrame(host_call),
        ),
        else => error.TypeError,
    };
}

fn functionCallRecord(
    native_ctx: *core.JSContext,
    native_this: core.JSValue,
    native_args: []const core.JSValue,
    native_magic: i32,
) HostError!core.JSValue {
    const host_call = builtin_dispatch.nativeCall(native_ctx, native_this, native_args, native_magic) orelse return error.TypeError;
    return call_runtime.qjsFunctionCallCall(
        host_call.ctx,
        host_call.output,
        host_call.global orelse return error.TypeError,
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
    const function_object = try core.Object.create(rt, core.class.ids.c_function, null);
    function_object.setNativeFunctionRealm(realm);
    var function_value = function_object.value();
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

    try defineFunctionName(rt, function_object, name);
    const source_string = try core.string.String.createUtf8(rt, source);
    source_value = source_string.value();
    try function_object.setOptionalValueSlot(rt, try function_object.functionSourceSlot(rt), source_value.dup());
    source_value.free(rt);
    source_value = core.JSValue.undefinedValue();

    return function_value;
}

fn defineFunctionData(
    rt: *core.JSRuntime,
    target: *core.Object,
    name: []const u8,
    value: core.JSValue,
    writable: bool,
    enumerable: bool,
    configurable: bool,
) !void {
    var target_value = target.value();
    var rooted_value = value;
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &target_value },
        .{ .value = &rooted_value },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    const key = try rt.internAtom(name);
    defer rt.atoms.free(key);
    try target.defineOwnProperty(rt, key, core.Descriptor.data(rooted_value, writable, enumerable, configurable));
}

fn defineFunctionName(rt: *core.JSRuntime, function_object: *core.Object, name: []const u8) !void {
    const name_string = try core.string.String.createUtf8(rt, name);
    const name_value = name_string.value();
    defer name_value.free(rt);
    try defineFunctionData(rt, function_object, "name", name_value, false, false, true);
}

test "sourceFunction roots function and source while attaching source text" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.RealmContext.create(rt);
    defer ctx.destroy();

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

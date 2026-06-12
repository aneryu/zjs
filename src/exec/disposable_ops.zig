const std = @import("std");
const core = @import("../core/root.zig");
const bytecode = @import("../bytecode/root.zig");
const frame_mod = @import("frame.zig");
const exception_ops = @import("vm_exception_ops.zig");

const call_runtime = @import("call_runtime.zig");
const object_ops = @import("object_ops.zig");
const constructorPrototypeFromGlobal = object_ops.constructorPrototypeFromGlobal;
const callValueOrBytecode = call_runtime.callValueOrBytecode;
const objectFromValue = object_ops.objectFromValue;
const isCallableValue = call_runtime.isCallableValue;
const getValueProperty = object_ops.getValueProperty;
const createNamedError = exception_ops.createNamedError;
const qjsDisposableStackConstructWithPrototype = object_ops.qjsDisposableStackConstructWithPrototype;
const qjsSuppressedErrorConstructWithPrototype = object_ops.qjsSuppressedErrorConstructWithPrototype;

pub const DisposableStackMethod = enum(u8) {
    use = 1,
    adopt = 2,
    defer_ = 3,
    dispose = 4,
    move = 5,
    disposed_get = 6,
};

pub fn disposableStackMethodFromMarker(marker: u8) ?DisposableStackMethod {
    return switch (marker) {
        @intFromEnum(DisposableStackMethod.use) => .use,
        @intFromEnum(DisposableStackMethod.adopt) => .adopt,
        @intFromEnum(DisposableStackMethod.defer_) => .defer_,
        @intFromEnum(DisposableStackMethod.dispose) => .dispose,
        @intFromEnum(DisposableStackMethod.move) => .move,
        @intFromEnum(DisposableStackMethod.disposed_get) => .disposed_get,
        else => null,
    };
}

pub fn disposableStackReceiver(receiver: core.JSValue) !*core.Object {
    const object = objectFromValue(receiver) orelse return error.TypeError;
    if (object.class_id != core.class.ids.disposable_stack) return error.TypeError;
    return object;
}

pub fn parserDisposableStackReceiver(receiver: core.JSValue) !*core.Object {
    const object = objectFromValue(receiver) orelse return error.TypeError;
    if (object.class_id != core.class.ids.disposable_stack and
        object.class_id != core.class.ids.async_disposable_stack) return error.TypeError;
    return object;
}

pub fn qjsDisposableStackMethodCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    function_object: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    const marker = function_object.disposableStackMethod();
    if (marker == 0) return null;
    const method = disposableStackMethodFromMarker(marker) orelse return error.TypeError;
    const stack = try disposableStackReceiver(receiver);
    return switch (method) {
        .use => try qjsDisposableStackUse(ctx, output, global, stack, args, caller_function, caller_frame),
        .adopt => try qjsDisposableStackAdopt(ctx.runtime, stack, args),
        .defer_ => try qjsDisposableStackDefer(ctx.runtime, stack, args),
        .dispose => try qjsDisposableStackDispose(ctx, output, global, stack, caller_function, caller_frame),
        .move => try qjsDisposableStackMove(ctx, global, stack),
        .disposed_get => core.JSValue.boolean(stack.disposableStackDisposed()),
    };
}

pub fn qjsDisposableStackUse(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    if (stack.disposableStackDisposed()) return error.ReferenceError;
    const value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    if (value.isNull() or value.isUndefined()) return value.dup();
    if (!value.isObject()) return error.TypeError;

    const dispose_method = try getValueProperty(ctx, output, global, value, core.atom.ids.Symbol_dispose, caller_function, caller_frame);
    defer dispose_method.free(ctx.runtime);
    if (dispose_method.isNull() or dispose_method.isUndefined() or !isCallableValue(dispose_method)) return error.TypeError;
    try stack.appendDisposableResource(ctx.runtime, value, dispose_method, .use, false);
    return value.dup();
}

pub fn qjsDisposableStackAdopt(
    rt: *core.JSRuntime,
    stack: *core.Object,
    args: []const core.JSValue,
) !core.JSValue {
    if (stack.disposableStackDisposed()) return error.ReferenceError;
    const value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const on_dispose = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
    if (!isCallableValue(on_dispose)) return error.TypeError;
    try stack.appendDisposableResource(rt, value, on_dispose, .adopt, false);
    return value.dup();
}

pub fn qjsDisposableStackDefer(
    rt: *core.JSRuntime,
    stack: *core.Object,
    args: []const core.JSValue,
) !core.JSValue {
    if (stack.disposableStackDisposed()) return error.ReferenceError;
    const on_dispose = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    if (!isCallableValue(on_dispose)) return error.TypeError;
    try stack.appendDisposableResource(rt, core.JSValue.undefinedValue(), on_dispose, .defer_, false);
    return core.JSValue.undefinedValue();
}

pub fn qjsDisposableStackDispose(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *core.Object,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    return qjsDisposeDisposableStackResources(ctx, output, global, stack, null, caller_function, caller_frame);
}

pub fn qjsDisposableStackRecordDisposeError(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    pending_error: *?core.JSValue,
    thrown: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !void {
    if (pending_error.*) |suppressed| {
        var thrown_owned = true;
        errdefer if (thrown_owned) thrown.free(ctx.runtime);

        const combined = try qjsSuppressedErrorForDispose(ctx, output, global, thrown, suppressed, caller_function, caller_frame);
        thrown_owned = false;
        pending_error.* = combined;
        thrown.free(ctx.runtime);
        suppressed.free(ctx.runtime);
    } else {
        pending_error.* = thrown;
    }
}

pub fn qjsDisposeDisposableStackResources(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *core.Object,
    initial_error: ?core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    if (stack.disposableStackDisposed()) {
        if (initial_error) |value| {
            _ = ctx.throwValue(value.dup());
            return error.JSException;
        }
        return core.JSValue.undefinedValue();
    }
    stack.disposableStackDisposedSlot().* = true;

    var pending_error: ?core.JSValue = if (initial_error) |value| value.dup() else null;
    errdefer if (pending_error) |value| value.free(ctx.runtime);

    while (stack.popDisposableResource()) |resource| {
        defer resource.destroy(ctx.runtime);
        qjsDisposeResource(ctx, output, global, resource, caller_function, caller_frame) catch |err| {
            const thrown = try runtimeErrorValueForDisposableDispose(ctx, global, err);
            try qjsDisposableStackRecordDisposeError(ctx, output, global, &pending_error, thrown, caller_function, caller_frame);
        };
    }

    if (pending_error) |value| {
        pending_error = null;
        _ = ctx.throwValue(value);
        return error.JSException;
    }
    return core.JSValue.undefinedValue();
}

pub fn qjsUsingCreateDisposableStack(
    ctx: *core.JSContext,
    global: *core.Object,
) !core.JSValue {
    const prototype = constructorPrototypeFromGlobal(ctx.runtime, global, "DisposableStack");
    return qjsDisposableStackConstructWithPrototype(ctx, global, prototype);
}

pub fn qjsUsingAddSyncResource(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
) !core.JSValue {
    if (args.len < 2) return error.TypeError;
    const stack = try parserDisposableStackReceiver(args[0]);
    if (stack.disposableStackDisposed()) return error.ReferenceError;
    const value = args[1];
    if (value.isNull() or value.isUndefined()) return core.JSValue.undefinedValue();
    if (!value.isObject()) return error.TypeError;

    const dispose_method = try getValueProperty(ctx, output, global, value, core.atom.ids.Symbol_dispose, null, null);
    defer dispose_method.free(ctx.runtime);
    if (dispose_method.isNull() or dispose_method.isUndefined() or !isCallableValue(dispose_method)) return error.TypeError;
    try stack.appendDisposableResource(ctx.runtime, value, dispose_method, .use, false);
    return core.JSValue.undefinedValue();
}

pub fn qjsUsingDisposeSyncStack(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
) !core.JSValue {
    if (args.len < 1) return error.TypeError;
    const stack = try disposableStackReceiver(args[0]);
    return qjsDisposeDisposableStackResources(ctx, output, global, stack, null, null, null);
}

pub fn qjsUsingDisposeSyncStackForThrow(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
) !core.JSValue {
    if (args.len < 2) return error.TypeError;
    const stack = try disposableStackReceiver(args[0]);
    return qjsDisposeDisposableStackResources(ctx, output, global, stack, args[1], null, null);
}

pub fn qjsDisposeResource(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    resource: core.object.DisposableResource,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !void {
    const result = switch (resource.kind) {
        .use => try callValueOrBytecode(ctx, output, global, resource.value, resource.method, &.{}, caller_function, caller_frame),
        .adopt => try callValueOrBytecode(ctx, output, global, core.JSValue.undefinedValue(), resource.method, &.{resource.value}, caller_function, caller_frame),
        .defer_ => try callValueOrBytecode(ctx, output, global, core.JSValue.undefinedValue(), resource.method, &.{}, caller_function, caller_frame),
    };
    result.free(ctx.runtime);
}

pub fn runtimeErrorValueForDisposableDispose(
    ctx: *core.JSContext,
    global: *core.Object,
    err: anytype,
) !core.JSValue {
    if (exception_ops.pendingExceptionMatchesError(ctx, err)) return ctx.takeException();
    if (ctx.hasException()) ctx.clearException();
    const error_info = exception_ops.runtimeErrorInfo(err) orelse return err;
    return createNamedError(ctx.runtime, global, error_info.name, error_info.message);
}

pub fn qjsSuppressedErrorForDispose(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    error_value: core.JSValue,
    suppressed_value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const prototype = constructorPrototypeFromGlobal(ctx.runtime, global, "SuppressedError");
    const args = [_]core.JSValue{ error_value, suppressed_value };
    return qjsSuppressedErrorConstructWithPrototype(ctx, output, global, prototype, &args, caller_function, caller_frame);
}

pub fn qjsDisposableStackMove(
    ctx: *core.JSContext,
    global: *core.Object,
    stack: *core.Object,
) !core.JSValue {
    if (stack.disposableStackDisposed()) return error.ReferenceError;
    const prototype = constructorPrototypeFromGlobal(ctx.runtime, global, "DisposableStack");
    const moved = try core.Object.create(ctx.runtime, core.class.ids.disposable_stack, prototype);
    errdefer core.Object.destroyFromHeader(ctx.runtime, &moved.header);
    try moved.setFunctionRealmGlobalPtr(ctx.runtime, global);
    try stack.moveDisposableResourcesTo(ctx.runtime, moved);
    stack.disposableStackDisposedSlot().* = true;
    return moved.value();
}

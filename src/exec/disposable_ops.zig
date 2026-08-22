//! Explicit resource management: sync/async DisposableStack, parser `using`
//! orchestration helpers, iterator async-dispose, and suppressed errors.
//!
//! Payloads own registered resource values until this module moves or releases
//! them. Calls into user dispose callbacks keep realm/output/caller authority
//! explicit. Async disposal borrows Promise capability/settlement primitives
//! from `promise_ops`; `using_ops` supplies the bytecode-facing orchestration.

const std = @import("std");
const core = @import("../core/root.zig");
const bytecode = @import("../bytecode.zig");
const frame_mod = @import("frame.zig");
const exception_ops = @import("exception_ops.zig");

const builtin_glue = @import("builtin_glue.zig");
const call_runtime = @import("call_runtime.zig");
const object_ops = @import("object_ops.zig");
const promise_ops = @import("promise_ops.zig");
const PromiseCapabilityVm = promise_ops.PromiseCapabilityVm;
const callValueOrBytecodeRoot = call_runtime.callValueOrBytecodeRoot;
const constructorPrototypeFromGlobal = object_ops.constructorPrototypeFromGlobal;
const callValueOrBytecodeSyncInternal = call_runtime.callValueOrBytecodeSyncInternalOutlined;
const objectFromValue = object_ops.objectFromValue;
const isCallableValue = call_runtime.isCallableValue;
const getValueProperty = object_ops.getValueProperty;
const createPromiseResolvingPair = promise_ops.createPromiseResolvingPair;
const defaultPromiseCapability = promise_ops.defaultPromiseCapability;
const performPromiseThen = promise_ops.performPromiseThen;
const promiseDefaultConstructor = promise_ops.promiseDefaultConstructor;
const promiseErrorValue = exception_ops.promiseErrorValue;
const promisePrototypeFromGlobal = promise_ops.promisePrototypeFromGlobal;
const promiseRejectCapability = promise_ops.promiseRejectCapability;
const promiseResolveCapability = promise_ops.promiseResolveCapability;
const promiseStaticCall = promise_ops.promiseStaticCall;
const rejectedPromiseForRuntimeError = exception_ops.rejectedPromiseForRuntimeError;
const suppressedErrorConstructWithPrototype = object_ops.suppressedErrorConstructWithPrototype;

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

pub fn disposableStackMethodCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    function_object: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    const marker = function_object.disposableStackMethod();
    if (marker == 0) return null;
    const method = disposableStackMethodFromMarker(marker) orelse return error.TypeError;
    const stack = try disposableStackReceiver(receiver);
    return switch (method) {
        .use => try disposableStackUse(ctx, output, global, stack, args, caller_function, caller_frame),
        .adopt => try disposableStackAdopt(ctx.runtime, stack, args),
        .defer_ => try disposableStackDefer(ctx.runtime, stack, args),
        .dispose => try disposableStackDispose(ctx, output, global, stack, caller_function, caller_frame),
        .move => try disposableStackMove(ctx, global, stack),
        .disposed_get => core.JSValue.boolean(stack.disposableStackDisposed()),
    };
}

pub fn disposableStackUse(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    if (stack.disposableStackDisposed()) return error.ReferenceError;
    const value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    if (value.isNull() or value.isUndefined()) return value.dup();
    if (!value.isObject()) return error.TypeError;

    const dispose_method = try getValueProperty(ctx, output, global, value, core.atom.ids.Symbol_dispose, caller_function, caller_frame);
    defer dispose_method.free(ctx.runtime);
    if (dispose_method.isNull() or dispose_method.isUndefined() or !isCallableValue(dispose_method)) return error.TypeError;
    try stack.appendDisposableResource(ctx.runtime, value, dispose_method, .use, .sync, .direct);
    return value.dup();
}

pub fn disposableStackAdopt(
    rt: *core.JSRuntime,
    stack: *core.Object,
    args: []const core.JSValue,
) !core.JSValue {
    if (stack.disposableStackDisposed()) return error.ReferenceError;
    const value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const on_dispose = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
    if (!isCallableValue(on_dispose)) return error.TypeError;
    try stack.appendDisposableResource(rt, value, on_dispose, .adopt, .sync, .direct);
    return value.dup();
}

pub fn disposableStackDefer(
    rt: *core.JSRuntime,
    stack: *core.Object,
    args: []const core.JSValue,
) !core.JSValue {
    if (stack.disposableStackDisposed()) return error.ReferenceError;
    const on_dispose = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    if (!isCallableValue(on_dispose)) return error.TypeError;
    try stack.appendDisposableResource(rt, core.JSValue.undefinedValue(), on_dispose, .defer_, .sync, .direct);
    return core.JSValue.undefinedValue();
}

pub fn disposableStackDispose(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *core.Object,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    return disposeDisposableStackResources(ctx, output, global, stack, null, caller_function, caller_frame);
}

pub fn disposableStackRecordDisposeError(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    pending_error: *?core.JSValue,
    thrown: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !void {
    if (pending_error.*) |suppressed| {
        var thrown_owned = true;
        errdefer if (thrown_owned) thrown.free(ctx.runtime);

        const combined = try suppressedErrorForDispose(ctx, output, global, thrown, suppressed, caller_function, caller_frame);
        thrown_owned = false;
        pending_error.* = combined;
        thrown.free(ctx.runtime);
        suppressed.free(ctx.runtime);
    } else {
        pending_error.* = thrown;
    }
}

pub fn disposeDisposableStackResources(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *core.Object,
    initial_error: ?core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
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
        disposeResource(ctx, output, global, resource, caller_function, caller_frame) catch |err| {
            const thrown = try runtimeErrorValueForDisposableDispose(ctx, global, err);
            try disposableStackRecordDisposeError(ctx, output, global, &pending_error, thrown, caller_function, caller_frame);
        };
    }

    if (pending_error) |value| {
        pending_error = null;
        _ = ctx.throwValue(value);
        return error.JSException;
    }
    return core.JSValue.undefinedValue();
}

pub fn usingAddSyncResource(
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
    try stack.appendDisposableResource(ctx.runtime, value, dispose_method, .use, .sync, .direct);
    return core.JSValue.undefinedValue();
}

pub fn usingDisposeSyncStack(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
) !core.JSValue {
    if (args.len < 1) return error.TypeError;
    const stack = try parserDisposableStackReceiver(args[0]);
    return disposeDisposableStackResources(ctx, output, global, stack, null, null, null);
}

pub fn usingDisposeSyncStackForThrow(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
) !core.JSValue {
    if (args.len < 2) return error.TypeError;
    const stack = try parserDisposableStackReceiver(args[0]);
    return disposeDisposableStackResources(ctx, output, global, stack, args[1], null, null);
}

pub fn disposeResource(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    resource: core.object.DisposableResource,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !void {
    // AsyncDisposableStack awaits each result in promise continuations owned
    // by promise_ops. This helper is only the synchronous disposal algorithm.
    const result = switch (resource.kind) {
        .use => try callValueOrBytecodeSyncInternal(ctx, output, global, resource.value, resource.method, &.{}, caller_function, caller_frame),
        .adopt => try callValueOrBytecodeSyncInternal(ctx, output, global, core.JSValue.undefinedValue(), resource.method, &.{resource.value}, caller_function, caller_frame),
        .defer_ => try callValueOrBytecodeSyncInternal(ctx, output, global, core.JSValue.undefinedValue(), resource.method, &.{}, caller_function, caller_frame),
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
    return exception_ops.createNamedError(ctx, global, error_info.name, error_info.message);
}

pub fn suppressedErrorForDispose(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    error_value: core.JSValue,
    suppressed_value: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const prototype = constructorPrototypeFromGlobal(ctx.runtime, global, "SuppressedError");
    const args = [_]core.JSValue{ error_value, suppressed_value };
    return suppressedErrorConstructWithPrototype(ctx, output, global, prototype, &args, caller_function, caller_frame);
}

pub fn disposableStackMove(
    ctx: *core.JSContext,
    global: *core.Object,
    stack: *core.Object,
) !core.JSValue {
    if (stack.disposableStackDisposed()) return error.ReferenceError;
    const prototype = constructorPrototypeFromGlobal(ctx.runtime, global, "DisposableStack");
    const moved = try core.Object.create(ctx.runtime, core.class.ids.disposable_stack, prototype);
    errdefer core.Object.destroyFromHeader(ctx.runtime, &moved.header);
    try stack.moveDisposableResourcesTo(ctx.runtime, moved);
    stack.disposableStackDisposedSlot().* = true;
    return moved.value();
}

pub fn usingCreateAsyncDisposableStack(
    ctx: *core.JSContext,
    global: *core.Object,
) !core.JSValue {
    // Parser disposal capabilities are internal records, not observable
    // `AsyncDisposableStack` constructions. Keep the class payload/continuation
    // machinery while avoiding user-mutated constructor/prototype lookup.
    return asyncDisposableStackConstructWithPrototype(ctx, global, null);
}

pub fn usingAddAsyncResource(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
) !core.JSValue {
    if (args.len < 2) return error.TypeError;
    const stack = try asyncDisposableStackReceiver(args[0]);
    return asyncDisposableStackUse(ctx, output, global, stack, args[1..2], null, null);
}

pub fn usingDisposeAsyncStack(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
) !core.JSValue {
    if (args.len < 1) return error.TypeError;
    _ = try asyncDisposableStackReceiver(args[0]);
    return asyncDisposableStackDisposeAsync(ctx, output, global, args[0], null, null);
}

pub fn usingDisposeAsyncStackForThrow(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
) !core.JSValue {
    if (args.len < 2) return error.TypeError;
    var capability = try defaultPromiseCapability(ctx, output, global, null, null);
    errdefer capability.deinit(ctx.runtime);

    const stack = try asyncDisposableStackReceiver(args[0]);
    if (stack.disposableStackDisposed()) {
        try promiseRejectCapability(ctx, output, global, capability.reject, args[1], null, null);
        return capability.releaseCallbacks(ctx.runtime);
    }

    stack.disposableStackDisposedSlot().* = true;
    try asyncDisposableStackStoreCapability(stack, ctx.runtime, capability);
    try asyncDisposableStackContinueOrReject(ctx, output, global, stack, args[1], null, null);
    return capability.releaseCallbacks(ctx.runtime);
}

pub const AsyncDisposableStackMethod = enum(u8) {
    use = 1,
    adopt = 2,
    defer_ = 3,
    dispose_async = 4,
    move = 5,
    disposed_get = 6,
};

pub fn asyncDisposableStackMethodFromMarker(marker: u8) ?AsyncDisposableStackMethod {
    return switch (marker) {
        @intFromEnum(AsyncDisposableStackMethod.use) => .use,
        @intFromEnum(AsyncDisposableStackMethod.adopt) => .adopt,
        @intFromEnum(AsyncDisposableStackMethod.defer_) => .defer_,
        @intFromEnum(AsyncDisposableStackMethod.dispose_async) => .dispose_async,
        @intFromEnum(AsyncDisposableStackMethod.move) => .move,
        @intFromEnum(AsyncDisposableStackMethod.disposed_get) => .disposed_get,
        else => null,
    };
}

pub fn asyncDisposableStackConstructWithPrototype(
    ctx: *core.JSContext,
    _: *core.Object,
    prototype: ?*core.Object,
) !core.JSValue {
    const stack = try core.Object.create(ctx.runtime, core.class.ids.async_disposable_stack, prototype);
    errdefer core.Object.destroyFromHeader(ctx.runtime, &stack.header);
    return stack.value();
}

pub fn asyncDisposableStackReceiver(receiver: core.JSValue) !*core.Object {
    const object = objectFromValue(receiver) orelse return error.TypeError;
    if (object.class_id != core.class.ids.async_disposable_stack) return error.TypeError;
    return object;
}

pub fn asyncDisposableStackMethodCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    function_object: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    const marker = function_object.asyncDisposableStackMethod();
    if (marker == 0) return null;
    const method = asyncDisposableStackMethodFromMarker(marker) orelse return error.TypeError;
    if (method == .dispose_async) return try asyncDisposableStackDisposeAsync(ctx, output, global, receiver, caller_function, caller_frame);
    const stack = try asyncDisposableStackReceiver(receiver);
    return switch (method) {
        .use => try asyncDisposableStackUse(ctx, output, global, stack, args, caller_function, caller_frame),
        .adopt => try asyncDisposableStackAdopt(ctx.runtime, stack, args),
        .defer_ => try asyncDisposableStackDefer(ctx.runtime, stack, args),
        .move => try asyncDisposableStackMove(ctx, global, stack),
        .disposed_get => core.JSValue.boolean(stack.disposableStackDisposed()),
        .dispose_async => unreachable,
    };
}

pub fn asyncDisposableStackUse(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    if (stack.disposableStackDisposed()) return error.ReferenceError;
    const value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    if (value.isNull() or value.isUndefined()) {
        try stack.appendDisposableResource(ctx.runtime, core.JSValue.undefinedValue(), core.JSValue.undefinedValue(), .use, .async, .direct);
        return value.dup();
    }
    if (!value.isObject()) return error.TypeError;

    const async_dispose_method = try getValueProperty(ctx, output, global, value, core.atom.ids.Symbol_asyncDispose, caller_function, caller_frame);
    defer async_dispose_method.free(ctx.runtime);
    if (!async_dispose_method.isNull() and !async_dispose_method.isUndefined()) {
        if (!isCallableValue(async_dispose_method)) return error.TypeError;
        try stack.appendDisposableResource(ctx.runtime, value, async_dispose_method, .use, .async, .direct);
        return value.dup();
    }

    const dispose_method = try getValueProperty(ctx, output, global, value, core.atom.ids.Symbol_dispose, caller_function, caller_frame);
    defer dispose_method.free(ctx.runtime);
    if (dispose_method.isNull() or dispose_method.isUndefined() or !isCallableValue(dispose_method)) return error.TypeError;
    try stack.appendDisposableResource(ctx.runtime, value, dispose_method, .use, .async, .async_from_sync);
    return value.dup();
}

pub fn asyncDisposableStackAdopt(
    rt: *core.JSRuntime,
    stack: *core.Object,
    args: []const core.JSValue,
) !core.JSValue {
    if (stack.disposableStackDisposed()) return error.ReferenceError;
    const value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const on_dispose = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
    if (!isCallableValue(on_dispose)) return error.TypeError;
    try stack.appendDisposableResource(rt, value, on_dispose, .adopt, .async, .direct);
    return value.dup();
}

pub fn asyncDisposableStackDefer(
    rt: *core.JSRuntime,
    stack: *core.Object,
    args: []const core.JSValue,
) !core.JSValue {
    if (stack.disposableStackDisposed()) return error.ReferenceError;
    const on_dispose = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    if (!isCallableValue(on_dispose)) return error.TypeError;
    try stack.appendDisposableResource(rt, core.JSValue.undefinedValue(), on_dispose, .defer_, .async, .direct);
    return core.JSValue.undefinedValue();
}

pub fn asyncDisposableStackMove(
    ctx: *core.JSContext,
    global: *core.Object,
    stack: *core.Object,
) !core.JSValue {
    if (stack.disposableStackDisposed()) return error.ReferenceError;
    const prototype = constructorPrototypeFromGlobal(ctx.runtime, global, "AsyncDisposableStack");
    const moved = try core.Object.create(ctx.runtime, core.class.ids.async_disposable_stack, prototype);
    errdefer core.Object.destroyFromHeader(ctx.runtime, &moved.header);
    try stack.moveDisposableResourcesTo(ctx.runtime, moved);
    stack.disposableStackDisposedSlot().* = true;
    return moved.value();
}

pub fn asyncDisposableStackStoreCapability(stack: *core.Object, rt: *core.JSRuntime, capability: PromiseCapabilityVm) !void {
    const resolve = capability.resolve.dup();
    var resolve_owned = true;
    errdefer if (resolve_owned) resolve.free(rt);
    const reject = capability.reject.dup();
    var reject_owned = true;
    errdefer if (reject_owned) reject.free(rt);

    const resolve_slot = stack.disposableStackAsyncResolveSlot();
    const reject_slot = stack.disposableStackAsyncRejectSlot();

    stack.clearDisposableStackAsyncCapability(rt);
    resolve_slot.* = resolve;
    resolve_owned = false;
    reject_slot.* = reject;
    reject_owned = false;
}

pub fn asyncDisposableStackDisposeAsync(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    var capability = try defaultPromiseCapability(ctx, output, global, caller_function, caller_frame);
    errdefer capability.deinit(ctx.runtime);

    const stack = asyncDisposableStackReceiver(receiver) catch {
        const reason = try promiseErrorValue(ctx, global, error.TypeError);
        defer reason.free(ctx.runtime);
        try promiseRejectCapability(ctx, output, global, capability.reject, reason, caller_function, caller_frame);
        return capability.releaseCallbacks(ctx.runtime);
    };
    if (stack.disposableStackDisposed()) {
        try promiseResolveCapability(ctx, output, global, capability.resolve, core.JSValue.undefinedValue(), caller_function, caller_frame);
        return capability.releaseCallbacks(ctx.runtime);
    }

    stack.disposableStackDisposedSlot().* = true;
    try asyncDisposableStackStoreCapability(stack, ctx.runtime, capability);
    try asyncDisposableStackContinueOrReject(ctx, output, global, stack, null, caller_function, caller_frame);
    return capability.releaseCallbacks(ctx.runtime);
}

pub fn asyncDisposableStackContinuation(
    rt: *core.JSRuntime,
    global: *core.Object,
    stack: *core.Object,
    rejected: bool,
) !core.JSValue {
    const callback = try builtin_glue.createDataFunction(rt, global, "", 1);
    errdefer callback.free(rt);
    const callback_object = objectFromValue(callback) orelse return error.TypeError;
    try callback_object.setInternalCallableTag(rt, .async_disposable_stack_continuation);
    try callback_object.setOptionalValueSlot(rt, try callback_object.functionAsyncDisposeStackSlot(rt), stack.value().dup());
    (try callback_object.functionAsyncDisposeRejectedSlot(rt)).* = rejected;
    return callback;
}

pub fn asyncDisposableStackContinuationCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    function_object: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    const stack_value = function_object.functionAsyncDisposeStack() orelse return null;
    const stack = objectFromValue(stack_value) orelse return error.TypeError;
    if (stack.class_id != core.class.ids.async_disposable_stack) return error.TypeError;
    const rejected = function_object.functionAsyncDisposeRejected();
    const rejection = if (rejected) (if (args.len >= 1) args[0] else core.JSValue.undefinedValue()) else null;
    try asyncDisposableStackContinueOrReject(ctx, output, global, stack, rejection, caller_function, caller_frame);
    return core.JSValue.undefinedValue();
}

pub fn asyncDisposableStackContinueOrReject(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *core.Object,
    awaited_rejection: ?core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !void {
    asyncDisposableStackContinue(ctx, output, global, stack, awaited_rejection, caller_function, caller_frame) catch |err| {
        const reason = try promiseErrorValue(ctx, global, err);
        defer reason.free(ctx.runtime);
        try asyncDisposableStackRejectStored(ctx, output, global, stack, reason, caller_function, caller_frame);
    };
}

pub fn asyncDisposableStackContinue(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *core.Object,
    awaited_rejection: ?core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !void {
    if (awaited_rejection) |reason| {
        try asyncDisposableStackRecordError(ctx, output, global, stack, reason, caller_function, caller_frame);
    }

    while (stack.popDisposableResource()) |resource| {
        defer resource.destroy(ctx.runtime);
        const result = asyncDisposeResource(ctx, output, global, resource, caller_function, caller_frame) catch |err| {
            const thrown = try runtimeErrorValueForDisposableDispose(ctx, global, err);
            defer thrown.free(ctx.runtime);
            try asyncDisposableStackRecordError(ctx, output, global, stack, thrown, caller_function, caller_frame);
            continue;
        };
        defer result.free(ctx.runtime);
        if (resource.hint == .async) {
            try asyncDisposableStackAwaitValue(ctx, output, global, stack, result, caller_function, caller_frame);
            return;
        }
    }

    const pending_error_slot = stack.disposableStackAsyncErrorSlot();
    if (pending_error_slot.*) |reason| {
        try asyncDisposableStackRejectStored(ctx, output, global, stack, reason, caller_function, caller_frame);
        return;
    }
    try asyncDisposableStackResolveStored(ctx, output, global, stack, core.JSValue.undefinedValue(), caller_function, caller_frame);
}

pub fn asyncDisposeResource(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    resource: core.object.DisposableResource,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    if (resource.method.isUndefined()) return core.JSValue.undefinedValue();
    const result = switch (resource.kind) {
        .use => try callValueOrBytecodeRoot(ctx, output, global, resource.value, resource.method, &.{}, caller_function, caller_frame),
        .adopt => try callValueOrBytecodeRoot(ctx, output, global, core.JSValue.undefinedValue(), resource.method, &.{resource.value}, caller_function, caller_frame),
        .defer_ => try callValueOrBytecodeRoot(ctx, output, global, core.JSValue.undefinedValue(), resource.method, &.{}, caller_function, caller_frame),
    };
    if (resource.method_kind == .async_from_sync) {
        result.free(ctx.runtime);
        return core.JSValue.undefinedValue();
    }
    return result;
}

pub fn asyncDisposableStackAwaitValue(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *core.Object,
    value: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !void {
    const promise_constructor = try promiseDefaultConstructor(ctx, global);
    defer promise_constructor.free(ctx.runtime);
    const awaited = try promiseStaticCall(ctx, output, global, promise_constructor, &.{value}, .resolve, caller_function, caller_frame);
    defer awaited.free(ctx.runtime);

    const on_fulfilled = try asyncDisposableStackContinuation(ctx.runtime, global, stack, false);
    defer on_fulfilled.free(ctx.runtime);
    const on_rejected = try asyncDisposableStackContinuation(ctx.runtime, global, stack, true);
    defer on_rejected.free(ctx.runtime);

    // Same await-shaped internal attach as qjs js_async_function_resume
    // (quickjs.c:21268-21290): perform_promise_then, never a .then read.
    try performPromiseThen(ctx, output, global, awaited, on_fulfilled, on_rejected, core.JSValue.undefinedValue(), core.JSValue.undefinedValue());
}

pub fn asyncDisposableStackRecordError(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *core.Object,
    error_value: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !void {
    const slot = stack.disposableStackAsyncErrorSlot();
    if (slot.*) |suppressed| {
        const combined = try suppressedErrorForDispose(ctx, output, global, error_value, suppressed, caller_function, caller_frame);
        try stack.setOptionalValueSlot(ctx.runtime, slot, combined);
    } else {
        try stack.setOptionalValueSlot(ctx.runtime, slot, error_value.dup());
    }
}

pub fn asyncDisposableStackResolveStored(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *core.Object,
    value: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !void {
    const resolve_value = (stack.disposableStackAsyncResolveSlot().*) orelse return;
    const resolve = resolve_value.dup();
    defer resolve.free(ctx.runtime);
    try promiseResolveCapability(ctx, output, global, resolve, value, caller_function, caller_frame);
    stack.clearDisposableStackAsyncCapability(ctx.runtime);
}

pub fn asyncDisposableStackRejectStored(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *core.Object,
    reason: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !void {
    const reject_value = (stack.disposableStackAsyncRejectSlot().*) orelse return;
    const reject = reject_value.dup();
    defer reject.free(ctx.runtime);
    try promiseRejectCapability(ctx, output, global, reject, reason, caller_function, caller_frame);
    stack.clearDisposableStackAsyncCapability(ctx.runtime);
}

pub fn asyncIteratorAsyncDispose(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    function_object: *core.Object,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    if (!function_object.isAsyncIteratorAsyncDisposeFunction()) return null;

    const return_key = try ctx.runtime.internAtom("return");
    defer ctx.runtime.atoms.free(return_key);
    const return_method = getValueProperty(ctx, output, global, receiver, return_key, caller_function, caller_frame) catch |err| {
        return try rejectedPromiseForRuntimeError(ctx, global, err, promisePrototypeFromGlobal(ctx.runtime, global));
    };
    defer return_method.free(ctx.runtime);
    if (return_method.isUndefined() or return_method.isNull()) {
        return try core.promise.fulfilledWithPrototype(ctx, core.JSValue.undefinedValue(), promisePrototypeFromGlobal(ctx.runtime, global));
    }
    if (!isCallableValue(return_method)) {
        return try rejectedPromiseForRuntimeError(ctx, global, error.TypeError, promisePrototypeFromGlobal(ctx.runtime, global));
    }

    const result = callValueOrBytecodeRoot(ctx, output, global, receiver, return_method, &.{core.JSValue.undefinedValue()}, caller_function, caller_frame) catch |err| {
        return try rejectedPromiseForRuntimeError(ctx, global, err, promisePrototypeFromGlobal(ctx.runtime, global));
    };
    defer result.free(ctx.runtime);
    const result_object = objectFromValue(result) orelse {
        return try rejectedPromiseForRuntimeError(ctx, global, error.TypeError, promisePrototypeFromGlobal(ctx.runtime, global));
    };
    if (result_object.class_id == core.class.ids.promise) {
        // Adopt the (possibly pending) inner promise through a real reaction —
        // the dispose promise settles only when `.return()`'s promise does
        // (no in-VM draining/sleeping; jobs are host-pumped).
        const promise = try core.promise.constructWithPrototype(ctx, promisePrototypeFromGlobal(ctx.runtime, global));
        errdefer promise.free(ctx.runtime);
        const resolving = try createPromiseResolvingPair(ctx.runtime, global, promise);
        defer resolving.resolve.free(ctx.runtime);
        defer resolving.reject.free(ctx.runtime);
        try performPromiseThen(ctx, output, global, result, core.JSValue.undefinedValue(), core.JSValue.undefinedValue(), resolving.resolve, resolving.reject);
        return promise;
    }
    return try core.promise.fulfilledWithPrototype(ctx, core.JSValue.undefinedValue(), promisePrototypeFromGlobal(ctx.runtime, global));
}

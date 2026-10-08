//! Explicit resource management: sync/async DisposableStack, parser `using`
//! orchestration helpers, iterator async-dispose, and suppressed errors.
//!
//! Payloads own registered resource values until this module moves or releases
//! them. Calls into user dispose callbacks keep realm/output/caller authority
//! explicit. Async disposal borrows Promise capability/settlement primitives
//! from `promise_ops`; vm_opcodes supplies the bytecode-facing orchestration.

const std = @import("std");
const core = @import("../core/root.zig");
const bytecode = @import("../bytecode.zig");
const frame_mod = @import("frame.zig");
const exception_ops = @import("exception_ops.zig");

const builtin_glue = @import("builtin_glue.zig");
const builtin_dispatch = @import("builtin_dispatch.zig");
const HostError = exception_ops.HostError;
const call_runtime = @import("call_runtime.zig");
const object_ops = @import("object_ops.zig");
const promise_ops = @import("promise_ops.zig");
const PromiseCapabilityVm = promise_ops.PromiseCapabilityVm;
const callValueOrBytecodeRoot = call_runtime.callValueOrBytecodeRoot;
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
const promiseResolveStaticCall = promise_ops.promiseResolveStaticCall;
const rejectedPromiseForRuntimeError = exception_ops.rejectedPromiseForRuntimeError;
const suppressedErrorConstructWithPrototype = object_ops.suppressedErrorConstructWithPrototype;

pub const Method = core.host_function.builtin_method_ids.disposable.Method;

pub const internal_entries = [_]core.host_function.InternalEntry{
    disposableEntry("use", 1, .use),
    disposableEntry("adopt", 2, .adopt),
    disposableEntry("defer", 1, .defer_),
    disposableEntry("dispose", 0, .dispose),
    disposableEntry("move", 0, .move),
    disposableEntry("get disposed", 0, .disposed_get),
    disposableEntry("use", 1, .async_use),
    disposableEntry("adopt", 2, .async_adopt),
    disposableEntry("defer", 1, .async_defer),
    disposableEntry("disposeAsync", 0, .async_dispose_async),
    disposableEntry("move", 0, .async_move),
    disposableEntry("get disposed", 0, .async_disposed_get),
};

/// Record id of a DisposableStack (or, with `is_async`, AsyncDisposableStack)
/// prototype method, keyed by its property name.
pub fn prototypeMethodId(name: []const u8, is_async: bool) ?u32 {
    const method: Method = if (std.mem.eql(u8, name, "use"))
        if (is_async) .async_use else .use
    else if (std.mem.eql(u8, name, "adopt"))
        if (is_async) .async_adopt else .adopt
    else if (std.mem.eql(u8, name, "defer"))
        if (is_async) .async_defer else .defer_
    else if (std.mem.eql(u8, name, "move"))
        if (is_async) .async_move else .move
    else if (!is_async and std.mem.eql(u8, name, "dispose"))
        .dispose
    else if (is_async and std.mem.eql(u8, name, "disposeAsync"))
        .async_dispose_async
    else
        return null;
    return @intFromEnum(method);
}

fn disposableEntry(comptime name: []const u8, comptime length: u8, comptime method: Method) core.host_function.InternalEntry {
    const id: u32 = @intFromEnum(method);
    return .{
        .name = name,
        .length = length,
        .id = id,
        .magic = @intCast(id),
        .cproto = .generic_magic,
        .native_function = builtin_dispatch.genericMagicFunction(&disposableCall),
    };
}

/// Shared record handler for the `.disposable` domain. Receiver checks stay in
/// the bodies, so a method applied to a foreign receiver throws TypeError.
fn disposableCall(
    native_ctx: *core.JSContext,
    native_this: core.JSValue,
    native_args: []const core.JSValue,
    native_magic: i32,
) HostError!core.JSValue {
    const host_call = builtin_dispatch.nativeCall(native_ctx, native_this, native_args, native_magic) orelse return error.TypeError;
    const realm = try builtin_dispatch.callableRealm(host_call);
    const ctx = realm.realm;
    const global = realm.global;
    const output = host_call.output;
    const receiver = host_call.this_value;
    const args = host_call.args;
    const caller_function = builtin_dispatch.callerBytecode(host_call);
    const caller_frame = builtin_dispatch.callerFrame(host_call);
    const method = std.enums.fromInt(Method, host_call.magic) orelse return error.TypeError;
    return switch (method) {
        .use => disposableStackUse(ctx, output, global, try disposableStackReceiver(receiver), args, caller_function, caller_frame),
        .adopt => disposableStackAdopt(ctx.runtime, try disposableStackReceiver(receiver), args),
        .defer_ => disposableStackDefer(ctx.runtime, try disposableStackReceiver(receiver), args),
        .dispose => disposeDisposableStackResources(ctx, output, global, try disposableStackReceiver(receiver), null, caller_function, caller_frame),
        .move => disposableStackMoveWithClass(ctx, try disposableStackReceiver(receiver), core.class.ids.disposable_stack),
        .disposed_get => core.JSValue.boolean((try disposableStackReceiver(receiver)).disposableStackDisposed()),
        .async_use => asyncDisposableStackUse(ctx, output, global, try asyncDisposableStackReceiver(receiver), args, caller_function, caller_frame),
        .async_adopt => asyncDisposableStackAdopt(ctx.runtime, try asyncDisposableStackReceiver(receiver), args),
        .async_defer => asyncDisposableStackDefer(ctx.runtime, try asyncDisposableStackReceiver(receiver), args),
        .async_dispose_async => asyncDisposableStackDisposeAsync(ctx, output, global, receiver, caller_function, caller_frame),
        .async_move => disposableStackMoveWithClass(ctx, try asyncDisposableStackReceiver(receiver), core.class.ids.async_disposable_stack),
        .async_disposed_get => core.JSValue.boolean((try asyncDisposableStackReceiver(receiver)).disposableStackDisposed()),
    };
}

fn disposableStackReceiver(receiver: core.JSValue) !*core.Object {
    const object = objectFromValue(receiver) orelse return error.NotADisposableStack;
    if (object.class_id != core.class.ids.disposable_stack) return error.NotADisposableStack;
    return object;
}

pub fn parserDisposableStackReceiver(receiver: core.JSValue) !*core.Object {
    const object = objectFromValue(receiver) orelse return error.NotADisposableStack;
    if (object.class_id != core.class.ids.disposable_stack and
        object.class_id != core.class.ids.async_disposable_stack) return error.NotADisposableStack;
    return object;
}

fn disposableStackUse(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    if (stack.disposableStackDisposed()) return error.DisposableStackDisposed;
    const value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    if (value.is(.null_value) or value.is(.undefined_value)) return value;
    if (!value.is(.object)) return error.NotDisposable;

    const dispose_method = try getValueProperty(ctx, output, global, value, core.atom.ids.Symbol_dispose, caller_function, caller_frame);
    if (dispose_method.is(.null_value) or dispose_method.is(.undefined_value) or !isCallableValue(dispose_method)) return error.NotDisposable;
    try stack.appendDisposableResource(ctx.runtime, value, dispose_method, .use, .sync, .direct);
    return value;
}

fn disposableStackAdopt(
    rt: *core.JSRuntime,
    stack: *core.Object,
    args: []const core.JSValue,
) !core.JSValue {
    if (stack.disposableStackDisposed()) return error.DisposableStackDisposed;
    const value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const on_dispose = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
    if (!isCallableValue(on_dispose)) return error.NotAFunction;
    try stack.appendDisposableResource(rt, value, on_dispose, .adopt, .sync, .direct);
    return value;
}

fn disposableStackDefer(
    rt: *core.JSRuntime,
    stack: *core.Object,
    args: []const core.JSValue,
) !core.JSValue {
    if (stack.disposableStackDisposed()) return error.DisposableStackDisposed;
    const on_dispose = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    if (!isCallableValue(on_dispose)) return error.NotAFunction;
    try stack.appendDisposableResource(rt, core.JSValue.undefinedValue(), on_dispose, .defer_, .sync, .direct);
    return core.JSValue.undefinedValue();
}

fn disposableStackRecordDisposeError(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    pending_error: *?core.JSValue,
    thrown: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !void {
    if (pending_error.*) |suppressed| {
        const combined = try suppressedErrorForDispose(ctx, output, global, thrown, suppressed, caller_function, caller_frame);
        pending_error.* = combined;
    } else {
        pending_error.* = thrown;
    }
}

fn disposeDisposableStackResources(
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
            _ = ctx.throwValue(value);
            return error.JSException;
        }
        return core.JSValue.undefinedValue();
    }
    stack.disposableStackDisposedSlot().* = true;

    var pending_error: ?core.JSValue = initial_error;

    while (stack.popDisposableResource()) |resource| {
        disposeResource(ctx, output, global, resource, caller_function, caller_frame) catch |err| {
            const thrown = try runtimeErrorValueForDisposableDispose(ctx, global, err);
            try disposableStackRecordDisposeError(ctx, output, global, &pending_error, thrown, caller_function, caller_frame);
        };
    }

    if (pending_error) |value| {
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
    _ = try disposableStackUse(ctx, output, global, stack, args[1..2], null, null);
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

fn disposeResource(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    resource: core.object.DisposableResource,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !void {
    // AsyncDisposableStack awaits each result in the promise continuations
    // below. This helper is only the synchronous disposal algorithm.
    _ = switch (resource.kind) {
        .use => try callValueOrBytecodeSyncInternal(ctx, output, global, resource.value, resource.method, &.{}, caller_function, caller_frame),
        .adopt => try callValueOrBytecodeSyncInternal(ctx, output, global, core.JSValue.undefinedValue(), resource.method, &.{resource.value}, caller_function, caller_frame),
        .defer_ => try callValueOrBytecodeSyncInternal(ctx, output, global, core.JSValue.undefinedValue(), resource.method, &.{}, caller_function, caller_frame),
    };
}

fn runtimeErrorValueForDisposableDispose(
    ctx: *core.JSContext,
    global: *core.Object,
    err: anytype,
) !core.JSValue {
    // An interruption must keep unwinding: taking it as a value would let
    // disposal run further callbacks and rethrow it as a catchable error.
    if (ctx.exceptionIsUncatchable()) return err;
    if (exception_ops.pendingExceptionMatchesError(ctx, err)) return ctx.takeException();
    if (ctx.hasException()) ctx.clearException();
    const error_info = exception_ops.runtimeErrorInfo(err) orelse return err;
    return exception_ops.createSentinelError(ctx, global, err, error_info);
}

fn suppressedErrorForDispose(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    error_value: core.JSValue,
    suppressed_value: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const prototype = ctx.nativeErrorPrototypeObject(.suppressed_error) orelse return error.InvalidBuiltinRegistry;
    const args = [_]core.JSValue{ error_value, suppressed_value };
    return suppressedErrorConstructWithPrototype(ctx, output, global, prototype, &args, caller_function, caller_frame);
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

pub fn asyncDisposableStackConstructWithPrototype(
    ctx: *core.JSContext,
    _: *core.Object,
    prototype: ?*core.Object,
) !core.JSValue {
    const stack = try core.Object.create(ctx.runtime, core.class.ids.async_disposable_stack, prototype);
    errdefer core.Object.destroyFromHeader(ctx.runtime, stack.gcHeader());
    return stack.value();
}

fn asyncDisposableStackReceiver(receiver: core.JSValue) !*core.Object {
    const object = objectFromValue(receiver) orelse return error.NotADisposableStack;
    if (object.class_id != core.class.ids.async_disposable_stack) return error.NotADisposableStack;
    return object;
}

fn asyncDisposableStackUse(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    if (stack.disposableStackDisposed()) return error.DisposableStackDisposed;
    const value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    if (value.is(.null_value) or value.is(.undefined_value)) {
        try stack.appendDisposableResource(ctx.runtime, core.JSValue.undefinedValue(), core.JSValue.undefinedValue(), .use, .async, .direct);
        return value;
    }
    if (!value.is(.object)) return error.NotDisposable;

    const async_dispose_method = try getValueProperty(ctx, output, global, value, core.atom.ids.Symbol_asyncDispose, caller_function, caller_frame);
    if (!async_dispose_method.is(.null_value) and !async_dispose_method.is(.undefined_value)) {
        if (!isCallableValue(async_dispose_method)) return error.NotAFunction;
        try stack.appendDisposableResource(ctx.runtime, value, async_dispose_method, .use, .async, .direct);
        return value;
    }

    const dispose_method = try getValueProperty(ctx, output, global, value, core.atom.ids.Symbol_dispose, caller_function, caller_frame);
    if (dispose_method.is(.null_value) or dispose_method.is(.undefined_value) or !isCallableValue(dispose_method)) return error.NotDisposable;
    try stack.appendDisposableResource(ctx.runtime, value, dispose_method, .use, .async, .async_from_sync);
    return value;
}

fn asyncDisposableStackAdopt(
    rt: *core.JSRuntime,
    stack: *core.Object,
    args: []const core.JSValue,
) !core.JSValue {
    if (stack.disposableStackDisposed()) return error.DisposableStackDisposed;
    const value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const on_dispose = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
    if (!isCallableValue(on_dispose)) return error.NotAFunction;
    try stack.appendDisposableResource(rt, value, on_dispose, .adopt, .async, .direct);
    return value;
}

fn asyncDisposableStackDefer(
    rt: *core.JSRuntime,
    stack: *core.Object,
    args: []const core.JSValue,
) !core.JSValue {
    if (stack.disposableStackDisposed()) return error.DisposableStackDisposed;
    const on_dispose = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    if (!isCallableValue(on_dispose)) return error.NotAFunction;
    try stack.appendDisposableResource(rt, core.JSValue.undefinedValue(), on_dispose, .defer_, .async, .direct);
    return core.JSValue.undefinedValue();
}

/// DisposableStack / AsyncDisposableStack `move`: the two differ only in the
/// class id (and so the prototype) of the new stack.
noinline fn disposableStackMoveWithClass(
    ctx: *core.JSContext,
    stack: *core.Object,
    class_id: core.class.ClassId,
) !core.JSValue {
    if (stack.disposableStackDisposed()) return error.DisposableStackDisposed;
    const prototype = ctx.classPrototypeObject(class_id) orelse return error.InvalidBuiltinRegistry;
    const moved = try core.Object.create(ctx.runtime, class_id, prototype);
    errdefer core.Object.destroyFromHeader(ctx.runtime, moved.gcHeader());
    try stack.moveDisposableResourcesTo(ctx.runtime, moved);
    stack.disposableStackDisposedSlot().* = true;
    return moved.value();
}

fn asyncDisposableStackStoreCapability(stack: *core.Object, rt: *core.JSRuntime, capability: PromiseCapabilityVm) !void {
    const resolve = capability.resolve;
    const reject = capability.reject;

    const resolve_slot = stack.disposableStackAsyncResolveSlot();
    const reject_slot = stack.disposableStackAsyncRejectSlot();

    stack.clearDisposableStackAsyncCapability(rt);
    resolve_slot.* = resolve;
    reject_slot.* = reject;
    // Both slots live in the stack's payload; the capability functions are made
    // right here while the stack itself is typically already old.
    rt.gc.generationalBarrier(stack.gcHeader(), resolve.cycleMarkHeader());
    rt.gc.generationalBarrier(stack.gcHeader(), reject.cycleMarkHeader());
}

fn asyncDisposableStackDisposeAsync(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const capability = try defaultPromiseCapability(ctx, output, global, caller_function, caller_frame);

    const stack = asyncDisposableStackReceiver(receiver) catch {
        const reason = try exception_ops.createNamedError(ctx, global, "TypeError", "not an AsyncDisposableStack");
        try promiseRejectCapability(ctx, output, global, capability.reject, reason, caller_function, caller_frame);
        return capability.promise;
    };
    if (stack.disposableStackDisposed()) {
        try promiseResolveCapability(ctx, output, global, capability.resolve, core.JSValue.undefinedValue(), caller_function, caller_frame);
        return capability.promise;
    }

    stack.disposableStackDisposedSlot().* = true;
    try asyncDisposableStackStoreCapability(stack, ctx.runtime, capability);
    try asyncDisposableStackContinueOrReject(ctx, output, global, stack, null, caller_function, caller_frame);
    return capability.promise;
}

fn asyncDisposableStackContinuation(
    rt: *core.JSRuntime,
    global: *core.Object,
    stack: *core.Object,
    rejected: bool,
) !core.JSValue {
    const callback = try builtin_glue.createDataFunction(rt, global, "", 1);
    const callback_object = objectFromValue(callback) orelse return error.TypeError;
    try callback_object.setInternalCallableTag(rt, .async_disposable_stack_continuation);
    try callback_object.setOptionalValueSlot(rt, try callback_object.functionAsyncDisposeStackSlot(rt), stack.value());
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

fn asyncDisposableStackContinueOrReject(
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
        try asyncDisposableStackRejectStored(ctx, output, global, stack, reason, caller_function, caller_frame);
    };
}

fn asyncDisposableStackContinue(
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
    if (try asyncDisposableStackNextAwait(ctx, output, global, stack, caller_function, caller_frame)) |value| {
        return asyncDisposableStackAwaitValue(ctx, output, global, stack, value, caller_function, caller_frame);
    }
    const pending_error_slot = stack.disposableStackAsyncErrorSlot();
    if (pending_error_slot.*) |reason| {
        try asyncDisposableStackRejectStored(ctx, output, global, stack, reason, caller_function, caller_frame);
        return;
    }
    try asyncDisposableStackResolveStored(ctx, output, global, stack, core.JSValue.undefinedValue(), caller_function, caller_frame);
}

/// DisposeResources up to its next Await: dispose resources (recording
/// call failures) until one owes an Await, and return the value to await,
/// or null once every resource is disposed and nothing is owed.
fn asyncDisposableStackNextAwait(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *core.Object,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    // DisposeResources' needsAwait/hasAwaited. The only await that leaves
    // hasAwaited false is the `Await(undefined)` owed for null resources, and
    // it clears needsAwait, so needsAwait always restarts false here.
    var needs_await = false;
    const has_awaited = stack.disposableStackAsyncHasAwaitedSlot();
    while (stack.peekDisposableResource()) |resource| {
        if (resource.hint == .sync and needs_await and !has_awaited.*) return core.JSValue.undefinedValue();
        _ = stack.popDisposableResource();
        if (resource.method.is(.undefined_value)) {
            // `await using x = null` / `stack.use(null)`: nothing to call.
            needs_await = true;
            continue;
        }
        const result = asyncDisposeResource(ctx, output, global, resource, caller_function, caller_frame) catch |err| {
            const thrown = try runtimeErrorValueForDisposableDispose(ctx, global, err);
            if (resource.hint == .async and resource.method_kind == .async_from_sync) {
                // GetDisposeMethod's wrapper turns a throwing @@dispose into a
                // rejected promise (IfAbruptRejectPromise), which Dispose
                // then awaits: the error is observed one tick later.
                has_awaited.* = true;
                return try core.promise.rejectedWithPrototype(ctx, thrown, promisePrototypeFromGlobal(ctx.runtime, global));
            }
            try asyncDisposableStackRecordError(ctx, output, global, stack, thrown, caller_function, caller_frame);
            continue;
        };
        if (resource.hint == .async) {
            has_awaited.* = true;
            return result;
        }
    }
    if (needs_await and !has_awaited.*) return core.JSValue.undefinedValue();
    return null;
}

/// One step of an `await using` scope exit, driven by bytecode that awaits in
/// the running function itself (so each Await costs exactly the spec's ticks):
/// record `completion` (a body throw or a rejected await) if any, then return
/// the next value to await. Once every resource is disposed the step throws
/// the aggregated error, if any, or returns the stack object itself as the
/// "done" marker -- an internal object no resource can return.
pub fn usingAsyncDisposeStep(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *core.Object,
    completion: ?core.JSValue,
) !core.JSValue {
    if (completion) |thrown| try asyncDisposableStackRecordError(ctx, output, global, stack, thrown, null, null);
    if (try asyncDisposableStackNextAwait(ctx, output, global, stack, null, null)) |value| return value;
    const pending_error_slot = stack.disposableStackAsyncErrorSlot();
    if (pending_error_slot.*) |reason| {
        pending_error_slot.* = null;
        _ = ctx.throwValue(reason);
        return error.JSException;
    }
    return stack.value();
}

fn asyncDisposeResource(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    resource: core.object.DisposableResource,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    // The caller skips resources without a method.
    const result = switch (resource.kind) {
        .use => try callValueOrBytecodeRoot(ctx, output, global, resource.value, resource.method, &.{}, caller_function, caller_frame),
        .adopt => try callValueOrBytecodeRoot(ctx, output, global, core.JSValue.undefinedValue(), resource.method, &.{resource.value}, caller_function, caller_frame),
        .defer_ => try callValueOrBytecodeRoot(ctx, output, global, core.JSValue.undefinedValue(), resource.method, &.{}, caller_function, caller_frame),
    };
    if (resource.method_kind == .async_from_sync) {
        return core.JSValue.undefinedValue();
    }
    return result;
}

fn asyncDisposableStackAwaitValue(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *core.Object,
    value: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !void {
    const promise_constructor = try promiseDefaultConstructor(ctx, global);
    const awaited = try promiseResolveStaticCall(ctx, output, global, promise_constructor, &.{value}, caller_function, caller_frame);

    const on_fulfilled = try asyncDisposableStackContinuation(ctx.runtime, global, stack, false);
    const on_rejected = try asyncDisposableStackContinuation(ctx.runtime, global, stack, true);

    // Same await-shaped internal attach as qjs js_async_function_resume:
    // perform_promise_then, never a.then read.
    try performPromiseThen(ctx, awaited, on_fulfilled, on_rejected, core.JSValue.undefinedValue(), core.JSValue.undefinedValue());
}

fn asyncDisposableStackRecordError(
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
        try stack.setOptionalValueSlot(ctx.runtime, slot, error_value);
    }
}

fn asyncDisposableStackResolveStored(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *core.Object,
    value: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !void {
    const resolve = (stack.disposableStackAsyncResolveSlot().*) orelse return;
    try promiseResolveCapability(ctx, output, global, resolve, value, caller_function, caller_frame);
    stack.clearDisposableStackAsyncCapability(ctx.runtime);
}

fn asyncDisposableStackRejectStored(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *core.Object,
    reason: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !void {
    const reject = (stack.disposableStackAsyncRejectSlot().*) orelse return;
    try promiseRejectCapability(ctx, output, global, reject, reason, caller_function, caller_frame);
    stack.clearDisposableStackAsyncCapability(ctx.runtime);
}

pub fn asyncIteratorAsyncDispose(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const return_key = core.atom.ids.return_;
    const return_method = getValueProperty(ctx, output, global, receiver, return_key, caller_function, caller_frame) catch |err| {
        return try rejectedPromiseForRuntimeError(ctx, global, err, promisePrototypeFromGlobal(ctx.runtime, global));
    };
    if (return_method.is(.undefined_value) or return_method.is(.null_value)) {
        return try core.promise.fulfilledWithPrototype(ctx, core.JSValue.undefinedValue(), promisePrototypeFromGlobal(ctx.runtime, global));
    }
    if (!isCallableValue(return_method)) {
        return try rejectedPromiseForRuntimeError(ctx, global, error.NotAFunction, promisePrototypeFromGlobal(ctx.runtime, global));
    }

    const result = callValueOrBytecodeRoot(ctx, output, global, receiver, return_method, &.{core.JSValue.undefinedValue()}, caller_function, caller_frame) catch |err| {
        return try rejectedPromiseForRuntimeError(ctx, global, err, promisePrototypeFromGlobal(ctx.runtime, global));
    };
    // Steps 6.c-f: PromiseResolve(%Promise%, result) -- any value, thenables
    // adopted through their `then` -- and fulfil with undefined once it does.
    const promise_constructor = try promiseDefaultConstructor(ctx, global);
    const wrapper = promiseResolveStaticCall(ctx, output, global, promise_constructor, &.{result}, caller_function, caller_frame) catch |err| {
        return try rejectedPromiseForRuntimeError(ctx, global, err, promisePrototypeFromGlobal(ctx.runtime, global));
    };
    const promise = try core.promise.constructWithPrototype(ctx, promisePrototypeFromGlobal(ctx.runtime, global));
    const resolving = try createPromiseResolvingPair(ctx.runtime, global, promise);
    const unwrap = try promise_ops.asyncIteratorDisposeUnwrap(ctx.runtime, global);
    try performPromiseThen(ctx, wrapper, unwrap, core.JSValue.undefinedValue(), resolving.resolve, resolving.reject);
    return promise;
}

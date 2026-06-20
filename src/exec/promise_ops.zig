const std = @import("std");
const bytecode = @import("../bytecode/root.zig");
const core = @import("../core/root.zig");
const frontend = @import("../frontend/root.zig");
const call_mod = @import("call.zig");
const frame_mod = @import("frame.zig");
const property_ops = @import("property_ops.zig");
const zjs_vm = @import("zjs_vm.zig");
const stack_mod = @import("stack.zig");
const value_ops = @import("value_ops.zig");
const HostError = exceptions.HostError;
const rejectedPromiseForRuntimeError = exception_ops.rejectedPromiseForRuntimeError;
const qjsPromiseAggregateError = exception_ops.qjsPromiseAggregateError;
const qjsPromiseErrorValue = exception_ops.qjsPromiseErrorValue;
const runWithArgsState = zjs_vm.runWithArgsState;
const exceptions = @import("exceptions.zig");
const exception_ops = @import("vm_exception_ops.zig");

const call_runtime = @import("call_runtime.zig");
const array_ops = @import("array_ops.zig");
const builtin_glue = @import("builtin_glue.zig");
const coercion_ops = @import("coercion_ops.zig");
const disposable_ops = @import("disposable_ops.zig");
const forof_ops = @import("forof_ops.zig");
const object_ops = @import("object_ops.zig");
const string_ops = @import("string_ops.zig");
const AtomicsWaiter = call_runtime.AtomicsWaiter;
const ReflectConstructResolution = call_runtime.ReflectConstructResolution;
const ValueSliceRoot = array_ops.ValueSliceRoot;
const atomicsBufferObject = object_ops.atomicsBufferObject;
const atomicsElementBytes = call_runtime.atomicsElementBytes;
const atomicsLinkWaiter = call_runtime.atomicsLinkWaiter;
const atomicsMaskBits = call_runtime.atomicsMaskBits;
const atomicsReadBits = call_runtime.atomicsReadBits;
const atomicsReleaseWaiterKey = call_runtime.atomicsReleaseWaiterKey;
const atomicsRetainWaiterKey = call_runtime.atomicsRetainWaiterKey;
const atomicsTypedArray = array_ops.atomicsTypedArray;
const atomicsTypedArrayIsBigInt = array_ops.atomicsTypedArrayIsBigInt;
const atomicsValidateAccess = call_runtime.atomicsValidateAccess;
const atomicsValidateIndex = call_runtime.atomicsValidateIndex;
const atomicsWaitTimeoutMilliseconds = call_runtime.atomicsWaitTimeoutMilliseconds;
const atomicsWaiterIo = call_runtime.atomicsWaiterIo;
const atomicsWaiterKey = call_runtime.atomicsWaiterKey;
const boundFunctionArgs = call_runtime.boundFunctionArgs;
const cachedRealmObject = object_ops.cachedRealmObject;
const callValueOrBytecode = call_runtime.callValueOrBytecode;
const callableObjectFromValue = object_ops.callableObjectFromValue;
const closeIteratorFromVm = forof_ops.closeIteratorFromVm;
const closeIteratorFromVmImpl = forof_ops.closeIteratorFromVmImpl;
const constructDynamicFunctionFromSource = call_runtime.constructDynamicFunctionFromSource;
const constructValueOrBytecode = call_runtime.constructValueOrBytecode;
const constructorPrototypeFromGlobal = object_ops.constructorPrototypeFromGlobal;
const constructorPrototypeObject = object_ops.constructorPrototypeObject;
const createGeneratorObject = object_ops.createGeneratorObject;
const createIteratorResult = call_runtime.createIteratorResult;
const defineDataProperty = object_ops.defineDataProperty;
const defineValueProperty = object_ops.defineValueProperty;
const findForOfIteratorIndex = forof_ops.findForOfIteratorIndex;
const freeArgs = call_runtime.freeArgs;
const functionBytecodeFromValue = call_runtime.functionBytecodeFromValue;
const functionConstructorFromGlobal = builtin_glue.functionConstructorFromGlobal;
const functionPrototypeFromGlobal = object_ops.functionPrototypeFromGlobal;
const getIteratorMethod = call_runtime.getIteratorMethod;
const getValueProperty = object_ops.getValueProperty;
const isCallableValue = call_runtime.isCallableValue;
const isConstructorLike = call_runtime.isConstructorLike;
const objectFromValue = object_ops.objectFromValue;
const objectPrototypeFromGlobal = object_ops.objectPrototypeFromGlobal;
const objectRealmGlobal = object_ops.objectRealmGlobal;
const objectRestOwnKeys = object_ops.objectRestOwnKeys;
const pollGCSafePoint = call_runtime.pollGCSafePoint;
const processExpiredAtomicsWaiters = call_runtime.processExpiredAtomicsWaiters;
const proxyAwareOwnPropertyDescriptor = object_ops.proxyAwareOwnPropertyDescriptor;
const proxyTrapKeyValue = object_ops.proxyTrapKeyValue;
const qjsCreateBuiltinFunction = builtin_glue.qjsCreateBuiltinFunction;
const qjsDefineToStringTag = string_ops.qjsDefineToStringTag;
const qjsSuppressedErrorForDispose = disposable_ops.qjsSuppressedErrorForDispose;
const runNextOsRwHandler = call_runtime.runNextOsRwHandler;
const runNextOsTimer = call_runtime.runNextOsTimer;
const runtimeErrorValueForDisposableDispose = disposable_ops.runtimeErrorValueForDisposableDispose;
const setGeneratorResumeCompletionType = call_runtime.setGeneratorResumeCompletionType;
const storeRealmValue = builtin_glue.storeRealmValue;
const throwTypeErrorMessage = exception_ops.throwTypeErrorMessage;
const toBigIntBitsForAtomics = call_runtime.toBigIntBitsForAtomics;
const toInt32BitsForAtomics = call_runtime.toInt32BitsForAtomics;
const toNumberForAtomics = call_runtime.toNumberForAtomics;
const valueTruthy = coercion_ops.valueTruthy;

pub fn closeForAwaitIteratorForPendingError(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *const stack_mod.Stack,
) !void {
    const index = findForOfIteratorIndex(ctx.runtime, stack) catch return;
    const iterator_value = stack.values[index].dup();
    defer iterator_value.free(ctx.runtime);
    _ = property_ops.expectObject(iterator_value) catch return;

    const pending_exception = if (ctx.hasException()) ctx.takeException() else null;
    defer if (pending_exception) |value| value.free(ctx.runtime);
    closeIteratorFromVm(ctx, output, global, iterator_value) catch {};
    if (ctx.hasException()) ctx.clearException();
    if (pending_exception) |value| _ = ctx.throwValue(value.dup());
}

pub fn promisePrototypeFromGlobal(rt: *core.JSRuntime, global: *core.Object) ?*core.Object {
    if (global.cachedPromiseProto()) |prototype| return prototype;
    const promise_atom = rt.internAtom("Promise") catch return null;
    defer rt.atoms.free(promise_atom);
    const promise_value = global.getProperty(promise_atom);
    defer promise_value.free(rt);
    const promise_constructor = property_ops.expectObject(promise_value) catch return null;
    const prototype_value = promise_constructor.getProperty(core.atom.ids.prototype);
    defer prototype_value.free(rt);
    return property_ops.expectObject(prototype_value) catch null;
}

pub fn asyncFunctionPrototypeFromGlobal(rt: *core.JSRuntime, global: *core.Object) !?*core.Object {
    if (cachedRealmObject(global, .async_function_prototype)) |stored| return stored;

    const prototype = try core.Object.create(rt, core.class.ids.object, functionPrototypeFromGlobal(rt, global));
    const prototype_value = prototype.value();
    var prototype_value_owned = true;
    errdefer if (prototype_value_owned) prototype_value.free(rt);
    const constructor = try core.function.nativeFunction(rt, "AsyncFunction", 1);
    defer constructor.free(rt);
    const constructor_object = property_ops.expectObject(constructor) catch return error.TypeError;
    try constructor_object.setFunctionRealmGlobalPtr(rt, global);
    if (functionConstructorFromGlobal(rt, global)) |function_constructor| try constructor_object.setPrototype(rt, function_constructor);
    try constructor_object.defineOwnProperty(rt, core.atom.ids.prototype, core.Descriptor.data(prototype_value, false, false, false));
    try prototype.defineOwnProperty(rt, core.atom.ids.constructor, core.Descriptor.data(constructor_object.value(), false, false, true));
    try qjsDefineToStringTag(rt, prototype, "AsyncFunction");

    const constructor_value = constructor_object.value();
    try storeRealmValue(rt, global, .async_function_constructor, constructor_value);
    try storeRealmValue(rt, global, .async_function_prototype, prototype_value);
    prototype_value_owned = false;
    prototype_value.free(rt);
    return prototype;
}

pub fn asyncIteratorPrototypeFromGlobal(rt: *core.JSRuntime, global: *core.Object) !*core.Object {
    if (cachedRealmObject(global, .async_iterator_prototype)) |stored| return stored;
    const object = try core.Object.create(rt, core.class.ids.object, objectPrototypeFromGlobal(rt, global));
    var object_raw_owned = true;
    errdefer if (object_raw_owned) core.Object.destroyFromHeader(rt, &object.header);
    const method = try core.function.nativeFunction(rt, "[Symbol.asyncIterator]", 0);
    defer method.free(rt);
    const async_iterator_atom = core.atom.predefinedId("Symbol.asyncIterator", .symbol) orelse return error.TypeError;
    try object.defineOwnProperty(rt, async_iterator_atom, core.Descriptor.data(method, true, false, true));
    if (core.atom.predefinedId("Symbol.asyncDispose", .symbol)) |async_dispose_atom| {
        const dispose = try core.function.nativeFunction(rt, "[Symbol.asyncDispose]", 0);
        defer dispose.free(rt);
        const dispose_object = objectFromValue(dispose) orelse return error.TypeError;
        if (!dispose_object.addAsyncIteratorAsyncDisposeFunction()) return error.TypeError;
        try object.defineOwnProperty(rt, async_dispose_atom, core.Descriptor.data(dispose, true, false, true));
    }
    const value = object.value();
    object_raw_owned = false;
    defer value.free(rt);
    try storeRealmValue(rt, global, .async_iterator_prototype, value);
    return object;
}

pub fn asyncGeneratorPrototypeFromGlobal(rt: *core.JSRuntime, global: *core.Object) !*core.Object {
    if (cachedRealmObject(global, .async_generator_prototype)) |stored| return stored;
    const async_iterator_prototype = try asyncIteratorPrototypeFromGlobal(rt, global);
    const object = try core.Object.create(rt, core.class.ids.object, async_iterator_prototype);
    var object_raw_owned = true;
    errdefer if (object_raw_owned) core.Object.destroyFromHeader(rt, &object.header);
    try installAsyncGeneratorPrototypeProperties(rt, object);
    const value = object.value();
    object_raw_owned = false;
    defer value.free(rt);
    try storeRealmValue(rt, global, .async_generator_prototype, value);
    return object;
}

pub fn installAsyncGeneratorPrototypeProperties(rt: *core.JSRuntime, object: *core.Object) !void {
    try defineAsyncGeneratorDataMethod(rt, object, "next", 1);
    try defineAsyncGeneratorDataMethod(rt, object, "return", 1);
    try defineAsyncGeneratorDataMethod(rt, object, "throw", 1);

    const tag_atom = core.atom.predefinedId("Symbol.toStringTag", .symbol) orelse return error.TypeError;
    const tag = try value_ops.createStringValue(rt, "AsyncGenerator");
    defer tag.free(rt);
    try object.defineOwnProperty(rt, tag_atom, core.Descriptor.data(tag, false, false, true));
}

pub fn defineAsyncGeneratorDataMethod(rt: *core.JSRuntime, object: *core.Object, name: []const u8, length: i32) !void {
    const atom_id = try rt.internAtom(name);
    defer rt.atoms.free(atom_id);
    const method = try core.function.nativeFunction(rt, name, length);
    defer method.free(rt);
    const method_object = property_ops.expectObject(method) catch return error.TypeError;
    if (!method_object.addAsyncGeneratorPrototypeMethod()) return error.TypeError;
    try object.defineOwnProperty(rt, atom_id, core.Descriptor.data(method, true, false, true));
}

pub fn asyncGeneratorFunctionPrototypeFromGlobal(rt: *core.JSRuntime, global: *core.Object) !?*core.Object {
    if (cachedRealmObject(global, .async_generator_function_prototype)) |stored| return stored;
    const object = try core.Object.create(rt, core.class.ids.object, functionPrototypeFromGlobal(rt, global));
    const object_value = object.value();
    var object_value_owned = true;
    errdefer if (object_value_owned) object_value.free(rt);
    const constructor = try core.function.nativeFunction(rt, "AsyncGeneratorFunction", 1);
    defer constructor.free(rt);
    const constructor_object = property_ops.expectObject(constructor) catch return error.TypeError;
    try constructor_object.setFunctionRealmGlobalPtr(rt, global);
    if (functionConstructorFromGlobal(rt, global)) |function_constructor| try constructor_object.setPrototype(rt, function_constructor);
    try constructor_object.defineOwnProperty(rt, core.atom.ids.prototype, core.Descriptor.data(object_value, false, false, false));
    try object.defineOwnProperty(rt, core.atom.ids.constructor, core.Descriptor.data(constructor_object.value(), false, false, true));
    try storeRealmValue(rt, global, .async_generator_function_constructor, constructor_object.value());
    const async_generator_prototype = try asyncGeneratorPrototypeFromGlobal(rt, global);
    try object.defineOwnProperty(rt, core.atom.ids.prototype, core.Descriptor.data(async_generator_prototype.value(), false, false, true));
    try async_generator_prototype.defineOwnProperty(rt, core.atom.ids.constructor, core.Descriptor.data(object_value, false, false, true));
    try qjsDefineToStringTag(rt, object, "AsyncGeneratorFunction");
    try storeRealmValue(rt, global, .async_generator_function_prototype, object_value);
    object_value_owned = false;
    object_value.free(rt);
    return object;
}

pub fn qjsUsingCreateAsyncDisposableStack(
    ctx: *core.JSContext,
    global: *core.Object,
) !core.JSValue {
    const prototype = constructorPrototypeFromGlobal(ctx.runtime, global, "AsyncDisposableStack");
    return qjsAsyncDisposableStackConstructWithPrototype(ctx, global, prototype);
}

pub fn qjsUsingAddAsyncResource(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
) !core.JSValue {
    if (args.len < 2) return error.TypeError;
    const stack = try asyncDisposableStackReceiver(args[0]);
    return qjsAsyncDisposableStackUse(ctx, output, global, stack, args[1..2], null, null);
}

pub fn qjsUsingDisposeAsyncStack(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
) !core.JSValue {
    if (args.len < 1) return error.TypeError;
    _ = try asyncDisposableStackReceiver(args[0]);
    return qjsAsyncDisposableStackDisposeAsync(ctx, output, global, args[0], null, null);
}

pub fn qjsUsingDisposeAsyncStackForThrow(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
) !core.JSValue {
    if (args.len < 2) return error.TypeError;
    var capability = try qjsDefaultPromiseCapability(ctx, output, global, null, null);
    errdefer capability.deinit(ctx.runtime);

    const stack = try asyncDisposableStackReceiver(args[0]);
    if (stack.disposableStackDisposed()) {
        try qjsPromiseRejectCapability(ctx, output, global, capability.reject, args[1], null, null);
        return capability.releaseCallbacks(ctx.runtime);
    }

    stack.disposableStackDisposedSlot().* = true;
    try qjsAsyncDisposableStackStoreCapability(stack, ctx.runtime, capability);
    try qjsAsyncDisposableStackContinueOrReject(ctx, output, global, stack, args[1], null, null);
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

pub fn qjsAsyncDisposableStackConstructWithPrototype(
    ctx: *core.JSContext,
    global: *core.Object,
    prototype: ?*core.Object,
) !core.JSValue {
    const stack = try core.Object.create(ctx.runtime, core.class.ids.async_disposable_stack, prototype);
    errdefer core.Object.destroyFromHeader(ctx.runtime, &stack.header);
    try stack.setFunctionRealmGlobalPtr(ctx.runtime, global);
    return stack.value();
}

pub fn asyncDisposableStackReceiver(receiver: core.JSValue) !*core.Object {
    const object = objectFromValue(receiver) orelse return error.TypeError;
    if (object.class_id != core.class.ids.async_disposable_stack) return error.TypeError;
    return object;
}

pub fn qjsAsyncDisposableStackMethodCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    function_object: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    const marker = function_object.asyncDisposableStackMethod();
    if (marker == 0) return null;
    const method = asyncDisposableStackMethodFromMarker(marker) orelse return error.TypeError;
    if (method == .dispose_async) return try qjsAsyncDisposableStackDisposeAsync(ctx, output, global, receiver, caller_function, caller_frame);
    const stack = try asyncDisposableStackReceiver(receiver);
    return switch (method) {
        .use => try qjsAsyncDisposableStackUse(ctx, output, global, stack, args, caller_function, caller_frame),
        .adopt => try qjsAsyncDisposableStackAdopt(ctx.runtime, stack, args),
        .defer_ => try qjsAsyncDisposableStackDefer(ctx.runtime, stack, args),
        .move => try qjsAsyncDisposableStackMove(ctx, global, stack),
        .disposed_get => core.JSValue.boolean(stack.disposableStackDisposed()),
        .dispose_async => unreachable,
    };
}

pub fn qjsAsyncDisposableStackUse(
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
    if (value.isNull() or value.isUndefined()) {
        try stack.appendDisposableResource(ctx.runtime, core.JSValue.undefinedValue(), core.JSValue.undefinedValue(), .use, true);
        return value.dup();
    }
    if (!value.isObject()) return error.TypeError;

    const async_dispose_method = try getValueProperty(ctx, output, global, value, core.atom.ids.Symbol_asyncDispose, caller_function, caller_frame);
    defer async_dispose_method.free(ctx.runtime);
    if (!async_dispose_method.isNull() and !async_dispose_method.isUndefined()) {
        if (!isCallableValue(async_dispose_method)) return error.TypeError;
        try stack.appendDisposableResource(ctx.runtime, value, async_dispose_method, .use, true);
        return value.dup();
    }

    const dispose_method = try getValueProperty(ctx, output, global, value, core.atom.ids.Symbol_dispose, caller_function, caller_frame);
    defer dispose_method.free(ctx.runtime);
    if (dispose_method.isNull() or dispose_method.isUndefined() or !isCallableValue(dispose_method)) return error.TypeError;
    try stack.appendDisposableResource(ctx.runtime, value, dispose_method, .use, false);
    return value.dup();
}

pub fn qjsAsyncDisposableStackAdopt(
    rt: *core.JSRuntime,
    stack: *core.Object,
    args: []const core.JSValue,
) !core.JSValue {
    if (stack.disposableStackDisposed()) return error.ReferenceError;
    const value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const on_dispose = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
    if (!isCallableValue(on_dispose)) return error.TypeError;
    try stack.appendDisposableResource(rt, value, on_dispose, .adopt, true);
    return value.dup();
}

pub fn qjsAsyncDisposableStackDefer(
    rt: *core.JSRuntime,
    stack: *core.Object,
    args: []const core.JSValue,
) !core.JSValue {
    if (stack.disposableStackDisposed()) return error.ReferenceError;
    const on_dispose = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    if (!isCallableValue(on_dispose)) return error.TypeError;
    try stack.appendDisposableResource(rt, core.JSValue.undefinedValue(), on_dispose, .defer_, true);
    return core.JSValue.undefinedValue();
}

pub fn qjsAsyncDisposableStackMove(
    ctx: *core.JSContext,
    global: *core.Object,
    stack: *core.Object,
) !core.JSValue {
    if (stack.disposableStackDisposed()) return error.ReferenceError;
    const prototype = constructorPrototypeFromGlobal(ctx.runtime, global, "AsyncDisposableStack");
    const moved = try core.Object.create(ctx.runtime, core.class.ids.async_disposable_stack, prototype);
    errdefer core.Object.destroyFromHeader(ctx.runtime, &moved.header);
    try moved.setFunctionRealmGlobalPtr(ctx.runtime, global);
    try stack.moveDisposableResourcesTo(ctx.runtime, moved);
    stack.disposableStackDisposedSlot().* = true;
    return moved.value();
}

pub fn qjsDefaultPromiseCapability(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !PromiseCapabilityVm {
    const promise_constructor = try qjsPromiseDefaultConstructor(ctx, global);
    defer promise_constructor.free(ctx.runtime);
    return qjsPromiseCapability(ctx, output, global, promise_constructor, caller_function, caller_frame);
}

pub fn qjsPromiseResolveCapability(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    resolve_value: core.JSValue,
    value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !void {
    const result = try callValueOrBytecode(ctx, output, global, core.JSValue.undefinedValue(), resolve_value, &.{value}, caller_function, caller_frame);
    result.free(ctx.runtime);
}

pub fn qjsAsyncDisposableStackStoreCapability(stack: *core.Object, rt: *core.JSRuntime, capability: PromiseCapabilityVm) !void {
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

pub fn qjsAsyncDisposableStackDisposeAsync(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    var capability = try qjsDefaultPromiseCapability(ctx, output, global, caller_function, caller_frame);
    errdefer capability.deinit(ctx.runtime);

    const stack = asyncDisposableStackReceiver(receiver) catch {
        const reason = try qjsPromiseErrorValue(ctx, global, error.TypeError);
        defer reason.free(ctx.runtime);
        try qjsPromiseRejectCapability(ctx, output, global, capability.reject, reason, caller_function, caller_frame);
        return capability.releaseCallbacks(ctx.runtime);
    };
    if (stack.disposableStackDisposed()) {
        try qjsPromiseResolveCapability(ctx, output, global, capability.resolve, core.JSValue.undefinedValue(), caller_function, caller_frame);
        return capability.releaseCallbacks(ctx.runtime);
    }

    stack.disposableStackDisposedSlot().* = true;
    try qjsAsyncDisposableStackStoreCapability(stack, ctx.runtime, capability);
    try qjsAsyncDisposableStackContinueOrReject(ctx, output, global, stack, null, caller_function, caller_frame);
    return capability.releaseCallbacks(ctx.runtime);
}

pub fn qjsAsyncDisposableStackContinuation(
    rt: *core.JSRuntime,
    global: *core.Object,
    stack: *core.Object,
    rejected: bool,
) !core.JSValue {
    const callback = try qjsCreateBuiltinFunction(rt, global, "", 1);
    errdefer callback.free(rt);
    const callback_object = objectFromValue(callback) orelse return error.TypeError;
    try callback_object.setOptionalValueSlot(rt, callback_object.functionAsyncDisposeStackSlot(), stack.value().dup());
    callback_object.functionAsyncDisposeRejectedSlot().* = rejected;
    return callback;
}

pub fn qjsAsyncDisposableStackContinuationCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    function_object: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    const stack_value = function_object.functionAsyncDisposeStack() orelse return null;
    const stack = objectFromValue(stack_value) orelse return error.TypeError;
    if (stack.class_id != core.class.ids.async_disposable_stack) return error.TypeError;
    const rejected = function_object.functionAsyncDisposeRejected();
    const rejection = if (rejected) (if (args.len >= 1) args[0] else core.JSValue.undefinedValue()) else null;
    try qjsAsyncDisposableStackContinueOrReject(ctx, output, global, stack, rejection, caller_function, caller_frame);
    return core.JSValue.undefinedValue();
}

pub fn qjsAsyncDisposableStackContinueOrReject(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *core.Object,
    awaited_rejection: ?core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !void {
    qjsAsyncDisposableStackContinue(ctx, output, global, stack, awaited_rejection, caller_function, caller_frame) catch |err| {
        const reason = try qjsPromiseErrorValue(ctx, global, err);
        defer reason.free(ctx.runtime);
        try qjsAsyncDisposableStackRejectStored(ctx, output, global, stack, reason, caller_function, caller_frame);
    };
}

pub fn qjsAsyncDisposableStackContinue(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *core.Object,
    awaited_rejection: ?core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !void {
    if (awaited_rejection) |reason| {
        try qjsAsyncDisposableStackRecordError(ctx, output, global, stack, reason, caller_function, caller_frame);
    }

    while (stack.popDisposableResource()) |resource| {
        defer resource.destroy(ctx.runtime);
        const result = qjsAsyncDisposeResource(ctx, output, global, resource, caller_function, caller_frame) catch |err| {
            const thrown = try runtimeErrorValueForDisposableDispose(ctx, global, err);
            defer thrown.free(ctx.runtime);
            try qjsAsyncDisposableStackRecordError(ctx, output, global, stack, thrown, caller_function, caller_frame);
            continue;
        };
        defer result.free(ctx.runtime);
        if (resource.await_result) {
            try qjsAsyncDisposableStackAwaitValue(ctx, output, global, stack, result, caller_function, caller_frame);
            return;
        }
    }

    const pending_error_slot = stack.disposableStackAsyncErrorSlot();
    if (pending_error_slot.*) |reason| {
        try qjsAsyncDisposableStackRejectStored(ctx, output, global, stack, reason, caller_function, caller_frame);
        return;
    }
    try qjsAsyncDisposableStackResolveStored(ctx, output, global, stack, core.JSValue.undefinedValue(), caller_function, caller_frame);
}

pub fn qjsAsyncDisposeResource(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    resource: core.object.DisposableResource,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    if (resource.method.isUndefined()) return core.JSValue.undefinedValue();
    return switch (resource.kind) {
        .use => try callValueOrBytecode(ctx, output, global, resource.value, resource.method, &.{}, caller_function, caller_frame),
        .adopt => try callValueOrBytecode(ctx, output, global, core.JSValue.undefinedValue(), resource.method, &.{resource.value}, caller_function, caller_frame),
        .defer_ => try callValueOrBytecode(ctx, output, global, core.JSValue.undefinedValue(), resource.method, &.{}, caller_function, caller_frame),
    };
}

pub fn qjsAsyncDisposableStackAwaitValue(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *core.Object,
    value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !void {
    const promise_constructor = try qjsPromiseDefaultConstructor(ctx, global);
    defer promise_constructor.free(ctx.runtime);
    const awaited = try qjsPromiseStaticCall(ctx, output, global, promise_constructor, &.{value}, .resolve, caller_function, caller_frame);
    defer awaited.free(ctx.runtime);

    const on_fulfilled = try qjsAsyncDisposableStackContinuation(ctx.runtime, global, stack, false);
    defer on_fulfilled.free(ctx.runtime);
    const on_rejected = try qjsAsyncDisposableStackContinuation(ctx.runtime, global, stack, true);
    defer on_rejected.free(ctx.runtime);

    const then_atom = try ctx.runtime.internAtom("then");
    defer ctx.runtime.atoms.free(then_atom);
    const then_value = try getValueProperty(ctx, output, global, awaited, then_atom, caller_function, caller_frame);
    defer then_value.free(ctx.runtime);
    if (!isCallableValue(then_value)) return error.TypeError;
    const then_result = try callValueOrBytecode(ctx, output, global, awaited, then_value, &.{ on_fulfilled, on_rejected }, caller_function, caller_frame);
    then_result.free(ctx.runtime);
}

pub fn qjsAsyncDisposableStackRecordError(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *core.Object,
    error_value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !void {
    const slot = stack.disposableStackAsyncErrorSlot();
    if (slot.*) |suppressed| {
        const combined = try qjsSuppressedErrorForDispose(ctx, output, global, error_value, suppressed, caller_function, caller_frame);
        try stack.setOptionalValueSlot(ctx.runtime, slot, combined);
    } else {
        try stack.setOptionalValueSlot(ctx.runtime, slot, error_value.dup());
    }
}

pub fn qjsAsyncDisposableStackResolveStored(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *core.Object,
    value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !void {
    const resolve_value = (stack.disposableStackAsyncResolveSlot().*) orelse return;
    const resolve = resolve_value.dup();
    defer resolve.free(ctx.runtime);
    try qjsPromiseResolveCapability(ctx, output, global, resolve, value, caller_function, caller_frame);
    stack.clearDisposableStackAsyncCapability(ctx.runtime);
}

pub fn qjsAsyncDisposableStackRejectStored(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *core.Object,
    reason: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !void {
    const reject_value = (stack.disposableStackAsyncRejectSlot().*) orelse return;
    const reject = reject_value.dup();
    defer reject.free(ctx.runtime);
    try qjsPromiseRejectCapability(ctx, output, global, reject, reason, caller_function, caller_frame);
    stack.clearDisposableStackAsyncCapability(ctx.runtime);
}

pub fn qjsPromiseConstruct(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    constructor: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const executor = if (args.len >= 1) args[0] else return throwTypeErrorMessage(ctx, global, "not a function");
    if (!isCallableValue(executor)) return throwTypeErrorMessage(ctx, global, "not a function");
    const fallback_global = if (objectFromValue(constructor)) |constructor_object|
        objectRealmGlobal(constructor_object) orelse global
    else
        global;
    const prototype = (try constructorPrototypeObject(ctx.runtime, constructor)) orelse promisePrototypeFromGlobal(ctx.runtime, fallback_global);
    return qjsPromiseConstructWithPrototype(ctx, output, global, prototype, args, caller_function, caller_frame);
}

pub fn qjsPromiseConstructWithPrototype(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    prototype: ?*core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const executor = if (args.len >= 1) args[0] else return throwTypeErrorMessage(ctx, global, "not a function");
    if (!isCallableValue(executor)) return throwTypeErrorMessage(ctx, global, "not a function");
    const promise = try core.promise.constructWithPrototype(ctx.runtime, prototype);
    errdefer promise.free(ctx.runtime);

    const resolving = try createPromiseResolvingPair(ctx.runtime, global, promise);
    const resolve = resolving.resolve;
    defer resolve.free(ctx.runtime);
    const reject = resolving.reject;
    defer reject.free(ctx.runtime);
    const result = callValueOrBytecode(ctx, output, global, core.JSValue.undefinedValue(), executor, &.{ resolve, reject }, caller_function, caller_frame) catch |err| {
        const promise_object = objectFromValue(promise) orelse return err;
        var reason = promiseRejectionReason(ctx, global, err);
        defer reason.deinit(ctx.runtime);
        try qjsPromiseSettleValue(ctx, global, promise_object, reason.value, true);
        reason.commit(ctx);
        return promise;
    };
    result.free(ctx.runtime);
    return promise;
}

pub const PromiseResolvingPairVm = struct {
    resolve: core.JSValue,
    reject: core.JSValue,
};

pub fn createPromiseResolvingState(rt: *core.JSRuntime) !*core.Object {
    var state_val = core.JSValue.undefinedValue();
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &state_val },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    const state = try core.Object.create(rt, core.class.ids.object, null);
    state_val = state.value();
    errdefer state_val.free(rt);
    (try state.promiseAlreadyResolvedSlot(rt)).* = false;
    return state;
}

pub fn createPromiseResolvingPair(rt: *core.JSRuntime, global: *core.Object, promise: core.JSValue) !PromiseResolvingPairVm {
    var state_val = core.JSValue.undefinedValue();
    var resolve_val = core.JSValue.undefinedValue();
    var reject_val = core.JSValue.undefinedValue();

    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &state_val },
        .{ .value = &resolve_val },
        .{ .value = &reject_val },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    defer state_val.free(rt);
    defer resolve_val.free(rt);
    defer reject_val.free(rt);

    const state = try createPromiseResolvingState(rt);
    state_val = state.value();

    resolve_val = try createPromiseResolvingFunction(rt, global, promise, false, state);
    reject_val = try createPromiseResolvingFunction(rt, global, promise, true, state);

    return .{
        .resolve = resolve_val.dup(),
        .reject = reject_val.dup(),
    };
}

pub fn createPromiseResolvingFunction(rt: *core.JSRuntime, global: *core.Object, promise: core.JSValue, reject: bool, state: *core.Object) !core.JSValue {
    var rooted_promise = promise;
    var state_val = state.value();
    var function_val = core.JSValue.undefinedValue();
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &rooted_promise },
        .{ .value = &state_val },
        .{ .value = &function_val },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    function_val = try core.function.nativeFunction(rt, "", 1);
    errdefer function_val.free(rt);
    const object = objectFromValue(function_val) orelse return error.TypeError;
    try object.setFunctionRealmGlobalPtr(rt, global);
    if (functionPrototypeFromGlobal(rt, global)) |function_proto| {
        try object.setPrototype(rt, function_proto);
    }
    try object.setFunctionPromiseResolvingTarget(rt, rooted_promise.dup());
    try object.setFunctionPromiseResolvingState(rt, state_val.dup());
    object.functionPromiseResolvingRejectSlot().* = reject;
    return function_val;
}

test "createPromiseResolvingFunction roots promise and state while allocating function" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    const global = try zjs_vm.contextGlobal(ctx);

    const state = try createPromiseResolvingState(rt);
    var state_alive = true;
    defer if (state_alive) state.value().free(rt);
    const marker_key = try rt.internAtom("marker");
    defer rt.atoms.free(marker_key);
    const state_symbol = try rt.atoms.newValueSymbol("gc-qjs-promise-resolving-state-symbol");
    try state.defineOwnProperty(rt, marker_key, core.Descriptor.data(core.JSValue.symbol(state_symbol), true, true, true));

    const promise_symbol = try rt.atoms.newValueSymbol("gc-qjs-promise-resolving-target-symbol");
    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const function_value = try createPromiseResolvingFunction(rt, global, core.JSValue.symbol(promise_symbol), true, state);
    var function_alive = true;
    defer if (function_alive) function_value.free(rt);
    const function_object = objectFromValue(function_value) orelse return error.TypeError;

    try std.testing.expect(rt.atoms.name(promise_symbol) != null);
    try std.testing.expect(rt.atoms.name(state_symbol) != null);
    try std.testing.expect(function_object.functionPromiseResolvingTarget().?.same(core.JSValue.symbol(promise_symbol)));
    try std.testing.expect(function_object.functionPromiseResolvingRejectSlot().*);

    state.value().free(rt);
    state_alive = false;
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(promise_symbol) != null);
    try std.testing.expect(rt.atoms.name(state_symbol) != null);
    const stored_state_value = function_object.functionPromiseResolvingState() orelse return error.TypeError;
    const stored_state = objectFromValue(stored_state_value) orelse return error.TypeError;
    {
        const marker_value = stored_state.getProperty(marker_key);
        defer marker_value.free(rt);
        try std.testing.expect(marker_value.same(core.JSValue.symbol(state_symbol)));
    }

    function_value.free(rt);
    function_alive = false;
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(promise_symbol) == null);
    try std.testing.expect(rt.atoms.name(state_symbol) == null);
}

pub fn qjsAppendPromiseReaction(rt: *core.JSRuntime, promise: *core.Object, reaction: core.JSValue) !void {
    const current = promise.promiseReactions();
    const next = try rt.memory.alloc(core.JSValue, current.len + 1);
    errdefer rt.memory.free(core.JSValue, next);
    var rooted_next: []core.JSValue = next[0..0];
    var next_root = ValueSliceRoot{};
    next_root.init(rt, &rooted_next);
    defer next_root.deinit();

    @memcpy(next[0..current.len], current);
    rooted_next = next[0..current.len];
    next[current.len] = reaction.dup();
    rooted_next = next[0 .. current.len + 1];
    var reaction_owned = true;
    errdefer if (reaction_owned) {
        next[current.len].free(rt);
        next[current.len] = core.JSValue.undefinedValue();
        rooted_next = next[0..current.len];
    };
    reaction_owned = false;
    promise.promiseReactionsSlot().* = next;
    if (current.len != 0) rt.memory.free(core.JSValue, current);
}

pub fn qjsPromiseReactionRecord(
    rt: *core.JSRuntime,
    on_fulfilled: core.JSValue,
    on_rejected: core.JSValue,
    resolve: core.JSValue,
    reject: core.JSValue,
) !core.JSValue {
    var rooted_on_fulfilled = on_fulfilled;
    var rooted_on_rejected = on_rejected;
    var rooted_resolve = resolve;
    var rooted_reject = reject;
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &rooted_on_fulfilled },
        .{ .value = &rooted_on_rejected },
        .{ .value = &rooted_resolve },
        .{ .value = &rooted_reject },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    const record = try core.Object.create(rt, core.class.ids.object, null);
    errdefer core.Object.destroyFromHeader(rt, &record.header);
    try record.setPromiseReactionOnFulfilled(rt, rooted_on_fulfilled.dup());
    try record.setPromiseReactionOnRejected(rt, rooted_on_rejected.dup());
    try record.setPromiseReactionResolve(rt, rooted_resolve.dup());
    try record.setPromiseReactionReject(rt, rooted_reject.dup());
    return record.value();
}

test "qjsPromiseReactionRecord roots direct symbol fields while allocating slots" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const on_fulfilled_symbol = try rt.atoms.newValueSymbol("gc-reaction-on-fulfilled-symbol");
    const on_rejected_symbol = try rt.atoms.newValueSymbol("gc-reaction-on-rejected-symbol");
    const resolve_symbol = try rt.atoms.newValueSymbol("gc-reaction-resolve-symbol");
    const reject_symbol = try rt.atoms.newValueSymbol("gc-reaction-reject-symbol");
    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const record_value = try qjsPromiseReactionRecord(
        rt,
        core.JSValue.symbol(on_fulfilled_symbol),
        core.JSValue.symbol(on_rejected_symbol),
        core.JSValue.symbol(resolve_symbol),
        core.JSValue.symbol(reject_symbol),
    );
    var record_value_alive = true;
    defer if (record_value_alive) record_value.free(rt);
    const record = objectFromValue(record_value) orelse return error.TypeError;

    try std.testing.expect(rt.atoms.name(on_fulfilled_symbol) != null);
    try std.testing.expect(rt.atoms.name(on_rejected_symbol) != null);
    try std.testing.expect(rt.atoms.name(resolve_symbol) != null);
    try std.testing.expect(rt.atoms.name(reject_symbol) != null);
    try std.testing.expect(record.promiseReactionOnFulfilled().?.same(core.JSValue.symbol(on_fulfilled_symbol)));
    try std.testing.expect(record.promiseReactionOnRejected().?.same(core.JSValue.symbol(on_rejected_symbol)));
    try std.testing.expect(record.promiseReactionResolve().?.same(core.JSValue.symbol(resolve_symbol)));
    try std.testing.expect(record.promiseReactionReject().?.same(core.JSValue.symbol(reject_symbol)));

    record_value.free(rt);
    record_value_alive = false;
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(on_fulfilled_symbol) == null);
    try std.testing.expect(rt.atoms.name(on_rejected_symbol) == null);
    try std.testing.expect(rt.atoms.name(resolve_symbol) == null);
    try std.testing.expect(rt.atoms.name(reject_symbol) == null);
}

pub fn qjsPromiseReactionJob(
    rt: *core.JSRuntime,
    global: *core.Object,
    reaction: *core.Object,
    value: core.JSValue,
    rejected: bool,
) !core.JSValue {
    var reaction_value = reaction.value();
    var rooted_value = value;
    var job_val = core.JSValue.undefinedValue();
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &reaction_value },
        .{ .value = &rooted_value },
        .{ .value = &job_val },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    job_val = try qjsCreateBuiltinFunction(rt, global, "", 0);
    errdefer job_val.free(rt);
    const job_object = objectFromValue(job_val) orelse return error.TypeError;
    try job_object.setFunctionPromiseReactionRecord(rt, reaction_value.dup());
    try job_object.setFunctionPromiseReactionValue(rt, rooted_value.dup());
    job_object.functionPromiseReactionIsRejectedSlot().* = rejected;
    return job_val;
}

test "qjsPromiseReactionJob roots reaction and value while allocating job" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    const global = try zjs_vm.contextGlobal(ctx);

    const reaction = try core.Object.create(rt, core.class.ids.object, null);
    var reaction_alive = true;
    defer if (reaction_alive) reaction.value().free(rt);
    const marker_key = try rt.internAtom("marker");
    defer rt.atoms.free(marker_key);
    const reaction_symbol = try rt.atoms.newValueSymbol("gc-qjs-promise-reaction-record-symbol");
    try reaction.defineOwnProperty(rt, marker_key, core.Descriptor.data(core.JSValue.symbol(reaction_symbol), true, true, true));

    const value_symbol = try rt.atoms.newValueSymbol("gc-qjs-promise-reaction-value-symbol");
    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const job_value = try qjsPromiseReactionJob(rt, global, reaction, core.JSValue.symbol(value_symbol), true);
    var job_alive = true;
    defer if (job_alive) job_value.free(rt);
    const job_object = objectFromValue(job_value) orelse return error.TypeError;

    try std.testing.expect(rt.atoms.name(reaction_symbol) != null);
    try std.testing.expect(rt.atoms.name(value_symbol) != null);
    try std.testing.expect(job_object.functionPromiseReactionValue().?.same(core.JSValue.symbol(value_symbol)));
    try std.testing.expect(job_object.functionPromiseReactionIsRejectedSlot().*);

    reaction.value().free(rt);
    reaction_alive = false;
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(reaction_symbol) != null);
    try std.testing.expect(rt.atoms.name(value_symbol) != null);
    const stored_reaction_value = job_object.functionPromiseReactionRecord() orelse return error.TypeError;
    const stored_reaction = objectFromValue(stored_reaction_value) orelse return error.TypeError;
    {
        const marker_value = stored_reaction.getProperty(marker_key);
        defer marker_value.free(rt);
        try std.testing.expect(marker_value.same(core.JSValue.symbol(reaction_symbol)));
    }

    job_value.free(rt);
    job_alive = false;
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(reaction_symbol) == null);
    try std.testing.expect(rt.atoms.name(value_symbol) == null);
}

pub const PreparedPromiseReactionJobs = struct {
    jobs: []core.JSValue = &.{},
    initialized: usize = 0,

    pub fn rootSlice(self: *PreparedPromiseReactionJobs) core.runtime.ValueRootSlice {
        return .{ .mutable = &self.jobs };
    }

    pub fn deinit(self: *PreparedPromiseReactionJobs, rt: *core.JSRuntime) void {
        for (self.jobs[0..self.initialized]) |job| job.free(rt);
        if (self.jobs.len != 0) rt.memory.free(core.JSValue, self.jobs);
        self.* = .{};
    }

    pub fn commit(self: *PreparedPromiseReactionJobs, ctx: *core.JSContext, promise: *core.Object) void {
        const reactions = promise.promiseReactions();
        if (self.initialized == 0) return;

        promise.promiseReactionsSlot().* = &.{};
        for (reactions) |reaction| reaction.free(ctx.runtime);
        ctx.runtime.memory.free(core.JSValue, reactions);

        for (self.jobs[0..self.initialized]) |job| {
            const index = ctx.pending_promise_jobs.len;
            ctx.pending_promise_jobs = ctx.pending_promise_jobs.ptr[0 .. index + 1];
            ctx.pending_promise_jobs[index] = .{
                .sequence = ctx.runtime.nextJobSequence(),
                .value = job,
            };
        }

        ctx.runtime.memory.free(core.JSValue, self.jobs);
        self.* = .{};
    }
};

pub const PreparedPromiseReactionJobsRoot = struct {
    rt: ?*core.JSRuntime = null,
    slices: [1]core.runtime.ValueRootSlice = undefined,
    frame: core.runtime.ValueRootFrame = .{},

    pub fn init(self: *PreparedPromiseReactionJobsRoot, rt: *core.JSRuntime, prepared: *PreparedPromiseReactionJobs) void {
        self.rt = rt;
        self.slices[0] = prepared.rootSlice();
        self.frame = .{
            .previous = rt.active_value_roots,
            .slices = &self.slices,
        };
        rt.active_value_roots = &self.frame;
    }

    pub fn deinit(self: *PreparedPromiseReactionJobsRoot) void {
        const rt = self.rt orelse return;
        rt.active_value_roots = self.frame.previous;
        self.rt = null;
    }
};

test "prepared promise reaction jobs root exposes dynamic job slice" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const first_atom = try rt.atoms.newValueSymbol("gc-prepared-promise-job-root-first");
    const second_atom = try rt.atoms.newValueSymbol("gc-prepared-promise-job-root-second");
    const jobs = try rt.memory.alloc(core.JSValue, 2);
    jobs[0] = core.JSValue.symbol(first_atom);
    jobs[1] = core.JSValue.symbol(second_atom);
    var prepared = PreparedPromiseReactionJobs{
        .jobs = jobs,
        .initialized = 2,
    };
    defer prepared.deinit(rt);

    var prepared_root: PreparedPromiseReactionJobsRoot = .{};
    prepared_root.init(rt, &prepared);
    defer prepared_root.deinit();

    const Counter = struct {
        first_atom: u32,
        second_atom: u32,
        first_seen: bool = false,
        second_seen: bool = false,

        fn visitValue(context: *anyopaque, slot: *core.JSValue) core.runtime.RootTraceError!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (slot.asSymbolAtom()) |atom_id| {
                if (atom_id == self.first_atom) self.first_seen = true;
                if (atom_id == self.second_atom) self.second_seen = true;
            }
        }

        fn visitObject(context: *anyopaque, slot: *?*core.Object) core.runtime.RootTraceError!void {
            _ = context;
            _ = slot;
        }
    };

    var counter = Counter{
        .first_atom = first_atom,
        .second_atom = second_atom,
    };
    var visitor = core.runtime.RootVisitor{
        .context = &counter,
        .visit_value = Counter.visitValue,
        .visit_object = Counter.visitObject,
    };
    try rt.traceActiveRoots(&visitor);

    try std.testing.expect(counter.first_seen);
    try std.testing.expect(counter.second_seen);
}

pub fn qjsPreparePromiseReactionJobs(
    ctx: *core.JSContext,
    global: *core.Object,
    promise: *core.Object,
    value: core.JSValue,
    rejected: bool,
) !PreparedPromiseReactionJobs {
    const reactions = promise.promiseReactions();
    if (reactions.len == 0) return .{};
    var rooted_value = value;
    var rooted_prepared_jobs: []core.JSValue = &.{};
    var root_slices = [_]core.runtime.ValueRootSlice{
        .{ .mutable = &rooted_prepared_jobs },
    };
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &rooted_value },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = ctx.runtime.active_value_roots,
        .slices = &root_slices,
        .values = &root_values,
    };
    ctx.runtime.active_value_roots = &root_frame;
    defer ctx.runtime.active_value_roots = root_frame.previous;

    const jobs = try ctx.runtime.memory.alloc(core.JSValue, reactions.len);
    var prepared = PreparedPromiseReactionJobs{ .jobs = jobs };
    errdefer prepared.deinit(ctx.runtime);

    for (reactions) |reaction_value| {
        const reaction = objectFromValue(reaction_value) orelse return error.TypeError;
        prepared.jobs[prepared.initialized] = try qjsPromiseReactionJob(ctx.runtime, global, reaction, rooted_value, rejected);
        prepared.initialized += 1;
        rooted_prepared_jobs = prepared.jobs[0..prepared.initialized];
    }

    try ctx.ensurePendingPromiseJobCapacity(ctx.pending_promise_jobs.len + prepared.initialized);
    return prepared;
}

pub fn qjsQueuePromiseReactions(
    ctx: *core.JSContext,
    global: *core.Object,
    promise: *core.Object,
    value: core.JSValue,
    rejected: bool,
) !void {
    var prepared = try qjsPreparePromiseReactionJobs(ctx, global, promise, value, rejected);
    errdefer prepared.deinit(ctx.runtime);
    var prepared_root: PreparedPromiseReactionJobsRoot = .{};
    prepared_root.init(ctx.runtime, &prepared);
    defer prepared_root.deinit();
    prepared.commit(ctx, promise);
}

pub fn qjsPromiseSettleValue(
    ctx: *core.JSContext,
    global: *core.Object,
    promise: *core.Object,
    value: core.JSValue,
    rejected: bool,
) !void {
    const had_reactions = promise.promiseReactions().len != 0;
    const needs_callback_job = promise.promiseReactionCallback() != null and promise.promiseReactionArg() == null;
    var prepared_reactions = try qjsPreparePromiseReactionJobs(ctx, global, promise, value, rejected);
    errdefer prepared_reactions.deinit(ctx.runtime);
    var prepared_root: PreparedPromiseReactionJobsRoot = .{};
    prepared_root.init(ctx.runtime, &prepared_reactions);
    defer prepared_root.deinit();
    if (needs_callback_job) {
        try ctx.ensurePendingPromiseJobCapacity(ctx.pending_promise_jobs.len + prepared_reactions.initialized + 1);
    }

    const next_result = value.dup();
    var next_result_owned = true;
    errdefer if (next_result_owned) next_result.free(ctx.runtime);
    const result_slot = promise.promiseResultSlot();

    var next_reaction_arg: ?core.JSValue = null;
    errdefer if (next_reaction_arg) |reaction_arg| reaction_arg.free(ctx.runtime);
    const reaction_arg_slot = promise.promiseReactionArgSlot();
    if (needs_callback_job) {
        next_reaction_arg = value.dup();
        try enqueuePendingPromiseJob(ctx, promise.value());
    }

    const old_result = result_slot.*;
    result_slot.* = next_result;
    next_result_owned = false;
    promise.promiseIsRejectedSlot().* = rejected;
    if (old_result) |stored| stored.free(ctx.runtime);
    if (next_reaction_arg) |reaction_arg| {
        const old_reaction_arg = reaction_arg_slot.*;
        reaction_arg_slot.* = reaction_arg;
        next_reaction_arg = null;
        if (old_reaction_arg) |stored| stored.free(ctx.runtime);
    }
    prepared_reactions.commit(ctx, promise);

    if (rejected and !had_reactions and ctx.track_unhandled_rejections) {
        ctx.recordUnhandledPromiseRejection(promise.value(), value);
    }
}

test "qjsPromiseSettleValue handles result self-assignment" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const global = try core.Object.create(rt, core.class.ids.object, null);
    defer global.value().free(rt);
    const promise = try core.Object.create(rt, core.class.ids.promise, null);
    defer promise.value().free(rt);
    const result = try core.Object.create(rt, core.class.ids.object, null);

    try promise.setPromiseResult(rt, result.value().dup());
    result.value().free(rt);
    try std.testing.expectEqual(@as(i32, 1), result.header.rc);

    const current = promise.promiseResult().?;
    try qjsPromiseSettleValue(ctx, global, promise, current, false);

    try std.testing.expectEqual(@as(i32, 1), result.header.rc);
    try std.testing.expectEqual(&result.header, promise.promiseResult().?.refHeader().?);
}

test "qjsPromiseSettleValue roots direct symbol result while preparing reaction jobs" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    const ctx = try core.JSContext.create(rt);
    const global = try core.Object.create(rt, core.class.ids.object, null);
    const promise = try core.Object.create(rt, core.class.ids.promise, null);
    defer {
        promise.value().free(rt);
        global.value().free(rt);
        ctx.destroy();
        rt.destroy();
    }

    const reaction = try qjsPromiseReactionRecord(rt, core.JSValue.undefinedValue(), core.JSValue.undefinedValue(), core.JSValue.undefinedValue(), core.JSValue.undefinedValue());
    try qjsAppendPromiseReaction(rt, promise, reaction);
    reaction.free(rt);

    const symbol_atom = try rt.atoms.newValueSymbol("gc-promise-settle-result-symbol");
    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);
    try qjsPromiseSettleValue(ctx, global, promise, core.JSValue.symbol(symbol_atom), false);

    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    const result = promise.promiseResult() orelse return error.TypeError;
    try std.testing.expect(result.same(core.JSValue.symbol(symbol_atom)));
    try std.testing.expectEqual(@as(usize, 1), ctx.pending_promise_jobs.len);
    const job_object = objectFromValue(ctx.pending_promise_jobs[0].value) orelse return error.TypeError;
    const job_value = job_object.functionPromiseReactionValue() orelse return error.TypeError;
    try std.testing.expect(job_value.same(core.JSValue.symbol(symbol_atom)));

    var pending_job = ctx.takePendingPromiseJob() orelse return error.TypeError;
    pending_job.deinit(rt);
    try promise.setPromiseResult(rt, null);
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

pub fn qjsPromiseResolvingFunctionCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    function_object: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    const target_value = function_object.functionPromiseResolvingTarget() orelse return null;
    const target = objectFromValue(target_value) orelse return core.JSValue.undefinedValue();
    if (target.class_id != core.class.ids.promise) return core.JSValue.undefinedValue();
    if (target.promiseResult() != null) return core.JSValue.undefinedValue();
    const state_value = function_object.functionPromiseResolvingState() orelse return error.TypeError;
    const state = objectFromValue(state_value) orelse return error.TypeError;
    if (state.promiseAlreadyResolved()) return core.JSValue.undefinedValue();
    (try state.promiseAlreadyResolvedSlot(ctx.runtime)).* = true;
    const reject = function_object.functionPromiseResolvingReject();
    const value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    if (!reject and value.sameValue(target_value)) {
        const error_value = if (objectRealmGlobal(function_object)) |error_global|
            try exception_ops.createNamedError(ctx, error_global, "TypeError", "")
        else
            try exception_ops.createNamedErrorWithConstructor(ctx, global, core.JSValue.undefinedValue(), "TypeError", "");
        defer error_value.free(ctx.runtime);
        try qjsPromiseSettleValue(ctx, global, target, error_value, true);
        return core.JSValue.undefinedValue();
    }
    if (!reject and value.isObject()) {
        if (objectFromValue(value)) |resolution_object| {
            if (resolution_object.class_id == core.class.ids.promise) {
                if (resolution_object.promiseResult()) |stored| {
                    try qjsPromiseSettleValue(ctx, global, target, stored, resolution_object.promiseIsRejected());
                    return core.JSValue.undefinedValue();
                }
                const then_key = try ctx.runtime.internAtom("then");
                defer ctx.runtime.atoms.free(then_key);
                const then_value = getValueProperty(ctx, output, global, value, then_key, caller_function, caller_frame) catch |err| {
                    var reason = promiseRejectionReason(ctx, global, err);
                    defer reason.deinit(ctx.runtime);
                    try qjsPromiseSettleValue(ctx, global, target, reason.value, true);
                    reason.commit(ctx);
                    return core.JSValue.undefinedValue();
                };
                defer then_value.free(ctx.runtime);
                if (isCallableValue(then_value)) {
                    const resolving = try createPromiseResolvingPair(ctx.runtime, global, target_value);
                    const resolve = resolving.resolve;
                    defer resolve.free(ctx.runtime);
                    const reject_value = resolving.reject;
                    defer reject_value.free(ctx.runtime);
                    const then_result = callValueOrBytecode(ctx, output, global, value, then_value, &.{ resolve, reject_value }, caller_function, caller_frame) catch |err| {
                        if (target.promiseResultSlot().* == null) {
                            var reason = promiseRejectionReason(ctx, global, err);
                            defer reason.deinit(ctx.runtime);
                            try qjsPromiseSettleValue(ctx, global, target, reason.value, true);
                            reason.commit(ctx);
                        }
                        return core.JSValue.undefinedValue();
                    };
                    then_result.free(ctx.runtime);
                    return core.JSValue.undefinedValue();
                }
                try qjsPromiseSettleValue(ctx, global, target, value, reject);
                return core.JSValue.undefinedValue();
            }

            const then_key = try ctx.runtime.internAtom("then");
            defer ctx.runtime.atoms.free(then_key);
            const then_value = getValueProperty(ctx, output, global, value, then_key, caller_function, caller_frame) catch |err| {
                var reason = promiseRejectionReason(ctx, global, err);
                defer reason.deinit(ctx.runtime);
                try qjsPromiseSettleValue(ctx, global, target, reason.value, true);
                reason.commit(ctx);
                return core.JSValue.undefinedValue();
            };
            defer then_value.free(ctx.runtime);
            if (isCallableValue(then_value)) {
                const thenable_job = try qjsPromiseThenableJob(ctx.runtime, global, target_value, value, then_value);
                defer thenable_job.free(ctx.runtime);
                try target.setPromiseReactionCallback(ctx.runtime, thenable_job.dup());
                try target.setPromiseReactionArg(ctx.runtime, null);
                return core.JSValue.undefinedValue();
            }
        }
    }
    try qjsPromiseSettleValue(ctx, global, target, value, reject);
    return core.JSValue.undefinedValue();
}

pub fn qjsPromiseThenableJob(rt: *core.JSRuntime, global: *core.Object, target_value: core.JSValue, thenable_value: core.JSValue, then_value: core.JSValue) !core.JSValue {
    var rooted_target_value = target_value;
    var rooted_thenable_value = thenable_value;
    var rooted_then_value = then_value;
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &rooted_target_value },
        .{ .value = &rooted_thenable_value },
        .{ .value = &rooted_then_value },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    const job = try qjsCreateBuiltinFunction(rt, global, "", 0);
    errdefer job.free(rt);
    const job_object = objectFromValue(job) orelse return error.TypeError;
    try job_object.setFunctionPromiseThenableTarget(rt, rooted_target_value.dup());
    try job_object.setFunctionPromiseThenableThis(rt, rooted_thenable_value.dup());
    try job_object.setFunctionPromiseThenableThen(rt, rooted_then_value.dup());
    return job;
}

test "qjsPromiseThenableJob roots direct function bytecode then callback while creating job" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const global = try core.Object.create(rt, core.class.ids.object, null);
    defer global.value().free(rt);
    const target = try core.Object.create(rt, core.class.ids.promise, null);
    defer target.value().free(rt);
    const thenable = try core.Object.create(rt, core.class.ids.object, null);
    defer thenable.value().free(rt);

    const fb_slice = try rt.memory.alloc(bytecode.FunctionBytecode, 1);
    const fb = &fb_slice[0];
    fb.* = bytecode.FunctionBytecode.init(&rt.memory, &rt.atoms, core.atom.ids.empty_string);
    fb.func_kind = .generator;
    try rt.gc.add(&fb.header);

    const symbol_atom = try rt.atoms.newValueSymbol("gc-promise-thenable-job-bytecode-symbol");
    fb.cpool = try rt.memory.alloc(core.JSValue, 1);
    fb.cpool[0] = core.JSValue.symbol(symbol_atom);
    fb.cpool_count = 1;

    var then_callback = core.JSValue.functionBytecode(&fb.header);
    var then_callback_alive = true;
    defer if (then_callback_alive) then_callback.free(rt);

    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const job = try qjsPromiseThenableJob(rt, global, target.value(), thenable.value(), then_callback);
    var job_alive = true;
    defer if (job_alive) job.free(rt);
    const job_object = objectFromValue(job) orelse return error.TypeError;

    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    const stored = job_object.functionPromiseThenableThen() orelse return error.TypeError;
    try std.testing.expect(stored.same(then_callback));

    job.free(rt);
    job_alive = false;
    then_callback.free(rt);
    then_callback_alive = false;
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

pub fn qjsPromiseThenableJobPending(callback: core.JSValue) bool {
    const callback_object = objectFromValue(callback) orelse return false;
    return callback_object.functionPromiseThenableTarget() != null;
}

pub fn qjsSettlePendingThenableJobs(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    promise: *core.Object,
) !void {
    while (promise.promiseResultSlot().* == null) {
        const callback = promise.promiseReactionCallback() orelse break;
        if (!qjsPromiseThenableJobPending(callback)) break;
        try settlePendingPromiseReaction(ctx, output, global, promise);
    }
}

pub fn qjsPromiseThenableJobCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    function_object: *core.Object,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    const target_value = function_object.functionPromiseThenableTarget() orelse return null;
    const thenable_value = function_object.functionPromiseThenableThis() orelse return error.TypeError;
    const then_value = function_object.functionPromiseThenableThen() orelse return error.TypeError;

    const resolving = try createPromiseResolvingPair(ctx.runtime, global, target_value);
    const resolve = resolving.resolve;
    defer resolve.free(ctx.runtime);
    const reject_value = resolving.reject;
    defer reject_value.free(ctx.runtime);

    const then_result = callValueOrBytecode(ctx, output, global, thenable_value, then_value, &.{ resolve, reject_value }, caller_function, caller_frame) catch |err| {
        const reason = try qjsPromiseErrorValue(ctx, global, err);
        defer reason.free(ctx.runtime);
        const reject_result = try callValueOrBytecode(ctx, output, global, core.JSValue.undefinedValue(), reject_value, &.{reason}, caller_function, caller_frame);
        reject_result.free(ctx.runtime);
        return core.JSValue.undefinedValue();
    };
    then_result.free(ctx.runtime);
    return core.JSValue.undefinedValue();
}

pub fn qjsPromiseReactionJobCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    function_object: *core.Object,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    const reaction_value = function_object.functionPromiseReactionRecord() orelse return null;
    const reaction = objectFromValue(reaction_value) orelse return error.TypeError;

    const payload = function_object.functionPromiseReactionValue() orelse core.JSValue.undefinedValue();
    const rejected = function_object.functionPromiseReactionIsRejected();
    const handler_value = if (rejected) reaction.promiseReactionOnRejected() else reaction.promiseReactionOnFulfilled();
    const handler = handler_value orelse core.JSValue.undefinedValue();

    const resolve_value = reaction.promiseReactionResolve() orelse return error.TypeError;
    const reject_value = reaction.promiseReactionReject() orelse return error.TypeError;

    if (!isCallableValue(handler)) {
        const settle = if (rejected) reject_value else resolve_value;
        const settle_result = try callValueOrBytecode(ctx, output, global, core.JSValue.undefinedValue(), settle, &.{payload}, caller_function, caller_frame);
        settle_result.free(ctx.runtime);
        return core.JSValue.undefinedValue();
    }

    const callback_result = callValueOrBytecode(ctx, output, global, core.JSValue.undefinedValue(), handler, &.{payload}, caller_function, caller_frame) catch |err| {
        const reason = try qjsPromiseErrorValue(ctx, global, err);
        defer reason.free(ctx.runtime);
        const reject_result = try callValueOrBytecode(ctx, output, global, core.JSValue.undefinedValue(), reject_value, &.{reason}, caller_function, caller_frame);
        reject_result.free(ctx.runtime);
        return core.JSValue.undefinedValue();
    };
    if (rejected) clearHandledRejectionException(ctx);
    defer callback_result.free(ctx.runtime);
    const resolve_result = try callValueOrBytecode(ctx, output, global, core.JSValue.undefinedValue(), resolve_value, &.{callback_result}, caller_function, caller_frame);
    resolve_result.free(ctx.runtime);
    return core.JSValue.undefinedValue();
}

pub const PromiseStaticMode = enum {
    resolve,
    all,
    all_keyed,
    race,
    reject,
    all_settled,
    all_settled_keyed,
    any,
    try_,
    with_resolvers,
};

pub const PromiseCombinatorMode = enum {
    all,
    race,
    all_settled,
    any,
};

pub const PromiseCombinatorCallbackMode = enum(u8) {
    all_resolve = 1,
    all_settled_fulfill = 2,
    all_settled_reject = 3,
    any_reject = 4,
    all_keyed_resolve = 5,
    all_settled_keyed_fulfill = 6,
    all_settled_keyed_reject = 7,
};

pub const PromiseCapabilityVm = struct {
    promise: core.JSValue,
    resolve: core.JSValue,
    reject: core.JSValue,

    pub fn deinit(self: PromiseCapabilityVm, rt: *core.JSRuntime) void {
        self.promise.free(rt);
        self.resolve.free(rt);
        self.reject.free(rt);
    }

    pub fn releaseCallbacks(self: PromiseCapabilityVm, rt: *core.JSRuntime) core.JSValue {
        self.resolve.free(rt);
        self.reject.free(rt);
        return self.promise;
    }
};

pub fn qjsPromiseCapabilityExecutorCall(ctx: *core.JSContext, function_object: *core.Object, args: []const core.JSValue) !?core.JSValue {
    const slot_value = function_object.functionPromiseCapabilitySlot() orelse return null;
    const slot = objectFromValue(slot_value) orelse return error.TypeError;
    const current_resolve = slot.promiseCapabilityResolve();
    const current_reject = slot.promiseCapabilityReject();
    if ((current_resolve != null and !current_resolve.?.isUndefined()) or
        (current_reject != null and !current_reject.?.isUndefined()))
    {
        return error.TypeError;
    }
    const resolve = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const reject = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
    try slot.setPromiseCapability(ctx.runtime, resolve.dup(), reject.dup());
    return core.JSValue.undefinedValue();
}

pub fn qjsPromiseCombinatorElementCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    function_object: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    const mode: PromiseCombinatorCallbackMode = switch (function_object.functionPromiseCombinatorMode()) {
        0 => return null,
        @intFromEnum(PromiseCombinatorCallbackMode.all_resolve) => .all_resolve,
        @intFromEnum(PromiseCombinatorCallbackMode.all_settled_fulfill) => .all_settled_fulfill,
        @intFromEnum(PromiseCombinatorCallbackMode.all_settled_reject) => .all_settled_reject,
        @intFromEnum(PromiseCombinatorCallbackMode.any_reject) => .any_reject,
        @intFromEnum(PromiseCombinatorCallbackMode.all_keyed_resolve) => .all_keyed_resolve,
        @intFromEnum(PromiseCombinatorCallbackMode.all_settled_keyed_fulfill) => .all_settled_keyed_fulfill,
        @intFromEnum(PromiseCombinatorCallbackMode.all_settled_keyed_reject) => .all_settled_keyed_reject,
        else => return error.TypeError,
    };

    if (function_object.functionPromiseCombinatorCalled()) return core.JSValue.undefinedValue();
    function_object.functionPromiseCombinatorCalledSlot().* = true;

    const state_value = function_object.functionPromiseCombinatorState() orelse return error.TypeError;
    const state = objectFromValue(state_value) orelse return error.TypeError;
    const values_value = state.promiseCombinatorValues() orelse return error.TypeError;
    const values = objectFromValue(values_value) orelse return error.TypeError;

    const index = function_object.functionPromiseCombinatorIndex();
    const payload = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();

    switch (mode) {
        .all_resolve, .all_keyed_resolve => try qjsPromiseSetArrayIndex(ctx.runtime, values, index, payload),
        .all_settled_fulfill, .all_settled_reject, .all_settled_keyed_fulfill, .all_settled_keyed_reject => {
            const rejected = mode == .all_settled_reject or mode == .all_settled_keyed_reject;
            const record = try qjsPromiseSettlementRecord(ctx.runtime, rejected, payload);
            defer record.free(ctx.runtime);
            try qjsPromiseSetArrayIndex(ctx.runtime, values, index, record);
        },
        .any_reject => try qjsPromiseSetArrayIndex(ctx.runtime, values, index, payload),
    }

    const remaining = state.promiseCombinatorRemaining();
    const next_remaining = remaining - 1;
    (try state.promiseCombinatorRemainingSlot(ctx.runtime)).* = next_remaining;
    if (next_remaining != 0) return core.JSValue.undefinedValue();

    const resolve_value = state.promiseCombinatorResolve() orelse return error.TypeError;
    const reject_value = state.promiseCombinatorReject() orelse return error.TypeError;
    switch (mode) {
        .all_resolve, .all_settled_fulfill, .all_settled_reject => {
            const result = callValueOrBytecode(ctx, output, global, core.JSValue.undefinedValue(), resolve_value, &.{values_value}, caller_function, caller_frame) catch |err| {
                const reason = try qjsPromiseErrorValue(ctx, global, err);
                defer reason.free(ctx.runtime);
                try qjsPromiseRejectCapability(ctx, output, global, reject_value, reason, caller_function, caller_frame);
                return core.JSValue.undefinedValue();
            };
            result.free(ctx.runtime);
        },
        .all_keyed_resolve, .all_settled_keyed_fulfill, .all_settled_keyed_reject => {
            const keys_value = state.promiseCombinatorKeys() orelse return error.TypeError;
            const keys = objectFromValue(keys_value) orelse return error.TypeError;
            const keyed_result = try qjsPromiseKeyedResult(ctx.runtime, keys, values);
            defer keyed_result.free(ctx.runtime);
            const result = callValueOrBytecode(ctx, output, global, core.JSValue.undefinedValue(), resolve_value, &.{keyed_result}, caller_function, caller_frame) catch |err| {
                const reason = try qjsPromiseErrorValue(ctx, global, err);
                defer reason.free(ctx.runtime);
                try qjsPromiseRejectCapability(ctx, output, global, reject_value, reason, caller_function, caller_frame);
                return core.JSValue.undefinedValue();
            };
            result.free(ctx.runtime);
        },
        .any_reject => {
            const aggregate_error = try qjsPromiseAggregateError(ctx, global, values);
            defer aggregate_error.free(ctx.runtime);
            const result = try callValueOrBytecode(ctx, output, global, core.JSValue.undefinedValue(), reject_value, &.{aggregate_error}, caller_function, caller_frame);
            result.free(ctx.runtime);
        },
    }
    return core.JSValue.undefinedValue();
}

pub fn qjsPromiseCapability(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    constructor_value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !PromiseCapabilityVm {
    var slot_value = core.JSValue.undefinedValue();
    var executor_value = core.JSValue.undefinedValue();
    var promise_value = core.JSValue.undefinedValue();
    var resolve_value = core.JSValue.undefinedValue();
    var reject_value = core.JSValue.undefinedValue();
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &slot_value },
        .{ .value = &executor_value },
        .{ .value = &promise_value },
        .{ .value = &resolve_value },
        .{ .value = &reject_value },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = ctx.runtime.active_value_roots,
        .values = &root_values,
    };
    ctx.runtime.active_value_roots = &root_frame;
    defer ctx.runtime.active_value_roots = root_frame.previous;

    defer slot_value.free(ctx.runtime);
    defer executor_value.free(ctx.runtime);
    defer promise_value.free(ctx.runtime);
    defer resolve_value.free(ctx.runtime);
    defer reject_value.free(ctx.runtime);

    const constructor_global = qjsPromiseConstructorRealmGlobal(constructor_value, global);
    const slot = try core.Object.create(ctx.runtime, core.class.ids.object, null);
    slot_value = slot.value();
    // Materialize the capability payload now, while an allocation failure
    // still surfaces as a plain OOM from NewPromiseCapability. The capability
    // executor runs inside the Promise constructor, where a failing store
    // would be spec-caught into a rejected promise and resurface as a
    // misleading "resolve is not callable" TypeError (found by test-oom
    // injection). With the payload preallocated the executor's stores are
    // allocation-free, mirroring QuickJS's js_promise_executor.
    _ = try slot.promiseCapabilityResolveSlot(ctx.runtime);
    _ = try slot.promiseCapabilityRejectSlot(ctx.runtime);

    executor_value = try qjsCreateBuiltinFunction(ctx.runtime, constructor_global, "", 2);
    const executor_object = objectFromValue(executor_value) orelse return error.TypeError;
    try executor_object.setFunctionPromiseCapabilitySlot(ctx.runtime, slot_value.dup());

    promise_value = try constructValueOrBytecode(ctx, output, global, constructor_value, &.{executor_value}, caller_function, caller_frame);

    resolve_value = if (slot.promiseCapabilityResolve()) |stored| stored.dup() else core.JSValue.undefinedValue();
    reject_value = if (slot.promiseCapabilityReject()) |stored| stored.dup() else core.JSValue.undefinedValue();
    if (!isCallableValue(resolve_value) or !isCallableValue(reject_value)) return error.TypeError;
    return .{
        .promise = promise_value.dup(),
        .resolve = resolve_value.dup(),
        .reject = reject_value.dup(),
    };
}

pub fn qjsPromiseSetArrayIndex(rt: *core.JSRuntime, array: *core.Object, index: u32, value: core.JSValue) !void {
    try property_ops.defineDataProperty(rt, array, core.atom.atomFromUInt32(index), value);
    if (array.arrayLength() <= index) array.setArrayLength(index + 1);
}

pub fn qjsPromiseKeyedResult(rt: *core.JSRuntime, keys: *core.Object, values: *core.Object) !core.JSValue {
    var keys_value = keys.value();
    var values_value = values.value();
    var result_value = core.JSValue.undefinedValue();
    var key_value = core.JSValue.undefinedValue();
    var value = core.JSValue.undefinedValue();
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &keys_value },
        .{ .value = &values_value },
        .{ .value = &result_value },
        .{ .value = &key_value },
        .{ .value = &value },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    const result = try core.Object.create(rt, core.class.ids.object, null);
    result_value = result.value();
    errdefer result_value.free(rt);
    result.flags.null_prototype = true;

    var index: u32 = 0;
    while (index < keys.arrayLength()) : (index += 1) {
        const index_atom = core.atom.atomFromUInt32(index);
        key_value = keys.getProperty(index_atom);
        defer {
            key_value.free(rt);
            key_value = core.JSValue.undefinedValue();
        }
        const key_atom = try property_ops.propertyKeyAtom(rt, key_value);
        defer rt.atoms.free(key_atom);
        value = values.getProperty(index_atom);
        defer {
            value.free(rt);
            value = core.JSValue.undefinedValue();
        }
        try property_ops.defineDataProperty(rt, result, key_atom, value);
    }
    return result_value;
}

test "qjsPromiseKeyedResult roots direct symbol values while defining keyed result" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const keys = try core.Object.createArray(rt, null);
    var keys_alive = true;
    defer if (keys_alive) keys.value().free(rt);
    const values = try core.Object.createArray(rt, null);
    var values_alive = true;
    defer if (values_alive) values.value().free(rt);

    const key_name = try value_ops.createStringValue(rt, "answer");
    defer key_name.free(rt);
    try qjsPromiseSetArrayIndex(rt, keys, 0, key_name);
    const value_symbol = try rt.atoms.newValueSymbol("gc-qjs-promise-keyed-result-symbol");
    try qjsPromiseSetArrayIndex(rt, values, 0, core.JSValue.symbol(value_symbol));

    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const result_value = try qjsPromiseKeyedResult(rt, keys, values);
    var result_alive = true;
    defer if (result_alive) result_value.free(rt);
    const result = objectFromValue(result_value) orelse return error.TypeError;

    try std.testing.expect(rt.atoms.name(value_symbol) != null);
    values.value().free(rt);
    values_alive = false;
    keys.value().free(rt);
    keys_alive = false;
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(value_symbol) != null);
    const answer_atom = try rt.internAtom("answer");
    defer rt.atoms.free(answer_atom);
    {
        const stored = result.getProperty(answer_atom);
        defer stored.free(rt);
        try std.testing.expect(stored.same(core.JSValue.symbol(value_symbol)));
    }

    result_value.free(rt);
    result_alive = false;
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(value_symbol) == null);
}

pub fn qjsPromiseSettlementRecord(rt: *core.JSRuntime, rejected: bool, payload: core.JSValue) !core.JSValue {
    var rooted_payload = payload;
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &rooted_payload },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    const record = try core.Object.create(rt, core.class.ids.object, null);
    errdefer core.Object.destroyFromHeader(rt, &record.header);
    const status = try value_ops.createStringValue(rt, if (rejected) "rejected" else "fulfilled");
    defer status.free(rt);
    try defineValueProperty(rt, record, "status", status);
    try defineValueProperty(rt, record, if (rejected) "reason" else "value", rooted_payload);
    return record.value();
}

test "qjsPromiseSettlementRecord roots direct symbol payload while defining status" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const symbol_atom = try rt.atoms.newValueSymbol("gc-promise-settlement-record-symbol");
    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const record_value = try qjsPromiseSettlementRecord(rt, false, core.JSValue.symbol(symbol_atom));
    var record_alive = true;
    defer if (record_alive) record_value.free(rt);
    const record = objectFromValue(record_value) orelse return error.TypeError;

    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    const value_atom = try rt.internAtom("value");
    defer rt.atoms.free(value_atom);
    const value = record.getProperty(value_atom);
    defer value.free(rt);
    try std.testing.expect(value.same(core.JSValue.symbol(symbol_atom)));

    record_value.free(rt);
    record_alive = false;
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

pub fn qjsPromiseCombinatorState(rt: *core.JSRuntime, resolve_value: core.JSValue, reject_value: core.JSValue, values: *core.Object) !*core.Object {
    var rooted_resolve = resolve_value;
    var rooted_reject = reject_value;
    var rooted_values = values.value();
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &rooted_resolve },
        .{ .value = &rooted_reject },
        .{ .value = &rooted_values },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    const state = try core.Object.create(rt, core.class.ids.object, null);
    errdefer core.Object.destroyFromHeader(rt, &state.header);
    try state.setPromiseCombinatorResolve(rt, rooted_resolve.dup());
    try state.setPromiseCombinatorReject(rt, rooted_reject.dup());
    try state.setPromiseCombinatorValues(rt, rooted_values.dup());
    (try state.promiseCombinatorRemainingSlot(rt)).* = 1;
    return state;
}

test "qjsPromiseCombinatorState roots direct function bytecode resolve while creating state" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const values = try core.Object.create(rt, core.class.ids.array, null);
    defer values.value().free(rt);

    const fb_slice = try rt.memory.alloc(bytecode.FunctionBytecode, 1);
    const fb = &fb_slice[0];
    fb.* = bytecode.FunctionBytecode.init(&rt.memory, &rt.atoms, core.atom.ids.empty_string);
    try rt.gc.add(&fb.header);

    const symbol_atom = try rt.atoms.newValueSymbol("gc-qjs-promise-combinator-state-resolve-bytecode-symbol");
    fb.cpool = try rt.memory.alloc(core.JSValue, 1);
    fb.cpool[0] = core.JSValue.symbol(symbol_atom);
    fb.cpool_count = 1;

    var resolve_value = core.JSValue.functionBytecode(&fb.header);
    var resolve_alive = true;
    defer if (resolve_alive) resolve_value.free(rt);

    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const state = try qjsPromiseCombinatorState(rt, resolve_value, core.JSValue.undefinedValue(), values);
    var state_alive = true;
    defer if (state_alive) core.Object.destroyFromHeader(rt, &state.header);

    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    const stored = state.promiseCombinatorResolve() orelse return error.TypeError;
    try std.testing.expect(stored.same(resolve_value));

    core.Object.destroyFromHeader(rt, &state.header);
    state_alive = false;
    resolve_value.free(rt);
    resolve_alive = false;
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

pub fn qjsPromiseKeyedCombinatorState(rt: *core.JSRuntime, resolve_value: core.JSValue, reject_value: core.JSValue, values: *core.Object, keys: *core.Object) !*core.Object {
    const state = try qjsPromiseCombinatorState(rt, resolve_value, reject_value, values);
    errdefer core.Object.destroyFromHeader(rt, &state.header);
    try state.setPromiseCombinatorKeys(rt, keys.value().dup());
    return state;
}

pub fn qjsPromiseCombinatorCallback(
    rt: *core.JSRuntime,
    global: *core.Object,
    mode: PromiseCombinatorCallbackMode,
    state: *core.Object,
    index: u32,
) !core.JSValue {
    const callback = try qjsCreateBuiltinFunction(rt, global, "", 1);
    errdefer callback.free(rt);
    const callback_object = objectFromValue(callback) orelse return error.TypeError;
    callback_object.functionPromiseCombinatorModeSlot().* = @intFromEnum(mode);
    try callback_object.setFunctionPromiseCombinatorState(rt, state.value().dup());
    callback_object.functionPromiseCombinatorIndexSlot().* = index;
    callback_object.functionPromiseCombinatorCalledSlot().* = false;
    return callback;
}

pub fn qjsPromiseRejectCapability(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    reject_value: core.JSValue,
    reason: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !void {
    const result = try callValueOrBytecode(ctx, output, global, core.JSValue.undefinedValue(), reject_value, &.{reason}, caller_function, caller_frame);
    result.free(ctx.runtime);
}

pub fn qjsPromiseRejectCapabilityForError(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    reject_value: core.JSValue,
    err: anytype,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !void {
    const reason = try qjsPromiseErrorValue(ctx, global, err);
    defer reason.free(ctx.runtime);
    try qjsPromiseRejectCapability(ctx, output, global, reject_value, reason, caller_function, caller_frame);
}

pub fn qjsPromiseStaticMode(name: []const u8) ?PromiseStaticMode {
    if (std.mem.eql(u8, name, "resolve")) return .resolve;
    if (std.mem.eql(u8, name, "all")) return .all;
    if (std.mem.eql(u8, name, "allKeyed")) return .all_keyed;
    if (std.mem.eql(u8, name, "race")) return .race;
    if (std.mem.eql(u8, name, "reject")) return .reject;
    if (std.mem.eql(u8, name, "allSettled")) return .all_settled;
    if (std.mem.eql(u8, name, "allSettledKeyed")) return .all_settled_keyed;
    if (std.mem.eql(u8, name, "any")) return .any;
    if (std.mem.eql(u8, name, "try")) return .try_;
    if (std.mem.eql(u8, name, "withResolvers")) return .with_resolvers;
    return null;
}

pub fn qjsPromiseStaticBuiltinCallee(rt: *core.JSRuntime, global: *core.Object, function_object: *core.Object, name: []const u8) !bool {
    const ctor_key = try rt.internAtom("Promise");
    defer rt.atoms.free(ctor_key);
    const ctor_value = global.getProperty(ctor_key);
    defer ctor_value.free(rt);
    const ctor_object = objectFromValue(ctor_value) orelse return false;
    const method_key = try rt.internAtom(name);
    defer rt.atoms.free(method_key);
    const method_value = ctor_object.getProperty(method_key);
    defer method_value.free(rt);
    return method_value.sameValue(function_object.value());
}

pub fn qjsPromiseResolveIdentity(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    constructor_value: core.JSValue,
    value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    const promise_object = objectFromValue(value) orelse return null;
    if (promise_object.class_id != core.class.ids.promise) return null;
    const constructor = try getValueProperty(ctx, output, global, value, core.atom.ids.constructor, caller_function, caller_frame);
    defer constructor.free(ctx.runtime);
    if (constructor.sameValue(constructor_value)) return value.dup();
    return null;
}

pub fn qjsPromiseDefaultConstructor(ctx: *core.JSContext, global: *core.Object) !core.JSValue {
    const promise_key = try ctx.runtime.internAtom("Promise");
    defer ctx.runtime.atoms.free(promise_key);
    return global.getProperty(promise_key);
}

pub fn qjsPromiseSpeciesConstructor(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const default_constructor = try qjsPromiseDefaultConstructor(ctx, global);
    errdefer default_constructor.free(ctx.runtime);

    const constructor_value = try getValueProperty(ctx, output, global, receiver, core.atom.ids.constructor, caller_function, caller_frame);
    defer constructor_value.free(ctx.runtime);
    if (constructor_value.isUndefined()) return default_constructor;
    if (!constructor_value.isObject()) return error.TypeError;

    const species_atom = core.atom.predefinedId("Symbol.species", .symbol) orelse return error.TypeError;
    const species_value = try getValueProperty(ctx, output, global, constructor_value, species_atom, caller_function, caller_frame);
    defer species_value.free(ctx.runtime);
    if (species_value.isUndefined() or species_value.isNull()) return default_constructor;

    default_constructor.free(ctx.runtime);
    return species_value.dup();
}

pub fn qjsPromiseConstructorRealmGlobal(constructor_value: core.JSValue, fallback_global: *core.Object) *core.Object {
    if (objectFromValue(constructor_value)) |constructor_object| {
        if (objectRealmGlobal(constructor_object)) |realm_global| return realm_global;
    }
    return fallback_global;
}

pub fn qjsPromiseCombinatorCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    constructor_value: core.JSValue,
    args: []const core.JSValue,
    mode: PromiseCombinatorMode,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    if (!constructor_value.isObject()) return error.TypeError;
    if (!(try isConstructorLike(ctx, constructor_value))) return error.TypeError;
    var capability = try qjsPromiseCapability(ctx, output, global, constructor_value, caller_function, caller_frame);
    errdefer capability.deinit(ctx.runtime);

    const resolve_key = try ctx.runtime.internAtom("resolve");
    defer ctx.runtime.atoms.free(resolve_key);
    const promise_resolve = getValueProperty(ctx, output, global, constructor_value, resolve_key, caller_function, caller_frame) catch |err| {
        const reason = try qjsPromiseErrorValue(ctx, global, err);
        defer reason.free(ctx.runtime);
        try qjsPromiseRejectCapability(ctx, output, global, capability.reject, reason, caller_function, caller_frame);
        return capability.releaseCallbacks(ctx.runtime);
    };
    defer promise_resolve.free(ctx.runtime);
    if (!isCallableValue(promise_resolve)) {
        const reason = try qjsPromiseErrorValue(ctx, global, error.TypeError);
        defer reason.free(ctx.runtime);
        try qjsPromiseRejectCapability(ctx, output, global, capability.reject, reason, caller_function, caller_frame);
        return capability.releaseCallbacks(ctx.runtime);
    }

    const iterable = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const iterator_method = getIteratorMethod(ctx, output, global, iterable) catch |err| {
        const reason = try qjsPromiseErrorValue(ctx, global, err);
        defer reason.free(ctx.runtime);
        try qjsPromiseRejectCapability(ctx, output, global, capability.reject, reason, caller_function, caller_frame);
        return capability.releaseCallbacks(ctx.runtime);
    };
    defer iterator_method.free(ctx.runtime);
    if (!isCallableValue(iterator_method)) {
        const reason = try qjsPromiseErrorValue(ctx, global, error.TypeError);
        defer reason.free(ctx.runtime);
        try qjsPromiseRejectCapability(ctx, output, global, capability.reject, reason, caller_function, caller_frame);
        return capability.releaseCallbacks(ctx.runtime);
    }
    const iterator_value = callValueOrBytecode(ctx, output, global, iterable, iterator_method, &.{}, caller_function, caller_frame) catch |err| {
        const reason = try qjsPromiseErrorValue(ctx, global, err);
        defer reason.free(ctx.runtime);
        try qjsPromiseRejectCapability(ctx, output, global, capability.reject, reason, caller_function, caller_frame);
        return capability.releaseCallbacks(ctx.runtime);
    };
    defer iterator_value.free(ctx.runtime);
    _ = property_ops.expectObject(iterator_value) catch |err| {
        const reason = try qjsPromiseErrorValue(ctx, global, err);
        defer reason.free(ctx.runtime);
        try qjsPromiseRejectCapability(ctx, output, global, capability.reject, reason, caller_function, caller_frame);
        return capability.releaseCallbacks(ctx.runtime);
    };
    const next_key = try ctx.runtime.internAtom("next");
    defer ctx.runtime.atoms.free(next_key);
    const iterator_next = getValueProperty(ctx, output, global, iterator_value, next_key, caller_function, caller_frame) catch |err| {
        const reason = try qjsPromiseErrorValue(ctx, global, err);
        defer reason.free(ctx.runtime);
        try qjsPromiseRejectCapability(ctx, output, global, capability.reject, reason, caller_function, caller_frame);
        return capability.releaseCallbacks(ctx.runtime);
    };
    defer iterator_next.free(ctx.runtime);
    if (!isCallableValue(iterator_next)) {
        const reason = try qjsPromiseErrorValue(ctx, global, error.TypeError);
        defer reason.free(ctx.runtime);
        try qjsPromiseRejectCapability(ctx, output, global, capability.reject, reason, caller_function, caller_frame);
        return capability.releaseCallbacks(ctx.runtime);
    }
    const done_key = core.atom.predefinedId("done", .string).?;
    const value_key = core.atom.predefinedId("value", .string).?;

    const values = if (mode != .race) try core.Object.createArray(ctx.runtime, null) else null;
    const values_value = if (values) |array| array.value() else null;
    defer if (values_value) |value| value.free(ctx.runtime);
    const state = if (values) |array| try qjsPromiseCombinatorState(ctx.runtime, capability.resolve, capability.reject, array) else null;
    const state_value = if (state) |state_object| state_object.value() else null;
    defer if (state_value) |value| value.free(ctx.runtime);

    var iterator_done = false;
    var index: u32 = 0;
    while (true) {
        const next_result_value = callValueOrBytecode(ctx, output, global, iterator_value, iterator_next, &.{}, caller_function, caller_frame) catch |err| {
            if (!iterator_done) closeIteratorFromVm(ctx, output, global, iterator_value) catch {};
            const reason = try qjsPromiseErrorValue(ctx, global, err);
            defer reason.free(ctx.runtime);
            try qjsPromiseRejectCapability(ctx, output, global, capability.reject, reason, caller_function, caller_frame);
            return capability.releaseCallbacks(ctx.runtime);
        };
        defer next_result_value.free(ctx.runtime);
        const next_result = property_ops.expectObject(next_result_value) catch |err| {
            if (!iterator_done) closeIteratorFromVm(ctx, output, global, iterator_value) catch {};
            const reason = try qjsPromiseErrorValue(ctx, global, err);
            defer reason.free(ctx.runtime);
            try qjsPromiseRejectCapability(ctx, output, global, capability.reject, reason, caller_function, caller_frame);
            return capability.releaseCallbacks(ctx.runtime);
        };
        const done_value = getValueProperty(ctx, output, global, next_result.value(), done_key, null, null) catch |err| {
            const reason = try qjsPromiseErrorValue(ctx, global, err);
            defer reason.free(ctx.runtime);
            try qjsPromiseRejectCapability(ctx, output, global, capability.reject, reason, caller_function, caller_frame);
            return capability.releaseCallbacks(ctx.runtime);
        };
        defer done_value.free(ctx.runtime);
        if (value_ops.isTruthy(done_value)) {
            iterator_done = true;
            break;
        }
        const step_value = getValueProperty(ctx, output, global, next_result.value(), value_key, null, null) catch |err| {
            const reason = try qjsPromiseErrorValue(ctx, global, err);
            defer reason.free(ctx.runtime);
            try qjsPromiseRejectCapability(ctx, output, global, capability.reject, reason, caller_function, caller_frame);
            return capability.releaseCallbacks(ctx.runtime);
        };
        defer step_value.free(ctx.runtime);

        if (state) |state_object| {
            const remaining = state_object.promiseCombinatorRemaining();
            try qjsPromiseSetArrayIndex(ctx.runtime, values.?, index, core.JSValue.undefinedValue());
            (try state_object.promiseCombinatorRemainingSlot(ctx.runtime)).* = remaining + 1;
        }

        const next_promise = callValueOrBytecode(ctx, output, global, constructor_value, promise_resolve, &.{step_value}, caller_function, caller_frame) catch |err| {
            if (!iterator_done) closeIteratorFromVm(ctx, output, global, iterator_value) catch {};
            const reason = try qjsPromiseErrorValue(ctx, global, err);
            defer reason.free(ctx.runtime);
            try qjsPromiseRejectCapability(ctx, output, global, capability.reject, reason, caller_function, caller_frame);
            return capability.releaseCallbacks(ctx.runtime);
        };
        defer next_promise.free(ctx.runtime);

        const then_key = try ctx.runtime.internAtom("then");
        defer ctx.runtime.atoms.free(then_key);
        const then_value = getValueProperty(ctx, output, global, next_promise, then_key, caller_function, caller_frame) catch |err| {
            if (!iterator_done) closeIteratorFromVm(ctx, output, global, iterator_value) catch {};
            const reason = try qjsPromiseErrorValue(ctx, global, err);
            defer reason.free(ctx.runtime);
            try qjsPromiseRejectCapability(ctx, output, global, capability.reject, reason, caller_function, caller_frame);
            return capability.releaseCallbacks(ctx.runtime);
        };
        defer then_value.free(ctx.runtime);
        if (!isCallableValue(then_value)) {
            if (!iterator_done) closeIteratorFromVm(ctx, output, global, iterator_value) catch {};
            const reason = try qjsPromiseErrorValue(ctx, global, error.TypeError);
            defer reason.free(ctx.runtime);
            try qjsPromiseRejectCapability(ctx, output, global, capability.reject, reason, caller_function, caller_frame);
            return capability.releaseCallbacks(ctx.runtime);
        }

        const on_fulfilled = switch (mode) {
            .all => try qjsPromiseCombinatorCallback(ctx.runtime, global, .all_resolve, state.?, index),
            .all_settled => blk: {
                const callback = try qjsPromiseCombinatorCallback(ctx.runtime, global, .all_settled_fulfill, state.?, index);
                break :blk callback;
            },
            .any => capability.resolve.dup(),
            .race => capability.resolve.dup(),
        };
        defer on_fulfilled.free(ctx.runtime);
        const on_rejected = switch (mode) {
            .all => capability.reject.dup(),
            .all_settled => blk: {
                const callback = try qjsPromiseCombinatorCallback(ctx.runtime, global, .all_settled_reject, state.?, index);
                break :blk callback;
            },
            .any => try qjsPromiseCombinatorCallback(ctx.runtime, global, .any_reject, state.?, index),
            .race => capability.reject.dup(),
        };
        defer on_rejected.free(ctx.runtime);

        const then_result = callValueOrBytecode(ctx, output, global, next_promise, then_value, &.{ on_fulfilled, on_rejected }, caller_function, caller_frame) catch |err| {
            if (!iterator_done) closeIteratorFromVm(ctx, output, global, iterator_value) catch {};
            const reason = try qjsPromiseErrorValue(ctx, global, err);
            defer reason.free(ctx.runtime);
            try qjsPromiseRejectCapability(ctx, output, global, capability.reject, reason, caller_function, caller_frame);
            return capability.releaseCallbacks(ctx.runtime);
        };
        then_result.free(ctx.runtime);
        index += 1;
    }

    if (state) |state_object| {
        const remaining = state_object.promiseCombinatorRemaining();
        const next_remaining = remaining - 1;
        (try state_object.promiseCombinatorRemainingSlot(ctx.runtime)).* = next_remaining;
        if (next_remaining == 0) {
            switch (mode) {
                .all, .all_settled => {
                    const result = callValueOrBytecode(ctx, output, global, core.JSValue.undefinedValue(), capability.resolve, &.{values.?.value()}, caller_function, caller_frame) catch |err| {
                        const reason = try qjsPromiseErrorValue(ctx, global, err);
                        defer reason.free(ctx.runtime);
                        try qjsPromiseRejectCapability(ctx, output, global, capability.reject, reason, caller_function, caller_frame);
                        return capability.releaseCallbacks(ctx.runtime);
                    };
                    result.free(ctx.runtime);
                },
                .any => {
                    const aggregate_error = try qjsPromiseAggregateError(ctx, global, values.?);
                    defer aggregate_error.free(ctx.runtime);
                    const result = try callValueOrBytecode(ctx, output, global, core.JSValue.undefinedValue(), capability.reject, &.{aggregate_error}, caller_function, caller_frame);
                    result.free(ctx.runtime);
                },
                .race => {},
            }
        }
    }

    return capability.releaseCallbacks(ctx.runtime);
}

pub fn qjsPromiseKeyedCombinatorCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    constructor_value: core.JSValue,
    args: []const core.JSValue,
    all_settled: bool,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    if (!constructor_value.isObject()) return error.TypeError;
    if (!(try isConstructorLike(ctx, constructor_value))) return error.TypeError;
    var capability = try qjsPromiseCapability(ctx, output, global, constructor_value, caller_function, caller_frame);
    errdefer capability.deinit(ctx.runtime);

    const resolve_key = try ctx.runtime.internAtom("resolve");
    defer ctx.runtime.atoms.free(resolve_key);
    const promise_resolve = getValueProperty(ctx, output, global, constructor_value, resolve_key, caller_function, caller_frame) catch |err| {
        const reason = try qjsPromiseErrorValue(ctx, global, err);
        defer reason.free(ctx.runtime);
        try qjsPromiseRejectCapability(ctx, output, global, capability.reject, reason, caller_function, caller_frame);
        return capability.releaseCallbacks(ctx.runtime);
    };
    defer promise_resolve.free(ctx.runtime);
    if (!isCallableValue(promise_resolve)) {
        const reason = try qjsPromiseErrorValue(ctx, global, error.TypeError);
        defer reason.free(ctx.runtime);
        try qjsPromiseRejectCapability(ctx, output, global, capability.reject, reason, caller_function, caller_frame);
        return capability.releaseCallbacks(ctx.runtime);
    }

    const promises_value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const promises = objectFromValue(promises_value) orelse {
        const reason = try qjsPromiseErrorValue(ctx, global, error.TypeError);
        defer reason.free(ctx.runtime);
        try qjsPromiseRejectCapability(ctx, output, global, capability.reject, reason, caller_function, caller_frame);
        return capability.releaseCallbacks(ctx.runtime);
    };

    const own_keys = objectRestOwnKeys(ctx, output, global, promises) catch |err| {
        const reason = try qjsPromiseErrorValue(ctx, global, err);
        defer reason.free(ctx.runtime);
        try qjsPromiseRejectCapability(ctx, output, global, capability.reject, reason, caller_function, caller_frame);
        return capability.releaseCallbacks(ctx.runtime);
    };
    defer core.Object.freeKeys(ctx.runtime, own_keys);

    const keys = try core.Object.createArray(ctx.runtime, null);
    const keys_value = keys.value();
    defer keys_value.free(ctx.runtime);
    const values = try core.Object.createArray(ctx.runtime, null);
    const values_value = values.value();
    defer values_value.free(ctx.runtime);
    const state = try qjsPromiseKeyedCombinatorState(ctx.runtime, capability.resolve, capability.reject, values, keys);
    const state_value = state.value();
    defer state_value.free(ctx.runtime);

    var index: u32 = 0;
    for (own_keys) |key| {
        const desc = proxyAwareOwnPropertyDescriptor(ctx, output, global, promises, key, caller_function, caller_frame) catch |err| {
            const reason = try qjsPromiseErrorValue(ctx, global, err);
            defer reason.free(ctx.runtime);
            try qjsPromiseRejectCapability(ctx, output, global, capability.reject, reason, caller_function, caller_frame);
            return capability.releaseCallbacks(ctx.runtime);
        } orelse continue;
        defer desc.destroy(ctx.runtime);
        if (desc.enumerable != true) continue;

        const step_value = getValueProperty(ctx, output, global, promises_value, key, caller_function, caller_frame) catch |err| {
            const reason = try qjsPromiseErrorValue(ctx, global, err);
            defer reason.free(ctx.runtime);
            try qjsPromiseRejectCapability(ctx, output, global, capability.reject, reason, caller_function, caller_frame);
            return capability.releaseCallbacks(ctx.runtime);
        };
        defer step_value.free(ctx.runtime);

        const key_value = proxyTrapKeyValue(ctx.runtime, key) catch |err| {
            const reason = try qjsPromiseErrorValue(ctx, global, err);
            defer reason.free(ctx.runtime);
            try qjsPromiseRejectCapability(ctx, output, global, capability.reject, reason, caller_function, caller_frame);
            return capability.releaseCallbacks(ctx.runtime);
        };
        defer key_value.free(ctx.runtime);
        try qjsPromiseSetArrayIndex(ctx.runtime, keys, index, key_value);

        const remaining = state.promiseCombinatorRemaining();
        try qjsPromiseSetArrayIndex(ctx.runtime, values, index, core.JSValue.undefinedValue());
        (try state.promiseCombinatorRemainingSlot(ctx.runtime)).* = remaining + 1;

        const next_promise = callValueOrBytecode(ctx, output, global, constructor_value, promise_resolve, &.{step_value}, caller_function, caller_frame) catch |err| {
            const reason = try qjsPromiseErrorValue(ctx, global, err);
            defer reason.free(ctx.runtime);
            try qjsPromiseRejectCapability(ctx, output, global, capability.reject, reason, caller_function, caller_frame);
            return capability.releaseCallbacks(ctx.runtime);
        };
        defer next_promise.free(ctx.runtime);

        const then_key = try ctx.runtime.internAtom("then");
        defer ctx.runtime.atoms.free(then_key);
        const then_value = getValueProperty(ctx, output, global, next_promise, then_key, caller_function, caller_frame) catch |err| {
            const reason = try qjsPromiseErrorValue(ctx, global, err);
            defer reason.free(ctx.runtime);
            try qjsPromiseRejectCapability(ctx, output, global, capability.reject, reason, caller_function, caller_frame);
            return capability.releaseCallbacks(ctx.runtime);
        };
        defer then_value.free(ctx.runtime);
        if (!isCallableValue(then_value)) {
            const reason = try qjsPromiseErrorValue(ctx, global, error.TypeError);
            defer reason.free(ctx.runtime);
            try qjsPromiseRejectCapability(ctx, output, global, capability.reject, reason, caller_function, caller_frame);
            return capability.releaseCallbacks(ctx.runtime);
        }

        const on_fulfilled = if (all_settled)
            try qjsPromiseCombinatorCallback(ctx.runtime, global, .all_settled_keyed_fulfill, state, index)
        else
            try qjsPromiseCombinatorCallback(ctx.runtime, global, .all_keyed_resolve, state, index);
        defer on_fulfilled.free(ctx.runtime);
        const on_rejected = if (all_settled)
            try qjsPromiseCombinatorCallback(ctx.runtime, global, .all_settled_keyed_reject, state, index)
        else
            capability.reject.dup();
        defer on_rejected.free(ctx.runtime);

        const then_result = callValueOrBytecode(ctx, output, global, next_promise, then_value, &.{ on_fulfilled, on_rejected }, caller_function, caller_frame) catch |err| {
            const reason = try qjsPromiseErrorValue(ctx, global, err);
            defer reason.free(ctx.runtime);
            try qjsPromiseRejectCapability(ctx, output, global, capability.reject, reason, caller_function, caller_frame);
            return capability.releaseCallbacks(ctx.runtime);
        };
        then_result.free(ctx.runtime);
        index += 1;
    }

    const remaining = state.promiseCombinatorRemaining();
    const next_remaining = remaining - 1;
    (try state.promiseCombinatorRemainingSlot(ctx.runtime)).* = next_remaining;
    if (next_remaining == 0) {
        const keyed_result = try qjsPromiseKeyedResult(ctx.runtime, keys, values);
        defer keyed_result.free(ctx.runtime);
        const result = callValueOrBytecode(ctx, output, global, core.JSValue.undefinedValue(), capability.resolve, &.{keyed_result}, caller_function, caller_frame) catch |err| {
            const reason = try qjsPromiseErrorValue(ctx, global, err);
            defer reason.free(ctx.runtime);
            try qjsPromiseRejectCapability(ctx, output, global, capability.reject, reason, caller_function, caller_frame);
            return capability.releaseCallbacks(ctx.runtime);
        };
        result.free(ctx.runtime);
    }

    return capability.releaseCallbacks(ctx.runtime);
}

pub fn qjsPromiseStaticCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    constructor_value: core.JSValue,
    args: []const core.JSValue,
    mode: PromiseStaticMode,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    if (!constructor_value.isObject()) return error.TypeError;
    if (!(try isConstructorLike(ctx, constructor_value))) return error.TypeError;

    switch (mode) {
        .all => return qjsPromiseCombinatorCall(ctx, output, global, constructor_value, args, .all, caller_function, caller_frame),
        .all_keyed => return qjsPromiseKeyedCombinatorCall(ctx, output, global, constructor_value, args, false, caller_function, caller_frame),
        .race => return qjsPromiseCombinatorCall(ctx, output, global, constructor_value, args, .race, caller_function, caller_frame),
        .all_settled => return qjsPromiseCombinatorCall(ctx, output, global, constructor_value, args, .all_settled, caller_function, caller_frame),
        .all_settled_keyed => return qjsPromiseKeyedCombinatorCall(ctx, output, global, constructor_value, args, true, caller_function, caller_frame),
        .any => return qjsPromiseCombinatorCall(ctx, output, global, constructor_value, args, .any, caller_function, caller_frame),
        else => {},
    }

    switch (mode) {
        .resolve => {
            const payload = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
            if (try qjsPromiseResolveIdentity(ctx, output, global, constructor_value, payload, caller_function, caller_frame)) |same_promise| {
                return same_promise;
            }
            var capability = try qjsPromiseCapability(ctx, output, global, constructor_value, caller_function, caller_frame);
            errdefer capability.deinit(ctx.runtime);
            const resolve_result = try callValueOrBytecode(ctx, output, global, core.JSValue.undefinedValue(), capability.resolve, &.{payload}, caller_function, caller_frame);
            resolve_result.free(ctx.runtime);
            return capability.releaseCallbacks(ctx.runtime);
        },
        .reject => {
            const reason = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
            var capability = try qjsPromiseCapability(ctx, output, global, constructor_value, caller_function, caller_frame);
            errdefer capability.deinit(ctx.runtime);
            const reject_result = try callValueOrBytecode(ctx, output, global, core.JSValue.undefinedValue(), capability.reject, &.{reason}, caller_function, caller_frame);
            reject_result.free(ctx.runtime);
            return capability.releaseCallbacks(ctx.runtime);
        },
        .try_ => {
            const callback = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
            const callback_args = if (args.len >= 1) args[1..] else args[0..0];
            var capability = try qjsPromiseCapability(ctx, output, global, constructor_value, caller_function, caller_frame);
            errdefer capability.deinit(ctx.runtime);
            const callback_result = callValueOrBytecode(ctx, output, global, core.JSValue.undefinedValue(), callback, callback_args, caller_function, caller_frame) catch |err| {
                const reason = try qjsPromiseErrorValue(ctx, global, err);
                defer reason.free(ctx.runtime);
                const reject_result = try callValueOrBytecode(ctx, output, global, core.JSValue.undefinedValue(), capability.reject, &.{reason}, caller_function, caller_frame);
                reject_result.free(ctx.runtime);
                return capability.releaseCallbacks(ctx.runtime);
            };
            defer callback_result.free(ctx.runtime);
            const resolve_result = try callValueOrBytecode(ctx, output, global, core.JSValue.undefinedValue(), capability.resolve, &.{callback_result}, caller_function, caller_frame);
            resolve_result.free(ctx.runtime);
            return capability.releaseCallbacks(ctx.runtime);
        },
        .with_resolvers => {
            var capability = try qjsPromiseCapability(ctx, output, global, constructor_value, caller_function, caller_frame);
            defer capability.deinit(ctx.runtime);
            const result = try core.Object.create(ctx.runtime, core.class.ids.object, objectPrototypeFromGlobal(ctx.runtime, global));
            errdefer core.Object.destroyFromHeader(ctx.runtime, &result.header);
            try defineValueProperty(ctx.runtime, result, "promise", capability.promise);
            try defineValueProperty(ctx.runtime, result, "resolve", capability.resolve);
            try defineValueProperty(ctx.runtime, result, "reject", capability.reject);
            return result.value();
        },
        else => unreachable,
    }
}

pub const PromiseRejectionReason = struct {
    value: core.JSValue,
    from_exception: bool,

    pub fn deinit(self: *PromiseRejectionReason, rt: *core.JSRuntime) void {
        self.value.free(rt);
        self.value = core.JSValue.undefinedValue();
        self.from_exception = false;
    }

    pub fn commit(self: *PromiseRejectionReason, ctx: *core.JSContext) void {
        if (self.from_exception and ctx.hasException()) ctx.clearException();
    }
};

pub fn promiseRejectionReason(ctx: *core.JSContext, global: *core.Object, err: anytype) PromiseRejectionReason {
    if (ctx.hasException()) {
        return .{
            .value = ctx.exception_slot.value.dup(),
            .from_exception = true,
        };
    }
    return .{
        .value = exception_ops.createNamedError(ctx, global, if (err == error.TypeError) "TypeError" else "Error", "") catch core.JSValue.undefinedValue(),
        .from_exception = false,
    };
}

pub fn closeForAwaitIteratorFromVm(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    iterator_value: core.JSValue,
) !void {
    // QuickJS OP_iterator_close uses ordinary IteratorClose for for-await
    // records too; it does not await a promise returned by return().
    try closeIteratorFromVmImpl(ctx, output, global, iterator_value);
}

pub fn constructAsyncFunctionFromSource(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    constructor: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    return constructDynamicFunctionFromSource(ctx, output, global, constructor, constructor, args, .async_function, caller_function, caller_frame);
}

pub fn constructAsyncGeneratorFunctionFromSource(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    constructor: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    return constructDynamicFunctionFromSource(ctx, output, global, constructor, constructor, args, .async_generator, caller_function, caller_frame);
}

pub fn parameterSourceContainsAwait(rt: *core.JSRuntime, source: []const u8) !bool {
    var lexer = frontend.zjs_lexer.Lexer.init(rt.memory.allocator, &rt.atoms, source);
    lexer.is_strict_mode = true;
    while (true) {
        var token = try lexer.next();
        defer lexer.freeToken(&token);
        if (token.val == frontend.zjs_token.TOK_AWAIT) return true;
        if (token.val == frontend.zjs_token.TOK_EOF) return false;
    }
}

pub fn atomicsDestroyAsyncWaiter(waiter: *AtomicsWaiter) void {
    const ctx = waiter.ctx.?;
    if (waiter.promise) |promise| promise.free(ctx.runtime);
    atomicsReleaseWaiterKey(&waiter.key);
    ctx.runtime.memory.destroy(AtomicsWaiter, waiter);
}

pub fn atomicsSettleAsyncWaiter(waiter: *AtomicsWaiter, promise: core.JSValue, result: []const u8) !void {
    const ctx = waiter.ctx orelse return;
    const promise_object = objectFromValue(promise) orelse return error.TypeError;
    if (promise_object.class_id != core.class.ids.promise) return error.TypeError;
    if (promise_object.promiseResultSlot().* != null) return;
    const result_value = try value_ops.createStringValue(ctx.runtime, result);
    var result_value_owned = true;
    errdefer if (result_value_owned) result_value.free(ctx.runtime);
    try ctx.ensurePendingPromiseJobCapacity(ctx.pending_promise_jobs.len + 1);

    const result_slot = promise_object.promiseResultSlot();

    var reaction_arg_value: ?core.JSValue = null;
    errdefer if (reaction_arg_value) |value| value.free(ctx.runtime);
    const reaction_arg_slot = promise_object.promiseReactionArgSlot();
    const needs_reaction_arg = promise_object.promiseReactionCallback() != null and promise_object.promiseReactionArg() == null;
    if (needs_reaction_arg) {
        reaction_arg_value = result_value.dup();
    }

    try enqueuePendingPromiseJob(ctx, promise);

    const old_result = result_slot.*;
    result_slot.* = result_value;
    result_value_owned = false;
    promise_object.promiseIsRejectedSlot().* = false;
    if (old_result) |stored| stored.free(ctx.runtime);
    if (reaction_arg_value) |value| {
        const old_reaction_arg = reaction_arg_slot.*;
        reaction_arg_slot.* = value;
        reaction_arg_value = null;
        if (old_reaction_arg) |stored| stored.free(ctx.runtime);
    }
}

pub fn qjsAtomicsWaitAsync(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const view_value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const view = try atomicsTypedArray(view_value, true);
    if ((try atomicsBufferObject(view)).class_id != core.class.ids.shared_array_buffer) return error.TypeError;
    const index_value = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
    const index = try atomicsValidateAccess(ctx, output, global, view, index_value, caller_function, caller_frame);
    const expected_arg = if (args.len >= 3) args[2] else core.JSValue.undefinedValue();
    const expected = if (atomicsTypedArrayIsBigInt(view))
        try toBigIntBitsForAtomics(ctx, output, global, expected_arg, caller_function, caller_frame)
    else
        try toInt32BitsForAtomics(ctx, output, global, expected_arg, caller_function, caller_frame);
    const timeout_arg = if (args.len >= 4) args[3] else core.JSValue.float64(std.math.nan(f64));
    const timeout = try toNumberForAtomics(ctx, output, global, timeout_arg, caller_function, caller_frame);
    try atomicsValidateIndex(ctx.runtime, view, index);
    const bytes = try atomicsElementBytes(view, index);
    const current = atomicsReadBits(view, bytes);
    if (current != atomicsMaskBits(view, expected)) {
        const result = try value_ops.createStringValue(ctx.runtime, "not-equal");
        defer result.free(ctx.runtime);
        return atomicsWaitAsyncResult(ctx, false, result);
    }
    if (timeout <= 0 and !std.math.isNan(timeout)) {
        const result = try value_ops.createStringValue(ctx.runtime, "timed-out");
        defer result.free(ctx.runtime);
        return atomicsWaitAsyncResult(ctx, false, result);
    }

    const promise = try core.promise.constructWithPrototype(ctx.runtime, promisePrototypeFromGlobal(ctx.runtime, global));
    defer promise.free(ctx.runtime);
    if (objectFromValue(promise)) |promise_object| {
        promise_object.promiseAtomicsWaitAsyncSlot().* = true;
    }
    const deadline = if (atomicsWaitTimeoutMilliseconds(timeout)) |timeout_ms|
        std.Io.Timestamp.now(atomicsWaiterIo(), .awake).addDuration(std.Io.Duration.fromMilliseconds(timeout_ms))
    else
        null;
    const waiter = try ctx.runtime.memory.create(AtomicsWaiter);
    const key = try atomicsWaiterKey(view, bytes);
    atomicsRetainWaiterKey(key);
    waiter.* = .{
        .key = key,
        .promise = promise.dup(),
        .ctx = ctx,
        .deadline = deadline,
    };
    atomicsLinkAsyncWaiter(waiter);
    return atomicsWaitAsyncResult(ctx, true, promise);
}

pub fn atomicsLinkAsyncWaiter(waiter: *AtomicsWaiter) void {
    const io = atomicsWaiterIo();
    call_runtime.atomics_waiter_mutex.lockUncancelable(io);
    defer call_runtime.atomics_waiter_mutex.unlock(io);
    atomicsLinkWaiter(waiter);
}

pub fn atomicsWaitAsyncResult(ctx: *core.JSContext, is_async: bool, value: core.JSValue) !core.JSValue {
    var rooted_value = value;
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &rooted_value },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = ctx.runtime.active_value_roots,
        .values = &root_values,
    };
    ctx.runtime.active_value_roots = &root_frame;
    defer ctx.runtime.active_value_roots = root_frame.previous;

    const result = try core.Object.create(ctx.runtime, core.class.ids.object, null);
    errdefer core.Object.destroyFromHeader(ctx.runtime, &result.header);
    try defineValueProperty(ctx.runtime, result, "async", core.JSValue.boolean(is_async));
    try defineValueProperty(ctx.runtime, result, "value", rooted_value);
    return result.value();
}

test "atomicsWaitAsyncResult roots direct function bytecode value while creating result object" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const fb_slice = try rt.memory.alloc(bytecode.FunctionBytecode, 1);
    const fb = &fb_slice[0];
    fb.* = bytecode.FunctionBytecode.init(&rt.memory, &rt.atoms, core.atom.ids.empty_string);
    try rt.gc.add(&fb.header);

    const symbol_atom = try rt.atoms.newValueSymbol("gc-atomics-wait-async-result-bytecode-symbol");
    fb.cpool = try rt.memory.alloc(core.JSValue, 1);
    fb.cpool[0] = core.JSValue.symbol(symbol_atom);
    fb.cpool_count = 1;

    var result_payload = core.JSValue.functionBytecode(&fb.header);
    var payload_alive = true;
    defer if (payload_alive) result_payload.free(rt);

    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const result_value = try atomicsWaitAsyncResult(ctx, true, result_payload);
    var result_alive = true;
    defer if (result_alive) result_value.free(rt);
    const result = objectFromValue(result_value) orelse return error.TypeError;

    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    const value_key = try rt.internAtom("value");
    defer rt.atoms.free(value_key);
    const stored = result.getProperty(value_key);
    defer stored.free(rt);
    try std.testing.expect(stored.same(result_payload));

    result_value.free(rt);
    result_alive = false;
    result_payload.free(rt);
    payload_alive = false;
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

pub fn qjsAsyncFunctionStart(
    ctx: *core.JSContext,
    func: core.JSValue,
    current_function_value: core.JSValue,
    this_value: core.JSValue,
    args: []const core.JSValue,
    var_refs: []const core.JSValue,
    output: ?*std.Io.Writer,
    global: *core.Object,
    eval_var_ref_names: []const core.Atom,
    eval_var_refs: []const core.JSValue,
) HostError!core.JSValue {
    const promise = try core.promise.constructWithPrototype(ctx.runtime, promisePrototypeFromGlobal(ctx.runtime, global));
    errdefer promise.free(ctx.runtime);

    const continuation_value = try createGeneratorObject(ctx, func, current_function_value, this_value, args, var_refs, output, global, eval_var_ref_names, eval_var_refs, false);
    defer continuation_value.free(ctx.runtime);
    const continuation = objectFromValue(continuation_value) orelse return error.TypeError;
    try continuation.setOptionalValueSlot(ctx.runtime, continuation.generatorAsyncPromiseSlot(), promise.dup());

    try qjsAsyncFunctionRunAndSettle(ctx, output, global, continuation, null, false);
    return promise;
}

pub fn qjsAsyncFunctionRunState(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    continuation: *core.Object,
    resume_value: ?core.JSValue,
    resume_rejected: bool,
) HostError!core.JSValue {
    if (continuation.generatorExecuting()) return error.TypeError;
    const function_value = continuation.functionBytecodeSlot().* orelse return error.TypeError;
    const fb = functionBytecodeFromValue(function_value) orelse return error.TypeError;
    var nested = bytecode.function.asBytecodeView(fb, ctx.runtime);
    var nested_stack = stack_mod.Stack.init(&ctx.runtime.memory, ctx.runtime.stack_size);
    defer nested_stack.deinit(ctx.runtime);

    try setGeneratorResumeCompletionType(ctx.runtime, continuation, if (resume_rejected) 2 else 0);
    continuation.generatorExecutingSlot().* = true;
    defer continuation.generatorExecutingSlot().* = false;

    const async_global = objectRealmGlobal(continuation) orelse global;
    const current_function_value = continuation.generatorCurrentFunction() orelse continuation.value();
    const fb_runtime_strict = fb.is_strict_mode or fb.runtime_strict_mode;
    return runWithArgsState(ctx, &nested_stack, &nested, continuation.generatorThis() orelse core.JSValue.undefinedValue(), continuation.generatorArgs(), continuation.functionCapturesSlot().*, output, async_global, false, fb_runtime_strict, false, &.{}, &.{}, continuation.functionEvalLocalNamesSlot().*, continuation.functionEvalLocalRefsSlot().*, &.{}, &.{}, &.{}, &.{}, continuation, resume_value, null, current_function_value, core.JSValue.undefinedValue(), core.JSValue.undefinedValue(), false, false, core.JSValue.undefinedValue(), false, true);
}

pub fn qjsAsyncFunctionRunAndSettle(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    continuation: *core.Object,
    resume_value: ?core.JSValue,
    resume_rejected: bool,
) HostError!void {
    const async_global = objectRealmGlobal(continuation) orelse global;
    const result = qjsAsyncFunctionRunState(ctx, output, async_global, continuation, resume_value, resume_rejected) catch |err| {
        continuation.generatorDoneSlot().* = true;
        const reason = try qjsPromiseErrorValue(ctx, async_global, err);
        defer reason.free(ctx.runtime);
        try qjsAsyncFunctionSettle(ctx, output, async_global, continuation, reason, true, null, null);
        clearHandledRejectionException(ctx);
        qjsAsyncFunctionClearPromise(ctx.runtime, continuation);
        return;
    };
    defer result.free(ctx.runtime);

    if (continuation.generatorJustYielded() and !continuation.generatorDone()) {
        try qjsAsyncFunctionAwaitOrReject(ctx, output, async_global, continuation, result, null, null);
        return;
    }

    continuation.generatorDoneSlot().* = true;
    try qjsAsyncFunctionSettle(ctx, output, async_global, continuation, result, false, null, null);
    qjsAsyncFunctionClearPromise(ctx.runtime, continuation);
}

pub fn qjsAsyncFunctionAwaitOrReject(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    continuation: *core.Object,
    awaited_value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) HostError!void {
    qjsAsyncFunctionAwait(ctx, output, global, continuation, awaited_value, caller_function, caller_frame) catch |err| {
        continuation.generatorDoneSlot().* = true;
        const reason = try qjsPromiseErrorValue(ctx, global, err);
        defer reason.free(ctx.runtime);
        try qjsAsyncFunctionSettle(ctx, output, global, continuation, reason, true, caller_function, caller_frame);
        clearHandledRejectionException(ctx);
        qjsAsyncFunctionClearPromise(ctx.runtime, continuation);
    };
}

pub fn clearHandledRejectionException(ctx: *core.JSContext) void {
    if (!ctx.hasUnhandledRejection() and ctx.hasException()) ctx.clearException();
}

pub fn qjsAsyncFunctionAwait(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    continuation: *core.Object,
    awaited_value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) HostError!void {
    const promise_constructor = try qjsPromiseDefaultConstructor(ctx, global);
    defer promise_constructor.free(ctx.runtime);
    const awaited = try qjsPromiseStaticCall(ctx, output, global, promise_constructor, &.{awaited_value}, .resolve, caller_function, caller_frame);
    defer awaited.free(ctx.runtime);

    const on_fulfilled = try qjsAsyncFunctionResumeCallback(ctx.runtime, global, continuation, false);
    defer on_fulfilled.free(ctx.runtime);
    const on_rejected = try qjsAsyncFunctionResumeCallback(ctx.runtime, global, continuation, true);
    defer on_rejected.free(ctx.runtime);

    const then_atom = try ctx.runtime.internAtom("then");
    defer ctx.runtime.atoms.free(then_atom);
    const then_value = try getValueProperty(ctx, output, global, awaited, then_atom, caller_function, caller_frame);
    defer then_value.free(ctx.runtime);
    if (!isCallableValue(then_value)) return error.TypeError;
    const then_result = try callValueOrBytecode(ctx, output, global, awaited, then_value, &.{ on_fulfilled, on_rejected }, caller_function, caller_frame);
    then_result.free(ctx.runtime);
}

pub fn qjsAsyncFunctionResumeCallback(
    rt: *core.JSRuntime,
    global: *core.Object,
    continuation: *core.Object,
    rejected: bool,
) !core.JSValue {
    const callback = try qjsCreateBuiltinFunction(rt, global, "", 1);
    errdefer callback.free(rt);
    const callback_object = objectFromValue(callback) orelse return error.TypeError;
    try callback_object.setOptionalValueSlot(rt, callback_object.functionAsyncContinuationSlot(), continuation.value().dup());
    callback_object.functionAsyncContinuationRejectedSlot().* = rejected;
    return callback;
}

pub fn qjsAsyncFunctionResumeCallbackCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    function_object: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) HostError!?core.JSValue {
    const continuation_value = function_object.functionAsyncContinuation() orelse return null;
    const continuation = objectFromValue(continuation_value) orelse return error.TypeError;
    const rejected = function_object.functionAsyncContinuationRejected();
    const resume_value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    try qjsAsyncFunctionRunAndSettle(ctx, output, objectRealmGlobal(continuation) orelse global, continuation, resume_value, rejected);
    _ = caller_function;
    _ = caller_frame;
    return core.JSValue.undefinedValue();
}

pub fn qjsAsyncFunctionSettle(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    continuation: *core.Object,
    value: core.JSValue,
    rejected: bool,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) HostError!void {
    var rooted_value = value;
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &rooted_value },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = ctx.runtime.active_value_roots,
        .values = &root_values,
    };
    ctx.runtime.active_value_roots = &root_frame;
    defer ctx.runtime.active_value_roots = root_frame.previous;

    const promise_value = continuation.generatorAsyncPromise() orelse return error.TypeError;
    const resolving = try createPromiseResolvingPair(ctx.runtime, global, promise_value);
    defer resolving.resolve.free(ctx.runtime);
    defer resolving.reject.free(ctx.runtime);
    const settle = if (rejected) resolving.reject else resolving.resolve;
    const result = try callValueOrBytecode(ctx, output, global, core.JSValue.undefinedValue(), settle, &.{rooted_value}, caller_function, caller_frame);
    result.free(ctx.runtime);
}

test "qjsAsyncFunctionSettle roots direct symbol result before promise stores it" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    const ctx = try core.JSContext.create(rt);
    const global = try core.Object.create(rt, core.class.ids.object, null);
    const continuation = try core.Object.create(rt, core.class.ids.generator, null);
    defer {
        continuation.value().free(rt);
        global.value().free(rt);
        ctx.destroy();
        rt.destroy();
    }

    const promise = try core.promise.constructWithPrototype(rt, promisePrototypeFromGlobal(rt, global));
    defer promise.free(rt);
    try continuation.setOptionalValueSlot(rt, continuation.generatorAsyncPromiseSlot(), promise.dup());

    const symbol_atom = try rt.atoms.newValueSymbol("gc-async-settle-symbol");
    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);
    try qjsAsyncFunctionSettle(ctx, null, global, continuation, core.JSValue.symbol(symbol_atom), false, null, null);

    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    const promise_object = objectFromValue(promise) orelse return error.TypeError;
    const result = promise_object.promiseResult() orelse return error.TypeError;
    try std.testing.expect(result.same(core.JSValue.symbol(symbol_atom)));

    try promise_object.setPromiseResult(rt, null);
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

pub fn qjsAsyncFunctionClearPromise(rt: *core.JSRuntime, continuation: *core.Object) void {
    continuation.clearOptionalValueSlot(rt, continuation.generatorAsyncPromiseSlot());
}

pub fn isAsyncGeneratorPrototypeMethod(rt: *core.JSRuntime, function_object: *core.Object) bool {
    _ = rt;
    return function_object.isAsyncGeneratorPrototypeMethod();
}

pub fn isAsyncGeneratorReceiver(value: core.JSValue) bool {
    const object = objectFromValue(value) orelse return false;
    return object.class_id == core.class.ids.async_generator;
}

pub fn asyncGeneratorRejectedTypeError(ctx: *core.JSContext, global: *core.Object) !core.JSValue {
    return rejectedPromiseForRuntimeError(ctx, global, error.TypeError, promisePrototypeFromGlobal(ctx.runtime, global));
}

pub fn qjsAsyncIteratorAsyncDispose(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    function_object: *core.Object,
    caller_function: ?*const bytecode.Bytecode,
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
        return try core.promise.fulfilledWithPrototype(ctx.runtime, core.JSValue.undefinedValue(), promisePrototypeFromGlobal(ctx.runtime, global));
    }
    if (!isCallableValue(return_method)) {
        return try rejectedPromiseForRuntimeError(ctx, global, error.TypeError, promisePrototypeFromGlobal(ctx.runtime, global));
    }

    const result = callValueOrBytecode(ctx, output, global, receiver, return_method, &.{core.JSValue.undefinedValue()}, caller_function, caller_frame) catch |err| {
        return try rejectedPromiseForRuntimeError(ctx, global, err, promisePrototypeFromGlobal(ctx.runtime, global));
    };
    defer result.free(ctx.runtime);
    const result_object = objectFromValue(result) orelse {
        return try rejectedPromiseForRuntimeError(ctx, global, error.TypeError, promisePrototypeFromGlobal(ctx.runtime, global));
    };
    if (result_object.class_id == core.class.ids.promise) {
        try settlePendingPromiseReaction(ctx, output, global, result_object);
        if (result_object.promiseResult() == null) try awaitPendingPromise(ctx, output, global, result_object);
        if (result_object.promiseIsRejected()) {
            const reason = if (result_object.promiseResult()) |stored| stored.dup() else core.JSValue.undefinedValue();
            defer reason.free(ctx.runtime);
            return try core.promise.rejectedWithPrototype(ctx.runtime, reason, promisePrototypeFromGlobal(ctx.runtime, global));
        }
    }
    return try core.promise.fulfilledWithPrototype(ctx.runtime, core.JSValue.undefinedValue(), promisePrototypeFromGlobal(ctx.runtime, global));
}

pub fn asyncGeneratorFulfilledIteratorResult(ctx: *core.JSContext, global: *core.Object, value: core.JSValue, done: bool) !core.JSValue {
    const iterator_result = try createIteratorResult(ctx.runtime, global, value, done);
    defer iterator_result.free(ctx.runtime);
    return core.promise.fulfilledWithPrototype(ctx.runtime, iterator_result, promisePrototypeFromGlobal(ctx.runtime, global));
}

pub fn asyncGeneratorIteratorResultFromPromise(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    promise_value: core.JSValue,
    done: bool,
) !core.JSValue {
    const promise = try core.promise.constructWithPrototype(ctx.runtime, promisePrototypeFromGlobal(ctx.runtime, global));
    errdefer promise.free(ctx.runtime);
    const resolving = try createPromiseResolvingPair(ctx.runtime, global, promise);
    defer resolving.resolve.free(ctx.runtime);
    defer resolving.reject.free(ctx.runtime);

    const unwrap = try qjsAsyncFromSyncIteratorUnwrap(ctx.runtime, global, done);
    defer unwrap.free(ctx.runtime);
    try qjsPerformPromiseThen(ctx, output, global, promise_value, unwrap, core.JSValue.undefinedValue(), resolving.resolve, resolving.reject);
    return promise;
}

pub fn qjsAsyncFromSyncIteratorMethodCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    function_object: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    const method_id = function_object.asyncFromSyncIteratorMethod();
    if (method_id == 0) return null;
    const wrapper = objectFromValue(receiver) orelse return error.TypeError;
    if (wrapper.class_id != core.class.ids.async_from_sync_iterator) return error.TypeError;
    const sync_iterator = (wrapper.iteratorTargetSlot().*) orelse return error.TypeError;
    return switch (method_id) {
        1 => try qjsAsyncFromSyncIteratorNext(ctx, output, global, receiver, wrapper, sync_iterator, args, caller_function, caller_frame),
        2 => try qjsAsyncFromSyncIteratorReturn(ctx, output, global, wrapper, sync_iterator, args, caller_function, caller_frame),
        else => null,
    };
}

pub fn qjsAsyncFromSyncIteratorNext(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    wrapper: *core.Object,
    sync_iterator: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const next_method = if (wrapper.iteratorNext()) |stored| stored.dup() else blk: {
        const next_key = try ctx.runtime.internAtom("next");
        defer ctx.runtime.atoms.free(next_key);
        const method = try getValueProperty(ctx, output, global, sync_iterator, next_key, caller_function, caller_frame);
        errdefer method.free(ctx.runtime);
        if (!isCallableValue(method)) return error.TypeError;
        break :blk method;
    };
    defer next_method.free(ctx.runtime);
    const result = if (args.len > 0)
        callValueOrBytecode(ctx, output, global, sync_iterator, next_method, args[0..1], caller_function, caller_frame)
    else
        callValueOrBytecode(ctx, output, global, sync_iterator, next_method, &.{}, caller_function, caller_frame);
    const next_result = result catch |err| {
        return rejectedPromiseForRuntimeError(ctx, global, err, promisePrototypeFromGlobal(ctx.runtime, global));
    };
    defer next_result.free(ctx.runtime);
    _ = receiver;
    return qjsAsyncFromSyncIteratorContinuation(ctx, output, global, next_result, caller_function, caller_frame);
}

pub fn qjsAsyncFromSyncIteratorReturn(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    wrapper: *core.Object,
    sync_iterator: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    _ = wrapper;
    const return_key = try ctx.runtime.internAtom("return");
    defer ctx.runtime.atoms.free(return_key);
    const return_method = try getValueProperty(ctx, output, global, sync_iterator, return_key, caller_function, caller_frame);
    defer return_method.free(ctx.runtime);
    if (return_method.isUndefined() or return_method.isNull()) {
        const done_result = try createIteratorResult(ctx.runtime, global, core.JSValue.undefinedValue(), true);
        defer done_result.free(ctx.runtime);
        return core.promise.fulfilledWithPrototype(ctx.runtime, done_result, promisePrototypeFromGlobal(ctx.runtime, global));
    }
    if (!isCallableValue(return_method)) return error.TypeError;
    const result = if (args.len > 0)
        callValueOrBytecode(ctx, output, global, sync_iterator, return_method, args[0..1], caller_function, caller_frame)
    else
        callValueOrBytecode(ctx, output, global, sync_iterator, return_method, &.{}, caller_function, caller_frame);
    const return_result = result catch |err| {
        return rejectedPromiseForRuntimeError(ctx, global, err, promisePrototypeFromGlobal(ctx.runtime, global));
    };
    defer return_result.free(ctx.runtime);
    return qjsAsyncFromSyncIteratorContinuation(ctx, output, global, return_result, caller_function, caller_frame);
}

pub fn qjsAsyncFromSyncIteratorContinuation(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    result: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    var capability = try qjsDefaultPromiseCapability(ctx, output, global, caller_function, caller_frame);
    errdefer capability.deinit(ctx.runtime);

    const result_object = property_ops.expectObject(result) catch |err| {
        try qjsPromiseRejectCapabilityForError(ctx, output, global, capability.reject, err, caller_function, caller_frame);
        return capability.releaseCallbacks(ctx.runtime);
    };
    const done_key = core.atom.predefinedId("done", .string) orelse return error.TypeError;
    const done_value = getValueProperty(ctx, output, global, result_object.value(), done_key, caller_function, caller_frame) catch |err| {
        try qjsPromiseRejectCapabilityForError(ctx, output, global, capability.reject, err, caller_function, caller_frame);
        return capability.releaseCallbacks(ctx.runtime);
    };
    defer done_value.free(ctx.runtime);
    const done = valueTruthy(done_value);

    const value_key = core.atom.predefinedId("value", .string) orelse return error.TypeError;
    const value = getValueProperty(ctx, output, global, result_object.value(), value_key, caller_function, caller_frame) catch |err| {
        try qjsPromiseRejectCapabilityForError(ctx, output, global, capability.reject, err, caller_function, caller_frame);
        return capability.releaseCallbacks(ctx.runtime);
    };
    defer value.free(ctx.runtime);

    const promise_constructor = try qjsPromiseDefaultConstructor(ctx, global);
    defer promise_constructor.free(ctx.runtime);
    const value_wrapper_promise = qjsPromiseStaticCall(ctx, output, global, promise_constructor, &.{value}, .resolve, caller_function, caller_frame) catch |err| {
        try qjsPromiseRejectCapabilityForError(ctx, output, global, capability.reject, err, caller_function, caller_frame);
        return capability.releaseCallbacks(ctx.runtime);
    };
    defer value_wrapper_promise.free(ctx.runtime);

    const unwrap = try qjsAsyncFromSyncIteratorUnwrap(ctx.runtime, global, done);
    defer unwrap.free(ctx.runtime);

    qjsPerformPromiseThen(
        ctx,
        output,
        global,
        value_wrapper_promise,
        unwrap,
        core.JSValue.undefinedValue(),
        capability.resolve,
        capability.reject,
    ) catch |err| {
        try qjsPromiseRejectCapabilityForError(ctx, output, global, capability.reject, err, caller_function, caller_frame);
        return capability.releaseCallbacks(ctx.runtime);
    };
    return capability.releaseCallbacks(ctx.runtime);
}

pub fn qjsAsyncFromSyncIteratorUnwrap(
    rt: *core.JSRuntime,
    global: *core.Object,
    done: bool,
) !core.JSValue {
    const callback = try qjsCreateBuiltinFunction(rt, global, "", 1);
    errdefer callback.free(rt);
    const callback_object = objectFromValue(callback) orelse return error.TypeError;
    callback_object.functionAsyncFromSyncUnwrapDoneSlot().* = if (done) 2 else 1;
    return callback;
}

pub fn qjsAsyncFromSyncIteratorUnwrapCall(
    ctx: *core.JSContext,
    global: *core.Object,
    function_object: *core.Object,
    args: []const core.JSValue,
) !?core.JSValue {
    const mode = function_object.functionAsyncFromSyncUnwrapDone();
    if (mode == 0) return null;
    if (mode != 1 and mode != 2) return error.TypeError;
    const payload = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    return try createIteratorResult(ctx.runtime, global, payload, mode == 2);
}

pub const PromiseFinallyCallbackMode = enum(u8) {
    fulfill = 1,
    reject = 2,
    return_value = 3,
    throw_reason = 4,
};

pub fn qjsPromiseFinallyCallback(
    rt: *core.JSRuntime,
    global: *core.Object,
    mode: PromiseFinallyCallbackMode,
    payload: ?core.JSValue,
    on_finally: ?core.JSValue,
    constructor_value: ?core.JSValue,
) !core.JSValue {
    var rooted_payload = payload orelse core.JSValue.undefinedValue();
    var rooted_on_finally = on_finally orelse core.JSValue.undefinedValue();
    var rooted_constructor = constructor_value orelse core.JSValue.undefinedValue();
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &rooted_payload },
        .{ .value = &rooted_on_finally },
        .{ .value = &rooted_constructor },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    const callback = try qjsCreateBuiltinFunction(rt, global, "", if (mode == .fulfill or mode == .reject) 1 else 0);
    errdefer callback.free(rt);
    const callback_object = objectFromValue(callback) orelse return error.TypeError;
    callback_object.functionPromiseFinallyModeSlot().* = @intFromEnum(mode);
    if (payload != null) try callback_object.setFunctionPromiseFinallyPayload(rt, rooted_payload.dup());
    if (on_finally != null) try callback_object.setFunctionPromiseFinallyCallback(rt, rooted_on_finally.dup());
    if (constructor_value != null) try callback_object.setFunctionPromiseFinallyConstructor(rt, rooted_constructor.dup());
    return callback;
}

test "qjsPromiseFinallyCallback roots direct symbol payload while allocating callback" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    const global = try core.Object.create(rt, core.class.ids.object, null);
    defer {
        global.value().free(rt);
        rt.destroy();
    }

    const symbol_atom = try rt.atoms.newValueSymbol("gc-promise-finally-payload-symbol");
    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const callback = try qjsPromiseFinallyCallback(
        rt,
        global,
        .return_value,
        core.JSValue.symbol(symbol_atom),
        null,
        null,
    );
    var callback_alive = true;
    defer if (callback_alive) callback.free(rt);
    const callback_object = objectFromValue(callback) orelse return error.TypeError;

    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    const stored = callback_object.functionPromiseFinallyPayload() orelse return error.TypeError;
    try std.testing.expect(stored.same(core.JSValue.symbol(symbol_atom)));

    callback.free(rt);
    callback_alive = false;
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

pub fn qjsPromiseFinallyCallbackCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    function_object: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    const mode: PromiseFinallyCallbackMode = switch (function_object.functionPromiseFinallyMode()) {
        0 => return null,
        @intFromEnum(PromiseFinallyCallbackMode.fulfill) => .fulfill,
        @intFromEnum(PromiseFinallyCallbackMode.reject) => .reject,
        @intFromEnum(PromiseFinallyCallbackMode.return_value) => .return_value,
        @intFromEnum(PromiseFinallyCallbackMode.throw_reason) => .throw_reason,
        else => return error.TypeError,
    };

    switch (mode) {
        .return_value => {
            const payload = function_object.functionPromiseFinallyPayload() orelse return error.TypeError;
            return payload.dup();
        },
        .throw_reason => {
            const payload = function_object.functionPromiseFinallyPayload() orelse return error.TypeError;
            _ = ctx.throwValue(payload.dup());
            return error.JSException;
        },
        .fulfill, .reject => {
            const payload = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
            const on_finally = function_object.functionPromiseFinallyCallback() orelse return error.TypeError;
            const constructor_value = function_object.functionPromiseFinallyConstructor() orelse return error.TypeError;

            const callback_result = try callValueOrBytecode(ctx, output, global, core.JSValue.undefinedValue(), on_finally, &.{}, caller_function, caller_frame);
            defer callback_result.free(ctx.runtime);
            const resolved = try qjsPromiseStaticCall(ctx, output, global, constructor_value, &.{callback_result}, .resolve, caller_function, caller_frame);
            defer resolved.free(ctx.runtime);

            const continuation = try qjsPromiseFinallyCallback(
                ctx.runtime,
                global,
                if (mode == .fulfill) .return_value else .throw_reason,
                payload,
                null,
                null,
            );
            defer continuation.free(ctx.runtime);

            const then_key = try ctx.runtime.internAtom("then");
            defer ctx.runtime.atoms.free(then_key);
            const then_value = try getValueProperty(ctx, output, global, resolved, then_key, caller_function, caller_frame);
            defer then_value.free(ctx.runtime);
            if (!isCallableValue(then_value)) return error.TypeError;
            return try callValueOrBytecode(ctx, output, global, resolved, then_value, &.{continuation}, caller_function, caller_frame);
        },
    }
}

pub fn qjsPromiseFinally(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const constructor_value = try qjsPromiseSpeciesConstructor(ctx, output, global, receiver, caller_function, caller_frame);
    defer constructor_value.free(ctx.runtime);

    const on_finally = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const then_fulfilled = if (isCallableValue(on_finally))
        try qjsPromiseFinallyCallback(ctx.runtime, global, .fulfill, null, on_finally, constructor_value)
    else
        on_finally.dup();
    defer then_fulfilled.free(ctx.runtime);
    const then_rejected = if (isCallableValue(on_finally))
        try qjsPromiseFinallyCallback(ctx.runtime, global, .reject, null, on_finally, constructor_value)
    else
        on_finally.dup();
    defer then_rejected.free(ctx.runtime);

    const then_atom = try ctx.runtime.internAtom("then");
    defer ctx.runtime.atoms.free(then_atom);
    const then_value = try getValueProperty(ctx, output, global, receiver, then_atom, caller_function, caller_frame);
    defer then_value.free(ctx.runtime);
    if (!isCallableValue(then_value)) return error.TypeError;
    return callValueOrBytecode(ctx, output, global, receiver, then_value, &.{ then_fulfilled, then_rejected }, caller_function, caller_frame);
}

pub fn qjsAtomicsWaitAsyncPromise(rt: *core.JSRuntime, promise: *core.Object) bool {
    _ = rt;
    return promise.promiseAtomicsWaitAsync();
}

pub fn qjsPerformPromiseThen(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    on_fulfilled: core.JSValue,
    on_rejected: core.JSValue,
    resolve_value: core.JSValue,
    reject_value: core.JSValue,
) !void {
    const object = objectFromValue(receiver) orelse return error.TypeError;
    if (object.class_id != core.class.ids.promise) return error.TypeError;
    try processExpiredAtomicsWaiters(ctx);
    if (object.promiseResultSlot().* == null and object.promiseReactionCallback() != null and
        qjsPromiseThenableJobPending(object.promiseReactionCallback().?))
    {
        try qjsSettlePendingThenableJobs(ctx, output, global, object);
    }

    if (object.promiseIsRejected()) core.promise.markHandled(ctx, object);
    const reaction = try qjsPromiseReactionRecord(ctx.runtime, on_fulfilled, on_rejected, resolve_value, reject_value);
    defer reaction.free(ctx.runtime);
    if (object.promiseResultSlot().* == null) {
        try qjsAppendPromiseReaction(ctx.runtime, object, reaction);
        return;
    }

    const result_value = if (object.promiseResult()) |stored| stored.dup() else core.JSValue.undefinedValue();
    defer result_value.free(ctx.runtime);
    const reaction_object = objectFromValue(reaction) orelse return error.TypeError;
    const job = try qjsPromiseReactionJob(ctx.runtime, global, reaction_object, result_value, object.promiseIsRejected());
    defer job.free(ctx.runtime);
    try enqueuePendingPromiseJob(ctx, job);
}

pub fn qjsPromiseThen(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    method_name: []const u8,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    const is_catch = std.mem.eql(u8, method_name, "catch");
    const is_finally = std.mem.eql(u8, method_name, "finally");
    if (is_finally) return try qjsPromiseFinally(ctx, output, global, receiver, args, caller_function, caller_frame);
    if (!receiver.isObject()) {
        if (is_catch) return try qjsPromiseCatchGeneric(ctx, output, global, receiver, args);
        return error.TypeError;
    }
    const object = property_ops.expectObject(receiver) catch {
        if (is_catch) return try qjsPromiseCatchGeneric(ctx, output, global, receiver, args);
        return error.TypeError;
    };
    if (object.class_id != core.class.ids.promise) {
        if (is_catch) return try qjsPromiseCatchGeneric(ctx, output, global, receiver, args);
        return error.TypeError;
    }
    try processExpiredAtomicsWaiters(ctx);
    const constructor_value = try qjsPromiseSpeciesConstructor(ctx, output, global, receiver, caller_function, caller_frame);
    defer constructor_value.free(ctx.runtime);
    var capability = try qjsPromiseCapability(ctx, output, global, constructor_value, caller_function, caller_frame);
    errdefer capability.deinit(ctx.runtime);
    if (object.promiseResultSlot().* == null and object.promiseReactionCallback() != null and
        qjsPromiseThenableJobPending(object.promiseReactionCallback().?))
    {
        try qjsSettlePendingThenableJobs(ctx, output, global, object);
    }

    if (object.promiseIsRejected()) core.promise.markHandled(ctx, object);
    const on_fulfilled = if (is_catch) core.JSValue.undefinedValue() else if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const on_rejected = if (is_catch) (if (args.len >= 1) args[0] else core.JSValue.undefinedValue()) else if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
    if (object.promiseResultSlot().* == null) {
        if (!object.promiseIsRejected() and qjsAtomicsWaitAsyncPromise(ctx.runtime, object) and isCallableValue(on_fulfilled)) {
            try object.setPromiseReactionCallback(ctx.runtime, on_fulfilled.dup());
            try object.setPromiseReactionArg(ctx.runtime, null);
            return capability.releaseCallbacks(ctx.runtime);
        }
        const reaction = try qjsPromiseReactionRecord(ctx.runtime, on_fulfilled, on_rejected, capability.resolve, capability.reject);
        defer reaction.free(ctx.runtime);
        try qjsAppendPromiseReaction(ctx.runtime, object, reaction);
        return capability.releaseCallbacks(ctx.runtime);
    }
    const result_value = if (object.promiseResult()) |stored| stored.dup() else core.JSValue.undefinedValue();
    defer result_value.free(ctx.runtime);

    const reaction = try qjsPromiseReactionRecord(ctx.runtime, on_fulfilled, on_rejected, capability.resolve, capability.reject);
    defer reaction.free(ctx.runtime);
    const reaction_object = objectFromValue(reaction) orelse return error.TypeError;
    const job = try qjsPromiseReactionJob(ctx.runtime, global, reaction_object, result_value, object.promiseIsRejected());
    defer job.free(ctx.runtime);
    try enqueuePendingPromiseJob(ctx, job);
    return capability.releaseCallbacks(ctx.runtime);
}

pub fn qjsPromiseCatchGeneric(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    args: []const core.JSValue,
) !core.JSValue {
    const then_atom = try ctx.runtime.internAtom("then");
    defer ctx.runtime.atoms.free(then_atom);
    const then_value = try getValueProperty(ctx, output, global, receiver, then_atom, null, null);
    defer then_value.free(ctx.runtime);
    if (!isCallableValue(then_value)) return error.TypeError;
    const on_rejected = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const catch_args = [_]core.JSValue{ core.JSValue.undefinedValue(), on_rejected };
    return callValueOrBytecode(ctx, output, global, receiver, then_value, &catch_args, null, null);
}

pub fn settlePendingPromiseReaction(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    promise: *core.Object,
) !void {
    const callback = promise.promiseReactionCallback() orelse return;
    const callback_is_thenable_job = qjsPromiseThenableJobPending(callback);
    var callback_value = callback.dup();
    defer callback_value.free(ctx.runtime);
    var arg = if (promise.promiseReactionArg()) |stored| stored.dup() else core.JSValue.undefinedValue();
    defer arg.free(ctx.runtime);
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &callback_value },
        .{ .value = &arg },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = ctx.runtime.active_value_roots,
        .values = &root_values,
    };
    ctx.runtime.active_value_roots = &root_frame;
    defer ctx.runtime.active_value_roots = root_frame.previous;

    try promise.setPromiseReactionCallback(ctx.runtime, null);
    try promise.setPromiseReactionArg(ctx.runtime, null);

    const callback_args = [_]core.JSValue{arg};
    const callback_result = callValueOrBytecode(ctx, output, global, core.JSValue.undefinedValue(), callback_value, &callback_args, null, null) catch |err| {
        const rejected = try rejectedPromiseForRuntimeError(ctx, global, err, promisePrototypeFromGlobal(ctx.runtime, global));
        defer rejected.free(ctx.runtime);
        const rejected_object = objectFromValue(rejected) orelse return error.TypeError;
        const is_rejected = rejected_object.promiseIsRejected();
        const next_result = if (rejected_object.promiseResult()) |stored| stored.dup() else core.JSValue.undefinedValue();
        var next_result_owned = true;
        defer if (next_result_owned) next_result.free(ctx.runtime);
        var prepared_reactions = try qjsPreparePromiseReactionJobs(ctx, global, promise, next_result, is_rejected);
        errdefer prepared_reactions.deinit(ctx.runtime);
        var prepared_root: PreparedPromiseReactionJobsRoot = .{};
        prepared_root.init(ctx.runtime, &prepared_reactions);
        defer prepared_root.deinit();
        promise.promiseIsRejectedSlot().* = is_rejected;
        try promise.setPromiseResult(ctx.runtime, next_result);
        next_result_owned = false;
        prepared_reactions.commit(ctx, promise);
        return;
    };
    defer callback_result.free(ctx.runtime);
    if (callback_is_thenable_job or promise.promiseResult() != null or promise.promiseReactionCallback() != null) return;
    if (promise.promiseResult()) |stored| stored.free(ctx.runtime);
    if (objectFromValue(callback_result)) |result_promise| {
        if (result_promise.class_id == core.class.ids.promise and result_promise.promiseIsRejected()) {
            const next_result = if (result_promise.promiseResult()) |stored| stored.dup() else core.JSValue.undefinedValue();
            var next_result_owned = true;
            defer if (next_result_owned) next_result.free(ctx.runtime);
            var prepared_reactions = try qjsPreparePromiseReactionJobs(ctx, global, promise, next_result, true);
            errdefer prepared_reactions.deinit(ctx.runtime);
            var prepared_root: PreparedPromiseReactionJobsRoot = .{};
            prepared_root.init(ctx.runtime, &prepared_reactions);
            defer prepared_root.deinit();
            try promise.setPromiseResult(ctx.runtime, next_result);
            next_result_owned = false;
            promise.promiseIsRejectedSlot().* = true;
            prepared_reactions.commit(ctx, promise);
            return;
        }
    }
    var prepared_reactions = try qjsPreparePromiseReactionJobs(ctx, global, promise, callback_result, false);
    errdefer prepared_reactions.deinit(ctx.runtime);
    var prepared_root: PreparedPromiseReactionJobsRoot = .{};
    prepared_root.init(ctx.runtime, &prepared_reactions);
    defer prepared_root.deinit();
    try promise.setPromiseResult(ctx.runtime, callback_result.dup());
    promise.promiseIsRejectedSlot().* = false;
    prepared_reactions.commit(ctx, promise);
}

test "settlePendingPromiseReaction roots callback and arg after clearing promise slots" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    const ctx = try core.JSContext.create(rt);
    const global = try core.Object.create(rt, core.class.ids.object, null);
    const promise = try core.Object.create(rt, core.class.ids.promise, null);
    defer {
        promise.value().free(rt);
        global.value().free(rt);
        ctx.destroy();
        rt.destroy();
    }

    const fb_slice = try rt.memory.alloc(bytecode.FunctionBytecode, 1);
    const fb = &fb_slice[0];
    fb.* = bytecode.FunctionBytecode.init(&rt.memory, &rt.atoms, core.atom.ids.empty_string);
    fb.func_kind = .generator;
    try rt.gc.add(&fb.header);

    const callback_symbol = try rt.atoms.newValueSymbol("gc-promise-reaction-callback-symbol");
    fb.cpool = try rt.memory.alloc(core.JSValue, 1);
    fb.cpool[0] = core.JSValue.symbol(callback_symbol);
    fb.cpool_count = 1;

    var callback = core.JSValue.functionBytecode(&fb.header);
    var callback_alive = true;
    defer if (callback_alive) callback.free(rt);
    const arg_symbol = try rt.atoms.newValueSymbol("gc-promise-reaction-arg-symbol");
    try promise.setPromiseReactionCallback(rt, callback.dup());
    try promise.setPromiseReactionArg(rt, core.JSValue.symbol(arg_symbol));

    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);
    try settlePendingPromiseReaction(ctx, null, global, promise);

    try std.testing.expect(rt.atoms.name(callback_symbol) != null);
    try std.testing.expect(rt.atoms.name(arg_symbol) != null);

    const result = promise.promiseResult() orelse return error.TypeError;
    const generator = objectFromValue(result) orelse return error.TypeError;
    try std.testing.expectEqual(@as(usize, 1), generator.generatorArgs().len);
    try std.testing.expect(generator.generatorArgs()[0].same(core.JSValue.symbol(arg_symbol)));

    try promise.setPromiseResult(rt, null);
    callback.free(rt);
    callback_alive = false;
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(callback_symbol) == null);
    try std.testing.expect(rt.atoms.name(arg_symbol) == null);
}

pub fn awaitPendingPromise(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    promise: *core.Object,
) !void {
    if (!ctx.runtime.canBlock()) return;
    if (!qjsAtomicsWaitAsyncPromise(ctx.runtime, promise)) return;

    const io = atomicsWaiterIo();
    while (promise.promiseResultSlot().* == null) {
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(1), .awake) catch {};
        try processExpiredAtomicsWaiters(ctx);
        try settlePendingPromiseReaction(ctx, output, global, promise);
    }
}

pub fn drainPendingPromiseJobs(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
) !void {
    while (true) {
        try processExpiredAtomicsWaiters(ctx);
        while (true) {
            const promise_sequence = ctx.peekPendingPromiseJobSequence();
            const finalization_sequence = ctx.runtime.peekPendingFinalizationJobSequence();
            if (promise_sequence == null and finalization_sequence == null) break;

            if (finalization_sequence != null and (promise_sequence == null or finalization_sequence.? < promise_sequence.?)) {
                var cleanup_job = ctx.runtime.takePendingFinalizationJob().?;
                defer cleanup_job.deinit(ctx.runtime);
                var root_values = [_]core.runtime.ValueRootValue{
                    .{ .value = &cleanup_job.callback },
                    .{ .value = &cleanup_job.held_value },
                };
                const root_frame = core.runtime.ValueRootFrame{
                    .previous = ctx.runtime.active_value_roots,
                    .values = &root_values,
                };
                ctx.runtime.active_value_roots = &root_frame;
                defer ctx.runtime.active_value_roots = root_frame.previous;

                const result = try callValueOrBytecode(ctx, output, global, core.JSValue.undefinedValue(), cleanup_job.callback, &.{cleanup_job.held_value}, null, null);
                result.free(ctx.runtime);
                try pollGCSafePoint(ctx);
                continue;
            }

            var pending_job = ctx.takePendingPromiseJob().?;
            defer pending_job.deinit(ctx.runtime);
            const job = pending_job.value;
            const promise = objectFromValue(job) orelse {
                if (isCallableValue(job)) {
                    const result = try callValueOrBytecode(ctx, output, global, global.value(), job, &.{}, null, null);
                    result.free(ctx.runtime);
                    try pollGCSafePoint(ctx);
                }
                continue;
            };
            if (promise.class_id == core.class.ids.promise) {
                try settlePendingPromiseReaction(ctx, output, global, promise);
                try pollGCSafePoint(ctx);
                continue;
            }
            if (isCallableValue(job)) {
                const result = try callValueOrBytecode(ctx, output, global, global.value(), job, &.{}, null, null);
                result.free(ctx.runtime);
                try pollGCSafePoint(ctx);
            }
        }
        if (try call_mod.runNextOsSignalHandler(ctx, output, global)) continue;
        if (try runNextOsRwHandler(ctx, output, global)) continue;
        if (!try runNextOsTimer(ctx, output, global)) break;
    }
}

pub fn enqueuePendingPromiseJob(ctx: *core.JSContext, promise: core.JSValue) !void {
    const index = ctx.pending_promise_jobs.len;
    try ctx.ensurePendingPromiseJobCapacity(index + 1);
    const job = try core.context.PendingPromiseJob.init(ctx, ctx.runtime.nextJobSequence(), promise);
    ctx.pending_promise_jobs = ctx.pending_promise_jobs.ptr[0 .. index + 1];
    ctx.pending_promise_jobs[index] = job;
}

pub fn awaitThenableValue(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    awaited: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    const awaited_object = objectFromValue(awaited) orelse return null;
    if (awaited_object.class_id == core.class.ids.promise) return null;

    const then_key = try ctx.runtime.internAtom("then");
    defer ctx.runtime.atoms.free(then_key);
    const then_value = try getValueProperty(ctx, output, global, awaited, then_key, caller_function, caller_frame);
    defer then_value.free(ctx.runtime);
    if (!isCallableValue(then_value)) return null;

    const promise = try core.promise.constructWithPrototype(ctx.runtime, promisePrototypeFromGlobal(ctx.runtime, global));
    defer promise.free(ctx.runtime);
    const promise_object = objectFromValue(promise) orelse return error.TypeError;
    const resolving = try createPromiseResolvingPair(ctx.runtime, global, promise);
    const resolve = resolving.resolve;
    defer resolve.free(ctx.runtime);
    const reject = resolving.reject;
    defer reject.free(ctx.runtime);

    const then_result = callValueOrBytecode(ctx, output, global, awaited, then_value, &.{ resolve, reject }, caller_function, caller_frame) catch |err| {
        var reason = promiseRejectionReason(ctx, global, err);
        defer reason.deinit(ctx.runtime);
        try promise_object.setPromiseResult(ctx.runtime, reason.value);
        reason.value = core.JSValue.undefinedValue();
        promise_object.promiseIsRejectedSlot().* = true;
        reason.commit(ctx);
        return try finishAwaitedPromise(ctx, promise_object);
    };
    then_result.free(ctx.runtime);

    try qjsSettlePendingThenableJobs(ctx, output, global, promise_object);
    return try finishAwaitedPromise(ctx, promise_object);
}

pub fn finishAwaitedPromise(ctx: *core.JSContext, promise: *core.Object) !core.JSValue {
    const result = if (promise.promiseResult()) |stored| stored.dup() else core.JSValue.undefinedValue();
    errdefer result.free(ctx.runtime);
    if (promise.promiseIsRejected()) {
        _ = ctx.throwValue(result.dup());
        return error.JSException;
    }
    return result;
}

pub fn qjsReflectConstructResolveBound(
    rt: *core.JSRuntime,
    target_value: core.JSValue,
    new_target_value: core.JSValue,
    args: []const core.JSValue,
) !ReflectConstructResolution {
    var target = target_value;
    var effective_new_target = new_target_value;
    var current_args: []const core.JSValue = args;
    var owned_args: []core.JSValue = &.{};
    var rooted_owned_args: []core.JSValue = &.{};
    var owned_args_root = ValueSliceRoot{};
    owned_args_root.init(rt, &rooted_owned_args);
    defer owned_args_root.deinit();
    errdefer if (owned_args.len != 0) {
        freeArgs(rt, owned_args);
        rooted_owned_args = &.{};
    };

    while (callableObjectFromValue(target)) |function_object| {
        if (function_object.class_id != core.class.ids.bound_function) break;
        const combined = try boundFunctionArgs(rt, function_object, current_args);
        const previous_owned_args = owned_args;
        rooted_owned_args = combined;
        owned_args = combined;
        current_args = owned_args;
        if (previous_owned_args.len != 0) freeArgs(rt, previous_owned_args);
        const next_target = function_object.boundTarget() orelse return error.TypeError;
        if (target.sameValue(effective_new_target)) {
            effective_new_target = next_target;
        }
        target = next_target;
    }

    return .{
        .target = target,
        .new_target = effective_new_target,
        .args = current_args,
        .owned_args = owned_args,
    };
}

pub fn rejectModuleNamespaceSuperSet(ctx: *core.JSContext, receiver: core.JSValue, atom_id: core.Atom) !bool {
    const receiver_object = objectFromValue(receiver) orelse return false;
    if (receiver_object.class_id != core.class.ids.module_ns) return false;
    if (receiver_object.moduleNamespaceOwnBindingValue(atom_id)) |binding_value| {
        defer binding_value.free(ctx.runtime);
        if (binding_value.isUninitialized()) return error.ReferenceError;
        return error.TypeError;
    }
    return error.TypeError;
}

var promise_jobs: usize = 0;
fn countPromiseJob(_: *core.JSContext, args: []const core.JSValue) core.JSValue {
    promise_jobs += 1;
    if (args.len >= 1) promise_jobs += @intCast(args[0].asInt32().?);
    return core.JSValue.undefinedValue();
}

test "promise enqueues reactions and executes jobs via engine" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    rt.materialize_context_global_cb = struct {
        fn cb(c: *core.JSContext) anyerror!*core.Object {
            return try zjs_vm.contextGlobal(c);
        }
    }.cb;
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    promise_jobs = 0;
    try core.promise.enqueueReaction(ctx, countPromiseJob, &.{core.JSValue.int32(2)});

    rt.job_queue.runAll();
    const global_object = try ctx.globalObject();
    try drainPendingPromiseJobs(ctx, null, global_object);

    try std.testing.expectEqual(@as(usize, 3), promise_jobs);
}

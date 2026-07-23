const std = @import("std");
const bytecode = @import("../bytecode.zig");
const core = @import("../core/root.zig");
const jobs_mod = @import("../core/jobs.zig");
const call_mod = @import("call.zig");
const frame_mod = @import("frame.zig");
const property_ops = @import("property_ops.zig");
const zjs_vm = @import("zjs_vm.zig");
const stack_mod = @import("stack.zig");
const value_ops = @import("value_ops.zig");

pub const LegacyStaticMethod = core.host_function.builtin_method_ids.promise.LegacyStaticMethod;

pub fn legacyStaticMethodId(name: []const u8) ?u32 {
    if (std.mem.eql(u8, name, "resolve")) return @intFromEnum(LegacyStaticMethod.resolve);
    if (std.mem.eql(u8, name, "all")) return @intFromEnum(LegacyStaticMethod.all);
    if (std.mem.eql(u8, name, "race")) return @intFromEnum(LegacyStaticMethod.race);
    if (std.mem.eql(u8, name, "reject")) return @intFromEnum(LegacyStaticMethod.reject);
    if (std.mem.eql(u8, name, "allSettled")) return @intFromEnum(LegacyStaticMethod.all_settled);
    if (std.mem.eql(u8, name, "any")) return @intFromEnum(LegacyStaticMethod.any);
    if (std.mem.eql(u8, name, "try")) return @intFromEnum(LegacyStaticMethod.try_);
    if (std.mem.eql(u8, name, "withResolvers")) return @intFromEnum(LegacyStaticMethod.with_resolvers);
    if (std.mem.eql(u8, name, "allKeyed")) return @intFromEnum(LegacyStaticMethod.all_keyed);
    if (std.mem.eql(u8, name, "allSettledKeyed")) return @intFromEnum(LegacyStaticMethod.all_settled_keyed);
    return null;
}

const HostError = exceptions.HostError;
const rejectedPromiseForRuntimeError = exception_ops.rejectedPromiseForRuntimeError;
const qjsPromiseAggregateError = exception_ops.qjsPromiseAggregateError;
const qjsPromiseErrorValue = exception_ops.qjsPromiseErrorValue;
const runWithCallEnv = zjs_vm.runWithCallEnv;
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
const runNextAtomicsHostCompletion = call_runtime.runNextAtomicsHostCompletion;
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

pub fn promisePrototypeFromGlobal(rt: *core.JSRuntime, global: *core.Object) ?*core.Object {
    if (global.cachedPromiseProto(rt)) |prototype| return prototype;
    const promise_atom = rt.internAtom("Promise") catch return null;
    defer rt.atoms.free(promise_atom);
    const promise_constructor = global.getOwnDataObjectBorrowed(promise_atom) orelse return null;
    return promise_constructor.getOwnDataObjectBorrowed(core.atom.ids.prototype);
}

pub fn asyncFunctionPrototypeFromGlobal(rt: *core.JSRuntime, global: *core.Object) !?*core.Object {
    if (cachedRealmObject(rt, global, .async_function_prototype)) |stored| return stored;

    const prototype = try core.Object.create(rt, core.class.ids.object, functionPrototypeFromGlobal(rt, global));
    const prototype_value = prototype.value();
    var prototype_value_owned = true;
    errdefer if (prototype_value_owned) prototype_value.free(rt);
    const constructor = try core.function.nativeFunctionForGlobal(rt, global, "AsyncFunction", 1);
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
    if (cachedRealmObject(rt, global, .async_iterator_prototype)) |stored| return stored;
    const object = try core.Object.create(rt, core.class.ids.object, objectPrototypeFromGlobal(rt, global));
    var object_raw_owned = true;
    errdefer if (object_raw_owned) core.Object.destroyFromHeader(rt, &object.header);
    const method = try core.function.nativeFunctionForGlobal(rt, global, "[Symbol.asyncIterator]", 0);
    defer method.free(rt);
    const async_iterator_atom = core.atom.predefinedId("Symbol.asyncIterator", .symbol) orelse return error.TypeError;
    try object.defineOwnProperty(rt, async_iterator_atom, core.Descriptor.data(method, true, false, true));
    if (core.atom.predefinedId("Symbol.asyncDispose", .symbol)) |async_dispose_atom| {
        const dispose = try core.function.nativeFunctionForGlobal(rt, global, "[Symbol.asyncDispose]", 0);
        defer dispose.free(rt);
        const dispose_object = objectFromValue(dispose) orelse return error.TypeError;
        if (!try dispose_object.addAsyncIteratorAsyncDisposeFunction(rt)) return error.TypeError;
        try object.defineOwnProperty(rt, async_dispose_atom, core.Descriptor.data(dispose, true, false, true));
    }
    const value = object.value();
    object_raw_owned = false;
    defer value.free(rt);
    try storeRealmValue(rt, global, .async_iterator_prototype, value);
    return object;
}

pub fn asyncGeneratorPrototypeFromGlobal(rt: *core.JSRuntime, global: *core.Object) !*core.Object {
    if (cachedRealmObject(rt, global, .async_generator_prototype)) |stored| return stored;
    const async_iterator_prototype = try asyncIteratorPrototypeFromGlobal(rt, global);
    const object = try core.Object.create(rt, core.class.ids.object, async_iterator_prototype);
    var object_raw_owned = true;
    errdefer if (object_raw_owned) core.Object.destroyFromHeader(rt, &object.header);
    try installAsyncGeneratorPrototypeProperties(rt, global, object);
    const value = object.value();
    object_raw_owned = false;
    defer value.free(rt);
    try storeRealmValue(rt, global, .async_generator_prototype, value);
    return object;
}

pub fn installAsyncGeneratorPrototypeProperties(rt: *core.JSRuntime, global: *core.Object, object: *core.Object) !void {
    try defineAsyncGeneratorDataMethod(rt, global, object, "next", 1);
    try defineAsyncGeneratorDataMethod(rt, global, object, "return", 1);
    try defineAsyncGeneratorDataMethod(rt, global, object, "throw", 1);

    const tag_atom = core.atom.predefinedId("Symbol.toStringTag", .symbol) orelse return error.TypeError;
    const tag = try value_ops.createStringValue(rt, "AsyncGenerator");
    defer tag.free(rt);
    try object.defineOwnProperty(rt, tag_atom, core.Descriptor.data(tag, false, false, true));
}

pub fn defineAsyncGeneratorDataMethod(rt: *core.JSRuntime, global: *core.Object, object: *core.Object, name: []const u8, length: i32) !void {
    const atom_id = try rt.internAtom(name);
    defer rt.atoms.free(atom_id);
    const method = try core.function.nativeFunctionForGlobal(rt, global, name, length);
    defer method.free(rt);
    const method_object = property_ops.expectObject(method) catch return error.TypeError;
    if (!try method_object.addAsyncGeneratorPrototypeMethod(rt)) return error.TypeError;
    try object.defineOwnProperty(rt, atom_id, core.Descriptor.data(method, true, false, true));
}

pub fn asyncGeneratorFunctionPrototypeFromGlobal(rt: *core.JSRuntime, global: *core.Object) !?*core.Object {
    if (cachedRealmObject(rt, global, .async_generator_function_prototype)) |stored| return stored;
    const object = try core.Object.create(rt, core.class.ids.object, functionPrototypeFromGlobal(rt, global));
    const object_value = object.value();
    var object_value_owned = true;
    errdefer if (object_value_owned) object_value.free(rt);
    const constructor = try core.function.nativeFunctionForGlobal(rt, global, "AsyncGeneratorFunction", 1);
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
    // Parser disposal capabilities are internal records, not observable
    // `AsyncDisposableStack` constructions. Keep the class payload/continuation
    // machinery while avoiding user-mutated constructor/prototype lookup.
    return qjsAsyncDisposableStackConstructWithPrototype(ctx, global, null);
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

pub fn qjsAsyncDisposableStackMethodCall(
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

pub fn qjsAsyncDisposableStackAdopt(
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

pub fn qjsAsyncDisposableStackDefer(
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

pub fn qjsAsyncDisposableStackMove(
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

pub fn qjsDefaultPromiseCapability(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    caller_function: ?*const bytecode.FunctionBytecode,
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
    caller_function: ?*const bytecode.FunctionBytecode,
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
    caller_function: ?*const bytecode.FunctionBytecode,
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
    const callback = try builtin_glue.qjsCreateDataFunction(rt, global, "", 1);
    errdefer callback.free(rt);
    const callback_object = objectFromValue(callback) orelse return error.TypeError;
    try callback_object.setInternalCallableTag(rt, .async_disposable_stack_continuation);
    try callback_object.setOptionalValueSlot(rt, try callback_object.functionAsyncDisposeStackSlot(rt), stack.value().dup());
    (try callback_object.functionAsyncDisposeRejectedSlot(rt)).* = rejected;
    return callback;
}

pub fn qjsAsyncDisposableStackContinuationCall(
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
    try qjsAsyncDisposableStackContinueOrReject(ctx, output, global, stack, rejection, caller_function, caller_frame);
    return core.JSValue.undefinedValue();
}

pub fn qjsAsyncDisposableStackContinueOrReject(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *core.Object,
    awaited_rejection: ?core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
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
    caller_function: ?*const bytecode.FunctionBytecode,
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
        if (resource.hint == .async) {
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
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    if (resource.method.isUndefined()) return core.JSValue.undefinedValue();
    const result = switch (resource.kind) {
        .use => try callValueOrBytecode(ctx, output, global, resource.value, resource.method, &.{}, caller_function, caller_frame),
        .adopt => try callValueOrBytecode(ctx, output, global, core.JSValue.undefinedValue(), resource.method, &.{resource.value}, caller_function, caller_frame),
        .defer_ => try callValueOrBytecode(ctx, output, global, core.JSValue.undefinedValue(), resource.method, &.{}, caller_function, caller_frame),
    };
    if (resource.method_kind == .async_from_sync) {
        result.free(ctx.runtime);
        return core.JSValue.undefinedValue();
    }
    return result;
}

pub fn qjsAsyncDisposableStackAwaitValue(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *core.Object,
    value: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
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

    // Same await-shaped internal attach as qjs js_async_function_resume
    // (quickjs.c:21268-21290): perform_promise_then, never a .then read.
    try qjsPerformPromiseThen(ctx, output, global, awaited, on_fulfilled, on_rejected, core.JSValue.undefinedValue(), core.JSValue.undefinedValue());
}

pub fn qjsAsyncDisposableStackRecordError(
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
    caller_function: ?*const bytecode.FunctionBytecode,
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
    caller_function: ?*const bytecode.FunctionBytecode,
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
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const executor = if (args.len >= 1) args[0] else return throwTypeErrorMessage(ctx, global, "not a function");
    if (!isCallableValue(executor)) return throwTypeErrorMessage(ctx, global, "not a function");
    const fallback_global = if (objectFromValue(constructor)) |constructor_object|
        objectRealmGlobal(constructor_object) orelse global
    else
        global;
    var resolved_prototype = try constructorPrototypeObject(ctx.runtime, constructor);
    defer resolved_prototype.deinit(ctx.runtime);
    const prototype = resolved_prototype.object() orelse promisePrototypeFromGlobal(ctx.runtime, fallback_global);
    return qjsPromiseConstructWithPrototype(ctx, output, global, prototype, args, caller_function, caller_frame);
}

pub fn qjsPromiseConstructWithPrototype(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    prototype: ?*core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const executor = if (args.len >= 1) args[0] else return throwTypeErrorMessage(ctx, global, "not a function");
    if (!isCallableValue(executor)) return throwTypeErrorMessage(ctx, global, "not a function");
    const promise = try core.promise.constructWithPrototype(ctx, prototype);
    errdefer promise.free(ctx.runtime);

    const resolving = try createPromiseResolvingPair(ctx.runtime, global, promise);
    const resolve = resolving.resolve;
    defer resolve.free(ctx.runtime);
    const reject = resolving.reject;
    defer reject.free(ctx.runtime);
    const result = callValueOrBytecode(ctx, output, global, core.JSValue.undefinedValue(), executor, &.{ resolve, reject }, caller_function, caller_frame) catch |err| {
        _ = objectFromValue(promise) orelse return err;
        var reason = try promiseRejectionReason(ctx, global, err);
        defer reason.deinit(ctx.runtime);
        // Abrupt executor completion must invoke the REJECT resolving function
        // (qjs js_promise_constructor: JS_Call(resolving_funcs[1], ...)), which
        // honors the [[AlreadyResolved]] once-guard, instead of settling the
        // promise directly (which would override a prior resolve()).
        const rejected = try callValueOrBytecode(ctx, output, global, core.JSValue.undefinedValue(), reject, &.{reason.value}, caller_function, caller_frame);
        rejected.free(ctx.runtime);
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

    const function_proto = functionPrototypeFromGlobal(rt, global) orelse return error.InvalidBuiltinRegistry;
    function_val = try core.function.nativeDataFunctionWithPrototype(rt, function_proto, "", 1);
    errdefer function_val.free(rt);
    const object = objectFromValue(function_val) orelse return error.TypeError;
    try object.setInternalCallableTag(rt, .promise_resolving);
    try object.setFunctionPromiseResolvingTarget(rt, rooted_promise.dup());
    try object.setFunctionPromiseResolvingState(rt, state_val.dup());
    (try object.functionPromiseResolvingRejectSlot(rt)).* = reject;
    return function_val;
}

fn testStandardGlobal(ctx: *core.JSContext) !*core.Object {
    @import("standard_globals.zig").configureRuntime(ctx.runtime);
    return zjs_vm.contextGlobal(ctx);
}

test "createPromiseResolvingFunction roots promise and state while allocating function" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    const global = try testStandardGlobal(ctx);

    const state = try createPromiseResolvingState(rt);
    var state_alive = true;
    defer if (state_alive) state.value().free(rt);
    const marker_key = try rt.internAtom("marker");
    defer rt.atoms.free(marker_key);
    const state_symbol = try rt.atoms.newValueSymbol("gc-qjs-promise-resolving-state-symbol");
    {
        const state_marker_value = try rt.symbolValue(state_symbol);
        defer state_marker_value.free(rt);
        try state.defineOwnProperty(rt, marker_key, core.Descriptor.data(state_marker_value, true, true, true));
    }

    const promise_symbol = try rt.atoms.newValueSymbol("gc-qjs-promise-resolving-target-symbol");
    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const promise_value = try rt.symbolValue(promise_symbol);
    var promise_value_alive = true;
    defer if (promise_value_alive) promise_value.free(rt);
    const function_value = try createPromiseResolvingFunction(rt, global, promise_value, true, state);
    promise_value.free(rt);
    promise_value_alive = false;
    var function_alive = true;
    defer if (function_alive) function_value.free(rt);
    const function_object = objectFromValue(function_value) orelse return error.TypeError;

    try std.testing.expect(rt.atoms.name(promise_symbol) != null);
    try std.testing.expect(rt.atoms.name(state_symbol) != null);
    try std.testing.expectEqual(promise_symbol, function_object.functionPromiseResolvingTarget().?.asSymbolAtom().?);
    try std.testing.expect(function_object.functionPromiseResolvingReject());

    state.value().free(rt);
    state_alive = false;
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(promise_symbol) != null);
    try std.testing.expect(rt.atoms.name(state_symbol) != null);
    const stored_state_value = function_object.functionPromiseResolvingState() orelse return error.TypeError;
    const stored_state = objectFromValue(stored_state_value) orelse return error.TypeError;
    {
        const marker_value = try stored_state.getProperty(marker_key);
        defer marker_value.free(rt);
        try std.testing.expectEqual(state_symbol, marker_value.asSymbolAtom().?);
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

    const on_fulfilled_value = try rt.symbolValue(on_fulfilled_symbol);
    var on_fulfilled_alive = true;
    defer if (on_fulfilled_alive) on_fulfilled_value.free(rt);
    const on_rejected_value = try rt.symbolValue(on_rejected_symbol);
    var on_rejected_alive = true;
    defer if (on_rejected_alive) on_rejected_value.free(rt);
    const resolve_value = try rt.symbolValue(resolve_symbol);
    var resolve_alive = true;
    defer if (resolve_alive) resolve_value.free(rt);
    const reject_value = try rt.symbolValue(reject_symbol);
    var reject_alive = true;
    defer if (reject_alive) reject_value.free(rt);
    const record_value = try qjsPromiseReactionRecord(rt, on_fulfilled_value, on_rejected_value, resolve_value, reject_value);
    on_fulfilled_value.free(rt);
    on_fulfilled_alive = false;
    on_rejected_value.free(rt);
    on_rejected_alive = false;
    resolve_value.free(rt);
    resolve_alive = false;
    reject_value.free(rt);
    reject_alive = false;
    var record_value_alive = true;
    defer if (record_value_alive) record_value.free(rt);
    const record = objectFromValue(record_value) orelse return error.TypeError;

    try std.testing.expect(rt.atoms.name(on_fulfilled_symbol) != null);
    try std.testing.expect(rt.atoms.name(on_rejected_symbol) != null);
    try std.testing.expect(rt.atoms.name(resolve_symbol) != null);
    try std.testing.expect(rt.atoms.name(reject_symbol) != null);
    try std.testing.expectEqual(on_fulfilled_symbol, record.promiseReactionOnFulfilled().?.asSymbolAtom().?);
    try std.testing.expectEqual(on_rejected_symbol, record.promiseReactionOnRejected().?.asSymbolAtom().?);
    try std.testing.expectEqual(resolve_symbol, record.promiseReactionResolve().?.asSymbolAtom().?);
    try std.testing.expectEqual(reject_symbol, record.promiseReactionReject().?.asSymbolAtom().?);

    record_value.free(rt);
    record_value_alive = false;
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(on_fulfilled_symbol) == null);
    try std.testing.expect(rt.atoms.name(on_rejected_symbol) == null);
    try std.testing.expect(rt.atoms.name(resolve_symbol) == null);
    try std.testing.expect(rt.atoms.name(reject_symbol) == null);
}

pub fn qjsPromiseReactionJob(
    ctx: *core.JSContext,
    reaction: *core.Object,
    value: core.JSValue,
    rejected: bool,
) !jobs_mod.Job {
    return jobs_mod.Job.initPromiseReaction(ctx, reaction.value(), value, rejected);
}

test "qjsPromiseReactionJob roots reaction and value while allocating job" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    const global = try core.Object.create(rt, core.class.ids.global_object, null);
    _ = try global.ensureGlobalPayload(rt);
    ctx.global = global;

    const reaction = try core.Object.create(rt, core.class.ids.object, null);
    var reaction_alive = true;
    defer if (reaction_alive) reaction.value().free(rt);
    const marker_key = try rt.internAtom("marker");
    defer rt.atoms.free(marker_key);
    const reaction_symbol = try rt.atoms.newValueSymbol("gc-qjs-promise-reaction-record-symbol");
    {
        const reaction_marker_value = try rt.symbolValue(reaction_symbol);
        defer reaction_marker_value.free(rt);
        try reaction.defineOwnProperty(rt, marker_key, core.Descriptor.data(reaction_marker_value, true, true, true));
    }

    const value_symbol = try rt.atoms.newValueSymbol("gc-qjs-promise-reaction-value-symbol");
    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const reaction_payload = try rt.symbolValue(value_symbol);
    var reaction_payload_alive = true;
    defer if (reaction_payload_alive) reaction_payload.free(rt);
    var job = try qjsPromiseReactionJob(ctx, reaction, reaction_payload, true);
    var job_alive = true;
    defer if (job_alive) job.deinit();
    reaction_payload.free(rt);
    reaction_payload_alive = false;

    try std.testing.expect(rt.atoms.name(reaction_symbol) != null);
    try std.testing.expect(rt.atoms.name(value_symbol) != null);
    try std.testing.expectEqual(value_symbol, job.payload.promise_reaction.value.asSymbolAtom().?);
    try std.testing.expect(job.payload.promise_reaction.rejected);

    reaction.value().free(rt);
    reaction_alive = false;
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(reaction_symbol) != null);
    try std.testing.expect(rt.atoms.name(value_symbol) != null);
    const stored_reaction_value = job.payload.promise_reaction.reaction;
    const stored_reaction = objectFromValue(stored_reaction_value) orelse return error.TypeError;
    {
        const marker_value = try stored_reaction.getProperty(marker_key);
        defer marker_value.free(rt);
        try std.testing.expectEqual(reaction_symbol, marker_value.asSymbolAtom().?);
    }

    job.deinit();
    job_alive = false;
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(reaction_symbol) == null);
    try std.testing.expect(rt.atoms.name(value_symbol) == null);
}

pub const PreparedPromiseReactionJobs = struct {
    jobs: []jobs_mod.Job = &.{},
    initialized: usize = 0,
    reserved_entries: usize = 0,

    pub fn deinit(self: *PreparedPromiseReactionJobs, rt: *core.JSRuntime) void {
        if (self.reserved_entries != 0) {
            rt.job_queue.releaseReservedEntries(self.reserved_entries);
        }
        for (self.jobs[0..self.initialized]) |*job| job.deinit();
        if (self.jobs.len != 0) rt.memory.free(jobs_mod.Job, self.jobs);
        self.* = .{};
    }

    pub fn commit(self: *PreparedPromiseReactionJobs, ctx: *core.JSContext, promise: *core.Object) void {
        const reactions = promise.promiseReactions();
        if (self.initialized == 0) {
            std.debug.assert(self.reserved_entries == 0);
            self.* = .{};
            return;
        }
        std.debug.assert(self.reserved_entries == self.initialized);

        promise.promiseReactionsSlot().* = &.{};
        for (reactions) |reaction| reaction.free(ctx.runtime);
        ctx.runtime.memory.free(core.JSValue, reactions);

        for (self.jobs[0..self.initialized]) |job| {
            ctx.runtime.job_queue.enqueueReserved(job);
            self.reserved_entries -= 1;
        }

        ctx.runtime.memory.free(jobs_mod.Job, self.jobs);
        self.* = .{};
    }
};

test "prepared promise reaction jobs own direct symbol payloads" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    const reaction = try core.Object.create(rt, core.class.ids.object, null);
    defer reaction.value().free(rt);

    const jobs = try rt.memory.alloc(jobs_mod.Job, 2);
    const first_atom = try rt.atoms.newValueSymbol("gc-prepared-promise-job-root-first");
    const first = try rt.symbolValue(first_atom);
    defer first.free(rt);
    jobs[0] = try jobs_mod.Job.initPromiseReaction(ctx, reaction.value(), first, false);
    const second_atom = try rt.atoms.newValueSymbol("gc-prepared-promise-job-root-second");
    const second = try rt.symbolValue(second_atom);
    defer second.free(rt);
    jobs[1] = try jobs_mod.Job.initPromiseReaction(ctx, reaction.value(), second, false);
    var prepared = PreparedPromiseReactionJobs{
        .jobs = jobs,
        .initialized = 2,
    };
    defer prepared.deinit(rt);

    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(first_atom) != null);
    try std.testing.expect(rt.atoms.name(second_atom) != null);
}

pub fn qjsPreparePromiseReactionJobs(
    ctx: *core.JSContext,
    promise: *core.Object,
    value: core.JSValue,
    rejected: bool,
) !PreparedPromiseReactionJobs {
    const reactions = promise.promiseReactions();
    if (reactions.len == 0) return .{};
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

    const jobs = try ctx.runtime.memory.alloc(jobs_mod.Job, reactions.len);
    var prepared = PreparedPromiseReactionJobs{ .jobs = jobs };
    errdefer prepared.deinit(ctx.runtime);

    for (reactions) |reaction_value| {
        const reaction = objectFromValue(reaction_value) orelse return error.TypeError;
        prepared.jobs[prepared.initialized] = try qjsPromiseReactionJob(ctx, reaction, rooted_value, rejected);
        prepared.initialized += 1;
    }

    try ctx.runtime.job_queue.reserveEntries(prepared.initialized);
    prepared.reserved_entries = prepared.initialized;
    return prepared;
}

pub fn qjsQueuePromiseReactions(
    ctx: *core.JSContext,
    global: *core.Object,
    promise: *core.Object,
    value: core.JSValue,
    rejected: bool,
) !void {
    _ = global;
    var prepared = try qjsPreparePromiseReactionJobs(ctx, promise, value, rejected);
    errdefer prepared.deinit(ctx.runtime);
    prepared.commit(ctx, promise);
}

pub fn qjsPromiseSettleValue(
    ctx: *core.JSContext,
    global: *core.Object,
    promise: *core.Object,
    value: core.JSValue,
    rejected: bool,
) HostError!void {
    const had_reactions = promise.promiseReactions().len != 0;
    const needs_callback_job = promise.promiseReactionCallback() != null and promise.promiseReactionArg() == null;
    _ = global;
    var prepared_reactions = try qjsPreparePromiseReactionJobs(ctx, promise, value, rejected);
    errdefer prepared_reactions.deinit(ctx.runtime);
    var prepared_callback_job: ?jobs_mod.Job = null;
    var callback_reserved = false;
    errdefer {
        if (prepared_callback_job) |*job| job.deinit();
        if (callback_reserved) ctx.runtime.job_queue.releaseReservedEntries(1);
    }
    if (needs_callback_job) {
        try ctx.runtime.job_queue.reserveEntries(1);
        callback_reserved = true;
        prepared_callback_job = try jobs_mod.Job.initPromise(ctx, promise.value());
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
    if (rejected and !had_reactions and ctx.track_unhandled_rejections) {
        ctx.recordUnhandledPromiseRejection(promise.value(), value);
    }
    if (prepared_callback_job) |job| {
        ctx.runtime.job_queue.enqueueReserved(job);
        prepared_callback_job = null;
        callback_reserved = false;
    }
    prepared_reactions.commit(ctx, promise);
}

test "qjsPromiseSettleValue handles result self-assignment" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const global = try core.Object.create(rt, core.class.ids.global_object, null);
    _ = try global.ensureGlobalPayload(rt);
    ctx.global = global;
    const promise = try core.Object.create(rt, core.class.ids.promise, null);
    defer promise.value().free(rt);
    const result = try core.Object.create(rt, core.class.ids.object, null);

    try promise.setPromiseResult(rt, result.value().dup());
    result.value().free(rt);
    try std.testing.expectEqual(@as(i32, 1), result.header.meta().rc);

    const current = promise.promiseResult().?;
    try qjsPromiseSettleValue(ctx, global, promise, current, false);

    try std.testing.expectEqual(@as(i32, 1), result.header.meta().rc);
    try std.testing.expectEqual(&result.header, promise.promiseResult().?.refHeader().?);
}

test "qjsPromiseSettleValue roots direct symbol result while preparing reaction jobs" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    const ctx = try core.JSContext.create(rt);
    const global = try core.Object.create(rt, core.class.ids.global_object, null);
    _ = try global.ensureGlobalPayload(rt);
    ctx.global = global;
    const promise = try core.Object.create(rt, core.class.ids.promise, null);
    defer {
        promise.value().free(rt);
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
    const settle_value = try rt.symbolValue(symbol_atom);
    var settle_value_alive = true;
    defer if (settle_value_alive) settle_value.free(rt);
    try qjsPromiseSettleValue(ctx, global, promise, settle_value, false);
    settle_value.free(rt);
    settle_value_alive = false;

    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    const result = promise.promiseResult() orelse return error.TypeError;
    try std.testing.expectEqual(symbol_atom, result.asSymbolAtom().?);
    try std.testing.expectEqual(@as(usize, 1), ctx.runtime.job_queue.jobs.len);
    const job_value = ctx.runtime.job_queue.jobs[0].payload.promise_reaction.value;
    try std.testing.expectEqual(symbol_atom, job_value.asSymbolAtom().?);

    var pending_job = ctx.runtime.job_queue.takeFirst() orelse return error.TypeError;
    pending_job.deinit();
    try promise.setPromiseResult(rt, null);
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

test "qjsPromiseSettleValue preserves pending state across reaction prepare and FIFO reserve OOM" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    const global = try core.Object.create(rt, core.class.ids.global_object, null);
    _ = try global.ensureGlobalPayload(rt);
    ctx.global = global;
    const promise = try core.Object.create(rt, core.class.ids.promise, null);
    defer promise.value().free(rt);

    const reaction = try qjsPromiseReactionRecord(
        rt,
        core.JSValue.undefinedValue(),
        core.JSValue.undefinedValue(),
        core.JSValue.undefinedValue(),
        core.JSValue.undefinedValue(),
    );
    defer reaction.free(rt);
    try qjsAppendPromiseReaction(rt, promise, reaction);

    const baseline = rt.memory.allocated_bytes;
    const limits = [_]usize{
        baseline,
        baseline + @sizeOf(jobs_mod.Job),
    };
    for (limits) |limit| {
        rt.setMemoryLimit(limit);
        try std.testing.expectError(
            error.OutOfMemory,
            qjsPromiseSettleValue(ctx, global, promise, core.JSValue.int32(42), false),
        );
        rt.setMemoryLimit(null);
        try std.testing.expect(promise.promiseResult() == null);
        try std.testing.expectEqual(@as(usize, 1), promise.promiseReactions().len);
        try std.testing.expectEqual(@as(usize, 0), rt.job_queue.jobs.len);
        try std.testing.expectEqual(@as(usize, 0), rt.job_queue.reserved_entries);
        try std.testing.expectEqual(baseline, rt.memory.allocated_bytes);
    }

    try qjsPromiseSettleValue(ctx, global, promise, core.JSValue.int32(42), false);
    try std.testing.expectEqual(@as(?i32, 42), promise.promiseResult().?.asInt32());
    try std.testing.expectEqual(@as(usize, 0), promise.promiseReactions().len);
    try std.testing.expectEqual(@as(usize, 1), rt.job_queue.jobs.len);
    var queued = rt.job_queue.takeFirst().?;
    queued.deinit();
}

fn promiseSettlementMayAllocate(target: *const core.Object) bool {
    return target.promiseReactions().len != 0 or
        (target.promiseReactionCallback() != null and target.promiseReactionArg() == null);
}

/// Finish a resolving-function completion while holding one queue
/// reservation. If reaction preparation exhausts memory after the once-guard
/// has become visible, publish an allocation-free typed continuation into that
/// exact slot. The original resolving pair may then die; the Runtime FIFO is
/// the sole retry authority.
fn settlePromiseResolutionWithReservedOwner(
    ctx: *core.JSContext,
    global: *core.Object,
    target: *core.Object,
    completion: core.JSValue,
    rejected: bool,
    slot_reserved: *bool,
) HostError!void {
    std.debug.assert(slot_reserved.*);
    qjsPromiseSettleValue(ctx, global, target, completion, rejected) catch |err| {
        if (err != error.OutOfMemory) return err;
        ctx.runtime.job_queue.enqueueReserved(jobs_mod.Job.initPromiseSettlementNoFail(
            ctx,
            target.value(),
            completion,
            rejected,
        ));
        slot_reserved.* = false;
        return;
    };
    ctx.runtime.job_queue.releaseReservedEntries(1);
    slot_reserved.* = false;
}

/// Scalar/self-resolution has no intervening user callback, so a target with
/// no reaction/callback work settles without adding an artificial queue OOM
/// point. Otherwise reserve the durable retry owner before publishing the
/// shared once-guard.
fn publishPromiseResolution(
    ctx: *core.JSContext,
    global: *core.Object,
    state: *core.Object,
    target: *core.Object,
    completion: core.JSValue,
    rejected: bool,
) HostError!void {
    if (!promiseSettlementMayAllocate(target)) {
        (try state.promiseAlreadyResolvedSlot(ctx.runtime)).* = true;
        try qjsPromiseSettleValue(ctx, global, target, completion, rejected);
        return;
    }

    try ctx.runtime.job_queue.reserveEntries(1);
    var slot_reserved = true;
    defer if (slot_reserved) ctx.runtime.job_queue.releaseReservedEntries(1);
    (try state.promiseAlreadyResolvedSlot(ctx.runtime)).* = true;
    try settlePromiseResolutionWithReservedOwner(ctx, global, target, completion, rejected, &slot_reserved);
}

pub fn qjsPromiseResolvingFunctionCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    function_object: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) HostError!?core.JSValue {
    const target_value = function_object.functionPromiseResolvingTarget() orelse return null;
    const target = objectFromValue(target_value) orelse return core.JSValue.undefinedValue();
    if (target.class_id != core.class.ids.promise) return core.JSValue.undefinedValue();
    const state_value = function_object.functionPromiseResolvingState() orelse return error.TypeError;
    const state = objectFromValue(state_value) orelse return error.TypeError;
    if (target.promiseResult() != null) return core.JSValue.undefinedValue();
    if (state.promiseAlreadyResolved()) {
        // A prior call won the shared once-guard. Any allocation-sensitive
        // completion that could not settle synchronously is owned by the
        // Runtime FIFO, so later calls are true no-ops rather than an
        // out-of-order retry channel.
        return core.JSValue.undefinedValue();
    }

    const reject = function_object.functionPromiseResolvingReject();
    const value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    if (!reject and value.sameValue(target_value)) {
        // qjs js_promise_resolve_function_call (quickjs.c:53608):
        // JS_ThrowTypeError(ctx, "promise self resolution").
        const error_global = objectRealmGlobal(function_object) orelse global;
        const error_value = try exception_ops.createNamedError(ctx, error_global, "TypeError", "promise self resolution");
        defer error_value.free(ctx.runtime);
        try publishPromiseResolution(ctx, global, state, target, error_value, true);
        return core.JSValue.undefinedValue();
    }

    if (reject or !value.isObject() or objectFromValue(value) == null) {
        try publishPromiseResolution(ctx, global, state, target, value, reject);
        return core.JSValue.undefinedValue();
    }

    if (!reject and value.isObject()) {
        if (objectFromValue(value) != null) {
            // No native-promise special case: qjs js_promise_resolve_function_call
            // (quickjs.c:53600-53630) treats every object resolution uniformly —
            // Get(resolution, "then") once, and if callable enqueue the thenable
            // job (a settled/pending native promise is adopted via its `then`,
            // costing the same 2 ticks and observing patched `then`).
            const then_key = try ctx.runtime.internAtom("then");
            defer ctx.runtime.atoms.free(then_key);

            // Hold one FIFO slot before publishing the once-guard. After the
            // getter runs, a callable result can therefore be transferred to
            // a typed thenable job without any fallible work or lost owner.
            try ctx.runtime.job_queue.reserveEntries(1);
            var thenable_slot_reserved = true;
            defer if (thenable_slot_reserved) ctx.runtime.job_queue.releaseReservedEntries(1);

            (try state.promiseAlreadyResolvedSlot(ctx.runtime)).* = true;
            const then_value = getValueProperty(ctx, output, global, value, then_key, caller_function, caller_frame) catch |err| {
                const reason = try qjsPromiseErrorValue(ctx, global, err);
                defer reason.free(ctx.runtime);
                try settlePromiseResolutionWithReservedOwner(ctx, global, target, reason, true, &thenable_slot_reserved);
                return core.JSValue.undefinedValue();
            };
            defer then_value.free(ctx.runtime);
            if (isCallableValue(then_value)) {
                // Mirrors js_promise_resolve_function_call (quickjs.c:53626):
                // resolving with a callable-then object ALWAYS enqueues a
                // js_promise_resolve_thenable_job — never stored lazily, never
                // run synchronously; then is invoked exactly once, as a job.
                ctx.runtime.job_queue.enqueueReserved(jobs_mod.Job.initPromiseThenableNoFail(ctx, target_value, value, then_value));
                thenable_slot_reserved = false;
                return core.JSValue.undefinedValue();
            }

            try settlePromiseResolutionWithReservedOwner(ctx, global, target, value, false, &thenable_slot_reserved);
            return core.JSValue.undefinedValue();
        }
    }
    unreachable;
}

pub fn qjsPromiseThenableJob(
    ctx: *core.JSContext,
    target_value: core.JSValue,
    thenable_value: core.JSValue,
    then_value: core.JSValue,
) !jobs_mod.Job {
    return jobs_mod.Job.initPromiseThenable(ctx, target_value, thenable_value, then_value);
}

const PromiseJobOomProbe = struct {
    calls: usize = 0,
    fail: bool,

    fn call(ptr: *anyopaque, invocation: core.host_function.ExternalCall) anyerror!core.JSValue {
        const self: *PromiseJobOomProbe = @ptrCast(@alignCast(ptr));
        self.calls += 1;
        const rt = invocation.realm.runtime;
        rt.setMemoryLimit(rt.memory.allocated_bytes);
        if (self.fail) return error.TypeError;
        return core.JSValue.int32(77);
    }
};

fn promiseJobOomProbeFunction(
    ctx: *core.JSContext,
    probe: *PromiseJobOomProbe,
    name: []const u8,
) !core.JSValue {
    const external_id = try ctx.runtime.registerExternalHostFunction(.{
        .ptr = probe,
        .call = PromiseJobOomProbe.call,
    });
    const function = try core.function.nativeFunction(ctx, name, 0);
    errdefer function.free(ctx.runtime);
    const object = objectFromValue(function) orelse return error.TypeError;
    object.hostFunctionKindSlot().* = core.host_function.ids.external_host;
    object.externalHostFunctionIdSlot().* = external_id;
    return function;
}

const PromiseBareCapabilityErrorProbe = struct {
    calls: usize = 0,

    fn call(ptr: *anyopaque, _: core.host_function.ExternalCall) anyerror!core.JSValue {
        const self: *PromiseBareCapabilityErrorProbe = @ptrCast(@alignCast(ptr));
        self.calls += 1;
        return error.TypeError;
    }
};

fn promiseBareCapabilityErrorFunction(
    ctx: *core.JSContext,
    probe: *PromiseBareCapabilityErrorProbe,
) !core.JSValue {
    const external_id = try ctx.runtime.registerExternalHostFunction(.{
        .ptr = probe,
        .call = PromiseBareCapabilityErrorProbe.call,
    });
    const function = try core.function.nativeFunction(ctx, "bareCapabilityError", 0);
    errdefer function.free(ctx.runtime);
    const object = objectFromValue(function) orelse return error.TypeError;
    object.hostFunctionKindSlot().* = core.host_function.ids.external_host;
    object.externalHostFunctionIdSlot().* = external_id;
    return function;
}

fn appendDummyPromiseReaction(rt: *core.JSRuntime, promise: *core.Object) !void {
    const reaction = try qjsPromiseReactionRecord(
        rt,
        core.JSValue.undefinedValue(),
        core.JSValue.undefinedValue(),
        core.JSValue.undefinedValue(),
        core.JSValue.undefinedValue(),
    );
    defer reaction.free(rt);
    try qjsAppendPromiseReaction(rt, promise, reaction);
}

test "Promise executor recursive OOM rejects with preallocated reason" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    @import("standard_globals.zig").configureRuntime(rt);
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    defer rt.setMemoryLimit(null);
    const global = try zjs_vm.contextGlobal(ctx);
    const preallocated = ctx.preallocated_oom_error orelse return error.TestUnexpectedResult;

    var probe = PromiseJobOomProbe{ .fail = true };
    const executor = try promiseJobOomProbeFunction(ctx, &probe, "executorOomProbe");
    defer executor.free(rt);

    // The host executor first exhausts the heap and then reports a bare
    // TypeError. Error construction therefore recursively OOMs after user
    // code has run; rejection must retain the preallocated abrupt value, not
    // silently substitute `undefined` or invoke the executor again.
    const promise = try qjsPromiseConstructWithPrototype(
        ctx,
        null,
        global,
        null,
        &.{executor},
        null,
        null,
    );
    defer promise.free(rt);
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    const promise_object = objectFromValue(promise) orelse return error.TypeError;
    try std.testing.expect(promise_object.promiseIsRejected());
    const reason = promise_object.promiseResult() orelse return error.TestUnexpectedResult;
    try std.testing.expect(reason.same(preallocated));
    try std.testing.expect(!reason.isUndefined());
}

test "direct Promise resolve OOM is owned by FIFO after resolving pair collection" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    @import("standard_globals.zig").configureRuntime(rt);
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    defer rt.setMemoryLimit(null);
    const global = try zjs_vm.contextGlobal(ctx);

    const target = try core.Object.create(rt, core.class.ids.promise, null);
    defer target.value().free(rt);
    try appendDummyPromiseReaction(rt, target);
    const resolving = try createPromiseResolvingPair(rt, global, target.value());
    var resolving_alive = true;
    defer if (resolving_alive) {
        resolving.resolve.free(rt);
        resolving.reject.free(rt);
    };
    const resolve_object = objectFromValue(resolving.resolve) orelse return error.TypeError;
    const reject_object = objectFromValue(resolving.reject) orelse return error.TypeError;

    // Isolate the post-once-guard failure: the durable continuation slot is
    // already available, while preparing the target's reaction batch cannot
    // allocate.
    try rt.job_queue.ensureCapacity(1);
    rt.setMemoryLimit(rt.memory.allocated_bytes);
    const resolve_result = (try qjsPromiseResolvingFunctionCall(
        ctx,
        null,
        global,
        resolve_object,
        &.{core.JSValue.int32(41)},
        null,
        null,
    )).?;
    resolve_result.free(rt);
    try std.testing.expect(target.promiseResult() == null);
    try std.testing.expectEqual(@as(usize, 1), rt.job_queue.jobs.len);
    try std.testing.expectEqual(jobs_mod.Kind.promise_settlement, std.meta.activeTag(rt.job_queue.jobs[0].payload));

    // The paired reject cannot bypass the continuation's frozen FIFO
    // position; the once-guard makes it a no-op.
    const ignored_reject = (try qjsPromiseResolvingFunctionCall(
        ctx,
        null,
        global,
        reject_object,
        &.{core.JSValue.int32(99)},
        null,
        null,
    )).?;
    ignored_reject.free(rt);
    try std.testing.expectEqual(@as(usize, 1), rt.job_queue.jobs.len);

    resolving.resolve.free(rt);
    resolving.reject.free(rt);
    resolving_alive = false;
    _ = rt.runObjectCycleRemoval();

    rt.setMemoryLimit(null);
    try std.testing.expectEqual(jobs_mod.RunOneStatus.success, try drainOnePendingJob(ctx, null, global));
    try std.testing.expectEqual(@as(?i32, 41), target.promiseResult().?.asInt32());
    try std.testing.expect(!target.promiseIsRejected());
    try std.testing.expectEqual(@as(usize, 1), rt.job_queue.jobs.len);
    try std.testing.expectEqual(jobs_mod.RunOneStatus.success, try drainOnePendingJob(ctx, null, global));
}

test "custom Promise reaction capability bare error becomes runOne exception exactly once" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    @import("standard_globals.zig").configureRuntime(rt);
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    const global = try zjs_vm.contextGlobal(ctx);

    var probe = PromiseBareCapabilityErrorProbe{};
    const resolve = try promiseBareCapabilityErrorFunction(ctx, &probe);
    defer resolve.free(rt);
    const reaction = try qjsPromiseReactionRecord(
        rt,
        core.JSValue.undefinedValue(),
        core.JSValue.undefinedValue(),
        resolve,
        core.JSValue.undefinedValue(),
    );
    defer reaction.free(rt);
    try rt.job_queue.enqueuePromiseReaction(ctx, reaction, core.JSValue.int32(5), false);

    const TailJob = struct {
        fn run(_: *core.JSContext, _: []const core.JSValue) core.JSValue {
            return core.JSValue.int32(8);
        }
    };
    try rt.job_queue.enqueueFunc(ctx, TailJob.run, &.{});

    try std.testing.expectEqual(jobs_mod.RunOneStatus.exception, try drainOnePendingJob(ctx, null, global));
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expect(ctx.hasException());
    try std.testing.expectEqual(@as(usize, 1), rt.job_queue.jobs.len);
    const exception = ctx.takeException();
    exception.free(rt);

    try std.testing.expectEqual(jobs_mod.RunOneStatus.success, try drainOnePendingJob(ctx, null, global));
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expectEqual(jobs_mod.RunOneStatus.empty, try drainOnePendingJob(ctx, null, global));
}

test "Promise reaction OOM transfers internal settle to FIFO without invoking handler twice" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    @import("standard_globals.zig").configureRuntime(rt);
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    defer rt.setMemoryLimit(null);
    const global = try zjs_vm.contextGlobal(ctx);

    const target = try core.Object.create(rt, core.class.ids.promise, null);
    defer target.value().free(rt);
    try appendDummyPromiseReaction(rt, target);

    const resolving = try createPromiseResolvingPair(rt, global, target.value());
    defer resolving.resolve.free(rt);
    defer resolving.reject.free(rt);

    var probe = PromiseJobOomProbe{ .fail = false };
    const handler = try promiseJobOomProbeFunction(ctx, &probe, "reactionOomProbe");
    defer handler.free(rt);
    const reaction = try qjsPromiseReactionRecord(
        rt,
        handler,
        core.JSValue.undefinedValue(),
        resolving.resolve,
        resolving.reject,
    );
    defer reaction.free(rt);
    try rt.job_queue.enqueuePromiseReaction(ctx, reaction, core.JSValue.int32(1), false);

    try std.testing.expectEqual(jobs_mod.RunOneStatus.success, try drainOnePendingJob(ctx, null, global));
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expect(target.promiseResult() == null);
    try std.testing.expectEqual(@as(usize, 1), rt.job_queue.jobs.len);
    try std.testing.expectEqual(jobs_mod.Kind.promise_settlement, std.meta.activeTag(rt.job_queue.jobs[0].payload));
    try std.testing.expectEqual(@as(?i32, 77), rt.job_queue.jobs[0].payload.promise_settlement.completion.asInt32());

    rt.setMemoryLimit(null);
    try std.testing.expectEqual(jobs_mod.RunOneStatus.success, try drainOnePendingJob(ctx, null, global));
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expectEqual(@as(?i32, 77), target.promiseResult().?.asInt32());
    try std.testing.expectEqual(@as(usize, 1), rt.job_queue.jobs.len);
    try std.testing.expectEqual(jobs_mod.RunOneStatus.success, try drainOnePendingJob(ctx, null, global));
}

test "Promise resolving OOM keeps FIFO owner after then getter and resolver collection" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    @import("standard_globals.zig").configureRuntime(rt);
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    defer rt.setMemoryLimit(null);
    const global = try zjs_vm.contextGlobal(ctx);

    const target = try core.Object.create(rt, core.class.ids.promise, null);
    defer target.value().free(rt);
    try appendDummyPromiseReaction(rt, target);
    const resolving = try createPromiseResolvingPair(rt, global, target.value());
    var resolving_alive = true;
    defer if (resolving_alive) {
        resolving.resolve.free(rt);
        resolving.reject.free(rt);
    };
    const resolve_object = objectFromValue(resolving.resolve) orelse return error.TypeError;
    const state = objectFromValue(resolve_object.functionPromiseResolvingState().?) orelse return error.TypeError;

    const thenable = try core.Object.create(rt, core.class.ids.object, null);
    defer thenable.value().free(rt);
    var probe = PromiseJobOomProbe{ .fail = false };
    const getter = try promiseJobOomProbeFunction(ctx, &probe, "thenGetterOomProbe");
    defer getter.free(rt);
    const then_key = try rt.internAtom("then");
    defer rt.atoms.free(then_key);
    try thenable.defineOwnProperty(
        rt,
        then_key,
        core.Descriptor.accessor(getter, core.JSValue.undefinedValue(), true, true),
    );

    const direct_result = (try qjsPromiseResolvingFunctionCall(ctx, null, global, resolve_object, &.{thenable.value()}, null, null)).?;
    direct_result.free(rt);
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expect(state.promiseAlreadyResolved());
    try std.testing.expect(target.promiseResult() == null);
    try std.testing.expectEqual(@as(usize, 1), rt.job_queue.jobs.len);
    try std.testing.expectEqual(jobs_mod.Kind.promise_settlement, std.meta.activeTag(rt.job_queue.jobs[0].payload));

    resolving.resolve.free(rt);
    resolving.reject.free(rt);
    resolving_alive = false;
    _ = rt.runObjectCycleRemoval();

    rt.setMemoryLimit(null);
    try std.testing.expectEqual(jobs_mod.RunOneStatus.success, try drainOnePendingJob(ctx, null, global));
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expect(target.promiseResult().?.same(thenable.value()));
    try std.testing.expectEqual(@as(usize, 1), rt.job_queue.jobs.len);
    try std.testing.expectEqual(jobs_mod.RunOneStatus.success, try drainOnePendingJob(ctx, null, global));
}

test "Promise resolving getter throw plus settle OOM rejects once after resolver collection" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    @import("standard_globals.zig").configureRuntime(rt);
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    defer rt.setMemoryLimit(null);
    const global = try zjs_vm.contextGlobal(ctx);

    const target = try core.Object.create(rt, core.class.ids.promise, null);
    defer target.value().free(rt);
    try appendDummyPromiseReaction(rt, target);
    const resolving = try createPromiseResolvingPair(rt, global, target.value());
    var resolving_alive = true;
    defer if (resolving_alive) {
        resolving.resolve.free(rt);
        resolving.reject.free(rt);
    };
    const resolve_object = objectFromValue(resolving.resolve) orelse return error.TypeError;

    const thenable = try core.Object.create(rt, core.class.ids.object, null);
    defer thenable.value().free(rt);
    var probe = PromiseJobOomProbe{ .fail = true };
    const getter = try promiseJobOomProbeFunction(ctx, &probe, "thenGetterThrowOomProbe");
    defer getter.free(rt);
    const then_key = try rt.internAtom("then");
    defer rt.atoms.free(then_key);
    try thenable.defineOwnProperty(
        rt,
        then_key,
        core.Descriptor.accessor(getter, core.JSValue.undefinedValue(), true, true),
    );

    const direct_result = (try qjsPromiseResolvingFunctionCall(ctx, null, global, resolve_object, &.{thenable.value()}, null, null)).?;
    direct_result.free(rt);
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expect(target.promiseResult() == null);
    try std.testing.expectEqual(@as(usize, 1), rt.job_queue.jobs.len);
    try std.testing.expectEqual(jobs_mod.Kind.promise_settlement, std.meta.activeTag(rt.job_queue.jobs[0].payload));
    try std.testing.expect(rt.job_queue.jobs[0].payload.promise_settlement.rejected);

    resolving.resolve.free(rt);
    resolving.reject.free(rt);
    resolving_alive = false;
    _ = rt.runObjectCycleRemoval();

    rt.setMemoryLimit(null);
    try std.testing.expectEqual(jobs_mod.RunOneStatus.success, try drainOnePendingJob(ctx, null, global));
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expect(target.promiseResult() != null);
    try std.testing.expect(target.promiseIsRejected());
    try std.testing.expectEqual(@as(usize, 1), rt.job_queue.jobs.len);
    try std.testing.expectEqual(jobs_mod.RunOneStatus.success, try drainOnePendingJob(ctx, null, global));
}

test "Promise thenable OOM resumes rejection without invoking then twice" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    @import("standard_globals.zig").configureRuntime(rt);
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    defer rt.setMemoryLimit(null);
    const global = try zjs_vm.contextGlobal(ctx);

    const target = try core.Object.create(rt, core.class.ids.promise, null);
    defer target.value().free(rt);
    try appendDummyPromiseReaction(rt, target);
    const thenable = try core.Object.create(rt, core.class.ids.object, null);
    defer thenable.value().free(rt);

    var probe = PromiseJobOomProbe{ .fail = true };
    const then_function = try promiseJobOomProbeFunction(ctx, &probe, "thenableOomProbe");
    defer then_function.free(rt);
    try rt.job_queue.enqueuePromiseThenable(ctx, target.value(), thenable.value(), then_function);

    try std.testing.expectEqual(jobs_mod.RunOneStatus.success, try drainOnePendingJob(ctx, null, global));
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expect(target.promiseResult() == null);
    try std.testing.expectEqual(@as(usize, 1), rt.job_queue.jobs.len);
    try std.testing.expectEqual(jobs_mod.Kind.promise_settlement, std.meta.activeTag(rt.job_queue.jobs[0].payload));
    try std.testing.expect(rt.job_queue.jobs[0].payload.promise_settlement.rejected);

    rt.setMemoryLimit(null);
    try std.testing.expectEqual(jobs_mod.RunOneStatus.success, try drainOnePendingJob(ctx, null, global));
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expect(target.promiseResult() != null);
    try std.testing.expect(target.promiseIsRejected());
    try std.testing.expectEqual(@as(usize, 1), rt.job_queue.jobs.len);
    try std.testing.expectEqual(jobs_mod.RunOneStatus.success, try drainOnePendingJob(ctx, null, global));
}

test "qjsPromiseThenableJob roots direct function bytecode then callback while creating job" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const global = try core.Object.create(rt, core.class.ids.global_object, null);
    _ = try global.ensureGlobalPayload(rt);
    ctx.global = global;
    const target = try core.Object.create(rt, core.class.ids.promise, null);
    defer target.value().free(rt);
    const thenable = try core.Object.create(rt, core.class.ids.object, null);
    defer thenable.value().free(rt);

    const fb = try bytecode.FunctionBytecode.createFixture(rt, .{
        .flags = .{ .func_kind = .generator },
        .cpool_count = 1,
    });
    var fb_published = false;
    errdefer if (!fb_published) fb.destroyUnpublishedFixture(rt);
    const symbol_atom = try rt.atoms.newValueSymbol("gc-promise-thenable-job-bytecode-symbol");
    fb.cpoolSlice()[0] = try rt.symbolValue(symbol_atom);
    fb.publishFixtureNoFail(rt);
    fb_published = true;

    var then_callback = core.JSValue.functionBytecode(&fb.header);
    var then_callback_alive = true;
    defer if (then_callback_alive) then_callback.free(rt);

    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    var job = try qjsPromiseThenableJob(ctx, target.value(), thenable.value(), then_callback);
    var job_alive = true;
    defer if (job_alive) job.deinit();

    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    const stored = job.payload.promise_thenable.then_function;
    try std.testing.expect(stored.same(then_callback));

    job.deinit();
    job_alive = false;
    then_callback.free(rt);
    then_callback_alive = false;
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

pub fn qjsPromiseThenableJobCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    payload: *jobs_mod.PromiseThenablePayload,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) HostError!core.JSValue {
    if (payload.phase == .prepare) {
        // Preparation is the only phase that may be retried from its start:
        // no user code has run yet. Keep the pair in the entry so both the
        // once-guard and the functions survive any later rejection retry.
        const resolving = try createPromiseResolvingPair(ctx.runtime, global, payload.target);
        std.debug.assert(payload.resolving_resolve.isUndefined());
        std.debug.assert(payload.resolving_reject.isUndefined());
        payload.resolving_resolve = resolving.resolve;
        payload.resolving_reject = resolving.reject;
        payload.phase = .invoke;
    }

    invoke: {
        if (payload.phase == .invoke) {
            const then_result = callValueOrBytecode(
                ctx,
                output,
                global,
                payload.thenable,
                payload.then_function,
                &.{ payload.resolving_resolve, payload.resolving_reject },
                caller_function,
                caller_frame,
            ) catch |err| {
                // From this point onward the then callback must never run again:
                // it may already have called resolve/reject or performed arbitrary
                // side effects. Capture its abrupt completion in the entry and
                // resume only the rejection call after a retriable OOM.
                const reason = try qjsPromiseErrorValue(ctx, global, err);
                payload.replaceCompletionOwned(ctx.runtime, reason);
                payload.phase = .reject;
                break :invoke;
            };
            then_result.free(ctx.runtime);
            return core.JSValue.undefinedValue();
        }
    }

    std.debug.assert(payload.phase == .reject);
    const reject_result = try callValueOrBytecode(
        ctx,
        output,
        global,
        core.JSValue.undefinedValue(),
        payload.resolving_reject,
        &.{payload.completion},
        caller_function,
        caller_frame,
    );
    reject_result.free(ctx.runtime);
    return core.JSValue.undefinedValue();
}

fn qjsPromiseSettlementJobCall(
    ctx: *core.JSContext,
    global: *core.Object,
    payload: *const jobs_mod.PromiseSettlementPayload,
) HostError!void {
    const target = objectFromValue(payload.target) orelse return error.TypeError;
    if (target.class_id != core.class.ids.promise) return error.TypeError;
    // A second settlement cannot normally win because the resolving pair's
    // once-guard was published before this entry. Treat an already-settled
    // target as a completed continuation so teardown remains idempotent under
    // defensive host integration.
    if (target.promiseResult() != null) return;
    try qjsPromiseSettleValue(ctx, global, target, payload.completion, payload.rejected);
}

pub fn qjsPromiseReactionJobCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    payload: *jobs_mod.PromiseReactionPayload,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) HostError!core.JSValue {
    const reaction = objectFromValue(payload.reaction) orelse return error.TypeError;
    const resolve_value = reaction.promiseReactionResolve() orelse return error.TypeError;
    const reject_value = reaction.promiseReactionReject() orelse return error.TypeError;

    invoke: {
        if (payload.phase == .invoke) {
            const handler_value = if (payload.rejected) reaction.promiseReactionOnRejected() else reaction.promiseReactionOnFulfilled();
            const handler = handler_value orelse core.JSValue.undefinedValue();

            // perform_promise_then canonicalizes non-callable handlers to
            // undefined at registration time. Do not re-run IsCallable here:
            // a callable Proxy may have been revoked after registration and
            // must still be Called (and reject the child with TypeError), not
            // silently become the identity/thrower fallback.
            if (handler.isUndefined()) {
                payload.phase = if (payload.rejected) .reject else .resolve;
                break :invoke;
            }

            const callback_result = callValueOrBytecode(
                ctx,
                output,
                global,
                core.JSValue.undefinedValue(),
                handler,
                &.{payload.value},
                caller_function,
                caller_frame,
            ) catch |err| {
                // The handler has run and may have observable side effects. Store
                // its abrupt completion before attempting the capability reject,
                // so an OOM retries only that settle phase.
                const reason = try qjsPromiseErrorValue(ctx, global, err);
                payload.replaceValueOwned(ctx.runtime, reason);
                payload.phase = .reject;
                break :invoke;
            };
            if (payload.rejected) clearHandledRejectionException(ctx);
            payload.replaceValueOwned(ctx.runtime, callback_result);
            payload.phase = .resolve;
        }
    }

    const settle = switch (payload.phase) {
        .invoke => unreachable,
        .resolve => resolve_value,
        .reject => reject_value,
    };
    // qjs promise_reaction_job (quickjs.c:53415-53421): "as an extension,
    // we support undefined as value to avoid creating a dummy promise in the
    // 'await' implementation of async functions" — an undefined resolving
    // function is skipped and the value dropped.
    if (settle.isUndefined()) return core.JSValue.undefinedValue();
    const settle_result = callValueOrBytecode(
        ctx,
        output,
        global,
        core.JSValue.undefinedValue(),
        settle,
        &.{payload.value},
        caller_function,
        caller_frame,
    ) catch |err| {
        // A custom species capability can be an arbitrary host callable. Its
        // bare host error is still an abrupt ECMAScript job completion: make
        // sure runOne observes a value in the job realm's unique exception
        // slot. Retrying here would repeat user code, so the entry is consumed.
        if (!ctx.hasException()) {
            const reason = try qjsPromiseErrorValue(ctx, global, err);
            _ = ctx.throwValue(reason);
        }
        return err;
    };
    settle_result.free(ctx.runtime);
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
    caller_function: ?*const bytecode.FunctionBytecode,
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
    (try function_object.functionPromiseCombinatorCalledSlot(ctx.runtime)).* = true;

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
    caller_function: ?*const bytecode.FunctionBytecode,
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

    executor_value = try builtin_glue.qjsCreateDataFunction(ctx.runtime, constructor_global, "", 2);
    const executor_object = objectFromValue(executor_value) orelse return error.TypeError;
    try executor_object.setInternalCallableTag(ctx.runtime, .promise_capability_executor);
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

    var index: u32 = 0;
    while (index < keys.arrayLength()) : (index += 1) {
        const index_atom = core.atom.atomFromUInt32(index);
        key_value = try keys.getProperty(index_atom);
        defer {
            key_value.free(rt);
            key_value = core.JSValue.undefinedValue();
        }
        const key_atom = try property_ops.propertyKeyAtom(rt, key_value);
        defer rt.atoms.free(key_atom);
        value = try values.getProperty(index_atom);
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
    {
        const keyed_value = try rt.symbolValue(value_symbol);
        defer keyed_value.free(rt);
        try qjsPromiseSetArrayIndex(rt, values, 0, keyed_value);
    }

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
        const stored = try result.getProperty(answer_atom);
        defer stored.free(rt);
        try std.testing.expectEqual(value_symbol, stored.asSymbolAtom().?);
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

    const payload_value = try rt.symbolValue(symbol_atom);
    var payload_alive = true;
    defer if (payload_alive) payload_value.free(rt);
    const record_value = try qjsPromiseSettlementRecord(rt, false, payload_value);
    payload_value.free(rt);
    payload_alive = false;
    var record_alive = true;
    defer if (record_alive) record_value.free(rt);
    const record = objectFromValue(record_value) orelse return error.TypeError;

    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    const value_atom = try rt.internAtom("value");
    defer rt.atoms.free(value_atom);
    {
        const value = try record.getProperty(value_atom);
        defer value.free(rt);
        try std.testing.expectEqual(symbol_atom, value.asSymbolAtom().?);
    }

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

    const fb = try bytecode.FunctionBytecode.createFixture(rt, .{ .cpool_count = 1 });
    var fb_published = false;
    errdefer if (!fb_published) fb.destroyUnpublishedFixture(rt);
    const symbol_atom = try rt.atoms.newValueSymbol("gc-qjs-promise-combinator-state-resolve-bytecode-symbol");
    fb.cpoolSlice()[0] = try rt.symbolValue(symbol_atom);
    fb.publishFixtureNoFail(rt);
    fb_published = true;

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
    const callback = try builtin_glue.qjsCreateDataFunction(rt, global, "", 1);
    errdefer callback.free(rt);
    const callback_object = objectFromValue(callback) orelse return error.TypeError;
    try callback_object.setInternalCallableTag(rt, .promise_combinator_element);
    (try callback_object.functionPromiseCombinatorModeSlot(rt)).* = @intFromEnum(mode);
    try callback_object.setFunctionPromiseCombinatorState(rt, state.value().dup());
    (try callback_object.functionPromiseCombinatorIndexSlot(rt)).* = index;
    (try callback_object.functionPromiseCombinatorCalledSlot(rt)).* = false;
    return callback;
}

pub fn qjsPromiseRejectCapability(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    reject_value: core.JSValue,
    reason: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
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
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !void {
    const reason = try qjsPromiseErrorValue(ctx, global, err);
    defer reason.free(ctx.runtime);
    try qjsPromiseRejectCapability(ctx, output, global, reject_value, reason, caller_function, caller_frame);
}

pub fn qjsPromiseResolveIdentity(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    constructor_value: core.JSValue,
    value: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    const promise_object = objectFromValue(value) orelse return null;
    if (promise_object.class_id != core.class.ids.promise) return null;
    if (promiseConstructorDataValueForFastPath(promise_object)) |constructor| {
        if (constructor.sameValue(constructor_value)) return value.dup();
        return null;
    }
    const constructor = try getValueProperty(ctx, output, global, value, core.atom.ids.constructor, caller_function, caller_frame);
    defer constructor.free(ctx.runtime);
    if (constructor.sameValue(constructor_value)) return value.dup();
    return null;
}

/// QuickJS's `JS_GetProperty(..., JS_ATOM_constructor)` reaches the Promise's
/// ordinary shape/prototype chain directly. zjs's general resolver must also
/// support legacy class-name fallback for prototype-less internal promises,
/// so keep that authority for missing/accessor/exotic shapes while letting the
/// normal Promise.prototype data hit take the same direct walk as qjs.
fn promiseConstructorDataValueForFastPath(promise: *core.Object) ?core.JSValue {
    var cursor = promise;
    while (true) {
        if (cursor.needsSlowPropertyAccess()) return null;
        var slow_property = false;
        if (cursor.findOwnDataValueFast(core.atom.ids.constructor, &slow_property)) |value| return value;
        if (slow_property) return null;
        cursor = cursor.getPrototype() orelse return null;
    }
}

pub fn qjsPromiseDefaultConstructor(ctx: *core.JSContext, global: *core.Object) !core.JSValue {
    // qjs uses the cached intrinsic ctx->promise_ctor (js_async_function_resume
    // quickjs.c:21268, js_new_promise_capability quickjs.c:53745; set at
    // JS_AddIntrinsicPromise quickjs.c:54663) — never a globalThis.Promise
    // lookup, so deleting/replacing the global binding cannot break await or
    // the default species. The realm slot is populated at install time
    // (installPromiseExtras); the global read remains only as a fallback for
    // bare non-realm globals (unit-test contexts).
    if (global.cachedRealmValue(ctx.runtime, .promise_constructor)) |stored| return stored.dup();
    const promise_key = try ctx.runtime.internAtom("Promise");
    defer ctx.runtime.atoms.free(promise_key);
    return try global.getProperty(promise_key);
}

pub fn qjsPromiseSpeciesConstructor(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
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
    caller_function: ?*const bytecode.FunctionBytecode,
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

    // The combinator result array (Promise.all/allSettled) and the Promise.any
    // errors array (reuses this `values`) must carry %Array.prototype% so
    // `result instanceof Array` holds — qjs js_promise_all uses JS_NewArray
    // (quickjs.c:54012), not a null-proto object.
    const values = if (mode != .race) try core.Object.createArray(ctx.runtime, array_ops.arrayPrototypeFromGlobal(ctx.runtime, global)) else null;
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
    caller_function: ?*const bytecode.FunctionBytecode,
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

/// Per-method body for `Promise.resolve`, matching qjs
/// `js_promise_resolve(..., magic = 0)`. Keeping it separate prevents the
/// identity hot path from inheriting the combinator/reject/try/withResolvers
/// frame and register pressure of `qjsPromiseStaticCall`.
pub fn qjsPromiseResolveStaticCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    constructor_value: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    if (!constructor_value.isObject()) return error.TypeError;

    // qjs `js_promise_resolve` reads a native Promise's observable
    // `constructor` and returns an identity match before asking whether
    // `this_val` is a constructor. NewPromiseCapability performs that check
    // only after the identity arm misses. Besides matching the observable
    // getter/error order, this keeps the overwhelmingly common
    // `Promise.resolve(existingPromise)` path out of capability validation.
    const payload = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    if (try qjsPromiseResolveIdentity(ctx, output, global, constructor_value, payload, caller_function, caller_frame)) |same_promise| {
        return same_promise;
    }

    if (!(try isConstructorLike(ctx, constructor_value))) return error.TypeError;
    var capability = try qjsPromiseCapability(ctx, output, global, constructor_value, caller_function, caller_frame);
    errdefer capability.deinit(ctx.runtime);
    const resolve_result = try callValueOrBytecode(ctx, output, global, core.JSValue.undefinedValue(), capability.resolve, &.{payload}, caller_function, caller_frame);
    resolve_result.free(ctx.runtime);
    return capability.releaseCallbacks(ctx.runtime);
}

pub fn qjsPromiseStaticCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    constructor_value: core.JSValue,
    args: []const core.JSValue,
    mode: PromiseStaticMode,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    if (mode == .resolve) return qjsPromiseResolveStaticCall(ctx, output, global, constructor_value, args, caller_function, caller_frame);
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
        .resolve => unreachable,
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

pub fn promiseRejectionReason(
    ctx: *core.JSContext,
    global: *core.Object,
    err: anytype,
) HostError!PromiseRejectionReason {
    if (ctx.hasException()) {
        return .{
            .value = ctx.runtime.current_exception.dup(),
            .from_exception = true,
        };
    }

    const value = exception_ops.createNamedError(
        ctx,
        global,
        if (err == error.TypeError) "TypeError" else "Error",
        "",
    ) catch |create_err| {
        if (create_err == error.OutOfMemory) {
            // The executor/then callback has already run, so losing its abrupt
            // completion (or retrying it) is not an option.  Use the same
            // allocation-free recursive-OOM fallback as Promise jobs.
            if (ctx.preallocated_oom_error) |preallocated| return .{
                .value = preallocated.dup(),
                .from_exception = false,
            };
            return .{
                .value = core.JSValue.nullValue(),
                .from_exception = false,
            };
        }
        return @errorCast(create_err);
    };
    return .{
        .value = value,
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
    caller_function: ?*const bytecode.FunctionBytecode,
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
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    return constructDynamicFunctionFromSource(ctx, output, global, constructor, constructor, args, .async_generator, caller_function, caller_frame);
}

pub fn atomicsDestroyAsyncWaiter(waiter: *AtomicsWaiter) void {
    const ctx = waiter.realm.borrow().?;
    const rt = ctx.runtime;
    rt.assertOwnerThread();
    if (waiter.promise) |promise| promise.free(rt);
    atomicsReleaseWaiterKey(&waiter.key);
    waiter.realm.deinit();
    rt.memory.destroy(AtomicsWaiter, waiter);
}

pub fn atomicsDestroyAsyncWaiterOpaque(raw_waiter: *anyopaque) void {
    const waiter: *AtomicsWaiter = @ptrCast(@alignCast(raw_waiter));
    atomicsDestroyAsyncWaiter(waiter);
}

/// Run one owner-thread waitAsync completion. `drainOnePendingJob` reserves the
/// unlinked entry's queue slot before calling this function. Every failure is
/// before Promise publication and leaves that reservation untouched so the
/// typed completion can be restored at the FIFO head. Success consumes the
/// reservation with the follow-up Promise job as its final no-fail step.
pub fn atomicsRunAsyncWaiterCompletion(
    ctx: *core.JSContext,
    payload: *const jobs_mod.AtomicsWaiterPayload,
) core.context.DynamicImportError!void {
    const waiter: *AtomicsWaiter = @ptrCast(@alignCast(payload.waiter));
    std.debug.assert(waiter.realm.borrow() == ctx);
    ctx.runtime.assertOwnerThread();
    const promise = payload.promise;
    const promise_object = objectFromValue(promise) orelse return error.TypeError;
    if (promise_object.class_id != core.class.ids.promise) return error.TypeError;
    if (promise_object.promiseResultSlot().* != null) {
        ctx.runtime.job_queue.releaseReservedEntries(1);
        return;
    }
    const result = if (waiter.completion == .notified) "ok" else "timed-out";
    const result_value = try value_ops.createStringValue(ctx.runtime, result);
    var result_value_owned = true;
    errdefer if (result_value_owned) result_value.free(ctx.runtime);
    var prepared_job = try jobs_mod.Job.initPromise(ctx, promise);
    var prepared_job_owned = true;
    errdefer if (prepared_job_owned) prepared_job.deinit();

    const result_slot = promise_object.promiseResultSlot();

    var reaction_arg_value: ?core.JSValue = null;
    errdefer if (reaction_arg_value) |value| value.free(ctx.runtime);
    const reaction_arg_slot = promise_object.promiseReactionArgSlot();
    const needs_reaction_arg = promise_object.promiseReactionCallback() != null and promise_object.promiseReactionArg() == null;
    if (needs_reaction_arg) {
        reaction_arg_value = result_value.dup();
    }

    if (promise_object.promiseReactionCallback() != null) {
        // A .then/await already installed the lazy single reaction callback.
        // Leave the promise result unset: settlePendingPromiseReaction runs that
        // callback and then fires this promise's reaction list (which settles the
        // chained .then promise). Pre-setting the result here would make that
        // drain early-return (promiseResult != null) and drop the chain after the
        // first reaction. The callback receives the settle value via the reaction
        // arg below; free the now-unused result_value.
        result_value.free(ctx.runtime);
        result_value_owned = false;
    } else {
        const old_result = result_slot.*;
        result_slot.* = result_value;
        result_value_owned = false;
        promise_object.promiseIsRejectedSlot().* = false;
        if (old_result) |stored| stored.free(ctx.runtime);
    }
    if (reaction_arg_value) |value| {
        const old_reaction_arg = reaction_arg_slot.*;
        reaction_arg_slot.* = value;
        reaction_arg_value = null;
        if (old_reaction_arg) |stored| stored.free(ctx.runtime);
    }
    ctx.runtime.job_queue.enqueueReserved(prepared_job);
    prepared_job_owned = false;
}

pub fn qjsAtomicsWaitAsync(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
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

    const promise = try core.promise.constructWithPrototype(ctx, promisePrototypeFromGlobal(ctx.runtime, global));
    defer promise.free(ctx.runtime);
    if (objectFromValue(promise)) |promise_object| {
        promise_object.promiseAtomicsWaitAsyncSlot().* = true;
    }
    const deadline = if (atomicsWaitTimeoutMilliseconds(timeout)) |timeout_ms|
        std.Io.Timestamp.now(atomicsWaiterIo(), .awake).addDuration(std.Io.Duration.fromMilliseconds(timeout_ms))
    else
        null;
    const key = try atomicsWaiterKey(view, bytes);
    const waiter = try ctx.runtime.memory.create(AtomicsWaiter);
    atomicsRetainWaiterKey(key);
    waiter.* = .{
        .key = key,
        .promise = promise.dup(),
        .realm = core.RealmRef.retain(ctx),
        .deadline = deadline,
    };
    var waiter_owned = true;
    errdefer if (waiter_owned) atomicsDestroyAsyncWaiter(waiter);

    // The result wrapper is observable publication of this wait. Finish every
    // fallible allocation before linking the node into the cross-runtime
    // waiter registry; otherwise an OOM here leaves an unreachable Promise and
    // RealmRef behind until context teardown.
    const result = try atomicsWaitAsyncResult(ctx, true, promise);
    atomicsLinkAsyncWaiter(waiter);
    waiter_owned = false;
    return result;
}

pub fn atomicsLinkAsyncWaiter(waiter: *AtomicsWaiter) void {
    const ctx = waiter.realm.borrow().?;
    ctx.runtime.assertOwnerThread();
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

    const fb = try bytecode.FunctionBytecode.createFixture(rt, .{ .cpool_count = 1 });
    var fb_published = false;
    errdefer if (!fb_published) fb.destroyUnpublishedFixture(rt);
    const symbol_atom = try rt.atoms.newValueSymbol("gc-atomics-wait-async-result-bytecode-symbol");
    fb.cpoolSlice()[0] = try rt.symbolValue(symbol_atom);
    fb.publishFixtureNoFail(rt);
    fb_published = true;

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
    {
        const stored = try result.getProperty(value_key);
        defer stored.free(rt);
        try std.testing.expect(stored.same(result_payload));
    }

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
    var_refs: []const *core.VarRef,
    output: ?*std.Io.Writer,
    global: *core.Object,
) HostError!core.JSValue {
    const promise = try core.promise.constructWithPrototype(ctx, promisePrototypeFromGlobal(ctx.runtime, global));
    errdefer promise.free(ctx.runtime);

    const continuation_value = try createGeneratorObject(ctx, func, current_function_value, this_value, args, var_refs, output, global, false);
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
    const function_value = continuation.generatorFunctionBytecode() orelse return error.TypeError;
    const fb = functionBytecodeFromValue(function_value) orelse return error.TypeError;
    var nested_stack = stack_mod.Stack.init(&ctx.runtime.memory, ctx.runtime.stackSize());
    defer continuation.finalizeGeneratorExecutionCompletion(ctx.runtime);
    defer nested_stack.deinit(ctx.runtime);

    try setGeneratorResumeCompletionType(ctx.runtime, continuation, if (resume_rejected) 2 else 0);
    continuation.generatorExecutingSlot().* = true;
    defer continuation.generatorExecutingSlot().* = false;

    const async_global = objectRealmGlobal(continuation) orelse global;
    const current_function_value = continuation.generatorCurrentFunction() orelse continuation.value();
    const fb_runtime_strict = fb.isStrictMode() or fb.runtimeStrictMode();
    return runWithCallEnv(.{
        .ctx = ctx,
        .stack = &nested_stack,
        .function = fb,
        .initial_this_value = continuation.generatorThis() orelse core.JSValue.undefinedValue(),
        .args = continuation.generatorArgs(),
        .var_refs = continuation.generatorCaptures(),
        .output = output,
        .global = async_global,
        .strict_unresolved_get_var = fb_runtime_strict,
        .generator_state = continuation,
        .resume_value = resume_value,
        .current_function_value = current_function_value,
        .suspend_on_module_await = true,
    });
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
        continuation.completeGeneratorExecution(ctx.runtime);
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

    continuation.completeGeneratorExecution(ctx.runtime);
    try qjsAsyncFunctionSettle(ctx, output, async_global, continuation, result, false, null, null);
    qjsAsyncFunctionClearPromise(ctx.runtime, continuation);
}

pub fn qjsAsyncFunctionAwaitOrReject(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    continuation: *core.Object,
    awaited_value: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) HostError!void {
    qjsAsyncFunctionAwait(ctx, output, global, continuation, awaited_value, caller_function, caller_frame) catch |err| {
        continuation.completeGeneratorExecution(ctx.runtime);
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
    caller_function: ?*const bytecode.FunctionBytecode,
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

    // qjs js_async_function_resume (quickjs.c:21268-21290): the resume
    // callbacks attach through the INTERNAL perform_promise_then with
    // undefined resolving funcs — a (patched) Promise.prototype.then property
    // is never read for a native-promise await.
    try qjsPerformPromiseThen(ctx, output, global, awaited, on_fulfilled, on_rejected, core.JSValue.undefinedValue(), core.JSValue.undefinedValue());
}

pub fn qjsAsyncFunctionResumeCallback(
    rt: *core.JSRuntime,
    global: *core.Object,
    continuation: *core.Object,
    rejected: bool,
) !core.JSValue {
    const callback = try builtin_glue.qjsCreateDataFunction(rt, global, "", 1);
    errdefer callback.free(rt);
    const callback_object = objectFromValue(callback) orelse return error.TypeError;
    try callback_object.setInternalCallableTag(rt, .async_function_resume);
    try callback_object.setOptionalValueSlot(rt, try callback_object.functionAsyncContinuationSlot(rt), continuation.value().dup());
    (try callback_object.functionAsyncContinuationRejectedSlot(rt)).* = rejected;
    return callback;
}

pub fn qjsAsyncFunctionResumeCallbackCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    function_object: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
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
    caller_function: ?*const bytecode.FunctionBytecode,
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
    const global = try testStandardGlobal(ctx);
    const continuation = try core.Object.create(rt, core.class.ids.generator, null);
    defer {
        continuation.value().free(rt);
        ctx.destroy();
        rt.destroy();
    }

    const promise = try core.promise.constructWithPrototype(ctx, promisePrototypeFromGlobal(rt, global));
    defer promise.free(rt);
    try continuation.setOptionalValueSlot(rt, continuation.generatorAsyncPromiseSlot(), promise.dup());

    const symbol_atom = try rt.atoms.newValueSymbol("gc-async-settle-symbol");
    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);
    const settle_value = try rt.symbolValue(symbol_atom);
    var settle_value_alive = true;
    defer if (settle_value_alive) settle_value.free(rt);
    try qjsAsyncFunctionSettle(ctx, null, global, continuation, settle_value, false, null, null);
    settle_value.free(rt);
    settle_value_alive = false;

    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    const promise_object = objectFromValue(promise) orelse return error.TypeError;
    const result = promise_object.promiseResult() orelse return error.TypeError;
    try std.testing.expectEqual(symbol_atom, result.asSymbolAtom().?);

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

    const result = callValueOrBytecode(ctx, output, global, receiver, return_method, &.{core.JSValue.undefinedValue()}, caller_function, caller_frame) catch |err| {
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
        try qjsPerformPromiseThen(ctx, output, global, result, core.JSValue.undefinedValue(), core.JSValue.undefinedValue(), resolving.resolve, resolving.reject);
        return promise;
    }
    return try core.promise.fulfilledWithPrototype(ctx, core.JSValue.undefinedValue(), promisePrototypeFromGlobal(ctx.runtime, global));
}

pub fn qjsAsyncFromSyncIteratorMethodCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    function_object: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
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
        3 => try qjsAsyncFromSyncIteratorThrow(ctx, output, global, wrapper, sync_iterator, args, caller_function, caller_frame),
        else => null,
    };
}

/// Mirrors the GEN_MAGIC_THROW arm of js_async_from_sync_iterator_next
/// (quickjs.c:54503-54520): `.throw` is re-read per call; absent throw closes
/// the sync iterator and rejects TypeError "throw is not a method".
pub fn qjsAsyncFromSyncIteratorThrow(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    wrapper: *core.Object,
    sync_iterator: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    _ = wrapper;
    const throw_key = try ctx.runtime.internAtom("throw");
    defer ctx.runtime.atoms.free(throw_key);
    const throw_method = getValueProperty(ctx, output, global, sync_iterator, throw_key, caller_function, caller_frame) catch |err| {
        return rejectedPromiseForRuntimeError(ctx, global, err, promisePrototypeFromGlobal(ctx.runtime, global));
    };
    defer throw_method.free(ctx.runtime);
    if (throw_method.isUndefined() or throw_method.isNull()) {
        // IteratorClose(sync_iter) with no pending exception; a close failure
        // rejects with that error, otherwise reject the TypeError
        // (quickjs.c:54515-54519).
        call_runtime.qjsIteratorClose(ctx, output, global, sync_iterator, caller_function, caller_frame) catch |err| {
            return rejectedPromiseForRuntimeError(ctx, global, err, promisePrototypeFromGlobal(ctx.runtime, global));
        };
        const reason = try exception_ops.createNamedError(ctx, global, "TypeError", "throw is not a method");
        defer reason.free(ctx.runtime);
        return core.promise.rejectedWithPrototype(ctx, reason, promisePrototypeFromGlobal(ctx.runtime, global));
    }
    if (!isCallableValue(throw_method)) {
        const reason = try exception_ops.createNamedError(ctx, global, "TypeError", "throw is not a method");
        defer reason.free(ctx.runtime);
        return core.promise.rejectedWithPrototype(ctx, reason, promisePrototypeFromGlobal(ctx.runtime, global));
    }
    const result = if (args.len > 0)
        callValueOrBytecode(ctx, output, global, sync_iterator, throw_method, args[0..1], caller_function, caller_frame)
    else
        callValueOrBytecode(ctx, output, global, sync_iterator, throw_method, &.{}, caller_function, caller_frame);
    const throw_result = result catch |err| {
        return rejectedPromiseForRuntimeError(ctx, global, err, promisePrototypeFromGlobal(ctx.runtime, global));
    };
    defer throw_result.free(ctx.runtime);
    return qjsAsyncFromSyncIteratorContinuation(ctx, output, global, throw_result, sync_iterator, true, caller_function, caller_frame);
}

/// The onRejected close-wrap reaction (js_async_from_sync_iterator_close_wrap,
/// quickjs.c:54468-54476): re-throw the reason, close the sync iterator with
/// the exception pending (close errors swallowed), and propagate the rejection.
pub fn qjsAsyncFromSyncIteratorCloseWrap(
    rt: *core.JSRuntime,
    global: *core.Object,
    sync_iterator: core.JSValue,
) !core.JSValue {
    const callback = try builtin_glue.qjsCreateDataFunction(rt, global, "", 1);
    errdefer callback.free(rt);
    const callback_object = objectFromValue(callback) orelse return error.TypeError;
    try callback_object.setInternalCallableTag(rt, .async_from_sync_iterator_close_wrap);
    try callback_object.setOptionalValueSlot(rt, try callback_object.functionAsyncContinuationSlot(rt), sync_iterator.dup());
    return callback;
}

pub fn qjsAsyncFromSyncIteratorCloseWrapCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    function_object: *core.Object,
    args: []const core.JSValue,
) HostError!?core.JSValue {
    const sync_iterator = function_object.functionAsyncContinuation() orelse return null;
    const reason = if (args.len >= 1) args[0].dup() else core.JSValue.undefinedValue();
    defer reason.free(ctx.runtime);
    // JS_IteratorClose(…, TRUE): the close runs with the exception logically
    // pending — its own result and failures are discarded.
    call_runtime.qjsIteratorClose(ctx, output, global, sync_iterator, null, null) catch {
        if (ctx.hasException()) ctx.clearException();
    };
    _ = ctx.throwValue(reason.dup());
    return error.JSException;
}

pub fn qjsAsyncFromSyncIteratorNext(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    wrapper: *core.Object,
    sync_iterator: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
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
    return qjsAsyncFromSyncIteratorContinuation(ctx, output, global, next_result, sync_iterator, true, caller_function, caller_frame);
}

pub fn qjsAsyncFromSyncIteratorReturn(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    wrapper: *core.Object,
    sync_iterator: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
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
        return core.promise.fulfilledWithPrototype(ctx, done_result, promisePrototypeFromGlobal(ctx.runtime, global));
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
    return qjsAsyncFromSyncIteratorContinuation(ctx, output, global, return_result, sync_iterator, false, caller_function, caller_frame);
}

pub fn qjsAsyncFromSyncIteratorContinuation(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    result: core.JSValue,
    sync_iterator: core.JSValue,
    close_on_rejection: bool,
    caller_function: ?*const bytecode.FunctionBytecode,
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
        // PromiseResolve threw: close the sync iterator with the exception
        // pending, then reject (quickjs.c:54544-54549).
        if (close_on_rejection and !done) {
            call_runtime.qjsIteratorClose(ctx, output, global, sync_iterator, caller_function, caller_frame) catch {
                if (ctx.hasException()) ctx.clearException();
            };
        }
        try qjsPromiseRejectCapabilityForError(ctx, output, global, capability.reject, err, caller_function, caller_frame);
        return capability.releaseCallbacks(ctx.runtime);
    };
    defer value_wrapper_promise.free(ctx.runtime);

    const unwrap = try qjsAsyncFromSyncIteratorUnwrap(ctx.runtime, global, done);
    defer unwrap.free(ctx.runtime);

    // onRejected close-wrap only when `!done && magic != GEN_MAGIC_RETURN`
    // (quickjs.c:54570-54579).
    const close_wrap: core.JSValue = if (close_on_rejection and !done)
        try qjsAsyncFromSyncIteratorCloseWrap(ctx.runtime, global, sync_iterator)
    else
        core.JSValue.undefinedValue();
    defer close_wrap.free(ctx.runtime);

    qjsPerformPromiseThen(
        ctx,
        output,
        global,
        value_wrapper_promise,
        unwrap,
        close_wrap,
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
    const callback = try builtin_glue.qjsCreateDataFunction(rt, global, "", 1);
    errdefer callback.free(rt);
    const callback_object = objectFromValue(callback) orelse return error.TypeError;
    try callback_object.setInternalCallableTag(rt, .async_from_sync_iterator_unwrap);
    (try callback_object.functionAsyncFromSyncUnwrapDoneSlot(rt)).* = if (done) 2 else 1;
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

    const callback = try builtin_glue.qjsCreateDataFunction(rt, global, "", if (mode == .fulfill or mode == .reject) 1 else 0);
    errdefer callback.free(rt);
    const callback_object = objectFromValue(callback) orelse return error.TypeError;
    try callback_object.setInternalCallableTag(rt, .promise_finally_callback);
    (try callback_object.functionPromiseFinallyModeSlot(rt)).* = @intFromEnum(mode);
    if (payload != null) try callback_object.setFunctionPromiseFinallyPayload(rt, rooted_payload.dup());
    if (on_finally != null) try callback_object.setFunctionPromiseFinallyCallback(rt, rooted_on_finally.dup());
    if (constructor_value != null) try callback_object.setFunctionPromiseFinallyConstructor(rt, rooted_constructor.dup());
    return callback;
}

test "qjsPromiseFinallyCallback roots direct symbol payload while allocating callback" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    const global = try testStandardGlobal(ctx);

    const symbol_atom = try rt.atoms.newValueSymbol("gc-promise-finally-payload-symbol");
    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const payload_value = try rt.symbolValue(symbol_atom);
    var payload_alive = true;
    defer if (payload_alive) payload_value.free(rt);
    const callback = try qjsPromiseFinallyCallback(
        rt,
        global,
        .return_value,
        payload_value,
        null,
        null,
    );
    payload_value.free(rt);
    payload_alive = false;
    var callback_alive = true;
    defer if (callback_alive) callback.free(rt);
    const callback_object = objectFromValue(callback) orelse return error.TypeError;

    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    const stored = callback_object.functionPromiseFinallyPayload() orelse return error.TypeError;
    try std.testing.expectEqual(symbol_atom, stored.asSymbolAtom().?);

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
    caller_function: ?*const bytecode.FunctionBytecode,
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
    caller_function: ?*const bytecode.FunctionBytecode,
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
    _ = output;
    _ = global;
    const object = objectFromValue(receiver) orelse return error.TypeError;
    if (object.class_id != core.class.ids.promise) return error.TypeError;
    // zjs-specific Atomics.waitAsync promises settle through the lazy
    // promiseReactionCallback machinery. Foreign notify only publishes a
    // scalar winner; the typed Runtime FIFO completion later installs the
    // reaction argument on the owner thread. Keep the same fast path
    // qjsPromiseThen uses so awaiting a waitAsync promise still resumes.
    if (object.promiseResultSlot().* == null and !object.promiseIsRejected() and
        qjsAtomicsWaitAsyncPromise(ctx.runtime, object) and isCallableValue(on_fulfilled))
    {
        try object.setPromiseReactionCallback(ctx.runtime, on_fulfilled.dup());
        try object.setPromiseReactionArg(ctx.runtime, null);
        return;
    }
    const stored_on_fulfilled = if (isCallableValue(on_fulfilled)) on_fulfilled else core.JSValue.undefinedValue();
    const stored_on_rejected = if (isCallableValue(on_rejected)) on_rejected else core.JSValue.undefinedValue();
    const reaction = try qjsPromiseReactionRecord(ctx.runtime, stored_on_fulfilled, stored_on_rejected, resolve_value, reject_value);
    defer reaction.free(ctx.runtime);
    if (object.promiseResultSlot().* == null) {
        try qjsAppendPromiseReaction(ctx.runtime, object, reaction);
        if (object.promiseIsRejected()) core.promise.markHandled(ctx, object);
        return;
    }

    const result_value = if (object.promiseResult()) |stored| stored.dup() else core.JSValue.undefinedValue();
    defer result_value.free(ctx.runtime);
    const reaction_object = objectFromValue(reaction) orelse return error.TypeError;
    const rejected = object.promiseIsRejected();
    var prepared_job = try ctx.runtime.job_queue.preparePromiseReaction(ctx, reaction_object.value(), result_value, rejected);
    var prepared_job_owned = true;
    defer if (prepared_job_owned) prepared_job.deinit();
    try ctx.runtime.job_queue.reserveEntries(1);
    var job_slot_reserved = true;
    defer if (job_slot_reserved) ctx.runtime.job_queue.releaseReservedEntries(1);

    // QJS prepares reaction data before the handled tracker notification, then
    // performs only no-fail publication. Preserve that phase boundary: an OOM
    // above leaves the original rejection tracked and no phantom handled state.
    if (rejected) core.promise.markHandled(ctx, object);
    ctx.runtime.job_queue.enqueueReserved(prepared_job);
    prepared_job_owned = false;
    job_slot_reserved = false;
}

test "already-rejected Promise remains tracked when then preparation OOMs" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    @import("standard_globals.zig").configureRuntime(rt);
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    defer rt.setMemoryLimit(null);
    const global = try zjs_vm.contextGlobal(ctx);

    const reason = core.JSValue.int32(73);
    const promise_value = try core.promise.rejectedWithUnhandledPrototype(ctx, reason, null);
    defer promise_value.free(rt);
    try std.testing.expect(ctx.hasUnhandledRejection());
    try std.testing.expect(ctx.hasException());
    try std.testing.expect(ctx.runtime.current_exception.sameValue(reason));

    const baseline = rt.memory.allocated_bytes;
    rt.setMemoryLimit(baseline);
    try std.testing.expectError(error.OutOfMemory, qjsPerformPromiseThen(
        ctx,
        null,
        global,
        promise_value,
        core.JSValue.undefinedValue(),
        core.JSValue.undefinedValue(),
        core.JSValue.undefinedValue(),
        core.JSValue.undefinedValue(),
    ));
    try std.testing.expect(ctx.hasUnhandledRejection());
    try std.testing.expect(ctx.hasException());
    try std.testing.expect(ctx.runtime.current_exception.sameValue(reason));
    try std.testing.expectEqual(@as(usize, 0), rt.job_queue.jobs.len);
    try std.testing.expectEqual(@as(usize, 0), rt.job_queue.reserved_entries);
    try std.testing.expectEqual(baseline, rt.memory.allocated_bytes);

    rt.setMemoryLimit(null);
    try qjsPerformPromiseThen(
        ctx,
        null,
        global,
        promise_value,
        core.JSValue.undefinedValue(),
        core.JSValue.undefinedValue(),
        core.JSValue.undefinedValue(),
        core.JSValue.undefinedValue(),
    );
    try std.testing.expect(!ctx.hasUnhandledRejection());
    try std.testing.expect(!ctx.hasException());
    try std.testing.expectEqual(@as(usize, 1), rt.job_queue.jobs.len);
    try std.testing.expectEqual(jobs_mod.RunOneStatus.success, try drainOnePendingJob(ctx, null, global));
}

pub fn qjsPromiseThen(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    method_name: []const u8,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    const is_catch = std.mem.eql(u8, method_name, "catch");
    const is_finally = std.mem.eql(u8, method_name, "finally");
    if (is_finally) return try qjsPromiseFinally(ctx, output, global, receiver, args, caller_function, caller_frame);
    // Promise.prototype.catch is ALWAYS Invoke(this, "then", [undefined, arg])
    // (qjs js_promise_catch = JS_Invoke(this_val, JS_ATOM_then, ...),
    // quickjs.c:54275-54282) — it observes a user-overridden/patched `then`
    // and never takes the builtin then-capability fast path, so route every
    // catch (incl. on a genuine promise) through the generic this.then path.
    if (is_catch) return try qjsPromiseCatchGeneric(ctx, output, global, receiver, args);
    if (!receiver.isObject()) {
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
    const constructor_value = try qjsPromiseSpeciesConstructor(ctx, output, global, receiver, caller_function, caller_frame);
    defer constructor_value.free(ctx.runtime);
    var capability = try qjsPromiseCapability(ctx, output, global, constructor_value, caller_function, caller_frame);
    errdefer capability.deinit(ctx.runtime);
    const on_fulfilled = if (is_catch) core.JSValue.undefinedValue() else if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const on_rejected = if (is_catch) (if (args.len >= 1) args[0] else core.JSValue.undefinedValue()) else if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
    const stored_on_fulfilled = if (isCallableValue(on_fulfilled)) on_fulfilled else core.JSValue.undefinedValue();
    const stored_on_rejected = if (isCallableValue(on_rejected)) on_rejected else core.JSValue.undefinedValue();
    if (object.promiseResultSlot().* == null) {
        if (!object.promiseIsRejected() and qjsAtomicsWaitAsyncPromise(ctx.runtime, object) and isCallableValue(on_fulfilled)) {
            try object.setPromiseReactionCallback(ctx.runtime, on_fulfilled.dup());
            try object.setPromiseReactionArg(ctx.runtime, null);
            // The single reaction callback runs `on_fulfilled` when the
            // waitAsync promise settles; settlePendingPromiseReaction then fires
            // this promise's reaction list with the callback's result. Append a
            // pass-through reaction (undefined handlers) tied to the chained
            // `.then` capability so the returned promise settles with that
            // result — otherwise `waitAsync(...).value.then(a).then(b)` drops the
            // chain after the first reaction (b never runs).
            const chain_reaction = try qjsPromiseReactionRecord(ctx.runtime, core.JSValue.undefinedValue(), core.JSValue.undefinedValue(), capability.resolve, capability.reject);
            defer chain_reaction.free(ctx.runtime);
            try qjsAppendPromiseReaction(ctx.runtime, object, chain_reaction);
            if (object.promiseIsRejected()) core.promise.markHandled(ctx, object);
            return capability.releaseCallbacks(ctx.runtime);
        }
        const reaction = try qjsPromiseReactionRecord(ctx.runtime, stored_on_fulfilled, stored_on_rejected, capability.resolve, capability.reject);
        defer reaction.free(ctx.runtime);
        try qjsAppendPromiseReaction(ctx.runtime, object, reaction);
        if (object.promiseIsRejected()) core.promise.markHandled(ctx, object);
        return capability.releaseCallbacks(ctx.runtime);
    }
    const result_value = if (object.promiseResult()) |stored| stored.dup() else core.JSValue.undefinedValue();
    defer result_value.free(ctx.runtime);

    const reaction = try qjsPromiseReactionRecord(ctx.runtime, stored_on_fulfilled, stored_on_rejected, capability.resolve, capability.reject);
    defer reaction.free(ctx.runtime);
    const reaction_object = objectFromValue(reaction) orelse return error.TypeError;
    const rejected = object.promiseIsRejected();
    var prepared_job = try ctx.runtime.job_queue.preparePromiseReaction(ctx, reaction_object.value(), result_value, rejected);
    var prepared_job_owned = true;
    defer if (prepared_job_owned) prepared_job.deinit();
    try ctx.runtime.job_queue.reserveEntries(1);
    var job_slot_reserved = true;
    defer if (job_slot_reserved) ctx.runtime.job_queue.releaseReservedEntries(1);

    if (rejected) core.promise.markHandled(ctx, object);
    ctx.runtime.job_queue.enqueueReserved(prepared_job);
    prepared_job_owned = false;
    job_slot_reserved = false;
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
        var prepared_reactions = try qjsPreparePromiseReactionJobs(ctx, promise, next_result, is_rejected);
        errdefer prepared_reactions.deinit(ctx.runtime);
        promise.promiseIsRejectedSlot().* = is_rejected;
        try promise.setPromiseResult(ctx.runtime, next_result);
        next_result_owned = false;
        prepared_reactions.commit(ctx, promise);
        return;
    };
    defer callback_result.free(ctx.runtime);
    if (promise.promiseResult() != null or promise.promiseReactionCallback() != null) return;
    if (promise.promiseResult()) |stored| stored.free(ctx.runtime);
    if (objectFromValue(callback_result)) |result_promise| {
        if (result_promise.class_id == core.class.ids.promise and result_promise.promiseIsRejected()) {
            const next_result = if (result_promise.promiseResult()) |stored| stored.dup() else core.JSValue.undefinedValue();
            var next_result_owned = true;
            defer if (next_result_owned) next_result.free(ctx.runtime);
            var prepared_reactions = try qjsPreparePromiseReactionJobs(ctx, promise, next_result, true);
            errdefer prepared_reactions.deinit(ctx.runtime);
            try promise.setPromiseResult(ctx.runtime, next_result);
            next_result_owned = false;
            promise.promiseIsRejectedSlot().* = true;
            prepared_reactions.commit(ctx, promise);
            return;
        }
    }
    var prepared_reactions = try qjsPreparePromiseReactionJobs(ctx, promise, callback_result, false);
    errdefer prepared_reactions.deinit(ctx.runtime);
    try promise.setPromiseResult(ctx.runtime, callback_result.dup());
    promise.promiseIsRejectedSlot().* = false;
    prepared_reactions.commit(ctx, promise);
}

test "settlePendingPromiseReaction roots callback and arg after clearing promise slots" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    const ctx = try core.JSContext.create(rt);
    const global = try testStandardGlobal(ctx);
    const promise = try core.Object.create(rt, core.class.ids.promise, null);
    defer {
        promise.value().free(rt);
        ctx.destroy();
        rt.destroy();
    }

    const fb = try bytecode.FunctionBytecode.createFixture(rt, .{
        .realm = ctx,
        .flags = .{ .func_kind = .generator },
        .cpool_count = 1,
    });
    var fb_published = false;
    errdefer if (!fb_published) fb.destroyUnpublishedFixture(rt);
    const callback_symbol = try rt.atoms.newValueSymbol("gc-promise-reaction-callback-symbol");
    fb.cpoolSlice()[0] = try rt.symbolValue(callback_symbol);
    fb.publishFixtureNoFail(rt);
    fb_published = true;

    var callback = core.JSValue.functionBytecode(&fb.header);
    var callback_alive = true;
    defer if (callback_alive) callback.free(rt);
    const arg_symbol = try rt.atoms.newValueSymbol("gc-promise-reaction-arg-symbol");
    const arg_value = try rt.symbolValue(arg_symbol);
    try promise.setPromiseReactionCallback(rt, callback.dup());
    try promise.setPromiseReactionArg(rt, arg_value);

    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);
    try settlePendingPromiseReaction(ctx, null, global, promise);

    try std.testing.expect(rt.atoms.name(callback_symbol) != null);
    try std.testing.expect(rt.atoms.name(arg_symbol) != null);

    const result = promise.promiseResult() orelse return error.TypeError;
    const generator = objectFromValue(result) orelse return error.TypeError;
    try std.testing.expect(generator.generatorExecutionState().has_frame);
    try std.testing.expectEqual(@as(usize, 0), generator.generatorPc());
    try std.testing.expectEqual(@as(usize, 1), generator.generatorArgs().len);
    try std.testing.expectEqual(arg_symbol, generator.generatorArgs()[0].asSymbolAtom().?);

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

    while (promise.promiseResultSlot().* == null) {
        while (true) switch (try drainOnePendingJob(ctx, output, global)) {
            .empty => break,
            .success => {},
            .exception => return error.JSException,
        };
        if (promise.promiseResultSlot().* != null) break;
        if (!try runNextAtomicsHostCompletion(ctx, true)) return;
    }
}

pub fn drainPendingPromiseJobs(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
) HostError!void {
    while (true) {
        while (true) switch (try drainOnePendingJob(ctx, output, global)) {
            .empty => break,
            .success => {},
            .exception => return error.JSException,
        };
        if (try call_mod.runNextOsSignalHandler(ctx, output, global)) continue;
        if (try runNextOsRwHandler(ctx, output, global)) continue;
        if (try runNextOsTimer(ctx, output, global)) continue;
        if (try runNextAtomicsHostCompletion(ctx, false)) continue;
        break;
    }
}

fn promiseReactionInternalSettleCanRetry(payload: *const jobs_mod.PromiseReactionPayload) bool {
    if (payload.phase == .invoke) return false;
    const reaction = objectFromValue(payload.reaction) orelse return false;
    const settle = switch (payload.phase) {
        .invoke => unreachable,
        .resolve => reaction.promiseReactionResolve(),
        .reject => reaction.promiseReactionReject(),
    } orelse return false;
    const function = objectFromValue(settle) orelse return false;
    return function.internalCallableTag() == .promise_resolving;
}

/// Execute exactly one typed ECMAScript FIFO entry. The host context selects
/// the Runtime only; the entry's owned RealmRef selects the execution realm.
pub fn drainOnePendingJob(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
) HostError!jobs_mod.RunOneStatus {
    _ = global;
    try processExpiredAtomicsWaiters(ctx);
    if (!ctx.runtime.job_queue.hasJobs()) return .empty;

    var entry = ctx.runtime.job_queue.takeFirst().?;
    var entry_owned = true;
    defer if (entry_owned) entry.deinit();
    const job_ctx = entry.realm.borrow() orelse unreachable;
    const job_global = job_ctx.global orelse return error.InvalidBuiltinRegistry;
    var result: ?core.JSValue = null;
    switch (entry.payload) {
        .generic => {
            result = entry.run();
        },
        .promise => |*payload| {
            const job = payload.value;
            if (objectFromValue(job)) |object| {
                if (object.class_id == core.class.ids.promise) {
                    settlePendingPromiseReaction(job_ctx, output, job_global, object) catch |err| {
                        if (job_ctx.hasException()) return .exception;
                        return err;
                    };
                } else if (isCallableValue(job)) {
                    result = callValueOrBytecode(job_ctx, output, job_global, job_global.value(), job, &.{}, null, null) catch |err| {
                        if (job_ctx.hasException()) return .exception;
                        return err;
                    };
                }
            } else if (isCallableValue(job)) {
                result = callValueOrBytecode(job_ctx, output, job_global, job_global.value(), job, &.{}, null, null) catch |err| {
                    if (job_ctx.hasException()) return .exception;
                    return err;
                };
            }
        },
        .promise_reaction => |*payload| {
            const reservations_before = ctx.runtime.job_queue.reserved_entries;
            ctx.runtime.job_queue.reserveUnlinkedEntrySlot();
            result = qjsPromiseReactionJobCall(job_ctx, output, job_global, payload, null, null) catch |err| {
                if (err == error.OutOfMemory and promiseReactionInternalSettleCanRetry(payload)) {
                    std.debug.assert(ctx.runtime.job_queue.reserved_entries == reservations_before + 1);
                    ctx.runtime.job_queue.prependReserved(entry);
                    entry_owned = false;
                    return err;
                }
                ctx.runtime.job_queue.releaseReservedEntries(1);
                if (job_ctx.hasException()) return .exception;
                return err;
            };
            ctx.runtime.job_queue.releaseReservedEntries(1);
            std.debug.assert(ctx.runtime.job_queue.reserved_entries == reservations_before);
        },
        .promise_thenable => |*payload| {
            const reservations_before = ctx.runtime.job_queue.reserved_entries;
            ctx.runtime.job_queue.reserveUnlinkedEntrySlot();
            result = qjsPromiseThenableJobCall(job_ctx, output, job_global, payload, null, null) catch |err| {
                if (err == error.OutOfMemory) {
                    std.debug.assert(ctx.runtime.job_queue.reserved_entries == reservations_before + 1);
                    ctx.runtime.job_queue.prependReserved(entry);
                    entry_owned = false;
                    return err;
                }
                ctx.runtime.job_queue.releaseReservedEntries(1);
                if (job_ctx.hasException()) return .exception;
                return err;
            };
            ctx.runtime.job_queue.releaseReservedEntries(1);
            std.debug.assert(ctx.runtime.job_queue.reserved_entries == reservations_before);
        },
        .promise_settlement => |*payload| {
            const reservations_before = ctx.runtime.job_queue.reserved_entries;
            ctx.runtime.job_queue.reserveUnlinkedEntrySlot();
            qjsPromiseSettlementJobCall(job_ctx, job_global, payload) catch |err| {
                if (err == error.OutOfMemory) {
                    std.debug.assert(ctx.runtime.job_queue.reserved_entries == reservations_before + 1);
                    ctx.runtime.job_queue.prependReserved(entry);
                    entry_owned = false;
                    return err;
                }
                ctx.runtime.job_queue.releaseReservedEntries(1);
                if (job_ctx.hasException()) return .exception;
                return err;
            };
            ctx.runtime.job_queue.releaseReservedEntries(1);
            std.debug.assert(ctx.runtime.job_queue.reserved_entries == reservations_before);
        },
        .dynamic_import => |*payload| {
            const reservations_before = ctx.runtime.job_queue.reserved_entries;
            ctx.runtime.job_queue.reserveUnlinkedEntrySlot();
            result = payload.runner(job_ctx, output, payload) catch |err| {
                if (err == error.OutOfMemory) {
                    std.debug.assert(ctx.runtime.job_queue.reserved_entries == reservations_before + 1);
                    ctx.runtime.job_queue.prependReserved(entry);
                    entry_owned = false;
                    return err;
                }
                ctx.runtime.job_queue.releaseReservedEntries(1);
                if (job_ctx.hasException()) return .exception;
                return err;
            };
            ctx.runtime.job_queue.releaseReservedEntries(1);
            std.debug.assert(ctx.runtime.job_queue.reserved_entries == reservations_before);
        },
        .atomics_waiter => |*payload| {
            const reservations_before = ctx.runtime.job_queue.reserved_entries;
            ctx.runtime.job_queue.reserveUnlinkedEntrySlot();
            payload.runner(job_ctx, payload) catch |err| {
                std.debug.assert(ctx.runtime.job_queue.reserved_entries == reservations_before + 1);
                ctx.runtime.job_queue.prependReserved(entry);
                entry_owned = false;
                return err;
            };
            std.debug.assert(ctx.runtime.job_queue.reserved_entries == reservations_before);
        },
        .finalization => |*payload| {
            result = callValueOrBytecode(job_ctx, output, job_global, core.JSValue.undefinedValue(), payload.callback, &.{payload.held_value}, null, null) catch |err| {
                if (job_ctx.hasException()) return .exception;
                return err;
            };
        },
    }
    if (result) |value| {
        const status: jobs_mod.RunOneStatus = if (value.isException()) .exception else .success;
        value.free(job_ctx.runtime);
        if (status == .exception) return .exception;
    }
    pollGCSafePoint(job_ctx) catch |err| {
        if (job_ctx.hasException()) return .exception;
        return err;
    };
    return .success;
}

pub fn enqueuePendingPromiseJob(ctx: *core.JSContext, promise: core.JSValue) !void {
    try ctx.runtime.job_queue.enqueuePromise(ctx, promise);
}

pub fn awaitThenableValue(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    awaited: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) HostError!?core.JSValue {
    const awaited_object = objectFromValue(awaited) orelse return null;
    if (awaited_object.class_id == core.class.ids.promise) return null;

    const then_key = try ctx.runtime.internAtom("then");
    defer ctx.runtime.atoms.free(then_key);
    const then_value = try getValueProperty(ctx, output, global, awaited, then_key, caller_function, caller_frame);
    defer then_value.free(ctx.runtime);
    if (!isCallableValue(then_value)) return null;

    const promise = try core.promise.constructWithPrototype(ctx, promisePrototypeFromGlobal(ctx.runtime, global));
    defer promise.free(ctx.runtime);
    const promise_object = objectFromValue(promise) orelse return error.TypeError;
    const resolving = try createPromiseResolvingPair(ctx.runtime, global, promise);
    const resolve = resolving.resolve;
    defer resolve.free(ctx.runtime);
    const reject = resolving.reject;
    defer reject.free(ctx.runtime);

    const then_result = callValueOrBytecode(ctx, output, global, awaited, then_value, &.{ resolve, reject }, caller_function, caller_frame) catch |err| {
        var reason = try promiseRejectionReason(ctx, global, err);
        defer reason.deinit(ctx.runtime);
        try promise_object.setPromiseResult(ctx.runtime, reason.value);
        reason.value = core.JSValue.undefinedValue();
        promise_object.promiseIsRejectedSlot().* = true;
        reason.commit(ctx);
        return try finishAwaitedPromise(ctx, promise_object);
    };
    then_result.free(ctx.runtime);

    // resolve(anotherThenable) inside `then` enqueues a nested thenable job
    // (js_promise_resolve_function_call -> JS_EnqueueJob). This helper serves
    // the drain-model await paths (async generators / module TLA), which
    // synchronously run the pending queue until the awaited promise settles.
    if (promise_object.promiseResultSlot().* == null and ctx.runtime.job_queue.jobs.len != 0) {
        try drainPendingPromiseJobs(ctx, output, global);
    }
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
    // OrdinarySetWithOwnDescriptor probes Receiver.[[GetOwnProperty]] before
    // attempting to define on it. For a namespace Receiver that operation
    // reads the live export and must propagate ReferenceError while it is TDZ.
    // Only a successful/absent descriptor reaches the namespace write
    // rejection and becomes TypeError.
    if (try receiver_object.getOwnProperty(ctx.runtime, atom_id)) |desc| {
        desc.destroy(ctx.runtime);
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
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    const global = try core.Object.create(rt, core.class.ids.global_object, null);
    _ = try global.ensureGlobalPayload(rt);
    ctx.global = global;

    promise_jobs = 0;
    try core.promise.enqueueReaction(ctx, countPromiseJob, &.{core.JSValue.int32(2)});

    try drainPendingPromiseJobs(ctx, null, global);

    try std.testing.expectEqual(@as(usize, 3), promise_jobs);
}

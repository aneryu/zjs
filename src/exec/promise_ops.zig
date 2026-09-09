//! Promise jobs, capabilities, reactions, combinators, and async-function glue.
//!
//! Atomics waiters live with the rest of Atomics in `atomics_ops.zig`; sync and
//! async explicit-resource-management algorithms live in `disposable_ops.zig`.
//! Compatibility aliases below preserve the historical `promise_ops` names
//! without moving their implementations back into this module.
//! Call inputs are borrowed, returned values are owned, and values retained by
//! promise/job payloads must be duplicated. Keep the measured
//! `ctx`/`output`/`global`/caller-function/caller-frame ABI explicit, and never
//! share benchmark-hot arms with cold paths. Promise behavior follows
//! quickjs.c:53415-54663.

const std = @import("std");
const builtin = @import("builtin");
const function_ops = @import("function_ops.zig");
const atomics_ops = @import("atomics_ops.zig");
const bytecode = @import("../bytecode.zig");
const core = @import("../core/root.zig");
const builtin_dispatch = @import("builtin_dispatch.zig");
const jobs_mod = core.jobs;
const call_mod = @import("call.zig");
const frame_mod = @import("frame.zig");
const property_ops = @import("property_ops.zig");
const zjs_vm = @import("zjs_vm.zig");
const vm_call = @import("vm_call.zig");
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
const promiseAggregateError = exception_ops.promiseAggregateError;
const promiseErrorValue = exception_ops.promiseErrorValue;
const runWithCallEnvAfterInterruptPoll = zjs_vm.runWithCallEnvAfterInterruptPoll;
const exceptions = @import("exceptions.zig");
const exception_ops = @import("exception_ops.zig");

const call_runtime = @import("call_runtime.zig");
const array_ops = @import("array_ops.zig");
const builtin_glue = @import("builtin_glue.zig");
const coercion_ops = @import("coercion_ops.zig");
const disposable_ops = @import("disposable_ops.zig");
const forof_ops = @import("forof_ops.zig");
const object_ops = @import("object_ops.zig");
const iterator_ops = @import("iterator_ops.zig");
const cachedRealmObject = object_ops.cachedRealmObject;
const callValueOrBytecodeRoot = call_runtime.callValueOrBytecodeRoot;
const closeIteratorForAbruptCompletion = forof_ops.closeIteratorForAbruptCompletion;
const closeIteratorFromVmImpl = forof_ops.closeIteratorFromVmImpl;
const constructDynamicFunctionFromSource = function_ops.constructDynamicFunctionFromSource;
const constructValueOrBytecode = call_runtime.constructValueOrBytecode;
const constructorPrototypeObject = object_ops.constructorPrototypeObject;
const createGeneratorObject = object_ops.createGeneratorObject;
const createIteratorResult = iterator_ops.createIteratorResult;
const defineValueProperty = object_ops.defineValueProperty;
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
const processExpiredAtomicsWaiters = atomics_ops.processExpiredAtomicsWaiters;
const proxyAwareOwnPropertyDescriptor = object_ops.proxyAwareOwnPropertyDescriptor;
const proxyTrapKeyValue = object_ops.proxyTrapKeyValue;
const defineToStringTag = iterator_ops.defineToStringTag;
const runNextAtomicsHostCompletion = atomics_ops.runNextAtomicsHostCompletion;
const runNextOsRwHandler = call_runtime.runNextOsRwHandler;
const runNextOsTimer = call_runtime.runNextOsTimer;
const setGeneratorResumeCompletionType = call_runtime.setGeneratorResumeCompletionType;
const storeRealmValue = builtin_glue.storeRealmValue;
const throwTypeErrorMessage = exception_ops.throwTypeErrorMessage;
const valueTruthy = coercion_ops.valueTruthy;

// Historical namespace compatibility for the two domains extracted by Q18.
pub const usingCreateAsyncDisposableStack = disposable_ops.usingCreateAsyncDisposableStack;
pub const usingAddAsyncResource = disposable_ops.usingAddAsyncResource;
pub const usingDisposeAsyncStack = disposable_ops.usingDisposeAsyncStack;
pub const usingDisposeAsyncStackForThrow = disposable_ops.usingDisposeAsyncStackForThrow;
pub const AsyncDisposableStackMethod = disposable_ops.AsyncDisposableStackMethod;
pub const asyncDisposableStackMethodFromMarker = disposable_ops.asyncDisposableStackMethodFromMarker;
pub const asyncDisposableStackConstructWithPrototype = disposable_ops.asyncDisposableStackConstructWithPrototype;
pub const asyncDisposableStackReceiver = disposable_ops.asyncDisposableStackReceiver;
pub const asyncDisposableStackMethodCall = disposable_ops.asyncDisposableStackMethodCall;
pub const asyncDisposableStackUse = disposable_ops.asyncDisposableStackUse;
pub const asyncDisposableStackAdopt = disposable_ops.asyncDisposableStackAdopt;
pub const asyncDisposableStackDefer = disposable_ops.asyncDisposableStackDefer;
pub const asyncDisposableStackMove = disposable_ops.asyncDisposableStackMove;
pub const asyncDisposableStackStoreCapability = disposable_ops.asyncDisposableStackStoreCapability;
pub const asyncDisposableStackDisposeAsync = disposable_ops.asyncDisposableStackDisposeAsync;
pub const asyncDisposableStackContinuation = disposable_ops.asyncDisposableStackContinuation;
pub const asyncDisposableStackContinuationCall = disposable_ops.asyncDisposableStackContinuationCall;
pub const asyncDisposableStackContinueOrReject = disposable_ops.asyncDisposableStackContinueOrReject;
pub const asyncDisposableStackContinue = disposable_ops.asyncDisposableStackContinue;
pub const asyncDisposeResource = disposable_ops.asyncDisposeResource;
pub const asyncDisposableStackAwaitValue = disposable_ops.asyncDisposableStackAwaitValue;
pub const asyncDisposableStackRecordError = disposable_ops.asyncDisposableStackRecordError;
pub const asyncDisposableStackResolveStored = disposable_ops.asyncDisposableStackResolveStored;
pub const asyncDisposableStackRejectStored = disposable_ops.asyncDisposableStackRejectStored;
pub const asyncIteratorAsyncDispose = disposable_ops.asyncIteratorAsyncDispose;
pub const atomicsDestroyAsyncWaiter = atomics_ops.atomicsDestroyAsyncWaiter;
pub const atomicsDestroyAsyncWaiterOpaque = atomics_ops.atomicsDestroyAsyncWaiterOpaque;
pub const atomicsRunAsyncWaiterCompletion = atomics_ops.atomicsRunAsyncWaiterCompletion;
pub const atomicsWaitAsync = atomics_ops.atomicsWaitAsync;
pub const atomicsLinkAsyncWaiter = atomics_ops.atomicsLinkAsyncWaiter;
pub const atomicsWaitAsyncResult = atomics_ops.atomicsWaitAsyncResult;
pub const atomicsWaitAsyncPromise = atomics_ops.atomicsWaitAsyncPromise;

pub fn promisePrototypeFromGlobal(rt: *core.JSRuntime, global: *core.Object) ?*core.Object {
    if (global.cachedPromiseProto(rt)) |prototype| return prototype;
    const promise_atom = core.atom.ids.Promise;
    const promise_constructor = global.getOwnDataObjectBorrowed(promise_atom) orelse return null;
    return promise_constructor.getOwnDataObjectBorrowed(core.atom.ids.prototype);
}

pub fn asyncFunctionPrototypeFromGlobal(rt: *core.JSRuntime, global: *core.Object) !?*core.Object {
    if (cachedRealmObject(rt, global, .async_function_prototype)) |stored| return stored;

    const prototype = try core.Object.create(rt, core.class.ids.object, functionPrototypeFromGlobal(rt, global));
    const prototype_value = prototype.value();
    const constructor = try core.function.nativeFunctionForGlobal(rt, global, "AsyncFunction", 1);
    const constructor_object = property_ops.expectObject(constructor) catch return error.TypeError;
    try constructor_object.setFunctionRealmGlobalPtr(rt, global);
    if (functionConstructorFromGlobal(rt, global)) |function_constructor| try constructor_object.setPrototype(rt, function_constructor);
    try constructor_object.defineOwnProperty(rt, core.atom.ids.prototype, core.Descriptor.data(prototype_value, false, false, false));
    try prototype.defineOwnProperty(rt, core.atom.ids.constructor, core.Descriptor.data(constructor_object.value(), false, false, true));
    try defineToStringTag(rt, prototype, "AsyncFunction");

    const constructor_value = constructor_object.value();
    try storeRealmValue(rt, global, .async_function_constructor, constructor_value);
    try storeRealmValue(rt, global, .async_function_prototype, prototype_value);
    return prototype;
}

pub fn asyncIteratorPrototypeFromGlobal(rt: *core.JSRuntime, global: *core.Object) !*core.Object {
    if (cachedRealmObject(rt, global, .async_iterator_prototype)) |stored| return stored;
    const object = try core.Object.create(rt, core.class.ids.object, objectPrototypeFromGlobal(rt, global));
    var object_raw_owned = true;
    errdefer if (object_raw_owned) core.Object.destroyFromHeader(rt, object.gcHeader());
    const method = try core.function.nativeFunctionForGlobal(rt, global, "[Symbol.asyncIterator]", 0);
    const async_iterator_atom = core.atom.predefinedId("Symbol.asyncIterator", .symbol) orelse return error.TypeError;
    try object.defineOwnProperty(rt, async_iterator_atom, core.Descriptor.data(method, true, false, true));
    if (core.atom.predefinedId("Symbol.asyncDispose", .symbol)) |async_dispose_atom| {
        const dispose = try core.function.nativeFunctionForGlobal(rt, global, "[Symbol.asyncDispose]", 0);
        const dispose_object = objectFromValue(dispose) orelse return error.TypeError;
        if (!try dispose_object.addAsyncIteratorAsyncDisposeFunction(rt)) return error.TypeError;
        try object.defineOwnProperty(rt, async_dispose_atom, core.Descriptor.data(dispose, true, false, true));
    }
    const value = object.value();
    object_raw_owned = false;
    try storeRealmValue(rt, global, .async_iterator_prototype, value);
    return object;
}

pub fn asyncGeneratorPrototypeFromGlobal(rt: *core.JSRuntime, global: *core.Object) !*core.Object {
    if (cachedRealmObject(rt, global, .async_generator_prototype)) |stored| return stored;
    const async_iterator_prototype = try asyncIteratorPrototypeFromGlobal(rt, global);
    const object = try core.Object.create(rt, core.class.ids.object, async_iterator_prototype);
    var object_raw_owned = true;
    errdefer if (object_raw_owned) core.Object.destroyFromHeader(rt, object.gcHeader());
    try installAsyncGeneratorPrototypeProperties(rt, global, object);
    const value = object.value();
    object_raw_owned = false;
    try storeRealmValue(rt, global, .async_generator_prototype, value);
    return object;
}

pub fn installAsyncGeneratorPrototypeProperties(rt: *core.JSRuntime, global: *core.Object, object: *core.Object) !void {
    try defineAsyncGeneratorDataMethod(rt, global, object, core.atom.ids.next, 1);
    try defineAsyncGeneratorDataMethod(rt, global, object, core.atom.ids.return_, 1);
    try defineAsyncGeneratorDataMethod(rt, global, object, core.atom.ids.throw, 1);

    const tag_atom = core.atom.predefinedId("Symbol.toStringTag", .symbol) orelse return error.TypeError;
    const tag = try value_ops.createStringValue(rt, "AsyncGenerator");
    try object.defineOwnProperty(rt, tag_atom, core.Descriptor.data(tag, false, false, true));
}

pub fn defineAsyncGeneratorDataMethod(rt: *core.JSRuntime, global: *core.Object, object: *core.Object, atom_id: core.Atom, length: i32) !void {
    const method = try core.function.nativeFunctionForGlobal(rt, global, core.atom.predefinedName(atom_id), length);
    const method_object = property_ops.expectObject(method) catch return error.TypeError;
    if (!try method_object.addAsyncGeneratorPrototypeMethod(rt)) return error.TypeError;
    try object.defineOwnProperty(rt, atom_id, core.Descriptor.data(method, true, false, true));
}

pub fn asyncGeneratorFunctionPrototypeFromGlobal(rt: *core.JSRuntime, global: *core.Object) !?*core.Object {
    if (cachedRealmObject(rt, global, .async_generator_function_prototype)) |stored| return stored;
    const object = try core.Object.create(rt, core.class.ids.object, functionPrototypeFromGlobal(rt, global));
    const object_value = object.value();
    const constructor = try core.function.nativeFunctionForGlobal(rt, global, "AsyncGeneratorFunction", 1);
    const constructor_object = property_ops.expectObject(constructor) catch return error.TypeError;
    try constructor_object.setFunctionRealmGlobalPtr(rt, global);
    if (functionConstructorFromGlobal(rt, global)) |function_constructor| try constructor_object.setPrototype(rt, function_constructor);
    try constructor_object.defineOwnProperty(rt, core.atom.ids.prototype, core.Descriptor.data(object_value, false, false, false));
    try object.defineOwnProperty(rt, core.atom.ids.constructor, core.Descriptor.data(constructor_object.value(), false, false, true));
    try storeRealmValue(rt, global, .async_generator_function_constructor, constructor_object.value());
    const async_generator_prototype = try asyncGeneratorPrototypeFromGlobal(rt, global);
    try object.defineOwnProperty(rt, core.atom.ids.prototype, core.Descriptor.data(async_generator_prototype.value(), false, false, true));
    try async_generator_prototype.defineOwnProperty(rt, core.atom.ids.constructor, core.Descriptor.data(object_value, false, false, true));
    try defineToStringTag(rt, object, "AsyncGeneratorFunction");
    try storeRealmValue(rt, global, .async_generator_function_prototype, object_value);
    return object;
}

pub fn defaultPromiseCapability(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !PromiseCapabilityVm {
    const promise_constructor = try promiseDefaultConstructor(ctx, global);
    return promiseCapability(ctx, output, global, promise_constructor, caller_function, caller_frame);
}

pub fn promiseResolveCapability(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    resolve_value: core.JSValue,
    value: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !void {
    _ = try callValueOrBytecodeRoot(ctx, output, global, core.JSValue.undefinedValue(), resolve_value, &.{value}, caller_function, caller_frame);
}

pub fn promiseConstruct(
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
    return promiseConstructWithPrototype(ctx, output, global, prototype, args, caller_function, caller_frame);
}

pub fn promiseConstructWithPrototype(
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

    const resolving = try createPromiseResolvingPair(ctx.runtime, global, promise);
    const resolve = resolving.resolve;
    const reject = resolving.reject;
    _ = call_runtime.callValueOrBytecodeSyncInternalOutlined(ctx, output, global, core.JSValue.undefinedValue(), executor, &.{ resolve, reject }, caller_function, caller_frame) catch |err| {
        _ = objectFromValue(promise) orelse return err;
        var reason = try promiseRejectionReason(ctx, global, err);
        defer reason.deinit(ctx.runtime);
        // Abrupt executor completion must invoke the REJECT resolving function
        // (qjs js_promise_constructor: JS_Call(resolving_funcs[1], ...)), which
        // honors the [[AlreadyResolved]] once-guard, instead of settling the
        // promise directly (which would override a prior resolve()).
        _ = try callValueOrBytecodeRoot(ctx, output, global, core.JSValue.undefinedValue(), reject, &.{reason.value}, caller_function, caller_frame);
        reason.commit(ctx);
        return promise;
    };
    return promise;
}

pub const PromiseResolvingPairVm = struct {
    resolve: core.JSValue,
    reject: core.JSValue,
};

pub fn createPromiseResolvingState(rt: *core.JSRuntime) !*core.Object {
    var state_val = core.JSValue.undefinedValue();
    var root_frame = core.runtime.rootValues(.{&state_val});
    root_frame.activate(rt);
    defer root_frame.deactivate(rt);

    const state = try core.Object.create(rt, core.class.ids.object, null);
    state_val = state.value();
    (try state.promiseAlreadyResolvedSlot(rt)).* = false;
    return state;
}

pub fn createPromiseResolvingPair(rt: *core.JSRuntime, global: *core.Object, promise: core.JSValue) !PromiseResolvingPairVm {
    var state_val = core.JSValue.undefinedValue();
    var resolve_val = core.JSValue.undefinedValue();
    var reject_val = core.JSValue.undefinedValue();

    var root_frame = core.runtime.rootValues(.{ &state_val, &resolve_val, &reject_val });
    root_frame.activate(rt);
    defer root_frame.deactivate(rt);

    const state = try createPromiseResolvingState(rt);
    state_val = state.value();

    resolve_val = try createPromiseResolvingFunction(rt, global, promise, false, state);
    reject_val = try createPromiseResolvingFunction(rt, global, promise, true, state);

    return .{
        .resolve = resolve_val,
        .reject = reject_val,
    };
}

pub fn createPromiseResolvingFunction(rt: *core.JSRuntime, global: *core.Object, promise: core.JSValue, reject: bool, state: *core.Object) !core.JSValue {
    var rooted_promise = promise;
    var state_val = state.value();
    var function_val = core.JSValue.undefinedValue();
    var root_frame = core.runtime.rootValues(.{ &rooted_promise, &state_val, &function_val });
    root_frame.activate(rt);
    defer root_frame.deactivate(rt);

    const function_proto = functionPrototypeFromGlobal(rt, global) orelse return error.InvalidBuiltinRegistry;
    function_val = try core.function.nativeDataFunctionWithPrototype(rt, function_proto, "", 1);
    const object = objectFromValue(function_val) orelse return error.TypeError;
    try object.setInternalCallableTag(rt, .promise_resolving);
    try object.setFunctionPromiseResolvingTarget(rt, rooted_promise);
    try object.setFunctionPromiseResolvingState(rt, state_val);
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
    const marker_key = try rt.internAtom("marker");
    const state_symbol = try rt.atoms.newValueSymbol("gc-qjs-promise-resolving-state-symbol");
    {
        const state_marker_value = try rt.takeSymbolValue(state_symbol);
        try state.defineOwnProperty(rt, marker_key, core.Descriptor.data(state_marker_value, true, true, true));
    }

    const promise_symbol = try rt.atoms.newValueSymbol("gc-qjs-promise-resolving-target-symbol");
    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const promise_value = try rt.takeSymbolValue(promise_symbol);
    const function_value = try createPromiseResolvingFunction(rt, global, promise_value, true, state);
    const function_object = objectFromValue(function_value) orelse return error.TypeError;

    // Root only the FUNCTION for the quiescent whole-heap collections below:
    // the mid-phase assertions observe state/symbols surviving through the
    // function's own stored edges, which is the behavior under test. (The
    // paced threshold collections during creation scan engine-active and
    // cover the stack-held locals conservatively.)
    var function_slot: ?*core.Object = function_object;
    var live_roots = core.runtime.rootObjects(.{&function_slot});
    live_roots.activate(rt);
    var live_roots_active = true;
    defer if (live_roots_active) live_roots.deactivate(rt);

    try std.testing.expect(rt.atoms.name(promise_symbol) != null);
    try std.testing.expect(rt.atoms.name(state_symbol) != null);
    try std.testing.expectEqual(promise_symbol, function_object.functionPromiseResolvingTarget().?.asSymbolAtom().?);
    try std.testing.expect(function_object.functionPromiseResolvingReject());

    state_alive = false;
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(promise_symbol) != null);
    try std.testing.expect(rt.atoms.name(state_symbol) != null);
    const stored_state_value = function_object.functionPromiseResolvingState() orelse return error.TypeError;
    const stored_state = objectFromValue(stored_state_value) orelse return error.TypeError;
    {
        const marker_value = try stored_state.getProperty(marker_key);
        try std.testing.expectEqual(state_symbol, marker_value.asSymbolAtom().?);
    }

    live_roots.deactivate(rt);
    live_roots_active = false;
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(promise_symbol) == null);
    try std.testing.expect(rt.atoms.name(state_symbol) == null);
}

/// qjs `list_add_tail(&rd->link, &s->promise_reactions[is_reject])`
/// (quickjs.c:54221-54222) links the reaction record onto the pending promise
/// in O(1) with no allocation of its own. The array adaptation keeps a
/// capacity alongside the live prefix and grows by doubling, so subscribing N
/// handlers to one pending promise costs O(N) rather than the O(N^2) that an
/// exact-size realloc per subscription used to pay.
pub fn appendPromiseReaction(rt: *core.JSRuntime, promise: *core.Object, reaction: core.JSValue) !void {
    const slot = promise.promiseReactionsSlot();
    const capacity_slot = promise.promiseReactionsCapacitySlot();
    if (slot.*.len == capacity_slot.*) {
        const current = slot.*;
        const next_capacity = if (capacity_slot.* == 0) @as(usize, 4) else capacity_slot.* * 2;
        // TGC S4-c: the subscriber list is a subordinate `.payload` GC cell.
        // Mint adjacent to the install -- only the memcpy separates them --
        // and leave the SUPERSEDED cell to the sweep instead of freeing it.
        const next = try core.Object.createPayloadSliceCell(rt, core.JSValue, next_capacity);
        @memcpy(next[0..current.len], current);
        slot.* = next[0..current.len];
        capacity_slot.* = next_capacity;
        // A pending promise is usually the older of the two, and the cell was
        // published moments ago.
        rt.gc.rememberOwnerForBulkWrite(promise.gcHeader());
    }

    // Past the last fallible step: the append itself is a no-fail publish into
    // reserved storage, so the promise is never observed in a torn state.
    const len = slot.*.len;
    std.debug.assert(len < capacity_slot.*);
    slot.*.ptr[len] = reaction;
    slot.* = slot.*.ptr[0 .. len + 1];
    // The reaction list lives in the promise's payload, so the promise is the
    // owner. A pending promise is usually the older of the two -- it is what
    // the subscriber is attaching to.
    rt.gc.generationalBarrier(promise.gcHeader(), reaction.cycleMarkHeader());
}

pub fn promiseReactionRecord(
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
    var root_frame = core.runtime.rootValues(.{
        &rooted_on_fulfilled,
        &rooted_on_rejected,
        &rooted_resolve,
        &rooted_reject,
    });
    root_frame.activate(rt);
    defer root_frame.deactivate(rt);

    const record = try core.Object.createPromiseReactionRecord(rt);
    errdefer core.Object.destroyFromHeader(rt, record.gcHeader());
    try record.setPromiseReactionOnFulfilled(rt, rooted_on_fulfilled);
    try record.setPromiseReactionOnRejected(rt, rooted_on_rejected);
    try record.setPromiseReactionResolve(rt, rooted_resolve);
    try record.setPromiseReactionReject(rt, rooted_reject);
    return record.value();
}

test "promiseReactionRecord roots direct symbol fields while allocating slots" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const on_fulfilled_symbol = try rt.atoms.newValueSymbol("gc-reaction-on-fulfilled-symbol");
    const on_rejected_symbol = try rt.atoms.newValueSymbol("gc-reaction-on-rejected-symbol");
    const resolve_symbol = try rt.atoms.newValueSymbol("gc-reaction-resolve-symbol");
    const reject_symbol = try rt.atoms.newValueSymbol("gc-reaction-reject-symbol");
    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const on_fulfilled_value = try rt.takeSymbolValue(on_fulfilled_symbol);
    const on_rejected_value = try rt.takeSymbolValue(on_rejected_symbol);
    const resolve_value = try rt.takeSymbolValue(resolve_symbol);
    const reject_value = try rt.takeSymbolValue(reject_symbol);
    const record_value = try promiseReactionRecord(rt, on_fulfilled_value, on_rejected_value, resolve_value, reject_value);
    const record = objectFromValue(record_value) orelse return error.TypeError;

    try std.testing.expect(rt.atoms.name(on_fulfilled_symbol) != null);
    try std.testing.expect(rt.atoms.name(on_rejected_symbol) != null);
    try std.testing.expect(rt.atoms.name(resolve_symbol) != null);
    try std.testing.expect(rt.atoms.name(reject_symbol) != null);
    try std.testing.expectEqual(on_fulfilled_symbol, record.promiseReactionOnFulfilled().?.asSymbolAtom().?);
    try std.testing.expectEqual(on_rejected_symbol, record.promiseReactionOnRejected().?.asSymbolAtom().?);
    try std.testing.expectEqual(resolve_symbol, record.promiseReactionResolve().?.asSymbolAtom().?);
    try std.testing.expectEqual(reject_symbol, record.promiseReactionReject().?.asSymbolAtom().?);

    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(on_fulfilled_symbol) == null);
    try std.testing.expect(rt.atoms.name(on_rejected_symbol) == null);
    try std.testing.expect(rt.atoms.name(resolve_symbol) == null);
    try std.testing.expect(rt.atoms.name(reject_symbol) == null);
}

pub fn promiseReactionJob(
    ctx: *core.JSContext,
    reaction: *core.Object,
    value: core.JSValue,
    rejected: bool,
) !jobs_mod.Job {
    return jobs_mod.Job.initPromiseReaction(ctx, reaction.value(), value, rejected);
}

test "promiseReactionJob roots reaction and value while allocating job" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    const global = try core.Object.create(rt, core.class.ids.global_object, null);
    _ = try global.ensureGlobalPayload(rt);
    ctx.global = global;

    const reaction = try core.Object.create(rt, core.class.ids.object, null);
    const marker_key = try rt.internAtom("marker");
    const reaction_symbol = try rt.atoms.newValueSymbol("gc-qjs-promise-reaction-record-symbol");
    {
        const reaction_marker_value = try rt.takeSymbolValue(reaction_symbol);
        try reaction.defineOwnProperty(rt, marker_key, core.Descriptor.data(reaction_marker_value, true, true, true));
    }

    const value_symbol = try rt.atoms.newValueSymbol("gc-qjs-promise-reaction-value-symbol");
    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const reaction_payload = try rt.takeSymbolValue(value_symbol);
    var job = try promiseReactionJob(ctx, reaction, reaction_payload, true);
    var job_alive = true;
    defer if (job_alive) job.deinit();

    // The holder under test is the native Job struct; its JSValue refs are
    // invisible to a declared-roots tracing sweep, so name the job's slots
    // directly. Deactivated before the death phase.
    var job_roots_storage = [_]core.runtime.ValueRootValue{
        .{ .value = &job.payload.promise_reaction.reaction },
        .{ .value = &job.payload.promise_reaction.value },
    };
    var job_roots = core.runtime.ValueRootFrame{ .values = &job_roots_storage };
    job_roots.activate(rt);
    var job_roots_active = true;
    defer if (job_roots_active) job_roots.deactivate(rt);

    try std.testing.expect(rt.atoms.name(reaction_symbol) != null);
    try std.testing.expect(rt.atoms.name(value_symbol) != null);
    try std.testing.expectEqual(value_symbol, job.payload.promise_reaction.value.asSymbolAtom().?);
    try std.testing.expect(job.payload.promise_reaction.rejected);

    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(reaction_symbol) != null);
    try std.testing.expect(rt.atoms.name(value_symbol) != null);
    const stored_reaction_value = job.payload.promise_reaction.reaction;
    const stored_reaction = objectFromValue(stored_reaction_value) orelse return error.TypeError;
    {
        const marker_value = try stored_reaction.getProperty(marker_key);
        try std.testing.expectEqual(reaction_symbol, marker_value.asSymbolAtom().?);
    }

    job_roots.deactivate(rt);
    job_roots_active = false;
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
        if (self.initialized == 0) {
            std.debug.assert(self.reserved_entries == 0);
            self.* = .{};
            return;
        }
        std.debug.assert(self.reserved_entries == self.initialized);

        const capacity_slot = promise.promiseReactionsCapacitySlot();
        promise.promiseReactionsSlot().* = &.{};
        capacity_slot.* = 0;
        // TGC S4-c: the drained subscriber list is a `.payload` cell -- the
        // sweep returns it; dropping the pointer is the whole release.

        for (self.jobs[0..self.initialized]) |job| {
            ctx.runtime.job_queue.enqueueReserved(job);
            self.reserved_entries -= 1;
        }

        ctx.runtime.memory.free(jobs_mod.Job, self.jobs);
        self.* = .{};
    }
};

test "prepared promise reaction jobs expose direct symbol payloads to an explicit root frame" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    const reaction = try core.Object.create(rt, core.class.ids.object, null);

    const jobs = try rt.memory.alloc(jobs_mod.Job, 2);
    const first_atom = try rt.atoms.newValueSymbol("gc-prepared-promise-job-root-first");
    const first = try rt.takeSymbolValue(first_atom);
    jobs[0] = jobs_mod.Job.initPromiseReaction(ctx, reaction.value(), first, false);
    const second_atom = try rt.atoms.newValueSymbol("gc-prepared-promise-job-root-second");
    const second = try rt.takeSymbolValue(second_atom);
    jobs[1] = jobs_mod.Job.initPromiseReaction(ctx, reaction.value(), second, false);
    var prepared = PreparedPromiseReactionJobs{
        .jobs = jobs,
        .initialized = 2,
    };
    defer prepared.deinit(rt);

    var root_storage = [_]core.runtime.ValueRootValue{
        .{ .value = &prepared.jobs[0].payload.promise_reaction.reaction },
        .{ .value = &prepared.jobs[0].payload.promise_reaction.value },
        .{ .value = &prepared.jobs[1].payload.promise_reaction.reaction },
        .{ .value = &prepared.jobs[1].payload.promise_reaction.value },
    };
    var roots = core.runtime.ValueRootFrame{ .values = &root_storage };
    roots.activate(rt);
    var roots_active = true;
    defer if (roots_active) roots.deactivate(rt);

    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(first_atom) != null);
    try std.testing.expect(rt.atoms.name(second_atom) != null);

    roots.deactivate(rt);
    roots_active = false;
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(first_atom) == null);
    try std.testing.expect(rt.atoms.name(second_atom) == null);
}

pub fn preparePromiseReactionJobs(
    ctx: *core.JSContext,
    promise: *core.Object,
    value: core.JSValue,
    rejected: bool,
) !PreparedPromiseReactionJobs {
    const reactions = promise.promiseReactions();
    if (reactions.len == 0) return .{};
    var rooted_value = value;
    var root_frame = core.runtime.rootValues(.{&rooted_value});
    root_frame.activate(ctx.runtime);
    defer root_frame.deactivate(ctx.runtime);

    const jobs = try ctx.runtime.memory.alloc(jobs_mod.Job, reactions.len);
    var prepared = PreparedPromiseReactionJobs{ .jobs = jobs };
    errdefer prepared.deinit(ctx.runtime);

    for (reactions) |reaction_value| {
        const reaction = objectFromValue(reaction_value) orelse return error.TypeError;
        prepared.jobs[prepared.initialized] = try promiseReactionJob(ctx, reaction, rooted_value, rejected);
        prepared.initialized += 1;
    }

    try ctx.runtime.job_queue.reserveEntries(prepared.initialized);
    prepared.reserved_entries = prepared.initialized;
    return prepared;
}

pub fn promiseSettleValue(
    ctx: *core.JSContext,
    global: *core.Object,
    promise: *core.Object,
    value: core.JSValue,
    rejected: bool,
) HostError!void {
    const had_reactions = promise.promiseReactions().len != 0;
    const needs_callback_job = promise.promiseReactionCallback() != null and promise.promiseReactionArg() == null;
    _ = global;
    var prepared_reactions = try preparePromiseReactionJobs(ctx, promise, value, rejected);
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
        prepared_callback_job = jobs_mod.Job.initPromise(ctx, promise.value());
    }

    const next_result = value;
    const result_slot = promise.promiseResultSlot();

    var next_reaction_arg: ?core.JSValue = null;
    const reaction_arg_slot = promise.promiseReactionArgSlot();
    if (needs_callback_job) {
        next_reaction_arg = value;
    }

    result_slot.* = next_result;
    // Settling writes straight into the payload rather than through
    // `Object.setPromiseResult`, so it takes the barrier itself: a promise
    // that has been pending for a while is old, and the value it settles with
    // was just produced.
    ctx.runtime.gc.generationalBarrier(promise.gcHeader(), next_result.cycleMarkHeader());
    promise.promiseIsRejectedSlot().* = rejected;
    if (next_reaction_arg) |reaction_arg| {
        reaction_arg_slot.* = reaction_arg;
        ctx.runtime.gc.generationalBarrier(promise.gcHeader(), reaction_arg.cycleMarkHeader());
        next_reaction_arg = null;
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

test "promiseSettleValue handles result self-assignment" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const global = try core.Object.create(rt, core.class.ids.global_object, null);
    _ = try global.ensureGlobalPayload(rt);
    ctx.global = global;
    const promise = try core.Object.create(rt, core.class.ids.promise, null);
    const result = try core.Object.create(rt, core.class.ids.object, null);

    try promise.setPromiseResult(rt, result.value());

    const current = promise.promiseResult().?;
    try promiseSettleValue(ctx, global, promise, current, false);

    try std.testing.expectEqual(result.gcHeader(), promise.promiseResult().?.refHeader().?);
}

test "promiseSettleValue roots direct symbol result while preparing reaction jobs" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    const ctx = try core.JSContext.create(rt);
    const global = try core.Object.create(rt, core.class.ids.global_object, null);
    _ = try global.ensureGlobalPayload(rt);
    ctx.global = global;
    const promise = try core.Object.create(rt, core.class.ids.promise, null);
    defer {
        ctx.destroy();
        rt.destroy();
    }

    const reaction = try promiseReactionRecord(rt, core.JSValue.undefinedValue(), core.JSValue.undefinedValue(), core.JSValue.undefinedValue(), core.JSValue.undefinedValue());
    try appendPromiseReaction(rt, promise, reaction);

    const symbol_atom = try rt.atoms.newValueSymbol("gc-promise-settle-result-symbol");
    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);
    const settle_value = try rt.takeSymbolValue(symbol_atom);
    try promiseSettleValue(ctx, global, promise, settle_value, false);

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

test "promiseSettleValue preserves pending state across reaction prepare and FIFO reserve OOM" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    const global = try core.Object.create(rt, core.class.ids.global_object, null);
    _ = try global.ensureGlobalPayload(rt);
    ctx.global = global;
    const promise = try core.Object.create(rt, core.class.ids.promise, null);

    const reaction = try promiseReactionRecord(
        rt,
        core.JSValue.undefinedValue(),
        core.JSValue.undefinedValue(),
        core.JSValue.undefinedValue(),
        core.JSValue.undefinedValue(),
    );
    try appendPromiseReaction(rt, promise, reaction);

    const baseline = rt.memory.allocated_bytes;
    const limits = [_]usize{
        baseline,
        baseline + @sizeOf(jobs_mod.Job),
    };
    for (limits) |limit| {
        rt.setMemoryLimit(limit);
        try std.testing.expectError(
            error.OutOfMemory,
            promiseSettleValue(ctx, global, promise, core.JSValue.int32(42), false),
        );
        rt.setMemoryLimit(null);
        try std.testing.expect(promise.promiseResult() == null);
        try std.testing.expectEqual(@as(usize, 1), promise.promiseReactions().len);
        try std.testing.expectEqual(@as(usize, 0), rt.job_queue.jobs.len);
        try std.testing.expectEqual(@as(usize, 0), rt.job_queue.reserved_entries);
        try std.testing.expectEqual(baseline, rt.memory.allocated_bytes);
    }

    try promiseSettleValue(ctx, global, promise, core.JSValue.int32(42), false);
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
    promiseSettleValue(ctx, global, target, completion, rejected) catch |err| {
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
    state: ?*core.Object,
    target: *core.Object,
    completion: core.JSValue,
    rejected: bool,
) HostError!void {
    if (!promiseSettlementMayAllocate(target)) {
        if (state) |shared| (try shared.promiseAlreadyResolvedSlot(ctx.runtime)).* = true;
        try promiseSettleValue(ctx, global, target, completion, rejected);
        return;
    }

    try ctx.runtime.job_queue.reserveEntries(1);
    var slot_reserved = true;
    defer if (slot_reserved) ctx.runtime.job_queue.releaseReservedEntries(1);
    if (state) |shared| (try shared.promiseAlreadyResolvedSlot(ctx.runtime)).* = true;
    try settlePromiseResolutionWithReservedOwner(ctx, global, target, completion, rejected, &slot_reserved);
}

pub fn promiseResolvingFunctionCall(
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
    return try resolvePromiseWithState(
        ctx,
        output,
        global,
        target,
        state,
        if (args.len >= 1) args[0] else core.JSValue.undefinedValue(),
        function_object.functionPromiseResolvingReject(),
        function_object,
        caller_function,
        caller_frame,
    );
}

/// Shared Promise resolution algorithm. Public resolving functions and async
/// completion use the same reserve-before-observation protocol. Public
/// resolving functions require a shared once owner; null is an internal
/// invocation whose fresh local state cannot be observed or called again.
/// A function origin is needed only for a public resolver's self-error realm.
fn resolvePromiseWithState(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    target: *core.Object,
    state: ?*core.Object,
    value: core.JSValue,
    reject: bool,
    resolving_function: ?*core.Object,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) HostError!core.JSValue {
    const target_value = target.value();
    if (target.promiseResult() != null) return core.JSValue.undefinedValue();
    if (state != null and state.?.promiseAlreadyResolved()) {
        // A prior call won the shared once-guard. Any allocation-sensitive
        // completion that could not settle synchronously is owned by the
        // Runtime FIFO, so later calls are true no-ops rather than an
        // out-of-order retry channel.
        return core.JSValue.undefinedValue();
    }

    if (!reject and value.sameValue(target_value)) {
        // qjs js_promise_resolve_function_call (quickjs.c:53608):
        // JS_ThrowTypeError(ctx, "promise self resolution").
        const error_global = if (resolving_function) |function_object|
            objectRealmGlobal(function_object) orelse global
        else
            global;
        const error_value = try exception_ops.createNamedError(ctx, error_global, "TypeError", "promise self resolution");
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
            const then_key = core.atom.ids.then;

            // Hold one FIFO slot before publishing the once-guard. After the
            // getter runs, a callable result can therefore be transferred to
            // a typed thenable job without any fallible work or lost owner.
            try ctx.runtime.job_queue.reserveEntries(1);
            var thenable_slot_reserved = true;
            defer if (thenable_slot_reserved) ctx.runtime.job_queue.releaseReservedEntries(1);

            if (state) |shared| (try shared.promiseAlreadyResolvedSlot(ctx.runtime)).* = true;
            const then_value = getValueProperty(ctx, output, global, value, then_key, caller_function, caller_frame) catch |err| {
                const reason = try promiseErrorValue(ctx, global, err);
                try settlePromiseResolutionWithReservedOwner(ctx, global, target, reason, true, &thenable_slot_reserved);
                return core.JSValue.undefinedValue();
            };
            if (isCallableValue(then_value)) {
                // Mirrors js_promise_resolve_function_call (quickjs.c:53626):
                // resolving with a callable-then object ALWAYS enqueues a
                // js_promise_resolve_thenable_job — never stored lazily, never
                // run synchronously; then is invoked exactly once, as a job.
                ctx.runtime.job_queue.enqueueReserved(jobs_mod.Job.initPromiseThenable(ctx, target_value, value, then_value));
                thenable_slot_reserved = false;
                return core.JSValue.undefinedValue();
            }

            try settlePromiseResolutionWithReservedOwner(ctx, global, target, value, false, &thenable_slot_reserved);
            return core.JSValue.undefinedValue();
        }
    }
    unreachable;
}

pub fn promiseThenableJob(
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

    fn thunk(ctx: *core.JSContext, this_value: core.JSValue, argv: [*]const core.JSValue, argc: u32, entry: *const core.NativeEntry, func_obj: ?*core.Object) callconv(.c) core.JSValue {
        _ = this_value;
        _ = argv;
        _ = argc;
        _ = func_obj;
        const self: *PromiseJobOomProbe = @ptrCast(@alignCast(entry.state.?));
        const result = self.call(ctx) catch |err| return builtin_dispatch.hostErrorToValue(ctx, ctx.global, err);
        return result;
    }

    fn call(self: *PromiseJobOomProbe, ctx: *core.JSContext) anyerror!core.JSValue {
        self.calls += 1;
        const rt = ctx.runtime;
        // TGC S4-b: sweep (with the conservative net, the caller's frames are
        // live) so the limit below is the LIVE size -- storage cells are
        // collected carriers now, so `checkAllocation`'s retry collection
        // would otherwise find real bytes to give back.
        _ = rt.tryRunObjectCycleRemovalWithValueRoots(null, .engine_active) catch {};
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
    const entry = try ctx.runtime.allocNativeEntry(.{
        .target = core.NativeEntry.code(&PromiseJobOomProbe.thunk),
        .kind = .managed,
        .state = @ptrCast(probe),
    });
    const function = try core.function.nativeFunction(ctx, name, 0);
    const object = objectFromValue(function) orelse return error.TypeError;
    object.installNativeEntry(entry);
    return function;
}

const PromiseBareCapabilityErrorProbe = struct {
    calls: usize = 0,

    fn thunk(ctx: *core.JSContext, this_value: core.JSValue, argv: [*]const core.JSValue, argc: u32, entry: *const core.NativeEntry, func_obj: ?*core.Object) callconv(.c) core.JSValue {
        _ = this_value;
        _ = argv;
        _ = argc;
        _ = func_obj;
        const self: *PromiseBareCapabilityErrorProbe = @ptrCast(@alignCast(entry.state.?));
        self.calls += 1;
        return builtin_dispatch.hostErrorToValue(ctx, ctx.global, error.TypeError);
    }
};

fn promiseBareCapabilityErrorFunction(
    ctx: *core.JSContext,
    probe: *PromiseBareCapabilityErrorProbe,
) !core.JSValue {
    const entry = try ctx.runtime.allocNativeEntry(.{
        .target = core.NativeEntry.code(&PromiseBareCapabilityErrorProbe.thunk),
        .kind = .managed,
        .state = @ptrCast(probe),
    });
    const function = try core.function.nativeFunction(ctx, "bareCapabilityError", 0);
    const object = objectFromValue(function) orelse return error.TypeError;
    object.installNativeEntry(entry);
    return function;
}

fn appendDummyPromiseReaction(rt: *core.JSRuntime, promise: *core.Object) !void {
    const reaction = try promiseReactionRecord(
        rt,
        core.JSValue.undefinedValue(),
        core.JSValue.undefinedValue(),
        core.JSValue.undefinedValue(),
        core.JSValue.undefinedValue(),
    );
    try appendPromiseReaction(rt, promise, reaction);
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

    // The host executor first exhausts the heap and then reports a bare
    // TypeError. Error construction therefore recursively OOMs after user
    // code has run; rejection must retain the preallocated abrupt value, not
    // silently substitute `undefined` or invoke the executor again.
    const promise = try promiseConstructWithPrototype(
        ctx,
        null,
        global,
        null,
        &.{executor},
        null,
        null,
    );
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
    try appendDummyPromiseReaction(rt, target);
    const resolving = try createPromiseResolvingPair(rt, global, target.value());
    const resolve_object = objectFromValue(resolving.resolve) orelse return error.TypeError;
    const reject_object = objectFromValue(resolving.reject) orelse return error.TypeError;

    // Isolate the post-once-guard failure: the durable continuation slot is
    // already available, while preparing the target's reaction batch cannot
    // allocate.
    try rt.job_queue.ensureCapacity(1);
    // TGC S4-b: see `PromiseJobOomProbe.call`.
    _ = rt.tryRunObjectCycleRemovalWithValueRoots(null, .engine_active) catch {};
    rt.setMemoryLimit(rt.memory.allocated_bytes);
    _ = (try promiseResolvingFunctionCall(
        ctx,
        null,
        global,
        resolve_object,
        &.{core.JSValue.int32(41)},
        null,
        null,
    )).?;
    try std.testing.expect(target.promiseResult() == null);
    try std.testing.expectEqual(@as(usize, 1), rt.job_queue.jobs.len);
    try std.testing.expectEqual(jobs_mod.Kind.promise_settlement, std.meta.activeTag(rt.job_queue.jobs[0].payload));

    // The paired reject cannot bypass the continuation's frozen FIFO
    // position; the once-guard makes it a no-op.
    _ = (try promiseResolvingFunctionCall(
        ctx,
        null,
        global,
        reject_object,
        &.{core.JSValue.int32(99)},
        null,
        null,
    )).?;
    try std.testing.expectEqual(@as(usize, 1), rt.job_queue.jobs.len);

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
    const reaction = try promiseReactionRecord(
        rt,
        core.JSValue.undefinedValue(),
        core.JSValue.undefinedValue(),
        resolve,
        core.JSValue.undefinedValue(),
    );
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
    _ = ctx.takeException();

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
    try appendDummyPromiseReaction(rt, target);

    const resolving = try createPromiseResolvingPair(rt, global, target.value());

    var probe = PromiseJobOomProbe{ .fail = false };
    const handler = try promiseJobOomProbeFunction(ctx, &probe, "reactionOomProbe");
    const reaction = try promiseReactionRecord(
        rt,
        handler,
        core.JSValue.undefinedValue(),
        resolving.resolve,
        resolving.reject,
    );
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
    try appendDummyPromiseReaction(rt, target);
    const resolving = try createPromiseResolvingPair(rt, global, target.value());
    const resolve_object = objectFromValue(resolving.resolve) orelse return error.TypeError;
    const state = objectFromValue(resolve_object.functionPromiseResolvingState().?) orelse return error.TypeError;

    const thenable = try core.Object.create(rt, core.class.ids.object, null);
    var probe = PromiseJobOomProbe{ .fail = false };
    const getter = try promiseJobOomProbeFunction(ctx, &probe, "thenGetterOomProbe");
    const then_key = try rt.internAtom("then");
    try thenable.defineOwnProperty(
        rt,
        then_key,
        core.Descriptor.accessor(getter, core.JSValue.undefinedValue(), true, true),
    );

    _ = (try promiseResolvingFunctionCall(ctx, null, global, resolve_object, &.{thenable.value()}, null, null)).?;
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expect(state.promiseAlreadyResolved());
    try std.testing.expect(target.promiseResult() == null);
    try std.testing.expectEqual(@as(usize, 1), rt.job_queue.jobs.len);
    try std.testing.expectEqual(jobs_mod.Kind.promise_settlement, std.meta.activeTag(rt.job_queue.jobs[0].payload));

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
    try appendDummyPromiseReaction(rt, target);
    const resolving = try createPromiseResolvingPair(rt, global, target.value());
    const resolve_object = objectFromValue(resolving.resolve) orelse return error.TypeError;

    const thenable = try core.Object.create(rt, core.class.ids.object, null);
    var probe = PromiseJobOomProbe{ .fail = true };
    const getter = try promiseJobOomProbeFunction(ctx, &probe, "thenGetterThrowOomProbe");
    const then_key = try rt.internAtom("then");
    try thenable.defineOwnProperty(
        rt,
        then_key,
        core.Descriptor.accessor(getter, core.JSValue.undefinedValue(), true, true),
    );

    _ = (try promiseResolvingFunctionCall(ctx, null, global, resolve_object, &.{thenable.value()}, null, null)).?;
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expect(target.promiseResult() == null);
    try std.testing.expectEqual(@as(usize, 1), rt.job_queue.jobs.len);
    try std.testing.expectEqual(jobs_mod.Kind.promise_settlement, std.meta.activeTag(rt.job_queue.jobs[0].payload));
    try std.testing.expect(rt.job_queue.jobs[0].payload.promise_settlement.rejected);

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
    try appendDummyPromiseReaction(rt, target);
    const thenable = try core.Object.create(rt, core.class.ids.object, null);

    var probe = PromiseJobOomProbe{ .fail = true };
    const then_function = try promiseJobOomProbeFunction(ctx, &probe, "thenableOomProbe");
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

test "promiseThenableJob roots direct function bytecode then callback while creating job" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const global = try core.Object.create(rt, core.class.ids.global_object, null);
    _ = try global.ensureGlobalPayload(rt);
    ctx.global = global;
    const target = try core.Object.create(rt, core.class.ids.promise, null);
    const thenable = try core.Object.create(rt, core.class.ids.object, null);

    const fb = try bytecode.FunctionBytecode.createFixture(rt, .{
        .flags = .{ .func_kind = .generator },
        .cpool_count = 1,
    });
    var fb_published = false;
    errdefer if (!fb_published) fb.destroyUnpublishedFixture(rt);
    const symbol_atom = try rt.atoms.newValueSymbol("gc-promise-thenable-job-bytecode-symbol");
    fb.cpoolSlice()[0] = try rt.takeSymbolValue(symbol_atom);
    fb.publishFixtureNoFail(rt);
    fb_published = true;

    const then_callback = core.JSValue.functionBytecode(&fb.header);

    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    var job = try promiseThenableJob(ctx, target.value(), thenable.value(), then_callback);
    var job_alive = true;
    defer if (job_alive) job.deinit();

    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    const stored = job.payload.promise_thenable.then_function;
    try std.testing.expect(stored.same(then_callback));

    job.deinit();
    job_alive = false;
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

pub fn promiseThenableJobCall(
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
            _ = callValueOrBytecodeRoot(
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
                const reason = try promiseErrorValue(ctx, global, err);
                payload.replaceCompletionOwned(ctx.runtime, reason);
                payload.phase = .reject;
                break :invoke;
            };
            return core.JSValue.undefinedValue();
        }
    }

    std.debug.assert(payload.phase == .reject);
    _ = try callValueOrBytecodeRoot(
        ctx,
        output,
        global,
        core.JSValue.undefinedValue(),
        payload.resolving_reject,
        &.{payload.completion},
        caller_function,
        caller_frame,
    );
    return core.JSValue.undefinedValue();
}

fn promiseSettlementJobCall(
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
    try promiseSettleValue(ctx, global, target, payload.completion, payload.rejected);
}

pub fn promiseReactionJobCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    payload: *jobs_mod.PromiseReactionPayload,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) HostError!core.JSValue {
    const reaction = objectFromValue(payload.reaction) orelse return error.TypeError;
    const intrinsic = reaction.promiseReactionIntrinsicCapability();
    const resolve_value = if (intrinsic == null) reaction.promiseReactionResolve() orelse return error.TypeError else core.JSValue.undefinedValue();
    const reject_value = if (intrinsic == null) reaction.promiseReactionReject() orelse return error.TypeError else core.JSValue.undefinedValue();

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

            const callback_result = callValueOrBytecodeRoot(
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
                const reason = try promiseErrorValue(ctx, global, err);
                payload.replaceValueOwned(ctx.runtime, reason);
                payload.phase = .reject;
                break :invoke;
            };
            if (payload.rejected) clearHandledRejectionException(ctx);
            payload.replaceValueOwned(ctx.runtime, callback_result);
            payload.phase = .resolve;
        }
    }

    if (intrinsic) |capability| {
        // The old resolver call polled before dispatch. Keep that observation
        // point, and preserve its construction realm for self-resolution errors.
        try exception_ops.pollInterrupt(ctx, global);
        const rejected = payload.phase == .reject;
        const target = objectFromValue(capability.target) orelse unreachable;
        const resolve_global = if (!rejected and payload.value.sameValue(capability.target))
            objectFromValue(capability.self_error_global) orelse unreachable
        else
            global;
        _ = try resolvePromiseWithState(ctx, output, resolve_global, target, null, payload.value, rejected, null, caller_function, caller_frame);
        reaction.clearPromiseReactionIntrinsicCapability();
        if (comptime builtin.is_test) ThenCapabilityTestStorage.metrics.intrinsic_settle += 1;
        return core.JSValue.undefinedValue();
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
    _ = callValueOrBytecodeRoot(
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
            const reason = try promiseErrorValue(ctx, global, err);
            _ = ctx.throwValue(reason);
        }
        return err;
    };
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
};

pub const ThenCapabilityTestMetrics = struct {
    intrinsic_prepare: usize = 0,
    intrinsic: usize = 0,
    fallback: usize = 0,
    intrinsic_settle: usize = 0,
    intrinsic_retry: usize = 0,
};
const ThenCapabilityTestStorage = if (builtin.is_test) struct {
    var metrics: ThenCapabilityTestMetrics = .{};
} else struct {};

pub fn resetThenCapabilityTestMetrics() void {
    if (comptime builtin.is_test) ThenCapabilityTestStorage.metrics = .{};
}

pub fn thenCapabilityTestMetrics() ThenCapabilityTestMetrics {
    return if (comptime builtin.is_test) ThenCapabilityTestStorage.metrics else .{};
}

const ThenCapability = struct {
    promise: core.JSValue,
    resolve: core.JSValue = core.JSValue.undefinedValue(),
    reject: core.JSValue = core.JSValue.undefinedValue(),
    intrinsic_global: core.JSValue = core.JSValue.undefinedValue(),
};

/// Called only after SpeciesConstructor, so its observable Gets are never
/// skipped or replayed. The cached intrinsic's own data prototype also avoids
/// consulting a replaced globalThis.Promise binding.
fn thenCapability(ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, constructor: core.JSValue, legacy_wait_async: bool, caller_function: ?*const bytecode.FunctionBytecode, caller_frame: ?*frame_mod.Frame) HostError!ThenCapability {
    if (!legacy_wait_async) {
        if (global.cachedRealmValue(ctx.runtime, .promise_constructor)) |intrinsic| {
            if (constructor.sameValue(intrinsic)) {
                const object = objectFromValue(intrinsic) orelse unreachable;
                if (object.getOwnDataObjectBorrowed(core.atom.ids.prototype)) |prototype| {
                    if (comptime builtin.is_test) ThenCapabilityTestStorage.metrics.intrinsic_prepare += 1;
                    const promise = try core.promise.constructWithPrototype(ctx, prototype);
                    if (comptime builtin.is_test) ThenCapabilityTestStorage.metrics.intrinsic += 1;
                    return .{ .promise = promise, .intrinsic_global = global.value() };
                }
            }
        }
    }
    const capability = try promiseCapability(ctx, output, global, constructor, caller_function, caller_frame);
    if (comptime builtin.is_test) ThenCapabilityTestStorage.metrics.fallback += 1;
    return .{ .promise = capability.promise, .resolve = capability.resolve, .reject = capability.reject };
}

/// The caller roots the capability for the entire subscription transaction.
/// Only handlers need additional roots while the private record is allocated.
fn thenReactionRecord(rt: *core.JSRuntime, capability: *const ThenCapability, on_fulfilled: core.JSValue, on_rejected: core.JSValue) HostError!core.JSValue {
    if (capability.intrinsic_global.isUndefined()) return promiseReactionRecord(rt, on_fulfilled, on_rejected, capability.resolve, capability.reject);
    var fulfilled = on_fulfilled;
    var rejected = on_rejected;
    var roots = core.runtime.rootValues(.{ &fulfilled, &rejected });
    roots.activate(rt);
    defer roots.deactivate(rt);
    const record = try core.Object.createPromiseReactionRecord(rt);
    errdefer core.Object.destroyFromHeader(rt, record.gcHeader());
    try record.setPromiseReactionOnFulfilled(rt, fulfilled);
    try record.setPromiseReactionOnRejected(rt, rejected);
    record.setPromiseReactionIntrinsicCapability(rt, capability.promise, capability.intrinsic_global);
    return record.value();
}

pub fn promiseCapabilityExecutorCall(ctx: *core.JSContext, function_object: *core.Object, args: []const core.JSValue) !?core.JSValue {
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
    try slot.setPromiseCapability(ctx.runtime, resolve, reject);
    return core.JSValue.undefinedValue();
}

pub fn promiseCombinatorElementCall(
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
        .all_resolve, .all_keyed_resolve => try promiseSetArrayIndex(ctx.runtime, values, index, payload),
        .all_settled_fulfill, .all_settled_reject, .all_settled_keyed_fulfill, .all_settled_keyed_reject => {
            const rejected = mode == .all_settled_reject or mode == .all_settled_keyed_reject;
            const record = try promiseSettlementRecord(ctx.runtime, rejected, payload);
            try promiseSetArrayIndex(ctx.runtime, values, index, record);
        },
        .any_reject => try promiseSetArrayIndex(ctx.runtime, values, index, payload),
    }

    const remaining = state.promiseCombinatorRemaining();
    const next_remaining = remaining - 1;
    (try state.promiseCombinatorRemainingSlot(ctx.runtime)).* = next_remaining;
    if (next_remaining != 0) return core.JSValue.undefinedValue();

    const resolve_value = state.promiseCombinatorResolve() orelse return error.TypeError;
    const reject_value = state.promiseCombinatorReject() orelse return error.TypeError;
    switch (mode) {
        .all_resolve, .all_settled_fulfill, .all_settled_reject => {
            _ = callValueOrBytecodeRoot(ctx, output, global, core.JSValue.undefinedValue(), resolve_value, &.{values_value}, caller_function, caller_frame) catch |err| {
                const reason = try promiseErrorValue(ctx, global, err);
                try promiseRejectCapability(ctx, output, global, reject_value, reason, caller_function, caller_frame);
                return core.JSValue.undefinedValue();
            };
        },
        .all_keyed_resolve, .all_settled_keyed_fulfill, .all_settled_keyed_reject => {
            const keys_value = state.promiseCombinatorKeys() orelse return error.TypeError;
            const keys = objectFromValue(keys_value) orelse return error.TypeError;
            const keyed_result = try promiseKeyedResult(ctx.runtime, keys, values);
            _ = callValueOrBytecodeRoot(ctx, output, global, core.JSValue.undefinedValue(), resolve_value, &.{keyed_result}, caller_function, caller_frame) catch |err| {
                const reason = try promiseErrorValue(ctx, global, err);
                try promiseRejectCapability(ctx, output, global, reject_value, reason, caller_function, caller_frame);
                return core.JSValue.undefinedValue();
            };
        },
        .any_reject => {
            const aggregate_error = try promiseAggregateError(ctx, global, values);
            _ = try callValueOrBytecodeRoot(ctx, output, global, core.JSValue.undefinedValue(), reject_value, &.{aggregate_error}, caller_function, caller_frame);
        },
    }
    return core.JSValue.undefinedValue();
}

pub fn promiseCapability(
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
    var root_frame = core.runtime.rootValues(.{
        &slot_value,
        &executor_value,
        &promise_value,
        &resolve_value,
        &reject_value,
    });
    root_frame.activate(ctx.runtime);
    defer root_frame.deactivate(ctx.runtime);

    const constructor_global = promiseConstructorRealmGlobal(constructor_value, global);
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

    executor_value = try builtin_glue.createDataFunction(ctx.runtime, constructor_global, "", 2);
    const executor_object = objectFromValue(executor_value) orelse return error.TypeError;
    try executor_object.setInternalCallableTag(ctx.runtime, .promise_capability_executor);
    try executor_object.setFunctionPromiseCapabilitySlot(ctx.runtime, slot_value);

    promise_value = try constructValueOrBytecode(ctx, output, global, constructor_value, &.{executor_value}, caller_function, caller_frame);

    resolve_value = if (slot.promiseCapabilityResolve()) |stored| stored else core.JSValue.undefinedValue();
    reject_value = if (slot.promiseCapabilityReject()) |stored| stored else core.JSValue.undefinedValue();
    if (!isCallableValue(resolve_value) or !isCallableValue(reject_value)) return error.TypeError;
    return .{
        .promise = promise_value,
        .resolve = resolve_value,
        .reject = reject_value,
    };
}

pub fn promiseSetArrayIndex(rt: *core.JSRuntime, array: *core.Object, index: u32, value: core.JSValue) !void {
    try property_ops.defineDataProperty(rt, array, core.atom.atomFromUInt32(index), value);
    if (array.arrayLength() <= index) array.setArrayLength(index + 1);
}

pub fn promiseKeyedResult(rt: *core.JSRuntime, keys: *core.Object, values: *core.Object) !core.JSValue {
    var keys_value = keys.value();
    var values_value = values.value();
    var result_value = core.JSValue.undefinedValue();
    var key_value = core.JSValue.undefinedValue();
    var value = core.JSValue.undefinedValue();
    var root_frame = core.runtime.rootValues(.{
        &keys_value,
        &values_value,
        &result_value,
        &key_value,
        &value,
    });
    root_frame.activate(rt);
    defer root_frame.deactivate(rt);

    const result = try core.Object.create(rt, core.class.ids.object, null);
    result_value = result.value();

    var index: u32 = 0;
    while (index < keys.arrayLength()) : (index += 1) {
        const index_atom = core.atom.atomFromUInt32(index);
        key_value = try keys.getProperty(index_atom);
        defer {
            key_value = core.JSValue.undefinedValue();
        }
        const key_atom = try property_ops.propertyKeyAtom(rt, key_value);
        value = try values.getProperty(index_atom);
        defer {
            value = core.JSValue.undefinedValue();
        }
        try property_ops.defineDataProperty(rt, result, key_atom, value);
    }
    return result_value;
}

test "promiseKeyedResult roots direct symbol values while defining keyed result" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const keys = try core.Object.createArray(rt, null);
    const values = try core.Object.createArray(rt, null);

    const key_name = try value_ops.createStringValue(rt, "answer");
    try promiseSetArrayIndex(rt, keys, 0, key_name);
    const value_symbol = try rt.atoms.newValueSymbol("gc-qjs-promise-keyed-result-symbol");
    {
        const keyed_value = try rt.takeSymbolValue(value_symbol);
        try promiseSetArrayIndex(rt, values, 0, keyed_value);
    }

    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const result_value = try promiseKeyedResult(rt, keys, values);
    const result = objectFromValue(result_value) orelse return error.TypeError;

    // Root the RESULT (the holder under test) for the quiescent collections;
    // the symbol's mid-phase survival must come via its stored property.
    var result_slot: ?*core.Object = result;
    var result_roots = core.runtime.rootObjects(.{&result_slot});
    result_roots.activate(rt);
    var result_roots_active = true;
    defer if (result_roots_active) result_roots.deactivate(rt);

    try std.testing.expect(rt.atoms.name(value_symbol) != null);
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(value_symbol) != null);
    const answer_atom = try rt.internAtom("answer");
    {
        const stored = try result.getProperty(answer_atom);
        try std.testing.expectEqual(value_symbol, stored.asSymbolAtom().?);
    }

    result_roots.deactivate(rt);
    result_roots_active = false;
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(value_symbol) == null);
}

pub fn promiseSettlementRecord(rt: *core.JSRuntime, rejected: bool, payload: core.JSValue) !core.JSValue {
    var rooted_payload = payload;
    var root_frame = core.runtime.rootValues(.{&rooted_payload});
    root_frame.activate(rt);
    defer root_frame.deactivate(rt);

    const record = try core.Object.create(rt, core.class.ids.object, null);
    errdefer core.Object.destroyFromHeader(rt, record.gcHeader());
    const status = try value_ops.createStringValue(rt, if (rejected) "rejected" else "fulfilled");
    try defineValueProperty(rt, record, core.atom.ids.status, status);
    try defineValueProperty(rt, record, if (rejected) core.atom.ids.reason else core.atom.ids.value, rooted_payload);
    return record.value();
}

test "promiseSettlementRecord roots direct symbol payload while defining status" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const symbol_atom = try rt.atoms.newValueSymbol("gc-promise-settlement-record-symbol");
    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const payload_value = try rt.takeSymbolValue(symbol_atom);
    const record_value = try promiseSettlementRecord(rt, false, payload_value);
    const record = objectFromValue(record_value) orelse return error.TypeError;

    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    const value_atom = try rt.internAtom("value");
    {
        const value = try record.getProperty(value_atom);
        try std.testing.expectEqual(symbol_atom, value.asSymbolAtom().?);
    }

    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

pub fn promiseCombinatorState(rt: *core.JSRuntime, resolve_value: core.JSValue, reject_value: core.JSValue, values: *core.Object) !*core.Object {
    var rooted_resolve = resolve_value;
    var rooted_reject = reject_value;
    var rooted_values = values.value();
    var root_frame = core.runtime.rootValues(.{ &rooted_resolve, &rooted_reject, &rooted_values });
    root_frame.activate(rt);
    defer root_frame.deactivate(rt);

    const state = try core.Object.create(rt, core.class.ids.object, null);
    errdefer core.Object.destroyFromHeader(rt, state.gcHeader());
    try state.setPromiseCombinatorResolve(rt, rooted_resolve);
    try state.setPromiseCombinatorReject(rt, rooted_reject);
    try state.setPromiseCombinatorValues(rt, rooted_values);
    (try state.promiseCombinatorRemainingSlot(rt)).* = 1;
    return state;
}

test "promiseCombinatorState roots direct function bytecode resolve while creating state" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const values = try core.Object.create(rt, core.class.ids.array, null);

    const fb = try bytecode.FunctionBytecode.createFixture(rt, .{ .cpool_count = 1 });
    var fb_published = false;
    errdefer if (!fb_published) fb.destroyUnpublishedFixture(rt);
    const symbol_atom = try rt.atoms.newValueSymbol("gc-qjs-promise-combinator-state-resolve-bytecode-symbol");
    fb.cpoolSlice()[0] = try rt.takeSymbolValue(symbol_atom);
    fb.publishFixtureNoFail(rt);
    fb_published = true;

    const resolve_value = core.JSValue.functionBytecode(&fb.header);

    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const state = try promiseCombinatorState(rt, resolve_value, core.JSValue.undefinedValue(), values);
    var state_alive = true;
    defer if (state_alive) core.Object.destroyFromHeader(rt, state.gcHeader());

    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    const stored = state.promiseCombinatorResolve() orelse return error.TypeError;
    try std.testing.expect(stored.same(resolve_value));

    // The zero threshold opened an incremental mark while constructing the
    // state. This test deliberately bypasses normal tracer ownership with a
    // direct destructor below, so first close that epoch and drain the entry
    // which may name `state`; freeing it while queued is exactly the O2-B
    // raw-pointer lifetime violation.
    rt.gc.abortIncrementalCycle();
    core.Object.destroyFromHeader(rt, state.gcHeader());
    state_alive = false;
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

pub fn promiseKeyedCombinatorState(rt: *core.JSRuntime, resolve_value: core.JSValue, reject_value: core.JSValue, values: *core.Object, keys: *core.Object) !*core.Object {
    const state = try promiseCombinatorState(rt, resolve_value, reject_value, values);
    errdefer core.Object.destroyFromHeader(rt, state.gcHeader());
    try state.setPromiseCombinatorKeys(rt, keys.value());
    return state;
}

pub fn promiseCombinatorCallback(
    rt: *core.JSRuntime,
    global: *core.Object,
    mode: PromiseCombinatorCallbackMode,
    state: *core.Object,
    index: u32,
) !core.JSValue {
    const callback = try builtin_glue.createDataFunction(rt, global, "", 1);
    const callback_object = objectFromValue(callback) orelse return error.TypeError;
    try callback_object.setInternalCallableTag(rt, .promise_combinator_element);
    (try callback_object.functionPromiseCombinatorModeSlot(rt)).* = @intFromEnum(mode);
    try callback_object.setFunctionPromiseCombinatorState(rt, state.value());
    (try callback_object.functionPromiseCombinatorIndexSlot(rt)).* = index;
    (try callback_object.functionPromiseCombinatorCalledSlot(rt)).* = false;
    return callback;
}

pub fn promiseRejectCapability(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    reject_value: core.JSValue,
    reason: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !void {
    _ = try callValueOrBytecodeRoot(ctx, output, global, core.JSValue.undefinedValue(), reject_value, &.{reason}, caller_function, caller_frame);
}

pub noinline fn promiseRejectCapabilityForError(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    reject_value: core.JSValue,
    err: anyerror,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !void {
    const reason = try promiseErrorValue(ctx, global, err);
    try promiseRejectCapability(ctx, output, global, reject_value, reason, caller_function, caller_frame);
}

/// Promise combinators turn most abrupt completions into a rejection of the
/// capability they have already created. Keep that fail-reject epilogue in
/// one cold body, matching QuickJS's `js_promise_all` `fail_reject` label,
/// instead of cloning error conversion, rejection, and callback release into
/// every observable operation in the combinator loop.
noinline fn rejectCombinatorAndRelease(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    capability: *const PromiseCapabilityVm,
    err: anyerror,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    try promiseRejectCapabilityForError(ctx, output, global, capability.reject, err, caller_function, caller_frame);
    return capability.promise;
}

pub fn promiseResolveIdentity(
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
        if (constructor.sameValue(constructor_value)) return value;
        return null;
    }
    const constructor = try getValueProperty(ctx, output, global, value, core.atom.ids.constructor, caller_function, caller_frame);
    if (constructor.sameValue(constructor_value)) return value;
    return null;
}

/// QuickJS's `JS_GetProperty(..., JS_ATOM_constructor)` reaches the Promise's
/// ordinary shape/prototype chain directly. Keep that authority for
/// missing/accessor/exotic shapes while letting the normal Promise.prototype
/// data hit take the same direct walk as qjs.
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

pub fn promiseDefaultConstructor(ctx: *core.JSContext, global: *core.Object) !core.JSValue {
    // qjs uses the cached intrinsic ctx->promise_ctor (js_async_function_resume
    // quickjs.c:21268, js_new_promise_capability quickjs.c:53745; set at
    // JS_AddIntrinsicPromise quickjs.c:54663) — never a globalThis.Promise
    // lookup, so deleting/replacing the global binding cannot break await or
    // the default species. The realm slot is populated at install time
    // (installPromiseExtras); the global read remains only as a fallback for
    // bare non-realm globals (unit-test contexts).
    if (global.cachedRealmValue(ctx.runtime, .promise_constructor)) |stored| return stored;
    const promise_key = core.atom.ids.Promise;
    return try global.getProperty(promise_key);
}

pub fn promiseSpeciesConstructor(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const default_constructor = try promiseDefaultConstructor(ctx, global);

    const constructor_value = try getValueProperty(ctx, output, global, receiver, core.atom.ids.constructor, caller_function, caller_frame);
    if (constructor_value.isUndefined()) return default_constructor;
    if (!constructor_value.isObject()) return error.TypeError;

    const species_atom = core.atom.predefinedId("Symbol.species", .symbol) orelse return error.TypeError;
    const species_value = try getValueProperty(ctx, output, global, constructor_value, species_atom, caller_function, caller_frame);
    if (species_value.isUndefined() or species_value.isNull()) return default_constructor;

    return species_value;
}

pub fn promiseConstructorRealmGlobal(constructor_value: core.JSValue, fallback_global: *core.Object) *core.Object {
    if (objectFromValue(constructor_value)) |constructor_object| {
        if (objectRealmGlobal(constructor_object)) |realm_global| return realm_global;
    }
    return fallback_global;
}

pub fn promiseCombinatorCall(
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
    const capability = try promiseCapability(ctx, output, global, constructor_value, caller_function, caller_frame);

    const resolve_key = core.atom.ids.resolve;
    const promise_resolve = getValueProperty(ctx, output, global, constructor_value, resolve_key, caller_function, caller_frame) catch |err| {
        return rejectCombinatorAndRelease(ctx, output, global, &capability, err, caller_function, caller_frame);
    };
    if (!isCallableValue(promise_resolve)) {
        return rejectCombinatorAndRelease(ctx, output, global, &capability, error.TypeError, caller_function, caller_frame);
    }

    const iterable = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const iterator_method = getIteratorMethod(ctx, output, global, iterable) catch |err| {
        return rejectCombinatorAndRelease(ctx, output, global, &capability, err, caller_function, caller_frame);
    };
    if (!isCallableValue(iterator_method)) {
        return rejectCombinatorAndRelease(ctx, output, global, &capability, error.TypeError, caller_function, caller_frame);
    }
    const iterator_value = callValueOrBytecodeRoot(ctx, output, global, iterable, iterator_method, &.{}, caller_function, caller_frame) catch |err| {
        return rejectCombinatorAndRelease(ctx, output, global, &capability, err, caller_function, caller_frame);
    };
    _ = property_ops.expectObject(iterator_value) catch |err| {
        return rejectCombinatorAndRelease(ctx, output, global, &capability, err, caller_function, caller_frame);
    };
    const next_key = core.atom.ids.next;
    const iterator_next = getValueProperty(ctx, output, global, iterator_value, next_key, caller_function, caller_frame) catch |err| {
        return rejectCombinatorAndRelease(ctx, output, global, &capability, err, caller_function, caller_frame);
    };
    if (!isCallableValue(iterator_next)) {
        return rejectCombinatorAndRelease(ctx, output, global, &capability, error.TypeError, caller_function, caller_frame);
    }
    const done_key = core.atom.predefinedId("done", .string).?;
    const value_key = core.atom.predefinedId("value", .string).?;

    // The combinator result array (Promise.all/allSettled) and the Promise.any
    // errors array (reuses this `values`) must carry %Array.prototype% so
    // `result instanceof Array` holds — qjs js_promise_all uses JS_NewArray
    // (quickjs.c:54012), not a null-proto object.
    const values = if (mode != .race) try core.Object.createArray(ctx.runtime, array_ops.arrayPrototypeFromGlobal(ctx.runtime, global)) else null;
    const state = if (values) |array| try promiseCombinatorState(ctx.runtime, capability.resolve, capability.reject, array) else null;

    var iterator_done = false;
    var index: u32 = 0;
    while (true) {
        const next_result_value = callValueOrBytecodeRoot(ctx, output, global, iterator_value, iterator_next, &.{}, caller_function, caller_frame) catch |err| {
            return rejectCombinatorAndRelease(ctx, output, global, &capability, err, caller_function, caller_frame);
        };
        const next_result = property_ops.expectObject(next_result_value) catch |err| {
            return rejectCombinatorAndRelease(ctx, output, global, &capability, err, caller_function, caller_frame);
        };
        const done_value = getValueProperty(ctx, output, global, next_result.value(), done_key, null, null) catch |err| {
            return rejectCombinatorAndRelease(ctx, output, global, &capability, err, caller_function, caller_frame);
        };
        if (value_ops.isTruthy(done_value)) {
            iterator_done = true;
            break;
        }
        const step_value = getValueProperty(ctx, output, global, next_result.value(), value_key, null, null) catch |err| {
            return rejectCombinatorAndRelease(ctx, output, global, &capability, err, caller_function, caller_frame);
        };

        if (state) |state_object| {
            const remaining = state_object.promiseCombinatorRemaining();
            try promiseSetArrayIndex(ctx.runtime, values.?, index, core.JSValue.undefinedValue());
            (try state_object.promiseCombinatorRemainingSlot(ctx.runtime)).* = remaining + 1;
        }

        const next_promise = callValueOrBytecodeRoot(ctx, output, global, constructor_value, promise_resolve, &.{step_value}, caller_function, caller_frame) catch |err| {
            if (!iterator_done) closeIteratorForAbruptCompletion(ctx, output, global, iterator_value);
            return rejectCombinatorAndRelease(ctx, output, global, &capability, err, caller_function, caller_frame);
        };

        const then_key = core.atom.ids.then;
        const then_value = getValueProperty(ctx, output, global, next_promise, then_key, caller_function, caller_frame) catch |err| {
            if (!iterator_done) closeIteratorForAbruptCompletion(ctx, output, global, iterator_value);
            return rejectCombinatorAndRelease(ctx, output, global, &capability, err, caller_function, caller_frame);
        };
        if (!isCallableValue(then_value)) {
            if (!iterator_done) closeIteratorForAbruptCompletion(ctx, output, global, iterator_value);
            return rejectCombinatorAndRelease(ctx, output, global, &capability, error.TypeError, caller_function, caller_frame);
        }

        const on_fulfilled = switch (mode) {
            .all => try promiseCombinatorCallback(ctx.runtime, global, .all_resolve, state.?, index),
            .all_settled => blk: {
                const callback = try promiseCombinatorCallback(ctx.runtime, global, .all_settled_fulfill, state.?, index);
                break :blk callback;
            },
            .any => capability.resolve,
            .race => capability.resolve,
        };
        const on_rejected = switch (mode) {
            .all => capability.reject,
            .all_settled => blk: {
                const callback = try promiseCombinatorCallback(ctx.runtime, global, .all_settled_reject, state.?, index);
                break :blk callback;
            },
            .any => try promiseCombinatorCallback(ctx.runtime, global, .any_reject, state.?, index),
            .race => capability.reject,
        };

        _ = callValueOrBytecodeRoot(ctx, output, global, next_promise, then_value, &.{ on_fulfilled, on_rejected }, caller_function, caller_frame) catch |err| {
            if (!iterator_done) closeIteratorForAbruptCompletion(ctx, output, global, iterator_value);
            return rejectCombinatorAndRelease(ctx, output, global, &capability, err, caller_function, caller_frame);
        };
        index += 1;
    }

    if (state) |state_object| {
        const remaining = state_object.promiseCombinatorRemaining();
        const next_remaining = remaining - 1;
        (try state_object.promiseCombinatorRemainingSlot(ctx.runtime)).* = next_remaining;
        if (next_remaining == 0) {
            switch (mode) {
                .all, .all_settled => {
                    _ = callValueOrBytecodeRoot(ctx, output, global, core.JSValue.undefinedValue(), capability.resolve, &.{values.?.value()}, caller_function, caller_frame) catch |err| {
                        return rejectCombinatorAndRelease(ctx, output, global, &capability, err, caller_function, caller_frame);
                    };
                },
                .any => {
                    const aggregate_error = try promiseAggregateError(ctx, global, values.?);
                    _ = try callValueOrBytecodeRoot(ctx, output, global, core.JSValue.undefinedValue(), capability.reject, &.{aggregate_error}, caller_function, caller_frame);
                },
                .race => {},
            }
        }
    }

    return capability.promise;
}

pub fn promiseKeyedCombinatorCall(
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
    const capability = try promiseCapability(ctx, output, global, constructor_value, caller_function, caller_frame);

    const resolve_key = core.atom.ids.resolve;
    const promise_resolve = getValueProperty(ctx, output, global, constructor_value, resolve_key, caller_function, caller_frame) catch |err| {
        return rejectCombinatorAndRelease(ctx, output, global, &capability, err, caller_function, caller_frame);
    };
    if (!isCallableValue(promise_resolve)) {
        return rejectCombinatorAndRelease(ctx, output, global, &capability, error.TypeError, caller_function, caller_frame);
    }

    const promises_value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const promises = objectFromValue(promises_value) orelse {
        return rejectCombinatorAndRelease(ctx, output, global, &capability, error.TypeError, caller_function, caller_frame);
    };

    const own_keys = objectRestOwnKeys(ctx, output, global, promises) catch |err| {
        return rejectCombinatorAndRelease(ctx, output, global, &capability, err, caller_function, caller_frame);
    };
    defer core.Object.freeKeys(ctx.runtime, own_keys);

    const keys = try core.Object.createArray(ctx.runtime, null);
    const values = try core.Object.createArray(ctx.runtime, null);
    const state = try promiseKeyedCombinatorState(ctx.runtime, capability.resolve, capability.reject, values, keys);

    var index: u32 = 0;
    for (own_keys) |key| {
        const desc = proxyAwareOwnPropertyDescriptor(ctx, output, global, promises, key, caller_function, caller_frame) catch |err| {
            return rejectCombinatorAndRelease(ctx, output, global, &capability, err, caller_function, caller_frame);
        } orelse continue;
        if (desc.enumerable != true) continue;

        const step_value = getValueProperty(ctx, output, global, promises_value, key, caller_function, caller_frame) catch |err| {
            return rejectCombinatorAndRelease(ctx, output, global, &capability, err, caller_function, caller_frame);
        };

        const key_value = proxyTrapKeyValue(ctx.runtime, key) catch |err| {
            return rejectCombinatorAndRelease(ctx, output, global, &capability, err, caller_function, caller_frame);
        };
        try promiseSetArrayIndex(ctx.runtime, keys, index, key_value);

        const remaining = state.promiseCombinatorRemaining();
        try promiseSetArrayIndex(ctx.runtime, values, index, core.JSValue.undefinedValue());
        (try state.promiseCombinatorRemainingSlot(ctx.runtime)).* = remaining + 1;

        const next_promise = callValueOrBytecodeRoot(ctx, output, global, constructor_value, promise_resolve, &.{step_value}, caller_function, caller_frame) catch |err| {
            return rejectCombinatorAndRelease(ctx, output, global, &capability, err, caller_function, caller_frame);
        };

        const then_key = core.atom.ids.then;
        const then_value = getValueProperty(ctx, output, global, next_promise, then_key, caller_function, caller_frame) catch |err| {
            return rejectCombinatorAndRelease(ctx, output, global, &capability, err, caller_function, caller_frame);
        };
        if (!isCallableValue(then_value)) {
            return rejectCombinatorAndRelease(ctx, output, global, &capability, error.TypeError, caller_function, caller_frame);
        }

        const on_fulfilled = if (all_settled)
            try promiseCombinatorCallback(ctx.runtime, global, .all_settled_keyed_fulfill, state, index)
        else
            try promiseCombinatorCallback(ctx.runtime, global, .all_keyed_resolve, state, index);
        const on_rejected = if (all_settled)
            try promiseCombinatorCallback(ctx.runtime, global, .all_settled_keyed_reject, state, index)
        else
            capability.reject;

        _ = callValueOrBytecodeRoot(ctx, output, global, next_promise, then_value, &.{ on_fulfilled, on_rejected }, caller_function, caller_frame) catch |err| {
            return rejectCombinatorAndRelease(ctx, output, global, &capability, err, caller_function, caller_frame);
        };
        index += 1;
    }

    const remaining = state.promiseCombinatorRemaining();
    const next_remaining = remaining - 1;
    (try state.promiseCombinatorRemainingSlot(ctx.runtime)).* = next_remaining;
    if (next_remaining == 0) {
        const keyed_result = try promiseKeyedResult(ctx.runtime, keys, values);
        _ = callValueOrBytecodeRoot(ctx, output, global, core.JSValue.undefinedValue(), capability.resolve, &.{keyed_result}, caller_function, caller_frame) catch |err| {
            return rejectCombinatorAndRelease(ctx, output, global, &capability, err, caller_function, caller_frame);
        };
    }

    return capability.promise;
}

/// Per-method body for `Promise.resolve`, matching qjs
/// `js_promise_resolve(..., magic = 0)`. Keeping it separate prevents the
/// identity hot path from inheriting the combinator/reject/try/withResolvers
/// frame and register pressure of `promiseStaticCall`.
pub fn promiseResolveStaticCall(
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
    if (try promiseResolveIdentity(ctx, output, global, constructor_value, payload, caller_function, caller_frame)) |same_promise| {
        return same_promise;
    }

    if (!(try isConstructorLike(ctx, constructor_value))) return error.TypeError;
    const capability = try promiseCapability(ctx, output, global, constructor_value, caller_function, caller_frame);
    _ = try callValueOrBytecodeRoot(ctx, output, global, core.JSValue.undefinedValue(), capability.resolve, &.{payload}, caller_function, caller_frame);
    return capability.promise;
}

pub fn promiseStaticCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    constructor_value: core.JSValue,
    args: []const core.JSValue,
    mode: PromiseStaticMode,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    if (mode == .resolve) return promiseResolveStaticCall(ctx, output, global, constructor_value, args, caller_function, caller_frame);
    if (!constructor_value.isObject()) return error.TypeError;
    if (!(try isConstructorLike(ctx, constructor_value))) return error.TypeError;

    switch (mode) {
        .all => return promiseCombinatorCall(ctx, output, global, constructor_value, args, .all, caller_function, caller_frame),
        .all_keyed => return promiseKeyedCombinatorCall(ctx, output, global, constructor_value, args, false, caller_function, caller_frame),
        .race => return promiseCombinatorCall(ctx, output, global, constructor_value, args, .race, caller_function, caller_frame),
        .all_settled => return promiseCombinatorCall(ctx, output, global, constructor_value, args, .all_settled, caller_function, caller_frame),
        .all_settled_keyed => return promiseKeyedCombinatorCall(ctx, output, global, constructor_value, args, true, caller_function, caller_frame),
        .any => return promiseCombinatorCall(ctx, output, global, constructor_value, args, .any, caller_function, caller_frame),
        else => {},
    }

    switch (mode) {
        .resolve => unreachable,
        .reject => {
            const reason = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
            const capability = try promiseCapability(ctx, output, global, constructor_value, caller_function, caller_frame);
            _ = try callValueOrBytecodeRoot(ctx, output, global, core.JSValue.undefinedValue(), capability.reject, &.{reason}, caller_function, caller_frame);
            return capability.promise;
        },
        .try_ => {
            const callback = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
            const callback_args = if (args.len >= 1) args[1..] else args[0..0];
            const capability = try promiseCapability(ctx, output, global, constructor_value, caller_function, caller_frame);
            const callback_result = callValueOrBytecodeRoot(ctx, output, global, core.JSValue.undefinedValue(), callback, callback_args, caller_function, caller_frame) catch |err| {
                const reason = try promiseErrorValue(ctx, global, err);
                _ = try callValueOrBytecodeRoot(ctx, output, global, core.JSValue.undefinedValue(), capability.reject, &.{reason}, caller_function, caller_frame);
                return capability.promise;
            };
            _ = try callValueOrBytecodeRoot(ctx, output, global, core.JSValue.undefinedValue(), capability.resolve, &.{callback_result}, caller_function, caller_frame);
            return capability.promise;
        },
        .with_resolvers => {
            const capability = try promiseCapability(ctx, output, global, constructor_value, caller_function, caller_frame);
            const result = try core.Object.create(ctx.runtime, core.class.ids.object, objectPrototypeFromGlobal(ctx.runtime, global));
            errdefer core.Object.destroyFromHeader(ctx.runtime, result.gcHeader());
            try defineValueProperty(ctx.runtime, result, core.atom.ids.promise, capability.promise);
            try defineValueProperty(ctx.runtime, result, core.atom.ids.resolve, capability.resolve);
            try defineValueProperty(ctx.runtime, result, core.atom.ids.reject, capability.reject);
            return result.value();
        },
        else => unreachable,
    }
}

pub const PromiseRejectionReason = struct {
    value: core.JSValue,
    from_exception: bool,

    pub fn deinit(self: *PromiseRejectionReason, _: *core.JSRuntime) void {
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
            .value = ctx.runtime.current_exception,
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
                .value = preallocated,
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

pub fn asyncFunctionStart(
    ctx: *core.JSContext,
    func: core.JSValue,
    current_function_value: core.JSValue,
    this_value: core.JSValue,
    args: []const core.JSValue,
    var_refs: []const *core.VarRef,
    output: ?*std.Io.Writer,
    global: *core.Object,
    call_depth_precharged: bool,
    call_entry_ctx: *core.JSContext,
    call_entry_global: *core.Object,
) HostError!core.JSValue {
    const promise = try core.promise.constructWithPrototype(ctx, promisePrototypeFromGlobal(ctx.runtime, global));

    const continuation_value = try createGeneratorObject(
        ctx,
        func,
        current_function_value,
        this_value,
        args,
        var_refs,
        output,
        global,
        false,
        call_depth_precharged,
        call_entry_ctx,
        call_entry_global,
    );
    const continuation = objectFromValue(continuation_value) orelse return error.TypeError;
    try continuation.setOptionalValueSlot(ctx.runtime, continuation.generatorAsyncPromiseSlot(), promise);

    try asyncFunctionRunAndSettle(
        call_entry_ctx,
        output,
        call_entry_global,
        continuation,
        null,
        false,
    );
    return promise;
}

pub fn asyncFunctionRunState(
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

    const caller_global = ctx.global orelse global;
    const current_function_value = continuation.generatorCurrentFunction() orelse continuation.value();
    const fb_runtime_strict = fb.isStrictMode() or fb.runtimeStrictMode();
    const call_depth_guard = try vm_call.enterCallDepth(ctx, caller_global, 0);
    defer call_depth_guard.deinit();
    try exception_ops.pollInterrupt(ctx, caller_global);
    return runWithCallEnvAfterInterruptPoll(.{
        .ctx = ctx,
        .stack = &nested_stack,
        .function = fb,
        .initial_this_value = continuation.generatorThis() orelse core.JSValue.undefinedValue(),
        .args = continuation.generatorArgs(),
        .var_refs = continuation.generatorCaptures(),
        .output = output,
        .global = caller_global,
        .strict_unresolved_get_var = fb_runtime_strict,
        .generator_state = continuation,
        .resume_value = resume_value,
        .current_function_value = current_function_value,
        .suspend_on_module_await = true,
        .call_depth_precharged = true,
    });
}

pub fn asyncFunctionRunAndSettle(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    continuation: *core.Object,
    resume_value: ?core.JSValue,
    resume_rejected: bool,
) HostError!void {
    const async_global = objectRealmGlobal(continuation) orelse global;
    const result = asyncFunctionRunState(ctx, output, async_global, continuation, resume_value, resume_rejected) catch |err| {
        continuation.completeGeneratorExecution(ctx.runtime);
        const reason = try promiseErrorValue(ctx, async_global, err);
        try asyncFunctionSettle(ctx, output, async_global, continuation, reason, true, null, null);
        clearHandledRejectionException(ctx);
        asyncFunctionClearPromise(ctx.runtime, continuation);
        return;
    };

    if (continuation.generatorJustYielded() and !continuation.generatorDone()) {
        try asyncFunctionAwaitOrReject(ctx, output, async_global, continuation, result, null, null);
        return;
    }

    continuation.completeGeneratorExecution(ctx.runtime);
    try asyncFunctionSettle(ctx, output, async_global, continuation, result, false, null, null);
    asyncFunctionClearPromise(ctx.runtime, continuation);
}

pub fn asyncFunctionAwaitOrReject(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    continuation: *core.Object,
    awaited_value: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) HostError!void {
    asyncFunctionAwait(ctx, output, global, continuation, awaited_value, caller_function, caller_frame) catch |err| {
        continuation.completeGeneratorExecution(ctx.runtime);
        const reason = try promiseErrorValue(ctx, global, err);
        try asyncFunctionSettle(ctx, output, global, continuation, reason, true, caller_function, caller_frame);
        clearHandledRejectionException(ctx);
        asyncFunctionClearPromise(ctx.runtime, continuation);
    };
}

pub fn clearHandledRejectionException(ctx: *core.JSContext) void {
    if (!ctx.hasUnhandledRejection() and ctx.hasException()) ctx.clearException();
}

pub fn asyncFunctionAwait(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    continuation: *core.Object,
    awaited_value: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) HostError!void {
    var continuation_value = continuation.value();
    var awaited = awaited_value;
    var on_fulfilled = core.JSValue.undefinedValue();
    var on_rejected = core.JSValue.undefinedValue();
    var roots = core.runtime.rootValues(.{ &continuation_value, &awaited, &on_fulfilled, &on_rejected });
    roots.activate(ctx.runtime);
    defer roots.deactivate(ctx.runtime);

    const promise_constructor = try promiseDefaultConstructor(ctx, global);
    awaited = try promiseStaticCall(ctx, output, global, promise_constructor, &.{awaited}, .resolve, caller_function, caller_frame);

    // PromiseResolve can run a constructor getter that settles its input.
    // Only the resulting fulfilled Promise has an immutable value ready for
    // direct scheduling. Pending/rejected keep the paired internal handlers.
    const fulfilled = if (objectFromValue(awaited)) |promise|
        promise.class_id == core.class.ids.promise and promise.promiseResult() != null and !promise.promiseIsRejected()
    else
        false;
    if (fulfilled) {
        // PromiseResolve (including any constructor getter) has completed.
        // Await has no observable result capability: one typed FIFO entry is
        // the complete reaction. Prepare capacity while the source Promise
        // and continuation are rooted, then publish without allocating.
        const promise = objectFromValue(awaited).?;
        try ctx.runtime.job_queue.reserveEntries(1);
        ctx.runtime.job_queue.enqueueReserved(jobs_mod.Job.initAsyncResume(ctx, continuation_value, promise.promiseResult().?));
        return;
    }
    on_fulfilled = try asyncFunctionResumeCallback(ctx.runtime, global, continuation, false);
    on_rejected = try asyncFunctionResumeCallback(ctx.runtime, global, continuation, true);

    // qjs js_async_function_resume (quickjs.c:21268-21290): the resume
    // callbacks attach through the INTERNAL perform_promise_then with
    // undefined resolving funcs — a (patched) Promise.prototype.then property
    // is never read for a native-promise await.
    try performPromiseThen(ctx, output, global, awaited, on_fulfilled, on_rejected, core.JSValue.undefinedValue(), core.JSValue.undefinedValue());
}

test "fulfilled await preparation OOM never publishes a partial FIFO job" {
    var failures: usize = 0;
    var successes: usize = 0;
    for ([_]usize{ 0, 40, 80, 160, 240, 320, 640, 1280 }) |allowance| {
        const rt = try core.JSRuntime.create(std.testing.allocator);
        defer rt.destroy();
        const ctx = try core.JSContext.create(rt);
        defer ctx.destroy();
        const global = try testStandardGlobal(ctx);
        var continuation = (try core.Object.create(rt, core.class.ids.object, null)).value();
        var awaited = core.JSValue.undefinedValue();
        var roots = core.runtime.rootValues(.{ &continuation, &awaited });
        roots.activate(rt);
        defer roots.deactivate(rt);
        awaited = try core.promise.fulfilledWithPrototype(ctx, core.JSValue.int32(42), promisePrototypeFromGlobal(rt, global));
        // Prime the intrinsic, but leave the FIFO empty so the allocation
        // limit tests the remaining preparation failure: queue storage.
        _ = try promiseDefaultConstructor(ctx, global);
        try std.testing.expectEqual(@as(usize, 0), rt.job_queue.capacity);
        rt.suppressLimitCollectionForTest(true);
        defer rt.suppressLimitCollectionForTest(false);
        rt.setMemoryLimit(rt.memory.allocated_bytes + allowance);
        defer rt.setMemoryLimit(null);
        asyncFunctionAwait(ctx, null, global, try core.Object.expect(continuation), awaited, null, null) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expectEqual(@as(usize, 0), rt.job_queue.jobs.len);
            try std.testing.expectEqual(@as(usize, 0), rt.job_queue.reserved_entries);
            try std.testing.expectEqual(@as(?i32, 42), (try core.Object.expect(awaited)).promiseResult().?.asInt32());
            failures += 1;
            continue;
        };
        successes += 1;
        try std.testing.expectEqual(@as(usize, 1), rt.job_queue.jobs.len);
        try std.testing.expectEqual(@as(usize, 0), rt.job_queue.reserved_entries);
    }
    try std.testing.expect(failures > 0);
    try std.testing.expect(successes > 0);
}

pub fn asyncFunctionResumeCallback(
    rt: *core.JSRuntime,
    global: *core.Object,
    continuation: *core.Object,
    rejected: bool,
) !core.JSValue {
    var rooted_continuation: ?*core.Object = continuation;
    var roots = core.runtime.rootObjects(.{&rooted_continuation});
    roots.activate(rt);
    defer roots.deactivate(rt);

    // qjs js_async_function_resolve_create: internal Await handlers carry
    // only the continuation; the class distinguishes fulfillment/rejection.
    // User thenables receive separate, fully described resolving functions.
    const prototype = functionPrototypeFromGlobal(rt, global) orelse return error.InvalidBuiltinRegistry;
    const class_id = if (rejected) core.class.ids.async_function_reject else core.class.ids.async_function_resolve;
    const callback = try core.Object.create(rt, class_id, prototype);
    callback.setAsyncResumeContinuation(rt, rooted_continuation);
    return callback.value();
}

fn asyncResumeJobCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    payload: *const jobs_mod.AsyncResumePayload,
) HostError!void {
    // Keep the former internal callback's outer call-entry poll. The existing
    // resume path below retains its stack guard, inner poll and function realm.
    try exception_ops.pollInterrupt(ctx, global);
    const continuation = objectFromValue(payload.continuation) orelse unreachable;
    try asyncFunctionRunAndSettle(ctx, output, global, continuation, payload.value, false);
}

pub fn asyncFunctionResumeCallbackCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    function_object: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) HostError!?core.JSValue {
    const continuation = function_object.asyncResumeContinuation() orelse return null;
    const rejected = function_object.class_id == core.class.ids.async_function_reject;
    const resume_value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    try asyncFunctionRunAndSettle(ctx, output, objectRealmGlobal(continuation) orelse global, continuation, resume_value, rejected);
    _ = caller_function;
    _ = caller_frame;
    return core.JSValue.undefinedValue();
}

test "async resume callbacks keep only internal state and trace their continuation" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    const global = try testStandardGlobal(ctx);
    const function_proto = functionPrototypeFromGlobal(rt, global).?;
    const marker_key = try rt.internAtom("continuation-marker");

    for ([_]bool{ false, true }) |rejected| {
        var continuation: ?*core.Object = try core.Object.create(rt, core.class.ids.object, null);
        var callback: ?*core.Object = null;
        var roots = core.runtime.rootObjects(.{ &continuation, &callback });
        roots.activate(rt);
        defer roots.deactivate(rt);
        const marker = try rt.atoms.newValueSymbol("async-resume-continuation-root");
        try continuation.?.defineOwnProperty(rt, marker_key, core.Descriptor.data(try rt.takeSymbolValue(marker), true, true, true));
        const old_threshold = rt.gcThreshold();
        rt.setGCThreshold(0);
        defer rt.setGCThreshold(old_threshold);
        callback = try core.Object.expect(try asyncFunctionResumeCallback(rt, global, continuation.?, rejected));

        try std.testing.expectEqual(if (rejected) core.class.ids.async_function_reject else core.class.ids.async_function_resolve, callback.?.class_id);
        try std.testing.expectEqual(core.class.PayloadKind.none, callback.?.flags.class_payload_kind);
        try std.testing.expect(call_mod.isCallableObjectValue(callback.?.value()));
        try std.testing.expect(call_runtime.isCallableValue(callback.?.value()));
        try std.testing.expect(!try call_runtime.isConstructorLike(ctx, callback.?.value()));
        try std.testing.expect(callback.?.externalClassPayload() == null);
        try std.testing.expect(callback.?.externalClassPayloadConst() == null);
        try std.testing.expect(!core.Object.payloadKindNeedsFinalizer(callback.?.class_id, callback.?.flags.class_payload_kind));
        try std.testing.expectEqual(function_proto, callback.?.getPrototype().?);
        try std.testing.expectEqual(@as(u32, 0), callback.?.shape_ref.prop_count);
        try std.testing.expect(callback.?.functionRealmGlobalPtr() == null);
        try std.testing.expectEqual(core.atom.null_atom, callback.?.nativeDispatchName());

        // The callback must be the sole root of its continuation at this boundary.
        continuation = null;
        _ = rt.runObjectCycleRemoval();
        try std.testing.expect(rt.atoms.name(marker) != null);
        const retained = callback.?.asyncResumeContinuation().?;
        try std.testing.expectEqual(marker, (try retained.getProperty(marker_key)).asSymbolAtom().?);
        callback = null;
        _ = rt.runObjectCycleRemoval();
        try std.testing.expect(rt.atoms.name(marker) == null);
    }
}

test "async resume callback allocation failure preserves its continuation" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    const global = try testStandardGlobal(ctx);
    var continuation: ?*core.Object = try core.Object.create(rt, core.class.ids.object, null);
    var roots = core.runtime.rootObjects(.{&continuation});
    roots.activate(rt);
    defer roots.deactivate(rt);
    const marker_key = try rt.internAtom("continuation-marker");
    try continuation.?.defineOwnProperty(rt, marker_key, core.Descriptor.data(core.JSValue.int32(42), true, true, true));
    // The object boundary may collect unrelated bootstrap garbage first;
    // zero keeps the allocation forbidden even after that reclamation.
    rt.setMemoryLimit(0);
    defer rt.setMemoryLimit(null);
    try std.testing.expectError(error.OutOfMemory, asyncFunctionResumeCallback(rt, global, continuation.?, false));
    rt.setMemoryLimit(null);
    _ = rt.runObjectCycleRemoval();
    try std.testing.expectEqual(@as(?i32, 42), (try continuation.?.getProperty(marker_key)).asInt32());
    const callback = try core.Object.expect(try asyncFunctionResumeCallback(rt, global, continuation.?, true));
    try std.testing.expectEqual(continuation.?, callback.asyncResumeContinuation().?);
}

test "async resume callback continuation barrier preserves young state" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    const global = try testStandardGlobal(ctx);
    const initial = try core.Object.create(rt, core.class.ids.object, null);
    var callback: ?*core.Object = try core.Object.expect(try asyncFunctionResumeCallback(rt, global, initial, false));
    var roots = core.runtime.rootObjects(.{&callback});
    roots.activate(rt);
    defer roots.deactivate(rt);
    _ = try core.gc_trace_stw.collectMinor(rt, null, .declared_only);
    try std.testing.expect(!callback.?.gcHeader().metaConst().flags.young);

    const young = try core.Object.create(rt, core.class.ids.object, null);
    try std.testing.expect(young.gcHeader().metaConst().flags.young);
    callback.?.setAsyncResumeContinuation(rt, young);
    try std.testing.expect(rt.gc.generation.remembered.contains(@intFromPtr(callback.?.gcHeader())));
    // Declared-only collection cannot rescue young through this Zig local.
    _ = try core.gc_trace_stw.collectMinor(rt, null, .declared_only);
    try std.testing.expect(rt.ownsObject(young));
    try std.testing.expectEqual(young, callback.?.asyncResumeContinuation().?);

    const removed = try core.Object.create(rt, core.class.ids.object, null);
    callback.?.setAsyncResumeContinuation(rt, removed);
    callback.?.setAsyncResumeContinuation(rt, null);
    _ = try core.gc_trace_stw.collectMinor(rt, null, .declared_only);
    try std.testing.expect(!rt.ownsObject(removed));
}

/// Settle a rooted ordinary-frame async result without a generator carrier.
pub fn settleAsyncPromise(ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, promise: core.JSValue, value: core.JSValue, rejected: bool) HostError!void {
    var rooted_promise = promise;
    var rooted_value = value;
    var roots = core.runtime.rootValues(.{ &rooted_promise, &rooted_value });
    roots.activate(ctx.runtime);
    defer roots.deactivate(ctx.runtime);
    const target = objectFromValue(rooted_promise) orelse return error.TypeError;
    std.debug.assert(target.class_id == core.class.ids.promise);
    try exception_ops.pollInterrupt(ctx, global);
    const view = try builtin_dispatch.CallRealmView.caller(ctx);
    _ = try resolvePromiseWithState(view.realm, output, view.global, target, null, rooted_value, rejected, null, null, null);
}

pub fn asyncFunctionSettle(
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
    var rooted_continuation = continuation.value();
    var promise_value = continuation.generatorAsyncPromise() orelse return error.TypeError;
    var root_frame = core.runtime.rootValues(.{ &rooted_value, &rooted_continuation, &promise_value });
    root_frame.activate(ctx.runtime);
    defer root_frame.deactivate(ctx.runtime);

    const target = objectFromValue(promise_value) orelse return error.TypeError;
    std.debug.assert(target.class_id == core.class.ids.promise);
    // Preserve the former JS_Call entry poll and C_FUNCTION_DATA caller realm.
    // The fresh internal resolver had no private function-realm override; its
    // self-resolution error therefore also used this caller view. No resolver
    // can expose this invocation's fresh once state, so it needs no heap cell.
    // Observing a then getter still reserves durable FIFO ownership first;
    // the eventual thenable job creates its own externally shared once state.
    try exception_ops.pollInterrupt(ctx, global);
    const view = try builtin_dispatch.CallRealmView.caller(ctx);
    _ = try resolvePromiseWithState(view.realm, output, view.global, target, null, rooted_value, rejected, null, caller_function, caller_frame);
}

test "asyncFunctionSettle roots continuation target and result through interrupt GC" {
    const Probe = struct {
        calls: usize = 0,

        fn run(rt: *core.JSRuntime, user_context: ?*anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(user_context.?));
            self.calls += 1;
            _ = rt.runObjectCycleRemoval();
            return false;
        }
    };
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    const global = try testStandardGlobal(ctx);
    var promise_value = core.JSValue.undefinedValue();
    var continuation_value = core.JSValue.undefinedValue();
    var result_value = core.JSValue.undefinedValue();
    var setup_roots = core.runtime.rootValues(.{ &promise_value, &continuation_value, &result_value });
    setup_roots.activate(rt);
    var setup_active = true;
    defer if (setup_active) setup_roots.deactivate(rt);
    promise_value = try core.promise.constructWithPrototype(ctx, promisePrototypeFromGlobal(rt, global));
    const target = objectFromValue(promise_value) orelse unreachable;
    const continuation = try core.Object.create(rt, core.class.ids.generator, null);
    continuation_value = continuation.value();
    try continuation.setOptionalValueSlot(rt, continuation.generatorAsyncPromiseSlot(), promise_value);
    const symbol_atom = try rt.atoms.newValueSymbol("interrupt-async-settle-symbol");
    result_value = try rt.takeSymbolValue(symbol_atom);

    // Remove setup roots so only the callee can keep these values alive.
    // Declared-root collection ignores the native pointer locals above.
    setup_roots.deactivate(rt);
    setup_active = false;
    var probe = Probe{};
    rt.setInterruptHandler(Probe.run, &probe);
    defer rt.setInterruptHandler(null, null);
    ctx.interrupt_counter = 1;
    try asyncFunctionSettle(ctx, null, global, continuation, result_value, false, null, null);

    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expect(rt.ownsObject(continuation));
    try std.testing.expect(rt.ownsObject(target));
    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    try std.testing.expectEqual(symbol_atom, target.promiseResult().?.asSymbolAtom().?);
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(!rt.ownsObject(continuation));
    try std.testing.expect(!rt.ownsObject(target));
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

test "asyncFunctionSettle needs no allocation for scalar completion" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    const global = try testStandardGlobal(ctx);
    var promise_value = core.JSValue.undefinedValue();
    var continuation_value = core.JSValue.undefinedValue();
    var roots = core.runtime.rootValues(.{ &promise_value, &continuation_value });
    roots.activate(rt);
    defer roots.deactivate(rt);
    for ([_]bool{ false, true }) |rejected| {
        promise_value = try core.promise.constructWithPrototype(ctx, promisePrototypeFromGlobal(rt, global));
        const continuation = try core.Object.create(rt, core.class.ids.generator, null);
        continuation_value = continuation.value();
        try continuation.setOptionalValueSlot(rt, continuation.generatorAsyncPromiseSlot(), promise_value);
        _ = rt.runObjectCycleRemoval();
        rt.suppressLimitCollectionForTest(true);
        defer rt.suppressLimitCollectionForTest(false);
        const allocated = rt.memory.allocated_bytes;
        rt.setMemoryLimit(allocated);
        defer rt.setMemoryLimit(null);
        // Keep this an allocation test; interrupt-triggered collection has
        // its own coverage and must not release memory to hide an allocation.
        ctx.interrupt_counter = core.JSContext.interrupt_counter_reset;
        try asyncFunctionSettle(ctx, null, global, continuation, core.JSValue.int32(42), rejected, null, null);
        const target = objectFromValue(promise_value) orelse unreachable;
        try std.testing.expectEqual(@as(?i32, 42), target.promiseResult().?.asInt32());
        try std.testing.expectEqual(rejected, target.promiseIsRejected());
        try std.testing.expectEqual(allocated, rt.memory.allocated_bytes);
        try std.testing.expectEqual(@as(usize, 0), rt.job_queue.jobs.len);
    }
}

test "asyncFunctionSettle fits the allocation budget of its shared state" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    const global = try testStandardGlobal(ctx);
    // Warm metadata and allocator classes before pricing the one completion.
    const promise = try core.promise.constructWithPrototype(ctx, promisePrototypeFromGlobal(rt, global));
    var promise_root = promise;
    var roots = core.runtime.rootValues(.{&promise_root});
    roots.activate(rt);
    defer roots.deactivate(rt);
    _ = try createPromiseResolvingPair(rt, global, promise);
    const continuation = try core.Object.create(rt, core.class.ids.generator, null);
    try continuation.setOptionalValueSlot(rt, continuation.generatorAsyncPromiseSlot(), promise);

    rt.suppressLimitCollectionForTest(true);
    defer rt.suppressLimitCollectionForTest(false);
    const allocated = rt.memory.allocated_bytes;
    rt.setMemoryLimit(allocated + 1024);
    defer rt.setMemoryLimit(null);
    try asyncFunctionSettle(ctx, null, global, continuation, core.JSValue.int32(42), false, null, null);
    const target = objectFromValue(promise) orelse unreachable;
    try std.testing.expectEqual(@as(?i32, 42), target.promiseResult().?.asInt32());
    try std.testing.expect(!target.promiseIsRejected());
}

test "asyncFunctionSettle transfers getter OOM completion to FIFO exactly once" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    const global = try testStandardGlobal(ctx);
    defer rt.setMemoryLimit(null);

    var target_value = core.JSValue.undefinedValue();
    var continuation_value = core.JSValue.undefinedValue();
    var thenable_value = core.JSValue.undefinedValue();
    var roots = core.runtime.rootValues(.{ &target_value, &continuation_value, &thenable_value });
    roots.activate(rt);
    defer roots.deactivate(rt);
    const target = try core.Object.create(rt, core.class.ids.promise, null);
    target_value = target.value();
    try appendDummyPromiseReaction(rt, target);
    const continuation = try core.Object.create(rt, core.class.ids.generator, null);
    continuation_value = continuation.value();
    try continuation.setOptionalValueSlot(rt, continuation.generatorAsyncPromiseSlot(), target_value);
    const thenable = try core.Object.create(rt, core.class.ids.object, null);
    thenable_value = thenable.value();
    var probe = PromiseJobOomProbe{ .fail = false };
    const getter = try promiseJobOomProbeFunction(ctx, &probe, "asyncThenGetterOomProbe");
    try thenable.defineOwnProperty(rt, core.atom.ids.then, core.Descriptor.accessor(getter, core.JSValue.undefinedValue(), true, true));

    try asyncFunctionSettle(ctx, null, global, continuation, thenable_value, false, null, null);
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expect(target.promiseResult() == null);
    try std.testing.expectEqual(@as(usize, 1), rt.job_queue.jobs.len);
    try std.testing.expectEqual(jobs_mod.Kind.promise_settlement, std.meta.activeTag(rt.job_queue.jobs[0].payload));
    // The temporary once state and continuation may die. The FIFO owns the
    // target and observed completion; retrying must not read the getter again.
    continuation_value = core.JSValue.undefinedValue();
    thenable_value = core.JSValue.undefinedValue();
    _ = rt.runObjectCycleRemoval();
    rt.setMemoryLimit(null);
    try std.testing.expectEqual(jobs_mod.RunOneStatus.success, try drainOnePendingJob(ctx, null, global));
    try std.testing.expect(target.promiseResult().?.sameValue(thenable.value()));
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expectEqual(jobs_mod.RunOneStatus.success, try drainOnePendingJob(ctx, null, global));
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expectEqual(jobs_mod.RunOneStatus.empty, try drainOnePendingJob(ctx, null, global));
}

test "asyncFunctionSettle roots direct symbol result before promise stores it" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    const ctx = try core.JSContext.create(rt);
    const global = try testStandardGlobal(ctx);
    const continuation = try core.Object.create(rt, core.class.ids.generator, null);
    defer {
        ctx.destroy();
        rt.destroy();
    }

    const promise = try core.promise.constructWithPrototype(ctx, promisePrototypeFromGlobal(rt, global));
    try continuation.setOptionalValueSlot(rt, continuation.generatorAsyncPromiseSlot(), promise);

    const symbol_atom = try rt.atoms.newValueSymbol("gc-async-settle-symbol");
    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);
    const settle_value = try rt.takeSymbolValue(symbol_atom);
    try asyncFunctionSettle(ctx, null, global, continuation, settle_value, false, null, null);

    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    const promise_object = objectFromValue(promise) orelse return error.TypeError;
    const result = promise_object.promiseResult() orelse return error.TypeError;
    try std.testing.expectEqual(symbol_atom, result.asSymbolAtom().?);

    try promise_object.setPromiseResult(rt, null);
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

pub fn asyncFunctionClearPromise(rt: *core.JSRuntime, continuation: *core.Object) void {
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

pub fn asyncFromSyncIteratorMethodCall(
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
        1 => try asyncFromSyncIteratorNext(ctx, output, global, receiver, wrapper, sync_iterator, args, caller_function, caller_frame),
        2 => try asyncFromSyncIteratorReturn(ctx, output, global, wrapper, sync_iterator, args, caller_function, caller_frame),
        3 => try asyncFromSyncIteratorThrow(ctx, output, global, wrapper, sync_iterator, args, caller_function, caller_frame),
        else => null,
    };
}

/// Mirrors the GEN_MAGIC_THROW arm of js_async_from_sync_iterator_next
/// (quickjs.c:54503-54520): `.throw` is re-read per call; absent throw closes
/// the sync iterator and rejects TypeError "throw is not a method".
pub fn asyncFromSyncIteratorThrow(
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
    const throw_key = core.atom.ids.throw;
    const throw_method = getValueProperty(ctx, output, global, sync_iterator, throw_key, caller_function, caller_frame) catch |err| {
        return rejectedPromiseForRuntimeError(ctx, global, err, promisePrototypeFromGlobal(ctx.runtime, global));
    };
    if (throw_method.isUndefined() or throw_method.isNull()) {
        // IteratorClose(sync_iter) with no pending exception; a close failure
        // rejects with that error, otherwise reject the TypeError
        // (quickjs.c:54515-54519).
        iterator_ops.iteratorCloseValue(ctx, output, global, sync_iterator, caller_function, caller_frame) catch |err| {
            return rejectedPromiseForRuntimeError(ctx, global, err, promisePrototypeFromGlobal(ctx.runtime, global));
        };
        const reason = try exception_ops.createNamedError(ctx, global, "TypeError", "throw is not a method");
        return core.promise.rejectedWithPrototype(ctx, reason, promisePrototypeFromGlobal(ctx.runtime, global));
    }
    if (!isCallableValue(throw_method)) {
        const reason = try exception_ops.createNamedError(ctx, global, "TypeError", "throw is not a method");
        return core.promise.rejectedWithPrototype(ctx, reason, promisePrototypeFromGlobal(ctx.runtime, global));
    }
    const result = if (args.len > 0)
        callValueOrBytecodeRoot(ctx, output, global, sync_iterator, throw_method, args[0..1], caller_function, caller_frame)
    else
        callValueOrBytecodeRoot(ctx, output, global, sync_iterator, throw_method, &.{}, caller_function, caller_frame);
    const throw_result = result catch |err| {
        return rejectedPromiseForRuntimeError(ctx, global, err, promisePrototypeFromGlobal(ctx.runtime, global));
    };
    return asyncFromSyncIteratorContinuation(ctx, output, global, throw_result, sync_iterator, true, caller_function, caller_frame);
}

/// The onRejected close-wrap reaction (js_async_from_sync_iterator_close_wrap,
/// quickjs.c:54468-54476): re-throw the reason, close the sync iterator with
/// the exception pending (close errors swallowed), and propagate the rejection.
pub fn asyncFromSyncIteratorCloseWrap(
    rt: *core.JSRuntime,
    global: *core.Object,
    sync_iterator: core.JSValue,
) !core.JSValue {
    const callback = try builtin_glue.createDataFunction(rt, global, "", 1);
    const callback_object = objectFromValue(callback) orelse return error.TypeError;
    try callback_object.setInternalCallableTag(rt, .async_from_sync_iterator_close_wrap);
    try callback_object.setOptionalValueSlot(rt, try callback_object.functionAsyncContinuationSlot(rt), sync_iterator);
    return callback;
}

pub fn asyncFromSyncIteratorCloseWrapCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    function_object: *core.Object,
    args: []const core.JSValue,
) HostError!?core.JSValue {
    const sync_iterator = function_object.functionAsyncContinuation() orelse return null;
    const reason = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    // JS_IteratorClose(…, TRUE): the close runs with the exception logically
    // pending — its own result and failures are discarded.
    iterator_ops.iteratorCloseValue(ctx, output, global, sync_iterator, null, null) catch {
        if (ctx.hasException()) ctx.clearException();
    };
    _ = ctx.throwValue(reason);
    return error.JSException;
}

pub fn asyncFromSyncIteratorNext(
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
    const next_method = if (wrapper.iteratorNext()) |stored| stored else blk: {
        const next_key = core.atom.ids.next;
        const method = try getValueProperty(ctx, output, global, sync_iterator, next_key, caller_function, caller_frame);
        if (!isCallableValue(method)) return error.TypeError;
        break :blk method;
    };
    const result = if (args.len > 0)
        callValueOrBytecodeRoot(ctx, output, global, sync_iterator, next_method, args[0..1], caller_function, caller_frame)
    else
        callValueOrBytecodeRoot(ctx, output, global, sync_iterator, next_method, &.{}, caller_function, caller_frame);
    const next_result = result catch |err| {
        return rejectedPromiseForRuntimeError(ctx, global, err, promisePrototypeFromGlobal(ctx.runtime, global));
    };
    _ = receiver;
    return asyncFromSyncIteratorContinuation(ctx, output, global, next_result, sync_iterator, true, caller_function, caller_frame);
}

pub fn asyncFromSyncIteratorReturn(
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
    const return_key = core.atom.ids.return_;
    const return_method = try getValueProperty(ctx, output, global, sync_iterator, return_key, caller_function, caller_frame);
    if (return_method.isUndefined() or return_method.isNull()) {
        const done_result = try createIteratorResult(ctx.runtime, global, core.JSValue.undefinedValue(), true);
        return core.promise.fulfilledWithPrototype(ctx, done_result, promisePrototypeFromGlobal(ctx.runtime, global));
    }
    if (!isCallableValue(return_method)) return error.TypeError;
    const result = if (args.len > 0)
        callValueOrBytecodeRoot(ctx, output, global, sync_iterator, return_method, args[0..1], caller_function, caller_frame)
    else
        callValueOrBytecodeRoot(ctx, output, global, sync_iterator, return_method, &.{}, caller_function, caller_frame);
    const return_result = result catch |err| {
        return rejectedPromiseForRuntimeError(ctx, global, err, promisePrototypeFromGlobal(ctx.runtime, global));
    };
    return asyncFromSyncIteratorContinuation(ctx, output, global, return_result, sync_iterator, false, caller_function, caller_frame);
}

pub fn asyncFromSyncIteratorContinuation(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    result: core.JSValue,
    sync_iterator: core.JSValue,
    close_on_rejection: bool,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const capability = try defaultPromiseCapability(ctx, output, global, caller_function, caller_frame);

    const result_object = property_ops.expectObject(result) catch |err| {
        try promiseRejectCapabilityForError(ctx, output, global, capability.reject, err, caller_function, caller_frame);
        return capability.promise;
    };
    const done_key = core.atom.predefinedId("done", .string) orelse return error.TypeError;
    const done_value = getValueProperty(ctx, output, global, result_object.value(), done_key, caller_function, caller_frame) catch |err| {
        try promiseRejectCapabilityForError(ctx, output, global, capability.reject, err, caller_function, caller_frame);
        return capability.promise;
    };
    const done = valueTruthy(done_value);

    const value_key = core.atom.predefinedId("value", .string) orelse return error.TypeError;
    const value = getValueProperty(ctx, output, global, result_object.value(), value_key, caller_function, caller_frame) catch |err| {
        try promiseRejectCapabilityForError(ctx, output, global, capability.reject, err, caller_function, caller_frame);
        return capability.promise;
    };

    const promise_constructor = try promiseDefaultConstructor(ctx, global);
    const value_wrapper_promise = promiseStaticCall(ctx, output, global, promise_constructor, &.{value}, .resolve, caller_function, caller_frame) catch |err| {
        // PromiseResolve threw: close the sync iterator with the exception
        // pending, then reject (quickjs.c:54544-54549).
        if (close_on_rejection and !done) {
            iterator_ops.iteratorCloseValue(ctx, output, global, sync_iterator, caller_function, caller_frame) catch {
                if (ctx.hasException()) ctx.clearException();
            };
        }
        try promiseRejectCapabilityForError(ctx, output, global, capability.reject, err, caller_function, caller_frame);
        return capability.promise;
    };

    const unwrap = try asyncFromSyncIteratorUnwrap(ctx.runtime, global, done);

    // onRejected close-wrap only when `!done && magic != GEN_MAGIC_RETURN`
    // (quickjs.c:54570-54579).
    const close_wrap: core.JSValue = if (close_on_rejection and !done)
        try asyncFromSyncIteratorCloseWrap(ctx.runtime, global, sync_iterator)
    else
        core.JSValue.undefinedValue();

    performPromiseThen(
        ctx,
        output,
        global,
        value_wrapper_promise,
        unwrap,
        close_wrap,
        capability.resolve,
        capability.reject,
    ) catch |err| {
        try promiseRejectCapabilityForError(ctx, output, global, capability.reject, err, caller_function, caller_frame);
        return capability.promise;
    };
    return capability.promise;
}

pub fn asyncFromSyncIteratorUnwrap(
    rt: *core.JSRuntime,
    global: *core.Object,
    done: bool,
) !core.JSValue {
    const callback = try builtin_glue.createDataFunction(rt, global, "", 1);
    const callback_object = objectFromValue(callback) orelse return error.TypeError;
    try callback_object.setInternalCallableTag(rt, .async_from_sync_iterator_unwrap);
    (try callback_object.functionAsyncFromSyncUnwrapDoneSlot(rt)).* = if (done) 2 else 1;
    return callback;
}

pub fn asyncFromSyncIteratorUnwrapCall(
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

pub fn promiseFinallyCallback(
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
    var root_frame = core.runtime.rootValues(.{
        &rooted_payload,
        &rooted_on_finally,
        &rooted_constructor,
    });
    root_frame.activate(rt);
    defer root_frame.deactivate(rt);

    const callback = try builtin_glue.createDataFunction(rt, global, "", if (mode == .fulfill or mode == .reject) 1 else 0);
    const callback_object = objectFromValue(callback) orelse return error.TypeError;
    try callback_object.setInternalCallableTag(rt, .promise_finally_callback);
    (try callback_object.functionPromiseFinallyModeSlot(rt)).* = @intFromEnum(mode);
    if (payload != null) try callback_object.setFunctionPromiseFinallyPayload(rt, rooted_payload);
    if (on_finally != null) try callback_object.setFunctionPromiseFinallyCallback(rt, rooted_on_finally);
    if (constructor_value != null) try callback_object.setFunctionPromiseFinallyConstructor(rt, rooted_constructor);
    return callback;
}

test "promiseFinallyCallback roots direct symbol payload while allocating callback" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    const global = try testStandardGlobal(ctx);

    const symbol_atom = try rt.atoms.newValueSymbol("gc-promise-finally-payload-symbol");
    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const payload_value = try rt.takeSymbolValue(symbol_atom);
    const callback = try promiseFinallyCallback(
        rt,
        global,
        .return_value,
        payload_value,
        null,
        null,
    );
    const callback_object = objectFromValue(callback) orelse return error.TypeError;

    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    const stored = callback_object.functionPromiseFinallyPayload() orelse return error.TypeError;
    try std.testing.expectEqual(symbol_atom, stored.asSymbolAtom().?);

    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

pub fn promiseFinallyCallbackCall(
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
            return payload;
        },
        .throw_reason => {
            const payload = function_object.functionPromiseFinallyPayload() orelse return error.TypeError;
            _ = ctx.throwValue(payload);
            return error.JSException;
        },
        .fulfill, .reject => {
            const payload = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
            const on_finally = function_object.functionPromiseFinallyCallback() orelse return error.TypeError;
            const constructor_value = function_object.functionPromiseFinallyConstructor() orelse return error.TypeError;

            const callback_result = try callValueOrBytecodeRoot(ctx, output, global, core.JSValue.undefinedValue(), on_finally, &.{}, caller_function, caller_frame);
            const resolved = try promiseStaticCall(ctx, output, global, constructor_value, &.{callback_result}, .resolve, caller_function, caller_frame);

            const continuation = try promiseFinallyCallback(
                ctx.runtime,
                global,
                if (mode == .fulfill) .return_value else .throw_reason,
                payload,
                null,
                null,
            );

            const then_key = core.atom.ids.then;
            const then_value = try getValueProperty(ctx, output, global, resolved, then_key, caller_function, caller_frame);
            if (!isCallableValue(then_value)) return error.TypeError;
            return try callValueOrBytecodeRoot(ctx, output, global, resolved, then_value, &.{continuation}, caller_function, caller_frame);
        },
    }
}

pub fn promiseFinally(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const constructor_value = try promiseSpeciesConstructor(ctx, output, global, receiver, caller_function, caller_frame);

    const on_finally = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const then_fulfilled = if (isCallableValue(on_finally))
        try promiseFinallyCallback(ctx.runtime, global, .fulfill, null, on_finally, constructor_value)
    else
        on_finally;
    const then_rejected = if (isCallableValue(on_finally))
        try promiseFinallyCallback(ctx.runtime, global, .reject, null, on_finally, constructor_value)
    else
        on_finally;

    const then_atom = core.atom.ids.then;
    const then_value = try getValueProperty(ctx, output, global, receiver, then_atom, caller_function, caller_frame);
    if (!isCallableValue(then_value)) return error.TypeError;
    return callValueOrBytecodeRoot(ctx, output, global, receiver, then_value, &.{ then_fulfilled, then_rejected }, caller_function, caller_frame);
}

pub fn performPromiseThen(
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
    // promiseThen uses so awaiting a waitAsync promise still resumes.
    if (object.promiseResultSlot().* == null and !object.promiseIsRejected() and
        atomicsWaitAsyncPromise(ctx.runtime, object) and isCallableValue(on_fulfilled))
    {
        try object.setPromiseReactionCallback(ctx.runtime, on_fulfilled);
        try object.setPromiseReactionArg(ctx.runtime, null);
        return;
    }
    const stored_on_fulfilled = if (isCallableValue(on_fulfilled)) on_fulfilled else core.JSValue.undefinedValue();
    const stored_on_rejected = if (isCallableValue(on_rejected)) on_rejected else core.JSValue.undefinedValue();
    const reaction = try promiseReactionRecord(ctx.runtime, stored_on_fulfilled, stored_on_rejected, resolve_value, reject_value);
    if (object.promiseResultSlot().* == null) {
        try appendPromiseReaction(ctx.runtime, object, reaction);
        if (object.promiseIsRejected()) core.promise.markHandled(ctx, object);
        return;
    }

    const result_value = if (object.promiseResult()) |stored| stored else core.JSValue.undefinedValue();
    const reaction_object = objectFromValue(reaction) orelse return error.TypeError;
    const rejected = object.promiseIsRejected();
    var prepared_job = ctx.runtime.job_queue.preparePromiseReaction(ctx, reaction_object.value(), result_value, rejected);
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
    try std.testing.expect(ctx.hasUnhandledRejection());
    try std.testing.expect(ctx.hasException());
    try std.testing.expect(ctx.runtime.current_exception.sameValue(reason));

    // TGC S4-b: storage buffers are collected carriers now, so the
    // limit-triggered retry collection inside `checkAllocation` can free real
    // bytes. Sweep first so the baseline is the LIVE size.
    _ = rt.tryRunObjectCycleRemovalWithValueRoots(null, .engine_active) catch {};
    const baseline = rt.memory.allocated_bytes;
    rt.setMemoryLimit(baseline);
    try std.testing.expectError(error.OutOfMemory, performPromiseThen(
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
    try performPromiseThen(
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

pub fn promiseThen(
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
    if (is_finally) return try promiseFinally(ctx, output, global, receiver, args, caller_function, caller_frame);
    // Promise.prototype.catch is ALWAYS Invoke(this, "then", [undefined, arg])
    // (qjs js_promise_catch = JS_Invoke(this_val, JS_ATOM_then, ...),
    // quickjs.c:54275-54282) — it observes a user-overridden/patched `then`
    // and never takes the builtin then-capability fast path, so route every
    // catch (incl. on a genuine promise) through the generic this.then path.
    if (is_catch) return try promiseCatchGeneric(ctx, output, global, receiver, args);
    if (!receiver.isObject()) {
        return error.TypeError;
    }
    const object = property_ops.expectObject(receiver) catch {
        if (is_catch) return try promiseCatchGeneric(ctx, output, global, receiver, args);
        return error.TypeError;
    };
    if (object.class_id != core.class.ids.promise) {
        if (is_catch) return try promiseCatchGeneric(ctx, output, global, receiver, args);
        return error.TypeError;
    }
    const constructor_value = try promiseSpeciesConstructor(ctx, output, global, receiver, caller_function, caller_frame);
    var capability = try thenCapability(ctx, output, global, constructor_value, atomicsWaitAsyncPromise(ctx.runtime, object), caller_function, caller_frame);
    var capability_roots = core.runtime.rootValues(.{ &capability.promise, &capability.resolve, &capability.reject, &capability.intrinsic_global });
    capability_roots.activate(ctx.runtime);
    defer capability_roots.deactivate(ctx.runtime);
    const on_fulfilled = if (is_catch) core.JSValue.undefinedValue() else if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const on_rejected = if (is_catch) (if (args.len >= 1) args[0] else core.JSValue.undefinedValue()) else if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
    const stored_on_fulfilled = if (isCallableValue(on_fulfilled)) on_fulfilled else core.JSValue.undefinedValue();
    const stored_on_rejected = if (isCallableValue(on_rejected)) on_rejected else core.JSValue.undefinedValue();
    if (object.promiseResultSlot().* == null) {
        if (!object.promiseIsRejected() and atomicsWaitAsyncPromise(ctx.runtime, object) and isCallableValue(on_fulfilled)) {
            try object.setPromiseReactionCallback(ctx.runtime, on_fulfilled);
            try object.setPromiseReactionArg(ctx.runtime, null);
            // The single reaction callback runs `on_fulfilled` when the
            // waitAsync promise settles; settlePendingPromiseReaction then fires
            // this promise's reaction list with the callback's result. Append a
            // pass-through reaction (undefined handlers) tied to the chained
            // `.then` capability so the returned promise settles with that
            // result — otherwise `waitAsync(...).value.then(a).then(b)` drops the
            // chain after the first reaction (b never runs).
            const chain_reaction = try thenReactionRecord(ctx.runtime, &capability, core.JSValue.undefinedValue(), core.JSValue.undefinedValue());
            try appendPromiseReaction(ctx.runtime, object, chain_reaction);
            if (object.promiseIsRejected()) core.promise.markHandled(ctx, object);
            return capability.promise;
        }
        const reaction = try thenReactionRecord(ctx.runtime, &capability, stored_on_fulfilled, stored_on_rejected);
        try appendPromiseReaction(ctx.runtime, object, reaction);
        if (object.promiseIsRejected()) core.promise.markHandled(ctx, object);
        return capability.promise;
    }
    const result_value = if (object.promiseResult()) |stored| stored else core.JSValue.undefinedValue();

    const reaction = try thenReactionRecord(ctx.runtime, &capability, stored_on_fulfilled, stored_on_rejected);
    const reaction_object = objectFromValue(reaction) orelse return error.TypeError;
    const rejected = object.promiseIsRejected();
    var prepared_job = ctx.runtime.job_queue.preparePromiseReaction(ctx, reaction_object.value(), result_value, rejected);
    var prepared_job_owned = true;
    defer if (prepared_job_owned) prepared_job.deinit();
    try ctx.runtime.job_queue.reserveEntries(1);
    var job_slot_reserved = true;
    defer if (job_slot_reserved) ctx.runtime.job_queue.releaseReservedEntries(1);

    if (rejected) core.promise.markHandled(ctx, object);
    ctx.runtime.job_queue.enqueueReserved(prepared_job);
    prepared_job_owned = false;
    job_slot_reserved = false;
    return capability.promise;
}

pub fn promiseCatchGeneric(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    args: []const core.JSValue,
) !core.JSValue {
    const then_atom = core.atom.ids.then;
    const then_value = try getValueProperty(ctx, output, global, receiver, then_atom, null, null);
    if (!isCallableValue(then_value)) return error.TypeError;
    const on_rejected = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const catch_args = [_]core.JSValue{ core.JSValue.undefinedValue(), on_rejected };
    return callValueOrBytecodeRoot(ctx, output, global, receiver, then_value, &catch_args, null, null);
}

pub fn settlePendingPromiseReaction(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    promise: *core.Object,
) !void {
    const callback = promise.promiseReactionCallback() orelse return;
    var callback_value = callback;
    var arg = if (promise.promiseReactionArg()) |stored| stored else core.JSValue.undefinedValue();
    var root_frame = core.runtime.rootValues(.{ &callback_value, &arg });
    root_frame.activate(ctx.runtime);
    defer root_frame.deactivate(ctx.runtime);

    try promise.setPromiseReactionCallback(ctx.runtime, null);
    try promise.setPromiseReactionArg(ctx.runtime, null);

    const callback_args = [_]core.JSValue{arg};
    const callback_result = callValueOrBytecodeRoot(ctx, output, global, core.JSValue.undefinedValue(), callback_value, &callback_args, null, null) catch |err| {
        const rejected = try rejectedPromiseForRuntimeError(ctx, global, err, promisePrototypeFromGlobal(ctx.runtime, global));
        const rejected_object = objectFromValue(rejected) orelse return error.TypeError;
        const is_rejected = rejected_object.promiseIsRejected();
        const next_result = if (rejected_object.promiseResult()) |stored| stored else core.JSValue.undefinedValue();
        var prepared_reactions = try preparePromiseReactionJobs(ctx, promise, next_result, is_rejected);
        errdefer prepared_reactions.deinit(ctx.runtime);
        promise.promiseIsRejectedSlot().* = is_rejected;
        try promise.setPromiseResult(ctx.runtime, next_result);
        prepared_reactions.commit(ctx, promise);
        return;
    };
    if (promise.promiseResult() != null or promise.promiseReactionCallback() != null) return;
    if (objectFromValue(callback_result)) |result_promise| {
        if (result_promise.class_id == core.class.ids.promise and result_promise.promiseIsRejected()) {
            const next_result = if (result_promise.promiseResult()) |stored| stored else core.JSValue.undefinedValue();
            var prepared_reactions = try preparePromiseReactionJobs(ctx, promise, next_result, true);
            errdefer prepared_reactions.deinit(ctx.runtime);
            try promise.setPromiseResult(ctx.runtime, next_result);
            promise.promiseIsRejectedSlot().* = true;
            prepared_reactions.commit(ctx, promise);
            return;
        }
    }
    var prepared_reactions = try preparePromiseReactionJobs(ctx, promise, callback_result, false);
    errdefer prepared_reactions.deinit(ctx.runtime);
    try promise.setPromiseResult(ctx.runtime, callback_result);
    promise.promiseIsRejectedSlot().* = false;
    prepared_reactions.commit(ctx, promise);
}

test "settlePendingPromiseReaction roots callback and arg after clearing promise slots" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    const ctx = try core.JSContext.create(rt);
    const global = try testStandardGlobal(ctx);
    const promise = try core.Object.create(rt, core.class.ids.promise, null);
    defer {
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
    fb.cpoolSlice()[0] = try rt.takeSymbolValue(callback_symbol);
    fb.publishFixtureNoFail(rt);
    fb_published = true;

    const callback = core.JSValue.functionBytecode(&fb.header);
    const arg_symbol = try rt.atoms.newValueSymbol("gc-promise-reaction-arg-symbol");
    const arg_value = try rt.takeSymbolValue(arg_symbol);
    try promise.setPromiseReactionCallback(rt, callback);
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
    if (!atomicsWaitAsyncPromise(ctx.runtime, promise)) return;

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
    if (reaction.promiseReactionIntrinsicCapability() != null) {
        if (comptime builtin.is_test) ThenCapabilityTestStorage.metrics.intrinsic_retry += 1;
        return true;
    }
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
    var active_job_root: core.runtime.ActiveJobRoot = .{};
    active_job_root.activate(ctx.runtime, &entry);
    defer active_job_root.deactivate(ctx.runtime);
    defer ctx.runtime.clearWeakRefKeptAlive();
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
                    result = callValueOrBytecodeRoot(job_ctx, output, job_global, job_global.value(), job, &.{}, null, null) catch |err| {
                        if (job_ctx.hasException()) return .exception;
                        return err;
                    };
                }
            } else if (isCallableValue(job)) {
                result = callValueOrBytecodeRoot(job_ctx, output, job_global, job_global.value(), job, &.{}, null, null) catch |err| {
                    if (job_ctx.hasException()) return .exception;
                    return err;
                };
            }
        },
        .promise_reaction => |*payload| {
            const unlinked_before = ctx.runtime.job_queue.unlinked_head_slots;
            ctx.runtime.job_queue.reserveUnlinkedEntrySlot();
            result = promiseReactionJobCall(job_ctx, output, job_global, payload, null, null) catch |err| {
                if (err == error.OutOfMemory and promiseReactionInternalSettleCanRetry(payload)) {
                    std.debug.assert(ctx.runtime.job_queue.unlinked_head_slots == unlinked_before + 1);
                    ctx.runtime.job_queue.prependReserved(entry);
                    entry_owned = false;
                    return err;
                }
                ctx.runtime.job_queue.releaseUnlinkedEntrySlot();
                if (job_ctx.hasException()) return .exception;
                return err;
            };
            ctx.runtime.job_queue.releaseUnlinkedEntrySlot();
            std.debug.assert(ctx.runtime.job_queue.unlinked_head_slots == unlinked_before);
        },
        .async_resume => |*payload| {
            asyncResumeJobCall(job_ctx, output, job_global, payload) catch |err| {
                // As in an Await reaction with undefined resolving functions,
                // consume the callback's abrupt completion. The body may have
                // already run; this entry must never replay it after OOM.
                _ = try promiseErrorValue(job_ctx, job_global, err);
            };
        },
        .promise_thenable => |*payload| {
            const unlinked_before = ctx.runtime.job_queue.unlinked_head_slots;
            ctx.runtime.job_queue.reserveUnlinkedEntrySlot();
            result = promiseThenableJobCall(job_ctx, output, job_global, payload, null, null) catch |err| {
                if (err == error.OutOfMemory) {
                    std.debug.assert(ctx.runtime.job_queue.unlinked_head_slots == unlinked_before + 1);
                    ctx.runtime.job_queue.prependReserved(entry);
                    entry_owned = false;
                    return err;
                }
                ctx.runtime.job_queue.releaseUnlinkedEntrySlot();
                if (job_ctx.hasException()) return .exception;
                return err;
            };
            ctx.runtime.job_queue.releaseUnlinkedEntrySlot();
            std.debug.assert(ctx.runtime.job_queue.unlinked_head_slots == unlinked_before);
        },
        .promise_settlement => |*payload| {
            const unlinked_before = ctx.runtime.job_queue.unlinked_head_slots;
            ctx.runtime.job_queue.reserveUnlinkedEntrySlot();
            promiseSettlementJobCall(job_ctx, job_global, payload) catch |err| {
                if (err == error.OutOfMemory) {
                    std.debug.assert(ctx.runtime.job_queue.unlinked_head_slots == unlinked_before + 1);
                    ctx.runtime.job_queue.prependReserved(entry);
                    entry_owned = false;
                    return err;
                }
                ctx.runtime.job_queue.releaseUnlinkedEntrySlot();
                if (job_ctx.hasException()) return .exception;
                return err;
            };
            ctx.runtime.job_queue.releaseUnlinkedEntrySlot();
            std.debug.assert(ctx.runtime.job_queue.unlinked_head_slots == unlinked_before);
        },
        .dynamic_import => |*payload| {
            const unlinked_before = ctx.runtime.job_queue.unlinked_head_slots;
            ctx.runtime.job_queue.reserveUnlinkedEntrySlot();
            result = payload.runner(job_ctx, output, payload) catch |err| {
                if (err == error.OutOfMemory) {
                    std.debug.assert(ctx.runtime.job_queue.unlinked_head_slots == unlinked_before + 1);
                    ctx.runtime.job_queue.prependReserved(entry);
                    entry_owned = false;
                    return error.OutOfMemory;
                }
                ctx.runtime.job_queue.releaseUnlinkedEntrySlot();
                if (job_ctx.hasException()) return .exception;
                return err;
            };
            ctx.runtime.job_queue.releaseUnlinkedEntrySlot();
            std.debug.assert(ctx.runtime.job_queue.unlinked_head_slots == unlinked_before);
        },
        .atomics_waiter => |*payload| {
            const unlinked_before = ctx.runtime.job_queue.unlinked_head_slots;
            ctx.runtime.job_queue.reserveUnlinkedEntrySlot();
            payload.runner(job_ctx, payload) catch |err| {
                std.debug.assert(ctx.runtime.job_queue.unlinked_head_slots == unlinked_before + 1);
                ctx.runtime.job_queue.prependReserved(entry);
                entry_owned = false;
                return err;
            };
            std.debug.assert(ctx.runtime.job_queue.unlinked_head_slots == unlinked_before);
        },
        .finalization => |*payload| {
            result = callValueOrBytecodeRoot(job_ctx, output, job_global, core.JSValue.undefinedValue(), payload.callback, &.{payload.held_value}, null, null) catch |err| {
                if (job_ctx.hasException()) return .exception;
                return err;
            };
        },
    }
    if (result) |value| {
        const status: jobs_mod.RunOneStatus = if (value.isException()) .exception else .success;
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

    const then_key = core.atom.ids.then;
    const then_value = try getValueProperty(ctx, output, global, awaited, then_key, caller_function, caller_frame);
    if (!isCallableValue(then_value)) return null;

    const promise = try core.promise.constructWithPrototype(ctx, promisePrototypeFromGlobal(ctx.runtime, global));
    const promise_object = objectFromValue(promise) orelse return error.TypeError;
    const resolving = try createPromiseResolvingPair(ctx.runtime, global, promise);
    const resolve = resolving.resolve;
    const reject = resolving.reject;

    _ = callValueOrBytecodeRoot(ctx, output, global, awaited, then_value, &.{ resolve, reject }, caller_function, caller_frame) catch |err| {
        var reason = try promiseRejectionReason(ctx, global, err);
        defer reason.deinit(ctx.runtime);
        try promise_object.setPromiseResult(ctx.runtime, reason.value);
        reason.value = core.JSValue.undefinedValue();
        promise_object.promiseIsRejectedSlot().* = true;
        reason.commit(ctx);
        return try finishAwaitedPromise(ctx, promise_object);
    };

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
    const result = if (promise.promiseResult()) |stored| stored else core.JSValue.undefinedValue();
    if (promise.promiseIsRejected()) {
        _ = ctx.throwValue(result);
        return error.JSException;
    }
    return result;
}

pub fn rejectModuleNamespaceSuperSet(ctx: *core.JSContext, receiver: core.JSValue, atom_id: core.Atom) !bool {
    const receiver_object = objectFromValue(receiver) orelse return false;
    if (receiver_object.class_id != core.class.ids.module_ns) return false;
    // OrdinarySetWithOwnDescriptor probes Receiver.[[GetOwnProperty]] before
    // attempting to define on it. For a namespace Receiver that operation
    // reads the live export and must propagate ReferenceError while it is TDZ.
    // Only a successful/absent descriptor reaches the namespace write
    // rejection and becomes TypeError.
    _ = try receiver_object.getOwnProperty(ctx.runtime, atom_id);
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

test "promise reaction carrier uses a dedicated traced payload" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const u = core.JSValue.undefinedValue();
    const value = try promiseReactionRecord(rt, u, u, u, u);
    const record = try core.Object.expect(value);
    try std.testing.expectEqual(core.class.ids.object, record.class_id);
    try std.testing.expectEqual(core.class.PayloadKind.promise_reaction_record, record.flags.class_payload_kind);
    try std.testing.expect(record.ordinaryPayloadForAudit() == null);
    try std.testing.expect(!core.Object.payloadKindNeedsFinalizer(record.class_id, record.flags.class_payload_kind));
    try std.testing.expectEqual(@as(u32, 0), record.shape_ref.prop_count);
}

test "promise reaction carrier barriers cover all four slots" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const u = core.JSValue.undefinedValue();
    var record: ?*core.Object = try core.Object.expect(try promiseReactionRecord(rt, u, u, u, u));
    var roots = core.runtime.rootObjects(.{&record});
    roots.activate(rt);
    defer roots.deactivate(rt);
    _ = try core.gc_trace_stw.collectMinor(rt, null, .declared_only);
    try std.testing.expect(!record.?.gcHeader().metaConst().flags.young);
    inline for (.{
        .{ "setPromiseReactionOnFulfilled", "promiseReactionOnFulfilled" },
        .{ "setPromiseReactionOnRejected", "promiseReactionOnRejected" },
        .{ "setPromiseReactionResolve", "promiseReactionResolve" },
        .{ "setPromiseReactionReject", "promiseReactionReject" },
    }) |accessors| {
        const child = try core.Object.create(rt, core.class.ids.object, null);
        try std.testing.expect(child.gcHeader().metaConst().flags.young);
        try @field(core.Object, accessors[0])(record.?, rt, child.value());
        try std.testing.expect(rt.gc.generation.remembered.contains(@intFromPtr(record.?.gcHeader())));
        _ = try core.gc_trace_stw.collectMinor(rt, null, .declared_only);
        try std.testing.expect(rt.ownsObject(child));
        try std.testing.expect(@field(core.Object, accessors[1])(record.?).?.same(child.value()));
        const removed = try core.Object.create(rt, core.class.ids.object, null);
        try @field(core.Object, accessors[0])(record.?, rt, removed.value());
        try @field(core.Object, accessors[0])(record.?, rt, null);
        _ = try core.gc_trace_stw.collectMinor(rt, null, .declared_only);
        try std.testing.expect(!rt.ownsObject(removed));
    }
}

test "promise reaction carrier promotion preserves values across OOM and GC" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    var values: [4]core.JSValue = undefined;
    var symbols: [4]core.Atom = undefined;
    for (&values, &symbols) |*value, *symbol| {
        symbol.* = try rt.atoms.newValueSymbol("reaction-promotion");
        value.* = try rt.takeSymbolValue(symbol.*);
    }
    var record: ?*core.Object = try core.Object.expect(try promiseReactionRecord(rt, values[0], values[1], values[2], values[3]));
    var roots = core.runtime.rootObjects(.{&record});
    roots.activate(rt);
    defer roots.deactivate(rt);
    values = @splat(core.JSValue.undefinedValue());
    _ = rt.runObjectCycleRemoval();
    rt.setMemoryLimit(0);
    defer rt.setMemoryLimit(null);
    try std.testing.expectError(error.OutOfMemory, record.?.ensureOrdinaryPayload(rt));
    try std.testing.expectEqual(core.class.PayloadKind.promise_reaction_record, record.?.flags.class_payload_kind);
    rt.setMemoryLimit(null);
    rt.setGCThreshold(0);
    (try record.?.promiseAlreadyResolvedSlot(rt)).* = true;
    try std.testing.expect(record.?.promiseAlreadyResolved());
    try std.testing.expectEqual(core.class.PayloadKind.ordinary, record.?.flags.class_payload_kind);
    _ = rt.runObjectCycleRemoval();
    const getters = .{ "promiseReactionOnFulfilled", "promiseReactionOnRejected", "promiseReactionResolve", "promiseReactionReject" };
    inline for (getters, 0..) |getter, i| {
        try std.testing.expect(rt.atoms.name(symbols[i]) != null);
        try std.testing.expectEqual(symbols[i], @field(core.Object, getter)(record.?).?.asSymbolAtom().?);
    }
    record = null;
    _ = rt.runObjectCycleRemoval();
    for (symbols) |symbol| try std.testing.expect(rt.atoms.name(symbol) == null);
}

test "promise reaction carrier allocation failure preserves input roots" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    var input: ?*core.Object = try core.Object.create(rt, core.class.ids.object, null);
    var record: ?*core.Object = null;
    var roots = core.runtime.rootObjects(.{ &input, &record });
    roots.activate(rt);
    defer roots.deactivate(rt);
    rt.setMemoryLimit(0);
    defer rt.setMemoryLimit(null);
    try std.testing.expectError(error.OutOfMemory, promiseReactionRecord(rt, input.?.value(), input.?.value(), input.?.value(), input.?.value()));
    rt.setMemoryLimit(null);
    rt.setGCThreshold(0);
    record = try core.Object.expect(try promiseReactionRecord(rt, input.?.value(), input.?.value(), input.?.value(), input.?.value()));
    const child = input.?;
    input = null;
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.ownsObject(child));
    try std.testing.expect(record.?.promiseReactionReject().?.same(child.value()));
    record = null;
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(!rt.ownsObject(child));
}

test "P-Cap target and error realm edges survive remembered and declared-only tracing" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    var record: ?*core.Object = try core.Object.createPromiseReactionRecord(rt);
    var roots = core.runtime.rootObjects(.{&record});
    roots.activate(rt);
    defer roots.deactivate(rt);
    _ = try core.gc_trace_stw.collectMinor(rt, null, .declared_only);
    try std.testing.expect(!record.?.gcHeader().metaConst().flags.young);

    const target = try core.Object.create(rt, core.class.ids.promise, null);
    const error_global = try core.Object.create(rt, core.class.ids.global_object, null);
    try std.testing.expect(target.gcHeader().metaConst().flags.young);
    record.?.setPromiseReactionIntrinsicCapability(rt, target.value(), error_global.value());
    try std.testing.expect(rt.gc.generation.remembered.contains(@intFromPtr(record.?.gcHeader())));
    _ = try core.gc_trace_stw.collectMinor(rt, null, .declared_only);
    try std.testing.expect(rt.ownsObject(target));
    try std.testing.expect(rt.ownsObject(error_global));
    _ = try rt.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only);
    try std.testing.expect(record.?.promiseReactionIntrinsicCapability().?.target.sameValue(target.value()));
    try std.testing.expect(record.?.promiseReactionIntrinsicCapability().?.self_error_global.sameValue(error_global.value()));

    _ = try record.?.ensureOrdinaryPayload(rt);
    _ = try rt.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only);
    try std.testing.expect(rt.ownsObject(target));
    try std.testing.expect(rt.ownsObject(error_global));
    try std.testing.expect(record.?.promiseReactionIntrinsicCapability().?.target.sameValue(target.value()));
    record.?.clearPromiseReactionIntrinsicCapability();
    _ = try rt.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only);
    try std.testing.expect(!rt.ownsObject(target));
    try std.testing.expect(!rt.ownsObject(error_global));
}

test "P-Cap intrinsic construction OOM leaves no published reaction" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    const global = try testStandardGlobal(ctx);
    const constructor = try promiseDefaultConstructor(ctx, global);
    var source = try core.promise.constructWithPrototype(ctx, promisePrototypeFromGlobal(rt, global));
    var roots = core.runtime.rootValues(.{&source});
    roots.activate(rt);
    defer roots.deactivate(rt);
    rt.suppressLimitCollectionForTest(true);
    defer rt.suppressLimitCollectionForTest(false);
    rt.setMemoryLimit(0);
    defer rt.setMemoryLimit(null);
    resetThenCapabilityTestMetrics();
    try std.testing.expectError(error.OutOfMemory, thenCapability(ctx, null, global, constructor, false, null, null));
    try std.testing.expectEqual(@as(usize, 1), thenCapabilityTestMetrics().intrinsic_prepare);
    try std.testing.expectEqual(@as(usize, 0), thenCapabilityTestMetrics().intrinsic);
    try std.testing.expectEqual(@as(usize, 0), thenCapabilityTestMetrics().fallback);
    try std.testing.expectEqual(@as(usize, 0), objectFromValue(source).?.promiseReactions().len);
    try std.testing.expectEqual(@as(usize, 0), rt.job_queue.jobs.len);
}

test "fulfilled await uses only its reserved FIFO slot" {
    for (0..3) |kind| {
        const rt = try core.JSRuntime.create(std.testing.allocator);
        defer rt.destroy();
        const ctx = try core.JSContext.create(rt);
        defer ctx.destroy();
        const global = try testStandardGlobal(ctx);
        var continuation = (try core.Object.create(rt, core.class.ids.object, null)).value();
        var value = core.JSValue.undefinedValue();
        var awaited = core.JSValue.undefinedValue();
        var roots = core.runtime.rootValues(.{ &continuation, &value, &awaited });
        roots.activate(rt);
        defer roots.deactivate(rt);
        value = switch (kind) {
            0 => core.JSValue.int32(42),
            1 => try rt.takeSymbolValue(try rt.atoms.newValueSymbol("direct-await-value")),
            else => (try core.Object.create(rt, core.class.ids.object, null)).value(),
        };
        awaited = try core.promise.fulfilledWithPrototype(ctx, value, promisePrototypeFromGlobal(rt, global));
        _ = try promiseDefaultConstructor(ctx, global);
        try rt.job_queue.reserveEntries(1);
        rt.job_queue.releaseReservedEntries(1);
        const before = rt.memory.allocated_bytes;
        rt.suppressLimitCollectionForTest(true);
        defer rt.suppressLimitCollectionForTest(false);
        rt.setMemoryLimit(before);
        defer rt.setMemoryLimit(null);
        try asyncFunctionAwait(ctx, null, global, try core.Object.expect(continuation), awaited, null, null);
        try std.testing.expectEqual(before, rt.memory.allocated_bytes);
        try std.testing.expectEqual(@as(usize, 1), rt.job_queue.jobs.len);
        try std.testing.expectEqual(@as(usize, 0), rt.job_queue.reserved_entries);
        const job = &rt.job_queue.jobs[0];
        try std.testing.expectEqual(jobs_mod.Kind.async_resume, std.meta.activeTag(job.payload));
        try std.testing.expect(job.payload.async_resume.continuation.sameValue(continuation));
        try std.testing.expect(job.payload.async_resume.value.sameValue(value));
        try std.testing.expectEqual(ctx, job.realm.borrow().?);
    }
}

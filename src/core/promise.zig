//! Promise engine-core construction primitives.
//!
//! QuickJS keeps Promise object creation, fulfillment/rejection, the legacy
//! Promise.* static helpers, and unhandled-rejection bookkeeping inside the
//! engine core (js_promise_*), not in a builtins-only layer. These functions
//! are pure engine primitives: they depend only on `core.Object`,
//! `core.runtime` rooting, `core.function` (the lazy `then`/`catch` install +
//! native-function factory), and the core job queue. They have zero exec/
//! builtins dependency, so they live in core and are consumed directly by the
//! VM (exec/promise_ops.zig and friends).

const core = @import("root.zig");
const jobs = @import("jobs.zig");
const std = @import("std");

/// QuickJS source map: narrow Promise constructor payload used by transitional
/// `new_promise` bytecode.
pub fn construct(realm: *core.RealmContext) !core.JSValue {
    return constructWithPrototype(realm, null);
}

pub fn constructWithPrototype(realm: *core.RealmContext, prototype: ?*core.Object) !core.JSValue {
    const rt = realm.runtime;
    const object = try core.Object.create(rt, core.class.ids.promise, prototype);
    errdefer core.Object.destroyFromHeader(rt, object.gcHeader());
    if (prototype == null) {
        try core.function.defineNativeMethod(realm, object, "then", 2);
        try core.function.defineNativeMethod(realm, object, "catch", 1);
    }
    return object.value();
}

pub fn fulfilledWithPrototype(realm: *core.RealmContext, value: core.JSValue, prototype: ?*core.Object) !core.JSValue {
    const rt = realm.runtime;
    var rooted_value = value;
    var root_frame = core.runtime.rootValues(.{&rooted_value});
    root_frame.activate(rt);
    defer root_frame.deactivate(rt);

    const promise = try constructWithPrototype(realm, prototype);
    const object = promiseObject(promise) orelse return error.TypeError;
    try object.setPromiseResult(rt, rooted_value);
    return promise;
}

pub fn rejectedWithPrototype(realm: *core.RealmContext, reason: core.JSValue, prototype: ?*core.Object) !core.JSValue {
    const rt = realm.runtime;
    var rooted_reason = reason;
    var root_frame = core.runtime.rootValues(.{&rooted_reason});
    root_frame.activate(rt);
    defer root_frame.deactivate(rt);

    const promise = try constructWithPrototype(realm, prototype);
    const object = promiseObject(promise) orelse return error.TypeError;
    try object.setPromiseResult(rt, rooted_reason);
    object.promiseIsRejectedSlot().* = true;
    return promise;
}

test "fulfilledWithPrototype roots direct function bytecode result while constructing promise" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const realm = try core.RealmContext.create(rt);
    defer realm.destroy();
    const function_proto = try core.Object.create(rt, core.class.ids.object, null);
    realm.cached_function_proto = function_proto;

    const fb = try core.FunctionBytecode.createFixture(rt, .{ .cpool_count = 1 });
    var fb_published = false;
    errdefer if (!fb_published) fb.destroyUnpublishedFixture(rt);
    const symbol_atom = try rt.atoms.newValueSymbol("gc-promise-fulfilled-bytecode-symbol");
    fb.cpoolSlice()[0] = try rt.takeSymbolValue(symbol_atom);
    fb.publishFixtureNoFail(rt);
    fb_published = true;

    const result_value = core.JSValue.functionBytecode(&fb.header);

    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    errdefer rt.setGCThreshold(old_threshold);

    const promise_value = try fulfilledWithPrototype(realm, result_value, null);
    const promise = promiseObject(promise_value) orelse return error.TypeError;

    const then_value = try promise.getProperty(core.atom.predefinedId("then", .string).?);
    const then_function = try core.Object.expect(then_value);
    try std.testing.expectEqual(core.class.ids.c_function_data, then_function.class_id);
    try std.testing.expectEqual(function_proto, then_function.getPrototype().?);

    const catch_value = try promise.getProperty(core.atom.predefinedId("catch", .string).?);
    const catch_function = try core.Object.expect(catch_value);
    try std.testing.expectEqual(core.class.ids.c_function_data, catch_function.class_id);
    try std.testing.expectEqual(function_proto, catch_function.getPrototype().?);

    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    const stored = promise.promiseResult() orelse return error.TypeError;
    try std.testing.expect(stored.same(result_value));

    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

fn promiseObject(value: core.JSValue) ?*core.Object {
    const header = value.refHeader() orelse return null;
    const object = core.Object.fromHeader(header);
    if (object.class_id != core.class.ids.promise) return null;
    return object;
}

pub fn rejectedWithUnhandledPrototype(ctx: *core.JSContext, reason: core.JSValue, prototype: ?*core.Object) !core.JSValue {
    const promise = try rejectedWithPrototype(ctx, reason, prototype);
    ctx.recordUnhandledPromiseRejection(promise, reason);
    return promise;
}

/// Mirrors qjs perform_promise_then on an already-rejected unhandled promise
/// (quickjs.c:54224-54229, tracker fired with is_handled=TRUE →
/// js_std_promise_rejection_tracker quickjs-libc.c:4259-4268): unreport THIS
/// promise only. Handling one promise must not suppress the report of a
/// different promise, even one rejected with a sameValue reason.
pub fn markHandled(ctx: *core.JSContext, promise: *core.Object) void {
    if (!promise.promiseIsRejected()) return;
    const reason = promise.promiseResult() orelse return;
    ctx.removeUnhandledPromiseRejection(promise.value());
    if (!ctx.hasException()) return;
    if (ctx.runtime.current_exception.sameValue(reason)) {
        ctx.clearException();
    }
}

pub fn withResolvers(ctx: *core.JSContext, prototype: ?*core.Object) !core.JSValue {
    const rt = ctx.runtime;
    var promise_val = core.JSValue.undefinedValue();
    var resolve_val = core.JSValue.undefinedValue();
    var reject_val = core.JSValue.undefinedValue();
    var result_val = core.JSValue.undefinedValue();
    var root_frame = core.runtime.rootValues(.{
        &promise_val,
        &resolve_val,
        &reject_val,
        &result_val,
    });
    root_frame.activate(rt);
    defer root_frame.deactivate(rt);

    promise_val = try constructWithPrototype(ctx, prototype);
    resolve_val = try createResolvingFunction(ctx, promise_val, false);
    reject_val = try createResolvingFunction(ctx, promise_val, true);

    const result = try core.Object.create(rt, core.class.ids.object, null);
    result_val = result.value();
    try defineData(rt, result, core.atom.ids.promise, promise_val);
    try defineData(rt, result, core.atom.ids.resolve, resolve_val);
    try defineData(rt, result, core.atom.ids.reject, reject_val);
    return result_val;
}

fn createResolvingFunction(ctx: *core.JSContext, promise: core.JSValue, reject: bool) !core.JSValue {
    const rt = ctx.runtime;
    const function_proto = ctx.cached_function_proto orelse return error.InvalidBuiltinRegistry;
    var rooted_promise = promise;
    var function_val = core.JSValue.undefinedValue();
    var state_val = core.JSValue.undefinedValue();
    var root_frame = core.runtime.rootValues(.{ &rooted_promise, &function_val, &state_val });
    root_frame.activate(rt);
    defer root_frame.deactivate(rt);

    function_val = try core.function.nativeDataFunctionWithPrototype(rt, function_proto, "", 1);
    const header = function_val.refHeader() orelse return error.TypeError;
    const object = core.Object.fromHeader(header);
    const state = try core.Object.create(rt, core.class.ids.object, null);
    state_val = state.value();
    (try state.promiseAlreadyResolvedSlot(rt)).* = false;
    try object.setInternalCallableTag(rt, .promise_resolving);
    try object.setFunctionPromiseResolvingTarget(rt, rooted_promise);
    try object.setFunctionPromiseResolvingState(rt, state_val);
    (try object.functionPromiseResolvingRejectSlot(rt)).* = reject;
    return function_val;
}

test "createResolvingFunction roots promise and state while allocating slots" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    const function_proto = try core.Object.create(rt, core.class.ids.object, null);
    ctx.cached_function_proto = function_proto;

    const promise_symbol = try rt.atoms.newValueSymbol("gc-promise-resolving-target-symbol");
    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const promise_value = try rt.takeSymbolValue(promise_symbol);
    const function_value = try createResolvingFunction(ctx, promise_value, false);
    const function_object = core.Object.fromHeader(function_value.refHeader() orelse return error.TypeError);

    try std.testing.expect(rt.atoms.name(promise_symbol) != null);
    const stored_target = function_object.functionPromiseResolvingTarget() orelse return error.TypeError;
    try std.testing.expect(stored_target.same(promise_value));
    const stored_state = function_object.functionPromiseResolvingState() orelse return error.TypeError;
    const state_object = core.Object.fromHeader(stored_state.refHeader() orelse return error.TypeError);
    try std.testing.expect(!state_object.promiseAlreadyResolved(rt));

    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(promise_symbol) == null);
}

test "withResolvers roots promise and resolving functions while creating result" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    const function_proto = try core.Object.create(rt, core.class.ids.object, null);
    ctx.cached_function_proto = function_proto;

    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const result_value = try withResolvers(ctx, null);
    const result = core.Object.fromHeader(result_value.refHeader() orelse return error.TypeError);

    const promise_key = try rt.internAtom("promise");
    defer rt.atoms.free(promise_key);
    const resolve_key = try rt.internAtom("resolve");
    defer rt.atoms.free(resolve_key);
    const reject_key = try rt.internAtom("reject");
    defer rt.atoms.free(reject_key);

    const promise_value = try result.getProperty(promise_key);
    const resolve_value = try result.getProperty(resolve_key);
    const reject_value = try result.getProperty(reject_key);

    try std.testing.expect(promiseObject(promise_value) != null);
    const resolve_object = core.Object.fromHeader(resolve_value.refHeader() orelse return error.TypeError);
    const reject_object = core.Object.fromHeader(reject_value.refHeader() orelse return error.TypeError);
    try std.testing.expect(resolve_object.functionPromiseResolvingTarget().?.same(promise_value));
    try std.testing.expect(reject_object.functionPromiseResolvingTarget().?.same(promise_value));
    try std.testing.expect(!resolve_object.functionPromiseResolvingReject());
    try std.testing.expect(reject_object.functionPromiseResolvingReject());

    _ = rt.runObjectCycleRemoval();
}

fn defineData(rt: *core.JSRuntime, object: *core.Object, atom_id: core.Atom, value: core.JSValue) !void {
    try object.defineOwnProperty(rt, atom_id, core.Descriptor.data(value, true, true, true));
}

pub fn enqueueReaction(ctx: *core.JSContext, job: jobs.Func, args: []const core.JSValue) !void {
    try ctx.runtime.job_queue.enqueueFunc(ctx, job, args);
}

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
        const then_value = try core.function.defineNativeMethod(realm, object, "then", 2);
        const then_fn = try core.Object.expect(then_value);
        then_fn.nativeFunctionIdSlot().* = core.function.nativeBuiltinId(
            .promise,
            @intFromEnum(core.host_function.builtin_method_ids.promise.PrototypeMethod.then),
        );
        const catch_value = try core.function.defineNativeMethod(realm, object, "catch", 1);
        const catch_fn = try core.Object.expect(catch_value);
        catch_fn.nativeFunctionIdSlot().* = core.function.nativeBuiltinId(
            .promise,
            @intFromEnum(core.host_function.builtin_method_ids.promise.PrototypeMethod.catch_),
        );
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
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const realm = try core.RealmContext.create(rt, .{});
    defer realm.destroy();
    const function_proto = try core.Object.create(rt, core.class.ids.object, null);
    realm.cached_function_proto = function_proto;

    const symbol_atom = try rt.atoms.newValueSymbol("gc-promise-fulfilled-bytecode-symbol");
    const fb = try core.FunctionBytecode.createPublishedFixture(rt, .{ .cpool_count = 1 }, &.{try rt.takeSymbolValue(symbol_atom)});

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
    try std.testing.expectEqual(
        core.function.nativeBuiltinId(
            .promise,
            @intFromEnum(core.host_function.builtin_method_ids.promise.PrototypeMethod.then),
        ),
        then_function.nativeFunctionId(),
    );
    try std.testing.expect(then_function.nativeEntry() == null);

    const catch_value = try promise.getProperty(core.atom.predefinedId("catch", .string).?);
    const catch_function = try core.Object.expect(catch_value);
    try std.testing.expectEqual(core.class.ids.c_function_data, catch_function.class_id);
    try std.testing.expectEqual(function_proto, catch_function.getPrototype().?);
    try std.testing.expectEqual(
        core.function.nativeBuiltinId(
            .promise,
            @intFromEnum(core.host_function.builtin_method_ids.promise.PrototypeMethod.catch_),
        ),
        catch_function.nativeFunctionId(),
    );
    try std.testing.expect(catch_function.nativeEntry() == null);

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
/// (quickjs.c, tracker fired with is_handled=TRUE →
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

pub fn enqueueReaction(ctx: *core.JSContext, job: jobs.Func, args: []const core.JSValue) !void {
    try ctx.runtime.job_queue.enqueueFunc(ctx, job, args);
}

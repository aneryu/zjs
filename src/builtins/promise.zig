const core = @import("../core/root.zig");
const function_builtin = @import("function.zig");
const jobs = @import("../core/jobs.zig");
const std = @import("std");

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
    return null;
}

/// QuickJS source map: narrow Promise constructor payload used by transitional
/// `new_promise` bytecode.
pub fn construct(rt: *core.JSRuntime) !core.JSValue {
    return constructWithPrototype(rt, null);
}

pub fn constructWithPrototype(rt: *core.JSRuntime, prototype: ?*core.Object) !core.JSValue {
    const object = try core.Object.create(rt, core.class.ids.promise, prototype);
    errdefer core.Object.destroyFromHeader(rt, &object.header);
    if (prototype == null) {
        try function_builtin.defineNativeMethod(rt, object, "then", 2);
        try function_builtin.defineNativeMethod(rt, object, "catch", 1);
    }
    return object.value();
}

pub fn fulfilledWithPrototype(rt: *core.JSRuntime, value: core.JSValue, prototype: ?*core.Object) !core.JSValue {
    var rooted_value = value;
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &rooted_value },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    const promise = try constructWithPrototype(rt, prototype);
    const object = promiseObject(promise) orelse return error.TypeError;
    try object.setPromiseResult(rt, rooted_value.dup());
    return promise;
}

pub fn rejectedWithPrototype(rt: *core.JSRuntime, reason: core.JSValue, prototype: ?*core.Object) !core.JSValue {
    var rooted_reason = reason;
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &rooted_reason },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    const promise = try constructWithPrototype(rt, prototype);
    const object = promiseObject(promise) orelse return error.TypeError;
    try object.setPromiseResult(rt, rooted_reason.dup());
    object.promiseIsRejectedSlot().* = true;
    return promise;
}

test "fulfilledWithPrototype roots direct function bytecode result while constructing promise" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const fb_slice = try rt.memory.alloc(core.FunctionBytecode, 1);
    const fb = &fb_slice[0];
    fb.* = core.FunctionBytecode.init(&rt.memory, &rt.atoms, core.atom.ids.empty_string);
    try rt.gc.add(&fb.header);

    const symbol_atom = try rt.atoms.newValueSymbol("gc-promise-fulfilled-bytecode-symbol");
    fb.cpool = try rt.memory.alloc(core.JSValue, 1);
    fb.cpool[0] = core.JSValue.symbol(symbol_atom);
    fb.cpool_count = 1;

    var result_value = core.JSValue.functionBytecode(&fb.header);
    var result_alive = true;
    defer if (result_alive) result_value.free(rt);

    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    errdefer rt.setGCThreshold(old_threshold);

    const promise_value = try fulfilledWithPrototype(rt, result_value, null);
    var promise_alive = true;
    defer if (promise_alive) promise_value.free(rt);
    const promise = promiseObject(promise_value) orelse return error.TypeError;

    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    const stored = promise.promiseResult() orelse return error.TypeError;
    try std.testing.expect(stored.same(result_value));

    promise_value.free(rt);
    promise_alive = false;
    result_value.free(rt);
    result_alive = false;
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

fn promiseObject(value: core.JSValue) ?*core.Object {
    const header = value.refHeader() orelse return null;
    const object: *core.Object = @fieldParentPtr("header", header);
    if (object.class_id != core.class.ids.promise) return null;
    return object;
}

/// QuickJS source map: selected Promise static helpers used by current smoke
/// coverage. This intentionally preserves the existing narrow behavior:
/// resolve/all/race ignore arguments, reject records an unhandled reason, and
/// every supported mode returns a Promise object.
pub fn staticCall(ctx: *core.JSContext, mode: u32, payload: ?core.JSValue) !core.JSValue {
    return staticCallWithPrototype(ctx, mode, payload, null, null);
}

pub fn staticCallWithPrototype(
    ctx: *core.JSContext,
    mode: u32,
    payload: ?core.JSValue,
    prototype: ?*core.Object,
    global: ?*core.Object,
) !core.JSValue {
    switch (mode) {
        @intFromEnum(LegacyStaticMethod.resolve) => {
            const value = payload orelse core.JSValue.undefinedValue();
            if (promiseObject(value)) |promise| {
                if (prototype == null or promise.getPrototype() == prototype) {
                    return value.dup();
                }
            }
            return fulfilledWithPrototype(ctx.runtime, value, prototype);
        },
        @intFromEnum(LegacyStaticMethod.all) => if (payload) |iterable| return promiseAll(ctx, iterable, prototype),
        @intFromEnum(LegacyStaticMethod.race) => if (payload) |iterable| return promiseRace(ctx, iterable, prototype),
        @intFromEnum(LegacyStaticMethod.reject) => {
            const value = payload orelse return error.TypeError;
            return rejectedWithUnhandledPrototype(ctx, value, prototype);
        },
        @intFromEnum(LegacyStaticMethod.all_settled) => if (payload) |iterable| return promiseAllSettled(ctx, iterable, prototype),
        @intFromEnum(LegacyStaticMethod.any) => if (payload) |iterable| return promiseAny(ctx, iterable, prototype, global),
        @intFromEnum(LegacyStaticMethod.with_resolvers) => return withResolvers(ctx.runtime, prototype),
        else => return error.TypeError,
    }
    return constructWithPrototype(ctx.runtime, prototype);
}

pub fn rejectedWithUnhandledPrototype(ctx: *core.JSContext, reason: core.JSValue, prototype: ?*core.Object) !core.JSValue {
    const promise = try rejectedWithPrototype(ctx.runtime, reason, prototype);
    ctx.recordUnhandledPromiseRejection(promise, reason);
    return promise;
}

pub fn markHandled(ctx: *core.JSContext, promise: *core.Object) void {
    if (!promise.promiseIsRejected()) return;
    const reason = promise.promiseResult() orelse return;
    const pending_exception_is_unhandled =
        ctx.exception_slot.hasException() and
        ctx.unhandled_rejection_slot.hasException() and
        ctx.exception_slot.value.sameValue(ctx.unhandled_rejection_slot.value);
    const matches_unhandled_promise =
        ctx.unhandled_rejection_promise_slot.hasException() and
        ctx.unhandled_rejection_promise_slot.value.same(promise.value());
    const matches_unhandled_reason =
        ctx.unhandled_rejection_slot.hasException() and
        ctx.unhandled_rejection_slot.value.sameValue(reason);

    if (matches_unhandled_promise or matches_unhandled_reason) {
        ctx.clearUnhandledRejection();
        if (pending_exception_is_unhandled) {
            ctx.clearException();
            return;
        }
    }
    if (!ctx.exception_slot.hasException()) return;
    if (ctx.exception_slot.value.sameValue(reason)) {
        ctx.clearException();
    }
}

pub fn withResolvers(rt: *core.JSRuntime, prototype: ?*core.Object) !core.JSValue {
    var promise_val = core.JSValue.undefinedValue();
    var resolve_val = core.JSValue.undefinedValue();
    var reject_val = core.JSValue.undefinedValue();
    var result_val = core.JSValue.undefinedValue();
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &promise_val },
        .{ .value = &resolve_val },
        .{ .value = &reject_val },
        .{ .value = &result_val },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    defer promise_val.free(rt);
    defer resolve_val.free(rt);
    defer reject_val.free(rt);

    promise_val = try constructWithPrototype(rt, prototype);
    resolve_val = try createResolvingFunction(rt, promise_val, false);
    reject_val = try createResolvingFunction(rt, promise_val, true);

    const result = try core.Object.create(rt, core.class.ids.object, null);
    result_val = result.value();
    errdefer result_val.free(rt);
    try defineData(rt, result, "promise", promise_val);
    try defineData(rt, result, "resolve", resolve_val);
    try defineData(rt, result, "reject", reject_val);
    return result_val;
}

fn createResolvingFunction(rt: *core.JSRuntime, promise: core.JSValue, reject: bool) !core.JSValue {
    var rooted_promise = promise;
    var function_val = core.JSValue.undefinedValue();
    var state_val = core.JSValue.undefinedValue();
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &rooted_promise },
        .{ .value = &function_val },
        .{ .value = &state_val },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    function_val = try function_builtin.nativeFunction(rt, "", 1);
    errdefer function_val.free(rt);
    const header = function_val.refHeader() orelse return error.TypeError;
    const object: *core.Object = @fieldParentPtr("header", header);
    const state = try core.Object.create(rt, core.class.ids.object, null);
    state_val = state.value();
    defer state_val.free(rt);
    (try state.promiseAlreadyResolvedSlot(rt)).* = false;
    try object.setFunctionPromiseResolvingTarget(rt, rooted_promise.dup());
    try object.setFunctionPromiseResolvingState(rt, state_val.dup());
    object.functionPromiseResolvingRejectSlot().* = reject;
    return function_val;
}

test "createResolvingFunction roots promise and state while allocating slots" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const promise_symbol = try rt.atoms.newValueSymbol("gc-promise-resolving-target-symbol");
    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const function_value = try createResolvingFunction(rt, core.JSValue.symbol(promise_symbol), false);
    var function_alive = true;
    defer if (function_alive) function_value.free(rt);
    const function_object: *core.Object = @fieldParentPtr("header", function_value.refHeader() orelse return error.TypeError);

    try std.testing.expect(rt.atoms.name(promise_symbol) != null);
    const stored_target = function_object.functionPromiseResolvingTarget() orelse return error.TypeError;
    try std.testing.expect(stored_target.same(core.JSValue.symbol(promise_symbol)));
    const stored_state = function_object.functionPromiseResolvingState() orelse return error.TypeError;
    const state_object: *core.Object = @fieldParentPtr("header", stored_state.refHeader() orelse return error.TypeError);
    try std.testing.expect(!state_object.promiseAlreadyResolved());

    function_value.free(rt);
    function_alive = false;
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(promise_symbol) == null);
}

test "withResolvers roots promise and resolving functions while creating result" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const result_value = try withResolvers(rt, null);
    var result_alive = true;
    defer if (result_alive) result_value.free(rt);
    const result: *core.Object = @fieldParentPtr("header", result_value.refHeader() orelse return error.TypeError);

    const promise_key = try rt.internAtom("promise");
    defer rt.atoms.free(promise_key);
    const resolve_key = try rt.internAtom("resolve");
    defer rt.atoms.free(resolve_key);
    const reject_key = try rt.internAtom("reject");
    defer rt.atoms.free(reject_key);

    const promise_value = result.getProperty(promise_key);
    defer promise_value.free(rt);
    const resolve_value = result.getProperty(resolve_key);
    defer resolve_value.free(rt);
    const reject_value = result.getProperty(reject_key);
    defer reject_value.free(rt);

    try std.testing.expect(promiseObject(promise_value) != null);
    const resolve_object: *core.Object = @fieldParentPtr("header", resolve_value.refHeader() orelse return error.TypeError);
    const reject_object: *core.Object = @fieldParentPtr("header", reject_value.refHeader() orelse return error.TypeError);
    try std.testing.expect(resolve_object.functionPromiseResolvingTarget().?.same(promise_value));
    try std.testing.expect(reject_object.functionPromiseResolvingTarget().?.same(promise_value));
    try std.testing.expect(!resolve_object.functionPromiseResolvingRejectSlot().*);
    try std.testing.expect(reject_object.functionPromiseResolvingRejectSlot().*);

    result_value.free(rt);
    result_alive = false;
    _ = rt.runObjectCycleRemoval();
}

fn promiseAll(ctx: *core.JSContext, iterable: core.JSValue, prototype: ?*core.Object) !core.JSValue {
    const rt = ctx.runtime;
    const source = arrayObject(iterable) orelse return rejectedWithUnhandledPrototype(ctx, core.JSValue.undefinedValue(), prototype);

    var out_val = core.JSValue.undefinedValue();
    var item_val = core.JSValue.undefinedValue();
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &out_val },
        .{ .value = &item_val },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    defer out_val.free(rt);
    defer item_val.free(rt);

    const out = try core.Object.createArray(rt, null);
    out_val = out.value();

    var index: u32 = 0;
    while (index < source.length) : (index += 1) {
        item_val = source.getProperty(core.atom.atomFromUInt32(index));
        defer {
            item_val.free(rt);
            item_val = core.JSValue.undefinedValue();
        }
        const settled = promiseObject(item_val);
        if (settled) |promise| {
            if (promise.promiseIsRejected()) {
                markHandled(ctx, promise);
                const reason = if (promise.promiseResult()) |stored| stored.dup() else core.JSValue.undefinedValue();
                defer reason.free(rt);
                return rejectedWithUnhandledPrototype(ctx, reason, prototype);
            }
            const value = if (promise.promiseResult()) |stored| stored.dup() else core.JSValue.undefinedValue();
            defer value.free(rt);
            try out.defineOwnProperty(rt, core.atom.atomFromUInt32(index), core.Descriptor.data(value, true, true, true));
        } else {
            try out.defineOwnProperty(rt, core.atom.atomFromUInt32(index), core.Descriptor.data(item_val, true, true, true));
        }
    }
    out.length = source.length;
    return fulfilledWithPrototype(rt, out_val, prototype);
}

fn promiseRace(ctx: *core.JSContext, iterable: core.JSValue, prototype: ?*core.Object) !core.JSValue {
    const rt = ctx.runtime;
    const source = arrayObject(iterable) orelse return rejectedWithUnhandledPrototype(ctx, core.JSValue.undefinedValue(), prototype);
    if (source.length == 0) return constructWithPrototype(rt, prototype);
    const item = source.getProperty(core.atom.atomFromUInt32(0));
    defer item.free(rt);
    if (promiseObject(item)) |promise| {
        const value = if (promise.promiseResult()) |stored| stored.dup() else core.JSValue.undefinedValue();
        defer value.free(rt);
        if (promise.promiseIsRejected()) {
            markHandled(ctx, promise);
            return rejectedWithUnhandledPrototype(ctx, value, prototype);
        }
        return fulfilledWithPrototype(rt, value, prototype);
    }
    return fulfilledWithPrototype(rt, item, prototype);
}

fn promiseAllSettled(ctx: *core.JSContext, iterable: core.JSValue, prototype: ?*core.Object) !core.JSValue {
    const rt = ctx.runtime;
    const source = arrayObject(iterable) orelse return rejectedWithUnhandledPrototype(ctx, core.JSValue.undefinedValue(), prototype);

    var out_val = core.JSValue.undefinedValue();
    var item_val = core.JSValue.undefinedValue();
    var record_val = core.JSValue.undefinedValue();
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &out_val },
        .{ .value = &item_val },
        .{ .value = &record_val },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    defer out_val.free(rt);
    defer item_val.free(rt);
    defer record_val.free(rt);

    const out = try core.Object.createArray(rt, null);
    out_val = out.value();

    var index: u32 = 0;
    while (index < source.length) : (index += 1) {
        item_val = source.getProperty(core.atom.atomFromUInt32(index));
        defer {
            item_val.free(rt);
            item_val = core.JSValue.undefinedValue();
        }
        if (promiseObject(item_val)) |promise| {
            if (promise.promiseIsRejected()) markHandled(ctx, promise);
        }
        record_val = try settlementRecord(rt, item_val);
        defer {
            record_val.free(rt);
            record_val = core.JSValue.undefinedValue();
        }
        try out.defineOwnProperty(rt, core.atom.atomFromUInt32(index), core.Descriptor.data(record_val, true, true, true));
    }
    out.length = source.length;
    return fulfilledWithPrototype(rt, out_val, prototype);
}

fn promiseAny(ctx: *core.JSContext, iterable: core.JSValue, prototype: ?*core.Object, global: ?*core.Object) !core.JSValue {
    const rt = ctx.runtime;
    const source = arrayObject(iterable) orelse return rejectedWithUnhandledPrototype(ctx, core.JSValue.undefinedValue(), prototype);

    var errors_val = core.JSValue.undefinedValue();
    var fulfillment_val = core.JSValue.undefinedValue();
    var item_val = core.JSValue.undefinedValue();

    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &errors_val },
        .{ .value = &fulfillment_val },
        .{ .value = &item_val },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    defer errors_val.free(rt);
    defer fulfillment_val.free(rt);
    defer item_val.free(rt);

    const errors = try core.Object.createArray(rt, null);
    errors_val = errors.value();

    var has_fulfillment = false;
    var error_count: u32 = 0;
    var index: u32 = 0;
    while (index < source.length) : (index += 1) {
        item_val = source.getProperty(core.atom.atomFromUInt32(index));
        defer {
            item_val.free(rt);
            item_val = core.JSValue.undefinedValue();
        }
        if (promiseObject(item_val)) |promise| {
            if (promise.promiseIsRejected()) {
                markHandled(ctx, promise);
                const reason = if (promise.promiseResult()) |stored| stored.dup() else core.JSValue.undefinedValue();
                defer reason.free(rt);
                try errors.defineOwnProperty(rt, core.atom.atomFromUInt32(error_count), core.Descriptor.data(reason, true, true, true));
                error_count += 1;
                continue;
            }
            if (!has_fulfillment) {
                fulfillment_val = if (promise.promiseResult()) |stored| stored.dup() else core.JSValue.undefinedValue();
                has_fulfillment = true;
            }
            continue;
        }
        if (!has_fulfillment) {
            fulfillment_val = item_val.dup();
            has_fulfillment = true;
        }
    }
    if (has_fulfillment) {
        return fulfilledWithPrototype(rt, fulfillment_val, prototype);
    }
    errors.length = error_count;
    const aggregate_error = try aggregateErrorValue(ctx, global, errors);
    defer aggregate_error.free(rt);
    return rejectedWithUnhandledPrototype(ctx, aggregate_error, prototype);
}

test "promise all family preserves direct symbol payload ownership" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const all_symbol = try rt.atoms.newValueSymbol("gc-promise-all-symbol");
    const all_source = try core.Object.createArray(rt, null);
    var all_source_alive = true;
    defer if (all_source_alive) all_source.value().free(rt);
    try all_source.defineOwnProperty(rt, core.atom.atomFromUInt32(0), core.Descriptor.data(core.JSValue.symbol(all_symbol), true, true, true));
    all_source.length = 1;

    const settled_symbol = try rt.atoms.newValueSymbol("gc-promise-all-settled-symbol");
    const settled_source = try core.Object.createArray(rt, null);
    var settled_source_alive = true;
    defer if (settled_source_alive) settled_source.value().free(rt);
    try settled_source.defineOwnProperty(rt, core.atom.atomFromUInt32(0), core.Descriptor.data(core.JSValue.symbol(settled_symbol), true, true, true));
    settled_source.length = 1;

    const any_symbol = try rt.atoms.newValueSymbol("gc-promise-any-rejection-symbol");
    const rejected_value = try rejectedWithPrototype(rt, core.JSValue.symbol(any_symbol), null);
    var rejected_alive = true;
    defer if (rejected_alive) rejected_value.free(rt);
    const any_source = try core.Object.createArray(rt, null);
    var any_source_alive = true;
    defer if (any_source_alive) any_source.value().free(rt);
    try any_source.defineOwnProperty(rt, core.atom.atomFromUInt32(0), core.Descriptor.data(rejected_value, true, true, true));
    any_source.length = 1;

    const all_promise_value = try promiseAll(ctx, all_source.value(), null);
    var all_promise_alive = true;
    defer if (all_promise_alive) all_promise_value.free(rt);
    const all_promise = promiseObject(all_promise_value) orelse return error.TypeError;
    const all_result_value = all_promise.promiseResult() orelse return error.TypeError;
    const all_result = objectFromValue(all_result_value) orelse return error.TypeError;
    {
        const stored = all_result.getProperty(core.atom.atomFromUInt32(0));
        defer stored.free(rt);
        try std.testing.expect(stored.same(core.JSValue.symbol(all_symbol)));
    }

    const settled_promise_value = try promiseAllSettled(ctx, settled_source.value(), null);
    var settled_promise_alive = true;
    defer if (settled_promise_alive) settled_promise_value.free(rt);
    const settled_promise = promiseObject(settled_promise_value) orelse return error.TypeError;
    const settled_result_value = settled_promise.promiseResult() orelse return error.TypeError;
    const settled_result = objectFromValue(settled_result_value) orelse return error.TypeError;
    {
        const record_value = settled_result.getProperty(core.atom.atomFromUInt32(0));
        defer record_value.free(rt);
        const record = objectFromValue(record_value) orelse return error.TypeError;
        const value_atom = try rt.internAtom("value");
        defer rt.atoms.free(value_atom);
        const stored = record.getProperty(value_atom);
        defer stored.free(rt);
        try std.testing.expect(stored.same(core.JSValue.symbol(settled_symbol)));
    }

    const any_promise_value = try promiseAny(ctx, any_source.value(), null, null);
    var any_promise_alive = true;
    defer if (any_promise_alive) any_promise_value.free(rt);
    const any_promise = promiseObject(any_promise_value) orelse return error.TypeError;
    try std.testing.expect(any_promise.promiseIsRejected());
    const aggregate_value = any_promise.promiseResult() orelse return error.TypeError;
    const aggregate = objectFromValue(aggregate_value) orelse return error.TypeError;
    const errors_atom = try rt.internAtom("errors");
    defer rt.atoms.free(errors_atom);
    const errors_value = aggregate.getProperty(errors_atom);
    defer errors_value.free(rt);
    const errors = objectFromValue(errors_value) orelse return error.TypeError;
    {
        const stored = errors.getProperty(core.atom.atomFromUInt32(0));
        defer stored.free(rt);
        try std.testing.expect(stored.same(core.JSValue.symbol(any_symbol)));
    }
    all_source.value().free(rt);
    all_source_alive = false;
    settled_source.value().free(rt);
    settled_source_alive = false;
    rejected_value.free(rt);
    rejected_alive = false;
    any_source.value().free(rt);
    any_source_alive = false;

    all_promise_value.free(rt);
    all_promise_alive = false;
    settled_promise_value.free(rt);
    settled_promise_alive = false;
    any_promise_value.free(rt);
    any_promise_alive = false;
}

fn settlementRecord(rt: *core.JSRuntime, item: core.JSValue) !core.JSValue {
    var rooted_item = item;
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &rooted_item },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    const record = try core.Object.create(rt, core.class.ids.object, null);
    errdefer core.Object.destroyFromHeader(rt, &record.header);
    if (promiseObject(rooted_item)) |promise| {
        const status = try stringValue(rt, if (promise.promiseIsRejected()) "rejected" else "fulfilled");
        defer status.free(rt);
        try defineData(rt, record, "status", status);
        const payload = if (promise.promiseResult()) |stored| stored.dup() else core.JSValue.undefinedValue();
        defer payload.free(rt);
        try defineData(rt, record, if (promise.promiseIsRejected()) "reason" else "value", payload);
    } else {
        const status = try stringValue(rt, "fulfilled");
        defer status.free(rt);
        try defineData(rt, record, "status", status);
        try defineData(rt, record, "value", rooted_item);
    }
    return record.value();
}

test "settlementRecord roots direct function bytecode item while creating record" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const fb_slice = try rt.memory.alloc(core.FunctionBytecode, 1);
    const fb = &fb_slice[0];
    fb.* = core.FunctionBytecode.init(&rt.memory, &rt.atoms, core.atom.ids.empty_string);
    try rt.gc.add(&fb.header);

    const symbol_atom = try rt.atoms.newValueSymbol("gc-promise-settlement-bytecode-symbol");
    fb.cpool = try rt.memory.alloc(core.JSValue, 1);
    fb.cpool[0] = core.JSValue.symbol(symbol_atom);
    fb.cpool_count = 1;

    var item = core.JSValue.functionBytecode(&fb.header);
    var item_alive = true;
    defer if (item_alive) item.free(rt);

    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const record_value = try settlementRecord(rt, item);
    var record_alive = true;
    defer if (record_alive) record_value.free(rt);
    const record = objectFromValue(record_value) orelse return error.TypeError;

    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    const value_atom = try rt.internAtom("value");
    defer rt.atoms.free(value_atom);
    const stored = record.getProperty(value_atom);
    defer stored.free(rt);
    try std.testing.expect(stored.same(item));

    record_value.free(rt);
    record_alive = false;
    item.free(rt);
    item_alive = false;
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

fn defineData(rt: *core.JSRuntime, object: *core.Object, name: []const u8, value: core.JSValue) !void {
    const atom = try rt.internAtom(name);
    defer rt.atoms.free(atom);
    try object.defineOwnProperty(rt, atom, core.Descriptor.data(value, true, true, true));
}

fn defineHiddenData(rt: *core.JSRuntime, object: *core.Object, name: []const u8, value: core.JSValue) !void {
    const atom = try rt.internAtom(name);
    defer rt.atoms.free(atom);
    try object.defineOwnProperty(rt, atom, core.Descriptor.data(value, true, false, false));
}

fn stringValue(rt: *core.JSRuntime, bytes: []const u8) !core.JSValue {
    const string = try core.string.String.createUtf8(rt, bytes);
    return string.value();
}

fn aggregateErrorValue(ctx: *core.JSContext, global: ?*core.Object, errors: *core.Object) !core.JSValue {
    var errors_value = errors.value();
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &errors_value },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = ctx.runtime.active_value_roots,
        .values = &root_values,
    };
    ctx.runtime.active_value_roots = &root_frame;
    defer ctx.runtime.active_value_roots = root_frame.previous;

    var prototype: ?*core.Object = null;
    if (global) |global_object| {
        const ctor_key = try ctx.runtime.internAtom("AggregateError");
        defer ctx.runtime.atoms.free(ctor_key);
        const ctor_value = global_object.getProperty(ctor_key);
        defer ctor_value.free(ctx.runtime);
        if (ctor_value.isObject()) {
            const ctor_object = promiseObject(ctor_value) orelse objectFromValue(ctor_value);
            if (ctor_object) |ctor| {
                const prototype_value = ctor.getProperty(core.atom.ids.prototype);
                defer prototype_value.free(ctx.runtime);
                prototype = objectFromValue(prototype_value);
            }
        }
    }

    const instance = try core.Object.create(ctx.runtime, core.class.ids.error_, prototype);
    errdefer core.Object.destroyFromHeader(ctx.runtime, &instance.header);
    const name = try stringValue(ctx.runtime, "AggregateError");
    defer name.free(ctx.runtime);
    try defineData(ctx.runtime, instance, "name", name);
    try defineData(ctx.runtime, instance, "errors", errors_value);
    return instance.value();
}

test "aggregateErrorValue roots errors array while creating aggregate error" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const errors = try core.Object.createArray(rt, null);
    var errors_alive = true;
    defer if (errors_alive) errors.value().free(rt);
    const symbol_atom = try rt.atoms.newValueSymbol("gc-promise-aggregate-errors-symbol");
    try errors.defineOwnProperty(rt, core.atom.atomFromUInt32(0), core.Descriptor.data(core.JSValue.symbol(symbol_atom), true, true, true));
    errors.length = 1;

    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const aggregate_value = try aggregateErrorValue(ctx, null, errors);
    var aggregate_alive = true;
    defer if (aggregate_alive) aggregate_value.free(rt);
    const aggregate = objectFromValue(aggregate_value) orelse return error.TypeError;

    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    const errors_key = try rt.internAtom("errors");
    defer rt.atoms.free(errors_key);
    {
        const stored_errors_value = aggregate.getProperty(errors_key);
        defer stored_errors_value.free(rt);
        try std.testing.expect(stored_errors_value.same(errors.value()));
    }

    aggregate_value.free(rt);
    aggregate_alive = false;
    errors.value().free(rt);
    errors_alive = false;
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

fn arrayObject(value: core.JSValue) ?*core.Object {
    const header = value.refHeader() orelse return null;
    const object: *core.Object = @fieldParentPtr("header", header);
    if (!object.flags.is_array) return null;
    return object;
}

fn objectFromValue(value: core.JSValue) ?*core.Object {
    const header = value.refHeader() orelse return null;
    if (header.kind != .object) return null;
    return @fieldParentPtr("header", header);
}

pub fn enqueueReaction(ctx: *core.JSContext, job: jobs.Func, args: []const core.JSValue) !void {
    try ctx.runtime.job_queue.enqueueFunc(ctx, job, args);
}

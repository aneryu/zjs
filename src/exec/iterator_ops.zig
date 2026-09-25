//! Synchronous/async iterator protocols, VM iterator records, and iterator helpers.
//!
//! Iterator and `next` values are borrowed while local or frame-rooted, then
//! transferred with `pushOwned` when a VM record takes them; returned JSValues
//! are owned. The alias wall preserves the extracted for-of, array, object, and
//! promise seams without erasing their ownership boundaries. Keep the measured
//! `ctx`/`output`/`global`/caller-function/caller-frame tuple explicit and never
//! share iterator hot arms with cold protocol fallbacks. The core protocol maps
//! to QuickJS JS_IteratorNext2 and for-in handling at quickjs.c,
//! with collection iterators around quickjs.c.

const std = @import("std");

const bytecode = @import("../bytecode.zig");
const core = @import("../core/root.zig");
const method_ids = core.host_function.builtin_method_ids;
const exceptions = @import("exception_ops.zig");
const frame_mod = @import("frame.zig");
const property_ops = @import("property_ops.zig");
const call_runtime = @import("call_runtime.zig");
const call_site_mod = @import("call_site.zig");
const exception_ops = @import("exception_ops.zig");
const array_ops = @import("array_ops.zig");
const builtin_glue = @import("builtin_glue.zig");
const coercion_ops = @import("value_ops.zig");

const object_ops = @import("object_ops.zig");
const promise_ops = @import("promise_ops.zig");
const property_direct = @import("property_ops.zig");
const string_ops = @import("string_ops.zig");
const stack_mod = @import("stack.zig");
const value_ops = @import("value_ops.zig");
const HostError = exceptions.HostError;
const Vm = @import("tailcall_dispatch.zig").Vm;
const op = bytecode.opcode.op;

const IteratorZipError = exceptions.HostError;
const CallSite = call_site_mod.CallSite;
pub const for_in_iterator_kind: u8 = 251;

pub fn forOfStart(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.FunctionBytecode,
    frame: *frame_mod.Frame,
    catch_target: ?usize,
    is_async: bool,
) !void {
    const iterable = try stack.pop();

    if (is_async) {
        const async_iterator_atom = core.atom.predefinedId("Symbol.asyncIterator", .symbol) orelse return error.TypeError;
        const async_method = try object_ops.getValueProperty(ctx, output, global, iterable, async_iterator_atom, function, frame);
        if (!async_method.is(.undefined_value) and !async_method.is(.null_value)) {
            if (!call_runtime.isCallableValue(async_method)) return error.TypeError;
            const iterator_value = try call_runtime.callValueOrBytecodeRoot(ctx, output, global, iterable, async_method, &.{}, function, frame);
            _ = try property_ops.expectObject(iterator_value);
            const next_method = try iteratorNextMethod(ctx, output, global, iterator_value, function, frame, object_ops.getValueProperty);
            try pushForAwaitRecord(ctx, stack, iterator_value, next_method);
            return;
        }
    }

    const iterator_method = try call_runtime.getIteratorMethod(ctx, output, global, iterable);
    if (!call_runtime.isCallableValue(iterator_method)) {
        _ = exception_ops.throwTypeErrorMessage(ctx, global, "value is not iterable") catch |err| return err;
        return error.TypeError;
    }
    const iterator_value = try call_runtime.callValueOrBytecodeRoot(ctx, output, global, iterable, iterator_method, &.{}, function, frame);
    _ = try property_ops.expectObject(iterator_value);
    if (is_async) {
        const wrapper = try createAsyncFromSyncIterator(ctx, output, global, iterator_value, function, frame, object_ops.getValueProperty, call_runtime.isCallableValue);
        const next_method = try iteratorNextMethod(ctx, output, global, wrapper, function, frame, object_ops.getValueProperty);
        try pushForAwaitRecord(ctx, stack, wrapper, next_method);
        return;
    }

    const next_method = try iteratorNextMethod(ctx, output, global, iterator_value, function, frame, object_ops.getValueProperty);
    try stack.pushOwned(iterator_value);
    errdefer {
        _ = stack.pop() catch null;
    }
    try stack.push(next_method);
    errdefer {
        _ = stack.pop() catch null;
        _ = stack.pop() catch null;
    }
    try stack.pushOwned(iteratorCatchMarker(catchTargetMarkerValue(catch_target)));
}

pub noinline fn forOfStartVm(vm: *Vm, opc: u8) HostError!void {
    forOfStart(vm.ctx, vm.output, vm.global, vm.stack, vm.function, vm.frame, vm.catch_target.*, opc == op.for_await_of_start) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(vm.ctx, vm.output, vm.stack, vm.frame, vm.catch_target, vm.global, err)) return;
        return err;
    };
}

fn catchTargetMarkerValue(catch_target: ?usize) i32 {
    return if (catch_target) |target| @intCast(target) else -1;
}

fn iteratorNextMethod(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    iterator_value: core.JSValue,
    function: ?*const bytecode.FunctionBytecode,
    frame: ?*frame_mod.Frame,
    comptime getValueProperty: anytype,
) !core.JSValue {
    const next_key = core.atom.ids.next;
    const next_method = try getValueProperty(ctx, output, global, iterator_value, next_key, function, frame);
    return next_method;
}

fn pushForAwaitRecord(
    _: *core.JSContext,
    stack: *stack_mod.Stack,
    iterator_value: core.JSValue,
    next_method: core.JSValue,
) !void {
    try stack.push(iterator_value);
    errdefer {
        _ = stack.pop() catch null;
    }
    try stack.push(next_method);
    errdefer {
        _ = stack.pop() catch null;
        _ = stack.pop() catch null;
    }
    try stack.pushOwned(asyncIteratorCatchMarker());
}

pub fn createAsyncFromSyncIterator(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    sync_iterator: core.JSValue,
    function: ?*const bytecode.FunctionBytecode,
    frame: ?*frame_mod.Frame,
    comptime getValueProperty: anytype,
    comptime isCallableValue: anytype,
) !core.JSValue {
    _ = isCallableValue;
    const rt = ctx.runtime;
    var rooted_sync_iterator = sync_iterator;
    var rooted_next_method = core.JSValue.undefinedValue();
    var root_frame = core.runtime.rootValues(.{ &rooted_sync_iterator, &rooted_next_method });
    root_frame.activate(rt);
    defer root_frame.deactivate(rt);

    rooted_next_method = try iteratorNextMethod(ctx, output, global, rooted_sync_iterator, function, frame, getValueProperty);

    const wrapper = try core.Object.create(rt, core.class.ids.async_from_sync_iterator, null);
    errdefer core.Object.destroyFromHeader(rt, wrapper.gcHeader());
    try wrapper.setOptionalValueSlot(rt, wrapper.iteratorTargetSlot(), rooted_sync_iterator);
    try wrapper.setOptionalValueSlot(rt, wrapper.iteratorNextSlot(), rooted_next_method);

    const next_fn = try asyncFromSyncMethod(ctx, "next", 1);
    try defineValueProperty(rt, wrapper, core.atom.ids.next, next_fn);

    const return_fn = try asyncFromSyncMethod(ctx, "return", 2);
    try defineValueProperty(rt, wrapper, core.atom.ids.return_, return_fn);

    const throw_fn = try asyncFromSyncMethod(ctx, "throw", 3);
    try defineValueProperty(rt, wrapper, core.atom.ids.throw, throw_fn);
    return wrapper.value();
}

var test_async_from_sync_next_method: core.JSValue = core.JSValue.undefinedValue();

fn testAsyncFromSyncGetValueProperty(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.JSValue,
    key: core.Atom,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    _ = ctx;
    _ = output;
    _ = global;
    _ = value;
    _ = key;
    _ = caller_function;
    _ = caller_frame;
    return test_async_from_sync_next_method;
}

fn testAsyncFromSyncIsCallable(value: core.JSValue) bool {
    return value.is(.function_bytecode) or objectFromValue(value) != null;
}

test "createAsyncFromSyncIterator roots direct function bytecode next method while creating wrapper" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();
    const global = try core.Object.create(rt, core.class.ids.global_object, null);
    _ = try global.ensureGlobalPayload(rt);
    ctx.global = global;
    const function_proto = try core.Object.create(rt, core.class.ids.object, null);
    ctx.cached_function_proto = function_proto;
    const iterator = try core.Object.create(rt, core.class.ids.object, null);

    const symbol_atom = try rt.atoms.newValueSymbol("gc-async-from-sync-next-bytecode-symbol");
    const fb = try bytecode.FunctionBytecode.createPublishedFixture(rt, .{
        .flags = .{ .func_kind = .generator },
        .cpool_count = 1,
    }, &.{try rt.takeSymbolValue(symbol_atom)});

    const next_method = core.JSValue.functionBytecode(&fb.header);
    test_async_from_sync_next_method = next_method;
    defer test_async_from_sync_next_method = core.JSValue.undefinedValue();

    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const wrapper_value = try createAsyncFromSyncIterator(
        ctx,
        null,
        global,
        iterator.value(),
        null,
        null,
        testAsyncFromSyncGetValueProperty,
        testAsyncFromSyncIsCallable,
    );
    const wrapper = objectFromValue(wrapper_value) orelse return error.TypeError;

    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    const stored = wrapper.iteratorNext() orelse return error.TypeError;
    try std.testing.expect(stored.same(next_method));

    _ = rt.collectForTest();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

fn asyncFromSyncMethod(ctx: *core.JSContext, name: []const u8, method_id: i32) !core.JSValue {
    const rt = ctx.runtime;
    const method = try core.function.nativeFunction(ctx, name, 0);
    const object = try property_ops.expectObject(method);
    if (method_id < 1 or method_id > 3) return error.TypeError;
    if (!try object.addAsyncFromSyncIteratorMethod(rt, @intCast(method_id))) return error.TypeError;
    return method;
}

fn defineValueProperty(rt: *core.JSRuntime, object: *core.Object, key: core.Atom, value: core.JSValue) !void {
    try object.defineOwnProperty(rt, key, core.Descriptor.data(value, .method));
}

pub fn forInStart(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
) !void {
    try stack.reserveAdditional(1);
    const object_value = try stack.pop();
    const iterator = try createForInIterator(ctx, output, global, object_value);
    try stack.pushOwned(iterator);
}

pub noinline fn forInStartVm(vm: *Vm) HostError!void {
    forInStart(vm.ctx, vm.output, vm.global, vm.stack) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(vm.ctx, vm.output, vm.stack, vm.frame, vm.catch_target, vm.global, err)) return;
        return err;
    };
}

pub fn iteratorNext(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.FunctionBytecode,
    frame: *frame_mod.Frame,
) !void {
    if (stack.len() < 4) return error.StackUnderflow;

    const iterator_value = stack.values[stack.len() - 4];
    const next_method = stack.values[stack.len() - 3];
    const arg_value = stack.values[stack.len() - 1];

    const result = try call_runtime.callValueOrBytecodeRoot(ctx, output, global, iterator_value, next_method, &.{arg_value}, function, frame);
    _ = stack.pop() catch |err| {
        return err;
    };
    stack.pushOwned(result) catch |err| {
        return err;
    };
}

pub noinline fn iteratorNextVm(vm: *Vm) HostError!void {
    iteratorNext(vm.ctx, vm.output, vm.global, vm.stack, vm.function, vm.frame) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(vm.ctx, vm.output, vm.stack, vm.frame, vm.catch_target, vm.global, err)) return;
        return err;
    };
}

pub fn iteratorCheckObject(ctx: *core.JSContext, stack: *stack_mod.Stack) !void {
    _ = ctx;
    const value = stack.peekBorrowed() orelse return error.StackUnderflow;
    if (!value.is(.object)) return error.TypeError;
}

pub noinline fn iteratorCheckObjectVm(vm: *Vm) HostError!void {
    iteratorCheckObject(vm.ctx, vm.stack) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(vm.ctx, vm.output, vm.stack, vm.frame, vm.catch_target, vm.global, err)) return;
        return err;
    };
}

pub fn forAwaitOfNext(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.FunctionBytecode,
    frame: *frame_mod.Frame,
) !void {
    if (stack.len() < 3) return error.StackUnderflow;
    const record_index = stack.len() - 3;
    const marker_index = stack.len() - 1;
    const iterator_value = stack.values[record_index];
    const next_method = stack.values[record_index + 1];

    stack.values[marker_index] = core.JSValue.undefinedValue();

    const result = try call_runtime.callValueOrBytecodeRoot(ctx, output, global, iterator_value, next_method, &.{}, function, frame);
    try stack.pushOwned(result);
}

pub noinline fn forAwaitOfNextVm(vm: *Vm) HostError!void {
    forAwaitOfNext(vm.ctx, vm.output, vm.global, vm.stack, vm.function, vm.frame) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(vm.ctx, vm.output, vm.stack, vm.frame, vm.catch_target, vm.global, err)) return;
        return err;
    };
}

pub fn iteratorGetValueDone(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.FunctionBytecode,
    frame: *frame_mod.Frame,
) !void {
    try stack.reserveAdditional(1);
    if (stack.len() < 2) return error.StackUnderflow;
    const object_value = try stack.pop();
    _ = try property_ops.expectObject(object_value);

    const done_key = core.atom.predefinedId("done", .string) orelse return error.TypeError;
    const done = try object_ops.getValueProperty(ctx, output, global, object_value, done_key, function, frame);
    const done_bool = coercion_ops.valueTruthy(done);

    const value_key = core.atom.predefinedId("value", .string) orelse return error.TypeError;
    const value = try object_ops.getValueProperty(ctx, output, global, object_value, value_key, function, frame);

    const marker_index = stack.len() - 1;
    stack.values[marker_index] = asyncIteratorCatchMarker();

    stack.pushOwnedAssumeCapacity(value);
    stack.pushOwnedAssumeCapacity(core.JSValue.boolean(done_bool));
}

pub noinline fn iteratorGetValueDoneVm(vm: *Vm) HostError!void {
    iteratorGetValueDone(vm.ctx, vm.output, vm.global, vm.stack, vm.function, vm.frame) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(vm.ctx, vm.output, vm.stack, vm.frame, vm.catch_target, vm.global, err)) return;
        return err;
    };
}

pub fn iteratorCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.FunctionBytecode,
    frame: *frame_mod.Frame,
) !void {
    if (frame.pc >= function.byteCode().len) return error.InvalidBytecode;
    const flags = function.byteCode()[frame.pc];
    frame.pc += 1;
    if (stack.len() < 4) return error.StackUnderflow;

    const iterator_value = stack.values[stack.len() - 4];
    const arg_value = stack.values[stack.len() - 1];

    const atom_name: []const u8 = if ((flags & 1) != 0) "throw" else "return";
    const atom_id = try ctx.runtime.internAtom(atom_name);
    const method = try object_ops.getValueProperty(ctx, output, global, iterator_value, atom_id, function, frame);
    if (method.is(.undefined_value) or method.is(.null_value)) {
        try stack.pushOwned(core.JSValue.boolean(true));
        return;
    }

    const result = if ((flags & 2) != 0)
        try call_runtime.callValueOrBytecodeRoot(ctx, output, global, iterator_value, method, &.{}, function, frame)
    else
        try call_runtime.callValueOrBytecodeRoot(ctx, output, global, iterator_value, method, &.{arg_value}, function, frame);

    try stack.reserveAdditional(1);
    _ = try stack.pop();
    stack.pushOwnedAssumeCapacity(result);
    stack.pushOwnedAssumeCapacity(core.JSValue.boolean(false));
}

pub noinline fn iteratorCallVm(vm: *Vm) HostError!void {
    iteratorCall(vm.ctx, vm.output, vm.global, vm.stack, vm.function, vm.frame) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(vm.ctx, vm.output, vm.stack, vm.frame, vm.catch_target, vm.global, err)) return;
        return err;
    };
}

/// Resolve the iterator record addressed by a `for_of_next depth` operand.
/// The depth is part of the bytecode contract: accepting another iterator
/// found elsewhere on the operand stack would silently execute malformed
/// bytecode and can close the wrong iterator on an abrupt completion.
pub fn forOfIteratorIndex(stack: *const stack_mod.Stack, depth: u8) !usize {
    const required = @as(usize, depth) + 3;
    if (stack.len() < required) return error.InvalidBytecode;
    const iterator_index = stack.len() - required;
    const iterator = stack.values[iterator_index];
    const catch_marker = stack.values[iterator_index + 2];
    if (!isIteratorCatchMarker(catch_marker)) return error.InvalidBytecode;
    if (!iterator.is(.undefined_value) and !iterator.is(.object)) return error.InvalidBytecode;
    return iterator_index;
}

pub fn forOfNext(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.FunctionBytecode,
    frame: *frame_mod.Frame,
) !void {
    if (frame.pc >= function.byteCode().len) return error.InvalidBytecode;
    const depth = function.byteCode()[frame.pc];
    frame.pc += 1;
    const iterator_index = try forOfIteratorIndex(stack, depth);
    errdefer abandonForOfIteratorAtIndex(stack, iterator_index);
    if (try fastArrayForOfNext(ctx, stack, iterator_index)) return;
    if (try fastMapSetForOfNext(ctx, stack, iterator_index)) return;
    if (try fastGeneratorForOfNext(ctx, output, global, stack, iterator_index)) return;
    const iterator_value = stack.values[iterator_index];
    var value: core.JSValue = undefined;
    var done: bool = undefined;
    if (iterator_value.is(.undefined_value)) {
        value = core.JSValue.undefinedValue();
        done = true;
    } else {
        if (iterator_index + 1 >= stack.len()) return error.StackUnderflow;
        const next_method = stack.values[iterator_index + 1];
        const step = try iteratorStepWithNext(ctx, output, global, iterator_value, next_method, function, frame);
        value = step.value;
        done = step.done;
    }
    if (done) {
        try stack.reserveAdditional(2);
        stack.values[iterator_index] = core.JSValue.undefinedValue();
    } else {
        try stack.reserveAdditional(2);
    }
    stack.pushOwnedAssumeCapacity(value);
    stack.pushOwnedAssumeCapacity(core.JSValue.boolean(done));
}

/// Finish generic `for_of_next` after a bytecode `next()` method returned in
/// the current Machine. The caller stack was deliberately left untouched
/// while the moved method frame ran, so the bytecode depth operand identifies
/// the same iterator record it identified before the call. `next_result` is
/// owned by this function on every path.
pub fn finishForOfNextResult(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.FunctionBytecode,
    frame: *frame_mod.Frame,
    depth: u8,
    next_result: core.JSValue,
) !void {
    const iterator_index = try forOfIteratorIndex(stack, depth);
    errdefer abandonForOfIteratorAtIndex(stack, iterator_index);

    const next_object = objectFromValue(next_result) orelse return error.TypeError;
    const done_value = try iteratorResultProperty(
        ctx,
        output,
        global,
        next_object,
        next_result,
        core.atom.ids.done,
        function,
        frame,
    );

    const done = coercion_ops.valueTruthy(done_value);
    const value = if (done)
        core.JSValue.undefinedValue()
    else
        try iteratorResultProperty(
            ctx,
            output,
            global,
            next_object,
            next_result,
            core.atom.ids.value,
            function,
            frame,
        );

    // Normal bytecode frames reserve `stack_size + 1` at entry, so the two
    // for-of outputs fit without another call through the generic growth
    // path. Keep the checked fallback for synthetic/malformed bytecode and
    // any cold heap-backed frame whose capacity invariant is weaker.
    if (stack.len() > stack.capacity or stack.capacity - stack.len() < 2) {
        try stack.reserveAdditional(2);
    }
    if (done) {
        stack.values[iterator_index] = core.JSValue.undefinedValue();
    }
    stack.pushOwnedAssumeCapacity(value);
    stack.pushOwnedAssumeCapacity(core.JSValue.boolean(done));
}

/// qjs's `JS_IteratorNext2` reads `done`/`value` through the ordinary property
/// walker before falling into observable accessor/Proxy/exotic machinery. Use
/// the same split here: the fast probe walks ordinary shapes/prototypes and
/// returns a borrowed data value (or undefined for a true miss); every
/// observable action still delegates to the authoritative resolver.
inline fn iteratorResultProperty(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    object: *core.Object,
    receiver: core.JSValue,
    atom_id: core.Atom,
    function: *const bytecode.FunctionBytecode,
    frame: *frame_mod.Frame,
) !core.JSValue {
    // Iterator-result objects overwhelmingly expose own `done`/`value` data
    // slots. Probe that exact qjs shape leg before paying the generic ordinary
    // prototype walk; accessors, var refs, auto-init and exotic receivers all
    // return null and retain the fallback below.
    if (object.proxyTarget() == null and !object.hasExoticMethods()) {
        var slow_property = false;
        if (object.findOwnDataValueFast(atom_id, &slow_property)) |borrowed| return borrowed;
        if (slow_property) {
            return object_ops.getValueProperty(ctx, output, global, receiver, atom_id, function, frame);
        }
    }
    if (property_direct.ordinaryDataPropertyValueOrUndefinedForFastPath(ctx.runtime, receiver, atom_id)) |borrowed| {
        return borrowed;
    }
    return object_ops.getValueProperty(ctx, output, global, receiver, atom_id, function, frame);
}

fn fastArrayForOfNext(ctx: *core.JSContext, stack: *stack_mod.Stack, iterator_index: usize) !bool {
    if (iterator_index + 1 >= stack.len()) return false;
    const iterator = objectFromValue(stack.values[iterator_index]) orelse return false;
    if (iterator.class_id != core.class.ids.array_iterator) return false;
    const next_function = objectFromValue(stack.values[iterator_index + 1]) orelse return false;
    if (!next_function.isArrayIteratorNextFunction()) return false;

    const kind = arrayIteratorKind(iterator);
    if (kind != .key and kind != .value) return false;

    const target_value = (iterator.iteratorTargetSlot().*) orelse {
        try stack.reserveAdditional(2);
        stack.values[iterator_index] = core.JSValue.undefinedValue();
        stack.pushOwnedAssumeCapacity(core.JSValue.undefinedValue());
        stack.pushOwnedAssumeCapacity(core.JSValue.boolean(true));
        return true;
    };
    const target = objectFromValue(target_value) orelse return false;
    if (!target.isArray() or target.hasExoticMethods() or target.proxyTarget() != null) return false;

    const index = iterator.iteratorIndexSlot().*;
    const length: usize = @intCast(target.arrayLength());
    if (index >= length) {
        try stack.reserveAdditional(2);
        iterator.clearOptionalValueSlot(ctx.runtime, iterator.iteratorTargetSlot());
        stack.values[iterator_index] = core.JSValue.undefinedValue();
        stack.pushOwnedAssumeCapacity(core.JSValue.undefinedValue());
        stack.pushOwnedAssumeCapacity(core.JSValue.boolean(true));
        return true;
    }
    if (index > core.atom.max_int_atom) return false;
    const element_index: u32 = @intCast(index);

    const value = switch (kind) {
        .key => core.JSValue.int32(@intCast(element_index)),
        .value => blk: {
            const atom_id = core.Atom.taggedInt(element_index);
            if (target.findProperty(atom_id) != null) return false;
            const elements = target.arrayElements();
            if (index >= elements.len) return false;
            const element = elements[index];
            break :blk element;
        },
        .key_value => unreachable,
    };

    try stack.reserveAdditional(2);
    iterator.iteratorIndexSlot().* = index + 1;
    stack.pushOwnedAssumeCapacity(value);
    stack.pushOwnedAssumeCapacity(core.JSValue.boolean(false));
    return true;
}

/// Result-object-free for-of step for the built-in Map/Set iterators (qjs
/// JS_IteratorNext2 built-in fast path, quickjs.c): when the iterator is a
/// default map/set iterator (its `next` is the builtin collection iterator_next,
/// not user-overridden), advance its entry cursor and push the value + done flag
/// straight onto the operand stack, skipping the per-step `{value, done}` result
/// object the generic protocol allocates (collectionIteratorNext -> iteratorResult).
///
/// Scope: the `key` / `value` iterator kinds (Map.keys/values, Set, Map.values),
/// whose value is a borrowed entry slot — alive via the collection regardless of a
/// GC during reserveAdditional — plus the `key_value` (entries) kind, which builds
/// a dense `[k,v]` pair array (`buildCollectionEntryPair`) right here.
fn fastMapSetForOfNext(ctx: *core.JSContext, stack: *stack_mod.Stack, iterator_index: usize) !bool {
    if (iterator_index + 1 >= stack.len()) return false;
    const iterator = objectFromValue(stack.values[iterator_index]) orelse return false;
    if (iterator.class_id != core.class.ids.map_iterator and iterator.class_id != core.class.ids.set_iterator) return false;
    // key / value / key_value (entries -> [k,v] pair). Anything else falls through.
    const kind = collectionIteratorKind(iterator) orelse return false;
    const next_function = objectFromValue(stack.values[iterator_index + 1]) orelse return false;
    const ref = core.function.decodeNativeBuiltinId(next_function.nativeFunctionId()) orelse return false;
    if (ref.domain != .collection or ref.id != @intFromEnum(method_ids.collection.PrototypeMethod.iterator_next)) return false;

    const target_value = (iterator.iteratorTargetSlot().*) orelse return try finishMapSetForOfDone(ctx, stack, iterator_index, false);
    const target = objectFromValue(target_value) orelse return false;
    if (target.class_id != core.class.ids.map and target.class_id != core.class.ids.set) return false;
    const is_set = target.class_id == core.class.ids.set;

    // Same cursor park as the generic collectionIteratorNext.
    iterator.retainCollectionIteratorCursor();
    while ((iterator.iteratorIndexSlot().*) < target.collectionEntriesSlot().items.len) {
        const index = iterator.iteratorIndexSlot().*;
        iterator.iteratorIndexSlot().* += 1;
        const entry = target.collectionEntriesSlot().items[index];
        if (!entry.active) continue;
        // key/value are borrowed entry slots, kept alive by the collection
        // (reachable via the iterator's target on the operand stack), so the dup
        // survives the reserveAdditional grow without separate rooting — same as
        // the array path. key_value builds a fresh [k,v] pair (mirrors
        // collection.iteratorValue's key_value), held alive by its own refcount.
        const value = switch (kind) {
            .key => entry.key,
            .value => if (is_set) entry.key else entry.value,
            .key_value => try buildCollectionEntryPair(
                ctx.runtime,
                is_set,
                entry,
                if (ctx.global) |global| array_ops.arrayPrototypeFromGlobal(ctx.runtime, global) else null,
            ),
        };
        try stack.reserveAdditional(2);
        stack.pushOwnedAssumeCapacity(value);
        stack.pushOwnedAssumeCapacity(core.JSValue.boolean(false));
        return true;
    }
    return try finishMapSetForOfDone(ctx, stack, iterator_index, true);
}

/// Result-object-free for-of step for a pristine sync generator (qjs JS_IteratorNext2
/// built-in fast path, quickjs.c): when the iterator is a sync generator whose
/// `next` is the un-overridden %GeneratorPrototype%.next, resume one step via
/// `syncGeneratorStep` (returns the raw value+done) and push value + done straight onto
/// the operand stack, skipping the per-step `{value, done}` iterator-result object the
/// generic protocol (generatorNext -> createIteratorResult) allocates. All `return false`
/// bails are BEFORE the resume (the generator has not advanced), so falling through to the
/// generic path never double-advances.
fn fastGeneratorForOfNext(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    iterator_index: usize,
) !bool {
    if (iterator_index + 1 >= stack.len()) return false;
    const iterator = objectFromValue(stack.values[iterator_index]) orelse return false;
    if (iterator.class_id != core.class.ids.generator) return false;
    const next_function = objectFromValue(stack.values[iterator_index + 1]) orelse return false;
    if (!next_function.isGeneratorNextFunction()) return false;

    const receiver = stack.values[iterator_index];
    // null is returned only for non-sync-generator receivers, checked BEFORE
    // the resume runs any user code, so falling back to the generic path never
    // double-advances.
    const step = (try call_runtime.syncGeneratorStep(ctx, output, global, receiver, &.{})) orelse return false;
    const value = step.value;
    const done = step.done;

    try stack.reserveAdditional(2);
    if (done) {
        stack.values[iterator_index] = core.JSValue.undefinedValue();
    }
    stack.pushOwnedAssumeCapacity(value);
    stack.pushOwnedAssumeCapacity(core.JSValue.boolean(done));
    return true;
}

/// Build the `[key, value]` pair for a Map/Set entries iterator step. Mirrors
/// collection.iteratorValue's key_value arm and qjs js_create_array
/// (quickjs.c → JS_NewArray), whose proto is the realm Array.prototype.
fn buildCollectionEntryPair(rt: *core.JSRuntime, is_set: bool, entry: core.object.CollectionEntry, prototype: ?*core.Object) !core.JSValue {
    // qjs js_create_array: a pre-sized dense fast array filled by
    // direct slot writes, NOT two per-element defineOwnProperty (each an
    // atomFromUInt32 + Descriptor build + the indexed-property machinery). Every
    // allocation (createArray, the elements slice) happens BEFORE the dups, so no
    // GC sits between a dup and the adopt; the borrowed key/value meanwhile stay
    // alive via the collection (same liveness the key/value kinds rely on).
    const pair = try core.Object.createArray(rt, prototype);
    errdefer core.Object.destroyFromHeader(rt, pair.gcHeader());
    // TGC S4-b spec 2.2: `.array_storage` GC cell.
    const elements = try core.Object.createArrayStorageSlice(rt, 2);
    elements[0] = entry.key;
    elements[1] = if (is_set) entry.key else entry.value;
    pair.adoptDenseArrayElementsAssumingEmpty(rt, elements);
    // Match the flag the old defineOwnProperty path set via markIndexedProperties.
    pair.flags.may_have_indexed_properties = true;
    return pair.value();
}

fn finishMapSetForOfDone(ctx: *core.JSContext, stack: *stack_mod.Stack, iterator_index: usize, clear_target: bool) !bool {
    if (clear_target) {
        if (objectFromValue(stack.values[iterator_index])) |iterator| {
            iterator.detachCollectionIteratorTarget(ctx.runtime);
        }
    }
    try stack.reserveAdditional(2);
    stack.values[iterator_index] = core.JSValue.undefinedValue();
    stack.pushOwnedAssumeCapacity(core.JSValue.undefinedValue());
    stack.pushOwnedAssumeCapacity(core.JSValue.boolean(true));
    return true;
}

pub noinline fn forOfNextVm(vm: *Vm) HostError!void {
    forOfNext(vm.ctx, vm.output, vm.global, vm.stack, vm.function, vm.frame) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(vm.ctx, vm.output, vm.stack, vm.frame, vm.catch_target, vm.global, err)) return;
        return err;
    };
}

/// Mirrors qjs js_for_in_next: step the snapshot of the
/// CURRENT chain object; on exhaustion walk the prototype chain LAZILY (one
/// prototype per step, own keys re-snapshotted on entry, visited-key dedup on
/// the iterator object) and re-check every candidate key with an OWN-property
/// existence probe on the current chain object (JS_GetOwnPropertyInternal
/// desc==NULL, quickjs.c "check if the property was deleted" -- the
/// gopd trap for proxies, NEVER a proto-walking [[HasProperty]]).
pub noinline fn forInNext(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
) !void {
    const rt = ctx.runtime;
    const iterator_value = stack.peek() orelse return error.StackUnderflow;
    // fail safe.
    const iterator = core.value_semantics.objectFromValue(iterator_value) orelse return pushForInDone(stack);
    if (iterator.class_id != core.class.ids.for_in_iterator) return pushForInDone(stack);

    const yielded_key: core.Atom = loop: while (true) {
        const index = iterator.iteratorIndexSlot().*;
        if (index >= iterator.iteratorLength()) {
            // not an object / no more prototype.
            const obj_value = iterator.iteratorTargetSlot().* orelse return pushForInDone(stack);
            const obj = try property_ops.expectObject(obj_value);
            // "no more property in the current object: look in the prototype"
            if (forInInProtoChainSlot(iterator).* == 0) {
                if (try forInPrepareProtoChainEnum(ctx, output, global, iterator, obj)) {
                    return pushForInDone(stack);
                }
                forInInProtoChainSlot(iterator).* = 1;
            }
            // it->obj = JS_GetPrototypeFree(ctx, it->obj).
            const proto_value = try object_ops.objectGetPrototypeOfValue(ctx, output, global, obj, null, null);
            if (proto_value.is(.null_value)) {
                iterator.clearOptionalValueSlot(rt, iterator.iteratorTargetSlot());
                return pushForInDone(stack); // no more prototype
            }
            const proto = property_ops.expectObject(proto_value) catch |err| {
                return err;
            };
            try iterator.setOptionalValueSlot(rt, iterator.iteratorTargetSlot(), proto_value);
            // snapshot the prototype's own string keys.
            const keys = try forInSnapshotOwnStringKeys(ctx, output, global, proto, iterator);
            core.atom.freeAtomList(rt, iterator.iteratorAtomKeysSlot().*);
            iterator.iteratorAtomKeysSlot().* = keys;
            iterator.setIteratorLength(std.math.cast(u32, keys.len) orelse return error.OutOfMemory);
            iterator.iteratorIndexSlot().* = 0;
            continue;
        }

        const obj_value = iterator.iteratorTargetSlot().* orelse return pushForInDone(stack);
        const obj = try property_ops.expectObject(obj_value);
        if (forInIsArraySlot(iterator).* != 0) {
            // prop = __JS_AtomFromUInt32(it->idx).
            const key = core.Atom.taggedInt(@intCast(index));
            iterator.iteratorIndexSlot().* = index + 1;
            // check if the property was deleted.
            if (try object_ops.proxyAwareExistsOwnProperty(ctx, output, global, obj, key, null, null)) break :loop key;
            continue;
        }

        const key = iterator.iteratorAtomKeys()[index];
        iterator.iteratorIndexSlot().* = index + 1;
        if (forInInProtoChainSlot(iterator).* != 0) {
            // "slow case: we are in the prototype chain" -- visited-key dedup
            // via an own-prop probe on the enum object itself, then add to
            // the visited list.
            if (try iterator.existsOwnProperty(rt, key)) continue; // already visited
            try forInDefineVisited(rt, iterator, key);
        }
        // qjs's `if (!is_enumerable) continue` is folded
        // into the snapshot: atom_keys holds only the enumerable tab entries.
        // check if the property was deleted.
        if (try object_ops.proxyAwareExistsOwnProperty(ctx, output, global, obj, key, null, null)) break :loop key;
    };

    // return the property.
    const key_value = try rt.atoms.toStringValue(rt, yielded_key);
    try stack.reserveAdditional(2);
    stack.pushOwnedAssumeCapacity(key_value);
    stack.pushOwnedAssumeCapacity(core.JSValue.boolean(false));
}

fn pushForInDone(stack: *stack_mod.Stack) !void {
    try stack.reserveAdditional(2);
    stack.pushOwnedAssumeCapacity(core.JSValue.undefinedValue());
    stack.pushOwnedAssumeCapacity(core.JSValue.boolean(true));
}

/// Mirrors qjs js_for_in_prepare_prototype_chain_enum.
/// Returns true when the enumeration is finished (no enumerable string key
/// anywhere in the prototype chain); false to enter the slow prototype-chain
/// phase after seeding the visited-key set with the root snapshot.
fn forInPrepareProtoChainEnum(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    iterator: *core.Object,
    root: *core.Object,
) !bool {
    const rt = ctx.runtime;

    // "check if there are enumerable properties in the prototype chain (fast
    // path)": walk the chain with the ENUM_ONLY probe.
    var obj1_val = try object_ops.objectGetPrototypeOfValue(ctx, output, global, root, null, null);
    var value_root_frame = core.runtime.rootValues(.{&obj1_val});
    value_root_frame.activate(rt);
    defer value_root_frame.deactivate(rt);

    var has_enumerable = false;
    while (!obj1_val.is(.null_value)) {
        const obj1 = try property_ops.expectObject(obj1_val);
        if (try forInHasEnumerableStringKey(ctx, output, global, obj1)) {
            has_enumerable = true;
            break; // goto slow_path
        }
        const next_val = try object_ops.objectGetPrototypeOfValue(ctx, output, global, obj1, null, null);
        obj1_val = next_val;
    }
    if (!has_enumerable) return true;

    // slow_path: "add the visited properties, even if they are not
    // enumerable".
    if (forInIsArraySlot(iterator).* != 0) {
        // convert the fast-array count snapshot into a real key tab
        //. qjs stores the converted tab in
        // it->tab_atom, but the caller immediately steps it->obj to the
        // prototype and replaces the tab; it is only
        // ever read by the visited defines, so it stays local here.
        const keys = try forInSnapshotOwnStringKeys(ctx, output, global, root, iterator);
        defer core.atom.freeAtomList(rt, keys);
        forInIsArraySlot(iterator).* = 0;
        for (keys) |key| try forInDefineVisited(rt, iterator, key);
    } else {
        // the snapshot's non-enumerable entries were folded into the visited
        // set when the tab was built; define the enumerable remainder.
        for (iterator.iteratorAtomKeys()) |key| try forInDefineVisited(rt, iterator, key);
    }
    return false;
}

/// VM wrapper routing forInNext errors to the active catch handler, exactly
/// like forInStartVm/forOfNextVm: a gopd trap / prototype-walk throw raised
/// mid-iteration is an ordinary catchable JS exception in qjs (js_for_in_next
/// returning -1 unwinds OP_for_in_next into the exception path).
pub noinline fn forInNextVm(vm: *Vm) HostError!void {
    forInNext(vm.ctx, vm.output, vm.global, vm.stack) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(vm.ctx, vm.output, vm.stack, vm.frame, vm.catch_target, vm.global, err)) return;
        return err;
    };
}

pub fn iteratorClose(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
) !void {
    // OP_iterator_close has one compiler contract and always consumes the
    // three-slot iterator record.  A live record carries an exact sync/async
    // catch marker; QuickJS-style generator-return cleanup deliberately uses
    // `undefined` as its dummy sync marker after nip_catch/rot3r.  Do not infer
    // a record from the iterator/next value shapes: proxies and host callables
    // make those shapes neither unique nor stable.
    const marker = try stack.pop();
    if (!isIteratorCatchMarker(marker) and !marker.is(.undefined_value)) return error.InvalidBytecode;
    const is_for_await_record = isAsyncIteratorCatchMarker(marker);
    _ = try stack.pop();
    const it = try stack.pop();
    if (it.is(.undefined_value)) return;
    if (is_for_await_record) {
        try promise_ops.closeForAwaitIteratorFromVm(ctx, output, global, it);
    } else {
        try closeIteratorFromVm(ctx, output, global, it);
    }
}

pub noinline fn iteratorCloseVm(vm: *Vm) HostError!void {
    iteratorClose(vm.ctx, vm.output, vm.global, vm.stack) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(vm.ctx, vm.output, vm.stack, vm.frame, vm.catch_target, vm.global, err)) return;
        return err;
    };
}

pub fn arrayIteratorPrototypeFromContext(
    ctx: *core.JSContext,
    global: *core.Object,
) !*core.Object {
    const slot: usize = core.class.ids.array_iterator;
    if (slot < ctx.class_prototypes.len) {
        const stored = ctx.class_prototypes[slot];
        if (stored.is(.object)) return try property_ops.expectObject(stored);
    }

    const object = try iteratorPrototype(ctx.runtime, global, "Array Iterator");
    errdefer core.Object.destroyFromHeader(ctx.runtime, object.gcHeader());
    try builtin_glue.defineNativeDataMethodWithNativeId(
        ctx.runtime,
        global,
        object,
        core.atom.ids.next,
        0,
        core.function.nativeBuiltinId(.iterator, @intFromEnum(method_ids.iterator.IntrinsicMethod.array_iterator_next)),
    );
    const next_atom = core.atom.predefinedId("next", .string) orelse return error.TypeError;
    const next_value = try object.getProperty(next_atom);
    const next_function = try property_ops.expectObject(next_value);
    if (!try next_function.addArrayIteratorNextFunction(ctx.runtime)) return error.TypeError;

    // %ArrayIteratorPrototype% inherits @@iterator from %IteratorPrototype%.
    // Installing an own copy here breaks the ES6 prototype-chain test
    // (`proto2.hasOwnProperty(@@iterator) && !proto1.hasOwnProperty(@@iterator)`).

    if (slot < ctx.class_prototypes.len) {
        const value = object.value();
        ctx.class_prototypes[slot] = value;
        // Raw slot store, not `setClassPrototype`: barrier it here. This runs
        // the first time anything iterates an Array, which is arbitrarily long
        // after the realm went old, and once the host create-ref is consumed
        // the realm is a heap object rather than a root -- so the minor's
        // sticky mark stops at it and the fresh prototype is condemned.
        ctx.runtime.gc.generationalBarrier(&ctx.header, object.gcHeader());
    }
    return object;
}

pub fn arrayIteratorMethod(
    ctx: *core.JSContext,
    global: *core.Object,
    receiver: core.JSValue,
    function_object: *core.Object,
) !?core.JSValue {
    const kind = std.enums.fromInt(ArrayIteratorKind, function_object.arrayIteratorKind()) orelse return null;
    if (receiver.is(.null_value) or receiver.is(.undefined_value)) return error.TypeError;
    var rooted_object = if (receiver.is(.object)) receiver else try object_ops.primitiveObjectForAccess(ctx.runtime, global, receiver);

    var root_frame = core.runtime.rootValues(.{&rooted_object});
    root_frame.activate(ctx.runtime);
    defer root_frame.deactivate(ctx.runtime);

    const object = try property_ops.expectObject(rooted_object);
    if (array_ops.isTypedArrayPrototypeMethod(ctx.runtime, function_object)) {
        if (!core.object.isTypedArrayObject(object)) return error.TypeError;
        if (try core.object.typedArrayDetached(object)) return error.TypeError;
        if (try core.object.typedArrayOutOfBounds(object)) return error.TypeError;
    }
    const prototype = try arrayIteratorPrototypeFromContext(ctx, global);
    const iterator = try core.Object.create(ctx.runtime, core.class.ids.array_iterator, prototype);
    errdefer core.Object.destroyFromHeader(ctx.runtime, iterator.gcHeader());
    try iterator.setOptionalValueSlot(ctx.runtime, iterator.iteratorTargetSlot(), rooted_object);
    rooted_object = core.JSValue.undefinedValue();
    iterator.iteratorIndexSlot().* = 0;
    setArrayIteratorKind(iterator, kind);
    return iterator.value();
}

pub fn arrayIteratorNext(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
) !?core.JSValue {
    const iterator = try property_ops.expectObject(receiver);
    if (iterator.class_id != core.class.ids.array_iterator) return error.TypeError;
    const target_value = (iterator.iteratorTargetSlot().*) orelse return try createIteratorResult(ctx.runtime, global, core.JSValue.undefinedValue(), true);
    const target = try property_ops.expectObject(target_value);
    const length = if (core.object.isTypedArrayObject(target)) blk: {
        if (try core.object.typedArrayDetached(target)) return error.TypeError;
        if (try core.object.typedArrayOutOfBounds(target)) return error.TypeError;
        break :blk core.object.typedArrayLength(ctx.runtime, target) catch return error.TypeError;
    } else if (target.isArray()) target.arrayLength() else blk: {
        const length_value = try object_ops.getValueProperty(ctx, output, global, target_value, core.atom.ids.length, null, null);
        break :blk @min(try coercion_ops.toLengthIndex(ctx, output, global, length_value), std.math.maxInt(u32));
    };
    if ((iterator.iteratorIndexSlot().*) >= length) {
        const done_result = try createIteratorResult(ctx.runtime, global, core.JSValue.undefinedValue(), true);
        iterator.clearOptionalValueSlot(ctx.runtime, iterator.iteratorTargetSlot());
        return done_result;
    }
    const index: u32 = @intCast((iterator.iteratorIndexSlot().*));
    iterator.iteratorIndexSlot().* += 1;
    const value = try arrayIteratorValue(ctx, output, global, target, index, arrayIteratorKind(iterator), object_ops.getValueProperty);
    return try createIteratorResult(ctx.runtime, global, value, false);
}

pub fn arrayIteratorValue(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    target: *core.Object,
    index: u32,
    kind: ArrayIteratorKind,
    comptime getValueProperty: anytype,
) !core.JSValue {
    return switch (kind) {
        .key => core.JSValue.int32(@intCast(index)),
        .value => if (core.object.isTypedArrayObject(target))
            try core.typed_array.typedArrayGetIndex(ctx.runtime, target, index)
        else
            try getValueProperty(ctx, output, global, target.value(), core.Atom.taggedInt(index), null, null),
        .key_value => blk: {
            var pair_value = core.JSValue.undefinedValue();
            var value = core.JSValue.undefinedValue();
            var root_frame = core.runtime.rootValues(.{ &pair_value, &value });
            root_frame.activate(ctx.runtime);
            defer root_frame.deactivate(ctx.runtime);

            const pair = try core.Object.createArray(ctx.runtime, array_ops.arrayPrototypeFromGlobal(ctx.runtime, global));
            errdefer core.Object.destroyFromHeader(ctx.runtime, pair.gcHeader());
            pair_value = pair.value();
            value = if (core.object.isTypedArrayObject(target))
                try core.typed_array.typedArrayGetIndex(ctx.runtime, target, index)
            else
                try getValueProperty(ctx, output, global, target.value(), core.Atom.taggedInt(index), null, null);
            try pair.defineOwnProperty(ctx.runtime, core.Atom.taggedInt(0), core.Descriptor.data(core.JSValue.int32(@intCast(index)), .all));
            try pair.defineOwnProperty(ctx.runtime, core.Atom.taggedInt(1), core.Descriptor.data(value, .all));
            break :blk pair_value;
        },
    };
}

fn testArrayIteratorGetValueProperty(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.JSValue,
    atom_id: core.Atom,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    _ = ctx;
    _ = output;
    _ = global;
    _ = caller_function;
    _ = caller_frame;
    const object = try property_ops.expectObject(value);
    return try object.getProperty(atom_id);
}

test "arrayIteratorValue roots entry value while creating pair array" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();
    const global = try core.Object.create(rt, core.class.ids.object, null);
    const target = try core.Object.createArray(rt, null);

    const symbol_atom = try rt.atoms.newValueSymbol("gc-array-iterator-entry-symbol");
    const symbol_value = try rt.takeSymbolValue(symbol_atom);
    try target.defineOwnProperty(rt, core.Atom.taggedInt(0), core.Descriptor.data(symbol_value, .all));
    target.setArrayLength(1);

    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const pair_value = try arrayIteratorValue(ctx, null, global, target, 0, .key_value, testArrayIteratorGetValueProperty);
    const pair = try property_ops.expectObject(pair_value);

    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    {
        const stored = try pair.getProperty(core.Atom.taggedInt(1));
        try std.testing.expectEqual(@as(?core.Atom, symbol_atom), stored.asSymbolAtom());
    }

    _ = rt.collectForTest();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

/// The realm's %IteratorPrototype%.
///
/// Cache first, exactly as `object_ops.objectPrototypeFromGlobal` does for
/// %Object.prototype%: this is an intrinsic fixed at realm construction, not
/// the current value of the writable `Iterator` global. Resolving it by
/// walking `globalThis.Iterator.prototype` meant that
/// `globalThis.Iterator = polyfill` — what every Iterator-Helpers shim does,
/// before application code runs — detached every lazily-built builtin
/// iterator prototype from it.
///
/// The global walk survives as the fallback for the bare-runtime tiers, which
/// have no realm cache to seed.
pub fn iteratorPrototypeFromGlobal(rt: *core.JSRuntime, global: *core.Object) ?*core.Object {
    // The realm registers `Iterator` as a standard constructor, so its
    // prototype is already in the realm's class-prototype table. Reading it
    // there costs no new state — an extra `cached_values` slot would have
    // grown JSContext and shifted every field after it.
    if (rt.contextForGlobalIncludingConstructing(global)) |realm| {
        if (realm.classPrototypeObject(core.class.ids.iterator)) |proto| return proto;
    }
    const iterator_key = core.atom.predefinedId("Iterator", .string) orelse return null;
    const iterator = global.getOwnDataObjectBorrowed(iterator_key) orelse return null;
    return iterator.getOwnDataObjectBorrowed(core.atom.ids.prototype);
}

pub fn defineToStringTag(rt: *core.JSRuntime, object: *core.Object, tag_name: []const u8) !void {
    const tag_atom = core.atom.predefinedId("Symbol.toStringTag", .symbol) orelse return error.TypeError;
    var values = [_]core.JSValue{ object.value(), core.JSValue.undefinedValue() };
    const slots: []core.JSValue = &values;
    const slices = [_]core.runtime.ValueRootSlice{.{ .mutable = &slots }};
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(rt);
    defer roots.deactivate(rt);
    values[1] = try value_ops.createStringValue(rt, tag_name);
    try core.value_semantics.objectFromValue(values[0]).?.defineOwnProperty(rt, tag_atom, core.Descriptor.data(values[1], .{ .configurable = true }));
}

pub fn iteratorPrototype(rt: *core.JSRuntime, global: *core.Object, tag_name: []const u8) !*core.Object {
    var values = [_]core.JSValue{ global.value(), core.JSValue.undefinedValue(), core.JSValue.undefinedValue() };
    const slots: []core.JSValue = &values;
    const slices = [_]core.runtime.ValueRootSlice{.{ .mutable = &slots }};
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(rt);
    defer roots.deactivate(rt);
    if (iteratorPrototypeFromGlobal(rt, global)) |base| {
        values[1] = base.value();
    } else {
        values[1] = (try core.Object.create(rt, core.class.ids.object, null)).value();
        try defineToStringTag(rt, core.value_semantics.objectFromValue(values[1]).?, "Iterator");
    }
    values[2] = (try core.Object.create(rt, core.class.ids.object, core.value_semantics.objectFromValue(values[1]).?)).value();
    try defineToStringTag(rt, core.value_semantics.objectFromValue(values[2]).?, tag_name);
    return core.value_semantics.objectFromValue(values[2]).?;
}

pub fn iteratorPrototypeAccessor(
    ctx: *core.JSContext,
    global: *core.Object,
    receiver: core.JSValue,
    args: []const core.JSValue,
    id: u32,
) !core.JSValue {
    switch (id) {
        @intFromEnum(method_ids.iterator.AccessorMethod.constructor_getter) => {
            const iterator_key = core.atom.predefinedId("Iterator", .string) orelse return error.TypeError;
            return try global.getProperty(iterator_key);
        },
        @intFromEnum(method_ids.iterator.AccessorMethod.constructor_setter) => {
            if (args.len == 0) {
                const iterator_key = core.atom.predefinedId("Iterator", .string) orelse return error.TypeError;
                return try global.getProperty(iterator_key);
            }
            return try iteratorPrototypeAccessorSet(ctx, global, receiver, core.atom.ids.constructor, args[0]);
        },
        @intFromEnum(method_ids.iterator.AccessorMethod.to_string_tag_getter) => return try value_ops.createStringValue(ctx.runtime, "Iterator"),
        @intFromEnum(method_ids.iterator.AccessorMethod.to_string_tag_setter) => return try iteratorPrototypeAccessorSet(
            ctx,
            global,
            receiver,
            core.atom.predefinedId("Symbol.toStringTag", .symbol) orelse return error.TypeError,
            if (args.len >= 1) args[0] else core.JSValue.undefinedValue(),
        ),
        else => return error.TypeError,
    }
}

pub fn iteratorPrototypeAccessorSet(
    ctx: *core.JSContext,
    global: *core.Object,
    receiver: core.JSValue,
    atom_id: core.Atom,
    value: core.JSValue,
) !core.JSValue {
    const object = try property_ops.expectObject(receiver);
    if (atom_id == core.atom.ids.constructor) {
        if (!value.is(.object)) return error.TypeError;
        try object.defineOwnProperty(ctx.runtime, atom_id, core.Descriptor.data(value, .method));
        return core.JSValue.undefinedValue();
    }
    const tag_atom = core.atom.predefinedId("Symbol.toStringTag", .symbol) orelse return error.TypeError;
    if (atom_id == tag_atom) {
        if (iteratorPrototypeFromGlobal(ctx.runtime, global)) |home| {
            if (object == home) return error.TypeError;
        }
    }
    if (try object.getOwnProperty(ctx.runtime, atom_id) != null) {
        object.setProperty(ctx.runtime, atom_id, value) catch |err| switch (err) {
            error.ReadOnly, error.AccessorWithoutSetter, error.NotExtensible, error.IncompatibleDescriptor => return error.TypeError,
            else => return err,
        };
        return core.JSValue.undefinedValue();
    }
    try object.defineOwnProperty(ctx.runtime, atom_id, core.Descriptor.data(value, .all));
    return core.JSValue.undefinedValue();
}

pub fn iteratorFromCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    if (args.len < 1) return error.TypeError;
    const source = args[0];
    if (source.is(.null_value) or source.is(.undefined_value)) return error.TypeError;
    if (!source.isString() and (core.value_semantics.objectFromValue(source)) == null) return error.TypeError;

    const result = try iteratorFromSourceForIteratorFrom(ctx, output, global, source, caller_function, caller_frame);
    if (!result.wrap) {
        return result.iterator;
    }
    return try call_runtime.wrapIteratorFromIterator(ctx, global, result.iterator, result.next_method);
}

pub const IteratorFromResult = struct {
    iterator: core.JSValue,
    next_method: ?core.JSValue = null,
    wrap: bool = false,
};

pub inline fn installIteratorHelperMethod(
    rt: *core.JSRuntime,
    global: *core.Object,
    helper: *core.Object,
    key: core.Atom,
    method_id: i32,
) !void {
    return builtin_glue.defineStampedNativeDataMethod(rt, global, helper, key, 0, .iterator_helper, method_id);
}

fn iteratorMethodsPrototype(
    rt: *core.JSRuntime,
    global: *core.Object,
    slot: core.object.RealmValueSlot,
    tag_name: []const u8,
) !*core.Object {
    if (global.cachedRealmValue(rt, slot)) |stored| return property_ops.expectObject(stored);

    var values = [_]core.JSValue{core.JSValue.undefinedValue()};
    var slots: []core.JSValue = &values;
    const globals = [_]core.JSValue{global.value()};
    const slices = [_]core.runtime.ValueRootSlice{ .{ .mutable = &slots }, .{ .borrowed = &globals } };
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(rt);
    defer roots.deactivate(rt);
    values[0] = (try iteratorPrototype(rt, global, tag_name)).value();
    try installIteratorHelperMethod(rt, global, objectFromValue(values[0]).?, core.atom.ids.next, 1);
    try installIteratorHelperMethod(rt, global, objectFromValue(values[0]).?, core.atom.ids.return_, 2);
    try global.setCachedRealmValue(rt, slot, values[0]);
    return objectFromValue(values[0]).?;
}

pub fn iteratorHelperPrototype(
    rt: *core.JSRuntime,
    global: *core.Object,
) !*core.Object {
    return iteratorMethodsPrototype(rt, global, .iterator_helper_prototype, "Iterator Helper");
}

pub fn iteratorConcatCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    comptime arrayPrototypeFromGlobal: anytype,
    comptime getIteratorMethod: anytype,
    comptime isCallableValue: anytype,
) !core.JSValue {
    // The argument window is an immutable ABI borrow; intermediate objects
    // and returned methods must remain independently movable across getters.
    var values = [_]core.JSValue{core.JSValue.undefinedValue()} ** 5;
    var slots: []core.JSValue = &values;
    const globals = [_]core.JSValue{global.value()};
    const slices = [_]core.runtime.ValueRootSlice{ .{ .mutable = &slots }, .{ .borrowed = &globals }, .{ .borrowed = args } };
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(ctx.runtime);
    defer roots.deactivate(ctx.runtime);
    values[0] = (try core.Object.createArray(ctx.runtime, arrayPrototypeFromGlobal(ctx.runtime, global))).value();

    for (args, 0..) |item, index| {
        values[1] = item;
        _ = try property_ops.expectObject(values[1]);
        values[2] = try getIteratorMethod(ctx, output, global, values[1]);
        if (values[2].is(.undefined_value) or values[2].is(.null_value) or !isCallableValue(values[2])) return error.TypeError;
        try objectFromValue(values[0]).?.setProperty(ctx.runtime, core.Atom.taggedInt(@intCast(index * 2)), values[1]);
        try objectFromValue(values[0]).?.setProperty(ctx.runtime, core.Atom.taggedInt(@intCast(index * 2 + 1)), values[2]);
    }

    values[3] = (try iteratorMethodsPrototype(ctx.runtime, global, .iterator_concat_prototype, "Iterator Concat")).value();
    values[4] = (try core.Object.create(ctx.runtime, core.class.ids.iterator_helper, objectFromValue(values[3]).?)).value();
    const helper = objectFromValue(values[4]).?;
    try helper.setOptionalValueSlot(ctx.runtime, helper.iteratorTargetSlot(), values[0]);
    setHelperKind(helper, .concat);
    helper.iteratorIndexSlot().* = 0;
    return helper.value();
}

var test_iterator_concat_method: core.JSValue = core.JSValue.undefinedValue();

fn testIteratorConcatArrayPrototypeFromGlobal(rt: *core.JSRuntime, global: *core.Object) ?*core.Object {
    _ = rt;
    _ = global;
    return null;
}

fn testIteratorConcatGetIteratorMethod(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.JSValue,
) !core.JSValue {
    _ = output;
    _ = global;
    _ = value;
    ctx.runtime.setGCThreshold(0);
    return test_iterator_concat_method;
}

test "iteratorConcatCall roots direct function bytecode iterator method while creating helper" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();
    const global = try core.Object.create(rt, core.class.ids.object, null);
    global.promoteToGlobalObjectClass(rt);
    _ = try global.ensureGlobalPayload(rt);
    ctx.global = global;
    const iterator = try core.Object.create(rt, core.class.ids.object, null);

    const concat_prototype = try core.Object.create(rt, core.class.ids.object, null);
    try global.setCachedRealmValue(rt, .iterator_concat_prototype, concat_prototype.value());

    const symbol_atom = try rt.atoms.newValueSymbol("gc-iterator-concat-method-bytecode-symbol");
    const fb = try bytecode.FunctionBytecode.createPublishedFixture(rt, .{
        .flags = .{ .func_kind = .generator },
        .cpool_count = 1,
    }, &.{try rt.takeSymbolValue(symbol_atom)});

    const iterator_method = core.JSValue.functionBytecode(&fb.header);
    test_iterator_concat_method = iterator_method;
    defer test_iterator_concat_method = core.JSValue.undefinedValue();

    const old_threshold = rt.gcThreshold();
    defer rt.setGCThreshold(old_threshold);

    const helper_value = try iteratorConcatCall(
        ctx,
        null,
        global,
        &.{iterator.value()},
        testIteratorConcatArrayPrototypeFromGlobal,
        testIteratorConcatGetIteratorMethod,
        testAsyncFromSyncIsCallable,
    );
    const helper = objectFromValue(helper_value) orelse return error.TypeError;

    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    const records_value = helper.iteratorTarget() orelse return error.TypeError;
    const records = objectFromValue(records_value) orelse return error.TypeError;
    {
        const stored_method = try records.getProperty(core.Atom.taggedInt(1));
        try std.testing.expect(stored_method.same(iterator_method));
    }

    _ = rt.collectForTest();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

pub const IteratorZipRecord = struct {
    iterator: core.JSValue,
    next: core.JSValue,
};

pub const IteratorZipCompletion = struct {
    err: ?IteratorZipError = null,
    exception: core.JSValue = core.JSValue.uninitialized(),
    exception_slot: []core.JSValue = &.{},
    root_slices: [1]core.runtime.ValueRootSlice = undefined,
    root_frame: core.runtime.ValueRootFrame = .{},
    roots_active: bool = false,

    /// Activate at the final address immediately after construction. The
    /// saved exception must survive even while Runtime.current_exception is
    /// cleared or replaced by another iterator's close callback.
    pub fn activateRoots(self: *IteratorZipCompletion, rt: *core.JSRuntime) void {
        std.debug.assert(!self.roots_active);
        self.exception_slot = @as([*]core.JSValue, @ptrCast(&self.exception))[0..1];
        self.root_slices[0] = .{ .mutable = &self.exception_slot };
        self.root_frame = .{ .slices = &self.root_slices };
        self.root_frame.activate(rt);
        self.roots_active = true;
    }

    pub fn initNormal() IteratorZipCompletion {
        return .{};
    }

    pub fn initThrow(ctx: *core.JSContext, err: anytype) IteratorZipCompletion {
        var completion = IteratorZipCompletion.initNormal();
        completion.capture(ctx, err);
        return completion;
    }

    pub fn capture(self: *IteratorZipCompletion, ctx: *core.JSContext, err: anytype) void {
        if (!self.exception.is(.uninitialized)) {
            self.exception = core.JSValue.uninitialized();
        }
        self.err = @errorCast(err);
        if (ctx.hasException()) self.exception = ctx.takeException();
    }

    pub fn restore(self: *const IteratorZipCompletion, ctx: *core.JSContext) void {
        if (ctx.hasException()) ctx.clearException();
        if (!self.exception.is(.uninitialized)) _ = ctx.throwValue(self.exception);
    }

    pub fn deinit(self: *IteratorZipCompletion, rt: *core.JSRuntime) void {
        if (self.roots_active) {
            self.root_frame.deactivate(rt);
            self.roots_active = false;
        }
        if (!self.exception.is(.uninitialized)) {
            self.exception = core.JSValue.uninitialized();
        }
        self.err = null;
    }
};

const objectFromValue = core.value_semantics.objectFromValue;

pub fn iteratorZipCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    keyed: bool,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const rt = ctx.runtime;
    if (args.len < 1) return error.TypeError;
    // Inputs, options, accumulated iterators/nexts/pads/keys, padding source,
    // and the outer iterator record each have an actual mutable slot.
    var values = [_]core.JSValue{ args[0], if (args.len >= 2) args[1] else core.JSValue.undefinedValue() } ++ ([_]core.JSValue{core.JSValue.undefinedValue()} ** 7);
    var slots: []core.JSValue = &values;
    const globals = [_]core.JSValue{global.value()};
    const slices = [_]core.runtime.ValueRootSlice{ .{ .mutable = &slots }, .{ .borrowed = &globals } };
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(rt);
    defer roots.deactivate(rt);
    _ = objectFromValue(values[0]) orelse return error.TypeError;
    const mode = try iteratorZipModeFromOptions(ctx, output, global, values[1], caller_function, caller_frame);
    if (mode == .longest and !values[1].is(.undefined_value)) {
        values[6] = try object_ops.getValueProperty(ctx, output, global, values[1], core.atom.ids.padding, caller_function, caller_frame);
        if (!values[6].is(.undefined_value) and objectFromValue(values[6]) == null) return error.TypeError;
    }
    values[2] = (try core.Object.create(rt, core.class.ids.object, null)).value();
    values[3] = (try core.Object.create(rt, core.class.ids.object, null)).value();
    values[4] = (try core.Object.create(rt, core.class.ids.object, null)).value();
    if (keyed) values[5] = (try core.Object.create(rt, core.class.ids.object, null)).value();
    const count = if (!keyed) blk: {
        values[7] = try iteratorForValue(ctx, output, global, values[0], caller_function, caller_frame);
        values[8] = try iteratorZipNextMethod(ctx, output, global, values[7], caller_function, caller_frame);
        break :blk try iteratorZipCollectIndexed(ctx, output, global, values[7], values[8], objectFromValue(values[2]).?, objectFromValue(values[3]).?, objectFromValue(values[4]).?, values[6], mode, caller_function, caller_frame);
    } else try iteratorZipCollectKeyed(ctx, output, global, objectFromValue(values[0]).?, objectFromValue(values[2]).?, objectFromValue(values[3]).?, objectFromValue(values[4]).?, objectFromValue(values[5]).?, values[6], mode, caller_function, caller_frame);
    if (count > std.math.maxInt(i32)) return error.RangeError;
    return try iteratorZipCreateHelper(rt, global, objectFromValue(values[2]).?, objectFromValue(values[3]).?, objectFromValue(values[4]).?, objectFromValue(values[5]), count, mode, keyed);
}

pub fn iteratorZipModeFromOptions(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    options: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !IteratorZipMode {
    if (options.is(.undefined_value)) return .shortest;
    _ = objectFromValue(options) orelse return error.TypeError;
    const mode_key = core.atom.ids.mode;
    const mode_value = try object_ops.getValueProperty(ctx, output, global, options, mode_key, caller_function, caller_frame);
    if (mode_value.is(.undefined_value)) return .shortest;
    if (string_ops.stringValueUnitsEqualBytes(mode_value, "shortest")) return .shortest;
    if (string_ops.stringValueUnitsEqualBytes(mode_value, "longest")) return .longest;
    if (string_ops.stringValueUnitsEqualBytes(mode_value, "strict")) return .strict;
    return error.TypeError;
}

pub fn iteratorZipCollectIndexed(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    iterables_iterator: core.JSValue,
    iterables_next: core.JSValue,
    iters: *core.Object,
    nexts: *core.Object,
    pads: *core.Object,
    padding: core.JSValue,
    mode: IteratorZipMode,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !usize {
    var rooted = [_]core.JSValue{ iterables_iterator, iterables_next, iters.value(), nexts.value(), pads.value(), padding } ++ ([_]core.JSValue{core.JSValue.undefinedValue()} ** 5);
    var slots: []core.JSValue = &rooted;
    const globals = [_]core.JSValue{global.value()};
    const slices = [_]core.runtime.ValueRootSlice{ .{ .mutable = &slots }, .{ .borrowed = &globals } };
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(ctx.runtime);
    defer roots.deactivate(ctx.runtime);

    var count: usize = 0;

    while (true) {
        rooted[6] = call_runtime.callValueOrBytecodeSyncInternalOutlined(ctx, output, global, rooted[0], rooted[1], &.{}, caller_function, caller_frame) catch |err| {
            return iteratorZipCloseAllAndPropagate(ctx, output, global, objectFromValue(rooted[2]).?, count, err, null, caller_function, caller_frame);
        };
        _ = objectFromValue(rooted[6]) orelse {
            return iteratorZipCloseAllAndPropagate(ctx, output, global, objectFromValue(rooted[2]).?, count, error.TypeError, null, caller_function, caller_frame);
        };
        const done_value = object_ops.getValueProperty(ctx, output, global, rooted[6], core.atom.predefinedId("done", .string).?, caller_function, caller_frame) catch |err| {
            return iteratorZipCloseAllAndPropagate(ctx, output, global, objectFromValue(rooted[2]).?, count, err, null, caller_function, caller_frame);
        };
        if (coercion_ops.valueTruthy(done_value)) break;
        const item = object_ops.getValueProperty(ctx, output, global, rooted[6], core.atom.predefinedId("value", .string).?, caller_function, caller_frame) catch |err| {
            return iteratorZipCloseAllAndPropagate(ctx, output, global, objectFromValue(rooted[2]).?, count, err, null, caller_function, caller_frame);
        };
        const record = iteratorZipFlattenableRecord(ctx, output, global, item, caller_function, caller_frame) catch |err| {
            return iteratorZipCloseAllAndPropagate(ctx, output, global, objectFromValue(rooted[2]).?, count, err, rooted[0], caller_function, caller_frame);
        };
        rooted[9] = record.iterator;
        rooted[10] = record.next;
        try iteratorZipStoreIndex(ctx.runtime, objectFromValue(rooted[2]).?, count, rooted[9]);
        try iteratorZipStoreIndex(ctx.runtime, objectFromValue(rooted[3]).?, count, rooted[10]);
        count += 1;
    }

    if (mode == .longest) {
        if (!rooted[5].is(.undefined_value) and !rooted[5].is(.null_value)) {
            rooted[7] = iteratorForValue(ctx, output, global, rooted[5], caller_function, caller_frame) catch |err| {
                return iteratorZipCloseAllAndPropagate(ctx, output, global, objectFromValue(rooted[2]).?, count, err, null, caller_function, caller_frame);
            };
            rooted[8] = iteratorZipNextMethod(ctx, output, global, rooted[7], caller_function, caller_frame) catch |err| {
                return iteratorZipCloseAllAndPropagate(ctx, output, global, objectFromValue(rooted[2]).?, count, err, null, caller_function, caller_frame);
            };

            var index: usize = 0;
            var done = false;
            while (index < count) : (index += 1) {
                rooted[6] = call_runtime.callValueOrBytecodeSyncInternalOutlined(ctx, output, global, rooted[7], rooted[8], &.{}, caller_function, caller_frame) catch |err| {
                    rooted[7] = core.JSValue.undefinedValue();
                    return iteratorZipCloseAllAndPropagate(ctx, output, global, objectFromValue(rooted[2]).?, count, err, null, caller_function, caller_frame);
                };
                _ = objectFromValue(rooted[6]) orelse {
                    rooted[7] = core.JSValue.undefinedValue();
                    return iteratorZipCloseAllAndPropagate(ctx, output, global, objectFromValue(rooted[2]).?, count, error.TypeError, null, caller_function, caller_frame);
                };
                const done_value = object_ops.getValueProperty(ctx, output, global, rooted[6], core.atom.predefinedId("done", .string).?, caller_function, caller_frame) catch |err| {
                    rooted[7] = core.JSValue.undefinedValue();
                    return iteratorZipCloseAllAndPropagate(ctx, output, global, objectFromValue(rooted[2]).?, count, err, null, caller_function, caller_frame);
                };
                done = coercion_ops.valueTruthy(done_value);
                const value = object_ops.getValueProperty(ctx, output, global, rooted[6], core.atom.predefinedId("value", .string).?, caller_function, caller_frame) catch |err| {
                    rooted[7] = core.JSValue.undefinedValue();
                    return iteratorZipCloseAllAndPropagate(ctx, output, global, objectFromValue(rooted[2]).?, count, err, null, caller_function, caller_frame);
                };
                if (done) break;
                try iteratorZipStoreIndex(ctx.runtime, objectFromValue(rooted[4]).?, index, value);
            }
            if (!done) {
                iteratorZipClose(ctx, output, global, rooted[7], caller_function, caller_frame) catch |err| {
                    rooted[7] = core.JSValue.undefinedValue();
                    return iteratorZipCloseAllAndPropagate(ctx, output, global, objectFromValue(rooted[2]).?, count, err, null, caller_function, caller_frame);
                };
            }
            while (index < count) : (index += 1) {
                try iteratorZipStoreIndex(ctx.runtime, objectFromValue(rooted[4]).?, index, core.JSValue.undefinedValue());
            }
        } else {
            for (0..count) |index| {
                try iteratorZipStoreIndex(ctx.runtime, objectFromValue(rooted[4]).?, index, core.JSValue.undefinedValue());
            }
        }
    }

    return count;
}

pub fn iteratorZipCollectKeyed(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    iterables: *core.Object,
    iters: *core.Object,
    nexts: *core.Object,
    pads: *core.Object,
    keys: *core.Object,
    padding: core.JSValue,
    mode: IteratorZipMode,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !usize {
    var rooted = [_]core.JSValue{ iterables.value(), iters.value(), nexts.value(), pads.value(), keys.value(), padding } ++ ([_]core.JSValue{core.JSValue.undefinedValue()} ** 3);
    var slots: []core.JSValue = &rooted;
    const globals = [_]core.JSValue{global.value()};
    const slices = [_]core.runtime.ValueRootSlice{ .{ .mutable = &slots }, .{ .borrowed = &globals } };
    var own_keys: []core.Atom = &.{};
    const atom_roots = [_]core.runtime.AtomRootSlot{.{ .list = &own_keys }};
    var roots = core.runtime.ValueRootFrame{ .slices = &slices, .atoms = &atom_roots };
    roots.activate(ctx.runtime);
    defer roots.deactivate(ctx.runtime);

    own_keys = try object_ops.objectRestOwnKeys(ctx, output, global, objectFromValue(rooted[0]).?);
    defer core.Object.freeKeys(ctx.runtime, own_keys);

    var count: usize = 0;
    for (own_keys) |key| {
        const desc = object_ops.proxyAwareOwnPropertyDescriptor(ctx, output, global, objectFromValue(rooted[0]).?, key, caller_function, caller_frame) catch |err| {
            return iteratorZipCloseAllAndPropagate(ctx, output, global, objectFromValue(rooted[1]).?, count, err, null, caller_function, caller_frame);
        } orelse continue;
        if (desc.enumerable != true) continue;

        const iter = object_ops.getValueProperty(ctx, output, global, objectFromValue(rooted[0]).?.value(), key, caller_function, caller_frame) catch |err| {
            return iteratorZipCloseAllAndPropagate(ctx, output, global, objectFromValue(rooted[1]).?, count, err, null, caller_function, caller_frame);
        };
        if (iter.is(.undefined_value)) continue;

        const record = iteratorZipFlattenableRecord(ctx, output, global, iter, caller_function, caller_frame) catch |err| {
            return iteratorZipCloseAllAndPropagate(ctx, output, global, objectFromValue(rooted[1]).?, count, err, null, caller_function, caller_frame);
        };
        rooted[6] = record.iterator;
        rooted[7] = record.next;
        rooted[8] = object_ops.proxyTrapKeyValue(ctx.runtime, key) catch |err| {
            return iteratorZipCloseAllAndPropagate(ctx, output, global, objectFromValue(rooted[1]).?, count, err, null, caller_function, caller_frame);
        };

        try iteratorZipStoreIndex(ctx.runtime, objectFromValue(rooted[1]).?, count, rooted[6]);
        try iteratorZipStoreIndex(ctx.runtime, objectFromValue(rooted[2]).?, count, rooted[7]);
        try iteratorZipStoreIndex(ctx.runtime, objectFromValue(rooted[4]).?, count, rooted[8]);
        count += 1;
    }

    if (mode == .longest) {
        for (0..count) |index| {
            if (!rooted[5].is(.undefined_value) and !rooted[5].is(.null_value)) {
                const key_value = iteratorZipGetIndex(objectFromValue(rooted[4]).?, index);
                const key = property_ops.propertyKeyAtom(ctx.runtime, key_value) catch |err| {
                    return iteratorZipCloseAllAndPropagate(ctx, output, global, objectFromValue(rooted[1]).?, count, err, null, caller_function, caller_frame);
                };
                const pad_value = object_ops.getValueProperty(ctx, output, global, rooted[5], key, caller_function, caller_frame) catch |err| {
                    return iteratorZipCloseAllAndPropagate(ctx, output, global, objectFromValue(rooted[1]).?, count, err, null, caller_function, caller_frame);
                };
                try iteratorZipStoreIndex(ctx.runtime, objectFromValue(rooted[3]).?, index, pad_value);
            } else {
                try iteratorZipStoreIndex(ctx.runtime, objectFromValue(rooted[3]).?, index, core.JSValue.undefinedValue());
            }
        }
    }

    return count;
}

pub fn iteratorZipFlattenableRecord(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !IteratorZipRecord {
    var values = [_]core.JSValue{ value, core.JSValue.undefinedValue(), core.JSValue.undefinedValue(), core.JSValue.undefinedValue() };
    var slots: []core.JSValue = &values;
    const globals = [_]core.JSValue{global.value()};
    const slices = [_]core.runtime.ValueRootSlice{ .{ .mutable = &slots }, .{ .borrowed = &globals } };
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(ctx.runtime);
    defer roots.deactivate(ctx.runtime);
    _ = objectFromValue(values[0]) orelse return error.TypeError;
    const symbol_key = core.atom.predefinedId("Symbol.iterator", .symbol) orelse return error.TypeError;
    values[1] = try object_ops.getValueProperty(ctx, output, global, values[0], symbol_key, caller_function, caller_frame);
    if (!values[1].is(.undefined_value) and !values[1].is(.null_value)) {
        if (!call_runtime.isCallableValue(values[1])) return error.TypeError;
        values[2] = try call_runtime.callValueOrBytecodeSyncInternalOutlined(ctx, output, global, values[0], values[1], &.{}, caller_function, caller_frame);
        _ = objectFromValue(values[2]) orelse return error.TypeError;
    } else values[2] = values[0];
    values[3] = try iteratorZipNextMethod(ctx, output, global, values[2], caller_function, caller_frame);
    return .{ .iterator = values[2], .next = values[3] };
}

pub fn iteratorZipNextMethod(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    iterator_value: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const iterator = objectFromValue(iterator_value) orelse return error.TypeError;
    if (iterator.cachedIteratorNext(ctx.runtime)) |cached| return cached;
    const next_key = core.atom.ids.next;
    const next_value = try object_ops.getValueProperty(ctx, output, global, iterator_value, next_key, caller_function, caller_frame);
    return next_value;
}

pub fn iteratorZipCreateHelper(
    rt: *core.JSRuntime,
    global: *core.Object,
    iters: *core.Object,
    nexts: *core.Object,
    pads: *core.Object,
    keys: ?*core.Object,
    count: usize,
    mode: IteratorZipMode,
    keyed: bool,
) !core.JSValue {
    var values = [_]core.JSValue{
        core.JSValue.undefinedValue(),
        iters.value(),
        nexts.value(),
        pads.value(),
        if (keys) |object| object.value() else core.JSValue.undefinedValue(),
        core.JSValue.undefinedValue(),
    };
    var slots: []core.JSValue = &values;
    const globals = [_]core.JSValue{global.value()};
    const slices = [_]core.runtime.ValueRootSlice{ .{ .mutable = &slots }, .{ .borrowed = &globals } };
    var root_frame = core.runtime.ValueRootFrame{ .slices = &slices };
    root_frame.activate(rt);
    defer root_frame.deactivate(rt);

    values[5] = (try iteratorHelperPrototype(rt, global)).value();
    values[0] = (try core.Object.create(rt, core.class.ids.iterator_helper, objectFromValue(values[5]).?)).value();
    const helper = objectFromValue(values[0]).?;
    setHelperKind(helper, if (keyed) .zip_keyed else .zip);
    helper.iteratorIndexSlot().* = count;
    setZipMode(helper, mode);
    setZipState(helper, .fresh);
    helper.iteratorZipAliveSlot().* = count;
    try installIteratorHelperMethod(rt, global, objectFromValue(values[0]).?, core.atom.ids.next, 1);
    try installIteratorHelperMethod(rt, global, objectFromValue(values[0]).?, core.atom.ids.return_, 2);
    try objectFromValue(values[0]).?.setOptionalValueSlot(rt, objectFromValue(values[0]).?.iteratorTargetSlot(), values[1]);
    try objectFromValue(values[0]).?.setOptionalValueSlot(rt, objectFromValue(values[0]).?.iteratorZipNextsSlot(), values[2]);
    try objectFromValue(values[0]).?.setOptionalValueSlot(rt, objectFromValue(values[0]).?.iteratorZipPadsSlot(), values[3]);
    if (!values[4].is(.undefined_value)) {
        try objectFromValue(values[0]).?.setOptionalValueSlot(rt, objectFromValue(values[0]).?.iteratorZipKeysSlot(), values[4]);
    }
    return values[0];
}

pub fn iteratorZipStoreIndex(rt: *core.JSRuntime, object: *core.Object, index: usize, value: core.JSValue) !void {
    var rooted_value = value;
    var root_frame = core.runtime.rootValues(.{&rooted_value});
    root_frame.activate(rt);
    defer root_frame.deactivate(rt);

    try object.defineOwnProperty(rt, core.Atom.taggedInt(@intCast(index)), core.Descriptor.data(rooted_value, .all));
}

test "iteratorZipStoreIndex roots direct function bytecode value while defining property" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const object = try core.Object.create(rt, core.class.ids.object, null);

    const symbol_atom = try rt.atoms.newValueSymbol("gc-iterator-zip-store-bytecode-symbol");
    const fb = try bytecode.FunctionBytecode.createPublishedFixture(rt, .{
        .flags = .{ .func_kind = .generator },
        .cpool_count = 1,
    }, &.{try rt.takeSymbolValue(symbol_atom)});

    const stored_value = core.JSValue.functionBytecode(&fb.header);

    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    try iteratorZipStoreIndex(rt, object, 0, stored_value);

    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    {
        const stored = iteratorZipGetIndex(object, 0);
        try std.testing.expect(stored.same(stored_value));
    }

    _ = object.deleteProperty(rt, core.Atom.taggedInt(0));
    _ = rt.collectForTest();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

test "iteratorZipStoreIndex roots direct symbol value while defining property" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const object = try core.Object.create(rt, core.class.ids.object, null);

    const symbol_atom = try rt.atoms.newValueSymbol("gc-iterator-zip-store-symbol");
    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const symbol_value = try rt.takeSymbolValue(symbol_atom);
    try iteratorZipStoreIndex(rt, object, 0, symbol_value);

    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    {
        const stored = iteratorZipGetIndex(object, 0);
        try std.testing.expectEqual(@as(?core.Atom, symbol_atom), stored.asSymbolAtom());
    }

    _ = object.deleteProperty(rt, core.Atom.taggedInt(0));
    _ = rt.collectForTest();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

pub fn iteratorZipGetIndex(object: *core.Object, index: usize) core.JSValue {
    return object.getOwnDataPropertyValue(core.Atom.taggedInt(@intCast(index))) orelse core.JSValue.undefinedValue();
}

pub fn iteratorZipSetIndex(rt: *core.JSRuntime, object: *core.Object, index: usize, value: core.JSValue) !void {
    var rooted_value = value;
    var root_frame = core.runtime.rootValues(.{&rooted_value});
    root_frame.activate(rt);
    defer root_frame.deactivate(rt);

    try object.setProperty(rt, core.Atom.taggedInt(@intCast(index)), rooted_value);
}

pub fn iteratorZipCloseWithCompletion(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    completion: *IteratorZipCompletion,
    iterator_value: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) void {
    iteratorZipClose(ctx, output, global, iterator_value, caller_function, caller_frame) catch |err| {
        if (completion.err == null) {
            completion.capture(ctx, err);
        } else if (ctx.hasException()) {
            ctx.clearException();
        }
        completion.restore(ctx);
    };
}

pub fn iteratorZipCloseAllWithCompletion(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    completion: *IteratorZipCompletion,
    iters: *core.Object,
    count: usize,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !void {
    var values = [_]core.JSValue{ iters.value(), core.JSValue.undefinedValue() };
    var slots: []core.JSValue = &values;
    const globals = [_]core.JSValue{global.value()};
    const slices = [_]core.runtime.ValueRootSlice{ .{ .mutable = &slots }, .{ .borrowed = &globals } };
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(ctx.runtime);
    defer roots.deactivate(ctx.runtime);
    var index = count;
    while (index > 0) {
        index -= 1;
        values[1] = iteratorZipGetIndex(objectFromValue(values[0]).?, index);
        try iteratorZipSetIndex(ctx.runtime, objectFromValue(values[0]).?, index, core.JSValue.undefinedValue());
        if (values[1].is(.undefined_value) or values[1].is(.null_value)) continue;
        iteratorZipCloseWithCompletion(ctx, output, global, completion, values[1], caller_function, caller_frame);
    }
}

pub fn iteratorZipClose(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    iterator_value: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !void {
    var values = [_]core.JSValue{iterator_value};
    var slots: []core.JSValue = &values;
    const globals = [_]core.JSValue{global.value()};
    const slices = [_]core.runtime.ValueRootSlice{ .{ .mutable = &slots }, .{ .borrowed = &globals } };
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(ctx.runtime);
    defer roots.deactivate(ctx.runtime);
    const return_key = core.atom.ids.return_;
    const return_method = try object_ops.getValueProperty(ctx, output, global, values[0], return_key, caller_function, caller_frame);
    if (return_method.is(.undefined_value) or return_method.is(.null_value)) return;
    if (!call_runtime.isCallableValue(return_method)) return error.TypeError;
    var close_call = CallSite.initInternal(
        ctx,
        output,
        global,
        values[0],
        return_method,
        caller_function,
        caller_frame,
    );
    close_call.activateRoots();
    defer close_call.deinit();
    _ = try close_call.call(&.{});
}

pub fn iteratorZipCloseAllAndPropagate(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    iters: *core.Object,
    count: usize,
    err: IteratorZipError,
    extra_iterator: ?core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) IteratorZipError {
    var values = [_]core.JSValue{ iters.value(), extra_iterator orelse core.JSValue.undefinedValue() };
    var slots: []core.JSValue = &values;
    const globals = [_]core.JSValue{global.value()};
    const slices = [_]core.runtime.ValueRootSlice{ .{ .mutable = &slots }, .{ .borrowed = &globals } };
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(ctx.runtime);
    defer roots.deactivate(ctx.runtime);
    var completion = IteratorZipCompletion.initThrow(ctx, err);
    completion.activateRoots(ctx.runtime);
    defer completion.deinit(ctx.runtime);
    iteratorZipCloseAllWithCompletion(ctx, output, global, &completion, objectFromValue(values[0]).?, count, caller_function, caller_frame) catch |close_err| {
        completion.restore(ctx);
        return close_err;
    };
    if (extra_iterator != null) {
        iteratorZipCloseWithCompletion(ctx, output, global, &completion, values[1], caller_function, caller_frame);
    }
    completion.restore(ctx);
    return completion.err orelse err;
}

const IteratorStep = struct {
    value: core.JSValue,
    done: bool,
};

const IteratorPredicateKind = enum {
    every,
    find,
    for_each,
    some,
};

pub fn iteratorCloseWithCompletionAndPropagate(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    iterator_value: core.JSValue,
    err: IteratorZipError,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) IteratorZipError {
    var completion = IteratorZipCompletion.initThrow(ctx, err);
    completion.activateRoots(ctx.runtime);
    defer completion.deinit(ctx.runtime);
    iteratorZipCloseWithCompletion(ctx, output, global, &completion, iterator_value, caller_function, caller_frame);
    completion.restore(ctx);
    return completion.err orelse err;
}

fn iteratorHelperCloseWithCompletionAndPropagate(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    helper: *core.Object,
    err: anytype,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) IteratorZipError {
    var completion = IteratorZipCompletion.initThrow(ctx, err);
    completion.activateRoots(ctx.runtime);
    defer completion.deinit(ctx.runtime);
    iteratorHelperClose(ctx, output, global, helper, caller_function, caller_frame) catch |close_err| {
        if (ctx.hasException()) ctx.clearException();
        completion.restore(ctx);
        return close_err;
    };
    completion.restore(ctx);
    return completion.err orelse err;
}

pub fn iteratorPrototypeMethodCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    args: []const core.JSValue,
    method_id: u32,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    return switch (method_id) {
        @intFromEnum(method_ids.iterator.PrototypeMethod.to_array) => try iteratorToArrayCall(ctx, output, global, receiver, caller_function, caller_frame),
        @intFromEnum(method_ids.iterator.PrototypeMethod.every) => try iteratorPredicateCall(ctx, output, global, receiver, args, .every, caller_function, caller_frame),
        @intFromEnum(method_ids.iterator.PrototypeMethod.find) => try iteratorPredicateCall(ctx, output, global, receiver, args, .find, caller_function, caller_frame),
        @intFromEnum(method_ids.iterator.PrototypeMethod.for_each) => try iteratorPredicateCall(ctx, output, global, receiver, args, .for_each, caller_function, caller_frame),
        @intFromEnum(method_ids.iterator.PrototypeMethod.reduce) => try iteratorReduceCall(ctx, output, global, receiver, args, caller_function, caller_frame),
        @intFromEnum(method_ids.iterator.PrototypeMethod.some) => try iteratorPredicateCall(ctx, output, global, receiver, args, .some, caller_function, caller_frame),
        @intFromEnum(method_ids.iterator.PrototypeMethod.map) => try iteratorCreateCallbackHelper(ctx, output, global, receiver, args, .map, caller_function, caller_frame),
        @intFromEnum(method_ids.iterator.PrototypeMethod.filter) => try iteratorCreateCallbackHelper(ctx, output, global, receiver, args, .filter, caller_function, caller_frame),
        @intFromEnum(method_ids.iterator.PrototypeMethod.take) => try iteratorCreateLimitHelper(ctx, output, global, receiver, args, .take, caller_function, caller_frame),
        @intFromEnum(method_ids.iterator.PrototypeMethod.drop) => try iteratorCreateLimitHelper(ctx, output, global, receiver, args, .drop, caller_function, caller_frame),
        @intFromEnum(method_ids.iterator.PrototypeMethod.flat_map) => try iteratorCreateCallbackHelper(ctx, output, global, receiver, args, .flatMap, caller_function, caller_frame),
        @intFromEnum(method_ids.iterator.PrototypeMethod.dispose) => try iteratorDisposeCall(ctx, output, global, receiver, caller_function, caller_frame),
        else => null,
    };
}

fn iteratorDisposeCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    try iteratorZipClose(ctx, output, global, receiver, caller_function, caller_frame);
    return core.JSValue.undefinedValue();
}

fn iteratorToArrayCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    _ = objectFromValue(receiver) orelse return error.TypeError;
    var values = [_]core.JSValue{ receiver, core.JSValue.undefinedValue(), core.JSValue.undefinedValue() };
    var slots: []core.JSValue = &values;
    const globals = [_]core.JSValue{global.value()};
    const slices = [_]core.runtime.ValueRootSlice{ .{ .mutable = &slots }, .{ .borrowed = &globals } };
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(ctx.runtime);
    defer roots.deactivate(ctx.runtime);
    const next_key = core.atom.ids.next;
    const next_method = try object_ops.getValueProperty(ctx, output, global, values[0], next_key, caller_function, caller_frame);
    if (!call_runtime.isCallableValue(next_method)) return error.TypeError;
    var next_call = CallSite.initInternal(
        ctx,
        output,
        global,
        values[0],
        next_method,
        caller_function,
        caller_frame,
    );
    next_call.activateRoots();
    defer next_call.deinit();

    values[1] = (try core.Object.createArray(ctx.runtime, array_ops.arrayPrototypeFromGlobal(ctx.runtime, global))).value();
    var index: u32 = 0;
    while (true) : (index += 1) {
        const step = try iteratorStepWithSyncCall(ctx, output, global, &next_call, caller_function, caller_frame);
        if (step.done) {
            objectFromValue(values[1]).?.setArrayLength(index);
            return values[1];
        }
        values[2] = step.value;
        try objectFromValue(values[1]).?.defineOwnProperty(ctx.runtime, core.Atom.taggedInt(index), core.Descriptor.data(values[2], .all));
    }
}

fn iteratorPredicateCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    args: []const core.JSValue,
    kind: IteratorPredicateKind,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    _ = objectFromValue(receiver) orelse return error.TypeError;
    var values = [_]core.JSValue{ receiver, if (args.len > 0) args[0] else core.JSValue.undefinedValue(), core.JSValue.undefinedValue() };
    var slots: []core.JSValue = &values;
    const globals = [_]core.JSValue{global.value()};
    const slices = [_]core.runtime.ValueRootSlice{ .{ .mutable = &slots }, .{ .borrowed = &globals } };
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(ctx.runtime);
    defer roots.deactivate(ctx.runtime);
    if (args.len < 1 or !call_runtime.isCallableValue(values[1])) {
        return iteratorCloseWithCompletionAndPropagate(ctx, output, global, values[0], error.TypeError, caller_function, caller_frame);
    }
    const next_key = core.atom.ids.next;
    const next_method = try object_ops.getValueProperty(ctx, output, global, values[0], next_key, caller_function, caller_frame);
    if (!call_runtime.isCallableValue(next_method)) return error.TypeError;
    var next_call = CallSite.initInternal(
        ctx,
        output,
        global,
        values[0],
        next_method,
        caller_function,
        caller_frame,
    );
    next_call.activateRoots();
    defer next_call.deinit();
    var callback_call = CallSite.initInternal(
        ctx,
        output,
        global,
        core.JSValue.undefinedValue(),
        values[1],
        caller_function,
        caller_frame,
    );
    callback_call.activateRoots();
    defer callback_call.deinit();

    var index: usize = 0;
    while (true) : (index += 1) {
        const step = try iteratorStepWithSyncCall(ctx, output, global, &next_call, caller_function, caller_frame);
        if (step.done) {
            return switch (kind) {
                .every => core.JSValue.boolean(true),
                .some => core.JSValue.boolean(false),
                .find, .for_each => core.JSValue.undefinedValue(),
            };
        }

        values[2] = step.value;
        const result = callback_call.call(&.{ values[2], core.JSValue.int32(@intCast(index)) }) catch |err| {
            return iteratorCloseWithCompletionAndPropagate(ctx, output, global, values[0], err, caller_function, caller_frame);
        };
        const truthy = coercion_ops.valueTruthy(result);
        switch (kind) {
            .every => if (!truthy) {
                try iteratorZipClose(ctx, output, global, values[0], caller_function, caller_frame);
                return core.JSValue.boolean(false);
            },
            .some => if (truthy) {
                try iteratorZipClose(ctx, output, global, values[0], caller_function, caller_frame);
                return core.JSValue.boolean(true);
            },
            .find => if (truthy) {
                try iteratorZipClose(ctx, output, global, values[0], caller_function, caller_frame);
                return values[2];
            },
            .for_each => {},
        }
    }
}

fn iteratorReduceCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    _ = objectFromValue(receiver) orelse return error.TypeError;
    var values = [_]core.JSValue{ receiver, if (args.len > 0) args[0] else core.JSValue.undefinedValue(), if (args.len > 1) args[1] else core.JSValue.undefinedValue(), core.JSValue.undefinedValue() };
    var slots: []core.JSValue = &values;
    const globals = [_]core.JSValue{global.value()};
    const slices = [_]core.runtime.ValueRootSlice{ .{ .mutable = &slots }, .{ .borrowed = &globals } };
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(ctx.runtime);
    defer roots.deactivate(ctx.runtime);
    if (args.len < 1 or !call_runtime.isCallableValue(values[1])) {
        return iteratorCloseWithCompletionAndPropagate(ctx, output, global, values[0], error.TypeError, caller_function, caller_frame);
    }
    const next_key = core.atom.ids.next;
    const next_method = try object_ops.getValueProperty(ctx, output, global, values[0], next_key, caller_function, caller_frame);
    if (!call_runtime.isCallableValue(next_method)) return error.TypeError;
    var next_call = CallSite.initInternal(
        ctx,
        output,
        global,
        values[0],
        next_method,
        caller_function,
        caller_frame,
    );
    next_call.activateRoots();
    defer next_call.deinit();
    var callback_call = CallSite.initInternal(
        ctx,
        output,
        global,
        core.JSValue.undefinedValue(),
        values[1],
        caller_function,
        caller_frame,
    );
    callback_call.activateRoots();
    defer callback_call.deinit();

    var index: usize = 0;
    if (args.len < 2) {
        const first = try iteratorStepWithSyncCall(ctx, output, global, &next_call, caller_function, caller_frame);
        if (first.done) return error.TypeError;
        index = 1;
        values[2] = first.value;
    }

    while (true) : (index += 1) {
        const step = try iteratorStepWithSyncCall(ctx, output, global, &next_call, caller_function, caller_frame);
        if (step.done) return values[2];
        values[3] = step.value;

        const result = callback_call.call(&.{ values[2], values[3], core.JSValue.int32(@intCast(index)) }) catch |err| {
            return iteratorCloseWithCompletionAndPropagate(ctx, output, global, values[0], err, caller_function, caller_frame);
        };
        values[2] = result;
    }
}

/// Leftover post-`next()` decode. candidate101 still compiles two leftover
/// copies (`iteratorStepWithNext` 736 / `iteratorStepWithSyncCall` 729,
/// extra 729, 14.3% match). The leftover is objectFromValue + get `done` /
/// `value`. Comptime identity is only how `next()` is invoked. Take the
/// already-produced result on one walk. Private names stay `inline` and
/// keep their unique call — do not fold Next through `CallSite`.
noinline fn iteratorStepFromNextResult(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    next_result: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !IteratorStep {
    var values = [_]core.JSValue{next_result};
    var slots: []core.JSValue = &values;
    const globals = [_]core.JSValue{global.value()};
    const slices = [_]core.runtime.ValueRootSlice{ .{ .mutable = &slots }, .{ .borrowed = &globals } };
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(ctx.runtime);
    defer roots.deactivate(ctx.runtime);
    _ = objectFromValue(next_result) orelse return error.TypeError;
    const done = try object_ops.getValueProperty(
        ctx,
        output,
        global,
        values[0],
        core.atom.predefinedId("done", .string).?,
        caller_function,
        caller_frame,
    );
    if (coercion_ops.valueTruthy(done)) return .{ .value = core.JSValue.undefinedValue(), .done = true };
    const value = try object_ops.getValueProperty(
        ctx,
        output,
        global,
        values[0],
        core.atom.predefinedId("value", .string).?,
        caller_function,
        caller_frame,
    );
    return .{ .value = value, .done = false };
}

pub inline fn iteratorStepWithNext(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    iterator_value: core.JSValue,
    next_method: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !IteratorStep {
    const next_result = try call_runtime.callValueOrBytecodeRoot(ctx, output, global, iterator_value, next_method, &.{}, caller_function, caller_frame);
    return iteratorStepFromNextResult(ctx, output, global, next_result, caller_function, caller_frame);
}

inline fn iteratorStepWithSyncCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    next_call: *CallSite,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !IteratorStep {
    const next_result = try next_call.call(&.{});
    return iteratorStepFromNextResult(ctx, output, global, next_result, caller_function, caller_frame);
}

fn iteratorStepWithSyncValues(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    iterator_value: core.JSValue,
    next_method: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !IteratorStep {
    var next_call = CallSite.initInternal(
        ctx,
        output,
        global,
        iterator_value,
        next_method,
        caller_function,
        caller_frame,
    );
    next_call.activateRoots();
    defer next_call.deinit();
    return iteratorStepWithSyncCall(ctx, output, global, &next_call, caller_function, caller_frame);
}

fn iteratorCreateCallbackHelper(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    args: []const core.JSValue,
    kind: IteratorHelperKind,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    _ = objectFromValue(receiver) orelse return error.TypeError;
    if (args.len < 1 or !call_runtime.isCallableValue(args[0])) {
        return iteratorCloseWithCompletionAndPropagate(ctx, output, global, receiver, error.TypeError, caller_function, caller_frame);
    }
    return try iteratorCreateHelper(ctx, output, global, receiver, kind, args[0], null, caller_function, caller_frame, object_ops.getValueProperty);
}

fn iteratorCreateLimitHelper(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    args: []const core.JSValue,
    kind: IteratorHelperKind,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    _ = objectFromValue(receiver) orelse return error.TypeError;
    var values = [_]core.JSValue{ receiver, if (args.len > 0) args[0] else core.JSValue.undefinedValue() };
    var slots: []core.JSValue = &values;
    const globals = [_]core.JSValue{global.value()};
    const slices = [_]core.runtime.ValueRootSlice{ .{ .mutable = &slots }, .{ .borrowed = &globals } };
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(ctx.runtime);
    defer roots.deactivate(ctx.runtime);
    const limit = iteratorLimitArgument(ctx, output, global, values[1..]) catch |err| {
        return iteratorCloseWithCompletionAndPropagate(ctx, output, global, values[0], err, caller_function, caller_frame);
    };
    return try iteratorCreateHelper(ctx, output, global, values[0], kind, core.JSValue.undefinedValue(), limit, caller_function, caller_frame, object_ops.getValueProperty);
}

fn iteratorLimitArgument(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
) !usize {
    const limit_arg = if (args.len > 0) args[0] else core.JSValue.undefinedValue();
    const primitive = if (limit_arg.is(.object))
        try coercion_ops.toPrimitiveForNumber(ctx, output, global, limit_arg)
    else
        limit_arg;
    const number_value = try value_ops.toNumberValue(ctx.runtime, primitive);
    const number = number_value.as(.float64) orelse @as(f64, @floatFromInt(number_value.as(.int) orelse 0));
    if (std.math.isNan(number)) return error.RangeError;
    if (!std.math.isFinite(number)) return std.math.maxInt(usize);
    const integer = std.math.trunc(number);
    if (integer < 0) return error.RangeError;
    return @as(usize, @intFromFloat(integer));
}

fn iteratorCreateHelper(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    kind: IteratorHelperKind,
    callback: core.JSValue,
    limit: ?usize,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
    comptime getValueProperty: anytype,
) !core.JSValue {
    var values = [_]core.JSValue{ receiver, callback, core.JSValue.undefinedValue(), core.JSValue.undefinedValue(), core.JSValue.undefinedValue() };
    var slots: []core.JSValue = &values;
    const globals = [_]core.JSValue{global.value()};
    const slices = [_]core.runtime.ValueRootSlice{ .{ .mutable = &slots }, .{ .borrowed = &globals } };
    var root_frame = core.runtime.ValueRootFrame{ .slices = &slices };
    root_frame.activate(ctx.runtime);
    defer root_frame.deactivate(ctx.runtime);

    _ = objectFromValue(values[0]) orelse return error.TypeError;
    const next_key = core.atom.ids.next;
    values[2] = try getValueProperty(ctx, output, global, values[0], next_key, caller_function, caller_frame);

    values[3] = (try iteratorHelperPrototype(ctx.runtime, global)).value();
    values[4] = (try core.Object.create(ctx.runtime, core.class.ids.iterator_helper, objectFromValue(values[3]).?)).value();
    // Payload publication stores existing values and records their barriers;
    // it does not invoke JS or collect.
    const helper = objectFromValue(values[4]).?;
    try helper.setOptionalValueSlot(ctx.runtime, helper.iteratorTargetSlot(), values[0]);
    setHelperKind(helper, kind);
    helper.iteratorIndexSlot().* = limit orelse 0;
    try helper.setOptionalValueSlot(ctx.runtime, helper.iteratorNextSlot(), values[2]);
    if (!values[1].is(.undefined_value)) try helper.setOptionalValueSlot(ctx.runtime, helper.iteratorCallbackSlot(), values[1]);
    return values[4];
}

test "iteratorCreateHelper roots direct function bytecode callback while creating helper" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();
    const global = try core.Object.create(rt, core.class.ids.object, null);
    global.promoteToGlobalObjectClass(rt);
    _ = try global.ensureGlobalPayload(rt);
    ctx.global = global;
    const iterator = try core.Object.create(rt, core.class.ids.object, null);

    const next_key = try rt.internAtom("next");
    try iterator.defineOwnProperty(rt, next_key, core.Descriptor.data(core.JSValue.int32(1), .all));

    const helper_prototype = try core.Object.create(rt, core.class.ids.object, null);
    try global.setCachedRealmValue(rt, .iterator_helper_prototype, helper_prototype.value());

    const symbol_atom = try rt.atoms.newValueSymbol("gc-iterator-helper-callback-bytecode-symbol");
    const fb = try bytecode.FunctionBytecode.createPublishedFixture(rt, .{
        .flags = .{ .func_kind = .generator },
        .cpool_count = 1,
    }, &.{try rt.takeSymbolValue(symbol_atom)});

    const callback = core.JSValue.functionBytecode(&fb.header);

    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const helper_value = try iteratorCreateHelper(
        ctx,
        null,
        global,
        iterator.value(),
        .map,
        callback,
        null,
        null,
        null,
        testIteratorGetValuePropertyOptional,
    );
    const helper = objectFromValue(helper_value) orelse return error.TypeError;

    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    const stored = helper.iteratorCallback() orelse return error.TypeError;
    try std.testing.expect(stored.same(callback));

    _ = rt.collectForTest();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

fn iteratorZipPutResult(
    rt: *core.JSRuntime,
    results: *core.Object,
    keys: ?*core.Object,
    index: usize,
    value: core.JSValue,
) !void {
    var rooted = [_]core.JSValue{ results.value(), value, if (keys) |object| object.value() else core.JSValue.undefinedValue() };
    var slots: []core.JSValue = &rooted;
    const slices = [_]core.runtime.ValueRootSlice{.{ .mutable = &slots }};
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(rt);
    defer roots.deactivate(rt);
    if (objectFromValue(rooted[2])) |key_store| {
        const key_value = iteratorZipGetIndex(key_store, index);
        const atom_id = try property_ops.propertyKeyAtom(rt, key_value);
        try objectFromValue(rooted[0]).?.defineOwnProperty(rt, atom_id, core.Descriptor.data(rooted[1], .all));
        return;
    }
    try objectFromValue(rooted[0]).?.defineOwnProperty(rt, core.Atom.taggedInt(@intCast(index)), core.Descriptor.data(rooted[1], .all));
}

fn iteratorZipCompleteAbrupt(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    helper: *core.Object,
    iters: *core.Object,
    count: usize,
    current_index: ?usize,
    err: IteratorZipError,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) IteratorZipError {
    var rooted = [_]core.JSValue{helper.value()};
    var slots: []core.JSValue = &rooted;
    const borrowed = [_]core.JSValue{global.value()};
    const slices = [_]core.runtime.ValueRootSlice{ .{ .mutable = &slots }, .{ .borrowed = &borrowed } };
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(ctx.runtime);
    defer roots.deactivate(ctx.runtime);

    var completion = IteratorZipCompletion.initThrow(ctx, err);
    completion.activateRoots(ctx.runtime);
    defer completion.deinit(ctx.runtime);
    objectFromValue(rooted[0]).?.iteratorZipAliveSlot().* = 0;
    if (current_index) |index| {
        try iteratorZipSetIndex(ctx.runtime, iters, index, core.JSValue.undefinedValue());
    }
    iteratorZipCloseAllWithCompletion(ctx, output, global, &completion, iters, count, caller_function, caller_frame) catch |close_err| {
        completion.restore(ctx);
        return close_err;
    };
    try iteratorHelperClear(ctx.runtime, objectFromValue(rooted[0]).?);
    setZipState(objectFromValue(rooted[0]).?, .done);
    completion.restore(ctx);
    return completion.err orelse err;
}

fn iteratorZipHelperNext(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    helper: *core.Object,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    // helper, iterators, next methods, padding, keys, unpublished row, step.
    // Re-project after every callback; rooting the owner does not pin children.
    var rooted = [_]core.JSValue{helper.value()} ++ ([_]core.JSValue{core.JSValue.undefinedValue()} ** 6);
    var slots: []core.JSValue = &rooted;
    const borrowed = [_]core.JSValue{global.value()};
    const slices = [_]core.runtime.ValueRootSlice{ .{ .mutable = &slots }, .{ .borrowed = &borrowed } };
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(ctx.runtime);
    defer roots.deactivate(ctx.runtime);
    switch (zipState(objectFromValue(rooted[0]).?)) {
        .fresh, .yielded => setZipState(objectFromValue(rooted[0]).?, .running),
        .running => return error.TypeError,
        .done => return try createIteratorResult(ctx.runtime, global, core.JSValue.undefinedValue(), true),
    }

    rooted[1] = objectFromValue(rooted[0]).?.iteratorTargetSlot().* orelse return try createIteratorResult(ctx.runtime, global, core.JSValue.undefinedValue(), true);
    _ = objectFromValue(rooted[1]) orelse return error.TypeError;
    rooted[2] = objectFromValue(rooted[0]).?.iteratorZipNexts() orelse return error.TypeError;
    _ = objectFromValue(rooted[2]) orelse return error.TypeError;
    rooted[3] = objectFromValue(rooted[0]).?.iteratorZipPads() orelse return error.TypeError;
    _ = objectFromValue(rooted[3]) orelse return error.TypeError;
    if (helperKind(objectFromValue(rooted[0]).?) == .zip_keyed) {
        rooted[4] = objectFromValue(rooted[0]).?.iteratorZipKeys() orelse return error.TypeError;
        _ = objectFromValue(rooted[4]) orelse return error.TypeError;
    }
    const mode = zipMode(objectFromValue(rooted[0]).?);
    var alive: usize = objectFromValue(rooted[0]).?.iteratorZipAliveSlot().*;
    const count = (objectFromValue(rooted[0]).?.iteratorIndexSlot().*);

    rooted[5] = if (rooted[4].is(.undefined_value))
        (try core.Object.createArray(ctx.runtime, array_ops.arrayPrototypeFromGlobal(ctx.runtime, global))).value()
    else
        (try core.Object.create(ctx.runtime, core.class.ids.object, null)).value();

    var dones: usize = 0;
    var values: usize = 0;
    for (0..count) |index| {
        const iter = iteratorZipGetIndex(objectFromValue(rooted[1]).?, index);
        if (iter.is(.undefined_value) or iter.is(.null_value)) {
            if (mode != .longest) return error.TypeError;
            const pad = iteratorZipGetIndex(objectFromValue(rooted[3]).?, index);
            try iteratorZipPutResult(ctx.runtime, objectFromValue(rooted[5]).?, objectFromValue(rooted[4]), index, pad);
            continue;
        }

        const next_method = iteratorZipGetIndex(objectFromValue(rooted[2]).?, index);
        rooted[6] = call_runtime.callValueOrBytecodeSyncInternalOutlined(ctx, output, global, iter, next_method, &.{}, caller_function, caller_frame) catch |err| {
            return iteratorZipCompleteAbrupt(ctx, output, global, objectFromValue(rooted[0]).?, objectFromValue(rooted[1]).?, count, index, err, caller_function, caller_frame);
        };
        _ = objectFromValue(rooted[6]) orelse {
            return iteratorZipCompleteAbrupt(ctx, output, global, objectFromValue(rooted[0]).?, objectFromValue(rooted[1]).?, count, index, error.TypeError, caller_function, caller_frame);
        };
        const done_value = object_ops.getValueProperty(ctx, output, global, rooted[6], core.atom.predefinedId("done", .string).?, caller_function, caller_frame) catch |err| {
            return iteratorZipCompleteAbrupt(ctx, output, global, objectFromValue(rooted[0]).?, objectFromValue(rooted[1]).?, count, index, err, caller_function, caller_frame);
        };
        if (!coercion_ops.valueTruthy(done_value)) {
            if (mode == .strict and dones > 0) {
                return iteratorZipCompleteAbrupt(ctx, output, global, objectFromValue(rooted[0]).?, objectFromValue(rooted[1]).?, count, null, error.TypeError, caller_function, caller_frame);
            }
            const value = object_ops.getValueProperty(ctx, output, global, rooted[6], core.atom.predefinedId("value", .string).?, caller_function, caller_frame) catch |err| {
                return iteratorZipCompleteAbrupt(ctx, output, global, objectFromValue(rooted[0]).?, objectFromValue(rooted[1]).?, count, index, err, caller_function, caller_frame);
            };
            try iteratorZipPutResult(ctx.runtime, objectFromValue(rooted[5]).?, objectFromValue(rooted[4]), index, value);
            values += 1;
            continue;
        }

        if (alive > 0) alive -= 1;
        dones += 1;
        try iteratorZipSetIndex(ctx.runtime, objectFromValue(rooted[1]).?, index, core.JSValue.undefinedValue());
        objectFromValue(rooted[0]).?.iteratorZipAliveSlot().* = alive;

        switch (mode) {
            .shortest => {
                var completion = IteratorZipCompletion.initNormal();
                completion.activateRoots(ctx.runtime);
                defer completion.deinit(ctx.runtime);
                try iteratorZipCloseAllWithCompletion(ctx, output, global, &completion, objectFromValue(rooted[1]).?, count, caller_function, caller_frame);
                try iteratorHelperClear(ctx.runtime, objectFromValue(rooted[0]).?);
                setZipState(objectFromValue(rooted[0]).?, .done);
                if (completion.err) |err| {
                    completion.restore(ctx);
                    return err;
                }
                return try createIteratorResult(ctx.runtime, global, core.JSValue.undefinedValue(), true);
            },
            .longest => {
                if (alive < 1) {
                    try iteratorHelperClear(ctx.runtime, objectFromValue(rooted[0]).?);
                    setZipState(objectFromValue(rooted[0]).?, .done);
                    return try createIteratorResult(ctx.runtime, global, core.JSValue.undefinedValue(), true);
                }
                const pad = iteratorZipGetIndex(objectFromValue(rooted[3]).?, index);
                try iteratorZipPutResult(ctx.runtime, objectFromValue(rooted[5]).?, objectFromValue(rooted[4]), index, pad);
            },
            .strict => {
                if (values > 0) {
                    return iteratorZipCompleteAbrupt(ctx, output, global, objectFromValue(rooted[0]).?, objectFromValue(rooted[1]).?, count, null, error.TypeError, caller_function, caller_frame);
                }
            },
        }
    }

    if (values == 0) {
        try iteratorHelperClear(ctx.runtime, objectFromValue(rooted[0]).?);
        setZipState(objectFromValue(rooted[0]).?, .done);
        return try createIteratorResult(ctx.runtime, global, core.JSValue.undefinedValue(), true);
    }

    if (objectFromValue(rooted[4]) == null) objectFromValue(rooted[5]).?.setArrayLength(@intCast(count));
    setZipState(objectFromValue(rooted[0]).?, .yielded);
    return try createIteratorResult(ctx.runtime, global, rooted[5], false);
}

fn iteratorZipHelperReturn(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    helper: *core.Object,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    var rooted = [_]core.JSValue{helper.value()};
    var slots: []core.JSValue = &rooted;
    const borrowed = [_]core.JSValue{global.value()};
    const slices = [_]core.runtime.ValueRootSlice{ .{ .mutable = &slots }, .{ .borrowed = &borrowed } };
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(ctx.runtime);
    defer roots.deactivate(ctx.runtime);
    switch (zipState(objectFromValue(rooted[0]).?)) {
        .fresh => setZipState(objectFromValue(rooted[0]).?, .done),
        .yielded => setZipState(objectFromValue(rooted[0]).?, .running),
        .running => return error.TypeError,
        .done => return try createIteratorResult(ctx.runtime, global, core.JSValue.undefinedValue(), true),
    }

    if ((objectFromValue(rooted[0]).?.iteratorTargetSlot().*)) |iterator_value| {
        const iters = objectFromValue(iterator_value) orelse return error.TypeError;
        var completion = IteratorZipCompletion.initNormal();
        completion.activateRoots(ctx.runtime);
        defer completion.deinit(ctx.runtime);
        try iteratorZipCloseAllWithCompletion(ctx, output, global, &completion, iters, (objectFromValue(rooted[0]).?.iteratorIndexSlot().*), caller_function, caller_frame);
        try iteratorHelperClear(ctx.runtime, objectFromValue(rooted[0]).?);
        setZipState(objectFromValue(rooted[0]).?, .done);
        if (completion.err) |err| {
            completion.restore(ctx);
            return err;
        }
        return try createIteratorResult(ctx.runtime, global, core.JSValue.undefinedValue(), true);
    }
    try iteratorHelperClear(ctx.runtime, objectFromValue(rooted[0]).?);
    setZipState(objectFromValue(rooted[0]).?, .done);
    return try createIteratorResult(ctx.runtime, global, core.JSValue.undefinedValue(), true);
}

pub fn iteratorHelperNext(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    function_object: *core.Object,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    if (function_object.iteratorHelperMethod() != 1) return null;
    const helper = objectFromValue(receiver) orelse return error.TypeError;
    if (helper.class_id != core.class.ids.iterator_helper) return error.TypeError;
    const borrowed = [_]core.JSValue{global.value()};
    var values = [_]core.JSValue{ receiver, core.JSValue.undefinedValue(), core.JSValue.undefinedValue() };
    var slots: []core.JSValue = &values;
    const slices = [_]core.runtime.ValueRootSlice{ .{ .borrowed = &borrowed }, .{ .mutable = &slots } };
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(ctx.runtime);
    defer roots.deactivate(ctx.runtime);
    if (objectFromValue(values[0]).?.generatorExecuting()) return error.TypeError;
    objectFromValue(values[0]).?.generatorExecutingSlot().* = true;
    defer objectFromValue(values[0]).?.generatorExecutingSlot().* = false;
    const iterator = (objectFromValue(values[0]).?.iteratorTargetSlot().*) orelse return try createIteratorResult(ctx.runtime, global, core.JSValue.undefinedValue(), true);
    const kind = helperKind(objectFromValue(values[0]).?);

    switch (kind) {
        .zip, .zip_keyed => return try iteratorZipHelperNext(ctx, output, global, objectFromValue(values[0]).?, caller_function, caller_frame),
        .concat => {
            while (true) {
                if (objectFromValue(values[0]).?.iteratorData()) |inner_iterator| {
                    const inner_next = objectFromValue(values[0]).?.iteratorInnerNext() orelse return error.TypeError;
                    const inner_step = try iteratorStepWithSyncValues(ctx, output, global, inner_iterator, inner_next, caller_function, caller_frame);
                    if (!inner_step.done) return try createIteratorResult(ctx.runtime, global, inner_step.value, false);
                    try iteratorHelperClearInner(ctx.runtime, objectFromValue(values[0]).?);
                }

                const records = objectFromValue(objectFromValue(values[0]).?.iteratorTargetSlot().* orelse return error.TypeError) orelse return error.TypeError;
                if ((objectFromValue(values[0]).?.iteratorIndexSlot().*) >= records.arrayLength() / 2) {
                    try iteratorHelperClear(ctx.runtime, objectFromValue(values[0]).?);
                    return try createIteratorResult(ctx.runtime, global, core.JSValue.undefinedValue(), true);
                }
                const item_index: u32 = @intCast((objectFromValue(values[0]).?.iteratorIndexSlot().*) * 2);
                objectFromValue(values[0]).?.iteratorIndexSlot().* += 1;
                const item = try records.getProperty(core.Atom.taggedInt(item_index));
                const method = try records.getProperty(core.Atom.taggedInt(item_index + 1));
                const inner_iterator = try call_runtime.callValueOrBytecodeSyncInternalOutlined(ctx, output, global, item, method, &.{}, caller_function, caller_frame);
                try iteratorHelperSetInnerFromIterator(ctx, output, global, objectFromValue(values[0]).?, inner_iterator, caller_function, caller_frame);
            }
        },
        .take => {
            const next_method = objectFromValue(values[0]).?.iteratorNext() orelse return error.TypeError;
            var next_call = CallSite.initInternal(ctx, output, global, iterator, next_method, caller_function, caller_frame);
            next_call.activateRoots();
            defer next_call.deinit();
            if ((objectFromValue(values[0]).?.iteratorIndexSlot().*) == 0) {
                try iteratorHelperClose(ctx, output, global, objectFromValue(values[0]).?, caller_function, caller_frame);
                return try createIteratorResult(ctx.runtime, global, core.JSValue.undefinedValue(), true);
            }
            objectFromValue(values[0]).?.iteratorIndexSlot().* -= 1;
            const step = try iteratorStepWithSyncCall(ctx, output, global, &next_call, caller_function, caller_frame);
            if (step.done) {
                try iteratorHelperClear(ctx.runtime, objectFromValue(values[0]).?);
                return try createIteratorResult(ctx.runtime, global, core.JSValue.undefinedValue(), true);
            }
            return try createIteratorResult(ctx.runtime, global, step.value, false);
        },
        .drop => {
            const next_method = objectFromValue(values[0]).?.iteratorNext() orelse return error.TypeError;
            var next_call = CallSite.initInternal(ctx, output, global, iterator, next_method, caller_function, caller_frame);
            next_call.activateRoots();
            defer next_call.deinit();
            while ((objectFromValue(values[0]).?.iteratorIndexSlot().*) > 0) : (objectFromValue(values[0]).?.iteratorIndexSlot().* -= 1) {
                const skipped = try iteratorStepWithSyncCall(ctx, output, global, &next_call, caller_function, caller_frame);
                if (skipped.done) {
                    try iteratorHelperClear(ctx.runtime, objectFromValue(values[0]).?);
                    return try createIteratorResult(ctx.runtime, global, core.JSValue.undefinedValue(), true);
                }
            }
            const step = try iteratorStepWithSyncCall(ctx, output, global, &next_call, caller_function, caller_frame);
            if (step.done) {
                try iteratorHelperClear(ctx.runtime, objectFromValue(values[0]).?);
                return try createIteratorResult(ctx.runtime, global, core.JSValue.undefinedValue(), true);
            }
            return try createIteratorResult(ctx.runtime, global, step.value, false);
        },
        .map, .filter, .flatMap => {
            const next_method = objectFromValue(values[0]).?.iteratorNext() orelse return error.TypeError;
            const callback = objectFromValue(values[0]).?.iteratorCallback() orelse return error.TypeError;
            var next_call = CallSite.initInternal(ctx, output, global, iterator, next_method, caller_function, caller_frame);
            next_call.activateRoots();
            defer next_call.deinit();
            var callback_call = CallSite.initInternal(
                ctx,
                output,
                global,
                core.JSValue.undefinedValue(),
                callback,
                caller_function,
                caller_frame,
            );
            callback_call.activateRoots();
            defer callback_call.deinit();
            while (true) {
                if (kind == .flatMap) {
                    if (objectFromValue(values[0]).?.iteratorData()) |inner_iterator| {
                        const inner_next = objectFromValue(values[0]).?.iteratorInnerNext() orelse return error.TypeError;
                        const inner_step = try iteratorStepWithSyncValues(ctx, output, global, inner_iterator, inner_next, caller_function, caller_frame);
                        if (!inner_step.done) return try createIteratorResult(ctx.runtime, global, inner_step.value, false);
                        try iteratorHelperClearInner(ctx.runtime, objectFromValue(values[0]).?);
                    }
                }
                const step = try iteratorStepWithSyncCall(ctx, output, global, &next_call, caller_function, caller_frame);
                if (step.done) {
                    try iteratorHelperClear(ctx.runtime, objectFromValue(values[0]).?);
                    return try createIteratorResult(ctx.runtime, global, core.JSValue.undefinedValue(), true);
                }
                const index = (objectFromValue(values[0]).?.iteratorIndexSlot().*);
                objectFromValue(values[0]).?.iteratorIndexSlot().* += 1;
                values[1] = step.value;
                values[2] = callback_call.call(&.{ values[1], core.JSValue.int32(@intCast(index)) }) catch |err| {
                    return iteratorHelperCloseWithCompletionAndPropagate(ctx, output, global, objectFromValue(values[0]).?, err, caller_function, caller_frame);
                };
                if (kind == .map) return try createIteratorResult(ctx.runtime, global, values[2], false);
                if (kind == .flatMap) {
                    try iteratorHelperSetInner(ctx, output, global, objectFromValue(values[0]).?, values[2], caller_function, caller_frame);
                    continue;
                }
                if (coercion_ops.valueTruthy(values[2])) return try createIteratorResult(ctx.runtime, global, values[1], false);
            }
        },
    }
}

fn iteratorHelperSetInner(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    helper: *core.Object,
    mapped: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !void {
    _ = objectFromValue(mapped) orelse return error.TypeError;
    var values = [_]core.JSValue{ helper.value(), mapped, core.JSValue.undefinedValue(), core.JSValue.undefinedValue() };
    var slots: []core.JSValue = &values;
    const borrowed = [_]core.JSValue{global.value()};
    const slices = [_]core.runtime.ValueRootSlice{ .{ .mutable = &slots }, .{ .borrowed = &borrowed } };
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(ctx.runtime);
    defer roots.deactivate(ctx.runtime);
    const symbol_key = core.atom.predefinedId("Symbol.iterator", .symbol) orelse return error.TypeError;
    values[2] = try object_ops.getValueProperty(ctx, output, global, values[1], symbol_key, caller_function, caller_frame);
    values[3] = if (values[2].is(.undefined_value) or values[2].is(.null_value))
        values[1]
    else blk: {
        if (!call_runtime.isCallableValue(values[2])) return error.TypeError;
        var iterator_call = CallSite.initInternal(ctx, output, global, values[1], values[2], caller_function, caller_frame);
        iterator_call.activateRoots();
        defer iterator_call.deinit();
        const value = try iterator_call.call(&.{});
        _ = objectFromValue(value) orelse return error.TypeError;
        break :blk value;
    };
    try iteratorHelperSetInnerFromIterator(ctx, output, global, objectFromValue(values[0]).?, values[3], caller_function, caller_frame);
}

fn iteratorHelperSetInnerFromIterator(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    helper: *core.Object,
    inner_iterator: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !void {
    _ = objectFromValue(inner_iterator) orelse return error.TypeError;
    var values = [_]core.JSValue{ helper.value(), inner_iterator, core.JSValue.undefinedValue() };
    var slots: []core.JSValue = &values;
    const borrowed = [_]core.JSValue{global.value()};
    const slices = [_]core.runtime.ValueRootSlice{ .{ .mutable = &slots }, .{ .borrowed = &borrowed } };
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(ctx.runtime);
    defer roots.deactivate(ctx.runtime);
    const next_key = core.atom.ids.next;
    values[2] = try object_ops.getValueProperty(ctx, output, global, values[1], next_key, caller_function, caller_frame);
    try objectFromValue(values[0]).?.setOptionalValueSlot(ctx.runtime, objectFromValue(values[0]).?.iteratorDataSlot(), values[1]);
    try objectFromValue(values[0]).?.setOptionalValueSlot(ctx.runtime, objectFromValue(values[0]).?.iteratorInnerNextSlot(), values[2]);
}

pub fn iteratorHelperReturn(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    function_object: *core.Object,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    if (function_object.iteratorHelperMethod() != 2) return null;
    const helper = objectFromValue(receiver) orelse return error.TypeError;
    if (helper.class_id != core.class.ids.iterator_helper) return error.TypeError;
    const borrowed = [_]core.JSValue{global.value()};
    var values = [_]core.JSValue{receiver};
    var slots: []core.JSValue = &values;
    const slices = [_]core.runtime.ValueRootSlice{ .{ .mutable = &slots }, .{ .borrowed = &borrowed } };
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(ctx.runtime);
    defer roots.deactivate(ctx.runtime);
    if (helperKind(objectFromValue(values[0]).?) == .zip or helperKind(objectFromValue(values[0]).?) == .zip_keyed) {
        return try iteratorZipHelperReturn(ctx, output, global, objectFromValue(values[0]).?, caller_function, caller_frame);
    }
    if (objectFromValue(values[0]).?.generatorExecuting()) return error.TypeError;
    objectFromValue(values[0]).?.generatorExecutingSlot().* = true;
    defer objectFromValue(values[0]).?.generatorExecutingSlot().* = false;
    try iteratorHelperClose(ctx, output, global, objectFromValue(values[0]).?, caller_function, caller_frame);
    return try createIteratorResult(ctx.runtime, global, core.JSValue.undefinedValue(), true);
}

fn iteratorHelperClose(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    helper: *core.Object,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !void {
    var values = [_]core.JSValue{helper.value()};
    var slots: []core.JSValue = &values;
    const globals = [_]core.JSValue{global.value()};
    const slices = [_]core.runtime.ValueRootSlice{ .{ .mutable = &slots }, .{ .borrowed = &globals } };
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(ctx.runtime);
    defer roots.deactivate(ctx.runtime);
    try iteratorHelperCloseInner(ctx, output, global, objectFromValue(values[0]).?, caller_function, caller_frame);
    if (helperKind(objectFromValue(values[0]).?) == .concat) {
        try iteratorHelperClear(ctx.runtime, objectFromValue(values[0]).?);
        return;
    }
    const iterator = (objectFromValue(values[0]).?.iteratorTargetSlot().*) orelse return;
    iteratorCloseValue(ctx, output, global, iterator, caller_function, caller_frame) catch |err| {
        try iteratorHelperClear(ctx.runtime, objectFromValue(values[0]).?);
        return err;
    };
    try iteratorHelperClear(ctx.runtime, objectFromValue(values[0]).?);
}

fn iteratorHelperClear(rt: *core.JSRuntime, helper: *core.Object) !void {
    try iteratorHelperClearInner(rt, helper);
    helper.clearOptionalValueSlot(rt, helper.iteratorTargetSlot());
    helper.clearOptionalValueSlot(rt, helper.iteratorNextSlot());
    helper.clearOptionalValueSlot(rt, helper.iteratorCallbackSlot());
    helper.clearOptionalValueSlot(rt, helper.iteratorZipNextsSlot());
    helper.clearOptionalValueSlot(rt, helper.iteratorZipPadsSlot());
    helper.clearOptionalValueSlot(rt, helper.iteratorZipKeysSlot());
}

fn iteratorHelperCloseInner(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    helper: *core.Object,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !void {
    var values = [_]core.JSValue{helper.value()};
    var slots: []core.JSValue = &values;
    const globals = [_]core.JSValue{global.value()};
    const slices = [_]core.runtime.ValueRootSlice{ .{ .mutable = &slots }, .{ .borrowed = &globals } };
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(ctx.runtime);
    defer roots.deactivate(ctx.runtime);
    const inner_iterator = objectFromValue(values[0]).?.iteratorData() orelse return;
    iteratorCloseValue(ctx, output, global, inner_iterator, caller_function, caller_frame) catch |err| {
        try iteratorHelperClearInner(ctx.runtime, objectFromValue(values[0]).?);
        return err;
    };
    try iteratorHelperClearInner(ctx.runtime, objectFromValue(values[0]).?);
}

fn iteratorHelperClearInner(rt: *core.JSRuntime, helper: *core.Object) !void {
    helper.clearOptionalValueSlot(rt, helper.iteratorDataSlot());
    helper.clearOptionalValueSlot(rt, helper.iteratorInnerNextSlot());
}

fn testIteratorGetValuePropertyOptional(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.JSValue,
    key: core.Atom,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    _ = ctx;
    _ = output;
    _ = global;
    _ = caller_function;
    _ = caller_frame;
    const object = try property_ops.expectObject(value);
    return try object.getProperty(key);
}

pub fn iteratorCloseValue(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    iterator_value: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !void {
    try iteratorZipClose(ctx, output, global, iterator_value, caller_function, caller_frame);
}

pub fn iteratorForValue(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    source_value: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    var values = [_]core.JSValue{ source_value, core.JSValue.undefinedValue(), core.JSValue.undefinedValue() };
    var slots: []core.JSValue = &values;
    const globals = [_]core.JSValue{global.value()};
    const slices = [_]core.runtime.ValueRootSlice{ .{ .mutable = &slots }, .{ .borrowed = &globals } };
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(ctx.runtime);
    defer roots.deactivate(ctx.runtime);

    if (values[0].isString()) return core.object.stringIterator(ctx, values[0]);
    const source_object = core.value_semantics.objectFromValue(values[0]);
    if (source_object != null and source_object.?.class_id == core.class.ids.string) return core.object.stringIterator(ctx, values[0]);
    if (source_object != null and
        (source_object.?.class_id == core.class.ids.array_iterator or
            source_object.?.class_id == core.class.ids.string_iterator or
            source_object.?.class_id == core.class.ids.generator or
            source_object.?.class_id == core.class.ids.async_generator))
    {
        return values[0];
    }
    values[1] = try call_runtime.getIteratorMethod(ctx, output, global, values[0]);
    if (!call_runtime.isCallableValue(values[1])) return exception_ops.throwTypeErrorMessage(ctx, global, "value is not iterable");
    values[2] = try call_runtime.callValueOrBytecodeRoot(ctx, output, global, values[0], values[1], &.{}, caller_function, caller_frame);
    _ = try property_ops.expectObject(values[2]);
    try call_runtime.cacheIteratorNextMethod(ctx, output, global, values[2]);
    return values[2];
}

pub const IteratorStepResult = struct {
    result: core.JSValue,
    value: core.JSValue,
    done: bool,
};

pub const IteratorValueDone = struct {
    value: core.JSValue,
    done: bool,
};

pub fn iteratorStepValue(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    iterator_value: core.JSValue,
) !IteratorValueDone {
    var values = [_]core.JSValue{ iterator_value, core.JSValue.undefinedValue(), core.JSValue.undefinedValue(), core.JSValue.undefinedValue() };
    var slots: []core.JSValue = &values;
    const globals = [_]core.JSValue{global.value()};
    const slices = [_]core.runtime.ValueRootSlice{ .{ .mutable = &slots }, .{ .borrowed = &globals } };
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(ctx.runtime);
    defer roots.deactivate(ctx.runtime);

    const iterator = try property_ops.expectObject(values[0]);
    values[2] = if (iterator.cachedIteratorNext(ctx.runtime)) |stored| stored else blk: {
        const next_key = core.atom.ids.next;
        break :blk try object_ops.getValueProperty(ctx, output, global, values[0], next_key, null, null);
    };
    if (!call_runtime.isCallableValue(values[2])) return error.TypeError;
    values[3] = try call_runtime.callValueOrBytecodeRoot(ctx, output, global, values[0], values[2], &.{}, null, null);
    // IteratorStep (ES 7.4.6) reads `done` and `value` off whatever object
    // `next()` returned. There is no class-based dispatch here: a Promise is
    // an ordinary object to the SYNCHRONOUS protocol (unwrapping one would
    // observe its internal state outside the job queue), and a RegExp is too.
    _ = try property_ops.expectObject(values[3]);
    const done_key = core.atom.predefinedId("done", .string).?;
    const done = try object_ops.getValueProperty(ctx, output, global, values[3], done_key, null, null);
    if (value_ops.isTruthy(done)) return .{ .value = core.JSValue.undefinedValue(), .done = true };
    const value_key = core.atom.predefinedId("value", .string).?;
    return .{ .value = try object_ops.getValueProperty(ctx, output, global, values[3], value_key, null, null), .done = false };
}

pub fn iteratorStepResult(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    iterator_value: core.JSValue,
    next_arg: core.JSValue,
) !IteratorStepResult {
    var values = [_]core.JSValue{ iterator_value, next_arg, core.JSValue.undefinedValue(), core.JSValue.undefinedValue() };
    var slots: []core.JSValue = &values;
    const globals = [_]core.JSValue{global.value()};
    const slices = [_]core.runtime.ValueRootSlice{ .{ .mutable = &slots }, .{ .borrowed = &globals } };
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(ctx.runtime);
    defer roots.deactivate(ctx.runtime);

    const iterator = try property_ops.expectObject(values[0]);
    values[2] = if (iterator.cachedIteratorNext(ctx.runtime)) |stored| stored else blk: {
        const next_key = core.atom.ids.next;
        break :blk try object_ops.getValueProperty(ctx, output, global, values[0], next_key, null, null);
    };
    if (!call_runtime.isCallableValue(values[2])) return error.TypeError;
    values[3] = try call_runtime.callValueOrBytecodeRoot(ctx, output, global, values[0], values[2], &.{values[1]}, null, null);
    _ = try property_ops.expectObject(values[3]);
    const done_key = core.atom.predefinedId("done", .string).?;
    const done = try object_ops.getValueProperty(ctx, output, global, values[3], done_key, null, null);
    const is_done = coercion_ops.valueTruthy(done);
    // Unlike IteratorStepValue, the `yield*` caller only needs `value` on the
    // done step (it becomes the delegation's completion value); the not-done
    // step forwards the whole result object via `.result`, so reading `value`
    // there would be an extra observable Get.
    const value = if (is_done) blk: {
        const value_key = core.atom.predefinedId("value", .string).?;
        break :blk try object_ops.getValueProperty(ctx, output, global, values[3], value_key, null, null);
    } else core.JSValue.undefinedValue();
    return .{ .result = values[3], .value = value, .done = is_done };
}

pub fn iteratorCallForNativeRecord(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    id: u32,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    const IteratorIntrinsic = method_ids.iterator.IntrinsicMethod;
    switch (id) {
        @intFromEnum(IteratorIntrinsic.array_iterator_next) => return try arrayIteratorNext(ctx, output, global, receiver),
        @intFromEnum(IteratorIntrinsic.generator_next) => return (try call_runtime.generatorNext(ctx, output, global, receiver, args)) orelse error.TypeError,
        @intFromEnum(IteratorIntrinsic.generator_return) => return (try call_runtime.generatorReturn(ctx, output, global, receiver, args)) orelse error.TypeError,
        @intFromEnum(IteratorIntrinsic.generator_throw) => return (try call_runtime.generatorThrow(ctx, output, global, receiver, args)) orelse error.TypeError,
        else => {},
    }
    switch (id) {
        @intFromEnum(method_ids.iterator.AccessorMethod.constructor_getter),
        @intFromEnum(method_ids.iterator.AccessorMethod.constructor_setter),
        @intFromEnum(method_ids.iterator.AccessorMethod.to_string_tag_getter),
        @intFromEnum(method_ids.iterator.AccessorMethod.to_string_tag_setter),
        => return @as(?core.JSValue, try object_ops.iteratorPrototypeAccessor(ctx, global, receiver, args, id)),
        else => {},
    }
    if (try iteratorStaticCall(ctx, output, global, args, id, caller_function, caller_frame)) |value| return value;
    return object_ops.iteratorPrototypeMethodCall(ctx, output, global, receiver, args, id, caller_function, caller_frame);
}

pub fn iteratorStaticCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    method_id: u32,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    return switch (method_id) {
        @intFromEnum(method_ids.iterator.StaticMethod.from) => try iteratorFromCall(ctx, output, global, args, caller_function, caller_frame),
        @intFromEnum(method_ids.iterator.StaticMethod.concat) => try string_ops.iteratorConcatCall(ctx, output, global, args),
        @intFromEnum(method_ids.iterator.StaticMethod.zip) => try iteratorZipCall(ctx, output, global, args, false, caller_function, caller_frame),
        @intFromEnum(method_ids.iterator.StaticMethod.zip_keyed) => try iteratorZipCall(ctx, output, global, args, true, caller_function, caller_frame),
        else => null,
    };
}

pub fn iteratorFromSourceForIteratorFrom(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    source: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !IteratorFromResult {
    var values = [_]core.JSValue{ source, core.JSValue.undefinedValue(), core.JSValue.undefinedValue(), core.JSValue.undefinedValue() };
    var slots: []core.JSValue = &values;
    const globals = [_]core.JSValue{global.value()};
    const slices = [_]core.runtime.ValueRootSlice{ .{ .mutable = &slots }, .{ .borrowed = &globals } };
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(ctx.runtime);
    defer roots.deactivate(ctx.runtime);

    // Iterator.from is two steps, in this order (ES Iterator.from):
    //   1. GetIteratorFlattenable(O, iterate-string-primitives) — resolve the
    //      source to an iterator, through @@iterator when it has one.
    //   2. OrdinaryHasInstance(%Iterator%, the RESOLVED iterator) — wrap
    //      unless the resolved iterator is already an %Iterator%.
    //
    // Both parts used to be wrong here: the instance test ran against the
    // SOURCE rather than the resolved iterator, and only the branch where the
    // source had no @@iterator could produce a wrapper. So a class that is
    // iterable, returns itself from @@iterator, and is not an %Iterator% —
    // the exact shape of test262 sm/Iterator/from/
    // return-wrapper-if-not-iterator-instance — came back unwrapped, and none
    // of the iterator helpers were reachable on it.
    values[2] = blk: {
        values[1] = try call_runtime.getIteratorMethod(ctx, output, global, values[0]);
        if (values[0].isString()) {
            break :blk try call_runtime.callValueOrBytecodeRoot(ctx, output, global, values[0], values[1], &.{}, caller_function, caller_frame);
        }
        const source_object = object_ops.objectFromValue(values[0]) orelse return error.TypeError;
        if (values[1].is(.undefined_value) or values[1].is(.null_value)) {
            break :blk source_object.value();
        }
        if (!call_runtime.isCallableValue(values[1])) return error.TypeError;
        const iterator = try call_runtime.callValueOrBytecodeRoot(ctx, output, global, values[0], values[1], &.{}, caller_function, caller_frame);
        _ = object_ops.objectFromValue(iterator) orelse return error.TypeError;
        break :blk iterator;
    };

    if (object_ops.iteratorIsOnIteratorPrototypeChain(ctx.runtime, global, values[2])) {
        return .{ .iterator = values[2] };
    }

    const next_key = core.atom.ids.next;
    values[3] = try object_ops.getValueProperty(ctx, output, global, values[2], next_key, caller_function, caller_frame);
    return .{ .iterator = values[2], .next_method = values[3], .wrap = true };
}

const IteratorWrapKind = enum { next, return_ };

/// Leftover Iterator.from wrap next/return. candidate104 still compiles
/// `iteratorWrapNext` (720) / `iteratorWrapReturn` (766, extra 720,
/// 4.6% match). The leftover is method-id check + wrap object + target
/// + get method + call + object result. Comptime identity is next
/// (cached method) vs return (missing-return result). Take that at
/// runtime. Public names stay `inline` and pass only the kind — no
/// leftover setup at the wrapper (knives 94/98).
noinline fn iteratorWrapMethodCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    function_object: *core.Object,
    kind: IteratorWrapKind,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    const expected: u8 = switch (kind) {
        .next => 1,
        .return_ => 2,
    };
    if (function_object.functionIteratorWrapMethod() != expected) return null;
    var values = [_]core.JSValue{ receiver, core.JSValue.undefinedValue(), core.JSValue.undefinedValue() };
    var slots: []core.JSValue = &values;
    const globals = [_]core.JSValue{global.value()};
    const slices = [_]core.runtime.ValueRootSlice{ .{ .mutable = &slots }, .{ .borrowed = &globals } };
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(ctx.runtime);
    defer roots.deactivate(ctx.runtime);
    const wrapper = object_ops.objectFromValue(values[0]) orelse return error.TypeError;
    if (wrapper.class_id != core.class.ids.iterator_wrap) return error.TypeError;
    values[1] = (wrapper.iteratorTargetSlot().*) orelse return error.TypeError;
    values[2] = switch (kind) {
        .next => if (wrapper.iteratorNext()) |stored| stored else blk: {
            const next_key = core.atom.ids.next;
            const next_method = try object_ops.getValueProperty(ctx, output, global, values[1], next_key, caller_function, caller_frame);
            if (!call_runtime.isCallableValue(next_method)) return error.TypeError;
            break :blk next_method;
        },
        .return_ => blk: {
            const return_key = core.atom.ids.return_;
            const return_method = try object_ops.getValueProperty(ctx, output, global, values[1], return_key, caller_function, caller_frame);
            if (return_method.is(.undefined_value) or return_method.is(.null_value)) {
                return try createIteratorResult(ctx.runtime, global, core.JSValue.undefinedValue(), true);
            }
            if (!call_runtime.isCallableValue(return_method)) return error.TypeError;
            break :blk return_method;
        },
    };
    const result = try call_runtime.callValueOrBytecodeRoot(ctx, output, global, values[1], values[2], &.{}, caller_function, caller_frame);
    _ = object_ops.objectFromValue(result) orelse return error.TypeError;
    return result;
}

pub inline fn iteratorWrapNext(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    function_object: *core.Object,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    return iteratorWrapMethodCall(ctx, output, global, receiver, function_object, .next, caller_function, caller_frame);
}

pub inline fn iteratorWrapReturn(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    function_object: *core.Object,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    return iteratorWrapMethodCall(ctx, output, global, receiver, function_object, .return_, caller_function, caller_frame);
}

/// The single owner of ES `CreateIterResultObject` (7.4.14). `value` stays a
/// borrow: the installed slot takes its own reference.
///
/// `global` is optional because the bare-runtime iterator paths have no realm
/// to resolve `%Object.prototype%` from. Passing null yields a null-prototype
/// result, which is a deviation — spelled out at those call sites rather than
/// reached by accident. Four hand-written copies of this operation used to
/// exist; two of them (Map/Set and String iterators) shipped null-prototype
/// results for years, so `.hasOwnProperty` on an iterator result threw.
pub noinline fn createIteratorResult(rt: *core.JSRuntime, global: ?*core.Object, value: core.JSValue, done: bool) !core.JSValue {
    var values = [_]core.JSValue{ if (global) |realm| realm.value() else core.JSValue.undefinedValue(), value, core.JSValue.undefinedValue() };
    const slots: []core.JSValue = &values;
    const slices = [_]core.runtime.ValueRootSlice{.{ .mutable = &slots }};
    var root_frame = core.runtime.ValueRootFrame{ .slices = &slices };
    root_frame.activate(rt);
    defer root_frame.deactivate(rt);

    // QuickJS's js_create_iterator_result uses an ordinary object followed by
    // the `value` and `done` transitions; iterator results are not one of the
    // five initial Shapes owned by JSContext.
    values[2] = (try core.Object.createPlainObjectReserved2(
        rt,
        if (core.value_semantics.objectFromValue(values[0])) |realm| object_ops.objectPrototypeFromGlobal(rt, realm) else null,
    )).value();
    try core.value_semantics.objectFromValue(values[2]).?.defineOwnPropertyAssumingNew(
        rt,
        core.atom.ids.value,
        core.Descriptor.data(values[1], .all),
    );
    try core.value_semantics.objectFromValue(values[2]).?.defineOwnPropertyAssumingNew(
        rt,
        core.atom.ids.done,
        core.Descriptor.data(core.JSValue.boolean(done), .all),
    );
    return values[2];
}

pub fn closeIteratorForFromEntriesAbrupt(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    iterator_value: core.JSValue,
) !void {
    if (ctx.exceptionIsUncatchable()) return;
    const globals = [_]core.JSValue{global.value()};
    var values = [_]core.JSValue{ iterator_value, core.JSValue.undefinedValue(), core.JSValue.undefinedValue() };
    const live: []core.JSValue = &values;
    const slices = [_]core.runtime.ValueRootSlice{ .{ .borrowed = &globals }, .{ .mutable = &live } };
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(ctx.runtime);
    defer roots.deactivate(ctx.runtime);
    const had_exception = ctx.hasException();
    const was_out_of_memory = ctx.exceptionIsOutOfMemory();
    if (had_exception) values[2] = ctx.takeException();
    defer {
        if (ctx.hasException()) ctx.clearException();
        if (had_exception) {
            _ = ctx.throwValue(values[2]);
            if (was_out_of_memory) ctx.markExceptionOutOfMemory();
        }
    }
    // IteratorClose (ECMA-262 7.4.11): the incoming throw completion wins
    // over GetMethod/Call failures. The caller retains its original Zig error;
    // the actual exception slot above survives GC during return lookup/call.
    const return_key = core.atom.ids.return_;
    values[1] = object_ops.getValueProperty(ctx, output, global, values[0], return_key, null, null) catch return;
    if (values[1].is(.undefined_value) or values[1].is(.null_value)) return;
    if (!call_runtime.isCallableValue(values[1])) return;
    _ = call_runtime.callValueOrBytecodeRoot(ctx, output, global, values[0], values[1], &.{}, null, null) catch return;
}

test "createIteratorResult roots direct function bytecode value while creating result" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const symbol_atom = try rt.atoms.newValueSymbol("gc-closure-iterator-result-bytecode-symbol");
    const fb = try bytecode.FunctionBytecode.createPublishedFixture(rt, .{ .cpool_count = 1 }, &.{try rt.takeSymbolValue(symbol_atom)});

    const result_value = core.JSValue.functionBytecode(&fb.header);

    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const iterator_result_value = try createIteratorResult(rt, null, result_value, false);
    const iterator_result = try core.value_semantics.expectObject(iterator_result_value);

    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    const value_atom = try rt.internAtom("value");
    {
        const stored = try iterator_result.getProperty(value_atom);
        try std.testing.expect(stored.same(result_value));
    }

    _ = rt.collectForTest();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

// ----- merged from iterator_slots.zig -----
// Typed views over the three small integer slots of an iterator payload
// (`kind`, `zip_mode`, `zip_state`). The payload stores bare bytes because
// every iterator class shares one payload struct; what a byte means depends
// on the class, and these accessors are the only place that knowledge lives.
const Object = core.Object;
pub const ArrayIteratorKind = enum(u8) {
    key = 1,
    value = 2,
    key_value = 3,
};
pub const CollectionIteratorKind = enum(u8) {
    key = 1,
    value = 2,
    key_value = 3,
};
pub const IteratorHelperKind = enum(u8) {
    map = 1,
    filter = 2,
    take = 3,
    drop = 4,
    flatMap = 5,
    concat = 6,
    zip = 7,
    zip_keyed = 8,
};
pub const IteratorZipMode = enum(u8) {
    shortest = 0,
    longest = 1,
    strict = 2,
};
pub const ZipState = enum(u8) {
    /// Created, no `next` yet.
    fresh = 0,
    /// Last `next` produced a result.
    yielded = 1,
    /// A `next`/`return` is executing (re-entry is a TypeError).
    running = 2,
    /// Closed, every further `next` reports done.
    done = 3,
};
pub const RegExpStringIteratorFlags = packed struct(u8) {
    global: bool = false,
    unicode: bool = false,
    _reserved: u6 = 0,
};
pub fn arrayIteratorKind(iterator: *const Object) ArrayIteratorKind {
    return @enumFromInt(iterator.iteratorKind());
}

pub fn setArrayIteratorKind(iterator: *Object, kind: ArrayIteratorKind) void {
    iterator.iteratorKindSlot().* = @intFromEnum(kind);
}

pub fn collectionIteratorKind(iterator: *const Object) ?CollectionIteratorKind {
    return std.enums.fromInt(CollectionIteratorKind, iterator.iteratorKind());
}

pub fn setCollectionIteratorKind(iterator: *Object, kind: CollectionIteratorKind) void {
    iterator.iteratorKindSlot().* = @intFromEnum(kind);
}

pub fn helperKind(helper: *const Object) IteratorHelperKind {
    return @enumFromInt(helper.iteratorKind());
}

pub fn setHelperKind(helper: *Object, kind: IteratorHelperKind) void {
    helper.iteratorKindSlot().* = @intFromEnum(kind);
}

pub fn zipMode(helper: *const Object) IteratorZipMode {
    return @enumFromInt(helper.iteratorZipMode());
}

pub fn setZipMode(helper: *Object, mode: IteratorZipMode) void {
    helper.iteratorZipModeSlot().* = @intFromEnum(mode);
}

pub fn zipState(helper: *const Object) ZipState {
    return @enumFromInt(helper.iteratorZipState());
}

pub fn setZipState(helper: *Object, state: ZipState) void {
    helper.iteratorZipStateSlot().* = @intFromEnum(state);
}

pub fn regExpStringIteratorFlags(iterator: *const Object) RegExpStringIteratorFlags {
    return @bitCast(iterator.iteratorKind());
}

pub fn setRegExpStringIteratorFlags(iterator: *Object, flags: RegExpStringIteratorFlags) void {
    iterator.iteratorKindSlot().* = @bitCast(flags);
}

// ----- merged from iterator_builtin_ops.zig -----
// Iterator builtin declaration table and native-record dispatch seam.
//
// Domain-local ids cover Iterator statics, helpers, accessors, disposal, and
// intrinsic iterator/generator methods. Algorithms and iterator-close
// ownership live in this file with the registry identity, which forwards the
// active realm/caller context.
const builtin_dispatch = @import("builtin_dispatch.zig");
pub const AccessorMethod = core.host_function.builtin_method_ids.iterator.AccessorMethod;
pub const StaticMethod = core.host_function.builtin_method_ids.iterator.StaticMethod;
pub const PrototypeMethod = core.host_function.builtin_method_ids.iterator.PrototypeMethod;
pub const IntrinsicMethod = core.host_function.builtin_method_ids.iterator.IntrinsicMethod;
pub fn staticMethodId(name: []const u8) ?u32 {
    if (std.mem.eql(u8, name, "from")) return @intFromEnum(StaticMethod.from);
    if (std.mem.eql(u8, name, "concat")) return @intFromEnum(StaticMethod.concat);
    if (std.mem.eql(u8, name, "zip")) return @intFromEnum(StaticMethod.zip);
    if (std.mem.eql(u8, name, "zipKeyed")) return @intFromEnum(StaticMethod.zip_keyed);
    return null;
}

pub fn prototypeMethodId(name: []const u8) ?u32 {
    if (std.mem.eql(u8, name, "toArray")) return @intFromEnum(PrototypeMethod.to_array);
    if (std.mem.eql(u8, name, "every")) return @intFromEnum(PrototypeMethod.every);
    if (std.mem.eql(u8, name, "find")) return @intFromEnum(PrototypeMethod.find);
    if (std.mem.eql(u8, name, "forEach")) return @intFromEnum(PrototypeMethod.for_each);
    if (std.mem.eql(u8, name, "reduce")) return @intFromEnum(PrototypeMethod.reduce);
    if (std.mem.eql(u8, name, "some")) return @intFromEnum(PrototypeMethod.some);
    if (std.mem.eql(u8, name, "map")) return @intFromEnum(PrototypeMethod.map);
    if (std.mem.eql(u8, name, "filter")) return @intFromEnum(PrototypeMethod.filter);
    if (std.mem.eql(u8, name, "take")) return @intFromEnum(PrototypeMethod.take);
    if (std.mem.eql(u8, name, "drop")) return @intFromEnum(PrototypeMethod.drop);
    if (std.mem.eql(u8, name, "flatMap")) return @intFromEnum(PrototypeMethod.flat_map);
    return null;
}

/// Declaration + dispatch table for the `.iterator` native-builtin domain
/// (QuickJS js_iterator_proto_funcs / js_iterator_funcs analogue). One shared
/// record handler `iteratorCallNative` switches on the per-record `magic`
/// (== domain-local id) and forwards to the iterator-helper VM ops, which stay
/// in exec because they interleave with the iterator protocol (next/close) and
/// the static helpers reach the for-of machinery. Standard-global bootstrap
/// resolves names through its iterator static/prototype method lists plus the
/// accessor/dispose enum ids; this table is consumed by the record-dispatch
/// path (`internal_builtins.table`).
pub const internal_entries = iteratorEntries: {
    const Entry = core.host_function.InternalEntry;
    break :iteratorEntries [_]Entry{
        iteratorEntry("get constructor", 0, @intFromEnum(AccessorMethod.constructor_getter)),
        iteratorEntry("set constructor", 1, @intFromEnum(AccessorMethod.constructor_setter)),
        iteratorEntry("get [Symbol.toStringTag]", 0, @intFromEnum(AccessorMethod.to_string_tag_getter)),
        iteratorEntry("set [Symbol.toStringTag]", 1, @intFromEnum(AccessorMethod.to_string_tag_setter)),
        iteratorEntry("from", 1, @intFromEnum(StaticMethod.from)),
        iteratorEntry("concat", 0, @intFromEnum(StaticMethod.concat)),
        iteratorEntry("zip", 1, @intFromEnum(StaticMethod.zip)),
        iteratorEntry("zipKeyed", 1, @intFromEnum(StaticMethod.zip_keyed)),
        iteratorEntry("toArray", 0, @intFromEnum(PrototypeMethod.to_array)),
        iteratorEntry("every", 1, @intFromEnum(PrototypeMethod.every)),
        iteratorEntry("find", 1, @intFromEnum(PrototypeMethod.find)),
        iteratorEntry("forEach", 1, @intFromEnum(PrototypeMethod.for_each)),
        iteratorEntry("reduce", 1, @intFromEnum(PrototypeMethod.reduce)),
        iteratorEntry("some", 1, @intFromEnum(PrototypeMethod.some)),
        iteratorEntry("map", 1, @intFromEnum(PrototypeMethod.map)),
        iteratorEntry("filter", 1, @intFromEnum(PrototypeMethod.filter)),
        iteratorEntry("take", 1, @intFromEnum(PrototypeMethod.take)),
        iteratorEntry("drop", 1, @intFromEnum(PrototypeMethod.drop)),
        iteratorEntry("flatMap", 1, @intFromEnum(PrototypeMethod.flat_map)),
        iteratorEntry("[Symbol.dispose]", 0, @intFromEnum(PrototypeMethod.dispose)),
        iteratorEntry("Array Iterator.next", 0, @intFromEnum(IntrinsicMethod.array_iterator_next)),
        iteratorEntry("Generator.next", 1, @intFromEnum(IntrinsicMethod.generator_next)),
        iteratorEntry("Generator.return", 1, @intFromEnum(IntrinsicMethod.generator_return)),
        iteratorEntry("Generator.throw", 1, @intFromEnum(IntrinsicMethod.generator_throw)),
    };
};
fn iteratorEntry(comptime name: []const u8, comptime length: u8, comptime id: u32) core.host_function.InternalEntry {
    return .{
        .name = name,
        .length = length,
        .id = id,
        .magic = @intCast(id),
        .cproto = .generic_magic,
        .native_function = builtin_dispatch.genericMagicFunction(&iteratorCallNative),
    };
}

/// Shared record handler for the `.iterator` domain. Mirrors the retired
/// `call.zig` `callIteratorNativeFunctionRecord`: it resolves the active realm
/// global and forwards to `iteratorCallForNativeRecord`, which
/// dispatches the accessors, static helpers, and prototype helper methods. A
/// null result means the id resolved to no handler, which only happens for a
/// corrupt id, so it surfaces as a TypeError.
fn iteratorCallNative(
    native_ctx: *core.JSContext,
    native_this: core.JSValue,
    native_args: []const core.JSValue,
    native_magic: i32,
) HostError!core.JSValue {
    const host_call = builtin_dispatch.nativeCall(native_ctx, native_this, native_args, native_magic) orelse return error.TypeError;
    const realm = try builtin_dispatch.callableRealm(host_call);
    const ctx = realm.realm;
    const id: u32 = host_call.magic;
    const caller_function = builtin_dispatch.callerBytecode(host_call);
    const caller_frame = builtin_dispatch.callerFrame(host_call);
    if (try iteratorCallForNativeRecord(ctx, host_call.output, realm.global, host_call.this_value, id, host_call.args, caller_function, caller_frame)) |value| return value;
    return error.TypeError;
}

test "intrinsic iterator next methods have dedicated native records" {
    const testing = std.testing;
    const expected_ids = [_]u32{
        @intFromEnum(IntrinsicMethod.array_iterator_next),
        @intFromEnum(IntrinsicMethod.generator_next),
        @intFromEnum(IntrinsicMethod.generator_return),
        @intFromEnum(IntrinsicMethod.generator_throw),
    };
    for (expected_ids) |expected_id| {
        var handler: ?core.host_function.NativeFunctionPtr = null;
        for (internal_entries) |entry| {
            if (entry.id == expected_id) handler = entry.native_function;
        }
        try testing.expect(handler != null);
        const native = handler.?;
        try testing.expectEqual(core.host_function.NativeCProto.generic_magic, std.meta.activeTag(native));
        try testing.expect(native.generic_magic == &iteratorCallNative);
    }
}

// ----- merged from forof_ops.zig -----
// for-in/for-of iterator records, pending-error iterator close paths and VM iterator helpers.
const appendAtom = core.atom.appendAtom;
const callValueOrBytecodeRoot = call_runtime.callValueOrBytecodeRoot;
const freeAtomList = core.atom.freeAtomList;
const objectRestOwnKeys = object_ops.objectRestOwnKeys;
const primitiveObjectForAccess = object_ops.primitiveObjectForAccess;
const proxyAwareOwnPropertyDescriptor = object_ops.proxyAwareOwnPropertyDescriptor;
pub fn forInIsArraySlot(iterator: *core.Object) *u8 {
    return iterator.iteratorZipModeSlot();
}

/// qjs `it->in_prototype_chain` (JSForInIterator).
pub fn forInInProtoChainSlot(iterator: *core.Object) *u8 {
    return iterator.iteratorZipStateSlot();
}

/// Mirrors qjs build_for_in_iterator: snapshot ONLY the root
/// object's own string keys (JS_GPN_STRING_MASK | JS_GPN_SET_ENUM); the
/// prototype chain is walked LAZILY by forInNext (js_for_in_next
/// quickjs.c), one prototype at a time.
pub fn createForInIterator(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    object_value: core.JSValue,
) !core.JSValue {
    const rt = ctx.runtime;

    var iterator_val = core.JSValue.undefinedValue();
    var source_val = core.JSValue.undefinedValue();
    var root_frame = core.runtime.rootValues(.{ &iterator_val, &source_val });
    root_frame.activate(rt);
    defer root_frame.deactivate(rt);

    const iterator = try core.Object.create(rt, core.class.ids.for_in_iterator, null);
    errdefer core.Object.destroyFromHeader(rt, iterator.gcHeader());
    iterator_val = iterator.value();

    // it->is_array = FALSE; it->obj = obj; it->idx = 0; it->tab_atom = NULL;
    // it->atom_count = 0; it->in_prototype_chain = FALSE
    iterator.iteratorKindSlot().* = for_in_iterator_kind;
    iterator.iteratorIndexSlot().* = 0;
    iterator.setIteratorLength(0);
    forInIsArraySlot(iterator).* = 0;
    forInInProtoChainSlot(iterator).* = 0;

    // null/undefined: it->obj stays null and the first next() reports done
    if (object_value.is(.null_value) or object_value.is(.undefined_value)) return iterator.value();

    // JS_ToObjectFree for primitives.
    source_val = if (object_value.is(.object)) object_value else try primitiveObjectForAccess(rt, global, object_value);
    const source = try property_ops.expectObject(source_val);
    try iterator.setOptionalValueSlot(rt, iterator.iteratorTargetSlot(), source_val);

    if (forInFastArrayCount(rt, source)) |count| {
        // "for fast arrays, we only store the number of elements"
        //; index keys are generated on the fly.
        forInIsArraySlot(iterator).* = 1;
        iterator.setIteratorLength(count);
    } else {
        // normal_case.
        const keys = try forInSnapshotOwnStringKeys(ctx, output, global, source, iterator);
        iterator.iteratorAtomKeysSlot().* = keys;
        iterator.setIteratorLength(std.math.cast(u32, keys.len) orelse return error.OutOfMemory);
    }
    return iterator.value();
}

/// The `p->fast_array` branch of build_for_in_iterator:
/// a fast array (zjs dense array / typed array) with no enumerable shape
/// props stores only the element count. Returns null for the normal case.
fn forInFastArrayCount(rt: *core.JSRuntime, source: *core.Object) ?u32 {
    if (core.object.isTypedArrayObject(source)) {
        // "check that there are no enumerable normal fields".
        for (source.shapeProps()) |prop| {
            const prop_flags = core.property.Flags.fromBits(prop.flags);
            if (!prop_flags.deleted and prop_flags.enumerable) return null;
        }
        return core.object.typedArrayLength(rt, source) catch 0;
    }
    if (!source.isArray() or !source.flags.fast_array) return null;
    if (source.isProxy() or source.hasExoticMethods()) return null;
    for (source.shapeProps()) |prop| {
        const prop_flags = core.property.Flags.fromBits(prop.flags);
        if (prop_flags.deleted) continue;
        if (prop_flags.enumerable) return null;
        // qjs fast arrays never carry shape-resident index props; if zjs has
        // any (sparse remnants) the normal snapshot must merge them.
        if (core.array.arrayIndexFromAtom(rt.atoms, prop.atom_id) != null) return null;
    }
    return std.math.cast(u32, source.arrayElements().len) orelse null;
}

/// Mirrors JS_GetOwnPropertyNamesInternal(ctx, &tab, &n, obj,
/// JS_GPN_STRING_MASK | JS_GPN_SET_ENUM) as consumed by the for-in machinery
/// (build_for_in_iterator quickjs.c, the js_for_in_next prototype step
/// quickjs.c and the is_array conversion quickjs.c). Returns the
/// enumerable own string keys in tab order (owned atoms). qjs keeps the
/// non-enumerable tab entries only to feed the visited-key set on the enum
/// object (quickjs.c, always behind a dedup
/// check); we record those straight onto the iterator's visited set here
/// instead of carrying a parallel is_enumerable array.
pub fn forInSnapshotOwnStringKeys(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    object: *core.Object,
    iterator: *core.Object,
) ![]core.Atom {
    const rt = ctx.runtime;
    const all = try objectRestOwnKeys(ctx, output, global, object);
    defer core.Object.freeKeys(rt, all);
    var out: []core.Atom = &.{};
    errdefer freeAtomList(rt, out);
    // TGC S3 §4 class B: `out` and the `all` snapshot are native []Atom
    // arrays held across a per-key [[GetOwnProperty]] that can reach a proxy
    // trap.
    var key_roots = core.runtime.rootAtomSlots(.{
        core.runtime.AtomRootSlot{ .list = &out },
        core.runtime.AtomRootSlot{ .list = &all },
    });
    key_roots.activate(rt);
    defer key_roots.deactivate(rt);
    for (all) |key| {
        // JS_GPN_STRING_MASK: array-index atoms are string kind (JS_AtomGetKind).
        if (rt.atoms.kind(key) != .string) continue;
        if (try forInOwnKeyIsEnumerable(ctx, output, global, object, key)) {
            try appendAtom(rt, &out, key);
        } else {
            try forInDefineVisited(rt, iterator, key);
        }
    }
    return out;
}

/// Per-key is_enumerable of the SET_ENUM walk. Ordinary objects read the
/// shape flag; proxies/exotics run the full
/// [[GetOwnProperty]] (quickjs.c "set the is_enumerable field if
/// necessary"), so the gopd trap order/count matches qjs. A key whose
/// descriptor probe reports absence counts as non-enumerable.
fn forInOwnKeyIsEnumerable(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    object: *core.Object,
    key: core.Atom,
) !bool {
    if (object.proxyTarget() == null) {
        switch (object.ownPropertyEnumerableKind(ctx.runtime, key)) {
            .enumerable => return true,
            .not_enumerable => return false,
            .descriptor => {},
        }
    }
    const desc = try proxyAwareOwnPropertyDescriptor(ctx, output, global, object, key, null, null) orelse return false;
    const is_enumerable = desc.enumerable orelse false;
    return is_enumerable;
}

/// JS_DefinePropertyValue(ctx, enum_obj, prop, JS_NULL, JS_PROP_ENUMERABLE):
/// the visited-key set lives as JS_NULL-valued props on the iterator object
/// itself (js_for_in_next quickjs.c, prepare slow_path quickjs.c).
/// qjs only ever defines a visited key after a dedup miss; the exists guard
/// keeps redefinition of the non-configurable marker impossible.
pub fn forInDefineVisited(rt: *core.JSRuntime, iterator: *core.Object, key: core.Atom) !void {
    if (try iterator.existsOwnProperty(rt, key)) return;
    try iterator.defineOwnProperty(rt, key, core.Descriptor.data(core.JSValue.nullValue(), .{ .enumerable = true }));
}

/// The JS_GPN_STRING_MASK | JS_GPN_ENUM_ONLY probe of
/// js_for_in_prepare_prototype_chain_enum: does this
/// prototype own at least one enumerable string-keyed property? Ordinary
/// objects reduce to a shape/dense scan (the same walk qjs's
/// JS_GetOwnPropertyNamesInternal does off the shape, quickjs.c);
/// proxies/exotics run the full filtered-tab construction so ownKeys + the
/// per-key gopd probes fire exactly as in qjs (the tab is discarded,
/// quickjs.c).
pub fn forInHasEnumerableStringKey(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    object: *core.Object,
) !bool {
    const rt = ctx.runtime;
    if (core.object.isTypedArrayObject(object)) {
        // fast_array branch: every element is an
        // enumerable index key.
        if ((core.object.typedArrayLength(rt, object) catch 0) != 0) return true;
    } else if (object.proxyTarget() != null or object.hasExoticMethods() or
        object.class_id == core.class.ids.module_ns)
    {
        // Exotic own-keys behavior: build-and-discard the filtered tab like
        // qjs. No early exit -- qjs probes every string key's descriptor.
        const all = try objectRestOwnKeys(ctx, output, global, object);
        defer core.Object.freeKeys(rt, all);
        var found = false;
        for (all) |key| {
            if (rt.atoms.kind(key) != .string) continue;
            if (try forInOwnKeyIsEnumerable(ctx, output, global, object, key)) found = true;
        }
        return found;
    } else if (object.arrayElements().len != 0) {
        // dense array elements are enumerable index keys.
        return true;
    }
    for (object.shapeProps()) |prop| {
        const prop_flags = core.property.Flags.fromBits(prop.flags);
        if (prop_flags.deleted or !prop_flags.enumerable) continue;
        if (rt.atoms.kind(prop.atom_id) != .string) continue;
        return true;
    }
    return false;
}

/// Iterator records share JSValue's internal catch-offset tag with ordinary
/// catch markers, but use the otherwise-invalid payload range below -1. This
/// preserves the saved outer catch target while giving unwind code an exact
/// record discriminator instead of guessing from adjacent object/callable
/// shapes. -2 identifies an async iterator; sync records use minInt...-3.
const async_iterator_catch_offset: i32 = -2;
pub fn iteratorCatchMarker(previous_target: i32) core.JSValue {
    std.debug.assert(previous_target >= -1);
    std.debug.assert(previous_target <= std.math.maxInt(i32) - 3);
    const encoded: i32 = if (previous_target == -1)
        std.math.minInt(i32)
    else
        @intCast(@as(i64, std.math.minInt(i32)) + @as(i64, previous_target) + 1);
    return core.JSValue.catchOffset(encoded);
}

pub fn iteratorCatchMarkerPreviousTarget(value: core.JSValue) ?i32 {
    const encoded = value.as(.catch_offset) orelse return null;
    if (encoded >= async_iterator_catch_offset) return null;
    if (encoded == std.math.minInt(i32)) return -1;
    return @intCast(@as(i64, encoded) - @as(i64, std.math.minInt(i32)) - 1);
}

pub fn asyncIteratorCatchMarker() core.JSValue {
    return core.JSValue.catchOffset(async_iterator_catch_offset);
}

pub fn isAsyncIteratorCatchMarker(value: core.JSValue) bool {
    return (value.as(.catch_offset) orelse return false) == async_iterator_catch_offset;
}

pub fn isIteratorCatchMarker(value: core.JSValue) bool {
    return isAsyncIteratorCatchMarker(value) or iteratorCatchMarkerPreviousTarget(value) != null;
}

test "iterator catch markers are distinct from ordinary catch offsets" {
    for ([_]i32{ -1, 0, 42 }) |ordinary| {
        try std.testing.expect(!isIteratorCatchMarker(core.JSValue.catchOffset(ordinary)));
    }
    for ([_]i32{ -1, 0, 42 }) |previous| {
        const marker = iteratorCatchMarker(previous);
        try std.testing.expect(isIteratorCatchMarker(marker));
        try std.testing.expect(!isAsyncIteratorCatchMarker(marker));
        try std.testing.expectEqual(previous, iteratorCatchMarkerPreviousTarget(marker).?);
    }
    const async_marker = asyncIteratorCatchMarker();
    try std.testing.expect(isIteratorCatchMarker(async_marker));
    try std.testing.expect(isAsyncIteratorCatchMarker(async_marker));
    try std.testing.expect(iteratorCatchMarkerPreviousTarget(async_marker) == null);
}

pub fn closeStackTopForOfIteratorForPendingError(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
) !void {
    // QuickJS uncatchable interruptions skip the catch-offset/iterator-close
    // stack scan entirely. In particular, do not take/rethrow the pending
    // InternalError here: that would clear its uncatchable execution flag and
    // allow an outer catch/finally to consume it.
    if (ctx.exceptionIsUncatchable()) return;
    // The pending exception is taken and re-thrown unchanged below, so its
    // category has to survive the round trip: `takeException` and `throwValue`
    // both reset the exception flags. Uncatchability dodges this by returning
    // above; out-of-memory cannot (the iterators still have to be closed), so
    // read the flag here and restore it with the value. Without this an
    // uncaught OOM inside a for-of body reaches the embedder as a plain
    // `error.JSException`.
    const pending_out_of_memory = ctx.exceptionIsOutOfMemory();
    const pending_exception = if (ctx.hasException()) ctx.takeException() else null;
    var before = stack.len();
    while (findTopClosableForOfRecordIndexBefore(stack, before)) |record_index| {
        // Transfer the record's iterator ownership out before invoking user
        // code. Besides matching IteratorClose's one-shot semantics, this
        // prevents a later catch/unwind/deinit seam from calling return()
        // again for the same abrupt completion.
        const iterator_value = stack.values[record_index];
        stack.values[record_index] = core.JSValue.undefinedValue();
        closeIteratorFromVm(ctx, output, global, iterator_value) catch {};
        if (ctx.hasException()) ctx.clearException();
        before = record_index;
    }
    if (pending_exception) |value| {
        _ = ctx.throwValue(value);
        if (pending_out_of_memory) ctx.markExceptionOutOfMemory();
    }
}

/// Run IteratorClose for an abrupt completion without letting a close failure
/// replace the exception that was already pending on the context.
pub fn closeIteratorForAbruptCompletion(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    iterator_value: core.JSValue,
) void {
    if (ctx.exceptionIsUncatchable()) return;
    const pending_out_of_memory = ctx.exceptionIsOutOfMemory();
    const pending_exception = if (ctx.hasException()) ctx.takeException() else null;
    closeIteratorFromVm(ctx, output, global, iterator_value) catch {};
    if (ctx.hasException()) ctx.clearException();
    if (pending_exception) |value| {
        _ = ctx.throwValue(value);
        if (pending_out_of_memory) ctx.markExceptionOutOfMemory();
    }
}

fn findTopClosableForOfRecordIndexBefore(stack: *const stack_mod.Stack, before: usize) ?usize {
    const end = @min(before, stack.len());
    if (end < 3) return null;
    var index = end - 3;
    while (true) {
        if (isForOfRecordAt(stack, index) and !hasCatchMarkerAboveForOfRecord(stack, index)) {
            return index;
        }
        if (index == 0) break;
        index -= 1;
    }
    return null;
}

pub fn isForOfRecordAt(stack: *const stack_mod.Stack, index: usize) bool {
    if (index + 2 >= stack.len()) return false;
    return isIteratorCatchMarker(stack.values[index + 2]);
}

/// QuickJS `js_for_of_next` replaces the current iterator with undefined on
/// every IteratorNext abrupt completion. That prevents IteratorClose from
/// calling `return()` on the iterator whose `next`/result access just failed,
/// while leaving any enclosing iterator records available for normal unwind.
pub fn abandonForOfIteratorAtIndex(stack: *stack_mod.Stack, index: usize) void {
    std.debug.assert(isForOfRecordAt(stack, index));
    stack.values[index] = core.JSValue.undefinedValue();
}

/// The `*JSRuntime` is unused (abandoning is a pure stack-slot overwrite under
/// tracing GC); it stays in the signature so the VM unwind call sites in
/// `tailcall_dispatch` / `inline_calls` keep their uniform `(vm.ctx.runtime,
/// stack, depth)` shape.
pub fn abandonForOfIteratorAtDepth(_: *core.JSRuntime, stack: *stack_mod.Stack, depth: u8) !void {
    const required = @as(usize, depth) + 3;
    if (stack.len() < required) return error.InvalidBytecode;
    const index = stack.len() - required;
    if (!isForOfRecordAt(stack, index)) return error.InvalidBytecode;
    abandonForOfIteratorAtIndex(stack, index);
}

pub fn hasCatchMarkerAboveForOfRecord(stack: *const stack_mod.Stack, record_index: usize) bool {
    var index = record_index + 3;
    while (index < stack.len()) : (index += 1) {
        if (!stack.values[index].is(.catch_offset)) continue;
        // Nested iterator markers are cleanup records, not catch boundaries.
        if (isIteratorCatchMarker(stack.values[index])) continue;
        return true;
    }
    return false;
}

pub fn closeIteratorFromVm(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    iterator_value: core.JSValue,
) !void {
    try closeIteratorFromVmImpl(ctx, output, global, iterator_value);
}

pub fn closeIteratorFromVmImpl(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    iterator_value: core.JSValue,
) !void {
    const return_key = core.atom.ids.return_;
    const return_method = try object_ops.getValueProperty(ctx, output, global, iterator_value, return_key, null, null);
    if (return_method.is(.undefined_value) or return_method.is(.null_value)) return;
    if (!call_runtime.isCallableValue(return_method)) return error.TypeError;
    const out = try callValueOrBytecodeRoot(ctx, output, global, iterator_value, return_method, &.{}, null, null);
    if (!out.is(.object)) return error.TypeError;
}

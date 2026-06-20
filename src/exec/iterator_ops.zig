const std = @import("std");

const bytecode = @import("../bytecode/root.zig");
const core = @import("../core/root.zig");
const method_ids = core.host_function.builtin_method_ids;
const exceptions = @import("exceptions.zig");
const frame_mod = @import("frame.zig");
const property_ops = @import("property_ops.zig");
const call_runtime = @import("call_runtime.zig");
const exception_ops = @import("vm_exception_ops.zig");
const array_ops = @import("array_ops.zig");
const builtin_glue = @import("builtin_glue.zig");
const coercion_ops = @import("coercion_ops.zig");
const forof_ops = @import("forof_ops.zig");
const object_ops = @import("object_ops.zig");
const promise_ops = @import("promise_ops.zig");
const string_ops = @import("string_ops.zig");
const stack_mod = @import("stack.zig");
const value_ops = @import("value_ops.zig");

const IteratorZipError = exceptions.HostError;
const for_await_record_marker: i32 = -0x7fff0001;
pub const simple_for_in_iterator_kind: u8 = 251;
pub const Step = enum { done, continue_loop };

pub fn forOfStart(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    catch_target: ?usize,
    is_async: bool,
) !void {
    const iterable = try stack.pop();
    defer iterable.free(ctx.runtime);

    if (is_async) {
        const async_iterator_atom = core.atom.predefinedId("Symbol.asyncIterator", .symbol) orelse return error.TypeError;
        const async_method = try object_ops.getValueProperty(ctx, output, global, iterable, async_iterator_atom, function, frame);
        defer async_method.free(ctx.runtime);
        if (!async_method.isUndefined() and !async_method.isNull()) {
            if (!call_runtime.isCallableValue(async_method)) return error.TypeError;
            const iterator_value = try call_runtime.callValueOrBytecode(ctx, output, global, iterable, async_method, &.{}, function, frame);
            errdefer iterator_value.free(ctx.runtime);
            _ = try property_ops.expectObject(iterator_value);
            const next_method = try iteratorNextMethod(ctx, output, global, iterator_value, function, frame, object_ops.getValueProperty, call_runtime.isCallableValue);
            defer next_method.free(ctx.runtime);
            try pushForAwaitRecord(ctx, stack, iterator_value, next_method);
            iterator_value.free(ctx.runtime);
            return;
        }
    }

    var iterator_value: core.JSValue = undefined;
    var owns_iterator_value = false;
    const iterable_object = property_ops.expectObject(iterable) catch null;
    if (iterable.isString()) {
        const iterator = try core.object.stringIterator(ctx.runtime, iterable);
        var iterator_owned = true;
        errdefer if (iterator_owned) iterator.free(ctx.runtime);
        if (is_async) {
            const wrapper = try createAsyncFromSyncIterator(ctx, output, global, iterator, function, frame, object_ops.getValueProperty, call_runtime.isCallableValue);
            iterator_owned = false;
            defer iterator.free(ctx.runtime);
            defer wrapper.free(ctx.runtime);
            const next_method = try iteratorNextMethod(ctx, output, global, wrapper, function, frame, object_ops.getValueProperty, call_runtime.isCallableValue);
            defer next_method.free(ctx.runtime);
            try pushForAwaitRecord(ctx, stack, wrapper, next_method);
            return;
        } else {
            iterator_value = iterator;
            owns_iterator_value = true;
        }
    } else if (iterable_object != null and iterable_object.?.class_id == core.class.ids.string) {
        const iterator = try core.object.stringIterator(ctx.runtime, iterable);
        var iterator_owned = true;
        errdefer if (iterator_owned) iterator.free(ctx.runtime);
        if (is_async) {
            const wrapper = try createAsyncFromSyncIterator(ctx, output, global, iterator, function, frame, object_ops.getValueProperty, call_runtime.isCallableValue);
            iterator_owned = false;
            defer iterator.free(ctx.runtime);
            defer wrapper.free(ctx.runtime);
            const next_method = try iteratorNextMethod(ctx, output, global, wrapper, function, frame, object_ops.getValueProperty, call_runtime.isCallableValue);
            defer next_method.free(ctx.runtime);
            try pushForAwaitRecord(ctx, stack, wrapper, next_method);
            return;
        } else {
            iterator_value = iterator;
            owns_iterator_value = true;
        }
    } else if (iterable_object != null and
        (iterable_object.?.class_id == core.class.ids.array_iterator or
            iterable_object.?.class_id == core.class.ids.string_iterator or
            iterable_object.?.class_id == core.class.ids.generator or
            iterable_object.?.class_id == core.class.ids.async_generator))
    {
        if (is_async) {
            const wrapper = try createAsyncFromSyncIterator(ctx, output, global, iterable, function, frame, object_ops.getValueProperty, call_runtime.isCallableValue);
            defer wrapper.free(ctx.runtime);
            const next_method = try iteratorNextMethod(ctx, output, global, wrapper, function, frame, object_ops.getValueProperty, call_runtime.isCallableValue);
            defer next_method.free(ctx.runtime);
            try pushForAwaitRecord(ctx, stack, wrapper, next_method);
            return;
        } else {
            iterator_value = iterable.dup();
            owns_iterator_value = true;
        }
    } else {
        const iterator_method = try call_runtime.getIteratorMethod(ctx, output, global, iterable);
        defer iterator_method.free(ctx.runtime);
        if (!call_runtime.isCallableValue(iterator_method)) {
            _ = exception_ops.throwTypeErrorMessage(ctx, global, "value is not iterable") catch |err| return err;
            return error.TypeError;
        }
        iterator_value = try call_runtime.callValueOrBytecode(ctx, output, global, iterable, iterator_method, &.{}, function, frame);
        var iterator_value_owned = true;
        errdefer if (iterator_value_owned) iterator_value.free(ctx.runtime);
        _ = try property_ops.expectObject(iterator_value);
        if (is_async) {
            const wrapper = try createAsyncFromSyncIterator(ctx, output, global, iterator_value, function, frame, object_ops.getValueProperty, call_runtime.isCallableValue);
            iterator_value.free(ctx.runtime);
            iterator_value_owned = false;
            defer wrapper.free(ctx.runtime);
            const next_method = try iteratorNextMethod(ctx, output, global, wrapper, function, frame, object_ops.getValueProperty, call_runtime.isCallableValue);
            defer next_method.free(ctx.runtime);
            try pushForAwaitRecord(ctx, stack, wrapper, next_method);
            return;
        } else {
            owns_iterator_value = true;
        }
    }

    errdefer if (owns_iterator_value) iterator_value.free(ctx.runtime);
    _ = try property_ops.expectObject(iterator_value);
    const next_method = try iteratorNextMethod(ctx, output, global, iterator_value, function, frame, object_ops.getValueProperty, call_runtime.isCallableValue);
    defer next_method.free(ctx.runtime);
    try stack.pushOwned(iterator_value);
    owns_iterator_value = false;
    errdefer {
        const it = stack.pop() catch null;
        if (it) |value| value.free(ctx.runtime);
    }
    try stack.push(next_method);
    errdefer {
        const next = stack.pop() catch null;
        if (next) |value| value.free(ctx.runtime);
        const it = stack.pop() catch null;
        if (it) |value| value.free(ctx.runtime);
    }
    try stack.pushOwned(core.JSValue.catchOffset(catchTargetMarkerValue(catch_target)));
}

pub fn forOfStartVm(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    is_async: bool,
) !Step {
    forOfStart(ctx, output, global, stack, function, frame, catch_target.*, is_async) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    return .done;
}

fn catchTargetMarkerValue(catch_target: ?usize) i32 {
    return if (catch_target) |target| @intCast(target) else -1;
}

fn iteratorNextMethod(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    iterator_value: core.JSValue,
    function: ?*const bytecode.Bytecode,
    frame: ?*frame_mod.Frame,
    comptime getValueProperty: anytype,
    comptime isCallableValue: anytype,
) !core.JSValue {
    const next_key = try ctx.runtime.internAtom("next");
    defer ctx.runtime.atoms.free(next_key);
    const next_method = try getValueProperty(ctx, output, global, iterator_value, next_key, function, frame);
    errdefer next_method.free(ctx.runtime);
    if (!isCallableValue(next_method)) return error.TypeError;
    return next_method;
}

fn pushForAwaitRecord(ctx: *core.JSContext, stack: *stack_mod.Stack, iterator_value: core.JSValue, next_method: core.JSValue) !void {
    try stack.push(iterator_value);
    errdefer {
        const it = stack.pop() catch null;
        if (it) |value| value.free(ctx.runtime);
    }
    try stack.push(next_method);
    errdefer {
        const next = stack.pop() catch null;
        if (next) |value| value.free(ctx.runtime);
        const it = stack.pop() catch null;
        if (it) |value| value.free(ctx.runtime);
    }
    try stack.pushOwned(core.JSValue.int32(for_await_record_marker));
}

fn createAsyncFromSyncIterator(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    sync_iterator: core.JSValue,
    function: ?*const bytecode.Bytecode,
    frame: ?*frame_mod.Frame,
    comptime getValueProperty: anytype,
    comptime isCallableValue: anytype,
) !core.JSValue {
    const rt = ctx.runtime;
    var rooted_sync_iterator = sync_iterator;
    var rooted_next_method = core.JSValue.undefinedValue();
    var owns_next_method = false;
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &rooted_sync_iterator },
        .{ .value = &rooted_next_method },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    rooted_next_method = try iteratorNextMethod(ctx, output, global, rooted_sync_iterator, function, frame, getValueProperty, isCallableValue);
    owns_next_method = true;
    defer if (owns_next_method) rooted_next_method.free(rt);

    const wrapper = try core.Object.create(rt, core.class.ids.async_from_sync_iterator, null);
    errdefer core.Object.destroyFromHeader(rt, &wrapper.header);
    try wrapper.setOptionalValueSlot(rt, wrapper.iteratorTargetSlot(), rooted_sync_iterator.dup());
    try wrapper.setOptionalValueSlot(rt, wrapper.iteratorNextSlot(), rooted_next_method.dup());

    const next_fn = try asyncFromSyncMethod(rt, "next", 1);
    defer next_fn.free(rt);
    try defineValueProperty(rt, wrapper, "next", next_fn);

    const return_fn = try asyncFromSyncMethod(rt, "return", 2);
    defer return_fn.free(rt);
    try defineValueProperty(rt, wrapper, "return", return_fn);
    return wrapper.value();
}

var test_async_from_sync_next_method: core.JSValue = core.JSValue.undefinedValue();

fn testAsyncFromSyncGetValueProperty(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.JSValue,
    key: core.Atom,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    _ = ctx;
    _ = output;
    _ = global;
    _ = value;
    _ = key;
    _ = caller_function;
    _ = caller_frame;
    return test_async_from_sync_next_method.dup();
}

fn testAsyncFromSyncIsCallable(value: core.JSValue) bool {
    return value.isFunctionBytecode() or objectFromValue(value) != null;
}

test "createAsyncFromSyncIterator roots direct function bytecode next method while creating wrapper" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    const global = try core.Object.create(rt, core.class.ids.object, null);
    defer global.value().free(rt);
    const iterator = try core.Object.create(rt, core.class.ids.object, null);
    defer iterator.value().free(rt);

    const fb_slice = try rt.memory.alloc(bytecode.FunctionBytecode, 1);
    const fb = &fb_slice[0];
    fb.* = bytecode.FunctionBytecode.init(&rt.memory, &rt.atoms, core.atom.ids.empty_string);
    fb.func_kind = .generator;
    try rt.gc.add(&fb.header);

    const symbol_atom = try rt.atoms.newValueSymbol("gc-async-from-sync-next-bytecode-symbol");
    fb.cpool = try rt.memory.alloc(core.JSValue, 1);
    fb.cpool[0] = core.JSValue.symbol(symbol_atom);
    fb.cpool_count = 1;

    var next_method = core.JSValue.functionBytecode(&fb.header);
    var next_method_alive = true;
    defer if (next_method_alive) next_method.free(rt);
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
    var wrapper_alive = true;
    defer if (wrapper_alive) wrapper_value.free(rt);
    const wrapper = objectFromValue(wrapper_value) orelse return error.TypeError;

    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    const stored = wrapper.iteratorNext() orelse return error.TypeError;
    try std.testing.expect(stored.same(next_method));

    wrapper_value.free(rt);
    wrapper_alive = false;
    next_method.free(rt);
    next_method_alive = false;
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

fn asyncFromSyncMethod(rt: *core.JSRuntime, name: []const u8, method_id: i32) !core.JSValue {
    const method = try core.function.nativeFunction(rt, name, 0);
    errdefer method.free(rt);
    const object = try property_ops.expectObject(method);
    if (method_id < 1 or method_id > 2) return error.TypeError;
    if (!object.addAsyncFromSyncIteratorMethod(@intCast(method_id))) return error.TypeError;
    return method;
}

fn defineValueProperty(rt: *core.JSRuntime, object: *core.Object, name: []const u8, value: core.JSValue) !void {
    const key = try rt.internAtom(name);
    defer rt.atoms.free(key);
    try object.defineOwnProperty(rt, key, core.Descriptor.data(value, true, false, true));
}

pub fn forInStart(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
) !void {
    try stack.reserveAdditional(1);
    const object_value = try stack.pop();
    defer object_value.free(ctx.runtime);
    const iterator = try forof_ops.createForInIterator(ctx, output, global, object_value);
    errdefer iterator.free(ctx.runtime);
    try stack.pushOwned(iterator);
}

pub fn forInStartVm(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
) !Step {
    forInStart(ctx, output, global, stack) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    return .done;
}

pub fn iteratorNext(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
) !void {
    if (stack.values.len < 4) return error.StackUnderflow;

    const iterator_value = stack.values[stack.values.len - 4].dup();
    defer iterator_value.free(ctx.runtime);
    const next_method = stack.values[stack.values.len - 3].dup();
    defer next_method.free(ctx.runtime);
    const arg_value = stack.values[stack.values.len - 1].dup();
    defer arg_value.free(ctx.runtime);

    const result = try call_runtime.callValueOrBytecode(ctx, output, global, iterator_value, next_method, &.{arg_value}, function, frame);
    const old_arg = stack.pop() catch |err| {
        result.free(ctx.runtime);
        return err;
    };
    old_arg.free(ctx.runtime);
    stack.pushOwned(result) catch |err| {
        result.free(ctx.runtime);
        return err;
    };
}

pub fn iteratorNextVm(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
) !Step {
    iteratorNext(ctx, output, global, stack, function, frame) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    return .done;
}

pub fn iteratorCheckObject(ctx: *core.JSContext, stack: *stack_mod.Stack) !void {
    _ = ctx;
    const value = stack.peekBorrowed() orelse return error.StackUnderflow;
    if (!value.isObject()) return error.TypeError;
}

pub fn iteratorCheckObjectVm(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    global: *core.Object,
) !Step {
    iteratorCheckObject(ctx, stack) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    return .done;
}

pub fn iteratorGetValueDone(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
) !void {
    try stack.reserveAdditional(1);
    const object_value = try stack.pop();
    defer object_value.free(ctx.runtime);
    _ = try property_ops.expectObject(object_value);

    const value_key = core.atom.predefinedId("value", .string) orelse return error.TypeError;
    const done_key = core.atom.predefinedId("done", .string) orelse return error.TypeError;
    const value = try object_ops.getValueProperty(ctx, output, global, object_value, value_key, function, frame);
    const done = object_ops.getValueProperty(ctx, output, global, object_value, done_key, function, frame) catch |err| {
        value.free(ctx.runtime);
        return err;
    };
    errdefer value.free(ctx.runtime);
    defer done.free(ctx.runtime);

    stack.pushOwnedAssumeCapacity(value);
    stack.pushOwnedAssumeCapacity(core.JSValue.boolean(coercion_ops.valueTruthy(done)));
}

pub fn iteratorGetValueDoneVm(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
) !Step {
    iteratorGetValueDone(ctx, output, global, stack, function, frame) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    return .done;
}

pub fn iteratorCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
) !void {
    if (frame.pc >= function.code.len) return error.InvalidBytecode;
    const flags = function.code[frame.pc];
    frame.pc += 1;
    if (stack.values.len < 4) return error.StackUnderflow;

    const iterator_value = stack.values[stack.values.len - 4].dup();
    defer iterator_value.free(ctx.runtime);
    const arg_value = stack.values[stack.values.len - 1].dup();
    defer arg_value.free(ctx.runtime);

    const atom_name: []const u8 = if ((flags & 1) != 0) "throw" else "return";
    const atom_id = try ctx.runtime.internAtom(atom_name);
    defer ctx.runtime.atoms.free(atom_id);
    const method = try object_ops.getValueProperty(ctx, output, global, iterator_value, atom_id, function, frame);
    defer method.free(ctx.runtime);
    if (method.isUndefined() or method.isNull()) {
        try stack.pushOwned(core.JSValue.boolean(true));
        return;
    }

    const result = if ((flags & 2) != 0)
        try call_runtime.callValueOrBytecode(ctx, output, global, iterator_value, method, &.{}, function, frame)
    else
        try call_runtime.callValueOrBytecode(ctx, output, global, iterator_value, method, &.{arg_value}, function, frame);

    errdefer result.free(ctx.runtime);
    try stack.reserveAdditional(1);
    const old_arg = try stack.pop();
    old_arg.free(ctx.runtime);
    stack.pushOwnedAssumeCapacity(result);
    stack.pushOwnedAssumeCapacity(core.JSValue.boolean(false));
}

pub fn iteratorCallVm(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
) !Step {
    iteratorCall(ctx, output, global, stack, function, frame) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    return .done;
}

pub fn forOfNext(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
) !void {
    if (frame.pc >= function.code.len) return error.InvalidBytecode;
    const depth = function.code[frame.pc];
    frame.pc += 1;
    const iterator_index = if (stack.values.len >= @as(usize, depth) + 3)
        stack.values.len - @as(usize, depth) - 3
    else
        try forof_ops.findForOfIteratorIndex(ctx.runtime, stack);
    if (try fastArrayForOfNext(ctx, stack, iterator_index)) return;
    const iterator_value = stack.values[iterator_index].dup();
    defer iterator_value.free(ctx.runtime);
    var value: core.JSValue = undefined;
    var done: bool = undefined;
    if (iterator_value.isUndefined()) {
        value = core.JSValue.undefinedValue();
        done = true;
    } else {
        if (iterator_index + 1 >= stack.values.len) return error.StackUnderflow;
        const next_method = stack.values[iterator_index + 1].dup();
        defer next_method.free(ctx.runtime);
        const step = try iteratorStepWithNext(ctx, output, global, iterator_value, next_method, function, frame);
        value = step.value;
        done = step.done;
    }
    errdefer value.free(ctx.runtime);
    if (done) {
        const old_iterator = stack.values[iterator_index];
        try stack.reserveAdditional(2);
        stack.values[iterator_index] = core.JSValue.undefinedValue();
        old_iterator.free(ctx.runtime);
    } else {
        try stack.reserveAdditional(2);
    }
    stack.pushOwnedAssumeCapacity(value);
    stack.pushOwnedAssumeCapacity(core.JSValue.boolean(done));
}

fn fastArrayForOfNext(ctx: *core.JSContext, stack: *stack_mod.Stack, iterator_index: usize) !bool {
    if (iterator_index + 1 >= stack.values.len) return false;
    const iterator = objectFromValue(stack.values[iterator_index]) orelse return false;
    if (iterator.class_id != core.class.ids.array_iterator) return false;
    const next_function = objectFromValue(stack.values[iterator_index + 1]) orelse return false;
    if (!next_function.isArrayIteratorNextFunction()) return false;

    const kind = iterator.iteratorKindSlot().*;
    if (kind != 1 and kind != 2) return false;

    const target_value = (iterator.iteratorTargetSlot().*) orelse {
        try stack.reserveAdditional(2);
        const old_iterator = stack.values[iterator_index];
        stack.values[iterator_index] = core.JSValue.undefinedValue();
        old_iterator.free(ctx.runtime);
        stack.pushOwnedAssumeCapacity(core.JSValue.undefinedValue());
        stack.pushOwnedAssumeCapacity(core.JSValue.boolean(true));
        return true;
    };
    const target = objectFromValue(target_value) orelse return false;
    if (!target.flags.is_array or target.exotic != null or target.proxyTarget() != null) return false;

    const index = iterator.iteratorIndexSlot().*;
    const length: usize = @intCast(target.length);
    if (index >= length) {
        try stack.reserveAdditional(2);
        iterator.clearOptionalValueSlot(ctx.runtime, iterator.iteratorTargetSlot());
        const old_iterator = stack.values[iterator_index];
        stack.values[iterator_index] = core.JSValue.undefinedValue();
        old_iterator.free(ctx.runtime);
        stack.pushOwnedAssumeCapacity(core.JSValue.undefinedValue());
        stack.pushOwnedAssumeCapacity(core.JSValue.boolean(true));
        return true;
    }
    if (index > core.atom.max_int_atom) return false;
    const element_index: u32 = @intCast(index);

    const value = switch (kind) {
        1 => core.JSValue.int32(@intCast(element_index)),
        2 => blk: {
            const atom_id = core.atom.atomFromUInt32(element_index);
            if (target.findProperty(atom_id) != null) return false;
            const elements = target.arrayElements();
            if (index >= elements.len) return false;
            const element = elements[index];
            break :blk element.dup();
        },
        else => unreachable,
    };
    errdefer value.free(ctx.runtime);

    try stack.reserveAdditional(2);
    iterator.iteratorIndexSlot().* = index + 1;
    stack.pushOwnedAssumeCapacity(value);
    stack.pushOwnedAssumeCapacity(core.JSValue.boolean(false));
    return true;
}

pub fn forOfNextVm(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
) !Step {
    forOfNext(ctx, output, global, stack, function, frame) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    return .done;
}

pub fn forInNext(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
) !void {
    const iterator_value = stack.peek() orelse return error.StackUnderflow;
    defer iterator_value.free(ctx.runtime);
    const iterator = try property_ops.expectObject(iterator_value);
    if ((iterator.iteratorKindSlot().*) == simple_for_in_iterator_kind) {
        return try simpleForInNext(ctx, output, global, stack, iterator);
    }
    const index_key = try ctx.runtime.internAtom("__index");
    defer ctx.runtime.atoms.free(index_key);
    const source_key = try ctx.runtime.internAtom("__source");
    defer ctx.runtime.atoms.free(source_key);
    while (true) {
        const index_value = iterator.getProperty(index_key);
        defer index_value.free(ctx.runtime);
        const index: u32 = @intCast(index_value.asInt32() orelse 0);
        if (index >= iterator.length) {
            try stack.reserveAdditional(2);
            stack.pushOwnedAssumeCapacity(core.JSValue.undefinedValue());
            stack.pushOwnedAssumeCapacity(core.JSValue.boolean(true));
            break;
        }
        const key_value = iterator.getProperty(core.atom.atomFromUInt32(index));
        defer key_value.free(ctx.runtime);
        try stack.reserveAdditional(2);
        try iterator.defineOwnProperty(ctx.runtime, index_key, core.Descriptor.data(core.JSValue.int32(@intCast(index + 1)), true, true, true));

        const source_value = iterator.getProperty(source_key);
        defer source_value.free(ctx.runtime);
        if (!source_value.isUndefined()) {
            const source = try property_ops.expectObject(source_value);
            const key_atom = try property_ops.propertyKeyAtom(ctx.runtime, key_value);
            defer ctx.runtime.atoms.free(key_atom);
            if (core.object.isTypedArrayObject(source)) {
                if (core.array.arrayIndexFromAtom(&ctx.runtime.atoms, key_atom)) |typed_index| {
                    if (typed_index >= (core.object.typedArrayLength(ctx.runtime, source) catch 0)) continue;
                } else if (!try object_ops.hasValueProperty(ctx, output, global, source_value, source, key_atom, null, null)) {
                    continue;
                }
            } else if (!try object_ops.hasValueProperty(ctx, output, global, source_value, source, key_atom, null, null)) continue;
        }

        stack.pushAssumeCapacity(key_value);
        stack.pushOwnedAssumeCapacity(core.JSValue.boolean(false));
        break;
    }
}

fn simpleForInNext(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    iterator: *core.Object,
) !void {
    const atom_keys = iterator.iteratorAtomKeys();
    if (atom_keys.len != 0) {
        return try simpleForInNextAtomKeys(ctx, output, global, stack, iterator, atom_keys);
    }

    while (true) {
        const index = iterator.iteratorIndexSlot().*;
        if (index >= iterator.length) {
            try stack.reserveAdditional(2);
            iterator.clearOptionalValueSlot(ctx.runtime, iterator.iteratorTargetSlot());
            stack.pushOwnedAssumeCapacity(core.JSValue.undefinedValue());
            stack.pushOwnedAssumeCapacity(core.JSValue.boolean(true));
            return;
        }

        const key_value = iterator.getProperty(core.atom.atomFromUInt32(@intCast(index)));
        defer key_value.free(ctx.runtime);
        try stack.reserveAdditional(2);
        iterator.iteratorIndexSlot().* = index + 1;

        if ((iterator.iteratorTargetSlot().*)) |source_value| {
            const source = try property_ops.expectObject(source_value);
            const key_atom = try property_ops.propertyKeyAtom(ctx.runtime, key_value);
            defer ctx.runtime.atoms.free(key_atom);
            if (!try object_ops.hasValueProperty(ctx, output, global, source_value, source, key_atom, null, null)) continue;
        }

        stack.pushAssumeCapacity(key_value);
        stack.pushOwnedAssumeCapacity(core.JSValue.boolean(false));
        return;
    }
}

fn simpleForInNextAtomKeys(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    iterator: *core.Object,
    atom_keys: []const core.Atom,
) !void {
    while (true) {
        const index = iterator.iteratorIndexSlot().*;
        if (index >= atom_keys.len) {
            try stack.reserveAdditional(2);
            iterator.clearOptionalValueSlot(ctx.runtime, iterator.iteratorTargetSlot());
            stack.pushOwnedAssumeCapacity(core.JSValue.undefinedValue());
            stack.pushOwnedAssumeCapacity(core.JSValue.boolean(true));
            return;
        }

        const key_atom = atom_keys[index];
        iterator.iteratorIndexSlot().* = index + 1;

        if ((iterator.iteratorTargetSlot().*)) |source_value| {
            const source = try property_ops.expectObject(source_value);
            if (!try object_ops.hasValueProperty(ctx, output, global, source_value, source, key_atom, null, null)) continue;
        }

        const key_value = try ctx.runtime.atoms.toStringValue(ctx.runtime, key_atom);
        errdefer key_value.free(ctx.runtime);
        try stack.reserveAdditional(2);
        stack.pushOwnedAssumeCapacity(key_value);
        stack.pushOwnedAssumeCapacity(core.JSValue.boolean(false));
        return;
    }
}

pub fn iteratorClose(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
) !void {
    var is_for_await_record = false;
    const it = blk: {
        const top = stack.peekBorrowed() orelse return error.StackUnderflow;
        const is_record = top.isCatchOffset() or (top.asInt32() orelse 0) == for_await_record_marker;
        is_for_await_record = !top.isCatchOffset() and (top.asInt32() orelse 0) == for_await_record_marker;
        if (!is_record) break :blk try stack.pop();

        const marker = try stack.pop();
        marker.free(ctx.runtime);
        const next_method = stack.pop() catch |err| return err;
        next_method.free(ctx.runtime);
        break :blk try stack.pop();
    };
    defer it.free(ctx.runtime);
    if (it.isUndefined()) return;
    if (is_for_await_record) {
        try promise_ops.closeForAwaitIteratorFromVm(ctx, output, global, it);
    } else {
        try forof_ops.closeIteratorFromVm(ctx, output, global, it);
    }
}

pub fn iteratorCloseVm(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
) !Step {
    iteratorClose(ctx, output, global, stack) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(ctx, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    return .done;
}

pub fn arrayIteratorPrototypeFromContext(
    ctx: *core.JSContext,
    global: *core.Object,
) !*core.Object {
    const slot: usize = core.class.ids.array_iterator;
    if (slot < ctx.class_prototypes.len) {
        const stored = ctx.class_prototypes[slot];
        if (stored.isObject()) return property_ops.expectObject(stored) catch return error.TypeError;
    }

    const object = try qjsIteratorPrototype(ctx.runtime, global, "Array Iterator");
    errdefer core.Object.destroyFromHeader(ctx.runtime, &object.header);
    try builtin_glue.defineNativeDataMethod(ctx.runtime, object, "next", 0);
    const next_atom = core.atom.predefinedId("next", .string) orelse return error.TypeError;
    const next_value = object.getProperty(next_atom);
    defer next_value.free(ctx.runtime);
    const next_function = property_ops.expectObject(next_value) catch return error.TypeError;
    if (!next_function.addArrayIteratorNextFunction()) return error.TypeError;

    const iterator_method = try core.function.nativeFunction(ctx.runtime, "[Symbol.iterator]", 0);
    defer iterator_method.free(ctx.runtime);
    const iterator_function = property_ops.expectObject(iterator_method) catch return error.TypeError;
    if (!iterator_function.addIteratorIdentityFunction()) return error.TypeError;
    const iterator_atom = core.atom.predefinedId("Symbol.iterator", .symbol) orelse return error.TypeError;
    try object.defineOwnProperty(ctx.runtime, iterator_atom, core.Descriptor.data(iterator_method, true, false, true));

    if (slot < ctx.class_prototypes.len) {
        const value = object.value();
        ctx.class_prototypes[slot] = value.dup();
        value.free(ctx.runtime);
    }
    return object;
}

pub fn arrayIteratorMethod(
    ctx: *core.JSContext,
    global: *core.Object,
    receiver: core.JSValue,
    function_object: *core.Object,
) !?core.JSValue {
    const kind = function_object.arrayIteratorKind();
    if (kind < 1 or kind > 3) return null;
    if (receiver.isNull() or receiver.isUndefined()) return error.TypeError;
    var rooted_object = if (receiver.isObject()) receiver.dup() else try object_ops.primitiveObjectForAccess(ctx.runtime, global, receiver);
    errdefer rooted_object.free(ctx.runtime);

    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &rooted_object },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = ctx.runtime.active_value_roots,
        .values = &root_values,
    };
    ctx.runtime.active_value_roots = &root_frame;
    defer ctx.runtime.active_value_roots = root_frame.previous;

    const object = try property_ops.expectObject(rooted_object);
    if (array_ops.isTypedArrayPrototypeMethod(ctx.runtime, function_object)) {
        if (!core.object.isTypedArrayObject(object)) return error.TypeError;
        if (try core.object.typedArrayDetached(object)) return error.TypeError;
        if (try core.object.typedArrayOutOfBounds(object)) return error.TypeError;
    }
    const prototype = try arrayIteratorPrototypeFromContext(ctx, global);
    const iterator = try core.Object.create(ctx.runtime, core.class.ids.array_iterator, prototype);
    errdefer core.Object.destroyFromHeader(ctx.runtime, &iterator.header);
    try iterator.setOptionalValueSlot(ctx.runtime, iterator.iteratorTargetSlot(), rooted_object);
    rooted_object = core.JSValue.undefinedValue();
    iterator.iteratorIndexSlot().* = 0;
    iterator.iteratorKindSlot().* = kind;
    return iterator.value();
}

pub fn arrayIteratorNext(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
) !?core.JSValue {
    const iterator = property_ops.expectObject(receiver) catch return error.TypeError;
    if (iterator.class_id != core.class.ids.array_iterator) return error.TypeError;
    const target_value = (iterator.iteratorTargetSlot().*) orelse return try call_runtime.createIteratorResult(ctx.runtime, global, core.JSValue.undefinedValue(), true);
    const target = property_ops.expectObject(target_value) catch return error.TypeError;
    const length = if (core.object.isTypedArrayObject(target)) blk: {
        if (try core.object.typedArrayDetached(target)) return error.TypeError;
        if (try core.object.typedArrayOutOfBounds(target)) return error.TypeError;
        break :blk core.object.typedArrayLength(ctx.runtime, target) catch return error.TypeError;
    } else if (target.flags.is_array) target.length else blk: {
        const length_value = try object_ops.getValueProperty(ctx, output, global, target_value, core.atom.ids.length, null, null);
        defer length_value.free(ctx.runtime);
        break :blk @min(try coercion_ops.toLengthIndex(ctx, output, global, length_value), std.math.maxInt(u32));
    };
    if ((iterator.iteratorIndexSlot().*) >= length) {
        const done_result = try call_runtime.createIteratorResult(ctx.runtime, global, core.JSValue.undefinedValue(), true);
        iterator.clearOptionalValueSlot(ctx.runtime, iterator.iteratorTargetSlot());
        return done_result;
    }
    const index: u32 = @intCast((iterator.iteratorIndexSlot().*));
    iterator.iteratorIndexSlot().* += 1;
    const value = try arrayIteratorValue(ctx, output, global, target, index, (iterator.iteratorKindSlot().*), object_ops.getValueProperty);
    defer value.free(ctx.runtime);
    return try call_runtime.createIteratorResult(ctx.runtime, global, value, false);
}

pub fn arrayIteratorValue(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    target: *core.Object,
    index: u32,
    kind: u8,
    comptime getValueProperty: anytype,
) !core.JSValue {
    return switch (kind) {
        1 => core.JSValue.int32(@intCast(index)),
        2 => if (core.object.isTypedArrayObject(target))
            try core.typed_array.typedArrayGetIndex(ctx.runtime, target, index)
        else
            try getValueProperty(ctx, output, global, target.value(), core.atom.atomFromUInt32(index), null, null),
        3 => blk: {
            var pair_value = core.JSValue.undefinedValue();
            var value = core.JSValue.undefinedValue();
            var root_values = [_]core.runtime.ValueRootValue{
                .{ .value = &pair_value },
                .{ .value = &value },
            };
            const root_frame = core.runtime.ValueRootFrame{
                .previous = ctx.runtime.active_value_roots,
                .values = &root_values,
            };
            ctx.runtime.active_value_roots = &root_frame;
            defer ctx.runtime.active_value_roots = root_frame.previous;
            defer value.free(ctx.runtime);

            const pair = try core.Object.createArray(ctx.runtime, null);
            errdefer core.Object.destroyFromHeader(ctx.runtime, &pair.header);
            pair_value = pair.value();
            value = if (core.object.isTypedArrayObject(target))
                try core.typed_array.typedArrayGetIndex(ctx.runtime, target, index)
            else
                try getValueProperty(ctx, output, global, target.value(), core.atom.atomFromUInt32(index), null, null);
            try pair.defineOwnProperty(ctx.runtime, core.atom.atomFromUInt32(0), core.Descriptor.data(core.JSValue.int32(@intCast(index)), true, true, true));
            try pair.defineOwnProperty(ctx.runtime, core.atom.atomFromUInt32(1), core.Descriptor.data(value, true, true, true));
            break :blk pair_value;
        },
        else => error.TypeError,
    };
}

fn testArrayIteratorGetValueProperty(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.JSValue,
    atom_id: core.Atom,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    _ = ctx;
    _ = output;
    _ = global;
    _ = caller_function;
    _ = caller_frame;
    const object = try property_ops.expectObject(value);
    return object.getProperty(atom_id);
}

test "arrayIteratorValue roots entry value while creating pair array" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    const global = try core.Object.create(rt, core.class.ids.object, null);
    defer global.value().free(rt);
    const target = try core.Object.createArray(rt, null);
    var target_alive = true;
    defer if (target_alive) target.value().free(rt);

    const symbol_atom = try rt.atoms.newValueSymbol("gc-array-iterator-entry-symbol");
    try target.defineOwnProperty(rt, core.atom.atomFromUInt32(0), core.Descriptor.data(core.JSValue.symbol(symbol_atom), true, true, true));
    target.length = 1;

    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const pair_value = try arrayIteratorValue(ctx, null, global, target, 0, 3, testArrayIteratorGetValueProperty);
    var pair_alive = true;
    defer if (pair_alive) pair_value.free(rt);
    const pair = try property_ops.expectObject(pair_value);

    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    {
        const stored = pair.getProperty(core.atom.atomFromUInt32(1));
        defer stored.free(rt);
        try std.testing.expect(stored.same(core.JSValue.symbol(symbol_atom)));
    }

    pair_value.free(rt);
    pair_alive = false;
    target.value().free(rt);
    target_alive = false;
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

pub fn iteratorPrototypeFromGlobal(rt: *core.JSRuntime, global: *core.Object) ?*core.Object {
    const iterator_key = core.atom.predefinedId("Iterator", .string) orelse return null;
    const iterator_value = global.getProperty(iterator_key);
    defer iterator_value.free(rt);
    const iterator = property_ops.expectObject(iterator_value) catch return null;
    const prototype_value = iterator.getProperty(core.atom.ids.prototype);
    defer prototype_value.free(rt);
    return property_ops.expectObject(prototype_value) catch return null;
}

pub fn qjsDefineToStringTag(rt: *core.JSRuntime, object: *core.Object, tag_name: []const u8) !void {
    const tag_atom = core.atom.predefinedId("Symbol.toStringTag", .symbol) orelse return error.TypeError;
    const tag = try value_ops.createStringValue(rt, tag_name);
    defer tag.free(rt);
    try object.defineOwnProperty(rt, tag_atom, core.Descriptor.data(tag, false, false, true));
}

pub fn qjsIteratorPrototype(rt: *core.JSRuntime, global: *core.Object, tag_name: []const u8) !*core.Object {
    var fallback_base = if (iteratorPrototypeFromGlobal(rt, global) == null) blk: {
        const base = try core.Object.create(rt, core.class.ids.object, null);
        errdefer core.Object.destroyFromHeader(rt, &base.header);
        try qjsDefineToStringTag(rt, base, "Iterator");
        break :blk base;
    } else null;
    errdefer if (fallback_base) |base| base.value().free(rt);
    const base = iteratorPrototypeFromGlobal(rt, global) orelse fallback_base.?;
    const specific = try core.Object.create(rt, core.class.ids.object, base);
    errdefer core.Object.destroyFromHeader(rt, &specific.header);
    if (fallback_base) |owned_base| {
        fallback_base = null;
        owned_base.value().free(rt);
    }
    try qjsDefineToStringTag(rt, specific, tag_name);
    return specific;
}

pub fn qjsIteratorPrototypeAccessor(
    ctx: *core.JSContext,
    global: *core.Object,
    receiver: core.JSValue,
    args: []const core.JSValue,
    id: u32,
) !core.JSValue {
    switch (id) {
        @intFromEnum(method_ids.iterator.AccessorMethod.constructor_getter) => {
            const iterator_key = core.atom.predefinedId("Iterator", .string) orelse return error.TypeError;
            return global.getProperty(iterator_key);
        },
        @intFromEnum(method_ids.iterator.AccessorMethod.constructor_setter) => {
            if (args.len == 0) {
                const iterator_key = core.atom.predefinedId("Iterator", .string) orelse return error.TypeError;
                return global.getProperty(iterator_key);
            }
            return try qjsIteratorPrototypeAccessorSet(ctx, global, receiver, core.atom.ids.constructor, args[0]);
        },
        @intFromEnum(method_ids.iterator.AccessorMethod.to_string_tag_getter) => return try value_ops.createStringValue(ctx.runtime, "Iterator"),
        @intFromEnum(method_ids.iterator.AccessorMethod.to_string_tag_setter) => return try qjsIteratorPrototypeAccessorSet(
            ctx,
            global,
            receiver,
            core.atom.predefinedId("Symbol.toStringTag", .symbol) orelse return error.TypeError,
            if (args.len >= 1) args[0] else core.JSValue.undefinedValue(),
        ),
        else => return error.TypeError,
    }
}

pub fn qjsIteratorPrototypeAccessorSet(
    ctx: *core.JSContext,
    global: *core.Object,
    receiver: core.JSValue,
    atom_id: core.Atom,
    value: core.JSValue,
) !core.JSValue {
    const object = property_ops.expectObject(receiver) catch return error.TypeError;
    if (atom_id == core.atom.ids.constructor) {
        if (!value.isObject()) return error.TypeError;
        try object.defineOwnProperty(ctx.runtime, atom_id, core.Descriptor.data(value, true, false, true));
        return core.JSValue.undefinedValue();
    }
    const tag_atom = core.atom.predefinedId("Symbol.toStringTag", .symbol) orelse return error.TypeError;
    if (atom_id == tag_atom) {
        if (iteratorPrototypeFromGlobal(ctx.runtime, global)) |home| {
            if (object == home) return error.TypeError;
        }
    }
    if (object.getOwnProperty(atom_id)) |desc| {
        defer desc.destroy(ctx.runtime);
        object.setProperty(ctx.runtime, atom_id, value) catch |err| switch (err) {
            error.ReadOnly, error.AccessorWithoutSetter, error.NotExtensible, error.IncompatibleDescriptor => return error.TypeError,
            else => return err,
        };
        return core.JSValue.undefinedValue();
    }
    try object.defineOwnProperty(ctx.runtime, atom_id, core.Descriptor.data(value, true, true, true));
    return core.JSValue.undefinedValue();
}

pub fn qjsIteratorFromCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    if (args.len < 1) return error.TypeError;
    const source = args[0];
    if (source.isNull() or source.isUndefined()) return error.TypeError;
    if (!source.isString() and (property_ops.expectObject(source) catch null) == null) return error.TypeError;

    const result = try call_runtime.iteratorFromSourceForIteratorFrom(ctx, output, global, source, caller_function, caller_frame);
    if (!result.wrap) {
        if (result.next_method) |next_method| next_method.free(ctx.runtime);
        return result.iterator;
    }
    defer result.deinit(ctx.runtime);
    return try call_runtime.wrapIteratorFromIterator(ctx, global, result.iterator, result.next_method);
}

pub const IteratorFromResult = struct {
    iterator: core.JSValue,
    next_method: ?core.JSValue = null,
    wrap: bool = false,

    pub fn deinit(self: IteratorFromResult, rt: *core.JSRuntime) void {
        self.iterator.free(rt);
        if (self.next_method) |next_method| next_method.free(rt);
    }
};

pub fn qjsInstallIteratorHelperMethod(
    rt: *core.JSRuntime,
    helper: *core.Object,
    name: []const u8,
    method_id: i32,
) !void {
    const key = try rt.internAtom(name);
    defer rt.atoms.free(key);
    const method = try core.function.nativeFunction(rt, name, 0);
    defer method.free(rt);
    const method_object = property_ops.expectObject(method) catch return error.TypeError;
    if (method_id < 1 or method_id > 2) return error.TypeError;
    if (!method_object.addIteratorHelperMethod(@intCast(method_id))) return error.TypeError;
    try helper.defineOwnProperty(rt, key, core.Descriptor.data(method, true, false, true));
}

fn qjsIteratorMethodsPrototype(
    rt: *core.JSRuntime,
    global: *core.Object,
    slot: core.object.RealmValueSlot,
    tag_name: []const u8,
) !*core.Object {
    if (global.cachedRealmValue(slot)) |stored| return property_ops.expectObject(stored);

    const proto = try qjsIteratorPrototype(rt, global, tag_name);
    var proto_raw_owned = true;
    errdefer if (proto_raw_owned) core.Object.destroyFromHeader(rt, &proto.header);
    try qjsInstallIteratorHelperMethod(rt, proto, "next", 1);
    try qjsInstallIteratorHelperMethod(rt, proto, "return", 2);
    const value = proto.value();
    proto_raw_owned = false;
    defer value.free(rt);
    const cached = try global.cachedRealmValueSlot(rt, slot);
    try global.setOptionalValueSlot(rt, cached, value.dup());
    return proto;
}

pub fn qjsIteratorHelperPrototype(
    rt: *core.JSRuntime,
    global: *core.Object,
) !*core.Object {
    return qjsIteratorMethodsPrototype(rt, global, .iterator_helper_prototype, "Iterator Helper");
}

pub fn qjsIteratorConcatPrototype(
    rt: *core.JSRuntime,
    global: *core.Object,
) !*core.Object {
    return qjsIteratorMethodsPrototype(rt, global, .iterator_concat_prototype, "Iterator Concat");
}

pub fn qjsIteratorConcatCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    comptime arrayPrototypeFromGlobal: anytype,
    comptime getIteratorMethod: anytype,
    comptime isCallableValue: anytype,
) !core.JSValue {
    const records = try core.Object.createArray(ctx.runtime, arrayPrototypeFromGlobal(ctx.runtime, global));
    errdefer core.Object.destroyFromHeader(ctx.runtime, &records.header);

    var rooted_records = records.value();
    var records_root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &rooted_records },
    };
    const records_root_frame = core.runtime.ValueRootFrame{
        .previous = ctx.runtime.active_value_roots,
        .values = &records_root_values,
    };
    ctx.runtime.active_value_roots = &records_root_frame;
    defer ctx.runtime.active_value_roots = records_root_frame.previous;

    for (args, 0..) |item, index| {
        var rooted_item = item;
        var rooted_iterator_method = core.JSValue.undefinedValue();
        var owns_iterator_method = false;
        var loop_root_values = [_]core.runtime.ValueRootValue{
            .{ .value = &rooted_item },
            .{ .value = &rooted_iterator_method },
        };
        const loop_root_frame = core.runtime.ValueRootFrame{
            .previous = ctx.runtime.active_value_roots,
            .values = &loop_root_values,
        };
        ctx.runtime.active_value_roots = &loop_root_frame;
        defer ctx.runtime.active_value_roots = loop_root_frame.previous;

        _ = property_ops.expectObject(rooted_item) catch return error.TypeError;
        rooted_iterator_method = try getIteratorMethod(ctx, output, global, rooted_item);
        owns_iterator_method = true;
        defer if (owns_iterator_method) rooted_iterator_method.free(ctx.runtime);
        if (rooted_iterator_method.isUndefined() or rooted_iterator_method.isNull() or !isCallableValue(rooted_iterator_method)) return error.TypeError;
        try records.setProperty(ctx.runtime, core.atom.atomFromUInt32(@intCast(index * 2)), rooted_item);
        try records.setProperty(ctx.runtime, core.atom.atomFromUInt32(@intCast(index * 2 + 1)), rooted_iterator_method);
    }

    const prototype = try qjsIteratorConcatPrototype(ctx.runtime, global);
    const helper = try core.Object.create(ctx.runtime, core.class.ids.iterator_helper, prototype);
    errdefer core.Object.destroyFromHeader(ctx.runtime, &helper.header);
    try helper.setOptionalValueSlot(ctx.runtime, helper.iteratorTargetSlot(), rooted_records);
    rooted_records = core.JSValue.undefinedValue();
    helper.iteratorKindSlot().* = 6;
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
    return test_iterator_concat_method.dup();
}

test "qjsIteratorConcatCall roots direct function bytecode iterator method while creating helper" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    const global = try core.Object.create(rt, core.class.ids.object, null);
    defer global.value().free(rt);
    const iterator = try core.Object.create(rt, core.class.ids.object, null);
    defer iterator.value().free(rt);

    const concat_prototype = try core.Object.create(rt, core.class.ids.object, null);
    defer concat_prototype.value().free(rt);
    const cached_concat_prototype = try global.cachedRealmValueSlot(rt, .iterator_concat_prototype);
    try global.setOptionalValueSlot(rt, cached_concat_prototype, concat_prototype.value().dup());

    const fb_slice = try rt.memory.alloc(bytecode.FunctionBytecode, 1);
    const fb = &fb_slice[0];
    fb.* = bytecode.FunctionBytecode.init(&rt.memory, &rt.atoms, core.atom.ids.empty_string);
    fb.func_kind = .generator;
    try rt.gc.add(&fb.header);

    const symbol_atom = try rt.atoms.newValueSymbol("gc-iterator-concat-method-bytecode-symbol");
    fb.cpool = try rt.memory.alloc(core.JSValue, 1);
    fb.cpool[0] = core.JSValue.symbol(symbol_atom);
    fb.cpool_count = 1;

    var iterator_method = core.JSValue.functionBytecode(&fb.header);
    var iterator_method_alive = true;
    defer if (iterator_method_alive) iterator_method.free(rt);
    test_iterator_concat_method = iterator_method;
    defer test_iterator_concat_method = core.JSValue.undefinedValue();

    const old_threshold = rt.gcThreshold();
    defer rt.setGCThreshold(old_threshold);

    const helper_value = try qjsIteratorConcatCall(
        ctx,
        null,
        global,
        &.{iterator.value()},
        testIteratorConcatArrayPrototypeFromGlobal,
        testIteratorConcatGetIteratorMethod,
        testAsyncFromSyncIsCallable,
    );
    var helper_alive = true;
    defer if (helper_alive) helper_value.free(rt);
    const helper = objectFromValue(helper_value) orelse return error.TypeError;

    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    const records_value = helper.iteratorTarget() orelse return error.TypeError;
    const records = objectFromValue(records_value) orelse return error.TypeError;
    const stored_method = records.getProperty(core.atom.atomFromUInt32(1));
    defer stored_method.free(rt);
    try std.testing.expect(stored_method.same(iterator_method));

    helper_value.free(rt);
    helper_alive = false;
    iterator_method.free(rt);
    iterator_method_alive = false;
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

pub const IteratorZipMode = enum(u8) {
    shortest = 0,
    longest = 1,
    strict = 2,
};

pub const IteratorZipRecord = struct {
    iterator: core.JSValue,
    next: core.JSValue,
};

pub const IteratorZipCompletion = struct {
    err: ?IteratorZipError = null,
    exception: core.JSValue = core.JSValue.uninitialized(),

    pub fn initNormal() IteratorZipCompletion {
        return .{};
    }

    pub fn initThrow(ctx: *core.JSContext, err: anytype) IteratorZipCompletion {
        var completion = IteratorZipCompletion.initNormal();
        completion.capture(ctx, err);
        return completion;
    }

    pub fn capture(self: *IteratorZipCompletion, ctx: *core.JSContext, err: anytype) void {
        if (!self.exception.isUninitialized()) {
            const old_exception = self.exception;
            self.exception = core.JSValue.uninitialized();
            old_exception.free(ctx.runtime);
        }
        self.err = @errorCast(err);
        if (ctx.hasException()) self.exception = ctx.takeException();
    }

    pub fn restore(self: *const IteratorZipCompletion, ctx: *core.JSContext) void {
        if (ctx.hasException()) ctx.clearException();
        if (!self.exception.isUninitialized()) _ = ctx.throwValue(self.exception.dup());
    }

    pub fn deinit(self: *IteratorZipCompletion, rt: *core.JSRuntime) void {
        if (!self.exception.isUninitialized()) {
            const old_exception = self.exception;
            self.exception = core.JSValue.uninitialized();
            old_exception.free(rt);
        }
        self.err = null;
    }
};

const IteratorZipHelperKind = enum(u8) {
    zip = 7,
    zip_keyed = 8,
};

fn objectFromValue(value: core.JSValue) ?*core.Object {
    return property_ops.expectObject(value) catch null;
}

pub fn qjsIteratorZipCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    keyed: bool,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const rt = ctx.runtime;
    var rooted_args = args;
    var iters_val = core.JSValue.undefinedValue();
    var nexts_val = core.JSValue.undefinedValue();
    var pads_val = core.JSValue.undefinedValue();
    var keys_val = core.JSValue.undefinedValue();
    var padding_val = core.JSValue.undefinedValue();

    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &iters_val },
        .{ .value = &nexts_val },
        .{ .value = &pads_val },
        .{ .value = &keys_val },
        .{ .value = &padding_val },
    };
    var rooted_args_buffer = try core.runtime.ValueRootBuffer.initCopy(rt, rooted_args);
    defer rooted_args_buffer.deinit(rt);
    rooted_args = rooted_args_buffer.values;
    var root_slices = [_]core.runtime.ValueRootSlice{
        rooted_args_buffer.slice(),
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = &root_values,
        .slices = &root_slices,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    if (rooted_args.len < 1) return error.TypeError;
    const iterables = rooted_args[0];
    const iterables_object = objectFromValue(iterables) orelse return error.TypeError;

    const options = if (rooted_args.len >= 2) rooted_args[1] else core.JSValue.undefinedValue();
    const mode = try qjsIteratorZipModeFromOptions(ctx, output, global, options, caller_function, caller_frame);
    if (mode == .longest and rooted_args.len >= 2 and !options.isUndefined()) {
        const padding_key = try rt.internAtom("padding");
        defer rt.atoms.free(padding_key);
        const padding_value = try object_ops.getValueProperty(ctx, output, global, options, padding_key, caller_function, caller_frame);
        errdefer padding_value.free(rt);
        if (!padding_value.isUndefined() and objectFromValue(padding_value) == null) return error.TypeError;
        padding_val = padding_value;
    }
    defer if (!padding_val.isUndefined()) padding_val.free(rt);

    const iters = try core.Object.create(rt, core.class.ids.object, null);
    iters_val = iters.value();
    errdefer {
        core.Object.destroyFromHeader(rt, &iters.header);
        iters_val = core.JSValue.undefinedValue();
    }
    const nexts = try core.Object.create(rt, core.class.ids.object, null);
    nexts_val = nexts.value();
    errdefer {
        core.Object.destroyFromHeader(rt, &nexts.header);
        nexts_val = core.JSValue.undefinedValue();
    }
    const pads = try core.Object.create(rt, core.class.ids.object, null);
    pads_val = pads.value();
    errdefer {
        core.Object.destroyFromHeader(rt, &pads.header);
        pads_val = core.JSValue.undefinedValue();
    }
    const keys = if (keyed) try core.Object.create(rt, core.class.ids.object, null) else null;
    if (keys) |k| keys_val = k.value();
    errdefer if (keys) |object| {
        core.Object.destroyFromHeader(rt, &object.header);
        keys_val = core.JSValue.undefinedValue();
    };

    const count = if (!keyed) blk: {
        var iterables_iterator = call_runtime.iteratorForValue(ctx, output, global, iterables, caller_function, caller_frame) catch |err| return err;
        defer if (!iterables_iterator.isUndefined()) iterables_iterator.free(rt);
        const iterables_next = try qjsIteratorZipNextMethod(ctx, output, global, iterables_iterator, caller_function, caller_frame);
        defer iterables_next.free(rt);

        break :blk try qjsIteratorZipCollectIndexed(
            ctx,
            output,
            global,
            iterables_iterator,
            iterables_next,
            iters,
            nexts,
            pads,
            padding_val,
            mode,
            caller_function,
            caller_frame,
        );
    } else try qjsIteratorZipCollectKeyed(
        ctx,
        output,
        global,
        iterables_object,
        iters,
        nexts,
        pads,
        keys.?,
        padding_val,
        mode,
        caller_function,
        caller_frame,
    );

    if (count > std.math.maxInt(i32)) return error.RangeError;
    return try qjsIteratorZipCreateHelper(rt, global, iters, nexts, pads, keys, count, mode, keyed);
}

pub fn qjsIteratorZipModeFromOptions(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    options: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !IteratorZipMode {
    if (options.isUndefined()) return .shortest;
    _ = objectFromValue(options) orelse return error.TypeError;
    const mode_key = try ctx.runtime.internAtom("mode");
    defer ctx.runtime.atoms.free(mode_key);
    const mode_value = try object_ops.getValueProperty(ctx, output, global, options, mode_key, caller_function, caller_frame);
    defer mode_value.free(ctx.runtime);
    if (mode_value.isUndefined()) return .shortest;
    if (string_ops.stringValueUnitsEqualBytes(mode_value, "shortest")) return .shortest;
    if (string_ops.stringValueUnitsEqualBytes(mode_value, "longest")) return .longest;
    if (string_ops.stringValueUnitsEqualBytes(mode_value, "strict")) return .strict;
    return error.TypeError;
}

pub fn qjsIteratorZipCollectIndexed(
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
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !usize {
    var count: usize = 0;

    while (true) {
        const item_result = call_runtime.callValueOrBytecode(ctx, output, global, iterables_iterator, iterables_next, &.{}, caller_function, caller_frame) catch |err| {
            return qjsIteratorZipCloseAllAndPropagate(ctx, output, global, iters, count, err, null, caller_function, caller_frame);
        };
        defer item_result.free(ctx.runtime);
        const item_object = objectFromValue(item_result) orelse {
            return qjsIteratorZipCloseAllAndPropagate(ctx, output, global, iters, count, error.TypeError, null, caller_function, caller_frame);
        };
        const done_value = object_ops.getValueProperty(ctx, output, global, item_object.value(), core.atom.predefinedId("done", .string).?, caller_function, caller_frame) catch |err| {
            return qjsIteratorZipCloseAllAndPropagate(ctx, output, global, iters, count, err, null, caller_function, caller_frame);
        };
        defer done_value.free(ctx.runtime);
        if (coercion_ops.valueTruthy(done_value)) break;
        const item = object_ops.getValueProperty(ctx, output, global, item_object.value(), core.atom.predefinedId("value", .string).?, caller_function, caller_frame) catch |err| {
            return qjsIteratorZipCloseAllAndPropagate(ctx, output, global, iters, count, err, null, caller_function, caller_frame);
        };
        defer item.free(ctx.runtime);
        const record = qjsIteratorZipFlattenableRecord(ctx, output, global, item, caller_function, caller_frame) catch |err| {
            return qjsIteratorZipCloseAllAndPropagate(ctx, output, global, iters, count, err, iterables_iterator, caller_function, caller_frame);
        };
        defer record.iterator.free(ctx.runtime);
        defer record.next.free(ctx.runtime);
        try qjsIteratorZipStoreIndex(ctx.runtime, iters, count, record.iterator);
        try qjsIteratorZipStoreIndex(ctx.runtime, nexts, count, record.next);
        count += 1;
    }

    if (mode == .longest) {
        if (!padding.isUndefined() and !padding.isNull()) {
            var padding_iterator = call_runtime.iteratorForValue(ctx, output, global, padding, caller_function, caller_frame) catch |err| {
                return qjsIteratorZipCloseAllAndPropagate(ctx, output, global, iters, count, err, null, caller_function, caller_frame);
            };
            defer if (!padding_iterator.isUndefined()) padding_iterator.free(ctx.runtime);
            const padding_next = qjsIteratorZipNextMethod(ctx, output, global, padding_iterator, caller_function, caller_frame) catch |err| {
                return qjsIteratorZipCloseAllAndPropagate(ctx, output, global, iters, count, err, null, caller_function, caller_frame);
            };
            defer padding_next.free(ctx.runtime);

            var index: usize = 0;
            var done = false;
            while (index < count) : (index += 1) {
                const pad_step = call_runtime.callValueOrBytecode(ctx, output, global, padding_iterator, padding_next, &.{}, caller_function, caller_frame) catch |err| {
                    padding_iterator.free(ctx.runtime);
                    padding_iterator = core.JSValue.undefinedValue();
                    return qjsIteratorZipCloseAllAndPropagate(ctx, output, global, iters, count, err, null, caller_function, caller_frame);
                };
                defer pad_step.free(ctx.runtime);
                const pad_object = objectFromValue(pad_step) orelse {
                    padding_iterator.free(ctx.runtime);
                    padding_iterator = core.JSValue.undefinedValue();
                    return qjsIteratorZipCloseAllAndPropagate(ctx, output, global, iters, count, error.TypeError, null, caller_function, caller_frame);
                };
                const done_value = object_ops.getValueProperty(ctx, output, global, pad_object.value(), core.atom.predefinedId("done", .string).?, caller_function, caller_frame) catch |err| {
                    padding_iterator.free(ctx.runtime);
                    padding_iterator = core.JSValue.undefinedValue();
                    return qjsIteratorZipCloseAllAndPropagate(ctx, output, global, iters, count, err, null, caller_function, caller_frame);
                };
                defer done_value.free(ctx.runtime);
                done = coercion_ops.valueTruthy(done_value);
                const value = object_ops.getValueProperty(ctx, output, global, pad_object.value(), core.atom.predefinedId("value", .string).?, caller_function, caller_frame) catch |err| {
                    padding_iterator.free(ctx.runtime);
                    padding_iterator = core.JSValue.undefinedValue();
                    return qjsIteratorZipCloseAllAndPropagate(ctx, output, global, iters, count, err, null, caller_function, caller_frame);
                };
                defer value.free(ctx.runtime);
                if (done) break;
                try qjsIteratorZipStoreIndex(ctx.runtime, pads, index, value);
            }
            if (!done) {
                qjsIteratorZipClose(ctx, output, global, padding_iterator, caller_function, caller_frame) catch |err| {
                    padding_iterator.free(ctx.runtime);
                    padding_iterator = core.JSValue.undefinedValue();
                    return qjsIteratorZipCloseAllAndPropagate(ctx, output, global, iters, count, err, null, caller_function, caller_frame);
                };
            }
            while (index < count) : (index += 1) {
                try qjsIteratorZipStoreIndex(ctx.runtime, pads, index, core.JSValue.undefinedValue());
            }
        } else {
            var index: usize = 0;
            while (index < count) : (index += 1) {
                try qjsIteratorZipStoreIndex(ctx.runtime, pads, index, core.JSValue.undefinedValue());
            }
        }
    }

    return count;
}

pub fn qjsIteratorZipCollectKeyed(
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
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !usize {
    const own_keys = try object_ops.objectRestOwnKeys(ctx, output, global, iterables);
    defer core.Object.freeKeys(ctx.runtime, own_keys);

    var count: usize = 0;
    for (own_keys) |key| {
        const desc = object_ops.proxyAwareOwnPropertyDescriptor(ctx, output, global, iterables, key, caller_function, caller_frame) catch |err| {
            return qjsIteratorZipCloseAllAndPropagate(ctx, output, global, iters, count, err, null, caller_function, caller_frame);
        } orelse continue;
        defer desc.destroy(ctx.runtime);
        if (desc.enumerable != true) continue;

        const iter = object_ops.getValueProperty(ctx, output, global, iterables.value(), key, caller_function, caller_frame) catch |err| {
            return qjsIteratorZipCloseAllAndPropagate(ctx, output, global, iters, count, err, null, caller_function, caller_frame);
        };
        defer iter.free(ctx.runtime);
        if (iter.isUndefined()) continue;

        const record = qjsIteratorZipFlattenableRecord(ctx, output, global, iter, caller_function, caller_frame) catch |err| {
            return qjsIteratorZipCloseAllAndPropagate(ctx, output, global, iters, count, err, null, caller_function, caller_frame);
        };
        defer record.iterator.free(ctx.runtime);
        defer record.next.free(ctx.runtime);
        const key_value = object_ops.proxyTrapKeyValue(ctx.runtime, key) catch |err| {
            return qjsIteratorZipCloseAllAndPropagate(ctx, output, global, iters, count, err, null, caller_function, caller_frame);
        };
        defer key_value.free(ctx.runtime);

        try qjsIteratorZipStoreIndex(ctx.runtime, iters, count, record.iterator);
        try qjsIteratorZipStoreIndex(ctx.runtime, nexts, count, record.next);
        try qjsIteratorZipStoreIndex(ctx.runtime, keys, count, key_value);
        count += 1;
    }

    if (mode == .longest) {
        var index: usize = 0;
        while (index < count) : (index += 1) {
            if (!padding.isUndefined() and !padding.isNull()) {
                const key_value = qjsIteratorZipGetIndex(keys, index);
                defer key_value.free(ctx.runtime);
                const key = property_ops.propertyKeyAtom(ctx.runtime, key_value) catch |err| {
                    return qjsIteratorZipCloseAllAndPropagate(ctx, output, global, iters, count, err, null, caller_function, caller_frame);
                };
                defer ctx.runtime.atoms.free(key);
                const pad_value = object_ops.getValueProperty(ctx, output, global, padding, key, caller_function, caller_frame) catch |err| {
                    return qjsIteratorZipCloseAllAndPropagate(ctx, output, global, iters, count, err, null, caller_function, caller_frame);
                };
                defer pad_value.free(ctx.runtime);
                try qjsIteratorZipStoreIndex(ctx.runtime, pads, index, pad_value);
            } else {
                try qjsIteratorZipStoreIndex(ctx.runtime, pads, index, core.JSValue.undefinedValue());
            }
        }
    }

    return count;
}

pub fn qjsIteratorZipFlattenableRecord(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !IteratorZipRecord {
    _ = objectFromValue(value) orelse return error.TypeError;
    const symbol_key = core.atom.predefinedId("Symbol.iterator", .symbol) orelse return error.TypeError;
    const iterator_method = try object_ops.getValueProperty(ctx, output, global, value, symbol_key, caller_function, caller_frame);
    defer iterator_method.free(ctx.runtime);
    const iterator_value = if (!iterator_method.isUndefined() and !iterator_method.isNull()) blk: {
        if (!call_runtime.isCallableValue(iterator_method)) return error.TypeError;
        const iterator = try call_runtime.callValueOrBytecode(ctx, output, global, value, iterator_method, &.{}, caller_function, caller_frame);
        errdefer iterator.free(ctx.runtime);
        _ = objectFromValue(iterator) orelse return error.TypeError;
        break :blk iterator;
    } else value.dup();
    errdefer iterator_value.free(ctx.runtime);

    const next_value = try qjsIteratorZipNextMethod(ctx, output, global, iterator_value, caller_function, caller_frame);
    errdefer next_value.free(ctx.runtime);
    return .{ .iterator = iterator_value, .next = next_value };
}

pub fn qjsIteratorZipNextMethod(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    iterator_value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const iterator = objectFromValue(iterator_value) orelse return error.TypeError;
    if (iterator.cachedIteratorNext()) |cached| return cached.dup();
    const next_key = try ctx.runtime.internAtom("next");
    defer ctx.runtime.atoms.free(next_key);
    const next_value = try object_ops.getValueProperty(ctx, output, global, iterator_value, next_key, caller_function, caller_frame);
    errdefer next_value.free(ctx.runtime);
    return next_value;
}

pub fn qjsIteratorZipCreateHelper(
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
    var helper_value = core.JSValue.undefinedValue();
    var iters_value = iters.value();
    var nexts_value = nexts.value();
    var pads_value = pads.value();
    var keys_value = if (keys) |keys_object| keys_object.value() else core.JSValue.undefinedValue();
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &helper_value },
        .{ .value = &iters_value },
        .{ .value = &nexts_value },
        .{ .value = &pads_value },
        .{ .value = &keys_value },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    const prototype = try qjsIteratorHelperPrototype(rt, global);
    const helper = try core.Object.create(rt, core.class.ids.iterator_helper, prototype);
    errdefer core.Object.destroyFromHeader(rt, &helper.header);
    helper_value = helper.value();
    helper.iteratorKindSlot().* = @intFromEnum(if (keyed) IteratorZipHelperKind.zip_keyed else IteratorZipHelperKind.zip);
    helper.iteratorIndexSlot().* = count;
    helper.iteratorZipModeSlot().* = @intFromEnum(mode);
    helper.iteratorZipStateSlot().* = 0;
    helper.iteratorZipAliveSlot().* = count;
    try qjsInstallIteratorHelperMethod(rt, helper, "next", 1);
    try qjsInstallIteratorHelperMethod(rt, helper, "return", 2);
    try helper.setOptionalValueSlot(rt, helper.iteratorTargetSlot(), iters_value);
    iters_value = core.JSValue.undefinedValue();
    try helper.setOptionalValueSlot(rt, helper.iteratorZipNextsSlot(), nexts_value);
    nexts_value = core.JSValue.undefinedValue();
    try helper.setOptionalValueSlot(rt, helper.iteratorZipPadsSlot(), pads_value);
    pads_value = core.JSValue.undefinedValue();
    if (keys != null) {
        try helper.setOptionalValueSlot(rt, helper.iteratorZipKeysSlot(), keys_value);
        keys_value = core.JSValue.undefinedValue();
    }
    return helper_value;
}

pub fn qjsIteratorZipStoreIndex(rt: *core.JSRuntime, object: *core.Object, index: usize, value: core.JSValue) !void {
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

    try object.defineOwnProperty(rt, core.atom.atomFromUInt32(@intCast(index)), core.Descriptor.data(rooted_value, true, true, true));
}

test "qjsIteratorZipStoreIndex roots direct function bytecode value while defining property" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const object = try core.Object.create(rt, core.class.ids.object, null);
    defer object.value().free(rt);

    const fb_slice = try rt.memory.alloc(bytecode.FunctionBytecode, 1);
    const fb = &fb_slice[0];
    fb.* = bytecode.FunctionBytecode.init(&rt.memory, &rt.atoms, core.atom.ids.empty_string);
    fb.func_kind = .generator;
    try rt.gc.add(&fb.header);

    const symbol_atom = try rt.atoms.newValueSymbol("gc-iterator-zip-store-bytecode-symbol");
    fb.cpool = try rt.memory.alloc(core.JSValue, 1);
    fb.cpool[0] = core.JSValue.symbol(symbol_atom);
    fb.cpool_count = 1;

    var stored_value = core.JSValue.functionBytecode(&fb.header);
    var stored_value_alive = true;
    defer if (stored_value_alive) stored_value.free(rt);

    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    try qjsIteratorZipStoreIndex(rt, object, 0, stored_value);

    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    const stored = qjsIteratorZipGetIndex(object, 0);
    defer stored.free(rt);
    try std.testing.expect(stored.same(stored_value));

    _ = object.deleteProperty(rt, core.atom.atomFromUInt32(0));
    stored_value.free(rt);
    stored_value_alive = false;
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

test "qjsIteratorZipStoreIndex roots direct symbol value while defining property" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const object = try core.Object.create(rt, core.class.ids.object, null);
    defer object.value().free(rt);

    const symbol_atom = try rt.atoms.newValueSymbol("gc-iterator-zip-store-symbol");
    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    try qjsIteratorZipStoreIndex(rt, object, 0, core.JSValue.symbol(symbol_atom));

    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    {
        const stored = qjsIteratorZipGetIndex(object, 0);
        defer stored.free(rt);
        try std.testing.expect(stored.same(core.JSValue.symbol(symbol_atom)));
    }

    _ = object.deleteProperty(rt, core.atom.atomFromUInt32(0));
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

pub fn qjsIteratorZipGetIndex(object: *core.Object, index: usize) core.JSValue {
    return object.getProperty(core.atom.atomFromUInt32(@intCast(index)));
}

pub fn qjsIteratorZipSetIndex(rt: *core.JSRuntime, object: *core.Object, index: usize, value: core.JSValue) !void {
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

    try object.setProperty(rt, core.atom.atomFromUInt32(@intCast(index)), rooted_value);
}

pub fn qjsIteratorZipCloseWithCompletion(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    completion: *IteratorZipCompletion,
    iterator_value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) void {
    qjsIteratorZipClose(ctx, output, global, iterator_value, caller_function, caller_frame) catch |err| {
        if (completion.err == null) {
            completion.capture(ctx, err);
        } else if (ctx.hasException()) {
            ctx.clearException();
        }
        completion.restore(ctx);
    };
}

pub fn qjsIteratorZipCloseAllWithCompletion(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    completion: *IteratorZipCompletion,
    iters: *core.Object,
    count: usize,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !void {
    var index = count;
    while (index > 0) {
        index -= 1;
        const iterator_value = qjsIteratorZipGetIndex(iters, index);
        defer iterator_value.free(ctx.runtime);
        try qjsIteratorZipSetIndex(ctx.runtime, iters, index, core.JSValue.undefinedValue());
        if (iterator_value.isUndefined() or iterator_value.isNull()) continue;
        qjsIteratorZipCloseWithCompletion(ctx, output, global, completion, iterator_value, caller_function, caller_frame);
    }
}

pub fn qjsIteratorZipClose(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    iterator_value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !void {
    try call_runtime.qjsIteratorClose(ctx, output, global, iterator_value, caller_function, caller_frame);
}

pub fn qjsIteratorZipCloseAllAndPropagate(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    iters: *core.Object,
    count: usize,
    err: anytype,
    extra_iterator: ?core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) IteratorZipError {
    var completion = IteratorZipCompletion.initThrow(ctx, err);
    defer completion.deinit(ctx.runtime);
    qjsIteratorZipCloseAllWithCompletion(ctx, output, global, &completion, iters, count, caller_function, caller_frame) catch |close_err| {
        completion.restore(ctx);
        return close_err;
    };
    if (extra_iterator) |iterator_value| {
        qjsIteratorZipCloseWithCompletion(ctx, output, global, &completion, iterator_value, caller_function, caller_frame);
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

fn iteratorCloseWithCompletionAndPropagate(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    iterator_value: core.JSValue,
    err: anytype,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) IteratorZipError {
    var completion = IteratorZipCompletion.initThrow(ctx, err);
    defer completion.deinit(ctx.runtime);
    qjsIteratorZipCloseWithCompletion(ctx, output, global, &completion, iterator_value, caller_function, caller_frame);
    completion.restore(ctx);
    return completion.err orelse err;
}

fn iteratorHelperCloseWithCompletionAndPropagate(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    helper: *core.Object,
    err: anytype,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) IteratorZipError {
    var completion = IteratorZipCompletion.initThrow(ctx, err);
    defer completion.deinit(ctx.runtime);
    qjsIteratorHelperClose(ctx, output, global, helper, caller_function, caller_frame) catch |close_err| {
        if (ctx.hasException()) ctx.clearException();
        completion.restore(ctx);
        return close_err;
    };
    completion.restore(ctx);
    return completion.err orelse err;
}

pub fn qjsIteratorPrototypeMethodCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    args: []const core.JSValue,
    method_id: u32,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    return switch (method_id) {
        @intFromEnum(method_ids.iterator.PrototypeMethod.to_array) => try qjsIteratorToArrayCall(ctx, output, global, receiver, caller_function, caller_frame),
        @intFromEnum(method_ids.iterator.PrototypeMethod.every) => try qjsIteratorPredicateCall(ctx, output, global, receiver, args, .every, caller_function, caller_frame),
        @intFromEnum(method_ids.iterator.PrototypeMethod.find) => try qjsIteratorPredicateCall(ctx, output, global, receiver, args, .find, caller_function, caller_frame),
        @intFromEnum(method_ids.iterator.PrototypeMethod.for_each) => try qjsIteratorPredicateCall(ctx, output, global, receiver, args, .for_each, caller_function, caller_frame),
        @intFromEnum(method_ids.iterator.PrototypeMethod.reduce) => try qjsIteratorReduceCall(ctx, output, global, receiver, args, caller_function, caller_frame),
        @intFromEnum(method_ids.iterator.PrototypeMethod.some) => try qjsIteratorPredicateCall(ctx, output, global, receiver, args, .some, caller_function, caller_frame),
        @intFromEnum(method_ids.iterator.PrototypeMethod.map) => try qjsIteratorCreateCallbackHelper(ctx, output, global, receiver, args, .map, caller_function, caller_frame),
        @intFromEnum(method_ids.iterator.PrototypeMethod.filter) => try qjsIteratorCreateCallbackHelper(ctx, output, global, receiver, args, .filter, caller_function, caller_frame),
        @intFromEnum(method_ids.iterator.PrototypeMethod.take) => try qjsIteratorCreateLimitHelper(ctx, output, global, receiver, args, .take, caller_function, caller_frame),
        @intFromEnum(method_ids.iterator.PrototypeMethod.drop) => try qjsIteratorCreateLimitHelper(ctx, output, global, receiver, args, .drop, caller_function, caller_frame),
        @intFromEnum(method_ids.iterator.PrototypeMethod.flat_map) => try qjsIteratorCreateCallbackHelper(ctx, output, global, receiver, args, .flatMap, caller_function, caller_frame),
        @intFromEnum(method_ids.iterator.PrototypeMethod.dispose) => try qjsIteratorDisposeCall(ctx, output, global, receiver, caller_function, caller_frame),
        else => null,
    };
}

fn qjsIteratorDisposeCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const return_key = try ctx.runtime.internAtom("return");
    defer ctx.runtime.atoms.free(return_key);
    const return_method = try object_ops.getValueProperty(ctx, output, global, receiver, return_key, caller_function, caller_frame);
    defer return_method.free(ctx.runtime);
    if (return_method.isUndefined() or return_method.isNull()) return core.JSValue.undefinedValue();
    if (!call_runtime.isCallableValue(return_method)) return error.TypeError;
    const result = try call_runtime.callValueOrBytecode(ctx, output, global, receiver, return_method, &.{}, caller_function, caller_frame);
    result.free(ctx.runtime);
    return core.JSValue.undefinedValue();
}

fn qjsIteratorToArrayCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const iterator = objectFromValue(receiver) orelse return error.TypeError;
    const next_key = try ctx.runtime.internAtom("next");
    defer ctx.runtime.atoms.free(next_key);
    const next_method = try object_ops.getValueProperty(ctx, output, global, iterator.value(), next_key, caller_function, caller_frame);
    defer next_method.free(ctx.runtime);
    if (!call_runtime.isCallableValue(next_method)) return error.TypeError;

    const out = try core.Object.createArray(ctx.runtime, array_ops.arrayPrototypeFromGlobal(ctx.runtime, global));
    errdefer core.Object.destroyFromHeader(ctx.runtime, &out.header);
    var index: u32 = 0;
    while (true) : (index += 1) {
        const next = try call_runtime.callValueOrBytecode(ctx, output, global, iterator.value(), next_method, &.{}, caller_function, caller_frame);
        defer next.free(ctx.runtime);
        const next_object = objectFromValue(next) orelse return error.TypeError;
        const done_value = try object_ops.getValueProperty(ctx, output, global, next_object.value(), core.atom.predefinedId("done", .string).?, caller_function, caller_frame);
        defer done_value.free(ctx.runtime);
        if (coercion_ops.valueTruthy(done_value)) {
            out.length = index;
            return out.value();
        }
        const value = try object_ops.getValueProperty(ctx, output, global, next_object.value(), core.atom.predefinedId("value", .string).?, caller_function, caller_frame);
        defer value.free(ctx.runtime);
        try out.defineOwnProperty(ctx.runtime, core.atom.atomFromUInt32(index), core.Descriptor.data(value, true, true, true));
    }
}

fn qjsIteratorPredicateCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    args: []const core.JSValue,
    kind: IteratorPredicateKind,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const iterator = objectFromValue(receiver) orelse return error.TypeError;
    if (args.len < 1 or !call_runtime.isCallableValue(args[0])) {
        return iteratorCloseWithCompletionAndPropagate(ctx, output, global, iterator.value(), error.TypeError, caller_function, caller_frame);
    }
    const next_key = try ctx.runtime.internAtom("next");
    defer ctx.runtime.atoms.free(next_key);
    const next_method = try object_ops.getValueProperty(ctx, output, global, iterator.value(), next_key, caller_function, caller_frame);
    defer next_method.free(ctx.runtime);
    if (!call_runtime.isCallableValue(next_method)) return error.TypeError;

    var index: usize = 0;
    while (true) : (index += 1) {
        const step = try iteratorStepWithNext(ctx, output, global, iterator.value(), next_method, caller_function, caller_frame);
        defer step.value.free(ctx.runtime);
        if (step.done) {
            return switch (kind) {
                .every => core.JSValue.boolean(true),
                .some => core.JSValue.boolean(false),
                .find, .for_each => core.JSValue.undefinedValue(),
            };
        }

        const result = call_runtime.callValueOrBytecode(
            ctx,
            output,
            global,
            core.JSValue.undefinedValue(),
            args[0],
            &.{ step.value, core.JSValue.int32(@intCast(index)) },
            caller_function,
            caller_frame,
        ) catch |err| {
            return iteratorCloseWithCompletionAndPropagate(ctx, output, global, iterator.value(), err, caller_function, caller_frame);
        };
        defer result.free(ctx.runtime);
        const truthy = coercion_ops.valueTruthy(result);
        switch (kind) {
            .every => if (!truthy) {
                try call_runtime.qjsIteratorClose(ctx, output, global, iterator.value(), caller_function, caller_frame);
                return core.JSValue.boolean(false);
            },
            .some => if (truthy) {
                try call_runtime.qjsIteratorClose(ctx, output, global, iterator.value(), caller_function, caller_frame);
                return core.JSValue.boolean(true);
            },
            .find => if (truthy) {
                try call_runtime.qjsIteratorClose(ctx, output, global, iterator.value(), caller_function, caller_frame);
                return step.value.dup();
            },
            .for_each => {},
        }
    }
}

fn qjsIteratorReduceCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const iterator = objectFromValue(receiver) orelse return error.TypeError;
    if (args.len < 1 or !call_runtime.isCallableValue(args[0])) {
        return iteratorCloseWithCompletionAndPropagate(ctx, output, global, iterator.value(), error.TypeError, caller_function, caller_frame);
    }
    const next_key = try ctx.runtime.internAtom("next");
    defer ctx.runtime.atoms.free(next_key);
    const next_method = try object_ops.getValueProperty(ctx, output, global, iterator.value(), next_key, caller_function, caller_frame);
    defer next_method.free(ctx.runtime);
    if (!call_runtime.isCallableValue(next_method)) return error.TypeError;

    var index: usize = 0;
    var accumulator = if (args.len >= 2) args[1].dup() else blk: {
        const first = try iteratorStepWithNext(ctx, output, global, iterator.value(), next_method, caller_function, caller_frame);
        defer if (first.done) first.value.free(ctx.runtime);
        if (first.done) return error.TypeError;
        index = 1;
        break :blk first.value;
    };
    errdefer accumulator.free(ctx.runtime);

    while (true) : (index += 1) {
        const step = try iteratorStepWithNext(ctx, output, global, iterator.value(), next_method, caller_function, caller_frame);
        defer step.value.free(ctx.runtime);
        if (step.done) return accumulator;

        const result = call_runtime.callValueOrBytecode(
            ctx,
            output,
            global,
            core.JSValue.undefinedValue(),
            args[0],
            &.{ accumulator, step.value, core.JSValue.int32(@intCast(index)) },
            caller_function,
            caller_frame,
        ) catch |err| {
            return iteratorCloseWithCompletionAndPropagate(ctx, output, global, iterator.value(), err, caller_function, caller_frame);
        };
        accumulator.free(ctx.runtime);
        accumulator = result;
    }
}

fn iteratorStepWithNext(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    iterator_value: core.JSValue,
    next_method: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !IteratorStep {
    const next_result = try call_runtime.callValueOrBytecode(ctx, output, global, iterator_value, next_method, &.{}, caller_function, caller_frame);
    defer next_result.free(ctx.runtime);
    const next_object = objectFromValue(next_result) orelse return error.TypeError;
    const done = try object_ops.getValueProperty(ctx, output, global, next_object.value(), core.atom.predefinedId("done", .string).?, caller_function, caller_frame);
    defer done.free(ctx.runtime);
    if (coercion_ops.valueTruthy(done)) return .{ .value = core.JSValue.undefinedValue(), .done = true };
    const value = try object_ops.getValueProperty(ctx, output, global, next_object.value(), core.atom.predefinedId("value", .string).?, caller_function, caller_frame);
    return .{ .value = value, .done = false };
}

fn qjsIteratorCreateCallbackHelper(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    args: []const core.JSValue,
    kind: IteratorHelperKind,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    _ = objectFromValue(receiver) orelse return error.TypeError;
    if (args.len < 1 or !call_runtime.isCallableValue(args[0])) {
        return iteratorCloseWithCompletionAndPropagate(ctx, output, global, receiver, error.TypeError, caller_function, caller_frame);
    }
    return try qjsIteratorCreateHelper(ctx, output, global, receiver, kind, args[0], null, caller_function, caller_frame, object_ops.getValueProperty);
}

fn qjsIteratorCreateLimitHelper(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    args: []const core.JSValue,
    kind: IteratorHelperKind,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    _ = objectFromValue(receiver) orelse return error.TypeError;
    const limit = qjsIteratorLimitArgument(ctx, output, global, receiver, args) catch |err| {
        return iteratorCloseWithCompletionAndPropagate(ctx, output, global, receiver, err, caller_function, caller_frame);
    };
    return try qjsIteratorCreateHelper(ctx, output, global, receiver, kind, core.JSValue.undefinedValue(), limit, caller_function, caller_frame, object_ops.getValueProperty);
}

fn qjsIteratorLimitArgument(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    args: []const core.JSValue,
) !usize {
    _ = receiver;
    const limit_arg = if (args.len > 0) args[0] else core.JSValue.undefinedValue();
    const primitive = if (limit_arg.isObject())
        try coercion_ops.toPrimitiveForNumber(ctx, output, global, limit_arg)
    else
        limit_arg.dup();
    defer primitive.free(ctx.runtime);
    const number_value = try value_ops.toNumberValue(ctx.runtime, primitive);
    defer number_value.free(ctx.runtime);
    const number = number_value.asFloat64() orelse @as(f64, @floatFromInt(number_value.asInt32() orelse 0));
    if (std.math.isNan(number)) return error.RangeError;
    if (!std.math.isFinite(number)) return std.math.maxInt(usize);
    const integer = std.math.trunc(number);
    if (integer < 0) return error.RangeError;
    return @as(usize, @intFromFloat(integer));
}

fn qjsIteratorCreateHelper(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    kind: IteratorHelperKind,
    callback: core.JSValue,
    limit: ?usize,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
    comptime getValueProperty: anytype,
) !core.JSValue {
    var rooted_receiver = receiver;
    var rooted_callback = callback;
    var rooted_next_method = core.JSValue.undefinedValue();
    var owns_next_method = false;
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &rooted_receiver },
        .{ .value = &rooted_callback },
        .{ .value = &rooted_next_method },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = ctx.runtime.active_value_roots,
        .values = &root_values,
    };
    ctx.runtime.active_value_roots = &root_frame;
    defer ctx.runtime.active_value_roots = root_frame.previous;

    const iterator = objectFromValue(rooted_receiver) orelse return error.TypeError;
    const next_key = try ctx.runtime.internAtom("next");
    defer ctx.runtime.atoms.free(next_key);
    rooted_next_method = try getValueProperty(ctx, output, global, iterator.value(), next_key, caller_function, caller_frame);
    owns_next_method = true;
    defer if (owns_next_method) rooted_next_method.free(ctx.runtime);

    const prototype = try qjsIteratorHelperPrototype(ctx.runtime, global);
    const helper = try core.Object.create(ctx.runtime, core.class.ids.iterator_helper, prototype);
    errdefer core.Object.destroyFromHeader(ctx.runtime, &helper.header);
    try helper.setOptionalValueSlot(ctx.runtime, helper.iteratorTargetSlot(), rooted_receiver.dup());
    helper.iteratorKindSlot().* = @intFromEnum(kind);
    helper.iteratorIndexSlot().* = limit orelse 0;
    try helper.setOptionalValueSlot(ctx.runtime, helper.iteratorNextSlot(), rooted_next_method.dup());
    if (!rooted_callback.isUndefined()) try helper.setOptionalValueSlot(ctx.runtime, helper.iteratorCallbackSlot(), rooted_callback.dup());
    return helper.value();
}

test "qjsIteratorCreateHelper roots direct function bytecode callback while creating helper" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    const global = try core.Object.create(rt, core.class.ids.object, null);
    defer global.value().free(rt);
    const iterator = try core.Object.create(rt, core.class.ids.object, null);
    defer iterator.value().free(rt);

    const next_key = try rt.internAtom("next");
    defer rt.atoms.free(next_key);
    try iterator.defineOwnProperty(rt, next_key, core.Descriptor.data(core.JSValue.int32(1), true, true, true));

    const helper_prototype = try core.Object.create(rt, core.class.ids.object, null);
    defer helper_prototype.value().free(rt);
    const cached_helper_prototype = try global.cachedRealmValueSlot(rt, .iterator_helper_prototype);
    try global.setOptionalValueSlot(rt, cached_helper_prototype, helper_prototype.value().dup());

    const fb_slice = try rt.memory.alloc(bytecode.FunctionBytecode, 1);
    const fb = &fb_slice[0];
    fb.* = bytecode.FunctionBytecode.init(&rt.memory, &rt.atoms, core.atom.ids.empty_string);
    fb.func_kind = .generator;
    try rt.gc.add(&fb.header);

    const symbol_atom = try rt.atoms.newValueSymbol("gc-iterator-helper-callback-bytecode-symbol");
    fb.cpool = try rt.memory.alloc(core.JSValue, 1);
    fb.cpool[0] = core.JSValue.symbol(symbol_atom);
    fb.cpool_count = 1;

    var callback = core.JSValue.functionBytecode(&fb.header);
    var callback_alive = true;
    defer if (callback_alive) callback.free(rt);

    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const helper_value = try qjsIteratorCreateHelper(
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
    var helper_alive = true;
    defer if (helper_alive) helper_value.free(rt);
    const helper = objectFromValue(helper_value) orelse return error.TypeError;

    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    const stored = helper.iteratorCallback() orelse return error.TypeError;
    try std.testing.expect(stored.same(callback));

    helper_value.free(rt);
    helper_alive = false;
    callback.free(rt);
    callback_alive = false;
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

fn qjsIteratorZipPutResult(
    rt: *core.JSRuntime,
    results: *core.Object,
    keys: ?*core.Object,
    index: usize,
    value: core.JSValue,
) !void {
    if (keys) |key_store| {
        const key_value = qjsIteratorZipGetIndex(key_store, index);
        defer key_value.free(rt);
        const atom_id = try property_ops.propertyKeyAtom(rt, key_value);
        defer rt.atoms.free(atom_id);
        try results.defineOwnProperty(rt, atom_id, core.Descriptor.data(value, true, true, true));
        return;
    }
    try results.defineOwnProperty(rt, core.atom.atomFromUInt32(@intCast(index)), core.Descriptor.data(value, true, true, true));
}

fn qjsIteratorZipCompleteAbrupt(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    helper: *core.Object,
    iters: *core.Object,
    count: usize,
    current_index: ?usize,
    err: anytype,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) IteratorZipError {
    var completion = IteratorZipCompletion.initThrow(ctx, err);
    defer completion.deinit(ctx.runtime);
    helper.iteratorZipAliveSlot().* = 0;
    if (current_index) |index| {
        try qjsIteratorZipSetIndex(ctx.runtime, iters, index, core.JSValue.undefinedValue());
    }
    qjsIteratorZipCloseAllWithCompletion(ctx, output, global, &completion, iters, count, caller_function, caller_frame) catch |close_err| {
        completion.restore(ctx);
        return close_err;
    };
    try qjsIteratorHelperClear(ctx.runtime, helper);
    helper.iteratorZipStateSlot().* = 3;
    completion.restore(ctx);
    return completion.err orelse err;
}

fn qjsIteratorZipHelperNext(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    helper: *core.Object,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const state = helper.iteratorZipStateSlot().*;
    switch (state) {
        0, 1 => helper.iteratorZipStateSlot().* = 2,
        2 => return error.TypeError,
        3 => return try call_runtime.createIteratorResult(ctx.runtime, global, core.JSValue.undefinedValue(), true),
        else => return error.TypeError,
    }

    const iterator_value = (helper.iteratorTargetSlot().*) orelse return try call_runtime.createIteratorResult(ctx.runtime, global, core.JSValue.undefinedValue(), true);
    const iters = objectFromValue(iterator_value) orelse return error.TypeError;
    const nexts_value = helper.iteratorZipNexts() orelse return error.TypeError;
    const nexts = objectFromValue(nexts_value) orelse return error.TypeError;
    const pads_value = helper.iteratorZipPads() orelse return error.TypeError;
    const pads = objectFromValue(pads_value) orelse return error.TypeError;
    const keys = if ((helper.iteratorKindSlot().*) == @intFromEnum(IteratorHelperKind.zip_keyed)) blk: {
        const keys_value = helper.iteratorZipKeys() orelse return error.TypeError;
        break :blk objectFromValue(keys_value) orelse return error.TypeError;
    } else null;
    const mode: IteratorZipMode = @enumFromInt(helper.iteratorZipModeSlot().*);
    var alive: usize = helper.iteratorZipAliveSlot().*;
    const count = (helper.iteratorIndexSlot().*);

    const results = if (keys == null)
        try core.Object.createArray(ctx.runtime, array_ops.arrayPrototypeFromGlobal(ctx.runtime, global))
    else blk: {
        const object = try core.Object.create(ctx.runtime, core.class.ids.object, null);
        object.flags.null_prototype = true;
        break :blk object;
    };
    const results_value = results.value();
    defer results_value.free(ctx.runtime);

    var dones: usize = 0;
    var values: usize = 0;
    var index: usize = 0;
    while (index < count) : (index += 1) {
        const iter = qjsIteratorZipGetIndex(iters, index);
        defer iter.free(ctx.runtime);
        if (iter.isUndefined() or iter.isNull()) {
            if (mode != .longest) return error.TypeError;
            const pad = qjsIteratorZipGetIndex(pads, index);
            defer pad.free(ctx.runtime);
            try qjsIteratorZipPutResult(ctx.runtime, results, keys, index, pad);
            continue;
        }

        const next_method = qjsIteratorZipGetIndex(nexts, index);
        defer next_method.free(ctx.runtime);
        const step_result = call_runtime.callValueOrBytecode(ctx, output, global, iter, next_method, &.{}, caller_function, caller_frame) catch |err| {
            return qjsIteratorZipCompleteAbrupt(ctx, output, global, helper, iters, count, index, err, caller_function, caller_frame);
        };
        defer step_result.free(ctx.runtime);
        const step_object = objectFromValue(step_result) orelse {
            return qjsIteratorZipCompleteAbrupt(ctx, output, global, helper, iters, count, index, error.TypeError, caller_function, caller_frame);
        };
        const done_value = object_ops.getValueProperty(ctx, output, global, step_object.value(), core.atom.predefinedId("done", .string).?, caller_function, caller_frame) catch |err| {
            return qjsIteratorZipCompleteAbrupt(ctx, output, global, helper, iters, count, index, err, caller_function, caller_frame);
        };
        defer done_value.free(ctx.runtime);
        if (!coercion_ops.valueTruthy(done_value)) {
            if (mode == .strict and dones > 0) {
                return qjsIteratorZipCompleteAbrupt(ctx, output, global, helper, iters, count, null, error.TypeError, caller_function, caller_frame);
            }
            const value = object_ops.getValueProperty(ctx, output, global, step_object.value(), core.atom.predefinedId("value", .string).?, caller_function, caller_frame) catch |err| {
                return qjsIteratorZipCompleteAbrupt(ctx, output, global, helper, iters, count, index, err, caller_function, caller_frame);
            };
            defer value.free(ctx.runtime);
            try qjsIteratorZipPutResult(ctx.runtime, results, keys, index, value);
            values += 1;
            continue;
        }

        if (alive > 0) alive -= 1;
        dones += 1;
        try qjsIteratorZipSetIndex(ctx.runtime, iters, index, core.JSValue.undefinedValue());
        helper.iteratorZipAliveSlot().* = alive;

        switch (mode) {
            .shortest => {
                var completion = IteratorZipCompletion.initNormal();
                defer completion.deinit(ctx.runtime);
                try qjsIteratorZipCloseAllWithCompletion(ctx, output, global, &completion, iters, count, caller_function, caller_frame);
                try qjsIteratorHelperClear(ctx.runtime, helper);
                helper.iteratorZipStateSlot().* = 3;
                if (completion.err) |err| {
                    completion.restore(ctx);
                    return err;
                }
                return try call_runtime.createIteratorResult(ctx.runtime, global, core.JSValue.undefinedValue(), true);
            },
            .longest => {
                if (alive < 1) {
                    try qjsIteratorHelperClear(ctx.runtime, helper);
                    helper.iteratorZipStateSlot().* = 3;
                    return try call_runtime.createIteratorResult(ctx.runtime, global, core.JSValue.undefinedValue(), true);
                }
                const pad = qjsIteratorZipGetIndex(pads, index);
                defer pad.free(ctx.runtime);
                try qjsIteratorZipPutResult(ctx.runtime, results, keys, index, pad);
            },
            .strict => {
                if (values > 0) {
                    return qjsIteratorZipCompleteAbrupt(ctx, output, global, helper, iters, count, null, error.TypeError, caller_function, caller_frame);
                }
            },
        }
    }

    if (values == 0) {
        try qjsIteratorHelperClear(ctx.runtime, helper);
        helper.iteratorZipStateSlot().* = 3;
        return try call_runtime.createIteratorResult(ctx.runtime, global, core.JSValue.undefinedValue(), true);
    }

    if (keys == null) results.length = @intCast(count);
    helper.iteratorZipStateSlot().* = 1;
    return try call_runtime.createIteratorResult(ctx.runtime, global, results_value, false);
}

fn qjsIteratorZipHelperReturn(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    helper: *core.Object,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const state = helper.iteratorZipStateSlot().*;
    switch (state) {
        0 => helper.iteratorZipStateSlot().* = 3,
        1 => helper.iteratorZipStateSlot().* = 2,
        2 => return error.TypeError,
        3 => return try call_runtime.createIteratorResult(ctx.runtime, global, core.JSValue.undefinedValue(), true),
        else => return error.TypeError,
    }

    if ((helper.iteratorTargetSlot().*)) |iterator_value| {
        const iters = objectFromValue(iterator_value) orelse return error.TypeError;
        var completion = IteratorZipCompletion.initNormal();
        defer completion.deinit(ctx.runtime);
        try qjsIteratorZipCloseAllWithCompletion(ctx, output, global, &completion, iters, (helper.iteratorIndexSlot().*), caller_function, caller_frame);
        try qjsIteratorHelperClear(ctx.runtime, helper);
        helper.iteratorZipStateSlot().* = 3;
        if (completion.err) |err| {
            completion.restore(ctx);
            return err;
        }
        return try call_runtime.createIteratorResult(ctx.runtime, global, core.JSValue.undefinedValue(), true);
    }
    try qjsIteratorHelperClear(ctx.runtime, helper);
    helper.iteratorZipStateSlot().* = 3;
    return try call_runtime.createIteratorResult(ctx.runtime, global, core.JSValue.undefinedValue(), true);
}

pub fn qjsIteratorHelperNext(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    function_object: *core.Object,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    if (function_object.iteratorHelperMethod() != 1) return null;
    const helper = objectFromValue(receiver) orelse return error.TypeError;
    if (helper.class_id != core.class.ids.iterator_helper) return error.TypeError;
    if (helper.generatorExecuting()) return error.TypeError;
    helper.generatorExecutingSlot().* = true;
    defer helper.generatorExecutingSlot().* = false;
    const iterator = (helper.iteratorTargetSlot().*) orelse return try call_runtime.createIteratorResult(ctx.runtime, global, core.JSValue.undefinedValue(), true);
    const kind: IteratorHelperKind = @enumFromInt((helper.iteratorKindSlot().*));

    switch (kind) {
        .zip, .zip_keyed => return try qjsIteratorZipHelperNext(ctx, output, global, helper, caller_function, caller_frame),
        .concat => {
            while (true) {
                if (helper.iteratorData()) |inner_iterator| {
                    const inner_next = helper.iteratorInnerNext() orelse return error.TypeError;
                    const inner_step = try iteratorStepWithNext(ctx, output, global, inner_iterator, inner_next, caller_function, caller_frame);
                    defer inner_step.value.free(ctx.runtime);
                    if (!inner_step.done) return try call_runtime.createIteratorResult(ctx.runtime, global, inner_step.value, false);
                    try qjsIteratorHelperClearInner(ctx.runtime, helper);
                }

                const records = objectFromValue(iterator) orelse return error.TypeError;
                if ((helper.iteratorIndexSlot().*) >= records.length / 2) {
                    try qjsIteratorHelperClear(ctx.runtime, helper);
                    return try call_runtime.createIteratorResult(ctx.runtime, global, core.JSValue.undefinedValue(), true);
                }
                const item_index: u32 = @intCast((helper.iteratorIndexSlot().*) * 2);
                helper.iteratorIndexSlot().* += 1;
                const item = records.getProperty(core.atom.atomFromUInt32(item_index));
                defer item.free(ctx.runtime);
                const method = records.getProperty(core.atom.atomFromUInt32(item_index + 1));
                defer method.free(ctx.runtime);
                const inner_iterator = try call_runtime.callValueOrBytecode(ctx, output, global, item, method, &.{}, caller_function, caller_frame);
                defer inner_iterator.free(ctx.runtime);
                try qjsIteratorHelperSetInnerFromIterator(ctx, output, global, helper, inner_iterator, caller_function, caller_frame);
            }
        },
        .take => {
            const next_method = helper.iteratorNext() orelse return error.TypeError;
            if ((helper.iteratorIndexSlot().*) == 0) {
                try qjsIteratorHelperClose(ctx, output, global, helper, caller_function, caller_frame);
                return try call_runtime.createIteratorResult(ctx.runtime, global, core.JSValue.undefinedValue(), true);
            }
            helper.iteratorIndexSlot().* -= 1;
            const step = try iteratorStepWithNext(ctx, output, global, iterator, next_method, caller_function, caller_frame);
            defer step.value.free(ctx.runtime);
            if (step.done) {
                try qjsIteratorHelperClear(ctx.runtime, helper);
                return try call_runtime.createIteratorResult(ctx.runtime, global, core.JSValue.undefinedValue(), true);
            }
            return try call_runtime.createIteratorResult(ctx.runtime, global, step.value, false);
        },
        .drop => {
            const next_method = helper.iteratorNext() orelse return error.TypeError;
            while ((helper.iteratorIndexSlot().*) > 0) : (helper.iteratorIndexSlot().* -= 1) {
                const skipped = try iteratorStepWithNext(ctx, output, global, iterator, next_method, caller_function, caller_frame);
                defer skipped.value.free(ctx.runtime);
                if (skipped.done) {
                    try qjsIteratorHelperClear(ctx.runtime, helper);
                    return try call_runtime.createIteratorResult(ctx.runtime, global, core.JSValue.undefinedValue(), true);
                }
            }
            const step = try iteratorStepWithNext(ctx, output, global, iterator, next_method, caller_function, caller_frame);
            defer step.value.free(ctx.runtime);
            if (step.done) {
                try qjsIteratorHelperClear(ctx.runtime, helper);
                return try call_runtime.createIteratorResult(ctx.runtime, global, core.JSValue.undefinedValue(), true);
            }
            return try call_runtime.createIteratorResult(ctx.runtime, global, step.value, false);
        },
        .map, .filter, .flatMap => {
            const next_method = helper.iteratorNext() orelse return error.TypeError;
            const callback = helper.iteratorCallback() orelse return error.TypeError;
            while (true) {
                if (kind == .flatMap) {
                    if (helper.iteratorData()) |inner_iterator| {
                        const inner_next = helper.iteratorInnerNext() orelse return error.TypeError;
                        const inner_step = try iteratorStepWithNext(ctx, output, global, inner_iterator, inner_next, caller_function, caller_frame);
                        defer inner_step.value.free(ctx.runtime);
                        if (!inner_step.done) return try call_runtime.createIteratorResult(ctx.runtime, global, inner_step.value, false);
                        try qjsIteratorHelperClearInner(ctx.runtime, helper);
                    }
                }
                const step = try iteratorStepWithNext(ctx, output, global, iterator, next_method, caller_function, caller_frame);
                defer step.value.free(ctx.runtime);
                if (step.done) {
                    try qjsIteratorHelperClear(ctx.runtime, helper);
                    return try call_runtime.createIteratorResult(ctx.runtime, global, core.JSValue.undefinedValue(), true);
                }
                const index = (helper.iteratorIndexSlot().*);
                helper.iteratorIndexSlot().* += 1;
                const mapped = call_runtime.callValueOrBytecode(
                    ctx,
                    output,
                    global,
                    core.JSValue.undefinedValue(),
                    callback,
                    &.{ step.value, core.JSValue.int32(@intCast(index)) },
                    caller_function,
                    caller_frame,
                ) catch |err| {
                    return iteratorHelperCloseWithCompletionAndPropagate(ctx, output, global, helper, err, caller_function, caller_frame);
                };
                defer mapped.free(ctx.runtime);
                if (kind == .map) return try call_runtime.createIteratorResult(ctx.runtime, global, mapped, false);
                if (kind == .flatMap) {
                    try qjsIteratorHelperSetInner(ctx, output, global, helper, mapped, caller_function, caller_frame);
                    continue;
                }
                if (coercion_ops.valueTruthy(mapped)) return try call_runtime.createIteratorResult(ctx.runtime, global, step.value, false);
            }
        },
    }
}

fn qjsIteratorHelperSetInner(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    helper: *core.Object,
    mapped: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !void {
    const mapped_object = objectFromValue(mapped) orelse return error.TypeError;
    const symbol_key = core.atom.predefinedId("Symbol.iterator", .symbol) orelse return error.TypeError;
    const iterator_method = try object_ops.getValueProperty(ctx, output, global, mapped, symbol_key, caller_function, caller_frame);
    defer iterator_method.free(ctx.runtime);
    const inner_iterator = if (iterator_method.isUndefined() or iterator_method.isNull())
        mapped_object.value().dup()
    else blk: {
        if (!call_runtime.isCallableValue(iterator_method)) return error.TypeError;
        const value = try call_runtime.callValueOrBytecode(ctx, output, global, mapped, iterator_method, &.{}, caller_function, caller_frame);
        errdefer value.free(ctx.runtime);
        _ = objectFromValue(value) orelse return error.TypeError;
        break :blk value;
    };
    defer inner_iterator.free(ctx.runtime);
    try qjsIteratorHelperSetInnerFromIterator(ctx, output, global, helper, inner_iterator, caller_function, caller_frame);
}

fn qjsIteratorHelperSetInnerFromIterator(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    helper: *core.Object,
    inner_iterator: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !void {
    _ = objectFromValue(inner_iterator) orelse return error.TypeError;
    const next_key = try ctx.runtime.internAtom("next");
    defer ctx.runtime.atoms.free(next_key);
    const inner_next = try object_ops.getValueProperty(ctx, output, global, inner_iterator, next_key, caller_function, caller_frame);
    defer inner_next.free(ctx.runtime);
    const next_inner_iterator = inner_iterator.dup();
    errdefer next_inner_iterator.free(ctx.runtime);
    const next_inner_next = inner_next.dup();
    errdefer next_inner_next.free(ctx.runtime);
    const iterator_slot = helper.iteratorDataSlot();
    const inner_next_slot = helper.iteratorInnerNextSlot();
    const old_inner_iterator = iterator_slot.*;
    const old_inner_next = inner_next_slot.*;
    iterator_slot.* = next_inner_iterator;
    inner_next_slot.* = next_inner_next;
    if (old_inner_iterator) |stored| stored.free(ctx.runtime);
    if (old_inner_next) |stored| stored.free(ctx.runtime);
}

pub fn qjsIteratorHelperReturn(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    function_object: *core.Object,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    if (function_object.iteratorHelperMethod() != 2) return null;
    const helper = objectFromValue(receiver) orelse return error.TypeError;
    if (helper.class_id != core.class.ids.iterator_helper) return error.TypeError;
    if ((helper.iteratorKindSlot().*) == @intFromEnum(IteratorHelperKind.zip) or
        (helper.iteratorKindSlot().*) == @intFromEnum(IteratorHelperKind.zip_keyed))
    {
        return try qjsIteratorZipHelperReturn(ctx, output, global, helper, caller_function, caller_frame);
    }
    if (helper.generatorExecuting()) return error.TypeError;
    helper.generatorExecutingSlot().* = true;
    defer helper.generatorExecutingSlot().* = false;
    try qjsIteratorHelperClose(ctx, output, global, helper, caller_function, caller_frame);
    return try call_runtime.createIteratorResult(ctx.runtime, global, core.JSValue.undefinedValue(), true);
}

fn qjsIteratorHelperClose(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    helper: *core.Object,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !void {
    try qjsIteratorHelperCloseInner(ctx, output, global, helper, caller_function, caller_frame);
    if ((helper.iteratorKindSlot().*) == @intFromEnum(IteratorHelperKind.concat)) {
        try qjsIteratorHelperClear(ctx.runtime, helper);
        return;
    }
    const iterator = (helper.iteratorTargetSlot().*) orelse return;
    call_runtime.qjsIteratorClose(ctx, output, global, iterator, caller_function, caller_frame) catch |err| {
        try qjsIteratorHelperClear(ctx.runtime, helper);
        return err;
    };
    try qjsIteratorHelperClear(ctx.runtime, helper);
}

fn qjsIteratorHelperClear(rt: *core.JSRuntime, helper: *core.Object) !void {
    try qjsIteratorHelperClearInner(rt, helper);
    helper.clearOptionalValueSlot(rt, helper.iteratorTargetSlot());
    helper.clearOptionalValueSlot(rt, helper.iteratorNextSlot());
    helper.clearOptionalValueSlot(rt, helper.iteratorCallbackSlot());
    helper.clearOptionalValueSlot(rt, helper.iteratorZipNextsSlot());
    helper.clearOptionalValueSlot(rt, helper.iteratorZipPadsSlot());
    helper.clearOptionalValueSlot(rt, helper.iteratorZipKeysSlot());
}

fn qjsIteratorHelperCloseInner(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    helper: *core.Object,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !void {
    const inner_iterator = helper.iteratorData() orelse return;
    call_runtime.qjsIteratorClose(ctx, output, global, inner_iterator, caller_function, caller_frame) catch |err| {
        try qjsIteratorHelperClearInner(ctx.runtime, helper);
        return err;
    };
    try qjsIteratorHelperClearInner(ctx.runtime, helper);
}

fn qjsIteratorHelperClearInner(rt: *core.JSRuntime, helper: *core.Object) !void {
    helper.clearOptionalValueSlot(rt, helper.iteratorDataSlot());
    helper.clearOptionalValueSlot(rt, helper.iteratorInnerNextSlot());
}

fn testIteratorGetValuePropertyOptional(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.JSValue,
    key: core.Atom,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    _ = ctx;
    _ = output;
    _ = global;
    _ = caller_function;
    _ = caller_frame;
    const object = property_ops.expectObject(value) catch return error.TypeError;
    return object.getProperty(key);
}

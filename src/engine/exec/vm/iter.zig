const std = @import("std");

const bytecode = @import("../../bytecode/root.zig");
const builtins = @import("../../builtins/root.zig");
const core = @import("../../core/root.zig");
const exceptions = @import("../exceptions.zig");
const frame_mod = @import("../frame.zig");
const property_ops = @import("../property_ops.zig");
const stack_mod = @import("../stack.zig");
const value_ops = @import("../value_ops.zig");

const IteratorZipError = exceptions.HostError;
const for_await_record_marker: i32 = -0x7fff0001;
pub const simple_for_in_iterator_kind: u8 = 251;

pub fn forOfStart(
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    catch_target: ?usize,
    is_async: bool,
    comptime getIteratorMethod: anytype,
    comptime getValueProperty: anytype,
    comptime isCallableValue: anytype,
    comptime callValueOrBytecode: anytype,
) !void {
    const iterable = try stack.pop();
    defer iterable.free(ctx.runtime);

    if (is_async) {
        const async_iterator_atom = core.atom.predefinedId("Symbol.asyncIterator", .symbol) orelse return error.TypeError;
        const async_method = try getValueProperty(ctx, output, global, iterable, async_iterator_atom, function, frame);
        defer async_method.free(ctx.runtime);
        if (!async_method.isUndefined() and !async_method.isNull()) {
            if (!isCallableValue(async_method)) return error.TypeError;
            const iterator_value = try callValueOrBytecode(ctx, output, global, iterable, async_method, &.{}, function, frame);
            errdefer iterator_value.free(ctx.runtime);
            _ = try property_ops.expectObject(iterator_value);
            const next_method = try iteratorNextMethod(ctx, output, global, iterator_value, function, frame, getValueProperty, isCallableValue);
            defer next_method.free(ctx.runtime);
            try pushForAwaitRecord(ctx, stack, iterator_value, next_method);
            iterator_value.free(ctx.runtime);
            return;
        }
    }

    var iterator_value: core.Value = undefined;
    var owns_iterator_value = false;
    const iterable_object = property_ops.expectObject(iterable) catch null;
    if (iterable.isString()) {
        const iterator = try builtins.string.iterator(ctx.runtime, iterable);
        var iterator_owned = true;
        errdefer if (iterator_owned) iterator.free(ctx.runtime);
        if (is_async) {
            const wrapper = try createAsyncFromSyncIterator(ctx, output, global, iterator, function, frame, getValueProperty, isCallableValue);
            iterator_owned = false;
            defer iterator.free(ctx.runtime);
            defer wrapper.free(ctx.runtime);
            const next_method = try iteratorNextMethod(ctx, output, global, wrapper, function, frame, getValueProperty, isCallableValue);
            defer next_method.free(ctx.runtime);
            try pushForAwaitRecord(ctx, stack, wrapper, next_method);
            return;
        } else {
            iterator_value = iterator;
            owns_iterator_value = true;
        }
    } else if (iterable_object != null and iterable_object.?.class_id == core.class.ids.string) {
        const iterator = try builtins.string.iterator(ctx.runtime, iterable);
        var iterator_owned = true;
        errdefer if (iterator_owned) iterator.free(ctx.runtime);
        if (is_async) {
            const wrapper = try createAsyncFromSyncIterator(ctx, output, global, iterator, function, frame, getValueProperty, isCallableValue);
            iterator_owned = false;
            defer iterator.free(ctx.runtime);
            defer wrapper.free(ctx.runtime);
            const next_method = try iteratorNextMethod(ctx, output, global, wrapper, function, frame, getValueProperty, isCallableValue);
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
            const wrapper = try createAsyncFromSyncIterator(ctx, output, global, iterable, function, frame, getValueProperty, isCallableValue);
            defer wrapper.free(ctx.runtime);
            const next_method = try iteratorNextMethod(ctx, output, global, wrapper, function, frame, getValueProperty, isCallableValue);
            defer next_method.free(ctx.runtime);
            try pushForAwaitRecord(ctx, stack, wrapper, next_method);
            return;
        } else {
            iterator_value = iterable.dup();
            owns_iterator_value = true;
        }
    } else {
        const iterator_method = try getIteratorMethod(ctx, output, global, iterable);
        defer iterator_method.free(ctx.runtime);
        if (!isCallableValue(iterator_method)) return error.TypeError;
        iterator_value = try callValueOrBytecode(ctx, output, global, iterable, iterator_method, &.{}, function, frame);
        var iterator_value_owned = true;
        errdefer if (iterator_value_owned) iterator_value.free(ctx.runtime);
        _ = try property_ops.expectObject(iterator_value);
        if (is_async) {
            const wrapper = try createAsyncFromSyncIterator(ctx, output, global, iterator_value, function, frame, getValueProperty, isCallableValue);
            iterator_value.free(ctx.runtime);
            iterator_value_owned = false;
            defer wrapper.free(ctx.runtime);
            const next_method = try iteratorNextMethod(ctx, output, global, wrapper, function, frame, getValueProperty, isCallableValue);
            defer next_method.free(ctx.runtime);
            try pushForAwaitRecord(ctx, stack, wrapper, next_method);
            return;
        } else {
            owns_iterator_value = true;
        }
    }

    errdefer if (owns_iterator_value) iterator_value.free(ctx.runtime);
    _ = try property_ops.expectObject(iterator_value);
    const next_method = try iteratorNextMethod(ctx, output, global, iterator_value, function, frame, getValueProperty, isCallableValue);
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
    try stack.pushOwned(core.Value.catchOffset(catchTargetMarkerValue(catch_target)));
}

fn catchTargetMarkerValue(catch_target: ?usize) i32 {
    return if (catch_target) |target| @intCast(target) else -1;
}

fn iteratorNextMethod(
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    global: *core.Object,
    iterator_value: core.Value,
    function: ?*const bytecode.Bytecode,
    frame: ?*frame_mod.Frame,
    comptime getValueProperty: anytype,
    comptime isCallableValue: anytype,
) !core.Value {
    const next_key = try ctx.runtime.internAtom("next");
    defer ctx.runtime.atoms.free(next_key);
    const next_method = try getValueProperty(ctx, output, global, iterator_value, next_key, function, frame);
    errdefer next_method.free(ctx.runtime);
    if (!isCallableValue(next_method)) return error.TypeError;
    return next_method;
}

fn pushForAwaitRecord(ctx: *core.Context, stack: *stack_mod.Stack, iterator_value: core.Value, next_method: core.Value) !void {
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
    try stack.pushOwned(core.Value.int32(for_await_record_marker));
}

fn createAsyncFromSyncIterator(
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    global: *core.Object,
    sync_iterator: core.Value,
    function: ?*const bytecode.Bytecode,
    frame: ?*frame_mod.Frame,
    comptime getValueProperty: anytype,
    comptime isCallableValue: anytype,
) !core.Value {
    const rt = ctx.runtime;
    var rooted_sync_iterator = sync_iterator;
    var rooted_next_method = core.Value.undefinedValue();
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
    wrapper.iteratorTargetSlot().* = rooted_sync_iterator.dup();
    wrapper.iteratorNextSlot().* = rooted_next_method.dup();

    const next_fn = try asyncFromSyncMethod(rt, "next", 1);
    defer next_fn.free(rt);
    try defineValueProperty(rt, wrapper, "next", next_fn);

    const return_fn = try asyncFromSyncMethod(rt, "return", 2);
    defer return_fn.free(rt);
    try defineValueProperty(rt, wrapper, "return", return_fn);
    return wrapper.value();
}

var test_async_from_sync_next_method: core.Value = core.Value.undefinedValue();

fn testAsyncFromSyncGetValueProperty(
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.Value,
    key: core.Atom,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.Value {
    _ = ctx;
    _ = output;
    _ = global;
    _ = value;
    _ = key;
    _ = caller_function;
    _ = caller_frame;
    return test_async_from_sync_next_method.dup();
}

fn testAsyncFromSyncIsCallable(value: core.Value) bool {
    return value.isFunctionBytecode() or objectFromValue(value) != null;
}

test "createAsyncFromSyncIterator roots direct function bytecode next method while creating wrapper" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    const ctx = try core.Context.create(rt);
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
    fb.cpool = try rt.memory.alloc(core.Value, 1);
    fb.cpool[0] = core.Value.symbol(symbol_atom);
    fb.cpool_count = 1;

    var next_method = core.Value.functionBytecode(&fb.header);
    var next_method_alive = true;
    defer if (next_method_alive) next_method.free(rt);
    test_async_from_sync_next_method = next_method;
    defer test_async_from_sync_next_method = core.Value.undefinedValue();

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

fn asyncFromSyncMethod(rt: *core.Runtime, name: []const u8, method_id: i32) !core.Value {
    const method = try builtins.function.nativeFunction(rt, name, 0);
    errdefer method.free(rt);
    const object = try property_ops.expectObject(method);
    if (method_id < 1 or method_id > 2) return error.TypeError;
    if (!object.addAsyncFromSyncIteratorMethod(@intCast(method_id))) return error.TypeError;
    return method;
}

fn defineValueProperty(rt: *core.Runtime, object: *core.Object, name: []const u8, value: core.Value) !void {
    const key = try rt.internAtom(name);
    defer rt.atoms.free(key);
    try object.defineOwnProperty(rt, key, core.Descriptor.data(value, true, false, true));
}

pub fn forInStart(
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    comptime createForInIterator: anytype,
) !void {
    try stack.reserveAdditional(1);
    const object_value = try stack.pop();
    defer object_value.free(ctx.runtime);
    const iterator = try createForInIterator(ctx, output, global, object_value);
    errdefer iterator.free(ctx.runtime);
    try stack.pushOwned(iterator);
}

pub fn iteratorNext(
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    comptime callValueOrBytecode: anytype,
) !void {
    if (stack.values.len < 4) return error.StackUnderflow;

    const iterator_value = stack.values[stack.values.len - 4].dup();
    defer iterator_value.free(ctx.runtime);
    const next_method = stack.values[stack.values.len - 3].dup();
    defer next_method.free(ctx.runtime);
    const arg_value = stack.values[stack.values.len - 1].dup();
    defer arg_value.free(ctx.runtime);

    const result = try callValueOrBytecode(ctx, output, global, iterator_value, next_method, &.{arg_value}, function, frame);
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

pub fn iteratorCheckObject(ctx: *core.Context, stack: *stack_mod.Stack) !void {
    _ = ctx;
    const value = stack.peekBorrowed() orelse return error.StackUnderflow;
    if (!value.isObject()) return error.TypeError;
}

pub fn iteratorGetValueDone(
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    comptime getValueProperty: anytype,
    comptime valueTruthy: anytype,
) !void {
    try stack.reserveAdditional(1);
    const object_value = try stack.pop();
    defer object_value.free(ctx.runtime);
    _ = try property_ops.expectObject(object_value);

    const value_key = core.atom.predefinedId("value", .string) orelse return error.TypeError;
    const done_key = core.atom.predefinedId("done", .string) orelse return error.TypeError;
    const value = try getValueProperty(ctx, output, global, object_value, value_key, function, frame);
    const done = getValueProperty(ctx, output, global, object_value, done_key, function, frame) catch |err| {
        value.free(ctx.runtime);
        return err;
    };
    errdefer value.free(ctx.runtime);
    defer done.free(ctx.runtime);

    stack.pushOwnedAssumeCapacity(value);
    stack.pushOwnedAssumeCapacity(core.Value.boolean(valueTruthy(done)));
}

pub fn iteratorCall(
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    comptime getValueProperty: anytype,
    comptime callValueOrBytecode: anytype,
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
    const method = try getValueProperty(ctx, output, global, iterator_value, atom_id, function, frame);
    defer method.free(ctx.runtime);
    if (method.isUndefined() or method.isNull()) {
        try stack.pushOwned(core.Value.boolean(true));
        return;
    }

    const result = if ((flags & 2) != 0)
        try callValueOrBytecode(ctx, output, global, iterator_value, method, &.{}, function, frame)
    else
        try callValueOrBytecode(ctx, output, global, iterator_value, method, &.{arg_value}, function, frame);

    errdefer result.free(ctx.runtime);
    try stack.reserveAdditional(1);
    const old_arg = try stack.pop();
    old_arg.free(ctx.runtime);
    stack.pushOwnedAssumeCapacity(result);
    stack.pushOwnedAssumeCapacity(core.Value.boolean(false));
}

pub fn forOfNext(
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    comptime findForOfIteratorIndex: anytype,
    comptime callValueOrBytecode: anytype,
    comptime getValueProperty: anytype,
    comptime valueTruthy: anytype,
) !void {
    if (frame.pc >= function.code.len) return error.InvalidBytecode;
    const depth = function.code[frame.pc];
    frame.pc += 1;
    const iterator_index = if (stack.values.len >= @as(usize, depth) + 3)
        stack.values.len - @as(usize, depth) - 3
    else
        try findForOfIteratorIndex(ctx.runtime, stack);
    const iterator_value = stack.values[iterator_index].dup();
    defer iterator_value.free(ctx.runtime);
    var value: core.Value = undefined;
    var done: bool = undefined;
    if (iterator_value.isUndefined()) {
        value = core.Value.undefinedValue();
        done = true;
    } else {
        if (iterator_index + 1 >= stack.values.len) return error.StackUnderflow;
        const next_method = stack.values[iterator_index + 1].dup();
        defer next_method.free(ctx.runtime);
        const step = try iteratorStepWithNext(ctx, output, global, iterator_value, next_method, function, frame, getValueProperty, callValueOrBytecode, valueTruthy);
        value = step.value;
        done = step.done;
    }
    errdefer value.free(ctx.runtime);
    if (done) {
        const old_iterator = stack.values[iterator_index];
        try stack.reserveAdditional(2);
        stack.values[iterator_index] = core.Value.undefinedValue();
        old_iterator.free(ctx.runtime);
    } else {
        try stack.reserveAdditional(2);
    }
    stack.pushOwnedAssumeCapacity(value);
    stack.pushOwnedAssumeCapacity(core.Value.boolean(done));
}

pub fn forInNext(
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    comptime hasValueProperty: anytype,
) !void {
    const iterator_value = stack.peek() orelse return error.StackUnderflow;
    defer iterator_value.free(ctx.runtime);
    const iterator = try property_ops.expectObject(iterator_value);
    if ((iterator.iteratorKindSlot().*) == simple_for_in_iterator_kind) {
        return try simpleForInNext(ctx, output, global, stack, iterator, hasValueProperty);
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
            stack.pushOwnedAssumeCapacity(core.Value.undefinedValue());
            stack.pushOwnedAssumeCapacity(core.Value.boolean(true));
            break;
        }
        const key_value = iterator.getProperty(core.atom.atomFromUInt32(index));
        defer key_value.free(ctx.runtime);
        try stack.reserveAdditional(2);
        try iterator.defineOwnProperty(ctx.runtime, index_key, core.Descriptor.data(core.Value.int32(@intCast(index + 1)), true, true, true));

        const source_value = iterator.getProperty(source_key);
        defer source_value.free(ctx.runtime);
        if (!source_value.isUndefined()) {
            const source = try property_ops.expectObject(source_value);
            const key_atom = try property_ops.propertyKeyAtom(ctx.runtime, key_value);
            defer ctx.runtime.atoms.free(key_atom);
            if (builtins.buffer.isTypedArrayObject(source)) {
                if (core.array.arrayIndexFromAtom(&ctx.runtime.atoms, key_atom)) |typed_index| {
                    if (typed_index >= (builtins.buffer.typedArrayLength(ctx.runtime, source) catch 0)) continue;
                } else if (!try hasValueProperty(ctx, output, global, source_value, source, key_atom, null, null)) {
                    continue;
                }
            } else if (!try hasValueProperty(ctx, output, global, source_value, source, key_atom, null, null)) continue;
        }

        stack.pushAssumeCapacity(key_value);
        stack.pushOwnedAssumeCapacity(core.Value.boolean(false));
        break;
    }
}

fn simpleForInNext(
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    iterator: *core.Object,
    comptime hasValueProperty: anytype,
) !void {
    while (true) {
        const index = iterator.iteratorIndexSlot().*;
        if (index >= iterator.length) {
            try stack.reserveAdditional(2);
            if ((iterator.iteratorTargetSlot().*)) |stored| {
                iterator.iteratorTargetSlot().* = null;
                stored.free(ctx.runtime);
            }
            stack.pushOwnedAssumeCapacity(core.Value.undefinedValue());
            stack.pushOwnedAssumeCapacity(core.Value.boolean(true));
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
            if (!try hasValueProperty(ctx, output, global, source_value, source, key_atom, null, null)) continue;
        }

        stack.pushAssumeCapacity(key_value);
        stack.pushOwnedAssumeCapacity(core.Value.boolean(false));
        return;
    }
}

pub fn iteratorClose(
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    comptime closeIteratorFromVm: anytype,
    comptime closeForAwaitIteratorFromVm: anytype,
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
        try closeForAwaitIteratorFromVm(ctx, output, global, it);
    } else {
        try closeIteratorFromVm(ctx, output, global, it);
    }
}

pub fn arrayIteratorPrototypeFromContext(
    ctx: *core.Context,
    global: *core.Object,
    comptime iteratorPrototypeFactory: anytype,
    comptime defineNativeDataMethod: anytype,
) !*core.Object {
    const slot: usize = core.class.ids.array_iterator;
    if (slot < ctx.class_prototypes.len) {
        const stored = ctx.class_prototypes[slot];
        if (stored.isObject()) return property_ops.expectObject(stored) catch return error.TypeError;
    }

    const object = try iteratorPrototypeFactory(ctx.runtime, global, "Array Iterator");
    errdefer core.Object.destroyFromHeader(ctx.runtime, &object.header);
    try defineNativeDataMethod(ctx.runtime, object, "next", 0);
    const next_atom = core.atom.predefinedId("next", .string) orelse return error.TypeError;
    const next_value = object.getProperty(next_atom);
    defer next_value.free(ctx.runtime);
    const next_function = property_ops.expectObject(next_value) catch return error.TypeError;
    if (!next_function.addArrayIteratorNextFunction()) return error.TypeError;

    const iterator_method = try builtins.function.nativeFunction(ctx.runtime, "[Symbol.iterator]", 0);
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
    ctx: *core.Context,
    global: *core.Object,
    receiver: core.Value,
    function_object: *core.Object,
    comptime primitiveObjectForAccess: anytype,
    comptime isTypedArrayPrototypeMethod: anytype,
    comptime arrayIteratorPrototypeFactory: anytype,
) !?core.Value {
    const kind = function_object.arrayIteratorKind();
    if (kind < 1 or kind > 3) return null;
    if (receiver.isNull() or receiver.isUndefined()) return error.TypeError;
    var rooted_object = if (receiver.isObject()) receiver.dup() else try primitiveObjectForAccess(ctx.runtime, global, receiver);
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
    if (isTypedArrayPrototypeMethod(ctx.runtime, function_object)) {
        if (!builtins.buffer.isTypedArrayObject(object)) return error.TypeError;
        if (try builtins.buffer.typedArrayDetached(object)) return error.TypeError;
        if (try builtins.buffer.typedArrayOutOfBounds(object)) return error.TypeError;
    }
    const prototype = try arrayIteratorPrototypeFactory(ctx, global);
    const iterator = try core.Object.create(ctx.runtime, core.class.ids.array_iterator, prototype);
    errdefer core.Object.destroyFromHeader(ctx.runtime, &iterator.header);
    iterator.iteratorTargetSlot().* = rooted_object;
    iterator.iteratorIndexSlot().* = 0;
    iterator.iteratorKindSlot().* = kind;
    return iterator.value();
}

pub fn arrayIteratorNext(
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.Value,
    comptime createIteratorResult: anytype,
    comptime getValueProperty: anytype,
    comptime toLengthIndex: anytype,
) !?core.Value {
    const iterator = property_ops.expectObject(receiver) catch return error.TypeError;
    if (iterator.class_id != core.class.ids.array_iterator) return error.TypeError;
    const target_value = (iterator.iteratorTargetSlot().*) orelse return try createIteratorResult(ctx.runtime, global, core.Value.undefinedValue(), true);
    const target = property_ops.expectObject(target_value) catch return error.TypeError;
    const length = if (builtins.buffer.isTypedArrayObject(target)) blk: {
        if (try builtins.buffer.typedArrayDetached(target)) return error.TypeError;
        if (try builtins.buffer.typedArrayOutOfBounds(target)) return error.TypeError;
        break :blk builtins.buffer.typedArrayLength(ctx.runtime, target) catch return error.TypeError;
    } else if (target.is_array) target.length else blk: {
        const length_value = try getValueProperty(ctx, output, global, target_value, core.atom.ids.length, null, null);
        defer length_value.free(ctx.runtime);
        break :blk @min(try toLengthIndex(ctx, output, global, length_value), std.math.maxInt(u32));
    };
    if ((iterator.iteratorIndexSlot().*) >= length) {
        const done_result = try createIteratorResult(ctx.runtime, global, core.Value.undefinedValue(), true);
        if ((iterator.iteratorTargetSlot().*)) |stored| {
            iterator.iteratorTargetSlot().* = null;
            stored.free(ctx.runtime);
        }
        return done_result;
    }
    const index: u32 = @intCast((iterator.iteratorIndexSlot().*));
    iterator.iteratorIndexSlot().* += 1;
    const value = try arrayIteratorValue(ctx, output, global, target, index, (iterator.iteratorKindSlot().*), getValueProperty);
    defer value.free(ctx.runtime);
    return try createIteratorResult(ctx.runtime, global, value, false);
}

pub fn arrayIteratorValue(
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    global: *core.Object,
    target: *core.Object,
    index: u32,
    kind: u8,
    comptime getValueProperty: anytype,
) !core.Value {
    return switch (kind) {
        1 => core.Value.int32(@intCast(index)),
        2 => if (builtins.buffer.isTypedArrayObject(target))
            try builtins.buffer.typedArrayGetIndex(ctx.runtime, target, index)
        else
            try getValueProperty(ctx, output, global, target.value(), core.atom.atomFromUInt32(index), null, null),
        3 => blk: {
            var pair_value = core.Value.undefinedValue();
            var value = core.Value.undefinedValue();
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
            value = if (builtins.buffer.isTypedArrayObject(target))
                try builtins.buffer.typedArrayGetIndex(ctx.runtime, target, index)
            else
                try getValueProperty(ctx, output, global, target.value(), core.atom.atomFromUInt32(index), null, null);
            try pair.defineOwnProperty(ctx.runtime, core.atom.atomFromUInt32(0), core.Descriptor.data(core.Value.int32(@intCast(index)), true, true, true));
            try pair.defineOwnProperty(ctx.runtime, core.atom.atomFromUInt32(1), core.Descriptor.data(value, true, true, true));
            break :blk pair_value;
        },
        else => error.TypeError,
    };
}

fn testArrayIteratorGetValueProperty(
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.Value,
    atom_id: core.Atom,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.Value {
    _ = ctx;
    _ = output;
    _ = global;
    _ = caller_function;
    _ = caller_frame;
    const object = try property_ops.expectObject(value);
    return object.getProperty(atom_id);
}

test "arrayIteratorValue roots entry value while creating pair array" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    const ctx = try core.Context.create(rt);
    defer ctx.destroy();
    const global = try core.Object.create(rt, core.class.ids.object, null);
    defer global.value().free(rt);
    const target = try core.Object.createArray(rt, null);
    var target_alive = true;
    defer if (target_alive) target.value().free(rt);

    const symbol_atom = try rt.atoms.newValueSymbol("gc-array-iterator-entry-symbol");
    try target.defineOwnProperty(rt, core.atom.atomFromUInt32(0), core.Descriptor.data(core.Value.symbol(symbol_atom), true, true, true));
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
        try std.testing.expect(stored.same(core.Value.symbol(symbol_atom)));
    }

    pair_value.free(rt);
    pair_alive = false;
    target.value().free(rt);
    target_alive = false;
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

pub fn iteratorPrototypeFromGlobal(rt: *core.Runtime, global: *core.Object) ?*core.Object {
    const iterator_key = core.atom.predefinedId("Iterator", .string) orelse return null;
    const iterator_value = global.getProperty(iterator_key);
    defer iterator_value.free(rt);
    const iterator = property_ops.expectObject(iterator_value) catch return null;
    const prototype_value = iterator.getProperty(core.atom.ids.prototype);
    defer prototype_value.free(rt);
    return property_ops.expectObject(prototype_value) catch return null;
}

pub fn qjsDefineToStringTag(rt: *core.Runtime, object: *core.Object, tag_name: []const u8) !void {
    const tag_atom = core.atom.predefinedId("Symbol.toStringTag", .symbol) orelse return error.TypeError;
    const tag = try value_ops.createStringValue(rt, tag_name);
    defer tag.free(rt);
    try object.defineOwnProperty(rt, tag_atom, core.Descriptor.data(tag, false, false, true));
}

pub fn qjsIteratorPrototype(rt: *core.Runtime, global: *core.Object, tag_name: []const u8) !*core.Object {
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
    ctx: *core.Context,
    global: *core.Object,
    receiver: core.Value,
    args: []const core.Value,
    id: u32,
) !core.Value {
    switch (id) {
        @intFromEnum(builtins.iterator.AccessorMethod.constructor_getter) => {
            const iterator_key = core.atom.predefinedId("Iterator", .string) orelse return error.TypeError;
            return global.getProperty(iterator_key);
        },
        @intFromEnum(builtins.iterator.AccessorMethod.constructor_setter) => {
            if (args.len == 0) {
                const iterator_key = core.atom.predefinedId("Iterator", .string) orelse return error.TypeError;
                return global.getProperty(iterator_key);
            }
            return try qjsIteratorPrototypeAccessorSet(ctx, global, receiver, core.atom.ids.constructor, args[0]);
        },
        @intFromEnum(builtins.iterator.AccessorMethod.to_string_tag_getter) => return try value_ops.createStringValue(ctx.runtime, "Iterator"),
        @intFromEnum(builtins.iterator.AccessorMethod.to_string_tag_setter) => return try qjsIteratorPrototypeAccessorSet(
            ctx,
            global,
            receiver,
            core.atom.predefinedId("Symbol.toStringTag", .symbol) orelse return error.TypeError,
            if (args.len >= 1) args[0] else core.Value.undefinedValue(),
        ),
        else => return error.TypeError,
    }
}

pub fn qjsIteratorPrototypeAccessorSet(
    ctx: *core.Context,
    global: *core.Object,
    receiver: core.Value,
    atom_id: core.Atom,
    value: core.Value,
) !core.Value {
    const object = property_ops.expectObject(receiver) catch return error.TypeError;
    if (atom_id == core.atom.ids.constructor) {
        if (!value.isObject()) return error.TypeError;
        try object.defineOwnProperty(ctx.runtime, atom_id, core.Descriptor.data(value, true, false, true));
        return core.Value.undefinedValue();
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
        return core.Value.undefinedValue();
    }
    try object.defineOwnProperty(ctx.runtime, atom_id, core.Descriptor.data(value, true, true, true));
    return core.Value.undefinedValue();
}

pub fn qjsIteratorFromCall(
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.Value,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
    comptime iteratorFromSourceForIteratorFrom: anytype,
    comptime wrapIteratorFromIterator: anytype,
) !core.Value {
    if (args.len < 1) return error.TypeError;
    const source = args[0];
    if (source.isNull() or source.isUndefined()) return error.TypeError;
    if (!source.isString() and (property_ops.expectObject(source) catch null) == null) return error.TypeError;

    const result = try iteratorFromSourceForIteratorFrom(ctx, output, global, source, caller_function, caller_frame);
    if (!result.wrap) {
        if (result.next_method) |next_method| next_method.free(ctx.runtime);
        return result.iterator;
    }
    defer result.deinit(ctx.runtime);
    return try wrapIteratorFromIterator(ctx, global, result.iterator, result.next_method);
}

pub const IteratorFromResult = struct {
    iterator: core.Value,
    next_method: ?core.Value = null,
    wrap: bool = false,

    pub fn deinit(self: IteratorFromResult, rt: *core.Runtime) void {
        self.iterator.free(rt);
        if (self.next_method) |next_method| next_method.free(rt);
    }
};

pub fn qjsInstallIteratorHelperMethod(
    rt: *core.Runtime,
    helper: *core.Object,
    name: []const u8,
    method_id: i32,
) !void {
    const key = try rt.internAtom(name);
    defer rt.atoms.free(key);
    const method = try builtins.function.nativeFunction(rt, name, 0);
    defer method.free(rt);
    const method_object = property_ops.expectObject(method) catch return error.TypeError;
    if (method_id < 1 or method_id > 2) return error.TypeError;
    if (!method_object.addIteratorHelperMethod(@intCast(method_id))) return error.TypeError;
    try helper.defineOwnProperty(rt, key, core.Descriptor.data(method, true, false, true));
}

fn qjsIteratorMethodsPrototype(
    rt: *core.Runtime,
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
    const next_value = value.dup();
    const old_value = cached.*;
    cached.* = next_value;
    if (old_value) |stored| stored.free(rt);
    return proto;
}

pub fn qjsIteratorHelperPrototype(
    rt: *core.Runtime,
    global: *core.Object,
) !*core.Object {
    return qjsIteratorMethodsPrototype(rt, global, .iterator_helper_prototype, "Iterator Helper");
}

pub fn qjsIteratorConcatPrototype(
    rt: *core.Runtime,
    global: *core.Object,
) !*core.Object {
    return qjsIteratorMethodsPrototype(rt, global, .iterator_concat_prototype, "Iterator Concat");
}

pub fn qjsIteratorConcatCall(
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.Value,
    comptime arrayPrototypeFromGlobal: anytype,
    comptime getIteratorMethod: anytype,
    comptime isCallableValue: anytype,
) !core.Value {
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
        var rooted_iterator_method = core.Value.undefinedValue();
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
    helper.iteratorTargetSlot().* = rooted_records;
    helper.iteratorKindSlot().* = 6;
    helper.iteratorIndexSlot().* = 0;
    return helper.value();
}

var test_iterator_concat_method: core.Value = core.Value.undefinedValue();

fn testIteratorConcatArrayPrototypeFromGlobal(rt: *core.Runtime, global: *core.Object) ?*core.Object {
    _ = rt;
    _ = global;
    return null;
}

fn testIteratorConcatGetIteratorMethod(
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.Value,
) !core.Value {
    _ = output;
    _ = global;
    _ = value;
    ctx.runtime.setGCThreshold(0);
    return test_iterator_concat_method.dup();
}

test "qjsIteratorConcatCall roots direct function bytecode iterator method while creating helper" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    const ctx = try core.Context.create(rt);
    defer ctx.destroy();
    const global = try core.Object.create(rt, core.class.ids.object, null);
    defer global.value().free(rt);
    const iterator = try core.Object.create(rt, core.class.ids.object, null);
    defer iterator.value().free(rt);

    const concat_prototype = try core.Object.create(rt, core.class.ids.object, null);
    defer concat_prototype.value().free(rt);
    const cached_concat_prototype = try global.cachedRealmValueSlot(rt, .iterator_concat_prototype);
    cached_concat_prototype.* = concat_prototype.value().dup();

    const fb_slice = try rt.memory.alloc(bytecode.FunctionBytecode, 1);
    const fb = &fb_slice[0];
    fb.* = bytecode.FunctionBytecode.init(&rt.memory, &rt.atoms, core.atom.ids.empty_string);
    fb.func_kind = .generator;
    try rt.gc.add(&fb.header);

    const symbol_atom = try rt.atoms.newValueSymbol("gc-iterator-concat-method-bytecode-symbol");
    fb.cpool = try rt.memory.alloc(core.Value, 1);
    fb.cpool[0] = core.Value.symbol(symbol_atom);
    fb.cpool_count = 1;

    var iterator_method = core.Value.functionBytecode(&fb.header);
    var iterator_method_alive = true;
    defer if (iterator_method_alive) iterator_method.free(rt);
    test_iterator_concat_method = iterator_method;
    defer test_iterator_concat_method = core.Value.undefinedValue();

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

pub fn qjsIteratorStaticCall(
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.Value,
    method_id: u32,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
    comptime iteratorFromCall: anytype,
    comptime iteratorConcatCall: anytype,
    comptime iteratorZipCall: anytype,
    comptime iteratorZipKeyedCall: anytype,
) !?core.Value {
    return switch (method_id) {
        @intFromEnum(builtins.iterator.StaticMethod.from) => try iteratorFromCall(ctx, output, global, args, caller_function, caller_frame),
        @intFromEnum(builtins.iterator.StaticMethod.concat) => try iteratorConcatCall(ctx, output, global, args),
        @intFromEnum(builtins.iterator.StaticMethod.zip) => try iteratorZipCall(ctx, output, global, args, caller_function, caller_frame),
        @intFromEnum(builtins.iterator.StaticMethod.zip_keyed) => try iteratorZipKeyedCall(ctx, output, global, args, caller_function, caller_frame),
        else => null,
    };
}

pub const IteratorZipMode = enum(u8) {
    shortest = 0,
    longest = 1,
    strict = 2,
};

pub const IteratorZipRecord = struct {
    iterator: core.Value,
    next: core.Value,
};

pub const IteratorZipCompletion = struct {
    err: ?IteratorZipError = null,
    exception: core.Value = core.Value.uninitialized(),

    pub fn initNormal() IteratorZipCompletion {
        return .{};
    }

    pub fn initThrow(ctx: *core.Context, err: anytype) IteratorZipCompletion {
        var completion = IteratorZipCompletion.initNormal();
        completion.capture(ctx, err);
        return completion;
    }

    pub fn capture(self: *IteratorZipCompletion, ctx: *core.Context, err: anytype) void {
        if (!self.exception.isUninitialized()) {
            const old_exception = self.exception;
            self.exception = core.Value.uninitialized();
            old_exception.free(ctx.runtime);
        }
        self.err = @errorCast(err);
        if (ctx.hasException()) self.exception = ctx.takeException();
    }

    pub fn restore(self: *const IteratorZipCompletion, ctx: *core.Context) void {
        if (ctx.hasException()) ctx.clearException();
        if (!self.exception.isUninitialized()) _ = ctx.throwValue(self.exception.dup());
    }

    pub fn deinit(self: *IteratorZipCompletion, rt: *core.Runtime) void {
        if (!self.exception.isUninitialized()) {
            const old_exception = self.exception;
            self.exception = core.Value.uninitialized();
            old_exception.free(rt);
        }
        self.err = null;
    }
};

const IteratorZipHelperKind = enum(u8) {
    zip = 7,
    zip_keyed = 8,
};

fn objectFromValue(value: core.Value) ?*core.Object {
    return property_ops.expectObject(value) catch null;
}

pub fn qjsIteratorZipCall(
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.Value,
    keyed: bool,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
    comptime getValueProperty: anytype,
    comptime iteratorForValue: anytype,
    comptime callValueOrBytecode: anytype,
    comptime valueTruthy: anytype,
    comptime stringValueUnitsEqualBytes: anytype,
    comptime objectRestOwnKeys: anytype,
    comptime proxyAwareOwnPropertyDescriptor: anytype,
    comptime proxyTrapKeyValue: anytype,
    comptime closeIterator: anytype,
    comptime isCallableValue: anytype,
) !core.Value {
    const rt = ctx.runtime;
    const rooted_args = args;
    var iters_val = core.Value.undefinedValue();
    var nexts_val = core.Value.undefinedValue();
    var pads_val = core.Value.undefinedValue();
    var keys_val = core.Value.undefinedValue();
    var padding_val = core.Value.undefinedValue();

    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &iters_val },
        .{ .value = &nexts_val },
        .{ .value = &pads_val },
        .{ .value = &keys_val },
        .{ .value = &padding_val },
    };
    var root_slices = [_]core.runtime.ValueRootSlice{
        .{ .constant = &rooted_args },
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

    const options = if (rooted_args.len >= 2) rooted_args[1] else core.Value.undefinedValue();
    const mode = try qjsIteratorZipModeFromOptions(ctx, output, global, options, caller_function, caller_frame, getValueProperty, stringValueUnitsEqualBytes);
    if (mode == .longest and rooted_args.len >= 2 and !options.isUndefined()) {
        const padding_key = try rt.internAtom("padding");
        defer rt.atoms.free(padding_key);
        const padding_value = try getValueProperty(ctx, output, global, options, padding_key, caller_function, caller_frame);
        errdefer padding_value.free(rt);
        if (!padding_value.isUndefined() and objectFromValue(padding_value) == null) return error.TypeError;
        padding_val = padding_value;
    }
    defer if (!padding_val.isUndefined()) padding_val.free(rt);

    const iters = try core.Object.create(rt, core.class.ids.object, null);
    iters_val = iters.value();
    errdefer {
        core.Object.destroyFromHeader(rt, &iters.header);
        iters_val = core.Value.undefinedValue();
    }
    const nexts = try core.Object.create(rt, core.class.ids.object, null);
    nexts_val = nexts.value();
    errdefer {
        core.Object.destroyFromHeader(rt, &nexts.header);
        nexts_val = core.Value.undefinedValue();
    }
    const pads = try core.Object.create(rt, core.class.ids.object, null);
    pads_val = pads.value();
    errdefer {
        core.Object.destroyFromHeader(rt, &pads.header);
        pads_val = core.Value.undefinedValue();
    }
    const keys = if (keyed) try core.Object.create(rt, core.class.ids.object, null) else null;
    if (keys) |k| keys_val = k.value();
    errdefer if (keys) |object| {
        core.Object.destroyFromHeader(rt, &object.header);
        keys_val = core.Value.undefinedValue();
    };

    const count = if (!keyed) blk: {
        var iterables_iterator = iteratorForValue(ctx, output, global, iterables, caller_function, caller_frame) catch |err| return err;
        defer if (!iterables_iterator.isUndefined()) iterables_iterator.free(rt);
        const iterables_next = try qjsIteratorZipNextMethod(ctx, output, global, iterables_iterator, caller_function, caller_frame, getValueProperty, isCallableValue);
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
            getValueProperty,
            iteratorForValue,
            callValueOrBytecode,
            valueTruthy,
            closeIterator,
            isCallableValue,
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
        getValueProperty,
        callValueOrBytecode,
        closeIterator,
        objectRestOwnKeys,
        proxyAwareOwnPropertyDescriptor,
        proxyTrapKeyValue,
        isCallableValue,
    );

    if (count > std.math.maxInt(i32)) return error.RangeError;
    return try qjsIteratorZipCreateHelper(rt, global, iters, nexts, pads, keys, count, mode, keyed);
}

pub fn qjsIteratorZipModeFromOptions(
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    global: *core.Object,
    options: core.Value,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
    comptime getValueProperty: anytype,
    comptime stringValueUnitsEqualBytes: anytype,
) !IteratorZipMode {
    if (options.isUndefined()) return .shortest;
    _ = objectFromValue(options) orelse return error.TypeError;
    const mode_key = try ctx.runtime.internAtom("mode");
    defer ctx.runtime.atoms.free(mode_key);
    const mode_value = try getValueProperty(ctx, output, global, options, mode_key, caller_function, caller_frame);
    defer mode_value.free(ctx.runtime);
    if (mode_value.isUndefined()) return .shortest;
    if (stringValueUnitsEqualBytes(mode_value, "shortest")) return .shortest;
    if (stringValueUnitsEqualBytes(mode_value, "longest")) return .longest;
    if (stringValueUnitsEqualBytes(mode_value, "strict")) return .strict;
    return error.TypeError;
}

pub fn qjsIteratorZipCollectIndexed(
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    global: *core.Object,
    iterables_iterator: core.Value,
    iterables_next: core.Value,
    iters: *core.Object,
    nexts: *core.Object,
    pads: *core.Object,
    padding: core.Value,
    mode: IteratorZipMode,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
    comptime getValueProperty: anytype,
    comptime iteratorForValue: anytype,
    comptime callValueOrBytecode: anytype,
    comptime valueTruthy: anytype,
    comptime closeIterator: anytype,
    comptime isCallableValue: anytype,
) !usize {
    var count: usize = 0;

    while (true) {
        const item_result = callValueOrBytecode(ctx, output, global, iterables_iterator, iterables_next, &.{}, caller_function, caller_frame) catch |err| {
            return qjsIteratorZipCloseAllAndPropagate(ctx, output, global, iters, count, err, null, caller_function, caller_frame, closeIterator);
        };
        defer item_result.free(ctx.runtime);
        const item_object = objectFromValue(item_result) orelse {
            return qjsIteratorZipCloseAllAndPropagate(ctx, output, global, iters, count, error.TypeError, null, caller_function, caller_frame, closeIterator);
        };
        const done_value = getValueProperty(ctx, output, global, item_object.value(), core.atom.predefinedId("done", .string).?, caller_function, caller_frame) catch |err| {
            return qjsIteratorZipCloseAllAndPropagate(ctx, output, global, iters, count, err, null, caller_function, caller_frame, closeIterator);
        };
        defer done_value.free(ctx.runtime);
        if (valueTruthy(done_value)) break;
        const item = getValueProperty(ctx, output, global, item_object.value(), core.atom.predefinedId("value", .string).?, caller_function, caller_frame) catch |err| {
            return qjsIteratorZipCloseAllAndPropagate(ctx, output, global, iters, count, err, null, caller_function, caller_frame, closeIterator);
        };
        defer item.free(ctx.runtime);
        const record = qjsIteratorZipFlattenableRecord(ctx, output, global, item, caller_function, caller_frame, getValueProperty, callValueOrBytecode, isCallableValue) catch |err| {
            return qjsIteratorZipCloseAllAndPropagate(ctx, output, global, iters, count, err, iterables_iterator, caller_function, caller_frame, closeIterator);
        };
        defer record.iterator.free(ctx.runtime);
        defer record.next.free(ctx.runtime);
        try qjsIteratorZipStoreIndex(ctx.runtime, iters, count, record.iterator);
        try qjsIteratorZipStoreIndex(ctx.runtime, nexts, count, record.next);
        count += 1;
    }

    if (mode == .longest) {
        if (!padding.isUndefined() and !padding.isNull()) {
            var padding_iterator = iteratorForValue(ctx, output, global, padding, caller_function, caller_frame) catch |err| {
                return qjsIteratorZipCloseAllAndPropagate(ctx, output, global, iters, count, err, null, caller_function, caller_frame, closeIterator);
            };
            defer if (!padding_iterator.isUndefined()) padding_iterator.free(ctx.runtime);
            const padding_next = qjsIteratorZipNextMethod(ctx, output, global, padding_iterator, caller_function, caller_frame, getValueProperty, isCallableValue) catch |err| {
                return qjsIteratorZipCloseAllAndPropagate(ctx, output, global, iters, count, err, null, caller_function, caller_frame, closeIterator);
            };
            defer padding_next.free(ctx.runtime);

            var index: usize = 0;
            var done = false;
            while (index < count) : (index += 1) {
                const pad_step = callValueOrBytecode(ctx, output, global, padding_iterator, padding_next, &.{}, caller_function, caller_frame) catch |err| {
                    padding_iterator.free(ctx.runtime);
                    padding_iterator = core.Value.undefinedValue();
                    return qjsIteratorZipCloseAllAndPropagate(ctx, output, global, iters, count, err, null, caller_function, caller_frame, closeIterator);
                };
                defer pad_step.free(ctx.runtime);
                const pad_object = objectFromValue(pad_step) orelse {
                    padding_iterator.free(ctx.runtime);
                    padding_iterator = core.Value.undefinedValue();
                    return qjsIteratorZipCloseAllAndPropagate(ctx, output, global, iters, count, error.TypeError, null, caller_function, caller_frame, closeIterator);
                };
                const done_value = getValueProperty(ctx, output, global, pad_object.value(), core.atom.predefinedId("done", .string).?, caller_function, caller_frame) catch |err| {
                    padding_iterator.free(ctx.runtime);
                    padding_iterator = core.Value.undefinedValue();
                    return qjsIteratorZipCloseAllAndPropagate(ctx, output, global, iters, count, err, null, caller_function, caller_frame, closeIterator);
                };
                defer done_value.free(ctx.runtime);
                done = valueTruthy(done_value);
                const value = getValueProperty(ctx, output, global, pad_object.value(), core.atom.predefinedId("value", .string).?, caller_function, caller_frame) catch |err| {
                    padding_iterator.free(ctx.runtime);
                    padding_iterator = core.Value.undefinedValue();
                    return qjsIteratorZipCloseAllAndPropagate(ctx, output, global, iters, count, err, null, caller_function, caller_frame, closeIterator);
                };
                defer value.free(ctx.runtime);
                if (done) break;
                try qjsIteratorZipStoreIndex(ctx.runtime, pads, index, value);
            }
            if (!done) {
                qjsIteratorZipClose(ctx, output, global, padding_iterator, caller_function, caller_frame, closeIterator) catch |err| {
                    padding_iterator.free(ctx.runtime);
                    padding_iterator = core.Value.undefinedValue();
                    return qjsIteratorZipCloseAllAndPropagate(ctx, output, global, iters, count, err, null, caller_function, caller_frame, closeIterator);
                };
            }
            while (index < count) : (index += 1) {
                try qjsIteratorZipStoreIndex(ctx.runtime, pads, index, core.Value.undefinedValue());
            }
        } else {
            var index: usize = 0;
            while (index < count) : (index += 1) {
                try qjsIteratorZipStoreIndex(ctx.runtime, pads, index, core.Value.undefinedValue());
            }
        }
    }

    return count;
}

pub fn qjsIteratorZipCollectKeyed(
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    global: *core.Object,
    iterables: *core.Object,
    iters: *core.Object,
    nexts: *core.Object,
    pads: *core.Object,
    keys: *core.Object,
    padding: core.Value,
    mode: IteratorZipMode,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
    comptime getValueProperty: anytype,
    comptime callValueOrBytecode: anytype,
    comptime closeIterator: anytype,
    comptime objectRestOwnKeys: anytype,
    comptime proxyAwareOwnPropertyDescriptor: anytype,
    comptime proxyTrapKeyValue: anytype,
    comptime isCallableValue: anytype,
) !usize {
    const own_keys = try objectRestOwnKeys(ctx, output, global, iterables);
    defer core.Object.freeKeys(ctx.runtime, own_keys);

    var count: usize = 0;
    for (own_keys) |key| {
        const desc = proxyAwareOwnPropertyDescriptor(ctx, output, global, iterables, key, caller_function, caller_frame) catch |err| {
            return qjsIteratorZipCloseAllAndPropagate(ctx, output, global, iters, count, err, null, caller_function, caller_frame, closeIterator);
        } orelse continue;
        defer desc.destroy(ctx.runtime);
        if (desc.enumerable != true) continue;

        const iter = getValueProperty(ctx, output, global, iterables.value(), key, caller_function, caller_frame) catch |err| {
            return qjsIteratorZipCloseAllAndPropagate(ctx, output, global, iters, count, err, null, caller_function, caller_frame, closeIterator);
        };
        defer iter.free(ctx.runtime);
        if (iter.isUndefined()) continue;

        const record = qjsIteratorZipFlattenableRecord(ctx, output, global, iter, caller_function, caller_frame, getValueProperty, callValueOrBytecode, isCallableValue) catch |err| {
            return qjsIteratorZipCloseAllAndPropagate(ctx, output, global, iters, count, err, null, caller_function, caller_frame, closeIterator);
        };
        defer record.iterator.free(ctx.runtime);
        defer record.next.free(ctx.runtime);
        const key_value = proxyTrapKeyValue(ctx.runtime, key) catch |err| {
            return qjsIteratorZipCloseAllAndPropagate(ctx, output, global, iters, count, err, null, caller_function, caller_frame, closeIterator);
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
                    return qjsIteratorZipCloseAllAndPropagate(ctx, output, global, iters, count, err, null, caller_function, caller_frame, closeIterator);
                };
                defer ctx.runtime.atoms.free(key);
                const pad_value = getValueProperty(ctx, output, global, padding, key, caller_function, caller_frame) catch |err| {
                    return qjsIteratorZipCloseAllAndPropagate(ctx, output, global, iters, count, err, null, caller_function, caller_frame, closeIterator);
                };
                defer pad_value.free(ctx.runtime);
                try qjsIteratorZipStoreIndex(ctx.runtime, pads, index, pad_value);
            } else {
                try qjsIteratorZipStoreIndex(ctx.runtime, pads, index, core.Value.undefinedValue());
            }
        }
    }

    return count;
}

pub fn qjsIteratorZipFlattenableRecord(
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.Value,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
    comptime getValueProperty: anytype,
    comptime callValueOrBytecode: anytype,
    comptime isCallableValue: anytype,
) !IteratorZipRecord {
    _ = objectFromValue(value) orelse return error.TypeError;
    const symbol_key = core.atom.predefinedId("Symbol.iterator", .symbol) orelse return error.TypeError;
    const iterator_method = try getValueProperty(ctx, output, global, value, symbol_key, caller_function, caller_frame);
    defer iterator_method.free(ctx.runtime);
    const iterator_value = if (!iterator_method.isUndefined() and !iterator_method.isNull()) blk: {
        if (!isCallableValue(iterator_method)) return error.TypeError;
        const iterator = try callValueOrBytecode(ctx, output, global, value, iterator_method, &.{}, caller_function, caller_frame);
        errdefer iterator.free(ctx.runtime);
        _ = objectFromValue(iterator) orelse return error.TypeError;
        break :blk iterator;
    } else value.dup();
    errdefer iterator_value.free(ctx.runtime);

    const next_value = try qjsIteratorZipNextMethod(ctx, output, global, iterator_value, caller_function, caller_frame, getValueProperty, isCallableValue);
    errdefer next_value.free(ctx.runtime);
    return .{ .iterator = iterator_value, .next = next_value };
}

pub fn qjsIteratorZipNextMethod(
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    global: *core.Object,
    iterator_value: core.Value,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
    comptime getValueProperty: anytype,
    comptime isCallableValue: anytype,
) !core.Value {
    _ = isCallableValue;
    const iterator = objectFromValue(iterator_value) orelse return error.TypeError;
    if (iterator.cachedIteratorNext()) |cached| return cached.dup();
    const next_key = try ctx.runtime.internAtom("next");
    defer ctx.runtime.atoms.free(next_key);
    const next_value = try getValueProperty(ctx, output, global, iterator_value, next_key, caller_function, caller_frame);
    errdefer next_value.free(ctx.runtime);
    return next_value;
}

pub fn qjsIteratorZipCreateHelper(
    rt: *core.Runtime,
    global: *core.Object,
    iters: *core.Object,
    nexts: *core.Object,
    pads: *core.Object,
    keys: ?*core.Object,
    count: usize,
    mode: IteratorZipMode,
    keyed: bool,
) !core.Value {
    var helper_value = core.Value.undefinedValue();
    var iters_value = iters.value();
    var nexts_value = nexts.value();
    var pads_value = pads.value();
    var keys_value = if (keys) |keys_object| keys_object.value() else core.Value.undefinedValue();
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
    helper.iteratorTargetSlot().* = iters_value;
    helper.iteratorZipNextsSlot().* = nexts_value;
    helper.iteratorZipPadsSlot().* = pads_value;
    if (keys != null) helper.iteratorZipKeysSlot().* = keys_value;
    return helper_value;
}

pub fn qjsIteratorZipStoreIndex(rt: *core.Runtime, object: *core.Object, index: usize, value: core.Value) !void {
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
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    const object = try core.Object.create(rt, core.class.ids.object, null);
    defer object.value().free(rt);

    const fb_slice = try rt.memory.alloc(bytecode.FunctionBytecode, 1);
    const fb = &fb_slice[0];
    fb.* = bytecode.FunctionBytecode.init(&rt.memory, &rt.atoms, core.atom.ids.empty_string);
    fb.func_kind = .generator;
    try rt.gc.add(&fb.header);

    const symbol_atom = try rt.atoms.newValueSymbol("gc-iterator-zip-store-bytecode-symbol");
    fb.cpool = try rt.memory.alloc(core.Value, 1);
    fb.cpool[0] = core.Value.symbol(symbol_atom);
    fb.cpool_count = 1;

    var stored_value = core.Value.functionBytecode(&fb.header);
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
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    const object = try core.Object.create(rt, core.class.ids.object, null);
    defer object.value().free(rt);

    const symbol_atom = try rt.atoms.newValueSymbol("gc-iterator-zip-store-symbol");
    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    try qjsIteratorZipStoreIndex(rt, object, 0, core.Value.symbol(symbol_atom));

    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    {
        const stored = qjsIteratorZipGetIndex(object, 0);
        defer stored.free(rt);
        try std.testing.expect(stored.same(core.Value.symbol(symbol_atom)));
    }

    _ = object.deleteProperty(rt, core.atom.atomFromUInt32(0));
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

pub fn qjsIteratorZipGetIndex(object: *core.Object, index: usize) core.Value {
    return object.getProperty(core.atom.atomFromUInt32(@intCast(index)));
}

pub fn qjsIteratorZipSetIndex(rt: *core.Runtime, object: *core.Object, index: usize, value: core.Value) !void {
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
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    global: *core.Object,
    completion: *IteratorZipCompletion,
    iterator_value: core.Value,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
    comptime closeIterator: anytype,
) void {
    qjsIteratorZipClose(ctx, output, global, iterator_value, caller_function, caller_frame, closeIterator) catch |err| {
        if (completion.err == null) {
            completion.capture(ctx, err);
        } else if (ctx.hasException()) {
            ctx.clearException();
        }
        completion.restore(ctx);
    };
}

pub fn qjsIteratorZipCloseAllWithCompletion(
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    global: *core.Object,
    completion: *IteratorZipCompletion,
    iters: *core.Object,
    count: usize,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
    comptime closeIterator: anytype,
) !void {
    var index = count;
    while (index > 0) {
        index -= 1;
        const iterator_value = qjsIteratorZipGetIndex(iters, index);
        defer iterator_value.free(ctx.runtime);
        try qjsIteratorZipSetIndex(ctx.runtime, iters, index, core.Value.undefinedValue());
        if (iterator_value.isUndefined() or iterator_value.isNull()) continue;
        qjsIteratorZipCloseWithCompletion(ctx, output, global, completion, iterator_value, caller_function, caller_frame, closeIterator);
    }
}

pub fn qjsIteratorZipClose(
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    global: *core.Object,
    iterator_value: core.Value,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
    comptime closeIterator: anytype,
) !void {
    try closeIterator(ctx, output, global, iterator_value, caller_function, caller_frame);
}

pub fn qjsIteratorZipCloseAllAndPropagate(
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    global: *core.Object,
    iters: *core.Object,
    count: usize,
    err: anytype,
    extra_iterator: ?core.Value,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
    comptime closeIterator: anytype,
) IteratorZipError {
    var completion = IteratorZipCompletion.initThrow(ctx, err);
    defer completion.deinit(ctx.runtime);
    qjsIteratorZipCloseAllWithCompletion(ctx, output, global, &completion, iters, count, caller_function, caller_frame, closeIterator) catch |close_err| {
        completion.restore(ctx);
        return close_err;
    };
    if (extra_iterator) |iterator_value| {
        qjsIteratorZipCloseWithCompletion(ctx, output, global, &completion, iterator_value, caller_function, caller_frame, closeIterator);
    }
    completion.restore(ctx);
    return completion.err orelse err;
}

const IteratorStep = struct {
    value: core.Value,
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
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    global: *core.Object,
    iterator_value: core.Value,
    err: anytype,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
    comptime closeIterator: anytype,
) IteratorZipError {
    var completion = IteratorZipCompletion.initThrow(ctx, err);
    defer completion.deinit(ctx.runtime);
    qjsIteratorZipCloseWithCompletion(ctx, output, global, &completion, iterator_value, caller_function, caller_frame, closeIterator);
    completion.restore(ctx);
    return completion.err orelse err;
}

fn iteratorHelperCloseWithCompletionAndPropagate(
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    global: *core.Object,
    helper: *core.Object,
    err: anytype,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
    comptime closeIterator: anytype,
) IteratorZipError {
    var completion = IteratorZipCompletion.initThrow(ctx, err);
    defer completion.deinit(ctx.runtime);
    qjsIteratorHelperClose(ctx, output, global, helper, caller_function, caller_frame, closeIterator) catch |close_err| {
        if (ctx.hasException()) ctx.clearException();
        completion.restore(ctx);
        return close_err;
    };
    completion.restore(ctx);
    return completion.err orelse err;
}

pub fn qjsIteratorPrototypeMethodCall(
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.Value,
    args: []const core.Value,
    method_id: u32,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
    comptime createIteratorResult: anytype,
    comptime getValueProperty: anytype,
    comptime toPrimitiveForNumber: anytype,
    comptime callValueOrBytecode: anytype,
    comptime valueTruthy: anytype,
    comptime closeIterator: anytype,
    comptime arrayPrototypeFromGlobalFn: anytype,
    comptime isCallableValue: anytype,
) !?core.Value {
    _ = createIteratorResult;
    return switch (method_id) {
        @intFromEnum(builtins.iterator.PrototypeMethod.to_array) => try qjsIteratorToArrayCall(ctx, output, global, receiver, caller_function, caller_frame, getValueProperty, callValueOrBytecode, valueTruthy, arrayPrototypeFromGlobalFn, isCallableValue),
        @intFromEnum(builtins.iterator.PrototypeMethod.every) => try qjsIteratorPredicateCall(ctx, output, global, receiver, args, .every, caller_function, caller_frame, getValueProperty, callValueOrBytecode, valueTruthy, closeIterator, isCallableValue),
        @intFromEnum(builtins.iterator.PrototypeMethod.find) => try qjsIteratorPredicateCall(ctx, output, global, receiver, args, .find, caller_function, caller_frame, getValueProperty, callValueOrBytecode, valueTruthy, closeIterator, isCallableValue),
        @intFromEnum(builtins.iterator.PrototypeMethod.for_each) => try qjsIteratorPredicateCall(ctx, output, global, receiver, args, .for_each, caller_function, caller_frame, getValueProperty, callValueOrBytecode, valueTruthy, closeIterator, isCallableValue),
        @intFromEnum(builtins.iterator.PrototypeMethod.reduce) => try qjsIteratorReduceCall(ctx, output, global, receiver, args, caller_function, caller_frame, getValueProperty, callValueOrBytecode, closeIterator, valueTruthy, isCallableValue),
        @intFromEnum(builtins.iterator.PrototypeMethod.some) => try qjsIteratorPredicateCall(ctx, output, global, receiver, args, .some, caller_function, caller_frame, getValueProperty, callValueOrBytecode, valueTruthy, closeIterator, isCallableValue),
        @intFromEnum(builtins.iterator.PrototypeMethod.map) => try qjsIteratorCreateCallbackHelper(ctx, output, global, receiver, args, .map, caller_function, caller_frame, getValueProperty, closeIterator, isCallableValue),
        @intFromEnum(builtins.iterator.PrototypeMethod.filter) => try qjsIteratorCreateCallbackHelper(ctx, output, global, receiver, args, .filter, caller_function, caller_frame, getValueProperty, closeIterator, isCallableValue),
        @intFromEnum(builtins.iterator.PrototypeMethod.take) => try qjsIteratorCreateLimitHelper(ctx, output, global, receiver, args, .take, caller_function, caller_frame, getValueProperty, toPrimitiveForNumber, closeIterator),
        @intFromEnum(builtins.iterator.PrototypeMethod.drop) => try qjsIteratorCreateLimitHelper(ctx, output, global, receiver, args, .drop, caller_function, caller_frame, getValueProperty, toPrimitiveForNumber, closeIterator),
        @intFromEnum(builtins.iterator.PrototypeMethod.flat_map) => try qjsIteratorCreateCallbackHelper(ctx, output, global, receiver, args, .flatMap, caller_function, caller_frame, getValueProperty, closeIterator, isCallableValue),
        @intFromEnum(builtins.iterator.PrototypeMethod.dispose) => try qjsIteratorDisposeCall(ctx, output, global, receiver, caller_function, caller_frame, getValueProperty, callValueOrBytecode, isCallableValue),
        else => null,
    };
}

fn qjsIteratorDisposeCall(
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.Value,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
    comptime getValueProperty: anytype,
    comptime callValueOrBytecode: anytype,
    comptime isCallableValue: anytype,
) !core.Value {
    const return_key = try ctx.runtime.internAtom("return");
    defer ctx.runtime.atoms.free(return_key);
    const return_method = try getValueProperty(ctx, output, global, receiver, return_key, caller_function, caller_frame);
    defer return_method.free(ctx.runtime);
    if (return_method.isUndefined() or return_method.isNull()) return core.Value.undefinedValue();
    if (!isCallableValue(return_method)) return error.TypeError;
    const result = try callValueOrBytecode(ctx, output, global, receiver, return_method, &.{}, caller_function, caller_frame);
    result.free(ctx.runtime);
    return core.Value.undefinedValue();
}

fn qjsIteratorToArrayCall(
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.Value,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
    comptime getValueProperty: anytype,
    comptime callValueOrBytecode: anytype,
    comptime valueTruthy: anytype,
    comptime arrayPrototypeFromGlobalFn: anytype,
    comptime isCallableValue: anytype,
) !core.Value {
    const iterator = objectFromValue(receiver) orelse return error.TypeError;
    const next_key = try ctx.runtime.internAtom("next");
    defer ctx.runtime.atoms.free(next_key);
    const next_method = try getValueProperty(ctx, output, global, iterator.value(), next_key, caller_function, caller_frame);
    defer next_method.free(ctx.runtime);
    if (!isCallableValue(next_method)) return error.TypeError;

    const out = try core.Object.createArray(ctx.runtime, arrayPrototypeFromGlobalFn(ctx.runtime, global));
    errdefer core.Object.destroyFromHeader(ctx.runtime, &out.header);
    var index: u32 = 0;
    while (true) : (index += 1) {
        const next = try callValueOrBytecode(ctx, output, global, iterator.value(), next_method, &.{}, caller_function, caller_frame);
        defer next.free(ctx.runtime);
        const next_object = objectFromValue(next) orelse return error.TypeError;
        const done_value = try getValueProperty(ctx, output, global, next_object.value(), core.atom.predefinedId("done", .string).?, caller_function, caller_frame);
        defer done_value.free(ctx.runtime);
        if (valueTruthy(done_value)) {
            out.length = index;
            return out.value();
        }
        const value = try getValueProperty(ctx, output, global, next_object.value(), core.atom.predefinedId("value", .string).?, caller_function, caller_frame);
        defer value.free(ctx.runtime);
        try out.defineOwnProperty(ctx.runtime, core.atom.atomFromUInt32(index), core.Descriptor.data(value, true, true, true));
    }
}

fn qjsIteratorPredicateCall(
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.Value,
    args: []const core.Value,
    kind: IteratorPredicateKind,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
    comptime getValueProperty: anytype,
    comptime callValueOrBytecode: anytype,
    comptime valueTruthy: anytype,
    comptime closeIterator: anytype,
    comptime isCallableValue: anytype,
) !core.Value {
    const iterator = objectFromValue(receiver) orelse return error.TypeError;
    if (args.len < 1 or !isCallableValue(args[0])) {
        return iteratorCloseWithCompletionAndPropagate(ctx, output, global, iterator.value(), error.TypeError, caller_function, caller_frame, closeIterator);
    }
    const next_key = try ctx.runtime.internAtom("next");
    defer ctx.runtime.atoms.free(next_key);
    const next_method = try getValueProperty(ctx, output, global, iterator.value(), next_key, caller_function, caller_frame);
    defer next_method.free(ctx.runtime);
    if (!isCallableValue(next_method)) return error.TypeError;

    var index: usize = 0;
    while (true) : (index += 1) {
        const step = try iteratorStepWithNext(ctx, output, global, iterator.value(), next_method, caller_function, caller_frame, getValueProperty, callValueOrBytecode, valueTruthy);
        defer step.value.free(ctx.runtime);
        if (step.done) {
            return switch (kind) {
                .every => core.Value.boolean(true),
                .some => core.Value.boolean(false),
                .find, .for_each => core.Value.undefinedValue(),
            };
        }

        const result = callValueOrBytecode(
            ctx,
            output,
            global,
            core.Value.undefinedValue(),
            args[0],
            &.{ step.value, core.Value.int32(@intCast(index)) },
            caller_function,
            caller_frame,
        ) catch |err| {
            return iteratorCloseWithCompletionAndPropagate(ctx, output, global, iterator.value(), err, caller_function, caller_frame, closeIterator);
        };
        defer result.free(ctx.runtime);
        const truthy = valueTruthy(result);
        switch (kind) {
            .every => if (!truthy) {
                try closeIterator(ctx, output, global, iterator.value(), caller_function, caller_frame);
                return core.Value.boolean(false);
            },
            .some => if (truthy) {
                try closeIterator(ctx, output, global, iterator.value(), caller_function, caller_frame);
                return core.Value.boolean(true);
            },
            .find => if (truthy) {
                try closeIterator(ctx, output, global, iterator.value(), caller_function, caller_frame);
                return step.value.dup();
            },
            .for_each => {},
        }
    }
}

fn qjsIteratorReduceCall(
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.Value,
    args: []const core.Value,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
    comptime getValueProperty: anytype,
    comptime callValueOrBytecode: anytype,
    comptime closeIterator: anytype,
    comptime valueTruthy: anytype,
    comptime isCallableValue: anytype,
) !core.Value {
    const iterator = objectFromValue(receiver) orelse return error.TypeError;
    if (args.len < 1 or !isCallableValue(args[0])) {
        return iteratorCloseWithCompletionAndPropagate(ctx, output, global, iterator.value(), error.TypeError, caller_function, caller_frame, closeIterator);
    }
    const next_key = try ctx.runtime.internAtom("next");
    defer ctx.runtime.atoms.free(next_key);
    const next_method = try getValueProperty(ctx, output, global, iterator.value(), next_key, caller_function, caller_frame);
    defer next_method.free(ctx.runtime);
    if (!isCallableValue(next_method)) return error.TypeError;

    var index: usize = 0;
    var accumulator = if (args.len >= 2) args[1].dup() else blk: {
        const first = try iteratorStepWithNext(ctx, output, global, iterator.value(), next_method, caller_function, caller_frame, getValueProperty, callValueOrBytecode, valueTruthy);
        defer if (first.done) first.value.free(ctx.runtime);
        if (first.done) return error.TypeError;
        index = 1;
        break :blk first.value;
    };
    errdefer accumulator.free(ctx.runtime);

    while (true) : (index += 1) {
        const step = try iteratorStepWithNext(ctx, output, global, iterator.value(), next_method, caller_function, caller_frame, getValueProperty, callValueOrBytecode, valueTruthy);
        defer step.value.free(ctx.runtime);
        if (step.done) return accumulator;

        const result = callValueOrBytecode(
            ctx,
            output,
            global,
            core.Value.undefinedValue(),
            args[0],
            &.{ accumulator, step.value, core.Value.int32(@intCast(index)) },
            caller_function,
            caller_frame,
        ) catch |err| {
            return iteratorCloseWithCompletionAndPropagate(ctx, output, global, iterator.value(), err, caller_function, caller_frame, closeIterator);
        };
        accumulator.free(ctx.runtime);
        accumulator = result;
    }
}

fn iteratorStepWithNext(
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    global: *core.Object,
    iterator_value: core.Value,
    next_method: core.Value,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
    comptime getValueProperty: anytype,
    comptime callValueOrBytecode: anytype,
    comptime valueTruthy: anytype,
) !IteratorStep {
    const next_result = try callValueOrBytecode(ctx, output, global, iterator_value, next_method, &.{}, caller_function, caller_frame);
    defer next_result.free(ctx.runtime);
    const next_object = objectFromValue(next_result) orelse return error.TypeError;
    const done = try getValueProperty(ctx, output, global, next_object.value(), core.atom.predefinedId("done", .string).?, caller_function, caller_frame);
    defer done.free(ctx.runtime);
    if (valueTruthy(done)) return .{ .value = core.Value.undefinedValue(), .done = true };
    const value = try getValueProperty(ctx, output, global, next_object.value(), core.atom.predefinedId("value", .string).?, caller_function, caller_frame);
    return .{ .value = value, .done = false };
}

fn qjsIteratorCreateCallbackHelper(
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.Value,
    args: []const core.Value,
    kind: IteratorHelperKind,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
    comptime getValueProperty: anytype,
    comptime closeIterator: anytype,
    comptime isCallableValue: anytype,
) !core.Value {
    _ = objectFromValue(receiver) orelse return error.TypeError;
    if (args.len < 1 or !isCallableValue(args[0])) {
        return iteratorCloseWithCompletionAndPropagate(ctx, output, global, receiver, error.TypeError, caller_function, caller_frame, closeIterator);
    }
    return try qjsIteratorCreateHelper(ctx, output, global, receiver, kind, args[0], null, caller_function, caller_frame, getValueProperty);
}

fn qjsIteratorCreateLimitHelper(
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.Value,
    args: []const core.Value,
    kind: IteratorHelperKind,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
    comptime getValueProperty: anytype,
    comptime toPrimitiveForNumber: anytype,
    comptime closeIterator: anytype,
) !core.Value {
    _ = objectFromValue(receiver) orelse return error.TypeError;
    const limit = qjsIteratorLimitArgument(ctx, output, global, receiver, args, toPrimitiveForNumber) catch |err| {
        return iteratorCloseWithCompletionAndPropagate(ctx, output, global, receiver, err, caller_function, caller_frame, closeIterator);
    };
    return try qjsIteratorCreateHelper(ctx, output, global, receiver, kind, core.Value.undefinedValue(), limit, caller_function, caller_frame, getValueProperty);
}

fn qjsIteratorLimitArgument(
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.Value,
    args: []const core.Value,
    comptime toPrimitiveForNumber: anytype,
) !usize {
    _ = receiver;
    const limit_arg = if (args.len > 0) args[0] else core.Value.undefinedValue();
    const primitive = if (limit_arg.isObject())
        try toPrimitiveForNumber(ctx, output, global, limit_arg)
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
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.Value,
    kind: IteratorHelperKind,
    callback: core.Value,
    limit: ?usize,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
    comptime getValueProperty: anytype,
) !core.Value {
    var rooted_receiver = receiver;
    var rooted_callback = callback;
    var rooted_next_method = core.Value.undefinedValue();
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
    helper.iteratorTargetSlot().* = rooted_receiver.dup();
    helper.iteratorKindSlot().* = @intFromEnum(kind);
    helper.iteratorIndexSlot().* = limit orelse 0;
    helper.iteratorNextSlot().* = rooted_next_method.dup();
    if (!rooted_callback.isUndefined()) helper.iteratorCallbackSlot().* = rooted_callback.dup();
    return helper.value();
}

test "qjsIteratorCreateHelper roots direct function bytecode callback while creating helper" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    const ctx = try core.Context.create(rt);
    defer ctx.destroy();
    const global = try core.Object.create(rt, core.class.ids.object, null);
    defer global.value().free(rt);
    const iterator = try core.Object.create(rt, core.class.ids.object, null);
    defer iterator.value().free(rt);

    const next_key = try rt.internAtom("next");
    defer rt.atoms.free(next_key);
    try iterator.defineOwnProperty(rt, next_key, core.Descriptor.data(core.Value.int32(1), true, true, true));

    const helper_prototype = try core.Object.create(rt, core.class.ids.object, null);
    defer helper_prototype.value().free(rt);
    const cached_helper_prototype = try global.cachedRealmValueSlot(rt, .iterator_helper_prototype);
    cached_helper_prototype.* = helper_prototype.value().dup();

    const fb_slice = try rt.memory.alloc(bytecode.FunctionBytecode, 1);
    const fb = &fb_slice[0];
    fb.* = bytecode.FunctionBytecode.init(&rt.memory, &rt.atoms, core.atom.ids.empty_string);
    fb.func_kind = .generator;
    try rt.gc.add(&fb.header);

    const symbol_atom = try rt.atoms.newValueSymbol("gc-iterator-helper-callback-bytecode-symbol");
    fb.cpool = try rt.memory.alloc(core.Value, 1);
    fb.cpool[0] = core.Value.symbol(symbol_atom);
    fb.cpool_count = 1;

    var callback = core.Value.functionBytecode(&fb.header);
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
    rt: *core.Runtime,
    results: *core.Object,
    keys: ?*core.Object,
    index: usize,
    value: core.Value,
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
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    global: *core.Object,
    helper: *core.Object,
    iters: *core.Object,
    count: usize,
    current_index: ?usize,
    err: anytype,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
    comptime closeIterator: anytype,
) IteratorZipError {
    var completion = IteratorZipCompletion.initThrow(ctx, err);
    defer completion.deinit(ctx.runtime);
    helper.iteratorZipAliveSlot().* = 0;
    if (current_index) |index| {
        try qjsIteratorZipSetIndex(ctx.runtime, iters, index, core.Value.undefinedValue());
    }
    qjsIteratorZipCloseAllWithCompletion(ctx, output, global, &completion, iters, count, caller_function, caller_frame, closeIterator) catch |close_err| {
        completion.restore(ctx);
        return close_err;
    };
    try qjsIteratorHelperClear(ctx.runtime, helper);
    helper.iteratorZipStateSlot().* = 3;
    completion.restore(ctx);
    return completion.err orelse err;
}

fn qjsIteratorZipHelperNext(
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    global: *core.Object,
    helper: *core.Object,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
    comptime createIteratorResult: anytype,
    comptime getValueProperty: anytype,
    comptime callValueOrBytecode: anytype,
    comptime valueTruthy: anytype,
    comptime closeIterator: anytype,
    comptime arrayPrototypeFromGlobalFn: anytype,
) !core.Value {
    const state = helper.iteratorZipStateSlot().*;
    switch (state) {
        0, 1 => helper.iteratorZipStateSlot().* = 2,
        2 => return error.TypeError,
        3 => return try createIteratorResult(ctx.runtime, global, core.Value.undefinedValue(), true),
        else => return error.TypeError,
    }

    const iterator_value = (helper.iteratorTargetSlot().*) orelse return try createIteratorResult(ctx.runtime, global, core.Value.undefinedValue(), true);
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
        try core.Object.createArray(ctx.runtime, arrayPrototypeFromGlobalFn(ctx.runtime, global))
    else blk: {
        const object = try core.Object.create(ctx.runtime, core.class.ids.object, null);
        object.null_prototype = true;
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
        const step_result = callValueOrBytecode(ctx, output, global, iter, next_method, &.{}, caller_function, caller_frame) catch |err| {
            return qjsIteratorZipCompleteAbrupt(ctx, output, global, helper, iters, count, index, err, caller_function, caller_frame, closeIterator);
        };
        defer step_result.free(ctx.runtime);
        const step_object = objectFromValue(step_result) orelse {
            return qjsIteratorZipCompleteAbrupt(ctx, output, global, helper, iters, count, index, error.TypeError, caller_function, caller_frame, closeIterator);
        };
        const done_value = getValueProperty(ctx, output, global, step_object.value(), core.atom.predefinedId("done", .string).?, caller_function, caller_frame) catch |err| {
            return qjsIteratorZipCompleteAbrupt(ctx, output, global, helper, iters, count, index, err, caller_function, caller_frame, closeIterator);
        };
        defer done_value.free(ctx.runtime);
        if (!valueTruthy(done_value)) {
            if (mode == .strict and dones > 0) {
                return qjsIteratorZipCompleteAbrupt(ctx, output, global, helper, iters, count, null, error.TypeError, caller_function, caller_frame, closeIterator);
            }
            const value = getValueProperty(ctx, output, global, step_object.value(), core.atom.predefinedId("value", .string).?, caller_function, caller_frame) catch |err| {
                return qjsIteratorZipCompleteAbrupt(ctx, output, global, helper, iters, count, index, err, caller_function, caller_frame, closeIterator);
            };
            defer value.free(ctx.runtime);
            try qjsIteratorZipPutResult(ctx.runtime, results, keys, index, value);
            values += 1;
            continue;
        }

        if (alive > 0) alive -= 1;
        dones += 1;
        try qjsIteratorZipSetIndex(ctx.runtime, iters, index, core.Value.undefinedValue());
        helper.iteratorZipAliveSlot().* = alive;

        switch (mode) {
            .shortest => {
                var completion = IteratorZipCompletion.initNormal();
                defer completion.deinit(ctx.runtime);
                try qjsIteratorZipCloseAllWithCompletion(ctx, output, global, &completion, iters, count, caller_function, caller_frame, closeIterator);
                try qjsIteratorHelperClear(ctx.runtime, helper);
                helper.iteratorZipStateSlot().* = 3;
                if (completion.err) |err| {
                    completion.restore(ctx);
                    return err;
                }
                return try createIteratorResult(ctx.runtime, global, core.Value.undefinedValue(), true);
            },
            .longest => {
                if (alive < 1) {
                    try qjsIteratorHelperClear(ctx.runtime, helper);
                    helper.iteratorZipStateSlot().* = 3;
                    return try createIteratorResult(ctx.runtime, global, core.Value.undefinedValue(), true);
                }
                const pad = qjsIteratorZipGetIndex(pads, index);
                defer pad.free(ctx.runtime);
                try qjsIteratorZipPutResult(ctx.runtime, results, keys, index, pad);
            },
            .strict => {
                if (values > 0) {
                    return qjsIteratorZipCompleteAbrupt(ctx, output, global, helper, iters, count, null, error.TypeError, caller_function, caller_frame, closeIterator);
                }
            },
        }
    }

    if (values == 0) {
        try qjsIteratorHelperClear(ctx.runtime, helper);
        helper.iteratorZipStateSlot().* = 3;
        return try createIteratorResult(ctx.runtime, global, core.Value.undefinedValue(), true);
    }

    if (keys == null) results.length = @intCast(count);
    helper.iteratorZipStateSlot().* = 1;
    return try createIteratorResult(ctx.runtime, global, results_value, false);
}

fn qjsIteratorZipHelperReturn(
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    global: *core.Object,
    helper: *core.Object,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
    comptime createIteratorResult: anytype,
    comptime closeIterator: anytype,
) !core.Value {
    const state = helper.iteratorZipStateSlot().*;
    switch (state) {
        0 => helper.iteratorZipStateSlot().* = 3,
        1 => helper.iteratorZipStateSlot().* = 2,
        2 => return error.TypeError,
        3 => return try createIteratorResult(ctx.runtime, global, core.Value.undefinedValue(), true),
        else => return error.TypeError,
    }

    if ((helper.iteratorTargetSlot().*)) |iterator_value| {
        const iters = objectFromValue(iterator_value) orelse return error.TypeError;
        var completion = IteratorZipCompletion.initNormal();
        defer completion.deinit(ctx.runtime);
        try qjsIteratorZipCloseAllWithCompletion(ctx, output, global, &completion, iters, (helper.iteratorIndexSlot().*), caller_function, caller_frame, closeIterator);
        try qjsIteratorHelperClear(ctx.runtime, helper);
        helper.iteratorZipStateSlot().* = 3;
        if (completion.err) |err| {
            completion.restore(ctx);
            return err;
        }
        return try createIteratorResult(ctx.runtime, global, core.Value.undefinedValue(), true);
    }
    try qjsIteratorHelperClear(ctx.runtime, helper);
    helper.iteratorZipStateSlot().* = 3;
    return try createIteratorResult(ctx.runtime, global, core.Value.undefinedValue(), true);
}

pub fn qjsIteratorHelperNext(
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.Value,
    function_object: *core.Object,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
    comptime createIteratorResult: anytype,
    comptime getValueProperty: anytype,
    comptime callValueOrBytecode: anytype,
    comptime valueTruthy: anytype,
    comptime closeIterator: anytype,
    comptime arrayPrototypeFromGlobalFn: anytype,
    comptime isCallableValue: anytype,
) !?core.Value {
    if (function_object.iteratorHelperMethod() != 1) return null;
    const helper = objectFromValue(receiver) orelse return error.TypeError;
    if (helper.class_id != core.class.ids.iterator_helper) return error.TypeError;
    if (helper.generatorExecuting()) return error.TypeError;
    helper.generatorExecutingSlot().* = true;
    defer helper.generatorExecutingSlot().* = false;
    const iterator = (helper.iteratorTargetSlot().*) orelse return try createIteratorResult(ctx.runtime, global, core.Value.undefinedValue(), true);
    const kind: IteratorHelperKind = @enumFromInt((helper.iteratorKindSlot().*));

    switch (kind) {
        .zip, .zip_keyed => return try qjsIteratorZipHelperNext(ctx, output, global, helper, caller_function, caller_frame, createIteratorResult, getValueProperty, callValueOrBytecode, valueTruthy, closeIterator, arrayPrototypeFromGlobalFn),
        .concat => {
            while (true) {
                if (helper.iteratorData()) |inner_iterator| {
                    const inner_next = helper.iteratorInnerNext() orelse return error.TypeError;
                    const inner_step = try iteratorStepWithNext(ctx, output, global, inner_iterator, inner_next, caller_function, caller_frame, getValueProperty, callValueOrBytecode, valueTruthy);
                    defer inner_step.value.free(ctx.runtime);
                    if (!inner_step.done) return try createIteratorResult(ctx.runtime, global, inner_step.value, false);
                    try qjsIteratorHelperClearInner(ctx.runtime, helper);
                }

                const records = objectFromValue(iterator) orelse return error.TypeError;
                if ((helper.iteratorIndexSlot().*) >= records.length / 2) {
                    try qjsIteratorHelperClear(ctx.runtime, helper);
                    return try createIteratorResult(ctx.runtime, global, core.Value.undefinedValue(), true);
                }
                const item_index: u32 = @intCast((helper.iteratorIndexSlot().*) * 2);
                helper.iteratorIndexSlot().* += 1;
                const item = records.getProperty(core.atom.atomFromUInt32(item_index));
                defer item.free(ctx.runtime);
                const method = records.getProperty(core.atom.atomFromUInt32(item_index + 1));
                defer method.free(ctx.runtime);
                const inner_iterator = try callValueOrBytecode(ctx, output, global, item, method, &.{}, caller_function, caller_frame);
                defer inner_iterator.free(ctx.runtime);
                try qjsIteratorHelperSetInnerFromIterator(ctx, output, global, helper, inner_iterator, caller_function, caller_frame, getValueProperty);
            }
        },
        .take => {
            const next_method = helper.iteratorNext() orelse return error.TypeError;
            if ((helper.iteratorIndexSlot().*) == 0) {
                try qjsIteratorHelperClose(ctx, output, global, helper, caller_function, caller_frame, closeIterator);
                return try createIteratorResult(ctx.runtime, global, core.Value.undefinedValue(), true);
            }
            helper.iteratorIndexSlot().* -= 1;
            const step = try iteratorStepWithNext(ctx, output, global, iterator, next_method, caller_function, caller_frame, getValueProperty, callValueOrBytecode, valueTruthy);
            defer step.value.free(ctx.runtime);
            if (step.done) {
                try qjsIteratorHelperClear(ctx.runtime, helper);
                return try createIteratorResult(ctx.runtime, global, core.Value.undefinedValue(), true);
            }
            return try createIteratorResult(ctx.runtime, global, step.value, false);
        },
        .drop => {
            const next_method = helper.iteratorNext() orelse return error.TypeError;
            while ((helper.iteratorIndexSlot().*) > 0) : (helper.iteratorIndexSlot().* -= 1) {
                const skipped = try iteratorStepWithNext(ctx, output, global, iterator, next_method, caller_function, caller_frame, getValueProperty, callValueOrBytecode, valueTruthy);
                defer skipped.value.free(ctx.runtime);
                if (skipped.done) {
                    try qjsIteratorHelperClear(ctx.runtime, helper);
                    return try createIteratorResult(ctx.runtime, global, core.Value.undefinedValue(), true);
                }
            }
            const step = try iteratorStepWithNext(ctx, output, global, iterator, next_method, caller_function, caller_frame, getValueProperty, callValueOrBytecode, valueTruthy);
            defer step.value.free(ctx.runtime);
            if (step.done) {
                try qjsIteratorHelperClear(ctx.runtime, helper);
                return try createIteratorResult(ctx.runtime, global, core.Value.undefinedValue(), true);
            }
            return try createIteratorResult(ctx.runtime, global, step.value, false);
        },
        .map, .filter, .flatMap => {
            const next_method = helper.iteratorNext() orelse return error.TypeError;
            const callback = helper.iteratorCallback() orelse return error.TypeError;
            while (true) {
                if (kind == .flatMap) {
                    if (helper.iteratorData()) |inner_iterator| {
                        const inner_next = helper.iteratorInnerNext() orelse return error.TypeError;
                        const inner_step = try iteratorStepWithNext(ctx, output, global, inner_iterator, inner_next, caller_function, caller_frame, getValueProperty, callValueOrBytecode, valueTruthy);
                        defer inner_step.value.free(ctx.runtime);
                        if (!inner_step.done) return try createIteratorResult(ctx.runtime, global, inner_step.value, false);
                        try qjsIteratorHelperClearInner(ctx.runtime, helper);
                    }
                }
                const step = try iteratorStepWithNext(ctx, output, global, iterator, next_method, caller_function, caller_frame, getValueProperty, callValueOrBytecode, valueTruthy);
                defer step.value.free(ctx.runtime);
                if (step.done) {
                    try qjsIteratorHelperClear(ctx.runtime, helper);
                    return try createIteratorResult(ctx.runtime, global, core.Value.undefinedValue(), true);
                }
                const index = (helper.iteratorIndexSlot().*);
                helper.iteratorIndexSlot().* += 1;
                const mapped = callValueOrBytecode(
                    ctx,
                    output,
                    global,
                    core.Value.undefinedValue(),
                    callback,
                    &.{ step.value, core.Value.int32(@intCast(index)) },
                    caller_function,
                    caller_frame,
                ) catch |err| {
                    return iteratorHelperCloseWithCompletionAndPropagate(ctx, output, global, helper, err, caller_function, caller_frame, closeIterator);
                };
                defer mapped.free(ctx.runtime);
                if (kind == .map) return try createIteratorResult(ctx.runtime, global, mapped, false);
                if (kind == .flatMap) {
                    try qjsIteratorHelperSetInner(ctx, output, global, helper, mapped, caller_function, caller_frame, getValueProperty, callValueOrBytecode, isCallableValue);
                    continue;
                }
                if (valueTruthy(mapped)) return try createIteratorResult(ctx.runtime, global, step.value, false);
            }
        },
    }
}

fn qjsIteratorHelperSetInner(
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    global: *core.Object,
    helper: *core.Object,
    mapped: core.Value,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
    comptime getValueProperty: anytype,
    comptime callValueOrBytecode: anytype,
    comptime isCallableValue: anytype,
) !void {
    const mapped_object = objectFromValue(mapped) orelse return error.TypeError;
    const symbol_key = core.atom.predefinedId("Symbol.iterator", .symbol) orelse return error.TypeError;
    const iterator_method = try getValueProperty(ctx, output, global, mapped, symbol_key, caller_function, caller_frame);
    defer iterator_method.free(ctx.runtime);
    const inner_iterator = if (iterator_method.isUndefined() or iterator_method.isNull())
        mapped_object.value().dup()
    else blk: {
        if (!isCallableValue(iterator_method)) return error.TypeError;
        const value = try callValueOrBytecode(ctx, output, global, mapped, iterator_method, &.{}, caller_function, caller_frame);
        errdefer value.free(ctx.runtime);
        _ = objectFromValue(value) orelse return error.TypeError;
        break :blk value;
    };
    defer inner_iterator.free(ctx.runtime);
    try qjsIteratorHelperSetInnerFromIterator(ctx, output, global, helper, inner_iterator, caller_function, caller_frame, getValueProperty);
}

fn qjsIteratorHelperSetInnerFromIterator(
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    global: *core.Object,
    helper: *core.Object,
    inner_iterator: core.Value,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
    comptime getValueProperty: anytype,
) !void {
    _ = objectFromValue(inner_iterator) orelse return error.TypeError;
    const next_key = try ctx.runtime.internAtom("next");
    defer ctx.runtime.atoms.free(next_key);
    const inner_next = try getValueProperty(ctx, output, global, inner_iterator, next_key, caller_function, caller_frame);
    defer inner_next.free(ctx.runtime);
    const next_inner_iterator = inner_iterator.dup();
    const next_inner_next = inner_next.dup();
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
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.Value,
    function_object: *core.Object,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
    comptime createIteratorResult: anytype,
    comptime getValueProperty: anytype,
    comptime callValueOrBytecode: anytype,
    comptime valueTruthy: anytype,
    comptime closeIterator: anytype,
    comptime arrayPrototypeFromGlobalFn: anytype,
    comptime isCallableValue: anytype,
) !?core.Value {
    _ = getValueProperty;
    _ = callValueOrBytecode;
    _ = valueTruthy;
    _ = arrayPrototypeFromGlobalFn;
    _ = isCallableValue;
    if (function_object.iteratorHelperMethod() != 2) return null;
    const helper = objectFromValue(receiver) orelse return error.TypeError;
    if (helper.class_id != core.class.ids.iterator_helper) return error.TypeError;
    if ((helper.iteratorKindSlot().*) == @intFromEnum(IteratorHelperKind.zip) or
        (helper.iteratorKindSlot().*) == @intFromEnum(IteratorHelperKind.zip_keyed))
    {
        return try qjsIteratorZipHelperReturn(ctx, output, global, helper, caller_function, caller_frame, createIteratorResult, closeIterator);
    }
    if (helper.generatorExecuting()) return error.TypeError;
    helper.generatorExecutingSlot().* = true;
    defer helper.generatorExecutingSlot().* = false;
    try qjsIteratorHelperClose(ctx, output, global, helper, caller_function, caller_frame, closeIterator);
    return try createIteratorResult(ctx.runtime, global, core.Value.undefinedValue(), true);
}

fn qjsIteratorHelperClose(
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    global: *core.Object,
    helper: *core.Object,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
    comptime closeIterator: anytype,
) !void {
    try qjsIteratorHelperCloseInner(ctx, output, global, helper, caller_function, caller_frame, closeIterator);
    if ((helper.iteratorKindSlot().*) == @intFromEnum(IteratorHelperKind.concat)) {
        try qjsIteratorHelperClear(ctx.runtime, helper);
        return;
    }
    const iterator = (helper.iteratorTargetSlot().*) orelse return;
    closeIterator(ctx, output, global, iterator, caller_function, caller_frame) catch |err| {
        try qjsIteratorHelperClear(ctx.runtime, helper);
        return err;
    };
    try qjsIteratorHelperClear(ctx.runtime, helper);
}

fn qjsIteratorHelperClear(rt: *core.Runtime, helper: *core.Object) !void {
    try qjsIteratorHelperClearInner(rt, helper);
    if ((helper.iteratorTargetSlot().*)) |stored| {
        helper.iteratorTargetSlot().* = null;
        stored.free(rt);
    }
    if ((helper.iteratorNextSlot().*)) |stored| {
        helper.iteratorNextSlot().* = null;
        stored.free(rt);
    }
    if ((helper.iteratorCallbackSlot().*)) |stored| {
        helper.iteratorCallbackSlot().* = null;
        stored.free(rt);
    }
    if ((helper.iteratorZipNextsSlot().*)) |stored| {
        helper.iteratorZipNextsSlot().* = null;
        stored.free(rt);
    }
    if ((helper.iteratorZipPadsSlot().*)) |stored| {
        helper.iteratorZipPadsSlot().* = null;
        stored.free(rt);
    }
    if ((helper.iteratorZipKeysSlot().*)) |stored| {
        helper.iteratorZipKeysSlot().* = null;
        stored.free(rt);
    }
}

fn qjsIteratorHelperCloseInner(
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    global: *core.Object,
    helper: *core.Object,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
    comptime closeIterator: anytype,
) !void {
    const inner_iterator = helper.iteratorData() orelse return;
    closeIterator(ctx, output, global, inner_iterator, caller_function, caller_frame) catch |err| {
        try qjsIteratorHelperClearInner(ctx.runtime, helper);
        return err;
    };
    try qjsIteratorHelperClearInner(ctx.runtime, helper);
}

fn qjsIteratorHelperClearInner(rt: *core.Runtime, helper: *core.Object) !void {
    if (helper.iteratorData()) |stored| {
        helper.iteratorDataSlot().* = null;
        stored.free(rt);
    }
    if (helper.iteratorInnerNext()) |stored| {
        helper.iteratorInnerNextSlot().* = null;
        stored.free(rt);
    }
}

fn testHasValueProperty(
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.Value,
    object: *core.Object,
    key: core.Atom,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !bool {
    _ = ctx;
    _ = output;
    _ = global;
    _ = value;
    _ = object;
    _ = key;
    _ = caller_function;
    _ = caller_frame;
    return true;
}

fn testIteratorGetValueProperty(
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.Value,
    key: core.Atom,
    caller_function: *const bytecode.Bytecode,
    caller_frame: *frame_mod.Frame,
) !core.Value {
    _ = ctx;
    _ = output;
    _ = global;
    _ = caller_function;
    _ = caller_frame;
    const object = property_ops.expectObject(value) catch return error.TypeError;
    return object.getProperty(key);
}

fn testIteratorGetValuePropertyOptional(
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.Value,
    key: core.Atom,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.Value {
    _ = ctx;
    _ = output;
    _ = global;
    _ = caller_function;
    _ = caller_frame;
    const object = property_ops.expectObject(value) catch return error.TypeError;
    return object.getProperty(key);
}

fn testIteratorValueTruthy(value: core.Value) bool {
    return value_ops.isTruthy(value);
}

test "iterator value-done keeps result object on stack when reservation fails" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const rt = try core.Runtime.create(failing.allocator());
    const ctx = try core.Context.create(rt);
    const global = try core.Object.create(rt, core.class.ids.object, null);
    const result = try core.Object.create(rt, core.class.ids.object, null);
    var stack = stack_mod.Stack.init(&rt.memory, 16);
    const name = try rt.internAtom("iteratorValueDoneOOM");
    var function = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    var frame = frame_mod.Frame.init(&function);
    defer {
        failing.fail_index = std.math.maxInt(usize);
        frame.deinit(&rt.memory, rt);
        function.deinit(rt);
        rt.atoms.free(name);
        stack.deinit(rt);
        result.value().free(rt);
        global.value().free(rt);
        ctx.destroy();
        rt.destroy();
    }

    const value_key = core.atom.predefinedId("value", .string) orelse return error.TypeError;
    const done_key = core.atom.predefinedId("done", .string) orelse return error.TypeError;
    try result.defineOwnPropertyAssumingNew(rt, value_key, core.Descriptor.data(core.Value.int32(123), true, true, true));
    try result.defineOwnPropertyAssumingNew(rt, done_key, core.Descriptor.data(core.Value.boolean(true), true, true, true));
    for (0..7) |index| try stack.pushOwned(core.Value.int32(@intCast(index)));
    try stack.push(result.value());

    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(
        error.OutOfMemory,
        iteratorGetValueDone(ctx, null, global, &stack, &function, &frame, testIteratorGetValueProperty, testIteratorValueTruthy),
    );
    failing.fail_index = std.math.maxInt(usize);

    try std.testing.expectEqual(@as(usize, 8), stack.values.len);
    try std.testing.expectEqual(&result.header, stack.values[7].refHeader().?);
}

fn testIteratorCallGetValueProperty(
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.Value,
    key: core.Atom,
    caller_function: *const bytecode.Bytecode,
    caller_frame: *frame_mod.Frame,
) !core.Value {
    _ = ctx;
    _ = output;
    _ = global;
    _ = value;
    _ = key;
    _ = caller_function;
    _ = caller_frame;
    return core.Value.int32(1);
}

fn testIteratorCallValueOrBytecode(
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.Value,
    func: core.Value,
    args: []const core.Value,
    caller_function: *const bytecode.Bytecode,
    caller_frame: *frame_mod.Frame,
) !core.Value {
    _ = ctx;
    _ = output;
    _ = global;
    _ = this_value;
    _ = func;
    _ = args;
    _ = caller_function;
    _ = caller_frame;
    return core.Value.int32(123);
}

test "iterator call keeps argument on stack when result reservation fails" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const rt = try core.Runtime.create(failing.allocator());
    const ctx = try core.Context.create(rt);
    const global = try core.Object.create(rt, core.class.ids.object, null);
    const iterator = try core.Object.create(rt, core.class.ids.object, null);
    var stack = stack_mod.Stack.init(&rt.memory, 16);
    const name = try rt.internAtom("iteratorCallOOM");
    const return_atom = try rt.internAtom("return");
    var function = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    var code = [_]u8{0};
    function.code = code[0..];
    var frame = frame_mod.Frame.init(&function);
    defer {
        failing.fail_index = std.math.maxInt(usize);
        frame.deinit(&rt.memory, rt);
        function.deinit(rt);
        rt.atoms.free(return_atom);
        rt.atoms.free(name);
        stack.deinit(rt);
        iterator.value().free(rt);
        global.value().free(rt);
        ctx.destroy();
        rt.destroy();
    }

    for (0..4) |index| try stack.pushOwned(core.Value.int32(@intCast(index)));
    try stack.push(iterator.value());
    try stack.pushOwned(core.Value.int32(5));
    try stack.pushOwned(core.Value.int32(6));
    try stack.pushOwned(core.Value.int32(77));

    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(
        error.OutOfMemory,
        iteratorCall(ctx, null, global, &stack, &function, &frame, testIteratorCallGetValueProperty, testIteratorCallValueOrBytecode),
    );
    failing.fail_index = std.math.maxInt(usize);

    try std.testing.expectEqual(@as(usize, 8), stack.values.len);
    try std.testing.expectEqual(@as(?i32, 77), stack.values[7].asInt32());
    try std.testing.expectEqual(&iterator.header, stack.values[4].refHeader().?);
}

test "simple for-in iterator keeps target when done result stack reservation fails" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const rt = try core.Runtime.create(failing.allocator());
    const ctx = try core.Context.create(rt);
    const global = try core.Object.create(rt, core.class.ids.object, null);
    const iterator = try core.Object.create(rt, core.class.ids.for_in_iterator, null);
    var stack = stack_mod.Stack.init(&rt.memory, 8);
    defer {
        failing.fail_index = std.math.maxInt(usize);
        stack.deinit(rt);
        iterator.value().free(rt);
        global.value().free(rt);
        ctx.destroy();
        rt.destroy();
    }

    const target = try core.Object.create(rt, core.class.ids.object, null);
    iterator.iteratorKindSlot().* = simple_for_in_iterator_kind;
    iterator.iteratorIndexSlot().* = 1;
    iterator.length = 1;
    iterator.iteratorTargetSlot().* = target.value().dup();
    target.value().free(rt);

    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(
        error.OutOfMemory,
        simpleForInNext(ctx, null, global, &stack, iterator, testHasValueProperty),
    );
    failing.fail_index = std.math.maxInt(usize);

    try std.testing.expect(iterator.iteratorTargetSlot().* != null);
    try std.testing.expectEqual(@as(usize, 0), stack.values.len);
}

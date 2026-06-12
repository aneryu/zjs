//! for-in/for-of iterator records, pending-error iterator close paths and VM iterator helpers.

const builtins = @import("../builtins/root.zig");
const core = @import("../core/root.zig");
const frame_mod = @import("frame.zig");
const iter_vm = @import("iterator_ops.zig");
const property_ops = @import("property_ops.zig");
const stack_mod = @import("stack.zig");
const std = @import("std");

const call_runtime = @import("call_runtime.zig");
const utils = @import("vm_utils.zig");
const object_ops = @import("object_ops.zig");

// Helpers that remain in call_runtime.zig (generic utilities outside the for-of
// iterator cluster).
const appendAtom = utils.appendAtom;
const atomListContains = utils.atomListContains;
const callValueOrBytecode = call_runtime.callValueOrBytecode;
const freeAtomList = utils.freeAtomList;
const getValueProperty = object_ops.getValueProperty;
const isCallableValue = call_runtime.isCallableValue;
const isDestructuringIteratorState = call_runtime.isDestructuringIteratorState;
const objectFromValue = object_ops.objectFromValue;
const objectRestOwnKeys = object_ops.objectRestOwnKeys;
const primitiveObjectForAccess = object_ops.primitiveObjectForAccess;
const proxyAwareOwnPropertyDescriptor = object_ops.proxyAwareOwnPropertyDescriptor;
const qjsObjectGetPrototypeOfStep = object_ops.qjsObjectGetPrototypeOfStep;
const sameObjectIdentity = object_ops.sameObjectIdentity;

pub fn createForInIterator(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    object_value: core.JSValue,
) !core.JSValue {
    const rt = ctx.runtime;
    if (try createSimpleForInIterator(rt, object_value)) |simple| return simple;

    var iterator_val = core.JSValue.undefinedValue();
    var source_val = core.JSValue.undefinedValue();
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &iterator_val },
        .{ .value = &source_val },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;
    defer source_val.free(rt);

    const iterator = try core.Object.create(rt, core.class.ids.for_in_iterator, null);
    errdefer core.Object.destroyFromHeader(rt, &iterator.header);
    iterator_val = iterator.value();

    var out_index: u32 = 0;

    if (!object_value.isNull() and !object_value.isUndefined()) {
        source_val = if (object_value.isObject()) object_value.dup() else try primitiveObjectForAccess(rt, global, object_value);
        var seen: []core.Atom = &.{};
        defer freeAtomList(rt, seen);
        var current: ?*core.Object = try property_ops.expectObject(source_val);
        const root = current;
        while (current) |object| {
            if (root != null and object == root.? and builtins.buffer.isTypedArrayObject(object)) {
                const length = builtins.buffer.typedArrayLength(rt, object) catch 0;
                var index: u32 = 0;
                while (index < length) : (index += 1) {
                    const key = core.atom.atomFromUInt32(index);
                    try appendAtom(rt, &seen, key);
                    const key_value = try rt.atoms.toStringValue(rt, key);
                    defer key_value.free(rt);
                    try iterator.defineOwnProperty(rt, core.atom.atomFromUInt32(out_index), core.Descriptor.data(key_value, true, true, true));
                    out_index += 1;
                }
            }
            const keys = try objectRestOwnKeys(ctx, output, global, object);
            defer core.Object.freeKeys(rt, keys);

            for (keys) |key| {
                if (rt.atoms.kind(key) == .symbol) continue;
                if (atomListContains(seen, key)) continue;
                try appendAtom(rt, &seen, key);
                if (object.moduleNamespaceOwnBindingValue(key)) |binding_value| {
                    defer binding_value.free(rt);
                    if (binding_value.isUninitialized()) return error.ReferenceError;
                }
                const desc = try proxyAwareOwnPropertyDescriptor(ctx, output, global, object, key, null, null) orelse continue;
                defer desc.destroy(rt);
                if (!(desc.enumerable orelse false)) continue;
                const key_value = try rt.atoms.toStringValue(rt, key);
                defer key_value.free(rt);
                try iterator.defineOwnProperty(rt, core.atom.atomFromUInt32(out_index), core.Descriptor.data(key_value, true, true, true));
                out_index += 1;
            }

            current = try qjsObjectGetPrototypeOfStep(ctx, output, global, object, null, null);
        }

        const source_key = try rt.internAtom("__source");
        defer rt.atoms.free(source_key);
        try iterator.defineOwnProperty(rt, source_key, core.Descriptor.data(source_val, true, false, true));
    }
    iterator.length = out_index;

    const index_key = try rt.internAtom("__index");
    defer rt.atoms.free(index_key);
    try iterator.defineOwnProperty(rt, index_key, core.Descriptor.data(core.JSValue.int32(0), true, true, true));
    return iterator.value();
}

pub fn createSimpleForInIterator(rt: *core.JSRuntime, object_value: core.JSValue) !?core.JSValue {
    if (object_value.isNull() or object_value.isUndefined()) return null;
    if (!object_value.isObject()) return null;
    const source = objectFromValue(object_value) orelse return null;
    if (!simpleForInRootCanUseFastPath(rt, source)) return null;
    const key_count = simpleForInEnumerableStringKeyCount(rt, source);
    const out_length = std.math.cast(u32, key_count) orelse return null;

    const iterator = try core.Object.create(rt, core.class.ids.for_in_iterator, null);
    errdefer core.Object.destroyFromHeader(rt, &iterator.header);
    if (key_count != 0) {
        const keys = try rt.memory.alloc(core.Atom, key_count);
        errdefer rt.memory.free(core.Atom, keys);
        var out_index: usize = 0;
        for (source.shapeProps()) |prop| {
            const prop_flags = core.property.Flags.fromBits(prop.flags);
            if (prop_flags.deleted or !prop_flags.enumerable) continue;
            if (rt.atoms.kind(prop.atom_id) != .string) continue;
            keys[out_index] = rt.atoms.dup(prop.atom_id);
            out_index += 1;
        }
        iterator.iteratorAtomKeysSlot().* = keys;
    }
    iterator.length = out_length;

    iterator.iteratorKindSlot().* = iter_vm.simple_for_in_iterator_kind;
    iterator.iteratorIndexSlot().* = 0;
    try iterator.setOptionalValueSlot(rt, iterator.iteratorTargetSlot(), object_value.dup());
    return iterator.value();
}

fn simpleForInEnumerableStringKeyCount(rt: *core.JSRuntime, source: *core.Object) usize {
    var count: usize = 0;
    for (source.shapeProps()) |prop| {
        const prop_flags = core.property.Flags.fromBits(prop.flags);
        if (prop_flags.deleted or !prop_flags.enumerable) continue;
        if (rt.atoms.kind(prop.atom_id) != .string) continue;
        count += 1;
    }
    return count;
}

pub fn simpleForInRootCanUseFastPath(rt: *core.JSRuntime, source: *core.Object) bool {
    if (source.class_id != core.class.ids.object or source.flags.is_proxy or source.exotic != null or source.flags.is_array) return false;
    if (builtins.buffer.isTypedArrayObject(source)) return false;
    if (source.arrayElements().len != 0) return false;
    for (source.shapeProps()) |prop| {
        if (core.property.Flags.fromBits(prop.flags).deleted) continue;
        if (core.array.arrayIndexFromAtom(&rt.atoms, prop.atom_id) != null) return false;
        const kind = rt.atoms.kind(prop.atom_id);
        if (kind != .string and kind != .symbol and kind != .private) return false;
    }

    var proto = source.getPrototype();
    while (proto) |object| : (proto = object.getPrototype()) {
        if (object.flags.is_proxy or object.exotic != null) return false;
        if (builtins.buffer.isTypedArrayObject(object)) return false;
        if (object.arrayElements().len != 0) return false;
        for (object.shapeProps()) |prop| {
            const prop_flags = core.property.Flags.fromBits(prop.flags);
            if (prop_flags.deleted or !prop_flags.enumerable) continue;
            if (rt.atoms.kind(prop.atom_id) == .symbol or rt.atoms.kind(prop.atom_id) == .private) continue;
            return false;
        }
    }
    return true;
}

pub fn findForOfIteratorIndex(rt: *core.JSRuntime, stack: *const stack_mod.Stack) !usize {
    var index = stack.values.len;
    while (index > 0) {
        index -= 1;
        const value = stack.values[index];
        if (isIteratorLikeValue(rt, value)) return index;
    }
    return error.StackUnderflow;
}

pub fn isIteratorLikeValue(rt: *core.JSRuntime, value: core.JSValue) bool {
    const object = property_ops.expectObject(value) catch return false;
    if (object.cachedIteratorNext() != null) return true;
    const next_key = rt.internAtom("next") catch return false;
    defer rt.atoms.free(next_key);
    const next_value = object.getProperty(next_key);
    defer next_value.free(rt);
    return isCallableValue(next_value);
}

pub fn closeStackTopForOfIteratorForPendingError(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *const stack_mod.Stack,
) !void {
    return closeStackTopForOfIteratorForPendingErrorInternal(ctx, output, global, stack, null);
}

pub fn closeStackTopForOfIteratorForPendingErrorWithFrame(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *const stack_mod.Stack,
    frame: *const frame_mod.Frame,
) !void {
    return closeStackTopForOfIteratorForPendingErrorInternal(ctx, output, global, stack, frame);
}

pub fn closeStackTopForOfIteratorForPendingErrorInternal(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *const stack_mod.Stack,
    frame: ?*const frame_mod.Frame,
) !void {
    const record_index = findTopClosableForOfRecordIndex(stack) orelse return;
    const iterator_value = stack.values[record_index].dup();
    defer iterator_value.free(ctx.runtime);
    if (property_ops.expectObject(iterator_value)) |object| {
        if (isDestructuringIteratorState(object)) return;
    } else |_| {}
    if (frame) |active_frame| {
        if (activeDestructuringStateTargetsIterator(stack.values, active_frame, iterator_value)) return;
    }

    const pending_exception = if (ctx.hasException()) ctx.takeException() else null;
    defer if (pending_exception) |value| value.free(ctx.runtime);
    closeIteratorFromVm(ctx, output, global, iterator_value) catch {};
    if (ctx.hasException()) ctx.clearException();
    if (pending_exception) |value| _ = ctx.throwValue(value.dup());
}

pub fn findTopClosableForOfRecordIndex(stack: *const stack_mod.Stack) ?usize {
    if (stack.values.len < 3) return null;
    var index = stack.values.len - 3;
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
    if (index + 2 >= stack.values.len) return false;
    return stack.values[index].isObject() and
        isCallableValue(stack.values[index + 1]) and
        stack.values[index + 2].isCatchOffset();
}

pub fn hasCatchMarkerAboveForOfRecord(stack: *const stack_mod.Stack, record_index: usize) bool {
    var index = record_index + 3;
    while (index < stack.values.len) : (index += 1) {
        if (stack.values[index].isCatchOffset()) return true;
    }
    return false;
}

pub fn activeDestructuringStateTargetsIterator(
    stack_values: []const core.JSValue,
    frame: *const frame_mod.Frame,
    iterator_value: core.JSValue,
) bool {
    return destructuringStateTargetsIteratorInValues(stack_values, iterator_value) or
        destructuringStateTargetsIteratorInValues(frame.locals, iterator_value) or
        destructuringStateTargetsIteratorInValues(frame.args, iterator_value) or
        destructuringStateTargetsIteratorInValues(frame.var_refs, iterator_value);
}

pub fn destructuringStateTargetsIteratorInValues(values: []const core.JSValue, iterator_value: core.JSValue) bool {
    for (values) |value| {
        const object = property_ops.expectObject(value) catch continue;
        if (!isDestructuringIteratorState(object)) continue;
        const target = (object.iteratorTargetSlot().*) orelse continue;
        if (sameObjectIdentity(target, iterator_value)) return true;
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
    const return_key = try ctx.runtime.internAtom("return");
    defer ctx.runtime.atoms.free(return_key);
    const return_method = try getValueProperty(ctx, output, global, iterator_value, return_key, null, null);
    defer return_method.free(ctx.runtime);
    if (return_method.isUndefined() or return_method.isNull()) return;
    if (!isCallableValue(return_method)) return error.TypeError;
    const out = try callValueOrBytecode(ctx, output, global, iterator_value, return_method, &.{}, null, null);
    defer out.free(ctx.runtime);
    if (!out.isObject()) return error.TypeError;
}

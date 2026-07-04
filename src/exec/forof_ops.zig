//! for-in/for-of iterator records, pending-error iterator close paths and VM iterator helpers.

const core = @import("../core/root.zig");
const frame_mod = @import("frame.zig");
const iter_vm = @import("iterator_ops.zig");
const property_ops = @import("property_ops.zig");
const stack_mod = @import("stack.zig");
const std = @import("std");

const call_runtime = @import("call_runtime.zig");
const object_ops = @import("object_ops.zig");

// Helpers that remain in call_runtime.zig (generic utilities outside the for-of
// iterator cluster).
const appendAtom = core.atom.appendAtom;
const callValueOrBytecode = call_runtime.callValueOrBytecode;
const freeAtomList = core.atom.freeAtomList;
const getValueProperty = object_ops.getValueProperty;
const isCallableValue = call_runtime.isCallableValue;
const isDestructuringIteratorState = call_runtime.isDestructuringIteratorState;
const objectRestOwnKeys = object_ops.objectRestOwnKeys;
const primitiveObjectForAccess = object_ops.primitiveObjectForAccess;
const proxyAwareOwnPropertyDescriptor = object_ops.proxyAwareOwnPropertyDescriptor;
const sameObjectIdentity = object_ops.sameObjectIdentity;

// ---------------------------------------------------------------------------
// for-in iterator (mirrors qjs JSForInIterator / build_for_in_iterator)
//
// qjs JSForInIterator field mapping (struct at quickjs.c:1276) onto the zjs
// iterator payload (core/object.zig IteratorPayload):
//   it->obj                -> payload.target      (current chain object; null
//                             mirrors the JS_NULL/JS_UNDEFINED "done" states)
//   it->idx                -> payload.index
//   it->atom_count         -> payload.length
//   it->tab_atom           -> payload.atom_keys   (the ENUMERABLE string keys
//                             of the SET_ENUM tab; the non-enumerable entries,
//                             which qjs keeps only to feed the visited-key
//                             set, are folded into that set eagerly -- see
//                             forInSnapshotOwnStringKeys)
//   it->is_array           -> payload.zip_mode    (repurposed u8 slot, 0/1)
//   it->in_prototype_chain -> payload.zip_state   (repurposed u8 slot, 0/1)
// The visited-key dedup set lives as properties on the iterator object itself,
// exactly like qjs defines JS_NULL-valued props on the JS_CLASS_FOR_IN_ITERATOR
// enum_obj (js_for_in_next quickjs.c:16469).
// ---------------------------------------------------------------------------

/// qjs `it->is_array` (JSForInIterator).
pub fn forInIsArraySlot(iterator: *core.Object) *u8 {
    return iterator.iteratorZipModeSlot();
}

/// qjs `it->in_prototype_chain` (JSForInIterator).
pub fn forInInProtoChainSlot(iterator: *core.Object) *u8 {
    return iterator.iteratorZipStateSlot();
}

/// Mirrors qjs build_for_in_iterator (quickjs.c:16268): snapshot ONLY the root
/// object's own string keys (JS_GPN_STRING_MASK | JS_GPN_SET_ENUM); the
/// prototype chain is walked LAZILY by forInNext (js_for_in_next
/// quickjs.c:16404), one prototype at a time.
pub fn createForInIterator(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    object_value: core.JSValue,
) !core.JSValue {
    const rt = ctx.runtime;

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

    // it->is_array = FALSE; it->obj = obj; it->idx = 0; it->tab_atom = NULL;
    // it->atom_count = 0; it->in_prototype_chain = FALSE (quickjs.c:16292-16297)
    iterator.iteratorKindSlot().* = iter_vm.for_in_iterator_kind;
    iterator.iteratorIndexSlot().* = 0;
    iterator.setIteratorLength(0);
    forInIsArraySlot(iterator).* = 0;
    forInInProtoChainSlot(iterator).* = 0;

    // null/undefined: it->obj stays null and the first next() reports done
    // (quickjs.c:16301-16302 / 16428-16429).
    if (object_value.isNull() or object_value.isUndefined()) return iterator.value();

    // JS_ToObjectFree for primitives (quickjs.c:16277-16279).
    source_val = if (object_value.isObject()) object_value.dup() else try primitiveObjectForAccess(rt, global, object_value);
    const source = try property_ops.expectObject(source_val);
    try iterator.setOptionalValueSlot(rt, iterator.iteratorTargetSlot(), source_val.dup());

    if (forInFastArrayCount(rt, source)) |count| {
        // "for fast arrays, we only store the number of elements"
        // (quickjs.c:16315-16317); index keys are generated on the fly.
        forInIsArraySlot(iterator).* = 1;
        iterator.setIteratorLength(count);
    } else {
        // normal_case (quickjs.c:16318-16326).
        const keys = try forInSnapshotOwnStringKeys(ctx, output, global, source, iterator);
        iterator.iteratorAtomKeysSlot().* = keys;
        iterator.setIteratorLength(std.math.cast(u32, keys.len) orelse return error.OutOfMemory);
    }
    return iterator.value();
}

/// The `p->fast_array` branch of build_for_in_iterator (quickjs.c:16305-16317):
/// a fast array (zjs dense array / typed array) with no enumerable shape
/// props stores only the element count. Returns null for the normal case.
fn forInFastArrayCount(rt: *core.JSRuntime, source: *core.Object) ?u32 {
    if (core.object.isTypedArrayObject(source)) {
        // "check that there are no enumerable normal fields" (quickjs.c:16307).
        for (source.shapeProps()) |prop| {
            const prop_flags = core.property.Flags.fromBits(prop.flags);
            if (!prop_flags.deleted and prop_flags.enumerable) return null;
        }
        return core.object.typedArrayLength(rt, source) catch 0;
    }
    if (!source.flags.is_array or !source.flags.fast_array) return null;
    if (source.flags.is_proxy or source.hasExoticMethods()) return null;
    for (source.shapeProps()) |prop| {
        const prop_flags = core.property.Flags.fromBits(prop.flags);
        if (prop_flags.deleted) continue;
        if (prop_flags.enumerable) return null;
        // qjs fast arrays never carry shape-resident index props; if zjs has
        // any (sparse remnants) the normal snapshot must merge them.
        if (core.array.arrayIndexFromAtom(&rt.atoms, prop.atom_id) != null) return null;
    }
    return std.math.cast(u32, source.arrayElements().len) orelse null;
}

/// Mirrors JS_GetOwnPropertyNamesInternal(ctx, &tab, &n, obj,
/// JS_GPN_STRING_MASK | JS_GPN_SET_ENUM) as consumed by the for-in machinery
/// (build_for_in_iterator quickjs.c:16321, the js_for_in_next prototype step
/// quickjs.c:16447 and the is_array conversion quickjs.c:16384). Returns the
/// enumerable own string keys in tab order (owned atoms). qjs keeps the
/// non-enumerable tab entries only to feed the visited-key set on the enum
/// object (quickjs.c:16386-16390 and 16463-16472, always behind a dedup
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
/// shape flag (quickjs.c:8629); proxies/exotics run the full
/// [[GetOwnProperty]] (quickjs.c:8674-8688 "set the is_enumerable field if
/// necessary"), so the gopd trap order/count matches qjs. A key whose
/// descriptor probe reports absence counts as non-enumerable (quickjs.c:8673).
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
    desc.destroy(ctx.runtime);
    return is_enumerable;
}

/// JS_DefinePropertyValue(ctx, enum_obj, prop, JS_NULL, JS_PROP_ENUMERABLE):
/// the visited-key set lives as JS_NULL-valued props on the iterator object
/// itself (js_for_in_next quickjs.c:16469, prepare slow_path quickjs.c:16386).
/// qjs only ever defines a visited key after a dedup miss; the exists guard
/// keeps redefinition of the non-configurable marker impossible.
pub fn forInDefineVisited(rt: *core.JSRuntime, iterator: *core.Object, key: core.Atom) !void {
    if (try iterator.existsOwnProperty(rt, key)) return;
    try iterator.defineOwnProperty(rt, key, core.Descriptor.data(core.JSValue.nullValue(), false, true, false));
}

/// The JS_GPN_STRING_MASK | JS_GPN_ENUM_ONLY probe of
/// js_for_in_prepare_prototype_chain_enum (quickjs.c:16360-16369): does this
/// prototype own at least one enumerable string-keyed property? Ordinary
/// objects reduce to a shape/dense scan (the same walk qjs's
/// JS_GetOwnPropertyNamesInternal does off the shape, quickjs.c:8626-8651);
/// proxies/exotics run the full filtered-tab construction so ownKeys + the
/// per-key gopd probes fire exactly as in qjs (the tab is discarded,
/// quickjs.c:16369).
pub fn forInHasEnumerableStringKey(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    object: *core.Object,
) !bool {
    const rt = ctx.runtime;
    if (core.object.isTypedArrayObject(object)) {
        // fast_array branch (quickjs.c:8656-8659): every element is an
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
        // dense array elements are enumerable index keys (quickjs.c:8656-8659).
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
    if (object.cachedIteratorNext(rt) != null) return true;
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
    // frame.var_refs is excluded: typed cell slots are never iterator-state
    // Objects (the pre-typed slot scan was a provable no-op — expectObject
    // rejects the var_ref GC kind).
    return destructuringStateTargetsIteratorInValues(stack_values, iterator_value) or
        destructuringStateTargetsIteratorInValues(frame.locals, iterator_value) or
        destructuringStateTargetsIteratorInValues(frame.args, iterator_value);
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

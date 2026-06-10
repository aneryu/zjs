const core = @import("../core/root.zig");
const builtins = @import("../builtins/root.zig");
const closure_mod = @import("closure.zig");
const collection_adapter = @import("collection_adapter.zig");
const globals_mod = @import("globals.zig");
const value_ops = @import("value_ops.zig");
const std = @import("std");

pub fn ordinaryObject(rt: *core.JSRuntime) !*core.Object {
    return core.Object.create(rt, core.class.ids.object, null);
}

pub fn functionObject(rt: *core.JSRuntime, name: core.Atom) !core.JSValue {
    const function = try core.Object.create(rt, core.class.ids.c_function, null);
    errdefer function.value().free(rt);

    const prototype = try core.Object.create(rt, core.class.ids.object, null);
    const prototype_value = prototype.value();
    defer prototype_value.free(rt);

    try function.defineOwnProperty(rt, core.atom.ids.prototype, core.Descriptor.data(prototype_value, true, false, false));

    if (rt.atoms.name(name)) |function_name| {
        const name_string = try core.string.String.createUtf8(rt, function_name);
        const name_value = name_string.value();
        defer name_value.free(rt);
        try function.defineOwnProperty(rt, core.atom.ids.name, core.Descriptor.data(name_value, false, false, true));
    }

    return function.value();
}

pub fn constructValue(rt: *core.JSRuntime, callee: core.JSValue, args: []const core.JSValue, globals: []globals_mod.Slot) !core.JSValue {
    var rooted_callee = callee;
    var rooted_args_buffer = try core.runtime.ValueRootBuffer.initCopy(rt, args);
    defer rooted_args_buffer.deinit(rt);
    const rooted_args = rooted_args_buffer.values;
    var rooted_instance = core.JSValue.undefinedValue();
    var root_slices = [_]core.runtime.ValueRootSlice{
        rooted_args_buffer.slice(),
    };
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &rooted_callee },
        .{ .value = &rooted_instance },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .slices = &root_slices,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    const constructor = try expectConstructor(rooted_callee);
    const prototype = constructor.getOwnDataObjectBorrowed(core.atom.ids.prototype) orelse object: {
        const prototype_value = constructor.getProperty(core.atom.ids.prototype);
        defer prototype_value.free(rt);
        if (!prototype_value.isObject()) break :object null;
        const header = prototype_value.refHeader() orelse break :object null;
        break :object @as(*core.Object, @fieldParentPtr("header", header));
    };

    if (constructor.typedArrayElementSize() != 0 and constructor.typedArrayKind() != 0) {
        return constructTypedArrayValue(rt, prototype, .{
            .size = constructor.typedArrayElementSize(),
            .kind = constructor.typedArrayKind(),
        }, rooted_args, activeGlobalObject(rt, globals) catch null);
    }
    if (isDateConstructorRecord(constructor)) return builtins.date.constructWithPrototype(rt, rooted_args, prototype);
    if (isRegExpConstructorRecord(constructor)) {
        const pattern = if (rooted_args.len >= 1) rooted_args[0] else try value_ops.createStringValue(rt, "");
        defer if (rooted_args.len < 1) pattern.free(rt);
        const flags = if (rooted_args.len >= 2) rooted_args[1] else try value_ops.createStringValue(rt, "");
        defer if (rooted_args.len < 2) flags.free(rt);
        return builtins.regexp.constructWithPrototype(rt, pattern, flags, prototype);
    }

    if (try constructorName(rt, constructor)) |name| {
        defer rt.memory.allocator.free(name);
        if (builtins.collection.constructorId(name)) |kind| return constructCollectionValue(rt, kind, prototype, rooted_args, globals);
        if (std.mem.eql(u8, name, "Function")) return constructFunctionValue(rt, constructor);
        if (std.mem.eql(u8, name, "Object")) return constructObjectValue(rt, rooted_args, constructor);
        if (std.mem.eql(u8, name, "Array")) return builtins.array.constructConstructorWithPrototype(rt, rooted_args, prototype);
        if (std.mem.eql(u8, name, "Iterator")) return error.TypeError;
        if (std.mem.eql(u8, name, "Date")) return builtins.date.constructWithPrototype(rt, rooted_args, prototype);
        if (std.mem.eql(u8, name, "RegExp")) {
            const pattern = if (rooted_args.len >= 1) rooted_args[0] else try value_ops.createStringValue(rt, "");
            defer if (rooted_args.len < 1) pattern.free(rt);
            const flags = if (rooted_args.len >= 2) rooted_args[1] else try value_ops.createStringValue(rt, "");
            defer if (rooted_args.len < 2) flags.free(rt);
            return builtins.regexp.constructWithPrototype(rt, pattern, flags, prototype);
        }
        if (std.mem.eql(u8, name, "String")) return builtins.string.constructWithPrototype(rt, rooted_args, prototype);
        if (std.mem.eql(u8, name, "Symbol")) return error.TypeError;
        if (std.mem.eql(u8, name, "DOMException")) return constructDOMExceptionObject(rt, prototype, rooted_args);
        if (std.mem.eql(u8, name, "Promise")) return builtins.promise.constructWithPrototype(rt, prototype);
        if (std.mem.eql(u8, name, "BigInt")) return error.TypeError;
        if (std.mem.eql(u8, name, "TypedArray")) return error.TypeError;
        if (std.mem.eql(u8, name, "Proxy")) {
            if (rooted_args.len < 2) return error.TypeError;
            _ = try expectObject(rooted_args[0]);
            _ = try expectObject(rooted_args[1]);
            const proxy = try core.Object.create(rt, core.class.ids.object, null);
            errdefer core.Object.destroyFromHeader(rt, &proxy.header);
            proxy.is_proxy = true;
            try proxy.ensureProxyPayload(rt);
            try proxy.setOptionalValueSlot(rt, proxy.proxyTargetSlot(), rooted_args[0].dup());
            try proxy.setOptionalValueSlot(rt, proxy.proxyHandlerSlot(), rooted_args[1].dup());
            return proxy.value();
        }
        if (std.mem.eql(u8, name, "ArrayBuffer")) {
            return builtins.buffer.arrayBufferConstructArgs(rt, rooted_args, prototype);
        }
        if (std.mem.eql(u8, name, "SharedArrayBuffer")) {
            return builtins.buffer.sharedArrayBufferConstructArgs(rt, rooted_args, prototype);
        }
        if (std.mem.eql(u8, name, "FinalizationRegistry")) {
            if (rooted_args.len < 1 or !isCallableObject(rooted_args[0])) return error.TypeError;
            return constructFinalizationRegistry(rt, rooted_args[0], prototype);
        }
        if (std.mem.eql(u8, name, "WeakRef")) return constructWeakRef(rt, rooted_args, prototype);
        if (std.mem.eql(u8, name, "DataView")) return builtins.buffer.dataViewConstruct(rt, rooted_args, prototype);
        if (typedArrayElement(name)) |element| {
            return constructTypedArrayValue(rt, prototype, element, rooted_args, activeGlobalObject(rt, globals) catch null);
        }
        if (std.mem.eql(u8, name, "Number")) {
            if (rooted_args.len >= 1 and rooted_args[0].isSymbol()) return error.TypeError;
            const primitive = if (rooted_args.len >= 1) try value_ops.toNumberValue(rt, rooted_args[0]) else core.JSValue.int32(0);
            return constructPrimitiveWrapper(rt, core.class.ids.number, prototype, primitive);
        }
        if (std.mem.eql(u8, name, "Boolean")) return constructPrimitiveWrapper(rt, core.class.ids.boolean, prototype, core.JSValue.boolean(rooted_args.len >= 1 and isTruthy(rooted_args[0])));
        if (isErrorConstructorName(name)) return constructErrorObject(rt, name, constructor.value(), prototype, rooted_args);
    }

    const instance = try core.Object.create(rt, core.class.ids.object, prototype);
    rooted_instance = instance.value();
    errdefer {
        rooted_instance = core.JSValue.undefinedValue();
        core.Object.destroyFromHeader(rt, &instance.header);
    }
    const constructor_key = try rt.internAtom("constructor");
    defer rt.atoms.free(constructor_key);
    try instance.defineOwnProperty(rt, constructor_key, core.Descriptor.data(rooted_callee, true, false, true));
    return rooted_instance;
}

test "constructValue fallback roots callee while defining constructor property" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("FallbackConstructor");
    defer rt.atoms.free(name);
    const constructor = try functionObject(rt, name);
    var constructor_alive = true;
    defer if (constructor_alive) constructor.free(rt);
    const constructor_object = try expectObject(constructor);

    const marker_atom = try rt.atoms.newValueSymbol("gc-construct-fallback-callee-symbol");
    const marker_key = try rt.internAtom("marker");
    defer rt.atoms.free(marker_key);
    try constructor_object.defineOwnProperty(rt, marker_key, core.Descriptor.data(core.JSValue.symbol(marker_atom), true, true, true));

    const instance_value = try constructValue(rt, constructor, &.{}, &.{});
    var instance_alive = true;
    defer if (instance_alive) instance_value.free(rt);
    const instance = try expectObject(instance_value);

    const constructor_key = try rt.internAtom("constructor");
    defer rt.atoms.free(constructor_key);
    const stored_constructor = instance.getProperty(constructor_key);
    defer stored_constructor.free(rt);
    try std.testing.expect(stored_constructor.same(constructor));

    const stored_constructor_object = try expectObject(stored_constructor);
    const marker = stored_constructor_object.getProperty(marker_key);
    defer marker.free(rt);
    try std.testing.expect(marker.same(core.JSValue.symbol(marker_atom)));
    try std.testing.expect(rt.atoms.name(marker_atom) != null);

    instance_value.free(rt);
    instance_alive = false;
    constructor.free(rt);
    constructor_alive = false;
}

pub fn constructTypedArrayValue(rt: *core.JSRuntime, prototype: ?*core.Object, element: TypedArrayElement, args: []const core.JSValue, global: ?*core.Object) !core.JSValue {
    var rooted_args_buffer = try core.runtime.ValueRootBuffer.initCopy(rt, args);
    defer rooted_args_buffer.deinit(rt);
    const rooted_args = rooted_args_buffer.values;
    var root_slices = [_]core.runtime.ValueRootSlice{
        rooted_args_buffer.slice(),
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .slices = &root_slices,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    const buffer = if (rooted_args.len >= 1) rooted_args[0] else core.JSValue.int32(0);
    if (buffer.isObject()) {
        const source = try expectObject(buffer);
        if (source.is_array) return constructTypedArrayArrayInput(rt, prototype, element, source, global);
        if (builtins.buffer.isTypedArrayObject(source)) return constructTypedArrayTypedArrayInput(rt, prototype, element, source, global);
        if (source.class_id != core.class.ids.array_buffer and source.class_id != core.class.ids.shared_array_buffer) return constructTypedArrayArrayLikeInput(rt, prototype, element, source, global);
        return builtins.buffer.typedArrayConstructWithOptions(rt, element.size, element.kind, buffer, rooted_args, prototype);
    }
    const element_count = buffer.asInt32() orelse return error.TypeError;
    if (element_count < 0) return error.RangeError;
    const byte_length = try std.math.mul(i32, element_count, @intCast(element.size));
    const backing_buffer = try createTypedArrayBackingBuffer(rt, prototype, global, byte_length);
    var backing_buffer_owned = true;
    errdefer if (backing_buffer_owned) backing_buffer.free(rt);
    const backing_buffer_object = expectObject(backing_buffer) catch return error.TypeError;
    backing_buffer_owned = false;
    return builtins.buffer.typedArrayConstructFullBufferOwned(rt, element.size, element.kind, backing_buffer, backing_buffer_object, prototype);
}

pub fn constructErrorObject(rt: *core.JSRuntime, name: []const u8, constructor: core.JSValue, prototype: ?*core.Object, args: []const core.JSValue) !core.JSValue {
    var rooted_args_buffer = try core.runtime.ValueRootBuffer.initCopy(rt, args);
    defer rooted_args_buffer.deinit(rt);
    const rooted_args = rooted_args_buffer.values;
    var root_slices = [_]core.runtime.ValueRootSlice{
        rooted_args_buffer.slice(),
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .slices = &root_slices,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    if (std.mem.eql(u8, name, "AggregateError")) return constructAggregateErrorObject(rt, constructor, prototype, rooted_args);
    const instance = try core.Object.create(rt, core.class.ids.error_, prototype);
    errdefer core.Object.destroyFromHeader(rt, &instance.header);
    const name_value = try value_ops.createStringValue(rt, name);
    defer name_value.free(rt);
    try defineData(rt, instance, "name", name_value, true, false, true);
    if (rooted_args.len >= 1 and !rooted_args[0].isUndefined()) {
        const message = try value_ops.toStringValue(rt, rooted_args[0]);
        defer message.free(rt);
        try defineData(rt, instance, "message", message, true, false, true);
    }
    return instance.value();
}

test "constructErrorObject roots direct symbol message while creating error" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const message_atom = try rt.atoms.newValueSymbol("gc-construct-error-message-symbol");
    const args = [_]core.JSValue{
        core.JSValue.symbol(message_atom),
    };

    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const error_value = try constructErrorObject(rt, "Error", core.JSValue.undefinedValue(), null, &args);
    var error_alive = true;
    defer if (error_alive) error_value.free(rt);
    const object = try expectObject(error_value);

    try std.testing.expect(rt.atoms.name(message_atom) != null);
    const message_key = try rt.internAtom("message");
    defer rt.atoms.free(message_key);
    const message_value = object.getProperty(message_key);
    defer message_value.free(rt);
    try expectStringValue(rt, "Symbol(gc-construct-error-message-symbol)", message_value);

    error_value.free(rt);
    error_alive = false;
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(message_atom) == null);
}

pub fn constructDOMExceptionObject(rt: *core.JSRuntime, prototype: ?*core.Object, args: []const core.JSValue) !core.JSValue {
    var rooted_args_buffer = try core.runtime.ValueRootBuffer.initCopy(rt, args);
    defer rooted_args_buffer.deinit(rt);
    const rooted_args = rooted_args_buffer.values;
    var root_slices = [_]core.runtime.ValueRootSlice{
        rooted_args_buffer.slice(),
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .slices = &root_slices,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    const instance = try core.Object.create(rt, core.class.ids.error_, prototype);
    errdefer core.Object.destroyFromHeader(rt, &instance.header);
    const message = if (rooted_args.len >= 1 and !rooted_args[0].isUndefined())
        try value_ops.toStringValue(rt, rooted_args[0])
    else
        try value_ops.createStringValue(rt, "");
    defer message.free(rt);
    const name = if (rooted_args.len >= 2 and !rooted_args[1].isUndefined())
        try value_ops.toStringValue(rt, rooted_args[1])
    else
        try value_ops.createStringValue(rt, "Error");
    defer name.free(rt);
    try defineData(rt, instance, "name", name, true, false, true);
    try defineData(rt, instance, "message", message, true, false, true);
    try defineData(rt, instance, "code", core.JSValue.int32(try domExceptionCode(rt, name)), true, false, true);
    return instance.value();
}

test "constructDOMExceptionObject roots direct symbol args while creating error" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const message_atom = try rt.atoms.newValueSymbol("gc-dom-exception-message-symbol");
    const name_atom = try rt.atoms.newValueSymbol("gc-dom-exception-name-symbol");
    const args = [_]core.JSValue{
        core.JSValue.symbol(message_atom),
        core.JSValue.symbol(name_atom),
    };

    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const error_value = try constructDOMExceptionObject(rt, null, &args);
    var error_alive = true;
    defer if (error_alive) error_value.free(rt);
    const object = try expectObject(error_value);

    try std.testing.expect(rt.atoms.name(message_atom) != null);
    try std.testing.expect(rt.atoms.name(name_atom) != null);
    const message_key = try rt.internAtom("message");
    defer rt.atoms.free(message_key);
    const message_value = object.getProperty(message_key);
    defer message_value.free(rt);
    try expectStringValue(rt, "Symbol(gc-dom-exception-message-symbol)", message_value);
    const name_key = try rt.internAtom("name");
    defer rt.atoms.free(name_key);
    const name_value = object.getProperty(name_key);
    defer name_value.free(rt);
    try expectStringValue(rt, "Symbol(gc-dom-exception-name-symbol)", name_value);

    error_value.free(rt);
    error_alive = false;
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(message_atom) == null);
    try std.testing.expect(rt.atoms.name(name_atom) == null);
}

fn domExceptionCode(rt: *core.JSRuntime, name_value: core.JSValue) !i32 {
    var name = std.ArrayList(u8).empty;
    defer name.deinit(rt.memory.allocator);
    try value_ops.appendRawString(rt, &name, name_value);
    const names = [_]?[]const u8{
        "IndexSizeError",
        null,
        "HierarchyRequestError",
        "WrongDocumentError",
        "InvalidCharacterError",
        null,
        "NoModificationAllowedError",
        "NotFoundError",
        "NotSupportedError",
        "InUseAttributeError",
        "InvalidStateError",
        "SyntaxError",
        "InvalidModificationError",
        "NamespaceError",
        "InvalidAccessError",
        null,
        "TypeMismatchError",
        "SecurityError",
        "NetworkError",
        "AbortError",
        "URLMismatchError",
        "QuotaExceededError",
        "TimeoutError",
        "InvalidNodeTypeError",
        "DataCloneError",
    };
    for (names, 0..) |candidate, index| {
        if (candidate) |text| {
            if (std.mem.eql(u8, name.items, text)) return @intCast(index + 1);
        }
    }
    return 0;
}

fn constructAggregateErrorObject(rt: *core.JSRuntime, constructor: core.JSValue, prototype: ?*core.Object, args: []const core.JSValue) !core.JSValue {
    _ = constructor;
    var errors_array_val = core.JSValue.undefinedValue();
    var copied_error_val = core.JSValue.undefinedValue();
    var cause_val = core.JSValue.undefinedValue();
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &errors_array_val },
        .{ .value = &copied_error_val },
        .{ .value = &cause_val },
    };
    var rooted_args_buffer = try core.runtime.ValueRootBuffer.initCopy(rt, args);
    defer rooted_args_buffer.deinit(rt);
    const rooted_args = rooted_args_buffer.values;
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

    defer errors_array_val.free(rt);
    defer copied_error_val.free(rt);
    defer cause_val.free(rt);

    const instance = try core.Object.create(rt, core.class.ids.error_, prototype);
    errdefer core.Object.destroyFromHeader(rt, &instance.header);
    const name_value = try value_ops.createStringValue(rt, "AggregateError");
    defer name_value.free(rt);
    try defineData(rt, instance, "name", name_value, true, false, true);

    if (rooted_args.len < 1 or !rooted_args[0].isObject()) return error.TypeError;
    const errors_source = try expectObject(rooted_args[0]);
    if (!errors_source.is_array) return error.TypeError;
    if (rooted_args.len >= 2 and !rooted_args[1].isUndefined()) {
        const message = try value_ops.toStringValue(rt, rooted_args[1]);
        defer message.free(rt);
        try defineData(rt, instance, "message", message, true, false, true);
    }

    if (rooted_args.len >= 3 and rooted_args[2].isObject()) {
        const options = try expectObject(rooted_args[2]);
        const cause_key = try rt.internAtom("cause");
        defer rt.atoms.free(cause_key);
        cause_val = options.getProperty(cause_key);
        var has_cause = !cause_val.isUndefined();
        if (!has_cause) {
            if (options.getOwnProperty(cause_key)) |desc| {
                desc.destroy(rt);
                has_cause = true;
            }
        }
        if (has_cause) try defineData(rt, instance, "cause", cause_val, true, false, true);
        cause_val.free(rt);
        cause_val = core.JSValue.undefinedValue();
    }

    const errors_array = try core.Object.createArray(rt, null);
    errors_array_val = errors_array.value();

    var index: u32 = 0;
    while (index < errors_source.length) : (index += 1) {
        copied_error_val = errors_source.getProperty(core.atom.atomFromUInt32(index));
        try errors_array.defineOwnProperty(rt, core.atom.atomFromUInt32(index), core.Descriptor.data(copied_error_val, true, true, true));
        copied_error_val.free(rt);
        copied_error_val = core.JSValue.undefinedValue();
    }
    errors_array.length = errors_source.length;
    try errors_array.defineOwnProperty(rt, core.atom.ids.length, core.Descriptor.data(core.JSValue.int32(@intCast(errors_source.length)), true, false, false));
    try defineData(rt, instance, "errors", errors_array_val, true, false, true);
    return instance.value();
}

pub fn isErrorConstructorName(name: []const u8) bool {
    return std.mem.eql(u8, name, "Error") or
        std.mem.eql(u8, name, "AggregateError") or
        std.mem.eql(u8, name, "EvalError") or
        std.mem.eql(u8, name, "RangeError") or
        std.mem.eql(u8, name, "ReferenceError") or
        std.mem.eql(u8, name, "SyntaxError") or
        std.mem.eql(u8, name, "TypeError") or
        std.mem.eql(u8, name, "URIError");
}

fn constructOrdinaryInstance(rt: *core.JSRuntime, prototype: ?*core.Object) !core.JSValue {
    const instance = try core.Object.create(rt, core.class.ids.object, prototype);
    errdefer core.Object.destroyFromHeader(rt, &instance.header);
    return instance.value();
}

fn constructWeakRef(rt: *core.JSRuntime, args: []const core.JSValue, prototype: ?*core.Object) !core.JSValue {
    if (args.len < 1 or !canBeHeldWeakly(rt, args[0])) return error.TypeError;
    return weakRefWithPrototype(rt, args[0], prototype);
}

pub fn weakRefWithPrototype(rt: *core.JSRuntime, target: core.JSValue, prototype: ?*core.Object) !core.JSValue {
    var rooted_target = target;
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &rooted_target },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    const instance = try core.Object.create(rt, core.class.ids.weak_ref, prototype);
    errdefer core.Object.destroyFromHeader(rt, &instance.header);
    try instance.setWeakRefTarget(rt, rooted_target);
    return instance.value();
}

fn constructFinalizationRegistry(rt: *core.JSRuntime, cleanup_callback: core.JSValue, prototype: ?*core.Object) !core.JSValue {
    const instance = try core.Object.create(rt, core.class.ids.finalization_registry, prototype);
    errdefer core.Object.destroyFromHeader(rt, &instance.header);
    try instance.setOptionalValueSlot(rt, instance.finalizationRegistryCleanupCallbackSlot(), cleanup_callback.dup());
    return instance.value();
}

test "constructWeakRef roots direct symbol target while creating weak ref" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const symbol_atom = try rt.atoms.newValueSymbol("gc-construct-weak-ref-symbol");
    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const weak_ref_value = try constructWeakRef(rt, &.{core.JSValue.symbol(symbol_atom)}, null);
    var weak_ref_alive = true;
    defer if (weak_ref_alive) weak_ref_value.free(rt);
    const weak_ref = expectObject(weak_ref_value) catch return error.TypeError;

    const live = weak_ref.weakRefDeref(rt);
    try std.testing.expect(live.same(core.JSValue.symbol(symbol_atom)));
    try std.testing.expect(rt.atoms.name(symbol_atom) != null);

    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
    try std.testing.expect(weak_ref.weakRefDeref(rt).isUndefined());

    weak_ref_value.free(rt);
    weak_ref_alive = false;
}

fn canBeHeldWeakly(rt: *core.JSRuntime, value: core.JSValue) bool {
    if (value.isObject()) return true;
    if (value.asSymbolAtom()) |atom_id| {
        return rt.atoms.kind(atom_id) == .symbol and builtins.symbol.registryKey(&rt.atoms, atom_id) == null;
    }
    return false;
}

fn defineData(
    rt: *core.JSRuntime,
    target: *core.Object,
    name: []const u8,
    value: core.JSValue,
    writable: bool,
    enumerable: bool,
    configurable: bool,
) !void {
    const key = try rt.internAtom(name);
    defer rt.atoms.free(key);
    try target.defineOwnProperty(rt, key, core.Descriptor.data(value, writable, enumerable, configurable));
}

fn constructPrimitiveWrapper(rt: *core.JSRuntime, class_id: core.class.ClassId, prototype: ?*core.Object, primitive: core.JSValue) !core.JSValue {
    var rooted_primitive = primitive;
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &rooted_primitive },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    const instance = try core.Object.create(rt, class_id, prototype);
    errdefer core.Object.destroyFromHeader(rt, &instance.header);
    try instance.setOptionalValueSlot(rt, instance.objectDataSlot(), rooted_primitive.dup());
    return instance.value();
}

test "constructPrimitiveWrapper roots direct symbol while creating wrapper" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const symbol_atom = try rt.atoms.newValueSymbol("gc-construct-wrapper-symbol");
    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const wrapper_value = try constructPrimitiveWrapper(rt, core.class.ids.symbol, null, core.JSValue.symbol(symbol_atom));
    var wrapper_alive = true;
    defer if (wrapper_alive) wrapper_value.free(rt);
    const wrapper = expectObject(wrapper_value) catch return error.TypeError;

    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    const stored = wrapper.objectData() orelse return error.TypeError;
    try std.testing.expect(stored.same(core.JSValue.symbol(symbol_atom)));

    wrapper_value.free(rt);
    wrapper_alive = false;
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

fn constructObjectValue(rt: *core.JSRuntime, args: []const core.JSValue, constructor: *core.Object) !core.JSValue {
    if (args.len >= 1) {
        const value = args[0];
        if (value.isObject()) return value.dup();
        if (!value.isNull() and !value.isUndefined()) {
            if (value.isString()) {
                return builtins.string.constructWithPrototype(rt, &.{value}, primitivePrototypeFromObjectConstructor(constructor, .string));
            }
            if (value.isNumber()) {
                return constructPrimitiveWrapper(rt, core.class.ids.number, primitivePrototypeFromObjectConstructor(constructor, .number), value);
            }
            if (value.asBool() != null) {
                return constructPrimitiveWrapper(rt, core.class.ids.boolean, primitivePrototypeFromObjectConstructor(constructor, .boolean), value);
            }
            if (value.isBigInt()) {
                return constructPrimitiveWrapper(rt, core.class.ids.big_int, primitivePrototypeFromObjectConstructor(constructor, .bigint), value);
            }
            if (value.isSymbol()) {
                return constructPrimitiveWrapper(rt, core.class.ids.symbol, primitivePrototypeFromObjectConstructor(constructor, .symbol), value);
            }
        }
    }
    const object_prototype = constructor.getProperty(core.atom.ids.prototype);
    defer object_prototype.free(rt);
    const prototype = if (object_prototype.isObject()) expectObject(object_prototype) catch null else null;
    const object = try core.Object.create(rt, core.class.ids.object, prototype);
    return object.value();
}

fn primitivePrototypeFromObjectConstructor(constructor: *core.Object, slot: core.object.PrimitivePrototypeSlot) ?*core.Object {
    const proto_value = constructor.functionPrimitivePrototype(slot) orelse return null;
    return expectObject(proto_value) catch null;
}

pub const TypedArrayElement = struct {
    size: u32,
    kind: u8,
};

pub fn typedArrayElement(name: []const u8) ?TypedArrayElement {
    if (std.mem.eql(u8, name, "Int8Array")) return .{ .size = 1, .kind = 1 };
    if (std.mem.eql(u8, name, "Uint8Array")) return .{ .size = 1, .kind = 2 };
    if (std.mem.eql(u8, name, "Uint8ClampedArray")) return .{ .size = 1, .kind = 3 };
    if (std.mem.eql(u8, name, "Int16Array")) return .{ .size = 2, .kind = 4 };
    if (std.mem.eql(u8, name, "Uint16Array")) return .{ .size = 2, .kind = 5 };
    if (std.mem.eql(u8, name, "Int32Array")) return .{ .size = 4, .kind = 6 };
    if (std.mem.eql(u8, name, "Uint32Array")) return .{ .size = 4, .kind = 7 };
    if (std.mem.eql(u8, name, "Float16Array")) return .{ .size = 2, .kind = 8 };
    if (std.mem.eql(u8, name, "Float32Array")) return .{ .size = 4, .kind = 9 };
    if (std.mem.eql(u8, name, "Float64Array")) return .{ .size = 8, .kind = 10 };
    if (std.mem.eql(u8, name, "BigInt64Array")) return .{ .size = 8, .kind = 11 };
    if (std.mem.eql(u8, name, "BigUint64Array")) return .{ .size = 8, .kind = 12 };
    return null;
}

fn constructTypedArrayArrayInput(rt: *core.JSRuntime, prototype: ?*core.Object, element: TypedArrayElement, source: *core.Object, global: ?*core.Object) !core.JSValue {
    const byte_length = try std.math.mul(u32, source.length, element.size);
    var backing_buffer = core.JSValue.undefinedValue();
    var object_value = core.JSValue.undefinedValue();
    var value = core.JSValue.undefinedValue();
    var coerced = core.JSValue.undefinedValue();
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &backing_buffer },
        .{ .value = &object_value },
        .{ .value = &value },
        .{ .value = &coerced },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    defer backing_buffer.free(rt);
    defer object_value.free(rt);
    defer value.free(rt);
    defer coerced.free(rt);

    backing_buffer = try createTypedArrayBackingBuffer(rt, prototype, global, @intCast(byte_length));
    object_value = try builtins.buffer.typedArrayConstructWithOptions(rt, element.size, element.kind, backing_buffer, &.{backing_buffer}, prototype);
    const object = try expectObject(object_value);

    var index: u32 = 0;
    while (index < source.length) : (index += 1) {
        value = source.getProperty(core.atom.atomFromUInt32(index));
        coerced = try typedArraySourceValue(rt, value);
        _ = try builtins.buffer.typedArraySetIndex(rt, object, index, coerced);

        coerced.free(rt);
        coerced = core.JSValue.undefinedValue();
        value.free(rt);
        value = core.JSValue.undefinedValue();
    }
    return object_value.dup();
}

fn constructTypedArrayTypedArrayInput(rt: *core.JSRuntime, prototype: ?*core.Object, element: TypedArrayElement, source: *core.Object, global: ?*core.Object) !core.JSValue {
    if (try builtins.buffer.typedArrayDetached(source)) return error.TypeError;
    if (try builtins.buffer.typedArrayOutOfBounds(source)) {
        const buffer_value = source.typedArrayBuffer() orelse return error.TypeError;
        const buffer_header = buffer_value.refHeader() orelse return error.TypeError;
        const buffer: *core.Object = @fieldParentPtr("header", buffer_header);
        if (source.typedArrayFixedLength() != null or source.typedArrayByteOffset() > buffer.byteStorage().len) return error.TypeError;
    }
    const length = try builtins.buffer.typedArrayLength(rt, source);
    const byte_length = try std.math.mul(u32, length, element.size);
    var backing_buffer = core.JSValue.undefinedValue();
    var object_value = core.JSValue.undefinedValue();
    var value = core.JSValue.undefinedValue();
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &backing_buffer },
        .{ .value = &object_value },
        .{ .value = &value },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    defer backing_buffer.free(rt);
    defer object_value.free(rt);
    defer value.free(rt);

    backing_buffer = try createTypedArrayBackingBuffer(rt, prototype, global, @intCast(byte_length));
    object_value = try builtins.buffer.typedArrayConstructWithOptions(rt, element.size, element.kind, backing_buffer, &.{backing_buffer}, prototype);
    const object = try expectObject(object_value);

    var index: u32 = 0;
    while (index < length) : (index += 1) {
        value = try builtins.buffer.typedArrayGetIndex(rt, source, index);
        _ = try builtins.buffer.typedArraySetIndex(rt, object, index, value);

        value.free(rt);
        value = core.JSValue.undefinedValue();
    }
    return object_value.dup();
}

fn constructTypedArrayArrayLikeInput(rt: *core.JSRuntime, prototype: ?*core.Object, element: TypedArrayElement, source: *core.Object, global: ?*core.Object) !core.JSValue {
    const length_value = source.getProperty(core.atom.ids.length);
    defer length_value.free(rt);
    const length_i32 = length_value.asInt32() orelse 0;
    if (length_i32 < 0) return error.RangeError;
    const length: u32 = @intCast(length_i32);
    const byte_length = try std.math.mul(u32, length, element.size);
    var backing_buffer = core.JSValue.undefinedValue();
    var object_value = core.JSValue.undefinedValue();
    var value = core.JSValue.undefinedValue();
    var coerced = core.JSValue.undefinedValue();
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &backing_buffer },
        .{ .value = &object_value },
        .{ .value = &value },
        .{ .value = &coerced },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    defer backing_buffer.free(rt);
    defer object_value.free(rt);
    defer value.free(rt);
    defer coerced.free(rt);

    backing_buffer = try createTypedArrayBackingBuffer(rt, prototype, global, @intCast(byte_length));
    object_value = try builtins.buffer.typedArrayConstructWithOptions(rt, element.size, element.kind, backing_buffer, &.{backing_buffer}, prototype);
    const object = try expectObject(object_value);

    var index: u32 = 0;
    while (index < length) : (index += 1) {
        value = source.getProperty(core.atom.atomFromUInt32(index));
        coerced = try typedArraySourceValue(rt, value);
        _ = try builtins.buffer.typedArraySetIndex(rt, object, index, coerced);

        coerced.free(rt);
        coerced = core.JSValue.undefinedValue();
        value.free(rt);
        value = core.JSValue.undefinedValue();
    }
    return object_value.dup();
}

fn isTruthy(value: core.JSValue) bool {
    if (value_ops.isHTMLDDA(value)) return false;
    if (value.asBool()) |b| return b;
    if (value.asInt32()) |n| return n != 0;
    if (value.asFloat64()) |n| return n != 0 and !std.math.isNan(n);
    return !(value.isUndefined() or value.isNull());
}

fn createTypedArrayBackingBuffer(rt: *core.JSRuntime, prototype: ?*core.Object, global: ?*core.Object, byte_length: i32) !core.JSValue {
    return builtins.buffer.arrayBufferConstructLength(rt, @intCast(byte_length), null, typedArrayArrayBufferPrototype(rt, prototype, global));
}

fn typedArrayArrayBufferPrototype(rt: *core.JSRuntime, prototype: ?*core.Object, global: ?*core.Object) ?*core.Object {
    if (arrayBufferPrototypeFromTypedArrayPrototype(prototype)) |buffer_prototype| return buffer_prototype;
    const global_object = global orelse return null;
    const ctor_key = core.atom.predefinedId("ArrayBuffer", .string) orelse return null;
    const ctor_value = global_object.getProperty(ctor_key);
    defer ctor_value.free(rt);
    if (!ctor_value.isObject()) return null;
    const ctor_object = expectObject(ctor_value) catch return null;
    const prototype_value = ctor_object.getProperty(core.atom.ids.prototype);
    defer prototype_value.free(rt);
    if (!prototype_value.isObject()) return null;
    return expectObject(prototype_value) catch return null;
}

fn arrayBufferPrototypeFromTypedArrayPrototype(prototype: ?*core.Object) ?*core.Object {
    var current = prototype orelse return null;
    while (true) {
        if (current.typedArrayArrayBufferPrototype()) |proto_value| {
            if (expectObject(proto_value) catch null) |buffer_prototype| return buffer_prototype;
        }
        current = current.prototype orelse return null;
    }
}

fn activeGlobalObject(rt: *core.JSRuntime, globals: []globals_mod.Slot) !?*core.Object {
    const global_value = try globals_mod.getByName(rt, globals, "globalThis");
    defer global_value.free(rt);
    if (!global_value.isObject()) return null;
    return try expectObject(global_value);
}

fn typedArraySourceValue(rt: *core.JSRuntime, value: core.JSValue) !core.JSValue {
    return primitiveWrapperStoredValue(rt, value) orelse value.dup();
}

fn primitiveWrapperStoredValue(rt: *core.JSRuntime, value: core.JSValue) ?core.JSValue {
    _ = rt;
    if (!value.isObject()) return null;
    const object = expectObject(value) catch return null;
    switch (object.class_id) {
        core.class.ids.number,
        core.class.ids.boolean,
        core.class.ids.big_int,
        core.class.ids.symbol,
        => if (object.objectData()) |stored| return stored.dup() else return null,
        else => return null,
    }
}

fn constructFunctionValue(rt: *core.JSRuntime, constructor: *core.Object) !core.JSValue {
    const out = try closure_mod.create(rt, 13, 0, 0, 0);
    errdefer out.free(rt);
    const realm_keys = [_][]const u8{
        "__realm_Object_proto",
        "__realm_Number_proto",
        "__realm_Boolean_proto",
        "__realm_Array_proto",
        "__realm_Iterator_proto",
        "__realm_Map_proto",
        "__realm_Set_proto",
        "__realm_WeakMap_proto",
        "__realm_WeakSet_proto",
        "__realm_RegExp_proto",
    };
    const function_object = try expectObject(out);
    for (realm_keys) |key_name| {
        const realm_proto_key = try rt.internAtom(key_name);
        defer rt.atoms.free(realm_proto_key);
        const realm_proto_value = constructor.getProperty(realm_proto_key);
        defer realm_proto_value.free(rt);
        if (!realm_proto_value.isUndefined()) {
            try function_object.defineOwnProperty(rt, realm_proto_key, core.Descriptor.data(realm_proto_value, true, false, true));
        }
    }
    return out;
}

fn constructCollectionValue(
    rt: *core.JSRuntime,
    kind: u32,
    prototype: ?*core.Object,
    args: []const core.JSValue,
    globals: []globals_mod.Slot,
) !core.JSValue {
    const collection_value = try builtins.collection.constructWithPrototype(rt, kind, prototype);
    errdefer collection_value.free(rt);
    if (args.len == 0 or args[0].isUndefined() or args[0].isNull()) return collection_value;

    const collection = try expectObject(collection_value);
    const adder_name: []const u8 = if (kind == 1 or kind == 3) "set" else "add";
    const adder = try getCollectionAdder(rt, collection, adder_name);
    defer adder.free(rt);
    if (!isCallableObject(adder)) return error.TypeError;

    const source = try expectObject(args[0]);
    if (!source.is_array) {
        try constructCollectionFromIterator(rt, collection_value, kind, args[0], adder, adder_name, globals);
        return collection_value;
    }
    var index: u32 = 0;
    while (index < source.length) : (index += 1) {
        const entry_value = source.getProperty(core.atom.atomFromUInt32(index));
        defer entry_value.free(rt);
        if (kind == 1 or kind == 3) {
            const entry = try expectObject(entry_value);
            if (!entry.is_array) return error.TypeError;
            const key = entry.getProperty(core.atom.atomFromUInt32(0));
            defer key.free(rt);
            const value = entry.getProperty(core.atom.atomFromUInt32(1));
            defer value.free(rt);
            var set_args = [_]core.JSValue{ key, value };
            if (isNativeCollectionAdder(rt, adder, adder_name)) {
                const out = try builtins.collection.methodCall(rt, collection_value, 1, &set_args);
                out.free(rt);
            } else {
                const out = try closure_mod.callWithThis(rt, adder, collection_value, &set_args, globals);
                out.free(rt);
                const set_out = try builtins.collection.methodCall(rt, collection_value, 1, &set_args);
                set_out.free(rt);
            }
        } else {
            var add_args = [_]core.JSValue{entry_value};
            if (isNativeCollectionAdder(rt, adder, adder_name)) {
                const out = try builtins.collection.methodCall(rt, collection_value, 6, &add_args);
                out.free(rt);
            } else {
                const out = try closure_mod.callWithThis(rt, adder, collection_value, &add_args, globals);
                out.free(rt);
                const add_out = try builtins.collection.methodCall(rt, collection_value, 6, &add_args);
                add_out.free(rt);
            }
        }
    }
    return collection_value;
}

pub fn constructCollectionClosure(
    rt: *core.JSRuntime,
    encoded: i32,
    globals: []globals_mod.Slot,
) !core.JSValue {
    if (encoded < 0) return error.TypeError;
    const collection_kind: u32 = @intCast(@divTrunc(encoded, 10));
    const arg_mode: i32 = @mod(encoded, 10);
    const prototype = try collectionPrototypeFromGlobals(rt, collection_kind, globals);

    var args: []core.JSValue = &.{};
    var arg_storage: [1]core.JSValue = undefined;
    switch (arg_mode) {
        0 => {},
        1 => {
            const array = try core.Object.createArray(rt, null);
            arg_storage[0] = array.value();
            args = arg_storage[0..1];
        },
        2 => {
            arg_storage[0] = try globals_mod.getByName(rt, globals, "iterable");
            args = arg_storage[0..1];
        },
        else => return error.TypeError,
    }
    defer {
        for (args) |arg| arg.free(rt);
    }
    return constructCollectionValue(rt, collection_kind, prototype, args, globals);
}

fn collectionPrototypeFromGlobals(rt: *core.JSRuntime, kind: u32, globals: []globals_mod.Slot) !?*core.Object {
    const name = collectionName(kind) orelse return error.TypeError;
    var constructor_value = try globals_mod.getByName(rt, globals, name);
    if (constructor_value.isUndefined()) {
        constructor_value.free(rt);
        constructor_value = try globalObjectProperty(rt, globals, name);
    }
    defer constructor_value.free(rt);
    const constructor = try expectObject(constructor_value);
    const prototype_value = constructor.getProperty(core.atom.ids.prototype);
    defer prototype_value.free(rt);
    if (!prototype_value.isObject()) return null;
    return try expectObject(prototype_value);
}

fn globalObjectProperty(rt: *core.JSRuntime, globals: []globals_mod.Slot, name: []const u8) !core.JSValue {
    const global_value = try globals_mod.getByName(rt, globals, "globalThis");
    defer global_value.free(rt);
    const global = try expectObject(global_value);
    const key = try rt.internAtom(name);
    defer rt.atoms.free(key);
    return global.getProperty(key);
}

fn constructCollectionFromIterator(
    rt: *core.JSRuntime,
    collection_value: core.JSValue,
    kind: u32,
    iterable_value: core.JSValue,
    adder: core.JSValue,
    adder_name: []const u8,
    globals: []globals_mod.Slot,
) !void {
    const iterable = try expectObject(iterable_value);
    const iterator_method_key = core.atom.predefinedId("Symbol.iterator", .symbol) orelse return error.TypeError;
    const iterator_method = iterable.getProperty(iterator_method_key);
    defer iterator_method.free(rt);
    if (iterator_method.isUndefined() or iterator_method.isNull()) return error.TypeError;
    if (!isCallableObject(iterator_method)) return error.TypeError;

    const iterator_value = try callClosureWithThis(rt, iterator_method, iterable_value, &.{}, globals);
    defer iterator_value.free(rt);
    const iterator = try expectObject(iterator_value);

    const next_key = try rt.internAtom("next");
    defer rt.atoms.free(next_key);
    const next_method = iterator.getProperty(next_key);
    defer next_method.free(rt);
    if (!isCallableObject(next_method)) return error.TypeError;

    while (true) {
        const next_result_value = try callClosureWithThis(rt, next_method, iterator_value, &.{}, globals);
        defer next_result_value.free(rt);
        const next_result = try expectObject(next_result_value);

        const done_key = try rt.internAtom("done");
        defer rt.atoms.free(done_key);
        const done_value = try getPropertyWithGetter(rt, next_result, done_key, globals);
        defer done_value.free(rt);
        if (done_value.asBool() == true) return;

        const value_key = try rt.internAtom("value");
        defer rt.atoms.free(value_key);
        const entry_value = getPropertyWithGetter(rt, next_result, value_key, globals) catch |err| {
            try closeIterator(rt, iterator, globals);
            return err;
        };
        defer entry_value.free(rt);

        if (kind == 1 or kind == 3) {
            const entry = expectObject(entry_value) catch |err| {
                try closeIterator(rt, iterator, globals);
                return err;
            };
            const key = getPropertyWithGetter(rt, entry, core.atom.atomFromUInt32(0), globals) catch |err| {
                try closeIterator(rt, iterator, globals);
                return err;
            };
            defer key.free(rt);
            const value = getPropertyWithGetter(rt, entry, core.atom.atomFromUInt32(1), globals) catch |err| {
                try closeIterator(rt, iterator, globals);
                return err;
            };
            defer value.free(rt);
            var set_args = [_]core.JSValue{ key, value };
            callCollectionAdder(rt, collection_value, adder, adder_name, &set_args, globals) catch |err| {
                try closeIterator(rt, iterator, globals);
                return err;
            };
        } else {
            var add_args = [_]core.JSValue{entry_value};
            callCollectionAdder(rt, collection_value, adder, adder_name, &add_args, globals) catch |err| {
                try closeIterator(rt, iterator, globals);
                return err;
            };
        }
    }
}

fn callCollectionAdder(
    rt: *core.JSRuntime,
    collection_value: core.JSValue,
    adder: core.JSValue,
    adder_name: []const u8,
    args: []const core.JSValue,
    globals: []globals_mod.Slot,
) !void {
    if (isNativeCollectionAdder(rt, adder, adder_name)) {
        const method: u32 = if (std.mem.eql(u8, adder_name, "set")) 1 else 6;
        const out = try builtins.collection.methodCall(rt, collection_value, method, args);
        out.free(rt);
        return;
    }
    const out = try callClosureWithThis(rt, adder, collection_value, args, globals);
    out.free(rt);
    const method: u32 = if (std.mem.eql(u8, adder_name, "set")) 1 else 6;
    const native_out = try builtins.collection.methodCall(rt, collection_value, method, args);
    native_out.free(rt);
}

fn closeIterator(rt: *core.JSRuntime, iterator: *core.Object, globals: []globals_mod.Slot) !void {
    const return_key = try rt.internAtom("return");
    defer rt.atoms.free(return_key);
    const return_method = iterator.getProperty(return_key);
    defer return_method.free(rt);
    if (!isCallableObject(return_method)) return;
    const out = callClosureWithThis(rt, return_method, iterator.value(), &.{}, globals) catch return;
    out.free(rt);
}

fn getPropertyWithGetter(rt: *core.JSRuntime, object: *core.Object, key: core.Atom, globals: []globals_mod.Slot) !core.JSValue {
    var cursor: ?*core.Object = object;
    while (cursor) |current_object| {
        if (current_object.getOwnProperty(key)) |desc| {
            defer desc.destroy(rt);
            if (desc.kind == .accessor) {
                if (desc.getter.isUndefined()) return core.JSValue.undefinedValue();
                return callClosureWithThis(rt, desc.getter, current_object.value(), &.{}, globals);
            }
            return desc.value.dup();
        }
        cursor = current_object.getPrototype();
    }
    return core.JSValue.undefinedValue();
}

fn callClosureWithThis(
    rt: *core.JSRuntime,
    callable: core.JSValue,
    this_value: core.JSValue,
    args: []const core.JSValue,
    globals: []globals_mod.Slot,
) !core.JSValue {
    const object = try expectObject(callable);
    if (object.class_id == core.class.ids.c_function) {
        const name = try nativeFunctionName(rt, object);
        defer rt.memory.allocator.free(name);
        if (builtins.collection.legacyClosureMethodId(name)) |method| {
            return builtins.collection.methodCallWithCallbackHost(rt, this_value, method, args, collection_adapter.host(globals)) catch |err| switch (err) {
                error.TypeError => error.TypeError,
                else => err,
            };
        }
        return error.TypeError;
    }
    if (object.class_id != core.class.ids.c_closure) return error.TypeError;
    return closure_mod.callWithThis(rt, callable, this_value, args, globals) catch |err| switch (err) {
        else => err,
    };
}

fn nativeFunctionName(rt: *core.JSRuntime, function_object: *core.Object) ![]u8 {
    const name_value = try nativeFunctionNameValue(rt, function_object, true);
    defer name_value.free(rt);
    var buffer = std.ArrayList(u8).empty;
    errdefer buffer.deinit(rt.memory.allocator);
    try value_ops.appendRawString(rt, &buffer, name_value);
    return buffer.toOwnedSlice(rt.memory.allocator);
}

fn nativeFunctionNameValue(rt: *core.JSRuntime, function_object: *core.Object, prefer_dispatch_name: bool) !core.JSValue {
    if (prefer_dispatch_name) {
        const dispatch_atom = function_object.nativeDispatchName();
        if (dispatch_atom != core.atom.null_atom) {
            const dispatch_name = try rt.atoms.toStringValue(rt, dispatch_atom);
            if (dispatch_name.isString()) return dispatch_name;
            dispatch_name.free(rt);
        }
    }
    const name_value = function_object.getProperty(core.atom.ids.name);
    if (!name_value.isString()) {
        name_value.free(rt);
        return error.TypeError;
    }
    return name_value;
}

fn isNativeCollectionAdder(rt: *core.JSRuntime, value: core.JSValue, expected: []const u8) bool {
    const header = value.refHeader() orelse return false;
    if (!value.isObject()) return false;
    const object: *core.Object = @fieldParentPtr("header", header);
    if (object.class_id != core.class.ids.c_function) return false;
    const name_value = nativeFunctionNameValue(rt, object, true) catch return false;
    defer name_value.free(rt);
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(rt.memory.allocator);
    value_ops.appendRawString(rt, &buffer, name_value) catch return false;
    return std.mem.eql(u8, buffer.items, expected);
}

fn getCollectionAdder(rt: *core.JSRuntime, collection: *core.Object, name: []const u8) !core.JSValue {
    const key = try rt.internAtom(name);
    defer rt.atoms.free(key);
    var cursor: ?*core.Object = collection;
    while (cursor) |object| {
        if (object.getOwnProperty(key)) |desc| {
            defer desc.destroy(rt);
            if (desc.kind == .accessor) {
                if (desc.getter.isUndefined()) return core.JSValue.undefinedValue();
                return closure_mod.call(rt, desc.getter, &.{}, &.{}) catch |err| switch (err) {
                    else => err,
                };
            }
            return desc.value.dup();
        }
        cursor = object.getPrototype();
    }
    return core.JSValue.undefinedValue();
}

fn expectObject(value: core.JSValue) !*core.Object {
    const header = value.refHeader() orelse return error.TypeError;
    if (!value.isObject()) return error.TypeError;
    return @fieldParentPtr("header", header);
}

fn expectStringValue(rt: *core.JSRuntime, expected: []const u8, value: core.JSValue) !void {
    var actual = std.ArrayList(u8).empty;
    defer actual.deinit(rt.memory.allocator);
    try value_ops.appendRawString(rt, &actual, value);
    try std.testing.expectEqualStrings(expected, actual.items);
}

fn constructorName(rt: *core.JSRuntime, constructor: *core.Object) !?[]u8 {
    const value = nativeFunctionNameValue(rt, constructor, true) catch return null;
    defer value.free(rt);
    var buffer = std.ArrayList(u8).empty;
    errdefer buffer.deinit(rt.memory.allocator);
    try value_ops.appendRawString(rt, &buffer, value);
    return try buffer.toOwnedSlice(rt.memory.allocator);
}

fn collectionName(kind: u32) ?[]const u8 {
    return switch (kind) {
        1 => "Map",
        2 => "Set",
        3 => "WeakMap",
        4 => "WeakSet",
        else => null,
    };
}

fn isDateConstructorRecord(object: *core.Object) bool {
    const native_ref = core.function.decodeNativeBuiltinId(object.nativeFunctionIdSlot().*) orelse return false;
    return native_ref.domain == .date and native_ref.id == @intFromEnum(builtins.date.ConstructorMethod.construct);
}

fn isRegExpConstructorRecord(object: *core.Object) bool {
    const native_ref = core.function.decodeNativeBuiltinId(object.nativeFunctionIdSlot().*) orelse return false;
    return native_ref.domain == .regexp and native_ref.id == @intFromEnum(builtins.regexp.ConstructorMethod.construct);
}

fn isCallableObject(value: core.JSValue) bool {
    const header = value.refHeader() orelse return false;
    if (!value.isObject()) return false;
    const object: *core.Object = @fieldParentPtr("header", header);
    return object.class_id == core.class.ids.c_function or
        object.class_id == core.class.ids.c_function_data or
        object.class_id == core.class.ids.c_closure or
        object.class_id == core.class.ids.bytecode_function or
        object.class_id == core.class.ids.bound_function;
}

fn expectConstructor(value: core.JSValue) !*core.Object {
    const header = value.refHeader() orelse return error.TypeError;
    if (!value.isObject()) return error.TypeError;
    const object: *core.Object = @fieldParentPtr("header", header);
    if (object.class_id != core.class.ids.c_function and
        object.class_id != core.class.ids.bytecode_function and
        object.class_id != core.class.ids.bound_function and
        object.class_id != core.class.ids.c_function_data and
        object.class_id != core.class.ids.c_closure)
    {
        return error.TypeError;
    }
    return object;
}

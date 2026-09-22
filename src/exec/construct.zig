//! Constructor-specific allocation bodies used by the unique Construct terminals.
//!
//! Callee and argument values are borrowed and rooted across observable work;
//! temporary prototype values are owned locally, while persistent proxy or
//! payload slots duplicate or explicitly take their inputs. Builtin record
//! domains own their direct bodies; TypedArray source copies live here as the
//! unique copy primitive consumed by `typedArrayConstructVm`.

const core = @import("../core/root.zig");
const builtin_dispatch = @import("builtin_dispatch.zig");
const value_ops = @import("value_ops.zig");
const std = @import("std");

// `new Object(stringPrimitive)` builds a String wrapper through the String
// construct record (Phase 6b-3 STEP 4) rather than naming
// `string_builtin_ops.constructWithPrototype`; the record's construct branch is
// pure (reads only `args`/`new_target`).
const string_construct_ref = core.function.NativeBuiltinRef{
    .domain = .string,
    .id = @intFromEnum(core.host_function.builtin_method_ids.string.ConstructorMethod.call),
};

pub fn functionObject(ctx: *core.RealmContext, name: core.Atom) !core.JSValue {
    const rt = ctx.runtimePtr();
    const function_proto = ctx.cached_function_proto orelse return error.InvalidBuiltinRegistry;
    const realm_global = ctx.global orelse return error.InvalidBuiltinRegistry;
    const object_proto_value = realm_global.cachedRealmValue(rt, .object_prototype) orelse return error.InvalidBuiltinRegistry;
    const object_proto = try core.Object.expect(object_proto_value);
    const function_name = rt.atoms.name(name) orelse "";
    const function_value = try core.function.nativeFunctionWithPrototypeAndCapacity(ctx, function_proto, function_name, 0, 3);
    const function = try core.Object.expect(function_value);

    const prototype = try core.Object.createWithOwnPropertyCapacity(rt, core.class.ids.object, object_proto, 1);
    const prototype_value = prototype.value();

    try prototype.defineOwnPropertyAssumingNew(rt, core.atom.ids.constructor, core.Descriptor.data(function_value, .method));
    try function.defineOwnProperty(rt, core.atom.ids.prototype, core.Descriptor.data(prototype_value, .{ .writable = true }));

    return function_value;
}

pub fn constructErrorObject(rt: *core.JSRuntime, name: []const u8, constructor: core.JSValue, prototype: ?*core.Object, args: []const core.JSValue) !core.JSValue {
    var rooted_args_buffer = try core.runtime.ValueRootBuffer.initCopy(rt, args);
    defer rooted_args_buffer.deinit(rt);
    const rooted_args = rooted_args_buffer.values;
    var root_slices = [_]core.runtime.ValueRootSlice{
        rooted_args_buffer.slice(),
    };
    var root_frame = core.runtime.ValueRootFrame{
        .slices = &root_slices,
    };
    root_frame.activate(rt);
    defer root_frame.deactivate(rt);

    if (std.mem.eql(u8, name, "AggregateError")) return constructAggregateErrorObject(rt, constructor, prototype, rooted_args);
    const instance = try core.Object.create(rt, core.class.ids.error_, prototype);
    errdefer core.Object.destroyFromHeader(rt, instance.gcHeader());
    // No own `name` property: it lives on the per-class prototype only
    // (qjs js_error_constructor quickjs.c defines only message/cause).
    if (rooted_args.len >= 1 and !rooted_args[0].is(.undefined_value)) {
        const message = try value_ops.toStringValue(rt, rooted_args[0]);
        try instance.defineOwnProperty(rt, core.atom.ids.message, core.Descriptor.data(message, .method));
    }
    return instance.value();
}

test "constructErrorObject roots direct symbol message while creating error" {
    const rt = try core.JSRuntime.create(.{ .allocator = std.testing.allocator });
    defer rt.destroy();

    const message_atom = try rt.atoms.newValueSymbol("gc-construct-error-message-symbol");
    const message_arg = try rt.takeSymbolValue(message_atom);
    const args = [_]core.JSValue{
        message_arg,
    };

    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const error_value = try constructErrorObject(rt, "Error", core.JSValue.undefinedValue(), null, &args);
    const object = try expectObject(error_value);

    try std.testing.expect(rt.atoms.name(message_atom) != null);
    const message_key = try rt.internAtom("message");
    const message_value = try object.getProperty(message_key);
    try expectStringValue(rt, "Symbol(gc-construct-error-message-symbol)", message_value);

    _ = rt.collectForTest();
    try std.testing.expect(rt.atoms.name(message_atom) == null);
}

pub fn constructDOMExceptionObject(rt: *core.JSRuntime, prototype: ?*core.Object, args: []const core.JSValue) !core.JSValue {
    var rooted_args_buffer = try core.runtime.ValueRootBuffer.initCopy(rt, args);
    defer rooted_args_buffer.deinit(rt);
    const rooted_args = rooted_args_buffer.values;
    var root_slices = [_]core.runtime.ValueRootSlice{
        rooted_args_buffer.slice(),
    };
    var root_frame = core.runtime.ValueRootFrame{
        .slices = &root_slices,
    };
    root_frame.activate(rt);
    defer root_frame.deactivate(rt);

    const instance = try core.Object.create(rt, core.class.ids.error_, prototype);
    errdefer core.Object.destroyFromHeader(rt, instance.gcHeader());
    const message = if (rooted_args.len >= 1 and !rooted_args[0].is(.undefined_value))
        try value_ops.toStringValue(rt, rooted_args[0])
    else
        try value_ops.createStringValue(rt, "");
    const name = if (rooted_args.len >= 2 and !rooted_args[1].is(.undefined_value))
        try value_ops.toStringValue(rt, rooted_args[1])
    else
        try value_ops.createStringValue(rt, "Error");
    try instance.defineOwnProperty(rt, core.atom.ids.name, core.Descriptor.data(name, .method));
    try instance.defineOwnProperty(rt, core.atom.ids.message, core.Descriptor.data(message, .method));
    try instance.defineOwnProperty(rt, core.atom.ids.code, core.Descriptor.data(core.JSValue.int32(try domExceptionCode(rt, name)), .method));
    return instance.value();
}

test "constructDOMExceptionObject roots direct symbol args while creating error" {
    const rt = try core.JSRuntime.create(.{ .allocator = std.testing.allocator });
    defer rt.destroy();

    const message_atom = try rt.atoms.newValueSymbol("gc-dom-exception-message-symbol");
    const message_arg = try rt.takeSymbolValue(message_atom);
    const name_atom = try rt.atoms.newValueSymbol("gc-dom-exception-name-symbol");
    const name_arg = try rt.takeSymbolValue(name_atom);
    const args = [_]core.JSValue{
        message_arg,
        name_arg,
    };

    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const error_value = try constructDOMExceptionObject(rt, null, &args);
    const object = try expectObject(error_value);

    try std.testing.expect(rt.atoms.name(message_atom) != null);
    try std.testing.expect(rt.atoms.name(name_atom) != null);
    const message_key = try rt.internAtom("message");
    const message_value = try object.getProperty(message_key);
    try expectStringValue(rt, "Symbol(gc-dom-exception-message-symbol)", message_value);
    const name_key = try rt.internAtom("name");
    const name_value = try object.getProperty(name_key);
    try expectStringValue(rt, "Symbol(gc-dom-exception-name-symbol)", name_value);

    _ = rt.collectForTest();
    try std.testing.expect(rt.atoms.name(message_atom) == null);
    try std.testing.expect(rt.atoms.name(name_atom) == null);
}

fn domExceptionCode(rt: *core.JSRuntime, name_value: core.JSValue) !i32 {
    var name = std.ArrayList(u8).empty;
    defer name.deinit(rt.nativeAllocator());
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
    var root_frame = core.runtime.ValueRootFrame{
        .values = &root_values,
        .slices = &root_slices,
    };
    root_frame.activate(rt);
    defer root_frame.deactivate(rt);

    const instance = try core.Object.create(rt, core.class.ids.error_, prototype);
    errdefer core.Object.destroyFromHeader(rt, instance.gcHeader());
    // No own `name` property: it lives on AggregateError.prototype
    // (qjs js_error_constructor quickjs.c, JS_AGGREGATE_ERROR magic).

    if (rooted_args.len < 1 or !rooted_args[0].is(.object)) return error.TypeError;
    const errors_source = try expectObject(rooted_args[0]);
    if (!errors_source.isArray()) return error.TypeError;
    if (rooted_args.len >= 2 and !rooted_args[1].is(.undefined_value)) {
        const message = try value_ops.toStringValue(rt, rooted_args[1]);
        try instance.defineOwnProperty(rt, core.atom.ids.message, core.Descriptor.data(message, .method));
    }

    if (rooted_args.len >= 3 and rooted_args[2].is(.object)) {
        const options = try expectObject(rooted_args[2]);
        const cause_key = core.atom.ids.cause;
        cause_val = try options.getProperty(cause_key);
        var has_cause = !cause_val.is(.undefined_value);
        if (!has_cause) {
            has_cause = (try options.getOwnProperty(rt, cause_key)) != null;
        }
        if (has_cause) try instance.defineOwnProperty(rt, core.atom.ids.cause, core.Descriptor.data(cause_val, .method));
        cause_val = core.JSValue.undefinedValue();
    }

    const errors_array = try core.Object.createArray(rt, null);
    errors_array_val = errors_array.value();

    var index: u32 = 0;
    while (index < errors_source.arrayLength()) : (index += 1) {
        copied_error_val = try errors_source.getProperty(core.Atom.taggedInt(index));
        try errors_array.defineOwnProperty(rt, core.Atom.taggedInt(index), core.Descriptor.data(copied_error_val, .all));
        copied_error_val = core.JSValue.undefinedValue();
    }
    errors_array.setArrayLength(errors_source.arrayLength());
    try errors_array.defineOwnProperty(rt, core.atom.ids.length, core.Descriptor.data(core.JSValue.int32(@intCast(errors_source.arrayLength())), .{ .writable = true }));
    try instance.defineOwnProperty(rt, core.atom.ids.errors, core.Descriptor.data(errors_array_val, .method));
    return instance.value();
}

pub fn isConstructErrorObjectName(name: []const u8) bool {
    return core.error_names.isConstructErrorObjectName(name);
}

pub fn weakRefWithPrototype(rt: *core.JSRuntime, target: core.JSValue, prototype: ?*core.Object) !core.JSValue {
    var rooted_target = target;
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &rooted_target },
    };
    var root_frame = core.runtime.ValueRootFrame{
        .values = &root_values,
    };
    root_frame.activate(rt);
    defer root_frame.deactivate(rt);

    const instance = try core.Object.create(rt, core.class.ids.weak_ref, prototype);
    errdefer core.Object.destroyFromHeader(rt, instance.gcHeader());
    try instance.setWeakRefTarget(rt, rooted_target);
    return instance.value();
}

test "weakRefWithPrototype roots direct symbol target while creating weak ref" {
    const rt = try core.JSRuntime.create(.{ .allocator = std.testing.allocator });
    defer rt.destroy();

    const symbol_atom = try rt.atoms.newValueSymbol("gc-construct-weak-ref-symbol");
    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const symbol_value = try rt.takeSymbolValue(symbol_atom);
    const weak_ref_value = try weakRefWithPrototype(rt, symbol_value, null);
    const weak_ref = try expectObject(weak_ref_value);

    {
        const live = weak_ref.weakRefDeref(rt);
        try std.testing.expect(live.same(symbol_value));
    }
    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    rt.clearWeakRefKeptAlive();

    _ = rt.collectForTest();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
    try std.testing.expect(weak_ref.weakRefDeref(rt).is(.undefined_value));
}

fn constructPrimitiveWrapper(rt: *core.JSRuntime, class_id: core.class.ClassId, prototype: ?*core.Object, primitive: core.JSValue) !core.JSValue {
    var rooted_primitive = primitive;
    var root_frame = core.runtime.rootValues(.{&rooted_primitive});
    root_frame.activate(rt);
    defer root_frame.deactivate(rt);

    const instance = try core.Object.create(rt, class_id, prototype);
    errdefer core.Object.destroyFromHeader(rt, instance.gcHeader());
    try instance.setOptionalValueSlot(rt, instance.objectDataSlot(), rooted_primitive);
    return instance.value();
}

test "constructPrimitiveWrapper roots direct symbol while creating wrapper" {
    const rt = try core.JSRuntime.create(.{ .allocator = std.testing.allocator });
    defer rt.destroy();

    const symbol_atom = try rt.atoms.newValueSymbol("gc-construct-wrapper-symbol");
    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const symbol_value = try rt.takeSymbolValue(symbol_atom);
    const wrapper_value = try constructPrimitiveWrapper(rt, core.class.ids.symbol, null, symbol_value);
    const wrapper = try expectObject(wrapper_value);

    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    const stored = wrapper.objectData() orelse return error.TypeError;
    try std.testing.expect(stored.same(symbol_value));

    _ = rt.collectForTest();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

/// Shared Object constructor / [[Call]] body. The native-record path has
/// already distinguished a custom new.target, matching QuickJS
/// `js_object_constructor` before it reaches the nullish/ToObject switch below.
pub fn objectConstructorValue(ctx: *core.JSContext, args: []const core.JSValue, constructor: *core.Object) !core.JSValue {
    const rt = ctx.runtime;
    if (args.len >= 1) {
        const value = args[0];
        if (value.is(.object)) return value;
        if (!value.is(.null_value) and !value.is(.undefined_value)) {
            if (value.isString()) {
                return (try builtin_dispatch.callConstructRecord(ctx, null, null, &.{}, null, string_construct_ref, try primitivePrototypeFromObjectConstructor(constructor, core.class.ids.string), &.{value}, null, null)) orelse error.TypeError;
            }
            if (value.isNumber()) {
                return constructPrimitiveWrapper(rt, core.class.ids.number, try primitivePrototypeFromObjectConstructor(constructor, core.class.ids.number), value);
            }
            if (value.as(.boolean) != null) {
                return constructPrimitiveWrapper(rt, core.class.ids.boolean, try primitivePrototypeFromObjectConstructor(constructor, core.class.ids.boolean), value);
            }
            if (value.isBigInt()) {
                return constructPrimitiveWrapper(rt, core.class.ids.big_int, try primitivePrototypeFromObjectConstructor(constructor, core.class.ids.big_int), value);
            }
            if (value.is(.symbol)) {
                return constructPrimitiveWrapper(rt, core.class.ids.symbol, try primitivePrototypeFromObjectConstructor(constructor, core.class.ids.symbol), value);
            }
        }
    }
    const object_prototype = try constructor.getProperty(core.atom.ids.prototype);
    const prototype = if (object_prototype.is(.object)) core.value_semantics.objectFromValue(object_prototype) else null;
    const object = try core.Object.create(rt, core.class.ids.object, prototype);
    return object.value();
}

fn primitivePrototypeFromObjectConstructor(constructor: *core.Object, class_id: core.ClassId) !*core.Object {
    const realm = constructor.nativeFunctionRealm() orelse return error.InvalidBuiltinRegistry;
    return realm.classPrototypeObject(class_id) orelse error.InvalidBuiltinRegistry;
}

pub const TypedArrayElement = core.typed_array_names.Element;

pub fn typedArrayElement(name: []const u8) ?TypedArrayElement {
    return core.typed_array_names.element(name);
}

pub fn constructTypedArrayTypedArrayInput(rt: *core.JSRuntime, prototype: ?*core.Object, array_buffer_prototype: *core.Object, element: TypedArrayElement, source: *core.Object) !core.JSValue {
    if (try core.object.typedArrayDetached(source)) return error.TypeError;
    if (try core.object.typedArrayOutOfBounds(source)) {
        const buffer_value = source.typedArrayBuffer() orelse return error.TypeError;
        const buffer_header = buffer_value.refHeader() orelse return error.TypeError;
        const buffer = core.Object.fromHeader(buffer_header);
        if (source.typedArrayFixedLength() != null or source.typedArrayByteOffset() > buffer.byteStorage().len) return error.TypeError;
    }
    const length = try core.object.typedArrayLength(rt, source);
    const byte_length = try std.math.mul(u32, length, element.size);
    var backing_buffer = core.JSValue.undefinedValue();
    var object_value = core.JSValue.undefinedValue();
    var value = core.JSValue.undefinedValue();
    var root_frame = core.runtime.rootValues(.{ &backing_buffer, &object_value, &value });
    root_frame.activate(rt);
    defer root_frame.deactivate(rt);

    backing_buffer = try createTypedArrayBackingBuffer(rt, array_buffer_prototype, @intCast(byte_length));
    object_value = try core.typed_array.typedArrayConstructWithOptions(rt, element.size, element.kind, backing_buffer, &.{backing_buffer}, prototype);
    const object = try expectObject(object_value);

    var index: u32 = 0;
    while (index < length) : (index += 1) {
        value = try core.typed_array.typedArrayGetIndex(rt, source, index);
        _ = try core.typed_array.typedArraySetIndex(rt, object, index, value);

        value = core.JSValue.undefinedValue();
    }
    return object_value;
}

fn createTypedArrayBackingBuffer(rt: *core.JSRuntime, array_buffer_prototype: *core.Object, byte_length: i32) !core.JSValue {
    return core.typed_array.arrayBufferConstructLength(rt, @intCast(byte_length), null, array_buffer_prototype);
}

const expectObject = core.value_semantics.expectObject;

fn expectStringValue(rt: *core.JSRuntime, expected: []const u8, value: core.JSValue) !void {
    var actual = std.ArrayList(u8).empty;
    defer actual.deinit(rt.nativeAllocator());
    try value_ops.appendRawString(rt, &actual, value);
    try std.testing.expectEqualStrings(expected, actual.items);
}

fn isCallableObject(value: core.JSValue) bool {
    const header = value.refHeader() orelse return false;
    if (!value.is(.object)) return false;
    const object = core.Object.fromHeader(header);
    return object.class_id == core.class.ids.c_function or
        object.class_id == core.class.ids.c_function_data or
        core.class.isAsyncFunctionResumeClass(object.class_id) or
        core.class.isBytecodeFunctionClass(object.class_id) or
        object.class_id == core.class.ids.bound_function;
}

fn isConstructibleBytecodeFunctionObject(object: *const core.Object) bool {
    return switch (object.class_id) {
        core.class.ids.bytecode_function => if (object.bytecodeFunctionStoragePtrConst().function_bytecode) |fb|
            fb.hasPrototype() and fb.functionKind() == .normal
        else
            false,
        core.class.ids.generator_function,
        core.class.ids.async_function,
        core.class.ids.async_generator_function,
        => false,
        else => false,
    };
}

fn expectConstructor(value: core.JSValue) !*core.Object {
    const header = value.refHeader() orelse return error.TypeError;
    if (!value.is(.object)) return error.TypeError;
    const object = core.Object.fromHeader(header);
    if (core.class.isBytecodeFunctionClass(object.class_id)) {
        if (!isConstructibleBytecodeFunctionObject(object)) return error.TypeError;
        return object;
    }
    if (object.class_id != core.class.ids.c_function and
        object.class_id != core.class.ids.bound_function)
    {
        return error.TypeError;
    }
    return object;
}

test "legacy constructor gate follows four-class bytecode constructability" {
    const rt = try core.JSRuntime.create(.{ .allocator = std.testing.allocator });
    defer rt.destroy();

    const Case = struct {
        class_id: core.ClassId,
        func_kind: core.function_bytecode.FunctionKind,
        has_prototype: bool,
        expected_constructor: bool,
    };
    const Fixture = struct {
        fn create(runtime: *core.JSRuntime, case: Case) !*core.Object {
            const object = try core.Object.create(runtime, case.class_id, null);

            const fb = try core.FunctionBytecode.createFixture(runtime, .{ .flags = .{
                .func_kind = case.func_kind,
                .has_prototype = case.has_prototype,
            } });
            fb.publishFixtureNoFail(runtime);
            try object.setFunctionBytecodeValue(runtime, core.JSValue.functionBytecode(&fb.header));
            return object;
        }
    };
    const cases = [_]Case{
        .{ .class_id = core.class.ids.bytecode_function, .func_kind = .normal, .has_prototype = true, .expected_constructor = true },
        // Canonical arrows are ordinary-kind bytecode functions without a
        // prototype; a prototype-bearing arrow fixture is not a valid state.
        .{ .class_id = core.class.ids.bytecode_function, .func_kind = .normal, .has_prototype = false, .expected_constructor = false },
        .{ .class_id = core.class.ids.generator_function, .func_kind = .generator, .has_prototype = true, .expected_constructor = false },
        .{ .class_id = core.class.ids.async_function, .func_kind = .async, .has_prototype = false, .expected_constructor = false },
        .{ .class_id = core.class.ids.async_generator_function, .func_kind = .async_generator, .has_prototype = true, .expected_constructor = false },
    };

    for (cases) |case| {
        const function_object = try Fixture.create(rt, case);
        try std.testing.expect(isCallableObject(function_object.value()));
        if (case.expected_constructor) {
            try std.testing.expectEqual(function_object, try expectConstructor(function_object.value()));
        } else {
            try std.testing.expectError(error.TypeError, expectConstructor(function_object.value()));
        }
    }
}

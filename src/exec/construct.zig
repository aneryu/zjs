//! Constructor-specific allocation bodies used by the unique Construct terminals.
//!
//! Callee and argument values are borrowed and rooted across observable work.
//! Builtin record
//! domains own their direct bodies; TypedArray source copies live here as the
//! unique copy primitive consumed by `typedArrayConstructVm`.

const core = @import("../core/root.zig");
const builtin_dispatch = @import("builtin_dispatch.zig");
const std = @import("std");

// `new Object(stringPrimitive)` builds a String wrapper through the String
// construct record (Phase 6b-3 STEP 4) rather than naming
// `string_builtin_ops.constructWithPrototype`; the record's construct branch is
// pure (reads only `args`/`new_target`).
const string_construct_ref = core.function.NativeBuiltinRef{
    .domain = .string,
    .id = @intFromEnum(core.host_function.builtin_method_ids.string.ConstructorMethod.call),
};

pub fn weakRefWithPrototype(rt: *core.JSRuntime, target: core.JSValue, prototype: ?*core.Object) !core.JSValue {
    var rooted_target = target;
    var root_values = [_]*core.JSValue{
        &rooted_target,
    };
    var root_frame = core.runtime.ValueRootFrame{
        .values = &root_values,
    };
    root_frame.activate(rt);
    defer root_frame.deactivate(rt);

    const instance = try core.Object.create(rt, core.class.ids.weak_ref, prototype);
    errdefer core.Object.destroyFromHeader(rt, instance.gcHeader());
    try instance.setWeakRefTarget(rt, rooted_target);
    // WeakRef(target) step 4: AddToKeptObjects(target) keeps it alive until
    // the end of the current job; deref does exactly that.
    _ = try instance.weakRefDeref(rt);
    return instance.value();
}

test "weakRefWithPrototype roots direct symbol target while creating weak ref" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const symbol_atom = try rt.atoms.newValueSymbol("gc-construct-weak-ref-symbol");
    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const symbol_value = try rt.takeSymbolValue(symbol_atom);
    const weak_ref_value = try weakRefWithPrototype(rt, symbol_value, null);
    const weak_ref = try expectObject(weak_ref_value);

    {
        const live = try weak_ref.weakRefDeref(rt);
        try std.testing.expect(live.same(symbol_value));
    }
    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    rt.clearWeakRefKeptAlive();

    _ = rt.collectForTest();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
    try std.testing.expect((try weak_ref.weakRefDeref(rt)).is(.undefined_value));
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
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
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
        // The caller returns object arguments before reaching here.
        if (!value.is(.null_value) and !value.is(.undefined_value)) {
            if (value.isString()) {
                return (try builtin_dispatch.callConstructRecord(ctx, null, null, null, string_construct_ref, try primitivePrototypeFromObjectConstructor(constructor, core.class.ids.string), &.{value}, null, null)) orelse error.TypeError;
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
    if (try core.object.typedArrayDetached(source)) return error.TypedArrayOutOfBounds;
    if (try core.object.typedArrayOutOfBounds(source)) return error.TypedArrayOutOfBounds;
    // InitializeTypedArrayFromTypedArray: content types must match even for
    // an empty source.
    if (source.typedArrayKind().isBigInt() != element.kind.isBigInt()) return error.TypedArrayContentTypeMismatch;
    const length = try core.object.typedArrayLength(rt, source);
    const byte_length = @as(usize, length) * element.size; // length is a u32
    var backing_buffer = core.JSValue.undefinedValue();
    var object_value = core.JSValue.undefinedValue();
    var value = core.JSValue.undefinedValue();
    var root_frame = core.runtime.rootValues(.{ &backing_buffer, &object_value, &value });
    root_frame.activate(rt);
    defer root_frame.deactivate(rt);

    backing_buffer = try core.typed_array.arrayBufferConstructLength(rt, byte_length, null, array_buffer_prototype);
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

const expectObject = core.value_semantics.expectObject;

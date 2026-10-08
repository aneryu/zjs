//! Execution-layer object, property, prototype, proxy, and function-object algorithms.
//!
//! Values are traced by the GC, not reference counted: arguments and results
//! need no ownership transfer, but a value held only in a native local must be
//! rooted across anything that can allocate. Keep the
//! `ctx`/`output`/`global`/caller-function/caller-frame tuple
//! explicit: the threaded `global` is cross-realm authority, not necessarily
//! `ctx.globalObject()`. Benchmark-hot object/property arms must not be shared
//! with cold generic paths. Core mappings include QuickJS primitive-prototype,
//! closure, and function-object paths.

const std = @import("std");
const function_ops = @import("function_ops.zig");
const bytecode = @import("../bytecode.zig");
const builtin_dispatch = @import("builtin_dispatch.zig");
const core = @import("../core/root.zig");
const method_ids = core.host_function.builtin_method_ids;
const call = @import("call.zig");
const construct_mod = @import("construct.zig");
const date_ops = @import("date_ops.zig");
const frame_mod = @import("frame.zig");
const iterator_ops = @import("iterator_ops.zig");
const property_ops = @import("property_ops.zig");
const reflect_ops = @import("reflect_ops.zig");
const zjs_vm = @import("zjs_vm.zig");
const value_ops = @import("value_ops.zig");
const vm_property = @import("vm_property.zig");
const stack_mod = @import("stack.zig");
const Vm = @import("tailcall_dispatch.zig").Vm;
const HostError = exception_ops.HostError;
const exception_ops = @import("exception_ops.zig");
const call_runtime = @import("call_runtime.zig");
const array_ops = @import("array_ops.zig");
const builtin_glue = @import("builtin_glue.zig");
const module_mod = @import("module.zig");
const promise_ops = @import("promise_ops.zig");
const regexp_fastpath = @import("regexp_ops.zig");
const string_ops = @import("string_ops.zig");

// --- Dynamically gathered call_runtime aliases (excluding local definitions) ---
const DataViewConstructorArgs = builtin_glue.DataViewConstructorArgs;
const DynamicFunctionKind = function_ops.DynamicFunctionKind;
const LengthIndexAtom = array_ops.LengthIndexAtom;
const RegExpMatch = string_ops.RegExpMatch;

const addCollectionEntriesFromIterator = builtin_glue.addCollectionEntriesFromIterator;
const aggregateErrorsIterableToArray = array_ops.aggregateErrorsIterableToArray;
const appendDecodedRegExpGroupName = regexp_fastpath.appendDecodedRegExpGroupName;
const arrayLengthAssignmentValue = array_ops.arrayLengthAssignmentValue;
const arrayPrototypeFromGlobal = array_ops.arrayPrototypeFromGlobal;
const arrayPrototypeValuesFromGlobal = array_ops.arrayPrototypeValuesFromGlobal;
const asyncFunctionPrototypeFromGlobal = promise_ops.asyncFunctionPrototypeFromGlobal;
const asyncGeneratorPrototypeFromGlobal = promise_ops.asyncGeneratorPrototypeFromGlobal;
const callAccessorSetter = call_runtime.callAccessorSetter;
const callSiteFunctionNameValue = exception_ops.callSiteFunctionNameValue;
const callValueOrBytecodeSyncInternal = call_runtime.callValueOrBytecodeSyncInternalOutlined;
const captureErrorStack = exception_ops.captureErrorStack;
const createArrayFromArgs = array_ops.createArrayFromArgs;
const createRegExpIndexPair = regexp_fastpath.createRegExpIndexPair;
const currentFrameFunctionIsStrict = call_runtime.currentFrameFunctionIsStrict;
const defineNativeDataMethod = builtin_glue.defineNativeDataMethod;
const ensureVarRefsCapacity = frame_mod.ensureVarRefsCapacity;
const functionBytecodeFromValue = call_runtime.functionBytecodeFromValue;
const functionConstructorFromGlobal = builtin_glue.functionConstructorFromGlobal;
const functionNameValueFromAtom = call_runtime.functionNameValueFromAtom;
const functionRealmContext = call_runtime.functionRealmContext;
const functionRealmGlobal = call_runtime.functionRealmGlobal;
const functionRuntimeStrict = call_runtime.functionRuntimeStrict;
const getFastStringPrimitiveDataProperty = string_ops.getFastStringPrimitiveDataProperty;
const getStringIndexValue = string_ops.getStringIndexValue;
const importMetaUrlValue = module_mod.importMetaUrlValue;
const isCallableValue = call_runtime.isCallableValue;
const isConstructorLike = call_runtime.isConstructorLike;
const lengthIndexValue = array_ops.lengthIndexValue;
const mappedArgumentsValue = call_runtime.mappedArgumentsValue;
const ordinarySetWithReceiver = call_runtime.ordinarySetWithReceiver;
const bigIntPrototypeToString = string_ops.bigIntPrototypeToString;
const createArrayDataOrTypedArrayElement = array_ops.createArrayDataOrTypedArrayElement;
const defineToStringTag = iterator_ops.defineToStringTag;
const objectEntryArrayValue = array_ops.objectEntryArrayValue;
const regExpAutoInitBuiltinMatches = string_ops.regExpAutoInitBuiltinMatches;
const regExpNativeBuiltinMatches = string_ops.regExpNativeBuiltinMatches;
const regExpConstructorFromGlobal = regexp_fastpath.regExpConstructorFromGlobal;
const runGeneratorParameterInit = call_runtime.runGeneratorParameterInit;
const setFailureShouldThrow = call_runtime.setFailureShouldThrow;
const setMappedArgumentsValue = call_runtime.setMappedArgumentsValue;
const storeRealmValue = builtin_glue.storeRealmValue;
const stringObjectHasIndexProperty = string_ops.stringObjectHasIndexProperty;
const throwPrivateBrandTypeError = call_runtime.throwPrivateBrandTypeError;
const throwRangeErrorMessage = exception_ops.throwRangeErrorMessage;
const throwSetFailureTypeError = call_runtime.throwSetFailureTypeError;
const throwTypeErrorIntrinsicForGlobal = call_runtime.throwTypeErrorIntrinsicForGlobal;
const throwTypeErrorMessage = exception_ops.throwTypeErrorMessage;
const toLengthIndex = value_ops.toLengthIndex;
const toPrimitiveForString = string_ops.toPrimitiveForString;
const toStringForAnnexB = string_ops.toStringForAnnexB;
const typedArrayCanonicalGet = array_ops.typedArrayCanonicalGet;
const typedArrayCanonicalDelete = array_ops.typedArrayCanonicalDelete;
const typedArrayCanonicalHas = array_ops.typedArrayCanonicalHas;
const typedArrayCanonicalOwnDescriptor = array_ops.typedArrayCanonicalOwnDescriptor;
const typedArrayCanonicalIndexExists = array_ops.typedArrayCanonicalIndexExists;
const typedArrayDefineOwnPropertyVm = array_ops.typedArrayDefineOwnPropertyVm;
const typedArrayOwnKeys = array_ops.typedArrayOwnKeys;
const typedArrayPrototypeSet = array_ops.typedArrayPrototypeSet;
const valueTruthy = value_ops.valueTruthy;

pub fn objectPrototypeFromGlobal(rt: *core.JSRuntime, global: *core.Object) ?*core.Object {
    // Use the realm-cached `%Object.prototype%` (O(1) array index, like QuickJS's
    // `class_proto[JS_CLASS_OBJECT]`) instead of resolving `global.Object.prototype`
    // by two property-hash lookups on EVERY object allocation. `arrayPrototypeFromGlobal`
    // already takes this fast path; `{}` literals went through the slow path and it
    // showed up as ~7.7% of empty-object allocation. `Object.prototype` is
    // non-writable/non-configurable so the cached value never goes stale.
    if (global.cachedRealmValue(rt, .object_prototype)) |stored| {
        return core.value_semantics.objectFromValue(stored);
    }
    if (rt.contextForGlobal(global)) |ctx| {
        if (ctx.classPrototypeObject(core.class.ids.object)) |prototype| return prototype;
    }
    return constructorPrototypeFromGlobalAtom(global, core.atom.ids.Object);
}

/// Global-binding walk of `global[name].prototype`. Result objects that spec
/// says should use a realm intrinsic must not call this: use
/// `JSContext.classPrototypeObject` or `nativeErrorPrototypeObject` instead.
/// Kept for embedder fallbacks where no class table has been published.
pub fn constructorPrototypeFromGlobal(rt: *core.JSRuntime, global: *core.Object, constructor_name: []const u8) ?*core.Object {
    const ctor_key = rt.internAtom(constructor_name) catch return null;
    return constructorPrototypeFromGlobalAtom(global, ctor_key);
}

pub fn constructorPrototypeFromGlobalAtom(global: *core.Object, constructor_atom: core.Atom) ?*core.Object {
    if (global.getOwnDataObjectBorrowed(constructor_atom)) |constructor| {
        if (constructor.getOwnDataObjectBorrowed(core.atom.ids.prototype)) |prototype| return prototype;
    }
    return null;
}

pub fn functionPrototypeFromGlobal(global: *core.Object) ?*core.Object {
    return constructorPrototypeFromGlobalAtom(global, core.atom.ids.Function);
}

pub fn cachedRealmObject(rt: *core.JSRuntime, global: *core.Object, slot: core.object.RealmValueSlot) ?*core.Object {
    const stored = global.cachedRealmValue(rt, slot) orelse return null;
    return core.value_semantics.objectFromValue(stored);
}

pub fn primitivePrototypeFromRealmOrGlobal(
    rt: *core.JSRuntime,
    global: *core.Object,
    slot: core.object.RealmValueSlot,
    constructor_atom: core.Atom,
) ?*core.Object {
    // Mirror QuickJS JS_GetPrototypePrimitive: primitive
    // prototype lookup reads ctx->class_proto[...] directly. The realm slot is
    // the intrinsic pointer; fallback preserves bare-runtime/global-walk behavior.
    if (cachedRealmObject(rt, global, slot)) |stored| return stored;
    // Embedder fallback when the realm slot is unpublished. Standard boxing
    // uses the cached intrinsic, so replacing `globalThis.String` is not
    // observable here.
    return constructorPrototypeFromGlobalAtom(global, constructor_atom);
}

fn primitivePrototypeForAccess(rt: *core.JSRuntime, global: *core.Object, primitive: core.JSValue) ?*core.Object {
    if (primitive.isString()) {
        const constructor_atom = comptime (core.atom.predefinedId("String", .string)).?;
        return primitivePrototypeFromRealmOrGlobal(rt, global, .string_prototype, constructor_atom);
    }
    if (primitive.isNumber()) {
        const constructor_atom = comptime (core.atom.predefinedId("Number", .string)).?;
        return primitivePrototypeFromRealmOrGlobal(rt, global, .number_prototype, constructor_atom);
    }
    if (primitive.is(.boolean)) {
        const constructor_atom = comptime (core.atom.predefinedId("Boolean", .string)).?;
        return primitivePrototypeFromRealmOrGlobal(rt, global, .boolean_prototype, constructor_atom);
    }
    if (primitive.isBigInt()) {
        const constructor_atom = comptime (core.atom.predefinedId("BigInt", .string)).?;
        return primitivePrototypeFromRealmOrGlobal(rt, global, .bigint_prototype, constructor_atom);
    }
    if (primitive.is(.symbol)) {
        const constructor_atom = comptime (core.atom.predefinedId("Symbol", .string)).?;
        return primitivePrototypeFromRealmOrGlobal(rt, global, .symbol_prototype, constructor_atom);
    }
    return null;
}

/// Materialize an ordinary function's ThisBinding on first observation.
/// QuickJS keeps the raw `this_obj` through JS_CallInternal and performs
/// sloppy nullish substitution / primitive ToObject in OP_push_this. Direct
/// eval of an ordinary function uses the same hook. Arrow lexical `this` is an
/// ordinary closure cell and never observes the arrow frame slot. Replacing
/// the frame slot once preserves wrapper identity within the invocation.
pub fn materializeFrameThisBinding(ctx: *core.JSContext, global: *core.Object, frame: *frame_mod.Frame) !core.JSValue {
    if (frame.function.isStrictMode() or frame.function.runtimeStrictMode()) return frame.this_value;

    const current = frame.this_value;
    if (current.is(.object)) return current;
    if (current.is(.undefined_value) or current.is(.null_value)) {
        frame.this_value = global.value();
        return frame.this_value;
    }

    const boxed = try primitiveObjectForAccess(ctx.runtime, global, current);
    frame.this_value = boxed;
    return boxed;
}

pub fn generatorPrototypeFromGlobal(rt: *core.JSRuntime, global: *core.Object) !*core.Object {
    if (cachedRealmObject(rt, global, .generator_prototype)) |stored| return stored;
    const object = try core.Object.create(rt, core.class.ids.object, iteratorPrototypeFromGlobal(rt, global) orelse objectPrototypeFromGlobal(rt, global));
    var object_raw_owned = true;
    errdefer if (object_raw_owned) core.Object.destroyFromHeader(rt, object.gcHeader());
    try installGeneratorPrototypeProperties(rt, global, object);
    const value = object.value();
    object_raw_owned = false;
    try storeRealmValue(rt, global, .generator_prototype, value);
    return object;
}

pub fn installGeneratorPrototypeProperties(rt: *core.JSRuntime, global: *core.Object, object: *core.Object) !void {
    const IntrinsicMethod = method_ids.iterator.IntrinsicMethod;
    const next_atom = core.atom.ids.next;
    const next = try core.function.nativeFunctionForGlobal(rt, global, "next", 1);
    const next_object = try property_ops.expectObject(next);
    next_object.setNativeBuiltinIdAndRecord(core.function.nativeBuiltinId(.iterator, @intFromEnum(IntrinsicMethod.generator_next)));
    try next_object.addGeneratorNextFunction(rt);
    try object.defineOwnProperty(rt, next_atom, core.Descriptor.data(next, .method));
    try builtin_glue.defineNativeDataMethodWithNativeId(rt, global, object, core.atom.ids.return_, 1, core.function.nativeBuiltinId(.iterator, @intFromEnum(IntrinsicMethod.generator_return)));
    try builtin_glue.defineNativeDataMethodWithNativeId(rt, global, object, core.atom.ids.throw, 1, core.function.nativeBuiltinId(.iterator, @intFromEnum(IntrinsicMethod.generator_throw)));

    const tag_atom = comptime core.atom.predefinedId("Symbol.toStringTag", .symbol).?;
    const tag = try value_ops.createStringValue(rt, "Generator");
    try object.defineOwnProperty(rt, tag_atom, core.Descriptor.data(tag, .{ .configurable = true }));
}

const GeneratorFunctionFamily = struct {
    name: []const u8,
    constructor_kind: core.host_function.NativeConstructorKind,
    prototype_slot: core.object.RealmValueSlot,
    constructor_slot: core.object.RealmValueSlot,
};

/// %GeneratorFunction.prototype% or %AsyncGeneratorFunction.prototype% and
/// its constructor, created on first use. `instancePrototypeFromGlobal`
/// returns the family's generator prototype, which becomes its `prototype`.
fn generatorFunctionFamilyPrototype(
    rt: *core.JSRuntime,
    global: *core.Object,
    comptime family: GeneratorFunctionFamily,
    comptime instancePrototypeFromGlobal: anytype,
) !*core.Object {
    if (cachedRealmObject(rt, global, family.prototype_slot)) |stored| return stored;
    const object = try core.Object.create(rt, core.class.ids.object, functionPrototypeFromGlobal(global));
    const object_value = object.value();
    const constructor = try core.function.nativeFunctionForGlobal(rt, global, family.name, 1);
    const constructor_object = try property_ops.expectObject(constructor);
    constructor_object.setNativeConstructorKind(family.constructor_kind);
    try constructor_object.setFunctionRealmGlobalPtr(rt, global);
    if (functionConstructorFromGlobal(rt, global)) |function_constructor| try constructor_object.setPrototype(rt, function_constructor);
    try constructor_object.defineOwnProperty(rt, core.atom.ids.prototype, core.Descriptor.data(object_value, .none));
    try object.defineOwnProperty(rt, core.atom.ids.constructor, core.Descriptor.data(constructor_object.value(), .{ .configurable = true }));
    try storeRealmValue(rt, global, family.constructor_slot, constructor_object.value());
    const instance_prototype = try instancePrototypeFromGlobal(rt, global);
    try object.defineOwnProperty(rt, core.atom.ids.prototype, core.Descriptor.data(instance_prototype.value(), .{ .configurable = true }));
    try instance_prototype.defineOwnProperty(rt, core.atom.ids.constructor, core.Descriptor.data(object_value, .{ .configurable = true }));
    try defineToStringTag(rt, object, family.name);
    try storeRealmValue(rt, global, family.prototype_slot, object_value);
    return object;
}

pub fn generatorFunctionPrototypeFromGlobal(rt: *core.JSRuntime, global: *core.Object) !*core.Object {
    return generatorFunctionFamilyPrototype(rt, global, .{
        .name = "GeneratorFunction",
        .constructor_kind = .generator_function,
        .prototype_slot = .generator_function_prototype,
        .constructor_slot = .generator_function_constructor,
    }, generatorPrototypeFromGlobal);
}

pub fn asyncGeneratorFunctionPrototypeFromGlobal(rt: *core.JSRuntime, global: *core.Object) !*core.Object {
    return generatorFunctionFamilyPrototype(rt, global, .{
        .name = "AsyncGeneratorFunction",
        .constructor_kind = .async_generator_function,
        .prototype_slot = .async_generator_function_prototype,
        .constructor_slot = .async_generator_function_constructor,
    }, promise_ops.asyncGeneratorPrototypeFromGlobal);
}

fn bytecodeFunctionClassId(fb: *const bytecode.FunctionBytecode) core.ClassId {
    return switch (fb.functionKind()) {
        .normal => core.class.ids.bytecode_function,
        .generator => core.class.ids.generator_function,
        .async => core.class.ids.async_function,
        .async_generator => core.class.ids.async_generator_function,
    };
}

/// Allocate the unpublished object shell for a canonical module root.
/// The caller still owns `fb`; attaching that exact owner and constructing the
/// nullable MODULE_DECL/MODULE_IMPORT capture table are module-linker steps.
pub fn createModuleBytecodeFunctionShell(
    ctx: *core.JSContext,
    fb: *const bytecode.FunctionBytecode,
) !*core.Object {
    if (!fb.isModule()) return error.InvalidBytecode;
    const realm = fb.realmContext() orelse return error.InvalidBytecode;
    if (realm != ctx) return error.InvalidBytecode;
    // A bare Realm may reach module linking before any script/global lookup.
    // Materialize its standard global before resolving the root function's
    // intrinsic prototype, just as ordinary root closure construction does.
    _ = try zjs_vm.contextGlobal(ctx);
    const class_id = bytecodeFunctionClassId(fb);
    const prototype = try bytecodeFunctionPrototypeForRealm(
        ctx,
        realm,
        class_id,
        fb.functionKind(),
    );
    return core.Object.create(ctx.runtime, class_id, prototype);
}

/// Resolve the immutable intrinsic prototype from the FunctionBytecode's own
/// realm before allocating the closure object. The three non-ordinary
/// function prototypes are lazily built by zjs; once built, publish them in
/// the same RealmContext class-prototype table used by constructor fallback.
fn bytecodeFunctionPrototypeForRealm(
    ctx: *core.JSContext,
    realm: *core.JSContext,
    class_id: core.ClassId,
    kind: bytecode.function_bytecode.FunctionKind,
) !*core.Object {
    if (realm.classPrototypeObject(class_id)) |prototype| return prototype;
    const global = realm.global orelse return error.InvalidBuiltinRegistry;
    const prototype = switch (kind) {
        .normal => functionPrototypeFromGlobal(global) orelse return error.InvalidBuiltinRegistry,
        .generator => try generatorFunctionPrototypeFromGlobal(ctx.runtime, global),
        .async => try asyncFunctionPrototypeFromGlobal(ctx.runtime, global),
        .async_generator => try asyncGeneratorFunctionPrototypeFromGlobal(ctx.runtime, global),
    };
    try realm.setClassPrototype(class_id, prototype);
    return prototype;
}

pub const ClosureCellResolver = struct {
    context: ?*anyopaque = null,
    resolve: *const fn (
        context: ?*anyopaque,
        ctx: *core.JSContext,
        global: *core.Object,
        fb: *const bytecode.FunctionBytecode,
        index: usize,
        cv: bytecode.function_bytecode.BytecodeClosureVar,
    ) HostError!*core.VarRef,
};

pub const ClosureCaptureSource = union(enum) {
    nested_frame: *frame_mod.Frame,
    root_global,
    custom: ClosureCellResolver,
};

/// The closure cell a value must be; anything else is malformed bytecode.
pub fn closureCellFromValue(value: core.JSValue) !*core.VarRef {
    return core.VarRef.fromValue(value) orelse error.InvalidBytecode;
}

/// Construct one root GLOBAL/GLOBAL_DECL cell exactly where qjs closure2 pass
/// 2 does. GLOBAL_DECL metadata is applied by the declaration owner helpers;
/// ordinary GLOBAL/GLOBAL_REF rows remain pure aliases selected by the shared
/// waterfall.
pub fn createRootGlobalClosureCell(
    ctx: *core.JSContext,
    global: *core.Object,
    fb: *const bytecode.FunctionBytecode,
    cv: bytecode.function_bytecode.BytecodeClosureVar,
) !*core.VarRef {
    switch (cv.closureType()) {
        .global, .global_ref => return closureCellFromValue(try call_runtime.selectOrdinaryGlobalClosureCell(ctx, global, cv.var_name)),
        .global_decl => {},
        else => return error.InvalidBytecode,
    }

    const cell_value = if (cv.isLexical())
        try call_runtime.ensureGlobalLexicalCell(ctx, global, cv.var_name, cv.isConst())
    else
        (try call_runtime.ensureGlobalObjectVarRefCell(
            ctx,
            global,
            cv.var_name,
            fb.isDirectOrIndirectEval(),
            cv.varKind() == .global_function_decl,
        )) orelse try call_runtime.selectOrdinaryGlobalClosureCell(ctx, global, cv.var_name);
    return closureCellFromValue(cell_value);
}

/// One qjs js_closure2 closure-type arm (qjs:17297-17331). This is only the
/// tagged dispatch around the real capture/global helpers, so keep it inside
/// the capture loop rather than materializing another call-chain level.
inline fn resolveNestedClosureCell(
    ctx: *core.JSContext,
    frame: *frame_mod.Frame,
    global: *core.Object,
    cv: bytecode.function_bytecode.BytecodeClosureVar,
) !*core.VarRef {
    return switch (cv.closureType()) {
        // qjs js_closure2 LOCAL/ARG/REF/GLOBAL_REF:
        // direct `get_var_ref` / `cur_var_refs[idx]` with `ref_count++`. No
        // production bounds return — finalize sized the windows.
        .local => try frame.captureLocal(ctx.runtime, cv.var_idx),
        .arg => try frame.captureArg(ctx.runtime, cv.var_idx),
        .ref, .global_ref => blk: {
            std.debug.assert(cv.var_idx < frame.var_refs.len);
            break :blk frame.var_refs[cv.var_idx];
        },
        // qjs js_closure_global_var: the capture waterfall for a
        // global reference is [global_var_obj lexical VARREF] -> [global_obj VARREF
        // property] -> [shared uninitialized_vars side-table cell], REGARDLESS of the
        // closure var's own lexical bit — a plain reference captures a pre-existing
        // global lexical's cell directly, and an undeclared name shares the parked cell
        // that a later declaration (js_closure_define_global_var) will reuse. The shared
        // table cell carries no per-capture flags; is_lexical/is_const are stamped only
        // at definition time (add_var_ref, 17210-17223).
        .global, .global_decl => try closureCellFromValue(try call_runtime.selectOrdinaryGlobalClosureCell(ctx, global, cv.var_name)),
        .module_decl, .module_import => blk: {
            try ensureVarRefsCapacity(ctx, frame, cv.var_idx);
            break :blk frame.var_refs[cv.var_idx];
        },
    };
}

/// Shared js_closure2 core (qjs:17262-17331) for nested and ordinary root
/// functions. One `js_mallocz` of the capture array is attached to the
/// already-bytecode-backed object *before* the fill loop (qjs:17276-17280),
/// so the object is the sole GC root — no sidecar allocation, no per-slot
/// `initialized` counter, no post-loop `setFunctionCaptures` transfer.
/// Fail is `JS_FreeValue(func_obj)`: the caller's object `errdefer` walks
/// the partial array through `free_var_ref`, which skips remaining nulls.
fn attachFunctionCaptures(
    ctx: *core.JSContext,
    global: *core.Object,
    fb: *const bytecode.FunctionBytecode,
    object: *core.Object,
    source: ClosureCaptureSource,
) HostError!void {
    const closure_vars = fb.closureVar();
    if (closure_vars.len == 0) return;

    try object.allocateNullCaptureSlots(ctx.runtime, closure_vars.len);
    const slots = object.mutableCaptureSlots();

    // qjs js_closure2 has one capture source (`sf`/`cur_var_refs`) and switches
    // only on closure_type inside the loop (qjs:17297-17331). Root construction
    // needs two additional zjs sources, but their tag is closure-wide: select it
    // once instead of re-testing the same union for every capture.
    switch (source) {
        .nested_frame => |frame| for (closure_vars, 0..) |cv, idx| {
            slots[idx] = try resolveNestedClosureCell(ctx, frame, global, cv);
        },
        .root_global => {
            try vm_property.validateGlobalVarDeclarations(ctx, global, fb);
            for (closure_vars, 0..) |cv, idx| {
                slots[idx] = try createRootGlobalClosureCell(ctx, global, fb, cv);
            }
        },
        .custom => |resolver| {
            try vm_property.validateGlobalVarDeclarations(ctx, global, fb);
            for (closure_vars, 0..) |cv, idx| {
                slots[idx] = try resolver.resolve(resolver.context, ctx, global, fb, idx, cv);
            }
        },
    }
    // The resolvers allocate, so a minor inside the fill can promote `object`
    // and retire the remembrance taken when the slots were attached; the
    // cells stored after it would be unremembered young children.
    ctx.runtime.gc.rememberOwnerForBulkWrite(object.gcHeader());
}

fn createBytecodeFunctionObjectInternal(
    ctx: *core.JSContext,
    global: *core.Object,
    value: core.JSValue,
    name_fallback: core.Atom,
    capture_source: ClosureCaptureSource,
) HostError!core.JSValue {
    var rooted_value = value;
    if (!rooted_value.is(.function_bytecode)) return error.InvalidBytecode;
    var root_frame = core.runtime.rootValues(.{&rooted_value});
    root_frame.activate(ctx.runtime);
    defer root_frame.deactivate(ctx.runtime);

    const fb = functionBytecodeFromValue(rooted_value) orelse return error.InvalidBytecode;
    // qjs `js_closure` does not re-validate the
    // finalized bytecode or Realm identity: `JS_VALUE_GET_PTR` +
    // `JS_NewObjectClass(func_kind_to_class_id[b->func_kind])`. Finalize
    // already published the extension and bound the Realm; Debug/Safe still
    // assert so a fixture cannot silently enter the production object.
    std.debug.assert(fb.hasExtension() and fb.byte_code != null and fb.byte_code_len > 0);
    const realm = fb.realmContext().?;
    std.debug.assert(realm == ctx and realm.global == global and ctx.global == global);
    const class_id = bytecodeFunctionClassId(fb);
    const function_prototype = try bytecodeFunctionPrototypeForRealm(ctx, realm, class_id, fb.functionKind());
    // length + name (+ lazy prototype later). qjs NewObjectClass then
    // js_function_set_properties.
    const object = try core.Object.createWithOwnPropertyCapacity(ctx.runtime, class_id, function_prototype, 3);
    errdefer core.Object.destroyFromHeader(ctx.runtime, object.gcHeader());
    // Pool.get/fclosure hands this constructor an owned FunctionBytecode
    // value. Move that exact reference into the object; attachment performs no
    // allocation and consumes it even when validation fails.
    const owned_bytecode = rooted_value;
    rooted_value = core.JSValue.undefinedValue();
    try object.setFunctionBytecodeValue(ctx.runtime, owned_bytecode);
    try attachFunctionCaptures(ctx, global, fb, object, capture_source);

    // qjs js_closure (17388-17392): `name_atom = b->func_name;` then
    // `if (name_atom == JS_ATOM_NULL) name_atom = JS_ATOM_empty_string;` —
    // no atom-table `kind()` probe on the create hot path.
    const effective_name = if (fb.func_name != core.atom.ids.empty_string)
        fb.func_name
    else
        name_fallback;
    try jsFunctionSetProperties(ctx.runtime, object, effective_name, fb.defined_arg_count);

    return object.value();
}

/// qjs `js_function_set_properties`:
/// `JS_DefinePropertyValue(length, NewInt32, CONFIGURABLE)` then
/// `JS_DefinePropertyValue(name, JS_AtomToString, CONFIGURABLE)`.
/// Fresh bytecode function — CreateProperty miss → add_property, no
/// Descriptor round-trip and no objectHasNonEmptyName probe.
fn jsFunctionSetProperties(
    rt: *core.JSRuntime,
    object: *core.Object,
    name_atom: core.Atom,
    length: i32,
) HostError!void {
    const configurable = comptime core.property.Flags.data(.{ .configurable = true });
    try object.defineOwnDataValueAssumingNew(
        rt,
        core.atom.ids.length,
        core.JSValue.int32(length),
        configurable,
    );
    // qjs JS_AtomToString: dup the atom's string body. Prefix / public-Symbol
    // composition is JS_DefineObjectName, not this helper.
    const name_value = try rt.atoms.toStringValueForPush(rt, name_atom);
    try object.defineOwnDataValueAssumingNew(
        rt,
        core.atom.ids.name,
        name_value,
        configurable,
    );
}

/// qjs `js_closure` installs the generic function prototype policy. Class
/// constructors bypass this helper: OP_define_class creates their prototype
/// and constructor backlink explicitly.
fn installOrdinaryFunctionPrototype(
    ctx: *core.JSContext,
    global: *core.Object,
    value: core.JSValue,
) HostError!void {
    const object = try property_ops.expectObject(value);
    const function_value = object.functionBytecode() orelse return error.InvalidBytecode;
    const fb = functionBytecodeFromValue(function_value) orelse return error.InvalidBytecode;
    if (!fb.hasPrototype()) return;

    if (fb.functionKind() == .normal) {
        // qjs-faithful lazy `prototype` (JS_AUTOINIT_ID_PROTOTYPE): install a
        // placeholder; the prototype object + its `constructor` back-ref are
        // materialized only when `.prototype` is first observed or the
        // function is constructed.
        // qjs js_closure (17312-17415): JS_SetConstructorBit then
        // JS_DefineAutoInitProperty(PROTOTYPE, WRITABLE) with the creating
        // ctx. zjs constructability is FB hasPrototype∧normal (no object
        // bit); the autoinit install still dups that same ctx as realm.
        try object.defineFunctionPrototypeAutoInit(
            ctx.runtime,
            ctx,
            comptime core.property.Flags.data(.{ .writable = true }),
        );
        return;
    }

    const generator_prototype = if (fb.functionKind() == .async_generator)
        try asyncGeneratorPrototypeFromGlobal(ctx.runtime, global)
    else if (fb.functionKind() == .generator)
        try generatorPrototypeFromGlobal(ctx.runtime, global)
    else
        objectPrototypeFromGlobal(ctx.runtime, global);
    const prototype = try core.Object.create(ctx.runtime, core.class.ids.object, generator_prototype);
    try object.defineOwnProperty(ctx.runtime, core.atom.ids.prototype, core.Descriptor.data(prototype.value(), .{ .writable = true }));
}

pub fn createBytecodeFunctionObject(
    ctx: *core.JSContext,
    frame: *frame_mod.Frame,
    global: *core.Object,
    value: core.JSValue,
) HostError!core.JSValue {
    const object_value = try createBytecodeFunctionObjectInternal(
        ctx,
        global,
        value,
        core.atom.ids.empty_string,
        .{ .nested_frame = frame },
    );
    try installOrdinaryFunctionPrototype(ctx, global, object_value);
    return object_value;
}

fn createClassBytecodeFunctionObject(
    ctx: *core.JSContext,
    frame: *frame_mod.Frame,
    global: *core.Object,
    value: core.JSValue,
    class_name: core.Atom,
) HostError!core.JSValue {
    return createBytecodeFunctionObjectInternal(
        ctx,
        global,
        value,
        class_name,
        .{ .nested_frame = frame },
    );
}

/// Consume the canonical root FB and create the real script/eval function
/// object. The returned object is the root frame's own `current_function`.
pub fn createRootBytecodeFunctionObject(
    ctx: *core.JSContext,
    global: *core.Object,
    value: core.JSValue,
    capture_source: ClosureCaptureSource,
) HostError!core.JSValue {
    switch (capture_source) {
        .nested_frame => return error.InvalidBytecode,
        .root_global, .custom => {},
    }
    const object_value = try createBytecodeFunctionObjectInternal(
        ctx,
        global,
        value,
        core.atom.ids.empty_string,
        capture_source,
    );
    try installOrdinaryFunctionPrototype(ctx, global, object_value);
    return object_value;
}

pub fn constructPrimitiveWrapperWithPrototype(
    rt: *core.JSRuntime,
    class_id: core.class.ClassId,
    prototype: ?*core.Object,
    primitive: core.JSValue,
) !core.JSValue {
    var rooted_primitive = primitive;
    var root_frame = core.runtime.rootValues(.{&rooted_primitive});
    root_frame.activate(rt);
    defer root_frame.deactivate(rt);

    const object = try core.Object.create(rt, class_id, prototype);
    errdefer core.Object.destroyFromHeader(rt, object.gcHeader());
    try object.setOptionalValueSlot(rt, object.objectDataSlot(), rooted_primitive);
    return object.value();
}

test "constructPrimitiveWrapperWithPrototype roots direct symbol while creating wrapper" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const symbol_atom = try rt.atoms.newValueSymbol("gc-construct-primitive-wrapper-symbol");
    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const symbol_value = try rt.symbolValue(symbol_atom);
    const wrapper_value = try constructPrimitiveWrapperWithPrototype(rt, core.class.ids.symbol, null, symbol_value);
    const wrapper = objectFromValue(wrapper_value) orelse return error.TypeError;

    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    const stored = wrapper.objectDataSlot().* orelse return error.TypeError;
    try std.testing.expect(stored.same(symbol_value));

    _ = try rt.collectForTest();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

/// Create an Error-class instance with the `message` and `cause` that every
/// Error constructor installs (InstallErrorCause). The caller keeps
/// `message` and `options` rooted.
fn createErrorWithMessageAndCause(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    prototype: ?*core.Object,
    message: core.JSValue,
    options: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !*core.Object {
    const rt = ctx.runtime;
    const instance = try core.Object.create(rt, core.class.ids.error_, prototype);

    // No own `name` property: it lives on the per-class prototype only, so
    // patching `X.prototype.name` reflects on existing instances and a
    // new.target-derived prototype supplies its own name.
    if (!message.is(.undefined_value)) {
        const message_string = try toStringForAnnexB(ctx, output, global, message, caller_function, caller_frame);
        try instance.defineOwnProperty(rt, core.atom.ids.message, core.Descriptor.data(message_string, .method));
    }

    if (options.is(.object)) {
        const cause_key = core.atom.ids.cause;
        if (try hasValueProperty(ctx, output, global, try property_ops.expectObject(options), cause_key, caller_function, caller_frame)) {
            var cause = try getValueProperty(ctx, output, global, options, cause_key, caller_function, caller_frame);
            var root_values = [_]*core.JSValue{&cause};
            var root_frame = core.runtime.ValueRootFrame{ .values = &root_values };
            root_frame.activate(rt);
            defer root_frame.deactivate(rt);
            try instance.defineOwnProperty(rt, core.atom.ids.cause, core.Descriptor.data(cause, .method));
        }
    }
    return instance;
}

fn argOrUndefined(args: []const core.JSValue, index: usize) core.JSValue {
    return if (index < args.len) args[index] else core.JSValue.undefinedValue();
}

pub fn aggregateErrorConstructWithPrototype(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    prototype: ?*core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const rt = ctx.runtime;
    var rooted_args_buffer = try core.runtime.ValueRootBuffer.initCopy(rt, args);
    defer rooted_args_buffer.deinit();
    const rooted_args = rooted_args_buffer.values();

    const instance = try createErrorWithMessageAndCause(ctx, output, global, prototype, argOrUndefined(rooted_args, 1), argOrUndefined(rooted_args, 2), caller_function, caller_frame);
    const errors_array = try aggregateErrorsIterableToArray(ctx, output, global, argOrUndefined(rooted_args, 0), caller_function, caller_frame);
    try instance.defineOwnProperty(rt, core.atom.ids.errors, core.Descriptor.data(errors_array.value(), .method));

    try captureErrorStack(ctx, global, instance);
    return instance.value();
}

test "aggregateErrorConstructWithPrototype preserves direct symbol errors and cause" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();
    const global = try zjs_vm.contextGlobal(ctx);

    const errors_source = try core.Object.createArray(rt, arrayPrototypeFromGlobal(rt, global));
    const options = try core.Object.create(rt, core.class.ids.object, objectPrototypeFromGlobal(rt, global));

    const error_value = try rt.newSymbolValue("gc-aggregate-error-item-symbol");
    const error_atom = error_value.asSymbolAtom().?;
    const cause_value = try rt.newSymbolValue("gc-aggregate-error-cause-symbol");
    const cause_atom = cause_value.asSymbolAtom().?;
    try errors_source.defineOwnProperty(rt, core.Atom.taggedInt(0), core.Descriptor.data(error_value, .all));
    errors_source.setArrayLength(1);
    try errors_source.defineOwnProperty(rt, core.atom.ids.length, core.Descriptor.data(core.JSValue.int32(1), .{ .writable = true }));
    try options.defineOwnProperty(rt, core.atom.ids.cause, core.Descriptor.data(cause_value, .method));

    const args = [_]core.JSValue{
        errors_source.value(),
        core.JSValue.undefinedValue(),
        options.value(),
    };
    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);
    ctx.runtime.execution.beginErrorStackFormatting();
    defer ctx.runtime.execution.endErrorStackFormatting();

    const aggregate_value = try aggregateErrorConstructWithPrototype(ctx, null, global, null, &args, null, null);
    const aggregate = objectFromValue(aggregate_value) orelse return error.TypeError;

    try std.testing.expect(rt.atoms.name(error_atom) != null);
    try std.testing.expect(rt.atoms.name(cause_atom) != null);
    const errors_key = try rt.internAtom("errors");
    const cause_key = try rt.internAtom("cause");
    {
        const stored_errors_value = try aggregate.getProperty(errors_key);
        const stored_errors = objectFromValue(stored_errors_value) orelse return error.TypeError;
        const stored_error = try stored_errors.getProperty(core.Atom.taggedInt(0));
        try std.testing.expect(stored_error.same(error_value));

        const stored_cause = try aggregate.getProperty(cause_key);
        try std.testing.expect(stored_cause.same(cause_value));
    }

    _ = try rt.collectForTest();
    try std.testing.expect(rt.atoms.name(error_atom) == null);
    try std.testing.expect(rt.atoms.name(cause_atom) == null);
}

pub fn suppressedErrorConstructWithPrototype(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    prototype: ?*core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const rt = ctx.runtime;
    var rooted_args_buffer = try core.runtime.ValueRootBuffer.initCopy(rt, args);
    defer rooted_args_buffer.deinit();
    const rooted_args = rooted_args_buffer.values();

    const instance = try core.Object.create(rt, core.class.ids.error_, prototype);
    const instance_value = instance.value();

    const message_arg = argOrUndefined(rooted_args, 2);
    if (!message_arg.is(.undefined_value)) {
        const message = try toStringForAnnexB(ctx, output, global, message_arg, caller_function, caller_frame);
        try instance.defineOwnProperty(rt, core.atom.ids.message, core.Descriptor.data(message, .method));
    }

    const error_value = argOrUndefined(rooted_args, 0);
    try instance.defineOwnProperty(rt, core.atom.ids.error_, core.Descriptor.data(error_value, .method));

    const suppressed_value = argOrUndefined(rooted_args, 1);
    try instance.defineOwnProperty(rt, core.atom.ids.suppressed, core.Descriptor.data(suppressed_value, .method));

    try captureErrorStack(ctx, global, instance);

    return instance_value;
}

test "suppressedErrorConstructWithPrototype roots direct symbol args while creating error" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();
    const global = try core.Object.create(rt, core.class.ids.object, null);

    const error_atom = try rt.atoms.newValueSymbol("gc-suppressed-error-value-symbol");
    const error_arg = try rt.symbolValue(error_atom);
    const suppressed_atom = try rt.atoms.newValueSymbol("gc-suppressed-error-suppressed-symbol");
    const suppressed_arg = try rt.symbolValue(suppressed_atom);
    const args = [_]core.JSValue{
        error_arg,
        suppressed_arg,
    };

    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const error_value = try suppressedErrorConstructWithPrototype(ctx, null, global, null, &args, null, null);
    const object = objectFromValue(error_value) orelse return error.TypeError;

    try std.testing.expect(rt.atoms.name(error_atom) != null);
    try std.testing.expect(rt.atoms.name(suppressed_atom) != null);
    const error_key = try rt.internAtom("error");
    const suppressed_key = try rt.internAtom("suppressed");
    {
        const stored_error = try object.getProperty(error_key);
        const stored_suppressed = try object.getProperty(suppressed_key);
        try std.testing.expect(stored_error.same(error_arg));
        try std.testing.expect(stored_suppressed.same(suppressed_arg));
    }

    _ = try rt.collectForTest();
    try std.testing.expect(rt.atoms.name(error_atom) == null);
    try std.testing.expect(rt.atoms.name(suppressed_atom) == null);
}

pub fn disposableStackConstructWithPrototype(
    ctx: *core.JSContext,
    prototype: ?*core.Object,
) !core.JSValue {
    const stack = try core.Object.create(ctx.runtime, core.class.ids.disposable_stack, prototype);
    errdefer core.Object.destroyFromHeader(ctx.runtime, stack.gcHeader());
    return stack.value();
}
pub fn errorConstructWithPrototype(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    prototype: ?*core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    var rooted_args_buffer = try core.runtime.ValueRootBuffer.initCopy(ctx.runtime, args);
    defer rooted_args_buffer.deinit();
    const rooted_args = rooted_args_buffer.values();

    const instance = try createErrorWithMessageAndCause(ctx, output, global, prototype, argOrUndefined(rooted_args, 0), argOrUndefined(rooted_args, 1), caller_function, caller_frame);
    try captureErrorStack(ctx, global, instance);
    return instance.value();
}

test "errorConstructWithPrototype preserves direct symbol cause" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();
    const global = try zjs_vm.contextGlobal(ctx);

    const options = try core.Object.create(rt, core.class.ids.object, objectPrototypeFromGlobal(rt, global));

    const cause_atom = try rt.atoms.newValueSymbol("gc-error-cause-symbol");
    const cause_value = try rt.symbolValue(cause_atom);
    try options.defineOwnProperty(rt, core.atom.ids.cause, core.Descriptor.data(cause_value, .method));
    const args = [_]core.JSValue{
        core.JSValue.undefinedValue(),
        options.value(),
    };
    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);
    ctx.runtime.execution.beginErrorStackFormatting();
    defer ctx.runtime.execution.endErrorStackFormatting();

    const error_value = try errorConstructWithPrototype(ctx, null, global, null, &args, null, null);
    const object = objectFromValue(error_value) orelse return error.TypeError;

    try std.testing.expect(rt.atoms.name(cause_atom) != null);
    const cause_key = try rt.internAtom("cause");
    {
        const stored_cause = try object.getProperty(cause_key);
        try std.testing.expect(stored_cause.same(cause_value));
    }

    _ = try rt.collectForTest();
    try std.testing.expect(rt.atoms.name(cause_atom) == null);
}

pub fn createCallSiteObject(ctx: *core.JSContext, global: *core.Object, entry: core.BacktraceFrame) !core.JSValue {
    const object = try core.Object.create(ctx.runtime, core.class.ids.object, try callSitePrototypeFromGlobal(ctx.runtime, global));
    errdefer core.Object.destroyFromHeader(ctx.runtime, object.gcHeader());
    const location = entry.location();
    const filename = if (entry.is_native)
        core.JSValue.nullValue()
    else
        try value_ops.createStringValueLossy(ctx.runtime, ctx.runtime.atoms.name(entry.filename) orelse "<anonymous>");
    const function_name_value = try callSiteFunctionNameValue(ctx, entry);
    try object.setCallSiteMetadata(
        ctx.runtime,
        filename,
        function_name_value,
        if (entry.is_native) 0 else if (location.line_num > 0) location.line_num else 1,
        if (entry.is_native) 0 else if (location.col_num > 0) location.col_num else 1,
        entry.is_native,
    );

    return object.value();
}

pub fn callSitePrototypeFromGlobal(rt: *core.JSRuntime, global: *core.Object) !*core.Object {
    if (cachedRealmObject(rt, global, .callsite_prototype)) |stored| return stored;
    var values = [_]core.JSValue{core.JSValue.undefinedValue()};
    var slots: []core.JSValue = &values;
    const globals = [_]core.JSValue{global.value()};
    const slices = [_]core.runtime.ValueRootSlice{ .{ .mutable = &slots }, .{ .borrowed = &globals } };
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(rt);
    defer roots.deactivate(rt);
    // Keep the unpublished prototype alive in non-test builds too. On error,
    // GC reclaims the partial object after this scope leaves the root chain.
    values[0] = (try core.Object.create(rt, core.class.ids.object, objectPrototypeFromGlobal(rt, global))).value();

    const methods = [_]struct { name: []const u8, id: core.function.EngineHelperMethod }{
        .{ .name = "getFunction", .id = .callsite_get_function },
        .{ .name = "getFunctionName", .id = .callsite_get_function_name },
        .{ .name = "getFileName", .id = .callsite_get_file_name },
        .{ .name = "getLineNumber", .id = .callsite_get_line_number },
        .{ .name = "getColumnNumber", .id = .callsite_get_column_number },
        .{ .name = "isNative", .id = .callsite_is_native },
    };
    for (methods) |method| {
        try builtin_glue.defineNativeDataMethodNamedWithNativeId(rt, global, objectFromValue(values[0]).?, method.name, 0, core.function.nativeBuiltinId(.engine_helper, @intFromEnum(method.id)));
    }
    try defineToStringTag(rt, objectFromValue(values[0]).?, "CallSite");

    try storeRealmValue(rt, global, .callsite_prototype, values[0]);
    return objectFromValue(values[0]).?;
}

const regexp_exec_atom = core.atom.predefinedId("exec", .string).?;

/// The RegExp.prototype property `atom_id` that `object` (a genuine RegExp
/// without an own `atom_id`) inherits, found by a side-effect-free shape probe
/// (qjs find_property_regexp).
fn regExpInheritedProperty(object: *core.Object, atom_id: core.Atom) ?struct { holder: *core.Object, index: usize } {
    if (object.class_id != core.class.ids.regexp) return null;
    if (object.hasOwnProperty(atom_id)) return null;
    const proto = object.getPrototype() orelse return null;
    if (proto.hasExoticMethods()) return null;
    const index = proto.findProperty(atom_id) orelse return null;
    return .{ .holder = proto, .index = index };
}

/// `object.exec` is the built-in RegExp.prototype.exec (qjs js_is_standard_regexp).
pub fn regExpExecIsDefault(object: *core.Object) bool {
    const found = regExpInheritedProperty(object, regexp_exec_atom) orelse return false;
    const entry = found.holder.propertyEntry(found.index).*;
    const expected_id = @intFromEnum(method_ids.regexp.PrototypeMethod.exec);
    return switch (found.holder.propKindAt(found.index)) {
        .data => regExpNativeBuiltinMatches(entry.slot.data, expected_id),
        .auto_init => regExpAutoInitBuiltinMatches(core.property.autoInit(entry.slot.auto_init).*, expected_id),
        .var_ref, .accessor => false,
    };
}

/// A RegExp flag getter resolves to the built-in accessor (qjs
/// check_regexp_getter). It NEVER invokes the getter, so probing has no
/// observable effect; an overridden getter sends callers to the generic path.
fn regExpGetterIsDefault(object: *core.Object, comptime getter: method_ids.regexp.AccessorMethod) bool {
    const atom_id = comptime core.atom.predefinedId(@tagName(getter), .string).?;
    const found = regExpInheritedProperty(object, atom_id) orelse return false;
    return switch (found.holder.propKindAt(found.index)) {
        .accessor => regExpNativeBuiltinMatches(found.holder.propertyEntry(found.index).*.slot.accessor.getterValue(), @intFromEnum(getter)),
        .auto_init, .data, .var_ref => false,
    };
}

/// Side-effect-free `js_is_standard_regexp` (quickjs.c): the receiver is a
/// genuine RegExp whose `lastIndex` is a plain number and whose `exec` method
/// and `flags`/`global`/`unicode` getters are all the pristine built-ins. Only
/// then may a fast path read flags straight from the compiled bytecode and skip
/// the observable property reads the spec otherwise mandates.
pub fn regExpIsStandard(object: *core.Object) bool {
    if (object.class_id != core.class.ids.regexp) return false;
    // QuickJS `js_is_standard_regexp` requires `JS_IsNumber(lastIndex)`: a
    // non-number lastIndex (string "1", {}, ...) must take the generic path so
    // ToLength coercion is observed (sticky/global use lastIndex directly).
    const last_index = object.regexpLastIndex() orelse return false;
    if (!last_index.isNumber()) return false;
    return regExpExecIsDefault(object) and
        regExpGetterIsDefault(object, .flags) and
        regExpGetterIsDefault(object, .global) and
        regExpGetterIsDefault(object, .unicode);
}

/// Set(O, P, V, true) (§7.3.4) on an object.
pub fn setValuePropertyStrict(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    object_value: core.JSValue,
    atom_id: core.Atom,
    value: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !void {
    _ = try property_ops.expectObject(object_value);
    _ = try setValuePropertyWithThrow(ctx, output, global, object_value, atom_id, value, caller_function, caller_frame, true);
}

/// The realm's `RegExp.prototype` (borrowed), or null when `RegExp` is not an
/// object with a data `prototype`.
pub fn regExpPrototypeFromGlobal(rt: *core.JSRuntime, global: *core.Object) !?*core.Object {
    const constructor_value = regExpConstructorFromGlobal(rt, global) catch |err| switch (err) {
        error.TypeError => return null,
        else => return err,
    };
    const constructor = objectFromValue(constructor_value) orelse return null;
    return constructor.getOwnDataObjectBorrowed(core.atom.ids.prototype);
}

pub fn datePrototypeMethod(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    method: core.host_function.builtin_method_ids.date.PrototypeMethod,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    switch (method) {
        .to_json => return date_ops.dateToJsonCall(ctx, output, global, this_value, caller_function, caller_frame),
        .set_year => if (try date_ops.dateSetYear(ctx, output, global, this_value, args)) |value| return value,
        .set_time => if (try date_ops.dateSetTime(ctx, output, global, this_value, args)) |value| return value,
        else => {},
    }
    if (try date_ops.dateCapturedSetterCall(ctx, output, global, this_value, method, args)) |value| return value;
    // Remaining (non-special-cased) prototype methods run the plain
    // `methodCallArgs` body, which lives in `exec/date_ops.zig`. Route it
    // through the record table's func-object-free arm so exec carries no
    // compile-time Date body knowledge. The arm dispatches the body directly,
    // so this does not re-enter the dispatcher.
    const native_ref = core.function.NativeBuiltinRef{ .domain = .date, .id = @intFromEnum(method) };
    const result = builtin_dispatch.callInternalRecord(ctx, output, null, &.{}, null, this_value, native_ref, args, caller_function, caller_frame) catch |err| switch (err) {
        error.TypeError => return throwTypeErrorMessage(ctx, global, "not a Date object"),
        error.RangeError => return throwRangeErrorMessage(ctx, global, "Date value is NaN"),
        else => return err,
    };
    return result orelse throwTypeErrorMessage(ctx, global, "not a Date object");
}

pub fn defineFreshNonIndexDataProperty(rt: *core.JSRuntime, object: *core.Object, atom_id: core.Atom, value: core.JSValue, attrs: core.property.Attrs) !void {
    // Legacy core property writers borrow raw pointers through shape/storage
    // growth. Keep their addresses stable for this call, including in release.
    const values = [_]core.JSValue{ object.value(), value };
    const slices = [_]core.runtime.ValueRootSlice{.{ .borrowed = &values }};
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(rt);
    defer roots.deactivate(rt);
    var atom_roots = core.runtime.rootAtoms(.{&atom_id});
    atom_roots.activate(rt);
    defer atom_roots.deactivate(rt);
    var owner_pin = try core.runtime.NativePin.initHeader(rt, object.gcHeader());
    defer owner_pin.deinit();
    var value_pin = try core.runtime.NativePin.initValue(rt, value);
    defer if (value_pin) |*held| held.deinit();
    try object.defineOwnNonIndexPropertyAssumingNew(rt, atom_id, core.Descriptor.data(value, attrs));
}

pub fn defineRegExpIndicesGroupsProperty(rt: *core.JSRuntime, global: *core.Object, out: *core.Object, found: *const RegExpMatch) !void {
    var values = [_]core.JSValue{ global.value(), out.value(), core.JSValue.undefinedValue(), core.JSValue.undefinedValue() };
    const slots: []core.JSValue = &values;
    const slices = [_]core.runtime.ValueRootSlice{.{ .mutable = &slots }};
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(rt);
    defer roots.deactivate(rt);
    const groups_atom = comptime core.atom.predefinedId("groups", .string).?;
    if (!found.has_named_captures) {
        try defineFreshNonIndexDataProperty(rt, objectFromValue(values[1]).?, groups_atom, core.JSValue.undefinedValue(), .all);
        return;
    }

    values[2] = (try core.Object.create(rt, core.class.ids.object, null)).value();
    var capture_index: usize = 0;
    while (capture_index < found.capture_count) : (capture_index += 1) {
        const name = found.captureNameAt(capture_index) orelse continue;
        const capture = found.captureAt(capture_index);
        var decoded_name = std.ArrayList(u8).empty;
        defer decoded_name.deinit(rt.nativeAllocator());
        try appendDecodedRegExpGroupName(rt, &decoded_name, name);
        const atom = try rt.internAtom(decoded_name.items);
        // TGC S3 §4 class B: bare group-name id held across the property
        // define (and, in the indices form, a fresh pair object).
        var group_atom_roots = core.runtime.rootAtoms(.{&atom});
        group_atom_roots.activate(rt);
        defer group_atom_roots.deactivate(rt);
        // Duplicate named groups share one property; the participating
        // (matched) capture wins, an unset duplicate must not overwrite it.
        if (capture.undefined and objectFromValue(values[2]).?.hasOwnProperty(atom)) continue;
        values[3] = if (capture.undefined)
            core.JSValue.undefinedValue()
        else
            try createRegExpIndexPair(rt, objectFromValue(values[0]).?, capture.start, capture.start + capture.len);
        // The descriptor carries a raw snapshot through the core writer.
        const borrowed = [_]core.JSValue{ values[2], values[3] };
        const borrowed_slices = [_]core.runtime.ValueRootSlice{.{ .borrowed = &borrowed }};
        var write_roots = core.runtime.ValueRootFrame{ .slices = &borrowed_slices };
        write_roots.activate(rt);
        defer write_roots.deactivate(rt);
        var owner_pin = try core.runtime.NativePin.initValue(rt, values[2]);
        defer if (owner_pin) |*held| held.deinit();
        var value_pin = try core.runtime.NativePin.initValue(rt, values[3]);
        defer if (value_pin) |*held| held.deinit();
        try objectFromValue(values[2]).?.defineOwnProperty(rt, atom, core.Descriptor.data(values[3], .all));
    }
    try defineFreshNonIndexDataProperty(rt, objectFromValue(values[1]).?, groups_atom, values[2], .all);
}

// The RegExp result already owns one value for every capture. Reuse those
// values when materializing named groups instead of slicing the input a second
// time. QuickJS fills the dense result and `groups` from the same capture loop
// in `js_regexp_exec`; keeping this helper separate preserves a compact common
// result-construction body while retaining that ownership model.
pub noinline fn populateRegExpGroupsFromCaptureValues(
    rt: *core.JSRuntime,
    groups: *core.Object,
    found: *const RegExpMatch,
    capture_values: []const core.JSValue,
) !void {
    std.debug.assert(found.has_named_captures);
    std.debug.assert(capture_values.len >= found.capture_count + 1);
    // The capture backing is a caller-owned native slice or rooted stable
    // array-storage cell. Its values and the raw groups pointer stay borrowed
    // through the core property writer's allocating mutation window.
    const values = [_]core.JSValue{groups.value()};
    const slices = [_]core.runtime.ValueRootSlice{ .{ .borrowed = &values }, .{ .borrowed = capture_values } };
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(rt);
    defer roots.deactivate(rt);

    var groups_pin = try core.runtime.NativePin.initHeader(rt, groups.gcHeader());
    defer groups_pin.deinit();
    var capture_index: usize = 0;
    while (capture_index < found.capture_count) : (capture_index += 1) {
        const name = found.captureNameAt(capture_index) orelse continue;
        const capture = found.captureAt(capture_index);
        var decoded_name = std.ArrayList(u8).empty;
        defer decoded_name.deinit(rt.nativeAllocator());
        try appendDecodedRegExpGroupName(rt, &decoded_name, name);
        const atom = try rt.internAtom(decoded_name.items);
        // TGC S3 §4 class B: bare group-name id held across the property
        // define (and, in the indices form, a fresh pair object).
        var group_atom_roots = core.runtime.rootAtoms(.{&atom});
        group_atom_roots.activate(rt);
        defer group_atom_roots.deactivate(rt);
        // Duplicate named groups share one property; the participating
        // (matched) capture wins, an unset duplicate must not overwrite it.
        if (capture.undefined and groups.hasOwnProperty(atom)) continue;
        try groups.defineOwnProperty(rt, atom, core.Descriptor.data(capture_values[capture_index + 1], .all));
    }
}

pub fn primitivePrototypeMethod(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    function_object: *core.Object,
    this_value: core.JSValue,
    id: u32,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const rt = ctx.runtime;
    const tag: i32 = @intCast(id);
    const class_tag = @divTrunc(tag, 10);
    const method_tag = @mod(tag, 10);
    // Methods 3..5 do not coerce `this` through the wrapper-prototype rules:
    // 3 is the constructor-called-as-function path, 4/5 are the Symbol
    // `description` getter and `[Symbol.toPrimitive]`, which validate their
    // receiver themselves (ids: standard_globals primitive_*_id constants).
    switch (method_tag) {
        3 => switch (class_tag) {
            2 => return core.JSValue.boolean(args.len >= 1 and value_ops.isTruthy(args[0])),
            4 => return symbolConstructorCall(ctx, output, global, args),
            else => return error.TypeError,
        },
        4 => {
            if (class_tag != 4) return error.TypeError;
            return symbolDescriptionValue(rt, this_value) catch |err| switch (err) {
                error.TypeError => return throwTypeErrorMessage(ctx, global, "not a symbol"),
                else => err,
            };
        },
        5 => {
            if (class_tag != 4) return error.TypeError;
            return symbolPrimitiveValue(this_value) catch |err| switch (err) {
                error.TypeError => return throwTypeErrorMessage(ctx, global, "not a symbol"),
            };
        },
        else => {},
    }
    const primitive = primitivePrototypeThisValue(this_value, class_tag) catch return throwPrimitivePrototypeTypeError(ctx, global, function_object, class_tag);
    return switch (method_tag) {
        1 => if (class_tag == 1) blk: {
            // `Number.prototype.toString` body lives in `number_ops.zig`;
            // route the already-coerced number primitive through the `.number`
            // record (`primitivePrototypeThisValue` is idempotent for a number,
            // so the record's receiver re-check is a no-op) instead of naming
            // the builtin from exec.
            const native_ref = core.function.NativeBuiltinRef{ .domain = .number, .id = @intFromEnum(method_ids.number.PrototypeMethod.to_string) };
            break :blk (try builtin_dispatch.callInternalRecord(ctx, output, global, &.{}, null, primitive, native_ref, args, caller_function, caller_frame)) orelse error.TypeError;
        } else if (class_tag == 3)
            bigIntPrototypeToString(ctx, output, global, primitive, args, caller_function, caller_frame)
        else
            value_ops.toStringValue(rt, primitive),
        2 => primitive,
        // BigInt.prototype.toLocaleString: no Intl, so the base-10 form.
        8 => if (class_tag == 3) bigIntPrototypeToString(ctx, output, global, primitive, &.{}, caller_function, caller_frame) else error.TypeError,
        else => error.TypeError,
    };
}

/// `Symbol(...)` called as a function (never a constructor): coerce the
/// optional description through the user-visible ToString path, then mint a
/// fresh value symbol.
fn symbolConstructorCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
) !core.JSValue {
    const rt = ctx.runtime;
    const description = blk: {
        if (args.len >= 1 and !args[0].is(.undefined_value)) {
            if (args[0].is(.symbol)) return throwTypeErrorMessage(ctx, global, "cannot convert symbol to string");
            const string_value = try string_ops.toStringForAnnexB(ctx, output, global, args[0], null, null);
            var buffer = std.ArrayList(u8).empty;
            errdefer buffer.deinit(rt.nativeAllocator());
            try value_ops.appendRawString(rt, &buffer, string_value);
            break :blk @as(?[]u8, try buffer.toOwnedSlice(rt.nativeAllocator()));
        }
        break :blk null;
    };
    defer if (description) |bytes| rt.nativeAllocator().free(bytes);
    return rt.newSymbolValue(if (description) |bytes| bytes else null);
}

/// `get Symbol.prototype.description`: unwraps a symbol primitive or a
/// Symbol wrapper object and returns its description string (or undefined).
fn symbolDescriptionValue(rt: *core.JSRuntime, this_value: core.JSValue) !core.JSValue {
    const primitive = try symbolPrimitiveValue(this_value);
    const body = primitive.asSymbolBody() orelse return error.TypeError;
    return body.descriptionValue(rt);
}

/// `Symbol.prototype[Symbol.toPrimitive]`: returns the wrapped symbol
/// primitive; throws TypeError for any other receiver.
fn symbolPrimitiveValue(this_value: core.JSValue) !core.JSValue {
    if (this_value.is(.symbol)) return this_value;
    if (!this_value.is(.object)) return error.TypeError;
    const header = this_value.refHeader() orelse return error.TypeError;
    const object = core.Object.fromHeader(header);
    if (object.class_id != core.class.ids.symbol) return error.TypeError;
    const primitive = (object.objectData() orelse return error.TypeError);
    if (!primitive.is(.symbol)) {
        return error.TypeError;
    }
    return primitive;
}

pub fn throwPrimitivePrototypeTypeError(
    ctx: *core.JSContext,
    global: *core.Object,
    function_object: *core.Object,
    class_tag: i32,
) !core.JSValue {
    const error_global = objectRealmGlobal(function_object) orelse global;
    const message = switch (class_tag) {
        1 => "not a number",
        2 => "not a boolean",
        3 => "not a bigint",
        4 => "not a symbol",
        5 => "not a string",
        else => "",
    };
    const error_value = try exception_ops.createNamedError(ctx, error_global, "TypeError", message);
    _ = ctx.throwValue(error_value);
    return error.JSException;
}

pub fn primitivePrototypeThisValue(value: core.JSValue, class_tag: i32) !core.JSValue {
    if (class_tag == 1 and value.isNumber()) return value;
    if (class_tag == 2 and value.as(.boolean) != null) return value;
    if (class_tag == 3 and value.isBigInt()) return value;
    if (class_tag == 4 and value.is(.symbol)) return value;
    if (class_tag == 5 and value.isString()) return value;
    if (!value.is(.object)) return error.TypeError;
    const object = objectFromValue(value).?;
    const matches = switch (class_tag) {
        1 => object.class_id == core.class.ids.number,
        2 => object.class_id == core.class.ids.boolean,
        3 => object.class_id == core.class.ids.big_int,
        4 => object.class_id == core.class.ids.symbol,
        5 => object.class_id == core.class.ids.string,
        else => false,
    };
    if (!matches) return error.TypeError;
    return object.objectData() orelse error.TypeError;
}

pub fn defineErrorStackDataProperty(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: *core.Object,
    stack_key: core.Atom,
    desc: core.Descriptor,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !void {
    if (receiver.proxyTarget() != null) {
        const ok = try proxyDefineOwnProperty(ctx, output, global, receiver, stack_key, desc, caller_function, caller_frame);
        if (!ok) return error.TypeError;
        return;
    }
    try receiver.defineOwnProperty(ctx.runtime, stack_key, desc);
}

pub fn dataViewConstructWithPrototype(
    rt: *core.JSRuntime,
    buffer: core.JSValue,
    coerced: DataViewConstructorArgs,
    prototype: ?*core.Object,
) !core.JSValue {
    const offset_value = if (coerced.has_offset) lengthIndexValue(coerced.byte_offset) else core.JSValue.undefinedValue();
    const length_value = if (coerced.view_length) |length| lengthIndexValue(length) else core.JSValue.undefinedValue();
    const construct_args = [_]core.JSValue{ buffer, offset_value, length_value };
    const used_args = if (coerced.view_length != null)
        construct_args[0..3]
    else if (coerced.has_offset)
        construct_args[0..2]
    else
        construct_args[0..1];
    return core.typed_array.dataViewConstruct(rt, used_args, prototype);
}

/// PrivateFieldAdd / PrivateMethodOrAccessorAdd step 1 under
/// `nonextensible-applies-to-private`: `? IsExtensible(O)`. A Proxy answers
/// through its trap; an ordinary object's flag is checked by the define.
pub fn requirePrivateElementTargetExtensible(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    object: *core.Object,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) HostError!void {
    if (object.proxyTarget() == null) return;
    if (!try proxyAwareIsExtensible(ctx, output, global, object, caller_function, caller_frame)) return error.NotExtensible;
}

pub fn defineClassFieldDataProperty(rt: *core.JSRuntime, object: *core.Object, atom_id: core.Atom, value: core.JSValue) !void {
    // NO-ALIGN(qjs): JS_DefinePrivateField raw-adds private
    // fields with add_property and never consults extensibility, so qjs lands
    // private fields on preventExtensions'd/frozen instances. test262's
    // `nonextensible-applies-to-private` feature (PrivateFieldAdd step 1:
    // "If O.[[Extensible]] is false, throw a TypeError") mandates the throw
    // (language/statements/class/elements/private-class-field-on-nonextensible-
    // objects.js), so zjs keeps the NotExtensible -> TypeError behavior.
    if (rt.atoms.kind(atom_id) == .private and object.hasOwnProperty(atom_id)) return error.PrivateMemberExists;
    try object.defineOwnProperty(rt, atom_id, core.Descriptor.data(value, .all));
}

pub fn constructWeakRefWithPrototype(rt: *core.JSRuntime, target: core.JSValue, prototype: ?*core.Object) !core.JSValue {
    return construct_mod.weakRefWithPrototype(rt, target, prototype);
}

pub fn constructFinalizationRegistryWithPrototype(
    ctx: *core.JSContext,
    cleanup_callback: core.JSValue,
    prototype: ?*core.Object,
) !core.JSValue {
    const rt = ctx.runtime;
    var rooted_cleanup_callback = cleanup_callback;
    var root_values = [_]*core.JSValue{
        &rooted_cleanup_callback,
    };
    var root_frame = core.runtime.ValueRootFrame{
        .values = &root_values,
    };
    root_frame.activate(rt);
    defer root_frame.deactivate(rt);

    const instance = try core.Object.createFinalizationRegistry(rt, ctx, prototype);
    errdefer core.Object.destroyFromHeader(rt, instance.gcHeader());
    try instance.setOptionalValueSlot(rt, instance.finalizationRegistryCleanupCallbackSlot(), rooted_cleanup_callback);
    return instance.value();
}

pub fn constructCollectionWithPrototypeFromVm(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    kind: u32,
    args: []const core.JSValue,
    prototype: ?*core.Object,
) !core.JSValue {
    // Only the empty Map/Set/WeakMap/WeakSet creation routes through the
    // collection construct record (Phase 6b-3 STEP 4); the adder protocol below
    // that fills it from an iterable argument stays in exec. The collection
    // constructors carry no native id, so the record is reached with an explicit
    // ref built from `kind`.
    const construct_id = core.host_function.builtin_method_id_lookup.collection.constructIdForKind(kind) orelse return error.TypeError;
    const collection_construct_ref = core.function.NativeBuiltinRef{ .domain = .collection, .id = construct_id };
    const collection_value = (try builtin_dispatch.callConstructRecord(ctx, output, global, null, collection_construct_ref, prototype, &.{}, null, null)) orelse return error.TypeError;
    if (args.len == 0 or args[0].is(.undefined_value) or args[0].is(.null_value)) return collection_value;

    const adder_name: []const u8 = if (kind == 1 or kind == 3) "set" else "add";
    const adder_key = try ctx.runtime.internAtom(adder_name);
    const adder = try getValueProperty(ctx, output, global, collection_value, adder_key, null, null);
    if (!isCallableValue(adder)) return error.NotAFunction;

    // The dense array read used to be selected here, on `isArray()` alone, so
    // an array with an own `@@iterator` — or a patched
    // `%ArrayIteratorPrototype%.next` — was silently indexed instead of
    // iterated. That decision now lives inside the iterator path, which makes
    // it only after resolving `@@iterator` and only when the protocol is
    // provably untampered; it is the same guard `appendSpreadValuesEnumerate`
    // already applies for `[...src]`.
    try addCollectionEntriesFromIterator(ctx, output, global, collection_value, kind, args[0], adder);
    return collection_value;
}

pub fn constructorPrototypeObject(constructor: core.JSValue) !?*core.Object {
    if (!constructor.is(.object)) return null;
    if (objectFromValue(constructor)) |object| {
        if (object.getOwnDataObjectBorrowed(core.atom.ids.prototype)) |prototype| return prototype;
    }
    const prototype_value = try property_ops.getPropertyValue(constructor, core.atom.ids.prototype);
    if (prototype_value.is(.object)) return objectFromValue(prototype_value);
    return null;
}

pub fn dynamicFunctionNewTargetPrototype(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    new_target: core.JSValue,
    kind: DynamicFunctionKind,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !?*core.Object {
    const prototype_value = try getValueProperty(ctx, output, global, new_target, core.atom.ids.prototype, caller_function, caller_frame);
    if (prototype_value.is(.object)) return objectFromValue(prototype_value);
    const fallback_realm = try functionRealmContext(ctx, new_target);
    const class_id = switch (kind) {
        .normal => core.class.ids.bytecode_function,
        .async_function => core.class.ids.async_function,
        .generator => core.class.ids.generator_function,
        .async_generator => core.class.ids.async_generator_function,
    };
    return fallback_realm.classPrototypeObject(class_id) orelse return error.InvalidBuiltinRegistry;
}

/// Class selected by QuickJS constructor bodies when they call
/// `js_create_from_ctor(ctx, new_target, class_id)`. Native Error subclasses
/// intentionally stay out of this table: QuickJS resolves those through the
/// separate `native_error_proto[]` realm-state family.
const constructor_class_names = std.StaticStringMap(core.ClassId).initComptime(.{
    .{ "Object", core.class.ids.object },
    .{ "Function", core.class.ids.bytecode_function },
    .{ "Array", core.class.ids.array },
    .{ "String", core.class.ids.string },
    .{ "Number", core.class.ids.number },
    .{ "Boolean", core.class.ids.boolean },
    .{ "Symbol", core.class.ids.symbol },
    .{ "BigInt", core.class.ids.big_int },
    .{ "Date", core.class.ids.date },
    .{ "RegExp", core.class.ids.regexp },
    .{ "Error", core.class.ids.error_ },
    .{ "DisposableStack", core.class.ids.disposable_stack },
    .{ "AsyncDisposableStack", core.class.ids.async_disposable_stack },
    .{ "Promise", core.class.ids.promise },
    .{ "Map", core.class.ids.map },
    .{ "Set", core.class.ids.set },
    .{ "WeakMap", core.class.ids.weakmap },
    .{ "WeakSet", core.class.ids.weakset },
    .{ "WeakRef", core.class.ids.weak_ref },
    .{ "FinalizationRegistry", core.class.ids.finalization_registry },
    .{ "ArrayBuffer", core.class.ids.array_buffer },
    .{ "SharedArrayBuffer", core.class.ids.shared_array_buffer },
    .{ "DataView", core.class.ids.dataview },
    .{ "Iterator", core.class.ids.iterator },
});

pub fn constructorClassPrototypeId(name: []const u8) ?core.ClassId {
    if (constructor_class_names.get(name)) |class_id| return class_id;
    if (construct_mod.typedArrayElement(name)) |element| {
        return core.typed_array.typedArrayClassIdForKind(element.kind);
    }
    return null;
}

pub fn nativeErrorKindFromConstructorName(name: []const u8) ?core.context.NativeErrorKind {
    if (std.mem.eql(u8, name, "Error")) return .error_;
    if (std.mem.eql(u8, name, "EvalError")) return .eval_error;
    if (std.mem.eql(u8, name, "RangeError")) return .range_error;
    if (std.mem.eql(u8, name, "ReferenceError")) return .reference_error;
    if (std.mem.eql(u8, name, "SyntaxError")) return .syntax_error;
    if (std.mem.eql(u8, name, "TypeError")) return .type_error;
    if (std.mem.eql(u8, name, "URIError")) return .uri_error;
    if (std.mem.eql(u8, name, "InternalError")) return .internal_error;
    if (std.mem.eql(u8, name, "AggregateError")) return .aggregate_error;
    if (std.mem.eql(u8, name, "SuppressedError")) return .suppressed_error;
    return null;
}

pub fn objectRealmGlobal(object: *core.Object) ?*core.Object {
    // QuickJS JS_GetFunctionRealm recursively unwraps Proxy and bound
    // functions for the explicit FunctionRealm query. This is distinct from
    // call dispatch, where both wrappers keep the caller view until recursion
    // reaches the final bytecode/C-function arm.
    if (object.proxyTarget()) |target_value| {
        const target_object = objectFromValue(target_value) orelse return null;
        return objectRealmGlobal(target_object);
    }
    if (object.class_id == core.class.ids.bound_function) {
        const target_value = object.boundTarget() orelse return null;
        const target_object = objectFromValue(target_value) orelse return null;
        return objectRealmGlobal(target_object);
    }
    if (object.class_id == core.class.ids.generator or object.class_id == core.class.ids.async_generator) {
        if (object.generatorFunctionRealmGlobalPtr()) |realm_global| return realm_global;
    }
    if (object.bytecodeFunctionRealmGlobalPtr()) |realm_global| return realm_global;
    if (object.nativeFunctionRealmGlobalPtr()) |realm_global| return realm_global;
    const realm_value = object.functionRealmGlobal() orelse return null;
    return core.value_semantics.objectFromValue(realm_value);
}

pub fn propertyIndexFromLengthKey(rt: *core.JSRuntime, atom_id: core.Atom) ?usize {
    if (core.array.arrayIndexFromAtom(rt.atoms, atom_id)) |index| return index;
    if (rt.atoms.kind(atom_id) != .string) return null;
    const name = rt.atoms.name(atom_id) orelse return null;
    if (name.len == 0) return null;
    for (name) |ch| {
        if (ch < '0' or ch > '9') return null;
    }
    return std.fmt.parseUnsigned(usize, name, 10) catch null;
}

pub fn propertyAtomFromLengthIndex(rt: *core.JSRuntime, index: usize) !LengthIndexAtom {
    if (index <= core.atom.max_int_atom) return .{ .atom = core.Atom.taggedInt(@intCast(index)), .owned = false };
    const name = try std.fmt.allocPrint(rt.nativeAllocator(), "{d}", .{index});
    defer rt.nativeAllocator().free(name);
    const id = try rt.internAtom(name);
    // TGC S3 §2.2 root G; see `LengthIndexAtom`. Paired with `deinit`.
    rt.atoms.pinForHost(id);
    return .{ .atom = id, .owned = true };
}

pub fn createDataPropertyOrThrow(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    object: *core.Object,
    atom_id: core.Atom,
    value: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !void {
    if (object.proxyTarget() != null) {
        try proxyCreateDataPropertyOrThrow(ctx, output, global, object, atom_id, value, caller_function, caller_frame);
        return;
    }
    // A typed array's [[DefineOwnProperty]] converts the value (ToNumber /
    // ToBigInt, observable through valueOf) and refuses an invalid index.
    if (try array_ops.typedArrayDefineOwnPropertyVm(ctx, output, global, object, atom_id, core.Descriptor.data(value, .all))) |defined| {
        if (!defined) {
            _ = try throwTypeErrorMessage(ctx, global, "cannot define typed array element");
            unreachable;
        }
        return;
    }
    try createArrayDataOrTypedArrayElement(ctx.runtime, object, atom_id, value);
}

pub fn objectGetPrototypeOfStep(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    object: *core.Object,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !?*core.Object {
    if (!object.isProxy()) {
        if (isThrowTypeErrorIntrinsicObject(object)) {
            if (object.getPrototype()) |prototype| return prototype;
            return functionPrototypeFromGlobal(objectRealmGlobal(object) orelse global);
        }
        return object.getPrototype();
    }
    const handler_value = try proxyHandlerForTrap(ctx, global, object);
    const target_value = object.proxyTargetOfProxy();
    const target = objectFromValue(target_value) orelse return error.TypeError;
    const trap_key = core.atom.ids.getPrototypeOf;
    const trap = try getValueProperty(ctx, output, global, handler_value, trap_key, caller_function, caller_frame);
    if (trap.is(.undefined_value) or trap.is(.null_value)) return objectGetPrototypeOfStep(ctx, output, global, target, caller_function, caller_frame);
    const result = try callValueOrBytecodeSyncInternal(ctx, output, global, handler_value, trap, &.{target_value}, caller_function, caller_frame);
    const result_proto = if (result.is(.null_value)) null else objectFromValue(result) orelse return error.ProxyInvariantViolation;
    if (!try proxyAwareIsExtensible(ctx, output, global, target, caller_function, caller_frame)) {
        const target_proto = try objectGetPrototypeOfStep(ctx, output, global, target, caller_function, caller_frame);
        if (target_proto != result_proto) return error.ProxyInvariantViolation;
    }
    return result_proto;
}

/// Inline wrapper over the outlined `objectGetPrototypeOfStep` walk
/// (including the proxy getPrototypeOf trap); only the JSValue result
/// wrapping differs.
pub inline fn objectGetPrototypeOfValue(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    object: *core.Object,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const proto = try objectGetPrototypeOfStep(ctx, output, global, object, caller_function, caller_frame);
    return if (proto) |prototype| prototype.value() else core.JSValue.nullValue();
}

pub fn objectRestOwnKeys(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    source: *core.Object,
) HostError![]core.Atom {
    if (source.proxyTarget() == null and core.object.isTypedArrayObject(source)) {
        return try typedArrayOwnKeys(ctx.runtime, source);
    }
    if (source.proxyTarget() == null) {
        return try source.ownKeys(ctx.runtime);
    }
    const target_value = source.proxyTarget() orelse return source.ownKeys(ctx.runtime);
    const handler_value = try proxyHandlerForTrap(ctx, global, source);
    const own_keys_atom = core.atom.ids.ownKeys;
    const trap = try getValueProperty(ctx, output, global, handler_value, own_keys_atom, null, null);
    if (trap.is(.undefined_value) or trap.is(.null_value)) {
        const target = try property_ops.expectObject(target_value);
        return objectRestOwnKeys(ctx, output, global, target);
    }
    var trap_result = try callValueOrBytecodeSyncInternal(ctx, output, global, handler_value, trap, &.{target_value}, null, null);
    _ = try property_ops.expectObject(trap_result);
    // TGC S3 §4 class V: `key_value` is only ever reachable through
    // `trap_result`, and `propertyKeyAtom` below derives the atom's liveness
    // from that value's string/symbol body -- so both need a real root.
    var key_value = core.JSValue.undefinedValue();
    var trap_roots = core.runtime.rootValues(.{ &trap_result, &key_value });
    trap_roots.activate(ctx.runtime);
    defer trap_roots.deactivate(ctx.runtime);
    var out: core.atom.AtomListBuilder = .{};
    defer out.deinit(ctx.runtime);
    // Duplicate check (§10.5.11 step 9): a set, not a scan of `out` per key.
    var seen: std.AutoHashMapUnmanaged(core.Atom, void) = .empty;
    defer seen.deinit(ctx.runtime.nativeAllocator());
    // TGC S3 §4 class B: the accumulated ids sit in a native []Atom while the
    // trap result is read key by key, which re-enters JS every iteration.
    var out_roots = core.runtime.rootAtomList(&out.items);
    out_roots.activate(ctx.runtime);
    defer out_roots.deactivate(ctx.runtime);
    const length_value = try getValueProperty(ctx, output, global, trap_result, core.atom.ids.length, null, null);
    const length = try toLengthIndex(ctx, output, global, length_value);
    for (0..length) |index| {
        const index_key = try propertyAtomFromLengthIndex(ctx.runtime, index);
        defer index_key.deinit(ctx.runtime);
        key_value = try getValueProperty(ctx, output, global, trap_result, index_key.atom, null, null);
        defer key_value = core.JSValue.undefinedValue();
        if (!key_value.isString() and !key_value.is(.symbol)) return error.ProxyInvariantViolation;
        const atom_id = try property_ops.propertyKeyAtom(ctx.runtime, key_value);
        if ((try seen.getOrPut(ctx.runtime.nativeAllocator(), atom_id)).found_existing) return error.ProxyInvariantViolation;
        try out.append(ctx.runtime, atom_id);
    }
    try validateProxyOwnKeysResult(ctx, output, global, target_value, out.items);
    return try out.toOwnedSlice(ctx.runtime);
}

pub fn objectRestOwnPropertyDescriptor(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    source: *core.Object,
    key: core.Atom,
) !?core.Descriptor {
    return try proxyAwareOwnPropertyDescriptor(ctx, output, global, source, key, null, null);
}

pub fn atomicsBufferObject(object: *core.Object) !*core.Object {
    const buffer_value = object.typedArrayBuffer() orelse return error.TypeError;
    return property_ops.expectObject(buffer_value);
}

pub fn importMetaObject(
    ctx: *core.JSContext,
    function: *const bytecode.FunctionBytecode,
) !core.JSValue {
    const record = ctx.modules.find(function.scriptOrModule()) orelse return error.ModuleNotFound;
    if (record.import_meta) |value| return value;

    const object = try core.Object.create(ctx.runtime, core.class.ids.object, null);
    errdefer core.Object.destroyFromHeader(ctx.runtime, object.gcHeader());
    // import.meta is a real null-prototype object (JS_GetImportMeta:
    // JS_NewObjectProto(ctx, JS_NULL), quickjs.c); without the flag,
    // ToPrimitive fell through to %Object.prototype%.toString and
    // import(import.meta) stringified instead of rejecting with TypeError.
    if (ctx.module_source_loader != null) {
        const url = try importMetaUrlValue(ctx, record);
        try defineValueProperty(ctx.runtime, object, core.atom.ids.url, url);
        try defineValueProperty(ctx.runtime, object, core.atom.ids.main, core.JSValue.boolean(record.import_meta_main));
    }
    const value = object.value();
    record.import_meta = value;
    // The record is created when the module is loaded; `import.meta` is built
    // the first time the module body evaluates the expression, which can be
    // arbitrarily later. `ModuleRecord.setEvalException` already barriers its
    // sibling field for exactly this reason; this store had no funnel at all.
    ctx.runtime.gc.generationalBarrier(&record.header, value.cycleMarkHeader());
    return value;
}

pub fn createGeneratorObject(
    ctx: *core.JSContext,
    func: core.JSValue,
    current_function_value: core.JSValue,
    this_value: core.JSValue,
    input_args: []const core.JSValue,
    input_var_refs: []const *core.VarRef,
    output: ?*std.Io.Writer,
    global: *core.Object,
    is_async: bool,
    call_depth_precharged: bool,
    call_entry_ctx: *core.JSContext,
    call_entry_global: *core.Object,
) !core.JSValue {
    var rooted_func = func;
    var rooted_current = current_function_value;
    var rooted_this = this_value;
    var rooted_boxed_this = core.JSValue.undefinedValue();

    var root_values = [_]*core.JSValue{
        &rooted_func,
        &rooted_current,
        &rooted_this,
        &rooted_boxed_this,
    };
    if (input_args.len > array_ops.max_apply_arguments) {
        return throwRangeErrorMessage(ctx, global, "too many arguments in function call (only 65534 allowed)");
    }
    const fb = functionBytecodeFromValue(rooted_func) orelse return error.TypeError;
    var root_slices = [_]core.runtime.ValueRootSlice{
        .{ .borrowed = input_args },
        .{ .borrowed_cells = input_var_refs },
    };
    var root_frame = core.runtime.ValueRootFrame{
        .values = &root_values,
        .slices = &root_slices,
    };
    root_frame.activate(ctx.runtime);
    defer root_frame.deactivate(ctx.runtime);

    const class_id = if (is_async) core.class.ids.async_generator else core.class.ids.generator;
    // Normal JS generator calls keep their execution state detached while the
    // parameter prologue runs, then create the public object directly with its
    // final prototype. This mirrors qjs js_generator_function_call and avoids
    // a temporary null-prototype Shape on every short-lived generator. The raw
    // internal-bytecode path creates its registered object eagerly and saves
    // the raw FB in the same current-function owner used for realm derivation.
    const detached_shell = rooted_current.is(.object);
    const object = if (detached_shell)
        try core.Object.createGeneratorShell(ctx.runtime, class_id)
    else
        try core.Object.create(ctx.runtime, class_id, null);
    var object_registered = !detached_shell;
    errdefer if (object_registered)
        core.Object.destroyFromHeader(ctx.runtime, object.gcHeader())
    else
        object.destroyGeneratorShell(ctx.runtime);
    var prepared_frame: zjs_vm.PreparedEntryFrame = undefined;
    var prepared_frame_ptr: ?*const zjs_vm.PreparedEntryFrame = null;
    if (detached_shell) {
        const stack_slots = try std.math.add(usize, @as(usize, fb.stack_size), 1);
        const frame_arg_count = frame_mod.frameArgCount(fb, input_args.len);
        const need_original_args = frame_mod.argumentsNeedsOriginalSnapshot(fb);
        const original_arg_count = frame_mod.originalArgCount(input_args.len, need_original_args);
        const var_ref_count = frame_mod.frameVarRefStorageCount(fb, input_var_refs);
        const open_var_ref_count = frame_mod.frameOpenVarRefStorageCount(fb);
        const layout: frame_mod.SlabLayout = .{
            .args = frame_arg_count,
            .original_args = original_arg_count,
            .locals = fb.var_count,
            .var_refs = var_ref_count,
            .open_var_refs = open_var_ref_count,
        };
        const frame_slots = try layout.totalSlots();
        try object.initGeneratorExecutionWithStorage(ctx.runtime, stack_slots, frame_slots);
        prepared_frame = .{
            .slab = frame_mod.FrameSlab.partition(object.generatorCombinedFrameStorage(), layout),
            .need_original_args = need_original_args,
        };
        prepared_frame_ptr = &prepared_frame;
    }
    object.generatorActualArgCountSlot().* = @intCast(input_args.len);
    // This is the complete realm provenance for generator/async resumption:
    // normal calls save the closure object, while internal calls save the raw
    // FunctionBytecode. Both own the FB that owns its RealmContext.
    const saved_current = if (rooted_current.is(.object) or rooted_current.is(.function_bytecode)) rooted_current else rooted_func;
    object.setGeneratorCurrentFunction(saved_current);
    const fb_runtime_strict = fb.isStrictMode() or fb.runtimeStrictMode();
    const effective_this = if (!fb_runtime_strict) blk: {
        if (rooted_this.is(.undefined_value) or rooted_this.is(.null_value)) break :blk global.value();
        if (!rooted_this.is(.object)) {
            rooted_boxed_this = try primitiveObjectForAccess(ctx.runtime, global, rooted_this);
            break :blk rooted_boxed_this;
        }
        break :blk rooted_this;
    } else rooted_this;
    object.setGeneratorThis(effective_this);
    // Every generator gets one resident frame at creation. Canonical bytecode
    // parks at OP_initial_yield; markerless internal fixtures park at pc 0.
    // qjs's async_func_init likewise has no separate deferred args/captures
    // owner.
    _ = try runGeneratorParameterInit(
        ctx,
        fb,
        prepared_frame_ptr,
        object,
        rooted_current,
        effective_this,
        input_args,
        input_var_refs,
        output,
        call_depth_precharged,
        call_entry_ctx,
        call_entry_global,
    );

    const prototype = try generatorObjectPrototype(ctx.runtime, global, rooted_current, is_async);
    if (detached_shell) {
        try object.finishGeneratorShell(ctx.runtime, prototype);
        object_registered = true;
    } else {
        try object.setFreshObjectPrototype(ctx.runtime, prototype);
    }
    return object.value();
}

pub fn generatorObjectPrototype(rt: *core.JSRuntime, global: *core.Object, function_value: core.JSValue, is_async: bool) !?*core.Object {
    const fallback = if (is_async) try asyncGeneratorPrototypeFromGlobal(rt, global) else try generatorPrototypeFromGlobal(rt, global);
    const function_object = core.value_semantics.objectFromValue(function_value) orelse return fallback;
    if (function_object.getOwnDataObjectBorrowed(core.atom.ids.prototype)) |prototype| return prototype;
    const prototype_value = try function_object.getProperty(core.atom.ids.prototype);
    if (prototype_value.is(.object)) return objectFromValue(prototype_value);
    return fallback;
}

/// OrdinaryHasInstance(%Iterator%, value): the chain is read with
/// [[GetPrototypeOf]], so a Proxy's trap answers for it.
pub fn iteratorIsOnIteratorPrototypeChain(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) HostError!bool {
    const iterator = objectFromValue(value) orelse return false;
    const iterator_proto = iteratorPrototypeFromGlobal(ctx.runtime, global) orelse return false;
    var cursor = iterator.value();
    var roots = core.runtime.rootValues(.{&cursor});
    roots.activate(ctx.runtime);
    defer roots.deactivate(ctx.runtime);
    while (true) {
        const proto = (try objectGetPrototypeOfStep(ctx, output, global, objectFromValue(cursor).?, caller_function, caller_frame)) orelse return false;
        if (proto == iterator_proto) return true;
        cursor = proto.value();
    }
}

pub fn wrapForValidIteratorPrototype(rt: *core.JSRuntime, global: *core.Object) !*core.Object {
    if (cachedRealmObject(rt, global, .wrap_for_valid_iterator_prototype)) |stored| return stored;

    var values = [_]core.JSValue{core.JSValue.undefinedValue()};
    var slots: []core.JSValue = &values;
    const globals = [_]core.JSValue{global.value()};
    const slices = [_]core.runtime.ValueRootSlice{ .{ .mutable = &slots }, .{ .borrowed = &globals } };
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(rt);
    defer roots.deactivate(rt);
    values[0] = (try core.Object.create(rt, core.class.ids.object, iteratorPrototypeFromGlobal(rt, global))).value();
    try defineNativeDataMethod(rt, global, objectFromValue(values[0]).?, core.atom.ids.next, 0);
    try tagIteratorWrapPrototypeMethod(rt, global, objectFromValue(values[0]).?, core.atom.ids.next, .wrap_for_valid_iterator_next);
    try defineNativeDataMethod(rt, global, objectFromValue(values[0]).?, core.atom.ids.return_, 0);
    try tagIteratorWrapPrototypeMethod(rt, global, objectFromValue(values[0]).?, core.atom.ids.return_, .wrap_for_valid_iterator_return);
    try storeRealmValue(rt, global, .wrap_for_valid_iterator_prototype, values[0]);
    return objectFromValue(values[0]).?;
}

pub fn tagIteratorWrapPrototypeMethod(
    rt: *core.JSRuntime,
    global: *core.Object,
    proto: *core.Object,
    key: core.Atom,
    method: core.host_function.builtin_method_ids.iterator.IntrinsicMethod,
) !void {
    var values = [_]core.JSValue{ proto.value(), core.JSValue.undefinedValue() };
    var slots: []core.JSValue = &values;
    const globals = [_]core.JSValue{global.value()};
    const slices = [_]core.runtime.ValueRootSlice{ .{ .mutable = &slots }, .{ .borrowed = &globals } };
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(rt);
    defer roots.deactivate(rt);
    values[1] = try objectFromValue(values[0]).?.getProperty(key);
    const method_object = objectFromValue(values[1]) orelse return;
    method_object.setNativeBuiltinIdAndRecord(core.function.nativeBuiltinId(.iterator, @intFromEnum(method)));
    if (functionPrototypeFromGlobal(global)) |function_proto| {
        try objectFromValue(values[1]).?.setPrototype(rt, function_proto);
    }
}

pub fn iteratorPrototypeFromGlobal(rt: *core.JSRuntime, global: *core.Object) ?*core.Object {
    return iterator_ops.iteratorPrototypeFromGlobal(rt, global);
}

pub fn iteratorPrototype(rt: *core.JSRuntime, global: *core.Object, tag_name: []const u8) !*core.Object {
    return iterator_ops.iteratorPrototype(rt, global, tag_name);
}

fn argumentsPropertyTemplate(rt: *core.JSRuntime, global: *core.Object, comptime mapped: bool) !*core.Shape {
    const ctx = rt.contextForGlobal(global) orelse return error.TypeError;
    const current = if (mapped) ctx.mapped_arguments_shape else ctx.arguments_shape;
    if (current) |initial| return initial;
    try ctx.initializeInitialShapes(
        objectPrototypeFromGlobal(rt, global),
        arrayPrototypeFromGlobal(rt, global),
        ctx.classPrototypeObject(core.class.ids.regexp) orelse constructorPrototypeFromGlobal(rt, global, "RegExp"),
    );
    return (if (mapped) ctx.mapped_arguments_shape else ctx.arguments_shape) orelse return error.TypeError;
}

/// qjs js_build_mapped_arguments:
/// `JS_NewObjectFromShape(ctx->mapped_arguments_shape, props)` then one
/// var-ref table (`get_var_ref` for formals, `js_create_var_ref` for extra
/// actuals). Kept as its own noinline so the unmapped thrower/accessor
/// construction does not sit in the sc_list / apply hot I-cache line.
noinline fn createMappedArgumentsObject(
    ctx: *core.JSContext,
    global: *core.Object,
    frame: *frame_mod.Frame,
    args: []core.JSValue,
) !core.JSValue {
    const initial_shape = if (ctx.mapped_arguments_shape) |cached|
        cached
    else
        try argumentsPropertyTemplate(ctx.runtime, global, true);
    const iterator_value = try argumentsIteratorValueOwned(ctx, global);
    const entries = [_]core.property.Entry{
        .{ .slot = .{ .data = core.JSValue.int32(@intCast(args.len)) } },
        .{ .slot = .{ .data = iterator_value } },
        .{ .slot = .{ .data = frame.current_function } },
    };
    const object = try core.Object.createArgumentsFromShape(
        ctx.runtime,
        core.class.ids.mapped_arguments,
        initial_shape,
        &entries,
    );
    errdefer core.Object.destroyFromHeader(ctx.runtime, object.gcHeader());

    if (args.len == 0) return object.value();

    const refs = try object.allocateMappedArgumentsVarRefsAssumingEmpty(ctx.runtime, args.len);
    const formal_count = @min(args.len, frame.function.arg_count);
    var index: usize = 0;
    while (index < formal_count) : (index += 1) {
        refs[index] = try frame.captureArg(ctx.runtime, index);
    }
    while (index < args.len) : (index += 1) {
        const initial = args[index];
        refs[index] = try core.VarRef.createClosed(ctx.runtime, initial);
    }
    // Every `refs[index]` store above is an edge into the table, and each
    // `captureArg` / `createClosed` between them is an allocation that can run
    // a minor. A minor retires the remembered set once it has traced the
    // owner, so a var ref created after it lands in an old table with no
    // record; remember the owner once more now that the table is complete.
    ctx.runtime.gc.rememberOwnerForBulkWrite(object.gcHeader());
    return object.value();
}

fn argumentsIteratorValueOwned(ctx: *core.JSContext, global: *core.Object) !core.JSValue {
    // qjs js_build_(mapped_)arguments reads the realm cache with a single
    // `JS_DupValue(ctx, ctx->array_proto_values)`.
    // createArgumentsObject already holds the frame's realm (`ctx = b->realm`,
    // the same context whose shapes argumentsPropertyTemplate serves), so read
    // the slot directly instead of arrayPrototypeValuesFromGlobal's
    // global->context reverse lookup plus dup/defer-free pair. Bootstrap and
    // bare-runtime frames may run before the cache is populated (or against a
    // caller-supplied global): fall back to the lookup path.
    if (ctx.global == global) {
        if (ctx.cached_values[@intFromEnum(core.object.RealmValueSlot.array_prototype_values)]) |cached| {
            return cached;
        }
    }
    return (try arrayPrototypeValuesFromGlobal(ctx.runtime, global)) orelse core.JSValue.undefinedValue();
}

// `noinline`: qjs OP_special_object reaches js_build_(mapped_)arguments as an
// out-of-line call; keeping the builder's construction
// locals out of the dispatch arm's frame mirrors that call boundary.
pub noinline fn createArgumentsObject(ctx: *core.JSContext, global: *core.Object, frame: *frame_mod.Frame, mapped_override: ?bool) !core.JSValue {
    // zjs-side adaptation (R2): qjs finalizes the mapped/unmapped decision at
    // emit time (quickjs.c gates OP_special_object MAPPED_ARGUMENTS on
    // `!(js_mode & JS_MODE_STRICT) && has_simple_parameter_list`). zjs's
    // The compile policy can make a sloppy-parsed function runtime-strict
    // while its prologue still emits the subtype-1 (mapped) special_object,
    // so the override arm must re-apply the same effective-strictness gate the
    // else arm uses. A runtime-strict frame therefore downgrades to an
    // UNMAPPED arguments object (spec-correct for strict functions), which
    // needs no open-ref window and never reaches captureArg.
    const mapped = (mapped_override orelse true) and
        !currentFrameFunctionIsStrict(frame) and frame.function.hasSimpleParameterList();
    const args = if (mapped)
        frame.args[0..@min(frame.actual_arg_count, frame.args.len)]
    else if (frame.originalArgs().len != 0)
        frame.originalArgs()[0..@min(frame.actual_arg_count, frame.originalArgs().len)]
    else
        frame.args[0..@min(frame.actual_arg_count, frame.args.len)];
    if (mapped) {
        return createMappedArgumentsObject(ctx, global, frame, args);
    }
    const object = blk: {
        const initial_shape = try argumentsPropertyTemplate(ctx.runtime, global, false);
        // qjs js_build_arguments prop fill: the callee
        // getset cell owns TWO throw_type_error refs, which
        // fromBorrowedValues' double retain provides; the accessor then
        // transfers into the object (destroyed by the shape's accessor flags
        // on a failed construction).
        const thrower = try throwTypeErrorIntrinsicForGlobal(ctx.runtime, global);
        const iterator_value = try argumentsIteratorValueOwned(ctx, global);
        const entries = [_]core.property.Entry{
            .{ .slot = .{ .data = core.JSValue.int32(@intCast(args.len)) } },
            .{ .slot = .{ .data = iterator_value } },
            .{ .slot = .{ .accessor = core.property.Accessor.fromBorrowedValues(thrower, thrower) } },
        };
        break :blk try core.Object.createArgumentsFromShape(ctx.runtime, core.class.ids.arguments, initial_shape, &entries);
    };
    errdefer core.Object.destroyFromHeader(ctx.runtime, object.gcHeader());

    var dense_elements: []core.JSValue = &.{};
    if (args.len != 0) {
        // TGC S4-b spec 2.2: `.array_storage` GC cell.
        dense_elements = try core.Object.createArrayStorageSlice(ctx.runtime, args.len);
        for (args, 0..) |_, index| dense_elements[index] = args[index];
    }
    object.adoptDenseUnmappedArgumentsElementsAssumingEmpty(ctx.runtime, dense_elements);
    return object.value();
}

pub fn installFunctionPrototypeThrowTypeErrorAccessors(rt: *core.JSRuntime, global: *core.Object, thrower: core.JSValue) !void {
    const function_prototype = functionPrototypeFromGlobal(global) orelse return;
    const arguments_key = core.atom.ids.arguments;
    try function_prototype.defineOwnProperty(rt, arguments_key, core.Descriptor.accessor(thrower, thrower, .{ .configurable = true }));
    try function_prototype.defineOwnProperty(rt, core.atom.ids.caller, core.Descriptor.accessor(thrower, thrower, .{ .configurable = true }));
}

pub fn isThrowTypeErrorIntrinsicObject(object: *core.Object) bool {
    return object.isThrowTypeErrorIntrinsicFunction();
}

pub fn frameArgumentsObjectForSpecialObject(ctx: *core.JSContext, global: *core.Object, frame: *frame_mod.Frame, subtype: u8) !core.JSValue {
    // The compiler emits this once and stores the owned result in the hidden
    // arguments vardef. Direct eval captures that final local cell through
    // closure2, so no second cross-bytecode FrameCold cache is needed.
    const mapped_override: ?bool = switch (subtype) {
        0 => false,
        1 => true,
        else => null,
    };
    return createArgumentsObject(ctx, global, frame, mapped_override);
}

pub fn functionObjectFromValue(value: core.JSValue) ?*core.Object {
    const object = objectFromValue(value) orelse return null;
    if (!core.class.isBytecodeFunctionClass(object.class_id)) return null;
    return object;
}

/// Inline-call resolution twin of `functionObjectFromValue` with qjs's exact
/// discrimination: JS_CallInternal admits only `p->class_id ==
/// JS_CLASS_BYTECODE_FUNCTION` with a single compare —
/// generator/async classes take the class_array call slow path there. zjs's
/// four-class set test (`isBytecodeFunctionClass`) compiles to a 1<<id
/// shift+mask chain (8 insn); on the inline-call path the three non-normal
/// classes are ALWAYS rejected two loads later by `functionKind() != .normal`,
/// so the exact compare is a strict refinement: same accept set, and the
/// generator/async miss reaches the authoritative slow path earlier.
pub inline fn plainBytecodeFunctionObjectFromValue(value: core.JSValue) ?*core.Object {
    const object = objectFromValue(value) orelse return null;
    if (object.class_id != core.class.ids.bytecode_function) return null;
    return object;
}

// Authoritative implementations live in core.value_semantics (the Object
// type's own layer); the safety contract and the TrustedExpression
// precondition are documented there. These re-exports keep the established
// exec spellings working.
pub const objectFromValue = core.value_semantics.objectFromValue;
pub const objectFromValueTrustedExpression = core.value_semantics.objectFromValueTrustedExpression;

pub fn callableObjectFromValue(value: core.JSValue) ?*core.Object {
    const object = objectFromValue(value) orelse return null;
    if (object.class_id != core.class.ids.c_function and
        object.class_id != core.class.ids.c_function_data and
        !core.class.isAsyncFunctionResumeClass(object.class_id) and
        object.class_id != core.class.ids.bound_function) return null;
    return object;
}

pub fn toPropertyKeyValue(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    if (!value.is(.object)) return value;
    return toPrimitiveForString(ctx, output, global, value, caller_function, caller_frame);
}

pub fn toPropertyKeyAtom(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.Atom {
    const key_value = try toPropertyKeyValue(ctx, output, global, value, caller_function, caller_frame);
    return property_ops.propertyKeyAtom(ctx.runtime, key_value);
}

pub fn callObjectToPrimitiveMethod(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    atom_id: core.Atom,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    var values = [_]core.JSValue{ global.value(), receiver, core.JSValue.undefinedValue() };
    const live: []core.JSValue = &values;
    const slices = [_]core.runtime.ValueRootSlice{.{ .mutable = &live }};
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(ctx.runtime);
    defer roots.deactivate(ctx.runtime);
    const object = try property_ops.expectObject(values[1]);
    values[2] = try getMethodPropertyForOrdinaryToPrimitive(ctx, output, objectFromValue(values[0]).?, values[1], object, atom_id, caller_function, caller_frame);
    if (values[2].is(.undefined_value) or values[2].is(.null_value)) return null;
    if (!isCallableValue(values[2])) return null;
    // A method getter can move the receiver before the method is invoked.
    // Re-read both the receiver and callable from their actual root slots.
    const result = try callValueOrBytecodeSyncInternal(ctx, output, objectFromValue(values[0]).?, values[1], values[2], &.{}, caller_function, caller_frame);
    if (result.is(.object)) {
        return null;
    }
    return result;
}

pub fn getMethodPropertyForOrdinaryToPrimitive(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    object: *core.Object,
    atom_id: core.Atom,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    if (object.proxyTarget() != null) return getProxyProperty(ctx, output, global, receiver, object, atom_id, caller_function, caller_frame);
    if (try findPropertyDescriptor(ctx.runtime, object, atom_id)) |desc| {
        switch (desc.kind) {
            .data => return desc.value,
            .accessor => {
                if (desc.getter.is(.undefined_value)) return core.JSValue.undefinedValue();
                return callValueOrBytecodeSyncInternal(ctx, output, global, receiver, desc.getter, &.{}, caller_function, caller_frame);
            },
            .generic => return core.JSValue.undefinedValue(),
        }
    }
    return getValueProperty(ctx, output, global, receiver, atom_id, caller_function, caller_frame);
}

pub fn getValueProperty(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.JSValue,
    atom_id: core.Atom,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const rt = ctx.runtime;
    if (value.is(.object)) {
        const object = try property_ops.expectObject(value);
        // QJS keeps private-field access out of JS_GetPropertyInternal. ZJS
        // shares this entry point, so reject ordinary property atoms with the
        // AtomTable's conservative lower bound before consulting the full
        // dynamic kind table. Predefined names such as exec/flags/lastIndex
        // therefore pay only the cheap bound check; a possible private atom is
        // still confirmed exactly before taking private-field semantics.
        if (rt.atoms.mightBePrivate(atom_id) and rt.atoms.kind(atom_id) == .private) {
            return getPrivateValueProperty(ctx, output, global, value, object, atom_id, caller_function, caller_frame);
        }
        // Mapped arguments overlay their live parameter cell on the ordinary
        // shape entry. This is the one representation-specific exception to
        // the universal shape walk below.
        if (mappedArgumentsValue(ctx.runtime, object, atom_id)) |mapped_value| return mapped_value;
        if (object.class_id == core.class.ids.proxy) {
            return getProxyProperty(ctx, output, global, value, object, atom_id, caller_function, caller_frame);
        }
        if (object.class_id >= core.class.ids.uint8c_array and object.class_id <= core.class.ids.float64_array) {
            // qjs JS_GetPropertyInternal probes the shape before its typed-array
            // exotic arm. Canonical numeric elements never occupy a shape slot;
            // named length/byteLength/byteOffset continue through the actual
            // prototype chain below instead of being synthesized as own values.
            if (object.findProperty(atom_id) == null) {
                if (try typedArrayCanonicalGet(ctx.runtime, object, atom_id)) |indexed| return indexed;
            }
        }
        if (!object.hasExoticMethods()) {
            if (object.isArray()) {
                if (atom_id == core.atom.ids.length) return value_ops.length(value);
                if (atom_id.isTaggedInt()) {
                    const index = atom_id.toUInt32();
                    if (object.getDenseArrayElementValue(index)) |element| return element;
                }
                if (object.getOwnDataPropertyValue(atom_id)) |own_data| return own_data;
            } else if (object.class_id == core.class.ids.object) {
                if (object.getOwnDataPropertyValue(atom_id)) |own_data| return own_data;
            }
        }
        // QuickJS's fixed `JS_ATOM_Symbol_hasInstance` lookup goes straight
        // into the ordinary shape walk. Keep zjs's
        // receiver-aware legacy compatibility helper ahead of that walk only
        // for its two actual keys; unrelated function properties must not pay
        // an outlined `caller`/`arguments` miss.
        if (core.class.isFunctionClass(object.class_id) and
            (atom_id == core.atom.ids.caller or atom_id == core.atom.ids.arguments))
        {
            if (try functionCallerArgumentsProperty(ctx, output, global, value, object, atom_id, caller_function, caller_frame)) |function_value| {
                return function_value;
            }
        }
        // QuickJS resolves an ordinary property with one shape/prototype walk:
        // find_own_property comes before every class/exotic check at every
        // prototype depth. Class-specific numeric,
        // proxy, module and legacy-function behavior is handled by that same
        // walk only after a shape miss.
        if (try getPropertyValueFromObjectChain(ctx, output, global, value, object, atom_id, caller_function, caller_frame)) |property_value| {
            return property_value;
        }
        // qjs JS_GetPropertyInternal: after the proto
        // walk, return JS_UNDEFINED. No class-name fallback, no DataView
        // own-leg, no String-index miss synthesis.
        return core.JSValue.undefinedValue();
    }
    return getValuePropertyNonObject(ctx, output, global, value, atom_id, caller_function, caller_frame);
}

/// QJS `JS_GetPropertyInternal` starts a named-atom read with the ordinary
/// `find_own_property` shape walk and enters class/exotic handling only after a
/// miss. Internal algorithms already carry an atom, so
/// they can use the same data-only prefix without paying the VM computed-key
/// conversion or the general resolver's representation-specific index cases.
///
/// A complete ordinary miss is distinct from a slow/exotic lookup: QJS returns
/// undefined immediately after exhausting the ordinary prototype chain, while
/// accessors, auto-init/var-ref entries, proxies, class exotics, private names,
/// and integer-index atoms must enter the full observable resolver.
pub const NamedDataPropertyProbe = struct {
    slot: ?*const core.JSValue = null,
    needs_slow: bool = false,
};

pub inline fn probeNamedDataProperty(
    rt: *core.JSRuntime,
    receiver: core.JSValue,
    atom_id: core.Atom,
) NamedDataPropertyProbe {
    if (atom_id.isTaggedInt() or rt.atoms.mightBePrivate(atom_id)) return .{ .needs_slow = true };
    const object = objectFromValueTrustedExpression(receiver) orelse return .{ .needs_slow = true };
    return probePublicNamedDataPropertyFromObject(object, atom_id);
}

/// Object-unpacked twin for internal algorithms that carry a known public,
/// non-index atom. JS_IsInstanceOf has already required an Object RHS before
/// requesting the predefined public Symbol.hasInstance key, exactly as QJS
/// does before JS_GetProperty.
pub inline fn probePublicNamedDataPropertyFromObject(
    initial_object: *core.Object,
    atom_id: core.Atom,
) NamedDataPropertyProbe {
    var object = initial_object;
    while (true) {
        var slow_property = false;
        if (object.findOwnDataSlotFast(atom_id, &slow_property)) |slot| return .{ .slot = slot };
        if (slow_property or object.needsSlowPropertyAccess()) return .{ .needs_slow = true };
        object = object.getPrototype() orelse return .{};
    }
}

noinline fn getValuePropertyNonObject(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.JSValue,
    atom_id: core.Atom,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const rt = ctx.runtime;
    if (rt.atoms.mightBePrivate(atom_id) and rt.atoms.kind(atom_id) == .private) return error.TypeError;
    if (value.isString()) {
        if (atom_id == core.atom.ids.length) return value_ops.length(value);
        if (try getStringIndexValue(rt, value, atom_id)) |indexed| return indexed;
        return getPrimitiveProperty(ctx, output, global, value, atom_id, caller_function, caller_frame);
    }
    if (value.isNumber() or value.is(.boolean) or value.isBigInt() or value.is(.symbol)) {
        return getPrimitiveProperty(ctx, output, global, value, atom_id, caller_function, caller_frame);
    }
    if (value.is(.null_value) or value.is(.undefined_value)) {
        return throwNullishPropertyTypeError(ctx, global, value, atom_id, .read);
    }
    return error.TypeError;
}

noinline fn functionCallerArgumentsProperty(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    object: *core.Object,
    atom_id: core.Atom,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    if (!core.class.isFunctionClass(object.class_id)) return null;
    // qjs gates the legacy accessors on an atom-id compare (`atom ==
    // JS_ATOM_caller`); both spellings are predefined atoms, so interning makes
    // the id test exact. Spelling out the bytes here made every property read
    // on every function object pay an atom-table name lookup plus two memcmps.
    if (atom_id != core.atom.ids.caller and atom_id != core.atom.ids.arguments) return null;
    if (try object.getOwnProperty(ctx.runtime, atom_id)) |own_desc| {
        switch (own_desc.kind) {
            .data => return own_desc.value,
            .generic => return core.JSValue.undefinedValue(),
            .accessor => {
                if (own_desc.getter.is(.undefined_value)) return core.JSValue.undefinedValue();
                return try callValueOrBytecodeSyncInternal(ctx, output, global, receiver, own_desc.getter, &.{}, caller_function, caller_frame);
            },
        }
    }
    // Legacy sloppy-function extension: an ordinary non-strict function
    // reads `caller`/`arguments` as undefined. Every other function has no
    // such property (§17.1) and takes the ordinary prototype walk, which
    // normally reaches %Function.prototype%'s %ThrowTypeError% accessors.
    const fb_value = object.functionBytecode() orelse return null;
    const fb = functionBytecodeFromValue(fb_value) orelse return null;
    if (object.class_id == core.class.ids.bytecode_function and fb.hasPrototype() and
        !fb.isStrictMode() and !fb.runtimeStrictMode())
    {
        return core.JSValue.undefinedValue();
    }
    return null;
}

noinline fn getPrivateValueProperty(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    object: *core.Object,
    atom_id: core.Atom,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    if (try object.getOwnProperty(ctx.runtime, atom_id)) |desc| {
        switch (desc.kind) {
            .data => return desc.value,
            .generic => return error.TypeError,
            .accessor => {
                if (desc.getter.is(.undefined_value)) return error.TypeError;
                return callValueOrBytecodeSyncInternal(ctx, output, global, receiver, desc.getter, &.{}, caller_function, caller_frame);
            },
        }
    }
    return throwPrivateBrandTypeError(ctx, global, atom_id, caller_frame);
}

pub fn setPrivateValueProperty(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    object: *core.Object,
    atom_id: core.Atom,
    value: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !void {
    if (try object.getOwnProperty(ctx.runtime, atom_id)) |desc| {
        switch (desc.kind) {
            .data => {
                if (!(desc.writable orelse false)) return error.TypeError;
                if (!try object.setOwnWritableDataProperty(ctx.runtime, atom_id, value)) return error.TypeError;
                return;
            },
            .generic => return error.TypeError,
            .accessor => {
                if (desc.setter.is(.undefined_value)) return error.TypeError;
                _ = try callValueOrBytecodeSyncInternal(ctx, output, global, receiver, desc.setter, &.{value}, caller_function, caller_frame);
                return;
            },
        }
    }
    _ = try throwPrivateBrandTypeError(ctx, global, atom_id, caller_frame);
}

pub fn getPrimitiveProperty(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    atom_id: core.Atom,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    if (try getFastStringPrimitiveDataProperty(ctx, global, receiver, atom_id)) |value| return value;

    // QuickJS JS_GetPropertyInternal selects ctx->class_proto directly for a
    // primitive and walks that object chain with the original primitive as the
    // receiver. Property reads must not materialize a transient boxed object;
    // boxing belongs to ToObject/OP_push_this and other observable conversions.
    const prototype = primitivePrototypeForAccess(ctx.runtime, global, receiver) orelse return core.JSValue.undefinedValue();
    if (try getPropertyValueFromObjectChain(ctx, output, global, receiver, prototype, atom_id, caller_function, caller_frame)) |value| return value;
    return core.JSValue.undefinedValue();
}

pub fn ownDataOrAutoInitPropertyValue(object: *core.Object, atom_id: core.Atom) !?core.JSValue {
    if (object.hasExoticMethods()) return null;
    if (object.findProperty(atom_id)) |index| {
        return switch (object.propKindAt(index)) {
            .data => object.propertyEntry(index).*.slot.data,
            .auto_init => try object.getProperty(atom_id),
            .var_ref, .accessor => null,
        };
    }
    return null;
}

/// `[[Get]]` with an explicit receiver (`super.x`, `Reflect.get(t, k, r)`):
/// qjs `JS_GetPropertyInternal(ctx, obj, prop, this_obj,...)`
/// threads `this_obj` through ONE shape/prototype walk, so an accessor found at
/// any depth is invoked on the receiver rather than on the holder.
///
/// zjs splits that into a descriptor walk here plus `getValueProperty` as the
/// tail. KNOWN COST: on a complete miss the same prototype chain is walked
/// twice, i.e. O(2 x chain) for `super.missing` and for a Proxy with no `get`
/// trap. The second pass is not redundant -- it is what supplies the entry-only
/// cases the descriptor walk cannot express (a private-name atom, and the
/// legacy `caller`/`arguments` compatibility properties on a function target) --
/// but it is deliberately kept as a whole re-entry rather than as a hand-picked
/// subset, because `getValueProperty` is the single authority on the order of
/// those entry checks against the ordinary walk. Note also that the tail passes
/// `target_value`, not `receiver_value`: anything it resolves is by definition
/// something the receiver-aware walk above already declined.
pub fn getValuePropertyWithReceiver(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    target_value: core.JSValue,
    target: *core.Object,
    receiver_value: core.JSValue,
    atom_id: core.Atom,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    var current: ?*core.Object = target;
    while (current) |object| : (current = object.getPrototype()) {
        if (object.proxyTarget() != null) return getProxyProperty(ctx, output, global, receiver_value, object, atom_id, caller_function, caller_frame);
        // TypedArray [[Get]] (§10.4.5.4): a canonical numeric key never
        // reaches the prototype chain.
        if (core.object.isTypedArrayObject(object)) {
            if (try typedArrayCanonicalGet(ctx.runtime, object, atom_id)) |indexed| return indexed;
        }
        if (try object.getOwnProperty(ctx.runtime, atom_id)) |desc| {
            switch (desc.kind) {
                .data => return desc.value,
                .generic => return core.JSValue.undefinedValue(),
                .accessor => {
                    if (desc.getter.is(.undefined_value)) return core.JSValue.undefinedValue();
                    return callValueOrBytecodeSyncInternal(ctx, output, global, receiver_value, desc.getter, &.{}, caller_function, caller_frame);
                },
            }
        }
    }
    // Miss: re-enter the general resolver for the entry-only cases (see the
    // doc comment above for why this second chain walk is intentional).
    return getValueProperty(ctx, output, global, target_value, atom_id, caller_function, caller_frame);
}

pub fn primitiveObjectForAccess(rt: *core.JSRuntime, global: *core.Object, primitive: core.JSValue) !core.JSValue {
    var values = [_]core.JSValue{ global.value(), primitive, core.JSValue.undefinedValue() };
    const slots: []core.JSValue = &values;
    const slices = [_]core.runtime.ValueRootSlice{.{ .mutable = &slots }};
    var root_frame = core.runtime.ValueRootFrame{ .slices = &slices };
    root_frame.activate(rt);
    defer root_frame.deactivate(rt);

    const prototype = primitivePrototypeForAccess(rt, objectFromValue(values[0]).?, values[1]) orelse return error.NullishToObject;
    if (values[1].isString()) {
        // Share the rooted, code-unit-based String wrapper construction path.
        return string_ops.constructWithPrototype(rt, values[1..2], prototype);
    }
    const class_id: core.class.ClassId = if (values[1].isNumber())
        core.class.ids.number
    else if (values[1].is(.boolean))
        core.class.ids.boolean
    else if (values[1].isBigInt())
        core.class.ids.big_int
    else if (values[1].is(.symbol))
        core.class.ids.symbol
    else
        return error.TypeError;
    values[2] = (try core.Object.create(rt, class_id, prototype)).value();
    const object = objectFromValue(values[2]).?;
    try object.setOptionalValueSlot(rt, object.objectDataSlot(), values[1]);
    return values[2];
}

test "primitiveObjectForAccess roots direct symbol while creating wrapper" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    const global = try core.Object.create(rt, core.class.ids.object, null);
    const symbol_constructor = try core.Object.create(rt, core.class.ids.object, null);
    const symbol_prototype = try core.Object.create(rt, core.class.ids.object, null);
    defer {
        rt.destroy();
    }

    try symbol_constructor.defineOwnProperty(
        rt,
        core.atom.ids.prototype,
        core.Descriptor.data(symbol_prototype.value(), .all),
    );
    const symbol_ctor_atom = try rt.internAtom("Symbol");
    try global.defineOwnProperty(
        rt,
        symbol_ctor_atom,
        core.Descriptor.data(symbol_constructor.value(), .all),
    );

    const symbol_atom = try rt.atoms.newValueSymbol("gc-primitive-wrapper-symbol");
    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const symbol_value = try rt.symbolValue(symbol_atom);
    const wrapper_value = try primitiveObjectForAccess(rt, global, symbol_value);
    const wrapper = objectFromValue(wrapper_value) orelse return error.TypeError;

    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    const stored = wrapper.objectData() orelse return error.TypeError;
    try std.testing.expect(stored.same(symbol_value));

    _ = try rt.collectForTest();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

pub fn setValueProperty(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    object_value: core.JSValue,
    atom_id: core.Atom,
    value: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) HostError!core.JSValue {
    return setValuePropertyWithThrow(ctx, output, global, object_value, atom_id, value, caller_function, caller_frame, false);
}

/// `setValueProperty` with an explicit throw override: `force_throw = true` is
/// the qjs `JS_PROP_THROW` discipline (spec `Set(O, P, V, true)`) used by the
/// array mutator builtins, which must surface element/length write failures
/// regardless of the calling code's strictness (qjs `JS_SetPropertyInt64` at
/// the js_array_* sites always throws on failure).
pub fn setValuePropertyWithThrow(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    object_value: core.JSValue,
    atom_id: core.Atom,
    value: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
    force_throw: bool,
) HostError!core.JSValue {
    const throw_on_set_failure = force_throw or setFailureShouldThrow(caller_function);
    if (ctx.runtime.atoms.kind(atom_id) == .private) {
        if (!object_value.is(.object)) return error.TypeError;
        const object = try property_ops.expectObject(object_value);
        try setPrivateValueProperty(ctx, output, global, object_value, object, atom_id, value, caller_function, caller_frame);
        return core.JSValue.undefinedValue();
    }
    const is_strict = if (caller_function) |func| functionRuntimeStrict(func) else false;
    // A number key's atom is fresh and held by nothing; boxing a primitive
    // base allocates, and setters and traps run JavaScript, before it is
    // stored or named in an error.
    var key_roots = core.runtime.rootAtoms(.{&atom_id});
    key_roots.activate(ctx.runtime);
    defer key_roots.deactivate(ctx.runtime);
    if (!object_value.is(.object)) {
        if (object_value.is(.null_value) or object_value.is(.undefined_value))
            return throwNullishPropertyTypeError(ctx, global, object_value, atom_id, .set);
        const boxed_value = try primitiveObjectForAccess(ctx.runtime, global, object_value);
        const boxed = try property_ops.expectObject(boxed_value);
        const succeeded = try ordinarySetWithReceiver(ctx, output, global, boxed, object_value, atom_id, value, caller_function, caller_frame);
        if (!succeeded and throw_on_set_failure) return throwSetFailureTypeError(ctx, global, atom_id, error.TypeError);
        return core.JSValue.undefinedValue();
    }
    const object = try property_ops.expectObject(object_value);
    if (object.proxyTarget() != null) {
        const ok = try proxySetValueProperty(ctx, output, global, object_value, object, atom_id, value, caller_function, caller_frame);
        if (!ok and throw_on_set_failure) return throwSetFailureTypeError(ctx, global, atom_id, error.TypeError);
        return core.JSValue.undefinedValue();
    }
    // A module namespace's [[Set]] always fails (§10.4.6.9), before any
    // binding is read: an export still in its TDZ must not throw ReferenceError.
    if (object.class_id == core.class.ids.module_ns) {
        if (throw_on_set_failure) return throwSetFailureTypeError(ctx, global, atom_id, error.ReadOnly);
        return core.JSValue.undefinedValue();
    }
    if (object.flags.is_with_environment and is_strict and !object.hasProperty(atom_id)) return error.ReferenceError;
    if (try setMappedArgumentsValue(ctx, object, atom_id, value)) return core.JSValue.undefinedValue();
    if (core.object.isTypedArrayObject(object)) {
        if (try array_ops.typedArrayNumericSet(ctx, output, global, object, object_value, atom_id, value, caller_function, caller_frame)) |ok| {
            if (!ok and throw_on_set_failure) return throwSetFailureTypeError(ctx, global, atom_id, error.ReadOnly);
            return core.JSValue.undefinedValue();
        }
    }
    if (object.isArray() and atom_id == core.atom.ids.length) {
        // OrdinarySetWithOwnDescriptor rejects a non-writable own `length`
        // before ArraySetLength converts the value.
        if (!object.flags.length_writable) {
            if (throw_on_set_failure) return throwSetFailureTypeError(ctx, global, atom_id, error.ReadOnly);
            return core.JSValue.undefinedValue();
        }
        const value_to_set = try arrayLengthAssignmentValue(ctx, output, global, object, atom_id, value);
        return storeOrdinaryProperty(ctx, global, object, atom_id, value_to_set, throw_on_set_failure);
    }
    if (object.isArray()) {
        if (core.array.arrayIndexFromAtom(ctx.runtime.atoms, atom_id)) |index| {
            if (try object.appendDenseArrayIndex(ctx.runtime, index, atom_id, value)) return core.JSValue.undefinedValue();
        }
    }
    // Single merged own probe (qjs JS_SetPropertyInternal runs ONE
    // find_own_property, quickjs.c): the old back-to-back
    // setOwnWritableDataProperty + defineNewOwnDataPropertyForSimpleSet pair
    // re-probed the same shape twice — once to classify the hit, once to
    // prove absence before the add.
    if (try object.setOrDefineOwnDataPropertyForSimpleSet(ctx.runtime, atom_id, value)) return core.JSValue.undefinedValue();
    if (try typedArrayPrototypeSet(ctx, output, global, object_value, object.getPrototype(), atom_id, value, caller_function, caller_frame)) |ok| {
        if (!ok and throw_on_set_failure) return throwSetFailureTypeError(ctx, global, atom_id, error.TypeError);
        return core.JSValue.undefinedValue();
    }
    const called_setter = callAccessorSetter(ctx, output, global, object_value, object, atom_id, value, caller_function, caller_frame) catch |err| switch (err) {
        error.AccessorWithoutSetter => {
            if (throw_on_set_failure) return throwSetFailureTypeError(ctx, global, atom_id, error.AccessorWithoutSetter);
            return core.JSValue.undefinedValue();
        },
        else => return err,
    };
    if (called_setter) return core.JSValue.undefinedValue();
    if (try firstProxyInPrototypeSetPath(ctx.runtime, object, atom_id)) |prototype_proxy| {
        const ok = try proxySetValueProperty(ctx, output, global, object_value, prototype_proxy, atom_id, value, caller_function, caller_frame);
        if (!ok and throw_on_set_failure) return throwSetFailureTypeError(ctx, global, atom_id, error.TypeError);
        return core.JSValue.undefinedValue();
    }
    const value_to_set = try arrayLengthAssignmentValue(ctx, output, global, object, atom_id, value);
    return storeOrdinaryProperty(ctx, global, object, atom_id, value_to_set, throw_on_set_failure);
}

/// The final ordinary [[Set]] store; a rejected write throws only when the
/// caller's mode requires it (strict code or `force_throw`).
fn storeOrdinaryProperty(
    ctx: *core.JSContext,
    global: *core.Object,
    object: *core.Object,
    atom_id: core.Atom,
    value: core.JSValue,
    throw_on_set_failure: bool,
) HostError!core.JSValue {
    object.setProperty(ctx.runtime, atom_id, value) catch |err| switch (err) {
        error.ReadOnly, error.AccessorWithoutSetter, error.NotExtensible, error.IncompatibleDescriptor => |e| {
            if (!throw_on_set_failure) return core.JSValue.undefinedValue();
            // A writable Array `length` rejects a shrink only at an element it
            // cannot delete (ArraySetLength step 17.b).
            if (e == error.IncompatibleDescriptor and object.isArray() and atom_id == core.atom.ids.length) {
                return throwTypeErrorMessage(ctx, global, "cannot delete a non-configurable array element");
            }
            return throwSetFailureTypeError(ctx, global, atom_id, e);
        },
        else => return err,
    };
    return core.JSValue.undefinedValue();
}

pub fn setWithOwnDescriptor(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver_value: core.JSValue,
    atom_id: core.Atom,
    value: core.JSValue,
    own_desc: core.Descriptor,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) HostError!bool {
    switch (own_desc.kind) {
        .accessor => {
            if (own_desc.setter.is(.undefined_value)) return false;
            _ = try callValueOrBytecodeSyncInternal(ctx, output, global, receiver_value, own_desc.setter, &.{value}, caller_function, caller_frame);
            return true;
        },
        .data, .generic => {
            if (own_desc.kind == .data and own_desc.writable == false) return false;
            const receiver = objectFromValue(receiver_value) orelse return false;
            const receiver_desc = try proxyAwareOwnPropertyDescriptor(ctx, output, global, receiver, atom_id, caller_function, caller_frame);
            if (receiver_desc) |desc| {
                if (desc.kind == .accessor) return false;
                if (desc.kind == .data and desc.writable == false) return false;
                const update_desc = core.Descriptor{
                    .kind = .data,
                    .value = value,
                    .value_present = true,
                };
                return try defineOwnPropertyVm(ctx, output, global, receiver, atom_id, update_desc, .return_false, caller_function, caller_frame);
            }
            return try defineOwnPropertyVm(ctx, output, global, receiver, atom_id, core.Descriptor.data(value, .all), .return_false, caller_function, caller_frame);
        },
    }
}

/// What `defineOwnPropertyVm` does when an ordinary define rejects.
pub const DefineRejection = enum {
    /// [[DefineOwnProperty]] proper: report `false`.
    return_false,
    /// DefinePropertyOrThrow callers: keep the specific error
    /// (`ReadOnly`, `NotExtensible`, `IncompatibleDescriptor`) so its message
    /// survives.
    keep_error,
};

/// O.[[DefineOwnProperty]](P, Desc) for any object: a Proxy's trap, a
/// TypedArray's canonical numeric keys, an Array's `length` through
/// ArraySetLength (which converts the value there, after ToPropertyDescriptor
/// and only on this path), else the ordinary define.
pub fn defineOwnPropertyVm(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    object: *core.Object,
    atom_id: core.Atom,
    desc: core.Descriptor,
    rejection: DefineRejection,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) HostError!bool {
    if (object.proxyTarget() != null) return try proxyDefineOwnProperty(ctx, output, global, object, atom_id, desc, caller_function, caller_frame);
    if (try typedArrayDefineOwnPropertyVm(ctx, output, global, object, atom_id, desc)) |ok| return ok;
    var define_desc = desc;
    if (desc.value_present) {
        define_desc.value = try arrayLengthAssignmentValue(ctx, output, global, object, atom_id, desc.value);
    }
    object.defineOwnProperty(ctx.runtime, atom_id, define_desc) catch |err| switch (err) {
        error.ReadOnly, error.NotExtensible, error.IncompatibleDescriptor => switch (rejection) {
            .return_false => return false,
            .keep_error => return err,
        },
        else => return err,
    };
    return true;
}

pub fn definePropertyWithKind(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    kind: i32,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    const target = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const object = core.value_semantics.objectFromValue(target) orelse return error.NotAnObject;
    const atom_id = try toPropertyKeyAtom(ctx, output, global, if (args.len >= 2) args[1] else core.JSValue.undefinedValue(), caller_function, caller_frame);
    const attributes = if (args.len >= 3) args[2] else core.JSValue.undefinedValue();
    const desc_object = core.value_semantics.objectFromValue(attributes) orelse return error.InvalidPropertyDescriptor;
    const desc = try descriptorFromObject(ctx, output, global, attributes, desc_object, object, atom_id, caller_function, caller_frame);
    // Reflect.defineProperty (kind 2) reports failure as `false`.
    const defined = defineOwnPropertyVm(ctx, output, global, object, atom_id, desc, .keep_error, caller_function, caller_frame) catch |err| switch (err) {
        error.IncompatibleDescriptor, error.NotExtensible, error.ReadOnly => if (kind == 2) return core.JSValue.boolean(false) else return err,
        else => return err,
    };
    if (!defined) {
        if (kind == 2) return core.JSValue.boolean(false);
        return error.CannotDefineProperty;
    }
    if (kind == 2) return core.JSValue.boolean(true);
    return args[0];
}

pub const PendingPropertyDescriptor = struct {
    atom_id: core.Atom,
    desc: core.Descriptor,
};

/// One outlined own-properties walk (ToObject + [[OwnPropertyKeys]] + array
/// fill) for Object.keys/values/entries and getOwnPropertyNames/Symbols.
/// keys/values/entries check enumerability; names/symbols filter strings vs
/// symbols.
pub const OwnPropertiesKind = enum { keys, values, entries, own_names, own_symbols };

pub fn objectEnumerableOwnPropertiesCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    kind: OwnPropertiesKind,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    if (args.len < 1 or args[0].is(.null_value) or args[0].is(.undefined_value)) return error.NullishToObject;

    var object_value = if (objectFromValue(args[0])) |_| args[0] else try primitiveObjectForAccess(ctx.runtime, global, args[0]);
    const object = objectFromValue(object_value) orelse return error.TypeError;
    const keys = try objectRestOwnKeys(ctx, output, global, object);
    defer core.Object.freeKeys(ctx.runtime, keys);
    // A Proxy ownKeys result lives only in this native list across the
    // traps and allocations below; keep its atoms alive.
    var keys_roots = core.runtime.rootAtomList(&keys);
    keys_roots.activate(ctx.runtime);
    defer keys_roots.deactivate(ctx.runtime);

    const out = try core.Object.createArray(ctx.runtime, arrayPrototypeFromGlobal(ctx.runtime, global));
    errdefer core.Object.destroyFromHeader(ctx.runtime, out.gcHeader());
    var out_value = out.value();

    var element = core.JSValue.undefinedValue();

    var root_frame = core.runtime.rootValues(.{ &object_value, &out_value, &element });
    root_frame.activate(ctx.runtime);
    defer root_frame.deactivate(ctx.runtime);

    for (keys) |key| {
        try exception_ops.pollNativeLoop(ctx, global);
        const is_symbol = ctx.runtime.atoms.isPublicSymbol(key);
        switch (kind) {
            .own_names => {
                if (is_symbol) continue;
                element = try ctx.runtime.atoms.toStringValue(ctx.runtime, key);
            },
            .own_symbols => {
                if (!is_symbol) continue;
                element = try ctx.runtime.symbolValue(key);
            },
            .keys, .values, .entries => {
                if (is_symbol) continue;
                const desc = try objectRestOwnPropertyDescriptor(ctx, output, global, object, key) orelse continue;
                if (desc.enumerable != true) continue;
                element = switch (kind) {
                    .keys => try ctx.runtime.atoms.toStringValue(ctx.runtime, key),
                    .values => try getValueProperty(ctx, output, global, object_value, key, caller_function, caller_frame),
                    .entries => try objectEntryArrayValue(ctx, output, global, object_value, key, caller_function, caller_frame),
                    .own_names, .own_symbols => unreachable,
                };
            },
        }
        errdefer {
            element = core.JSValue.undefinedValue();
        }
        try createDataPropertyOrThrow(ctx, output, global, out, core.Atom.taggedInt(out.arrayLength()), element, caller_function, caller_frame);
        element = core.JSValue.undefinedValue();
    }
    return out_value;
}

pub fn objectProtoGetterCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    if (this_value.is(.null_value) or this_value.is(.undefined_value)) return error.NullishToObject;
    const object_value = if (objectFromValue(this_value)) |_| this_value else try primitiveObjectForAccess(ctx.runtime, global, this_value);
    const object = objectFromValue(object_value) orelse return error.TypeError;
    return objectGetPrototypeOfValue(ctx, output, global, object, caller_function, caller_frame);
}

pub fn objectProtoSetterCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    prototype_value: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    if (this_value.is(.null_value) or this_value.is(.undefined_value)) return error.NullishToObject;
    if (!prototype_value.is(.null_value) and objectFromValue(prototype_value) == null) return core.JSValue.undefinedValue();
    if (objectFromValue(this_value) == null) return core.JSValue.undefinedValue();
    var args = [_]core.JSValue{ this_value, prototype_value };
    _ = try objectSetPrototypeOfCall(ctx, output, global, &args, caller_function, caller_frame);
    return core.JSValue.undefinedValue();
}

/// Object/Reflect.isExtensible: argument admission here, then the outlined
/// `proxyAwareExtensibleOp` walk (proxy trap + invariant check).
pub inline fn objectIsExtensibleCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    const target_value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const object = objectFromValue(target_value) orelse return core.JSValue.boolean(false);
    return core.JSValue.boolean(try proxyAwareIsExtensible(ctx, output, global, object, caller_function, caller_frame));
}

pub fn objectSetPrototypeOfCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    const target = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const prototype_value = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
    if (target.is(.null_value) or target.is(.undefined_value)) return try throwTypeErrorMessage(ctx, global, "not an object");
    const prototype: ?*core.Object = if (prototype_value.is(.null_value))
        null
    else
        objectFromValue(prototype_value) orelse return try throwTypeErrorMessage(ctx, global, "not an object");
    const object = objectFromValue(target) orelse return target;
    if (object.proxyTarget() == null and objectHasImmutablePrototype(object) and object.getPrototype() != prototype)
        return try throwTypeErrorMessage(ctx, global, "prototype is immutable");
    if (object.proxyTarget() != null) {
        if (!try proxyAwareSetPrototypeOf(ctx, output, global, object, prototype, caller_function, caller_frame))
            return try throwTypeErrorMessage(ctx, global, "proxy: setPrototypeOf trap returned false");
        return target;
    }
    object.setPrototype(ctx.runtime, prototype) catch |err| switch (err) {
        // Throw via the callee realm's global (threaded in as `global`) so a
        // cross-realm `gw.Object.setPrototypeOf(...)` produces gw's TypeError.
        // A bare `return error.TypeError` would materialize at the VM catch
        // against the caller realm (ctx.global), which is the wrong realm.
        error.PrototypeCycle => return @as(?core.JSValue, try throwTypeErrorMessage(ctx, global, "circular prototype chain")),
        error.NotExtensible => return @as(?core.JSValue, try throwTypeErrorMessage(ctx, global, "prototype is not extensible")),
        else => return err,
    };
    return target;
}

pub fn reflectSetPrototypeOfCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const object = objectFromValue(args[0]) orelse return try throwTypeErrorMessage(ctx, global, "not an object");
    const prototype_value = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
    const prototype: ?*core.Object = if (prototype_value.is(.null_value))
        null
    else
        objectFromValue(prototype_value) orelse return try throwTypeErrorMessage(ctx, global, "not an object");
    if (object.proxyTarget() == null and objectHasImmutablePrototype(object) and object.getPrototype() != prototype) return core.JSValue.boolean(false);
    if (object.proxyTarget() != null) {
        return core.JSValue.boolean(try proxyAwareSetPrototypeOf(ctx, output, global, object, prototype, caller_function, caller_frame));
    }
    object.setPrototype(ctx.runtime, prototype) catch |err| switch (err) {
        error.PrototypeCycle, error.NotExtensible => return core.JSValue.boolean(false),
        else => return err,
    };
    return core.JSValue.boolean(true);
}

pub fn reflectConstructPrototypeVm(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    target_name: []const u8,
    new_target: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !?*core.Object {
    // An own data `.prototype` object is what [[Get]] would return.
    if (objectFromValue(new_target)) |object| {
        if (object.getOwnDataObjectBorrowed(core.atom.ids.prototype)) |prototype| return prototype;
    }
    const prototype_value = try getValueProperty(ctx, output, global, new_target, core.atom.ids.prototype, caller_function, caller_frame);
    if (prototype_value.is(.object)) return objectFromValue(prototype_value);
    const fallback_realm = try functionRealmContext(ctx, new_target);
    if (constructorClassPrototypeId(target_name)) |class_id| {
        return fallback_realm.classPrototypeObject(class_id) orelse return error.InvalidBuiltinRegistry;
    }

    // Native Error subclasses live in the realm `native_error_proto[]` family,
    // not the class-prototype table. GetPrototypeFromConstructor still has to
    // use that intrinsic when `newTarget.prototype` is not an object.
    if (nativeErrorKindFromConstructorName(target_name)) |kind| {
        return fallback_realm.nativeErrorPrototypeObject(kind) orelse return error.InvalidBuiltinRegistry;
    }
    return null;
}

fn objectHasImmutablePrototype(object: *core.Object) bool {
    return object.hasImmutablePrototype();
}

pub fn reflectDeletePropertyCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    // A missing target is not an Object; a missing key is ToPropertyKey(undefined).
    const object = objectFromValue(if (args.len >= 1) args[0] else core.JSValue.undefinedValue()) orelse return error.NotAnObject;
    const atom_id = try toPropertyKeyAtom(ctx, output, global, if (args.len >= 2) args[1] else core.JSValue.undefinedValue(), caller_function, caller_frame);
    return core.JSValue.boolean(try deleteValueProperty(ctx, output, global, object, atom_id, caller_function, caller_frame));
}

pub fn reflectGetOwnPropertyDescriptorCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    // A missing target is not an Object; a missing key is ToPropertyKey(undefined).
    const object = objectFromValue(if (args.len >= 1) args[0] else core.JSValue.undefinedValue()) orelse return error.NotAnObject;
    const atom_id = try toPropertyKeyAtom(ctx, output, global, if (args.len >= 2) args[1] else core.JSValue.undefinedValue(), caller_function, caller_frame);
    var desc = try proxyAwareOwnPropertyDescriptor(ctx, output, global, object, atom_id, caller_function, caller_frame) orelse return core.JSValue.undefinedValue();
    call.materializeMappedArgumentsDescriptorValue(ctx.runtime, object, atom_id, &desc);
    return try descriptorObjectFromDescriptor(ctx.runtime, global, desc);
}

pub fn reflectGetPrototypeOfCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    if (args.len < 1) return error.NotAnObject;
    const object = objectFromValue(args[0]) orelse return error.NotAnObject;
    return try objectGetPrototypeOfValue(ctx, output, global, object, caller_function, caller_frame);
}

pub fn descriptorObjectFromDescriptor(rt: *core.JSRuntime, global: *core.Object, desc: core.Descriptor) !core.JSValue {
    const globals = [_]core.JSValue{global.value()};
    var values = [_]core.JSValue{ desc.value, desc.getter, desc.setter, core.JSValue.undefinedValue() };
    const live: []core.JSValue = &values;
    const slices = [_]core.runtime.ValueRootSlice{ .{ .borrowed = &globals }, .{ .mutable = &live } };
    var root_frame = core.runtime.ValueRootFrame{ .slices = &slices };
    root_frame.activate(rt);
    defer root_frame.deactivate(rt);

    values[3] = (try core.Object.create(rt, core.class.ids.object, objectPrototypeFromGlobal(rt, global))).value();
    if (desc.kind == .data and desc.value_present) {
        try defineValueProperty(rt, objectFromValue(values[3]).?, core.atom.ids.value, values[0]);
    } else if (desc.kind == .accessor) {
        if (desc.getter_present) try defineValueProperty(rt, objectFromValue(values[3]).?, core.atom.ids.get, values[1]);
        if (desc.setter_present) try defineValueProperty(rt, objectFromValue(values[3]).?, core.atom.ids.set, values[2]);
    }
    if (desc.writable) |writable| try defineValueProperty(rt, objectFromValue(values[3]).?, core.atom.ids.writable, core.JSValue.boolean(writable));
    if (desc.enumerable) |enumerable| try defineValueProperty(rt, objectFromValue(values[3]).?, core.atom.ids.enumerable, core.JSValue.boolean(enumerable));
    if (desc.configurable) |configurable| try defineValueProperty(rt, objectFromValue(values[3]).?, core.atom.ids.configurable, core.JSValue.boolean(configurable));
    return values[3];
}

test "descriptorObjectFromDescriptor roots direct function bytecode value while creating descriptor object" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const global = try core.Object.create(rt, core.class.ids.object, null);

    const symbol_atom = try rt.atoms.newValueSymbol("gc-descriptor-object-value-bytecode-symbol");
    const fb = try bytecode.FunctionBytecode.createPublishedFixture(rt, .{ .cpool_count = 1 }, &.{try rt.symbolValue(symbol_atom)});

    const desc_value = core.JSValue.functionBytecode(&fb.header);

    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const descriptor_value = try descriptorObjectFromDescriptor(
        rt,
        global,
        core.Descriptor.data(desc_value, .all),
    );
    const descriptor = objectFromValue(descriptor_value) orelse return error.TypeError;

    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    const value_key = try rt.internAtom("value");
    {
        const stored = try descriptor.getProperty(value_key);
        try std.testing.expect(stored.same(desc_value));
    }

    _ = try rt.collectForTest();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

pub fn descriptorFromObject(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    desc_value: core.JSValue,
    desc_object: *core.Object,
    target: *core.Object,
    atom_id: core.Atom,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.Descriptor {
    // Inputs are borrowed through the by-value API; descriptor fields are
    // mutable roots because later getters can detach their original edges.
    const borrowed = [_]core.JSValue{ global.value(), desc_value, desc_object.value(), target.value() };
    var fields = [_]core.JSValue{core.JSValue.undefinedValue()} ** 3;
    const live: []core.JSValue = &fields;
    const slices = [_]core.runtime.ValueRootSlice{ .{ .borrowed = &borrowed }, .{ .mutable = &live } };
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(ctx.runtime);
    defer roots.deactivate(ctx.runtime);
    var atom_roots = core.runtime.rootAtoms(.{&atom_id});
    atom_roots.activate(ctx.runtime);
    defer atom_roots.deactivate(ctx.runtime);

    const value_key = core.atom.ids.value;
    const writable_key = core.atom.ids.writable;
    const get_key = core.atom.ids.get;
    const set_key = core.atom.ids.set;
    const enumerable_key = core.atom.ids.enumerable;
    const configurable_key = core.atom.ids.configurable;

    const enumerable = try optionalBoolDescriptorProperty(ctx, output, global, desc_value, desc_object, enumerable_key, caller_function, caller_frame);
    const configurable = try optionalBoolDescriptorProperty(ctx, output, global, desc_value, desc_object, configurable_key, caller_function, caller_frame);

    const has_value = try hasValueProperty(ctx, output, global, desc_object, value_key, null, null);
    if (has_value) fields[0] = try getValueProperty(ctx, output, global, desc_value, value_key, caller_function, caller_frame);

    const has_writable = try hasValueProperty(ctx, output, global, desc_object, writable_key, null, null);
    const writable = if (has_writable) blk: {
        const writable_value = try getValueProperty(ctx, output, global, desc_value, writable_key, caller_function, caller_frame);
        break :blk valueTruthy(writable_value);
    } else null;

    const has_get = try hasValueProperty(ctx, output, global, desc_object, get_key, null, null);
    if (has_get) {
        const value = try getValueProperty(ctx, output, global, desc_value, get_key, caller_function, caller_frame);
        if (!value.is(.undefined_value) and !isCallableValue(value)) {
            return error.InvalidAccessor;
        }
        fields[1] = value;
    }

    const has_set = try hasValueProperty(ctx, output, global, desc_object, set_key, null, null);
    if (has_set) {
        const value = try getValueProperty(ctx, output, global, desc_value, set_key, caller_function, caller_frame);
        if (!value.is(.undefined_value) and !isCallableValue(value)) {
            return error.InvalidAccessor;
        }
        fields[2] = value;
    }

    if ((has_get or has_set) and (has_value or has_writable)) return error.MixedPropertyDescriptor;
    if (has_get or has_set) {
        return .{
            .kind = .accessor,
            .getter = fields[1],
            .getter_present = has_get,
            .setter = fields[2],
            .setter_present = has_set,
            .enumerable = enumerable,
            .configurable = configurable,
        };
    }
    if (has_value or has_writable) {
        // ToPropertyDescriptor does not convert: an Array `length` value is
        // converted by ArraySetLength, inside [[DefineOwnProperty]]
        // (`defineOwnPropertyVm`).
        return .{
            .kind = .data,
            .value = fields[0],
            .value_present = has_value,
            .writable = writable,
            .enumerable = enumerable,
            .configurable = configurable,
        };
    }
    return core.Descriptor.generic(enumerable, configurable);
}

pub fn optionalBoolDescriptorProperty(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    desc_value: core.JSValue,
    desc_object: *core.Object,
    atom_id: core.Atom,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !?bool {
    if (!try hasValueProperty(ctx, output, global, desc_object, atom_id, null, null)) return null;
    const value = try getValueProperty(ctx, output, global, desc_value, atom_id, caller_function, caller_frame);
    return valueTruthy(value);
}

inline fn getPropertyValueFromObjectChain(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    first: *core.Object,
    atom_id: core.Atom,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    var current: ?*core.Object = first;
    while (current) |prototype| : (current = prototype.getPrototype()) {
        // qjs JS_GetPropertyInternal always probes the ordinary shape FIRST,
        // for every class, and only enters its exotic arm after a miss. A
        // normal data/accessor hit therefore pays no Proxy/class-policy test.
        // Keep the paired shape/value result so the matching entry is read
        // once and only the live getter is retained.
        const shape_lookup = prototype.findOwnPropertySlotTrusted(atom_id);
        if (shape_lookup) |lookup| {
            switch (lookup.flags.kind) {
                .data => return lookup.entry.slot.data,
                .accessor => {
                    const getter = lookup.entry.slot.accessor.getterValue();
                    if (getter.is(.undefined_value)) return core.JSValue.undefinedValue();
                    // K3 native getter: direct native terminal (design §8.2).
                    if (builtin_dispatch.tryNativeAccessorCall(ctx, output, global, receiver, getter, &.{}, caller_function, caller_frame, .getter)) |native_result| return try native_result;
                    return try callValueOrBytecodeSyncInternal(ctx, output, global, receiver, getter, &.{}, caller_function, caller_frame);
                },
                // Auto-init materialization and var-ref/TDZ handling remain
                // centralized in getOwnProperty, exactly like qjs's retry and
                // VARREF branches after find_own_property.
                .auto_init, .var_ref => {},
            }
        }
        if (shape_lookup == null and !prototype.needsSlowPropertyAccess()) continue;
        if (try getSlowPropertyValueFromObject(ctx, output, global, receiver, prototype, atom_id, caller_function, caller_frame)) |value| return value;
    }
    return null;
}

/// Class/exotic synthesis and shape kinds that require materialization are the
/// slow arm after QuickJS's `find_own_property` miss/non-normal result. Keep
/// them out of the ordinary shape-loop frame without changing their order.
noinline fn getSlowPropertyValueFromObject(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    object: *core.Object,
    atom_id: core.Atom,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    if (object.class_id == core.class.ids.proxy) {
        return try getProxyProperty(ctx, output, global, receiver, object, atom_id, caller_function, caller_frame);
    }
    // qjs JS_GetPropertyInternal after find_own miss: `is_exotic && fast_array`.
    // TypedArray elements never occupy a shape slot, so
    // this arm is independent of whether `object` is the original receiver —
    // a proto-chain TypedArray must still answer canonical numeric indices
    // (in-range load, OOB / non-canonical numeric → undefined) before the
    // walk continues. Receiver-side `getValueProperty` already has the same
    // call; HAS's proto walk has `typedArrayCanonicalHas`.
    if (core.object.isTypedArrayObject(object)) {
        if (try typedArrayCanonicalGet(ctx.runtime, object, atom_id)) |indexed| return indexed;
    }
    if (try object.getOwnProperty(ctx.runtime, atom_id)) |desc| {
        switch (desc.kind) {
            .data => return desc.value,
            .generic => return core.JSValue.undefinedValue(),
            .accessor => {
                if (desc.getter.is(.undefined_value)) return core.JSValue.undefinedValue();
                return try callValueOrBytecodeSyncInternal(ctx, output, global, receiver, desc.getter, &.{}, caller_function, caller_frame);
            },
        }
    }
    return null;
}

pub fn getSuperPropertyValue(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    prototype: *core.Object,
    atom_id: core.Atom,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    // The home object's [[Prototype]].[[Get]](key, thisValue) (§13.3.7.1).
    return getValuePropertyWithReceiver(ctx, output, global, prototype.value(), prototype, receiver, atom_id, caller_function, caller_frame);
}

pub fn setSuperPropertyValue(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    prototype: *core.Object,
    atom_id: core.Atom,
    value: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !void {
    // PutValue on a super reference: HomeObject.[[Prototype]].[[Set]](P, V,
    // thisValue); the receiver itself is only ever defined on, never [[Set]].
    if (!try reflect_ops.setWithReceiver(ctx, output, global, prototype, receiver, atom_id, value, caller_function, caller_frame) and
        setFailureShouldThrow(caller_function))
    {
        _ = try throwSetFailureTypeError(ctx, global, atom_id, error.TypeError);
    }
}

pub fn findPropertyDescriptor(rt: *core.JSRuntime, object: *core.Object, atom_id: core.Atom) !?core.Descriptor {
    var current: ?*core.Object = object;
    while (current) |candidate| : (current = candidate.getPrototype()) {
        if (try candidate.getOwnProperty(rt, atom_id)) |desc| return desc;
    }
    return null;
}

pub fn sameObjectIdentity(a: core.JSValue, b: core.JSValue) bool {
    if (!a.is(.object) or !b.is(.object)) return false;
    const a_header = a.refHeader() orelse return false;
    const b_header = b.refHeader() orelse return false;
    return a_header == b_header;
}

/// `with`-scope [[HasProperty]]: `expectObject` on the incoming value, then
/// the outlined `hasValueProperty` walk (including the proxy `has` trap).
pub inline fn hasPropertyForWith(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    object_value: core.JSValue,
    atom_id: core.Atom,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) HostError!bool {
    const object = try property_ops.expectObject(object_value);
    return hasValueProperty(ctx, output, global, object, atom_id, caller_function, caller_frame);
}

pub fn hasValueProperty(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    object: *core.Object,
    atom_id: core.Atom,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) HostError!bool {
    const target_value = object.proxyTarget() orelse return ordinaryHasValueProperty(ctx, output, global, object, atom_id, caller_function, caller_frame);
    const target = try property_ops.expectObject(target_value);
    // The key may be a fresh atom (a number key) that nothing else holds,
    // and the trap lookup and call below run JavaScript.
    var key_roots = core.runtime.rootAtoms(.{&atom_id});
    key_roots.activate(ctx.runtime);
    defer key_roots.deactivate(ctx.runtime);
    const handler_value = try proxyHandlerForTrap(ctx, global, object);
    const has_atom = core.atom.ids.has;
    const trap = try getValueProperty(ctx, output, global, handler_value, has_atom, caller_function, caller_frame);
    if (trap.is(.undefined_value) or trap.is(.null_value)) {
        return hasValueProperty(ctx, output, global, target, atom_id, caller_function, caller_frame);
    }
    const key_value = try proxyTrapKeyValue(ctx.runtime, atom_id);
    const result = try callValueOrBytecodeSyncInternal(ctx, output, global, handler_value, trap, &.{ target_value, key_value }, caller_function, caller_frame);
    return try validateProxyHasResult(ctx, output, global, target, atom_id, valueTruthy(result), caller_function, caller_frame);
}

pub fn ordinaryHasValueProperty(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    object: *core.Object,
    atom_id: core.Atom,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !bool {
    // Module namespace [[HasProperty]] tests only the exported-key set. It
    // must not route through [[GetOwnProperty]], whose descriptor construction
    // reads the live binding and would throw for a still-uninitialized export.
    if (object.class_id == core.class.ids.module_ns) {
        return object.hasOwnProperty(atom_id);
    }
    if (typedArrayCanonicalHas(ctx.runtime, object, atom_id)) |has| return has;
    if (indexedExoticHasProperty(ctx.runtime, object, atom_id)) return true;
    // Use existsOwnProperty (qjs JS_GetOwnPropertyInternal desc==NULL mode)
    // instead of getOwnProperty + destroy: the HasProperty trap only needs
    // existence, not a materialized Descriptor. getOwnProperty calls
    // descriptorFromOwnPropertySlot which dups the value — pure waste here
    // since the descriptor is immediately destroyed. This was ~5.5% of pdfjs
    // self-time (ordinaryHasValueProperty 13 + getOwnProperty 16 samples).
    if (try object.existsOwnProperty(ctx.runtime, atom_id)) return true;

    var current = object.getPrototype();
    while (current) |proto| : (current = proto.getPrototype()) {
        if (proto.proxyTarget() != null) {
            return try hasValueProperty(ctx, output, global, proto, atom_id, caller_function, caller_frame);
        }
        if (proto.class_id == core.class.ids.module_ns) {
            return proto.hasOwnProperty(atom_id);
        }
        if (typedArrayCanonicalHas(ctx.runtime, proto, atom_id)) |has| return has;
        if (indexedExoticHasProperty(ctx.runtime, proto, atom_id)) return true;
        if (try proto.existsOwnProperty(ctx.runtime, atom_id)) return true;
    }
    return false;
}

pub fn indexedExoticHasProperty(rt: *core.JSRuntime, object: *core.Object, atom_id: core.Atom) bool {
    if (stringObjectHasIndexProperty(rt, object, atom_id)) return true;
    if (!core.object.isTypedArrayObject(object)) return false;
    return typedArrayCanonicalHas(rt, object, atom_id) orelse false;
}

pub fn deleteValuePropertyOrThrow(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    object: *core.Object,
    atom_id: core.Atom,
) !void {
    if (!try deleteValueProperty(ctx, output, global, object, atom_id, null, null)) return error.CannotDeleteProperty;
}

pub fn deleteValueProperty(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    object: *core.Object,
    atom_id: core.Atom,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !bool {
    const target_value = object.proxyTarget() orelse {
        // TypedArray [[Delete]] (§10.4.5.6): canonical numeric keys are
        // never deletable in range and always "deleted" out of range.
        if (try typedArrayCanonicalDelete(ctx.runtime, object, atom_id)) |deleted| return deleted;
        return try object.deleteProperty(ctx.runtime, atom_id);
    };
    const target = try property_ops.expectObject(target_value);
    // The key may be a fresh atom (a number key) that nothing else holds,
    // and the trap lookup and call below run JavaScript.
    var key_roots = core.runtime.rootAtoms(.{&atom_id});
    key_roots.activate(ctx.runtime);
    defer key_roots.deactivate(ctx.runtime);
    const handler_value = try proxyHandlerForTrap(ctx, global, object);
    const delete_atom = core.atom.ids.deleteProperty;
    const trap = try getValueProperty(ctx, output, global, handler_value, delete_atom, caller_function, caller_frame);
    if (trap.is(.undefined_value) or trap.is(.null_value)) {
        return deleteValueProperty(ctx, output, global, target, atom_id, caller_function, caller_frame);
    }
    const key_value = try proxyTrapKeyValue(ctx.runtime, atom_id);
    const result = try callValueOrBytecodeSyncInternal(ctx, output, global, handler_value, trap, &.{ target_value, key_value }, caller_function, caller_frame);
    if (!valueTruthy(result)) return false;
    // js_proxy_delete_property: the target desc is read via
    // JS_GetOwnPropertyInternal (exotic — a nested-proxy target fires its own
    // gopd trap); a non-configurable desc throws, then extensibility is
    // consulted via JS_IsExtensible (exotic — the target's isExtensible trap
    // DOES fire here, unlike js_proxy_has).
    if (try proxyAwareOwnPropertyDescriptor(ctx, output, global, target, atom_id, caller_function, caller_frame)) |desc| {
        if (desc.configurable == false) return error.ProxyInvariantViolation;
        if (!try proxyAwareIsExtensible(ctx, output, global, target, caller_function, caller_frame)) return error.ProxyInvariantViolation;
    }
    return true;
}

pub fn defineValueProperty(rt: *core.JSRuntime, object: *core.Object, key: core.Atom, value: core.JSValue) !void {
    try object.defineOwnProperty(rt, key, core.Descriptor.data(value, .all));
}

pub fn defineFunctionNameProperty(rt: *core.JSRuntime, object: *core.Object, value: core.JSValue) !void {
    if (try objectHasNonEmptyName(rt, object)) return;
    const key = core.atom.ids.name;
    try object.defineOwnProperty(rt, key, core.Descriptor.data(value, .{ .configurable = true }));
}

pub fn objectHasNonEmptyName(rt: *core.JSRuntime, object: *core.Object) !bool {
    const existing = (try object.getOwnProperty(rt, core.atom.ids.name)) orelse return false;
    if (existing.kind != .data or !existing.value.isString()) return false;
    return core.string.stringValueLen(existing.value) != 0;
}

pub const NullishAccess = enum { read, set };

/// TypeError for a property access on `null`/`undefined`, e.g.
/// "cannot read property 'x' of undefined".
pub fn throwNullishPropertyTypeError(ctx: *core.JSContext, global: *core.Object, value: core.JSValue, atom_id: core.Atom, access: NullishAccess) !core.JSValue {
    const property_name = try atomPropertyName(ctx.runtime, atom_id);
    defer ctx.runtime.nativeAllocator().free(property_name);
    return throwNullishAccessMessage(ctx, global, value, property_name, access);
}

pub fn throwNullishComputedPropertyTypeError(ctx: *core.JSContext, global: *core.Object, value: core.JSValue, key: core.JSValue, access: NullishAccess) !core.JSValue {
    var property_name = std.ArrayList(u8).empty;
    defer property_name.deinit(ctx.runtime.nativeAllocator());
    try value_ops.appendValueString(ctx.runtime, &property_name, key);
    return throwNullishAccessMessage(ctx, global, value, property_name.items, access);
}

fn throwNullishAccessMessage(ctx: *core.JSContext, global: *core.Object, value: core.JSValue, property_name: []const u8, access: NullishAccess) !core.JSValue {
    const base = if (value.is(.null_value)) "null" else "undefined";
    const message = try std.fmt.allocPrint(
        ctx.runtime.nativeAllocator(),
        "cannot {s} property '{s}' of {s}",
        .{ @tagName(access), property_name, base },
    );
    defer ctx.runtime.nativeAllocator().free(message);
    return throwTypeErrorMessage(ctx, global, message);
}

pub fn atomPropertyName(rt: *core.JSRuntime, atom_id: core.Atom) ![]const u8 {
    if (atom_id.isTaggedInt()) {
        return try std.fmt.allocPrint(rt.nativeAllocator(), "{d}", .{atom_id.toUInt32()});
    }
    const name = rt.atoms.name(atom_id) orelse "";
    return try rt.nativeAllocator().dupe(u8, name);
}

// --- Combined from class.zig ---

pub noinline fn getSuper(vm: *Vm) HostError!void {
    const stack = vm.stack;
    const source_from_stack = stack.len() != 0;
    const source = if (source_from_stack) try stack.pop() else vm.frame.current_function;
    const function_object = core.value_semantics.objectFromValue(source) orelse {
        try stack.pushOwned(core.JSValue.undefinedValue());
        return;
    };
    if (source_from_stack) {
        if (function_object.getPrototype()) |prototype| {
            try stack.push(prototype.value());
        } else {
            try stack.pushOwned(core.JSValue.nullValue());
        }
        return;
    }
    const home_object = function_object.functionHomeObject() orelse {
        if (function_object.getPrototype()) |prototype| {
            try stack.push(prototype.value());
        } else {
            try stack.pushOwned(core.JSValue.nullValue());
        }
        return;
    };
    if (home_object.getPrototype()) |prototype| {
        try stack.push(prototype.value());
    } else {
        try stack.pushOwned(core.JSValue.nullValue());
    }
}

/// Route an opcode's error to the frame's catch handler: success when a
/// handler took it, the error otherwise.
pub fn catchVmError(vm: *Vm, err: HostError) HostError!void {
    if (try call_runtime.handleCatchableRuntimeError(vm.ctx, vm.output, vm.stack, vm.frame, vm.catch_target, vm.global, err)) return;
    return err;
}

/// Deliver a `throw*Message` result to the running frame's catch handler.
/// `thrown` always fails; this only routes that error.
pub fn catchableThrow(vm: *Vm, thrown: HostError!core.JSValue) HostError!void {
    _ = thrown catch |err| return catchVmError(vm, err);
    unreachable;
}

pub noinline fn getSuperValue(vm: *Vm) HostError!void {
    const ctx = vm.ctx;
    const output = vm.output;
    const global = vm.global;
    const stack = vm.stack;
    const frame = vm.frame;
    const prop_value = try stack.pop();
    const obj = try stack.pop();
    const receiver = try stack.pop();
    if (property_ops.adapterValueIsUninitialized(receiver)) {
        return catchVmError(vm, error.ReferenceError);
    }
    const atom_id = toPropertyKeyAtom(ctx, output, global, prop_value, vm.function, frame) catch |err| return catchVmError(vm, err);
    if (obj.is(.undefined_value) or obj.is(.null_value))
        return catchableThrow(vm, throwNullishPropertyTypeError(ctx, global, obj, atom_id, .read));

    const prototype = try property_ops.expectObject(obj);
    const value = getSuperPropertyValue(ctx, output, global, receiver, prototype, atom_id, vm.function, frame) catch |err| return catchVmError(vm, err);
    try stack.push(value);
}

pub noinline fn putSuperValue(vm: *Vm) HostError!void {
    const ctx = vm.ctx;
    const output = vm.output;
    const global = vm.global;
    const stack = vm.stack;
    const function = vm.function;
    const frame = vm.frame;
    const value = try stack.pop();
    const prop_value = try stack.pop();
    const obj = try stack.pop();
    const receiver = try stack.pop();
    if (property_ops.adapterValueIsUninitialized(receiver)) {
        return catchVmError(vm, error.ReferenceError);
    }
    // PutValue converts the key before ToObject rejects a null home prototype.
    const atom_id = toPropertyKeyAtom(ctx, output, global, prop_value, function, frame) catch |err| return catchVmError(vm, err);
    if (obj.is(.undefined_value) or obj.is(.null_value))
        return catchableThrow(vm, throwTypeErrorMessage(ctx, global, "not an object"));
    const prototype = try property_ops.expectObject(obj);
    setSuperPropertyValue(ctx, output, global, receiver, prototype, atom_id, value, function, frame) catch |err| return catchVmError(vm, err);
}

pub noinline fn setHomeObject(vm: *Vm) HostError!void {
    const func_value = try vm.stack.peekFromTop(0);
    const home_value = try vm.stack.peekFromTop(1);
    if (func_value.is(.object) and home_value.is(.object)) {
        const func_object = try property_ops.expectObject(func_value);
        try func_object.setFunctionHomeObject(vm.ctx.runtime, try property_ops.expectObject(home_value));
    }
}

pub fn checkBrand(ctx: *core.JSContext, stack: *stack_mod.Stack) !void {
    if (stack.len() < 2) return error.StackUnderflow;
    const obj = stack.values[stack.len() - 2];
    const func = stack.values[stack.len() - 1];
    if (!try hasPrivateBrand(ctx.runtime, obj, func)) return error.TypeError;
}

pub noinline fn checkBrandVm(vm: *Vm) HostError!void {
    const ctx = vm.ctx;
    const global = vm.global;
    checkBrand(ctx, vm.stack) catch |err| {
        // OP_check_brand is responsible for throwing at the failing access
        // site.  Leaving a bare TypeError sentinel here lets an outer caller
        // materialize it with the caller's TypeError constructor instead of
        // the constructor from the bytecode function's realm.
        if (err == error.TypeError and !exception_ops.pendingExceptionMatchesError(ctx, err)) {
            const error_global = if (objectFromValue(vm.frame.current_function)) |function_object|
                objectRealmGlobal(function_object) orelse global
            else
                global;
            _ = throwTypeErrorMessage(ctx, error_global, "invalid brand on object") catch |throw_err| return catchVmError(vm, throw_err);
            unreachable;
        }
        return catchVmError(vm, err);
    };
}

pub fn addBrand(ctx: *core.JSContext, stack: *stack_mod.Stack) !void {
    const home_value = try stack.pop();
    var rooted_home = home_value;
    const obj = try stack.pop();
    var rooted_obj = obj;
    var root_frame = core.runtime.rootValues(.{ &rooted_home, &rooted_obj });
    root_frame.activate(ctx.runtime);
    defer root_frame.deactivate(ctx.runtime);

    const home = try property_ops.expectObject(rooted_home);
    const brand_atom = try ensureHomeObjectBrand(ctx.runtime, home);
    if (rooted_obj.is(.object)) {
        const object = try property_ops.expectObject(rooted_obj);
        if (ctx.global) |global| try requirePrivateElementTargetExtensible(ctx, null, global, object, null, null);
        if (object.hasOwnProperty(brand_atom)) return error.PrivateMemberExists;
        // NO-ALIGN(qjs): JS_AddBrand raw-adds the instance
        // brand ignoring extensibility; test262's
        // `nonextensible-applies-to-private` feature mandates the TypeError,
        // so zjs keeps the NotExtensible -> TypeError behavior.
        try object.defineOwnProperty(ctx.runtime, brand_atom, core.Descriptor.data(core.JSValue.undefinedValue(), .all));
    }
}

pub noinline fn addBrandVm(vm: *Vm) HostError!void {
    addBrand(vm.ctx, vm.stack) catch |err| return catchVmError(vm, err);
}

pub fn privateIn(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.FunctionBytecode,
    frame: *frame_mod.Frame,
) !void {
    const key = try stack.pop();
    const obj = try stack.pop();
    if (!obj.is(.object)) {
        _ = try throwTypeErrorMessage(ctx, global, "invalid 'in' operand");
        return;
    }
    const found = if (key.is(.object))
        try hasPrivateBrand(ctx.runtime, obj, key)
    else blk: {
        const atom_id = try toPropertyKeyAtom(ctx, output, global, key, function, frame);
        const object = try property_ops.expectObject(obj);
        break :blk object.hasOwnProperty(atom_id);
    };
    try stack.pushOwned(core.JSValue.boolean(found));
}

pub noinline fn privateInVm(vm: *Vm) HostError!void {
    privateIn(vm.ctx, vm.output, vm.global, vm.stack, vm.function, vm.frame) catch |err| return catchVmError(vm, err);
}

pub noinline fn defineClass(vm: *Vm, opc: u8) HostError!void {
    const ctx = vm.ctx;
    const output = vm.output;
    const global = vm.global;
    const stack = vm.stack;
    const function = vm.function;
    const frame = vm.frame;
    const is_computed_name = opc == bytecode.opcode.op.define_class_computed;
    const atom_id = core.Atom.fromRaw(readInt(u32, function.byteCode()[frame.pc..][0..4]));
    const flags = function.byteCode()[frame.pc + 4];
    frame.pc += 5;
    var ctor_source = try stack.pop();
    var parent_value = try stack.pop();
    // The `extends` form pops one slot too many when the superclass operand
    // is the placeholder `undefined`: the real superclass sits underneath it.
    // Nothing is "saved" here -- the slot we owe the stack back is always
    // exactly that `undefined` -- so track only whether we owe it.
    var owes_placeholder_class_binding = false;
    var superclass_value = core.JSValue.undefinedValue();
    var superclass_value_active = false;
    var ctor = core.JSValue.undefinedValue();
    var computed_key = core.JSValue.undefinedValue();
    var name_value = core.JSValue.undefinedValue();
    var superclass_proto = core.JSValue.undefinedValue();
    var proto_value = core.JSValue.undefinedValue();
    var root_frame = core.runtime.rootValues(.{
        &ctor_source,
        &parent_value,
        &superclass_value,
        &ctor,
        &computed_key,
        &name_value,
        &superclass_proto,
        &proto_value,
    });
    root_frame.activate(ctx.runtime);
    defer root_frame.deactivate(ctx.runtime);

    if ((flags & 1) != 0) {
        superclass_value = parent_value;
        superclass_value_active = true;
        parent_value = core.JSValue.undefinedValue();
        if (superclass_value.is(.undefined_value) and stack.len() > 0) {
            owes_placeholder_class_binding = true;
            superclass_value = try stack.pop();
        }
        if (!(superclass_value.is(.object) or superclass_value.is(.null_value)))
            return catchableThrow(vm, throwTypeErrorMessage(ctx, global, "parent class must be constructor"));
    }
    const owned_ctor_source = ctor_source;
    ctor_source = core.JSValue.undefinedValue();
    ctor = try createClassBytecodeFunctionObject(ctx, frame, global, owned_ctor_source, atom_id);
    const ctor_object = try property_ops.expectObject(ctor);
    if (is_computed_name) {
        computed_key = try stack.peekFromTop(0);
        const name_atom = toPropertyKeyAtom(ctx, output, global, computed_key, function, frame) catch |err| return catchVmError(vm, err);
        name_value = try functionNameValueFromAtom(ctx.runtime, name_atom, null);
        try defineFunctionNameProperty(ctx.runtime, ctor_object, name_value);
        name_value = core.JSValue.undefinedValue();
        computed_key = core.JSValue.undefinedValue();
    }
    var proto_parent: ?*core.Object = objectPrototypeFromGlobal(ctx.runtime, global);
    if (superclass_value_active) {
        if (superclass_value.is(.object)) {
            if (!isConstructorLike(superclass_value))
                return catchableThrow(vm, throwTypeErrorMessage(ctx, global, "parent class must be constructor"));
            const superclass_object = try property_ops.expectObject(superclass_value);
            try ctor_object.setPrototype(ctx.runtime, superclass_object);
            superclass_proto = getValueProperty(ctx, output, global, superclass_value, core.atom.ids.prototype, function, frame) catch |err| return catchVmError(vm, err);
            if (superclass_proto.is(.object)) {
                proto_parent = try property_ops.expectObject(superclass_proto);
            } else if (superclass_proto.is(.null_value)) {
                proto_parent = null;
            } else {
                return catchableThrow(vm, throwTypeErrorMessage(ctx, global, "parent prototype must be an object or null"));
            }
        } else {
            proto_parent = null;
        }
    }
    const proto = try core.Object.create(ctx.runtime, core.class.ids.object, proto_parent);
    proto_value = proto.value();
    try proto.defineOwnProperty(ctx.runtime, core.atom.ids.constructor, core.Descriptor.data(ctor_object.value(), .method));
    try ctor_object.defineOwnProperty(ctx.runtime, core.atom.ids.prototype, core.Descriptor.data(proto_value, .none));
    try ctor_object.setFunctionHomeObject(ctx.runtime, proto);
    if (owes_placeholder_class_binding) {
        try stack.push(core.JSValue.undefinedValue());
    }
    try stack.push(ctor);
    try stack.push(proto_value);
}

pub noinline fn defineMethod(vm: *Vm) HostError!void {
    const frame = vm.frame;
    const atom_id = core.Atom.fromRaw(readInt(u32, vm.function.byteCode()[frame.pc..][0..4]));
    frame.pc += 4;
    const flags = vm.function.byteCode()[frame.pc];
    frame.pc += 1;
    defineObjectMethod(vm.ctx.runtime, vm.stack, atom_id, flags) catch |err| return catchVmError(vm, err);
}

pub noinline fn defineMethodComputed(vm: *Vm) HostError!void {
    const ctx = vm.ctx;
    const stack = vm.stack;
    const frame = vm.frame;
    const flags = vm.function.byteCode()[frame.pc];
    frame.pc += 1;
    const value = try stack.pop();
    const key_value = try stack.pop();
    const atom_id = toPropertyKeyAtom(ctx, vm.output, vm.global, key_value, vm.function, frame) catch |err| return catchVmError(vm, err);
    // A number key's atom is fresh and held by nothing until the define;
    // naming a getter or setter ("get 1.5") allocates first.
    var key_roots = core.runtime.rootAtoms(.{&atom_id});
    key_roots.activate(ctx.runtime);
    defer key_roots.deactivate(ctx.runtime);
    defineObjectMethodValue(ctx.runtime, stack, atom_id, value, flags) catch |err| return catchVmError(vm, err);
}

fn defineObjectMethod(
    rt: *core.JSRuntime,
    stack: *stack_mod.Stack,
    atom_id: core.Atom,
    flags: u8,
) !void {
    if (stack.len() < 2) {
        const maybe_object = stack.peek() orelse return error.StackUnderflow;
        _ = core.value_semantics.objectFromValue(maybe_object) orelse return error.StackUnderflow;
        return;
    }
    const value = try stack.pop();
    try defineObjectMethodValue(rt, stack, atom_id, value, flags);
}

fn defineObjectMethodValue(
    rt: *core.JSRuntime,
    stack: *stack_mod.Stack,
    atom_id: core.Atom,
    value: core.JSValue,
    flags: u8,
) !void {
    const obj = stack.peek() orelse return error.StackUnderflow;
    var rooted_obj = obj;
    var rooted_value = value;
    var name_value = core.JSValue.undefinedValue();
    var getter = core.JSValue.undefinedValue();
    var setter = core.JSValue.undefinedValue();
    var root_frame = core.runtime.rootValues(.{
        &rooted_obj,
        &rooted_value,
        &name_value,
        &getter,
        &setter,
    });
    root_frame.activate(rt);
    defer root_frame.deactivate(rt);

    const object = try property_ops.expectObject(obj);
    if (rt.atoms.kind(atom_id) == .private) return error.InvalidBytecode;
    if (rooted_value.is(.object)) {
        const function_object = try property_ops.expectObject(rooted_value);
        try function_object.setFunctionHomeObject(rt, object);
        const prefix: ?[]const u8 = switch (flags & 3) {
            1 => "get",
            2 => "set",
            else => null,
        };
        name_value = try functionNameValueFromAtom(rt, atom_id, prefix);
        try defineFunctionNameProperty(rt, function_object, name_value);
        name_value = core.JSValue.undefinedValue();
    }
    const enumerable = (flags & 4) != 0;
    if ((flags & 3) == 1 or (flags & 3) == 2) {
        if (try object.getOwnProperty(rt, atom_id)) |existing| {
            if (existing.kind == .accessor) {
                getter = existing.getter;
                setter = existing.setter;
            }
        }
        const desc = if ((flags & 3) == 1)
            core.Descriptor.accessor(rooted_value, setter, .{ .enumerable = enumerable, .configurable = true })
        else
            core.Descriptor.accessor(getter, rooted_value, .{ .enumerable = enumerable, .configurable = true });
        try object.defineOwnProperty(rt, atom_id, desc);
        getter = core.JSValue.undefinedValue();
        setter = core.JSValue.undefinedValue();
        return;
    }
    try object.defineOwnProperty(rt, atom_id, core.Descriptor.data(rooted_value, .{ .writable = true, .enumerable = enumerable, .configurable = true }));
}

fn ensureHomeObjectBrand(rt: *core.JSRuntime, home: *core.Object) !core.Atom {
    if (try home.getOwnProperty(rt, core.atom.ids.Private_brand)) |desc| {
        if (desc.value.asSymbolAtom()) |brand_atom| return brand_atom;
        return error.TypeError;
    }
    const name = rt.atoms.name(core.atom.ids.Private_brand) orelse "<brand>";
    if (!home.isExtensible()) return error.NotExtensible;
    const brand_atom = try rt.atoms.newSymbol(name, .private);
    const brand_value = try rt.symbolValue(brand_atom);
    try home.defineOwnProperty(rt, core.atom.ids.Private_brand, core.Descriptor.data(brand_value, .all));
    return brand_atom;
}

fn hasPrivateBrand(rt: *core.JSRuntime, obj: core.JSValue, func: core.JSValue) !bool {
    // A bare TypeError: checkBrandVm throws it from the function's realm.
    const object = objectFromValue(obj) orelse return error.TypeError;
    const func_object = objectFromValue(func) orelse return error.TypeError;
    const home = func_object.functionHomeObject() orelse return error.TypeError;
    const desc = (try home.getOwnProperty(rt, core.atom.ids.Private_brand)) orelse return error.TypeError;
    const brand_atom = desc.value.asSymbolAtom() orelse return error.TypeError;
    return object.hasOwnProperty(brand_atom);
}

const readInt = call_runtime.readInt;

test "private brand atom is released with home object" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const home = try core.Object.create(rt, core.class.ids.object, null);
    const brand_atom = try ensureHomeObjectBrand(rt, home);
    try std.testing.expectEqual(core.atom.AtomKind.private, rt.atoms.kind(brand_atom).?);

    // The brand Atom is owned by the home object and comes back when the home
    // object is torn down; under the tracer that is a collection rather than
    // the last release. Nothing here needs rooting -- `home` is the thing that
    // must die.
    _ = try rt.collectForTest();
    try std.testing.expect(rt.atoms.name(brand_atom) == null);
}

test "private brand creation does not allocate atom for non-extensible home object" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const home = try core.Object.create(rt, core.class.ids.object, null);
    home.preventExtensions();
    const before_entries = rt.atoms.entries.len;

    try std.testing.expectError(error.NotExtensible, ensureHomeObjectBrand(rt, home));
    try std.testing.expectEqual(before_entries, rt.atoms.entries.len);
}

// --- Combined from proxy_ops.zig ---

const ProxySetKind = enum { value, error_stack };

/// Shared proxy [[Set]] trap walk; `kind` selects the missing-target /
/// missing-trap / falsy-result policy. Explicit `HostError` breaks the
/// inferred-error-set cycle with `ordinarySetWithReceiver`.
noinline fn proxySetWithTrap(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver_value: core.JSValue,
    proxy: *core.Object,
    atom_id: core.Atom,
    value: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
    kind: ProxySetKind,
) HostError!bool {
    const target_value = proxy.proxyTarget() orelse {
        return if (kind == .error_stack) false else error.TypeError;
    };
    // The key may be a fresh atom (a number key) that nothing else holds,
    // and the trap lookup and call below run JavaScript.
    var key_roots = core.runtime.rootAtoms(.{&atom_id});
    key_roots.activate(ctx.runtime);
    defer key_roots.deactivate(ctx.runtime);
    const handler_value = try proxyHandlerForTrap(ctx, global, proxy);
    const set_atom = core.atom.ids.set;
    const trap = try getValueProperty(ctx, output, global, handler_value, set_atom, caller_function, caller_frame);
    if (trap.is(.undefined_value) or trap.is(.null_value)) {
        switch (kind) {
            .error_stack => return false,
            .value => {
                // target.[[Set]](P, V, Receiver): the target's own [[Set]],
                // exotic ones (TypedArray, nested Proxy) included.
                const target = try property_ops.expectObject(target_value);
                return reflect_ops.setWithReceiver(ctx, output, global, target, receiver_value, atom_id, value, caller_function, caller_frame);
            },
        }
    }
    if (!isCallableValue(trap)) return error.NotAFunction;
    const key_value = try proxyTrapKeyValue(ctx.runtime, atom_id);
    const result = try callValueOrBytecodeSyncInternal(ctx, output, global, handler_value, trap, &.{ target_value, key_value, value, receiver_value }, caller_function, caller_frame);
    if (!valueTruthy(result)) {
        if (kind == .error_stack) {
            _ = try throwSetFailureTypeError(ctx, global, atom_id, error.ReadOnly);
            unreachable;
        }
        return false;
    }
    const target = try property_ops.expectObject(target_value);
    try validateProxySetResult(ctx, output, global, target, atom_id, value, caller_function, caller_frame);
    return true;
}

pub inline fn proxySetTrapForErrorStackSetter(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver_value: core.JSValue,
    receiver: *core.Object,
    stack_key: core.Atom,
    value: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) HostError!bool {
    return proxySetWithTrap(ctx, output, global, receiver_value, receiver, stack_key, value, caller_function, caller_frame, .error_stack);
}

fn proxyCreateDataPropertyOrThrow(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    proxy: *core.Object,
    atom_id: core.Atom,
    value: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !void {
    // CreateDataPropertyOrThrow = [[DefineOwnProperty]] (trap, forwarding,
    // and invariant checks) + throw on false.
    if (!try proxyDefineOwnProperty(ctx, output, global, proxy, atom_id, core.Descriptor.data(value, .all), caller_function, caller_frame))
        return error.CannotDefineProperty;
}

pub fn validateProxyOwnKeysResult(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    target_value: core.JSValue,
    result_keys: []const core.Atom,
) HostError!void {
    const rt = ctx.runtime;
    const target = try property_ops.expectObject(target_value);
    // §10.5.11 invariant walk: IsExtensible(target) first (a nested-proxy
    // target fires its isExtensible trap), then the target's own keys and a
    // [[GetOwnProperty]] per key. Revocation is validated only in step 1, so
    // a trap that revokes its own proxy is still checked against the
    // captured target.
    const target_extensible = try proxyAwareIsExtensible(ctx, output, global, target, null, null);
    const target_keys = try objectRestOwnKeys(ctx, output, global, target);
    defer core.Object.freeKeys(rt, target_keys);
    // A Proxy ownKeys result lives only in this native list across the
    // traps and allocations below; keep its atoms alive.
    var target_keys_roots = core.runtime.rootAtomList(&target_keys);
    target_keys_roots.activate(rt);
    defer target_keys_roots.deactivate(rt);

    // Step 16: [[GetOwnProperty]] for every target key before any check, so
    // a later key's trap runs (and may throw) even when an earlier key
    // already violates an invariant.
    const allocator = rt.nativeAllocator();
    const nonconfigurable = try allocator.alloc(bool, target_keys.len);
    defer allocator.free(nonconfigurable);
    for (target_keys, nonconfigurable) |target_key, *flag| {
        const desc = try proxyAwareOwnPropertyDescriptor(ctx, output, global, target, target_key, null, null);
        flag.* = if (desc) |item| item.configurable == false else false;
    }

    // The result keys are distinct (checked while collecting them).
    var result_index: std.AutoHashMapUnmanaged(core.Atom, usize) = .empty;
    defer result_index.deinit(allocator);
    try result_index.ensureTotalCapacity(allocator, @intCast(result_keys.len));
    for (result_keys, 0..) |result_key, i| result_index.putAssumeCapacity(result_key, i);
    const unchecked = try allocator.alloc(bool, result_keys.len);
    defer allocator.free(unchecked);
    @memset(unchecked, true);

    // Steps 19-22: every non-configurable key must be listed; a
    // non-extensible target must list exactly its own keys.
    for (target_keys, nonconfigurable) |target_key, flag| {
        if (!flag) continue;
        unchecked[result_index.get(target_key) orelse return error.ProxyInvariantViolation] = false;
    }
    if (target_extensible) return;
    for (target_keys, nonconfigurable) |target_key, flag| {
        if (flag) continue;
        unchecked[result_index.get(target_key) orelse return error.ProxyInvariantViolation] = false;
    }
    for (unchecked) |left| {
        if (left) return error.ProxyInvariantViolation;
    }
}

pub fn proxyAwareOwnPropertyDescriptor(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    source: *core.Object,
    key: core.Atom,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.Descriptor {
    const target_value = source.proxyTarget() orelse {
        if (try typedArrayCanonicalOwnDescriptor(ctx.runtime, source, key)) |desc| return desc;
        return source.getOwnProperty(ctx.runtime, key);
    };
    const target = try property_ops.expectObject(target_value);
    // The key may be a fresh atom (a number key) that nothing else holds,
    // and the trap lookup and call below run JavaScript.
    var key_roots = core.runtime.rootAtoms(.{&key});
    key_roots.activate(ctx.runtime);
    defer key_roots.deactivate(ctx.runtime);
    const handler_value = try proxyHandlerForTrap(ctx, global, source);
    const trap_atom = core.atom.ids.getOwnPropertyDescriptor;
    const trap = try getValueProperty(ctx, output, global, handler_value, trap_atom, caller_function, caller_frame);
    if (trap.is(.undefined_value) or trap.is(.null_value)) {
        return try proxyAwareOwnPropertyDescriptor(ctx, output, global, target, key, caller_function, caller_frame);
    }
    if (!isCallableValue(trap)) return error.NotAFunction;
    const key_value = try proxyTrapKeyValue(ctx.runtime, key);
    const desc_value = try callValueOrBytecodeSyncInternal(ctx, output, global, handler_value, trap, &.{ target_value, key_value }, caller_function, caller_frame);
    // [[GetOwnProperty]] 10.5.5: the result type is checked (step 8) before
    // the target is consulted (step 9), and IsExtensible(target) runs only
    // once a target descriptor or a result descriptor needs it.
    const desc_object: ?*core.Object = if (desc_value.is(.undefined_value)) null else try property_ops.expectObject(desc_value);
    const target_desc = try proxyAwareOwnPropertyDescriptor(ctx, output, global, target, key, caller_function, caller_frame);
    if (desc_object == null) {
        const item = target_desc orelse return null;
        if (item.configurable == false) return error.ProxyInvariantViolation;
        if (!try proxyAwareIsExtensible(ctx, output, global, target, caller_function, caller_frame)) return error.ProxyInvariantViolation;
        return null;
    }
    const target_extensible = try proxyAwareIsExtensible(ctx, output, global, target, caller_function, caller_frame);
    const result_desc = try descriptorFromObject(ctx, output, global, desc_value, desc_object.?, target, key, caller_function, caller_frame);
    const complete_desc = try completeProxyDescriptor(result_desc);
    if (!try isCompatibleProxyDescriptor(target_extensible, target_desc, complete_desc)) return error.ProxyInvariantViolation;
    if (complete_desc.configurable == false) {
        if (target_desc) |item| {
            if (item.configurable != false) return error.ProxyInvariantViolation;
            if (complete_desc.kind == .data and complete_desc.writable == false and item.kind == .data and item.writable == true) return error.ProxyInvariantViolation;
        } else {
            return error.ProxyInvariantViolation;
        }
    }
    return complete_desc;
}

/// Existence-only sibling of `proxyAwareOwnPropertyDescriptor`. For a
/// NON-proxy source it mirrors qjs `JS_GetOwnPropertyInternal(ctx, NULL, ...)`
/// (quickjs.c desc==NULL mode): typed-array canonical-index existence
/// (no element materialization), the module-namespace TDZ throw, then the
/// complete kind-cascade probe -- all with NO descriptor allocation and NO
/// `JS_DupValue`. For a Proxy it MUST keep the full descriptor path so the
/// `getOwnPropertyDescriptor` trap fires (spec / qjs `js_proxy_get_own_property`);
/// it then reports presence as `desc != null`. This is the
/// `JS_GetOwnPropertyInternal(NULL)` used by `js_object_hasOwnProperty`
pub fn proxyAwareExistsOwnProperty(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    source: *core.Object,
    key: core.Atom,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !bool {
    if (source.proxyTarget() == null) {
        if (try typedArrayCanonicalIndexExists(ctx.runtime, source, key)) |present| return present;
        return source.existsOwnProperty(ctx.runtime, key);
    }
    // Proxy: keep the full-descriptor path so the trap still fires.
    return (try proxyAwareOwnPropertyDescriptor(ctx, output, global, source, key, caller_function, caller_frame)) != null;
}

const ProxyExtensibleKind = enum { is_extensible, prevent };

/// Shared proxy isExtensible / preventExtensions trap walk; `kind` selects
/// the trap and result check. Explicit `HostError` breaks the inferred-
/// error-set cycle through Prevent's IsExtensible check and the
/// missing-trap recursion.
noinline fn proxyAwareExtensibleOp(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    object: *core.Object,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
    kind: ProxyExtensibleKind,
) HostError!bool {
    const target_value = object.proxyTarget() orelse return switch (kind) {
        .is_extensible => object.isExtensible(),
        .prevent => object.preventExtensionsChecked(),
    };
    const target = try property_ops.expectObject(target_value);
    const handler_value = try proxyHandlerForTrap(ctx, global, object);
    const trap_atom = switch (kind) {
        .is_extensible => core.atom.ids.isExtensible,
        .prevent => core.atom.ids.preventExtensions,
    };
    const trap = try getValueProperty(ctx, output, global, handler_value, trap_atom, caller_function, caller_frame);
    if (trap.is(.undefined_value) or trap.is(.null_value)) {
        return proxyAwareExtensibleOp(ctx, output, global, target, caller_function, caller_frame, kind);
    }
    if (!isCallableValue(trap)) return error.NotAFunction;
    const result = try callValueOrBytecodeSyncInternal(ctx, output, global, handler_value, trap, &.{target_value}, caller_function, caller_frame);
    switch (kind) {
        .is_extensible => {
            const extensible = valueTruthy(result);
            if (extensible != try proxyAwareExtensibleOp(ctx, output, global, target, caller_function, caller_frame, .is_extensible)) {
                return error.ProxyInvariantViolation;
            }
            return extensible;
        },
        .prevent => {
            if (!valueTruthy(result)) return false;
            if (try proxyAwareExtensibleOp(ctx, output, global, target, caller_function, caller_frame, .is_extensible)) {
                return error.ProxyInvariantViolation;
            }
            return true;
        },
    }
}

pub inline fn proxyAwareIsExtensible(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    object: *core.Object,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) HostError!bool {
    return proxyAwareExtensibleOp(ctx, output, global, object, caller_function, caller_frame, .is_extensible);
}

pub inline fn proxyAwarePreventExtensions(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    object: *core.Object,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) HostError!bool {
    return proxyAwareExtensibleOp(ctx, output, global, object, caller_function, caller_frame, .prevent);
}

pub fn proxyAwareSetPrototypeOf(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    object: *core.Object,
    prototype: ?*core.Object,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !bool {
    const target_value = object.proxyTarget() orelse {
        object.setPrototype(ctx.runtime, prototype) catch |err| switch (err) {
            error.PrototypeCycle, error.NotExtensible => return false,
            else => return err,
        };
        return true;
    };
    const target = try property_ops.expectObject(target_value);
    const handler_value = try proxyHandlerForTrap(ctx, global, object);
    const trap_atom = core.atom.ids.setPrototypeOf;
    const trap = try getValueProperty(ctx, output, global, handler_value, trap_atom, caller_function, caller_frame);
    const proto_value = if (prototype) |proto| proto.value() else core.JSValue.nullValue();
    if (trap.is(.undefined_value) or trap.is(.null_value)) return proxyAwareSetPrototypeOf(ctx, output, global, target, prototype, caller_function, caller_frame);
    if (!isCallableValue(trap)) return error.NotAFunction;
    const result = try callValueOrBytecodeSyncInternal(ctx, output, global, handler_value, trap, &.{ target_value, proto_value }, caller_function, caller_frame);
    if (!valueTruthy(result)) return false;
    if (!try proxyAwareIsExtensible(ctx, output, global, target, caller_function, caller_frame)) {
        const target_proto = try objectGetPrototypeOfStep(ctx, output, global, target, caller_function, caller_frame);
        if (target_proto != prototype) return error.ProxyInvariantViolation;
    }
    return true;
}

fn completeProxyDescriptor(desc: core.Descriptor) !core.Descriptor {
    return switch (desc.kind) {
        .generic, .data => core.Descriptor.data(if (desc.value_present) desc.value else core.JSValue.undefinedValue(), .{ .writable = desc.writable orelse false, .enumerable = desc.enumerable orelse false, .configurable = desc.configurable orelse false }),
        .accessor => core.Descriptor.accessor(if (desc.getter_present) desc.getter else core.JSValue.undefinedValue(), if (desc.setter_present) desc.setter else core.JSValue.undefinedValue(), .{ .enumerable = desc.enumerable orelse false, .configurable = desc.configurable orelse false }),
    };
}

pub fn isCompatibleProxyDescriptor(extensible: bool, current: ?core.Descriptor, desc: core.Descriptor) !bool {
    const current_desc = current orelse return extensible;
    if (current_desc.configurable orelse false) return true;
    if (desc.configurable orelse false) return false;
    if (desc.enumerable) |enumerable| {
        if (enumerable != (current_desc.enumerable orelse false)) return false;
    }
    if (desc.kind == .generic) return true;

    const current_is_accessor = current_desc.kind == .accessor;
    if ((desc.kind == .accessor) != current_is_accessor) return false;
    if (!current_is_accessor and !(current_desc.writable orelse false)) {
        if (desc.writable orelse false) return false;
        if (desc.kind == .data and desc.value_present and !current_desc.value.sameValue(desc.value)) return false;
    }
    if (current_is_accessor and desc.kind == .accessor) {
        if (desc.getter_present and !current_desc.getter.sameValue(desc.getter)) return false;
        if (desc.setter_present and !current_desc.setter.sameValue(desc.setter)) return false;
    }
    return true;
}

/// Whether `value` is a proxy with [[Call]]: a flag ProxyCreate fixes, so a
/// long proxy chain is not walked on every call.
pub fn proxyTargetIsCallable(value: core.JSValue) bool {
    const object = objectFromValue(value) orelse return false;
    return object.proxyIsCallable();
}

/// ProxyCreate(target, handler) (§10.5.14) after the Object checks: the
/// shared body of `new Proxy` and `Proxy.revocable`.
pub fn createProxyObject(ctx: *core.JSContext, target: core.JSValue, handler: core.JSValue) !*core.Object {
    const rt = ctx.runtime;
    var rooted_target = target;
    var rooted_handler = handler;
    var root_frame = core.runtime.rootValues(.{ &rooted_target, &rooted_handler });
    root_frame.activate(rt);
    defer root_frame.deactivate(rt);

    const is_callable = target.is(.function_bytecode) or functionObjectFromValue(target) != null or
        callableObjectFromValue(target) != null or proxyTargetIsCallable(target);
    const is_constructor = isConstructorLike(target);
    const proxy = try core.Object.create(rt, core.class.ids.proxy, null);
    errdefer core.Object.destroyFromHeader(rt, proxy.gcHeader());
    try proxy.ensureProxyPayload(rt);
    proxy.setProxyCallability(is_callable, is_constructor);
    try proxy.setOptionalValueSlot(rt, proxy.proxyTargetSlot(), rooted_target);
    try proxy.setOptionalValueSlot(rt, proxy.proxyHandlerSlot(), rooted_handler);
    return proxy;
}

/// SpeciesConstructor(O, defaultConstructor) (ES §7.3.22). The default is
/// the realm intrinsic the caller passes, never a replaceable global binding.
pub fn speciesConstructor(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    object_value: core.JSValue,
    default_constructor: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    var values = [_]core.JSValue{ global.value(), object_value, default_constructor, core.JSValue.undefinedValue() };
    const slots: []core.JSValue = &values;
    const slices = [_]core.runtime.ValueRootSlice{.{ .mutable = &slots }};
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(ctx.runtime);
    defer roots.deactivate(ctx.runtime);
    values[3] = try getValueProperty(ctx, output, objectFromValue(values[0]).?, values[1], core.atom.ids.constructor, caller_function, caller_frame);
    if (values[3].is(.undefined_value)) return values[2];
    if (!values[3].is(.object)) return error.NotAnObject;
    const species_atom = comptime core.atom.predefinedId("Symbol.species", .symbol).?;
    values[3] = try getValueProperty(ctx, output, objectFromValue(values[0]).?, values[3], species_atom, caller_function, caller_frame);
    if (values[3].is(.undefined_value) or values[3].is(.null_value)) return values[2];
    if (!isConstructorLike(values[3])) return error.NotAConstructor;
    return values[3];
}

/// The live handler of `proxy` for a trap lookup. Every trap re-enters the
/// engine for the proxy's target, so this is also the native-stack check that
/// bounds a deep proxy chain (qjs get_proxy_method).
pub fn proxyHandlerForTrap(ctx: *core.JSContext, global: *core.Object, proxy: *core.Object) !core.JSValue {
    if (ctx.runtime.stack.checkNativeOverflow(0)) return error.StackOverflow;
    return proxy.proxyHandler() orelse {
        _ = try throwTypeErrorMessage(ctx, global, "revoked proxy");
        unreachable;
    };
}

pub fn callProxyApply(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    proxy: *core.Object,
    this_value: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const target_value = proxy.proxyTargetOfProxy();
    const handler_value = try proxyHandlerForTrap(ctx, global, proxy);
    const apply_atom = core.atom.ids.apply;
    const trap = try getValueProperty(ctx, output, global, handler_value, apply_atom, caller_function, caller_frame);
    if (trap.is(.undefined_value) or trap.is(.null_value)) {
        return callValueOrBytecodeSyncInternal(ctx, output, global, this_value, target_value, args, caller_function, caller_frame);
    }
    if (!isCallableValue(trap)) return error.NotAFunction;
    const arg_array = try createArrayFromArgs(ctx.runtime, global, args);
    return callValueOrBytecodeSyncInternal(ctx, output, global, handler_value, trap, &.{ target_value, this_value, arg_array }, caller_function, caller_frame);
}

pub fn constructProxyInstance(
    ctx: *core.JSContext,
    target: core.JSValue,
    handler: core.JSValue,
) !core.JSValue {
    if (objectFromValue(target) == null or objectFromValue(handler) == null) return error.TypeError;
    return (try createProxyObject(ctx, target, handler)).value();
}

test "constructProxyInstance allocates a proxy whose [[Prototype]] is null" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();

    const target = try core.Object.create(rt, core.class.ids.object, null);
    const handler = try core.Object.create(rt, core.class.ids.object, null);
    const proxy_value = try constructProxyInstance(ctx, target.value(), handler.value());
    const proxy = objectFromValue(proxy_value) orelse return error.TypeError;
    try std.testing.expectEqual(core.class.ids.proxy, proxy.class_id);
    try std.testing.expect(proxy.getPrototype() == null);
    try std.testing.expect(proxy.proxyTarget() != null);
    try std.testing.expect(proxy.proxyHandler() != null);
}

pub fn constructProxy(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    proxy: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
    new_target_value: core.JSValue,
) !core.JSValue {
    if (!proxy.proxyIsConstructor()) return error.NotAConstructor;
    const target_value = proxy.proxyTargetOfProxy();
    const handler_value = try proxyHandlerForTrap(ctx, global, proxy);
    const construct_atom = core.atom.ids.construct;
    const trap = try getValueProperty(ctx, output, global, handler_value, construct_atom, caller_function, caller_frame);
    if (trap.is(.undefined_value) or trap.is(.null_value)) {
        // A proxy without a construct trap forwards the original new.target.
        // Re-enter the ordinary constructor boundary instead of flattening a
        // bound target chain: QuickJS polls each forwarded Proxy/Bound
        // constructor entry, and native constructors still need the original
        // new.target for their observable prototype lookup.
        return call_runtime.constructValueOrBytecodeWithNewTarget(ctx, output, global, target_value, args, caller_function, caller_frame, new_target_value);
    }
    if (!isCallableValue(trap)) return error.NotAFunction;
    const arg_array = try createArrayFromArgs(ctx.runtime, global, args);
    const result = try callValueOrBytecodeSyncInternal(ctx, output, global, handler_value, trap, &.{ target_value, arg_array, new_target_value }, caller_function, caller_frame);
    if (!result.is(.object)) {
        return error.NotAnObject;
    }
    return result;
}

pub fn getProxyProperty(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver_value: core.JSValue,
    proxy: *core.Object,
    atom_id: core.Atom,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) HostError!core.JSValue {
    // The key may be a fresh atom (a number key) that nothing else holds,
    // and the trap lookup and call below run JavaScript.
    var key_roots = core.runtime.rootAtoms(.{&atom_id});
    key_roots.activate(ctx.runtime);
    defer key_roots.deactivate(ctx.runtime);
    const target_value = proxy.proxyTargetOfProxy();
    const handler_value = try proxyHandlerForTrap(ctx, global, proxy);
    const trap = if (property_ops.ordinaryDataPropertyValueOrUndefinedForFastPath(ctx.runtime, handler_value, core.atom.ids.get)) |borrowed|
        borrowed
    else
        try getValueProperty(ctx, output, global, handler_value, core.atom.ids.get, caller_function, caller_frame);
    const target = try property_ops.expectObject(target_value);
    if (trap.is(.undefined_value) or trap.is(.null_value)) {
        if (property_ops.ordinaryDataPropertyValueOrUndefinedForFastPath(ctx.runtime, target_value, atom_id)) |borrowed| {
            return borrowed;
        }
        return getValuePropertyWithReceiver(ctx, output, global, target_value, target, receiver_value, atom_id, caller_function, caller_frame);
    }
    const key_value = try proxyTrapKeyValue(ctx.runtime, atom_id);
    const result = try callValueOrBytecodeSyncInternal(ctx, output, global, handler_value, trap, &.{ target_value, key_value, receiver_value }, caller_function, caller_frame);
    try validateProxyGetResult(ctx, output, global, target, atom_id, result, caller_function, caller_frame);
    return result;
}

pub fn validateProxyGetResult(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    target: *core.Object,
    atom_id: core.Atom,
    result: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !void {
    switch (validatePlainProxyGetResultFast(target, atom_id, result)) {
        .valid => return,
        .invalid => return error.ProxyInvariantViolation,
        .slow => {},
    }
    const target_desc = try proxyAwareOwnPropertyDescriptor(ctx, output, global, target, atom_id, caller_function, caller_frame) orelse return;
    if (target_desc.configurable != false) return;
    switch (target_desc.kind) {
        .data => {
            if (target_desc.writable == false and !result.sameValue(target_desc.value)) return error.ProxyInvariantViolation;
        },
        .accessor => {
            if (target_desc.getter.is(.undefined_value) and !result.is(.undefined_value)) return error.ProxyInvariantViolation;
        },
        .generic => {},
    }
}

const ProxyGetValidation = enum { valid, invalid, slow };

/// qjs `js_proxy_get` validates the trap result with a direct
/// JS_GetOwnPropertyInternal probe after the trap returns. Mirror that shape
/// for a plain target instead of materializing and destroying a full zjs
/// Descriptor. Only the two invariant-bearing cases can reject: a frozen data
/// value, or a non-configurable accessor whose getter is absent. Other property
/// kinds retain the authoritative descriptor path below.
fn validatePlainProxyGetResultFast(target: *core.Object, atom_id: core.Atom, result: core.JSValue) ProxyGetValidation {
    if (target.class_id != core.class.ids.object or target.isArray() or target.isGlobal() or target.flags.is_with_environment) return .slow;
    if (target.proxyTarget() != null or target.hasExoticMethods()) return .slow;
    const index = target.findProperty(atom_id) orelse return .valid;
    const flags = target.propFlagsAt(index);
    if (flags.deleted) return .valid;
    if (flags.configurable) return .valid;
    return switch (flags.kind) {
        .data => blk: {
            const stored = target.asDataAt(index) orelse break :blk .slow;
            break :blk if (flags.writable or result.sameValue(stored)) .valid else .invalid;
        },
        .accessor => blk: {
            const accessor = target.asAccessorAt(index) orelse break :blk .slow;
            break :blk if (!accessor.getterIsUndefined() or result.is(.undefined_value)) .valid else .invalid;
        },
        .var_ref, .auto_init => .slow,
    };
}

/// The Proxy whose [[Set]] OrdinarySet reaches for `atom_id`, if any: none
/// when `object` or an ordinary prototype before it owns the key
/// (OrdinarySetWithOwnDescriptor uses the first own descriptor found).
pub fn firstProxyInPrototypeSetPath(rt: *core.JSRuntime, object: *core.Object, atom_id: core.Atom) !?*core.Object {
    if (try object.getOwnProperty(rt, atom_id) != null) return null;
    var current = object.getPrototype();
    while (current) |prototype| : (current = prototype.getPrototype()) {
        if (prototype.proxyTarget() != null) return prototype;
        if (try prototype.getOwnProperty(rt, atom_id) != null) return null;
    }
    return null;
}

pub inline fn proxySetValueProperty(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver_value: core.JSValue,
    proxy: *core.Object,
    atom_id: core.Atom,
    value: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) HostError!bool {
    return proxySetWithTrap(ctx, output, global, receiver_value, proxy, atom_id, value, caller_function, caller_frame, .value);
}

pub fn validateProxySetResult(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    target: *core.Object,
    atom_id: core.Atom,
    value: core.JSValue,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !void {
    const target_desc = try proxyAwareOwnPropertyDescriptor(ctx, output, global, target, atom_id, caller_function, caller_frame) orelse return;
    if (target_desc.configurable != false) return;
    switch (target_desc.kind) {
        .data => {
            if (target_desc.writable == false and !value.sameValue(target_desc.value)) return error.ProxyInvariantViolation;
        },
        .accessor => {
            if (target_desc.setter.is(.undefined_value)) return error.ProxyInvariantViolation;
        },
        .generic => {},
    }
}

pub fn proxyTargetIsCallableObject(object: *core.Object) bool {
    return core.class.isFunctionClass(object.class_id) or proxyTargetIsCallable(object.value());
}

pub fn proxyDefineOwnProperty(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    proxy: *core.Object,
    atom_id: core.Atom,
    desc: core.Descriptor,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !bool {
    // The key may be a fresh atom (a number key) that nothing else holds,
    // and the trap lookup and call below run JavaScript.
    var key_roots = core.runtime.rootAtoms(.{&atom_id});
    key_roots.activate(ctx.runtime);
    defer key_roots.deactivate(ctx.runtime);
    const target_value = proxy.proxyTargetOfProxy();
    const target = try property_ops.expectObject(target_value);
    const handler_value = try proxyHandlerForTrap(ctx, global, proxy);
    const trap_atom = core.atom.ids.defineProperty;
    const trap = try getValueProperty(ctx, output, global, handler_value, trap_atom, caller_function, caller_frame);
    if (trap.is(.undefined_value) or trap.is(.null_value)) {
        return try defineOwnPropertyVm(ctx, output, global, target, atom_id, desc, .return_false, caller_function, caller_frame);
    }
    if (!isCallableValue(trap)) return error.NotAFunction;
    const key_value = try proxyTrapKeyValue(ctx.runtime, atom_id);
    const desc_value = try descriptorObjectFromDescriptor(ctx.runtime, global, desc);
    const result = try callValueOrBytecodeSyncInternal(ctx, output, global, handler_value, trap, &.{ target_value, key_value, desc_value }, caller_function, caller_frame);
    if (!valueTruthy(result)) return false;
    const target_desc = try proxyAwareOwnPropertyDescriptor(ctx, output, global, target, atom_id, caller_function, caller_frame);
    // [[DefineOwnProperty]] step 11: ? IsExtensible(target), which runs a
    // nested proxy target's trap. QuickJS reads the raw extensible flag.
    const target_extensible = try proxyAwareIsExtensible(ctx, output, global, target, caller_function, caller_frame);
    if (!try isCompatibleProxyDescriptor(target_extensible, target_desc, desc)) return error.ProxyInvariantViolation;
    const setting_config_false = desc.configurable == false;
    if (setting_config_false) {
        if (target_desc) |item| {
            if (item.configurable != false) return error.ProxyInvariantViolation;
        } else {
            return error.ProxyInvariantViolation;
        }
    }
    if (target_desc) |item| {
        if (item.configurable == false and item.kind == .data and item.writable == true and desc.kind == .data and desc.writable == false) return error.ProxyInvariantViolation;
    }
    return true;
}

pub fn validateProxyHasResult(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    target: *core.Object,
    atom_id: core.Atom,
    result: bool,
    caller_function: ?*const bytecode.FunctionBytecode,
    caller_frame: ?*frame_mod.Frame,
) !bool {
    if (result) return true;
    // [[HasProperty]] step 9: the target descriptor and ? IsExtensible(target)
    // both dispatch through a nested proxy target's traps. QuickJS reads the
    // raw extensible flag instead.
    if (try proxyAwareOwnPropertyDescriptor(ctx, output, global, target, atom_id, caller_function, caller_frame)) |desc| {
        if (desc.configurable == false) return error.ProxyInvariantViolation;
        if (!try proxyAwareIsExtensible(ctx, output, global, target, caller_function, caller_frame)) return error.ProxyInvariantViolation;
    }
    return false;
}

pub fn proxyTrapKeyValue(rt: *core.JSRuntime, atom_id: core.Atom) !core.JSValue {
    if (rt.atoms.kind(atom_id)) |kind| {
        if (core.atom.isPublicSymbolKind(kind)) return rt.symbolValue(atom_id);
    }
    return rt.atoms.toStringValue(rt, atom_id);
}

// ----- Object constructor and prototype builtins -----
// Object constructor, static/prototype records, and direct builtin bodies.
//
// Receiver and argument values are borrowed; returned JSValues are owned.
// Generic property, proxy, iterator, and construction algorithms remain with
// their owning exec modules behind the alias wall below. The builtin domain
// follows `js_object_constructor` and its tables at quickjs.c and
// quickjs.c; per-property source maps stay beside each algorithm.
const call_site_mod = @import("call_site.zig");
const CallSite = call_site_mod.CallSite;
const IntegrityLevel = call_runtime.IntegrityLevel;
const definePropertiesOnTarget = call_runtime.definePropertiesOnTarget;
const iteratorGetIterator = iterator_ops.getIterator;
const iteratorStepValue = iterator_ops.iteratorStepValue;
pub const StaticMethod = core.host_function.builtin_method_ids.object.StaticMethod;
pub const ConstructorMethod = core.host_function.builtin_method_ids.object.ConstructorMethod;
pub const PrototypeMethod = enum(u32) {
    to_string = 101,
    to_locale_string = 102,
    value_of = 103,
    has_own_property = 104,
    is_prototype_of = 105,
    property_is_enumerable = 106,
    define_getter = 107,
    define_setter = 108,
    lookup_getter = 109,
    lookup_setter = 110,
    /// The `Object.prototype.__proto__` accessor pair.
    proto_getter = 111,
    proto_setter = 112,
};
pub fn staticMethodId(name: []const u8) ?u32 {
    if (std.mem.eql(u8, name, "assign")) return @intFromEnum(StaticMethod.assign);
    if (std.mem.eql(u8, name, "create")) return @intFromEnum(StaticMethod.create);
    if (std.mem.eql(u8, name, "defineProperty")) return @intFromEnum(StaticMethod.define_property);
    if (std.mem.eql(u8, name, "defineProperties")) return @intFromEnum(StaticMethod.define_properties);
    if (std.mem.eql(u8, name, "getOwnPropertyDescriptor")) return @intFromEnum(StaticMethod.get_own_property_descriptor);
    if (std.mem.eql(u8, name, "getOwnPropertyDescriptors")) return @intFromEnum(StaticMethod.get_own_property_descriptors);
    if (std.mem.eql(u8, name, "getOwnPropertyNames")) return @intFromEnum(StaticMethod.get_own_property_names);
    if (std.mem.eql(u8, name, "getOwnPropertySymbols")) return @intFromEnum(StaticMethod.get_own_property_symbols);
    if (std.mem.eql(u8, name, "getPrototypeOf")) return @intFromEnum(StaticMethod.get_prototype_of);
    if (std.mem.eql(u8, name, "hasOwn")) return @intFromEnum(StaticMethod.has_own);
    if (std.mem.eql(u8, name, "isExtensible")) return @intFromEnum(StaticMethod.is_extensible);
    if (std.mem.eql(u8, name, "keys")) return @intFromEnum(StaticMethod.keys);
    if (std.mem.eql(u8, name, "preventExtensions")) return @intFromEnum(StaticMethod.prevent_extensions);
    if (std.mem.eql(u8, name, "seal")) return @intFromEnum(StaticMethod.seal);
    if (std.mem.eql(u8, name, "isSealed")) return @intFromEnum(StaticMethod.is_sealed);
    if (std.mem.eql(u8, name, "isFrozen")) return @intFromEnum(StaticMethod.is_frozen);
    if (std.mem.eql(u8, name, "setPrototypeOf")) return @intFromEnum(StaticMethod.set_prototype_of);
    if (std.mem.eql(u8, name, "values")) return @intFromEnum(StaticMethod.values);
    if (std.mem.eql(u8, name, "entries")) return @intFromEnum(StaticMethod.entries);
    if (std.mem.eql(u8, name, "is")) return @intFromEnum(StaticMethod.is);
    if (std.mem.eql(u8, name, "freeze")) return @intFromEnum(StaticMethod.freeze);
    if (std.mem.eql(u8, name, "fromEntries")) return @intFromEnum(StaticMethod.from_entries);
    if (std.mem.eql(u8, name, "groupBy")) return @intFromEnum(StaticMethod.group_by);
    return null;
}

pub fn prototypeMethodId(name: []const u8) ?u32 {
    if (std.mem.eql(u8, name, "toString")) return @intFromEnum(PrototypeMethod.to_string);
    if (std.mem.eql(u8, name, "toLocaleString")) return @intFromEnum(PrototypeMethod.to_locale_string);
    if (std.mem.eql(u8, name, "valueOf")) return @intFromEnum(PrototypeMethod.value_of);
    if (std.mem.eql(u8, name, "hasOwnProperty")) return @intFromEnum(PrototypeMethod.has_own_property);
    if (std.mem.eql(u8, name, "isPrototypeOf")) return @intFromEnum(PrototypeMethod.is_prototype_of);
    if (std.mem.eql(u8, name, "propertyIsEnumerable")) return @intFromEnum(PrototypeMethod.property_is_enumerable);
    if (std.mem.eql(u8, name, "__defineGetter__")) return @intFromEnum(PrototypeMethod.define_getter);
    if (std.mem.eql(u8, name, "__defineSetter__")) return @intFromEnum(PrototypeMethod.define_setter);
    if (std.mem.eql(u8, name, "__lookupGetter__")) return @intFromEnum(PrototypeMethod.lookup_getter);
    if (std.mem.eql(u8, name, "__lookupSetter__")) return @intFromEnum(PrototypeMethod.lookup_setter);
    return null;
}

pub fn prototypeMethodOrdinal(id: u32) ?i32 {
    return switch (id) {
        @intFromEnum(PrototypeMethod.to_string) => 1,
        @intFromEnum(PrototypeMethod.to_locale_string) => 2,
        @intFromEnum(PrototypeMethod.value_of) => 3,
        @intFromEnum(PrototypeMethod.has_own_property) => 4,
        @intFromEnum(PrototypeMethod.is_prototype_of) => 5,
        @intFromEnum(PrototypeMethod.property_is_enumerable) => 6,
        @intFromEnum(PrototypeMethod.define_getter) => 7,
        @intFromEnum(PrototypeMethod.define_setter) => 8,
        @intFromEnum(PrototypeMethod.lookup_getter) => 9,
        @intFromEnum(PrototypeMethod.lookup_setter) => 10,
        else => null,
    };
}

fn staticEntry(comptime name: []const u8, comptime length: u8, comptime method: StaticMethod) core.host_function.InternalEntry {
    return objectEntry(name, length, @intFromEnum(method));
}

fn prototypeEntry(comptime name: []const u8, comptime length: u8, comptime method: PrototypeMethod) core.host_function.InternalEntry {
    return objectEntry(name, length, @intFromEnum(method));
}

fn prototypeExecDirectEntry(
    comptime name: []const u8,
    comptime length: u8,
    comptime method: PrototypeMethod,
    comptime direct: core.native_entry.ManagedFn,
) core.host_function.InternalEntry {
    var entry = prototypeEntry(name, length, method);
    entry.managed = direct;
    return entry;
}

fn objectEntry(comptime name: []const u8, comptime length: u8, comptime id: u32) core.host_function.InternalEntry {
    return .{
        .name = name,
        .length = length,
        .id = id,
        .magic = @intCast(id),
        .cproto = .generic_magic,
        .native_function = builtin_dispatch.genericMagicFunction(&objectCall),
    };
}

fn constructorEntry() core.host_function.InternalEntry {
    return .{
        .name = "Object",
        .length = 1,
        .id = @intFromEnum(ConstructorMethod.call),
        .cproto = .constructor_or_func_magic,
        .native_function = builtin_dispatch.constructorOrFunctionMagic(&objectConstructorCall),
    };
}

/// Declaration table for the `.object` domain: the Object call entry plus one
/// entry per `Object.*` static and `Object.prototype.*` method. Static/prototype
/// `id`/`magic` values are consumed by `objectCallForNativeRecord` and the
/// bare-runtime fallback, kept in lockstep with the visible install order in
/// `standard_globals`.
pub const internal_entries = [_]core.host_function.InternalEntry{
    constructorEntry(),
    staticEntry("assign", 2, .assign),
    staticEntry("create", 2, .create),
    staticEntry("defineProperty", 3, .define_property),
    staticEntry("defineProperties", 2, .define_properties),
    staticEntry("getOwnPropertyDescriptor", 2, .get_own_property_descriptor),
    staticEntry("getOwnPropertyDescriptors", 1, .get_own_property_descriptors),
    staticEntry("getOwnPropertyNames", 1, .get_own_property_names),
    staticEntry("getOwnPropertySymbols", 1, .get_own_property_symbols),
    staticEntry("getPrototypeOf", 1, .get_prototype_of),
    staticEntry("hasOwn", 2, .has_own),
    staticEntry("isExtensible", 1, .is_extensible),
    staticEntry("keys", 1, .keys),
    staticEntry("preventExtensions", 1, .prevent_extensions),
    staticEntry("seal", 1, .seal),
    staticEntry("isSealed", 1, .is_sealed),
    staticEntry("isFrozen", 1, .is_frozen),
    staticEntry("setPrototypeOf", 2, .set_prototype_of),
    staticEntry("values", 1, .values),
    staticEntry("entries", 1, .entries),
    staticEntry("is", 2, .is),
    staticEntry("freeze", 1, .freeze),
    staticEntry("fromEntries", 1, .from_entries),
    staticEntry("groupBy", 2, .group_by),
    prototypeEntry("toString", 0, .to_string),
    prototypeEntry("toLocaleString", 0, .to_locale_string),
    prototypeEntry("valueOf", 0, .value_of),
    prototypeExecDirectEntry("hasOwnProperty", 1, .has_own_property, &objectHasOwnPropertyDirect),
    prototypeEntry("isPrototypeOf", 1, .is_prototype_of),
    prototypeEntry("propertyIsEnumerable", 1, .property_is_enumerable),
    prototypeEntry("__defineGetter__", 2, .define_getter),
    prototypeEntry("__defineSetter__", 2, .define_setter),
    prototypeEntry("__lookupGetter__", 1, .lookup_getter),
    prototypeEntry("__lookupSetter__", 1, .lookup_setter),
    prototypeEntry("get __proto__", 0, .proto_getter),
    prototypeEntry("set __proto__", 1, .proto_setter),
};
fn objectConstructorCall(
    native_ctx: *core.JSContext,
    native_this: core.JSValue,
    native_args: []const core.JSValue,
    native_magic: i32,
) HostError!core.JSValue {
    const host_call = builtin_dispatch.nativeCall(native_ctx, native_this, native_args, native_magic) orelse return error.TypeError;
    if (host_call.args.len != 0 and host_call.args[0].is(.object)) return host_call.args[0];
    const constructor = host_call.func_obj orelse return error.TypeError;
    return construct_mod.objectConstructorValue(host_call.ctx, host_call.args, constructor);
}

/// Shared record handler for the `.object` domain. JS methods stay on the
/// `.object` record and `objectCallForNativeRecord` (kept private). Callers
/// that need JS behavior must pass a Realm global.
fn objectCall(
    native_ctx: *core.JSContext,
    native_this: core.JSValue,
    native_args: []const core.JSValue,
    native_magic: i32,
) HostError!core.JSValue {
    const host_call = builtin_dispatch.nativeCall(native_ctx, native_this, native_args, native_magic) orelse return error.TypeError;
    const ctx = host_call.ctx;
    const output = host_call.output;
    const id: u32 = host_call.magic;
    const args = host_call.args;
    const this_value = host_call.this_value;
    const caller_function = builtin_dispatch.callerBytecode(host_call);
    const caller_frame = builtin_dispatch.callerFrame(host_call);

    if (host_call.func_obj != null) {
        const realm = try builtin_dispatch.callableRealm(host_call);
        std.debug.assert(realm.realm == ctx);
        return try objectCallForNativeRecord(ctx, output, realm.global, this_value, id, args, caller_function, caller_frame);
    }

    // A call without a callable carrier still names its realm's global.
    const global = host_call.global orelse return error.InvalidBuiltinRegistry;
    return try objectCallForNativeRecord(ctx, output, global, this_value, id, args, caller_function, caller_frame);
}

/// Realm-global dispatcher for the `.object` domain methods. The domain module
/// owns `Object.*` static/prototype dispatch directly.
/// Branches whose implementation stays in exec — because an opcode handler or
/// another exec module also calls it (`defineProperty`/`isExtensible`/
/// `setPrototypeOf`/`keys`/`values`/`entries`/`defineProperties`) or it is a
/// prototype method parked in another domain file (`toString`/`toLocaleString`)
/// — call back into exec through the qualified module path.
fn objectCallForNativeRecord(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    id: u32,
    args: []const core.JSValue,
    caller_function: ?*const builtin_dispatch.Bytecode,
    caller_frame: ?*builtin_dispatch.Frame,
) HostError!core.JSValue {
    return switch (id) {
        @intFromEnum(StaticMethod.assign) => (try objectAssignCall(ctx, output, global, args, caller_function, caller_frame)) orelse error.NotAnObject,
        @intFromEnum(StaticMethod.create) => (try objectCreateCall(ctx, output, global, args, caller_function, caller_frame)) orelse error.NotAnObject,
        @intFromEnum(StaticMethod.define_property) => (try definePropertyWithKind(ctx, output, global, args, 1, caller_function, caller_frame)) orelse error.NotAnObject,
        @intFromEnum(StaticMethod.define_properties) => (try call_runtime.definePropertiesCall(ctx, output, global, args, caller_function, caller_frame)) orelse error.NotAnObject,
        @intFromEnum(StaticMethod.get_own_property_descriptor) => (try getOwnPropertyDescriptorCall(ctx, output, global, args, caller_function, caller_frame)) orelse error.NotAnObject,
        @intFromEnum(StaticMethod.get_own_property_descriptors) => (try getOwnPropertyDescriptorsCall(ctx, output, global, args, caller_function, caller_frame)) orelse error.NotAnObject,
        @intFromEnum(StaticMethod.get_own_property_names) => (try objectOwnPropertyKeysCall(ctx, output, global, args, .string, caller_function, caller_frame)) orelse error.NotAnObject,
        @intFromEnum(StaticMethod.get_own_property_symbols) => (try objectOwnPropertyKeysCall(ctx, output, global, args, .symbol, caller_function, caller_frame)) orelse error.NotAnObject,
        @intFromEnum(StaticMethod.get_prototype_of) => (try objectGetPrototypeOfCall(ctx, output, global, args, caller_function, caller_frame)) orelse error.NotAnObject,
        @intFromEnum(StaticMethod.has_own) => (try objectHasOwnCall(ctx, output, global, args, caller_function, caller_frame)) orelse error.NotAnObject,
        @intFromEnum(StaticMethod.is_extensible) => (try objectIsExtensibleCall(ctx, output, global, args, caller_function, caller_frame)) orelse error.NotAnObject,
        @intFromEnum(StaticMethod.keys) => (try objectEnumerableOwnPropertiesCall(ctx, output, global, args, .keys, caller_function, caller_frame)) orelse error.NotAnObject,
        @intFromEnum(StaticMethod.prevent_extensions) => (try objectPreventExtensionsCall(ctx, output, global, args, caller_function, caller_frame)) orelse error.NotAnObject,
        @intFromEnum(StaticMethod.seal) => (try objectSetIntegrityCall(ctx, output, global, args, .sealed, caller_function, caller_frame)) orelse error.NotAnObject,
        @intFromEnum(StaticMethod.is_sealed) => (try objectTestIntegrityCall(ctx, output, global, args, .sealed)) orelse error.NotAnObject,
        @intFromEnum(StaticMethod.is_frozen) => (try objectTestIntegrityCall(ctx, output, global, args, .frozen)) orelse error.NotAnObject,
        @intFromEnum(StaticMethod.set_prototype_of) => (try objectSetPrototypeOfCall(ctx, output, global, args, caller_function, caller_frame)) orelse error.NotAnObject,
        @intFromEnum(StaticMethod.values) => (try objectEnumerableOwnPropertiesCall(ctx, output, global, args, .values, caller_function, caller_frame)) orelse error.NotAnObject,
        @intFromEnum(StaticMethod.entries) => (try objectEnumerableOwnPropertiesCall(ctx, output, global, args, .entries, caller_function, caller_frame)) orelse error.NotAnObject,
        @intFromEnum(StaticMethod.is) => {
            const lhs = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
            const rhs = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
            return core.JSValue.boolean(lhs.sameValue(rhs));
        },
        @intFromEnum(StaticMethod.freeze) => (try objectSetIntegrityCall(ctx, output, global, args, .frozen, caller_function, caller_frame)) orelse error.NotAnObject,
        @intFromEnum(StaticMethod.from_entries) => (try objectFromEntriesCall(ctx, output, global, args, caller_function, caller_frame)) orelse error.NotAnObject,
        @intFromEnum(StaticMethod.group_by) => (try objectGroupByCall(ctx, output, global, args, caller_function, caller_frame)) orelse error.NotAnObject,
        @intFromEnum(PrototypeMethod.to_string) => try string_ops.objectToStringCall(ctx, output, global, this_value, caller_function, caller_frame),
        @intFromEnum(PrototypeMethod.to_locale_string) => try string_ops.objectToLocaleStringCall(ctx, output, global, this_value, caller_function, caller_frame),
        @intFromEnum(PrototypeMethod.value_of) => try objectValueOfCall(ctx.runtime, global, this_value),
        @intFromEnum(PrototypeMethod.has_own_property) => (try objectPrototypeOwnPropertyCall(ctx, output, global, this_value, id, args, caller_function, caller_frame)) orelse error.NotAnObject,
        @intFromEnum(PrototypeMethod.is_prototype_of) => try objectIsPrototypeOf(ctx, output, global, this_value, args, caller_function, caller_frame),
        @intFromEnum(PrototypeMethod.property_is_enumerable) => (try objectPrototypeOwnPropertyCall(ctx, output, global, this_value, id, args, caller_function, caller_frame)) orelse error.NotAnObject,
        @intFromEnum(PrototypeMethod.define_getter) => (try objectPrototypeDefineAccessorCall(ctx, output, global, this_value, args, true, caller_function, caller_frame)) orelse error.NotAnObject,
        @intFromEnum(PrototypeMethod.define_setter) => (try objectPrototypeDefineAccessorCall(ctx, output, global, this_value, args, false, caller_function, caller_frame)) orelse error.NotAnObject,
        @intFromEnum(PrototypeMethod.lookup_getter) => (try objectPrototypeLookupAccessorCall(ctx, output, global, this_value, args, true, caller_function, caller_frame)) orelse error.NotAnObject,
        @intFromEnum(PrototypeMethod.lookup_setter) => (try objectPrototypeLookupAccessorCall(ctx, output, global, this_value, args, false, caller_function, caller_frame)) orelse error.NotAnObject,
        @intFromEnum(PrototypeMethod.proto_getter) => try objectProtoGetterCall(ctx, output, global, this_value, caller_function, caller_frame),
        @intFromEnum(PrototypeMethod.proto_setter) => try objectProtoSetterCall(ctx, output, global, this_value, if (args.len >= 1) args[0] else core.JSValue.undefinedValue(), caller_function, caller_frame),
        else => error.TypeError,
    };
}

const expectObject = core.value_semantics.expectObject;
pub fn objectIsPrototypeOf(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const builtin_dispatch.Bytecode,
    caller_frame: ?*builtin_dispatch.Frame,
) !core.JSValue {
    if (args.len == 0) return core.JSValue.boolean(false);
    var current = objectFromValue(args[0]) orelse return core.JSValue.boolean(false);
    // ToObject(this): null/undefined throw. A primitive's fresh wrapper can
    // never be on V's prototype chain, but the walk still runs: each
    // [[GetPrototypeOf]] is observable (and may throw) through a Proxy.
    if (this_value.is(.null_value) or this_value.is(.undefined_value)) return error.NullishToObject;
    const this_object = objectFromValue(this_value);
    while (try objectGetPrototypeOfStep(ctx, output, global, current, caller_function, caller_frame)) |prototype| {
        if (prototype == this_object) return core.JSValue.boolean(true);
        current = prototype;
        // A Proxy can make the chain endless (contract C8).
        try exception_ops.pollNativeLoop(ctx, global);
    }
    return core.JSValue.boolean(false);
}

pub fn objectValueOfCall(rt: *core.JSRuntime, global: *core.Object, this_value: core.JSValue) !core.JSValue {
    if (this_value.is(.null_value) or this_value.is(.undefined_value)) return error.NullishToObject;
    if (this_value.is(.object)) return this_value;
    return primitiveObjectForAccess(rt, global, this_value);
}

pub fn objectCreateCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const builtin_dispatch.Bytecode,
    caller_frame: ?*builtin_dispatch.Frame,
) !?core.JSValue {
    const prototype_value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const prototype: ?*core.Object = if (prototype_value.is(.null_value))
        null
    else
        objectFromValue(prototype_value) orelse return @as(?core.JSValue, try throwTypeErrorMessage(ctx, global, "not a prototype"));
    const object = try core.Object.create(ctx.runtime, core.class.ids.object, prototype);
    errdefer core.Object.destroyFromHeader(ctx.runtime, object.gcHeader());
    if (args.len >= 2 and !args[1].is(.undefined_value)) {
        try definePropertiesOnTarget(ctx, output, global, object, args[1], caller_function, caller_frame);
    }
    return object.value();
}

pub fn objectAssignCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const builtin_dispatch.Bytecode,
    caller_frame: ?*builtin_dispatch.Frame,
) !?core.JSValue {
    if (args.len < 1) return error.NullishToObject;
    const globals = [_]core.JSValue{global.value()};
    var values = [_]core.JSValue{core.JSValue.undefinedValue()} ** 2;
    const live: []core.JSValue = &values;
    const slices = [_]core.runtime.ValueRootSlice{ .{ .borrowed = &globals }, .{ .borrowed = args }, .{ .mutable = &live } };
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(ctx.runtime);
    defer roots.deactivate(ctx.runtime);
    if (args[0].is(.null_value) or args[0].is(.undefined_value)) return @as(?core.JSValue, try throwTypeErrorMessage(ctx, global, "Cannot convert undefined or null to object"));
    values[0] = if (objectFromValue(args[0])) |_| args[0] else try primitiveObjectForAccess(ctx.runtime, global, args[0]);
    _ = objectFromValue(values[0]) orelse return error.TypeError;

    for (args[1..]) |source_arg| {
        if (source_arg.is(.null_value) or source_arg.is(.undefined_value)) continue;
        values[1] = if (objectFromValue(source_arg)) |_| source_arg else try primitiveObjectForAccess(ctx.runtime, global, source_arg);
        const source = objectFromValue(values[1]) orelse return error.TypeError;
        const own_keys = try objectRestOwnKeys(ctx, output, global, source);
        defer core.Object.freeKeys(ctx.runtime, own_keys);
        // A Proxy ownKeys result lives only in this native list across the
        // traps and allocations below; keep its atoms alive.
        var own_keys_roots = core.runtime.rootAtomList(&own_keys);
        own_keys_roots.activate(ctx.runtime);
        defer own_keys_roots.deactivate(ctx.runtime);
        if (assignSourceIsOrdinary(objectFromValue(values[1]).?)) {
            // qjs js_object_assign is ONE JS_CopyDataProperties walk with
            // JS_GPN_ENUM_ONLY. For an ordinary
            // (non-exotic, non-proxy) source no per-key descriptor is
            // materialized (the ~ENUM_ONLY descriptor branch at quickjs.c runs
            // only for the exotic fallback). Mirror that single spec-ordered
            // pass here.
            try objectAssignEnumOnly(ctx, output, global, values[0], values[1], objectFromValue(values[1]).?, own_keys, caller_function, caller_frame);
        } else {
            // Proxy / exotic source: qjs clears JS_GPN_ENUM_ONLY
            // and builds a per-key descriptor in the loop
            // so the ownKeys + getOwnPropertyDescriptor traps fire in order.
            // Keep the descriptor-driven single pass that preserves the trap
            // sequence (symbol_pass = null = no extra traversal).
            try objectAssignKeys(ctx, output, global, values[0], values[1], objectFromValue(values[1]).?, own_keys, null, caller_function, caller_frame);
        }
    }

    return values[0];
}

/// True when `Object.assign`'s source is an ordinary object — no proxy
/// handler, no typed-array indexed exotic, no module-namespace bindings,
/// and no exotic own-keys hook. This mirrors qjs's `!p->is_exotic ||
/// !em->get_own_property_names` test: only such a
/// source keeps `JS_GPN_ENUM_ONLY` and reads the enumerable bit straight
/// off the shape. Everything else falls through to the descriptor path so
/// its traps/exotic enumeration fire exactly as qjs's ~ENUM_ONLY branch.
fn assignSourceIsOrdinary(source: *core.Object) bool {
    if (source.proxyTarget() != null) return false;
    if (source.hasExoticMethods()) return false;
    if (source.class_id == core.class.ids.module_ns) return false;
    if (core.object.isTypedArrayObject(source)) return false;
    return true;
}

/// Single ENUM_ONLY CopyDataProperties pass over an ordinary source's own
/// keys (already in spec order: integer indices ascending, then strings in
/// insertion order, then symbols). Each key's enumerability is re-read from
/// the shape right before its Get (step 3.a.iii), then the source getter
/// fires once, in key order, and the value is set on the target (target
/// setters / Proxy traps fire).
fn objectAssignEnumOnly(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    target_value: core.JSValue,
    source_value: core.JSValue,
    source: *core.Object,
    own_keys: []const core.Atom,
    caller_function: ?*const builtin_dispatch.Bytecode,
    caller_frame: ?*builtin_dispatch.Frame,
) !void {
    if (own_keys.len == 0) return;
    // These by-value operands remain in this frame across getters/setters.
    // Keep their addresses stable, including the value being handed to Set.
    var operands = [_]core.JSValue{ global.value(), target_value, source_value, source.value(), core.JSValue.undefinedValue() };
    const slices = [_]core.runtime.ValueRootSlice{.{ .borrowed = &operands }};
    const atoms = [_]core.runtime.AtomRootSlot{.{ .borrowed = own_keys }};
    var roots = core.runtime.ValueRootFrame{ .slices = &slices, .atoms = &atoms };
    roots.activate(ctx.runtime);
    defer roots.deactivate(ctx.runtime);
    // Object.assign step 3.a.iii: re-read each key's own descriptor right
    // before its Get, so an earlier getter that deletes or redefines a later
    // key is observed. An ordinary source has no traps, so the check is a
    // shape read.
    for (own_keys) |key| {
        try exception_ops.pollNativeLoop(ctx, global);
        const live_source = objectFromValue(operands[3]).?;
        if (!(live_source.ownPropertyEnumerable(key) orelse false)) continue;
        operands[4] = try getValueProperty(ctx, output, global, source_value, key, caller_function, caller_frame);
        try setValuePropertyStrict(ctx, output, global, target_value, key, operands[4], caller_function, caller_frame);
    }
}

pub fn objectAssignKeys(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    target_value: core.JSValue,
    source_value: core.JSValue,
    source: *core.Object,
    own_keys: []const core.Atom,
    symbol_pass: ?bool,
    caller_function: ?*const builtin_dispatch.Bytecode,
    caller_frame: ?*builtin_dispatch.Frame,
) !void {
    var operands = [_]core.JSValue{ global.value(), target_value, source_value, source.value(), core.JSValue.undefinedValue() };
    const slices = [_]core.runtime.ValueRootSlice{.{ .borrowed = &operands }};
    const atoms = [_]core.runtime.AtomRootSlot{.{ .borrowed = own_keys }};
    var roots = core.runtime.ValueRootFrame{ .slices = &slices, .atoms = &atoms };
    roots.activate(ctx.runtime);
    defer roots.deactivate(ctx.runtime);
    for (own_keys) |key| {
        try exception_ops.pollNativeLoop(ctx, global);
        const is_symbol = ctx.runtime.atoms.isPublicSymbol(key);
        if (symbol_pass) |pass| {
            if (is_symbol != pass) continue;
        }
        const desc = try objectRestOwnPropertyDescriptor(ctx, output, global, source, key) orelse continue;
        if (desc.enumerable != true) continue;
        operands[4] = try getValueProperty(ctx, output, global, source_value, key, caller_function, caller_frame);
        try setValuePropertyStrict(ctx, output, global, target_value, key, operands[4], caller_function, caller_frame);
    }
}

pub fn objectHasOwnCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const builtin_dispatch.Bytecode,
    caller_frame: ?*builtin_dispatch.Frame,
) !?core.JSValue {
    if (args.len < 1) return error.NullishToObject;
    const globals = [_]core.JSValue{global.value()};
    var values = [_]core.JSValue{core.JSValue.undefinedValue()};
    const live: []core.JSValue = &values;
    const slices = [_]core.runtime.ValueRootSlice{ .{ .borrowed = &globals }, .{ .borrowed = args }, .{ .mutable = &live } };
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(ctx.runtime);
    defer roots.deactivate(ctx.runtime);
    if (args[0].is(.null_value) or args[0].is(.undefined_value)) return error.NullishToObject;
    values[0] = if (objectFromValue(args[0])) |_| args[0] else try primitiveObjectForAccess(ctx.runtime, global, args[0]);
    _ = objectFromValue(values[0]) orelse return error.TypeError;
    const key_value = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
    const atom_id = try toPropertyKeyAtom(ctx, output, global, key_value, caller_function, caller_frame);
    var atom_roots = core.runtime.rootAtoms(.{&atom_id});
    atom_roots.activate(ctx.runtime);
    defer atom_roots.deactivate(ctx.runtime);
    // qjs `js_object_hasOwn` -> `JS_GetOwnPropertyInternal(ctx, NULL, p, atom)`:
    // the desc==NULL existence mode -- no descriptor is built,
    // no value is dup'd, and auto-init instantiation is delayed. Proxies still
    // route through the full getOwnPropertyDescriptor trap inside the wrapper.
    const present = try proxyAwareExistsOwnProperty(ctx, output, global, objectFromValue(values[0]).?, atom_id, caller_function, caller_frame);
    return core.JSValue.boolean(present);
}

/// Exec-direct arm of `Object.prototype.hasOwnProperty` (qjs
/// `js_object_hasOwnProperty`, quickjs.c: JS_ToPropertyKey, then
/// JS_GetOwnPropertyInternal with desc==NULL). Hot leg: an ordinary object
/// receiver (no proxy trap, no typed-array canonical-index rule) and a key
/// that is already an atom (`propertyKeyAtomIfReady`), so neither the
/// ToPropertyKey nor the interning step can run or throw; the existence
/// probe is the same `existsOwnProperty` the generic path reaches. Everything
/// else is the unchanged `objectPrototypeOwnPropertyCall`.
fn objectHasOwnPropertyDirect(
    ctx: *core.JSContext,
    this_value: core.JSValue,
    argv: [*]const core.JSValue,
    argc: u32,
    _: *const core.NativeEntry,
    _: ?*core.Object,
) callconv(.c) core.JSValue {
    const args = argv[0..argc];
    const global = ctx.global orelse return builtin_dispatch.hostErrorToValue(ctx, null, error.InvalidBuiltinRegistry);
    const caller = builtin_dispatch.vmCallerView(ctx);
    const output = caller.output;
    const caller_function = caller.caller_function;
    const caller_frame = caller.caller_frame;
    if (objectFromValue(this_value)) |object| {
        if (args.len >= 1) {
            if (property_ops.propertyKeyAtomIfReady(args[0])) |atom_id| {
                // Same exotic handling as the generic arm (typed-array
                // canonical index, Proxy trap): one predicate, not two.
                const present = proxyAwareExistsOwnProperty(ctx, output, global, object, atom_id, caller_function, caller_frame) catch |err|
                    return builtin_dispatch.hostErrorToValue(ctx, global, err);
                return (core.JSValue.boolean(present));
            }
        }
    }
    return builtin_dispatch.hostResultToValue(ctx, objectHasOwnPropertyHost(
        ctx,
        output,
        global,
        this_value,
        args,
        caller_function,
        caller_frame,
    ));
}

fn objectHasOwnPropertyHost(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const builtin_dispatch.Bytecode,
    caller_frame: ?*builtin_dispatch.Frame,
) HostError!core.JSValue {
    return (try objectPrototypeOwnPropertyCall(
        ctx,
        output,
        global,
        this_value,
        @intFromEnum(PrototypeMethod.has_own_property),
        args,
        caller_function,
        caller_frame,
    )) orelse error.TypeError;
}

test "Object.prototype.hasOwnProperty uses exec_direct on the shared object handler" {
    var found = false;
    for (internal_entries) |entry| {
        if (entry.id != @intFromEnum(PrototypeMethod.has_own_property)) continue;
        found = true;
        try std.testing.expect(core.host_function.genericMagicHandler(entry).? == &objectCall);
        try std.testing.expect(entry.managed != null);
        try std.testing.expect(entry.managed.? == &objectHasOwnPropertyDirect);
    }
    try std.testing.expect(found);
}

pub fn objectPrototypeOwnPropertyCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    method_id: u32,
    args: []const core.JSValue,
    caller_function: ?*const builtin_dispatch.Bytecode,
    caller_frame: ?*builtin_dispatch.Frame,
) !?core.JSValue {
    if (method_id != @intFromEnum(PrototypeMethod.has_own_property) and method_id != @intFromEnum(PrototypeMethod.property_is_enumerable)) return null;

    const borrowed = [_]core.JSValue{ global.value(), this_value };
    var values = [_]core.JSValue{core.JSValue.undefinedValue()};
    const live: []core.JSValue = &values;
    const slices = [_]core.runtime.ValueRootSlice{ .{ .borrowed = &borrowed }, .{ .borrowed = args }, .{ .mutable = &live } };
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(ctx.runtime);
    defer roots.deactivate(ctx.runtime);

    const key_value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const atom_id = try toPropertyKeyAtom(ctx, output, global, key_value, caller_function, caller_frame);
    var atom_roots = core.runtime.rootAtoms(.{&atom_id});
    atom_roots.activate(ctx.runtime);
    defer atom_roots.deactivate(ctx.runtime);

    if (this_value.is(.null_value) or this_value.is(.undefined_value)) return error.NullishToObject;
    values[0] = if (objectFromValue(this_value)) |_| this_value else try primitiveObjectForAccess(ctx.runtime, global, this_value);
    const object = try property_ops.expectObject(values[0]);
    // `hasOwnProperty` is the desc==NULL existence mode of
    // `JS_GetOwnPropertyInternal` (qjs `js_object_hasOwnProperty`,
    // quickjs.c): probe presence with no descriptor materialization.
    // `propertyIsEnumerable` (qjs `js_object_propertyIsEnumerable`) still
    // needs the enumerable flag, so it keeps the full-descriptor path.
    if (method_id == @intFromEnum(PrototypeMethod.has_own_property)) {
        const present = try proxyAwareExistsOwnProperty(ctx, output, global, object, atom_id, caller_function, caller_frame);
        return core.JSValue.boolean(present);
    }
    const desc = try proxyAwareOwnPropertyDescriptor(ctx, output, global, object, atom_id, caller_function, caller_frame) orelse return core.JSValue.boolean(false);
    return core.JSValue.boolean(desc.enumerable orelse false);
}

pub fn objectPrototypeDefineAccessorCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    args: []const core.JSValue,
    getter: bool,
    caller_function: ?*const builtin_dispatch.Bytecode,
    caller_frame: ?*builtin_dispatch.Frame,
) !?core.JSValue {
    const borrowed = [_]core.JSValue{ global.value(), this_value };
    var values = [_]core.JSValue{core.JSValue.undefinedValue()};
    const live: []core.JSValue = &values;
    const slices = [_]core.runtime.ValueRootSlice{ .{ .borrowed = &borrowed }, .{ .borrowed = args }, .{ .mutable = &live } };
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(ctx.runtime);
    defer roots.deactivate(ctx.runtime);
    if (this_value.is(.null_value) or this_value.is(.undefined_value)) return error.NullishToObject;
    values[0] = if (objectFromValue(this_value)) |_| this_value else try primitiveObjectForAccess(ctx.runtime, global, this_value);
    _ = objectFromValue(values[0]) orelse return error.TypeError;
    const accessor_value = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
    if (!isCallableValue(accessor_value)) return error.NotAFunction;
    const key_value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const key = try toPropertyKeyAtom(ctx, output, global, key_value, caller_function, caller_frame);
    var atom_roots = core.runtime.rootAtoms(.{&key});
    atom_roots.activate(ctx.runtime);
    defer atom_roots.deactivate(ctx.runtime);
    const object = objectFromValue(values[0]).?;

    const desc = if (getter) core.Descriptor{
        .kind = .accessor,
        .getter = accessor_value,
        .getter_present = true,
        .enumerable = true,
        .configurable = true,
    } else core.Descriptor{
        .kind = .accessor,
        .setter = accessor_value,
        .setter_present = true,
        .enumerable = true,
        .configurable = true,
    };
    // DefinePropertyOrThrow (B.2.2.2 step 5) through the object's own
    // [[DefineOwnProperty]]: proxies and typed arrays have their own; an
    // ordinary object's failure throws with its specific message.
    const defined = try defineOwnPropertyVm(ctx, output, global, object, key, desc, .keep_error, caller_function, caller_frame);
    if (!defined) return error.CannotDefineProperty;
    return core.JSValue.undefinedValue();
}

pub fn objectPrototypeLookupAccessorCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    args: []const core.JSValue,
    getter: bool,
    caller_function: ?*const builtin_dispatch.Bytecode,
    caller_frame: ?*builtin_dispatch.Frame,
) !?core.JSValue {
    const borrowed = [_]core.JSValue{ global.value(), this_value };
    var values = [_]core.JSValue{core.JSValue.undefinedValue()};
    const live: []core.JSValue = &values;
    const slices = [_]core.runtime.ValueRootSlice{ .{ .borrowed = &borrowed }, .{ .borrowed = args }, .{ .mutable = &live } };
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(ctx.runtime);
    defer roots.deactivate(ctx.runtime);
    if (this_value.is(.null_value) or this_value.is(.undefined_value)) return error.NullishToObject;
    values[0] = if (objectFromValue(this_value)) |_| this_value else try primitiveObjectForAccess(ctx.runtime, global, this_value);
    _ = objectFromValue(values[0]) orelse return error.TypeError;
    const key_value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const key = try toPropertyKeyAtom(ctx, output, global, key_value, caller_function, caller_frame);
    var atom_roots = core.runtime.rootAtoms(.{&key});
    atom_roots.activate(ctx.runtime);
    defer atom_roots.deactivate(ctx.runtime);

    while (true) {
        const desc = try objectRestOwnPropertyDescriptor(ctx, output, global, objectFromValue(values[0]).?, key);
        if (desc) |item| {
            if (item.kind != .accessor) return core.JSValue.undefinedValue();
            if (getter) return if (item.getter_present) item.getter else core.JSValue.undefinedValue();
            return if (item.setter_present) item.setter else core.JSValue.undefinedValue();
        }
        values[0] = ((try objectGetPrototypeOfStep(ctx, output, global, objectFromValue(values[0]).?, caller_function, caller_frame)) orelse return core.JSValue.undefinedValue()).value();
    }
}

pub fn objectFromEntriesCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const builtin_dispatch.Bytecode,
    caller_frame: ?*builtin_dispatch.Frame,
) !?core.JSValue {
    if (args.len < 1) return error.NotIterable;
    const globals = [_]core.JSValue{global.value()};
    // [0] result, [1] iterator, [2] entry, [3] key, [4] value, [5] next
    var values = [_]core.JSValue{core.JSValue.undefinedValue()} ** 6;
    const live: []core.JSValue = &values;
    const slices = [_]core.runtime.ValueRootSlice{ .{ .borrowed = &globals }, .{ .borrowed = args }, .{ .mutable = &live } };
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(ctx.runtime);
    defer roots.deactivate(ctx.runtime);
    values[0] = (try core.Object.create(ctx.runtime, core.class.ids.object, objectPrototypeFromGlobal(ctx.runtime, global))).value();
    const record = try iteratorGetIterator(ctx, output, global, args[0], caller_function, caller_frame);
    values[1] = record.iterator;
    values[5] = record.next;

    while (true) {
        const step = try iteratorStepValue(ctx, output, global, .{ .iterator = values[1], .next = values[5] });
        if (step.done) return values[0];
        values[2] = step.value;

        if (!values[2].is(.object)) {
            try iterator_ops.iteratorCloseForThrow(ctx, output, global, values[1]);
            return try throwTypeErrorMessage(ctx, global, "iterator value is not an entry object");
        }
        values[3] = getValueProperty(ctx, output, global, values[2], core.Atom.taggedInt(0), caller_function, caller_frame) catch |err| {
            try iterator_ops.iteratorCloseForThrow(ctx, output, global, values[1]);
            return err;
        };
        values[4] = getValueProperty(ctx, output, global, values[2], core.Atom.taggedInt(1), caller_function, caller_frame) catch |err| {
            try iterator_ops.iteratorCloseForThrow(ctx, output, global, values[1]);
            return err;
        };
        const key = toPropertyKeyAtom(ctx, output, global, values[3], caller_function, caller_frame) catch |err| {
            try iterator_ops.iteratorCloseForThrow(ctx, output, global, values[1]);
            return err;
        };
        var atom_roots = core.runtime.rootAtoms(.{&key});
        atom_roots.activate(ctx.runtime);
        defer atom_roots.deactivate(ctx.runtime);
        createDataPropertyOrThrow(ctx, output, global, objectFromValue(values[0]).?, key, values[4], caller_function, caller_frame) catch |err| {
            try iterator_ops.iteratorCloseForThrow(ctx, output, global, values[1]);
            return err;
        };
        @memset(values[2..5], core.JSValue.undefinedValue());
    }
}

pub fn objectGroupByCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const builtin_dispatch.Bytecode,
    caller_frame: ?*builtin_dispatch.Frame,
) !?core.JSValue {
    if (args.len < 2 or !isCallableValue(args[1])) return error.NotAFunction;
    const globals = [_]core.JSValue{global.value()};
    // [0] result, [1] iterator, [2] value, [3] key, [4] next
    var values = [_]core.JSValue{core.JSValue.undefinedValue()} ** 5;
    const live: []core.JSValue = &values;
    const slices = [_]core.runtime.ValueRootSlice{ .{ .borrowed = &globals }, .{ .borrowed = args }, .{ .mutable = &live } };
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(ctx.runtime);
    defer roots.deactivate(ctx.runtime);
    values[0] = (try core.Object.create(ctx.runtime, core.class.ids.object, null)).value();

    const record = try iteratorGetIterator(ctx, output, global, args[0], caller_function, caller_frame);
    values[1] = record.iterator;
    values[4] = record.next;
    var callback_call = CallSite.initInternal(
        ctx,
        output,
        global,
        core.JSValue.undefinedValue(),
        args[1],
        caller_function,
        caller_frame,
    );
    callback_call.activateRoots();
    defer callback_call.deinit();

    var index: usize = 0;
    while (true) {
        const max_safe_integer: usize = 9007199254740991;
        if (index >= max_safe_integer) {
            try iterator_ops.iteratorCloseForThrow(ctx, output, global, values[1]);
            return error.TypeError;
        }
        const step = try iteratorStepValue(ctx, output, global, .{ .iterator = values[1], .next = values[4] });
        if (step.done) return values[0];
        values[2] = step.value;

        const index_value = value_ops.numberToValue(@floatFromInt(index));
        values[3] = callback_call.call(&.{ values[2], index_value }) catch |err| {
            try iterator_ops.iteratorCloseForThrow(ctx, output, global, values[1]);
            return err;
        };
        const key = toPropertyKeyAtom(ctx, output, global, values[3], caller_function, caller_frame) catch |err| {
            try iterator_ops.iteratorCloseForThrow(ctx, output, global, values[1]);
            return err;
        };
        try appendObjectGroupByValue(ctx, output, global, values[0], objectFromValue(values[0]).?, key, values[2], caller_function, caller_frame);
        @memset(values[2..4], core.JSValue.undefinedValue());
        index += 1;
    }
}

pub fn objectSetIntegrityCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    level: IntegrityLevel,
    caller_function: ?*const builtin_dispatch.Bytecode,
    caller_frame: ?*builtin_dispatch.Frame,
) !?core.JSValue {
    const target_value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const object = objectFromValue(target_value) orelse return target_value;
    _ = try objectPreventExtensionsCall(ctx, output, global, args, caller_function, caller_frame);

    const own_keys = try objectRestOwnKeys(ctx, output, global, object);
    defer core.Object.freeKeys(ctx.runtime, own_keys);
    // A Proxy ownKeys result lives only in this native list across the
    // traps and allocations below; keep its atoms alive.
    var own_keys_roots = core.runtime.rootAtomList(&own_keys);
    own_keys_roots.activate(ctx.runtime);
    defer own_keys_roots.deactivate(ctx.runtime);
    for (own_keys) |key| {
        const desc = if (level == .frozen)
            try objectRestOwnPropertyDescriptor(ctx, output, global, object, key)
        else
            null;

        const next_desc = switch (level) {
            .sealed => core.Descriptor.generic(null, false),
            .frozen => blk: {
                // SetIntegrityLevel frozen step 7.b.ii: a key gone by now
                // (undefined currentDesc) is skipped.
                const item = desc orelse continue;
                if (item.kind == .data) break :blk core.Descriptor{
                    .kind = .data,
                    .value_present = false,
                    .writable = false,
                    .configurable = false,
                };
                break :blk core.Descriptor.generic(null, false);
            },
        };
        const defined = try defineOwnPropertyVm(ctx, output, global, object, key, next_desc, .keep_error, caller_function, caller_frame);
        if (!defined) return error.CannotDefineProperty;
    }
    return target_value;
}

pub fn objectTestIntegrityCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    level: IntegrityLevel,
) !?core.JSValue {
    const target_value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const object = objectFromValue(target_value) orelse return core.JSValue.boolean(true);
    // TestIntegrityLevel (§7.3.16) asks IsExtensible first; QuickJS walks
    // the keys first and asks last, which is observable through proxy traps.
    if (try proxyAwareIsExtensible(ctx, output, global, object, null, null)) return core.JSValue.boolean(false);
    const own_keys = try objectRestOwnKeys(ctx, output, global, object);
    defer core.Object.freeKeys(ctx.runtime, own_keys);
    // A Proxy ownKeys result lives only in this native list across the
    // traps and allocations below; keep its atoms alive.
    var own_keys_roots = core.runtime.rootAtomList(&own_keys);
    own_keys_roots.activate(ctx.runtime);
    defer own_keys_roots.deactivate(ctx.runtime);
    for (own_keys) |key| {
        const desc = try objectRestOwnPropertyDescriptor(ctx, output, global, object, key) orelse continue;
        if (desc.configurable == true) return core.JSValue.boolean(false);
        if (level == .frozen and desc.kind == .data and desc.writable == true) return core.JSValue.boolean(false);
    }
    return core.JSValue.boolean(true);
}

pub fn appendObjectGroupByValue(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    out_value: core.JSValue,
    out: *core.Object,
    key: core.Atom,
    value: core.JSValue,
    caller_function: ?*const builtin_dispatch.Bytecode,
    caller_frame: ?*builtin_dispatch.Frame,
) !void {
    const borrowed = [_]core.JSValue{ global.value(), out_value, out.value() };
    var values = [_]core.JSValue{ value, core.JSValue.undefinedValue() };
    const live: []core.JSValue = &values;
    const slices = [_]core.runtime.ValueRootSlice{ .{ .borrowed = &borrowed }, .{ .mutable = &live } };
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(ctx.runtime);
    defer roots.deactivate(ctx.runtime);
    var atom_roots = core.runtime.rootAtoms(.{&key});
    atom_roots.activate(ctx.runtime);
    defer atom_roots.deactivate(ctx.runtime);
    values[1] = getValueProperty(ctx, output, global, out_value, key, caller_function, caller_frame) catch core.JSValue.undefinedValue();
    if (values[1].is(.undefined_value)) {
        values[1] = (try core.Object.createArray(ctx.runtime, arrayPrototypeFromGlobal(ctx.runtime, global))).value();
        try createDataPropertyOrThrow(ctx, output, global, out, key, values[1], caller_function, caller_frame);
    }
    const group = objectFromValue(values[1]) orelse return error.TypeError;
    try createDataPropertyOrThrow(ctx, output, global, group, core.Atom.taggedInt(group.arrayLength()), values[0], caller_function, caller_frame);
}

test "Object.groupBy new group define failure releases group once" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();

    const global = try core.Object.create(rt, core.class.ids.object, null);
    const out = try core.Object.create(rt, core.class.ids.object, null);
    out.preventExtensions();

    const key = try rt.internAtom("group");

    try std.testing.expectError(
        error.NotExtensible,
        appendObjectGroupByValue(ctx, null, global, out.value(), out, key, core.JSValue.int32(1), null, null),
    );
    // The failed append leaves a half-built group object behind; the claim is
    // that it is released exactly once and nothing else leaks. Under the
    // tracer that release is a collection, and `global`/`out` are held only by
    // Zig locals, which the precise root scan does not see -- they have to be
    // named or the collection sweeps the objects the test is still counting.
    var kept_global: ?*core.Object = global;
    var kept_out: ?*core.Object = out;
    var roots = core.runtime.rootObjects(.{ &kept_global, &kept_out });
    roots.activate(rt);
    defer roots.deactivate(rt);
    _ = try rt.collectForTest();
    // RealmContext and Shapes are GC objects: global and out share one live
    // empty root shape, alongside their owning context.
    try std.testing.expectEqual(@as(usize, 4), rt.gc.liveCount());
}

pub fn objectPreventExtensionsCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const builtin_dispatch.Bytecode,
    caller_frame: ?*builtin_dispatch.Frame,
) !?core.JSValue {
    const target_value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const object = objectFromValue(target_value) orelse return target_value;
    if (!try proxyAwarePreventExtensions(ctx, output, global, object, caller_function, caller_frame)) return error.CannotPreventExtensions;
    return target_value;
}

pub fn getOwnPropertyDescriptorCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const builtin_dispatch.Bytecode,
    caller_frame: ?*builtin_dispatch.Frame,
) !?core.JSValue {
    if (args.len < 1) return error.NullishToObject;
    const globals = [_]core.JSValue{global.value()};
    var values = [_]core.JSValue{core.JSValue.undefinedValue()};
    const live: []core.JSValue = &values;
    const slices = [_]core.runtime.ValueRootSlice{ .{ .borrowed = &globals }, .{ .borrowed = args }, .{ .mutable = &live } };
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(ctx.runtime);
    defer roots.deactivate(ctx.runtime);
    if (args[0].is(.null_value) or args[0].is(.undefined_value)) return error.NullishToObject;
    values[0] = if (objectFromValue(args[0])) |_| args[0] else try primitiveObjectForAccess(ctx.runtime, global, args[0]);
    _ = objectFromValue(values[0]) orelse return error.TypeError;
    const key_value = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
    const atom_id = try toPropertyKeyAtom(ctx, output, global, key_value, caller_function, caller_frame);
    var atom_roots = core.runtime.rootAtoms(.{&atom_id});
    atom_roots.activate(ctx.runtime);
    defer atom_roots.deactivate(ctx.runtime);
    var desc = try proxyAwareOwnPropertyDescriptor(ctx, output, global, objectFromValue(values[0]).?, atom_id, caller_function, caller_frame) orelse return core.JSValue.undefinedValue();
    call.materializeMappedArgumentsDescriptorValue(ctx.runtime, objectFromValue(values[0]).?, atom_id, &desc);
    const desc_value = try descriptorObjectFromDescriptor(ctx.runtime, global, desc);
    return desc_value;
}

pub fn objectGetPrototypeOfCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const builtin_dispatch.Bytecode,
    caller_frame: ?*builtin_dispatch.Frame,
) !?core.JSValue {
    if (args.len < 1) return error.NullishToObject;
    if (args[0].is(.null_value) or args[0].is(.undefined_value)) return @as(?core.JSValue, try throwTypeErrorMessage(ctx, global, "not an object"));
    const object_value = if (objectFromValue(args[0])) |_| args[0] else try primitiveObjectForAccess(ctx.runtime, global, args[0]);
    const object = objectFromValue(object_value) orelse return error.TypeError;
    return try objectGetPrototypeOfValue(ctx, output, global, object, caller_function, caller_frame);
}

pub fn getOwnPropertyDescriptorsCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const builtin_dispatch.Bytecode,
    caller_frame: ?*builtin_dispatch.Frame,
) !?core.JSValue {
    if (args.len < 1) return error.NullishToObject;
    if (args[0].is(.null_value) or args[0].is(.undefined_value)) return error.NullishToObject;
    // Source, result, and the descriptor being installed all cross getters,
    // proxy traps, and allocations; reload each from its slot afterwards.
    // The result is published once created, so failure leaves it to the GC.
    const globals = [_]core.JSValue{global.value()};
    var values = [_]core.JSValue{core.JSValue.undefinedValue()} ** 3;
    const live: []core.JSValue = &values;
    const slices = [_]core.runtime.ValueRootSlice{ .{ .borrowed = &globals }, .{ .borrowed = args }, .{ .mutable = &live } };
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(ctx.runtime);
    defer roots.deactivate(ctx.runtime);
    values[0] = if (objectFromValue(args[0])) |_| args[0] else try primitiveObjectForAccess(ctx.runtime, global, args[0]);
    _ = objectFromValue(values[0]) orelse return error.NotAnObject;
    const own_keys = try objectRestOwnKeys(ctx, output, global, objectFromValue(values[0]).?);
    defer core.Object.freeKeys(ctx.runtime, own_keys);
    const atoms = [_]core.runtime.AtomRootSlot{.{ .borrowed = own_keys }};
    var atom_roots = core.runtime.ValueRootFrame{ .atoms = &atoms };
    atom_roots.activate(ctx.runtime);
    defer atom_roots.deactivate(ctx.runtime);

    values[1] = (try core.Object.create(ctx.runtime, core.class.ids.object, objectPrototypeFromGlobal(ctx.runtime, global))).value();
    for (own_keys) |key| {
        var desc = (try objectRestOwnPropertyDescriptor(ctx, output, global, objectFromValue(values[0]).?, key)) orelse continue;
        call.materializeMappedArgumentsDescriptorValue(ctx.runtime, objectFromValue(values[0]).?, key, &desc);
        values[2] = try descriptorObjectFromDescriptor(ctx.runtime, global, desc);
        try createDataPropertyOrThrow(ctx, output, global, objectFromValue(values[1]).?, key, values[2], caller_function, caller_frame);
        values[2] = core.JSValue.undefinedValue();
    }
    return values[1];
}

pub const OwnPropertyKeyFilter = enum {
    string,
    symbol,
};
pub inline fn objectOwnPropertyKeysCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    filter: OwnPropertyKeyFilter,
    caller_function: ?*const builtin_dispatch.Bytecode,
    caller_frame: ?*builtin_dispatch.Frame,
) !?core.JSValue {
    return objectEnumerableOwnPropertiesCall(
        ctx,
        output,
        global,
        args,
        switch (filter) {
            .string => .own_names,
            .symbol => .own_symbols,
        },
        caller_function,
        caller_frame,
    );
}

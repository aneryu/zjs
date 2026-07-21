const std = @import("std");
const bytecode = @import("../bytecode.zig");
const builtin_dispatch = @import("builtin_dispatch.zig");
const core = @import("../core/root.zig");
const method_ids = core.host_function.builtin_method_ids;
const call_mod = @import("call.zig");
const construct_mod = @import("construct.zig");
const date_vm = @import("date_ops.zig");
const frame_mod = @import("frame.zig");
const iter_vm = @import("iterator_ops.zig");
const property_ops = @import("property_ops.zig");
const zjs_vm = @import("zjs_vm.zig");
const value_ops = @import("value_ops.zig");
const value_vm = @import("vm_value.zig");
const stack_mod = @import("stack.zig");
const HostError = exceptions.HostError;
const op = bytecode.opcode.op;
const atom_buffer = (core.atom.predefinedId("buffer", .string)).?;
const atom_byte_length = (core.atom.predefinedId("byteLength", .string)).?;
const atom_byte_offset = (core.atom.predefinedId("byteOffset", .string)).?;
const exceptions = @import("exceptions.zig");
const exception_ops = @import("vm_exception_ops.zig");
const call_runtime = @import("call_runtime.zig");
const array_ops = @import("array_ops.zig");
const builtin_glue = @import("builtin_glue.zig");
const module_mod = @import("module.zig");
const coercion_ops = @import("coercion_ops.zig");
const error_stack_ops = @import("error_stack_ops.zig");
const eval_ops = @import("eval_ops.zig");
const promise_ops = @import("promise_ops.zig");
const property_ic = @import("property_ic.zig");
const regexp_fastpath = @import("regexp_fastpath.zig");
const regexp_properties = @import("../libs/unicode.zig").regexp_properties;
const slot_ops = @import("slot_ops.zig");
const string_ops = @import("string_ops.zig");
const value_slot = @import("value_slot.zig");

pub const Step = enum { done, continue_loop };

// --- Dynamically gathered call_runtime aliases (excluding local definitions) ---
const DataViewConstructorArgs = builtin_glue.DataViewConstructorArgs;
const DynamicFunctionKind = call_runtime.DynamicFunctionKind;
const IntegrityLevel = call_runtime.IntegrityLevel;
const LengthIndexAtom = array_ops.LengthIndexAtom;
const RegExpMatch = string_ops.RegExpMatch;
const ValueSliceRoot = array_ops.ValueSliceRoot;
const CellSliceRoot = array_ops.CellSliceRoot;
const addCollectionEntriesFromArray = array_ops.addCollectionEntriesFromArray;
const addCollectionEntriesFromIterator = builtin_glue.addCollectionEntriesFromIterator;
const aggregateErrorsIterableToArray = array_ops.aggregateErrorsIterableToArray;
const anchoredBinaryPropertyMatches = string_ops.anchoredBinaryPropertyMatches;
const appendDecodedRegExpGroupName = regexp_fastpath.appendDecodedRegExpGroupName;
const appendOwnedAtom = core.atom.appendOwnedAtom;
const arrayLengthAssignmentValue = array_ops.arrayLengthAssignmentValue;
const arrayLengthDefineValue = array_ops.arrayLengthDefineValue;
const arrayPrototypeFromGlobal = array_ops.arrayPrototypeFromGlobal;
const arrayPrototypeValuesFromGlobal = array_ops.arrayPrototypeValuesFromGlobal;
const asyncFunctionPrototypeFromGlobal = promise_ops.asyncFunctionPrototypeFromGlobal;
const asyncGeneratorFunctionPrototypeFromGlobal = promise_ops.asyncGeneratorFunctionPrototypeFromGlobal;
const asyncGeneratorPrototypeFromGlobal = promise_ops.asyncGeneratorPrototypeFromGlobal;
const atomListContains = core.atom.atomListContains;
const callAccessorSetter = call_runtime.callAccessorSetter;
const callSiteFunctionNameValue = error_stack_ops.callSiteFunctionNameValue;
const callValueOrBytecode = call_runtime.callValueOrBytecode;
const captureErrorStack = error_stack_ops.captureErrorStack;
const closeIteratorForFromEntriesAbrupt = call_runtime.closeIteratorForFromEntriesAbrupt;
const constructValueOrBytecode = call_runtime.constructValueOrBytecode;
const createArrayFromArgs = array_ops.createArrayFromArgs;
const createIteratorResult = call_runtime.createIteratorResult;
const createRegExpIndexPair = regexp_fastpath.createRegExpIndexPair;
const createRegExpMatchArrayFromValue = string_ops.createRegExpMatchArrayFromValue;
const createStringFromByteUnits = string_ops.createStringFromByteUnits;
const currentFrameFunctionIsStrict = call_runtime.currentFrameFunctionIsStrict;
const defineNativeDataMethod = builtin_glue.defineNativeDataMethod;
const defineStringWrapperIndexProperty = string_ops.defineStringWrapperIndexProperty;
const ensureVarRefsCapacity = frame_mod.ensureVarRefsCapacity;
const findPropertyEscapeMatch = string_ops.findPropertyEscapeMatch;
const findUnicodePropertyOnlyClassMatch = string_ops.findUnicodePropertyOnlyClassMatch;
const functionBytecodeFromValue = call_runtime.functionBytecodeFromValue;
const functionBytecodeUsesImportMeta = eval_ops.functionBytecodeUsesImportMeta;
const functionConstructorFromGlobal = builtin_glue.functionConstructorFromGlobal;
const functionNameValueFromAtom = call_runtime.functionNameValueFromAtom;
const functionRealmGlobal = call_runtime.functionRealmGlobal;
const functionRuntimeStrict = call_runtime.functionRuntimeStrict;
const getFastStringPrimitiveDataProperty = string_ops.getFastStringPrimitiveDataProperty;
const getStringIndexValue = string_ops.getStringIndexValue;
const importMetaUrlValue = module_mod.importMetaUrlValue;
const installLexicalPrivateNameRemap = call_runtime.installLexicalPrivateNameRemap;
const isBlockedByUnscopables = call_runtime.isBlockedByUnscopables;
const isCallableValue = call_runtime.isCallableValue;
const isConstructorLike = call_runtime.isConstructorLike;
const isFunctionLikeClass = call_runtime.isFunctionLikeClass;
const lengthIndexValue = array_ops.lengthIndexValue;
const mappedArgumentsValue = call_runtime.mappedArgumentsValue;
const ordinarySetWithReceiver = call_runtime.ordinarySetWithReceiver;
const qjsBigIntPrototypeToString = string_ops.qjsBigIntPrototypeToString;
const qjsCreateArrayDataOrTypedArrayElement = array_ops.qjsCreateArrayDataOrTypedArrayElement;
const qjsDefineToStringTag = string_ops.qjsDefineToStringTag;
const qjsIteratorClose = call_runtime.qjsIteratorClose;
const qjsObjectEntryArrayValue = array_ops.qjsObjectEntryArrayValue;
const qjsReflectConstructGenericCallable = call_runtime.qjsReflectConstructGenericCallable;
const qjsRegExpAutoInitBuiltinMatches = string_ops.qjsRegExpAutoInitBuiltinMatches;
const qjsRegExpAutoInitAccessorBuiltinMatches = string_ops.qjsRegExpAutoInitAccessorBuiltinMatches;
const qjsRegExpNativeBuiltinMatches = string_ops.qjsRegExpNativeBuiltinMatches;
const readUtf16CodePoint = string_ops.readUtf16CodePoint;
const regExpConstructorFromGlobal = regexp_fastpath.regExpConstructorFromGlobal;
const regExpFlagsContain = regexp_fastpath.regExpFlagsContain;
const rejectModuleNamespaceSuperSet = promise_ops.rejectModuleNamespaceSuperSet;
const remapPrivateAtomForOperation = call_runtime.remapPrivateAtomForOperation;
const runGeneratorParameterInit = call_runtime.runGeneratorParameterInit;
const setFailureShouldThrow = call_runtime.setFailureShouldThrow;
const setMappedArgumentsValue = call_runtime.setMappedArgumentsValue;
const storeRealmValue = builtin_glue.storeRealmValue;
const stringObjectHasIndexProperty = string_ops.stringObjectHasIndexProperty;
const stringSliceValue = string_ops.stringSliceValue;
const throwPrivateBrandTypeError = call_runtime.throwPrivateBrandTypeError;
const throwRangeErrorMessage = exception_ops.throwRangeErrorMessage;
const throwSetFailureTypeError = call_runtime.throwSetFailureTypeError;
const throwTypeErrorIntrinsicForGlobal = call_runtime.throwTypeErrorIntrinsicForGlobal;
const throwTypeErrorMessage = exception_ops.throwTypeErrorMessage;
const toLengthIndex = coercion_ops.toLengthIndex;
const toPrimitiveForNumber = coercion_ops.toPrimitiveForNumber;
const toPrimitiveForString = string_ops.toPrimitiveForString;
const toStringForAnnexB = string_ops.toStringForAnnexB;
const typedArrayCanonicalGet = array_ops.typedArrayCanonicalGet;
const typedArrayCanonicalHas = array_ops.typedArrayCanonicalHas;
const typedArrayCanonicalOwnDescriptor = array_ops.typedArrayCanonicalOwnDescriptor;
const typedArrayCanonicalIndexExists = array_ops.typedArrayCanonicalIndexExists;
const typedArrayCanonicalSet = array_ops.typedArrayCanonicalSet;
const typedArrayDefineOwnPropertyVm = array_ops.typedArrayDefineOwnPropertyVm;
const typedArrayOwnKeys = array_ops.typedArrayOwnKeys;
const typedArrayPrototypeSet = array_ops.typedArrayPrototypeSet;
const valueTruthy = coercion_ops.valueTruthy;
const varRefCellFromValue = slot_ops.varRefCellFromValue;

pub fn objectPrototypeFromGlobal(rt: *core.JSRuntime, global: *core.Object) ?*core.Object {
    // Use the realm-cached `%Object.prototype%` (O(1) array index, like QuickJS's
    // `class_proto[JS_CLASS_OBJECT]`) instead of resolving `global.Object.prototype`
    // by two property-hash lookups on EVERY object allocation. `arrayPrototypeFromGlobal`
    // already takes this fast path; `{}` literals went through the slow path and it
    // showed up as ~7.7% of empty-object allocation. `Object.prototype` is
    // non-writable/non-configurable so the cached value never goes stale.
    if (global.cachedRealmValue(.object_prototype)) |stored| {
        return property_ops.expectObject(stored) catch null;
    }
    return constructorPrototypeFromGlobalAtom(rt, global, core.atom.ids.Object);
}

pub fn constructorPrototypeFromGlobal(rt: *core.JSRuntime, global: *core.Object, constructor_name: []const u8) ?*core.Object {
    const ctor_key = rt.internAtom(constructor_name) catch return null;
    defer rt.atoms.free(ctor_key);
    return constructorPrototypeFromGlobalAtom(rt, global, ctor_key);
}

pub fn constructorPrototypeFromGlobalAtom(rt: *core.JSRuntime, global: *core.Object, constructor_atom: core.Atom) ?*core.Object {
    if (global.getOwnDataObjectBorrowed(constructor_atom)) |constructor| {
        if (constructor.getOwnDataObjectBorrowed(core.atom.ids.prototype)) |prototype| return prototype;
    }
    const constructor_value = global.getProperty(constructor_atom);
    defer constructor_value.free(rt);
    const object_constructor = property_ops.expectObject(constructor_value) catch return null;
    if (object_constructor.getOwnDataObjectBorrowed(core.atom.ids.prototype)) |prototype| return prototype;
    const prototype_value = object_constructor.getProperty(core.atom.ids.prototype);
    defer prototype_value.free(rt);
    return property_ops.expectObject(prototype_value) catch null;
}

pub fn functionPrototypeFromGlobal(rt: *core.JSRuntime, global: *core.Object) ?*core.Object {
    if (global.getOwnDataObjectBorrowed(core.atom.ids.Function)) |constructor| {
        if (constructor.getOwnDataObjectBorrowed(core.atom.ids.prototype)) |prototype| return prototype;
    }
    const function_value = global.getProperty(core.atom.ids.Function);
    defer function_value.free(rt);
    const function_constructor = property_ops.expectObject(function_value) catch return null;
    if (function_constructor.getOwnDataObjectBorrowed(core.atom.ids.prototype)) |prototype| return prototype;
    const prototype_value = function_constructor.getProperty(core.atom.ids.prototype);
    defer prototype_value.free(rt);
    return property_ops.expectObject(prototype_value) catch null;
}

pub fn cachedRealmObject(global: *core.Object, slot: core.object.RealmValueSlot) ?*core.Object {
    const stored = global.cachedRealmValue(slot) orelse return null;
    return property_ops.expectObject(stored) catch null;
}

pub fn primitivePrototypeFromRealmOrGlobal(
    rt: *core.JSRuntime,
    global: *core.Object,
    slot: core.object.RealmValueSlot,
    constructor_atom: core.Atom,
) ?*core.Object {
    // Mirror QuickJS JS_GetPrototypePrimitive (quickjs.c:7995-8011): primitive
    // prototype lookup reads ctx->class_proto[...] directly. The realm slot is
    // the intrinsic pointer; fallback preserves bare-runtime/global-walk behavior.
    if (cachedRealmObject(global, slot)) |stored| return stored;
    return constructorPrototypeFromGlobalAtom(rt, global, constructor_atom);
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
    if (primitive.isBool()) {
        const constructor_atom = comptime (core.atom.predefinedId("Boolean", .string)).?;
        return primitivePrototypeFromRealmOrGlobal(rt, global, .boolean_prototype, constructor_atom);
    }
    if (primitive.isBigInt()) {
        const constructor_atom = comptime (core.atom.predefinedId("BigInt", .string)).?;
        return primitivePrototypeFromRealmOrGlobal(rt, global, .bigint_prototype, constructor_atom);
    }
    if (primitive.isSymbol()) {
        const constructor_atom = comptime (core.atom.predefinedId("Symbol", .string)).?;
        return primitivePrototypeFromRealmOrGlobal(rt, global, .symbol_prototype, constructor_atom);
    }
    return null;
}

/// Materialize an ordinary function's ThisBinding on first observation.
/// QuickJS keeps the raw `this_obj` through JS_CallInternal and performs
/// sloppy nullish substitution / primitive ToObject in OP_push_this. Arrow
/// capture and direct eval are zjs's other observation points, so they use the
/// same hook. Replacing the frame slot once preserves wrapper identity within
/// the invocation.
pub fn materializeFrameThisBinding(ctx: *core.JSContext, global: *core.Object, frame: *frame_mod.Frame) !core.JSValue {
    const flags = frame.function.flags;
    if (flags.is_arrow_function or flags.is_strict or flags.runtime_strict) return frame.this_value;

    const current = frame.this_value;
    if (current.isObject()) return current;
    if (current.isUndefined() or current.isNull()) {
        if (frame.ownership.this_value == .owned) {
            current.free(ctx.runtime);
            frame.this_value = global.value().dup();
        } else {
            frame.this_value = global.value();
        }
        return frame.this_value;
    }

    const boxed = try primitiveObjectForAccess(ctx.runtime, global, current);
    if (frame.ownership.this_value == .owned) current.free(ctx.runtime);
    frame.this_value = boxed;
    frame.ownership.this_value = .owned;
    return boxed;
}

pub fn generatorPrototypeFromGlobal(rt: *core.JSRuntime, global: *core.Object) !*core.Object {
    if (cachedRealmObject(global, .generator_prototype)) |stored| return stored;
    const object = try core.Object.create(rt, core.class.ids.object, iteratorPrototypeFromGlobal(rt, global) orelse objectPrototypeFromGlobal(rt, global));
    var object_raw_owned = true;
    errdefer if (object_raw_owned) core.Object.destroyFromHeader(rt, &object.header);
    try installGeneratorPrototypeProperties(rt, object);
    const value = object.value();
    object_raw_owned = false;
    defer value.free(rt);
    try storeRealmValue(rt, global, .generator_prototype, value);
    return object;
}

pub fn installGeneratorPrototypeProperties(rt: *core.JSRuntime, object: *core.Object) !void {
    const IntrinsicMethod = method_ids.iterator.IntrinsicMethod;
    const next_atom = try rt.internAtom("next");
    defer rt.atoms.free(next_atom);
    const next = try core.function.nativeFunction(rt, "next", 1);
    defer next.free(rt);
    const next_object = property_ops.expectObject(next) catch return error.TypeError;
    next_object.setNativeBuiltinIdAndRecord(rt, core.function.nativeBuiltinId(.iterator, @intFromEnum(IntrinsicMethod.generator_next)));
    if (!next_object.addGeneratorNextFunction(rt)) return error.TypeError;
    try object.defineOwnProperty(rt, next_atom, core.Descriptor.data(next, true, false, true));
    try builtin_glue.defineNativeDataMethodWithNativeId(rt, object, "return", 1, core.function.nativeBuiltinId(.iterator, @intFromEnum(IntrinsicMethod.generator_return)));
    try builtin_glue.defineNativeDataMethodWithNativeId(rt, object, "throw", 1, core.function.nativeBuiltinId(.iterator, @intFromEnum(IntrinsicMethod.generator_throw)));

    const tag_atom = (comptime core.atom.predefinedId("Symbol.toStringTag", .symbol)) orelse return error.TypeError;
    const tag = try value_ops.createStringValue(rt, "Generator");
    defer tag.free(rt);
    try object.defineOwnProperty(rt, tag_atom, core.Descriptor.data(tag, false, false, true));
}

pub fn generatorFunctionPrototypeFromGlobal(rt: *core.JSRuntime, global: *core.Object) !?*core.Object {
    if (cachedRealmObject(global, .generator_function_prototype)) |stored| return stored;
    const object = try core.Object.create(rt, core.class.ids.object, functionPrototypeFromGlobal(rt, global));
    const object_value = object.value();
    var object_value_owned = true;
    errdefer if (object_value_owned) object_value.free(rt);
    const constructor = try core.function.nativeFunction(rt, "GeneratorFunction", 1);
    defer constructor.free(rt);
    const constructor_object = property_ops.expectObject(constructor) catch return error.TypeError;
    try constructor_object.setFunctionRealmGlobalPtr(rt, global);
    if (functionConstructorFromGlobal(rt, global)) |function_constructor| try constructor_object.setPrototype(rt, function_constructor);
    try constructor_object.defineOwnProperty(rt, core.atom.ids.prototype, core.Descriptor.data(object_value, false, false, false));
    try object.defineOwnProperty(rt, core.atom.ids.constructor, core.Descriptor.data(constructor_object.value(), false, false, true));
    try storeRealmValue(rt, global, .generator_function_constructor, constructor_object.value());
    const generator_prototype = try generatorPrototypeFromGlobal(rt, global);
    try object.defineOwnProperty(rt, core.atom.ids.prototype, core.Descriptor.data(generator_prototype.value(), false, false, true));
    try generator_prototype.defineOwnProperty(rt, core.atom.ids.constructor, core.Descriptor.data(object_value, false, false, true));
    try qjsDefineToStringTag(rt, object, "GeneratorFunction");
    try storeRealmValue(rt, global, .generator_function_prototype, object_value);
    object_value_owned = false;
    object_value.free(rt);
    return object;
}

// qjs js_closure_global_var (quickjs.c:17228-17260): the capture waterfall for a
// global reference is [global_var_obj lexical VARREF] -> [global_obj VARREF
// property] -> [shared uninitialized_vars side-table cell], REGARDLESS of the
// closure var's own lexical bit — a plain reference captures a pre-existing
// global lexical's cell directly, and an undeclared name shares the parked cell
// that a later declaration (js_closure_define_global_var) will reuse. The shared
// table cell carries no per-capture flags; is_lexical/is_const are stamped only
// at definition time (add_var_ref, 17210-17223).
fn createGlobalClosureVarRef(ctx: *core.JSContext, global: *core.Object, cv: bytecode.function_bytecode.BytecodeClosureVar) !*core.VarRef {
    if (call_runtime.globalLexicalCell(ctx, cv.var_name)) |cell_value| return core.VarRef.fromValue(cell_value) orelse error.InvalidBytecode;
    if (call_runtime.globalObjectVarRefCell(global, cv.var_name)) |cell_value| return core.VarRef.fromValue(cell_value) orelse error.InvalidBytecode;
    const cell_value = try call_runtime.globalObjectGetUninitializedVar(ctx, global, cv.var_name);
    const cell = core.VarRef.fromValue(cell_value) orelse return error.InvalidBytecode;
    if (cv.varKind() == .function_name) cell.varRefIsFunctionNameSlot().* = true;
    return cell;
}

pub fn createBytecodeFunctionObject(
    ctx: *core.JSContext,
    frame: *frame_mod.Frame,
    caller_function: *const bytecode.Bytecode,
    global: *core.Object,
    value: core.JSValue,
    name_atom: core.Atom,
    opc: u8,
    create_prototype: bool,
) !core.JSValue {
    if (!value.isFunctionBytecode()) return error.InvalidBytecode;
    var rooted_value = value;
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &rooted_value },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = ctx.runtime.active_value_roots,
        .values = &root_values,
    };
    ctx.runtime.active_value_roots = &root_frame;
    defer ctx.runtime.active_value_roots = root_frame.previous;

    const fb = functionBytecodeFromValue(rooted_value) orelse return error.InvalidBytecode;
    const object = try core.Object.create(ctx.runtime, core.class.ids.bytecode_function, null);
    errdefer core.Object.destroyFromHeader(ctx.runtime, &object.header);
    const function_prototype = if (fb.flags.func_kind == .async_generator)
        try asyncGeneratorFunctionPrototypeFromGlobal(ctx.runtime, global)
    else if (fb.flags.func_kind == .generator)
        try generatorFunctionPrototypeFromGlobal(ctx.runtime, global)
    else if (fb.flags.func_kind == .async)
        try asyncFunctionPrototypeFromGlobal(ctx.runtime, global)
    else
        functionPrototypeFromGlobal(ctx.runtime, global);
    if (function_prototype) |prototype| {
        // The function is still unexposed and property-empty. Rebind it to the
        // hash-consed root for its final prototype instead of taking the
        // general SetPrototypeOf mutation path: that path must clone a shared
        // shape before mutation and used to leave every closure with a private
        // 104-byte shape. qjs creates the closure directly from the class
        // prototype's hashed root (`JS_NewObjectClass`), so later length/name/
        // prototype transitions are shared as well.
        try object.setFreshObjectPrototype(ctx.runtime, prototype);
    }
    try object.setFunctionBytecodeValue(ctx.runtime, rooted_value.dup());
    try object.bindBytecodeFunctionRealmGlobal(global);
    if (objectFromValue(frame.current_function)) |parent_function_object| {
        if (parent_function_object.functionImportMeta()) |import_meta| {
            try object.setOptionalValueSlot(ctx.runtime, try object.functionImportMetaSlot(ctx.runtime), import_meta.dup());
        }
    } else if (caller_function.flags.is_module and functionBytecodeUsesImportMeta(fb)) {
        const import_meta = try importMetaObject(ctx, global, caller_function, frame);
        defer import_meta.free(ctx.runtime);
        try object.setOptionalValueSlot(ctx.runtime, try object.functionImportMetaSlot(ctx.runtime), import_meta.dup());
    }
    try installLexicalPrivateNameRemap(ctx.runtime, object, frame, fb.privateBoundNames());
    if (fb.class_fields_init) |init_bytecode_box| {
        const init_bytecode = init_bytecode_box.*;
        const init_value = try createBytecodeFunctionObject(ctx, frame, caller_function, global, init_bytecode, core.atom.ids.empty_string, opc, false);
        try object.setOptionalValueSlot(ctx.runtime, try object.functionClassFieldsInitSlot(ctx.runtime), init_value);
    }
    if (fb.flags.is_arrow_function) {
        // `this` and `new.target` now arrive through the ordinary closure-var
        // capture loop below, matching qjs js_closure2. Home/super metadata is
        // distinct method state and remains attached only when required.
        if (property_ops.expectObject(frame.current_function)) |function_object| {
            try object.setFunctionHomeObject(ctx.runtime, function_object.functionHomeObject());
            if (function_object.functionSuperConstructor()) |super_constructor| try object.setOptionalValueSlot(ctx.runtime, try object.functionSuperConstructorSlot(ctx.runtime), super_constructor.dup());
            if (function_object.functionArrowConstructorThis()) |constructor_this| try object.setOptionalValueSlot(ctx.runtime, try object.functionArrowConstructorThisSlot(ctx.runtime), constructor_this.dup());
        } else |_| {}
        if (frame.function.flags.is_derived_class_constructor) {
            try object.setOptionalValueSlot(ctx.runtime, try object.functionArrowConstructorThisSlot(ctx.runtime), frame.constructorThisValue().dup());
        }
    }
    const effective_name = if (fb.func_name != core.atom.ids.empty_string and ctx.runtime.atoms.kind(fb.func_name) != null)
        fb.func_name
    else if (fb.flags.is_class_constructor)
        name_atom
    else
        fb.func_name;
    try object.defineOwnProperty(ctx.runtime, core.atom.ids.length, core.Descriptor.data(core.JSValue.int32(fb.defined_arg_count), false, false, true));
    if (ctx.runtime.atoms.kind(effective_name) != null) {
        const name_value = try functionNameValueFromAtom(ctx.runtime, effective_name, null);
        defer name_value.free(ctx.runtime);
        try object.defineOwnProperty(ctx.runtime, core.atom.ids.name, core.Descriptor.data(name_value, false, false, true));
    }
    if (fb.closureVar().len > 0) {
        // js_closure2 capture loop (quickjs.c:17297-17331): every arm yields an
        // owned, typed JSVarRef*. Frame-local/argument identity crosses only
        // the OpenBindings Seam; JSValue cell handles remain at global/module
        // adapters and never enter persistent capture storage.
        const captures = try ctx.runtime.memory.alloc(*core.VarRef, fb.closureVar().len);
        var captures_transferred = false;
        errdefer if (!captures_transferred) ctx.runtime.memory.free(*core.VarRef, captures);
        var rooted_captures: []*core.VarRef = captures[0..0];
        var captures_root = CellSliceRoot{};
        captures_root.init(ctx.runtime, &rooted_captures);
        defer captures_root.deinit();
        var initialized: usize = 0;
        errdefer if (!captures_transferred) {
            for (captures[0..initialized]) |cell| cell.freeCell(ctx.runtime);
            rooted_captures = &.{};
        };
        for (fb.closureVar(), 0..) |cv, idx| {
            const cell: *core.VarRef = switch (cv.closureType()) {
                .local => blk: {
                    if (cv.var_idx >= frame.locals.len) return error.InvalidBytecode;
                    break :blk try frame.captureLocal(ctx.runtime, cv.var_idx);
                },
                .arg => blk: {
                    if (cv.var_idx >= frame.args.len) return error.InvalidBytecode;
                    break :blk try frame.captureArg(ctx.runtime, cv.var_idx);
                },
                .ref => blk: {
                    try ensureVarRefsCapacity(ctx, frame, cv.var_idx);
                    // qjs JS_CLOSURE_REF (quickjs.c:17322-17324): pure pointer
                    // copy + rc++ of the parent slot's cell (type-guaranteed).
                    break :blk frame.var_refs[cv.var_idx].retain();
                },
                .global_ref => blk: {
                    if (cv.var_idx >= frame.var_refs.len) return error.InvalidBytecode;
                    // qjs JS_CLOSURE_GLOBAL_REF (quickjs.c:17322-17324): pure
                    // pointer copy + rc++ — the slot type guarantees the cell,
                    // the pre-typed bridge cellify is gone (phase D).
                    break :blk frame.var_refs[cv.var_idx].retain();
                },
                .global, .global_decl => try createGlobalClosureVarRef(ctx, global, cv),
                .module_decl, .module_import => blk: {
                    try ensureVarRefsCapacity(ctx, frame, cv.var_idx);
                    break :blk frame.var_refs[cv.var_idx].retain();
                },
            };
            captures[idx] = cell;
            {
                // qjs js_closure2 mutates no flags on aliased cells: the
                // REF/GLOBAL_REF arm is a pure pointer copy + rc++
                // (quickjs.c:17322-17324) and the module arms alias link-time
                // cells (quickjs.c:17301/17305) — a cell's const/function-name
                // flags are fixed at its owning creation site (local capture
                // here, frame build, module record, global define). Re-deriving
                // them from the capturing side's cv would poison cells the
                // capture merely borrows: a module import slot is the EXPORTING
                // module's live cell (phase C de-nesting), and marking it const
                // would make the exporter's own writes throw.
                switch (cv.closureType()) {
                    .ref, .global_ref, .module_decl, .module_import => {},
                    .local, .arg, .global, .global_decl => {
                        const captured_const = cv.isConst() or (cv.closureType() == .local and
                            cv.var_idx < caller_function.vardefs.len and caller_function.vardefs[cv.var_idx].isConst());
                        cell.varRefIsConstSlot().* = cell.varRefIsConstSlot().* or captured_const or cv.varKind() == .function_name;
                        cell.varRefIsFunctionNameSlot().* = cell.varRefIsFunctionNameSlot().* or cv.varKind() == .function_name;
                    },
                }
            }
            initialized += 1;
            rooted_captures = captures[0..initialized];
        }
        captures_transferred = true;
        object.setFunctionCaptures(ctx.runtime, captures);
    }
    if (create_prototype and fb.flags.has_prototype) {
        if (fb.flags.func_kind == .normal and !fb.flags.is_class_constructor) {
            // qjs-faithful lazy `prototype` (JS_AUTOINIT_ID_PROTOTYPE): install a
            // placeholder; the prototype object + its `constructor` back-ref are
            // materialized only when `.prototype` is first observed or the
            // function is constructed. A never-constructed closure (callback /
            // IIFE / factory result) thus skips the prototype allocation AND the
            // `func <-> prototype.constructor` cycle, so it is reclaimed by
            // refcount instead of the cycle collector. Generators /
            // async-generators / class constructors keep the eager path below
            // (their prototype shapes are set up with different parents / no
            // constructor and are observed by the runtime immediately).
            try object.defineFunctionPrototypeAutoInit(ctx.runtime, core.property.Flags.data(true, false, false));
        } else {
            const generator_prototype = if (fb.flags.func_kind == .async_generator)
                try asyncGeneratorPrototypeFromGlobal(ctx.runtime, global)
            else if (fb.flags.func_kind == .generator)
                try generatorPrototypeFromGlobal(ctx.runtime, global)
            else
                objectPrototypeFromGlobal(ctx.runtime, global);
            const prototype = try core.Object.create(ctx.runtime, core.class.ids.object, generator_prototype);
            var prototype_raw_owned = true;
            errdefer if (prototype_raw_owned) core.Object.destroyFromHeader(ctx.runtime, &prototype.header);
            if (fb.flags.func_kind != .generator and fb.flags.func_kind != .async_generator) {
                try prototype.defineOwnProperty(ctx.runtime, core.atom.ids.constructor, core.Descriptor.data(object.value(), true, false, true));
            }
            const prototype_value = prototype.value();
            prototype_raw_owned = false;
            defer prototype_value.free(ctx.runtime);
            try object.defineOwnProperty(ctx.runtime, core.atom.ids.prototype, core.Descriptor.data(prototype_value, true, false, false));
        }
    }
    return object.value();
}

pub fn constructPrimitiveWrapperWithPrototype(
    rt: *core.JSRuntime,
    class_id: core.class.ClassId,
    prototype: ?*core.Object,
    primitive: core.JSValue,
) !core.JSValue {
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

    const object = try core.Object.create(rt, class_id, prototype);
    errdefer core.Object.destroyFromHeader(rt, &object.header);
    try object.setOptionalValueSlot(rt, object.objectDataSlot(), rooted_primitive.dup());
    return object.value();
}

test "constructPrimitiveWrapperWithPrototype roots direct symbol while creating wrapper" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const symbol_atom = try rt.atoms.newValueSymbol("gc-construct-primitive-wrapper-symbol");
    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const symbol_value = try rt.symbolValue(symbol_atom);
    const wrapper_value = try constructPrimitiveWrapperWithPrototype(rt, core.class.ids.symbol, null, symbol_value);
    var wrapper_alive = true;
    defer if (wrapper_alive) wrapper_value.free(rt);
    const wrapper = objectFromValue(wrapper_value) orelse return error.TypeError;

    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    const stored = wrapper.objectDataSlot().* orelse return error.TypeError;
    try std.testing.expect(stored.same(symbol_value));

    wrapper_value.free(rt);
    wrapper_alive = false;
    symbol_value.free(rt);
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

pub fn qjsAggregateErrorConstructWithPrototype(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    prototype: ?*core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const rt = ctx.runtime;
    var cause_val = core.JSValue.undefinedValue();
    var root_values = [_]core.runtime.ValueRootValue{
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

    defer cause_val.free(rt);

    const instance = try core.Object.create(rt, core.class.ids.error_, prototype);
    const instance_value = instance.value();
    errdefer instance_value.free(rt);

    // No own `name` property: it lives on the per-class prototype only
    // (qjs js_error_constructor quickjs.c:41441 defines message/cause/errors).

    if (rooted_args.len >= 2 and !rooted_args[1].isUndefined()) {
        const message = try toStringForAnnexB(ctx, output, global, rooted_args[1], caller_function, caller_frame);
        defer message.free(rt);
        try defineDataProperty(rt, instance, "message", message, true, false, true);
    }

    if (rooted_args.len >= 3 and rooted_args[2].isObject()) {
        const cause_key = try rt.internAtom("cause");
        defer rt.atoms.free(cause_key);
        const options = try property_ops.expectObject(rooted_args[2]);
        if (try hasValueProperty(ctx, output, global, rooted_args[2], options, cause_key, caller_function, caller_frame)) {
            cause_val = try getValueProperty(ctx, output, global, rooted_args[2], cause_key, caller_function, caller_frame);
            try defineDataProperty(rt, instance, "cause", cause_val, true, false, true);
            cause_val.free(rt);
            cause_val = core.JSValue.undefinedValue();
        }
    }

    const errors_value = if (rooted_args.len >= 1) rooted_args[0] else core.JSValue.undefinedValue();
    const errors_array = try aggregateErrorsIterableToArray(ctx, output, global, errors_value, caller_function, caller_frame);
    const errors_array_value = errors_array.value();
    defer errors_array_value.free(rt);
    try defineDataProperty(rt, instance, "errors", errors_array_value, true, false, true);

    try captureErrorStack(ctx, output, global, instance);

    return instance_value;
}

test "qjsAggregateErrorConstructWithPrototype preserves direct symbol errors and cause" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    const global = try zjs_vm.contextGlobal(ctx);

    const errors_source = try core.Object.createArray(rt, arrayPrototypeFromGlobal(rt, global));
    var errors_source_alive = true;
    defer if (errors_source_alive) errors_source.value().free(rt);
    const options = try core.Object.create(rt, core.class.ids.object, objectPrototypeFromGlobal(rt, global));
    var options_alive = true;
    defer if (options_alive) options.value().free(rt);

    const error_value = try rt.newSymbolValue("gc-aggregate-error-item-symbol");
    const error_atom = error_value.asSymbolAtom().?;
    const cause_value = try rt.newSymbolValue("gc-aggregate-error-cause-symbol");
    const cause_atom = cause_value.asSymbolAtom().?;
    try errors_source.defineOwnProperty(rt, core.atom.atomFromUInt32(0), core.Descriptor.data(error_value, true, true, true));
    errors_source.setArrayLength(1);
    try errors_source.defineOwnProperty(rt, core.atom.ids.length, core.Descriptor.data(core.JSValue.int32(1), true, false, false));
    try defineDataProperty(rt, options, "cause", cause_value, true, false, true);

    const args = [_]core.JSValue{
        errors_source.value(),
        core.JSValue.undefinedValue(),
        options.value(),
    };
    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);
    ctx.formatting_error_stack = true;
    defer ctx.formatting_error_stack = false;

    const aggregate_value = try qjsAggregateErrorConstructWithPrototype(ctx, null, global, null, &args, null, null);
    var aggregate_alive = true;
    defer if (aggregate_alive) aggregate_value.free(rt);
    const aggregate = objectFromValue(aggregate_value) orelse return error.TypeError;

    try std.testing.expect(rt.atoms.name(error_atom) != null);
    try std.testing.expect(rt.atoms.name(cause_atom) != null);
    const errors_key = try rt.internAtom("errors");
    defer rt.atoms.free(errors_key);
    const cause_key = try rt.internAtom("cause");
    defer rt.atoms.free(cause_key);
    {
        const stored_errors_value = aggregate.getProperty(errors_key);
        defer stored_errors_value.free(rt);
        const stored_errors = objectFromValue(stored_errors_value) orelse return error.TypeError;
        const stored_error = stored_errors.getProperty(core.atom.atomFromUInt32(0));
        defer stored_error.free(rt);
        try std.testing.expect(stored_error.same(error_value));

        const stored_cause = aggregate.getProperty(cause_key);
        defer stored_cause.free(rt);
        try std.testing.expect(stored_cause.same(cause_value));
    }

    aggregate_value.free(rt);
    aggregate_alive = false;
    error_value.free(rt);
    cause_value.free(rt);
    errors_source.value().free(rt);
    errors_source_alive = false;
    options.value().free(rt);
    options_alive = false;
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(error_atom) == null);
    try std.testing.expect(rt.atoms.name(cause_atom) == null);
}

pub fn qjsSuppressedErrorConstructWithPrototype(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    prototype: ?*core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const rt = ctx.runtime;
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
    const instance_value = instance.value();
    errdefer instance_value.free(rt);

    if (rooted_args.len >= 3 and !rooted_args[2].isUndefined()) {
        const message = try toStringForAnnexB(ctx, output, global, rooted_args[2], caller_function, caller_frame);
        defer message.free(rt);
        try defineDataProperty(rt, instance, "message", message, true, false, true);
    }

    const error_value = if (rooted_args.len >= 1) rooted_args[0] else core.JSValue.undefinedValue();
    try defineDataProperty(rt, instance, "error", error_value, true, false, true);

    const suppressed_value = if (rooted_args.len >= 2) rooted_args[1] else core.JSValue.undefinedValue();
    try defineDataProperty(rt, instance, "suppressed", suppressed_value, true, false, true);

    try captureErrorStack(ctx, output, global, instance);

    return instance_value;
}

test "qjsSuppressedErrorConstructWithPrototype roots direct symbol args while creating error" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    const global = try core.Object.create(rt, core.class.ids.object, null);
    defer global.value().free(rt);

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

    const error_value = try qjsSuppressedErrorConstructWithPrototype(ctx, null, global, null, &args, null, null);
    var error_alive = true;
    defer if (error_alive) error_value.free(rt);
    const object = objectFromValue(error_value) orelse return error.TypeError;

    try std.testing.expect(rt.atoms.name(error_atom) != null);
    try std.testing.expect(rt.atoms.name(suppressed_atom) != null);
    const error_key = try rt.internAtom("error");
    defer rt.atoms.free(error_key);
    const suppressed_key = try rt.internAtom("suppressed");
    defer rt.atoms.free(suppressed_key);
    {
        const stored_error = object.getProperty(error_key);
        defer stored_error.free(rt);
        const stored_suppressed = object.getProperty(suppressed_key);
        defer stored_suppressed.free(rt);
        try std.testing.expect(stored_error.same(error_arg));
        try std.testing.expect(stored_suppressed.same(suppressed_arg));
    }

    error_value.free(rt);
    error_alive = false;
    error_arg.free(rt);
    suppressed_arg.free(rt);
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(error_atom) == null);
    try std.testing.expect(rt.atoms.name(suppressed_atom) == null);
}

pub fn qjsDisposableStackConstructWithPrototype(
    ctx: *core.JSContext,
    global: *core.Object,
    prototype: ?*core.Object,
) !core.JSValue {
    const stack = try core.Object.create(ctx.runtime, core.class.ids.disposable_stack, prototype);
    errdefer core.Object.destroyFromHeader(ctx.runtime, &stack.header);
    try stack.setFunctionRealmGlobalPtr(ctx.runtime, global);
    return stack.value();
}
pub fn qjsErrorConstructWithPrototype(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    name: []const u8,
    prototype: ?*core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const rt = ctx.runtime;
    var cause_val = core.JSValue.undefinedValue();
    var root_values = [_]core.runtime.ValueRootValue{
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

    defer cause_val.free(rt);

    const instance = try core.Object.create(rt, core.class.ids.error_, prototype);
    const instance_value = instance.value();
    errdefer instance_value.free(rt);

    // No own `name` property: it lives on the per-class prototype only, so
    // patching `X.prototype.name` reflects on existing instances and a
    // new.target-derived prototype supplies its own name (qjs
    // js_error_constructor quickjs.c:41441 defines only message/cause).
    _ = name;

    if (rooted_args.len >= 1 and !rooted_args[0].isUndefined()) {
        const message = try toStringForAnnexB(ctx, output, global, rooted_args[0], caller_function, caller_frame);
        defer message.free(rt);
        try defineDataProperty(rt, instance, "message", message, true, false, true);
    }

    if (rooted_args.len >= 2 and rooted_args[1].isObject()) {
        const cause_key = try rt.internAtom("cause");
        defer rt.atoms.free(cause_key);
        const options = try property_ops.expectObject(rooted_args[1]);
        if (try hasValueProperty(ctx, output, global, rooted_args[1], options, cause_key, caller_function, caller_frame)) {
            cause_val = try getValueProperty(ctx, output, global, rooted_args[1], cause_key, caller_function, caller_frame);
            try defineDataProperty(rt, instance, "cause", cause_val, true, false, true);
            cause_val.free(rt);
            cause_val = core.JSValue.undefinedValue();
        }
    }

    try captureErrorStack(ctx, output, global, instance);

    return instance_value;
}

test "qjsErrorConstructWithPrototype preserves direct symbol cause" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    const global = try zjs_vm.contextGlobal(ctx);

    const options = try core.Object.create(rt, core.class.ids.object, objectPrototypeFromGlobal(rt, global));
    var options_alive = true;
    defer if (options_alive) options.value().free(rt);

    const cause_atom = try rt.atoms.newValueSymbol("gc-error-cause-symbol");
    const cause_value = try rt.symbolValue(cause_atom);
    try defineDataProperty(rt, options, "cause", cause_value, true, false, true);
    const args = [_]core.JSValue{
        core.JSValue.undefinedValue(),
        options.value(),
    };
    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);
    ctx.formatting_error_stack = true;
    defer ctx.formatting_error_stack = false;

    const error_value = try qjsErrorConstructWithPrototype(ctx, null, global, "Error", null, &args, null, null);
    var error_alive = true;
    defer if (error_alive) error_value.free(rt);
    const object = objectFromValue(error_value) orelse return error.TypeError;

    try std.testing.expect(rt.atoms.name(cause_atom) != null);
    const cause_key = try rt.internAtom("cause");
    defer rt.atoms.free(cause_key);
    {
        const stored_cause = object.getProperty(cause_key);
        defer stored_cause.free(rt);
        try std.testing.expect(stored_cause.same(cause_value));
    }

    error_value.free(rt);
    error_alive = false;
    cause_value.free(rt);
    options.value().free(rt);
    options_alive = false;
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(cause_atom) == null);
}

pub fn createCallSiteObject(ctx: *core.JSContext, global: *core.Object, entry: core.BacktraceFrame) !core.JSValue {
    const object = try core.Object.create(ctx.runtime, core.class.ids.object, try callSitePrototypeFromGlobal(ctx.runtime, global));
    errdefer core.Object.destroyFromHeader(ctx.runtime, &object.header);
    const location = entry.location();
    const filename = if (entry.is_native)
        core.JSValue.nullValue()
    else
        try value_ops.createStringValue(ctx.runtime, ctx.runtime.atoms.name(entry.filename) orelse "<anonymous>");
    defer filename.free(ctx.runtime);
    const function_name_value = try callSiteFunctionNameValue(ctx, entry);
    defer function_name_value.free(ctx.runtime);
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
    if (cachedRealmObject(global, .callsite_prototype)) |stored| return stored;
    const prototype = try core.Object.create(rt, core.class.ids.object, objectPrototypeFromGlobal(rt, global));
    var prototype_raw_owned = true;
    errdefer if (prototype_raw_owned) core.Object.destroyFromHeader(rt, &prototype.header);

    const methods = [_]struct { name: []const u8, id: core.function.HostGlobalMethod }{
        .{ .name = "getFunction", .id = .callsite_get_function },
        .{ .name = "getFunctionName", .id = .callsite_get_function_name },
        .{ .name = "getFileName", .id = .callsite_get_file_name },
        .{ .name = "getLineNumber", .id = .callsite_get_line_number },
        .{ .name = "getColumnNumber", .id = .callsite_get_column_number },
        .{ .name = "isNative", .id = .callsite_is_native },
    };
    for (methods) |method| {
        try builtin_glue.defineNativeDataMethodWithNativeId(rt, prototype, method.name, 0, core.function.nativeBuiltinId(.host, @intFromEnum(method.id)));
    }
    try qjsDefineToStringTag(rt, prototype, "CallSite");

    const prototype_value = prototype.value();
    prototype_raw_owned = false;
    defer prototype_value.free(rt);
    try storeRealmValue(rt, global, .callsite_prototype, prototype_value);
    return prototype;
}

pub fn defineDataProperty(
    rt: *core.JSRuntime,
    object: *core.Object,
    name: []const u8,
    value: core.JSValue,
    writable: bool,
    enumerable: bool,
    configurable: bool,
) !void {
    const key = try rt.internAtom(name);
    defer rt.atoms.free(key);
    try object.defineOwnProperty(rt, key, core.Descriptor.data(value, writable, enumerable, configurable));
}

pub fn currentArrowFunctionObject(frame: *frame_mod.Frame) ?*core.Object {
    const current_object = objectFromValue(frame.current_function) orelse return null;
    const function_value = current_object.functionBytecode() orelse return null;
    const fb = functionBytecodeFromValue(function_value) orelse return null;
    if (!fb.flags.is_arrow_function) return null;
    return current_object;
}

pub fn qjsRegExpPrototypeMethodIsDefault(rt: *core.JSRuntime, object: *core.Object, atom_id: core.Atom, expected_id: u32) bool {
    if (object.class_id != core.class.ids.regexp) return false;
    if (object.hasOwnProperty(atom_id)) return false;
    const proto = object.getPrototype() orelse return false;
    if (proto.hasExoticMethods()) return false;
    // Shape-hash probe of the prototype, mirroring qjs js_is_standard_regexp's
    // find_property_regexp (not a linear property walk).
    const property_index = proto.findProperty(atom_id) orelse return false;
    const prop_flags = core.property.Flags.fromBits(proto.shapeProps()[property_index].flags);
    if (prop_flags.isAccessor()) return false;
    const entry = proto.prop_values[property_index];
    return switch (proto.propKindAt(property_index)) {
        .data => qjsRegExpNativeBuiltinMatches(entry.slot.data, expected_id),
        .auto_init => qjsRegExpAutoInitBuiltinMatches(core.property.autoInitAt(rt, entry.slot.auto_init).*, expected_id),
        .var_ref, .accessor => false,
    };
}

/// Side-effect-free check that a RegExp flag getter (`flags`/`global`/`unicode`/
/// `sticky`) resolves to the default native accessor -- the accessor analog of
/// `qjsRegExpPrototypeMethodIsDefault`, used to gate the standard-regexp fast
/// paths exactly like QuickJS `check_regexp_getter`. Crucially this NEVER
/// invokes the getter, so probing it has no observable effect (the failing
/// `Symbol.replace/get-*-err` tests require the generic path to observe an
/// overridden getter in spec order instead).
pub fn qjsRegExpPrototypeGetterIsDefault(rt: *core.JSRuntime, object: *core.Object, atom_id: core.Atom, expected_id: u32) bool {
    if (object.class_id != core.class.ids.regexp) return false;
    if (object.hasOwnProperty(atom_id)) return false;
    const proto = object.getPrototype() orelse return false;
    if (proto.hasExoticMethods()) return false;
    // Shape-hash probe of the prototype, mirroring qjs check_regexp_getter's
    // find_property_regexp (not a linear property walk).
    const property_index = proto.findProperty(atom_id) orelse return false;
    const entry = proto.prop_values[property_index];
    return switch (proto.propKindAt(property_index)) {
        .accessor => qjsRegExpNativeBuiltinMatches(entry.slot.accessor.getterValue(), expected_id),
        .auto_init => qjsRegExpAutoInitAccessorBuiltinMatches(core.property.autoInitAt(rt, entry.slot.auto_init).*, expected_id),
        .data, .var_ref => false,
    };
}

/// Side-effect-free `js_is_standard_regexp` (quickjs.c): the receiver is a
/// genuine RegExp whose `lastIndex` is a plain number and whose `exec` method
/// and `flags`/`global`/`unicode` getters are all the pristine built-ins. Only
/// then may a fast path read flags straight from the compiled bytecode and skip
/// the observable property reads the spec otherwise mandates.
pub fn regExpIsStandard(rt: *core.JSRuntime, object: *core.Object) bool {
    if (object.class_id != core.class.ids.regexp) return false;
    // QuickJS `js_is_standard_regexp` requires `JS_IsNumber(lastIndex)`: a
    // non-number lastIndex (string "1", {}, ...) must take the generic path so
    // ToLength coercion is observed (sticky/global use lastIndex directly).
    if (object.regexpLastIndex()) |last_index| {
        if (!last_index.isNumber()) return false;
    } else return false;
    const exec_atom = (comptime core.atom.predefinedId("exec", .string)) orelse return false;
    if (!qjsRegExpPrototypeMethodIsDefault(rt, object, exec_atom, @intFromEnum(method_ids.regexp.PrototypeMethod.exec))) return false;
    const flags_atom = (comptime core.atom.predefinedId("flags", .string)) orelse return false;
    if (!qjsRegExpPrototypeGetterIsDefault(rt, object, flags_atom, @intFromEnum(method_ids.regexp.AccessorMethod.flags))) return false;
    const global_atom = (comptime core.atom.predefinedId("global", .string)) orelse return false;
    if (!qjsRegExpPrototypeGetterIsDefault(rt, object, global_atom, @intFromEnum(method_ids.regexp.AccessorMethod.global))) return false;
    const unicode_atom = (comptime core.atom.predefinedId("unicode", .string)) orelse return false;
    if (!qjsRegExpPrototypeGetterIsDefault(rt, object, unicode_atom, @intFromEnum(method_ids.regexp.AccessorMethod.unicode))) return false;
    return true;
}

pub fn regExpExecPropertyIsDefault(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    rx: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !bool {
    const exec_atom = (comptime core.atom.predefinedId("exec", .string)) orelse return false;
    const exec_value = try getValueProperty(ctx, output, global, rx, exec_atom, caller_function, caller_frame);
    defer exec_value.free(ctx.runtime);
    const exec_object = objectFromValue(exec_value) orelse return false;
    const native_ref = core.function.decodeNativeBuiltinId(exec_object.nativeFunctionId()) orelse return false;
    return native_ref.domain == .regexp and native_ref.id == @intFromEnum(method_ids.regexp.PrototypeMethod.exec);
}

pub fn setValuePropertyStrict(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    object_value: core.JSValue,
    atom_id: core.Atom,
    value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !void {
    const object = try property_ops.expectObject(object_value);
    const value_to_set = try arrayLengthAssignmentValue(ctx, output, global, object, atom_id, value, caller_function, caller_frame);
    defer if (!value_to_set.same(value)) value_to_set.free(ctx.runtime);
    if (core.object.isTypedArrayObject(object)) {
        if (try typedArrayCanonicalSet(ctx, output, global, object, atom_id, value_to_set)) return;
    }
    // Match QuickJS's first `find_own_property` branch: a writable own data
    // property is updated before any prototype/accessor walk. This also covers
    // synthesized own data slots such as RegExp `lastIndex`.
    if (try object.setOwnWritableDataProperty(ctx.runtime, atom_id, value_to_set)) return;
    const called_setter = callAccessorSetter(ctx, output, global, object_value, object, atom_id, value, caller_function, caller_frame) catch |err| switch (err) {
        error.AccessorWithoutSetter => return error.TypeError,
        else => return err,
    };
    if (called_setter) return;
    object.setProperty(ctx.runtime, atom_id, value_to_set) catch |err| switch (err) {
        error.ReadOnly, error.AccessorWithoutSetter, error.NotExtensible => return error.TypeError,
        error.InvalidLength => return error.RangeError,
        else => return err,
    };
}

pub fn regExpPrototypeFromGlobal(rt: *core.JSRuntime, global: *core.Object) ?*core.Object {
    const constructor = regExpConstructorFromGlobal(rt, global) catch return null;
    if (constructor.getOwnDataObjectBorrowed(core.atom.ids.prototype)) |prototype| return prototype;
    const prototype_value = constructor.getProperty(core.atom.ids.prototype);
    defer prototype_value.free(rt);
    return objectFromValue(prototype_value);
}

pub fn isSameRealmRegExpPrototypeGetter(rt: *core.JSRuntime, global: *core.Object, object: *core.Object, name: []const u8, getter_value: core.JSValue) !bool {
    const regexp_proto = regExpPrototypeFromGlobal(rt, global) orelse return false;
    if (object != regexp_proto) return false;
    const key = try rt.internAtom(name);
    defer rt.atoms.free(key);
    const desc = regexp_proto.getOwnProperty(rt, key) orelse return false;
    defer desc.destroy(rt);
    if (desc.kind != .accessor) return false;
    return sameObjectIdentity(desc.getter, getter_value);
}

pub fn objectHasRegExpInternalSlots(object: *core.Object) bool {
    if (object.class_id != core.class.ids.regexp) return false;
    return object.regexpSource() != null and object.regexpCompiledBytecode().len != 0;
}

pub const PropertyEscapePattern = struct {
    name: []const u8,
    positive: bool,
};

pub fn propertyEscapePattern(source: []const u8) ?PropertyEscapePattern {
    const positive_prefix = "\\p{";
    const negative_prefix = "\\P{";
    var prefix_len: usize = undefined;
    var positive: bool = undefined;
    if (std.mem.startsWith(u8, source, positive_prefix)) {
        prefix_len = positive_prefix.len;
        positive = true;
    } else if (std.mem.startsWith(u8, source, negative_prefix)) {
        prefix_len = negative_prefix.len;
        positive = false;
    } else {
        return null;
    }
    if (source.len <= prefix_len or source[source.len - 1] != '}') return null;
    const name = source[prefix_len .. source.len - 1];
    if (!isRuntimeSupportedBinaryPropertyName(name)) return null;
    return .{ .name = name, .positive = positive };
}

pub fn unicodePropertyOnlyClassSource(source: []const u8) bool {
    const body = unicodePropertyOnlyClassBody(source) orelse return false;
    var index: usize = 0;
    var saw_escape = false;
    while (index < body.len) {
        _ = readUnicodePropertyClassEscape(body, &index) orelse return false;
        saw_escape = true;
    }
    return saw_escape;
}

pub fn unicodePropertyOnlyClassBody(source: []const u8) ?[]const u8 {
    if (source.len < 3 or source[0] != '[' or source[source.len - 1] != ']') return null;
    const body = source[1 .. source.len - 1];
    if (body.len == 0 or body[0] == '^') return null;
    return body;
}

pub fn readUnicodePropertyClassEscape(body: []const u8, index: *usize) ?PropertyEscapePattern {
    if (index.* >= body.len or body[index.*] != '\\') return null;
    const start = index.*;
    index.* += 1;
    if (index.* >= body.len or (body[index.*] != 'p' and body[index.*] != 'P')) return null;
    index.* += 1;
    if (index.* >= body.len or body[index.*] != '{') return null;
    index.* += 1;
    while (index.* < body.len and body[index.*] != '}') : (index.* += 1) {}
    if (index.* >= body.len or body[index.*] != '}') return null;
    index.* += 1;
    return propertyEscapePattern(body[start..index.*]);
}

pub fn qjsDatePrototypeMethod(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    method_id: u32,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    if (method_id == 11) {
        if (try date_vm.qjsDateToJsonCall(ctx, output, global, this_value, args, caller_function, caller_frame)) |value| return value;
    }
    if (method_id == 23) {
        if (try date_vm.qjsDateSetYear(ctx, output, global, this_value, args, caller_function, caller_frame)) |value| return value;
    }
    if (method_id == 24) {
        if (try date_vm.qjsDateSetTime(ctx, output, global, this_value, args, caller_function, caller_frame)) |value| return value;
    }
    if (try date_vm.qjsDateCapturedSetterCall(ctx, output, global, this_value, method_id, args, caller_function, caller_frame)) |value| return value;
    // Remaining (non-special-cased) prototype ids run the plain `methodCallArgs`
    // body, which lives in `exec/date_ops.zig`. Route it through the record
    // table's func-object-free arm (re-encoding the decoded id to its
    // `PrototypeMethod` record id) so exec carries no compile-time Date body
    // knowledge. The arm dispatches the body directly, so this does not re-enter
    // the dispatcher.
    const native_ref = core.function.NativeBuiltinRef{ .domain = .date, .id = core.host_function.builtin_method_id_lookup.date.encodePrototypeMethodId(method_id) orelse return throwTypeErrorMessage(ctx, global, "not a Date object") };
    const result = builtin_dispatch.callInternalRecord(ctx, output, null, &.{}, null, this_value, native_ref, args, caller_function, caller_frame) catch |err| switch (err) {
        error.TypeError => return throwTypeErrorMessage(ctx, global, "not a Date object"),
        error.RangeError => return throwRangeErrorMessage(ctx, global, "Date value is NaN"),
        else => return err,
    };
    return result orelse throwTypeErrorMessage(ctx, global, "not a Date object");
}

pub fn isAnchoredBinaryPropertySource(source: []const u8) bool {
    const name = anchoredBinaryPropertyName(source) orelse return false;
    return isRuntimeSupportedBinaryPropertyName(name);
}

pub fn anchoredBinaryPropertyName(source: []const u8) ?[]const u8 {
    const positive_prefix = "^\\p{";
    const negative_prefix = "^\\P{";
    const prefix_len: usize = if (std.mem.startsWith(u8, source, positive_prefix))
        positive_prefix.len
    else if (std.mem.startsWith(u8, source, negative_prefix))
        negative_prefix.len
    else
        return null;
    const suffix = "}+$";
    if (!std.mem.endsWith(u8, source, suffix)) return null;
    if (source.len <= prefix_len + suffix.len) return null;
    return source[prefix_len .. source.len - suffix.len];
}

pub fn isRuntimeSupportedBinaryPropertyName(name: []const u8) bool {
    return regexp_properties.isSupportedUnicodePropertyExpression(name);
}

pub fn defineFreshNonIndexDataProperty(rt: *core.JSRuntime, object: *core.Object, atom_id: core.Atom, value: core.JSValue, writable: bool, enumerable: bool, configurable: bool) !void {
    try object.defineOwnNonIndexPropertyAssumingNew(rt, atom_id, core.Descriptor.data(value, writable, enumerable, configurable));
}

pub fn defineRegExpIndicesGroupsProperty(rt: *core.JSRuntime, global: *core.Object, out: *core.Object, found: *const RegExpMatch) !void {
    const groups_atom = (comptime core.atom.predefinedId("groups", .string)) orelse return error.TypeError;
    if (!found.has_named_captures) {
        try defineFreshNonIndexDataProperty(rt, out, groups_atom, core.JSValue.undefinedValue(), true, true, true);
        return;
    }

    const groups = try core.Object.create(rt, core.class.ids.object, null);
    var groups_raw_owned = true;
    errdefer if (groups_raw_owned) core.Object.destroyFromHeader(rt, &groups.header);
    var capture_index: usize = 0;
    while (capture_index < found.capture_count) : (capture_index += 1) {
        const name = found.captureNameAt(capture_index) orelse continue;
        const capture = found.captureAt(capture_index);
        var decoded_name = std.ArrayList(u8).empty;
        defer decoded_name.deinit(rt.memory.allocator);
        try appendDecodedRegExpGroupName(rt, &decoded_name, name);
        const atom = try rt.internAtom(decoded_name.items);
        defer rt.atoms.free(atom);
        // Duplicate named groups share one property; the participating
        // (matched) capture wins, an unset duplicate must not overwrite it.
        if (capture.undefined and groups.hasOwnProperty(atom)) continue;
        const value = if (capture.undefined)
            core.JSValue.undefinedValue()
        else
            try createRegExpIndexPair(rt, global, capture.start, capture.start + capture.len);
        defer value.free(rt);
        try groups.defineOwnProperty(rt, atom, core.Descriptor.data(value, true, true, true));
    }
    const groups_value = groups.value();
    groups_raw_owned = false;
    defer groups_value.free(rt);
    try defineFreshNonIndexDataProperty(rt, out, groups_atom, groups_value, true, true, true);
}

pub fn defineRegExpGroupsProperty(rt: *core.JSRuntime, out: *core.Object, input_bytes: []const u8, found: *const RegExpMatch) !void {
    const groups_atom = (comptime core.atom.predefinedId("groups", .string)) orelse return error.TypeError;
    if (!found.has_named_captures) {
        try defineFreshNonIndexDataProperty(rt, out, groups_atom, core.JSValue.undefinedValue(), true, true, true);
        return;
    }

    const groups = try core.Object.create(rt, core.class.ids.object, null);
    var groups_raw_owned = true;
    errdefer if (groups_raw_owned) core.Object.destroyFromHeader(rt, &groups.header);
    var capture_index: usize = 0;
    while (capture_index < found.capture_count) : (capture_index += 1) {
        const name = found.captureNameAt(capture_index) orelse continue;
        const capture = found.captureAt(capture_index);
        var decoded_name = std.ArrayList(u8).empty;
        defer decoded_name.deinit(rt.memory.allocator);
        try appendDecodedRegExpGroupName(rt, &decoded_name, name);
        const atom = try rt.internAtom(decoded_name.items);
        defer rt.atoms.free(atom);
        // Duplicate named groups share one property; the participating
        // (matched) capture wins, an unset duplicate must not overwrite it.
        if (capture.undefined and groups.hasOwnProperty(atom)) continue;
        const value = if (capture.undefined)
            core.JSValue.undefinedValue()
        else
            value_ops.createStringValue(rt, input_bytes[capture.start .. capture.start + capture.len]) catch |err| switch (err) {
                error.InvalidUtf8 => try createStringFromByteUnits(rt, input_bytes[capture.start .. capture.start + capture.len]),
                else => return err,
            };
        defer value.free(rt);
        try groups.defineOwnProperty(rt, atom, core.Descriptor.data(value, true, true, true));
    }
    const groups_value = groups.value();
    groups_raw_owned = false;
    defer groups_value.free(rt);
    try defineFreshNonIndexDataProperty(rt, out, groups_atom, groups_value, true, true, true);
}

pub fn defineRegExpGroupsPropertyFromValue(rt: *core.JSRuntime, out: *core.Object, input_value: core.JSValue, found: *const RegExpMatch) !void {
    const groups_value = try createRegExpGroupsValueFromValue(rt, input_value, found);
    defer groups_value.free(rt);
    const groups_atom = (comptime core.atom.predefinedId("groups", .string)) orelse return error.TypeError;
    try defineFreshNonIndexDataProperty(rt, out, groups_atom, groups_value, true, true, true);
}

pub fn createRegExpGroupsValueFromValue(rt: *core.JSRuntime, input_value: core.JSValue, found: *const RegExpMatch) !core.JSValue {
    if (!found.has_named_captures) return core.JSValue.undefinedValue();

    const groups = try core.Object.create(rt, core.class.ids.object, null);
    errdefer core.Object.destroyFromHeader(rt, &groups.header);
    var capture_index: usize = 0;
    while (capture_index < found.capture_count) : (capture_index += 1) {
        const name = found.captureNameAt(capture_index) orelse continue;
        const capture = found.captureAt(capture_index);
        var decoded_name = std.ArrayList(u8).empty;
        defer decoded_name.deinit(rt.memory.allocator);
        try appendDecodedRegExpGroupName(rt, &decoded_name, name);
        const atom = try rt.internAtom(decoded_name.items);
        defer rt.atoms.free(atom);
        // Duplicate named groups share one property; the participating
        // (matched) capture wins, an unset duplicate must not overwrite it.
        if (capture.undefined and groups.hasOwnProperty(atom)) continue;
        const value = if (capture.undefined)
            core.JSValue.undefinedValue()
        else
            try stringSliceValue(rt, input_value, capture.start, capture.len);
        defer value.free(rt);
        try groups.defineOwnProperty(rt, atom, core.Descriptor.data(value, true, true, true));
    }
    return groups.value();
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

    var capture_index: usize = 0;
    while (capture_index < found.capture_count) : (capture_index += 1) {
        const name = found.captureNameAt(capture_index) orelse continue;
        const capture = found.captureAt(capture_index);
        var decoded_name = std.ArrayList(u8).empty;
        defer decoded_name.deinit(rt.memory.allocator);
        try appendDecodedRegExpGroupName(rt, &decoded_name, name);
        const atom = try rt.internAtom(decoded_name.items);
        defer rt.atoms.free(atom);
        // Duplicate named groups share one property; the participating
        // (matched) capture wins, an unset duplicate must not overwrite it.
        if (capture.undefined and groups.hasOwnProperty(atom)) continue;
        try groups.defineOwnProperty(rt, atom, core.Descriptor.data(capture_values[capture_index + 1], true, true, true));
    }
}

pub fn qjsPrimitivePrototypeMethod(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    function_object: *core.Object,
    this_value: core.JSValue,
    id: u32,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
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
            4 => return qjsSymbolConstructorCall(ctx, output, global, args),
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
            return symbolPrimitiveValue(rt, this_value) catch |err| switch (err) {
                error.TypeError => return throwTypeErrorMessage(ctx, global, "not a symbol"),
            };
        },
        else => {},
    }
    const primitive = primitivePrototypeThisValue(rt, this_value, class_tag) catch return throwPrimitivePrototypeTypeError(ctx, global, function_object, class_tag);
    defer primitive.free(rt);
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
            qjsBigIntPrototypeToString(ctx, output, global, primitive, args, caller_function, caller_frame)
        else
            value_ops.toStringValue(rt, primitive),
        2 => primitive.dup(),
        else => error.TypeError,
    };
}

/// `Symbol(...)` called as a function (never a constructor). Mirrors the
/// retired string-name dispatch branch in `call.zig`: coerce the optional
/// description through the user-visible ToString path, then mint a fresh
/// value symbol.
fn qjsSymbolConstructorCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
) !core.JSValue {
    const rt = ctx.runtime;
    const description = blk: {
        if (args.len >= 1 and !args[0].isUndefined()) {
            if (args[0].isSymbol()) return throwTypeErrorMessage(ctx, global, "cannot convert symbol to string");
            const string_value = try string_ops.toStringForAnnexB(ctx, output, global, args[0], null, null);
            defer string_value.free(rt);
            var buffer = std.ArrayList(u8).empty;
            errdefer buffer.deinit(rt.memory.allocator);
            try value_ops.appendRawString(rt, &buffer, string_value);
            break :blk @as(?[]u8, try buffer.toOwnedSlice(rt.memory.allocator));
        }
        break :blk null;
    };
    defer if (description) |bytes| rt.memory.allocator.free(bytes);
    return rt.newSymbolValue(if (description) |bytes| bytes else null);
}

/// `get Symbol.prototype.description`: unwraps a symbol primitive or a
/// Symbol wrapper object and returns its description string (or undefined).
fn symbolDescriptionValue(rt: *core.JSRuntime, this_value: core.JSValue) !core.JSValue {
    const primitive = try symbolPrimitiveValue(rt, this_value);
    defer primitive.free(rt);
    const atom_id = primitive.asSymbolAtom() orelse return error.TypeError;
    const desc = core.symbol.description(&rt.atoms, atom_id) orelse return core.JSValue.undefinedValue();
    return value_ops.createStringValue(rt, desc);
}

/// `Symbol.prototype[Symbol.toPrimitive]`: returns the wrapped symbol
/// primitive; throws TypeError for any other receiver.
fn symbolPrimitiveValue(rt: *core.JSRuntime, this_value: core.JSValue) !core.JSValue {
    if (this_value.isSymbol()) return this_value.dup();
    if (!this_value.isObject()) return error.TypeError;
    const header = this_value.refHeader() orelse return error.TypeError;
    const object: *core.Object = @fieldParentPtr("header", header);
    if (object.class_id != core.class.ids.symbol) return error.TypeError;
    const primitive = (object.objectData() orelse return error.TypeError).dup();
    if (!primitive.isSymbol()) {
        primitive.free(rt);
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

pub fn getNumberPrototypeMethodId(rt: *core.JSRuntime, function_object: *core.Object) ?u32 {
    _ = rt;
    const native_ref = core.function.decodeNativeBuiltinId(function_object.nativeFunctionId()) orelse return null;
    if (native_ref.domain != .number) return null;
    return switch (native_ref.id) {
        @intFromEnum(method_ids.number.PrototypeMethod.to_string),
        @intFromEnum(method_ids.number.PrototypeMethod.to_locale_string),
        @intFromEnum(method_ids.number.PrototypeMethod.to_fixed),
        @intFromEnum(method_ids.number.PrototypeMethod.to_exponential),
        @intFromEnum(method_ids.number.PrototypeMethod.to_precision),
        => native_ref.id,
        else => null,
    };
}

pub fn qjsNumberPrototypeMethod(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    method_id: u32,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    // Route to the `.number` domain record (the method body lives in
    // `number_ops.zig`, beside its coercion boundary). The
    // record handler coerces the receiver/argument itself, so the raw
    // `this_value`/`args` are forwarded unchanged. Accept the legacy small ids
    // (1..5) used by historical fast-call sites as well as the
    // `PrototypeMethod` enum ids baked into installed native functions.
    const id: u32 = switch (method_id) {
        1, @intFromEnum(method_ids.number.PrototypeMethod.to_string) => @intFromEnum(method_ids.number.PrototypeMethod.to_string),
        2, @intFromEnum(method_ids.number.PrototypeMethod.to_locale_string) => @intFromEnum(method_ids.number.PrototypeMethod.to_locale_string),
        3, @intFromEnum(method_ids.number.PrototypeMethod.to_fixed) => @intFromEnum(method_ids.number.PrototypeMethod.to_fixed),
        4, @intFromEnum(method_ids.number.PrototypeMethod.to_exponential) => @intFromEnum(method_ids.number.PrototypeMethod.to_exponential),
        5, @intFromEnum(method_ids.number.PrototypeMethod.to_precision) => @intFromEnum(method_ids.number.PrototypeMethod.to_precision),
        else => return throwTypeErrorMessage(ctx, global, "not a number"),
    };
    const native_ref = core.function.NativeBuiltinRef{ .domain = .number, .id = id };
    return (try builtin_dispatch.callInternalRecord(ctx, output, global, &.{}, null, this_value, native_ref, args, caller_function, caller_frame)) orelse
        throwTypeErrorMessage(ctx, global, "not a number");
}

pub fn primitivePrototypeThisValue(rt: *core.JSRuntime, value: core.JSValue, class_tag: i32) !core.JSValue {
    if (class_tag == 1 and value.isNumber()) return value.dup();
    if (class_tag == 2 and value.asBool() != null) return value.dup();
    if (class_tag == 3 and value.isBigInt()) return value.dup();
    if (class_tag == 4 and value.isSymbol()) return value.dup();
    if (class_tag == 5 and value.isString()) return value.dup();
    if (!value.isObject()) return error.TypeError;
    const object = try property_ops.expectObject(value);
    const matches = switch (class_tag) {
        1 => object.class_id == core.class.ids.number,
        2 => object.class_id == core.class.ids.boolean,
        3 => object.class_id == core.class.ids.big_int,
        4 => object.class_id == core.class.ids.symbol,
        5 => object.class_id == core.class.ids.string,
        else => false,
    };
    if (!matches) return error.TypeError;
    if (class_tag == 5) return (object.objectData() orelse return error.TypeError).dup();
    _ = rt;
    return (object.objectData() orelse return error.TypeError).dup();
}

pub fn defineErrorStackDataProperty(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: *core.Object,
    stack_key: core.Atom,
    desc: core.Descriptor,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !void {
    if (receiver.proxyTarget() != null) {
        const ok = try proxyDefineOwnProperty(ctx, output, global, receiver, stack_key, desc, caller_function, caller_frame);
        if (!ok) return error.TypeError;
        return;
    }
    receiver.defineOwnProperty(ctx.runtime, stack_key, desc) catch |err| switch (err) {
        error.ReadOnly, error.NotExtensible, error.IncompatibleDescriptor => return error.TypeError,
        error.InvalidLength => return error.RangeError,
        else => return err,
    };
}

pub fn qjsDataViewConstructWithPrototype(
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

pub fn defineClassFieldDataProperty(rt: *core.JSRuntime, object: *core.Object, atom_id: core.Atom, value: core.JSValue) !void {
    // NO-ALIGN(qjs): JS_DefinePrivateField (quickjs.c:8374) raw-adds private
    // fields with add_property and never consults extensibility, so qjs lands
    // private fields on preventExtensions'd/frozen instances. test262's
    // `nonextensible-applies-to-private` feature (PrivateFieldAdd step 1:
    // "If O.[[Extensible]] is false, throw a TypeError") mandates the throw
    // (language/statements/class/elements/private-class-field-on-nonextensible-
    // objects.js), so zjs keeps the NotExtensible -> TypeError behavior.
    if (rt.atoms.kind(atom_id) == .private and object.hasOwnProperty(atom_id)) return error.TypeError;
    object.defineOwnProperty(rt, atom_id, core.Descriptor.data(value, true, true, true)) catch |err| switch (err) {
        error.IncompatibleDescriptor, error.NotExtensible, error.ReadOnly => return error.TypeError,
        else => return err,
    };
}

pub fn qjsConstructWeakRefWithPrototype(rt: *core.JSRuntime, target: core.JSValue, prototype: ?*core.Object) !core.JSValue {
    return construct_mod.weakRefWithPrototype(rt, target, prototype);
}

pub fn qjsConstructFinalizationRegistryWithPrototype(rt: *core.JSRuntime, cleanup_callback: core.JSValue, prototype: ?*core.Object) !core.JSValue {
    var rooted_cleanup_callback = cleanup_callback;
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &rooted_cleanup_callback },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    const instance = try core.Object.create(rt, core.class.ids.finalization_registry, prototype);
    errdefer core.Object.destroyFromHeader(rt, &instance.header);
    try instance.setOptionalValueSlot(rt, instance.finalizationRegistryCleanupCallbackSlot(), rooted_cleanup_callback.dup());
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
    const collection_value = (try builtin_dispatch.callConstructRecord(ctx, output, global, &.{}, null, collection_construct_ref, prototype, &.{}, null, null)) orelse return error.TypeError;
    errdefer collection_value.free(ctx.runtime);
    if (args.len == 0 or args[0].isUndefined() or args[0].isNull()) return collection_value;

    const adder_name: []const u8 = if (kind == 1 or kind == 3) "set" else "add";
    const adder_key = try ctx.runtime.internAtom(adder_name);
    defer ctx.runtime.atoms.free(adder_key);
    const adder = try getValueProperty(ctx, output, global, collection_value, adder_key, null, null);
    defer adder.free(ctx.runtime);
    if (!isCallableValue(adder)) return error.TypeError;

    const source = property_ops.expectObject(args[0]) catch null;
    if (source) |source_object| {
        if (source_object.isArray()) {
            try addCollectionEntriesFromArray(ctx, output, global, collection_value, kind, source_object, adder);
            return collection_value;
        }
    }

    try addCollectionEntriesFromIterator(ctx, output, global, collection_value, kind, args[0], adder);
    return collection_value;
}

pub fn constructorPrototypeObject(rt: *core.JSRuntime, constructor: core.JSValue) !?*core.Object {
    if (!constructor.isObject()) return null;
    if (objectFromValue(constructor)) |object| {
        if (object.getOwnDataObjectBorrowed(core.atom.ids.prototype)) |prototype| return prototype;
    }
    const prototype_value = try property_ops.getPropertyValue(rt, constructor, core.atom.ids.prototype);
    defer prototype_value.free(rt);
    return objectFromValue(prototype_value);
}

pub fn dynamicFunctionNewTargetPrototype(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    new_target: core.JSValue,
    kind: DynamicFunctionKind,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?*core.Object {
    const prototype_value = try getValueProperty(ctx, output, global, new_target, core.atom.ids.prototype, caller_function, caller_frame);
    defer prototype_value.free(ctx.runtime);
    if (prototype_value.isObject()) return objectFromValue(prototype_value);
    const fallback_global = if (objectFromValue(new_target)) |new_target_object| blk: {
        if (isRevokedProxy(new_target_object)) return error.TypeError;
        break :blk functionRealmGlobal(new_target_object) orelse global;
    } else global;
    return dynamicFunctionDefaultPrototype(ctx, fallback_global, kind);
}

pub fn dynamicFunctionDefaultPrototype(
    ctx: *core.JSContext,
    global: *core.Object,
    kind: DynamicFunctionKind,
) !?*core.Object {
    return switch (kind) {
        .normal => functionPrototypeFromGlobal(ctx.runtime, global),
        .async_function => try asyncFunctionPrototypeFromGlobal(ctx.runtime, global),
        .generator => try generatorFunctionPrototypeFromGlobal(ctx.runtime, global),
        .async_generator => try asyncGeneratorFunctionPrototypeFromGlobal(ctx.runtime, global),
    };
}

pub fn objectRealmGlobal(object: *core.Object) ?*core.Object {
    if (object.class_id == core.class.ids.bound_function) {
        const target_value = object.boundTarget() orelse return null;
        const target_object = objectFromValue(target_value) orelse return null;
        return objectRealmGlobal(target_object);
    }
    if (object.class_id == core.class.ids.generator or object.class_id == core.class.ids.async_generator) {
        if (object.generatorCurrentFunction()) |current_function| {
            if (objectFromValue(current_function)) |current_object| {
                if (current_object != object) {
                    if (objectRealmGlobal(current_object)) |realm_global| return realm_global;
                }
            }
        }
    }
    if (object.functionRealmGlobalPtr()) |realm_global| return realm_global;
    const realm_value = object.functionRealmGlobal() orelse return null;
    return property_ops.expectObject(realm_value) catch null;
}

pub fn copyRealmPrototypeKeys(rt: *core.JSRuntime, constructor: core.JSValue, function_object: *core.Object) !void {
    const constructor_object = property_ops.expectObject(constructor) catch return;
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
    for (realm_keys) |key_name| {
        const key = try rt.internAtom(key_name);
        defer rt.atoms.free(key);
        const value = constructor_object.getProperty(key);
        defer value.free(rt);
        if (!value.isUndefined()) {
            try function_object.defineOwnProperty(rt, key, core.Descriptor.data(value, true, false, true));
        }
    }
}

pub fn propertyIndexFromLengthKey(rt: *core.JSRuntime, atom_id: core.Atom) ?usize {
    if (core.array.arrayIndexFromAtom(&rt.atoms, atom_id)) |index| return index;
    if (rt.atoms.kind(atom_id) != .string) return null;
    const name = rt.atoms.name(atom_id) orelse return null;
    if (name.len == 0) return null;
    for (name) |ch| {
        if (ch < '0' or ch > '9') return null;
    }
    return std.fmt.parseUnsigned(usize, name, 10) catch null;
}

pub fn propertyAtomFromLengthIndex(rt: *core.JSRuntime, index: usize) !LengthIndexAtom {
    if (index <= core.atom.max_int_atom) return .{ .atom = core.atom.atomFromUInt32(@intCast(index)), .owned = false };
    const name = try std.fmt.allocPrint(rt.memory.allocator, "{d}", .{index});
    defer rt.memory.allocator.free(name);
    return .{ .atom = try rt.internAtom(name), .owned = true };
}

pub fn createDataPropertyOrThrow(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver_value: core.JSValue,
    object: *core.Object,
    atom_id: core.Atom,
    value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !void {
    if (object.proxyTarget() != null) {
        try proxyCreateDataPropertyOrThrow(ctx, output, global, receiver_value, object, atom_id, value, caller_function, caller_frame);
        return;
    }
    try qjsCreateArrayDataOrTypedArrayElement(ctx.runtime, object, atom_id, value);
}

pub fn qjsObjectGetPrototypeOfStep(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    object: *core.Object,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?*core.Object {
    if (!object.isProxy()) {
        if (isThrowTypeErrorIntrinsicObject(object)) {
            if (object.getPrototype()) |prototype| return prototype;
            return functionPrototypeFromGlobal(ctx.runtime, objectRealmGlobal(object) orelse global);
        }
        return object.getPrototype();
    }
    if (object.proxyHandler() == null) return error.TypeError;
    const target_value = object.proxyTarget() orelse return error.TypeError;
    const target = objectFromValue(target_value) orelse return error.TypeError;
    const handler_value = object.proxyHandler().?;
    const trap_key = try ctx.runtime.internAtom("getPrototypeOf");
    defer ctx.runtime.atoms.free(trap_key);
    const trap = try getValueProperty(ctx, output, global, handler_value, trap_key, caller_function, caller_frame);
    defer trap.free(ctx.runtime);
    if (trap.isUndefined() or trap.isNull()) return qjsObjectGetPrototypeOfStep(ctx, output, global, target, caller_function, caller_frame);
    const result = try callValueOrBytecode(ctx, output, global, handler_value, trap, &.{target_value}, caller_function, caller_frame);
    defer result.free(ctx.runtime);
    const result_proto = if (result.isNull()) null else objectFromValue(result) orelse return error.TypeError;
    if (!try proxyAwareIsExtensible(ctx, output, global, target, caller_function, caller_frame)) {
        const target_proto = try qjsObjectGetPrototypeOfStep(ctx, output, global, target, caller_function, caller_frame);
        if (target_proto != result_proto) return error.TypeError;
    }
    return result_proto;
}

pub fn qjsObjectGetPrototypeOfValue(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    object: *core.Object,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    if (!object.isProxy()) {
        if (isThrowTypeErrorIntrinsicObject(object)) {
            if (object.getPrototype()) |prototype| return prototype.value().dup();
            if (functionPrototypeFromGlobal(ctx.runtime, objectRealmGlobal(object) orelse global)) |prototype| return prototype.value().dup();
            return core.JSValue.nullValue();
        }
        if (object.getPrototype()) |prototype| return prototype.value().dup();
        return core.JSValue.nullValue();
    }
    if (object.proxyHandler() == null) return error.TypeError;
    const target_value = object.proxyTarget() orelse return error.TypeError;
    const target = objectFromValue(target_value) orelse return error.TypeError;
    const handler_value = object.proxyHandler().?;
    const trap_key = try ctx.runtime.internAtom("getPrototypeOf");
    defer ctx.runtime.atoms.free(trap_key);
    const trap = try getValueProperty(ctx, output, global, handler_value, trap_key, caller_function, caller_frame);
    defer trap.free(ctx.runtime);
    if (trap.isUndefined() or trap.isNull()) return qjsObjectGetPrototypeOfValue(ctx, output, global, target, caller_function, caller_frame);
    const result = try callValueOrBytecode(ctx, output, global, handler_value, trap, &.{target_value}, caller_function, caller_frame);
    errdefer result.free(ctx.runtime);
    if (!result.isNull() and objectFromValue(result) == null) return error.TypeError;
    if (!try proxyAwareIsExtensible(ctx, output, global, target, caller_function, caller_frame)) {
        const target_proto = try qjsObjectGetPrototypeOfStep(ctx, output, global, target, caller_function, caller_frame);
        const same = if (result.isNull())
            target_proto == null
        else if (objectFromValue(result)) |result_object|
            target_proto != null and target_proto.? == result_object
        else
            false;
        if (!same) return error.TypeError;
    }
    return result;
}

pub fn internalSpecialObjectValue(rt: *core.JSRuntime, subtype: u8) !?core.JSValue {
    return try call_mod.internalUsingHelperFunction(rt, subtype);
}

pub fn qjsDestructuringObjectRest(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
) !core.JSValue {
    if (args.len < 1) return error.TypeError;
    var source_value = if (args[0].isObject())
        args[0].dup()
    else
        try primitiveObjectForAccess(ctx.runtime, global, args[0]);
    defer source_value.free(ctx.runtime);
    const source = try property_ops.expectObject(source_value);

    var out_value = core.JSValue.undefinedValue();
    var value = core.JSValue.undefinedValue();
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &source_value },
        .{ .value = &out_value },
        .{ .value = &value },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = ctx.runtime.active_value_roots,
        .values = &root_values,
    };
    ctx.runtime.active_value_roots = &root_frame;
    defer ctx.runtime.active_value_roots = root_frame.previous;
    defer value.free(ctx.runtime);

    const out = try core.Object.create(ctx.runtime, core.class.ids.object, objectPrototypeFromGlobal(ctx.runtime, global));
    errdefer core.Object.destroyFromHeader(ctx.runtime, &out.header);
    out_value = out.value();
    const keys = try objectRestOwnKeys(ctx, output, global, source);
    defer core.Object.freeKeys(ctx.runtime, keys);

    for (keys) |key| {
        if (source.class_id == core.class.ids.string and key == core.atom.ids.length) continue;
        if (try objectRestKeyExcluded(ctx, args[1..], key)) continue;
        const desc = try objectRestOwnPropertyDescriptor(ctx, output, global, source, key) orelse continue;
        defer desc.destroy(ctx.runtime);
        if (desc.enumerable != true) continue;
        value = getValueProperty(ctx, output, global, args[0], key, null, null) catch |err| return err;
        try out.defineOwnProperty(ctx.runtime, key, core.Descriptor.data(value, true, true, true));
        value.free(ctx.runtime);
        value = core.JSValue.undefinedValue();
    }
    return out_value;
}

test "qjsDestructuringObjectRest roots direct symbol values while creating rest object" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    const global = try zjs_vm.contextGlobal(ctx);

    const source = try core.Object.create(rt, core.class.ids.object, objectPrototypeFromGlobal(rt, global));
    var source_alive = true;
    defer if (source_alive) source.value().free(rt);
    const key = try rt.internAtom("kept");
    defer rt.atoms.free(key);
    const symbol_atom = try rt.atoms.newValueSymbol("gc-destructuring-object-rest-symbol");
    const symbol_value = try rt.symbolValue(symbol_atom);
    try source.defineOwnProperty(rt, key, core.Descriptor.data(symbol_value, true, true, true));
    symbol_value.free(rt);

    const args = [_]core.JSValue{source.value()};
    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const rest_value = try qjsDestructuringObjectRest(ctx, null, global, &args);
    var rest_alive = true;
    defer if (rest_alive) rest_value.free(rt);
    const rest = try property_ops.expectObject(rest_value);

    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    {
        const stored = rest.getProperty(key);
        defer stored.free(rt);
        try std.testing.expectEqual(@as(?core.Atom, symbol_atom), stored.asSymbolAtom());
    }

    rest_value.free(rt);
    rest_alive = false;
    source.value().free(rt);
    source_alive = false;
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
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
    const handler_value = source.proxyHandler() orelse return error.TypeError;
    const own_keys_atom = try ctx.runtime.internAtom("ownKeys");
    defer ctx.runtime.atoms.free(own_keys_atom);
    const trap = try getValueProperty(ctx, output, global, handler_value, own_keys_atom, null, null);
    defer trap.free(ctx.runtime);
    if (trap.isUndefined() or trap.isNull()) {
        const target = try property_ops.expectObject(target_value);
        return objectRestOwnKeys(ctx, output, global, target);
    }
    const trap_result = try callValueOrBytecode(ctx, output, global, handler_value, trap, &.{target_value}, null, null);
    defer trap_result.free(ctx.runtime);
    _ = try property_ops.expectObject(trap_result);
    var out: []core.Atom = &.{};
    errdefer core.Object.freeKeys(ctx.runtime, out);
    const length_value = try getValueProperty(ctx, output, global, trap_result, core.atom.ids.length, null, null);
    defer length_value.free(ctx.runtime);
    const length = try toLengthIndex(ctx, output, global, length_value);
    var index: usize = 0;
    while (index < length) : (index += 1) {
        const index_key = try propertyAtomFromLengthIndex(ctx.runtime, index);
        defer index_key.deinit(ctx.runtime);
        const key_value = try getValueProperty(ctx, output, global, trap_result, index_key.atom, null, null);
        defer key_value.free(ctx.runtime);
        if (!key_value.isString() and !key_value.isSymbol()) return error.TypeError;
        const atom_id = try property_ops.propertyKeyAtom(ctx.runtime, key_value);
        errdefer ctx.runtime.atoms.free(atom_id);
        if (atomListContains(out, atom_id)) return error.TypeError;
        try appendOwnedAtom(ctx.runtime, &out, atom_id);
    }
    try validateProxyOwnKeysResult(ctx, output, global, source, target_value, out);
    return out;
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

pub fn objectRestKeyExcluded(ctx: *core.JSContext, excluded: []const core.JSValue, key: core.Atom) !bool {
    for (excluded) |value| {
        const excluded_key = try property_ops.propertyKeyAtom(ctx.runtime, value);
        defer ctx.runtime.atoms.free(excluded_key);
        if (excluded_key == key) return true;
    }
    return false;
}

pub fn atomicsBufferObject(object: *core.Object) !*core.Object {
    const buffer_value = object.typedArrayBuffer() orelse return error.TypeError;
    return property_ops.expectObject(buffer_value);
}

pub fn importMetaObject(
    ctx: *core.JSContext,
    global: *core.Object,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
) !core.JSValue {
    _ = global;
    if (objectFromValue(frame.current_function)) |function_object| {
        if (function_object.functionImportMeta()) |value| return value.dup();
    }

    if (!function.flags.is_module) return error.SyntaxError;
    const record = ctx.runtime.modules.find(function.name) orelse return error.ModuleNotFound;
    if (record.import_meta) |value| return value.dup();

    const object = try core.Object.create(ctx.runtime, core.class.ids.object, null);
    errdefer core.Object.destroyFromHeader(ctx.runtime, &object.header);
    // import.meta is a real null-prototype object (JS_GetImportMeta:
    // JS_NewObjectProto(ctx, JS_NULL), quickjs.c:30900); without the flag,
    // ToPrimitive fell through to %Object.prototype%.toString and
    // import(import.meta) stringified instead of rejecting with TypeError.
    const url = try importMetaUrlValue(ctx.runtime, record);
    defer url.free(ctx.runtime);
    try defineValueProperty(ctx.runtime, object, "url", url);
    try defineValueProperty(ctx.runtime, object, "main", core.JSValue.boolean(record.import_meta_main));
    const value = object.value();
    record.import_meta = value.dup();
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
) !core.JSValue {
    var rooted_func = func;
    var rooted_current = current_function_value;
    var rooted_this = this_value;
    var rooted_boxed_this = core.JSValue.undefinedValue();
    defer rooted_boxed_this.free(ctx.runtime);

    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &rooted_func },
        .{ .value = &rooted_current },
        .{ .value = &rooted_this },
        .{ .value = &rooted_boxed_this },
    };
    if (input_args.len > array_ops.max_apply_arguments) {
        return throwRangeErrorMessage(ctx, global, "too many arguments in function call (only 65534 allowed)");
    }
    const fb = functionBytecodeFromValue(rooted_func) orelse return error.TypeError;
    var root_slices = [_]core.runtime.ValueRootSlice{
        .{ .borrowed = input_args },
        .{ .borrowed_cells = input_var_refs },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = ctx.runtime.active_value_roots,
        .values = &root_values,
        .slices = &root_slices,
    };
    ctx.runtime.active_value_roots = &root_frame;
    defer ctx.runtime.active_value_roots = root_frame.previous;

    // Build the borrowed bytecode view once: its finalized frame dimensions
    // size the qjs-style execution FAM and the same view runs the parameter
    // prologue below.
    var nested_base: bytecode.Bytecode = undefined;
    const nested: *const bytecode.Bytecode = bytecode.cachedBytecodeView(fb, &ctx.runtime.memory, &ctx.runtime.atoms) orelse blk: {
        nested_base = bytecode.makeBytecodeView(fb, &ctx.runtime.memory, &ctx.runtime.atoms);
        break :blk &nested_base;
    };

    const class_id = if (is_async) core.class.ids.async_generator else core.class.ids.generator;
    // Normal JS generator calls keep their execution state detached while the
    // parameter prologue runs, then create the public object directly with its
    // final prototype. This mirrors qjs js_generator_function_call and avoids
    // a temporary null-prototype Shape on every short-lived generator. The raw
    // internal-bytecode path still needs a registered holder while installing
    // its borrowed realm fallback.
    const detached_shell = rooted_current.isObject();
    const object = if (detached_shell)
        try core.Object.createGeneratorShell(ctx.runtime, class_id)
    else
        try core.Object.create(ctx.runtime, class_id, null);
    var object_registered = !detached_shell;
    errdefer if (object_registered)
        core.Object.destroyFromHeader(ctx.runtime, &object.header)
    else
        object.destroyGeneratorShell(ctx.runtime);
    var prepared_frame: zjs_vm.PreparedEntryFrame = undefined;
    var prepared_frame_ptr: ?*const zjs_vm.PreparedEntryFrame = null;
    if (detached_shell) {
        const stack_slots = try std.math.add(usize, @as(usize, fb.stack_size), 1);
        const frame_arg_count = frame_mod.frameArgCount(nested, input_args.len);
        const need_original_args = frame_mod.argumentsNeedsOriginalSnapshot(nested);
        const original_arg_count = frame_mod.originalArgCount(input_args.len, need_original_args);
        const var_ref_count = frame_mod.frameVarRefStorageCount(nested, input_var_refs);
        const open_var_ref_count = frame_mod.frameOpenVarRefStorageCount(nested);
        const frame_slots = try frame_mod.FrameSlab.requiredStorageSlots(
            frame_arg_count,
            original_arg_count,
            nested.var_count,
            0,
            var_ref_count,
            open_var_ref_count,
        );
        try object.initGeneratorExecutionWithStorage(ctx.runtime, stack_slots, frame_slots);
        prepared_frame = .{
            .slab = frame_mod.FrameSlab.partitionStorage(
                object.generatorCombinedFrameStorage(),
                frame_arg_count,
                original_arg_count,
                nested.var_count,
                0,
                var_ref_count,
                open_var_ref_count,
            ),
            .need_original_args = need_original_args,
        };
        prepared_frame_ptr = &prepared_frame;
    }
    object.generatorActualArgCountSlot().* = @intCast(input_args.len);
    if (rooted_current.isObject()) {
        object.setGeneratorCurrentFunction(ctx.runtime, rooted_current.dup());
        // The owned current-function edge dominates this borrowed realm pointer
        // for the execution record's lifetime, so normal generators need no
        // separate borrowed-holder registry entry.
        object.generatorPayloadPtr().realm_global_ptr = global;
    } else {
        // Internal raw-FunctionBytecode calls have no function object, but use
        // the same qjs-like current-function owner slot. Normal JS calls store
        // the closure object here; both paths derive bytecode from this edge.
        const raw_current = if (rooted_current.isFunctionBytecode()) rooted_current else rooted_func;
        object.setGeneratorCurrentFunction(ctx.runtime, raw_current.dup());
        // Raw internal bytecode has no function object to dominate the realm.
        try object.setFunctionRealmGlobalPtr(ctx.runtime, global);
    }
    const fb_runtime_strict = fb.flags.is_strict_mode or fb.flags.runtime_strict_mode;
    const effective_this = if (!fb_runtime_strict) blk: {
        if (rooted_this.isUndefined() or rooted_this.isNull()) break :blk global.value();
        if (!rooted_this.isObject()) {
            rooted_boxed_this = try primitiveObjectForAccess(ctx.runtime, global, rooted_this);
            break :blk rooted_boxed_this;
        }
        break :blk rooted_this;
    } else rooted_this;
    object.setGeneratorThis(ctx.runtime, effective_this.dup());
    // Every generator gets one resident frame at creation, including internal
    // hand-built bytecode with no body marker (which parks at pc 0). qjs's
    // async_func_init likewise has no separate deferred args/captures owner.
    const init_result = try runGeneratorParameterInit(ctx, fb, nested, prepared_frame_ptr, object, rooted_current, effective_this, input_args, input_var_refs, output, global);
    init_result.free(ctx.runtime);

    const prototype = generatorObjectPrototype(ctx.runtime, global, rooted_current, is_async) catch null;
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
    const function_object = property_ops.expectObject(function_value) catch return fallback;
    if (function_object.getOwnDataObjectBorrowed(core.atom.ids.prototype)) |prototype| return prototype;
    const prototype_value = function_object.getProperty(core.atom.ids.prototype);
    defer prototype_value.free(rt);
    return property_ops.expectObject(prototype_value) catch fallback;
}

pub fn qjsIteratorPrototypeAccessor(ctx: *core.JSContext, global: *core.Object, receiver: core.JSValue, args: []const core.JSValue, id: u32) !core.JSValue {
    if (id == @intFromEnum(method_ids.iterator.AccessorMethod.constructor_setter)) {
        if (args.len > 0) {
            if (!args[0].isObject()) return throwTypeErrorMessage(ctx, global, "not an object");
            if (!receiver.isObject()) return throwTypeErrorMessage(ctx, global, "not an object");
        }
    } else if (id == @intFromEnum(method_ids.iterator.AccessorMethod.to_string_tag_setter)) {
        const receiver_object = property_ops.expectObject(receiver) catch return throwTypeErrorMessage(ctx, global, "not an object");
        if (iteratorPrototypeFromGlobal(ctx.runtime, global)) |home| {
            if (receiver_object == home) return throwTypeErrorMessage(ctx, global, "Cannot assign to read only property");
        }
    }
    return iter_vm.qjsIteratorPrototypeAccessor(ctx, global, receiver, args, id);
}

pub fn qjsIteratorPrototypeAccessorSet(ctx: *core.JSContext, global: *core.Object, receiver: core.JSValue, atom_id: core.Atom, value: core.JSValue) !core.JSValue {
    if (atom_id == core.atom.ids.constructor) {
        if (!value.isObject()) return throwTypeErrorMessage(ctx, global, "not an object");
        if (!receiver.isObject()) return throwTypeErrorMessage(ctx, global, "not an object");
    } else if (atom_id == ((comptime core.atom.predefinedId("Symbol.toStringTag", .symbol)) orelse return error.TypeError)) {
        const receiver_object = property_ops.expectObject(receiver) catch return throwTypeErrorMessage(ctx, global, "not an object");
        if (iteratorPrototypeFromGlobal(ctx.runtime, global)) |home| {
            if (receiver_object == home) return throwTypeErrorMessage(ctx, global, "Cannot assign to read only property");
        }
    }
    return iter_vm.qjsIteratorPrototypeAccessorSet(ctx, global, receiver, atom_id, value);
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
    return iter_vm.qjsIteratorPrototypeMethodCall(
        ctx,
        output,
        global,
        receiver,
        args,
        method_id,
        caller_function,
        caller_frame,
    );
}

pub fn iteratorIsOnIteratorPrototypeChain(rt: *core.JSRuntime, global: *core.Object, value: core.JSValue) bool {
    const iterator = objectFromValue(value) orelse return false;
    const iterator_proto = iteratorPrototypeFromGlobal(rt, global) orelse return false;
    var prototype = iterator.getPrototype();
    while (prototype) |proto| {
        if (proto == iterator_proto) return true;
        prototype = proto.getPrototype();
    }
    return false;
}

pub fn wrapForValidIteratorPrototype(rt: *core.JSRuntime, global: *core.Object) !*core.Object {
    if (cachedRealmObject(global, .wrap_for_valid_iterator_prototype)) |stored| return stored;

    const proto = try core.Object.create(rt, core.class.ids.object, iteratorPrototypeFromGlobal(rt, global));
    var proto_raw_owned = true;
    errdefer if (proto_raw_owned) core.Object.destroyFromHeader(rt, &proto.header);
    try defineNativeDataMethod(rt, proto, "next", 0);
    try tagIteratorWrapPrototypeMethod(rt, global, proto, "next", 1);
    try defineNativeDataMethod(rt, proto, "return", 0);
    try tagIteratorWrapPrototypeMethod(rt, global, proto, "return", 2);
    const value = proto.value();
    proto_raw_owned = false;
    defer value.free(rt);
    try storeRealmValue(rt, global, .wrap_for_valid_iterator_prototype, value);
    return proto;
}

pub fn tagIteratorWrapPrototypeMethod(rt: *core.JSRuntime, global: *core.Object, proto: *core.Object, name: []const u8, method_id: i32) !void {
    const key = try rt.internAtom(name);
    defer rt.atoms.free(key);
    const method = proto.getProperty(key);
    defer method.free(rt);
    const method_object = objectFromValue(method) orelse return;
    (try method_object.functionIteratorWrapMethodSlot(rt)).* = @intCast(method_id);
    if (functionPrototypeFromGlobal(rt, global)) |function_proto| {
        try method_object.setPrototype(rt, function_proto);
    }
}

pub fn iteratorPrototypeFromGlobal(rt: *core.JSRuntime, global: *core.Object) ?*core.Object {
    return iter_vm.iteratorPrototypeFromGlobal(rt, global);
}

pub fn qjsIteratorPrototype(rt: *core.JSRuntime, global: *core.Object, tag_name: []const u8) !*core.Object {
    return iter_vm.qjsIteratorPrototype(rt, global, tag_name);
}

fn argumentsPropertyTemplate(rt: *core.JSRuntime, global: *core.Object, comptime mapped: bool) !*core.Object {
    const cached = try global.cachedRealmValueSlot(
        rt,
        if (mapped) .mapped_arguments_template else .unmapped_arguments_template,
    );
    if (cached.*) |stored| return core.Object.expect(stored);

    // qjs prepares `ctx->arguments_shape` once per realm and every later
    // `js_build_arguments` call supplies only the three property values. Keep a
    // realm-owned template solely to pin that final shape and its fixed slots;
    // the template is never exposed to JavaScript.
    const template = try core.Object.createWithOwnPropertyCapacity(
        rt,
        if (mapped) core.class.ids.mapped_arguments else core.class.ids.arguments,
        objectPrototypeFromGlobal(rt, global),
        3,
    );
    defer template.value().free(rt);

    if (mapped) {
        try template.defineOwnProperty(
            rt,
            core.atom.ids.length,
            core.Descriptor.data(core.JSValue.int32(0), true, false, true),
        );
    } else {
        try template.defineOwnPropertyAssumingNew(
            rt,
            core.atom.ids.length,
            core.Descriptor.data(core.JSValue.int32(0), true, false, true),
        );
    }
    if (try arrayPrototypeValuesFromGlobal(rt, global)) |values| {
        defer values.free(rt);
        const iterator_key = (comptime core.atom.predefinedId("Symbol.iterator", .symbol)) orelse return error.TypeError;
        if (mapped) {
            try template.defineOwnProperty(rt, iterator_key, core.Descriptor.data(values, true, false, true));
        } else {
            try template.defineOwnPropertyAssumingNew(rt, iterator_key, core.Descriptor.data(values, true, false, true));
        }
    }
    const callee_key = (comptime core.atom.predefinedId("callee", .string)) orelse return error.TypeError;
    if (mapped) {
        try template.defineOwnProperty(rt, callee_key, core.Descriptor.data(core.JSValue.undefinedValue(), true, false, true));
    } else {
        const thrower = try throwTypeErrorIntrinsicForGlobal(rt, global);
        defer thrower.free(rt);
        try template.defineOwnPropertyAssumingNew(rt, callee_key, core.Descriptor.accessor(thrower, thrower, false, false));
    }

    try global.setOptionalValueSlot(rt, cached, template.value().dup());
    return core.Object.expect(cached.*.?);
}

pub fn createArgumentsObject(ctx: *core.JSContext, global: *core.Object, frame: *frame_mod.Frame, mapped_override: ?bool) !core.JSValue {
    // zjs-side adaptation (R2): qjs finalizes the mapped/unmapped decision at
    // emit time (quickjs.c:34864 gates OP_special_object MAPPED_ARGUMENTS on
    // `!(js_mode & JS_MODE_STRICT) && has_simple_parameter_list`). zjs's
    // embedder `forceRuntimeStrict` (eval_entry.zig:60,252) can turn a
    // sloppy-parsed function strict AFTER the prologue already emitted the
    // subtype-1 (mapped) special_object, so the override arm must re-apply the
    // same effective-strictness gate the else arm uses. A force-strict frame
    // therefore downgrades to an UNMAPPED arguments object (spec-correct for
    // strict functions), which needs no open-ref window and never reaches
    // captureArg — matching has_mapped_arguments=false in the view.
    const mapped = if (mapped_override) |requested|
        requested and !currentFrameFunctionIsStrict(frame) and frame.function.flags.has_simple_parameter_list
    else
        !currentFrameFunctionIsStrict(frame) and frame.function.flags.has_simple_parameter_list;
    const args = if (mapped)
        frame.args[0..@min(frame.actual_arg_count, frame.args.len)]
    else if (frame.originalArgs().len != 0)
        frame.originalArgs()[0..@min(frame.actual_arg_count, frame.originalArgs().len)]
    else
        frame.args[0..@min(frame.actual_arg_count, frame.args.len)];
    const object = blk: {
        const template = if (mapped)
            try argumentsPropertyTemplate(ctx.runtime, global, true)
        else
            try argumentsPropertyTemplate(ctx.runtime, global, false);
        const out = try core.Object.createFromPropertyTemplate(ctx.runtime, template);
        out.replaceOwnDataPropertyValueAtAssumingShapeOwned(
            ctx.runtime,
            0,
            core.JSValue.int32(@intCast(args.len)),
        );
        if (mapped) {
            const callee_key = (comptime core.atom.predefinedId("callee", .string)) orelse return error.TypeError;
            const callee_index = template.findProperty(callee_key) orelse return error.TypeError;
            out.replaceOwnDataPropertyValueAtAssumingShapeOwned(
                ctx.runtime,
                callee_index,
                frame.current_function.dup(),
            );
        }
        break :blk out;
    };
    errdefer core.Object.destroyFromHeader(ctx.runtime, &object.header);

    if (!mapped) {
        var dense_elements: []core.JSValue = &.{};
        if (args.len != 0) {
            dense_elements = try ctx.runtime.allocRuntime(core.JSValue, args.len);
            for (args, 0..) |_, index| dense_elements[index] = value_slot.loadOwned(&args[index]);
        }
        object.adoptDenseUnmappedArgumentsElementsAssumingEmpty(ctx.runtime, dense_elements);
        return object.value();
    }

    var argument_root_storage: []*core.VarRef = &.{};
    var rooted_argument_cells: []*core.VarRef = &.{};
    var argument_cells_root = CellSliceRoot{};
    argument_cells_root.init(ctx.runtime, &rooted_argument_cells);
    defer argument_cells_root.deinit();
    defer if (argument_root_storage.len != 0) ctx.runtime.memory.free(*core.VarRef, argument_root_storage);
    if (args.len > 0) {
        _ = try object.allocateMappedArgumentsVarRefsAssumingEmpty(ctx.runtime, args.len);
        argument_root_storage = try ctx.runtime.memory.alloc(*core.VarRef, args.len);
    }
    var initialized_argument_refs: usize = 0;
    for (args, 0..) |_, index| {
        const refs = object.argumentsVarRefsMut();
        const cell = if (index < frame.function.arg_count) blk: {
            break :blk try frame.captureArg(ctx.runtime, index);
        } else blk: {
            // qjs creates a closed var-ref for each extra actual argument: it
            // remains mutable through the Arguments object but has no formal
            // parameter binding in the frame.
            const initial = value_slot.loadOwned(&args[index]);
            errdefer initial.free(ctx.runtime);
            break :blk try core.VarRef.createClosed(ctx.runtime, initial);
        };
        refs[index] = cell;
        argument_root_storage[index] = cell;
        initialized_argument_refs = index + 1;
        rooted_argument_cells = argument_root_storage[0..initialized_argument_refs];
    }
    return object.value();
}

pub fn installFunctionPrototypeThrowTypeErrorAccessors(rt: *core.JSRuntime, global: *core.Object, thrower: core.JSValue) !void {
    const function_prototype = functionPrototypeFromGlobal(rt, global) orelse return;
    const arguments_key = core.atom.ids.arguments;
    try function_prototype.defineOwnProperty(rt, arguments_key, core.Descriptor.accessor(thrower, thrower, false, true));
    const caller_key = (comptime core.atom.predefinedId("caller", .string)).?;
    try function_prototype.defineOwnProperty(rt, caller_key, core.Descriptor.accessor(thrower, thrower, false, true));
}

pub fn isThrowTypeErrorIntrinsicObject(object: *core.Object) bool {
    return object.isThrowTypeErrorIntrinsicFunction();
}

pub fn frameArgumentsObject(ctx: *core.JSContext, global: *core.Object, frame: *frame_mod.Frame) !core.JSValue {
    if (frame.argumentsObject()) |value| return value.dup();
    const value = try createArgumentsObject(ctx, global, frame, null);
    (try frame.ensureCold(&ctx.runtime.memory)).arguments_object = value.dup();
    return value;
}

pub fn frameArgumentsObjectForSpecialObject(ctx: *core.JSContext, global: *core.Object, frame: *frame_mod.Frame, subtype: u8) !core.JSValue {
    // The compiler emits this special object once in the function prologue and
    // immediately stores it in the hidden `arguments_var_idx` local, matching
    // qjs. Only direct eval needs a second cross-bytecode lookup channel; keep
    // FrameCold as that bridge instead of allocating it for every ordinary
    // arguments-using call.
    const cache_for_direct_eval = frame.function.flags.has_eval_call;
    if (cache_for_direct_eval) {
        if (frame.argumentsObject()) |value| return value.dup();
    }
    const mapped_override: ?bool = switch (subtype) {
        0 => false,
        1 => true,
        else => null,
    };
    const value = try createArgumentsObject(ctx, global, frame, mapped_override);
    if (cache_for_direct_eval) {
        (try frame.ensureCold(&ctx.runtime.memory)).arguments_object = value.dup();
    }
    return value;
}

pub fn functionObjectFromValue(value: core.JSValue) ?*core.Object {
    const object = objectFromValue(value) orelse return null;
    if (object.class_id != core.class.ids.bytecode_function) return null;
    return object;
}

pub fn objectFromValue(value: core.JSValue) ?*core.Object {
    if (!value.isObject()) return null;
    const header = value.refHeader() orelse return null;
    if (header.meta().kind != .object) return null;
    return @fieldParentPtr("header", header);
}

pub fn callableObjectFromValue(value: core.JSValue) ?*core.Object {
    const object = objectFromValue(value) orelse return null;
    if (object.class_id != core.class.ids.c_function and
        object.class_id != core.class.ids.c_closure and
        object.class_id != core.class.ids.bound_function) return null;
    return object;
}

pub fn toPropertyKeyValue(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    if (!value.isObject()) return value.dup();
    return toPrimitiveForString(ctx, output, global, value, caller_function, caller_frame);
}

pub fn toPropertyKeyAtom(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.Atom {
    const key_value = try toPropertyKeyValue(ctx, output, global, value, caller_function, caller_frame);
    defer key_value.free(ctx.runtime);
    return property_ops.propertyKeyAtom(ctx.runtime, key_value);
}

pub fn callObjectToPrimitiveMethod(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    name: []const u8,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    const atom_id = try ctx.runtime.internAtom(name);
    defer ctx.runtime.atoms.free(atom_id);
    const object = try property_ops.expectObject(receiver);
    const method = try getMethodPropertyForOrdinaryToPrimitive(ctx, output, global, receiver, object, atom_id, caller_function, caller_frame);
    defer method.free(ctx.runtime);
    if (method.isUndefined() or method.isNull()) return null;
    if (!isCallableValue(method)) return null;
    const result = try callValueOrBytecode(ctx, output, global, receiver, method, &.{}, caller_function, caller_frame);
    if (result.isObject()) {
        result.free(ctx.runtime);
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
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    if (object.proxyTarget() != null) return getProxyProperty(ctx, output, global, receiver, object, atom_id, caller_function, caller_frame);
    if (try findPropertyDescriptor(ctx.runtime, object, atom_id)) |desc| {
        defer desc.destroy(ctx.runtime);
        switch (desc.kind) {
            .data => return desc.value.dup(),
            .accessor => {
                if (desc.getter.isUndefined()) return core.JSValue.undefinedValue();
                return callValueOrBytecode(ctx, output, global, receiver, desc.getter, &.{}, caller_function, caller_frame);
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
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const rt = ctx.runtime;
    if (value.isObject()) {
        const object = try property_ops.expectObject(value);
        // QJS keeps private-field access out of JS_GetPropertyInternal. ZJS
        // shares this entry point, so reject ordinary property atoms with the
        // AtomTable's conservative lower bound before consulting the full
        // dynamic kind table. Predefined names such as exec/flags/lastIndex
        // therefore pay only the cheap bound check; a possible private atom is
        // still confirmed exactly before taking private-field semantics.
        if (rt.atoms.mightBePrivate(atom_id) and rt.atoms.kind(atom_id) == .private) {
            const effective_atom = remapPrivateAtomForOperation(rt, caller_frame, object, atom_id);
            return getPrivateValueProperty(ctx, output, global, value, object, effective_atom, caller_function, caller_frame);
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
                if (atom_id == core.atom.ids.length) return value_ops.length(rt, value);
                if (core.atom.isTaggedInt(atom_id)) {
                    const index = core.atom.atomToUInt32(atom_id);
                    if (object.getDenseArrayElementValue(index)) |element| return element;
                }
                if (object.getOwnDataPropertyValue(atom_id)) |own_data| return own_data;
            } else if (object.class_id == core.class.ids.object) {
                if (object.getOwnDataPropertyValue(atom_id)) |own_data| return own_data;
            }
        }
        if (isFunctionLikeClass(object.class_id)) {
            if (try functionCallerArgumentsProperty(ctx, output, global, value, object, atom_id, caller_function, caller_frame)) |function_value| {
                return function_value;
            }
        }
        if (object.moduleNamespaceOwnBindingValue(atom_id)) |binding_value| {
            if (binding_value.isUninitialized()) {
                binding_value.free(rt);
                return error.ReferenceError;
            }
            return binding_value;
        }
        // QuickJS resolves an ordinary property with one shape/prototype walk:
        // find_own_property comes before every class/exotic check at every
        // prototype depth (quickjs.c:8268-8330). Class-specific numeric,
        // proxy, module and legacy-function behavior is handled by that same
        // walk only after a shape miss.
        if (try getPropertyValueFromObjectChain(ctx, output, global, value, object, atom_id, caller_function, caller_frame)) |property_value| {
            return property_value;
        }
        return getValuePropertyObjectMiss(ctx, global, value, object, atom_id);
    }
    return getValuePropertyNonObject(ctx, output, global, value, atom_id, caller_function, caller_frame);
}

/// Object-property fallback after the real shape/prototype chain missed. QJS
/// reaches the equivalent cases only from the cold exotic/missing-property
/// arms of JS_GetPropertyInternal; keeping them out of the common frame avoids
/// making every successful RegExp/result lookup carry their error paths.
noinline fn getValuePropertyObjectMiss(
    ctx: *core.JSContext,
    global: *core.Object,
    value: core.JSValue,
    object: *core.Object,
    atom_id: core.Atom,
) !core.JSValue {
    const rt = ctx.runtime;
    if (object.class_id == core.class.ids.dataview and
        (atom_id == atom_buffer or
            atom_id == atom_byte_length or
            atom_id == atom_byte_offset))
    {
        if (atom_id == atom_buffer) return (object.typedArrayBuffer() orelse return error.TypeError).dup();
        if (atom_id == atom_byte_length) return core.JSValue.int32(@intCast(try core.typed_array.dataViewByteLength(rt, object)));
        return core.JSValue.int32(@intCast(try core.typed_array.dataViewByteOffset(rt, object)));
    }
    const direct = object.getProperty(atom_id);
    if (!direct.isUndefined()) return direct;
    direct.free(rt);
    if (object.isArray() and atom_id == core.atom.ids.length) return value_ops.length(rt, value);
    if (object.class_id == core.class.ids.string) {
        if (object.objectData()) |string_data| {
            if (try getStringIndexValue(rt, string_data, atom_id)) |indexed| return indexed;
        }
    }
    if (object.isArray()) return getPrototypeMethodWithFallback(rt, global, "Array", atom_id, "Object");
    if (object.class_id == core.class.ids.object) {
        if (object.hasNullPrototype()) return core.JSValue.undefinedValue();
        return getPrototypeMethod(rt, global, "Object", atom_id);
    }
    if (object.class_id == core.class.ids.string) return getPrototypeMethod(rt, global, "String", atom_id);
    if (object.class_id == core.class.ids.number) return getPrototypeMethod(rt, global, "Number", atom_id);
    if (object.class_id == core.class.ids.boolean) return getPrototypeMethod(rt, global, "Boolean", atom_id);
    if (object.class_id == core.class.ids.big_int) return getPrototypeMethod(rt, global, "BigInt", atom_id);
    if (object.class_id == core.class.ids.symbol) return getPrototypeMethod(rt, global, "Symbol", atom_id);
    if (isFunctionLikeClass(object.class_id)) {
        return getPrototypeMethodWithFallback(rt, global, "Function", atom_id, "Object");
    }
    if (object.class_id == core.class.ids.date) return getPrototypeMethod(rt, global, "Date", atom_id);
    if (object.class_id == core.class.ids.regexp) return getPrototypeMethodWithFallback(rt, global, "RegExp", atom_id, "Object");
    if (object.class_id == core.class.ids.promise) return getPrototypeMethod(rt, global, "Promise", atom_id);
    if (object.class_id == core.class.ids.array_buffer) return getPrototypeMethod(rt, global, "ArrayBuffer", atom_id);
    if (object.class_id == core.class.ids.shared_array_buffer) return getPrototypeMethod(rt, global, "SharedArrayBuffer", atom_id);
    if (object.class_id == core.class.ids.weak_ref) return getPrototypeMethod(rt, global, "WeakRef", atom_id);
    if (object.class_id == core.class.ids.finalization_registry) return getPrototypeMethod(rt, global, "FinalizationRegistry", atom_id);
    if (object.class_id == core.class.ids.disposable_stack) return getPrototypeMethod(rt, global, "DisposableStack", atom_id);
    if (object.class_id == core.class.ids.async_disposable_stack) return getPrototypeMethod(rt, global, "AsyncDisposableStack", atom_id);
    if (object.class_id == core.class.ids.dataview) return getPrototypeMethod(rt, global, "DataView", atom_id);
    return core.JSValue.undefinedValue();
}

noinline fn getValuePropertyNonObject(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.JSValue,
    atom_id: core.Atom,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const rt = ctx.runtime;
    if (rt.atoms.mightBePrivate(atom_id) and rt.atoms.kind(atom_id) == .private) return error.TypeError;
    if (value.isString()) {
        if (atom_id == core.atom.ids.length) return value_ops.length(rt, value);
        if (try getStringIndexValue(rt, value, atom_id)) |indexed| return indexed;
        return getPrimitiveProperty(ctx, output, global, value, atom_id, caller_function, caller_frame);
    }
    if (value.isNumber() or value.isBool() or value.isBigInt() or value.isSymbol()) {
        return getPrimitiveProperty(ctx, output, global, value, atom_id, caller_function, caller_frame);
    }
    if (value.isNull() or value.isUndefined()) {
        return throwNullishPropertyTypeError(ctx, global, value, atom_id);
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
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    if (!isFunctionLikeClass(object.class_id)) return null;
    if (!value_ops.atomNameEql(ctx.runtime, atom_id, "caller") and !value_ops.atomNameEql(ctx.runtime, atom_id, "arguments")) return null;
    if (object.getOwnProperty(ctx.runtime, atom_id)) |own_desc| {
        defer own_desc.destroy(ctx.runtime);
        switch (own_desc.kind) {
            .data => return own_desc.value.dup(),
            .generic => return core.JSValue.undefinedValue(),
            .accessor => {
                if (own_desc.getter.isUndefined()) return core.JSValue.undefinedValue();
                return try callValueOrBytecode(ctx, output, global, receiver, own_desc.getter, &.{}, caller_function, caller_frame);
            },
        }
    }
    if (object.functionBytecode()) |fb_value| {
        const fb = functionBytecodeFromValue(fb_value) orelse return core.JSValue.undefinedValue();
        if (fb.flags.is_strict_mode or fb.flags.runtime_strict_mode or fb.flags.is_arrow_function or fb.flags.func_kind == .generator or fb.flags.func_kind == .async_generator) return error.TypeError;
        return core.JSValue.undefinedValue();
    }
    return error.TypeError;
}

noinline fn getPrivateValueProperty(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    object: *core.Object,
    atom_id: core.Atom,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    if (object.getOwnProperty(ctx.runtime, atom_id)) |desc| {
        defer desc.destroy(ctx.runtime);
        switch (desc.kind) {
            .data => return desc.value.dup(),
            .generic => return error.TypeError,
            .accessor => {
                if (desc.getter.isUndefined()) return error.TypeError;
                return callValueOrBytecode(ctx, output, global, receiver, desc.getter, &.{}, caller_function, caller_frame);
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
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !void {
    if (object.getOwnProperty(ctx.runtime, atom_id)) |desc| {
        defer desc.destroy(ctx.runtime);
        switch (desc.kind) {
            .data => {
                if (!(desc.writable orelse false)) return error.TypeError;
                if (!try object.setOwnWritableDataProperty(ctx.runtime, atom_id, value)) return error.TypeError;
                return;
            },
            .generic => return error.TypeError,
            .accessor => {
                if (desc.setter.isUndefined()) return error.TypeError;
                const result = try callValueOrBytecode(ctx, output, global, receiver, desc.setter, &.{value}, caller_function, caller_frame);
                result.free(ctx.runtime);
                return;
            },
        }
    }
    _ = try throwPrivateBrandTypeError(ctx, global, atom_id, caller_frame);
    return;
}

pub fn getPrimitiveProperty(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    atom_id: core.Atom,
    caller_function: ?*const bytecode.Bytecode,
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

pub fn ownDataOrAutoInitPropertyValue(object: *core.Object, atom_id: core.Atom) ?core.JSValue {
    if (object.hasExoticMethods()) return null;
    if (object.findProperty(atom_id)) |index| {
        return switch (object.propKindAt(index)) {
            .data => object.prop_values[index].slot.data.dup(),
            .auto_init => object.getProperty(atom_id),
            .var_ref, .accessor => null,
        };
    }
    return null;
}

pub fn getValuePropertyWithReceiver(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    target_value: core.JSValue,
    target: *core.Object,
    receiver_value: core.JSValue,
    atom_id: core.Atom,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    var current: ?*core.Object = target;
    while (current) |object| : (current = object.getPrototype()) {
        if (object.proxyTarget() != null) return getProxyProperty(ctx, output, global, receiver_value, object, atom_id, caller_function, caller_frame);
        if (object.getOwnProperty(ctx.runtime, atom_id)) |desc| {
            defer desc.destroy(ctx.runtime);
            switch (desc.kind) {
                .data => return desc.value.dup(),
                .generic => return core.JSValue.undefinedValue(),
                .accessor => {
                    if (desc.getter.isUndefined()) return core.JSValue.undefinedValue();
                    return callValueOrBytecode(ctx, output, global, receiver_value, desc.getter, &.{}, caller_function, caller_frame);
                },
            }
        }
    }
    return getValueProperty(ctx, output, global, target_value, atom_id, caller_function, caller_frame);
}

pub fn primitiveObjectForAccess(rt: *core.JSRuntime, global: *core.Object, primitive: core.JSValue) !core.JSValue {
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

    const prototype = primitivePrototypeForAccess(rt, global, rooted_primitive) orelse return error.TypeError;
    if (rooted_primitive.isString()) {
        const object = try core.Object.create(rt, core.class.ids.string, prototype);
        errdefer core.Object.destroyFromHeader(rt, &object.header);
        try object.setOptionalValueSlot(rt, object.objectDataSlot(), rooted_primitive.dup());
        const string_value = rooted_primitive.asStringBody() orelse return error.TypeError;
        try string_value.ensureFlat(rt);
        var index: u32 = 0;
        while (index < string_value.len()) : (index += 1) {
            try defineStringWrapperIndexProperty(rt, object, index, string_value.codeUnitAt(index));
        }
        try object.defineOwnProperty(rt, core.atom.ids.length, core.Descriptor.data(core.JSValue.int32(@intCast(string_value.len())), false, false, false));
        return object.value();
    }
    const class_id: core.class.ClassId = if (rooted_primitive.isNumber())
        core.class.ids.number
    else if (rooted_primitive.isBool())
        core.class.ids.boolean
    else if (rooted_primitive.isBigInt())
        core.class.ids.big_int
    else if (rooted_primitive.isSymbol())
        core.class.ids.symbol
    else
        return error.TypeError;
    const object = try core.Object.create(rt, class_id, prototype);
    errdefer core.Object.destroyFromHeader(rt, &object.header);
    try object.setOptionalValueSlot(rt, object.objectDataSlot(), rooted_primitive.dup());
    return object.value();
}

test "primitiveObjectForAccess roots direct symbol while creating wrapper" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    const global = try core.Object.create(rt, core.class.ids.object, null);
    const symbol_constructor = try core.Object.create(rt, core.class.ids.object, null);
    const symbol_prototype = try core.Object.create(rt, core.class.ids.object, null);
    defer {
        symbol_prototype.value().free(rt);
        symbol_constructor.value().free(rt);
        global.value().free(rt);
        rt.destroy();
    }

    try symbol_constructor.defineOwnProperty(
        rt,
        core.atom.ids.prototype,
        core.Descriptor.data(symbol_prototype.value(), true, true, true),
    );
    const symbol_ctor_atom = try rt.internAtom("Symbol");
    defer rt.atoms.free(symbol_ctor_atom);
    try global.defineOwnProperty(
        rt,
        symbol_ctor_atom,
        core.Descriptor.data(symbol_constructor.value(), true, true, true),
    );

    const symbol_atom = try rt.atoms.newValueSymbol("gc-primitive-wrapper-symbol");
    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const symbol_value = try rt.symbolValue(symbol_atom);
    const wrapper_value = try primitiveObjectForAccess(rt, global, symbol_value);
    var wrapper_alive = true;
    defer if (wrapper_alive) wrapper_value.free(rt);
    const wrapper = objectFromValue(wrapper_value) orelse return error.TypeError;

    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    const stored = wrapper.objectData() orelse return error.TypeError;
    try std.testing.expect(stored.same(symbol_value));

    wrapper_value.free(rt);
    wrapper_alive = false;
    symbol_value.free(rt);
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

pub fn setValueProperty(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    object_value: core.JSValue,
    atom_id: core.Atom,
    value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
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
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
    force_throw: bool,
) HostError!core.JSValue {
    const throw_on_set_failure = force_throw or setFailureShouldThrow(caller_function);
    if (ctx.runtime.atoms.kind(atom_id) == .private) {
        if (!object_value.isObject()) return error.TypeError;
        const object = try property_ops.expectObject(object_value);
        const effective_atom = remapPrivateAtomForOperation(ctx.runtime, caller_frame, object, atom_id);
        try setPrivateValueProperty(ctx, output, global, object_value, object, effective_atom, value, caller_function, caller_frame);
        return core.JSValue.undefinedValue();
    }
    const is_strict = if (caller_function) |func| functionRuntimeStrict(func) else false;
    if (!object_value.isObject()) {
        if (object_value.isNull() or object_value.isUndefined()) return error.TypeError;
        const boxed_value = try primitiveObjectForAccess(ctx.runtime, global, object_value);
        defer boxed_value.free(ctx.runtime);
        const boxed = try property_ops.expectObject(boxed_value);
        const succeeded = try ordinarySetWithReceiver(ctx, output, global, boxed_value, boxed, object_value, atom_id, value, caller_function, caller_frame);
        if (!succeeded and throw_on_set_failure) return throwSetFailureTypeError(ctx, global, atom_id, error.TypeError);
        return core.JSValue.undefinedValue();
    }
    const object = try property_ops.expectObject(object_value);
    if (object.proxyTarget() != null) {
        const ok = try proxySetValueProperty(ctx, output, global, object_value, object, atom_id, value, caller_function, caller_frame);
        if (!ok and throw_on_set_failure) return throwSetFailureTypeError(ctx, global, atom_id, error.TypeError);
        return core.JSValue.undefinedValue();
    }
    if (object.flags.is_with_environment and is_strict and !object.hasProperty(atom_id)) return error.ReferenceError;
    if (try setMappedArgumentsValue(ctx, object, atom_id, value)) return core.JSValue.undefinedValue();
    if (core.object.isTypedArrayObject(object)) {
        if (try typedArrayCanonicalSet(ctx, output, global, object, atom_id, value)) {
            return core.JSValue.undefinedValue();
        }
    }
    if (object.isArray() and atom_id == core.atom.ids.length) {
        const value_to_set = try arrayLengthAssignmentValue(ctx, output, global, object, atom_id, value, caller_function, caller_frame);
        defer if (!value_to_set.same(value)) value_to_set.free(ctx.runtime);
        object.setProperty(ctx.runtime, atom_id, value_to_set) catch |err| switch (err) {
            error.InvalidLength => return error.RangeError,
            error.ReadOnly => {
                if (throw_on_set_failure) return throwSetFailureTypeError(ctx, global, atom_id, error.ReadOnly);
                return core.JSValue.undefinedValue();
            },
            error.AccessorWithoutSetter => {
                if (throw_on_set_failure) return throwSetFailureTypeError(ctx, global, atom_id, error.AccessorWithoutSetter);
                return core.JSValue.undefinedValue();
            },
            error.NotExtensible => {
                if (throw_on_set_failure) return throwSetFailureTypeError(ctx, global, atom_id, error.NotExtensible);
                return core.JSValue.undefinedValue();
            },
            error.IncompatibleDescriptor => {
                if (throw_on_set_failure) return throwSetFailureTypeError(ctx, global, atom_id, error.IncompatibleDescriptor);
                return core.JSValue.undefinedValue();
            },
            else => return err,
        };
        return core.JSValue.undefinedValue();
    }
    if (object.isArray()) {
        if (core.array.arrayIndexFromAtom(&ctx.runtime.atoms, atom_id)) |index| {
            if (try object.appendDenseArrayIndex(ctx.runtime, index, atom_id, value)) return core.JSValue.undefinedValue();
        }
    }
    if (try object.setOwnWritableDataProperty(ctx.runtime, atom_id, value)) return core.JSValue.undefinedValue();
    if (try object.defineNewOwnDataPropertyForSimpleSet(ctx.runtime, atom_id, value)) return core.JSValue.undefinedValue();
    if (try typedArrayPrototypeSet(ctx, output, global, object_value, object, object.getPrototype(), atom_id, value, caller_function, caller_frame)) |ok| {
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
    if (ctx.runtime.atoms.kind(atom_id) == .private) return error.TypeError;
    const value_to_set = try arrayLengthAssignmentValue(ctx, output, global, object, atom_id, value, caller_function, caller_frame);
    defer if (!value_to_set.same(value)) value_to_set.free(ctx.runtime);
    object.setProperty(ctx.runtime, atom_id, value_to_set) catch |err| switch (err) {
        error.InvalidLength => return error.RangeError,
        error.ReadOnly => {
            if (throw_on_set_failure) return throwSetFailureTypeError(ctx, global, atom_id, error.ReadOnly);
            return core.JSValue.undefinedValue();
        },
        error.AccessorWithoutSetter => {
            if (throw_on_set_failure) return throwSetFailureTypeError(ctx, global, atom_id, error.AccessorWithoutSetter);
            return core.JSValue.undefinedValue();
        },
        error.NotExtensible => {
            if (throw_on_set_failure) return throwSetFailureTypeError(ctx, global, atom_id, error.NotExtensible);
            return core.JSValue.undefinedValue();
        },
        error.IncompatibleDescriptor => {
            if (throw_on_set_failure) return throwSetFailureTypeError(ctx, global, atom_id, error.IncompatibleDescriptor);
            return core.JSValue.undefinedValue();
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
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) HostError!bool {
    switch (own_desc.kind) {
        .accessor => {
            if (own_desc.setter.isUndefined()) return false;
            const result = try callValueOrBytecode(ctx, output, global, receiver_value, own_desc.setter, &.{value}, caller_function, caller_frame);
            result.free(ctx.runtime);
            return true;
        },
        .data, .generic => {
            if (own_desc.kind == .data and own_desc.writable == false) return false;
            const receiver = objectFromValue(receiver_value) orelse return false;
            const receiver_desc = try proxyAwareOwnPropertyDescriptor(ctx, output, global, receiver, atom_id, caller_function, caller_frame);
            defer if (receiver_desc) |desc| desc.destroy(ctx.runtime);
            if (receiver_desc) |desc| {
                if (desc.kind == .accessor) return false;
                if (desc.kind == .data and desc.writable == false) return false;
                const update_desc = core.Descriptor{
                    .kind = .data,
                    .value = value,
                    .value_present = true,
                };
                if (receiver.proxyTarget() != null) return try proxyDefineOwnProperty(ctx, output, global, receiver, atom_id, update_desc, caller_function, caller_frame);
                receiver.defineOwnProperty(ctx.runtime, atom_id, update_desc) catch |err| switch (err) {
                    error.ReadOnly, error.NotExtensible, error.IncompatibleDescriptor => return false,
                    error.InvalidLength => return error.RangeError,
                    else => return err,
                };
                return true;
            }
            const create_desc = core.Descriptor.data(value, true, true, true);
            if (receiver.proxyTarget() != null) return try proxyDefineOwnProperty(ctx, output, global, receiver, atom_id, create_desc, caller_function, caller_frame);
            receiver.defineOwnProperty(ctx.runtime, atom_id, create_desc) catch |err| switch (err) {
                error.ReadOnly, error.NotExtensible, error.IncompatibleDescriptor => return false,
                error.InvalidLength => return error.RangeError,
                else => return err,
            };
            return true;
        },
    }
}

pub fn bytecodeFunctionObjectTag(object: *core.Object) []const u8 {
    const function_value = object.functionBytecode() orelse return "Function";
    const function_bytecode = functionBytecodeFromValue(function_value) orelse return "Function";
    if (function_bytecode.flags.func_kind == .async or function_bytecode.flags.func_kind == .async_generator) return "AsyncFunction";
    if (function_bytecode.flags.func_kind == .generator) return "GeneratorFunction";
    return "Function";
}

pub fn qjsDefinePropertyWithKind(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    kind: i32,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    if (args.len < 1) return error.TypeError;
    const object = property_ops.expectObject(args[0]) catch return @as(?core.JSValue, try throwTypeErrorMessage(ctx, global, "not an object"));
    if (args.len < 2) return error.TypeError;
    const atom_id = try toPropertyKeyAtom(ctx, output, global, args[1], caller_function, caller_frame);
    defer ctx.runtime.atoms.free(atom_id);
    if (args.len < 3) return error.TypeError;
    const desc_object = property_ops.expectObject(args[2]) catch return error.TypeError;
    const desc = try qjsDescriptorFromObject(ctx, output, global, args[2], desc_object, object, atom_id, caller_function, caller_frame);
    defer desc.destroy(ctx.runtime);
    const defined = if (object.proxyTarget() != null)
        proxyDefineOwnProperty(ctx, output, global, object, atom_id, desc, caller_function, caller_frame) catch |err| switch (err) {
            error.IncompatibleDescriptor, error.NotExtensible, error.ReadOnly => {
                if (kind == 2) return core.JSValue.boolean(false);
                return error.TypeError;
            },
            error.InvalidLength => return error.RangeError,
            else => return err,
        }
    else blk: {
        if (try typedArrayDefineOwnPropertyVm(ctx, output, global, object, atom_id, desc)) |ok| {
            break :blk ok;
        } else {
            object.defineOwnProperty(ctx.runtime, atom_id, desc) catch |err| switch (err) {
                error.IncompatibleDescriptor, error.NotExtensible, error.ReadOnly => {
                    if (kind == 2) return core.JSValue.boolean(false);
                    return error.TypeError;
                },
                error.InvalidLength => return error.RangeError,
                else => return err,
            };
            break :blk true;
        }
    };
    if (!defined) {
        if (kind == 2) return core.JSValue.boolean(false);
        return error.TypeError;
    }
    if (kind == 2) return core.JSValue.boolean(true);
    return args[0].dup();
}

pub const PendingPropertyDescriptor = struct {
    atom_id: core.Atom,
    desc: core.Descriptor,

    pub fn destroy(self: PendingPropertyDescriptor, rt: *core.JSRuntime) void {
        rt.atoms.free(self.atom_id);
        self.desc.destroy(rt);
    }
};

pub fn qjsObjectEnumerableOwnPropertiesCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    mode: core.object.EntriesMode,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    if (args.len < 1) return error.TypeError;
    if (args[0].isNull() or args[0].isUndefined()) return @as(?core.JSValue, try throwTypeErrorMessage(ctx, global, "Cannot convert undefined or null to object"));

    var object_value = if (objectFromValue(args[0])) |_| args[0].dup() else try primitiveObjectForAccess(ctx.runtime, global, args[0]);
    defer object_value.free(ctx.runtime);
    const object = objectFromValue(object_value) orelse return error.TypeError;
    const keys = try objectRestOwnKeys(ctx, output, global, object);
    defer core.Object.freeKeys(ctx.runtime, keys);

    const out = try core.Object.createArray(ctx.runtime, arrayPrototypeFromGlobal(ctx.runtime, global));
    errdefer core.Object.destroyFromHeader(ctx.runtime, &out.header);
    var out_value = out.value();

    var element = core.JSValue.undefinedValue();
    defer element.free(ctx.runtime);

    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &object_value },
        .{ .value = &out_value },
        .{ .value = &element },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = ctx.runtime.active_value_roots,
        .values = &root_values,
    };
    ctx.runtime.active_value_roots = &root_frame;
    defer ctx.runtime.active_value_roots = root_frame.previous;

    for (keys) |key| {
        if (ctx.runtime.atoms.isPublicSymbol(key)) continue;
        const desc = try objectRestOwnPropertyDescriptor(ctx, output, global, object, key) orelse continue;
        defer desc.destroy(ctx.runtime);
        if (desc.enumerable != true) continue;

        element = switch (mode) {
            .keys => try ctx.runtime.atoms.toStringValue(ctx.runtime, key),
            .values => try getValueProperty(ctx, output, global, object_value, key, caller_function, caller_frame),
            .entries => try qjsObjectEntryArrayValue(ctx, output, global, object_value, key, caller_function, caller_frame),
        };
        errdefer {
            element.free(ctx.runtime);
            element = core.JSValue.undefinedValue();
        }
        try createDataPropertyOrThrow(ctx, output, global, out_value, out, core.atom.atomFromUInt32(out.arrayLength()), element, caller_function, caller_frame);
        element.free(ctx.runtime);
        element = core.JSValue.undefinedValue();
    }
    return out_value;
}

pub fn qjsObjectProtoGetterCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    if (this_value.isNull() or this_value.isUndefined()) return error.TypeError;
    const object_value = if (objectFromValue(this_value)) |_| this_value.dup() else try primitiveObjectForAccess(ctx.runtime, global, this_value);
    defer object_value.free(ctx.runtime);
    const object = objectFromValue(object_value) orelse return error.TypeError;
    return qjsObjectGetPrototypeOfValue(ctx, output, global, object, caller_function, caller_frame);
}

pub fn qjsObjectProtoSetterCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    prototype_value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    if (this_value.isNull() or this_value.isUndefined()) return error.TypeError;
    if (!prototype_value.isNull() and objectFromValue(prototype_value) == null) return core.JSValue.undefinedValue();
    if (objectFromValue(this_value) == null) return core.JSValue.undefinedValue();
    var args = [_]core.JSValue{ this_value, prototype_value };
    if (try qjsObjectSetPrototypeOfCall(ctx, output, global, &args, caller_function, caller_frame)) |value| {
        value.free(ctx.runtime);
        return core.JSValue.undefinedValue();
    }
    return core.JSValue.undefinedValue();
}

pub fn qjsObjectIsExtensibleCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    const target_value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const object = objectFromValue(target_value) orelse return core.JSValue.boolean(false);
    if (object.proxyTarget() == null) return core.JSValue.boolean(object.isExtensible());
    const proxy_target_value = object.proxyTarget() orelse return core.JSValue.boolean(object.isExtensible());
    const target = objectFromValue(proxy_target_value) orelse return error.TypeError;
    const handler_value = object.proxyHandler() orelse return error.TypeError;
    const trap_key = try ctx.runtime.internAtom("isExtensible");
    defer ctx.runtime.atoms.free(trap_key);
    const trap = try getValueProperty(ctx, output, global, handler_value, trap_key, caller_function, caller_frame);
    defer trap.free(ctx.runtime);
    if (trap.isUndefined() or trap.isNull()) return core.JSValue.boolean(try proxyAwareIsExtensible(ctx, output, global, target, caller_function, caller_frame));
    if (!isCallableValue(trap)) return error.TypeError;
    const result = try callValueOrBytecode(ctx, output, global, handler_value, trap, &.{proxy_target_value}, caller_function, caller_frame);
    defer result.free(ctx.runtime);
    const extensible = valueTruthy(result);
    if (extensible != try proxyAwareIsExtensible(ctx, output, global, target, caller_function, caller_frame)) return error.TypeError;
    return core.JSValue.boolean(extensible);
}

pub fn qjsObjectSetPrototypeOfCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    if (args.len < 2) return error.TypeError;
    if (args[0].isNull() or args[0].isUndefined()) return @as(?core.JSValue, try throwTypeErrorMessage(ctx, global, "not an object"));
    const prototype: ?*core.Object = if (args[1].isNull())
        null
    else
        objectFromValue(args[1]) orelse return error.TypeError;
    const object = objectFromValue(args[0]) orelse return args[0].dup();
    if (object.proxyTarget() == null and objectHasImmutablePrototype(ctx.runtime, object) and object.getPrototype() != prototype) return error.TypeError;
    if (object.proxyTarget() != null) {
        if (!try proxyAwareSetPrototypeOf(ctx, output, global, object, prototype, caller_function, caller_frame)) return error.TypeError;
        return args[0].dup();
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
    return args[0].dup();
}

pub fn qjsReflectSetPrototypeOfCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    if (args.len < 2) return null;
    const object = objectFromValue(args[0]) orelse return error.TypeError;
    const prototype: ?*core.Object = if (args[1].isNull())
        null
    else
        objectFromValue(args[1]) orelse return error.TypeError;
    if (object.proxyTarget() == null and objectHasImmutablePrototype(ctx.runtime, object) and object.getPrototype() != prototype) return core.JSValue.boolean(false);
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
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?*core.Object {
    const prototype_value = try getValueProperty(ctx, output, global, new_target, core.atom.ids.prototype, caller_function, caller_frame);
    defer prototype_value.free(ctx.runtime);
    if (prototype_value.isObject()) return objectFromValue(prototype_value);
    if (try reflectConstructRealmPrototype(ctx, output, global, target_name, new_target, caller_function, caller_frame)) |prototype| return prototype;
    const fallback_global = if (objectFromValue(new_target)) |new_target_object|
        functionRealmGlobal(new_target_object) orelse global
    else
        global;
    return constructorPrototypeFromGlobal(ctx.runtime, fallback_global, target_name);
}

pub fn reflectConstructRealmPrototype(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    target_name: []const u8,
    new_target: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?*core.Object {
    const realm_key_name = try std.fmt.allocPrint(ctx.runtime.memory.allocator, "__realm_{s}_proto", .{target_name});
    defer ctx.runtime.memory.allocator.free(realm_key_name);
    const realm_key = try ctx.runtime.internAtom(realm_key_name);
    defer ctx.runtime.atoms.free(realm_key);
    const realm_proto_value = try getValueProperty(ctx, output, global, new_target, realm_key, caller_function, caller_frame);
    defer realm_proto_value.free(ctx.runtime);
    if (!realm_proto_value.isObject()) return null;
    return objectFromValue(realm_proto_value);
}

pub fn objectHasImmutablePrototype(rt: *core.JSRuntime, object: *core.Object) bool {
    _ = rt;
    return object.hasImmutablePrototype();
}

pub fn qjsReflectDeletePropertyCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    if (args.len < 2) return error.TypeError;
    const object = try property_ops.expectObject(args[0]);
    const atom_id = try toPropertyKeyAtom(ctx, output, global, args[1], caller_function, caller_frame);
    defer ctx.runtime.atoms.free(atom_id);
    return core.JSValue.boolean(try deleteValueProperty(ctx, output, global, args[0], object, atom_id, caller_function, caller_frame));
}

pub fn qjsReflectGetOwnPropertyDescriptorCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    if (args.len < 2) return error.TypeError;
    const object = objectFromValue(args[0]) orelse return error.TypeError;
    const atom_id = try toPropertyKeyAtom(ctx, output, global, args[1], caller_function, caller_frame);
    defer ctx.runtime.atoms.free(atom_id);
    var desc = try proxyAwareOwnPropertyDescriptor(ctx, output, global, object, atom_id, caller_function, caller_frame) orelse return core.JSValue.undefinedValue();
    try call_mod.materializeMappedArgumentsDescriptorValueForVm(ctx.runtime, object, atom_id, &desc);
    defer desc.destroy(ctx.runtime);
    return try descriptorObjectFromDescriptor(ctx.runtime, global, desc);
}

pub fn qjsReflectGetPrototypeOfCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    if (args.len < 1) return error.TypeError;
    const object = objectFromValue(args[0]) orelse return error.TypeError;
    return try qjsObjectGetPrototypeOfValue(ctx, output, global, object, caller_function, caller_frame);
}

pub fn descriptorObjectFromDescriptor(rt: *core.JSRuntime, global: *core.Object, desc: core.Descriptor) !core.JSValue {
    var desc_value = desc.value;
    var desc_getter = desc.getter;
    var desc_setter = desc.setter;
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &desc_value },
        .{ .value = &desc_getter },
        .{ .value = &desc_setter },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    const object = try core.Object.create(rt, core.class.ids.object, objectPrototypeFromGlobal(rt, global));
    errdefer core.Object.destroyFromHeader(rt, &object.header);
    if (desc.kind == .data and desc.value_present) {
        try defineValueProperty(rt, object, "value", desc_value);
    } else if (desc.kind == .accessor) {
        if (desc.getter_present) try defineValueProperty(rt, object, "get", desc_getter);
        if (desc.setter_present) try defineValueProperty(rt, object, "set", desc_setter);
    }
    if (desc.writable) |writable| try defineValueProperty(rt, object, "writable", core.JSValue.boolean(writable));
    if (desc.enumerable) |enumerable| try defineValueProperty(rt, object, "enumerable", core.JSValue.boolean(enumerable));
    if (desc.configurable) |configurable| try defineValueProperty(rt, object, "configurable", core.JSValue.boolean(configurable));
    return object.value();
}

test "descriptorObjectFromDescriptor roots direct function bytecode value while creating descriptor object" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const global = try core.Object.create(rt, core.class.ids.object, null);
    defer global.value().free(rt);

    const fb_slice = try rt.memory.alloc(bytecode.FunctionBytecode, 1);
    const fb = &fb_slice[0];
    fb.* = bytecode.FunctionBytecode.init(&rt.memory, &rt.atoms, core.atom.ids.empty_string);
    try rt.gc.add(&fb.header);

    {
        const __cp = try rt.memory.alloc(core.JSValue, 1);
        fb.cpool = __cp.ptr;
        fb.cpool_count = @intCast(__cp.len);
    }
    const symbol_atom = try rt.atoms.newValueSymbol("gc-descriptor-object-value-bytecode-symbol");
    fb.cpool[0] = try rt.symbolValue(symbol_atom);

    var desc_value = core.JSValue.functionBytecode(&fb.header);
    var desc_value_alive = true;
    defer if (desc_value_alive) desc_value.free(rt);

    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const descriptor_value = try descriptorObjectFromDescriptor(
        rt,
        global,
        core.Descriptor.data(desc_value, true, true, true),
    );
    var descriptor_alive = true;
    defer if (descriptor_alive) descriptor_value.free(rt);
    const descriptor = objectFromValue(descriptor_value) orelse return error.TypeError;

    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    const value_key = try rt.internAtom("value");
    defer rt.atoms.free(value_key);
    {
        const stored = descriptor.getProperty(value_key);
        defer stored.free(rt);
        try std.testing.expect(stored.same(desc_value));
    }

    descriptor_value.free(rt);
    descriptor_alive = false;
    desc_value.free(rt);
    desc_value_alive = false;
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

pub fn qjsDescriptorFromObject(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    desc_value: core.JSValue,
    desc_object: *core.Object,
    target: *core.Object,
    atom_id: core.Atom,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.Descriptor {
    const value_key = try ctx.runtime.internAtom("value");
    defer ctx.runtime.atoms.free(value_key);
    const writable_key = try ctx.runtime.internAtom("writable");
    defer ctx.runtime.atoms.free(writable_key);
    const get_key = try ctx.runtime.internAtom("get");
    defer ctx.runtime.atoms.free(get_key);
    const set_key = try ctx.runtime.internAtom("set");
    defer ctx.runtime.atoms.free(set_key);
    const enumerable_key = try ctx.runtime.internAtom("enumerable");
    defer ctx.runtime.atoms.free(enumerable_key);
    const configurable_key = try ctx.runtime.internAtom("configurable");
    defer ctx.runtime.atoms.free(configurable_key);

    const enumerable = try qjsOptionalBoolDescriptorProperty(ctx, output, global, desc_value, desc_object, enumerable_key, caller_function, caller_frame);
    const configurable = try qjsOptionalBoolDescriptorProperty(ctx, output, global, desc_value, desc_object, configurable_key, caller_function, caller_frame);

    const has_value = try hasValueProperty(ctx, output, global, desc_value, desc_object, value_key, null, null);
    var data_value: ?core.JSValue = null;
    errdefer if (data_value) |stored| stored.free(ctx.runtime);
    if (has_value) data_value = try getValueProperty(ctx, output, global, desc_value, value_key, caller_function, caller_frame);

    const has_writable = try hasValueProperty(ctx, output, global, desc_value, desc_object, writable_key, null, null);
    const writable = if (has_writable) blk: {
        const writable_value = try getValueProperty(ctx, output, global, desc_value, writable_key, caller_function, caller_frame);
        defer writable_value.free(ctx.runtime);
        break :blk valueTruthy(writable_value);
    } else null;

    const has_get = try hasValueProperty(ctx, output, global, desc_value, desc_object, get_key, null, null);
    var getter_value: ?core.JSValue = null;
    errdefer if (getter_value) |stored| stored.free(ctx.runtime);
    if (has_get) {
        const value = try getValueProperty(ctx, output, global, desc_value, get_key, caller_function, caller_frame);
        if (!value.isUndefined() and !isCallableValue(value)) {
            value.free(ctx.runtime);
            return error.TypeError;
        }
        getter_value = value;
    }

    const has_set = try hasValueProperty(ctx, output, global, desc_value, desc_object, set_key, null, null);
    var setter_value: ?core.JSValue = null;
    errdefer if (setter_value) |stored| stored.free(ctx.runtime);
    if (has_set) {
        const value = try getValueProperty(ctx, output, global, desc_value, set_key, caller_function, caller_frame);
        if (!value.isUndefined() and !isCallableValue(value)) {
            value.free(ctx.runtime);
            return error.TypeError;
        }
        setter_value = value;
    }

    if ((has_get or has_set) and (has_value or has_writable)) return error.TypeError;
    if (has_get or has_set) {
        const getter = getter_value orelse core.JSValue.undefinedValue();
        getter_value = null;
        const setter = setter_value orelse core.JSValue.undefinedValue();
        setter_value = null;
        return .{
            .kind = .accessor,
            .getter = getter,
            .getter_present = has_get,
            .setter = setter,
            .setter_present = has_set,
            .enumerable = enumerable,
            .configurable = configurable,
        };
    }
    if (has_value or has_writable) {
        var value = data_value orelse core.JSValue.undefinedValue();
        data_value = null;
        errdefer value.free(ctx.runtime);
        if (has_value and target.isArray() and atom_id == core.atom.ids.length and !value.isNumber()) {
            const coerced = try arrayLengthDefineValue(ctx, output, global, value);
            value.free(ctx.runtime);
            value = coerced;
        }
        return .{
            .kind = .data,
            .value = value,
            .value_present = has_value,
            .writable = writable,
            .enumerable = enumerable,
            .configurable = configurable,
        };
    }
    return core.Descriptor.generic(enumerable, configurable);
}

pub fn qjsOptionalBoolDescriptorProperty(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    desc_value: core.JSValue,
    desc_object: *core.Object,
    atom_id: core.Atom,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?bool {
    if (!try hasValueProperty(ctx, output, global, desc_value, desc_object, atom_id, null, null)) return null;
    const value = try getValueProperty(ctx, output, global, desc_value, atom_id, caller_function, caller_frame);
    defer value.free(ctx.runtime);
    return valueTruthy(value);
}

pub fn getAccessorDescriptorValue(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    object: *core.Object,
    atom_id: core.Atom,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    if (try findPropertyDescriptor(ctx.runtime, object, atom_id)) |desc| {
        defer desc.destroy(ctx.runtime);
        if (desc.kind != .accessor) return null;
        if (desc.getter.isUndefined()) return core.JSValue.undefinedValue();
        return try callValueOrBytecode(ctx, output, global, receiver, desc.getter, &.{}, caller_function, caller_frame);
    }
    return null;
}

pub fn getPrototypePropertyValue(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    object: *core.Object,
    atom_id: core.Atom,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    const prototype = object.getPrototype() orelse return null;
    return getPropertyValueFromObjectChain(ctx, output, global, receiver, prototype, atom_id, caller_function, caller_frame);
}

inline fn getPropertyValueFromObjectChain(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    first: *core.Object,
    atom_id: core.Atom,
    caller_function: ?*const bytecode.Bytecode,
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
                .data => return lookup.entry.slot.data.dup(),
                .accessor => {
                    const getter = lookup.entry.slot.accessor.getterValue().dup();
                    defer getter.free(ctx.runtime);
                    if (getter.isUndefined()) return core.JSValue.undefinedValue();
                    return try callValueOrBytecode(ctx, output, global, receiver, getter, &.{}, caller_function, caller_frame);
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
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    if (object.class_id == core.class.ids.proxy) {
        return try getProxyProperty(ctx, output, global, receiver, object, atom_id, caller_function, caller_frame);
    }
    if (object.getOwnProperty(ctx.runtime, atom_id)) |desc| {
        defer desc.destroy(ctx.runtime);
        switch (desc.kind) {
            .data => return desc.value.dup(),
            .generic => return core.JSValue.undefinedValue(),
            .accessor => {
                if (desc.getter.isUndefined()) return core.JSValue.undefinedValue();
                return try callValueOrBytecode(ctx, output, global, receiver, desc.getter, &.{}, caller_function, caller_frame);
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
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    var current: ?*core.Object = prototype;
    while (current) |object| {
        if (try findPropertyDescriptor(ctx.runtime, object, atom_id)) |desc| {
            defer desc.destroy(ctx.runtime);
            switch (desc.kind) {
                .accessor => {
                    if (desc.getter.isUndefined()) return core.JSValue.undefinedValue();
                    return callValueOrBytecode(ctx, output, global, receiver, desc.getter, &.{}, caller_function, caller_frame);
                },
                .data => return desc.value.dup(),
                .generic => {},
            }
        }
        current = object.getPrototype();
    }
    return core.JSValue.undefinedValue();
}

pub fn setSuperPropertyValue(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    prototype: *core.Object,
    atom_id: core.Atom,
    value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !void {
    if (try findPropertyDescriptor(ctx.runtime, prototype, atom_id)) |desc| {
        defer desc.destroy(ctx.runtime);
        switch (desc.kind) {
            .accessor => {
                if (desc.setter.isUndefined()) return error.AccessorWithoutSetter;
                const result = try callValueOrBytecode(ctx, output, global, receiver, desc.setter, &.{value}, caller_function, caller_frame);
                result.free(ctx.runtime);
                return;
            },
            .data => {
                if (try rejectModuleNamespaceSuperSet(ctx, receiver, atom_id)) return;
                const result = try setValueProperty(ctx, output, global, receiver, atom_id, value, caller_function, caller_frame);
                result.free(ctx.runtime);
                return;
            },
            .generic => {},
        }
    }
    if (try rejectModuleNamespaceSuperSet(ctx, receiver, atom_id)) return;
    const result = try setValueProperty(ctx, output, global, receiver, atom_id, value, caller_function, caller_frame);
    result.free(ctx.runtime);
}

pub fn findPropertyDescriptor(rt: *core.JSRuntime, object: *core.Object, atom_id: core.Atom) !?core.Descriptor {
    if (object.getOwnProperty(rt, atom_id)) |desc| return desc;
    if (object.getPrototype()) |proto| return findPropertyDescriptor(rt, proto, atom_id);
    return null;
}

pub fn sameObjectIdentity(a: core.JSValue, b: core.JSValue) bool {
    if (!a.isObject() or !b.isObject()) return false;
    const a_header = a.refHeader() orelse return false;
    const b_header = b.refHeader() orelse return false;
    return a_header == b_header;
}

pub fn remapPrivateAtomFromObject(rt: *core.JSRuntime, object: *const core.Object, atom_id: core.Atom) core.Atom {
    if (rt.atoms.kind(atom_id) != .private) return atom_id;
    for (object.privateRemapFrom(), 0..) |old_atom, idx| {
        if (old_atom == atom_id) return object.privateRemapTo()[idx];
    }
    return atom_id;
}

pub fn getPrototypeMethodWithFallback(rt: *core.JSRuntime, global: *core.Object, constructor_name: []const u8, atom_id: core.Atom, fallback_constructor_name: []const u8) !core.JSValue {
    const value = try getPrototypeMethod(rt, global, constructor_name, atom_id);
    if (!value.isUndefined()) return value;
    value.free(rt);
    return getPrototypeMethod(rt, global, fallback_constructor_name, atom_id);
}

pub fn getPrototypeMethod(rt: *core.JSRuntime, global: *core.Object, constructor_name: []const u8, atom_id: core.Atom) !core.JSValue {
    const ctor_key = try rt.internAtom(constructor_name);
    defer rt.atoms.free(ctor_key);
    const ctor_value = global.getProperty(ctor_key);
    defer ctor_value.free(rt);
    const ctor = try property_ops.expectObject(ctor_value);
    const proto_value = ctor.getProperty(core.atom.ids.prototype);
    defer proto_value.free(rt);
    const proto = try property_ops.expectObject(proto_value);
    return proto.getProperty(atom_id);
}

pub fn hasPropertyForWith(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    object_value: core.JSValue,
    atom_id: core.Atom,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !bool {
    const object = try property_ops.expectObject(object_value);
    const target_value = object.proxyTarget() orelse return ordinaryHasValueProperty(ctx, output, global, object, atom_id, false, caller_function, caller_frame);
    const target = try property_ops.expectObject(target_value);
    const handler_value = object.proxyHandler() orelse return error.TypeError;
    const has_atom = try ctx.runtime.internAtom("has");
    defer ctx.runtime.atoms.free(has_atom);
    const trap = try getValueProperty(ctx, output, global, handler_value, has_atom, caller_function, caller_frame);
    defer trap.free(ctx.runtime);
    if (trap.isUndefined() or trap.isNull()) {
        return hasPropertyForWith(ctx, output, global, target_value, atom_id, caller_function, caller_frame);
    }
    const key_value = try proxyTrapKeyValue(ctx.runtime, atom_id);
    defer key_value.free(ctx.runtime);
    const result = try callValueOrBytecode(ctx, output, global, handler_value, trap, &.{ target_value, key_value }, caller_function, caller_frame);
    defer result.free(ctx.runtime);
    return try validateProxyHasResult(ctx, output, global, target, atom_id, valueTruthy(result), caller_function, caller_frame);
}

pub fn hasValueProperty(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    object: *core.Object,
    atom_id: core.Atom,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) HostError!bool {
    _ = receiver;
    const target_value = object.proxyTarget() orelse return ordinaryHasValueProperty(ctx, output, global, object, atom_id, false, caller_function, caller_frame);
    const target = try property_ops.expectObject(target_value);
    const handler_value = object.proxyHandler() orelse return error.TypeError;
    const has_atom = try ctx.runtime.internAtom("has");
    defer ctx.runtime.atoms.free(has_atom);
    const trap = try getValueProperty(ctx, output, global, handler_value, has_atom, caller_function, caller_frame);
    defer trap.free(ctx.runtime);
    if (trap.isUndefined() or trap.isNull()) {
        return hasValueProperty(ctx, output, global, target_value, target, atom_id, caller_function, caller_frame);
    }
    const key_value = try proxyTrapKeyValue(ctx.runtime, atom_id);
    defer key_value.free(ctx.runtime);
    const result = try callValueOrBytecode(ctx, output, global, handler_value, trap, &.{ target_value, key_value }, caller_function, caller_frame);
    defer result.free(ctx.runtime);
    return try validateProxyHasResult(ctx, output, global, target, atom_id, valueTruthy(result), caller_function, caller_frame);
}

pub fn ordinaryHasValueProperty(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    object: *core.Object,
    atom_id: core.Atom,
    has_builtin_object_proto: bool,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !bool {
    if (typedArrayCanonicalHas(ctx.runtime, object, atom_id)) |has| return has;
    if (indexedExoticHasProperty(ctx.runtime, object, atom_id)) return true;
    if (object.getOwnProperty(ctx.runtime, atom_id)) |desc| {
        desc.destroy(ctx.runtime);
        return true;
    }

    var current = object.getPrototype();
    while (current) |proto| : (current = proto.getPrototype()) {
        if (proto.proxyTarget() != null) {
            return try hasValueProperty(ctx, output, global, proto.value(), proto, atom_id, caller_function, caller_frame);
        }
        if (typedArrayCanonicalHas(ctx.runtime, proto, atom_id)) |has| return has;
        if (indexedExoticHasProperty(ctx.runtime, proto, atom_id)) return true;
        if (proto.getOwnProperty(ctx.runtime, atom_id)) |desc| {
            desc.destroy(ctx.runtime);
            return true;
        }
    }
    return has_builtin_object_proto;
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
    receiver: core.JSValue,
    object: *core.Object,
    atom_id: core.Atom,
) !void {
    if (!try deleteValueProperty(ctx, output, global, receiver, object, atom_id, null, null)) return error.TypeError;
}

pub fn deleteValueProperty(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    object: *core.Object,
    atom_id: core.Atom,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !bool {
    _ = receiver;
    const target_value = object.proxyTarget() orelse {
        return object.deleteProperty(ctx.runtime, atom_id);
    };
    const target = try property_ops.expectObject(target_value);
    const handler_value = object.proxyHandler() orelse return error.TypeError;
    const delete_atom = try ctx.runtime.internAtom("deleteProperty");
    defer ctx.runtime.atoms.free(delete_atom);
    const trap = try getValueProperty(ctx, output, global, handler_value, delete_atom, caller_function, caller_frame);
    defer trap.free(ctx.runtime);
    if (trap.isUndefined() or trap.isNull()) {
        return deleteValueProperty(ctx, output, global, target_value, target, atom_id, caller_function, caller_frame);
    }
    const key_value = try proxyTrapKeyValue(ctx.runtime, atom_id);
    defer key_value.free(ctx.runtime);
    const result = try callValueOrBytecode(ctx, output, global, handler_value, trap, &.{ target_value, key_value }, caller_function, caller_frame);
    defer result.free(ctx.runtime);
    if (!valueTruthy(result)) return false;
    // js_proxy_delete_property (quickjs.c:51157): the target desc is read via
    // JS_GetOwnPropertyInternal (exotic — a nested-proxy target fires its own
    // gopd trap); a non-configurable desc throws, then extensibility is
    // consulted via JS_IsExtensible (exotic — the target's isExtensible trap
    // DOES fire here, unlike js_proxy_has).
    if (try proxyAwareOwnPropertyDescriptor(ctx, output, global, target, atom_id, caller_function, caller_frame)) |desc| {
        defer desc.destroy(ctx.runtime);
        if (desc.configurable == false) return error.TypeError;
        if (!try proxyAwareIsExtensible(ctx, output, global, target, caller_function, caller_frame)) return error.TypeError;
    }
    return true;
}

pub fn defineValueProperty(rt: *core.JSRuntime, object: *core.Object, name: []const u8, value: core.JSValue) !void {
    const key = try rt.internAtom(name);
    defer rt.atoms.free(key);
    try object.defineOwnProperty(rt, key, core.Descriptor.data(value, true, true, true));
}

pub fn defineFunctionNameProperty(rt: *core.JSRuntime, object: *core.Object, value: core.JSValue) !void {
    if (objectHasNonEmptyName(rt, object)) return;
    const key = try rt.internAtom("name");
    defer rt.atoms.free(key);
    try object.defineOwnProperty(rt, key, core.Descriptor.data(value, false, false, true));
}

pub fn objectHasNonEmptyName(rt: *core.JSRuntime, object: *core.Object) bool {
    const existing = object.getOwnProperty(rt, core.atom.ids.name) orelse return false;
    defer existing.destroy(rt);
    if (existing.kind != .data or !existing.value.isString()) return false;
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.memory.allocator);
    value_ops.appendRawString(rt, &bytes, existing.value) catch return false;
    return bytes.items.len != 0;
}

pub fn throwNullishPropertyTypeError(ctx: *core.JSContext, global: *core.Object, value: core.JSValue, atom_id: core.Atom) !core.JSValue {
    const property_name = try atomPropertyName(ctx.runtime, atom_id);
    defer ctx.runtime.memory.allocator.free(property_name);
    const base = if (value.isNull()) "null" else "undefined";
    const message = try std.fmt.allocPrint(
        ctx.runtime.memory.allocator,
        "cannot read property '{s}' of {s}",
        .{ property_name, base },
    );
    defer ctx.runtime.memory.allocator.free(message);
    return throwTypeErrorMessage(ctx, global, message);
}

pub fn throwNullishComputedPropertyTypeError(ctx: *core.JSContext, global: *core.Object, value: core.JSValue, key: core.JSValue) !core.JSValue {
    var property_name = std.ArrayList(u8).empty;
    defer property_name.deinit(ctx.runtime.memory.allocator);
    try value_ops.appendValueString(ctx.runtime, &property_name, key);
    const base = if (value.isNull()) "null" else "undefined";
    const message = try std.fmt.allocPrint(
        ctx.runtime.memory.allocator,
        "cannot read property '{s}' of {s}",
        .{ property_name.items, base },
    );
    defer ctx.runtime.memory.allocator.free(message);
    return throwTypeErrorMessage(ctx, global, message);
}

pub fn atomPropertyName(rt: *core.JSRuntime, atom_id: core.Atom) ![]const u8 {
    if (core.atom.isTaggedInt(atom_id)) {
        return try std.fmt.allocPrint(rt.memory.allocator, "{d}", .{core.atom.atomToUInt32(atom_id)});
    }
    const name = rt.atoms.name(atom_id) orelse "";
    return try rt.memory.allocator.dupe(u8, name);
}

// --- Combined from class.zig ---

pub noinline fn getSuper(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    frame: *frame_mod.Frame,
) !void {
    const source_from_stack = stack.len() != 0;
    const source = if (source_from_stack) try stack.pop() else frame.current_function.dup();
    defer source.free(ctx.runtime);
    const function_object = property_ops.expectObject(source) catch {
        try stack.pushOwned(core.JSValue.undefinedValue());
        return;
    };
    if (function_object.functionSuperConstructor()) |super_constructor| {
        const fb_value = function_object.functionBytecode();
        const is_arrow = if (fb_value) |value|
            if (functionBytecodeFromValue(value)) |fb| fb.flags.is_arrow_function else false
        else
            false;
        if (is_arrow) {
            try stack.push(super_constructor);
        } else if (function_object.getPrototype()) |prototype| {
            try stack.push(prototype.value());
        } else {
            try stack.pushOwned(core.JSValue.nullValue());
        }
        return;
    }
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

pub noinline fn getSuperValue(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
) !Step {
    const prop_value = try stack.pop();
    defer prop_value.free(ctx.runtime);
    const obj = try stack.pop();
    defer obj.free(ctx.runtime);
    const receiver = try stack.pop();
    defer receiver.free(ctx.runtime);
    if (slot_ops.adapterValueIsUninitialized(receiver)) {
        if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, error.ReferenceError)) return .continue_loop;
        return error.ReferenceError;
    }
    const atom_id = toPropertyKeyAtom(ctx, output, global, prop_value, function, frame) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    defer ctx.runtime.atoms.free(atom_id);
    if (obj.isUndefined() or obj.isNull()) {
        if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, error.TypeError)) return .continue_loop;
        return error.TypeError;
    }

    var prototype = try property_ops.expectObject(obj);
    if (property_ops.expectObject(frame.current_function)) |function_object| {
        if (function_object.functionSuperConstructor()) |super_constructor| {
            if (sameObjectIdentity(super_constructor, obj)) {
                if (function_object.functionHomeObject()) |home_object| {
                    prototype = home_object.getPrototype() orelse {
                        try stack.pushOwned(core.JSValue.undefinedValue());
                        return .done;
                    };
                }
            }
        }
    } else |_| {}
    const value = getSuperPropertyValue(ctx, output, global, receiver, prototype, atom_id, function, frame) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    defer value.free(ctx.runtime);
    try stack.push(value);
    return .done;
}

pub noinline fn putSuperValue(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
) !Step {
    const value = try stack.pop();
    defer value.free(ctx.runtime);
    const prop_value = try stack.pop();
    defer prop_value.free(ctx.runtime);
    const obj = try stack.pop();
    defer obj.free(ctx.runtime);
    const receiver = try stack.pop();
    defer receiver.free(ctx.runtime);
    if (slot_ops.adapterValueIsUninitialized(receiver)) {
        if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, error.ReferenceError)) return .continue_loop;
        return error.ReferenceError;
    }
    if (obj.isUndefined() or obj.isNull()) {
        if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, error.TypeError)) return .continue_loop;
        return error.TypeError;
    }
    const atom_id = toPropertyKeyAtom(ctx, output, global, prop_value, function, frame) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    defer ctx.runtime.atoms.free(atom_id);
    var prototype = try property_ops.expectObject(obj);
    if (property_ops.expectObject(frame.current_function)) |function_object| {
        if (function_object.functionSuperConstructor()) |super_constructor| {
            if (sameObjectIdentity(super_constructor, obj)) {
                if (function_object.functionHomeObject()) |home_object| {
                    prototype = home_object.getPrototype() orelse {
                        if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, error.TypeError)) return .continue_loop;
                        return error.TypeError;
                    };
                }
            }
        }
    } else |_| {}
    setSuperPropertyValue(ctx, output, global, receiver, prototype, atom_id, value, function, frame) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    return .done;
}

pub noinline fn setHomeObject(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
) !void {
    const func_value = try stackValueFromTop(stack, 0);
    defer func_value.free(ctx.runtime);
    const home_value = try stackValueFromTop(stack, 1);
    defer home_value.free(ctx.runtime);
    if (func_value.isObject() and home_value.isObject()) {
        const func_object = try property_ops.expectObject(func_value);
        var can_set_home_object = true;
        if (func_object.functionBytecode()) |function_bytecode_value| {
            if (functionBytecodeFromValue(function_bytecode_value)) |fb| {
                can_set_home_object = !fb.flags.is_class_constructor;
            }
        }
        if (can_set_home_object) {
            try func_object.setFunctionHomeObject(ctx.runtime, try property_ops.expectObject(home_value));
        }
    }
}

pub fn checkBrand(ctx: *core.JSContext, stack: *stack_mod.Stack) !void {
    if (stack.len() < 2) return error.StackUnderflow;
    const obj = stack.values[stack.len() - 2].dup();
    defer obj.free(ctx.runtime);
    const func = stack.values[stack.len() - 1].dup();
    defer func.free(ctx.runtime);
    if (!try hasPrivateBrand(ctx.runtime, obj, func)) return error.TypeError;
}

pub noinline fn checkBrandVm(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    stack: *stack_mod.Stack,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    global: *core.Object,
) !Step {
    checkBrand(ctx, stack) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    return .done;
}

pub fn addBrand(ctx: *core.JSContext, stack: *stack_mod.Stack) !void {
    const home_value = try stack.pop();
    var rooted_home = home_value;
    defer home_value.free(ctx.runtime);
    const obj = try stack.pop();
    var rooted_obj = obj;
    defer obj.free(ctx.runtime);
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &rooted_home },
        .{ .value = &rooted_obj },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = ctx.runtime.active_value_roots,
        .values = &root_values,
    };
    ctx.runtime.active_value_roots = &root_frame;
    defer ctx.runtime.active_value_roots = root_frame.previous;

    const home = try property_ops.expectObject(rooted_home);
    const brand_atom = try ensureHomeObjectBrand(ctx.runtime, home);
    if (rooted_obj.isObject()) {
        const object = try property_ops.expectObject(rooted_obj);
        if (object.hasOwnProperty(brand_atom)) return error.TypeError;
        // NO-ALIGN(qjs): JS_AddBrand (quickjs.c:8464) raw-adds the instance
        // brand ignoring extensibility; test262's
        // `nonextensible-applies-to-private` feature mandates the TypeError,
        // so zjs keeps the NotExtensible -> TypeError behavior.
        object.defineOwnProperty(ctx.runtime, brand_atom, core.Descriptor.data(core.JSValue.undefinedValue(), true, true, true)) catch |err| switch (err) {
            error.IncompatibleDescriptor, error.NotExtensible, error.ReadOnly => return error.TypeError,
            else => return err,
        };
    }
}

pub noinline fn addBrandVm(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    stack: *stack_mod.Stack,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    global: *core.Object,
) !Step {
    addBrand(ctx, stack) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    return .done;
}

pub fn privateIn(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
) !void {
    const key = try stack.pop();
    defer key.free(ctx.runtime);
    const obj = try stack.pop();
    defer obj.free(ctx.runtime);
    if (!obj.isObject()) {
        _ = try throwTypeErrorMessage(ctx, global, "invalid 'in' operand");
        return;
    }
    const found = if (key.isObject())
        try hasPrivateBrand(ctx.runtime, obj, key)
    else blk: {
        const atom_id = try toPropertyKeyAtom(ctx, output, global, key, function, frame);
        defer ctx.runtime.atoms.free(atom_id);
        const object = try property_ops.expectObject(obj);
        break :blk object.hasOwnProperty(atom_id);
    };
    try stack.pushOwned(core.JSValue.boolean(found));
}

pub noinline fn privateInVm(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
) !Step {
    privateIn(ctx, output, global, stack, function, frame) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    return .done;
}

pub noinline fn defineClass(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    is_computed_name: bool,
) !Step {
    const atom_id = readInt(u32, function.code[frame.pc..][0..4]);
    const flags = function.code[frame.pc + 4];
    frame.pc += 5;
    var ctor_source = try stack.pop();
    defer ctor_source.free(ctx.runtime);
    var parent_value = try stack.pop();
    defer parent_value.free(ctx.runtime);
    var saved_class_binding = core.JSValue.undefinedValue();
    var saved_class_binding_active = false;
    defer if (saved_class_binding_active) saved_class_binding.free(ctx.runtime);
    var superclass_value = core.JSValue.undefinedValue();
    var superclass_value_active = false;
    defer if (superclass_value_active) superclass_value.free(ctx.runtime);
    var ctor = core.JSValue.undefinedValue();
    defer ctor.free(ctx.runtime);
    var computed_key = core.JSValue.undefinedValue();
    defer computed_key.free(ctx.runtime);
    var name_value = core.JSValue.undefinedValue();
    defer name_value.free(ctx.runtime);
    var superclass_proto = core.JSValue.undefinedValue();
    defer superclass_proto.free(ctx.runtime);
    var proto_value = core.JSValue.undefinedValue();
    defer proto_value.free(ctx.runtime);
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &ctor_source },
        .{ .value = &parent_value },
        .{ .value = &saved_class_binding },
        .{ .value = &superclass_value },
        .{ .value = &ctor },
        .{ .value = &computed_key },
        .{ .value = &name_value },
        .{ .value = &superclass_proto },
        .{ .value = &proto_value },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = ctx.runtime.active_value_roots,
        .values = &root_values,
    };
    ctx.runtime.active_value_roots = &root_frame;
    defer ctx.runtime.active_value_roots = root_frame.previous;

    if ((flags & 1) != 0) {
        superclass_value = parent_value;
        superclass_value_active = true;
        parent_value = core.JSValue.undefinedValue();
        if (superclass_value.isUndefined() and stack.len() > 0) {
            saved_class_binding = superclass_value;
            saved_class_binding_active = true;
            superclass_value = try stack.pop();
        }
        if (!(superclass_value.isObject() or superclass_value.isNull())) {
            if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, error.TypeError)) return .continue_loop;
            return error.TypeError;
        }
    }
    ctor = try createBytecodeFunctionObject(ctx, frame, function, global, ctor_source, atom_id, op.define_class, false);
    const ctor_object = try property_ops.expectObject(ctor);
    if (is_computed_name) {
        computed_key = try stackValueFromTop(stack, 0);
        const name_atom = toPropertyKeyAtom(ctx, output, global, computed_key, function, frame) catch |err| {
            if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
            return err;
        };
        defer ctx.runtime.atoms.free(name_atom);
        name_value = try functionNameValueFromAtom(ctx.runtime, name_atom, null);
        try defineFunctionNameProperty(ctx.runtime, ctor_object, name_value);
        name_value.free(ctx.runtime);
        name_value = core.JSValue.undefinedValue();
        computed_key.free(ctx.runtime);
        computed_key = core.JSValue.undefinedValue();
    }
    var proto_parent: ?*core.Object = objectPrototypeFromGlobal(ctx.runtime, global);
    if (superclass_value_active) {
        if (superclass_value.isObject()) {
            if (!(try isConstructorLike(ctx, superclass_value))) {
                if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, error.TypeError)) return .continue_loop;
                return error.TypeError;
            }
            const superclass_object = try property_ops.expectObject(superclass_value);
            try ctor_object.setPrototype(ctx.runtime, superclass_object);
            try ctor_object.setOptionalValueSlot(ctx.runtime, try ctor_object.functionSuperConstructorSlot(ctx.runtime), superclass_value.dup());
            superclass_proto = getValueProperty(ctx, output, global, superclass_value, core.atom.ids.prototype, function, frame) catch |err| {
                if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
                return err;
            };
            if (superclass_proto.isObject()) {
                proto_parent = try property_ops.expectObject(superclass_proto);
            } else if (!superclass_proto.isNull()) {
                if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, error.TypeError)) return .continue_loop;
                return error.TypeError;
            }
        } else {
            proto_parent = null;
        }
    }
    const proto = try core.Object.create(ctx.runtime, core.class.ids.object, proto_parent);
    proto_value = proto.value();
    try proto.defineOwnProperty(ctx.runtime, core.atom.ids.constructor, core.Descriptor.data(ctor_object.value(), true, false, true));
    try ctor_object.defineOwnProperty(ctx.runtime, core.atom.ids.prototype, core.Descriptor.data(proto_value, false, false, false));
    if (functionBytecodeFromValue(ctor_source)) |ctor_fb| {
        if (ctor_fb.privateBoundNames().len != 0 or ctor_fb.classPrivateNames().len != 0) {
            call_runtime.clearPrivateNameRemap(ctx.runtime, proto);
            try installLexicalPrivateNameRemap(ctx.runtime, proto, frame, ctor_fb.privateBoundNames());
            try call_runtime.installFreshPrivateNameRemap(ctx.runtime, proto, ctor_fb.classPrivateNames());
            try call_runtime.copyPrivateNameRemap(ctx.runtime, ctor_object, proto);
        }
    }
    try ctor_object.setFunctionHomeObject(ctx.runtime, proto);
    if (ctor_object.functionClassFieldsInit()) |init_value| {
        if (objectFromValue(init_value)) |init_object| {
            try init_object.setFunctionHomeObject(ctx.runtime, proto);
        }
    }
    if (saved_class_binding_active) {
        try stack.push(saved_class_binding);
    }
    try stack.push(ctor);
    try stack.push(proto_value);
    return .done;
}

pub noinline fn defineMethod(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
) !Step {
    const atom_id = readInt(u32, function.code[frame.pc..][0..4]);
    frame.pc += 4;
    const flags = function.code[frame.pc];
    frame.pc += 1;
    defineObjectMethod(ctx.runtime, stack, atom_id, flags, frame) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    return .done;
}

pub noinline fn defineMethodComputed(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
) !Step {
    const flags = function.code[frame.pc];
    frame.pc += 1;
    const value = try stack.pop();
    defer value.free(ctx.runtime);
    const key_value = try stack.pop();
    defer key_value.free(ctx.runtime);
    const atom_id = toPropertyKeyAtom(ctx, output, global, key_value, function, frame) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    defer ctx.runtime.atoms.free(atom_id);
    defineObjectMethodValue(ctx.runtime, stack, atom_id, value, flags, frame) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    return .done;
}

fn defineObjectMethod(
    rt: *core.JSRuntime,
    stack: *stack_mod.Stack,
    atom_id: core.Atom,
    flags: u8,
    caller_frame: ?*frame_mod.Frame,
) !void {
    if (stack.len() < 2) {
        const maybe_object = stack.peek() orelse return error.StackUnderflow;
        defer maybe_object.free(rt);
        _ = property_ops.expectObject(maybe_object) catch return error.StackUnderflow;
        return;
    }
    const value = try stack.pop();
    defer value.free(rt);
    try defineObjectMethodValue(rt, stack, atom_id, value, flags, caller_frame);
}

fn defineObjectMethodValue(
    rt: *core.JSRuntime,
    stack: *stack_mod.Stack,
    atom_id: core.Atom,
    value: core.JSValue,
    flags: u8,
    caller_frame: ?*frame_mod.Frame,
) !void {
    const obj = stack.peek() orelse return error.StackUnderflow;
    var rooted_obj = obj;
    defer obj.free(rt);
    var rooted_value = value;
    var name_value = core.JSValue.undefinedValue();
    defer name_value.free(rt);
    var getter = core.JSValue.undefinedValue();
    defer getter.free(rt);
    var setter = core.JSValue.undefinedValue();
    defer setter.free(rt);
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &rooted_obj },
        .{ .value = &rooted_value },
        .{ .value = &name_value },
        .{ .value = &getter },
        .{ .value = &setter },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    const object = try property_ops.expectObject(obj);
    const effective_atom = remapPrivateAtomFromObject(rt, object, atom_id);
    if (rooted_value.isObject()) {
        const function_object = try property_ops.expectObject(rooted_value);
        try function_object.setFunctionHomeObject(rt, object);
        if (function_object.functionBytecode()) |function_bytecode_value| {
            if (functionBytecodeFromValue(function_bytecode_value)) |fb| {
                try installLexicalPrivateNameRemap(rt, object, caller_frame, fb.privateBoundNames());
            }
        }
        const prefix: ?[]const u8 = switch (flags & 3) {
            1 => "get",
            2 => "set",
            else => null,
        };
        name_value = try functionNameValueFromAtom(rt, effective_atom, prefix);
        try defineFunctionNameProperty(rt, function_object, name_value);
        name_value.free(rt);
        name_value = core.JSValue.undefinedValue();
    }
    const enumerable = (flags & 4) != 0;
    if ((flags & 3) == 1 or (flags & 3) == 2) {
        if (object.getOwnProperty(rt, effective_atom)) |existing| {
            defer existing.destroy(rt);
            if (existing.kind == .accessor) {
                getter = existing.getter.dup();
                setter = existing.setter.dup();
            }
        }
        const desc = if ((flags & 3) == 1)
            core.Descriptor.accessor(rooted_value, setter, enumerable, true)
        else
            core.Descriptor.accessor(getter, rooted_value, enumerable, true);
        object.defineOwnProperty(rt, effective_atom, desc) catch |err| switch (err) {
            error.IncompatibleDescriptor, error.NotExtensible, error.ReadOnly => return error.TypeError,
            else => return err,
        };
        getter.free(rt);
        getter = core.JSValue.undefinedValue();
        setter.free(rt);
        setter = core.JSValue.undefinedValue();
        return;
    }
    const writable = rt.atoms.kind(atom_id) != .private;
    object.defineOwnProperty(rt, effective_atom, core.Descriptor.data(rooted_value, writable, enumerable, true)) catch |err| switch (err) {
        error.IncompatibleDescriptor, error.NotExtensible, error.ReadOnly => return error.TypeError,
        else => return err,
    };
}

fn stackValueFromTop(stack: *const stack_mod.Stack, offset: u8) !core.JSValue {
    const index_from_top: usize = offset;
    if (index_from_top >= stack.len()) return error.StackUnderflow;
    return stack.values[stack.len() - 1 - index_from_top].dup();
}

fn ensureHomeObjectBrand(rt: *core.JSRuntime, home: *core.Object) !core.Atom {
    if (home.getOwnProperty(rt, core.atom.ids.Private_brand)) |desc| {
        defer desc.destroy(rt);
        if (desc.value.asSymbolAtom()) |brand_atom| return brand_atom;
        return error.TypeError;
    }
    const name = rt.atoms.name(core.atom.ids.Private_brand) orelse "<brand>";
    if (!home.isExtensible()) return error.NotExtensible;
    const brand_atom = try rt.atoms.newSymbol(name, .private);
    defer rt.atoms.free(brand_atom);
    try home.defineOwnProperty(rt, core.atom.ids.Private_brand, core.Descriptor.data(try rt.symbolValue(brand_atom), true, true, true));
    return brand_atom;
}

fn hasPrivateBrand(rt: *core.JSRuntime, obj: core.JSValue, func: core.JSValue) !bool {
    const object = try property_ops.expectObject(obj);
    const func_object = try property_ops.expectObject(func);
    const home = func_object.functionHomeObject() orelse return error.TypeError;
    const desc = home.getOwnProperty(rt, core.atom.ids.Private_brand) orelse return error.TypeError;
    defer desc.destroy(rt);
    const brand_atom = desc.value.asSymbolAtom() orelse return error.TypeError;
    return object.hasOwnProperty(brand_atom);
}

fn readInt(comptime T: type, bytes: []const u8) T {
    return std.mem.readInt(T, bytes[0..@sizeOf(T)], .little);
}

test "private brand atom is released with home object" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const home = try core.Object.create(rt, core.class.ids.object, null);
    const brand_atom = try ensureHomeObjectBrand(rt, home);
    try std.testing.expectEqual(core.atom.AtomKind.private, rt.atoms.kind(brand_atom).?);

    home.value().free(rt);
    try std.testing.expect(rt.atoms.name(brand_atom) == null);
}

test "private brand creation does not allocate atom for non-extensible home object" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const home = try core.Object.create(rt, core.class.ids.object, null);
    defer home.value().free(rt);
    home.preventExtensions();
    const before_entries = rt.atoms.entries.len;

    try std.testing.expectError(error.NotExtensible, ensureHomeObjectBrand(rt, home));
    try std.testing.expectEqual(before_entries, rt.atoms.entries.len);
}

// --- Combined from proxy_ops.zig ---

pub fn proxySetTrapForErrorStackSetter(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver_value: core.JSValue,
    receiver: *core.Object,
    stack_key: core.Atom,
    value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !bool {
    const target_value = receiver.proxyTarget() orelse return false;
    const handler_value = receiver.proxyHandler() orelse return error.TypeError;
    const set_atom = try ctx.runtime.internAtom("set");
    defer ctx.runtime.atoms.free(set_atom);
    const trap = try getValueProperty(ctx, output, global, handler_value, set_atom, caller_function, caller_frame);
    defer trap.free(ctx.runtime);
    if (trap.isUndefined() or trap.isNull()) return false;
    if (!isCallableValue(trap)) return error.TypeError;

    const key_value = try proxyTrapKeyValue(ctx.runtime, stack_key);
    defer key_value.free(ctx.runtime);
    const result = try callValueOrBytecode(ctx, output, global, handler_value, trap, &.{ target_value, key_value, value, receiver_value }, caller_function, caller_frame);
    defer result.free(ctx.runtime);
    if (!valueTruthy(result)) return error.TypeError;
    const target = try property_ops.expectObject(target_value);
    try validateProxySetResult(ctx, output, global, target, stack_key, value, caller_function, caller_frame);
    return true;
}

pub fn isRevokedProxy(object: *core.Object) bool {
    return object.isProxy() and object.proxyHandler() == null;
}

pub fn proxyCreateDataPropertyOrThrow(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver_value: core.JSValue,
    proxy: *core.Object,
    atom_id: core.Atom,
    value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !void {
    const target_value = proxy.proxyTarget() orelse return error.TypeError;
    const target = property_ops.expectObject(target_value) catch return error.TypeError;
    const handler_value = proxy.proxyHandler() orelse return error.TypeError;
    const trap_atom = try ctx.runtime.internAtom("defineProperty");
    defer ctx.runtime.atoms.free(trap_atom);
    const trap = try getValueProperty(ctx, output, global, handler_value, trap_atom, caller_function, caller_frame);
    defer trap.free(ctx.runtime);
    if (trap.isUndefined() or trap.isNull()) {
        target.defineOwnProperty(ctx.runtime, atom_id, core.Descriptor.data(value, true, true, true)) catch |err| switch (err) {
            error.IncompatibleDescriptor, error.NotExtensible, error.ReadOnly => return error.TypeError,
            else => return err,
        };
        return;
    }
    if (!isCallableValue(trap)) return error.TypeError;

    const key_value = try proxyTrapKeyValue(ctx.runtime, atom_id);
    defer key_value.free(ctx.runtime);
    const desc_object = try core.Object.create(ctx.runtime, core.class.ids.object, objectPrototypeFromGlobal(ctx.runtime, global));
    const desc_value = desc_object.value();
    defer desc_value.free(ctx.runtime);
    try defineValueProperty(ctx.runtime, desc_object, "value", value);
    try defineValueProperty(ctx.runtime, desc_object, "writable", core.JSValue.boolean(true));
    try defineValueProperty(ctx.runtime, desc_object, "enumerable", core.JSValue.boolean(true));
    try defineValueProperty(ctx.runtime, desc_object, "configurable", core.JSValue.boolean(true));
    const result = try callValueOrBytecode(ctx, output, global, handler_value, trap, &.{ target_value, key_value, desc_value }, caller_function, caller_frame);
    defer result.free(ctx.runtime);
    if (!value_ops.isTruthy(result)) return error.TypeError;
    _ = receiver_value;
}

pub fn validateProxyOwnKeysResult(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    source: *core.Object,
    target_value: core.JSValue,
    result_keys: []const core.Atom,
) HostError!void {
    const rt = ctx.runtime;
    const target = try property_ops.expectObject(target_value);
    // js_proxy_get_own_property_names (quickjs.c:51219) invariant walk:
    // JS_IsExtensible on the target FIRST (exotic — a nested-proxy target
    // fires its isExtensible trap), then a revoked re-check (the ownKeys trap
    // may have revoked its own proxy, quickjs.c:51285), then the target's own
    // keys via JS_GetOwnPropertyNamesInternal (exotic ownKeys) and a per-key
    // revoked re-check (quickjs.c:51293) + JS_GetOwnPropertyInternal (exotic
    // gopd — inner invariant violations surface as TypeErrors here).
    const target_extensible = try proxyAwareIsExtensible(ctx, output, global, target, null, null);
    if (source.proxyHandler() == null) return error.TypeError; // revoked proxy
    const target_keys = try objectRestOwnKeys(ctx, output, global, target);
    defer core.Object.freeKeys(rt, target_keys);

    // Mirrors qjs's tab[idx].is_enumerable found-marking: a trap-result key on
    // a non-extensible target must correspond to a target key whose gopd walk
    // actually found a descriptor.
    const found = try rt.memory.allocator.alloc(bool, result_keys.len);
    defer rt.memory.allocator.free(found);
    @memset(found, false);

    for (target_keys) |target_key| {
        if (source.proxyHandler() == null) return error.TypeError; // revoked proxy
        const desc = (try proxyAwareOwnPropertyDescriptor(ctx, output, global, target, target_key, null, null)) orelse continue;
        defer desc.destroy(rt);
        if (desc.configurable == false or !target_extensible) {
            const idx = for (result_keys, 0..) |result_key, i| {
                if (result_key == target_key) break i;
            } else return error.TypeError;
            if (!target_extensible) found[idx] = true;
        }
    }
    if (!target_extensible) {
        for (found) |marked| {
            if (!marked) return error.TypeError;
        }
    }
}

pub fn proxyAwareOwnPropertyDescriptor(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    source: *core.Object,
    key: core.Atom,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.Descriptor {
    if (source.proxyTarget() == null) {
        if (try typedArrayCanonicalOwnDescriptor(ctx.runtime, source, key)) |desc| return desc;
        if (source.moduleNamespaceOwnBindingValue(key)) |binding_value| {
            defer binding_value.free(ctx.runtime);
            if (binding_value.isUninitialized()) return error.ReferenceError;
        }
        return source.getOwnProperty(ctx.runtime, key);
    }
    const target_value = source.proxyTarget() orelse return error.TypeError;
    const target = try property_ops.expectObject(target_value);
    const handler_value = source.proxyHandler() orelse return error.TypeError;
    const trap_atom = try ctx.runtime.internAtom("getOwnPropertyDescriptor");
    defer ctx.runtime.atoms.free(trap_atom);
    const trap = try getValueProperty(ctx, output, global, handler_value, trap_atom, caller_function, caller_frame);
    defer trap.free(ctx.runtime);
    if (trap.isUndefined() or trap.isNull()) {
        return try proxyAwareOwnPropertyDescriptor(ctx, output, global, target, key, caller_function, caller_frame);
    }
    if (!isCallableValue(trap)) return error.TypeError;
    const key_value = try proxyTrapKeyValue(ctx.runtime, key);
    defer key_value.free(ctx.runtime);
    const desc_value = try callValueOrBytecode(ctx, output, global, handler_value, trap, &.{ target_value, key_value }, caller_function, caller_frame);
    defer desc_value.free(ctx.runtime);
    const target_desc = try proxyAwareOwnPropertyDescriptor(ctx, output, global, target, key, caller_function, caller_frame);
    defer if (target_desc) |item| item.destroy(ctx.runtime);
    const target_extensible = try proxyAwareIsExtensible(ctx, output, global, target, caller_function, caller_frame);
    if (desc_value.isUndefined()) {
        if (target_desc) |item| {
            if (item.configurable == false or !target_extensible) return error.TypeError;
        }
        return null;
    }
    const desc_object = property_ops.expectObject(desc_value) catch return error.TypeError;
    var result_desc = try qjsDescriptorFromObject(ctx, output, global, desc_value, desc_object, target, key, caller_function, caller_frame);
    errdefer result_desc.destroy(ctx.runtime);
    var complete_desc = try completeProxyDescriptor(ctx.runtime, result_desc);
    errdefer complete_desc.destroy(ctx.runtime);
    if (!try isCompatibleProxyDescriptor(target_extensible, target_desc, complete_desc)) return error.TypeError;
    if (complete_desc.configurable == false) {
        if (target_desc) |item| {
            if (item.configurable != false) return error.TypeError;
            if (complete_desc.kind == .data and complete_desc.writable == false and item.kind == .data and item.writable == true) return error.TypeError;
        } else {
            return error.TypeError;
        }
    }
    result_desc.destroy(ctx.runtime);
    return complete_desc;
}

/// Existence-only sibling of `proxyAwareOwnPropertyDescriptor`. For a
/// NON-proxy source it mirrors qjs `JS_GetOwnPropertyInternal(ctx, NULL, ...)`
/// (quickjs.c:8854 desc==NULL mode): typed-array canonical-index existence
/// (no element materialization), the module-namespace TDZ throw, then the
/// complete kind-cascade probe -- all with NO descriptor allocation and NO
/// `JS_DupValue`. For a Proxy it MUST keep the full descriptor path so the
/// `getOwnPropertyDescriptor` trap fires (spec / qjs `js_proxy_get_own_property`);
/// it then reports presence as `desc != null`. This is the
/// `JS_GetOwnPropertyInternal(NULL)` used by `js_object_hasOwnProperty`
/// (quickjs.c:40536).
pub fn proxyAwareExistsOwnProperty(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    source: *core.Object,
    key: core.Atom,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !bool {
    if (source.proxyTarget() == null) {
        if (try typedArrayCanonicalIndexExists(ctx.runtime, source, key)) |present| return present;
        return source.existsOwnProperty(ctx.runtime, key);
    }
    // Proxy: keep the full-descriptor path so the trap still fires.
    const desc = try proxyAwareOwnPropertyDescriptor(ctx, output, global, source, key, caller_function, caller_frame) orelse return false;
    desc.destroy(ctx.runtime);
    return true;
}

pub fn proxyAwareIsExtensible(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    object: *core.Object,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !bool {
    if (object.proxyTarget() == null) return object.isExtensible();
    const target_value = object.proxyTarget() orelse return error.TypeError;
    const target = try property_ops.expectObject(target_value);
    const handler_value = object.proxyHandler() orelse return error.TypeError;
    const trap_atom = try ctx.runtime.internAtom("isExtensible");
    defer ctx.runtime.atoms.free(trap_atom);
    const trap = try getValueProperty(ctx, output, global, handler_value, trap_atom, caller_function, caller_frame);
    defer trap.free(ctx.runtime);
    if (trap.isUndefined() or trap.isNull()) return try proxyAwareIsExtensible(ctx, output, global, target, caller_function, caller_frame);
    if (!isCallableValue(trap)) return error.TypeError;
    const result = try callValueOrBytecode(ctx, output, global, handler_value, trap, &.{target_value}, caller_function, caller_frame);
    defer result.free(ctx.runtime);
    const extensible = valueTruthy(result);
    if (extensible != try proxyAwareIsExtensible(ctx, output, global, target, caller_function, caller_frame)) return error.TypeError;
    return extensible;
}

pub fn proxyAwarePreventExtensions(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    object: *core.Object,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !bool {
    const target_value = object.proxyTarget() orelse {
        object.preventExtensions();
        return true;
    };
    const target = try property_ops.expectObject(target_value);
    const handler_value = object.proxyHandler() orelse return error.TypeError;
    const trap_atom = try ctx.runtime.internAtom("preventExtensions");
    defer ctx.runtime.atoms.free(trap_atom);
    const trap = try getValueProperty(ctx, output, global, handler_value, trap_atom, caller_function, caller_frame);
    defer trap.free(ctx.runtime);
    if (trap.isUndefined() or trap.isNull()) return proxyAwarePreventExtensions(ctx, output, global, target, caller_function, caller_frame);
    if (!isCallableValue(trap)) return error.TypeError;
    const result = try callValueOrBytecode(ctx, output, global, handler_value, trap, &.{target_value}, caller_function, caller_frame);
    defer result.free(ctx.runtime);
    if (!valueTruthy(result)) return false;
    if (try proxyAwareIsExtensible(ctx, output, global, target, caller_function, caller_frame)) return error.TypeError;
    return true;
}

pub fn proxyAwareSetPrototypeOf(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    object: *core.Object,
    prototype: ?*core.Object,
    caller_function: ?*const bytecode.Bytecode,
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
    const handler_value = object.proxyHandler() orelse return error.TypeError;
    const trap_atom = try ctx.runtime.internAtom("setPrototypeOf");
    defer ctx.runtime.atoms.free(trap_atom);
    const trap = try getValueProperty(ctx, output, global, handler_value, trap_atom, caller_function, caller_frame);
    defer trap.free(ctx.runtime);
    const proto_value = if (prototype) |proto| proto.value() else core.JSValue.nullValue();
    if (trap.isUndefined() or trap.isNull()) return proxyAwareSetPrototypeOf(ctx, output, global, target, prototype, caller_function, caller_frame);
    if (!isCallableValue(trap)) return error.TypeError;
    const result = try callValueOrBytecode(ctx, output, global, handler_value, trap, &.{ target_value, proto_value }, caller_function, caller_frame);
    defer result.free(ctx.runtime);
    if (!valueTruthy(result)) return false;
    if (!try proxyAwareIsExtensible(ctx, output, global, target, caller_function, caller_frame)) {
        const target_proto = try qjsObjectGetPrototypeOfStep(ctx, output, global, target, caller_function, caller_frame);
        if (target_proto != prototype) return error.TypeError;
    }
    return true;
}

pub fn completeProxyDescriptor(rt: *core.JSRuntime, desc: core.Descriptor) !core.Descriptor {
    _ = rt;
    return switch (desc.kind) {
        .generic, .data => core.Descriptor.data(
            if (desc.value_present) desc.value.dup() else core.JSValue.undefinedValue(),
            desc.writable orelse false,
            desc.enumerable orelse false,
            desc.configurable orelse false,
        ),
        .accessor => core.Descriptor.accessor(
            if (desc.getter_present) desc.getter.dup() else core.JSValue.undefinedValue(),
            if (desc.setter_present) desc.setter.dup() else core.JSValue.undefinedValue(),
            desc.enumerable orelse false,
            desc.configurable orelse false,
        ),
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

pub fn proxyTargetIsCallable(value: core.JSValue) bool {
    const object = objectFromValue(value) orelse return false;
    const target = object.proxyTarget() orelse return false;
    return target.isFunctionBytecode() or functionObjectFromValue(target) != null or callableObjectFromValue(target) != null or proxyTargetIsCallable(target);
}

pub fn proxyTargetIsConstructor(ctx: *core.JSContext, value: core.JSValue) error{OutOfMemory}!bool {
    const object = objectFromValue(value) orelse return false;
    const target = object.proxyTarget() orelse return false;
    return isConstructorLike(ctx, target);
}

pub fn callProxyApply(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    proxy_value: core.JSValue,
    proxy: *core.Object,
    this_value: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    _ = proxy_value;
    // Materialize the revoked-proxy TypeError here so it carries the
    // current realm's constructor (the caller frame's `global`), not the
    // realm where the error eventually surfaces.
    const target_value = proxy.proxyTarget() orelse return throwTypeErrorMessage(ctx, global, "revoked proxy");
    const handler_value = proxy.proxyHandler() orelse return throwTypeErrorMessage(ctx, global, "revoked proxy");
    const apply_atom = try ctx.runtime.internAtom("apply");
    defer ctx.runtime.atoms.free(apply_atom);
    const trap = try getValueProperty(ctx, output, global, handler_value, apply_atom, caller_function, caller_frame);
    defer trap.free(ctx.runtime);
    if (trap.isUndefined() or trap.isNull()) {
        return callValueOrBytecode(ctx, output, global, this_value, target_value, args, caller_function, caller_frame);
    }
    if (!isCallableValue(trap)) return error.TypeError;
    const arg_array = try createArrayFromArgs(ctx.runtime, global, args);
    defer arg_array.free(ctx.runtime);
    return callValueOrBytecode(ctx, output, global, handler_value, trap, &.{ target_value, this_value, arg_array }, caller_function, caller_frame);
}

pub fn constructProxy(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    proxy_value: core.JSValue,
    proxy: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
    new_target_value: core.JSValue,
) !core.JSValue {
    if (!(try proxyTargetIsConstructor(ctx, proxy_value))) return error.TypeError;
    const target_value = proxy.proxyTarget() orelse return throwTypeErrorMessage(ctx, global, "revoked proxy");
    const handler_value = proxy.proxyHandler() orelse return throwTypeErrorMessage(ctx, global, "revoked proxy");
    const construct_atom = try ctx.runtime.internAtom("construct");
    defer ctx.runtime.atoms.free(construct_atom);
    const trap = try getValueProperty(ctx, output, global, handler_value, construct_atom, caller_function, caller_frame);
    defer trap.free(ctx.runtime);
    if (trap.isUndefined() or trap.isNull()) {
        if (try qjsReflectConstructGenericCallable(ctx, output, global, target_value, new_target_value, args, caller_function, caller_frame)) |value| return value;
        return constructValueOrBytecode(ctx, output, global, target_value, args, caller_function, caller_frame);
    }
    if (!isCallableValue(trap)) return error.TypeError;
    const arg_array = try createArrayFromArgs(ctx.runtime, global, args);
    defer arg_array.free(ctx.runtime);
    const result = try callValueOrBytecode(ctx, output, global, handler_value, trap, &.{ target_value, arg_array, new_target_value }, caller_function, caller_frame);
    if (!result.isObject()) {
        result.free(ctx.runtime);
        return error.TypeError;
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
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) HostError!core.JSValue {
    const target_value = (proxy.proxyTarget() orelse return throwTypeErrorMessage(ctx, global, "revoked proxy")).dup();
    defer target_value.free(ctx.runtime);
    const handler_value = (proxy.proxyHandler() orelse return throwTypeErrorMessage(ctx, global, "revoked proxy")).dup();
    defer handler_value.free(ctx.runtime);
    const trap = if (property_ic.ordinaryDataPropertyValueOrUndefinedForFastPath(ctx.runtime, handler_value, core.atom.ids.get)) |borrowed|
        if (borrowed.requiresRefCount()) borrowed.dup() else borrowed
    else
        try getValueProperty(ctx, output, global, handler_value, core.atom.ids.get, caller_function, caller_frame);
    defer trap.free(ctx.runtime);
    const target = try property_ops.expectObject(target_value);
    if (trap.isUndefined() or trap.isNull()) {
        if (property_ic.ordinaryDataPropertyValueOrUndefinedForFastPath(ctx.runtime, target_value, atom_id)) |borrowed| {
            return if (borrowed.requiresRefCount()) borrowed.dup() else borrowed;
        }
        return getValuePropertyWithReceiver(ctx, output, global, target_value, target, receiver_value, atom_id, caller_function, caller_frame);
    }
    const key_value = try proxyTrapKeyValue(ctx.runtime, atom_id);
    defer key_value.free(ctx.runtime);
    const result = try callValueOrBytecode(ctx, output, global, handler_value, trap, &.{ target_value, key_value, receiver_value }, caller_function, caller_frame);
    errdefer result.free(ctx.runtime);
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
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !void {
    switch (validatePlainProxyGetResultFast(target, atom_id, result)) {
        .valid => return,
        .invalid => return error.TypeError,
        .slow => {},
    }
    const target_desc = try proxyAwareOwnPropertyDescriptor(ctx, output, global, target, atom_id, caller_function, caller_frame) orelse return;
    defer target_desc.destroy(ctx.runtime);
    if (target_desc.configurable != false) return;
    switch (target_desc.kind) {
        .data => {
            if (target_desc.writable == false and !result.sameValue(target_desc.value)) return error.TypeError;
        },
        .accessor => {
            if (target_desc.getter.isUndefined() and !result.isUndefined()) return error.TypeError;
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
            break :blk if (!accessor.getterIsUndefined() or result.isUndefined()) .valid else .invalid;
        },
        .var_ref, .auto_init => .slow,
    };
}

pub fn firstProxyInPrototypeSetPath(rt: *core.JSRuntime, object: *core.Object, atom_id: core.Atom) !?*core.Object {
    var current = object.getPrototype();
    while (current) |prototype| : (current = prototype.getPrototype()) {
        if (prototype.proxyTarget() != null) return prototype;
        if (prototype.getOwnProperty(rt, atom_id)) |desc| {
            desc.destroy(rt);
            return null;
        }
    }
    return null;
}

pub fn proxySetValueProperty(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver_value: core.JSValue,
    proxy: *core.Object,
    atom_id: core.Atom,
    value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) HostError!bool {
    const target_value = proxy.proxyTarget() orelse return error.TypeError;
    const handler_value = proxy.proxyHandler() orelse return error.TypeError;
    const set_atom = try ctx.runtime.internAtom("set");
    defer ctx.runtime.atoms.free(set_atom);
    const trap = try getValueProperty(ctx, output, global, handler_value, set_atom, caller_function, caller_frame);
    defer trap.free(ctx.runtime);
    if (trap.isUndefined() or trap.isNull()) {
        const target = try property_ops.expectObject(target_value);
        return ordinarySetWithReceiver(ctx, output, global, target_value, target, receiver_value, atom_id, value, caller_function, caller_frame);
    }
    if (!isCallableValue(trap)) return error.TypeError;
    const key_value = try proxyTrapKeyValue(ctx.runtime, atom_id);
    defer key_value.free(ctx.runtime);
    const result = try callValueOrBytecode(ctx, output, global, handler_value, trap, &.{ target_value, key_value, value, receiver_value }, caller_function, caller_frame);
    defer result.free(ctx.runtime);
    if (!valueTruthy(result)) return false;
    const target = try property_ops.expectObject(target_value);
    try validateProxySetResult(ctx, output, global, target, atom_id, value, caller_function, caller_frame);
    return true;
}

pub fn validateProxySetResult(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    target: *core.Object,
    atom_id: core.Atom,
    value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !void {
    const target_desc = try proxyAwareOwnPropertyDescriptor(ctx, output, global, target, atom_id, caller_function, caller_frame) orelse return;
    defer target_desc.destroy(ctx.runtime);
    if (target_desc.configurable != false) return;
    switch (target_desc.kind) {
        .data => {
            if (target_desc.writable == false and !value.sameValue(target_desc.value)) return error.TypeError;
        },
        .accessor => {
            if (target_desc.setter.isUndefined()) return error.TypeError;
        },
        .generic => {},
    }
}

pub fn proxyDefineValueForReflectSet(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver_value: core.JSValue,
    proxy: *core.Object,
    atom_id: core.Atom,
    value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !void {
    var rooted_value = value;
    var key_value = core.JSValue.undefinedValue();
    var desc_value = core.JSValue.undefinedValue();
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &rooted_value },
        .{ .value = &key_value },
        .{ .value = &desc_value },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = ctx.runtime.active_value_roots,
        .values = &root_values,
    };
    ctx.runtime.active_value_roots = &root_frame;
    defer ctx.runtime.active_value_roots = root_frame.previous;

    const target_value = proxy.proxyTarget() orelse return error.TypeError;
    const handler_value = proxy.proxyHandler() orelse return error.TypeError;
    key_value = try proxyTrapKeyValue(ctx.runtime, atom_id);
    defer key_value.free(ctx.runtime);

    const get_desc_atom = try ctx.runtime.internAtom("getOwnPropertyDescriptor");
    defer ctx.runtime.atoms.free(get_desc_atom);
    const get_desc = try getValueProperty(ctx, output, global, handler_value, get_desc_atom, caller_function, caller_frame);
    defer get_desc.free(ctx.runtime);
    if (!get_desc.isUndefined() and !get_desc.isNull()) {
        if (!isCallableValue(get_desc)) return error.TypeError;
        const result = try callValueOrBytecode(ctx, output, global, handler_value, get_desc, &.{ target_value, key_value }, caller_function, caller_frame);
        result.free(ctx.runtime);
    }

    const define_atom = try ctx.runtime.internAtom("defineProperty");
    defer ctx.runtime.atoms.free(define_atom);
    const define = try getValueProperty(ctx, output, global, handler_value, define_atom, caller_function, caller_frame);
    defer define.free(ctx.runtime);
    if (define.isUndefined() or define.isNull()) {
        const target = try property_ops.expectObject(target_value);
        target.defineOwnProperty(ctx.runtime, atom_id, core.Descriptor.data(rooted_value, true, true, true)) catch |err| switch (err) {
            error.InvalidLength => return error.RangeError,
            error.ReadOnly, error.NotExtensible, error.IncompatibleDescriptor => return error.TypeError,
            else => return err,
        };
        return;
    }
    if (!isCallableValue(define)) return error.TypeError;
    const desc_object = try core.Object.create(ctx.runtime, core.class.ids.object, objectPrototypeFromGlobal(ctx.runtime, global));
    desc_value = desc_object.value();
    defer desc_value.free(ctx.runtime);
    try defineValueProperty(ctx.runtime, desc_object, "value", rooted_value);
    const result = try callValueOrBytecode(ctx, output, global, handler_value, define, &.{ target_value, key_value, desc_value }, caller_function, caller_frame);
    defer result.free(ctx.runtime);
    if (!valueTruthy(result)) return error.TypeError;
    _ = receiver_value;
}

pub fn proxyTargetIsCallableObject(object: *core.Object) bool {
    if (isFunctionLikeClass(object.class_id)) return true;
    if (!object.isProxy()) return false;
    const target = object.proxyTarget() orelse return false;
    return target.isFunctionBytecode() or functionObjectFromValue(target) != null or callableObjectFromValue(target) != null or proxyTargetIsCallable(target);
}

pub fn proxyDefineOwnProperty(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    proxy: *core.Object,
    atom_id: core.Atom,
    desc: core.Descriptor,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !bool {
    const target_value = proxy.proxyTarget() orelse return error.TypeError;
    const target = property_ops.expectObject(target_value) catch return error.TypeError;
    const handler_value = proxy.proxyHandler() orelse return error.TypeError;
    const trap_atom = try ctx.runtime.internAtom("defineProperty");
    defer ctx.runtime.atoms.free(trap_atom);
    const trap = try getValueProperty(ctx, output, global, handler_value, trap_atom, caller_function, caller_frame);
    defer trap.free(ctx.runtime);
    if (trap.isUndefined() or trap.isNull()) {
        if (target.proxyTarget() != null) return try proxyDefineOwnProperty(ctx, output, global, target, atom_id, desc, caller_function, caller_frame);
        target.defineOwnProperty(ctx.runtime, atom_id, desc) catch |err| switch (err) {
            error.ReadOnly, error.NotExtensible, error.IncompatibleDescriptor => return false,
            error.InvalidLength => return error.RangeError,
            else => return err,
        };
        return true;
    }
    if (!isCallableValue(trap)) return error.TypeError;
    const key_value = try proxyTrapKeyValue(ctx.runtime, atom_id);
    defer key_value.free(ctx.runtime);
    const desc_value = try descriptorObjectFromDescriptor(ctx.runtime, global, desc);
    defer desc_value.free(ctx.runtime);
    const result = try callValueOrBytecode(ctx, output, global, handler_value, trap, &.{ target_value, key_value, desc_value }, caller_function, caller_frame);
    defer result.free(ctx.runtime);
    if (!valueTruthy(result)) return false;
    const target_desc = try proxyAwareOwnPropertyDescriptor(ctx, output, global, target, atom_id, caller_function, caller_frame);
    defer if (target_desc) |item| item.destroy(ctx.runtime);
    // js_proxy_define_own_property (quickjs.c:51060) reads the raw
    // p->extensible flag of the target (no JS_IsExtensible call — a
    // nested-proxy target does NOT fire its isExtensible trap here).
    const target_extensible = target.isExtensible();
    if (!try isCompatibleProxyDescriptor(target_extensible, target_desc, desc)) return error.TypeError;
    const setting_config_false = desc.configurable == false;
    if (setting_config_false) {
        if (target_desc) |item| {
            if (item.configurable != false) return error.TypeError;
        } else {
            return error.TypeError;
        }
    }
    if (target_desc) |item| {
        if (item.configurable == false and item.kind == .data and item.writable == true and desc.kind == .data and desc.writable == false) return error.TypeError;
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
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !bool {
    if (result) return true;
    // js_proxy_has (quickjs.c:50765): the target desc is read via
    // JS_GetOwnPropertyInternal (exotic-dispatching — a nested-proxy target
    // fires its own getOwnPropertyDescriptor trap and its invariant checks),
    // while extensibility is the raw p->extensible flag (NOT JS_IsExtensible:
    // no isExtensible trap fires here).
    if (try proxyAwareOwnPropertyDescriptor(ctx, output, global, target, atom_id, caller_function, caller_frame)) |desc| {
        defer desc.destroy(ctx.runtime);
        if (desc.configurable == false) return error.TypeError;
        if (!target.isExtensible()) return error.TypeError;
    }
    return false;
}

pub fn proxyTrapKeyValue(rt: *core.JSRuntime, atom_id: core.Atom) !core.JSValue {
    if (rt.atoms.kind(atom_id)) |kind| {
        if (core.atom.isPublicSymbolKind(kind)) return rt.symbolValue(atom_id);
    }
    return rt.atoms.toStringValue(rt, atom_id);
}

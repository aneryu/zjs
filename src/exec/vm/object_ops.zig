const std = @import("std");
const bytecode = @import("../../bytecode/root.zig");
const builtins = @import("../../builtins/root.zig");
const core = @import("../../core/root.zig");
const call_mod = @import("../call.zig");
const construct_mod = @import("../construct.zig");
const date_vm = @import("date.zig");
const frame_mod = @import("../frame.zig");
const iter_vm = @import("iter.zig");
const property_ops = @import("../property_ops.zig");
const zjs_vm = @import("../zjs_vm.zig");
const value_ops = @import("../value_ops.zig");
const value_vm = @import("value.zig");
const HostError = exceptions.HostError;
pub const createNamedError = exception_ops.createNamedError;
const op = bytecode.opcode.op;
const atom_buffer = core.atom.predefinedId("buffer", .string).?;
const atom_byte_length = core.atom.predefinedId("byteLength", .string).?;
const atom_byte_offset = core.atom.predefinedId("byteOffset", .string).?;
const exceptions = @import("../exceptions.zig");
const exception_ops = @import("exception_ops.zig");

const shared_vm = @import("shared.zig");
const ActiveRootValueProbe = shared_vm.ActiveRootValueProbe;
const DataViewConstructorArgs = shared_vm.DataViewConstructorArgs;
const DynamicFunctionKind = shared_vm.DynamicFunctionKind;
const IntegrityLevel = shared_vm.IntegrityLevel;
const LengthIndexAtom = shared_vm.LengthIndexAtom;
const RegExpMatch = shared_vm.RegExpMatch;
const ValueSliceRoot = shared_vm.ValueSliceRoot;
const addCollectionEntriesFromArray = shared_vm.addCollectionEntriesFromArray;
const addCollectionEntriesFromIterator = shared_vm.addCollectionEntriesFromIterator;
const aggregateErrorsIterableToArray = shared_vm.aggregateErrorsIterableToArray;
const anchoredBinaryPropertyMatches = shared_vm.anchoredBinaryPropertyMatches;
const appendDecodedRegExpGroupName = shared_vm.appendDecodedRegExpGroupName;
const appendFunctionEvalLocal = shared_vm.appendFunctionEvalLocal;
const appendOwnedAtom = shared_vm.appendOwnedAtom;
const appendPrivateBoundName = shared_vm.appendPrivateBoundName;
const arrayLengthAssignmentValue = shared_vm.arrayLengthAssignmentValue;
const arrayLengthDefineValue = shared_vm.arrayLengthDefineValue;
const arrayPrototypeFromGlobal = shared_vm.arrayPrototypeFromGlobal;
const arrayPrototypeValuesFromGlobal = shared_vm.arrayPrototypeValuesFromGlobal;
const asyncFunctionPrototypeFromGlobal = shared_vm.asyncFunctionPrototypeFromGlobal;
const asyncGeneratorFunctionPrototypeFromGlobal = shared_vm.asyncGeneratorFunctionPrototypeFromGlobal;
const asyncGeneratorPrototypeFromGlobal = shared_vm.asyncGeneratorPrototypeFromGlobal;
const atomListContains = shared_vm.atomListContains;
const callAccessorSetter = shared_vm.callAccessorSetter;
const callSiteFunctionNameValue = shared_vm.callSiteFunctionNameValue;
const callValueOrBytecode = shared_vm.callValueOrBytecode;
const captureErrorStack = shared_vm.captureErrorStack;
const closeIteratorForFromEntriesAbrupt = shared_vm.closeIteratorForFromEntriesAbrupt;
const coerceOptionalNumberMethodArgument = shared_vm.coerceOptionalNumberMethodArgument;
const createIteratorResult = shared_vm.createIteratorResult;
const createRegExpIndexPair = shared_vm.createRegExpIndexPair;
const createRegExpMatchArrayFromValue = shared_vm.createRegExpMatchArrayFromValue;
const createStringFromByteUnits = shared_vm.createStringFromByteUnits;
const currentFrameFunctionIsStrict = shared_vm.currentFrameFunctionIsStrict;
const defineNativeDataMethod = shared_vm.defineNativeDataMethod;
const defineStringWrapperIndexProperty = shared_vm.defineStringWrapperIndexProperty;
const derivedConstructorThisLocalSlot = shared_vm.derivedConstructorThisLocalSlot;
const ensureLocalVarRefCell = shared_vm.ensureLocalVarRefCell;
const ensureVarRefCell = shared_vm.ensureVarRefCell;
const ensureVarRefsCapacity = shared_vm.ensureVarRefsCapacity;
const evalBytecodeHasVarDeclarations = shared_vm.evalBytecodeHasVarDeclarations;
const evalLocalSlotIsEvalVarCell = shared_vm.evalLocalSlotIsEvalVarCell;
const exactScriptExtensionsAliasTarget = shared_vm.exactScriptExtensionsAliasTarget;
const findPropertyEscapeMatch = shared_vm.findPropertyEscapeMatch;
const findStringPropertyEscapeMatch = shared_vm.findStringPropertyEscapeMatch;
const findUnicodePropertyOnlyClassMatch = shared_vm.findUnicodePropertyOnlyClassMatch;
const firstProxyInPrototypeSetPath = shared_vm.firstProxyInPrototypeSetPath;
const functionBytecodeFromValue = shared_vm.functionBytecodeFromValue;
const functionBytecodeHasClosureVarName = shared_vm.functionBytecodeHasClosureVarName;
const functionBytecodeHasDirectEval = shared_vm.functionBytecodeHasDirectEval;
const functionBytecodeUsesAtom = shared_vm.functionBytecodeUsesAtom;
const functionBytecodeUsesImportMeta = shared_vm.functionBytecodeUsesImportMeta;
const functionConstructorFromGlobal = shared_vm.functionConstructorFromGlobal;
const functionNameValueFromAtom = shared_vm.functionNameValueFromAtom;
const functionRealmGlobal = shared_vm.functionRealmGlobal;
const functionRuntimeStrict = shared_vm.functionRuntimeStrict;
const getFastStringPrimitiveDataProperty = shared_vm.getFastStringPrimitiveDataProperty;
const getProxyProperty = shared_vm.getProxyProperty;
const getStringIndexValue = shared_vm.getStringIndexValue;
const importMetaUrlValue = shared_vm.importMetaUrlValue;
const installLexicalPrivateNameRemap = shared_vm.installLexicalPrivateNameRemap;
const isAnchoredRgiEmojiSource = shared_vm.isAnchoredRgiEmojiSource;
const isBlockedByUnscopables = shared_vm.isBlockedByUnscopables;
const isCallableValue = shared_vm.isCallableValue;
const isFunctionLikeClass = shared_vm.isFunctionLikeClass;
const isRevokedProxy = shared_vm.isRevokedProxy;
const isUnknownScriptName = shared_vm.isUnknownScriptName;
const iteratorForValue = shared_vm.iteratorForValue;
const iteratorStepValue = shared_vm.iteratorStepValue;
const lengthIndexValue = shared_vm.lengthIndexValue;
const lookupFrameFirstEvalBindingValue = shared_vm.lookupFrameFirstEvalBindingValue;
const lookupNamedSlotValue = shared_vm.lookupNamedSlotValue;
const lookupNamedVarRef = shared_vm.lookupNamedVarRef;
const mappedArgumentsValue = shared_vm.mappedArgumentsValue;
const ordinarySetWithReceiver = shared_vm.ordinarySetWithReceiver;
const proxyAwareIsExtensible = shared_vm.proxyAwareIsExtensible;
const proxyAwareOwnPropertyDescriptor = shared_vm.proxyAwareOwnPropertyDescriptor;
const proxyAwarePreventExtensions = shared_vm.proxyAwarePreventExtensions;
const proxyAwareSetPrototypeOf = shared_vm.proxyAwareSetPrototypeOf;
const proxyCreateDataPropertyOrThrow = shared_vm.proxyCreateDataPropertyOrThrow;
const proxyDefineOwnProperty = shared_vm.proxyDefineOwnProperty;
const proxySetValueProperty = shared_vm.proxySetValueProperty;
const proxyTrapKeyValue = shared_vm.proxyTrapKeyValue;
const qjsBigIntPrototypeToString = shared_vm.qjsBigIntPrototypeToString;
const qjsCreateArrayDataOrTypedArrayElement = shared_vm.qjsCreateArrayDataOrTypedArrayElement;
const qjsDefinePropertiesCall = shared_vm.qjsDefinePropertiesCall;
const qjsDefinePropertiesOnTarget = shared_vm.qjsDefinePropertiesOnTarget;
const qjsDefineToStringTag = shared_vm.qjsDefineToStringTag;
const qjsDestructuringRest = shared_vm.qjsDestructuringRest;
const qjsIteratorClose = shared_vm.qjsIteratorClose;
const qjsObjectEntryArrayValue = shared_vm.qjsObjectEntryArrayValue;
const qjsObjectToLocaleStringCall = shared_vm.qjsObjectToLocaleStringCall;
const qjsObjectToStringCall = shared_vm.qjsObjectToStringCall;
const qjsRegExpAutoInitBuiltinMatches = shared_vm.qjsRegExpAutoInitBuiltinMatches;
const qjsRegExpExecAnchoredRgiEmojiFallback = shared_vm.qjsRegExpExecAnchoredRgiEmojiFallback;
const qjsRegExpNativeBuiltinMatches = shared_vm.qjsRegExpNativeBuiltinMatches;
const qjsWorkerNativeFunction = shared_vm.qjsWorkerNativeFunction;
const readUtf16CodePoint = shared_vm.readUtf16CodePoint;
const regExpConstructorFromGlobal = shared_vm.regExpConstructorFromGlobal;
const regExpFlagsContain = shared_vm.regExpFlagsContain;
const rejectModuleNamespaceSuperSet = shared_vm.rejectModuleNamespaceSuperSet;
const remapPrivateAtomForOperation = shared_vm.remapPrivateAtomForOperation;
const runGeneratorParameterInit = shared_vm.runGeneratorParameterInit;
const setFailureShouldThrow = shared_vm.setFailureShouldThrow;
const setMappedArgumentsValue = shared_vm.setMappedArgumentsValue;
const shouldSkipDirectEvalLocalCapture = shared_vm.shouldSkipDirectEvalLocalCapture;
const shouldSkipDirectEvalScopeCaptureName = shared_vm.shouldSkipDirectEvalScopeCaptureName;
const slotValueDup = shared_vm.slotValueDup;
const storeRealmValue = shared_vm.storeRealmValue;
const stringObjectHasIndexProperty = shared_vm.stringObjectHasIndexProperty;
const stringPropertyEscapePattern = shared_vm.stringPropertyEscapePattern;
const stringSliceValue = shared_vm.stringSliceValue;
const throwPrivateBrandTypeError = shared_vm.throwPrivateBrandTypeError;
const throwRangeErrorMessage = shared_vm.throwRangeErrorMessage;
const throwSetFailureTypeError = shared_vm.throwSetFailureTypeError;
const throwTypeErrorIntrinsicForGlobal = shared_vm.throwTypeErrorIntrinsicForGlobal;
const throwTypeErrorMessage = shared_vm.throwTypeErrorMessage;
const toLengthIndex = shared_vm.toLengthIndex;
const toPrimitiveForNumber = shared_vm.toPrimitiveForNumber;
const toPrimitiveForString = shared_vm.toPrimitiveForString;
const toStringForAnnexB = shared_vm.toStringForAnnexB;
const typedArrayCanonicalGet = shared_vm.typedArrayCanonicalGet;
const typedArrayCanonicalHas = shared_vm.typedArrayCanonicalHas;
const typedArrayCanonicalSet = shared_vm.typedArrayCanonicalSet;
const typedArrayDefineOwnPropertyVm = shared_vm.typedArrayDefineOwnPropertyVm;
const typedArrayOwnKeys = shared_vm.typedArrayOwnKeys;
const typedArrayPrototypeSet = shared_vm.typedArrayPrototypeSet;
const unicodePropertyRunCodePointMatches = shared_vm.unicodePropertyRunCodePointMatches;
const validateProxyHasResult = shared_vm.validateProxyHasResult;
const validateProxyOwnKeysResult = shared_vm.validateProxyOwnKeysResult;
const valueTruthy = shared_vm.valueTruthy;
const varRefCellFromValue = shared_vm.varRefCellFromValue;


pub fn objectPrototypeFromGlobal(rt: *core.JSRuntime, global: *core.Object) ?*core.Object {
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
    try defineNativeDataMethod(rt, object, "next", 1);
    try defineNativeDataMethod(rt, object, "return", 1);
    try defineNativeDataMethod(rt, object, "throw", 1);

    const tag_atom = core.atom.predefinedId("Symbol.toStringTag", .symbol) orelse return error.TypeError;
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
    const constructor = try builtins.function.nativeFunction(rt, "GeneratorFunction", 1);
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

pub fn createBytecodeFunctionObject(
    ctx: *core.JSContext,
    frame: *frame_mod.Frame,
    caller_function: *const bytecode.Bytecode,
    global: *core.Object,
    value: core.JSValue,
    name_atom: core.Atom,
    opc: u8,
    create_prototype: bool,
    eval_local_names: []const core.Atom,
    input_eval_local_slots: []core.JSValue,
    eval_var_ref_names: []const core.Atom,
    input_eval_var_refs: []const core.JSValue,
    input_skip_direct_eval_capture_values: []const core.JSValue,
) !core.JSValue {
    if (!value.isFunctionBytecode()) return error.InvalidBytecode;
    var rooted_value = value;
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &rooted_value },
    };
    var eval_local_slots = input_eval_local_slots;
    var eval_var_refs_buffer = try core.runtime.ValueRootBuffer.initCopy(ctx.runtime, input_eval_var_refs);
    defer eval_var_refs_buffer.deinit(ctx.runtime);
    const eval_var_refs = eval_var_refs_buffer.values;
    var skip_direct_eval_capture_values_buffer = try core.runtime.ValueRootBuffer.initCopy(ctx.runtime, input_skip_direct_eval_capture_values);
    defer skip_direct_eval_capture_values_buffer.deinit(ctx.runtime);
    const skip_direct_eval_capture_values = skip_direct_eval_capture_values_buffer.values;
    var root_slices = [_]core.runtime.ValueRootSlice{
        .{ .mutable = &eval_local_slots },
        eval_var_refs_buffer.slice(),
        skip_direct_eval_capture_values_buffer.slice(),
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = ctx.runtime.active_value_roots,
        .values = &root_values,
        .slices = &root_slices,
    };
    ctx.runtime.active_value_roots = &root_frame;
    defer ctx.runtime.active_value_roots = root_frame.previous;

    const fb = functionBytecodeFromValue(rooted_value) orelse return error.InvalidBytecode;
    const object = try core.Object.create(ctx.runtime, core.class.ids.bytecode_function, null);
    errdefer core.Object.destroyFromHeader(ctx.runtime, &object.header);
    const function_prototype = if (fb.func_kind == .async_generator)
        try asyncGeneratorFunctionPrototypeFromGlobal(ctx.runtime, global)
    else if (fb.func_kind == .generator)
        try generatorFunctionPrototypeFromGlobal(ctx.runtime, global)
    else if (fb.func_kind == .async)
        try asyncFunctionPrototypeFromGlobal(ctx.runtime, global)
    else
        functionPrototypeFromGlobal(ctx.runtime, global);
    if (function_prototype) |prototype| {
        try object.setPrototype(ctx.runtime, prototype);
    }
    try object.setFunctionRealmGlobalPtr(ctx.runtime, global);
    try object.setOptionalValueSlot(ctx.runtime, object.functionBytecodeSlot(), rooted_value.dup());
    if (objectFromValue(frame.current_function)) |parent_function_object| {
        if (parent_function_object.functionEvalLocalNamesSlot().*.len != 0) {
            try object.setOptionalValueSlot(ctx.runtime, object.functionEvalParentFunctionSlot(), frame.current_function.dup());
        }
        if (parent_function_object.functionImportMeta()) |import_meta| {
            try object.setOptionalValueSlot(ctx.runtime, object.functionImportMetaSlot(), import_meta.dup());
        }
    } else if (caller_function.flags.is_module and functionBytecodeUsesImportMeta(fb)) {
        const import_meta = try importMetaObject(ctx, global, caller_function, frame);
        defer import_meta.free(ctx.runtime);
        try object.setOptionalValueSlot(ctx.runtime, object.functionImportMetaSlot(), import_meta.dup());
    }
    try installLexicalPrivateNameRemap(ctx.runtime, object, frame, fb.private_bound_names);
    if (fb.class_fields_init) |init_bytecode| {
        const init_value = try createBytecodeFunctionObject(ctx, frame, caller_function, global, init_bytecode, core.atom.ids.empty_string, opc, false, eval_local_names, eval_local_slots, eval_var_ref_names, eval_var_refs, &.{});
        try object.setOptionalValueSlot(ctx.runtime, object.functionClassFieldsInitSlot(), init_value);
    }
    if (fb.is_arrow_function) {
        const lexical_this_slot = derivedConstructorThisLocalSlot(frame) orelse &frame.this_value;
        const lexical_this_value = if (frame.function.flags.is_derived_class_constructor or varRefCellFromValue(lexical_this_slot.*) != null)
            try ensureVarRefCell(ctx, lexical_this_slot)
        else
            lexical_this_slot.*.dup();
        try object.setOptionalValueSlot(ctx.runtime, object.functionLexicalThisSlot(), lexical_this_value);
        if (property_ops.expectObject(frame.current_function)) |function_object| {
            try object.setFunctionHomeObject(ctx.runtime, function_object.functionHomeObject());
            if (function_object.functionSuperConstructor()) |super_constructor| try object.setOptionalValueSlot(ctx.runtime, object.functionSuperConstructorSlot(), super_constructor.dup());
            if (function_object.functionArrowConstructorThis()) |constructor_this| try object.setOptionalValueSlot(ctx.runtime, object.functionArrowConstructorThisSlot(), constructor_this.dup());
        } else |_| {}
        if (frame.function.flags.is_derived_class_constructor) {
            try object.setOptionalValueSlot(ctx.runtime, object.functionArrowConstructorThisSlot(), frame.constructor_this_value.dup());
        }
        if (!frame.new_target.isUndefined()) {
            try object.setOptionalValueSlot(ctx.runtime, object.functionArrowNewTargetSlot(), frame.new_target.dup());
        }
        if (functionBytecodeUsesAtom(fb, core.atom.ids.arguments) or functionBytecodeUsesArgumentsSpecialObject(fb)) {
            const arguments_value = lookupFrameFirstEvalBindingValue(ctx.runtime, eval_local_names, eval_local_slots, eval_var_ref_names, eval_var_refs, frame, core.atom.ids.arguments) orelse
                try frameArgumentsObject(ctx, global, frame);
            defer arguments_value.free(ctx.runtime);
            try appendFunctionEvalLocal(ctx, object, core.atom.ids.arguments, arguments_value);
        }
    }
    const effective_name = if (fb.func_name != core.atom.ids.empty_string and ctx.runtime.atoms.kind(fb.func_name) != null)
        fb.func_name
    else if (fb.is_class_constructor)
        name_atom
    else
        fb.func_name;
    try object.defineOwnProperty(ctx.runtime, core.atom.ids.length, core.Descriptor.data(core.JSValue.int32(fb.defined_arg_count), false, false, true));
    if (ctx.runtime.atoms.kind(effective_name) != null) {
        const name_value = try functionNameValueFromAtom(ctx.runtime, effective_name, null);
        defer name_value.free(ctx.runtime);
        try object.defineOwnProperty(ctx.runtime, core.atom.ids.name, core.Descriptor.data(name_value, false, false, true));
    }
    if (fb.closure_var.len > 0) {
        const captures = try ctx.runtime.memory.alloc(core.JSValue, fb.closure_var.len);
        var captures_transferred = false;
        errdefer if (!captures_transferred) ctx.runtime.memory.free(core.JSValue, captures);
        var rooted_captures: []core.JSValue = captures[0..0];
        var captures_root = ValueSliceRoot{};
        captures_root.init(ctx.runtime, &rooted_captures);
        defer captures_root.deinit();
        var initialized: usize = 0;
        errdefer if (!captures_transferred) {
            for (captures[0..initialized]) |*stored| {
                stored.free(ctx.runtime);
                stored.* = core.JSValue.undefinedValue();
            }
            rooted_captures = &.{};
        };
        for (fb.closure_var, 0..) |cv, idx| {
            captures[idx] = switch (cv.closure_type) {
                .local => blk: {
                    if (cv.var_idx >= frame.locals.len) return error.InvalidBytecode;
                    break :blk try ensureLocalVarRefCell(ctx, frame, cv.var_idx, cv.is_lexical);
                },
                .arg => blk: {
                    if (cv.var_idx >= frame.args.len) return error.InvalidBytecode;
                    break :blk try ensureVarRefCell(ctx, &frame.args[cv.var_idx]);
                },
                .ref => blk: {
                    try ensureVarRefsCapacity(ctx, frame, cv.var_idx);
                    break :blk try ensureVarRefCell(ctx, &frame.var_refs[cv.var_idx]);
                },
                .module_decl, .module_import => blk: {
                    try ensureVarRefsCapacity(ctx, frame, cv.var_idx);
                    break :blk try ensureVarRefCell(ctx, &frame.var_refs[cv.var_idx]);
                },
                else => return error.InvalidBytecode,
            };
            if (varRefCellFromValue(captures[idx])) |cell| {
                const captured_const = cv.is_const or switch (cv.closure_type) {
                    .local => cv.var_idx < caller_function.var_is_const.len and caller_function.var_is_const[cv.var_idx],
                    .ref, .module_decl, .module_import => cv.var_idx < caller_function.var_ref_is_const.len and caller_function.var_ref_is_const[cv.var_idx],
                    else => false,
                };
                cell.varRefIsConstSlot().* = cell.varRefIsConstSlot().* or captured_const or cv.var_kind == .function_name;
                cell.varRefIsFunctionNameSlot().* = cell.varRefIsFunctionNameSlot().* or cv.var_kind == .function_name;
            }
            initialized += 1;
            rooted_captures = captures[0..initialized];
        }
        captures_transferred = true;
        try object.setValueSlice(ctx.runtime, object.functionCapturesSlot(), captures);
    }
    const function_has_direct_eval = functionBytecodeHasDirectEval(fb, ctx.runtime);
    const captures_eval_var_scope =
        value_ops.atomNameEql(ctx.runtime, caller_function.name, "<eval>") and
        !frame.current_function.isUndefined() and
        fb.func_name == core.atom.ids.empty_string and
        evalBytecodeHasVarDeclarations(ctx.runtime, caller_function);
    const captures_direct_eval_scope = function_has_direct_eval or captures_eval_var_scope;
    const captures_eval_frame_scope = captures_direct_eval_scope;
    if (eval_local_names.len > 0 or eval_var_ref_names.len > 0 or
        (captures_eval_frame_scope and caller_function.var_names.len > 0) or
        (captures_eval_frame_scope and caller_function.arg_names.len > 0) or
        (captures_direct_eval_scope and caller_function.var_ref_names.len > 0))
    {
        var used_count: usize = 0;
        for (eval_local_names, 0..) |atom_id, idx| {
            if (shouldSkipDirectEvalScopeCaptureName(ctx.runtime, captures_direct_eval_scope, fb, atom_id)) continue;
            if (functionBytecodeHasClosureVarName(fb, atom_id)) continue;
            const capture_eval_var_cell = captures_eval_var_scope and idx < eval_local_slots.len and evalLocalSlotIsEvalVarCell(eval_local_slots[idx]);
            if (captures_direct_eval_scope or capture_eval_var_cell or functionBytecodeUsesAtom(fb, atom_id)) used_count += 1;
        }
        for (eval_var_ref_names) |atom_id| {
            if (shouldSkipDirectEvalScopeCaptureName(ctx.runtime, captures_direct_eval_scope, fb, atom_id)) continue;
            if (functionBytecodeHasClosureVarName(fb, atom_id)) continue;
            if (captures_direct_eval_scope or captures_eval_var_scope or functionBytecodeUsesAtom(fb, atom_id)) used_count += 1;
        }
        if (captures_eval_frame_scope) {
            const local_count = @min(caller_function.var_names.len, frame.locals.len);
            for (frame.locals[0..local_count], 0..) |slot, idx| {
                if (idx < caller_function.var_is_lexical.len and caller_function.var_is_lexical[idx]) continue;
                if (idx < frame.locals_uninit.len and frame.localIsUninitialized(idx)) continue;
                if (shouldSkipDirectEvalLocalCapture(fb, slot, skip_direct_eval_capture_values)) continue;
                used_count += 1;
            }
            const arg_count = @min(caller_function.arg_names.len, frame.args.len);
            for (caller_function.arg_names[0..arg_count], 0..) |atom_id, idx| {
                if (atom_id == core.atom.null_atom) continue;
                if (functionBytecodeHasClosureVarName(fb, atom_id)) continue;
                if (shouldSkipDirectEvalLocalCapture(fb, frame.args[idx], skip_direct_eval_capture_values)) continue;
                used_count += 1;
            }
            if (captures_direct_eval_scope) used_count += @min(caller_function.var_ref_names.len, frame.var_refs.len);
        }
        if (used_count > 0) {
            const names = try ctx.runtime.memory.alloc(core.Atom, used_count);
            var eval_bindings_transferred = false;
            errdefer if (!eval_bindings_transferred) ctx.runtime.memory.free(core.Atom, names);
            const refs = try ctx.runtime.memory.alloc(core.JSValue, used_count);
            errdefer if (!eval_bindings_transferred) ctx.runtime.memory.free(core.JSValue, refs);
            var rooted_refs: []core.JSValue = refs[0..0];
            var refs_root = ValueSliceRoot{};
            refs_root.init(ctx.runtime, &rooted_refs);
            defer refs_root.deinit();
            var initialized: usize = 0;
            var initialized_names: usize = 0;
            errdefer if (!eval_bindings_transferred) {
                for (names[0..initialized_names]) |atom_id| ctx.runtime.atoms.free(atom_id);
            };
            errdefer if (!eval_bindings_transferred) {
                for (refs[0..initialized]) |*stored| {
                    stored.free(ctx.runtime);
                    stored.* = core.JSValue.undefinedValue();
                }
                rooted_refs = &.{};
            };
            for (eval_local_names, 0..) |atom_id, idx| {
                if (shouldSkipDirectEvalScopeCaptureName(ctx.runtime, captures_direct_eval_scope, fb, atom_id)) continue;
                if (functionBytecodeHasClosureVarName(fb, atom_id)) continue;
                const capture_eval_var_cell = captures_eval_var_scope and idx < eval_local_slots.len and evalLocalSlotIsEvalVarCell(eval_local_slots[idx]);
                if (!captures_direct_eval_scope and !capture_eval_var_cell and !functionBytecodeUsesAtom(fb, atom_id)) continue;
                names[initialized] = ctx.runtime.atoms.dup(atom_id);
                initialized_names += 1;
                refs[initialized] = if (idx < eval_local_slots.len)
                    try ensureVarRefCell(ctx, &eval_local_slots[idx])
                else
                    core.JSValue.undefinedValue();
                initialized += 1;
                rooted_refs = refs[0..initialized];
            }
            for (eval_var_ref_names, 0..) |atom_id, idx| {
                if (shouldSkipDirectEvalScopeCaptureName(ctx.runtime, captures_direct_eval_scope, fb, atom_id)) continue;
                if (functionBytecodeHasClosureVarName(fb, atom_id)) continue;
                if (!captures_direct_eval_scope and !captures_eval_var_scope and !functionBytecodeUsesAtom(fb, atom_id)) continue;
                names[initialized] = ctx.runtime.atoms.dup(atom_id);
                initialized_names += 1;
                refs[initialized] = if (idx < eval_var_refs.len)
                    eval_var_refs[idx].dup()
                else
                    core.JSValue.undefinedValue();
                initialized += 1;
                rooted_refs = refs[0..initialized];
            }
            if (captures_eval_frame_scope) {
                const local_count = @min(caller_function.var_names.len, frame.locals.len);
                for (caller_function.var_names[0..local_count], 0..) |atom_id, idx| {
                    if (idx < caller_function.var_is_lexical.len and caller_function.var_is_lexical[idx]) continue;
                    if (idx < frame.locals_uninit.len and frame.localIsUninitialized(idx)) continue;
                    if (shouldSkipDirectEvalLocalCapture(fb, frame.locals[idx], skip_direct_eval_capture_values)) continue;
                    names[initialized] = ctx.runtime.atoms.dup(atom_id);
                    initialized_names += 1;
                    refs[initialized] = try ensureVarRefCell(ctx, &frame.locals[idx]);
                    initialized += 1;
                    rooted_refs = refs[0..initialized];
                }
                const arg_count = @min(caller_function.arg_names.len, frame.args.len);
                for (caller_function.arg_names[0..arg_count], 0..) |atom_id, idx| {
                    if (atom_id == core.atom.null_atom) continue;
                    if (functionBytecodeHasClosureVarName(fb, atom_id)) continue;
                    if (shouldSkipDirectEvalLocalCapture(fb, frame.args[idx], skip_direct_eval_capture_values)) continue;
                    names[initialized] = ctx.runtime.atoms.dup(atom_id);
                    initialized_names += 1;
                    refs[initialized] = try ensureVarRefCell(ctx, &frame.args[idx]);
                    initialized += 1;
                    rooted_refs = refs[0..initialized];
                }
            }
            if (captures_direct_eval_scope) {
                const ref_count = @min(caller_function.var_ref_names.len, frame.var_refs.len);
                for (caller_function.var_ref_names[0..ref_count], 0..) |atom_id, idx| {
                    names[initialized] = ctx.runtime.atoms.dup(atom_id);
                    initialized_names += 1;
                    refs[initialized] = try ensureVarRefCell(ctx, &frame.var_refs[idx]);
                    initialized += 1;
                    rooted_refs = refs[0..initialized];
                }
            }
            try object.writeValueSliceBarrier(ctx.runtime, refs);
            eval_bindings_transferred = true;
            object.functionEvalLocalNamesSlot().* = names;
            object.functionEvalLocalRefsSlot().* = refs;
        }
    }
    if (create_prototype and fb.has_prototype) {
        const generator_prototype = if (fb.func_kind == .async_generator)
            try asyncGeneratorPrototypeFromGlobal(ctx.runtime, global)
        else if (fb.func_kind == .generator)
            try generatorPrototypeFromGlobal(ctx.runtime, global)
        else
            objectPrototypeFromGlobal(ctx.runtime, global);
        const prototype = try core.Object.create(ctx.runtime, core.class.ids.object, generator_prototype);
        var prototype_raw_owned = true;
        errdefer if (prototype_raw_owned) core.Object.destroyFromHeader(ctx.runtime, &prototype.header);
        if (fb.func_kind != .generator and fb.func_kind != .async_generator) {
            try prototype.defineOwnProperty(ctx.runtime, core.atom.ids.constructor, core.Descriptor.data(object.value(), true, false, true));
        }
        const prototype_value = prototype.value();
        prototype_raw_owned = false;
        defer prototype_value.free(ctx.runtime);
        try object.defineOwnProperty(ctx.runtime, core.atom.ids.prototype, core.Descriptor.data(prototype_value, true, false, false));
    }
    return object.value();
}

pub fn functionBytecodeUsesArgumentsSpecialObject(fb: *const bytecode.FunctionBytecode) bool {
    var index: usize = 0;
    while (index + 1 < fb.byte_code.len) : (index += 1) {
        if (fb.byte_code[index] == op.special_object and (fb.byte_code[index + 1] == 0 or fb.byte_code[index + 1] == 1)) return true;
    }
    return false;
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

    const wrapper_value = try constructPrimitiveWrapperWithPrototype(rt, core.class.ids.symbol, null, core.JSValue.symbol(symbol_atom));
    var wrapper_alive = true;
    defer if (wrapper_alive) wrapper_value.free(rt);
    const wrapper = objectFromValue(wrapper_value) orelse return error.TypeError;

    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    const stored = wrapper.objectDataSlot().* orelse return error.TypeError;
    try std.testing.expect(stored.same(core.JSValue.symbol(symbol_atom)));

    wrapper_value.free(rt);
    wrapper_alive = false;
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

    const name_value = try value_ops.createStringValue(rt, "AggregateError");
    defer name_value.free(rt);
    try defineDataProperty(rt, instance, "name", name_value, true, false, true);

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

    const error_atom = try rt.atoms.newValueSymbol("gc-aggregate-error-item-symbol");
    const cause_atom = try rt.atoms.newValueSymbol("gc-aggregate-error-cause-symbol");
    try errors_source.defineOwnProperty(rt, core.atom.atomFromUInt32(0), core.Descriptor.data(core.JSValue.symbol(error_atom), true, true, true));
    errors_source.length = 1;
    try errors_source.defineOwnProperty(rt, core.atom.ids.length, core.Descriptor.data(core.JSValue.int32(1), true, false, false));
    try defineDataProperty(rt, options, "cause", core.JSValue.symbol(cause_atom), true, false, true);

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
        try std.testing.expect(stored_error.same(core.JSValue.symbol(error_atom)));

        const stored_cause = aggregate.getProperty(cause_key);
        defer stored_cause.free(rt);
        try std.testing.expect(stored_cause.same(core.JSValue.symbol(cause_atom)));
    }

    aggregate_value.free(rt);
    aggregate_alive = false;
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
    const suppressed_atom = try rt.atoms.newValueSymbol("gc-suppressed-error-suppressed-symbol");
    const args = [_]core.JSValue{
        core.JSValue.symbol(error_atom),
        core.JSValue.symbol(suppressed_atom),
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
    const stored_error = object.getProperty(error_key);
    defer stored_error.free(rt);
    const stored_suppressed = object.getProperty(suppressed_key);
    defer stored_suppressed.free(rt);
    try std.testing.expect(stored_error.same(core.JSValue.symbol(error_atom)));
    try std.testing.expect(stored_suppressed.same(core.JSValue.symbol(suppressed_atom)));

    error_value.free(rt);
    error_alive = false;
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

    const name_value = try value_ops.createStringValue(rt, name);
    defer name_value.free(rt);
    try defineDataProperty(rt, instance, "name", name_value, true, false, true);

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
    try defineDataProperty(rt, options, "cause", core.JSValue.symbol(cause_atom), true, false, true);
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
        try std.testing.expect(stored_cause.same(core.JSValue.symbol(cause_atom)));
    }

    error_value.free(rt);
    error_alive = false;
    options.value().free(rt);
    options_alive = false;
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(cause_atom) == null);
}

pub fn createCallSiteObject(ctx: *core.JSContext, global: *core.Object, entry: core.BacktraceFrame) !core.JSValue {
    const object = try core.Object.create(ctx.runtime, core.class.ids.object, try callSitePrototypeFromGlobal(ctx.runtime, global));
    errdefer core.Object.destroyFromHeader(ctx.runtime, &object.header);
    const location = entry.location();
    const filename = try value_ops.createStringValue(ctx.runtime, ctx.runtime.atoms.name(entry.filename) orelse "<anonymous>");
    defer filename.free(ctx.runtime);
    const function_name_value = try callSiteFunctionNameValue(ctx, entry);
    defer function_name_value.free(ctx.runtime);
    try object.setCallSiteMetadata(
        ctx.runtime,
        filename,
        function_name_value,
        if (location.line_num > 0) location.line_num else 1,
        if (location.col_num > 0) location.col_num else 1,
    );

    return object.value();
}

pub fn callSitePrototypeFromGlobal(rt: *core.JSRuntime, global: *core.Object) !*core.Object {
    if (cachedRealmObject(global, .callsite_prototype)) |stored| return stored;
    const prototype = try core.Object.create(rt, core.class.ids.object, objectPrototypeFromGlobal(rt, global));
    var prototype_raw_owned = true;
    errdefer if (prototype_raw_owned) core.Object.destroyFromHeader(rt, &prototype.header);

    const methods = [_][]const u8{
        "getFunction",
        "getFunctionName",
        "getFileName",
        "getLineNumber",
        "getColumnNumber",
        "isNative",
    };
    for (methods) |method_name| {
        try defineNativeDataMethod(rt, prototype, method_name, 0);
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
    const function_value = current_object.functionBytecodeSlot().* orelse return null;
    const fb = functionBytecodeFromValue(function_value) orelse return null;
    if (!fb.is_arrow_function) return null;
    return current_object;
}

pub fn qjsRegExpPrototypeMethodIsDefault(object: *core.Object, atom_id: core.Atom, expected_id: u32) bool {
    if (object.class_id != core.class.ids.regexp) return false;
    if (object.hasOwnProperty(atom_id)) return false;
    const proto = object.getPrototype() orelse return false;
    if (proto.exotic != null) return false;
    for (proto.properties) |entry| {
        if (entry.flags.deleted or entry.atom_id != atom_id) continue;
        if (entry.flags.accessor) return false;
        return switch (entry.slot) {
            .data => |method| qjsRegExpNativeBuiltinMatches(method, expected_id),
            .auto_init => |info| qjsRegExpAutoInitBuiltinMatches(info, expected_id),
            .accessor, .deleted => false,
        };
    }
    return false;
}

pub fn regExpExecPropertyIsDefault(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    rx: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !bool {
    const exec_atom = core.atom.predefinedId("exec", .string) orelse return false;
    const exec_value = try getValueProperty(ctx, output, global, rx, exec_atom, caller_function, caller_frame);
    defer exec_value.free(ctx.runtime);
    const exec_object = objectFromValue(exec_value) orelse return false;
    const native_ref = core.function.decodeNativeBuiltinId(exec_object.nativeFunctionId()) orelse return false;
    return native_ref.domain == .regexp and native_ref.id == @intFromEnum(builtins.regexp.PrototypeMethod.exec);
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
    if (builtins.buffer.isTypedArrayObject(object)) {
        if (try typedArrayCanonicalSet(ctx, output, global, object, atom_id, value_to_set)) return;
    }
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
    const desc = regexp_proto.getOwnProperty(key) orelse return false;
    defer desc.destroy(rt);
    if (desc.kind != .accessor) return false;
    return sameObjectIdentity(desc.getter, getter_value);
}

pub fn objectHasRegExpInternalSlots(object: *core.Object) bool {
    if (object.class_id != core.class.ids.regexp) return false;
    return object.regexpSource() != null and object.regexpFlags() != null;
}

pub fn qjsRegExpExecPropertyFallback(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    regexp_value: core.JSValue,
    source: []const u8,
    flags: []const u8,
    string_value: core.JSValue,
    use_last_index: bool,
    is_global: bool,
    is_sticky: bool,
    has_indices: bool,
    input_len: usize,
    start_index: usize,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    if (isAnchoredRgiEmojiSource(source) and regExpFlagsContain(flags, 'v')) {
        return try qjsRegExpExecAnchoredRgiEmojiFallback(ctx, output, global, regexp_value, string_value, use_last_index, is_global, is_sticky, has_indices, input_len, start_index, caller_function, caller_frame);
    }
    if (isAnchoredBinaryPropertySource(source)) {
        return try qjsRegExpExecAnchoredPropertyFallback(ctx, output, global, regexp_value, source, string_value, use_last_index, is_global, is_sticky, has_indices, input_len, start_index, caller_function, caller_frame);
    }
    if (regExpFlagsContain(flags, 'v')) {
        if (findStringPropertyEscapeMatch(source, string_value, start_index, is_sticky)) |match| {
            const update_last_index = use_last_index and (is_global or is_sticky);
            if (update_last_index) {
                const next_value = if (match.index + match.len <= @as(usize, @intCast(std.math.maxInt(i32))))
                    core.JSValue.int32(@intCast(match.index + match.len))
                else
                    core.JSValue.float64(@floatFromInt(match.index + match.len));
                try setValuePropertyStrict(ctx, output, global, regexp_value, core.atom.ids.lastIndex, next_value, caller_function, caller_frame);
            }
            return try createRegExpMatchArrayFromValue(ctx.runtime, global, string_value, match, has_indices);
        }
    }
    if (regExpFlagsContain(flags, 'u') or regExpFlagsContain(flags, 'v')) {
        if (findUnicodePropertyOnlyClassMatch(source, string_value, start_index, is_sticky)) |match| {
            const update_last_index = use_last_index and (is_global or is_sticky);
            if (update_last_index) {
                const next_value = if (match.index + match.len <= @as(usize, @intCast(std.math.maxInt(i32))))
                    core.JSValue.int32(@intCast(match.index + match.len))
                else
                    core.JSValue.float64(@floatFromInt(match.index + match.len));
                try setValuePropertyStrict(ctx, output, global, regexp_value, core.atom.ids.lastIndex, next_value, caller_function, caller_frame);
            }
            return try createRegExpMatchArrayFromValue(ctx.runtime, global, string_value, match, has_indices);
        }
    }
    if (findPropertyEscapeMatch(source, string_value, start_index, is_sticky)) |match| {
        const update_last_index = use_last_index and (is_global or is_sticky);
        if (update_last_index) {
            const next_value = if (match.index + match.len <= @as(usize, @intCast(std.math.maxInt(i32))))
                core.JSValue.int32(@intCast(match.index + match.len))
            else
                core.JSValue.float64(@floatFromInt(match.index + match.len));
            try setValuePropertyStrict(ctx, output, global, regexp_value, core.atom.ids.lastIndex, next_value, caller_function, caller_frame);
        }
        return try createRegExpMatchArrayFromValue(ctx.runtime, global, string_value, match, has_indices);
    }
    const update_last_index = use_last_index and (is_global or is_sticky);
    if (update_last_index) {
        try setValuePropertyStrict(ctx, output, global, regexp_value, core.atom.ids.lastIndex, core.JSValue.int32(0), caller_function, caller_frame);
    }
    return core.JSValue.nullValue();
}

pub fn qjsRegExpExecAnchoredPropertyFallback(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    regexp_value: core.JSValue,
    source: []const u8,
    string_value: core.JSValue,
    use_last_index: bool,
    is_global: bool,
    is_sticky: bool,
    has_indices: bool,
    input_len: usize,
    start_index: usize,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    const update_last_index = use_last_index and (is_global or is_sticky);
    if (start_index != 0 or !anchoredBinaryPropertyMatches(source, string_value)) {
        if (update_last_index) try setValuePropertyStrict(ctx, output, global, regexp_value, core.atom.ids.lastIndex, core.JSValue.int32(0), caller_function, caller_frame);
        return core.JSValue.nullValue();
    }

    if (update_last_index) {
        const next_value = if (input_len <= @as(usize, @intCast(std.math.maxInt(i32))))
            core.JSValue.int32(@intCast(input_len))
        else
            core.JSValue.float64(@floatFromInt(input_len));
        try setValuePropertyStrict(ctx, output, global, regexp_value, core.atom.ids.lastIndex, next_value, caller_function, caller_frame);
    }

    return try createRegExpMatchArrayFromValue(ctx.runtime, global, string_value, .{
        .index = 0,
        .len = input_len,
        .capture_count = 0,
    }, has_indices);
}

pub fn regexpSourceUsesZigPropertyFallback(source: []const u8, flags: []const u8) bool {
    if (regExpFlagsContain(flags, 'v')) {
        if (isAnchoredRgiEmojiSource(source)) return true;
        if (stringPropertyEscapePattern(source)) |name| return std.mem.eql(u8, name, "RGI_Emoji");
    }
    if ((regExpFlagsContain(flags, 'u') or regExpFlagsContain(flags, 'v')) and unicodePropertyOnlyClassSource(source)) return true;
    if (anchoredBinaryPropertyName(source)) |name| return isUnknownScriptName(name);
    if (propertyEscapePattern(source)) |parsed| return isUnknownScriptName(parsed.name);
    return false;
}

pub const PropertyEscapePattern = struct {
    name: []const u8,
    positive: bool,
};

pub const UnicodePropertyRunPattern = struct {
    name: []const u8,
    positive: bool,
    predicate: FastUnicodePropertyPredicate = .generic,
};

pub const FastUnicodePropertyPredicate = enum {
    generic,
    greek_script,
};

pub fn simpleUnicodePropertyRunTestFast(source: []const u8, flags: []const u8, string_value: core.JSValue) ?bool {
    const parsed = unicodePropertyRunPattern(source, flags) orelse return null;
    const header = string_value.refHeader() orelse return null;
    if (!string_value.isString()) return null;
    const string_object: *core.string.String = @fieldParentPtr("header", header);
    switch (string_object.resolveData()) {
        .latin1 => |bytes| {
            for (bytes) |byte| {
                if (unicodePropertyRunCodePointMatches(parsed, byte)) return true;
            }
        },
        .utf16 => |units| {
            var index: usize = 0;
            while (index < units.len) {
                const code_point = readUtf16CodePoint(units, &index);
                if (unicodePropertyRunCodePointMatches(parsed, code_point)) return true;
            }
        },
    }
    return false;
}

pub fn unicodePropertyRunPattern(source: []const u8, flags: []const u8) ?UnicodePropertyRunPattern {
    if (flags.len != 1 or flags[0] != 'u') return null;
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

    var scan = prefix_len;
    while (scan < source.len and source[scan] != '}') : (scan += 1) {}
    if (scan == prefix_len or scan >= source.len or source[scan] != '}') return null;
    const name = source[prefix_len..scan];
    if (!isRuntimeSupportedBinaryPropertyName(name)) return null;
    const predicate = fastUnicodePropertyPredicate(name);
    scan += 1;
    if (scan >= source.len or source[scan] != '+') return null;
    scan += 1;
    if (scan == source.len) return .{ .name = name, .positive = positive, .predicate = predicate };
    if (std.mem.eql(u8, source[scan..], "[0-9]?")) return .{ .name = name, .positive = positive, .predicate = predicate };
    return null;
}

pub fn fastUnicodePropertyPredicate(name: []const u8) FastUnicodePropertyPredicate {
    if (std.mem.eql(u8, name, "Script=Greek") or
        std.mem.eql(u8, name, "Script=Grek") or
        std.mem.eql(u8, name, "sc=Greek") or
        std.mem.eql(u8, name, "sc=Grek"))
    {
        return .greek_script;
    }
    return .generic;
}

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
    return builtins.date.methodCallArgs(ctx.runtime, this_value, method_id, args) catch |err| switch (err) {
        error.TypeError => return throwTypeErrorMessage(ctx, global, "not a Date object"),
        error.RangeError => return throwRangeErrorMessage(ctx, global, "Date value is NaN"),
        else => err,
    };
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
    return exactScriptExtensionsAliasTarget(name) != null or
        std.mem.eql(u8, name, "ASCII") or
        std.mem.eql(u8, name, "ASCII_Hex_Digit") or
        std.mem.eql(u8, name, "AHex") or
        std.mem.eql(u8, name, "Cased") or
        std.mem.eql(u8, name, "Hex_Digit") or
        std.mem.eql(u8, name, "Hex") or
        std.mem.eql(u8, name, "Dash") or
        std.mem.eql(u8, name, "Bidi_Mirrored") or
        std.mem.eql(u8, name, "Bidi_M") or
        std.mem.eql(u8, name, "Bidi_Control") or
        std.mem.eql(u8, name, "Bidi_C") or
        std.mem.eql(u8, name, "Deprecated") or
        std.mem.eql(u8, name, "Dep") or
        std.mem.eql(u8, name, "Diacritic") or
        std.mem.eql(u8, name, "Dia") or
        std.mem.eql(u8, name, "IDS_Binary_Operator") or
        std.mem.eql(u8, name, "IDSB") or
        std.mem.eql(u8, name, "IDS_Trinary_Operator") or
        std.mem.eql(u8, name, "IDST") or
        std.mem.eql(u8, name, "ID_Start") or
        std.mem.eql(u8, name, "IDS") or
        std.mem.eql(u8, name, "ID_Continue") or
        std.mem.eql(u8, name, "IDC") or
        std.mem.eql(u8, name, "XID_Start") or
        std.mem.eql(u8, name, "XIDS") or
        std.mem.eql(u8, name, "XID_Continue") or
        std.mem.eql(u8, name, "XIDC") or
        std.mem.eql(u8, name, "Join_Control") or
        std.mem.eql(u8, name, "Join_C") or
        std.mem.eql(u8, name, "Radical") or
        std.mem.eql(u8, name, "Variation_Selector") or
        std.mem.eql(u8, name, "VS") or
        std.mem.eql(u8, name, "Quotation_Mark") or
        std.mem.eql(u8, name, "QMark") or
        std.mem.eql(u8, name, "Pattern_White_Space") or
        std.mem.eql(u8, name, "Pat_WS") or
        std.mem.eql(u8, name, "White_Space") or
        std.mem.eql(u8, name, "space") or
        std.mem.eql(u8, name, "Regional_Indicator") or
        std.mem.eql(u8, name, "RI") or
        std.mem.eql(u8, name, "Logical_Order_Exception") or
        std.mem.eql(u8, name, "LOE") or
        std.mem.eql(u8, name, "Noncharacter_Code_Point") or
        std.mem.eql(u8, name, "NChar") or
        std.mem.eql(u8, name, "Pattern_Syntax") or
        std.mem.eql(u8, name, "Pat_Syn") or
        std.mem.eql(u8, name, "Default_Ignorable_Code_Point") or
        std.mem.eql(u8, name, "DI") or
        std.mem.eql(u8, name, "Alphabetic") or
        std.mem.eql(u8, name, "Alpha") or
        std.mem.eql(u8, name, "Case_Ignorable") or
        std.mem.eql(u8, name, "CI") or
        std.mem.eql(u8, name, "Changes_When_Casemapped") or
        std.mem.eql(u8, name, "CWCM") or
        std.mem.eql(u8, name, "Changes_When_Casefolded") or
        std.mem.eql(u8, name, "CWCF") or
        std.mem.eql(u8, name, "Changes_When_Lowercased") or
        std.mem.eql(u8, name, "CWL") or
        std.mem.eql(u8, name, "Changes_When_Titlecased") or
        std.mem.eql(u8, name, "CWT") or
        std.mem.eql(u8, name, "Changes_When_Uppercased") or
        std.mem.eql(u8, name, "CWU") or
        std.mem.eql(u8, name, "Changes_When_NFKC_Casefolded") or
        std.mem.eql(u8, name, "CWKCF") or
        std.mem.eql(u8, name, "Cased_Letter") or
        std.mem.eql(u8, name, "LC") or
        std.mem.eql(u8, name, "General_Category=Cased_Letter") or
        std.mem.eql(u8, name, "General_Category=LC") or
        std.mem.eql(u8, name, "gc=Cased_Letter") or
        std.mem.eql(u8, name, "gc=LC") or
        std.mem.eql(u8, name, "Letter") or
        std.mem.eql(u8, name, "L") or
        std.mem.eql(u8, name, "General_Category=Letter") or
        std.mem.eql(u8, name, "General_Category=L") or
        std.mem.eql(u8, name, "gc=Letter") or
        std.mem.eql(u8, name, "gc=L") or
        std.mem.eql(u8, name, "Lowercase") or
        std.mem.eql(u8, name, "Lower") or
        std.mem.eql(u8, name, "Lowercase_Letter") or
        std.mem.eql(u8, name, "Ll") or
        std.mem.eql(u8, name, "General_Category=Lowercase_Letter") or
        std.mem.eql(u8, name, "General_Category=Ll") or
        std.mem.eql(u8, name, "gc=Lowercase_Letter") or
        std.mem.eql(u8, name, "gc=Ll") or
        std.mem.eql(u8, name, "Uppercase") or
        std.mem.eql(u8, name, "Upper") or
        std.mem.eql(u8, name, "Uppercase_Letter") or
        std.mem.eql(u8, name, "Lu") or
        std.mem.eql(u8, name, "General_Category=Uppercase_Letter") or
        std.mem.eql(u8, name, "General_Category=Lu") or
        std.mem.eql(u8, name, "gc=Uppercase_Letter") or
        std.mem.eql(u8, name, "gc=Lu") or
        std.mem.eql(u8, name, "Titlecase_Letter") or
        std.mem.eql(u8, name, "Lt") or
        std.mem.eql(u8, name, "General_Category=Titlecase_Letter") or
        std.mem.eql(u8, name, "General_Category=Lt") or
        std.mem.eql(u8, name, "gc=Titlecase_Letter") or
        std.mem.eql(u8, name, "gc=Lt") or
        std.mem.eql(u8, name, "Format") or
        std.mem.eql(u8, name, "Cf") or
        std.mem.eql(u8, name, "General_Category=Format") or
        std.mem.eql(u8, name, "General_Category=Cf") or
        std.mem.eql(u8, name, "gc=Format") or
        std.mem.eql(u8, name, "gc=Cf") or
        std.mem.eql(u8, name, "Unassigned") or
        std.mem.eql(u8, name, "Cn") or
        std.mem.eql(u8, name, "General_Category=Unassigned") or
        std.mem.eql(u8, name, "General_Category=Cn") or
        std.mem.eql(u8, name, "gc=Unassigned") or
        std.mem.eql(u8, name, "gc=Cn") or
        std.mem.eql(u8, name, "Other") or
        std.mem.eql(u8, name, "C") or
        std.mem.eql(u8, name, "General_Category=Other") or
        std.mem.eql(u8, name, "General_Category=C") or
        std.mem.eql(u8, name, "gc=Other") or
        std.mem.eql(u8, name, "gc=C") or
        std.mem.eql(u8, name, "Decimal_Number") or
        std.mem.eql(u8, name, "Nd") or
        std.mem.eql(u8, name, "digit") or
        std.mem.eql(u8, name, "General_Category=Decimal_Number") or
        std.mem.eql(u8, name, "General_Category=Nd") or
        std.mem.eql(u8, name, "General_Category=digit") or
        std.mem.eql(u8, name, "gc=Decimal_Number") or
        std.mem.eql(u8, name, "gc=Nd") or
        std.mem.eql(u8, name, "gc=digit") or
        std.mem.eql(u8, name, "Other_Number") or
        std.mem.eql(u8, name, "No") or
        std.mem.eql(u8, name, "General_Category=Other_Number") or
        std.mem.eql(u8, name, "General_Category=No") or
        std.mem.eql(u8, name, "gc=Other_Number") or
        std.mem.eql(u8, name, "gc=No") or
        std.mem.eql(u8, name, "Number") or
        std.mem.eql(u8, name, "N") or
        std.mem.eql(u8, name, "General_Category=Number") or
        std.mem.eql(u8, name, "General_Category=N") or
        std.mem.eql(u8, name, "gc=Number") or
        std.mem.eql(u8, name, "gc=N") or
        std.mem.eql(u8, name, "Math_Symbol") or
        std.mem.eql(u8, name, "Sm") or
        std.mem.eql(u8, name, "General_Category=Math_Symbol") or
        std.mem.eql(u8, name, "General_Category=Sm") or
        std.mem.eql(u8, name, "gc=Math_Symbol") or
        std.mem.eql(u8, name, "gc=Sm") or
        std.mem.eql(u8, name, "Other_Symbol") or
        std.mem.eql(u8, name, "So") or
        std.mem.eql(u8, name, "General_Category=Other_Symbol") or
        std.mem.eql(u8, name, "General_Category=So") or
        std.mem.eql(u8, name, "gc=Other_Symbol") or
        std.mem.eql(u8, name, "gc=So") or
        std.mem.eql(u8, name, "Symbol") or
        std.mem.eql(u8, name, "S") or
        std.mem.eql(u8, name, "General_Category=Symbol") or
        std.mem.eql(u8, name, "General_Category=S") or
        std.mem.eql(u8, name, "gc=Symbol") or
        std.mem.eql(u8, name, "gc=S") or
        std.mem.eql(u8, name, "Close_Punctuation") or
        std.mem.eql(u8, name, "Pe") or
        std.mem.eql(u8, name, "General_Category=Close_Punctuation") or
        std.mem.eql(u8, name, "General_Category=Pe") or
        std.mem.eql(u8, name, "gc=Close_Punctuation") or
        std.mem.eql(u8, name, "gc=Pe") or
        std.mem.eql(u8, name, "Open_Punctuation") or
        std.mem.eql(u8, name, "Ps") or
        std.mem.eql(u8, name, "General_Category=Open_Punctuation") or
        std.mem.eql(u8, name, "General_Category=Ps") or
        std.mem.eql(u8, name, "gc=Open_Punctuation") or
        std.mem.eql(u8, name, "gc=Ps") or
        std.mem.eql(u8, name, "Other_Punctuation") or
        std.mem.eql(u8, name, "Po") or
        std.mem.eql(u8, name, "General_Category=Other_Punctuation") or
        std.mem.eql(u8, name, "General_Category=Po") or
        std.mem.eql(u8, name, "gc=Other_Punctuation") or
        std.mem.eql(u8, name, "gc=Po") or
        std.mem.eql(u8, name, "Punctuation") or
        std.mem.eql(u8, name, "P") or
        std.mem.eql(u8, name, "punct") or
        std.mem.eql(u8, name, "General_Category=Punctuation") or
        std.mem.eql(u8, name, "General_Category=P") or
        std.mem.eql(u8, name, "General_Category=punct") or
        std.mem.eql(u8, name, "gc=Punctuation") or
        std.mem.eql(u8, name, "gc=P") or
        std.mem.eql(u8, name, "gc=punct") or
        std.mem.eql(u8, name, "Spacing_Mark") or
        std.mem.eql(u8, name, "Mc") or
        std.mem.eql(u8, name, "Nonspacing_Mark") or
        std.mem.eql(u8, name, "Mn") or
        std.mem.eql(u8, name, "General_Category=Nonspacing_Mark") or
        std.mem.eql(u8, name, "General_Category=Mn") or
        std.mem.eql(u8, name, "gc=Nonspacing_Mark") or
        std.mem.eql(u8, name, "gc=Mn") or
        std.mem.eql(u8, name, "Mark") or
        std.mem.eql(u8, name, "Combining_Mark") or
        std.mem.eql(u8, name, "M") or
        std.mem.eql(u8, name, "General_Category=Mark") or
        std.mem.eql(u8, name, "General_Category=Combining_Mark") or
        std.mem.eql(u8, name, "General_Category=M") or
        std.mem.eql(u8, name, "gc=Mark") or
        std.mem.eql(u8, name, "gc=Combining_Mark") or
        std.mem.eql(u8, name, "gc=M") or
        std.mem.eql(u8, name, "General_Category=Spacing_Mark") or
        std.mem.eql(u8, name, "General_Category=Mc") or
        std.mem.eql(u8, name, "gc=Spacing_Mark") or
        std.mem.eql(u8, name, "gc=Mc") or
        std.mem.eql(u8, name, "Modifier_Letter") or
        std.mem.eql(u8, name, "Lm") or
        std.mem.eql(u8, name, "General_Category=Modifier_Letter") or
        std.mem.eql(u8, name, "General_Category=Lm") or
        std.mem.eql(u8, name, "gc=Modifier_Letter") or
        std.mem.eql(u8, name, "gc=Lm") or
        std.mem.eql(u8, name, "Other_Letter") or
        std.mem.eql(u8, name, "Lo") or
        std.mem.eql(u8, name, "General_Category=Other_Letter") or
        std.mem.eql(u8, name, "General_Category=Lo") or
        std.mem.eql(u8, name, "gc=Other_Letter") or
        std.mem.eql(u8, name, "gc=Lo") or
        std.mem.eql(u8, name, "Control") or
        std.mem.eql(u8, name, "Cc") or
        std.mem.eql(u8, name, "cntrl") or
        std.mem.eql(u8, name, "General_Category=Control") or
        std.mem.eql(u8, name, "General_Category=Cc") or
        std.mem.eql(u8, name, "General_Category=cntrl") or
        std.mem.eql(u8, name, "gc=Control") or
        std.mem.eql(u8, name, "gc=Cc") or
        std.mem.eql(u8, name, "gc=cntrl") or
        std.mem.eql(u8, name, "Connector_Punctuation") or
        std.mem.eql(u8, name, "Pc") or
        std.mem.eql(u8, name, "General_Category=Connector_Punctuation") or
        std.mem.eql(u8, name, "General_Category=Pc") or
        std.mem.eql(u8, name, "gc=Connector_Punctuation") or
        std.mem.eql(u8, name, "gc=Pc") or
        std.mem.eql(u8, name, "Letter_Number") or
        std.mem.eql(u8, name, "Nl") or
        std.mem.eql(u8, name, "General_Category=Letter_Number") or
        std.mem.eql(u8, name, "General_Category=Nl") or
        std.mem.eql(u8, name, "gc=Letter_Number") or
        std.mem.eql(u8, name, "gc=Nl") or
        std.mem.eql(u8, name, "Separator") or
        std.mem.eql(u8, name, "Z") or
        std.mem.eql(u8, name, "General_Category=Separator") or
        std.mem.eql(u8, name, "General_Category=Z") or
        std.mem.eql(u8, name, "gc=Separator") or
        std.mem.eql(u8, name, "gc=Z") or
        std.mem.eql(u8, name, "Line_Separator") or
        std.mem.eql(u8, name, "Zl") or
        std.mem.eql(u8, name, "General_Category=Line_Separator") or
        std.mem.eql(u8, name, "General_Category=Zl") or
        std.mem.eql(u8, name, "gc=Line_Separator") or
        std.mem.eql(u8, name, "gc=Zl") or
        std.mem.eql(u8, name, "Paragraph_Separator") or
        std.mem.eql(u8, name, "Zp") or
        std.mem.eql(u8, name, "General_Category=Paragraph_Separator") or
        std.mem.eql(u8, name, "General_Category=Zp") or
        std.mem.eql(u8, name, "gc=Paragraph_Separator") or
        std.mem.eql(u8, name, "gc=Zp") or
        std.mem.eql(u8, name, "Space_Separator") or
        std.mem.eql(u8, name, "Zs") or
        std.mem.eql(u8, name, "General_Category=Space_Separator") or
        std.mem.eql(u8, name, "General_Category=Zs") or
        std.mem.eql(u8, name, "gc=Space_Separator") or
        std.mem.eql(u8, name, "gc=Zs") or
        std.mem.eql(u8, name, "Private_Use") or
        std.mem.eql(u8, name, "Co") or
        std.mem.eql(u8, name, "General_Category=Private_Use") or
        std.mem.eql(u8, name, "General_Category=Co") or
        std.mem.eql(u8, name, "gc=Private_Use") or
        std.mem.eql(u8, name, "gc=Co") or
        std.mem.eql(u8, name, "Surrogate") or
        std.mem.eql(u8, name, "Cs") or
        std.mem.eql(u8, name, "General_Category=Surrogate") or
        std.mem.eql(u8, name, "General_Category=Cs") or
        std.mem.eql(u8, name, "gc=Surrogate") or
        std.mem.eql(u8, name, "gc=Cs") or
        std.mem.eql(u8, name, "Enclosing_Mark") or
        std.mem.eql(u8, name, "Me") or
        std.mem.eql(u8, name, "General_Category=Enclosing_Mark") or
        std.mem.eql(u8, name, "General_Category=Me") or
        std.mem.eql(u8, name, "gc=Enclosing_Mark") or
        std.mem.eql(u8, name, "gc=Me") or
        std.mem.eql(u8, name, "Currency_Symbol") or
        std.mem.eql(u8, name, "Sc") or
        std.mem.eql(u8, name, "General_Category=Currency_Symbol") or
        std.mem.eql(u8, name, "General_Category=Sc") or
        std.mem.eql(u8, name, "gc=Currency_Symbol") or
        std.mem.eql(u8, name, "gc=Sc") or
        std.mem.eql(u8, name, "Modifier_Symbol") or
        std.mem.eql(u8, name, "Sk") or
        std.mem.eql(u8, name, "General_Category=Modifier_Symbol") or
        std.mem.eql(u8, name, "General_Category=Sk") or
        std.mem.eql(u8, name, "gc=Modifier_Symbol") or
        std.mem.eql(u8, name, "gc=Sk") or
        std.mem.eql(u8, name, "Dash_Punctuation") or
        std.mem.eql(u8, name, "Pd") or
        std.mem.eql(u8, name, "General_Category=Dash_Punctuation") or
        std.mem.eql(u8, name, "General_Category=Pd") or
        std.mem.eql(u8, name, "gc=Dash_Punctuation") or
        std.mem.eql(u8, name, "gc=Pd") or
        std.mem.eql(u8, name, "Initial_Punctuation") or
        std.mem.eql(u8, name, "Pi") or
        std.mem.eql(u8, name, "General_Category=Initial_Punctuation") or
        std.mem.eql(u8, name, "General_Category=Pi") or
        std.mem.eql(u8, name, "gc=Initial_Punctuation") or
        std.mem.eql(u8, name, "gc=Pi") or
        std.mem.eql(u8, name, "Final_Punctuation") or
        std.mem.eql(u8, name, "Pf") or
        std.mem.eql(u8, name, "General_Category=Final_Punctuation") or
        std.mem.eql(u8, name, "General_Category=Pf") or
        std.mem.eql(u8, name, "gc=Final_Punctuation") or
        std.mem.eql(u8, name, "gc=Pf") or
        std.mem.eql(u8, name, "Script=Adlam") or
        std.mem.eql(u8, name, "Script=Adlm") or
        std.mem.eql(u8, name, "sc=Adlam") or
        std.mem.eql(u8, name, "sc=Adlm") or
        std.mem.eql(u8, name, "Script_Extensions=Adlam") or
        std.mem.eql(u8, name, "Script_Extensions=Adlm") or
        std.mem.eql(u8, name, "scx=Adlam") or
        std.mem.eql(u8, name, "scx=Adlm") or
        std.mem.eql(u8, name, "Script=Anatolian_Hieroglyphs") or
        std.mem.eql(u8, name, "Script=Hluw") or
        std.mem.eql(u8, name, "sc=Anatolian_Hieroglyphs") or
        std.mem.eql(u8, name, "sc=Hluw") or
        std.mem.eql(u8, name, "Script=Ahom") or
        std.mem.eql(u8, name, "sc=Ahom") or
        std.mem.eql(u8, name, "Script_Extensions=Ahom") or
        std.mem.eql(u8, name, "scx=Ahom") or
        std.mem.eql(u8, name, "Script=Arabic") or
        std.mem.eql(u8, name, "Script=Arab") or
        std.mem.eql(u8, name, "sc=Arabic") or
        std.mem.eql(u8, name, "sc=Arab") or
        std.mem.eql(u8, name, "Script_Extensions=Arabic") or
        std.mem.eql(u8, name, "Script_Extensions=Arab") or
        std.mem.eql(u8, name, "scx=Arabic") or
        std.mem.eql(u8, name, "scx=Arab") or
        std.mem.eql(u8, name, "Script=Armenian") or
        std.mem.eql(u8, name, "Script=Armn") or
        std.mem.eql(u8, name, "sc=Armenian") or
        std.mem.eql(u8, name, "sc=Armn") or
        std.mem.eql(u8, name, "Script_Extensions=Armenian") or
        std.mem.eql(u8, name, "Script_Extensions=Armn") or
        std.mem.eql(u8, name, "scx=Armenian") or
        std.mem.eql(u8, name, "scx=Armn") or
        std.mem.eql(u8, name, "Script=Avestan") or
        std.mem.eql(u8, name, "Script=Avst") or
        std.mem.eql(u8, name, "sc=Avestan") or
        std.mem.eql(u8, name, "sc=Avst") or
        std.mem.eql(u8, name, "Script_Extensions=Avestan") or
        std.mem.eql(u8, name, "Script_Extensions=Avst") or
        std.mem.eql(u8, name, "scx=Avestan") or
        std.mem.eql(u8, name, "scx=Avst") or
        std.mem.eql(u8, name, "Script=Bassa_Vah") or
        std.mem.eql(u8, name, "Script=Bass") or
        std.mem.eql(u8, name, "sc=Bassa_Vah") or
        std.mem.eql(u8, name, "sc=Bass") or
        std.mem.eql(u8, name, "Script=Balinese") or
        std.mem.eql(u8, name, "Script=Bali") or
        std.mem.eql(u8, name, "sc=Balinese") or
        std.mem.eql(u8, name, "sc=Bali") or
        std.mem.eql(u8, name, "Script=Bamum") or
        std.mem.eql(u8, name, "Script=Bamu") or
        std.mem.eql(u8, name, "sc=Bamum") or
        std.mem.eql(u8, name, "sc=Bamu") or
        std.mem.eql(u8, name, "Script=Beria_Erfe") or
        std.mem.eql(u8, name, "Script=Berf") or
        std.mem.eql(u8, name, "sc=Beria_Erfe") or
        std.mem.eql(u8, name, "sc=Berf") or
        std.mem.eql(u8, name, "Script=Batak") or
        std.mem.eql(u8, name, "Script=Batk") or
        std.mem.eql(u8, name, "sc=Batak") or
        std.mem.eql(u8, name, "sc=Batk") or
        std.mem.eql(u8, name, "Script_Extensions=Batak") or
        std.mem.eql(u8, name, "Script_Extensions=Batk") or
        std.mem.eql(u8, name, "scx=Batak") or
        std.mem.eql(u8, name, "scx=Batk") or
        std.mem.eql(u8, name, "Script=Bengali") or
        std.mem.eql(u8, name, "Script=Beng") or
        std.mem.eql(u8, name, "sc=Bengali") or
        std.mem.eql(u8, name, "sc=Beng") or
        std.mem.eql(u8, name, "Script_Extensions=Bengali") or
        std.mem.eql(u8, name, "Script_Extensions=Beng") or
        std.mem.eql(u8, name, "scx=Bengali") or
        std.mem.eql(u8, name, "scx=Beng") or
        std.mem.eql(u8, name, "Script=Bhaiksuki") or
        std.mem.eql(u8, name, "Script=Bhks") or
        std.mem.eql(u8, name, "sc=Bhaiksuki") or
        std.mem.eql(u8, name, "sc=Bhks") or
        std.mem.eql(u8, name, "Script=Bopomofo") or
        std.mem.eql(u8, name, "Script=Bopo") or
        std.mem.eql(u8, name, "sc=Bopomofo") or
        std.mem.eql(u8, name, "sc=Bopo") or
        std.mem.eql(u8, name, "Script_Extensions=Bopomofo") or
        std.mem.eql(u8, name, "Script_Extensions=Bopo") or
        std.mem.eql(u8, name, "scx=Bopomofo") or
        std.mem.eql(u8, name, "scx=Bopo") or
        std.mem.eql(u8, name, "Script=Brahmi") or
        std.mem.eql(u8, name, "Script=Brah") or
        std.mem.eql(u8, name, "sc=Brahmi") or
        std.mem.eql(u8, name, "sc=Brah") or
        std.mem.eql(u8, name, "Script=Braille") or
        std.mem.eql(u8, name, "Script=Brai") or
        std.mem.eql(u8, name, "sc=Braille") or
        std.mem.eql(u8, name, "sc=Brai") or
        std.mem.eql(u8, name, "Script=Buginese") or
        std.mem.eql(u8, name, "Script=Bugi") or
        std.mem.eql(u8, name, "sc=Buginese") or
        std.mem.eql(u8, name, "sc=Bugi") or
        std.mem.eql(u8, name, "Script_Extensions=Buginese") or
        std.mem.eql(u8, name, "Script_Extensions=Bugi") or
        std.mem.eql(u8, name, "scx=Buginese") or
        std.mem.eql(u8, name, "scx=Bugi") or
        std.mem.eql(u8, name, "Script=Buhid") or
        std.mem.eql(u8, name, "Script=Buhd") or
        std.mem.eql(u8, name, "sc=Buhid") or
        std.mem.eql(u8, name, "sc=Buhd") or
        std.mem.eql(u8, name, "Script_Extensions=Buhid") or
        std.mem.eql(u8, name, "Script_Extensions=Buhd") or
        std.mem.eql(u8, name, "scx=Buhid") or
        std.mem.eql(u8, name, "scx=Buhd") or
        std.mem.eql(u8, name, "Script=Carian") or
        std.mem.eql(u8, name, "Script=Cari") or
        std.mem.eql(u8, name, "sc=Carian") or
        std.mem.eql(u8, name, "sc=Cari") or
        std.mem.eql(u8, name, "Script_Extensions=Carian") or
        std.mem.eql(u8, name, "Script_Extensions=Cari") or
        std.mem.eql(u8, name, "scx=Carian") or
        std.mem.eql(u8, name, "scx=Cari") or
        std.mem.eql(u8, name, "Script=Caucasian_Albanian") or
        std.mem.eql(u8, name, "Script=Aghb") or
        std.mem.eql(u8, name, "sc=Caucasian_Albanian") or
        std.mem.eql(u8, name, "sc=Aghb") or
        std.mem.eql(u8, name, "Script_Extensions=Caucasian_Albanian") or
        std.mem.eql(u8, name, "Script_Extensions=Aghb") or
        std.mem.eql(u8, name, "scx=Caucasian_Albanian") or
        std.mem.eql(u8, name, "scx=Aghb") or
        std.mem.eql(u8, name, "Script=Canadian_Aboriginal") or
        std.mem.eql(u8, name, "Script=Cans") or
        std.mem.eql(u8, name, "sc=Canadian_Aboriginal") or
        std.mem.eql(u8, name, "sc=Cans") or
        std.mem.eql(u8, name, "Script=Common") or
        std.mem.eql(u8, name, "Script=Zyyy") or
        std.mem.eql(u8, name, "sc=Common") or
        std.mem.eql(u8, name, "sc=Zyyy") or
        std.mem.eql(u8, name, "Script_Extensions=Common") or
        std.mem.eql(u8, name, "Script_Extensions=Zyyy") or
        std.mem.eql(u8, name, "scx=Common") or
        std.mem.eql(u8, name, "scx=Zyyy") or
        std.mem.eql(u8, name, "Script=Chakma") or
        std.mem.eql(u8, name, "Script=Cakm") or
        std.mem.eql(u8, name, "sc=Chakma") or
        std.mem.eql(u8, name, "sc=Cakm") or
        std.mem.eql(u8, name, "Script_Extensions=Chakma") or
        std.mem.eql(u8, name, "Script_Extensions=Cakm") or
        std.mem.eql(u8, name, "scx=Chakma") or
        std.mem.eql(u8, name, "scx=Cakm") or
        std.mem.eql(u8, name, "Script=Cham") or
        std.mem.eql(u8, name, "sc=Cham") or
        std.mem.eql(u8, name, "Script=Cherokee") or
        std.mem.eql(u8, name, "Script=Cher") or
        std.mem.eql(u8, name, "sc=Cherokee") or
        std.mem.eql(u8, name, "sc=Cher") or
        std.mem.eql(u8, name, "Script_Extensions=Cherokee") or
        std.mem.eql(u8, name, "Script_Extensions=Cher") or
        std.mem.eql(u8, name, "scx=Cherokee") or
        std.mem.eql(u8, name, "scx=Cher") or
        std.mem.eql(u8, name, "Script=Chorasmian") or
        std.mem.eql(u8, name, "Script=Chrs") or
        std.mem.eql(u8, name, "sc=Chorasmian") or
        std.mem.eql(u8, name, "sc=Chrs") or
        std.mem.eql(u8, name, "Script=Coptic") or
        std.mem.eql(u8, name, "Script=Copt") or
        std.mem.eql(u8, name, "Script=Qaac") or
        std.mem.eql(u8, name, "sc=Coptic") or
        std.mem.eql(u8, name, "sc=Copt") or
        std.mem.eql(u8, name, "sc=Qaac") or
        std.mem.eql(u8, name, "Script_Extensions=Coptic") or
        std.mem.eql(u8, name, "Script_Extensions=Copt") or
        std.mem.eql(u8, name, "Script_Extensions=Qaac") or
        std.mem.eql(u8, name, "scx=Coptic") or
        std.mem.eql(u8, name, "scx=Copt") or
        std.mem.eql(u8, name, "scx=Qaac") or
        std.mem.eql(u8, name, "Script=Cyrillic") or
        std.mem.eql(u8, name, "Script=Cyrl") or
        std.mem.eql(u8, name, "sc=Cyrillic") or
        std.mem.eql(u8, name, "sc=Cyrl") or
        std.mem.eql(u8, name, "Script_Extensions=Cyrillic") or
        std.mem.eql(u8, name, "Script_Extensions=Cyrl") or
        std.mem.eql(u8, name, "scx=Cyrillic") or
        std.mem.eql(u8, name, "scx=Cyrl") or
        std.mem.eql(u8, name, "Script=Cuneiform") or
        std.mem.eql(u8, name, "Script=Xsux") or
        std.mem.eql(u8, name, "sc=Cuneiform") or
        std.mem.eql(u8, name, "sc=Xsux") or
        std.mem.eql(u8, name, "Script=Cypro_Minoan") or
        std.mem.eql(u8, name, "Script=Cpmn") or
        std.mem.eql(u8, name, "sc=Cypro_Minoan") or
        std.mem.eql(u8, name, "sc=Cpmn") or
        std.mem.eql(u8, name, "Script_Extensions=Cypro_Minoan") or
        std.mem.eql(u8, name, "Script_Extensions=Cpmn") or
        std.mem.eql(u8, name, "scx=Cypro_Minoan") or
        std.mem.eql(u8, name, "scx=Cpmn") or
        std.mem.eql(u8, name, "Script=Cypriot") or
        std.mem.eql(u8, name, "Script=Cprt") or
        std.mem.eql(u8, name, "sc=Cypriot") or
        std.mem.eql(u8, name, "sc=Cprt") or
        std.mem.eql(u8, name, "Script_Extensions=Cypriot") or
        std.mem.eql(u8, name, "Script_Extensions=Cprt") or
        std.mem.eql(u8, name, "scx=Cypriot") or
        std.mem.eql(u8, name, "scx=Cprt") or
        std.mem.eql(u8, name, "Script=Devanagari") or
        std.mem.eql(u8, name, "Script=Deva") or
        std.mem.eql(u8, name, "sc=Devanagari") or
        std.mem.eql(u8, name, "sc=Deva") or
        std.mem.eql(u8, name, "Script_Extensions=Devanagari") or
        std.mem.eql(u8, name, "Script_Extensions=Deva") or
        std.mem.eql(u8, name, "scx=Devanagari") or
        std.mem.eql(u8, name, "scx=Deva") or
        std.mem.eql(u8, name, "Script=Deseret") or
        std.mem.eql(u8, name, "Script=Dsrt") or
        std.mem.eql(u8, name, "sc=Deseret") or
        std.mem.eql(u8, name, "sc=Dsrt") or
        std.mem.eql(u8, name, "Script=Dives_Akuru") or
        std.mem.eql(u8, name, "Script=Diak") or
        std.mem.eql(u8, name, "sc=Dives_Akuru") or
        std.mem.eql(u8, name, "sc=Diak") or
        std.mem.eql(u8, name, "Script_Extensions=Dives_Akuru") or
        std.mem.eql(u8, name, "Script_Extensions=Diak") or
        std.mem.eql(u8, name, "scx=Dives_Akuru") or
        std.mem.eql(u8, name, "scx=Diak") or
        std.mem.eql(u8, name, "Script=Duployan") or
        std.mem.eql(u8, name, "Script=Dupl") or
        std.mem.eql(u8, name, "sc=Duployan") or
        std.mem.eql(u8, name, "sc=Dupl") or
        std.mem.eql(u8, name, "Script_Extensions=Duployan") or
        std.mem.eql(u8, name, "Script_Extensions=Dupl") or
        std.mem.eql(u8, name, "scx=Duployan") or
        std.mem.eql(u8, name, "scx=Dupl") or
        std.mem.eql(u8, name, "Script=Dogra") or
        std.mem.eql(u8, name, "Script=Dogr") or
        std.mem.eql(u8, name, "sc=Dogra") or
        std.mem.eql(u8, name, "sc=Dogr") or
        std.mem.eql(u8, name, "Script_Extensions=Dogra") or
        std.mem.eql(u8, name, "Script_Extensions=Dogr") or
        std.mem.eql(u8, name, "scx=Dogra") or
        std.mem.eql(u8, name, "scx=Dogr") or
        std.mem.eql(u8, name, "Script=Elbasan") or
        std.mem.eql(u8, name, "Script=Elba") or
        std.mem.eql(u8, name, "sc=Elbasan") or
        std.mem.eql(u8, name, "sc=Elba") or
        std.mem.eql(u8, name, "Script_Extensions=Elbasan") or
        std.mem.eql(u8, name, "Script_Extensions=Elba") or
        std.mem.eql(u8, name, "scx=Elbasan") or
        std.mem.eql(u8, name, "scx=Elba") or
        std.mem.eql(u8, name, "Script=Elymaic") or
        std.mem.eql(u8, name, "Script=Elym") or
        std.mem.eql(u8, name, "sc=Elymaic") or
        std.mem.eql(u8, name, "sc=Elym") or
        std.mem.eql(u8, name, "Script=Egyptian_Hieroglyphs") or
        std.mem.eql(u8, name, "Script=Egyp") or
        std.mem.eql(u8, name, "sc=Egyptian_Hieroglyphs") or
        std.mem.eql(u8, name, "sc=Egyp") or
        std.mem.eql(u8, name, "Script=Ethiopic") or
        std.mem.eql(u8, name, "Script=Ethi") or
        std.mem.eql(u8, name, "sc=Ethiopic") or
        std.mem.eql(u8, name, "sc=Ethi") or
        std.mem.eql(u8, name, "Script_Extensions=Ethiopic") or
        std.mem.eql(u8, name, "Script_Extensions=Ethi") or
        std.mem.eql(u8, name, "scx=Ethiopic") or
        std.mem.eql(u8, name, "scx=Ethi") or
        std.mem.eql(u8, name, "Script=Garay") or
        std.mem.eql(u8, name, "Script=Gara") or
        std.mem.eql(u8, name, "sc=Garay") or
        std.mem.eql(u8, name, "sc=Gara") or
        std.mem.eql(u8, name, "Script_Extensions=Garay") or
        std.mem.eql(u8, name, "Script_Extensions=Gara") or
        std.mem.eql(u8, name, "scx=Garay") or
        std.mem.eql(u8, name, "scx=Gara") or
        std.mem.eql(u8, name, "Script=Georgian") or
        std.mem.eql(u8, name, "Script=Geor") or
        std.mem.eql(u8, name, "sc=Georgian") or
        std.mem.eql(u8, name, "sc=Geor") or
        std.mem.eql(u8, name, "Script_Extensions=Georgian") or
        std.mem.eql(u8, name, "Script_Extensions=Geor") or
        std.mem.eql(u8, name, "scx=Georgian") or
        std.mem.eql(u8, name, "scx=Geor") or
        std.mem.eql(u8, name, "Script=Glagolitic") or
        std.mem.eql(u8, name, "Script=Glag") or
        std.mem.eql(u8, name, "sc=Glagolitic") or
        std.mem.eql(u8, name, "sc=Glag") or
        std.mem.eql(u8, name, "Script_Extensions=Glagolitic") or
        std.mem.eql(u8, name, "Script_Extensions=Glag") or
        std.mem.eql(u8, name, "scx=Glagolitic") or
        std.mem.eql(u8, name, "scx=Glag") or
        std.mem.eql(u8, name, "Script=Gothic") or
        std.mem.eql(u8, name, "Script=Goth") or
        std.mem.eql(u8, name, "sc=Gothic") or
        std.mem.eql(u8, name, "sc=Goth") or
        std.mem.eql(u8, name, "Script_Extensions=Gothic") or
        std.mem.eql(u8, name, "Script_Extensions=Goth") or
        std.mem.eql(u8, name, "scx=Gothic") or
        std.mem.eql(u8, name, "scx=Goth") or
        std.mem.eql(u8, name, "Script=Greek") or
        std.mem.eql(u8, name, "Script=Grek") or
        std.mem.eql(u8, name, "sc=Greek") or
        std.mem.eql(u8, name, "sc=Grek") or
        std.mem.eql(u8, name, "Script_Extensions=Greek") or
        std.mem.eql(u8, name, "Script_Extensions=Grek") or
        std.mem.eql(u8, name, "scx=Greek") or
        std.mem.eql(u8, name, "scx=Grek") or
        std.mem.eql(u8, name, "Script=Grantha") or
        std.mem.eql(u8, name, "Script=Gran") or
        std.mem.eql(u8, name, "sc=Grantha") or
        std.mem.eql(u8, name, "sc=Gran") or
        std.mem.eql(u8, name, "Script_Extensions=Grantha") or
        std.mem.eql(u8, name, "Script_Extensions=Gran") or
        std.mem.eql(u8, name, "scx=Grantha") or
        std.mem.eql(u8, name, "scx=Gran") or
        std.mem.eql(u8, name, "Script=Gunjala_Gondi") or
        std.mem.eql(u8, name, "Script=Gong") or
        std.mem.eql(u8, name, "sc=Gunjala_Gondi") or
        std.mem.eql(u8, name, "sc=Gong") or
        std.mem.eql(u8, name, "Script_Extensions=Gunjala_Gondi") or
        std.mem.eql(u8, name, "Script_Extensions=Gong") or
        std.mem.eql(u8, name, "scx=Gunjala_Gondi") or
        std.mem.eql(u8, name, "scx=Gong") or
        std.mem.eql(u8, name, "Script=Gurung_Khema") or
        std.mem.eql(u8, name, "Script=Gukh") or
        std.mem.eql(u8, name, "sc=Gurung_Khema") or
        std.mem.eql(u8, name, "sc=Gukh") or
        std.mem.eql(u8, name, "Script_Extensions=Gurung_Khema") or
        std.mem.eql(u8, name, "Script_Extensions=Gukh") or
        std.mem.eql(u8, name, "scx=Gurung_Khema") or
        std.mem.eql(u8, name, "scx=Gukh") or
        std.mem.eql(u8, name, "Script=Gurmukhi") or
        std.mem.eql(u8, name, "Script=Guru") or
        std.mem.eql(u8, name, "sc=Gurmukhi") or
        std.mem.eql(u8, name, "sc=Guru") or
        std.mem.eql(u8, name, "Script_Extensions=Gurmukhi") or
        std.mem.eql(u8, name, "Script_Extensions=Guru") or
        std.mem.eql(u8, name, "scx=Gurmukhi") or
        std.mem.eql(u8, name, "scx=Guru") or
        std.mem.eql(u8, name, "Script=Gujarati") or
        std.mem.eql(u8, name, "Script=Gujr") or
        std.mem.eql(u8, name, "sc=Gujarati") or
        std.mem.eql(u8, name, "sc=Gujr") or
        std.mem.eql(u8, name, "Script_Extensions=Gujarati") or
        std.mem.eql(u8, name, "Script_Extensions=Gujr") or
        std.mem.eql(u8, name, "scx=Gujarati") or
        std.mem.eql(u8, name, "scx=Gujr") or
        std.mem.eql(u8, name, "Script=Han") or
        std.mem.eql(u8, name, "Script=Hani") or
        std.mem.eql(u8, name, "sc=Han") or
        std.mem.eql(u8, name, "sc=Hani") or
        std.mem.eql(u8, name, "Script_Extensions=Han") or
        std.mem.eql(u8, name, "Script_Extensions=Hani") or
        std.mem.eql(u8, name, "scx=Han") or
        std.mem.eql(u8, name, "scx=Hani") or
        std.mem.eql(u8, name, "Script=Hangul") or
        std.mem.eql(u8, name, "Script=Hang") or
        std.mem.eql(u8, name, "sc=Hangul") or
        std.mem.eql(u8, name, "sc=Hang") or
        std.mem.eql(u8, name, "Script_Extensions=Hangul") or
        std.mem.eql(u8, name, "Script_Extensions=Hang") or
        std.mem.eql(u8, name, "scx=Hangul") or
        std.mem.eql(u8, name, "scx=Hang") or
        std.mem.eql(u8, name, "Script=Hanunoo") or
        std.mem.eql(u8, name, "Script=Hano") or
        std.mem.eql(u8, name, "sc=Hanunoo") or
        std.mem.eql(u8, name, "sc=Hano") or
        std.mem.eql(u8, name, "Script_Extensions=Hanunoo") or
        std.mem.eql(u8, name, "Script_Extensions=Hano") or
        std.mem.eql(u8, name, "scx=Hanunoo") or
        std.mem.eql(u8, name, "scx=Hano") or
        std.mem.eql(u8, name, "Script=Hatran") or
        std.mem.eql(u8, name, "Script=Hatr") or
        std.mem.eql(u8, name, "sc=Hatran") or
        std.mem.eql(u8, name, "sc=Hatr") or
        std.mem.eql(u8, name, "Script=Hanifi_Rohingya") or
        std.mem.eql(u8, name, "Script=Rohg") or
        std.mem.eql(u8, name, "sc=Hanifi_Rohingya") or
        std.mem.eql(u8, name, "sc=Rohg") or
        std.mem.eql(u8, name, "Script_Extensions=Hanifi_Rohingya") or
        std.mem.eql(u8, name, "Script_Extensions=Rohg") or
        std.mem.eql(u8, name, "scx=Hanifi_Rohingya") or
        std.mem.eql(u8, name, "scx=Rohg") or
        std.mem.eql(u8, name, "Script=Hebrew") or
        std.mem.eql(u8, name, "Script=Hebr") or
        std.mem.eql(u8, name, "sc=Hebrew") or
        std.mem.eql(u8, name, "sc=Hebr") or
        std.mem.eql(u8, name, "Script_Extensions=Hebrew") or
        std.mem.eql(u8, name, "Script_Extensions=Hebr") or
        std.mem.eql(u8, name, "scx=Hebrew") or
        std.mem.eql(u8, name, "scx=Hebr") or
        std.mem.eql(u8, name, "Script=Hiragana") or
        std.mem.eql(u8, name, "Script=Hira") or
        std.mem.eql(u8, name, "sc=Hiragana") or
        std.mem.eql(u8, name, "sc=Hira") or
        std.mem.eql(u8, name, "Script_Extensions=Hiragana") or
        std.mem.eql(u8, name, "Script_Extensions=Hira") or
        std.mem.eql(u8, name, "scx=Hiragana") or
        std.mem.eql(u8, name, "scx=Hira") or
        std.mem.eql(u8, name, "Script=Inherited") or
        std.mem.eql(u8, name, "Script=Zinh") or
        std.mem.eql(u8, name, "Script=Qaai") or
        std.mem.eql(u8, name, "sc=Inherited") or
        std.mem.eql(u8, name, "sc=Zinh") or
        std.mem.eql(u8, name, "sc=Qaai") or
        std.mem.eql(u8, name, "Script_Extensions=Inherited") or
        std.mem.eql(u8, name, "Script_Extensions=Zinh") or
        std.mem.eql(u8, name, "Script_Extensions=Qaai") or
        std.mem.eql(u8, name, "scx=Inherited") or
        std.mem.eql(u8, name, "scx=Zinh") or
        std.mem.eql(u8, name, "scx=Qaai") or
        std.mem.eql(u8, name, "Script=Inscriptional_Pahlavi") or
        std.mem.eql(u8, name, "Script=Phli") or
        std.mem.eql(u8, name, "sc=Inscriptional_Pahlavi") or
        std.mem.eql(u8, name, "sc=Phli") or
        std.mem.eql(u8, name, "Script=Inscriptional_Parthian") or
        std.mem.eql(u8, name, "Script=Prti") or
        std.mem.eql(u8, name, "sc=Inscriptional_Parthian") or
        std.mem.eql(u8, name, "sc=Prti") or
        std.mem.eql(u8, name, "Script=Imperial_Aramaic") or
        std.mem.eql(u8, name, "Script=Armi") or
        std.mem.eql(u8, name, "sc=Imperial_Aramaic") or
        std.mem.eql(u8, name, "sc=Armi") or
        std.mem.eql(u8, name, "Script_Extensions=Imperial_Aramaic") or
        std.mem.eql(u8, name, "Script_Extensions=Armi") or
        std.mem.eql(u8, name, "scx=Imperial_Aramaic") or
        std.mem.eql(u8, name, "scx=Armi") or
        std.mem.eql(u8, name, "Script=Javanese") or
        std.mem.eql(u8, name, "Script=Java") or
        std.mem.eql(u8, name, "sc=Javanese") or
        std.mem.eql(u8, name, "sc=Java") or
        std.mem.eql(u8, name, "Script_Extensions=Javanese") or
        std.mem.eql(u8, name, "Script_Extensions=Java") or
        std.mem.eql(u8, name, "scx=Javanese") or
        std.mem.eql(u8, name, "scx=Java") or
        std.mem.eql(u8, name, "Script=Kaithi") or
        std.mem.eql(u8, name, "Script=Kthi") or
        std.mem.eql(u8, name, "sc=Kaithi") or
        std.mem.eql(u8, name, "sc=Kthi") or
        std.mem.eql(u8, name, "Script_Extensions=Kaithi") or
        std.mem.eql(u8, name, "Script_Extensions=Kthi") or
        std.mem.eql(u8, name, "scx=Kaithi") or
        std.mem.eql(u8, name, "scx=Kthi") or
        std.mem.eql(u8, name, "Script=Kayah_Li") or
        std.mem.eql(u8, name, "Script=Kali") or
        std.mem.eql(u8, name, "sc=Kayah_Li") or
        std.mem.eql(u8, name, "sc=Kali") or
        std.mem.eql(u8, name, "Script_Extensions=Kayah_Li") or
        std.mem.eql(u8, name, "Script_Extensions=Kali") or
        std.mem.eql(u8, name, "scx=Kayah_Li") or
        std.mem.eql(u8, name, "scx=Kali") or
        std.mem.eql(u8, name, "Script=Kannada") or
        std.mem.eql(u8, name, "Script=Knda") or
        std.mem.eql(u8, name, "sc=Kannada") or
        std.mem.eql(u8, name, "sc=Knda") or
        std.mem.eql(u8, name, "Script_Extensions=Kannada") or
        std.mem.eql(u8, name, "Script_Extensions=Knda") or
        std.mem.eql(u8, name, "scx=Kannada") or
        std.mem.eql(u8, name, "scx=Knda") or
        std.mem.eql(u8, name, "Script=Katakana") or
        std.mem.eql(u8, name, "Script=Kana") or
        std.mem.eql(u8, name, "sc=Katakana") or
        std.mem.eql(u8, name, "sc=Kana") or
        std.mem.eql(u8, name, "Script_Extensions=Katakana") or
        std.mem.eql(u8, name, "Script_Extensions=Kana") or
        std.mem.eql(u8, name, "scx=Katakana") or
        std.mem.eql(u8, name, "scx=Kana") or
        std.mem.eql(u8, name, "Script=Kawi") or
        std.mem.eql(u8, name, "sc=Kawi") or
        std.mem.eql(u8, name, "Script_Extensions=Kawi") or
        std.mem.eql(u8, name, "scx=Kawi") or
        std.mem.eql(u8, name, "Script=Kharoshthi") or
        std.mem.eql(u8, name, "Script=Khar") or
        std.mem.eql(u8, name, "sc=Kharoshthi") or
        std.mem.eql(u8, name, "sc=Khar") or
        std.mem.eql(u8, name, "Script=Khitan_Small_Script") or
        std.mem.eql(u8, name, "Script=Kits") or
        std.mem.eql(u8, name, "sc=Khitan_Small_Script") or
        std.mem.eql(u8, name, "sc=Kits") or
        std.mem.eql(u8, name, "Script=Khojki") or
        std.mem.eql(u8, name, "Script=Khoj") or
        std.mem.eql(u8, name, "sc=Khojki") or
        std.mem.eql(u8, name, "sc=Khoj") or
        std.mem.eql(u8, name, "Script_Extensions=Khojki") or
        std.mem.eql(u8, name, "Script_Extensions=Khoj") or
        std.mem.eql(u8, name, "scx=Khojki") or
        std.mem.eql(u8, name, "scx=Khoj") or
        std.mem.eql(u8, name, "Script=Khmer") or
        std.mem.eql(u8, name, "Script=Khmr") or
        std.mem.eql(u8, name, "sc=Khmer") or
        std.mem.eql(u8, name, "sc=Khmr") or
        std.mem.eql(u8, name, "Script=Kirat_Rai") or
        std.mem.eql(u8, name, "Script=Krai") or
        std.mem.eql(u8, name, "sc=Kirat_Rai") or
        std.mem.eql(u8, name, "sc=Krai") or
        std.mem.eql(u8, name, "Script=Khudawadi") or
        std.mem.eql(u8, name, "Script=Sind") or
        std.mem.eql(u8, name, "sc=Khudawadi") or
        std.mem.eql(u8, name, "sc=Sind") or
        std.mem.eql(u8, name, "Script_Extensions=Khudawadi") or
        std.mem.eql(u8, name, "Script_Extensions=Sind") or
        std.mem.eql(u8, name, "scx=Khudawadi") or
        std.mem.eql(u8, name, "scx=Sind") or
        std.mem.eql(u8, name, "Script=Lao") or
        std.mem.eql(u8, name, "Script=Laoo") or
        std.mem.eql(u8, name, "sc=Lao") or
        std.mem.eql(u8, name, "sc=Laoo") or
        std.mem.eql(u8, name, "Script_Extensions=Lao") or
        std.mem.eql(u8, name, "Script_Extensions=Laoo") or
        std.mem.eql(u8, name, "scx=Lao") or
        std.mem.eql(u8, name, "scx=Laoo") or
        std.mem.eql(u8, name, "Script=Lepcha") or
        std.mem.eql(u8, name, "Script=Lepc") or
        std.mem.eql(u8, name, "sc=Lepcha") or
        std.mem.eql(u8, name, "sc=Lepc") or
        std.mem.eql(u8, name, "Script=Limbu") or
        std.mem.eql(u8, name, "Script=Limb") or
        std.mem.eql(u8, name, "sc=Limbu") or
        std.mem.eql(u8, name, "sc=Limb") or
        std.mem.eql(u8, name, "Script_Extensions=Limbu") or
        std.mem.eql(u8, name, "Script_Extensions=Limb") or
        std.mem.eql(u8, name, "scx=Limbu") or
        std.mem.eql(u8, name, "scx=Limb") or
        std.mem.eql(u8, name, "Script_Extensions=Linear_A") or
        std.mem.eql(u8, name, "Script_Extensions=Lina") or
        std.mem.eql(u8, name, "scx=Linear_A") or
        std.mem.eql(u8, name, "scx=Lina") or
        std.mem.eql(u8, name, "Script_Extensions=Linear_B") or
        std.mem.eql(u8, name, "Script_Extensions=Linb") or
        std.mem.eql(u8, name, "scx=Linear_B") or
        std.mem.eql(u8, name, "scx=Linb") or
        std.mem.eql(u8, name, "Script_Extensions=Lisu") or
        std.mem.eql(u8, name, "scx=Lisu") or
        std.mem.eql(u8, name, "Script_Extensions=Lydian") or
        std.mem.eql(u8, name, "Script_Extensions=Lydi") or
        std.mem.eql(u8, name, "scx=Lydian") or
        std.mem.eql(u8, name, "scx=Lydi") or
        std.mem.eql(u8, name, "Script_Extensions=Mahajani") or
        std.mem.eql(u8, name, "Script_Extensions=Mahj") or
        std.mem.eql(u8, name, "scx=Mahajani") or
        std.mem.eql(u8, name, "scx=Mahj") or
        std.mem.eql(u8, name, "Script_Extensions=Manichaean") or
        std.mem.eql(u8, name, "Script_Extensions=Mani") or
        std.mem.eql(u8, name, "scx=Manichaean") or
        std.mem.eql(u8, name, "scx=Mani") or
        std.mem.eql(u8, name, "Script_Extensions=Masaram_Gondi") or
        std.mem.eql(u8, name, "Script_Extensions=Gonm") or
        std.mem.eql(u8, name, "scx=Masaram_Gondi") or
        std.mem.eql(u8, name, "scx=Gonm") or
        std.mem.eql(u8, name, "Script_Extensions=Multani") or
        std.mem.eql(u8, name, "Script_Extensions=Mult") or
        std.mem.eql(u8, name, "scx=Multani") or
        std.mem.eql(u8, name, "scx=Mult") or
        std.mem.eql(u8, name, "Script=Linear_A") or
        std.mem.eql(u8, name, "Script=Lina") or
        std.mem.eql(u8, name, "sc=Linear_A") or
        std.mem.eql(u8, name, "sc=Lina") or
        std.mem.eql(u8, name, "Script=Linear_B") or
        std.mem.eql(u8, name, "Script=Linb") or
        std.mem.eql(u8, name, "sc=Linear_B") or
        std.mem.eql(u8, name, "sc=Linb") or
        std.mem.eql(u8, name, "Script=Lycian") or
        std.mem.eql(u8, name, "Script=Lyci") or
        std.mem.eql(u8, name, "sc=Lycian") or
        std.mem.eql(u8, name, "sc=Lyci") or
        std.mem.eql(u8, name, "Script_Extensions=Lycian") or
        std.mem.eql(u8, name, "Script_Extensions=Lyci") or
        std.mem.eql(u8, name, "scx=Lycian") or
        std.mem.eql(u8, name, "scx=Lyci") or
        std.mem.eql(u8, name, "Script=Lydian") or
        std.mem.eql(u8, name, "Script=Lydi") or
        std.mem.eql(u8, name, "sc=Lydian") or
        std.mem.eql(u8, name, "sc=Lydi") or
        std.mem.eql(u8, name, "Script=Latin") or
        std.mem.eql(u8, name, "Script=Latn") or
        std.mem.eql(u8, name, "sc=Latin") or
        std.mem.eql(u8, name, "sc=Latn") or
        std.mem.eql(u8, name, "Script_Extensions=Latin") or
        std.mem.eql(u8, name, "Script_Extensions=Latn") or
        std.mem.eql(u8, name, "scx=Latin") or
        std.mem.eql(u8, name, "scx=Latn") or
        std.mem.eql(u8, name, "Script=Lisu") or
        std.mem.eql(u8, name, "sc=Lisu") or
        std.mem.eql(u8, name, "Script=Mahajani") or
        std.mem.eql(u8, name, "Script=Mahj") or
        std.mem.eql(u8, name, "sc=Mahajani") or
        std.mem.eql(u8, name, "sc=Mahj") or
        std.mem.eql(u8, name, "Script=Makasar") or
        std.mem.eql(u8, name, "Script=Maka") or
        std.mem.eql(u8, name, "sc=Makasar") or
        std.mem.eql(u8, name, "sc=Maka") or
        std.mem.eql(u8, name, "Script=Malayalam") or
        std.mem.eql(u8, name, "Script=Mlym") or
        std.mem.eql(u8, name, "sc=Malayalam") or
        std.mem.eql(u8, name, "sc=Mlym") or
        std.mem.eql(u8, name, "Script_Extensions=Malayalam") or
        std.mem.eql(u8, name, "Script_Extensions=Mlym") or
        std.mem.eql(u8, name, "scx=Malayalam") or
        std.mem.eql(u8, name, "scx=Mlym") or
        std.mem.eql(u8, name, "Script=Masaram_Gondi") or
        std.mem.eql(u8, name, "Script=Gonm") or
        std.mem.eql(u8, name, "sc=Masaram_Gondi") or
        std.mem.eql(u8, name, "sc=Gonm") or
        std.mem.eql(u8, name, "Script=Mandaic") or
        std.mem.eql(u8, name, "Script=Mand") or
        std.mem.eql(u8, name, "sc=Mandaic") or
        std.mem.eql(u8, name, "sc=Mand") or
        std.mem.eql(u8, name, "Script_Extensions=Mandaic") or
        std.mem.eql(u8, name, "Script_Extensions=Mand") or
        std.mem.eql(u8, name, "scx=Mandaic") or
        std.mem.eql(u8, name, "scx=Mand") or
        std.mem.eql(u8, name, "Script=Manichaean") or
        std.mem.eql(u8, name, "Script=Mani") or
        std.mem.eql(u8, name, "sc=Manichaean") or
        std.mem.eql(u8, name, "sc=Mani") or
        std.mem.eql(u8, name, "Script=Marchen") or
        std.mem.eql(u8, name, "Script=Marc") or
        std.mem.eql(u8, name, "sc=Marchen") or
        std.mem.eql(u8, name, "sc=Marc") or
        std.mem.eql(u8, name, "Script=Medefaidrin") or
        std.mem.eql(u8, name, "Script=Medf") or
        std.mem.eql(u8, name, "sc=Medefaidrin") or
        std.mem.eql(u8, name, "sc=Medf") or
        std.mem.eql(u8, name, "Script=Meetei_Mayek") or
        std.mem.eql(u8, name, "Script=Mtei") or
        std.mem.eql(u8, name, "sc=Meetei_Mayek") or
        std.mem.eql(u8, name, "sc=Mtei") or
        std.mem.eql(u8, name, "Script=Mende_Kikakui") or
        std.mem.eql(u8, name, "Script=Mend") or
        std.mem.eql(u8, name, "sc=Mende_Kikakui") or
        std.mem.eql(u8, name, "sc=Mend") or
        std.mem.eql(u8, name, "Script=Meroitic_Hieroglyphs") or
        std.mem.eql(u8, name, "Script=Mero") or
        std.mem.eql(u8, name, "sc=Meroitic_Hieroglyphs") or
        std.mem.eql(u8, name, "sc=Mero") or
        std.mem.eql(u8, name, "Script_Extensions=Meroitic_Hieroglyphs") or
        std.mem.eql(u8, name, "Script_Extensions=Mero") or
        std.mem.eql(u8, name, "scx=Meroitic_Hieroglyphs") or
        std.mem.eql(u8, name, "scx=Mero") or
        std.mem.eql(u8, name, "Script=Meroitic_Cursive") or
        std.mem.eql(u8, name, "Script=Merc") or
        std.mem.eql(u8, name, "sc=Meroitic_Cursive") or
        std.mem.eql(u8, name, "sc=Merc") or
        std.mem.eql(u8, name, "Script=Miao") or
        std.mem.eql(u8, name, "Script=Plrd") or
        std.mem.eql(u8, name, "sc=Miao") or
        std.mem.eql(u8, name, "sc=Plrd") or
        std.mem.eql(u8, name, "Script=Modi") or
        std.mem.eql(u8, name, "sc=Modi") or
        std.mem.eql(u8, name, "Script_Extensions=Modi") or
        std.mem.eql(u8, name, "scx=Modi") or
        std.mem.eql(u8, name, "Script=Mongolian") or
        std.mem.eql(u8, name, "Script=Mong") or
        std.mem.eql(u8, name, "sc=Mongolian") or
        std.mem.eql(u8, name, "sc=Mong") or
        std.mem.eql(u8, name, "Script_Extensions=Mongolian") or
        std.mem.eql(u8, name, "Script_Extensions=Mong") or
        std.mem.eql(u8, name, "scx=Mongolian") or
        std.mem.eql(u8, name, "scx=Mong") or
        std.mem.eql(u8, name, "Script=Multani") or
        std.mem.eql(u8, name, "Script=Mult") or
        std.mem.eql(u8, name, "sc=Multani") or
        std.mem.eql(u8, name, "sc=Mult") or
        std.mem.eql(u8, name, "Script=Myanmar") or
        std.mem.eql(u8, name, "Script=Mymr") or
        std.mem.eql(u8, name, "sc=Myanmar") or
        std.mem.eql(u8, name, "sc=Mymr") or
        std.mem.eql(u8, name, "Script_Extensions=Myanmar") or
        std.mem.eql(u8, name, "Script_Extensions=Mymr") or
        std.mem.eql(u8, name, "scx=Myanmar") or
        std.mem.eql(u8, name, "scx=Mymr") or
        std.mem.eql(u8, name, "Script=Mro") or
        std.mem.eql(u8, name, "Script=Mroo") or
        std.mem.eql(u8, name, "sc=Mro") or
        std.mem.eql(u8, name, "sc=Mroo") or
        std.mem.eql(u8, name, "Script=Nag_Mundari") or
        std.mem.eql(u8, name, "Script=Nagm") or
        std.mem.eql(u8, name, "sc=Nag_Mundari") or
        std.mem.eql(u8, name, "sc=Nagm") or
        std.mem.eql(u8, name, "Script_Extensions=Nag_Mundari") or
        std.mem.eql(u8, name, "Script_Extensions=Nagm") or
        std.mem.eql(u8, name, "scx=Nag_Mundari") or
        std.mem.eql(u8, name, "scx=Nagm") or
        std.mem.eql(u8, name, "Script=Nabataean") or
        std.mem.eql(u8, name, "Script=Nbat") or
        std.mem.eql(u8, name, "sc=Nabataean") or
        std.mem.eql(u8, name, "sc=Nbat") or
        std.mem.eql(u8, name, "Script=Nandinagari") or
        std.mem.eql(u8, name, "Script=Nand") or
        std.mem.eql(u8, name, "sc=Nandinagari") or
        std.mem.eql(u8, name, "sc=Nand") or
        std.mem.eql(u8, name, "Script_Extensions=Nandinagari") or
        std.mem.eql(u8, name, "Script_Extensions=Nand") or
        std.mem.eql(u8, name, "scx=Nandinagari") or
        std.mem.eql(u8, name, "scx=Nand") or
        std.mem.eql(u8, name, "Script=Newa") or
        std.mem.eql(u8, name, "sc=Newa") or
        std.mem.eql(u8, name, "Script_Extensions=Newa") or
        std.mem.eql(u8, name, "scx=Newa") or
        std.mem.eql(u8, name, "Script=New_Tai_Lue") or
        std.mem.eql(u8, name, "Script=Talu") or
        std.mem.eql(u8, name, "sc=New_Tai_Lue") or
        std.mem.eql(u8, name, "sc=Talu") or
        std.mem.eql(u8, name, "Script_Extensions=New_Tai_Lue") or
        std.mem.eql(u8, name, "Script_Extensions=Talu") or
        std.mem.eql(u8, name, "scx=New_Tai_Lue") or
        std.mem.eql(u8, name, "scx=Talu") or
        std.mem.eql(u8, name, "Script=Nko") or
        std.mem.eql(u8, name, "Script=Nkoo") or
        std.mem.eql(u8, name, "sc=Nko") or
        std.mem.eql(u8, name, "sc=Nkoo") or
        std.mem.eql(u8, name, "Script_Extensions=Nko") or
        std.mem.eql(u8, name, "Script_Extensions=Nkoo") or
        std.mem.eql(u8, name, "scx=Nko") or
        std.mem.eql(u8, name, "scx=Nkoo") or
        std.mem.eql(u8, name, "Script=Nushu") or
        std.mem.eql(u8, name, "Script=Nshu") or
        std.mem.eql(u8, name, "sc=Nushu") or
        std.mem.eql(u8, name, "sc=Nshu") or
        std.mem.eql(u8, name, "Script=Nyiakeng_Puachue_Hmong") or
        std.mem.eql(u8, name, "Script=Hmnp") or
        std.mem.eql(u8, name, "sc=Nyiakeng_Puachue_Hmong") or
        std.mem.eql(u8, name, "sc=Hmnp") or
        std.mem.eql(u8, name, "Script=Ogham") or
        std.mem.eql(u8, name, "Script=Ogam") or
        std.mem.eql(u8, name, "sc=Ogham") or
        std.mem.eql(u8, name, "sc=Ogam") or
        std.mem.eql(u8, name, "Script=Ol_Chiki") or
        std.mem.eql(u8, name, "Script=Olck") or
        std.mem.eql(u8, name, "sc=Ol_Chiki") or
        std.mem.eql(u8, name, "sc=Olck") or
        std.mem.eql(u8, name, "Script=Ol_Onal") or
        std.mem.eql(u8, name, "Script=Onao") or
        std.mem.eql(u8, name, "sc=Ol_Onal") or
        std.mem.eql(u8, name, "sc=Onao") or
        std.mem.eql(u8, name, "Script_Extensions=Ol_Onal") or
        std.mem.eql(u8, name, "Script_Extensions=Onao") or
        std.mem.eql(u8, name, "scx=Ol_Onal") or
        std.mem.eql(u8, name, "scx=Onao") or
        std.mem.eql(u8, name, "Script=Old_Italic") or
        std.mem.eql(u8, name, "Script=Ital") or
        std.mem.eql(u8, name, "sc=Old_Italic") or
        std.mem.eql(u8, name, "sc=Ital") or
        std.mem.eql(u8, name, "Script=Old_North_Arabian") or
        std.mem.eql(u8, name, "Script=Narb") or
        std.mem.eql(u8, name, "sc=Old_North_Arabian") or
        std.mem.eql(u8, name, "sc=Narb") or
        std.mem.eql(u8, name, "Script=Old_Sogdian") or
        std.mem.eql(u8, name, "Script=Sogo") or
        std.mem.eql(u8, name, "sc=Old_Sogdian") or
        std.mem.eql(u8, name, "sc=Sogo") or
        std.mem.eql(u8, name, "Script_Extensions=Old_Sogdian") or
        std.mem.eql(u8, name, "Script_Extensions=Sogo") or
        std.mem.eql(u8, name, "scx=Old_Sogdian") or
        std.mem.eql(u8, name, "scx=Sogo") or
        std.mem.eql(u8, name, "Script=Old_South_Arabian") or
        std.mem.eql(u8, name, "Script=Sarb") or
        std.mem.eql(u8, name, "sc=Old_South_Arabian") or
        std.mem.eql(u8, name, "sc=Sarb") or
        std.mem.eql(u8, name, "Script=Old_Hungarian") or
        std.mem.eql(u8, name, "Script=Hung") or
        std.mem.eql(u8, name, "sc=Old_Hungarian") or
        std.mem.eql(u8, name, "sc=Hung") or
        std.mem.eql(u8, name, "Script_Extensions=Old_Hungarian") or
        std.mem.eql(u8, name, "Script_Extensions=Hung") or
        std.mem.eql(u8, name, "scx=Old_Hungarian") or
        std.mem.eql(u8, name, "scx=Hung") or
        std.mem.eql(u8, name, "Script=Old_Permic") or
        std.mem.eql(u8, name, "Script=Perm") or
        std.mem.eql(u8, name, "sc=Old_Permic") or
        std.mem.eql(u8, name, "sc=Perm") or
        std.mem.eql(u8, name, "Script_Extensions=Old_Permic") or
        std.mem.eql(u8, name, "Script_Extensions=Perm") or
        std.mem.eql(u8, name, "scx=Old_Permic") or
        std.mem.eql(u8, name, "scx=Perm") or
        std.mem.eql(u8, name, "Script=Old_Uyghur") or
        std.mem.eql(u8, name, "Script=Ougr") or
        std.mem.eql(u8, name, "sc=Old_Uyghur") or
        std.mem.eql(u8, name, "sc=Ougr") or
        std.mem.eql(u8, name, "Script_Extensions=Old_Uyghur") or
        std.mem.eql(u8, name, "Script_Extensions=Ougr") or
        std.mem.eql(u8, name, "scx=Old_Uyghur") or
        std.mem.eql(u8, name, "scx=Ougr") or
        std.mem.eql(u8, name, "Script=Old_Turkic") or
        std.mem.eql(u8, name, "Script=Orkh") or
        std.mem.eql(u8, name, "sc=Old_Turkic") or
        std.mem.eql(u8, name, "sc=Orkh") or
        std.mem.eql(u8, name, "Script_Extensions=Old_Turkic") or
        std.mem.eql(u8, name, "Script_Extensions=Orkh") or
        std.mem.eql(u8, name, "scx=Old_Turkic") or
        std.mem.eql(u8, name, "scx=Orkh") or
        std.mem.eql(u8, name, "Script=Old_Persian") or
        std.mem.eql(u8, name, "Script=Xpeo") or
        std.mem.eql(u8, name, "sc=Old_Persian") or
        std.mem.eql(u8, name, "sc=Xpeo") or
        std.mem.eql(u8, name, "Script_Extensions=Old_Persian") or
        std.mem.eql(u8, name, "Script_Extensions=Xpeo") or
        std.mem.eql(u8, name, "scx=Old_Persian") or
        std.mem.eql(u8, name, "scx=Xpeo") or
        std.mem.eql(u8, name, "Script=Osmanya") or
        std.mem.eql(u8, name, "Script=Osma") or
        std.mem.eql(u8, name, "sc=Osmanya") or
        std.mem.eql(u8, name, "sc=Osma") or
        std.mem.eql(u8, name, "Script_Extensions=Osmanya") or
        std.mem.eql(u8, name, "Script_Extensions=Osma") or
        std.mem.eql(u8, name, "scx=Osmanya") or
        std.mem.eql(u8, name, "scx=Osma") or
        std.mem.eql(u8, name, "Script=Oriya") or
        std.mem.eql(u8, name, "Script=Orya") or
        std.mem.eql(u8, name, "sc=Oriya") or
        std.mem.eql(u8, name, "sc=Orya") or
        std.mem.eql(u8, name, "Script_Extensions=Oriya") or
        std.mem.eql(u8, name, "Script_Extensions=Orya") or
        std.mem.eql(u8, name, "scx=Oriya") or
        std.mem.eql(u8, name, "scx=Orya") or
        std.mem.eql(u8, name, "Script=Osage") or
        std.mem.eql(u8, name, "Script=Osge") or
        std.mem.eql(u8, name, "sc=Osage") or
        std.mem.eql(u8, name, "sc=Osge") or
        std.mem.eql(u8, name, "Script_Extensions=Osage") or
        std.mem.eql(u8, name, "Script_Extensions=Osge") or
        std.mem.eql(u8, name, "scx=Osage") or
        std.mem.eql(u8, name, "scx=Osge") or
        std.mem.eql(u8, name, "Script=Palmyrene") or
        std.mem.eql(u8, name, "Script=Palm") or
        std.mem.eql(u8, name, "sc=Palmyrene") or
        std.mem.eql(u8, name, "sc=Palm") or
        std.mem.eql(u8, name, "Script=Pahawh_Hmong") or
        std.mem.eql(u8, name, "Script=Hmng") or
        std.mem.eql(u8, name, "sc=Pahawh_Hmong") or
        std.mem.eql(u8, name, "sc=Hmng") or
        std.mem.eql(u8, name, "Script_Extensions=Pahawh_Hmong") or
        std.mem.eql(u8, name, "Script_Extensions=Hmng") or
        std.mem.eql(u8, name, "scx=Pahawh_Hmong") or
        std.mem.eql(u8, name, "scx=Hmng") or
        std.mem.eql(u8, name, "Script=Pau_Cin_Hau") or
        std.mem.eql(u8, name, "Script=Pauc") or
        std.mem.eql(u8, name, "sc=Pau_Cin_Hau") or
        std.mem.eql(u8, name, "sc=Pauc") or
        std.mem.eql(u8, name, "Script_Extensions=Pau_Cin_Hau") or
        std.mem.eql(u8, name, "Script_Extensions=Pauc") or
        std.mem.eql(u8, name, "scx=Pau_Cin_Hau") or
        std.mem.eql(u8, name, "scx=Pauc") or
        std.mem.eql(u8, name, "Script=Phags_Pa") or
        std.mem.eql(u8, name, "Script=Phag") or
        std.mem.eql(u8, name, "sc=Phags_Pa") or
        std.mem.eql(u8, name, "sc=Phag") or
        std.mem.eql(u8, name, "Script_Extensions=Phags_Pa") or
        std.mem.eql(u8, name, "Script_Extensions=Phag") or
        std.mem.eql(u8, name, "scx=Phags_Pa") or
        std.mem.eql(u8, name, "scx=Phag") or
        std.mem.eql(u8, name, "Script=Phoenician") or
        std.mem.eql(u8, name, "Script=Phnx") or
        std.mem.eql(u8, name, "sc=Phoenician") or
        std.mem.eql(u8, name, "sc=Phnx") or
        std.mem.eql(u8, name, "Script_Extensions=Phoenician") or
        std.mem.eql(u8, name, "Script_Extensions=Phnx") or
        std.mem.eql(u8, name, "scx=Phoenician") or
        std.mem.eql(u8, name, "scx=Phnx") or
        std.mem.eql(u8, name, "Script=Psalter_Pahlavi") or
        std.mem.eql(u8, name, "Script=Phlp") or
        std.mem.eql(u8, name, "sc=Psalter_Pahlavi") or
        std.mem.eql(u8, name, "sc=Phlp") or
        std.mem.eql(u8, name, "Script_Extensions=Psalter_Pahlavi") or
        std.mem.eql(u8, name, "Script_Extensions=Phlp") or
        std.mem.eql(u8, name, "scx=Psalter_Pahlavi") or
        std.mem.eql(u8, name, "scx=Phlp") or
        std.mem.eql(u8, name, "Script=Rejang") or
        std.mem.eql(u8, name, "Script=Rjng") or
        std.mem.eql(u8, name, "sc=Rejang") or
        std.mem.eql(u8, name, "sc=Rjng") or
        std.mem.eql(u8, name, "Script_Extensions=Rejang") or
        std.mem.eql(u8, name, "Script_Extensions=Rjng") or
        std.mem.eql(u8, name, "scx=Rejang") or
        std.mem.eql(u8, name, "scx=Rjng") or
        std.mem.eql(u8, name, "Script=Runic") or
        std.mem.eql(u8, name, "Script=Runr") or
        std.mem.eql(u8, name, "sc=Runic") or
        std.mem.eql(u8, name, "sc=Runr") or
        std.mem.eql(u8, name, "Script_Extensions=Runic") or
        std.mem.eql(u8, name, "Script_Extensions=Runr") or
        std.mem.eql(u8, name, "scx=Runic") or
        std.mem.eql(u8, name, "scx=Runr") or
        std.mem.eql(u8, name, "Script=Saurashtra") or
        std.mem.eql(u8, name, "Script=Saur") or
        std.mem.eql(u8, name, "sc=Saurashtra") or
        std.mem.eql(u8, name, "sc=Saur") or
        std.mem.eql(u8, name, "Script_Extensions=Saurashtra") or
        std.mem.eql(u8, name, "Script_Extensions=Saur") or
        std.mem.eql(u8, name, "scx=Saurashtra") or
        std.mem.eql(u8, name, "scx=Saur") or
        std.mem.eql(u8, name, "Script=Shavian") or
        std.mem.eql(u8, name, "Script=Shaw") or
        std.mem.eql(u8, name, "sc=Shavian") or
        std.mem.eql(u8, name, "sc=Shaw") or
        std.mem.eql(u8, name, "Script_Extensions=Shavian") or
        std.mem.eql(u8, name, "Script_Extensions=Shaw") or
        std.mem.eql(u8, name, "scx=Shavian") or
        std.mem.eql(u8, name, "scx=Shaw") or
        std.mem.eql(u8, name, "Script=Sharada") or
        std.mem.eql(u8, name, "Script=Shrd") or
        std.mem.eql(u8, name, "sc=Sharada") or
        std.mem.eql(u8, name, "sc=Shrd") or
        std.mem.eql(u8, name, "Script_Extensions=Sharada") or
        std.mem.eql(u8, name, "Script_Extensions=Shrd") or
        std.mem.eql(u8, name, "scx=Sharada") or
        std.mem.eql(u8, name, "scx=Shrd") or
        std.mem.eql(u8, name, "Script=Samaritan") or
        std.mem.eql(u8, name, "Script=Samr") or
        std.mem.eql(u8, name, "sc=Samaritan") or
        std.mem.eql(u8, name, "sc=Samr") or
        std.mem.eql(u8, name, "Script_Extensions=Samaritan") or
        std.mem.eql(u8, name, "Script_Extensions=Samr") or
        std.mem.eql(u8, name, "scx=Samaritan") or
        std.mem.eql(u8, name, "scx=Samr") or
        std.mem.eql(u8, name, "Script=SignWriting") or
        std.mem.eql(u8, name, "Script=Sgnw") or
        std.mem.eql(u8, name, "sc=SignWriting") or
        std.mem.eql(u8, name, "sc=Sgnw") or
        std.mem.eql(u8, name, "Script_Extensions=SignWriting") or
        std.mem.eql(u8, name, "Script_Extensions=Sgnw") or
        std.mem.eql(u8, name, "scx=SignWriting") or
        std.mem.eql(u8, name, "scx=Sgnw") or
        std.mem.eql(u8, name, "Script=Siddham") or
        std.mem.eql(u8, name, "Script=Sidd") or
        std.mem.eql(u8, name, "sc=Siddham") or
        std.mem.eql(u8, name, "sc=Sidd") or
        std.mem.eql(u8, name, "Script_Extensions=Siddham") or
        std.mem.eql(u8, name, "Script_Extensions=Sidd") or
        std.mem.eql(u8, name, "scx=Siddham") or
        std.mem.eql(u8, name, "scx=Sidd") or
        std.mem.eql(u8, name, "Script=Sidetic") or
        std.mem.eql(u8, name, "Script=Sidt") or
        std.mem.eql(u8, name, "sc=Sidetic") or
        std.mem.eql(u8, name, "sc=Sidt") or
        std.mem.eql(u8, name, "Script_Extensions=Sidetic") or
        std.mem.eql(u8, name, "Script_Extensions=Sidt") or
        std.mem.eql(u8, name, "scx=Sidetic") or
        std.mem.eql(u8, name, "scx=Sidt") or
        std.mem.eql(u8, name, "Script=Sinhala") or
        std.mem.eql(u8, name, "Script=Sinh") or
        std.mem.eql(u8, name, "sc=Sinhala") or
        std.mem.eql(u8, name, "sc=Sinh") or
        std.mem.eql(u8, name, "Script_Extensions=Sinhala") or
        std.mem.eql(u8, name, "Script_Extensions=Sinh") or
        std.mem.eql(u8, name, "scx=Sinhala") or
        std.mem.eql(u8, name, "scx=Sinh") or
        std.mem.eql(u8, name, "Script=Sogdian") or
        std.mem.eql(u8, name, "Script=Sogd") or
        std.mem.eql(u8, name, "sc=Sogdian") or
        std.mem.eql(u8, name, "sc=Sogd") or
        std.mem.eql(u8, name, "Script_Extensions=Sogdian") or
        std.mem.eql(u8, name, "Script_Extensions=Sogd") or
        std.mem.eql(u8, name, "scx=Sogdian") or
        std.mem.eql(u8, name, "scx=Sogd") or
        std.mem.eql(u8, name, "Script=Soyombo") or
        std.mem.eql(u8, name, "Script=Soyo") or
        std.mem.eql(u8, name, "sc=Soyombo") or
        std.mem.eql(u8, name, "sc=Soyo") or
        std.mem.eql(u8, name, "Script_Extensions=Soyombo") or
        std.mem.eql(u8, name, "Script_Extensions=Soyo") or
        std.mem.eql(u8, name, "scx=Soyombo") or
        std.mem.eql(u8, name, "scx=Soyo") or
        std.mem.eql(u8, name, "Script=Sora_Sompeng") or
        std.mem.eql(u8, name, "Script=Sora") or
        std.mem.eql(u8, name, "sc=Sora_Sompeng") or
        std.mem.eql(u8, name, "sc=Sora") or
        std.mem.eql(u8, name, "Script=Sundanese") or
        std.mem.eql(u8, name, "Script=Sund") or
        std.mem.eql(u8, name, "sc=Sundanese") or
        std.mem.eql(u8, name, "sc=Sund") or
        std.mem.eql(u8, name, "Script_Extensions=Sundanese") or
        std.mem.eql(u8, name, "Script_Extensions=Sund") or
        std.mem.eql(u8, name, "scx=Sundanese") or
        std.mem.eql(u8, name, "scx=Sund") or
        std.mem.eql(u8, name, "Script=Sunuwar") or
        std.mem.eql(u8, name, "Script=Sunu") or
        std.mem.eql(u8, name, "sc=Sunuwar") or
        std.mem.eql(u8, name, "sc=Sunu") or
        std.mem.eql(u8, name, "Script_Extensions=Sunuwar") or
        std.mem.eql(u8, name, "Script_Extensions=Sunu") or
        std.mem.eql(u8, name, "scx=Sunuwar") or
        std.mem.eql(u8, name, "scx=Sunu") or
        std.mem.eql(u8, name, "Script=Syloti_Nagri") or
        std.mem.eql(u8, name, "Script=Sylo") or
        std.mem.eql(u8, name, "sc=Syloti_Nagri") or
        std.mem.eql(u8, name, "sc=Sylo") or
        std.mem.eql(u8, name, "Script_Extensions=Syloti_Nagri") or
        std.mem.eql(u8, name, "Script_Extensions=Sylo") or
        std.mem.eql(u8, name, "scx=Syloti_Nagri") or
        std.mem.eql(u8, name, "scx=Sylo") or
        std.mem.eql(u8, name, "Script=Syriac") or
        std.mem.eql(u8, name, "Script=Syrc") or
        std.mem.eql(u8, name, "sc=Syriac") or
        std.mem.eql(u8, name, "sc=Syrc") or
        std.mem.eql(u8, name, "Script_Extensions=Syriac") or
        std.mem.eql(u8, name, "Script_Extensions=Syrc") or
        std.mem.eql(u8, name, "scx=Syriac") or
        std.mem.eql(u8, name, "scx=Syrc") or
        std.mem.eql(u8, name, "Script=Tagbanwa") or
        std.mem.eql(u8, name, "Script=Tagb") or
        std.mem.eql(u8, name, "sc=Tagbanwa") or
        std.mem.eql(u8, name, "sc=Tagb") or
        std.mem.eql(u8, name, "Script_Extensions=Tagbanwa") or
        std.mem.eql(u8, name, "Script_Extensions=Tagb") or
        std.mem.eql(u8, name, "scx=Tagbanwa") or
        std.mem.eql(u8, name, "scx=Tagb") or
        std.mem.eql(u8, name, "Script=Tagalog") or
        std.mem.eql(u8, name, "Script=Tglg") or
        std.mem.eql(u8, name, "sc=Tagalog") or
        std.mem.eql(u8, name, "sc=Tglg") or
        std.mem.eql(u8, name, "Script_Extensions=Tagalog") or
        std.mem.eql(u8, name, "Script_Extensions=Tglg") or
        std.mem.eql(u8, name, "scx=Tagalog") or
        std.mem.eql(u8, name, "scx=Tglg") or
        std.mem.eql(u8, name, "Script=Tai_Le") or
        std.mem.eql(u8, name, "Script=Tale") or
        std.mem.eql(u8, name, "sc=Tai_Le") or
        std.mem.eql(u8, name, "sc=Tale") or
        std.mem.eql(u8, name, "Script_Extensions=Tai_Le") or
        std.mem.eql(u8, name, "Script_Extensions=Tale") or
        std.mem.eql(u8, name, "scx=Tai_Le") or
        std.mem.eql(u8, name, "scx=Tale") or
        std.mem.eql(u8, name, "Script=Tai_Tham") or
        std.mem.eql(u8, name, "Script=Lana") or
        std.mem.eql(u8, name, "sc=Tai_Tham") or
        std.mem.eql(u8, name, "sc=Lana") or
        std.mem.eql(u8, name, "Script_Extensions=Tai_Tham") or
        std.mem.eql(u8, name, "Script_Extensions=Lana") or
        std.mem.eql(u8, name, "scx=Tai_Tham") or
        std.mem.eql(u8, name, "scx=Lana") or
        std.mem.eql(u8, name, "Script=Tai_Viet") or
        std.mem.eql(u8, name, "Script=Tavt") or
        std.mem.eql(u8, name, "sc=Tai_Viet") or
        std.mem.eql(u8, name, "sc=Tavt") or
        std.mem.eql(u8, name, "Script_Extensions=Tai_Viet") or
        std.mem.eql(u8, name, "Script_Extensions=Tavt") or
        std.mem.eql(u8, name, "scx=Tai_Viet") or
        std.mem.eql(u8, name, "scx=Tavt") or
        std.mem.eql(u8, name, "Script=Tai_Yo") or
        std.mem.eql(u8, name, "Script=Tayo") or
        std.mem.eql(u8, name, "sc=Tai_Yo") or
        std.mem.eql(u8, name, "sc=Tayo") or
        std.mem.eql(u8, name, "Script_Extensions=Tai_Yo") or
        std.mem.eql(u8, name, "Script_Extensions=Tayo") or
        std.mem.eql(u8, name, "scx=Tai_Yo") or
        std.mem.eql(u8, name, "scx=Tayo") or
        std.mem.eql(u8, name, "Script=Takri") or
        std.mem.eql(u8, name, "Script=Takr") or
        std.mem.eql(u8, name, "sc=Takri") or
        std.mem.eql(u8, name, "sc=Takr") or
        std.mem.eql(u8, name, "Script_Extensions=Takri") or
        std.mem.eql(u8, name, "Script_Extensions=Takr") or
        std.mem.eql(u8, name, "scx=Takri") or
        std.mem.eql(u8, name, "scx=Takr") or
        std.mem.eql(u8, name, "Script=Tangsa") or
        std.mem.eql(u8, name, "Script=Tnsa") or
        std.mem.eql(u8, name, "sc=Tangsa") or
        std.mem.eql(u8, name, "sc=Tnsa") or
        std.mem.eql(u8, name, "Script=Tamil") or
        std.mem.eql(u8, name, "Script=Taml") or
        std.mem.eql(u8, name, "sc=Tamil") or
        std.mem.eql(u8, name, "sc=Taml") or
        std.mem.eql(u8, name, "Script_Extensions=Tamil") or
        std.mem.eql(u8, name, "Script_Extensions=Taml") or
        std.mem.eql(u8, name, "scx=Tamil") or
        std.mem.eql(u8, name, "scx=Taml") or
        std.mem.eql(u8, name, "Script=Telugu") or
        std.mem.eql(u8, name, "Script=Telu") or
        std.mem.eql(u8, name, "sc=Telugu") or
        std.mem.eql(u8, name, "sc=Telu") or
        std.mem.eql(u8, name, "Script_Extensions=Telugu") or
        std.mem.eql(u8, name, "Script_Extensions=Telu") or
        std.mem.eql(u8, name, "scx=Telugu") or
        std.mem.eql(u8, name, "scx=Telu") or
        std.mem.eql(u8, name, "Script=Tangut") or
        std.mem.eql(u8, name, "Script=Tang") or
        std.mem.eql(u8, name, "sc=Tangut") or
        std.mem.eql(u8, name, "sc=Tang") or
        std.mem.eql(u8, name, "Script_Extensions=Tangut") or
        std.mem.eql(u8, name, "Script_Extensions=Tang") or
        std.mem.eql(u8, name, "scx=Tangut") or
        std.mem.eql(u8, name, "scx=Tang") or
        std.mem.eql(u8, name, "Script=Thai") or
        std.mem.eql(u8, name, "sc=Thai") or
        std.mem.eql(u8, name, "Script_Extensions=Thai") or
        std.mem.eql(u8, name, "scx=Thai") or
        std.mem.eql(u8, name, "Script=Thaana") or
        std.mem.eql(u8, name, "Script=Thaa") or
        std.mem.eql(u8, name, "sc=Thaana") or
        std.mem.eql(u8, name, "sc=Thaa") or
        std.mem.eql(u8, name, "Script_Extensions=Thaana") or
        std.mem.eql(u8, name, "Script_Extensions=Thaa") or
        std.mem.eql(u8, name, "scx=Thaana") or
        std.mem.eql(u8, name, "scx=Thaa") or
        std.mem.eql(u8, name, "Script=Tibetan") or
        std.mem.eql(u8, name, "Script=Tibt") or
        std.mem.eql(u8, name, "sc=Tibetan") or
        std.mem.eql(u8, name, "sc=Tibt") or
        std.mem.eql(u8, name, "Script_Extensions=Tibetan") or
        std.mem.eql(u8, name, "Script_Extensions=Tibt") or
        std.mem.eql(u8, name, "scx=Tibetan") or
        std.mem.eql(u8, name, "scx=Tibt") or
        std.mem.eql(u8, name, "Script=Tifinagh") or
        std.mem.eql(u8, name, "Script=Tfng") or
        std.mem.eql(u8, name, "sc=Tifinagh") or
        std.mem.eql(u8, name, "sc=Tfng") or
        std.mem.eql(u8, name, "Script_Extensions=Tifinagh") or
        std.mem.eql(u8, name, "Script_Extensions=Tfng") or
        std.mem.eql(u8, name, "scx=Tifinagh") or
        std.mem.eql(u8, name, "scx=Tfng") or
        std.mem.eql(u8, name, "Script=Tirhuta") or
        std.mem.eql(u8, name, "Script=Tirh") or
        std.mem.eql(u8, name, "sc=Tirhuta") or
        std.mem.eql(u8, name, "sc=Tirh") or
        std.mem.eql(u8, name, "Script_Extensions=Tirhuta") or
        std.mem.eql(u8, name, "Script_Extensions=Tirh") or
        std.mem.eql(u8, name, "scx=Tirhuta") or
        std.mem.eql(u8, name, "scx=Tirh") or
        std.mem.eql(u8, name, "Script=Todhri") or
        std.mem.eql(u8, name, "Script=Todr") or
        std.mem.eql(u8, name, "sc=Todhri") or
        std.mem.eql(u8, name, "sc=Todr") or
        std.mem.eql(u8, name, "Script_Extensions=Todhri") or
        std.mem.eql(u8, name, "Script_Extensions=Todr") or
        std.mem.eql(u8, name, "scx=Todhri") or
        std.mem.eql(u8, name, "scx=Todr") or
        std.mem.eql(u8, name, "Script=Tolong_Siki") or
        std.mem.eql(u8, name, "Script=Tols") or
        std.mem.eql(u8, name, "sc=Tolong_Siki") or
        std.mem.eql(u8, name, "sc=Tols") or
        std.mem.eql(u8, name, "Script=Toto") or
        std.mem.eql(u8, name, "sc=Toto") or
        std.mem.eql(u8, name, "Script_Extensions=Toto") or
        std.mem.eql(u8, name, "scx=Toto") or
        std.mem.eql(u8, name, "Script=Tulu_Tigalari") or
        std.mem.eql(u8, name, "Script=Tutg") or
        std.mem.eql(u8, name, "sc=Tulu_Tigalari") or
        std.mem.eql(u8, name, "sc=Tutg") or
        std.mem.eql(u8, name, "Script_Extensions=Tulu_Tigalari") or
        std.mem.eql(u8, name, "Script_Extensions=Tutg") or
        std.mem.eql(u8, name, "scx=Tulu_Tigalari") or
        std.mem.eql(u8, name, "scx=Tutg") or
        std.mem.eql(u8, name, "Script=Ugaritic") or
        std.mem.eql(u8, name, "Script=Ugar") or
        std.mem.eql(u8, name, "sc=Ugaritic") or
        std.mem.eql(u8, name, "sc=Ugar") or
        std.mem.eql(u8, name, "Script=Vai") or
        std.mem.eql(u8, name, "Script=Vaii") or
        std.mem.eql(u8, name, "sc=Vai") or
        std.mem.eql(u8, name, "sc=Vaii") or
        std.mem.eql(u8, name, "Script=Vithkuqi") or
        std.mem.eql(u8, name, "Script=Vith") or
        std.mem.eql(u8, name, "sc=Vithkuqi") or
        std.mem.eql(u8, name, "sc=Vith") or
        std.mem.eql(u8, name, "Script=Wancho") or
        std.mem.eql(u8, name, "Script=Wcho") or
        std.mem.eql(u8, name, "sc=Wancho") or
        std.mem.eql(u8, name, "sc=Wcho") or
        std.mem.eql(u8, name, "Script=Warang_Citi") or
        std.mem.eql(u8, name, "Script=Wara") or
        std.mem.eql(u8, name, "sc=Warang_Citi") or
        std.mem.eql(u8, name, "sc=Wara") or
        std.mem.eql(u8, name, "Script=Yezidi") or
        std.mem.eql(u8, name, "Script=Yezi") or
        std.mem.eql(u8, name, "sc=Yezidi") or
        std.mem.eql(u8, name, "sc=Yezi") or
        std.mem.eql(u8, name, "Script_Extensions=Yezidi") or
        std.mem.eql(u8, name, "Script_Extensions=Yezi") or
        std.mem.eql(u8, name, "scx=Yezidi") or
        std.mem.eql(u8, name, "scx=Yezi") or
        std.mem.eql(u8, name, "Script=Yi") or
        std.mem.eql(u8, name, "Script=Yiii") or
        std.mem.eql(u8, name, "sc=Yi") or
        std.mem.eql(u8, name, "sc=Yiii") or
        std.mem.eql(u8, name, "Script_Extensions=Yi") or
        std.mem.eql(u8, name, "Script_Extensions=Yiii") or
        std.mem.eql(u8, name, "scx=Yi") or
        std.mem.eql(u8, name, "scx=Yiii") or
        std.mem.eql(u8, name, "Script=Zanabazar_Square") or
        std.mem.eql(u8, name, "Script=Zanb") or
        std.mem.eql(u8, name, "sc=Zanabazar_Square") or
        std.mem.eql(u8, name, "sc=Zanb") or
        std.mem.eql(u8, name, "Script=Unknown") or
        std.mem.eql(u8, name, "Script=Zzzz") or
        std.mem.eql(u8, name, "sc=Unknown") or
        std.mem.eql(u8, name, "sc=Zzzz") or
        std.mem.eql(u8, name, "Script_Extensions=Unknown") or
        std.mem.eql(u8, name, "Script_Extensions=Zzzz") or
        std.mem.eql(u8, name, "scx=Unknown") or
        std.mem.eql(u8, name, "scx=Zzzz") or
        std.mem.eql(u8, name, "Any") or
        std.mem.eql(u8, name, "Assigned") or
        std.mem.eql(u8, name, "Emoji") or
        std.mem.eql(u8, name, "Emoji_Component") or
        std.mem.eql(u8, name, "EComp") or
        std.mem.eql(u8, name, "Emoji_Modifier") or
        std.mem.eql(u8, name, "EMod") or
        std.mem.eql(u8, name, "Emoji_Modifier_Base") or
        std.mem.eql(u8, name, "EBase") or
        std.mem.eql(u8, name, "Emoji_Presentation") or
        std.mem.eql(u8, name, "EPres") or
        std.mem.eql(u8, name, "Extended_Pictographic") or
        std.mem.eql(u8, name, "ExtPict") or
        std.mem.eql(u8, name, "Grapheme_Base") or
        std.mem.eql(u8, name, "Gr_Base") or
        std.mem.eql(u8, name, "Grapheme_Extend") or
        std.mem.eql(u8, name, "Gr_Ext") or
        std.mem.eql(u8, name, "Extender") or
        std.mem.eql(u8, name, "Ext") or
        std.mem.eql(u8, name, "Sentence_Terminal") or
        std.mem.eql(u8, name, "STerm") or
        std.mem.eql(u8, name, "Soft_Dotted") or
        std.mem.eql(u8, name, "SD") or
        std.mem.eql(u8, name, "Terminal_Punctuation") or
        std.mem.eql(u8, name, "Term") or
        std.mem.eql(u8, name, "Math") or
        std.mem.eql(u8, name, "Ideographic") or
        std.mem.eql(u8, name, "Ideo") or
        std.mem.eql(u8, name, "Unified_Ideograph") or
        std.mem.eql(u8, name, "UIdeo");
}

pub fn defineFreshNonIndexDataProperty(rt: *core.JSRuntime, object: *core.Object, atom_id: core.Atom, value: core.JSValue, writable: bool, enumerable: bool, configurable: bool) !void {
    try object.defineOwnNonIndexPropertyAssumingNew(rt, atom_id, core.Descriptor.data(value, writable, enumerable, configurable));
}

pub fn defineRegExpIndicesGroupsProperty(rt: *core.JSRuntime, global: *core.Object, out: *core.Object, found: RegExpMatch) !void {
    var has_named = false;
    for (found.captures[0..found.capture_count]) |capture| {
        if (capture.name != null) {
            has_named = true;
            break;
        }
    }
    const groups_atom = core.atom.predefinedId("groups", .string) orelse return error.TypeError;
    if (!has_named) {
        try defineFreshNonIndexDataProperty(rt, out, groups_atom, core.JSValue.undefinedValue(), true, true, true);
        return;
    }

    const groups = try core.Object.create(rt, core.class.ids.object, null);
    var groups_raw_owned = true;
    errdefer if (groups_raw_owned) core.Object.destroyFromHeader(rt, &groups.header);
    groups.null_prototype = true;
    for (found.captures[0..found.capture_count]) |capture| {
        const name = capture.name orelse continue;
        var decoded_name = std.ArrayList(u8).empty;
        defer decoded_name.deinit(rt.memory.allocator);
        try appendDecodedRegExpGroupName(rt, &decoded_name, name);
        const atom = try rt.internAtom(decoded_name.items);
        defer rt.atoms.free(atom);
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

pub fn defineRegExpGroupsProperty(rt: *core.JSRuntime, out: *core.Object, input_bytes: []const u8, found: RegExpMatch) !void {
    var has_named = false;
    for (found.captures[0..found.capture_count]) |capture| {
        if (capture.name != null) {
            has_named = true;
            break;
        }
    }
    const groups_atom = core.atom.predefinedId("groups", .string) orelse return error.TypeError;
    if (!has_named) {
        try defineFreshNonIndexDataProperty(rt, out, groups_atom, core.JSValue.undefinedValue(), true, true, true);
        return;
    }

    const groups = try core.Object.create(rt, core.class.ids.object, null);
    var groups_raw_owned = true;
    errdefer if (groups_raw_owned) core.Object.destroyFromHeader(rt, &groups.header);
    groups.null_prototype = true;
    for (found.captures[0..found.capture_count]) |capture| {
        const name = capture.name orelse continue;
        var decoded_name = std.ArrayList(u8).empty;
        defer decoded_name.deinit(rt.memory.allocator);
        try appendDecodedRegExpGroupName(rt, &decoded_name, name);
        const atom = try rt.internAtom(decoded_name.items);
        defer rt.atoms.free(atom);
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

pub fn defineRegExpGroupsPropertyFromValue(rt: *core.JSRuntime, out: *core.Object, input_value: core.JSValue, found: RegExpMatch) !void {
    var has_named = false;
    for (found.captures[0..found.capture_count]) |capture| {
        if (capture.name != null) {
            has_named = true;
            break;
        }
    }
    const groups_atom = core.atom.predefinedId("groups", .string) orelse return error.TypeError;
    if (!has_named) {
        try defineFreshNonIndexDataProperty(rt, out, groups_atom, core.JSValue.undefinedValue(), true, true, true);
        return;
    }

    const groups = try core.Object.create(rt, core.class.ids.object, null);
    var groups_raw_owned = true;
    errdefer if (groups_raw_owned) core.Object.destroyFromHeader(rt, &groups.header);
    groups.null_prototype = true;
    for (found.captures[0..found.capture_count]) |capture| {
        const name = capture.name orelse continue;
        var decoded_name = std.ArrayList(u8).empty;
        defer decoded_name.deinit(rt.memory.allocator);
        try appendDecodedRegExpGroupName(rt, &decoded_name, name);
        const atom = try rt.internAtom(decoded_name.items);
        defer rt.atoms.free(atom);
        const value = if (capture.undefined)
            core.JSValue.undefinedValue()
        else
            try stringSliceValue(rt, input_value, capture.start, capture.len);
        defer value.free(rt);
        try groups.defineOwnProperty(rt, atom, core.Descriptor.data(value, true, true, true));
    }
    const groups_value = groups.value();
    groups_raw_owned = false;
    defer groups_value.free(rt);
    try defineFreshNonIndexDataProperty(rt, out, groups_atom, groups_value, true, true, true);
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
    const primitive = primitivePrototypeThisValue(rt, this_value, class_tag) catch return throwPrimitivePrototypeTypeError(ctx, global, function_object);
    defer primitive.free(rt);
    return switch (method_tag) {
        1 => if (class_tag == 1)
            builtins.number.toStringMethod(rt, primitive, args)
        else if (class_tag == 3)
            qjsBigIntPrototypeToString(ctx, output, global, primitive, args, caller_function, caller_frame)
        else
            value_ops.toStringValue(rt, primitive),
        2 => primitive.dup(),
        else => error.TypeError,
    };
}

pub fn throwPrimitivePrototypeTypeError(
    ctx: *core.JSContext,
    global: *core.Object,
    function_object: *core.Object,
) !core.JSValue {
    const error_global = objectRealmGlobal(function_object) orelse global;
    const error_value = try createNamedError(ctx.runtime, error_global, "TypeError", "");
    _ = ctx.throwValue(error_value);
    return error.Test262Error;
}

pub fn getNumberPrototypeMethodId(rt: *core.JSRuntime, function_object: *core.Object) ?u32 {
    _ = rt;
    const native_ref = core.function.decodeNativeBuiltinId(function_object.nativeFunctionId()) orelse return null;
    if (native_ref.domain != .number) return null;
    return switch (native_ref.id) {
        @intFromEnum(builtins.number.PrototypeMethod.to_string),
        @intFromEnum(builtins.number.PrototypeMethod.to_locale_string),
        @intFromEnum(builtins.number.PrototypeMethod.to_fixed),
        @intFromEnum(builtins.number.PrototypeMethod.to_exponential),
        @intFromEnum(builtins.number.PrototypeMethod.to_precision),
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
    const primitive = primitivePrototypeThisValue(ctx.runtime, this_value, 1) catch |err| switch (err) {
        error.TypeError => return throwTypeErrorMessage(ctx, global, "not a number"),
    };
    defer primitive.free(ctx.runtime);
    const coerced_arg: ?core.JSValue = try coerceOptionalNumberMethodArgument(ctx, output, global, args, true);
    defer if (coerced_arg) |value| value.free(ctx.runtime);
    var coerced_storage: [1]core.JSValue = undefined;
    const method_args = if (coerced_arg) |value| blk: {
        coerced_storage[0] = value;
        break :blk coerced_storage[0..];
    } else args;
    _ = caller_function;
    _ = caller_frame;
    return (switch (method_id) {
        1, @intFromEnum(builtins.number.PrototypeMethod.to_string) => builtins.number.toStringMethod(ctx.runtime, primitive, method_args),
        2, @intFromEnum(builtins.number.PrototypeMethod.to_locale_string) => builtins.number.toStringMethod(ctx.runtime, primitive, &.{}),
        3, @intFromEnum(builtins.number.PrototypeMethod.to_fixed) => builtins.number.toFixed(ctx.runtime, primitive, method_args),
        4, @intFromEnum(builtins.number.PrototypeMethod.to_exponential) => builtins.number.toExponential(ctx.runtime, primitive, method_args),
        5, @intFromEnum(builtins.number.PrototypeMethod.to_precision) => builtins.number.toPrecision(ctx.runtime, primitive, method_args),
        else => error.TypeError,
    }) catch |err| switch (err) {
        error.TypeError => return throwTypeErrorMessage(ctx, global, "not a number"),
        error.RangeError => return throwRangeErrorMessage(ctx, global, "invalid number of digits"),
        else => err,
    };
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
    return builtins.buffer.dataViewConstruct(rt, used_args, prototype);
}

pub fn defineClassFieldDataProperty(rt: *core.JSRuntime, object: *core.Object, atom_id: core.Atom, value: core.JSValue) !void {
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
    const collection_value = try builtins.collection.constructWithPrototype(ctx.runtime, kind, prototype);
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
        if (source_object.is_array) {
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
    if (!prototype_value.isObject()) return null;
    const header = prototype_value.refHeader() orelse return null;
    return @fieldParentPtr("header", header);
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

pub fn qjsObjectIsPrototypeOf(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    if (args.len == 0) return core.JSValue.boolean(false);
    var current = objectFromValue(args[0]) orelse return core.JSValue.boolean(false);
    const this_object = objectFromValue(this_value) orelse return error.TypeError;
    while (try qjsObjectGetPrototypeOfStep(ctx, output, global, current, caller_function, caller_frame)) |prototype| {
        if (prototype == this_object) return core.JSValue.boolean(true);
        current = prototype;
    }
    return core.JSValue.boolean(false);
}

pub fn qjsObjectGetPrototypeOfStep(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    object: *core.Object,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?*core.Object {
    if (!object.is_proxy) {
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
    if (!object.is_proxy) {
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
    return try call_mod.internalDestructuringHelperFunction(rt, subtype);
}

pub fn qjsDestructuringObjectRest(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
) !core.JSValue {
    if (args.len < 1) return error.TypeError;
    var source_value = try value_vm.toObjectForWith(ctx.runtime, args[0]);
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

test "qjsDestructuringRest roots direct symbol values while creating rest array" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    const global = try zjs_vm.contextGlobal(ctx);

    const source = try core.Object.createArray(rt, arrayPrototypeFromGlobal(rt, global));
    var source_alive = true;
    defer if (source_alive) source.value().free(rt);
    const symbol_atom = try rt.atoms.newValueSymbol("gc-destructuring-rest-symbol");
    try source.defineOwnProperty(rt, core.atom.atomFromUInt32(0), core.Descriptor.data(core.JSValue.symbol(symbol_atom), true, true, true));
    source.length = 1;

    const args = [_]core.JSValue{ source.value(), core.JSValue.int32(0) };
    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const rest_value = try qjsDestructuringRest(ctx, null, global, &args);
    var rest_alive = true;
    defer if (rest_alive) rest_value.free(rt);
    const rest = try property_ops.expectObject(rest_value);

    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    {
        const stored = rest.getProperty(core.atom.atomFromUInt32(0));
        defer stored.free(rt);
        try std.testing.expect(stored.same(core.JSValue.symbol(symbol_atom)));
    }

    rest_value.free(rt);
    rest_alive = false;
    source.value().free(rt);
    source_alive = false;
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
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
    try source.defineOwnProperty(rt, key, core.Descriptor.data(core.JSValue.symbol(symbol_atom), true, true, true));

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
        try std.testing.expect(stored.same(core.JSValue.symbol(symbol_atom)));
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
    if (source.proxyTarget() == null and builtins.buffer.isTypedArrayObject(source)) {
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
    try validateProxyOwnKeysResult(ctx, output, global, target_value, out);
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

pub fn qjsObjectCallForNativeRecord(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    id: u32,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    const object_mod = builtins.object;
    return switch (id) {
        @intFromEnum(object_mod.StaticMethod.assign) => (try qjsObjectAssignCall(ctx, output, global, args, caller_function, caller_frame)) orelse error.TypeError,
        @intFromEnum(object_mod.StaticMethod.create) => (try qjsObjectCreateCall(ctx, output, global, args, caller_function, caller_frame)) orelse error.TypeError,
        @intFromEnum(object_mod.StaticMethod.define_property) => (try qjsDefinePropertyWithKind(ctx, output, global, args, 1, caller_function, caller_frame)) orelse error.TypeError,
        @intFromEnum(object_mod.StaticMethod.define_properties) => (try qjsDefinePropertiesCall(ctx, output, global, args, caller_function, caller_frame)) orelse error.TypeError,
        @intFromEnum(object_mod.StaticMethod.get_own_property_descriptor) => (try qjsGetOwnPropertyDescriptorCall(ctx, output, global, args, caller_function, caller_frame)) orelse error.TypeError,
        @intFromEnum(object_mod.StaticMethod.get_own_property_descriptors) => (try qjsGetOwnPropertyDescriptorsCall(ctx, output, global, args, caller_function, caller_frame)) orelse error.TypeError,
        @intFromEnum(object_mod.StaticMethod.get_own_property_names) => (try qjsObjectOwnPropertyKeysCall(ctx, output, global, args, .string, caller_function, caller_frame)) orelse error.TypeError,
        @intFromEnum(object_mod.StaticMethod.get_own_property_symbols) => (try qjsObjectOwnPropertyKeysCall(ctx, output, global, args, .symbol, caller_function, caller_frame)) orelse error.TypeError,
        @intFromEnum(object_mod.StaticMethod.get_prototype_of) => (try qjsObjectGetPrototypeOfCall(ctx, output, global, args, caller_function, caller_frame)) orelse error.TypeError,
        @intFromEnum(object_mod.StaticMethod.has_own) => (try qjsObjectHasOwnCall(ctx, output, global, args, caller_function, caller_frame)) orelse error.TypeError,
        @intFromEnum(object_mod.StaticMethod.is_extensible) => (try qjsObjectIsExtensibleCall(ctx, output, global, args, caller_function, caller_frame)) orelse error.TypeError,
        @intFromEnum(object_mod.StaticMethod.keys) => (try qjsObjectEnumerableOwnPropertiesCall(ctx, output, global, args, .keys, caller_function, caller_frame)) orelse error.TypeError,
        @intFromEnum(object_mod.StaticMethod.prevent_extensions) => (try qjsObjectPreventExtensionsCall(ctx, output, global, args, caller_function, caller_frame)) orelse error.TypeError,
        @intFromEnum(object_mod.StaticMethod.seal) => (try qjsObjectSetIntegrityCall(ctx, output, global, args, .sealed, caller_function, caller_frame)) orelse error.TypeError,
        @intFromEnum(object_mod.StaticMethod.is_sealed) => (try qjsObjectTestIntegrityCall(ctx, output, global, args, .sealed)) orelse error.TypeError,
        @intFromEnum(object_mod.StaticMethod.is_frozen) => (try qjsObjectTestIntegrityCall(ctx, output, global, args, .frozen)) orelse error.TypeError,
        @intFromEnum(object_mod.StaticMethod.set_prototype_of) => (try qjsObjectSetPrototypeOfCall(ctx, output, global, args, caller_function, caller_frame)) orelse error.TypeError,
        @intFromEnum(object_mod.StaticMethod.values) => (try qjsObjectEnumerableOwnPropertiesCall(ctx, output, global, args, .values, caller_function, caller_frame)) orelse error.TypeError,
        @intFromEnum(object_mod.StaticMethod.entries) => (try qjsObjectEnumerableOwnPropertiesCall(ctx, output, global, args, .entries, caller_function, caller_frame)) orelse error.TypeError,
        @intFromEnum(object_mod.StaticMethod.is) => {
            const lhs = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
            const rhs = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
            return core.JSValue.boolean(object_mod.sameValue(lhs, rhs));
        },
        @intFromEnum(object_mod.StaticMethod.freeze) => (try qjsObjectSetIntegrityCall(ctx, output, global, args, .frozen, caller_function, caller_frame)) orelse error.TypeError,
        @intFromEnum(object_mod.StaticMethod.from_entries) => (try qjsObjectFromEntriesCall(ctx, output, global, args, caller_function, caller_frame)) orelse error.TypeError,
        @intFromEnum(object_mod.StaticMethod.group_by) => (try qjsObjectGroupByCall(ctx, output, global, args, caller_function, caller_frame)) orelse error.TypeError,
        @intFromEnum(object_mod.PrototypeMethod.to_string) => try qjsObjectToStringCall(ctx, output, global, this_value, caller_function, caller_frame),
        @intFromEnum(object_mod.PrototypeMethod.to_locale_string) => try qjsObjectToLocaleStringCall(ctx, output, global, this_value, caller_function, caller_frame),
        @intFromEnum(object_mod.PrototypeMethod.value_of) => try qjsObjectValueOfCall(ctx.runtime, global, this_value),
        @intFromEnum(object_mod.PrototypeMethod.has_own_property) => (try qjsObjectPrototypeOwnPropertyCall(ctx, output, global, this_value, id, args, caller_function, caller_frame)) orelse error.TypeError,
        @intFromEnum(object_mod.PrototypeMethod.is_prototype_of) => try qjsObjectIsPrototypeOf(ctx, output, global, this_value, args, caller_function, caller_frame),
        @intFromEnum(object_mod.PrototypeMethod.property_is_enumerable) => (try qjsObjectPrototypeOwnPropertyCall(ctx, output, global, this_value, id, args, caller_function, caller_frame)) orelse error.TypeError,
        @intFromEnum(object_mod.PrototypeMethod.define_getter) => (try qjsObjectPrototypeDefineAccessorCall(ctx, output, global, this_value, args, true, caller_function, caller_frame)) orelse error.TypeError,
        @intFromEnum(object_mod.PrototypeMethod.define_setter) => (try qjsObjectPrototypeDefineAccessorCall(ctx, output, global, this_value, args, false, caller_function, caller_frame)) orelse error.TypeError,
        @intFromEnum(object_mod.PrototypeMethod.lookup_getter) => (try qjsObjectPrototypeLookupAccessorCall(ctx, output, global, this_value, args, true, caller_function, caller_frame)) orelse error.TypeError,
        @intFromEnum(object_mod.PrototypeMethod.lookup_setter) => (try qjsObjectPrototypeLookupAccessorCall(ctx, output, global, this_value, args, false, caller_function, caller_frame)) orelse error.TypeError,
        else => error.TypeError,
    };
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
    const url = try importMetaUrlValue(ctx.runtime, record);
    defer url.free(ctx.runtime);
    try defineValueProperty(ctx.runtime, object, "url", url);
    try defineValueProperty(ctx.runtime, object, "main", core.JSValue.boolean(record.import_meta_main));
    const value = object.value();
    record.import_meta = value.dup();
    return value;
}

pub fn withObjectBindingValue(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    with_object_value: core.JSValue,
    atom_id: core.Atom,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
) !?core.JSValue {
    if (with_object_value.isUndefined()) return null;
    _ = property_ops.expectObject(with_object_value) catch return null;
    const has_binding = try hasPropertyForWith(ctx, output, global, with_object_value, atom_id, function, frame);
    if (!has_binding) return null;
    if (try isBlockedByUnscopables(ctx, output, global, with_object_value, atom_id, function, frame)) return null;
    return try getValueProperty(ctx, output, global, with_object_value, atom_id, function, frame);
}

pub fn directEvalWithObject(
    rt: *core.JSRuntime,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) core.JSValue {
    const function = caller_function orelse return core.JSValue.undefinedValue();
    const frame = caller_frame orelse return core.JSValue.undefinedValue();
    const count = @min(function.var_names.len, frame.locals.len);
    var idx = count;
    while (idx > 0) {
        idx -= 1;
        const name = rt.atoms.name(function.var_names[idx]) orelse continue;
        if (!std.mem.startsWith(u8, name, "__active_with_obj_")) continue;
        const value = slotValueDup(frame.locals[idx]);
        if (objectFromValue(value) != null) return value;
        value.free(rt);
    }
    return core.JSValue.undefinedValue();
}

pub fn appendPrivateBoundNamesFromObject(
    rt: *core.JSRuntime,
    atoms: *std.ArrayList(core.Atom),
    object: *core.Object,
) !void {
    for (object.properties) |entry| {
        try appendPrivateBoundName(rt, atoms, entry.atom_id);
    }
}

pub fn directEvalCallerAllowsSuperProperty(caller_frame: ?*frame_mod.Frame, eval_in_class_field_initializer: bool) bool {
    if (eval_in_class_field_initializer) return true;
    const outer_frame = caller_frame orelse return false;
    if (outer_frame.current_function.isUndefined()) return false;
    if (functionBytecodeFromValue(outer_frame.current_function)) |fb| return fb.super_allowed;
    if (objectFromValue(outer_frame.current_function)) |function_object| {
        const stored = function_object.functionBytecodeSlot().* orelse return false;
        const fb = functionBytecodeFromValue(stored) orelse return false;
        return fb.super_allowed;
    }
    return false;
}

pub const WorkerObjectInitError = std.mem.Allocator.Error || error{
    IncompatibleDescriptor,
    InvalidLength,
    InvalidUtf8,
    NotExtensible,
    ReadOnly,
    TypeError,
};

pub fn qjsWorkerObjectId(rt: *core.JSRuntime, value: core.JSValue) !i32 {
    _ = rt;
    const object = objectFromValue(value) orelse return error.TypeError;
    return object.workerId() orelse error.TypeError;
}

pub fn qjsWorkerParentObject(rt: *core.JSRuntime) WorkerObjectInitError!core.JSValue {
    const worker = shared_vm.current_qjs_worker orelse return core.JSValue.undefinedValue();
    if (shared_vm.current_qjs_worker_parent) |parent| return parent.dup();
    const parent = try core.Object.create(rt, core.class.ids.object, null);
    errdefer core.Object.destroyFromHeader(rt, &parent.header);
    (try parent.workerIdSlot(rt)).* = worker.id;
    const post = try qjsWorkerNativeFunction(rt, "postMessage", 1, .parent);
    defer post.free(rt);
    try defineValueProperty(rt, parent, "postMessage", post);
    try defineValueProperty(rt, parent, "onmessage", core.JSValue.nullValue());
    _ = try rt.registerExternalValueSymbolRoot(parent.value());
    shared_vm.current_qjs_worker_parent = parent.value();
    return parent.value().dup();
}
pub fn createGeneratorObject(
    ctx: *core.JSContext,
    func: core.JSValue,
    current_function_value: core.JSValue,
    this_value: core.JSValue,
    input_args: []const core.JSValue,
    input_var_refs: []const core.JSValue,
    output: ?*std.Io.Writer,
    global: *core.Object,
    eval_var_ref_names: []const core.Atom,
    input_eval_var_refs: []const core.JSValue,
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
    var args_buffer = try core.runtime.ValueRootBuffer.initCopy(ctx.runtime, input_args);
    defer args_buffer.deinit(ctx.runtime);
    const args = args_buffer.values;
    var var_refs_buffer = try core.runtime.ValueRootBuffer.initCopy(ctx.runtime, input_var_refs);
    defer var_refs_buffer.deinit(ctx.runtime);
    const var_refs = var_refs_buffer.values;
    var eval_var_refs_buffer = try core.runtime.ValueRootBuffer.initCopy(ctx.runtime, input_eval_var_refs);
    defer eval_var_refs_buffer.deinit(ctx.runtime);
    const eval_var_refs = eval_var_refs_buffer.values;
    var root_slices = [_]core.runtime.ValueRootSlice{
        args_buffer.slice(),
        var_refs_buffer.slice(),
        eval_var_refs_buffer.slice(),
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = ctx.runtime.active_value_roots,
        .values = &root_values,
        .slices = &root_slices,
    };
    ctx.runtime.active_value_roots = &root_frame;
    defer ctx.runtime.active_value_roots = root_frame.previous;

    const fb = functionBytecodeFromValue(rooted_func) orelse return error.TypeError;
    const class_id = if (is_async) core.class.ids.async_generator else core.class.ids.generator;
    const object = try core.Object.create(ctx.runtime, class_id, null);
    errdefer core.Object.destroyFromHeader(ctx.runtime, &object.header);
    try object.setOptionalValueSlot(ctx.runtime, object.functionBytecodeSlot(), rooted_func.dup());
    if (property_ops.expectObject(rooted_current)) |function_object| {
        try object.setOptionalValueSlot(ctx.runtime, object.generatorCurrentFunctionSlot(), rooted_current.dup());
        try object.setFunctionHomeObject(ctx.runtime, function_object.functionHomeObject());
        try object.setFunctionRealmGlobalPtr(ctx.runtime, objectRealmGlobal(function_object) orelse global);
    } else |_| {}
    try object.setFunctionRealmGlobalPtrIfNull(ctx.runtime, global);
    const fb_runtime_strict = fb.is_strict_mode or fb.runtime_strict_mode;
    const effective_this = if (!fb_runtime_strict) blk: {
        if (rooted_this.isUndefined() or rooted_this.isNull()) break :blk global.value();
        if (!rooted_this.isObject()) {
            rooted_boxed_this = try primitiveObjectForAccess(ctx.runtime, global, rooted_this);
            break :blk rooted_boxed_this;
        }
        break :blk rooted_this;
    } else rooted_this;
    try object.setOptionalValueSlot(ctx.runtime, object.generatorThisSlot(), effective_this.dup());
    if (var_refs.len > 0) {
        const captures = try ctx.runtime.memory.alloc(core.JSValue, var_refs.len);
        var rooted_captures: []core.JSValue = captures[0..0];
        var captures_root = ValueSliceRoot{};
        captures_root.init(ctx.runtime, &rooted_captures);
        defer captures_root.deinit();
        var initialized: usize = 0;
        var captures_owned = true;
        errdefer if (captures_owned) {
            for (captures[0..initialized]) |*stored| {
                stored.free(ctx.runtime);
                stored.* = core.JSValue.undefinedValue();
            }
            rooted_captures = &.{};
            ctx.runtime.memory.free(core.JSValue, captures);
        };
        for (var_refs, 0..) |value, idx| {
            captures[idx] = value.dup();
            initialized += 1;
            rooted_captures = captures[0..initialized];
        }
        captures_owned = false;
        try object.setValueSlice(ctx.runtime, object.functionCapturesSlot(), captures);
    }

    if (args.len > 0) {
        const generator_args = try ctx.runtime.memory.alloc(core.JSValue, args.len);
        var rooted_generator_args: []core.JSValue = generator_args[0..0];
        var generator_args_root = ValueSliceRoot{};
        generator_args_root.init(ctx.runtime, &rooted_generator_args);
        defer generator_args_root.deinit();
        var initialized: usize = 0;
        var generator_args_owned = true;
        errdefer if (generator_args_owned) {
            for (generator_args[0..initialized]) |*stored| {
                stored.free(ctx.runtime);
                stored.* = core.JSValue.undefinedValue();
            }
            rooted_generator_args = &.{};
            ctx.runtime.memory.free(core.JSValue, generator_args);
        };
        for (args, 0..) |value, idx| {
            generator_args[idx] = value.dup();
            initialized += 1;
            rooted_generator_args = generator_args[0..initialized];
        }
        generator_args_owned = false;
        try object.setValueSlice(ctx.runtime, object.generatorArgsSlot(), generator_args);
    }

    if (eval_var_ref_names.len > 0) {
        const names = try ctx.runtime.memory.alloc(core.Atom, eval_var_ref_names.len);
        var locals_transferred = false;
        var refs_allocated = false;
        errdefer if (!refs_allocated and !locals_transferred) ctx.runtime.memory.free(core.Atom, names);
        const refs = try ctx.runtime.memory.alloc(core.JSValue, eval_var_ref_names.len);
        refs_allocated = true;
        var rooted_refs: []core.JSValue = refs[0..0];
        var refs_root = ValueSliceRoot{};
        refs_root.init(ctx.runtime, &rooted_refs);
        defer refs_root.deinit();
        var initialized: usize = 0;
        var initialized_names: usize = 0;
        errdefer if (!locals_transferred) {
            for (names[0..initialized_names]) |atom_id| ctx.runtime.atoms.free(atom_id);
            for (refs[0..initialized]) |*stored| {
                stored.free(ctx.runtime);
                stored.* = core.JSValue.undefinedValue();
            }
            rooted_refs = &.{};
            ctx.runtime.memory.free(core.Atom, names);
            ctx.runtime.memory.free(core.JSValue, refs);
        };
        for (eval_var_ref_names, 0..) |atom_id, idx| {
            names[idx] = ctx.runtime.atoms.dup(atom_id);
            initialized_names += 1;
            if (idx < eval_var_refs.len) {
                refs[idx] = eval_var_refs[idx].dup();
            } else {
                refs[idx] = core.JSValue.undefinedValue();
            }
            initialized += 1;
            rooted_refs = refs[0..initialized];
        }
        try object.writeValueSliceBarrier(ctx.runtime, refs);
        locals_transferred = true;
        object.functionEvalLocalNamesSlot().* = names;
        object.functionEvalLocalRefsSlot().* = refs;
    }

    if (fb.generator_body_pc != 0) {
        const init_result = try runGeneratorParameterInit(ctx, fb, object, current_function_value, effective_this, args, object.functionCapturesSlot().*, output, global);
        init_result.free(ctx.runtime);
    }

    const prototype = generatorObjectPrototype(ctx.runtime, global, current_function_value, is_async) catch null;
    try object.setPrototype(ctx.runtime, prototype);

    const next = try builtins.function.nativeFunction(ctx.runtime, "next", 0);
    defer next.free(ctx.runtime);
    try defineValueProperty(ctx.runtime, object, "next", next);
    const return_fn = try builtins.function.nativeFunction(ctx.runtime, "return", 1);
    defer return_fn.free(ctx.runtime);
    try defineValueProperty(ctx.runtime, object, "return", return_fn);
    const slice = try builtins.function.nativeFunction(ctx.runtime, "slice", 1);
    defer slice.free(ctx.runtime);
    try defineValueProperty(ctx.runtime, object, "slice", slice);
    return object.value();
}

test "createGeneratorObject roots copied captures while installing generator slots" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    const global = try core.Object.create(rt, core.class.ids.object, null);
    defer global.value().free(rt);

    const fb_slice = try rt.memory.alloc(bytecode.FunctionBytecode, 1);
    const fb = &fb_slice[0];
    fb.* = bytecode.FunctionBytecode.init(&rt.memory, &rt.atoms, core.atom.ids.empty_string);
    try rt.gc.add(&fb.header);
    var func_value = core.JSValue.functionBytecode(&fb.header);
    var func_alive = true;
    defer if (func_alive) func_value.free(rt);

    const child = try core.Object.create(rt, core.class.ids.object, null);
    var child_alive = true;
    defer if (child_alive) child.value().free(rt);
    child.header.setGeneration(.young);
    const var_refs = [_]core.JSValue{child.value()};

    const saved_trigger_fn = rt.memory.trigger_gc_fn;
    const saved_trigger_ctx = rt.memory.trigger_gc_ctx;
    var probe = ActiveRootValueProbe{
        .rt = rt,
        .target = child.value(),
    };
    rt.memory.trigger_gc_fn = ActiveRootValueProbe.trigger;
    rt.memory.trigger_gc_ctx = &probe;
    defer {
        rt.memory.trigger_gc_fn = saved_trigger_fn;
        rt.memory.trigger_gc_ctx = saved_trigger_ctx;
        rt.gc.clearRememberedSet();
    }

    const generator_value = try createGeneratorObject(ctx, func_value, core.JSValue.undefinedValue(), core.JSValue.undefinedValue(), &.{}, &var_refs, null, global, &.{}, &.{}, false);
    var generator_alive = true;
    defer if (generator_alive) generator_value.free(rt);

    try std.testing.expect(!probe.trace_failed);
    try std.testing.expect(probe.max_match_count >= 2);
    const generator = objectFromValue(generator_value) orelse return error.TypeError;
    try std.testing.expectEqual(@as(usize, 1), generator.functionCapturesSlot().*.len);
    try std.testing.expect(generator.functionCapturesSlot().*[0].same(child.value()));

    generator_value.free(rt);
    generator_alive = false;
    child.value().free(rt);
    child_alive = false;
    func_value.free(rt);
    func_alive = false;
}

pub fn generatorObjectPrototype(rt: *core.JSRuntime, global: *core.Object, function_value: core.JSValue, is_async: bool) !?*core.Object {
    const fallback = if (is_async) try asyncGeneratorPrototypeFromGlobal(rt, global) else try generatorPrototypeFromGlobal(rt, global);
    const function_object = property_ops.expectObject(function_value) catch return fallback;
    const prototype_value = function_object.getProperty(core.atom.ids.prototype);
    defer prototype_value.free(rt);
    return property_ops.expectObject(prototype_value) catch fallback;
}

pub fn qjsIteratorPrototypeAccessor(ctx: *core.JSContext, global: *core.Object, receiver: core.JSValue, args: []const core.JSValue, id: u32) !core.JSValue {
    if (id == @intFromEnum(builtins.iterator.AccessorMethod.constructor_setter)) {
        if (args.len > 0) {
            if (!args[0].isObject()) return throwTypeErrorMessage(ctx, global, "not an object");
            if (!receiver.isObject()) return throwTypeErrorMessage(ctx, global, "not an object");
        }
    } else if (id == @intFromEnum(builtins.iterator.AccessorMethod.to_string_tag_setter)) {
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
    } else if (atom_id == (core.atom.predefinedId("Symbol.toStringTag", .symbol) orelse return error.TypeError)) {
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
        createIteratorResult,
        getValueProperty,
        toPrimitiveForNumber,
        callValueOrBytecode,
        valueTruthy,
        qjsIteratorClose,
        arrayPrototypeFromGlobal,
        isCallableValue,
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
    method_object.functionIteratorWrapMethodSlot().* = @intCast(method_id);
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

pub fn createArgumentsObject(ctx: *core.JSContext, global: *core.Object, frame: *frame_mod.Frame, mapped_override: ?bool) !core.JSValue {
    const mapped = if (mapped_override) |requested|
        requested and frame.function.flags.has_simple_parameter_list
    else
        !currentFrameFunctionIsStrict(frame) and frame.function.flags.has_simple_parameter_list;
    const args = if (mapped)
        frame.args[0..@min(frame.actual_arg_count, frame.args.len)]
    else if (frame.original_args.len != 0)
        frame.original_args[0..@min(frame.actual_arg_count, frame.original_args.len)]
    else
        frame.args[0..@min(frame.actual_arg_count, frame.args.len)];
    const object = try core.Object.create(ctx.runtime, if (mapped) core.class.ids.mapped_arguments else core.class.ids.arguments, objectPrototypeFromGlobal(ctx.runtime, global));
    errdefer core.Object.destroyFromHeader(ctx.runtime, &object.header);
    try object.defineOwnProperty(ctx.runtime, core.atom.ids.length, core.Descriptor.data(core.JSValue.int32(@intCast(args.len)), true, false, true));
    if (try arrayPrototypeValuesFromGlobal(ctx.runtime, global)) |values| {
        defer values.free(ctx.runtime);
        const iterator_key = core.atom.predefinedId("Symbol.iterator", .symbol) orelse return error.TypeError;
        try object.defineOwnProperty(ctx.runtime, iterator_key, core.Descriptor.data(values, true, false, true));
    }
    const callee_key = try ctx.runtime.internAtom("callee");
    defer ctx.runtime.atoms.free(callee_key);
    if (mapped) {
        try object.defineOwnProperty(ctx.runtime, callee_key, core.Descriptor.data(frame.current_function, true, false, true));
    } else {
        const thrower = try throwTypeErrorIntrinsicForGlobal(ctx.runtime, global);
        defer thrower.free(ctx.runtime);
        try object.defineOwnProperty(ctx.runtime, callee_key, core.Descriptor.accessor(thrower, thrower, false, false));
    }
    var rooted_argument_refs: []core.JSValue = &.{};
    var argument_refs_root = ValueSliceRoot{};
    argument_refs_root.init(ctx.runtime, &rooted_argument_refs);
    defer argument_refs_root.deinit();

    if (mapped and args.len > 0) {
        const refs = object.argumentsVarRefsSlot();
        refs.* = try ctx.runtime.memory.alloc(core.JSValue, args.len);
        errdefer {
            rooted_argument_refs = &.{};
            const owned_refs = refs.*;
            refs.* = &.{};
            ctx.runtime.memory.free(core.JSValue, owned_refs);
        }
        @memset(refs.*, core.JSValue.undefinedValue());
    }
    for (args, 0..) |arg, index| {
        const refs = object.argumentsVarRefsSlot();
        if (mapped and index < refs.*.len and index < frame.args.len) {
            var rooted_cell = try ensureVarRefCell(ctx, &frame.args[index]);
            var cell_owned = true;
            errdefer if (cell_owned) rooted_cell.free(ctx.runtime);
            {
                var root_values = [_]core.runtime.ValueRootValue{
                    .{ .value = &rooted_cell },
                };
                const root_frame = core.runtime.ValueRootFrame{
                    .previous = ctx.runtime.active_value_roots,
                    .values = &root_values,
                };
                ctx.runtime.active_value_roots = &root_frame;
                defer ctx.runtime.active_value_roots = root_frame.previous;
                try ctx.runtime.writeBarrierValueAt(&object.header, rooted_cell, &refs.*[index]);
            }
            refs.*[index] = rooted_cell;
            cell_owned = false;
            rooted_argument_refs = refs.*[0 .. index + 1];
        }
        const arg_value = slotValueDup(arg);
        defer arg_value.free(ctx.runtime);
        try object.defineOwnProperty(ctx.runtime, core.atom.atomFromUInt32(@intCast(index)), core.Descriptor.data(arg_value, true, true, true));
    }
    return object.value();
}

pub fn installFunctionPrototypeThrowTypeErrorAccessors(rt: *core.JSRuntime, global: *core.Object, thrower: core.JSValue) !void {
    const function_prototype = functionPrototypeFromGlobal(rt, global) orelse return;
    const arguments_key = core.atom.ids.arguments;
    try function_prototype.defineOwnProperty(rt, arguments_key, core.Descriptor.accessor(thrower, thrower, false, true));
    const caller_key = core.atom.predefinedId("caller", .string).?;
    try function_prototype.defineOwnProperty(rt, caller_key, core.Descriptor.accessor(thrower, thrower, false, true));
}

pub fn isThrowTypeErrorIntrinsicObject(object: *core.Object) bool {
    return object.isThrowTypeErrorIntrinsicFunction();
}

pub fn frameArgumentsObject(ctx: *core.JSContext, global: *core.Object, frame: *frame_mod.Frame) !core.JSValue {
    if (frame.arguments_object) |value| return value.dup();
    const value = try createArgumentsObject(ctx, global, frame, null);
    frame.arguments_object = value.dup();
    return value;
}

pub fn frameArgumentsObjectForSpecialObject(ctx: *core.JSContext, global: *core.Object, frame: *frame_mod.Frame, subtype: u8) !core.JSValue {
    if (frame.arguments_object) |value| return value.dup();
    const mapped_override: ?bool = switch (subtype) {
        0 => false,
        1 => true,
        else => null,
    };
    const value = try createArgumentsObject(ctx, global, frame, mapped_override);
    frame.arguments_object = value.dup();
    return value;
}

pub fn functionObjectFromValue(value: core.JSValue) ?*core.Object {
    if (!value.isObject()) return null;
    const header = value.refHeader() orelse return null;
    const object: *core.Object = @fieldParentPtr("header", header);
    if (object.class_id != core.class.ids.bytecode_function) return null;
    return object;
}

pub fn objectFromValue(value: core.JSValue) ?*core.Object {
    if (!value.isObject()) return null;
    const header = value.refHeader() orelse return null;
    return @fieldParentPtr("header", header);
}

pub fn callableObjectFromValue(value: core.JSValue) ?*core.Object {
    if (!value.isObject()) return null;
    const header = value.refHeader() orelse return null;
    const object: *core.Object = @fieldParentPtr("header", header);
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
    if (try findPropertyDescriptor(object, atom_id)) |desc| {
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
        if (rt.atoms.kind(atom_id) == .private) {
            const effective_atom = remapPrivateAtomForOperation(rt, caller_frame, object, atom_id);
            return getPrivateValueProperty(ctx, output, global, value, object, effective_atom, caller_function, caller_frame);
        }
        if (object.proxyTarget() != null) {
            return getProxyProperty(ctx, output, global, value, object, atom_id, caller_function, caller_frame);
        }
        if (mappedArgumentsValue(ctx.runtime, object, atom_id)) |mapped_value| return mapped_value;
        if (builtins.buffer.isTypedArrayObject(object)) {
            if (try typedArrayCanonicalGet(ctx.runtime, object, atom_id)) |indexed| return indexed;
            if (atom_id == core.atom.ids.length) return core.JSValue.int32(@intCast(try builtins.buffer.typedArrayLength(rt, object)));
            if (atom_id == atom_byte_length) return core.JSValue.int32(@intCast(try builtins.buffer.typedArrayByteLength(rt, object)));
            if (atom_id == atom_byte_offset) return core.JSValue.int32(@intCast(try builtins.buffer.typedArrayByteOffset(object)));
        }
        if (object.exotic == null) {
            if (object.is_array) {
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
        if (try functionCallerArgumentsProperty(ctx, output, global, value, object, atom_id, caller_function, caller_frame)) |function_value| {
            return function_value;
        }
        if (try getAccessorDescriptorValue(ctx, output, global, value, object, atom_id, caller_function, caller_frame)) |accessor_value| {
            return accessor_value;
        }
        if (object.moduleNamespaceOwnBindingValue(atom_id)) |binding_value| {
            if (binding_value.isUninitialized()) {
                binding_value.free(rt);
                return error.ReferenceError;
            }
            return binding_value;
        }
        if (object.class_id == core.class.ids.dataview and
            (atom_id == atom_buffer or
                atom_id == atom_byte_length or
                atom_id == atom_byte_offset))
        {
            if (atom_id == atom_buffer) return (object.typedArrayBuffer() orelse return error.TypeError).dup();
            if (atom_id == atom_byte_length) return core.JSValue.int32(@intCast(try builtins.buffer.dataViewByteLength(rt, object)));
            return core.JSValue.int32(@intCast(try builtins.buffer.dataViewByteOffset(rt, object)));
        }
        if (object.getOwnProperty(atom_id)) |own_desc| {
            defer own_desc.destroy(rt);
            switch (own_desc.kind) {
                .data => return own_desc.value.dup(),
                .generic => return core.JSValue.undefinedValue(),
                .accessor => {
                    if (own_desc.getter.isUndefined()) return core.JSValue.undefinedValue();
                    return callValueOrBytecode(ctx, output, global, value, own_desc.getter, &.{}, caller_function, caller_frame);
                },
            }
        }
        if (try getPrototypePropertyValue(ctx, output, global, value, object, atom_id, caller_function, caller_frame)) |prototype_value| {
            return prototype_value;
        }
        const direct = object.getProperty(atom_id);
        if (!direct.isUndefined()) return direct;
        direct.free(rt);
        if (rt.atoms.kind(atom_id) == .private) return error.TypeError;
        if (object.is_array and atom_id == core.atom.ids.length) return value_ops.length(rt, value);
        if (object.class_id == core.class.ids.string) {
            if (object.objectData()) |string_data| {
                if (try getStringIndexValue(rt, string_data, atom_id)) |indexed| return indexed;
            }
        }
        if (object.is_array) return getPrototypeMethodWithFallback(rt, global, "Array", atom_id, "Object");
        if (object.class_id == core.class.ids.object) {
            if (object.null_prototype) return core.JSValue.undefinedValue();
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
    if (rt.atoms.kind(atom_id) == .private) return error.TypeError;
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

pub fn functionCallerArgumentsProperty(
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
    if (object.getOwnProperty(atom_id)) |own_desc| {
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
        if (fb.is_strict_mode or fb.runtime_strict_mode or fb.is_arrow_function or fb.func_kind == .generator or fb.func_kind == .async_generator) return error.TypeError;
        return core.JSValue.undefinedValue();
    }
    return error.TypeError;
}

pub fn getPrivateValueProperty(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    object: *core.Object,
    atom_id: core.Atom,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.JSValue {
    if (object.getOwnProperty(atom_id)) |desc| {
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
    if (object.getOwnProperty(atom_id)) |desc| {
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
    if (try getFastNumberPrimitiveDataProperty(ctx, global, receiver, atom_id)) |value| return value;

    const object_value = try primitiveObjectForAccess(ctx.runtime, global, receiver);
    defer object_value.free(ctx.runtime);
    const object = try property_ops.expectObject(object_value);
    if (try findPropertyDescriptor(object, atom_id)) |desc| {
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
    return core.JSValue.undefinedValue();
}

pub fn ownDataOrAutoInitPropertyValue(object: *core.Object, atom_id: core.Atom) ?core.JSValue {
    if (object.exotic != null) return null;
    for (object.properties) |entry| {
        if (entry.flags.deleted or entry.atom_id != atom_id) continue;
        if (entry.flags.accessor) return null;
        return switch (entry.slot) {
            .data => |stored| stored.dup(),
            .auto_init => object.getProperty(atom_id),
            .accessor, .deleted => null,
        };
    }
    return null;
}

pub fn getFastNumberPrimitiveDataProperty(
    ctx: *core.JSContext,
    global: *core.Object,
    receiver: core.JSValue,
    atom_id: core.Atom,
) !?core.JSValue {
    if (!receiver.isNumber()) return null;
    if (!isStandardNumberPrototypeMethodAtom(ctx.runtime, atom_id)) return null;

    const proto = constructorPrototypeFromGlobal(ctx.runtime, global, "Number") orelse return null;
    const desc = (try findPropertyDescriptor(proto, atom_id)) orelse return core.JSValue.undefinedValue();
    defer desc.destroy(ctx.runtime);
    return switch (desc.kind) {
        .data => desc.value.dup(),
        .generic => core.JSValue.undefinedValue(),
        .accessor => null,
    };
}

pub fn isStandardNumberPrototypeMethodAtom(rt: *core.JSRuntime, atom_id: core.Atom) bool {
    return value_ops.atomNameEql(rt, atom_id, "toString") or
        value_ops.atomNameEql(rt, atom_id, "toLocaleString") or
        value_ops.atomNameEql(rt, atom_id, "toFixed") or
        value_ops.atomNameEql(rt, atom_id, "toExponential") or
        value_ops.atomNameEql(rt, atom_id, "toPrecision");
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
        if (object.getOwnProperty(atom_id)) |desc| {
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

    if (rooted_primitive.isString()) {
        const prototype = constructorPrototypeFromGlobal(rt, global, "String") orelse return error.TypeError;
        const object = try core.Object.create(rt, core.class.ids.string, prototype);
        errdefer core.Object.destroyFromHeader(rt, &object.header);
        try object.setOptionalValueSlot(rt, object.objectDataSlot(), rooted_primitive.dup());
        const header = rooted_primitive.refHeader() orelse return error.TypeError;
        const string_value: *core.string.String = @fieldParentPtr("header", header);
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
    const constructor_name = if (rooted_primitive.isNumber())
        "Number"
    else if (rooted_primitive.isBool())
        "Boolean"
    else if (rooted_primitive.isBigInt())
        "BigInt"
    else
        "Symbol";
    const prototype = constructorPrototypeFromGlobal(rt, global, constructor_name) orelse return error.TypeError;
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

    const wrapper_value = try primitiveObjectForAccess(rt, global, core.JSValue.symbol(symbol_atom));
    var wrapper_alive = true;
    defer if (wrapper_alive) wrapper_value.free(rt);
    const wrapper = objectFromValue(wrapper_value) orelse return error.TypeError;

    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    const stored = wrapper.objectData() orelse return error.TypeError;
    try std.testing.expect(stored.same(core.JSValue.symbol(symbol_atom)));

    wrapper_value.free(rt);
    wrapper_alive = false;
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
    const throw_on_set_failure = setFailureShouldThrow(caller_function);
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
    if (object.is_with_environment and is_strict and !object.hasProperty(atom_id)) return error.ReferenceError;
    if (try setMappedArgumentsValue(ctx, object, atom_id, value)) return core.JSValue.undefinedValue();
    if (builtins.buffer.isTypedArrayObject(object)) {
        if (try typedArrayCanonicalSet(ctx, output, global, object, atom_id, value)) {
            return core.JSValue.undefinedValue();
        }
    }
    if (object.is_array and atom_id == core.atom.ids.length) {
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
    if (object.is_array) {
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

pub fn qjsObjectValueOfCall(rt: *core.JSRuntime, global: *core.Object, this_value: core.JSValue) !core.JSValue {
    if (this_value.isNull() or this_value.isUndefined()) return error.TypeError;
    if (this_value.isObject()) return this_value.dup();
    return primitiveObjectForAccess(rt, global, this_value);
}

pub fn bytecodeFunctionObjectTag(object: *core.Object) []const u8 {
    const function_value = object.functionBytecodeSlot().* orelse return "Function";
    const function_bytecode = functionBytecodeFromValue(function_value) orelse return "Function";
    if (function_bytecode.func_kind == .async or function_bytecode.func_kind == .async_generator) return "AsyncFunction";
    if (function_bytecode.func_kind == .generator) return "GeneratorFunction";
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

pub fn qjsObjectCreateCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    if (args.len < 1) return error.TypeError;
    const prototype: ?*core.Object = if (args[0].isNull())
        null
    else
        objectFromValue(args[0]) orelse return @as(?core.JSValue, try throwTypeErrorMessage(ctx, global, "object prototype may only be an Object or null"));
    const object = try core.Object.create(ctx.runtime, core.class.ids.object, prototype);
    errdefer core.Object.destroyFromHeader(ctx.runtime, &object.header);
    object.null_prototype = args[0].isNull();
    if (args.len >= 2 and !args[1].isUndefined()) {
        try qjsDefinePropertiesOnTarget(ctx, output, global, object, args[1], caller_function, caller_frame);
    }
    return object.value();
}

pub fn qjsObjectAssignCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    if (args.len < 1) return error.TypeError;
    if (args[0].isNull() or args[0].isUndefined()) return @as(?core.JSValue, try throwTypeErrorMessage(ctx, global, "Cannot convert undefined or null to object"));
    const target_value = if (objectFromValue(args[0])) |_| args[0].dup() else try primitiveObjectForAccess(ctx.runtime, global, args[0]);
    errdefer target_value.free(ctx.runtime);
    _ = objectFromValue(target_value) orelse return error.TypeError;

    for (args[1..]) |source_arg| {
        if (source_arg.isNull() or source_arg.isUndefined()) continue;
        const source_value = if (objectFromValue(source_arg)) |_| source_arg.dup() else try primitiveObjectForAccess(ctx.runtime, global, source_arg);
        defer source_value.free(ctx.runtime);
        const source = objectFromValue(source_value) orelse return error.TypeError;
        const keys = try objectRestOwnKeys(ctx, output, global, source);
        defer core.Object.freeKeys(ctx.runtime, keys);
        if (source.proxyTarget() != null) {
            try qjsObjectAssignKeys(ctx, output, global, target_value, source_value, source, keys, null, caller_function, caller_frame);
        } else {
            try qjsObjectAssignKeys(ctx, output, global, target_value, source_value, source, keys, false, caller_function, caller_frame);
            try qjsObjectAssignKeys(ctx, output, global, target_value, source_value, source, keys, true, caller_function, caller_frame);
        }
    }

    return target_value;
}

pub fn qjsObjectAssignKeys(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    target_value: core.JSValue,
    source_value: core.JSValue,
    source: *core.Object,
    keys: []const core.Atom,
    symbol_pass: ?bool,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !void {
    for (keys) |key| {
        const is_symbol = ctx.runtime.atoms.kind(key) == .symbol;
        if (symbol_pass) |pass| {
            if (is_symbol != pass) continue;
        }
        const desc = try objectRestOwnPropertyDescriptor(ctx, output, global, source, key) orelse continue;
        defer desc.destroy(ctx.runtime);
        if (desc.enumerable != true) continue;
        const value = try getValueProperty(ctx, output, global, source_value, key, caller_function, caller_frame);
        defer value.free(ctx.runtime);
        try setValuePropertyStrict(ctx, output, global, target_value, key, value, caller_function, caller_frame);
    }
}

pub fn qjsObjectEnumerableOwnPropertiesCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    mode: builtins.object.EntriesMode,
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
        if (ctx.runtime.atoms.kind(key) == .symbol) continue;
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
        try createDataPropertyOrThrow(ctx, output, global, out_value, out, core.atom.atomFromUInt32(out.length), element, caller_function, caller_frame);
        element.free(ctx.runtime);
        element = core.JSValue.undefinedValue();
    }
    return out_value;
}

pub fn qjsObjectHasOwnCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    if (args.len < 1) return null;
    if (args[0].isNull() or args[0].isUndefined()) return error.TypeError;
    const object_value = if (objectFromValue(args[0])) |_| args[0].dup() else try primitiveObjectForAccess(ctx.runtime, global, args[0]);
    defer object_value.free(ctx.runtime);
    const object = objectFromValue(object_value) orelse return error.TypeError;
    const key_value = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
    const atom_id = try toPropertyKeyAtom(ctx, output, global, key_value, caller_function, caller_frame);
    defer ctx.runtime.atoms.free(atom_id);
    const desc = try proxyAwareOwnPropertyDescriptor(ctx, output, global, object, atom_id, caller_function, caller_frame) orelse return core.JSValue.boolean(false);
    desc.destroy(ctx.runtime);
    return core.JSValue.boolean(true);
}

pub fn qjsObjectPrototypeOwnPropertyCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    method_id: u32,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    const object_mod = builtins.object;
    if (method_id != @intFromEnum(object_mod.PrototypeMethod.has_own_property) and method_id != @intFromEnum(object_mod.PrototypeMethod.property_is_enumerable)) return null;

    const key_value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const atom_id = try toPropertyKeyAtom(ctx, output, global, key_value, caller_function, caller_frame);
    defer ctx.runtime.atoms.free(atom_id);

    if (this_value.isNull() or this_value.isUndefined()) return error.TypeError;
    const object_value = if (objectFromValue(this_value)) |_| this_value.dup() else try primitiveObjectForAccess(ctx.runtime, global, this_value);
    defer object_value.free(ctx.runtime);
    const object = property_ops.expectObject(object_value) catch return error.TypeError;
    const desc = try proxyAwareOwnPropertyDescriptor(ctx, output, global, object, atom_id, caller_function, caller_frame) orelse return core.JSValue.boolean(false);
    defer desc.destroy(ctx.runtime);
    if (method_id == @intFromEnum(object_mod.PrototypeMethod.property_is_enumerable)) return core.JSValue.boolean(desc.enumerable orelse false);
    return core.JSValue.boolean(true);
}

pub fn qjsObjectPrototypeDefineAccessorCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    args: []const core.JSValue,
    getter: bool,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    if (this_value.isNull() or this_value.isUndefined()) return error.TypeError;
    const object_value = if (objectFromValue(this_value)) |_| this_value.dup() else try primitiveObjectForAccess(ctx.runtime, global, this_value);
    defer object_value.free(ctx.runtime);
    const object = objectFromValue(object_value) orelse return error.TypeError;
    const accessor_value = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
    if (!isCallableValue(accessor_value)) return error.TypeError;
    const key_value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const key = try toPropertyKeyAtom(ctx, output, global, key_value, caller_function, caller_frame);
    defer ctx.runtime.atoms.free(key);

    const desc = if (getter) core.Descriptor{
        .kind = .accessor,
        .getter = accessor_value.dup(),
        .getter_present = true,
        .enumerable = true,
        .configurable = true,
    } else core.Descriptor{
        .kind = .accessor,
        .setter = accessor_value.dup(),
        .setter_present = true,
        .enumerable = true,
        .configurable = true,
    };
    defer desc.destroy(ctx.runtime);
    const defined = if (object.proxyTarget() != null)
        proxyDefineOwnProperty(ctx, output, global, object, key, desc, caller_function, caller_frame) catch |err| switch (err) {
            error.IncompatibleDescriptor, error.NotExtensible, error.ReadOnly => return error.TypeError,
            error.InvalidLength => return error.RangeError,
            else => return err,
        }
    else blk: {
        object.defineOwnProperty(ctx.runtime, key, desc) catch |err| switch (err) {
            error.IncompatibleDescriptor, error.NotExtensible, error.ReadOnly => return error.TypeError,
            error.InvalidLength => return error.RangeError,
            else => return err,
        };
        break :blk true;
    };
    if (!defined) return error.TypeError;
    return core.JSValue.undefinedValue();
}

pub fn qjsObjectPrototypeLookupAccessorCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    args: []const core.JSValue,
    getter: bool,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    if (this_value.isNull() or this_value.isUndefined()) return error.TypeError;
    const object_value = if (objectFromValue(this_value)) |_| this_value.dup() else try primitiveObjectForAccess(ctx.runtime, global, this_value);
    defer object_value.free(ctx.runtime);
    var object = objectFromValue(object_value) orelse return error.TypeError;
    const key_value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const key = try toPropertyKeyAtom(ctx, output, global, key_value, caller_function, caller_frame);
    defer ctx.runtime.atoms.free(key);

    while (true) {
        const desc = try objectRestOwnPropertyDescriptor(ctx, output, global, object, key);
        if (desc) |item| {
            defer item.destroy(ctx.runtime);
            if (item.kind != .accessor) return core.JSValue.undefinedValue();
            if (getter) return if (item.getter_present) item.getter.dup() else core.JSValue.undefinedValue();
            return if (item.setter_present) item.setter.dup() else core.JSValue.undefinedValue();
        }
        object = (try qjsObjectGetPrototypeOfStep(ctx, output, global, object, caller_function, caller_frame)) orelse return core.JSValue.undefinedValue();
    }
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

pub fn qjsObjectFromEntriesCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    if (args.len < 1) return error.TypeError;
    const out = try core.Object.create(ctx.runtime, core.class.ids.object, objectPrototypeFromGlobal(ctx.runtime, global));
    errdefer core.Object.destroyFromHeader(ctx.runtime, &out.header);
    const out_value = out.value();

    const iterator_value = try iteratorForValue(ctx, output, global, args[0], caller_function, caller_frame);
    defer iterator_value.free(ctx.runtime);

    while (true) {
        const step = try iteratorStepValue(ctx, output, global, iterator_value);
        defer step.value.free(ctx.runtime);
        if (step.done) return out_value;

        const entry = objectFromValue(step.value) orelse {
            try closeIteratorForFromEntriesAbrupt(ctx, output, global, iterator_value);
            return error.TypeError;
        };
        const key_value = getValueProperty(ctx, output, global, entry.value(), core.atom.atomFromUInt32(0), caller_function, caller_frame) catch |err| {
            try closeIteratorForFromEntriesAbrupt(ctx, output, global, iterator_value);
            return err;
        };
        defer key_value.free(ctx.runtime);
        const value = getValueProperty(ctx, output, global, entry.value(), core.atom.atomFromUInt32(1), caller_function, caller_frame) catch |err| {
            try closeIteratorForFromEntriesAbrupt(ctx, output, global, iterator_value);
            return err;
        };
        defer value.free(ctx.runtime);
        const key = toPropertyKeyAtom(ctx, output, global, key_value, caller_function, caller_frame) catch |err| {
            try closeIteratorForFromEntriesAbrupt(ctx, output, global, iterator_value);
            return err;
        };
        defer ctx.runtime.atoms.free(key);
        createDataPropertyOrThrow(ctx, output, global, out_value, out, key, value, caller_function, caller_frame) catch |err| {
            try closeIteratorForFromEntriesAbrupt(ctx, output, global, iterator_value);
            return err;
        };
    }
}

pub fn qjsObjectGroupByCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    if (args.len < 2) return error.TypeError;
    if (!isCallableValue(args[1])) return error.TypeError;
    const out = try core.Object.create(ctx.runtime, core.class.ids.object, null);
    errdefer core.Object.destroyFromHeader(ctx.runtime, &out.header);
    out.null_prototype = true;
    const out_value = out.value();

    const iterator_value = try iteratorForValue(ctx, output, global, args[0], caller_function, caller_frame);
    defer iterator_value.free(ctx.runtime);

    var index: usize = 0;
    while (true) {
        const max_safe_integer: usize = 9007199254740991;
        if (index >= max_safe_integer) {
            try closeIteratorForFromEntriesAbrupt(ctx, output, global, iterator_value);
            return error.TypeError;
        }
        const step = try iteratorStepValue(ctx, output, global, iterator_value);
        defer step.value.free(ctx.runtime);
        if (step.done) return out_value;

        const index_value = value_ops.numberToValue(@floatFromInt(index));
        const raw_key = callValueOrBytecode(ctx, output, global, core.JSValue.undefinedValue(), args[1], &.{ step.value, index_value }, caller_function, caller_frame) catch |err| {
            try closeIteratorForFromEntriesAbrupt(ctx, output, global, iterator_value);
            return err;
        };
        defer raw_key.free(ctx.runtime);
        const key = toPropertyKeyAtom(ctx, output, global, raw_key, caller_function, caller_frame) catch |err| {
            try closeIteratorForFromEntriesAbrupt(ctx, output, global, iterator_value);
            return err;
        };
        defer ctx.runtime.atoms.free(key);
        try appendObjectGroupByValue(ctx, output, global, out_value, out, key, step.value, caller_function, caller_frame);
        index += 1;
    }
}

pub fn qjsObjectSetIntegrityCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    level: IntegrityLevel,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    const target_value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const object = objectFromValue(target_value) orelse return target_value.dup();
    if (level == .frozen and builtins.buffer.typedArrayBackedByResizableBuffer(object)) return error.TypeError;
    if (try qjsObjectPreventExtensionsCall(ctx, output, global, args, caller_function, caller_frame)) |prevented| {
        prevented.free(ctx.runtime);
    } else return error.TypeError;

    const keys = try objectRestOwnKeys(ctx, output, global, object);
    defer core.Object.freeKeys(ctx.runtime, keys);
    for (keys) |key| {
        const desc = if (level == .frozen)
            try objectRestOwnPropertyDescriptor(ctx, output, global, object, key)
        else
            null;
        defer if (desc) |item| item.destroy(ctx.runtime);

        const next_desc = switch (level) {
            .sealed => core.Descriptor.generic(null, false),
            .frozen => blk: {
                if (desc) |item| {
                    if (item.kind == .data) break :blk core.Descriptor{
                        .kind = .data,
                        .value_present = false,
                        .writable = false,
                        .configurable = false,
                    };
                }
                break :blk core.Descriptor.generic(null, false);
            },
        };
        const defined = if (object.proxyTarget() != null)
            try proxyDefineOwnProperty(ctx, output, global, object, key, next_desc, caller_function, caller_frame)
        else blk: {
            object.defineOwnProperty(ctx.runtime, key, next_desc) catch |err| switch (err) {
                error.IncompatibleDescriptor, error.NotExtensible, error.ReadOnly => return error.TypeError,
                error.InvalidLength => return error.RangeError,
                else => return err,
            };
            break :blk true;
        };
        if (!defined) return error.TypeError;
    }
    return target_value.dup();
}

pub fn qjsObjectTestIntegrityCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    level: IntegrityLevel,
) !?core.JSValue {
    const target_value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const object = objectFromValue(target_value) orelse return core.JSValue.boolean(true);
    if (try objectIsExtensibleForIntegrity(ctx, output, global, object)) return core.JSValue.boolean(false);
    const keys = try objectRestOwnKeys(ctx, output, global, object);
    defer core.Object.freeKeys(ctx.runtime, keys);
    for (keys) |key| {
        const desc = try objectRestOwnPropertyDescriptor(ctx, output, global, object, key) orelse continue;
        defer desc.destroy(ctx.runtime);
        if (desc.configurable == true) return core.JSValue.boolean(false);
        if (level == .frozen and desc.kind == .data and desc.writable == true) return core.JSValue.boolean(false);
    }
    return core.JSValue.boolean(true);
}

pub fn objectIsExtensibleForIntegrity(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    object: *core.Object,
) !bool {
    if (object.proxyTarget() == null) return object.isExtensible();
    const target_value = object.proxyTarget() orelse return object.isExtensible();
    const target = property_ops.expectObject(target_value) catch return error.TypeError;
    const handler_value = object.proxyHandler() orelse return error.TypeError;
    const trap_key = try ctx.runtime.internAtom("isExtensible");
    defer ctx.runtime.atoms.free(trap_key);
    const trap = try getValueProperty(ctx, output, global, handler_value, trap_key, null, null);
    defer trap.free(ctx.runtime);
    if (trap.isUndefined() or trap.isNull()) return target.isExtensible();
    if (!isCallableValue(trap)) return error.TypeError;
    const result = try callValueOrBytecode(ctx, output, global, handler_value, trap, &.{target_value}, null, null);
    defer result.free(ctx.runtime);
    const extensible = valueTruthy(result);
    if (extensible != target.isExtensible()) return error.TypeError;
    return extensible;
}

pub fn appendObjectGroupByValue(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    out_value: core.JSValue,
    out: *core.Object,
    key: core.Atom,
    value: core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !void {
    var group_value = getValueProperty(ctx, output, global, out_value, key, caller_function, caller_frame) catch core.JSValue.undefinedValue();
    defer group_value.free(ctx.runtime);
    if (group_value.isUndefined()) {
        group_value.free(ctx.runtime);
        const group = try core.Object.createArray(ctx.runtime, arrayPrototypeFromGlobal(ctx.runtime, global));
        group_value = group.value();
        try createDataPropertyOrThrow(ctx, output, global, out_value, out, key, group_value, caller_function, caller_frame);
    }
    const group = objectFromValue(group_value) orelse return error.TypeError;
    try createDataPropertyOrThrow(ctx, output, global, group_value, group, core.atom.atomFromUInt32(group.length), value, caller_function, caller_frame);
}

test "Object.groupBy new group define failure releases group once" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const global = try core.Object.create(rt, core.class.ids.object, null);
    defer global.value().free(rt);
    const out = try core.Object.create(rt, core.class.ids.object, null);
    defer out.value().free(rt);
    out.preventExtensions();

    const key = try rt.internAtom("group");
    defer rt.atoms.free(key);

    try std.testing.expectError(
        error.TypeError,
        appendObjectGroupByValue(ctx, null, global, out.value(), out, key, core.JSValue.int32(1), null, null),
    );
    try std.testing.expectEqual(@as(usize, 2), rt.gc.liveCount());
}

pub fn qjsObjectPreventExtensionsCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    const target_value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const object = objectFromValue(target_value) orelse return target_value.dup();
    if (object.proxyTarget() != null) {
        if (!try proxyAwarePreventExtensions(ctx, output, global, object, caller_function, caller_frame)) return error.TypeError;
        return target_value.dup();
    }
    object.preventExtensions();
    return target_value.dup();
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
        error.PrototypeCycle, error.NotExtensible => return error.TypeError,
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

pub fn qjsGetOwnPropertyDescriptorCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    if (args.len < 1) return null;
    if (args[0].isNull() or args[0].isUndefined()) return error.TypeError;
    const object_value = if (objectFromValue(args[0])) |_| args[0].dup() else try primitiveObjectForAccess(ctx.runtime, global, args[0]);
    defer object_value.free(ctx.runtime);
    const object = objectFromValue(object_value) orelse return error.TypeError;
    const key_value = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
    const atom_id = try toPropertyKeyAtom(ctx, output, global, key_value, caller_function, caller_frame);
    defer ctx.runtime.atoms.free(atom_id);
    var desc = try proxyAwareOwnPropertyDescriptor(ctx, output, global, object, atom_id, caller_function, caller_frame) orelse return core.JSValue.undefinedValue();
    try call_mod.materializeMappedArgumentsDescriptorValueForVm(ctx.runtime, object, atom_id, &desc);
    defer desc.destroy(ctx.runtime);
    const desc_value = try descriptorObjectFromDescriptor(ctx.runtime, global, desc);
    return desc_value;
}

pub fn qjsObjectGetPrototypeOfCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    if (args.len < 1) return null;
    if (args[0].isNull() or args[0].isUndefined()) return @as(?core.JSValue, try throwTypeErrorMessage(ctx, global, "not an object"));
    const object_value = if (objectFromValue(args[0])) |_| args[0].dup() else try primitiveObjectForAccess(ctx.runtime, global, args[0]);
    defer object_value.free(ctx.runtime);
    const object = objectFromValue(object_value) orelse return error.TypeError;
    if (try qjsObjectPrototypeMethodFunctionPrototype(ctx, global, object)) |prototype| return prototype.value().dup();
    return try qjsObjectGetPrototypeOfValue(ctx, output, global, object, caller_function, caller_frame);
}

pub fn qjsObjectPrototypeMethodFunctionPrototype(
    ctx: *core.JSContext,
    global: *core.Object,
    object: *core.Object,
) !?*core.Object {
    if (object.class_id != core.class.ids.c_function) return null;
    if (!isObjectPrototypeNativeRecord(object, @intFromEnum(builtins.object.PrototypeMethod.is_prototype_of))) return null;
    return functionPrototypeFromGlobal(ctx.runtime, global);
}

pub fn isObjectPrototypeNativeRecord(object: *core.Object, id: u32) bool {
    const native_ref = core.function.decodeNativeBuiltinId(object.nativeFunctionIdSlot().*) orelse return false;
    return native_ref.domain == .object and native_ref.id == id;
}

pub fn qjsGetOwnPropertyDescriptorsCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    if (args.len < 1) return null;
    if (args[0].isNull() or args[0].isUndefined()) return error.TypeError;
    const object_value = if (objectFromValue(args[0])) |_| args[0].dup() else try primitiveObjectForAccess(ctx.runtime, global, args[0]);
    defer object_value.free(ctx.runtime);
    const object = objectFromValue(object_value) orelse return error.TypeError;
    const keys = try objectRestOwnKeys(ctx, output, global, object);
    defer core.Object.freeKeys(ctx.runtime, keys);

    const out = try core.Object.create(ctx.runtime, core.class.ids.object, objectPrototypeFromGlobal(ctx.runtime, global));
    errdefer core.Object.destroyFromHeader(ctx.runtime, &out.header);
    for (keys) |key| {
        var desc = (try objectRestOwnPropertyDescriptor(ctx, output, global, object, key)) orelse continue;
        try call_mod.materializeMappedArgumentsDescriptorValueForVm(ctx.runtime, object, key, &desc);
        defer desc.destroy(ctx.runtime);
        const desc_value = try descriptorObjectFromDescriptor(ctx.runtime, global, desc);
        defer desc_value.free(ctx.runtime);
        try createDataPropertyOrThrow(ctx, output, global, out.value(), out, key, desc_value, caller_function, caller_frame);
    }
    return out.value();
}

pub const OwnPropertyKeyFilter = enum {
    string,
    symbol,
};

pub fn qjsObjectOwnPropertyKeysCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    filter: OwnPropertyKeyFilter,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.JSValue {
    if (args.len < 1) return error.TypeError;
    if (args[0].isNull() or args[0].isUndefined()) return error.TypeError;
    const object_value = if (objectFromValue(args[0])) |_| args[0].dup() else try primitiveObjectForAccess(ctx.runtime, global, args[0]);
    defer object_value.free(ctx.runtime);
    const object = objectFromValue(object_value) orelse return error.TypeError;
    const keys = try objectRestOwnKeys(ctx, output, global, object);
    defer core.Object.freeKeys(ctx.runtime, keys);

    const out = try core.Object.createArray(ctx.runtime, arrayPrototypeFromGlobal(ctx.runtime, global));
    errdefer core.Object.destroyFromHeader(ctx.runtime, &out.header);
    for (keys) |key| {
        const is_symbol = ctx.runtime.atoms.kind(key) == .symbol;
        switch (filter) {
            .string => {
                if (is_symbol) continue;
                const name_value = try ctx.runtime.atoms.toStringValue(ctx.runtime, key);
                defer name_value.free(ctx.runtime);
                try createDataPropertyOrThrow(ctx, output, global, out.value(), out, core.atom.atomFromUInt32(out.length), name_value, caller_function, caller_frame);
            },
            .symbol => {
                if (!is_symbol) continue;
                try createDataPropertyOrThrow(ctx, output, global, out.value(), out, core.atom.atomFromUInt32(out.length), core.JSValue.symbol(key), caller_function, caller_frame);
            },
        }
    }
    return out.value();
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

    const symbol_atom = try rt.atoms.newValueSymbol("gc-descriptor-object-value-bytecode-symbol");
    fb.cpool = try rt.memory.alloc(core.JSValue, 1);
    fb.cpool[0] = core.JSValue.symbol(symbol_atom);
    fb.cpool_count = 1;

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
    const stored = descriptor.getProperty(value_key);
    defer stored.free(rt);
    try std.testing.expect(stored.same(desc_value));

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
        if (has_value and target.is_array and atom_id == core.atom.ids.length and !value.isNumber()) {
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
    if (try findPropertyDescriptor(object, atom_id)) |desc| {
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
    var current = object.getPrototype();
    while (current) |prototype| : (current = prototype.getPrototype()) {
        if (prototype.proxyTarget() != null) {
            return try getProxyProperty(ctx, output, global, receiver, prototype, atom_id, caller_function, caller_frame);
        }
        if (prototype.getOwnProperty(atom_id)) |desc| {
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
        if (try findPropertyDescriptor(object, atom_id)) |desc| {
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
    if (try findPropertyDescriptor(prototype, atom_id)) |desc| {
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

pub fn findPropertyDescriptor(object: *core.Object, atom_id: core.Atom) !?core.Descriptor {
    if (object.getOwnProperty(atom_id)) |desc| return desc;
    if (object.prototype) |proto| return findPropertyDescriptor(proto, atom_id);
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
    return try validateProxyHasResult(ctx.runtime, target, atom_id, valueTruthy(result));
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
    return try validateProxyHasResult(ctx.runtime, target, atom_id, valueTruthy(result));
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
    if (object.getOwnProperty(atom_id)) |desc| {
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
        if (proto.getOwnProperty(atom_id)) |desc| {
            desc.destroy(ctx.runtime);
            return true;
        }
    }
    return has_builtin_object_proto;
}

pub fn indexedExoticHasProperty(rt: *core.JSRuntime, object: *core.Object, atom_id: core.Atom) bool {
    if (stringObjectHasIndexProperty(rt, object, atom_id)) return true;
    if (!builtins.buffer.isTypedArrayObject(object)) return false;
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
    if (target.getOwnProperty(atom_id)) |desc| {
        defer desc.destroy(ctx.runtime);
        if (desc.configurable == false) return error.TypeError;
        if (!target.isExtensible()) return error.TypeError;
    }
    return true;
}

pub fn capturedArgumentsObject(
    rt: *core.JSRuntime,
    eval_local_names: []const core.Atom,
    eval_local_slots: []core.JSValue,
    eval_var_ref_names: []const core.Atom,
    eval_var_refs: []const core.JSValue,
    frame: *frame_mod.Frame,
) ?core.JSValue {
    if (lookupNamedSlotValue(rt, eval_local_names, eval_local_slots, core.atom.ids.arguments)) |value| return value;
    if (lookupNamedVarRef(rt, eval_var_ref_names, eval_var_refs, core.atom.ids.arguments)) |value| return value;
    if (lookupNamedSlotValue(rt, frame.eval_local_names, frame.eval_local_slots, core.atom.ids.arguments)) |value| return value;
    if (lookupNamedVarRef(rt, frame.eval_var_ref_names, frame.eval_var_refs, core.atom.ids.arguments)) |value| return value;
    return null;
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
    const existing = object.getOwnProperty(core.atom.ids.name) orelse return false;
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